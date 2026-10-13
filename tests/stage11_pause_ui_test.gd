extends SceneTree
## 独立夹具：真实场景树暂停、Timer、Tween 与 GUI 输入；不启动任何游戏系统。

const PAUSE_SCRIPT: Script = preload("res://scripts/global_pause_controller.gd")
const HUD_SCENE: PackedScene = preload("res://scenes/ui/first_level_hud.tscn")

class SimulationProbe extends Node:
	var process_steps: int = 0
	var physics_steps: int = 0
	var timer_ticks: int = 0
	var tween_value: float = 0.0
	var timer: Timer = Timer.new()

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_PAUSABLE

	func _ready() -> void:
		timer.wait_time = 0.03
		timer.one_shot = false
		timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
		timer.timeout.connect(func() -> void: timer_ticks += 1)
		add_child(timer)
		timer.start()
		create_tween().tween_property(self, "tween_value", 100.0, 10.0)

	func _process(_delta: float) -> void:
		process_steps += 1

	func _physics_process(_delta: float) -> void:
		physics_steps += 1

class UIProbe extends Node:
	var steps: int = 0

	func _process(_delta: float) -> void:
		steps += 1

class UnhandledProbe extends Node:
	var space_events: int = 0

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _unhandled_input(event: InputEvent) -> void:
		var key: InputEventKey = event as InputEventKey
		if key != null and (key.keycode == KEY_SPACE or key.physical_keycode == KEY_SPACE):
			space_events += 1

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []
var _fixture: Node
var _controller: GlobalPauseController
var _hud: FirstLevelHUD
var _simulation: SimulationProbe
var _ui_probe: UIProbe
var _unhandled_probe: UnhandledProbe
var _focus_witness: Button
var _pause_events: Array[bool] = []
var _intents: Dictionary = {"start": 0, "pause": 0, "restart": 0, "foreign_accept": 0}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 920)
	_create_fixture()
	await _frames(12)
	await _test_real_tree_freeze()
	_test_space_and_reset()
	await _test_ui_intents_and_snapshot_copy()
	await _test_exit_unpauses()
	_fixture.free()
	await _frames(2)
	_check(not paused and root.get_child_count() == 0, "Fixture cleanup leaves no paused tree or orphan UI")
	print("STAGE11_PAUSE_UI_TEST_RESULT ", JSON.stringify({"checks": checks,
		"failures": failures, "evidence": evidence,
		"scope": "standalone SceneTree pause, sibling process/physics/Timer/Tween, actual viewport GUI events and copied result snapshots"}))
	quit(0 if failures.is_empty() else 1)


func _create_fixture() -> void:
	_fixture = Node.new()
	_fixture.name = "PauseUIFixture"
	_fixture.process_mode = Node.PROCESS_MODE_ALWAYS
	_simulation = SimulationProbe.new()
	_simulation.name = "Simulation"
	_controller = PAUSE_SCRIPT.new() as GlobalPauseController
	_controller.name = "GlobalPauseController"
	_hud = HUD_SCENE.instantiate() as FirstLevelHUD
	_ui_probe = UIProbe.new()
	_ui_probe.name = "UIHeartbeat"
	_hud.add_child(_ui_probe)
	_unhandled_probe = UnhandledProbe.new()
	_unhandled_probe.name = "UnhandledWitness"
	_focus_witness = Button.new()
	_focus_witness.name = "ForeignFocusWitness"
	_focus_witness.text = "Foreign focus witness"
	_focus_witness.position = Vector2(24, 250)
	_focus_witness.size = Vector2(200, 32)
	_focus_witness.focus_mode = Control.FOCUS_ALL
	_focus_witness.pressed.connect(func() -> void: _intents["foreign_accept"] += 1)
	_fixture.add_child(_simulation)
	_fixture.add_child(_unhandled_probe)
	_fixture.add_child(_focus_witness)
	_fixture.add_child(_hud)
	_fixture.add_child(_controller)
	root.add_child(_fixture)
	_controller.pause_changed.connect(_on_pause_changed)
	_hud.start_requested.connect(func() -> void: _intents["start"] += 1)
	_hud.pause_requested.connect(func() -> void: _intents["pause"] += 1)
	_hud.restart_requested.connect(func() -> void: _intents["restart"] += 1)
	_hud.show_flow(_flow_snapshot())
	_hud.show_colony({"core_health": 81.5, "core_max_health": 100, "nutrition": 37,
		"total_recovered": 148, "stage_name": "扩张", "elapsed_seconds": 125.9})


func _on_pause_changed(value: bool) -> void:
	_pause_events.append(value)
	_hud.show_pause(value)


func _test_real_tree_freeze() -> void:
	_check(_controller.process_mode == Node.PROCESS_MODE_ALWAYS
		and _hud.process_mode == Node.PROCESS_MODE_ALWAYS,
		"Pause controller and HUD always process independently of their parent")
	_check(_simulation.process_steps > 0 and _simulation.physics_steps > 0
		and _simulation.timer_ticks > 0 and _simulation.tween_value > 0.0,
		"Actual sibling process, physics, Timer and bound Tween advance before pause")
	_controller.set_paused(true)
	await _frames(2)
	var before: Dictionary = _simulation_snapshot()
	var ui_before: int = _ui_probe.steps
	await _frames(12)
	var after: Dictionary = _simulation_snapshot()
	_check(paused and _controller.is_paused(), "Controller freezes the real SceneTree")
	_check(before == after, "Pause freezes sibling process, physics, Timer ticks/time-left and bound Tween exactly")
	_check(_ui_probe.steps > ui_before, "HUD descendants keep processing while world simulation is paused")
	_check(_hud.pause_label.text.contains("倒计时冻结") and _hud.start_button.disabled,
		"Pause UI explains planning and disables starting a wave")
	_check(not _hud.is_pointer_over_panel(Vector2(620, 380)),
		"Pause adds no full-screen overlay over battlefield selection and previews")
	_controller.set_paused(false)
	await _frames(12)
	_check(_simulation.process_steps > int(after["process"])
		and _simulation.physics_steps > int(after["physics"])
		and _simulation.timer_ticks > int(after["ticks"])
		and _simulation.tween_value > float(after["tween"]),
		"Resuming advances the same sibling simulation, Timer and bound Tween")
	evidence.append({"case": "actual_scene_tree_freeze", "before": before, "during": after,
		"ui_steps_during_pause": _ui_probe.steps - ui_before})


func _test_space_and_reset() -> void:
	_controller.reset()
	_pause_events.clear()
	_controller.set_paused(false)
	_controller.set_paused(false)
	_check(_pause_events.is_empty(), "Setting the same pause value is idempotent")
	_focus_witness.grab_focus()
	_check(root.gui_get_focus_owner() == _focus_witness, "A real focusable foreign button owns keyboard focus")
	_check(_key(KEY_SPACE, true), "Space press is consumed in _input before GUI")
	_check(paused and _pause_events == [true], "One fresh Space press toggles exactly once")
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, true, true)
	_check(paused and _pause_events.size() == 1, "Repeated key-down and echo cannot repeat the pause toggle")
	_check(_key(KEY_SPACE, false), "Space release is also consumed before GUI")
	_check(paused and _pause_events.size() == 1, "Space release never toggles pause")
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	_check(not paused and _pause_events == [true, false], "The next full Space press resumes exactly once")
	_check(int(_intents["foreign_accept"]) == 0 and _unhandled_probe.space_events == 0,
		"Consumed Space cannot activate focused ui_accept or reach unhandled gameplay input")
	_check(int(_intents["start"]) == 0 and int(_intents["restart"]) == 0,
		"Pausing and resuming cannot start or restart the level")
	_check(not _key(KEY_R, true) and not _key(KEY_R, false), "R is left to the owning level input")
	_controller.set_terminal(true)
	_controller.toggle_pause()
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	_check(not paused and _pause_events.size() == 2, "Terminal locks button/direct and Space toggles")
	_controller.set_paused(true)
	_check(paused, "Lifecycle may explicitly set pause while terminal toggle is locked")
	_controller.reset()
	var after_reset: int = _pause_events.size()
	_controller.reset()
	_check(not paused and not _controller.is_paused() and _pause_events.size() == after_reset,
		"Reset always resumes and repeated reset emits no extra transition")
	_key(KEY_SPACE, true)
	_check(paused, "Reset removes the terminal lock for a new preparation")
	_controller.reset()
	var held_reset_count: int = _pause_events.size()
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, true, true)
	_check(not paused and _pause_events.size() == held_reset_count,
		"Reset while Space is held cannot turn repeated key-down into a new press")
	_key(KEY_SPACE, false)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	_check(paused, "A genuine press after release works after held-key reset")
	_controller.reset()
	_focus_witness.release_focus()
	evidence.append({"case": "space_and_reset", "transitions": _pause_events.duplicate(),
		"foreign_accept": _intents["foreign_accept"], "unhandled_space": _unhandled_probe.space_events})


func _test_ui_intents_and_snapshot_copy() -> void:
	for node: Node in _hud.find_children("*", "Button", true, false):
		var button: Button = node as Button
		_check(button.focus_mode == Control.FOCUS_NONE, "Every FirstLevelHUD button has FOCUS_NONE: %s" % button.name)
	_check(_hud.flow_panel.get_global_rect() == Rect2(790, 12, 394, 206), "Flow panel keeps the agreed compact rectangle")
	_check(_hud.colony_panel.get_global_rect() == Rect2(24, 12, 750, 48), "Colony summary keeps the agreed top-left rectangle")
	_check(_hud.result_panel.get_global_rect() == Rect2(300, 290, 600, 310), "Settlement keeps the agreed centered rectangle")
	_check(_hud.is_pointer_over_panel(Vector2(802, 25))
		and _hud.is_pointer_over_panel(Vector2(40, 30))
		and not _hud.is_pointer_over_panel(Vector2(620, 380)),
		"Only visible panel rectangles claim pointer input")
	_check(_hud.colony_label.text.contains("81.5/100")
		and _hud.colony_label.text.contains("营养 37")
		and _hud.colony_label.text.contains("回收 148")
		and _hud.colony_label.text.contains("02:05"), "Colony summary renders supplied health, stock, recovered and elapsed values")
	var flow: Dictionary = _flow_snapshot()
	_hud.show_flow(flow)
	flow["can_start"] = false
	flow["next_title"] = "mutated after publication"
	_check(not _hud.start_button.disabled and _hud.next_label.text.contains("首波试探"),
		"Flow UI holds its own copied snapshot")
	_click(_hud.start_button.get_global_rect().get_center())
	_check(int(_intents["start"]) == 1 and not paused,
		"Actual start click emits one request and does not mutate simulation")
	_click(_hud.pause_button.get_global_rect().get_center())
	_check(int(_intents["pause"]) == 1 and not paused,
		"Actual pause click is a pure request, requiring the owner's controller binding")
	_controller.set_paused(true)
	await _frames(2)
	var frozen: Dictionary = _simulation_snapshot()
	_click(_hud.start_button.get_global_rect().get_center())
	_check(int(_intents["start"]) == 1, "Paused start button cannot issue a wave request")
	_click(_hud.pause_button.get_global_rect().get_center())
	_click(_hud.restart_button.get_global_rect().get_center())
	_check(int(_intents["pause"]) == 2 and int(_intents["restart"]) == 1 and paused,
		"Pause and restart buttons accept actual pointer clicks while SceneTree is paused")
	var actual: Dictionary = {"victory": true, "reached_wave": 6, "completed_waves": 6,
		"total_recovered": 173, "stage_name": "成熟", "mature_organs": 5,
		"core_health": 63.5, "elapsed_seconds": 245.9,
		"audit": {"arrival_ids": ["fixture:arrival:1"]}}
	_hud.show_result(actual)
	actual["total_recovered"] = 999
	actual["core_health"] = 0
	actual["audit"]["arrival_ids"].append("mutated:caller")
	_hud.show_colony({"core_health": 0, "core_max_health": 100, "nutrition": 0,
		"total_recovered": 999, "stage_name": "初生", "elapsed_seconds": 0})
	_hud.show_flow({"state": &"interrupted", "wave_index": 1, "completed_waves": 0,
		"wave_total": 6, "can_start": true})
	_check(_hud.result_panel.visible and _hud.result_title.text.contains("胜利"), "Settlement is shown from the captured victory flag")
	_check(_hud.result_left_label.text.contains("到达波次：6 / 6")
		and _hud.result_left_label.text.contains("完成波次：6 / 6")
		and _hud.result_left_label.text.contains("173 营养")
		and _hud.result_left_label.text.contains("成熟"), "Settlement shows actual reached/completed waves, recovered nutrition and stage")
	_check(_hud.result_right_label.text.contains("器官：5")
		and _hud.result_right_label.text.contains("生命：63.5")
		and _hud.result_right_label.text.contains("04:05"), "Settlement shows actual mature organs, core health and elapsed time")
	var copied_audit: Dictionary = _hud._result_snapshot.get("audit", {})
	_check(copied_audit["arrival_ids"].size() == 1,
		"Settlement snapshot deep-copies nested data and ignores later live/caller changes")
	_check(_hud.start_button.disabled and _hud.pause_button.disabled
		and not _hud.restart_button.disabled and not _hud.result_restart_button.disabled,
		"Settlement locks start/pause while leaving both restart buttons available")
	_check(_hud.is_pointer_over_panel(Vector2(620, 380))
		and not _hud.is_pointer_over_panel(Vector2(1000, 420)),
		"Settlement claims its centered panel without adding a full-screen overlay")
	_click(_hud.result_restart_button.get_global_rect().get_center())
	await _frames(2)
	_check(int(_intents["restart"]) == 2 and paused and _simulation_snapshot() == frozen,
		"Actual settlement restart click works while paused and HUD alone changes no simulation")
	_hud.show_result({"victory": false, "reached_wave": 3, "completed_waves": 2,
		"total_recovered": 45, "stage_name": "扩张", "mature_organs": 2,
		"core_health": 0, "elapsed_seconds": 75})
	_check(_hud.result_title.text == "本次挑战失败"
		and _hud.result_left_label.text.contains("到达波次：3 / 6")
		and _hud.result_left_label.text.contains("完成波次：2 / 6")
		and _hud.result_right_label.text.contains("生命：0"), "Defeat settlement replaces the previous result with its own captured values")
	_hud.clear_result()
	_hud.clear_result()
	_controller.reset()
	_hud.show_flow(_flow_snapshot())
	_check(not _hud.result_panel.visible and _hud._result_snapshot.is_empty()
		and _hud.result_title.text.is_empty() and _hud.result_left_label.text.is_empty(),
		"Idempotent clear removes old settlement visibility, stored data and labels")
	_check(not _hud.start_button.disabled and not _hud.pause_button.disabled
		and not _hud.is_pointer_over_panel(Vector2(620, 380)),
		"Fresh preparation restores controls and releases the old result rectangle")
	_hud.show_flow({"state": &"preparation", "wave_index": 2, "completed_waves": 2,
		"wave_total": 6, "planned": 7, "spawned": 7, "defeated": 7, "active": 0,
		"unspawned": 0, "preparation_remaining": 8.3, "can_start": true,
		"next_title": "两翼来袭", "next_direction": "左右两侧", "total_defeated": 12})
	_check(_hud.start_button.text == "开始第 3 波"
		and _hud.pause_label.text.contains("8.3 秒")
		and _hud.progress_label.text.contains("总击败 12")
		and _hud.next_label.text.contains("左右两侧"), "Wave preparation renders true countdown, next wave/direction and aggregate defeats")
	evidence.append({"case": "actual_ui_intents_and_result_copy", "intents": _intents.duplicate(),
		"result_snapshot_detached": true, "pause_planning_unobstructed": true})


func _test_exit_unpauses() -> void:
	_controller.set_paused(true)
	_check(paused, "Exit fixture begins with the actual tree paused")
	_fixture.remove_child(_controller)
	_check(not paused and not _controller.is_paused(), "Controller tree exit unpauses before any new scene starts")
	_controller.free()
	_controller = null
	await _frames(3)
	_check(_simulation.process_steps > 0, "Sibling simulation can continue after controller exit")
	evidence.append({"case": "tree_exit", "paused_after_exit": paused})


func _flow_snapshot() -> Dictionary:
	return {"state": &"initial_preparation", "wave_index": 0, "completed_waves": 0,
		"wave_total": 6, "planned": 0, "spawned": 0, "defeated": 0, "active": 0,
		"unspawned": 0, "preparation_remaining": 0.0, "can_start": true,
		"next_title": "首波试探", "next_direction": "左侧", "total_defeated": 0}


func _simulation_snapshot() -> Dictionary:
	return {"process": _simulation.process_steps, "physics": _simulation.physics_steps,
		"ticks": _simulation.timer_ticks, "time_left": _simulation.timer.time_left,
		"tween": _simulation.tween_value}


func _key(code: Key, pressed_value: bool, echo_value: bool = false) -> bool:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed_value
	event.echo = echo_value
	root.push_input(event, true)
	return root.is_input_handled()


func _click(point: Vector2) -> void:
	for pressed_value: bool in [true, false]:
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed_value else 0
		event.position = point
		event.global_position = point
		event.pressed = pressed_value
		root.push_input(event, true)


func _frames(count: int) -> void:
	for _frame: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)
