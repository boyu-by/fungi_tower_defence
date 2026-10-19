extends SceneTree
## 音乐验证覆盖真实声部、剧情和三关生命周期，不触碰玩家音量与主线存档。

const AUDIO: PackedScene = preload("res://scenes/audio/game_audio.tscn")
const SETTINGS: PackedScene = preload("res://scenes/audio/audio_settings_control.tscn")
const PREFS: String = "res://.artifact_work/music-integration-test.cfg"
const LEVEL_PATHS: Array[String] = ["res://scenes/levels/first_level.tscn",
	"res://scenes/levels/second_level.tscn", "res://scenes/levels/third_level.tscn"]

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.artifact_work"))
	_remove_preferences()
	# node_added precedes _ready, including the real standalone StoryPlayer fallback.
	node_added.connect(_isolate_audio_preferences)
	await _frames(2)
	await _test_tracks_and_real_playback()
	await _test_independent_volume_and_persistence()
	await _test_standalone_story_lifecycle()
	await _test_navigator_story_lifecycle()
	await _test_three_level_lifecycles()
	_remove_preferences()
	node_added.disconnect(_isolate_audio_preferences)
	_check(root.get_child_count() == 0, "Music or story services escaped their owning scenes")
	_check(not paused, "Music fixtures left the world paused")
	print("MUSIC_INTEGRATION_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _isolate_audio_preferences(node: Node) -> void:
	if node is GameAudio:
		node.preferences_path = PREFS


func _remove_preferences() -> void:
	if FileAccess.file_exists(PREFS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
		await process_frame


func _new_scene() -> Node:
	var scene := Node.new()
	scene.add_child(AUDIO.instantiate())
	root.add_child(scene)
	current_scene = scene
	await _frames(2)
	return scene


func _active_count(music: GameMusic) -> int:
	var count: int = 0
	for voice in music._voices:
		if voice.player.playing:
			count += 1
	return count


func _test_tracks_and_real_playback() -> void:
	var scene := await _new_scene()
	var audio := scene.get_node("GameAudio") as GameAudio
	var music := audio.get_node("Music") as GameMusic
	_check(music.library.tracks.size() == 4 and music._voices.size() == 2,
		"Four music tracks must share exactly two bounded voices")
	for id: StringName in [&"chapter_1", &"chapter_2", &"chapter_3", &"battle"]:
		var track := music.library.find_track(id)
		_check(track != null and track.stream != null and track.stream.get_length() > 1.0,
			"Invalid or missing music track: " + String(id))
		var stream := track.stream as AudioStreamMP3
		_check(stream != null and stream.loop, "Music must loop during long sessions and final CG panels: " + String(id))
	for voice in music._voices:
		_check(voice.player.bus == &"Music" and voice.player.process_mode == Node.PROCESS_MODE_ALWAYS,
			"Music player must use its independent bus and survive world pause")
	_check(not audio.play_music(&"missing") and music.start_count == 0,
		"An unknown track must not start or change the music state")
	_check(audio.play_music(&"chapter_1"), "Chapter 1 music did not start")
	await create_timer(music.fade_seconds + 0.15).timeout
	var first_voice := music._current
	var position := first_voice.player.get_playback_position()
	_check(position > 0.05 and is_equal_approx(first_voice.gain, 1.0),
		"Chapter music did not advance through its fade-in")
	_check(audio.play_music(&"chapter_1") and music.start_count == 1 and music._current == first_voice,
		"Repeating the current music request must reuse the existing playback")
	await create_timer(0.12).timeout
	_check(first_voice.player.get_playback_position() >= position,
		"Repeating a track reset its playback position")
	_check(not audio.play_music(&"missing") and music.current_id == &"chapter_1" and music.start_count == 1,
		"An invalid request interrupted a running track")
	paused = true
	var chapter_gain := first_voice.player.volume_db
	await create_timer(music.fade_seconds + 0.1).timeout
	_check(is_equal_approx(first_voice.player.volume_db, chapter_gain),
		"World pause unexpectedly attenuated chapter music")
	paused = false
	_check(audio.play_music(&"battle") and _active_count(music) == 2,
		"Track changes must crossfade the existing pair of voices")
	await create_timer(music.fade_seconds + 0.1).timeout
	_check(_active_count(music) == 1 and first_voice.track == null,
		"The old chapter track was not released after the crossfade")
	var battle_voice := music._current
	var battle_gain := battle_voice.player.volume_db
	paused = true
	position = battle_voice.player.get_playback_position()
	await create_timer(music.fade_seconds + 0.1).timeout
	_check(absf(battle_voice.player.volume_db - battle_gain - music.planning_attenuation_db) < 0.1,
		"Paused battle music did not attenuate by the configured planning gain")
	_check(battle_voice.player.get_playback_position() > position,
		"Planning pause restarted or froze the battle music")
	paused = false
	await create_timer(music.fade_seconds + 0.1).timeout
	_check(absf(battle_voice.player.volume_db - battle_gain) < 0.1,
		"Leaving pause did not restore the battle music gain")
	audio.pause_music(true)
	position = battle_voice.player.get_playback_position()
	await create_timer(0.15).timeout
	_check(battle_voice.player.stream_paused and absf(battle_voice.player.get_playback_position() - position) < 0.06,
		"Explicit story playback pause did not hold the audio timeline")
	audio.pause_music(false)
	await create_timer(0.15).timeout
	_check(not battle_voice.player.stream_paused and battle_voice.player.get_playback_position() > position,
		"Resuming music failed to continue its existing timeline")
	battle_voice.player.seek(battle_voice.player.stream.get_length() - 0.12)
	await create_timer(0.35).timeout
	_check(battle_voice.player.playing and battle_voice.player.get_playback_position() < 1.0,
		"Battle music did not wrap to the beginning across its actual loop boundary")
	audio.stop_music(&"chapter_1")
	_check(music.current_id == &"battle", "An outgoing story stopped a newer battle track")
	audio.stop_music(&"battle")
	await create_timer(music.fade_seconds + 0.1).timeout
	_check(music.current_id.is_empty() and _active_count(music) == 0,
		"Stopping the matching track failed to fade and release playback")
	scene.queue_free()
	await _frames(2)
	_check(not is_instance_valid(music), "Scene disposal retained music players")


func _test_independent_volume_and_persistence() -> void:
	var scene := await _new_scene()
	var audio := scene.get_node("GameAudio") as GameAudio
	var settings := SETTINGS.instantiate() as VBoxContainer
	scene.add_child(settings)
	audio.set_effects_volume(0.35, false)
	audio.set_music_volume(0.65, false)
	var effects_slider := settings.get_node("Effects/Volume") as HSlider
	var music_slider := settings.get_node("Music/Volume") as HSlider
	_check(effects_slider.value == 35.0 and music_slider.value == 65.0,
		"Audio settings did not display independent effect and music volumes")
	music_slider.value = 45.0
	_check(is_equal_approx(audio.music_volume, 0.45) and is_equal_approx(audio.effects_volume, 0.35),
		"Music slider changed the effects volume")
	(settings.get_node("Music/Toggle") as Button).pressed.emit()
	_check(is_zero_approx(audio.music_volume) and not AudioServer.is_bus_mute(AudioServer.get_bus_index("Effects")),
		"Muting music also muted the sound effects")
	(settings.get_node("Music/Toggle") as Button).pressed.emit()
	_check(is_equal_approx(audio.music_volume, 0.45), "Music unmute did not restore its previous volume")
	effects_slider.value = 25.0
	(settings.get_node("Effects/Toggle") as Button).pressed.emit()
	_check(is_zero_approx(audio.effects_volume) and not AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")),
		"Muting effects also muted the background music")
	(settings.get_node("Effects/Toggle") as Button).pressed.emit()
	_check(is_equal_approx(audio.effects_volume, 0.25) and is_equal_approx(audio.music_volume, 0.45),
		"Independent mute toggles lost their channel volumes")
	audio.save_preferences()
	var config := ConfigFile.new()
	_check(config.load(PREFS) == OK and is_equal_approx(config.get_value("audio", "music_volume"), 0.45)
		and is_equal_approx(config.get_value("audio", "effects_volume"), 0.25),
		"Independent sound preferences were not saved together")
	scene.queue_free()
	await _frames(2)
	scene = await _new_scene()
	audio = scene.get_node("GameAudio") as GameAudio
	_check(is_equal_approx(audio.music_volume, 0.45) and is_equal_approx(audio.effects_volume, 0.25),
		"Replacing a scene lost its saved independent channel volumes")
	scene.queue_free()
	await _frames(2)


func _test_standalone_story_lifecycle() -> void:
	current_scene = null
	var story := StoryPlayer.open(root, 2)
	await _frames(2)
	var audio := GameAudio.find_for(story)
	var music := audio.get_node("Music") as GameMusic
	_check(audio.get_parent() == story and audio.preferences_path == PREFS,
		"Standalone CG preview did not create its own isolated audio service")
	_check(music.current_id == &"chapter_2" and music.start_count == 1,
		"Standalone CG did not select its chapter music")
	await create_timer(0.15).timeout
	story._toggle_play()
	var position := music._current.player.get_playback_position()
	await create_timer(0.15).timeout
	_check(not story.playing and music._current.player.stream_paused
		and absf(music._current.player.get_playback_position() - position) < 0.06,
		"Pausing CG animation did not pause the matching music")
	story.advance()
	_check(music.start_count == 1 and music._current.player.stream_paused,
		"Manual CG frame changes restarted or unpaused the chapter track")
	story._toggle_play()
	await create_timer(0.15).timeout
	_check(story.playing and music._current.player.get_playback_position() > position,
		"Resuming the CG failed to resume its chapter timeline")
	story.finish()
	_check(music.current_id.is_empty(), "Finishing standalone CG did not release chapter music")
	await _frames(2)
	_check(not is_instance_valid(audio), "Standalone CG audio escaped its lifecycle")


func _test_navigator_story_lifecycle() -> void:
	var scene := await _new_scene()
	var audio := scene.get_node("GameAudio") as GameAudio
	var music := audio.get_node("Music") as GameMusic
	var navigator := Node.new()
	root.add_child(navigator)
	var expected: Array[StringName] = [&"chapter_1", &"chapter_2", &"chapter_3", &"chapter_3"]
	paused = true
	for chapter: int in range(1, 5):
		var story := StoryPlayer.open(navigator, chapter)
		await _frames(2)
		_check(GameAudio.find_for(story) == audio and story.get_node_or_null("GameAudio") == null,
			"Navigator CG created a duplicate audio service: " + str(chapter))
		_check(story.sequence.music_id == expected[chapter - 1] and music.current_id == expected[chapter - 1],
			"CG selected the wrong chapter track: " + str(chapter))
		var starts := music.start_count
		story.advance()
		story.previous()
		_check(music.start_count == starts, "CG frame navigation restarted its soundtrack: " + str(chapter))
		if chapter == 2:
			story._toggle_play()
			_check(music._current.player.stream_paused, "Shared CG pause did not silence its music before skip")
		story.finish()
		_check(music.current_id.is_empty(), "Navigator CG did not release its music: " + str(chapter))
		if chapter == 2:
			_check(_active_count(music) == 0, "Skipping paused CG briefly resumed its already silent music")
			await create_timer(0.15).timeout
			_check(_active_count(music) == 0, "Skipped paused CG music resumed on a later frame")
		await _frames(2)
		_check(is_instance_valid(audio), "Navigator CG freed the scene-owned shared audio service")
	paused = false
	var interrupted := StoryPlayer.open(navigator, 1)
	audio.play_music(&"battle")
	interrupted.finish()
	await _frames(2)
	_check(music.current_id == &"battle", "Late CG cleanup interrupted a newer soundtrack")
	navigator.queue_free()
	scene.queue_free()
	await _frames(2)


func _test_three_level_lifecycles() -> void:
	for index: int in range(LEVEL_PATHS.size()):
		# 第一关保留旧教程类继承，三关共用场景组件和终局接口。
		var level := load(LEVEL_PATHS[index]).instantiate() as Node2D
		root.add_child(level)
		current_scene = level
		await _frames(2)
		var audio := GameAudio.find_for(level)
		var music := audio.get_node("Music") as GameMusic
		_check(music.current_id == &"battle" and music.start_count == 1,
			"Level did not inherit shared battle music: " + str(index + 1))
		if index == 0:
			level.mother_core.take_damage(99999)
		else:
			level.finish_level(true)
		await _frames(3)
		_check(not level.get_result_snapshot().is_empty() and music.current_id.is_empty(),
			"A real terminal result failed to stop battle music: " + str(index + 1))
		await create_timer(music.fade_seconds + 0.1).timeout
		_check(_active_count(music) == 0, "Terminal state retained audible battle music: " + str(index + 1))
		level.queue_free()
		await _frames(2)
		_check(not is_instance_valid(audio) and not paused,
			"Level disposal retained music or global pause: " + str(index + 1))
