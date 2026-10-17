class_name ThirdLevelHUD
extends FirstLevelHUD
## 沿用前两关纯显示层；CG4为可替换的文字占位，世界停机后仍可跳过或查看结算。

@export_multiline var ending_text: String = "我思考了很久，直到现在，\n才发现画画不应为了任何理由。\n仅仅是想画，所以去画。"

var _objectives: Dictionary = {}
var _ending_snapshot: Dictionary = {}
var _ending_pending: bool = false
var _ending_panel: ColorRect
var _ending_timer: SceneTreeTimer


func show_objectives(snapshot: Dictionary) -> void:
	_objectives = snapshot.duplicate(true)
	if _ui_ready:
		_render_flow()


func _render_flow() -> void:
	wave_label.text = "第三关 · 自我和解"
	progress_label.text = "收集碎片 %d/3 · 连通菌域持续覆盖5秒" % int(_objectives.get("completed", 0))
	var rows: PackedStringArray = []
	for fragment: Dictionary in _objectives.get("fragments", []):
		rows.append("%s：%s" % [fragment.name, "已收集" if fragment.collected else (
			"收集中" if fragment.collecting else "等待有效覆盖") + " %.1f/%.0fs" % [fragment.progress, fragment.duration]])
	counts_label.text = "\n".join(rows)
	var soonest: float = INF
	for source: Dictionary in _flow_snapshot.get("sources", []):
		soonest = minf(soonest, float(source.remaining))
	next_label.text = "下批来袭约 %ds · 压力阶段 %d/3" % [ceili(soonest), int(_flow_snapshot.get("stage", 0)) + 1] \
		if is_finite(soonest) else "准备探索"
	pause_label.text = "已暂停 · 收集、生产与运输冻结" if _paused else "失联保留进度；灰色菌域残影不能收集"
	start_button.text = "提前开始防守"
	start_button.disabled = _paused or _has_result or _ending_pending or not bool(_flow_snapshot.get("can_start", false))
	pause_button.text = "恢复 · Space" if _paused else "暂停 · Space"
	pause_button.disabled = _has_result or _ending_pending
	for label: Label in [wave_label, progress_label, counts_label, next_label, pause_label]:
		label.tooltip_text = label.text


func _render_result() -> void:
	result_panel.visible = _has_result
	if not _has_result:
		return
	var won: bool = bool(_result_snapshot.get("victory", false))
	result_title.text = "自我和解 · 通关" if won else "母核失守"
	result_subtitle.text = "三个碎片已经完整收集" if won else "保护探索路线，再次出发"
	result_left_label.text = "收集碎片：%d / 3\n累计回收：%d 营养" % [
		int(_result_snapshot.get("objective", {}).get("completed", 0)), int(_result_snapshot.get("total_recovered", 0))]
	result_right_label.text = "母核生命：%s\n本局用时：%s" % [
		_health_text(float(_result_snapshot.get("core_health", 0))), _time_text(float(_result_snapshot.get("elapsed_seconds", 0)))]


func show_ending(snapshot: Dictionary) -> void:
	if _ending_pending or _has_result:
		return
	_ending_pending = true
	_ending_snapshot = snapshot.duplicate(true)
	_render_flow()
	# 先冻结并展示完成的网络，再进入CG4。计时器随本层退出断开，不遗留旧局回调。
	_ending_timer = get_tree().create_timer(1.5, true)
	_ending_timer.timeout.connect(_open_ending)


func _open_ending() -> void:
	if not is_inside_tree() or not _ending_pending:
		return
	_ending_timer = null
	_ending_panel = ColorRect.new()
	_ending_panel.name = "CG4Placeholder"
	_ending_panel.color = Color(0.035, 0.068, 0.052, 0.98)
	_ending_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_ending_panel)
	var column := VBoxContainer.new()
	column.position = Vector2(200, 230)
	column.size = Vector2(800, 420)
	column.add_theme_constant_override("separation", 30)
	_ending_panel.add_child(column)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC"])
	var paragraphs: PackedStringArray = ["与自己和解"]
	paragraphs.append_array(ending_text.split("\n"))
	for text: String in paragraphs:
		var label := Label.new()
		label.text = text
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", 23)
		column.add_child(label)
	var button := Button.new()
	button.text = "继续 · 查看通关结算"
	button.custom_minimum_size.y = 52
	button.add_theme_font_override("font", font)
	button.pressed.connect(finish_ending)
	column.add_child(button)


func finish_ending() -> void:
	if not _ending_pending:
		return
	_ending_pending = false
	if is_instance_valid(_ending_panel):
		_ending_panel.queue_free()
	show_result(_ending_snapshot)


func _exit_tree() -> void:
	if _ending_timer != null and _ending_timer.timeout.is_connected(_open_ending):
		_ending_timer.timeout.disconnect(_open_ending)
