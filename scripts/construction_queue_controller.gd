class_name ConstructionQueueController
extends Control
## 只读队列快照和显式施工身份；地图标记由本 Control 绘制，不创建施工节点。

signal notice(message: String)

const ROW_LIMIT: int = 3
const MARKER_RADIUS: float = 15.0
const MARKER_PICK_RADIUS: float = 22.0
const KIND_TEXT: Dictionary = {
	&"growth": "延伸菌路", &"remote_cultivation": "远程攻击芽", &"connection": "连接菌结",
	&"cultivation": "就地培育",
}
const STATE_TEXT: Dictionary = {
	&"waiting": "等待", &"executing": "执行中", &"paused": "已暂停",
	&"completed": "已完成", &"cancelled": "已取消", &"failed": "失败",
	&"maturing": "独立成熟",
}
const REASON_TEXT: Dictionary = {
	&"queued": "排队中", &"pipeline_busy": "等待当前施工", &"paused": "已暂停",
	&"tip_limit": "等待空闲尖端", &"maturation_handoff": "等待培育交接",
	&"disconnected": "菌路断开，等待恢复", &"nutrition": "等待营养",
	&"in_transit": "营养运输中", &"core_empty": "母核营养不足",
	&"combat_reserve": "保留战斗营养", &"repair_budget": "营养优先用于修复",
	&"settlement_pending": "等待退款结算", &"construction_busy": "等待当前施工",
	&"startup": "等待启动库存", &"occupied": "器官槽位已占用",
	&"invalid_configuration": "施工配置无效", &"core_unavailable": "母核不可用",
}

@export var coordinator: ConstructionCoordinator
@export var marker_container: Node2D

var _entries: Array[Dictionary] = []
var _maturing: Array[Dictionary] = []
var _snapshot: Dictionary = {}
var _maturing_item_ids: Array[String] = []
var _selected_construction_id: String = ""
var _observed_coordinator: ConstructionCoordinator
var _ui_ready: bool = false
var _marker_signature: Array = []

@onready var _title_label: Label = $Panel/TitleLabel
@onready var _row_buttons: Array[Button] = [$Panel/Row1, $Panel/Row2, $Panel/Row3]
@onready var _up_button: Button = $Panel/Actions/MoveUp
@onready var _down_button: Button = $Panel/Actions/MoveDown
@onready var _pause_button: Button = $Panel/Actions/Pause
@onready var _resume_button: Button = $Panel/Actions/Resume
@onready var _cancel_button: Button = $Panel/Actions/Cancel
@onready var _maturing_selector: OptionButton = $Panel/Maturing
@onready var _hint_label: Label = $Panel/HintLabel


func _ready() -> void:
	_ui_ready = true
	for index: int in range(_row_buttons.size()):
		_row_buttons[index].pressed.connect(_on_row_pressed.bind(index))
	_up_button.pressed.connect(_on_move_up_pressed)
	_down_button.pressed.connect(_on_move_down_pressed)
	_pause_button.pressed.connect(_on_pause_pressed)
	_resume_button.pressed.connect(_on_resume_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_maturing_selector.item_selected.connect(_on_maturing_selected)
	_maturing_selector.get_popup().popup_hide.connect(_on_maturing_popup_hidden)
	refresh()


func _exit_tree() -> void:
	_disconnect_coordinator()
	_ui_ready = false


func _process(_delta: float) -> void:
	# 快照由 changed 更新；只在地图变换或已有端点移动时重绘标记。
	var signature: Array = []
	if _has_marker_container():
		signature.append(marker_container.get_canvas_transform())
		signature.append(get_global_transform_with_canvas())
		for entry: Dictionary in _entries + _maturing:
			signature.append(_marker_geometry(entry))
	if signature != _marker_signature:
		_marker_signature = signature
		queue_redraw()


func _draw() -> void:
	if not _has_marker_container():
		return
	# 用视口像素绘制，使地图缩放后数字和命中半径仍一致。
	draw_set_transform_matrix(get_global_transform_with_canvas().affine_inverse())
	for entry: Dictionary in _entries + _maturing:
		if String(entry.get("construction_id", "")) != _selected_construction_id:
			_draw_marker(entry, false)
	var selected: Dictionary = _entry_for_id(_selected_construction_id)
	if not selected.is_empty():
		_draw_marker(selected, true)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _on_coordinator_changed(snapshot: Dictionary) -> void:
	_apply_snapshot(snapshot)


func _on_row_pressed(index: int) -> void:
	# 行始终静态存在，但当前行身份随排序快照更新。
	refresh()
	if index >= 0 and index < _entries.size():
		select_request(String(_entries[index].get("construction_id", "")))


func _on_move_up_pressed() -> void:
	move_selected(-1)


func _on_move_down_pressed() -> void:
	move_selected(1)


func _on_pause_pressed() -> void:
	pause_selected()


func _on_resume_pressed() -> void:
	resume_selected()


func _on_cancel_pressed() -> void:
	cancel_selected()


func _on_maturing_selected(index: int) -> void:
	if index >= 0 and index < _maturing_selector.item_count:
		select_request(String(_maturing_selector.get_item_metadata(index)))


func _on_maturing_popup_hidden() -> void:
	if _ui_ready:
		refresh.call_deferred()


func handle_input(event: InputEvent) -> bool:
	if event is InputEventKey and event.echo:
		return false
	refresh()
	if event is InputEventMouseButton:
		var mouse: InputEventMouseButton = event as InputEventMouseButton
		if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed \
				or not mouse.position.is_finite() or is_pointer_over_panel(mouse.position):
			return false
		var picked_id: String = _pick_marker(mouse.position)
		return select_request(picked_id) if not picked_id.is_empty() else false
	var is_pause: bool = _is_command_pressed(event, &"growth_pause", KEY_P)
	var is_cancel: bool = _is_command_pressed(event, &"growth_cancel", KEY_X)
	if not is_pause and not is_cancel:
		return false
	var selected: Dictionary = _entry_for_id(_selected_construction_id)
	if selected.is_empty():
		return false
	if is_cancel:
		cancel_selected()
	elif StringName(selected.get("state", &"waiting")) == &"paused":
		resume_selected()
	else:
		pause_selected()
	# 明确选择存在时，拒绝的操作也被消费，不能落到别的施工对象。
	return true


func select_request(construction_id: String) -> bool:
	refresh()
	if not _has_coordinator() or (not construction_id.is_empty() \
			and _entry_for_id(construction_id).is_empty()):
		return false
	var accepted: bool = coordinator.select_request(construction_id)
	refresh()
	return accepted


func move_selected(direction: int) -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	if direction != -1 and direction != 1:
		return false
	var selected: Dictionary = _selected_entry()
	if selected.is_empty() or not _can_move(selected):
		return false
	var accepted: bool = coordinator.move_request(String(selected["construction_id"]), direction)
	refresh()
	return accepted


func pause_selected() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var selected: Dictionary = _selected_entry()
	if selected.is_empty() or StringName(selected.get("state", &"")) not in [&"waiting", &"executing", &"maturing"]:
		return false
	var accepted: bool = coordinator.pause_request(String(selected["construction_id"]))
	refresh()
	if not accepted:
		notice.emit("该施工任务当前无法暂停")
	return accepted


func resume_selected() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var selected: Dictionary = _selected_entry()
	if selected.is_empty() or StringName(selected.get("state", &"")) != &"paused":
		return false
	var accepted: bool = coordinator.resume_request(String(selected["construction_id"]))
	refresh()
	if not accepted:
		notice.emit("该施工任务当前无法继续")
	return accepted


func cancel_selected() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var selected: Dictionary = _selected_entry()
	if selected.is_empty():
		return false
	var accepted: bool = coordinator.cancel_request(String(selected["construction_id"]))
	refresh()
	if not accepted:
		notice.emit("该施工任务当前无法取消")
	return accepted


func refresh() -> void:
	_connect_coordinator()
	var snapshot: Dictionary = coordinator.get_snapshot() if _has_coordinator() else {}
	_apply_snapshot(snapshot)


func is_pointer_over_panel(viewport_position: Vector2) -> bool:
	if not viewport_position.is_finite() or not is_visible_in_tree():
		return false
	if _ui_ready and _maturing_selector.get_popup().visible:
		return true
	var local_point: Vector2 = get_global_transform_with_canvas().affine_inverse() * viewport_position
	return Rect2(Vector2.ZERO, size).has_point(local_point)


func _has_coordinator() -> bool:
	return is_instance_valid(coordinator) and not coordinator.is_queued_for_deletion()


func _has_marker_container() -> bool:
	return is_instance_valid(marker_container) and not marker_container.is_queued_for_deletion()


func _connect_coordinator() -> void:
	if _observed_coordinator == coordinator and _has_coordinator():
		return
	_disconnect_coordinator()
	if _has_coordinator():
		_observed_coordinator = coordinator
		_observed_coordinator.changed.connect(_on_coordinator_changed)


func _disconnect_coordinator() -> void:
	if is_instance_valid(_observed_coordinator) \
			and _observed_coordinator.changed.is_connected(_on_coordinator_changed):
		_observed_coordinator.changed.disconnect(_on_coordinator_changed)
	_observed_coordinator = null


func _apply_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	_entries.clear()
	_maturing.clear()
	var values: Array = snapshot.get("entries", [])
	for value: Variant in values:
		if value is Dictionary and _entries.size() < ROW_LIMIT:
			var entry: Dictionary = value
			_entries.append(entry.duplicate(true))
	for value: Variant in snapshot.get("maturing", []):
		if value is Dictionary:
			_maturing.append(value.duplicate(true))
	_selected_construction_id = String(snapshot.get("selected_id", ""))
	if _entry_for_id(_selected_construction_id).is_empty():
		_selected_construction_id = ""
	if _ui_ready:
		_refresh_labels(int(snapshot.get("limit", ROW_LIMIT)))
	if is_inside_tree():
		queue_redraw()


func _refresh_labels(limit: int) -> void:
	_title_label.text = "施工队列 %d/%d" % [_entries.size(), limit]
	for index: int in range(_row_buttons.size()):
		var row: Button = _row_buttons[index]
		row.disabled = index >= _entries.size()
		if row.disabled:
			row.text = "%d. — 空闲槽位" % (index + 1)
			row.tooltip_text = ""
			row.modulate = Color.WHITE
		else:
			var entry: Dictionary = _entries[index]
			var construction_id: String = String(entry.get("construction_id", ""))
			var is_selected: bool = construction_id == _selected_construction_id
			var state: StringName = StringName(entry.get("state", &"waiting"))
			var reason: StringName = StringName(entry.get("wait_reason", &""))
			row.text = "%s%d. #%d · %s · %s\n原因：%s" % [
				"▶ " if is_selected else "   ", index + 1, int(entry.get("sequence", 0)),
				_kind_text(entry), String(STATE_TEXT.get(state, String(state))),
				String(REASON_TEXT.get(reason, String(reason))) if not reason.is_empty() else "—",
			]
			row.tooltip_text = "ID: " + construction_id
			row.modulate = Color(0.76, 1.0, 0.86) if is_selected else Color.WHITE
	var selected: Dictionary = _entry_for_id(_selected_construction_id)
	var has_selection: bool = not selected.is_empty() and _has_coordinator()
	var selected_index: int = _selected_index()
	_up_button.disabled = not has_selection or not _can_move(selected) or selected_index <= 0
	_down_button.disabled = not has_selection or not _can_move(selected) or selected_index >= _entries.size() - 1
	var selected_state: StringName = StringName(selected.get("state", &""))
	_pause_button.disabled = not has_selection or selected_state not in [&"waiting", &"executing", &"maturing"]
	_resume_button.disabled = not has_selection or selected_state != &"paused"
	_cancel_button.disabled = not has_selection
	_title_label.text += " · 未选择"
	_title_label.tooltip_text = "点击队列行或地图编号选择施工任务"
	if has_selection:
		_title_label.text = "施工队列 %d/%d · 已选 #%d" % [
			_entries.size(), limit, int(selected.get("sequence", 0)),
		]
		_title_label.tooltip_text = "当前目标：#%d · %s\nID: %s" % [
			int(selected.get("sequence", 0)), _kind_text(selected), _selected_construction_id,
		]
	_refresh_maturing_selector()
	if _has_coordinator() and coordinator.multi_worker_enabled:
		_title_label.offset_right = 266.0
		_title_label.text = "目标 %d/%d · 尖端 %d/%d · 等待 %d" % [
			_entries.size(), limit, int(_snapshot.get("tip_count", 0)),
			int(_snapshot.get("tip_limit", 1)), int(_snapshot.get("waiting_count", 0))]
	else:
		_title_label.offset_right = 213.0


func _refresh_maturing_selector() -> void:
	var enabled: bool = _has_coordinator() and coordinator.multi_worker_enabled
	_maturing_selector.visible = enabled
	_hint_label.visible = not enabled
	if not enabled or _maturing_selector.get_popup().visible:
		return
	var ids: Array[String] = [""]
	for request: Dictionary in _maturing:
		ids.append(String(request["construction_id"]))
	if ids != _maturing_item_ids:
		_maturing_item_ids = ids
		_maturing_selector.clear()
		for construction_id: String in ids:
			_maturing_selector.add_item("")
			_maturing_selector.set_item_metadata(_maturing_selector.item_count - 1, construction_id)
	_maturing_selector.set_item_text(0, "成熟 %d ▾" % _maturing.size())
	for index: int in range(_maturing.size()):
		var request: Dictionary = _maturing[index]
		var detail: Dictionary = request.get("detail", {})
		_maturing_selector.set_item_text(index + 1, "#%d %s · %s %d%%" % [
			int(request["sequence"]), _kind_text(request), STATE_TEXT.get(request.get("state"), "等待"),
			int(round(float(detail.get("progress", 0.0)) * 100.0))])
	_maturing_selector.disabled = _maturing.is_empty()
	_maturing_selector.select(maxi(0, ids.find(_selected_construction_id)))
	_maturing_selector.tooltip_text = "已接通的芽和就地培育在此选择；不占外部目标或尖端名额。"


func _kind_text(entry: Dictionary) -> String:
	var kind: StringName = StringName(entry.get("kind", &""))
	if kind in [&"remote_cultivation", &"cultivation"]:
		var organ_kind: StringName = entry.get("parameters", {}).get("organ_kind", &"attack")
		return ("远处" if kind == &"remote_cultivation" else "培育") + ("胃囊" if organ_kind == &"digestive" else "攻击芽")
	return String(KIND_TEXT.get(kind, String(kind)))


func _entry_for_id(construction_id: String) -> Dictionary:
	if construction_id.is_empty():
		return {}
	var found: Dictionary = {}
	for entry: Dictionary in _entries + _maturing:
		if String(entry.get("construction_id", "")) == construction_id:
			found = entry
	return found


func _selected_entry() -> Dictionary:
	refresh()
	return _entry_for_id(_selected_construction_id) if _has_coordinator() else {}


func _selected_index() -> int:
	var found: int = -1
	for index: int in range(_entries.size()):
		if String(_entries[index].get("construction_id", "")) == _selected_construction_id:
			found = index
	return found


func _can_move(entry: Dictionary) -> bool:
	return not entry.is_empty() and not bool(entry.get("started", false)) \
		and bool(entry.get("occupies_external_slot", true)) \
		and StringName(entry.get("state", &"")) in [&"waiting", &"paused"]


func _is_command_pressed(event: InputEvent, action: StringName, key: Key) -> bool:
	if event is InputEventAction:
		return event.action == action and event.pressed
	if not event is InputEventKey:
		return false
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.ctrl_pressed \
			or key_event.alt_pressed or key_event.meta_pressed or key_event.shift_pressed:
		return false
	return key_event.keycode == key or key_event.physical_keycode == key \
		or (InputMap.has_action(action) and event.is_action_pressed(action, false, true))


func _marker_geometry(entry: Dictionary) -> Dictionary:
	var parameters: Dictionary = entry.get("parameters", {})
	if StringName(entry.get("kind", &"")) == &"cultivation":
		var host: Variant = parameters.get("host")
		if _is_live_endpoint(host) and host.global_position.is_finite():
			return {"point": host.global_position}
		return {}
	if StringName(entry.get("kind", &"")) == &"connection":
		var first: Variant = parameters.get("first_node")
		var second: Variant = parameters.get("second_node")
		if not _is_live_endpoint(first) or not _is_live_endpoint(second):
			return {}
		var first_position: Vector2 = (first as Node2D).global_position
		var second_position: Vector2 = (second as Node2D).global_position
		if not first_position.is_finite() or not second_position.is_finite():
			return {}
		return {"point": first_position.lerp(second_position, 0.5),
			"first": first_position, "second": second_position}
	var point: Variant = parameters.get("target_position")
	if not point is Vector2:
		return {}
	var target_position: Vector2 = point
	if not target_position.is_finite():
		return {}
	return {"point": target_position}


func _is_live_endpoint(value: Variant) -> bool:
	return is_instance_valid(value) and value is Node2D and not (value as Node2D).is_queued_for_deletion()


func _world_to_viewport(world_position: Vector2) -> Vector2:
	# parameters 保存全局坐标；不能把 marker_container 的局部偏移再加一遍。
	return marker_container.get_global_transform_with_canvas() * marker_container.to_local(world_position)


func _pick_marker(viewport_position: Vector2) -> String:
	if not _has_marker_container():
		return ""
	var picked_id: String = ""
	var nearest_squared: float = MARKER_PICK_RADIUS * MARKER_PICK_RADIUS
	for entry: Dictionary in _entries + _maturing:
		var geometry: Dictionary = _marker_geometry(entry)
		if geometry.is_empty():
			continue
		var point: Vector2 = _world_to_viewport(geometry["point"])
		var distance_squared: float = viewport_position.distance_squared_to(point)
		var construction_id: String = String(entry.get("construction_id", ""))
		if distance_squared < nearest_squared or (is_equal_approx(distance_squared, nearest_squared) \
				and (picked_id.is_empty() or construction_id == _selected_construction_id)):
			nearest_squared = distance_squared
			picked_id = construction_id
	return picked_id


func _draw_marker(entry: Dictionary, is_selected: bool) -> void:
	var geometry: Dictionary = _marker_geometry(entry)
	if geometry.is_empty():
		return
	var point: Vector2 = _world_to_viewport(geometry["point"])
	var state: StringName = StringName(entry.get("state", &"waiting"))
	var color: Color = Color(0.98, 0.81, 0.40)
	if state == &"paused":
		color = Color(0.64, 0.78, 1.0)
	elif state == &"executing":
		color = Color(0.45, 0.94, 0.77)
	elif entry.get("phase") == &"maturing":
		color = Color(0.92, 0.66, 0.95)
	if geometry.has("first") and geometry.has("second"):
		var first: Vector2 = _world_to_viewport(geometry["first"])
		var second: Vector2 = _world_to_viewport(geometry["second"])
		draw_line(first, second, Color(color, 0.55), 2.0 if is_selected else 1.0, true)
		draw_circle(first, 5.0, color, false, 1.0, true)
		draw_circle(second, 5.0, color, false, 1.0, true)
	draw_circle(point, MARKER_RADIUS, Color(0.055, 0.10, 0.09, 0.96), true, -1.0, true)
	draw_circle(point, MARKER_RADIUS, color, false, 2.0, true)
	if is_selected:
		draw_circle(point, MARKER_RADIUS + 4.0, Color(0.90, 1.0, 0.94), false, 2.0, true)
	var font: Font = get_theme_default_font()
	var font_size: int = 13
	var label: String = "#%d" % int(entry.get("sequence", 0))
	var label_width: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	var baseline: float = (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, point + Vector2(-label_width * 0.5, baseline), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)
