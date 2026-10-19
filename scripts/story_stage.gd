class_name StoryStage
extends Control
## 只负责镜头绘制。原画、评论和转场使用播放器提供的时钟，暂停时不会偷跑。
var shot: StoryShot
var elapsed: float = 0.0
var _effect: ShaderMaterial
var _remarks: Array[PanelContainer] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_effect = ShaderMaterial.new()
	_effect.shader = preload("res://resources/story/memory_effect.gdshader")
	material = _effect
	resized.connect(_layout_remarks)


func show_shot(value: StoryShot, time: float) -> void:
	var changed: bool = shot != value
	shot = value
	elapsed = time
	if _effect != null:
		_effect.set_shader_parameter("elapsed", elapsed)
		_effect.set_shader_parameter("grain", shot.grain)
		_effect.set_shader_parameter("darkness", shot.darkness)
		_effect.set_shader_parameter("desaturation", shot.desaturation)
	if changed:
		_build_remarks()
	_layout_remarks()
	queue_redraw()


func _draw() -> void:
	if shot == null or size.x <= 0 or size.y <= 0:
		return
	# 整个承载区域填同一底色，透明边缘与淡入淡出不会出现黑洞。
	draw_rect(Rect2(Vector2.ZERO, size), shot.background)
	var view: Rect2 = shot.get_framing()
	var ratio: float = minf(size.x / view.size.x, size.y / view.size.y)
	var origin: Vector2 = (size - view.size * ratio) * 0.5 - view.position * ratio
	var tick: float = floorf(elapsed * 6.0)
	if shot.unsettled:
		origin += Vector2(sin(tick * 2.1), cos(tick * 1.7)) * 1.3
	draw_set_transform(origin, 0, Vector2.ONE * ratio)
	for index: int in range(shot.layers.size()):
		var offset := Vector2.ZERO
		if shot.hand_motion and index in [1, 2]:
			offset = Vector2(sin(tick * 0.8) * 7.0, cos(tick * 0.8) * 5.0)
		if shot.adult_entry and index in [3, 4]:
			offset.y -= pow(1.0 - minf(elapsed / 0.85, 1.0), 2.0) * 450.0
		if shot.layers[index] != null:
			# 手部贴图贴着画布边缘，移动时只绘制画布内部分，避免露到留白区。
			var target: Rect2 = Rect2(offset, shot.canvas_size).intersection(Rect2(Vector2.ZERO, shot.canvas_size))
			draw_texture_rect_region(shot.layers[index], target, Rect2(target.position - offset, target.size))
	if not shot.flipbook.is_empty():
		draw_texture_rect(shot.flipbook[shot.get_flipbook_index(elapsed)], Rect2(Vector2.ZERO, shot.canvas_size), false)
	if shot.unsettled and fmod(elapsed, 2.4) < 0.12:
		for index: int in range(3):
			var y: float = 180 + fmod(tick * 137 + index * 281, 720)
			draw_line(Vector2(0, y), Vector2(shot.canvas_size.x, y + 1), Color(0.65, 0.52, 0.7, 0.12), 3)
	draw_set_transform(Vector2.ZERO)


func _build_remarks() -> void:
	for panel: PanelContainer in _remarks:
		remove_child(panel)
		panel.queue_free()
	_remarks.clear()
	for text: String in shot.remarks:
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.theme = ArtUI.theme(24)
		panel.add_theme_stylebox_override("panel", ArtUI.paper(ArtUI.UI + "框底 (2).png", 20))
		var label := Label.new()
		label.text = text
		# 先给换行标签可用宽度，防止容器初次以零宽排字并撑成高纸片。
		label.custom_minimum_size.x = 240
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(label)
		add_child(panel)
		_remarks.append(panel)


func _layout_remarks() -> void:
	for index: int in range(_remarks.size()):
		var panel: PanelContainer = _remarks[index]
		var progress: float = clampf((elapsed - 0.5 - index * 0.8) / 0.35, 0, 1)
		panel.size = Vector2(clampf(size.x * 0.3, 280, 360), 0)
		panel.position = Vector2(size.x - panel.size.x - 28, 28 + index * 96 + (1 - progress) * 12)
		panel.modulate.a = progress
