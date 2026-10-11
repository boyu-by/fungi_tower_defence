extends SceneTree
## 已有宿主之间的真实付费连接：固定路线运输、资源守恒、器官身份及关卡输入。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const STEP: float = 0.05
const STEP_LIMIT: int = 5000
const HOST_PATHS: Array[String] = [
	"World/Colony/Nodes/HyphaNode", "World/Colony/Nodes/RightNode", "World/Colony/Nodes/RearNode",
]
const OLD_EDGE_PATHS: Array[String] = [
	"World/Colony/Connections/HyphaEdge", "World/Colony/Connections/RecoveryEdge",
	"World/Colony/Connections/DigestionEdge", "World/Colony/Connections/RightEdge",
]
const PACKET_PATHS: Array[String] = [
	"World/GrowthPackets", "World/Packets", "World/RecoveryPackets", "World/ReturnPackets",
]

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var case_results: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_natural_route_and_input()
	await _test_paid_loop_and_logistics()
	await _test_reversed_source_and_supply_loss()
	await _test_cancellation_and_old_callbacks()
	await _test_restart_with_paid_packet()
	_check(root.get_child_count() == 0, "Connection integration teardown leaves no scene objects")
	print("CONNECTION_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "conservation_checks": conservation_checks,
		"cases": case_results,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _prepare_level(level: Node2D, short_connection: bool = false) -> void:
	# 旧单执行器兼容夹具；正式 7.3 多实例路径由 multitip_construction_test 验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	level.get_node("Systems/SupplySystem/DispatchTimer").autostart = false
	level.get_node("Systems/RecyclingSystem/DispatchTimer").autostart = false
	for path: String in HOST_PATHS:
		var weapon: Node = level.get_node(path).get_node_or_null("SporeWeapon")
		if weapon != null:
			weapon.get_node("FireTimer").autostart = false
	if short_connection:
		# 只配置夹具位置；原有器官、边和最少段数寻路规则仍使用真实关卡。
		var left: HyphaNode = level.get_node(HOST_PATHS[0]) as HyphaNode
		var right: HyphaNode = level.get_node(HOST_PATHS[1]) as HyphaNode
		right.position = left.position + Vector2(80, 0)


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _stop_level(level: Node2D) -> void:
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.growth_supply_system.auto_supply = false
	level.growth_supply_system.set_process(false)
	level.cultivation_supply_system.auto_supply = false
	level.cultivation_supply_system.set_process(false)
	level.nutrition_return_system.auto_return = false
	level.nutrition_return_system.get_node("DispatchTimer").stop()
	level.growth_system.set_physics_process(false)
	level.cultivation_system.set_physics_process(false)
	level.fungal_field.set_process(false)
	level.set_process(false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level(short_connection: bool = false) -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level, short_connection)
	root.add_child(level)
	current_scene = level
	_stop_level(level)
	await physics_frame
	await process_frame
	level.call("_process", 0.0)
	level.fungal_field.advance(1.0)
	_check(level.has_node("Systems/ConnectionSystem") and level.has_node("Systems/ConnectionInputController"),
		"Real level owns both connection systems")
	_check(level.mother_core.nutrition == 72 and level.supply_system.get_in_transit_count() == 0,
		"Fixture begins with the actual default capital and no automatic dispatch")
	return level


func _remove_level(level: Node2D, evidence: Dictionary) -> void:
	evidence["active"] = false
	if is_instance_valid(level):
		if current_scene == level:
			current_scene = null
		level.queue_free()
	await process_frame
	await process_frame


func _connection(level: Node2D) -> Node:
	return level.get_node("Systems/ConnectionSystem")


func _input(level: Node2D) -> Node:
	return level.get_node("Systems/ConnectionInputController")


func _snapshot(level: Node2D) -> Dictionary:
	return _connection(level).call("get_task_snapshot")


func _left(level: Node2D) -> HyphaNode:
	return level.get_node(HOST_PATHS[0]) as HyphaNode


func _right(level: Node2D) -> HyphaNode:
	return level.get_node(HOST_PATHS[1]) as HyphaNode


func _rear(level: Node2D) -> HyphaNode:
	return level.get_node(HOST_PATHS[2]) as HyphaNode


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

	# 7.2 入队与执行分开；显式推进调度，不伪造运输或注入施工缓存。
	if is_instance_valid(current_scene):
		current_scene.construction_coordinator.pump()


func _remember_growth(snapshot: Dictionary, evidence: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		var costs: Dictionary = evidence["growth_costs"]
		costs[task_id] = maxi(int(costs.get(task_id, 0)), int(snapshot.get("consumed_nutrition", 0)))


func _observe(level: Node2D, label: String) -> Dictionary:
	var evidence: Dictionary = {
		"label": label, "active": true, "initial_total": 0, "growth_costs": {},
		"packets": {}, "formed": [], "growth_completed": [], "completed": [], "cancelled": [],
		"source_id": 0, "target_id": 0, "callback_replays": 0, "checkpoints": [],
	}
	level.growth_system.task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_growth(snapshot, evidence))
	level.growth_system.junction_formed.connect(func(host: HyphaNode) -> void:
		if bool(evidence["active"]):
			var formed: Array = evidence["formed"]
			formed.append(host.get_instance_id()))
	level.growth_system.task_completed.connect(func(task_id: int) -> void:
		if not bool(evidence["active"]):
			return
		var snapshot: Dictionary = level.growth_system.get_task_snapshot()
		if snapshot.get("task_kind", &"") != &"connection":
			return
		var completed: Array = evidence["growth_completed"]
		completed.append(task_id)
		var target: HyphaNode = snapshot.get("target_node") as HyphaNode
		_check(target != null and target.get_instance_id() == int(evidence["target_id"])
			and level.growth_system.get_completed_endpoint(task_id) == target
			and level.network_system.has_direct_connection(snapshot["start_node"], target),
			"Final existing-host connection is committed before GrowthSystem completion is observed"))
	_connection(level).connect(&"task_completed", func(task_id: int) -> void:
		if bool(evidence["active"]):
			var completed: Array = evidence["completed"]
			completed.append(task_id))
	_connection(level).connect(&"task_cancelled", func(task_id: int) -> void:
		if bool(evidence["active"]):
			var cancelled: Array = evidence["cancelled"]
			cancelled.append(task_id))
	_connection(level).connect(&"connection_completed", func(task_id: int, source: HyphaNode, target: HyphaNode) -> void:
		if not bool(evidence["active"]):
			return
		_check(source.get_instance_id() == int(evidence["source_id"])
			and target.get_instance_id() == int(evidence["target_id"])
			and level.growth_system.get_completed_endpoint(task_id) == target
			and level.network_system.is_route_valid(level.network_system.find_route(source, target)),
			"Connection completion reports the exact selected existing hosts and an already valid route"))
	_watch_container(level, "World/GrowthPackets", "growth", level.growth_supply_system, evidence)
	_watch_container(level, "World/Packets", "supply", level.supply_system, evidence)
	_watch_container(level, "World/RecoveryPackets", "haul", level.recycling_system, evidence)
	_watch_container(level, "World/ReturnPackets", "return", level.nutrition_return_system, evidence)
	evidence["initial_total"] = int(_resources(level, evidence)["total"])
	_checkpoint(level, evidence, "initial")
	return evidence


func _callbacks(packet: Node, owner: Node, event: StringName) -> Array[Callable]:
	var result: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(event):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			result.append(callback)
	return result


func _watch_container(level: Node2D, path: String, kind: String, owner: Node, evidence: Dictionary) -> void:
	level.get_node(path).child_entered_tree.connect(func(child: Node) -> void:
		if not bool(evidence["active"]) or not (child is NutrientPacket or child is RemainsPacket):
			return
		var packet: Node2D = child as Node2D
		packet.set_physics_process(false)
		var records: Dictionary = evidence["packets"]
		var record: Dictionary = {
			"id": packet.get_instance_id(), "kind": kind, "packet": packet, "edges": [],
			"movements": 0, "arrivals": 0, "interruptions": 0,
			"arrived_callbacks": _callbacks(packet, owner, &"arrived"),
			"interrupted_callbacks": _callbacks(packet, owner, &"interrupted"),
		}
		records[packet.get_instance_id()] = record
		_check(not record["arrived_callbacks"].is_empty() and not record["interrupted_callbacks"].is_empty(),
			"%s packet is owned by real settlement callbacks before entering the world" % kind)
		if kind == "return":
			var body: Polygon2D = packet.get_node("Body") as Polygon2D
			var glow: Polygon2D = packet.get_node("Glow") as Polygon2D
			var trail: Line2D = packet.get_node("Trail") as Line2D
			_check(packet.get("speed") == 80.0 and not String(packet.get_meta("return_product_id", "")).is_empty()
				and body.color.g > body.color.r and body.color.g > body.color.b
				and glow.color.g > glow.color.r and glow.color.g > glow.color.b
				and trail.default_color.g > trail.default_color.r and trail.default_color.g > trail.default_color.b,
				"Real nutrition return uses its unique product ID, green visuals, and normal 80px/s speed")
		packet.connect(&"arrived", func(finished: Node2D) -> void:
			if not bool(evidence["active"]):
				return
			record["arrivals"] = int(record["arrivals"]) + 1
			if kind == "return":
				_check(finished.global_position.is_equal_approx(level.mother_core.global_position),
					"Green packet is credited only after physically reaching the core")
			elif kind == "haul":
				_check(finished.global_position.is_equal_approx(_rear(level).global_position),
					"Carcass batch is queued only after physically reaching the digestive host")
			_replay_settled_callbacks(level, evidence, record))
		packet.connect(&"interrupted", func(_finished: Node2D) -> void:
			if bool(evidence["active"]):
				record["interruptions"] = int(record["interruptions"]) + 1
				_replay_settled_callbacks(level, evidence, record)))


func _replay_settled_callbacks(level: Node2D, evidence: Dictionary, record: Dictionary) -> void:
	var packet: Variant = record["packet"]
	if not is_instance_valid(packet):
		return
	var before: Dictionary = _resources(level, evidence)
	# 首次收件始终由真实移动触发；这里只重放已经到达或中断的旧结算回调。
	for key: String in ["arrived_callbacks", "interrupted_callbacks"]:
		for callback: Callable in record[key]:
			if callback.is_valid():
				callback.call(packet)
				callback.call(packet)
				evidence["callback_replays"] = int(evidence["callback_replays"]) + 2
	_check(_resources(level, evidence) == before,
		"Repeated settled %s callbacks neither duplicate income nor refund another task" % record["kind"])


func _resources(level: Node2D, evidence: Dictionary) -> Dictionary:
	var parts: Dictionary = {
		"core": int(level.mother_core.nutrition), "organ_stock": 0, "combat_transit": 0,
		"growth_transit": 0, "growth_buffer": 0, "network_investment": 0,
		"carcass_source": 0, "live_remains": 0,
		"digestive_queue": int(level.digestive_organ.get_queued_nutrition()),
		"digestive_output_including_return_transit": int(level.digestive_organ.get_output_nutrition()),
		"cultivation_transit": int(level.cultivation_supply_system.get_in_transit_nutrition()),
	}
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
		# 入站预留和已扣款运输是同一笔营养，不另加一份容量。
		parts["combat_transit"] = int(parts["combat_transit"]) + organ.incoming_nutrition
	for shipment: Dictionary in level.growth_supply_system.get_shipment_records():
		if bool(shipment["debited"]) and not bool(shipment["settled"]) and not bool(shipment["refunded"]):
			parts["growth_transit"] = int(parts["growth_transit"]) + GrowthSupplySystem.PACKET_NUTRITION
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_remember_growth(growth, evidence)
	parts["growth_buffer"] = int(growth.get("buffered_nutrition", 0))
	var costs: Dictionary = evidence["growth_costs"]
	for consumed: int in costs.values():
		parts["network_investment"] = int(parts["network_investment"]) + consumed
	var cultivation: Dictionary = level.cultivation_system.get_resource_snapshot()
	parts["cultivation_structure"] = int(cultivation["structure_consumed"])
	parts["cultivation_buffer"] = int(cultivation["buffered_nutrition"])
	parts["startup_reserved"] = int(cultivation["startup_reserved"])
	for child: Node in level.get_node("World/Remains").get_children():
		if child.is_queued_for_deletion():
			continue
		if child is LargeCarcass:
			parts["carcass_source"] = int(parts["carcass_source"]) + child.get_remaining_nutrition()
		elif child is EnemyRemains:
			# 搬运包只引用已领取尸块；胃囊入站预留同样不再增加营养。
			parts["live_remains"] = int(parts["live_remains"]) + child.nutrition_value
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	return parts


func _checkpoint(level: Node2D, evidence: Dictionary, phase: String, remember: bool = true) -> void:
	var parts: Dictionary = _resources(level, evidence)
	conservation_checks += 1
	_check(int(parts["total"]) == int(evidence["initial_total"]),
		"%s/%s conserves core, owned packets, organs, remains, products, and paid structure" % [evidence["label"], phase])
	_check(int(parts["combat_transit"]) == level.supply_system.get_in_transit_count(),
		"%s/%s normal supply reservations match actual prepaid packets" % [evidence["label"], phase])
	if remember:
		var checkpoints: Array = evidence["checkpoints"]
		checkpoints.append({"phase": phase, "resources": parts})


func _tick(level: Node2D, evidence: Dictionary, feed_growth: bool = false) -> void:
	if feed_growth:
		level.growth_supply_system.try_dispatch()
	for path: String in PACKET_PATHS:
		for child: Node in level.get_node(path).get_children():
			if child.is_queued_for_deletion() or not (child is NutrientPacket or child is RemainsPacket):
				continue
			var packet: Node2D = child as Node2D
			var before: Vector2 = packet.global_position
			packet.call("_physics_process", STEP)
			if not is_instance_valid(packet):
				continue
			var records: Dictionary = evidence["packets"]
			var record: Dictionary = records.get(packet.get_instance_id(), {})
			if record.is_empty() or packet.global_position.is_equal_approx(before):
				continue
			record["movements"] = int(record["movements"]) + 1
			var edge: HyphaEdge = packet.get("edge") as HyphaEdge
			var progress: float = float(packet.get("progress"))
			if edge != null and progress > 0.0 and progress < 1.0:
				var traversed: Array = record["edges"]
				if not traversed.has(edge.get_instance_id()):
					traversed.append(edge.get_instance_id())
	level.growth_system.advance(STEP)
	level.growth_supply_system.call("_process", STEP)
	level.call("_process", 0.0)
	level.fungal_field.advance(STEP)


func _until(level: Node2D, evidence: Dictionary, label: String, condition: Callable,
		feed_growth: bool = false, limit: int = STEP_LIMIT) -> bool:
	for step: int in range(limit):
		if bool(condition.call()):
			break
		_tick(level, evidence, feed_growth)
		if step % 50 == 0:
			_checkpoint(level, evidence, label + "_in_progress", false)
	var reached: bool = bool(condition.call())
	_check(reached, "%s reaches %s using real transport before the bounded step limit" % [evidence["label"], label])
	_checkpoint(level, evidence, label)
	return reached


func _finish_connection(level: Node2D, evidence: Dictionary) -> bool:
	return _until(level, evidence, "connection_completed", func() -> bool:
		return _snapshot(level).get("state", &"idle") == &"completed", true)


func _organ_state(level: Node2D) -> Dictionary:
	var state: Dictionary = {"hosts": [], "organs": [], "weapons": []}
	var hosts: Array = state["hosts"]
	for path: String in HOST_PATHS:
		var host: HyphaNode = level.get_node(path) as HyphaNode
		var occupant: Node = host.get_organ_occupant()
		var children: Array[int] = []
		for child: Node in host.get_children():
			children.append(child.get_instance_id())
		hosts.append({"host_id": host.get_instance_id(), "position": host.global_position,
			"occupant_id": occupant.get_instance_id() if occupant != null else 0,
			"slot_state": host.get_organ_slot_state(), "slot_available": host.is_organ_slot_available(),
			"children": children})
	var organs: Array = state["organs"]
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		organs.append({"id": organ.get_instance_id(), "stock": organ.nutrition,
			"incoming": organ.incoming_nutrition, "capacity": organ.capacity})
	var weapons: Array = state["weapons"]
	for weapon: SporeWeapon in level.get_weapons():
		weapons.append(weapon.get_instance_id())
	state["digestive_id"] = level.digestive_organ.get_instance_id()
	state["digestive_incoming"] = level.digestive_organ.incoming_remains
	state["digestive_queue"] = level.digestive_organ.get_queued_nutrition()
	state["digestive_output"] = level.digestive_organ.get_output_snapshot()
	state["digested"] = level.digestive_organ.digested_count
	return state


func _old_routes(level: Node2D) -> Array[NetworkRoute]:
	var routes: Array[NetworkRoute] = []
	for path: String in OLD_EDGE_PATHS:
		var edge: HyphaEdge = level.get_node(path) as HyphaEdge
		var route: NetworkRoute = level.network_system.find_route(edge.start_node, edge.end_node)
		_check(route.found and route.segments.size() == 1 and route.segments[0].edge == edge,
			"Original edge %s has its own registered route" % edge.name)
		routes.append(route)
	return routes


func _assert_old_routes(level: Node2D, routes: Array[NetworkRoute], label: String) -> void:
	for route: NetworkRoute in routes:
		_check(level.network_system.is_route_valid(route), label + " preserves every original edge and its exact endpoints")


func _assert_simple_routes(level: Node2D) -> void:
	var nodes: Array[Node2D] = level.network_system.get_registered_nodes()
	for first: Node2D in nodes:
		for second: Node2D in nodes:
			var route: NetworkRoute = level.network_system.find_route(first, second)
			var simple: bool = route.found and level.network_system.is_route_valid(route)
			var visited: Dictionary[int, bool] = {first.get_instance_id(): true}
			for segment: NetworkRoute.Segment in route.segments:
				if visited.has(segment.end_node.get_instance_id()):
					simple = false
				visited[segment.end_node.get_instance_id()] = true
			_check(simple and route.segments.size() < nodes.size(),
				"Loop route %s -> %s terminates with no repeated node" % [first.name, second.name])


func _preview(level: Node2D, first: HyphaNode, second: HyphaNode) -> Dictionary:
	var before: int = level.mother_core.nutrition
	var hosts: Dictionary = _organ_state(level)
	var count: int = level.network_system.get_registered_nodes().size()
	var preview: Dictionary = _connection(level).call("preview_connection", first, second)
	_check(preview.has_all(["valid", "error", "reason", "first_node", "second_node", "start_node",
		"target_node", "reversed", "plan", "total_cost"]), "Connection preview exposes the frozen endpoint and fee contract")
	_check(level.mother_core.nutrition == before and _organ_state(level) == hosts
		and level.network_system.get_registered_nodes().size() == count,
		"Preview neither debits nutrition nor mutates occupied hosts, slots, or topology")
	if bool(preview.get("valid", false)):
		var source: HyphaNode = preview["start_node"] as HyphaNode
		var target: HyphaNode = preview["target_node"] as HyphaNode
		var planned: Dictionary = level.growth_planner.plan(source.global_position, target.global_position, true)
		_check(preview["plan"] == planned and int(preview["total_cost"]) == int(planned["total_cost"]),
			"Preview exactly uses the shared planner with an existing fee-free target")
		_check(int(planned["junction_cost"]) == planned["junction_positions"].size() * level.growth_planner.junction_cost
			and int(planned["segments"].back()["junction_cost"]) == 0,
			"Only new relays incur junction fees; the existing final host incurs none")
	return preview


func _expect_hosts(evidence: Dictionary, preview: Dictionary) -> void:
	evidence["source_id"] = preview["start_node"].get_instance_id()
	evidence["target_id"] = preview["target_node"].get_instance_id()


func _place_connection(level: Node2D, evidence: Dictionary, first: HyphaNode, second: HyphaNode) -> int:
	var preview: Dictionary = _preview(level, first, second)
	_check(bool(preview.get("valid", false)), "Occupied existing hosts admit the requested paid connection")
	if not bool(preview.get("valid", false)):
		return 0
	_expect_hosts(evidence, preview)
	var balance: int = level.mother_core.nutrition
	_press(KEY_L)
	_check(bool(_input(level).call("is_placing")), "L enters the actual connection placement controller")
	_click(first.global_position)
	var selection: Dictionary = _input(level).call("get_selection_snapshot")
	_check(selection.get("first_node") == first and not level.growth_system.has_active_task(),
		"First click selects an existing endpoint without creating construction")
	var hovered: Dictionary = _input(level).call("preview_at", second.global_position)
	_check(bool(hovered.get("valid", false)) and hovered.get("plan") == preview["plan"],
		"Hover previews the exact connection that the second click will build")
	_click(second.global_position)
	# 7.2 正式入口先入队；在测试中显式推进下一次调度。
	level.construction_coordinator.pump()
	var snapshot: Dictionary = _snapshot(level)
	var task_id: int = int(snapshot.get("task_id", 0))
	_check(task_id > 0 and bool(_connection(level).call("has_active_task"))
		and not bool(_input(level).call("is_placing")), "Second click creates one task and exits L mode")
	_check(snapshot.get("task_kind", &"") == &"connection"
		and task_id == int(level.growth_system.get_task_snapshot().get("task_id", 0))
		and snapshot.get("start_node") == preview["start_node"] and snapshot.get("target_node") == preview["target_node"],
		"Connection uses the original GrowthSystem identity and exact selected host objects")
	_check(level.mother_core.nutrition == balance and float(snapshot.get("distance", -1.0)) == 0.0,
		"Two clicks alone provide neither a free physical link nor immediate growth funding")
	return task_id


func _new_edges(level: Node2D) -> Array[int]:
	var old_ids: Array[int] = []
	for path: String in OLD_EDGE_PATHS:
		old_ids.append(level.get_node(path).get_instance_id())
	var result: Array[int] = []
	for child: Node in level.hypha_edges.get_children():
		if child is HyphaEdge and not old_ids.has(child.get_instance_id()):
			result.append(child.get_instance_id())
	return result


func _assert_paid_completion(level: Node2D, evidence: Dictionary, task_id: int,
		preview: Dictionary, balance: int, original_nodes: int, original_organs: Dictionary) -> Array[int]:
	var snapshot: Dictionary = _snapshot(level)
	var plan: Dictionary = preview["plan"]
	var source: HyphaNode = preview["start_node"] as HyphaNode
	var target: HyphaNode = preview["target_node"] as HyphaNode
	var relays: PackedVector2Array = plan["junction_positions"]
	_check(snapshot.get("state") == &"completed" and int(snapshot.get("task_id", 0)) == task_id
		and int(snapshot.get("consumed_nutrition", -1)) == int(plan["total_cost"])
		and int(snapshot.get("buffered_nutrition", -1)) == 0
		and level.growth_supply_system.get_in_transit_count() == 0,
		"Completion consumes the exact quoted fee and clears all construction reservations")
	_check(level.mother_core.nutrition == balance - int(plan["total_cost"]),
		"Core debit exactly equals paid extension and relay fees without recharging either endpoint")
	_check(level.growth_system.get_completed_endpoint(task_id) == target
		and level.network_system.has_direct_connection(source, target),
		"Completed corridor reaches the original selected host, including a relay corridor")
	_check(level.network_system.get_registered_nodes().size() == original_nodes + relays.size()
		and int(snapshot.get("formed_junctions", -1)) == relays.size(),
		"Only paid relay nodes are added; no replacement or duplicate endpoint is created")
	for position: Vector2 in relays:
		var matches: Array[HyphaNode] = []
		for child: Node in level.hypha_nodes.get_children():
			if child is HyphaNode and child.global_position.is_equal_approx(position):
				matches.append(child as HyphaNode)
		_check(matches.size() == 1 and matches[0] != source and matches[0] != target
			and matches[0].get_organ_slot_state() == &"empty"
			and level.network_system.is_connected_to_core(matches[0]), "Each quoted paid relay is present, empty, and connected")
	var formed: Array = evidence["formed"]
	_check(formed.size() == relays.size() and not formed.has(source.get_instance_id())
		and not formed.has(target.get_instance_id()), "Existing endpoint completion emits no junction_formed for either host")
	_check(evidence["completed"] == [task_id] and evidence["growth_completed"] == [task_id],
		"Connection and underlying growth each report one completion with the same task ID")
	_check(_organ_state(level) == original_organs,
		"Connecting occupied hosts preserves organ count, identities, inventory, weapons, children, and slots")
	var edges: Array[int] = _new_edges(level)
	_check(edges.size() == relays.size() + 1, "Completed corridor has exactly the quoted number of physical edges")
	_checkpoint(level, evidence, "exact_paid_completion")
	return edges


func _first_packet(level: Node2D, path: String) -> Node2D:
	var result: Node2D = null
	for child: Node in level.get_node(path).get_children():
		if (child is NutrientPacket or child is RemainsPacket) and not child.is_queued_for_deletion():
			result = child as Node2D
			break
	_check(result != null, "Expected an actual packet in %s" % path)
	return result


func _assert_crossed(evidence: Dictionary, packet_id: int, new_edges: Array[int], label: String) -> void:
	var records: Dictionary = evidence["packets"]
	var record: Dictionary = records.get(packet_id, {})
	var crossed: bool = (
		not record.is_empty() and int(record.get("movements", 0)) > 0
		and int(record.get("arrivals", 0)) == 1 and int(record.get("interruptions", 0)) == 0
	)
	for edge_id: int in new_edges:
		crossed = crossed and record.get("edges", []).has(edge_id)
	_check(crossed, label + " physically traverses every new corridor edge and settles exactly once")


func _route_uses(route: NetworkRoute, edge_ids: Array[int]) -> bool:
	var seen: Array[int] = []
	for segment: NetworkRoute.Segment in route.segments:
		seen.append(segment.edge.get_instance_id())
	var uses: bool = route.found
	for edge_id: int in edge_ids:
		uses = uses and seen.has(edge_id)
	return uses


func _summarize(evidence: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var packets: Array[Dictionary] = []
	var records: Dictionary = evidence["packets"]
	for record: Dictionary in records.values():
		packets.append({"id": record["id"], "kind": record["kind"], "edges": record["edges"],
			"movements": record["movements"], "arrivals": record["arrivals"], "interruptions": record["interruptions"]})
	var result: Dictionary = {
		"case": evidence["label"], "initial_total": evidence["initial_total"],
		"growth_investments": evidence["growth_costs"], "completed": evidence["completed"],
		"cancelled": evidence["cancelled"], "callback_replays": evidence["callback_replays"],
		"packets": packets, "checkpoints": evidence["checkpoints"],
	}
	result.merge(extra, true)
	return result


func _test_natural_route_and_input() -> void:
	var level: Node2D = await _new_level(true)
	var evidence: Dictionary = _observe(level, "natural_route_and_input")
	var organs: Dictionary = _organ_state(level)
	var old_routes: Array[NetworkRoute] = _old_routes(level)
	var original_nodes: int = level.network_system.get_registered_nodes().size()
	var left: HyphaNode = _left(level)
	var right: HyphaNode = _right(level)
	_check(level.network_system.find_route(left, right).segments.size() == 2
		and not level.network_system.has_direct_connection(left, right), "Original indirect route permits an explicit paid loop")
	_press(KEY_L)
	_press(KEY_B)
	_check(level.cultivation_input_controller.is_remote_placing() and not bool(_input(level).call("is_placing"))
		and not level.growth_input_controller.is_placing(), "B and L placement modes exclude one another")
	_press(KEY_L)
	_check(bool(_input(level).call("is_placing")) and not level.cultivation_input_controller.is_remote_placing(),
		"L exits remote cultivation placement")
	_press(KEY_G)
	_check(level.growth_input_controller.is_placing() and not bool(_input(level).call("is_placing"))
		and not level.cultivation_input_controller.is_remote_placing(), "G exits L mode before ordinary growth placement")
	_press(KEY_ESCAPE)
	_check(not level.growth_input_controller.is_placing() and not bool(_input(level).call("is_placing")),
		"Esc exits placement without creating a task")
	var preview: Dictionary = _preview(level, left, right)
	var balance: int = level.mother_core.nutrition
	var task_id: int = _place_connection(level, evidence, left, right)
	if task_id == 0:
		await _remove_level(level, evidence)
		return
	_check(level.growth_supply_system.try_dispatch() and level.mother_core.nutrition == balance - 1
		and level.growth_supply_system.get_in_transit_count() == 1
		and int(_snapshot(level).get("consumed_nutrition", -1)) == 0,
		"Connection receives the usual genuinely prepaid GrowthSupplySystem packet")
	_press(KEY_P)
	_check(_snapshot(level).get("state") == &"paused" and not paused,
		"P pauses the current connection while the scene remains active")
	_until(level, evidence, "packet_arrives_while_paused", func() -> bool:
		return level.growth_supply_system.get_in_transit_count() == 0)
	var frozen: Dictionary = _snapshot(level)
	_check(frozen.get("state") == &"paused" and float(frozen.get("distance", -1.0)) == 0.0
		and int(frozen.get("buffered_nutrition", -1)) == 1 and level.mother_core.nutrition == balance - 1,
		"Pause accepts the already moving packet into one refundable buffer and builds nothing")
	_press(KEY_P)
	if not _finish_connection(level, evidence):
		await _remove_level(level, evidence)
		return
	var new_edges: Array[int] = _assert_paid_completion(level, evidence, task_id, preview, balance, original_nodes, organs)
	_check(int(preview["total_cost"]) == 1 and new_edges.size() == 1,
		"80px existing-host connection pays one extension unit and no endpoint or relay fee")
	_assert_old_routes(level, old_routes, "Naturally selected connection")
	_check(level.network_system.find_route(left, right).segments.size() == 1,
		"The new direct corridor is preferred to the original two-edge path while all old edges remain registered")
	var organ: AttackOrgan = right.get_node("AttackOrgan") as AttackOrgan
	var route: NetworkRoute = level.network_system.find_route(level.mother_core, right)
	_check(_route_uses(route, new_edges), "Normal least-edge supply query naturally chooses the new paid edge")
	var stock: int = organ.nutrition
	var before_supply: int = level.mother_core.nutrition
	_check(level.supply_system.request_supply(organ), "Occupied target requests a normal post-connection supply packet")
	var packet: Node2D = _first_packet(level, "World/Packets")
	var packet_id: int = packet.get_instance_id() if packet != null else 0
	_check(organ.nutrition == stock and organ.incoming_nutrition == 1 and level.mother_core.nutrition == before_supply - 1,
		"Post-connection supply debits and reserves without early inventory credit")
	_until(level, evidence, "natural_supply_arrives", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0)
	_check(organ.nutrition == stock + 1 and organ.incoming_nutrition == 0
		and level.mother_core.nutrition == before_supply - 1, "Natural new-edge supply delivers one unit without duplicate credit")
	_assert_crossed(evidence, packet_id, new_edges, "Natural normal supply")
	_assert_simple_routes(level)
	_assert_old_routes(level, old_routes, "After natural supply")
	_checkpoint(level, evidence, "natural_supply_settled")
	case_results.append(_summarize(evidence, {"task_id": task_id, "cost": preview["total_cost"], "new_edges": new_edges}))
	await _remove_level(level, evidence)


func _test_paid_loop_and_logistics() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "paid_relays_and_all_logistics")
	var organs: Dictionary = _organ_state(level)
	var old_routes: Array[NetworkRoute] = _old_routes(level)
	var left: HyphaNode = _left(level)
	var right: HyphaNode = _right(level)
	var original_nodes: int = level.network_system.get_registered_nodes().size()
	var preview: Dictionary = _preview(level, left, right)
	var balance: int = level.mother_core.nutrition
	var task_id: int = _place_connection(level, evidence, left, right)
	if task_id == 0 or not _finish_connection(level, evidence):
		await _remove_level(level, evidence)
		return
	var new_edges: Array[int] = _assert_paid_completion(level, evidence, task_id, preview, balance, original_nodes, organs)
	_check(preview["plan"]["junction_positions"].size() == 2 and int(preview["total_cost"]) == 13,
		"Original 341px occupied-host corridor pays five extension units and two four-unit relays")
	_assert_old_routes(level, old_routes, "Paid relay corridor")
	_assert_simple_routes(level)
	var settled: Dictionary = _resources(level, evidence)
	_check(not bool(_connection(level).call("preview_connection", left, right)["valid"])
		and not bool(_connection(level).call("preview_connection", right, left)["valid"])
		and int(_connection(level).call("request_connection", left, right)) == 0,
		"Completed explicit relay corridor is rejected as a duplicate in either direction")
	_check(_resources(level, evidence) == settled, "Duplicate admission never recharges a completed link")
	var right_edge: HyphaEdge = level.get_node(OLD_EDGE_PATHS[3]) as HyphaEdge
	var recovery_edge: HyphaEdge = level.get_node(OLD_EDGE_PATHS[1]) as HyphaEdge
	var digestion_edge: HyphaEdge = level.get_node(OLD_EDGE_PATHS[2]) as HyphaEdge
	var core_left_edge: HyphaEdge = level.get_node(OLD_EDGE_PATHS[0]) as HyphaEdge
	level.network_system.unregister_edge(right_edge)
	var organ: AttackOrgan = right.get_node("AttackOrgan") as AttackOrgan
	_check(_route_uses(level.network_system.find_route(level.mother_core, right), new_edges),
		"Loss of the target's old entry leaves a valid route through the completed paid corridor")
	var before_supply: int = level.mother_core.nutrition
	var old_stock: int = organ.nutrition
	_check(level.supply_system.request_supply(organ), "Long paid corridor accepts normal organ supply")
	var packet: Node2D = _first_packet(level, "World/Packets")
	var supply_id: int = packet.get_instance_id() if packet != null else 0
	_until(level, evidence, "long_corridor_supply", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0)
	_assert_crossed(evidence, supply_id, new_edges, "Normal organ supply")
	_check(organ.nutrition == old_stock + 1 and organ.incoming_nutrition == 0
		and level.mother_core.nutrition == before_supply - 1, "Long corridor transfers one paid organ nutrition unit")
	var carcass: LargeCarcass = CARCASS_SCENE.instantiate() as LargeCarcass
	carcass.position = right.global_position + Vector2(35, 0)
	level.get_node("World/Remains").add_child(carcass)
	evidence["initial_total"] = int(evidence["initial_total"]) + carcass.get_remaining_nutrition()
	level.call("_process", 0.0)
	level.fungal_field.advance(1.0)
	_check(level.fungal_field.get_collection_node(carcass.global_position) == right,
		"Large carcass is collected at the actual connected target host")
	var before_harvest: int = level.mother_core.nutrition
	_check(level.recycling_system.try_dispatch(), "Real recycling system commits a finite large-carcass batch")
	packet = _first_packet(level, "World/RecoveryPackets")
	var haul_id: int = packet.get_instance_id() if packet != null else 0
	_check(carcass.get_remaining_nutrition() == 70 and carcass.get_harvested_nutrition() == 10
		and carcass.get_reserved_nutrition() == 0 and level.digestive_organ.incoming_remains == 1
		and level.digestive_organ.get_queued_count() == 0, "Harvest owns exactly one ten-unit batch without early digestion")
	_checkpoint(level, evidence, "ten_unit_harvest_committed")
	_until(level, evidence, "carcass_haul_arrives", func() -> bool:
		return level.recycling_system.get_in_transit_count() == 0)
	_assert_crossed(evidence, haul_id, new_edges, "Large-carcass remains haul")
	_check(level.digestive_organ.get_queued_nutrition() == 10 and level.digestive_organ.incoming_remains == 0
		and level.mother_core.nutrition == before_harvest, "Actual carcass arrival queues nutrition without crediting the core")
	level.digestive_organ.digest_timer.start(0.02)
	for _frame: int in range(15):
		if level.digestive_organ.get_output_count() > 0:
			break
		await physics_frame
		await process_frame
	_check(level.digestive_organ.get_output_nutrition() == 10 and level.digestive_organ.digested_count == 1
		and level.mother_core.nutrition == before_harvest, "Actual digestion timer creates one uncredited ten-unit output product")
	level.network_system.register_edge(right_edge)
	level.network_system.unregister_edge(recovery_edge)
	level.network_system.unregister_edge(digestion_edge)
	_check(_route_uses(level.network_system.find_route(_rear(level), level.mother_core), new_edges),
		"Digestive return has a valid route across the completed connection from its opposite end")
	_check(level.nutrition_return_system.try_dispatch(), "Real return system claims the actual digested product")
	packet = _first_packet(level, "World/ReturnPackets")
	var return_id: int = packet.get_instance_id() if packet != null else 0
	_check(level.mother_core.nutrition == before_harvest and level.nutrition_return_system.get_in_transit_nutrition() == 10,
		"Green return launch carries ten units without immediate core income")
	_until(level, evidence, "green_return_arrives", func() -> bool:
		return level.nutrition_return_system.get_in_transit_count() == 0)
	_assert_crossed(evidence, return_id, new_edges, "Green nutrition return")
	_check(level.mother_core.nutrition == before_harvest + 10 and level.colony_progress.get_total_recovered() == 10
		and level.mother_core.get_received_product_count() == 1 and level.digestive_organ.get_output_nutrition() == 0,
		"Only one physically returned product credits the core and recovered ledger")
	level.network_system.register_edge(digestion_edge)
	var left_organ: AttackOrgan = left.get_node("AttackOrgan") as AttackOrgan
	var left_stock: int = left_organ.nutrition
	var before_loss: int = level.mother_core.nutrition
	_check(level.supply_system.request_supply(left_organ), "Original core-to-left path holds one prepaid fixed-route packet")
	packet = _first_packet(level, "World/Packets")
	var interrupted_id: int = packet.get_instance_id() if packet != null else 0
	_tick(level, evidence)
	_check(packet != null and packet.global_position.distance_to(level.mother_core.global_position) > 0.0,
		"The original-route packet physically moves before its entry is removed")
	level.network_system.unregister_edge(core_left_edge)
	_until(level, evidence, "old_fixed_route_interrupts", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0)
	_check(level.mother_core.nutrition == before_loss and left_organ.nutrition == left_stock
		and left_organ.incoming_nutrition == 0, "Original route loss refunds once and never credits or reroutes its old packet")
	var old_record: Dictionary = evidence["packets"][interrupted_id]
	_check(int(old_record["arrivals"]) == 0 and int(old_record["interruptions"]) == 1,
		"Invalidated original-route packet emits one interruption and no arrival")
	_check(_route_uses(level.network_system.find_route(level.mother_core, left), new_edges)
		and level.supply_system.get_active_organs().has(left_organ), "Other end naturally keeps the former source host supplied after its old entry is lost")
	_check(level.supply_system.request_supply(left_organ), "A newly dispatched packet uses the surviving opposite-end route")
	packet = _first_packet(level, "World/Packets")
	var opposite_id: int = packet.get_instance_id() if packet != null else 0
	_until(level, evidence, "opposite_end_supply_arrives", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0)
	_assert_crossed(evidence, opposite_id, new_edges, "New opposite-end normal supply")
	_check(left_organ.nutrition == left_stock + 1 and left_organ.incoming_nutrition == 0
		and level.mother_core.nutrition == before_loss - 1, "Opposite-end supply credits one paid unit after actual arrival")
	for path: String in OLD_EDGE_PATHS:
		level.network_system.register_edge(level.get_node(path) as HyphaEdge)
	_assert_old_routes(level, old_routes, "Restored original paths after logistics")
	_assert_simple_routes(level)
	var relays: PackedVector2Array = preview["plan"]["junction_positions"]
	var relay: HyphaNode = null
	for child: Node in level.hypha_nodes.get_children():
		if child is HyphaNode and child.global_position.is_equal_approx(relays[0]):
			relay = child as HyphaNode
	_check(relay != null, "Paid relay provides an existing empty-host construction fixture")
	if relay != null:
		relay.selection_requested.emit(relay)
		_press(KEY_C)
		_check(level.cultivation_system.has_active_task() and not level.growth_system.has_active_task(),
			"C still starts normal organ cultivation on a paid relay after connection completion")
		var busy: Dictionary = _connection(level).call("preview_connection", relay, _rear(level))
		_check(not bool(busy.get("valid", false)) and int(_connection(level).call("request_connection", relay, _rear(level))) == 0
			and level.growth_system.create_target(left, Vector2(1050, 380)) == 0,
			"Current cultivation excludes both connection and ordinary growth construction")
		_press(KEY_L)
		_check(bool(_input(level).call("is_placing")) and not bool(_connection(level).call("has_active_task")),
			"L can preview a queued target while C keeps the single execution pipeline")
		_press(KEY_ESCAPE)
		_press(KEY_X)
		_check(not level.cultivation_system.has_active_task() and not bool(_connection(level).call("has_active_task")),
			"X cancels the current C construction rather than disturbing a completed connection")
	_checkpoint(level, evidence, "all_logistics_and_exclusivity_settled")
	case_results.append(_summarize(evidence, {"task_id": task_id, "cost": preview["total_cost"],
		"new_edges": new_edges, "supply_packet": supply_id, "haul_packet": haul_id,
		"return_packet": return_id, "opposite_end_packet": opposite_id, "recovered": 10}))
	await _remove_level(level, evidence)


func _test_reversed_source_and_supply_loss() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "reversed_source_waits_for_real_supply")
	var organs: Dictionary = _organ_state(level)
	var old_routes: Array[NetworkRoute] = _old_routes(level)
	var original_nodes: int = level.network_system.get_registered_nodes().size()
	var left: HyphaNode = _left(level)
	var right: HyphaNode = _right(level)
	var core_left: HyphaEdge = level.get_node(OLD_EDGE_PATHS[0]) as HyphaEdge
	var recovery: HyphaEdge = level.get_node(OLD_EDGE_PATHS[1]) as HyphaEdge
	var right_edge: HyphaEdge = level.get_node(OLD_EDGE_PATHS[3]) as HyphaEdge
	level.network_system.unregister_edge(core_left)
	level.network_system.unregister_edge(recovery)
	var preview: Dictionary = _preview(level, left, right)
	_check(bool(preview.get("valid", false)) and bool(preview.get("reversed", false))
		and preview.get("start_node") == right and preview.get("target_node") == left,
		"Disconnected first host reverses construction to the connected second host")
	if not bool(preview.get("valid", false)):
		await _remove_level(level, evidence)
		return
	_expect_hosts(evidence, preview)
	var balance: int = level.mother_core.nutrition
	var task_id: int = int(_connection(level).call("request_connection", left, right))
	_check(task_id > 0 and _snapshot(level).get("start_node") == right
		and _snapshot(level).get("target_node") == left, "Reversed request retains the selected opposite host identity")
	_check(not level.network_system.find_route(right, left).found and not level.network_system.is_connected_to_core(left),
		"Creating construction never invents a usable route to its unbuilt disconnected endpoint")
	_check(level.growth_supply_system.try_dispatch() and level.mother_core.nutrition == balance - 1,
		"Reversed construction starts with one real prepaid nutrient packet")
	var held_packet: Node2D = _first_packet(level, "World/GrowthPackets")
	level.network_system.unregister_edge(right_edge)
	_until(level, evidence, "lost_future_route_waits_at_next_node", func() -> bool:
		return held_packet != null and held_packet.get_transport_snapshot()["state"] == &"waiting")
	var before_wait: Dictionary = _snapshot(level)
	for _step: int in range(120):
		_tick(level, evidence, true)
	var waiting: Dictionary = _snapshot(level)
	_check(waiting.get("state") == &"waiting" and waiting.get("wait_reason") == &"disconnected"
		and float(waiting.get("distance", -1.0)) == float(before_wait.get("distance", -2.0))
		and int(waiting.get("consumed_nutrition", -1)) == 0
		and level.mother_core.nutrition == balance - 1 and level.growth_supply_system.get_in_transit_count() == 1,
		"Loss of a future route retains the same prepaid packet without free distance, investment, refund, or duplicate dispatch")
	_check(not level.network_system.find_route(right, left).found and not level.network_system.is_connected_to_core(left)
		and level.fungal_field.get_effective_radius(left) == 0.0 and _organ_state(level) == organs,
		"Unbuilt target supplies neither a hidden path nor field coverage and keeps its original occupied slot")
	_checkpoint(level, evidence, "disconnected_wait")
	level.network_system.register_edge(right_edge)
	if not _finish_connection(level, evidence):
		await _remove_level(level, evidence)
		return
	var new_edges: Array[int] = _assert_paid_completion(level, evidence, task_id, preview, balance, original_nodes, organs)
	_check(level.network_system.is_connected_to_core(left), "Only completed paid connection brings the disconnected existing host back into the live network")
	var organ: AttackOrgan = left.get_node("AttackOrgan") as AttackOrgan
	var stock: int = organ.nutrition
	_check(level.supply_system.request_supply(organ), "Previously disconnected occupied host receives supply through the completed reverse corridor")
	var packet: Node2D = _first_packet(level, "World/Packets")
	var packet_id: int = packet.get_instance_id() if packet != null else 0
	_until(level, evidence, "reverse_target_supply_arrives", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0)
	_assert_crossed(evidence, packet_id, new_edges, "Reversed target supply")
	_check(organ.nutrition == stock + 1 and organ.incoming_nutrition == 0,
		"Disconnected target joins the normal supply ledger after actual completion")
	level.network_system.register_edge(core_left)
	level.network_system.register_edge(recovery)
	_assert_old_routes(level, old_routes, "Reconnected old source paths")
	_checkpoint(level, evidence, "reverse_connection_and_supply_settled")
	case_results.append(_summarize(evidence, {"task_id": task_id, "reversed": true, "new_edges": new_edges}))
	await _remove_level(level, evidence)


func _test_cancellation_and_old_callbacks() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "cancel_paid_relays_and_retire_callbacks")
	var organs: Dictionary = _organ_state(level)
	var old_routes: Array[NetworkRoute] = _old_routes(level)
	var left: HyphaNode = _left(level)
	var right: HyphaNode = _right(level)
	var task_id: int = _place_connection(level, evidence, left, right)
	if task_id == 0:
		await _remove_level(level, evidence)
		return
	if not _until(level, evidence, "one_paid_relay_and_moving_shipments", func() -> bool:
		var snapshot: Dictionary = _snapshot(level)
		return int(snapshot.get("formed_junctions", 0)) == 1 and float(snapshot.get("distance", 0.0)) > 160.0 \
			and level.growth_supply_system.get_in_transit_count() > 0, true):
		await _remove_level(level, evidence)
		return
	var before: Dictionary = _snapshot(level)
	var nodes_before: int = level.hypha_nodes.get_child_count()
	var paid: int = int(before["consumed_nutrition"])
	_press(KEY_P)
	for _step: int in range(20):
		_tick(level, evidence)
	_check(_snapshot(level).get("state") == &"paused" and float(_snapshot(level).get("distance", -1.0)) == float(before["distance"]),
		"P preserves paid relay and partial strand progress while old packets continue moving")
	_press(KEY_X)
	var cancelled: Dictionary = _snapshot(level)
	_check(cancelled.get("state") == &"cancelled" and int(cancelled.get("task_id", 0)) == task_id
		and int(cancelled.get("buffered_nutrition", -1)) == 0 and level.growth_supply_system.get_in_transit_count() == 0
		and level.mother_core.nutrition == 72 - paid, "X retains paid investment and refunds all unused connection packets and buffers exactly once")
	_check(level.hypha_nodes.get_child_count() == nodes_before and nodes_before == 4
		and level.growth_system.get_completed_endpoint(task_id) == null
		and not level.network_system.has_direct_connection(left, right),
		"Cancelled connection retains its one mature relay without completing or minting the target endpoint")
	_check(evidence["cancelled"] == [task_id] and evidence["completed"].is_empty()
		and _organ_state(level) == organs, "Cancellation reports one original ID and preserves every occupied-host organ")
	for node: Node2D in level.network_system.get_registered_nodes():
		if not (node is HyphaNode or node is MotherCore):
			_check(level.fungal_field.get_effective_radius(node) == 0.0, "Cancelled inert partial endpoint grants no mature fungal field")
	_assert_old_routes(level, old_routes, "Cancelled construction")
	_checkpoint(level, evidence, "cancelled_unused_nutrition_refunded")
	var old_records: Array = evidence["packets"].values().duplicate()
	_connection(level).call("reset")
	_check(not bool(_connection(level).call("has_active_task")) and _snapshot(level).get("state") == &"idle"
		and level.mother_core.nutrition == 72 - paid, "Connection reset retires task state without refunding invested structure")
	var next_preview: Dictionary = _preview(level, right, left)
	_expect_hosts(evidence, next_preview)
	var next_balance: int = level.mother_core.nutrition
	var next_id: int = int(_connection(level).call("request_connection", right, left))
	_check(next_id > task_id, "Replacement connection preserves increasing original GrowthSystem task identities")
	for record: Dictionary in old_records:
		_replay_settled_callbacks(level, evidence, record)
	for _step: int in range(80):
		_tick(level, evidence)
	_check(int(_snapshot(level).get("task_id", 0)) == next_id and float(_snapshot(level).get("distance", -1.0)) == 0.0
		and int(_snapshot(level).get("buffered_nutrition", -1)) == 0 and level.mother_core.nutrition == next_balance,
		"Old callbacks after reset cannot fund, refund, complete, or advance the replacement connection")
	var old_formed_count: int = evidence["formed"].size()
	if not _finish_connection(level, evidence):
		await _remove_level(level, evidence)
		return
	_check(level.mother_core.nutrition == next_balance - int(next_preview["total_cost"])
		and level.growth_system.get_completed_endpoint(next_id) == left
		and evidence["completed"] == [next_id] and evidence["growth_completed"] == [next_id]
		and evidence["formed"].size() == old_formed_count + next_preview["plan"]["junction_positions"].size(),
		"Replacement completes with its own exact payments and selected old host while cancelled history stays spent")
	var final_balance: int = level.mother_core.nutrition
	_press(KEY_X)
	_connection(level).call("reset")
	for record: Dictionary in old_records:
		_replay_settled_callbacks(level, evidence, record)
	_check(level.mother_core.nutrition == final_balance and level.network_system.has_direct_connection(left, right)
		and _organ_state(level) == organs, "Late X, reset, and cancelled callbacks preserve completed physical connection and all organ stock")
	_checkpoint(level, evidence, "replacement_completed_no_stale_income")
	case_results.append(_summarize(evidence, {"cancelled_task": task_id, "retained_investment": paid, "replacement_task": next_id}))
	await _remove_level(level, evidence)


func _test_restart_with_paid_packet() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "restart_with_real_connection_packet")
	var task_id: int = _place_connection(level, evidence, _left(level), _right(level))
	if task_id == 0:
		await _remove_level(level, evidence)
		return
	var balance: int = level.mother_core.nutrition
	_check(level.growth_supply_system.try_dispatch() and level.mother_core.nutrition == balance - 1,
		"R fixture owns one actually debited connection packet")
	var packet: Node2D = _first_packet(level, "World/GrowthPackets")
	if packet == null:
		await _remove_level(level, evidence)
		return
	_tick(level, evidence)
	_check(packet.global_position.distance_to(level.mother_core.global_position) > 0.0
		and int(_snapshot(level).get("consumed_nutrition", -1)) == 0,
		"Restart interrupts an actually moving, still uninvested packet")
	var packet_id: int = packet.get_instance_id()
	var owner_id: int = _connection(level).get_instance_id()
	var callbacks: Array[Callable] = _callbacks(packet, level.growth_supply_system, &"arrived")
	callbacks.append_array(_callbacks(packet, level.growth_supply_system, &"interrupted"))
	var balances: Array[int] = []
	level.mother_core.nutrition_changed.connect(func(value: int) -> void: balances.append(value))
	_checkpoint(level, evidence, "before_actual_R")
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	evidence["active"] = false
	for _frame: int in range(30):
		await physics_frame
		await process_frame
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	var restarted: Node2D = current_scene as Node2D
	_check(is_instance_valid(restarted) and restarted != level and not is_instance_valid(level),
		"Actual R input removes the old connection level and reloads its scene")
	if not is_instance_valid(restarted) or restarted == level:
		if is_instance_valid(level):
			await _remove_level(level, evidence)
		return
	_stop_level(restarted)
	var retired: bool = true
	for callback: Callable in callbacks:
		retired = retired and not callback.is_valid()
	_check(not balances.is_empty() and balances.back() == balance,
		"R refunds its unspent packet to the original source before removing that scene")
	_check(not is_instance_valid(instance_from_id(packet_id)) and not is_instance_valid(instance_from_id(owner_id)) and retired,
		"Restart retires the old packet, connection coordinator, and all bound settlement callbacks")
	_check(_snapshot(restarted).get("state") == &"idle" and not bool(_connection(restarted).call("has_active_task"))
		and restarted.growth_system.get_task_snapshot().get("state") == &"idle"
		and restarted.growth_supply_system.get_shipment_records().is_empty()
		and not bool(_input(restarted).call("is_placing")), "R clears construction IDs, buffers, shipment accounts, and L placement")
	for path: String in ["World/GrowthPackets", "World/GrowthTips", "World/GrowthTargets", "World/Packets",
			"World/RecoveryPackets", "World/ReturnPackets", "World/CultivationPackets", "World/Remains"]:
		_check(restarted.get_node(path).get_child_count() == 0, "R removes old connection objects from %s" % path)
	_check(restarted.mother_core.nutrition == 72 and restarted.hypha_nodes.get_child_count() == 3
		and restarted.hypha_edges.get_child_count() == 4 and restarted.supply_system.get_registered_organs().size() == 2
		and restarted.mother_core.get_received_product_count() == 0 and restarted.colony_progress.get_total_recovered() == 0,
		"Restart restores the original core capital, organ inventories, network, and empty recovered ledger")
	var fresh: Dictionary = _observe(restarted, "restart_late_callback_window")
	for _step: int in range(600):
		_tick(restarted, fresh, true)
	_check(restarted.mother_core.nutrition == 72 and fresh["packets"].is_empty() and fresh["completed"].is_empty()
		and restarted.hypha_nodes.get_child_count() == 3 and _snapshot(restarted).get("state") == &"idle",
		"Simulating beyond the old packet travel time creates no ghost debit, refund, arrival, or connection")
	_checkpoint(restarted, fresh, "restart_no_old_callbacks")
	case_results.append(_summarize(evidence, {"old_task": task_id, "old_callbacks_retired": retired,
		"new_scene": _summarize(fresh)}))
	await _remove_level(restarted, fresh)
