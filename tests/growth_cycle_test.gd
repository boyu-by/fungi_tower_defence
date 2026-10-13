extends SceneTree
## 真实关卡验收：付费扩张、菌域采集、尸体运输、产物返运和累计入账。
## 只推进场景帧；生长和消化收入都必须经过实际运输包。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const TARGET: Vector2 = Vector2(1100, 400)
const REMAINS_POSITION: Vector2 = Vector2(1120, 420)
const EXPECTED_JUNCTIONS: Array[Vector2] = [
	Vector2(900, 400), Vector2(1020, 400), Vector2(1100, 400),
]
const SAMPLE_NUTRITION: int = 4
const GROWTH_COST: int = 16

var checks: int = 0
var failures: Array[String] = []
var conservation_checks: int = 0
var milestones: Array[Dictionary] = []
var cycle_result: Dictionary = {}
var cancellation_result: Dictionary = {}
var restart_result: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_expansion_recovery_and_restart()
	await _test_cancel_during_growth_transport()
	await _test_cancel_partial_growth()
	_check(root.get_child_count() == 0, "Cycle teardown leaves no scene objects")
	print("GROWTH_CYCLE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures,
		"conservation_checks": conservation_checks, "milestones": milestones,
		"cycle": cycle_result, "cancellation": cancellation_result,
		"restart": restart_result,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _new_level() -> Node2D:
	var level := LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level)
	root.add_child(level)
	current_scene = level
	_stop_non_growth_timers(level)
	# 留出接收后、产出前的可观察窗口，仍由胃囊的正常计时器消化。
	level.digestive_organ.digest_timer.wait_time = 1.0
	await _wait_frames(2)
	return level


func _prepare_level(level: Node2D) -> void:
	# 旧单执行器兼容夹具；正式 7.3 多实例路径由 multitip_construction_test 验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	level.expansion_demo_enabled = true
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _stop_non_growth_timers(level: Node2D) -> void:
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _remove_level(level: Node2D) -> void:
	if current_scene == level:
		current_scene = null
	level.queue_free()
	await process_frame
	await process_frame


func _step() -> void:
	# process_frame 紧随本轮物理更新；上轮同步结算和删除已完成。
	await physics_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await _step()


func _press(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	root.push_input(event)
	event = InputEventKey.new()
	event.keycode = key
	root.push_input(event)


func _observe_level(level: Node2D) -> Dictionary:
	var evidence: Dictionary = {
		"shots": 0, "nutrition_spent": 0, "production": [], "arrivals": [], "progress": [],
		"packet_arrivals": [], "packet_interruptions": [],
		"generic_serial": 0, "last_generic_balance": -1,
		"return_packet": null, "retired_growth_consumed": 0,
	}
	var core: Node2D = level.mother_core
	core.nutrition_changed.connect(func(balance: int) -> void:
		evidence["generic_serial"] = int(evidence["generic_serial"]) + 1
		evidence["last_generic_balance"] = balance)
	core.digestion_product_arrived.connect(func(product_id: String, amount: int) -> void:
		var tracked_packet: Variant = evidence["return_packet"]
		var packet_live: bool = is_instance_valid(tracked_packet)
		var packet_position: Vector2 = Vector2.ZERO
		if packet_live:
			packet_position = tracked_packet.global_position
		var arrivals: Array = evidence["arrivals"]
		arrivals.append({
			"product_id": product_id, "nutrition": amount,
			"balance": core.nutrition, "packet_live": packet_live,
			"packet_position": packet_position,
			"generic_serial": int(evidence["generic_serial"]),
			"last_generic_balance": int(evidence["last_generic_balance"]),
		}))
	level.digestive_organ.product_created.connect(func(product_id: String, amount: int) -> void:
		var production: Array = evidence["production"]
		production.append({"product_id": product_id, "nutrition": amount}))
	level.colony_progress.progress_changed.connect(func(total: int, count: int) -> void:
		var progress: Array = evidence["progress"]
		progress.append({"total": total, "count": count}))
	for weapon: SporeWeapon in level.get_weapons():
		weapon.volley_committed.connect(func(_shot_id: String, spent: int, _count: int) -> void:
			evidence["shots"] = int(evidence["shots"]) + 1
			evidence["nutrition_spent"] = int(evidence["nutrition_spent"]) + spent)
	return evidence


func _packet_callbacks(packet: Node2D, owner: Node, signal_name: StringName) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _watch_packet(packet: Node2D, owner: Node, evidence: Dictionary, label: String) -> void:
	var arrived_callbacks := _packet_callbacks(packet, owner, &"arrived")
	var interrupted_callbacks := _packet_callbacks(packet, owner, &"interrupted")
	_check(not arrived_callbacks.is_empty() and not interrupted_callbacks.is_empty(),
		"%s has live arrival and interruption settlement callbacks" % label)
	# 后连接的观察者在系统结算后重放旧回调；不是提前伪造第一次到达。
	packet.connect(&"arrived", func(finished_packet: Node2D) -> void:
		var arrivals: Array = evidence["packet_arrivals"]
		arrivals.append({"label": label, "position": finished_packet.global_position})
		_replay_settled_callbacks(finished_packet, arrived_callbacks, interrupted_callbacks))
	packet.connect(&"interrupted", func(finished_packet: Node2D) -> void:
		var interruptions: Array = evidence["packet_interruptions"]
		interruptions.append({"label": label, "position": finished_packet.global_position})
		_replay_settled_callbacks(finished_packet, arrived_callbacks, interrupted_callbacks))


func _replay_settled_callbacks(packet: Node2D, arrived: Array[Callable], interrupted: Array[Callable]) -> void:
	for callback: Callable in arrived:
		if callback.is_valid():
			callback.call(packet)
			callback.call(packet)
	for callback: Callable in interrupted:
		if callback.is_valid():
			callback.call(packet)
			callback.call(packet)


func _resource_snapshot(level: Node2D, evidence: Dictionary) -> Dictionary:
	var organs: int = 0
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		organs += organ.nutrition + organ.incoming_nutrition
	var originals: int = 0
	for child: Node in level.get_node("World/Remains").get_children():
		# 被领取的原尸体仍保存资源；接收后 queue_free 的原尸体已转入胃囊队列。
		if child is EnemyRemains and not child.is_queued_for_deletion():
			originals += child.nutrition_value
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var parts: Dictionary = {
		"core": int(level.mother_core.nutrition), "organs_and_incoming": organs,
		"growth_buffer": int(growth["buffered_nutrition"]),
		"growth_in_transit": int(level.growth_supply_system.get_in_transit_count()),
		"growth_consumed": int(growth["consumed_nutrition"]) + int(evidence["retired_growth_consumed"]),
		"shots_consumed": int(evidence["nutrition_spent"]),
		"original_remains": originals,
		"digestive_queue": int(level.digestive_organ.get_queued_nutrition()),
		# output 已包括返运在途；产物预留只代表空间，都不能再加一份资源。
		"digestive_output": int(level.digestive_organ.get_output_nutrition()),
	}
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	return parts


func _checkpoint(level: Node2D, evidence: Dictionary, expected: int, label: String,
		remember: bool = true) -> void:
	var parts := _resource_snapshot(level, evidence)
	conservation_checks += 1
	_check(int(parts["total"]) == expected,
		"%s conserves nutrition: expected %d, got %s" % [label, expected, parts])
	_check(int(evidence["shots"]) == 0, "%s keeps the isolated wave disabled" % label)
	var output: Dictionary = level.digestive_organ.get_output_snapshot()
	var returning: Dictionary = level.nutrition_return_system.get_return_snapshot()
	_check(int(output["count"]) == level.digestive_organ.get_output_count()
		and int(output["nutrition"]) == level.digestive_organ.get_output_nutrition(),
		"%s output snapshot matches stored and in-transit products" % label)
	_check(int(output["count"]) + int(output["reserved_count"]) <= 2
		and int(output["nutrition"]) + int(output["reserved_nutrition"]) <= 20
		and int(output["reserved_count"]) >= 0 and int(output["reserved_nutrition"]) >= 0,
		"%s respects output limits including active reservations" % label)
	_check(int(output["queued_count"]) + int(output["in_transit_count"]) == int(output["count"]),
		"%s classifies every outstanding product exactly once" % label)
	_check(int(returning["in_transit_count"]) == level.nutrition_return_system.get_in_transit_count()
		and int(returning["in_transit_nutrition"]) == level.nutrition_return_system.get_in_transit_nutrition()
		and int(returning["queued_count"]) == int(output["queued_count"])
		and int(returning["in_transit_count"]) == int(output["in_transit_count"]),
		"%s return ledger and digestive output agree" % label)
	var product_total: int = 0
	var queued_nutrition: int = 0
	var in_transit_nutrition: int = 0
	var products: Array[Dictionary] = level.digestive_organ.get_output_products()
	for product: Dictionary in products:
		product_total += int(product["nutrition"])
		if StringName(product["status"]) == &"queued":
			queued_nutrition += int(product["nutrition"])
		elif StringName(product["status"]) == &"in_transit":
			in_transit_nutrition += int(product["nutrition"])
		_check(not String(product["product_id"]).is_empty()
			and int(product["source_id"]) == level.digestive_organ.get_instance_id()
			and [&"queued", &"in_transit"].has(StringName(product["status"])),
			"%s exposes a uniquely owned outstanding product" % label)
	_check(products.size() == int(output["count"]) and product_total == int(output["nutrition"]),
		"%s output records neither duplicate nor omit nutrition" % label)
	_check(int(returning["queued_nutrition"]) == queued_nutrition
		and int(returning["in_transit_nutrition"]) == in_transit_nutrition,
		"%s return ledger accounts for queued and in-transit output without another resource copy" % label)
	if remember:
		milestones.append({"phase": label, "expected": expected, "resources": parts})


func _node_ids(level: Node2D) -> Array[int]:
	var ids: Array[int] = []
	for node: Node2D in level.network_system.get_registered_nodes():
		ids.append(node.get_instance_id())
	return ids


func _added_junctions(level: Node2D, original_ids: Array[int]) -> Array[HyphaNode]:
	var nodes: Array[HyphaNode] = []
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and not original_ids.has(node.get_instance_id()):
			nodes.append(node as HyphaNode)
	return nodes


func _place_target(level: Node2D, position: Vector2 = TARGET) -> bool:
	var controller: GrowthInputController = level.growth_input_controller
	var entered: bool = controller.enter_placement_mode()
	_check(entered, "Real growth controller enters placement mode")
	var placed: bool = entered and controller.place_target(position)
	# 正式放置只入队；推进调度后才读取原生长任务身份。
	level.construction_coordinator.pump()
	_check(placed and not controller.is_placing(), "Real growth controller creates the paid expansion task")
	return placed


func _first_growth_packet(level: Node2D) -> NutrientPacket:
	var found: NutrientPacket = null
	for record: Dictionary in level.growth_supply_system.get_shipment_records():
		if not bool(record["settled"]) and is_instance_valid(record["packet"]):
			found = record["packet"] as NutrientPacket
			break
	_check(found != null, "Real growth shipment exposes its live nutrient packet")
	return found


func _wait_packet_movement(packet: Node2D, origin: Vector2, label: String) -> void:
	for frame in range(20):
		await _step()
		if not is_instance_valid(packet) or packet.global_position.distance_to(origin) > 1.0:
			break
	_check(is_instance_valid(packet) and packet.global_position.distance_to(origin) > 1.0,
		"%s physically moves before settlement" % label)


func _wait_growth_completed(level: Node2D, evidence: Dictionary, expected: int,
		original_ids: Array[int], sample: EnemyRemains) -> int:
	var coverage_junctions: int = 0
	var previous_formed: int = 0
	var premature_coverage: bool = false
	for frame in range(6000):
		await _step()
		var growth: Dictionary = level.growth_system.get_task_snapshot()
		var added := _added_junctions(level, original_ids)
		var covered: bool = level.fungal_field.is_covered(REMAINS_POSITION)
		if covered and added.size() < 2 and not premature_coverage:
			premature_coverage = true
			_check(false, "Corpse coverage appeared before two new mature junctions")
		if covered and coverage_junctions == 0:
			coverage_junctions = added.size()
			_check(coverage_junctions >= 2 and sample.is_available(),
				"New mature coverage reaches the unclaimed corpse before pickup")
			_checkpoint(level, evidence, expected, "coverage_before_claim")
		if int(growth["formed_junctions"]) != previous_formed:
			previous_formed = int(growth["formed_junctions"])
			_check(added.size() == previous_formed,
				"Every formed mature junction is registered in the real network")
			_check(sample.is_available() and level.recycling_system.get_in_transit_count() == 0,
				"Expansion has not prematurely claimed or transported the sample")
			if previous_formed == 1:
				_check(not covered and not level.recycling_system.try_dispatch(),
					"One paid new junction cannot reach or claim the distant corpse")
			_checkpoint(level, evidence, expected, "formed_%d_junctions" % previous_formed)
		if frame % 60 == 0:
			_checkpoint(level, evidence, expected, "growth_frame_%d" % frame, false)
		if growth["state"] == &"completed":
			break
	_check(level.growth_system.get_task_snapshot()["state"] == &"completed",
		"Real growth supply completes the expansion before timeout")
	_check(coverage_junctions >= 2 and not premature_coverage,
		"First corpse coverage requires at least two added mature junctions")
	return coverage_junctions


func _check_completed_network(level: Node2D, original_ids: Array[int], original_edges: int) -> void:
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_check(is_equal_approx(float(growth["distance"]), 320.0)
		and is_equal_approx(float(growth["total_distance"]), 320.0)
		and is_equal_approx(float(growth["progress"]), 1.0)
		and int(growth["formed_junctions"]) == 3
		and int(growth["consumed_nutrition"]) == GROWTH_COST,
		"320-pixel expansion forms three junctions for exactly sixteen delivered nutrition")
	_check(int(growth["buffered_nutrition"]) == 0
		and level.growth_supply_system.get_in_transit_count() == 0,
		"Completed growth leaves no unspent buffer or prepaid shipment")
	var added := _added_junctions(level, original_ids)
	_check(added.size() == 3 and level.network_system.get_registered_nodes().size() == original_ids.size() + 3,
		"Completed network has precisely three new mature nodes and no temporary tip")
	_check(level.hypha_edges.get_child_count() == original_edges + 3,
		"Completed expansion preserves exactly three real added edges")
	var start := level.get_node("World/Colony/Nodes/RightNode") as Node2D
	for index in range(EXPECTED_JUNCTIONS.size()):
		var formed: HyphaNode = null
		for node: HyphaNode in added:
			if node.global_position.is_equal_approx(EXPECTED_JUNCTIONS[index]):
				formed = node
		_check(formed != null and level.network_system.is_connected_to_core(formed),
			"Paid junction %s exists and connects to the core" % EXPECTED_JUNCTIONS[index])
		if formed != null:
			var route: NetworkRoute = level.network_system.find_route(start, formed)
			_check(level.network_system.is_route_valid(route) and route.segments.size() == index + 1,
				"New junction is reached through every paid expansion edge")
			for segment: NetworkRoute.Segment in route.segments:
				_check(segment.edge.get_parent() == level.hypha_edges,
					"Expansion route uses a real edge in the level connection container")
	_check(REMAINS_POSITION.distance_to(EXPECTED_JUNCTIONS[0]) > 110.0
		and REMAINS_POSITION.distance_to(EXPECTED_JUNCTIONS[1]) < 110.0,
		"Sample geometry requires the second expansion junction at the normal field radius")


func _haul_sample(level: Node2D, sample: EnemyRemains, evidence: Dictionary,
		expected: int, original_ids: Array[int], label: String) -> int:
	var candidates: Array[Node2D] = level.fungal_field.get_collecting_nodes(sample.global_position)
	_check(not candidates.is_empty() and sample.is_available(), "%s is covered and unclaimed" % label)
	if candidates.is_empty() or not sample.is_available():
		return 0
	var destination: Node2D = level.digestive_organ.get_parent()
	var route: NetworkRoute = level.network_system.find_route(candidates[0], destination)
	var added_on_route: int = 0
	for segment: NetworkRoute.Segment in route.segments:
		if not original_ids.has(segment.start_node.get_instance_id()) and segment.start_node is HyphaNode:
			added_on_route += 1
	_check(level.network_system.is_route_valid(route) and route.segments.size() >= 3 and added_on_route >= 2,
		"%s uses a corpse route through multiple new mature nodes" % label)
	if not level.network_system.is_route_valid(route) or route.segments.size() < 3 or added_on_route < 2:
		return 0
	var dispatched: bool = level.recycling_system.try_dispatch()
	_check(dispatched, "%s launches the real remains packet" % label)
	if not dispatched:
		return 0
	_check(not level.recycling_system.try_dispatch(), "%s cannot claim its corpse twice" % label)
	_check(not sample.visible and not sample.is_available() and not sample.is_queued_for_deletion(),
		"%s keeps the claimed original as the sole in-transit resource owner" % label)
	_check(level.digestive_organ.incoming_remains == 1 and level.digestive_organ.get_queued_count() == 0,
		"%s reserves a corpse slot without early queue entry" % label)
	var packet := level.get_node("World/RecoveryPackets").get_child(0) as RemainsPacket
	_check(packet != null and packet.global_position.is_equal_approx(sample.global_position)
		and packet.edge == route.segments[0].edge,
		"%s starts at the corpse on the chosen real network route" % label)
	if packet == null:
		return 0
	_watch_packet(packet, level.recycling_system, evidence, label)
	var visited: Dictionary[int, bool] = {}
	packet.arrived.connect(func(finished: RemainsPacket) -> void:
		visited[finished.segment_index] = true
		_check(finished.global_position.is_equal_approx(destination.global_position),
			"%s physically arrives at the digestive junction" % label))
	_checkpoint(level, evidence, expected, label + "_claimed")
	await _wait_packet_movement(packet, sample.global_position, label)
	for frame in range(1800):
		if is_instance_valid(packet) and not packet.is_queued_for_deletion():
			var segment_index: int = packet.segment_index
			_check(segment_index >= 0 and segment_index < route.segments.size(),
				"%s packet stays within its fixed multi-edge route" % label)
			if segment_index >= 0 and segment_index < route.segments.size():
				var segment: NetworkRoute.Segment = route.segments[segment_index]
				_check(packet.edge == segment.edge, "%s traverses the expected physical edge" % label)
				if packet.progress > 0.0 or segment_index > 0:
					visited[segment_index] = true
					var expected_position: Vector2 = segment.start_node.global_position.lerp(
						segment.end_node.global_position, packet.progress)
					_check(packet.global_position.distance_to(expected_position) < 0.05,
						"%s packet position follows its current real network segment" % label)
		if level.recycling_system.get_in_transit_count() == 0:
			break
		if frame % 30 == 0:
			_checkpoint(level, evidence, expected, label + "_haul_%d" % frame, false)
		await _step()
	await _wait_frames(2)
	_check(level.recycling_system.get_in_transit_count() == 0 and visited.size() == route.segments.size(),
		"%s visits every real haul segment before completing" % label)
	_check(not is_instance_valid(sample) and level.get_node("World/RecoveryPackets").get_child_count() == 0,
		"%s consumes the original corpse and removes its finished transport" % label)
	_check(level.digestive_organ.get_queued_count() == 1
		and level.digestive_organ.get_queued_nutrition() == SAMPLE_NUTRITION
		and level.digestive_organ.incoming_remains == 0,
		"%s enters the active digestive queue exactly once after arrival" % label)
	var output: Dictionary = level.digestive_organ.get_output_snapshot()
	_check(int(output["reserved_count"]) == 1 and int(output["reserved_nutrition"]) == SAMPLE_NUTRITION,
		"%s reserves output space before starting the real digestion timer" % label)
	_checkpoint(level, evidence, expected, label + "_digesting")
	return route.segments.size()


func _wait_output(level: Node2D, evidence: Dictionary, expected: int, label: String) -> Dictionary:
	for frame in range(900):
		if level.digestive_organ.get_output_count() == 1:
			break
		await _step()
		if frame % 30 == 0:
			_checkpoint(level, evidence, expected, label + "_digestion_%d" % frame, false)
	await _wait_frames(2)
	var products: Array[Dictionary] = level.digestive_organ.get_output_products()
	_check(products.size() == 1 and level.digestive_organ.get_output_nutrition() == SAMPLE_NUTRITION,
		"%s creates exactly one outstanding four-nutrition product" % label)
	var product: Dictionary = {} if products.is_empty() else products[0]
	if not product.is_empty():
		_check(StringName(product["status"]) == &"queued" and int(product["nutrition"]) == SAMPLE_NUTRITION,
			"%s waits in output storage until a real return packet is dispatched" % label)
	var output: Dictionary = level.digestive_organ.get_output_snapshot()
	_check(level.digestive_organ.get_queued_count() == 0 and level.digestive_organ.get_queued_nutrition() == 0
		and int(output["reserved_count"]) == 0 and int(output["reserved_nutrition"]) == 0,
		"%s transfers the active corpse into output without retaining an extra reservation" % label)
	_check(level.nutrition_return_system.get_in_transit_count() == 0
		and level.get_node("World/ReturnPackets").get_child_count() == 0,
		"%s cannot silently dispatch while automatic return is disabled" % label)
	_checkpoint(level, evidence, expected, label + "_produced_not_credited")
	return product


func _launch_return(level: Node2D, product_id: String, evidence: Dictionary,
		expected: int, label: String) -> NutrientPacket:
	var returning: Node = level.nutrition_return_system
	var dispatched: bool = returning.try_dispatch()
	_check(dispatched, "%s dispatches a real product return" % label)
	var packet: NutrientPacket = null
	if dispatched:
		for record: Dictionary in returning.get_shipment_records():
			if String(record["product_id"]) == product_id and StringName(record["status"]) == &"in_transit":
				packet = record["packet"] as NutrientPacket
				var route: NetworkRoute = record["route"] as NetworkRoute
				_check(int(record["nutrition"]) == SAMPLE_NUTRITION
					and level.network_system.is_route_valid(route)
					and route.start_node == level.digestive_organ.get_parent()
					and route.end_node == level.mother_core and not route.segments.is_empty(),
					"%s records the original product and a real stomach-to-core route" % label)
	_check(packet != null and packet.get_parent() == level.get_node("World/ReturnPackets"),
		"%s creates the existing nutrient-packet scene in the return container" % label)
	if packet != null:
		_check(packet.global_position.is_equal_approx(level.digestive_organ.get_parent().global_position),
			"%s starts its physical return at the digestive junction" % label)
		evidence["return_packet"] = packet
		_watch_packet(packet, returning, evidence, label)
	_check(returning.get_in_transit_count() == 1 and returning.get_in_transit_nutrition() == SAMPLE_NUTRITION
		and level.digestive_organ.get_output_count() == 1
		and level.digestive_organ.get_output_nutrition() == SAMPLE_NUTRITION,
		"%s keeps in-transit output outstanding until core acceptance" % label)
	_checkpoint(level, evidence, expected, label + "_in_transit")
	return packet


func _test_expansion_recovery_and_restart() -> void:
	var level := await _new_level()
	var evidence := _observe_level(level)
	var sample := level.get_node("World/Remains/ExpansionRemains") as EnemyRemains
	var initial_core: int = level.mother_core.nutrition
	var initial_ids := _node_ids(level)
	var initial_edges: int = level.hypha_edges.get_child_count()
	var initial_resources: int = int(_resource_snapshot(level, evidence)["total"])
	_check(initial_core == 72 and initial_resources == 84 and initial_ids.size() == 4,
		"Cycle starts with 72 core nutrition, eight organ nutrition and the four-nutrition sample")
	_check(sample != null and sample.global_position.is_equal_approx(REMAINS_POSITION)
		and sample.nutrition_value == SAMPLE_NUTRITION and sample.is_available(),
		"Real level contains the intended distant unclaimed expansion sample")
	_check(not level.fungal_field.is_covered(REMAINS_POSITION) and not level.recycling_system.try_dispatch(),
		"Initial colony cannot cover or claim the expansion sample")
	_check(level.colony_progress.get_total_recovered() == 0 and level.colony_progress.get_product_count() == 0
		and level.mother_core.get_received_product_count() == 0,
		"Starting funds are not recovered nutrition or product arrivals")
	_checkpoint(level, evidence, initial_resources, "initial_unclaimed")
	if sample == null or not _place_target(level):
		await _remove_level(level)
		return
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_check(growth["start_node"] == level.get_node("World/Colony/Nodes/RightNode")
		and int(growth["total_cost"]) == GROWTH_COST and float(growth["total_distance"]) == 320.0
		and float(growth["distance"]) == 0.0 and int(growth["consumed_nutrition"]) == 0
		and level.mother_core.nutrition == initial_core,
		"Controller chooses the right frontier and placement alone creates no investment")
	_check(level.growth_supply_system.try_dispatch(), "Real growth supply debits and dispatches its first nutrient")
	var funding_packet := _first_growth_packet(level)
	_check(level.mother_core.nutrition == initial_core - 1
		and level.growth_supply_system.get_in_transit_count() == 1
		and int(level.growth_system.get_task_snapshot()["buffered_nutrition"]) == 0,
		"Growth funding is prepaid transport, not a receive_nutrition injection")
	_check(level.growth_system.pause_task(), "Growth alone pauses while its real first shipment travels")
	_checkpoint(level, evidence, initial_resources, "growth_first_dispatch")
	if funding_packet != null:
		await _wait_packet_movement(funding_packet, funding_packet.global_position, "growth_funding")
	for frame in range(900):
		if level.growth_supply_system.get_in_transit_count() == 0:
			break
		await _step()
	await _wait_frames(2)
	growth = level.growth_system.get_task_snapshot()
	_check(growth["state"] == &"paused" and int(growth["buffered_nutrition"]) == 1
		and int(growth["consumed_nutrition"]) == 0 and float(growth["distance"]) == 0.0
		and level.growth_supply_system.get_in_transit_count() == 0,
		"First actual arrival enters the paused growth buffer without free extension")
	_checkpoint(level, evidence, initial_resources, "growth_first_actual_arrival")
	level.growth_supply_system.auto_supply = true
	_check(level.growth_system.resume_task(), "Real growth resumes from its physically funded buffer")
	var coverage_junctions: int = await _wait_growth_completed(level, evidence, initial_resources, initial_ids, sample)
	_check_completed_network(level, initial_ids, initial_edges)
	_check(level.mother_core.nutrition == initial_core - GROWTH_COST
		and evidence["arrivals"].is_empty() and level.colony_progress.get_total_recovered() == 0,
		"Every paid growth debit leaves recovered income unchanged")
	_checkpoint(level, evidence, initial_resources, "expanded_network_complete")
	var haul_segments: int = await _haul_sample(level, sample, evidence, initial_resources, initial_ids, "first_corpse")
	_check(level.mother_core.nutrition == initial_core - GROWTH_COST
		and level.colony_progress.get_total_recovered() == 0 and evidence["arrivals"].is_empty(),
		"Corpse collection and digestive arrival cannot credit the core or cumulative income")
	var product: Dictionary = await _wait_output(level, evidence, initial_resources, "first_product")
	if product.is_empty():
		await _remove_level(level)
		return
	var product_id: String = product["product_id"]
	_check(level.digestive_organ.digested_count == 1 and level.digestive_organ.total_nutrition_produced == SAMPLE_NUTRITION
		and evidence["production"].size() == 1 and evidence["production"][0]["product_id"] == product_id,
		"Normal digestion produces one uniquely identified product exactly once")
	_check(level.mother_core.nutrition == initial_core - GROWTH_COST
		and not level.mother_core.has_received_product(product_id)
		and level.mother_core.get_received_product_count() == 0
		and level.colony_progress.get_total_recovered() == 0 and level.colony_progress.get_product_count() == 0
		and evidence["arrivals"].is_empty() and evidence["progress"].is_empty(),
		"Finished production alone creates no core balance, arrival or cumulative credit")
	var cancelled_return := _launch_return(level, product_id, evidence, initial_resources, "cancelled_return")
	if cancelled_return == null:
		await _remove_level(level)
		return
	await _wait_packet_movement(cancelled_return, cancelled_return.global_position, "cancelled_return")
	_check(level.mother_core.nutrition == initial_core - GROWTH_COST
		and not level.mother_core.has_received_product(product_id) and level.colony_progress.get_total_recovered() == 0,
		"Moving return transport still creates no arrival income")
	_checkpoint(level, evidence, initial_resources, "return_moving_not_credited")
	cancelled_return.cancel_transport()
	cancelled_return.cancel_transport()
	await _wait_frames(2)
	var interrupted: Dictionary = level.nutrition_return_system.get_return_snapshot()
	var requeued: Array[Dictionary] = level.digestive_organ.get_output_products()
	_check(int(interrupted["interrupted_count"]) == 1 and int(interrupted["delivered_count"]) == 0
		and int(interrupted["in_transit_count"]) == 0 and int(interrupted["queued_count"]) == 1,
		"Return cancellation and old callback replays settle one interruption only")
	_check(requeued.size() == 1 and String(requeued[0]["product_id"]) == product_id
		and StringName(requeued[0]["status"]) == &"queued"
		and level.mother_core.nutrition == initial_core - GROWTH_COST
		and evidence["arrivals"].is_empty() and level.colony_progress.get_total_recovered() == 0,
		"Interrupted return requeues the same owned product without income or another digestion")
	_checkpoint(level, evidence, initial_resources, "same_product_requeued")
	var successful_return := _launch_return(level, product_id, evidence, initial_resources, "successful_return")
	if successful_return == null:
		await _remove_level(level)
		return
	var generic_before: int = int(evidence["generic_serial"])
	await _wait_packet_movement(successful_return, successful_return.global_position, "successful_return")
	for frame in range(900):
		if level.mother_core.has_received_product(product_id):
			break
		await _step()
		if frame % 30 == 0:
			_checkpoint(level, evidence, initial_resources, "return_frame_%d" % frame, false)
	await _wait_frames(2)
	var completed_return: Dictionary = level.nutrition_return_system.get_return_snapshot()
	_check(level.mother_core.has_received_product(product_id) and level.mother_core.get_received_product_count() == 1
		and level.mother_core.nutrition == initial_core - GROWTH_COST + SAMPLE_NUTRITION,
		"Actual return reaches the core and credits exactly four nutrition once")
	_check(level.colony_progress.has_product(product_id) and level.colony_progress.get_total_recovered() == SAMPLE_NUTRITION
		and level.colony_progress.get_product_count() == 1 and evidence["progress"].size() == 1,
		"Core arrival adds exactly one product and four cumulative recovered nutrition")
	_check(evidence["arrivals"].size() == 1, "One physical product delivery emits exactly one core arrival event")
	if evidence["arrivals"].size() == 1:
		var arrival: Dictionary = evidence["arrivals"][0]
		_check(String(arrival["product_id"]) == product_id and int(arrival["nutrition"]) == SAMPLE_NUTRITION
			and bool(arrival["packet_live"])
			and Vector2(arrival["packet_position"]).is_equal_approx(level.mother_core.global_position),
			"Core arrival event belongs to the live nutrient packet physically at the core")
		_check(int(arrival["generic_serial"]) == generic_before + 1
			and int(arrival["last_generic_balance"]) == int(arrival["balance"]),
			"Core emits generic balance change before its unique product arrival event")
	_check(int(completed_return["delivered_count"]) == 1
		and int(completed_return["delivered_nutrition"]) == SAMPLE_NUTRITION
		and int(completed_return["interrupted_count"]) == 1
		and level.nutrition_return_system.get_in_transit_count() == 0
		and level.digestive_organ.get_output_count() == 0 and level.digestive_organ.get_output_nutrition() == 0
		and level.get_node("World/ReturnPackets").get_child_count() == 0,
		"Arrival callback replay cannot double-credit or leave outstanding output")
	_checkpoint(level, evidence, initial_resources, "actual_return_credited")
	var balance_after: int = level.mother_core.nutrition
	_check(not level.mother_core.accept_digestion_product(product_id, SAMPLE_NUTRITION)
		and not level.colony_progress.record_arrival(product_id, SAMPLE_NUTRITION),
		"Core and cumulative ledgers reject duplicate settlement IDs")
	level.mother_core.digestion_product_arrived.emit(product_id, SAMPLE_NUTRITION)
	await _wait_frames(4)
	_check(level.mother_core.nutrition == balance_after and level.mother_core.get_received_product_count() == 1
		and level.colony_progress.get_total_recovered() == SAMPLE_NUTRITION
		and level.colony_progress.get_product_count() == 1 and evidence["progress"].size() == 1,
		"Replayed arrival event cannot create a second cumulative product")
	_checkpoint(level, evidence, initial_resources, "duplicate_id_and_event_rejected")
	cycle_result = {
		"distance": 320, "growth_cost": GROWTH_COST, "new_junctions": 3,
		"junctions_at_first_coverage": coverage_junctions, "haul_segments": haul_segments,
		"produced": SAMPLE_NUTRITION, "credited": level.colony_progress.get_total_recovered(),
		"product_count": level.colony_progress.get_product_count(),
		"interrupted_returns": int(completed_return["interrupted_count"]),
		"core_balance": balance_after,
	}
	await _restart_with_pending_transports(level, evidence, initial_resources, initial_ids, product_id)


func _restart_with_pending_transports(level: Node2D, evidence: Dictionary,
		initial_resources: int, original_ids: Array[int], credited_id: String) -> void:
	var extra := REMAINS_SCENE.instantiate() as EnemyRemains
	extra.name = "RestartRemains"
	extra.nutrition_value = SAMPLE_NUTRITION
	extra.position = REMAINS_POSITION
	level.get_node("World/Remains").add_child(extra)
	var expected: int = initial_resources + SAMPLE_NUTRITION
	_checkpoint(level, evidence, expected, "restart_additional_original_corpse")
	await _haul_sample(level, extra, evidence, expected, original_ids, "restart_corpse")
	var product: Dictionary = await _wait_output(level, evidence, expected, "restart_product")
	if product.is_empty():
		await _remove_level(level)
		return
	var pending_id: String = product["product_id"]
	_check(pending_id != credited_id and int(product["source_id"]) == level.digestive_organ.get_instance_id(),
		"Second production uses a fresh ID while preserving its digestive source")
	_check(level.colony_progress.get_total_recovered() == SAMPLE_NUTRITION
		and level.colony_progress.get_product_count() == 1 and not level.mother_core.has_received_product(pending_id),
		"Second production leaves only the first actually returned product credited")
	var return_packet := _launch_return(level, pending_id, evidence, expected, "restart_return")
	if return_packet == null:
		await _remove_level(level)
		return
	await _wait_packet_movement(return_packet, return_packet.global_position, "restart_return")
	level.growth_supply_system.auto_supply = false
	if not _place_target(level, Vector2(1100, 540)):
		await _remove_level(level)
		return
	# 新任务快照从零开始；第一段已永久投资的营养仍由验收账本保留。
	evidence["retired_growth_consumed"] = GROWTH_COST
	_check(level.growth_supply_system.try_dispatch(), "Restart fixture launches a debited real growth packet")
	var growth_packet := _first_growth_packet(level)
	if growth_packet != null:
		_watch_packet(growth_packet, level.growth_supply_system, evidence, "restart_growth")
	_check(level.growth_supply_system.get_in_transit_count() == 1
		and level.nutrition_return_system.get_in_transit_count() == 1
		and level.colony_progress.get_total_recovered() == SAMPLE_NUTRITION,
		"R fixture simultaneously owns pending return, prepaid growth and nonzero recovered statistics")
	_checkpoint(level, evidence, expected, "restart_pending_transports")
	var old_return_id: int = return_packet.get_instance_id()
	var old_growth_id: int = 0 if growth_packet == null else growth_packet.get_instance_id()
	var arrivals_before: int = evidence["arrivals"].size()
	root.child_entered_tree.connect(_prepare_reload_child, CONNECT_ONE_SHOT)
	_press(KEY_R)
	for frame in range(30):
		await _step()
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	await _wait_frames(2)
	var restarted := current_scene as Node2D
	_check(is_instance_valid(restarted) and not is_instance_valid(level), "R reload removes the previous real level")
	if not is_instance_valid(restarted) or restarted == level:
		if root.child_entered_tree.is_connected(_prepare_reload_child):
			root.child_entered_tree.disconnect(_prepare_reload_child)
		if is_instance_valid(level):
			await _remove_level(level)
		return
	_stop_non_growth_timers(restarted)
	restarted.get_node("Systems/EnemySpawner").stop_spawning()
	_check(not is_instance_valid(instance_from_id(old_return_id))
		and (old_growth_id == 0 or not is_instance_valid(instance_from_id(old_growth_id))),
		"R removes both old physical packets instead of transferring them to the new level")
	_check(evidence["arrivals"].size() == arrivals_before,
		"Reset cancellation and its stale callback replays never accept the unreturned product")
	_check(restarted.mother_core.nutrition == 72 and restarted.mother_core.get_received_product_count() == 0
		and not restarted.mother_core.has_received_product(credited_id)
		and not restarted.mother_core.has_received_product(pending_id)
		and restarted.colony_progress.get_total_recovered() == 0
		and restarted.colony_progress.get_product_count() == 0,
		"R restores initial balance and clears previously positive arrival and cumulative ledgers")
	var growth: Dictionary = restarted.growth_system.get_task_snapshot()
	_check(growth["state"] == &"idle" and int(growth["consumed_nutrition"]) == 0
		and int(growth["buffered_nutrition"]) == 0
		and restarted.growth_supply_system.get_in_transit_count() == 0
		and restarted.growth_supply_system.get_shipment_records().is_empty(),
		"R clears the old growth target, buffer, in-transit investment and shipment ledger")
	var output: Dictionary = restarted.digestive_organ.get_output_snapshot()
	var returning: Dictionary = restarted.nutrition_return_system.get_return_snapshot()
	_check(restarted.digestive_organ.incoming_remains == 0
		and restarted.digestive_organ.get_queued_count() == 0
		and restarted.digestive_organ.get_queued_nutrition() == 0
		and restarted.digestive_organ.digested_count == 0
		and restarted.digestive_organ.total_nutrition_produced == 0
		and int(output["count"]) == 0 and int(output["nutrition"]) == 0
		and int(output["reserved_count"]) == 0 and int(output["reserved_nutrition"]) == 0,
		"R clears corpse queues, production counters, output products and reservations")
	_check(int(returning["queued_count"]) == 0 and int(returning["in_transit_count"]) == 0
		and int(returning["in_transit_nutrition"]) == 0 and int(returning["delivered_count"]) == 0
		and int(returning["delivered_nutrition"]) == 0 and int(returning["interrupted_count"]) == 0
		and restarted.nutrition_return_system.get_shipment_records().is_empty(),
		"R resets all return accounting instead of inheriting old production or delivery records")
	for path: String in ["World/ReturnPackets", "World/GrowthPackets", "World/RecoveryPackets",
			"World/Packets", "World/GrowthTips", "World/GrowthTargets", "World/Enemies", "World/Projectiles"]:
		_check(restarted.get_node(path).get_child_count() == 0, "R leaves %s free of legacy objects" % path)
	_check(restarted.network_system.get_registered_nodes().size() == 4
		and restarted.hypha_nodes.get_child_count() == 3 and restarted.hypha_edges.get_child_count() == 4,
		"R restores only the original mature network")
	var fresh_sample := restarted.get_node("World/Remains/ExpansionRemains") as EnemyRemains
	_check(restarted.get_node("World/Remains").get_child_count() == 1
		and fresh_sample.is_available() and fresh_sample.visible
		and fresh_sample.nutrition_value == SAMPLE_NUTRITION
		and fresh_sample.global_position.is_equal_approx(REMAINS_POSITION),
		"R restores one fresh demo corpse instead of old claimed or digested originals")
	var fresh_evidence := _observe_level(restarted)
	_checkpoint(restarted, fresh_evidence, initial_resources, "restart_initial_state")
	await _wait_frames(360)
	_check(restarted.mother_core.nutrition == 72 and restarted.colony_progress.get_total_recovered() == 0
		and restarted.mother_core.get_received_product_count() == 0
		and fresh_evidence["arrivals"].is_empty() and fresh_evidence["production"].is_empty(),
		"Waiting beyond the old transport duration creates no ghost arrivals, production or credit")
	_checkpoint(restarted, fresh_evidence, initial_resources, "restart_no_late_credit")
	restart_result = {"core_balance": restarted.mother_core.nutrition,
		"recovered": restarted.colony_progress.get_total_recovered(),
		"products": restarted.colony_progress.get_product_count(), "legacy_packets": 0}
	await _remove_level(restarted)


func _test_cancel_during_growth_transport() -> void:
	var level := await _new_level()
	var evidence := _observe_level(level)
	var expected: int = int(_resource_snapshot(level, evidence)["total"])
	if not _place_target(level):
		await _remove_level(level)
		return
	_check(level.growth_supply_system.try_dispatch(), "Cancel fixture launches a real prepaid growth shipment")
	var packet := _first_growth_packet(level)
	if packet != null:
		_watch_packet(packet, level.growth_supply_system, evidence, "cancel_growth_in_transit")
		await _wait_packet_movement(packet, packet.global_position, "cancel_growth_in_transit")
	_check(level.growth_supply_system.get_in_transit_count() == 1 and level.mother_core.nutrition == 71,
		"Cancellation begins with one real debited nutrient still in transit")
	_checkpoint(level, evidence, expected, "cancel_growth_prepaid")
	_check(level.growth_system.cancel_task(), "Real active growth task accepts cancellation")
	_check(not level.growth_system.cancel_task(), "Already cancelled growth cannot cancel or refund again")
	await _wait_frames(4)
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_check(growth["state"] == &"cancelled" and int(growth["consumed_nutrition"]) == 0
		and int(growth["buffered_nutrition"]) == 0 and float(growth["distance"]) == 0.0
		and level.growth_supply_system.get_in_transit_count() == 0 and level.mother_core.nutrition == 72,
		"Cancel and replayed transport callbacks refund the undelivered nutrient once")
	_check(level.network_system.get_registered_nodes().size() == 4
		and level.hypha_nodes.get_child_count() == 3 and level.get_node("World/GrowthPackets").get_child_count() == 0,
		"Cancelling before paid extension cannot create a mature node or a transport remnant")
	_check(evidence["arrivals"].is_empty() and level.mother_core.get_received_product_count() == 0
		and level.colony_progress.get_total_recovered() == 0 and level.colony_progress.get_product_count() == 0,
		"Growth refund is a balance change and never a digestion-product arrival")
	_checkpoint(level, evidence, expected, "cancel_growth_refunded_once")
	await _wait_frames(180)
	_check(level.mother_core.nutrition == 72 and level.growth_supply_system.get_in_transit_count() == 0,
		"Late growth processing cannot deliver a cancelled nutrient or refund twice")
	_checkpoint(level, evidence, expected, "cancel_growth_no_late_settlement")
	await _remove_level(level)


func _test_cancel_partial_growth() -> void:
	var level := await _new_level()
	var evidence := _observe_level(level)
	var expected: int = int(_resource_snapshot(level, evidence)["total"])
	var original_ids := _node_ids(level)
	if not _place_target(level):
		await _remove_level(level)
		return
	level.growth_supply_system.auto_supply = true
	for frame in range(4000):
		await _step()
		var growing: Dictionary = level.growth_system.get_task_snapshot()
		if int(growing["formed_junctions"]) == 1 and float(growing["distance"]) > 160.0:
			break
		if frame % 60 == 0:
			_checkpoint(level, evidence, expected, "partial_growth_%d" % frame, false)
	var before: Dictionary = level.growth_system.get_task_snapshot()
	_check(int(before["formed_junctions"]) == 1 and float(before["distance"]) > 160.0
		and float(before["distance"]) < 240.0 and int(before["consumed_nutrition"]) > 0,
		"Partial cancel starts with one mature node and a paid unfinished second strand")
	_check(not level.fungal_field.is_covered(REMAINS_POSITION) and not level.recycling_system.try_dispatch(),
		"One mature new node cannot collect the distant corpse before partial cancellation")
	_checkpoint(level, evidence, expected, "partial_growth_before_cancel")
	_check(level.growth_system.cancel_task(), "Partly formed growth accepts cancellation")
	await _wait_frames(4)
	var after: Dictionary = level.growth_system.get_task_snapshot()
	var mature := _added_junctions(level, original_ids)
	_check(after["state"] == &"cancelled" and after["distance"] == before["distance"]
		and int(after["consumed_nutrition"]) == int(before["consumed_nutrition"])
		and int(after["buffered_nutrition"]) == 0 and level.growth_supply_system.get_in_transit_count() == 0,
		"Partial cancellation freezes physical investment and refunds all unconsumed nutrition")
	_check(mature.size() == 1 and level.mother_core.nutrition + int(after["consumed_nutrition"]) == 72,
		"Partial cancellation preserves the paid node without a free second junction or double refund")
	var stump: Node2D = null
	for node: Node2D in level.network_system.get_registered_nodes():
		if not original_ids.has(node.get_instance_id()) and not node is HyphaNode:
			stump = node
	_check(stump != null and stump.global_position.is_equal_approx(before["tip_position"])
		and level.network_system.is_connected_to_core(stump),
		"Paid partial strand ends at the actual registered inert stump")
	if stump != null:
		_check(level.fungal_field.get_effective_radius(stump) == 0.0,
			"Cancelled partial endpoint contributes no mature fungal coverage")
	_check(not level.growth_system.cancel_task(), "Repeated partial cancel cannot repeat settlement")
	_checkpoint(level, evidence, expected, "partial_growth_cancelled")
	await _wait_frames(180)
	_check(_added_junctions(level, original_ids).size() == 1
		and not level.fungal_field.is_covered(REMAINS_POSITION) and not level.recycling_system.try_dispatch()
		and level.digestive_organ.get_queued_count() == 0 and level.digestive_organ.get_output_count() == 0,
		"Cancelled paid strand cannot later mature, claim or digest the out-of-field corpse")
	_check(level.mother_core.nutrition + int(after["consumed_nutrition"]) == 72
		and level.colony_progress.get_total_recovered() == 0 and level.colony_progress.get_product_count() == 0
		and evidence["arrivals"].is_empty(),
		"Partial growth spending and refunds never create cumulative recovery income")
	_checkpoint(level, evidence, expected, "partial_growth_no_late_claim")
	cancellation_result = {"preserved_junctions": mature.size(),
		"paid_distance": after["distance"], "consumed": after["consumed_nutrition"],
		"refunded_core_balance": level.mother_core.nutrition,
		"recovered": level.colony_progress.get_total_recovered()}
	await _remove_level(level)
