extends SceneTree
## 第三阶段真实关卡：输入、运输、成形、菌域，以及暂停和重开。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")

var checks: int = 0
var failures: Array[String] = []
var chain_result: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_real_growth_chain()
	await _test_partial_cancellation()
	await _test_starvation_and_recovery()
	await _test_restart_during_transport()
	await _test_growth_pause_keeps_combat_and_recycling()
	await _test_growth_during_full_battle()
	_check(root.get_child_count() == 0, "Integration teardown leaves no scene objects")
	print("GROWTH_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "real_chain": chain_result,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _new_level(combat: bool = false) -> Node2D:
	var level := LEVEL_SCENE.instantiate() as Node2D
	# 旧单执行器兼容夹具；正式多实例路径另作真实集成验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	level.expansion_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = combat
	root.add_child(level)
	current_scene = level
	await physics_frame
	await process_frame
	return level


func _remove_level(level: Node2D) -> void:
	level.queue_free()
	await process_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame


func _press(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	root.push_input(event)
	event = InputEventKey.new()
	event.keycode = key
	root.push_input(event)


func _push_click(position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = true
	root.push_input(event)
	event = event.duplicate() as InputEventMouseButton
	event.pressed = false
	root.push_input(event)
	# 7.2 的正式输入只入队；显式推进调度边界，仍由原真实包结算与施工。
	if is_instance_valid(current_scene):
		current_scene.construction_coordinator.pump()


func _wait_completion(level: Node2D, limit: int = 6000) -> void:
	for frame in range(limit):
		if level.growth_system.get_task_snapshot().state == &"completed":
			break
		await physics_frame
	await process_frame
	_check(level.growth_system.get_task_snapshot().state == &"completed",
		"Real nutrition transport completes growth before timeout")


func _test_real_growth_chain() -> void:
	var level := await _new_level()
	var growth: GrowthSystem = level.growth_system
	var supply: GrowthSupplySystem = level.growth_supply_system
	var input: GrowthInputController = level.growth_input_controller
	var start := level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var target := Vector2(1080, 400)
	var plan: Dictionary = level.growth_planner.plan(start.global_position, target)
	supply.auto_supply = false
	_check(growth.planner == level.growth_planner and input.planner == level.growth_planner,
		"Preview and execution use the same planner resource")
	_check(not level.fungal_field.is_covered(target), "Distant target begins outside fungal field")
	_push_click(start.global_position + Vector2(0, -32))
	await _wait_frames(3)
	_check(level.selected_node == start, "Normal organ picking works before growth placement")
	var balance: int = level.mother_core.nutrition
	var nodes_before: int = level.network_system.get_registered_nodes().size()
	_press(KEY_G)
	_check(input.is_placing(), "G enters placement through the scene input map")
	var preview: Dictionary = input.preview_at(target)
	_check(preview.valid and preview.start_node == start and preview.plan.total_cost == plan.total_cost,
		"Preview chooses connected right frontier and exact planner fee")
	_check(level.mother_core.nutrition == balance and level.network_system.get_registered_nodes().size() == nodes_before,
		"Preview has no debit or registered network nodes")
	_press(KEY_ESCAPE)
	_check(not input.is_placing() and level.selected_node == start,
		"Esc exits placement without clearing ordinary selection")
	_press(KEY_G)
	_push_click(target)
	_check(growth.has_active_task() and not input.is_placing(), "Left-click creates one real growth task")
	_check(level.mother_core.nutrition == balance, "Placing target alone does not debit")
	var snapshot: Dictionary = growth.get_task_snapshot()
	_check(snapshot.total_cost == 16 and snapshot.distance == 0.0,
		"300-pixel target quotes 16 and starts with no physical extension")
	var tip: Node2D = growth.get_delivery_target(snapshot.task_id)
	var route: NetworkRoute = level.network_system.find_route(level.mother_core, tip)
	_check(route.found and route.segments.size() == 3, "Actual tip is a multi-edge transport destination")
	_check(level.fungal_field.get_effective_radius(tip) == 0.0, "Unpaid temporary tip grants no fungal field")
	_check(supply.try_dispatch(), "Actual growth supply launches a nutrient packet")
	_check(supply.get_in_transit_count() == 1 and growth.get_task_snapshot().consumed_nutrition == 0,
		"Debited packet is in transit, never immediate growth funding")
	_press(KEY_P)
	supply.auto_supply = true
	await _wait_frames(240)
	snapshot = growth.get_task_snapshot()
	_check(snapshot.state == &"paused" and snapshot.distance == 0.0,
		"Growth pause preserves position while the packet travels")
	_check(supply.get_in_transit_count() == 0 and snapshot.buffered_nutrition == 1,
		"Existing shipment arrives in paused buffer without new shipments")
	_check(level.mother_core.nutrition == balance - 1, "Pause makes no extra debit")
	_press(KEY_P)
	await _wait_completion(level)
	snapshot = growth.get_task_snapshot()
	_check(snapshot.progress == 1.0 and snapshot.consumed_nutrition == plan.total_cost,
		"Completion reports full progress and exact preview fee")
	_check(snapshot.buffered_nutrition == 0 and supply.get_in_transit_count() == 0,
		"Completed task leaves no buffered or in-transit growth nutrition")
	_check(level.mother_core.nutrition == balance - plan.total_cost,
		"Real core debit equals growth investment in idle combat scene")
	_check(level.hypha_nodes.get_child_count() == 6, "Exactly three paid junctions have been added")
	for point: Vector2 in plan.junction_positions:
		var found: HyphaNode = null
		for child in level.hypha_nodes.get_children():
			if child is HyphaNode and child.global_position.is_equal_approx(point):
				found = child
		_check(found != null and level.network_system.is_connected_to_core(found),
			"Planner junction %s is present and connected" % point)
	await _wait_frames(75)
	_check(level.fungal_field.is_covered(target + Vector2(65, 0)),
		"New endpoint gradually expands real fungal collecting coverage")
	_check(level.hud.growth_label.text.contains("完成"), "HUD follows completed task state")
	var after_nodes: int = level.network_system.get_registered_nodes().size()
	var after_balance: int = level.mother_core.nutrition
	_press(KEY_X)
	await _wait_frames(60)
	_check(level.network_system.get_registered_nodes().size() == after_nodes and level.mother_core.nutrition == after_balance,
		"Late cancel and processing cannot generate or charge after completion")
	chain_result = {"distance": snapshot.distance, "cost": snapshot.consumed_nutrition,
		"new_junctions": snapshot.formed_junctions, "core_balance": after_balance}
	await _remove_level(level)


func _test_partial_cancellation() -> void:
	var level := await _new_level()
	_press(KEY_G)
	_push_click(Vector2(1080, 400))
	for frame in range(3000):
		var current: Dictionary = level.growth_system.get_task_snapshot()
		if current.formed_junctions == 1 and current.distance > 150.0:
			break
		await physics_frame
	var before: Dictionary = level.growth_system.get_task_snapshot()
	_check(before.formed_junctions == 1 and before.distance > 150.0 and before.distance < 240.0,
		"Cancellation fixture has one mature junction and a partial next strand")
	var mature_count: int = level.hypha_nodes.get_child_count()
	_press(KEY_X)
	await _wait_frames(5)
	var after: Dictionary = level.growth_system.get_task_snapshot()
	_check(after.state == &"cancelled" and after.distance == before.distance,
		"X cancels at exact paid physical progress")
	_check(level.hypha_nodes.get_child_count() == mature_count,
		"Cancel preserves existing mature nodes without minting an unpaid endpoint")
	var stump: Node2D = null
	for node in level.network_system.get_registered_nodes():
		if not node is MotherCore and not node is HyphaNode:
			stump = node
	_check(stump != null and stump.global_position.is_equal_approx(before.tip_position),
		"Paid partial edge retains a registered inert endpoint")
	if stump != null:
		_check(level.fungal_field.get_effective_radius(stump) == 0.0,
			"Cancelled partial endpoint never contributes mature coverage")
	_check(level.mother_core.nutrition + after.consumed_nutrition == 72,
		"Cancel refunds every unconsumed growth nutrient exactly once")
	_press(KEY_X)
	await _wait_frames(120)
	_check(level.hypha_nodes.get_child_count() == mature_count and level.mother_core.nutrition + after.consumed_nutrition == 72,
		"Repeated cancel and waiting do not mint nodes or double-refund")
	await _remove_level(level)


func _test_starvation_and_recovery() -> void:
	var level := await _new_level()
	level.mother_core.try_spend_nutrition(level.mother_core.nutrition)
	_press(KEY_G)
	_push_click(Vector2(860, 400))
	await _wait_frames(180)
	var snapshot: Dictionary = level.growth_system.get_task_snapshot()
	_check(snapshot.state == &"waiting" and snapshot.distance == 0.0,
		"No core balance keeps a placed target waiting without growth")
	_check(snapshot.wait_reason == &"core_empty", "Task reports an actual empty-core wait reason")
	_check(level.hud.growth_label.text.contains("等待"), "HUD reflects starvation")
	level.mother_core.add_nutrition(5)
	await _wait_completion(level, 2400)
	_check(level.mother_core.nutrition == 0 and level.growth_system.get_task_snapshot().consumed_nutrition == 5,
		"Replenished nutrition travels and pays exact 80-pixel cost")
	await _remove_level(level)


func _test_restart_during_transport() -> void:
	var level := await _new_level()
	level.growth_supply_system.auto_supply = false
	_press(KEY_G)
	_push_click(Vector2(1080, 400))
	_check(level.growth_supply_system.try_dispatch(), "Restart fixture has debited live transport")
	_press(KEY_R)
	await _wait_frames(4)
	var restarted := current_scene as Node2D
	_check(is_instance_valid(restarted) and restarted != level, "R reloads the scene during growth transport")
	_check(restarted.growth_system.get_task_snapshot().state == &"idle",
		"Restart has no old active target")
	_check(restarted.growth_supply_system.get_in_transit_count() == 0 and restarted.growth_supply_system.get_shipment_records().is_empty(),
		"Restart has no old shipments or accounting ledger")
	_check(restarted.mother_core.nutrition == 72 and restarted.network_system.get_registered_nodes().size() == 4,
		"Restart restores exact initial balance and network")
	_check(restarted.get_node("World/GrowthTargets").get_child_count() == 0,
		"Restart removes the old target marker")
	await _remove_level(restarted)


func _test_growth_pause_keeps_combat_and_recycling() -> void:
	var level := await _new_level(true)
	_press(KEY_G)
	_push_click(Vector2(1080, 400))
	_press(KEY_P)
	var shots: Array[int] = [0]
	for weapon: SporeWeapon in level.get_weapons():
		weapon.shot_fired.connect(func(_enemy: BasicEnemy) -> void: shots[0] += 1)
	for frame in range(5000):
		if level.colony_progress.get_total_recovered() == 24:
			break
		await physics_frame
	await process_frame
	_check(not paused and level.growth_system.get_task_snapshot().state == &"paused",
		"Only the growth task is paused, never the scene tree")
	_check(level.growth_system.get_task_snapshot().distance == 0.0,
		"Paused growth remains stationary for the entire battle")
	_check(shots[0] == 12 and level.digestive_organ.digested_count == 6,
		"Both attack organs fire and all six remains are recycled while growth is paused")
	_check(level.digestive_organ.total_nutrition_produced == 24 and level.mother_core.health > 0,
		"Paused growth allows the full surviving colony resource loop")
	_press(KEY_X)
	_check(level.growth_system.get_task_snapshot().state == &"cancelled", "Paused target can be cancelled after battle")
	await _remove_level(level)


func _test_growth_during_full_battle() -> void:
	var level := await _new_level(true)
	var shots: Array[int] = [0]
	for weapon: SporeWeapon in level.get_weapons():
		weapon.shot_fired.connect(func(_enemy: BasicEnemy) -> void: shots[0] += 1)
	_press(KEY_G)
	_push_click(Vector2(1080, 400))
	for frame in range(7000):
		if level.colony_progress.get_total_recovered() == 24 and level.growth_system.get_task_snapshot().state == &"completed":
			break
		await physics_frame
	await _wait_frames(180)
	var snapshot: Dictionary = level.growth_system.get_task_snapshot()
	_check(snapshot.state == &"completed" and snapshot.consumed_nutrition == 16,
		"Growth completes with live combat and resource recycling")
	_check(shots[0] == 12 and level.digestive_organ.digested_count == 6 and level.mother_core.health > 0,
		"Real two-organ combat remains supplied during growth")
	var inventory: int = 0
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		inventory += organ.nutrition + organ.incoming_nutrition
	var accounted: int = level.mother_core.nutrition + inventory + shots[0] + snapshot.consumed_nutrition \
		+ snapshot.buffered_nutrition + level.growth_supply_system.get_in_transit_count() + level.digestive_organ.get_output_nutrition()
	_check(accounted == 80 + level.digestive_organ.total_nutrition_produced,
		"Combined core, organs, prepaid transit, growth and shots conserve all nutrition")
	await _remove_level(level)
