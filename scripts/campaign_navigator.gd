class_name CampaignNavigator
extends Node
## 主菜单拥有一次主线会话；直接F6调试和旧自动测试不会改写玩家的关卡记录。

signal quit_requested

const MENU_SCENE: String = "res://scenes/ui/main_menu.tscn"
const LEVEL_SCENES: Array[String] = ["res://scenes/levels/first_level.tscn",
	"res://scenes/levels/second_level.tscn", "res://scenes/levels/third_level.tscn"]
const LEVEL_NAMES: Array[String] = ["第一关 · 初步绘画", "第二关 · AI冲击", "第三关 · 自我和解"]

var progress_store: CampaignProgressStore = CampaignProgressStore.new()
var active_run: bool = false
var _transition_pending: bool = false


static func ensure(tree: SceneTree) -> CampaignNavigator:
	var existing := tree.root.get_node_or_null("CampaignFlow") as CampaignNavigator
	if is_instance_valid(existing):
		return existing
	var navigator := CampaignNavigator.new()
	navigator.name = "CampaignFlow"
	tree.root.add_child(navigator)
	return navigator


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	progress_store.load_progress()
	get_tree().scene_changed.connect(_on_scene_changed)


func start_new_game() -> bool:
	if _transition_pending or not progress_store.start_new_game():
		return false
	active_run = true
	_transition_pending = true
	var player := StoryPlayer.open(self, 1)
	player.finished.connect(func() -> void:
		_transition_pending = false
		_open_scene(LEVEL_SCENES[0]))
	return true


func continue_game() -> bool:
	var progress: Dictionary = progress_store.get_snapshot()
	if _transition_pending or not bool(progress.has_save):
		return false
	active_run = true
	return _open_scene(LEVEL_SCENES[int(progress.continue_level) - 1])


func bind_level(level: Node) -> void:
	var index: int = LEVEL_SCENES.find(level.scene_file_path) + 1
	if not active_run or index < 1 or not level.has_signal("level_finished"):
		return
	if not progress_store.record_entry(index):
		level.hud.show_notice(progress_store.last_error)
	var callback: Callable = _on_level_finished.bind(index)
	if not level.level_finished.is_connected(callback):
		level.level_finished.connect(callback)


func _on_level_finished(snapshot: Dictionary, index: int) -> void:
	if active_run and bool(snapshot.get("victory", false)):
		progress_store.record_victory(index)


func return_to_menu(level: Node) -> bool:
	if _transition_pending or not is_instance_valid(level):
		return false
	# 先停掉旧局生产和任务，再解除全局暂停交给标题页。
	level._restart_pending = true
	level.wave_flow.stop(&"return_to_menu")
	level._announce_level_stopping(&"return_to_menu")
	level.get_node("World").process_mode = Node.PROCESS_MODE_DISABLED
	level.get_node("Systems").process_mode = Node.PROCESS_MODE_DISABLED
	level.pause_controller.reset()
	active_run = false
	return _open_scene(MENU_SCENE)


func request_quit() -> void:
	quit_requested.emit()
	get_tree().quit()


func _open_scene(path: String) -> bool:
	if _transition_pending:
		return false
	_transition_pending = true
	get_tree().paused = false
	var error: Error = get_tree().change_scene_to_file(path)
	if error != OK:
		_transition_pending = false
		return false
	return true


func _on_scene_changed() -> void:
	_transition_pending = false
