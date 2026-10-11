extends SceneTree
## 第二阶段真实关卡接线：多器官选择、动态登记、路线撤销与菌域回收。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_selection_and_route_removal()
	await _test_dynamic_registration()
	await _test_field_return_route()
	_check(root.get_child_count() == 0, "Logistics teardown leaves no orphan nodes")
	print("LOGISTICS_INTEGRATION_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _new_level() -> Node2D:
	var level := LEVEL_SCENE.instantiate() as Node2D
	level.expansion_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	root.add_child(level)
	current_scene = level
	await physics_frame
	await process_frame
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	for current_weapon in level.get_weapons():
		current_weapon.get_node("FireTimer").stop()
	level.fungal_field.advance(1.0)
	return level


func _remove_level(level: Node2D) -> void:
	level.queue_free()
	await process_frame
	await process_frame


func _press(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	root.push_input(event)
	event = InputEventKey.new()
	event.keycode = key
	root.push_input(event)


func _click(point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event)
	await physics_frame
	await process_frame
	event = event.duplicate() as InputEventMouseButton
	event.pressed = false
	root.push_input(event)
	await physics_frame
	await process_frame


func _wait_supply(level: Node2D) -> void:
	for frame in range(900):
		if level.supply_system.get_in_transit_count() == 0:
			break
		await physics_frame
	await process_frame
	await process_frame
	_check(level.supply_system.get_in_transit_count() == 0, "Supply completed before timeout")


func _test_selection_and_route_removal() -> void:
	var level := await _new_level()
	var supply: SupplySystem = level.supply_system
	var network: NetworkSystem = level.network_system
	var right := level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var organ := right.get_node("AttackOrgan") as AttackOrgan
	var right_weapon := right.get_node("SporeWeapon") as SporeWeapon
	_check(supply.get_registered_organs().size() == 2, "Scene registers both attack organs")
	_check(supply.get_active_organs().size() == 2, "Both connected organs active")
	_check(not level.has_node("World/Colony/Nodes/HyphaNode/RecoveryOrgan"),
		"Demo does not depend on a recovery organ")
	_check(network.find_route(level.mother_core, right).segments.size() == 2,
		"Right organ is reached through two edges")
	await _click(organ.global_position + Vector2(0, -32))
	_check(level.selected_node == right, "Click selects second organ's junction")
	_check(right_weapon.range_outline.visible and not level.weapon.range_outline.visible,
		"Only selected weapon shows its range")
	_press(KEY_E)
	_check(organ.nutrition == 3 and level.attack_organ.nutrition == 4, "E consumes selected stock only")
	_press(KEY_N)
	_check(organ.incoming_nutrition == 1 and level.attack_organ.incoming_nutrition == 0,
		"N supplies selected organ only")
	_check(level.mother_core.nutrition == 71, "Selected supply debits immediately")
	await _wait_supply(level)
	_check(organ.nutrition == 4 and organ.incoming_nutrition == 0, "Two-edge delivery reaches selected organ")
	_check(level.hud.colony_label.text.contains("攻击器官：2"), "HUD counts both organs")
	_check(level.hud.stock_label.text.contains("器官库存：4/6"), "HUD follows selected inventory")
	var balance: int = level.mother_core.nutrition
	var route := network.find_route(level.mother_core, right)
	_check(network.is_route_valid(route), "Fresh route is valid")
	_check(supply.request_supply(organ), "Dispatch before edge unregister")
	var edge := level.get_node("World/Colony/Connections/RightEdge") as HyphaEdge
	network.unregister_edge(edge)
	_check(not network.is_route_valid(route), "Unregister invalidates snapshot without freeing visible edge")
	for _frame: int in range(120):
		await physics_frame
		await process_frame
	_check(level.mother_core.nutrition == balance - 1 and organ.incoming_nutrition == 1
		and supply.get_in_transit_count() == 1,
		"Unregistered future edge retains the original payment and reservation while waiting")
	_check(supply.get_active_organs().size() == 1, "Disconnected recipient excluded from active query")
	network.register_edge(edge)
	_check(supply.get_active_organs().size() == 2, "Restored edge restores active query")
	await _wait_supply(level)
	_check(level.mother_core.nutrition == balance - 1 and organ.incoming_nutrition == 0
		and organ.nutrition == 5, "Restored future edge delivers the same prepaid cargo once")
	_press(KEY_ESCAPE)
	_check(not right_weapon.range_outline.visible, "Cancel selection hides second range")
	await _remove_level(level)


func _test_dynamic_registration() -> void:
	var level := await _new_level()
	var supply: SupplySystem = level.supply_system
	var network: NetworkSystem = level.network_system
	var host := NODE_SCENE.instantiate() as HyphaNode
	host.position = Vector2(960, 500)
	level.hypha_nodes.add_child(host)
	var organ := ORGAN_SCENE.instantiate() as AttackOrgan
	host.add_child(organ)
	var current_weapon := WEAPON_SCENE.instantiate() as SporeWeapon
	current_weapon.inventory_owner = organ
	current_weapon.enemy_container = level.get_node("World/Enemies")
	current_weapon.projectile_container = level.get_node("World/Projectiles")
	host.add_child(current_weapon)
	current_weapon.get_node("FireTimer").stop()
	var edge := EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = level.get_node("World/Colony/Nodes/RightNode")
	edge.end_node = host
	level.hypha_edges.add_child(edge)
	await process_frame
	_check(supply.get_registered_organs().size() == 3 and supply.get_registered_organs().has(organ),
		"Adding an organ to a live node registers it")
	_check(supply.get_active_organs().size() == 3, "New connected organ appears in active query")
	var route := network.find_route(level.mother_core, host)
	_check(route.segments.size() == 3, "Added organ has a three-edge route")
	organ.selection_requested.emit()
	_check(level.selected_node == host and current_weapon.range_outline.visible,
		"Dynamic organ selection and weapon range are connected")
	var balance: int = level.mother_core.nutrition
	_check(supply.request_supply(organ), "Dynamic organ accepts supply")
	level.hypha_nodes.remove_child(host)
	await _wait_supply(level)
	_check(supply.get_registered_organs().size() == 2, "Removing live host unregisters its organ")
	_check(organ.incoming_nutrition == 0 and level.mother_core.nutrition == balance,
		"Removing host releases pending reservation and refunds")
	_check(level.selected_node == null, "Removed selection is cleared")
	_check(not network.get_registered_nodes().has(host), "Removed host leaves the network")
	host.free()
	_check(not network.is_route_valid(route), "Freed target invalidates old route snapshot safely")
	edge.free()
	await _remove_level(level)


func _test_field_return_route() -> void:
	var level := await _new_level()
	var network: NetworkSystem = level.network_system
	var field: FungalField = level.fungal_field
	var front: Node2D = level.attack_organ.get_parent()
	var rear: Node2D = level.digestive_organ.get_parent()
	var direct := level.get_node("World/Colony/Connections/RecoveryEdge") as HyphaEdge
	network.unregister_edge(direct)
	_check(network.find_route(front, rear).segments.size() == 2, "Harvest can use alternate two-edge route")
	var remains := REMAINS_SCENE.instantiate() as EnemyRemains
	level.get_node("World/Remains").add_child(remains)
	remains.global_position = front.global_position + Vector2(-20, 0)
	_check(field.get_collection_node(remains.global_position) == front, "Corpse belongs to front field")
	level.digestive_organ.digest_timer.wait_time = 5.0
	var before: int = level.mother_core.nutrition
	_check(level.recycling_system.try_dispatch(), "Field dispatches without RecoveryOrgan or fixed edge")
	_check(not level.recycling_system.try_dispatch(), "Same corpse cannot dispatch twice")
	_check(level.digestive_organ.get_queued_count() == 0 and level.digestive_organ.incoming_remains == 1,
		"Pickup reserves capacity without early queue entry")
	for frame in range(900):
		if level.recycling_system.get_in_transit_count() == 0:
			break
		await physics_frame
	_check(level.recycling_system.get_in_transit_count() == 0, "Multi-edge return completed")
	_check(level.digestive_organ.get_queued_count() == 1 and level.mother_core.nutrition == before,
		"Arrival queues corpse but does not credit core")
	level.digestive_organ.digest_timer.start(0.1)
	for frame in range(15):
		await physics_frame
	_check(level.mother_core.nutrition == before and level.digestive_organ.get_output_nutrition() == 4,
		"Digestion creates uncredited return output")
	for frame in range(420):
		if level.colony_progress.get_total_recovered() == 4:
			break
		await physics_frame
	_check(level.mother_core.nutrition == before + 4 and level.colony_progress.get_total_recovered() == 4,
		"Income and cumulative recovery occur only at actual return")
	_check(level.digestive_organ.digested_count == 1, "Corpse is digested once")
	await _remove_level(level)
