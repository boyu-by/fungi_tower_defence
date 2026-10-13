extends SceneTree
## 只读图形实玩记录器：没有输入、资源、伤害、成长或计时修改。
const LEVEL: PackedScene = preload("res://scenes/levels/first_level.tscn")
class InputObserver:
	extends Node
	var events: Array[Dictionary] = []
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseButton or (event is InputEventKey and event.pressed and not event.echo):
			events.append({"text": event.as_text(), "point": event.position if event is InputEventMouse else Vector2.ZERO, "time_ms": Time.get_ticks_msec()})
			if events.size() > 20:
				events.pop_front()
var _input_observer: InputObserver
var _last_ms: int = -1000
var _log: FileAccess
var _last_instance: int = 0
var _errors: int = 0
var _samples: int = 0

func _initialize() -> void:
	_launch.call_deferred()

func _launch() -> void:
	DirAccess.make_dir_recursive_absolute("/tmp/fungi_stage11")
	_log = FileAccess.open("/tmp/fungi_stage11/live.jsonl", FileAccess.WRITE)
	var level: FirstLevel = LEVEL.instantiate() as FirstLevel
	root.add_child(level)
	current_scene = level
	_input_observer = InputObserver.new()
	_input_observer.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(_input_observer)
	process_frame.connect(_observe)

func _observe() -> void:
	if Time.get_ticks_msec() - _last_ms < 500 or not current_scene is FirstLevel:
		return
	_last_ms = Time.get_ticks_msec()
	var level: FirstLevel = current_scene as FirstLevel
	if not level.is_node_ready():
		return
	var snapshot: Dictionary = level.get_level_snapshot()
	var ledger: Dictionary = level.get_combat_resource_snapshot()
	if not snapshot.result.is_empty():
		ledger = snapshot.result.resources
	if bool(ledger.get("valid", false)) and not bool(ledger.get("balanced", true)):
		_errors += 1
	_samples += 1
	snapshot["display"] = {"size": level.get_window().size, "position": level.get_window().position, "content_scale_size": level.get_window().content_scale_size, "visible": level.get_window().visible, "mode": level.get_window().mode}
	snapshot["input_events"] = _input_observer.events.duplicate(true)
	snapshot["instance_id"] = level.get_instance_id()
	snapshot["wall_ms"] = Time.get_ticks_msec()
	snapshot["ledger"] = ledger
	snapshot["samples"] = _samples
	snapshot["unbalanced_samples"] = _errors
	snapshot["frontier"] = {"attacks": level.tissue_attack_count, "breaks": level.network_break_count}
	snapshot["construction"] = level.construction_coordinator.get_snapshot()
	snapshot["enemies"] = []
	for enemy: Node in level.get_node("World/Enemies").get_children():
		if enemy is BasicEnemy:
			snapshot.enemies.append({"position": enemy.global_position, "health": enemy.health, "type": enemy.get_archetype()})
	snapshot["organs"] = []
	for weapon: SporeWeapon in level.get_weapons():
		var organ: AttackOrgan = weapon.inventory_owner
		snapshot.organs.append({"position": organ.global_position, "health": organ.health, "nutrition": organ.nutrition,
			"firing": weapon.get_firing_state(), "range": weapon.attack_range, "working": organ.is_functional(), "differentiation": organ.get_differentiation_snapshot()})
	var text: String = JSON.stringify(snapshot)
	_log.store_line(text)
	_log.flush()
	var latest: FileAccess = FileAccess.open("/tmp/fungi_stage11/live_latest.json", FileAccess.WRITE)
	latest.store_string(text)
	if not snapshot.result.is_empty():
		var result: FileAccess = FileAccess.open("/tmp/fungi_stage11/live_result_%d.json" % level.get_instance_id(), FileAccess.WRITE)
		result.store_string(text)
	if _last_instance != level.get_instance_id():
		_last_instance = level.get_instance_id()
		print("LIVE_NEW_GAME ", _last_instance)
