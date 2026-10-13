extends "res://scripts/gameplay/colony_operations_runtime.gd"
## 旧场景兼容入口：仅保留演示资源、快捷跳转、调试输入与原单波结算。

const LARGE_CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
@export var expansion_demo_enabled: bool = true
@export var carcass_demo_enabled: bool = false
var progression_hint_controller: ProgressionHintController

func _ready() -> void:
	super._ready()
	if carcass_demo_enabled:
		hud.show_notice("L 连接菌结：先选左翼，再选右翼，预览环路；B 在右侧十字种芽，G 伸展，C 培育")

func _prepare_map_content() -> void:
	if not expansion_demo_enabled:
		$World/Remains/ExpansionRemains.free()
	if carcass_demo_enabled:
		var carcass: LargeCarcass = LARGE_CARCASS_SCENE.instantiate() as LargeCarcass
		carcass.name = "LargeCarcass"
		carcass.position = Vector2(1120, 440)
		$World/Remains.add_child(carcass)


func _connect_progression_hints() -> void:
	if not has_method("get_resource_access_snapshot"):
		return
	progression_hint_controller = ProgressionHintController.new()
	progression_hint_controller.name = "ProgressionHintController"
	$Systems.add_child(progression_hint_controller)
	progression_hint_controller.hint_changed.connect(hud.show_progression_hint)
	hud.progression_hint_dismiss_requested.connect(progression_hint_controller.dismiss_current)
	hud.progression_hint_toggle_requested.connect(progression_hint_controller.set_hints_enabled)
	progression_hint_controller.configure(colony_progress, colony_capabilities,
		construction_coordinator, digestive_organ, main_vein_system, self)
	hud.show_progression_hint(progression_hint_controller.get_snapshot())


func _stop_progression_hints() -> void:
	if is_instance_valid(progression_hint_controller):
		progression_hint_controller.reset()
	if is_instance_valid(hud):
		hud.show_progression_hint({})


func _unhandled_input(event: InputEvent) -> void:
	var viewport: Viewport = get_viewport()
	if event.is_action_pressed("colony_operations_demo"):
		viewport.set_input_as_handled()
		_announce_level_stopping(&"scene_change")
		get_tree().change_scene_to_file("res://scenes/levels/colony_operations_demo.tscn")
		return
	if event.is_action_pressed("terrain_threat_demo"):
		viewport.set_input_as_handled()
		_announce_level_stopping(&"scene_change")
		get_tree().change_scene_to_file("res://scenes/levels/terrain_threat_demo.tscn")
		return
	if event.is_action_pressed("combat_specialization_demo"):
		viewport.set_input_as_handled()
		_announce_level_stopping(&"scene_change")
		_stop_progression_hints()
		get_tree().change_scene_to_file("res://scenes/levels/combat_specialization_demo.tscn")
		return
	if event.is_action_pressed("original_carcass_demo") or event.is_action_pressed("progression_demo"):
		var scene_path: String = "res://scenes/levels/progression_demo.tscn" \
			if event.is_action_pressed("progression_demo") else "res://scenes/levels/large_carcass_demo.tscn"
		viewport.set_input_as_handled()
		_announce_level_stopping(&"scene_change")
		_stop_progression_hints()
		get_tree().change_scene_to_file(scene_path)
		return
	if repair_input_controller.handle_input(event):
		if is_instance_valid(viewport):
			viewport.set_input_as_handled()
		return
	if event.is_action_pressed("traffic_recovery_demo"):
		get_viewport().set_input_as_handled()
		_announce_level_stopping(&"scene_change")
		_stop_progression_hints()
		get_tree().change_scene_to_file("res://scenes/levels/traffic_recovery_demo.tscn")
		return
	elif event.is_action_pressed("cancel_selection"):
		_select_node(null)
	elif event.is_action_pressed("debug_damage_core"):
		mother_core.take_damage(30)
	elif event.is_action_pressed("request_supply"):
		var organ := _get_selected_organ()
		if is_instance_valid(organ):
			supply_system.request_supply(organ)
		else:
			hud.show_notice("请选择一个攻击器官所在的菌结")
	elif event.is_action_pressed("debug_consume_nutrition"):
		if normal_weapon_profile != null:
			return
		var organ := _get_selected_organ()
		if is_instance_valid(organ) and organ.consume_nutrition():
			hud.show_notice("器官消耗 1 点营养；库存不足时会自动补给")
		else:
			hud.show_notice("器官库存为空，等待供养")
	elif event.is_action_pressed("restart_level"):
		get_viewport().set_input_as_handled()
		restart_level()
		return
	else:
		return
	get_viewport().set_input_as_handled()


func _on_wave_finished() -> void:
	if mother_core.health > 0:
		hud.show_battle_result(true)
