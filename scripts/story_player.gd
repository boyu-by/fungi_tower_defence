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
var _previous: Button
var _stage: StoryStage
var _caption: Label
var _speaker: Label
var _title: Label
var _dialogue: PanelContainer
var _caption_scroll: ScrollContainer
var _outgoing: StoryStage
var _incoming_group: CanvasGroup
var _transition_elapsed: float = 0.0
var _transition_duration: float = 0.0
var _audio: GameAudio
var _last_audio_frame: int = -1

static func open(parent: Node, chapter: int) -> StoryPlayer:
	var player := StoryPlayer.new()
	player.sequence = load("res://resources/story/cg%d.tres" % chapter) as StorySequence
	parent.add_child(player)
	return player

func _ready() -> void:
	add_to_group("story_players")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audio = GameAudio.find_for(self)
	if _audio == null:
		_audio = preload("res://scenes/audio/game_audio.tscn").instantiate() as GameAudio
		add_child(_audio)
	_audio.observe_ui(self)
	layer = 100
	var backdrop := ColorRect.new()
	backdrop.color = Color("e7dfd2")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.theme = ArtUI.theme(22)
	backdrop.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)
	_title = Label.new()
	_title.text = sequence.title
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ArtUI.typography(_title, 26, true)
	column.add_child(_title)
	var visual := Control.new()
	visual.custom_minimum_size.y = 160
	visual.size_flags_vertical = Control.SIZE_EXPAND_FILL
	visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(visual)
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visual.add_child(_image)
	# 先合成一个完整画面再调透明度，避免多层手部与底图在转场中逐层透色。
	var outgoing_group := CanvasGroup.new()
	visual.add_child(outgoing_group)
	_outgoing = StoryStage.new()
	outgoing_group.add_child(_outgoing)
	_outgoing.hide()
	_incoming_group = CanvasGroup.new()
	visual.add_child(_incoming_group)
	_stage = StoryStage.new()
	_incoming_group.add_child(_stage)
	visual.resized.connect(func() -> void:
		_stage.size = visual.size
		_outgoing.size = visual.size)
	_dialogue = PanelContainer.new()
	_dialogue.custom_minimum_size.y = 126
	var paper: StyleBoxTexture = ArtUI.paper(ArtUI.UI + "对话框.png", 20)
	paper.content_margin_left = 36
	paper.content_margin_right = 48
	paper.content_margin_bottom = 26
	_dialogue.add_theme_stylebox_override("panel", paper)
	column.add_child(_dialogue)
	_caption_scroll = ScrollContainer.new()
	_caption_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dialogue.add_child(_caption_scroll)
	var text_column := VBoxContainer.new()
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_column.alignment = BoxContainer.ALIGNMENT_CENTER
	_caption_scroll.add_child(text_column)
	_speaker = Label.new()
	ArtUI.typography(_speaker, 20, true)
	text_column.add_child(_speaker)
	_caption = Label.new()
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.add_theme_constant_override("line_spacing", 5)
	ArtUI.typography(_caption, 26)
	text_column.add_child(_caption)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	column.add_child(row)
	_counter = Label.new()
	_counter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ArtUI.typography(_counter, 18)
	row.add_child(_counter)
	_previous = _button(row, "上一幕", previous)
	_play = _button(row, "暂停播放", _toggle_play)
	_next = _button(row, "下一幕", advance)
	_button(row, "跳过剧情", finish)
	var volume := preload("res://scenes/audio/audio_volume_control.tscn").instantiate() as Control
	row.add_child(volume)
	_refresh()
	_next.grab_focus()

func _button(row: HBoxContainer, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(144, 46)
	button.pressed.connect(callback)
	row.add_child(button)
	return button

func _process(delta: float) -> void:
	if not playing or _finished:
		return
	_elapsed += maxf(0.0, delta)
	if not sequence.shots.is_empty():
		_stage.show_shot(sequence.shots[frame_index], _elapsed + sequence.shots[frame_index].animation_offset)
		_transition_elapsed += maxf(0.0, delta)
		_update_transition()
	if frame_index < sequence.get_count() - 1 and _elapsed >= sequence.get_seconds(frame_index):
		advance()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			finish()
		elif event.keycode == KEY_SPACE:
			advance()
		elif event.keycode == KEY_LEFT:
			previous()
		elif event.keycode == KEY_P:
			_toggle_play()
		elif event.keycode in [KEY_TAB, KEY_ENTER, KEY_KP_ENTER, KEY_UP, KEY_DOWN, KEY_RIGHT]:
			# 留给当前剧情按钮的键盘导航；其他游戏快捷键由剧情层拦截。
			return
		get_viewport().set_input_as_handled()

func _toggle_play() -> void:
	playing = not playing
	_play.text = "暂停播放" if playing else "自动播放"

func advance() -> void:
	if _finished:
		return
	if frame_index >= sequence.get_count() - 1:
		finish()
		return
	frame_index += 1
	_elapsed = 0.0
	_refresh()

func previous() -> void:
	if _finished or frame_index <= 0:
		return
	frame_index -= 1
	_elapsed = 0.0
	_refresh()

func _refresh() -> void:
	var has_shots: bool = not sequence.shots.is_empty()
	_stage.visible = has_shots
	_image.visible = not has_shots
	_caption.position.x = 0
	if has_shots:
		var shot: StoryShot = sequence.shots[frame_index]
		var old_shot: StoryShot = _stage.shot
		var same_scene: bool = old_shot != null and not shot.scene_id.is_empty() and old_shot.scene_id == shot.scene_id
		_transition_duration = shot.transition_seconds if playing and old_shot != null and old_shot != shot and not same_scene else 0.0
		_transition_elapsed = 0.0
		if _transition_duration > 0:
			_outgoing.show_shot(old_shot, _stage.elapsed)
		_stage.show_shot(shot, _elapsed + shot.animation_offset)
		_update_transition()
		_title.text = shot.title if not shot.title.is_empty() else sequence.title
		_caption.text = shot.caption
		_speaker.text = shot.speaker
	else:
		_image.texture = sequence.frames[frame_index] if not sequence.frames.is_empty() else null
		_caption.text = sequence.caption
		_speaker.text = ""
	_speaker.visible = not _speaker.text.is_empty()
	# 无字幕分镜保留同样的画面尺寸，避免漫画逐格出现时镜头忽大忽小。
	_dialogue.modulate.a = 0.0 if _caption.text.is_empty() else 1.0
	_caption_scroll.scroll_vertical = 0
	_counter.text = "%02d / %02d" % [frame_index + 1, sequence.get_count()]
	if not has_shots and sequence.frames.is_empty():
		_counter.text = "剧情占位 · 美术图片待替换 · Space 继续 · Esc 跳过"
	_next.text = "继续" if frame_index >= sequence.get_count() - 1 else "下一幕"
	_play.disabled = sequence.get_count() < 2
	_previous.disabled = frame_index == 0
	_previous.tooltip_text = "← 上一幕"
	_next.tooltip_text = "Space 下一幕或继续"
	_play.tooltip_text = "P 暂停或自动播放"
	if _last_audio_frame != frame_index:
		_last_audio_frame = frame_index
		_audio.play(&"paper")


func _update_transition() -> void:
	var weight: float = clampf(_transition_elapsed / _transition_duration, 0, 1) if _transition_duration > 0 else 1.0
	_incoming_group.modulate.a = smoothstep(0.0, 1.0, weight)
	_outgoing.visible = weight < 1.0

func finish() -> void:
	if _finished:
		return
	_finished = true
	finished.emit()
	queue_free()
