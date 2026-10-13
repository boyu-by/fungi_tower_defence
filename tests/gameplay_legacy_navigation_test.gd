extends SceneTree
## Exercise the unchanged application entry, development shortcuts and R reload.

const ENTRY := "res://scenes/levels/first_level.tscn"
const SHORTCUTS := {
	"original_carcass_demo": "large_carcass_demo",
	"traffic_recovery_demo": "traffic_recovery_demo",
	"progression_demo": "progression_demo",
	"combat_specialization_demo": "combat_specialization_demo",
	"terrain_threat_demo": "terrain_threat_demo",
	"colony_operations_demo": "colony_operations_demo",
}

var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)

func _step(frames: int) -> void:
	for _frame: int in range(frames):
		await process_frame
		await physics_frame

func _run() -> void:
	_check(String(ProjectSettings.get_setting("application/run/main_scene")) == ENTRY, "Application entry stays unchanged")
	change_scene_to_file(ENTRY)
	await _step(3)
	_check(current_scene is FirstLevel, "Current test entry still runs FirstLevel")
	_check(current_scene.mother_core.nutrition == 72 and current_scene.mother_core.health == 240, "Test entry retains initial resources")
	for action: String in SHORTCUTS:
		var event := InputEventAction.new()
		event.action = action
		event.pressed = true
		current_scene._unhandled_input(event)
		await _step(3)
		_check(current_scene.scene_file_path == "res://scenes/levels/%s.tscn" % SHORTCUTS[action], action + " navigates to original scene")
		_check(not paused, action + " starts unpaused")
	var old_id := current_scene.get_instance_id()
	current_scene.mother_core.take_damage(30)
	var restart := InputEventAction.new()
	restart.action = &"restart_level"
	restart.pressed = true
	current_scene._unhandled_input(restart)
	await _step(3)
	_check(current_scene.get_instance_id() != old_id, "R creates a new scene instance")
	_check(current_scene.mother_core.health == 240 and current_scene.mother_core.nutrition == 72, "R restores original state")
	change_scene_to_file(ENTRY)
	await _step(3)
	current_scene.pause_controller.set_paused(true)
	restart = InputEventAction.new()
	restart.action = &"restart_level"
	restart.pressed = true
	current_scene._input(restart)
	await _step(3)
	_check(current_scene is FirstLevel and not paused, "Paused test entry still restarts")
	_check(current_scene.get_level_snapshot().flow.state == "initial_preparation", "Restart retains manual first-wave preparation")
	print("GAMEPLAY_LEGACY_NAVIGATION_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
