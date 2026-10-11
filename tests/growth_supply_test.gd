extends SceneTree
## 生长物流夹具：真实营养包和网络，手动推进包与生长，避免依赖帧率。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")

class Fixture:
	extends RefCounted

	var scene: Node2D
	var source: MotherCore
	var hub: Node2D
	var start: Node2D
	var edges: Array[HyphaEdge] = []
	var network: NetworkSystem
	var growth: GrowthSystem
	var supply: GrowthSupplySystem
	var battle: SupplySystem
	var organs: Array[AttackOrgan] = []
	var packets: Node2D
	var task_id: int = 0
	var last_supply_snapshot: Dictionary = {}

class Trigger:
	extends RefCounted

	var fired: bool = false

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	await _test_actual_delivery_and_completion()
	await _test_combat_reserve_and_battle_supply()
	await _test_paid_incoming_and_growth_balance()
	await _test_paused_transit()
	await _test_route_loss_and_recovery()
	await _test_cancelled_buffer_source_identity()
	await _test_cancel_arrival_orders()
	await _test_cancel_during_receive()
	await _test_cancel_during_debit()
	await _test_queue_during_debit()
	await _test_cancel_before_debit()
	await _test_reset_restart_and_stale_callbacks()
	await _test_direct_packet_removal()
	await _test_synchronous_zero_length_delivery()
	await _test_interval_and_configuration()
	await _test_supply_exit()
	_check(root.get_child_count() == initial_children, "Growth supply fixtures left root children")
	print("GROWTH_SUPPLY_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(balance: int = 512, organ_count: int = 0,
		local_stock: int = 0) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.scene = Node2D.new()
	root.add_child(fixture.scene)
	fixture.source = CORE_SCENE.instantiate() as MotherCore
	fixture.source.initial_nutrition = balance
	fixture.scene.add_child(fixture.source)
	fixture.hub = Node2D.new()
	fixture.hub.position = Vector2(80.0, 0.0)
	fixture.scene.add_child(fixture.hub)
	fixture.start = NODE_SCENE.instantiate() as HyphaNode
	fixture.start.position = Vector2(160.0, 0.0)
	fixture.scene.add_child(fixture.start)
	fixture.network = NetworkSystem.new()
	fixture.scene.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.source, true), "Fixture core registration")
	_check(fixture.network.register_node(fixture.hub), "Fixture hub registration")
	_check(fixture.network.register_node(fixture.start), "Fixture growth start registration")
	fixture.edges.append(_new_edge(fixture, fixture.source, fixture.hub))
	# 此边反向存储端点，真实路线必须穿过一个反向段。
	fixture.edges.append(_new_edge(fixture, fixture.start, fixture.hub))
	fixture.packets = Node2D.new()
	fixture.scene.add_child(fixture.packets)
	fixture.growth = GrowthSystem.new()
	fixture.growth.planner = GrowthPlanner.new()
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = _new_container(fixture.scene)
	fixture.growth.edge_container = _new_container(fixture.scene)
	fixture.growth.tip_container = _new_container(fixture.scene)
	fixture.scene.add_child(fixture.growth)
	fixture.growth.set_process(false)
	fixture.growth.set_physics_process(false)
	fixture.battle = SupplySystem.new()
	fixture.battle.mother_core = fixture.source
	fixture.battle.network_system = fixture.network
	fixture.battle.packet_container = fixture.packets
	fixture.battle.packet_scene = PACKET_SCENE
	fixture.scene.add_child(fixture.battle)
	for index: int in range(organ_count):
		var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
		organ.initial_nutrition = local_stock
		fixture.start.add_child(organ)
		fixture.organs.append(organ)
		_check(fixture.battle.register_organ(organ), "Fixture combat organ " + str(index))
	fixture.supply = GrowthSupplySystem.new()
	fixture.supply.growth_system = fixture.growth
	fixture.supply.mother_core = fixture.source
	fixture.supply.network_system = fixture.network
	fixture.supply.combat_supply_system = fixture.battle
	fixture.supply.packet_container = fixture.packets
	fixture.supply.auto_supply = false
	fixture.supply.supply_changed.connect(_capture_supply.bind(fixture))
	fixture.scene.add_child(fixture.supply)
	fixture.supply.set_process(false)
	return fixture


func _new_container(parent: Node2D) -> Node2D:
	var container: Node2D = Node2D.new()
	parent.add_child(container)
	return container


func _new_edge(fixture: Fixture, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	fixture.scene.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Fixture edge registration")
	return edge


func _capture_supply(snapshot: Dictionary, fixture: Fixture) -> void:
	fixture.last_supply_snapshot = snapshot.duplicate()


func _create_target(fixture: Fixture, start: Node2D = null) -> void:
	var origin: Node2D = fixture.start if start == null else start
	fixture.task_id = fixture.growth.create_target(origin, origin.global_position + Vector2(180.0, 0.0))
	_check(fixture.task_id > 0, "Growth target creation failed")
	_check(fixture.growth.get_requested_nutrition(fixture.task_id) > 0,
		"New growth target did not request its first investment")


func _snapshot(fixture: Fixture) -> Dictionary:
	return fixture.growth.get_task_snapshot()


func _active_packets(fixture: Fixture) -> Array[NutrientPacket]:
	var packets: Array[NutrientPacket] = []
	for record: Dictionary in fixture.supply.get_shipment_records():
		var packet: Variant = record.get("packet")
		if not bool(record.get("settled", false)) and is_instance_valid(packet):
			packets.append(packet as NutrientPacket)
	return packets


func _freeze_packets(fixture: Fixture) -> void:
	for child: Node in fixture.packets.get_children():
		if child is NutrientPacket:
			child.set_physics_process(false)


func _dispatch(fixture: Fixture) -> bool:
	var result: bool = fixture.supply.try_dispatch()
	_freeze_packets(fixture)
	return result


func _dispatch_demand(fixture: Fixture) -> int:
	var count: int = 0
	for attempt: int in range(512):
		if not _dispatch(fixture):
			break
		count += 1
	return count


func _first_packet(fixture: Fixture) -> NutrientPacket:
	var packets: Array[NutrientPacket] = _active_packets(fixture)
	_check(not packets.is_empty(), "Expected a real in-flight growth packet")
	return null if packets.is_empty() else packets[0]


func _deliver_growth(fixture: Fixture) -> void:
	for packet: NutrientPacket in _active_packets(fixture):
		if is_instance_valid(packet) and not packet.is_queued_for_deletion():
			packet._physics_process(1000.0)


func _check_audit(fixture: Fixture, context: String) -> void:
	var previous_id: int = 0
	var pending: int = 0
	for record: Dictionary in fixture.supply.get_shipment_records():
		var shipment_id: int = int(record.get("shipment_id", 0))
		_check(shipment_id > previous_id, context + ": shipment identifiers were reused or reordered")
		previous_id = shipment_id
		_check(record.has("task_id") and record.has("source") and record.has("packet")
			and record.has("debited") and record.has("settled") and record.has("status"),
			context + ": audit fields missing")
		if not bool(record.get("settled", false)):
			pending += 1
	_check(pending == fixture.supply.get_in_transit_count(), context + ": pending ledger mismatch")


func _remove_fixture(fixture: Fixture) -> void:
	if is_instance_valid(fixture.supply):
		fixture.supply.reset()
	fixture.scene.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.scene), "Growth fixture teardown failed")


func _test_actual_delivery_and_completion() -> void:
	var fixture: Fixture = _new_fixture()
	var initial_balance: int = fixture.source.nutrition
	_create_target(fixture)
	_check(fixture.source.nutrition == initial_balance and fixture.supply.get_in_transit_count() == 0,
		"Placing a target synchronously debited or dispatched")
	fixture.growth.advance(10.0)
	_check(is_zero_approx(float(_snapshot(fixture).get("distance", -1.0)))
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Growth moved or consumed before any arrival")
	var target: Node2D = fixture.growth.get_delivery_target(fixture.task_id)
	var route: NetworkRoute = fixture.network.find_route(fixture.source, target)
	_check(route.found and route.segments.size() >= 3 and not route.segments[1].forward,
		"Growth delivery is not a real multi-segment mixed-direction route")
	_check(_dispatch(fixture), "Initial growth dispatch failed")
	var packet: NutrientPacket = _first_packet(fixture)
	if packet == null:
		await _remove_fixture(fixture)
		return
	packet.speed = 100.0
	packet._physics_process(0.5)
	_check(packet.global_position.distance_to(Vector2(50.0, 0.0)) < 0.001,
		"Growth packet did not travel the first real route segment")
	fixture.growth.advance(10.0)
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0
		and is_zero_approx(float(_snapshot(fixture).get("distance", -1.0))),
		"Dispatched but undelivered nutrition funded growth")
	packet._physics_process(2.0)
	_check(fixture.supply.get_in_transit_count() == 0
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1,
		"Actual packet arrival did not enter the growth buffer")
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0
		and is_zero_approx(float(_snapshot(fixture).get("distance", -1.0))),
		"Arrival implicitly advanced growth")
	for investment: int in range(512):
		if not fixture.growth.has_active_task():
			break
		_dispatch_demand(fixture)
		_deliver_growth(fixture)
		fixture.growth.advance(1000.0)
	var snapshot: Dictionary = _snapshot(fixture)
	_check(StringName(snapshot.get("state", &"idle")) == &"completed", "Delivered growth did not complete")
	_check(int(snapshot.get("consumed_nutrition", -1)) == int(snapshot.get("total_cost", -2)),
		"Completed growth consumed a different amount from its plan")
	var junctions: Variant = snapshot.get("formed_junctions", 0)
	var junction_count: int = junctions.size() if junctions is Array else int(junctions)
	_check(junction_count > 0, "Completed growth formed no mature junction")
	_check(fixture.source.nutrition + int(snapshot.get("consumed_nutrition", 0)) == initial_balance,
		"Multi-segment growth accounting did not conserve nutrition")
	_check(fixture.supply.get_in_transit_count() == 0 and int(snapshot.get("buffered_nutrition", -1)) == 0,
		"Completed growth retained outstanding nutrition")
	_check(not _dispatch(fixture), "Completed growth accepted another shipment")
	_check_audit(fixture, "Real delivery")
	await _remove_fixture(fixture)


func _test_combat_reserve_and_battle_supply() -> void:
	var fixture: Fixture = _new_fixture(2 * SporeWeapon.SHOT_NUTRITION, 1)
	_create_target(fixture)
	_check(fixture.supply.get_combat_reserve() == 2 * SporeWeapon.SHOT_NUTRITION
		and fixture.supply.get_available_growth_nutrition() == 0,
		"Empty active organ did not reserve two shots")
	_check(not _dispatch(fixture) and fixture.source.nutrition == 2,
		"Growth spent the combat reserve")
	_check(StringName(_snapshot(fixture).get("wait_reason", &"")) == &"combat_reserve",
		"Combat reserve did not explain blocked growth")
	_check(fixture.battle.get_in_transit_count() == 0 and fixture.organs[0].incoming_nutrition == 0,
		"Growth supply dispatched battle packets or reserved organ capacity")
	_check(fixture.battle.request_supply(fixture.organs[0]), "Battle supply failed while growth was blocked")
	_check(fixture.battle.request_supply(fixture.organs[0]), "Second reserved battle shot could not dispatch")
	_freeze_packets(fixture)
	_check(fixture.supply.get_combat_reserve() == 0 and fixture.source.nutrition == 0,
		"Already-paid combat arrivals were reserved twice")
	fixture.source.add_nutrition(1)
	_check(_dispatch(fixture), "Growth could not use balance above already-paid combat reserve")
	_check(fixture.battle.get_in_transit_count() == 2
		and fixture.organs[0].incoming_nutrition == 2, "Growth changed battle transport ownership")
	for child: Node in fixture.packets.get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			(child as NutrientPacket)._physics_process(1000.0)
	_check(fixture.organs[0].nutrition == 2 and fixture.organs[0].incoming_nutrition == 0,
		"Battle packets did not retain normal delivery behavior")
	fixture.growth.cancel_task()
	_check(fixture.source.nutrition == 1 and fixture.organs[0].nutrition == 2,
		"Growth cancellation refunded combat stock or lost its own buffer")
	await _remove_fixture(fixture)


func _test_paid_incoming_and_growth_balance() -> void:
	var fixture: Fixture = _new_fixture(5, 1)
	_create_target(fixture)
	_check(fixture.battle.request_supply(fixture.organs[0]), "Paid incoming first combat dispatch")
	_check(fixture.battle.request_supply(fixture.organs[0]), "Paid incoming second combat dispatch")
	_freeze_packets(fixture)
	_check(fixture.source.nutrition == 3 and fixture.supply.get_combat_reserve() == 0
		and fixture.supply.get_available_growth_nutrition() == 3,
		"Paid organ incoming reduced available growth twice")
	_check(_dispatch(fixture), "Growth balance fixture dispatch failed")
	_check(fixture.source.nutrition == 2 and fixture.supply.get_in_transit_count() == 1
		and fixture.supply.get_available_growth_nutrition() == 2,
		"Growth in-transit nutrition was subtracted from core balance twice")
	fixture.growth.cancel_task()
	_check(fixture.source.nutrition == 3 and fixture.organs[0].incoming_nutrition == 2,
		"Growth cancellation changed already-paid organ incoming")
	await _remove_fixture(fixture)


func _test_paused_transit() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	_check(_dispatch(fixture), "Paused transit initial dispatch")
	_check(fixture.growth.pause_task(), "Pause active growth failed")
	_check(not _dispatch(fixture) and fixture.source.nutrition == 99, "Pause permitted a new debit")
	_deliver_growth(fixture)
	fixture.growth.advance(100.0)
	var snapshot: Dictionary = _snapshot(fixture)
	_check(StringName(snapshot.get("state", &"idle")) == &"paused"
		and int(snapshot.get("buffered_nutrition", -1)) == 1,
		"Paused in-flight delivery was discarded instead of buffered")
	_check(int(snapshot.get("consumed_nutrition", -1)) == 0
		and is_zero_approx(float(snapshot.get("distance", -1.0))), "Paused delivery funded movement")
	_check(fixture.growth.resume_task(), "Resume buffered growth failed")
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1,
		"Resume implicitly consumed the frozen buffer")
	fixture.growth.cancel_task()
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
		"Paused delivered buffer did not refund once on cancellation")
	_check(int(fixture.last_supply_snapshot.get("delivered", -1)) == 1
		and int(fixture.last_supply_snapshot.get("refunded", -1)) == 1,
		"Paused arrival/refund counters are incorrect")
	await _remove_fixture(fixture)


func _test_route_loss_and_recovery() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	_check(_dispatch(fixture), "Disconnected fixture initial dispatch")
	var packet: NutrientPacket = _first_packet(fixture)
	var old_id: int = int(fixture.supply.get_shipment_records()[0].get("shipment_id", 0))
	fixture.network.unregister_edge(fixture.edges[0])
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet._physics_process(1.0)
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
		"Broken physical route failed to interrupt and refund")
	_check(not _dispatch(fixture) and StringName(_snapshot(fixture).get("wait_reason", &"")) == &"disconnected",
		"Disconnected task dispatched or lacked its waiting reason")
	fixture.growth.advance(100.0)
	_check(is_zero_approx(float(_snapshot(fixture).get("distance", -1.0))),
		"Disconnected growth moved without delivered nutrition")
	_check(fixture.network.register_edge(fixture.edges[0]), "Restore lost route failed")
	_check(_dispatch(fixture), "Recovered route did not retry growth supply")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(int(records.back().get("shipment_id", 0)) > old_id, "Retry reused the interrupted shipment identifier")
	_deliver_growth(fixture)
	fixture.growth.cancel_task()
	_check(fixture.source.nutrition == 100 and int(fixture.last_supply_snapshot.get("refunded", -1)) == 2,
		"Recovered route cancellation did not conserve both debits")
	_check_audit(fixture, "Route recovery")
	await _remove_fixture(fixture)


func _test_cancelled_buffer_source_identity() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	var sent: int = _dispatch_demand(fixture)
	_check(sent > 0, "Buffer source fixture dispatched no investment")
	_deliver_growth(fixture)
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == sent,
		"Delivered investment was not held before advance")
	var replacement: MotherCore = CORE_SCENE.instantiate() as MotherCore
	replacement.initial_nutrition = 23
	replacement.position = Vector2(0.0, 80.0)
	fixture.scene.add_child(replacement)
	fixture.supply.mother_core = replacement
	var new_network: NetworkSystem = NetworkSystem.new()
	fixture.scene.add_child(new_network)
	fixture.supply.network_system = new_network
	_check(fixture.growth.cancel_task(), "Buffered task cancellation failed")
	_check(fixture.source.nutrition == 100 and replacement.nutrition == 23,
		"Unspent buffer refund followed the exported replacement source")
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0
		and fixture.growth.take_unspent_nutrition(fixture.task_id) == 0,
		"Cancellation failed to clear buffer before refund or drained twice")
	fixture.growth.cancel_task()
	fixture.supply.reset()
	_check(fixture.source.nutrition == 100 and replacement.nutrition == 23,
		"Repeated terminal cleanup duplicated a buffer refund")
	await _remove_fixture(fixture)


func _test_cancel_arrival_orders() -> void:
	for arrival_first: bool in [false, true]:
		var fixture: Fixture = _new_fixture(100)
		_create_target(fixture)
		_check(_dispatch(fixture), "Cancellation order dispatch")
		var packet: NutrientPacket = _first_packet(fixture)
		if packet == null:
			await _remove_fixture(fixture)
			continue
		if arrival_first:
			packet._physics_process(1000.0)
		fixture.growth.cancel_task()
		packet.arrived.emit(packet)
		packet.interrupted.emit(packet)
		packet.cancel_transport()
		packet.cancel_transport()
		packet.tree_exiting.emit()
		fixture.growth.cancel_task()
		_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
			"Same-frame cancellation/arrival order changed conserved nutrition")
		_check(int(fixture.last_supply_snapshot.get("delivered", -1)) == (1 if arrival_first else 0)
			and int(fixture.last_supply_snapshot.get("refunded", -1)) == 1,
			"Duplicate terminal events changed arrival or refund counters")
		_check_audit(fixture, "Cancellation event order")
		await _remove_fixture(fixture)


func _cancel_on_buffer(snapshot: Dictionary, growth: GrowthSystem, trigger: Trigger) -> void:
	if not trigger.fired and int(snapshot.get("buffered_nutrition", 0)) > 0:
		trigger.fired = true
		growth.cancel_task()


func _test_cancel_during_receive() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	_check(_dispatch(fixture), "Receive reentry dispatch")
	var trigger: Trigger = Trigger.new()
	fixture.growth.task_changed.connect(_cancel_on_buffer.bind(fixture.growth, trigger))
	_deliver_growth(fixture)
	_check(trigger.fired and fixture.source.nutrition == 100
		and fixture.supply.get_in_transit_count() == 0, "Receive signal cancellation lost the newly accepted buffer")
	_check(StringName(_snapshot(fixture).get("state", &"idle")) == &"cancelled"
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0,
		"Receive reentry left a live task or uncleared buffer")
	_check(int(fixture.last_supply_snapshot.get("delivered", -1)) == 1
		and int(fixture.last_supply_snapshot.get("refunded", -1)) == 1,
		"Receive reentry did not settle the accepted arrival once")
	await _remove_fixture(fixture)


func _cancel_on_debit(_balance: int, growth: GrowthSystem, trigger: Trigger) -> void:
	if not trigger.fired:
		trigger.fired = true
		growth.cancel_task()


func _test_cancel_during_debit() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	var trigger: Trigger = Trigger.new()
	fixture.source.nutrition_changed.connect(_cancel_on_debit.bind(fixture.growth, trigger))
	_check(not _dispatch(fixture), "Debit signal cancellation reported an active shipment")
	_check(trigger.fired and fixture.source.nutrition == 100
		and fixture.supply.get_in_transit_count() == 0,
		"Cancellation inside source debit failed to refund synchronously")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(records.size() == 1 and bool(records[0].get("debited", false))
		and bool(records[0].get("settled", false)) and bool(records[0].get("refunded", false)),
		"Debit reentry happened before the audit record was committed")
	await _remove_fixture(fixture)


func _queue_on_debit(_balance: int, node: Node, trigger: Trigger) -> void:
	if not trigger.fired:
		trigger.fired = true
		node.queue_free()


func _test_queue_during_debit() -> void:
	for queue_receiver: bool in [false, true]:
		var fixture: Fixture = _new_fixture(100)
		_create_target(fixture)
		var trigger: Trigger = Trigger.new()
		var target: Node = fixture.growth if queue_receiver else fixture.source
		fixture.source.nutrition_changed.connect(_queue_on_debit.bind(target, trigger))
		_check(not _dispatch(fixture), "Queued source/receiver permitted transport after debit")
		_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
			"Queued source/receiver debit leaked a payment")
		for record: Dictionary in fixture.supply.get_shipment_records():
			_check(bool(record.get("settled", false)), "Queued debit left an unsettled record")
		await process_frame
		await process_frame
		_check(not is_instance_valid(target), "Debit queue target failed to exit")
		fixture.supply.reset()
		_check(fixture.supply.get_in_transit_count() == 0, "Queued debit cleanup retained a shipment")
		await _remove_fixture(fixture)


func _cancel_on_packet_added(_node: Node, growth: GrowthSystem, trigger: Trigger) -> void:
	if not trigger.fired:
		trigger.fired = true
		growth.cancel_task()


func _test_cancel_before_debit() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	var trigger: Trigger = Trigger.new()
	fixture.packets.child_entered_tree.connect(_cancel_on_packet_added.bind(fixture.growth, trigger))
	_check(not _dispatch(fixture), "Packet add callback cancellation dispatched")
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
		"Cancellation before debit manufactured a refund")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(records.size() == 1 and not bool(records[0].get("debited", true))
		and bool(records[0].get("settled", false)), "Pre-debit cancellation audit is incorrect")
	_check(int(fixture.last_supply_snapshot.get("refunded", -1)) == 0,
		"Pre-debit cancellation counted a nonexistent payment as refunded")
	await _remove_fixture(fixture)


func _test_reset_restart_and_stale_callbacks() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	var old_task_id: int = fixture.task_id
	_check(_dispatch(fixture), "Reset fixture dispatch")
	var old_packet: NutrientPacket = _first_packet(fixture)
	var old_shipment_id: int = int(fixture.supply.get_shipment_records()[0].get("shipment_id", 0))
	fixture.supply.reset()
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0
		and fixture.supply.get_shipment_records().is_empty(), "Reset did not refund and clear its old ledger")
	_check(int(fixture.last_supply_snapshot.get("delivered", -1)) == 0
		and int(fixture.last_supply_snapshot.get("refunded", -1)) == 0, "Reset retained old counters")
	_create_target(fixture)
	_check(fixture.task_id > old_task_id and _dispatch(fixture), "Reset could not start a new growth task")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(records.size() == 1 and int(records[0].get("shipment_id", 0)) > old_shipment_id,
		"Reset recycled a shipment identifier")
	if is_instance_valid(old_packet):
		old_packet.arrived.emit(old_packet)
		old_packet.interrupted.emit(old_packet)
		old_packet.tree_exiting.emit()
	_check(fixture.source.nutrition == 99 and fixture.supply.get_in_transit_count() == 1,
		"Old callbacks settled or refunded a new task's packet")
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0,
		"Old callback delivered nutrition into the new task")
	_deliver_growth(fixture)
	fixture.supply.reset()
	fixture.supply.reset()
	_check(fixture.source.nutrition == 100 and fixture.supply.get_shipment_records().is_empty(),
		"Reset after accepted buffer was not once-only")
	await _remove_fixture(fixture)


func _test_direct_packet_removal() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	_check(_dispatch(fixture), "Forced packet removal dispatch")
	var packet: NutrientPacket = _first_packet(fixture)
	if packet != null:
		packet.queue_free()
	await process_frame
	await process_frame
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
		"Packet tree exit did not settle and refund")
	_check(_dispatch(fixture), "Packet removal blocked a later real retry")
	fixture.growth.cancel_task()
	_check(fixture.source.nutrition == 100, "Forced removal retry cancellation lost nutrition")
	await _remove_fixture(fixture)


func _test_synchronous_zero_length_delivery() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture, fixture.source)
	var target: Node2D = fixture.growth.get_delivery_target(fixture.task_id)
	var route: NetworkRoute = fixture.network.find_route(fixture.source, target)
	_check(route.found and fixture.source.global_position == target.global_position,
		"Synchronous route fixture does not have a zero-length growing edge")
	_check(_dispatch(fixture), "Synchronous real arrival was treated as dispatch failure")
	_check(fixture.source.nutrition == 99 and fixture.supply.get_in_transit_count() == 0
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1,
		"Synchronous start_route completed before accounting was recorded")
	_check(is_zero_approx(float(_snapshot(fixture).get("distance", -1.0))),
		"Synchronous zero-length packet implicitly advanced growth")
	fixture.growth.cancel_task()
	_check(fixture.source.nutrition == 100 and int(fixture.last_supply_snapshot.get("refunded", -1)) == 1,
		"Synchronous buffer cancellation refunded incorrectly")
	await _remove_fixture(fixture)


func _test_interval_and_configuration() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	fixture.supply.auto_supply = true
	fixture.supply._process(0.34)
	_check(fixture.source.nutrition == 100, "Automatic growth supply dispatched before its interval")
	fixture.supply._process(0.02)
	_freeze_packets(fixture)
	_check(fixture.source.nutrition == 99 and fixture.supply.get_in_transit_count() == 1,
		"Automatic growth supply did not dispatch at its interval")
	fixture.supply.reset()
	fixture.supply.auto_supply = false
	_create_target(fixture)
	fixture.supply.packet_scene = CORE_SCENE
	_check(not _dispatch(fixture) and fixture.source.nutrition == 100,
		"Wrong packet scene debited growth nutrition")
	_check(StringName(_snapshot(fixture).get("wait_reason", &"")) == &"invalid_configuration",
		"Wrong packet scene did not report invalid configuration")
	fixture.supply.packet_scene = PACKET_SCENE
	fixture.supply.packet_container = null
	_check(not _dispatch(fixture) and fixture.source.nutrition == 100,
		"Missing packet container debited growth nutrition")
	fixture.supply.packet_container = fixture.packets
	_check(_dispatch(fixture), "Restored configuration did not retry growth supply")
	fixture.growth.cancel_task()
	fixture.source.nutrition = 0
	_create_target(fixture)
	_check(not _dispatch(fixture) and StringName(_snapshot(fixture).get("wait_reason", &"")) == &"core_empty",
		"Empty core did not report the correct growth wait reason")
	await _remove_fixture(fixture)


func _test_supply_exit() -> void:
	var fixture: Fixture = _new_fixture(100)
	_create_target(fixture)
	_check(_dispatch(fixture), "Supply exit fixture dispatch")
	var supply: GrowthSupplySystem = fixture.supply
	fixture.scene.remove_child(supply)
	_check(fixture.source.nutrition == 100 and not fixture.growth.has_active_task(),
		"Growth supply tree exit did not cancel task and refund pending transit")
	_check(supply.get_in_transit_count() == 0 and supply.get_shipment_records().is_empty(),
		"Exited growth supply retained an unsettled ledger")
	supply.free()
	await _remove_fixture(fixture)
