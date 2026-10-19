extends SceneTree
## 声音只观察真实事件。射击/命中、回流、暂停和场景释放都不能改变玩法结算。

const AUDIO: PackedScene = preload("res://scenes/audio/game_audio.tscn")
const VOLUME: PackedScene = preload("res://scenes/audio/audio_volume_control.tscn")
const FIRST: PackedScene = preload("res://scenes/levels/first_level.tscn")
const ENEMY: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PREFS: String = "res://.artifact_work/audio-feedback-test.cfg"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.artifact_work"))
	if FileAccess.file_exists(PREFS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	await _test_catalog_limits_and_controls()
	await _test_real_combat_and_arrival()
	await _test_other_levels()
	await _test_story_shared_audio()
	await _test_story_lifetime()
	if FileAccess.file_exists(PREFS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	_check(root.get_child_count() == 0, "Sound components left root-level nodes")
	print("AUDIO_FEEDBACK_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
		await process_frame


func _count(audio: GameAudio, id: StringName) -> int:
	return int(audio.get_statistics().get(id, 0))


func _test_catalog_limits_and_controls() -> void:
	var owner := Node.new()
	root.add_child(owner)
	current_scene = owner
	var audio := AUDIO.instantiate() as GameAudio
	audio.preferences_path = PREFS
	owner.add_child(audio)
	await _frames(2)
	_check(audio.bank.cues.size() == 18 and audio._voices.size() == 9, "Catalog and fixed voice pool loaded")
	for cue: SoundCue in audio.bank.cues:
		_check(not cue.streams.is_empty(), "Cue has no audio: " + String(cue.id))
		for stream: AudioStream in cue.streams:
			_check(stream != null and stream.get_length() > 0.0, "Invalid audio stream: " + String(cue.id))
	_check(AudioServer.get_bus_index("Effects") >= 0, "Effects bus is missing")
	_check(audio.play(&"shoot"), "Configured shot was not played")
	_check(not audio.play(&"shoot") and _count(audio, &"shoot") == 1, "Repeated shot bypassed cooldown")
	_check(not audio.play(&"missing"), "Unknown cue was accepted")
	for cue: SoundCue in audio.bank.cues:
		audio.play(cue.id)
	var active: int = 0
	for voice in audio._voices:
		if voice.player.playing:
			active += 1
	_check(active <= 9, "Burst spawned unlimited voices")
	audio.stop_all()
	paused = true
	_check(not audio.play(&"grow"), "World sound started during global pause")
	await create_timer(0.15).timeout
	_check(audio.play(&"ui_cancel"), "Menu sound was disabled during pause")
	paused = false
	audio.stop_all()
	audio.set_effects_volume(0.0, false)
	_check(not audio.play(&"built"), "Muted audio still played")
	audio.set_effects_volume(0.55, false)
	var volume := VOLUME.instantiate() as HBoxContainer
	owner.add_child(volume)
	_check((volume.get_node("Volume") as HSlider).value == 55.0, "Volume control did not reflect mixer")
	(volume.get_node("Volume") as HSlider).value = 35.0
	_check(is_equal_approx(audio.effects_volume, 0.35), "Volume slider did not reach mixer")
	(volume.get_node("Toggle") as Button).pressed.emit()
	_check(is_zero_approx(audio.effects_volume), "Mute button did not mute")
	(volume.get_node("Toggle") as Button).pressed.emit()
	_check(is_equal_approx(audio.effects_volume, 0.35), "Unmute lost previous volume")
	audio.save_preferences()
	var config := ConfigFile.new()
	_check(config.load(PREFS) == OK and is_equal_approx(config.get_value("audio", "effects_volume"), 0.35),
		"Audio preferences were not saved independently")
	owner.queue_free()
	await _frames(2)


func _new_first() -> FirstLevel:
	var level := FIRST.instantiate() as FirstLevel
	(level.get_node("GameAudio") as GameAudio).preferences_path = PREFS
	root.add_child(level)
	current_scene = level
	await _frames(2)
	(level.get_node("GameAudio") as GameAudio).set_effects_volume(0.7, false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.fire_timer.stop()
	return level


func _test_real_combat_and_arrival() -> void:
	var level := await _new_first()
	var audio := level.get_node("GameAudio") as GameAudio
	var weapon: SporeWeapon = level.get_weapons()[0]
	var enemy := ENEMY.instantiate() as BasicEnemy
	enemy.mother_core = level.mother_core
	enemy.move_speed = 0.0
	level.get_node("World/Enemies").add_child(enemy)
	enemy.global_position = weapon.inventory_owner.global_position + Vector2(130, 0)
	await _frames(2)
	var stock := weapon.inventory_owner.nutrition
	_check(_count(audio, &"hit") == 0, "Enemy appearance played a false hit")
	weapon._on_fire_timer_timeout()
	_check(_count(audio, &"shoot") == 1, "Committed volley missed its sound")
	_check(enemy.health == 24 and _count(audio, &"hit") == 0, "Shot sound caused early damage or hit")
	_check(weapon.inventory_owner.nutrition == stock - 1, "Audio changed shot nutrition cost")
	for frame in range(100):
		if enemy.health < 24:
			break
		await physics_frame
	_check(enemy.health == 12 and _count(audio, &"hit") == 1, "Actual projectile hit missed its sound")
	enemy.take_damage(999)
	enemy.take_damage(999)
	_check(_count(audio, &"death") == 1, "Repeated death played multiple sounds")
	level.mother_core.add_nutrition(1)
	_check(_count(audio, &"income") == 0, "A refund or generic credit played recovery sound")
	var before := level.mother_core.nutrition
	_check(level.mother_core.accept_digestion_product("sound-test-product", 4), "Valid product was refused")
	_check(_count(audio, &"income") == 1 and level.mother_core.nutrition == before + 4,
		"Actual product arrival did not produce exactly one recovery sound")
	_check(not level.mother_core.accept_digestion_product("sound-test-product", 4), "Duplicate product accepted")
	_check(_count(audio, &"income") == 1, "Duplicate product repeated recovery sound")
	level.mother_core.take_damage(12)
	_check(_count(audio, &"core_hit") == 1, "Actual core damage missed warning")
	level.mother_core.heal(10.0)
	_check(_count(audio, &"core_hit") == 1, "Healing played damage warning")
	level.mother_core.take_damage(999)
	await _frames(3)
	_check(_count(audio, &"defeat") == 1, "Terminal defeat did not play while paused")
	level.level_finished.emit({"victory": false})
	_check(_count(audio, &"defeat") == 1, "Repeated result replayed terminal sound")
	for voice in audio._voices:
		if int(voice.player.get_meta("channel")) == SoundCue.Channel.WORLD:
			_check(not voice.player.playing, "Terminal state kept old combat sounds")
	level.queue_free()
	await _frames(2)
	_check(not paused, "Level cleanup retained global pause")


func _test_other_levels() -> void:
	for path: String in ["res://scenes/levels/second_level.tscn", "res://scenes/levels/third_level.tscn"]:
		var level := load(path).instantiate() as Node2D
		(level.get_node("GameAudio") as GameAudio).preferences_path = PREFS
		root.add_child(level)
		current_scene = level
		await _frames(2)
		var audio := GameAudio.find_for(level)
		_check(audio != null and audio._voices.size() == 9, "Shared level did not inherit audio: " + path)
		var initial: int = level.mother_core.nutrition
		level.mother_core.take_damage(1)
		_check(_count(audio, &"core_hit") == 1 and level.mother_core.nutrition == initial,
			"Shared level damage feedback changed resource balance: " + path)
		level.queue_free()
		await _frames(2)
		_check(not is_instance_valid(audio), "Audio escaped its level lifecycle")


func _test_story_shared_audio() -> void:
	var scene := Node.new()
	var audio := AUDIO.instantiate() as GameAudio
	audio.preferences_path = PREFS
	scene.add_child(audio)
	root.add_child(scene)
	current_scene = scene
	var story := StoryPlayer.open(root, 1)
	await _frames(2)
	_check(GameAudio.find_for(story) == audio and story.get_node_or_null("GameAudio") == null,
		"Navigator-owned story did not reuse the current scene audio")
	story._play.pressed.emit()
	_check(_count(audio, &"ui_click") == 1, "Navigator-owned story buttons missed UI feedback")
	story.finish()
	await _frames(2)
	_check(is_instance_valid(audio), "Closing a shared story freed its scene audio")
	scene.queue_free()
	await _frames(2)


func _test_story_lifetime() -> void:
	var player := StoryPlayer.new()
	player.sequence = load("res://resources/story/cg1.tres") as StorySequence
	var isolated_audio := AUDIO.instantiate() as GameAudio
	isolated_audio.preferences_path = PREFS
	player.add_child(isolated_audio)
	root.add_child(player)
	current_scene = player
	await _frames(2)
	var audio := GameAudio.find_for(player)
	_check(audio != null and _count(audio, &"paper") == 1, "Independent story preview lacked paper sound")
	player._refresh()
	_check(_count(audio, &"paper") == 1, "Refreshing same story frame replayed sound")
	paused = true
	await create_timer(0.55).timeout
	player.advance()
	_check(_count(audio, &"paper") == 2, "Story transition did not sound while world paused")
	player.finish()
	await _frames(2)
	_check(not is_instance_valid(audio), "Independent story audio leaked after closing")
	paused = false
