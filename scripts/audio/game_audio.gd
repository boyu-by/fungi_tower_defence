class_name GameAudio
extends Node
## 场景拥有的有限声部播放器。退出关卡即释放，不向玩法模型写入任何状态。

signal sound_played(cue_id: StringName)
signal volume_changed(value: float)

class Voice:
	var player: AudioStreamPlayer
	var cue: SoundCue

@export var bank: SoundBank
@export var preferences_path: String = "user://audio_settings.cfg"

var effects_volume: float = 0.7
var _previous_volume: float = 0.7
var _cues: Dictionary[StringName, SoundCue] = {}
var _last_played: Dictionary[StringName, int] = {}
var _counts: Dictionary[StringName, int] = {}
var _voices: Array[Voice] = []
var _preferences_dirty: bool = false
var _random := RandomNumberGenerator.new()

@onready var save_timer: Timer = $SaveTimer


static func find_for(context: Node) -> GameAudio:
	if not is_instance_valid(context):
		return null
	var cursor: Node = context
	while cursor != null:
		if cursor is GameAudio:
			return cursor
		var audio := cursor.get_node_or_null("GameAudio") as GameAudio
		if audio != null:
			return audio
		cursor = cursor.get_parent()
	if context.is_inside_tree():
		var scene := context.get_tree().current_scene
		if is_instance_valid(scene):
			return scene.get_node_or_null("GameAudio") as GameAudio
	return null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_random.randomize()
	if bank != null:
		for cue in bank.cues:
			if cue != null and not cue.id.is_empty():
				_cues[cue.id] = cue
	for player: Node in $Players.find_children("*", "AudioStreamPlayer", true, false):
		var voice := Voice.new()
		voice.player = player as AudioStreamPlayer
		_voices.append(voice)
	var config := ConfigFile.new()
	if config.load(preferences_path) == OK:
		var saved: Variant = config.get_value("audio", "effects_volume", 0.7)
		if (saved is float or saved is int) and is_finite(float(saved)):
			effects_volume = clampf(float(saved), 0.0, 1.0)
	_apply_volume()


func play(cue_id: StringName) -> bool:
	if not is_node_ready() or effects_volume <= 0.0:
		return false
	var cue: SoundCue = _cues.get(cue_id)
	if cue == null or cue.streams.is_empty():
		return false
	if cue.channel == SoundCue.Channel.WORLD and get_tree().paused:
		return false
	var now := Time.get_ticks_usec()
	if _last_played.has(cue_id) and now - _last_played[cue_id] < int(cue.cooldown * 1000000.0):
		return false
	var active := 0
	for voice in _voices:
		if voice.cue == cue and voice.player.playing:
			active += 1
	if active >= cue.max_voices:
		return false
	var voice := _available_voice(cue)
	if voice == null:
		return false
	var stream := cue.streams[_random.randi_range(0, cue.streams.size() - 1)]
	if stream == null:
		return false
	voice.player.stop()
	voice.cue = cue
	voice.player.stream = stream
	voice.player.volume_db = cue.volume_db
	voice.player.pitch_scale = _random.randf_range(cue.pitch_min, maxf(cue.pitch_min, cue.pitch_max))
	voice.player.play()
	_last_played[cue_id] = now
	_counts[cue_id] = _counts.get(cue_id, 0) + 1
	sound_played.emit(cue_id)
	return true


func _available_voice(cue: SoundCue) -> Voice:
	var candidate: Voice = null
	for voice in _voices:
		if int(voice.player.get_meta("channel")) != cue.channel:
			continue
		if not voice.player.playing:
			return voice
		if voice.cue != null and (candidate == null or voice.cue.priority < candidate.cue.priority):
			candidate = voice
	if candidate != null and (cue.channel == SoundCue.Channel.STINGER or cue.priority > candidate.cue.priority):
		return candidate
	return null


func _process(_delta: float) -> void:
	for voice in _voices:
		if voice.cue == null or not voice.player.playing or voice.player.stream_paused:
			continue
		var limit := voice.cue.duration_limit
		if limit <= 0.0:
			continue
		var remaining := limit - voice.player.get_playback_position()
		if remaining <= 0.0:
			voice.player.stop()
		elif remaining < 0.04:
			voice.player.volume_db = voice.cue.volume_db + linear_to_db(maxf(remaining / 0.04, 0.001))


func stop_world() -> void:
	for voice in _voices:
		if int(voice.player.get_meta("channel")) == SoundCue.Channel.WORLD:
			voice.player.stop()


func stop_all() -> void:
	for voice in _voices:
		voice.player.stop()


func observe_ui(scope: Node) -> void:
	# 主线剧情位于导航层，仍复用当前场景播放器，弱引用不会延长剧情生命周期。
	$UIFeedback.observe_scope(scope)


func set_effects_volume(value: float, persist: bool = true) -> void:
	if not is_finite(value):
		return
	effects_volume = clampf(value, 0.0, 1.0)
	_apply_volume()
	if persist:
		_preferences_dirty = true
		save_timer.start()


func toggle_mute() -> void:
	set_effects_volume(0.0 if effects_volume > 0.0 else _previous_volume)


func _apply_volume() -> void:
	if effects_volume > 0.0:
		_previous_volume = effects_volume
	var bus := AudioServer.get_bus_index("Effects")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, effects_volume <= 0.0)
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(effects_volume, 0.001)))
	volume_changed.emit(effects_volume)


func save_preferences() -> void:
	if not _preferences_dirty:
		return
	var config := ConfigFile.new()
	config.set_value("audio", "effects_volume", effects_volume)
	if config.save(preferences_path) == OK:
		_preferences_dirty = false


func get_statistics() -> Dictionary:
	return _counts.duplicate()


func _exit_tree() -> void:
	stop_all()
	save_preferences()
