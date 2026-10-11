extends SceneTree
## 集成验证：使用真实关卡、物理帧和输入，检查供养资源不会增加、丢失或重复结算。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_delivery_and_auto_supply()
	await _test_cancellation_and_rejection()
	await _test_receiver_loss()
	await _test_dispatch_record_ownership()
	await _test_input_and_restart()
	print("SUPPLY_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
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
	return level


func _remove_level(level: Node2D) -> void:
	level.queue_free()
	await process_frame
	await process_frame


func _press_key(key: Key, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	event.echo = echo
	root.push_input(event)
	var release := InputEventKey.new()
	release.keycode = key
	root.push_input(release)


func _click_at(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = point
	event.global_position = point
	event.pressed = true
	root.push_input(event)
	await physics_frame
	await process_frame
	event = event.duplicate() as InputEventMouseButton
	event.pressed = false
	root.push_input(event)
	await physics_frame
	await process_frame


func _wait_until_empty(level: Node2D) -> void:
	for frame in range(240):
		if level.supply_system.get_in_transit_count() == 0:
			break
		await physics_frame
	await process_frame
	await process_frame
	_check(level.supply_system.get_in_transit_count() == 0, "Transport timed out")
	_check(level.get_node("World/Packets").get_child_count() == 0, "Finished packets remain")


func _check_state(level: Node2D, balance: int, stored: int, incoming: int, context: String) -> void:
	_check(level.mother_core.nutrition == balance, context + ": core balance")
	_check(level.attack_organ.nutrition == stored, context + ": local stock")
	_check(level.attack_organ.incoming_nutrition == incoming, context + ": reserved stock")
	_check(level.supply_system.get_in_transit_count() == incoming, context + ": active shipments")


func _test_delivery_and_auto_supply() -> void:
	var level := await _new_level()
	_check_state(level, 72, 4, 0, "Initial")
	_press_key(KEY_N, true)
	_check_state(level, 72, 4, 0, "Echo input ignored")
	_press_key(KEY_N)
	_press_key(KEY_N)
	_press_key(KEY_N)
	_check_state(level, 70, 4, 2, "Capacity includes incoming stock")
	_check(level.hud.stock_label.text.contains("母核营养：70"), "HUD missed debit")
	_check(level.hud.transport_label.text.contains("在途 2"), "HUD missed shipments")
	var packet := level.get_node("World/Packets").get_child(0) as NutrientPacket
	_check(packet.global_position == level.mother_core.global_position, "Packet start position")
	for frame in range(12):
		await physics_frame
	_check(packet.progress > 0.0 and packet.progress < 1.0, "Packet did not move physically")

	# 父节点与端点移动后，包仍须走在画出的连接线上。
	level.get_node("World").position = Vector2(35, 17)
	level.get_node("World/Packets").position = Vector2(40, -15)
	level.attack_organ.get_parent().position = Vector2(700, 300)
	await physics_frame
	await process_frame
	await process_frame
	var edge: HyphaEdge = level.supply_system.supply_edge
	var vein := edge.get_node("Vein") as Line2D
	var closest := Geometry2D.get_closest_point_to_segment(
		packet.global_position, vein.to_global(vein.points[0]), vein.to_global(vein.points[1])
	)
	_check(closest.distance_to(packet.global_position) < 0.01, "Packet left vein after transforms")
	await _wait_until_empty(level)
	_check_state(level, 70, 6, 0, "Arrival")
	_check(level.supply_system.delivered_packets == 2, "Arrival counted more than once")
	_check(level.attack_organ.inventory_slots.get_child(5).color == AttackOrgan.STORED_COLOR,
		"Inventory slots did not fill")
	for press in range(4):
		_press_key(KEY_E)
	_check_state(level, 70, 2, 0, "Consumption")
	level.supply_system.get_node("DispatchTimer").start()
	for frame in range(240):
		if level.attack_organ.nutrition == 3 and level.supply_system.get_in_transit_count() == 0:
			break
		await physics_frame
	_check_state(level, 69, 3, 0, "Automatic refill")
	for frame in range(48):
		await physics_frame
	level.supply_system.get_node("DispatchTimer").stop()
	_check_state(level, 69, 3, 0, "No refill above target")
	_check(level.mother_core.nutrition + level.attack_organ.nutrition + 4 == 76,
		"Conservation after consuming four")
	await _remove_level(level)


func _test_cancellation_and_rejection() -> void:
	var level := await _new_level()
	# 第二阶段可经后方绕行；本用例同时禁用旁路，继续验证真正断网的退款约束。
	level.get_node("World/Colony/Connections/RecoveryEdge").end_node = null
	var supply: SupplySystem = level.supply_system
	var packets := level.get_node("World/Packets")
	_check(level.mother_core.try_spend_nutrition(72), "Unable to exhaust test balance")
	_check(not supply.request_supply(), "Empty core dispatched a packet")
	_check_state(level, 0, 4, 0, "Insufficient balance rollback")
	level.mother_core.add_nutrition(72)
	var endpoint: Node2D = supply.supply_edge.end_node
	supply.supply_edge.end_node = null
	_check(not supply.request_supply(), "Missing endpoint allowed dispatch")
	_check_state(level, 72, 4, 0, "Missing endpoint")
	supply.supply_edge.end_node = endpoint
	_check(supply.request_supply(), "Valid supply was rejected")
	supply.supply_edge.end_node = null
	await _wait_until_empty(level)
	_check_state(level, 72, 4, 0, "Interrupted connection refunded")
	supply.supply_edge.end_node = endpoint
	supply.request_supply()
	var packet := packets.get_child(0) as NutrientPacket
	packet.cancel_transport()
	packet.cancel_transport()
	await _wait_until_empty(level)
	_check_state(level, 72, 4, 0, "Repeated cancellation refunded once")
	supply.request_supply()
	packets.get_child(0).queue_free()
	await _wait_until_empty(level)
	_check_state(level, 72, 4, 0, "Forced packet removal refunded")
	_check(supply.interrupted_packets == 3, "Cancellation count was duplicated")
	supply.packet_scene = load("res://scenes/colony/hypha_node.tscn") as PackedScene
	_check(not supply.request_supply(), "Incorrect packet scene was accepted")
	_check_state(level, 72, 4, 0, "Incorrect packet scene rollback")
	_check(packets.get_child_count() == 0, "Incorrect packet instance leaked into container")
	await _remove_level(level)


func _test_receiver_loss() -> void:
	var level := await _new_level()
	var source: MotherCore = level.mother_core
	var supply: SupplySystem = level.supply_system
	supply.request_supply()
	level.attack_organ.queue_free()
	await _wait_until_empty(level)
	_check(source.nutrition == 72, "Removed receiver did not refund source")
	_check(supply.interrupted_packets == 1 and supply.delivered_packets == 0,
		"Removed receiver was counted as delivered")
	await _remove_level(level)


func _test_dispatch_record_ownership() -> void:
	var level := await _new_level()
	var original_source: MotherCore = level.mother_core
	var original_receiver: AttackOrgan = level.attack_organ
	var supply: SupplySystem = level.supply_system
	supply.request_supply()
	var other_source := CORE_SCENE.instantiate() as MotherCore
	var other_receiver := ORGAN_SCENE.instantiate() as AttackOrgan
	level.add_child(other_source)
	level.add_child(other_receiver)
	supply.mother_core = other_source
	supply.target_organ = other_receiver
	await _wait_until_empty(level)
	_check(original_source.nutrition == 71 and original_receiver.nutrition == 5,
		"Shipment failed to settle with original owners")
	_check(other_source.nutrition == 72 and other_receiver.nutrition == 4,
		"Configuration change redirected an existing shipment")
	_check(not supply.request_supply(), "Mismatched route allowed new dispatch")
	await _remove_level(level)


func _test_input_and_restart() -> void:
	var level := await _new_level()
	var node := level.attack_organ.get_parent() as HyphaNode
	await _click_at(level.attack_organ.global_position + Vector2(0, -32))
	_check(level.selected_node == node, "Organ cap click did not select host node")
	_check(node.selection_ring.visible, "Selection ring did not appear")
	_press_key(KEY_ESCAPE)
	_check(level.selected_node == null and not node.selection_ring.visible, "Esc did not clear")
	await _click_at(node.global_position)
	await _click_at(node.global_position, MOUSE_BUTTON_RIGHT)
	_check(level.selected_node == null, "Right click did not clear")
	var depleted_count := [0]
	level.mother_core.depleted.connect(func() -> void: depleted_count[0] += 1)
	for press in range(9):
		_press_key(KEY_H)
	_check(level.mother_core.health == 0 and depleted_count[0] == 1, "Damage regression")
	_check(not level.supply_system.request_supply(), "Dead core dispatched")
	_check_state(level, 72, 4, 0, "Dead core rollback")
	_press_key(KEY_R)
	await process_frame
	await process_frame
	await physics_frame
	level = current_scene as Node2D
	level.supply_system.get_node("DispatchTimer").stop()
	_check_state(level, 72, 4, 0, "Restart")
	_press_key(KEY_N)
	_press_key(KEY_R)
	await process_frame
	await process_frame
	await physics_frame
	level = current_scene as Node2D
	level.supply_system.get_node("DispatchTimer").stop()
	_check_state(level, 72, 4, 0, "Restart with active shipment")
	_press_key(KEY_N)
	await _remove_level(level)
	_check(root.get_child_count() == 0, "Scene teardown left an orphan node")
