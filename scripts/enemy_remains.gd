class_name EnemyRemains
extends Node2D
## 尸体仅累计未领取的地面暴露；中断退回同一对象，保留剩余腐败时间。

signal decayed(nutrition: int)

const DECAY_SECONDS: float = 55.0

@export_range(1, 100, 1) var nutrition_value: int = 4

var _claimed: bool = false
var _ground_seconds: float = 0.0
var _decayed: bool = false
var _decayed_nutrition: int = 0
var _is_exiting: bool = false
var _body_color: Color = Color.WHITE


func _enter_tree() -> void:
	_is_exiting = false


func _ready() -> void:
	var body: CanvasItem = get_node_or_null("Body") as CanvasItem
	if body != null:
		_body_color = body.modulate
	_refresh_decay_view()


func _exit_tree() -> void:
	# 场景清理不属于自然腐败，退出时不生成损失事件。
	_is_exiting = true


func _physics_process(delta: float) -> void:
	advance_decay(delta)


func _draw() -> void:
	if _claimed or _decayed or _ground_seconds <= 0.0:
		return
	var remaining_ratio: float = 1.0 - _ground_seconds / DECAY_SECONDS
	draw_arc(Vector2(0.0, 3.0), 19.0, -PI / 2.0,
		-PI / 2.0 + TAU * remaining_ratio, 32, Color(0.73, 0.54, 0.30, 0.65), 2.0, true)


func is_available() -> bool:
	return not _claimed and not _decayed and not _is_exiting and not is_queued_for_deletion()


func is_decayed() -> bool:
	return _decayed


func get_decay_snapshot() -> Dictionary:
	return {
		"duration_seconds": DECAY_SECONDS, "elapsed_seconds": _ground_seconds,
		"remaining_seconds": maxf(0.0, DECAY_SECONDS - _ground_seconds),
		"progress": clampf(_ground_seconds / DECAY_SECONDS, 0.0, 1.0),
		"claimed": _claimed, "available": is_available(), "decayed": _decayed,
		"decayed_nutrition": _decayed_nutrition,
	}


func advance_decay(delta: float) -> void:
	if not is_available() or not is_finite(delta) or delta <= 0.0:
		return
	_ground_seconds = minf(DECAY_SECONDS, _ground_seconds + delta)
	if _ground_seconds >= DECAY_SECONDS:
		# 先提交终态和唯一库存损失；同帧领取及信号重入都不能复活营养。
		_decayed = true
		_decayed_nutrition = maxi(0, nutrition_value)
		nutrition_value = 0
		hide()
		set_physics_process(false)
		var corpse_ref: WeakRef = weakref(self)
		decayed.emit(_decayed_nutrition)
		var corpse: EnemyRemains = corpse_ref.get_ref() as EnemyRemains
		if is_instance_valid(corpse) and not corpse.is_queued_for_deletion():
			corpse.queue_free()
	else:
		_refresh_decay_view()


func try_claim() -> bool:
	if not is_available():
		return false
	_claimed = true
	hide()
	return true


func release_claim(drop_position: Vector2) -> void:
	if _decayed or _is_exiting or is_queued_for_deletion():
		return
	_claimed = false
	global_position = drop_position
	show()
	_refresh_decay_view()


func _refresh_decay_view() -> void:
	var body: CanvasItem = get_node_or_null("Body") as CanvasItem
	if body != null:
		var progress: float = clampf(_ground_seconds / DECAY_SECONDS, 0.0, 1.0)
		body.modulate = _body_color.lerp(Color(0.39, 0.33, 0.26, 0.28), progress)
	queue_redraw()
