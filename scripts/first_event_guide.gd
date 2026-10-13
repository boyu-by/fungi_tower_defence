class_name FirstEventGuide
extends Control
## 只记录本局首次事件；关闭期间静默记忆，不积压历史提示或改动游戏资源。

signal changed(snapshot: Dictionary)

const EVENT_TEXTS: Dictionary = {
	&"target_placed": "目标已放置，营养会沿菌丝送往尖端。\n网络接通后，覆盖内的尸骸才能回运。",
	&"remains_returned": "尸体已送达胃囊，正在排队消化。\n绿色回流送抵母核后，营养才能再次使用。",
	&"nutrition_returned": "消化营养已回到母核，也会推动成长。\n先取左前80，再准备向右前扩张。",
	&"stage_unlocked": "菌落已成长，新的能力已经解锁。\n查看成长栏；扩张与器官仍需付费建设。",
	&"differentiated": "首次分化已完成。\n破甲对付重甲，散射应对小型群体。",
	&"network_broken": "网络断路：失联区域暂停补给与采集。\nF选受损组织，J付费修复；也可L连存活菌结。",
}

var is_enabled: bool = true

var _seen: Dictionary[StringName, bool] = {}
var _seen_order: Array[StringName] = []
var _pending: Array[Dictionary] = []
var _current: Dictionary = {}
var _message_panel: Panel
var _message_label: Label
var _dismiss_button: Button
var _toggle_button: Button


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(750, 60)


func _ready() -> void:
	_build_ui()
	_refresh_view()


func record_event(event_id: StringName, facts: Dictionary = {}) -> void:
	if not EVENT_TEXTS.has(event_id) or _seen.has(event_id):
		return
	_seen[event_id] = true
	_seen_order.append(event_id)
	if is_enabled:
		_pending.append({"id": event_id, "text": _message_for(event_id, facts)})
		_show_next()
	_publish()


func dismiss_current() -> void:
	if _current.is_empty():
		return
	_current.clear()
	_show_next()
	_publish()


func set_enabled(value: bool) -> void:
	if is_enabled == value:
		return
	is_enabled = value
	if not is_enabled:
		_current.clear()
		_pending.clear()
	_publish()


## 保留当前提示设置，清除旧局的可见提示、待显示项和首次事件记录。
func reset() -> void:
	_seen.clear()
	_seen_order.clear()
	_pending.clear()
	_current.clear()
	_publish()


func get_snapshot() -> Dictionary:
	return {
		"enabled": is_enabled,
		"visible": is_enabled and not _current.is_empty(),
		"current_event": _current.get("id", &""),
		"text": String(_current.get("text", "")),
		"seen": _seen_order.duplicate(),
	}


func _message_for(event_id: StringName, facts: Dictionary) -> String:
	var message: String = String(EVENT_TEXTS[event_id])
	var raw_stage: Variant = facts.get("stage_name", "")
	if event_id == &"stage_unlocked" and (raw_stage is String or raw_stage is StringName):
		var stage_name: String = String(raw_stage).strip_edges().replace("\n", " ")
		if not stage_name.is_empty() and stage_name.length() <= 12:
			message = "菌落成长至「%s」，新的能力已经解锁。\n查看成长栏；扩张与器官仍需付费建设。" % stage_name
	return message


func _show_next() -> void:
	if is_enabled and _current.is_empty() and not _pending.is_empty():
		_current = _pending.pop_front()


func _publish() -> void:
	_refresh_view()
	changed.emit(get_snapshot())


func _build_ui() -> void:
	if is_instance_valid(_message_panel):
		return
	var font: SystemFont = SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC"])
	var guide_theme: Theme = Theme.new()
	guide_theme.default_font = font
	guide_theme.default_font_size = 14
	theme = guide_theme
	_message_panel = Panel.new()
	_message_panel.name = "MessagePanel"
	_message_panel.size = Vector2(636, 60)
	_message_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background: StyleBoxFlat = StyleBoxFlat.new()
	background.bg_color = Color(0.075, 0.105, 0.085, 0.97)
	background.border_color = Color(0.40, 0.58, 0.43, 1.0)
	background.set_border_width_all(1)
	background.set_corner_radius_all(5)
	_message_panel.add_theme_stylebox_override("panel", background)
	add_child(_message_panel)
	_message_label = Label.new()
	_message_label.name = "Message"
	_message_label.position = Vector2(12, 7)
	_message_label.size = Vector2(526, 46)
	_message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message_label.add_theme_color_override("font_color", Color(0.94, 0.94, 0.83, 1))
	_message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message_panel.add_child(_message_label)
	_dismiss_button = Button.new()
	_dismiss_button.name = "Dismiss"
	_dismiss_button.text = "知道了"
	_dismiss_button.position = Vector2(548, 14)
	_dismiss_button.size = Vector2(76, 32)
	_dismiss_button.focus_mode = Control.FOCUS_NONE
	_dismiss_button.pressed.connect(dismiss_current)
	_message_panel.add_child(_dismiss_button)
	_toggle_button = Button.new()
	_toggle_button.name = "Toggle"
	_toggle_button.position = Vector2(648, 14)
	_toggle_button.size = Vector2(102, 32)
	_toggle_button.focus_mode = Control.FOCUS_NONE
	_toggle_button.toggle_mode = true
	_toggle_button.tooltip_text = "开启或关闭本局首次事件提示"
	_toggle_button.toggled.connect(set_enabled)
	add_child(_toggle_button)


func _refresh_view() -> void:
	if not is_instance_valid(_message_panel):
		return
	var snapshot: Dictionary = get_snapshot()
	_message_panel.visible = bool(snapshot["visible"])
	_message_label.text = String(snapshot["text"])
	_toggle_button.set_pressed_no_signal(is_enabled)
	_toggle_button.text = "引导 开" if is_enabled else "引导 关"
