extends SceneTree
## 独立提示契约夹具：阈值通过 record_arrival 构造，资源用只读快照夹具，
## 主脉等级通过已登记边的局部状态构造；不代表采集、物理运输或完整经济闭环。
## 胃室扩建使用生产场景的真实 3 秒物理计时器；完整闭环另由 progression_cycle_test 验证。

class ResourceAccessFixture:
	extends Node

	signal resource_access_changed(resource_index: int, connected: bool)

	var _resources: Array[Dictionary] = [
		{"index": 1, "resource_id": "hint_fixture:first", "connected": false,
			"position": Vector2(1030, 450), "recommended_target": Vector2(970, 440),
			"remaining_nutrition": 80, "harvested_nutrition": 0},
		{"index": 2, "resource_id": "hint_fixture:second", "connected": false,
			"position": Vector2(110, 460), "recommended_target": Vector2(180, 450),
			"remaining_nutrition": 120, "harvested_nutrition": 0},
	]

	func get_resource_access_snapshot() -> Array[Dictionary]:
		return _resources.duplicate(true)

	func set_connected(index: int, connected: bool, notify: bool = true) -> void:
		for resource: Dictionary in _resources:
			if int(resource["index"]) == index and bool(resource["connected"]) != connected:
				resource["connected"] = connected
				if notify:
					resource_access_changed.emit(index, connected)

class Fixture:
	extends RefCounted

	var host: Node2D
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var queue: ConstructionQueue
	var coordinator: ConstructionCoordinator
	var stomach: DigestiveOrgan
	var veins: MainVeinSystem
	var edge: HyphaEdge
	var resources: ResourceAccessFixture
	var controller: ProgressionHintController
	var events: Array[Dictionary] = []

const HINT_SCRIPT: GDScript = preload("res://scripts/progression_hint_controller.gd")
const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const EXPECTED_IDS: Array[StringName] = [
	&"first_resource_connected", &"expanded", &"two_tips_available",
	&"second_resource_connected", &"mature", &"second_chamber_ready",
	&"first_vein_upgrade",
]

var failures: Array[String] = []
var checks: int = 0
var evidence: Array[Dictionary] = []
var _hosts: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_false_payloads_and_snapshot_copies()
	_test_read_only_and_idempotent_configuration()
	_test_two_tips_require_all_authorities()
	_test_stale_pending_and_visible_queries()
	_test_reentrant_queue_and_dismiss()
	_test_reentrant_disable()
	_test_reentrant_reset_generation()
	_test_replacement_and_retired_callbacks()
	_test_reset_and_fresh_scene_defaults()
	_test_exit_requires_explicit_configuration()
	await _test_queued_and_freed_sources()
	var muted: Fixture = _prepare_disabled_playthrough()
	await _test_all_seven_and_real_expansion()
	_test_disabled_playthrough_has_no_historical_flood(muted)
	_test_enable_samples_silent_disabled_changes()
	_free_fixtures()
	await process_frame
	await process_frame
	_check(root.get_child_count() == initial_children, "Hint tests left fixture nodes in the tree")
	print("PROGRESSION_HINT_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
		"fixture_scope": "isolated_hint_contract; constructed_thresholds_and_resource_snapshots; real_chamber_timer",
		"full_cycle_test": "res://tests/progression_cycle_test.gd",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _new_fixture(configure_now: bool = true) -> Fixture:
	var fixture := Fixture.new()
	fixture.host = Node2D.new()
	_hosts.append(weakref(fixture.host))
	root.add_child(fixture.host)
	fixture.progress = ColonyProgress.new()
	fixture.host.add_child(fixture.progress)
	fixture.capabilities = ColonyCapabilities.new()
	fixture.capabilities.colony_progress = fixture.progress
	fixture.host.add_child(fixture.capabilities)
	fixture.queue = ConstructionQueue.new()
	fixture.queue.capabilities = fixture.capabilities
	fixture.queue.multi_execution = true
	fixture.host.add_child(fixture.queue)
	fixture.coordinator = ConstructionCoordinator.new()
	fixture.coordinator.queue = fixture.queue
	fixture.coordinator.multi_worker_enabled = true
	fixture.coordinator.auto_execute = false
	fixture.host.add_child(fixture.coordinator)
	fixture.stomach = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	fixture.stomach.colony_capabilities = fixture.capabilities
	fixture.host.add_child(fixture.stomach)
	fixture.veins = MainVeinSystem.new()
	fixture.host.add_child(fixture.veins)
	var first_endpoint := Node2D.new()
	var second_endpoint := Node2D.new()
	second_endpoint.position = Vector2(100, 0)
	fixture.host.add_child(first_endpoint)
	fixture.host.add_child(second_endpoint)
	fixture.edge = HyphaEdge.new()
	fixture.edge.start_node = first_endpoint
	fixture.edge.end_node = second_endpoint
	var line := Line2D.new()
	line.name = "Vein"
	fixture.edge.add_child(line)
	fixture.host.add_child(fixture.edge)
	_check(fixture.veins.register_edge(fixture.edge), "Local hint fixture registered its live edge")
	fixture.resources = ResourceAccessFixture.new()
	fixture.host.add_child(fixture.resources)
	fixture.controller = HINT_SCRIPT.new() as ProgressionHintController
	fixture.host.add_child(fixture.controller)
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.events.append(snapshot.duplicate(true))
		_check_snapshot_shape(snapshot, "Hint notification")
		if snapshot["visible"] and snapshot["id"] == &"second_chamber_ready":
			var digestion: Dictionary = fixture.stomach.get_digestion_snapshot()
			_check(digestion["expansion_state"] == &"ready" and digestion["chamber_count"] == 2,
				"A visible chamber hint claimed readiness without an actual ready stomach")
	)
	if configure_now:
		_configure(fixture)
	return fixture


func _configure(fixture: Fixture, source_fixture: Fixture = null) -> void:
	var sources: Fixture = source_fixture if source_fixture != null else fixture
	fixture.controller.configure(sources.progress, sources.capabilities, sources.coordinator,
		sources.stomach, sources.veins, sources.resources)


func _check_snapshot_shape(snapshot: Dictionary, context: String) -> void:
	_check(snapshot.has_all(["enabled", "visible", "id", "text", "pending_count", "seen_ids", "generation"]),
		context + ": required public fields")
	_check(snapshot.get("enabled") is bool and snapshot.get("visible") is bool
		and snapshot.get("id") is StringName and snapshot.get("text") is String
		and snapshot.get("pending_count") is int and snapshot.get("seen_ids") is Array
		and snapshot.get("generation") is int, context + ": public field types")
	_check(int(snapshot.get("pending_count", -1)) >= 0, context + ": negative pending count")
	if bool(snapshot.get("visible", false)):
		_check(EXPECTED_IDS.has(snapshot["id"]) and not String(snapshot["text"]).is_empty(),
			context + ": visible hint outside the seven allowed IDs")
	else:
		_check(snapshot.get("id", &"") == &"" and snapshot.get("text", "") == "",
			context + ": hidden hint retained display text")


func _drain(fixture: Fixture) -> Array[StringName]:
	var shown: Array[StringName] = []
	var guard: int = 0
	while bool(fixture.controller.get_snapshot()["visible"]) and guard < 8:
		var snapshot: Dictionary = fixture.controller.get_snapshot()
		shown.append(snapshot["id"])
		fixture.controller.dismiss_current()
		guard += 1
	_check(not fixture.controller.get_snapshot()["visible"]
		and fixture.controller.get_snapshot()["pending_count"] == 0, "Dismissal did not drain the bounded hint queue")
	return shown


func _capture_callback(source: Node, signal_name: StringName, controller: ProgressionHintController) -> Callable:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in source.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == controller:
			callbacks.append(callback)
	_check(callbacks.size() == 1, "Expected exactly one hint binding for %s" % signal_name)
	return callbacks[0] if not callbacks.is_empty() else Callable()


func _connection_count(source: Node, signal_name: StringName, controller: ProgressionHintController) -> int:
	var count: int = 0
	for connection: Dictionary in source.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == controller:
			count += 1
	return count


func _emit_duplicates(fixture: Fixture) -> void:
	fixture.resources.resource_access_changed.emit(1, true)
	fixture.resources.resource_access_changed.emit(2, true)
	fixture.progress.progress_changed.emit(999, 999)
	fixture.progress.stage_changed.emit(ColonyProgress.Stage.NASCENT, ColonyProgress.Stage.MATURE)
	fixture.progress.stage_unlocked.emit(ColonyProgress.Stage.MATURE)
	fixture.coordinator.changed.emit({"tip_limit": 2, "tip_count": 2})
	fixture.stomach.digestion_changed.emit({"expansion_state": &"ready", "chamber_count": 2})
	fixture.veins.edge_upgraded.emit(fixture.edge, 0, 2)


func _world_snapshot(fixture: Fixture) -> Dictionary:
	return {
		"recovered": fixture.progress.get_total_recovered(), "products": fixture.progress.get_product_count(),
		"stage": fixture.progress.get_stage(), "requests": fixture.queue.get_all_requests(),
		"queue": fixture.queue.get_snapshot(), "construction": fixture.coordinator.get_resource_snapshot(),
		"digestion": fixture.stomach.get_digestion_snapshot(), "output": fixture.stomach.get_output_snapshot(),
		"veins": fixture.veins.get_snapshot(), "resources": fixture.resources.get_resource_access_snapshot(),
		"paused": paused,
	}


func _upgrade_isolated_edge(fixture: Fixture) -> void:
	# 只构造已登记边的权威等级用于观察器契约，不伪称实际运输促成升级。
	fixture.edge.apply_vein_growth(1, HyphaEdge.VEIN_THRESHOLDS[0])
	fixture.veins.edge_upgraded.emit(fixture.edge, 0, 1)


func _test_false_payloads_and_snapshot_copies() -> void:
	var fixture: Fixture = _new_fixture()
	var before: Dictionary = _world_snapshot(fixture)
	var event_count: int = fixture.events.size()
	_emit_duplicates(fixture)
	_check(fixture.events.size() == event_count and not fixture.controller.get_snapshot()["visible"]
		and fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Signal payloads fabricated a hint without authoritative state")
	_check(_world_snapshot(fixture) == before, "False hint callbacks changed authoritative world state")
	var copied: Dictionary = fixture.controller.get_snapshot()
	copied["seen_ids"].append(&"mature")
	copied["id"] = &"mature"
	copied["text"] = "changed outside controller"
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty()
		and fixture.controller.get_snapshot()["id"] == &"", "Public hint snapshot exposed mutable controller state")


func _test_read_only_and_idempotent_configuration() -> void:
	var fixture: Fixture = _new_fixture(false)
	var before: Dictionary = _world_snapshot(fixture)
	_configure(fixture)
	var generation: int = fixture.controller.get_snapshot()["generation"]
	var event_count: int = fixture.events.size()
	_configure(fixture)
	_check(fixture.controller.get_snapshot()["generation"] == generation and fixture.events.size() == event_count,
		"Same-source configuration restarted or republished the playthrough")
	for signal_name: StringName in [&"progress_changed", &"stage_changed", &"stage_unlocked"]:
		_check(_connection_count(fixture.progress, signal_name, fixture.controller) == 1,
			"Idempotent configure duplicated a progress signal binding")
	fixture.controller.dismiss_current()
	fixture.controller.set_hints_enabled(false)
	fixture.controller.set_hints_enabled(false)
	fixture.controller.set_hints_enabled(true)
	fixture.controller._process(0.0)
	_check(_world_snapshot(fixture) == before, "Configure/query/dismiss/toggle mutated game state or paused the tree")
	evidence.append({"case": "read_only_controller", "world_snapshot_unchanged": true,
		"initial_recovered": 0, "construction_requests": 0, "tree_paused": false})


func _test_two_tips_require_all_authorities() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.coordinator.multi_worker_enabled = false
	_check(fixture.progress.record_arrival("isolated:tip_gate", 60), "Constructed expanded tip fixture")
	_check(_drain(fixture) == [&"expanded"], "Expanded stage claimed two tips while multi-worker mode was disabled")
	fixture.coordinator.multi_worker_enabled = true
	fixture.queue.capabilities = null
	fixture.coordinator.changed.emit({"tip_limit": 2})
	_check(not fixture.controller.get_snapshot()["visible"], "Two-tip hint trusted capabilities while actual queue limit was one")
	var alternate_capabilities := ColonyCapabilities.new()
	alternate_capabilities.colony_progress = fixture.progress
	fixture.host.add_child(alternate_capabilities)
	fixture.queue.capabilities = alternate_capabilities
	fixture.capabilities.colony_progress = null
	fixture.coordinator.changed.emit({"tip_limit": 2})
	_check(fixture.coordinator.get_snapshot()["tip_limit"] == 2
		and not fixture.controller.get_snapshot()["visible"], "Two-tip hint ignored the provided capability source")
	fixture.capabilities.colony_progress = fixture.progress
	fixture.queue.capabilities = fixture.capabilities
	fixture.coordinator.changed.emit({"tip_limit": 0})
	var snapshot: Dictionary = fixture.controller.get_snapshot()
	_check(snapshot["id"] == &"two_tips_available" and fixture.coordinator.get_snapshot()["tip_count"] == 0
		and String(snapshot["text"]).contains("允许 2"), "Two-tip hint did not describe permitted capacity independently of active tips")
	_check(_drain(fixture) == [&"two_tips_available"], "Valid two-tip hint was not exactly once")


func _test_stale_pending_and_visible_queries() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.resources.set_connected(1, true)
	_check(fixture.progress.record_arrival("isolated:stale_queue", 60), "Constructed queued tip fixture")
	fixture.resources.set_connected(2, true)
	_check(fixture.controller.get_snapshot()["pending_count"] == 3, "Initial queued hint count")
	fixture.coordinator.multi_worker_enabled = false
	fixture.coordinator.changed.emit({"tip_limit": 2})
	fixture.resources.set_connected(2, false)
	_check(fixture.controller.get_snapshot()["pending_count"] == 1, "Stale capability/resource hints remained pending")
	_check(_drain(fixture) == [&"first_resource_connected", &"expanded"], "Presentation revived unavailable queued hints")
	fixture.coordinator.multi_worker_enabled = true
	fixture.resources.set_connected(2, true)
	_check(not fixture.controller.get_snapshot()["visible"], "Dropped first-time hints flooded after their conditions returned")
	var current: Fixture = _new_fixture()
	current.resources.set_connected(1, true)
	current.resources.set_connected(1, false, false)
	_check(not current.controller.get_snapshot()["visible"] and current.controller.get_snapshot()["text"] == "",
		"Read-only snapshot claimed current access after silent disconnection")
	current.controller._process(0.0)
	current.resources.set_connected(1, true)
	_check(not current.controller.get_snapshot()["visible"], "Current access hint repeated after disconnection/reconnection")


func _test_reentrant_queue_and_dismiss() -> void:
	var fixture: Fixture = _new_fixture()
	var shown: Array[StringName] = []
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		_check(snapshot == fixture.controller.get_snapshot(), "Reentrant notification published an obsolete snapshot")
		if snapshot["visible"]:
			shown.append(snapshot["id"])
			if snapshot["id"] == &"first_resource_connected":
				_check(fixture.progress.record_arrival("isolated:reentrant", 60), "Reentrant threshold fixture")
				fixture.resources.set_connected(2, true)
				_emit_duplicates(fixture)
			fixture.controller.dismiss_current()
	)
	fixture.resources.set_connected(1, true)
	_check(shown == [&"first_resource_connected", &"expanded", &"two_tips_available", &"second_resource_connected"],
		"Queued synchronous callbacks repeated, reopened, or reordered first-time hints")
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["seen_ids"].size() == 4,
		"Reentrant dismiss did not commit all four hint identities before notification")
	var event_count: int = fixture.events.size()
	_emit_duplicates(fixture)
	_check(fixture.events.size() == event_count, "Duplicate callbacks republished dismissed hints")
	evidence.append({"case": "queued_reentrancy", "shown_ids": shown, "duplicates_republished": false})


func _test_reentrant_disable() -> void:
	var fixture: Fixture = _new_fixture()
	var visible_ids: Array[StringName] = []
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["visible"]:
			visible_ids.append(snapshot["id"])
			if snapshot["id"] == &"first_resource_connected":
				fixture.progress.record_arrival("isolated:disable_reentrant", 60)
				fixture.controller.set_hints_enabled(false)
				fixture.resources.set_connected(2, true)
	)
	fixture.resources.set_connected(1, true)
	_check(visible_ids == [&"first_resource_connected"] and not fixture.controller.get_snapshot()["enabled"]
		and fixture.controller.get_snapshot()["seen_ids"].size() == 4, "Reentrant disable emitted old queued hints or forgot disabled occurrences")
	fixture.controller.set_hints_enabled(true)
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["pending_count"] == 0,
		"Reentrant re-enable flooded queued history")


func _test_reentrant_reset_generation() -> void:
	var fixture: Fixture = _new_fixture()
	var retired: Callable = _capture_callback(fixture.resources, &"resource_access_changed", fixture.controller)
	var old_generation: int = fixture.controller.get_snapshot()["generation"]
	var did_reset: Array[bool] = [false]
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["visible"] and snapshot["id"] == &"first_resource_connected" and not did_reset[0]:
			did_reset[0] = true
			fixture.progress.record_arrival("isolated:before_reset", 60)
			fixture.controller.reset()
			fixture.progress.reset()
			fixture.resources.set_connected(1, false)
			_configure(fixture)
			fixture.resources.set_connected(2, true)
	)
	fixture.resources.set_connected(1, true)
	var snapshot: Dictionary = fixture.controller.get_snapshot()
	_check(did_reset[0] and snapshot["generation"] > old_generation
		and snapshot["id"] == &"second_resource_connected"
		and snapshot["seen_ids"] == [&"second_resource_connected"], "Reset inside publication mixed old and new playthrough state")
	for event: Dictionary in fixture.events:
		_check(not event["visible"] or not [&"expanded", &"two_tips_available"].has(event["id"]),
			"Reset delivered an old generation's queued expansion hint")
	fixture.resources.set_connected(1, true, false)
	if retired.is_valid():
		retired.call(1, true)
	_check(fixture.controller.get_snapshot()["seen_ids"] == [&"second_resource_connected"],
		"Pre-reset callback entered the same sources' new generation")
	fixture.resources.resource_access_changed.emit(1, true)
	_check(_drain(fixture) == [&"second_resource_connected", &"first_resource_connected"],
		"New-generation resource callback could not queue its own first-time hint")


func _test_replacement_and_retired_callbacks() -> void:
	var old: Fixture = _new_fixture()
	var fresh: Fixture = _new_fixture(false)
	var retired: Callable = _capture_callback(old.resources, &"resource_access_changed", old.controller)
	old.resources.set_connected(1, true)
	var old_generation: int = old.controller.get_snapshot()["generation"]
	_configure(old, fresh)
	_check(old.controller.get_snapshot()["generation"] > old_generation
		and old.controller.get_snapshot()["seen_ids"].is_empty(), "Replacing sources retained the previous playthrough")
	_check(_connection_count(old.resources, &"resource_access_changed", old.controller) == 0
		and _connection_count(old.progress, &"stage_changed", old.controller) == 0
		and _connection_count(old.coordinator, &"changed", old.controller) == 0
		and _connection_count(old.stomach, &"digestion_changed", old.controller) == 0
		and _connection_count(old.veins, &"edge_upgraded", old.controller) == 0,
		"Replacing sources left old signal subscriptions")
	fresh.resources.set_connected(1, true, false)
	old.progress.record_arrival("isolated:retired_source", 160)
	if retired.is_valid():
		retired.call(1, true)
	_check(not old.controller.get_snapshot()["visible"], "Retired source or captured callback published into replacement sources")
	fresh.resources.resource_access_changed.emit(1, true)
	_check(old.controller.get_snapshot()["id"] == &"first_resource_connected", "Replacement source was not observed")
	var generation: int = old.controller.get_snapshot()["generation"]
	_configure(old, fresh)
	_check(old.controller.get_snapshot()["generation"] == generation
		and _connection_count(fresh.resources, &"resource_access_changed", old.controller) == 1,
		"Repeated replacement configuration duplicated its binding")


func _test_reset_and_fresh_scene_defaults() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.resources.set_connected(1, true)
	fixture.controller.set_hints_enabled(false)
	var old_generation: int = fixture.controller.get_snapshot()["generation"]
	fixture.controller.reset()
	var snapshot: Dictionary = fixture.controller.get_snapshot()
	_check(snapshot["enabled"] and not snapshot["visible"] and snapshot["pending_count"] == 0
		and snapshot["seen_ids"].is_empty() and snapshot["generation"] > old_generation,
		"Reset did not clear hints, advance generation, and restore enabled defaults")
	_check(_connection_count(fixture.progress, &"progress_changed", fixture.controller) == 0
		and _connection_count(fixture.progress, &"stage_changed", fixture.controller) == 0
		and _connection_count(fixture.progress, &"stage_unlocked", fixture.controller) == 0
		and _connection_count(fixture.resources, &"resource_access_changed", fixture.controller) == 0,
		"Reset retained observation subscriptions")
	fixture.resources.set_connected(2, true)
	fixture.progress.record_arrival("isolated:after_hint_reset", 60)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Reset accepted source events without configure")
	var fresh: Fixture = _new_fixture()
	_check(fresh.controller.get_snapshot()["enabled"] and fresh.controller.get_snapshot()["seen_ids"].is_empty()
		and not fresh.controller.get_snapshot()["visible"], "A fresh scene inherited disabled hints or seen IDs")


func _test_exit_requires_explicit_configuration() -> void:
	var fixture: Fixture = _new_fixture()
	var retired: Callable = _capture_callback(fixture.resources, &"resource_access_changed", fixture.controller)
	fixture.host.remove_child(fixture.controller)
	_check(_connection_count(fixture.resources, &"resource_access_changed", fixture.controller) == 0
		and fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Controller exit retained bindings or playthrough state")
	fixture.host.add_child(fixture.controller)
	fixture.resources.set_connected(1, true)
	if retired.is_valid():
		retired.call(1, true)
	_check(not fixture.controller.get_snapshot()["visible"], "Reentry revived bindings without explicit configure")
	_configure(fixture)
	_check(_drain(fixture) == [&"first_resource_connected"], "Explicit configure after reentry could not observe current sources")


func _test_queued_and_freed_sources() -> void:
	var fixture: Fixture = _new_fixture()
	var retired: Callable = _capture_callback(fixture.resources, &"resource_access_changed", fixture.controller)
	fixture.resources.queue_free()
	fixture.resources.set_connected(1, true)
	if retired.is_valid():
		retired.call(1, true)
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["seen_ids"].is_empty(),
		"Queued deletion emitted a positive resource hint")
	await process_frame
	_check(not is_instance_valid(fixture.resources), "Resource fixture did not actually free")
	if retired.is_valid():
		retired.call(1, true)
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["seen_ids"].is_empty(),
		"Freed source or its saved callback emitted a positive hint")
	var progress_source: Fixture = _new_fixture()
	progress_source.progress.queue_free()
	progress_source.progress.record_arrival("isolated:queued_progress", 160)
	_check(progress_source.controller.get_snapshot()["seen_ids"].is_empty(), "Queued progress source fabricated stage/capability hints")
	await process_frame
	progress_source.controller.reset()
	evidence.append({"case": "dead_source_isolation", "queued_sources_ignored": true, "saved_callbacks_ignored": true})


func _prepare_disabled_playthrough() -> Fixture:
	var fixture: Fixture = _new_fixture()
	fixture.resources.set_connected(1, true)
	fixture.controller.set_hints_enabled(false)
	fixture.resources.set_connected(2, true)
	_check(fixture.progress.record_arrival("isolated:muted_mature", 160), "Constructed disabled mature fixture")
	_upgrade_isolated_edge(fixture)
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["pending_count"] == 0,
		"Disabled hints retained visible or queued history")
	return fixture


func _test_all_seven_and_real_expansion() -> void:
	var fixture: Fixture = _new_fixture()
	var shown: Array[StringName] = []
	fixture.resources.set_connected(1, true)
	shown.append_array(_drain(fixture))
	_check(fixture.progress.record_arrival("isolated:59", 59), "Constructed threshold 59")
	_check(not fixture.controller.get_snapshot()["visible"], "Expanded hint appeared before recovered 60")
	_check(fixture.progress.record_arrival("isolated:60", 1), "Constructed threshold 60")
	shown.append_array(_drain(fixture))
	fixture.resources.set_connected(2, true)
	shown.append_array(_drain(fixture))
	_check(fixture.progress.record_arrival("isolated:159", 99), "Constructed threshold 159")
	_check(not fixture.controller.get_snapshot()["visible"], "Mature hint appeared before recovered 160")
	var started_at: float = _now()
	_check(fixture.progress.record_arrival("isolated:160", 1), "Constructed threshold 160")
	var mature: Dictionary = fixture.controller.get_snapshot()
	_check(mature["id"] == &"mature" and String(mature["text"]).contains("完成扩建后")
		and fixture.stomach.get_digestion_snapshot()["expansion_state"] == &"expanding"
		and fixture.stomach.get_digestion_snapshot()["chamber_count"] == 1,
		"Mature hint claimed an already working second chamber")
	shown.append_array(_drain(fixture))
	var expansion_connections: Array = fixture.stomach.chamber_expansion_timer.timeout.get_connections()
	_check(expansion_connections.size() == 1, "Real chamber expansion did not own exactly one timer callback")
	if not expansion_connections.is_empty():
		var early_callback: Callable = expansion_connections[0]["callable"]
		early_callback.call()
	fixture.stomach.digestion_changed.emit({"expansion_state": &"ready", "chamber_count": 2})
	_check(not fixture.controller.get_snapshot()["seen_ids"].has(&"second_chamber_ready"),
		"Early timer callback or claimed-ready signal payload unlocked a chamber hint")
	await create_timer(0.15, true, true).timeout
	_check(fixture.stomach.get_digestion_snapshot()["expansion_state"] == &"expanding"
		and not fixture.controller.get_snapshot()["visible"], "Chamber hint appeared during the real expansion interval")
	var deadline: float = _now() + 6.0
	while fixture.stomach.get_digestion_snapshot()["expansion_state"] != &"ready" and _now() < deadline:
		await physics_frame
	var elapsed: float = _now() - started_at
	_check(elapsed >= DigestiveOrgan.EXPANSION_DURATION
		and fixture.stomach.get_digestion_snapshot()["chamber_count"] == 2,
		"Production timer did not complete a real three-second chamber expansion")
	shown.append_array(_drain(fixture))
	# 未登记边即便自行设置等级和发送升级参数，也不能成为主脉提示的证据。
	var unregistered := HyphaEdge.new()
	unregistered.start_node = fixture.edge.start_node
	unregistered.end_node = fixture.edge.end_node
	var line := Line2D.new()
	line.name = "Vein"
	unregistered.add_child(line)
	fixture.host.add_child(unregistered)
	unregistered.apply_vein_growth(1, 20)
	fixture.veins.edge_upgraded.emit(unregistered, 0, 1)
	_check(not fixture.controller.get_snapshot()["visible"], "Unregistered upgraded edge triggered a vein hint")
	_upgrade_isolated_edge(fixture)
	shown.append_array(_drain(fixture))
	_check(shown == EXPECTED_IDS and fixture.controller.get_snapshot()["seen_ids"] == EXPECTED_IDS,
		"Playthrough did not emit exactly the seven contracted first-time hints")
	var event_count: int = fixture.events.size()
	_emit_duplicates(fixture)
	_configure(fixture)
	_check(fixture.events.size() == event_count, "Duplicate/reconfigured callbacks repeated completed first-time hints")
	_check(fixture.progress.get_total_recovered() == 160 and fixture.stomach.get_output_count() == 0
		and fixture.queue.get_all_requests().is_empty(), "Hint observation invented production or construction")
	evidence.append({"case": "seven_hint_sequence", "fixture": "constructed_thresholds_and_resource_snapshots",
		"shown_ids": shown, "expansion_elapsed_physics_seconds": elapsed,
		"early_ready_payload_rejected": true, "unregistered_edge_rejected": true})


func _test_disabled_playthrough_has_no_historical_flood(fixture: Fixture) -> void:
	_check(fixture.stomach.get_digestion_snapshot()["expansion_state"] == &"ready"
		and fixture.controller.get_snapshot()["seen_ids"].size() == 7,
		"Disabled playthrough did not mark its real timer-completed chamber hint as seen")
	fixture.controller.set_hints_enabled(true)
	_check(fixture.controller.get_snapshot()["enabled"] and not fixture.controller.get_snapshot()["visible"]
		and fixture.controller.get_snapshot()["pending_count"] == 0, "Re-enabling flooded all seven historical hints")
	var event_count: int = fixture.events.size()
	_emit_duplicates(fixture)
	_check(fixture.events.size() == event_count, "Duplicate disabled-history events republished a hint after re-enable")
	evidence.append({"case": "disabled_occurrences", "seen_count": 7, "reenabled_pending_count": 0})


func _test_enable_samples_silent_disabled_changes() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.controller.set_hints_enabled(false)
	fixture.controller.set_process(false)
	fixture.resources.set_connected(1, true, false)
	fixture.resources.set_connected(2, true, false)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Silent fixture unexpectedly signalled while disabled")
	fixture.controller.set_hints_enabled(true)
	_check(fixture.controller.get_snapshot()["seen_ids"] == [&"first_resource_connected", &"second_resource_connected"]
		and not fixture.controller.get_snapshot()["visible"], "Re-enable failed to suppress silent changes that occurred while disabled")


func _free_fixtures() -> void:
	for reference: WeakRef in _hosts:
		var host: Node = reference.get_ref() as Node
		if is_instance_valid(host):
			host.free()
	_hosts.clear()
