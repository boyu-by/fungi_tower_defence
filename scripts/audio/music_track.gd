class_name MusicTrack
extends Resource
## 音乐只配置曲目和混音电平，循环由音频导入设置控制。

@export var id: StringName
@export var stream: AudioStream
@export_range(-40.0, 0.0, 1.0) var volume_db: float = -14.0
