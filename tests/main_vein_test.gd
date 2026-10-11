extends SceneTree
## 单元测试直接构造候选并业务确认，独立验证等级；真实业务结算由集成测试覆盖。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const EDGE_KEYS: Array[String] = [
	"edge_id", "grade", "level", "grade_name", "confirmed_passages", "next_threshold",
	"traffic_capacity", "health", "max_health", "width",
]

class Fixture:
	extends RefCounted

	var world: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var tracker: CargoPassageTracker
	var main: MainVeinSystem
	var first: Node2D
	var second: Node2D
	var third: Node2D
	var edge: HyphaEdge
	var base_width: float = 6.0
	var serial: int = 0
	var progress: Array[Dictionary] = []
	var upgrades: Array[Dictionary] = []
	var traffic_events: Array[Dictionary] = []
	var health_events: Array[Dictionary] = []
	var settings_events: Array[Dictionary] = []
	var triggered: bool = false

var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_thresholds_and_repeats()
	_test_authority_and_two_stage_confirmation()
	_test_batch_and_independent_edges()
	_test_late_binding_and_replay()
	_test_health_and_legacy_setter()
	_test_art_width_and_colors()
	_test_live_fifo_expansion()
	_test_large_fifo_head()
	_test_live_repair_demand()
	_test_source_and_tracker_generations()
	_test_stop_and_reset()
	_test_reentrant_reset_and_stop()
	_test_reentrant_health_and_growth()
	await _test_deleted_edges_and_weak_history()
	_test_enabled_opt_out_and_snapshot_copies()
	_check(root.get_child_count() == initial_children, "Main vein fixtures left root children")
	print("MAIN_VEIN_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) <= 0.000001, message + ": got %s expected %s" % [actual, expected])


func _keys(snapshot: Dictionary, expected: Array[String], message: String) -> void:
	var matching: bool = snapshot.size() == expected.size()
	for key: String in expected:
		matching = matching and snapshot.has(key)
	_check(matching, message)


func _node(fixture: Fixture, point: Vector2) -> Node2D:
	var node: Node2D = Node2D.new()
	fixture.world.add_child(node)
	node.position = point
	_check(fixture.network.register_node(node), "Fixture endpoint registered")
	return node


func _edge(fixture: Fixture, first: Node2D, second: Node2D, width: float = 6.0) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate()
	edge.start_node = first
	edge.end_node = second
	var line: Line2D = edge.get_node("Vein") as Line2D
	line.width = width
	line.default_color = Color(0.31, 0.56, 0.42, 1.0)
	fixture.world.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Fixture edge registered")
	return edge


func _fixture(bind_tracker: bool = true, enroll: bool = true, width: float = 6.0) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.base_width = width
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.first = _node(fixture, Vector2.ZERO)
	fixture.second = _node(fixture, Vector2(100.0, 0.0))
	fixture.third = _node(fixture, Vector2(200.0, 0.0))
	fixture.edge = _edge(fixture, fixture.first, fixture.second, width)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.tracker = CargoPassageTracker.new()
	fixture.world.add_child(fixture.tracker)
	fixture.main = MainVeinSystem.new()
	if bind_tracker:
		fixture.main.cargo_passage_tracker = fixture.tracker
	fixture.world.add_child(fixture.main)
	if enroll:
		_check(fixture.main.register_edge(fixture.edge), "Fixture edge enrolled")
	fixture.main.edge_progress_changed.connect(func(edge: HyphaEdge, snapshot: Dictionary) -> void:
		_check(snapshot == edge.get_vein_snapshot(), "Progress callback sees committed edge state")
		fixture.progress.append(snapshot.duplicate(true))
	)
	fixture.main.edge_upgraded.connect(func(edge: HyphaEdge, previous: int, current: int) -> void:
		fixture.upgrades.append({"edge_id": edge.get_instance_id(), "previous": previous, "current": current})
	)
	fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.traffic_events.append(snapshot.duplicate(true))
	)
	fixture.edge.health_changed.connect(func(current: float, maximum: float) -> void:
		var snapshot: Dictionary = fixture.edge.get_vein_snapshot()
		_check(snapshot["health"] == current and snapshot["max_health"] == maximum,
			"Health callback sees committed health and maximum")
		fixture.health_events.append(snapshot)
	)
	fixture.edge.traffic_settings_changed.connect(func() -> void:
		fixture.settings_events.append(fixture.edge.get_vein_snapshot())
	)
	return fixture


func _destroy(fixture: Fixture) -> void:
	fixture.world.free()


func _prepare(
	fixture: Fixture, cargo_id: String, edge: HyphaEdge = null,
	tracker: CargoPassageTracker = null, kind: StringName = &"supply"
) -> int:
	var source: CargoPassageTracker = fixture.tracker if tracker == null else tracker
	var target: HyphaEdge = fixture.edge if edge == null else edge
	var generation: int = source.register_cargo(cargo_id, kind)
	_check(generation > 0, "Cargo registered: " + cargo_id)
	_check(source.record_candidate(cargo_id, target, generation), "Candidate recorded: " + cargo_id)
	return generation


func _confirm(fixture: Fixture, cargo_id: String, edge: HyphaEdge = null, kind: StringName = &"supply") -> void:
	var generation: int = _prepare(fixture, cargo_id, edge, null, kind)
	_check(fixture.tracker.confirm_cargo(cargo_id, generation), "Cargo business confirmation: " + cargo_id)


func _grow(fixture: Fixture, amount: int, prefix: String = "grow", edge: HyphaEdge = null) -> void:
	for index: int in range(amount):
		fixture.serial += 1
		_confirm(fixture, "%s:%d" % [prefix, fixture.serial], edge)


func _grade(fixture: Fixture, count: int, grade: int, capacity: int, maximum: float, health: float = 35.0) -> void:
	var snapshot: Dictionary = fixture.main.get_edge_snapshot(fixture.edge)
	_keys(snapshot, EDGE_KEYS, "Per-edge snapshot schema")
	_check(snapshot["edge_id"] == fixture.edge.get_instance_id(), "Snapshot edge identity")
	_check(snapshot["confirmed_passages"] == count and snapshot["grade"] == grade
		and snapshot["level"] == grade + 1, "Count and display level: " + str(count))
	_check(snapshot["grade_name"] == HyphaEdge.VEIN_GRADE_NAMES[grade], "Display grade name")
	_check(snapshot["next_threshold"] == (20 if grade == 0 else (60 if grade == 1 else 0)), "Next threshold")
	_check(snapshot["traffic_capacity"] == capacity, "Grade capacity")
	_close(float(snapshot["max_health"]), maximum, "Grade maximum health")
	_close(float(snapshot["health"]), health, "Growth retains absolute health")
	_close(float(snapshot["width"]), fixture.base_width + grade * 2.0, "Grade width")


func _request(fixture: Fixture, key: String, kind: StringName = &"supply", reverse: bool = false) -> Dictionary:
	var owner: Node = Node.new()
	fixture.world.add_child(owner)
	return fixture.traffic.request_passage(
		key, owner, "main-vein:" + key, fixture.edge,
		fixture.second if reverse else fixture.first,
		fixture.first if reverse else fixture.second, kind
	)


func _binding(tracker: CargoPassageTracker, main: MainVeinSystem) -> Callable:
	var callback: Callable = Callable()
	for connection: Dictionary in tracker.passage_confirmed.get_connections():
		var candidate: Callable = connection["callable"]
		if candidate.get_object() == main:
			callback = candidate
	_check(callback.is_valid(), "Captured bound tracker callback")
	return callback


func _test_thresholds_and_repeats() -> void:
	var fixture: Fixture = _fixture()
	_check(MainVeinSystem.Grade.BASIC == 0 and MainVeinSystem.Grade.DEVELOPED == 1
		and MainVeinSystem.Grade.MATURE == 2, "Frozen grade enum")
	_grade(fixture, 0, 0, 2, 35.0)
	_grow(fixture, 19)
	_grade(fixture, 19, 0, 2, 35.0)
	_check(fixture.upgrades.is_empty() and fixture.health_events.is_empty(), "No upgrade below twenty")
	_grow(fixture, 1)
	_grade(fixture, 20, 1, 3, 50.0)
	_grow(fixture, 39)
	_grade(fixture, 59, 1, 3, 50.0)
	_grow(fixture, 1)
	_grade(fixture, 60, 2, 4, 65.0)
	_grow(fixture, 7)
	_grade(fixture, 67, 2, 4, 65.0)
	var event_count: int = fixture.progress.size()
	var generation: int = fixture.tracker.get_generation()
	_check(not fixture.tracker.confirm_cargo("grow:20", generation), "Repeated sealed business confirmation is ignored")
	fixture.tracker.passage_confirmed.emit("grow:20", fixture.edge, generation)
	fixture.main.configure_tracker(fixture.tracker)
	_grade(fixture, 67, 2, 4, 65.0)
	_check(fixture.progress.size() == event_count and fixture.upgrades.size() == 2, "Dedupe remains past maturity and replay")
	_check(fixture.upgrades[0]["previous"] == 0 and fixture.upgrades[0]["current"] == 1
		and fixture.upgrades[1]["previous"] == 1 and fixture.upgrades[1]["current"] == 2,
		"Each crossed grade published once")
	_check(fixture.health_events.size() == 2 and fixture.settings_events.size() == 2,
		"Health and traffic publish only at capability changes")
	evidence["thresholds"] = {"count": 67, "upgrade_events": fixture.upgrades.duplicate(true)}
	_destroy(fixture)


func _test_authority_and_two_stage_confirmation() -> void:
	var fixture: Fixture = _fixture()
	var generation: int = _prepare(fixture, "pending")
	_grade(fixture, 0, 0, 2, 35.0)
	fixture.tracker.passage_confirmed.emit("unknown", fixture.edge, generation)
	fixture.tracker.passage_confirmed.emit("pending", fixture.edge, generation)
	_check(not fixture.tracker.record_candidate("pending", fixture.edge, generation), "Repeated candidate does not duplicate passage")
	_grade(fixture, 0, 0, 2, 35.0)
	_check(fixture.tracker.confirm_cargo("pending", generation), "Accepted pending cargo seals")
	fixture.tracker.passage_confirmed.emit("pending", fixture.edge, generation + 1)
	_grade(fixture, 1, 0, 2, 35.0)
	var discarded_generation: int = _prepare(fixture, "refunded")
	_check(fixture.tracker.discard_cargo("refunded", discarded_generation), "Refunded paid cargo discarded")
	fixture.tracker.passage_confirmed.emit("refunded", fixture.edge, discarded_generation)
	var empty_generation: int = fixture.tracker.register_cargo("empty", &"return")
	_check(fixture.tracker.confirm_cargo("empty", empty_generation), "Accepted cargo with no traversed edge is valid")
	_grade(fixture, 1, 0, 2, 35.0)
	_confirm(fixture, "batch:ten-nutrition", null, &"remains")
	_grade(fixture, 2, 0, 2, 35.0)
	_check(fixture.progress.size() == 2, "Pending, forged, refunded and empty receipts never grow")
	_destroy(fixture)


func _test_batch_and_independent_edges() -> void:
	var fixture: Fixture = _fixture()
	var other: HyphaEdge = _edge(fixture, fixture.second, fixture.third)
	_check(fixture.main.get_edge_snapshot(other).is_empty(), "Formal enrollment remains explicit until receipt")
	var generation: int = _prepare(fixture, "same-cargo-two-edges")
	_check(fixture.tracker.record_candidate("same-cargo-two-edges", other, generation), "Same cargo may traverse a second edge")
	_check(fixture.tracker.confirm_cargo("same-cargo-two-edges", generation), "Batch of candidate edges confirms atomically")
	_grade(fixture, 1, 0, 2, 35.0)
	_check(fixture.main.get_edge_snapshot(other)["confirmed_passages"] == 1, "Valid receipt enrolls previously untracked edge")
	_grow(fixture, 19)
	_grade(fixture, 20, 1, 3, 50.0)
	_check(fixture.main.get_edge_snapshot(other)["grade"] == 0
		and fixture.main.get_edge_snapshot(other)["confirmed_passages"] == 1, "Edge grades do not share counts")
	fixture.network.unregister_edge(fixture.edge)
	_check(fixture.main.register_edge(fixture.edge), "Same live edge can be re-enrolled while detached")
	_check(fixture.network.register_edge(fixture.edge), "Same edge re-enters formal network")
	_grade(fixture, 20, 1, 3, 50.0)
	_check(fixture.upgrades.size() == 1, "Temporary removal does not downgrade or repeat an upgrade")
	_destroy(fixture)


func _test_late_binding_and_replay() -> void:
	var fixture: Fixture = _fixture(false, false)
	_grow(fixture, 65, "late")
	_check(fixture.main.get_edge_snapshot(fixture.edge).is_empty(), "Unbound system has no inferred history")
	_check(fixture.edge.max_health == 35.0 and fixture.edge.traffic_capacity == 2, "Tracker alone never mutates capabilities")
	fixture.main.configure_tracker(fixture.tracker)
	_grade(fixture, 65, 2, 4, 65.0)
	_check(fixture.upgrades.size() == 2 and fixture.progress.size() == 65, "Late observer consumes every unique confirmed pair once")
	fixture.main.configure_tracker(fixture.tracker)
	fixture.main.configure_tracker(fixture.tracker)
	_grade(fixture, 65, 2, 4, 65.0)
	_check(fixture.upgrades.size() == 2 and fixture.progress.size() == 65, "Repeated binding does not duplicate replay")
	_grow(fixture, 1, "late-live")
	_grade(fixture, 66, 2, 4, 65.0)
	_destroy(fixture)


func _test_health_and_legacy_setter() -> void:
	var ordinary: HyphaEdge = HyphaEdge.new()
	ordinary.max_health = 80.0
	_check(ordinary.health == 80.0, "Legacy scene maximum override starts undamaged edge full")
	ordinary.take_damage(10.0)
	ordinary.max_health = 90.0
	_check(ordinary.health == 70.0, "Legacy maximum setter preserves absolute health after damage")
	ordinary.free()
	var fixture: Fixture = _fixture()
	_grow(fixture, 20)
	_grade(fixture, 20, 1, 3, 50.0)
	fixture.edge.take_damage(12.5)
	fixture.edge.entry_enabled = false
	var first_id: int = fixture.edge.start_node.get_instance_id()
	var second_id: int = fixture.edge.end_node.get_instance_id()
	_grow(fixture, 40)
	_grade(fixture, 60, 2, 4, 65.0, 22.5)
	_check(not fixture.edge.entry_enabled and not fixture.edge.is_traversable()
		and fixture.edge.start_node.get_instance_id() == first_id
		and fixture.edge.end_node.get_instance_id() == second_id, "Growth preserves entry flags and topology identities")
	_destroy(fixture)
	fixture = _fixture()
	var cargos: Array[String] = []
	for index: int in range(60):
		var cargo_id: String = "before-break:%d" % index
		_prepare(fixture, cargo_id)
		cargos.append(cargo_id)
	fixture.edge.take_damage(35.0)
	for cargo_id: String in cargos:
		_check(fixture.tracker.confirm_cargo(cargo_id, fixture.tracker.get_generation()), "Previously traversed cargo may settle after break")
	_grade(fixture, 60, 2, 4, 65.0, 0.0)
	_check(not fixture.edge.is_traversable(), "Zero-health growth never reopens edge")
	fixture.main.reset()
	_grade(fixture, 0, 0, 2, 35.0, 0.0)
	evidence["broken_growth"] = {"maximum": 65.0, "health": 0.0, "traversable": false}
	_destroy(fixture)


func _test_art_width_and_colors() -> void:
	var fixture: Fixture = _fixture(true, true, 9.25)
	var line: Line2D = fixture.edge.get_node("Vein") as Line2D
	var open_color: Color = line.default_color
	fixture.edge._process(0.0)
	_check(line.default_color == open_color, "Open art color preserved")
	_grow(fixture, 20)
	fixture.edge._process(0.0)
	_check(line.default_color == Color(0.84, 0.65, 0.34, 1.0), "Existing damaged art color preserved after larger maximum")
	_close(line.width, 11.25, "Width adds two to original scene art")
	fixture.edge.restore_health(15.0)
	fixture.edge._process(0.0)
	_check(line.default_color == open_color, "Fully repaired edge returns to original open color")
	fixture.edge.take_damage(50.0)
	_grow(fixture, 40)
	fixture.edge._process(0.0)
	_close(line.width, 13.25, "Mature width adds four to original scene art")
	_check(line.default_color == Color(0.58, 0.29, 0.22, 0.7), "Broken art color preserved")
	fixture.main.reset()
	fixture.edge._process(0.0)
	_close(line.width, 9.25, "Reset restores captured base width")
	_check(line.default_color == Color(0.58, 0.29, 0.22, 0.7), "Reset does not heal or repaint broken state open")
	_destroy(fixture)


func _test_live_fifo_expansion() -> void:
	var fixture: Fixture = _fixture()
	var first: Dictionary = _request(fixture, "occupied-a")
	var second: Dictionary = _request(fixture, "occupied-b", &"return", true)
	var queued_first: Dictionary = _request(fixture, "queued-a", &"return")
	var queued_second: Dictionary = _request(fixture, "queued-b", &"supply", true)
	var traffic_generation: int = fixture.traffic.get_generation()
	_check(first["state"] == &"granted" and second["state"] == &"granted"
		and queued_first["state"] == &"queued" and queued_second["state"] == &"queued", "Base edge holds two leases and shared-direction FIFO")
	_grow(fixture, 20)
	_check(fixture.traffic.get_request(queued_first["request_id"])["state"] == &"granted"
		and fixture.traffic.get_request(queued_second["request_id"])["state"] == &"queued", "Capacity three drains oldest waiter automatically")
	_check(fixture.traffic.get_lease(first["token"])["request_id"] == first["request_id"]
		and fixture.traffic.get_lease(second["token"])["request_id"] == second["request_id"], "Original occupied lease tokens survive first upgrade")
	_grow(fixture, 40)
	_check(fixture.traffic.get_request(queued_second["request_id"])["state"] == &"granted", "Capacity four drains next original waiter")
	var snapshot: Dictionary = fixture.traffic.get_snapshot()
	_check(snapshot["occupied_units"] == 4 and snapshot["queued_count"] == 0
		and snapshot["active_lease_count"] == 4 and fixture.traffic.get_generation() == traffic_generation,
		"Growth neither cancels traffic nor changes traffic generation")
	var grant_keys: Array[String] = []
	for event: Dictionary in fixture.traffic_events:
		if event["state"] == &"granted":
			grant_keys.append(event["request_key"])
	_check(grant_keys == ["occupied-a", "occupied-b", "queued-a", "queued-b"], "Expanded grants preserve FIFO order exactly")
	evidence["live_fifo"] = {"occupied_units": 4, "granted_order": grant_keys, "generation": traffic_generation}
	_destroy(fixture)


func _test_large_fifo_head() -> void:
	var fixture: Fixture = _fixture()
	var first: Dictionary = _request(fixture, "small-a")
	var second: Dictionary = _request(fixture, "small-b", &"return", true)
	var head: Dictionary = _request(fixture, "large-head", &"remains", true)
	var tail: Dictionary = _request(fixture, "small-tail")
	_grow(fixture, 20)
	_check(fixture.traffic.get_request(head["request_id"])["state"] == &"queued"
		and fixture.traffic.get_request(tail["request_id"])["state"] == &"queued", "Large two-unit FIFO head still blocks one-unit tail at capacity three")
	_grow(fixture, 40)
	_check(fixture.traffic.get_request(head["request_id"])["state"] == &"granted"
		and fixture.traffic.get_request(tail["request_id"])["state"] == &"queued", "Capacity four grants original large head without bypass")
	_check(fixture.traffic.release(first["token"]), "Original occupied token releases normally after maturity")
	_check(fixture.traffic.get_request(tail["request_id"])["state"] == &"granted"
		and not fixture.traffic.get_lease(second["token"]).is_empty(), "Release grants original tail and preserves opposite-direction occupant")
	_destroy(fixture)


func _test_live_repair_demand() -> void:
	var fixture: Fixture = _fixture()
	var core: MotherCore = CORE_SCENE.instantiate()
	fixture.world.add_child(core)
	core.position = Vector2(-100.0, 0.0)
	_check(fixture.network.register_node(core, true), "Repair fixture original mother core registered")
	_edge(fixture, core, fixture.first)
	var repair: RepairSystem = RepairSystem.new()
	repair.network_system = fixture.network
	fixture.world.add_child(repair)
	repair.set_physics_process(false)
	_grow(fixture, 19)
	fixture.edge.take_damage(15.0)
	var task_id: int = repair.request_repair(fixture.edge)
	_check(task_id > 0 and repair.receive_nutrition(task_id, "repair-two", 2), "Repair unit fixture funded two units")
	repair.advance(0.5)
	var before: Dictionary = repair.get_task_snapshot()
	_check(before["health"] == 25.0 and before["paid_heal_remaining"] == 5.0
		and before["consumed_nutrition"] == 1 and before["buffered_nutrition"] == 1, "Repair credit fixture commits partial paid restoration")
	_grow(fixture, 1)
	var after: Dictionary = repair.get_task_snapshot()
	_check(after["task_id"] == task_id and after["max_health"] == 50.0 and after["health"] == 25.0,
		"Normal health_changed updates same active repair to new maximum")
	for key: String in ["initial_cost", "consumed_nutrition", "buffered_nutrition", "paid_heal_remaining", "restored_health"]:
		_check(after[key] == before[key], "Growth preserves committed repair ledger: " + key)
	_check(after["remaining_demand"] == 1 and repair.get_requested_nutrition(task_id) == 1,
		"Larger maximum creates additional paid repair demand")
	repair.advance(100.0)
	_check(fixture.edge.health == 40.0 and repair.has_active_task()
		and repair.get_task_snapshot()["consumed_nutrition"] == 2, "Existing funding cannot freely restore newly added maximum")
	_check(repair.receive_nutrition(task_id, "repair-extra", 1), "New demand accepts new nutrition on original repair task")
	repair.advance(1.0)
	_check(fixture.edge.health == 50.0 and not repair.has_active_task()
		and repair.get_task_snapshot()["consumed_nutrition"] == 3, "Additional funded repair completes exactly once")
	_check(core.nutrition == core.initial_nutrition, "Vein and repair controller never mutate core wallet")
	evidence["repair_maximum_growth"] = {"task_id": task_id, "additional_demand": 1, "consumed_nutrition": 3, "health": 50.0}
	_destroy(fixture)


func _test_source_and_tracker_generations() -> void:
	var fixture: Fixture = _fixture()
	_confirm(fixture, "same-business-id")
	var old_callback: Callable = _binding(fixture.tracker, fixture.main)
	var old_generation: int = _prepare(fixture, "old-source-pending")
	var replacement: CargoPassageTracker = CargoPassageTracker.new()
	fixture.world.add_child(replacement)
	var replacement_generation: int = _prepare(fixture, "same-business-id", null, replacement)
	_check(replacement.confirm_cargo("same-business-id", replacement_generation), "Replacement source owns an independent confirmed identity")
	fixture.main.configure_tracker(replacement)
	_grade(fixture, 2, 0, 2, 35.0)
	_check(fixture.tracker.confirm_cargo("old-source-pending", old_generation), "Old source may settle its own ledger")
	old_callback.call("old-source-pending", fixture.edge, old_generation)
	fixture.tracker.passage_confirmed.emit("old-source-pending", fixture.edge, old_generation)
	_grade(fixture, 2, 0, 2, 35.0)
	fixture.main.configure_tracker(replacement)
	_grade(fixture, 2, 0, 2, 35.0)
	var replacement_callback: Callable = _binding(replacement, fixture.main)
	replacement.reset()
	_check(replacement.get_generation() > replacement_generation, "Tracker reset advances its generation")
	replacement_callback.call("same-business-id", fixture.edge, replacement_generation)
	_grade(fixture, 2, 0, 2, 35.0)
	var new_generation: int = _prepare(fixture, "same-business-id", null, replacement)
	_check(replacement.confirm_cargo("same-business-id", new_generation), "New generation may own genuinely new identity")
	_grade(fixture, 3, 0, 2, 35.0)
	fixture.main.configure_tracker(null)
	var detached_generation: int = _prepare(fixture, "detached-source", null, replacement)
	_check(replacement.confirm_cargo("detached-source", detached_generation), "Detached tracker remains independent")
	replacement_callback.call("detached-source", fixture.edge, detached_generation)
	_grade(fixture, 3, 0, 2, 35.0)
	_destroy(fixture)


func _test_stop_and_reset() -> void:
	var fixture: Fixture = _fixture()
	_grow(fixture, 60)
	fixture.edge.restore_health(30.0)
	fixture.edge.take_damage(5.0)
	var old_callback: Callable = _binding(fixture.tracker, fixture.main)
	var tracker_generation: int = fixture.tracker.get_generation()
	var main_generation: int = int(fixture.main.get_snapshot()["generation"])
	fixture.main.stop()
	_grow(fixture, 3, "stopped")
	_grade(fixture, 60, 2, 4, 65.0, 60.0)
	_check(fixture.main.get_snapshot()["stopped"], "Death stop retains grade and health while freezing consumption")
	fixture.main.configure_tracker(fixture.tracker)
	_grade(fixture, 60, 2, 4, 65.0, 60.0)
	fixture.traffic.reset()
	fixture.main.reset()
	_grade(fixture, 0, 0, 2, 35.0, 35.0)
	_check(not fixture.main.get_snapshot()["stopped"]
		and fixture.tracker.get_generation() > tracker_generation
		and fixture.main.get_snapshot()["generation"] > main_generation, "Restart invalidates both sources and resumes a fresh cycle")
	old_callback.call("grow:20", fixture.edge, tracker_generation)
	fixture.tracker.passage_confirmed.emit("grow:60", fixture.edge, tracker_generation)
	_grade(fixture, 0, 0, 2, 35.0, 35.0)
	fixture.edge.take_damage(10.0)
	_grow(fixture, 20, "new-cycle")
	_grade(fixture, 20, 1, 3, 50.0, 25.0)
	fixture.main.reset()
	_grade(fixture, 0, 0, 2, 35.0, 25.0)
	_destroy(fixture)


func _test_reentrant_reset_and_stop() -> void:
	var fixture: Fixture = _fixture()
	_grow(fixture, 19)
	var stale_generation: int = _prepare(fixture, "late-after-reset")
	fixture.main.edge_progress_changed.connect(func(_edge_value: HyphaEdge, snapshot: Dictionary) -> void:
		if not fixture.triggered and snapshot["confirmed_passages"] == 20:
			fixture.triggered = true
			fixture.main.reset()
	)
	_grow(fixture, 1)
	_check(fixture.triggered and fixture.upgrades.is_empty(), "Progress callback reset invalidates queued upgrade publication")
	_grade(fixture, 0, 0, 2, 35.0)
	_check(not fixture.tracker.confirm_cargo("late-after-reset", stale_generation), "Old business callback cannot confirm new cycle")
	_grow(fixture, 20, "after-reentrant-reset")
	_grade(fixture, 20, 1, 3, 50.0)
	_destroy(fixture)
	fixture = _fixture()
	_grow(fixture, 19)
	fixture.edge.health_changed.connect(func(_health: float, maximum: float) -> void:
		if maximum == 50.0 and not fixture.triggered:
			fixture.triggered = true
			fixture.main.stop()
	)
	_grow(fixture, 1)
	_check(fixture.triggered and fixture.upgrades.is_empty()
		and fixture.progress.size() == 19, "Health observer stop suppresses queued main notifications")
	_grade(fixture, 20, 1, 3, 50.0)
	_grow(fixture, 40, "after-stop")
	_grade(fixture, 20, 1, 3, 50.0)
	_destroy(fixture)


func _test_reentrant_health_and_growth() -> void:
	var fixture: Fixture = _fixture()
	_grow(fixture, 19)
	fixture.edge.health_changed.connect(func(_health: float, maximum: float) -> void:
		if fixture.triggered or maximum != 50.0:
			return
		fixture.triggered = true
		var snapshot: Dictionary = fixture.main.get_edge_snapshot(fixture.edge)
		_check(snapshot["grade"] == 1 and snapshot["confirmed_passages"] == 20
			and snapshot["traffic_capacity"] == 3 and snapshot["width"] == 8.0,
			"Health observer sees grade, count, capacity and width committed together")
		fixture.edge.take_damage(4.0)
		_confirm(fixture, "reentrant-extra")
	)
	_grow(fixture, 1)
	_grade(fixture, 21, 1, 3, 50.0, 31.0)
	_check(fixture.upgrades.size() == 1 and fixture.progress.size() == 21, "Reentrant business confirmation counts each cargo once")
	_check(fixture.settings_events.size() == 1, "Nested callback keeps original expansion publication")
	_destroy(fixture)
	fixture = _fixture(false)
	_grow(fixture, 20, "late-reentrant")
	var occupied_a: Dictionary = _request(fixture, "late-occupied-a")
	var occupied_b: Dictionary = _request(fixture, "late-occupied-b")
	var waiter: Dictionary = _request(fixture, "late-waiter")
	fixture.edge.health_changed.connect(func(_health: float, maximum: float) -> void:
		if fixture.triggered or maximum != 50.0:
			return
		fixture.triggered = true
		_confirm(fixture, "late-health-extra")
	)
	fixture.main.configure_tracker(fixture.tracker)
	_grade(fixture, 21, 1, 3, 50.0)
	_check(fixture.settings_events.size() == 1
		and fixture.traffic.get_request(waiter["request_id"])["state"] == &"granted",
		"Synchronous same-grade confirmation during replay cannot swallow original FIFO expansion")
	_check(not fixture.traffic.get_lease(occupied_a["token"]).is_empty()
		and not fixture.traffic.get_lease(occupied_b["token"]).is_empty(), "Reentrant replay preserves original occupants")
	_destroy(fixture)


func _test_deleted_edges_and_weak_history() -> void:
	var fixture: Fixture = _fixture()
	_grow(fixture, 20)
	var reference: WeakRef = weakref(fixture.edge)
	var deleted_id: int = fixture.edge.get_instance_id()
	fixture.edge.free()
	fixture.edge = null
	_check(reference.get_ref() == null and fixture.main.get_snapshot()["edges"].is_empty(), "Tracker and vein history do not keep deleted edge alive")
	_check(fixture.tracker.get_confirmed_passages().is_empty(), "Deleted confirmed edges omitted by tracker authority")
	_check(fixture.main.get_edge_snapshot(null).is_empty() and not fixture.main.register_edge(null), "Invalid edge APIs remain harmless")
	evidence["weak_history"] = {"deleted_edge_id": deleted_id, "remaining_edges": 0}
	_destroy(fixture)
	fixture = _fixture()
	var generation: int = _prepare(fixture, "delete-before-confirm")
	fixture.edge.queue_free()
	_check(fixture.main.get_snapshot()["edges"].is_empty(), "Queued deletion omitted before destruction")
	_check(fixture.tracker.confirm_cargo("delete-before-confirm", generation), "Cargo settlement remains valid after its edge is deleted")
	_check(fixture.progress.is_empty() and fixture.upgrades.is_empty(), "Deleted candidate never grows an edge")
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.edge), "Queued edge actually freed without retained strong history")
	fixture.edge = null
	_destroy(fixture)


func _test_enabled_opt_out_and_snapshot_copies() -> void:
	var fixture: Fixture = _fixture()
	fixture.main.enabled = false
	_grow(fixture, 20, "disabled")
	_grade(fixture, 0, 0, 2, 35.0)
	_check(fixture.progress.is_empty(), "Explicit opt out ignores confirmations")
	var custom: HyphaEdge = _edge(fixture, fixture.second, fixture.third, 10.0)
	custom.max_health = 80.0
	custom.traffic_capacity = 7
	_check(fixture.main.register_edge(custom) and custom.max_health == 80.0
		and custom.health == 80.0 and custom.traffic_capacity == 7, "Disabled enrollment preserves standalone legacy capabilities")
	fixture.main.enabled = true
	fixture.main.configure_tracker(fixture.tracker)
	_grade(fixture, 20, 1, 3, 50.0)
	var snapshot: Dictionary = fixture.main.get_snapshot()
	_keys(snapshot, ["enabled", "stopped", "generation", "edges"], "System snapshot schema")
	var row: Dictionary = fixture.main.get_edge_snapshot(fixture.edge)
	row["confirmed_passages"] = 9999
	row["grade"] = 2
	var rows: Array = snapshot["edges"]
	rows[0]["traffic_capacity"] = 9999
	rows.clear()
	var progress_count: int = fixture.progress.size()
	for attempt: int in range(5):
		fixture.main.get_snapshot()
		fixture.main.get_edge_snapshot(fixture.edge)
		fixture.edge.get_vein_snapshot()
	_grade(fixture, 20, 1, 3, 50.0)
	_check(fixture.main.get_snapshot()["edges"].size() == 2 and fixture.progress.size() == progress_count,
		"Snapshot mutation and pure queries cannot mutate history or emit signals")
	_destroy(fixture)
