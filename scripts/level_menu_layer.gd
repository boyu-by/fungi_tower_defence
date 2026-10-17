class_name LevelMenuLayer
extends CanvasLayer
## 独立的暂停菜单；Space规划暂停仍由原控制器处理，打开菜单不提交任何建设指令。

@onready var overlay: Control = $Overlay
@onready var resume_button: Button = $Overlay/Center/Panel/Buttons/ResumeButton
@onready var restart_button: Button = $Overlay/Center/Panel/Buttons/RestartButton
@onready var title_button: Button = $Overlay/Center/Panel/Buttons/TitleButton
@onready var quit_button: Button = $Overlay/Center/Panel/Buttons/QuitButton

var result_title_button: Button
var result_quit_button: Button
var _level: Node2D
var _navigator: CampaignNavigator
var _was_paused: bool = false
var _configured: bool = false


func configure(level: Node2D) -> void:
	if _configured:
		return
	_level = level
	_navigator = get_node_or_null("/root/CampaignFlow") as CampaignNavigator
	resume_button.pressed.connect(close_menu)
	restart_button.pressed.connect(_restart)
	title_button.pressed.connect(_return_to_title)
	quit_button.pressed.connect(_quit)
	_level.level_finished.connect(_on_level_finished)
	var row := HBoxContainer.new()
	row.name = "NavigationButtons"
	row.position = Vector2(24, 330)
	row.size = Vector2(552, 44)
	row.add_theme_constant_override("separation", 12)
	row.theme = preload("res://resources/ui/menu_theme.tres")
	_level.flow_hud.result_panel.size.y = 394
	for button: Button in [_level.flow_hud.result_restart_button, _level.flow_hud.result_continue_button]:
		button.theme = row.theme
		button.custom_minimum_size.y = 48
		button.size.y = 48
	_level.flow_hud.result_panel.add_child(row)
	result_title_button = _result_button(row, "返回主菜单", _return_to_title)
	result_quit_button = _result_button(row, "退出游戏", _quit)
	if is_instance_valid(_navigator):
		_navigator.bind_level(_level)
	_configured = true


func _result_button(parent: Node, caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func open_menu() -> void:
	if not _configured or is_open() or not _level.get_result_snapshot().is_empty() or _level._restart_pending:
		return
	_was_paused = _level.pause_controller.is_paused()
	_level.compact_hud.close_drawer()
	_level.pause_controller.set_menu_active(true)
	_level.pause_controller.set_paused(true)
	resume_button.text = "返回暂停规划" if _was_paused else "继续游戏"
	overlay.show()
	resume_button.grab_focus()


func close_menu() -> void:
	if not is_open():
		return
	overlay.hide()
	_level.pause_controller.set_menu_active(false)
	_level.pause_controller.set_paused(_was_paused)
	resume_button.release_focus()


func is_open() -> bool:
	return is_instance_valid(overlay) and overlay.visible


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey:
		if event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			close_menu()
			get_viewport().set_input_as_handled()
		elif not (event.is_action("ui_accept") or event.is_action("ui_focus_next") \
				or event.is_action("ui_focus_prev") or event.is_action("ui_up") or event.is_action("ui_down")):
			get_viewport().set_input_as_handled()


func _restart() -> void:
	overlay.hide()
	_level.pause_controller.set_menu_active(false)
	_level.restart_level()


func _return_to_title() -> void:
	if not is_instance_valid(_navigator):
		_navigator = CampaignNavigator.ensure(get_tree())
	_navigator.return_to_menu(_level)


func _quit() -> void:
	if not is_instance_valid(_navigator):
		_navigator = CampaignNavigator.ensure(get_tree())
	_navigator.request_quit()


func _on_level_finished(_snapshot: Dictionary) -> void:
	overlay.hide()
	_level.pause_controller.set_menu_active(false)
