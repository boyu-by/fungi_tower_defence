class_name ConnectionTarget
extends Node2D
## 无碰撞的连接标记；保留点击顺序，按协调器给出的真实方向和规划费用绘制。

const FIRST_COLOR: Color = Color(0.98, 0.82, 0.42)
const PREVIEW_COLOR: Color = Color(0.52, 0.89, 0.83, 0.8)
const WAIT_COLOR: Color = Color(0.97, 0.79, 0.37)
const PAUSED_COLOR: Color = Color(0.61, 0.75, 0.95)
const COMPLETE_COLOR: Color = Color(0.41, 0.92, 0.75)
const ERROR_COLOR: Color = Color(0.94, 0.43, 0.40)
const STATE_TEXT: Dictionary = {
	&"idle": "未开始", &"waiting": "等待供养", &"extending": "延伸中",
	&"paused": "已暂停", &"cancelled": "已取消", &"completed": "已接通",
}
const WAIT_TEXT: Dictionary = {
	&"nutrition": "等待营养", &"in_transit": "营养运输中", &"core_empty": "母核营养不足",
	&"combat_reserve": "保留战斗营养", &"repair_budget": "营养优先用于修复", &"disconnected": "菌路断开，等待恢复连接",
	&"invalid_configuration": "连接配置无效", &"core_unavailable": "母核不可用",
	&"paused": "连接已暂停", &"settlement_pending": "等待退款结算",
}

@export var placement_bounds: Rect2 = Rect2(0, 230, 1200, 410)

var _is_preview: bool = false
var _preview: Dictionary = {}
var _snapshot: Dictionary = {}
var _selection: Dictionary = {}
var _route_plan: Dictionary = {}
var _has_first: bool = false
var _has_second: bool = false
var _first_position: Vector2 = Vector2.ZERO
var _second_position: Vector2 = Vector2.ZERO

@onready var status_label: Label = $StatusLabel
@onready var first_label: Label = $FirstLabel
@onready var second_label: Label = $SecondLabel


func _ready() -> void:
	_refresh_labels()
	queue_redraw()


func _draw() -> void:
	var color: Color = _marker_color()
	if bool(_route_plan.get("valid", false)):
		var segments: Array = _route_plan.get("segments", [])
		var relays: PackedVector2Array = _route_plan.get("junction_positions", PackedVector2Array())
		for segment: Dictionary in segments:
			var start: Vector2 = segment.get("start_position", Vector2.ZERO)
			var end: Vector2 = segment.get("end_position", Vector2.ZERO)
			if not start.is_finite() or not end.is_finite():
				continue
			var local_start: Vector2 = to_local(start)
			var local_end: Vector2 = to_local(end)
			draw_line(local_start, local_end, color, 2.0, true)
			_draw_direction(local_start, local_end, color)
			var relay_cost: int = int(segment.get("junction_cost", 0))
			# 新菌结身份来自规划器的位置列表；零菌结单价也保留全部中继标记。
			if relays.has(end):
				draw_circle(local_end, 5.0, FIRST_COLOR, true, -1.0, true)
				draw_circle(local_end, 8.0, color, false, 1.0, true)
				var font: Font = status_label.get_theme_font("font")
				draw_string(font, local_end + Vector2(10, -8), "中继 %d 营养" % relay_cost,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, FIRST_COLOR)
	if _has_first:
		_draw_endpoint(to_local(_first_position), FIRST_COLOR, 13.0)
	if _has_second:
		_draw_endpoint(to_local(_second_position), color, 17.0)
	elif _is_preview:
		draw_circle(Vector2.ZERO, 9.0, color, false, 1.0, true)
	if not _is_preview:
		var progress: float = clampf(float(_snapshot.get("progress", 0.0)), 0.0, 1.0)
		var target: Vector2 = _route_plan.get("end_position", global_position)
		if progress > 0.0 and target.is_finite():
			draw_arc(to_local(target), 21.0, -PI / 2.0, -PI / 2.0 + TAU * progress,
				40, color, 3.0, true)


func show_preview(preview: Dictionary) -> void:
	_is_preview = true
	_preview = preview.duplicate(true)
	_snapshot = {}
	_selection = preview.duplicate(true)
	_route_plan = preview.get("plan", {}).duplicate(true)
	var pointer: Vector2 = preview.get("target_position", global_position)
	if pointer.is_finite():
		global_position = pointer
	_update_endpoint_positions()
	if is_node_ready():
		_refresh_labels()
	queue_redraw()


func show_status(snapshot: Dictionary) -> void:
	_is_preview = false
	_snapshot = snapshot.duplicate(true)
	_preview = {}
	if snapshot.has("plan"):
		_route_plan = snapshot.get("plan", {}).duplicate(true)
	if _selection.is_empty():
		_selection = {
			"first_node": snapshot.get("first_node", snapshot.get("start_node")),
			"second_node": snapshot.get("second_node", snapshot.get("target_node")),
			"start_node": snapshot.get("start_node"), "target_node": snapshot.get("target_node"),
			"reversed": bool(snapshot.get("reversed", false)),
		}
	var target_position: Vector2 = snapshot.get("target_position", global_position)
	if target_position.is_finite():
		global_position = target_position
	_update_endpoint_positions()
	if is_node_ready():
		_refresh_labels()
	queue_redraw()


func get_task_id() -> int:
	return int(_snapshot.get("task_id", 0))


func get_status_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func get_endpoint_snapshot() -> Dictionary:
	return {
		"first_node": _selection.get("first_node"), "second_node": _selection.get("second_node"),
		"start_node": _selection.get("start_node"), "target_node": _selection.get("target_node"),
		"reversed": bool(_selection.get("reversed", false)),
		"first_position": _first_position, "second_position": _second_position,
	}


func get_route_plan() -> Dictionary:
	return _route_plan.duplicate(true)


func is_preview() -> bool:
	return _is_preview


func _refresh_labels() -> void:
	var color: Color = _marker_color()
	status_label.modulate = color
	first_label.modulate = FIRST_COLOR
	second_label.modulate = color
	first_label.visible = _has_first
	second_label.visible = _has_second
	var source: Variant = _selection.get("start_node")
	var target: Variant = _selection.get("target_node")
	var first: Variant = _selection.get("first_node")
	var second: Variant = _selection.get("second_node")
	first_label.text = "① 已选菌结" + _endpoint_role(first, source, target)
	second_label.text = "② 第二菌结" + _endpoint_role(second, source, target)
	if _is_preview:
		if not bool(_preview.get("valid", false)):
			status_label.text = String(_preview.get("error", "请选择两个已有菌结"))
		else:
			status_label.text = "左键确认连接 · " + _direction_text() + "\n" + _cost_text()
	else:
		var state: StringName = StringName(_snapshot.get("state", &"idle"))
		status_label.text = "连接 #%d · %s · %d%%\n%s\n%s\n已投入 %d · 尚需 %d" % [
			get_task_id(), String(STATE_TEXT.get(state, String(state))),
			int(round(float(_snapshot.get("progress", 0.0)) * 100.0)),
			_direction_text(), _cost_text(), int(_snapshot.get("consumed_nutrition", 0)),
			int(_snapshot.get("remaining_cost", 0)),
		]
		var wait_reason: StringName = StringName(_snapshot.get("wait_reason", &""))
		if not wait_reason.is_empty():
			status_label.text += "\n" + String(WAIT_TEXT.get(wait_reason, String(wait_reason)))
	status_label.size = Vector2(360.0, maxf(80.0, status_label.get_combined_minimum_size().y))
	if _has_first:
		first_label.size = Vector2(260, 24)
		first_label.position = to_local(_first_position) + Vector2(18, -42)
		_position_label(first_label)
	if _has_second:
		second_label.size = Vector2(260, 24)
		var label_offset: Vector2 = Vector2(18, -42)
		if _has_first and _first_position.distance_squared_to(_second_position) < 48.0 * 48.0:
			label_offset = Vector2(18, 0)
		second_label.position = to_local(_second_position) + label_offset
		_position_label(second_label)
	_position_status_label()


func _cost_text() -> String:
	var relays: PackedVector2Array = _route_plan.get("junction_positions", PackedVector2Array())
	return "延伸 %d + 中继菌结 %d = 总计 %d 营养\n已有两端各 0 · 付费中继 %d · 距离 %.0f" % [
		int(_route_plan.get("extension_cost", 0)), int(_route_plan.get("junction_cost", 0)),
		int(_route_plan.get("total_cost", _snapshot.get("total_cost", 0))), relays.size(),
		float(_route_plan.get("distance", _snapshot.get("total_distance", 0.0))),
	]


func _direction_text() -> String:
	return "方向 ② → ①（供养自动反向）" if bool(_selection.get("reversed", false)) \
		else "方向 ① → ②"


func _endpoint_role(endpoint: Variant, source: Variant, target: Variant) -> String:
	if not is_instance_valid(endpoint):
		return ""
	if is_instance_valid(source) and endpoint == source:
		return " · 供养起点（已有 0）"
	if is_instance_valid(target) and endpoint == target:
		return " · 接入终点（已有 0）"
	return ""


func _update_endpoint_positions() -> void:
	var first: Variant = _selection.get("first_node")
	var second: Variant = _selection.get("second_node")
	if is_instance_valid(first) and first is Node2D and first.global_position.is_finite():
		_first_position = first.global_position
		_has_first = true
	elif _is_preview:
		_has_first = false
	if is_instance_valid(second) and second is Node2D and second.global_position.is_finite():
		_second_position = second.global_position
		_has_second = true
	elif _is_preview:
		_has_second = false


func _draw_endpoint(point: Vector2, color: Color, radius: float) -> void:
	draw_circle(point, radius, color, false, 2.0, true)
	draw_line(point + Vector2(-radius - 5, 0), point + Vector2(radius + 5, 0), color, 1.0, true)
	draw_line(point + Vector2(0, -radius - 5), point + Vector2(0, radius + 5), color, 1.0, true)


func _draw_direction(start: Vector2, end: Vector2, color: Color) -> void:
	if start.distance_squared_to(end) <= 16.0:
		return
	var direction: Vector2 = (end - start).normalized()
	var side: Vector2 = direction.orthogonal()
	var head: Vector2 = start.lerp(end, 0.55)
	draw_line(head - direction * 10.0 + side * 5.0, head, color, 2.0, true)
	draw_line(head - direction * 10.0 - side * 5.0, head, color, 2.0, true)


func _position_label(label: Label) -> void:
	var canvas_transform: Transform2D = get_global_transform_with_canvas()
	var bounds: Rect2 = _label_screen_bounds()
	var label_rect: Rect2 = canvas_transform * Rect2(label.position, label.size)
	if label_rect.end.x > bounds.end.x:
		label.position.x -= label.size.x + 36.0
		label_rect = canvas_transform * Rect2(label.position, label.size)
	var screen_offset: Vector2 = Vector2(
		clampf(label_rect.position.x, bounds.position.x, bounds.end.x - label_rect.size.x),
		clampf(label_rect.position.y, bounds.position.y, bounds.end.y - label_rect.size.y)
	) - label_rect.position
	label.position += canvas_transform.affine_inverse().basis_xform(screen_offset)


func _position_status_label() -> void:
	var canvas_transform: Transform2D = get_global_transform_with_canvas()
	var bounds: Rect2 = _label_screen_bounds()
	var label_rect: Rect2 = canvas_transform * Rect2(status_label.position, status_label.size)
	var size: Vector2 = label_rect.size
	var anchor: Vector2 = canvas_transform.origin
	var gap: float = canvas_transform.basis_xform(Vector2(0, 6)).length()
	var endpoint_gap: float = canvas_transform.basis_xform(Vector2(0, 28)).length()
	var above: float = anchor.y - endpoint_gap
	var below: float = anchor.y + endpoint_gap
	var right: float = anchor.x + endpoint_gap
	var left: float = anchor.x - endpoint_gap - size.x
	var roles: Array[Rect2] = []
	for label: Label in [first_label, second_label]:
		if label.visible:
			roles.append(canvas_transform * Rect2(label.position, label.size))
	# 紧邻目标的角色标签先排好位置，再为完整报价/等待信息留出间隙。
	if _has_first and _first_position.is_equal_approx(global_position):
		var first_rect: Rect2 = canvas_transform * Rect2(first_label.position, first_label.size)
		above = minf(above, first_rect.position.y - gap)
		below = maxf(below, first_rect.end.y + gap)
		right = maxf(right, first_rect.end.x + gap)
		left = minf(left, first_rect.position.x - gap - size.x)
	if _has_second and _second_position.is_equal_approx(global_position):
		var second_rect: Rect2 = canvas_transform * Rect2(second_label.position, second_label.size)
		above = minf(above, second_rect.position.y - gap)
		below = maxf(below, second_rect.end.y + gap)
		right = maxf(right, second_rect.end.x + gap)
		left = minf(left, second_rect.position.x - gap - size.x)
	var aligned_x: float = clampf(anchor.x + endpoint_gap, bounds.position.x, bounds.end.x - size.x)
	var centered_y: float = clampf(anchor.y - size.y / 2.0, bounds.position.y, bounds.end.y - size.y)
	var candidates: Array[Vector2] = [
		Vector2(aligned_x, above - size.y),
		Vector2(clampf(left, bounds.position.x, bounds.end.x - size.x), above - size.y),
		Vector2(right, centered_y), Vector2(left, centered_y),
	]
	# 上方不够时沿角色标签两侧寻找空位，最后才考虑目标下方。
	for role: Rect2 in roles:
		candidates.append(Vector2(role.position.x - gap - size.x, centered_y))
		candidates.append(Vector2(role.end.x + gap, centered_y))
	candidates.append(Vector2(aligned_x, below))
	var chosen: Vector2 = Vector2(aligned_x,
		clampf(above - size.y, bounds.position.y, bounds.end.y - size.y))
	for candidate_position: Vector2 in candidates:
		var candidate: Rect2 = Rect2(candidate_position, size)
		if not bounds.encloses(candidate):
			continue
		var overlaps_role: bool = false
		for role: Rect2 in roles:
			if candidate.intersects(role.grow(gap)):
				overlaps_role = true
				break
		if not overlaps_role:
			chosen = candidate_position
			break
	status_label.position += canvas_transform.affine_inverse().basis_xform(chosen - label_rect.position)


func _label_screen_bounds() -> Rect2:
	# 地图边界使用世界坐标；再取可见部分，避免状态落入地图外的 HUD。
	var map_rect: Rect2 = get_canvas_transform() * placement_bounds.grow(-8.0)
	var visible_map: Rect2 = map_rect.intersection(get_viewport_rect().grow(-8.0))
	return visible_map if visible_map.has_area() else map_rect


func _marker_color() -> Color:
	if _is_preview:
		var reason: StringName = StringName(_preview.get("reason", &""))
		if reason == &"choose_first" or reason == &"choose_second" or reason == &"endpoint_required":
			return FIRST_COLOR
		return PREVIEW_COLOR if bool(_preview.get("valid", false)) else ERROR_COLOR
	match StringName(_snapshot.get("state", &"idle")):
		&"waiting":
			return WAIT_COLOR
		&"paused":
			return PAUSED_COLOR
		&"cancelled":
			return ERROR_COLOR
	return COMPLETE_COLOR
