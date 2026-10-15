class_name AIProductionController
extends Node
## 每次生产拥有独立 EnemySpawner；旧批次仍存活时也能接受新批次。

signal changed(snapshot: Dictionary)
signal objective_completed(evidence: Dictionary)
signal enemy_created(enemy: BasicEnemy)

const SPAWNER: PackedScene = preload("res://scenes/systems/enemy_spawner.tscn")

@export var profile: AIProductionProfile = AIProductionProfile.new()

var elapsed_seconds: float = 0.0
var destroyed_ids: Array[StringName] = []
var _level: ColonyLevelRuntime
var _sources: Dictionary = {}
var _batches: Array[Dictionary] = []
var _configured: bool = false
var _stopped: bool = false
var _last_second: int = -1
var _spawned: int = 0
var _preparation_skipped: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func configure(level: ColonyLevelRuntime, facilities: Array[AIFacility]) -> void:
	if _configured:
		return
	_level = level
	profile = profile.duplicate(true) as AIProductionProfile
	if facilities.size() != 3 or not profile.is_valid():
		push_error("第二关需要三个不同ID设施及有效的生产配置。")
		_stopped = true
		return
	for facility: AIFacility in facilities:
		if facility.facility_id.is_empty() or _sources.has(facility.facility_id):
			push_error("AI设施ID必须非空且唯一。")
			_stopped = true
			_sources.clear()
			return
		_sources[facility.facility_id] = {"facility": facility, "remaining": profile.preparation_seconds,
			"cycles": 0, "index": _sources.size(), "phase": &"preparing"}
	for id: StringName in _sources:
		var facility: Variant = _sources[id].facility
		facility.facility_destroyed.connect(_on_facility_destroyed)
		facility.tree_exiting.connect(_on_facility_exiting.bind(id))
		facility.set_production_state(&"preparing", profile.preparation_seconds)
	_configured = true
	changed.emit(get_snapshot())


func _process(delta: float) -> void:
	if not _configured or _stopped or not can_process() or not is_finite(delta) or delta <= 0:
		return
	elapsed_seconds += delta
	_prune_batches()
	for id: StringName in _sources:
		var record: Dictionary = _sources[id]
		var facility: Variant = record.facility
		if not is_instance_valid(facility) or not facility.is_alive():
			continue
		record.remaining = maxf(0.0, float(record.remaining) - delta)
		if float(record.remaining) <= 0.0:
			if _source_load(id) >= profile.max_alive_per_source:
				record.remaining = 3.0
				record.phase = &"capped"
			elif _spawn_cycle(id):
				record.remaining = profile.cycle_seconds
				record.cycles = int(record.cycles) + 1
				record.phase = &"cooldown"
			else:
				record.remaining = 3.0
				record.phase = &"blocked"
		elif StringName(record.phase) not in [&"capped", &"blocked"]:
			record.phase = &"warning" if float(record.remaining) <= profile.warning_seconds else (
				&"preparing" if int(record.cycles) == 0 else &"cooldown")
		var phase: StringName = &"generating" if _is_generating(id) else StringName(record.phase)
		facility.set_production_state(phase, float(record.remaining))
	if int(elapsed_seconds) != _last_second:
		_last_second = int(elapsed_seconds)
		changed.emit(get_snapshot())


func begin_attack() -> bool:
	if not _configured or _stopped or _preparation_skipped or not can_process() or elapsed_seconds >= profile.preparation_seconds:
		return false
	for record: Dictionary in _sources.values():
		if int(record.cycles) > 0:
			return false
	for record: Dictionary in _sources.values():
		record.remaining = 0.0
	_preparation_skipped = true
	return true


func get_snapshot() -> Dictionary:
	var facilities: Array[Dictionary] = []
	for record: Dictionary in _sources.values():
		var facility: Variant = record.facility
		if is_instance_valid(facility):
			facilities.append(facility.get_facility_snapshot())
	return {"state": "stopped" if _stopped else "fighting", "completed": destroyed_ids.size(),
		"total": 3, "destroyed_ids": destroyed_ids.duplicate(), "facilities": facilities,
		"spawned": _spawned, "elapsed_seconds": elapsed_seconds,
		"can_start": not _stopped and not _preparation_skipped and elapsed_seconds < profile.preparation_seconds \
			and _sources.values().all(func(record: Dictionary) -> bool: return int(record.cycles) == 0)}


func stop(reason: StringName) -> void:
	if _stopped:
		return
	_stopped = true
	for batch: Dictionary in _batches:
		var spawner: Variant = batch.spawner
		if is_instance_valid(spawner):
			spawner.stop_spawning(reason)
	for record: Dictionary in _sources.values():
		var facility: Variant = record.facility
		if is_instance_valid(facility):
			facility.set_production_state(&"stopped", 0)


func _exit_tree() -> void:
	stop(&"scene_exit")


func _on_facility_destroyed(id: StringName) -> void:
	if _stopped or not _sources.has(id) or destroyed_ids.has(id):
		return
	var facility: Variant = _sources[id].facility
	if not is_instance_valid(facility) or facility.is_alive():
		return
	destroyed_ids.append(id)
	for batch: Dictionary in _batches:
		if batch.source_id == id and is_instance_valid(batch.spawner):
			(batch.spawner as EnemySpawner).stop_spawning(&"source_destroyed")
	for record: Dictionary in _sources.values():
		record.remaining = maxf(float(record.remaining), profile.destruction_grace_seconds)
	changed.emit(get_snapshot())
	if destroyed_ids.size() == 3:
		objective_completed.emit({"level_id": "second_level", "completed": 3, "total": 3,
			"destroyed_ids": destroyed_ids.duplicate(), "spawned": _spawned})


func _on_facility_exiting(id: StringName) -> void:
	if not _stopped and not destroyed_ids.has(id):
		# 删除设施不算摧毁，也不能让新生产引用失效来源。
		stop(&"facility_removed")


func _spawn_cycle(id: StringName) -> bool:
	var record: Dictionary = _sources[id]
	var facility: Variant = record.facility
	var point: Vector2 = _find_safe_spawn(facility)
	if not point.is_finite():
		return false
	var scenes: Array[PackedScene] = profile.get_scenes_for_cycle(elapsed_seconds, int(record.cycles), int(record.index))
	var capacity: int = profile.max_alive_per_source - _source_load(id)
	var entries: Array[EnemySpawnEntry] = []
	var planned: int = 0
	for scene: PackedScene in scenes:
		if planned >= capacity:
			break
		planned += 1
		if scene == profile.swarm_scene and not entries.is_empty() and entries.back().enemy_scene == scene:
			entries.back().group_size += 1
			entries.back().member_interval = 0.25
			continue
		var entry := EnemySpawnEntry.new()
		entry.enemy_scene = scene
		entry.group_interval = maxf(0.05, profile.member_interval)
		entry.spawn_point_index = 0
		entries.append(entry)
	if entries.is_empty():
		return false
	var spawner := SPAWNER.instantiate() as EnemySpawner
	spawner.auto_start = false
	spawner.mother_core = _level.mother_core
	spawner.enemy_container = _level.get_node("World/Enemies") as Node2D
	spawner.spawn_entries = entries
	var points := Node2D.new()
	points.name = "BatchSpawnPoints"
	spawner.add_child(points)
	var marker := Marker2D.new()
	marker.position = point
	points.add_child(marker)
	spawner.spawn_points = points
	spawner.enemy_spawned.connect(_on_enemy_spawned.bind(id))
	add_child(spawner)
	_batches.append({"source_id": id, "spawner": spawner})
	return not spawner.start_batch().is_empty()


func _source_load(id: StringName) -> int:
	var count: int = 0
	for enemy: Node in _level.get_node("World/Enemies").get_children():
		if enemy is BasicEnemy and enemy.is_alive() and enemy.get_meta("source_id", &"") == id:
			count += 1
	for batch: Dictionary in _batches:
		var spawner: Variant = batch.spawner
		if batch.source_id == id and is_instance_valid(spawner):
			var snapshot: Dictionary = spawner.get_batch_snapshot()
			if snapshot.get("state") == "spawning":
				count += int(snapshot.get("unspawned", 0))
	return count


func _is_generating(id: StringName) -> bool:
	for batch: Dictionary in _batches:
		if batch.source_id == id and is_instance_valid(batch.spawner) \
				and (batch.spawner as EnemySpawner).get_batch_snapshot().get("state") == "spawning":
			return true
	return false


func _prune_batches() -> void:
	for index: int in range(_batches.size() - 1, -1, -1):
		var spawner: Variant = _batches[index].spawner
		if not is_instance_valid(spawner):
			_batches.remove_at(index)
			continue
		var snapshot: Dictionary = spawner.get_batch_snapshot()
		if snapshot.get("state") in ["completed", "stopped", "invalid"] and int(snapshot.get("active", 0)) == 0:
			spawner.queue_free()
			_batches.remove_at(index)


func _on_enemy_spawned(enemy: BasicEnemy, _spawn_id: String, _batch_id: String, source_id: StringName) -> void:
	if _stopped:
		return
	if not _point_is_clear(enemy.global_position):
		var point: Vector2 = _find_safe_spawn(_sources[source_id].facility)
		if not point.is_finite():
			enemy.queue_free()
			return
		enemy.global_position = point
	enemy.set_meta("source_id", source_id)
	_level._on_terrain_enemy_spawned(enemy, _spawn_id, _batch_id)
	_spawned += 1
	enemy_created.emit(enemy)


func _find_safe_spawn(facility: AIFacility) -> Vector2:
	var origin: Vector2 = (facility.get_node("SpawnPoints/Exit") as Node2D).global_position
	var candidates: Array[Vector2] = [origin]
	for radius: float in [60.0, 100.0]:
		for index: int in range(12):
			candidates.append(origin + Vector2.from_angle(index * TAU / 12.0) * radius)
	for point: Vector2 in candidates:
		if _point_is_clear(point):
			return point
	return Vector2(INF, INF)


func _point_is_clear(point: Vector2) -> bool:
	if not point.is_finite() or (is_instance_valid(_level.terrain_navigation) \
			and not _level.terrain_navigation.is_point_walkable(point, BasicEnemy.NAVIGATION_CLEARANCE)):
		return false
	for tissue: Node2D in _level.network_system.get_registered_nodes():
		if is_instance_valid(tissue) and point.distance_to(tissue.global_position) < 42.0:
			return false
	for edge: HyphaEdge in _level.network_system.get_registered_edges():
		if is_instance_valid(edge) and edge.has_endpoints() and point.distance_to(
				Geometry2D.get_closest_point_to_segment(point, edge.start_node.global_position, edge.end_node.global_position)) < 24.0:
			return false
	for tissue: Node in get_tree().get_nodes_in_group("colony_tissues"):
		if tissue is Node2D and not tissue is HyphaEdge and _level.is_ancestor_of(tissue) \
				and point.distance_to((tissue as Node2D).global_position) < 42.0:
			return false
	return true
