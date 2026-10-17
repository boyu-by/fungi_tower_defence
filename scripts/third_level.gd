class_name ThirdLevel
extends "res://scripts/gameplay/colony_level_runtime.gd"
## 第三关只接线地图、碎片与持续出怪；资源和建设由共用运行层管理。

@onready var wave_flow: ExplorationProductionController = $ExplorationProductionController
@onready var fragment_collection: FragmentCollectionController = $FragmentCollectionController
@onready var flow_hud: ThirdLevelHUD = $FirstLevelHUD

var first_guide: ThirdLevelGuide
var compact_hud: CompactColonyHUD
var _third_ready: bool = false
var _restart_pending: bool = false
var _old_content_size: Vector2i
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
	first_guide = ThirdLevelGuide.new()
	first_guide.name = "ThirdLevelGuide"
	hud.add_child(first_guide)
	wave_flow.changed.connect(flow_hud.show_flow)
	wave_flow.enemy_created.connect(_on_enemy_created)
	fragment_collection.changed.connect(flow_hud.show_objectives)
	fragment_collection.fragment_collected.connect(wave_flow.on_fragment_collected)
	fragment_collection.fragment_collected.connect(_on_fragment_collected)
	fragment_collection.objective_completed.connect(_on_objective_completed)
	flow_hud.start_requested.connect(start_next_wave)
	flow_hud.pause_requested.connect(pause_controller.toggle_pause)
	flow_hud.restart_requested.connect(restart_level)
	pause_controller.pause_changed.connect(flow_hud.show_pause)
	level_stopping.connect(wave_flow.stop)
	level_stopping.connect(fragment_collection.stop)
	level_finished.connect(_on_third_finished)
	colony_progress.progress_changed.connect(_on_third_recovery)
	var sources: Array[Marker2D] = []
	for child: Node in $World/SpawnPoints.get_children():
		sources.append(child as Marker2D)
	if not wave_flow.configure(self, sources) or not fragment_collection.configure(self, get_fragment_targets()):
		push_error("第三关目标或持续出怪配置无效。")
		wave_flow.stop(&"invalid_configuration")
		fragment_collection.stop(&"invalid_configuration")
	_objective_overlay = Node2D.new()
	_objective_overlay.name = "ExplorationWarnings"
	_objective_overlay.z_index = 30
	$World.add_child(_objective_overlay)
	_objective_overlay.draw.connect(_draw_spawn_warnings)
	_preview_font = SystemFont.new()
	_preview_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC"])
	compact_hud = CompactColonyHUD.new()
	compact_hud.name = "CompactHUD"
	add_child(compact_hud)
	compact_hud.configure(self)
	_third_ready = true
	_refresh_third_hud()
	first_guide.record_event(&"opening")
	hud.show_notice("第三关：用连通母核的菌域覆盖三个碎片，各收集5秒；大型尸骸支持探索与防守。")


func _process(delta: float) -> void:
	if _restart_pending:
		return
	super._process(delta)
	if _third_ready:
		_refresh_third_hud()
		_objective_overlay.queue_redraw()


func _input(event: InputEvent) -> void:
	if not _third_ready or _restart_pending:
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
	if not _third_ready or _restart_pending:
		return
	if event is InputEventMouse and (compact_hud.is_pointer_over_ui(event.position) \
			or flow_hud.is_pointer_over_panel(event.position)):
		return
	if get_tree().paused and event.is_action_pressed("request_supply"):
		get_viewport().set_input_as_handled()
		return
	super._unhandled_input(event)


func _exit_tree() -> void:
	super._exit_tree()
	get_window().content_scale_size = _old_content_size


func start_next_wave() -> bool:
	return wave_flow.begin_attack() if _third_ready and not get_tree().paused and not _restart_pending else false


func restart_level() -> void:
	if _restart_pending:
		return
	_restart_pending = true
	pause_controller.reset()
	super.restart_level()


func get_fragment_targets() -> Array[MemoryFragment]:
	var fragments: Array[MemoryFragment] = []
	for child: Node in $World/Fragments.get_children():
		if child is MemoryFragment:
			fragments.append(child)
	return fragments


func get_objective_caption() -> String:
	return "收集碎片 %d/3" % fragment_collection.collected_ids.size()


func get_level_snapshot() -> Dictionary:
	return {"production": wave_flow.get_snapshot(), "fragments": fragment_collection.get_snapshot(),
		"result": get_result_snapshot(), "paused": pause_controller.is_paused(), "elapsed_seconds": elapsed_seconds}


func _on_objective_completed(evidence: Dictionary) -> void:
	finish_level(true, evidence)


func _on_mother_core_depleted() -> void:
	finish_level(false, fragment_collection.get_evidence())


func _on_third_finished(snapshot: Dictionary) -> void:
	compact_hud.close_drawer()
	if bool(snapshot.get("victory", false)):
		flow_hud.show_ending(snapshot)
	else:
		flow_hud.show_result(snapshot)
	compact_hud.refresh()


func _on_fragment_collected(_id: StringName, text: String) -> void:
	first_guide.record_event(&"fragment_collected")
	hud.show_notice(text + "  下一批敌人至少延后15秒。")


func _on_enemy_created(enemy: BasicEnemy) -> void:
	var events: Dictionary = {BasicEnemy.Archetype.SWARM: &"swarm", BasicEnemy.Archetype.ARMORED: &"armored",
		BasicEnemy.Archetype.SILK_GNAWER: &"silk_gnawer", BasicEnemy.Archetype.JUNCTION_GNAWER: &"junction_gnawer"}
	if events.has(enemy.archetype):
		first_guide.record_event(events[enemy.archetype])


func _on_third_recovery(total: int, _products: int) -> void:
	if total > 0:
		first_guide.record_event(&"nutrition_returned")


func _refresh_third_hud() -> void:
	flow_hud.show_colony({"core_health": mother_core.health, "core_max_health": mother_core.max_health,
		"nutrition": mother_core.nutrition, "total_recovered": colony_progress.get_total_recovered(),
		"stage_name": colony_progress.get_stage_name(), "elapsed_seconds": floorf(elapsed_seconds)})
	flow_hud.show_flow(wave_flow.get_snapshot())
	flow_hud.show_objectives(fragment_collection.get_snapshot())
	compact_hud.refresh()


func _draw_spawn_warnings() -> void:
	if not get_result_snapshot().is_empty():
		return
	for source: Dictionary in wave_flow.get_snapshot().get("sources", []):
		var point: Vector2 = source.position
		var warning: bool = source.phase == &"warning"
		var color := Color("edaa77") if warning else Color("72918d")
		_objective_overlay.draw_arc(point, 26, 0, TAU, 24, color, 2, true)
		_objective_overlay.draw_string(_preview_font, point + Vector2(-55, -36),
			"来袭 %.0fs" % float(source.remaining) if warning else "敌人入口", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)
