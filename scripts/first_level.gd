class_name FirstLevel
extends "res://scripts/colony_operations_demo.gd"
## 第一关只接线：六波、观察界面与生命周期复用现有的资源和组织系统。

signal level_finished(snapshot: Dictionary)

const DEVELOPMENT_SCENES: Dictionary = {
	&"original_carcass_demo": "res://scenes/levels/large_carcass_demo.tscn",
	&"traffic_recovery_demo": "res://scenes/levels/traffic_recovery_demo.tscn",
	&"progression_demo": "res://scenes/levels/progression_demo.tscn",
	&"combat_specialization_demo": "res://scenes/levels/combat_specialization_demo.tscn",
	&"terrain_threat_demo": "res://scenes/levels/terrain_threat_demo.tscn",
	&"colony_operations_demo": "res://scenes/levels/colony_operations_demo.tscn",
}

@onready var wave_flow: FirstLevelFlow = $FirstLevelFlow
@onready var pause_controller: GlobalPauseController = $GlobalPauseController
@onready var flow_hud: FirstLevelHUD = $FirstLevelHUD

var first_guide: FirstEventGuide
var compact_hud: CompactColonyHUD
var elapsed_seconds: float = 0.0
var _result_snapshot: Dictionary = {}
var _pending_victory: Dictionary = {}
var _failure_pending: bool = false
var _restart_pending: bool = false
var _formal_ready: bool = false
var _last_flow: Dictionary = {}
var _last_colony_ui: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$World.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Systems.process_mode = Node.PROCESS_MODE_PAUSABLE
	hud.process_mode = Node.PROCESS_MODE_ALWAYS
	enemy_spawner.auto_start = false
	pause_controller.reset()
	super._ready()
	# 开发演示仍保留自己的接口，正式局仅由六波模块驱动生成器。
	_disconnect_demo_signals()
	combat_hint_controller.set_enabled(false)
	hud.set_combat_demo_enabled(false)
	hud.show_progression_hint({})
	frontier_status.compact_labels = true
	frontier_status.exposure_label_position = Vector2(424, 637)
	first_guide = FirstEventGuide.new()
	first_guide.name = "FirstEventGuide"
	hud.add_child(first_guide)
	first_guide.position = Vector2(24, 178)
	first_guide.size = Vector2(750, 60)
	_connect_first_events()
	wave_flow.changed.connect(_on_flow_changed)
	wave_flow.victory_candidate.connect(_on_victory_candidate)
	wave_flow.interrupted.connect(_on_flow_interrupted)
	flow_hud.start_requested.connect(start_next_wave)
	flow_hud.pause_requested.connect(pause_controller.toggle_pause)
	flow_hud.restart_requested.connect(restart_level)
	flow_hud.continue_requested.connect(_open_second_level)
	pause_controller.pause_changed.connect(_on_global_pause_changed)
	wave_flow.configure(enemy_spawner)
	_formal_ready = true
	_layout_formal_hud()
	_refresh_formal_hud()
	hud.show_notice("第一关：可先用 G 接通左前方80尸骸，再点击开始第一波。Space随时暂停规划。")


func _process(delta: float) -> void:
	if not _formal_ready or _restart_pending:
		return
	if _result_snapshot.is_empty() and not _failure_pending and not get_tree().paused:
		elapsed_seconds += maxf(delta, 0.0)
		super._process(delta)
	elif _result_snapshot.is_empty():
		# 暂停只刷新观察信息，不执行父关卡的调度与菌域同步。
		_refresh_operations_status()
		_operation_view.queue_redraw()
	_refresh_formal_hud()


func _input(event: InputEvent) -> void:
	if not _formal_ready or _restart_pending:
		return
	if event is InputEventKey and event.keycode == KEY_SPACE:
		# 子控制器在 GUI 之前处理 Space；父关卡绝不将其交给 ui_accept。
		return
	if event.is_action_pressed("restart_level") and not event.is_echo():
		get_viewport().set_input_as_handled()
		restart_level()
		return
	if not _result_snapshot.is_empty() or _failure_pending:
		return
	if event is InputEventKey and not event.is_echo():
		for action: StringName in DEVELOPMENT_SCENES:
			if event.is_action_pressed(action):
				get_viewport().set_input_as_handled()
				open_development_demo(action)
				return
		if event.is_pressed() and event.keycode == KEY_ESCAPE:
			compact_hud.close_drawer()
	if event is InputEventMouse and compact_hud.is_pointer_over_ui(event.position):
		return
	if event is InputEventMouse and flow_hud.is_pointer_over_panel(event.position):
		return
	if event is InputEventMouse and first_guide.is_visible_in_tree() \
			and first_guide.get_global_rect().has_point(event.position):
		return
	# 正式关卡不暴露旧调试伤害/库存快捷键。
	if event.is_action_pressed("debug_damage_core") or event.is_action_pressed("debug_consume_nutrition"):
		get_viewport().set_input_as_handled()
		return
	if get_tree().paused and event.is_action_pressed("request_supply"):
		get_viewport().set_input_as_handled()
		return
	super._input(event)


func _unhandled_input(event: InputEvent) -> void:
	if not _formal_ready or _restart_pending or not _result_snapshot.is_empty() or _failure_pending:
		return
	if event is InputEventMouse and (compact_hud.is_pointer_over_ui(event.position) \
			or flow_hud.is_pointer_over_panel(event.position) \
			or (first_guide.is_visible_in_tree() and first_guide.get_global_rect().has_point(event.position))):
		return
	if get_tree().paused and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and not repair_input_controller.is_selecting():
		var point: Vector2 = get_canvas_transform().affine_inverse() * event.position
		if growth_input_controller.placement_bounds.has_point(point):
			_select_node(_node_near(point))
			get_viewport().set_input_as_handled()
			return
	super._unhandled_input(event)


func start_next_wave() -> bool:
	if not _formal_ready or get_tree().paused or _restart_pending or _failure_pending \
			or not _result_snapshot.is_empty():
		return false
	return wave_flow.begin_next_wave()


func restart_level() -> void:
	if _restart_pending:
		return
	_restart_pending = true
	_pending_victory.clear()
	wave_flow.stop(&"restart")
	pause_controller.reset()
	super.restart_level()


func get_level_snapshot() -> Dictionary:
	return {"flow": wave_flow.get_snapshot(), "paused": pause_controller.is_paused(),
		"elapsed_seconds": elapsed_seconds, "result": _result_snapshot.duplicate(true),
		"colony": _colony_snapshot(), "guide": first_guide.get_snapshot() if is_instance_valid(first_guide) else {}}


func get_result_snapshot() -> Dictionary:
	return _result_snapshot.duplicate(true)


func _on_flow_changed(snapshot: Dictionary) -> void:
	_last_flow = snapshot.duplicate(true)
	flow_hud.show_flow(snapshot)


func _on_flow_interrupted(_reason: StringName) -> void:
	if not _restart_pending and _result_snapshot.is_empty() and not _failure_pending:
		hud.show_notice("本局出怪已中断，不能计为清波；请重新开始。")


func _on_victory_candidate(evidence: Dictionary) -> void:
	if _restart_pending or not _result_snapshot.is_empty():
		return
	_pending_victory = evidence.duplicate(true)
	_resolve_result.call_deferred()


func _on_mother_core_depleted() -> void:
	if _restart_pending or not _result_snapshot.is_empty():
		return
	_failure_pending = true
	pause_controller.set_paused(true)
	pause_controller.set_terminal(true)
	# 等当前死亡信号栈结束，再读取真实快照；同帧失败覆盖胜利候选。
	_resolve_result.call_deferred()


func _resolve_result() -> void:
	if _restart_pending or not _result_snapshot.is_empty() or not is_inside_tree():
		return
	var failed: bool = _failure_pending or mother_core.health <= 0
	var flow: Dictionary = wave_flow.get_snapshot()
	var batch: Dictionary = enemy_spawner.get_batch_snapshot()
	var won: bool = not _pending_victory.is_empty() and not failed \
		and int(flow.get("completed_waves", 0)) == 6 and int(flow.get("total_defeated", 0)) == 66 \
		and String(batch.get("state")) == "completed" and int(batch.get("removed", -1)) == 0 \
		and int(batch.get("spawned", -1)) == int(batch.get("planned", 0)) \
		and int(batch.get("defeated", -1)) == int(batch.get("planned", 0)) \
		and int(batch.get("active", -1)) == 0
	if not failed and not won:
		return
	# 先拍照，之后的停派、退款、清理不能改写这份结算。
	_result_snapshot = {"victory": won, "reached_wave": int(flow.get("wave_index", 0)),
		"completed_waves": int(flow.get("completed_waves", 0)),
		"total_recovered": colony_progress.get_total_recovered(), "stage_name": colony_progress.get_stage_name(),
		"mature_organs": _count_mature_organs(), "core_health": mother_core.health,
		"elapsed_seconds": elapsed_seconds, "total_defeated": int(flow.get("total_defeated", 0)),
		"resources": get_combat_resource_snapshot().duplicate(true), "flow": flow.duplicate(true)}
	_pending_victory.clear()
	wave_flow.stop(&"victory" if won else &"defeat")
	pause_controller.set_terminal(true)
	pause_controller.set_paused(true)
	_announce_level_stopping(&"victory" if won else &"core_depleted")
	stop_demo()
	_is_tearing_down = true
	$World.process_mode = Node.PROCESS_MODE_DISABLED
	$Systems.process_mode = Node.PROCESS_MODE_DISABLED
	for control: Node in hud.find_children("*", "BaseButton", true, false):
		(control as BaseButton).disabled = true
	flow_hud.show_result(_result_snapshot)
	if won:
		flow_hud.show_continue("进入第二关")
	level_finished.emit(_result_snapshot.duplicate(true))


func _open_second_level() -> void:
	if _restart_pending or not bool(_result_snapshot.get("victory", false)):
		return
	_restart_pending = true
	pause_controller.reset()
	get_tree().change_scene_to_file("res://scenes/levels/second_level.tscn")


func _count_mature_organs() -> int:
	var count: int = 0
	for node: Node in $World.find_children("*", "", true, false):
		if (node is AttackOrgan or node is DigestiveOrgan) and not node.is_queued_for_deletion() \
				and float(node.get("health")) > 0.0:
			count += 1
	return count


func _colony_snapshot() -> Dictionary:
	return {"core_health": mother_core.health, "core_max_health": mother_core.max_health,
		"nutrition": mother_core.nutrition, "total_recovered": colony_progress.get_total_recovered(),
		"stage_name": colony_progress.get_stage_name(), "elapsed_seconds": elapsed_seconds}


func _refresh_formal_hud() -> void:
	var colony: Dictionary = _colony_snapshot()
	# 计时按秒显示，避免无关的 UI 重排。
	colony["elapsed_seconds"] = floorf(elapsed_seconds)
	if colony != _last_colony_ui:
		_last_colony_ui = colony
		flow_hud.show_colony(colony)
	if _result_snapshot.is_empty():
		var flow: Dictionary = wave_flow.get_snapshot()
		flow["preparation_remaining"] = ceilf(float(flow.get("preparation_remaining", 0.0)))
		if flow != _last_flow:
			_last_flow = flow.duplicate(true)
			flow_hud.show_flow(flow)
		if not is_instance_valid(differentiation_input_controller.get_selected_organ()) \
				and not differentiation_system.has_active_task():
			differentiation_input_controller.hide()
		if get_tree().paused:
			frontier_status.queue_redraw()
	if is_instance_valid(compact_hud):
		compact_hud.refresh()


func _on_global_pause_changed(paused: bool) -> void:
	flow_hud.show_pause(paused)
	if _formal_ready and _result_snapshot.is_empty():
		hud.show_notice("全局暂停：可选择、G/B/L/T/M预览；恢复后再确认，P/K仍分别控制单任务。" if paused else "已继续；保留的规划需再次点击确认，费用和可达性会重新检查。")


func _connect_first_events() -> void:
	construction_coordinator.changed.connect(_on_guide_construction)
	recycling_system.recycling_changed.connect(_on_guide_recycling)
	colony_progress.progress_changed.connect(_on_guide_recovered)
	colony_progress.stage_changed.connect(_on_guide_stage)
	differentiation_system.organ_differentiated.connect(_on_guide_differentiated)
	tissue_lifecycle.tissue_lost.connect(_on_guide_tissue_lost)


func _on_guide_construction(snapshot: Dictionary) -> void:
	if _restart_pending or not _result_snapshot.is_empty():
		return
	for entry: Dictionary in snapshot.get("entries", []):
		if entry.get("kind") in [&"growth", &"remote_cultivation"]:
			first_guide.record_event(&"target_placed", {"construction_id": entry.get("construction_id")})


func _on_guide_recycling(_in_transit: int, delivered: int, _interrupted: int) -> void:
	if delivered > 0 and not _restart_pending and _result_snapshot.is_empty():
		first_guide.record_event(&"remains_returned", {"delivered": delivered})


func _on_guide_recovered(total: int, _products: int) -> void:
	if total > 0 and not _restart_pending and _result_snapshot.is_empty():
		first_guide.record_event(&"nutrition_returned", {"total": total})


func _on_guide_stage(_previous: ColonyProgress.Stage, current: ColonyProgress.Stage) -> void:
	if current > ColonyProgress.Stage.NASCENT and not _restart_pending and _result_snapshot.is_empty():
		first_guide.record_event(&"stage_unlocked", {"stage": colony_progress.get_stage_name()})


func _on_guide_differentiated(_id: int, _organ: AttackOrgan, _direction: int) -> void:
	if not _restart_pending and _result_snapshot.is_empty():
		first_guide.record_event(&"differentiated")


func _on_guide_tissue_lost(_id: int, kind: StringName, _point: Vector2) -> void:
	if kind in [&"菌结", &"菌丝"] and not _restart_pending and _result_snapshot.is_empty():
		first_guide.record_event(&"network_broken")


func _connect_progression_hints() -> void:
	pass


func _on_wave_finished() -> void:
	pass


func _add_frontier_batch_button() -> void:
	pass


func select_test_batch(_kind: StringName) -> bool:
	return false


func start_test_batch() -> String:
	return ""


func _read_resource_snapshot(resource_offset: int) -> Dictionary:
	var snapshot: Dictionary = super._read_resource_snapshot(resource_offset)
	var marker: Node2D = get_node("World/FirstResourceGuide" if resource_offset == 0 else "World/SecondResourceGuide")
	snapshot["recommended_target"] = marker.global_position
	return snapshot


func _refresh_resource_guides() -> void:
	var origins: Array[Node2D] = [$World/Colony/Nodes/HyphaNode, $World/Colony/Nodes/RightNode]
	for index: int in range(2):
		var marker: Node2D = get_node("World/FirstResourceGuide" if index == 0 else "World/SecondResourceGuide")
		var plan: Dictionary = growth_system.preview_target(origins[index], marker.global_position)
		var label: Label = marker.get_node("Hint")
		label.text = "%s｜G接通约%d营养\n每批10回运，绿色产物到母核才入账" % [
			"左前尸骸80 · 先发展" if index == 0 else "右前尸骸120 · 注意侧翼", int(plan.get("total_cost", 0))]


func _layout_formal_hud() -> void:
	compact_hud = CompactColonyHUD.new()
	compact_hud.name = "CompactHUD"
	add_child(compact_hud)
	compact_hud.configure(self)


func open_development_demo(action: StringName) -> void:
	if _restart_pending or not DEVELOPMENT_SCENES.has(action):
		return
	_restart_pending = true
	wave_flow.stop(&"scene_change")
	pause_controller.reset()
	_announce_level_stopping(&"scene_change")
	get_tree().change_scene_to_file(String(DEVELOPMENT_SCENES[action]))


func _reload_operations() -> void:
	open_development_demo(&"colony_operations_demo")
