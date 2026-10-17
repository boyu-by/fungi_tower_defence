class_name ExplorationProductionController
extends Node
## 与第二关一致：每轮创建独立批次，旧敌存活不阻塞生产，暂停不补发。

signal changed(snapshot: Dictionary)
signal enemy_created(enemy: BasicEnemy)

const SPAWNER: PackedScene = preload("res://scenes/systems/enemy_spawner.tscn")
@export var profile: ExplorationProductionProfile

var elapsed_seconds: float = 0.0
var _level: ColonyLevelRuntime
var _sources: Dictionary = {}
var _batches: Array[Dictionary] = []
var _configured: bool = false
var _stopped: bool = false
var _preparation_skipped: bool = false
var _collected: int = 0
var _collected_ids: Array[StringName] = []
var _spawned: int = 0
var _last_second: int = -1


func _init() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func configure(level: ColonyLevelRuntime, sources: Array[Marker2D]) -> bool:
	if _configured or sources.size() != 3 or profile == null or not profile.is_valid():
		return false
	for source: Marker2D in sources:
		if not is_instance_valid(source) or _sources.has(StringName(source.name)):
			_sources.clear()
			return false
		var index: int = _sources.size()
		_sources[StringName(source.name)] = {"marker": source, "index": index, "cycles": 0,
			"remaining": profile.preparation_seconds + index * profile.source_stagger_seconds, "phase": &"preparing"}
	_level = level
	profile = profile.duplicate(true) as ExplorationProductionProfile
	_configured = true
	changed.emit(get_snapshot())
	return true


func _process(delta: float) -> void:
	if not _configured or _stopped or not can_process() or not is_finite(delta) or delta <= 0:
		return
	elapsed_seconds += delta
	_prune_batches()
	for id: StringName in _sources:
		var record: Dictionary = _sources[id]
		var marker: Variant = record.marker
		if not is_instance_valid(marker):
			stop(&"source_removed")
			return
		record.remaining = maxf(0, float(record.remaining) - delta)
		if float(record.remaining) <= 0:
			if _source_load(id) >= profile.max_alive_per_source:
				record.phase = &"capped"
				record.remaining = 3.0
			elif _spawn_cycle(id):
				record.cycles = int(record.cycles) + 1
				record.remaining = profile.cycle_seconds
				record.phase = &"cooldown"
			else:
				record.phase = &"blocked"
				record.remaining = 3.0
		elif StringName(record.phase) not in [&"capped", &"blocked"]:
			record.phase = &"warning" if float(record.remaining) <= profile.warning_seconds else (
				&"preparing" if int(record.cycles) == 0 else &"cooldown")
	if int(elapsed_seconds) != _last_second:
		_last_second = int(elapsed_seconds)
		changed.emit(get_snapshot())


func begin_attack() -> bool:
	if not _configured or _stopped or _preparation_skipped or not can_process() \
			or elapsed_seconds >= profile.preparation_seconds:
		return false
	for record: Dictionary in _sources.values():
		record.remaining = int(record.index) * profile.source_stagger_seconds
	_preparation_skipped = true
	return true


func on_fragment_collected(id: StringName, _text: String) -> void:
	if _stopped or not _configured or id.is_empty() or _collected_ids.has(id):
		return
	_collected_ids.append(id)
	_collected = mini(3, _collected + 1)
	for record: Dictionary in _sources.values():
		record.remaining = maxf(float(record.remaining), profile.collection_grace_seconds)
	changed.emit(get_snapshot())


func get_snapshot() -> Dictionary:
	var sources: Array[Dictionary] = []
	for id: StringName in _sources:
		var record: Dictionary = _sources[id]
		var marker: Variant = record.marker
		sources.append({"id": id, "remaining": record.remaining, "phase": record.phase,
			"position": marker.global_position if is_instance_valid(marker) else Vector2.ZERO,
			"cycles": record.cycles, "load": _source_load(id) if _configured else 0})
	return {"state": "stopped" if _stopped else "fighting", "sources": sources, "spawned": _spawned,
		"elapsed_seconds": elapsed_seconds, "stage": profile.get_stage(elapsed_seconds, _collected) if profile != null else 0,
		"can_start": _configured and not _stopped and not _preparation_skipped and elapsed_seconds < profile.preparation_seconds}


func stop(reason: StringName) -> void:
	if _stopped:
		return
	_stopped = true
	for batch: Dictionary in _batches:
		var spawner: Variant = batch.spawner
		if is_instance_valid(spawner):
			spawner.stop_spawning(reason)


func _exit_tree() -> void:
	stop(&"scene_exit")


func _spawn_cycle(id: StringName) -> bool:
	var record: Dictionary = _sources[id]
	var point: Vector2 = _find_safe_spawn(record.marker.global_position)
	if not point.is_finite():
		return false
	var scenes: Array[PackedScene] = profile.get_exploration_scenes(elapsed_seconds, int(record.cycles), int(record.index), _collected)
	var capacity: int = profile.max_alive_per_source - _source_load(id)
	var entries: Array[EnemySpawnEntry] = []
	for index: int in range(mini(scenes.size(), capacity)):
		var scene: PackedScene = scenes[index]
		if scene == profile.swarm_scene and not entries.is_empty() and entries.back().enemy_scene == scene:
			entries.back().group_size += 1
			entries.back().member_interval = 0.25
			continue
		var entry := EnemySpawnEntry.new()
		entry.enemy_scene = scene
		entry.group_interval = profile.member_interval
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


func _on_enemy_spawned(enemy: BasicEnemy, spawn_id: String, batch_id: String, id: StringName) -> void:
	if _stopped:
		return
	if not _point_is_clear(enemy.global_position):
		var point: Vector2 = _find_safe_spawn(_sources[id].marker.global_position)
		if not point.is_finite():
			enemy.queue_free()
			return
		enemy.global_position = point
	enemy.set_meta("source_id", id)
	_level._on_terrain_enemy_spawned(enemy, spawn_id, batch_id)
	_spawned += 1
	enemy_created.emit(enemy)


func _find_safe_spawn(origin: Vector2) -> Vector2:
	var candidates: Array[Vector2] = [origin]
	for radius: float in [60.0, 100.0]:
		for index: int in range(12):
			candidates.append(origin + Vector2.from_angle(index * TAU / 12.0) * radius)
	for point: Vector2 in candidates:
		if _point_is_clear(point):
			return point
	return Vector2(INF, INF)


func _point_is_clear(point: Vector2) -> bool:
	if not point.is_finite() or not _level.terrain_navigation.is_point_walkable(point, BasicEnemy.NAVIGATION_CLEARANCE):
		return false
	for fragment: MemoryFragment in _level.get_fragment_targets():
		if point.distance_to(fragment.global_position) < 75:
			return false
	for edge: HyphaEdge in _level.network_system.get_registered_edges():
		if is_instance_valid(edge) and edge.has_endpoints() and point.distance_to(
				Geometry2D.get_closest_point_to_segment(point, edge.start_node.global_position, edge.end_node.global_position)) < 24:
			return false
	for tissue: Node in get_tree().get_nodes_in_group("colony_tissues"):
		if tissue is Node2D and not tissue is HyphaEdge and _level.is_ancestor_of(tissue) \
				and point.distance_to(tissue.global_position) < 42:
			return false
	return true
