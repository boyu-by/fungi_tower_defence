extends SceneTree
var failures: int = 0
var completions: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	for chapter: int in range(1, 5):
		var player := StoryPlayer.open(root, chapter)
		_check(not player.sequence.title.is_empty() and not player.sequence.caption.is_empty(), "four chapters have narrative placeholders")
		player.finished.connect(func() -> void: completions += 1)
		player.advance()
		player.finish()
		await process_frame
	_check(completions == 4, "advance and skip complete each placeholder exactly once")
	var sequence := StorySequence.new()
	sequence.frames = [PlaceholderTexture2D.new(), PlaceholderTexture2D.new(), PlaceholderTexture2D.new()]
	sequence.frame_seconds = PackedFloat32Array([0.1, 0.2])
	var player := StoryPlayer.new()
	player.sequence = sequence
	root.add_child(player)
	paused = true
	player._process(0.11)
	_check(player.frame_index == 1, "configured frame durations advance while tree paused")
	player._toggle_play()
	player._process(1.0)
	_check(player.frame_index == 1, "manual pause holds image")
	player.advance()
	_check(player.frame_index == 2, "manual advance works while paused")
	player._toggle_play()
	player._process(100.0)
	_check(not player._finished, "last image waits for explicit continue")
	player.finished.connect(func() -> void: completions += 1)
	player.finish()
	player.finish()
	await process_frame
	_check(completions == 5, "skip cannot double-complete image sequence")
	paused = false
	print("STORY PLAYER failures=", failures)
	quit(0 if failures == 0 else 1)
