class_name SecondLevel
extends "res://scripts/gameplay/colony_level_runtime.gd"
## 第二关只接线：独立地图、AI目标与生产，其他玩法继续由共用系统拥有。

@onready var wave_flow: AIProductionController = $AIProductionController
@onready var flow_hud: SecondLevelHUD = $FirstLevelHUD

var first_guide: SecondLevelGuide
var compact_hud: CompactColonyHUD
var _second_ready: bool = false
var _restart_pending: bool = false
var _old_content_size: Vector2i
var _attack_preview: Dictionary = {}
var _objective_overlay: Node2D
var _preview_font: SystemFont


func _ready() -> void:
	_old_content_size = get_window().content_scale_size
	get_window().content_scale_size = Vector2i(1200, 920)
	get_window().size = Vector2i(1200, 920)
	growth_planner = growth_planner.duplicate(true) as GrowthPlanner
	growth_planner.bounded_branches_enabled = true
	growth_planner.auto_join_enabled = true
	super._ready()
	frontier_status.compact_labels = true
	first_guide = SecondLevelGuide.new()
	first_guide.name = "SecondLevelGuide"
	hud.add_child(first_guide)
	for facility: AIFacility in get_facility_targets():
		facility.priority_requested.connect(prioritize_facility)
		facility.facility_destroyed.connect(_on_facility_destroyed)
	wave_flow.changed.connect(flow_hud.show_flow)
	wave_flow.objective_completed.connect(_on_objective_completed)
	wave_flow.enemy_created.connect(_on_enemy_created)
	flow_hud.start_requested.connect(start_next_wave)
	flow_hud.pause_requested.connect(pause_controller.toggle_pause)
	flow_hud.restart_requested.connect(restart_level)
	flow_hud.continue_requested.connect(_open_third_level)
	pause_controller.pause_changed.connect(flow_hud.show_pause)
	level_stopping.connect(wave_flow.stop)
	level_finished.connect(_on_second_finished)
	recycling_system.recycling_changed.connect(_on_second_recycling)
	colony_progress.progress_changed.connect(_on_second_recovery)
	cultivation_input_controller.remote_preview_changed.connect(_on_attack_preview)
	cultivation_input_controller.remote_mode_changed.connect(func(placing: bool) -> void:
		if not placing: _attack_preview.clear())
	wave_flow.configure(self, get_facility_targets())
	_objective_overlay = Node2D.new()
	_objective_overlay.name = "FacilityRangePreview"
	_objective_overlay.z_index = 30
	$World.add_child(_objective_overlay)
	_objective_overlay.draw.connect(_draw_attack_preview)
	_preview_font = SystemFont.new()
	_preview_font.font_names = PackedStringArray(["Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC"])
	compact_hud = CompactColonyHUD.new()
	compact_hud.name = "CompactHUD"
	add_child(compact_hud)
	compact_hud.configure(self)
	LevelStoryCaption.attach(self, 2)
	_second_ready = true
	_refresh_second_hud()
	hud.show_notice("第二关：%d秒后AI开始生产。接通两侧尸骸，培育前沿火力；点击AI可设为优先目标。" % ceili(wave_flow.profile.preparation_seconds))


func _process(delta: float) -> void:
	if _restart_pending:
		return
	super._process(delta)
	if _second_ready:
		_refresh_second_hud()
		_objective_overlay.queue_redraw()


func _input(event: InputEvent) -> void:
	if not _second_ready or _restart_pending:
		return
	if is_instance_valid(compact_hud) and compact_hud.level_menu.is_open():
		return
	if event is InputEventKey and event.keycode == KEY_SPACE:
		return
	if event.is_action_pressed("restart_level") and not event.is_echo():
		get_viewport().set_input_as_handled()
		restart_level()
		return
	if not get_result_snapshot().is_empty():
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		compact_hud.close_drawer()
	if event is InputEventMouse and (compact_hud.is_pointer_over_ui(event.position) \
			or flow_hud.is_pointer_over_panel(event.position)):
		return
	if event.is_action_pressed("debug_damage_core") or event.is_action_pressed("debug_consume_nutrition"):
		get_viewport().set_input_as_handled()
		return
	super._input(event)


func _unhandled_input(event: InputEvent) -> void:
	if not _second_ready or _restart_pending:
		return
	if is_instance_valid(compact_hud) and compact_hud.level_menu.is_open():
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouse and (compact_hud.is_pointer_over_ui(event.position) \
			or flow_hud.is_pointer_over_panel(event.position)):
		return
	if get_tree().paused and event.is_action_pressed("request_supply"):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed \
			and not growth_input_controller.is_placing() and not cultivation_input_controller.is_remote_placing() \
			and not connection_input_controller.is_placing() and _operation_mode == &"":
		var point: Vector2 = get_canvas_transform().affine_inverse() * event.position
		for facility: AIFacility in get_facility_targets():
			if Rect2(facility.global_position - Vector2(40, 80), Vector2(80, 90)).has_point(point):
				prioritize_facility(facility.facility_id)
				get_viewport().set_input_as_handled()
				return
	super._unhandled_input(event)


func _exit_tree() -> void:
	super._exit_tree()
	get_window().content_scale_size = _old_content_size


func start_next_wave() -> bool:
	# 工具坞共用“开始”意图，第二关仅允许提前结束初始准备。
	return wave_flow.begin_attack() if _second_ready and not get_tree().paused and not _restart_pending else false


func restart_level() -> void:
	if _restart_pending:
		return
	_restart_pending = true
	pause_controller.reset()
	super.restart_level()


func get_facility_targets() -> Array[AIFacility]:
	var facilities: Array[AIFacility] = []
	for path: String in ["LeftAI", "CenterAI", "RightAI"]:
		var facility := get_node_or_null("World/Enemies/" + path) as AIFacility
		if is_instance_valid(facility):
			facilities.append(facility)
	return facilities


func prioritize_facility(id: StringName) -> void:
	if not get_result_snapshot().is_empty():
		return
	var chosen: AIFacility
	for facility: AIFacility in get_facility_targets():
		if facility.facility_id == id and facility.is_alive():
			chosen = facility
	if chosen == null:
		return
	if combat_targeting_system.get_priority_target() == chosen:
		clear_facility_priority()
		return
	combat_targeting_system.set_priority_target(chosen)
	for facility: AIFacility in get_facility_targets():
		facility.prioritized = facility == chosen
		facility._refresh_view()
	hud.show_notice("优先攻击%s：需要正常攻击器官在射程内。再次点击可取消优先，恢复自动选敌。" % chosen.display_name)


func clear_facility_priority() -> void:
	if not get_result_snapshot().is_empty():
		return
	combat_targeting_system.set_priority_target(null)
	for facility: AIFacility in get_facility_targets():
		facility.prioritized = false
		facility._refresh_view()
	hud.show_notice("已恢复自动选敌：先应对射程内的敌人，空闲时攻击AI设施。")


func get_objective_caption() -> String:
	return "摧毁 AI %d/3" % wave_flow.destroyed_ids.size()


func get_level_snapshot() -> Dictionary:
	return {"production": wave_flow.get_snapshot(), "result": get_result_snapshot(),
		"paused": pause_controller.is_paused(), "elapsed_seconds": elapsed_seconds}


func _on_objective_completed(evidence: Dictionary) -> void:
	finish_level(true, evidence)


func _on_mother_core_depleted() -> void:
	finish_level(false, {"level_id": "second_level", "completed": wave_flow.destroyed_ids.size(),
		"total": 3, "destroyed_ids": wave_flow.destroyed_ids.duplicate()})


func _on_second_finished(snapshot: Dictionary) -> void:
	flow_hud.show_result(snapshot)
	if bool(snapshot.get("victory", false)):
		flow_hud.show_continue("进入第三关")
	compact_hud.refresh()


func _open_third_level() -> void:
	if _restart_pending or not bool(get_result_snapshot().get("victory", false)):
		return
	_restart_pending = true
	pause_controller.reset()
	var player := StoryPlayer.open(self, 3)
	player.finished.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/levels/third_level.tscn"))


func _on_facility_destroyed(_id: StringName) -> void:
	first_guide.record_event(&"facility_destroyed")
	hud.show_notice("AI设施已摧毁，永久停止该来源生产；已出生敌人仍需防守。")


func _on_enemy_created(enemy: BasicEnemy) -> void:
	var events: Dictionary = {BasicEnemy.Archetype.SWARM: &"swarm", BasicEnemy.Archetype.ARMORED: &"armored",
		BasicEnemy.Archetype.SILK_GNAWER: &"silk_gnawer", BasicEnemy.Archetype.JUNCTION_GNAWER: &"junction_gnawer"}
	if events.has(enemy.archetype):
		first_guide.record_event(events[enemy.archetype])


func _on_second_recycling(_in_transit: int, delivered: int, _interrupted: int) -> void:
	if delivered > 0: first_guide.record_event(&"remains_returned")


func _on_second_recovery(total: int, _products: int) -> void:
	if total > 0: first_guide.record_event(&"nutrition_returned")


func _refresh_second_hud() -> void:
	flow_hud.show_colony({"core_health": mother_core.health, "core_max_health": mother_core.max_health,
		"nutrition": mother_core.nutrition, "total_recovered": colony_progress.get_total_recovered(),
		"stage_name": colony_progress.get_stage_name(), "elapsed_seconds": floorf(elapsed_seconds)})
	flow_hud.show_flow(wave_flow.get_snapshot())
	compact_hud.refresh()


func get_attack_preview(point: Vector2) -> Dictionary:
	var covered: PackedStringArray = []
	for facility: AIFacility in get_facility_targets():
		if facility.is_alive() and point.distance_to(facility.global_position) <= normal_weapon_profile.attack_range:
			covered.append(facility.display_name)
	return {"point": point, "range": normal_weapon_profile.attack_range, "covered": covered}


func _on_attack_preview(preview: Dictionary) -> void:
	_attack_preview = get_attack_preview(preview.get("target_position", Vector2.ZERO)) \
		if cultivation_input_controller.selected_organ_kind == &"attack" else {}


func _draw_attack_preview() -> void:
	if _attack_preview.is_empty():
		return
	var point: Vector2 = _attack_preview.point
	var covered: PackedStringArray = _attack_preview.covered
	var color := Color("b9dd93") if not covered.is_empty() else Color("edb272")
	_objective_overlay.draw_arc(point, float(_attack_preview.range), 0, TAU, 60, color, 1.5, true)
	_objective_overlay.draw_string(_preview_font, point + Vector2(-95, 35),
		"可覆盖：" + "、".join(covered) if not covered.is_empty() else "此处攻击器官无法覆盖AI", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)
