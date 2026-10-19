class_name GameMusic
extends Node
## 场景拥有两个音乐声部，用线性增益交接曲目，不影响关卡和剧情推进。

@export var library: MusicLibrary
@export_range(0.05, 2.0, 0.05) var fade_seconds: float = 0.5
@export_range(-30.0, 0.0, 1.0) var planning_attenuation_db: float = -12.0

class MusicVoice:
	var player: AudioStreamPlayer
	var track: MusicTrack
	var gain: float = 0.0
	var target: float = 0.0

var current_id: StringName = &""
var start_count: int = 0
var _voices: Array[MusicVoice] = []
var _current: MusicVoice
var _paused: bool = false
var _planning_gain: float = 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for player: Node in get_children():
		if player is AudioStreamPlayer:
			var voice := MusicVoice.new()
			voice.player = player
			_voices.append(voice)


func play_track(id: StringName) -> bool:
	if id == current_id and _current != null:
		return true
	var track := library.find_track(id) if library != null else null
	if track == null or track.stream == null or _voices.size() < 2:
		return false
	var next: MusicVoice = _voices[0] if _current != _voices[0] else _voices[1]
	if _current == null:
		next = _voices[0] if _voices[0].gain <= _voices[1].gain else _voices[1]
	for voice in _voices:
		voice.target = 0.0
	next.player.stop()
	next.track = track
	next.gain = 0.0
	next.target = 1.0
	next.player.stream = track.stream
	next.player.volume_db = -80.0
	next.player.stream_paused = false
	next.player.play()
	_current = next
	current_id = id
	_paused = false
	start_count += 1
	return true


func set_music_paused(value: bool) -> void:
	_paused = value
	for voice in _voices:
		voice.player.stream_paused = value


func stop_music(immediate: bool = false) -> void:
	# 暂停中的曲目已经静音；跳过剧情时直接释放，避免为淡出而短暂恢复声音。
	immediate = immediate or _paused
	current_id = &""
	_current = null
	_paused = false
	for voice in _voices:
		voice.target = 0.0
		voice.player.stream_paused = false
		if immediate:
			voice.gain = 0.0
			voice.player.stop()
			voice.player.stream = null
			voice.track = null


func _process(delta: float) -> void:
	var step := maxf(delta, 0.0) / maxf(fade_seconds, 0.05)
	var planning_target := db_to_linear(planning_attenuation_db) if get_tree().paused else 1.0
	_planning_gain = move_toward(_planning_gain, planning_target, step)
	for voice in _voices:
		if voice.track == null:
			continue
		if not _paused:
			voice.gain = move_toward(voice.gain, voice.target, step)
		if voice.gain <= 0.0 and voice.target <= 0.0:
			voice.player.stop()
			voice.player.stream = null
			voice.track = null
			continue
		var gain := voice.gain * (_planning_gain if voice.track.id == &"battle" else 1.0)
		voice.player.volume_db = voice.track.volume_db + linear_to_db(maxf(gain, 0.0001))


func _exit_tree() -> void:
	stop_music(true)
