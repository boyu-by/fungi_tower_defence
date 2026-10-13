extends SceneTree
## 验证尸体资源从死亡、领取、运输到消化的完整生命周期。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")

var failures: Array[String] = []
var checks: int = 0
var cycle_result: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_death_and_delayed_income()
	await _test_interruptions_and_configuration()
	await _test_capacity_and_core_connection()
	await _test_receiver_loss_and_restart()
	await _test_default_cycle()
	print("RECYCLING_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cycle": cycle_result
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_level() -> Node2D:
	var level := LEVEL_SCENE.instantiate() as Node2D
	level.expansion_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	root.add_child(level)
	current_scene = level
	await physics_frame
	await process_frame
	level.supply_system.get_node("DispatchTimer").stop()
	for current_weapon in level.get_weapons():
		current_weapon.get_node("FireTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.nutrition_return_system.auto_return = false
	# 本组验证物流而非展开动画：使用成熟的 110/140 覆盖，不再使用旧 320 回收半径。
	level.fungal_field.advance(1.0)
	return level


func _remove_level(level: Node2D) -> void:
	level.queue_free()
	await process_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame


func _add_remains(level: Node2D, position: Vector2) -> EnemyRemains:
	var remains := REMAINS_SCENE.instantiate() as EnemyRemains
	level.get_node("World/Remains").add_child(remains)
	remains.global_position = position
	return remains


func _wait_for_transport(level: Node2D) -> void:
	for frame in range(420):
		if level.recycling_system.get_in_transit_count() == 0:
			break
		await physics_frame
	await _wait_frames(2)
	_check(level.recycling_system.get_in_transit_count() == 0, "Remains transport timed out")
	_check(level.get_node("World/RecoveryPackets").get_child_count() == 0, "Finished packet remained")


func _wait_for_income(level: Node2D, expected_total: int) -> void:
	level.nutrition_return_system.auto_return = true
	for frame in range(900):
		if level.colony_progress.get_total_recovered() == expected_total:
			break
		await physics_frame
	await _wait_frames(2)
	_check(level.colony_progress.get_total_recovered() == expected_total,
		"Actual return reached the core before timeout")


func _test_death_and_delayed_income() -> void:
	var level := await _new_level()
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.mother_core = level.mother_core
	enemy.move_speed = 0.0
	level.get_node("World/Enemies").add_child(enemy)
	enemy.global_position = level.attack_organ.get_parent().global_position + Vector2(80, 0)
	var death_position := enemy.global_position
	enemy.take_damage(999)
	enemy.take_damage(999)
	var remains := level.get_node("World/Remains").get_child(0) as EnemyRemains
	_check(level.get_node("World/Remains").get_child_count() == 1, "Repeated death created extra remains")
	_check(remains.global_position == death_position and remains.nutrition_value == 4,
		"Remains did not preserve death position and value")
	level.digestive_organ.digest_timer.wait_time = 5.0
	_check(level.recycling_system.try_dispatch(), "Available remains were not collected")
	_check(not level.recycling_system.try_dispatch(), "Remains were claimed twice")
	_check(not remains.visible and not remains.is_available(), "Claimed remains still available")
	_check(level.digestive_organ.incoming_remains == 1, "Destination was not reserved")
	_check(level.mother_core.nutrition == 72 and level.digestive_organ.get_queued_count() == 0,
		"Income or storage was credited before arrival")
	var packet := level.get_node("World/RecoveryPackets").get_child(0) as RemainsPacket
	await _wait_frames(12)
	_check(packet.global_position.distance_to(level.attack_organ.get_parent().global_position) < 80.0,
		"Pickup packet did not move to frontline node")
	await _wait_for_transport(level)
	_check(not is_instance_valid(remains), "Delivered remains were not removed")
	_check(level.digestive_organ.get_queued_count() == 1 and level.digestive_organ.incoming_remains == 0,
		"Delivery did not enter digestive queue")
	_check(level.mother_core.nutrition == 72, "Arrival bypassed digestion")
	level.digestive_organ.digest_timer.start(0.1)
	await _wait_frames(18)
	_check(level.mother_core.nutrition == 72 and level.colony_progress.get_total_recovered() == 0
		and level.digestive_organ.digested_count == 1 and level.digestive_organ.get_output_nutrition() == 4,
		"Digestion must produce four pending nutrients without early income")
	await _wait_for_income(level, 4)
	_check(level.mother_core.nutrition == 76, "Only real return credits four nutrition")
	await _wait_frames(18)
	_check(level.mother_core.nutrition == 76, "Digestion credited twice")
	var alive_enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	level.get_node("World/Enemies").add_child(alive_enemy)
	alive_enemy.queue_free()
	await _wait_frames(2)
	_check(level.get_node("World/Remains").get_child_count() == 0, "Removing live enemy created remains")
	await _remove_level(level)


func _test_interruptions_and_configuration() -> void:
	var level := await _new_level()
	var system: RecyclingSystem = level.recycling_system
	var remains := _add_remains(level, level.attack_organ.get_parent().global_position + Vector2(20, 0))
	# 切掉母核到后方的旁路，确保测试的是所有通路都断开，而非仅指定直连失效。
	level.digestive_organ.core_edge.end_node = null
	var return_edge := level.get_node("World/Colony/Connections/RecoveryEdge") as HyphaEdge
	var endpoint: Node2D = return_edge.end_node
	return_edge.end_node = null
	_check(not system.try_dispatch(), "Disconnected route accepted shipment")
	_check(remains.is_available() and level.digestive_organ.incoming_remains == 0,
		"Rejected route claimed resource")
	return_edge.end_node = endpoint
	_check(system.try_dispatch(), "Restored route rejected shipment")
	await _wait_frames(24)
	var packet := level.get_node("World/RecoveryPackets").get_child(0) as RemainsPacket
	var drop_position := packet.global_position
	return_edge.end_node = null
	await _wait_for_transport(level)
	_check(remains.is_available() and remains.visible, "Interrupted remains did not return to ground")
	_check(remains.global_position.distance_to(drop_position) < 0.01, "Remains dropped at wrong position")
	_check(level.mother_core.nutrition == 72 and level.digestive_organ.incoming_remains == 0,
		"Interruption credited income or leaked reservation")
	return_edge.end_node = endpoint
	system.try_dispatch()
	packet = level.get_node("World/RecoveryPackets").get_child(0) as RemainsPacket
	packet.cancel_transport()
	packet.cancel_transport()
	await _wait_for_transport(level)
	_check(system.interrupted_count == 2 and remains.is_available(), "Cancellation settled more than once")
	system.try_dispatch()
	level.get_node("World/RecoveryPackets").get_child(0).queue_free()
	await _wait_for_transport(level)
	_check(system.interrupted_count == 3 and level.digestive_organ.incoming_remains == 0,
		"Forced removal leaked reservation")
	system.packet_scene = load("res://scenes/colony/hypha_node.tscn") as PackedScene
	_check(not system.try_dispatch(), "Incorrect packet scene accepted")
	_check(remains.is_available() and remains.visible and level.digestive_organ.incoming_remains == 0,
		"Incorrect packet scene lost resource")
	await _remove_level(level)


func _test_capacity_and_core_connection() -> void:
	var level := await _new_level()
	var organ: DigestiveOrgan = level.digestive_organ
	organ.capacity = 2
	organ.digest_timer.wait_time = 5.0
	var source: Vector2 = level.attack_organ.get_parent().global_position
	for offset in [10.0, 20.0, 30.0]:
		_add_remains(level, source + Vector2(offset, 0))
	_check(level.recycling_system.try_dispatch() and level.recycling_system.try_dispatch(),
		"Two available slots rejected shipments")
	_check(not level.recycling_system.try_dispatch(), "Incoming reservations exceeded capacity")
	_check(organ.incoming_remains == 2, "Incoming reservations were miscounted")
	await _wait_for_transport(level)
	_check(organ.get_queued_count() == 2, "Queued inventory was miscounted")
	_check(not level.recycling_system.try_dispatch(), "Full queue accepted another corpse")
	var endpoint: Node2D = organ.core_edge.end_node
	var alternate: HyphaEdge = level.get_node("World/Colony/Connections/RecoveryEdge")
	var alternate_endpoint: Node2D = alternate.end_node
	organ.core_edge.end_node = null
	alternate.end_node = null
	organ.digest_timer.start(0.1)
	await _wait_frames(24)
	_check(organ.get_queued_count() == 0 and organ.get_output_count() == 2
		and organ.get_output_nutrition() == 8 and level.mother_core.nutrition == 72,
		"Disconnected stomach processes received corpses into bounded uncredited outputs")
	organ.core_edge.end_node = endpoint
	alternate.end_node = alternate_endpoint
	await _wait_for_income(level, 8)
	_check(organ.get_queued_count() == 0 and level.mother_core.nutrition == 80,
		"Restored network returns retained products to the core")
	_check(level.recycling_system.try_dispatch(), "Released capacity did not allow new shipment")
	await _wait_for_transport(level)
	await _wait_for_income(level, 12)
	_check(organ.digested_count == 3 and level.mother_core.nutrition == 84,
		"Batch resource conservation failed")
	await _remove_level(level)


func _test_receiver_loss_and_restart() -> void:
	var level := await _new_level()
	var original: DigestiveOrgan = level.digestive_organ
	var remains := _add_remains(level, level.attack_organ.get_parent().global_position)
	level.recycling_system.try_dispatch()
	var other := DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	level.add_child(other)
	level.recycling_system.digestive_organ = other
	await _wait_for_transport(level)
	_check(original.get_queued_count() == 1 and other.get_queued_count() == 0,
		"Changing configuration redirected existing shipment")
	await _remove_level(level)

	level = await _new_level()
	remains = _add_remains(level, level.attack_organ.get_parent().global_position)
	level.recycling_system.try_dispatch()
	level.digestive_organ.queue_free()
	await _wait_for_transport(level)
	_check(remains.is_available() and remains.visible and level.mother_core.nutrition == 72,
		"Removed receiver lost remains or credited income")
	await _remove_level(level)

	level = await _new_level()
	_add_remains(level, level.attack_organ.get_parent().global_position)
	level.recycling_system.try_dispatch()
	var event := InputEventKey.new()
	event.keycode = KEY_R
	event.pressed = true
	root.push_input(event)
	event = InputEventKey.new()
	event.keycode = KEY_R
	root.push_input(event)
	await process_frame
	await process_frame
	await physics_frame
	_check(not is_instance_valid(level), "Restart kept previous recycling scene")
	level = current_scene as Node2D
	level.enemy_spawner.stop_spawning()
	_check(level.mother_core.nutrition == 72 and level.digestive_organ.incoming_remains == 0,
		"Restart inherited nutrition or reservations")
	_check(level.get_node("World/Remains").get_child_count() == 1 and
		level.has_node("World/Remains/ExpansionRemains") and
		level.get_node("World/RecoveryPackets").get_child_count() == 0, "Restart inherited recycling objects")
	_check(level.colony_progress.get_total_recovered() == 0 and level.digestive_organ.get_output_count() == 0
		and level.nutrition_return_system.get_in_transit_count() == 0, "Restart clears output, returns and recovered statistics")
	await _remove_level(level)


func _test_default_cycle() -> void:
	var level := LEVEL_SCENE.instantiate() as Node2D
	level.expansion_demo_enabled = false
	root.add_child(level)
	current_scene = level
	var shots := [0]
	var combat_cost := [0]
	var initial_resources: int = level.mother_core.nutrition
	for organ in level.supply_system.get_registered_organs():
		initial_resources += organ.nutrition
	for current_weapon in level.get_weapons():
		current_weapon.volley_committed.connect(func(_shot_id: String, spent: int, _count: int) -> void:
			shots[0] += 1
			combat_cost[0] += spent)
	for frame in range(2400):
		if level.colony_progress.get_total_recovered() == 24 or level.mother_core.health == 0:
			break
		await physics_frame
	await _wait_frames(180)
	_check(level.enemy_spawner.defeated_count == 6, "Default cycle did not defeat six enemies")
	_check(level.recycling_system.delivered_count == 6 and level.digestive_organ.digested_count == 6,
		"Default cycle did not recover and digest all six")
	_check(level.digestive_organ.total_nutrition_produced == 24, "Default cycle produced wrong income")
	_check(level.colony_progress.get_total_recovered() == 24 and level.digestive_organ.get_output_nutrition() == 0,
		"Every default-cycle product actually returned exactly once")
	var stored: int = 0
	for organ in level.supply_system.get_registered_organs():
		stored += organ.nutrition
	_check(level.mother_core.nutrition + stored + level.supply_system.get_in_transit_count() + combat_cost[0]
		== initial_resources + level.digestive_organ.total_nutrition_produced,
		"Full cycle conservation failed across all organs")
	_check(level.get_node("World/Remains").get_child_count() == 0 and
		level.get_node("World/RecoveryPackets").get_child_count() == 0, "Full cycle left remains or packets")
	_check(level.digestive_organ.get_queued_count() == 0 and
		level.digestive_organ.incoming_remains == 0, "Full cycle left digestive reservations")
	_check(level.hud.recovery_label.text.contains("累计回收：+24"), "HUD missed independently recovered nutrition")
	cycle_result = {
		"defeated": level.enemy_spawner.defeated_count,
		"digested": level.digestive_organ.digested_count,
		"income": level.digestive_organ.total_nutrition_produced,
		"shots": shots[0], "nutrition_spent": combat_cost[0], "core_balance": level.mother_core.nutrition
	}
	await _remove_level(level)
	_check(root.get_child_count() == 0, "Recycling teardown left orphan nodes")
