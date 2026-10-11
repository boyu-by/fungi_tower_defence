class_name LargeCarcass
extends Node2D
## 大型尸骸保存有限库存；预留不扣库存，提交后的营养永不退回来源。

signal resources_changed(snapshot: Dictionary)
signal exhausted

const MAX_BATCH_SIZE: int = 10
const STATUS_TEXT: Dictionary = {
	&"out_of_field": "菌域外",
	&"no_route": "无开采路径",
	&"capacity_full": "胃囊已满",
	&"ready": "可开采",
	&"harvesting": "开采中",
	&"exhausted": "已耗尽",
}

@export var total_nutrition: int = 80
@export var batch_size: int = 10

var _initialized: bool = false
var _resource_id: String = ""
var _initial_nutrition: int = 0
var _effective_batch_size: int = 0
var _remaining_nutrition: int = 0
var _reserved_nutrition: int = 0
var _harvested_nutrition: int = 0
var _reservations: Dictionary[String, int] = {}
var _used_request_ids: Dictionary[String, bool] = {}
var _committed_batch_ids: Dictionary[String, bool] = {}
var _harvest_status: StringName = &"out_of_field"
var _exhaustion_notified: bool = false


func _ready() -> void:
	_ensure_initialized()
	_refresh_view()
	if _remaining_nutrition == 0 and not _exhaustion_notified:
		_exhaustion_notified = true
		exhausted.emit()


func get_resource_id() -> String:
	if _resource_id.is_empty():
		_resource_id = "large_carcass:%d" % get_instance_id()
	return _resource_id


func reserve_batch(request_id: String, requested_amount: int = 10) -> int:
	_ensure_initialized()
	if request_id.is_empty() or _used_request_ids.has(request_id):
		return 0
	# 每次非空请求都只使用一次；失败后调用方须生成新请求 ID。
	_used_request_ids[request_id] = true
	if requested_amount <= 0 or _effective_batch_size <= 0 or is_queued_for_deletion():
		return 0
	var amount: int = mini(
		mini(requested_amount, _effective_batch_size),
		_remaining_nutrition - _reserved_nutrition
	)
	if amount <= 0:
		return 0
	_reservations[request_id] = amount
	_reserved_nutrition += amount
	_notify_resources_changed()
	return amount


func get_reservation_nutrition(request_id: String) -> int:
	_ensure_initialized()
	return _reservations.get(request_id, 0)


func commit_batch(request_id: String, batch_id: String) -> bool:
	_ensure_initialized()
	if request_id.is_empty() or batch_id.is_empty():
		return false
	if not _reservations.has(request_id) or _committed_batch_ids.has(batch_id):
		return false
	var amount: int = _reservations[request_id]
	_reservations.erase(request_id)
	_committed_batch_ids[batch_id] = true
	_reserved_nutrition -= amount
	_remaining_nutrition -= amount
	_harvested_nutrition += amount
	if _remaining_nutrition == 0:
		_harvest_status = &"exhausted"
	_notify_resources_changed()
	# 信号回调可以删除来源；提交结果仍表示已经完成的库存扣减。
	return true


func release_batch(request_id: String) -> bool:
	_ensure_initialized()
	if request_id.is_empty() or not _reservations.has(request_id):
		return false
	var amount: int = _reservations[request_id]
	_reservations.erase(request_id)
	_reserved_nutrition -= amount
	_notify_resources_changed()
	return true


func get_remaining_nutrition() -> int:
	_ensure_initialized()
	return _remaining_nutrition


func get_reserved_nutrition() -> int:
	_ensure_initialized()
	return _reserved_nutrition


func get_available_nutrition() -> int:
	_ensure_initialized()
	return _remaining_nutrition - _reserved_nutrition


func get_harvested_nutrition() -> int:
	_ensure_initialized()
	return _harvested_nutrition


func is_exhausted() -> bool:
	_ensure_initialized()
	return _remaining_nutrition == 0


func get_snapshot() -> Dictionary:
	_ensure_initialized()
	return _make_snapshot()


func set_harvest_status(status: StringName) -> void:
	_ensure_initialized()
	if not STATUS_TEXT.has(status):
		return
	if status == &"exhausted" and _remaining_nutrition > 0:
		return
	var next_status: StringName = &"exhausted" if _remaining_nutrition == 0 else status
	if next_status == _harvest_status:
		return
	_harvest_status = next_status
	_notify_resources_changed()


func _ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true
	_initial_nutrition = maxi(0, total_nutrition)
	_effective_batch_size = clampi(batch_size, 0, MAX_BATCH_SIZE)
	_remaining_nutrition = _initial_nutrition
	if _remaining_nutrition == 0:
		_harvest_status = &"exhausted"


func _make_snapshot() -> Dictionary:
	return {
		"resource_id": get_resource_id(),
		"total_nutrition": _initial_nutrition,
		"remaining_nutrition": _remaining_nutrition,
		"reserved_nutrition": _reserved_nutrition,
		"available_nutrition": _remaining_nutrition - _reserved_nutrition,
		"harvested_nutrition": _harvested_nutrition,
		"status": _harvest_status,
	}


func _notify_resources_changed() -> void:
	var notify_exhaustion: bool = _remaining_nutrition == 0 and not _exhaustion_notified
	if notify_exhaustion:
		_exhaustion_notified = true
	var snapshot: Dictionary = _make_snapshot()
	var source_reference: WeakRef = weakref(self)
	_refresh_view()
	resources_changed.emit(snapshot)
	# 通过弱引用检查通知后的生命周期，不假定来源仍可接收后续事件。
	var live_source: LargeCarcass = source_reference.get_ref() as LargeCarcass
	if notify_exhaustion and is_instance_valid(live_source):
		live_source.exhausted.emit()


func _refresh_view() -> void:
	var stock_label := get_node_or_null("StockLabel") as Label
	if stock_label != null:
		stock_label.text = "剩余营养：%d/%d" % [_remaining_nutrition, _initial_nutrition]
	var status_label := get_node_or_null("StatusLabel") as Label
	if status_label != null:
		status_label.text = STATUS_TEXT[_harvest_status]
	var body := get_node_or_null("Body") as Polygon2D
	if body != null:
		body.modulate = Color(0.65, 0.65, 0.65, 0.8) if _remaining_nutrition == 0 else Color.WHITE
