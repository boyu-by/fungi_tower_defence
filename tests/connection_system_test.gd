extends SceneTree
## 使用同一生长供养账本和真实运输包，手动推进已有菌结之间的付费连接。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const HOST_SCENES: Array[PackedScene] = [
	preload("res://scenes/colony/attack_organ.tscn"),
	preload("res://scenes/colony/digestive_organ.tscn"),
	preload("res://scenes/colony/organ_bud.tscn"),
]

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var network: NetworkSystem
	var growth: GrowthSystem
	var supply: GrowthSupplySystem
	var connection: ConnectionSystem
	var first: HyphaNode
	var second: HyphaNode
	var feed: HyphaEdge
	var target_feed: HyphaEdge
	var packets: Node2D
	var completed: Array[int] = []
	var cancelled: Array[int] = []
	var connected: Array[Dictionary] = []
	var formed: Array[HyphaNode] = []
	var changed: Array[Dictionary] = []
	var slot_changes: int = 0

class Trigger:
	extends RefCounted

	var fired: bool = false
	var new_task_id: int = 0

class RejectingNetwork:
	extends NetworkSystem

	var attempts: int = 0

	func register_connection_corridor(
		_first: HyphaNode, _second: HyphaNode, _edges: Array[HyphaEdge]
	) -> bool:
		attempts += 1
		return false

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	await _test_short_connection_and_exact_endpoint()
	await _test_paid_relays_and_duplicate_corridor()
	await _test_reversed_source()
	await _test_occupied_and_reserved_hosts()
	await _test_loop_and_crossing()
	await _test_physical_duplicate_and_validation()
	await _test_source_loss_and_opposite_supply()
	await _test_cancelled_paid_network()
	await _test_pause_and_original_source_refund()
	await _test_target_unregister_and_free()
	await _test_reset_restart_and_stale_callbacks()
	await _test_missing_food_and_core()
	await _test_rejected_final_registration()
	await _test_target_removed_during_final_commit()
	await _test_source_lost_during_final_commit()
	await _test_reentrant_creation_and_terminal_callbacks()
	_check(root.get_child_count() == initial_children, "Connection fixtures left root children")
	print("CONNECTION_SYSTEM_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_container(parent: Node2D) -> Node2D:
	var container: Node2D = Node2D.new()
	parent.add_child(container)
	return container


func _new_node(fixture: Fixture, position: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.growth.node_container.add_child(node)
	node.global_position = position
	_check(fixture.network.register_node(node), "Fixture junction registration")
	return node


func _new_edge(fixture: Fixture, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	fixture.growth.edge_container.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Fixture edge registration")
	return edge


func _new_fixture(
	distance: float = 80.0, both_connected: bool = false, balance: int = 256,
	network: NetworkSystem = null
) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = balance
	fixture.world.add_child(fixture.core)
	fixture.network = NetworkSystem.new() if network == null else network
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Fixture mother core registration")
	fixture.growth = GrowthSystem.new()
	fixture.growth.planner = GrowthPlanner.new()
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = _new_container(fixture.world)
	fixture.growth.edge_container = _new_container(fixture.world)
	fixture.growth.tip_container = _new_container(fixture.world)
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_physics_process(false)
	fixture.first = _new_node(fixture, Vector2(160.0, 0.0))
	fixture.second = _new_node(fixture, Vector2(160.0 + distance, 0.0))
	fixture.feed = _new_edge(fixture, fixture.first, fixture.core)
	if both_connected:
		fixture.target_feed = _new_edge(fixture, fixture.core, fixture.second)
	fixture.packets = _new_container(fixture.world)
	fixture.supply = GrowthSupplySystem.new()
	fixture.supply.growth_system = fixture.growth
	fixture.supply.mother_core = fixture.core
	fixture.supply.network_system = fixture.network
	fixture.supply.packet_container = fixture.packets
	fixture.supply.auto_supply = false
	fixture.world.add_child(fixture.supply)
	fixture.supply.set_process(false)
	fixture.connection = ConnectionSystem.new()
	fixture.connection.growth_system = fixture.growth
	fixture.connection.mother_core = fixture.core
	fixture.world.add_child(fixture.connection)
	fixture.connection.task_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.changed.append(snapshot.duplicate())
	)
	fixture.connection.task_completed.connect(func(task_id: int) -> void:
		fixture.completed.append(task_id)
	)
	fixture.connection.task_cancelled.connect(func(task_id: int) -> void:
		fixture.cancelled.append(task_id)
	)
	fixture.connection.connection_completed.connect(
		func(task_id: int, source: HyphaNode, target: HyphaNode) -> void:
			fixture.connected.append({"task_id": task_id, "source": source, "target": target})
			_check(fixture.growth.get_completed_endpoint(task_id) == target,
				"Completion callback did not expose the committed existing endpoint")
			_check(fixture.network.has_direct_connection(source, target),
				"Completion callback ran before final physical corridor registration")
	)
	fixture.growth.junction_formed.connect(func(node: HyphaNode) -> void:
		fixture.formed.append(node)
	)
	return fixture


func _remove_fixture(fixture: Fixture) -> void:
	fixture.supply.reset()
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _snapshot(fixture: Fixture) -> Dictionary:
	return fixture.connection.get_task_snapshot()


func _dispatch(fixture: Fixture) -> bool:
	var dispatched: bool = fixture.supply.try_dispatch()
	for child: Node in fixture.packets.get_children():
		if child is NutrientPacket:
			child.set_physics_process(false)
	return dispatched


func _dispatch_demand(fixture: Fixture) -> int:
	var dispatched: int = 0
	for attempt: int in range(64):
		if not _dispatch(fixture):
			break
		dispatched += 1
	return dispatched


func _deliver(fixture: Fixture) -> void:
	for record: Dictionary in fixture.supply.get_shipment_records():
		var packet: Variant = record.get("packet")
		if not bool(record.get("settled", false)) and is_instance_valid(packet) \
				and not packet.is_queued_for_deletion():
			packet._physics_process(1000.0)


func _drive_to_completion(fixture: Fixture) -> void:
	for step: int in range(64):
		if not fixture.connection.has_active_task():
			break
		_dispatch_demand(fixture)
		_deliver(fixture)
		fixture.growth.advance(1000.0)
	_check(_snapshot(fixture).get("state") == &"completed", "Paid connection failed to complete")


func _test_short_connection_and_exact_endpoint() -> void:
	var fixture: Fixture = _new_fixture()
	var balance: int = fixture.core.nutrition
	var preview: Dictionary = fixture.connection.preview_connection(fixture.first, fixture.second)
	_check(preview.has_all(["valid", "error", "reason", "first_node", "second_node", "start_node",
		"target_node", "reversed", "plan", "total_cost"]), "Preview contract is incomplete")
	_check(bool(preview["valid"]) and preview["reason"] is StringName,
		"Connected first node did not produce a valid typed preview")
	_check(preview["plan"] == fixture.growth.planner.plan(
		fixture.first.global_position, fixture.second.global_position, true),
		"Connection preview recalculated or changed the authoritative planner result")
	_check(preview["total_cost"] == 1 and preview["plan"]["junction_positions"].is_empty(),
		"Short connection charged a new endpoint junction")
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_check(task_id > 0 and _snapshot(fixture)["task_id"] == task_id
		and fixture.growth.get_task_snapshot()["task_id"] == task_id,
		"Connection created a separate task identifier")
	_check(_snapshot(fixture)["task_kind"] == &"connection"
		and _snapshot(fixture)["start_node"] == fixture.first
		and _snapshot(fixture)["target_node"] == fixture.second, "Connection snapshot lost host identities")
	_check(fixture.core.nutrition == balance, "Connection creation spent nutrition directly")
	fixture.growth.advance(1000.0)
	_check(_snapshot(fixture)["distance"] == 0.0, "Short connection grew without delivered nutrition")
	_drive_to_completion(fixture)
	_check(fixture.growth.node_container.get_child_count() == 2 and fixture.formed.is_empty(),
		"Existing endpoint was replaced by an overlapping or newly counted junction")
	_check(fixture.core.nutrition == balance - 1 and _snapshot(fixture)["consumed_nutrition"] == 1,
		"Short connection did not pay exactly its planned extension fee")
	_check(fixture.growth.get_completed_endpoint(task_id) == fixture.second
		and fixture.completed == [task_id] and fixture.connected.size() == 1,
		"Existing endpoint or completion events were not committed once")
	fixture.growth.task_completed.emit(task_id)
	fixture.growth.task_cancelled.emit(task_id)
	_check(fixture.completed.size() == 1 and fixture.connected.size() == 1 and fixture.cancelled.is_empty(),
		"Duplicate terminal notifications were forwarded")
	await _remove_fixture(fixture)


func _test_paid_relays_and_duplicate_corridor() -> void:
	var fixture: Fixture = _new_fixture(300.0)
	var preview: Dictionary = fixture.connection.preview_connection(fixture.first, fixture.second)
	_check(preview["total_cost"] == 12 and preview["plan"]["extension_cost"] == 4
		and preview["plan"]["junction_cost"] == 8, "Relay fees differ from the shared plan")
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_drive_to_completion(fixture)
	_check(_snapshot(fixture)["formed_junctions"] == 2 and fixture.formed.size() == 2
		and fixture.growth.node_container.get_child_count() == 4, "Relay connection added the wrong junctions")
	_check(fixture.formed[0].global_position == Vector2(280.0, 0.0)
		and fixture.formed[1].global_position == Vector2(400.0, 0.0), "Paid relay positions differ from preview")
	_check(fixture.core.nutrition == 244 and _snapshot(fixture)["consumed_nutrition"] == 12
		and fixture.supply.get_in_transit_count() == 0, "Relay connection did not conserve its single ledger")
	_check(fixture.network.has_direct_connection(fixture.first, fixture.second)
		and fixture.network.has_direct_connection(fixture.second, fixture.first),
		"Completed relay corridor was not recognized in both directions")
	_check(fixture.connection.request_connection(fixture.second, fixture.first) == 0
		and fixture.growth.create_connection(fixture.first, fixture.second) == 0,
		"Completed relay corridor accepted a duplicate construction")
	var last_edge: HyphaEdge = fixture.growth.edge_container.get_child(3) as HyphaEdge
	fixture.network.unregister_edge(last_edge)
	_check(not fixture.network.has_direct_connection(fixture.first, fixture.second),
		"Removed corridor edge left a phantom direct connection")
	fixture.network.register_edge(last_edge)
	_check(fixture.network.has_direct_connection(fixture.first, fixture.second),
		"Restoring the same paid edge forgot the explicit corridor identity")
	_check(fixture.growth.get_completed_endpoint(task_id) == fixture.second,
		"Later network changes replaced the saved endpoint identity")
	await _remove_fixture(fixture)


func _test_reversed_source() -> void:
	var fixture: Fixture = _new_fixture(160.0)
	fixture.network.unregister_edge(fixture.feed)
	fixture.target_feed = _new_edge(fixture, fixture.core, fixture.second)
	var preview: Dictionary = fixture.connection.preview_connection(fixture.first, fixture.second)
	_check(bool(preview["valid"]) and bool(preview["reversed"])
		and preview["start_node"] == fixture.second and preview["target_node"] == fixture.first,
		"Disconnected first endpoint did not reverse to the supplied endpoint")
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_drive_to_completion(fixture)
	_check(_snapshot(fixture)["start_node"] == fixture.second
		and fixture.growth.get_completed_endpoint(task_id) == fixture.first,
		"Reversed construction rebased or completed at a generated endpoint")
	_check(fixture.connected[0]["source"] == fixture.second and fixture.connected[0]["target"] == fixture.first,
		"Reversed completion signal reported selection order instead of construction direction")
	await _remove_fixture(fixture)


func _test_occupied_and_reserved_hosts() -> void:
	for index: int in range(4):
		var fixture: Fixture = _new_fixture()
		var first_organ: Node = HOST_SCENES[index % HOST_SCENES.size()].instantiate()
		fixture.first.add_child(first_organ)
		first_organ.process_mode = Node.PROCESS_MODE_DISABLED
		if index < 3:
			var second_organ: Node = HOST_SCENES[(index + 1) % HOST_SCENES.size()].instantiate()
			fixture.second.add_child(second_organ)
			second_organ.process_mode = Node.PROCESS_MODE_DISABLED
		else:
			_check(fixture.second.try_reserve_organ_slot("connection-test-reserved"), "Fixture slot reservation")
		var first_children: Array[Node] = fixture.first.get_children()
		var second_children: Array[Node] = fixture.second.get_children()
		var first_state: StringName = fixture.first.get_organ_slot_state()
		var second_state: StringName = fixture.second.get_organ_slot_state()
		fixture.first.organ_slot_changed.connect(func() -> void: fixture.slot_changes += 1)
		fixture.second.organ_slot_changed.connect(func() -> void: fixture.slot_changes += 1)
		_check(fixture.connection.request_connection(fixture.first, fixture.second) > 0,
			"Occupied or reserved organ host could not connect")
		_drive_to_completion(fixture)
		_check(fixture.first.get_children() == first_children and fixture.second.get_children() == second_children
			and fixture.first.get_organ_slot_state() == first_state
			and fixture.second.get_organ_slot_state() == second_state and fixture.slot_changes == 0,
			"Connection changed an existing organ, child, or slot reservation")
		await _remove_fixture(fixture)


func _test_loop_and_crossing() -> void:
	var fixture: Fixture = _new_fixture(80.0, true)
	_check(fixture.network.find_route(fixture.first, fixture.second).found
		and not fixture.network.has_direct_connection(fixture.first, fixture.second),
		"Ordinary indirect route was mistaken for an explicit connection")
	var crossing_first: HyphaNode = _new_node(fixture, Vector2(200.0, -80.0))
	var crossing_second: HyphaNode = _new_node(fixture, Vector2(200.0, 80.0))
	var crossing: HyphaEdge = _new_edge(fixture, crossing_first, crossing_second)
	_check(fixture.connection.request_connection(fixture.first, fixture.second) > 0,
		"Existing indirect route prevented a paid loop")
	_drive_to_completion(fixture)
	_check(fixture.growth.node_container.get_child_count() == 4 and fixture.formed.is_empty()
		and crossing.start_node == crossing_first and crossing.end_node == crossing_second,
		"Crossing lines created an unsolicited junction or rewired the crossed edge")
	_check(not fixture.network.find_route(fixture.core, crossing_first).found,
		"Geometric crossing automatically spliced an unrelated physical network")
	fixture.network.unregister_edge(fixture.feed)
	_check(fixture.network.is_connected_to_core(fixture.first), "Completed loop did not preserve opposite supply")
	await _remove_fixture(fixture)


func _test_physical_duplicate_and_validation() -> void:
	var fixture: Fixture = _new_fixture()
	var edge: HyphaEdge = _new_edge(fixture, fixture.second, fixture.first)
	_check(fixture.network.has_direct_connection(fixture.first, fixture.second)
		and fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Existing reverse physical edge did not reject a duplicate")
	fixture.network.unregister_edge(edge)
	_check(not bool(fixture.connection.preview_connection(fixture.first, fixture.first)["valid"]),
		"Same node was a valid connection")
	fixture.network.unregister_node(fixture.second)
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Unregistered existing junction was accepted")
	fixture.network.register_node(fixture.second)
	fixture.second.global_position = fixture.first.global_position
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Co-located hosts created a free connection")
	fixture.second.global_position += Vector2(80.0, 0.0)
	fixture.network.unregister_edge(fixture.feed)
	_check(fixture.connection.preview_connection(fixture.first, fixture.second)["reason"] == &"disconnected"
		and fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Two registered but unsupplied hosts created a connection")
	fixture.network.register_edge(fixture.feed)
	fixture.connection.construction_blocker = func() -> bool: return true
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Injected construction blocker was ignored")
	fixture.connection.construction_blocker = Callable()
	fixture.growth.construction_blocker = func() -> bool: return true
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Shared growth construction blocker was ignored")
	fixture.growth.construction_blocker = Callable()
	var ordinary_id: int = fixture.growth.create_target(fixture.first, Vector2(160.0, 80.0))
	_check(ordinary_id > 0 and fixture.growth.get_task_snapshot()["task_kind"] == &"growth"
		and fixture.growth.get_task_snapshot()["target_node"] == null, "Ordinary growth API contract changed")
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0
		and not fixture.connection.has_active_task(), "Connection overlapped or adopted ordinary growth")
	fixture.growth.cancel_task()
	_check(fixture.cancelled.is_empty() and fixture.completed.is_empty() and fixture.changed.is_empty(),
		"Connection forwarded another construction's events")
	await _remove_fixture(fixture)


func _test_source_loss_and_opposite_supply() -> void:
	var fixture: Fixture = _new_fixture(300.0, true)
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_check(_dispatch_demand(fixture) == 2, "Source-loss initial extension was not funded")
	_deliver(fixture)
	fixture.growth.advance(1.0)
	var distance: float = _snapshot(fixture)["distance"]
	fixture.network.unregister_edge(fixture.feed)
	fixture.growth.advance(1000.0)
	_check(_snapshot(fixture)["distance"] == distance and _snapshot(fixture)["wait_reason"] == &"disconnected"
		and _snapshot(fixture)["start_node"] == fixture.first, "Source loss rebased or continued unfed construction")
	_check(not _dispatch(fixture) and not fixture.network.is_connected_to_core(fixture.first),
		"Unbuilt target supplied construction through an imaginary edge")
	fixture.network.register_edge(fixture.feed)
	_drive_to_completion(fixture)
	fixture.network.unregister_edge(fixture.feed)
	_check(fixture.network.is_connected_to_core(fixture.first)
		and fixture.growth.get_completed_endpoint(task_id) == fixture.second,
		"Completed physical corridor could not supply through the opposite endpoint")
	await _remove_fixture(fixture)


func _test_cancelled_paid_network() -> void:
	var fixture: Fixture = _new_fixture(300.0)
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1.0)
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1.0)
	var consumed: int = _snapshot(fixture)["consumed_nutrition"]
	_check(fixture.formed.size() == 1 and consumed == 7, "Cancellation fixture has no paid relay and partial strand")
	_check(fixture.connection.cancel_task(), "Partial connection cancellation failed")
	_check(fixture.network.is_connected_to_core(fixture.formed[0])
		and fixture.growth.node_container.get_child_count() == 3
		and fixture.growth.edge_container.get_child_count() == 3,
		"Cancellation removed paid relay network or the retained partial strand")
	_check(not fixture.network.has_direct_connection(fixture.first, fixture.second)
		and fixture.growth.get_completed_endpoint(task_id) == null and fixture.connected.is_empty(),
		"Cancelled partial strand was registered as a completed connection")
	_check(fixture.core.nutrition + consumed == 256 and fixture.cancelled == [task_id],
		"Partial cancellation refunded consumed structure or settled twice")
	_check(not fixture.connection.cancel_task() and not fixture.connection.pause_task(),
		"Terminal task accepted repeated controls")
	await _remove_fixture(fixture)


func _test_pause_and_original_source_refund() -> void:
	var fixture: Fixture = _new_fixture(160.0)
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_check(_dispatch(fixture) and fixture.connection.pause_task(), "Pause fixture failed to dispatch and pause")
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_check(_snapshot(fixture)["state"] == &"paused" and _snapshot(fixture)["buffered_nutrition"] == 1
		and _snapshot(fixture)["consumed_nutrition"] == 0 and not _dispatch(fixture),
		"Paused transit was discarded, spent, or allowed another debit")
	_check(fixture.connection.resume_task() and _snapshot(fixture)["buffered_nutrition"] == 1,
		"Resume consumed a frozen buffer implicitly")
	var replacement: MotherCore = CORE_SCENE.instantiate() as MotherCore
	replacement.initial_nutrition = 23
	fixture.world.add_child(replacement)
	fixture.supply.mother_core = replacement
	_check(fixture.connection.cancel_task(), "Buffered connection cancellation failed")
	fixture.growth.task_cancelled.emit(task_id)
	fixture.connection.reset()
	fixture.supply.reset()
	_check(fixture.core.nutrition == 256 and replacement.nutrition == 23
		and fixture.supply.get_in_transit_count() == 0, "Buffer refund lost original source identity or duplicated payment")
	await _remove_fixture(fixture)


func _test_target_unregister_and_free() -> void:
	for removal: int in range(3):
		var fixture: Fixture = _new_fixture(160.0)
		var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
		_check(_dispatch(fixture), "Target-removal fixture dispatched no real packet")
		if removal == 0:
			fixture.network.unregister_node(fixture.second)
		elif removal == 1:
			fixture.second.free()
		else:
			fixture.second.queue_free()
			fixture.growth.advance(1.0)
		_check(not fixture.connection.has_active_task() and fixture.cancelled == [task_id]
			and fixture.connected.is_empty() and fixture.growth.get_completed_endpoint(task_id) == null,
			"Removed target left a live or completed connection")
		_check(fixture.core.nutrition == 256 and fixture.supply.get_in_transit_count() == 0,
			"Target removal failed to refund outstanding nutrition once")
		fixture.growth.advance(1000.0)
		_check(_snapshot(fixture)["consumed_nutrition"] == 0,
			"Removed target allowed growth after cancellation")
		await _remove_fixture(fixture)


func _test_reset_restart_and_stale_callbacks() -> void:
	var fixture: Fixture = _new_fixture(160.0)
	var old_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	var old_snapshot: Dictionary = _snapshot(fixture)
	_check(_dispatch(fixture), "Reset fixture dispatched no packet")
	var old_record: Dictionary = fixture.supply.get_shipment_records()[0]
	var old_packet: NutrientPacket = old_record["packet"]
	fixture.connection.reset()
	_check(fixture.core.nutrition == 256 and _snapshot(fixture)["task_id"] == 0
		and not fixture.growth.has_active_task(), "Reset did not cancel and refund the delegated task")
	var new_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_check(new_id > old_id and _dispatch(fixture), "Reset reused a task ID or prevented restart")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(int(records.back()["shipment_id"]) > int(old_record["shipment_id"]),
		"Connection restart reused a shipment ID")
	old_packet.arrived.emit(old_packet)
	old_packet.interrupted.emit(old_packet)
	old_packet.tree_exiting.emit()
	fixture.growth.task_changed.emit(old_snapshot)
	fixture.growth.task_cancelled.emit(old_id)
	fixture.growth.task_completed.emit(old_id)
	_check(_snapshot(fixture)["task_id"] == new_id and _snapshot(fixture)["buffered_nutrition"] == 0
		and fixture.supply.get_in_transit_count() == 1 and fixture.core.nutrition == 255,
		"Stale packet or task callbacks changed the restarted task")
	_check(fixture.cancelled == [old_id] and fixture.completed.is_empty(),
		"Stale callbacks were forwarded after reset")
	fixture.connection.cancel_task()
	fixture.connection.reset()
	fixture.connection.reset()
	_check(fixture.core.nutrition == 256, "Repeated reset refunded more than the original debit")
	await _remove_fixture(fixture)


func _test_missing_food_and_core() -> void:
	var fixture: Fixture = _new_fixture(80.0, false, 0)
	_check(fixture.connection.request_connection(fixture.first, fixture.second) > 0,
		"An empty core prevented creating a waiting connection")
	_check(not _dispatch(fixture), "Empty core paid for a connection")
	fixture.growth.advance(1000.0)
	_check(_snapshot(fixture)["wait_reason"] == &"core_empty" and _snapshot(fixture)["distance"] == 0.0
		and _snapshot(fixture)["consumed_nutrition"] == 0, "Missing food produced free growth")
	fixture.connection.cancel_task()
	fixture.core.health = 0
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0
		and fixture.growth.create_connection(fixture.first, fixture.second) == 0,
		"Dead core created a connection")
	fixture.core.health = 240
	fixture.core.add_nutrition(1)
	_check(fixture.connection.request_connection(fixture.first, fixture.second) > 0
		and _dispatch(fixture), "Core-loss fixture could not fund its first extension")
	_deliver(fixture)
	fixture.core.health = 0
	fixture.growth.advance(1000.0)
	_check(_snapshot(fixture)["distance"] == 0.0 and _snapshot(fixture)["consumed_nutrition"] == 0,
		"Core death spent a delivered buffer or produced free growth")
	fixture.supply._process(0.0)
	_check(not fixture.connection.has_active_task() and fixture.core.nutrition == 1,
		"Dead source did not settle and refund its unconsumed original buffer")
	fixture.core.health = 240
	fixture.connection.mother_core = null
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0,
		"Missing configured core created a connection")
	fixture.connection.mother_core = fixture.core
	fixture.network.unregister_node(fixture.core)
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0
		and fixture.growth.create_connection(fixture.first, fixture.second) == 0,
		"Missing registered core created a connection")
	await _remove_fixture(fixture)


func _test_rejected_final_registration() -> void:
	var network: RejectingNetwork = RejectingNetwork.new()
	var fixture: Fixture = _new_fixture(80.0, false, 256, network)
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_check(network.attempts == 1 and not fixture.connection.has_active_task()
		and fixture.cancelled == [task_id] and fixture.completed.is_empty(),
		"Rejected final corridor looped in one advance or reported completion")
	_check(fixture.core.nutrition == 255 and fixture.growth.get_completed_endpoint(task_id) == null,
		"Rejected final registration refunded consumed structure or exposed an endpoint")
	await _remove_fixture(fixture)


func _on_final_network_change(fixture: Fixture, trigger: Trigger, remove_source: bool) -> void:
	if trigger.fired or not fixture.growth.has_active_task():
		return
	for child: Node in fixture.growth.edge_container.get_children():
		if child is HyphaEdge and (child as HyphaEdge).connects(fixture.first, fixture.second):
			trigger.fired = true
			if remove_source:
				fixture.network.unregister_edge(fixture.feed)
			else:
				fixture.network.unregister_node(fixture.second)
			break


func _test_target_removed_during_final_commit() -> void:
	var fixture: Fixture = _new_fixture()
	var task_id: int = fixture.connection.request_connection(fixture.first, fixture.second)
	var trigger: Trigger = Trigger.new()
	fixture.network.network_changed.connect(_on_final_network_change.bind(fixture, trigger, false))
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_check(trigger.fired and fixture.cancelled == [task_id] and fixture.completed.is_empty()
		and fixture.connected.is_empty(), "Synchronous target removal committed a stale final endpoint")
	_check(fixture.growth.get_completed_endpoint(task_id) == null and fixture.core.nutrition == 255
		and fixture.growth.edge_container.get_child_count() == 2,
		"Synchronous target removal lost the paid strand or created a free junction")
	await _remove_fixture(fixture)


func _test_source_lost_during_final_commit() -> void:
	var fixture: Fixture = _new_fixture(80.0, true)
	fixture.connection.request_connection(fixture.first, fixture.second)
	var trigger: Trigger = Trigger.new()
	fixture.network.network_changed.connect(_on_final_network_change.bind(fixture, trigger, true))
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_check(trigger.fired and fixture.connection.has_active_task() and fixture.completed.is_empty()
		and _snapshot(fixture)["wait_reason"] == &"disconnected",
		"Final commit used the uncommitted opposite host to disguise source supply loss")
	_check(not fixture.network.has_direct_connection(fixture.first, fixture.second),
		"Uncommitted final edge was left connected during source waiting")
	fixture.network.register_edge(fixture.feed)
	_drive_to_completion(fixture)
	_check(fixture.core.nutrition == 255, "Final commit retry charged the extension twice")
	await _remove_fixture(fixture)


func _reset_on_snapshot(snapshot: Dictionary, fixture: Fixture, trigger: Trigger, state: StringName) -> void:
	if not trigger.fired and snapshot.get("state") == state:
		trigger.fired = true
		fixture.connection.reset()


func _reset_on_connection(
	_task_id: int, _source: HyphaNode, _target: HyphaNode, fixture: Fixture, trigger: Trigger
) -> void:
	if not trigger.fired:
		trigger.fired = true
		fixture.connection.reset()


func _restart_on_connection(
	_task_id: int, _source: HyphaNode, _target: HyphaNode,
	fixture: Fixture, trigger: Trigger, next_target: HyphaNode
) -> void:
	if not trigger.fired:
		trigger.fired = true
		trigger.new_task_id = fixture.connection.request_connection(fixture.first, next_target)


func _test_reentrant_creation_and_terminal_callbacks() -> void:
	var fixture: Fixture = _new_fixture()
	var trigger: Trigger = Trigger.new()
	fixture.connection.task_changed.connect(_reset_on_snapshot.bind(fixture, trigger, &"waiting"))
	_check(fixture.connection.request_connection(fixture.first, fixture.second) == 0
		and trigger.fired and not fixture.growth.has_active_task() and _snapshot(fixture)["task_id"] == 0,
		"Reset inside initial snapshot returned a stale connection ID or left growth active")
	await _remove_fixture(fixture)
	for reset_state: StringName in [&"completed", &"cancelled"]:
		fixture = _new_fixture()
		fixture.connection.request_connection(fixture.first, fixture.second)
		trigger = Trigger.new()
		fixture.connection.task_changed.connect(_reset_on_snapshot.bind(fixture, trigger, reset_state))
		if reset_state == &"completed":
			_dispatch_demand(fixture)
			_deliver(fixture)
			fixture.growth.advance(1000.0)
		else:
			fixture.connection.cancel_task()
		_check(trigger.fired and _snapshot(fixture)["task_id"] == 0
			and fixture.completed.is_empty() and fixture.cancelled.is_empty() and fixture.connected.is_empty(),
			"Terminal snapshot reset was followed by stale task or host events")
		await _remove_fixture(fixture)
	fixture = _new_fixture()
	fixture.connection.request_connection(fixture.first, fixture.second)
	trigger = Trigger.new()
	fixture.connection.connection_completed.connect(_reset_on_connection.bind(fixture, trigger))
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_check(trigger.fired and fixture.connected.size() == 1 and fixture.completed.is_empty()
		and _snapshot(fixture)["task_id"] == 0, "Host completion reset was followed by a stale task_completed")
	await _remove_fixture(fixture)
	fixture = _new_fixture()
	var first_task: int = fixture.connection.request_connection(fixture.first, fixture.second)
	var next_target: HyphaNode = _new_node(fixture, Vector2(160.0, 80.0))
	trigger = Trigger.new()
	fixture.connection.connection_completed.connect(_restart_on_connection.bind(fixture, trigger, next_target))
	_dispatch_demand(fixture)
	_deliver(fixture)
	fixture.growth.advance(1000.0)
	_check(trigger.new_task_id > first_task and _snapshot(fixture)["task_id"] == trigger.new_task_id
		and _snapshot(fixture)["target_node"] == next_target and fixture.completed.is_empty(),
		"Completion reentry lost the new task or emitted the old terminal ID afterwards")
	fixture.growth.task_completed.emit(first_task)
	fixture.growth.task_cancelled.emit(first_task)
	_check(fixture.connected.size() == 1 and fixture.completed.is_empty() and fixture.cancelled.is_empty(),
		"Reentrant new task accepted old terminal callbacks")
	await _remove_fixture(fixture)
