extends SceneTree
## 只手动推进真实运输包、共享网络/调度器与生长；不记营养业务账本。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const KINDS: Array[StringName] = [&"supply", &"return", &"remains"]

class Fixture:
	extends RefCounted

	var host: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var nodes: Array[Node2D] = []
	var edges: Array[HyphaEdge] = []

class Outcome:
	extends RefCounted

	var arrivals: int = 0
	var interruptions: int = 0
	var valid_arrival: bool = false
	var target: Node2D
	var task_id: String = ""
	var terminal: Dictionary = {}
	var position: Vector2 = Vector2.ZERO
	var statuses: Array[Dictionary] = []

class Trigger:
	extends RefCounted

	var fired: bool = false
	var calls: int = 0
	var snapshot: Dictionary = {}

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_pure_contract_and_completed_identity()
	_test_before_entry_closure_and_bypass()
	_test_queued_request_replaced_and_cancelled()
	_test_occupied_closure_and_geometry()
	_test_future_change_at_next_node()
	_test_traversed_losses_are_ignored()
	_test_no_route_recovery_and_retry_fingerprint()
	_test_capacity_wait_keeps_fifo_and_plan()
	_test_infinite_wait_estimate_keeps_a_static_route()
	_test_target_edge_and_endpoint_removal()
	_test_scheduler_identity_cancellation()
	_test_zero_length_plans_and_pickup()
	_test_growth_endpoint_handoff()
	_test_request_release_and_status_reentry()
	_check(root.get_child_count() == initial_children, "Reroute fixtures left root children")
	print("PACKET_REROUTE_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _position(actual: Vector2, expected: Vector2, message: String) -> void:
	_check(actual.distance_to(expected) < 0.001,
		message + ": got %s expected %s" % [actual, expected])


func _outcome(outcome: Outcome, arrivals: int, interruptions: int, context: String) -> void:
	_check(outcome.arrivals == arrivals and outcome.interruptions == interruptions,
		context + ": arrived=%d interrupted=%d" % [outcome.arrivals, outcome.interruptions])


func _fixture(points: PackedVector2Array, capacity: int = 2, growth_nodes: bool = false) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.host = Node2D.new()
	root.add_child(fixture.host)
	fixture.network = NetworkSystem.new()
	fixture.host.add_child(fixture.network)
	for index: int in range(points.size()):
		var node: Node2D = Node2D.new()
		if growth_nodes:
			node.free()
			node = CORE_SCENE.instantiate() if index == 0 else NODE_SCENE.instantiate()
		fixture.host.add_child(node)
		node.global_position = points[index]
		fixture.nodes.append(node)
		_check(fixture.network.register_node(node, index == 0), "Fixture node registered")
	for index: int in range(points.size() - 1):
		# 隔段反向存储，同时验证路线方向和两个方向的同一 FIFO。
		var first: Node2D = fixture.nodes[index] if index % 2 == 0 else fixture.nodes[index + 1]
		var last: Node2D = fixture.nodes[index + 1] if index % 2 == 0 else fixture.nodes[index]
		fixture.edges.append(_edge(fixture, first, last, capacity))
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.host.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	return fixture


func _edge(fixture: Fixture, first: Node2D, last: Node2D, capacity: int = 2) -> HyphaEdge:
	var connection: HyphaEdge = EDGE_SCENE.instantiate()
	connection.start_node = first
	connection.end_node = last
	connection.traffic_capacity = capacity
	fixture.host.add_child(connection)
	connection.set_process(false)
	_check(fixture.network.register_edge(connection), "Fixture edge registered")
	return connection


func _node(fixture: Fixture, point: Vector2) -> Node2D:
	var node: Node2D = Node2D.new()
	fixture.host.add_child(node)
	node.global_position = point
	_check(fixture.network.register_node(node), "Bypass node registered")
	return node


func _packet(fixture: Fixture, kind: StringName, outcome: Outcome,
		point: Vector2 = Vector2.ZERO) -> Variant:
	var packet: Variant = RemainsPacket.new() if kind == &"remains" else NutrientPacket.new()
	packet.speed = 100.0
	packet.traffic_required = true
	fixture.host.add_child(packet)
	packet.global_position = point
	packet.set_physics_process(false)
	packet.arrived.connect(func(delivered: Variant) -> void:
		outcome.arrivals += 1
		outcome.valid_arrival = delivered.has_arrived_at(outcome.target, outcome.task_id)
		_capture(delivered, outcome)
	)
	packet.interrupted.connect(func(stopped: Variant) -> void:
		outcome.interruptions += 1
		_capture(stopped, outcome)
	)
	packet.status_changed.connect(func(snapshot: Dictionary) -> void:
		outcome.statuses.append(snapshot)
	)
	return packet


func _capture(packet: Variant, outcome: Outcome) -> void:
	outcome.terminal = packet.get_transport_snapshot()
	outcome.position = packet.global_position


func _start(packet: Variant, fixture: Fixture, kind: StringName, outcome: Outcome,
		first: Node2D = null, last: Node2D = null, task_id: String = "") -> void:
	var source: Node2D = first if first != null else fixture.nodes[0]
	var target: Node2D = last if last != null else fixture.nodes[-1]
	var route: NetworkRoute = fixture.network.find_route(source, target)
	_start_route(packet, fixture, kind, outcome, route, task_id)


func _start_route(packet: Variant, fixture: Fixture, kind: StringName, outcome: Outcome,
		route: NetworkRoute, task_id: String = "") -> void:
	outcome.target = route.end_node
	outcome.task_id = task_id if not task_id.is_empty() else "reroute-test:%d" % packet.get_instance_id()
	if kind == &"remains":
		packet.start_route(route, fixture.network, fixture.traffic, outcome.task_id)
	else:
		packet.start_route(route, fixture.network, fixture.traffic, outcome.task_id, kind)


func _step(packet: Variant, delta: float) -> void:
	if is_instance_valid(packet):
		packet._physics_process(delta)


func _empty_traffic(fixture: Fixture, context: String) -> void:
	var snapshot: Dictionary = fixture.traffic.get_snapshot()
	_check(snapshot["occupied_units"] == 0 and snapshot["queued_count"] == 0
		and snapshot["active_request_count"] == 0, context + ": no request or lease remains")


func _destroy(fixture: Fixture) -> void:
	if is_instance_valid(fixture.host):
		fixture.host.free()


func _test_pure_contract_and_completed_identity() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		var idle: Dictionary = packet.get_transport_snapshot()
		_check(not idle["started"] and not idle["terminal"] and idle["final_target"] == null,
			"Idle trace has no started transport " + String(kind))
		_check(not packet.is_transport_valid(fixture.nodes[-1])
			and not packet.has_arrived_at(fixture.nodes[-1]), "Idle cannot counterfeit delivery")
		packet.speed = 150.0
		_start(packet, fixture, kind, outcome)
		var snapshot: Dictionary = packet.get_transport_snapshot()
		_check(snapshot["started"] and snapshot["final_target"] == outcome.target
			and snapshot["final_target_id"] == outcome.target.get_instance_id()
			and snapshot["location_kind"] == &"edge" and snapshot["route_revision"] == 1,
			"Start captures immutable target and physical location " + String(kind))
		var unrelated: Node2D = _node(fixture, Vector2(500.0, 500.0))
		var trigger: Trigger = Trigger.new()
		fixture.network.network_changed.connect(func() -> void: trigger.calls += 1)
		unrelated.queue_free()
		var before: Dictionary = fixture.traffic.get_snapshot()
		var status_count: int = outcome.statuses.size()
		for attempt: int in range(5):
			_check(packet.is_transport_valid(outcome.target, outcome.task_id), "Active transport is valid")
			_check(not packet.is_transport_valid(fixture.nodes[0], outcome.task_id)
				and not packet.is_transport_valid(outcome.target, "other-task")
				and not packet.has_arrived_at(outcome.target, outcome.task_id), "Target/task and arrival are strict")
			var query: Dictionary = packet.get_transport_snapshot()
			query["final_target_id"] = 0
			query["state"] = &"completed"
		_check(fixture.traffic.get_snapshot() == before and trigger.calls == 0
			and outcome.statuses.size() == status_count, "All packet queries are pure")
		packet.arrived.emit(packet)
		_check(not outcome.valid_arrival and not packet.has_arrived_at(outcome.target, outcome.task_id),
			"A forged arrived signal cannot satisfy physical arrival")
		outcome.arrivals = 0
		packet.arrived.connect(func(delivered: Variant) -> void: delivered.queue_free())
		packet.traffic_required = false
		# 旧导出速度允许业务在启动后配置；速度本身不会替换路线或 FIFO 身份。
		packet.speed = 100.0
		_step(packet, 0.5)
		_position(packet.global_position, Vector2(50.0, 0.0), "Live speed changes apply after dispatch")
		var moving: Dictionary = packet.get_transport_snapshot()
		_check(moving["route_revision"] == snapshot["route_revision"]
			and moving["request_id"] == snapshot["request_id"] and moving["reroute_count"] == 0,
			"Changing speed alone retains the route and passage identity")
		packet.speed = 50.0
		_step(packet, 1.0)
		_outcome(outcome, 1, 0, "Natural physical arrival " + String(kind))
		_check(outcome.valid_arrival and packet.has_arrived_at(outcome.target, outcome.task_id)
			and packet.is_transport_valid(outcome.target, outcome.task_id)
			and packet.is_queued_for_deletion(), "Delivered completion stays valid until deletion")
		_check(outcome.terminal["terminal"] and outcome.terminal["location_kind"] == &"node"
			and outcome.terminal["traffic_required"], "Terminal trace retains captured requirement")
		_empty_traffic(fixture, "Completed contract")
		_destroy(fixture)


func _test_before_entry_closure_and_bypass() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[-1])
		var bypass: Node2D = _node(fixture, Vector2(50.0, 50.0))
		var first: HyphaEdge = _edge(fixture, fixture.nodes[0], bypass)
		_edge(fixture, bypass, fixture.nodes[-1])
		fixture.edges[0].entry_enabled = false
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		_start_route(packet, fixture, kind, outcome, route)
		var snapshot: Dictionary = packet.get_transport_snapshot()
		_check(packet.edge == first and snapshot["reroute_count"] == 1
			and snapshot["route_revision"] == 2 and snapshot["final_target"] == fixture.nodes[-1],
			"Before-entry closure chooses a bypass " + String(kind))
		_check(fixture.traffic.get_edge_snapshot(fixture.edges[0])["queue"].is_empty()
			and fixture.traffic.get_edge_snapshot(fixture.edges[0])["leases"].is_empty(),
			"Closed obsolete edge holds no queued request or occupancy")
		_step(packet, 2.0)
		_outcome(outcome, 1, 0, "Bypass reaches original target " + String(kind))
		_position(outcome.position, fixture.nodes[-1].global_position, "Bypass is physical travel")
		_check(outcome.terminal["completed_segments"] == 2, "Bypass counts only actual completed hops")
		_empty_traffic(fixture, "Bypass finish")
		_destroy(fixture)


func _test_queued_request_replaced_and_cancelled() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]), 2)
		var blocker: Node = Node.new()
		fixture.host.add_child(blocker)
		var blocking: Dictionary = fixture.traffic.request_passage("blocker", blocker, "blocker",
			fixture.edges[0], fixture.nodes[0], fixture.nodes[1], &"remains")
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		_start(packet, fixture, kind, outcome)
		var old: Dictionary = packet.get_transport_snapshot()
		_check(old["state"] == &"waiting" and not String(old["request_id"]).is_empty(), "Capacity wait is admitted")
		var bypass: Node2D = _node(fixture, Vector2(50.0, 50.0))
		var first: HyphaEdge = _edge(fixture, fixture.nodes[0], bypass)
		_edge(fixture, bypass, fixture.nodes[-1])
		fixture.edges[0].entry_enabled = false
		_step(packet, 0.2)
		var rerouted: Dictionary = packet.get_transport_snapshot()
		_check(fixture.traffic.get_request(old["request_id"])["state"] == &"cancelled"
			and rerouted["request_id"] != old["request_id"] and packet.edge == first,
			"Reroute cancels obsolete FIFO identity and uses a new key")
		_check(fixture.traffic.get_request(rerouted["request_id"])["request_key"]
			!= fixture.traffic.get_request(old["request_id"])["request_key"], "Reroute key is monotonic")
		var position: Vector2 = packet.global_position
		packet.cancel_transport()
		packet.cancel_transport()
		fixture.edges[0].entry_enabled = true
		fixture.traffic.release(String(blocking["token"]))
		_step(packet, 100.0)
		_outcome(outcome, 0, 1, "Reroute then cancel is unique " + String(kind))
		_position(packet.global_position, position, "Cancellation preserves actual bypass position")
		_check(not fixture.traffic.release(String(rerouted["token"]))
			and not fixture.traffic.cancel_request(String(old["request_id"])), "Stale handles cannot resurrect a route")
		_empty_traffic(fixture, "Reroute cancellation")
		_destroy(fixture)


func _test_occupied_closure_and_geometry() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		_start(packet, fixture, kind, outcome)
		_step(packet, 0.25)
		var before: Dictionary = packet.get_transport_snapshot()
		var bypass: Node2D = _node(fixture, Vector2(50.0, 50.0))
		_edge(fixture, fixture.nodes[0], bypass)
		_edge(fixture, bypass, fixture.nodes[-1])
		fixture.edges[0].entry_enabled = false
		fixture.nodes[-1].global_position = Vector2(200.0, 0.0)
		fixture.edges[0].traffic_capacity = 0
		for attempt: int in range(4):
			_step(packet, 10.0)
			var frozen: Dictionary = packet.get_transport_snapshot()
			_check(frozen["state"] == &"blocked" and frozen["location_kind"] == &"edge"
				and frozen["token"] == before["token"] and frozen["request_id"] == before["request_id"]
				and is_equal_approx(frozen["progress"], before["progress"])
				and frozen["reroute_count"] == 0, "Occupied closure freezes the same lease and plan")
			_position(packet.global_position, before["position"], "Closed growing geometry never moves the packet")
			_check(packet.is_transport_valid(outcome.target, outcome.task_id), "Blocked transport is still valid")
		_check(fixture.traffic.get_snapshot()["occupied_units"] == (2 if kind == &"remains" else 1),
			"Shrinking capacity preserves the occupied cargo units")
		fixture.edges[0].entry_enabled = true
		_step(packet, 0.0)
		_position(packet.global_position, before["position"], "Reopening resumes from frozen world position")
		_step(packet, 0.1)
		_position(packet.global_position, Vector2(35.0, 0.0), "Only new frame distance follows reopening")
		_step(packet, 2.0)
		_outcome(outcome, 1, 0, "Occupied edge eventually reaches the moving target " + String(kind))
		_empty_traffic(fixture, "Blocked recovery")
		_destroy(fixture)


func _test_future_change_at_next_node() -> void:
	for kind: StringName in KINDS:
		for operation: StringName in [&"close", &"unregister", &"retarget"]:
			var fixture: Fixture = _fixture(PackedVector2Array([
				Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)]))
			var outcome: Outcome = Outcome.new()
			var packet: Variant = _packet(fixture, kind, outcome)
			_start(packet, fixture, kind, outcome)
			_step(packet, 0.25)
			var before: Dictionary = packet.get_transport_snapshot()
			var bypass: Node2D = _node(fixture, Vector2(150.0, 50.0))
			var next: HyphaEdge = _edge(fixture, fixture.nodes[1], bypass)
			_edge(fixture, bypass, fixture.nodes[-1])
			match operation:
				&"close": fixture.edges[1].entry_enabled = false
				&"unregister": fixture.network.unregister_edge(fixture.edges[1])
				&"retarget": fixture.edges[1].start_node = fixture.nodes[0]
			_step(packet, 0.25)
			_position(packet.global_position, Vector2(50.0, 0.0), "Future break does not stop the occupied edge")
			_check(packet.get_transport_snapshot()["token"] == before["token"]
				and packet.get_transport_snapshot()["reroute_count"] == 0, "Future break waits for an actual node")
			_step(packet, 0.6)
			var repaired: Dictionary = packet.get_transport_snapshot()
			_check(repaired["current_node"] == fixture.nodes[1] and packet.edge == next
				and repaired["reroute_count"] == 1 and repaired["completed_segments"] == 1,
				"Future change reroutes from the reached node " + String(operation))
			_position(packet.global_position, Vector2(100.0, 0.0).move_toward(bypass.global_position, 10.0),
				"Node reroute preserves only the current frame leftover distance")
			_step(packet, 2.0)
			_outcome(outcome, 1, 0, "Repaired future route arrives " + String(kind))
			_empty_traffic(fixture, "Future reroute")
			_destroy(fixture)


func _test_traversed_losses_are_ignored() -> void:
	for kind: StringName in KINDS:
		for operation: StringName in [&"close", &"unregister", &"free", &"retarget"]:
			var fixture: Fixture = _fixture(PackedVector2Array([
				Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)]))
			var outcome: Outcome = Outcome.new()
			var packet: Variant = _packet(fixture, kind, outcome)
			_start(packet, fixture, kind, outcome)
			_step(packet, 1.25)
			var before: Dictionary = packet.get_transport_snapshot()
			match operation:
				&"close": fixture.edges[0].entry_enabled = false
				&"unregister": fixture.network.unregister_edge(fixture.edges[0])
				&"free": fixture.edges[0].free()
				&"retarget": fixture.edges[0].end_node = fixture.nodes[-1]
			_check(packet.is_transport_valid(outcome.target, outcome.task_id), "Traversed loss keeps business identity")
			_step(packet, 0.75)
			_outcome(outcome, 1, 0, "Traversed " + String(operation) + " is ignored " + String(kind))
			_check(before["current_node"] == fixture.nodes[1] and outcome.terminal["reroute_count"] == 0,
				"Past route loss never replaces the current plan")
			_empty_traffic(fixture, "Traversed route loss")
			_destroy(fixture)


func _test_no_route_recovery_and_retry_fingerprint() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[-1])
		fixture.edges[0].entry_enabled = false
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		_start_route(packet, fixture, kind, outcome, route)
		var waiting: Dictionary = packet.get_transport_snapshot()
		_check(waiting["state"] == &"waiting" and waiting["wait_reason"] == &"no_route"
			and waiting["location_kind"] == &"node" and waiting["current_node"] == fixture.nodes[0]
			and waiting["request_id"] == "" and waiting["token"] == "", "No route waits at the actual node")
		var outsider: Node = Node.new()
		fixture.host.add_child(outsider)
		# 已关闭边可由外部调度器保留排队；占用变化不会成为重规划触发器。
		var queued: Dictionary = fixture.traffic.request_passage("unrelated", outsider, "unrelated",
			fixture.edges[0], fixture.nodes[0], fixture.nodes[1], &"supply")
		fixture.traffic.cancel_request(queued["request_id"])
		fixture.nodes[-1].global_position = Vector2(150.0, 0.0)
		for attempt: int in range(6):
			_step(packet, 10.0)
			_check(packet.get_transport_snapshot()["reroute_count"] == waiting["reroute_count"]
				and packet.get_transport_snapshot()["route_revision"] == waiting["route_revision"],
				"No-route wait ignores occupancy, geometry and unchanged frames")
			_position(packet.global_position, fixture.nodes[0].global_position, "No-route wait discards time")
		fixture.edges[0].entry_enabled = true
		_step(packet, 0.2)
		_position(packet.global_position, Vector2(20.0, 0.0), "Reopening replans and uses only new distance")
		_check(packet.get_transport_snapshot()["reroute_count"] == waiting["reroute_count"] + 1
			and packet.get_transport_snapshot()["final_target"] == fixture.nodes[-1], "No-route retry keeps original identity")
		_step(packet, 2.0)
		_outcome(outcome, 1, 0, "No-route recovery " + String(kind))
		_empty_traffic(fixture, "No-route recovery")
		_destroy(fixture)
	# 已抵达节点处移除下一条边也等待；登记替代边才重试。
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)]))
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		_start(packet, fixture, kind, outcome)
		fixture.network.unregister_edge(fixture.edges[1])
		_step(packet, 10.0)
		_check(packet.get_transport_snapshot()["state"] == &"waiting"
			and packet.get_transport_snapshot()["current_node"] == fixture.nodes[1], "Removed next edge waits at reached node")
		_position(packet.global_position, fixture.nodes[1].global_position, "No-route transition commits physical node")
		_edge(fixture, fixture.nodes[1], fixture.nodes[-1])
		_step(packet, 1.0)
		_outcome(outcome, 1, 0, "Replacement registered edge recovers no-route wait")
		_destroy(fixture)


func _test_capacity_wait_keeps_fifo_and_plan() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]), 2)
	var blocker: Node = Node.new()
	fixture.host.add_child(blocker)
	var blocking: Dictionary = fixture.traffic.request_passage("occupier", blocker, "occupier",
		fixture.edges[0], fixture.nodes[0], fixture.nodes[1], &"remains")
	var first_outcome: Outcome = Outcome.new()
	var first: Variant = _packet(fixture, &"remains", first_outcome, fixture.nodes[1].global_position)
	_start(first, fixture, &"remains", first_outcome, fixture.nodes[1], fixture.nodes[0])
	var late_outcome: Outcome = Outcome.new()
	var late: Variant = _packet(fixture, &"supply", late_outcome)
	_start(late, fixture, &"supply", late_outcome)
	var first_trace: Dictionary = first.get_transport_snapshot()
	var late_trace: Dictionary = late.get_transport_snapshot()
	var bypass: Node2D = _node(fixture, Vector2(50.0, 1.0))
	_edge(fixture, fixture.nodes[0], bypass)
	_edge(fixture, bypass, fixture.nodes[-1])
	fixture.edges[0].traffic_capacity = 1
	fixture.traffic.release(blocking["token"])
	fixture.nodes[-1].global_position = Vector2(100.0, 10.0)
	for attempt: int in range(5):
		_step(first, 100.0)
		_step(late, 100.0)
		_check(first.get_transport_snapshot()["request_id"] == first_trace["request_id"]
			and late.get_transport_snapshot()["request_id"] == late_trace["request_id"]
			and first.get_transport_snapshot()["reroute_count"] == 0
			and late.get_transport_snapshot()["reroute_count"] == 0, "Capacity and cost changes retain the chosen plan/FIFO")
	var queue: Array = fixture.traffic.get_edge_snapshot(fixture.edges[0])["queue"]
	_check(queue.size() == 2 and queue[0]["request_id"] == first_trace["request_id"]
		and queue[1]["request_id"] == late_trace["request_id"], "Small later cargo never overtakes admitted large cargo")
	fixture.edges[0].traffic_capacity = 2
	_step(first, 2.0)
	_outcome(first_outcome, 1, 0, "Reverse FIFO head recovers unchanged request")
	_step(late, 2.0)
	_outcome(late_outcome, 1, 0, "Later forward packet follows FIFO head")
	_empty_traffic(fixture, "Stable FIFO")
	_destroy(fixture)


## 缩容后的旧大包队首让成本估计为 INF，静态可用路仍应保留为 FIFO 等待。
func _test_infinite_wait_estimate_keeps_a_static_route() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
	var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[-1])
	var bypass: Node2D = _node(fixture, Vector2(50.0, 0.0))
	_edge(fixture, fixture.nodes[0], bypass, 1)
	var narrow: HyphaEdge = _edge(fixture, bypass, fixture.nodes[-1], 2)
	var occupier: Node = Node.new()
	var head: Node = Node.new()
	fixture.host.add_child(occupier)
	fixture.host.add_child(head)
	var occupied: Dictionary = fixture.traffic.request_passage("inf-occupied", occupier, "inf-occupied",
		narrow, bypass, fixture.nodes[-1], &"remains")
	var queued: Dictionary = fixture.traffic.request_passage("inf-head", head, "inf-head",
		narrow, bypass, fixture.nodes[-1], &"remains")
	narrow.traffic_capacity = 1
	fixture.traffic.release(occupied["token"])
	fixture.edges[0].entry_enabled = false
	_check(is_inf(fixture.traffic.estimate_wait_seconds(narrow, 1, 100.0)), "Oversize FIFO head gives infinite cost advice")
	var outcome: Outcome = Outcome.new()
	var packet: Variant = _packet(fixture, &"supply", outcome)
	_start_route(packet, fixture, &"supply", outcome, route)
	_step(packet, 10.0)
	var waiting: Dictionary = packet.get_transport_snapshot()
	_check(waiting["state"] == &"waiting" and waiting["wait_reason"] == &"capacity"
		and waiting["current_node"] == bypass and not String(waiting["request_id"]).is_empty()
		and waiting["reroute_count"] == 1, "Infinite wait estimate preserves a static route and real FIFO request")
	fixture.traffic.cancel_request(queued["request_id"])
	_step(packet, 0.5)
	_outcome(outcome, 1, 0, "Queue recovery needs no occupancy-driven replan")
	_check(outcome.terminal["reroute_count"] == 1, "FIFO recovery retains the selected fallback plan")
	_empty_traffic(fixture, "Infinite wait fallback")
	_destroy(fixture)


func _test_target_edge_and_endpoint_removal() -> void:
	for kind: StringName in KINDS:
		for phase: StringName in [&"node", &"edge", &"blocked"]:
			for operation: StringName in [&"target", &"current_node", &"current_edge", &"retarget", &"endpoint"]:
				if phase == &"node" and operation in [&"current_edge", &"retarget", &"endpoint"]:
					continue
				var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
				var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[-1])
				fixture.edges[0].entry_enabled = phase != &"node"
				var outcome: Outcome = Outcome.new()
				var packet: Variant = _packet(fixture, kind, outcome)
				_start_route(packet, fixture, kind, outcome, route)
				if phase != &"node":
					_step(packet, 0.3)
				if phase == &"blocked":
					fixture.edges[0].entry_enabled = false
					_step(packet, 1.0)
				var before: Vector2 = packet.global_position
				match operation:
					&"target": fixture.network.unregister_node(fixture.nodes[-1])
					&"current_node": fixture.nodes[0].free()
					&"current_edge": fixture.network.unregister_edge(fixture.edges[0])
					&"retarget": fixture.edges[0].start_node = _node(fixture, Vector2(-10.0, 0.0))
					&"endpoint": fixture.nodes[-1].queue_free()
				_check(not packet.is_transport_valid(outcome.target, outcome.task_id), "Permanent location/target loss invalidates pure contract")
				_step(packet, 100.0)
				packet.cancel_transport()
				_outcome(outcome, 0, 1, "Permanent " + String(operation) + " in " + String(phase) + " " + String(kind))
				_position(packet.global_position, before, "Permanent failure never moves or teleports the packet")
				_empty_traffic(fixture, "Permanent failure")
				_destroy(fixture)


func _test_scheduler_identity_cancellation() -> void:
	for kind: StringName in KINDS:
		for operation: StringName in [&"task", &"owner", &"reset", &"request", &"network", &"traffic"]:
			var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
			var outcome: Outcome = Outcome.new()
			var packet: Variant = _packet(fixture, kind, outcome)
			var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[-1])
			if operation != &"request":
				fixture.edges[0].entry_enabled = false
			_start_route(packet, fixture, kind, outcome, route)
			var before: Vector2 = packet.global_position
			match operation:
				&"task": fixture.traffic.cancel_task(outcome.task_id, fixture.traffic.get_generation())
				&"owner": fixture.traffic.cancel_owner(packet)
				&"reset": fixture.traffic.reset()
				&"request": fixture.traffic.cancel_request(packet.get_transport_snapshot()["request_id"])
				&"network": fixture.host.remove_child(fixture.network)
				&"traffic": fixture.host.remove_child(fixture.traffic)
			_check(not packet.is_transport_valid(outcome.target, outcome.task_id), "Scheduler/dependency cancellation is visible to pure contract")
			fixture.edges[0].entry_enabled = true
			_step(packet, 100.0)
			_outcome(outcome, 0, 1, "Identity is terminal after " + String(operation) + " " + String(kind))
			_position(packet.global_position, before, "Cancelled identity does not resurrect when the route reopens")
			if not fixture.network.is_inside_tree():
				fixture.network.free()
			if not fixture.traffic.is_inside_tree():
				fixture.traffic.free()
			_destroy(fixture)
	# 拾取尚未有申请时，任务取消同样终止原身份。
	var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
	var outcome: Outcome = Outcome.new()
	var packet: Variant = _packet(fixture, &"remains", outcome, Vector2(-50.0, 0.0))
	_start(packet, fixture, &"remains", outcome)
	_check(packet.get_transport_snapshot()["state"] == &"pickup", "Ground pickup has its own physical phase")
	fixture.traffic.cancel_task(outcome.task_id, fixture.traffic.get_generation())
	_step(packet, 10.0)
	_outcome(outcome, 0, 1, "Task retirement terminates pickup without a request")
	_position(packet.global_position, Vector2(-50.0, 0.0), "Cancelled pickup never starts moving")
	_destroy(fixture)


func _test_zero_length_plans_and_pickup() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]))
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, Vector2(-30.0, 0.0) if kind == &"remains" else Vector2.ZERO)
		_start(packet, fixture, kind, outcome)
		if kind == &"remains":
			_check(packet.get_transport_snapshot()["location_kind"] == &"ground"
				and packet.get_transport_snapshot()["current_node"] == null,
				"Pickup cannot claim an unreached node")
			_step(packet, 0.3)
		_outcome(outcome, 1, 0, "Loop-free zero-length chain terminates " + String(kind))
		_check(outcome.terminal["completed_segments"] == 2 and outcome.valid_arrival,
			"Each zero-length hop acquires/releases physical passage before arrival")
		var granted: int = 0
		for snapshot: Dictionary in outcome.statuses:
			if snapshot["location_kind"] == &"edge" and not String(snapshot["token"]).is_empty():
				granted += 1
		_check(granted == 2, "All zero-length hops had exactly one granted moving status")
		_empty_traffic(fixture, "Zero-length chain")
		_destroy(fixture)


func _test_growth_endpoint_handoff() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO]), 2, true)
		var growth: GrowthSystem = GrowthSystem.new()
		growth.network_system = fixture.network
		growth.traffic_system = fixture.traffic
		growth.node_container = fixture.host
		growth.edge_container = fixture.host
		growth.tip_container = fixture.host
		fixture.host.add_child(growth)
		growth.set_physics_process(false)
		var task_id: int = growth.create_target(fixture.nodes[0], Vector2(360.0, 0.0))
		_check(task_id > 0, "Real growth task created")
		var tip: Node2D = growth.get_delivery_target(task_id)
		_check(tip is GrowthTip, "Original target is a real live GrowthTip")
		_check(growth.receive_nutrition(task_id, 9101, growth.get_requested_nutrition(task_id)), "First growth extension paid")
		growth.advance(0.5)
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], tip)
		var original_edge: HyphaEdge = route.segments[0].edge
		original_edge.traffic_capacity = 2
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		packet.speed = 10.0
		_start_route(packet, fixture, kind, outcome, route)
		_step(packet, 0.5)
		var before: Dictionary = packet.get_transport_snapshot()
		original_edge.entry_enabled = false
		_step(packet, 1.0)
		growth.advance(100.0)
		_check(growth.receive_nutrition(task_id, 9102, growth.get_requested_nutrition(task_id)), "Paid real junction formation")
		growth.advance(0.01)
		_check(growth.has_active_task() and growth.get_delivery_target(task_id) == tip,
			"Intermediate junction preserves the same live target/task")
		var junction: Node2D = original_edge.end_node
		_check(junction is HyphaNode and junction != tip
			and fixture.network.get_growth_handoff(original_edge, tip.get_instance_id()) == junction,
			"Only explicit paid endpoint handoff is recognized")
		var lease: Dictionary = fixture.traffic.get_lease(before["token"])
		_check(not lease.is_empty() and lease["to_node"] == junction
			and lease["request_id"] == before["request_id"], "Physical handoff preserves request and occupancy")
		_check(growth.receive_nutrition(task_id, 9103, growth.get_requested_nutrition(task_id)), "Next real extension paid")
		growth.advance(0.5)
		var onward: NetworkRoute = fixture.network.find_route(junction, tip)
		onward.segments[0].edge.traffic_capacity = 2
		_step(packet, 10.0)
		var blocked: Dictionary = packet.get_transport_snapshot()
		_check(blocked["state"] == &"blocked" and blocked["token"] == before["token"]
			and is_equal_approx(blocked["progress"], before["progress"])
			and packet.is_transport_valid(tip, outcome.task_id), "Handoff during blockage preserves normalized trace and identity")
		_position(packet.global_position, before["position"], "Closed edge freezes even while real tip grows and hands off")
		original_edge.entry_enabled = true
		_step(packet, 0.0)
		_position(packet.global_position, before["position"], "Growth handoff reopening preserves world position")
		var distance_to_junction: float = packet.global_position.distance_to(junction.global_position)
		_step(packet, distance_to_junction / 10.0 + 0.2)
		var resumed: Dictionary = packet.get_transport_snapshot()
		_check(resumed["current_node"] == junction and resumed["final_target"] == tip
			and resumed["request_id"] != before["request_id"] and resumed["reroute_count"] == 1,
			"At the new real junction the packet replans onward to its original GrowthTip")
		_position(packet.global_position, junction.global_position.move_toward(tip.global_position, 2.0),
			"Growth handoff completes only physical distances on both edges")
		_step(packet, 10.0)
		_outcome(outcome, 1, 0, "Real growth handoff arrives " + String(kind))
		_check(outcome.valid_arrival, "Real tip receives only a committed arrival contract")
		_empty_traffic(fixture, "Real growth handoff")
		_destroy(fixture)


func _test_request_release_and_status_reentry() -> void:
	for kind: StringName in KINDS:
		for event: StringName in [&"grant", &"release", &"completed"]:
			for operation: StringName in [&"cancel", &"detach", &"reset", &"target"]:
				var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
				var outcome: Outcome = Outcome.new()
				var packet: Variant = _packet(fixture, kind, outcome)
				var trigger: Trigger = Trigger.new()
				var callback: Callable = func() -> void:
					if trigger.fired:
						return
					trigger.fired = true
					trigger.snapshot = packet.get_transport_snapshot()
					_step(packet, 100.0)
					match operation:
						&"cancel": packet.cancel_transport()
						&"detach": fixture.host.remove_child(packet)
						&"reset": fixture.traffic.reset()
						&"target": fixture.nodes[-1].queue_free()
				if event == &"completed":
					packet.status_changed.connect(func(snapshot: Dictionary) -> void:
						if snapshot["state"] == &"completed":
							callback.call()
					)
				else:
					fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
						var expected: StringName = &"granted" if event == &"grant" else &"released"
						if snapshot["owner_id"] == packet.get_instance_id() and snapshot["state"] == expected:
							callback.call()
					)
				_start(packet, fixture, kind, outcome)
				_step(packet, 1.0)
				_check(trigger.fired, "Reentry event fired " + String(event))
				_outcome(outcome, 0, 1, "Reentry " + String(event) + " " + String(operation) + " " + String(kind))
				if event == &"grant":
					_position(outcome.position, Vector2.ZERO, "Grant reentry gets no early distance")
				else:
					_position(outcome.position, Vector2(100.0, 0.0), "Terminal reentry preserves physical arrival")
				_check(not packet.has_arrived_at(outcome.target, outcome.task_id), "Vetoed reentry cannot authorize delivery")
				_empty_traffic(fixture, "Reentry cleanup")
				if operation == &"detach":
					_check(is_instance_valid(packet) and not packet.is_inside_tree(), "Callback removes before actual free")
					packet.free()
					_outcome(outcome, 0, 1, "Unlocked physical free never replays settlement")
				_destroy(fixture)
