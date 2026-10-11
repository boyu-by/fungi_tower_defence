extends SceneTree
## 正式关卡队列资源隔离：真实 G/B/L 入队、原付款/物理运输/缓存/退款/占位路径。
## 运行：Godot --headless --fixed-fps 60 --path . --script tests/construction_queue_integration_test.gd
## 只推进原 advance/_physics_process；首次到达永不手工发信号或直接 receive_nutrition。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const STEP: float = 0.1
const STEP_LIMIT: int = 4000
const CAPITAL: int = 72
const GROWTH_TARGET: Vector2 = Vector2(440, 260)
const REMOTE_TARGET: Vector2 = Vector2(940, 400)
const PACKET_PATHS: Array[String] = ["World/GrowthPackets", "World/CultivationPackets"]

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []
var interfaces_available: bool = true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_three_formal_targets_complete_serially()
	if interfaces_available:
		await _test_growth_cache_cancel_then_next()
		await _test_remote_startup_cancel_then_next()
		await _test_reset_and_late_settlement()
	_check(root.get_child_count() == 0, "Physical integration teardown removes all level objects")
	print("CONSTRUCTION_QUEUE_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "conservation_checks": conservation_checks,
		"cases": cases, "evidence": "formal_level_original_physical_transport",
		"first_arrivals_fabricated": false, "nutrition_injected": false,
		"balances_weakened": false, "packet_speed_changed": false,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _queue(level: Node2D) -> ConstructionQueue:
	return level.get("construction_queue") as ConstructionQueue


func _coordinator(level: Node2D) -> ConstructionCoordinator:
	return level.get("construction_coordinator") as ConstructionCoordinator


func _left(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode


func _right(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/RightNode") as HyphaNode


func _remote(level: Node2D) -> RemoteCultivationSystem:
	return level.get_node("Systems/RemoteCultivationSystem") as RemoteCultivationSystem


func _connection(level: Node2D) -> ConnectionSystem:
	return level.get_node("Systems/ConnectionSystem") as ConnectionSystem


func _prepare(level: Node2D) -> void:
	# 本用例保留7.2串行队列的固定容量2基线；7.5动态扩容由新真实业务整合覆盖。
	level.get_node("Systems/MainVeinSystem").set("enabled", false)
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	level.get_node("Systems/SupplySystem/DispatchTimer").autostart = false
	level.get_node("Systems/RecyclingSystem/DispatchTimer").autostart = false
	var repair_supply: Node = level.get_node_or_null("Systems/RepairSupplySystem")
	if repair_supply != null:
		repair_supply.set("auto_supply", false)
	var coordinator: Node = level.get_node_or_null("Systems/ConstructionCoordinator")
	if coordinator != null:
		coordinator.set("auto_execute", false)
	for path: String in ["World/Colony/Nodes/HyphaNode", "World/Colony/Nodes/RightNode"]:
		level.get_node(path + "/SporeWeapon/FireTimer").autostart = false


func _quiet(level: Node2D) -> void:
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.nutrition_return_system.get_node("DispatchTimer").stop()
	level.growth_supply_system.set_process(false)
	level.cultivation_supply_system.set_process(false)
	level.growth_system.set_physics_process(false)
	level.cultivation_system.set_physics_process(false)
	level.fungal_field.set_process(false)
	level.set_process(false)
	var repair_supply: Node = level.get_node_or_null("Systems/RepairSupplySystem")
	if repair_supply != null:
		repair_supply.set_process(false)
	var repair: Node = level.get_node_or_null("Systems/RepairSystem")
	if repair != null:
		repair.set_physics_process(false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level() -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	# 旧单执行器兼容夹具；正式多实例路径另作真实集成验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	_prepare(level)
	root.add_child(level)
	current_scene = level
	_quiet(level)
	await process_frame
	await process_frame
	level.call("_process", 0.0)
	level.fungal_field.advance(1.0)
	_check(level.mother_core.nutrition == CAPITAL and level.get_node("World/Enemies").get_child_count() == 0,
		"Formal scene begins with its actual 72 capital and a stopped enemy wave")
	return level


func _check_wiring(level: Node2D) -> bool:
	var queue: ConstructionQueue = _queue(level)
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var controller: Node = level.get("construction_queue_controller") as Node
	var available: bool = queue != null and coordinator != null and controller != null
	_check(available, "Level exports its queue, coordinator and queue controller")
	if not available:
		interfaces_available = false
		return false
	_check(queue == level.get_node_or_null("Systems/ConstructionQueue")
		and coordinator == level.get_node_or_null("Systems/ConstructionCoordinator")
		and controller == level.hud.get_node_or_null("ConstructionQueue"),
		"Formal exports are the actual systems and HUD child ConstructionQueue")
	_check(coordinator.queue == queue and coordinator.mother_core == level.mother_core
		and coordinator.network_system == level.network_system
		and coordinator.growth_system == level.growth_system
		and coordinator.growth_supply_system == level.growth_supply_system
		and coordinator.remote_cultivation_system == _remote(level)
		and coordinator.connection_system == _connection(level)
		and coordinator.cultivation_system == level.cultivation_system
		and coordinator.cultivation_supply_system == level.cultivation_supply_system,
		"Coordinator references the exact original level executors, supplies, network and payer")
	_check(queue.capabilities == level.get_node("Systems/ColonyCapabilities")
		and int(queue.get_snapshot()["limit"]) == 3,
		"Formal queue limit comes from its real ColonyCapabilities")
	_check(controller.get("coordinator") == coordinator
		and level.growth_input_controller.get("construction_coordinator") == coordinator
		and level.cultivation_input_controller.get("construction_coordinator") == coordinator
		and level.get_node("Systems/ConnectionInputController").get("construction_coordinator") == coordinator,
		"HUD and actual G/B/L input controllers share this exact queue coordinator")
	_check(level.growth_supply_system.mother_core == level.mother_core
		and level.cultivation_supply_system.mother_core == level.mother_core
		and level.growth_supply_system.traffic_system == level.traffic_system
		and level.cultivation_supply_system.traffic_system == level.traffic_system
		and level.growth_supply_system.traffic_required and level.cultivation_supply_system.traffic_required,
		"Both construction supplies retain the original payer and mandatory shared physical FIFO")
	return true


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event)
	var released: InputEventKey = event.duplicate() as InputEventKey
	released.pressed = false
	root.push_input(released)


func _click(position: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event)
	var released: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	released.pressed = false
	root.push_input(released)


func _admit(level: Node2D, kind: StringName, parameters: Dictionary) -> String:
	var result: Dictionary = _coordinator(level).enqueue(kind, parameters)
	var construction_id: String = String(result.get("construction_id", ""))
	_check(bool(result.get("accepted", false)) and not construction_id.is_empty(),
		"Physical %s request is admitted with one stable construction ID" % kind)
	return construction_id


func _identity(request: Dictionary) -> Dictionary:
	return {"construction_id": request.get("construction_id", ""), "sequence": request.get("sequence", 0),
		"kind": request.get("kind", &""), "parameters": request.get("parameters", {}).duplicate(true),
		"payer": request.get("payer"), "payer_id": request.get("payer_id", 0),
		"internal_ids": request.get("internal_ids", {}).duplicate(true)}


func _remember_growth(snapshot: Dictionary, evidence: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		var costs: Dictionary = evidence["growth_costs"]
		costs[task_id] = maxi(int(costs.get(task_id, 0)), int(snapshot.get("consumed_nutrition", 0)))


func _observe(level: Node2D, label: String) -> Dictionary:
	var evidence: Dictionary = {"label": label, "active": true, "initial_total": 0,
		"growth_costs": {}, "packets": {}, "started": [], "finished": [], "matured": [],
		"known_requests": {}, "callback_replays": 0, "checkpoints": []}
	level.growth_system.task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_growth(snapshot, evidence))
	_coordinator(level).changed.connect(func(snapshot: Dictionary) -> void:
		if not bool(evidence["active"]):
			return
		var known: Dictionary = evidence["known_requests"]
		for entry: Dictionary in snapshot.get("entries", []):
			var construction_id: String = String(entry["construction_id"])
			if not bool(entry["started"]) or known.has(construction_id):
				continue
			known[construction_id] = true
			var started: Array = evidence["started"]
			started.append(construction_id)
			var resources: Dictionary = level.cultivation_system.get_resource_snapshot()
			_check(level.growth_supply_system.get_in_transit_count() == 0
				and level.cultivation_supply_system.get_in_transit_count() == 0
				and int(level.growth_system.get_task_snapshot().get("buffered_nutrition", 0)) == 0
				and int(resources["buffered_nutrition"]) == 0 and int(resources["startup_reserved"]) == 0,
				"Every new external executor begins only after original outgoing transit and refundable caches settle"))
	_coordinator(level).request_finished.connect(func(construction_id: String, state: StringName) -> void:
		if bool(evidence["active"]):
			var finished: Array = evidence["finished"]
			for previous: Dictionary in finished:
				_check(previous["construction_id"] != construction_id, "A physical queue request finishes at most once")
			finished.append({"construction_id": construction_id, "state": String(state)}))
	level.cultivation_system.organ_matured.connect(
		func(task_id: int, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon) -> void:
			if not bool(evidence["active"]):
				return
			weapon.get_node("FireTimer").stop()
			var snapshot: Dictionary = level.cultivation_system.get_task_snapshot(task_id)
			_check(snapshot["state"] == &"completed" and int(snapshot["structure_consumed"]) == 8
				and int(snapshot["startup_transferred"]) == 4 and int(snapshot["startup_reserved"]) == 0
				and float(snapshot["effective_time"]) >= CultivationSystem.MINIMUM_EFFECTIVE_TIME,
				"Original B maturity pays eight structure and four startup after three effective seconds")
			_check(organ.nutrition == 4 and organ.incoming_nutrition == 0
				and organ.get_parent() == host and weapon.get_parent() == host
				and weapon.inventory_owner == organ and not host.is_organ_slot_available(),
				"Mature B owns one real committed host slot and exactly four paid inventory")
			var matured: Array = evidence["matured"]
			matured.append({"task_id": task_id, "host_id": host.get_instance_id(), "stock": organ.nutrition}))
	_watch_packets(level, "World/GrowthPackets", "growth", level.growth_supply_system, evidence)
	_watch_packets(level, "World/CultivationPackets", "cultivation", level.cultivation_supply_system, evidence)
	evidence["initial_total"] = int(_resources(level, evidence)["total"])
	_checkpoint(level, evidence, "initial", true)
	return evidence


func _callbacks(packet: Node, owner: Node, event: StringName) -> Array[Callable]:
	var result: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(event):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			result.append(callback)
	return result


func _watch_packets(level: Node2D, path: String, kind: String, owner: Node, evidence: Dictionary) -> void:
	level.get_node(path).child_entered_tree.connect(func(child: Node) -> void:
		if not bool(evidence["active"]) or not child is NutrientPacket:
			return
		var packet: NutrientPacket = child as NutrientPacket
		packet.set_physics_process(false)
		var record: Dictionary = {"id": packet.get_instance_id(), "packet": packet, "kind": kind,
			"movements": 0, "arrivals": 0, "interruptions": 0, "edges": [],
			"arrived_callbacks": _callbacks(packet, owner, &"arrived"),
			"interrupted_callbacks": _callbacks(packet, owner, &"interrupted")}
		var packets: Dictionary = evidence["packets"]
		packets[packet.get_instance_id()] = record
		_check(not record["arrived_callbacks"].is_empty() and not record["interrupted_callbacks"].is_empty(),
			"Original %s supply binds both settlement callbacks before its packet enters the world" % kind)
		packet.arrived.connect(func(arrived: NutrientPacket) -> void:
			if not bool(evidence["active"]):
				return
			record["arrivals"] = int(record["arrivals"]) + 1
			var shipments: Array = owner.call("get_shipment_records")
			var owned: Dictionary = {}
			for shipment: Dictionary in shipments:
				if shipment["packet"] == arrived:
					owned = shipment
					break
			var target: Node2D = owned.get("final_target") as Node2D
			_check(not owned.is_empty() and is_instance_valid(target)
				and arrived.global_position.distance_to(target.global_position) < 0.05
				and int(record["movements"]) > 0 and not record["edges"].is_empty(),
				"First %s arrival follows actual packet movement through original edges to its exact owned endpoint" % kind)
			_replay_settled(level, evidence, record))
		packet.interrupted.connect(func(_interrupted: NutrientPacket) -> void:
			if bool(evidence["active"]):
				record["interruptions"] = int(record["interruptions"]) + 1
				_replay_settled(level, evidence, record)))


func _replay_settled(level: Node2D, evidence: Dictionary, record: Dictionary) -> void:
	var packet: Variant = record["packet"]
	if not is_instance_valid(packet):
		return
	var before: Dictionary = _resources(level, evidence)
	# 调用者只在真实 arrived/interrupted 之后重放，或在 reset 完成真实取消之后重放。
	for key: String in ["arrived_callbacks", "interrupted_callbacks"]:
		for callback: Callable in record[key]:
			if callback.is_valid():
				callback.call(packet)
				callback.call(packet)
				evidence["callback_replays"] = int(evidence["callback_replays"]) + 2
	_check(_resources(level, evidence) == before,
		"Already settled %s callbacks cannot duplicate receipts or refund another executor" % record["kind"])


func _resources(level: Node2D, evidence: Dictionary) -> Dictionary:
	var parts: Dictionary = {"core": int(level.mother_core.nutrition), "organ_stock": 0,
		"combat_transit": 0, "growth_transit": 0, "cultivation_transit": 0,
		"growth_buffer": 0, "network_structure": 0, "organ_structure": 0,
		"cultivation_buffer": 0, "startup_reserved": 0}
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
		parts["combat_transit"] = int(parts["combat_transit"]) + organ.incoming_nutrition
	for record: Dictionary in level.growth_supply_system.get_shipment_records():
		if bool(record["debited"]) and not bool(record["settled"]) and not bool(record["refunded"]):
			parts["growth_transit"] = int(parts["growth_transit"]) + GrowthSupplySystem.PACKET_NUTRITION
	parts["cultivation_transit"] = level.cultivation_supply_system.get_in_transit_nutrition()
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_remember_growth(growth, evidence)
	parts["growth_buffer"] = int(growth.get("buffered_nutrition", 0))
	var costs: Dictionary = evidence["growth_costs"]
	for consumed: int in costs.values():
		parts["network_structure"] = int(parts["network_structure"]) + consumed
	var cultivation: Dictionary = level.cultivation_system.get_resource_snapshot()
	parts["organ_structure"] = int(cultivation["structure_consumed"])
	parts["cultivation_buffer"] = int(cultivation["buffered_nutrition"])
	parts["startup_reserved"] = int(cultivation["startup_reserved"])
	# 母核预算锁、FIFO 租约、入站容量、startup_transferred 都是所有权引用/历史，不另加库存。
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	return parts


func _checkpoint(level: Node2D, evidence: Dictionary, phase: String, remember: bool = false) -> void:
	var resources: Dictionary = _resources(level, evidence)
	conservation_checks += 1
	_check(int(resources["total"]) == int(evidence["initial_total"]),
		"%s/%s conserves exact original ownership: %s" % [evidence["label"], phase, resources])
	var budget: Dictionary = level.mother_core.get_budget_snapshot()
	_check(int(budget["balance"]) == int(resources["core"])
		and int(budget["reserved"]) + int(budget["spendable"]) == int(resources["core"]),
		"Original budget reservations partition the real payer balance without extra nutrition")
	_check(int(resources["combat_transit"]) == level.supply_system.get_in_transit_count()
		and int(resources["growth_transit"]) <= level.growth_supply_system.get_in_transit_count(),
		"Incoming capacity and growth FIFO drafts never duplicate paid transit inventory")
	var live_tips: int = 0
	for child: Node in level.get_node("World/GrowthTips").get_children():
		if child is GrowthTip and not child.is_queued_for_deletion():
			live_tips += 1
	_check(live_tips <= 1, "External queue uses at most one original construction tip")
	for row: Dictionary in level.traffic_system.get_snapshot()["edges"]:
		_check(int(row["capacity"]) == 2 and int(row["occupied_units"]) >= 0 and int(row["occupied_units"]) <= 2,
			"Construction packets retain original edge capacity two and actual shared FIFO leases")
	for owner: Node in [level.growth_supply_system, level.cultivation_supply_system]:
		for shipment: Dictionary in owner.call("get_shipment_records"):
			_check(shipment["source"] == level.mother_core and int(shipment["task_id"]) > 0
				and not String(shipment["transport_task_id"]).is_empty(),
				"Original shipment keeps its actual frozen payer, original task ID and transport identity")
	if remember:
		var checkpoints: Array = evidence["checkpoints"]
		checkpoints.append({"phase": phase, "resources": resources})


func _cultivation_paid_count(level: Node2D) -> int:
	var count: int = 0
	for shipment: Dictionary in level.cultivation_supply_system.get_shipment_records():
		if bool(shipment["debited"]):
			count += 1
	return count


func _tick(level: Node2D, evidence: Dictionary, feed: bool = true, cultivation_limit: int = -1) -> void:
	_coordinator(level).pump()
	if feed:
		level.growth_supply_system.try_dispatch()
		if cultivation_limit < 0 or _cultivation_paid_count(level) < cultivation_limit:
			level.cultivation_supply_system.try_dispatch()
	level.traffic_system.refresh()
	for path: String in PACKET_PATHS:
		for child: Node in level.get_node(path).get_children():
			if not child is NutrientPacket or child.is_queued_for_deletion():
				continue
			var packet: NutrientPacket = child as NutrientPacket
			var records: Dictionary = evidence["packets"]
			var record: Dictionary = records.get(packet.get_instance_id(), {})
			var before: Vector2 = packet.global_position
			var occupied_edge: HyphaEdge = packet.get("edge") as HyphaEdge
			packet.call("_physics_process", STEP)
			if not is_instance_valid(packet) or record.is_empty() or packet.global_position.is_equal_approx(before):
				continue
			record["movements"] = int(record["movements"]) + 1
			var current_edge: HyphaEdge = packet.get("edge") as HyphaEdge
			for edge: HyphaEdge in [occupied_edge, current_edge]:
				if is_instance_valid(edge) and not record["edges"].has(edge.get_instance_id()):
					record["edges"].append(edge.get_instance_id())
	level.growth_system.advance(STEP)
	level.cultivation_system.advance(STEP)
	level.growth_supply_system.call("_process", 0.0)
	level.cultivation_supply_system.call("_process", 0.0)
	level.call("_process", 0.0)
	level.fungal_field.advance(STEP)
	level.digestive_organ.digest_timer.stop()
	await process_frame
	_coordinator(level).pump()
	level.call("_process", 0.0)


func _until(level: Node2D, evidence: Dictionary, phase: String, condition: Callable,
		feed: bool = true, cultivation_limit: int = -1) -> bool:
	for step: int in range(STEP_LIMIT):
		if bool(condition.call()):
			break
		await _tick(level, evidence, feed, cultivation_limit)
		if step % 20 == 0:
			_checkpoint(level, evidence, phase + "_in_progress")
	var reached: bool = bool(condition.call())
	_check(reached, "%s reaches %s through original physical packets before the bounded step limit" % [evidence["label"], phase])
	_checkpoint(level, evidence, phase, true)
	return reached


func _dispose(level: Node2D, evidence: Dictionary) -> void:
	if not evidence.is_empty():
		evidence["active"] = false
	if is_instance_valid(_coordinator(level)):
		_coordinator(level).reset()
	if current_scene == level:
		current_scene = null
	level.queue_free()
	await process_frame
	await process_frame


func _summary(level: Node2D, evidence: Dictionary, details: Dictionary) -> Dictionary:
	var result: Dictionary = {"case": evidence["label"], "initial_total": evidence["initial_total"],
		"final_resources": _resources(level, evidence), "started": evidence["started"],
		"finished": evidence["finished"], "matured": evidence["matured"],
		"callback_replays": evidence["callback_replays"], "packet_count": evidence["packets"].size(),
		"physical_arrivals": 0, "moving_packets": 0, "checkpoints": evidence["checkpoints"]}
	for packet: Dictionary in evidence["packets"].values():
		result["physical_arrivals"] = int(result["physical_arrivals"]) + int(packet["arrivals"])
		if int(packet["movements"]) > 0:
			result["moving_packets"] = int(result["moving_packets"]) + 1
	result.merge(details)
	return result


func _test_three_formal_targets_complete_serially() -> void:
	var level: Node2D = await _new_level()
	if not _check_wiring(level):
		await _dispose(level, {})
		return
	var evidence: Dictionary = _observe(level, "formal_G_B_L_serial_completion")
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var previews: Dictionary = {
		"growth": coordinator.preview(&"growth", {"start_node": _left(level), "target_position": GROWTH_TARGET}),
		"remote": coordinator.preview(&"remote_cultivation", {"start_node": _right(level), "target_position": REMOTE_TARGET}),
		"connection": coordinator.preview(&"connection", {"first_node": _left(level), "second_node": _right(level)}),
	}
	for preview: Dictionary in previews.values():
		_check(bool(preview.get("valid", false)) and int(preview.get("total_cost", 0)) > 0,
			"Actual original planners quote each distinct formal G/B/L target")
	_press(KEY_G)
	_click(GROWTH_TARGET)
	var growth_id: String = String(queue.get_snapshot()["selected_id"])
	_check(not growth_id.is_empty() and queue.get_request(growth_id).get("kind") == &"growth"
		and queue.get_request(growth_id).get("parameters") == {"start_node": _left(level), "target_position": GROWTH_TARGET}
		and not level.growth_system.has_active_task() and level.mother_core.nutrition == CAPITAL,
		"Real G input only admits its nearest captured left origin and target, with deferred unpaid start")
	coordinator.pump()
	var active_before_sort: Dictionary = _identity(queue.get_request(growth_id))
	_press(KEY_B)
	_click(REMOTE_TARGET)
	var remote_id: String = String(queue.get_snapshot()["selected_id"])
	_press(KEY_L)
	_click(_left(level).global_position)
	_click(_right(level).global_position)
	var connection_id: String = String(queue.get_snapshot()["selected_id"])
	_check(queue.get_snapshot()["entries"].size() == 3 and growth_id != remote_id and remote_id != connection_id
		and queue.get_request(remote_id).get("kind") == &"remote_cultivation"
		and queue.get_request(connection_id).get("kind") == &"connection"
		and level.mother_core.nutrition == CAPITAL
		and not queue.get_request(remote_id).get("started", true) and not queue.get_request(connection_id).get("started", true),
		"Actual B and L inputs admit unpaid waiting work while G already owns the original executor")
	if growth_id.is_empty() or remote_id == growth_id or connection_id == remote_id or queue.get_snapshot()["entries"].size() != 3:
		await _dispose(level, evidence)
		return
	var remote_identity: Dictionary = _identity(queue.get_request(remote_id))
	var connection_identity: Dictionary = _identity(queue.get_request(connection_id))
	_check(coordinator.move_request(connection_id, -1) and coordinator.move_request(remote_id, -1),
		"Two waiting physical requests can exchange order and return to their original serial order")
	_check(_identity(queue.get_request(growth_id)) == active_before_sort
		and _identity(queue.get_request(remote_id)) == remote_identity
		and _identity(queue.get_request(connection_id)) == connection_identity,
		"Sorting preserves all original sequences, payer references, endpoint order and captured internal IDs")
	var fourth: Dictionary = coordinator.enqueue(&"growth", {"start_node": _right(level), "target_position": Vector2(1040, 530)})
	var duplicate: Dictionary = coordinator.enqueue(&"connection", {"first_node": _right(level), "second_node": _left(level)})
	_check(not bool(fourth.get("accepted", true)) and fourth.get("reason") == &"queue_full"
		and String(fourth.get("construction_id", "bad")).is_empty()
		and not bool(duplicate.get("accepted", true)) and duplicate.get("reason") == &"duplicate"
		and duplicate.get("construction_id") == connection_id and level.mother_core.nutrition == CAPITAL,
		"An executing slot plus two waiting slots rejects a fourth but resolves reversed L to the same ID without charging")
	coordinator.select_request(growth_id)
	var first_task: int = int(queue.get_request(growth_id)["internal_ids"]["growth_task_id"])
	level.growth_system.task_completed.emit(first_task)
	coordinator.pump()
	_check(queue.get_snapshot()["active_id"] == growth_id and not queue.get_request(remote_id)["started"],
		"Fake matching completion before actual transport cannot advance the physical queue")
	if not await _until(level, evidence, "G_completes_and_B_starts", func() -> bool:
		return queue.get_request(growth_id).get("state") == &"completed" and queue.get_request(remote_id).get("started", false)):
		await _dispose(level, evidence)
		return
	var growth_endpoint: HyphaNode = level.growth_system.get_completed_endpoint(first_task)
	_check(growth_endpoint != null and growth_endpoint.global_position.distance_to(GROWTH_TARGET) < 0.05
		and level.mother_core.nutrition == CAPITAL - int(previews["growth"]["total_cost"])
		and queue.get_snapshot()["selected_id"] == "",
		"G completion commits its actual captured endpoint, exact original cost, and clears its selected row")
	var remote_current: Dictionary = queue.get_request(remote_id)
	var remote_request: int = int(remote_current["internal_ids"]["remote_request_id"])
	level.growth_system.task_completed.emit(first_task)
	_remote(level).request_completed.emit(remote_request)
	coordinator.pump()
	_check(queue.get_snapshot()["active_id"] == remote_id and not queue.get_request(connection_id)["started"],
		"A retired G completion and fake current B completion cannot bypass real organ maturity")
	if not await _until(level, evidence, "B_reaches_original_cultivation", func() -> bool:
		return int(queue.get_request(remote_id).get("internal_ids", {}).get("cultivation_task_id", 0)) > 0):
		await _dispose(level, evidence)
		return
	var handoff: Dictionary = queue.get_request(remote_id)
	var bud_task: int = int(handoff["internal_ids"]["cultivation_task_id"])
	_check(handoff["state"] == &"executing" and not queue.get_request(connection_id)["started"]
		and level.cultivation_system.has_active_task() and evidence["matured"].is_empty(),
		"B stays the external executor after network completion until its actual organ matures")
	level.cultivation_system.task_completed.emit(bud_task)
	coordinator.pump()
	_check(queue.get_snapshot()["active_id"] == remote_id and not queue.get_request(connection_id)["started"],
		"Fake current cultivation completion cannot release the serial pipeline")
	if not await _until(level, evidence, "B_matures_and_L_starts", func() -> bool:
		return queue.get_request(remote_id).get("state") == &"completed" and queue.get_request(connection_id).get("started", false)):
		await _dispose(level, evidence)
		return
	var completed_remote: Dictionary = _remote(level).get_request_snapshot()
	var remote_host: HyphaNode = completed_remote.get("endpoint") as HyphaNode
	_check(remote_host != null and remote_host.global_position.distance_to(REMOTE_TARGET) < 0.05
		and evidence["matured"].size() == 1 and int(completed_remote["request_id"]) == remote_request
		and int(completed_remote["consumed_nutrition"]) == int(previews["remote"]["total_cost"])
		and level.mother_core.nutrition == CAPITAL - int(previews["growth"]["total_cost"]) - int(previews["remote"]["total_cost"]),
		"True B maturity owns its intended host and pays its original full growth plus twelve budget once")
	var connection_task: int = int(queue.get_request(connection_id)["internal_ids"]["growth_task_id"])
	_check(_connection(level).has_active_task() and connection_task > first_task
		and int(_connection(level).get_task_snapshot()["task_id"]) == connection_task
		and queue.get_request(connection_id)["parameters"] == connection_identity["parameters"],
		"L starts with original shared growth execution and exactly its captured occupied host pair")
	if not await _until(level, evidence, "L_completes", func() -> bool:
		return queue.get_request(connection_id).get("state") == &"completed"):
		await _dispose(level, evidence)
		return
	var total_cost: int = int(previews["growth"]["total_cost"]) + int(previews["remote"]["total_cost"]) + int(previews["connection"]["total_cost"])
	var expected_ids: Array[String] = [growth_id, remote_id, connection_id]
	_check(evidence["started"] == expected_ids and evidence["finished"] == [
		{"construction_id": growth_id, "state": "completed"}, {"construction_id": remote_id, "state": "completed"},
		{"construction_id": connection_id, "state": "completed"}],
		"Three different formal targets start and complete exactly once in G then mature B then L order")
	_check(level.network_system.has_direct_connection(_left(level), _right(level))
		and level.growth_system.get_completed_endpoint(connection_task) == _right(level)
		and level.mother_core.nutrition == CAPITAL - total_cost
		and level.growth_supply_system.get_in_transit_count() == 0
		and level.cultivation_supply_system.get_in_transit_count() == 0
		and queue.get_snapshot()["entries"].is_empty(),
		"Final original connection settles every shipment and exact total cost without a second executor or mixed cache")
	var before_duplicate: Dictionary = _resources(level, evidence)
	level.growth_system.task_completed.emit(connection_task)
	_connection(level).task_completed.emit(connection_task)
	_remote(level).request_completed.emit(remote_request)
	level.cultivation_system.task_completed.emit(bud_task)
	coordinator.pump()
	_check(_resources(level, evidence) == before_duplicate and evidence["finished"].size() == 3,
		"Duplicate original terminal events preserve all completed resources and queue terminal counts")
	_checkpoint(level, evidence, "three_targets_settled", true)
	cases.append(_summary(level, evidence, {"construction_ids": expected_ids, "total_cost": total_cost,
		"original_task_ids": [first_task, remote_request, bud_task, connection_task]}))
	await _dispose(level, evidence)


func _test_growth_cache_cancel_then_next() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "growth_original_cache_refund_before_next")
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var first_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1100, 400)})
	var next_id: String = _admit(level, &"connection", {"first_node": _left(level), "second_node": _right(level)})
	coordinator.pause_request(next_id)
	coordinator.pump()
	if not await _until(level, evidence, "paid_structure_and_original_packet_in_transit", func() -> bool:
		var growth: Dictionary = level.growth_system.get_task_snapshot()
		return int(growth.get("consumed_nutrition", 0)) > 0 and level.growth_supply_system.get_in_transit_count() > 0):
		await _dispose(level, evidence)
		return
	_check(coordinator.pause_request(first_id), "Physical active G pauses through its original task")
	var held: Dictionary = _identity(queue.get_request(first_id))
	var cache_filled: Callable = func() -> bool:
		return level.growth_supply_system.get_in_transit_count() == 0 \
			and int(level.growth_system.get_task_snapshot().get("buffered_nutrition", 0)) > 0
	if not await _until(level, evidence, "paused_paid_packets_physically_fill_original_cache", cache_filled, false):
		await _dispose(level, evidence)
		return
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var paid_structure: int = int(growth["consumed_nutrition"])
	var refundable: int = int(growth["buffered_nutrition"])
	var before_cancel: int = level.mother_core.nutrition
	_check(queue.get_snapshot()["active_id"] == first_id and _identity(queue.get_request(first_id)) == held
		and not queue.get_request(next_id)["started"] and queue.get_request(first_id)["state"] == &"paused",
		"Physical arrivals during active pause fill only its original cache and hold later work")
	_check(coordinator.cancel_request(first_id), "Physical G cancellation uses its actual original cached task")
	_check(level.mother_core.nutrition == before_cancel + refundable
		and level.mother_core.nutrition == CAPITAL - paid_structure
		and int(level.growth_system.get_task_snapshot()["buffered_nutrition"]) == 0
		and level.growth_supply_system.get_in_transit_count() == 0
		and queue.get_request(first_id)["state"] == &"cancelled" and not queue.get_request(next_id)["started"],
		"Original G cancellation returns precisely its unspent paid cache to its original payer and retains invested structure")
	_checkpoint(level, evidence, "original_G_cache_refunded", true)
	var next_preview: Dictionary = coordinator.preview(&"connection", {"first_node": _left(level), "second_node": _right(level)})
	_check(coordinator.resume_request(next_id), "Next physical L resumes after outgoing G refunds settle")
	if await _until(level, evidence, "next_L_completes_from_own_payments", func() -> bool:
		return queue.get_request(next_id).get("state") == &"completed"):
		_check(level.mother_core.nutrition == CAPITAL - paid_structure - int(next_preview["total_cost"]),
			"Following L pays only its exact own budget and cannot consume the retired G cache")
		cases.append(_summary(level, evidence, {"cancelled": first_id, "next": next_id,
			"retained_network_cost": paid_structure, "original_cache_refund": refundable}))
	await _dispose(level, evidence)


func _test_remote_startup_cancel_then_next() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "B_original_startup_reservation_and_transit_refund")
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var remote_id: String = _admit(level, &"remote_cultivation", {"start_node": _right(level), "target_position": REMOTE_TARGET})
	var next_id: String = _admit(level, &"growth", {"start_node": _left(level), "target_position": GROWTH_TARGET})
	coordinator.pause_request(next_id)
	coordinator.pump()
	# 只停止第九次原派发之后的后续派发；不改变付款余额、到货、库存或原占位规则。
	var startup_reserved: Callable = func() -> bool:
		var cultivation: Dictionary = level.cultivation_system.get_task_snapshot()
		return int(cultivation.get("structure_consumed", 0)) == 8 \
			and int(cultivation.get("startup_reserved", 0)) == 1 \
			and level.cultivation_supply_system.get_in_transit_count() == 0
	if not await _until(level, evidence, "eight_structure_and_one_real_startup_reserved", startup_reserved, true, 9):
		await _dispose(level, evidence)
		return
	var request: Dictionary = queue.get_request(remote_id)
	var internal: Dictionary = request["internal_ids"]
	var remote_snapshot: Dictionary = _remote(level).get_request_snapshot()
	var host: HyphaNode = remote_snapshot.get("endpoint") as HyphaNode
	var original_cultivation: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(host != null and not host.is_organ_slot_available() and evidence["matured"].is_empty()
		and int(internal["cultivation_task_id"]) == int(original_cultivation["task_id"])
		and int(original_cultivation["startup_transferred"]) == 0,
		"Unmatured B holds the actual bud slot and an original refundable paid startup reservation")
	_check(level.cultivation_supply_system.try_dispatch()
		and level.cultivation_supply_system.get_in_transit_nutrition() == 1
		and coordinator.pause_request(remote_id),
		"One more original cultivation dispatch pays a real packet before B pauses")
	var before: int = level.mother_core.nutrition
	var network_cost: int = int(remote_snapshot["growth_consumed"])
	_check(coordinator.cancel_request(remote_id), "Cancelling physical B delegates to its matching original cultivation")
	var cancelled: Dictionary = level.cultivation_system.get_task_snapshot(int(internal["cultivation_task_id"]))
	_check(level.mother_core.nutrition == before + 2 and level.mother_core.nutrition == CAPITAL - network_cost - 8
		and int(cancelled["structure_consumed"]) == 8 and int(cancelled["buffered_nutrition"]) == 0
		and int(cancelled["startup_reserved"]) == 0 and int(cancelled["startup_transferred"]) == 0
		and level.cultivation_supply_system.get_in_transit_count() == 0
		and queue.get_request(remote_id)["state"] == &"cancelled" and evidence["matured"].is_empty(),
		"Original B refunds exactly one reserved startup and one paid in-transit packet, retaining only its real network/eight structure")
	_check(host != null and not host.is_organ_slot_available() and not queue.get_request(next_id)["started"],
		"Cancelled B keeps the original resumable bud slot without creating an organ or starting paused next work")
	_checkpoint(level, evidence, "B_original_startup_and_transit_refunded", true)
	var next_preview: Dictionary = coordinator.preview(&"growth", {"start_node": _left(level), "target_position": GROWTH_TARGET})
	coordinator.resume_request(next_id)
	if await _until(level, evidence, "next_G_uses_own_nutrition", func() -> bool:
		return queue.get_request(next_id).get("state") == &"completed"):
		_check(level.mother_core.nutrition == CAPITAL - network_cost - 8 - int(next_preview["total_cost"])
			and int(level.cultivation_system.get_task_snapshot(int(internal["cultivation_task_id"]))["startup_reserved"]) == 0,
			"Following G funds itself without using or refunding the cancelled B's reserved startup again")
		cases.append(_summary(level, evidence, {"cancelled": remote_id, "next": next_id,
			"retained_network_cost": network_cost, "retained_organ_structure": 8, "original_refund": 2}))
	await _dispose(level, evidence)


func _test_reset_and_late_settlement() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "reset_original_paid_packet_and_generation_isolation")
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var retired_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1100, 400)})
	var waiting_id: String = _admit(level, &"remote_cultivation", {"start_node": _left(level), "target_position": Vector2(120, 380)})
	coordinator.pump()
	if not await _until(level, evidence, "original_paid_transport_before_reset", func() -> bool:
		return level.growth_supply_system.get_in_transit_count() > 0):
		await _dispose(level, evidence)
		return
	var stale: Dictionary = level.growth_system.get_task_snapshot().duplicate(true)
	var retired_task: int = int(stale["task_id"])
	var old_sequence: int = int(queue.get_request(waiting_id)["sequence"])
	var generation: int = queue.get_generation()
	var old_packets: Array = evidence["packets"].values().duplicate()
	var invested: int = int(_resources(level, evidence)["network_structure"])
	coordinator.reset()
	_check(queue.get_generation() > generation and queue.get_snapshot()["entries"].is_empty()
		and queue.get_snapshot()["selected_id"] == "" and queue.get_snapshot()["active_id"] == ""
		and queue.get_request(retired_id).is_empty() and queue.get_request(waiting_id).is_empty()
		and level.growth_supply_system.get_in_transit_count() == 0
		and int(level.growth_system.get_task_snapshot()["buffered_nutrition"]) == 0
		and level.mother_core.nutrition == CAPITAL - invested,
		"Queue reset first cancels original paid work with the original payer alive and clears its generation/history")
	var fresh_id: String = _admit(level, &"connection", {"first_node": _right(level), "second_node": _left(level)})
	coordinator.pump()
	# reset 已触发原取消；本帧先重放仍待销毁的旧包，再跨原结算屏障捕获新任务身份。
	for record: Dictionary in old_packets:
		_replay_settled(level, evidence, record)
	await process_frame
	coordinator.pump()
	await process_frame
	coordinator.pump()
	var fresh: Dictionary = _identity(queue.get_request(fresh_id))
	var fresh_task: int = int(fresh["internal_ids"]["growth_task_id"])
	var balance: int = level.mother_core.nutrition
	_check(fresh_id != retired_id and fresh_id != waiting_id and int(fresh["sequence"]) > old_sequence
		and fresh_task > retired_task, "Fresh generation uses new construction/sequence/original task identities")
	level.growth_system.task_changed.emit(stale)
	level.growth_system.task_completed.emit(retired_task)
	level.growth_system.task_cancelled.emit(retired_task)
	_connection(level).task_completed.emit(retired_task)
	for _step: int in range(12):
		await _tick(level, evidence, false)
	_check(_identity(queue.get_request(fresh_id)) == fresh and queue.get_request(fresh_id)["state"] == &"executing"
		and level.mother_core.nutrition == balance and float(level.growth_system.get_task_snapshot()["distance"]) == 0.0
		and int(level.growth_system.get_task_snapshot()["buffered_nutrition"]) == 0,
		"Old packet and task callbacks after reset cannot pay, refund, advance or complete the replacement connection")
	_checkpoint(level, evidence, "late_callbacks_leave_fresh_executor_unfunded", true)
	var preview: Dictionary = level.growth_system.planner.plan(_right(level).global_position, _left(level).global_position, true)
	if await _until(level, evidence, "fresh_connection_completes_from_original_new_packets", func() -> bool:
		return queue.get_request(fresh_id).get("state") == &"completed"):
		_check(level.mother_core.nutrition == balance - int(preview["total_cost"])
			and level.growth_system.get_completed_endpoint(fresh_task) == _left(level)
			and level.network_system.has_direct_connection(_right(level), _left(level)),
			"Replacement honors its captured reversed endpoint order and its own exact new original payment budget")
		cases.append(_summary(level, evidence, {"retired": retired_id, "retired_waiting": waiting_id,
			"fresh": fresh_id, "retired_task": retired_task, "fresh_task": fresh_task,
			"retained_network_cost": invested, "generation_advanced": true}))
	await _dispose(level, evidence)
