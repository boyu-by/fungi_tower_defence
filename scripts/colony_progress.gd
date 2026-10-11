class_name ColonyProgress
extends Node

## 只观察已到达的消化产物，按产物 ID 累计回收量，不修改任何营养余额。

signal progress_changed(total_recovered: int, product_count: int)
signal stage_changed(previous_stage: Stage, current_stage: Stage)
signal stage_unlocked(stage: Stage)

enum Stage { NASCENT = 0, EXPANDED = 1, MATURE = 2 }

const ARRIVAL_SIGNAL: StringName = &"digestion_product_arrived"
const MAX_RECOVERED: int = 9223372036854775807
const EXPANDED_THRESHOLD: int = 60
const MATURE_THRESHOLD: int = 160

var _total_recovered: int = 0
var _product_ids: Dictionary = {}
var _sources: Dictionary = {}
var _notification_queue: Array[Dictionary] = []
var _notification_generation: RefCounted = RefCounted.new()
var _is_notifying: bool = false


func _on_digestion_product_arrived(
	product_id: String, nutrition: int, source_id: int, registration: RefCounted
) -> void:
	if not _sources.has(source_id):
		return
	var binding: Dictionary = _sources[source_id]
	if binding["registration"] != registration:
		return
	record_arrival(product_id, nutrition)


func register_source(source: Node) -> bool:
	if not is_instance_valid(source) or not source.has_signal(ARRIVAL_SIGNAL):
		return false
	var source_id: int = source.get_instance_id()
	if _sources.has(source_id):
		return false

	# 每次注册独立标记，旧回调即使延迟执行也不能进入新的观察周期。
	var registration := RefCounted.new()
	var callback: Callable = _on_digestion_product_arrived.bind(source_id, registration)
	if source.connect(ARRIVAL_SIGNAL, callback) != OK:
		return false
	_sources[source_id] = {
		"source": weakref(source),
		"callback": callback,
		"registration": registration,
	}
	return true


func unregister_source(source: Node) -> void:
	if not is_instance_valid(source):
		return
	var source_id: int = source.get_instance_id()
	if not _sources.has(source_id):
		return
	var binding: Dictionary = _sources[source_id]
	_sources.erase(source_id)
	_disconnect_source(binding)


func record_arrival(product_id: String, nutrition: int) -> bool:
	if product_id.is_empty() or nutrition <= 0 or _product_ids.has(product_id):
		return false
	if nutrition > MAX_RECOVERED - _total_recovered:
		return false

	var previous_stage: Stage = get_stage()
	_product_ids[product_id] = true
	_total_recovered += nutrition
	_queue_progress_notifications(previous_stage, true)
	return true


func get_total_recovered() -> int:
	return _total_recovered


func get_product_count() -> int:
	return _product_ids.size()


func has_product(product_id: String) -> bool:
	return _product_ids.has(product_id)


func get_stage() -> Stage:
	if _total_recovered >= MATURE_THRESHOLD:
		return Stage.MATURE
	if _total_recovered >= EXPANDED_THRESHOLD:
		return Stage.EXPANDED
	return Stage.NASCENT


func get_stage_name() -> String:
	match get_stage():
		Stage.EXPANDED:
			return "展开"
		Stage.MATURE:
			return "成熟"
		_:
			return "初生"


func get_next_stage_threshold() -> int:
	match get_stage():
		Stage.EXPANDED:
			return MATURE_THRESHOLD
		Stage.MATURE:
			return 0
		_:
			return EXPANDED_THRESHOLD


func reset() -> void:
	var previous_stage: Stage = get_stage()
	# 重置换用独立代际标记，信号回调内重置也会淘汰旧周期的待发通知。
	_notification_generation = RefCounted.new()
	_notification_queue.clear()
	var bindings: Array = _sources.values()
	_sources.clear()
	for binding: Dictionary in bindings:
		_disconnect_source(binding)
	_product_ids.clear()
	_total_recovered = 0
	_queue_progress_notifications(previous_stage, false)


func _queue_progress_notifications(previous_stage: Stage, unlock_stages: bool) -> void:
	var current_stage: Stage = get_stage()
	_notification_queue.append({
		"generation": _notification_generation,
		"signal": &"progress_changed",
		"total_recovered": _total_recovered,
		"product_count": _product_ids.size(),
	})
	if previous_stage != current_stage:
		_notification_queue.append({
			"generation": _notification_generation,
			"signal": &"stage_changed",
			"previous_stage": previous_stage,
			"current_stage": current_stage,
		})
	# 阶段只由单调累计量推导。整批入队后才发信号，重入收件不会插队或重复解锁。
	if unlock_stages and previous_stage < Stage.EXPANDED and current_stage >= Stage.EXPANDED:
		_notification_queue.append({
			"generation": _notification_generation,
			"signal": &"stage_unlocked",
			"stage": Stage.EXPANDED,
		})
	if unlock_stages and previous_stage < Stage.MATURE and current_stage >= Stage.MATURE:
		_notification_queue.append({
			"generation": _notification_generation,
			"signal": &"stage_unlocked",
			"stage": Stage.MATURE,
		})
	_flush_notifications()


func _flush_notifications() -> void:
	if _is_notifying:
		return
	_is_notifying = true
	while not _notification_queue.is_empty():
		var notification: Dictionary = _notification_queue.pop_front()
		if notification["generation"] == _notification_generation:
			match notification["signal"]:
				&"progress_changed":
					progress_changed.emit(notification["total_recovered"], notification["product_count"])
				&"stage_changed":
					stage_changed.emit(notification["previous_stage"], notification["current_stage"])
				&"stage_unlocked":
					stage_unlocked.emit(notification["stage"])
	_is_notifying = false


func _disconnect_source(binding: Dictionary) -> void:
	var source_ref: WeakRef = binding["source"]
	var source: Node = source_ref.get_ref() as Node
	var callback: Callable = binding["callback"]
	if is_instance_valid(source) and source.is_connected(ARRIVAL_SIGNAL, callback):
		source.disconnect(ARRIVAL_SIGNAL, callback)
