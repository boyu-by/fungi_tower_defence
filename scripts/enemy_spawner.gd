class_name EnemySpawner
extends Node
## 一批有限敌人。配置在接受 start 时冻结；身份先登记，再入树和通知。

signal wave_changed(spawned: int, defeated: int, active: int, total: int)
signal wave_finished
signal batch_started(batch_id: String, planned: int)
signal batch_changed(snapshot: Dictionary)
signal enemy_spawned(enemy: BasicEnemy, spawn_id: String, batch_id: String)
signal batch_finished(batch_id: String)
signal batch_stopped(batch_id: String, reason: StringName)

const MAX_BATCH_COUNT: int = 500

@export var mother_core: MotherCore
@export var enemy_container: Node2D
@export var spawn_points: Node2D
@export var enemy_scene: PackedScene
@export_range(1, 500, 1) var wave_size: int = 6
@export var auto_start: bool = true
@export var spawn_entries: Array[EnemySpawnEntry] = []

var spawned_count: int = 0
var defeated_count: int = 0
var _active_enemies: Dictionary[int, BasicEnemy] = {}
var _enemy_callbacks: Dictionary[int, Dictionary] = {}
var _adding_enemies: Dictionary[int, bool] = {}
var _environment_callbacks: Array[Dictionary] = []
var _entries: Array[EnemySpawnEntry] = []
var _points: Array[Node] = []
var _batch_core: MotherCore
var _batch_container: Node2D
var _batch_points_container: Node2D
var _batch_id: String = ""
var _generation: int = 0
var _batch_serial: int = 0
var _spawn_serial: int = 0
var _timer_serial: int = 0
var _armed_timer_serial: int = 0
var _state: StringName = &"idle"
var _reason: StringName = &""
var _planned_count: int = 0
var _removed_count: int = 0
var _legacy: bool = true
var _entry_index: int = 0
var _group_index: int = 0
var _member_index: int = 0
var _point_cursor: int = 0
var _group_positions := PackedVector2Array()
var _next_delay: float = 0.0
var _configured_spawn_interval: float = 3.0
var _start_callback: Callable
var _spawn_callback: Callable
var _completion_emitted: bool = false
var _exiting: bool = false
var _preparing: bool = false
var _preparation_cancelled: bool = false

@onready var start_timer: Timer = get_node_or_null("StartTimer") as Timer
@onready var spawn_timer: Timer = get_node_or_null("SpawnTimer") as Timer


func _enter_tree() -> void:
	_exiting = false


func _ready() -> void:
	if is_instance_valid(spawn_timer):
		_configured_spawn_interval = spawn_timer.wait_time
		spawn_timer.one_shot = true
	if auto_start:
		_arm_auto_start()


func _exit_tree() -> void:
	_exiting = true
	_generation += 1
	_cancel_timers()
	_disconnect_environment()
	_disconnect_all_enemies()
	if _state in [&"waiting", &"spawning", &"draining"]:
		_state = &"stopped"
		_reason = &"exited_tree"


func _on_start_timer_timeout(generation: int, batch_id: String, timer_id: int) -> void:
	if not _is_current(generation, batch_id) or _state != &"waiting" \
			or timer_id != _armed_timer_serial:
		return
	start_batch()


func _on_spawn_timer_timeout(generation: int, batch_id: String, timer_id: int) -> void:
	if not _can_spawn(generation, batch_id) or timer_id != _armed_timer_serial:
		return
	_cancel_spawn_timer()
	_spawn_due_members(generation, batch_id)


func _on_core_depleted(generation: int, batch_id: String) -> void:
	if not _is_current(generation, batch_id):
		return
	stop_spawning(&"core_depleted")


func _on_environment_removed(reason: StringName, generation: int, batch_id: String) -> void:
	if not _is_current(generation, batch_id):
		return
	stop_spawning(reason)


func _on_enemy_died(enemy: BasicEnemy, enemy_id: int, generation: int, batch_id: String) -> void:
	if not _is_current(generation, batch_id) or not _active_enemies.has(enemy_id) \
			or not is_instance_valid(enemy) or _active_enemies[enemy_id] != enemy:
		return
	_settle_enemy(enemy_id, true, generation, batch_id)


func _on_enemy_removed(enemy_id: int, generation: int, batch_id: String) -> void:
	if not _is_current(generation, batch_id) or not _active_enemies.has(enemy_id):
		return
	_settle_enemy(enemy_id, false, generation, batch_id)


func start_batch() -> String:
	if not is_inside_tree() or is_queued_for_deletion() or _exiting \
			or _preparing or _state in [&"spawning", &"draining", &"stopped"]:
		return ""
	if is_instance_valid(spawn_timer) and not _spawn_callback.is_valid():
		_configured_spawn_interval = spawn_timer.wait_time
	var plan := _prepare_locked()
	if plan.is_empty():
		return ""
	if not (plan["errors"] as PackedStringArray).is_empty():
		_reject_plan(plan["errors"])
		return ""

	_generation += 1
	_cancel_timers()
	_disconnect_environment()
	_disconnect_all_enemies()
	_clear_counts()
	_entries.assign(plan["entries"])
	_points.assign(plan["points"])
	_batch_core = mother_core
	_batch_container = enemy_container
	_batch_points_container = spawn_points
	_planned_count = plan["planned"]
	_legacy = plan["legacy"]
	_batch_serial += 1
	_batch_id = "%d:%d" % [get_instance_id(), _batch_serial]
	_state = &"spawning"
	_reason = &""
	var accepted_id := _batch_id
	var accepted_generation := _generation
	_bind_environment(accepted_generation, accepted_id)
	batch_started.emit(accepted_id, _planned_count)
	if _can_spawn(accepted_generation, accepted_id):
		_spawn_due_members(accepted_generation, accepted_id)
	return accepted_id


func start_wave() -> void:
	start_batch()


func stop_spawning(reason: StringName = &"manual") -> void:
	if _preparing:
		_preparation_cancelled = true
	if _exiting or _state in [&"stopped", &"invalid", &"completed"]:
		return
	_generation += 1
	_cancel_timers()
	_disconnect_environment()
	_disconnect_all_enemies()
	_state = &"stopped"
	_reason = reason
	var stopped_generation := _generation
	var stopped_id := _batch_id
	# 旧 Callable 全部退役；现有成员的真实终结由新一代监听继续结算。
	for enemy_id: int in _active_enemies:
		if is_instance_valid(_active_enemies[enemy_id]):
			_bind_enemy(_active_enemies[enemy_id], enemy_id, stopped_generation, stopped_id)
	_emit_changed(stopped_generation, stopped_id)
	if _is_current(stopped_generation, stopped_id) and not stopped_id.is_empty():
		batch_stopped.emit(stopped_id, reason)


func reset() -> void:
	if _preparing:
		_preparation_cancelled = true
	var retiring: Array[BasicEnemy] = []
	retiring.assign(_active_enemies.values())
	_generation += 1
	_cancel_timers()
	_disconnect_environment()
	_disconnect_all_enemies()
	_clear_counts()
	_entries.clear()
	_points.clear()
	_batch_core = null
	_batch_container = null
	_batch_points_container = null
	_batch_id = ""
	_state = &"idle"
	_reason = &""
	_legacy = spawn_entries.is_empty()
	var reset_generation := _generation
	# 先清空身份，再移出自有活体；tree_exiting 的同步重入不能污染新批。
	for enemy: BasicEnemy in retiring:
		if is_instance_valid(enemy):
			var parent := enemy.get_parent()
			# add_child 尚在派发入树通知时，父节点不能同步 remove_child。
			if _adding_enemies.has(enemy.get_instance_id()):
				enemy.process_mode = Node.PROCESS_MODE_DISABLED
			elif is_instance_valid(parent):
				parent.remove_child(enemy)
			if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
				enemy.queue_free()
	_emit_changed(reset_generation, "")


func get_planned_count() -> int:
	if _state in [&"idle", &"waiting"] and _batch_id.is_empty():
		var plan := _prepare_locked()
		if not plan.is_empty() and (plan["errors"] as PackedStringArray).is_empty():
			return plan["planned"]
		return 0
	return _planned_count


func get_active_count() -> int:
	return _active_enemies.size()


## 只读成员身份；提示模块不能借查询结算死亡或删除旧成员。
func has_active_enemy(enemy: Variant) -> bool:
	return is_instance_valid(enemy) and enemy is BasicEnemy \
		and _active_enemies.get(enemy.get_instance_id()) == enemy


func get_batch_snapshot() -> Dictionary:
	return {
		"batch_id": _batch_id, "generation": _generation, "state": String(_state),
		"planned": _planned_count, "spawned": spawned_count,
		"active": get_active_count(), "defeated": defeated_count,
		"removed": _removed_count, "unspawned": _planned_count - spawned_count,
		"reason": String(_reason), "legacy": _legacy,
	}


func _arm_auto_start() -> void:
	if not is_instance_valid(start_timer) or not start_timer.is_inside_tree():
		_reject_plan(PackedStringArray(["StartTimer is unavailable"]))
		return
	_generation += 1
	_state = &"waiting"
	_batch_core = mother_core
	_batch_container = enemy_container
	_batch_points_container = spawn_points
	_bind_environment(_generation, "")
	_timer_serial += 1
	_armed_timer_serial = _timer_serial
	_start_callback = _on_start_timer_timeout.bind(_generation, "", _armed_timer_serial)
	start_timer.timeout.connect(_start_callback)
	start_timer.one_shot = true
	start_timer.start()
	_emit_changed(_generation, "")


func _prepare_locked() -> Dictionary:
	if _preparing:
		return {}
	_preparing = true
	_preparation_cancelled = false
	var generation := _generation
	var batch_id := _batch_id
	var signature := _configuration_signature()
	var plan := _prepare_plan()
	_preparing = false
	if _preparation_cancelled or not _is_current(generation, batch_id):
		return {}
	if signature != _configuration_signature():
		var errors: PackedStringArray = plan["errors"]
		errors.append("configuration changed during preparation")
		plan["errors"] = errors
	return plan


func _configuration_signature() -> int:
	var entries: Array = []
	for entry: EnemySpawnEntry in spawn_entries:
		if entry == null:
			entries.append(null)
		else:
			entries.append([entry.get_instance_id(), _scene_signature(entry.enemy_scene),
				entry.group_count, entry.group_size, entry.group_interval, entry.member_interval,
				entry.member_spacing, entry.spawn_point_index])
	var points: Array = []
	if is_instance_valid(spawn_points):
		for child: Node in spawn_points.get_children():
			points.append([child.get_instance_id(), child.is_queued_for_deletion(),
				(child as Node2D).global_transform if child is Node2D else Transform2D.IDENTITY])
	return hash([entries, _scene_signature(enemy_scene), wave_size, points,
		mother_core.get_instance_id() if is_instance_valid(mother_core) else 0,
		mother_core.health if is_instance_valid(mother_core) else 0,
		mother_core.global_transform if is_instance_valid(mother_core) else Transform2D.IDENTITY,
		enemy_container.get_instance_id() if is_instance_valid(enemy_container) else 0,
		enemy_container.global_transform if is_instance_valid(enemy_container) else Transform2D.IDENTITY,
		spawn_points.get_instance_id() if is_instance_valid(spawn_points) else 0,
		spawn_timer.wait_time if is_instance_valid(spawn_timer) else _configured_spawn_interval])


func _scene_signature(scene: PackedScene) -> Array:
	if scene == null:
		return []
	return [scene.get_instance_id(), hash(scene.get("_bundled"))]


func _prepare_plan() -> Dictionary:
	var errors := PackedStringArray()
	var entries: Array[EnemySpawnEntry] = []
	var points: Array[Node] = []
	var legacy := spawn_entries.is_empty()
	if legacy:
		var entry := EnemySpawnEntry.new()
		entry.enemy_scene = enemy_scene
		entry.group_count = wave_size
		entry.group_size = 1
		entry.group_interval = _configured_spawn_interval
		if is_instance_valid(spawn_timer) and not _spawn_callback.is_valid():
			entry.group_interval = spawn_timer.wait_time
		entries.append(entry.copy_for_instance())
	else:
		for index in range(spawn_entries.size()):
			var entry := spawn_entries[index]
			if entry == null:
				errors.append("entry %d is null" % index)
			else:
				entries.append(entry.copy_for_instance())
	var planned := 0
	for index in range(entries.size()):
		var entry := entries[index]
		for error: String in entry.get_validation_errors():
			errors.append("entry %d: %s" % [index, error])
		var count := entry.get_total_count()
		if count > MAX_BATCH_COUNT - planned or count < 0:
			errors.append("batch cannot exceed 500 enemies")
		elif count > 0:
			planned += count
	if planned <= 0:
		errors.append("batch must plan at least one enemy")
	if not is_instance_valid(mother_core) or mother_core.is_queued_for_deletion() \
			or not mother_core.is_inside_tree() or mother_core.health <= 0:
		errors.append("mother_core must be alive and inside the tree")
	if not is_instance_valid(enemy_container) or enemy_container.is_queued_for_deletion() \
			or not enemy_container.is_inside_tree():
		errors.append("enemy_container is unavailable")
	if not is_instance_valid(spawn_points) or spawn_points.is_queued_for_deletion() \
			or not spawn_points.is_inside_tree() or spawn_points.get_child_count() == 0:
		errors.append("spawn_points must contain live Node2D anchors")
	else:
		points.assign(spawn_points.get_children())
		var cursor := 0
		for entry: EnemySpawnEntry in entries:
			if entry.spawn_point_index >= points.size():
				errors.append("spawn_point_index is outside spawn_points children")
			elif entry.group_count > 0 and entry.group_count <= MAX_BATCH_COUNT:
				for group in range(entry.group_count):
					var point_index := entry.spawn_point_index
					if point_index == -1:
						point_index = cursor % points.size()
						cursor += 1
					if point_index >= 0 and point_index < points.size():
						var point := points[point_index]
						if not point is Node2D or point.is_queued_for_deletion():
							errors.append("selected spawn point must be a live Node2D anchor")
	return {"errors": errors, "entries": entries, "points": points,
		"planned": planned, "legacy": legacy}


func _reject_plan(errors: PackedStringArray) -> void:
	_generation += 1
	_cancel_timers()
	_disconnect_environment()
	_disconnect_all_enemies()
	if _batch_id.is_empty():
		_clear_counts()
		_entries.clear()
		_points.clear()
		_legacy = spawn_entries.is_empty()
	_state = &"invalid"
	_reason = StringName("invalid_configuration: " + "; ".join(errors))
	_emit_changed(_generation, _batch_id)


func _spawn_due_members(generation: int, batch_id: String) -> void:
	var continue_now := true
	while continue_now and _can_spawn(generation, batch_id):
		continue_now = _spawn_one(generation, batch_id)
		if continue_now and _can_spawn(generation, batch_id):
			if _next_delay > 0.0:
				_arm_spawn_timer(_next_delay, generation, batch_id)
				continue_now = false


func _spawn_one(generation: int, batch_id: String) -> bool:
	if not _can_spawn(generation, batch_id) or not _ensure_environment():
		return false
	var entry := _entries[_entry_index]
	if _member_index == 0 and not _prepare_group(entry):
		return false
	var position := _group_positions[_member_index]
	var instance: Node = entry.enemy_scene.instantiate()
	if not _can_spawn(generation, batch_id) or not _ensure_environment():
		if is_instance_valid(instance):
			instance.free()
		return false
	if not instance is BasicEnemy:
		if is_instance_valid(instance):
			instance.free()
		stop_spawning(&"invalid_enemy_scene")
		return false
	var enemy := instance as BasicEnemy
	enemy.mother_core = _batch_core
	# 容器可有平移、旋转、缩放；入树回调必须已经能看到正确世界位置。
	enemy.position = _batch_container.to_local(position)
	var enemy_id := enemy.get_instance_id()
	_spawn_serial += 1
	var spawn_id := "%s:%d" % [batch_id, _spawn_serial]
	enemy.set_meta(&"spawn_id", spawn_id)
	enemy.set_meta(&"batch_id", batch_id)
	_active_enemies[enemy_id] = enemy
	_bind_enemy(enemy, enemy_id, generation, batch_id)
	spawned_count += 1
	_advance_member(entry)
	if spawned_count == _planned_count:
		_state = &"draining"
		_cancel_spawn_timer()
	_adding_enemies[enemy_id] = true
	_batch_container.add_child(enemy)
	_adding_enemies.erase(enemy_id)
	if not _is_current(generation, batch_id):
		return false
	if is_instance_valid(enemy):
		enemy_spawned.emit(enemy, spawn_id, batch_id)
	if not _is_current(generation, batch_id):
		return false
	# 同步移出/删除当前成员会取消剩余生成；真正死亡仍正常结算。
	if not is_instance_valid(enemy) or enemy.is_queued_for_deletion() \
			or not enemy.is_inside_tree() or enemy.get_parent() != _batch_container:
		if _state == &"spawning":
			stop_spawning(&"enemy_removed_during_spawn")
		return false
	_emit_changed(generation, batch_id)
	if not _is_current(generation, batch_id):
		return false
	if not is_instance_valid(enemy) or enemy.is_queued_for_deletion() \
			or not enemy.is_inside_tree() or enemy.get_parent() != _batch_container:
		if _state == &"spawning":
			stop_spawning(&"enemy_removed_during_spawn")
		return false
	_finish_if_ready(generation, batch_id)
	return _can_spawn(generation, batch_id)


func _prepare_group(entry: EnemySpawnEntry) -> bool:
	var index := entry.spawn_point_index
	if index == -1:
		index = _point_cursor % _points.size()
		_point_cursor += 1
	var point := _points[index] as Node2D
	if not is_instance_valid(point) or point.is_queued_for_deletion() \
			or not point.is_inside_tree() or point.get_parent() != _batch_points_container:
		stop_spawning(&"spawn_point_unavailable")
		return false
	var center := point.global_position
	var direction := _batch_core.global_position - center
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	var perpendicular := direction.normalized().orthogonal()
	_group_positions.clear()
	for member in range(entry.group_size):
		var offset := (float(member) - float(entry.group_size - 1) * 0.5) * entry.member_spacing
		_group_positions.append(center + perpendicular * offset)
	return true


func _advance_member(entry: EnemySpawnEntry) -> void:
	_member_index += 1
	_next_delay = entry.member_interval
	if _member_index == entry.group_size:
		_member_index = 0
		_group_index += 1
		_group_positions.clear()
		_next_delay = entry.group_interval
		if _group_index == entry.group_count:
			_group_index = 0
			_entry_index += 1


func _ensure_environment() -> bool:
	var reason: StringName = &""
	if not is_instance_valid(_batch_core) or _batch_core.is_queued_for_deletion() \
			or not _batch_core.is_inside_tree():
		reason = &"core_unavailable"
	elif _batch_core.health <= 0:
		reason = &"core_depleted"
	elif not is_instance_valid(_batch_container) or _batch_container.is_queued_for_deletion() \
			or not _batch_container.is_inside_tree():
		reason = &"enemy_container_unavailable"
	elif not is_instance_valid(_batch_points_container) or _batch_points_container.is_queued_for_deletion() \
			or not _batch_points_container.is_inside_tree():
		reason = &"spawn_points_unavailable"
	if reason.is_empty():
		for point: Node in _points:
			if not is_instance_valid(point) or point.is_queued_for_deletion() \
					or not point.is_inside_tree() or point.get_parent() != _batch_points_container:
				reason = &"spawn_point_unavailable"
				break
	if not reason.is_empty():
		stop_spawning(reason)
	return reason.is_empty()


func _arm_spawn_timer(delay: float, generation: int, batch_id: String) -> void:
	if not _can_spawn(generation, batch_id):
		return
	if not is_instance_valid(spawn_timer) or spawn_timer.is_queued_for_deletion() \
			or not spawn_timer.is_inside_tree():
		stop_spawning(&"spawn_timer_unavailable")
		return
	_cancel_spawn_timer()
	_timer_serial += 1
	_armed_timer_serial = _timer_serial
	_spawn_callback = _on_spawn_timer_timeout.bind(generation, batch_id, _armed_timer_serial)
	spawn_timer.timeout.connect(_spawn_callback)
	spawn_timer.start(delay)


func _cancel_spawn_timer() -> void:
	_armed_timer_serial = 0
	if is_instance_valid(spawn_timer):
		spawn_timer.stop()
		if _spawn_callback.is_valid() and spawn_timer.timeout.is_connected(_spawn_callback):
			spawn_timer.timeout.disconnect(_spawn_callback)
		spawn_timer.wait_time = _configured_spawn_interval
	_spawn_callback = Callable()


func _cancel_timers() -> void:
	if is_instance_valid(start_timer):
		start_timer.stop()
		if _start_callback.is_valid() and start_timer.timeout.is_connected(_start_callback):
			start_timer.timeout.disconnect(_start_callback)
	_start_callback = Callable()
	_cancel_spawn_timer()


func _bind_environment(generation: int, batch_id: String) -> void:
	if is_instance_valid(_batch_core):
		_connect_environment(_batch_core.depleted, _on_core_depleted.bind(generation, batch_id))
		_connect_environment(_batch_core.tree_exiting,
			_on_environment_removed.bind(&"core_unavailable", generation, batch_id))
	if is_instance_valid(_batch_container):
		_connect_environment(_batch_container.tree_exiting,
			_on_environment_removed.bind(&"enemy_container_unavailable", generation, batch_id))
	if is_instance_valid(_batch_points_container):
		_connect_environment(_batch_points_container.tree_exiting,
			_on_environment_removed.bind(&"spawn_points_unavailable", generation, batch_id))
	for point: Node in _points:
		if is_instance_valid(point):
			_connect_environment(point.tree_exiting,
				_on_environment_removed.bind(&"spawn_point_unavailable", generation, batch_id))


func _connect_environment(notification: Signal, callback: Callable) -> void:
	notification.connect(callback)
	_environment_callbacks.append({"owner": weakref(notification.get_object()),
		"signal": notification, "callback": callback})


func _disconnect_environment() -> void:
	for record: Dictionary in _environment_callbacks:
		var notification: Signal = record["signal"]
		var callback: Callable = record["callback"]
		if is_instance_valid((record["owner"] as WeakRef).get_ref()) \
				and notification.is_connected(callback):
			notification.disconnect(callback)
	_environment_callbacks.clear()


func _bind_enemy(enemy: BasicEnemy, enemy_id: int, generation: int, batch_id: String) -> void:
	if not is_instance_valid(enemy):
		return
	var died_callback := _on_enemy_died.bind(enemy_id, generation, batch_id)
	var removed_callback := _on_enemy_removed.bind(enemy_id, generation, batch_id)
	enemy.died.connect(died_callback)
	enemy.tree_exiting.connect(removed_callback)
	_enemy_callbacks[enemy_id] = {"enemy": weakref(enemy),
		"died": died_callback, "removed": removed_callback}


func _disconnect_enemy(enemy_id: int) -> void:
	if not _enemy_callbacks.has(enemy_id):
		return
	var record: Dictionary = _enemy_callbacks[enemy_id]
	_enemy_callbacks.erase(enemy_id)
	var enemy := (record["enemy"] as WeakRef).get_ref() as BasicEnemy
	if is_instance_valid(enemy):
		if enemy.died.is_connected(record["died"]):
			enemy.died.disconnect(record["died"])
		if enemy.tree_exiting.is_connected(record["removed"]):
			enemy.tree_exiting.disconnect(record["removed"])


func _disconnect_all_enemies() -> void:
	for enemy_id: int in _enemy_callbacks.keys():
		_disconnect_enemy(enemy_id)


func _settle_enemy(enemy_id: int, defeated: bool, generation: int, batch_id: String) -> void:
	_active_enemies.erase(enemy_id)
	_disconnect_enemy(enemy_id)
	if defeated:
		defeated_count += 1
	else:
		_removed_count += 1
	_emit_changed(generation, batch_id)
	_finish_if_ready(generation, batch_id)


func _finish_if_ready(generation: int, batch_id: String) -> void:
	if not _is_current(generation, batch_id) or _completion_emitted \
			or _state not in [&"spawning", &"draining"] \
			or spawned_count != _planned_count or get_active_count() != 0:
		return
	_completion_emitted = true
	_state = &"completed"
	_cancel_timers()
	_disconnect_environment()
	_emit_changed(generation, batch_id)
	if not _is_current(generation, batch_id):
		return
	batch_finished.emit(batch_id)
	if _is_current(generation, batch_id) and defeated_count == _planned_count \
			and _removed_count == 0:
		wave_finished.emit()


func _clear_counts() -> void:
	_active_enemies.clear()
	spawned_count = 0
	defeated_count = 0
	_removed_count = 0
	_planned_count = 0
	_entry_index = 0
	_group_index = 0
	_member_index = 0
	_point_cursor = 0
	_group_positions.clear()
	_next_delay = 0.0
	_completion_emitted = false


func _is_current(generation: int, batch_id: String) -> bool:
	return is_instance_valid(self) and not _exiting and is_inside_tree() \
		and not is_queued_for_deletion() and _generation == generation and _batch_id == batch_id


func _can_spawn(generation: int, batch_id: String) -> bool:
	return _is_current(generation, batch_id) and _state == &"spawning" \
		and spawned_count < _planned_count


func _emit_changed(generation: int, batch_id: String) -> void:
	if not _is_current(generation, batch_id):
		return
	var snapshot := get_batch_snapshot()
	wave_changed.emit(snapshot["spawned"], snapshot["defeated"], snapshot["active"], snapshot["planned"])
	if _is_current(generation, batch_id):
		batch_changed.emit(get_batch_snapshot())
