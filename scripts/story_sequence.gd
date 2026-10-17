class_name StorySequence
extends Resource
## 每张图按对应秒数停留；缺图时仍播放文字占位。
@export var title: String = ""
@export_multiline var caption: String = ""
@export var frames: Array[Texture2D] = []
@export var frame_seconds: PackedFloat32Array = PackedFloat32Array()
@export var default_frame_seconds: float = 2.0
