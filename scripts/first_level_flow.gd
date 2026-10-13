class_name FirstLevelFlow
extends Node
## 六波流程只管理批次与准备倒计时；关卡负责母核生死和最终结算。

signal changed(snapshot: Dictionary)
signal victory_candidate(evidence: Dictionary)
signal interrupted(reason: StringName)

const WAVE_TOTAL: int = 6

@export var waves: Array[FirstLevelWave] = [
	preload("res://resources/first_level_waves/wave_01.tres"),
	preload("res://resources/first_level_waves/wave_02.tres"),
	preload("res://resources/first_level_waves/wave_03.tres"),
	preload("res://resources/first_level_waves/wave_04.tres"),
	preload("res://resources/first_level_waves/wave_05.tres"),
	preload("res://resources/first_level_waves/wave_06.tres"),
]
@export var preparation_seconds: float = 20.0

var _spawner: EnemySpawner
var _bindings: Array[Dictionary] = []
var _generation: int = 0
var _operation_serial: int = 0
var _state: StringName = &"initial_preparation"
var _reason: StringName = &""
var _wave_index: int = 0
var _completed_waves: int = 0
var _total_defeated: int = 0
var _preparation_remaining: float = 0.0
var _batch_id: String = ""
var _batch_generation: int = -1
var _planned: int = 0
var _spawned: int = 0
var _defeated: int = 0
var _active: int = 0
var _removed: int = 0
var _unspawned: int = 0
var _starting: bool = false
var _dispatching_start: bool = false
var _transitioning: bool = false
var _completion_observed: bool = false
var _pending_completion: Dictionary = {}
var _exiting: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _enter_tree() -> void:
	_exiting = false


func _exit_tree() -> void:
	_exiting = true
	var owner := _spawner
	var retiring_id := _batch_id
	var retiring_generation := _batch_generation
	_invalidate()
	_state = &"stopped"
	_reason = &"flow_exited_tree"
	_stop_owned_batch(owner, retiring_id, retiring_generation, _reason)


func _process(delta: float) -> void:
	if not _is_live() or not can_process() or not is_finite(delta) or delta <= 0.0 \
			or _state in [&"interrupted", &"stopped"]:
		return
	if not _has_live_spawner():
		_interrupt(&"spawner_unavailable")
	elif _state == &"preparation":
		_preparation_remaining = maxf(0.0, _preparation_remaining - delta)
		if _preparation_remaining <= 0.0:
			begin_next_wave()
		else:
			changed.emit(get_snapshot())


func _on_batch_started(batch_id: String, planned: int, generation: int) -> void:
	if not _accepts_callback(generation):
		return
	var live := _spawner.get_batch_snapshot()
	if batch_id.is_empty() or String(live.get("batch_id", "")) != batch_id:
		return
	if not _starting or not _dispatching_start or _state != &"fighting" \
			or not _batch_id.is_empty():
		if batch_id == _batch_id and int(live.get("generation", -1)) == _batch_generation:
			return
		_interrupt(&"unexpected_batch_started")
		return
	if planned != _planned or int(live.get("planned", -1)) != _planned \
			or String(live.get("state", "")) not in ["spawning", "draining", "completed"]:
		_interrupt(_reason_from_snapshot(live, &"batch_identity_changed"))
	else:
		_batch_id = batch_id
		_batch_generation = int(live.get("generation", -1))
		_read_counts(live)


func _on_batch_changed(snapshot: Dictionary, generation: int) -> void:
	if not _accepts_callback(generation):
		return
	var live := _spawner.get_batch_snapshot()
	# 早先的监听器可以同步重置或开启另一批；退役快照不能倒写新状态。
	if snapshot != live:
		return
	if _state == &"initial_preparation":
		if String(live.get("state", "")) != "idle":
			_interrupt(_reason_from_snapshot(live, &"unexpected_batch_started"))
		return
	if not _matches_batch(live):
		_interrupt(_reason_from_snapshot(live, &"batch_identity_changed"))
		return
	if _state == &"fighting":
		_read_counts(live)
		var batch_state := String(live.get("state", ""))
		if _removed > 0:
			_interrupt(&"enemy_removed")
		elif batch_state not in ["spawning", "draining", "completed"]:
			_interrupt(_reason_from_snapshot(live, &"batch_interrupted"))
		else:
			_completion_observed = batch_state == "completed"
			if not _starting:
				changed.emit(get_snapshot())
	elif _state in [&"preparation", &"victory_candidate"] and not _is_clear(live):
		_interrupt(_reason_from_snapshot(live, &"completed_batch_invalidated"))


func _on_batch_finished(batch_id: String, generation: int) -> void:
	if not _accepts_callback(generation) or _state != &"fighting" \
			or batch_id != _batch_id:
		return
	var live := _spawner.get_batch_snapshot()
	if not _completion_observed or not _is_clear(live):
		return
	# start_batch 的同步回调可能已经杀死最后成员；返回身份确认后再结算。
	if _starting:
		_pending_completion = live.duplicate(true)
	else:
		_complete_wave(live)


func _on_batch_stopped(batch_id: String, reason: StringName, generation: int) -> void:
	if not _accepts_callback(generation) or batch_id != _batch_id:
		return
	var live := _spawner.get_batch_snapshot()
	if String(live.get("batch_id", "")) != batch_id \
			or String(live.get("state", "")) != "stopped" \
			or StringName(String(live.get("reason", ""))) != reason:
		return
	_interrupt(reason if not reason.is_empty() else &"batch_stopped")


func _on_spawner_exiting(generation: int) -> void:
	if generation != _generation or not _is_live() \
			or _state in [&"interrupted", &"stopped"]:
		return
	_interrupt(&"spawner_exited_tree")


func configure(spawner: EnemySpawner) -> void:
	var previous := _spawner
	var retiring_id := _batch_id
	var retiring_generation := _batch_generation
	_invalidate()
	_clear_flow()
	_spawner = spawner
	var generation := _generation
	_stop_owned_batch(previous, retiring_id, retiring_generation, &"flow_reconfigured")
	if generation == _generation:
		_prepare_configuration()


func begin_next_wave() -> bool:
	if not _can_start() or not _is_live() or not can_process():
		return false
	var previous := _spawner.get_batch_snapshot()
	if _wave_index == 0 and String(previous.get("state", "")) != "idle":
		_interrupt(_reason_from_snapshot(previous, &"spawner_not_idle"))
		return false
	if _wave_index > 0 and not _is_clear(previous):
		_interrupt(_reason_from_snapshot(previous, &"completed_batch_invalidated"))
		return false
	var wave := waves[_wave_index]
	var planned := _get_wave_count(wave)
	if planned <= 0:
		_interrupt(&"invalid_wave_configuration")
		return false
	var entries: Array[EnemySpawnEntry] = []
	for entry: EnemySpawnEntry in wave.entries:
		entries.append(entry.copy_for_instance())
	# 每波重新绑定一代 Callable；上一波保存的退出/停止通知也随之退役。
	_generation += 1
	_disconnect_spawner()
	_connect_spawner()
	_operation_serial += 1
	var operation := _operation_serial
	var generation := _generation
	_wave_index += 1
	_state = &"fighting"
	_reason = &""
	_preparation_remaining = 0.0
	_batch_id = ""
	_batch_generation = -1
	_planned = planned
	_spawned = 0
	_defeated = 0
	_active = 0
	_removed = 0
	_unspawned = planned
	_completion_observed = false
	_pending_completion.clear()
	_starting = true
	_spawner.spawn_entries = entries
	_dispatching_start = true
	var accepted_id := _spawner.start_batch()
	if not _is_operation_current(generation, operation):
		return false
	_dispatching_start = false
	_starting = false
	if accepted_id.is_empty() or accepted_id != _batch_id:
		_interrupt(&"batch_start_rejected")
		return false
	var live := _spawner.get_batch_snapshot()
	if not _matches_batch(live):
		_interrupt(_reason_from_snapshot(live, &"batch_identity_changed"))
		return false
	_read_counts(live)
	if not _pending_completion.is_empty():
		var completion := _pending_completion.duplicate(true)
		_pending_completion.clear()
		_complete_wave(completion)
	else:
		changed.emit(get_snapshot())
	return true


func get_snapshot() -> Dictionary:
	var next_title: String = ""
	var next_direction: String = ""
	if _wave_index < waves.size() and waves[_wave_index] != null:
		next_title = waves[_wave_index].title
		next_direction = waves[_wave_index].direction_text
	return {
		"state": String(_state), "wave_index": _wave_index,
		"completed_waves": _completed_waves, "wave_total": WAVE_TOTAL,
		"planned": _planned, "spawned": _spawned, "defeated": _defeated,
		"active": _active, "unspawned": _unspawned, "removed": _removed,
		"preparation_remaining": _preparation_remaining, "can_start": _can_start(),
		"next_title": next_title, "next_direction": next_direction,
		"total_defeated": _total_defeated, "batch_id": _batch_id,
		"batch_generation": _batch_generation, "reason": String(_reason),
	}


func stop(reason: StringName) -> void:
	if _state == &"stopped":
		return
	var owner := _spawner
	var retiring_id := _batch_id
	var retiring_generation := _batch_generation
	_invalidate()
	_state = &"stopped"
	_reason = reason
	var generation := _generation
	_stop_owned_batch(owner, retiring_id, retiring_generation, reason)
	if generation == _generation and _is_live():
		changed.emit(get_snapshot())


func reset() -> void:
	_invalidate()
	_clear_flow()
	var owner := _spawner
	var generation := _generation
	# 身份和监听先退役；删除旧活体产生的同步通知不得成为清波证据。
	if is_instance_valid(owner) and not owner.is_queued_for_deletion():
		owner.reset()
	if generation == _generation and owner == _spawner:
		_prepare_configuration()


func _prepare_configuration() -> void:
	if not is_instance_valid(_spawner) or _spawner.is_queued_for_deletion():
		_interrupt(&"spawner_unavailable")
	elif _spawner.auto_start:
		_interrupt(&"spawner_auto_start_enabled")
	elif String(_spawner.get_batch_snapshot().get("state", "")) != "idle":
		_interrupt(&"spawner_not_idle")
	elif waves.size() != WAVE_TOTAL:
		_interrupt(&"invalid_wave_count")
	elif not is_finite(preparation_seconds) or preparation_seconds < 0.0:
		_interrupt(&"invalid_preparation_seconds")
	else:
		_connect_spawner()
		changed.emit(get_snapshot())


func _connect_spawner() -> void:
	_bind(_spawner.batch_started, _on_batch_started.bind(_generation))
	_bind(_spawner.batch_changed, _on_batch_changed.bind(_generation))
	_bind(_spawner.batch_finished, _on_batch_finished.bind(_generation))
	_bind(_spawner.batch_stopped, _on_batch_stopped.bind(_generation))
	_bind(_spawner.tree_exiting, _on_spawner_exiting.bind(_generation))


func _bind(notification: Signal, callback: Callable) -> void:
	notification.connect(callback)
	_bindings.append({"owner": weakref(notification.get_object()),
		"signal": notification, "callback": callback})


func _disconnect_spawner() -> void:
	for record: Dictionary in _bindings:
		var notification: Signal = record["signal"]
		var callback: Callable = record["callback"]
		if is_instance_valid((record["owner"] as WeakRef).get_ref()) \
				and notification.is_connected(callback):
			notification.disconnect(callback)
	_bindings.clear()


func _invalidate() -> void:
	_generation += 1
	_operation_serial += 1
	_disconnect_spawner()
	_starting = false
	_dispatching_start = false
	_transitioning = false
	_completion_observed = false
	_pending_completion.clear()
	_preparation_remaining = 0.0


func _clear_flow() -> void:
	_state = &"initial_preparation"
	_reason = &""
	_wave_index = 0
	_completed_waves = 0
	_total_defeated = 0
	_batch_id = ""
	_batch_generation = -1
	_planned = 0
	_spawned = 0
	_defeated = 0
	_active = 0
	_removed = 0
	_unspawned = 0


func _complete_wave(evidence: Dictionary) -> void:
	if _state != &"fighting" or not _is_clear(evidence) \
			or evidence != _spawner.get_batch_snapshot() or not _completion_observed:
		return
	_read_counts(evidence)
	_completed_waves += 1
	_completion_observed = false
	var generation := _generation
	var operation := _operation_serial
	_transitioning = true
	if _completed_waves == WAVE_TOTAL:
		_state = &"victory_candidate"
		_transitioning = false
		var candidate := evidence.duplicate(true)
		candidate["wave_index"] = _wave_index
		candidate["completed_waves"] = _completed_waves
		candidate["wave_total"] = WAVE_TOTAL
		candidate["total_defeated"] = _total_defeated
		# 最终快照由关卡在确认活母核与失败优先级后发布。
		victory_candidate.emit(candidate)
	else:
		_state = &"preparation"
		_preparation_remaining = preparation_seconds
		_transitioning = false
		changed.emit(get_snapshot())
		if _is_operation_current(generation, operation):
			_transitioning = false


func _interrupt(reason: StringName) -> void:
	if _state in [&"interrupted", &"stopped"] or _exiting:
		return
	var owner := _spawner
	var retiring_id := _batch_id
	var retiring_generation := _batch_generation
	_invalidate()
	_state = &"interrupted"
	_reason = reason
	var generation := _generation
	_stop_owned_batch(owner, retiring_id, retiring_generation, reason)
	if generation == _generation and not _exiting:
		changed.emit(get_snapshot())
		if generation == _generation and _state == &"interrupted":
			interrupted.emit(reason)


func _stop_owned_batch(owner: Variant, batch_id: String, generation: int,
		reason: StringName) -> void:
	if batch_id.is_empty() or not is_instance_valid(owner) \
			or not owner is EnemySpawner:
		return
	var spawner := owner as EnemySpawner
	if spawner.is_queued_for_deletion() or not spawner.is_inside_tree():
		return
	var live := spawner.get_batch_snapshot()
	if String(live.get("batch_id", "")) == batch_id \
			and int(live.get("generation", -1)) == generation:
		spawner.stop_spawning(reason)


func _read_counts(snapshot: Dictionary) -> void:
	var defeated := int(snapshot.get("defeated", 0))
	_total_defeated += maxi(0, defeated - _defeated)
	_spawned = int(snapshot.get("spawned", 0))
	_defeated = defeated
	_active = int(snapshot.get("active", 0))
	_removed = int(snapshot.get("removed", 0))
	_unspawned = int(snapshot.get("unspawned", _planned - _spawned))


func _get_wave_count(wave: FirstLevelWave) -> int:
	if wave == null or wave.entries.is_empty():
		return 0
	var planned: int = 0
	for entry: EnemySpawnEntry in wave.entries:
		if entry == null:
			return 0
		var count := entry.get_total_count()
		if count <= 0 or count > EnemySpawner.MAX_BATCH_COUNT - planned:
			return 0
		planned += count
	return planned


func _is_live() -> bool:
	return is_inside_tree() and not _exiting and not is_queued_for_deletion()


func _has_live_spawner() -> bool:
	return is_instance_valid(_spawner) and not _spawner.is_queued_for_deletion() \
		and _spawner.is_inside_tree()


func _accepts_callback(generation: int) -> bool:
	return generation == _generation and _is_live() and _has_live_spawner() \
		and _state not in [&"interrupted", &"stopped"]


func _is_operation_current(generation: int, operation: int) -> bool:
	return generation == _generation and operation == _operation_serial \
		and _is_live() and _state not in [&"interrupted", &"stopped"]


func _matches_batch(snapshot: Dictionary) -> bool:
	return not _batch_id.is_empty() and String(snapshot.get("batch_id", "")) == _batch_id \
		and int(snapshot.get("generation", -1)) == _batch_generation \
		and int(snapshot.get("planned", -1)) == _planned


func _is_clear(snapshot: Dictionary) -> bool:
	return _matches_batch(snapshot) and String(snapshot.get("state", "")) == "completed" \
		and _planned > 0 and int(snapshot.get("spawned", -1)) == _planned \
		and int(snapshot.get("defeated", -1)) == _planned \
		and int(snapshot.get("removed", -1)) == 0 \
		and int(snapshot.get("active", -1)) == 0 \
		and int(snapshot.get("unspawned", -1)) == 0


func _can_start() -> bool:
	return _state in [&"initial_preparation", &"preparation"] \
		and _wave_index < WAVE_TOTAL and waves.size() == WAVE_TOTAL \
		and not _starting and not _transitioning and _has_live_spawner() \
		and not _spawner.auto_start and _is_live() and can_process()


func _reason_from_snapshot(snapshot: Dictionary, fallback: StringName) -> StringName:
	var reason := StringName(String(snapshot.get("reason", "")))
	if not reason.is_empty():
		return reason
	if String(snapshot.get("state", "")) == "idle":
		return &"spawner_reset"
	return fallback
