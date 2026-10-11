extends SceneTree
## 真实付费连接 → 生命断路 → 同一调度器维修供养 → 原货物继续与场域恢复。
## 仅手动推进生产包的物理更新与生产系统；首次抵达、维修缓存和收入绝不伪造。
## 运行：Godot --headless --fixed-fps 60 --path . --script tests/network_recovery_cycle_test.gd

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const STEP: float = 0.1
const STEP_LIMIT: int = 2000
const POSITION_EPSILON: float = 0.05
const SOURCE_NUTRITION: int = 80
const INITIAL_CAPITAL: int = 72
const PACKET_PATHS: Array[String] = [
	"World/Packets", "World/GrowthPackets", "World/RepairPackets",
	"World/RecoveryPackets", "World/ReturnPackets",
]
const SERVICE_PATHS: Array[String] = [
	"Systems/SupplySystem", "Systems/GrowthSupplySystem", "Systems/RepairSupplySystem",
	"Systems/RecyclingSystem", "Systems/NutritionReturnSystem",
]
const KINDS: Array[String] = ["ordinary", "growth", "repair", "remains", "return"]

var checks: int = 0
var failures: Array[String] = []
var conservation_checks: int = 0
var cases: Array[Dictionary] = []
var interfaces_available: bool = true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	await _test_paid_corridor_recovery(true)
	if interfaces_available:
		await _test_paid_corridor_recovery(false)
		await _test_wholly_isolated()
		await _test_construction_coexists()
		await _test_pause_cancel_and_late_callbacks()
		await _test_real_return_receipt()
		await _test_restart_identity_isolation()
	_check(root.get_child_count() == 0, "Recovery integration removes every level and old physical packet")
	print("NETWORK_RECOVERY_CYCLE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "conservation_checks": conservation_checks,
		"cases": cases, "first_arrivals_fabricated": false, "repair_buffer_injected": false,
		"motion": "manual_ticks_of_production_packets", "initial_capital": INITIAL_CAPITAL,
		"initial_carcass": SOURCE_NUTRITION, "edge_capacity": 2,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _repair(level: Node2D) -> RepairSystem:
	return level.get_node_or_null("Systems/RepairSystem") as RepairSystem


func _repair_supply(level: Node2D) -> RepairSupplySystem:
	return level.get_node_or_null("Systems/RepairSupplySystem") as RepairSupplySystem


func _controller(level: Node2D) -> RepairInputController:
	return level.get_node_or_null("Systems/RepairInputController") as RepairInputController


func _right(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/RightNode") as HyphaNode


func _left(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode


func _ordinary_target(level: Node2D) -> AttackOrgan:
	return _right(level).get_node("AttackOrgan") as AttackOrgan


func _original_right_edge(level: Node2D) -> HyphaEdge:
	return level.get_node("World/Colony/Connections/RightEdge") as HyphaEdge


func _prepare_level(level: Node2D) -> void:
	# 保留本用例的原容量2/35HP交通与账目基线；主脉动态成长由7.5真实整合验证。
	level.get_node("Systems/MainVeinSystem").set("enabled", false)
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = true
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	var repair_supply: Node = level.get_node_or_null("Systems/RepairSupplySystem")
	if repair_supply != null:
		repair_supply.set("auto_supply", false)
	level.get_node("World/Colony/MotherCore").initial_nutrition = INITIAL_CAPITAL


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _quiet(level: Node2D) -> void:
	level.set_process(false)
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.nutrition_return_system.auto_return = false
	level.nutrition_return_system.get_node("DispatchTimer").stop()
	level.growth_system.set_physics_process(false)
	level.cultivation_system.set_physics_process(false)
	level.growth_supply_system.auto_supply = false
	level.growth_supply_system.set_process(false)
	level.cultivation_supply_system.auto_supply = false
	level.cultivation_supply_system.set_process(false)
	level.traffic_system.set_process(false)
	level.fungal_field.set_process(false)
	level.digestive_organ.digest_timer.stop()
	if _repair(level) != null:
		_repair(level).set_physics_process(false)
		_repair(level).set_process(false)
	if _repair_supply(level) != null:
		_repair_supply(level).auto_supply = false
		_repair_supply(level).set_process(false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level() -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level)
	root.add_child(level)
	current_scene = level
	_quiet(level)
	await physics_frame
	await process_frame
	_quiet(level)
	level.call("_process", 0.0)
	level.fungal_field.advance(1.0)
	var available: bool = _repair(level) != null and _repair_supply(level) != null \
		and _controller(level) != null and level.get_node_or_null("World/RepairPackets") != null
	_check(available, "Formal scene owns repair task, repair supply, repair controller and physical packet container")
	interfaces_available = interfaces_available and available
	if available:
		_check(level.get("repair_system") == _repair(level)
			and level.get("repair_supply_system") == _repair_supply(level)
			and level.get("repair_input_controller") == _controller(level),
			"Level fields expose the same formal repair objects")
		_check(_repair(level).network_system == level.network_system
			and _repair_supply(level).repair_system == _repair(level)
			and _repair_supply(level).mother_core == level.mother_core
			and _repair_supply(level).network_system == level.network_system
			and _repair_supply(level).traffic_system == level.traffic_system
			and _repair_supply(level).traffic_required
			and _repair_supply(level).packet_container == level.get_node("World/RepairPackets"),
			"Repair uses the original pay source, network, mandatory shared FIFO and actual repair packets")
		_check(_controller(level).repair_system == _repair(level)
			and _controller(level).repair_supply_system == _repair_supply(level)
			and _controller(level).network_system == level.network_system,
			"Formal input controller operates the exact shared repair objects")
		var dispatchers: int = 0
		for child: Node in level.get_node("Systems").get_children():
			if child is NetworkTrafficSystem:
				dispatchers += 1
		_check(dispatchers == 1, "Repair does not create a second dispatcher or independent capacity pool")
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		_check(edge.traffic_capacity == 2 and is_equal_approx(edge.health, 35.0)
			and is_equal_approx(edge.max_health, 35.0), "Initial edges retain capacity two and full thirty-five HP")
	_check(level.mother_core.nutrition == INITIAL_CAPITAL
		and _ordinary_target(level).nutrition == 4
		and level.get_node("World/Remains/LargeCarcass").get_remaining_nutrition() == SOURCE_NUTRITION,
		"Recovery fixture retains the original capital, organ inventory and eighty-unit source")
	return level


func _dispose(level: Node2D, evidence: Dictionary) -> void:
	evidence["active"] = false
	if is_instance_valid(level):
		if current_scene == level:
			current_scene = null
		level.queue_free()
	await process_frame
	await process_frame


func _callbacks(packet: Node, owner: Node, event: StringName) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(event):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _remember_cost(evidence: Dictionary, key: String, snapshot: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id <= 0:
		return
	var costs: Dictionary = evidence[key]
	var previous: int = int(costs.get(task_id, 0))
	var consumed: int = int(snapshot.get("consumed_nutrition", 0))
	if consumed >= previous:
		costs[task_id] = consumed


func _observe(level: Node2D, label: String) -> Dictionary:
	var evidence: Dictionary = {
		"label": label, "active": true, "growth_costs": {}, "repair_costs": {},
		"packets": {}, "receipts": {}, "checkpoints": [], "initial_total": 0,
		"dispatcher_id": level.traffic_system.get_instance_id(), "failures_at_start": failures.size(),
	}
	level.growth_system.task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_cost(evidence, "growth_costs", snapshot))
	_repair(level).task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_cost(evidence, "repair_costs", snapshot))
	level.mother_core.digestion_product_arrived.connect(func(product_id: String, amount: int) -> void:
		if not bool(evidence["active"]):
			return
		var receipts: Dictionary = evidence["receipts"]
		_check(not receipts.has(product_id) and amount == 10,
			"Only one real ten-unit green return credits each unique product identity")
		receipts[product_id] = amount)
	for index: int in range(PACKET_PATHS.size()):
		var owner: Node = level.get_node(SERVICE_PATHS[index])
		var kind: String = KINDS[index]
		level.get_node(PACKET_PATHS[index]).child_entered_tree.connect(func(child: Node) -> void:
			if bool(evidence["active"]) and (child is NutrientPacket or child is RemainsPacket):
				_watch_packet(level, evidence, child as Node2D, owner, kind))
	evidence["initial_total"] = int(_resources(level, evidence)["total"])
	_checkpoint(level, evidence, "initial")
	return evidence


func _watch_packet(level: Node2D, evidence: Dictionary, packet: Node2D, owner: Node, kind: String) -> void:
	packet.set_physics_process(false)
	var record: Dictionary = {
		"id": packet.get_instance_id(), "packet": packet, "kind": kind,
		"arrivals": 0, "interruptions": 0, "task_id": "", "target": null,
		"repair_edge": _repair(level).get_task_snapshot().get("edge") if kind == "repair" else null,
		"arrived_callbacks": _callbacks(packet, owner, &"arrived"),
		"interrupted_callbacks": _callbacks(packet, owner, &"interrupted"),
		"states": [], "granted_edges": [],
	}
	(evidence["packets"] as Dictionary)[packet.get_instance_id()] = record
	_check(bool(packet.get("traffic_required")) and not (record["arrived_callbacks"] as Array).is_empty(),
		"Production " + kind + " packet is paid and wired to its owning business before entering tree")
	packet.connect(&"status_changed", func(snapshot: Dictionary) -> void:
		if not bool(evidence["active"]):
			return
		var states: Array = record["states"]
		if states.is_empty() or states.back() != String(snapshot.get("state", &"")):
			states.append(String(snapshot.get("state", &"")))
		if not bool(snapshot.get("started", false)):
			return
		var task_id: String = String(snapshot.get("task_id", ""))
		if String(record["task_id"]).is_empty():
			record["task_id"] = task_id
			record["target"] = snapshot.get("final_target")
		_check(task_id == String(record["task_id"])
			and snapshot.get("final_target") == record["target"]
			and int(snapshot.get("traffic_system_id", 0)) == int(evidence["dispatcher_id"]),
			"Shipment target, task and original shared dispatcher stay immutable")
		if kind == "repair" and snapshot.get("edge") != null:
			_check(snapshot.get("edge") != record["repair_edge"],
				"Actual repair travel and every replan exclude the target edge even after it reopens")
		if snapshot.get("state") == &"moving":
			var grants: Array = record["granted_edges"]
			var edge: HyphaEdge = snapshot.get("edge") as HyphaEdge
			if edge != null and not grants.has(edge.get_instance_id()):
				grants.append(edge.get_instance_id()))
	packet.connect(&"arrived", func(finished: Node2D) -> void:
		if not bool(evidence["active"]):
			return
		record["arrivals"] = int(record["arrivals"]) + 1
		var target: Node2D = record["target"] as Node2D
		_check(int(record["arrivals"]) == 1 and int(record["interruptions"]) == 0
			and is_instance_valid(target) and finished.global_position.distance_to(target.global_position) < POSITION_EPSILON
			and bool(finished.call("has_arrived_at", target, String(record["task_id"]))),
			"First " + kind + " arrival is its real unique committed physical receipt"))
	packet.connect(&"interrupted", func(_finished: Node2D) -> void:
		if bool(evidence["active"]):
			record["interruptions"] = int(record["interruptions"]) + 1
			_check(int(record["arrivals"]) == 0 and int(record["interruptions"]) == 1,
				"Interrupted physical cargo settles once without an invented receipt"))


func _resources(level: Node2D, evidence: Dictionary) -> Dictionary:
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var repair: Dictionary = _repair(level).get_task_snapshot()
	_remember_cost(evidence, "growth_costs", growth)
	_remember_cost(evidence, "repair_costs", repair)
	var parts: Dictionary = {
		"core_balance": int(level.mother_core.nutrition), "organ_stock": 0,
		"ordinary_paid_transit": int(level.supply_system.get_in_transit_count()),
		"growth_paid_transit": int(level.growth_supply_system.get_in_transit_count()),
		"growth_buffer": int(growth.get("buffered_nutrition", 0)), "paid_network": 0,
		"repair_paid_transit": int(_repair_supply(level).get_in_transit_nutrition()),
		"repair_buffer": int(repair.get("buffered_nutrition", 0)), "repair_consumed": 0,
		"source": 0, "live_remains": 0, "digestive_queue": int(level.digestive_organ.get_queued_nutrition()),
		"products_including_return_transit": 0,
	}
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
	for consumed: int in (evidence["growth_costs"] as Dictionary).values():
		parts["paid_network"] = int(parts["paid_network"]) + consumed
	for consumed: int in (evidence["repair_costs"] as Dictionary).values():
		parts["repair_consumed"] = int(parts["repair_consumed"]) + consumed
	for child: Node in level.get_node("World/Remains").get_children():
		if child.is_queued_for_deletion():
			continue
		if child is LargeCarcass:
			parts["source"] = int(parts["source"]) + child.get_remaining_nutrition()
		elif child is EnemyRemains:
			parts["live_remains"] = int(parts["live_remains"]) + child.nutrition_value
	for product: Dictionary in level.digestive_organ.get_output_products():
		parts["products_including_return_transit"] = int(parts["products_including_return_transit"]) + int(product["nutrition"])
	# 预留仍属于母核余额；紫包和绿包分别引用尸块和胃囊产物，不重复计数。
	var total: int = 0
	for value: int in parts.values():
		total += value
	parts["total"] = total
	return parts


func _checkpoint(level: Node2D, evidence: Dictionary, phase: String) -> void:
	var resources: Dictionary = _resources(level, evidence)
	conservation_checks += 1
	_check(int(resources["total"]) == int(evidence["initial_total"]),
		String(evidence["label"]) + "/" + phase + " conserves balance + paid cargo + buffers + consumed investment")
	var budget: Dictionary = level.mother_core.get_budget_snapshot()
	_check(int(budget["reserved"]) >= 0 and int(budget["reserved"]) <= int(budget["balance"])
		and int(budget["spendable"]) + int(budget["reserved"]) == int(budget["balance"]),
		"Budget reservations partition the actual balance and add no resource mass")
	(evidence["checkpoints"] as Array).append({"phase": phase, "resources": resources})


func _tick(level: Node2D, _evidence: Dictionary, feed_repair: bool = false, feed_growth: bool = false) -> void:
	_repair_supply(level).refresh_budget()
	if feed_repair:
		_repair_supply(level).try_dispatch()
	if feed_growth:
		level.growth_supply_system.try_dispatch()
	level.traffic_system.refresh()
	for path: String in PACKET_PATHS:
		for child: Node in level.get_node(path).get_children():
			if not child.is_queued_for_deletion() and (child is NutrientPacket or child is RemainsPacket):
				child.call("_physics_process", STEP)
	level.growth_system.advance(STEP)
	_repair(level).advance(STEP)
	level.growth_supply_system.call("_process", 0.0)
	_repair_supply(level).refresh_budget()
	level.call("_process", 0.0)
	level.fungal_field.advance(STEP)
	level.digestive_organ.digest_timer.stop()
	for row: Dictionary in level.traffic_system.get_snapshot()["edges"]:
		_check(int(row["capacity"]) == 2 and int(row["occupied_units"]) >= 0
			and int(row["occupied_units"]) <= 2,
			"All business directions and repair packets share the original capacity of two")
	var task: Dictionary = _repair(level).get_task_snapshot()
	var missing: float = float(task.get("missing_health", 0.0))
	var credit: float = float(task.get("paid_heal_remaining", 0.0))
	var cost: int = int(ceil(maxf(0.0, missing - credit) / 10.0))
	_check(int(task.get("remaining_cost", 0)) == cost
		and int(task.get("remaining_demand", 0)) == maxi(cost - int(task.get("buffered_nutrition", 0)), 0),
		"Remaining repair cost includes paid credit and separately reports unmet delivered demand")


func _until(level: Node2D, evidence: Dictionary, phase: String, condition: Callable,
		feed_repair: bool = false, feed_growth: bool = false) -> bool:
	for tick: int in range(STEP_LIMIT):
		if bool(condition.call()):
			break
		_tick(level, evidence, feed_repair, feed_growth)
		if tick % 20 == 0:
			_checkpoint(level, evidence, phase + "_moving")
	var reached: bool = bool(condition.call())
	_check(reached, String(evidence["label"]) + " reaches " + phase + " using bounded real production motion")
	_checkpoint(level, evidence, phase)
	return reached


func _build_paid_corridor(level: Node2D, evidence: Dictionary) -> HyphaEdge:
	var old_ids: Array[int] = []
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		old_ids.append(edge.get_instance_id())
	var quote: Dictionary = level.connection_system.preview_connection(_left(level), _right(level))
	_check(bool(quote.get("valid", false)) and int(quote.get("total_cost", 0)) > 0,
		"Existing left and right junctions receive the unchanged production connection quote")
	var balance: int = level.mother_core.nutrition
	var task_id: int = level.connection_system.request_connection(_left(level), _right(level))
	_check(task_id > 0 and level.growth_system.has_active_task(),
		"Connection request creates a real GrowthSystem construction task")
	if task_id <= 0:
		return null
	if not _until(level, evidence, "real_paid_connection_completion", func() -> bool:
		return not level.growth_system.has_active_task(), false, true):
		return null
	var snapshot: Dictionary = level.growth_system.get_task_snapshot()
	_check(snapshot.get("state") == &"completed"
		and int(snapshot.get("consumed_nutrition", 0)) == int(quote["total_cost"])
		and level.mother_core.nutrition == balance - int(quote["total_cost"])
		and level.network_system.has_direct_connection(_left(level), _right(level)),
		"Real supply arrivals pay every unchanged connection fee and commit its physical corridor")
	var target: HyphaEdge = null
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		if not old_ids.has(edge.get_instance_id()) and edge.end_node == _right(level):
			target = edge
	_check(target != null and target.traffic_capacity == 2 and target.health == 35.0,
		"Recovery target is the actual newly paid last connection segment")
	return target


func _launch_ordinary(level: Node2D, evidence: Dictionary) -> NutrientPacket:
	var old_ids: Array[int] = []
	for child: Node in level.get_node("World/Packets").get_children():
		old_ids.append(child.get_instance_id())
	_check(level.supply_system.request_supply(_ordinary_target(level)), "Ordinary supply pays and reserves its real receiver")
	for child: Node in level.get_node("World/Packets").get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion() and not old_ids.has(child.get_instance_id()):
			_checkpoint(level, evidence, "ordinary_paid_dispatch")
			return child as NutrientPacket
	_check(false, "Ordinary supply exposes the actual new physical packet")
	return null


func _record(evidence: Dictionary, packet: Node2D) -> Dictionary:
	return (evidence["packets"] as Dictionary).get(packet.get_instance_id(), {})


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event)
	var released: InputEventKey = event.duplicate() as InputEventKey
	released.pressed = false
	root.push_input(released)


func _click(point: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event)
	var released: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	released.pressed = false
	root.push_input(released)


func _request_selected_repair(level: Node2D, edge: HyphaEdge) -> int:
	_press(KEY_F)
	_check(_controller(level).is_selecting(), "Real F input enters repair selection through the owning level")
	_click(edge.start_node.global_position.lerp(edge.end_node.global_position, 0.5))
	_check(_controller(level).get_selected_edge() == edge,
		"Real mouse input selects the original paid edge using its actual world line")
	_press(KEY_J)
	var task: Dictionary = _repair(level).get_task_snapshot()
	_check(_repair(level).has_active_task() and task.get("edge") == edge,
		"Real J input confirms the authoritative repair task")
	return int(task.get("task_id", 0))


func _summary(level: Node2D, evidence: Dictionary, extras: Dictionary) -> Dictionary:
	var packets: Array[Dictionary] = []
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		packets.append({"kind": record["kind"], "task_id": record["task_id"],
			"arrivals": record["arrivals"], "interruptions": record["interruptions"],
			"states": record["states"], "granted_edges": record["granted_edges"]})
	var result: Dictionary = {
		"label": evidence["label"], "passed": failures.size() == int(evidence["failures_at_start"]),
		"resources": _resources(level, evidence), "packets": packets,
		"unique_product_receipts": (evidence["receipts"] as Dictionary).size(),
	}
	result.merge(extras)
	return result


func _test_paid_corridor_recovery(with_bypass: bool) -> void:
	var level: Node2D = await _new_level()
	if not interfaces_available:
		await _dispose(level, {})
		return
	var evidence: Dictionary = _observe(level, "paid_corridor_" + ("node_bypass" if with_bypass else "no_bypass_field_restore"))
	var edge: HyphaEdge = _build_paid_corridor(level, evidence)
	if edge == null:
		await _dispose(level, evidence)
		return
	# 仅用独立手动开关把原有路线留作备用；生命恢复始终经真实维修。
	_original_right_edge(level).entry_enabled = false
	var occupied: NutrientPacket = _launch_ordinary(level, evidence)
	if occupied == null or not _until(level, evidence, "ordinary_occupies_paid_target", func() -> bool:
		return is_instance_valid(occupied) and occupied.edge == edge and occupied.progress > 0.0):
		await _dispose(level, evidence)
		return
	var occupied_record: Dictionary = _record(evidence, occupied)
	var before: Dictionary = occupied.get_transport_snapshot()
	var position: Vector2 = occupied.global_position
	var token: String = String(before["token"])
	var start_id: int = edge.start_node.get_instance_id()
	var end_id: int = edge.end_node.get_instance_id()
	_check(is_equal_approx(edge.take_damage(35.0), 35.0) and edge.health == 0.0
		and not edge.is_traversable() and edge.entry_enabled,
		"Damage to zero blocks passage without changing the independent manual entry flag")
	var waiting: NutrientPacket = _launch_ordinary(level, evidence)
	if waiting == null:
		await _dispose(level, evidence)
		return
	var waiting_record: Dictionary = _record(evidence, waiting)
	var balance: int = level.mother_core.nutrition
	for _wait: int in range(15):
		_tick(level, evidence)
		var state: Dictionary = occupied.get_transport_snapshot()
		_check(state.get("state") == &"blocked" and state.get("token") == token
			and occupied.global_position == position, "Occupied broken edge retains its exact position, progress and FIFO lease")
		_check(waiting.get_transport_snapshot().get("state") == &"waiting"
			and waiting.get_transport_snapshot().get("wait_reason") == &"no_route",
			"Node cargo with no bypass remains a paid waiting shipment")
	_check(int(occupied_record["arrivals"]) == 0 and int(waiting_record["arrivals"]) == 0
		and level.mother_core.nutrition == balance and _ordinary_target(level).incoming_nutrition == 2,
		"Break waiting neither delivers nor refunds either original paid cargo")
	_check(level.network_system.is_edge_valid(edge) and edge.start_node.get_instance_id() == start_id
		and edge.end_node.get_instance_id() == end_id,
		"Broken connection preserves the paid edge and both endpoint identities")
	var field: Dictionary = level.fungal_field.get_source_snapshot(_right(level))
	_check(not bool(field.get("connected", true)) and level.fungal_field.get_effective_radius(_right(level)) == 0.0,
		"Unavailable connectivity removes effective collection coverage immediately")
	if with_bypass:
		_original_right_edge(level).entry_enabled = true
		if not _until(level, evidence, "waiting_node_takes_real_original_bypass", func() -> bool:
			return int(waiting_record["arrivals"]) == 1):
			await _dispose(level, evidence)
			return
		_check(int(waiting_record["interruptions"]) == 0
			and (waiting_record["granted_edges"] as Array).has(_original_right_edge(level).get_instance_id())
			and int(occupied_record["arrivals"]) == 0 and occupied.global_position == position,
			"Real node cargo bypasses while cargo already inside the broken paid edge cannot teleport onto that bypass")
	else:
		level.fungal_field.advance(10.0)
		var remnant: Dictionary = level.fungal_field.get_source_snapshot(_right(level))
		_check(float(remnant.get("display_radius", 0.0)) > 0.0
			and float(remnant.get("display_radius", 0.0)) < 110.0,
			"Disconnected original field retains a fading visible remnant rather than collectible coverage")
	var repair_id: int = _request_selected_repair(level, edge)
	var task: Dictionary = _repair(level).get_task_snapshot()
	_check(repair_id > 0 and task.get("repair_point") == edge.start_node
		and int(task.get("initial_cost", 0)) == 4 and edge.health == 0.0,
		"Broken thirty-five HP segment selects its reachable start and quotes exactly four paid units")
	_check(_repair_supply(level).try_dispatch(), "Repair debits its actual reserved source and creates a real packet")
	_check(edge.health == 0.0 and int(_repair(level).get_task_snapshot().get("consumed_nutrition", 0)) == 0,
		"Dispatch alone cannot pay healing before real arrival")
	if not _until(level, evidence, "first_real_repair_arrival_reopens", func() -> bool:
		return edge.health > 0.0, true):
		await _dispose(level, evidence)
		return
	_check(edge.is_traversable() and edge.health <= 1.0001
		and int(_repair(level).get_task_snapshot().get("consumed_nutrition", 0)) == 1,
		"First delivered unit begins bounded ten-HP-per-second healing and first positive HP reopens the same edge")
	if not with_bypass:
		var restored: Dictionary = level.fungal_field.get_source_snapshot(_right(level))
		_check(bool(restored.get("connected", false))
			and level.fungal_field.get_effective_radius(_right(level)) > 0.0
			and float(restored.get("display_radius", 110.0)) < 110.0,
			"Actual paid HP recovery reconnects the original field with gradual radius restoration")
	if _until(level, evidence, "repair_and_both_original_cargo_complete", func() -> bool:
		return _repair(level).get_task_snapshot().get("state") == &"completed" \
			and level.supply_system.get_in_transit_count() == 0, true):
		_check(edge.health == 35.0 and int(_repair(level).get_task_snapshot()["consumed_nutrition"]) == 4
			and _repair_supply(level).get_in_transit_count() == 0,
			"Full repair consumes ceiling four once and leaves no unused paid cargo")
		_check(int(occupied_record["arrivals"]) == 1 and int(waiting_record["arrivals"]) == 1
			and int(occupied_record["interruptions"]) == 0 and int(waiting_record["interruptions"]) == 0
			and _ordinary_target(level).nutrition == 6 and _ordinary_target(level).incoming_nutrition == 0
			and level.supply_system.delivered_packets == 2 and level.supply_system.interrupted_packets == 0,
			"Both original paid shipments continue from their positions and settle precisely one receipt each")
		_check(edge.start_node.get_instance_id() == start_id and edge.end_node.get_instance_id() == end_id,
			"Completing repair never recreates either paid endpoint")
	cases.append(_summary(level, evidence, {"bypass": with_bypass, "repair_cost": 4, "occupied_token_preserved": true}))
	await _dispose(level, evidence)


func _test_wholly_isolated() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "wholly_isolated_waits_without_funding")
	var edge: HyphaEdge = _build_paid_corridor(level, evidence)
	if edge == null:
		await _dispose(level, evidence)
		return
	edge.take_damage(35.0)
	_original_right_edge(level).entry_enabled = false
	level.get_node("World/Colony/Connections/HyphaEdge").entry_enabled = false
	level.get_node("World/Colony/Connections/RecoveryEdge").entry_enabled = false
	var balance: int = level.mother_core.nutrition
	var task_id: int = _repair(level).request_repair(edge)
	_check(task_id > 0 and _repair(level).get_task_snapshot().get("repair_point") == null,
		"Valid damaged edge with both endpoints isolated creates an unfunded waiting task")
	for _tick_index: int in range(20):
		_tick(level, evidence, true)
		var supply: Dictionary = _repair_supply(level).get_supply_snapshot()
		_check(int(supply["reserved_nutrition"]) == 0 and int(supply["reservation_goal"]) == 0
			and int(supply["in_transit_nutrition"]) == 0 and int(supply["consumed_nutrition"]) == 0
			and level.mother_core.nutrition == balance and edge.health == 0.0,
			"Wholly isolated repair neither reserves, debits, dispatches, nor heals")
	_checkpoint(level, evidence, "isolated_unfunded")
	level.get_node("World/Colony/Connections/HyphaEdge").entry_enabled = true
	_repair_supply(level).refresh_budget()
	var reachable: Dictionary = _repair(level).get_task_snapshot()
	_check(int(reachable["task_id"]) == task_id and reachable.get("repair_point") == edge.start_node
		and bool(reachable["supply_reachable"]) and edge.health == 0.0
		and level.mother_core.nutrition == balance
		and int(_repair_supply(level).get_supply_snapshot()["reserved_nutrition"]) == 4,
		"A later real access path assigns the previously absent work point and funds the same waiting task without charging yet")
	if _until(level, evidence, "previously_isolated_task_real_repair_completion", func() -> bool:
		return not _repair(level).has_active_task(), true):
		_check(edge.health == 35.0 and level.mother_core.nutrition == balance - 4,
			"Previously isolated repair advances only after new real access and all four genuine deliveries")
	cases.append(_summary(level, evidence, {"initially_no_work_point": true, "initially_funded": 0, "later_repair_cost": 4}))
	await _dispose(level, evidence)


func _test_construction_coexists() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "repair_and_existing_construction_coexist")
	var edge: HyphaEdge = _build_paid_corridor(level, evidence)
	if edge == null:
		await _dispose(level, evidence)
		return
	edge.take_damage(7.0)
	var repair_id: int = _repair(level).request_repair(edge)
	var growth_id: int = level.growth_system.create_target(level.mother_core, Vector2(670, 560))
	_check(repair_id > 0 and growth_id > 0 and _repair(level).has_active_task()
		and level.growth_system.has_active_task(), "One independent repair coexists with the original single construction task")
	_check(_controller(level).enter_selection_mode(), "Active construction does not block F repair selection")
	_controller(level).exit_selection_mode()
	_check(level.growth_system.has_active_task(), "Entering and exiting repair selection cannot cancel construction")
	if _until(level, evidence, "both_independent_tasks_complete", func() -> bool:
		return not _repair(level).has_active_task() and not level.growth_system.has_active_task(), true, true):
		_check(edge.health == 35.0 and int(_repair(level).get_task_snapshot()["consumed_nutrition"]) == 1
			and int(level.growth_system.get_task_snapshot()["consumed_nutrition"]) == 5
			and level.growth_system.get_completed_endpoint(growth_id) != null,
			"Real independent deliveries pay one repair unit and unchanged five-unit growth including its endpoint")
	cases.append(_summary(level, evidence, {"simultaneous_construction": true, "repair_cost": 1, "growth_cost": 5}))
	await _dispose(level, evidence)


func _replay_callbacks(record: Dictionary) -> void:
	var packet: Node2D = record["packet"] as Node2D
	for key: String in ["arrived_callbacks", "interrupted_callbacks"]:
		for callback: Callable in record[key]:
			if callback.is_valid():
				callback.call(packet)


func _test_pause_cancel_and_late_callbacks() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "paid_repair_pause_cancel_refund_and_old_task_isolation")
	var edge: HyphaEdge = _build_paid_corridor(level, evidence)
	if edge == null:
		await _dispose(level, evidence)
		return
	edge.take_damage(35.0)
	var balance: int = level.mother_core.nutrition
	var task_id: int = _request_selected_repair(level, edge)
	_check(_repair_supply(level).try_dispatch() and _repair_supply(level).try_dispatch(),
		"Two real repair packets are debited before pause")
	_press(KEY_K)
	_repair_supply(level).refresh_budget()
	_check(_repair(level).get_task_snapshot().get("state") == &"paused"
		and _repair_supply(level).get_supply_snapshot()["reserved_nutrition"] == 0
		and _repair_supply(level).get_in_transit_nutrition() == 2
		and not _repair_supply(level).try_dispatch(),
		"Pausing releases only unpaid budget and retains both already paid shipments")
	if not _until(level, evidence, "real_deliveries_buffer_while_paused", func() -> bool:
		return _repair_supply(level).get_in_transit_count() == 0):
		await _dispose(level, evidence)
		return
	_check(edge.health == 0.0 and int(_repair(level).get_task_snapshot()["buffered_nutrition"]) == 2
		and int(_repair(level).get_task_snapshot()["consumed_nutrition"]) == 0,
		"Real arrivals are accepted while paused without accumulating healing time")
	_press(KEY_K)
	_repair(level).advance(STEP)
	_repair_supply(level).refresh_budget()
	_check(is_equal_approx(edge.health, 1.0) and int(_repair(level).get_task_snapshot()["consumed_nutrition"]) == 1
		and is_equal_approx(float(_repair(level).get_task_snapshot()["paid_heal_remaining"]), 9.0),
		"Resuming heals only this tick and retains nine HP of paid credit")
	_check(_repair_supply(level).try_dispatch(), "A third real packet is paid before explicit cancellation")
	_press(KEY_K)
	var frozen_hp: float = edge.health
	_press(KEY_BACKSPACE)
	_repair_supply(level).refresh_budget()
	_check(not _repair(level).has_active_task() and edge.health == frozen_hp
		and level.mother_core.nutrition == balance - 1
		and _repair_supply(level).get_in_transit_count() == 0
		and int(_repair(level).get_task_snapshot()["buffered_nutrition"]) == 0
		and is_zero_approx(float(_repair(level).get_task_snapshot()["paid_heal_remaining"])),
		"Cancel refunds one untouched buffer and one transit unit, preserves one paid healed HP, and discards consumed credit")
	var cancelled_supply: Dictionary = _repair_supply(level).get_supply_snapshot()
	_check(int(cancelled_supply["refunded_nutrition"]) == 2
		and level.colony_progress.get_total_recovered() == 0,
		"Refunded repairs credit their original source exactly once and create no recovered-income progress")
	var fresh_id: int = _repair(level).request_repair(edge)
	_check(fresh_id > task_id, "A replacement repair obtains a new monotonic task identity")
	var current: Dictionary = _repair(level).get_task_snapshot()
	var current_balance: int = level.mother_core.nutrition
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		if record["kind"] == "repair":
			_replay_callbacks(record)
	_check(_repair(level).get_task_snapshot() == current and level.mother_core.nutrition == current_balance
		and int(_repair_supply(level).get_supply_snapshot()["refunded_nutrition"]) == 0,
		"Replaying already settled old callbacks cannot fund, heal, refund, or cancel the new repair")
	_repair(level).cancel_task()
	_checkpoint(level, evidence, "cancelled_and_old_callbacks_inert")
	cases.append(_summary(level, evidence, {"old_task_id": task_id, "new_task_id": fresh_id, "consumed": 1, "refunded": 2}))
	await _dispose(level, evidence)


func _test_real_return_receipt() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "actual_carcass_digestion_green_receipt_after_paid_repair")
	if _build_paid_corridor(level, evidence) == null:
		await _dispose(level, evidence)
		return
	var carcass: LargeCarcass = level.get_node("World/Remains/LargeCarcass") as LargeCarcass
	carcass.global_position = level.mother_core.global_position + Vector2(-40, 0)
	_check(level.recycling_system.try_dispatch(), "Real recycling claims one ten-unit batch from the unchanged eighty-unit source")
	if not _until(level, evidence, "real_purple_arrival_at_stomach", func() -> bool:
		return level.recycling_system.get_in_transit_count() == 0):
		await _dispose(level, evidence)
		return
	_check(level.digestive_organ.get_queued_nutrition() == 10 and carcass.get_remaining_nutrition() == 70,
		"Real physical purple handoff owns exactly ten of the original eighty resource units")
	var stop_next: Callable = func(_product_id: String, _amount: int) -> void:
		level.digestive_organ.digest_timer.stop()
	level.digestive_organ.product_created.connect(stop_next, CONNECT_ONE_SHOT)
	level.digestive_organ.digest_timer.start(0.02)
	for _frame: int in range(30):
		await physics_frame
		await process_frame
		if level.digestive_organ.get_output_count() == 1:
			break
	level.digestive_organ.digest_timer.stop()
	if level.digestive_organ.product_created.is_connected(stop_next):
		level.digestive_organ.product_created.disconnect(stop_next)
	_check(level.digestive_organ.get_output_count() == 1 and level.mother_core.get_received_product_count() == 0,
		"Original real DigestTimer creates output without crediting the core before green transport")
	_checkpoint(level, evidence, "actual_timer_product")
	_check(level.nutrition_return_system.try_dispatch(), "Real return system reserves its unique product and creates a green packet")
	var packet: NutrientPacket = null
	for child: Node in level.get_node("World/ReturnPackets").get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			packet = child as NutrientPacket
	var edge: HyphaEdge = level.get_node("World/Colony/Connections/DigestionEdge") as HyphaEdge
	if packet == null or not _until(level, evidence, "green_occupies_original_core_edge", func() -> bool:
		return packet.edge == edge and packet.progress > 0.0):
		await _dispose(level, evidence)
		return
	var record: Dictionary = _record(evidence, packet)
	var token: String = String(packet.get_transport_snapshot()["token"])
	var position: Vector2 = packet.global_position
	var balance: int = level.mother_core.nutrition
	edge.take_damage(35.0)
	for _wait: int in range(10):
		_tick(level, evidence)
		_check(packet.global_position == position and packet.get_transport_snapshot().get("token") == token
			and packet.get_transport_snapshot().get("state") == &"blocked"
			and level.mother_core.get_received_product_count() == 0 and level.mother_core.nutrition == balance,
			"Green cargo on the actual broken edge keeps its product and token without any early core income")
	_check(_repair(level).request_repair(edge) > 0, "Real core-edge repair chooses its actual reachable work point")
	if _until(level, evidence, "same_green_cargo_actual_unique_receipt", func() -> bool:
		return level.nutrition_return_system.delivered_count == 1 and not _repair(level).has_active_task(), true):
		_check(int(record["arrivals"]) == 1 and int(record["interruptions"]) == 0
			and level.mother_core.get_received_product_count() == 1
			and level.colony_progress.get_total_recovered() == 10
			and (evidence["receipts"] as Dictionary).size() == 1
			and level.mother_core.nutrition == balance + 10 - 4,
			"Paid repair restores the same blocked green cargo and credits its original ten-unit product exactly once")
		var paid_balance: int = level.mother_core.nutrition
		_replay_callbacks(record)
		_check(level.mother_core.nutrition == paid_balance and level.mother_core.get_received_product_count() == 1
			and level.colony_progress.get_total_recovered() == 10,
			"Duplicate settled green callbacks cannot repeat income or recovery progress")
	_checkpoint(level, evidence, "unique_green_receipt_after_repair")
	cases.append(_summary(level, evidence, {"source_remaining": 70, "green_product": 10, "repair_cost": 4}))
	await _dispose(level, evidence)


func _test_restart_identity_isolation() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "actual_R_retires_repair_and_original_cargo_identities")
	var edge: HyphaEdge = _build_paid_corridor(level, evidence)
	if edge == null:
		await _dispose(level, evidence)
		return
	var paid_balance: int = level.mother_core.nutrition
	_original_right_edge(level).entry_enabled = false
	var ordinary: NutrientPacket = _launch_ordinary(level, evidence)
	if ordinary == null or not _until(level, evidence, "ordinary_moving_before_R", func() -> bool:
		return ordinary.edge == edge and ordinary.progress > 0.0):
		await _dispose(level, evidence)
		return
	edge.take_damage(35.0)
	_tick(level, evidence)
	var old_task: int = _repair(level).request_repair(edge)
	_check(old_task > 0 and _repair_supply(level).try_dispatch(), "R fixture contains a genuine paid moving repair shipment")
	var packets: Array[Node2D] = [ordinary]
	for child: Node in level.get_node("World/RepairPackets").get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			packets.append(child as Node2D)
	var handles: Array[Dictionary] = []
	var old_packet_ids: Array[int] = []
	var callbacks: Array[Callable] = []
	for packet: Node2D in packets:
		handles.append(packet.call("get_transport_snapshot"))
		old_packet_ids.append(packet.get_instance_id())
		var record: Dictionary = _record(evidence, packet)
		callbacks.append_array(record["arrived_callbacks"])
		callbacks.append_array(record["interrupted_callbacks"])
	var old_supply_id: int = _repair_supply(level).get_instance_id()
	var old_dispatcher_id: int = level.traffic_system.get_instance_id()
	var old_edge_id: int = edge.get_instance_id()
	var balances: Array[int] = []
	level.mother_core.nutrition_changed.connect(func(amount: int) -> void:
		balances.append(amount))
	_checkpoint(level, evidence, "before_actual_R")
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	for _frame: int in range(40):
		await physics_frame
		await process_frame
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	evidence["active"] = false
	var fresh: Node2D = current_scene as Node2D
	_check(is_instance_valid(fresh) and fresh != level and not is_instance_valid(level),
		"Actual R input destroys the old level and reloads the formal scene")
	if not is_instance_valid(fresh) or fresh == level:
		await _dispose(level, evidence)
		return
	_quiet(fresh)
	_check(not balances.is_empty() and balances.back() == paid_balance,
		"R refunds unused ordinary and repair cargo to their original pay source before teardown")
	for amount: int in balances:
		_check(amount <= paid_balance, "R never refunds completed network investment or duplicates old unused refunds")
	_check(not is_instance_valid(instance_from_id(old_supply_id))
		and not is_instance_valid(instance_from_id(old_dispatcher_id))
		and not is_instance_valid(instance_from_id(old_edge_id)),
		"R retires the old repair ledger, dispatcher and damaged paid edge identities")
	for packet_id: int in old_packet_ids:
		var record: Dictionary = (evidence["packets"] as Dictionary)[packet_id]
		_check(not is_instance_valid(instance_from_id(packet_id)) and int(record["arrivals"]) == 0
			and int(record["interruptions"]) == 1, "R destroys each old physical packet with one actual cancellation and no receipt")
	for callback: Callable in callbacks:
		_check(not callback.is_valid(), "R makes every captured old business callback owner inert")
	for handle: Dictionary in handles:
		_check(fresh.traffic_system.get_request(String(handle["request_id"])).is_empty()
			and fresh.traffic_system.get_lease(String(handle["token"])).is_empty()
			and not fresh.traffic_system.release(String(handle["token"]))
			and not fresh.traffic_system.cancel_request(String(handle["request_id"])),
			"Former repair and cargo handles cannot release or cancel fresh dispatcher records")
	_check(fresh.mother_core.nutrition == INITIAL_CAPITAL
		and fresh.mother_core.get_budget_snapshot()["reserved"] == 0
		and _repair(fresh).get_task_snapshot().get("state") == &"idle"
		and _repair_supply(fresh).get_in_transit_count() == 0
		and fresh.supply_system.get_in_transit_count() == 0
		and fresh.get_node("World/RepairPackets").get_child_count() == 0
		and not _controller(fresh).is_selecting()
		and _controller(fresh).get_selected_edge() == null,
		"Fresh R scene has original capital and empty repair, selection, unpaid budget and physical packet state")
	var fresh_evidence: Dictionary = _observe(fresh, "fresh_R_late_callback_window")
	for _tick_index: int in range(100):
		_tick(fresh, fresh_evidence)
	_check(fresh.mother_core.nutrition == INITIAL_CAPITAL
		and fresh.mother_core.get_received_product_count() == 0
		and (fresh_evidence["packets"] as Dictionary).is_empty(),
		"Beyond old travel time no old repair movement, payment, refund or receipt can appear in the new scene")
	_checkpoint(fresh, fresh_evidence, "late_old_identities_inert")
	cases.append(_summary(fresh, fresh_evidence, {"old_repair_task": old_task, "old_packet_count": old_packet_ids.size()}))
	await _dispose(fresh, fresh_evidence)
