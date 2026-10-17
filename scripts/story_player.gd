class_name StoryPlayer
extends CanvasLayer
## 覆盖当前场景，不继承战斗暂停；结束和跳过统一发出一次完成信号。
signal finished
var sequence: StorySequence
var frame_index: int = 0
var playing: bool = true
var _elapsed: float = 0.0
var _finished: bool = false
var _image: TextureRect
var _counter: Label
var _next: Button
var _play: Button

static func open(parent: Node, chapter: int) -> StoryPlayer:
	var player := StoryPlayer.new()
	player.sequence = load("res://resources/story/cg%d.tres" % chapter) as StorySequence
	parent.add_child(player)
	return player

func _ready() -> void:
	add_to_group("story_players")
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	var backdrop := ColorRect.new()
	backdrop.color = Color("101d19")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	margin.theme = load("res://resources/ui/menu_theme.tres")
	backdrop.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)
	var title := Label.new()
	title.text = sequence.title
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	column.add_child(title)
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_image)
	var caption := Label.new()
	caption.text = sequence.caption
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 23)
	column.add_child(caption)
	_counter = Label.new()
	_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_counter)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	_play = _button(row, "暂停播放", _toggle_play)
	_next = _button(row, "下一帧", advance)
	_button(row, "跳过剧情", finish)
	_refresh()
	_next.grab_focus()

func _button(row: HBoxContainer, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(160, 48)
	button.pressed.connect(callback)
	row.add_child(button)
	return button

func _process(delta: float) -> void:
	if not playing or _finished or frame_index >= sequence.frames.size() - 1:
		return
	_elapsed += delta
	var duration: float = sequence.frame_seconds[frame_index] if frame_index < sequence.frame_seconds.size() else sequence.default_frame_seconds
	if _elapsed >= maxf(0.05, duration):
		advance()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			finish()
		elif event.keycode == KEY_SPACE:
			advance()
		get_viewport().set_input_as_handled()

func _toggle_play() -> void:
	playing = not playing
	_play.text = "暂停播放" if playing else "自动播放"

func advance() -> void:
	if _finished:
		return
	if frame_index >= sequence.frames.size() - 1:
		finish()
		return
	frame_index += 1
	_elapsed = 0.0
	_refresh()

func _refresh() -> void:
	_image.texture = sequence.frames[frame_index] if not sequence.frames.is_empty() else null
	_counter.text = "画面 %d / %d · Space 推进 · Esc 跳过" % [frame_index + 1, maxi(1, sequence.frames.size())]
	if sequence.frames.is_empty():
		_counter.text = "剧情占位 · 美术图片待替换 · Space 继续 · Esc 跳过"
	_next.text = "继续" if frame_index >= sequence.frames.size() - 1 else "下一帧"
	_play.disabled = sequence.frames.size() < 2

func finish() -> void:
	if _finished:
		return
	_finished = true
	finished.emit()
	queue_free()
