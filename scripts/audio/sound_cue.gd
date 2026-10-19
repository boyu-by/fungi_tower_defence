class_name SoundCue
extends Resource
## 一个声音事件的候选音色、混音与限流参数，只读配置，不参与游戏结算。

enum Channel { UI, WORLD, STINGER }

@export var id: StringName
@export var streams: Array[AudioStream] = []
@export var channel: Channel = Channel.WORLD
@export_range(-60.0, 0.0, 1.0) var volume_db: float = -20.0
@export_range(0.5, 2.0, 0.01) var pitch_min: float = 1.0
@export_range(0.5, 2.0, 0.01) var pitch_max: float = 1.0
@export_range(0.0, 5.0, 0.01) var cooldown: float = 0.1
@export_range(1, 6, 1) var max_voices: int = 2
@export_range(0, 10, 1) var priority: int = 0
## 0 播放完整片段；长素材可截短并在结尾淡出。
@export_range(0.0, 10.0, 0.01) var duration_limit: float = 0.0
