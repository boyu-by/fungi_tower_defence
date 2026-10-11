extends SceneTree
## 营养包共享通行夹具：只手动推进真实包、网络、调度器与生长尖端。

const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")

class Fixture:
	extends RefCounted

	var scene: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var nodes: Array[Node2D] = []
	var edges: Array[HyphaEdge] = []

class Outcome:
	extends RefCounted

	var arrivals: int = 0
	var interruptions: int = 0
	var position: Vector2 = Vector2.ZERO
	var terminal: Dictionary = {}
	var traffic_at_terminal: Dictionary = {}
	var statuses: Array[Dictionary] = []

class Trigger:
	extends RefCounted

	var fired: bool = false
	var snapshot: Dictionary = {}
	var accepted: bool = false
	var calls: int = 0

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_wait_grant_and_snapshot()
	_test_continuous_hops()
	_test_intermediate_wait_discards_distance()
	_test_bidirectional_fifo()
	_test_cancel_waiting_and_moving()
	_test_nominal_capacity_and_entry_changes()
	_test_zero_segments_and_edges()
	_test_real_growing_tip()
	_test_strict_configuration_and_legacy()
	_test_reset_and_stale_handles()
	_test_dispatcher_and_network_loss()
	_test_original_route_invalidation()
	_test_request_notification_reentry()
	_test_hop_release_reentry()
	_test_status_and_terminal_reentry()
	_test_final_handoff_identity()
	_test_direct_removal()
	_check(root.get_child_count() == initial_children, "Nutrient traffic fixtures left root children")
	print("NUTRIENT_TRAFFIC_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _position(actual: Vector2, expected: Vector2, description: String) -> void:
	_check(actual.distance_to(expected) < 0.001,
		description + ": got %s, expected %s" % [actual, expected])


func _outcome(outcome: Outcome, arrivals: int, interruptions: int, description: String) -> void:
	_check(outcome.arrivals == arrivals and outcome.interruptions == interruptions,
		description + ": arrived=%d interrupted=%d" % [outcome.arrivals, outcome.interruptions])


func _new_fixture(points: PackedVector2Array, capacity: int = 1,
		growth_nodes: bool = false) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.scene = Node2D.new()
	root.add_child(fixture.scene)
	fixture.network = NetworkSystem.new()
	fixture.scene.add_child(fixture.network)
	for index: int in range(points.size()):
		var node: Node2D = null
		if growth_nodes:
			if index == 0:
				node = CORE_SCENE.instantiate() as MotherCore
			else:
				node = NODE_SCENE.instantiate() as HyphaNode
		else:
			node = Node2D.new()
		node.position = points[index]
		fixture.scene.add_child(node)
		fixture.nodes.append(node)
		_check(fixture.network.register_node(node, index == 0), "Fixture node registration")
	for index: int in range(points.size() - 1):
		# 第二段反向存储，运输必须使用路线方向而非边的存储方向。
		var first: Node2D = fixture.nodes[index + 1] if index % 2 == 1 else fixture.nodes[index]
		var second: Node2D = fixture.nodes[index] if index % 2 == 1 else fixture.nodes[index + 1]
		fixture.edges.append(_new_edge(fixture, first, second, capacity))
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.scene.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	return fixture


func _line_fixture() -> Fixture:
	return _new_fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))


func _new_edge(fixture: Fixture, first: Node2D, second: Node2D,
		capacity: int = 1) -> HyphaEdge:
	var connection: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	connection.start_node = first
	connection.end_node = second
	connection.traffic_capacity = capacity
	fixture.scene.add_child(connection)
	connection.set_process(false)
	_check(fixture.network.register_edge(connection), "Fixture edge registration")
	return connection


func _new_packet(fixture: Fixture, outcome: Outcome, required: bool = true) -> NutrientPacket:
	var packet: NutrientPacket = PACKET_SCENE.instantiate() as NutrientPacket
	packet.speed = 100.0
	packet.traffic_required = required
	packet.arrived.connect(_arrived.bind(outcome, fixture.traffic))
	packet.interrupted.connect(_interrupted.bind(outcome, fixture.traffic))
	packet.status_changed.connect(_status.bind(outcome))
	fixture.scene.add_child(packet)
	packet.set_physics_process(false)
	return packet


func _arrived(packet: NutrientPacket, outcome: Outcome, traffic: Variant) -> void:
	outcome.arrivals += 1
	_capture_terminal(packet, outcome, traffic)


func _interrupted(packet: NutrientPacket, outcome: Outcome, traffic: Variant) -> void:
	outcome.interruptions += 1
	_capture_terminal(packet, outcome, traffic)


func _capture_terminal(packet: NutrientPacket, outcome: Outcome, traffic: Variant) -> void:
	outcome.position = packet.global_position
	outcome.terminal = packet.get_transport_snapshot()
	if is_instance_valid(traffic):
		outcome.traffic_at_terminal = traffic.get_snapshot()


func _status(snapshot: Dictionary, outcome: Outcome) -> void:
	outcome.statuses.append(snapshot.duplicate())


func _count_network_change(trigger: Trigger) -> void:
	trigger.calls += 1


func _route(fixture: Fixture, first: int = 0, last: int = -1) -> NetworkRoute:
	return fixture.network.find_route(fixture.nodes[first], fixture.nodes[last])


func _start(packet: NutrientPacket, fixture: Fixture, first: int = 0, last: int = -1,
		kind: StringName = &"supply", task_id: String = "") -> void:
	packet.start_route(_route(fixture, first, last), fixture.network, fixture.traffic, task_id, kind)


func _empty_traffic(fixture: Fixture, description: String) -> void:
	var snapshot: Dictionary = fixture.traffic.get_snapshot()
	_check(int(snapshot["occupied_units"]) == 0 and int(snapshot["queued_count"]) == 0
		and int(snapshot["active_request_count"]) == 0, description)


func _destroy(fixture: Fixture) -> void:
	if is_instance_valid(fixture.traffic) and not fixture.traffic.is_inside_tree():
		fixture.traffic.free()
	if is_instance_valid(fixture.scene):
		fixture.scene.free()


## Godot 锁定正在执行方法/发出信号的包，回调内用离树触发真实退出。
func _detach_packet(packet: NutrientPacket) -> void:
	var parent: Node = packet.get_parent()
	if parent != null:
		parent.remove_child(packet)


## 由夹具在 start_route/_physics_process/cancel_transport 返回后释放，包已解锁。
func _free_after_detach(packet: NutrientPacket, fixture: Fixture,
		outcome: Outcome, description: String) -> void:
	_check(is_instance_valid(packet) and not packet.is_inside_tree(), description + ": exited synchronously")
	if is_instance_valid(packet):
		var snapshot: Dictionary = packet.get_transport_snapshot()
		_check(snapshot["state"] == &"interrupted" and String(snapshot["request_id"]).is_empty()
			and String(snapshot["token"]).is_empty(), description + ": exit already cleared terminal handles")
		packet.free()
	_check(not is_instance_valid(packet), description + ": freed after the active call returned")
	_outcome(outcome, 0, 1, description + ": free replayed no settlement")
	_empty_traffic(fixture, description + ": free retained no request or lease")


func _test_wait_grant_and_snapshot() -> void:
	var fixture: Fixture = _line_fixture()
	var leader_outcome: Outcome = Outcome.new()
	var waiting_outcome: Outcome = Outcome.new()
	var leader: NutrientPacket = _new_packet(fixture, leader_outcome)
	var waiting: NutrientPacket = _new_packet(fixture, waiting_outcome)
	var idle: Dictionary = waiting.get_transport_snapshot()
	_check(idle["state"] == &"idle" and bool(idle["traffic_required"])
		and waiting_outcome.statuses.is_empty(), "Idle snapshot changed packet state")
	_start(leader, fixture)
	_start(waiting, fixture, 0, -1, &"return")
	var snapshot: Dictionary = waiting.get_transport_snapshot()
	var request_id: String = snapshot["request_id"]
	var traffic_id: int = fixture.traffic.get_instance_id()
	_check(snapshot["state"] == &"waiting" and snapshot["wait_reason"] == &"capacity"
		and not request_id.is_empty() and String(snapshot["token"]).is_empty(), "Busy edge did not queue once")
	_check(snapshot["task_id"] != leader.get_transport_snapshot()["task_id"],
		"Default task identity was shared between packet instances")
	_check(snapshot["cargo_kind"] == &"return" and int(snapshot["units"]) == 1,
		"Return nutrient did not use exactly one traffic unit")
	var before: Dictionary = fixture.traffic.get_snapshot()
	var statuses: int = waiting_outcome.statuses.size()
	var unrelated: Node2D = Node2D.new()
	fixture.scene.add_child(unrelated)
	fixture.network.register_node(unrelated)
	var network_changes: Trigger = Trigger.new()
	fixture.network.network_changed.connect(_count_network_change.bind(network_changes))
	unrelated.queue_free()
	for attempt: int in range(5):
		var query: Dictionary = waiting.get_transport_snapshot()
		query["state"] = &"completed"
		query["request_id"] = "tampered"
	_check(fixture.traffic.get_snapshot() == before and waiting_outcome.statuses.size() == statuses
		and waiting.get_transport_snapshot()["state"] == &"waiting", "Snapshot query mutated traffic or packet")
	_check(network_changes.calls == 0, "Packet snapshot pruned queued topology registrations")
	waiting.start_route(null, null, null, "replacement", &"supply")
	for attempt: int in range(5):
		waiting._physics_process(100.0)
	_check(waiting.get_transport_snapshot()["request_id"] == request_id
		and int(fixture.traffic.get_snapshot()["queued_count"]) == 1, "Waiting tick re-enqueued or replaced the request")
	_position(waiting.global_position, Vector2.ZERO, "Capacity waiting stayed at its node")
	_outcome(waiting_outcome, 0, 0, "Waiting created no business settlement")
	leader._physics_process(1.0)
	_check(fixture.traffic.get_request(request_id)["state"] == &"granted"
		and waiting.get_transport_snapshot()["state"] == &"waiting",
		"Scheduler grant was adopted before the packet physics step")
	_outcome(waiting_outcome, 0, 0, "Grant alone did not deliver nutrition")
	waiting._physics_process(0.25)
	_position(waiting.global_position, Vector2(25.0, 0.0), "Grant used only the current frame distance")
	_check(is_equal_approx(waiting.progress, 0.25)
		and waiting.get_transport_snapshot()["current_node"] == fixture.nodes[0], "Moving snapshot lost its last reached node")
	waiting._physics_process(0.75)
	_outcome(waiting_outcome, 1, 0, "Granted waiter eventually delivered")
	_check(String(waiting_outcome.terminal["request_id"]).is_empty()
		and String(waiting_outcome.terminal["token"]).is_empty()
		and int(waiting_outcome.terminal["traffic_system_id"]) == traffic_id
		and waiting_outcome.terminal["task_id"] == snapshot["task_id"], "Terminal handles or trace identity were incorrect")
	_check(int(waiting_outcome.traffic_at_terminal["occupied_units"]) == 0,
		"Arrival business signal preceded lease release")
	_empty_traffic(fixture, "Completed packets retained traffic handles")
	_destroy(fixture)


func _test_continuous_hops() -> void:
	var fixture: Fixture = _new_fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(100.0, 100.0), Vector2(200.0, 100.0)
	]))
	var outcome: Outcome = Outcome.new()
	var packet: NutrientPacket = _new_packet(fixture, outcome)
	var route: NetworkRoute = _route(fixture)
	packet.start_route(route, fixture.network, fixture.traffic, "continuous")
	var first_id: String = packet.get_transport_snapshot()["request_id"]
	# 调用者可以修改原路线，包仍持有原来逐段对象的独立拷贝。
	route.segments[1].forward = not route.segments[1].forward
	route.segments.clear()
	packet._physics_process(1.5)
	_position(packet.global_position, Vector2(100.0, 50.0), "Unblocked hops preserved leftover distance")
	var snapshot: Dictionary = packet.get_transport_snapshot()
	_check(packet.segment_index == 1 and packet.edge == fixture.edges[1]
		and is_equal_approx(packet.progress, 0.5) and int(snapshot["completed_segments"]) == 1
		and snapshot["current_node"] == fixture.nodes[1], "Continuous hop snapshot was incorrect")
	_check(fixture.traffic.get_request(first_id)["state"] == &"released"
		and int(fixture.traffic.get_snapshot()["active_request_count"]) == 1
		and int(fixture.traffic.get_snapshot()["active_lease_count"]) == 1, "Packet held more than one edge across hops")
	packet._physics_process(1.5)
	_outcome(outcome, 1, 0, "Three live directional hops completed")
	_check(int(outcome.terminal["completed_segments"]) == 3 and packet.segment_index == 2
		and is_equal_approx(packet.progress, 1.0), "Terminal progress lost existing segment semantics")
	_position(outcome.position, Vector2(200.0, 100.0), "Continuous route terminal position")
	_empty_traffic(fixture, "Multi-hop arrival leaked a lease")
	_destroy(fixture)


func _test_intermediate_wait_discards_distance() -> void:
	var fixture: Fixture = _new_fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)
	]))
	var blocker_outcome: Outcome = Outcome.new()
	var blocker: NutrientPacket = _new_packet(fixture, blocker_outcome)
	_start(blocker, fixture, 2, 1, &"return")
	var outcome: Outcome = Outcome.new()
	var packet: NutrientPacket = _new_packet(fixture, outcome)
	_start(packet, fixture)
	packet._physics_process(10.0)
	var snapshot: Dictionary = packet.get_transport_snapshot()
	var request_id: String = snapshot["request_id"]
	_check(snapshot["state"] == &"waiting" and snapshot["current_node"] == fixture.nodes[1]
		and int(snapshot["completed_segments"]) == 1 and packet.segment_index == 1
		and is_zero_approx(packet.progress), "Intermediate waiting did not commit the actual node")
	_position(packet.global_position, fixture.nodes[1].global_position, "Intermediate queue did not jump or reset")
	packet._physics_process(100.0)
	_check(packet.get_transport_snapshot()["request_id"] == request_id, "Intermediate queue lost its FIFO position")
	blocker._physics_process(1.0)
	_outcome(outcome, 0, 0, "Intermediate scheduler grant did not deliver")
	packet._physics_process(0.25)
	_position(packet.global_position, Vector2(125.0, 0.0), "Queued hop discarded earlier overshoot and waiting time")
	packet._physics_process(0.75)
	_outcome(outcome, 1, 0, "Intermediate waiter resumed from the reached node")
	_empty_traffic(fixture, "Intermediate waiter leaked traffic")
	_destroy(fixture)


func _test_bidirectional_fifo() -> void:
	var fixture: Fixture = _line_fixture()
	var first_outcome: Outcome = Outcome.new()
	var reverse_outcome: Outcome = Outcome.new()
	var late_outcome: Outcome = Outcome.new()
	var first: NutrientPacket = _new_packet(fixture, first_outcome)
	var reverse: NutrientPacket = _new_packet(fixture, reverse_outcome)
	var late: NutrientPacket = _new_packet(fixture, late_outcome)
	_start(first, fixture)
	_start(reverse, fixture, 1, 0, &"return")
	_start(late, fixture)
	var reverse_id: String = reverse.get_transport_snapshot()["request_id"]
	var late_id: String = late.get_transport_snapshot()["request_id"]
	var snapshot: Dictionary = fixture.traffic.get_edge_snapshot(fixture.edges[0])
	_check(int(snapshot["occupied_units"]) == 1 and snapshot["queue"].size() == 2
		and snapshot["queue"][0]["request_id"] == reverse_id
		and snapshot["queue"][1]["request_id"] == late_id, "Directions did not share one FIFO and capacity")
	_position(reverse.global_position, Vector2(100.0, 0.0), "Reverse waiter stayed at its own origin")
	first._physics_process(1.0)
	_check(fixture.traffic.get_request(reverse_id)["state"] == &"granted"
		and fixture.traffic.get_request(late_id)["state"] == &"queued", "Later forward packet overtook reverse waiter")
	reverse._physics_process(0.25)
	_position(reverse.global_position, Vector2(75.0, 0.0), "Reverse movement respected route direction")
	reverse._physics_process(0.75)
	_outcome(reverse_outcome, 1, 0, "Reverse nutrient arrival")
	_check(fixture.traffic.get_request(late_id)["state"] == &"granted", "Reverse release did not admit next direction")
	late._physics_process(1.0)
	_outcome(late_outcome, 1, 0, "Later forward arrival")
	_empty_traffic(fixture, "Bidirectional competition leaked occupancy")
	_destroy(fixture)


func _test_cancel_waiting_and_moving() -> void:
	for waiting: bool in [true, false]:
		var fixture: Fixture = _line_fixture()
		fixture.edges[0].entry_enabled = not waiting
		var outcome: Outcome = Outcome.new()
		var packet: NutrientPacket = _new_packet(fixture, outcome)
		_start(packet, fixture)
		if not waiting:
			packet._physics_process(0.3)
		var position: Vector2 = packet.global_position
		packet.cancel_transport()
		packet.cancel_transport()
		packet.start_route(_route(fixture), fixture.network, fixture.traffic, "late")
		packet._physics_process(100.0)
		_outcome(outcome, 0, 1, "Repeated cancellation " + str(waiting))
		_position(outcome.position, position, "Cancellation did not move the packet")
		_check(outcome.terminal["state"] == &"interrupted"
			and String(outcome.terminal["request_id"]).is_empty()
			and String(outcome.terminal["token"]).is_empty(), "Cancellation retained active handles")
		_check(int(outcome.traffic_at_terminal["active_request_count"]) == 0,
			"Interruption business signal preceded traffic cleanup")
		_empty_traffic(fixture, "Cancelled packet retained queued request or moving lease")
		_destroy(fixture)


func _test_nominal_capacity_and_entry_changes() -> void:
	var fixture: Fixture = _line_fixture()
	fixture.edges[0].traffic_capacity = 0
	var outcome: Outcome = Outcome.new()
	var packet: NutrientPacket = _new_packet(fixture, outcome)
	_start(packet, fixture)
	packet._physics_process(100.0)
	_check(packet.get_transport_snapshot()["state"] == &"waiting"
		and packet.get_transport_snapshot()["wait_reason"] == &"capacity"
		and String(packet.get_transport_snapshot()["request_id"]).is_empty(), "Nominal zero capacity is a nonterminal pre-admission wait")
	_empty_traffic(fixture, "Zero nominal capacity creates no request")
	fixture.edges[0].entry_enabled = false
	fixture.edges[0].traffic_capacity = 1
	packet._physics_process(0.0)
	_check(String(packet.get_transport_snapshot()["request_id"]).is_empty()
		and packet.get_transport_snapshot()["wait_reason"] == &"no_route", "Closed only route waits at its node without an obsolete edge request")
	fixture.edges[0].traffic_capacity = 0
	packet._physics_process(100.0)
	fixture.edges[0].entry_enabled = true
	packet._physics_process(10.0)
	_check(packet.get_transport_snapshot()["state"] == &"waiting" and fixture.traffic.get_snapshot()["active_request_count"] == 0,
		"Still-insufficient nominal capacity cannot grant or repeatedly submit")
	_outcome(outcome, 0, 0, "Temporary settings produce no refund or arrival")
	fixture.edges[0].traffic_capacity = 1
	_position(packet.global_position, Vector2.ZERO, "Capacity restoration does not move without a tick")
	packet._physics_process(0.25)
	var stopped: Vector2 = packet.global_position
	var token: String = packet.get_transport_snapshot()["token"]
	fixture.edges[0].entry_enabled = false
	fixture.edges[0].traffic_capacity = 0
	packet._physics_process(0.75)
	_check(packet.get_transport_snapshot()["state"] == &"blocked" and packet.global_position == stopped
		and packet.get_transport_snapshot()["token"] == token, "Closure freezes the occupied edge even after shrink")
	_outcome(outcome, 0, 0, "Closed occupied segment cannot arrive")
	fixture.edges[0].entry_enabled = true
	packet._physics_process(0.75)
	_outcome(outcome, 1, 0, "Reopened existing occupancy may finish despite later capacity shrink")
	_empty_traffic(fixture, "Settings changes leaked traffic")
	_destroy(fixture)


func _test_zero_segments_and_edges() -> void:
	var same: Fixture = _new_fixture(PackedVector2Array([Vector2(20.0, 30.0)]))
	var same_outcome: Outcome = Outcome.new()
	var same_packet: NutrientPacket = _new_packet(same, same_outcome)
	_start(same_packet, same, 0, 0)
	_outcome(same_outcome, 1, 0, "Valid zero-segment traffic route completed synchronously")
	_position(same_outcome.position, same.nodes[0].global_position, "Zero-segment position")
	_check(int(same_outcome.terminal["completed_segments"]) == 0
		and int(same_outcome.terminal["segment_count"]) == 0 and same_packet.edge == null,
		"Zero-segment route invented an edge")
	_empty_traffic(same, "Zero-segment route reserved traffic")
	var missing_outcome: Outcome = Outcome.new()
	var missing: NutrientPacket = _new_packet(same, missing_outcome)
	missing.start_route(_route(same, 0, 0), same.network)
	_outcome(missing_outcome, 0, 1, "Zero-segment route bypassed required configuration")
	_destroy(same)
	var zero: Fixture = _new_fixture(PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]))
	zero.edges[1].entry_enabled = false
	var zero_outcome: Outcome = Outcome.new()
	var packet: NutrientPacket = _new_packet(zero, zero_outcome)
	_start(packet, zero)
	_check(packet.segment_index == 0 and int(packet.get_transport_snapshot()["completed_segments"]) == 0
		and packet.get_transport_snapshot()["state"] == &"waiting", "Closed remaining route waits before entering the zero-length chain")
	_outcome(zero_outcome, 0, 0, "Zero-length queue did not auto-arrive")
	_check(int(zero.traffic.get_snapshot()["occupied_units"]) == 0
		and int(zero.traffic.get_snapshot()["queued_count"]) == 0, "Zero-length hops held or queued multiple edges")
	zero.edges[1].entry_enabled = true
	_outcome(zero_outcome, 0, 0, "Zero-length grant did not auto-deliver")
	packet._physics_process(0.0)
	_outcome(zero_outcome, 1, 0, "Granted zero-length segment completed on a tick")
	_check(int(zero_outcome.terminal["completed_segments"]) == 2, "Zero-length chain lost completed hops")
	_empty_traffic(zero, "Zero-length chain leaked leases")
	_destroy(zero)
	var all_zero: Fixture = _new_fixture(PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]))
	var all_outcome: Outcome = Outcome.new()
	var all_packet: NutrientPacket = _new_packet(all_zero, all_outcome)
	_start(all_packet, all_zero)
	_outcome(all_outcome, 1, 0, "Unblocked all-zero edges completed after real grants")
	_empty_traffic(all_zero, "Synchronous all-zero arrival retained capacity")
	_destroy(all_zero)


func _deliver_growth(_packet: NutrientPacket, growth: GrowthSystem, task_id: int,
		trigger: Trigger) -> void:
	trigger.accepted = growth.receive_nutrition(task_id, 9002, 1)


func _test_real_growing_tip() -> void:
	var fixture: Fixture = _new_fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0)
	]), 1, true)
	var growth: GrowthSystem = GrowthSystem.new()
	growth.network_system = fixture.network
	growth.node_container = fixture.scene
	growth.edge_container = fixture.scene
	growth.tip_container = fixture.scene
	fixture.scene.add_child(growth)
	growth.set_physics_process(false)
	var task_id: int = growth.create_target(fixture.nodes[1], Vector2(280.0, 0.0))
	_check(task_id > 0, "Real growth target creation")
	var tip: Node2D = growth.get_delivery_target(task_id)
	_check(tip is GrowthTip, "Moving endpoint was not a real GrowthTip")
	var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], tip)
	var tip_edge: HyphaEdge = route.segments.back().edge
	var blocker: Node = Node.new()
	fixture.scene.add_child(blocker)
	var blocked_lease: Dictionary = fixture.traffic.request_passage("tip-blocker", blocker, "tip-blocker",
		tip_edge, route.segments.back().start_node, tip, &"remains")
	_check(blocked_lease["state"] == &"granted", "Real tip capacity blocker holds both units")
	var outcome: Outcome = Outcome.new()
	var packet: NutrientPacket = _new_packet(fixture, outcome)
	var delivered: Trigger = Trigger.new()
	packet.arrived.connect(_deliver_growth.bind(growth, task_id, delivered))
	packet.start_route(route, fixture.network, fixture.traffic, "real-growing-tip")
	packet._physics_process(5.0)
	_check(packet.get_transport_snapshot()["state"] == &"waiting" and packet.edge == tip_edge
		and is_zero_approx(packet.progress), "Initial zero-length tip edge still respects shared capacity")
	var investment: int = growth.get_requested_nutrition(task_id)
	_check(growth.receive_nutrition(task_id, 9001, investment), "Seed investment for real tip extension")
	growth.advance(1.0)
	packet._physics_process(100.0)
	_position(packet.global_position, fixture.nodes[1].global_position, "Waiting packet did not teleport with the growing tip")
	_check(tip.global_position.distance_to(fixture.nodes[1].global_position) > 0.0,
		"Real tip did not lengthen while the packet waited")
	_outcome(outcome, 0, 0, "Lengthened zero edge still waited for grant")
	fixture.traffic.release(String(blocked_lease["token"]))
	packet._physics_process(0.1)
	_position(packet.global_position, Vector2(110.0, 0.0), "Granted tip supply used live length")
	var fraction: float = packet.progress
	growth.advance(0.5)
	packet._physics_process(0.0)
	_check(is_equal_approx(packet.progress, fraction), "Growing tip changed normalized packet progress")
	_position(packet.global_position, fixture.nodes[1].global_position.lerp(tip.global_position, fraction),
		"Moving supply stayed on live growing geometry")
	packet._physics_process(0.1)
	growth.advance(0.25)
	var endpoint: Vector2 = tip.global_position
	packet._physics_process(1.0)
	_outcome(outcome, 1, 0, "Real growing-tip supply arrived physically")
	_position(outcome.position, endpoint, "Real tip arrival used current endpoint")
	_check(delivered.accepted and int(growth.get_task_snapshot()["buffered_nutrition"]) == 1,
		"Only actual tip arrival delivered the one-unit nutrition")
	_empty_traffic(fixture, "Real growing-tip arrival leaked a lease")
	_destroy(fixture)


func _test_strict_configuration_and_legacy() -> void:
	for case_name: String in ["required_missing", "explicit_no_network", "mismatch", "queued_traffic", "missing_dispatch_network", "wrong_cargo"]:
		var fixture: Fixture = _line_fixture()
		var outcome: Outcome = Outcome.new()
		var packet: NutrientPacket = _new_packet(fixture, outcome, case_name == "required_missing")
		packet.global_position = Vector2(-20.0, 5.0)
		var route: NetworkRoute = _route(fixture)
		match case_name:
			"required_missing":
				packet.start_route(route, fixture.network)
			"explicit_no_network":
				packet.start_route(route, null, fixture.traffic)
			"mismatch":
				var other: NetworkSystem = NetworkSystem.new()
				fixture.scene.add_child(other)
				packet.start_route(route, other, fixture.traffic)
			"queued_traffic":
				fixture.traffic.queue_free()
				_start(packet, fixture)
			"missing_dispatch_network":
				fixture.traffic.network_system = null
				_start(packet, fixture)
			"wrong_cargo":
				_start(packet, fixture, 0, -1, &"remains")
		_outcome(outcome, 0, 1, "Strict configuration " + case_name)
		_position(outcome.position, Vector2(-20.0, 5.0), "Invalid configuration had no movement " + case_name)
		_check(bool(outcome.terminal["traffic_enabled"]), "Explicit or required traffic silently fell back " + case_name)
		_destroy(fixture)
	var legacy: Fixture = _line_fixture()
	legacy.edges[0].traffic_capacity = 0
	legacy.edges[0].entry_enabled = false
	var legacy_outcome: Outcome = Outcome.new()
	var legacy_packet: NutrientPacket = _new_packet(legacy, legacy_outcome, false)
	legacy_packet.start_transport(legacy.edges[0])
	legacy_packet._physics_process(0.5)
	_check(legacy_packet.get_transport_snapshot()["state"] == &"waiting", "Legacy wrapper also waits for explicit temporary closure")
	legacy.edges[0].entry_enabled = true
	legacy_packet._physics_process(0.5)
	_position(legacy_packet.global_position, Vector2(50.0, 0.0), "Optional null dispatcher preserved legacy movement")
	legacy_packet._physics_process(0.5)
	_outcome(legacy_outcome, 1, 0, "Legacy entrypoint remained compatible")
	_check(not bool(legacy_outcome.terminal["traffic_enabled"]), "Legacy route created a traffic pool")
	_empty_traffic(legacy, "Legacy movement unexpectedly used dispatcher capacity")
	_destroy(legacy)
	var captured: Fixture = _line_fixture()
	captured.edges[0].entry_enabled = false
	var captured_outcome: Outcome = Outcome.new()
	var captured_packet: NutrientPacket = _new_packet(captured, captured_outcome)
	captured_packet.start_transport(captured.edges[0], captured.network, captured.traffic, "captured", &"return")
	captured_packet.traffic_required = false
	captured_packet._physics_process(100.0)
	_check(bool(captured_packet.get_transport_snapshot()["traffic_required"])
		and captured_packet.get_transport_snapshot()["state"] == &"waiting",
		"Changing exported required flag disabled captured traffic")
	captured_packet.cancel_transport()
	_destroy(captured)


func _test_reset_and_stale_handles() -> void:
	for waiting: bool in [true, false]:
		var fixture: Fixture = _line_fixture()
		fixture.edges[0].entry_enabled = not waiting
		var old_outcome: Outcome = Outcome.new()
		var old: NutrientPacket = _new_packet(fixture, old_outcome)
		_start(old, fixture)
		if not waiting:
			old._physics_process(0.25)
		var old_position: Vector2 = old.global_position
		var old_token: String = old.get_transport_snapshot()["token"]
		var old_request: String = old.get_transport_snapshot()["request_id"]
		fixture.traffic.reset()
		fixture.edges[0].entry_enabled = true
		var new_outcome: Outcome = Outcome.new()
		var fresh: NutrientPacket = _new_packet(fixture, new_outcome)
		_start(fresh, fixture)
		var new_request: String = fresh.get_transport_snapshot()["request_id"]
		old._physics_process(100.0)
		_outcome(old_outcome, 0, 1, "Reset interrupted stale packet " + str(waiting))
		_position(old_outcome.position, old_position, "Reset packet adopted no new-generation credit")
		_check(old_outcome.terminal["wait_reason"] == &"generation_changed"
			and fixture.traffic.get_request(old_request).is_empty(), "Reset did not invalidate old request identity")
		if not old_token.is_empty():
			_check(not fixture.traffic.release(old_token), "Stale token released a new-generation lease")
		old.cancel_transport()
		old._physics_process(100.0)
		_check(fixture.traffic.get_request(new_request)["state"] == &"granted"
			and int(fixture.traffic.get_snapshot()["occupied_units"]) == 1, "Old cleanup cancelled a new packet")
		fresh._physics_process(1.0)
		_outcome(new_outcome, 1, 0, "Fresh packet survived old reset callbacks")
		_empty_traffic(fixture, "Reset restart leaked traffic")
		_destroy(fixture)


func _test_dispatcher_and_network_loss() -> void:
	for waiting: bool in [true, false]:
		for case_name: String in ["free_traffic", "queue_traffic", "remove_traffic", "free_network", "queue_network", "replace_network", "cancel_request"]:
			var fixture: Fixture = _line_fixture()
			fixture.edges[0].entry_enabled = not waiting
			var blocker_token: String = ""
			if waiting and case_name == "cancel_request":
				fixture.edges[0].entry_enabled = true
				var blocker: Node = Node.new()
				fixture.scene.add_child(blocker)
				blocker_token = fixture.traffic.request_passage("blocker", blocker, "blocker", fixture.edges[0],
					fixture.nodes[0], fixture.nodes[1], &"supply")["token"]
			var outcome: Outcome = Outcome.new()
			var packet: NutrientPacket = _new_packet(fixture, outcome, false)
			_start(packet, fixture)
			if not waiting:
				packet._physics_process(0.2)
			var position: Vector2 = packet.global_position
			var traffic_id: int = fixture.traffic.get_instance_id()
			match case_name:
				"free_traffic":
					fixture.traffic.free()
				"queue_traffic":
					fixture.traffic.queue_free()
				"remove_traffic":
					fixture.scene.remove_child(fixture.traffic)
				"free_network":
					fixture.network.free()
				"queue_network":
					fixture.network.queue_free()
				"replace_network":
					var replacement: NetworkSystem = NetworkSystem.new()
					fixture.scene.add_child(replacement)
					fixture.traffic.network_system = replacement
				"cancel_request":
					fixture.traffic.cancel_request(packet.get_transport_snapshot()["request_id"])
					if not blocker_token.is_empty():
						fixture.traffic.release(blocker_token)
			packet._physics_process(100.0)
			_outcome(outcome, 0, 1, "Traffic loss " + case_name + " " + str(waiting))
			_position(outcome.position, position, "Traffic loss did not fall back to standalone movement")
			_check(bool(outcome.terminal["traffic_enabled"])
				and int(outcome.terminal["traffic_system_id"]) == traffic_id
				and String(outcome.terminal["token"]).is_empty()
				and String(outcome.terminal["request_id"]).is_empty(), "Lost traffic did not clear handles and preserve identity")
			if is_instance_valid(fixture.traffic):
				_empty_traffic(fixture, "Traffic loss cleanup retained an active request")
			_destroy(fixture)


func _test_original_route_invalidation() -> void:
	for waiting: bool in [true, false]:
		for case_name: String in ["unregister_earlier", "free_earlier", "retarget_earlier", "queue_target"]:
			var fixture: Fixture = _new_fixture(PackedVector2Array([
				Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)]))
			var blocker_token: String = ""
			if waiting:
				var blocker: Node = Node.new()
				fixture.scene.add_child(blocker)
				blocker_token = fixture.traffic.request_passage("blocker", blocker, "blocker", fixture.edges[1],
					fixture.nodes[1], fixture.nodes[2], &"supply")["token"]
			var outcome: Outcome = Outcome.new()
			var packet: NutrientPacket = _new_packet(fixture, outcome)
			_start(packet, fixture)
			packet._physics_process(1.25)
			var position: Vector2 = packet.global_position
			match case_name:
				"unregister_earlier": fixture.network.unregister_edge(fixture.edges[0])
				"free_earlier": fixture.edges[0].free()
				"retarget_earlier": fixture.edges[0].end_node = fixture.nodes[2]
				"queue_target": fixture.nodes[2].queue_free()
			packet._physics_process(100.0)
			if case_name == "queue_target":
				_outcome(outcome, 0, 1, "Original final target removal still terminates")
				_position(outcome.position, position, "Removed target receives no further movement")
			else:
				if waiting:
					_outcome(outcome, 0, 0, "Traversed edge removal keeps next-edge FIFO waiting")
					_position(packet.global_position, position, "Past-edge loss does not relocate the waiting node")
					fixture.traffic.release(blocker_token)
					packet._physics_process(1.0)
				_outcome(outcome, 1, 0, "Past-edge loss does not cancel remaining transport")
				_position(outcome.position, Vector2(200.0, 0.0), "Surviving path reaches original final target")
			if not blocker_token.is_empty():
				fixture.traffic.release(blocker_token)
			_empty_traffic(fixture, "Past-edge/target handling leaks no current traffic")
			_destroy(fixture)


func _request_reentry(snapshot: Dictionary, packet: NutrientPacket, fixture: Fixture,
		trigger: Trigger, action: StringName) -> void:
	if trigger.fired or snapshot["state"] != &"granted" or snapshot["owner_id"] != packet.get_instance_id():
		return
	trigger.fired = true
	packet._physics_process(100.0)
	match action:
		&"cancel":
			packet.cancel_transport()
		&"detach":
			_detach_packet(packet)
		&"reset":
			fixture.traffic.reset()
		&"queue_receiver":
			fixture.nodes[-1].queue_free()


func _test_request_notification_reentry() -> void:
	for action: StringName in [&"cancel", &"detach", &"reset", &"queue_receiver"]:
		var fixture: Fixture = _line_fixture()
		var outcome: Outcome = Outcome.new()
		var packet: NutrientPacket = _new_packet(fixture, outcome)
		var trigger: Trigger = Trigger.new()
		fixture.traffic.request_changed.connect(_request_reentry.bind(packet, fixture, trigger, action))
		_start(packet, fixture)
		_check(trigger.fired, "Request notification reentry did not fire " + String(action))
		_outcome(outcome, 0, 1, "Request notification stopped transport " + String(action))
		_position(outcome.position, Vector2.ZERO, "Request callback granted no early movement " + String(action))
		_empty_traffic(fixture, "Request callback leaked a lease before packet adopted its request id")
		if action == &"detach":
			_free_after_detach(packet, fixture, outcome, "Request callback removal")
		_destroy(fixture)


func _release_reentry(snapshot: Dictionary, packet: NutrientPacket, fixture: Fixture,
		trigger: Trigger, action: StringName) -> void:
	if trigger.fired or snapshot["state"] != &"released" or snapshot["owner_id"] != packet.get_instance_id():
		return
	trigger.fired = true
	trigger.snapshot = packet.get_transport_snapshot()
	match action:
		&"cancel":
			packet.cancel_transport()
		&"detach":
			_detach_packet(packet)
		&"reset":
			fixture.traffic.reset()
		&"invalidate":
			fixture.network.unregister_edge(fixture.edges[0])
		&"queue":
			packet.queue_free()
		&"free_target":
			fixture.nodes[-1].free()
		&"queue_target":
			fixture.nodes[-1].queue_free()


func _test_hop_release_reentry() -> void:
	for action: StringName in [&"cancel", &"detach", &"reset", &"invalidate", &"queue"]:
		var fixture: Fixture = _new_fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)
		]))
		var outcome: Outcome = Outcome.new()
		var packet: NutrientPacket = _new_packet(fixture, outcome)
		var trigger: Trigger = Trigger.new()
		_start(packet, fixture)
		fixture.traffic.request_changed.connect(_release_reentry.bind(packet, fixture, trigger, action))
		packet._physics_process(100.0)
		_check(trigger.fired and int(trigger.snapshot["completed_segments"]) == 1
			and trigger.snapshot["current_node"] == fixture.nodes[1]
			and String(trigger.snapshot["token"]).is_empty()
			and String(trigger.snapshot["request_id"]).is_empty(), "Hop release callback saw uncommitted arrival or live handles")
		if action == &"invalidate":
			_outcome(outcome, 1, 0, "Removal of just-traversed edge cannot veto onward movement")
			_position(outcome.position, Vector2(200.0, 0.0), "Release-time past-edge loss reaches original destination")
		else:
			_outcome(outcome, 0, 1, "Hop release reentry interrupted once " + String(action))
			_position(outcome.position, Vector2(100.0, 0.0), "Hop release reentry did not request or move on the next edge")
		_empty_traffic(fixture, "Hop release reentry leaked another edge")
		if action == &"detach":
			_free_after_detach(packet, fixture, outcome, "Hop release callback removal")
		_destroy(fixture)


func _status_reentry(snapshot: Dictionary, packet: NutrientPacket,
		fixture: Fixture, trigger: Trigger, action: StringName) -> void:
	if trigger.fired or (snapshot["state"] != &"moving" and snapshot["state"] != &"waiting"):
		return
	trigger.fired = true
	packet._physics_process(100.0)
	match action:
		&"cancel":
			packet.cancel_transport()
		&"reset":
			fixture.traffic.reset()
		&"free_traffic":
			fixture.traffic.free()


func _terminal_reentry(packet: NutrientPacket, fixture: Fixture) -> void:
	packet.cancel_transport()
	packet._physics_process(100.0)
	packet.start_route(_route(fixture), fixture.network, fixture.traffic, "terminal-reentry")
	packet.cancel_transport()


func _detach_on_terminal_status(snapshot: Dictionary, packet: NutrientPacket, trigger: Trigger) -> void:
	if not trigger.fired and (snapshot["state"] == &"completed" or snapshot["state"] == &"interrupted"):
		trigger.fired = true
		_detach_packet(packet)


func _test_status_and_terminal_reentry() -> void:
	for action: StringName in [&"cancel", &"reset", &"free_traffic"]:
		var fixture: Fixture = _line_fixture()
		var outcome: Outcome = Outcome.new()
		var packet: NutrientPacket = _new_packet(fixture, outcome)
		var trigger: Trigger = Trigger.new()
		packet.status_changed.connect(_status_reentry.bind(packet, fixture, trigger, action))
		_start(packet, fixture)
		_check(trigger.fired, "Status notification reentry did not fire")
		_outcome(outcome, 0, 1, "Status callback stopped further movement " + String(action))
		_position(outcome.position, Vector2.ZERO, "Status callback received no early distance credit")
		if is_instance_valid(fixture.traffic):
			_empty_traffic(fixture, "Status reentry leaked traffic")
		_destroy(fixture)
	var terminal: Fixture = _line_fixture()
	var terminal_outcome: Outcome = Outcome.new()
	var finished: NutrientPacket = _new_packet(terminal, terminal_outcome)
	var release_trigger: Trigger = Trigger.new()
	_start(finished, terminal)
	terminal.traffic.request_changed.connect(_release_reentry.bind(finished, terminal, release_trigger, &"cancel"))
	finished.arrived.connect(_terminal_reentry.bind(terminal))
	finished.interrupted.connect(_terminal_reentry.bind(terminal))
	finished._physics_process(1.0)
	_outcome(terminal_outcome, 0, 1, "Final release cancellation vetoed business arrival exactly once")
	_check(release_trigger.snapshot["state"] == &"completed"
		and String(release_trigger.snapshot["token"]).is_empty(), "Physical completion was not committed before release notification")
	_empty_traffic(terminal, "Terminal reentry leaked traffic")
	_destroy(terminal)
	for release_detach: bool in [true, false]:
		var fixture: Fixture = _line_fixture()
		var outcome: Outcome = Outcome.new()
		var packet: NutrientPacket = _new_packet(fixture, outcome)
		var trigger: Trigger = Trigger.new()
		_start(packet, fixture)
		if release_detach:
			fixture.traffic.request_changed.connect(_release_reentry.bind(packet, fixture, trigger, &"detach"))
		else:
			packet.status_changed.connect(_detach_on_terminal_status.bind(packet, trigger))
		packet._physics_process(1.0)
		_check(trigger.fired and is_instance_valid(packet) and not packet.is_inside_tree(),
			"Terminal notification did not synchronously detach the packet")
		_outcome(outcome, 0, 1, "Terminal removal vetoed business arrival exactly once " + str(release_detach))
		_position(outcome.position, Vector2(100.0, 0.0), "Terminal removal preserved the reached endpoint")
		_check(int(outcome.traffic_at_terminal["occupied_units"]) == 0,
			"Terminal removal emitted business settlement before capacity cleanup")
		_empty_traffic(fixture, "Terminal synchronous removal retained traffic")
		_free_after_detach(packet, fixture, outcome, "Terminal callback removal")
		_destroy(fixture)
	var cancellation: Fixture = _line_fixture()
	var cancellation_outcome: Outcome = Outcome.new()
	var cancelled: NutrientPacket = _new_packet(cancellation, cancellation_outcome)
	var cancellation_trigger: Trigger = Trigger.new()
	_start(cancelled, cancellation)
	cancelled.status_changed.connect(_detach_on_terminal_status.bind(cancelled, cancellation_trigger))
	cancelled.cancel_transport()
	_check(cancellation_trigger.fired, "Interruption status removal callback did not fire")
	_outcome(cancellation_outcome, 0, 1, "Terminal status removal preserved exactly one interruption")
	_position(cancellation_outcome.position, Vector2.ZERO, "Interruption status removal moved the packet")
	_empty_traffic(cancellation, "Interruption status removal retained traffic")
	_free_after_detach(cancelled, cancellation, cancellation_outcome, "Interruption status callback removal")
	_destroy(cancellation)


func _invalidate_on_final_status(snapshot: Dictionary, packet: NutrientPacket,
		fixture: Fixture, trigger: Trigger, action: StringName) -> void:
	if trigger.fired or snapshot["state"] != &"completed":
		return
	trigger.fired = true
	trigger.snapshot = packet.get_transport_snapshot()
	match action:
		&"reset":
			fixture.traffic.reset()
		&"free_target":
			fixture.nodes[-1].free()
		&"queue_target":
			fixture.nodes[-1].queue_free()
		&"cancel":
			packet.cancel_transport()


func _test_final_handoff_identity() -> void:
	for release_callback: bool in [true, false]:
		for action: StringName in [&"reset", &"free_target", &"queue_target", &"cancel"]:
			var fixture: Fixture = _line_fixture()
			var outcome: Outcome = Outcome.new()
			var packet: NutrientPacket = _new_packet(fixture, outcome)
			var trigger: Trigger = Trigger.new()
			_start(packet, fixture, 0, -1, &"supply", "final-handoff")
			if release_callback:
				fixture.traffic.request_changed.connect(_release_reentry.bind(packet, fixture, trigger, action))
			else:
				packet.status_changed.connect(_invalidate_on_final_status.bind(packet, fixture, trigger, action))
			packet._physics_process(1.0)
			var context: String = String(action) + " release=" + str(release_callback)
			_check(trigger.fired and trigger.snapshot["state"] == &"completed"
				and int(trigger.snapshot["completed_segments"]) == 1
				and String(trigger.snapshot["request_id"]).is_empty()
				and String(trigger.snapshot["token"]).is_empty(), "Final callback did not observe committed physical completion " + context)
			_outcome(outcome, 0, 1, "Invalid final handoff issued one interruption " + context)
			_position(outcome.position, Vector2(100.0, 0.0), "Final handoff veto preserved physical arrival position")
			_check(outcome.terminal["state"] == &"interrupted"
				and int(outcome.terminal["completed_segments"]) == 1
				and is_equal_approx(float(outcome.terminal["progress"]), 1.0)
				and outcome.terminal["task_id"] == "final-handoff", "Final handoff retained stale success or lost its physical trace " + context)
			_check(outcome.statuses.back()["state"] == &"interrupted", "Final status retained stale success " + context)
			if release_callback:
				var stale_success: bool = false
				for status: Dictionary in outcome.statuses:
					stale_success = stale_success or status["state"] == &"completed"
				_check(not stale_success, "Release-invalidated handoff published a stale completed status " + context)
			packet.cancel_transport()
			packet._physics_process(100.0)
			_outcome(outcome, 0, 1, "Late calls replayed no final handoff result " + context)
			_empty_traffic(fixture, "Invalid final handoff retained occupancy " + context)
			_destroy(fixture)


func _test_direct_removal() -> void:
	for waiting: bool in [true, false]:
		for action: StringName in [&"free", &"remove", &"queue"]:
			var fixture: Fixture = _line_fixture()
			fixture.edges[0].entry_enabled = not waiting
			var outcome: Outcome = Outcome.new()
			var packet: NutrientPacket = _new_packet(fixture, outcome)
			_start(packet, fixture)
			match action:
				&"free":
					packet.free()
				&"remove":
					fixture.scene.remove_child(packet)
					packet.cancel_transport()
					packet.free()
				&"queue":
					packet.queue_free()
					packet._physics_process(100.0)
			_outcome(outcome, 0, 1, "Direct removal settled once " + String(action) + " " + str(waiting))
			_empty_traffic(fixture, "Direct packet removal leaked waiting or moving handles")
			_destroy(fixture)
