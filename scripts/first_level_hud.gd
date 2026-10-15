class_name FirstLevelHUD
extends CanvasLayer
## 首关流程与结算的纯显示层；按钮只发出意图，不修改任何游戏资源。

signal start_requested
signal pause_requested
signal restart_requested
signal continue_requested

const FLOW_NAMES: Dictionary = {
	&"initial_preparation": "初始准备",
	&"fighting": "战斗中",
	&"preparation": "波间准备",
	&"victory_candidate": "胜利确认",
	&"interrupted": "关卡中断",
	&"stopped": "已停止",
}
const WAVE_TOTAL: int = 6

var _flow_snapshot: Dictionary = {}
var _colony_snapshot: Dictionary = {}
var _result_snapshot: Dictionary = {}
var _paused: bool = false
var _has_result: bool = false
var _ui_ready: bool = false

@onready var colony_panel: Control = $ColonyPanel
@onready var colony_label: Label = $ColonyPanel/Summary
@onready var flow_panel: Control = $FlowPanel
@onready var wave_label: Label = $FlowPanel/WaveLabel
@onready var progress_label: Label = $FlowPanel/ProgressLabel
@onready var counts_label: Label = $FlowPanel/CountsLabel
@onready var next_label: Label = $FlowPanel/NextLabel
@onready var pause_label: Label = $FlowPanel/PauseLabel
@onready var start_button: Button = $FlowPanel/Buttons/StartButton
@onready var pause_button: Button = $FlowPanel/Buttons/PauseButton
@onready var restart_button: Button = $FlowPanel/Buttons/RestartButton
@onready var result_panel: Control = $ResultPanel
@onready var result_title: Label = $ResultPanel/Title
@onready var result_subtitle: Label = $ResultPanel/Subtitle
@onready var result_left_label: Label = $ResultPanel/LeftStats
@onready var result_right_label: Label = $ResultPanel/RightStats
@onready var result_restart_button: Button = $ResultPanel/RestartButton
@onready var result_continue_button: Button = $ResultPanel/ContinueButton


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	start_button.pressed.connect(_on_start_pressed)
	pause_button.pressed.connect(_on_pause_pressed)
	restart_button.pressed.connect(_on_restart_pressed)
	result_restart_button.pressed.connect(_on_restart_pressed)
	result_continue_button.pressed.connect(func() -> void: continue_requested.emit())
	for button: Button in [start_button, pause_button, restart_button, result_restart_button]:
		button.focus_mode = Control.FOCUS_NONE
	_ui_ready = true
	_render_colony()
	_render_flow()
	_render_result()


func _on_start_pressed() -> void:
	if not start_button.disabled:
		start_requested.emit()


func _on_pause_pressed() -> void:
	if not pause_button.disabled:
		pause_requested.emit()


func _on_restart_pressed() -> void:
	restart_requested.emit()


func show_flow(snapshot: Dictionary) -> void:
	_flow_snapshot = snapshot.duplicate(true)
	if _ui_ready:
		_render_flow()


func show_pause(paused: bool) -> void:
	_paused = paused
	if _ui_ready:
		_render_flow()


func show_colony(snapshot: Dictionary) -> void:
	_colony_snapshot = snapshot.duplicate(true)
	if _ui_ready:
		_render_colony()


func show_result(snapshot: Dictionary) -> void:
	_result_snapshot = snapshot.duplicate(true)
	_has_result = true
	if _ui_ready:
		result_continue_button.hide()
		_render_result()
		_render_flow()


func clear_result() -> void:
	_result_snapshot.clear()
	_has_result = false
	if _ui_ready:
		result_continue_button.hide()
		_render_result()
		_render_flow()


func show_continue(caption: String) -> void:
	if not _ui_ready:
		return
	result_continue_button.text = caption
	result_continue_button.visible = _has_result and bool(_result_snapshot.get("victory", false))
	result_restart_button.position.x = 90.0 if result_continue_button.visible else 200.0


func is_pointer_over_panel(point: Vector2) -> bool:
	if not _ui_ready:
		return false
	for panel: Control in [colony_panel, flow_panel, result_panel]:
		if panel.is_visible_in_tree() and panel.get_global_rect().has_point(point):
			return true
	return false


func _render_colony() -> void:
	if _colony_snapshot.is_empty():
		colony_label.text = "母核 --/-- · 营养 -- · 累计回收 --\n成长：-- · 本局用时 -- · 空格 暂停/恢复"
	else:
		colony_label.text = "母核 %s/%s · 营养 %d · 累计回收 %d\n成长：%s · 本局用时 %s · 空格 暂停/恢复" % [
			_health_text(float(_colony_snapshot.get("core_health", 0.0))),
			_health_text(float(_colony_snapshot.get("core_max_health", 0.0))),
			int(_colony_snapshot.get("nutrition", 0)),
			int(_colony_snapshot.get("total_recovered", 0)),
			String(_colony_snapshot.get("stage_name", "--")),
			_time_text(float(_colony_snapshot.get("elapsed_seconds", 0.0))),
		]
	colony_label.tooltip_text = colony_label.text


func _render_flow() -> void:
	var state: StringName = StringName(_flow_snapshot.get("state", &"initial_preparation"))
	var wave_index: int = int(_flow_snapshot.get("wave_index", 0))
	var completed: int = int(_flow_snapshot.get("completed_waves", 0))
	var total: int = int(_flow_snapshot.get("wave_total", WAVE_TOTAL))
	var terminal: bool = state in [&"victory_candidate", &"interrupted", &"stopped"]
	var state_name: String = String(FLOW_NAMES.get(state, "等待流程"))
	if _has_result:
		state_name = "胜利" if bool(_result_snapshot.get("victory", false)) else "失败"
	wave_label.text = "首关 · %s（共 %d 波）" % [state_name, total] if wave_index == 0 else (
		"第 %d / %d 波 · %s" % [wave_index, total, state_name])
	progress_label.text = "完成 %d/%d 波 · 总击败 %d" % [completed, total,
		int(_flow_snapshot.get("total_defeated", 0))]
	counts_label.text = "本波击败 %d/%d · 场上 %d\n生成 %d/%d · 未生成 %d" % [
		int(_flow_snapshot.get("defeated", 0)), int(_flow_snapshot.get("planned", 0)),
		int(_flow_snapshot.get("active", 0)), int(_flow_snapshot.get("spawned", 0)),
		int(_flow_snapshot.get("planned", 0)), int(_flow_snapshot.get("unspawned", 0)),
	]
	if completed >= total or state == &"victory_candidate":
		next_label.text = "六波已清空，正在核验结果。" if not _has_result else "本次结算已生成。"
	elif wave_index == total and state == &"fighting":
		next_label.text = "最后一波 · 清空全部计划敌人后结算。
没有第七波。"
	elif state in [&"interrupted", &"stopped"]:
		next_label.text = "本次流程已结束。\n可重开并回到初始准备。"
	else:
		next_label.text = "下一波：%s\n方向：%s" % [
			String(_flow_snapshot.get("next_title", "等待波次信息")),
			String(_flow_snapshot.get("next_direction", "待确认")),
		]
	if _has_result or terminal:
		pause_label.text = "战斗已结束 · 查看结算或重新开始。"
	elif _paused:
		pause_label.text = "全局已暂停 · 模拟与倒计时冻结\n可选中 / 预览；恢复后提交操作。"
	elif state == &"preparation":
		pause_label.text = "波间准备 · %.1f 秒后自动开始\n可提前开始下一波，或按空格暂停。" % maxf(
			float(_flow_snapshot.get("preparation_remaining", 0.0)), 0.0)
	elif state == &"initial_preparation":
		pause_label.text = "先完成布局，再手动开始首波。\n空格暂停时仍可选中与预览。"
	else:
		pause_label.text = "战斗进行中 · 空格可暂停。\n暂停时仍可选中与预览。"
	pause_label.modulate = Color(1.0, 0.87, 0.55) if _paused else Color.WHITE
	start_button.text = "开始第 %d 波" % mini(completed + 1, total)
	start_button.disabled = _paused or _has_result or terminal or not bool(_flow_snapshot.get("can_start", false))
	pause_button.text = "已结束" if _has_result else ("恢复 · 空格" if _paused else "暂停 · 空格")
	pause_button.disabled = _has_result or terminal
	for label: Label in [wave_label, progress_label, counts_label, next_label, pause_label]:
		label.tooltip_text = label.text
	start_button.tooltip_text = "恢复全局暂停后开始下一波。" if _paused else "结束准备并请求开始下一波。"
	pause_button.tooltip_text = "暂停敌人、运输、建设、修复和波次倒计时；保留选中与预览。"
	restart_button.tooltip_text = "返回初始准备，重新开始本关。"


func _render_result() -> void:
	result_panel.visible = _has_result
	if not _has_result:
		result_title.text = ""
		result_subtitle.text = ""
		result_left_label.text = ""
		result_right_label.text = ""
		return
	var victory: bool = bool(_result_snapshot.get("victory", false))
	result_title.text = "守住菌落 · 首关胜利" if victory else "本次挑战失败"
	result_title.modulate = Color(0.75, 1.0, 0.8) if victory else Color(1.0, 0.75, 0.6)
	result_subtitle.text = "六波均已清空 · 本局数据如下" if victory else "回到初始准备，调整布局后再次挑战"
	result_left_label.text = "到达波次：%d / %d\n完成波次：%d / %d\n累计回收：%d 营养\n成长阶段：%s" % [
		int(_result_snapshot.get("reached_wave", 0)), WAVE_TOTAL,
		int(_result_snapshot.get("completed_waves", 0)), WAVE_TOTAL,
		int(_result_snapshot.get("total_recovered", 0)),
		String(_result_snapshot.get("stage_name", "--")),
	]
	result_right_label.text = "成熟器官：%d\n母核生命：%s\n本局用时：%s" % [
		int(_result_snapshot.get("mature_organs", 0)),
		_health_text(float(_result_snapshot.get("core_health", 0.0))),
		_time_text(float(_result_snapshot.get("elapsed_seconds", 0.0))),
	]
	result_left_label.tooltip_text = result_left_label.text
	result_right_label.tooltip_text = result_right_label.text


func _time_text(seconds: float) -> String:
	var whole_seconds: int = int(maxf(seconds, 0.0))
	var minutes: int = int(whole_seconds / 60.0)
	return "%02d:%02d" % [minutes, whole_seconds % 60]


func _health_text(health: float) -> String:
	return "%.0f" % health if is_equal_approx(health, roundf(health)) else "%.1f" % health
