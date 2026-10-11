@tool
class_name HyphaEdge
extends Node2D

## 损伤和临时禁行都保留边与端点；只有零生命值阻断正常通行。
signal traffic_settings_changed
signal health_changed(current: float, maximum: float)

const VEIN_THRESHOLDS: Array[int] = [20, 60]
const VEIN_CAPACITIES: Array[int] = [2, 3, 4]
const VEIN_MAX_HEALTH: Array[float] = [35.0, 50.0, 65.0]
const VEIN_GRADE_NAMES: Array[String] = ["细菌丝", "加粗菌脉", "成熟主脉"]
const VEIN_WIDTH_STEP: float = 2.0

@export var start_node: Node2D
@export var end_node: Node2D
@export var traffic_capacity: int = 2:
	get:
		return _traffic_capacity
	set(value):
		var normalized: int = maxi(0, value)
		if _traffic_capacity == normalized:
			return
		_traffic_capacity = normalized
		traffic_settings_changed.emit()
@export var entry_enabled: bool = true:
	set(value):
		if entry_enabled == value:
			return
		var previously_traversable: bool = is_traversable()
		entry_enabled = value
		if previously_traversable != is_traversable():
			traffic_settings_changed.emit()
@export var max_health: float = 35.0:
	get:
		return _max_health
	set(value):
		if not is_finite(value) or value <= 0.0 or _max_health == value:
			return
		var previously_traversable: bool = is_traversable()
		_max_health = value
		# 场景覆盖上限也在 ready 前满血；首次受伤后改变上限仅作截断。
		_health = minf(_health, max_health) if _health_was_changed else max_health
		_publish_health_change(previously_traversable)

var health: float:
	get:
		return _health

var _traffic_capacity: int = 2
var _max_health: float = 35.0
var _health: float = 35.0
var _health_was_changed: bool = false
var _vein_grade: int = 0
var _vein_confirmed_passages: int = 0
var _vein_revision: int = 0
var _base_vein_width: float = 6.0
var _vein_style_captured: bool = false
var _open_color: Color = Color(0.44313726, 0.60784316, 0.4745098, 1)

@onready var vein: Line2D = $Vein


func _ready() -> void:
	_capture_vein_style()
	_update_vein_width()


func _process(_delta: float) -> void:
	queue_redraw()
	if not is_instance_valid(vein):
		return

	if not has_endpoints():
		vein.clear_points()
		return

	var start_point := vein.to_local(start_node.global_position)
	var end_point := vein.to_local(end_node.global_position)

	vein.points = PackedVector2Array([
		start_point,
		end_point
	])
	if not is_traversable():
		vein.default_color = Color(0.58, 0.29, 0.22, 0.7)
	elif health < max_health:
		vein.default_color = Color(0.84, 0.65, 0.34, 1.0)
	else:
		vein.default_color = _open_color


func _draw() -> void:
	if is_traversable() or not has_endpoints():
		return
	var center: Vector2 = to_local(start_node.global_position.lerp(end_node.global_position, 0.5))
	var tint: Color = Color(1.0, 0.48, 0.35)
	draw_line(center + Vector2(-7, -7), center + Vector2(7, 7), tint, 2.0, true)
	draw_line(center + Vector2(-7, 7), center + Vector2(7, -7), tint, 2.0, true)


func take_damage(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or health <= 0.0:
		return 0.0
	var previously_traversable: bool = is_traversable()
	var actual: float = minf(amount, health)
	_health = maxf(health - actual, 0.0)
	_health_was_changed = true
	_publish_health_change(previously_traversable)
	return actual


## 生产中仅由 RepairSystem 在已抵达营养付费后调用。
func restore_health(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or health >= max_health:
		return 0.0
	var previously_traversable: bool = is_traversable()
	var actual: float = minf(amount, max_health - health)
	_health = minf(health + actual, max_health)
	_health_was_changed = true
	_publish_health_change(previously_traversable)
	return actual


## 主脉成长仅改变能力，不经过场景上限 setter 的未受伤自动补满分支。
## 所有可查询状态与线宽先提交；维修和交通的同步回调看到同一等级。
func apply_vein_growth(grade: int, confirmed_passages: int) -> void:
	if is_queued_for_deletion():
		return
	_capture_vein_style()
	var normalized_grade: int = clampi(grade, 0, VEIN_CAPACITIES.size() - 1)
	var capacity_changed: bool = _traffic_capacity != VEIN_CAPACITIES[normalized_grade]
	var maximum_changed: bool = _max_health != VEIN_MAX_HEALTH[normalized_grade]
	var previously_traversable: bool = is_traversable()
	if normalized_grade != _vein_grade or capacity_changed or maximum_changed:
		_vein_revision += 1
	var revision: int = _vein_revision
	_vein_grade = normalized_grade
	_vein_confirmed_passages = maxi(0, confirmed_passages)
	_traffic_capacity = VEIN_CAPACITIES[normalized_grade]
	_max_health = VEIN_MAX_HEALTH[normalized_grade]
	_health = minf(_health, _max_health)
	if maximum_changed:
		_health_was_changed = true
	_update_vein_width()
	queue_redraw()
	var traversal_changed: bool = previously_traversable != is_traversable()
	if maximum_changed:
		health_changed.emit(health, max_health)
	# 回调重置、改变能力或删除边后，不再发布旧扩容；同等级的新计数不吞掉扩容。
	if is_instance_valid(self) and not is_queued_for_deletion() and revision == _vein_revision \
			and (capacity_changed or traversal_changed):
		traffic_settings_changed.emit()


func get_vein_snapshot() -> Dictionary:
	var line: Line2D = _get_vein_line()
	return {
		"edge_id": get_instance_id(),
		"grade": _vein_grade,
		"level": _vein_grade + 1,
		"grade_name": VEIN_GRADE_NAMES[_vein_grade],
		"confirmed_passages": _vein_confirmed_passages,
		"next_threshold": VEIN_THRESHOLDS[_vein_grade] if _vein_grade < VEIN_THRESHOLDS.size() else 0,
		"traffic_capacity": traffic_capacity,
		"health": health,
		"max_health": max_health,
		"width": line.width if line != null else _base_vein_width + _vein_grade * VEIN_WIDTH_STEP,
	}


func is_traversable() -> bool:
	return health > 0.0 and entry_enabled


func get_health_snapshot() -> Dictionary:
	return {
		"health": health,
		"max_health": max_health,
		"missing_health": maxf(max_health - health, 0.0),
		"damaged": health < max_health,
		"broken": health <= 0.0,
		"entry_enabled": entry_enabled,
		"traversable": is_traversable(),
	}


func has_endpoints() -> bool:
	return is_instance_valid(start_node) and is_instance_valid(end_node)


func get_length() -> float:
	if not has_endpoints():
		return 0.0
	return start_node.global_position.distance_to(end_node.global_position)


func connects(first: Node2D, second: Node2D) -> bool:
	return has_endpoints() and (
		(start_node == first and end_node == second) or
		(start_node == second and end_node == first)
	)


func get_point_at(progress: float) -> Vector2:
	if not has_endpoints():
		return global_position
	return start_node.global_position.lerp(end_node.global_position, clampf(progress, 0.0, 1.0))


func _get_vein_line() -> Line2D:
	return vein if is_instance_valid(vein) else get_node_or_null("Vein") as Line2D


func _capture_vein_style() -> void:
	if _vein_style_captured:
		return
	var line: Line2D = _get_vein_line()
	if line != null:
		_base_vein_width = line.width
		_open_color = line.default_color
		_vein_style_captured = true


func _update_vein_width() -> void:
	var line: Line2D = _get_vein_line()
	if line != null:
		line.width = _base_vein_width + _vein_grade * VEIN_WIDTH_STEP


func _publish_health_change(previously_traversable: bool) -> void:
	# 先固定本次跨越零血线的事实；同步回调可再次改变生命值。
	var traversal_changed: bool = previously_traversable != is_traversable()
	health_changed.emit(health, max_health)
	if traversal_changed:
		traffic_settings_changed.emit()
