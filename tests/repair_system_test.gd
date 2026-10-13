extends SceneTree
## 手动推进真实边、网络和维修；不调度运输，也不修改母核营养钱包。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const SNAPSHOT_KEYS: Array[String] = [
	"task_id", "state", "wait_reason", "edge", "edge_id", "source_core", "repair_point",
	"target", "target_id", "target_name", "target_kind", "access_edge",
	"supply_reachable", "health", "max_health", "missing_health", "initial_cost",
	"estimated_total_cost", "consumed_nutrition", "buffered_nutrition", "paid_heal_remaining",
	"restored_health", "remaining_cost", "remaining_demand",
]
const PREVIEW_KEYS: Array[String] = [
	"valid", "reason", "edge", "edge_id", "health", "max_health", "missing_health",
	"target", "target_id", "target_name", "target_kind", "access_edge",
	"estimated_cost", "repair_point", "supply_reachable",
]

class Fixture:
	extends RefCounted

	var host: Node2D
	var network: NetworkSystem
	var core: MotherCore
	var start: Node2D
	var end: Node2D
	var target: HyphaEdge
	var start_supply: HyphaEdge = null
	var end_supply: HyphaEdge = null
	var repair: RepairSystem

class Outcome:
	extends RefCounted

	var snapshots: Array[Dictionary] = []
	var completions: Array[int] = []
	var cancellations: Array[int] = []
	var network_changes: int = 0
	var health_changes: int = 0
	var traffic_changes: int = 0

class Trigger:
	extends RefCounted

	var fired: bool = false
	var task_id: int = 0
	var replacement_id: int = 0
	var refunded: int = 0
	var snapshot: Dictionary = {}

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_edge_health_and_traversal()
	_test_timed_healing_and_ceil_cost()
	_test_fractional_final_unit()
	_test_pause_resume_and_delivery_ids()
	_test_cancel_and_reset_settlement()
	_test_disconnected_point_selection_and_pinning()
	_test_query_purity_and_original_source()
	_test_damage_increases_demand()
	_test_small_paid_credit_cannot_expand_for_free()
	_test_target_and_dependency_loss()
	_test_moving_geometry_keeps_identity()
	_test_delivery_notification_reentry()
	_test_healing_notification_reentry()
	_test_completion_notification_restart()
	_test_terminal_notification_restart()
	_test_real_growth_initial_health_and_handoff()
	_test_growth_handoff_cannot_move_the_work_point()
	_check(root.get_child_count() == initial_children, "Repair fixtures left root children")
	print("REPAIR_SYSTEM_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _close(actual: float, expected: float, message: String, tolerance: float = 0.000001) -> void:
	_check(absf(actual - expected) <= tolerance, message + ": got %s expected %s" % [actual, expected])


func _keys(snapshot: Dictionary, expected: Array[String], message: String) -> void:
	var matching: bool = snapshot.size() == expected.size()
	for key: String in expected:
		matching = matching and snapshot.has(key)
	_check(matching, message)


func _fixture(connect_start: bool = true, connect_end: bool = false, mature_start: bool = false) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.host = Node2D.new()
	root.add_child(fixture.host)
	fixture.network = NetworkSystem.new()
	fixture.host.add_child(fixture.network)
	fixture.core = CORE_SCENE.instantiate()
	fixture.host.add_child(fixture.core)
	fixture.core.global_position = Vector2.ZERO
	_check(fixture.network.register_node(fixture.core, true), "Fixture core registered")
	fixture.start = _node(fixture, Vector2(100.0, 0.0), mature_start)
	fixture.end = _node(fixture, Vector2(200.0, 0.0))
	if connect_start:
		fixture.start_supply = _edge(fixture, fixture.core, fixture.start)
	if connect_end:
		fixture.end_supply = _edge(fixture, fixture.core, fixture.end)
	fixture.target = _edge(fixture, fixture.start, fixture.end)
	fixture.repair = RepairSystem.new()
	fixture.repair.network_system = fixture.network
	fixture.host.add_child(fixture.repair)
	fixture.repair.set_physics_process(false)
	return fixture


func _node(fixture: Fixture, point: Vector2, mature: bool = false) -> Node2D:
	var node: Node2D = NODE_SCENE.instantiate() if mature else Node2D.new()
	fixture.host.add_child(node)
	node.global_position = point
	_check(fixture.network.register_node(node), "Fixture node registered")
	return node


func _edge(fixture: Fixture, first: Node2D, last: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate()
	edge.start_node = first
	edge.end_node = last
	fixture.host.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Fixture edge registered")
	return edge


func _observe(fixture: Fixture) -> Outcome:
	var outcome: Outcome = Outcome.new()
	fixture.repair.task_changed.connect(func(snapshot: Dictionary) -> void:
		outcome.snapshots.append(snapshot.duplicate())
	)
	fixture.repair.task_completed.connect(func(task_id: int) -> void:
		outcome.completions.append(task_id)
	)
	fixture.repair.task_cancelled.connect(func(task_id: int) -> void:
		outcome.cancellations.append(task_id)
	)
	fixture.network.network_changed.connect(func() -> void:
		outcome.network_changes += 1
	)
	return outcome


func _destroy(fixture: Fixture) -> void:
	fixture.host.free()


func _test_edge_health_and_traversal() -> void:
	var raw: HyphaEdge = HyphaEdge.new()
	_check(raw.health == 35.0 and raw.max_health == 35.0 and raw.is_traversable(),
		"New edge is full before ready and without geometry")
	raw.free()
	var unattached: HyphaEdge = EDGE_SCENE.instantiate()
	unattached.max_health = 50.0
	_check(unattached.health == 50.0, "Scene health override is full before ready")
	unattached.take_damage(6.5)
	unattached.max_health = 20.0
	_close(unattached.health, 20.0, "Changing maximum clamps existing health")
	unattached.max_health = NAN
	unattached.max_health = -1.0
	_check(unattached.max_health == 20.0, "Invalid maximum is rejected")
	unattached.free()
	var fixture: Fixture = _fixture()
	var edge: HyphaEdge = fixture.target
	var outcome: Outcome = Outcome.new()
	edge.health_changed.connect(func(_current: float, _maximum: float) -> void:
		outcome.health_changes += 1
	)
	edge.traffic_settings_changed.connect(func() -> void:
		outcome.traffic_changes += 1
	)
	for invalid: float in [0.0, -1.0, NAN, INF, -INF]:
		_check(edge.take_damage(invalid) == 0.0 and edge.restore_health(invalid) == 0.0,
			"Nonpositive and nonfinite edge changes are rejected")
	_check(outcome.health_changes == 0 and outcome.traffic_changes == 0, "Rejected amounts do not emit")
	_close(edge.take_damage(10.0), 10.0, "Partial damage reports actual amount")
	_check(edge.health == 25.0 and edge.is_traversable() and outcome.traffic_changes == 0,
		"Partial injury keeps passage")
	_close(edge.take_damage(100.0), 25.0, "Damage is clamped to available health")
	var broken: Dictionary = edge.get_health_snapshot()
	_keys(broken, ["health", "max_health", "missing_health", "damaged", "broken", "entry_enabled", "traversable", "destroyed", "functional"],
		"Edge snapshot has exact public keys")
	_check(broken["broken"] and not broken["traversable"] and broken["entry_enabled"]
		and outcome.traffic_changes == 1 and fixture.network.is_edge_valid(edge)
		and edge.start_node == fixture.start and edge.end_node == fixture.end
		and edge.traffic_capacity == 2 and not edge.is_queued_for_deletion(), "Zero HP blocks without deleting or retargeting")
	edge.entry_enabled = false
	_close(edge.restore_health(7.0), 7.0, "Broken edge can restore actual health")
	_check(not edge.is_traversable() and outcome.traffic_changes == 1, "Restoration preserves independent legacy closure")
	edge.entry_enabled = true
	_check(edge.is_traversable() and outcome.traffic_changes == 2, "Legacy reopening observes effective traversal")
	_close(edge.restore_health(100.0), 28.0, "Healing is clamped to maximum")
	_check(edge.health == 35.0 and outcome.health_changes == 4 and outcome.traffic_changes == 2,
		"Partial healing emits health without extra traversal transitions")
	_destroy(fixture)


func _test_timed_healing_and_ceil_cost() -> void:
	var fixture: Fixture = _fixture(true, true)
	var outcome: Outcome = _observe(fixture)
	_keys(fixture.repair.get_task_snapshot(), SNAPSHOT_KEYS, "Idle snapshot uses exact contract")
	_check(fixture.repair.request_repair(fixture.target) == 0, "Full edge cannot create a task")
	fixture.target.take_damage(35.0)
	var preview: Dictionary = fixture.repair.preview_repair(fixture.target)
	_keys(preview, PREVIEW_KEYS, "Preview uses exact contract")
	_check(preview["valid"] and preview["estimated_cost"] == 4
		and preview["repair_point"] == fixture.start and preview["supply_reachable"], "Broken 35 HP edge costs four units and prefers start")
	var original_balance: int = fixture.core.nutrition
	var task_id: int = fixture.repair.request_repair(fixture.target)
	var snapshot: Dictionary = fixture.repair.get_task_snapshot()
	_keys(snapshot, SNAPSHOT_KEYS, "Active snapshot uses exact contract")
	_check(task_id > 0 and snapshot["source_core"] == fixture.core and snapshot["edge_id"] == fixture.target.get_instance_id()
		and snapshot["state"] == &"waiting" and snapshot["wait_reason"] == &"nutrition"
		and snapshot["remaining_cost"] == 4 and snapshot["remaining_demand"] == 4,
		"Request captures identity and demand without healing")
	_check(fixture.core.nutrition == original_balance and fixture.repair.request_repair(fixture.target) == 0,
		"Request never charges wallet and rejects overlapping repair")
	_check(not fixture.repair.receive_nutrition(task_id + 1, "wrong-task", 1)
		and not fixture.repair.receive_nutrition(task_id, "", 1)
		and not fixture.repair.receive_nutrition(task_id, "too-much", 5), "Invalid deliveries are rejected")
	_check(fixture.repair.receive_nutrition(task_id, "paid-four", 4), "Arrived funded batch accepted")
	for invalid_delta: float in [0.0, -1.0, NAN, INF]:
		fixture.repair.advance(invalid_delta)
	_check(fixture.target.health == 0.0 and fixture.repair.get_task_snapshot()["consumed_nutrition"] == 0,
		"No positive elapsed step means no consumption")
	fixture.repair.advance(0.25)
	snapshot = fixture.repair.get_task_snapshot()
	_close(fixture.target.health, 2.5, "Healing rate is 10 HP per second")
	_check(snapshot["consumed_nutrition"] == 1 and snapshot["buffered_nutrition"] == 3
		and snapshot["paid_heal_remaining"] == 7.5 and snapshot["remaining_cost"] == 3
		and snapshot["remaining_demand"] == 0 and snapshot["estimated_total_cost"] == 4,
		"First unit commits paid credit and buffer-inclusive remaining cost")
	fixture.repair.advance(0.75)
	_close(fixture.target.health, 10.0, "First paid unit heals at most ten")
	fixture.repair.advance(1.0)
	_close(fixture.target.health, 20.0, "Second unit uses its own second")
	fixture.repair.advance(1.0)
	_close(fixture.target.health, 30.0, "Third unit leaves a fractional last unit")
	fixture.repair.advance(0.49)
	_close(fixture.target.health, 34.9, "Fractional last unit remains timed")
	snapshot = fixture.repair.get_task_snapshot()
	_check(snapshot["consumed_nutrition"] == 4 and snapshot["remaining_cost"] == 0
		and snapshot["buffered_nutrition"] == 0, "Last five HP still consume one integer unit")
	fixture.repair.advance(0.02)
	_close(fixture.target.health, 35.0, "Healing stops at maximum")
	_check(not fixture.repair.has_active_task() and outcome.completions == [task_id]
		and outcome.cancellations.is_empty(), "Completion is emitted once")
	fixture.repair.advance(100.0)
	_check(not fixture.repair.receive_nutrition(task_id, "late", 1)
		and not fixture.repair.cancel_task() and fixture.repair.take_unspent_nutrition(task_id) == 0
		and outcome.completions.size() == 1 and fixture.core.nutrition == original_balance, "Terminal replay neither heals nor pays twice")
	_destroy(fixture)


func _test_fractional_final_unit() -> void:
	for damage: float in [0.25, 10.25, 0.0000001]:
		var fixture: Fixture = _fixture()
		fixture.target.take_damage(damage)
		var cost: int = ceili((fixture.target.max_health - fixture.target.health) / 10.0)
		var task_id: int = fixture.repair.request_repair(fixture.target)
		_check(fixture.repair.get_requested_nutrition(task_id) == cost, "Fractional deficit uses explicit ceil")
		_check(fixture.repair.receive_nutrition(task_id, "fraction", cost), "Fractional repair receives whole units")
		fixture.repair.advance(100.0)
		var snapshot: Dictionary = fixture.repair.get_task_snapshot()
		_check(snapshot["state"] == &"completed" and snapshot["consumed_nutrition"] == cost,
			"Even tiny final deficit consumes the ceil-priced final unit")
		_close(fixture.target.health, 35.0, "Fractional healing reaches full")
		_close(float(snapshot["restored_health"]), damage, "Fractional restoration is accounted", 0.00000001)
		_destroy(fixture)


func _test_pause_resume_and_delivery_ids() -> void:
	var fixture: Fixture = _fixture()
	fixture.target.take_damage(25.0)
	var task_id: int = fixture.repair.request_repair(fixture.target)
	_check(fixture.repair.receive_nutrition(task_id, "first-two", 2), "Initial pause test funding")
	fixture.repair.advance(0.5)
	_check(fixture.repair.pause_task() and not fixture.repair.pause_task(), "Pause is idempotent")
	var before: Dictionary = fixture.repair.get_task_snapshot()
	_check(before["state"] == &"paused" and before["paid_heal_remaining"] == 5.0
		and fixture.repair.get_requested_nutrition(task_id) == 1, "Paused task retains credit and reports demand")
	_check(fixture.repair.receive_nutrition(task_id, "paid-while-paused", 1), "Already paid arrival is accepted during pause")
	_check(not fixture.repair.receive_nutrition(task_id, "paid-while-paused", 1)
		and not fixture.repair.receive_nutrition(task_id, "first-two", 1), "Delivery IDs cannot replay")
	fixture.repair.advance(100.0)
	var paused: Dictionary = fixture.repair.get_task_snapshot()
	_close(fixture.target.health, 15.0, "Paused elapsed time never heals")
	_check(paused["consumed_nutrition"] == 1 and paused["buffered_nutrition"] == 2
		and paused["paid_heal_remaining"] == 5.0 and paused["restored_health"] == 5.0, "Pause retains both kinds of unspent work")
	_check(fixture.repair.resume_task() and not fixture.repair.resume_task(), "Resume is idempotent")
	fixture.repair.advance(0.5)
	_close(fixture.target.health, 20.0, "Resume uses only newly passed time")
	fixture.repair.advance(1.5)
	_check(fixture.target.health == 35.0 and fixture.repair.get_task_snapshot()["consumed_nutrition"] == 3,
		"Resume finishes using retained credit and buffer")
	_destroy(fixture)


func _test_cancel_and_reset_settlement() -> void:
	for operation: StringName in [&"cancel", &"reset"]:
		var fixture: Fixture = _fixture()
		var outcome: Outcome = _observe(fixture)
		fixture.target.take_damage(25.0)
		var task_id: int = fixture.repair.request_repair(fixture.target)
		fixture.repair.receive_nutrition(task_id, "three", 3)
		fixture.repair.advance(0.25)
		if operation == &"cancel":
			_check(fixture.repair.cancel_task(), "Cancel active repair")
		else:
			fixture.repair.reset()
			fixture.repair.reset()
		var snapshot: Dictionary = fixture.repair.get_task_snapshot()
		_close(fixture.target.health, 12.5, "Terminal task retains restored HP")
		_check(snapshot["state"] == &"cancelled" and snapshot["paid_heal_remaining"] == 0.0
			and snapshot["consumed_nutrition"] == 1 and snapshot["buffered_nutrition"] == 2
			and outcome.cancellations == [task_id], "Cancel/reset discard consumed credit but preserve integer buffer once")
		_check(fixture.repair.request_repair(fixture.target) == 0, "Pending settlement prevents a new task")
		_check(fixture.repair.take_unspent_nutrition(task_id) == 2
			and fixture.repair.take_unspent_nutrition(task_id) == 0, "Unconsumed buffer can be drained exactly once")
		var next_id: int = fixture.repair.request_repair(fixture.target)
		_check(next_id > task_id and fixture.repair.get_requested_nutrition(next_id) == 3,
			"New attempt uses monotonic ID and buys fresh credit for remaining HP")
		_check(not fixture.repair.receive_nutrition(task_id, "old", 1), "Old task deliveries cannot fund restart")
		fixture.repair.receive_nutrition(next_id, "new", 1)
		fixture.repair.advance(1.0)
		_close(fixture.target.health, 22.5, "Restart cannot reuse discarded consumed credit")
		_check(fixture.core.nutrition == fixture.core.initial_nutrition, "Repair and buffer settlement never mutate core wallet")
		_destroy(fixture)


func _test_disconnected_point_selection_and_pinning() -> void:
	var fixture: Fixture = _fixture(false, false)
	fixture.target.take_damage(5.0)
	var preview: Dictionary = fixture.repair.preview_repair(fixture.target)
	_check(preview["valid"] and preview["reason"] == &"disconnected" and preview["repair_point"] == null,
		"Damaged disconnected edge can create an unfunded waiting task")
	var task_id: int = fixture.repair.request_repair(fixture.target)
	_check(fixture.repair.get_delivery_target(task_id) == null and not fixture.repair.is_supply_reachable(task_id)
		and not fixture.repair.receive_nutrition(task_id, "no-point", 1), "No endpoint means no delivery or consumption")
	fixture.end_supply = _edge(fixture, fixture.core, fixture.end)
	_check(fixture.repair.get_delivery_target(task_id) == fixture.end
		and fixture.repair.is_supply_reachable(task_id), "Refresh chooses end when start cannot be reached without target")
	fixture.repair.receive_nutrition(task_id, "endpoint-funded", 1)
	fixture.end_supply.entry_enabled = false
	fixture.start_supply = _edge(fixture, fixture.core, fixture.start)
	fixture.repair.advance(100.0)
	var waiting: Dictionary = fixture.repair.get_task_snapshot()
	_check(waiting["state"] == &"waiting" and waiting["wait_reason"] == &"disconnected"
		and waiting["repair_point"] == fixture.end and waiting["buffered_nutrition"] == 1,
		"Chosen point remains pinned even when the other endpoint has a live route")
	_close(fixture.target.health, 30.0, "Disconnected selected point cannot heal")
	fixture.end_supply.entry_enabled = true
	fixture.repair.advance(0.5)
	_check(fixture.target.health == 35.0 and not fixture.repair.has_active_task(), "Reopening original point permits repair")
	_destroy(fixture)


func _test_query_purity_and_original_source() -> void:
	var fixture: Fixture = _fixture()
	var outcome: Outcome = _observe(fixture)
	fixture.target.take_damage(10.0)
	var task_id: int = fixture.repair.request_repair(fixture.target)
	var changes: int = outcome.snapshots.size()
	var network_changes: int = outcome.network_changes
	fixture.core.queue_free()
	for attempt: int in range(5):
		fixture.repair.preview_repair(fixture.target)
		fixture.repair.get_task_snapshot()
		fixture.repair.get_delivery_target(task_id)
		fixture.repair.is_supply_reachable(task_id)
		fixture.repair.get_requested_nutrition(task_id)
	_check(outcome.snapshots.size() == changes and outcome.network_changes == network_changes
		and fixture.repair.has_active_task(), "Pure queries do not prune, cancel, emit, charge or retarget")
	fixture.repair.refresh_access()
	_check(not fixture.repair.has_active_task() and outcome.cancellations == [task_id], "Explicit refresh terminates lost original core")
	_destroy(fixture)


func _test_damage_increases_demand() -> void:
	var fixture: Fixture = _fixture()
	fixture.target.take_damage(15.0)
	var task_id: int = fixture.repair.request_repair(fixture.target)
	fixture.repair.receive_nutrition(task_id, "initial-two", 2)
	fixture.repair.advance(0.5)
	fixture.target.take_damage(20.0)
	var damaged: Dictionary = fixture.repair.get_task_snapshot()
	_check(damaged["initial_cost"] == 2 and damaged["estimated_total_cost"] == 4
		and damaged["paid_heal_remaining"] == 5.0 and damaged["remaining_cost"] == 3
		and damaged["remaining_demand"] == 2 and fixture.repair.get_requested_nutrition(task_id) == 2,
		"New injury increases demand without altering initial quote or paid credit")
	fixture.repair.receive_nutrition(task_id, "extra-two", 2)
	fixture.repair.advance(3.0)
	var completed: Dictionary = fixture.repair.get_task_snapshot()
	_check(completed["state"] == &"completed" and completed["consumed_nutrition"] == 4,
		"Additional damage is healed only by additional arrived funding")
	_close(float(completed["restored_health"]), 35.0, "All restoration, including later damage, is counted")
	_destroy(fixture)


func _test_small_paid_credit_cannot_expand_for_free() -> void:
	var fixture: Fixture = _fixture()
	fixture.target.take_damage(5.0)
	var task_id: int = fixture.repair.request_repair(fixture.target)
	fixture.repair.receive_nutrition(task_id, "five-hp", 1)
	fixture.repair.advance(0.1)
	fixture.target.take_damage(10.0)
	var snapshot: Dictionary = fixture.repair.get_task_snapshot()
	_check(snapshot["paid_heal_remaining"] == 4.0 and snapshot["remaining_demand"] == 1,
		"Unit bought against five missing HP cannot turn into ten after damage")
	fixture.repair.advance(10.0)
	_close(fixture.target.health, 25.0, "Only the original remaining four HP are free of new consumption")
	_check(fixture.repair.get_requested_nutrition(task_id) == 1, "Remaining ten HP still demand a unit")
	fixture.repair.receive_nutrition(task_id, "new-ten", 1)
	fixture.repair.advance(1.0)
	_check(fixture.target.health == 35.0 and fixture.repair.get_task_snapshot()["consumed_nutrition"] == 2,
		"Second unit funds new damage")
	_destroy(fixture)


func _test_target_and_dependency_loss() -> void:
	for operation: StringName in [
		&"unregister_edge", &"free_edge", &"retarget_start", &"retarget_end", &"queue_endpoint",
		&"remove_point", &"dead_core", &"replace_core", &"replace_network", &"remove_network",
	]:
		var fixture: Fixture = _fixture()
		var outcome: Outcome = _observe(fixture)
		fixture.target.take_damage(20.0)
		var task_id: int = fixture.repair.request_repair(fixture.target)
		fixture.repair.receive_nutrition(task_id, "two", 2)
		fixture.repair.advance(0.5)
		var before_health: float = fixture.target.health
		var detached: Node = null
		match operation:
			&"unregister_edge": fixture.network.unregister_edge(fixture.target)
			&"free_edge": fixture.target.free()
			&"retarget_start": fixture.target.start_node = _node(fixture, Vector2(-50.0, 0.0))
			&"retarget_end": fixture.target.end_node = _node(fixture, Vector2(250.0, 0.0))
			&"queue_endpoint": fixture.end.queue_free()
			&"remove_point":
				detached = fixture.start
				fixture.host.remove_child(detached)
			&"dead_core": fixture.core.take_damage(fixture.core.health)
			&"replace_core":
				fixture.network.unregister_node(fixture.core)
				var replacement: MotherCore = CORE_SCENE.instantiate()
				fixture.host.add_child(replacement)
				fixture.network.register_node(replacement, true)
			&"replace_network":
				var replacement: NetworkSystem = NetworkSystem.new()
				fixture.host.add_child(replacement)
				fixture.repair.network_system = replacement
			&"remove_network":
				detached = fixture.network
				fixture.host.remove_child(detached)
		fixture.repair.refresh_access()
		fixture.repair.advance(100.0)
		var terminal: Dictionary = fixture.repair.get_task_snapshot()
		_check(terminal["state"] == &"cancelled" and outcome.cancellations == [task_id]
			and terminal["consumed_nutrition"] == 1 and terminal["paid_heal_remaining"] == 0.0,
			"Permanent loss cancels original task once: " + String(operation))
		if is_instance_valid(fixture.target):
			_close(fixture.target.health, before_health, "Invalid target or source cannot heal: " + String(operation))
		_check(not fixture.repair.receive_nutrition(task_id, "late", 1)
			and fixture.repair.take_unspent_nutrition(task_id) == 1
			and fixture.repair.take_unspent_nutrition(task_id) == 0, "Permanent loss preserves one refundable buffer: " + String(operation))
		if detached != null:
			detached.free()
		_destroy(fixture)


func _test_moving_geometry_keeps_identity() -> void:
	var fixture: Fixture = _fixture()
	fixture.target.take_damage(10.0)
	var task_id: int = fixture.repair.request_repair(fixture.target)
	fixture.repair.receive_nutrition(task_id, "geometry", 1)
	fixture.start.global_position = Vector2(-100.0, 70.0)
	fixture.end.global_position = fixture.start.global_position
	fixture.repair.refresh_access()
	_check(fixture.target.get_length() == 0.0 and fixture.repair.has_active_task()
		and fixture.repair.get_delivery_target(task_id) == fixture.start, "Moving or zero-length geometry retains original identities")
	fixture.repair.advance(1.0)
	_check(fixture.target.health == 35.0, "Geometry movement neither blocks nor accelerates healing")
	_destroy(fixture)


func _test_delivery_notification_reentry() -> void:
	var fixture: Fixture = _fixture()
	fixture.target.take_damage(20.0)
	var trigger: Trigger = Trigger.new()
	trigger.task_id = fixture.repair.request_repair(fixture.target)
	fixture.repair.task_changed.connect(func(snapshot: Dictionary) -> void:
		if trigger.fired or snapshot["task_id"] != trigger.task_id or snapshot["buffered_nutrition"] != 2:
			return
		trigger.fired = true
		_check(not fixture.repair.receive_nutrition(trigger.task_id, "reentrant-paid", 2), "Delivery ID committed before notification")
		fixture.repair.cancel_task()
		trigger.refunded = fixture.repair.take_unspent_nutrition(trigger.task_id)
		trigger.replacement_id = fixture.repair.request_repair(fixture.target)
	)
	_check(fixture.repair.receive_nutrition(trigger.task_id, "reentrant-paid", 2), "Original delivery succeeds despite callback settlement")
	fixture.repair.advance(100.0)
	var replacement: Dictionary = fixture.repair.get_task_snapshot()
	_check(trigger.fired and trigger.refunded == 2 and trigger.replacement_id > trigger.task_id
		and replacement["task_id"] == trigger.replacement_id and replacement["buffered_nutrition"] == 0
		and replacement["consumed_nutrition"] == 0 and fixture.target.health == 15.0,
		"Reentrant delivery cancellation cannot fund or heal its replacement")
	_destroy(fixture)


func _test_healing_notification_reentry() -> void:
	var fixture: Fixture = _fixture()
	var outcome: Outcome = _observe(fixture)
	fixture.target.take_damage(20.0)
	var trigger: Trigger = Trigger.new()
	trigger.task_id = fixture.repair.request_repair(fixture.target)
	fixture.repair.receive_nutrition(trigger.task_id, "reentrant-two", 2)
	fixture.target.health_changed.connect(func(_health: float, _maximum: float) -> void:
		if trigger.fired:
			return
		trigger.fired = true
		trigger.snapshot = fixture.repair.get_task_snapshot()
		fixture.repair.advance(100.0)
		fixture.repair.cancel_task()
		trigger.refunded = fixture.repair.take_unspent_nutrition(trigger.task_id)
		trigger.replacement_id = fixture.repair.request_repair(fixture.target)
		fixture.repair.advance(100.0)
	)
	fixture.repair.advance(0.5)
	var replacement: Dictionary = fixture.repair.get_task_snapshot()
	_check(trigger.snapshot["consumed_nutrition"] == 1 and trigger.snapshot["buffered_nutrition"] == 1
		and trigger.snapshot["paid_heal_remaining"] == 5.0 and trigger.snapshot["restored_health"] == 5.0,
		"Consumed nutrition, credit and restoration are committed before health callback")
	_check(trigger.refunded == 1 and trigger.replacement_id > trigger.task_id
		and replacement["task_id"] == trigger.replacement_id and replacement["consumed_nutrition"] == 0
		and replacement["restored_health"] == 0.0 and outcome.cancellations == [trigger.task_id],
		"Health callback restart receives no write or time from the retired attempt")
	_close(fixture.target.health, 20.0, "Reentered advance cannot heal twice")
	_destroy(fixture)


func _test_completion_notification_restart() -> void:
	var fixture: Fixture = _fixture()
	var outcome: Outcome = _observe(fixture)
	fixture.target.take_damage(5.0)
	var trigger: Trigger = Trigger.new()
	trigger.task_id = fixture.repair.request_repair(fixture.target)
	fixture.repair.receive_nutrition(trigger.task_id, "finish-one", 1)
	fixture.target.health_changed.connect(func(health: float, _maximum: float) -> void:
		if trigger.fired or health < 35.0:
			return
		trigger.fired = true
		fixture.target.take_damage(5.0)
		trigger.replacement_id = fixture.repair.request_repair(fixture.target)
	)
	fixture.repair.advance(100.0)
	var replacement: Dictionary = fixture.repair.get_task_snapshot()
	_check(trigger.fired and trigger.replacement_id > trigger.task_id and outcome.completions == [trigger.task_id]
		and replacement["task_id"] == trigger.replacement_id and replacement["initial_cost"] == 1
		and replacement["consumed_nutrition"] == 0 and fixture.target.health == 30.0,
		"Completing health callback may start a fresh attempt without old completion writes")
	_destroy(fixture)


func _test_terminal_notification_restart() -> void:
	var fixture: Fixture = _fixture()
	var outcome: Outcome = _observe(fixture)
	fixture.target.take_damage(10.0)
	var trigger: Trigger = Trigger.new()
	trigger.task_id = fixture.repair.request_repair(fixture.target)
	fixture.repair.receive_nutrition(trigger.task_id, "cancel-one", 1)
	fixture.repair.task_changed.connect(func(snapshot: Dictionary) -> void:
		if trigger.fired or snapshot["task_id"] != trigger.task_id or snapshot["state"] != &"cancelled":
			return
		trigger.fired = true
		trigger.refunded = fixture.repair.take_unspent_nutrition(trigger.task_id)
		trigger.replacement_id = fixture.repair.request_repair(fixture.target)
	)
	fixture.repair.cancel_task()
	_check(trigger.fired and trigger.refunded == 1 and trigger.replacement_id > trigger.task_id
		and fixture.repair.get_task_snapshot()["task_id"] == trigger.replacement_id
		and outcome.cancellations == [trigger.task_id], "Terminal task notification may settle and restart without stale cancellation")
	_destroy(fixture)


func _growth(fixture: Fixture) -> GrowthSystem:
	var growth: GrowthSystem = GrowthSystem.new()
	growth.network_system = fixture.network
	growth.node_container = fixture.host
	growth.edge_container = fixture.host
	growth.tip_container = fixture.host
	fixture.host.add_child(growth)
	growth.set_physics_process(false)
	return growth


func _advance_to_handoff(growth: GrowthSystem, task_id: int) -> void:
	growth.advance(100.0)
	_check(growth.receive_nutrition(task_id, 9202, growth.get_requested_nutrition(task_id)), "Real junction investment funded")
	growth.advance(0.01)


func _test_real_growth_initial_health_and_handoff() -> void:
	var fixture: Fixture = _fixture()
	var growth: GrowthSystem = _growth(fixture)
	var growth_id: int = growth.create_target(fixture.core, Vector2(360.0, 0.0))
	_check(growth_id > 0, "Real growing edge created")
	var tip: Node2D = growth.get_delivery_target(growth_id)
	var route: NetworkRoute = fixture.network.find_route(fixture.core, tip)
	var edge: HyphaEdge = route.segments[0].edge
	_check(edge.health == 35.0 and edge.get_length() == 0.0 and edge.is_traversable(), "New zero-length growth edge starts full")
	_check(growth.receive_nutrition(growth_id, 9201, growth.get_requested_nutrition(growth_id)), "Real extension investment funded")
	growth.advance(0.5)
	edge.take_damage(20.0)
	var repair_id: int = fixture.repair.request_repair(edge)
	_check(repair_id > 0 and fixture.repair.get_delivery_target(repair_id) == fixture.core,
		"Repair remains independent of active construction and excludes the growing edge")
	fixture.repair.receive_nutrition(repair_id, "growth-repair-two", 2)
	fixture.repair.advance(0.5)
	var former_end_id: int = tip.get_instance_id()
	_advance_to_handoff(growth, growth_id)
	_check(edge.end_node is HyphaNode and edge.end_node != tip
		and fixture.network.get_growth_handoff(edge, former_end_id) == edge.end_node,
		"Growth records a real paid endpoint handoff")
	fixture.repair.refresh_access()
	_check(fixture.repair.has_active_task() and fixture.repair.get_delivery_target(repair_id) == fixture.core,
		"Paid handoff preserves an unaffected pinned work point")
	fixture.repair.advance(1.5)
	_check(edge.health == 35.0 and fixture.repair.get_task_snapshot()["consumed_nutrition"] == 2,
		"Same registered growing edge can finish its funded repair after handoff")
	_destroy(fixture)


func _test_growth_handoff_cannot_move_the_work_point() -> void:
	var fixture: Fixture = _fixture(true, false, true)
	var outcome: Outcome = _observe(fixture)
	var growth: GrowthSystem = _growth(fixture)
	var growth_id: int = growth.create_target(fixture.start, Vector2(460.0, 0.0))
	_check(growth_id > 0, "Point identity test starts growth from a real mature HyphaNode")
	if growth_id <= 0:
		_destroy(fixture)
		return
	var tip: Node2D = growth.get_delivery_target(growth_id)
	_check(growth.receive_nutrition(growth_id, 9201, growth.get_requested_nutrition(growth_id)), "Point identity test extension funded")
	growth.advance(0.5)
	var route: NetworkRoute = fixture.network.find_route(fixture.start, tip)
	_check(route.found and not route.segments.is_empty(), "Point identity test has its real growing edge route")
	if route.segments.is_empty():
		_destroy(fixture)
		return
	var edge: HyphaEdge = route.segments[0].edge
	fixture.start_supply.entry_enabled = false
	_edge(fixture, fixture.core, tip)
	edge.take_damage(10.0)
	var repair_id: int = fixture.repair.request_repair(edge)
	_check(fixture.repair.get_delivery_target(repair_id) == tip, "Only alternate tip endpoint is initially reachable excluding target")
	fixture.repair.receive_nutrition(repair_id, "pinned-tip-unit", 1)
	_advance_to_handoff(growth, growth_id)
	fixture.repair.refresh_access()
	var terminal: Dictionary = fixture.repair.get_task_snapshot()
	_check(terminal["state"] == &"cancelled" and terminal["wait_reason"] == &"repair_point_changed"
		and outcome.cancellations == [repair_id] and terminal["consumed_nutrition"] == 0,
		"Even paid handoff cannot silently move the selected packet delivery point")
	_check(fixture.repair.take_unspent_nutrition(repair_id) == 1
		and fixture.repair.take_unspent_nutrition(repair_id) == 0, "Changed pinned tip refunds only its unconsumed arrival")
	_close(edge.health, 25.0, "Changed repair point never receives healing")
	_destroy(fixture)
