extends SceneTree
## 独立运输测试：只加载稳定运输包、菌丝场景和网络，不加载关卡。

class Fixture:
	extends RefCounted

	var network: NetworkSystem = null
	var host: Node2D = null
	var nodes: Array[Node2D] = []
	var edges: Array[HyphaEdge] = []


class PacketOutcome:
	extends RefCounted

	var arrivals: int = 0
	var interruptions: int = 0
	var final_position: Vector2 = Vector2.ZERO


const NUTRIENT_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/remains_packet.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")

var failures: Array[String] = []
var checks: int = 0
var _objects: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_three_segments()
	_test_frame_overshoot()
	_test_pickup()
	_test_same_node_routes()
	_test_zero_length_edges()
	_test_route_snapshot()
	_test_invalid_routes()
	_test_route_invalidation()
	_test_local_validation()
	_test_repeated_calls()
	_test_signal_reentry()
	_test_network_signal_reentry()
	_test_legacy_and_transforms()
	await _test_direct_packet_removal()
	_free_objects()
	_check(root.get_child_count() == initial_children, "Cleanup left test fixtures in the tree")
	print("TRANSPORT_ROUTE_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _check_position(actual: Vector2, expected: Vector2, context: String) -> void:
	_check(actual.distance_to(expected) < 0.001,
		context + ": position %s, expected %s" % [actual, expected])


func _check_outcome(outcome: PacketOutcome, arrivals: int, interruptions: int,
		context: String) -> void:
	_check(outcome.arrivals == arrivals and outcome.interruptions == interruptions,
		context + ": arrived=%d interrupted=%d, expected %d/%d" %
		[outcome.arrivals, outcome.interruptions, arrivals, interruptions])


func _track(node: Node) -> void:
	_objects.append(weakref(node))


func _new_fixture(points: PackedVector2Array) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.network = NetworkSystem.new()
	_track(fixture.network)
	root.add_child(fixture.network)
	fixture.host = Node2D.new()
	_track(fixture.host)
	root.add_child(fixture.host)
	for point: Vector2 in points:
		var node: Node2D = Node2D.new()
		fixture.host.add_child(node)
		node.position = point
		fixture.nodes.append(node)
		_check(fixture.network.register_node(node, fixture.nodes.size() == 1),
			"Fixture node registration")
	for index: int in range(fixture.nodes.size() - 1):
		var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
		# 中间一段反向存储端点，确保路线不能假设边的原始方向。
		edge.start_node = fixture.nodes[index + 1] if index % 2 == 1 else fixture.nodes[index]
		edge.end_node = fixture.nodes[index] if index % 2 == 1 else fixture.nodes[index + 1]
		fixture.host.add_child(edge)
		edge.set_process(false)
		fixture.edges.append(edge)
		_check(fixture.network.register_edge(edge), "Fixture edge registration")
	return fixture


func _three_segment_fixture() -> Fixture:
	return _new_fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(100.0, 100.0), Vector2(200.0, 100.0)
	]))


func _new_packet(is_remains: bool, fixture: Fixture, outcome: PacketOutcome,
		at: Vector2) -> Node2D:
	var packet: Node2D = null
	if is_remains:
		var remains: RemainsPacket = REMAINS_SCENE.instantiate() as RemainsPacket
		remains.arrived.connect(_on_arrived.bind(outcome))
		remains.interrupted.connect(_on_interrupted.bind(outcome))
		remains.speed = 100.0
		packet = remains
	else:
		var nutrient: NutrientPacket = NUTRIENT_SCENE.instantiate() as NutrientPacket
		nutrient.arrived.connect(_on_arrived.bind(outcome))
		nutrient.interrupted.connect(_on_interrupted.bind(outcome))
		nutrient.speed = 100.0
		packet = nutrient
	_track(packet)
	fixture.host.add_child(packet)
	packet.global_position = at
	# 手动推进固定时间，避免帧率影响距离与终态断言。
	packet.set_physics_process(false)
	return packet


func _on_arrived(packet: Node2D, outcome: PacketOutcome) -> void:
	outcome.arrivals += 1
	outcome.final_position = packet.global_position


func _on_interrupted(packet: Node2D, outcome: PacketOutcome) -> void:
	outcome.interruptions += 1
	outcome.final_position = packet.global_position


func _start(packet: Node2D, route: NetworkRoute, network: NetworkSystem = null) -> void:
	if packet is NutrientPacket:
		(packet as NutrientPacket).start_route(route, network)
	else:
		(packet as RemainsPacket).start_route(route, network)


func _step(packet: Node2D, delta: float) -> void:
	if packet is NutrientPacket:
		(packet as NutrientPacket)._physics_process(delta)
	else:
		(packet as RemainsPacket)._physics_process(delta)


func _cancel(packet: Node2D) -> void:
	if packet is NutrientPacket:
		(packet as NutrientPacket).cancel_transport()
	else:
		(packet as RemainsPacket).cancel_transport()


func _progress(packet: Node2D) -> float:
	return float(packet.get("progress"))


func _segment_index(packet: Node2D) -> int:
	return int(packet.get("segment_index"))


func _edge(packet: Node2D) -> HyphaEdge:
	return packet.get("edge") as HyphaEdge


func _kind(is_remains: bool) -> String:
	return "Remains" if is_remains else "Nutrient"


func _test_three_segments() -> void:
	for is_remains: bool in [false, true]:
		for reverse: bool in [false, true]:
			var fixture: Fixture = _three_segment_fixture()
			var start_index: int = 3 if reverse else 0
			var end_index: int = 0 if reverse else 3
			var route: NetworkRoute = fixture.network.find_route(
				fixture.nodes[start_index], fixture.nodes[end_index])
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome,
				fixture.nodes[start_index].global_position)
			var context: String = _kind(is_remains) + (" reverse" if reverse else " forward")
			_start(packet, route, fixture.network)
			_check_position(packet.global_position, route.start_node.global_position, context + " start")
			_check(_edge(packet) == route.segments[0].edge and _segment_index(packet) == 0,
				context + ": first edge")
			_step(packet, 1.0)
			_check_position(packet.global_position, route.segments[0].end_node.global_position,
				context + " exact intermediate node")
			_check(_edge(packet) == route.segments[1].edge and _segment_index(packet) == 1
				and is_zero_approx(_progress(packet)), context + ": changed segment at node")
			_check_outcome(outcome, 0, 0, context + " intermediate node")
			_step(packet, 0.5)
			_check_position(packet.global_position, Vector2(100.0, 50.0), context + " mixed direction")
			_check(is_equal_approx(_progress(packet), 0.5), context + ": segment fraction")
			_step(packet, 1.5)
			_check_outcome(outcome, 1, 0, context + " terminal")
			_check_position(outcome.final_position, route.end_node.global_position, context + " endpoint")
			_check(_segment_index(packet) == 2 and is_equal_approx(_progress(packet), 1.0),
				context + ": final segment state")
			_cancel(packet)
			_step(packet, 5.0)
			_check_outcome(outcome, 1, 0, context + " terminal stays unique")


func _test_frame_overshoot() -> void:
	for is_remains: bool in [false, true]:
		var fixture: Fixture = _three_segment_fixture()
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
		var outcome: PacketOutcome = PacketOutcome.new()
		var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2.ZERO)
		_start(packet, route, fixture.network)
		_step(packet, 1.5)
		_check_position(packet.global_position, Vector2(100.0, 50.0),
			_kind(is_remains) + " leftover distance reaches second segment")
		_step(packet, 10.0)
		_check_outcome(outcome, 1, 0, _kind(is_remains) + " overshoot several segments")
		_check_position(outcome.final_position, Vector2(200.0, 100.0),
			_kind(is_remains) + " overshoot stops at destination")


func _test_pickup() -> void:
	var fixture: Fixture = _three_segment_fixture()
	var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
	var outcome: PacketOutcome = PacketOutcome.new()
	var packet: Node2D = _new_packet(true, fixture, outcome, Vector2(-50.0, 0.0))
	_start(packet, route, fixture.network)
	_check_position(packet.global_position, Vector2(-50.0, 0.0), "Pickup preserves ground position")
	_step(packet, 0.25)
	_check_position(packet.global_position, Vector2(-25.0, 0.0), "Pickup partial movement")
	_check(is_zero_approx(_progress(packet)), "Pickup did not advance edge fraction")
	_step(packet, 1.0)
	_check_position(packet.global_position, Vector2(75.0, 0.0), "Pickup leftover enters first edge")
	_step(packet, 2.25)
	_check_outcome(outcome, 1, 0, "Pickup and three segments finish once")

	var broken: Fixture = _three_segment_fixture()
	var broken_outcome: PacketOutcome = PacketOutcome.new()
	var broken_packet: Node2D = _new_packet(true, broken, broken_outcome, Vector2(-100.0, 0.0))
	_start(broken_packet, broken.network.find_route(broken.nodes[0], broken.nodes[3]), broken.network)
	broken.edges[2].queue_free()
	_step(broken_packet, 0.25)
	_check_outcome(broken_outcome, 0, 0, "Future edge loss preserves pickup cargo")
	_check_position(broken_packet.global_position, Vector2(-75.0, 0.0), "Pickup continues toward its valid collecting node")
	_step(broken_packet, 1.0)
	_check_position(broken_packet.global_position, Vector2.ZERO, "Missing future path waits at the actual collecting node")
	_check(broken_packet.get_transport_snapshot()["state"] == &"waiting", "No-route pickup does not become a failure")
	_cancel(broken_packet)
	_check_outcome(broken_outcome, 0, 1, "Explicit cancellation still uniquely terminates the held pickup")

	var moving: Fixture = _new_fixture(PackedVector2Array([Vector2.ZERO]))
	var moving_outcome: PacketOutcome = PacketOutcome.new()
	var moving_packet: Node2D = _new_packet(true, moving, moving_outcome, Vector2(-100.0, 0.0))
	_start(moving_packet, moving.network.find_route(moving.nodes[0], moving.nodes[0]), moving.network)
	_step(moving_packet, 0.25)
	moving.nodes[0].global_position = Vector2(0.0, 100.0)
	_step(moving_packet, 0.5)
	_check_position(moving_packet.global_position, Vector2(-45.0, 40.0), "Pickup follows moving start")
	_check_outcome(moving_outcome, 0, 0, "Moving pickup not finished early")
	_step(moving_packet, 0.75)
	_check_outcome(moving_outcome, 1, 0, "Moving pickup terminal")
	_check_position(moving_outcome.final_position, Vector2(0.0, 100.0), "Moving pickup endpoint")


func _test_same_node_routes() -> void:
	for is_remains: bool in [false, true]:
		var fixture: Fixture = _new_fixture(PackedVector2Array([Vector2.ZERO]))
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[0])
		var outcome: PacketOutcome = PacketOutcome.new()
		var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2(-50.0, 0.0))
		_start(packet, route, fixture.network)
		if is_remains:
			_check_outcome(outcome, 0, 0, "Zero-segment remains waits for pickup")
			_step(packet, 0.4)
			_check_position(packet.global_position, Vector2(-10.0, 0.0), "Zero-segment pickup movement")
			_check_outcome(outcome, 0, 0, "Zero-segment pickup not finished early")
			_step(packet, 0.2)
		_check_outcome(outcome, 1, 0, _kind(is_remains) + " zero-segment arrival")
		_check_position(outcome.final_position, Vector2.ZERO, _kind(is_remains) + " same-node position")
		_check(_edge(packet) == null, _kind(is_remains) + " zero-segment has no current edge")


func _test_zero_length_edges() -> void:
	for is_remains: bool in [false, true]:
		for all_zero: bool in [false, true]:
			var points: PackedVector2Array = PackedVector2Array([
				Vector2.ZERO, Vector2.ZERO,
				Vector2.ZERO if all_zero else Vector2(100.0, 0.0),
				Vector2.ZERO if all_zero else Vector2(100.0, 0.0)
			])
			var fixture: Fixture = _new_fixture(points)
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome,
				Vector2(-50.0, 0.0) if is_remains else Vector2.ZERO)
			_start(packet, fixture.network.find_route(fixture.nodes[0], fixture.nodes[3]), fixture.network)
			_step(packet, 2.0)
			var context: String = _kind(is_remains) + (" all zero edges" if all_zero else " zero edge chain")
			_check_outcome(outcome, 1, 0, context)
			_check_position(outcome.final_position, points[-1], context + " endpoint")
			_check(_segment_index(packet) == 2 and is_equal_approx(_progress(packet), 1.0),
				context + ": crossed trailing zero segment")


func _test_route_snapshot() -> void:
	for is_remains: bool in [false, true]:
		var fixture: Fixture = _three_segment_fixture()
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
		var original: NetworkRoute.Segment = route.segments[1]
		var outcome: PacketOutcome = PacketOutcome.new()
		var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2.ZERO)
		_start(packet, route, fixture.network)
		original.edge = fixture.edges[0]
		original.start_node = fixture.nodes[3]
		original.end_node = fixture.nodes[0]
		original.forward = not original.forward
		route.start_node = fixture.nodes[3]
		route.end_node = fixture.nodes[0]
		route.found = false
		route.segments.clear()
		_step(packet, 1.5)
		_check_position(packet.global_position, Vector2(100.0, 50.0),
			_kind(is_remains) + " copied segment and array")
		_step(packet, 1.5)
		_check_outcome(outcome, 1, 0, _kind(is_remains) + " caller mutation did not retarget")
		_check_position(outcome.final_position, Vector2(200.0, 100.0),
			_kind(is_remains) + " original destination")


func _test_invalid_routes() -> void:
	var cases: Array[String] = ["null", "not_found", "empty_different_nodes", "null_segment",
		"wrong_chain", "wrong_direction", "cycle", "queued_start", "freed_target"]
	for is_remains: bool in [false, true]:
		for case_name: String in cases:
			var fixture: Fixture = _three_segment_fixture()
			var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
			match case_name:
				"null":
					route = null
				"not_found":
					route.found = false
				"empty_different_nodes":
					route.segments.clear()
				"null_segment":
					route.segments[1] = null
				"wrong_chain":
					route.segments[1].start_node = fixture.nodes[0]
				"wrong_direction":
					route.segments[1].forward = not route.segments[1].forward
				"cycle":
					var back: NetworkRoute.Segment = NetworkRoute.Segment.new()
					back.edge = fixture.edges[0]
					back.start_node = fixture.nodes[1]
					back.end_node = fixture.nodes[0]
					back.forward = false
					route.segments.insert(1, back)
				"queued_start":
					fixture.nodes[0].queue_free()
				"freed_target":
					fixture.nodes[3].free()
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2(-10.0, 0.0))
			_start(packet, route, fixture.network)
			var context: String = _kind(is_remains) + " invalid " + case_name
			_check_outcome(outcome, 0, 1, context + " synchronously interrupted")
			_check_position(outcome.final_position, Vector2(-10.0, 0.0), context + " no movement")
			_cancel(packet)
			_step(packet, 100.0)
			_check_outcome(outcome, 0, 1, context + " terminal unique")


func _invalidate(fixture: Fixture, case_name: String) -> void:
	match case_name:
		"break_earlier":
			fixture.edges[0].end_node = null
		"retarget_earlier":
			fixture.edges[0].end_node = fixture.nodes[2]
		"swap_current":
			fixture.edges[1].start_node = fixture.nodes[1]
			fixture.edges[1].end_node = fixture.nodes[2]
		"unregister_earlier_edge":
			var alternate: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
			alternate.start_node = fixture.nodes[0]
			alternate.end_node = fixture.nodes[1]
			fixture.host.add_child(alternate)
			alternate.set_process(false)
			fixture.network.register_edge(alternate)
			fixture.network.unregister_edge(fixture.edges[0])
			_check(fixture.network.find_route(fixture.nodes[0], fixture.nodes[3]).found,
				"Alternative connectivity remains after removing an already-traversed edge")
		"unregister_earlier_node":
			fixture.network.unregister_node(fixture.nodes[0])
		"queued_target":
			fixture.nodes[3].queue_free()
		"freed_target":
			fixture.nodes[3].free()
		"freed_earlier_edge":
			fixture.edges[0].free()
		"queued_earlier_edge":
			fixture.edges[0].queue_free()
		"queued_network":
			fixture.network.queue_free()
		"freed_network":
			fixture.network.free()


func _test_route_invalidation() -> void:
	var cases: Array[String] = ["break_earlier", "retarget_earlier", "swap_current",
		"unregister_earlier_edge", "unregister_earlier_node", "queued_target", "freed_target",
		"freed_earlier_edge", "queued_earlier_edge", "queued_network", "freed_network"]
	for is_remains: bool in [false, true]:
		for case_name: String in cases:
			var fixture: Fixture = _three_segment_fixture()
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2.ZERO)
			_start(packet, fixture.network.find_route(fixture.nodes[0], fixture.nodes[3]), fixture.network)
			_step(packet, 1.5)
			var previous_position: Vector2 = packet.global_position
			_invalidate(fixture, case_name)
			_step(packet, 10.0)
			var context: String = _kind(is_remains) + " invalidated " + case_name
			var traversed_only: bool = case_name.contains("earlier")
			_check_outcome(outcome, 1 if traversed_only else 0, 0 if traversed_only else 1, context)
			var expected: Vector2 = fixture.nodes[3].global_position if traversed_only else previous_position
			_check_position(outcome.final_position, expected, context + " distinguishes traversed loss from occupied/target loss")
			_cancel(packet)
			_check_outcome(outcome, 1 if traversed_only else 0, 0 if traversed_only else 1, context + " repeated cancel")


func _test_local_validation() -> void:
	var cases: Array[String] = ["break_earlier", "retarget_earlier", "queued_target", "freed_target",
		"freed_earlier_edge", "queued_earlier_edge"]
	for is_remains: bool in [false, true]:
		for case_name: String in cases:
			var fixture: Fixture = _three_segment_fixture()
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2.ZERO)
			_start(packet, fixture.network.find_route(fixture.nodes[0], fixture.nodes[3]))
			_step(packet, 1.5)
			_check_position(packet.global_position, Vector2(100.0, 50.0),
				_kind(is_remains) + " local route without network")
			_invalidate(fixture, case_name)
			_step(packet, 10.0)
			var traversed_only: bool = case_name.contains("earlier")
			_check_outcome(outcome, 1 if traversed_only else 0, 0 if traversed_only else 1,
				_kind(is_remains) + " local validation " + case_name)


func _test_repeated_calls() -> void:
	for is_remains: bool in [false, true]:
		var fixture: Fixture = _three_segment_fixture()
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
		var outcome: PacketOutcome = PacketOutcome.new()
		var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2.ZERO)
		_start(packet, route, fixture.network)
		_step(packet, 0.5)
		_start(packet, null)
		_start(packet, fixture.network.find_route(fixture.nodes[3], fixture.nodes[0]), fixture.network)
		_check_position(packet.global_position, Vector2(50.0, 0.0), _kind(is_remains) + " repeated start")
		_step(packet, 2.5)
		_start(packet, route, fixture.network)
		_cancel(packet)
		_check_outcome(outcome, 1, 0, _kind(is_remains) + " repeated start keeps one result")

		var cancelled_outcome: PacketOutcome = PacketOutcome.new()
		var cancelled: Node2D = _new_packet(is_remains, fixture, cancelled_outcome, Vector2.ZERO)
		_cancel(cancelled)
		_cancel(cancelled)
		_start(cancelled, route, fixture.network)
		_step(cancelled, 10.0)
		_check_outcome(cancelled_outcome, 0, 1, _kind(is_remains) + " cancel before start")
		var active_outcome: PacketOutcome = PacketOutcome.new()
		var active: Node2D = _new_packet(is_remains, fixture, active_outcome, Vector2.ZERO)
		_start(active, route, fixture.network)
		_step(active, 0.25)
		_cancel(active)
		_cancel(active)
		_start(active, route, fixture.network)
		_step(active, 10.0)
		_check_outcome(active_outcome, 0, 1, _kind(is_remains) + " repeated active cancellation")


func _reenter_terminal(packet: Node2D, route: NetworkRoute, network: NetworkSystem) -> void:
	_cancel(packet)
	_start(packet, route, network)
	_step(packet, 10.0)
	_cancel(packet)


func _remove_during_terminal(packet: Node2D) -> void:
	if packet.get_parent() != null:
		packet.get_parent().remove_child(packet)


func _test_signal_reentry() -> void:
	for is_remains: bool in [false, true]:
		for delivered: bool in [false, true]:
			var fixture: Fixture = _three_segment_fixture()
			var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2.ZERO)
			packet.connect("arrived", _reenter_terminal.bind(route, fixture.network))
			packet.connect("interrupted", _reenter_terminal.bind(route, fixture.network))
			packet.connect("arrived", _remove_during_terminal)
			packet.connect("interrupted", _remove_during_terminal)
			_start(packet, route, fixture.network)
			if delivered:
				_step(packet, 3.0)
			else:
				_cancel(packet)
			var context: String = _kind(is_remains) + " signal reentry " + str(delivered)
			_check_outcome(outcome, 1 if delivered else 0, 0 if delivered else 1, context)
			_check(is_instance_valid(packet) and not packet.is_inside_tree(), context + ": exited tree")
			_check(not packet.is_queued_for_deletion(), context + ": exit did not queue deletion")
			fixture.host.add_child(packet)
			_start(packet, route, fixture.network)
			_cancel(packet)
			_check_outcome(outcome, 1 if delivered else 0, 0 if delivered else 1,
				context + " tree re-entry")


func _cancel_from_network(packet: Node2D) -> void:
	if is_instance_valid(packet):
		_cancel(packet)


func _test_network_signal_reentry() -> void:
	for is_remains: bool in [false, true]:
		for during_start: bool in [false, true]:
			var fixture: Fixture = _three_segment_fixture()
			var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
			var unrelated: Node2D = Node2D.new()
			fixture.host.add_child(unrelated)
			fixture.network.register_node(unrelated)
			var outcome: PacketOutcome = PacketOutcome.new()
			var packet: Node2D = _new_packet(is_remains, fixture, outcome, Vector2(-10.0, 0.0))
			if not during_start:
				_start(packet, route, fixture.network)
			fixture.network.network_changed.connect(_cancel_from_network.bind(packet))
			var trigger: Dictionary = {"fired": false, "position": packet.global_position}
			# 6.4 运输验证是纯查询；显式发出网络变化，不依赖查询顺手清理无关对象。
			packet.status_changed.connect(func(_snapshot: Dictionary) -> void:
				if not trigger["fired"]:
					trigger["fired"] = true
					trigger["position"] = packet.global_position
					fixture.network.unregister_node(unrelated))
			if during_start:
				_start(packet, route, fixture.network)
			else:
				_step(packet, 1.0)
			var context: String = _kind(is_remains) + " network signal reentry " + str(during_start)
			_check(trigger["fired"], context + " actual network callback fired")
			_check_outcome(outcome, 0, 1, context)
			_check_position(outcome.final_position, trigger["position"], context + " stops at the position of cancellation")


func _test_legacy_and_transforms() -> void:
	for is_remains: bool in [false, true]:
		var fixture: Fixture = _new_fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		fixture.host.position = Vector2(60.0, -30.0)
		fixture.host.rotation = 0.4
		fixture.host.scale = Vector2(1.5, 0.7)
		var edge: HyphaEdge = fixture.edges[0]
		edge.position = Vector2(-25.0, 5.0)
		edge.rotation = -0.8
		edge.scale = Vector2(0.5, 2.0)
		var source: Node2D = fixture.nodes[1] if is_remains else fixture.nodes[0]
		var destination: Node2D = fixture.nodes[0] if is_remains else fixture.nodes[1]
		var outcome: PacketOutcome = PacketOutcome.new()
		var packet: Node2D = _new_packet(is_remains, fixture, outcome, source.global_position)
		if is_remains:
			(packet as RemainsPacket).start_transport(edge, source, destination)
		else:
			(packet as NutrientPacket).start_transport(edge)
		_step(packet, edge.get_length() / 200.0)
		_check(is_equal_approx(_progress(packet), 0.5), _kind(is_remains) + " legacy half fraction")
		edge._process(0.0)
		var visual_fraction: float = 1.0 - _progress(packet) if is_remains else _progress(packet)
		var visual_position: Vector2 = edge.vein.to_global(
			edge.vein.points[0].lerp(edge.vein.points[1], visual_fraction))
		_check_position(packet.global_position, visual_position, _kind(is_remains) + " transformed visual edge")
		fixture.host.position += Vector2(15.0, 40.0)
		fixture.nodes[1].position += Vector2(30.0, 25.0)
		_step(packet, 0.0)
		edge._process(0.0)
		visual_position = edge.vein.to_global(
			edge.vein.points[0].lerp(edge.vein.points[1], visual_fraction))
		_check_position(packet.global_position, visual_position, _kind(is_remains) + " moving endpoints")
		_check_position(packet.global_position,
			source.global_position.lerp(destination.global_position, 0.5),
			_kind(is_remains) + " directed live positions")
		_step(packet, 10.0)
		_check_outcome(outcome, 1, 0, _kind(is_remains) + " legacy wrapper arrival")
		_check_position(outcome.final_position, destination.global_position,
			_kind(is_remains) + " legacy directed destination")

		var invalid_outcome: PacketOutcome = PacketOutcome.new()
		var invalid: Node2D = _new_packet(is_remains, fixture, invalid_outcome, Vector2.ZERO)
		if is_remains:
			(invalid as RemainsPacket).start_transport(edge, null, destination)
		else:
			(invalid as NutrientPacket).start_transport(null)
		_check_outcome(invalid_outcome, 0, 1, _kind(is_remains) + " invalid legacy wrapper")


func _test_direct_packet_removal() -> void:
	for is_remains: bool in [false, true]:
		var fixture: Fixture = _three_segment_fixture()
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], fixture.nodes[3])
		var detached_outcome: PacketOutcome = PacketOutcome.new()
		var detached: Node2D = _new_packet(is_remains, fixture, detached_outcome, Vector2.ZERO)
		_start(detached, route, fixture.network)
		_step(detached, 0.5)
		fixture.host.remove_child(detached)
		_check_outcome(detached_outcome, 0, 1, _kind(is_remains) + " direct tree exit")
		_check(not detached.is_queued_for_deletion(), _kind(is_remains) + " exit avoids queue_free")
		_cancel(detached)
		detached.free()
		_check_outcome(detached_outcome, 0, 1, _kind(is_remains) + " detached cleanup")

		var freed_outcome: PacketOutcome = PacketOutcome.new()
		var freed: Node2D = _new_packet(is_remains, fixture, freed_outcome, Vector2.ZERO)
		_start(freed, route, fixture.network)
		freed.free()
		_check_outcome(freed_outcome, 0, 1, _kind(is_remains) + " direct packet free")

		var queued_outcome: PacketOutcome = PacketOutcome.new()
		var queued: Node2D = _new_packet(is_remains, fixture, queued_outcome, Vector2.ZERO)
		_start(queued, route, fixture.network)
		queued.queue_free()
		_step(queued, 10.0)
		_check_outcome(queued_outcome, 0, 1, _kind(is_remains) + " queued packet interrupts before tick")
		await process_frame
		await process_frame
		_check(not is_instance_valid(queued), _kind(is_remains) + " queued packet freed")
		_check_outcome(queued_outcome, 0, 1, _kind(is_remains) + " queued packet result stays unique")

		var exit_outcome: PacketOutcome = PacketOutcome.new()
		var exit_packet: Node2D = _new_packet(is_remains, fixture, exit_outcome, Vector2.ZERO)
		_start(exit_packet, route, fixture.network)
		exit_packet.queue_free()
		await process_frame
		await process_frame
		_check_outcome(exit_outcome, 0, 1, _kind(is_remains) + " queued packet without next tick")


## 先释放网络，随后释放场景和已被移出的运输包。
func _free_objects() -> void:
	for reference: WeakRef in _objects:
		var node: Node = reference.get_ref() as Node
		if is_instance_valid(node):
			node.free()
	_objects.clear()
