extends SceneTree
## 正式关卡的真实业务物流：所有包竞争同一个默认容量二的调度器。
## 首次结算只来自真实物理移动；重复回调仅在合法终态之后重放。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const STEP: float = 0.05
const STEP_LIMIT: int = 3000
const POSITION_EPSILON: float = 0.01
const BUSINESS_KINDS: Array[String] = ["combat", "growth", "cultivation", "remains", "return"]
const SERVICE_PATHS: Array[String] = [
	"Systems/SupplySystem", "Systems/GrowthSupplySystem", "Systems/CultivationSupplySystem",
	"Systems/RecyclingSystem", "Systems/NutritionReturnSystem",
]
const PACKET_PATHS: Array[String] = [
	"World/Packets", "World/GrowthPackets", "World/CultivationPackets",
	"World/RecoveryPackets", "World/ReturnPackets",
]
const TRANSPORT_FIELDS: Array[String] = [
	"state", "wait_reason", "traffic_enabled", "traffic_required", "traffic_system_id",
	"task_id", "cargo_kind", "units", "request_id", "token", "current_node", "edge",
	"segment_index", "segment_count", "completed_segments", "progress", "position",
]

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var case_results: Array[Dictionary] = []
var _interfaces_available: bool = true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	var probe: Node2D = await _new_level(false)
	var packet: Node = preload("res://scenes/colony/nutrient_packet.tscn").instantiate()
	var remains_packet: Node = preload("res://scenes/recycling/remains_packet.tscn").instantiate()
	_check(packet.has_method("get_transport_snapshot") and remains_packet.has_method("get_transport_snapshot"),
		"Both production packet scenes expose the frozen transport snapshot interface")
	_check(packet.has_signal("status_changed") and remains_packet.has_signal("status_changed"),
		"Both production packet scenes expose transport status notifications")
	_interfaces_available = _interfaces_available and packet.has_method("get_transport_snapshot") \
		and remains_packet.has_method("get_transport_snapshot") \
		and packet.has_signal("status_changed") and remains_packet.has_signal("status_changed")
	packet.free()
	remains_packet.free()
	await _dispose(probe, {})
	if _interfaces_available:
		await _test_business_fifo_and_full_carcass_cycle()
		await _test_construction_competition("growth")
		await _test_construction_competition("cultivation")
		await _test_entry_closure()
		await _test_cancellation_matrix()
		await _test_missing_configuration()
		await _test_dispatcher_reset()
		await _test_restart("growth")
		await _test_restart("cultivation")
	_check(root.get_child_count() == 0, "Traffic integration teardown removes every fixture and detached owner")
	print("TRAFFIC_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"runtime": "EXECUTED", "status": "PASS" if failures.is_empty() else "FAIL",
		"checks": checks, "conservation_checks": conservation_checks, "failures": failures,
		"cases": case_results, "business_entrypoints": BUSINESS_KINDS,
		"fixture": "formal_level_01", "shared_dispatcher": true, "edge_capacity": 2,
		"initial_fixture_resources_and_timer_control": true,
		"motion": "manual_ticks_of_real_packet_physics", "route_policy": "existing_fixed_NetworkRoute",
		"first_arrivals_fabricated": false, "nutrition_injected_into_construction": false,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _has_property(object: Object, property: StringName) -> bool:
	for description: Dictionary in object.get_property_list():
		if description.get("name") == property:
			return true
	return false


func _prepare_level(level: Node2D) -> void:
	# 保留本用例的原容量2/35HP交通与账目基线；主脉动态成长由7.5真实整合验证。
	level.get_node("Systems/MainVeinSystem").set("enabled", false)
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	level.get_node("Systems/SupplySystem/DispatchTimer").autostart = false
	level.get_node("Systems/RecyclingSystem/DispatchTimer").autostart = false
	for host: Node in level.get_node("World/Colony/Nodes").get_children():
		var weapon: Node = host.get_node_or_null("SporeWeapon")
		if weapon != null:
			weapon.get_node("FireTimer").autostart = false


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
	level.digestive_organ.digest_timer.stop()
	level.fungal_field.set_process(false)
	level.set_process(false)
	var traffic: NetworkTrafficSystem = _traffic(level)
	if traffic != null:
		traffic.set_process(false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level(with_carcass: bool = true) -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level)
	root.add_child(level)
	current_scene = level
	_stop_level(level)
	await physics_frame
	await process_frame
	_stop_level(level)
	level.call("_process", 0.0)
	level.fungal_field.advance(1.0)
	_assert_formal_wiring(level)
	_check(level.mother_core.nutrition == 72 and level.supply_system.get_in_transit_count() == 0,
		"Formal fixture starts with the original capital and no automatic shipments")
	if with_carcass:
		var carcass: LargeCarcass = CARCASS_SCENE.instantiate() as LargeCarcass
		carcass.name = "TrafficCarcass"
		carcass.position = level.mother_core.global_position + Vector2(-40, 0)
		level.get_node("World/Remains").add_child(carcass)
		_check(carcass.get_remaining_nutrition() == 80
			and level.fungal_field.get_collection_node(carcass.global_position) == level.mother_core,
			"Initial eighty-unit source is collected at the real core with a physical forty-pixel pickup")
	return level


func _assert_formal_wiring(level: Node2D) -> void:
	var traffic: NetworkTrafficSystem = _traffic(level)
	var found: bool = traffic != null and _has_property(level, &"traffic_system")
	_check(found, "Formal Level01 owns Systems/NetworkTrafficSystem and level.traffic_system")
	if not found:
		_interfaces_available = false
		return
	_check(level.get("traffic_system") == traffic and traffic.network_system == level.network_system,
		"Formal level and dispatcher reference the same physical NetworkSystem")
	var dispatcher_count: int = 0
	for child: Node in level.get_node("Systems").get_children():
		if child is NetworkTrafficSystem:
			dispatcher_count += 1
	_check(dispatcher_count == 1, "Formal scene has exactly one dispatcher rather than a pool for each cargo class")
	for path: String in SERVICE_PATHS:
		var service: Node = level.get_node(path)
		var configured: bool = _has_property(service, &"traffic_system") and _has_property(service, &"traffic_required")
		_check(configured, path + " exposes both frozen traffic configuration fields")
		if not configured:
			_interfaces_available = false
			continue
		_check(service.get("traffic_system") == traffic and bool(service.get("traffic_required")),
			path + " uses the same mandatory formal dispatcher")
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		_check(edge.traffic_capacity == 2, "Every initial formal edge retains its original capacity of two")
	_check(level.digestive_organ.capacity == 4, "Integration keeps the original four-body stomach capacity")
	_check(level.supply_system.has_method("reset") and level.recycling_system.has_method("reset"),
		"Both ordinary business ledgers expose cancellation-based reset")
	_interfaces_available = _interfaces_available and level.supply_system.has_method("reset") \
		and level.recycling_system.has_method("reset")


func _traffic(level: Node2D) -> NetworkTrafficSystem:
	return level.get_node_or_null("Systems/NetworkTrafficSystem") as NetworkTrafficSystem


func _bottleneck(level: Node2D) -> HyphaEdge:
	return level.get_node("World/Colony/Connections/DigestionEdge") as HyphaEdge


func _rear(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/RearNode") as HyphaNode


func _combat_organ(level: Node2D) -> AttackOrgan:
	return level.get_node("World/Colony/Nodes/RightNode/AttackOrgan") as AttackOrgan


func _service(level: Node2D, kind: String) -> Node:
	return level.get_node(SERVICE_PATHS[BUSINESS_KINDS.find(kind)])


func _add_empty_host(level: Node2D) -> HyphaNode:
	var previous: HyphaNode = level.hypha_nodes.get_node_or_null("TrafficFixtureHost") as HyphaNode
	if previous != null:
		return previous
	# 零营养的初始拓扑夹具；新边使用原场景的容量，供养仍经过正式瓶颈。
	var host: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	host.name = "TrafficFixtureHost"
	host.position = Vector2(920, 640)
	level.hypha_nodes.add_child(host)
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.name = "TrafficFixtureEdge"
	edge.start_node = _rear(level)
	edge.end_node = host
	level.hypha_edges.add_child(edge)
	_check(level.network_system.is_node_registered(host) and level.network_system.is_edge_valid(edge)
		and edge.traffic_capacity == 2 and host.is_organ_slot_available(),
		"Actual level registration owns the empty cultivation fixture and its unchanged capacity-two edge")
	return host


func _callbacks(packet: Node, owner: Node, event: StringName) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(event):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _observe(level: Node2D, label: String) -> Dictionary:
	var evidence: Dictionary = {
		"label": label, "active": true, "initial_total": 0, "checks_at_start": checks,
		"failures_at_start": failures.size(), "packets": {}, "batches": {}, "products": {},
		"receipts": {}, "growth_costs": {}, "task_owners": {}, "organs": level.supply_system.get_registered_organs(),
		"combat_receiver": _combat_organ(level),
		"detached": [], "checkpoints": [], "callback_replays": 0,
		"peak_edge_occupied": 0, "peak_edge_queued": 0, "traffic_events": 0,
		"carcass": level.get_node_or_null("World/Remains/TrafficCarcass"),
	}
	level.growth_system.task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_growth(evidence, snapshot))
	level.cultivation_system.organ_matured.connect(func(_task: int, _host: HyphaNode,
			organ: AttackOrgan, weapon: SporeWeapon) -> void:
		if bool(evidence["active"]):
			var organs: Array = evidence["organs"]
			organs.append(organ)
			weapon.get_node("FireTimer").stop())
	level.digestive_organ.product_created.connect(func(product_id: String, amount: int) -> void:
		if bool(evidence["active"]):
			var products: Dictionary = evidence["products"]
			_check(not products.has(product_id), "Real digestion creates each product identity exactly once")
			products[product_id] = amount)
	level.mother_core.digestion_product_arrived.connect(func(product_id: String, amount: int) -> void:
		if not bool(evidence["active"]):
			return
		var receipts: Dictionary = evidence["receipts"]
		var return_packet: Node2D = _packet_for_product(evidence, product_id)
		_check(not receipts.has(product_id) and return_packet != null,
			"Core receipt refers to one uniquely owned real green packet")
		if return_packet != null:
			var snapshot: Dictionary = _transport(return_packet)
			_check(snapshot.get("state") == &"completed"
				and return_packet.global_position.distance_to(level.mother_core.global_position) < POSITION_EPSILON,
				"Core credits the product only after its actual green packet physically finishes")
			receipts[product_id] = amount)
	level.get_node("World/Remains").child_entered_tree.connect(func(child: Node) -> void:
		if not bool(evidence["active"]) or not child is EnemyRemains or not child.has_meta("carcass_batch_id"):
			return
		var batch: EnemyRemains = child as EnemyRemains
		var batch_id: String = String(batch.get_meta("carcass_batch_id", ""))
		var request_id: String = String(batch.get_meta("carcass_request_id", ""))
		var batches: Dictionary = evidence["batches"]
		var source: LargeCarcass = evidence["carcass"] as LargeCarcass
		_check(source != null and not batch_id.is_empty() and not request_id.is_empty()
			and not batches.has(batch_id) and not batch.is_available() and batch.nutrition_value == 0,
			"A new carcass draft is already claimed, uniquely identified, and still owns zero nutrition")
		if source != null:
			_check(source.get_reservation_nutrition(request_id) == 10
				and String(batch.get_meta("carcass_source_id", "")) == source.get_resource_id(),
				"Each ten-unit draft owns its distinct original source reservation")
		for previous: Dictionary in batches.values():
			_check(previous["request_id"] != request_id, "Parallel committed carcass batches never reuse a harvest request ID")
		batches[batch_id] = {"batch_id": batch_id, "request_id": request_id,
			"source_id": String(batch.get_meta("carcass_source_id", "")),
			"instance_id": batch.get_instance_id(), "nutrition": 10})
	for index: int in range(BUSINESS_KINDS.size()):
		_watch_container(level, evidence, PACKET_PATHS[index], BUSINESS_KINDS[index], level.get_node(SERVICE_PATHS[index]))
	_traffic(level).request_changed.connect(func(snapshot: Dictionary) -> void:
		if not bool(evidence["active"]):
			return
		evidence["traffic_events"] = int(evidence["traffic_events"]) + 1
		if snapshot.get("state") == &"granted":
			var records: Dictionary = evidence["packets"]
			var record: Dictionary = records.get(int(snapshot.get("owner_id", 0)), {})
			_check(not record.is_empty(), "Every granted traversal belongs to an observed real business packet")
			if not record.is_empty():
				var grants: Array = record["grants"]
				grants.append({"edge_id": snapshot["edge_id"], "from_id": snapshot["from_id"],
					"to_id": snapshot["to_id"], "units": snapshot["units"], "task_id": snapshot["task_id"],
					"request_id": snapshot["request_id"], "token": snapshot["token"],
					"zero_length": (snapshot["edge"] as HyphaEdge).get_length() == 0.0})
				_check(int(snapshot["units"]) == (2 if record["kind"] == "remains" else 1),
					"Granted occupancy depends on cargo kind rather than its nutrition mass")
		_audit_traffic(level, evidence))
	evidence["initial_total"] = int(_resources(level, evidence)["total"])
	_checkpoint(level, evidence, "initial")
	return evidence


func _watch_container(level: Node2D, evidence: Dictionary, path: String, kind: String, owner: Node) -> void:
	level.get_node(path).child_entered_tree.connect(func(child: Node) -> void:
		if not bool(evidence["active"]) or not (child is NutrientPacket or child is RemainsPacket):
			return
		var packet: Node2D = child as Node2D
		packet.set_physics_process(false)
		var record: Dictionary = {
			"id": packet.get_instance_id(), "packet": packet, "kind": kind, "states": [],
			"arrivals": 0, "interruptions": 0, "movement_ticks": 0, "waiting_ticks": 0,
			"grants": [], "task_id": "", "dispatcher_id": 0, "route": null,
			"task_owners": evidence["task_owners"],
			"arrived_callbacks": _callbacks(packet, owner, &"arrived"),
			"interrupted_callbacks": _callbacks(packet, owner, &"interrupted"),
		}
		var records: Dictionary = evidence["packets"]
		records[packet.get_instance_id()] = record
		_check(bool(packet.get("traffic_required")) and not record["arrived_callbacks"].is_empty()
			and not record["interrupted_callbacks"].is_empty(),
			"Mandatory traffic and real settlement ownership are set before " + kind + " packet enters the tree")
		# idle 尚未调用 start_route，调度器身份只在启动后检验。
		packet.connect(&"status_changed", func(snapshot: Dictionary) -> void:
			if bool(evidence["active"]):
				_record_transport(level, evidence, record, snapshot))
		packet.connect(&"arrived", func(finished: Node2D) -> void:
			if bool(evidence["active"]):
				record["arrivals"] = int(record["arrivals"]) + 1
				_assert_terminal(level, record, &"completed")
				var route: NetworkRoute = record["route"] as NetworkRoute
				_check(route != null and is_instance_valid(route.end_node)
					and finished.global_position.distance_to(route.end_node.global_position) < POSITION_EPSILON,
					"Actual " + kind + " arrival is at the end of its originally captured route")
				_replay_settled_callbacks(level, evidence, record))
		packet.connect(&"interrupted", func(_finished: Node2D) -> void:
			if bool(evidence["active"]):
				record["interruptions"] = int(record["interruptions"]) + 1
				_assert_terminal(level, record, &"interrupted")
				_replay_settled_callbacks(level, evidence, record)))


func _transport(packet: Node) -> Dictionary:
	return packet.call("get_transport_snapshot")


func _record_transport(level: Node2D, evidence: Dictionary, record: Dictionary, snapshot: Dictionary) -> void:
	var state: StringName = snapshot.get("state", &"")
	var states: Array = record["states"]
	if states.is_empty() or states.back() != String(state):
		states.append(String(state))
	if state == &"idle":
		return
	_validate_transport(level, record, snapshot)
	if state == &"waiting":
		var anchor: Node2D = snapshot.get("current_node") as Node2D
		_check(anchor != null and (snapshot["position"] as Vector2).distance_to(anchor.global_position) < POSITION_EPSILON,
			"Queued " + String(record["kind"]) + " stays at its real registered node")
	elif state == &"moving":
		var lease: Dictionary = _traffic(level).get_lease(String(snapshot.get("token", "")))
		_check(not lease.is_empty() and int(lease.get("owner_id", 0)) == int(record["id"])
			and lease.get("task_id") == snapshot.get("task_id") and lease.get("edge") == snapshot.get("edge"),
			"Moving " + String(record["kind"]) + " always holds a live lease for this task and this edge")
	_audit_traffic(level, evidence)


func _validate_transport(level: Node2D, record: Dictionary, snapshot: Dictionary) -> void:
	for field: String in TRANSPORT_FIELDS:
		_check(snapshot.has(field), "Started business transport exposes snapshot field " + field)
	var kind: StringName = &"remains" if record["kind"] == "remains" else (
		&"return" if record["kind"] == "return" else &"supply")
	_check(bool(snapshot.get("traffic_enabled", false)) and bool(snapshot.get("traffic_required", false))
		and int(snapshot.get("traffic_system_id", 0)) == _traffic(level).get_instance_id()
		and snapshot.get("cargo_kind") == kind and int(snapshot.get("units", 0)) == (2 if kind == &"remains" else 1)
		and not String(snapshot.get("task_id", "")).is_empty(),
		"Started " + String(record["kind"]) + " uses the single formal dispatcher and the frozen cargo units")
	var task_id: String = String(snapshot.get("task_id", ""))
	if String(record["task_id"]).is_empty():
		var task_owners: Dictionary = record["task_owners"]
		_check(not task_owners.has(task_id) or int(task_owners[task_id]) == int(record["id"]),
			"Different real shipments never collide on a dispatcher task ID")
		task_owners[task_id] = record["id"]
		record["task_id"] = task_id
		record["dispatcher_id"] = int(snapshot.get("traffic_system_id", 0))
	else:
		_check(task_id == String(record["task_id"]) and int(snapshot.get("traffic_system_id", 0)) == int(record["dispatcher_id"]),
			"Dispatcher and shipment identity stay captured for the entire journey")
	var packet: Node2D = record["packet"] as Node2D
	if is_instance_valid(packet) and record["route"] == null:
		record["route"] = packet.get("_route")


func _assert_terminal(level: Node2D, record: Dictionary, state: StringName) -> void:
	var snapshot: Dictionary = _transport(record["packet"] as Node)
	_validate_transport(level, record, snapshot)
	_check(snapshot.get("state") == state and String(snapshot.get("request_id", "")).is_empty()
		and String(snapshot.get("token", "")).is_empty(),
		"Real business callback sees terminal state and cleared traversal handles")
	_check(int(record["arrivals"]) + int(record["interruptions"]) == 1,
		"A real business packet emits exactly one terminal signal")
	for edge_snapshot: Dictionary in _traffic(level).get_snapshot().get("edges", []):
		for key: String in ["leases", "queue"]:
			for request: Dictionary in edge_snapshot.get(key, []):
				_check(int(request.get("owner_id", 0)) != int(record["id"]),
					"The terminal packet releases or cancels all dispatcher ownership before business callbacks")


func _replay_settled_callbacks(level: Node2D, evidence: Dictionary, record: Dictionary) -> void:
	var packet: Variant = record["packet"]
	if not is_instance_valid(packet):
		return
	var before: Dictionary = _resources(level, evidence)
	var traffic_before: Dictionary = _traffic(level).get_snapshot()
	for key: String in ["arrived_callbacks", "interrupted_callbacks"]:
		for callback: Callable in record[key]:
			if callback.is_valid():
				callback.call(packet)
				callback.call(packet)
				evidence["callback_replays"] = int(evidence["callback_replays"]) + 2
	_check(_resources(level, evidence) == before and _traffic(level).get_snapshot() == traffic_before,
		"Replayed terminal " + String(record["kind"]) + " callbacks cannot duplicate credit, refund, or traversal")


func _packet_for_product(evidence: Dictionary, product_id: String) -> Node2D:
	var result: Node2D = null
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		var packet: Variant = record["packet"]
		if record["kind"] == "return" and is_instance_valid(packet) \
				and String(packet.get_meta("return_product_id", "")) == product_id \
				and _transport(packet).get("state") == &"completed":
			result = packet as Node2D
	return result


func _last_packet(evidence: Dictionary, kind: String) -> Node2D:
	var result: Node2D = null
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		var packet: Variant = record["packet"]
		if record["kind"] == kind and is_instance_valid(packet) and not packet.is_queued_for_deletion():
			result = packet as Node2D
	return result


func _remember_growth(evidence: Dictionary, snapshot: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		var costs: Dictionary = evidence["growth_costs"]
		costs[task_id] = maxi(int(costs.get(task_id, 0)), int(snapshot.get("consumed_nutrition", 0)))


func _resources(level: Node2D, evidence: Dictionary) -> Dictionary:
	var parts: Dictionary = {
		"core": int(level.mother_core.nutrition), "organ_stock": 0, "combat_transit": 0,
		"growth_transit": 0, "growth_buffer": 0, "network_investment": 0,
		"cultivation_transit": int(level.cultivation_supply_system.get_in_transit_nutrition()),
		"carcass_source": 0, "live_batches": 0, "ordinary_remains": 0,
		"digestive_queue": int(level.digestive_organ.get_queued_nutrition()),
		"queued_products": 0, "return_transit": 0,
	}
	for organ: AttackOrgan in evidence.get("organs", []):
		if is_instance_valid(organ):
			# 移出树的接收者仍保留原库存；它与预留不重复计数。
			parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
			parts["combat_transit"] = int(parts["combat_transit"]) + organ.incoming_nutrition
	for shipment: Dictionary in level.growth_supply_system.get_shipment_records():
		if bool(shipment["debited"]) and not bool(shipment["settled"]) and not bool(shipment["refunded"]):
			parts["growth_transit"] = int(parts["growth_transit"]) + 1
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_remember_growth(evidence, growth)
	parts["growth_buffer"] = int(growth.get("buffered_nutrition", 0))
	for consumed: int in (evidence.get("growth_costs", {}) as Dictionary).values():
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
			var key: String = "live_batches" if child.has_meta("carcass_batch_id") else "ordinary_remains"
			parts[key] = int(parts[key]) + child.nutrition_value
	for product: Dictionary in level.digestive_organ.get_output_products():
		var key: String = "return_transit" if product["status"] == &"in_transit" else "queued_products"
		parts[key] = int(parts[key]) + int(product["nutrition"])
	# 回流包引用胃囊产物，紫包引用尸块；通道租约和胃囊空间预留不再增加质量。
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	return parts


func _audit_traffic(level: Node2D, evidence: Dictionary) -> void:
	var traffic: NetworkTrafficSystem = _traffic(level)
	var totals: Dictionary = traffic.get_snapshot()
	var occupied: int = 0
	var queued: int = 0
	var leases: int = 0
	var owners: Dictionary = {}
	for snapshot: Dictionary in totals.get("edges", []):
		var capacity: int = int(snapshot.get("capacity", -1))
		var edge_units: int = int(snapshot.get("occupied_units", -1))
		_check(capacity == 2 and edge_units >= 0 and edge_units <= capacity,
			"Every real traversal respects the unchanged shared capacity of two")
		occupied += edge_units
		queued += (snapshot.get("queue", []) as Array).size()
		leases += (snapshot.get("leases", []) as Array).size()
		for key: String in ["leases", "queue"]:
			for request: Dictionary in snapshot.get(key, []):
				var owner_id: int = int(request.get("owner_id", 0))
				_check(not owners.has(owner_id), "A physical packet never holds or requests two edges simultaneously")
				owners[owner_id] = true
		if snapshot.get("edge") == _bottleneck(level):
			evidence["peak_edge_occupied"] = maxi(int(evidence["peak_edge_occupied"]), edge_units)
			evidence["peak_edge_queued"] = maxi(int(evidence["peak_edge_queued"]), (snapshot.get("queue", []) as Array).size())
	_check(occupied == int(totals.get("occupied_units", -1)) and queued == int(totals.get("queued_count", -1))
		and leases == int(totals.get("active_lease_count", -1)) and owners.size() == int(totals.get("active_request_count", -1)),
		"Global traffic totals agree with the actual per-edge leases and FIFO queues")


func _checkpoint(level: Node2D, evidence: Dictionary, phase: String, remember: bool = true) -> void:
	var parts: Dictionary = _resources(level, evidence)
	conservation_checks += 1
	_check(int(parts["total"]) == int(evidence["initial_total"]),
		String(evidence["label"]) + "/" + phase + " conserves every resource owner and paid structure")
	_check(int(parts["combat_transit"]) == level.supply_system.get_in_transit_count(),
		"Combat receiver reservations match its real prepaid shipments")
	_check(level.digestive_organ.incoming_remains == level.recycling_system.get_in_transit_count()
		and level.digestive_organ.get_queued_count() + level.digestive_organ.incoming_remains <= level.digestive_organ.capacity,
		"Queued and moving remains retain exactly one original stomach reservation each")
	_check(int(parts["return_transit"]) == level.nutrition_return_system.get_in_transit_nutrition(),
		"Claimed products are counted once while their real green packets wait or move")
	_audit_traffic(level, evidence)
	if remember:
		var checkpoints: Array = evidence["checkpoints"]
		checkpoints.append({"phase": phase, "resources": parts,
			"occupied": _traffic(level).get_snapshot().get("occupied_units"),
			"queued": _traffic(level).get_snapshot().get("queued_count")})


func _tick_packet(level: Node2D, evidence: Dictionary, packet: Node2D, delta: float = STEP) -> void:
	if not is_instance_valid(packet) or packet.is_queued_for_deletion() or not packet.is_inside_tree():
		return
	var records: Dictionary = evidence["packets"]
	var record: Dictionary = records[packet.get_instance_id()]
	var before: Dictionary = _transport(packet)
	var position: Vector2 = packet.global_position
	packet.call("_physics_process", delta)
	if not is_instance_valid(packet):
		return
	var after: Dictionary = _transport(packet)
	_validate_transport(level, record, after)
	if not packet.global_position.is_equal_approx(position):
		record["movement_ticks"] = int(record["movement_ticks"]) + 1
	if before.get("state") == &"waiting" and after.get("state") == &"waiting" \
			and before.get("request_id") == after.get("request_id"):
		record["waiting_ticks"] = int(record["waiting_ticks"]) + 1
		_check(packet.global_position.is_equal_approx(position), "Waiting discards movement budget without drifting off its node")
		_check(int(record["arrivals"]) == 0 and int(record["interruptions"]) == 0,
			"Capacity or closed-entry waiting never triggers business arrival, interruption, or refund")
	if before.get("state") == &"waiting":
		_check(packet.global_position.distance_to(position) <= maxf(0.0, float(packet.get("speed"))) \
			* maxf(0.0, delta) + POSITION_EPSILON,
			"A newly granted business packet cannot reuse accumulated waiting movement budget")
	var traffic_before: Dictionary = _traffic(level).get_snapshot()
	var first: Dictionary = _transport(packet)
	var second: Dictionary = _transport(packet)
	_check(first == second and _traffic(level).get_snapshot() == traffic_before,
		"Packet transport snapshots are pure observations even during business waiting and settlement")
	_audit_traffic(level, evidence)


func _tick(level: Node2D, evidence: Dictionary, feed: String = "") -> void:
	if not feed.is_empty():
		_service(level, feed).call("try_dispatch")
	_traffic(level).refresh()
	for path: String in PACKET_PATHS:
		for child: Node in level.get_node(path).get_children():
			if child is NutrientPacket or child is RemainsPacket:
				_tick_packet(level, evidence, child as Node2D)
	level.growth_system.advance(STEP)
	level.cultivation_system.advance(STEP)
	level.growth_supply_system.call("_process", 0.0)
	level.cultivation_supply_system.call("_process", 0.0)
	level.call("_process", 0.0)
	level.fungal_field.advance(STEP)
	level.digestive_organ.digest_timer.stop()


func _until(level: Node2D, evidence: Dictionary, phase: String, condition: Callable,
		feed: String = "", limit: int = STEP_LIMIT) -> bool:
	for step: int in range(limit):
		if bool(condition.call()):
			break
		_tick(level, evidence, feed)
		if step % 20 == 0:
			_checkpoint(level, evidence, phase + "_moving", false)
	var reached: bool = bool(condition.call())
	_check(reached, String(evidence["label"]) + " reaches " + phase + " with bounded real motion")
	_checkpoint(level, evidence, phase)
	return reached


func _transport_count(level: Node2D) -> int:
	var count: int = 0
	for path: String in SERVICE_PATHS:
		count += int(level.get_node(path).call("get_in_transit_count"))
	return count


func _until_packet_state(level: Node2D, evidence: Dictionary, packet: Node2D, state: StringName) -> bool:
	if packet == null:
		_check(false, "Requested business packet exists before its state is inspected")
		return false
	for _step: int in range(50):
		if _transport(packet).get("state") == state or packet.is_queued_for_deletion():
			break
		_tick_packet(level, evidence, packet)
	var reached: bool = _transport(packet).get("state") == state
	_check(reached, "Real packet reaches the requested " + String(state) + " state")
	return reached


func _prepare_business_task(level: Node2D, kind: String) -> int:
	if kind == "growth":
		# 原规划器按整段预付 extension_cost；七十像素只需一包即可真实启动。
		var task_id: int = level.growth_system.create_target(_rear(level), _rear(level).global_position + Vector2(70, 0))
		_check(task_id > 0 and not level.cultivation_system.has_active_task(),
			"Growth competition starts a real exclusive construction task")
		return task_id
	if kind == "cultivation":
		var task_id: int = level.cultivation_system.start_cultivation(_add_empty_host(level))
		_check(task_id > 0 and not level.growth_system.has_active_task(),
			"Cultivation competition starts a real exclusive construction task")
		return task_id
	return 0


func _dispatch(level: Node2D, kind: String) -> bool:
	if kind == "combat":
		return level.supply_system.request_supply(_combat_organ(level))
	return bool(_service(level, kind).call("try_dispatch"))


func _launch(level: Node2D, evidence: Dictionary, kind: String) -> Node2D:
	_check(_dispatch(level, kind), "Real " + kind + " business entrypoint accepts a shipment")
	var packet: Node2D = _last_packet(evidence, kind)
	_check(packet != null, "Accepted " + kind + " creates its actual production packet")
	if packet != null:
		var record: Dictionary = evidence["packets"][packet.get_instance_id()]
		_validate_transport(level, record, _transport(packet))
	return packet


func _digest_one(level: Node2D, evidence: Dictionary) -> bool:
	var before: int = level.digestive_organ.digested_count
	var balance: int = level.mother_core.nutrition
	_check(level.digestive_organ.get_queued_count() > 0 and level.digestive_organ.get_output_count() < 2,
		"Real digestion has delivered input and original output capacity")
	# 唯一加速是已有计时器；输入和产物均由真实业务交接产生。
	var stop_next: Callable = func(_product_id: String, _amount: int) -> void:
		level.digestive_organ.digest_timer.stop()
	level.digestive_organ.product_created.connect(stop_next, CONNECT_ONE_SHOT)
	level.digestive_organ.digest_timer.start(0.02)
	for _frame: int in range(30):
		await physics_frame
		await process_frame
		if level.digestive_organ.digested_count > before:
			break
	level.digestive_organ.digest_timer.stop()
	if level.digestive_organ.product_created.is_connected(stop_next):
		level.digestive_organ.product_created.disconnect(stop_next)
	var produced: bool = level.digestive_organ.digested_count == before + 1
	_check(produced and level.mother_core.nutrition == balance,
		"Actual DigestTimer consumes one delivered body and creates uncredited output")
	_checkpoint(level, evidence, "actual_timer_digestion")
	return produced


func _prime_product(level: Node2D, evidence: Dictionary) -> bool:
	var balance: int = level.mother_core.nutrition
	var packet: Node2D = _launch(level, evidence, "remains")
	if packet == null:
		return false
	var pickup: Dictionary = _transport(packet)
	_check(pickup.get("state") == &"pickup" and String(pickup.get("request_id", "")).is_empty()
		and String(pickup.get("token", "")).is_empty() and _traffic(level).get_snapshot().get("occupied_units") == 0,
		"Off-edge remains pickup holds no dispatcher units before reaching the real collecting node")
	if not _until(level, evidence, "seed_body_actual_arrival", func() -> bool:
		return level.recycling_system.get_in_transit_count() == 0):
		return false
	_check(level.digestive_organ.get_queued_nutrition() == 10 and level.mother_core.nutrition == balance,
		"Seed product starts with one real ten-unit carcass delivery and no early core credit")
	return await _digest_one(level, evidence)


func _freeze_waiting(level: Node2D, evidence: Dictionary, packets: Array[Node2D], reason: StringName) -> void:
	var before: Dictionary = _resources(level, evidence)
	for packet: Node2D in packets:
		if packet != null:
			_check(_transport(packet).get("state") == &"waiting" and _transport(packet).get("wait_reason") == reason,
				"Valid business packet reports normal " + String(reason) + " waiting")
	for _step: int in range(30):
		for packet: Node2D in packets:
			if packet != null:
				_tick_packet(level, evidence, packet, 0.25)
		level.growth_system.advance(0.25)
		level.cultivation_system.advance(0.25)
		_checkpoint(level, evidence, "waiting_without_business_progress", false)
	_check(_resources(level, evidence) == before,
		"A long wait neither credits inventories nor advances unfunded structure nor releases source claims")


func _clean_traffic(traffic: NetworkTrafficSystem, description: String) -> void:
	var snapshot: Dictionary = traffic.get_snapshot()
	_check(int(snapshot.get("occupied_units", -1)) == 0 and int(snapshot.get("queued_count", -1)) == 0
		and int(snapshot.get("active_lease_count", -1)) == 0 and int(snapshot.get("active_request_count", -1)) == 0,
		description + " leaves no queue, lease, or owner registration")


func _settle_business(level: Node2D) -> void:
	for path: String in SERVICE_PATHS:
		var service: Node = level.get_node(path)
		if service.has_method("reset"):
			service.call("reset")
	if _traffic(level) != null:
		_traffic(level).refresh()
		_clean_traffic(_traffic(level), "Cancelling all actual business ledgers before dispatcher reset")


func _dispose(level: Node2D, evidence: Dictionary) -> void:
	if evidence.has("active"):
		evidence["active"] = false
	var detached: Array = evidence.get("detached", [])
	if is_instance_valid(level):
		_settle_business(level)
		if _traffic(level) != null:
			_traffic(level).reset()
		if current_scene == level:
			current_scene = null
		level.queue_free()
	await process_frame
	await process_frame
	for node: Variant in detached:
		if is_instance_valid(node):
			node.free()


func _summary(level: Node2D, evidence: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var packets: Array[Dictionary] = []
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		packets.append({"id": record["id"], "kind": record["kind"], "task_id": record["task_id"],
			"dispatcher_id": record["dispatcher_id"], "states": record["states"], "grants": record["grants"],
			"arrivals": record["arrivals"], "interruptions": record["interruptions"],
			"movement_ticks": record["movement_ticks"], "waiting_ticks": record["waiting_ticks"]})
	var result: Dictionary = {"name": evidence["label"], "passed": failures.size() == int(evidence["failures_at_start"]),
		"checks": checks - int(evidence["checks_at_start"]), "initial_mass": evidence["initial_total"],
		"final_resources": _resources(level, evidence), "peak_shared_edge_units": evidence["peak_edge_occupied"],
		"peak_shared_edge_queue": evidence["peak_edge_queued"], "packets": packets,
		"batches": (evidence["batches"] as Dictionary).values(), "products": evidence["products"],
		"receipts": evidence["receipts"], "callback_replays_after_terminal": evidence["callback_replays"],
		"traffic_events": evidence["traffic_events"], "checkpoints": evidence["checkpoints"]}
	result.merge(extra, true)
	return result


func _check_fifo(level: Node2D, packets: Array[Node2D], description: String) -> void:
	var queue: Array = _traffic(level).get_edge_snapshot(_bottleneck(level)).get("queue", [])
	_check(queue.size() == packets.size(), description + " contains exactly the real competing requests")
	for index: int in range(mini(queue.size(), packets.size())):
		_check(packets[index] != null and int(queue[index].get("owner_id", 0)) == packets[index].get_instance_id(),
			description + " preserves actual FIFO position %d across both directions" % index)


func _finish_carcass_cycle(level: Node2D, evidence: Dictionary) -> bool:
	var source: LargeCarcass = evidence["carcass"] as LargeCarcass
	for _turn: int in range(40):
		if source.get_remaining_nutrition() == 0 and _transport_count(level) == 0 \
				and level.digestive_organ.get_queued_count() == 0 and level.digestive_organ.get_output_count() == 0:
			break
		if _transport_count(level) > 0:
			if not _until(level, evidence, "resource_cycle_active_packets_settle", func() -> bool:
				return _transport_count(level) == 0):
				return false
		elif level.digestive_organ.get_output_count() > 0:
			if _launch(level, evidence, "return") == null:
				return false
		elif level.digestive_organ.get_queued_count() > 0:
			if not await _digest_one(level, evidence):
				return false
		elif source.get_remaining_nutrition() > 0:
			if _launch(level, evidence, "remains") == null:
				return false
	var completed: bool = source.get_remaining_nutrition() == 0 and _transport_count(level) == 0 \
		and level.digestive_organ.get_queued_count() == 0 and level.digestive_organ.get_output_count() == 0
	_check(completed, "Every remaining source unit completes harvesting, physical hauling, real digestion, and physical return")
	_checkpoint(level, evidence, "all_eighty_units_physically_returned")
	return completed


func _test_business_fifo_and_full_carcass_cycle() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "opposing_business_fifo_and_complete_eighty_unit_cycle")
	if not await _prime_product(level, evidence):
		await _dispose(level, evidence)
		return
	var balance: int = level.mother_core.nutrition
	var organ: AttackOrgan = _combat_organ(level)
	var stock: int = organ.nutrition
	var first_yellow: Node2D = _launch(level, evidence, "combat")
	var purple: Node2D = _launch(level, evidence, "remains")
	if first_yellow == null or not _until_packet_state(level, evidence, purple, &"waiting"):
		await _dispose(level, evidence)
		return
	var green: Node2D = _launch(level, evidence, "return")
	var late_yellow: Node2D = _launch(level, evidence, "combat")
	var waiting: Array[Node2D] = [purple, green, late_yellow]
	_check_fifo(level, waiting, "Two-unit purple head blocks later one-unit green and yellow")
	var edge_snapshot: Dictionary = _traffic(level).get_edge_snapshot(_bottleneck(level))
	_check(int(edge_snapshot["occupied_units"]) == 1 and int(edge_snapshot["available_units"]) == 1,
		"Actual yellow owns one unit while strict FIFO leaves the other unit idle behind a large head")
	if green != null:
		var request: Dictionary = _traffic(level).get_request(String(_transport(green)["request_id"]))
		_check(request.get("from_node") == _rear(level) and request.get("to_node") == level.mother_core,
			"Ten-nutrition green return competes from the opposite direction on the very same edge")
	for _batch: int in range(3):
		var extra: Node2D = _launch(level, evidence, "remains")
		if _until_packet_state(level, evidence, extra, &"waiting"):
			waiting.append(extra)
	var source: LargeCarcass = evidence["carcass"] as LargeCarcass
	_check(source.get_remaining_nutrition() == 30 and source.get_harvested_nutrition() == 50
		and source.get_reserved_nutrition() == 0 and level.digestive_organ.incoming_remains == 4
		and (evidence["batches"] as Dictionary).size() == 5,
		"Original spare stomach capacity legitimately admits four independent queued ten-unit batches")
	var before_full: Dictionary = _resources(level, evidence)
	_check(not level.recycling_system.try_dispatch() and _resources(level, evidence) == before_full,
		"An originally full stomach creates no fifth in-flight batch, duplicate claim, or source debit")
	_check_fifo(level, waiting, "All independent carcass batches share the original bidirectional FIFO")
	_freeze_waiting(level, evidence, waiting, &"capacity")
	_check(organ.nutrition == stock and organ.incoming_nutrition == 2
		and level.digestive_organ.get_queued_count() == 0 and level.mother_core.nutrition == balance - 2
		and level.digestive_organ.get_output_nutrition() == 10
		and level.digestive_organ.get_output_products()[0]["status"] == &"in_transit",
		"Waiting retains prepaid yellow reservations, purple stomach slots, and the uncredited green claim")
	if not _until(level, evidence, "first_competing_wave_settles", func() -> bool:
		return _transport_count(level) == 0):
		await _dispose(level, evidence)
		return
	_check(organ.nutrition == stock + 2 and organ.incoming_nutrition == 0
		and level.digestive_organ.get_queued_nutrition() == 40 and level.digestive_organ.incoming_remains == 0
		and level.mother_core.nutrition == balance - 2 + 10,
		"Only genuine arrivals settle the two yellow units, four purple batches, and ten-unit green return")
	await _finish_carcass_cycle(level, evidence)
	_check(source.get_remaining_nutrition() == 0 and source.get_harvested_nutrition() == 80
		and source.get_reserved_nutrition() == 0 and (evidence["batches"] as Dictionary).size() == 8
		and (evidence["products"] as Dictionary).size() == 8 and (evidence["receipts"] as Dictionary).size() == 8,
		"Whole source becomes eight uniquely owned batches, eight digestion products, and eight unique receipts")
	_check(level.mother_core.nutrition == balance - 2 + 80 and level.mother_core.get_received_product_count() == 8
		and level.colony_progress.get_total_recovered() == 80 and level.recycling_system.delivered_count == 8
		and level.nutrition_return_system.delivered_nutrition == 80,
		"Full eighty-unit mass is credited once by real returns while the paid yellow units stay in the organ")
	_clean_traffic(_traffic(level), "Naturally completed full resource cycle")
	case_results.append(_summary(level, evidence, {"original_stomach_capacity": 4,
		"legitimate_parallel_batches": 4, "fully_returned_nutrition": 80, "expected_batches_and_products": 8}))
	await _dispose(level, evidence)


func _test_construction_competition(kind: String) -> void:
	var level: Node2D = await _new_level()
	var host: HyphaNode = _add_empty_host(level)
	var evidence: Dictionary = _observe(level, kind + "_yellow_competes_with_real_purple_and_green")
	if not await _prime_product(level, evidence):
		await _dispose(level, evidence)
		return
	var balance: int = level.mother_core.nutrition
	var blocker: Node2D = _launch(level, evidence, "remains")
	if not _until_packet_state(level, evidence, blocker, &"moving"):
		await _dispose(level, evidence)
		return
	_tick_packet(level, evidence, blocker)
	var task_id: int = _prepare_business_task(level, kind)
	if kind == "growth":
		_check(level.cultivation_system.start_cultivation(host) == 0,
			"A real growth task rejects simultaneous cultivation rather than manufacturing two construction consumers")
	else:
		_check(level.growth_system.create_target(_rear(level), Vector2(960, 700)) == 0,
			"A real cultivation task excludes a simultaneous growth task")
	var yellow: Node2D = _launch(level, evidence, kind)
	var green: Node2D = _launch(level, evidence, "return")
	var combat: Node2D = _launch(level, evidence, "combat")
	var waiting: Array[Node2D] = [yellow, green, combat]
	_check_fifo(level, waiting, "Real " + kind + " joins the purple-owned bottleneck")
	_freeze_waiting(level, evidence, waiting, &"capacity")
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var cultivation: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(int(growth.get("consumed_nutrition", 0)) == 0 and int(growth.get("buffered_nutrition", 0)) == 0
		and float(growth.get("distance", 0.0)) == 0.0
		and int(cultivation.get("structure_consumed", 0)) == 0
		and int(cultivation.get("buffered_nutrition", 0)) == 0
		and int(cultivation.get("startup_reserved", 0)) == 0
		and float(cultivation.get("effective_time", 0.0)) == 0.0,
		"Neither construction spends, grows, ages a funded stage, nor receives startup stock while yellow waits")
	if not _until(level, evidence, "competing_construction_first_delivery", func() -> bool:
		return _transport_count(level) == 0):
		await _dispose(level, evidence)
		return
	if kind == "growth":
		growth = level.growth_system.get_task_snapshot()
		_check(int(growth["consumed_nutrition"]) == 1 and float(growth["distance"]) > 0.0,
			"Growth starts only after the prepaid packet actually arrives at its live GrowthTip")
		var first_record: Dictionary = evidence["packets"][yellow.get_instance_id()]
		var zero_grant: bool = false
		for grant: Dictionary in first_record["grants"]:
			zero_grant = zero_grant or bool(grant["zero_length"])
		_check(zero_grant, "The real initial zero-length GrowthTip edge still obtains and releases its own traversal grant")
		var second: Node2D = _launch(level, evidence, "growth")
		if second != null:
			var live_tip: Node2D = level.growth_system.get_delivery_target(task_id)
			_check(live_tip != null and live_tip.global_position.distance_to(_rear(level).global_position) > 0.0,
				"A later actual growth shipment follows the now-extended live tip")
			_until(level, evidence, "later_live_tip_delivery", func() -> bool:
				return level.growth_supply_system.get_in_transit_count() == 0)
		level.growth_system.cancel_task()
		_check(level.growth_supply_system.get_in_transit_count() == 0
			and level.mother_core.nutrition == balance + 10 - 1
				- int(level.growth_system.get_task_snapshot().get("consumed_nutrition", 0)),
			"Growth cancellation returns only unspent legitimately delivered buffer and keeps paid extension structure")
	else:
		cultivation = level.cultivation_system.get_task_snapshot()
		_check(int(cultivation["structure_consumed"]) == 1 and float(cultivation["effective_time"]) > 0.0,
			"Only the real first cultivation arrival funds the first timed structure stage")
		_until(level, evidence, "twelve_real_paid_units_mature_the_organ", func() -> bool:
			return level.cultivation_system.get_task_snapshot().get("state") == &"completed", "cultivation")
		cultivation = level.cultivation_system.get_task_snapshot()
		var organ: AttackOrgan = host.get_node_or_null("AttackOrgan") as AttackOrgan
		_check(int(cultivation.get("structure_consumed", 0)) == 8
			and int(cultivation.get("startup_transferred", 0)) == 4
			and float(cultivation.get("effective_time", 0.0)) >= 3.0
			and organ != null and organ.nutrition == 4 and organ.incoming_nutrition == 0,
			"Actual maturity consumes eight paid structure units and transfers exactly four paid startup units")
		_check(level.mother_core.nutrition == balance + 10 - 1 - 12
			and level.cultivation_supply_system.get_in_transit_count() == 0,
			"All twelve cultivation units debit once and settle under the unchanged shared traffic capacity")
	_checkpoint(level, evidence, "construction_paid_only_by_actual_deliveries")
	_clean_traffic(_traffic(level), "Completed construction competition")
	case_results.append(_summary(level, evidence, {"construction_kind": kind, "construction_task": task_id,
		"simultaneous_constructions": false, "real_green_nutrition": 10}))
	await _dispose(level, evidence)


func _test_entry_closure() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "temporary_closure_holds_cargo_until_recovery")
	if not await _prime_product(level, evidence):
		await _dispose(level, evidence)
		return
	var first: Node2D = _launch(level, evidence, "combat")
	if first == null:
		await _dispose(level, evidence)
		return
	_tick_packet(level, evidence, first)
	var token: String = String(_transport(first).get("token", ""))
	var stopped_position: Vector2 = first.global_position
	# 先合法领取，再模拟断路；断路之后不能从失联残影新采集。
	var purple: Node2D = _launch(level, evidence, "remains")
	_until_packet_state(level, evidence, purple, &"waiting")
	_bottleneck(level).entry_enabled = false
	# 原关卡有三角旁路；无路等待用例必须明确关闭其入口，而不是假定不会改道。
	var bypass: HyphaEdge = level.get_node("World/Colony/Connections/HyphaEdge") as HyphaEdge
	bypass.entry_enabled = false
	_traffic(level).refresh()
	_tick_packet(level, evidence, first)
	_tick_packet(level, evidence, purple)
	var green: Node2D = _launch(level, evidence, "return")
	var waiting: Array[Node2D] = [purple, green]
	_freeze_waiting(level, evidence, waiting, &"no_route")
	_check(_transport(first).get("state") == &"blocked" and first.global_position == stopped_position
		and not _traffic(level).get_lease(token).is_empty(),
		"6.4 closed occupied edge freezes the real yellow and preserves its original lease")
	_check(not level.recycling_system.try_dispatch(), "Closed collector route rejects new mining without releasing existing claims")
	var snapshot: Dictionary = _traffic(level).get_edge_snapshot(_bottleneck(level))
	_check(int(snapshot["occupied_units"]) == 1 and (snapshot["queue"] as Array).is_empty()
		and level.digestive_organ.incoming_remains == 1 and level.digestive_organ.get_queued_count() == 0
		and level.digestive_organ.get_output_nutrition() == 10 and level.mother_core.nutrition == 71,
		"Node no-route waits cancel obsolete edge requests but retain reservations, products and payment")
	_bottleneck(level).entry_enabled = true
	_traffic(level).refresh()
	_tick_packet(level, evidence, purple)
	_tick_packet(level, evidence, green)
	_check_fifo(level, waiting, "Replanned purple and green share the reopened edge FIFO")
	_until(level, evidence, "reopened_real_packets_finish", func() -> bool:
		return _transport_count(level) == 0)
	_check(level.mother_core.nutrition == 81 and level.digestive_organ.get_queued_nutrition() == 10,
		"Recovery delivers the same original product and carcass batch once")
	_clean_traffic(_traffic(level), "Entry closure and reopening")
	case_results.append(_summary(level, evidence, {"existing_lease_preserved": true, "closed_wait_reason": "no_route"}))
	await _dispose(level, evidence)


func _create_real_blocker(level: Node2D, evidence: Dictionary, kind: String) -> void:
	if kind == "remains":
		# 原攻击器官四点库存、六点容量，恰好允许两包真实黄色在途。
		_launch(level, evidence, "combat")
		_launch(level, evidence, "combat")
	else:
		var blocker: Node2D = _launch(level, evidence, "remains")
		_until_packet_state(level, evidence, blocker, &"moving")
	_check(int(_traffic(level).get_edge_snapshot(_bottleneck(level))["occupied_units"]) == 2,
		"A real business blocker fills the original shared edge without fabricated scheduler owners")


func _remove_business_target(level: Node2D, evidence: Dictionary, kind: String, task_id: int) -> void:
	var target: Node = null
	match kind:
		"combat":
			target = _combat_organ(level)
		"growth":
			target = level.growth_system.get_delivery_target(task_id)
		"cultivation":
			target = level.cultivation_system.get_delivery_target(task_id)
		"remains":
			target = level.digestive_organ
		"return":
			target = level.mother_core
	_check(target != null and target.get_parent() != null, "Actual business target exists before physical removal")
	if target != null and target.get_parent() != null:
		var detached: Array = evidence["detached"]
		detached.append(target)
		target.get_parent().remove_child(target)
		_check(not target.is_inside_tree(), "Target removal uses its real tree-exiting lifecycle")


func _assert_cancelled_business(level: Node2D, evidence: Dictionary, kind: String,
		packet: Node2D, core_before_dispatch: int, incoming_before_dispatch: int,
		stomach_before_dispatch: int, source_after_dispatch: int) -> void:
	var record: Dictionary = evidence["packets"][packet.get_instance_id()]
	_check(int(record["arrivals"]) == 0 and int(record["interruptions"]) == 1
		and _transport(packet).get("state") == &"interrupted",
		"Cancelled " + kind + " produces one real interruption and no invented arrival")
	if kind == "combat" or kind == "growth" or kind == "cultivation":
		_check(level.mother_core.nutrition == core_before_dispatch,
			"Cancelled prepaid " + kind + " refunds exactly once to its original source")
		_check(int(level.growth_system.get_task_snapshot().get("consumed_nutrition", 0)) == 0
			and int(level.cultivation_system.get_resource_snapshot()["structure_consumed"]) == 0,
			"Cancellation before genuine delivery creates no paid construction structure")
		if kind == "combat":
			var receiver: AttackOrgan = evidence["combat_receiver"] as AttackOrgan
			_check(receiver.incoming_nutrition == incoming_before_dispatch,
				"Cancelled combat shipment releases only its original receiver reservation")
	elif kind == "remains":
		var source: LargeCarcass = evidence["carcass"] as LargeCarcass
		_check(source.get_remaining_nutrition() == source_after_dispatch
			and level.digestive_organ.incoming_remains == stomach_before_dispatch,
			"Cancelled remains return the committed batch and release its stomach slot without restoring source stock twice")
		var available_batch: EnemyRemains = null
		for child: Node in level.get_node("World/Remains").get_children():
			if child is EnemyRemains and child.is_available() and not child.is_queued_for_deletion():
				available_batch = child as EnemyRemains
		_check(available_batch != null and available_batch.nutrition_value == 10
			and (evidence["batches"] as Dictionary).has(String(available_batch.get_meta("carcass_batch_id", ""))),
			"Cancelled ten-unit transport drops the same identified claimed carcass batch for later collection")
	else:
		var products: Array[Dictionary] = level.digestive_organ.get_output_products()
		_check(level.mother_core.nutrition == core_before_dispatch and products.size() == 1
			and products[0]["status"] == &"queued" and int(products[0]["nutrition"]) == 10
			and String(products[0]["product_id"]) == String(packet.get_meta("return_product_id", "")),
			"Cancelled green return preserves the same ten-unit output identity with no core income")


func _test_cancellation_matrix() -> void:
	for kind: String in BUSINESS_KINDS:
		for phase: String in ["waiting", "moving"]:
			for action: String in ["cancel", "packet_removed", "target_removed"]:
				var level: Node2D = await _new_level()
				if kind == "cultivation":
					_add_empty_host(level)
				var evidence: Dictionary = _observe(level, kind + "_" + phase + "_" + action)
				if kind == "return" and not await _prime_product(level, evidence):
					await _dispose(level, evidence)
					continue
				var task_id: int = _prepare_business_task(level, kind)
				if phase == "waiting":
					_create_real_blocker(level, evidence, kind)
				var core_before: int = level.mother_core.nutrition
				var incoming_before: int = _combat_organ(level).incoming_nutrition
				var stomach_before: int = level.digestive_organ.incoming_remains
				var packet: Node2D = _launch(level, evidence, kind)
				var state: StringName = &"waiting" if phase == "waiting" else &"moving"
				if not _until_packet_state(level, evidence, packet, state):
					await _dispose(level, evidence)
					continue
				if phase == "moving":
					_tick_packet(level, evidence, packet)
					_check(float(_transport(packet).get("progress", 0.0)) > 0.0,
						"Moving cancellation fixture actually traverses its granted edge before settlement")
				else:
					var waiting: Array[Node2D] = [packet]
					_freeze_waiting(level, evidence, waiting, &"capacity")
				var source_after: int = (evidence["carcass"] as LargeCarcass).get_remaining_nutrition()
				var handle: Dictionary = _transport(packet)
				var request_id: String = String(handle.get("request_id", ""))
				var token: String = String(handle.get("token", ""))
				_checkpoint(level, evidence, "before_real_" + action)
				match action:
					"cancel":
						packet.call("cancel_transport")
						packet.call("cancel_transport")
					"packet_removed":
						var detached: Array = evidence["detached"]
						detached.append(packet)
						packet.get_parent().remove_child(packet)
					"target_removed":
						_remove_business_target(level, evidence, kind, task_id)
						_tick_packet(level, evidence, packet)
						level.growth_supply_system.call("_process", 0.0)
						level.cultivation_supply_system.call("_process", 0.0)
				_traffic(level).refresh()
				_assert_cancelled_business(level, evidence, kind, packet, core_before,
					incoming_before, stomach_before, source_after)
				_check(_traffic(level).get_lease(token).is_empty() and not _traffic(level).release(token)
					and not _traffic(level).cancel_request(request_id),
					"Old waiting or moving traversal handles are inert after real business settlement")
				_replay_settled_callbacks(level, evidence, evidence["packets"][packet.get_instance_id()])
				_checkpoint(level, evidence, "cancelled_once_with_all_mass_retained")
				# 正式业务 reset 必须自行清理其他真实阻挡包，不能依靠 traffic.reset 掩盖泄漏。
				_settle_business(level)
				_checkpoint(level, evidence, "all_business_owners_settled_before_dispatcher_reset")
				case_results.append(_summary(level, evidence, {"business": kind, "phase": phase,
					"action": action, "first_settlement_from_actual_terminal": true}))
				await _dispose(level, evidence)


func _resource_notifications(level: Node2D) -> Dictionary:
	var notifications: Dictionary = {"core": 0, "organ": 0, "stomach": 0, "output": 0}
	level.mother_core.nutrition_changed.connect(func(_amount: int) -> void:
		notifications["core"] = int(notifications["core"]) + 1)
	_combat_organ(level).inventory_changed.connect(func(_stock: int, _incoming: int, _capacity: int) -> void:
		notifications["organ"] = int(notifications["organ"]) + 1)
	level.digestive_organ.inventory_changed.connect(func(_queued: int, _incoming: int) -> void:
		notifications["stomach"] = int(notifications["stomach"]) + 1)
	level.digestive_organ.output_changed.connect(func(_snapshot: Dictionary) -> void:
		notifications["output"] = int(notifications["output"]) + 1)
	return notifications


func _test_missing_configuration() -> void:
	for kind: String in BUSINESS_KINDS:
		for failure: String in ["missing_required_dispatcher", "dispatcher_network_mismatch"]:
			var level: Node2D = await _new_level()
			if kind == "cultivation":
				_add_empty_host(level)
			var evidence: Dictionary = _observe(level, kind + "_rejects_" + failure)
			if kind == "return" and not await _prime_product(level, evidence):
				await _dispose(level, evidence)
				continue
			_prepare_business_task(level, kind)
			var service: Node = _service(level, kind)
			var traffic: NetworkTrafficSystem = _traffic(level)
			var foreign_network: NetworkSystem = null
			if failure == "missing_required_dispatcher":
				service.set("traffic_system", null)
			else:
				# 错配测试复用唯一正式调度器，只替换其网络依赖，不创建另一类通道池。
				foreign_network = NetworkSystem.new()
				foreign_network.name = "WrongNetworkForAdmissionCheck"
				level.get_node("Systems").add_child(foreign_network)
				traffic.network_system = foreign_network
			var before: Dictionary = _resources(level, evidence)
			var packet_count: int = (evidence["packets"] as Dictionary).size()
			var incoming: int = level.digestive_organ.incoming_remains
			var batches: int = (evidence["batches"] as Dictionary).size()
			var notifications: Dictionary = _resource_notifications(level)
			_check(bool(service.get("traffic_required")) and not _dispatch(level, kind),
				"Mandatory " + kind + " rejects " + failure + " before dispatch")
			_check(_resources(level, evidence) == before and (evidence["packets"] as Dictionary).size() == packet_count
				and level.digestive_organ.incoming_remains == incoming
				and (evidence["batches"] as Dictionary).size() == batches,
				"Bad mandatory traffic configuration cannot debit, reserve, claim, harvest, or create a fallback packet")
			_check(notifications == {"core": 0, "organ": 0, "stomach": 0, "output": 0},
				"Admission rejection happens before even transient debit/reservation/claim notifications")
			service.set("traffic_system", traffic)
			traffic.network_system = level.network_system
			traffic.refresh()
			if foreign_network != null:
				foreign_network.free()
			_checkpoint(level, evidence, "strict_configuration_rejection_without_bypass")
			case_results.append(_summary(level, evidence, {"business": kind, "configuration_failure": failure,
				"resource_notifications_during_rejection": notifications.duplicate()}))
			await _dispose(level, evidence)


func _test_dispatcher_reset() -> void:
	var level: Node2D = await _new_level()
	var evidence: Dictionary = _observe(level, "dispatcher_reset_retires_actual_business_handles_and_late_callbacks")
	if not await _prime_product(level, evidence):
		await _dispose(level, evidence)
		return
	_prepare_business_task(level, "growth")
	var yellow: Node2D = _launch(level, evidence, "combat")
	var purple: Node2D = _launch(level, evidence, "remains")
	_until_packet_state(level, evidence, purple, &"waiting")
	var green: Node2D = _launch(level, evidence, "return")
	var growth: Node2D = _launch(level, evidence, "growth")
	var packets: Array[Node2D] = [yellow, purple, green, growth]
	var old_handles: Array[Dictionary] = []
	for packet: Node2D in packets:
		if packet != null:
			old_handles.append(_transport(packet))
	var generation: int = _traffic(level).get_generation()
	_checkpoint(level, evidence, "before_dispatcher_reset")
	_traffic(level).reset()
	_check(_traffic(level).get_generation() == generation + 1, "Explicit dispatcher reset advances one generation")
	_clean_traffic(_traffic(level), "Direct dispatcher reset")
	_until(level, evidence, "old_packets_detect_retired_permissions", func() -> bool:
		return _transport_count(level) == 0)
	_check(level.mother_core.nutrition == 72 and level.digestive_organ.get_queued_count() == 0
		and level.digestive_organ.incoming_remains == 0 and level.digestive_organ.get_output_nutrition() == 10
		and level.digestive_organ.get_output_products()[0]["status"] == &"queued",
		"Lost dispatcher permissions refund prepaid yellows, drop the same purple batch, and preserve the green product")
	var fresh: Node2D = _launch(level, evidence, "combat")
	var fresh_traffic: Dictionary = _traffic(level).get_snapshot()
	var resources: Dictionary = _resources(level, evidence)
	for handle: Dictionary in old_handles:
		_check(_traffic(level).get_request(String(handle["request_id"])).is_empty()
			and _traffic(level).get_lease(String(handle["token"])).is_empty()
			and not _traffic(level).cancel_request(String(handle["request_id"]))
			and not _traffic(level).release(String(handle["token"])),
			"Previous-generation request IDs and tokens cannot affect a new actual shipment")
	for packet: Node2D in packets:
		if packet != null and is_instance_valid(packet):
			_replay_settled_callbacks(level, evidence, evidence["packets"][packet.get_instance_id()])
	_check(_resources(level, evidence) == resources and _traffic(level).get_snapshot() == fresh_traffic,
		"Late old callbacks do not refund or release the new generation's real packet")
	_until(level, evidence, "new_generation_combat_arrives_normally", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0)
	_check(fresh != null and level.mother_core.nutrition == 71,
		"Fresh real traffic still pays and arrives exactly once after reset")
	level.growth_system.cancel_task()
	var source: LargeCarcass = evidence["carcass"] as LargeCarcass
	var source_stock: int = source.get_remaining_nutrition()
	var batch_count: int = (evidence["batches"] as Dictionary).size()
	var recovered_purple: Node2D = _launch(level, evidence, "remains")
	var recovered_green: Node2D = _launch(level, evidence, "return")
	_check(source.get_remaining_nutrition() == source_stock
		and (evidence["batches"] as Dictionary).size() == batch_count,
		"Retry collects the same cancelled carcass batch rather than harvesting or debiting the original source again")
	if recovered_green != null and green != null:
		_check(String(recovered_green.get_meta("return_product_id", "")) == String(green.get_meta("return_product_id", ""))
			and String(recovered_green.get_meta("return_attempt_id", "")) != String(green.get_meta("return_attempt_id", "")),
			"Retry green packet owns the original product under a distinct real transport attempt")
		_replay_settled_callbacks(level, evidence, evidence["packets"][green.get_instance_id()])
	if recovered_purple != null and purple != null:
		_replay_settled_callbacks(level, evidence, evidence["packets"][purple.get_instance_id()])
	_until(level, evidence, "cancelled_batch_and_original_product_retry_arrive", func() -> bool:
		return _transport_count(level) == 0)
	_check(level.mother_core.nutrition == 81 and level.mother_core.get_received_product_count() == 1
		and level.colony_progress.get_total_recovered() == 10
		and level.digestive_organ.get_queued_nutrition() == 10
		and level.digestive_organ.get_output_count() == 0 and source.get_remaining_nutrition() == source_stock,
		"Real retries preserve the cancelled body and credit its previously unreceived original product exactly once")
	_clean_traffic(_traffic(level), "Reset generation and fresh business completion")
	_checkpoint(level, evidence, "fresh_generation_conserves_all_old_resource_owners")
	case_results.append(_summary(level, evidence, {"old_generation": generation,
		"new_generation": _traffic(level).get_generation(), "stale_handles_checked": old_handles.size()}))
	await _dispose(level, evidence)


func _press_restart() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = KEY_R
	event.physical_keycode = KEY_R
	event.pressed = true
	root.push_input(event)
	var released: InputEventKey = event.duplicate() as InputEventKey
	released.pressed = false
	root.push_input(released)


func _test_restart(kind: String) -> void:
	var level: Node2D = await _new_level()
	if kind == "cultivation":
		_add_empty_host(level)
	var evidence: Dictionary = _observe(level, "actual_R_with_" + kind + "_moving_and_opposing_business_waiting")
	if not await _prime_product(level, evidence):
		await _dispose(level, evidence)
		return
	_prepare_business_task(level, kind)
	var construction: Node2D = _launch(level, evidence, kind)
	var combat: Node2D = _launch(level, evidence, "combat")
	if construction == null or combat == null:
		await _dispose(level, evidence)
		return
	_tick_packet(level, evidence, construction)
	_tick_packet(level, evidence, combat)
	_check(_transport(construction).get("state") == &"moving" and float(_transport(construction)["progress"]) > 0.0
		and _transport(combat).get("state") == &"moving" and float(_transport(combat)["progress"]) > 0.0,
		"Actual R fixture owns two actually moving prepaid yellow packets")
	var purple: Node2D = _launch(level, evidence, "remains")
	_until_packet_state(level, evidence, purple, &"waiting")
	var green: Node2D = _launch(level, evidence, "return")
	var waiting: Array[Node2D] = [purple, green]
	_freeze_waiting(level, evidence, waiting, &"capacity")
	var packets: Array[Node2D] = [construction, combat, purple, green]
	var packet_ids: Array[int] = []
	var callbacks: Array[Callable] = []
	var handles: Array[Dictionary] = []
	for packet: Node2D in packets:
		if packet != null:
			packet_ids.append(packet.get_instance_id())
			handles.append(_transport(packet))
			var record: Dictionary = evidence["packets"][packet.get_instance_id()]
			callbacks.append_array(record["arrived_callbacks"])
			callbacks.append_array(record["interrupted_callbacks"])
	var traffic: NetworkTrafficSystem = _traffic(level)
	var dispatcher_id: int = traffic.get_instance_id()
	var generation: int = traffic.get_generation()
	var balances: Array[int] = []
	var reset_evidence: Dictionary = {"observed": false}
	level.mother_core.nutrition_changed.connect(func(amount: int) -> void:
		balances.append(amount))
	traffic.traffic_changed.connect(func() -> void:
		if bool(reset_evidence["observed"]) or traffic.get_generation() == generation:
			return
		reset_evidence["observed"] = true
		reset_evidence["generation"] = traffic.get_generation()
		reset_evidence["business_in_transit"] = _transport_count(level)
		reset_evidence["combat_reserved"] = _combat_organ(level).incoming_nutrition
		reset_evidence["stomach_reserved"] = level.digestive_organ.incoming_remains
		reset_evidence["core_balance"] = level.mother_core.nutrition
		reset_evidence["occupied"] = traffic.get_snapshot().get("occupied_units")
		reset_evidence["queued"] = traffic.get_snapshot().get("queued_count")
		_check(_transport_count(level) == 0 and _combat_organ(level).incoming_nutrition == 0
			and level.digestive_organ.incoming_remains == 0 and level.mother_core.nutrition == 72,
			"Actual R settles every prepaid business and reservation before resetting the dispatcher")
		_clean_traffic(traffic, "R's dispatcher reset after business cancellation"))
	_checkpoint(level, evidence, "before_actual_R_input")
	root.child_entered_tree.connect(_prepare_reload_child)
	_press_restart()
	for _frame: int in range(40):
		await physics_frame
		await process_frame
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	evidence["active"] = false
	var restarted: Node2D = current_scene as Node2D
	_check(is_instance_valid(restarted) and restarted != level and not is_instance_valid(level),
		"Actual R input removes the old level and reloads the formal scene")
	if not is_instance_valid(restarted) or restarted == level:
		if is_instance_valid(level):
			await _dispose(level, evidence)
		return
	_stop_level(restarted)
	_assert_formal_wiring(restarted)
	_check(bool(reset_evidence["observed"]) and not balances.is_empty() and balances.back() == 72,
		"R observed dispatcher reset only after both unspent debits returned to the original core")
	for amount: int in balances:
		_check(amount <= 72, "R cannot duplicate any old prepaid refund")
	var retired: bool = true
	for callback: Callable in callbacks:
		retired = retired and not callback.is_valid()
	for packet_id: int in packet_ids:
		_check(not is_instance_valid(instance_from_id(packet_id)), "R destroys each old moving or waiting physical packet")
		var record: Dictionary = evidence["packets"][packet_id]
		_check(int(record["arrivals"]) == 0 and int(record["interruptions"]) == 1,
			"Actual R cancels each live business packet once without a fabricated delivery")
	_check(retired and not is_instance_valid(instance_from_id(dispatcher_id)),
		"R retires old business callback owners and the old shared dispatcher")
	for handle: Dictionary in handles:
		_check(_traffic(restarted).get_request(String(handle["request_id"])).is_empty()
			and _traffic(restarted).get_lease(String(handle["token"])).is_empty()
			and not _traffic(restarted).release(String(handle["token"]))
			and not _traffic(restarted).cancel_request(String(handle["request_id"])),
			"Old R request IDs and tokens are inert in the newly loaded formal dispatcher")
	for path: String in PACKET_PATHS + ["World/GrowthTips", "World/GrowthTargets", "World/Remains"]:
		_check(restarted.get_node(path).get_child_count() == 0, "R clears old transport or construction objects in " + path)
	_check(restarted.mother_core.nutrition == 72 and restarted.mother_core.get_received_product_count() == 0
		and restarted.colony_progress.get_total_recovered() == 0
		and restarted.digestive_organ.get_output_count() == 0 and restarted.digestive_organ.incoming_remains == 0
		and restarted.hypha_nodes.get_child_count() == 3 and restarted.hypha_edges.get_child_count() == 4
		and restarted.growth_system.get_task_snapshot().get("state") == &"idle"
		and not restarted.cultivation_system.has_active_task(),
		"R restores the formal initial capital, physical network, idle construction, and empty received-product ledger")
	_clean_traffic(_traffic(restarted), "Fresh formal scene after actual R")
	var fresh: Dictionary = _observe(restarted, kind + "_R_late_callback_window")
	for _step: int in range(400):
		_tick(restarted, fresh)
	_check(restarted.mother_core.nutrition == 72 and _transport_count(restarted) == 0
		and (fresh["packets"] as Dictionary).is_empty() and (fresh["receipts"] as Dictionary).is_empty(),
		"Simulating beyond old travel time after R creates no ghost movement, debit, refund, or credit")
	_checkpoint(restarted, fresh, "fresh_scene_has_no_late_business_work")
	var packet_summary: Array[Dictionary] = []
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		packet_summary.append({"id": record["id"], "kind": record["kind"], "states": record["states"],
			"task_id": record["task_id"], "dispatcher_id": record["dispatcher_id"],
			"arrivals": record["arrivals"], "interruptions": record["interruptions"]})
	case_results.append({"name": evidence["label"], "construction_kind": kind,
		"reset_observation_before_reload": reset_evidence, "original_core_refund_balances": balances,
		"old_callbacks_retired": retired, "old_packets": packet_summary,
		"fresh_scene": _summary(restarted, fresh)})
	await _dispose(restarted, fresh)
