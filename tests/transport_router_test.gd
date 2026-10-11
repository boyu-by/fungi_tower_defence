extends SceneTree
## 独立流量选路测试：不加载关卡、营养库存或真实运输包。

class Fixture:
	extends RefCounted

	var world: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var router: TransportRouter


class LengthEdge:
	extends HyphaEdge

	var test_length: float = 0.0

	func get_length() -> float:
		return test_length


var failures: Array[String] = []
var checks: int = 0
var _objects: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_edge_settings()
	_test_topology_snapshot()
	_test_uncongested_shortest_distance()
	_test_congestion_and_reopening()
	_test_stable_equal_cost_routes()
	_test_cycles_and_zero_lengths()
	_test_cargo_sizes_and_static_entry()
	_test_wait_formula_compatibility()
	_test_invalid_configuration_and_endpoints()
	_test_invalid_edge_costs()
	_test_pure_queries_with_pending_changes()
	_test_pure_queries_with_freed_objects()
	_test_legacy_corridor_identity()
	_free_objects()
	_check(root.get_child_count() == initial_children, "Router test cleanup left scene children")
	print("TRANSPORT_ROUTER_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(actual: float, expected: float, description: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) < 0.0001,
		description + ": actual=%s expected=%s" % [actual, expected])


func _track(node: Node) -> void:
	_objects.append(weakref(node))


func _new_fixture() -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	_track(fixture.world)
	root.add_child(fixture.world)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.traffic.set_physics_process(false)
	fixture.router = TransportRouter.new()
	fixture.router.network_system = fixture.network
	fixture.router.traffic_system = fixture.traffic
	fixture.world.add_child(fixture.router)
	return fixture


func _new_node(fixture: Fixture, point: Vector2) -> Node2D:
	var node: Node2D = Node2D.new()
	fixture.world.add_child(node)
	node.global_position = point
	_check(fixture.network.register_node(node), "Fixture node registration")
	return node


func _prepare_edge(edge: HyphaEdge, start: Node2D, end: Node2D) -> void:
	edge.start_node = start
	edge.end_node = end
	var vein: Line2D = Line2D.new()
	vein.name = "Vein"
	edge.add_child(vein)
	edge.set_process(false)


func _new_edge(
	fixture: Fixture, start: Node2D, end: Node2D, capacity: int = 2
) -> HyphaEdge:
	var edge: HyphaEdge = HyphaEdge.new()
	_prepare_edge(edge, start, end)
	edge.traffic_capacity = capacity
	fixture.world.add_child(edge)
	_check(fixture.network.register_edge(edge), "Fixture edge registration")
	return edge


func _new_owner(fixture: Fixture) -> Node:
	var owner: Node = Node.new()
	fixture.world.add_child(owner)
	return owner


func _request(
	fixture: Fixture, key: String, edge: HyphaEdge, from: Node2D, to: Node2D,
	kind: StringName = &"supply"
) -> Dictionary:
	return fixture.traffic.request_passage(
		key, _new_owner(fixture), "router-test", edge, from, to, kind
	)


## 同时检查边身份、路线连续性、正反方向和节点不重复。
func _check_route(
	result: Dictionary, expected_edges: Array[HyphaEdge], expected_nodes: Array[Node2D],
	context: String
) -> void:
	var route: NetworkRoute = result["route"]
	_check(bool(result["found"]) and route.found, context + ": route was not found")
	_check(route.start_node == expected_nodes[0] and route.end_node == expected_nodes[-1],
		context + ": route endpoints changed")
	_check(route.segments.size() == expected_edges.size(), context + ": segment count")
	var visited: Array[Node2D] = [expected_nodes[0]]
	for index: int in range(mini(route.segments.size(), expected_edges.size())):
		var segment: NetworkRoute.Segment = route.segments[index]
		_check(segment.edge == expected_edges[index], context + ": edge order %d" % index)
		_check(segment.start_node == expected_nodes[index]
			and segment.end_node == expected_nodes[index + 1], context + ": continuity %d" % index)
		_check(segment.forward == (segment.edge.start_node == segment.start_node),
			context + ": direction %d" % index)
		_check(not visited.has(segment.end_node), context + ": repeated node")
		visited.append(segment.end_node)
	_near(float(result["total_cost_seconds"]),
		float(result["travel_seconds"]) + float(result["estimated_wait_seconds"]),
		context + ": cost accounting")


func _check_no_route(result: Dictionary, context: String) -> void:
	var route: NetworkRoute = result["route"]
	_check(not bool(result["found"]) and not route.found, context + ": unexpected route")
	_check(route.segments.is_empty(), context + ": failed route retained segments")
	_check(result["reason"] is StringName and not String(result["reason"]).is_empty(),
		context + ": missing failure reason")


func _test_edge_settings() -> void:
	var edge: HyphaEdge = HyphaEdge.new()
	_track(edge)
	var start: Node2D = Node2D.new()
	var end: Node2D = Node2D.new()
	_track(start)
	_track(end)
	edge.start_node = start
	edge.end_node = end
	var seen: Array[Dictionary] = []
	edge.traffic_settings_changed.connect(func() -> void:
		seen.append({"capacity": edge.traffic_capacity, "enabled": edge.entry_enabled})
	)
	_check(edge.traffic_capacity == 2 and edge.entry_enabled, "Default edge traffic settings")
	edge.traffic_capacity = 2
	edge.entry_enabled = true
	_check(seen.is_empty(), "Unchanged traffic settings emitted notifications")
	edge.traffic_capacity = -4
	_check(edge.traffic_capacity == 0 and seen.size() == 1
		and seen[0]["capacity"] == 0, "Capacity was not normalized before notification")
	edge.traffic_capacity = -1
	_check(seen.size() == 1, "Repeated normalized capacity emitted a notification")
	edge.entry_enabled = false
	_check(seen.size() == 2 and not bool(seen[1]["enabled"]), "Closure notification preceded commit")
	edge.traffic_capacity = 3
	edge.entry_enabled = true
	_check(seen.size() == 4 and edge.traffic_capacity == 3 and edge.entry_enabled,
		"Traffic settings could not be restored")
	_check(edge.start_node == start and edge.end_node == end, "Traffic settings rewired endpoints")
	_check(edge.has_endpoints() and edge.connects(end, start), "Legacy edge methods changed")


func _test_topology_snapshot() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var other: Node2D = _new_node(fixture, Vector2(200.0, 0.0))
	var first: HyphaEdge = _new_edge(fixture, start, end)
	var second: HyphaEdge = _new_edge(fixture, other, end, 0)
	second.entry_enabled = false
	var changes: Array[int] = [0]
	fixture.network.network_changed.connect(func() -> void: changes[0] += 1)
	var snapshot: Dictionary = fixture.network.get_topology_snapshot()
	_check(snapshot["nodes"] == [start, end, other], "Topology node registration order changed")
	_check(snapshot["edges"].size() == 2
		and snapshot["edges"][0]["edge"] == first and snapshot["edges"][1]["edge"] == second,
		"Topology omitted a closed edge or changed registration order")
	var row: Dictionary = snapshot["edges"][1]
	_check(row.keys().size() == 9 and row["edge_id"] == second.get_instance_id()
		and row["start_node"] == other and row["end_node"] == end
		and row["start_id"] == other.get_instance_id() and row["end_id"] == end.get_instance_id()
		and row["capacity"] == 0 and not bool(row["entry_enabled"]), "Topology row contract")
	_near(float(row["length"]), 100.0, "Topology live length")
	_check(fixture.network.is_edge_valid(second) and not fixture.network.can_enter_edge(second),
		"Physical validity depended on static traffic settings")
	_check(fixture.network.is_node_registered(start)
		and not fixture.network.is_node_registered(null), "Pure node registration check")
	var edge_copy: Array[HyphaEdge] = fixture.network.get_registered_edges()
	edge_copy.clear()
	snapshot["nodes"].clear()
	row["capacity"] = 999
	snapshot["edges"].reverse()
	var fresh: Dictionary = fixture.network.get_topology_snapshot()
	_check(fixture.network.get_registered_edges() == [first, second]
		and fresh["nodes"] == [start, end, other]
		and fresh["edges"][0]["edge"] == first and fresh["edges"][1]["capacity"] == 0,
		"Topology or edge query exposed mutable registry containers")
	other.position.x += 20.0
	_near(float(fixture.network.get_topology_snapshot()["edges"][1]["length"]), 120.0,
		"Topology cached endpoint positions")
	var absent: Node2D = Node2D.new()
	_track(absent)
	second.start_node = absent
	_check(fixture.network.get_registered_edges() == [first, second]
		and not fixture.network.is_edge_valid(second)
		and fixture.network.get_topology_snapshot()["edges"].size() == 1,
		"Invalid endpoint removed edge identity or remained in physical topology")
	second.start_node = other
	_check(fixture.network.is_edge_valid(second)
		and fixture.network.get_registered_edges() == [first, second], "Endpoint restoration lost registration")
	_check(changes[0] == 0, "Pure topology queries emitted network_changed")


func _test_uncongested_shortest_distance() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var detour: Node2D = _new_node(fixture, Vector2(0.0, 200.0))
	var first: Node2D = _new_node(fixture, Vector2(30.0, 0.0))
	var second: Node2D = _new_node(fixture, Vector2(60.0, 0.0))
	var long_first: HyphaEdge = _new_edge(fixture, start, detour)
	var long_last: HyphaEdge = _new_edge(fixture, detour, end)
	var short_first: HyphaEdge = _new_edge(fixture, first, start)
	var short_middle: HyphaEdge = _new_edge(fixture, first, second)
	var short_last: HyphaEdge = _new_edge(fixture, end, second)
	var before: Dictionary = fixture.traffic.get_snapshot()
	var result: Dictionary = fixture.router.find_route(start, end, &"supply", 100.0)
	_check_route(result, [short_first, short_middle, short_last], [start, first, second, end],
		"Uncongested minimum distance")
	_near(float(result["total_distance"]), 100.0, "Uncongested distance")
	_near(float(result["travel_seconds"]), 1.0, "Uncongested travel time")
	_near(float(result["estimated_wait_seconds"]), 0.0, "Uncongested wait")
	_check(result["units"] == 1 and fixture.traffic.get_snapshot() == before,
		"Route query reserved capacity or changed scheduler state")
	var legacy: NetworkRoute = fixture.network.find_route(start, end)
	_check(legacy.found and legacy.segments.size() == 2
		and legacy.segments[0].edge == long_first and legacy.segments[1].edge == long_last,
		"Legacy BFS no longer chose minimum edge count")


func _test_congestion_and_reopening() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var bypass: Node2D = _new_node(fixture, Vector2(50.0, 40.0))
	var short: HyphaEdge = _new_edge(fixture, start, end)
	var first: HyphaEdge = _new_edge(fixture, start, bypass)
	var last: HyphaEdge = _new_edge(fixture, bypass, end)
	var held: Dictionary = _request(fixture, "held", short, end, start, &"remains")
	_check(held["accepted"] and held["state"] == &"granted", "Congestion lease fixture")
	var traffic_before: Dictionary = fixture.traffic.get_snapshot()
	var result: Dictionary = fixture.router.find_route(start, end, &"supply", 100.0)
	_check_route(result, [first, last], [start, bypass, end], "Congested short path bypass")
	_near(float(result["total_distance"]), 2.0 * sqrt(4100.0), "Bypass distance")
	_check(fixture.traffic.get_snapshot() == traffic_before, "Congested query changed leases")
	short.entry_enabled = false
	var closed: Dictionary = fixture.traffic.get_edge_snapshot(short)
	_check(closed["occupied_units"] == 2 and closed["leases"].size() == 1,
		"Closure revoked an existing hold")
	_check_route(fixture.router.find_route(start, end, &"supply", 100.0),
		[first, last], [start, bypass, end], "Closed edge bypass")
	_check(fixture.network.is_edge_valid(short) and fixture.network.has_direct_connection(start, end),
		"Closure removed physical connectivity")
	short.entry_enabled = true
	_check(fixture.traffic.get_edge_snapshot(short)["occupied_units"] == 2,
		"Reopening lost the held lease")
	_check(fixture.traffic.release(String(held["token"])), "Held lease did not release")
	_check_route(fixture.router.find_route(start, end, &"supply", 100.0),
		[short], [start, end], "Reopened unloaded short edge")
	_check(short.start_node == start and short.end_node == end
		and fixture.network.get_registered_edges() == [short, first, last],
		"Close/open changed endpoint or registration identity")
	first.entry_enabled = false
	short.entry_enabled = false
	_check_no_route(fixture.router.find_route(start, end), "All exits closed")
	_check(fixture.network.is_route_valid(fixture.network.find_route(start, end)),
		"Legacy route validation started using traffic flags")


func _test_stable_equal_cost_routes() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var first: Node2D = _new_node(fixture, Vector2(50.0, 0.0))
	var second: Node2D = _new_node(fixture, Vector2(50.0, 0.0))
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var first_entry: HyphaEdge = _new_edge(fixture, start, first)
	var second_entry: HyphaEdge = _new_edge(fixture, start, second)
	var second_exit: HyphaEdge = _new_edge(fixture, second, end)
	var first_exit: HyphaEdge = _new_edge(fixture, first, end)
	for iteration: int in range(4):
		_check_route(fixture.router.find_route(start, end), [first_entry, first_exit],
			[start, first, end], "Forward equal-cost tie %d" % iteration)
	_check_route(fixture.router.find_route(end, start), [second_exit, second_entry],
		[end, second, start], "Reverse equal-cost tie")
	fixture.network.unregister_edge(first_entry)
	fixture.network.register_edge(first_entry)
	_check_route(fixture.router.find_route(start, end), [second_entry, second_exit],
		[start, second, end], "Re-registration tie order")


func _test_cycles_and_zero_lengths() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var first: Node2D = _new_node(fixture, Vector2.ZERO)
	var second: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	_new_edge(fixture, start, start)
	var first_edge: HyphaEdge = _new_edge(fixture, start, first)
	_new_edge(fixture, first, second)
	_new_edge(fixture, second, start)
	var last_edge: HyphaEdge = _new_edge(fixture, first, end)
	_new_edge(fixture, second, end)
	var result: Dictionary = fixture.router.find_route(start, end, &"return", 100.0)
	_check_route(result, [first_edge, last_edge], [start, first, end], "Zero-length cycle")
	_near(float(result["travel_seconds"]), 1.0, "Zero edge travel accounting")
	_check(fixture.network.is_route_valid(result["route"]), "Zero cycle produced an invalid NetworkRoute")
	var same: Dictionary = fixture.router.find_route(second, second, &"remains", 100.0)
	_check_route(same, [], [second], "Registered same-node route")
	_check(same["units"] == 2, "Same-node route lost cargo size")
	_near(float(same["total_distance"]), 0.0, "Same-node distance")
	_near(float(same["total_cost_seconds"]), 0.0, "Same-node cost")
	var zero_result: Dictionary = fixture.router.find_route(start, first, &"supply", 100.0)
	_check_route(zero_result, [first_edge], [start, first], "Zero-length direct edge")
	_near(float(zero_result["total_cost_seconds"]), 0.0, "Zero-length edge cost")


func _test_cargo_sizes_and_static_entry() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var middle: Node2D = _new_node(fixture, Vector2(50.0, 40.0))
	var narrow: HyphaEdge = _new_edge(fixture, start, end, 1)
	var wide_first: HyphaEdge = _new_edge(fixture, start, middle)
	var wide_last: HyphaEdge = _new_edge(fixture, middle, end)
	for kind: StringName in [&"supply", &"return"]:
		var result: Dictionary = fixture.router.find_route(start, end, kind)
		_check_route(result, [narrow], [start, end], "One-unit cargo %s" % kind)
		_check(result["units"] == 1, "One-unit cargo mapping")
	var remains: Dictionary = fixture.router.find_route(start, end, &"remains")
	_check_route(remains, [wide_first, wide_last], [start, middle, end], "Two-unit cargo bypass")
	_check(remains["units"] == 2, "Remains cargo mapping")
	var hold: Dictionary = _request(fixture, "full-narrow", narrow, start, end)
	_check(hold["state"] == &"granted" and fixture.network.can_enter_edge(narrow, 1)
		and not fixture.network.can_enter_edge(narrow, 2), "Static entry query promised free capacity")
	_check(not fixture.network.can_enter_edge(narrow, 0)
		and not fixture.network.can_enter_edge(narrow, -1), "Nonpositive entry size was accepted")
	narrow.traffic_capacity = 0
	_check(fixture.network.is_edge_valid(narrow) and not fixture.network.can_enter_edge(narrow),
		"Zero capacity affected physical validity")
	wide_first.traffic_capacity = 1
	_check_no_route(fixture.router.find_route(start, end, &"remains"), "Undersized exits for remains")
	for kind: StringName in [&"", &"nutrition", &"unknown"]:
		var invalid: Dictionary = fixture.router.find_route(start, end, kind)
		_check_no_route(invalid, "Unknown cargo %s" % kind)
		_check(invalid["units"] == 0, "Unknown cargo acquired transport units")


func _test_wait_formula_compatibility() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var edge: HyphaEdge = _new_edge(fixture, start, end)
	_near(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0), 0.0, "Empty edge wait")
	var hold: Dictionary = _request(fixture, "one-hold", edge, start, end)
	_check(hold["state"] == &"granted", "Wait fixture initial hold")
	_near(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0), 0.0, "Remaining unit can enter now")
	_near(fixture.traffic.estimate_wait_seconds(edge, 2, 100.0), 1.0, "Large candidate waits one batch")
	var corpse: Dictionary = _request(fixture, "queued-corpse", edge, end, start, &"remains")
	_check(corpse["state"] == &"queued", "Wait fixture corpse bypassed FIFO")
	var before: Dictionary = fixture.traffic.get_snapshot()
	_near(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0), 2.0,
		"Occupied one + queued corpse + candidate one requires 2T")
	_near(fixture.traffic.estimate_wait_seconds(edge, 1, 50.0), 4.0, "Nominal wait speed scaling")
	var result: Dictionary = fixture.router.find_route(start, end, &"supply", 100.0)
	_check_route(result, [edge], [start, end], "Router scheduler wait compatibility")
	_near(float(result["travel_seconds"]), 1.0, "Queued route travel time")
	_near(float(result["estimated_wait_seconds"]), 2.0, "Queued route wait time")
	_near(float(result["total_cost_seconds"]), 3.0, "Queued route total cost")
	_check(fixture.traffic.get_snapshot() == before
		and fixture.traffic.get_request(String(corpse["request_id"]))["state"] == &"queued",
		"Estimate or route query granted/reordered requests")
	for speed: float in [0.0, -1.0, INF, NAN]:
		_check(fixture.traffic.estimate_wait_seconds(edge, 1, speed) == INF,
			"Invalid wait speed returned finite cost")
	for units: int in [-1, 0, 3]:
		_check(fixture.traffic.estimate_wait_seconds(edge, units, 100.0) == INF,
			"Invalid wait size returned finite cost")
	edge.entry_enabled = false
	_check(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0) == INF,
		"Closed edge wait was finite")
	edge.entry_enabled = true
	edge.traffic_capacity = 1
	_check(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0) == INF,
		"Oversized queued head returned finite wait after capacity shrink")
	_check_no_route(fixture.router.find_route(start, end), "Oversized queued head blocks route")
	edge.traffic_capacity = 2
	_check(fixture.traffic.release(String(hold["token"])), "Wait fixture hold release")
	var granted: Dictionary = fixture.traffic.get_request(String(corpse["request_id"]))
	_check(granted["state"] == &"granted", "Released wait fixture did not drain corpse")
	_near(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0), 1.0, "Full edge waits one batch")
	_check(fixture.traffic.release(String(granted["token"])), "Corpse lease release")
	_near(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0), 0.0, "Released edge retains no wait")


func _test_invalid_configuration_and_endpoints() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	_new_edge(fixture, start, end)
	var absent: Node2D = Node2D.new()
	_track(absent)
	_check_no_route(fixture.router.find_route(start, absent), "Unregistered end")
	_check_no_route(fixture.router.find_route(absent, absent), "Unregistered same node")
	_check_no_route(fixture.router.find_route(null, end), "Null start")
	_check_no_route(fixture.router.find_route(start, null), "Null end")
	var disconnected: Node2D = _new_node(fixture, Vector2(200.0, 0.0))
	_check_no_route(fixture.router.find_route(start, disconnected), "Disconnected registered endpoint")
	for speed: float in [0.0, -100.0, INF, NAN]:
		_check_no_route(fixture.router.find_route(start, end, &"supply", speed), "Invalid route speed")
		_check_no_route(fixture.router.find_route(start, start, &"supply", speed),
			"Same-node route bypassed speed validation")
	fixture.router.traffic_system = null
	_check_no_route(fixture.router.find_route(start, end), "Missing traffic system")
	fixture.router.traffic_system = fixture.traffic
	fixture.router.network_system = null
	_check_no_route(fixture.router.find_route(start, end), "Missing network system")
	var other_network: NetworkSystem = NetworkSystem.new()
	_track(other_network)
	fixture.router.network_system = other_network
	_check_no_route(fixture.router.find_route(start, end), "Scheduler and router network mismatch")
	fixture.router.network_system = fixture.network
	fixture.network.unregister_node(end)
	_check_no_route(fixture.router.find_route(start, end), "Unregistered endpoint after a valid route")


func _test_invalid_edge_costs() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var edge: LengthEdge = LengthEdge.new()
	_prepare_edge(edge, start, end)
	fixture.world.add_child(edge)
	_check(fixture.network.register_edge(edge), "Invalid-length fixture registration")
	for length: float in [-1.0, INF, NAN]:
		edge.test_length = length
		_check(fixture.network.is_edge_valid(edge), "Invalid length changed physical identity")
		_check(fixture.traffic.estimate_wait_seconds(edge, 1, 100.0) == INF,
			"Invalid edge length returned finite wait")
		_check_no_route(fixture.router.find_route(start, end), "Invalid edge length cost")
	edge.test_length = 100.0
	_check_route(fixture.router.find_route(start, end), [edge], [start, end], "Valid length restored")


func _test_pure_queries_with_pending_changes() -> void:
	var fixture: Fixture = _new_fixture()
	var start: Node2D = _new_node(fixture, Vector2.ZERO)
	var end: Node2D = _new_node(fixture, Vector2(100.0, 0.0))
	var edge: HyphaEdge = _new_edge(fixture, start, end)
	var held: Dictionary = _request(fixture, "query-hold", edge, start, end)
	var changes: Array[int] = [0, 0, 0]
	fixture.network.network_changed.connect(func() -> void: changes[0] += 1)
	fixture.traffic.traffic_changed.connect(func() -> void: changes[1] += 1)
	fixture.traffic.request_changed.connect(func(_snapshot: Dictionary) -> void: changes[2] += 1)
	var outside: Node2D = Node2D.new()
	_track(outside)
	edge.end_node = outside
	var traffic_before: Dictionary = fixture.traffic.get_snapshot()
	var request_before: Dictionary = fixture.traffic.get_request(String(held["request_id"]))
	for iteration: int in range(3):
		_check(fixture.network.get_registered_edges() == [edge]
			and fixture.network.is_node_registered(start)
			and not fixture.network.is_edge_valid(edge)
			and not fixture.network.can_enter_edge(edge)
			and fixture.network.get_topology_snapshot()["edges"].is_empty(),
			"Pure invalid endpoint query %d" % iteration)
		_check_no_route(fixture.router.find_route(start, end), "Pure invalid endpoint route")
	_check(changes == [0, 0, 0] and fixture.traffic.get_snapshot() == traffic_before
		and fixture.traffic.get_request(String(held["request_id"])) == request_before,
		"Pure queries refreshed scheduler or emitted changes")
	edge.end_node = end
	var raw_nodes: Dictionary = fixture.network.get("_nodes")
	var raw_edges: Dictionary = fixture.network.get("_edges")
	var raw_order: Array[int] = fixture.network.get("_edge_order")
	var node_count: int = raw_nodes.size()
	var edge_count: int = raw_edges.size()
	var order_before: Array[int] = raw_order.duplicate()
	edge.queue_free()
	_check(fixture.network.get_registered_edges().is_empty()
		and not fixture.network.is_edge_valid(edge)
		and fixture.network.get_topology_snapshot()["edges"].is_empty(),
		"Queued edge remained usable in pure topology")
	_check_no_route(fixture.router.find_route(start, end), "Queued edge route")
	end.queue_free()
	_check(not fixture.network.is_node_registered(end)
		and fixture.network.get_topology_snapshot()["nodes"] == [start],
		"Queued node remained registered in pure query results")
	_check_no_route(fixture.router.find_route(start, end), "Queued endpoint route")
	_check(raw_nodes.size() == node_count and raw_edges.size() == edge_count
		and raw_order == order_before and changes == [0, 0, 0],
		"Pure queries pruned pending registrations or changed traffic")


func _test_pure_queries_with_freed_objects() -> void:
	var network: NetworkSystem = NetworkSystem.new()
	var start: Node2D = Node2D.new()
	var end: Node2D = Node2D.new()
	var edge: HyphaEdge = HyphaEdge.new()
	_track(network)
	_track(start)
	_track(end)
	_track(edge)
	_prepare_edge(edge, start, end)
	network.register_node(start)
	network.register_node(end)
	network.register_edge(edge)
	var changes: Array[int] = [0]
	network.network_changed.connect(func() -> void: changes[0] += 1)
	var raw_nodes: Dictionary = network.get("_nodes")
	var raw_edges: Dictionary = network.get("_edges")
	end.free()
	_check(network.get_registered_edges() == [edge] and not network.is_edge_valid(edge)
		and not network.can_enter_edge(edge), "Freed endpoint was dereferenced or removed edge identity")
	_check(network.get_topology_snapshot()["nodes"] == [start]
		and network.get_topology_snapshot()["edges"].is_empty(), "Freed endpoint remained in topology")
	_check(raw_nodes.size() == 2 and raw_edges.size() == 1 and changes[0] == 0,
		"Pure endpoint queries pruned freed registrations")
	edge.free()
	_check(network.get_registered_edges().is_empty()
		and network.get_topology_snapshot()["edges"].is_empty(), "Freed edge remained in topology")
	_check(raw_edges.size() == 1 and changes[0] == 0, "Pure edge query pruned freed registration")


func _test_legacy_corridor_identity() -> void:
	var network: NetworkSystem = NetworkSystem.new()
	var first: HyphaNode = HyphaNode.new()
	var relay: Node2D = Node2D.new()
	var last: HyphaNode = HyphaNode.new()
	var first_edge: HyphaEdge = HyphaEdge.new()
	var last_edge: HyphaEdge = HyphaEdge.new()
	for node: Node in [network, first, relay, last, first_edge, last_edge]:
		_track(node)
	network.register_node(first, true)
	network.register_node(relay)
	network.register_node(last)
	_prepare_edge(first_edge, first, relay)
	_prepare_edge(last_edge, last, relay)
	network.register_edge(first_edge)
	network.register_edge(last_edge)
	_check(network.register_connection_corridor(first, last, [first_edge, last_edge]),
		"Legacy direct corridor fixture registration")
	var route: NetworkRoute = network.find_route(first, last)
	first_edge.entry_enabled = false
	last_edge.traffic_capacity = 0
	_check(network.has_direct_connection(first, last)
		and network.is_connected_to_core(last)
		and network.is_route_valid(route), "Traffic flags invalidated a physical direct corridor")
	_check(network.find_route(first, last).found
		and network.find_route(last, first).found, "Legacy physical BFS used traffic flags")
	first_edge.entry_enabled = true
	last_edge.traffic_capacity = 2
	_check(network.has_direct_connection(last, first)
		and network.is_route_valid(route)
		and route.segments[0].edge == first_edge and route.segments[1].edge == last_edge,
		"Reopened corridor changed route or direct-connection identities")
	_check(first_edge.start_node == first and first_edge.end_node == relay
		and last_edge.start_node == last and last_edge.end_node == relay,
		"Reopening a corridor rewired physical endpoints")


func _free_objects() -> void:
	for reference: WeakRef in _objects:
		var node: Node = reference.get_ref() as Node
		if is_instance_valid(node):
			node.free()
	_objects.clear()
