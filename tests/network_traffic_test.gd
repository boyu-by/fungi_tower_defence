extends SceneTree
## 独立容量账本测试：只使用节点和边，不创建实际运输包或结算营养。

class LengthEdge:
	extends HyphaEdge

	var reported_length: float = 100.0

	func get_length() -> float:
		return reported_length

class Fixture:
	extends RefCounted

	var world: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var first: Node2D
	var second: Node2D
	var third: Node2D
	var edge: HyphaEdge
	var events: Array[Dictionary] = []
	var changes: int = 0

class Trigger:
	extends RefCounted

	var fired: bool = false
	var restarted: bool = false
	var result: Dictionary = {}
	var old_token: String = ""
	var event_index: int = 0

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_kind_units_and_validation()
	_test_idempotency_and_owner_limit()
	_test_two_way_nutrition_and_exclusive_remains()
	_test_fifo_large_head_and_cancellation()
	_test_closure_and_capacity_changes()
	_test_cancel_owner_and_task_retirement()
	_test_reset_and_instance_handles()
	_test_owner_tree_exit_and_freed_references()
	_test_tree_outside_owner()
	_test_edge_and_node_removal()
	_test_direct_endpoint_mutation()
	await _test_queued_deletion_and_pure_queries()
	_test_network_exit_and_replacement()
	_test_wait_model()
	_test_snapshot_copies()
	_test_reentrant_release_and_next_hop()
	_test_reentrant_batch_grant()
	_test_reentrant_task_retirement()
	_test_reentrant_owner_exit_reset()
	_test_reentrant_reset()
	_test_reentrant_traffic_notification()
	_check(root.get_child_count() == initial_children, "Traffic fixtures left root children")
	print("NETWORK_TRAFFIC_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_node(fixture: Fixture, position: Vector2) -> Node2D:
	var node: Node2D = Node2D.new()
	fixture.world.add_child(node)
	node.position = position
	_check(fixture.network.register_node(node), "Fixture node registration failed")
	return node


func _new_owner(fixture: Fixture) -> Node:
	var owner: Node = Node.new()
	fixture.world.add_child(owner)
	return owner


func _new_edge(fixture: Fixture, first: Node2D, second: Node2D, capacity: int = 2) -> HyphaEdge:
	var edge: HyphaEdge = HyphaEdge.new()
	_configure_edge(fixture, edge, first, second, capacity)
	return edge


func _configure_edge(
	fixture: Fixture, edge: HyphaEdge, first: Node2D, second: Node2D, capacity: int
) -> void:
	edge.start_node = first
	edge.end_node = second
	edge.traffic_capacity = capacity
	var vein: Line2D = Line2D.new()
	vein.name = "Vein"
	edge.add_child(vein)
	fixture.world.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Fixture edge registration failed")


func _new_fixture(capacity: int = 2, length_edge: bool = false) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.first = _new_node(fixture, Vector2.ZERO)
	fixture.second = _new_node(fixture, Vector2(100.0, 0.0))
	fixture.third = _new_node(fixture, Vector2(0.0, 100.0))
	if length_edge:
		fixture.edge = LengthEdge.new()
		_configure_edge(fixture, fixture.edge, fixture.first, fixture.second, capacity)
	else:
		fixture.edge = _new_edge(fixture, fixture.first, fixture.second, capacity)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.events.append(snapshot.duplicate(true))
	)
	fixture.traffic.traffic_changed.connect(func() -> void: fixture.changes += 1)
	return fixture


func _dispose(fixture: Fixture) -> void:
	fixture.world.free()


func _request(
	fixture: Fixture, key: String, kind: StringName = &"supply", owner: Node = null,
	reverse: bool = false, task_id: String = "task"
) -> Dictionary:
	var requester: Node = _new_owner(fixture) if owner == null else owner
	return fixture.traffic.request_passage(
		key, requester, task_id, fixture.edge,
		fixture.second if reverse else fixture.first,
		fixture.first if reverse else fixture.second, kind
	)


func _check_rejected(snapshot: Dictionary, reason: StringName, context: String) -> void:
	_check(not snapshot["accepted"] and snapshot["state"] == &"rejected", context + ": accepted")
	_check(snapshot["reason"] == reason, context + ": reason")
	_check(snapshot["request_id"] == "" and snapshot["token"] == "", context + ": created handles")


func _check_totals(fixture: Fixture, occupied: int, queued: int, leases: int, context: String) -> void:
	var snapshot: Dictionary = fixture.traffic.get_snapshot()
	_check(snapshot["occupied_units"] == occupied, context + ": occupied units")
	_check(snapshot["queued_count"] == queued, context + ": queued count")
	_check(snapshot["active_lease_count"] == leases, context + ": lease count")
	_check(snapshot["active_request_count"] == queued + leases, context + ": active owner count")


func _queue_keys(fixture: Fixture) -> Array[String]:
	var keys: Array[String] = []
	for snapshot: Dictionary in fixture.traffic.get_edge_snapshot(fixture.edge)["queue"]:
		keys.append(snapshot["request_key"])
	return keys


func _test_kind_units_and_validation() -> void:
	_check(NetworkTrafficSystem.units_for_kind(&"supply") == 1, "Supply used nutrition amount as capacity")
	_check(NetworkTrafficSystem.units_for_kind(&"return") == 1, "Return cargo did not use one unit")
	_check(NetworkTrafficSystem.units_for_kind(&"remains") == 2, "Remains cargo did not use two units")
	_check(NetworkTrafficSystem.units_for_kind(&"other") == 0, "Unknown cargo had nonzero units")
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	for key: String in ["", "empty-task", "missing-owner", "same-endpoint", "unknown-kind"]:
		var snapshot: Dictionary = fixture.traffic.request_passage(
			key, null if key == "missing-owner" else owner,
			"" if key == "empty-task" else "validation", fixture.edge,
			fixture.first, fixture.first if key == "same-endpoint" else fixture.second,
			&"invalid" if key == "unknown-kind" else &"supply"
		)
		var reasons: Dictionary = {
			"": &"empty_request_key", "empty-task": &"empty_task_id",
			"missing-owner": &"invalid_owner", "same-endpoint": &"invalid_direction",
			"unknown-kind": &"unknown_cargo_kind",
		}
		_check_rejected(snapshot, reasons[key], "Validation " + key)
	var stranger: Node2D = Node2D.new()
	_check_rejected(fixture.traffic.request_passage(
		"stranger", owner, "validation", fixture.edge, stranger, fixture.second, &"supply"
	), &"invalid_direction", "Unregistered waiting node")
	stranger.free()
	_check_rejected(fixture.traffic.request_passage(
		"missing-edge", owner, "validation", null, fixture.first, fixture.second, &"supply"
	), &"invalid_edge", "Missing edge")
	fixture.edge.traffic_capacity = 1
	_check_rejected(_request(fixture, "oversized", &"remains", owner),
		&"capacity_exceeded", "Oversized initial request")
	fixture.edge.traffic_capacity = 0
	_check_rejected(_request(fixture, "zero-capacity", &"supply", owner),
		&"capacity_exceeded", "Zero capacity")
	fixture.edge.traffic_capacity = 2
	_check_totals(fixture, 0, 0, 0, "Rejections made no records")
	_check(fixture.events.is_empty(), "Rejection emitted request_changed")
	_check(fixture.traffic.get_request("missing").is_empty()
		and fixture.traffic.get_lease("missing").is_empty(), "Unknown handle returned a record")
	_dispose(fixture)


func _test_idempotency_and_owner_limit() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var first: Dictionary = _request(fixture, "hop", &"supply", owner)
	var changes: int = fixture.changes
	var event_count: int = fixture.events.size()
	var repeated: Dictionary = _request(fixture, "hop", &"supply", owner)
	_check(first == repeated and first["state"] == &"granted", "Idempotent grant changed its identity")
	_check(fixture.changes == changes and fixture.events.size() == event_count,
		"Idempotent grant emitted notifications")
	_check_rejected(_request(fixture, "hop", &"return", owner),
		&"request_key_conflict", "Conflicting cargo for the same key")
	_check_rejected(_request(fixture, "hop", &"supply", owner, true),
		&"request_key_conflict", "Conflicting direction for the same key")
	_check_rejected(_request(fixture, "next-hop", &"supply", owner), &"owner_busy", "Active owner")
	var other_edge: HyphaEdge = _new_edge(fixture, fixture.second, fixture.third)
	_check_rejected(fixture.traffic.request_passage(
		"other-edge", owner, "task", other_edge, fixture.second, fixture.third, &"supply"
	), &"owner_busy", "Owner on another edge")
	_check(fixture.traffic.release(first["token"]), "First release failed")
	_check(not fixture.traffic.release(first["token"]), "Repeated release succeeded")
	_check(not fixture.traffic.cancel_request(first["request_id"]), "Released request was cancelled again")
	var terminal: Dictionary = _request(fixture, "hop", &"supply", owner)
	_check(terminal["accepted"] and terminal["state"] == &"released" and terminal["token"] == "",
		"Repeated terminal key was requeued or regranted")
	_check(terminal["request_id"] == first["request_id"], "Terminal request identity changed")
	var next: Dictionary = _request(fixture, "next-hop", &"return", owner, true)
	_check(next["state"] == &"granted" and next["token"] != first["token"],
		"Released owner could not enter its next hop with a fresh lease")
	_check(fixture.traffic.cancel_request(next["request_id"]), "Granted cancellation failed")
	_check(not fixture.traffic.cancel_request(next["request_id"])
		and not fixture.traffic.release(next["token"]), "Cancelled grant settled twice")
	_check(_request(fixture, "next-hop", &"return", owner, true)["state"] == &"cancelled",
		"Cancelled idempotency key resurrected a grant")
	_check_totals(fixture, 0, 0, 0, "Terminal requests freed capacity")
	fixture.edge.entry_enabled = false
	var queued: Dictionary = _request(fixture, "one-queued-hop", &"supply", owner)
	_check(queued["state"] == &"queued" and _request(fixture, "one-queued-hop", &"supply", owner) == queued,
		"Queued request idempotency failed")
	_check_rejected(_request(fixture, "another-queued-hop", &"supply", owner),
		&"owner_busy", "Owner with one queued hop")
	_dispose(fixture)


func _test_two_way_nutrition_and_exclusive_remains() -> void:
	var fixture: Fixture = _new_fixture()
	var nutrient_owner: Node = _new_owner(fixture)
	nutrient_owner.set_meta("nutrition", 1000000)
	var first: Dictionary = _request(fixture, "outward", &"supply", nutrient_owner)
	var second: Dictionary = _request(fixture, "inward", &"return", null, true)
	var remains: Dictionary = _request(fixture, "remains", &"remains")
	_check(first["units"] == 1 and second["units"] == 1 and remains["units"] == 2,
		"Cargo nutrient metadata changed transport units")
	_check(first["state"] == &"granted" and second["state"] == &"granted"
		and remains["state"] == &"queued", "Opposite directions did not share the same capacity")
	_check(remains["from_node"] == fixture.first and remains["to_node"] == fixture.second,
		"Queued request lost its logical waiting endpoint")
	_check_totals(fixture, 2, 1, 2, "Two nutrition occupants")
	fixture.traffic.release(first["token"])
	_check(fixture.traffic.get_request(remains["request_id"])["state"] == &"queued",
		"Two-unit remains entered alongside a nutrition occupant")
	fixture.traffic.release(second["token"])
	var granted_remains: Dictionary = fixture.traffic.get_request(remains["request_id"])
	_check(granted_remains["state"] == &"granted", "Remains failed to enter an empty two-unit edge")
	var follower: Dictionary = _request(fixture, "behind-remains", &"return", null, true)
	_check(follower["state"] == &"queued", "Exclusive remains allowed another occupant")
	fixture.traffic.release(granted_remains["token"])
	_check(fixture.traffic.get_request(follower["request_id"])["state"] == &"granted",
		"Reverse follower did not enter after remains release")
	_dispose(fixture)


func _test_fifo_large_head_and_cancellation() -> void:
	var fixture: Fixture = _new_fixture()
	var occupant: Dictionary = _request(fixture, "occupant")
	var head: Dictionary = _request(fixture, "large-head", &"remains", null, true)
	var followers: Array[Dictionary] = []
	var expected_keys: Array[String] = ["large-head"]
	for index: int in range(24):
		var key: String = "late-small-%d" % index
		followers.append(_request(fixture, key, &"return" if index % 2 == 0 else &"supply"))
		expected_keys.append(key)
		_check(followers.back()["state"] == &"queued", "Late small cargo bypassed the large FIFO head")
	_check(_queue_keys(fixture) == expected_keys, "Two-way FIFO sequence changed")
	_check_totals(fixture, 1, 25, 1, "Large head blocks available spare unit")
	_check(fixture.traffic.cancel_request(head["request_id"]), "Cancelling the FIFO head failed")
	_check(fixture.traffic.get_request(followers[0]["request_id"])["state"] == &"granted"
		and fixture.traffic.get_request(followers[1]["request_id"])["state"] == &"queued",
		"Head cancellation did not admit exactly the first fitting follower")
	fixture.traffic.release(occupant["token"])
	_check(fixture.traffic.get_request(followers[1]["request_id"])["state"] == &"granted",
		"Release failed to drain the next FIFO follower")
	var leases: Array = fixture.traffic.get_edge_snapshot(fixture.edge)["leases"]
	_check(leases.size() == 2 and leases[0]["request_id"] == followers[0]["request_id"]
		and leases[1]["request_id"] == followers[1]["request_id"], "Leases were not returned in grant order")
	_check(not fixture.traffic.cancel_request(head["request_id"]), "Repeated FIFO head cancellation succeeded")
	_dispose(fixture)


func _test_closure_and_capacity_changes() -> void:
	var fixture: Fixture = _new_fixture()
	var first: Dictionary = _request(fixture, "first")
	fixture.edge.entry_enabled = false
	var closed: Dictionary = _request(fixture, "closed-queue", &"return", null, true)
	_check(closed["accepted"] and closed["state"] == &"queued", "Closed edge rejected a valid queued request")
	_check(not fixture.traffic.get_lease(first["token"]).is_empty(), "Closure evicted an existing occupant")
	fixture.traffic.release(first["token"])
	_check(fixture.traffic.get_request(closed["request_id"])["state"] == &"queued",
		"Release through a closed entry granted another request")
	fixture.edge.entry_enabled = true
	_check(fixture.traffic.get_request(closed["request_id"])["state"] == &"granted",
		"Reopening did not drain the closed FIFO")
	var second: Dictionary = _request(fixture, "second")
	var head: Dictionary = _request(fixture, "resize-head", &"remains")
	fixture.edge.traffic_capacity = 1
	var snapshot: Dictionary = fixture.traffic.get_edge_snapshot(fixture.edge)
	_check(snapshot["occupied_units"] == 2 and snapshot["available_units"] == 0,
		"Capacity reduction evicted occupants or reported negative availability")
	_check(snapshot["leases"].size() == 2 and snapshot["queue"].size() == 1,
		"Capacity reduction discarded a previously legal large head")
	var follower: Dictionary = _request(fixture, "resize-follower")
	_check(follower["state"] == &"queued", "Small follower bypassed an oversized head after shrink")
	_check_rejected(_request(fixture, "new-oversized", &"remains"),
		&"capacity_exceeded", "New remains after shrink")
	_check(is_inf(fixture.traffic.estimate_wait_seconds(fixture.edge, 1, 50.0)),
		"Oversized queued head did not make waiting estimate infinite")
	fixture.traffic.release(second["token"])
	fixture.traffic.release(fixture.traffic.get_request(closed["request_id"])["token"])
	_check_totals(fixture, 0, 2, 0, "Oversized old head waits with an empty shrunken edge")
	fixture.edge.traffic_capacity = 2
	_check(fixture.traffic.get_request(head["request_id"])["state"] == &"granted"
		and fixture.traffic.get_request(follower["request_id"])["state"] == &"queued",
		"Capacity increase did not grant the oldest two-unit cargo first")
	fixture.edge.traffic_capacity = 3
	_check(fixture.traffic.get_request(follower["request_id"])["state"] == &"granted",
		"Further capacity increase did not fill the spare unit")
	_check_totals(fixture, 3, 0, 2, "Capacity increase preserves grant order")
	_dispose(fixture)


func _test_cancel_owner_and_task_retirement() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var occupant: Dictionary = _request(fixture, "owner-occupant", &"supply", owner, false, "owner-task")
	var queued: Dictionary = _request(fixture, "retiring-head", &"remains", null, true, "retiring")
	var follower: Dictionary = _request(fixture, "retiring-follower", &"return", null, false, "retiring")
	_check(fixture.traffic.cancel_owner(owner) == 1 and fixture.traffic.cancel_owner(owner) == 0,
		"Owner cancellation did not settle exactly one active request")
	_check(fixture.traffic.get_request(occupant["request_id"])["state"] == &"cancelled"
		and fixture.traffic.get_request(queued["request_id"])["state"] == &"granted",
		"Owner cancellation failed to free and drain shared capacity")
	var generation: int = fixture.traffic.get_generation()
	_check(fixture.traffic.cancel_task("retiring", generation - 1) == 0,
		"Stale generation cancelled a current task")
	_check(fixture.traffic.cancel_task("retiring", generation) == 2,
		"Task cancellation missed its queued or granted request")
	_check(fixture.traffic.get_request(queued["request_id"])["state"] == &"cancelled"
		and fixture.traffic.get_request(follower["request_id"])["state"] == &"cancelled",
		"Task cancellation failed to commit all terminal states")
	_check(fixture.traffic.cancel_task("retiring", generation) == 0, "Task settled twice")
	_check_rejected(_request(fixture, "late-retired", &"supply", null, false, "retiring"),
		&"task_retired", "Retired task callback")
	_check(fixture.traffic.cancel_task("never-created", generation) == 0,
		"Retiring an empty task reported records")
	_check_rejected(_request(fixture, "empty-retired", &"supply", null, false, "never-created"),
		&"task_retired", "Task retired before any callback")
	var retired_retry: Dictionary = _request(fixture, "retiring-head", &"remains", queued["owner"], true, "retiring")
	_check(retired_retry["accepted"] and retired_retry["state"] == &"cancelled",
		"Retirement broke idempotency for an existing terminal record")
	_check_totals(fixture, 0, 0, 0, "Task retirement")
	_dispose(fixture)


func _test_reset_and_instance_handles() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var old: Dictionary = _request(fixture, "reused", &"remains", owner, false, "reused-task")
	var old_generation: int = fixture.traffic.get_generation()
	fixture.traffic.cancel_task("retired-before-reset", old_generation)
	fixture.traffic.reset()
	_check(fixture.traffic.get_generation() == old_generation + 1, "Reset did not increment generation once")
	_check(fixture.traffic.get_request(old["request_id"]).is_empty()
		and fixture.traffic.get_lease(old["token"]).is_empty(), "Reset retained old traffic handles")
	var current: Dictionary = _request(fixture, "reused", &"supply", owner, false, "reused-task")
	_check(current["state"] == &"granted" and current["request_id"] != old["request_id"]
		and current["token"] != old["token"], "Reset reused opaque handles or blocked a reused key")
	_check(not fixture.traffic.release(old["token"]) and not fixture.traffic.cancel_request(old["request_id"]),
		"Old reset handles changed a new generation")
	_check(fixture.traffic.cancel_task("reused-task", old_generation) == 0
		and fixture.traffic.get_request(current["request_id"])["state"] == &"granted",
		"Old task callback cancelled a restarted task")
	_check(_request(fixture, "unretired", &"supply", null, false, "retired-before-reset")["accepted"],
		"Reset retained task retirement")
	var other: Fixture = _new_fixture()
	var other_request: Dictionary = _request(other, "reused")
	_check(other_request["request_id"] != current["request_id"] and other_request["token"] != current["token"],
		"Different scheduler instances reused request or lease identities")
	_check(not other.traffic.release(current["token"]), "Cross-instance token released another scheduler")
	_dispose(other)
	_dispose(fixture)


func _test_owner_tree_exit_and_freed_references() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var record: Dictionary = _request(fixture, "exiting-owner", &"remains", owner)
	var follower: Dictionary = _request(fixture, "owner-exit-follower")
	fixture.world.remove_child(owner)
	_check(fixture.traffic.get_request(record["request_id"])["state"] == &"cancelled",
		"Owner tree exit failed to cancel its grant synchronously")
	_check(fixture.traffic.get_request(follower["request_id"])["state"] == &"granted",
		"Owner tree exit did not drain the follower")
	owner.free()
	var terminal: Dictionary = fixture.traffic.get_request(record["request_id"])
	_check(terminal["owner"] == null and terminal["owner_id"] == record["owner_id"],
		"Freed owner was not sanitized while preserving its identity")
	var queued_owner: Node = _new_owner(fixture)
	fixture.edge.entry_enabled = false
	var queued: Dictionary = _request(fixture, "free-queued-owner", &"supply", queued_owner)
	queued_owner.free()
	_check(fixture.traffic.get_request(queued["request_id"])["state"] == &"cancelled"
		and fixture.traffic.get_request(queued["request_id"])["owner"] == null,
		"Freeing a queued owner left its request active or exposed a freed reference")
	_dispose(fixture)


func _test_tree_outside_owner() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = Node.new()
	var active: Dictionary = _request(fixture, "tree-outside-owner", &"remains", owner)
	var waiting: Dictionary = _request(fixture, "after-tree-outside-owner")
	_check(active["state"] == &"granted", "Valid tree-outside owner was rejected")
	owner.free()
	var observed: Dictionary = fixture.traffic.get_request(active["request_id"])
	_check(observed["state"] == &"granted" and observed["owner"] == null,
		"Pure query failed to sanitize a directly freed tree-outside owner")
	fixture.traffic.refresh()
	_check(fixture.traffic.get_request(active["request_id"])["state"] == &"cancelled"
		and fixture.traffic.get_request(waiting["request_id"])["state"] == &"granted",
		"Refresh did not reconcile a directly freed tree-outside owner")
	_dispose(fixture)


func _test_edge_and_node_removal() -> void:
	for removal: int in range(4):
		var fixture: Fixture = _new_fixture()
		var active: Dictionary = _request(fixture, "removed-active", &"remains")
		var queued: Dictionary = _request(fixture, "removed-queued", &"return", null, true)
		if removal == 0:
			fixture.network.unregister_edge(fixture.edge)
		elif removal == 1:
			fixture.network.unregister_node(fixture.first)
		elif removal == 2:
			fixture.edge.free()
		else:
			fixture.first.free()
		var old_active: Dictionary = fixture.traffic.get_request(active["request_id"])
		var old_queued: Dictionary = fixture.traffic.get_request(queued["request_id"])
		_check(old_active["state"] == &"cancelled" and old_queued["state"] == &"cancelled",
			"Edge/node removal left queued or granted traffic active: %d" % removal)
		_check(fixture.traffic.get_lease(active["token"]).is_empty(), "Removal left a valid lease")
		_check_totals(fixture, 0, 0, 0, "Edge/node removal %d" % removal)
		if removal == 2:
			_check(old_active["edge"] == null and old_active["edge_id"] == active["edge_id"],
				"Freed edge reference was not sanitized")
		elif removal == 3:
			_check(old_active["from_node"] == null and old_queued["to_node"] == null,
				"Freed endpoint references were not sanitized")
		_dispose(fixture)


func _test_direct_endpoint_mutation() -> void:
	for mutation: int in range(3):
		var fixture: Fixture = _new_fixture()
		var active: Dictionary = _request(fixture, "original-endpoints", &"remains")
		var changes: int = fixture.changes
		if mutation == 0:
			fixture.edge.end_node = fixture.third
		elif mutation == 1:
			fixture.edge.start_node = fixture.second
			fixture.edge.end_node = fixture.first
		else:
			fixture.edge.end_node = null
		fixture.traffic.get_snapshot()
		fixture.traffic.get_edge_snapshot(fixture.edge)
		fixture.traffic.estimate_wait_seconds(fixture.edge, 1, 50.0)
		_check(fixture.traffic.get_request(active["request_id"])["state"] == &"granted"
			and fixture.changes == changes, "Query reconciled a direct endpoint mutation")
		fixture.traffic._process(0.0)
		_check(fixture.traffic.get_request(active["request_id"])["state"] == &"cancelled",
			"Process failed to cancel changed edge endpoints: %d" % mutation)
		_check_totals(fixture, 0, 0, 0, "Endpoint mutation %d" % mutation)
		_dispose(fixture)


func _test_queued_deletion_and_pure_queries() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var record: Dictionary = _request(fixture, "queued-delete-owner", &"remains", owner)
	var waiting: Dictionary = _request(fixture, "after-delete")
	var before: Dictionary = fixture.traffic.get_snapshot()
	var changes: int = fixture.changes
	var events: int = fixture.events.size()
	owner.queue_free()
	for index: int in range(8):
		_check(fixture.traffic.get_snapshot() == before, "Pure global query changed queued-deletion state")
		_check(fixture.traffic.get_request(record["request_id"])["state"] == &"granted",
			"Pure request query cancelled a queued-deletion owner")
		_check(not fixture.traffic.get_lease(record["token"]).is_empty(), "Pure lease query released traffic")
		fixture.traffic.get_edge_snapshot(fixture.edge)
		fixture.traffic.estimate_wait_seconds(fixture.edge, 1, 50.0)
	_check(fixture.changes == changes and fixture.events.size() == events, "Queries emitted notifications")
	var late: Dictionary = _request(fixture, "admission-refresh")
	_check(fixture.traffic.get_request(record["request_id"])["state"] == &"cancelled"
		and fixture.traffic.get_request(waiting["request_id"])["state"] == &"granted"
		and late["state"] == &"granted", "Admission did not reconcile queued deletion before granting")
	var deleted_owner: Node = _new_owner(fixture)
	deleted_owner.queue_free()
	_check_rejected(_request(fixture, "already-deleting", &"supply", deleted_owner),
		&"invalid_owner", "Queued-deletion new owner")
	await process_frame
	await process_frame
	_check(fixture.traffic.get_request(record["request_id"])["owner"] == null,
		"Queried snapshot retained an owner freed after queue_free")
	fixture.edge.queue_free()
	var event_count: int = fixture.events.size()
	_check(not fixture.traffic.get_edge_snapshot(fixture.edge)["exists"]
		and is_inf(fixture.traffic.estimate_wait_seconds(fixture.edge, 1, 50.0)),
		"Queued-deletion edge appeared available to planning")
	_check(fixture.events.size() == event_count, "Planning query cleaned a queued-deletion edge")
	fixture.traffic.refresh()
	_check_totals(fixture, 0, 0, 0, "Queued-deletion edge refresh")
	await process_frame
	await process_frame
	_dispose(fixture)


func _test_network_exit_and_replacement() -> void:
	var fixture: Fixture = _new_fixture()
	var old: Dictionary = _request(fixture, "old-network", &"remains")
	fixture.world.remove_child(fixture.network)
	_check(fixture.traffic.get_request(old["request_id"])["state"] == &"cancelled",
		"Network tree exit failed to cancel active traffic")
	_check(not fixture.traffic.get_edge_snapshot(fixture.edge)["exists"],
		"Exited network remained available to planning")
	fixture.world.add_child(fixture.network)
	var restarted: Dictionary = _request(fixture, "network-entered")
	_check(restarted["state"] == &"granted", "Reentered network could not accept a fresh hop")
	var old_network: NetworkSystem = fixture.network
	var replacement: NetworkSystem = NetworkSystem.new()
	fixture.world.add_child(replacement)
	for node: Node2D in [fixture.first, fixture.second, fixture.third]:
		replacement.register_node(node)
	replacement.register_edge(fixture.edge)
	var generation: int = fixture.traffic.get_generation()
	fixture.traffic.network_system = replacement
	fixture.traffic.refresh()
	_check(fixture.traffic.get_generation() == generation + 1
		and fixture.traffic.get_request(restarted["request_id"]).is_empty(),
		"Replacing the network did not clear records and advance generation")
	_check(not fixture.traffic.release(restarted["token"]), "Replaced network retained an old active token")
	var current: Dictionary = _request(fixture, "old-network", &"supply", old["owner"])
	_check(current["state"] == &"granted", "Replacement prevented reusing an old request key")
	var changes: int = fixture.changes
	old_network.unregister_edge(fixture.edge)
	old_network.network_changed.emit()
	_check(fixture.changes == changes and fixture.traffic.get_request(current["request_id"])["state"] == &"granted",
		"Old network callbacks affected the replacement dependency")
	fixture.network = replacement
	fixture.traffic.network_system = null
	fixture.traffic.refresh()
	_check_totals(fixture, 0, 0, 0, "Missing dependency clears old occupancy")
	_check_rejected(_request(fixture, "no-network"), &"missing_network", "Missing network dependency")
	_dispose(fixture)
	fixture = _new_fixture()
	old = _request(fixture, "free-network")
	fixture.network.free()
	_check(fixture.traffic.get_request(old["request_id"])["state"] == &"cancelled",
		"Freed network failed to cancel traffic")
	fixture.traffic.refresh()
	_check_totals(fixture, 0, 0, 0, "Freed dependency remains empty")
	_dispose(fixture)


func _test_wait_model() -> void:
	var fixture: Fixture = _new_fixture(2, true)
	var edge: LengthEdge = fixture.edge as LengthEdge
	_check(fixture.traffic.estimate_wait_seconds(edge, 1, 25.0) == 0.0, "Empty edge had a waiting cost")
	var occupant: Dictionary = _request(fixture, "wait-occupant")
	var head: Dictionary = _request(fixture, "wait-remains", &"remains")
	_check(fixture.traffic.estimate_wait_seconds(edge, 1, 25.0) == 8.0,
		"One occupant plus a two-unit head plus candidate did not cost two transits")
	_check(fixture.traffic.estimate_wait_seconds(edge, 2, 25.0) == 8.0,
		"Two-unit hypothetical candidate used incorrect FIFO batches")
	var before: Dictionary = fixture.traffic.get_snapshot()
	var events: int = fixture.events.size()
	for index: int in range(16):
		fixture.traffic.estimate_wait_seconds(edge, 1, 25.0)
	_check(fixture.traffic.get_snapshot() == before and fixture.events.size() == events,
		"Wait estimate mutated queue, leases, or notifications")
	fixture.traffic.cancel_request(head["request_id"])
	_check(fixture.traffic.estimate_wait_seconds(edge, 1, 25.0) == 0.0
		and fixture.traffic.estimate_wait_seconds(edge, 2, 25.0) == 4.0,
		"Available units were not considered for the hypothetical candidate")
	fixture.edge.entry_enabled = false
	_check(is_inf(fixture.traffic.estimate_wait_seconds(edge, 1, 25.0)), "Closed edge had finite wait")
	fixture.edge.entry_enabled = true
	for speed: float in [0.0, -1.0, INF, -INF, NAN]:
		_check(is_inf(fixture.traffic.estimate_wait_seconds(edge, 1, speed)), "Invalid speed had finite wait")
	for units: int in [0, -1, 3]:
		_check(is_inf(fixture.traffic.estimate_wait_seconds(edge, units, 25.0)), "Invalid units had finite wait")
	for length: float in [-1.0, INF, -INF, NAN]:
		edge.reported_length = length
		_check(is_inf(fixture.traffic.estimate_wait_seconds(edge, 1, 25.0)), "Invalid edge length had finite wait")
	edge.reported_length = 0.0
	_check(fixture.traffic.estimate_wait_seconds(edge, 2, 25.0) == 0.0, "Zero-length edge had nonzero wait")
	edge.reported_length = 100.0
	fixture.traffic.release(occupant["token"])
	fixture.network.unregister_edge(edge)
	_check(is_inf(fixture.traffic.estimate_wait_seconds(edge, 1, 25.0)), "Unregistered edge had finite wait")
	_check(is_inf(fixture.traffic.estimate_wait_seconds(null, 1, 25.0)), "Null edge had finite wait")
	_dispose(fixture)


func _test_snapshot_copies() -> void:
	var fixture: Fixture = _new_fixture()
	var active: Dictionary = _request(fixture, "copy-active", &"remains")
	var waiting: Dictionary = _request(fixture, "copy-queued")
	var request_copy: Dictionary = fixture.traffic.get_request(active["request_id"])
	request_copy["state"] = &"cancelled"
	request_copy["token"] = "forged"
	var lease_copy: Dictionary = fixture.traffic.get_lease(active["token"])
	lease_copy.clear()
	var edge_copy: Dictionary = fixture.traffic.get_edge_snapshot(fixture.edge)
	edge_copy["queue"][0]["units"] = 999
	edge_copy["leases"][0]["token"] = "forged"
	edge_copy["queue"].clear()
	var global_copy: Dictionary = fixture.traffic.get_snapshot()
	global_copy["edges"][0]["leases"].clear()
	global_copy["edges"].clear()
	_check(fixture.traffic.get_request(active["request_id"])["state"] == &"granted"
		and fixture.traffic.get_lease(active["token"])["token"] == active["token"],
		"Mutating a returned request/lease dictionary changed the scheduler")
	_check(fixture.traffic.get_request(waiting["request_id"])["units"] == 1
		and _queue_keys(fixture) == ["copy-queued"], "Returned nested queue data changed the FIFO")
	_check_totals(fixture, 2, 1, 1, "Copied nested snapshots")
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		snapshot.clear()
	)
	fixture.traffic.cancel_request(waiting["request_id"])
	_check(fixture.traffic.get_request(waiting["request_id"])["state"] == &"cancelled",
		"Mutating a notification snapshot changed its committed record")
	_dispose(fixture)


func _test_reentrant_release_and_next_hop() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var trigger: Trigger = Trigger.new()
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["request_key"] == "reentrant-first" and snapshot["state"] == &"granted" and not trigger.fired:
			trigger.fired = true
			_check(fixture.traffic.get_lease(snapshot["token"])["request_id"] == snapshot["request_id"],
				"Grant notification ran before committing its lease")
			_check(fixture.traffic.release(snapshot["token"]), "Reentrant release failed")
		elif snapshot["request_key"] == "reentrant-first" and snapshot["state"] == &"released" and not trigger.restarted:
			trigger.restarted = true
			trigger.result = _request(fixture, "reentrant-next", &"return", owner, true)
	)
	var first: Dictionary = _request(fixture, "reentrant-first", &"supply", owner)
	_check(trigger.fired and trigger.restarted and first["state"] == &"released" and first["token"] == "",
		"request_passage returned a stale grant after synchronous release")
	_check(trigger.result["state"] == &"granted"
		and fixture.traffic.get_lease(trigger.result["token"])["owner"] == owner,
		"Terminal callback could not request the same owner's next hop")
	_check_totals(fixture, 1, 0, 1, "Reentrant next hop")
	_dispose(fixture)


func _test_reentrant_batch_grant() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.edge.entry_enabled = false
	var first: Dictionary = _request(fixture, "batch-first")
	var second: Dictionary = _request(fixture, "batch-second", &"return", null, true)
	var third: Dictionary = _request(fixture, "batch-third")
	var trigger: Trigger = Trigger.new()
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["request_id"] == first["request_id"] and snapshot["state"] == &"granted" and not trigger.fired:
			trigger.fired = true
			var second_live: Dictionary = fixture.traffic.get_request(second["request_id"])
			_check(second_live["state"] == &"granted", "Batch notification exposed an uncommitted second lease")
			_check_totals(fixture, 2, 1, 2, "Committed batch in callback")
			_check(fixture.traffic.release(second_live["token"]), "Callback could not release another committed batch lease")
			_check(fixture.traffic.get_request(third["request_id"])["state"] == &"granted",
				"Reentrant release did not commit the next FIFO grant")
	)
	fixture.edge.entry_enabled = true
	_check(trigger.fired and fixture.traffic.get_request(second["request_id"])["state"] == &"released",
		"Batch callback failed to settle the second request")
	for event: Dictionary in fixture.events:
		_check(not (event["request_id"] == second["request_id"] and event["state"] == &"granted"),
			"Stale pending grant was emitted after its reentrant release")
	_check_totals(fixture, 2, 0, 2, "Reentrant batch drain")
	_dispose(fixture)


func _test_reentrant_task_retirement() -> void:
	var fixture: Fixture = _new_fixture()
	var first: Dictionary = _request(fixture, "retire-first", &"supply", null, false, "retiring")
	var second: Dictionary = _request(fixture, "retire-second", &"return", null, true, "retiring")
	var trigger: Trigger = Trigger.new()
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["task_id"] == "retiring" and snapshot["state"] == &"cancelled" and not trigger.fired:
			trigger.fired = true
			_check_totals(fixture, 0, 0, 0, "All task cancellations committed before callbacks")
			trigger.result = _request(fixture, "resurrection", &"supply", null, false, "retiring")
	)
	_check(fixture.traffic.cancel_task("retiring", fixture.traffic.get_generation()) == 2,
		"Reentrant task cancellation counted incorrectly")
	_check_rejected(trigger.result, &"task_retired", "Synchronous cancelled-task resurrection")
	_check(fixture.traffic.get_request(first["request_id"])["token"] == ""
		and fixture.traffic.get_request(second["request_id"])["token"] == "",
		"Task callbacks observed live terminal tokens")
	_dispose(fixture)


func _test_reentrant_owner_exit_reset() -> void:
	var fixture: Fixture = _new_fixture()
	var owner: Node = _new_owner(fixture)
	var record: Dictionary = _request(fixture, "owner-exit-reset", &"remains", owner)
	var trigger: Trigger = Trigger.new()
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["request_id"] == record["request_id"] and snapshot["state"] == &"cancelled" and not trigger.fired:
			trigger.fired = true
			fixture.traffic.reset()
			trigger.result = _request(fixture, "exiting-owner-resurrection", &"supply", owner)
	)
	fixture.world.remove_child(owner)
	_check(trigger.fired, "Actual owner remove_child did not emit a cancellation")
	_check_rejected(trigger.result, &"invalid_owner", "Exiting owner after cancellation callback reset")
	_check_totals(fixture, 0, 0, 0, "Owner exit reset leaves no new-generation traffic")
	fixture.traffic.refresh()
	_check_totals(fixture, 0, 0, 0, "Owner exit reset remains empty after refresh")
	owner.free()
	_dispose(fixture)


func _test_reentrant_reset() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.edge.entry_enabled = false
	var owner: Node = _new_owner(fixture)
	var first: Dictionary = _request(fixture, "reset-key", &"supply", owner)
	var second: Dictionary = _request(fixture, "reset-second")
	var old_generation: int = fixture.traffic.get_generation()
	var trigger: Trigger = Trigger.new()
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["request_id"] == first["request_id"] and snapshot["state"] == &"granted" and not trigger.fired:
			trigger.fired = true
			trigger.old_token = snapshot["token"]
			trigger.event_index = fixture.events.size()
			fixture.traffic.reset()
			trigger.result = _request(fixture, "reset-key", &"remains", owner)
	)
	fixture.edge.entry_enabled = true
	_check(trigger.fired and trigger.result["state"] == &"granted"
		and trigger.result["generation"] == old_generation + 1, "Reset callback did not grant in a fresh generation")
	_check(fixture.traffic.get_request(first["request_id"]).is_empty()
		and fixture.traffic.get_request(second["request_id"]).is_empty(), "Reset callback retained old request records")
	for index: int in range(trigger.event_index, fixture.events.size()):
		_check(fixture.events[index]["generation"] != old_generation, "Old generation notification followed a reentrant reset")
	_check(not fixture.traffic.release(trigger.old_token)
		and not fixture.traffic.cancel_request(second["request_id"])
		and fixture.traffic.cancel_task("task", old_generation) == 0,
		"Old callback handles changed the restarted generation")
	_check_totals(fixture, 2, 0, 1, "Reentrant reset restart")
	_dispose(fixture)
	fixture = _new_fixture()
	trigger = Trigger.new()
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == &"granted" and not trigger.fired:
			trigger.fired = true
			fixture.traffic.reset()
	)
	var result: Dictionary = _request(fixture, "reset-return-value")
	_check_rejected(result, &"generation_changed", "Return value after reset in grant notification")
	_check_totals(fixture, 0, 0, 0, "Grant callback reset")
	_dispose(fixture)


func _test_reentrant_traffic_notification() -> void:
	var fixture: Fixture = _new_fixture()
	var trigger: Trigger = Trigger.new()
	fixture.traffic.traffic_changed.connect(func() -> void:
		if not trigger.fired:
			trigger.fired = true
			fixture.traffic.reset()
			trigger.result = _request(fixture, "traffic-callback-restart")
	)
	var old: Dictionary = _request(fixture, "traffic-callback-old")
	_check_rejected(old, &"generation_changed", "Return value after traffic_changed reset")
	_check(trigger.result["state"] == &"granted"
		and not fixture.traffic.get_lease(trigger.result["token"]).is_empty(),
		"traffic_changed reentry lost its new request or lease")
	_check_totals(fixture, 1, 0, 1, "traffic_changed reentry")
	_dispose(fixture)
