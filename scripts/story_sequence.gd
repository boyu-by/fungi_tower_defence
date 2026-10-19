class_name StorySequence
extends Resource
## 每张图按对应秒数停留；缺图时仍播放文字占位。
@export var title: String = ""
@export var music_id: StringName = &""
@export_multiline var caption: String = ""
@export var frames: Array[Texture2D] = []
@export var frame_seconds: PackedFloat32Array = PackedFloat32Array()
@export var default_frame_seconds: float = 2.0
## 新剧情使用分镜；保留 frames 以兼容尚未接入的 CG 与旧图片序列。
@export var shots: Array[StoryShot] = []


func get_count() -> int:
	return shots.size() if not shots.is_empty() else maxi(1, frames.size())


func get_seconds(index: int) -> float:
	if not shots.is_empty():
		return maxf(0.05, shots[index].seconds)
	return maxf(0.05, frame_seconds[index] if index < frame_seconds.size() else default_frame_seconds)
