class_name LevelStoryCaption
extends CanvasLayer
## 关内独白只观察进度，不暂停战斗、不改变出怪计时。每句每局只显示一次。
const FIRST_LINES: PackedStringArray = [
	"好痛苦，我再也不想画画了、我再也不想画画了……我再也不想画画了！",
	"毁了，都撕毁了！为什么要这样呢？我只是喜欢画——哈哈，现在可能不了……",
	"为什么？为什么永远都画不够好，为什么为什么为什么我明明已经很努力了，画成这样真不如洗洗睡了！！！",
	"我画不出来、我一点也画不出来！！真的好累啊……好想睡觉，一直、一直……",
	"我真的画得很差吗……看看我吧，不然我只能消失在幻想中了……",
	"求你了，如果……如果童年的一切都是梦的话，让我不要醒来好吗？",
]
const SECOND_LINES: PackedStringArray = [
	"为什么、为什么要吸我们的血来取代我们！！？",
	"我只是不想被替代、我只是不想自己的热爱被否定而已……",
	"可是，让ai全都消失，就一定是对的吗……？",
]
var _level: Node
var _chapter: int
var _seen: Array[int] = []
var _pending: Array[int] = []
var _remaining: float = 0.0
var _panel: PanelContainer
var _label: Label


static func attach(level: Node, chapter: int) -> LevelStoryCaption:
	var caption := LevelStoryCaption.new()
	caption.name = "LevelStoryCaption"
	caption._level = level
	caption._chapter = chapter
	level.add_child(caption)
	level.wave_flow.changed.connect(caption._on_progress)
	caption._on_progress(level.wave_flow.get_snapshot())
	return caption


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 15
	_panel = PanelContainer.new()
	_panel.theme = ArtUI.theme(22)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", ArtUI.paper(ArtUI.UI + "对话框.png", 28))
	add_child(_panel)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_constant_override("line_spacing", 4)
	_panel.add_child(_label)
	_panel.hide()


func _on_progress(snapshot: Dictionary) -> void:
	var index: int = -1
	if _chapter == 1 and snapshot.get("state") in ["initial_preparation", "preparation"]:
		index = int(snapshot.get("completed_waves", 0))
	elif _chapter == 2 and snapshot.get("state") != "stopped":
		# 第二关是持续生产，三句分别对应开局、摧毁第一座和第二座设施。
		index = int(snapshot.get("completed", 0))
	var lines: PackedStringArray = FIRST_LINES if _chapter == 1 else SECOND_LINES
	if index < 0 or index >= lines.size() or index in _seen:
		return
	_seen.append(index)
	_pending.append(index)


func _process(delta: float) -> void:
	if not _level.get_result_snapshot().is_empty() or _level._restart_pending:
		_pending.clear()
		_panel.hide()
		return
	var hud: CompactColonyHUD = _level.compact_hud
	var blocked: bool = get_tree().paused or hud.drawer.visible or hud._mode_panel.visible
	_panel.visible = not blocked and (_remaining > 0 or not _pending.is_empty())
	if not _panel.visible:
		return
	if _remaining <= 0:
		var lines: PackedStringArray = FIRST_LINES if _chapter == 1 else SECOND_LINES
		_label.text = lines[_pending.pop_front()]
		_remaining = maxf(7.0, _label.text.length() / 6.0 + 3.0)
		_panel.modulate.a = 1.0
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	_panel.size = Vector2(minf(760, viewport_size.x - 64), 0)
	_panel.position = Vector2((viewport_size.x - _panel.size.x) * 0.5, hud.dock.position.y - _panel.size.y - 16)
	_remaining = maxf(0.0, _remaining - delta)
	_panel.modulate.a = minf(1.0, _remaining / 0.8)
