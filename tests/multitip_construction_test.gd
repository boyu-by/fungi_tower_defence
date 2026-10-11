extends SceneTree
## 7.3 正式多端集成：只驱动原模块的派送、物理运输和 advance。
## 所有施工付款经过 ConstructionSupplyScheduler.dispatch_round；首次收件从不伪造。
## 运行由父任务负责：Godot --headless --fixed-fps 60 --path . --script tests/multitip_construction_test.gd

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const WORKER_SCENE_PATH: String = "res://scenes/systems/construction_worker.tscn"
const STEP: float = 0.1
const STEP_LIMIT: int = 4000
const CAPITAL: int = 72
const SOURCE_NUTRITION: int = 80
const LEFT_REMOTE: Vector2 = Vector2(440, 260)
const RIGHT_REMOTE: Vector2 = Vector2(940, 400)
const THIRD_TARGET: Vector2 = Vector2(580, 780)
const PACKET_PATHS: Array[String] = [
	"World/GrowthPackets", "World/CultivationPackets", "World/Packets",
	"World/RepairPackets", "World/RecoveryPackets", "World/ReturnPackets",
]
const RESOURCE_FIELDS: Array[String] = [
	"network_structure", "organ_structure", "growth_buffer", "cultivation_buffer",
	"startup_reserved", "growth_transit", "cultivation_transit", "startup_transferred",
]
const MODULES: Dictionary = {
	"GrowthSystem": "growth_system", "GrowthSupplySystem": "growth_supply_system",
	"CultivationSystem": "cultivation_system", "CultivationSupplySystem": "cultivation_supply_system",
	"RemoteCultivationSystem": "remote_cultivation_system", "ConnectionSystem": "connection_system",
}
const ORIGINAL_SCRIPTS: Dictionary = {
	"GrowthSystem": "res://scripts/growth_system.gd",
	"GrowthSupplySystem": "res://scripts/growth_supply_system.gd",
	"CultivationSystem": "res://scripts/cultivation_system.gd",
	"CultivationSupplySystem": "res://scripts/cultivation_supply_system.gd",
	"RemoteCultivationSystem": "res://scripts/remote_cultivation_system.gd",
	"ConnectionSystem": "res://scripts/connection_system.gd",
}

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_formal_multitip_cycle()
	_check(root.get_child_count() == 0, "All formal scenes and physical workers are disposed")
	print("MULTITIP_CONSTRUCTION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "conservation_checks": conservation_checks,
		"cases": cases, "evidence": "formal_scene_original_modules_and_physical_packets",
		"first_arrivals_fabricated": false, "stage_receipts_fabricated": false,
		"cache_injected": false, "packet_speed_changed": false,
		"construction_funding": "scheduler.dispatch_round_only",
		"fixture_resources": "default_80_carcasses_and_explicit_conserved_escrow",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _coordinator(level: Node2D) -> ConstructionCoordinator:
	return level.get("construction_coordinator") as ConstructionCoordinator


func _queue(level: Node2D) -> ConstructionQueue:
	return level.get("construction_queue") as ConstructionQueue


func _scheduler(level: Node2D) -> ConstructionSupplyScheduler:
	return level.get("construction_supply_scheduler") as ConstructionSupplyScheduler


func _left(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode


func _right(level: Node2D) -> HyphaNode:
	return level.get_node("World/Colony/Nodes/RightNode") as HyphaNode


func _repair(level: Node2D) -> RepairSystem:
	return level.get_node("Systems/RepairSystem") as RepairSystem


func _repair_supply(level: Node2D) -> RepairSupplySystem:
	return level.get_node("Systems/RepairSupplySystem") as RepairSupplySystem


func _prepare(level: Node2D) -> void:
	# 保留本用例的原容量2/35HP交通与账目基线；主脉动态成长由7.5真实整合验证。
	level.get_node("Systems/MainVeinSystem").set("enabled", false)
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	level.get_node("Systems/RepairSupplySystem").auto_supply = false
	level.get_node("Systems/SupplySystem/DispatchTimer").autostart = false
	level.get_node("Systems/RecyclingSystem/DispatchTimer").autostart = false
	var coordinator: Node = level.get_node_or_null("Systems/ConstructionCoordinator")
	if coordinator != null:
		coordinator.set("auto_execute", false)
	var scheduler: Node = level.get_node_or_null("Systems/ConstructionSupplyScheduler")
	if scheduler != null:
		scheduler.set("auto_dispatch", false)
	for path: String in ["World/Colony/Nodes/HyphaNode", "World/Colony/Nodes/RightNode"]:
		level.get_node(path + "/SporeWeapon/FireTimer").autostart = false


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare(child as Node2D)


func _quiet(level: Node2D) -> void:
	level.set_process(false)
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.nutrition_return_system.get_node("DispatchTimer").stop()
	level.nutrition_return_system.auto_return = false
	level.growth_system.set_physics_process(false)
	level.cultivation_system.set_physics_process(false)
	level.growth_supply_system.set_process(false)
	level.cultivation_supply_system.set_process(false)
	level.traffic_system.set_process(false)
	level.fungal_field.set_process(false)
	_repair(level).set_physics_process(false)
	_repair_supply(level).set_process(false)
	if _scheduler(level) != null:
		_scheduler(level).auto_dispatch = false
		_scheduler(level).set_process(false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level() -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare(level)
	root.add_child(level)
	current_scene = level
	_quiet(level)
	await process_frame
	await process_frame
	level.call("_process", 0.0)
	level.fungal_field.advance(1.0)
	_check(level.mother_core.nutrition == CAPITAL and level.get_node("World/Enemies").get_child_count() == 0,
		"Formal scene retains its original 72 capital and no unrelated enemy traffic")
	return level


func _check_wiring(level: Node2D) -> bool:
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var scheduler: ConstructionSupplyScheduler = _scheduler(level)
	var container: Node = level.get_node_or_null("Systems/ConstructionWorkers")
	var available: bool = coordinator != null and queue != null and scheduler != null and container != null
	_check(available, "Formal scene exports its queue, worker container and construction supply scheduler")
	if not available:
		return false
	_check(coordinator.multi_worker_enabled and queue.multi_execution,
		"Formal scene selects real multi-worker execution before any admission")
	_check(coordinator.worker_container == container and coordinator.supply_scheduler == scheduler
		and scheduler == level.get_node("Systems/ConstructionSupplyScheduler")
		and coordinator.worker_scene.resource_path == WORKER_SCENE_PATH,
		"Formal coordinator uses ConstructionWorker scene and exact parent-owned scheduler/container")
	_check(coordinator.queue == queue and coordinator.mother_core == level.mother_core
		and coordinator.network_system == level.network_system
		and queue.capabilities == level.colony_capabilities
		and level.colony_capabilities.colony_progress == level.colony_progress,
		"Worker admission preserves the original payer, network and real capability source")
	var traffic_count: int = 0
	for child: Node in level.get_node("Systems").get_children():
		if child is NetworkTrafficSystem:
			traffic_count += 1
	_check(traffic_count == 1 and level.colony_capabilities.get_external_target_limit() == 3,
		"All construction uses one physical FIFO and the capability-owned external cap of three")
	return true


func _add_carcass_fixtures(level: Node2D, count: int) -> Array[LargeCarcass]:
	var sources: Array[LargeCarcass] = []
	for index: int in range(count):
		# 明示外部资源夹具；没有改核心余额，也没有调用任何回收收件入口。
		var source: LargeCarcass = CARCASS_SCENE.instantiate() as LargeCarcass
		source.name = "MultitipFixtureCarcass%d" % index
		source.position = level.mother_core.global_position + Vector2(-40, index * 24)
		level.get_node("World/Remains").add_child(source)
		sources.append(source)
		_check(source.get_remaining_nutrition() == SOURCE_NUTRITION
			and source.batch_size == LargeCarcass.MAX_BATCH_SIZE,
			"Each explicitly added corpse keeps its original eighty units and ten-unit batches")
	level.fungal_field.advance(1.0)
	return sources


func _observe(level: Node2D, label: String) -> Dictionary:
	var evidence: Dictionary = {
		"label": label, "active": true, "initial_total": 0, "worker_records": {},
		"growth_costs": {}, "organ_costs": {}, "repair_costs": {}, "packets": {},
		"receipts": {}, "matured": [], "finished": [], "handoffs": {}, "checkpoints": [],
		"escrow": 0, "fixture_escrow_transfers": 0, "organ_consumed": 0,
		"callback_replays": 0, "dispatch_rounds": 0, "nested_dispatch_attempts": 0,
		"funding_now": false,
		"dispatcher_id": level.traffic_system.get_instance_id(),
	}
	_coordinator(level).changed.connect(func(_snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_sync_workers(level, evidence))
	_coordinator(level).request_finished.connect(func(construction_id: String, state: StringName) -> void:
		if not bool(evidence["active"]):
			return
		var finished: Array = evidence["finished"]
		for previous: Dictionary in finished:
			_check(previous["construction_id"] != construction_id, "Each construction has exactly one terminal notification")
		finished.append({"construction_id": construction_id, "state": String(state)}))
	_repair(level).task_changed.connect(func(snapshot: Dictionary) -> void:
		if bool(evidence["active"]):
			_remember_cost(evidence["repair_costs"], "repair", snapshot))
	level.mother_core.digestion_product_arrived.connect(func(product_id: String, amount: int) -> void:
		if not bool(evidence["active"]):
			return
		var receipts: Dictionary = evidence["receipts"]
		_check(not receipts.has(product_id) and amount == 10,
			"Only an actual unique ten-unit green receipt changes recovered income")
		receipts[product_id] = amount)
	level.mother_core.nutrition_changed.connect(func(_amount: int) -> void:
		if bool(evidence["active"]) and bool(evidence["funding_now"]):
			evidence["nested_dispatch_attempts"] = int(evidence["nested_dispatch_attempts"]) + 1
			_check(_scheduler(level).dispatch_round() == 0,
				"Original debit callback cannot recursively enter another scheduler round"))
	for index: int in range(PACKET_PATHS.size()):
		var kind: String = ["growth", "cultivation", "combat", "repair", "remains", "return"][index]
		level.get_node(PACKET_PATHS[index]).child_entered_tree.connect(func(child: Node) -> void:
			if bool(evidence["active"]) and (child is NutrientPacket or child is RemainsPacket):
				_watch_packet(level, evidence, child as Node2D, kind))
	_sync_workers(level, evidence)
	evidence["initial_total"] = int(_resources(level, evidence)["total"])
	_checkpoint(level, evidence, "initial", true)
	return evidence


func _remember_cost(costs: Dictionary, prefix: String, snapshot: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		var identity: String = "%s:%d" % [prefix, task_id]
		costs[identity] = maxi(int(costs.get(identity, 0)), int(snapshot.get("consumed_nutrition", 0)))


func _remember_worker(worker: ConstructionWorker, evidence: Dictionary) -> void:
	if not is_instance_valid(worker) or worker.growth_system == null or worker.cultivation_system == null:
		return
	# 使用实体实例 + 原 task_id，不能把不同 worker 中相同整数 ID 合成一笔支出。
	_remember_cost(evidence["growth_costs"], str(worker.get_instance_id()), worker.growth_system.get_task_snapshot())
	var original: Dictionary = worker.cultivation_system.get_resource_snapshot()
	var costs: Dictionary = evidence["organ_costs"]
	var key: int = worker.get_instance_id()
	costs[key] = maxi(int(costs.get(key, 0)), int(original.get("structure_consumed", 0)))


func _sync_workers(level: Node2D, evidence: Dictionary) -> void:
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		if not is_instance_valid(worker) or worker.growth_system == null or worker.cultivation_system == null:
			continue
		worker.growth_system.set_physics_process(false)
		worker.cultivation_system.set_physics_process(false)
		worker.growth_supply_system.set_process(false)
		worker.cultivation_supply_system.set_process(false)
		var records: Dictionary = evidence["worker_records"]
		var instance_id: int = worker.get_instance_id()
		if not records.has(instance_id):
			var snapshot: Dictionary = worker.get_snapshot()
			records[instance_id] = {"worker_id": int(snapshot.get("worker_id", 0)), "worker": worker}
			worker.growth_system.task_changed.connect(func(task: Dictionary) -> void:
				if bool(evidence["active"]):
					_remember_cost(evidence["growth_costs"], str(instance_id), task))
			worker.cultivation_system.task_changed.connect(func(_task: Dictionary) -> void:
				if bool(evidence["active"]):
					_remember_worker(worker, evidence))
			worker.maturation_started.connect(func(construction_id: String) -> void:
				if bool(evidence["active"]):
					var handoffs: Dictionary = evidence["handoffs"]
					handoffs[construction_id] = int(handoffs.get(construction_id, 0)) + 1)
			worker.organ_matured.connect(
				func(construction_id: String, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon) -> void:
					if not bool(evidence["active"]):
						return
					weapon.get_node("FireTimer").stop()
					var request: Dictionary = _queue(level).get_request(construction_id)
					var task_id: int = int(request.get("internal_ids", {}).get("cultivation_task_id", 0))
					var task: Dictionary = worker.cultivation_system.get_task_snapshot(task_id)
					_check(task.get("state") == &"completed" and int(task.get("structure_consumed", -1)) == 8
						and int(task.get("startup_transferred", -1)) == 4 and int(task.get("startup_reserved", -1)) == 0
						and float(task.get("effective_time", 0.0)) >= CultivationSystem.MINIMUM_EFFECTIVE_TIME,
						"Real original cultivation consumes eight structure and transfers four stock after three effective seconds")
					_check(organ.nutrition == 4 and organ.incoming_nutrition == 0 and organ.get_parent() == host
						and weapon.get_parent() == host and weapon.inventory_owner == organ
						and not host.is_organ_slot_available(),
						"Each matured organ commits exactly its own physical host and original startup inventory")
					(evidence["matured"] as Array).append({"construction_id": construction_id,
						"worker_id": int(worker.get_snapshot().get("worker_id", 0)), "task_id": task_id,
						"host_id": host.get_instance_id(), "structure": 8, "stock": organ.nutrition}))
		_remember_worker(worker, evidence)


func _packet_owner(level: Node2D, packet: Node2D, kind: String) -> Node:
	if kind in ["growth", "cultivation"]:
		for worker: ConstructionWorker in _coordinator(level).get_workers(true):
			var supply: Node = worker.growth_supply_system if kind == "growth" else worker.cultivation_supply_system
			if supply == null:
				continue
			for shipment: Dictionary in supply.call("get_shipment_records"):
				if shipment.get("packet") == packet:
					return supply
		return null
	var paths: Dictionary = {"combat": "Systems/SupplySystem", "repair": "Systems/RepairSupplySystem",
		"remains": "Systems/RecyclingSystem", "return": "Systems/NutritionReturnSystem"}
	return level.get_node(paths[kind])


func _callbacks(packet: Node, owner: Node, signal_name: StringName) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _watch_packet(level: Node2D, evidence: Dictionary, packet: Node2D, kind: String) -> void:
	packet.set_physics_process(false)
	var owner: Node = _packet_owner(level, packet, kind)
	var record: Dictionary = {"id": packet.get_instance_id(), "packet": packet, "owner": owner,
		"kind": kind, "movements": 0, "arrivals": 0, "interruptions": 0,
		"task_id": "", "target": null, "edges": [], "handles": [],
		"arrived_callbacks": _callbacks(packet, owner, &"arrived"),
		"interrupted_callbacks": _callbacks(packet, owner, &"interrupted")}
	(evidence["packets"] as Dictionary)[packet.get_instance_id()] = record
	_check(owner != null and bool(packet.get("traffic_required"))
		and not (record["arrived_callbacks"] as Array).is_empty(),
		"Original %s packet enters the shared world with its owning original settlement callback" % kind)
	packet.connect(&"status_changed", func(snapshot: Dictionary) -> void:
		if not bool(evidence["active"]) or not bool(snapshot.get("started", false)):
			return
		var task_id: String = String(snapshot.get("task_id", ""))
		if String(record["task_id"]).is_empty():
			record["task_id"] = task_id
			record["target"] = snapshot.get("final_target")
		_check(task_id == String(record["task_id"]) and snapshot.get("final_target") == record["target"]
			and int(snapshot.get("traffic_system_id", 0)) == int(evidence["dispatcher_id"]),
			"Physical %s shipment keeps its original task, endpoint and shared dispatcher" % kind)
		var edge: HyphaEdge = snapshot.get("edge") as HyphaEdge
		if is_instance_valid(edge) and not (record["edges"] as Array).has(edge.get_instance_id()):
			(record["edges"] as Array).append(edge.get_instance_id())
		if not String(snapshot.get("token", "")).is_empty():
			(record["handles"] as Array).append(snapshot.duplicate()))
	packet.connect(&"arrived", func(arrived: Node2D) -> void:
		if not bool(evidence["active"]):
			return
		record["arrivals"] = int(record["arrivals"]) + 1
		var target: Node2D = record["target"] as Node2D
		_check(int(record["arrivals"]) == 1 and int(record["interruptions"]) == 0
			and is_instance_valid(target) and arrived.global_position.distance_to(target.global_position) < 0.05
			and bool(arrived.call("has_arrived_at", target, String(record["task_id"]))),
			"First %s receipt is a real unique physical arrival at its captured endpoint" % kind)
		if kind in ["growth", "cultivation", "remains", "return"]:
			_check(int(record["movements"]) > 0 and float(record.get("actual_displacement", 0.0)) > 0.0
				and not (record["edges"] as Array).is_empty(),
				"First %s receipt follows actual movement on original network edges" % kind))
	packet.connect(&"interrupted", func(_interrupted: Node2D) -> void:
		if bool(evidence["active"]):
			record["interruptions"] = int(record["interruptions"]) + 1
			_check(int(record["interruptions"]) == 1 and int(record["arrivals"]) == 0,
				"Actual cancelled %s cargo settles once without a false first receipt" % kind))


func _resources(level: Node2D, evidence: Dictionary) -> Dictionary:
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		_remember_worker(worker, evidence)
	_remember_cost(evidence["repair_costs"], "repair", _repair(level).get_task_snapshot())
	var construction: Dictionary = _coordinator(level).get_resource_snapshot()
	var repair: Dictionary = _repair(level).get_task_snapshot()
	var parts: Dictionary = {"core": int(level.mother_core.nutrition), "organ_stock": 0,
		"combat_transit": int(level.supply_system.get_in_transit_count()),
		"repair_transit": int(_repair_supply(level).get_in_transit_nutrition()),
		"repair_buffer": int(repair.get("buffered_nutrition", 0)), "repair_consumed": 0,
		"corpse_stock": 0, "live_remains": 0, "digestive_queue": int(level.digestive_organ.get_queued_nutrition()),
		"products_including_return_transit": 0, "fixture_escrow": int(evidence["escrow"]),
		"organ_consumed": int(evidence["organ_consumed"])}
	for field: String in RESOURCE_FIELDS:
		if field != "startup_transferred":
			parts[field] = int(construction.get(field, 0))
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
	for amount: int in (evidence["repair_costs"] as Dictionary).values():
		parts["repair_consumed"] = int(parts["repair_consumed"]) + amount
	for child: Node in level.get_node("World/Remains").get_children():
		if child.is_queued_for_deletion():
			continue
		if child is LargeCarcass:
			parts["corpse_stock"] = int(parts["corpse_stock"]) + child.get_remaining_nutrition()
		elif child is EnemyRemains:
			parts["live_remains"] = int(parts["live_remains"]) + child.nutrition_value
	for product: Dictionary in level.digestive_organ.get_output_products():
		parts["products_including_return_transit"] = int(parts["products_including_return_transit"]) + int(product["nutrition"])
	# 预算锁仍属于余额；紫包引用尸块，绿包引用产物；startup_transferred 已在 organ_stock。
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	return parts


func _sum_values(values: Dictionary) -> int:
	var total: int = 0
	for amount: int in values.values():
		total += amount
	return total


func _checkpoint(level: Node2D, evidence: Dictionary, phase: String, remember: bool = false) -> void:
	level.call("_process", 0.0)
	var resources: Dictionary = _resources(level, evidence)
	var construction: Dictionary = _coordinator(level).get_resource_snapshot()
	conservation_checks += 1
	_check(int(resources["total"]) == int(evidence["initial_total"]),
		"%s/%s preserves exact balance, paid cargo, stocks, buffers and permanent spending: %s"
		% [evidence["label"], phase, resources])
	for field: String in RESOURCE_FIELDS:
		_check(construction.has(field) and typeof(construction[field]) == TYPE_INT and int(construction[field]) >= 0,
			"Coordinator resource snapshot exposes nonnegative integer " + field)
	_check(int(construction.get("network_structure", -1)) == _sum_values(evidence["growth_costs"])
		and int(construction.get("organ_structure", -1)) == _sum_values(evidence["organ_costs"]),
		"Aggregate and archived structure equal independently observed original ledgers without merged task IDs")
	var budget: Dictionary = level.mother_core.get_budget_snapshot()
	_check(int(budget["balance"]) == int(resources["core"])
		and int(budget["reserved"]) + int(budget["spendable"]) == int(budget["balance"]),
		"Repair reservations partition the actual payer balance without adding resources")
	var snapshot: Dictionary = _coordinator(level).get_snapshot()
	var external_count: int = 0
	var tip_count: int = 0
	var active_ids: Array[String] = []
	for entry: Dictionary in snapshot.get("entries", []):
		if bool(entry.get("occupies_external_slot", false)):
			external_count += 1
		if bool(entry.get("occupies_tip_slot", false)):
			tip_count += 1
			active_ids.append(String(entry["construction_id"]))
	for entry: Dictionary in snapshot.get("maturing", []):
		_check(entry.get("phase") == &"maturing" and not bool(entry.get("occupies_external_slot", true))
			and not bool(entry.get("occupies_tip_slot", true)),
			"A real mature/local task consumes neither external admission nor active extension slot")
	_check(snapshot.has("waiting_count") and snapshot.has("maturing_count")
		and int(snapshot.get("external_count", -1)) == external_count and external_count <= 3
		and int(snapshot.get("tip_count", -1)) == tip_count
		and int(snapshot.get("tip_limit", -1)) == level.colony_capabilities.get_extension_tip_limit()
		and tip_count <= int(snapshot.get("tip_limit", 0)) and tip_count <= 2
		and snapshot.get("active_ids", []) == active_ids
		and int(snapshot.get("maturing_count", -1)) == snapshot.get("maturing", []).size(),
		"Query counts, active IDs and physical capability bounds agree for the exact current requests")
	var physical_tips: int = 0
	for child: Node in level.get_node("World/GrowthTips").get_children():
		if child is GrowthTip and not child.is_queued_for_deletion():
			physical_tips += 1
	_check(physical_tips <= tip_count and physical_tips <= 2,
		"There are never more than two actual original GrowthTip objects")
	var worker_ids: Array[int] = []
	var worker_instances: Array[int] = []
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		var worker_snapshot: Dictionary = worker.get_snapshot()
		var worker_id: int = int(worker_snapshot.get("worker_id", 0))
		_check(worker_id > 0 and not worker_ids.has(worker_id) and not worker_instances.has(worker.get_instance_id()),
			"get_workers returns each positive worker identity and live instance exactly once")
		worker_ids.append(worker_id)
		worker_instances.append(worker.get_instance_id())
		var local_resources: Dictionary = worker.get_resource_snapshot()
		for field: String in RESOURCE_FIELDS:
			_check(local_resources.has(field) and typeof(local_resources[field]) == TYPE_INT,
				"Worker resource query has the frozen integer field " + field)
	for row: Dictionary in level.traffic_system.get_snapshot()["edges"]:
		_check(int(row["capacity"]) == 2 and int(row["occupied_units"]) >= 0 and int(row["occupied_units"]) <= 2,
			"Every old and new physical route uses the original shared edge capacity/FIFO")
	if remember:
		(evidence["checkpoints"] as Array).append({"phase": phase, "resources": resources,
			"tip_count": tip_count, "external_count": external_count,
			"maturing_count": int(snapshot.get("maturing_count", 0))})


func _payments(worker: ConstructionWorker) -> int:
	var paid: int = 0
	for supply: Node in [worker.growth_supply_system, worker.cultivation_supply_system]:
		for shipment: Dictionary in supply.call("get_shipment_records"):
			if bool(shipment.get("debited", false)):
				paid += 1
	return paid


func _fund_round(level: Node2D, evidence: Dictionary) -> int:
	var before: Dictionary = {}
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		before[worker.get_instance_id()] = _payments(worker)
	var balance: int = level.mother_core.nutrition
	evidence["funding_now"] = true
	var dispatched: int = _scheduler(level).dispatch_round()
	evidence["funding_now"] = false
	var paid_delta: int = 0
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		var delta: int = _payments(worker) - int(before.get(worker.get_instance_id(), 0))
		_check(delta >= 0 and delta <= 1,
			"A construction group can pay for at most one original packet in a scheduler round")
		paid_delta += delta
	_check(dispatched == paid_delta and balance - level.mother_core.nutrition == paid_delta,
		"Scheduler reports original successful dispatches and cannot debit, refund or hide an extra payment")
	evidence["dispatch_rounds"] = int(evidence["dispatch_rounds"]) + 1
	return dispatched


func _tick(level: Node2D, evidence: Dictionary, feed: bool = true, controls: Dictionary = {}) -> void:
	_coordinator(level).pump()
	_sync_workers(level, evidence)
	if feed:
		_fund_round(level, evidence)
	level.traffic_system.refresh()
	for path: String in PACKET_PATHS:
		for child: Node in level.get_node(path).get_children():
			if child.is_queued_for_deletion() or not (child is NutrientPacket or child is RemainsPacket):
				continue
			var packet: Node2D = child as Node2D
			var record: Dictionary = (evidence["packets"] as Dictionary).get(packet.get_instance_id(), {})
			var before: Vector2 = packet.global_position
			var edge_before: HyphaEdge = packet.get("edge") as HyphaEdge
			# 先记录移动尝试，真实 arrived 会在原 _physics_process 内同步发出。
			if not record.is_empty() and packet.get("speed") != null:
				var transport: Dictionary = packet.call("get_transport_snapshot")
				if transport.get("state") == &"moving" and is_instance_valid(edge_before):
					record["movements"] = int(record["movements"]) + 1
					if not (record["edges"] as Array).has(edge_before.get_instance_id()):
						(record["edges"] as Array).append(edge_before.get_instance_id())
			packet.call("_physics_process", STEP)
			if is_instance_valid(packet) and not record.is_empty() and not packet.global_position.is_equal_approx(before):
				record["actual_displacement"] = float(record.get("actual_displacement", 0.0)) + packet.global_position.distance_to(before)
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		if not bool(controls.get("hold_growth", false)):
			worker.growth_system.advance(STEP)
		var request: Dictionary = worker.get_snapshot()
		var construction_id: String = String(request.get("construction_id", ""))
		var task: Dictionary = worker.cultivation_system.get_task_snapshot()
		var cultivation_step: float = STEP
		var ceilings: Dictionary = controls.get("cultivation_ceilings", {})
		if ceilings.has(construction_id):
			cultivation_step = minf(STEP, maxf(0.0, float(ceilings[construction_id]) - float(task.get("effective_time", 0.0))))
		if cultivation_step > 0.0:
			worker.cultivation_system.advance(cultivation_step)
		worker.growth_supply_system.call("_process", 0.0)
		worker.cultivation_supply_system.call("_process", 0.0)
	_repair(level).advance(STEP)
	_repair_supply(level).refresh_budget()
	level.call("_process", 0.0)
	level.fungal_field.advance(STEP)
	await physics_frame
	await process_frame
	_coordinator(level).pump()
	_sync_workers(level, evidence)
	level.call("_process", 0.0)


func _until(level: Node2D, evidence: Dictionary, phase: String, condition: Callable,
		feed: bool = true, controls: Dictionary = {}) -> bool:
	for step_index: int in range(STEP_LIMIT):
		if bool(condition.call()):
			break
		await _tick(level, evidence, feed, controls)
		if step_index % 40 == 0:
			_checkpoint(level, evidence, phase + "_in_progress")
	var reached: bool = bool(condition.call())
	_check(reached, "%s reaches %s with actual original motion before the bounded step limit" % [evidence["label"], phase])
	_checkpoint(level, evidence, phase, true)
	return reached


func _admit(level: Node2D, kind: StringName, parameters: Dictionary) -> String:
	var result: Dictionary = _coordinator(level).enqueue(kind, parameters)
	var construction_id: String = String(result.get("construction_id", ""))
	_check(bool(result.get("accepted", false)) and not construction_id.is_empty(),
		"Original %s admission has one stable construction identity" % kind)
	return construction_id


func _admit_local(level: Node2D, host: HyphaNode) -> String:
	var result: Dictionary = _coordinator(level).enqueue_local_cultivation(host)
	var construction_id: String = String(result.get("construction_id", ""))
	_check(bool(result.get("accepted", false)) and not construction_id.is_empty(),
		"A real empty host admits one original local cultivation identity")
	return construction_id


func _worker(level: Node2D, construction_id: String) -> ConstructionWorker:
	return _coordinator(level).get_worker(construction_id)


func _growth(level: Node2D, construction_id: String) -> Dictionary:
	var worker: ConstructionWorker = _worker(level, construction_id)
	return {} if worker == null else worker.growth_system.get_task_snapshot()


func _cultivation(level: Node2D, construction_id: String) -> Dictionary:
	var worker: ConstructionWorker = _worker(level, construction_id)
	var request: Dictionary = _queue(level).get_request(construction_id)
	var task_id: int = int(request.get("internal_ids", {}).get("cultivation_task_id", 0))
	return {} if worker == null else worker.cultivation_system.get_task_snapshot(task_id)


func _identity(request: Dictionary) -> Dictionary:
	return {"construction_id": request.get("construction_id", ""), "sequence": request.get("sequence", 0),
		"kind": request.get("kind", &""), "parameters": request.get("parameters", {}).duplicate(true),
		"payer": request.get("payer"), "payer_id": request.get("payer_id", 0),
		"worker_id": request.get("worker_id", 0), "internal_ids": request.get("internal_ids", {}).duplicate(true)}


func _check_worker_wiring(level: Node2D, construction_id: String) -> void:
	var worker: ConstructionWorker = _worker(level, construction_id)
	_check(worker != null, "Every physically started construction owns a real worker")
	if worker == null:
		return
	_check(worker.scene_file_path == WORKER_SCENE_PATH and worker.get_parent() == _coordinator(level).worker_container,
		"Worker is the actual ConstructionWorker scene under the formal parent container")
	for node_name: String in MODULES:
		var module: Node = worker.get(String(MODULES[node_name])) as Node
		_check(module == worker.get_node(node_name) and module.get_script().resource_path == ORIGINAL_SCRIPTS[node_name],
			"Worker composes the original " + node_name + " script without a copied executor")
	_check(worker.growth_system != level.growth_system and worker.cultivation_system != level.cultivation_system
		and worker.growth_supply_system != level.growth_supply_system
		and worker.cultivation_supply_system != level.cultivation_supply_system,
		"Formal mutable executors and payment lots belong to the worker instance")
	_check(worker.growth_system.network_system == level.network_system
		and worker.growth_system.traffic_system == level.traffic_system
		and worker.growth_system.node_container == level.get_node("World/Colony/Nodes")
		and worker.growth_system.edge_container == level.get_node("World/Colony/Connections")
		and worker.growth_system.tip_container == level.get_node("World/GrowthTips"),
		"Real worker grows into the original shared map and traffic infrastructure")
	var request: Dictionary = _queue(level).get_request(construction_id)
	var settled_terminal: bool = request.get("phase") == &"terminal" and worker.is_settled()
	var terminal_resources: Dictionary = worker.get_resource_snapshot().duplicate(true)
	var terminal_payments: int = _payments(worker)
	var terminal_growth: Dictionary = worker.growth_system.get_task_snapshot().duplicate(true)
	var terminal_cultivation: Dictionary = worker.cultivation_system.get_task_snapshot().duplicate(true)
	var terminal_request: Dictionary = request.duplicate(true)
	for supply: Node in [worker.growth_supply_system, worker.cultivation_supply_system]:
		_check(supply.get("mother_core") == level.mother_core and supply.get("network_system") == level.network_system
			and supply.get("traffic_system") == level.traffic_system and bool(supply.get("traffic_required"))
			and supply.get("combat_supply_system") == level.supply_system,
			"Worker's original supply keeps its real payer, combat reserve and shared FIFO")
		if settled_terminal:
			_check(supply.call("get_dispatch_owner") == null
				and not bool(supply.call("can_dispatch_scheduled", _scheduler(level)))
				and not bool(supply.call("try_dispatch_scheduled", _scheduler(level)))
				and not bool(supply.call("try_dispatch")),
				"Settled terminal supply releases scheduler ownership and refuses every original dispatch path")
			supply.call("_process", 1000.0)
		else:
			_check(supply.call("get_dispatch_owner") == _scheduler(level),
				"Active or still-settling original supply retains exclusive scheduler ownership")
	if settled_terminal:
		_check(not worker.growth_system.has_active_task() and not worker.cultivation_system.has_active_task()
			and worker.get_resource_snapshot() == terminal_resources and _payments(worker) == terminal_payments
			and worker.growth_system.get_task_snapshot() == terminal_growth
			and worker.cultivation_system.get_task_snapshot() == terminal_cultivation
			and _queue(level).get_request(construction_id) == terminal_request,
			"Retained terminal modules expose unchanged original task/ledger/history without paying another packet")
	for other: ConstructionWorker in _coordinator(level).get_workers(true):
		if other != worker:
			_check(other.growth_system != worker.growth_system and other.cultivation_system != worker.cultivation_system
				and other.growth_supply_system != worker.growth_supply_system
				and other.cultivation_supply_system != worker.cultivation_supply_system,
				"Concurrent workers never share original executor state or nutrition lots")


func _empty_hosts(level: Node2D, count: int) -> Array[HyphaNode]:
	var hosts: Array[HyphaNode] = []
	for child: Node in level.get_node("World/Colony/Nodes").get_children():
		if child is HyphaNode and not child.is_queued_for_deletion():
			var host: HyphaNode = child as HyphaNode
			if _is_paid_empty_host(level, host):
				hosts.append(host)
				if hosts.size() >= count:
					break
	_check(hosts.size() == count, "Paid actual growth leaves enough connected mature empty hosts for local cultivation")
	return hosts


func _is_paid_empty_host(level: Node2D, host: HyphaNode) -> bool:
	return host != _left(level) and host != _right(level) \
		and host != level.get_node("World/Colony/Nodes/RearNode") \
		and host.is_organ_slot_available() and level.network_system.find_route(level.mother_core, host).found


func _has_paid_empty_host(level: Node2D) -> bool:
	var found: bool = false
	for child: Node in level.get_node("World/Colony/Nodes").get_children():
		if child is HyphaNode and not child.is_queued_for_deletion() and _is_paid_empty_host(level, child as HyphaNode):
			found = true
			break
	return found


func _recover_batch(level: Node2D, evidence: Dictionary, batch_index: int) -> bool:
	var before_total: int = level.colony_progress.get_total_recovered()
	var before_stage: ColonyProgress.Stage = level.colony_progress.get_stage()
	var before_balance: int = level.mother_core.nutrition
	_check(level.recycling_system.try_dispatch(), "Original recycling dispatches actual corpse batch %d" % batch_index)
	if not await _until(level, evidence, "corpse_%d_real_digestion_output" % batch_index, func() -> bool:
		return level.digestive_organ.get_output_count() == 1, false):
		return false
	_check(level.colony_progress.get_total_recovered() == before_total and level.colony_progress.get_stage() == before_stage
		and level.mother_core.nutrition == before_balance,
		"Purple collection and the original DigestTimer cannot unlock a tip before green core arrival")
	var product: Dictionary = level.digestive_organ.get_output_products()[0]
	_check(int(product["nutrition"]) == 10, "Real digestion preserves the original ten-unit batch")
	_check(level.nutrition_return_system.try_dispatch(), "Original return dispatch pays no new resource and moves the actual product")
	_check(level.colony_progress.get_total_recovered() == before_total and level.mother_core.nutrition == before_balance,
		"Creating the actual green packet cannot pre-credit the stage or balance")
	if not await _until(level, evidence, "corpse_%d_actual_unique_core_receipt" % batch_index, func() -> bool:
		return level.colony_progress.get_total_recovered() == before_total + 10, false):
		return false
	_check(level.mother_core.nutrition == before_balance + 10
		and level.mother_core.get_received_product_count() == batch_index
		and level.colony_progress.get_product_count() == batch_index
		and (evidence["receipts"] as Dictionary).has(product["product_id"]),
		"Real return credits exactly its unique product and ten recovered units once")
	return true


func _summary(level: Node2D, evidence: Dictionary, case_name: String, details: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = {"case": case_name, "resources": _resources(level, evidence),
		"worker_instances_seen": (evidence["worker_records"] as Dictionary).size(),
		"physical_arrivals": 0, "moving_packets": 0, "packet_count": (evidence["packets"] as Dictionary).size(),
		"dispatch_rounds": evidence["dispatch_rounds"], "callback_replays": evidence["callback_replays"],
		"real_core_receipts": (evidence["receipts"] as Dictionary).size(),
		"fixture_escrow_transfers": evidence["fixture_escrow_transfers"]}
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		summary["physical_arrivals"] = int(summary["physical_arrivals"]) + int(record["arrivals"])
		if float(record.get("actual_displacement", 0.0)) > 0.0:
			summary["moving_packets"] = int(summary["moving_packets"]) + 1
	summary.merge(details)
	return summary


func _dispose(level: Node2D, evidence: Dictionary) -> void:
	if not evidence.is_empty():
		evidence["active"] = false
	if is_instance_valid(level):
		if _coordinator(level) != null:
			_coordinator(level).reset()
		if current_scene == level:
			current_scene = null
		level.queue_free()
	await process_frame
	await process_frame


func _test_formal_multitip_cycle() -> void:
	var level: Node2D = await _new_level()
	if not _check_wiring(level):
		await _dispose(level, {})
		return
	var sources: Array[LargeCarcass] = _add_carcass_fixtures(level, 2)
	var evidence: Dictionary = _observe(level, "continuous_formal_multitip_run")
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	_check(level.colony_progress.get_total_recovered() == 0
		and level.colony_capabilities.get_extension_tip_limit() == 1
		and int(coordinator.get_snapshot()["tip_limit"]) == 1,
		"Actual initial stage allows one extension tip before any recovered receipt")
	var left_id: String = _admit(level, &"remote_cultivation", {"start_node": _left(level), "target_position": LEFT_REMOTE})
	var right_id: String = _admit(level, &"remote_cultivation", {"start_node": _right(level), "target_position": RIGHT_REMOTE})
	var third_id: String = _admit(level, &"growth", {"start_node": _left(level), "target_position": THIRD_TARGET})
	coordinator.pump()
	_sync_workers(level, evidence)
	var left_worker: ConstructionWorker = _worker(level, left_id)
	if left_worker == null:
		_check(false, "First admitted external request must allocate its actual worker")
		await _dispose(level, evidence)
		return
	_check_worker_wiring(level, left_id)
	var initial: Dictionary = coordinator.get_snapshot()
	_check(int(initial["external_count"]) == 3 and int(initial["tip_count"]) == 1
		and queue.get_request(left_id).get("started", false)
		and not queue.get_request(right_id).get("started", true)
		and not queue.get_request(third_id).get("started", true),
		"One actual started worker leaves the second and third external goals waiting under cap three")
	var fourth: Dictionary = coordinator.enqueue(&"growth", {"start_node": _right(level), "target_position": Vector2(980, 560)})
	_check(not bool(fourth.get("accepted", true)) and fourth.get("reason") == &"queue_full"
		and String(fourth.get("construction_id", "bad")).is_empty(),
		"A fourth external request is rejected without allocating a worker or changing payer")
	_check(_fund_round(level, evidence) == 1 and left_worker.growth_supply_system.get_in_transit_count() == 1,
		"Initial scheduler round creates exactly one paid original packet for the single real tip")
	_check(coordinator.select_request(left_id) and coordinator.pause_request(left_id),
		"Selected active extension can pause with its already paid physical packet")
	if not await _until(level, evidence, "first_real_packet_buffers_while_paused", func() -> bool:
		return left_worker.growth_supply_system.get_in_transit_count() == 0, false):
		await _dispose(level, evidence)
		return
	var preserved: Dictionary = _identity(queue.get_request(left_id))
	var paused_growth: Dictionary = _growth(level, left_id).duplicate(true)
	_check(int(paused_growth.get("buffered_nutrition", -1)) == 1
		and is_zero_approx(float(paused_growth.get("distance", -1.0)))
		and queue.get_request(left_id).get("occupies_tip_slot", false)
		and int(coordinator.get_snapshot()["tip_count"]) == 1,
		"A paused actual extension retains its tip and paid buffer without growing")
	for batch_index: int in range(1, 7):
		if not await _recover_batch(level, evidence, batch_index):
			await _dispose(level, evidence)
			return
		_check(_worker(level, left_id) == left_worker and _identity(queue.get_request(left_id)) == preserved
			and _growth(level, left_id) == paused_growth,
			"Real recovery preserves the old worker, original IDs, payer, paused tip and paid cache")
		if batch_index < 6:
			_check(int(coordinator.get_snapshot()["tip_limit"]) == 1
				and not queue.get_request(right_id).get("started", true),
				"Below sixty actual recovered units a second worker cannot start")
	_check(level.colony_progress.get_total_recovered() == 60
		and level.colony_progress.get_stage() == ColonyProgress.Stage.EXPANDED
		and int(coordinator.get_snapshot()["tip_limit"]) == 2
		and int(coordinator.get_snapshot()["tip_count"]) == 2
		and queue.get_request(right_id).get("started", false)
		and not queue.get_request(third_id).get("started", true)
		and coordinator.get_snapshot()["selected_id"] == left_id,
		"Six genuine green arrivals unlock one new tip beside the unchanged selected paused original")
	var right_worker: ConstructionWorker = _worker(level, right_id)
	if right_worker == null:
		_check(false, "Real sixty-unit unlock must allocate the second independent worker")
		await _dispose(level, evidence)
		return
	_check_worker_wiring(level, right_id)
	_check(left_worker != right_worker
		and queue.get_request(left_id)["worker_id"] != queue.get_request(right_id)["worker_id"],
		"Original and newly unlocked construction have distinct permanent worker identities")
	_check(coordinator.pause_request(third_id) and not queue.get_request(third_id).get("occupies_tip_slot", true)
		and queue.get_request(third_id).get("occupies_external_slot", false)
		and int(coordinator.get_snapshot()["external_count"]) == 3,
		"A paused waiting third goal keeps its admission slot while using no tip")
	_check(coordinator.resume_request(third_id) and coordinator.resume_request(left_id),
		"Both captured waiting and paused active goals resume through their own identities")
	var ceilings: Dictionary = {left_id: 0.5, right_id: 0.5}
	var controls: Dictionary = {"cultivation_ceilings": ceilings}
	if not await _until(level, evidence, "two_actual_directions_advance", func() -> bool:
		return float(_growth(level, left_id).get("distance", 0.0)) > 0.0 \
			and float(_growth(level, right_id).get("distance", 0.0)) > 0.0, true, controls):
		await _dispose(level, evidence)
		return
	for construction_id: String in [left_id, right_id]:
		var worker: ConstructionWorker = _worker(level, construction_id)
		var growth: Dictionary = _growth(level, construction_id)
		var tip: Node2D = worker.growth_system.get_delivery_target(int(growth["task_id"]))
		var origin: HyphaNode = queue.get_request(construction_id)["parameters"]["start_node"] as HyphaNode
		_check(tip is GrowthTip and tip.global_position.distance_to(origin.global_position) > 0.0
			and int(growth.get("consumed_nutrition", 0)) > 0 and _payments(worker) > 0,
			"Each direction moves its own original GrowthTip using physically arrived nutrition")
	_check(coordinator.pause_request(right_id), "Second moving extension pauses without releasing its occupied tip")
	if not await _until(level, evidence, "left_actual_committed_remote_handoff", func() -> bool:
		return queue.get_request(left_id).get("phase") == &"maturing" \
			and queue.get_request(third_id).get("started", false), true, controls):
		await _dispose(level, evidence)
		return
	var handoff: Dictionary = queue.get_request(left_id)
	var left_growth_id: int = int(handoff["internal_ids"]["growth_task_id"])
	var left_cultivation_id: int = int(handoff["internal_ids"]["cultivation_task_id"])
	var left_remote: Dictionary = left_worker.remote_cultivation_system.get_request_snapshot()
	var left_host: HyphaNode = left_remote.get("endpoint") as HyphaNode
	_check(is_instance_valid(left_host) and left_host == left_worker.growth_system.get_completed_endpoint(left_growth_id)
		and left_host.global_position.distance_to(LEFT_REMOTE) < 0.05
		and left_remote.get("extension_released", false)
		and int(left_remote.get("cultivation_task_id", 0)) == left_cultivation_id
		and left_worker.cultivation_system.has_active_task()
		and not left_host.is_organ_slot_available(),
		"B handoff is the real committed growth endpoint and actual accepted original bud/task")
	_check(left_worker.growth_system.get_task_snapshot().get("state") == &"completed"
		and left_worker.growth_supply_system.get_in_transit_count() == 0
		and int(left_worker.growth_system.get_task_snapshot().get("buffered_nutrition", -1)) == 0
		and not handoff.get("occupies_tip_slot", true) and not handoff.get("occupies_external_slot", true)
		and int(coordinator.get_snapshot()["tip_count"]) == 2
		and int(coordinator.get_snapshot()["external_count"]) == 2
		and int(coordinator.get_snapshot()["maturing_count"]) == 1
		and queue.get_request(right_id).get("state") == &"paused",
		"Only settled original growth and accepted cultivation release B's two slots; third goal starts alongside paused second tip")
	_check(_worker(level, left_id) == left_worker and int(evidence["handoffs"].get(left_id, 0)) == 1,
		"Real handoff preserves its worker and signals once for the original construction")
	_check_worker_wiring(level, third_id)
	_check(coordinator.resume_request(right_id), "Paused second extension resumes its original growth task")
	var overlap: Dictionary = {"observed": false}
	if not await _until(level, evidence, "two_distinct_real_mature_tasks_and_growth_overlap", func() -> bool:
		if queue.get_request(third_id).get("phase") == &"extension" \
				and float(_growth(level, third_id).get("distance", 0.0)) > 0.0 \
				and float(_cultivation(level, left_id).get("effective_time", 0.0)) > 0.0:
			overlap["observed"] = true
		return queue.get_request(right_id).get("phase") == &"maturing" \
			and bool(overlap["observed"]), true, controls):
		await _dispose(level, evidence)
		return
	var right_host: HyphaNode = right_worker.remote_cultivation_system.get_request_snapshot().get("endpoint") as HyphaNode
	_check(is_instance_valid(right_host) and right_host != left_host
		and right_host.global_position.distance_to(RIGHT_REMOTE) < 0.05
		and left_worker.cultivation_system != right_worker.cultivation_system
		and left_worker.cultivation_supply_system != right_worker.cultivation_supply_system
		and int(coordinator.get_snapshot()["maturing_count"]) == 2
		and int(evidence["handoffs"].get(right_id, 0)) == 1,
		"Two real B tasks mature on distinct actual hosts with distinct original cultivation ledgers")
	_check(coordinator.select_request(left_id) and coordinator.pause_request(left_id)
		and queue.get_request(left_id).get("phase") == &"maturing"
		and queue.get_request(left_id).get("state") == &"paused"
		and not queue.get_request(left_id).get("occupies_tip_slot", true)
		and not queue.get_request(left_id).get("occupies_external_slot", true)
		and coordinator.resume_request(left_id),
		"Selection and pause/resume remain attached to a mature B without reacquiring an extension slot")
	if not await _until(level, evidence, "third_goal_commits_its_original_paid_empty_endpoint", func() -> bool:
		return queue.get_request(third_id).get("state") == &"completed", true, controls):
		await _dispose(level, evidence)
		return
	var third_worker: ConstructionWorker = _worker(level, third_id)
	var third_task_id: int = int(queue.get_request(third_id)["internal_ids"]["growth_task_id"])
	var local_host: HyphaNode = third_worker.growth_system.get_completed_endpoint(third_task_id)
	if local_host == null:
		_check(false, "Original third growth must commit its actual endpoint before local C")
		await _dispose(level, evidence)
		return
	var slots_before: Dictionary = coordinator.get_snapshot()
	var local_id: String = _admit_local(level, local_host)
	coordinator.pump()
	_sync_workers(level, evidence)
	_check_worker_wiring(level, local_id)
	var local_request: Dictionary = queue.get_request(local_id)
	var duplicate: Dictionary = coordinator.enqueue_local_cultivation(local_host)
	var selection: Dictionary = coordinator.get_cultivation_selection(local_host)
	_check(local_request.get("kind") == &"cultivation" and local_request.get("phase") == &"maturing"
		and not local_request.get("occupies_tip_slot", true) and not local_request.get("occupies_external_slot", true)
		and int(coordinator.get_snapshot()["tip_count"]) == int(slots_before["tip_count"])
		and int(coordinator.get_snapshot()["external_count"]) == int(slots_before["external_count"]),
		"Original local C is a mature task and consumes no external or tip slot")
	_check(not bool(duplicate.get("accepted", true)) and not String(duplicate.get("reason", "")).is_empty()
		and coordinator.get_cultivation_selection(local_host).get("construction_id") == local_id,
		"A simultaneous claim on the same real host is explicitly rejected without another task/bud")
	for field: String in ["host", "reason", "message", "can_cultivate", "can_continue", "can_pause",
			"can_resume", "can_cancel", "task", "total_cost", "remaining_cost", "available_nutrition", "construction_id"]:
		_check(selection.has(field), "Local cultivation selection preserves the original public field " + field)
	if not await _until(level, evidence, "both_B_and_local_C_pay_eight_plus_four_and_mature", func() -> bool:
		return queue.get_request(left_id).get("state") == &"completed" \
			and queue.get_request(right_id).get("state") == &"completed" \
			and queue.get_request(local_id).get("state") == &"completed"):
		await _dispose(level, evidence)
		return
	_check((evidence["matured"] as Array).size() == 3
		and int(_cultivation(level, left_id).get("startup_transferred", -1)) == 4
		and int(_cultivation(level, right_id).get("startup_transferred", -1)) == 4
		and int(_cultivation(level, local_id).get("startup_transferred", -1)) == 4
		and coordinator.get_snapshot()["selected_id"] == ""
		and coordinator.get_active_requests().is_empty(),
		"All three original maturations settle independently and terminal selection clears without choosing another task")
	var connection_id: String = _admit(level, &"connection", {"first_node": _left(level), "second_node": _right(level)})
	if not await _until(level, evidence, "original_L_constructs_actual_shared_corridor", func() -> bool:
		return queue.get_request(connection_id).get("state") == &"completed"):
		await _dispose(level, evidence)
		return
	_check_worker_wiring(level, connection_id)
	_check(level.network_system.has_direct_connection(_left(level), _right(level)),
		"Formal L creates its genuine paid corridor using another original per-worker growth module")
	for batch_index: int in range(7, 17):
		if not await _recover_batch(level, evidence, batch_index):
			await _dispose(level, evidence)
			return
	_check(level.colony_progress.get_total_recovered() == 160
		and level.colony_progress.get_stage() == ColonyProgress.Stage.MATURE
		and level.colony_capabilities.get_extension_tip_limit() == 2
		and int(coordinator.get_snapshot()["tip_limit"]) == 2
		and sources[0].get_remaining_nutrition() == 0 and sources[1].get_remaining_nutrition() == 0,
		"Sixteen actual original returns reach mature stage while retaining the two-tip hard limit")
	_checkpoint(level, evidence, "real_0_60_160_and_three_original_maturations", true)
	cases.append(_summary(level, evidence, "real_stage_unlock_and_remote_handoff", {
		"initial_tip_limit": 1, "sixty_tip_limit": 2, "mature_tip_limit": 2,
		"construction_ids": [left_id, right_id, third_id, local_id, connection_id],
		"matured": evidence["matured"].duplicate(true), "actual_growth_maturation_overlap": overlap["observed"]}))
	if not await _test_cancel_isolation(level, evidence):
		await _dispose(level, evidence)
		return
	if not await _test_paid_bud_continuation(level, evidence):
		await _dispose(level, evidence)
		return
	if not await _test_shared_budget_and_dispatch_ownership(level, evidence):
		await _dispose(level, evidence)
		return
	if not await _test_same_scene_reset(level, evidence):
		await _dispose(level, evidence)
		return
	var fresh: Node2D = await _test_actual_restart(level, evidence)
	if not is_instance_valid(fresh):
		if is_instance_valid(level):
			await _dispose(level, evidence)
		return
	await _test_actual_death(fresh)


func _replay_settled(level: Node2D, evidence: Dictionary, record: Dictionary) -> void:
	var candidate: Variant = record["packet"]
	if not is_instance_valid(candidate) or int(record["arrivals"]) + int(record["interruptions"]) != 1:
		return
	var packet: Node2D = candidate as Node2D
	var before: Dictionary = _resources(level, evidence)
	var history: Array[Dictionary] = _coordinator(level).get_all_requests().duplicate(true)
	# 仅在原物理 arrived/interrupted 已发生后重放结算回调，绝不制造首次到货。
	for key: String in ["arrived_callbacks", "interrupted_callbacks"]:
		for callback: Callable in record[key]:
			if callback.is_valid():
				callback.call(packet)
				callback.call(packet)
				evidence["callback_replays"] = int(evidence["callback_replays"]) + 2
	_check(_resources(level, evidence) == before and _coordinator(level).get_all_requests() == history,
		"Duplicate actually settled callbacks cannot repeat income, refund, structure or terminal history")


func _test_cancel_isolation(level: Node2D, evidence: Dictionary) -> bool:
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var cancelled_id: String = _admit(level, &"growth", {"start_node": _left(level), "target_position": Vector2(180, 500)})
	var survivor_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1020, 650)})
	if not await _until(level, evidence, "two_original_growths_own_real_spending_and_transit", func() -> bool:
		return int(_growth(level, cancelled_id).get("consumed_nutrition", 0)) > 0 \
			and float(_growth(level, survivor_id).get("distance", 0.0)) > 0.0 \
			and _worker(level, cancelled_id).growth_supply_system.get_in_transit_count() > 0):
		return false
	var cancelled_worker: ConstructionWorker = _worker(level, cancelled_id)
	var survivor_worker: ConstructionWorker = _worker(level, survivor_id)
	var survivor_identity: Dictionary = _identity(queue.get_request(survivor_id))
	var survivor_task: Dictionary = _growth(level, survivor_id).duplicate(true)
	var survivor_shipments: Array[Dictionary] = survivor_worker.growth_supply_system.get_shipment_records().duplicate(true)
	var survivor_resources: Dictionary = survivor_worker.get_resource_snapshot().duplicate(true)
	var cancelled_task: Dictionary = _growth(level, cancelled_id)
	var refundable: int = int(cancelled_task.get("buffered_nutrition", 0))
	for shipment: Dictionary in cancelled_worker.growth_supply_system.get_shipment_records():
		if bool(shipment.get("debited", false)) and not bool(shipment.get("settled", false)) \
				and not bool(shipment.get("refunded", false)):
			refundable += GrowthSupplySystem.PACKET_NUTRITION
	var before_balance: int = level.mother_core.nutrition
	var before_progress: int = level.colony_progress.get_total_recovered()
	_check(coordinator.cancel_request(cancelled_id), "Cancellation addresses the exact original worker instead of legacy active_id")
	var cancelled: Dictionary = queue.get_request(cancelled_id).duplicate(true)
	_check(cancelled.get("state") == &"cancelled" and cancelled.get("phase") == &"terminal"
		and not cancelled.get("occupies_tip_slot", true) and not cancelled.get("occupies_external_slot", true)
		and level.mother_core.nutrition == before_balance + refundable
		and level.colony_progress.get_total_recovered() == before_progress
		and cancelled_worker.is_settled(),
		"Original cancellation refunds only its real unused lots and preserves all previously paid network investment")
	_check(_worker(level, survivor_id) == survivor_worker and _identity(queue.get_request(survivor_id)) == survivor_identity
		and _growth(level, survivor_id) == survivor_task
		and survivor_worker.get_resource_snapshot() == survivor_resources
		and survivor_worker.growth_supply_system.get_shipment_records() == survivor_shipments,
		"Cancelling one worker preserves the other's IDs, exact payments, buffers, physical progress and ledger")
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		if record["owner"] == cancelled_worker.growth_supply_system:
			_replay_settled(level, evidence, record)
	if not await _until(level, evidence, "surviving_original_worker_completes_its_own_goal", func() -> bool:
		return queue.get_request(survivor_id).get("state") == &"completed"):
		return false
	_check(queue.get_request(cancelled_id) == cancelled
		and int(_growth(level, survivor_id).get("task_id", 0)) == int(survivor_task["task_id"])
		and float(_growth(level, survivor_id).get("distance", 0.0)) > float(survivor_task["distance"]),
		"The survivor advances and completes while the cancelled terminal snapshot stays frozen")
	_checkpoint(level, evidence, "one_cancelled_other_completed_without_ledger_crossing", true)
	cases.append(_summary(level, evidence, "cancel_one_preserve_another", {
		"cancelled": cancelled_id, "survivor": survivor_id, "actual_refund": refundable}))
	return true


func _test_paid_bud_continuation(level: Node2D, evidence: Dictionary) -> bool:
	var hosts: Array[HyphaNode] = _empty_hosts(level, 2)
	if hosts.size() != 2:
		return false
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var first_id: String = _admit_local(level, hosts[0])
	var second_id: String = _admit_local(level, hosts[1])
	coordinator.pump()
	_sync_workers(level, evidence)
	var first: ConstructionWorker = _worker(level, first_id)
	var second: ConstructionWorker = _worker(level, second_id)
	if first == null or second == null:
		_check(false, "Both original local buds must own independent workers")
		return false
	var controls: Dictionary = {"cultivation_ceilings": {first_id: 0.0, second_id: 0.0}}
	# 九轮原派送；只控制调用 advance 的时刻，不改需求、付款、库存或成熟参数。
	for _round_index: int in range(9):
		_check(_fund_round(level, evidence) == 2, "Each of the two real local groups receives one original packet in each funded round")
	if not await _until(level, evidence, "both_original_local_ledgers_hold_nine_real_arrivals", func() -> bool:
		return first.cultivation_supply_system.get_in_transit_count() == 0 \
			and second.cultivation_supply_system.get_in_transit_count() == 0, false, controls):
		return false
	_check(int(_cultivation(level, first_id).get("buffered_nutrition", -1)) == 9
		and int(_cultivation(level, second_id).get("buffered_nutrition", -1)) == 9,
		"Independent local cultivation owns nine physically delivered paid units per host")
	first.cultivation_system.advance(3.1)
	second.cultivation_system.advance(0.5)
	var paid_bud: Dictionary = _cultivation(level, first_id)
	_check(int(paid_bud.get("structure_consumed", -1)) == 8
		and int(paid_bud.get("startup_reserved", -1)) == 1
		and int(paid_bud.get("startup_transferred", -1)) == 0
		and not hosts[0].is_organ_slot_available(),
		"Original first bud has real eight-unit structure and one refundable startup unit before maturity")
	_check(_fund_round(level, evidence) == 2 and first.cultivation_supply_system.get_in_transit_nutrition() == 1,
		"One additional real packet is paid to each independent local group before cancellation")
	_check(coordinator.pause_request(first_id), "Paid startup task pauses by its selected construction identity")
	var second_identity: Dictionary = _identity(queue.get_request(second_id))
	var second_task: Dictionary = _cultivation(level, second_id).duplicate(true)
	var second_resources: Dictionary = second.get_resource_snapshot().duplicate(true)
	var second_shipments: Array[Dictionary] = second.cultivation_supply_system.get_shipment_records().duplicate(true)
	var before_balance: int = level.mother_core.nutrition
	var organ_structure: int = int(coordinator.get_resource_snapshot()["organ_structure"])
	_check(coordinator.cancel_request(first_id), "Original local cancellation retains its paid real bud")
	var frozen_terminal: Dictionary = queue.get_request(first_id).duplicate(true)
	_check(level.mother_core.nutrition == before_balance + 2 and first.is_settled()
		and int(_cultivation(level, first_id).get("structure_consumed", -1)) == 8
		and int(_cultivation(level, first_id).get("startup_reserved", -1)) == 0
		and int(_cultivation(level, first_id).get("buffered_nutrition", -1)) == 0
		and int(coordinator.get_resource_snapshot()["organ_structure"]) == organ_structure,
		"Cancelling the first paid bud refunds exactly its one reserved startup and one actual transit, never eight structure")
	_check(_identity(queue.get_request(second_id)) == second_identity
		and _cultivation(level, second_id) == second_task and second.get_resource_snapshot() == second_resources
		and second.cultivation_supply_system.get_shipment_records() == second_shipments,
		"The other real mature task retains its original IDs, paid lots and effective time across cancellation")
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		if record["owner"] == first.cultivation_supply_system:
			_replay_settled(level, evidence, record)
	await process_frame
	await process_frame
	coordinator.pump()
	_check(coordinator.get_cultivation_selection(hosts[0]).get("can_continue", false),
		"Original host selection exposes the paid retained bud as a genuine continuation")
	var continuation_id: String = _admit_local(level, hosts[0])
	coordinator.pump()
	_sync_workers(level, evidence)
	var continuation: ConstructionWorker = _worker(level, continuation_id)
	if continuation == null:
		_check(false, "Paid retained bud continuation must own an original live worker")
		return false
	_check(continuation_id != first_id
		and int(_cultivation(level, continuation_id).get("task_id", 0)) != int(paid_bud["task_id"])
		and int(_cultivation(level, continuation_id).get("structure_consumed", -1)) == 8
		and int(coordinator.get_resource_snapshot()["organ_structure"]) == organ_structure
		and queue.get_request(first_id) == frozen_terminal,
		"Continuation has a new construction/task while retaining its actual eight paid structure and old immutable history")
	if continuation == first:
		_check(coordinator.get_worker(first_id) == null
			and continuation.cultivation_system == first.cultivation_system,
			"A reused original worker is no longer exposed under its old terminal construction ID")
	if not await _until(level, evidence, "retained_bud_and_other_original_task_complete", func() -> bool:
		return queue.get_request(continuation_id).get("state") == &"completed" \
			and queue.get_request(second_id).get("state") == &"completed"):
		return false
	_check(queue.get_request(first_id) == frozen_terminal
		and int(coordinator.get_resource_snapshot()["organ_structure"]) == organ_structure + 8 - int(second_task.get("structure_consumed", 0)),
		"Completing continued and independent buds adds only the other's unpaid structure, with no repeated continuation baseline")
	_checkpoint(level, evidence, "retained_bud_continues_without_double_counting", true)
	cases.append(_summary(level, evidence, "paid_bud_continuation_and_mature_isolation", {
		"cancelled": first_id, "continuation": continuation_id, "other": second_id,
		"actual_startup_refund": 2, "retained_structure": 8}))
	return true


func _move_to_fixture_escrow(level: Node2D, evidence: Dictionary, target_balance: int) -> void:
	var transfer: int = level.mother_core.nutrition - target_balance
	_check(transfer >= 0 and level.mother_core.try_spend_nutrition(transfer),
		"Explicit low-balance fixture moves only spendable original core funds into conserved escrow")
	if transfer >= 0 and level.mother_core.nutrition == target_balance:
		evidence["escrow"] = int(evidence["escrow"]) + transfer
		evidence["fixture_escrow_transfers"] = int(evidence["fixture_escrow_transfers"]) + 1


func _release_fixture_escrow(level: Node2D, evidence: Dictionary, amount: int) -> void:
	_check(amount > 0 and int(evidence["escrow"]) >= amount,
		"Fixture replenishment owns previously withdrawn funds and adds no recovered receipt")
	if amount <= 0 or int(evidence["escrow"]) < amount:
		return
	evidence["escrow"] = int(evidence["escrow"]) - amount
	evidence["fixture_escrow_transfers"] = int(evidence["fixture_escrow_transfers"]) + 1
	level.mother_core.add_nutrition(amount)


func _assert_dispatch_guards(level: Node2D, evidence: Dictionary, construction_ids: Array[String]) -> void:
	var foreign_owner: Node = Node.new()
	level.get_node("Systems").add_child(foreign_owner)
	var before_balance: int = level.mother_core.nutrition
	var before: Dictionary = _coordinator(level).get_resource_snapshot().duplicate(true)
	for construction_id: String in construction_ids:
		var worker: ConstructionWorker = _worker(level, construction_id)
		for supply: Node in [worker.growth_supply_system, worker.cultivation_supply_system]:
			var paid: int = _payments(worker)
			supply.set("auto_supply", true)
			_check(not bool(supply.call("try_dispatch")), "Managed public direct dispatch refuses even if auto_supply is re-enabled")
			supply.call("_process", 1000.0)
			_check(supply.call("get_dispatch_owner") == _scheduler(level)
				and not bool(supply.call("claim_dispatch_owner", foreign_owner))
				and not bool(supply.call("can_dispatch_scheduled", foreign_owner))
				and not bool(supply.call("try_dispatch_scheduled", foreign_owner)),
				"Managed timer and foreign owner cannot claim or call another original dispatch path")
			supply.call("release_dispatch_owner", foreign_owner)
			_check(supply.call("get_dispatch_owner") == _scheduler(level) and _payments(worker) == paid,
				"A foreign release does not detach the scheduler or create duplicate payments")
			supply.set("auto_supply", false)
			# 同一注册重试也必须维持组内每轮最多一次，返回值不假定是新增还是幂等成功。
			_scheduler(level).register_supply(construction_id, supply)
	_check(level.mother_core.nutrition == before_balance and _coordinator(level).get_resource_snapshot() == before,
		"All duplicate direct/timer/foreign-owner attempts leave exact original resources unchanged")
	foreign_owner.queue_free()
	_checkpoint(level, evidence, "exclusive_original_dispatch_ownership", true)


func _test_shared_budget_and_dispatch_ownership(level: Node2D, evidence: Dictionary) -> bool:
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var first_id: String = _admit(level, &"growth", {"start_node": _left(level), "target_position": Vector2(220, 200)})
	var second_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1080, 280)})
	coordinator.pump()
	_sync_workers(level, evidence)
	var first: ConstructionWorker = _worker(level, first_id)
	var second: ConstructionWorker = _worker(level, second_id)
	if first == null or second == null:
		_check(false, "Two actual demand-bearing workers must exist before the shared-budget fixture")
		return false
	_assert_dispatch_guards(level, evidence, [first_id, second_id])
	var organ: AttackOrgan = _left(level).get_node("AttackOrgan") as AttackOrgan
	var stock: int = organ.nutrition
	_check(stock > 0 and organ.consume_nutrition(stock), "Original organ consumption creates actual shared combat demand")
	evidence["organ_consumed"] = int(evidence["organ_consumed"]) + stock
	var edge: HyphaEdge = level.get_node("World/Colony/Connections/RightEdge") as HyphaEdge
	edge.take_damage(35.0)
	var repair_id: int = _repair(level).request_repair(edge)
	_repair_supply(level).refresh_budget()
	var reserve: int = first.growth_supply_system.get_combat_reserve()
	_check(repair_id > 0 and int(_repair_supply(level).get_supply_snapshot()["reserved_nutrition"]) == 4
		and reserve == 2 * SporeWeapon.SHOT_NUTRITION
		and second.growth_supply_system.get_combat_reserve() == reserve,
		"Actual damaged edge reserves four repair units while both construction workers share the same two-shot combat reserve")
	_move_to_fixture_escrow(level, evidence, 4 + reserve + 1)
	var progress: int = level.colony_progress.get_total_recovered()
	var successful: Dictionary = {first_id: 0, second_id: 0}
	var ids: Array[String] = [first_id, second_id]
	for round_index: int in range(8):
		if round_index > 0:
			_release_fixture_escrow(level, evidence, 1)
		# 真实到货只能满足当前原分段；继续原 advance 才会产生下一段需求。
		# 每个有效轮次先让两组都具备需求，避免把跳过无需求组误判成饥饿。
		if not await _until(level, evidence, "one_unit_round_%d_both_original_demands_ready" % round_index, func() -> bool:
			return first.growth_supply_system.can_dispatch_scheduled(_scheduler(level)) \
				and second.growth_supply_system.can_dispatch_scheduled(_scheduler(level)), false):
			return false
		var first_before: int = _payments(first)
		var second_before: int = _payments(second)
		_check(first.growth_supply_system.get_available_growth_nutrition() == 1
			and second.growth_supply_system.get_available_growth_nutrition() == 1,
			"Both actual demand-bearing groups see the same single available original core unit")
		_check(_fund_round(level, evidence) == 1,
			"One shared spendable unit pays exactly one genuine group in each effective scheduler round")
		successful[first_id] = int(successful[first_id]) + _payments(first) - first_before
		successful[second_id] = int(successful[second_id]) + _payments(second) - second_before
		_check(level.mother_core.nutrition == 4 + reserve
			and int(level.mother_core.get_budget_snapshot()["reserved"]) == 4
			and absi(int(successful[first_id]) - int(successful[second_id])) <= 1,
			"Fair cursor cannot overspend actual repair/combat reservations or starve one direction under unit funding")
		if not await _until(level, evidence, "one_unit_round_%d_real_packet_settlement" % round_index, func() -> bool:
			return first.growth_supply_system.get_in_transit_count() == 0 \
				and second.growth_supply_system.get_in_transit_count() == 0, false):
			return false
		for worker: ConstructionWorker in [first, second]:
			var paid_resources: Dictionary = worker.get_resource_snapshot()
			_check(_payments(worker) == int(paid_resources["network_structure"])
				+ int(paid_resources["growth_buffer"]) + int(paid_resources["growth_transit"]),
				"Each real growth payment remains exactly consumed structure plus its actual paid buffer/transit")
	_check(int(successful[first_id]) == 4 and int(successful[second_id]) == 4
		and int(_growth(level, first_id).get("consumed_nutrition", 0)) > 0
		and int(_growth(level, second_id).get("consumed_nutrition", 0)) > 0
		and float(_growth(level, first_id).get("distance", 0.0)) > 0.0
		and float(_growth(level, second_id).get("distance", 0.0)) > 0.0
		and level.colony_progress.get_total_recovered() == progress,
		"Eight effective unit-funded rounds pay each group four times and physically advance both without counting fixture funds as recovery")
	_check(_fund_round(level, evidence) == 0, "Exhausted shared budget dispatches no additional original packet")
	var before_cancel: int = level.mother_core.nutrition
	var refundable: int = 0
	var refunds: Dictionary = {}
	var paid_structure: int = int(coordinator.get_resource_snapshot()["network_structure"])
	for construction_id: String in ids:
		var worker: ConstructionWorker = _worker(level, construction_id)
		var paid_resources: Dictionary = worker.get_resource_snapshot()
		var unused: int = int(paid_resources["growth_buffer"]) + int(paid_resources["growth_transit"])
		refunds[construction_id] = unused
		refundable += unused
		var before_worker_cancel: int = level.mother_core.nutrition
		_check(coordinator.cancel_request(construction_id)
			and level.mother_core.nutrition == before_worker_cancel + unused,
			"Budget cancellation refunds only this worker's actual remaining original buffer/transit")
	_check(level.mother_core.nutrition == before_cancel + refundable
		and int(coordinator.get_resource_snapshot()["network_structure"]) == paid_structure
		and int(level.mother_core.get_budget_snapshot()["reserved"]) == 4,
		"Cancelling both fair-progress workers preserves every consumed structural unit and actual repair reservation")
	_check(_repair_supply(level).try_dispatch(), "Actual repair can spend its protected reservation while construction is stopped")
	if not await _until(level, evidence, "protected_original_repair_physically_heals", func() -> bool:
		if _repair(level).has_active_task():
			_repair_supply(level).try_dispatch()
		return not _repair(level).has_active_task(), false):
		return false
	_check(edge.health == 35.0 and int(_repair(level).get_task_snapshot().get("consumed_nutrition", -1)) == 4
		and int(level.mother_core.get_budget_snapshot()["reserved"]) == 0,
		"Protected budget pays the original four-unit real repair and releases all unpaid reservation")
	_check(level.supply_system.request_supply(organ) and level.supply_system.request_supply(organ),
		"Original combat system dispatches both protected shots through the shared FIFO")
	if not await _until(level, evidence, "protected_combat_packets_physically_arrive", func() -> bool:
		return level.supply_system.get_in_transit_count() == 0, false):
		return false
	_check(organ.nutrition == reserve and organ.incoming_nutrition == 0,
		"Combat reserve becomes real original organ stock after actual transport")
	_release_fixture_escrow(level, evidence, int(evidence["escrow"]))
	_check(int(evidence["escrow"]) == 0 and level.colony_progress.get_total_recovered() == progress
		and int(evidence["nested_dispatch_attempts"]) > 0,
		"All conserved fixture funds return explicitly and recursive debit attempts produced no extra dispatch")
	_checkpoint(level, evidence, "fair_original_shared_budget_and_real_protected_business", true)
	cases.append(_summary(level, evidence, "shared_repair_combat_budget_and_exclusive_dispatch", {
		"construction_ids": ids, "successful_one_unit_rounds": successful,
		"actual_growth_refunds": refunds, "actual_refund_total": refundable,
		"actual_repair_cost": 4, "actual_combat_delivery": reserve,
		"nested_dispatch_attempts": evidence["nested_dispatch_attempts"]}))
	return true


func _live_packet_count(level: Node2D, path: String) -> int:
	var count: int = 0
	for child: Node in level.get_node(path).get_children():
		if not child.is_queued_for_deletion() and (child is NutrientPacket or child is RemainsPacket):
			count += 1
	return count


func _capture_retired_handles(level: Node2D, evidence: Dictionary) -> Dictionary:
	var retired: Dictionary = {"worker_instances": [], "module_instances": [], "packet_instances": [],
		"callbacks": [], "handles": [], "construction_ids": []}
	for worker: ConstructionWorker in _coordinator(level).get_workers(true):
		(retired["worker_instances"] as Array).append(worker.get_instance_id())
		(retired["construction_ids"] as Array).append(String(worker.get_snapshot().get("construction_id", "")))
		for field: String in MODULES.values():
			var module: Node = worker.get(field) as Node
			(retired["module_instances"] as Array).append(module.get_instance_id())
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		var candidate: Variant = record["packet"]
		if not is_instance_valid(candidate) or candidate.is_queued_for_deletion():
			continue
		var packet: Node2D = candidate as Node2D
		(retired["packet_instances"] as Array).append(packet.get_instance_id())
		(retired["callbacks"] as Array).append_array(record["arrived_callbacks"])
		(retired["callbacks"] as Array).append_array(record["interrupted_callbacks"])
		(retired["handles"] as Array).append(packet.call("get_transport_snapshot").duplicate())
	return retired


func _assert_retired_instances(retired: Dictionary) -> void:
	for field: String in ["worker_instances", "module_instances", "packet_instances"]:
		for instance_id: int in retired[field]:
			_check(not is_instance_valid(instance_from_id(instance_id)),
				"Reset/restart/death destroys every retired " + field + " physical identity")
	for callback: Callable in retired["callbacks"]:
		# 普通维修回调在同场景 reset 下仍有效；只有原 worker/旧场景的回调须失效。
		var owner: Object = callback.get_object()
		if not is_instance_valid(owner):
			_check(not callback.is_valid(), "Destroyed original callback owners cannot reach a later worker")


func _assert_clean_construction(level: Node2D, expected_network: int, expected_organ: int,
		fresh_scene: bool = false) -> void:
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var snapshot: Dictionary = coordinator.get_snapshot()
	var resources: Dictionary = coordinator.get_resource_snapshot()
	_check(snapshot["entries"].is_empty() and snapshot["maturing"].is_empty()
		and snapshot["active_ids"].is_empty() and snapshot["selected_id"] == "" and snapshot["active_id"] == ""
		and int(snapshot["tip_count"]) == 0 and int(snapshot["external_count"]) == 0
		and int(snapshot["waiting_count"]) == 0 and int(snapshot["maturing_count"]) == 0
		and coordinator.get_all_requests().is_empty() and coordinator.get_active_requests().is_empty(),
		"Cleanup clears queue, mature collection, selection, IDs, counts and every request history")
	_check(coordinator.get_workers(true).is_empty() and coordinator.worker_container.get_child_count() == 0
		and int(_scheduler(level).get_snapshot().get("registered_count", -1)) == 0
		and _scheduler(level).dispatch_round() == 0,
		"Cleanup frees all live/retired workers and leaves no scheduler registration capable of dispatch")
	_check(int(resources["network_structure"]) == expected_network and int(resources["organ_structure"]) == expected_organ,
		"Same-map cleanup preserves exactly paid archived network/organ structure; a new scene starts zero")
	for field: String in ["growth_buffer", "cultivation_buffer", "startup_reserved", "growth_transit", "cultivation_transit"]:
		_check(int(resources[field]) == 0, "Cleanup leaves no original refundable " + field)
	for path: String in ["World/GrowthPackets", "World/CultivationPackets"]:
		_check(level.get_node(path).get_child_count() == 0, "Cleanup removes every physical object in " + path)
	var tips: Node = level.get_node("World/GrowthTips")
	if fresh_scene:
		_check(tips.get_child_count() == 0, "A fresh actual R scene contains no old tip or retained growth stump")
	else:
		for child: Node in tips.get_children():
			_check(not child is GrowthTip and child is Node2D and child.get_script() == null
				and child.process_mode == Node.PROCESS_MODE_DISABLED,
				"Same-map cleanup retains only original inert cancelled structure and no actual GrowthTip/executor")
	_check(int(level.mother_core.get_budget_snapshot()["reserved"]) == 0,
		"All actual unpaid core reservations are released after the relevant business cleanup")


func _start_live_cleanup_fixture(level: Node2D, evidence: Dictionary, prefix: String) -> Array[String]:
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var first_id: String = _admit(level, &"remote_cultivation", {"start_node": _left(level), "target_position": Vector2(140, 230)})
	var second_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1080, 680)})
	var waiting_id: String = _admit(level, &"growth", {"start_node": _left(level), "target_position": Vector2(240, 740)})
	coordinator.pause_request(waiting_id)
	coordinator.pump()
	_sync_workers(level, evidence)
	var hosts: Array[HyphaNode] = _empty_hosts(level, 1)
	if hosts.is_empty():
		return []
	var local_id: String = _admit_local(level, hosts[0])
	coordinator.pump()
	_sync_workers(level, evidence)
	var ids: Array[String] = [first_id, second_id, waiting_id, local_id]
	var controls: Dictionary = {"cultivation_ceilings": {local_id: 0.5}}
	if not await _until(level, evidence, prefix + "_live_paid_workers_and_physical_cargo", func() -> bool:
		return int(_growth(level, first_id).get("consumed_nutrition", 0)) > 0 \
			and int(_growth(level, second_id).get("consumed_nutrition", 0)) > 0 \
			and int(_cultivation(level, local_id).get("structure_consumed", 0)) > 0 \
			and int(coordinator.get_resource_snapshot()["growth_transit"]) > 0, true, controls):
		return []
	_check(int(coordinator.get_snapshot()["tip_count"]) == 2
		and int(coordinator.get_snapshot()["external_count"]) == 3
		and int(coordinator.get_snapshot()["maturing_count"]) == 1,
		"Cleanup fixture has two actual progressing tips, one waiting external and one independent paid local bud")
	return ids


func _test_same_scene_reset(level: Node2D, evidence: Dictionary) -> bool:
	var ids: Array[String] = await _start_live_cleanup_fixture(level, evidence, "same_scene_reset")
	if ids.is_empty():
		return false
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var generation: int = _queue(level).get_generation()
	var before: Dictionary = coordinator.get_resource_snapshot().duplicate(true)
	var retired: Dictionary = _capture_retired_handles(level, evidence)
	var balance: int = level.mother_core.nutrition
	var refundable: int = int(before["growth_buffer"]) + int(before["cultivation_buffer"])
	refundable += int(before["startup_reserved"]) + int(before["growth_transit"]) + int(before["cultivation_transit"])
	_checkpoint(level, evidence, "before_same_scene_coordinator_reset", true)
	coordinator.reset()
	# 原取消已实际发生，旧包尚待销毁时重放；不是手工制造第一次到货。
	for record: Dictionary in (evidence["packets"] as Dictionary).values():
		_replay_settled(level, evidence, record)
	await process_frame
	await process_frame
	_assert_clean_construction(level, int(before["network_structure"]), int(before["organ_structure"]))
	_assert_retired_instances(retired)
	_check(_queue(level).get_generation() > generation and level.mother_core.nutrition == balance + refundable
		and level.colony_progress.get_total_recovered() == 160,
		"Same-scene reset invalidates generation and refunds only physical unused resources without resetting genuine recovery")
	var first_archive: Dictionary = coordinator.get_resource_snapshot().duplicate(true)
	coordinator.reset()
	await process_frame
	_check(coordinator.get_resource_snapshot() == first_archive,
		"A second empty reset cannot archive the same original structure twice")
	var fresh_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1110, 710)})
	coordinator.pump()
	_sync_workers(level, evidence)
	var identity: Dictionary = _identity(_queue(level).get_request(fresh_id))
	var new_balance: int = level.mother_core.nutrition
	for _tick_index: int in range(20):
		await _tick(level, evidence, false)
	_check(not ids.has(fresh_id) and _identity(_queue(level).get_request(fresh_id)) == identity
		and level.mother_core.nutrition == new_balance
		and int(_growth(level, fresh_id).get("consumed_nutrition", -1)) == 0
		and int(_growth(level, fresh_id).get("buffered_nutrition", -1)) == 0
		and is_zero_approx(float(_growth(level, fresh_id).get("distance", -1.0))),
		"Retired physical callbacks and deferred pumps cannot pay or advance a newly admitted generation")
	if not await _until(level, evidence, "new_generation_pays_only_new_original_shipments", func() -> bool:
		return _queue(level).get_request(fresh_id).get("state") == &"completed"):
		return false
	_check_worker_wiring(level, fresh_id)
	_checkpoint(level, evidence, "archived_structure_plus_new_generation_spending", true)
	cases.append(_summary(level, evidence, "same_scene_reset_archives_once", {
		"retired": ids, "new_construction": fresh_id, "actual_refund": refundable,
		"archived_network": before["network_structure"], "archived_organ": before["organ_structure"]}))
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


func _test_actual_restart(level: Node2D, evidence: Dictionary) -> Node2D:
	var ids: Array[String] = await _start_live_cleanup_fixture(level, evidence, "actual_R")
	if ids.is_empty():
		return null
	var edge: HyphaEdge = level.get_node("World/Colony/Connections/RightEdge") as HyphaEdge
	edge.take_damage(7.0)
	_check(_repair(level).request_repair(edge) > 0, "Actual R fixture includes a genuine original repair task")
	_repair_supply(level).refresh_budget()
	_check(int(level.mother_core.get_budget_snapshot()["reserved"]) == 1 and _repair_supply(level).try_dispatch(),
		"Actual R fixture owns a real repair reservation and paid original physical packet")
	var retired: Dictionary = _capture_retired_handles(level, evidence)
	var old_coordinator_id: int = _coordinator(level).get_instance_id()
	var old_scheduler_id: int = _scheduler(level).get_instance_id()
	var old_traffic_id: int = level.traffic_system.get_instance_id()
	var before: Dictionary = _resources(level, evidence)
	var expected_balance: int = int(before["core"]) + int(before["growth_buffer"]) + int(before["cultivation_buffer"])
	expected_balance += int(before["startup_reserved"]) + int(before["growth_transit"]) + int(before["cultivation_transit"])
	expected_balance += int(before["repair_buffer"]) + int(before["repair_transit"]) + int(before["combat_transit"])
	var balances: Array[int] = []
	level.mother_core.nutrition_changed.connect(func(amount: int) -> void:
		balances.append(amount))
	_checkpoint(level, evidence, "before_actual_R_with_two_tips_mature_waiting_and_repair", true)
	var summary: Dictionary = _summary(level, evidence, "actual_R_retires_all_instances", {"retired": ids})
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	for _frame_index: int in range(40):
		await physics_frame
		await process_frame
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	evidence["active"] = false
	var fresh: Node2D = current_scene as Node2D
	_check(is_instance_valid(fresh) and fresh != level and not is_instance_valid(level),
		"Actual R input destroys the old formal scene and creates a fresh formal scene")
	if not is_instance_valid(fresh) or fresh == level:
		return null
	_quiet(fresh)
	_check_wiring(fresh)
	_assert_clean_construction(fresh, 0, 0, true)
	_assert_retired_instances(retired)
	_check(not is_instance_valid(instance_from_id(old_coordinator_id))
		and not is_instance_valid(instance_from_id(old_scheduler_id))
		and not is_instance_valid(instance_from_id(old_traffic_id)),
		"R retires old coordinator, scheduler, shared FIFO and all mutable executor identities")
	_check(not balances.is_empty() and balances.back() == expected_balance,
		"R refunds exact original unused construction and repair ownership before its original payer disappears")
	for amount: int in balances:
		_check(amount <= expected_balance, "R cannot refund archived structural spending or duplicate unused resources")
	for handle: Dictionary in retired["handles"]:
		var request_id: String = String(handle.get("request_id", ""))
		var token: String = String(handle.get("token", ""))
		_check(fresh.traffic_system.get_request(request_id).is_empty()
			and fresh.traffic_system.get_lease(token).is_empty()
			and not fresh.traffic_system.release(token) and not fresh.traffic_system.cancel_request(request_id),
			"Old worker and repair transport handles cannot operate on the fresh shared FIFO")
	_check(fresh.mother_core.nutrition == CAPITAL and fresh.colony_progress.get_total_recovered() == 0
		and fresh.colony_progress.get_product_count() == 0
		and fresh.mother_core.get_received_product_count() == 0
		and int(_coordinator(fresh).get_snapshot()["tip_limit"]) == 1,
		"Fresh formal R scene starts original capital, zero histories/recovery and one initial tip capability")
	for path: String in PACKET_PATHS:
		_check(_live_packet_count(fresh, path) == 0, "Fresh R has no old physical packets in " + path)
	summary["fresh_capital"] = fresh.mother_core.nutrition
	summary["old_identities_destroyed"] = true
	cases.append(summary)
	return fresh


func _test_actual_death(level: Node2D) -> void:
	_add_carcass_fixtures(level, 1)
	var evidence: Dictionary = _observe(level, "fresh_formal_actual_death")
	var coordinator: ConstructionCoordinator = _coordinator(level)
	var queue: ConstructionQueue = _queue(level)
	var first_id: String = _admit(level, &"growth", {"start_node": _left(level), "target_position": Vector2(120, 380)})
	var second_id: String = _admit(level, &"growth", {"start_node": _right(level), "target_position": Vector2(1140, 400)})
	var waiting_id: String = _admit(level, &"remote_cultivation", {"start_node": _left(level), "target_position": Vector2(300, 720)})
	coordinator.pump()
	_sync_workers(level, evidence)
	_check(coordinator.pause_request(first_id), "Fresh death fixture preserves its actual initial worker during real recovery")
	for batch_index: int in range(1, 7):
		if not await _recover_batch(level, evidence, batch_index):
			await _dispose(level, evidence)
			return
	_check(coordinator.resume_request(first_id), "Genuine sixty-unit death fixture resumes the same original first task")
	if not await _until(level, evidence, "death_fixture_two_actual_paid_tips_form_mature_hosts", func() -> bool:
		return float(_growth(level, first_id).get("distance", 0.0)) >= 50.0 \
			and float(_growth(level, second_id).get("distance", 0.0)) >= 50.0 \
			and _has_paid_empty_host(level)):
		await _dispose(level, evidence)
		return
	var hosts: Array[HyphaNode] = _empty_hosts(level, 1)
	if hosts.is_empty():
		await _dispose(level, evidence)
		return
	var local_id: String = _admit_local(level, hosts[0])
	coordinator.pump()
	_sync_workers(level, evidence)
	_check(int(coordinator.get_snapshot()["tip_count"]) == 2
		and int(coordinator.get_snapshot()["external_count"]) == 3
		and queue.get_request(waiting_id).get("started", false) == false,
		"Actual death fixture owns two physical tips, a third waiting target and a separate local bud")
	_fund_round(level, evidence)
	var edge: HyphaEdge = level.get_node("World/Colony/Connections/RightEdge") as HyphaEdge
	edge.take_damage(7.0)
	_check(_repair(level).request_repair(edge) > 0, "Actual death fixture creates its original repair demand")
	_repair_supply(level).refresh_budget()
	_check(_repair_supply(level).try_dispatch(), "Actual death fixture owns genuine paid original repair cargo")
	var before: Dictionary = coordinator.get_resource_snapshot().duplicate(true)
	var retired: Dictionary = _capture_retired_handles(level, evidence)
	var received: int = level.mother_core.get_received_product_count()
	_checkpoint(level, evidence, "before_actual_core_depletion_with_all_worker_states", true)
	level.mother_core.take_damage(level.mother_core.health)
	await process_frame
	await process_frame
	_check(current_scene == level and level.mother_core.health == 0,
		"Real MotherCore damage emits depletion and keeps the defeated formal map until R")
	_assert_clean_construction(level, int(before["network_structure"]), int(before["organ_structure"]))
	_assert_retired_instances(retired)
	for path: String in PACKET_PATHS:
		_check(level.get_node(path).get_child_count() == 0, "Actual death removes all old business packets in " + path)
	for row: Dictionary in level.traffic_system.get_snapshot()["edges"]:
		_check(int(row["occupied_units"]) == 0, "Actual death releases every original FIFO lease")
	for key: Key in [KEY_G, KEY_B, KEY_L, KEY_C]:
		_press(key)
		_click(Vector2(320, 300))
	var dead_request: Dictionary = coordinator.enqueue(&"growth", {"start_node": _left(level), "target_position": Vector2(250, 320)})
	_check(not bool(dead_request.get("accepted", true)) and coordinator.get_all_requests().is_empty()
		and coordinator.get_workers(true).is_empty() and level.mother_core.get_received_product_count() == received,
		"Real defeated input and stale admission cannot create, pay, refund or unlock new worker tasks")
	_checkpoint(level, evidence, "actual_death_keeps_archived_structure_and_no_worker_ownership", true)
	cases.append(_summary(level, evidence, "actual_death_cleans_two_workers_local_waiting_and_repair", {
		"retired": [first_id, second_id, waiting_id, local_id], "actual_core_health": level.mother_core.health,
		"archived_network": before["network_structure"], "archived_organ": before["organ_structure"]}))
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	for _frame_index: int in range(40):
		await process_frame
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	evidence["active"] = false
	var fresh: Node2D = current_scene as Node2D
	_check(is_instance_valid(fresh) and fresh != level and not is_instance_valid(level),
		"Actual R after real death starts a fresh original scene")
	if is_instance_valid(fresh) and fresh != level:
		_quiet(fresh)
		_assert_clean_construction(fresh, 0, 0, true)
		_check(fresh.mother_core.nutrition == CAPITAL and fresh.colony_progress.get_total_recovered() == 0,
			"R after death restores original capital and real initial progression without archived spending")
		await _dispose(fresh, {})
	elif is_instance_valid(level):
		await _dispose(level, evidence)
