class_name StoryShot
extends Resource
## 一个镜头；图层按原始画布对齐。取景只去掉透明留白，不拉伸原画。
@export var title: String = ""
@export var speaker: String = ""
@export_multiline var caption: String = ""
@export var seconds: float = 5.0
@export var layers: Array[Texture2D] = []
@export var flipbook: Array[Texture2D] = []
@export var flipbook_seconds: float = 0.38
## 0为循环；正数到达次数后停在末帧。
@export_range(0, 16) var flipbook_loops: int = 0
@export var canvas_size: Vector2 = Vector2(1920, 1080)
@export var framing: Rect2 = Rect2()
## 同一画面的多段文案不重复转场；偏移用于连续画面的第二段字幕。
@export var scene_id: StringName = &""
@export var animation_offset: float = 0.0
@export_range(0.0, 2.0) var transition_seconds: float = 0.55
@export var background: Color = Color("e7dfd2")
@export_range(0.0, 1.0) var darkness: float = 0.0
@export_range(0.0, 1.0) var desaturation: float = 0.0
@export_range(0.0, 1.0) var grain: float = 0.025
@export var unsettled: bool = false
@export var hand_motion: bool = false
@export var adult_entry: bool = false
@export var remarks: PackedStringArray = PackedStringArray()


func get_framing() -> Rect2:
	return framing if framing.has_area() else Rect2(Vector2.ZERO, canvas_size)


func get_flipbook_index(time: float) -> int:
	if flipbook.is_empty():
		return 0
	var frame: int = int(maxf(0, time) / maxf(0.1, flipbook_seconds))
	if flipbook_loops > 0 and frame >= flipbook.size() * flipbook_loops:
		return flipbook.size() - 1
	return frame % flipbook.size()
