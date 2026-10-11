extends SceneTree
## 阶段五真实施工闭环：付费扩张 → 尸骸批次 → 胃囊 → 绿色回流 → C/B 防御。
## 运行：Godot --headless --fixed-fps 60 --path . --script tests/construction_cycle_test.gd
## 仅推进场景帧/原有计时器；初始资本在入树前配置，首次付款和收入均经过实际运输。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const SOURCE_NUTRITION: int = 80
const ORDINARY_NUTRITION: int = 4
const BATCH_NUTRITION: int = 10
const NETWORK_COST: int = 16
const ORGAN_COST: int = 12
const STRUCTURE_COST: int = 8
const STARTUP_COST: int = 4
const FULL_COST: int = 28
const RESOURCE_TARGET: Vector2 = Vector2(1100, 400)
const REMOTE_TARGET: Vector2 = Vector2(120, 380)
const POSITION_EPSILON: float = 0.05
const BUILD_FRAME_LIMIT: int = 7200
const CYCLE_FRAME_LIMIT: int = 9000

var checks: int = 0
var failures: Array[String] = []
var conservation_checks: int = 0
var milestones: Array[Dictionary] = []
var chain_result: Dictionary = {}
var extension_cancel_result: Dictionary = {}
var continuation_result: Dictionary = {}
var reconnect_result: Dictionary = {}
var handoff_reset_result: Dictionary = {}
var restart_results: Array[Dictionary] = []
var interfaces_available: bool = true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_full_resource_to_defense_cycle()
	if interfaces_available:
		await _test_cancel_paid_extension()
		await _test_cancel_then_continue_remote_cultivation()
		await _test_disconnection_and_reconnection()
		await _test_reset_before_deferred_handoff()
		await _test_restart_with_paid_transport(false)
		await _test_restart_with_paid_transport(true)
	_check(root.get_child_count() == 0, "Construction cycle teardown removes all level objects")
	print("CONSTRUCTION_CYCLE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "conservation_checks": conservation_checks,
		"milestones": milestones, "chain": chain_result,
		"extension_cancel": extension_cancel_result, "continuation": continuation_result,
		"reconnect": reconnect_result, "handoff_reset": handoff_reset_result,
		"restart": restart_results,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _prepare_level(level: Node2D, resources: bool = false, initial_capital: int = 72) -> void:
	# 旧单执行器兼容夹具；正式 7.3 多实例路径由 multitip_construction_test 验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	level.expansion_demo_enabled = resources
	level.carcass_demo_enabled = resources
	var core: MotherCore = level.get_node("World/Colony/MotherCore") as MotherCore
	core.initial_nutrition = initial_capital
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _stop_isolated_timers(level: Node2D) -> void:
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level(resources: bool = false, initial_capital: int = 72) -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level, resources, initial_capital)
	root.add_child(level)
	current_scene = level
	_stop_isolated_timers(level)
	await _wait_frames(2)
	_check(level.get_node("World/Enemies").get_child_count() == 0,
		"Fixture suppresses the official wave without replacing any enemy system")
	return level


func _remove_level(level: Node2D, evidence: Dictionary) -> void:
	evidence["active"] = false
	if is_instance_valid(level):
		if current_scene == level:
			current_scene = null
		level.queue_free()
	await process_frame
	await process_frame


func _step() -> void:
	await physics_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for _frame: int in range(count):
		await _step()


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

	# 7.2 入队与执行分开；显式推进调度，不伪造运输或注入施工缓存。
	if is_instance_valid(current_scene):
		current_scene.construction_coordinator.pump()


func _remote(level: Node2D) -> Node:
	return level.get("remote_cultivation_system") as Node


func _check_wiring(level: Node2D) -> bool:
	var remote: Node = _remote(level)
	var supported: bool = is_instance_valid(remote)
	_check(supported and remote == level.get_node_or_null("Systems/RemoteCultivationSystem"),
		"Actual base level exposes Systems/RemoteCultivationSystem")
	if not supported:
		interfaces_available = false
		return false
	for method: StringName in [&"preview_request", &"request_remote", &"has_active_request",
			&"get_request_snapshot", &"pause_request", &"resume_request", &"cancel_request",
			&"continue_request", &"reset"]:
		var present: bool = remote.has_method(method)
		_check(present, "Remote construction exposes %s" % method)
		supported = supported and present
	for event: StringName in [&"request_changed", &"request_completed", &"request_cancelled"]:
		var present: bool = remote.has_signal(event)
		_check(present, "Remote construction exposes %s" % event)
		supported = supported and present
	_check(level.growth_system.has_method("get_completed_endpoint"),
		"Growth exposes the actual completed endpoint instead of a coordinate search")
	supported = supported and level.growth_system.has_method("get_completed_endpoint")
	if supported:
		_check(remote.get("growth_system") == level.growth_system
			and remote.get("growth_supply_system") == level.growth_supply_system
			and remote.get("cultivation_system") == level.cultivation_system
			and remote.get("cultivation_supply_system") == level.cultivation_supply_system,
			"Remote coordinator owns the level's exact growth/cultivation and supply references")
		_check(level.cultivation_input_controller.get("remote_cultivation_system") == remote
			and level.cultivation_input_controller.get("growth_input_controller") == level.growth_input_controller,
			"Real cultivation input shares remote construction and placement systems")
		_check(InputMap.has_action("remote_cultivation_mode"), "Actual B action exists on the project")
	interfaces_available = interfaces_available and supported
	return supported


func _live_organs(host: HyphaNode) -> Array[AttackOrgan]:
	var result: Array[AttackOrgan] = []
	for child: Node in host.get_children():
		if child is AttackOrgan and not child.is_queued_for_deletion():
			result.append(child as AttackOrgan)
	return result


func _live_weapons(host: HyphaNode) -> Array[SporeWeapon]:
	var result: Array[SporeWeapon] = []
	for child: Node in host.get_children():
		if child is SporeWeapon and not child.is_queued_for_deletion():
			result.append(child as SporeWeapon)
	return result


func _live_tip_count(level: Node2D) -> int:
	var count: int = 0
	for child: Node in level.get_node("World/GrowthTips").get_children():
		if child is GrowthTip and not child.is_queued_for_deletion():
			count += 1
	return count


func _node_ids(level: Node2D) -> Array[int]:
	var result: Array[int] = []
	for node: Node2D in level.network_system.get_registered_nodes():
		result.append(node.get_instance_id())
	return result


func _new_junctions(level: Node2D, originals: Array[int]) -> Array[HyphaNode]:
	var result: Array[HyphaNode] = []
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and not originals.has(node.get_instance_id()):
			result.append(node as HyphaNode)
	return result


func _remember_growth(snapshot: Dictionary, evidence: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id <= 0:
		return
	var investments: Dictionary = evidence["growth_investments"]
	var current: int = int(snapshot.get("consumed_nutrition", 0))
	var previous: int = int(investments.get(task_id, 0))
	_check(current >= previous, "Paid network investment never decreases within growth task %d" % task_id)
	investments[task_id] = current


func _observe(level: Node2D, label: String, resources: bool = false) -> Dictionary:
	var evidence: Dictionary = {
		"label": label, "active": true, "initial_resources": 0,
		"initial_core": int(level.mother_core.nutrition),
		"ordinary_initial": ORDINARY_NUTRITION if resources else 0,
		"shots": 0, "shots_by_weapon": {}, "growth_investments": {},
		"batches": {}, "production": [], "arrivals": [], "return_packets": {},
		"packet_arrivals": {}, "packet_interruptions": {}, "packet_callbacks": [],
		"matured": [], "watched_weapons": {}, "remote_transitions": [],
		"completed_requests": [], "cancelled_requests": [], "handoffs": {},
		"exhausted_signals": 0, "replayed_callbacks": 0,
	}
	level.growth_system.task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_growth(snapshot, evidence))
	for weapon: SporeWeapon in level.get_weapons():
		_watch_weapon(weapon, evidence)
	level.cultivation_system.organ_matured.connect(
		func(task_id: int, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon) -> void:
			if not bool(evidence["active"]):
				return
			var snapshot: Dictionary = level.cultivation_system.get_task_snapshot(task_id)
			_check(snapshot["state"] == &"completed" and int(snapshot["structure_consumed"]) == STRUCTURE_COST
				and int(snapshot["startup_transferred"]) == STARTUP_COST
				and int(snapshot["startup_reserved"]) == 0 and int(snapshot["consumed_nutrition"]) == ORGAN_COST,
				"Mature organ costs eight structure and exactly four transferred paid startup")
			_check(float(snapshot["effective_time"]) >= 3.0 and organ.nutrition == STARTUP_COST
				and organ.incoming_nutrition == 0,
				"Real maturity waits three funded seconds and receives exactly four paid inventory")
			_check(organ.get_parent() == host and weapon.get_parent() == host
				and weapon.inventory_owner == organ and weapon.attack_range == 100.0
				and weapon.enemy_container == level.get_node("World/Enemies")
				and weapon.projectile_container == level.get_node("World/Projectiles"),
				"Actual mature organ/weapon are siblings wired to the real battle")
			var matured: Array = evidence["matured"]
			matured.append({"task_id": task_id, "host": host, "organ": organ, "weapon": weapon,
				"stock": organ.nutrition, "effective_time": snapshot["effective_time"]})
			weapon.get_node("FireTimer").stop()
			_watch_weapon(weapon, evidence))
	level.digestive_organ.product_created.connect(func(product_id: String, amount: int) -> void:
		if not bool(evidence["active"]):
			return
		var production: Array = evidence["production"]
		for previous: Dictionary in production:
			_check(previous["product_id"] != product_id, "Digestion never produces a duplicate product ID")
		production.append({"product_id": product_id, "nutrition": amount}))
	level.mother_core.digestion_product_arrived.connect(func(product_id: String, amount: int) -> void:
		if not bool(evidence["active"]):
			return
		var packets: Dictionary = evidence["return_packets"]
		var packet: Variant = packets.get(product_id)
		_check(is_instance_valid(packet) and packet.global_position.distance_to(
			level.mother_core.global_position) < POSITION_EPSILON,
			"First income is credited only while its real green packet physically arrives at the core")
		var arrivals: Array = evidence["arrivals"]
		for previous: Dictionary in arrivals:
			_check(previous["product_id"] != product_id, "Each actual product receipt is unique")
		arrivals.append({"product_id": product_id, "nutrition": amount,
			"balance": int(level.mother_core.nutrition)}))
	var source: LargeCarcass = level.get_node_or_null("World/Remains/LargeCarcass") as LargeCarcass
	if source != null:
		source.exhausted.connect(func() -> void:
			evidence["exhausted_signals"] = int(evidence["exhausted_signals"]) + 1)
	level.get_node("World/Remains").child_entered_tree.connect(func(child: Node) -> void:
		if not bool(evidence["active"]) or not child is EnemyRemains or not child.has_meta("carcass_batch_id"):
			return
		var batch: EnemyRemains = child as EnemyRemains
		var batch_id: String = String(batch.get_meta("carcass_batch_id", ""))
		var request_id: String = String(batch.get_meta("carcass_request_id", ""))
		var batches: Dictionary = evidence["batches"]
		_check(source != null and not batch_id.is_empty() and not request_id.is_empty()
			and not batches.has(batch_id) and not batch.is_available() and not batch.visible
			and batch.nutrition_value == 0 and source.get_reservation_nutrition(request_id) == BATCH_NUTRITION,
			"Mining draft is claimed, uniquely identified, and owns zero while its reserved ten remains in the source")
		_check(String(batch.get_meta("carcass_source_id", "")) == source.get_resource_id(),
			"Actual batch retains the authoritative carcass source identity")
		for previous: Dictionary in batches.values():
			_check(previous["request_id"] != request_id, "Separate mining batches use separate request IDs")
		batches[batch_id] = {"request_id": request_id, "nutrition": BATCH_NUTRITION})
	_watch_container(level, "World/Packets", "combat", level.supply_system, evidence)
	_watch_container(level, "World/GrowthPackets", "growth", level.growth_supply_system, evidence)
	_watch_container(level, "World/CultivationPackets", "cultivation", level.cultivation_supply_system, evidence)
	_watch_container(level, "World/RecoveryPackets", "haul", level.recycling_system, evidence)
	_watch_container(level, "World/ReturnPackets", "return", level.nutrition_return_system, evidence)
	var remote: Node = _remote(level)
	remote.connect(&"request_changed", func(snapshot: Dictionary) -> void:
		if not bool(evidence["active"]):
			return
		var transitions: Array = evidence["remote_transitions"]
		var compact: Dictionary = _compact_remote(snapshot)
		if transitions.is_empty() or transitions.back() != compact:
			# 保留阶段/状态转换；逐帧进度由守恒检查验证，不产生庞大的结果日志。
			if transitions.is_empty() or transitions.back()["request_id"] != compact["request_id"] \
					or transitions.back()["phase"] != compact["phase"] or transitions.back()["state"] != compact["state"]:
				transitions.append(compact)
		if snapshot.get("phase", &"") == &"connected":
			var growth_id: int = int(snapshot["growth_task_id"])
			var endpoint: HyphaNode = level.growth_system.get_completed_endpoint(growth_id) as HyphaNode
			_check(endpoint != null and snapshot["endpoint"] == endpoint
				and level.network_system.is_connected_to_core(endpoint)
				and level.growth_supply_system.get_in_transit_count() == 0
				and not level.cultivation_system.has_active_task(),
				"Connected phase names the actual paid endpoint after growth supply settles and before deferred cultivation")
		if int(snapshot.get("cultivation_task_id", 0)) > 0:
			var handoffs: Dictionary = evidence["handoffs"]
			var request_id: int = int(snapshot["request_id"])
			var cultivation_id: int = int(snapshot["cultivation_task_id"])
			_check(not handoffs.has(request_id) or int(handoffs[request_id]) == cultivation_id,
				"Each remote request hands off to one unique cultivation attempt")
			handoffs[request_id] = cultivation_id)
	remote.connect(&"request_completed", func(request_id: int) -> void:
		if bool(evidence["active"]):
			var completed: Array = evidence["completed_requests"]
			_check(not completed.has(request_id), "One remote request completes at most once")
			completed.append(request_id))
	remote.connect(&"request_cancelled", func(request_id: int) -> void:
		if bool(evidence["active"]):
			var cancelled: Array = evidence["cancelled_requests"]
			_check(not cancelled.has(request_id), "One remote request cancels at most once")
			cancelled.append(request_id))
	evidence["initial_resources"] = int(_resource_snapshot(level, evidence)["total"])
	return evidence


func _watch_weapon(weapon: SporeWeapon, evidence: Dictionary) -> void:
	var watched: Dictionary = evidence["watched_weapons"]
	var weapon_id: int = weapon.get_instance_id()
	if watched.has(weapon_id):
		return
	watched[weapon_id] = true
	weapon.shot_fired.connect(func(_enemy: BasicEnemy) -> void:
		if not bool(evidence["active"]):
			return
		evidence["shots"] = int(evidence["shots"]) + 1
		var counts: Dictionary = evidence["shots_by_weapon"]
		counts[weapon_id] = int(counts.get(weapon_id, 0)) + 1
		weapon.get_node("FireTimer").stop())


func _callbacks(packet: Node, owner: Node, event: StringName) -> Array[Callable]:
	var result: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(event):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			result.append(callback)
	return result


func _watch_container(level: Node2D, path: String, kind: String, owner: Node, evidence: Dictionary) -> void:
	level.get_node(path).child_entered_tree.connect(func(child: Node) -> void:
		if not bool(evidence["active"]) or not child is Node2D:
			return
		var packet: Node2D = child as Node2D
		var arrived: Array[Callable] = _callbacks(packet, owner, &"arrived")
		var interrupted: Array[Callable] = _callbacks(packet, owner, &"interrupted")
		_check(not arrived.is_empty() and not interrupted.is_empty(),
			"%s packet has both actual owner settlement callbacks before entering the world" % kind)
		var records: Array = evidence["packet_callbacks"]
		records.append({"kind": kind, "packet": packet, "packet_id": packet.get_instance_id(),
			"arrived": arrived, "interrupted": interrupted})
		if kind == "return":
			var product_id: String = String(packet.get_meta("return_product_id", ""))
			var packets: Dictionary = evidence["return_packets"]
			packets[product_id] = packet
			var body: Polygon2D = packet.get_node("Body") as Polygon2D
			var glow: Polygon2D = packet.get_node("Glow") as Polygon2D
			var trail: Line2D = packet.get_node("Trail") as Line2D
			_check(not product_id.is_empty() and packet.get("speed") == 80.0
				and body.color.g > body.color.r and body.color.g > body.color.b
				and glow.color.g > glow.color.r and glow.color.g > glow.color.b
				and trail.default_color.g > trail.default_color.r and trail.default_color.g > trail.default_color.b,
				"Return uses the real default-speed green packet scene and its unique product ID")
		packet.connect(&"arrived", func(finished: Node2D) -> void:
			if not bool(evidence["active"]):
				return
			var arrivals: Dictionary = evidence["packet_arrivals"]
			arrivals[kind] = int(arrivals.get(kind, 0)) + 1
			if kind == "return":
				_check(finished.global_position.distance_to(level.mother_core.global_position) < POSITION_EPSILON,
					"Observed green settlement occurs at the actual core")
			elif kind == "haul":
				_check(finished.global_position.distance_to(level.digestive_organ.get_parent().global_position) < POSITION_EPSILON,
					"Observed remains haul settles at the actual stomach junction")
			_replay_settled_callbacks(finished, arrived, interrupted, evidence))
		packet.connect(&"interrupted", func(_finished: Node2D) -> void:
			if bool(evidence["active"]):
				var interruptions: Dictionary = evidence["packet_interruptions"]
				interruptions[kind] = int(interruptions.get(kind, 0)) + 1
				_replay_settled_callbacks(_finished, arrived, interrupted, evidence)))


func _replay_settled_callbacks(packet: Node2D, arrived: Array[Callable],
		interrupted: Array[Callable], evidence: Dictionary) -> void:
	# 观察者在生产接收者之后连接，只重放已实际到达/中断的结算，绝不伪造首次收入。
	for callback: Callable in arrived:
		if callback.is_valid():
			callback.call(packet)
			callback.call(packet)
			evidence["replayed_callbacks"] = int(evidence["replayed_callbacks"]) + 2
	for callback: Callable in interrupted:
		if callback.is_valid():
			callback.call(packet)
			callback.call(packet)
			evidence["replayed_callbacks"] = int(evidence["replayed_callbacks"]) + 2


func _compact_remote(snapshot: Dictionary) -> Dictionary:
	var endpoint: Variant = snapshot.get("endpoint")
	return {
		"request_id": int(snapshot.get("request_id", 0)), "growth_task_id": int(snapshot.get("growth_task_id", 0)),
		"cultivation_task_id": int(snapshot.get("cultivation_task_id", 0)),
		"phase": String(snapshot.get("phase", &"")), "state": String(snapshot.get("state", &"idle")),
		"endpoint_id": endpoint.get_instance_id() if is_instance_valid(endpoint) else 0,
		"network_cost": int(snapshot.get("network_cost", 0)), "total_cost": int(snapshot.get("total_cost", 0)),
		"growth_consumed": int(snapshot.get("growth_consumed", 0)),
		"structure_consumed": int(snapshot.get("structure_consumed", 0)),
		"startup_transferred": int(snapshot.get("startup_transferred", 0)),
	}


func _resource_snapshot(level: Node2D, evidence: Dictionary) -> Dictionary:
	# 每个键是互斥的当前所有权或实际投入/消耗。预留空间和历史入账不是额外营养。
	var parts: Dictionary = {
		"core_available": int(level.mother_core.nutrition),
		"combat_transit": 0, "growth_transit": 0, "cultivation_transit": 0,
		"organ_stock": 0, "growth_buffer": 0, "cultivation_buffer": 0,
		"startup_reserved": 0, "network_structure": 0, "organ_structure": 0,
		"shots_consumed": int(evidence["shots"]) * SporeWeapon.SHOT_NUTRITION,
		"carcass_source_including_reserved": 0, "live_carcass_batches": 0, "ordinary_remains": 0,
		"digestive_queue_including_active_digest": int(level.digestive_organ.get_queued_nutrition()),
		"digestive_products_queued": 0, "return_transit": 0,
	}
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
		# incoming 与普通已扣款包是同一笔营养，只放在运输类别，库存只取 nutrition。
		parts["combat_transit"] = int(parts["combat_transit"]) + organ.incoming_nutrition
	for record: Dictionary in level.growth_supply_system.get_shipment_records():
		if bool(record["debited"]) and not bool(record["settled"]) and not bool(record["refunded"]):
			parts["growth_transit"] = int(parts["growth_transit"]) + GrowthSupplySystem.PACKET_NUTRITION
	parts["cultivation_transit"] = int(level.cultivation_supply_system.get_in_transit_nutrition())
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_remember_growth(growth, evidence)
	parts["growth_buffer"] = int(growth.get("buffered_nutrition", 0))
	var investments: Dictionary = evidence["growth_investments"]
	for consumed: int in investments.values():
		parts["network_structure"] = int(parts["network_structure"]) + consumed
	var cultivation: Dictionary = level.cultivation_system.get_resource_snapshot()
	parts["organ_structure"] = int(cultivation["structure_consumed"])
	parts["cultivation_buffer"] = int(cultivation["buffered_nutrition"])
	parts["startup_reserved"] = int(cultivation["startup_reserved"])
	# startup_transferred 是历史分配，已经进入器官库存或射击消耗，绝不再加到资源总量。
	for child: Node in level.get_node("World/Remains").get_children():
		if child is LargeCarcass and not child.is_queued_for_deletion():
			parts["carcass_source_including_reserved"] = int(parts["carcass_source_including_reserved"]) + child.get_remaining_nutrition()
		elif child is EnemyRemains and not child.is_queued_for_deletion():
			# 被领取的隐藏尸块仍拥有营养；搬运包与胃囊入站预留只引用它，不能再计一份。
			var key: String = "live_carcass_batches" if child.has_meta("carcass_batch_id") else "ordinary_remains"
			parts[key] = int(parts[key]) + child.nutrition_value
	for product: Dictionary in level.digestive_organ.get_output_products():
		var key: String = "return_transit" if product["status"] == &"in_transit" else "digestive_products_queued"
		parts[key] = int(parts[key]) + int(product["nutrition"])
	# DigestTimer 的产出空间预留仍在 queue 中；回流记录和物理包也引用上面的唯一产物。
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	return parts


func _sum_amount(records: Array, amount_filter: int = 0) -> int:
	var result: int = 0
	for record: Dictionary in records:
		var amount: int = int(record["nutrition"])
		if amount_filter == 0 or amount == amount_filter:
			result += amount
	return result


func _assert_remote_snapshot(level: Node2D, evidence: Dictionary) -> void:
	var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
	var required: Array[String] = ["request_id", "task_id", "growth_task_id", "cultivation_task_id",
		"phase", "state", "wait_reason", "endpoint", "target_position", "progress", "network_cost",
		"organ_cost", "total_cost", "growth_consumed", "structure_consumed", "startup_reserved",
		"startup_transferred", "buffered_nutrition", "consumed_nutrition", "remaining_cost",
		"remaining_demand", "growth_snapshot", "cultivation_snapshot"]
	var complete: bool = true
	for key: String in required:
		complete = complete and snapshot.has(key)
	_check(complete, "%s remote snapshot exposes the full frozen accounting interface" % evidence["label"])
	if not complete or int(snapshot["request_id"]) == 0:
		return
	var consumed: int = int(snapshot["growth_consumed"]) + int(snapshot["structure_consumed"]) + int(snapshot["startup_transferred"])
	var total: int = int(snapshot["network_cost"]) + ORGAN_COST
	_check(int(snapshot["task_id"]) == int(snapshot["request_id"])
		and int(snapshot["organ_cost"]) == ORGAN_COST and int(snapshot["total_cost"]) == total,
		"Remote full budget includes growth plus twelve once, including the four paid startup")
	_check(int(snapshot["consumed_nutrition"]) == consumed
		and int(snapshot["remaining_cost"]) == total - consumed
		and int(snapshot["remaining_demand"]) == total - consumed - int(snapshot["buffered_nutrition"]) - int(snapshot["startup_reserved"]),
		"Remote investment, remaining budget, and demand use disjoint buffer/startup accounting")
	var growth: Dictionary = snapshot["growth_snapshot"]
	var cultivation: Dictionary = snapshot["cultivation_snapshot"]
	_check(int(snapshot["growth_consumed"]) == int(growth.get("consumed_nutrition", 0))
		and int(snapshot["buffered_nutrition"]) == int(growth.get("buffered_nutrition", 0)) + int(cultivation.get("buffered_nutrition", 0))
		and int(snapshot["structure_consumed"]) == int(cultivation.get("structure_consumed", 0))
		and int(snapshot["startup_reserved"]) == int(cultivation.get("startup_reserved", 0))
		and int(snapshot["startup_transferred"]) == int(cultivation.get("startup_transferred", 0)),
		"Remote aggregate retains paid growth and references the unique cultivation attempt")
	_check(int(snapshot["remaining_cost"]) >= 0 and int(snapshot["remaining_demand"]) >= 0
		and float(snapshot["progress"]) >= 0.0 and float(snapshot["progress"]) <= 1.0,
		"Remote progress and unpaid demand stay inside their original budget")
	if snapshot["state"] == &"completed":
		var endpoint: HyphaNode = snapshot["endpoint"] as HyphaNode
		_check(endpoint != null and _live_organs(endpoint).size() == 1 and _live_weapons(endpoint).size() == 1
			and cultivation.get("state", &"") == &"completed"
			and int(snapshot["structure_consumed"]) == STRUCTURE_COST
			and int(snapshot["startup_transferred"]) == STARTUP_COST,
			"Remote completion means one actual mature defense with paid startup")


func _checkpoint(level: Node2D, evidence: Dictionary, phase: String, remember: bool = true) -> void:
	var parts: Dictionary = _resource_snapshot(level, evidence)
	conservation_checks += 1
	_check(int(parts["total"]) == int(evidence["initial_resources"]),
		"%s/%s conserves disjoint resources: expected %d, got %s" % [
			evidence["label"], phase, int(evidence["initial_resources"]), parts])
	for key: String in parts:
		_check(int(parts[key]) >= 0, "%s resource category %s is nonnegative" % [phase, key])
	_check(int(parts["combat_transit"]) == level.supply_system.get_in_transit_count(),
		"Combat reservations describe the same paid transit and are counted once")
	var returning: Dictionary = level.nutrition_return_system.get_return_snapshot()
	_check(int(parts["return_transit"]) == int(returning["in_transit_nutrition"])
		and int(parts["digestive_products_queued"]) == int(returning["queued_nutrition"])
		and int(parts["return_transit"]) + int(parts["digestive_products_queued"]) == level.digestive_organ.get_output_nutrition(),
		"Queued output and return transit partition the unique digestive products")
	var output: Dictionary = level.digestive_organ.get_output_snapshot()
	_check(int(output["count"]) + int(output["reserved_count"]) <= 2
		and int(output["nutrition"]) + int(output["reserved_nutrition"]) <= 20,
		"Real digestion obeys two output products and twenty nutrition including space reservations")
	_check(_live_tip_count(level) <= 1, "Scene has at most one active construction tip")
	var source: LargeCarcass = level.get_node_or_null("World/Remains/LargeCarcass") as LargeCarcass
	if source != null:
		var received_carcass: int = _sum_amount(evidence["arrivals"], BATCH_NUTRITION)
		var received_all: int = _sum_amount(evidence["arrivals"])
		var unreturned: int = int(parts["carcass_source_including_reserved"]) + int(parts["live_carcass_batches"])
		unreturned += int(parts["ordinary_remains"]) + int(parts["digestive_queue_including_active_digest"])
		unreturned += int(parts["digestive_products_queued"]) + int(parts["return_transit"])
		_check(unreturned + received_all == SOURCE_NUTRITION + int(evidence["ordinary_initial"]),
			"Unreturned original resources plus unique physical receipts conserve eighty plus the ordinary four")
		_check(source.get_remaining_nutrition() + source.get_harvested_nutrition() == SOURCE_NUTRITION
			and source.get_available_nutrition() + source.get_reserved_nutrition() == source.get_remaining_nutrition()
			and source.get_harvested_nutrition() >= 0 and source.get_harvested_nutrition() <= SOURCE_NUTRITION
			and received_carcass <= source.get_harvested_nutrition() and received_carcass <= SOURCE_NUTRITION,
			"Carcass reservations are included in its remaining eighty; harvest and actual carcass receipts never exceed eighty")
		_check(level.colony_progress.get_total_recovered() == received_all
			and level.mother_core.get_received_product_count() == evidence["arrivals"].size(),
			"Cumulative recovery counts actual unique receipts, excluding spending, refunds, and reservations")
	_assert_remote_snapshot(level, evidence)
	if remember:
		milestones.append({"case": evidence["label"], "phase": phase, "resources": parts})


func _wait_for(level: Node2D, evidence: Dictionary, phase: String, condition: Callable,
		frame_limit: int = BUILD_FRAME_LIMIT) -> bool:
	for frame: int in range(frame_limit):
		if bool(condition.call()):
			break
		await _step()
		if frame % 30 == 0:
			_checkpoint(level, evidence, phase, false)
	var completed: bool = bool(condition.call())
	_check(completed, "%s/%s finishes through real scene frames before %d-frame timeout" % [evidence["label"], phase, frame_limit])
	_checkpoint(level, evidence, phase)
	return completed


func _place_remote(level: Node2D, evidence: Dictionary, target: Vector2 = RESOURCE_TARGET) -> int:
	var balance: int = level.mother_core.nutrition
	_press(KEY_B)
	_check(level.cultivation_input_controller.is_remote_placing(), "Real B input enters attack-bud placement")
	var preview: Dictionary = level.cultivation_input_controller.preview_remote_at(target)
	_check(bool(preview.get("valid", false)) and int(preview.get("network_cost", 0)) == NETWORK_COST
		and int(preview.get("organ_cost", 0)) == ORGAN_COST and int(preview.get("total_cost", 0)) == FULL_COST
		and int(preview.get("remaining_cost", 0)) == FULL_COST,
		"Actual placement preview quotes 320px network16 + organ12 = total28, never32")
	_check(level.mother_core.nutrition == balance and not _remote(level).call("has_active_request"),
		"B preview spends no nutrition and owns no request before placement")
	_click(target)
	# 入队本身不启动执行；跨过串行调度边界后继续原账目验收。
	level.construction_coordinator.pump()
	var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
	var request_id: int = int(snapshot.get("request_id", 0))
	_check(request_id > 0 and _remote(level).call("has_active_request")
		and snapshot.get("phase", &"") == &"growth"
		and not level.cultivation_input_controller.is_remote_placing()
		and not level.growth_input_controller.is_placing(),
		"Real B click creates one growth-first remote request and closes both placement previews")
	_check(level.mother_core.nutrition == balance and not level.cultivation_system.has_active_task(),
		"Remote creation charges only real dispatched packets and creates no free organ bud")
	_checkpoint(level, evidence, "remote_placed")
	return request_id


func _first_packet(level: Node2D, path: String) -> Node2D:
	var result: Node2D = null
	for child: Node in level.get_node(path).get_children():
		if child is Node2D and not child.is_queued_for_deletion():
			result = child as Node2D
			break
	_check(result != null, "Expected real packet exists in %s" % path)
	return result


func _wait_movement(packet: Node2D) -> void:
	if packet == null:
		return
	var origin: Vector2 = packet.global_position
	for _frame: int in range(30):
		await _step()
		if not is_instance_valid(packet) or packet.global_position.distance_to(origin) > 1.0:
			break
	_check(is_instance_valid(packet) and packet.global_position.distance_to(origin) > 1.0,
		"Real transport physically moves before its first settlement")


func _select_host(level: Node2D, host: HyphaNode) -> void:
	host.selection_requested.emit(host)
	_check(level.selected_node == host and level.cultivation_input_controller.get_selection_status()["host"] == host,
		"Actual endpoint selection reaches level and C cultivation adapter")


func _assert_completed_remote(level: Node2D, evidence: Dictionary, request_id: int, initial_balance: int) -> HyphaNode:
	var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
	var endpoint: HyphaNode = snapshot.get("endpoint") as HyphaNode
	var actual: HyphaNode = level.growth_system.get_completed_endpoint(int(snapshot.get("growth_task_id", 0))) as HyphaNode
	_check(snapshot["state"] == &"completed" and int(snapshot["request_id"]) == request_id
		and endpoint != null and endpoint == actual,
		"Completed remote request retains the actual final junction for its growth identity")
	_check(int(snapshot["network_cost"]) == NETWORK_COST and int(snapshot["organ_cost"]) == ORGAN_COST
		and int(snapshot["total_cost"]) == FULL_COST and int(snapshot["growth_consumed"]) == NETWORK_COST
		and int(snapshot["structure_consumed"]) == STRUCTURE_COST
		and int(snapshot["startup_transferred"]) == STARTUP_COST
		and int(snapshot["consumed_nutrition"]) == FULL_COST and int(snapshot["remaining_cost"]) == 0
		and int(snapshot["buffered_nutrition"]) == 0 and int(snapshot["startup_reserved"]) == 0,
		"320px remote completion invests sixteen network, eight structure, four existing paid stock: total28")
	_check(level.mother_core.nutrition == initial_balance - FULL_COST
		and level.growth_supply_system.get_in_transit_count() == 0
		and level.cultivation_supply_system.get_in_transit_count() == 0
		and evidence["completed_requests"].has(request_id),
		"Unique remote maturity debits exactly28 and settles all construction shipments")
	_checkpoint(level, evidence, "remote_matured")
	return endpoint


func _assert_terminal_remote_hud(level: Node2D, request_id: int, state: StringName) -> Dictionary:
	var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
	var label: Label = level.hud.growth_label as Label
	var pause_button: Button = level.hud.growth_pause_button as Button
	var cancel_button: Button = level.hud.growth_cancel_button as Button
	var title: String = "攻击器官已成熟" if state == &"completed" else "已取消，保留已付结构"
	_check(int(snapshot["request_id"]) == request_id and snapshot["state"] == state,
		"HUD regression observes the exact current terminal remote request")
	_check(label.text.begins_with("远处培育 · ") and label.text.contains(title),
		"Visible HUD reports the current remote %s state without confusing its internal ID with queue identity" % state)
	_check(label.text.contains("网络 16 + 器官 12 = 28"),
		"Visible terminal HUD preserves full network16 + organ12 =28 instead of selected C's organ-only budget")
	_check(pause_button.disabled and cancel_button.disabled,
		"Terminal remote HUD disables current P pause and X cancel buttons")
	return {"request_id": request_id, "state": String(state), "text": label.text,
		"pause_disabled": pause_button.disabled, "cancel_disabled": cancel_button.disabled}


func _spawn_enemy(level: Node2D, host: HyphaNode) -> BasicEnemy:
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.mother_core = level.mother_core
	enemy.max_health = 200
	enemy.move_speed = 0.0
	enemy.position = host.global_position + Vector2(40, 0)
	level.get_node("World/Enemies").add_child(enemy)
	enemy.set_physics_process(false)
	enemy.get_node("AttackTimer").stop()
	return enemy


func _exercise_battle_and_auto_supply(level: Node2D, host: HyphaNode, evidence: Dictionary, phase: String) -> Dictionary:
	var organs: Array[AttackOrgan] = _live_organs(host)
	var weapons: Array[SporeWeapon] = _live_weapons(host)
	_check(organs.size() == 1 and weapons.size() == 1, "%s has one real mature combat organ and weapon" % phase)
	if organs.size() != 1 or weapons.size() != 1:
		return {}
	var organ: AttackOrgan = organs[0]
	var weapon: SporeWeapon = weapons[0]
	var enemy: BasicEnemy = _spawn_enemy(level, host)
	var balance: int = level.mother_core.nutrition
	var stock: int = organ.nutrition
	var delivered: int = level.supply_system.delivered_packets
	_check(stock == STARTUP_COST and level.supply_system.get_registered_organs().has(organ),
		"%s joins ordinary combat supply with exactly four paid startup" % phase)
	level.supply_system.get_node("DispatchTimer").start()
	for index: int in range(2):
		var counts: Dictionary = evidence["shots_by_weapon"]
		var before: int = int(counts.get(weapon.get_instance_id(), 0))
		# 保留场景 FireTimer 的原有周期；观察者在首次真实射击后停止，便于精确对账。
		weapon.get_node("FireTimer").start()
		await _wait_for(level, evidence, "%s_shot_%d" % [phase, index + 1], func() -> bool:
			return int(counts.get(weapon.get_instance_id(), 0)) == before + 1, 240)
		_check(organ.nutrition == stock - index - 1,
			"%s actual shot consumes one local paid nutrition without a free refill" % phase)
	await _wait_for(level, evidence, phase + "_projectile_hits", func() -> bool:
		return enemy.health == enemy.max_health - 2 * weapon.damage, 240)
	_check(enemy.is_alive() and evidence["arrivals"].size() == 9,
		"Isolated battle uses actual projectile damage without adding enemy-death nutrition")
	var saw_transit: bool = organ.incoming_nutrition > 0
	for frame: int in range(2400):
		saw_transit = saw_transit or organ.incoming_nutrition > 0
		if organ.nutrition == organ.refill_target and organ.incoming_nutrition == 0:
			break
		await _step()
		if frame % 30 == 0:
			_checkpoint(level, evidence, phase + "_automatic_supply", false)
	_check(saw_transit and organ.nutrition == 3 and organ.incoming_nutrition == 0
		and level.supply_system.delivered_packets == delivered + 1 and level.mother_core.nutrition == balance - 1,
		"%s normal DispatchTimer sends and delivers one paid combat packet automatically" % phase)
	_check(level.cultivation_supply_system.get_in_transit_count() == 0
		and not level.cultivation_system.has_active_task(),
		"Automatic combat refill preserves completed cultivation")
	_checkpoint(level, evidence, phase + "_automatic_supply_arrived")
	var result: Dictionary = {"shots": 2, "damage": enemy.max_health - enemy.health,
		"automatic_deliveries": level.supply_system.delivered_packets - delivered,
		"startup": stock, "final_stock": organ.nutrition}
	enemy.queue_free()
	await _wait_frames(2)
	return result


func _test_full_resource_to_defense_cycle() -> void:
	# 唯一测试资本只有扩张所需的16。C/B 的付款必须来自之后真实返回的原始资源。
	var level: Node2D = await _new_level(true, NETWORK_COST)
	if not _check_wiring(level):
		await _remove_level(level, {})
		return
	var evidence: Dictionary = _observe(level, "resource_to_defense", true)
	var source: LargeCarcass = level.get_node_or_null("World/Remains/LargeCarcass") as LargeCarcass
	var ordinary: EnemyRemains = level.get_node_or_null("World/Remains/ExpansionRemains") as EnemyRemains
	_check(source != null and ordinary != null and source.total_nutrition == SOURCE_NUTRITION
		and source.batch_size == BATCH_NUTRITION and ordinary.nutrition_value == ORDINARY_NUTRITION,
		"Real scene contains the separate80 carcass and the existing ordinary4 corpse")
	if source == null or ordinary == null:
		await _remove_level(level, evidence)
		return
	_check(int(evidence["initial_resources"]) == 108 and level.mother_core.nutrition == NETWORK_COST,
		"Transparent initial budget is core16 + preset organs8 + carcass80 + ordinary4 =108")
	_check(not level.fungal_field.is_covered(source.global_position) and not level.recycling_system.try_dispatch()
		and source.get_harvested_nutrition() == 0, "Unpaid distant source cannot harvest before mature coverage")
	_checkpoint(level, evidence, "initial_disjoint_budget")
	_press(KEY_G)
	_click(RESOURCE_TARGET)
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var growth_id: int = int(growth["task_id"])
	_check(growth_id > 0 and growth["start_node"] == level.get_node("World/Colony/Nodes/RightNode")
		and int(growth["total_cost"]) == NETWORK_COST and is_equal_approx(float(growth["total_distance"]), 320.0),
		"Real G placement creates the 320px16 prerequisite expansion")
	_check(level.growth_supply_system.try_dispatch() and level.growth_system.pause_task(),
		"Actual prerequisite growth dispatches a prepaid packet before a controlled pause")
	var growth_packet: Node2D = _first_packet(level, "World/GrowthPackets")
	await _wait_movement(growth_packet)
	_check(int(level.growth_system.get_task_snapshot()["consumed_nutrition"]) == 0,
		"Prepaid growth transit provides no free structure before actual arrival")
	await _wait_for(level, evidence, "first_growth_delivery", func() -> bool:
		return level.growth_supply_system.get_in_transit_count() == 0)
	_check(int(level.growth_system.get_task_snapshot()["buffered_nutrition"]) == 1,
		"Physically arrived nutrition is held as a separate unspent growth buffer")
	level.growth_supply_system.auto_supply = true
	_check(level.growth_system.resume_task(), "Prerequisite growth resumes from its paid buffer")
	if not await _wait_for(level, evidence, "paid_resource_extension", func() -> bool:
		return level.growth_system.get_task_snapshot()["state"] == &"completed"):
		await _remove_level(level, evidence)
		return
	var host: HyphaNode = level.growth_system.get_completed_endpoint(growth_id) as HyphaNode
	_check(host != null and host.is_organ_slot_available() and level.network_system.is_connected_to_core(host)
		and host.global_position.distance_to(RESOURCE_TARGET) < POSITION_EPSILON
		and level.fungal_field.is_covered(source.global_position) and level.fungal_field.is_covered(ordinary.global_position)
		and level.mother_core.nutrition == 0 and source.get_harvested_nutrition() == 0,
		"Sixteen real payments reach both original resources and leave zero initial capital at the actual empty endpoint")
	if host == null:
		await _remove_level(level, evidence)
		return
	_select_host(level, host)
	level.cultivation_supply_system.auto_supply = true
	_press(KEY_C)
	var existing_cultivation_id: int = int(level.cultivation_system.get_task_snapshot()["task_id"])
	await _wait_frames(120)
	var unfunded: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(existing_cultivation_id > 0 and unfunded["state"] == &"waiting"
		and int(unfunded["structure_consumed"]) == 0 and float(unfunded["effective_time"]) == 0.0
		and level.cultivation_supply_system.get_in_transit_count() == 0
		and _live_organs(host).is_empty() and int(evidence["shots"]) == 0,
		"Real C cultivation with zero core capital waits without free structure, startup, time, or attacks")
	_checkpoint(level, evidence, "cultivation_requires_actual_return_income")
	_check(level.recycling_system.try_dispatch() and not ordinary.is_available() and not ordinary.visible
		and source.get_harvested_nutrition() == 0, "Real recycling hauls the existing ordinary corpse first")
	_check(level.recycling_system.try_dispatch() and source.get_harvested_nutrition() == BATCH_NUTRITION,
		"Actual mining commits a separate ten-nutrition batch after ordinary priority")
	await _wait_movement(_first_packet(level, "World/RecoveryPackets"))
	_check(level.mother_core.nutrition == 0 and evidence["arrivals"].is_empty(),
		"Mining commit and actual haul movement grant no core income")
	await _wait_for(level, evidence, "real_stomach_products", func() -> bool:
		return level.digestive_organ.get_output_count() == 2)
	_check(level.digestive_organ.get_output_nutrition() == 14 and level.mother_core.nutrition == 0
		and int(level.cultivation_system.get_task_snapshot()["structure_consumed"]) == 0,
		"Normal DigestTimer produces ordinary4 and carcass10 without funding cultivation early")
	_check(level.nutrition_return_system.try_dispatch(), "Real product launches its green return")
	await _wait_movement(_first_packet(level, "World/ReturnPackets"))
	_check(level.mother_core.nutrition == 0 and evidence["arrivals"].is_empty()
		and int(level.cultivation_system.get_task_snapshot()["structure_consumed"]) == 0,
		"Moving green return retains product ownership and still cannot finance the bud")
	level.nutrition_return_system.auto_return = true
	level.recycling_system.get_node("DispatchTimer").start()
	if not await _wait_for(level, evidence, "automatic_resource_and_existing_cultivation", func() -> bool:
		return source.is_exhausted() and level.colony_progress.get_total_recovered() == 84 \
			and level.recycling_system.get_in_transit_count() == 0 and level.digestive_organ.get_queued_count() == 0 \
			and level.digestive_organ.get_output_count() == 0 and level.nutrition_return_system.get_in_transit_count() == 0 \
			and level.cultivation_system.get_task_snapshot()["state"] == &"completed", CYCLE_FRAME_LIMIT):
		await _remove_level(level, evidence)
		return
	_check(evidence["batches"].size() == 8 and evidence["production"].size() == 9
		and evidence["arrivals"].size() == 9 and _sum_amount(evidence["production"], BATCH_NUTRITION) == SOURCE_NUTRITION
		and _sum_amount(evidence["arrivals"], BATCH_NUTRITION) == SOURCE_NUTRITION
		and _sum_amount(evidence["arrivals"], ORDINARY_NUTRITION) == ORDINARY_NUTRITION
		and source.get_harvested_nutrition() == SOURCE_NUTRITION and int(evidence["exhausted_signals"]) == 1,
		"Exactly eight unique ten batches and one ordinary four digest and physically return once")
	_check(level.mother_core.nutrition == 84 - ORGAN_COST and evidence["matured"].size() == 1
		and level.cultivation_system.get_total_structure_consumed() == STRUCTURE_COST,
		"Returned original resources fund exactly12 for the existing empty junction")
	var remote_balance: int = level.mother_core.nutrition
	var request_id: int = _place_remote(level, evidence, REMOTE_TARGET)
	var requested: Dictionary = _remote(level).call("get_request_snapshot")
	var remote_growth: Dictionary = requested["growth_snapshot"]
	_check(remote_growth["start_node"] == level.get_node("World/Colony/Nodes/HyphaNode")
		and is_equal_approx(float(remote_growth["total_distance"]), 320.0),
		"In-bounds B placement chooses the real nearest left node for a fresh320px route")
	_check(int(_remote(level).call("request_remote", remote_growth["start_node"], Vector2(130, 500))) == 0,
		"Active remote construction rejects a second request instead of queuing another tip")
	_press(KEY_G)
	_check(level.growth_input_controller.is_placing() and _remote(level).call("has_active_request"),
		"G may preview another queued target while the same remote execution retains the sole pipeline")
	_press(KEY_ESCAPE)
	if not await _wait_for(level, evidence, "returned_nutrition_funds_remote_defense", func() -> bool:
		return _remote(level).call("get_request_snapshot")["state"] == &"completed"):
		await _remove_level(level, evidence)
		return
	var remote_host: HyphaNode = _assert_completed_remote(level, evidence, request_id, remote_balance)
	if remote_host == null:
		await _remove_level(level, evidence)
		return
	await _wait_frames(2)
	_check(level.selected_node == host and level.cultivation_input_controller.get_selection_status()["host"] == host,
		"Original completed C host remains selected after the newer B request matures")
	var completed_hud: Dictionary = _assert_terminal_remote_hud(level, request_id, &"completed")
	_check(remote_host.global_position.distance_to(REMOTE_TARGET) < POSITION_EPSILON
		and evidence["matured"].size() == 2 and level.supply_system.get_registered_organs().size() == 4,
		"Both C and B create unique real defenses registered with ordinary combat supply")
	var before_battle: Dictionary = _resource_snapshot(level, evidence)
	_check(int(before_battle["network_structure"]) == 2 * NETWORK_COST
		and int(before_battle["organ_structure"]) == 2 * STRUCTURE_COST
		and int(before_battle["organ_stock"]) == 16 and int(before_battle["total"]) == 108,
		"Mature accounting sinks32 network and16 organ structure, holding paid startup only in the16 inventory")
	var existing_battle: Dictionary = await _exercise_battle_and_auto_supply(level, host, evidence, "existing_defense")
	var remote_battle: Dictionary = await _exercise_battle_and_auto_supply(level, remote_host, evidence, "remote_defense")
	_check(int(evidence["shots"]) == 4 and level.supply_system.delivered_packets == 2
		and _sum_amount(evidence["arrivals"], BATCH_NUTRITION) == SOURCE_NUTRITION,
		"Both returned-resource defenses fire real shots and automatically receive paid combat supply")
	_checkpoint(level, evidence, "resource_to_defense_complete")
	chain_result = {"initial_budget": 108, "initial_capital": NETWORK_COST, "harvested": source.get_harvested_nutrition(),
		"carcass_returned": _sum_amount(evidence["arrivals"], BATCH_NUTRITION),
		"ordinary_returned": _sum_amount(evidence["arrivals"], ORDINARY_NUTRITION), "batches": evidence["batches"].size(),
		"products": evidence["production"].size(), "existing_cultivation_id": existing_cultivation_id,
		"existing_cultivation_cost": ORGAN_COST, "remote": _compact_remote(_remote(level).call("get_request_snapshot")),
		"existing_battle": existing_battle, "remote_battle": remote_battle,
		"hud_remote_completed": completed_hud,
		"replayed_settled_callbacks": int(evidence["replayed_callbacks"]),
		"remote_transitions": evidence["remote_transitions"], "final_resources": _resource_snapshot(level, evidence)}
	await _remove_level(level, evidence)


func _test_cancel_paid_extension() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "cancel_extension")
	var originals: Array[int] = _node_ids(level)
	var request_id: int = _place_remote(level, evidence)
	level.growth_supply_system.auto_supply = true
	await _wait_for(level, evidence, "partial_remote_extension", func() -> bool:
		var snapshot: Dictionary = level.growth_system.get_task_snapshot()
		return int(snapshot["formed_junctions"]) == 1 and float(snapshot["distance"]) > 160.0)
	var before: Dictionary = level.growth_system.get_task_snapshot()
	var consumed: int = int(before["consumed_nutrition"])
	var mature: Array[HyphaNode] = _new_junctions(level, originals)
	_check(consumed > 0 and consumed < NETWORK_COST and mature.size() == 1
		and not level.cultivation_system.has_active_task(), "Remote cancellation begins with a paid mature node and an unfinished strand")
	_press(KEY_X)
	await _wait_frames(4)
	var cancelled: Dictionary = _remote(level).call("get_request_snapshot")
	_check(cancelled["state"] == &"cancelled" and int(cancelled["request_id"]) == request_id
		and int(cancelled["growth_consumed"]) == consumed and int(cancelled["buffered_nutrition"]) == 0
		and level.growth_supply_system.get_in_transit_count() == 0 and level.mother_core.nutrition == 72 - consumed,
		"Real X cancels extension, refunds only unspent/transit nutrition, and retains the paid network")
	var cancelled_hud: Dictionary = _assert_terminal_remote_hud(level, request_id, &"cancelled")
	_check(_new_junctions(level, originals).size() == 1 and _live_tip_count(level) == 0
		and not level.cultivation_system.has_active_task() and int(_remote(level).call("continue_request")) == 0,
		"Growth cancellation requires fresh placement and cannot mature its partial endpoint for free")
	var stump_count: int = 0
	for node: Node2D in level.network_system.get_registered_nodes():
		if not originals.has(node.get_instance_id()) and not node is HyphaNode:
			stump_count += 1
			_check(node.global_position.distance_to(before["tip_position"]) < POSITION_EPSILON
				and level.network_system.is_connected_to_core(node) and level.fungal_field.get_effective_radius(node) == 0.0,
				"Cancelled paid strand keeps the actual connected inert stump without mature coverage")
	_check(stump_count == 1, "Exactly one inert stump retains the paid incomplete strand")
	# 旧编号的完成通知只能被忽略；它不能伪造首次营养入账或触发器官移交。
	level.growth_system.task_completed.emit(int(before["task_id"]))
	level.growth_system.task_completed.emit(int(before["task_id"]))
	await _wait_frames(180)
	_check(_remote(level).call("get_request_snapshot")["state"] == &"cancelled"
		and level.mother_core.nutrition == 72 - consumed and evidence["matured"].is_empty()
		and _new_junctions(level, originals).size() == 1 and evidence["completed_requests"].is_empty(),
		"Late cancelled growth events cannot regrow, create a free bud, or complete the remote request")
	_checkpoint(level, evidence, "cancelled_extension_preserved")
	extension_cancel_result = {"request_id": request_id, "sunk_network": consumed,
		"preserved_junctions": mature.size(), "inert_stumps": stump_count, "core": int(level.mother_core.nutrition),
		"hud_cancelled": cancelled_hud}
	await _remove_level(level, evidence)


func _test_cancel_then_continue_remote_cultivation() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "continue_remote")
	var request_id: int = _place_remote(level, evidence)
	level.growth_supply_system.auto_supply = true
	level.cultivation_supply_system.auto_supply = true
	await _wait_for(level, evidence, "partial_remote_cultivation", func() -> bool:
		var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
		return snapshot["phase"] == &"cultivation" and int(snapshot["structure_consumed"]) >= 2 \
			and float(snapshot["cultivation_snapshot"].get("effective_time", 0.0)) > 0.45)
	var paid: Dictionary = _remote(level).call("get_request_snapshot")
	var endpoint: HyphaNode = paid["endpoint"] as HyphaNode
	if endpoint == null:
		_check(false, "Remote continuation needs its actual stored growth endpoint")
		await _remove_level(level, evidence)
		return
	var bud: OrganBud = endpoint.get_organ_bud()
	var node_count: int = level.hypha_nodes.get_child_count()
	var edge_count: int = level.hypha_edges.get_child_count()
	_press(KEY_P)
	_check(_remote(level).call("get_request_snapshot")["state"] == &"paused" and not paused,
		"Real P pauses the remote cultivation request while its scene keeps running")
	await _wait_for(level, evidence, "paused_paid_cultivation_transit_settled", func() -> bool:
		return level.cultivation_supply_system.get_in_transit_count() == 0)
	var frozen: Dictionary = _remote(level).call("get_request_snapshot")
	_check(int(frozen["structure_consumed"]) == int(paid["structure_consumed"])
		and is_equal_approx(float(frozen["cultivation_snapshot"]["effective_time"]), float(paid["cultivation_snapshot"]["effective_time"]))
		and evidence["matured"].is_empty(), "Paused remote bud preserves its funded stage/time without maturing")
	_press(KEY_X)
	await _wait_frames(4)
	var cancelled: Dictionary = _remote(level).call("get_request_snapshot")
	var structure: int = int(paid["structure_consumed"])
	_check(cancelled["state"] == &"cancelled" and cancelled["endpoint"] == endpoint
		and int(cancelled["growth_consumed"]) == NETWORK_COST and int(cancelled["structure_consumed"]) == structure
		and int(cancelled["total_cost"]) == FULL_COST and int(cancelled["remaining_cost"]) == ORGAN_COST - structure
		and int(cancelled["buffered_nutrition"]) == 0 and int(cancelled["startup_reserved"]) == 0
		and level.mother_core.nutrition == 72 - NETWORK_COST - structure,
		"Cultivation cancellation retains full28 budget and paid16 network/structure while refunding only unspent funds")
	var cancelled_hud: Dictionary = _assert_terminal_remote_hud(level, request_id, &"cancelled")
	_check(endpoint.get_organ_bud() == bud and _live_organs(endpoint).is_empty()
		and not _remote(level).call("cancel_request"), "Cancelled cultivation keeps its unique paid bud and cannot settle cancellation twice")
	level.growth_system.task_completed.emit(int(paid["growth_task_id"]))
	await _wait_frames(2)
	var continued_id: int = int(_remote(level).call("continue_request"))
	var continued: Dictionary = _remote(level).call("get_request_snapshot")
	_check(continued_id > request_id and int(continued["request_id"]) == continued_id
		and int(continued["cultivation_task_id"]) > int(paid["cultivation_task_id"])
		and int(continued["growth_task_id"]) == int(paid["growth_task_id"])
		and continued["endpoint"] == endpoint and endpoint.get_organ_bud() == bud
		and int(continued["total_cost"]) == FULL_COST and int(continued["growth_consumed"]) == NETWORK_COST,
		"Continuation uses fresh monotonic request/cultivation identities at the stored endpoint with the full original budget")
	_check(not level.cultivation_system.receive_nutrition(int(paid["cultivation_task_id"]), "construction-stale-attempt", 1),
		"Old cultivation identity rejects a delayed delivery after continuation")
	level.growth_system.task_completed.emit(int(paid["growth_task_id"]))
	level.cultivation_system.task_completed.emit(int(paid["cultivation_task_id"]))
	await _wait_frames(2)
	_check(level.hypha_nodes.get_child_count() == node_count and level.hypha_edges.get_child_count() == edge_count
		and _live_tip_count(level) == 0 and endpoint.get_organ_bud() == bud,
		"Late completed growth/old cultivation events cannot regrow or duplicate the continued bud")
	await _wait_for(level, evidence, "continued_remote_maturity", func() -> bool:
		return _remote(level).call("get_request_snapshot")["state"] == &"completed")
	_assert_completed_remote(level, evidence, continued_id, 72)
	var historic: Dictionary = level.cultivation_system.get_task_snapshot(int(paid["cultivation_task_id"]))
	_check(historic["state"] == &"cancelled" and int(historic["structure_consumed"]) == structure
		and level.hypha_nodes.get_child_count() == node_count and level.hypha_edges.get_child_count() == edge_count
		and evidence["matured"].size() == 1 and _live_organs(endpoint).size() == 1,
		"Historic cancellation stays frozen while the same paid bud matures once without a second network")
	continuation_result = {"cancelled_request": request_id, "continued_request": continued_id,
		"retained_structure": structure, "endpoint_id": endpoint.get_instance_id(),
		"total_paid": 72 - int(level.mother_core.nutrition), "regrown_junctions": 0,
		"transitions": evidence["remote_transitions"], "hud_cancelled": cancelled_hud}
	await _remove_level(level, evidence)


func _interrupt_route(level: Node2D, evidence: Dictionary, route: NetworkRoute, phase: String) -> void:
	_check(route.found and not route.segments.is_empty(), "%s has a real route to interrupt" % phase)
	if not route.found or route.segments.is_empty():
		return
	# 生长末段必须保持 tip/edge 几何有效；断开其上游已成熟边，验证真实 disconnected 状态。
	var segment_index: int = route.segments.size() - 2 if phase == "growth" else route.segments.size() - 1
	_check(segment_index >= 0, "%s route has an upstream paid segment" % phase)
	if segment_index < 0:
		return
	var segment: NetworkRoute.Segment = route.segments[segment_index]
	var edge: HyphaEdge = segment.edge
	var previous_end: Node2D = edge.end_node
	var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
	var growth_distance: float = float(snapshot["growth_snapshot"].get("distance", 0.0))
	var structure: int = int(snapshot["structure_consumed"])
	var effective_time: float = float(snapshot["cultivation_snapshot"].get("effective_time", 0.0))
	var balance: int = level.mother_core.nutrition
	edge.end_node = null
	await _wait_frames(2)
	_check(_remote(level).call("resume_request"), "%s resumes its paused request against the disconnected network" % phase)
	await _wait_frames(180)
	var waiting: Dictionary = _remote(level).call("get_request_snapshot")
	_check(waiting["state"] == &"waiting" and waiting["wait_reason"] == &"disconnected"
		and int(waiting["request_id"]) == int(snapshot["request_id"])
		and is_equal_approx(float(waiting["growth_snapshot"].get("distance", 0.0)), growth_distance)
		and int(waiting["structure_consumed"]) == structure
		and is_equal_approx(float(waiting["cultivation_snapshot"].get("effective_time", 0.0)), effective_time)
		and level.mother_core.nutrition == balance,
		"%s disconnection waits with no unpaid growth, effective time, structure, or extra debit" % phase)
	_checkpoint(level, evidence, phase + "_disconnected_wait")
	edge.end_node = previous_end
	await _wait_frames(2)
	_check(level.network_system.is_route_valid(route), "%s restores the original live edge rather than creating a free bypass" % phase)
	_checkpoint(level, evidence, phase + "_original_edge_reconnected")


func _test_disconnection_and_reconnection() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "reconnect")
	var request_id: int = _place_remote(level, evidence)
	level.growth_supply_system.auto_supply = true
	level.cultivation_supply_system.auto_supply = true
	await _wait_for(level, evidence, "growth_route_before_disconnect", func() -> bool:
		var growth: Dictionary = level.growth_system.get_task_snapshot()
		return int(growth["formed_junctions"]) == 1 and float(growth["distance"]) > 160.0)
	_check(_remote(level).call("pause_request"), "Remote coordinator can pause real growth independently of SceneTree")
	await _wait_for(level, evidence, "paused_growth_shipments_settled", func() -> bool:
		return level.growth_supply_system.get_in_transit_count() == 0)
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var tip: Node2D = level.growth_system.get_delivery_target(int(growth["task_id"])) as Node2D
	var growth_route: NetworkRoute = level.network_system.find_route(level.mother_core, tip)
	await _interrupt_route(level, evidence, growth_route, "growth")
	await _wait_for(level, evidence, "cultivation_route_before_disconnect", func() -> bool:
		var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
		return snapshot["phase"] == &"cultivation" and int(snapshot["structure_consumed"]) >= 2)
	_check(_remote(level).call("pause_request"), "Remote coordinator pauses the actual cultivation phase")
	await _wait_for(level, evidence, "paused_cultivation_shipments_settled", func() -> bool:
		return level.cultivation_supply_system.get_in_transit_count() == 0)
	var snapshot: Dictionary = _remote(level).call("get_request_snapshot")
	var endpoint: HyphaNode = snapshot["endpoint"] as HyphaNode
	if endpoint == null:
		_check(false, "Reconnect cultivation retains its actual endpoint")
		await _remove_level(level, evidence)
		return
	var cultivation_route: NetworkRoute = level.network_system.find_route(level.mother_core, endpoint)
	await _interrupt_route(level, evidence, cultivation_route, "cultivation")
	await _wait_for(level, evidence, "reconnected_remote_maturity", func() -> bool:
		return _remote(level).call("get_request_snapshot")["state"] == &"completed")
	_assert_completed_remote(level, evidence, request_id, 72)
	_check(evidence["matured"].size() == 1 and evidence["handoffs"].size() == 1,
		"Growth and cultivation reconnect finish the same request with one unique handoff and maturity")
	reconnect_result = {"request_id": request_id, "phases_interrupted": ["growth", "cultivation"],
		"total_paid": 72 - int(level.mother_core.nutrition), "matured": evidence["matured"].size(),
		"transitions": evidence["remote_transitions"]}
	await _remove_level(level, evidence)


func _test_reset_before_deferred_handoff() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "reset_handoff")
	var request_id: int = _place_remote(level, evidence)
	var initial: Dictionary = _remote(level).call("get_request_snapshot")
	var growth_id: int = int(initial["growth_task_id"])
	var gate: Dictionary = {"reset": false, "endpoint": null}
	# 实际 growth_completed 先经过生产监听者，再在同一栈中重置，抢在其已排队移交之前失效。
	level.growth_system.task_completed.connect(func(completed_id: int) -> void:
		if completed_id != growth_id or bool(gate["reset"]):
			return
		gate["endpoint"] = level.growth_system.get_completed_endpoint(completed_id)
		gate["reset"] = true
		_remote(level).call("reset")
		level.cultivation_supply_system.reset()
		level.growth_supply_system.reset()
		level.cultivation_system.reset())
	level.growth_supply_system.auto_supply = true
	await _wait_for(level, evidence, "reset_at_actual_completed_growth", func() -> bool:
		return bool(gate["reset"]))
	await _wait_frames(4)
	var endpoint: HyphaNode = gate["endpoint"] as HyphaNode
	_check(endpoint != null and _remote(level).call("get_request_snapshot")["state"] == &"idle"
		and not _remote(level).call("has_active_request") and not level.cultivation_system.has_active_task()
		and endpoint.get_organ_bud() == null and level.mother_core.nutrition == 72 - NETWORK_COST,
		"Reset before deferred handoff preserves the paid endpoint and invalidates the queued free-bud opportunity")
	level.growth_system.task_completed.emit(growth_id)
	level.growth_system.task_completed.emit(growth_id)
	await _wait_frames(180)
	_check(evidence["matured"].is_empty() and level.cultivation_supply_system.get_in_transit_count() == 0
		and endpoint != null and endpoint.get_organ_bud() == null and evidence["completed_requests"].is_empty(),
		"Late old completed signals cannot revive the reset request or create its cultivation")
	_checkpoint(level, evidence, "reset_guard_rejects_late_handoff")
	var next_id: int = 0
	if endpoint != null:
		next_id = int(_remote(level).call("request_remote", endpoint, Vector2(1100, 600)))
		_check(next_id > request_id, "Same coordinator never reuses a request ID after reset")
		_check(int(_remote(level).call("get_request_snapshot")["growth_task_id"]) > growth_id,
			"Reset also preserves monotonic underlying growth identities")
		_check(_remote(level).call("cancel_request"), "Fresh post-reset placement can settle without another paid investment")
	await _wait_frames(4)
	_checkpoint(level, evidence, "post_reset_request_identity")
	handoff_reset_result = {"old_request": request_id, "new_request": next_id,
		"retained_paid_network": NETWORK_COST, "ghost_buds": 0, "core": int(level.mother_core.nutrition)}
	await _remove_level(level, evidence)


func _test_restart_with_paid_transport(cultivation_phase: bool) -> void:
	var level: Node2D = await _new_level()
	var label: String = "restart_cultivation" if cultivation_phase else "restart_growth"
	var evidence: Dictionary = _observe(level, label)
	var request_id: int = _place_remote(level, evidence)
	if cultivation_phase:
		level.growth_supply_system.auto_supply = true
		await _wait_for(level, evidence, "restart_actual_cultivation_handoff", func() -> bool:
			return _remote(level).call("get_request_snapshot")["phase"] == &"cultivation")
	var balance: int = level.mother_core.nutrition
	var dispatched: bool = level.cultivation_supply_system.try_dispatch() if cultivation_phase else level.growth_supply_system.try_dispatch()
	_check(dispatched and level.mother_core.nutrition == balance - 1,
		"%s holds one genuinely prepaid construction shipment" % label)
	var path: String = "World/CultivationPackets" if cultivation_phase else "World/GrowthPackets"
	var packet: Node2D = _first_packet(level, path)
	if packet == null:
		await _remove_level(level, evidence)
		return
	await _wait_movement(packet)
	var old_packet_id: int = packet.get_instance_id()
	var old_remote_id: int = _remote(level).get_instance_id()
	var owner: Node = level.cultivation_supply_system if cultivation_phase else level.growth_supply_system
	var old_callbacks: Array[Callable] = _callbacks(packet, owner, &"arrived")
	old_callbacks.append_array(_callbacks(packet, owner, &"interrupted"))
	var balances: Array[int] = []
	level.mother_core.nutrition_changed.connect(func(value: int) -> void: balances.append(value))
	_checkpoint(level, evidence, "restart_prepaid_packet")
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	for _frame: int in range(30):
		await _step()
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	evidence["active"] = false
	await _wait_frames(2)
	var restarted: Node2D = current_scene as Node2D
	_check(is_instance_valid(restarted) and restarted != level and not is_instance_valid(level),
		"%s actual R input removes the old real level" % label)
	if not is_instance_valid(restarted) or restarted == level:
		if is_instance_valid(level):
			await _remove_level(level, evidence)
		return
	_stop_isolated_timers(restarted)
	var callbacks_retired: bool = true
	for callback: Callable in old_callbacks:
		callbacks_retired = callbacks_retired and not callback.is_valid()
	_check(not balances.is_empty() and balances.back() == balance,
		"R refunds the one unspent packet to its original live source before scene removal")
	_check(not is_instance_valid(instance_from_id(old_packet_id))
		and not is_instance_valid(instance_from_id(old_remote_id)) and callbacks_retired,
		"Old packet, coordinator, and bound settlement callbacks are retired during restart")
	_check(_remote(restarted).call("get_request_snapshot")["state"] == &"idle"
		and not _remote(restarted).call("has_active_request")
		and restarted.growth_system.get_task_snapshot()["state"] == &"idle"
		and restarted.cultivation_system.get_task_snapshot()["state"] == &"idle"
		and restarted.growth_supply_system.get_shipment_records().is_empty()
		and restarted.cultivation_supply_system.get_shipment_records().is_empty(),
		"R clears remote/underlying construction identities, buffers, and shipment accounts")
	for container: String in ["World/GrowthPackets", "World/CultivationPackets", "World/GrowthTips",
			"World/GrowthTargets", "World/ReturnPackets", "World/RecoveryPackets", "World/Packets",
			"World/Enemies", "World/Projectiles", "World/Remains"]:
		_check(restarted.get_node(container).get_child_count() == 0,
			"%s R removes all legacy objects from %s" % [label, container])
	_check(restarted.mother_core.nutrition == 72 and restarted.hypha_nodes.get_child_count() == 3
		and restarted.hypha_edges.get_child_count() == 4 and restarted.supply_system.get_registered_organs().size() == 2
		and restarted.mother_core.get_received_product_count() == 0 and restarted.colony_progress.get_total_recovered() == 0,
		"Restart restores exact default capital, preset defenses, network, and empty recovered ledger")
	var fresh: Dictionary = _observe(restarted, label + "_fresh")
	# 使用有界帧窗口观察旧包原本足以走完的时间，不依赖主机墙钟或无限等待。
	for frame: int in range(1200):
		await _step()
		if frame % 30 == 0:
			_checkpoint(restarted, fresh, "restart_late_window", false)
	_check(restarted.mother_core.nutrition == 72 and fresh["matured"].is_empty()
		and fresh["arrivals"].is_empty() and _remote(restarted).call("get_request_snapshot")["state"] == &"idle",
		"Waiting beyond old transport time creates no ghost debit, refund, arrival, handoff, or maturity")
	_checkpoint(restarted, fresh, "restart_no_old_events")
	restart_results.append({"phase": "cultivation" if cultivation_phase else "growth", "old_request": request_id,
		"refunded_original_balance": balance, "new_core": int(restarted.mother_core.nutrition),
		"callbacks_retired": callbacks_retired, "new_resources": _resource_snapshot(restarted, fresh)})
	await _remove_level(restarted, fresh)
