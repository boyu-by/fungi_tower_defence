extends SceneTree
## 六波流程的独立夹具：真实生成器/敌人身份，显式缩短生成间隔并直接造成伤害。
## 本测试不代表正式关卡的战斗、建设或 8–12 分钟通关验收。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const SPAWNER_SCENE: PackedScene = preload("res://scenes/systems/enemy_spawner.tscn")
const NORMAL_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const EXPECTED: Array[Array] = [
	[6, 0, 0, 0], [6, 2, 0, 0], [6, 4, 0, 0],
	[6, 4, 2, 0], [8, 4, 1, 1], [8, 5, 3, 0],
]
const SNAPSHOT_KEYS: Array[String] = [
	"state", "wave_index", "completed_waves", "wave_total", "planned", "spawned",
	"defeated", "active", "unspawned", "preparation_remaining", "can_start",
	"next_title", "next_direction", "total_defeated", "batch_id",
]

var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_test_resources()
	await _test_manual_pause_and_timer()
	await _test_six_waves_and_candidate()
	await _test_terminal_paths()
	await _test_stale_identity_and_reset()
	await _test_reentrant_start_and_completion()
	await _test_synchronous_completion()
	await _test_configuration_guards()
	_check(root.get_child_count() == 0, "Flow fixtures dispose all nodes")
	print("STAGE11_FLOW_TEST_RESULT ", JSON.stringify({"checks": checks,
		"failures": failures, "evidence": evidence,
		"fixture": "real EnemySpawner and enemy scenes; shortened intervals, stationary actors, direct damage; no playable-level balance claim"}))
	quit(0 if failures.is_empty() else 1)


func _test_resources() -> void:
	var flow := FirstLevelFlow.new()
	_check(flow.waves.size() == 6 and flow.preparation_seconds == 20.0,
		"Formal flow exports six waves and five 20-second preparation intervals")
	_check(flow.process_mode == Node.PROCESS_MODE_PAUSABLE, "Flow countdown uses pausable processing")
	var total: int = 0
	var counts: Array[Array] = []
	var schedules: Array[Dictionary] = []
	for index: int in range(flow.waves.size()):
		var wave := flow.waves[index]
		var observed: Array[int] = [0, 0, 0, 0]
		var span: float = 0.0
		var last_gap: float = 0.0
		var points: Dictionary = {}
		_check(wave != null and not wave.entries.is_empty() and not wave.title.is_empty()
			and not wave.direction_text.is_empty(), "Wave %d has editable data and player direction text" % (index + 1))
		for entry: EnemySpawnEntry in wave.entries:
			_check(entry != null and entry.is_valid(), "Wave %d contains valid real-enemy entries" % (index + 1))
			var enemy := entry.enemy_scene.instantiate() as BasicEnemy
			var archetype := enemy.get_archetype()
			var amount := entry.get_total_count()
			observed[archetype] += amount
			points[entry.spawn_point_index] = true
			_check(entry.spawn_point_index in [0, 1], "Wave entries use only front and side-front anchors")
			_check(entry.group_interval > 0.0 and is_finite(entry.group_interval),
				"Wave groups have finite positive editable spacing")
			if archetype == BasicEnemy.Archetype.SWARM:
				_check(entry.group_size in [2, 3] and entry.member_interval <= 0.3,
					"Small swarms contain two or three actual members with short intra-group delay")
			span += entry.group_count * entry.group_interval \
				+ entry.group_count * (entry.group_size - 1) * entry.member_interval
			last_gap = entry.group_interval
			enemy.free()
		_check(observed == EXPECTED[index], "Wave %d matches exact normal/swarm/armored/gnawer counts" % (index + 1))
		counts.append(observed)
		for amount: int in observed:
			total += amount
		schedules.append({"wave": index + 1, "spawn_span_seconds": span - last_gap,
			"anchors": points.keys()})
	_check(total == 66, "Formal six waves plan exactly 66 individuals without multiplying swarm groups")
	evidence["resource_counts"] = counts
	evidence["initial_schedules"] = schedules
	flow.free()


func _fixture(custom_waves: Array[FirstLevelWave] = []) -> Dictionary:
	var world := Node2D.new()
	var core := CORE_SCENE.instantiate() as MotherCore
	core.max_health = 100000
	world.add_child(core)
	var enemies := Node2D.new()
	world.add_child(enemies)
	var points := Node2D.new()
	for position: Vector2 in [Vector2(-540, 120), Vector2(-450, -280)]:
		var marker := Marker2D.new()
		marker.position = position
		points.add_child(marker)
	world.add_child(points)
	var spawner := SPAWNER_SCENE.instantiate() as EnemySpawner
	spawner.auto_start = false
	spawner.mother_core = core
	spawner.enemy_container = enemies
	spawner.spawn_points = points
	world.add_child(spawner)
	var flow := FirstLevelFlow.new()
	var source: Array[FirstLevelWave] = flow.waves if custom_waves.is_empty() else custom_waves
	var copies: Array[FirstLevelWave] = []
	for original: FirstLevelWave in source:
		var copy := FirstLevelWave.new()
		copy.title = original.title
		copy.direction_text = original.direction_text
		for entry: EnemySpawnEntry in original.entries:
			var cloned := entry.copy_for_instance()
			cloned.group_interval = 0.05
			cloned.member_interval = 0.01 if cloned.group_size > 1 else 0.0
			copy.entries.append(cloned)
		copies.append(copy)
	flow.waves = copies
	world.add_child(flow)
	var starts: Array[String] = []
	var finishes: Array[String] = []
	var snapshots: Array[Dictionary] = []
	var candidates: Array[Dictionary] = []
	var interruptions: Array[String] = []
	var records: Array[Dictionary] = []
	var observed: Array[int] = [0, 0, 0, 0]
	var spawn_ids: Dictionary = {}
	spawner.batch_started.connect(func(batch_id: String, _planned: int) -> void: starts.append(batch_id))
	spawner.batch_finished.connect(func(batch_id: String) -> void: finishes.append(batch_id))
	spawner.enemy_spawned.connect(func(enemy: BasicEnemy, spawn_id: String, batch_id: String) -> void:
		_check(not spawn_ids.has(spawn_id) and not batch_id.is_empty(), "Fixture observes unique real spawn identities")
		spawn_ids[spawn_id] = true
		observed[enemy.get_archetype()] += 1
		records.append({"enemy": weakref(enemy), "spawn_id": spawn_id, "batch_id": batch_id})
		# 只隔离流程和生成计数；不是正式武器/供养战斗的替代验收。
		enemy.move_speed = 0.0
		enemy.attack_timer.stop())
	flow.changed.connect(func(snapshot: Dictionary) -> void:
		snapshots.append(snapshot.duplicate(true))
		_check_snapshot(snapshot))
	flow.victory_candidate.connect(func(candidate: Dictionary) -> void: candidates.append(candidate.duplicate(true)))
	flow.interrupted.connect(func(reason: StringName) -> void: interruptions.append(String(reason)))
	root.add_child(world)
	flow.configure(spawner)
	return {"world": world, "core": core, "enemies": enemies, "points": points,
		"spawner": spawner, "flow": flow, "starts": starts, "finishes": finishes,
		"snapshots": snapshots, "candidates": candidates, "interruptions": interruptions,
		"records": records, "observed": observed, "spawn_ids": spawn_ids}


func _check_snapshot(snapshot: Dictionary) -> void:
	for key: String in SNAPSHOT_KEYS:
		_check(snapshot.has(key), "Flow snapshot supplies %s" % key)
	_check(snapshot["wave_total"] == 6 and int(snapshot["wave_index"]) in range(7),
		"Flow snapshot stays within six waves")
	_check(int(snapshot["planned"]) == int(snapshot["spawned"]) + int(snapshot["unspawned"]),
		"Flow snapshot planned equals spawned plus unspawned")
	_check(int(snapshot["spawned"]) == int(snapshot["defeated"]) + int(snapshot["active"])
		+ int(snapshot["removed"]), "Flow snapshot accounts for each spawned individual")
	_check(int(snapshot["total_defeated"]) >= int(snapshot["defeated"]),
		"Cumulative kills include the current wave's observed normal deaths")


func _spawn_all(fixture: Dictionary) -> void:
	var spawner: EnemySpawner = fixture["spawner"]
	var slots: int = 0
	while spawner.get_batch_snapshot()["state"] == "spawning" and slots < 500:
		var callback: Callable = spawner._spawn_callback
		if not callback.is_valid():
			_check(false, "Spawning batch exposes the real next timer slot")
			break
		callback.call()
		slots += 1
	_check(spawner.spawned_count == spawner.get_planned_count(), "Fixture consumes every real scheduled member once")


func _kill_active(fixture: Dictionary) -> void:
	var spawner: EnemySpawner = fixture["spawner"]
	var enemies: Node2D = fixture["enemies"]
	for node: Node in enemies.get_children():
		if node is BasicEnemy and spawner.has_active_enemy(node):
			(node as BasicEnemy).take_damage(100000)


func _clear(fixture: Dictionary) -> void:
	_spawn_all(fixture)
	_kill_active(fixture)


func _test_manual_pause_and_timer() -> void:
	var fixture := _fixture()
	var flow: FirstLevelFlow = fixture["flow"]
	var spawner: EnemySpawner = fixture["spawner"]
	flow._process(10000.0)
	_check(flow.get_snapshot()["state"] == "initial_preparation" and flow.get_snapshot()["wave_index"] == 0
		and fixture["starts"].is_empty(), "Initial preparation has no automatic countdown")
	_check(flow.get_snapshot()["can_start"] and not String(flow.get_snapshot()["next_title"]).is_empty(),
		"Initial snapshot offers manual start and next-wave direction")
	_check(flow.begin_next_wave() and not flow.begin_next_wave(), "First manual click accepts exactly one batch")
	spawner.batch_finished.emit(String(spawner.get_batch_snapshot()["batch_id"]))
	_check(flow.get_snapshot()["state"] == "fighting" and flow.get_snapshot()["completed_waves"] == 0,
		"A finish signal without completed live evidence never clears a wave")
	_spawn_all(fixture)
	var first_enemy := (fixture["records"][0]["enemy"] as WeakRef).get_ref() as BasicEnemy
	first_enemy.take_damage(100000)
	_check(flow.get_snapshot()["total_defeated"] == 1 and flow.get_snapshot()["state"] == "fighting",
		"Cumulative normal kills advance during combat before the final death")
	_kill_active(fixture)
	_check(flow.get_snapshot()["state"] == "preparation" and flow.get_snapshot()["preparation_remaining"] == 20.0
		and flow.get_snapshot()["can_start"], "Normal clear begins a 20-second preparation with early start")
	flow._process(19.0)
	var remaining: float = flow.get_snapshot()["preparation_remaining"]
	paused = true
	flow._process(100.0)
	_check(flow.get_snapshot()["preparation_remaining"] == remaining and not flow.begin_next_wave(),
		"Paused flow neither consumes preparation time nor accepts manual start")
	paused = false
	flow._process(remaining)
	_check(flow.get_snapshot()["wave_index"] == 2 and fixture["starts"].size() == 2
		and not flow.begin_next_wave(), "Countdown expiration starts wave two exactly once")
	flow._process(10000.0)
	_check(fixture["starts"].size() == 2, "Fighting does not run a preparation countdown")
	_clear(fixture)
	_check(flow.begin_next_wave() and flow.get_snapshot()["wave_index"] == 3,
		"Early manual start cancels the second preparation without waiting")
	evidence["manual_timer"] = {"started": fixture["starts"].size(), "snapshot": flow.get_snapshot()}
	await _destroy(fixture)


func _test_six_waves_and_candidate() -> void:
	var fixture := _fixture()
	var flow: FirstLevelFlow = fixture["flow"]
	var spawner: EnemySpawner = fixture["spawner"]
	var counts: Array[Array] = []
	var batches: Dictionary = {}
	for index: int in range(6):
		fixture["observed"].fill(0)
		_check(flow.begin_next_wave(), "Formal-plan wave %d starts from preparation" % (index + 1))
		var identity := String(spawner.get_batch_snapshot()["batch_id"])
		_check(not identity.is_empty() and not batches.has(identity), "Each wave owns a distinct real batch")
		batches[identity] = true
		_clear(fixture)
		var snapshot := flow.get_snapshot()
		counts.append(fixture["observed"].duplicate())
		_check(fixture["observed"] == EXPECTED[index] and snapshot["completed_waves"] == index + 1,
			"Formal-plan wave %d clears only its exact real members" % (index + 1))
		_check(snapshot["active"] == 0 and snapshot["unspawned"] == 0
			and snapshot["defeated"] == snapshot["planned"], "Every accepted clear has all planned normal deaths")
		if index < 5:
			_check(snapshot["state"] == "preparation" and snapshot["preparation_remaining"] == 20.0
				and fixture["candidates"].is_empty(), "First five clears prepare without a victory candidate")
	var final := flow.get_snapshot()
	_check(final["state"] == "victory_candidate" and final["total_defeated"] == 66
		and fixture["starts"].size() == 6 and fixture["finishes"].size() == 6,
		"Six true clears produce exactly 66 normal defeats and six completed batches")
	_check(fixture["candidates"].size() == 1, "Sixth clear emits exactly one candidate for the owning level")
	var candidate: Dictionary = fixture["candidates"][0]
	_check(candidate["completed_waves"] == 6 and candidate["wave_index"] == 6
		and candidate["total_defeated"] == 66 and candidate["state"] == "completed"
		and candidate["batch_id"] == final["batch_id"] and candidate["generation"] == final["batch_generation"]
		and candidate["removed"] == 0 and candidate["active"] == 0 and candidate["unspawned"] == 0,
		"Candidate supplies matching batch identity/generation and complete normal-death evidence")
	_check(fixture["snapshots"].back()["state"] != "victory_candidate",
		"Flow leaves final level snapshot publication to the candidate arbiter")
	for _repeat: int in range(3):
		_check(not flow.begin_next_wave(), "Six-wave flow rejects every seventh-wave request")
		flow._process(10000.0)
		spawner.batch_finished.emit(String(final["batch_id"]))
	_check(fixture["starts"].size() == 6 and fixture["candidates"].size() == 1,
		"Timer and completion replays cannot spawn wave seven or duplicate a candidate")
	evidence["six_waves"] = {"counts": counts, "snapshot": final, "candidate": candidate,
		"real_spawn_id_count": fixture["spawn_ids"].size()}
	await _destroy(fixture)


func _test_terminal_paths() -> void:
	var paths: Array[Dictionary] = []
	for mode: String in ["removed", "queue_deleted", "spawner_stopped", "flow_stopped", "spawner_deleted", "flow_exit"]:
		var fixture := _fixture()
		var flow: FirstLevelFlow = fixture["flow"]
		var spawner: EnemySpawner = fixture["spawner"]
		flow.begin_next_wave()
		_spawn_all(fixture)
		var batch_id := String(spawner.get_batch_snapshot()["batch_id"])
		var finished := _flow_callback(spawner.batch_finished, flow)
		var enemy := (fixture["records"][0]["enemy"] as WeakRef).get_ref() as BasicEnemy
		var detached: Node
		if mode == "removed":
			detached = enemy
			(fixture["enemies"] as Node2D).remove_child(enemy)
		elif mode == "queue_deleted":
			enemy.queue_free()
			await _frames(2)
		elif mode == "spawner_stopped":
			spawner.stop_spawning(&"test_manual_stop")
		elif mode == "flow_stopped":
			flow.stop(&"test_manual_stop")
		elif mode == "spawner_deleted":
			spawner.queue_free()
			await _frames(2)
		else:
			detached = flow
			(fixture["world"] as Node2D).remove_child(flow)
		if finished.is_valid():
			finished.call(batch_id)
		if is_instance_valid(spawner):
			spawner.batch_finished.emit(batch_id)
			_kill_active(fixture)
		var snapshot := flow.get_snapshot()
		_check(snapshot["state"] in ["interrupted", "stopped"] and snapshot["completed_waves"] == 0
			and fixture["candidates"].is_empty() and not flow.begin_next_wave(),
			"%s never clears, resumes, or emits victory even after finish replay and real later deaths" % mode)
		if mode in ["removed", "queue_deleted"]:
			_check(snapshot["removed"] == 1 and fixture["interruptions"] == ["enemy_removed"],
				"Abnormal member removal is recorded once as an interrupted wave")
		if mode == "flow_stopped":
			_check(fixture["interruptions"].is_empty(), "Explicit stop does not pretend an external interruption")
		paths.append({"path": mode, "snapshot": snapshot,
			"interruptions": fixture["interruptions"].duplicate()})
		if is_instance_valid(detached):
			detached.free()
		await _destroy(fixture)
	evidence["terminal_paths"] = paths


func _test_stale_identity_and_reset() -> void:
	var fixture := _fixture()
	var flow: FirstLevelFlow = fixture["flow"]
	var spawner: EnemySpawner = fixture["spawner"]
	flow.begin_next_wave()
	var old_snapshot := spawner.get_batch_snapshot()
	var old_changed := _flow_callback(spawner.batch_changed, flow)
	var old_finished := _flow_callback(spawner.batch_finished, flow)
	var old_timer: Callable = spawner._spawn_callback
	var forged := old_snapshot.duplicate(true)
	for key: String in ["spawned", "defeated"]:
		forged[key] = forged["planned"]
	for key: String in ["active", "removed", "unspawned"]:
		forged[key] = 0
	forged["state"] = "completed"
	forged["generation"] = int(forged["generation"]) - 1
	spawner.batch_changed.emit(forged)
	spawner.batch_finished.emit(String(old_snapshot["batch_id"]))
	_check(flow.get_snapshot()["state"] == "fighting" and flow.get_snapshot()["completed_waves"] == 0,
		"Forged completed data and wrong generation cannot replace live completion evidence")
	spawner.reset()
	_check(flow.get_snapshot()["state"] == "interrupted" and flow.get_snapshot()["completed_waves"] == 0,
		"External spawner reset interrupts the old active wave")
	flow.reset()
	_check(flow.get_snapshot()["wave_index"] == 0 and flow.get_snapshot()["total_defeated"] == 0
		and flow.get_snapshot()["can_start"] and spawner.get_batch_snapshot()["state"] == "idle",
		"Flow reset clears its own totals and explicitly resets its owned spawner")
	_check(flow.begin_next_wave(), "Reset flow can cleanly start wave one again")
	var fresh := flow.get_snapshot()
	_check(fresh["batch_id"] != old_snapshot["batch_id"], "Reset restart owns a fresh batch identity")
	old_changed.call(forged)
	old_finished.call(String(old_snapshot["batch_id"]))
	old_timer.call()
	spawner.batch_changed.emit(old_snapshot)
	spawner.batch_finished.emit(String(old_snapshot["batch_id"]))
	_check(flow.get_snapshot() == fresh, "Captured old signals, timer, and emitted old snapshots cannot alter the reset run")
	var previous_started := _flow_callback(spawner.batch_started, flow)
	var previous_stopped := _flow_callback(spawner.batch_stopped, flow)
	var previous_exiting := _flow_callback(spawner.tree_exiting, flow)
	var previous_changed := _flow_callback(spawner.batch_changed, flow)
	_clear(fixture)
	var completed := spawner.get_batch_snapshot()
	_check(flow.begin_next_wave(), "True clear permits a fresh second wave before stale callback replay")
	var next := flow.get_snapshot()
	previous_started.call(String(completed["batch_id"]), int(completed["planned"]))
	previous_stopped.call(String(completed["batch_id"]), &"stale_stop")
	previous_exiting.call()
	previous_changed.call(completed)
	spawner.batch_started.emit(String(completed["batch_id"]), int(completed["planned"]))
	spawner.batch_stopped.emit(String(completed["batch_id"]), &"stale_stop")
	spawner.batch_started.emit(String(next["batch_id"]), int(next["planned"]))
	spawner.batch_stopped.emit(String(next["batch_id"]), &"forged_current_stop")
	_check(flow.get_snapshot() == next,
		"Previous-wave start/stop/exit callbacks and duplicate current notifications cannot interrupt the next batch")
	flow.reset()
	_check(spawner.get_active_count() == 0 and spawner.spawned_count == 0
		and flow.get_snapshot()["completed_waves"] == 0 and flow.get_snapshot()["state"] == "initial_preparation",
		"Reset during active wave removes owned actors without counting a clear")
	evidence["reset"] = {"retired": old_snapshot["batch_id"], "fresh": fresh["batch_id"],
		"snapshot": flow.get_snapshot()}
	await _destroy(fixture)


func _test_reentrant_start_and_completion() -> void:
	var fixture := _fixture()
	var flow: FirstLevelFlow = fixture["flow"]
	var spawner: EnemySpawner = fixture["spawner"]
	var clicks: Array[bool] = []
	flow.changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == "fighting":
			clicks.append(flow.begin_next_wave()))
	_check(flow.begin_next_wave() and fixture["starts"].size() == 1 and not clicks.has(true),
		"Reentrant fighting notifications cannot accept extra start clicks")
	_clear(fixture)
	var clicked: Array[bool] = [false]
	flow.changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == "fighting" and snapshot["wave_index"] == 2 and not clicked[0]:
			clicked[0] = true
			flow._process(100.0)
			clicks.append(flow.begin_next_wave()))
	flow._process(20.0)
	_check(fixture["starts"].size() == 2 and clicked[0] and not clicks.has(true),
		"Timer expiry plus synchronous repeated clicks starts only one next batch")
	await _destroy(fixture)

	fixture = _fixture()
	flow = fixture["flow"]
	spawner = fixture["spawner"]
	var reset_at_start: Array[bool] = [false]
	spawner.batch_started.connect(func(_batch_id: String, _planned: int) -> void:
		if not reset_at_start[0]:
			reset_at_start[0] = true
			flow.reset())
	_check(not flow.begin_next_wave() and spawner.spawned_count == 0
		and flow.get_snapshot()["state"] == "initial_preparation" and flow.get_snapshot()["completed_waves"] == 0,
		"Reset inside batch_started retires identity before the accepted start call returns")
	_check(flow.begin_next_wave() and flow.get_snapshot()["wave_index"] == 1,
		"A synchronous reset permits a fresh first wave without inheriting old work")
	await _destroy(fixture)

	fixture = _fixture()
	flow = fixture["flow"]
	spawner = fixture["spawner"]
	var reset_at_complete: Array[bool] = [false]
	# 重新连接流程，使明示的外部重置监听器先看到 completed 通知。
	spawner.batch_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == "completed" and not reset_at_complete[0]:
			reset_at_complete[0] = true
			flow.reset())
	flow.configure(spawner)
	flow.begin_next_wave()
	_clear(fixture)
	_check(reset_at_complete[0] and flow.get_snapshot()["state"] == "initial_preparation"
		and flow.get_snapshot()["completed_waves"] == 0 and fixture["candidates"].is_empty(),
		"Reset during completed notification cancels stale completion before batch_finished")
	evidence["reentrancy"] = {"timer_and_clicks_start_count": 2,
		"reset_inside_started": reset_at_start[0], "reset_inside_completed": reset_at_complete[0]}
	await _destroy(fixture)


func _test_synchronous_completion() -> void:
	var waves: Array[FirstLevelWave] = []
	for index: int in range(6):
		var wave := FirstLevelWave.new()
		wave.title = "explicit synchronous fixture %d" % (index + 1)
		wave.direction_text = "front"
		var entry := EnemySpawnEntry.new()
		entry.enemy_scene = NORMAL_SCENE
		entry.spawn_point_index = 0
		wave.entries = [entry]
		waves.append(wave)
	var fixture := _fixture(waves)
	var flow: FirstLevelFlow = fixture["flow"]
	var spawner: EnemySpawner = fixture["spawner"]
	spawner.enemy_spawned.connect(func(enemy: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
		enemy.take_damage(100000))
	for index: int in range(6):
		_check(flow.begin_next_wave() and flow.get_snapshot()["completed_waves"] == index + 1,
			"A real one-member fixture can clear synchronously within start_batch without losing its identity")
	_check(flow.get_snapshot()["state"] == "victory_candidate" and fixture["candidates"].size() == 1
		and flow.get_snapshot()["total_defeated"] == 6, "Synchronous sixth completion produces one candidate after accepted identity confirmation")
	evidence["synchronous_fixture"] = {"snapshot": flow.get_snapshot(), "candidates": fixture["candidates"].size()}
	await _destroy(fixture)


func _test_configuration_guards() -> void:
	var fixture := _fixture()
	var flow: FirstLevelFlow = fixture["flow"]
	var spawner: EnemySpawner = fixture["spawner"]
	spawner.auto_start = true
	flow.configure(spawner)
	_check(flow.get_snapshot()["state"] == "interrupted" and flow.get_snapshot()["reason"] == "spawner_auto_start_enabled",
		"Configure rejects an automatic spawner without silently changing its startup setting")
	spawner.auto_start = false
	flow.reset()
	flow.begin_next_wave()
	var other := FirstLevelFlow.new()
	(fixture["world"] as Node2D).add_child(other)
	var before := spawner.get_batch_snapshot()
	other.configure(spawner)
	_check(other.get_snapshot()["state"] == "interrupted" and spawner.get_batch_snapshot() == before,
		"Configure rejects an arbitrary active batch without deleting or stopping that other flow's actors")
	other.queue_free()
	await _destroy(fixture)


func _flow_callback(notification: Signal, flow: FirstLevelFlow) -> Callable:
	for record: Dictionary in notification.get_connections():
		var callback: Callable = record["callable"]
		if callback.get_object() == flow:
			return callback
	return Callable()


func _frames(count: int) -> void:
	for _frame: int in range(count):
		await process_frame


func _destroy(fixture: Dictionary) -> void:
	paused = false
	if is_instance_valid(fixture["flow"]):
		var flow: FirstLevelFlow = fixture["flow"]
		flow.stop(&"test_teardown")
	var world: Node2D = fixture["world"]
	world.queue_free()
	await _frames(3)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
		push_error(message)
