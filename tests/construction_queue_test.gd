extends SceneTree
## 阶段七队列契约的最小生产系统夹具；不是正式关卡集成证据。
## 运行：Godot --headless --fixed-fps 60 --path . --script tests/construction_queue_test.gd
## 不伪造首次营养到达；状态攻击只重放任务通知或已取消包的结算回调。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const CAPITAL: int = 64
const STEP: float = 0.1
const STEP_LIMIT: int = 1600

var checks: int = 0
var failures: Array[String] = []
var cases: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_capacity_duplicates_and_copies()
	await _test_sort_pause_and_selection()
	await _test_deferred_reset_and_local_c()
	await _test_active_refund_and_fake_events()
	await _test_temporary_disconnect()
	await _test_permanent_revalidation()
	await _test_completion_identity_and_reset()
	_check(root.get_child_count() == 0, "Unit fixtures leave no scene objects")
	print("CONSTRUCTION_QUEUE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases,
		"evidence": "minimal_fixture_with_original_systems",
		"formal_scene_integration": false, "first_arrivals_fabricated": false,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture(auto_execute: bool = false) -> Dictionary:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	var fixture: Dictionary = {"world": world}
	for key: String in ["nodes", "edges", "tips", "growth_packets", "cultivation_packets", "enemies", "projectiles"]:
		var container: Node2D = Node2D.new()
		world.add_child(container)
		fixture[key] = container
	var core: MotherCore = _new_core(world, Vector2(200, 400))
	var network: NetworkSystem = NetworkSystem.new()
	world.add_child(network)
	fixture["core"] = core
	fixture["network"] = network
	_check(network.register_node(core, true), "Fixture registers its actual payer")
	fixture["front"] = _add_host(fixture, Vector2(400, 400))
	fixture["rear"] = _add_host(fixture, Vector2(400, 560))
	fixture["front_edge"] = _add_edge(fixture, core, fixture["front"])
	fixture["rear_edge"] = _add_edge(fixture, core, fixture["rear"])
	var growth: GrowthSystem = GrowthSystem.new()
	growth.network_system = network
	growth.node_container = fixture["nodes"]
	growth.edge_container = fixture["edges"]
	growth.tip_container = fixture["tips"]
	world.add_child(growth)
	growth.set_physics_process(false)
	var cultivation: CultivationSystem = CultivationSystem.new()
	cultivation.network_system = network
	cultivation.growth_system = growth
	cultivation.enemy_container = fixture["enemies"]
	cultivation.projectile_container = fixture["projectiles"]
	world.add_child(cultivation)
	cultivation.set_physics_process(false)
	growth.construction_blocker = cultivation.has_active_task
	var growth_supply: GrowthSupplySystem = GrowthSupplySystem.new()
	growth_supply.growth_system = growth
	growth_supply.mother_core = core
	growth_supply.network_system = network
	growth_supply.packet_container = fixture["growth_packets"]
	growth_supply.auto_supply = false
	world.add_child(growth_supply)
	growth_supply.set_process(false)
	var cultivation_supply: CultivationSupplySystem = CultivationSupplySystem.new()
	cultivation_supply.cultivation_system = cultivation
	cultivation_supply.mother_core = core
	cultivation_supply.network_system = network
	cultivation_supply.packet_container = fixture["cultivation_packets"]
	cultivation_supply.auto_supply = false
	world.add_child(cultivation_supply)
	cultivation_supply.set_process(false)
	var remote: RemoteCultivationSystem = RemoteCultivationSystem.new()
	remote.growth_system = growth
	remote.cultivation_system = cultivation
	remote.growth_supply_system = growth_supply
	remote.cultivation_supply_system = cultivation_supply
	world.add_child(remote)
	var connection: ConnectionSystem = ConnectionSystem.new()
	connection.growth_system = growth
	connection.mother_core = core
	world.add_child(connection)
	var capabilities: ColonyCapabilities = ColonyCapabilities.new()
	world.add_child(capabilities)
	var queue: ConstructionQueue = ConstructionQueue.new()
	queue.capabilities = capabilities
	world.add_child(queue)
	var coordinator: ConstructionCoordinator = ConstructionCoordinator.new()
	coordinator.queue = queue
	coordinator.mother_core = core
	coordinator.network_system = network
	coordinator.growth_system = growth
	coordinator.growth_supply_system = growth_supply
	coordinator.remote_cultivation_system = remote
	coordinator.connection_system = connection
	coordinator.cultivation_system = cultivation
	coordinator.cultivation_supply_system = cultivation_supply
	coordinator.auto_execute = auto_execute
	world.add_child(coordinator)
	fixture.merge({"growth": growth, "cultivation": cultivation,
		"growth_supply": growth_supply, "cultivation_supply": cultivation_supply,
		"remote": remote, "connection": connection, "queue": queue, "coordinator": coordinator})
	for key: String in ["growth_packets", "cultivation_packets"]:
		var container: Node2D = fixture[key]
		container.child_entered_tree.connect(func(packet: Node) -> void:
			packet.set_physics_process(false))
	return fixture


func _new_core(world: Node2D, point: Vector2) -> MotherCore:
	var core: MotherCore = MotherCore.new()
	var bar: ProgressBar = ProgressBar.new()
	bar.name = "HealthBar"
	core.add_child(bar)
	core.position = point
	core.initial_nutrition = CAPITAL
	world.add_child(core)
	return core


func _add_host(fixture: Dictionary, point: Vector2) -> HyphaNode:
	var host: HyphaNode = HyphaNode.new()
	var ring: Line2D = Line2D.new()
	ring.name = "SelectionRing"
	host.add_child(ring)
	var container: Node2D = fixture["nodes"]
	container.add_child(host)
	host.global_position = point
	var network: NetworkSystem = fixture["network"]
	_check(network.register_node(host), "Fixture registers a live mature endpoint")
	return host


func _add_edge(fixture: Dictionary, first: Node2D, second: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	var container: Node2D = fixture["edges"]
	container.add_child(edge)
	var network: NetworkSystem = fixture["network"]
	_check(network.register_edge(edge), "Fixture registers an original transport edge")
	return edge


func _coordinator(fixture: Dictionary) -> ConstructionCoordinator:
	return fixture["coordinator"] as ConstructionCoordinator


func _queue(fixture: Dictionary) -> ConstructionQueue:
	return fixture["queue"] as ConstructionQueue


func _growth_parameters(fixture: Dictionary) -> Dictionary:
	return {"start_node": fixture["front"], "target_position": Vector2(560, 400)}


func _remote_parameters(fixture: Dictionary) -> Dictionary:
	return {"start_node": fixture["rear"], "target_position": Vector2(400, 720)}


func _connection_parameters(fixture: Dictionary) -> Dictionary:
	return {"first_node": fixture["front"], "second_node": fixture["rear"]}


func _admit(fixture: Dictionary, kind: StringName, parameters: Dictionary) -> String:
	var result: Dictionary = _coordinator(fixture).enqueue(kind, parameters)
	var construction_id: String = String(result.get("construction_id", ""))
	_check(bool(result.get("accepted", false)) and not construction_id.is_empty(),
		"%s admission returns an accepted stable construction ID" % kind)
	return construction_id


func _order(queue: ConstructionQueue) -> Array[String]:
	var result: Array[String] = []
	for entry: Dictionary in queue.get_snapshot()["entries"]:
		result.append(String(entry["construction_id"]))
	return result


func _identity(request: Dictionary) -> Dictionary:
	return {"construction_id": request.get("construction_id", ""),
		"sequence": request.get("sequence", 0), "kind": request.get("kind", &""),
		"parameters": request.get("parameters", {}).duplicate(true),
		"payer": request.get("payer"), "payer_id": request.get("payer_id", 0),
		"internal_ids": request.get("internal_ids", {}).duplicate(true)}


func _pump_frames(fixture: Dictionary, count: int = 2) -> void:
	for _frame: int in range(count):
		_coordinator(fixture).pump()
		await process_frame
	_coordinator(fixture).pump()


func _tick(fixture: Dictionary) -> void:
	_coordinator(fixture).pump()
	var growth_supply: GrowthSupplySystem = fixture["growth_supply"]
	var cultivation_supply: CultivationSupplySystem = fixture["cultivation_supply"]
	growth_supply.try_dispatch()
	cultivation_supply.try_dispatch()
	for key: String in ["growth_packets", "cultivation_packets"]:
		var container: Node2D = fixture[key]
		for child: Node in container.get_children():
			if child is NutrientPacket and not child.is_queued_for_deletion():
				child.call("_physics_process", STEP)
	var growth: GrowthSystem = fixture["growth"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	growth.advance(STEP)
	cultivation.advance(STEP)
	growth_supply.call("_process", 0.0)
	cultivation_supply.call("_process", 0.0)
	await process_frame
	_coordinator(fixture).pump()


func _until(fixture: Dictionary, condition: Callable, label: String) -> bool:
	for _step: int in range(STEP_LIMIT):
		if bool(condition.call()):
			break
		await _tick(fixture)
	var reached: bool = bool(condition.call())
	_check(reached, label + " within the bounded original-system fixture steps")
	return reached


func _dispose(fixture: Dictionary) -> void:
	# 队列必须先取消自身执行者，原母核和供养系统此时仍在树中。
	_coordinator(fixture).reset()
	var growth_supply: GrowthSupplySystem = fixture["growth_supply"]
	var cultivation_supply: CultivationSupplySystem = fixture["cultivation_supply"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var connection: ConnectionSystem = fixture["connection"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	remote.reset()
	connection.reset()
	growth_supply.reset()
	cultivation_supply.reset()
	cultivation.reset()
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


func _test_capacity_duplicates_and_copies() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = _queue(fixture)
	var core: MotherCore = fixture["core"]
	var parameters: Dictionary = _growth_parameters(fixture)
	var growth_id: String = _admit(fixture, &"growth", parameters)
	var remote_id: String = _admit(fixture, &"remote_cultivation", _remote_parameters(fixture))
	var connection_id: String = _admit(fixture, &"connection", _connection_parameters(fixture))
	var expected: Array[String] = [growth_id, remote_id, connection_id]
	_check(_order(queue) == expected and int(queue.get_snapshot()["limit"]) == 3,
		"Exactly three active external requests use the capability limit")
	var rejected: Dictionary = _coordinator(fixture).enqueue(&"growth",
		{"start_node": fixture["front"], "target_position": Vector2(620, 400)})
	_check(not bool(rejected.get("accepted", true)) and rejected.get("reason") == &"queue_full"
		and String(rejected.get("construction_id", "unexpected")).is_empty(),
		"A fourth distinct request is rejected with queue_full and an empty ID")
	for duplicate: Dictionary in [
		{"kind": &"growth", "parameters": {"start_node": fixture["front"], "target_position": Vector2(560.5, 400)}, "id": growth_id},
		{"kind": &"remote_cultivation", "parameters": {"start_node": fixture["rear"], "target_position": Vector2(400, 720.5)}, "id": remote_id},
		{"kind": &"connection", "parameters": {"first_node": fixture["rear"], "second_node": fixture["front"]}, "id": connection_id},
	]:
		var result: Dictionary = _coordinator(fixture).enqueue(duplicate["kind"], duplicate["parameters"])
		_check(not bool(result.get("accepted", true)) and result.get("reason") == &"duplicate"
			and result.get("construction_id") == duplicate["id"]
			and queue.get_snapshot()["selected_id"] == duplicate["id"] and _order(queue) == expected,
			"A full queue recognizes %s duplication, returns the same ID and selects that row" % duplicate["kind"])
	parameters["start_node"] = fixture["rear"]
	parameters["target_position"] = Vector2.ZERO
	var original: Dictionary = _identity(queue.get_request(growth_id))
	_check(original["parameters"] == _growth_parameters(fixture) and original["payer"] == core
		and int(original["payer_id"]) == core.get_instance_id(), "Admission captures original parameters and payer")
	var copy: Dictionary = queue.get_request(growth_id)
	copy["parameters"]["target_position"] = Vector2.ZERO
	copy["internal_ids"]["growth_task_id"] = 999
	copy["detail"]["caller_mutation"] = {"array": [1, 2]}
	copy["state"] = &"failed"
	var snapshot: Dictionary = queue.get_snapshot()
	snapshot["entries"][0]["parameters"]["start_node"] = fixture["rear"]
	snapshot["entries"].clear()
	snapshot["selected_id"] = "forged"
	_check(_identity(queue.get_request(growth_id)) == original and _order(queue) == expected
		and not queue.get_request(growth_id)["detail"].has("caller_mutation"),
		"Returned request and nested snapshot dictionaries cannot mutate queue storage")
	queue.changed.connect(func(changed: Dictionary) -> void:
		for entry: Dictionary in changed.get("entries", []):
			entry["parameters"].clear()
			entry["internal_ids"]["growth_task_id"] = -1
		changed["entries"].clear())
	queue.select_request(growth_id)
	_check(_identity(queue.get_request(growth_id)) == original,
		"Mutating a changed signal snapshot cannot alter captured storage")
	for construction_id: String in expected:
		var request: Dictionary = queue.get_request(construction_id)
		_check(request["state"] == &"waiting" and not bool(request["started"])
			and request["internal_ids"] == {"growth_task_id": 0, "remote_request_id": 0, "cultivation_task_id": 0},
			"Waiting admission owns no original executor IDs")
	_check(core.nutrition == CAPITAL and core.get_budget_snapshot()["reservations"].is_empty()
		and not (fixture["growth"] as GrowthSystem).has_active_task()
		and not (fixture["remote"] as RemoteCultivationSystem).has_active_request(),
		"All admission, duplication, copies and selection create no task, payment or reservation")
	_check(queue.get_request("unknown").is_empty() and not queue.select_request("unknown"),
		"Unknown IDs neither resolve nor select another row")
	_check(queue.select_request("") and queue.get_snapshot()["selected_id"] == ""
		and _order(queue) == expected, "An explicit empty ID clears selection without changing queue order")
	_check(_coordinator(fixture).select_request(remote_id) and _coordinator(fixture).cancel_request(remote_id),
		"The selected unstarted middle row cancels through the queue coordinator")
	var after_middle_cancel: Array[String] = [growth_id, connection_id]
	_check(_order(queue) == after_middle_cancel and queue.get_request(remote_id)["state"] == &"cancelled"
		and queue.get_snapshot()["selected_id"] == "" and core.nutrition == CAPITAL,
		"Middle cancellation preserves both neighbors, clears selection and makes no refund")
	cases.append("capacity_duplicates_immutable_copies")
	await _dispose(fixture)


func _test_sort_pause_and_selection() -> void:
	var fixture: Dictionary = _fixture()
	var coordinator: ConstructionCoordinator = _coordinator(fixture)
	var queue: ConstructionQueue = _queue(fixture)
	var growth_id: String = _admit(fixture, &"growth", _growth_parameters(fixture))
	var remote_id: String = _admit(fixture, &"remote_cultivation", _remote_parameters(fixture))
	var connection_id: String = _admit(fixture, &"connection", _connection_parameters(fixture))
	var identities: Dictionary = {}
	for construction_id: String in [growth_id, remote_id, connection_id]:
		identities[construction_id] = _identity(queue.get_request(construction_id))
	_check(coordinator.move_request(connection_id, -1) and coordinator.move_request(connection_id, -1),
		"An unstarted waiting row moves through two unstarted peers")
	var sorted_ids: Array[String] = [connection_id, growth_id, remote_id]
	_check(_order(queue) == sorted_ids and not coordinator.move_request(connection_id, -1)
		and not coordinator.move_request(remote_id, 1), "Sorting respects both boundaries")
	for construction_id: String in sorted_ids:
		_check(_identity(queue.get_request(construction_id)) == identities[construction_id],
			"Sorting retains immutable sequence, original endpoint order, payer and executor IDs")
	_check(coordinator.pause_request(connection_id), "An unstarted request can be paused")
	coordinator.pump()
	_check(queue.get_snapshot()["active_id"] == growth_id and queue.get_request(growth_id)["started"]
		and queue.get_request(connection_id)["state"] == &"paused"
		and queue.get_request(connection_id)["wait_reason"] == &"paused",
		"A paused pending head is skipped while preserving its stable row")
	var active_identity: Dictionary = _identity(queue.get_request(growth_id))
	_check(not coordinator.move_request(growth_id, 1) and not coordinator.move_request(remote_id, -1)
		and _identity(queue.get_request(growth_id)) == active_identity,
		"Started rows cannot move or be crossed by waiting rows")
	_check(coordinator.select_request(remote_id) and coordinator.cancel_request(remote_id),
		"A selected pending middle/tail request can be cancelled without executing")
	var remaining: Array[String] = [connection_id, growth_id]
	_check(_order(queue) == remaining and queue.get_request(remote_id)["state"] == &"cancelled"
		and not queue.get_request(remote_id)["started"] and queue.get_snapshot()["selected_id"] == "",
		"Pending cancellation removes one active slot, retains history and clears selection")
	_check((fixture["core"] as MotherCore).nutrition == CAPITAL,
		"Cancelling an uncharged pending request neither refunds nor spends")
	var next_id: String = _admit(fixture, &"growth",
		{"start_node": fixture["rear"], "target_position": Vector2(560, 560)})
	_check(int(queue.get_request(next_id)["sequence"]) > int(identities[connection_id]["sequence"]),
		"Freed capacity uses a new monotonically increasing admission sequence")
	_check(coordinator.cancel_request(growth_id), "Executing growth cancels its original task")
	await _pump_frames(fixture)
	_check(queue.get_snapshot()["active_id"] == next_id
		and _identity(queue.get_request(connection_id)) == identities[connection_id],
		"Cancellation advances past paused pending work without altering its captured identity")
	_check(coordinator.cancel_request(next_id) and queue.get_snapshot()["selected_id"] == "",
		"Cancelling a selected executor clears selection without auto-selecting another request")
	_check(coordinator.resume_request(connection_id), "The paused original connection can resume")
	await _pump_frames(fixture)
	var connection: ConnectionSystem = fixture["connection"]
	var request: Dictionary = queue.get_request(connection_id)
	_check(queue.get_snapshot()["active_id"] == connection_id and connection.has_active_task()
		and int(request["internal_ids"]["growth_task_id"]) == int(connection.get_task_snapshot()["task_id"])
		and request["parameters"] == _connection_parameters(fixture),
		"Resumption calls the original connection with the captured endpoint order")
	cases.append("waiting_sort_pause_skip_cancel_middle_selection")
	await _dispose(fixture)


func _test_deferred_reset_and_local_c() -> void:
	var fixture: Dictionary = _fixture(true)
	var coordinator: ConstructionCoordinator = _coordinator(fixture)
	var queue: ConstructionQueue = _queue(fixture)
	var generation: int = queue.get_generation()
	var old_id: String = _admit(fixture, &"growth", _growth_parameters(fixture))
	var old_sequence: int = int(queue.get_request(old_id)["sequence"])
	_check(queue.get_snapshot()["active_id"] == "" and not queue.get_request(old_id)["started"]
		and not (fixture["growth"] as GrowthSystem).has_active_task()
		and (fixture["tips"] as Node2D).get_child_count() == 0,
		"Auto execution is deferred beyond the synchronous enqueue call")
	coordinator.reset()
	await process_frame
	await process_frame
	_check(queue.get_generation() > generation and queue.get_snapshot()["entries"].is_empty()
		and queue.get_request(old_id).is_empty() and queue.get_snapshot()["selected_id"] == ""
		and not (fixture["growth"] as GrowthSystem).has_active_task(),
		"Reset invalidates the old deferred generation and clears queue, history and selection")
	coordinator.auto_execute = false
	var cultivation: CultivationSystem = fixture["cultivation"]
	var local_id: int = cultivation.start_cultivation(fixture["rear"])
	_check(local_id > 0 and cultivation.pause_task(), "Legacy local C owns its original paused executor")
	var fresh_id: String = _admit(fixture, &"growth", _growth_parameters(fixture))
	coordinator.pump()
	_check(fresh_id != old_id and int(queue.get_request(fresh_id)["sequence"]) > old_sequence
		and not queue.get_request(fresh_id)["started"]
		and queue.get_request(fresh_id)["wait_reason"] == &"pipeline_busy"
		and int(cultivation.get_task_snapshot()["task_id"]) == local_id,
		"Local C permits enqueue but holds external execution even while C is paused")
	_check(cultivation.cancel_task(), "Legacy C cancellation uses its original receiver")
	await _pump_frames(fixture)
	_check(queue.get_snapshot()["active_id"] == fresh_id
		and (fixture["core"] as MotherCore).nutrition == CAPITAL,
		"External work starts after local C settles without an admission charge")
	cases.append("deferred_generation_reset_local_c_blocks")
	await _dispose(fixture)


func _owner_callbacks(packet: Node, owner: Node, event: StringName) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(event):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _test_active_refund_and_fake_events() -> void:
	var fixture: Dictionary = _fixture()
	var coordinator: ConstructionCoordinator = _coordinator(fixture)
	var queue: ConstructionQueue = _queue(fixture)
	var core: MotherCore = fixture["core"]
	var growth: GrowthSystem = fixture["growth"]
	var supply: GrowthSupplySystem = fixture["growth_supply"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var first_id: String = _admit(fixture, &"growth", _growth_parameters(fixture))
	var second_id: String = _admit(fixture, &"remote_cultivation", _remote_parameters(fixture))
	coordinator.pump()
	var task_id: int = int(queue.get_request(first_id)["internal_ids"]["growth_task_id"])
	_check(task_id > 0 and task_id == int(growth.get_task_snapshot()["task_id"]),
		"Executing growth exposes its exact original task identity")
	_check(supply.try_dispatch() and core.nutrition == CAPITAL - 1 and supply.get_in_transit_count() == 1,
		"Only original dispatch debits the original payer and creates one owned packet")
	var records: Array[Dictionary] = supply.get_shipment_records()
	var packet: NutrientPacket = records[0]["packet"] as NutrientPacket
	var callbacks: Array[Callable] = _owner_callbacks(packet, supply, &"arrived")
	callbacks.append_array(_owner_callbacks(packet, supply, &"interrupted"))
	_check(not callbacks.is_empty() and records[0]["source"] == core and int(records[0]["task_id"]) == task_id,
		"Paid packet captures this payer and this internal executor")
	_check(coordinator.pause_request(first_id), "Executing work pauses through its original executor")
	var held_identity: Dictionary = _identity(queue.get_request(first_id))
	coordinator.pump()
	_check(queue.get_snapshot()["active_id"] == first_id and queue.get_request(first_id)["state"] == &"paused"
		and not queue.get_request(second_id)["started"] and _identity(queue.get_request(first_id)) == held_identity,
		"An executing paused request retains the single pipeline and stable internal IDs")
	_check(coordinator.cancel_request(first_id), "Active cancellation calls the matching original growth task")
	_check(core.nutrition == CAPITAL and supply.get_in_transit_count() == 0
		and int(growth.get_task_snapshot()["buffered_nutrition"]) == 0
		and growth.get_task_snapshot()["state"] == &"cancelled"
		and queue.get_request(first_id)["state"] == &"cancelled",
		"Original cancellation refunds the original paid transit exactly once before another start")
	# 真实取消已结算，趁旧包仍在本帧待销毁时重放；跨帧后不使用失效的对象引用。
	var replayed: int = 0
	for callback: Callable in callbacks:
		if callback.is_valid() and is_instance_valid(packet):
			callback.call(packet)
			callback.call(packet)
			replayed += 2
	_check(replayed >= 2 and core.nutrition == CAPITAL and supply.get_in_transit_count() == 0,
		"Repeated already-cancelled original callbacks cannot duplicate the original refund")
	await _pump_frames(fixture)
	var second: Dictionary = queue.get_request(second_id)
	var internal: Dictionary = second["internal_ids"]
	_check(second["started"] and int(internal["remote_request_id"]) > 0
		and int(internal["growth_task_id"]) > task_id and int(internal["cultivation_task_id"]) == 0,
		"Next remote work has its own original request/growth IDs and no premature cultivation ID")
	growth.task_completed.emit(task_id)
	growth.task_completed.emit(int(internal["growth_task_id"]))
	remote.request_completed.emit(int(internal["remote_request_id"]))
	var forged: Dictionary = growth.get_task_snapshot().duplicate(true)
	forged["state"] = &"completed"
	growth.task_changed.emit(forged)
	(fixture["connection"] as ConnectionSystem).task_completed.emit(task_id)
	coordinator.pump()
	_check(core.nutrition == CAPITAL and _identity(queue.get_request(second_id)) == _identity(second)
		and queue.get_request(second_id)["state"] == &"executing"
		and growth.has_active_task() and not (fixture["cultivation"] as CultivationSystem).has_active_task(),
		"Retired, repeated and fabricated current completion events cannot fund, finish or hand off the next request")
	cases.append("active_pause_holds_original_refund_fake_duplicate_events")
	await _dispose(fixture)


func _test_temporary_disconnect() -> void:
	var fixture: Dictionary = _fixture()
	var coordinator: ConstructionCoordinator = _coordinator(fixture)
	var queue: ConstructionQueue = _queue(fixture)
	var network: NetworkSystem = fixture["network"]
	var edge: HyphaEdge = fixture["front_edge"]
	var blocked_id: String = _admit(fixture, &"growth", _growth_parameters(fixture))
	var later_id: String = _admit(fixture, &"growth",
		{"start_node": fixture["rear"], "target_position": Vector2(560, 560)})
	var captured: Dictionary = _identity(queue.get_request(blocked_id))
	network.unregister_edge(edge)
	await _pump_frames(fixture)
	_check(queue.get_request(blocked_id)["state"] == &"waiting"
		and queue.get_request(blocked_id)["wait_reason"] == &"disconnected"
		and not queue.get_request(blocked_id)["started"] and not queue.get_request(later_id)["started"]
		and queue.get_snapshot()["active_id"] == "" and (fixture["core"] as MotherCore).nutrition == CAPITAL,
		"A temporary disconnected unpaused head waits, blocks later work and charges nothing")
	_check(coordinator.pause_request(blocked_id), "A temporarily disconnected pending head can be paused")
	await _pump_frames(fixture)
	_check(queue.get_snapshot()["active_id"] == later_id,
		"Explicitly pausing the disconnected pending head allows the later connected request")
	_check(coordinator.cancel_request(later_id) and network.register_edge(edge),
		"The later original task cancels and the same original transport edge reconnects")
	_check(coordinator.resume_request(blocked_id), "Disconnected work resumes using its original row")
	await _pump_frames(fixture)
	var request: Dictionary = queue.get_request(blocked_id)
	_check(request["started"] and request["state"] == &"executing"
		and request["parameters"] == captured["parameters"] and request["payer"] == captured["payer"]
		and request["payer_id"] == captured["payer_id"] and request["sequence"] == captured["sequence"],
		"Reconnection starts the frozen origin/payer without retargeting or a new construction ID")
	cases.append("temporary_disconnect_head_waits_paused_skip_reconnect")
	await _dispose(fixture)


func _test_permanent_revalidation() -> void:
	for invalidation: String in ["deleted_endpoint", "unregistered_endpoint", "invalid_geometry",
			"occupied_remote_target", "already_connected", "dead_payer", "replaced_payer"]:
		var fixture: Dictionary = _fixture()
		var coordinator: ConstructionCoordinator = _coordinator(fixture)
		var queue: ConstructionQueue = _queue(fixture)
		var network: NetworkSystem = fixture["network"]
		var core: MotherCore = fixture["core"]
		var kind: StringName = &"growth"
		var parameters: Dictionary = _growth_parameters(fixture)
		if invalidation == "unregistered_endpoint" or invalidation == "already_connected":
			kind = &"connection"
			parameters = _connection_parameters(fixture)
		elif invalidation == "occupied_remote_target":
			kind = &"remote_cultivation"
			parameters = _remote_parameters(fixture)
		var construction_id: String = _admit(fixture, kind, parameters)
		var original_payer_id: int = int(queue.get_request(construction_id)["payer_id"])
		var later_id: String = ""
		if invalidation == "deleted_endpoint" or invalidation == "invalid_geometry":
			later_id = _admit(fixture, &"growth",
				{"start_node": fixture["rear"], "target_position": Vector2(560, 560)})
		match invalidation:
			"deleted_endpoint":
				(fixture["front"] as HyphaNode).queue_free()
			"unregistered_endpoint":
				network.unregister_node(fixture["rear"])
			"invalid_geometry":
				(fixture["front"] as HyphaNode).global_position = parameters["target_position"]
			"occupied_remote_target":
				var occupant: HyphaNode = _add_host(fixture, parameters["target_position"])
				occupant.add_child(ATTACK_SCENE.instantiate())
			"already_connected":
				_add_edge(fixture, fixture["front"], fixture["rear"])
			"dead_payer":
				core.take_damage(core.max_health)
			"replaced_payer":
				var replacement: MotherCore = _new_core(fixture["world"], Vector2(100, 100))
				coordinator.mother_core = replacement
				(fixture["growth_supply"] as GrowthSupplySystem).mother_core = replacement
				(fixture["cultivation_supply"] as CultivationSupplySystem).mother_core = replacement
		await _pump_frames(fixture)
		var failed: Dictionary = queue.get_request(construction_id)
		_check(failed.get("state") == &"failed" and not bool(failed.get("started", true))
			and int(failed.get("payer_id", 0)) == original_payer_id and core.nutrition == CAPITAL,
			"Permanent %s fails the frozen request without starting, paying or refunding" % invalidation)
		_check(not String(failed.get("wait_reason", "")).is_empty(),
			"Permanent %s retains an explicit terminal failure reason" % invalidation)
		if not later_id.is_empty():
			_check(queue.get_snapshot()["active_id"] == later_id and queue.get_request(later_id)["started"],
				"A permanently invalid head advances to the next valid captured request")
		await _dispose(fixture)
	cases.append("permanent_deleted_unregistered_geometry_host_connection_payer_revalidation")


func _test_completion_identity_and_reset() -> void:
	var fixture: Dictionary = _fixture()
	var coordinator: ConstructionCoordinator = _coordinator(fixture)
	var queue: ConstructionQueue = _queue(fixture)
	var core: MotherCore = fixture["core"]
	var growth: GrowthSystem = fixture["growth"]
	var finished: Array[String] = []
	coordinator.request_finished.connect(func(construction_id: String, state: StringName) -> void:
		if state == &"completed":
			finished.append(construction_id))
	var first_id: String = _admit(fixture, &"growth", _growth_parameters(fixture))
	var next_id: String = _admit(fixture, &"connection", _connection_parameters(fixture))
	coordinator.select_request(first_id)
	coordinator.pump()
	var first_task: int = int(queue.get_request(first_id)["internal_ids"]["growth_task_id"])
	var first_sequence: int = int(queue.get_request(first_id)["sequence"])
	var reached: bool = await _until(fixture, func() -> bool:
		return queue.get_request(first_id).get("state") == &"completed", "Real growth reaches one terminal queue completion")
	if not reached:
		await _dispose(fixture)
		return
	_check(finished == [first_id] and queue.get_snapshot()["selected_id"] == ""
		and not _order(queue).has(first_id) and growth.get_completed_endpoint(first_task) != null,
		"Completion is unique, retains queryable terminal history, removes its slot and clears its selection")
	await _pump_frames(fixture)
	var before: Dictionary = _identity(queue.get_request(next_id))
	var balance: int = core.nutrition
	growth.task_completed.emit(first_task)
	growth.task_completed.emit(first_task)
	(fixture["connection"] as ConnectionSystem).task_completed.emit(int(before["internal_ids"]["growth_task_id"]))
	coordinator.pump()
	_check(finished == [first_id] and _identity(queue.get_request(next_id)) == before
		and queue.get_request(next_id)["state"] == &"executing" and core.nutrition == balance,
		"Duplicate completed old IDs and fake current connection completion cannot advance the current original executor")
	var stale: Dictionary = growth.get_task_snapshot().duplicate(true)
	var retired_task: int = int(stale["task_id"])
	var generation: int = queue.get_generation()
	coordinator.reset()
	_check(queue.get_generation() > generation and queue.get_request(first_id).is_empty()
		and queue.get_request(next_id).is_empty() and queue.get_snapshot()["active_id"] == ""
		and core.nutrition == balance,
		"Active reset retires all queue history and cancels the uncharged original executor")
	var fresh_id: String = _admit(fixture, &"growth",
		{"start_node": fixture["rear"], "target_position": Vector2(560, 560)})
	_check(fresh_id != first_id and fresh_id != next_id
		and int(queue.get_request(fresh_id)["sequence"]) > first_sequence,
		"Reset never reuses construction identity or admission sequence")
	await _pump_frames(fixture)
	var fresh: Dictionary = _identity(queue.get_request(fresh_id))
	growth.task_changed.emit(stale)
	growth.task_completed.emit(retired_task)
	growth.task_cancelled.emit(retired_task)
	await _pump_frames(fixture)
	_check(_identity(queue.get_request(fresh_id)) == fresh and queue.get_request(fresh_id)["state"] == &"executing"
		and core.nutrition == balance and finished == [first_id],
		"Late changed/completed/cancelled callbacks cannot mutate or settle a fresh generation")
	var other: ConstructionQueue = ConstructionQueue.new()
	other.capabilities = queue.capabilities
	var world: Node2D = fixture["world"]
	world.add_child(other)
	var other_result: Dictionary = other.enqueue(&"growth", _growth_parameters(fixture), core)
	_check(other_result.get("construction_id") != fresh_id and other_result.get("construction_id") != first_id,
		"Separate queue instances also use globally distinguishable construction IDs")
	cases.append("real_terminal_duplicate_event_reset_late_callback_global_identity")
	await _dispose(fixture)
