extends SceneTree
## 第一阶段接线验证：真实 demo 的图、菌域和规划器不改变原有资源结算。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var level := LEVEL_SCENE.instantiate() as Node2D
	level.expansion_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	root.add_child(level)
	current_scene = level
	level.set_process(false)
	level.fungal_field.set_process(false)
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	for current_weapon in level.get_weapons():
		current_weapon.get_node("FireTimer").stop()
	_test_initial_sources(level)
	_test_live_connectivity(level)
	_test_registration_hooks(level)
	_test_planning_without_execution(level)
	_test_core_loss(level)
	level.queue_free()
	await process_frame
	await process_frame
	print("FOUNDATION_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _test_initial_sources(level: Node2D) -> void:
	var network: NetworkSystem = level.network_system
	var field: FungalField = level.fungal_field
	var core: MotherCore = level.mother_core
	var front: Node2D = level.attack_organ.get_parent()
	var rear: Node2D = level.digestive_organ.get_parent()
	_check(network.get_registered_nodes().size() == 4, "Demo registers core and three junctions")
	_check(network.is_connected_to_core(front), "Front connected to core")
	_check(network.is_connected_to_core(rear), "Rear connected to core")
	var route := network.find_route(front, core)
	_check(route.found and route.segments.size() == 1, "Demo exposes direct reverse route")
	if route.segments.size() == 1:
		_check(not route.segments[0].forward, "Direct reverse route preserves direction")
	_check(field.get_effective_radius(core) == 0.0, "Demo coverage begins unexpanded")
	field.advance(1.0)
	_check(is_equal_approx(field.get_effective_radius(core), 140.0), "Core radius reaches 140")
	_check(is_equal_approx(field.get_effective_radius(front), 110.0), "Junction radius reaches 110")
	var overlap := Vector2(680, 570)
	_check(field.get_collecting_nodes(overlap).size() == 2, "Core/rear overlap has two candidates")
	_check(field.get_collection_node(overlap) == rear, "Overlap resolves to one nearest entrance")
	_check(field.z_index < -1, "Ground field is below hypha edges and organisms")
	_check(not level.weapon.range_outline.visible, "Weapon range remains selection-only")
	level._select_node(front)
	_check(level.weapon.range_outline.visible, "Existing selection still shows weapon range")
	_check(level.weapon.range_outline.default_color.r > 0.9, "Weapon range is amber")
	level._select_node(null)


func _test_live_connectivity(level: Node2D) -> void:
	var network: NetworkSystem = level.network_system
	var field: FungalField = level.fungal_field
	var core: MotherCore = level.mother_core
	var front: Node2D = level.attack_organ.get_parent()
	var rear: Node2D = level.digestive_organ.get_parent()
	var front_edge: HyphaEdge = level.supply_system.supply_edge
	var rear_edge: HyphaEdge = level.digestive_organ.core_edge
	front_edge.end_node = null
	level._sync_fungal_sources()
	var route := network.find_route(core, front)
	_check(route.found and route.segments.size() == 2, "Triangle uses surviving two-edge route")
	_check(field.is_covered(front.global_position), "Alternate route retains front coverage")
	rear_edge.end_node = null
	level._sync_fungal_sources()
	_check(not network.is_connected_to_core(front), "Both core links removed isolate front")
	_check(not field.is_covered(front.global_position), "Isolated front cannot collect")
	_check(not field.is_covered(rear.global_position), "Isolated rear cannot collect")
	_check(field.get_collection_node(Vector2(680, 570)) == core,
		"Core retains overlap after rear loses connection")
	_check(network.find_route(front, rear).found, "Isolated peers retain internal route")
	rear_edge.end_node = rear
	level._sync_fungal_sources()
	_check(network.is_connected_to_core(front), "Restored rear link reconnects the triangle")
	_check(field.get_effective_radius(front) == field.node_radius,
		"Grace-period reconnection resumes the radius that remained visible")
	field.advance(1.0)
	_check(field.is_covered(front.global_position), "Restored front coverage becomes effective")
	front_edge.end_node = front
	level._sync_fungal_sources()


func _test_registration_hooks(level: Node2D) -> void:
	var network: NetworkSystem = level.network_system
	var field: FungalField = level.fungal_field
	var rear: Node2D = level.digestive_organ.get_parent()
	var junction := NODE_SCENE.instantiate() as HyphaNode
	junction.position = Vector2(920, 590)
	level.hypha_nodes.add_child(junction)
	_check(network.get_registered_nodes().has(junction), "Added junction automatically registered")
	var edge := EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = rear
	edge.end_node = junction
	level.hypha_edges.add_child(edge)
	level._sync_fungal_sources()
	_check(network.is_connected_to_core(junction), "Added edge automatically registered")
	_check(field.get_effective_radius(junction) == 0.0, "New junction has no instant full coverage")
	field.advance(0.25)
	level._sync_fungal_sources()
	_check(is_equal_approx(field.get_effective_radius(junction), 35.0),
		"Repeated level snapshots preserve expansion")
	edge.free()
	level._sync_fungal_sources()
	_check(not network.is_connected_to_core(junction), "Removed edge invalidates connectivity")
	_check(field.get_effective_radius(junction) == 0.0, "Removed edge invalidates coverage")
	junction.free()
	level._sync_fungal_sources()
	_check(network.get_registered_nodes().size() == 4, "Removed junction leaves no stale registration")
	var tip := Node2D.new()
	level.hypha_nodes.add_child(tip)
	level._sync_fungal_sources()
	_check(network.get_registered_nodes().has(tip), "Generic temporary tip can join graph")
	_check(field.get_effective_radius(tip) == 0.0, "Temporary tips do not supply junction coverage")
	tip.free()
	level._sync_fungal_sources()


func _test_planning_without_execution(level: Node2D) -> void:
	var core: MotherCore = level.mother_core
	var nutrition_before := core.nutrition
	var inventory_before: int = level.attack_organ.nutrition
	var node_count_before: int = level.hypha_nodes.get_child_count()
	var edge_count_before: int = level.hypha_edges.get_child_count()
	var result: Dictionary = level.growth_planner.plan(
		core.global_position, core.global_position + Vector2(240, 0)
	)
	_check(result.valid and result.total_cost == 11, "Level exposes shared planner with 240px cost 11")
	_check(result.segments.size() == 2 and result.junction_positions.size() == 2,
		"Planner returns two segments and two new junctions")
	_check(core.nutrition == nutrition_before, "Planning does not deduct core nutrition")
	_check(level.attack_organ.nutrition == inventory_before, "Planning does not touch organ stock")
	_check(level.hypha_nodes.get_child_count() == node_count_before, "Planning does not create junctions")
	_check(level.hypha_edges.get_child_count() == edge_count_before, "Planning does not create edges")


func _test_core_loss(level: Node2D) -> void:
	level.mother_core.take_damage(level.mother_core.max_health)
	level._sync_fungal_sources()
	_check(not level.fungal_field.is_covered(level.mother_core.global_position),
		"Defeated colony has no valid collecting field")
