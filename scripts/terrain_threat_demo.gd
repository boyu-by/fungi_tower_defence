class_name TerrainThreatDemo
extends "res://scripts/combat_specialization_demo.gd"
## 第九阶段：固定岩石、前沿损伤与可恢复的真实啃食者危机。

@export var gnawer_batch_entries: Array[EnemySpawnEntry] = []

@onready var terrain_navigation: TerrainNavigation = $World/TerrainNavigation
@onready var frontier_status: FrontierStatus = $World/FrontierStatus

var tissue_attack_count: int = 0
var network_break_count: int = 0
var _last_attack: Dictionary = {}
var _last_loss: Dictionary = {}


func _ready() -> void:
	# Resource 是每局私有的，但本局所有预览与建设 worker 共用这一份。
	growth_planner = growth_planner.duplicate(true) as GrowthPlanner
	growth_planner.terrain_navigation = terrain_navigation
	super._ready()
	frontier_status.level = self
	enemy_spawner.enemy_spawned.connect(_on_terrain_enemy_spawned)
	tissue_lifecycle.tissue_lost.connect(_on_tissue_lost)
	for controller: Node in [growth_input_controller, connection_input_controller]:
		controller.connect("preview_changed", frontier_status.show_preview)
		controller.connect("mode_changed", frontier_status.clear_preview)
	cultivation_input_controller.remote_preview_changed.connect(frontier_status.show_preview)
	cultivation_input_controller.remote_mode_changed.connect(frontier_status.clear_preview)
	_add_frontier_batch_button()
	combat_hint_controller.set_enabled(false)
	select_test_batch(&"gnawer")
	hud.show_notice("第九阶段｜先 G 接通80/120资源并成长，再开始前沿批次；F选组织、J付费修复，空菌结C重建")


func _on_terrain_enemy_spawned(enemy: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
	enemy.terrain_navigation = terrain_navigation
	enemy.network_system = network_system
	enemy.attacked_tissue.connect(_on_enemy_attacked.bind(enemy))


func _on_enemy_attacked(target: Node2D, amount: float, enemy: BasicEnemy) -> void:
	tissue_attack_count += 1
	target.set_meta("combat_injured", true)
	_last_attack = {"target_id": target.get_instance_id(), "kind": String(target.get_class()),
		"amount": amount, "enemy_id": enemy.get_instance_id(), "position": target.global_position}
	if target is HyphaEdge:
		_last_attack["position"] = target.get_point_at(0.5)


func _on_tissue_lost(identity: int, kind: StringName, point: Vector2) -> void:
	_last_loss = {"id": identity, "kind": kind, "position": point}
	if kind in [&"菌结", &"菌丝"]:
		network_break_count += 1
		hud.show_notice("%s受损失效：物流会等待或改道。保护前沿，F选择目标后按J修复；也可L建立旁路" % kind)


func get_frontier_snapshot() -> Dictionary:
	return {"attacks": tissue_attack_count, "network_breaks": network_break_count,
		"last_attack": _last_attack.duplicate(), "last_loss": _last_loss.duplicate(),
		"resources": get_combat_resource_snapshot(), "batch": get_combat_demo_snapshot()}


func _is_batch_kind(kind: StringName) -> bool:
	return kind == &"gnawer" or super._is_batch_kind(kind)


func _get_batch_title(kind: StringName) -> String:
	return "前沿危机 ×3｜1啃食者从右下入口，2普通轮换" if kind == &"gnawer" else super._get_batch_title(kind)


func _get_batch_entries(kind: StringName) -> Array[EnemySpawnEntry]:
	return gnawer_batch_entries if kind == &"gnawer" else super._get_batch_entries(kind)


func get_batch_choices() -> Array[Dictionary]:
	var choices: Array[Dictionary] = super.get_batch_choices()
	choices.append({"id": &"gnawer", "title": _get_batch_title(&"gnawer"),
		"planned": _get_configured_count(&"gnawer")})
	return choices


func _add_frontier_batch_button() -> void:
	var panel: Control = hud.combat_demo_panel
	var button: Button = Button.new()
	button.name = "GnawerButton"
	button.text = "前沿 ×3"
	button.toggle_mode = true
	button.add_theme_font_size_override("font_size", 13)
	button.tooltip_text = _get_batch_title(&"gnawer")
	button.pressed.connect(func() -> void: hud.combat_batch_selected.emit(&"gnawer"))
	panel.add_child(button)
	var names: Array[String] = ["NormalButton", "SwarmButton", "ArmoredButton", "MixedButton", "GnawerButton"]
	for index: int in range(names.size()):
		var choice: Button = panel.get_node(names[index]) as Button
		choice.position = Vector2(8.0 + 73.0 * index, 24.0)
		choice.size = Vector2(68.0, 25.0)
