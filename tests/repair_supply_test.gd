extends SceneTree
## 真实包、真实余额和共享调度器；预留不加入资源总量，首笔交付只能来自实际抵达。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const STEP: float = 0.05

class Fixture:
	extends RefCounted

	var world: Node2D
	var nodes: Node2D
	var edges: Node2D
	var packets: Node2D
	var source: MotherCore
	var middle: HyphaNode
	var first: HyphaNode
	var second: HyphaNode
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var repair: RepairSystem
	var supply: RepairSupplySystem
	var battle: SupplySystem
	var organ: AttackOrgan
	var ingress: Array[HyphaEdge] = []
	var target: HyphaEdge
	var initial_balance: int = 32
	var task_id: int = 0

var checks: int = 0
var failures: Array[String] = []
var cases: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_core_reservations()
	await _test_priority_and_income_race()
	await _test_existing_paid_supply()
	await _test_endpoint_fallback_and_isolation()
	await _test_exclusions_survive_wait_and_reroute()
	await _test_pause_resume_and_partial_cancel()
	await _test_receive_cancel_same_stack()
	await _test_debit_reset_same_stack()
	await _test_target_and_source_loss()
	await _test_source_reference_change()
	await _test_reset_and_old_callbacks()
	await _test_zero_segment_delivery()
	_check(root.get_child_count() == 0, "All repair supply fixtures leave the tree")
	print("REPAIR_SUPPLY_TEST_RESULT ", JSON.stringify({
		"runtime": "EXECUTED", "status": "PASS" if failures.is_empty() else "FAIL",
		"checks": checks, "failures": failures, "cases": cases,
		"motion": "production_packet_physics", "first_settlements": "real_committed_arrivals",
		"shared_dispatcher": true, "artificial_resource_pools": false,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _container(parent: Node, node_name: String) -> Node2D:
	var container: Node2D = Node2D.new()
	container.name = node_name
	parent.add_child(container)
	return container


func _node(fixture: Fixture, point: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.nodes.add_child(node)
	node.global_position = point
	_check(fixture.network.register_node(node), "Physical repair junction registers")
	return node


func _edge(fixture: Fixture, first: Node2D, second: Node2D, enabled: bool = true) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	edge.entry_enabled = enabled
	fixture.edges.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Physical repair edge registers")
	return edge


func _new_fixture(balance: int = 32, connected: bool = true) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.initial_balance = balance
	fixture.world = _container(root, "RepairSupplyFixture")
	fixture.nodes = _container(fixture.world, "Nodes")
	fixture.edges = _container(fixture.world, "Edges")
	fixture.packets = _container(fixture.world, "Packets")
	fixture.source = CORE_SCENE.instantiate() as MotherCore
	fixture.source.initial_nutrition = balance
	fixture.nodes.add_child(fixture.source)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.source, true), "Original repair mother core registers")
	fixture.middle = _node(fixture, Vector2(80, 0))
	fixture.first = _node(fixture, Vector2(160, 0))
	fixture.second = _node(fixture, Vector2(240, 0))
	fixture.ingress.append(_edge(fixture, fixture.source, fixture.middle, connected))
	fixture.ingress.append(_edge(fixture, fixture.middle, fixture.first, connected))
	fixture.target = _edge(fixture, fixture.first, fixture.second)
	fixture.target.take_damage(25.0)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.repair = RepairSystem.new()
	fixture.repair.network_system = fixture.network
	fixture.world.add_child(fixture.repair)
	fixture.repair.set_process(false)
	fixture.repair.set_physics_process(false)
	fixture.supply = RepairSupplySystem.new()
	fixture.supply.repair_system = fixture.repair
	fixture.supply.mother_core = fixture.source
	fixture.supply.network_system = fixture.network
	fixture.supply.traffic_system = fixture.traffic
	fixture.supply.traffic_required = true
	fixture.supply.packet_container = fixture.packets
	fixture.supply.auto_supply = false
	fixture.world.add_child(fixture.supply)
	fixture.supply.set_process(false)
	fixture.packets.child_entered_tree.connect(func(child: Node) -> void:
		child.set_physics_process(false)
		child.set("speed", 80.0)
	)
	return fixture


func _request(fixture: Fixture, edge: HyphaEdge = null) -> void:
	fixture.task_id = fixture.repair.request_repair(edge if edge != null else fixture.target)
	_check(fixture.task_id > 0, "Damaged registered edge admits one repair task")


func _launch(fixture: Fixture) -> NutrientPacket:
	var before: int = fixture.supply.get_shipment_records().size()
	_check(fixture.supply.try_dispatch(), "Repair dispatch pays and launches one actual supply packet")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	if records.size() <= before:
		return null
	var packet: NutrientPacket = records.back()["packet"] as NutrientPacket
	_check(packet != null and bool(records.back()["debited"]), "Shipment retains its original debit and real packet")
	return packet


func _tick(fixture: Fixture, packet: NutrientPacket) -> void:
	fixture.traffic.refresh()
	fixture.supply.refresh_budget()
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet._physics_process(STEP)
	fixture.supply.refresh_budget()


func _finish(fixture: Fixture, packet: NutrientPacket) -> bool:
	if not is_instance_valid(packet):
		return false
	for _step: int in range(400):
		var snapshot: Dictionary = packet.get_transport_snapshot()
		if bool(snapshot.get("terminal", false)):
			var arrived: bool = snapshot.get("state") == &"completed"
			_check(arrived, "Physical repair supply arrives at its original point")
			return arrived
		_tick(fixture, packet)
	_check(false, "Physical repair supply reaches terminal state within bounded steps")
	return false


func _callbacks(packet: NutrientPacket, owner: Node) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for signal_name: StringName in [&"arrived", &"interrupted"]:
		for connection: Dictionary in packet.get_signal_connection_list(signal_name):
			var callback: Callable = connection["callable"]
			if callback.get_object() == owner:
				callbacks.append(callback)
	return callbacks


func _conservation(fixture: Fixture, context: String) -> void:
	var snapshot: Dictionary = fixture.repair.get_task_snapshot()
	var total: int = fixture.source.nutrition + fixture.supply.get_in_transit_nutrition() \
		+ int(snapshot.get("buffered_nutrition", 0)) + int(snapshot.get("consumed_nutrition", 0))
	_check(total == fixture.initial_balance, context + " conserves actual nutrition without counting reservations")


func _test_core_reservations() -> void:
	var fixture: Fixture = _new_fixture(4)
	var core: MotherCore = fixture.source
	_check(core.set_nutrition_reservation("unit_test", 3) == 3 and core.nutrition == 4 \
		and core.get_spendable_nutrition() == 1, "Funded locks leave real balance unchanged")
	var emitted: Array[int] = [0]
	core.budget_changed.connect(func(_snapshot: Dictionary) -> void: emitted[0] += 1)
	var before: Dictionary = core.get_budget_snapshot()
	core.get_nutrition_reservation("unit_test")
	core.get_spendable_nutrition()
	core.get_budget_snapshot()
	_check(emitted[0] == 0 and before == core.get_budget_snapshot(), "Budget queries are pure")
	_check(not core.try_spend_nutrition(2), "Ordinary spend cannot use a funded repair lock")
	var debit_observation: Array[bool] = [false]
	core.budget_changed.connect(func(snapshot: Dictionary) -> void:
		debit_observation[0] = int(snapshot["balance"]) == 3 \
			and int(snapshot["reserved"]) == 2 and int((snapshot["reservations"] as Array)[0]["desired"]) == 2
	, CONNECT_ONE_SHOT)
	_check(core.try_spend_reserved_nutrition("unit_test", 1) and debit_observation[0],
		"Reserved debit commits balance and goal reduction before callbacks")
	_check(core.release_nutrition_reservation("unit_test") == 2 \
		and core.release_nutrition_reservation("unit_test") == 0 and core.nutrition == 3,
		"Release unlocks exactly once and never refunds unspent balance")
	core.set_nutrition_reservation("large_a", 9223372036854775807)
	core.set_nutrition_reservation("large_b", 9223372036854775807)
	_check(int(core.get_budget_snapshot()["reserved"]) == 3, "Several maximum goals cannot overflow funded totals")
	core.nutrition = 0
	_check(core.get_nutrition_reservation("large_a") == 0 \
		and core.get_nutrition_reservation("large_b") == 0, "Direct fixture balance replacement cannot retain phantom funding")
	core.nutrition = 1
	core.add_nutrition(9223372036854775807)
	_check(core.nutrition == 1 and not core.accept_digestion_product("overflow", 9223372036854775807),
		"Overflowing income is rejected without a receipt or balance change")
	core.set_nutrition_reservation("large_a", 0)
	core.set_nutrition_reservation("large_b", 0)
	_check(core.get_spendable_nutrition() == 1, "Set zero is an idempotent unlock")
	cases.append("core_funded_budget_purity_and_overflow")
	await _dispose(fixture)


func _test_priority_and_income_race() -> void:
	var fixture: Fixture = _new_fixture(0)
	var observer_spends: Array[bool] = []
	# 普通观察者在补给刷新前登记；真实收入在广播前即受 active desired 保护。
	var income_observer: Callable = func(_balance: int) -> void:
		if fixture.source.get_spendable_nutrition() > 0:
			observer_spends.append(fixture.source.try_spend_nutrition(1))
		else:
			observer_spends.append(false)
	fixture.source.nutrition_changed.connect(income_observer)
	_request(fixture)
	var snapshot: Dictionary = fixture.supply.get_supply_snapshot()
	_check(int(snapshot["reservation_goal"]) == 3 and int(snapshot["reserved_nutrition"]) == 0 \
		and not fixture.supply.try_dispatch(), "Unfunded demand is recorded without phantom paid supply")
	_check(fixture.source.accept_digestion_product("repair-income-1", 1), "Genuine digestion income posts once")
	_check(fixture.source.nutrition == 1 and fixture.source.get_spendable_nutrition() == 0 \
		and not observer_spends.back(), "First income funds the repair goal before ordinary observers can spend")
	_check(fixture.source.accept_digestion_product("repair-income-2", 2), "Further genuine income fills the same goal")
	_check(fixture.source.nutrition == 3 and fixture.source.get_spendable_nutrition() == 0 \
		and int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 3,
		"All three required units are funded before surplus becomes available")
	_check(not fixture.source.accept_digestion_product("repair-income-1", 1), "Existing unique product ledger rejects duplicate income")
	fixture.source.add_nutrition(1)
	_check(fixture.source.nutrition == 3 and observer_spends.has(true), "Only income beyond the funded goal may be spent normally")
	fixture.source.nutrition_changed.disconnect(income_observer)
	var packet: NutrientPacket = _launch(fixture)
	_check(fixture.source.nutrition == 2 and int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 2,
		"Dispatch spends one funded unit without reserving that paid unit a second time")
	if packet != null:
		_finish(fixture, packet)
	fixture.repair.cancel_task()
	_check(fixture.source.nutrition == 3 and fixture.source.get_spendable_nutrition() == 3 \
		and fixture.source.get_received_product_count() == 2, "Refunds unlock genuine balance without inventing digestion income")
	cases.append("insufficient_funds_and_new_income_priority")
	await _dispose(fixture)


func _test_existing_paid_supply() -> void:
	var fixture: Fixture = _new_fixture(4)
	fixture.organ = ORGAN_SCENE.instantiate() as AttackOrgan
	fixture.organ.initial_nutrition = 0
	fixture.first.add_child(fixture.organ)
	fixture.battle = SupplySystem.new()
	fixture.battle.mother_core = fixture.source
	fixture.battle.network_system = fixture.network
	fixture.battle.traffic_system = fixture.traffic
	fixture.battle.traffic_required = true
	fixture.battle.packet_container = fixture.packets
	fixture.battle.packet_scene = PACKET_SCENE
	fixture.world.add_child(fixture.battle)
	_check(fixture.battle.register_organ(fixture.organ) and fixture.battle.request_supply(fixture.organ),
		"An ordinary supply pays before repair starts")
	var paid: NutrientPacket = fixture.packets.get_child(0) as NutrientPacket
	_request(fixture)
	_check(fixture.source.nutrition == 3 and fixture.source.get_spendable_nutrition() == 0 \
		and fixture.battle.get_in_transit_count() == 1 and fixture.organ.incoming_nutrition == 1,
		"New repair lock leaves an existing ordinary paid shipment and its receiver reservation untouched")
	_check(not fixture.battle.request_supply(fixture.organ), "New ordinary requests respect the repair lock")
	_finish(fixture, paid)
	_check(fixture.organ.nutrition == 1 and fixture.source.nutrition == 3,
		"The previously paid ordinary packet still physically delivers once")
	var repair_packet: NutrientPacket = _launch(fixture)
	if repair_packet != null:
		_check(int(repair_packet.get_transport_snapshot()["traffic_system_id"]) == fixture.traffic.get_instance_id() \
			and repair_packet.get_transport_snapshot()["cargo_kind"] == &"supply" \
			and int(repair_packet.get_transport_snapshot()["units"]) == 1,
			"Repair uses the existing shared dispatcher and ordinary one-unit cargo kind")
	fixture.repair.cancel_task()
	_check(fixture.source.nutrition == 3 and fixture.organ.nutrition == 1, "Repair cancellation cannot refund or consume ordinary supply")
	cases.append("existing_paid_ordinary_supply_preserved")
	await _dispose(fixture)


func _test_endpoint_fallback_and_isolation() -> void:
	var fixture: Fixture = _new_fixture(32, false)
	_request(fixture)
	_check(fixture.repair.get_task_snapshot().get("repair_point") == null \
		and int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 0 \
		and not fixture.supply.try_dispatch() and fixture.source.nutrition == 32,
		"An isolated target with only its own edge has no work point, funding or paid supply")
	_edge(fixture, fixture.source, fixture.second)
	fixture.supply.refresh_budget()
	_check(fixture.repair.get_delivery_target(fixture.task_id) == fixture.second \
		and int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 3,
		"Initially waiting repair pins the reachable end when the start remains isolated")
	var packet: NutrientPacket = _launch(fixture)
	if packet != null:
		_finish(fixture, packet)
		_check(packet.has_arrived_at(fixture.second, String(fixture.supply.get_shipment_records().back()["transport_task_id"])),
			"Fallback supply physically arrives at the chosen end")
	fixture.ingress[0].entry_enabled = true
	fixture.ingress[1].entry_enabled = true
	fixture.supply.refresh_budget()
	_check(fixture.repair.get_delivery_target(fixture.task_id) == fixture.second,
		"An assigned work point stays pinned after the other end becomes available")
	_conservation(fixture, "Endpoint fallback")
	cases.append("isolated_wait_and_endpoint_fallback")
	await _dispose(fixture)


func _test_exclusions_survive_wait_and_reroute() -> void:
	var fixture: Fixture = _new_fixture()
	var bypass: HyphaEdge = _edge(fixture, fixture.source, fixture.second, false)
	_request(fixture)
	var packet: NutrientPacket = _launch(fixture)
	if packet == null:
		await _dispose(fixture)
		return
	var original: Dictionary = packet.get_transport_snapshot()
	_check((original.get("excluded_edge_ids", []) as Array).has(fixture.target.get_instance_id()),
		"Target edge is excluded before the packet enters the scene tree")
	var entered: bool = false
	for _step: int in range(50):
		_tick(fixture, packet)
		var transport: Dictionary = packet.get_transport_snapshot()
		if transport.get("edge") == fixture.ingress[0] and transport.get("location_kind") == &"edge":
			entered = true
			break
	_check(entered, "Actual supply occupies the first shared edge")
	fixture.ingress[1].entry_enabled = false
	bypass.entry_enabled = true
	for _step: int in range(60):
		_tick(fixture, packet)
	var waiting: Dictionary = packet.get_transport_snapshot()
	_check(waiting.get("state") == &"waiting" and fixture.supply.get_in_transit_nutrition() == 1 \
		and int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 0,
		"A path available only through the target edge leaves the same paid packet waiting and releases unpaid locks")
	_check(waiting.get("final_target") == fixture.first and waiting.get("task_id") == original.get("task_id") \
		and (waiting.get("excluded_edge_ids", []) as Array).has(fixture.target.get_instance_id()),
		"Remaining-route replans preserve the original point, transport identity and exclusion")
	packet.arrived.emit(packet)
	_check(int(fixture.repair.get_task_snapshot()["buffered_nutrition"]) == 0 \
		and fixture.source.nutrition == 31, "A fake waiting arrival cannot deliver or refund paid cargo")
	fixture.ingress[1].entry_enabled = true
	_finish(fixture, packet)
	_conservation(fixture, "Excluded-edge wait and recovery")
	cases.append("target_edge_excluded_through_wait_and_replan")
	await _dispose(fixture)


func _test_pause_resume_and_partial_cancel() -> void:
	var fixture: Fixture = _new_fixture()
	_request(fixture)
	var packet: NutrientPacket = _launch(fixture)
	fixture.repair.pause_task()
	_check(int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 0 \
		and not fixture.supply.try_dispatch() and fixture.supply.get_in_transit_nutrition() == 1,
		"Pause releases unpaid reservation and keeps already paid transport")
	if packet != null:
		_finish(fixture, packet)
	fixture.repair.advance(1.0)
	_check(is_equal_approx(fixture.target.health, 10.0) \
		and int(fixture.repair.get_task_snapshot()["buffered_nutrition"]) == 1,
		"Paused repair accepts physical arrivals while preserving health and integer buffer")
	fixture.repair.resume_task()
	_check(int(fixture.supply.get_supply_snapshot()["reservation_goal"]) == 2, "Resume reserves only remaining demand beyond arrived stock")
	for _unit: int in range(2):
		var next_packet: NutrientPacket = _launch(fixture)
		if next_packet != null:
			_finish(fixture, next_packet)
	fixture.repair.advance(0.2)
	var snapshot: Dictionary = fixture.repair.get_task_snapshot()
	_check(int(snapshot["consumed_nutrition"]) == 1 and int(snapshot["buffered_nutrition"]) == 2 \
		and is_equal_approx(fixture.target.health, 12.0), "First positive work consumes one delivered unit for at most ten health")
	_conservation(fixture, "Partly consumed repair")
	fixture.repair.cancel_task()
	_check(fixture.source.nutrition == 31 and int(fixture.supply.get_supply_snapshot()["refunded_nutrition"]) == 2 \
		and is_equal_approx(fixture.target.health, 12.0), "Cancel refunds only two unconsumed integer units and loses paid credit")
	fixture.repair.cancel_task()
	fixture.supply.refresh_budget()
	_check(fixture.source.nutrition == 31 and fixture.repair.take_unspent_nutrition(fixture.task_id) == 0,
		"Repeated cancel and unspent take cannot refund a consumed unit or duplicate a refund")
	_conservation(fixture, "Cancelled partial repair")
	cases.append("pause_resume_and_partial_consumption_refunds")
	await _dispose(fixture)


func _test_receive_cancel_same_stack() -> void:
	var fixture: Fixture = _new_fixture()
	_request(fixture)
	var cancelled: Array[bool] = [false]
	fixture.repair.task_changed.connect(func(snapshot: Dictionary) -> void:
		if not cancelled[0] and int(snapshot.get("buffered_nutrition", 0)) > 0:
			cancelled[0] = true
			fixture.repair.cancel_task()
	)
	var packet: NutrientPacket = _launch(fixture)
	if packet != null:
		var callbacks: Array[Callable] = _callbacks(packet, fixture.supply)
		_finish(fixture, packet)
		_check(cancelled[0] and fixture.source.nutrition == 32 \
			and fixture.supply.get_in_transit_count() == 0, "Cancel inside receive notification returns its newly arrived lot exactly once")
		for callback: Callable in callbacks:
			callback.call(packet)
		packet.arrived.emit(packet)
		_check(fixture.source.nutrition == 32 and int(fixture.supply.get_supply_snapshot()["reserved_nutrition"]) == 0,
			"Terminal callback replays cannot recreate the obsolete lock or duplicate refund")
	_conservation(fixture, "Receive/cancel same stack")
	cases.append("real_arrival_cancel_same_stack")
	await _dispose(fixture)


func _test_debit_reset_same_stack() -> void:
	var fixture: Fixture = _new_fixture()
	_request(fixture)
	var reset_once: Array[bool] = [false]
	fixture.source.nutrition_changed.connect(func(_balance: int) -> void:
		if not reset_once[0]:
			reset_once[0] = true
			fixture.supply.reset()
	)
	_check(not fixture.supply.try_dispatch() and reset_once[0], "Reset during real debit aborts the launch")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(records.size() == 1 and bool(records[0]["debited"]) and bool(records[0]["refunded"]) \
		and fixture.source.nutrition == 32 and fixture.source.get_spendable_nutrition() == 32,
		"Debit intent retained before the observer reset permits one exact refund and no old lock")
	_conservation(fixture, "Debit/reset same stack")
	cases.append("debit_intent_before_reentrant_reset")
	await _dispose(fixture)


func _test_target_and_source_loss() -> void:
	for delete_source: bool in [false, true]:
		var fixture: Fixture = _new_fixture()
		_request(fixture)
		var packet: NutrientPacket = _launch(fixture)
		if delete_source:
			fixture.source.queue_free()
		else:
			fixture.target.queue_free()
		fixture.supply.refresh_budget()
		_check(not fixture.repair.has_active_task() and fixture.supply.get_in_transit_nutrition() == 0 \
			and fixture.source.nutrition == 32, "Queued source or target loss settles original paid supply without a freed-target call")
		if packet != null:
			packet.arrived.emit(packet)
			_check(fixture.source.nutrition == 32, "Deletion race cannot redeliver or refund twice")
		cases.append("source_loss" if delete_source else "target_loss")
		await _dispose(fixture)


func _test_source_reference_change() -> void:
	var fixture: Fixture = _new_fixture()
	_request(fixture)
	var packet: NutrientPacket = _launch(fixture)
	var replacement: MotherCore = CORE_SCENE.instantiate() as MotherCore
	fixture.nodes.add_child(replacement)
	fixture.supply.mother_core = replacement
	fixture.supply.refresh_budget()
	_check(not fixture.repair.has_active_task() and fixture.source.nutrition == 32 \
		and replacement.nutrition == 72 and replacement.get_spendable_nutrition() == 72,
		"Changing the exported source cancels original work and refunds only the original mother core")
	if packet != null:
		var record: Dictionary = fixture.supply.get_shipment_records().back()
		_check(record["source_core"] == fixture.source and bool(record["refunded"]), "Source identity remains evidence after a reference change")
	cases.append("original_source_identity_after_export_change")
	await _dispose(fixture)


func _test_reset_and_old_callbacks() -> void:
	var fixture: Fixture = _new_fixture()
	_request(fixture)
	var old_packet: NutrientPacket = _launch(fixture)
	if old_packet == null:
		await _dispose(fixture)
		return
	var callbacks: Array[Callable] = _callbacks(old_packet, fixture.supply)
	var old_record: Dictionary = fixture.supply.get_shipment_records().back()
	fixture.supply.reset()
	_request(fixture)
	var packet: NutrientPacket = _launch(fixture)
	var before: Dictionary = fixture.supply.get_supply_snapshot()
	var record: Dictionary = fixture.supply.get_shipment_records().back()
	_check(record["transport_task_id"] != old_record["transport_task_id"] \
		and record["budget_key"] != old_record["budget_key"], "Reset never reuses transport identity or budget epoch")
	for callback: Callable in callbacks:
		callback.call(old_packet)
	old_packet.arrived.emit(old_packet)
	_check(before == fixture.supply.get_supply_snapshot() and fixture.source.nutrition == 31,
		"Old callbacks cannot deliver or refund a replacement task's shipment")
	if packet != null:
		_finish(fixture, packet)
	fixture.supply.reset(true)
	_check(fixture.source.nutrition == 32 and not fixture.supply.try_dispatch(), "Sealed reset cancels work, returns unused lots and stops dispatch")
	_conservation(fixture, "Reset and stale callbacks")
	cases.append("epoch_reset_and_stale_callbacks")
	await _dispose(fixture)


func _test_zero_segment_delivery() -> void:
	var fixture: Fixture = _new_fixture()
	var target: HyphaEdge = _edge(fixture, fixture.source, fixture.second)
	target.take_damage(5.0)
	_request(fixture, target)
	_check(fixture.repair.get_delivery_target(fixture.task_id) == fixture.source,
		"A source endpoint is a legitimate pinned work point")
	var packet: NutrientPacket = _launch(fixture)
	_check(fixture.source.nutrition == 31 and int(fixture.repair.get_task_snapshot()["buffered_nutrition"]) == 1 \
		and fixture.supply.get_in_transit_count() == 0, "Zero-segment supply still pays and commits an actual synchronous arrival")
	if packet != null:
		_check(int(packet.get_transport_snapshot()["segment_count"]) == 0 \
			and packet.has_arrived_at(fixture.source, String(fixture.supply.get_shipment_records().back()["transport_task_id"])),
			"Zero-segment packet satisfies the same original target/task arrival proof")
	fixture.repair.advance(0.5)
	_check(is_equal_approx(target.health, target.max_health) and not fixture.repair.has_active_task() \
		and fixture.source.nutrition == 31, "Final fractional repair consumes one unit and completes at full health")
	_conservation(fixture, "Zero-segment repair completion")
	cases.append("zero_segment_real_debit_and_delivery")
	await _dispose(fixture)


func _ledger_weak_refs(supply: RepairSupplySystem) -> Array[WeakRef]:
	var references: Array[WeakRef] = []
	# 单独的调用帧只返回弱引用，验证生命周期时不保留被测 RefCounted 对象。
	for account: RefCounted in (supply.get("_accounts") as Dictionary).values():
		references.append(weakref(account))
	for shipment: RefCounted in (supply.get("_shipments") as Dictionary).values():
		references.append(weakref(shipment))
	return references


func _dispose(fixture: Fixture) -> void:
	var ledger_references: Array[WeakRef] = _ledger_weak_refs(fixture.supply)
	fixture.supply.reset(true)
	if fixture.battle != null:
		fixture.battle.reset(true)
	fixture.traffic.reset()
	fixture.world.queue_free()
	await process_frame
	await process_frame
	for reference: WeakRef in ledger_references:
		_check(reference.get_ref() == null, "Disposed repair supply releases its account and shipment ledger objects")
