class_name GrowthTarget
extends Node2D
## 无碰撞的目标标记；兼容普通生长和远程攻击芽，只显示输入层传入的报价与状态。

const PREVIEW_COLOR: Color = Color(0.63, 0.91, 0.68, 0.65)
const WAIT_COLOR: Color = Color(0.97, 0.79, 0.37)
const PAUSED_COLOR: Color = Color(0.61, 0.75, 0.95)
const COMPLETE_COLOR: Color = Color(0.41, 0.92, 0.75)
const ERROR_COLOR: Color = Color(0.94, 0.43, 0.40)
const STATE_TEXT: Dictionary = {
	&"idle": "未开始", &"waiting": "等待供养", &"extending": "延伸中",
	&"connected": "菌路已接通", &"cultivating": "培育中",
	&"paused": "已暂停", &"cancelled": "已取消", &"completed": "已完成",
}
const PHASE_TEXT: Dictionary = {
	&"growth": "延伸菌路", &"connected": "接通菌路", &"cultivation": "培育攻击芽",
}
const WAIT_TEXT: Dictionary = {
	&"nutrition": "等待营养", &"in_transit": "营养运输中", &"core_empty": "母核营养不足",
	&"combat_reserve": "保留战斗营养", &"repair_budget": "营养优先用于修复", &"disconnected": "生长路线断开",
	&"invalid_configuration": "生长配置无效", &"core_unavailable": "母核不可用",
	&"paused": "生长已暂停",
	&"settlement_pending": "等待退款结算", &"occupied": "器官槽位已占用",
	&"construction_busy": "等待当前建造任务", &"startup": "等待启动库存",
}

var _is_preview: bool = false
var _preview: Dictionary = {}
var _snapshot: Dictionary = {}
var _route_plan: Dictionary = {}

@onready var status_label: Label = $StatusLabel


func _ready() -> void:
	if _is_preview or not _snapshot.is_empty():
		_refresh_label()
	queue_redraw()


func _draw() -> void:
	var color: Color = _marker_color()
	if (_is_preview and bool(_preview.get("valid", false))) or _is_remote_status():
		var start_position: Vector2 = _route_plan.get("start_position", global_position)
		draw_line(to_local(start_position), Vector2.ZERO, color, 2.0, true)
		var junction_positions: PackedVector2Array = _route_plan.get("junction_positions", PackedVector2Array())
		for point: Vector2 in junction_positions:
			draw_circle(to_local(point), 4.0, color, false, 1.0, true)
	draw_circle(Vector2.ZERO, 11.0, color, false, 2.0, true)
	draw_line(Vector2(-16, 0), Vector2(16, 0), color, 1.0, true)
	draw_line(Vector2(0, -16), Vector2(0, 16), color, 1.0, true)
	if not _is_preview:
		var progress: float = clampf(float(_snapshot.get("progress", 0.0)), 0.0, 1.0)
		if progress > 0.0:
			draw_arc(Vector2.ZERO, 16.0, -PI / 2.0, -PI / 2.0 + TAU * progress, 40, color, 3.0, true)


func show_preview(preview: Dictionary) -> void:
	_is_preview = true
	_preview = preview.duplicate(true)
	_snapshot = {}
	_route_plan = preview.get("plan", {}).duplicate(true)
	var target_position: Vector2 = preview.get("target_position", Vector2.ZERO)
	# 非有限坐标不能写入 CanvasItem；错误提示仍留在上次有效鼠标位置。
	if target_position.is_finite():
		global_position = target_position
	if is_node_ready():
		_refresh_label()
	queue_redraw()


func show_status(snapshot: Dictionary) -> void:
	_is_preview = false
	_snapshot = snapshot.duplicate(true)
	_preview = {}
	if not _is_remote_status():
		_route_plan = {}
	elif snapshot.has("plan"):
		_route_plan = snapshot.get("plan", {}).duplicate(true)
	var target_position: Vector2 = snapshot.get("target_position", global_position)
	if target_position.is_finite():
		global_position = target_position
	if is_node_ready():
		_refresh_label()
	queue_redraw()


func get_task_id() -> int:
	return int(_snapshot.get("request_id", _snapshot.get("task_id", 0)))


func get_status_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func is_preview() -> bool:
	return _is_preview


func _refresh_label() -> void:
	status_label.modulate = _marker_color()
	if _is_preview:
		if not bool(_preview.get("valid", false)):
			status_label.text = String(_preview.get("error", "目标不可放置"))
		else:
			var plan: Dictionary = _preview.get("plan", {})
			var junction_positions: PackedVector2Array = plan.get("junction_positions", PackedVector2Array())
			if _is_remote_preview():
				status_label.text = "左键确认 · 远程攻击芽\n菌路 %d + 器官 %d = 总计 %d\n距离 %.0f · 新菌结 %d" % [
					int(_preview.get("network_cost", 0)), int(_preview.get("organ_cost", 12)),
					int(_preview.get("total_cost", 0)), float(plan.get("distance", 0.0)), junction_positions.size(),
				]
			else:
				status_label.text = "左键确认 · 预计营养 %d\n距离 %.0f · 新菌结 %d" % [
					int(plan.get("total_cost", 0)), float(plan.get("distance", 0.0)), junction_positions.size(),
				]
	else:
		var state: StringName = StringName(_snapshot.get("state", &"idle"))
		var wait_reason: StringName = StringName(_snapshot.get("wait_reason", &""))
		if _is_remote_status():
			var phase: StringName = StringName(_snapshot.get("phase", &""))
			var state_text: String = "已成熟" if state == &"completed" else String(STATE_TEXT.get(state, String(state)))
			var startup_text: String = "已转入库存 %d" % int(_snapshot.get("startup_transferred", 0)) \
				if state == &"completed" else "已预留启动库存 %d" % int(_snapshot.get("startup_reserved", 0))
			status_label.text = "远程攻击芽 #%d · %s · %d%%\n阶段：%s\n菌路 %d + 器官 %d = 总计 %d\n已投入 %d · 尚需 %d\n待供养 %d · 缓冲 %d · %s" % [
				get_task_id(), state_text, int(round(float(_snapshot.get("progress", 0.0)) * 100.0)),
				String(PHASE_TEXT.get(phase, "未开始")), int(_snapshot.get("network_cost", 0)),
				int(_snapshot.get("organ_cost", 12)), int(_snapshot.get("total_cost", 0)),
				int(_snapshot.get("consumed_nutrition", 0)), int(_snapshot.get("remaining_cost", 0)),
				int(_snapshot.get("remaining_demand", 0)), int(_snapshot.get("buffered_nutrition", 0)),
				startup_text,
			]
		else:
			status_label.text = "生长 #%d · %s · %d%%\n营养 %d/%d" % [
				get_task_id(), String(STATE_TEXT.get(state, String(state))),
				int(round(float(_snapshot.get("progress", 0.0)) * 100.0)),
				int(_snapshot.get("consumed_nutrition", 0)), int(_snapshot.get("total_cost", 0)),
			]
		if not wait_reason.is_empty():
			var wait_text: String = String(WAIT_TEXT.get(wait_reason, String(wait_reason)))
			if _is_remote_status() and wait_reason == &"paused":
				wait_text = "当前阶段已暂停"
			elif _is_remote_status() and wait_reason == &"disconnected":
				wait_text = "菌路断开，等待恢复连接"
			status_label.text += "\n" + wait_text
	_position_label()


func _position_label() -> void:
	var width: float = 360.0 if _is_remote_preview() or _is_remote_status() else 280.0
	status_label.size = Vector2(width, maxf(70.0, status_label.get_combined_minimum_size().y))
	status_label.position = Vector2(20, -35)
	var canvas_transform: Transform2D = get_global_transform_with_canvas()
	var viewport_rect: Rect2 = get_viewport_rect().grow(-8.0)
	var label_rect: Rect2 = canvas_transform * Rect2(status_label.position, status_label.size)
	if label_rect.end.x > viewport_rect.end.x:
		status_label.position.x = -20.0 - status_label.size.x
		label_rect = canvas_transform * Rect2(status_label.position, status_label.size)
	var screen_offset: Vector2 = Vector2(
		clampf(label_rect.position.x, viewport_rect.position.x, viewport_rect.end.x - label_rect.size.x),
		clampf(label_rect.position.y, viewport_rect.position.y, viewport_rect.end.y - label_rect.size.y)
	) - label_rect.position
	status_label.position += canvas_transform.affine_inverse().basis_xform(screen_offset)


func _is_remote_preview() -> bool:
	return _is_preview and _preview.has("organ_cost")


func _is_remote_status() -> bool:
	return not _is_preview and _snapshot.has("request_id")


func _marker_color() -> Color:
	if _is_preview:
		return PREVIEW_COLOR if bool(_preview.get("valid", false)) else ERROR_COLOR
	var state: StringName = StringName(_snapshot.get("state", &"idle"))
	match state:
		&"waiting":
			return WAIT_COLOR
		&"paused":
			return PAUSED_COLOR
		&"cancelled":
			return ERROR_COLOR
		&"completed":
			return COMPLETE_COLOR
	return COMPLETE_COLOR
