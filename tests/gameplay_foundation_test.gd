extends SceneTree
## Shared scene integration with independent map names and real production.

const FOUNDATION: PackedScene = preload("res://scenes/gameplay/colony_gameplay.tscn")
const NODE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const STOMACH: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const ATTACK: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const CARCASS: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")

var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await _empty_foundation()
	await _custom_map("Garden", Vector2(480, 360))
	await _custom_map("Workshop", Vector2(650, 460))
	await _death_priority()
	print("GAMEPLAY_FOUNDATION_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _step(frames: int) -> void:
	for _frame: int in range(frames):
		await physics_frame
		await process_frame

func _empty_foundation() -> void:
	var level := FOUNDATION.instantiate() as ColonyLevelRuntime
	level.enable_colony_operations = false
	var window_size := root.content_scale_size
	root.add_child(level)
	await _step(3)
	_check(root.content_scale_size == window_size, "Foundation does not impose a demo window size")
	_check(level.hypha_nodes.get_child_count() == 0, "Foundation contains no test colony layout")
	_check(level.hypha_edges.get_child_count() == 0, "Foundation contains no test edges")
	_check(level.get_node("World/Remains").get_child_count() == 0, "Foundation creates no test resources")
	_check(level.get_node("World/SpawnPoints").get_child_count() == 0, "Foundation creates no test entrances")
	_check(not level.has_method("start_test_batch"), "Foundation does not inherit manual demo batches")
	_check(not level.has_method("get_resource_access_snapshot"), "Foundation does not inherit fixed resource guides")
	_check(not level.enemy_spawner.auto_start, "Foundation never starts a wave")
	var health := level.mother_core.health
	var action := InputEventAction.new()
	action.action = &"debug_damage_core"
	action.pressed = true
	level._unhandled_input(action)
	_check(level.mother_core.health == health, "Debug damage is absent from shared gameplay")
	level._on_wave_finished()
	_check(level.get_result_snapshot().is_empty(), "A batch finishing does not win a shared level")
	level.queue_free()
	await _step(3)
	_check(not paused, "Removing a foundation leaves the scene tree unpaused")

func _custom_map(prefix: String, origin: Vector2) -> void:
	var level := FOUNDATION.instantiate() as ColonyLevelRuntime
	level.name = prefix
	level.operations_panel_position = Vector2(24, 640)
	var core := level.get_node("World/Colony/MotherCore") as MotherCore
	core.position = origin
	var colony := level.get_node("World/Colony/Nodes")
	var connections := level.get_node("World/Colony/Connections")
	var food_host := NODE.instantiate() as HyphaNode
	food_host.name = prefix + "FoodStation"
	food_host.position = origin + Vector2(60, 40)
	colony.add_child(food_host)
	var stomach := STOMACH.instantiate() as DigestiveOrgan
	stomach.name = prefix + "Vessel"
	stomach.mother_core = core
	food_host.add_child(stomach)
	var food_edge := _edge(connections, core, food_host, prefix + "FoodLine")
	stomach.core_edge = food_edge
	var defender := NODE.instantiate() as HyphaNode
	defender.name = prefix + "Defender"
	defender.position = origin + Vector2(-80, -60)
	colony.add_child(defender)
	var attack := ATTACK.instantiate() as AttackOrgan
	attack.name = prefix + "Launcher"
	defender.add_child(attack)
	var weapon := WEAPON.instantiate() as SporeWeapon
	weapon.inventory_owner = attack
	weapon.enemy_container = level.get_node("World/Enemies")
	weapon.projectile_container = level.get_node("World/Projectiles")
	defender.add_child(weapon)
	_edge(connections, core, defender, prefix + "DefenseLine")
	var empty_host := NODE.instantiate() as HyphaNode
	empty_host.name = prefix + "NewStation"
	empty_host.position = origin + Vector2(80, -40)
	colony.add_child(empty_host)
	_edge(connections, core, empty_host, prefix + "BuildLine")
	var carcass := CARCASS.instantiate() as LargeCarcass
	carcass.name = prefix + "Resource"
	carcass.total_nutrition = 10
	carcass.position = food_host.position
	level.get_node("World/Remains").add_child(carcass)
	root.add_child(level)
	await _step(3)
	_check(level.attack_organ == attack, prefix + ": arbitrary attack name resolves")
	_check(level.digestive_organ == stomach, prefix + ": arbitrary stomach name resolves")
	_check(level.network_system.is_available_connected_to_core(food_host), prefix + ": initial map registers")
	_check(is_instance_valid(level.transplant_system), prefix + ": transplant connects without a demo parent")
	_check(level.hud.get_node_or_null("OperationsPanel") != null, prefix + ": common operations UI exists")
	_check(level._operations_panel.get_child_count() == 6, prefix + ": UI has no development shortcut")
	for _frame: int in range(1800):
		if level.colony_progress.get_total_recovered() == 10:
			break
		await _step(1)
	_check(level.colony_progress.get_total_recovered() == 10, prefix + ": real carcass recovers through renamed stomach")
	_check(level.mother_core.nutrition == 82, prefix + ": no invented recovery income")
	level.choose_organ(&"digestive")
	level._select_node(empty_host)
	level._on_cultivation_requested()
	for _frame: int in range(1800):
		if level.get_digestive_organs().size() == 2:
			break
		await _step(1)
	_check(level.get_digestive_organs().size() == 2, prefix + ": paid second stomach matures")
	_check(level.mother_core.nutrition == 74, prefix + ": original eight-point recipe remains")
	var ledger := level.get_combat_resource_snapshot()
	_check(bool(ledger.get("balanced", false)) and int(ledger.get("error", -1)) == 0, prefix + ": resource ledger balances")
	level.pause_controller.set_paused(true)
	var time_before := level.elapsed_seconds
	var balance_before := level.mother_core.nutrition
	await _step(6)
	_check(level.elapsed_seconds == time_before and level.mother_core.nutrition == balance_before, prefix + ": pause freezes time and resources")
	level.pause_controller.set_paused(false)
	var objective := {"kind": "fixture", "completed": 3, "total": 3}
	_check(level.finish_level(true, objective), prefix + ": external objective finishes level")
	objective.completed = 0
	await _step(1)
	_check(level.get_result_snapshot().objective.completed == 3, prefix + ": evidence is copied")
	_check(not level.finish_level(true), prefix + ": terminal transition is unique")
	_check(level.get_result_snapshot().victory, prefix + ": objective records victory")
	level.queue_free()
	await _step(3)
	_check(not paused, prefix + ": teardown does not pause next level")

func _death_priority() -> void:
	for death_first: bool in [true, false]:
		var level := FOUNDATION.instantiate() as ColonyLevelRuntime
		level.enable_colony_operations = false
		root.add_child(level)
		await _step(2)
		if death_first:
			level.mother_core.take_damage(level.mother_core.health)
			level.finish_level(true)
		else:
			level.finish_level(true)
			level.mother_core.take_damage(level.mother_core.health)
		await _step(1)
		_check(not level.get_result_snapshot().victory, "Core death beats objective completion in either callback order")
		level.queue_free()
		await _step(2)
		_check(not paused, "Failure teardown resets pause")

func _edge(container: Node, start: Node2D, end: Node2D, edge_name: String) -> HyphaEdge:
	var edge := EDGE.instantiate() as HyphaEdge
	edge.name = edge_name
	edge.start_node = start
	edge.end_node = end
	container.add_child(edge)
	return edge
