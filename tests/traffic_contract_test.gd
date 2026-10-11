extends SceneTree
## 6.2 调度、拓扑和路由的组合契约；没有真实运输包、到达回调或资源结算。
## 环路案例只建模下一节点边界，生产运输接入属于 6.3。

const REQUEST_FIELDS: Array[String] = [
	"accepted", "request_key", "request_id", "generation", "state", "reason",
	"owner", "owner_id", "task_id", "edge", "edge_id", "from_node", "from_id",
	"to_node", "to_id", "cargo_kind", "units", "sequence", "token",
]
const ROUTE_FIELDS: Array[String] = [
	"found", "route", "total_distance", "travel_seconds", "estimated_wait_seconds",
	"total_cost_seconds", "units", "reason",
]

var checks: int = 0
var failures: Array[String] = []
var case_results: Array[Dictionary] = []
var _fixtures: Array[WeakRef] = []
var _owner_sequence: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_bidirectional_units_and_replay()
	_test_fifo_under_late_arrivals()
	_test_head_cancellation()
	_test_closure_and_capacity_reduction()
	_test_rejection_and_snapshot_isolation()
	_test_task_and_generation_cleanup()
	_test_owner_cleanup()
	_test_topology_cleanup()
	_test_mutation_entrypoints_reconcile()
	await _test_queries_before_refresh()
	_test_wait_and_weighted_routes()
	_test_stable_ties_and_zero_length_cycles()
	_test_reentrant_settlement()
	_test_reentrant_reset_during_drain()
	_test_ring_boundary_model()
	_free_fixtures()
	_check(root.get_child_count() == 0, "Contract teardown leaves no fixture nodes")
	print("TRAFFIC_CONTRACT_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": case_results,
		"scope": "6.2_module_contract", "packet_integration": false,
		"owner_model": "Node_with_nutrition_metadata",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(points: Array[Vector2], pairs: Array[Vector2i], capacity: int = 2) -> Dictionary:
	var container: Node = Node.new()
	container.name = "TrafficContractFixture%d" % _fixtures.size()
	root.add_child(container)
	_fixtures.append(weakref(container))
	var events: Dictionary = {"requests": [], "traffic_changes": 0, "network_changes": 0}
	var network: NetworkSystem = NetworkSystem.new()
	container.add_child(network)
	network.network_changed.connect(func() -> void:
		events["network_changes"] = int(events["network_changes"]) + 1)
	var nodes: Array[Node2D] = []
	for point: Vector2 in points:
		var node: Node2D = Node2D.new()
		node.position = point
		container.add_child(node)
		nodes.append(node)
		_check(network.register_node(node), "Fixture registers a real topology node")
	var edges: Array[HyphaEdge] = []
	for pair: Vector2i in pairs:
		var edge: HyphaEdge = _new_edge(container, nodes[pair.x], nodes[pair.y], capacity)
		edges.append(edge)
		_check(network.register_edge(edge), "Fixture registers a real topology edge")
	var traffic: NetworkTrafficSystem = NetworkTrafficSystem.new()
	traffic.network_system = network
	container.add_child(traffic)
	traffic.set_process(false)
	traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		var records: Array = events["requests"]
		records.append(_event_record(snapshot)))
	traffic.traffic_changed.connect(func() -> void:
		events["traffic_changes"] = int(events["traffic_changes"]) + 1)
	var router: TransportRouter = TransportRouter.new()
	router.network_system = network
	router.traffic_system = traffic
	container.add_child(router)
	router.set_process(false)
	return {"container": container, "network": network, "traffic": traffic,
		"router": router, "nodes": nodes, "edges": edges, "events": events}


func _new_edge(container: Node, start: Node2D, end: Node2D, capacity: int) -> HyphaEdge:
	var edge: HyphaEdge = HyphaEdge.new()
	edge.start_node = start
	edge.end_node = end
	edge.traffic_capacity = capacity
	var vein: Line2D = Line2D.new()
	vein.name = "Vein"
	edge.add_child(vein)
	container.add_child(edge)
	edge.set_process(false)
	return edge


func _new_owner(fixture: Dictionary, nutrition: int, kind: StringName = &"supply") -> Node:
	var owner: Node = Node.new()
	_owner_sequence += 1
	owner.name = "ModeledOwner%d" % _owner_sequence
	owner.set_meta(&"nutrition", nutrition)
	owner.set_meta(&"cargo_kind", kind)
	var container: Node = fixture["container"]
	container.add_child(owner)
	return owner


func _request(fixture: Dictionary, key: String, owner: Node, edge_index: int,
		from_index: int, to_index: int, kind: StringName = &"supply", task: String = "contract") -> Dictionary:
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var nodes: Array[Node2D] = fixture["nodes"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	return traffic.request_passage(key, owner, task, edges[edge_index],
		nodes[from_index], nodes[to_index], kind)


func _event_record(snapshot: Dictionary) -> Dictionary:
	return {"request_id": String(snapshot.get("request_id", "")),
		"generation": int(snapshot.get("generation", -1)), "state": String(snapshot.get("state", &"")),
		"token": String(snapshot.get("token", "")), "units": int(snapshot.get("units", 0)),
		"sequence": int(snapshot.get("sequence", 0))}


func _signal_counts(fixture: Dictionary) -> Array[int]:
	var events: Dictionary = fixture["events"]
	var requests: Array = events["requests"]
	return [requests.size(), int(events["traffic_changes"]), int(events["network_changes"])]


func _ids(snapshots: Array) -> Array[String]:
	var result: Array[String] = []
	for snapshot: Dictionary in snapshots:
		result.append(String(snapshot.get("request_id", "")))
	return result


func _state(traffic: NetworkTrafficSystem, request: Dictionary) -> StringName:
	var snapshot: Dictionary = traffic.get_request(String(request.get("request_id", "")))
	return StringName(snapshot.get("state", &""))


func _token(request: Dictionary) -> String:
	return String(request.get("token", ""))


func _check_request(request: Dictionary, state: StringName, units: int, context: String) -> void:
	for field: String in REQUEST_FIELDS:
		_check(request.has(field), context + ": snapshot field " + field)
	_check(bool(request.get("accepted", false)), context + ": accepted request")
	_check(StringName(request.get("state", &"")) == state, context + ": expected state")
	_check(int(request.get("units", -1)) == units, context + ": cargo occupancy units")
	_check(not String(request.get("request_id", "")).is_empty(), context + ": opaque request ID")
	_check((_token(request).is_empty()) == (state != &"granted"), context + ": active token only while granted")


func _check_rejected(request: Dictionary, context: String) -> void:
	_check(not bool(request.get("accepted", true)), context + ": rejected request")
	_check(StringName(request.get("state", &"")) == &"rejected", context + ": rejected state")
	_check(not String(request.get("reason", "")).is_empty(), context + ": rejection reason")
	_check(String(request.get("request_id", "")).is_empty() and _token(request).is_empty(),
		context + ": rejection has no request or lease identity")


func _check_totals(traffic: NetworkTrafficSystem, occupied: int, queued: int,
		leases: int, context: String) -> void:
	var snapshot: Dictionary = traffic.get_snapshot()
	_check(int(snapshot.get("occupied_units", -1)) == occupied, context + ": global occupancy")
	_check(int(snapshot.get("queued_count", -1)) == queued, context + ": global queue count")
	_check(int(snapshot.get("active_lease_count", -1)) == leases, context + ": active lease count")
	_check(int(snapshot.get("active_request_count", -1)) == queued + leases,
		context + ": active requests equal queued plus granted")


func _check_route(result: Dictionary, expected_edges: Array[HyphaEdge],
		expected_nodes: Array[Node2D], context: String) -> void:
	for field: String in ROUTE_FIELDS:
		_check(result.has(field), context + ": route field " + field)
	_check(bool(result.get("found", false)), context + ": route found")
	var route: NetworkRoute = result.get("route") as NetworkRoute
	_check(route != null, context + ": real NetworkRoute snapshot")
	if route == null:
		return
	_check(route.found and route.start_node == expected_nodes[0] and route.end_node == expected_nodes[-1],
		context + ": route endpoints and found flag")
	_check(route.segments.size() == expected_edges.size(), context + ": segment count")
	var visited: Array[Node2D] = [expected_nodes[0]]
	for index: int in range(mini(route.segments.size(), expected_edges.size())):
		var segment: NetworkRoute.Segment = route.segments[index]
		_check(segment.edge == expected_edges[index], context + ": edge order %d" % index)
		_check(segment.start_node == expected_nodes[index] and segment.end_node == expected_nodes[index + 1],
			context + ": directed endpoints %d" % index)
		_check(segment.forward == (segment.edge.start_node == segment.start_node),
			context + ": original edge direction %d" % index)
		_check(not visited.has(segment.end_node), context + ": no repeated route node")
		visited.append(segment.end_node)


func _check_no_route(result: Dictionary, context: String) -> void:
	_check(not bool(result.get("found", true)), context + ": route not found")
	_check(not String(result.get("reason", "")).is_empty(), context + ": route failure reason")
	var route: NetworkRoute = result.get("route") as NetworkRoute
	_check(route != null and not route.found and route.segments.is_empty(), context + ": failed route has no segments")


func _finish_case(name: String, fixture: Dictionary, evidence: Dictionary = {}) -> void:
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var snapshot: Dictionary = traffic.get_snapshot()
	case_results.append({"name": name, "generation": traffic.get_generation(),
		"occupied_units": int(snapshot.get("occupied_units", -1)),
		"queued_count": int(snapshot.get("queued_count", -1)),
		"active_lease_count": int(snapshot.get("active_lease_count", -1)),
		"signal_counts": _signal_counts(fixture), "evidence": evidence})


func _test_bidirectional_units_and_replay() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var network: NetworkSystem = fixture["network"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	var supply_owner: Node = _new_owner(fixture, 1)
	var return_owner: Node = _new_owner(fixture, 10, &"return")
	var remains_owner: Node = _new_owner(fixture, 137, &"remains")
	_check(NetworkTrafficSystem.units_for_kind(&"supply") == 1
		and NetworkTrafficSystem.units_for_kind(&"return") == 1
		and NetworkTrafficSystem.units_for_kind(&"remains") == 2
		and NetworkTrafficSystem.units_for_kind(&"unknown") == 0, "Cargo kinds have fixed occupancy units")
	var supply: Dictionary = _request(fixture, "supply-hop-1", supply_owner, 0, 0, 1)
	var returned: Dictionary = _request(fixture, "return-hop-1", return_owner, 0, 1, 0, &"return")
	_check_request(supply, &"granted", 1, "Forward supply")
	_check_request(returned, &"granted", 1, "Reverse ten-nutrition return")
	_check(supply.get("owner") == supply_owner and int(supply.get("owner_id", 0)) == supply_owner.get_instance_id(),
		"Request identifies its exact owner Node")
	_check(returned.get("edge") == edges[0] and returned.get("from_node") == edges[0].end_node
		and returned.get("to_node") == edges[0].start_node, "Reverse request retains edge and directed anchors")
	_check_totals(traffic, 2, 0, 2, "Two opposite-direction small cargoes share capacity")
	var shared: Dictionary = traffic.get_edge_snapshot(edges[0])
	for field: String in ["exists", "edge", "edge_id", "capacity", "entry_enabled",
			"occupied_units", "available_units", "queue", "leases"]:
		_check(shared.has(field), "Shared edge snapshot field " + field)
	_check(bool(shared.get("exists", false)) and int(shared.get("edge_id", 0)) == edges[0].get_instance_id()
		and int(shared.get("available_units", -1)) == 0, "Shared edge snapshot identifies a full live edge")
	_check(_ids(shared.get("leases", [])) == [String(supply["request_id"]), String(returned["request_id"])],
		"Opposite-direction active leases retain grant order")
	_check(network.can_enter_edge(edges[0], 2), "Topology capacity check is independent of free occupancy")
	var before_replay: Array[int] = _signal_counts(fixture)
	var replay: Dictionary = _request(fixture, "supply-hop-1", supply_owner, 0, 0, 1)
	_check(replay == supply and _signal_counts(fixture) == before_replay, "Identical per-hop key replays without new admission or signals")
	_check_rejected(_request(fixture, "supply-hop-1", supply_owner, 0, 0, 1, &"return"),
		"Conflicting cargo reuse of an existing key")
	_check_rejected(_request(fixture, "owner-busy-key", supply_owner, 0, 1, 0), "Owner cannot hold a second active request")
	var remains: Dictionary = _request(fixture, "remains-hop-1", remains_owner, 0, 1, 0, &"remains")
	_check_request(remains, &"queued", 2, "Arbitrary-nutrition remains")
	_check(traffic.release(_token(supply)) and not traffic.release(_token(supply)), "Supply token releases exactly once")
	_check(_state(traffic, remains) == &"queued", "Two-unit remains cannot enter one free unit")
	_check(traffic.release(_token(returned)) and not traffic.release(_token(returned)), "Reverse return token releases exactly once")
	var granted_remains: Dictionary = traffic.get_request(String(remains["request_id"]))
	_check_request(granted_remains, &"granted", 2, "Remains after both small cargoes release")
	_check_totals(traffic, 2, 0, 1, "One remains consumes the whole edge")
	_check(int(return_owner.get_meta(&"nutrition")) == 10 and int(remains_owner.get_meta(&"nutrition")) == 137,
		"Admission and release preserve independent nutrition metadata")
	_check(traffic.release(_token(granted_remains)), "Remains lease settles")
	var terminal: Dictionary = _request(fixture, "supply-hop-1", supply_owner, 0, 0, 1)
	_check_request(terminal, &"released", 1, "Released key replay")
	_check(terminal.get("request_id") == supply.get("request_id") and terminal.get("sequence") == supply.get("sequence"),
		"Terminal replay retains request identity and FIFO sequence")
	_check(not traffic.cancel_request(String(supply["request_id"])) and traffic.get_lease(_token(supply)).is_empty(),
		"Settled request cannot cancel or recover its old active lease")
	_check(traffic.get_request("unknown-request").is_empty() and traffic.get_lease("unknown-token").is_empty(),
		"Unknown request and lease queries are empty")
	_check_totals(traffic, 0, 0, 0, "Bidirectional case settles")
	_finish_case("bidirectional_units_and_key_replay", fixture,
		{"return_nutrition": 10, "return_units": 1, "remains_nutrition": 137, "remains_units": 2})


func _test_fifo_under_late_arrivals() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	var blocker: Dictionary = _request(fixture, "fifo-blocker", _new_owner(fixture, 1), 0, 0, 1)
	var head: Dictionary = _request(fixture, "fifo-remains-head", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
	var late: Array[Dictionary] = []
	var expected_queue: Array[String] = [String(head["request_id"])]
	for index: int in range(12):
		var kind: StringName = &"supply" if index % 2 == 0 else &"return"
		var request: Dictionary = _request(fixture, "fifo-late-%d" % index,
			_new_owner(fixture, 10 if kind == &"return" else 1, kind), 0,
			index % 2, 1 - index % 2, kind)
		late.append(request)
		expected_queue.append(String(request["request_id"]))
		_check_request(request, &"queued", 1, "Late small arrival %d" % index)
		var edge_snapshot: Dictionary = traffic.get_edge_snapshot(edges[0])
		_check(_ids(edge_snapshot.get("queue", [])) == expected_queue
			and int(edge_snapshot.get("occupied_units", -1)) == 1,
			"Repeated late small arrival %d never bypasses the two-unit FIFO head" % index)
	_check(traffic.release(_token(blocker)), "FIFO blocker releases its one unit")
	_check(_state(traffic, head) == &"granted", "Remains head grants before all late small arrivals")
	for request: Dictionary in late:
		_check(_state(traffic, request) == &"queued", "Remains owns both units before late small grants")
	var head_live: Dictionary = traffic.get_request(String(head["request_id"]))
	_check(traffic.release(_token(head_live)), "FIFO remains head releases once")
	for request: Dictionary in late:
		var live: Dictionary = traffic.get_request(String(request["request_id"]))
		_check(StringName(live.get("state", &"")) == &"granted", "Each oldest late small progresses after predecessors settle")
		_check(traffic.release(_token(live)), "Late small releases its own current token")
	var grants: Array[String] = []
	var events: Dictionary = fixture["events"]
	for event: Dictionary in events["requests"]:
		if event.get("state") == "granted":
			grants.append(String(event["request_id"]))
	var expected_grants: Array[String] = [String(blocker["request_id"]), String(head["request_id"])]
	expected_grants.append_array(_ids(late))
	_check(grants == expected_grants, "Grant notifications follow one FIFO across both directions without starvation")
	_check_totals(traffic, 0, 0, 0, "Repeated-arrival FIFO drains completely")
	_finish_case("fifo_no_small_bypass_or_starvation", fixture, {"late_small_arrivals": late.size(), "grant_order": grants})


func _test_head_cancellation() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var blocker: Dictionary = _request(fixture, "cancel-head-blocker", _new_owner(fixture, 1), 0, 0, 1)
	var head: Dictionary = _request(fixture, "cancel-head-remains", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
	var small: Dictionary = _request(fixture, "cancel-head-small", _new_owner(fixture, 10, &"return"), 0, 1, 0, &"return")
	_check(_state(traffic, small) == &"queued", "Fitting small waits behind an oversized-for-free-space head")
	_check(traffic.cancel_request(String(head["request_id"]))
		and not traffic.cancel_request(String(head["request_id"])), "Queued head cancellation occurs exactly once")
	_check(_state(traffic, head) == &"cancelled" and _state(traffic, small) == &"granted", "Head cancellation exposes the next fitting FIFO request")
	var small_live: Dictionary = traffic.get_request(String(small["request_id"]))
	_check(traffic.cancel_request(String(small["request_id"]))
		and not traffic.cancel_request(String(small["request_id"]))
		and not traffic.release(_token(small_live)), "Granted cancellation revokes its token exactly once")
	_check(traffic.release(_token(blocker)), "Unrelated blocker survives head and granted cancellation")
	_check_totals(traffic, 0, 0, 0, "Cancellation case settles")
	_finish_case("head_cancellation_and_unique_settlement", fixture)


func _test_closure_and_capacity_reduction() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var network: NetworkSystem = fixture["network"]
	var router: TransportRouter = fixture["router"]
	var nodes: Array[Node2D] = fixture["nodes"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	var edge: HyphaEdge = edges[0]
	var edge_id: int = edge.get_instance_id()
	var settings: Array[Dictionary] = []
	edge.traffic_settings_changed.connect(func() -> void:
		settings.append({"capacity": edge.traffic_capacity, "entry_enabled": edge.entry_enabled}))
	var active: Dictionary = _request(fixture, "closed-active", _new_owner(fixture, 1), 0, 0, 1)
	var head: Dictionary = _request(fixture, "closed-head", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
	var physical_route: NetworkRoute = network.find_route(nodes[0], nodes[1])
	edge.entry_enabled = false
	traffic.refresh()
	_check(not settings.is_empty() and not bool(settings[-1]["entry_enabled"]), "Entry setting signal observes the committed closed flag")
	_check(network.is_edge_valid(edge) and network.get_registered_edges().has(edge)
		and edge.get_instance_id() == edge_id, "Temporary closure retains physical edge validity and identity")
	_check(not network.can_enter_edge(edge, 1), "Closed edge blocks new entry permission")
	_check(network.find_route(nodes[0], nodes[1]).found and network.is_route_valid(physical_route),
		"Legacy physical BFS and existing route validity ignore traffic closure")
	var topology: Dictionary = network.get_topology_snapshot()
	var rows: Array = topology.get("edges", [])
	_check(rows.size() == 1 and rows[0].get("edge") == edge
		and not bool(rows[0].get("entry_enabled", true)), "Pure topology includes the closed physical edge")
	_check(_state(traffic, active) == &"granted" and _state(traffic, head) == &"queued", "Closure retains active lease and valid queued head")
	var tail: Dictionary = _request(fixture, "closed-tail", _new_owner(fixture, 10, &"return"), 0, 0, 1, &"return")
	_check_request(tail, &"queued", 1, "New request anchored at a closed registered endpoint")
	_check_no_route(router.find_route(nodes[0], nodes[1], &"supply", 60.0), "Router skips temporary closure")
	_check(is_inf(traffic.estimate_wait_seconds(edge, 1, 60.0)), "Closed edge wait is infinite")
	edge.entry_enabled = true
	traffic.refresh()
	_check(_state(traffic, head) == &"queued" and _state(traffic, tail) == &"queued", "Reopening preserves FIFO when the head still does not fit")
	edge.traffic_capacity = 1
	traffic.refresh()
	_check(int(settings[-1]["capacity"]) == 1, "Capacity setting signal observes its committed value")
	_check(traffic.release(_token(active)), "Active small releases after capacity reduction")
	var reduced: Dictionary = traffic.get_edge_snapshot(edge)
	_check(int(reduced.get("occupied_units", -1)) == 0 and int(reduced.get("available_units", -1)) == 1
		and _state(traffic, head) == &"queued" and _state(traffic, tail) == &"queued",
		"Head larger than reduced capacity blocks fitting later smalls")
	_check(is_inf(traffic.estimate_wait_seconds(edge, 1, 60.0)), "Oversized queued head makes candidate wait infinite")
	edge.traffic_capacity = 2
	traffic.refresh()
	var head_live: Dictionary = traffic.get_request(String(head["request_id"]))
	_check_request(head_live, &"granted", 2, "Restored capacity drains the retained head")
	edge.traffic_capacity = 1
	traffic.refresh()
	var overloaded: Dictionary = traffic.get_edge_snapshot(edge)
	_check(_state(traffic, head) == &"granted" and int(overloaded.get("occupied_units", -1)) == 2
		and int(overloaded.get("available_units", -1)) == 0, "Capacity reduction retains existing over-capacity occupancy and clamps availability")
	edge.traffic_capacity = -7
	traffic.refresh()
	_check(edge.traffic_capacity == 0 and int(settings[-1]["capacity"]) == 0, "Negative traffic capacity normalizes before its signal")
	_check(_state(traffic, head) == &"granted" and not network.can_enter_edge(edge, 1), "Zero capacity preserves a held lease and prevents fresh entry")
	_check(traffic.release(_token(head_live)), "Over-capacity lease can still release")
	_check(_state(traffic, tail) == &"queued", "Zero capacity retains the valid tail without entry")
	edge.traffic_capacity = 2
	traffic.refresh()
	var tail_live: Dictionary = traffic.get_request(String(tail["request_id"]))
	_check_request(tail_live, &"granted", 1, "Restored capacity admits the retained tail")
	_check(traffic.release(_token(tail_live)), "Reopened tail settles")
	_check_totals(traffic, 0, 0, 0, "Closure and capacity case settles")
	_finish_case("closure_and_capacity_changes_preserve_identity", fixture, {"edge_id": edge_id, "settings": settings})


func _test_rejection_and_snapshot_isolation() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0), Vector2(240, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var network: NetworkSystem = fixture["network"]
	var router: TransportRouter = fixture["router"]
	var nodes: Array[Node2D] = fixture["nodes"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	var owner: Node = _new_owner(fixture, 1)
	var queued_owner: Node = _new_owner(fixture, 1)
	queued_owner.queue_free()
	var absent: Node2D = Node2D.new()
	var container: Node = fixture["container"]
	container.add_child(absent)
	var unregistered_edge: HyphaEdge = _new_edge(container, nodes[0], nodes[1], 2)
	var invalid: Array[Dictionary] = [
		traffic.request_passage("", owner, "task", edges[0], nodes[0], nodes[1], &"supply"),
		traffic.request_passage("empty-task", owner, "", edges[0], nodes[0], nodes[1], &"supply"),
		traffic.request_passage("null-owner", null, "task", edges[0], nodes[0], nodes[1], &"supply"),
		traffic.request_passage("queued-owner", queued_owner, "task", edges[0], nodes[0], nodes[1], &"supply"),
		traffic.request_passage("null-edge", owner, "task", null, nodes[0], nodes[1], &"supply"),
		traffic.request_passage("unregistered-edge", owner, "task", unregistered_edge, nodes[0], nodes[1], &"supply"),
		traffic.request_passage("invalid-direction", owner, "task", edges[0], nodes[0], nodes[0], &"supply"),
		traffic.request_passage("wrong-anchor", owner, "task", edges[0], nodes[2], nodes[1], &"supply"),
		traffic.request_passage("unregistered-anchor", owner, "task", edges[0], absent, nodes[1], &"supply"),
		traffic.request_passage("unknown-kind", owner, "task", edges[0], nodes[0], nodes[1], &"unknown"),
	]
	for index: int in range(invalid.size()):
		_check_rejected(invalid[index], "Invalid request %d" % index)
	edges[0].traffic_capacity = 1
	_check_rejected(_request(fixture, "too-large", owner, 0, 0, 1, &"remains"), "Cargo larger than total capacity")
	_check_totals(traffic, 0, 0, 0, "Rejected requests never create active records")
	edges[0].traffic_capacity = 2
	var active: Dictionary = _request(fixture, "copy-active", owner, 0, 0, 1)
	var queued: Dictionary = _request(fixture, "copy-queued", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
	var before: Dictionary = traffic.get_snapshot()
	var counts: Array[int] = _signal_counts(fixture)
	var request_copy: Dictionary = traffic.get_request(String(active["request_id"]))
	request_copy["state"] = &"cancelled"
	request_copy["units"] = 99
	request_copy["token"] = "foreign-token"
	var lease_copy: Dictionary = traffic.get_lease(_token(active))
	lease_copy["units"] = 99
	var edge_copy: Dictionary = traffic.get_edge_snapshot(edges[0])
	var queue_copy: Array = edge_copy.get("queue", [])
	var leases_copy: Array = edge_copy.get("leases", [])
	if not queue_copy.is_empty():
		queue_copy[0]["units"] = 99
	if not leases_copy.is_empty():
		leases_copy[0]["state"] = &"cancelled"
	queue_copy.clear()
	leases_copy.clear()
	edge_copy["capacity"] = 99
	var global_copy: Dictionary = traffic.get_snapshot()
	var global_edges: Array = global_copy.get("edges", [])
	if not global_edges.is_empty():
		global_edges[0]["occupied_units"] = 99
	global_edges.clear()
	var topology_copy: Dictionary = network.get_topology_snapshot()
	var copied_nodes: Array = topology_copy.get("nodes", [])
	var copied_rows: Array = topology_copy.get("edges", [])
	_check(copied_nodes == nodes, "Pure topology preserves node registration order")
	if not copied_rows.is_empty():
		var row: Dictionary = copied_rows[0]
		for field: String in ["edge", "edge_id", "start_node", "end_node",
				"start_id", "end_id", "length", "capacity", "entry_enabled"]:
			_check(row.has(field), "Topology edge row field " + field)
		_check(row.get("start_node") == nodes[0] and row.get("end_node") == nodes[1]
			and int(row.get("start_id", 0)) == nodes[0].get_instance_id()
			and int(row.get("end_id", 0)) == nodes[1].get_instance_id()
			and is_equal_approx(float(row.get("length", -1.0)), 120.0),
			"Topology row exposes exact registered endpoints, IDs, and live length")
	if not copied_rows.is_empty():
		copied_rows[0]["capacity"] = 99
	copied_nodes.clear()
	copied_rows.clear()
	var registration_copy: Array[HyphaEdge] = network.get_registered_edges()
	registration_copy.clear()
	for _repeat: int in range(20):
		traffic.get_request(String(queued["request_id"]))
		traffic.get_lease(_token(active))
		traffic.get_edge_snapshot(edges[0])
		traffic.get_snapshot()
		traffic.get_generation()
		traffic.estimate_wait_seconds(edges[0], 1, 60.0)
		network.get_topology_snapshot()
		network.get_registered_edges()
		network.is_node_registered(nodes[0])
		network.is_edge_valid(edges[0])
		network.can_enter_edge(edges[0], 1)
		router.find_route(nodes[0], nodes[1], &"return", 60.0)
	_check(traffic.get_snapshot() == before and _signal_counts(fixture) == counts,
		"Copied nested snapshots and repeated pure route queries neither mutate nor emit")
	_check(_state(traffic, active) == &"granted" and _state(traffic, queued) == &"queued",
		"External snapshot edits cannot grant, cancel, resize, or settle live requests")
	var live_topology: Dictionary = network.get_topology_snapshot()
	var live_rows: Array = live_topology.get("edges", [])
	var live_nodes: Array = live_topology.get("nodes", [])
	_check(live_nodes.size() == 3 and live_rows.size() == 1
		and int(live_rows[0].get("capacity", -1)) == 2, "Topology snapshot copies cannot mutate registration or edge settings")
	_finish_case("invalid_admission_and_observational_snapshot_copies", fixture, {"pure_query_repetitions": 20})


func _test_task_and_generation_cleanup() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0), Vector2(240, 0)],
		[Vector2i(0, 1), Vector2i(1, 2)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var generation: int = traffic.get_generation()
	var owner: Node = _new_owner(fixture, 1)
	var active: Dictionary = _request(fixture, "generation-key", owner, 0, 0, 1, &"supply", "retired-task")
	var queued: Dictionary = _request(fixture, "generation-queued", _new_owner(fixture, 80, &"remains"),
		0, 1, 0, &"remains", "retired-task")
	var unrelated: Dictionary = _request(fixture, "generation-other", _new_owner(fixture, 10, &"return"),
		1, 1, 2, &"return", "unrelated-task")
	_check(traffic.cancel_task("retired-task", generation - 1) == 0, "Stale task generation cannot cancel current requests")
	_check(_state(traffic, active) == &"granted" and _state(traffic, queued) == &"queued", "Stale task callback preserves current queue and lease")
	_check(traffic.cancel_task("retired-task", generation) == 2
		and traffic.cancel_task("retired-task", generation) == 0, "Current task cancellation settles its queued and granted records once")
	_check(_state(traffic, active) == &"cancelled" and _state(traffic, queued) == &"cancelled"
		and _state(traffic, unrelated) == &"granted", "Task cancellation preserves another task on another edge")
	_check_rejected(_request(fixture, "retired-callback-key", _new_owner(fixture, 1), 0, 0, 1,
		&"supply", "retired-task"), "Retired task cannot resurrect through a fresh callback key")
	var replay: Dictionary = _request(fixture, "generation-key", owner, 0, 0, 1, &"supply", "retired-task")
	_check(replay.get("request_id") == active.get("request_id") and replay.get("state") == &"cancelled",
		"Identical retired-key replay returns its original terminal record")
	traffic.reset()
	_check(traffic.get_generation() > generation, "Reset advances monotonic scheduler generation")
	_check(traffic.get_request(String(active["request_id"])).is_empty()
		and traffic.get_request(String(queued["request_id"])).is_empty()
		and traffic.get_request(String(unrelated["request_id"])).is_empty()
		and traffic.get_lease(_token(unrelated)).is_empty(), "Reset clears all old records, queues, and leases")
	_check_totals(traffic, 0, 0, 0, "Reset settles global occupancy")
	var replacement: Dictionary = _request(fixture, "generation-key", owner, 0, 0, 1, &"supply", "retired-task")
	_check_request(replacement, &"granted", 1, "Reused key and task after reset")
	_check(replacement.get("request_id") != active.get("request_id") and _token(replacement) != _token(active)
		and int(replacement.get("generation", -1)) == traffic.get_generation(), "Replacement gets fresh opaque request and lease identities")
	_check(not traffic.release(_token(active)) and not traffic.release(_token(unrelated))
		and not traffic.cancel_request(String(active["request_id"]))
		and traffic.cancel_task("retired-task", generation) == 0, "All old-generation callbacks are inert against reused keys")
	_check(_state(traffic, replacement) == &"granted", "Old-generation callbacks cannot settle the replacement")
	var other_fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var other_traffic: NetworkTrafficSystem = other_fixture["traffic"]
	var other: Dictionary = _request(other_fixture, "generation-key", _new_owner(other_fixture, 1), 0, 0, 1,
		&"supply", "retired-task")
	_check(other.get("request_id") != replacement.get("request_id") and other.get("request_id") != active.get("request_id")
		and _token(other) != _token(replacement) and _token(other) != _token(active),
		"Different scheduler instances never share request IDs or lease tokens, even in the same generation")
	_check(not other_traffic.release(_token(replacement)) and not traffic.release(_token(other)),
		"Foreign scheduler tokens cannot settle local leases")
	_finish_case("task_retirement_and_generation_identity", fixture,
		{"old_generation": generation, "new_generation": traffic.get_generation(), "cross_instance_ids_distinct": true})


func _test_owner_cleanup() -> void:
	for scenario: String in ["cancel_owner", "owner_tree_exit", "freed_owner"]:
		var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
		var traffic: NetworkTrafficSystem = fixture["traffic"]
		var container: Node = fixture["container"]
		var owner: Node = _new_owner(fixture, 1)
		var next_owner: Node = _new_owner(fixture, 80, &"remains")
		var active: Dictionary = _request(fixture, scenario + "-active", owner, 0, 0, 1)
		var queued: Dictionary = _request(fixture, scenario + "-queued", next_owner, 0, 1, 0, &"remains")
		match scenario:
			"cancel_owner":
				_check(traffic.cancel_owner(owner) == 1 and traffic.cancel_owner(owner) == 0, "Owner cancellation settles its one active request once")
			"owner_tree_exit":
				container.remove_child(owner)
				_check(_state(traffic, active) == &"cancelled", "Owner tree_exiting cancels its lease before re-entry")
				container.add_child(owner)
			"freed_owner":
				owner.free()
		traffic.refresh()
		_check(_state(traffic, active) == &"cancelled" and traffic.get_lease(_token(active)).is_empty(),
			scenario + ": owner cleanup retires the original active token")
		_check(_state(traffic, queued) == &"granted", scenario + ": releasing dead owner's occupancy lets the FIFO head progress")
		_check(traffic.cancel_owner(next_owner) == 1 and traffic.cancel_owner(next_owner) == 0,
			scenario + ": subsequent owner cleanup is unique")
		_check_totals(traffic, 0, 0, 0, scenario + ": cleanup settles")
		_finish_case(scenario, fixture)

	for scenario: String in ["queued_owner_cancel", "queued_owner_tree_exit", "queued_owner_for_deletion"]:
		var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
		var traffic: NetworkTrafficSystem = fixture["traffic"]
		var container: Node = fixture["container"]
		var blocker: Dictionary = _request(fixture, scenario + "-blocker", _new_owner(fixture, 1), 0, 0, 1)
		var head_owner: Node = _new_owner(fixture, 80, &"remains")
		var head: Dictionary = _request(fixture, scenario + "-head", head_owner, 0, 1, 0, &"remains")
		var tail: Dictionary = _request(fixture, scenario + "-tail", _new_owner(fixture, 10, &"return"), 0, 0, 1, &"return")
		match scenario:
			"queued_owner_cancel":
				_check(traffic.cancel_owner(head_owner) == 1 and traffic.cancel_owner(head_owner) == 0,
					"Queued owner cancellation settles its waiting record exactly once")
			"queued_owner_tree_exit":
				container.remove_child(head_owner)
				_check(_state(traffic, head) == &"cancelled", "Queued owner tree exit cancels before re-entry")
				container.add_child(head_owner)
			"queued_owner_for_deletion":
				head_owner.queue_free()
		traffic.refresh()
		_check(_state(traffic, head) == &"cancelled" and _state(traffic, tail) == &"granted",
			scenario + ": dead queued head exposes the fitting later return")
		_check(traffic.release(_token(blocker)), scenario + ": unrelated blocker keeps its valid token")
		var tail_live: Dictionary = traffic.get_request(String(tail["request_id"]))
		_check(traffic.release(_token(tail_live)), scenario + ": fitting return settles normally")
		_check_totals(traffic, 0, 0, 0, scenario + ": queued owner cleanup settles")
		_finish_case(scenario, fixture)


func _test_topology_cleanup() -> void:
	for scenario: String in ["edge_unregister", "node_unregister", "changed_endpoint", "swapped_endpoints",
			"edge_tree_exit", "node_tree_exit", "freed_edge", "freed_endpoint"]:
		var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0), Vector2(240, 0)], [Vector2i(0, 1)])
		var traffic: NetworkTrafficSystem = fixture["traffic"]
		var network: NetworkSystem = fixture["network"]
		var container: Node = fixture["container"]
		var nodes: Array[Node2D] = fixture["nodes"]
		var edges: Array[HyphaEdge] = fixture["edges"]
		var active: Dictionary = _request(fixture, scenario + "-active", _new_owner(fixture, 1), 0, 0, 1)
		var queued: Dictionary = _request(fixture, scenario + "-queued", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
		match scenario:
			"edge_unregister":
				network.unregister_edge(edges[0])
			"node_unregister":
				network.unregister_node(nodes[1])
			"changed_endpoint":
				edges[0].end_node = nodes[2]
				_check(network.is_edge_valid(edges[0]), "Changed registered endpoint remains a physically valid edge")
			"swapped_endpoints":
				edges[0].start_node = nodes[1]
				edges[0].end_node = nodes[0]
			"edge_tree_exit":
				container.remove_child(edges[0])
				container.add_child(edges[0])
			"node_tree_exit":
				container.remove_child(nodes[1])
				container.add_child(nodes[1])
			"freed_edge":
				edges[0].free()
			"freed_endpoint":
				nodes[1].free()
		traffic.refresh()
		_check(_state(traffic, active) == &"cancelled" and _state(traffic, queued) == &"cancelled",
			scenario + ": both directions cancel their original edge traversal records")
		_check(traffic.get_lease(_token(active)).is_empty() and not traffic.release(_token(active)),
			scenario + ": old edge token is no longer active")
		_check_totals(traffic, 0, 0, 0, scenario + ": affected topology cleans all occupancy and queue")
		_finish_case(scenario, fixture)


func _exercise_pure_queries(fixture: Dictionary, active: Dictionary, queued: Dictionary,
		edge: HyphaEdge, start: Node2D, end: Node2D, context: String) -> void:
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var network: NetworkSystem = fixture["network"]
	var router: TransportRouter = fixture["router"]
	var counts: Array[int] = _signal_counts(fixture)
	var generation: int = traffic.get_generation()
	var active_state: StringName = _state(traffic, active)
	var queued_state: StringName = _state(traffic, queued)
	for _repeat: int in range(4):
		traffic.get_request(String(active["request_id"]))
		traffic.get_request(String(queued["request_id"]))
		traffic.get_lease(_token(active))
		traffic.get_edge_snapshot(edge)
		traffic.get_snapshot()
		traffic.estimate_wait_seconds(edge, 1, 60.0)
		network.get_topology_snapshot()
		network.get_registered_edges()
		network.is_node_registered(start)
		network.is_node_registered(end)
		network.is_edge_valid(edge)
		network.can_enter_edge(edge, 1)
		router.find_route(start, end, &"supply", 60.0)
	_check(_signal_counts(fixture) == counts and traffic.get_generation() == generation,
		context + ": queries do not refresh, emit, or advance generations")
	_check(_state(traffic, active) == active_state and _state(traffic, queued) == queued_state,
		context + ": queries leave stored request states untouched until an explicit mutation")


func _test_mutation_entrypoints_reconcile() -> void:
	for entrypoint: String in ["release", "cancel_request", "request_passage"]:
		var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0), Vector2(240, 0)], [Vector2i(0, 1)])
		var traffic: NetworkTrafficSystem = fixture["traffic"]
		var nodes: Array[Node2D] = fixture["nodes"]
		var edges: Array[HyphaEdge] = fixture["edges"]
		var owner: Node = _new_owner(fixture, 1)
		var active: Dictionary = _request(fixture, entrypoint + "-old-active", owner, 0, 0, 1)
		var queued: Dictionary = _request(fixture, entrypoint + "-old-queued", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
		edges[0].end_node = nodes[2]
		match entrypoint:
			"release":
				_check(not traffic.release(_token(active)), "Release reconciles direct endpoint change before accepting an obsolete token")
			"cancel_request":
				_check(not traffic.cancel_request(String(active["request_id"])),
					"Cancellation reconciles direct endpoint change before acting on an obsolete request")
			"request_passage":
				var replacement: Dictionary = _request(fixture, "mutation-replacement", owner, 0, 0, 2)
				_check_request(replacement, &"granted", 1, "Fresh request reconciles the old endpoint before admission")
				_check(traffic.release(_token(replacement)), "Replacement on the live changed endpoint releases normally")
		_check(_state(traffic, active) == &"cancelled" and _state(traffic, queued) == &"cancelled",
			entrypoint + ": mutation entrypoint cancels both old traversal records")
		_check_totals(traffic, 0, 0, 0, entrypoint + ": direct-mutation reconciliation settles")
		_finish_case("direct_mutation_reconciled_by_" + entrypoint, fixture)


func _test_queries_before_refresh() -> void:
	for scenario: String in ["queued_owner", "queued_edge", "queued_endpoint", "external_endpoint_change"]:
		var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0), Vector2(240, 0)], [Vector2i(0, 1)])
		var traffic: NetworkTrafficSystem = fixture["traffic"]
		var nodes: Array[Node2D] = fixture["nodes"]
		var edges: Array[HyphaEdge] = fixture["edges"]
		var owner: Node = _new_owner(fixture, 1)
		var active: Dictionary = _request(fixture, scenario + "-active", owner, 0, 0, 1)
		var queued: Dictionary = _request(fixture, scenario + "-queued", _new_owner(fixture, 80, &"remains"), 0, 1, 0, &"remains")
		match scenario:
			"queued_owner":
				owner.queue_free()
			"queued_edge":
				edges[0].queue_free()
			"queued_endpoint":
				nodes[1].queue_free()
			"external_endpoint_change":
				edges[0].end_node = nodes[2]
		_exercise_pure_queries(fixture, active, queued, edges[0], nodes[0], nodes[1], scenario)
		_check(_state(traffic, active) == &"granted" and _state(traffic, queued) == &"queued",
			scenario + ": raw external mutation stays unreconciled through all query entrypoints")
		traffic.refresh()
		_check(_state(traffic, active) == &"cancelled" and traffic.get_lease(_token(active)).is_empty(),
			scenario + ": explicit refresh retires invalid occupancy")
		if scenario == "queued_owner":
			_check(_state(traffic, queued) == &"granted", "Explicit refresh grants retained head after queued owner cleanup")
		else:
			_check(_state(traffic, queued) == &"cancelled", scenario + ": explicit refresh also cancels invalid queued traversal")
			_check_totals(traffic, 0, 0, 0, scenario + ": reconciliation clears edge traffic")
		await process_frame
		await process_frame
		_finish_case("pure_queries_before_" + scenario + "_refresh", fixture)


func _test_wait_and_weighted_routes() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(60, 80), Vector2(120, 0)],
		[Vector2i(0, 2), Vector2i(0, 1), Vector2i(1, 2)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var network: NetworkSystem = fixture["network"]
	var router: TransportRouter = fixture["router"]
	var nodes: Array[Node2D] = fixture["nodes"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	var blocker: Dictionary = _request(fixture, "weighted-blocker", _new_owner(fixture, 1), 0, 0, 2)
	var head: Dictionary = _request(fixture, "weighted-head", _new_owner(fixture, 80, &"remains"), 0, 2, 0, &"remains")
	var before: Dictionary = traffic.get_snapshot()
	var counts: Array[int] = _signal_counts(fixture)
	var wait_seconds: float = traffic.estimate_wait_seconds(edges[0], 1, 60.0)
	_check(is_equal_approx(wait_seconds, 4.0), "Capacity two, occupied one, queued remains two, candidate one waits exactly two nominal traversals")
	_check(is_equal_approx(traffic.estimate_wait_seconds(edges[0], 2, 60.0), 4.0), "Two-unit candidate also follows the current FIFO batch model")
	_check(is_inf(traffic.estimate_wait_seconds(edges[0], 0, 60.0))
		and is_inf(traffic.estimate_wait_seconds(edges[0], 3, 60.0))
		and is_inf(traffic.estimate_wait_seconds(edges[0], 1, 0.0))
		and is_inf(traffic.estimate_wait_seconds(edges[0], 1, -1.0))
		and is_inf(traffic.estimate_wait_seconds(edges[0], 1, INF))
		and is_inf(traffic.estimate_wait_seconds(edges[0], 1, NAN)), "Invalid candidate units and nonfinite or nonpositive speed yield infinite wait")
	var result: Dictionary = router.find_route(nodes[0], nodes[2], &"supply", 60.0)
	_check_route(result, [edges[1], edges[2]], [nodes[0], nodes[1], nodes[2]], "Congestion-weighted detour")
	_check(is_equal_approx(float(result.get("total_distance", -1.0)), 200.0)
		and is_equal_approx(float(result.get("travel_seconds", -1.0)), 200.0 / 60.0)
		and is_equal_approx(float(result.get("estimated_wait_seconds", -1.0)), 0.0)
		and is_equal_approx(float(result.get("total_cost_seconds", -1.0)), 200.0 / 60.0)
		and int(result.get("units", -1)) == 1, "Router reports selected-path distance, travel, wait, total time, and units")
	_check_route(router.find_route(nodes[2], nodes[0], &"return", 60.0),
		[edges[2], edges[1]], [nodes[2], nodes[1], nodes[0]], "Reverse return uses shared congestion")
	var physical: NetworkRoute = network.find_route(nodes[0], nodes[2])
	_check(physical.found and physical.segments.size() == 1 and physical.segments[0].edge == edges[0],
		"Legacy BFS still chooses its physical direct edge regardless of traffic wait")
	_check(traffic.get_snapshot() == before and _signal_counts(fixture) == counts,
		"Wait estimation and weighted route finding do not reserve capacity or change queues")
	_check(_state(traffic, blocker) == &"granted" and _state(traffic, head) == &"queued", "Route selection never moves or settles existing requests")
	for speed: float in [0.0, -1.0, INF, NAN]:
		_check_no_route(router.find_route(nodes[0], nodes[2], &"supply", speed), "Invalid router speed")
	_check_no_route(router.find_route(nodes[0], nodes[2], &"unknown", 60.0), "Unknown router cargo kind")
	_check_no_route(router.find_route(null, nodes[2], &"supply", 60.0), "Null route endpoint")
	var missing: Node2D = Node2D.new()
	var container: Node = fixture["container"]
	container.add_child(missing)
	_check_no_route(router.find_route(missing, missing, &"supply", 60.0), "Unregistered same-node query")
	var same: Dictionary = router.find_route(nodes[1], nodes[1], &"remains", 60.0)
	_check_route(same, [], [nodes[1]], "Registered same-node zero-cost route")
	_check(float(same.get("total_distance", -1.0)) == 0.0 and float(same.get("travel_seconds", -1.0)) == 0.0
		and float(same.get("estimated_wait_seconds", -1.0)) == 0.0
		and float(same.get("total_cost_seconds", -1.0)) == 0.0, "Same-node route has zero distance and every time cost")
	var other_network: NetworkSystem = NetworkSystem.new()
	container.add_child(other_network)
	router.network_system = other_network
	_check_no_route(router.find_route(nodes[0], nodes[2]), "Router rejects scheduler and network configuration mismatch")
	router.network_system = network
	router.traffic_system = null
	_check_no_route(router.find_route(nodes[0], nodes[2]), "Router rejects missing scheduler configuration")
	router.traffic_system = traffic
	edges[0].entry_enabled = false
	edges[1].traffic_capacity = 1
	edges[2].traffic_capacity = 1
	traffic.refresh()
	_check_no_route(router.find_route(nodes[0], nodes[2], &"remains", 60.0), "Remains cannot use closed or capacity-one edges")
	_check_route(router.find_route(nodes[0], nodes[2], &"return", 60.0),
		[edges[1], edges[2]], [nodes[0], nodes[1], nodes[2]], "Small return still uses capacity-one detour")
	_finish_case("nominal_fifo_wait_and_weighted_pure_routes", fixture,
		{"nominal_traversal_seconds": 2.0, "candidate_wait_seconds": wait_seconds,
		"selected_distance": 200.0, "wait_model_uses_actual_progress": false})


func _test_stable_ties_and_zero_length_cycles() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(100, 0), Vector2(100, 0), Vector2(200, 0)],
		[Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2), Vector2i(1, 2), Vector2i(1, 3), Vector2i(2, 3)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var network: NetworkSystem = fixture["network"]
	var router: TransportRouter = fixture["router"]
	var nodes: Array[Node2D] = fixture["nodes"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	var before: Dictionary = traffic.get_snapshot()
	var counts: Array[int] = _signal_counts(fixture)
	_check(edges[0].get_length() == 0.0 and edges[3].get_length() == 0.0,
		"Real self-loop and cross-edge fixtures have zero physical lengths")
	_check(traffic.estimate_wait_seconds(edges[3], 1, 60.0) == 0.0, "Valid zero-length edge has finite zero nominal wait")
	for repeat: int in range(10):
		_check_route(router.find_route(nodes[0], nodes[3], &"supply", 100.0),
			[edges[1], edges[4]], [nodes[0], nodes[1], nodes[3]], "Stable exact-cost tie %d" % repeat)
	_check_route(router.find_route(nodes[3], nodes[0], &"return", 100.0),
		[edges[4], edges[1]], [nodes[3], nodes[1], nodes[0]], "Reverse stable tie through a zero-cost cycle")
	_check(traffic.get_snapshot() == before and _signal_counts(fixture) == counts,
		"Repeated equal-cost and zero-cycle route queries remain observational")
	network.unregister_edge(edges[1])
	_check(network.register_edge(edges[1]), "Tie fixture re-registers its first branch at the end")
	_check_route(router.find_route(nodes[0], nodes[3], &"supply", 100.0),
		[edges[2], edges[5]], [nodes[0], nodes[2], nodes[3]], "Changed registration order selects the first newly discovered exact-cost tie")
	_finish_case("registration_order_ties_and_zero_cost_cycles", fixture,
		{"repeated_queries": 10, "zero_length_edges": 2, "all_routes_simple": true})


func _test_reentrant_settlement() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var owner: Node = _new_owner(fixture, 10, &"return")
	var callback: Dictionary = {"armed": true, "first_id": "", "first_token": "", "replacement": {}}
	traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(callback["armed"]) and snapshot.get("state") == &"granted":
			callback["armed"] = false
			callback["first_id"] = String(snapshot["request_id"])
			callback["first_token"] = _token(snapshot)
			var live: Dictionary = traffic.get_request(String(snapshot["request_id"]))
			var lease: Dictionary = traffic.get_lease(_token(snapshot))
			_check(live.get("state") == &"granted" and lease.get("request_id") == snapshot.get("request_id"),
				"Granted notification observes committed request and active lease")
			_check(traffic.cancel_request(String(snapshot["request_id"])), "Granted callback can reentrantly cancel its request")
			_check(not traffic.release(_token(snapshot)), "Reentrant cancellation retires the grant token immediately")
			callback["replacement"] = _request(fixture, "reentrant-replacement", owner, 0, 1, 0, &"return"))
	_request(fixture, "reentrant-first", owner, 0, 0, 1, &"return")
	var replacement: Dictionary = callback["replacement"]
	_check_request(replacement, &"granted", 1, "Fresh request from a reentrant cancellation callback")
	_check(traffic.get_request(String(callback["first_id"])).get("state") == &"cancelled"
		and traffic.get_lease(String(callback["first_token"])).is_empty(), "Original reentrant grant cannot leak a stale active lease")
	_check_totals(traffic, 1, 0, 1, "Only replacement owns capacity after reentrant cancellation")
	_check(traffic.release(_token(replacement)), "Reentrant replacement releases normally")
	_check_totals(traffic, 0, 0, 0, "Reentrant settlement case finishes")
	_finish_case("committed_signals_and_reentrant_cancel_request", fixture)


func _test_reentrant_reset_during_drain() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0)], [Vector2i(0, 1)])
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var edges: Array[HyphaEdge] = fixture["edges"]
	edges[0].entry_enabled = false
	var first: Dictionary = _request(fixture, "reentrant-reset-first", _new_owner(fixture, 1), 0, 0, 1)
	var second: Dictionary = _request(fixture, "reentrant-reset-second", _new_owner(fixture, 10, &"return"), 0, 1, 0, &"return")
	_check_request(first, &"queued", 1, "First closed-edge reset fixture")
	_check_request(second, &"queued", 1, "Second closed-edge reset fixture")
	var old_generation: int = traffic.get_generation()
	var callback: Dictionary = {"reset": false, "old_grants": 0, "tokens": []}
	traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot.get("state") == &"granted" and int(snapshot.get("generation", -1)) == old_generation:
			callback["old_grants"] = int(callback["old_grants"]) + 1
			_check(not bool(callback["reset"]), "Drain must not emit another old-generation grant after a reentrant reset")
			if not bool(callback["reset"]):
				_check(not traffic.get_lease(_token(snapshot)).is_empty(), "Drain grant commits before the reset callback")
				var edge_snapshot: Dictionary = traffic.get_edge_snapshot(edges[0])
				var tokens: Array = callback["tokens"]
				for lease: Dictionary in edge_snapshot.get("leases", []):
					tokens.append(_token(lease))
				callback["reset"] = true
				traffic.reset())
	edges[0].entry_enabled = true
	traffic.refresh()
	_check(bool(callback["reset"]) and int(callback["old_grants"]) == 1
		and traffic.get_generation() > old_generation, "First reopened grant resets the generation and suppresses pending stale grants")
	_check(traffic.get_request(String(first["request_id"])).is_empty()
		and traffic.get_request(String(second["request_id"])).is_empty(), "Reentrant reset clears both original queued identities")
	for token: String in callback["tokens"]:
		_check(traffic.get_lease(token).is_empty() and not traffic.release(token), "Every pre-reset drain token is inert")
	_check_totals(traffic, 0, 0, 0, "Reentrant reset leaves no stale drain occupancy")
	_finish_case("reentrant_reset_suppresses_pending_grants", fixture,
		{"old_generation": old_generation, "new_generation": traffic.get_generation(), "old_grants": callback["old_grants"]})


func _test_ring_boundary_model() -> void:
	var fixture: Dictionary = _new_fixture([Vector2.ZERO, Vector2(120, 0), Vector2(60, 100)],
		[Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 0)], 1)
	var traffic: NetworkTrafficSystem = fixture["traffic"]
	var nodes: Array[Node2D] = fixture["nodes"]
	var owners: Array[Node] = [
		_new_owner(fixture, 1), _new_owner(fixture, 10, &"return"), _new_owner(fixture, 1),
	]
	var kinds: Array[StringName] = [&"supply", &"return", &"supply"]
	var first_hops: Array[Dictionary] = []
	for index: int in range(3):
		owners[index].set_meta(&"modeled_node", nodes[index])
		var first: Dictionary = _request(fixture, "ring-owner-%d-hop-1" % index, owners[index], index,
			index, (index + 1) % 3, kinds[index], "ring-task-%d" % index)
		first_hops.append(first)
		_check_request(first, &"granted", 1, "Ring initial modeled hop %d" % index)
	for index: int in range(3):
		var next_edge: int = (index + 1) % 3
		_check_rejected(_request(fixture, "ring-owner-%d-premature-hop-2" % index, owners[index], next_edge,
			next_edge, (index + 2) % 3, kinds[index], "ring-task-%d" % index),
			"Ring owner %d cannot queue or acquire another edge while holding its current lease" % index)
	_check_totals(traffic, 3, 0, 3, "Full ring retains one lease per owner and no multi-edge wait cycle")
	var next_hops: Array[Dictionary] = []
	var boundary_states: Array[String] = []
	for index: int in range(3):
		var next_node: int = (index + 1) % 3
		_check(traffic.release(_token(first_hops[index])), "Ring owner %d releases at its modeled next-node boundary" % index)
		owners[index].set_meta(&"modeled_node", nodes[next_node])
		var next: Dictionary = _request(fixture, "ring-owner-%d-hop-2" % index, owners[index], next_node,
			next_node, (index + 2) % 3, kinds[index], "ring-task-%d" % index)
		next_hops.append(next)
		boundary_states.append(String(next.get("state", &"")))
		_check(bool(next.get("accepted", false)) and next.get("from_node") == owners[index].get_meta(&"modeled_node"),
			"Ring owner %d anchors its fresh request at the modeled registered endpoint" % index)
		_check(_state(traffic, first_hops[index]) == &"released" and traffic.get_lease(_token(first_hops[index])).is_empty(),
			"Ring owner %d never retains its earlier edge while queued or granted on the next" % index)
	_check(boundary_states == ["queued", "queued", "granted"], "Sequential boundary releases break the modeled ring contention")
	for index: int in range(3):
		var live: Dictionary = traffic.get_request(String(next_hops[index]["request_id"]))
		_check_request(live, &"granted", 1, "Ring next modeled hop %d progresses" % index)
		_check(traffic.release(_token(live)), "Ring next modeled hop %d releases once" % index)
	_check(int(owners[1].get_meta(&"nutrition")) == 10, "Modeled ring return remains ten nutrition with one occupancy unit")
	_check_totals(traffic, 0, 0, 0, "Modeled ring finishes without retained capacity")
	_finish_case("ring_release_before_next_hop_model", fixture,
		{"model_only": true, "packet_integration": false, "boundary_states": boundary_states,
		"boundary": "logical_registered_node", "return_nutrition": 10, "return_units": 1})


func _free_fixtures() -> void:
	for reference: WeakRef in _fixtures:
		var container: Node = reference.get_ref() as Node
		if is_instance_valid(container):
			container.free()
	_fixtures.clear()
