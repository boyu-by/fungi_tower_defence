class_name ColonyTerrainRuntime
extends "res://scripts/gameplay/colony_runtime.gd"
## 可选地形、前沿观察与组织攻击接线，不创建测试批次。

@onready var terrain_navigation: TerrainNavigation = get_node_or_null("World/TerrainNavigation") as TerrainNavigation
@onready var frontier_status: FrontierStatus = get_node_or_null("World/FrontierStatus") as FrontierStatus
var tissue_attack_count: int = 0
var network_break_count: int = 0
var _last_attack: Dictionary = {}
var _last_loss: Dictionary = {}

func _prepare_terrain_runtime() -> void:
	if is_instance_valid(terrain_navigation):
		growth_planner = growth_planner.duplicate(true) as GrowthPlanner
		growth_planner.terrain_navigation = terrain_navigation

func _connect_terrain_runtime() -> void:
	if is_instance_valid(frontier_status):
		frontier_status.level = self
	if is_instance_valid(terrain_navigation):
		enemy_spawner.enemy_spawned.connect(_on_terrain_enemy_spawned)
		tissue_lifecycle.tissue_lost.connect(_on_tissue_lost)
	if is_instance_valid(frontier_status):
		for controller: Node in [growth_input_controller, connection_input_controller]:
			controller.connect("preview_changed", frontier_status.show_preview)
			controller.connect("mode_changed", frontier_status.clear_preview)
		cultivation_input_controller.remote_preview_changed.connect(frontier_status.show_preview)
		cultivation_input_controller.remote_mode_changed.connect(frontier_status.clear_preview)

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
