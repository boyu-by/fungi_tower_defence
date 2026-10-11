extends SceneTree
## 候选由真实运输生成；显式确认仅隔离两阶段契约，不替代业务验收或消耗。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const KINDS: Array[StringName] = [&"supply", &"return", &"remains"]
const CARGO_FIELDS: Array[String] = [
	"cargo_id", "kind", "generation", "status", "candidate_edge_ids",
	"confirmed_edge_ids", "candidate_count", "confirmed_count",
]

class Fixture:
	extends RefCounted

	var host: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var tracker: CargoPassageTracker
	var nodes: Array[Node2D] = []
	var edges: Array[HyphaEdge] = []
	var events: Array[Dictionary] = []

class Outcome:
	extends RefCounted

	var arrivals: int = 0
	var interruptions: int = 0
	var valid_arrival: bool = false
	var target: Node2D
	var task_id: String = ""
	var terminal: Dictionary = {}

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_registration_and_binding()
	_test_real_two_phase_and_sealing()
	_test_waiting_partial_cancel_and_discard()
	_test_zero_routes_and_ground_pickup()
	_test_attempt_and_direction_dedupe()
	_test_reroute_and_blocked_resume()
	_test_growth_endpoint_handoff()
	_test_release_observer_order()
	_test_recorded_edge_geometry_changes()
	_test_weak_edges_and_notification_deletion()
	_test_generation_and_tracker_lifetime()
	_test_reentrant_confirmation_and_reset()
	_check(root.get_child_count() == initial_children, "All cargo fixtures were freed")
	print("CARGO_PASSAGE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
		"candidate_source": "real_packet_movement",
		"confirmation_scope": "unit_two_phase_contract",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture(points: PackedVector2Array, capacity: int = 2,
		growth_nodes: bool = false) -> Fixture:
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
		_check(fixture.network.register_node(node, index == 0), "Cargo fixture node registered")
	for index: int in range(points.size() - 1):
		var first: Node2D = fixture.nodes[index] if index % 2 == 0 else fixture.nodes[index + 1]
		var last: Node2D = fixture.nodes[index + 1] if index % 2 == 0 else fixture.nodes[index]
		fixture.edges.append(_edge(fixture, first, last, capacity))
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.host.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.tracker = CargoPassageTracker.new()
	fixture.host.add_child(fixture.tracker)
	fixture.tracker.passage_confirmed.connect(
		func(cargo_id: String, edge: HyphaEdge, generation: int) -> void:
			fixture.events.append({
				"cargo_id": cargo_id, "edge_id": edge.get_instance_id(), "generation": generation,
			})
	)
	return fixture


func _edge(fixture: Fixture, first: Node2D, last: Node2D, capacity: int = 2) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate()
	edge.start_node = first
	edge.end_node = last
	edge.traffic_capacity = capacity
	fixture.host.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Cargo fixture edge registered")
	return edge


func _node(fixture: Fixture, point: Vector2) -> Node2D:
	var node: Node2D = Node2D.new()
	fixture.host.add_child(node)
	node.global_position = point
	_check(fixture.network.register_node(node), "Cargo bypass node registered")
	return node


func _packet(fixture: Fixture, kind: StringName, outcome: Outcome,
		cargo_id: String = "", point: Vector2 = Vector2.ZERO) -> Variant:
	var packet: Variant = RemainsPacket.new() if kind == &"remains" else NutrientPacket.new()
	packet.speed = 100.0
	packet.traffic_required = true
	if not cargo_id.is_empty():
		var generation: int = fixture.tracker.register_cargo(cargo_id, kind)
		_check(generation == fixture.tracker.get_generation(), "Cargo identity is current")
		_check(packet.bind_cargo(fixture.tracker, cargo_id, generation), "Packet binds before add_child")
	fixture.host.add_child(packet)
	packet.global_position = point
	packet.set_physics_process(false)
	packet.arrived.connect(func(delivered: Variant) -> void:
		outcome.arrivals += 1
		outcome.valid_arrival = delivered.has_arrived_at(outcome.target, outcome.task_id)
		outcome.terminal = delivered.get_transport_snapshot()
	)
	packet.interrupted.connect(func(stopped: Variant) -> void:
		outcome.interruptions += 1
		outcome.terminal = stopped.get_transport_snapshot()
	)
	return packet


func _start(packet: Variant, fixture: Fixture, kind: StringName, outcome: Outcome,
		first: Node2D = null, last: Node2D = null, task_id: String = "") -> void:
	var source: Node2D = first if first != null else fixture.nodes[0]
	var target: Node2D = last if last != null else fixture.nodes[-1]
	var route: NetworkRoute = fixture.network.find_route(source, target)
	_start_route(packet, fixture, kind, outcome, route, task_id)


func _start_route(packet: Variant, fixture: Fixture, kind: StringName, outcome: Outcome,
		route: NetworkRoute, task_id: String = "") -> void:
	outcome.target = route.end_node
	outcome.task_id = task_id if not task_id.is_empty() else "cargo-attempt:%d" % packet.get_instance_id()
	if kind == &"remains":
		packet.start_route(route, fixture.network, fixture.traffic, outcome.task_id)
	else:
		packet.start_route(route, fixture.network, fixture.traffic, outcome.task_id, kind)


func _step(packet: Variant, delta: float) -> void:
	if is_instance_valid(packet):
		packet._physics_process(delta)


func _counts(tracker: CargoPassageTracker, cargo_id: String, candidates: int,
		confirmed: int, status: StringName, context: String) -> void:
	var snapshot: Dictionary = tracker.get_cargo_snapshot(cargo_id)
	for field: String in CARGO_FIELDS:
		_check(snapshot.has(field), context + ": field " + field)
	_check(snapshot.get("candidate_count", -1) == candidates
		and snapshot.get("confirmed_count", -1) == confirmed
		and snapshot.get("status", &"") == status, context + ": candidate/confirmed/status")


func _arrived(outcome: Outcome, context: String) -> void:
	_check(outcome.arrivals == 1 and outcome.interruptions == 0 and outcome.valid_arrival,
		context + ": one real arrival")


func _empty_traffic(fixture: Fixture, context: String) -> void:
	var snapshot: Dictionary = fixture.traffic.get_snapshot()
	_check(snapshot["occupied_units"] == 0 and snapshot["queued_count"] == 0
		and snapshot["active_request_count"] == 0, context + ": no traffic handles remain")


func _destroy(fixture: Fixture) -> void:
	fixture.host.free()


func _test_registration_and_binding() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
	var tracker: CargoPassageTracker = fixture.tracker
	var generation: int = tracker.get_generation()
	_check(generation >= 1, "Initial cargo generation is positive")
	_check(tracker.register_cargo("") == -1 and tracker.register_cargo("  ") == -1,
		"Empty business identities are rejected")
	_check(tracker.register_cargo("paid-lot", &"growth") == generation
		and tracker.register_cargo("paid-lot", &"growth") == generation,
		"Registration is idempotent for the same kind")
	_check(tracker.register_cargo("paid-lot", &"repair") == -1,
		"An existing identity cannot be hijacked by another kind")
	_check(not tracker.confirm_cargo("unknown", generation)
		and not tracker.discard_cargo("unknown", generation)
		and not tracker.record_candidate("unknown", fixture.edges[0], generation),
		"Unknown identities cannot create or confirm history")
	_check(not tracker.record_candidate("paid-lot", null, generation),
		"Invalid edges cannot be recorded")
	for kind: StringName in KINDS:
		var packet: Variant = RemainsPacket.new() if kind == &"remains" else NutrientPacket.new()
		_check(not packet.bind_cargo(null, "paid-lot", generation)
			and not packet.bind_cargo(tracker, "unknown", generation)
			and not packet.bind_cargo(tracker, "paid-lot", generation - 1),
			"Binding rejects null, unknown and old generations " + String(kind))
		_check(packet.bind_cargo(tracker, "paid-lot", generation)
			and packet.bind_cargo(tracker, "paid-lot", generation),
			"Identical prestart binding is harmless " + String(kind))
		var other: String = "other:" + String(kind)
		tracker.register_cargo(other, kind)
		_check(not packet.bind_cargo(tracker, other, generation),
			"Mismatched prestart cargo rebinding is rejected")
		var other_tracker: CargoPassageTracker = CargoPassageTracker.new()
		other_tracker.register_cargo("paid-lot", &"growth")
		_check(not packet.bind_cargo(other_tracker, "paid-lot", generation),
			"A second source cannot replace the captured tracker")
		other_tracker.free()
		var outcome: Outcome = Outcome.new()
		packet.arrived.connect(func(delivered: Variant) -> void:
			outcome.arrivals += 1
			outcome.valid_arrival = delivered.has_arrived_at(outcome.target, outcome.task_id)
			outcome.terminal = delivered.get_transport_snapshot()
		)
		packet.interrupted.connect(func(stopped: Variant) -> void:
			outcome.interruptions += 1
			outcome.terminal = stopped.get_transport_snapshot()
		)
		fixture.host.add_child(packet)
		packet.set_physics_process(false)
		_start(packet, fixture, kind, outcome)
		_check(not packet.bind_cargo(tracker, "paid-lot", generation),
			"Even identical binding after start is rejected")
		packet.cancel_transport()
		_check(outcome.interruptions == 1, "Binding never suppresses ordinary cancellation")
	_counts(tracker, "paid-lot", 0, 0, &"pending", "Cancellation does not settle cargo")
	_check(tracker.confirm_cargo("paid-lot", generation), "Accepted empty cargo can be confirmed")
	_check(tracker.register_cargo("paid-lot", &"growth") == generation
		and not tracker.confirm_cargo("paid-lot", generation)
		and not tracker.discard_cargo("paid-lot", generation),
		"Confirmed identity remains sealed and cannot be revoked")
	tracker.register_cargo("refund", &"supply")
	_check(tracker.discard_cargo("refund", generation)
		and not tracker.discard_cargo("refund", generation)
		and tracker.register_cargo("refund", &"supply") == -1,
		"Discarded payment identity cannot be reopened")
	_check(fixture.events.is_empty(), "Empty confirmations emit no passage")
	for kind: StringName in KINDS:
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome)
		_check(packet.get_transport_snapshot()["cargo_id"] == ""
			and packet.get_transport_snapshot()["cargo_generation"] == -1,
			"Legacy opt-out has no implicit transport-task cargo identity")
		_start(packet, fixture, kind, outcome)
		_step(packet, 1.0)
		_arrived(outcome, "Legacy " + String(kind))
	_check(tracker.get_snapshot()["candidate_passage_count"] == 0,
		"Unbound real transport leaves cargo history untouched")
	_empty_traffic(fixture, "Registration/binding")
	evidence.append({"case": "registration_binding_legacy", "packet_kinds": 3, "passages": 0})
	_destroy(fixture)


func _test_real_two_phase_and_sealing() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
		]))
		var cargo_id: String = "two-phase:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		var late_outcome: Outcome = Outcome.new()
		var late_packet: Variant = _packet(
			fixture, kind, late_outcome, cargo_id, fixture.nodes[-1].global_position)
		var extra_node: Node2D = _node(fixture, Vector2(300.0, 0.0))
		var extra_edge: HyphaEdge = _edge(fixture, fixture.nodes[-1], extra_node)
		var generation: int = fixture.tracker.get_generation()
		_start(packet, fixture, kind, outcome)
		_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Admission alone")
		_step(packet, 1.5)
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "First full edge plus partial next")
		_check(fixture.events.is_empty(), "Candidate does not notify observers")
		_step(packet, 0.5)
		_arrived(outcome, "Two-phase " + String(kind))
		_counts(fixture.tracker, cargo_id, 2, 0, &"pending", "Arrival alone leaves candidates pending")
		_check(outcome.terminal["cargo_id"] == cargo_id
			and outcome.terminal["cargo_generation"] == generation,
			"Transport snapshot retains captured business identity")
		fixture.tracker.passage_confirmed.connect(
			func(event_id: String, edge: HyphaEdge, event_generation: int) -> void:
				_check(event_id == cargo_id and event_generation == generation
					and fixture.tracker.has_confirmed_passage(event_id, edge, event_generation),
					"Each notification is backed by authoritative confirmation")
				_check(fixture.tracker.get_cargo_snapshot(cargo_id)["confirmed_count"] == 2,
					"All candidates are atomically confirmed before the first notification")
		)
		_check(fixture.tracker.confirm_cargo(cargo_id, generation), "Unit acceptance seals the cargo")
		_counts(fixture.tracker, cargo_id, 2, 2, &"confirmed", "Accepted two-edge cargo")
		_check(fixture.events.size() == 2
			and not fixture.tracker.confirm_cargo(cargo_id, generation),
			"Repeated confirmation does not replay notifications")
		var snapshot: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
		snapshot["candidate_edge_ids"].clear()
		snapshot["confirmed_edge_ids"].clear()
		snapshot["status"] = &"pending"
		var rows: Array[Dictionary] = fixture.tracker.get_confirmed_passages()
		_check(rows.size() == 2 and rows[0]["edge_ref"] is WeakRef,
			"Late observers receive live weak confirmation rows")
		rows[0]["cargo_id"] = "forged"
		rows[0]["edge_id"] = 0
		rows.clear()
		var aggregate: Dictionary = fixture.tracker.get_snapshot()
		aggregate["cargos"].clear()
		_counts(fixture.tracker, cargo_id, 2, 2, &"confirmed", "Public queries are copies")
		_start(late_packet, fixture, kind, late_outcome, fixture.nodes[-1], extra_node)
		_step(late_packet, 1.0)
		_arrived(late_outcome, "Already bound later attempt")
		_check(not fixture.tracker.has_confirmed_passage(cargo_id, extra_edge, generation),
			"Traversal after sealing cannot append a new effective edge")
		_counts(fixture.tracker, cargo_id, 2, 2, &"confirmed", "Sealed candidate set stays fixed")
		_empty_traffic(fixture, "Two-phase sealing")
		evidence.append({"case": "two_phase_sealed", "kind": kind, "candidates": 2, "signals": 2})
		_destroy(fixture)


func _test_waiting_partial_cancel_and_discard() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
		]))
		var holder_outcome: Outcome = Outcome.new()
		var holder: Variant = _packet(fixture, &"remains", holder_outcome)
		_start(holder, fixture, &"remains", holder_outcome, fixture.nodes[0], fixture.nodes[1])
		var cargo_id: String = "queued:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		_start(packet, fixture, kind, outcome)
		_step(packet, 20.0)
		_check(packet.get_transport_snapshot()["state"] == &"waiting",
			"Real queued packet cannot advance before admission")
		_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Queued waiting")
		packet.cancel_transport()
		holder.cancel_transport()
		_check(outcome.interruptions == 1 and fixture.events.is_empty(),
			"Queued cancellation publishes no candidate or confirmation")
		var partial_id: String = "partial:" + String(kind)
		var partial_outcome: Outcome = Outcome.new()
		var partial: Variant = _packet(fixture, kind, partial_outcome, partial_id)
		_start(partial, fixture, kind, partial_outcome)
		_step(partial, 0.5)
		_counts(fixture.tracker, partial_id, 0, 0, &"pending", "Partial edge movement")
		partial.cancel_transport()
		_counts(fixture.tracker, partial_id, 0, 0, &"pending", "Partial cancellation")
		var refund_id: String = "full-then-refund:" + String(kind)
		var refund_outcome: Outcome = Outcome.new()
		var refund: Variant = _packet(fixture, kind, refund_outcome, refund_id)
		_start(refund, fixture, kind, refund_outcome)
		_step(refund, 1.5)
		refund.cancel_transport()
		_counts(fixture.tracker, refund_id, 1, 0, &"pending", "Completed prefix survives attempt cancellation")
		var generation: int = fixture.tracker.get_generation()
		_check(fixture.tracker.discard_cargo(refund_id, generation), "Actual refund can discard an unconfirmed lot")
		_counts(fixture.tracker, refund_id, 0, 0, &"discarded", "Refund clears candidates")
		_check(not fixture.tracker.confirm_cargo(refund_id, generation)
			and fixture.events.is_empty(), "Refunded passage never becomes effective")
		var new_id: String = "new-payment:" + String(kind)
		var new_outcome: Outcome = Outcome.new()
		var new_packet: Variant = _packet(fixture, kind, new_outcome, new_id)
		_start(new_packet, fixture, kind, new_outcome)
		_step(new_packet, 2.0)
		_arrived(new_outcome, "New identity after refund")
		_check(fixture.tracker.confirm_cargo(new_id, generation) and fixture.events.size() == 2,
			"A genuinely new identity can confirm its own real traversal")
		_empty_traffic(fixture, "Queue/partial/refund")
		evidence.append({"case": "queued_partial_refund", "kind": kind, "refunded_signals": 0})
		_destroy(fixture)


func _test_zero_routes_and_ground_pickup() -> void:
	for kind: StringName in KINDS:
		for point_count: int in [1, 3]:
			var points: PackedVector2Array = PackedVector2Array()
			for index: int in range(point_count):
				points.append(Vector2.ZERO)
			var fixture: Fixture = _fixture(points)
			var outcome: Outcome = Outcome.new()
			var cargo_id: String = "zero:" + String(kind)
			var pickup_point: Vector2 = Vector2(-30.0, 0.0) if kind == &"remains" else Vector2.ZERO
			var packet: Variant = _packet(fixture, kind, outcome, cargo_id, pickup_point)
			_start(packet, fixture, kind, outcome)
			if kind == &"remains":
				_step(packet, 0.15)
				_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Ground pickup partial movement")
				_step(packet, 0.15)
			_arrived(outcome, "Zero-length route " + String(kind))
			_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Zero-length completion")
			_check(fixture.tracker.confirm_cargo(cargo_id, fixture.tracker.get_generation())
				and fixture.events.is_empty(), "Accepted zero-length cargo grows no edge")
			_empty_traffic(fixture, "Zero route")
			_destroy(fixture)
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2.ZERO, Vector2(100.0, 0.0), Vector2(100.0, 0.0),
		]))
		var outcome: Outcome = Outcome.new()
		var cargo_id: String = "mixed-zero:" + String(kind)
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		_start(packet, fixture, kind, outcome)
		_step(packet, 1.0)
		_arrived(outcome, "Mixed zero chain")
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Only nonzero completed edge is a candidate")
		_check(fixture.tracker.get_cargo_snapshot(cargo_id)["candidate_edge_ids"]
			== [fixture.edges[1].get_instance_id()], "Zero hops are excluded by edge identity")
		_destroy(fixture)
	evidence.append({"case": "zero_and_ground", "zero_route_sizes": [0, 2], "nonzero_mixed_candidates": 1})


func _test_attempt_and_direction_dedupe() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
		]))
		var cargo_id: String = "stable-original:" + String(kind)
		for attempt: int in range(3):
			var forward: bool = attempt % 2 == 0
			var first: Node2D = fixture.nodes[0] if forward else fixture.nodes[-1]
			var last: Node2D = fixture.nodes[-1] if forward else fixture.nodes[0]
			var outcome: Outcome = Outcome.new()
			var packet: Variant = _packet(fixture, kind, outcome, cargo_id, first.global_position)
			_start(packet, fixture, kind, outcome, first, last, "different-attempt:%d" % attempt)
			_step(packet, 2.0)
			_arrived(outcome, "Stable cargo retry")
			_counts(fixture.tracker, cargo_id, 2, 0, &"pending", "Repeated/reverse traversal is a set union")
			_check(outcome.terminal["task_id"] != cargo_id
				and outcome.terminal["cargo_id"] == cargo_id,
				"Attempt task identity does not replace the business identity")
		_check(fixture.events.is_empty(), "All failed/unaccepted attempts still have no confirmation")
		var generation: int = fixture.tracker.get_generation()
		_check(fixture.tracker.confirm_cargo(cargo_id, generation) and fixture.events.size() == 2,
			"Repeated and opposite passage confirms one cargo-edge pair each")
		for edge: HyphaEdge in fixture.edges:
			_check(fixture.tracker.has_confirmed_passage(cargo_id, edge, generation),
				"Both physical edges have exactly one confirmed pair")
		_check(fixture.tracker.get_snapshot()["confirmed_count"] == 1
			and fixture.tracker.get_snapshot()["confirmed_passage_count"] == 2,
			"Business count is neither nutrition amount nor cargo traffic units")
		_empty_traffic(fixture, "Stable retry")
		_destroy(fixture)
	evidence.append({"case": "attempt_direction_dedupe", "attempts_per_kind": 3,
		"confirmed_cargos_per_kind": 1, "confirmed_edges_per_kind": 2})


func _test_reroute_and_blocked_resume() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
		]))
		var bypass: Node2D = _node(fixture, Vector2(100.0, 100.0))
		var first_bypass: HyphaEdge = _edge(fixture, fixture.nodes[1], bypass)
		var last_bypass: HyphaEdge = _edge(fixture, bypass, fixture.nodes[2])
		var cargo_id: String = "rerouted:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		_start(packet, fixture, kind, outcome)
		_step(packet, 0.25)
		fixture.edges[1].entry_enabled = false
		_step(packet, 0.75)
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Original completed prefix before reroute")
		_step(packet, 3.0)
		_arrived(outcome, "Real reroute")
		var candidate_ids: Array = fixture.tracker.get_cargo_snapshot(cargo_id)["candidate_edge_ids"]
		_check(candidate_ids.size() == 3 and candidate_ids.has(fixture.edges[0].get_instance_id())
			and candidate_ids.has(first_bypass.get_instance_id())
			and candidate_ids.has(last_bypass.get_instance_id())
			and not candidate_ids.has(fixture.edges[1].get_instance_id()),
			"Reroute records completed real bypass edges and excludes abandoned edge")
		_check(outcome.terminal["reroute_count"] == 1 and fixture.events.is_empty(),
			"Reroute preserves original outcome and remains unconfirmed")
		_empty_traffic(fixture, "Reroute")
		_destroy(fixture)
		fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		cargo_id = "blocked:" + String(kind)
		outcome = Outcome.new()
		packet = _packet(fixture, kind, outcome, cargo_id)
		_start(packet, fixture, kind, outcome)
		_step(packet, 0.5)
		var before: Dictionary = packet.get_transport_snapshot()
		fixture.edges[0].entry_enabled = false
		_step(packet, 10.0)
		var blocked: Dictionary = packet.get_transport_snapshot()
		_check(blocked["state"] == &"blocked" and blocked["token"] == before["token"]
			and blocked["position"] == before["position"]
			and blocked["progress"] == before["progress"], "Blocked edge preserves lease and frozen position")
		_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Blocked partial edge")
		fixture.edges[0].entry_enabled = true
		_step(packet, 0.0)
		_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Reopening without distance")
		_step(packet, 0.5)
		_arrived(outcome, "Blocked real resume")
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Only resumed full traversal counts")
		_empty_traffic(fixture, "Blocked resume")
		_destroy(fixture)
	evidence.append({"case": "reroute_blocked_resume", "bypass_candidates": 3, "blocked_candidates": 0})


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
		_check(task_id > 0, "Handoff fixture creates a real growth task")
		var tip: Node2D = growth.get_delivery_target(task_id)
		_check(tip is GrowthTip, "Handoff target is a real GrowthTip")
		_check(growth.receive_nutrition(task_id, 9751, growth.get_requested_nutrition(task_id)),
			"Handoff fixture pays the first extension")
		growth.advance(0.5)
		var route: NetworkRoute = fixture.network.find_route(fixture.nodes[0], tip)
		var original_edge: HyphaEdge = route.segments[0].edge
		original_edge.traffic_capacity = 2
		var cargo_id: String = "handoff:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		packet.speed = 10.0
		_start_route(packet, fixture, kind, outcome, route)
		_step(packet, 0.5)
		var before: Dictionary = packet.get_transport_snapshot()
		original_edge.entry_enabled = false
		_step(packet, 1.0)
		growth.advance(100.0)
		_check(growth.receive_nutrition(task_id, 9752, growth.get_requested_nutrition(task_id)),
			"Handoff fixture pays junction formation")
		growth.advance(0.01)
		var junction: Node2D = original_edge.end_node
		_check(junction is HyphaNode and junction != tip
			and fixture.network.get_growth_handoff(original_edge, tip.get_instance_id()) == junction,
			"Legal handoff changes the real edge endpoint")
		var lease: Dictionary = fixture.traffic.get_lease(before["token"])
		_check(lease.get("to_node") == junction and lease.get("request_id") == before["request_id"],
			"Legal handoff retains the original lease identity")
		_check(growth.receive_nutrition(task_id, 9753, growth.get_requested_nutrition(task_id)),
			"Handoff fixture pays the next extension")
		growth.advance(0.5)
		var onward: NetworkRoute = fixture.network.find_route(junction, tip)
		onward.segments[0].edge.traffic_capacity = 2
		_step(packet, 10.0)
		_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Handoff while blocked is no traversal")
		_check(packet.get_transport_snapshot()["position"] == before["position"],
			"Blocked handoff freezes the world position")
		original_edge.entry_enabled = true
		_step(packet, 0.0)
		var distance_to_junction: float = packet.global_position.distance_to(junction.global_position)
		_step(packet, distance_to_junction / 10.0 + 0.2)
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Original real edge completed after handoff")
		_check(fixture.tracker.get_cargo_snapshot(cargo_id)["candidate_edge_ids"]
			== [original_edge.get_instance_id()], "Handoff preserves the edge's physical cargo identity")
		_step(packet, 10.0)
		_arrived(outcome, "Real growth endpoint handoff")
		_counts(fixture.tracker, cargo_id, 2, 0, &"pending", "Onward real edge completed")
		_empty_traffic(fixture, "Handoff")
		_destroy(fixture)
	evidence.append({"case": "legal_growth_handoff", "packet_kinds": 3, "candidates_after_real_motion": 2})


func _test_release_observer_order() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
		]))
		var cargo_id: String = "release-order:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		var release_snapshots: Array[Dictionary] = []
		fixture.traffic.request_changed.connect(func(request: Dictionary) -> void:
			if request["owner_id"] == packet.get_instance_id() and request["state"] == &"released":
				var snapshot: Dictionary = packet.get_transport_snapshot()
				var cargo: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
				release_snapshots.append(snapshot)
				_check(snapshot["location_kind"] == &"node"
					and snapshot["state"] in [&"waiting", &"completed"],
					"Release observer sees already committed packet location/state")
				_check(cargo["candidate_count"] == snapshot["completed_segments"]
					and cargo["confirmed_count"] == 0 and fixture.events.is_empty(),
					"Candidate is committed before the lease release notification")
				_step(packet, 100.0)
		)
		_start(packet, fixture, kind, outcome)
		_step(packet, 2.0)
		_arrived(outcome, "Release observer reentry")
		_check(release_snapshots.size() == 2, "Each real edge releases one lease")
		_counts(fixture.tracker, cargo_id, 2, 0, &"pending", "Release is not business confirmation")
		_empty_traffic(fixture, "Release order")
		_destroy(fixture)
	evidence.append({"case": "release_order", "candidate_before_release": true, "confirmation_on_release": false})


func _test_recorded_edge_geometry_changes() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
		]))
		var cargo_id: String = "historical-edge:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		_start(packet, fixture, kind, outcome)
		_step(packet, 1.5)
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Full prefix before endpoint loss")
		var connection: HyphaEdge = fixture.edges[0]
		var original_start: Node2D = connection.start_node
		var original_end: Node2D = connection.end_node
		var edge_id: int = connection.get_instance_id()
		var generation: int = fixture.tracker.get_generation()
		connection.start_node = null
		connection.end_node = null
		_check(is_instance_valid(connection) and not connection.has_endpoints(),
			"Traversed edge remains alive with temporarily disconnected endpoints")
		_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Recorded prefix survives endpoint loss")
		var empty_id: String = "invalid-new-candidate:" + String(kind)
		fixture.tracker.register_cargo(empty_id, kind)
		_check(not fixture.tracker.record_candidate(empty_id, connection, generation),
			"Disconnected geometry still cannot create a new candidate")
		_step(packet, 0.5)
		_arrived(outcome, "Arrival after traversed endpoint loss")
		_counts(fixture.tracker, cargo_id, 2, 0, &"pending", "Real completed route retains historical edge")
		_check(fixture.tracker.confirm_cargo(cargo_id, generation),
			"Unit business confirmation accepts recorded historical passage")
		_counts(fixture.tracker, cargo_id, 2, 2, &"confirmed", "Confirmation ignores later endpoint state")
		_check(fixture.tracker.has_confirmed_passage(cargo_id, connection, generation),
			"Disconnected live edge retains authoritative confirmation")
		var replayed: bool = false
		for row: Dictionary in fixture.tracker.get_confirmed_passages():
			if row["cargo_id"] == cargo_id and int(row["edge_id"]) == edge_id:
				replayed = row["edge_ref"] is WeakRef and row["edge_ref"].get_ref() == connection
		_check(replayed and fixture.events.size() == 2,
			"Late observers replay the same disconnected live edge exactly once")
		connection.start_node = original_start
		connection.end_node = original_end
		_counts(fixture.tracker, cargo_id, 2, 2, &"confirmed", "Restoring endpoints preserves the same history")
		_check(fixture.tracker.has_confirmed_passage(cargo_id, connection, generation)
			and not fixture.tracker.confirm_cargo(cargo_id, generation)
			and fixture.events.size() == 2, "Endpoint restoration cannot duplicate confirmation")
		connection.start_node = null
		_counts(fixture.tracker, cargo_id, 2, 2, &"confirmed", "Confirmed history survives another disconnection")
		_check(fixture.tracker.get_confirmed_passages().size() == 2,
			"Confirmed replay does not recheck present geometry")
		connection.start_node = original_start
		_empty_traffic(fixture, "Historical edge geometry")
		_destroy(fixture)
	evidence.append({"case": "historical_edge_geometry", "packet_kinds": 3,
		"confirmed_edges_per_kind": 2, "endpoint_restore_signals": 0})


func _test_weak_edges_and_notification_deletion() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
	]))
	var cargo_id: String = "weak-before-confirm"
	var outcome: Outcome = Outcome.new()
	var packet: Variant = _packet(fixture, &"remains", outcome, cargo_id)
	_start(packet, fixture, &"remains", outcome)
	_step(packet, 2.0)
	var deleted_edge: WeakRef = weakref(fixture.edges[0])
	fixture.edges[0].free()
	_check(deleted_edge.get_ref() == null, "Candidate history cannot retain a deleted edge")
	_counts(fixture.tracker, cargo_id, 1, 0, &"pending", "Deleted candidate omitted from live query")
	_check(fixture.tracker.confirm_cargo(cargo_id, fixture.tracker.get_generation())
		and fixture.events.size() == 1, "Confirmation skips deleted candidates")
	var rows: Array[Dictionary] = fixture.tracker.get_confirmed_passages()
	var live_ref: WeakRef = rows[0]["edge_ref"]
	fixture.edges[1].queue_free()
	_counts(fixture.tracker, cargo_id, 0, 0, &"confirmed", "Queued deletion is already excluded")
	_check(fixture.tracker.get_confirmed_passages().is_empty(),
		"No queued-for-deletion edge can be replayed to a late observer")
	fixture.edges[1].free()
	_check(live_ref.get_ref() == null, "Saved confirmation rows do not retain edges")
	_destroy(fixture)
	fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
	]))
	cargo_id = "delete-in-notification"
	outcome = Outcome.new()
	packet = _packet(fixture, &"supply", outcome, cargo_id)
	_start(packet, fixture, &"supply", outcome)
	_step(packet, 2.0)
	var erased: WeakRef = weakref(fixture.edges[1])
	fixture.tracker.passage_confirmed.connect(
		func(event_id: String, _edge_value: HyphaEdge, _generation: int) -> void:
			if event_id == cargo_id and is_instance_valid(erased.get_ref()):
				erased.get_ref().free()
	)
	_check(fixture.tracker.confirm_cargo(cargo_id, fixture.tracker.get_generation()),
		"Confirmation survives observer edge deletion")
	_check(fixture.events.size() == 1 and erased.get_ref() == null,
		"Deletion invalidates the queued second edge notification")
	_counts(fixture.tracker, cargo_id, 1, 1, &"confirmed", "Live confirmation query after callback deletion")
	_destroy(fixture)
	evidence.append({"case": "weak_edge_lifetime", "deleted_candidates_skipped": true,
		"queued_notification_deletion_safe": true})


func _test_generation_and_tracker_lifetime() -> void:
	for kind: StringName in KINDS:
		var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		var cargo_id: String = "reset-reused:" + String(kind)
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, kind, outcome, cargo_id)
		var old_generation: int = fixture.tracker.get_generation()
		_start(packet, fixture, kind, outcome)
		_step(packet, 0.5)
		fixture.tracker.reset()
		var new_generation: int = fixture.tracker.get_generation()
		_check(new_generation > old_generation
			and fixture.tracker.get_snapshot()["cargo_count"] == 0, "Reset invalidates before clearing cargo")
		fixture.tracker.register_cargo(cargo_id, kind)
		_step(packet, 0.5)
		_arrived(outcome, "Tracker reset preserves real transport")
		_counts(fixture.tracker, cargo_id, 0, 0, &"pending", "Old packet cannot write to reused new identity")
		_check(not fixture.tracker.confirm_cargo(cargo_id, old_generation)
			and not fixture.tracker.discard_cargo(cargo_id, old_generation)
			and not fixture.tracker.record_candidate(cargo_id, fixture.edges[0], old_generation),
			"All old-generation mutation entrypoints are invalid")
		var saved_confirmation: Callable = fixture.tracker.confirm_cargo.bind(cargo_id, old_generation)
		_check(not saved_confirmation.call(), "Saved business callback cannot confirm a newer generation")
		var current_outcome: Outcome = Outcome.new()
		var current: Variant = _packet(fixture, kind, current_outcome, cargo_id)
		_start(current, fixture, kind, current_outcome)
		_step(current, 1.0)
		_check(fixture.tracker.confirm_cargo(cargo_id, new_generation) and fixture.events.size() == 1,
			"Fresh generation accepts only its own packet passage")
		_empty_traffic(fixture, "Generation isolation")
		_destroy(fixture)
		fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		outcome = Outcome.new()
		packet = _packet(fixture, kind, outcome, "detached")
		old_generation = fixture.tracker.get_generation()
		fixture.host.remove_child(fixture.tracker)
		_check(fixture.tracker.get_generation() > old_generation,
			"Tracker tree exit invalidates bindings")
		fixture.host.add_child(fixture.tracker)
		fixture.tracker.register_cargo("detached", kind)
		_start(packet, fixture, kind, outcome)
		_step(packet, 1.0)
		_arrived(outcome, "Tracker tree exit preserves packet outcome")
		_counts(fixture.tracker, "detached", 0, 0, &"pending", "Reentered tracker does not resurrect old binding")
		_destroy(fixture)
		fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]))
		outcome = Outcome.new()
		packet = _packet(fixture, kind, outcome, "freed-source")
		var reference: WeakRef = weakref(fixture.tracker)
		fixture.tracker.free()
		_check(reference.get_ref() == null, "Packet holds only a weak tracker reference")
		_start(packet, fixture, kind, outcome)
		_step(packet, 1.0)
		_arrived(outcome, "Freed tracker preserves packet outcome")
		_empty_traffic(fixture, "Freed tracker")
		_destroy(fixture)
	evidence.append({"case": "generation_source_lifetime", "old_bindings_rejected": true,
		"transport_outcomes_preserved": true})


func _test_reentrant_confirmation_and_reset() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
	]))
	for cargo_id: String in ["first", "second"]:
		var outcome: Outcome = Outcome.new()
		var packet: Variant = _packet(fixture, &"supply", outcome, cargo_id)
		_start(packet, fixture, &"supply", outcome)
		_step(packet, 2.0)
	var generation: int = fixture.tracker.get_generation()
	var nested: Dictionary = {"confirmed": false}
	fixture.tracker.passage_confirmed.connect(
		func(cargo_id: String, _edge_value: HyphaEdge, event_generation: int) -> void:
			if cargo_id == "first" and not nested["confirmed"]:
				nested["confirmed"] = true
				_check(fixture.tracker.confirm_cargo("second", event_generation),
					"Notification can safely confirm a different ready cargo")
				_check(fixture.tracker.get_cargo_snapshot("second")["confirmed_count"] == 2,
					"Nested confirmation is atomic while notifications are deferred")
	)
	_check(fixture.tracker.confirm_cargo("first", generation) and fixture.events.size() == 4,
		"Reentrant confirmation drains each pair once")
	_check(fixture.tracker.get_snapshot()["confirmed_count"] == 2
		and fixture.tracker.get_snapshot()["confirmed_passage_count"] == 4,
		"Nested confirmation retains both independent authorities")
	_destroy(fixture)
	fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
	]))
	var outcome: Outcome = Outcome.new()
	var packet: Variant = _packet(fixture, &"return", outcome, "reset-in-signal")
	_start(packet, fixture, &"return", outcome)
	_step(packet, 2.0)
	generation = fixture.tracker.get_generation()
	var reset_state: Dictionary = {"fired": false, "generation": generation}
	fixture.tracker.passage_confirmed.connect(
		func(_cargo_id: String, _edge_value: HyphaEdge, event_generation: int) -> void:
			if reset_state["fired"]:
				return
			reset_state["fired"] = true
			_check(fixture.tracker.get_cargo_snapshot("reset-in-signal")["confirmed_count"] == 2,
				"Reset observer still sees the whole atomic confirmation")
			fixture.tracker.reset()
			reset_state["generation"] = fixture.tracker.get_generation()
			fixture.tracker.register_cargo("reset-in-signal", &"return")
			_check(not fixture.tracker.confirm_cargo("reset-in-signal", event_generation),
				"Reset callback cannot confirm the same textual ID in a new epoch")
	)
	_check(fixture.tracker.confirm_cargo("reset-in-signal", generation), "Original confirmation committed")
	_check(fixture.events.size() == 1 and int(reset_state["generation"]) > generation,
		"Reset drops every pending publication from the old generation")
	_counts(fixture.tracker, "reset-in-signal", 0, 0, &"pending", "Reset callback leaves fresh identity empty")
	var fresh_outcome: Outcome = Outcome.new()
	var fresh: Variant = _packet(fixture, &"return", fresh_outcome, "reset-in-signal")
	_start(fresh, fixture, &"return", fresh_outcome)
	_step(fresh, 2.0)
	_check(fixture.tracker.confirm_cargo("reset-in-signal", int(reset_state["generation"]))
		and fixture.events.size() == 3, "New-generation notification queue remains usable after reset")
	_destroy(fixture)
	fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0),
	]))
	outcome = Outcome.new()
	packet = _packet(fixture, &"supply", outcome, "source-queued-delete")
	_start(packet, fixture, &"supply", outcome)
	_step(packet, 2.0)
	fixture.tracker.passage_confirmed.connect(
		func(_cargo_id: String, _edge_value: HyphaEdge, _event_generation: int) -> void:
			fixture.tracker.queue_free()
	)
	_check(fixture.tracker.confirm_cargo("source-queued-delete", fixture.tracker.get_generation())
		and fixture.events.size() == 1, "Tracker deletion suppresses remaining queued publications")
	_destroy(fixture)
	evidence.append({"case": "notification_reentry", "nested_pairs": 4,
		"old_signals_after_reset": 0, "source_deletion_safe": true})
