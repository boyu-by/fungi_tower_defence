class_name ColonyLevelRuntime
extends "res://scripts/gameplay/colony_operations_runtime.gd"
## 正式关卡基础：地图由子场景提供，目标与波次由独立节点提供。

@export var enable_colony_operations: bool = true

signal level_finished(snapshot: Dictionary)

var combat_resource_ledger: CombatResourceLedger
var pause_controller: GlobalPauseController
var elapsed_seconds: float = 0.0
var _result_snapshot: Dictionary = {}
var _pending_objective: Dictionary = {}
var _completion_pending: bool = false
var _failure_pending: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$World.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Systems.process_mode = Node.PROCESS_MODE_PAUSABLE
	hud.process_mode = Node.PROCESS_MODE_ALWAYS
	pause_controller = GlobalPauseController.new()
	pause_controller.name = "GlobalPauseController"
	add_child(pause_controller)
	_prepare_terrain_runtime()
	if enable_colony_operations:
		_prepare_colony_operations()
	super._ready()
	_connect_terrain_runtime()
	if enable_colony_operations:
		_connect_colony_operations()
	combat_resource_ledger = CombatResourceLedger.new()
	combat_resource_ledger.name = "CombatResourceLedger"
	$Systems.add_child(combat_resource_ledger)
	combat_resource_ledger.configure(self)
	level_stopping.connect(_on_runtime_stopping)
	hud.set_combat_demo_enabled(false)
	hud.show_progression_hint({})
	hud.show_combat_hint({"enabled": false, "visible": false})
	(hud.get_node("HelpLabel") as Label).text = "G 伸展 · B 种芽 · C 培育 · O 切换器官 · T 改向 · M 移植 · L 连接 · P 暂停建设 · X 取消 · R 重开"

func _process(delta: float) -> void:
	if not _result_snapshot.is_empty():
		return
	if get_tree().paused:
		_refresh_operations_status()
		return
	elapsed_seconds += maxf(delta, 0.0)
	super._process(delta)
	_process_colony_operations()

func _input(event: InputEvent) -> void:
	if _result_snapshot.is_empty():
		super._input(event)

func _unhandled_input(event: InputEvent) -> void:
	if _result_snapshot.is_empty() or event.is_action_pressed("restart_level"):
		super._unhandled_input(event)

## Objective controllers propose completion; core death always wins the decision.
func finish_level(victory: bool, objective: Dictionary = {}) -> bool:
	if not _result_snapshot.is_empty():
		return false
	if not victory or mother_core.health <= 0:
		_failure_pending = true
	if _completion_pending:
		return false
	_completion_pending = true
	_pending_objective = objective.duplicate(true)
	_resolve_level_result.call_deferred()
	return true

func _resolve_level_result() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not _result_snapshot.is_empty():
		return
	var won: bool = not _failure_pending and mother_core.health > 0
	_result_snapshot = {"victory": won, "core_health": mother_core.health,
		"elapsed_seconds": elapsed_seconds, "objective": _pending_objective.duplicate(true),
		"total_recovered": colony_progress.get_total_recovered(),
		"resources": get_combat_resource_snapshot().duplicate(true)}
	_announce_level_stopping(&"victory" if won else &"core_depleted")
	_is_tearing_down = true
	pause_controller.set_terminal(true)
	pause_controller.set_paused(true)
	$World.process_mode = Node.PROCESS_MODE_DISABLED
	$Systems.process_mode = Node.PROCESS_MODE_DISABLED
	for control: Node in hud.find_children("*", "BaseButton", true, false):
		(control as BaseButton).disabled = true
	hud.show_battle_result(won)
	level_finished.emit(_result_snapshot.duplicate(true))

func get_result_snapshot() -> Dictionary:
	return _result_snapshot.duplicate(true)

func _on_mother_core_depleted() -> void:
	finish_level(false)

func get_combat_resource_snapshot() -> Dictionary:
	return combat_resource_ledger.get_snapshot() if is_instance_valid(combat_resource_ledger) else {}

func _on_runtime_stopping(_reason: StringName) -> void:
	_close_operations(_reason)
	if is_instance_valid(combat_resource_ledger):
		combat_resource_ledger.stop()
