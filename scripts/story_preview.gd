extends Control
## 编辑器 F6 直接预览，不进入关卡、不改写存档。
@export_range(1, 4) var chapter: int = 1

func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var replay := Button.new()
	replay.text = "重播剧情"
	replay.custom_minimum_size = Vector2(220, 64)
	center.add_child(replay)
	replay.pressed.connect(_play)
	_play()

func _play() -> void:
	StoryPlayer.open(self, chapter)
