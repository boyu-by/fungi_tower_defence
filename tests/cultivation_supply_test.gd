extends SceneTree
## 培育物流使用真实包、真实网络和真实培育状态；手动推进，独立验证付款与退款。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")

class Fixture:
	extends RefCounted

	var scene: Node2D
	var source: MotherCore
	var extra_sources: Array[MotherCore] = []
	var hub: HyphaNode
	var host: HyphaNode
	var edges: Array[HyphaEdge] = []
	var network: NetworkSystem
	var cultivation: CultivationSystem
	var supply: CultivationSupplySystem
	var battle: SupplySystem
	var organs: Array[AttackOrgan] = []
	var mature_organ: AttackOrgan
	var packets: Node2D
	var task_id: int = 0
	var initial_total: int = 0
	var shot_consumption: int = 0
	var recovery_events: int = 0
	var maturations: int = 0
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
	await _test_real_delivery_demand_and_maturity()
	await _test_combat_reserve_and_already_paid_transit()
	await _test_pause_and_route_loss()
	await _test_fifo_sources_and_continuation_baseline()
	await _test_startup_reservations_refund()
	await _test_maturity_interrupted_before_commit()
	await _test_captured_configuration()
	await _test_cancel_arrival_orders()
	await _test_synchronous_callbacks()
	await _test_removal_and_exit()
	await _test_reset_and_stale_callbacks()
	await _test_synchronous_route_and_unique_ids()
	await _test_interval_funds_and_configuration()
	_check(root.get_child_count() == initial_children, "Cultivation supply fixtures left root children")
	print("CULTIVATION_SUPPLY_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(balance: int = 100, organ_count: int = 0,
		local_stock: int = 0) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.scene = Node2D.new()
	root.add_child(fixture.scene)
	fixture.source = CORE_SCENE.instantiate() as MotherCore
	fixture.source.initial_nutrition = balance
	fixture.scene.add_child(fixture.source)
	fixture.hub = NODE_SCENE.instantiate() as HyphaNode
	fixture.hub.position = Vector2(80.0, 0.0)
	fixture.scene.add_child(fixture.hub)
	fixture.host = NODE_SCENE.instantiate() as HyphaNode
	fixture.host.position = Vector2(160.0, 0.0)
	fixture.scene.add_child(fixture.host)
	fixture.network = NetworkSystem.new()
	fixture.scene.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.source, true), "Fixture core registration")
	_check(fixture.network.register_node(fixture.hub), "Fixture hub registration")
	_check(fixture.network.register_node(fixture.host), "Fixture host registration")
	fixture.edges.append(_new_edge(fixture, fixture.source, fixture.hub))
	# 第二段反向存储端点，运输必须实际走过双向网络的反向段。
	fixture.edges.append(_new_edge(fixture, fixture.host, fixture.hub))
	fixture.packets = _new_container(fixture.scene)
	fixture.cultivation = CultivationSystem.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.enemy_container = _new_container(fixture.scene)
	fixture.cultivation.projectile_container = _new_container(fixture.scene)
	fixture.scene.add_child(fixture.cultivation)
	fixture.cultivation.set_process(false)
	fixture.cultivation.set_physics_process(false)
	fixture.battle = SupplySystem.new()
	fixture.battle.mother_core = fixture.source
	fixture.battle.network_system = fixture.network
	fixture.battle.packet_container = fixture.packets
	fixture.battle.packet_scene = PACKET_SCENE
	fixture.scene.add_child(fixture.battle)
	for index: int in range(organ_count):
		var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
		organ.initial_nutrition = local_stock
		fixture.hub.add_child(organ)
		fixture.organs.append(organ)
		_check(fixture.battle.register_organ(organ), "Fixture combat organ " + str(index))
	fixture.supply = CultivationSupplySystem.new()
	fixture.supply.cultivation_system = fixture.cultivation
	fixture.supply.mother_core = fixture.source
	fixture.supply.network_system = fixture.network
	fixture.supply.combat_supply_system = fixture.battle
	fixture.supply.packet_container = fixture.packets
	fixture.supply.auto_supply = false
	fixture.supply.supply_changed.connect(_capture_supply.bind(fixture))
	fixture.scene.add_child(fixture.supply)
	fixture.supply.set_process(false)
	fixture.cultivation.organ_matured.connect(_capture_maturity.bind(fixture))
	fixture.source.digestion_product_arrived.connect(_capture_recovery.bind(fixture))
	fixture.initial_total = fixture.source.nutrition + organ_count * local_stock
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


func _add_source(fixture: Fixture, balance: int) -> MotherCore:
	var source: MotherCore = CORE_SCENE.instantiate() as MotherCore
	source.initial_nutrition = balance
	source.position = Vector2(0.0, 80.0)
	fixture.scene.add_child(source)
	_check(fixture.network.register_node(source), "Replacement payer registration")
	fixture.edges.append(_new_edge(fixture, source, fixture.hub))
	fixture.extra_sources.append(source)
	fixture.initial_total += balance
	source.digestion_product_arrived.connect(_capture_recovery.bind(fixture))
	return source


func _capture_supply(snapshot: Dictionary, fixture: Fixture) -> void:
	fixture.last_supply_snapshot = snapshot.duplicate()


func _capture_recovery(_product_id: String, _amount: int, fixture: Fixture) -> void:
	fixture.recovery_events += 1


func _capture_maturity(_task_id: int, host: HyphaNode, organ: AttackOrgan,
		weapon: SporeWeapon, fixture: Fixture) -> void:
	fixture.maturations += 1
	fixture.mature_organ = organ
	fixture.organs.append(organ)
	weapon.set_physics_process(false)
	_check(host == fixture.host, "Maturity changed the captured host")
	# 关卡的动态登记回调在此用同一个战斗供养 API 模拟。
	_check(fixture.battle.register_organ(organ), "Mature organ battle registration")


func _start(fixture: Fixture) -> void:
	fixture.task_id = fixture.cultivation.start_cultivation(fixture.host)
	_check(fixture.task_id > 0, "Cultivation start failed")


func _snapshot(fixture: Fixture) -> Dictionary:
	return fixture.cultivation.get_task_snapshot(fixture.task_id)


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
	var dispatched: bool = fixture.supply.try_dispatch()
	_freeze_packets(fixture)
	return dispatched


func _dispatch_demand(fixture: Fixture) -> int:
	var count: int = 0
	for attempt: int in range(16):
		if not _dispatch(fixture):
			break
		count += 1
	return count


func _first_packet(fixture: Fixture) -> NutrientPacket:
	var packets: Array[NutrientPacket] = _active_packets(fixture)
	_check(not packets.is_empty(), "Expected a real in-flight cultivation packet")
	return null if packets.is_empty() else packets[0]


func _deliver(fixture: Fixture) -> void:
	for packet: NutrientPacket in _active_packets(fixture):
		if is_instance_valid(packet) and not packet.is_queued_for_deletion():
			packet._physics_process(1000.0)


func _check_conservation(fixture: Fixture, context: String, draft_stock: int = 0) -> void:
	var accounted: int = fixture.source.nutrition + fixture.shot_consumption + draft_stock
	for source: MotherCore in fixture.extra_sources:
		accounted += source.nutrition
	var resources: Dictionary = fixture.cultivation.get_resource_snapshot()
	accounted += int(resources.get("structure_consumed", 0))
	accounted += int(resources.get("buffered_nutrition", 0))
	accounted += int(resources.get("startup_reserved", 0))
	accounted += fixture.supply.get_in_transit_nutrition()
	for organ: AttackOrgan in fixture.organs:
		accounted += organ.nutrition + organ.incoming_nutrition
	_check(accounted == fixture.initial_total, context + ": nutrition conservation failed")
	_check(fixture.recovery_events == 0, context + ": ordinary refund counted as recovered nutrition")


func _check_audit(fixture: Fixture, context: String) -> void:
	var previous_serial: int = 0
	var pending: int = 0
	for record: Dictionary in fixture.supply.get_shipment_records():
		var shipment_id: String = String(record.get("shipment_id", ""))
		var components: PackedStringArray = shipment_id.split(":")
		var valid_id: bool = components.size() == 3 and components[0] == "cultivation" \
			and components[1] == str(fixture.supply.get_instance_id())
		_check(valid_id, context + ": shipment ID lacks supply-instance identity")
		if valid_id:
			var serial: int = int(components[2])
			_check(serial > previous_serial, context + ": shipment serial was reused")
			previous_serial = serial
		_check(record.has("task_id") and record.has("source") and record.has("packet")
			and record.has("debited") and record.has("settled") and record.has("status")
			and record.has("accepted") and record.has("refunded") and record.has("buffered_nutrition"),
			context + ": required audit fields missing")
		if not bool(record.get("settled", false)):
			pending += 1
	_check(pending == fixture.supply.get_in_transit_count(), context + ": pending ledger mismatch")


func _check_dispatch_notification(_packet: Node, fixture: Fixture) -> void:
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(not records.is_empty() and not bool(records.back().get("debited", true)),
		"Packet entry notification did not expose the provisional pre-debit reservation")
	_check_conservation(fixture, "Pre-debit packet entry notification")


func _remove_fixture(fixture: Fixture) -> void:
	if is_instance_valid(fixture.supply):
		fixture.supply.reset()
	fixture.scene.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.scene), "Cultivation fixture teardown failed")


func _test_real_delivery_demand_and_maturity() -> void:
	var fixture: Fixture = _new_fixture()
	_start(fixture)
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
		"Creating a bud debited or dispatched synchronously")
	fixture.cultivation.advance(10.0)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Undelivered nutrition advanced cultivation")
	var route: NetworkRoute = fixture.network.find_route(fixture.source, fixture.host)
	_check(route.found and route.segments.size() == 2 and not route.segments[1].forward,
		"Cultivation transport bypassed the real mixed-direction route")
	fixture.packets.child_entered_tree.connect(_check_dispatch_notification.bind(fixture))
	_check(_dispatch(fixture), "First cultivation packet dispatch")
	var packet: NutrientPacket = _first_packet(fixture)
	if packet == null:
		await _remove_fixture(fixture)
		return
	packet.speed = 100.0
	packet._physics_process(0.5)
	_check(packet.global_position.distance_to(Vector2(50.0, 0.0)) < 0.001,
		"Real cultivation packet did not travel its first route segment")
	fixture.cultivation.advance(10.0)
	_check(fixture.source.nutrition == 99 and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Paid in-transit packet was accepted before actual arrival")
	_check(_dispatch_demand(fixture) == 11 and not _dispatch(fixture)
		and fixture.source.nutrition == 88 and fixture.supply.get_in_transit_nutrition() == 12,
		"Outstanding shipments did not cap the twelve-unit demand")
	_check(fixture.supply.get_available_cultivation_nutrition() == 88,
		"Cultivation transit was subtracted from the already-debited balance twice")
	fixture.packets.child_entered_tree.disconnect(_check_dispatch_notification.bind(fixture))
	_check_conservation(fixture, "In transit")
	_deliver(fixture)
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 12
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Arrival advanced cultivation or omitted a paid unit")
	fixture.cultivation.advance(2.99)
	_check(fixture.maturations == 0, "Organ matured before three effective seconds")
	fixture.cultivation.advance(0.02)
	var snapshot: Dictionary = _snapshot(fixture)
	_check(StringName(snapshot.get("state", &"idle")) == &"completed" and fixture.maturations == 1,
		"Fully funded cultivation did not mature exactly once")
	_check(int(snapshot.get("structure_consumed", -1)) == 8
		and int(snapshot.get("startup_transferred", -1)) == 4
		and int(snapshot.get("consumed_nutrition", -1)) == 12
		and int(snapshot.get("startup_reserved", -1)) == 0,
		"Maturity did not separate sunk structure from transferred startup inventory")
	_check(is_instance_valid(fixture.mature_organ) and fixture.mature_organ.nutrition == 4,
		"Mature organ failed to receive exactly the paid startup stock")
	_check(not _dispatch(fixture) and fixture.supply.get_in_transit_count() == 0,
		"Mature task kept dispatching cultivation nutrition")
	for record: Dictionary in fixture.supply.get_shipment_records():
		_check(int(record.get("buffered_nutrition", -1)) == 0 and not bool(record.get("refunded", true)),
			"Maturity kept a refundable startup lot or refunded actual consumed stock")
	_check_conservation(fixture, "Maturity")
	_check(fixture.mature_organ.consume_nutrition(3), "Mature stock consumption fixture")
	fixture.shot_consumption += 3
	_check(fixture.battle.request_supply(fixture.mature_organ), "Existing battle supply did not take over")
	_freeze_packets(fixture)
	for child: Node in fixture.packets.get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			(child as NutrientPacket)._physics_process(1000.0)
	_check(fixture.mature_organ.nutrition == 2 and not _dispatch(fixture),
		"Battle delivery changed the completed cultivation task")
	_check_conservation(fixture, "Battle takeover")
	_check_audit(fixture, "Real delivery")
	await _remove_fixture(fixture)


func _test_combat_reserve_and_already_paid_transit() -> void:
	var fixture: Fixture = _new_fixture(5, 2, 0)
	_start(fixture)
	_check(fixture.supply.get_combat_reserve() == 2 * (fixture.organs[0].get_shot_nutrition_cost()
		+ fixture.organs[1].get_shot_nutrition_cost())
		and fixture.supply.get_available_cultivation_nutrition() == 1,
		"Combat reserve did not sum two shots for every active organ")
	_check(_dispatch(fixture) and not _dispatch(fixture) and fixture.source.nutrition == 4,
		"Cultivation spent below the battle reserve")
	_check(StringName(_snapshot(fixture).get("wait_reason", &"")) == &"in_transit",
		"Outstanding cultivation packet did not explain waiting")
	fixture.cultivation.cancel_task()
	fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host)
	_check(fixture.task_id > 0, "Continue reserve fixture")
	for organ: AttackOrgan in fixture.organs:
		_check(fixture.battle.request_supply(organ) and fixture.battle.request_supply(organ),
			"Battle could not use its reserved shots")
	_freeze_packets(fixture)
	_check(fixture.source.nutrition == 1 and fixture.supply.get_combat_reserve() == 0
		and fixture.supply.get_available_cultivation_nutrition() == 1,
		"Already-paid battle incoming was reserved twice")
	_check(_dispatch(fixture) and not _dispatch(fixture) and fixture.source.nutrition == 0,
		"Available balance overspent after battle dispatch")
	_check(fixture.battle.get_in_transit_count() == 4,
		"Cultivation altered battle shipment ownership")
	fixture.cultivation.cancel_task()
	_check(fixture.source.nutrition == 1 and fixture.organs[0].incoming_nutrition == 2,
		"Cultivation cancellation refunded or discarded battle incoming")
	_check_conservation(fixture, "Combat reserve")
	await _remove_fixture(fixture)


func _test_pause_and_route_loss() -> void:
	var fixture: Fixture = _new_fixture()
	_start(fixture)
	_check(_dispatch(fixture) and fixture.cultivation.pause_task(), "Pause with paid transit")
	_check(not _dispatch(fixture) and fixture.source.nutrition == 99, "Paused task dispatched a new payment")
	_deliver(fixture)
	fixture.cultivation.advance(10.0)
	_check(StringName(_snapshot(fixture).get("state", &"idle")) == &"paused"
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Paused arrival was lost or consumed before resume")
	_check(fixture.cultivation.resume_task() and _dispatch(fixture), "Resume did not retain demand")
	fixture.network.unregister_edge(fixture.edges[0])
	_check(fixture.supply.get_in_transit_count() == 0 and fixture.source.nutrition == 99,
		"Route loss did not refund only the undelivered packet")
	_check(not _dispatch(fixture)
		and StringName(_snapshot(fixture).get("wait_reason", &"")) == &"disconnected",
		"Disconnected cultivation dispatched or lost its wait reason")
	fixture.cultivation.advance(10.0)
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Disconnected cultivation consumed its previously delivered buffer")
	_check(fixture.network.register_edge(fixture.edges[0]) and _dispatch(fixture), "Route recovery failed")
	_deliver(fixture)
	fixture.cultivation.cancel_task()
	_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
		"Paused arrivals and route retry did not refund once")
	_check_conservation(fixture, "Pause and route loss")
	await _remove_fixture(fixture)


func _test_fifo_sources_and_continuation_baseline() -> void:
	var fixture: Fixture = _new_fixture(30)
	_start(fixture)
	for index: int in range(5):
		_check(_dispatch(fixture), "Original payer FIFO dispatch")
	_deliver(fixture)
	var replacement: MotherCore = _add_source(fixture, 23)
	fixture.supply.mother_core = replacement
	for index: int in range(3):
		_check(_dispatch(fixture), "Replacement payer FIFO dispatch")
	_deliver(fixture)
	fixture.cultivation.advance(0.5)
	var consumed: int = int(_snapshot(fixture).get("consumed_nutrition", 0))
	_check(consumed > 0 and consumed < 5, "FIFO fixture did not consume only older paid lots")
	var old_task_id: int = fixture.task_id
	fixture.cultivation.cancel_task()
	_check(fixture.source.nutrition == 30 - consumed and replacement.nutrition == 23,
		"FIFO refund followed replacement configuration or refunded sunk structure")
	_check(fixture.cultivation.take_unspent_nutrition(old_task_id) == 0,
		"Terminal refundable buffer was not atomically drained")
	fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host)
	_check(fixture.task_id > old_task_id and _dispatch_demand(fixture) == 12 - consumed,
		"Continuation reused task identity or charged its already-paid structure again")
	_deliver(fixture)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == consumed,
		"New arrivals consumed the historical structure baseline")
	fixture.cultivation.cancel_task()
	_check(replacement.nutrition == 23 and fixture.source.nutrition == 30 - consumed,
		"Continuation baseline retired newly paid refundable lots")
	var old_snapshot: Dictionary = fixture.cultivation.get_task_snapshot(old_task_id)
	_check(int(old_snapshot.get("consumed_nutrition", -1)) == consumed
		and StringName(old_snapshot.get("state", &"idle")) == &"cancelled",
		"Old task audit followed a new continuation attempt")
	_check_conservation(fixture, "FIFO and continuation")
	_check_audit(fixture, "FIFO sources")
	await _remove_fixture(fixture)


func _test_startup_reservations_refund() -> void:
	var fixture: Fixture = _new_fixture(16)
	_start(fixture)
	for index: int in range(8):
		_check(_dispatch(fixture), "Structure-only dispatch")
	_deliver(fixture)
	fixture.cultivation.advance(3.1)
	_check(int(_snapshot(fixture).get("structure_consumed", -1)) == 8
		and fixture.maturations == 0, "Structure-only task did not wait for paid startup stock")
	for index: int in range(3):
		_check(_dispatch(fixture), "Incomplete startup dispatch")
	_deliver(fixture)
	fixture.cultivation.advance(0.1)
	_check(int(_snapshot(fixture).get("startup_reserved", -1)) == 3
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 8,
		"Startup reserve was not held separately from actual consumption")
	_check(_dispatch(fixture), "Last startup in-flight dispatch")
	_check_conservation(fixture, "Startup reservation")
	fixture.cultivation.cancel_task()
	_check(fixture.source.nutrition == 8
		and int(_snapshot(fixture).get("startup_reserved", -1)) == 0
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0,
		"Cancellation failed to refund startup reserve and transit while retaining structure")
	_check(int(fixture.supply.get_supply_snapshot().get("refunded", -1)) == 4,
		"Startup ownership transition retired still-refundable source lots")
	_check_conservation(fixture, "Cancelled startup")
	await _remove_fixture(fixture)


func _interrupt_maturity(child: Node, fixture: Fixture, trigger: Trigger) -> void:
	if trigger.fired or not child is AttackOrgan:
		return
	trigger.fired = true
	var draft: AttackOrgan = child as AttackOrgan
	var snapshot: Dictionary = _snapshot(fixture)
	_check(int(snapshot.get("consumed_nutrition", -1)) == 8
		and StringName(snapshot.get("state", &"idle")) != &"completed",
		"Provisional child entry irreversibly retired refundable startup lots")
	_check(draft.process_mode == Node.PROCESS_MODE_DISABLED and draft.nutrition == 4,
		"Provisional startup inventory was active or did not match its paid allocation")
	_check_conservation(fixture, "Disabled maturity draft", draft.nutrition)
	fixture.supply.mother_core = fixture.source
	fixture.host.queue_free()
	# 排队删除后立即查询网络，使 network_changed 在成熟事务内触发供给账本扫描。
	fixture.network.get_registered_nodes()


func _test_maturity_interrupted_before_commit() -> void:
	var fixture: Fixture = _new_fixture(16)
	_start(fixture)
	for index: int in range(8):
		_check(_dispatch(fixture), "Interrupted maturity structure dispatch")
	_deliver(fixture)
	fixture.cultivation.advance(3.1)
	var replacement: MotherCore = _add_source(fixture, 23)
	fixture.supply.mother_core = replacement
	_check(_dispatch_demand(fixture) == 4, "Replacement payer did not fund startup exactly once")
	_deliver(fixture)
	var trigger: Trigger = Trigger.new()
	fixture.host.child_entered_tree.connect(_interrupt_maturity.bind(fixture, trigger))
	fixture.cultivation.advance(0.1)
	var snapshot: Dictionary = _snapshot(fixture)
	_check(trigger.fired and fixture.maturations == 0
		and StringName(snapshot.get("state", &"idle")) == &"cancelled",
		"Interrupted sibling/slot handoff completed or left an active cultivation task")
	_check(int(snapshot.get("consumed_nutrition", -1)) == 8
		and int(snapshot.get("startup_transferred", -1)) == 0
		and int(snapshot.get("startup_reserved", -1)) == 0,
		"Maturity rollback lost or irreversibly consumed the startup budget")
	_check(fixture.source.nutrition == 8 and replacement.nutrition == 23
		and int(fixture.supply.get_supply_snapshot().get("refunded", -1)) == 4,
		"Provisional maturity rollback did not refund original startup payer exactly four units")
	_check_conservation(fixture, "Interrupted maturity refund")
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.host), "Interrupted maturity host removal did not finish")
	await _remove_fixture(fixture)


func _test_captured_configuration() -> void:
	var fixture: Fixture = _new_fixture()
	_start(fixture)
	_check(_dispatch(fixture), "Captured transport dispatch")
	var replacement: MotherCore = _add_source(fixture, 23)
	var replacement_network: NetworkSystem = NetworkSystem.new()
	fixture.scene.add_child(replacement_network)
	fixture.supply.mother_core = replacement
	fixture.supply.network_system = replacement_network
	fixture.supply.cultivation_system = null
	_deliver(fixture)
	_check(int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1,
		"In-flight arrival followed exported replacement receiver or network")
	fixture.cultivation.cancel_task()
	_check(fixture.source.nutrition == 100 and replacement.nutrition == 23,
		"Captured shipment refunded the configured replacement payer")
	_check_conservation(fixture, "Captured configuration")
	await _remove_fixture(fixture)


func _test_cancel_arrival_orders() -> void:
	for arrival_first: bool in [false, true]:
		var fixture: Fixture = _new_fixture()
		_start(fixture)
		_check(_dispatch(fixture), "Cancellation order dispatch")
		var packet: NutrientPacket = _first_packet(fixture)
		if packet == null:
			await _remove_fixture(fixture)
			continue
		if arrival_first:
			packet._physics_process(1000.0)
		fixture.cultivation.cancel_task()
		packet.arrived.emit(packet)
		packet.interrupted.emit(packet)
		packet.cancel_transport()
		packet.tree_exiting.emit()
		fixture.cultivation.cancel_task()
		_check(fixture.source.nutrition == 100 and fixture.supply.get_in_transit_count() == 0,
			"Cancellation/arrival order or duplicate callbacks changed the refund")
		var snapshot: Dictionary = fixture.supply.get_supply_snapshot()
		_check(int(snapshot.get("delivered", -1)) == (1 if arrival_first else 0)
			and int(snapshot.get("refunded", -1)) == 1,
			"Replayed terminal callbacks changed delivery/refund counters")
		_check_conservation(fixture, "Cancellation order")
		await _remove_fixture(fixture)


func _cancel_on_buffer(snapshot: Dictionary, cultivation: CultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired and int(snapshot.get("buffered_nutrition", 0)) > 0:
		trigger.fired = true
		cultivation.cancel_task()


func _cancel_on_debit(_balance: int, cultivation: CultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired:
		trigger.fired = true
		cultivation.cancel_task()


func _reset_on_debit(_balance: int, supply: CultivationSupplySystem, trigger: Trigger) -> void:
	if not trigger.fired:
		trigger.fired = true
		supply.reset()


func _cancel_on_packet_added(_packet: Node, cultivation: CultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired:
		trigger.fired = true
		cultivation.cancel_task()


func _test_synchronous_callbacks() -> void:
	for phase: String in ["receive", "debit", "reset", "before_debit"]:
		var fixture: Fixture = _new_fixture()
		_start(fixture)
		var trigger: Trigger = Trigger.new()
		match phase:
			"receive":
				fixture.cultivation.task_changed.connect(_cancel_on_buffer.bind(fixture.cultivation, trigger))
			"debit":
				fixture.source.nutrition_changed.connect(_cancel_on_debit.bind(fixture.cultivation, trigger))
			"reset":
				fixture.source.nutrition_changed.connect(_reset_on_debit.bind(fixture.supply, trigger))
			"before_debit":
				fixture.packets.child_entered_tree.connect(_cancel_on_packet_added.bind(fixture.cultivation, trigger))
		var dispatched: bool = _dispatch(fixture)
		if phase == "receive":
			_check(dispatched, "Receive reentry fixture dispatch failed")
			_deliver(fixture)
		else:
			_check(not dispatched, phase + ": terminal callback reported live transport")
		_check(trigger.fired and fixture.source.nutrition == 100
			and fixture.supply.get_in_transit_count() == 0
			and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0,
			phase + ": synchronous callback lost payment or newly accepted buffer")
		var snapshot: Dictionary = fixture.supply.get_supply_snapshot()
		var expected_refunds: int = 0 if phase == "before_debit" or phase == "reset" else 1
		_check(int(snapshot.get("refunded", -1)) == expected_refunds,
			phase + ": callback refunded a nonexistent debit or duplicated a real refund")
		if phase == "receive":
			_check(int(snapshot.get("delivered", -1)) == 1,
				"Accepted arrival cancelled during receive was not counted once")
		_check_conservation(fixture, "Synchronous " + phase)
		await _remove_fixture(fixture)


func _test_removal_and_exit() -> void:
	for removed: String in ["host", "source", "receiver", "packet", "supply"]:
		var fixture: Fixture = _new_fixture()
		_start(fixture)
		for index: int in range(2):
			_check(_dispatch(fixture), "Removal refundable-buffer dispatch")
		_deliver(fixture)
		fixture.cultivation.advance(0.1)
		var consumed: int = int(_snapshot(fixture).get("consumed_nutrition", 0))
		_check(consumed == 1 and _dispatch(fixture), "Removal partial structure/transit setup")
		var target: Node
		match removed:
			"host":
				target = fixture.host
			"source":
				target = fixture.source
			"receiver":
				target = fixture.cultivation
			"packet":
				target = _first_packet(fixture)
			"supply":
				target = fixture.supply
		if target == null:
			await _remove_fixture(fixture)
			continue
		# 移出树同步验证退出结算；只 queue_free，避免释放正在发信号的对象。
		target.get_parent().remove_child(target)
		if removed == "packet":
			_check(fixture.source.nutrition == 98 and fixture.supply.get_in_transit_count() == 0,
				"Packet exit refunded the delivered buffer or retained transit")
			fixture.cultivation.cancel_task()
		_check(fixture.source.nutrition == 100 - consumed
			and fixture.supply.get_in_transit_count() == 0,
			removed + ": lifecycle removal lost refundable funds or refunded sunk structure")
		_check(fixture.recovery_events == 0, removed + ": removal refund counted as recovery")
		target.queue_free()
		await process_frame
		await process_frame
		_check(not is_instance_valid(target), removed + ": removed node was not freed")
		await _remove_fixture(fixture)


func _test_reset_and_stale_callbacks() -> void:
	var fixture: Fixture = _new_fixture()
	_start(fixture)
	var old_task_id: int = fixture.task_id
	_check(_dispatch(fixture), "Reset fixture dispatch")
	var old_packet: NutrientPacket = _first_packet(fixture)
	var old_id: String = String(fixture.supply.get_shipment_records()[0].get("shipment_id", ""))
	fixture.supply.reset()
	_check(fixture.source.nutrition == 100 and fixture.supply.get_shipment_records().is_empty(),
		"Reset did not return payment and clear audit records")
	fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host)
	_check(fixture.task_id > old_task_id and _dispatch(fixture), "Reset/continue did not use a new attempt")
	var new_id: String = String(fixture.supply.get_shipment_records()[0].get("shipment_id", ""))
	_check(new_id != old_id and int(new_id.get_slice(":", 2)) > int(old_id.get_slice(":", 2)),
		"Reset reused a shipment serial")
	if is_instance_valid(old_packet):
		old_packet.arrived.emit(old_packet)
		old_packet.interrupted.emit(old_packet)
		old_packet.tree_exiting.emit()
	_check(fixture.source.nutrition == 99 and fixture.supply.get_in_transit_count() == 1
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0,
		"Stale callbacks delivered or refunded a new task's shipment")
	_deliver(fixture)
	fixture.supply.reset()
	fixture.supply.reset()
	_check(fixture.source.nutrition == 100 and fixture.supply.get_shipment_records().is_empty(),
		"Reset of accepted buffer was not exactly once")
	_check_conservation(fixture, "Reset")
	await _remove_fixture(fixture)


func _test_synchronous_route_and_unique_ids() -> void:
	var first: Fixture = _new_fixture()
	var second: Fixture = _new_fixture()
	for fixture: Fixture in [first, second]:
		fixture.hub.position = Vector2.ZERO
		fixture.host.position = Vector2.ZERO
		_start(fixture)
		_check(_dispatch(fixture) and fixture.supply.get_in_transit_count() == 0
			and fixture.source.nutrition == 99
			and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1,
			"Zero-length real route arrived before its payment/source account was committed")
	var first_id: String = String(first.supply.get_shipment_records()[0].get("shipment_id", ""))
	var second_id: String = String(second.supply.get_shipment_records()[0].get("shipment_id", ""))
	_check(first_id != second_id, "Two supply instances reused a shipment ID")
	for fixture: Fixture in [first, second]:
		fixture.cultivation.cancel_task()
		_check_conservation(fixture, "Synchronous route")
		await _remove_fixture(fixture)


func _test_interval_funds_and_configuration() -> void:
	var fixture: Fixture = _new_fixture()
	_start(fixture)
	fixture.supply.auto_supply = true
	fixture.supply._process(0.34)
	_check(fixture.source.nutrition == 100, "Automatic dispatch ran before its interval")
	fixture.supply._process(5.0)
	_freeze_packets(fixture)
	_check(fixture.source.nutrition == 99 and fixture.supply.get_in_transit_count() == 1,
		"Long frame prepaid more than one cultivation packet")
	fixture.supply.reset()
	fixture.supply.auto_supply = false
	fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host)
	fixture.supply.packet_scene = PackedScene.new()
	_check(not _dispatch(fixture) and fixture.source.nutrition == 100
		and StringName(_snapshot(fixture).get("wait_reason", &"")) == &"invalid_configuration",
		"Uninstantiable packet scene debited funds or escaped configuration checks")
	fixture.supply.packet_scene = CORE_SCENE
	_check(not _dispatch(fixture) and fixture.source.nutrition == 100
		and StringName(_snapshot(fixture).get("wait_reason", &"")) == &"invalid_configuration",
		"Invalid packet scene spent nutrition or lacked a configuration reason")
	fixture.supply.packet_scene = PACKET_SCENE
	fixture.supply.packet_container = null
	_check(not _dispatch(fixture) and fixture.source.nutrition == 100, "Missing container debited funds")
	fixture.supply.packet_container = fixture.packets
	_check(_dispatch(fixture), "Restored packet configuration did not retry")
	fixture.cultivation.cancel_task()
	fixture.source.nutrition = 0
	fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host)
	_check(not _dispatch(fixture) and fixture.source.nutrition == 0
		and StringName(_snapshot(fixture).get("wait_reason", &"")) == &"core_empty",
		"Missing funds permitted dispatch or did not report waiting")
	await _remove_fixture(fixture)
