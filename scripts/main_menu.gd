class_name MainMenu
extends Control
## 标题页只提交开始、继续和退出意图；关卡记录由主线导航保存。

@onready var start_button: Button = $Center/Content/Menu/Margin/Buttons/StartButton
@onready var continue_button: Button = $Center/Content/Menu/Margin/Buttons/ContinueButton
@onready var quit_button: Button = $Center/Content/Menu/Margin/Buttons/QuitButton
@onready var progress_label: Label = $Center/Content/Menu/Margin/Buttons/Progress
@onready var reset_dialog: ConfirmationDialog = $NewGameConfirmation

var _navigator: CampaignNavigator


func _ready() -> void:
	ArtUI.skin_tree(self)
	ArtUI.menu_button(start_button, "开始游戏")
	ArtUI.menu_button(continue_button, "继续游戏")
	ArtUI.menu_button(quit_button, "退出游戏")
	for button: Button in [start_button, continue_button, quit_button]:
		button.tooltip_text = ""
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	get_window().content_scale_size = Vector2i(1200, 800)
	start_button.disabled = true
	continue_button.disabled = true
	quit_button.disabled = true
	_prepare_menu.call_deferred()


func _prepare_menu() -> void:
	_navigator = CampaignNavigator.ensure(get_tree())
	_navigator.active_run = false
	_navigator.progress_store.load_progress()
	start_button.pressed.connect(_on_start)
	continue_button.pressed.connect(_on_continue)
	quit_button.pressed.connect(_navigator.request_quit)
	reset_dialog.confirmed.connect(_start_new)
	reset_dialog.title = "开始新游戏"
	reset_dialog.dialog_text = "开始新游戏将重置已解锁的关卡进度。是否继续？"
	reset_dialog.ok_button_text = "开始新游戏"
	reset_dialog.cancel_button_text = "返回"
	start_button.disabled = false
	quit_button.disabled = false
	refresh_progress()
	start_button.grab_focus()


func refresh_progress() -> void:
	var progress: Dictionary = _navigator.progress_store.get_snapshot()
	continue_button.disabled = not bool(progress.has_save)
	if not bool(progress.has_save):
		progress_label.text = "尚无游戏进度，从第一次创作开始。"
	else:
		var name_text: String = CampaignNavigator.LEVEL_NAMES[int(progress.continue_level) - 1]
		progress_label.text = ("已通关，可继续挑战。\n" if progress.completed else "") + "继续：%s\n从本关开头重新开始。" % name_text
	if not _navigator.progress_store.last_error.is_empty():
		progress_label.text = _navigator.progress_store.last_error


func _on_start() -> void:
	var progress: Dictionary = _navigator.progress_store.get_snapshot()
	if bool(progress.has_save) and (int(progress.highest_unlocked) > 1 or bool(progress.completed)):
		reset_dialog.popup_centered(Vector2i(470, 180))
	else:
		_start_new()


func _start_new() -> void:
	if not _navigator.start_new_game():
		refresh_progress()
		return
	_lock_buttons()


func _on_continue() -> void:
	if not _navigator.continue_game():
		refresh_progress()
		return
	_lock_buttons()


func _lock_buttons() -> void:
	start_button.disabled = true
	continue_button.disabled = true
	quit_button.disabled = true
