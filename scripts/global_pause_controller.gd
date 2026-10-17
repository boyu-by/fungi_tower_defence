class_name GlobalPauseController
extends Node
## 全局暂停只冻结场景树；终局的模拟停机由关卡自己处理。

signal pause_changed(paused: bool)

var _paused: bool = false
var _terminal: bool = false
var _space_down: bool = false
var _menu_active: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = _paused


func _exit_tree() -> void:
	# 场景重载即使发生在暂停中，也不能把暂停留给下一局。
	get_tree().paused = false
	_paused = false
	_terminal = false
	_space_down = false
	_menu_active = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_space_down = false


func _input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null or (key_event.keycode != KEY_SPACE and key_event.physical_keycode != KEY_SPACE):
		return
	# _input 在 GUI 前执行。按下、回声和松开都消费，避免同次空格触发 ui_accept。
	get_viewport().set_input_as_handled()
	if not key_event.pressed:
		_space_down = false
	elif not key_event.echo and not _space_down:
		_space_down = true
		if not _menu_active:
			toggle_pause()


func toggle_pause() -> void:
	if _terminal or _menu_active:
		return
	set_paused(not _paused)


func set_paused(value: bool) -> void:
	var changed: bool = _paused != value
	_paused = value
	if is_inside_tree():
		get_tree().paused = value
	if changed:
		pause_changed.emit(value)


func is_paused() -> bool:
	return _paused


func set_terminal(value: bool) -> void:
	_terminal = value


func reset() -> void:
	_terminal = false
	_menu_active = false
	# 重开不会把尚未松开的空格变成一次新的按下。
	set_paused(false)


func set_menu_active(value: bool) -> void:
	_menu_active = value
