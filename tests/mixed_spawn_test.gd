extends SceneTree
## 真实三类敌人的混合生成、批次身份、同步重入与计时回放。

const NORMAL_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const SWARM_SCENE: PackedScene = preload("res://scenes/enemies/swarm_enemy.tscn")
const ARMORED_SCENE: PackedScene = preload("res://scenes/enemies/armored_enemy.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const SPAWNER_SCENE: PackedScene = preload("res://scenes/systems/enemy_spawner.tscn")
const REMAINS_SPAWNER_SCENE: PackedScene = preload("res://scenes/systems/remains_spawner.tscn")
const SWARM_BATCH_SCENE: PackedScene = preload("res://scenes/systems/swarm_enemy_batch.tscn")
const ARMORED_BATCH_SCENE: PackedScene = preload("res://scenes/systems/armored_enemy_batch.tscn")
const MIXED_BATCH_SCENE: PackedScene = preload("res://scenes/systems/mixed_enemy_batch.tscn")

class InitCallbackEnemy:
	extends BasicEnemy
	static var callback: Callable

	func _init() -> void:
		if callback.is_valid():
			callback.call()

var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_test_entry_validation()
	await _test_invalid_batches()
	await _test_default_and_presets()
	await _test_real_mixed_batch()
	await _test_group_timing_and_snapshot_isolation()
	await _test_terminal_accounting()
	await _test_stop_reset_and_old_callbacks()
	await _test_reset_ownership()
	await _test_preparation_callbacks()
	await _test_reentrant_callbacks()
	await _test_environment_invalidation_and_reopen()
	_check(root.get_child_count() == 0, "Mixed spawning teardown leaves no nodes")
	print("MIXED_SPAWN_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _check_snapshot(snapshot: Dictionary, description: String) -> void:
	_check(int(snapshot["planned"]) == int(snapshot["spawned"]) + int(snapshot["unspawned"]),
		description + ": planned = spawned + unspawned")
	_check(int(snapshot["spawned"]) == int(snapshot["active"]) + int(snapshot["defeated"])
		+ int(snapshot["removed"]), description + ": spawned = active + defeated + removed")
	_check(int(snapshot["unspawned"]) >= 0 and int(snapshot["active"]) >= 0,
		description + ": nonnegative counts")


func _entry(scene: PackedScene, groups: int = 1, members: int = 1,
		group_delay: float = 0.15, member_delay: float = 0.0,
		spacing: float = 24.0, point_index: int = -1) -> EnemySpawnEntry:
	var entry := EnemySpawnEntry.new()
	entry.enemy_scene = scene
	entry.group_count = groups
	entry.group_size = members
	entry.group_interval = group_delay
	entry.member_interval = member_delay
	entry.member_spacing = spacing
	entry.spawn_point_index = point_index
	return entry


func _fixture(scene: PackedScene = SPAWNER_SCENE, automatic: bool = false) -> Dictionary:
	var world := Node2D.new()
	world.position = Vector2(38, 49)
	world.rotation = 0.12
	var core := CORE_SCENE.instantiate() as MotherCore
	core.max_health = 100000
	world.add_child(core)
	var enemies := Node2D.new()
	enemies.position = Vector2(71, -33)
	enemies.rotation = 0.31
	enemies.scale = Vector2(0.9, 1.2)
	world.add_child(enemies)
	var points := Node2D.new()
	for position: Vector2 in [Vector2(-430, 60), Vector2(440, -80), Vector2(90, -420)]:
		var marker := Marker2D.new()
		marker.position = position
		points.add_child(marker)
	world.add_child(points)
	var remains := Node2D.new()
	world.add_child(remains)
	var spawner := scene.instantiate() as EnemySpawner
	spawner.auto_start = automatic
	spawner.mother_core = core
	spawner.enemy_container = enemies
	spawner.spawn_points = points
	(spawner.get_node("StartTimer") as Timer).wait_time = 0.08
	world.add_child(spawner)
	var remains_spawner := REMAINS_SPAWNER_SCENE.instantiate() as RemainsSpawner
	remains_spawner.enemy_container = enemies
	remains_spawner.remains_container = remains
	world.add_child(remains_spawner)
	var records: Array[Dictionary] = []
	var entered: Array[Dictionary] = []
	var snapshots: Array[Dictionary] = []
	var starts: Array[String] = []
	var finishes: Array[String] = []
	var stops: Array[Dictionary] = []
	var totals: Array[int] = []
	var victories: Array[int] = [0]
	enemies.child_entered_tree.connect(func(child: Node) -> void:
		if child is BasicEnemy:
			entered.append({"position": (child as BasicEnemy).global_position,
				"spawn_id": child.get_meta(&"spawn_id", ""),
				"batch_id": child.get_meta(&"batch_id", ""),
				"spawned": spawner.spawned_count, "active": spawner.get_active_count()}))
	spawner.batch_started.connect(func(batch_id: String, _planned: int) -> void: starts.append(batch_id))
	spawner.batch_changed.connect(func(snapshot: Dictionary) -> void:
		snapshots.append(snapshot.duplicate(true))
		_check_snapshot(snapshot, "Public batch snapshot"))
	spawner.enemy_spawned.connect(func(enemy: BasicEnemy, spawn_id: String, batch_id: String) -> void:
		records.append({"enemy": weakref(enemy), "spawn_id": spawn_id, "batch_id": batch_id,
			"archetype": enemy.archetype, "max_health": enemy.max_health, "armor": enemy.armor,
			"move_speed": enemy.move_speed, "attack_damage": enemy.attack_damage,
			"remains_nutrition": enemy.remains_nutrition, "position": enemy.global_position,
			"frame": Engine.get_physics_frames()})
		# 保留真实场景参数证据，再让计时和队形测试中的敌人原地等待。
		enemy.move_speed = 0.0
		enemy.attack_timer.stop())
	spawner.wave_changed.connect(func(_spawned: int, _defeated: int, _active: int, total: int) -> void:
		totals.append(total))
	spawner.wave_finished.connect(func() -> void: victories[0] += 1)
	spawner.batch_finished.connect(func(batch_id: String) -> void: finishes.append(batch_id))
	spawner.batch_stopped.connect(func(batch_id: String, reason: StringName) -> void:
		stops.append({"batch_id": batch_id, "reason": String(reason)}))
	root.add_child(world)
	return {"world": world, "core": core, "enemies": enemies, "points": points,
		"remains": remains, "spawner": spawner, "records": records, "entered": entered,
		"snapshots": snapshots, "starts": starts, "finishes": finishes, "stops": stops,
		"totals": totals, "victories": victories}


func _destroy(fixture: Dictionary) -> void:
	var spawner: EnemySpawner = fixture["spawner"]
	if is_instance_valid(spawner):
		spawner.stop_spawning(&"test_teardown")
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame


func _wait_spawned(fixture: Dictionary, expected: int, frame_limit: int = 150) -> bool:
	var spawner: EnemySpawner = fixture["spawner"]
	for frame in range(frame_limit):
		if spawner.spawned_count >= expected or spawner.get_batch_snapshot()["state"] == "stopped":
			break
		await physics_frame
	_check(spawner.spawned_count == expected, "Real timers reached planned spawn count %d" % expected)
	return spawner.spawned_count == expected


func _enemy(record: Dictionary) -> BasicEnemy:
	return (record["enemy"] as WeakRef).get_ref() as BasicEnemy


func _kill_records(records: Array[Dictionary]) -> void:
	for record: Dictionary in records:
		var enemy := _enemy(record)
		if is_instance_valid(enemy) and enemy.is_inside_tree() and enemy.is_alive():
			enemy.take_damage(9999)
			enemy.take_damage(9999)


func _point(fixture: Dictionary, index: int) -> Vector2:
	return ((fixture["points"] as Node2D).get_child(index) as Node2D).global_position


func _check_group(records: Array[Dictionary], first: int, members: int,
		center: Vector2, core_position: Vector2, spacing: float, description: String) -> void:
	var direction := core_position - center
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	var perpendicular := direction.normalized().orthogonal()
	var sum := Vector2.ZERO
	for member in range(members):
		var position: Vector2 = records[first + member]["position"]
		var expected := center + perpendicular * (float(member) - float(members - 1) * 0.5) * spacing
		_check(position.is_equal_approx(expected), description + ": member position")
		sum += position
	_check((sum / float(members)).is_equal_approx(center), description + ": centered group")


func _check_delay(first: Dictionary, second: Dictionary, delay: float, description: String) -> void:
	var elapsed := float(int(second["frame"]) - int(first["frame"])) / float(Engine.physics_ticks_per_second)
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	_check(elapsed + tick * 1.1 >= delay, description + ": did not fire early")
	_check(elapsed <= delay + tick * 3.1, description + ": timer interval")


func _serial_records(records: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in records:
		var item := record.duplicate()
		item.erase("enemy")
		var position: Vector2 = item["position"]
		item["position"] = [position.x, position.y]
		result.append(item)
	return result


func _wrong_scene() -> PackedScene:
	var node := Node2D.new()
	var scene := PackedScene.new()
	_check(scene.pack(node) == OK, "Wrong-root fixture packed")
	node.free()
	return scene


func _test_entry_validation() -> void:
	var entry := _entry(NORMAL_SCENE)
	_check(entry.is_valid() and entry.get_total_count() == 1, "Default entry is valid")
	var copy := entry.copy_for_instance()
	_check(copy != entry and copy.enemy_scene != entry.enemy_scene,
		"Entry copy and its scene resource are independent")
	copy.group_count = 3
	copy.member_spacing = 41.0
	_check(entry.group_count == 1 and entry.member_spacing == 24.0,
		"Entry copies preserve source parameters")
	var cases: Array[Dictionary] = [
		{"property": "group_count", "value": 0},
		{"property": "group_count", "value": -1},
		{"property": "group_size", "value": 0},
		{"property": "group_size", "value": -1},
		{"property": "group_interval", "value": 0.0},
		{"property": "group_interval", "value": -0.1},
		{"property": "group_interval", "value": INF},
		{"property": "group_interval", "value": NAN},
		{"property": "member_interval", "value": -0.1},
		{"property": "member_interval", "value": INF},
		{"property": "member_interval", "value": NAN},
		{"property": "member_spacing", "value": -1.0},
		{"property": "member_spacing", "value": INF},
		{"property": "member_spacing", "value": NAN},
		{"property": "spawn_point_index", "value": -2},
		{"property": "enemy_scene", "value": null},
		{"property": "enemy_scene", "value": PackedScene.new()},
		{"property": "enemy_scene", "value": _wrong_scene()},
	]
	for item: Dictionary in cases:
		var invalid := entry.copy_for_instance()
		invalid.set(item["property"], item["value"])
		_check(not invalid.is_valid() and not invalid.get_validation_errors().is_empty(),
			"Entry rejects invalid %s" % item["property"])
	_check(not _entry(NORMAL_SCENE, 1, 2, 0.1, 0.0, 0.0).is_valid(),
		"Multiple members reject zero spacing")
	_check(_entry(NORMAL_SCENE, 1, 1, 0.1, 0.0, 0.0).is_valid(),
		"One member allows zero spacing")
	_check(_entry(NORMAL_SCENE, 5, 100).is_valid(), "500-member entry is accepted")
	_check(not _entry(NORMAL_SCENE, 501).is_valid(), "501-member entry is rejected")
	var overflow := _entry(NORMAL_SCENE, 9223372036854775807, 2)
	_check(not overflow.is_valid() and overflow.get_total_count() == -1,
		"Count overflow is rejected without wrapping")


func _test_invalid_batches() -> void:
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	var cases: Array = [
		[null], [_entry(_wrong_scene())], [_entry(NORMAL_SCENE, 0)],
		[_entry(NORMAL_SCENE, 1, 2, 0.1, 0.0, 0.0)],
		[_entry(NORMAL_SCENE, 1, 1, 0.1, 0.0, 24.0, 3)],
		[_entry(NORMAL_SCENE, 250), _entry(SWARM_SCENE, 251)],
	]
	for entries: Array in cases:
		spawner.reset()
		spawner.spawn_entries.assign(entries)
		_check(spawner.get_planned_count() == 0, "Invalid idle configuration has no planned preview")
		_check(spawner.start_batch().is_empty(), "Invalid batch returns no identity")
		var snapshot := spawner.get_batch_snapshot()
		_check(snapshot["state"] == "invalid" and not String(snapshot["reason"]).is_empty(),
			"Invalid batch exposes an explicit reason")
		_check(snapshot["spawned"] == 0 and spawner.get_active_count() == 0,
			"Invalid batch creates no enemy")
	spawner.reset()
	spawner.spawn_entries.clear()
	spawner.wave_size = 0
	_check(spawner.start_batch().is_empty(), "Legacy zero wave_size is rejected unchanged")
	_check(spawner.wave_size == 0, "Invalid legacy count is not silently normalized")
	spawner.wave_size = 501
	spawner.reset()
	_check(spawner.start_batch().is_empty(), "Legacy count also obeys the 500-member cap")
	spawner.reset()
	spawner.spawn_entries = [_entry(NORMAL_SCENE, 1, 500, 0.1, 0.0, 1.0)]
	var stop_at_accept := func(_batch_id: String, _planned: int) -> void:
		spawner.stop_spawning(&"boundary_check")
	spawner.batch_started.connect(stop_at_accept)
	_check(not spawner.start_batch().is_empty() and spawner.get_planned_count() == 500,
		"Exactly 500 planned enemies are accepted")
	_check(spawner.spawned_count == 0, "Batch-start cancellation precedes all generation")
	spawner.batch_started.disconnect(stop_at_accept)
	_check((fixture["finishes"] as Array).is_empty() and fixture["victories"][0] == 0,
		"Invalid or stopped batches never finish")
	await _destroy(fixture)
	fixture = _fixture()
	spawner = fixture["spawner"]
	var points: Node2D = fixture["points"]
	for child: Node in points.get_children():
		points.remove_child(child)
		child.free()
	_check(spawner.start_batch().is_empty(), "Empty birth-point container is explicitly rejected")
	var wrong_point := Node.new()
	points.add_child(wrong_point)
	spawner.reset()
	_check(spawner.start_batch().is_empty(), "A plain Node cannot be a birth-position anchor")
	await _destroy(fixture)


func _test_default_and_presets() -> void:
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	var records: Array[Dictionary] = fixture["records"]
	_check(spawner.wave_size == 6 and spawner.spawn_entries.is_empty(),
		"Shared spawner keeps the original six-enemy configuration")
	_check(spawner.get_planned_count() == 6 and spawner.get_batch_snapshot()["planned"] == 0,
		"Idle planned preview is six while no batch ledger exists")
	spawner.start_wave()
	_check(records.size() == 1 and spawner.spawned_count == 1, "Legacy first enemy is immediate")
	_check(is_equal_approx(spawner.spawn_timer.wait_time, 3.0)
		and spawner.spawn_timer.time_left > 2.9, "Legacy interval remains the original SpawnTimer interval")
	for member in range(5):
		spawner.spawn_timer.timeout.emit()
	_check(records.size() == 6 and spawner.get_batch_snapshot()["legacy"],
		"Empty entries generate exactly six ordinary enemies")
	if records.size() == 6:
		for index in range(6):
			_check(records[index]["archetype"] == BasicEnemy.Archetype.NORMAL,
				"Legacy member uses the real ordinary scene")
			_check((records[index]["position"] as Vector2).is_equal_approx(_point(fixture, index % 3)),
				"Legacy one-member groups rotate exact marker positions")
	_kill_records(records)
	_check((fixture["finishes"] as Array).size() == 1 and fixture["victories"][0] == 1,
		"Legacy compatibility emits each completion once")
	_check(spawner.spawned_count == 6 and spawner.defeated_count == 6,
		"Legacy compatibility counters are retained")
	evidence["default"] = spawner.get_batch_snapshot()
	var completed_id := String(spawner.get_batch_snapshot()["batch_id"])
	spawner.spawn_entries = [_entry(NORMAL_SCENE, 0)]
	_check(spawner.start_batch().is_empty() and spawner.get_batch_snapshot()["state"] == "invalid"
		and spawner.get_planned_count() == 6 and spawner.spawned_count == 6
		and spawner.get_batch_snapshot()["batch_id"] == completed_id,
		"Rejected next configuration retains the last accepted batch ledger until reset")
	await _destroy(fixture)
	var preset_counts: Array[int] = []
	for item: Dictionary in [{"scene": SWARM_BATCH_SCENE, "planned": 3},
			{"scene": ARMORED_BATCH_SCENE, "planned": 1}, {"scene": MIXED_BATCH_SCENE, "planned": 6}]:
		fixture = _fixture(item["scene"])
		spawner = fixture["spawner"]
		_check(spawner.get_planned_count() == item["planned"], "Preset idle preview is its actual plan")
		spawner.start_batch()
		_check(spawner.get_planned_count() == item["planned"] and not spawner.get_batch_snapshot()["legacy"],
			"Preset accepted plan is frozen and explicit")
		preset_counts.append(spawner.get_planned_count())
		await _destroy(fixture)
	evidence["preset_planned"] = preset_counts
	fixture = _fixture()
	spawner = fixture["spawner"]
	var points: Node2D = fixture["points"]
	var original := points.get_child(0) as Node2D
	var anchor := Node2D.new()
	anchor.position = original.position
	points.remove_child(original)
	original.free()
	points.add_child(anchor)
	points.move_child(anchor, 0)
	spawner.wave_size = 1
	_check(not spawner.start_batch().is_empty(), "Legacy Node2D birth anchors remain accepted")
	_check((fixture["records"][0]["position"] as Vector2).is_equal_approx(anchor.global_position),
		"Legacy Node2D singleton uses the anchor's original position")
	await _destroy(fixture)


func _test_real_mixed_batch() -> void:
	var fixture := _fixture(MIXED_BATCH_SCENE)
	var spawner: EnemySpawner = fixture["spawner"]
	var entries: Array[EnemySpawnEntry] = []
	for source: EnemySpawnEntry in spawner.spawn_entries:
		var entry := source.copy_for_instance()
		entry.group_interval = 0.12
		entry.member_interval = 0.03
		entries.append(entry)
	entries[2].group_interval = 0.5
	spawner.spawn_entries = entries
	spawner.wave_size = 97
	var batch_id := spawner.start_batch()
	_check(not batch_id.is_empty() and spawner.spawned_count == 1, "Mixed first member is immediate")
	_check(spawner.start_batch().is_empty(), "Active batch rejects a second start")
	var records: Array[Dictionary] = fixture["records"]
	if not await _wait_spawned(fixture, 6) or records.size() != 6:
		await _destroy(fixture)
		return
	var expected: Array[Dictionary] = [
		{"archetype": BasicEnemy.Archetype.NORMAL, "max_health": 24, "armor": 0,
			"move_speed": 52.0, "attack_damage": 12},
		{"archetype": BasicEnemy.Archetype.SWARM, "max_health": 12, "armor": 0,
			"move_speed": 66.0, "attack_damage": 6},
		{"archetype": BasicEnemy.Archetype.ARMORED, "max_health": 72, "armor": 4,
			"move_speed": 26.0, "attack_damage": 15},
	]
	for index in range(6):
		var parameters: Dictionary = expected[0 if index < 2 else (1 if index < 5 else 2)]
		for key: String in parameters:
			_check(records[index][key] == parameters[key], "Mixed member retains real scene %s" % key)
		_check(records[index]["remains_nutrition"] == 4, "Mixed scenes retain corpse nutrition")
		_check(records[index]["batch_id"] == batch_id, "Mixed identity uses its accepted batch")
		for previous in range(index):
			_check(records[index]["spawn_id"] != records[previous]["spawn_id"], "Every member has a unique identity")
		var entered: Dictionary = fixture["entered"][index]
		_check((entered["position"] as Vector2).is_equal_approx(records[index]["position"])
			and entered["spawn_id"] == records[index]["spawn_id"] and entered["spawned"] == index + 1,
			"In-tree observer already sees final position, identity and count")
	var core: MotherCore = fixture["core"]
	_check_group(records, 0, 1, _point(fixture, 0), core.global_position, 24.0, "Mixed normal first")
	_check_group(records, 1, 1, _point(fixture, 1), core.global_position, 24.0, "Mixed normal second")
	_check_group(records, 2, 3, _point(fixture, 2), core.global_position, 24.0, "Mixed swarm")
	_check_group(records, 5, 1, _point(fixture, 0), core.global_position, 24.0, "Mixed armored")
	_check_delay(records[0], records[1], 0.12, "Normal group interval")
	_check_delay(records[1], records[2], 0.12, "Entry switch uses previous normal interval")
	_check_delay(records[2], records[3], 0.03, "Swarm member interval")
	_check_delay(records[3], records[4], 0.03, "Swarm next member interval")
	_check_delay(records[4], records[5], 0.12, "Armored switch uses previous swarm interval")
	_check(spawner.get_batch_snapshot()["state"] == "draining" and spawner.get_active_count() == 6,
		"Fully generated living mixed batch drains")
	for total: int in fixture["totals"]:
		_check(total == 6, "Legacy wave_changed reports actual mixed plan, not wave_size")
	_kill_records(records)
	_check(spawner.defeated_count == 6 and spawner.get_active_count() == 0,
		"Every real archetype follows the same death ledger")
	_check((fixture["finishes"] as Array).size() == 1 and fixture["victories"][0] == 1,
		"Full mixed victory completes exactly once")
	await _wait_frames(20)
	_check((fixture["enemies"] as Node2D).get_child_count() == 0
		and (fixture["remains"] as Node2D).get_child_count() == 6,
		"True deaths clean up all archetypes and create six corpses")
	evidence["mixed"] = {"members": _serial_records(records), "snapshot": spawner.get_batch_snapshot()}
	await _destroy(fixture)


func _test_group_timing_and_snapshot_isolation() -> void:
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	var shared := _entry(SWARM_SCENE, 2, 3, 0.16, 0.05, 30.0)
	spawner.spawn_entries = [shared, _entry(ARMORED_SCENE, 1, 1, 0.6, 0.0, 0.0, 2)]
	var second := _fixture()
	var second_spawner: EnemySpawner = second["spawner"]
	second_spawner.spawn_entries = [shared]
	var center := _point(fixture, 0)
	var batch_id := spawner.start_batch()
	_check(spawner.spawned_count == 1, "Positive member interval schedules remaining members")
	shared.enemy_scene = ARMORED_SCENE
	shared.group_count = 1
	shared.group_size = 1
	shared.group_interval = 0.6
	shared.member_interval = 0.5
	shared.member_spacing = 0.0
	shared.spawn_point_index = 2
	((fixture["points"] as Node2D).get_child(0) as Node2D).position += Vector2(100, 30)
	second_spawner.start_batch()
	_check(second_spawner.get_planned_count() == 1 and second["records"][0]["max_health"] == 72,
		"A later spawner sees the edited shared configuration")
	var records: Array[Dictionary] = fixture["records"]
	if not await _wait_spawned(fixture, 7) or records.size() != 7:
		await _destroy(second)
		await _destroy(fixture)
		return
	for index in range(6):
		_check(records[index]["max_health"] == 12 and records[index]["armor"] == 0,
			"Accepted batch ignores later scene and parameter edits")
	_check(spawner.get_planned_count() == 7 and spawner.get_batch_snapshot()["batch_id"] == batch_id,
		"Accepted plan remains seven after shared resource edits")
	var core: MotherCore = fixture["core"]
	_check_group(records, 0, 3, center, core.global_position, 30.0, "Frozen first group center")
	_check_group(records, 3, 3, _point(fixture, 1), core.global_position, 30.0, "Automatic next group marker")
	_check_group(records, 6, 1, _point(fixture, 2), core.global_position, 0.0, "Fixed marker singleton")
	_check_delay(records[0], records[1], 0.05, "Frozen member interval")
	_check_delay(records[1], records[2], 0.05, "Frozen second member interval")
	_check_delay(records[2], records[3], 0.16, "Last member to next group uses group interval")
	_check_delay(records[5], records[6], 0.16, "Last member to next entry uses previous group interval")
	var exported_snapshot := spawner.get_batch_snapshot()
	exported_snapshot["planned"] = 999
	_check(spawner.get_batch_snapshot()["planned"] == 7, "Public snapshot mutations cannot alter ledger")
	evidence["isolation"] = {"accepted": 7, "later_shared_plan": 1, "members": _serial_records(records)}
	await _destroy(second)
	await _destroy(fixture)


func _test_terminal_accounting() -> void:
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	spawner.spawn_entries = [_entry(NORMAL_SCENE, 1, 3)]
	spawner.start_batch()
	var records: Array[Dictionary] = fixture["records"]
	_check(records.size() == 3, "Zero member interval emits a whole group in the same call")
	if records.size() != 3:
		await _destroy(fixture)
		return
	var first := _enemy(records[0])
	var removed := _enemy(records[1])
	var last := _enemy(records[2])
	var first_callbacks: Dictionary = spawner._enemy_callbacks[first.get_instance_id()].duplicate()
	var removed_callbacks: Dictionary = spawner._enemy_callbacks[removed.get_instance_id()].duplicate()
	first.take_damage(9999)
	first.take_damage(9999)
	(first_callbacks["died"] as Callable).call(first)
	(first_callbacks["removed"] as Callable).call()
	_check(spawner.defeated_count == 1 and spawner.get_active_count() == 2,
		"Repeated death and exit callbacks settle a member once")
	(fixture["enemies"] as Node2D).remove_child(removed)
	(removed_callbacks["removed"] as Callable).call()
	(removed_callbacks["died"] as Callable).call(removed)
	_check(spawner.get_batch_snapshot()["removed"] == 1 and spawner.defeated_count == 1,
		"Living removal is separate from defeat")
	_check((fixture["remains"] as Node2D).get_child_count() == 1, "Living removal creates no corpse")
	last.take_damage(9999)
	last.take_damage(9999)
	_check(spawner.get_batch_snapshot()["state"] == "completed"
		and spawner.defeated_count == 2 and spawner.get_active_count() == 0,
		"Generated batch finishes when deaths and removals drain it")
	_check((fixture["finishes"] as Array).size() == 1 and fixture["victories"][0] == 0,
		"External removal finishes batch without old victory signal")
	evidence["removed_terminal"] = spawner.get_batch_snapshot()
	removed.free()
	await _destroy(fixture)


func _test_stop_reset_and_old_callbacks() -> void:
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	spawner.spawn_entries = [_entry(NORMAL_SCENE, 2, 2, 0.2)]
	var old_id := spawner.start_batch()
	var records: Array[Dictionary] = fixture["records"]
	var dying := _enemy(records[0])
	var removed := _enemy(records[1])
	var old_timeout := spawner._spawn_callback
	var old_died: Callable = spawner._enemy_callbacks[dying.get_instance_id()]["died"]
	var old_removed_died: Callable = spawner._enemy_callbacks[removed.get_instance_id()]["died"]
	var old_exit: Callable = spawner._enemy_callbacks[removed.get_instance_id()]["removed"]
	spawner.stop_spawning(&"test_stop")
	old_timeout.call()
	old_died.call(dying)
	old_exit.call()
	_check(spawner.spawned_count == 2 and spawner.defeated_count == 0 and spawner.get_active_count() == 2,
		"Stop invalidates all old callbacks without retiring living enemies")
	_check(spawner.start_batch().is_empty(), "Stopped batch requires reset before reopening")
	dying.take_damage(9999)
	(fixture["enemies"] as Node2D).remove_child(removed)
	await _wait_frames(20)
	var stopped := spawner.get_batch_snapshot()
	_check(stopped["state"] == "stopped" and stopped["reason"] == "test_stop"
		and stopped["defeated"] == 1 and stopped["removed"] == 1 and stopped["active"] == 0
		and stopped["unspawned"] == 2, "Stopped living members still settle actual deaths and removals")
	_check((fixture["finishes"] as Array).is_empty() and fixture["victories"][0] == 0
		and (fixture["stops"] as Array).size() == 1, "Stop has one notification and no completion")
	spawner.reset()
	var new_id := spawner.start_batch()
	var before := spawner.get_batch_snapshot()
	old_timeout.call()
	old_removed_died.call(removed)
	old_exit.call()
	_check(not new_id.is_empty() and new_id != old_id and spawner.get_batch_snapshot() == before,
		"Reset preserves monotonic identities and rejects old batch callbacks")
	var used_timeout := spawner._spawn_callback
	used_timeout.call()
	var count_after_timeout := spawner.spawned_count
	used_timeout.call()
	_check(count_after_timeout == 4 and spawner.spawned_count == 4,
		"A consumed timeout cannot advance another slot in the same batch")
	_kill_records(records)
	_check((fixture["finishes"] as Array).size() == 1 and fixture["victories"][0] == 1,
		"Explicit reopened batch can finish once")
	var completed_id := String(spawner.get_batch_snapshot()["batch_id"])
	var following_id := spawner.start_batch()
	_check(not following_id.is_empty() and following_id != completed_id and spawner.spawned_count == 2,
		"Completed batch supports an explicit fresh batch without automatic chaining")
	evidence["stop"] = stopped
	evidence["reopened_ids"] = [old_id, new_id, following_id]
	removed.free()
	await _destroy(fixture)


func _test_reset_ownership() -> void:
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	var configured := _entry(SWARM_SCENE, 1, 3)
	spawner.spawn_entries = [configured]
	var first_id := spawner.start_batch()
	var records: Array[Dictionary] = fixture["records"]
	var foreign := NORMAL_SCENE.instantiate() as BasicEnemy
	foreign.mother_core = fixture["core"]
	foreign.move_speed = 0.0
	foreign.position = Vector2(200, -300)
	(fixture["enemies"] as Node2D).add_child(foreign)
	var deaths: Array[int] = [0]
	for record: Dictionary in records:
		_enemy(record).died.connect(func(_dead: BasicEnemy) -> void: deaths[0] += 1)
	spawner.reset()
	_check(spawner.get_batch_snapshot()["state"] == "idle" and spawner.spawned_count == 0
		and spawner.get_active_count() == 0 and spawner.get_batch_snapshot()["planned"] == 0,
		"Reset clears the accepted batch ledger")
	_check(spawner.get_planned_count() == 3 and spawner.spawn_entries[0] == configured,
		"Reset preserves configured entries and their idle preview")
	_check(spawner.start_timer.is_stopped() and spawner.spawn_timer.is_stopped(),
		"Reset does not automatically reopen")
	await _wait_frames(2)
	_check(is_instance_valid(foreign) and foreign.is_inside_tree() and foreign.is_alive()
		and (fixture["enemies"] as Node2D).get_child_count() == 1,
		"Reset retires only its own living enemies")
	_check(deaths[0] == 0 and (fixture["remains"] as Node2D).get_child_count() == 0,
		"Reset retirement emits no death and produces no corpses")
	var new_id := spawner.start_batch()
	_check(new_id != first_id and spawner.get_active_count() == 3, "Reset starts a fresh scoped ledger")
	foreign.take_damage(9999)
	_check(spawner.defeated_count == 0 and spawner.get_active_count() == 3,
		"Foreign enemy death does not enter the spawner ledger")
	await _destroy(fixture)


func _test_preparation_callbacks() -> void:
	for mode: String in ["recursive_start", "stop", "reset", "replace", "preview_reset"]:
		InitCallbackEnemy.callback = Callable()
		var node := NORMAL_SCENE.instantiate() as BasicEnemy
		node.set_script(InitCallbackEnemy)
		var scene := PackedScene.new()
		_check(scene.pack(node) == OK, "Initializer callback fixture packed")
		node.free()
		var fixture := _fixture()
		var spawner: EnemySpawner = fixture["spawner"]
		spawner.spawn_entries = [_entry(scene, 2)]
		var acted: Array[bool] = [false]
		var recursive_ids: Array[String] = []
		var recursive_previews: Array[int] = []
		InitCallbackEnemy.callback = func() -> void:
			if acted[0]:
				return
			acted[0] = true
			if mode == "recursive_start":
				recursive_ids.append(spawner.start_batch())
				recursive_previews.append(spawner.get_planned_count())
			elif mode == "stop":
				spawner.stop_spawning(&"initializer_stop")
			elif mode == "replace":
				spawner.spawn_entries = [_entry(ARMORED_SCENE)]
			else:
				spawner.reset()
				recursive_ids.append(spawner.start_batch())
		var accepted_id := ""
		var preview := 0
		if mode == "preview_reset":
			preview = spawner.get_planned_count()
		else:
			accepted_id = spawner.start_batch()
		InitCallbackEnemy.callback = Callable()
		_check(acted[0], "Validation exercised an actual enemy initializer callback")
		var snapshot := spawner.get_batch_snapshot()
		if mode == "recursive_start":
			_check(recursive_ids == [""] and recursive_previews == [0]
				and not accepted_id.is_empty() and snapshot["spawned"] == 1,
				"Preparation lock prevents recursive start and preview instantiation")
		elif mode == "stop":
			_check(accepted_id.is_empty() and snapshot["state"] == "stopped"
				and snapshot["reason"] == "initializer_stop" and snapshot["spawned"] == 0,
				"Initializer stop cannot be overwritten by outer start")
		elif mode == "replace":
			_check(accepted_id.is_empty() and snapshot["state"] == "invalid"
				and String(snapshot["reason"]).contains("configuration changed")
				and snapshot["spawned"] == 0, "Initializer configuration replacement rejects stale prepared plan")
			_check(not spawner.start_batch().is_empty() and spawner.get_planned_count() == 1
				and fixture["records"][0]["max_health"] == 72, "Replacement can be accepted by a fresh explicit start")
		else:
			_check(accepted_id.is_empty() and snapshot["state"] == "idle"
				and snapshot["spawned"] == 0 and recursive_ids == [""],
				"Initializer reset cancels outer preparation and recursive restart")
			if mode == "preview_reset":
				_check(preview == 0, "Preview observes preparation cancellation without recursion")
		await _destroy(fixture)


func _test_reentrant_callbacks() -> void:
	for mode: String in ["started_stop", "spawned_stop", "spawned_reset", "changed_reset", "wave_reset",
			"spawned_remove", "spawned_queue", "entered_reset", "reset_and_restart"]:
		var fixture := _fixture()
		var spawner: EnemySpawner = fixture["spawner"]
		var enemies: Node2D = fixture["enemies"]
		spawner.spawn_entries = [_entry(NORMAL_SCENE, 1, 3)]
		var acted: Array[bool] = [false]
		var removed: Array[BasicEnemy] = []
		var new_ids: Array[String] = []
		if mode == "started_stop":
			spawner.batch_started.connect(func(_id: String, _count: int) -> void:
				spawner.stop_spawning(&"started_callback"))
		elif mode in ["spawned_stop", "spawned_reset", "spawned_remove", "spawned_queue", "reset_and_restart"]:
			spawner.enemy_spawned.connect(func(enemy: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
				if acted[0]:
					return
				acted[0] = true
				if mode == "spawned_stop":
					spawner.stop_spawning(&"spawned_callback")
				elif mode == "spawned_remove":
					enemies.remove_child(enemy)
					removed.append(enemy)
				elif mode == "spawned_queue":
					enemy.queue_free()
				else:
					spawner.reset()
					if mode == "reset_and_restart":
						spawner.spawn_entries = [_entry(ARMORED_SCENE)]
						new_ids.append(spawner.start_batch()))
		elif mode == "changed_reset":
			spawner.batch_changed.connect(func(snapshot: Dictionary) -> void:
				if not acted[0] and snapshot["spawned"] == 1:
					acted[0] = true
					spawner.reset())
		elif mode == "wave_reset":
			spawner.wave_changed.connect(func(spawned: int, _defeated: int, _active: int, _total: int) -> void:
				if not acted[0] and spawned == 1:
					acted[0] = true
					spawner.reset())
		else:
			enemies.child_entered_tree.connect(func(_child: Node) -> void:
				if not acted[0]:
					acted[0] = true
					spawner.reset())
		var accepted_id := spawner.start_batch()
		await _wait_frames(3)
		var snapshot := spawner.get_batch_snapshot()
		_check(not accepted_id.is_empty(), "Reentrant %s retains the accepted return identity" % mode)
		if mode == "started_stop":
			_check(snapshot["state"] == "stopped" and snapshot["spawned"] == 0,
				"Batch-start stop prevents every member")
		elif mode == "spawned_stop":
			_check(snapshot["state"] == "stopped" and snapshot["spawned"] == 1 and snapshot["active"] == 1,
				"Enemy-spawn stop prevents same-call group members")
		elif mode in ["spawned_remove", "spawned_queue"]:
			_check(snapshot["state"] == "stopped" and snapshot["spawned"] == 1 and snapshot["removed"] == 1,
				"Synchronous member removal prevents remaining group members")
		elif mode == "reset_and_restart":
			_check(new_ids.size() == 1 and new_ids[0] != accepted_id and snapshot["batch_id"] == new_ids[0]
				and snapshot["spawned"] == 1 and snapshot["planned"] == 1,
				"Synchronous reset and fresh start cannot inherit old group work")
			_check(fixture["records"].size() == 2 and fixture["records"][1]["max_health"] == 72,
				"New batch keeps its own real scene parameters")
		else:
			_check(snapshot["state"] == "idle" and snapshot["spawned"] == 0 and snapshot["active"] == 0,
				"Reentrant %s retires old state and cancels remaining members" % mode)
			var snapshots: Array[Dictionary] = fixture["snapshots"]
			_check(not snapshots.is_empty() and snapshots.back()["state"] == "idle",
				"Reset notification is not followed by a stale old-batch snapshot")
		_check((fixture["finishes"] as Array).is_empty() and fixture["victories"][0] == 0,
			"Synchronous cancellation creates no completion")
		for enemy: BasicEnemy in removed:
			if is_instance_valid(enemy):
				enemy.free()
		await _destroy(fixture)


func _test_environment_invalidation_and_reopen() -> void:
	var automatic := _fixture(SPAWNER_SCENE, true)
	var automatic_spawner: EnemySpawner = automatic["spawner"]
	var automatic_core: MotherCore = automatic["core"]
	var start_callback := automatic_spawner._start_callback
	_check(automatic_spawner.get_batch_snapshot()["state"] == "waiting"
		and automatic_spawner.get_planned_count() == 6, "Automatic startup waits with the default preview")
	automatic_core.take_damage(100000)
	start_callback.call()
	await _wait_frames(10)
	_check(automatic_spawner.spawned_count == 0 and automatic_spawner.start_timer.is_stopped()
		and automatic_spawner.get_batch_snapshot()["state"] == "stopped",
		"Core depletion independently cancels waiting startup")
	await _destroy(automatic)

	var environment_losses: Array[Dictionary] = []
	for mode: String in ["core", "point", "points", "container", "spawner_exit"]:
		var fixture := _fixture()
		var spawner: EnemySpawner = fixture["spawner"]
		spawner.spawn_entries = [_entry(SWARM_SCENE, 1, 3, 0.2, 0.1)]
		var first_id := spawner.start_batch()
		var timeout := spawner._spawn_callback
		var enemy := _enemy(fixture["records"][0])
		var died: Callable = spawner._enemy_callbacks[enemy.get_instance_id()]["died"]
		var exited: Callable = spawner._enemy_callbacks[enemy.get_instance_id()]["removed"]
		var detached: Node
		if mode == "core":
			(fixture["core"] as MotherCore).take_damage(100000)
		elif mode == "point":
			detached = (fixture["points"] as Node2D).get_child(0)
			(fixture["points"] as Node2D).remove_child(detached)
		elif mode == "points":
			detached = fixture["points"]
			(fixture["world"] as Node2D).remove_child(detached)
		elif mode == "container":
			detached = fixture["enemies"]
			(fixture["world"] as Node2D).remove_child(detached)
		else:
			detached = spawner
			(fixture["world"] as Node2D).remove_child(detached)
		_check(spawner.spawned_count == 1 and spawner.spawn_timer.is_stopped()
			and spawner.get_batch_snapshot()["state"] == "stopped",
			"Runtime %s loss immediately cancels generation" % mode)
		if mode != "spawner_exit":
			_check(fixture["stops"].size() == 1, "Runtime %s stop notification is synchronous" % mode)
		var immediately_stopped := spawner.get_batch_snapshot()
		timeout.call()
		_check(spawner.get_batch_snapshot() == immediately_stopped,
			"Runtime %s loss invalidates the captured old timer callback immediately" % mode)
		await _wait_frames(10)
		_check(spawner.spawned_count == 1 and spawner.get_batch_snapshot()["state"] == "stopped",
			"Runtime %s loss cancels future generation independently" % mode)
		var expected_reason := {"core": "core_depleted", "point": "spawn_point_unavailable",
			"points": "spawn_points_unavailable", "container": "enemy_container_unavailable",
			"spawner_exit": "exited_tree"}
		var actual_reason := String(spawner.get_batch_snapshot()["reason"])
		var accepted_reasons: Array[String] = [expected_reason[mode]]
		if mode == "points":
			# Godot 子节点先退出；Marker 的同步守卫可先于父容器报告真实失效。
			accepted_reasons.append("spawn_point_unavailable")
		_check(accepted_reasons.has(actual_reason),
			"Runtime %s loss records its reason: expected %s, actual %s" % [mode, accepted_reasons, actual_reason])
		var stops: Array[Dictionary] = fixture["stops"]
		if mode != "spawner_exit":
			_check(stops.size() == 1 and stops[0]["reason"] == actual_reason,
				"Runtime %s loss emits exactly one synchronous stop with its recorded reason" % mode)
		environment_losses.append({"mode": mode, "accepted_reasons": accepted_reasons,
			"snapshot": spawner.get_batch_snapshot(), "stops": stops.duplicate(true)})
		if mode == "core":
			(fixture["core"] as MotherCore).health = 100000
		elif mode == "point":
			(fixture["points"] as Node2D).add_child(detached)
			(fixture["points"] as Node2D).move_child(detached, 0)
		else:
			(fixture["world"] as Node2D).add_child(detached)
		spawner.reset()
		spawner.spawn_entries = [_entry(NORMAL_SCENE, 1, 2, 0.2, 0.05)]
		var new_id := spawner.start_batch()
		var before := spawner.get_batch_snapshot()
		timeout.call()
		if is_instance_valid(enemy):
			died.call(enemy)
		exited.call()
		_check(not new_id.is_empty() and new_id != first_id and spawner.get_batch_snapshot() == before,
			"Reopened %s fixture rejects all old callbacks" % mode)
		await _destroy(fixture)
	evidence["environment_losses"] = environment_losses

	# 同一批中已用过的计时槽，不得在后续槽正在等待时再次推进。
	var fixture := _fixture()
	var spawner: EnemySpawner = fixture["spawner"]
	spawner.spawn_entries = [_entry(NORMAL_SCENE, 4, 1, 0.2)]
	spawner.start_batch()
	var first_slot := spawner._spawn_callback
	first_slot.call()
	var second_slot := spawner._spawn_callback
	first_slot.call()
	_check(spawner.spawned_count == 2, "Old slot replay does not consume the next live timer slot")
	second_slot.call()
	second_slot.call()
	_check(spawner.spawned_count == 3, "Each live slot is consumed once")
	var final_slot := spawner._spawn_callback
	spawner.stop_spawning()
	final_slot.call()
	_check(spawner.spawned_count == 3, "Manual default reason cancels the final slot")
	evidence["timer_slots"] = {"consumed": 2, "spawned_before_stop": 3,
		"snapshot": spawner.get_batch_snapshot()}
	await _destroy(fixture)
