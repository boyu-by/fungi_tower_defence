extends SceneTree
## 7.6 完整循环：正式资源、原施工付款、实体运输、真实消化计时器和绿色抵达。
## 敌人生成/开火在本集成夹具中隔离；六敌实战由正式场景验证另行覆盖。
## 低余额段只把已拥有的余额转入明示 escrow，不赠送资源或推进成长。
## 父任务运行 Godot --headless --fixed-fps 60 --path . --script tests/progression_cycle_test.gd。

const DEMO_PATH: String = "res://scenes/levels/progression_demo.tscn"
const CAPITAL: int = 72
const SOURCE_TOTAL: int = 200
const STEP: float = 0.1
const STEP_LIMIT: int = 4000
const RUN_STEP_LIMIT: int = 30000
const FIRST_TARGET: Vector2 = Vector2(970, 440)
const SECOND_TARGET: Vector2 = Vector2(180, 450)
const PARALLEL_TARGET: Vector2 = Vector2(940, 600)
const WAITING_TARGET: Vector2 = Vector2(440, 260)
const PACKET_PATHS: Array[String] = [
	"World/GrowthPackets", "World/CultivationPackets", "World/Packets",
	"World/RepairPackets", "World/RecoveryPackets", "World/ReturnPackets",
]
const PACKET_KINDS: Array[String] = ["growth", "cultivation", "combat", "repair", "remains", "return"]
const RESOURCE_FIELDS: Array[String] = [
	"network_structure", "organ_structure", "growth_buffer", "cultivation_buffer",
	"startup_reserved", "growth_transit", "cultivation_transit",
]

class Fixture:
	extends RefCounted
	var level: Node2D
	var core: MotherCore
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var coordinator: ConstructionCoordinator
	var queue: ConstructionQueue
	var scheduler: ConstructionSupplyScheduler
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var tracker: CargoPassageTracker
	var veins: MainVeinSystem
	var stomach: DigestiveOrgan
	var recycling: RecyclingSystem
	var returns: NutritionReturnSystem
	var combat: SupplySystem
	var repair: RepairSystem
	var repair_supply: RepairSupplySystem
	var field: FungalField
	var left: HyphaNode
	var right: HyphaNode
	var first: LargeCarcass
	var second: LargeCarcass
	var active: bool = true
	var retiring: bool = false
	var initial_total: int = 0
	var initial_stock: int = 0
	var escrow: int = 0
	var fixture_consumed: int = 0
	var shots_spent: int = 0
	var enemy_drop_nutrition: int = 0
	var funding: bool = false
	var nested_dispatches: int = 0
	var packets: Dictionary = {}
	var workers: Dictionary = {}
	var growth_costs: Dictionary = {}
	var organ_costs: Dictionary = {}
	var repair_costs: Dictionary = {}
	var watched_weapons: Dictionary = {}
	var receipts: Dictionary = {}
	var starts: Array[Dictionary] = []
	var completions: Array[Dictionary] = []
	var transitions: Array[Vector2i] = []
	var unlocks: Array[int] = []
	var handoffs: Dictionary = {}
	var matured: Dictionary = {}
	var finished: Dictionary = {}
	var upgrades: Array[Dictionary] = []
	var access_events: Array[Dictionary] = []
	var checkpoints: Array[Dictionary] = []
	var high_capacity: Dictionary = {}
	var confirmed_history: Dictionary = {}
	var last_resources: Dictionary = {}
	var first_conservation_failure: Dictionary = {}
	var maximum_active: int = 0
	var maximum_products: int = 0
	var maximum_output_nutrition: int = 0

var checks: int = 0
var conservation_checks: int = 0
var sampled_steps: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	var fixture: Fixture = await _new_fixture()
	if fixture != null:
		var completed: bool = await _full_cycle(fixture)
		if completed:
			completed = await _cancel_identity(fixture)
		if completed:
			completed = await _isolated_budget(fixture)
		if completed:
			var fresh: Fixture = await _restart(fixture)
			if fresh != null:
				await _dispose(fresh)
		else:
			evidence.append({"case": "incomplete_cycle_diagnostics", "resources": fixture.last_resources,
				"first_conservation_failure": fixture.first_conservation_failure,
				"recovered": fixture.progress.get_total_recovered()})
			await _dispose(fixture)
	_check(root.get_child_count() == 0, "All progression fixtures and workers are disposed")
	_finish()


func _finish() -> void:
	print("PROGRESSION_CYCLE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
		"conservation_checks": conservation_checks, "sampled_steps": sampled_steps,
		"scene": DEMO_PATH, "original_carcass_nutrition": SOURCE_TOTAL,
		"first_arrivals_fabricated": false, "stage_receipts_fabricated": false,
		"direct_resource_grants": false, "packet_speed_changed": false,
		"main_veins_enabled": true, "motion": "original_physics_methods_with_bounded_steps",
		"digestion_clock": "original_physics_timers", "enemy_fixture": "original_six_enemy_spawner_and_fire_isolated",
		"full_six_enemy_gameplay_included": false,
		"budget_fixture": "separately_labeled_conserved_core_escrow",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
		push_error(message)


func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _prepare(level: Node2D) -> void:
	# 在 ready 前停用无关派送；资源、默认速度、胃囊 Timer 和主脉成长不作改写。
	level.set("expansion_demo_enabled", false)
	level.set("carcass_demo_enabled", false)
	level.get_node("Systems/EnemySpawner").set("auto_start", false)
	for name: String in ["GrowthSupplySystem", "CultivationSupplySystem", "RepairSupplySystem"]:
		level.get_node("Systems/" + name).set("auto_supply", false)
	level.get_node("Systems/NutritionReturnSystem").set("auto_return", false)
	level.get_node("Systems/ConstructionCoordinator").set("auto_execute", false)
	level.get_node("Systems/ConstructionSupplyScheduler").set("auto_dispatch", false)
	for name: String in ["SupplySystem", "RecyclingSystem"]:
		level.get_node("Systems/" + name + "/DispatchTimer").set("autostart", false)
	for name: String in ["HyphaNode", "RightNode"]:
		level.get_node("World/Colony/Nodes/" + name + "/SporeWeapon/FireTimer").set("autostart", false)


func _prepare_reload(child: Node) -> void:
	if child is Node2D and child.scene_file_path == DEMO_PATH:
		_prepare(child as Node2D)


func _quiet(level: Node2D) -> void:
	level.set_process(false)
	(level.get_node("Systems/EnemySpawner") as EnemySpawner).stop_spawning()
	for name: String in ["SupplySystem", "RecyclingSystem", "NutritionReturnSystem"]:
		(level.get_node("Systems/" + name + "/DispatchTimer") as Timer).stop()
	for name: String in ["GrowthSystem", "CultivationSystem", "RepairSystem"]:
		level.get_node("Systems/" + name).set_physics_process(false)
	for name: String in ["GrowthSupplySystem", "CultivationSupplySystem", "RepairSupplySystem",
		"ConstructionSupplyScheduler", "NetworkTrafficSystem"]:
		level.get_node("Systems/" + name).set_process(false)
	level.get_node("World/FungalField").set_process(false)
	for weapon: SporeWeapon in level.call("get_weapons"):
		weapon.get_node("FireTimer").stop()


func _new_fixture(level: Node2D = null) -> Fixture:
	if level == null and not FileAccess.file_exists(DEMO_PATH):
		_check(false, "Missing prerequisite: the frozen progression_demo scene must exist")
		return null
	if level == null:
		var packed: PackedScene = load(DEMO_PATH) as PackedScene
		if packed == null:
			_check(false, "Missing prerequisite: progression_demo must load as a PackedScene")
			return null
		level = packed.instantiate() as Node2D
		_prepare(level)
		root.add_child(level)
		current_scene = level
	_quiet(level)
	await process_frame
	await process_frame
	if not level.has_method("get_resource_access_snapshot"):
		_check(false, "Missing prerequisite: new demo must expose the frozen resource access observation")
		current_scene = null
		level.queue_free()
		await process_frame
		return null
	var fixture: Fixture = Fixture.new()
	fixture.level = level
	fixture.core = level.get_node("World/Colony/MotherCore") as MotherCore
	fixture.left = level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode
	fixture.right = level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	fixture.first = level.get_node_or_null("World/Remains/FirstCarcass") as LargeCarcass
	fixture.second = level.get_node_or_null("World/Remains/SecondCarcass") as LargeCarcass
	if fixture.first == null or fixture.second == null:
		_check(false, "Missing prerequisite: new demo must own its original FirstCarcass and SecondCarcass")
		await _dispose(fixture)
		return null
	fixture.progress = level.get_node("Systems/ColonyProgress") as ColonyProgress
	fixture.capabilities = level.get_node("Systems/ColonyCapabilities") as ColonyCapabilities
	fixture.coordinator = level.get_node("Systems/ConstructionCoordinator") as ConstructionCoordinator
	fixture.queue = level.get_node("Systems/ConstructionQueue") as ConstructionQueue
	fixture.scheduler = level.get_node("Systems/ConstructionSupplyScheduler") as ConstructionSupplyScheduler
	fixture.network = level.get_node("Systems/NetworkSystem") as NetworkSystem
	fixture.traffic = level.get_node("Systems/NetworkTrafficSystem") as NetworkTrafficSystem
	fixture.tracker = level.get_node("Systems/CargoPassageTracker") as CargoPassageTracker
	fixture.veins = level.get_node("Systems/MainVeinSystem") as MainVeinSystem
	fixture.stomach = level.get_node("World/Colony/Nodes/RearNode/DigestiveOrgan") as DigestiveOrgan
	fixture.recycling = level.get_node("Systems/RecyclingSystem") as RecyclingSystem
	fixture.returns = level.get_node("Systems/NutritionReturnSystem") as NutritionReturnSystem
	fixture.combat = level.get_node("Systems/SupplySystem") as SupplySystem
	fixture.repair = level.get_node("Systems/RepairSystem") as RepairSystem
	fixture.repair_supply = level.get_node("Systems/RepairSupplySystem") as RepairSupplySystem
	fixture.field = level.get_node("World/FungalField") as FungalField
	level.call("_process", 0.0)
	fixture.field.advance(1.0)
	level.call("_process", 0.0)
	for organ: AttackOrgan in fixture.combat.get_registered_organs():
		fixture.initial_stock += organ.nutrition
	fixture.initial_total = CAPITAL + SOURCE_TOTAL + fixture.initial_stock
	_observe(fixture)
	_checkpoint(fixture, "initial", true)
	_check(fixture.core.nutrition == CAPITAL and fixture.progress.get_total_recovered() == 0
		and fixture.core.get_received_product_count() == 0 and fixture.initial_stock == 8,
		"Initial 72 capital and original organ stock are excluded from recovered nutrition")
	_check(fixture.first.total_nutrition == 80 and fixture.second.total_nutrition == 120
		and fixture.first.batch_size == 10 and fixture.second.batch_size == 10
		and fixture.first.global_position == Vector2(1030, 450)
		and fixture.second.global_position == Vector2(110, 460),
		"New demo retains its frozen original two carcasses, positions and ten-unit batches")
	_check((level.get_node("Systems/EnemySpawner") as EnemySpawner).wave_size == 6
		and level.get_node("World/Enemies").get_child_count() == 0,
		"Isolated fixture retains the original six-enemy definition and reports zero spawned enemies")
	_check(fixture.coordinator.multi_worker_enabled and fixture.queue.multi_execution
		and fixture.coordinator.supply_scheduler == fixture.scheduler
		and fixture.coordinator.mother_core == fixture.core
		and fixture.capabilities.colony_progress == fixture.progress
		and fixture.stomach.colony_capabilities == fixture.capabilities and fixture.veins.enabled,
		"Formal workers, payer, stomach and natural veins use their actual shared production modules")
	_check(int(fixture.coordinator.get_snapshot()["tip_limit"]) == 1
		and fixture.stomach.get_digestion_snapshot()["expansion_state"] == &"locked",
		"A fresh run starts with one tip and one locked digestive chamber")
	return fixture


func _observe(fixture: Fixture) -> void:
	fixture.coordinator.changed.connect(func(_snapshot: Dictionary) -> void:
		if fixture.active:
			_sync_workers(fixture))
	fixture.coordinator.request_finished.connect(func(construction_id: String, state: StringName) -> void:
		if fixture.active:
			_check(not fixture.finished.has(construction_id), "Each construction identity terminates exactly once")
			fixture.finished[construction_id] = state)
	fixture.coordinator.organ_matured.connect(
		func(construction_id: String, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon) -> void:
			if not fixture.active:
				return
			_check(not fixture.matured.has(construction_id) and organ.nutrition == 4
				and organ.incoming_nutrition == 0 and organ.get_parent() == host
				and weapon.inventory_owner == organ and not host.is_organ_slot_available(),
				"Original remote maturation creates one real organ with four transferred startup units")
			fixture.matured[construction_id] = host.get_instance_id()
			_watch_weapon(fixture, weapon))
	fixture.core.digestion_product_arrived.connect(func(product_id: String, amount: int) -> void:
		if not fixture.active or fixture.retiring:
			return
		_check(not fixture.receipts.has(product_id) and amount == 10
			and fixture.core.has_received_product(product_id),
			"Actual green settlement credits each original ten-unit product exactly once")
		fixture.receipts[product_id] = amount)
	fixture.core.nutrition_changed.connect(func(_amount: int) -> void:
		if fixture.active and fixture.funding:
			fixture.nested_dispatches += 1
			_check(fixture.scheduler.dispatch_round() == 0,
				"A synchronous original debit cannot recursively dispatch another scheduler round"))
	fixture.progress.stage_changed.connect(func(before: ColonyProgress.Stage, after: ColonyProgress.Stage) -> void:
		if not fixture.active or fixture.retiring:
			return
		fixture.transitions.append(Vector2i(before, after))
		var economy: Dictionary = _event_economy(fixture)
		var tip_count: int = fixture.level.get_node("World/GrowthTips").get_child_count()
		fixture.progress.get_stage_name()
		fixture.progress.get_next_stage_threshold()
		fixture.capabilities.get_extension_tip_limit()
		fixture.capabilities.can_expand_second_digestive_chamber()
		fixture.level.call("get_resource_access_snapshot")
		_check(economy == _event_economy(fixture)
			and tip_count == fixture.level.get_node("World/GrowthTips").get_child_count(),
			"Stage notification and read-only capability/access queries cannot grant resources or create tips")
		_check(fixture.progress.get_total_recovered() == (60 if after == ColonyProgress.Stage.EXPANDED else 160),
			"Stage transitions occur at the exact original real-arrival thresholds"))
	fixture.progress.stage_unlocked.connect(func(stage: ColonyProgress.Stage) -> void:
		if fixture.active and not fixture.retiring:
			fixture.unlocks.append(stage))
	fixture.stomach.digestion_started.connect(
		func(task_id: String, chamber_id: int, input_id: String, nutrition: int) -> void:
			if fixture.active:
				for previous: Dictionary in fixture.starts:
					_check(previous["task_id"] != task_id and previous["input_id"] != input_id,
						"Each physical corpse intake belongs to one original digestion task")
				fixture.starts.append({"task_id": task_id, "chamber_id": chamber_id,
					"input_id": input_id, "nutrition": nutrition, "time": _now()}))
	fixture.stomach.digestion_completed.connect(
		func(task_id: String, chamber_id: int, product_id: String, nutrition: int) -> void:
			if fixture.active:
				var matched: bool = false
				for started: Dictionary in fixture.starts:
					if started["task_id"] == task_id:
						matched = started["chamber_id"] == chamber_id and started["nutrition"] == nutrition
						_check(_now() - float(started["time"]) >= 1.5 - 0.05,
							"Real digestive timer never completes before its unchanged 1.5-second duration")
				for previous: Dictionary in fixture.completions:
					_check(previous["task_id"] != task_id and previous["product_id"] != product_id,
						"Original digestion produces one unique output for each completed task")
				_check(matched and nutrition == 10, "Only a real ten-unit intake creates a production output")
				fixture.completions.append({"task_id": task_id, "chamber_id": chamber_id,
					"product_id": product_id, "nutrition": nutrition, "time": _now()}))
	fixture.veins.edge_upgraded.connect(func(edge: HyphaEdge, before: int, after: int) -> void:
		if fixture.active and not fixture.retiring:
			var snapshot: Dictionary = fixture.veins.get_edge_snapshot(edge)
			_check(int(snapshot.get("grade", -1)) >= after and after == before + 1
				and int(snapshot.get("confirmed_passages", 0)) >= HyphaEdge.VEIN_THRESHOLDS[after - 1],
				"Natural vein upgrades follow confirmed original cargo passages at their unchanged threshold")
			fixture.upgrades.append({"edge_id": edge.get_instance_id(), "before": before,
				"after": after, "confirmed_passages": snapshot.get("confirmed_passages", 0)}))
	fixture.level.connect("resource_access_changed", func(index: int, connected: bool) -> void:
		if fixture.active:
			fixture.access_events.append({"index": index, "connected": connected}))
	fixture.repair.task_changed.connect(func(snapshot: Dictionary) -> void:
		if fixture.active:
			_remember_cost(fixture.repair_costs, "repair", snapshot))
	fixture.level.get_node("World/Remains").child_entered_tree.connect(func(child: Node) -> void:
		if fixture.active and child is EnemyRemains and not child.has_meta("carcass_batch_id"):
			fixture.enemy_drop_nutrition += (child as EnemyRemains).nutrition_value)
	for index: int in range(PACKET_PATHS.size()):
		var kind: String = PACKET_KINDS[index]
		fixture.level.get_node(PACKET_PATHS[index]).child_entered_tree.connect(func(child: Node) -> void:
			if fixture.active and (child is NutrientPacket or child is RemainsPacket):
				_watch_packet(fixture, child as Node2D, kind))
	for weapon: SporeWeapon in fixture.level.call("get_weapons"):
		_watch_weapon(fixture, weapon)
	_sync_workers(fixture)


func _event_economy(fixture: Fixture) -> Dictionary:
	return {"core": fixture.core.nutrition, "construction": fixture.coordinator.get_resource_snapshot(),
		"intake": fixture.stomach.get_queued_nutrition(), "output": fixture.stomach.get_output_nutrition(),
		"first": fixture.first.get_remaining_nutrition(), "second": fixture.second.get_remaining_nutrition(),
		"repair_transit": fixture.repair_supply.get_in_transit_nutrition(),
		"combat_transit": fixture.combat.get_in_transit_count()}


func _watch_weapon(fixture: Fixture, weapon: SporeWeapon) -> void:
	if fixture.watched_weapons.has(weapon.get_instance_id()):
		return
	fixture.watched_weapons[weapon.get_instance_id()] = true
	weapon.get_node("FireTimer").stop()
	weapon.volley_committed.connect(func(_shot_id: String, spent: int, _count: int) -> void:
		if fixture.active:
			fixture.shots_spent += spent)


func _remember_cost(costs: Dictionary, owner: String, snapshot: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		var key: String = "%s:%d" % [owner, task_id]
		costs[key] = maxi(int(costs.get(key, 0)), int(snapshot.get("consumed_nutrition", 0)))


func _remember_worker(fixture: Fixture, worker: ConstructionWorker) -> void:
	if not is_instance_valid(worker) or worker.growth_system == null or worker.cultivation_system == null:
		return
	_remember_cost(fixture.growth_costs, str(worker.get_instance_id()), worker.growth_system.get_task_snapshot())
	var instance_id: int = worker.get_instance_id()
	fixture.organ_costs[instance_id] = maxi(int(fixture.organ_costs.get(instance_id, 0)),
		int(worker.cultivation_system.get_resource_snapshot().get("structure_consumed", 0)))


func _sync_workers(fixture: Fixture) -> void:
	for worker: ConstructionWorker in fixture.coordinator.get_workers(true):
		if not is_instance_valid(worker) or worker.growth_system == null or worker.cultivation_system == null:
			continue
		worker.growth_system.set_physics_process(false)
		worker.cultivation_system.set_physics_process(false)
		worker.growth_supply_system.set_process(false)
		worker.cultivation_supply_system.set_process(false)
		var instance_id: int = worker.get_instance_id()
		if not fixture.workers.has(instance_id):
			fixture.workers[instance_id] = worker.worker_id
			worker.growth_system.task_changed.connect(func(task: Dictionary) -> void:
				if fixture.active:
					_remember_cost(fixture.growth_costs, str(instance_id), task))
			worker.cultivation_system.task_changed.connect(func(_task: Dictionary) -> void:
				if fixture.active:
					_remember_worker(fixture, worker))
			worker.maturation_started.connect(func(construction_id: String) -> void:
				if fixture.active:
					fixture.handoffs[construction_id] = int(fixture.handoffs.get(construction_id, 0)) + 1)
		_remember_worker(fixture, worker)


func _watch_packet(fixture: Fixture, packet: Node2D, kind: String) -> void:
	packet.set_physics_process(false)
	var record: Dictionary = {"packet": weakref(packet), "kind": kind, "distance": 0.0,
		"arrivals": 0, "interruptions": 0, "task_id": "", "cargo_id": "", "generation": -1,
		"target_id": 0, "edges": [], "handles": []}
	fixture.packets[packet.get_instance_id()] = record
	packet.connect("status_changed", func(snapshot: Dictionary) -> void:
		if not fixture.active or not bool(snapshot.get("started", false)):
			return
		if String(record["task_id"]).is_empty():
			record["task_id"] = String(snapshot.get("task_id", ""))
			record["cargo_id"] = String(snapshot.get("cargo_id", ""))
			record["generation"] = int(snapshot.get("cargo_generation", -1))
			var target: Node2D = snapshot.get("final_target") as Node2D
			record["target_id"] = target.get_instance_id() if is_instance_valid(target) else 0
		_check(String(snapshot.get("task_id", "")) == String(record["task_id"])
			and String(snapshot.get("cargo_id", "")) == String(record["cargo_id"])
			and int(snapshot.get("cargo_generation", -1)) == int(record["generation"])
			and int(snapshot.get("traffic_system_id", 0)) == fixture.traffic.get_instance_id(),
			"Physical packets retain their original task, cargo generation and shared traffic owner")
		var edge: HyphaEdge = snapshot.get("edge") as HyphaEdge
		if is_instance_valid(edge) and not (record["edges"] as Array).has(edge.get_instance_id()):
			(record["edges"] as Array).append(edge.get_instance_id())
		if not String(snapshot.get("token", "")).is_empty():
			(record["handles"] as Array).append({"token": String(snapshot["token"]),
				"request_id": String(snapshot.get("request_id", ""))}))
	packet.connect("arrived", func(arrived: Node2D) -> void:
		if not fixture.active:
			return
		record["arrivals"] = int(record["arrivals"]) + 1
		var target: Node2D = instance_from_id(int(record["target_id"])) as Node2D
		_check(int(record["arrivals"]) == 1 and int(record["interruptions"]) == 0
			and is_instance_valid(target) and arrived.global_position.distance_to(target.global_position) < 0.05
			and bool(arrived.call("has_arrived_at", target, String(record["task_id"]))),
			"Every first packet receipt is its actual unique physical arrival at the captured endpoint")
		if kind in ["growth", "cultivation", "remains", "return"]:
			_check(float(record["distance"]) > 0.0 and not (record["edges"] as Array).is_empty(),
				"First construction, corpse and return receipts follow actual nonzero network movement"))
	packet.connect("interrupted", func(_interrupted: Node2D) -> void:
		if fixture.active:
			record["interruptions"] = int(record["interruptions"]) + 1
			_check(int(record["interruptions"]) == 1 and int(record["arrivals"]) == 0,
				"A cancelled physical packet terminates once without an invented receipt"))


func _sum(values: Dictionary) -> int:
	var total: int = 0
	for value: int in values.values():
		total += value
	return total


func _resources(fixture: Fixture) -> Dictionary:
	for worker: ConstructionWorker in fixture.coordinator.get_workers(true):
		_remember_worker(fixture, worker)
	_remember_cost(fixture.repair_costs, "repair", fixture.repair.get_task_snapshot())
	var construction: Dictionary = fixture.coordinator.get_resource_snapshot()
	var repair: Dictionary = fixture.repair.get_task_snapshot()
	var parts: Dictionary = {"core": fixture.core.nutrition, "organ_stock": 0,
		"combat_transit": fixture.combat.get_in_transit_count(),
		"repair_transit": fixture.repair_supply.get_in_transit_nutrition(),
		"repair_buffer": int(repair.get("buffered_nutrition", 0)), "repair_consumed": _sum(fixture.repair_costs),
		"carcass_stock": 0, "ground_remains": 0, "claimed_remains_transit": 0,
		"stomach_intake_including_active": fixture.stomach.get_queued_nutrition(),
		"outputs_including_return_transit": fixture.stomach.get_output_nutrition(),
		"shots_spent": fixture.shots_spent, "isolated_stock_consumed": fixture.fixture_consumed,
		"isolated_escrow": fixture.escrow}
	for field: String in RESOURCE_FIELDS:
		parts[field] = int(construction.get(field, 0))
	for organ: AttackOrgan in fixture.combat.get_registered_organs():
		parts["organ_stock"] = int(parts["organ_stock"]) + organ.nutrition
	for child: Node in fixture.level.get_node("World/Remains").get_children():
		if child.is_queued_for_deletion():
			continue
		if child is LargeCarcass:
			parts["carcass_stock"] = int(parts["carcass_stock"]) + (child as LargeCarcass).get_remaining_nutrition()
		elif child is EnemyRemains:
			var key: String = "ground_remains" if (child as EnemyRemains).is_available() else "claimed_remains_transit"
			parts[key] = int(parts[key]) + (child as EnemyRemains).nutrition_value
	# 预留预算属于 core；紫包引用真实尸块；绿包仍引用真实输出；startup_transferred 已入 organ_stock。
	parts["total"] = _sum(parts)
	return parts


func _checkpoint(fixture: Fixture, phase: String, remember: bool = false) -> void:
	var parts: Dictionary = _resources(fixture)
	var expected: int = fixture.initial_total + fixture.enemy_drop_nutrition
	fixture.last_resources = parts.duplicate(true)
	if int(parts["total"]) != expected and fixture.first_conservation_failure.is_empty():
		fixture.first_conservation_failure = {"phase": phase, "resources": parts.duplicate(true), "expected": expected}
	conservation_checks += 1
	_check(int(parts["total"]) == expected,
		"%s conserves every original source, stock, paid packet, cache, startup, repair and spent unit" % phase)
	var construction: Dictionary = fixture.coordinator.get_resource_snapshot()
	_check(int(construction.get("network_structure", -1)) == _sum(fixture.growth_costs)
		and int(construction.get("organ_structure", -1)) == _sum(fixture.organ_costs),
		"Independent worker/task ledgers match all live and archived construction structure")
	for field: String in RESOURCE_FIELDS:
		_check(construction.has(field) and typeof(construction[field]) == TYPE_INT and int(construction[field]) >= 0,
			"Construction observation exposes its nonnegative original " + field)
	var budget: Dictionary = fixture.core.get_budget_snapshot()
	_check(int(budget["balance"]) == fixture.core.nutrition
		and int(budget["reserved"]) + int(budget["spendable"]) == fixture.core.nutrition,
		"Repair budget partitions the original balance without a second resource bucket")
	if not fixture.retiring:
		_check(fixture.progress.get_total_recovered() == _sum(fixture.receipts)
			and fixture.progress.get_product_count() == fixture.receipts.size()
			and fixture.core.get_received_product_count() == fixture.receipts.size(),
			"Only unique original physical return receipts advance recovered income")
	var digestion: Dictionary = fixture.stomach.get_digestion_snapshot()
	var output: Dictionary = fixture.stomach.get_output_snapshot()
	_check(int(digestion["intake_count"]) == int(digestion["waiting_count"]) + int(digestion["active_count"])
		and fixture.stomach.get_queued_count() + fixture.stomach.incoming_remains <= fixture.stomach.capacity,
		"Real waiting and active intake share the unchanged stomach capacity of four")
	_check(int(output["count"]) + int(output["reserved_count"]) <= 2
		and int(output["nutrition"]) + int(output["reserved_nutrition"]) <= 20,
		"True parallel digestion respects two products and twenty nutrition including active reservations")
	_check(int(output["in_transit_count"]) == fixture.returns.get_in_transit_count()
		and int(fixture.returns.get_return_snapshot()["queued_nutrition"])
			+ fixture.returns.get_in_transit_nutrition() == fixture.stomach.get_output_nutrition(),
		"Queued and traveling green products retain one authoritative output owner")
	fixture.maximum_active = maxi(fixture.maximum_active, int(digestion["active_count"]))
	fixture.maximum_products = maxi(fixture.maximum_products, int(output["count"]))
	fixture.maximum_output_nutrition = maxi(fixture.maximum_output_nutrition, int(output["nutrition"]))
	var snapshot: Dictionary = fixture.coordinator.get_snapshot()
	var tips: int = 0
	var external: int = 0
	for entry: Dictionary in snapshot.get("entries", []):
		tips += 1 if bool(entry.get("occupies_tip_slot", false)) else 0
		external += 1 if bool(entry.get("occupies_external_slot", false)) else 0
	_check(tips == int(snapshot["tip_count"]) and external == int(snapshot["external_count"])
		and tips <= int(snapshot["tip_limit"]) and tips <= 2 and external <= 3,
		"Actual construction ownership respects the live tip capability and external admission cap")
	for entry: Dictionary in snapshot.get("maturing", []):
		_check(entry.get("phase") == &"maturing" and not bool(entry.get("occupies_tip_slot", true))
			and not bool(entry.get("occupies_external_slot", true)),
			"A committed real remote bud releases its external and extension slots during maturation")
	var physical_tips: int = 0
	for child: Node in fixture.level.get_node("World/GrowthTips").get_children():
		if child is GrowthTip and not child.is_queued_for_deletion():
			physical_tips += 1
	_check(physical_tips <= tips and physical_tips <= 2, "No more than two actual original GrowthTip objects exist")
	var confirmed: Dictionary = {}
	for passage: Dictionary in fixture.tracker.get_confirmed_passages():
		var edge_ref: WeakRef = passage.get("edge_ref") as WeakRef
		var edge: HyphaEdge = edge_ref.get_ref() as HyphaEdge if edge_ref != null else null
		if is_instance_valid(edge):
			confirmed[edge.get_instance_id()] = int(confirmed.get(edge.get_instance_id(), 0)) + 1
	for edge: HyphaEdge in fixture.network.get_registered_edges():
		var vein: Dictionary = fixture.veins.get_edge_snapshot(edge)
		var traffic: Dictionary = fixture.traffic.get_edge_snapshot(edge)
		if not edge.has_endpoints():
			var retained: Dictionary = edge.get_vein_snapshot()
			var retained_count: int = int(retained["confirmed_passages"])
			var retained_grade: int = 2 if retained_count >= 60 else (1 if retained_count >= 20 else 0)
			_check(retained_count == int(fixture.confirmed_history.get(edge.get_instance_id(), 0))
				and int(retained["grade"]) == retained_grade
				and edge.traffic_capacity == HyphaEdge.VEIN_CAPACITIES[retained_grade]
				and not bool(traffic["exists"]) and int(traffic["occupied_units"]) == 0,
				"A temporarily severed edge retains its previously proven natural growth without usable traffic")
			continue
		var grade: int = int(vein.get("grade", -1))
		var count: int = int(vein.get("confirmed_passages", -1))
		var expected_grade: int = 2 if count >= 60 else (1 if count >= 20 else 0)
		_check(grade == expected_grade and count == int(confirmed.get(edge.get_instance_id(), 0))
			and edge.traffic_capacity == HyphaEdge.VEIN_CAPACITIES[expected_grade],
			"Every natural edge grade and capacity matches its actual unique confirmed cargo passages")
		_check(int(traffic.get("capacity", -1)) == edge.traffic_capacity
			and int(traffic.get("occupied_units", 0)) <= edge.traffic_capacity,
			"The shared physical FIFO uses each naturally grown edge's actual capacity")
		fixture.confirmed_history[edge.get_instance_id()] = count
		if int(traffic.get("occupied_units", 0)) >= 3:
			fixture.high_capacity = {"edge_id": edge.get_instance_id(), "grade": grade,
				"confirmed_passages": count, "capacity": edge.traffic_capacity,
				"occupied_units": int(traffic["occupied_units"])}
	if remember:
		fixture.checkpoints.append({"phase": phase, "resources": parts, "expected": expected,
			"recovered": fixture.progress.get_total_recovered(), "tip_count": tips,
			"external_count": external, "maturing_count": snapshot.get("maturing_count", 0)})


func _fund(fixture: Fixture) -> int:
	var before: Dictionary = {}
	for worker: ConstructionWorker in fixture.coordinator.get_workers(true):
		before[worker.get_instance_id()] = _paid_count(worker)
	var balance: int = fixture.core.nutrition
	fixture.funding = true
	var paid: int = fixture.scheduler.dispatch_round()
	fixture.funding = false
	var actual: int = 0
	for worker: ConstructionWorker in fixture.coordinator.get_workers(true):
		var delta: int = _paid_count(worker) - int(before.get(worker.get_instance_id(), 0))
		_check(delta >= 0 and delta <= 1, "Each original construction group pays at most one packet per round")
		actual += delta
	_check(paid == actual and balance - fixture.core.nutrition == actual,
		"Original scheduler reporting equals real one-unit debits without hidden extra payments")
	return paid


func _paid_count(worker: ConstructionWorker) -> int:
	var total: int = 0
	for supply: Node in [worker.growth_supply_system, worker.cultivation_supply_system]:
		for shipment: Dictionary in supply.call("get_shipment_records"):
			total += 1 if bool(shipment.get("debited", false)) else 0
	return total


func _step(fixture: Fixture, fund: bool = false, collect: bool = false,
		return_output: bool = false, ceilings: Dictionary = {}) -> void:
	fixture.coordinator.pump()
	_sync_workers(fixture)
	if fund:
		_fund(fixture)
	if collect:
		for _slot: int in range(4):
			if not fixture.recycling.try_dispatch():
				break
	if return_output:
		for _slot: int in range(2):
			if not fixture.returns.try_dispatch():
				break
	fixture.traffic.refresh()
	for index: int in range(PACKET_PATHS.size()):
		var kind: String = PACKET_KINDS[index]
		for child: Node in fixture.level.get_node(PACKET_PATHS[index]).get_children():
			if child.is_queued_for_deletion() or not (child is NutrientPacket or child is RemainsPacket):
				continue
			var packet: Node2D = child as Node2D
			var expected_speed: float = 140.0 if kind == "remains" else (80.0 if kind == "return" else 150.0)
			_check(is_equal_approx(float(packet.get("speed")), expected_speed)
				and bool(packet.get("traffic_required")), "Original packet speed and shared traffic requirement are unchanged")
			var record: Dictionary = fixture.packets.get(packet.get_instance_id(), {})
			var previous: Vector2 = packet.global_position
			packet.call("_physics_process", STEP)
			if is_instance_valid(packet) and not record.is_empty():
				record["distance"] = float(record["distance"]) + previous.distance_to(packet.global_position)
	for worker: ConstructionWorker in fixture.coordinator.get_workers(true):
		worker.growth_system.advance(STEP)
		var task: Dictionary = worker.cultivation_system.get_task_snapshot()
		var construction_id: String = String(worker.get_snapshot().get("construction_id", ""))
		var delta: float = STEP
		if ceilings.has(construction_id):
			delta = minf(STEP, maxf(0.0, float(ceilings[construction_id]) - float(task.get("effective_time", 0.0))))
		if delta > 0.0:
			worker.cultivation_system.advance(delta)
		worker.growth_supply_system.call("_process", 0.0)
		worker.cultivation_supply_system.call("_process", 0.0)
	fixture.repair.advance(STEP)
	fixture.repair_supply.refresh_budget()
	fixture.level.call("_process", 0.0)
	fixture.field.advance(STEP)
	fixture.level.call("_process", 0.0)
	await physics_frame
	await process_frame
	fixture.coordinator.pump()
	_sync_workers(fixture)
	sampled_steps += 1
	if fixture.active:
		_checkpoint(fixture, "continuous_cycle")
	if sampled_steps >= RUN_STEP_LIMIT:
		_check(false, "Progression cycle exceeded its bounded global step budget")
		_finish()


func _until(fixture: Fixture, predicate: Callable, message: String, fund: bool = false,
		collect: bool = false, return_output: bool = false, ceilings: Dictionary = {}) -> bool:
	for _iteration: int in range(STEP_LIMIT):
		if bool(predicate.call()):
			break
		await _step(fixture, fund, collect, return_output, ceilings)
	var reached: bool = bool(predicate.call())
	_check(reached, message)
	_checkpoint(fixture, message, true)
	return reached


func _wait_seconds(fixture: Fixture, seconds: float, return_output: bool = false) -> void:
	var started: float = _now()
	await _until(fixture, func() -> bool: return _now() - started >= seconds,
		"Bounded original physics timers reach %.2f seconds" % seconds, false, false, return_output)


func _admit(fixture: Fixture, kind: StringName, origin: HyphaNode, target: Vector2) -> String:
	var result: Dictionary = fixture.coordinator.enqueue(kind, {"start_node": origin, "target_position": target})
	var construction_id: String = String(result.get("construction_id", ""))
	_check(bool(result.get("accepted", false)) and not construction_id.is_empty(),
		"Original admission accepts one stable " + String(kind) + " identity")
	fixture.coordinator.pump()
	_sync_workers(fixture)
	return construction_id


func _growth(fixture: Fixture, construction_id: String) -> Dictionary:
	var worker: ConstructionWorker = fixture.coordinator.get_worker(construction_id)
	return {} if worker == null else worker.growth_system.get_task_snapshot()


func _identity(request: Dictionary) -> Dictionary:
	return {"id": request.get("construction_id", ""), "kind": request.get("kind", &""),
		"sequence": request.get("sequence", 0), "parameters": request.get("parameters", {}).duplicate(true),
		"payer_id": request.get("payer_id", 0), "worker_id": request.get("worker_id", 0),
		"internal_ids": request.get("internal_ids", {}).duplicate(true)}


func _access(fixture: Fixture, index: int) -> bool:
	var resources: Array = fixture.level.call("get_resource_access_snapshot")
	return resources.size() >= index and bool((resources[index - 1] as Dictionary).get("connected", false))


func _recover_batch(fixture: Fixture, expected_total: int) -> bool:
	var before: int = fixture.progress.get_total_recovered()
	var before_stage: ColonyProgress.Stage = fixture.progress.get_stage()
	var balance: int = fixture.core.nutrition
	_check(fixture.stomach.get_queued_count() == 0 and fixture.stomach.get_output_count() == 0,
		"Each threshold observation starts with no hidden digestive products")
	_check(fixture.recycling.try_dispatch(), "An accessible original carcass dispatches a real batch")
	if not await _until(fixture, func() -> bool: return fixture.stomach.get_output_count() == 1,
		"Actual corpse movement and original digestion produce the next ten-unit product"):
		return false
	_check(fixture.progress.get_total_recovered() == before and fixture.progress.get_stage() == before_stage
		and fixture.core.nutrition == balance, "Harvest and digestion cannot unlock a stage before green arrival")
	var product: Dictionary = fixture.stomach.get_output_products()[0]
	var product_id: String = String(product["product_id"])
	_check(int(product["nutrition"]) == 10 and fixture.returns.try_dispatch(),
		"The real original product enters its green physical return")
	_check(fixture.returns.get_in_transit_count() == 1 and fixture.progress.get_total_recovered() == before
		and fixture.core.nutrition == balance, "Actual in-flight nutrition cannot advance the growth stage")
	if not await _until(fixture, func() -> bool: return fixture.progress.get_total_recovered() == expected_total,
		"Only the actual green packet arrival reaches recovered %d" % expected_total):
		return false
	_check(fixture.core.nutrition == balance + 10 and fixture.receipts.get(product_id, 0) == 10,
		"Each actual return adds exactly its own ten units without stage rewards")
	_check(not fixture.core.accept_digestion_product(product_id, 10)
		and fixture.core.nutrition == balance + 10 and fixture.progress.get_total_recovered() == expected_total,
		"Replaying an already physically received product cannot credit it twice")
	return true


func _full_cycle(fixture: Fixture) -> bool:
	var planner: GrowthPlanner = fixture.level.get("growth_planner") as GrowthPlanner
	var first_plan: Dictionary = planner.plan(fixture.right.global_position, FIRST_TARGET)
	var second_plan: Dictionary = planner.plan(fixture.left.global_position, SECOND_TARGET)
	_check(int(first_plan["total_cost"]) == 11 and int(second_plan["total_cost"]) == 16,
		"Original GrowthPlanner confirms first G11/B23 and second G16/B28 costs")
	_check(not _access(fixture, 1) and not _access(fixture, 2) and not fixture.recycling.try_dispatch(),
		"Both original large carcasses start outside usable collecting routes")
	var first_id: String = _admit(fixture, &"remote_cultivation", fixture.right, FIRST_TARGET)
	var first_worker: ConstructionWorker = fixture.coordinator.get_worker(first_id)
	if first_worker == null:
		_check(false, "Missing prerequisite: first formal B must create its real original worker")
		return false
	var first_identity: Dictionary = _identity(fixture.queue.get_request(first_id))
	_check(_fund(fixture) == 1 and fixture.coordinator.pause_request(first_id),
		"The single initial tip pauses with one original paid physical packet")
	if not await _until(fixture, func() -> bool:
		return first_worker.growth_supply_system.get_in_transit_count() == 0,
		"Original first payment physically arrives while its nascent tip is paused"):
		return false
	var paused: Dictionary = _growth(fixture, first_id)
	_check(int(paused.get("buffered_nutrition", 0)) == 1 and is_zero_approx(float(paused.get("distance", 0.0)))
		and _identity(fixture.queue.get_request(first_id)) == first_identity
		and fixture.progress.get_total_recovered() == 0
		and int(fixture.coordinator.get_snapshot()["tip_limit"]) == 1,
		"Paid cache, initial capital and a paused tip cannot count as recovered growth")
	_check(fixture.coordinator.resume_request(first_id), "Original first tip resumes its preserved worker and task")
	if not await _until(fixture, func() -> bool: return fixture.matured.has(first_id) and _access(fixture, 1),
		"Actual first B completes growth, original cultivation and the first collecting route", true):
		return false
	_check(fixture.core.nutrition == CAPITAL - 23 and fixture.progress.get_total_recovered() == 0
		and int(fixture.coordinator.get_resource_snapshot()["network_structure"]) == 11
		and int(fixture.coordinator.get_resource_snapshot()["organ_structure"]) == 8
		and int(fixture.coordinator.get_resource_snapshot()["startup_transferred"]) == 4,
		"Original first B pays exactly eleven structure plus eight organ and four startup stock")
	for batch: int in range(1, 6):
		if not await _recover_batch(fixture, batch * 10):
			return false
		_check(fixture.progress.get_stage() == ColonyProgress.Stage.NASCENT
			and int(fixture.coordinator.get_snapshot()["tip_limit"]) == 1,
			"Below sixty true recovered units the second extension tip remains locked")
	var second_id: String = _admit(fixture, &"remote_cultivation", fixture.left, SECOND_TARGET)
	var parallel_id: String = _admit(fixture, &"remote_cultivation", fixture.right, PARALLEL_TARGET)
	var third_id: String = _admit(fixture, &"growth", fixture.left, WAITING_TARGET)
	var second_worker: ConstructionWorker = fixture.coordinator.get_worker(second_id)
	if second_worker == null:
		_check(false, "The real second-resource goal must allocate its nascent worker")
		return false
	_check(int(fixture.coordinator.get_snapshot()["external_count"]) == 3
		and int(fixture.coordinator.get_snapshot()["tip_count"]) == 1
		and not fixture.queue.get_request(parallel_id).get("started", true)
		and not fixture.queue.get_request(third_id).get("started", true),
		"At fifty real recovered units only one of three admitted goals owns a tip")
	var rejected: Dictionary = fixture.coordinator.enqueue(&"growth", {
		"start_node": fixture.right, "target_position": Vector2(1080, 280)})
	_check(not bool(rejected.get("accepted", true)) and rejected.get("reason") == &"queue_full",
		"A fourth external goal cannot exceed the unchanged original cap of three")
	_check(_fund(fixture) == 1 and fixture.coordinator.pause_request(second_id),
		"The second resource's original paid packet can buffer under an actual paused tip")
	if not await _until(fixture, func() -> bool:
		return second_worker.growth_supply_system.get_in_transit_count() == 0,
		"Second-resource paused payment physically arrives before the sixty-unit receipt"):
		return false
	var preserved: Dictionary = _identity(fixture.queue.get_request(second_id))
	var second_paused: Dictionary = _growth(fixture, second_id).duplicate(true)
	if not await _recover_batch(fixture, 60):
		return false
	fixture.coordinator.pump()
	_sync_workers(fixture)
	var parallel_worker: ConstructionWorker = fixture.coordinator.get_worker(parallel_id)
	_check(fixture.progress.get_stage() == ColonyProgress.Stage.EXPANDED
		and fixture.capabilities.get_extension_tip_limit() == 2
		and int(fixture.coordinator.get_snapshot()["tip_limit"]) == 2
		and int(fixture.coordinator.get_snapshot()["tip_count"]) == 2
		and fixture.queue.get_request(parallel_id).get("started", false)
		and not fixture.queue.get_request(third_id).get("started", true)
		and _identity(fixture.queue.get_request(second_id)) == preserved
		and _growth(fixture, second_id) == second_paused,
		"The sixth true return unlocks a second worker beside the unchanged original paused tip")
	if parallel_worker == null:
		_check(false, "Missing prerequisite: actual sixty-unit capability must create the second independent worker")
		return false
	_check(second_worker != parallel_worker and second_worker.worker_id != parallel_worker.worker_id,
		"Both actual moving directions have independent permanent worker identities")
	_check(fixture.coordinator.resume_request(second_id), "The old paused tip resumes after the true capability unlock")
	var ceilings: Dictionary = {second_id: 0.5, parallel_id: 0.5}
	if not await _until(fixture, func() -> bool:
		return float(_growth(fixture, second_id).get("distance", 0.0)) > 0.0 \
			and float(_growth(fixture, parallel_id).get("distance", 0.0)) > 0.0,
		"Two real tips simultaneously move using actual arrived nutrition", true, false, false, ceilings):
		return false
	for construction_id: String in [second_id, parallel_id]:
		var worker: ConstructionWorker = fixture.coordinator.get_worker(construction_id)
		var growth: Dictionary = _growth(fixture, construction_id)
		var tip: Node2D = worker.growth_system.get_delivery_target(int(growth["task_id"]))
		var origin: HyphaNode = fixture.queue.get_request(construction_id)["parameters"]["start_node"] as HyphaNode
		_check(tip is GrowthTip and tip.global_position.distance_to(origin.global_position) > 0.0
			and int(growth["consumed_nutrition"]) > 0,
			"Each simultaneous tip is an original moving object funded by its own real payment")
	_check(not fixture.queue.get_request(third_id).get("started", true),
		"A third admitted goal waits while both actual extension slots are occupied")
	if not await _until(fixture, func() -> bool:
		return float(_growth(fixture, parallel_id).get("distance", 0.0)) >= 120.0 \
			and int(_growth(fixture, parallel_id).get("requested_nutrition", 0)) >= 3,
		"Parallel original growth reaches its real unpaid four-unit junction", true, false, false, ceilings):
		return false
	# 第一 B 的 23 个实际付款已自然加粗共同路线；继续原派包，不改容量或通行历史。
	for _round: int in range(4):
		_fund(fixture)
	_checkpoint(fixture, "natural_capacity_with_original_paid_fifo", true)
	_check(not fixture.upgrades.is_empty() and not fixture.high_capacity.is_empty(),
		"Natural confirmed cargo upgrades admit at least three actual units on the shared FIFO")
	_check(fixture.coordinator.pause_request(parallel_id),
		"Pausing the independent moving tip preserves its slot during the other goal's real handoff")
	if not await _until(fixture, func() -> bool:
		return fixture.queue.get_request(second_id).get("phase") == &"maturing" \
			and fixture.queue.get_request(third_id).get("started", false),
		"Actual second-resource B handoff releases a slot and starts the waiting third goal", true, false, false, ceilings):
		return false
	var handoff: Dictionary = fixture.queue.get_request(second_id)
	var remote: Dictionary = second_worker.remote_cultivation_system.get_request_snapshot()
	var host: HyphaNode = remote.get("endpoint") as HyphaNode
	_check(is_instance_valid(host) and host.global_position.distance_to(SECOND_TARGET) < 0.05
		and host == second_worker.growth_system.get_completed_endpoint(int(handoff["internal_ids"]["growth_task_id"]))
		and remote.get("extension_released", false) and second_worker.cultivation_system.has_active_task()
		and not handoff.get("occupies_tip_slot", true) and not handoff.get("occupies_external_slot", true)
		and int(fixture.coordinator.get_snapshot()["maturing_count"]) >= 1
		and int(fixture.handoffs.get(second_id, 0)) == 1,
		"Only committed original growth and its accepted real cultivation bud release both B slots")
	_check(fixture.coordinator.get_worker(second_id) == second_worker
		and fixture.queue.get_request(third_id).get("occupies_tip_slot", false)
		and fixture.queue.get_request(parallel_id).get("state") == &"paused",
		"Handoff preserves its original worker and admits the third goal beside the paused second tip")
	_check(fixture.coordinator.resume_request(parallel_id), "The independent paused task resumes through its captured identity")
	if not await _until(fixture, func() -> bool:
		return fixture.matured.has(second_id) and fixture.matured.has(parallel_id) \
			and fixture.finished.get(third_id) == &"completed" and _access(fixture, 2),
		"Original parallel B maturation and third growth finish with the second real resource connected", true):
		return false
	_check(fixture.progress.get_total_recovered() == 60 and fixture.stomach.get_digestion_snapshot()["chamber_count"] == 1,
		"Construction completion alone cannot force mature progression or a second stomach chamber")
	evidence.append({"case": "real_two_tip_admission_and_maturation_handoff", "recovered": 60,
		"first_construction_id": first_id, "second_construction_id": second_id,
		"parallel_construction_id": parallel_id, "waiting_third_id": third_id,
		"second_worker_id": second_worker.worker_id, "parallel_worker_id": parallel_worker.worker_id,
		"second_growth_cost": 16, "second_remote_cost": 28,
		"natural_capacity": fixture.high_capacity.duplicate(), "access_events": fixture.access_events.duplicate(true)})
	for batch: int in range(7, 17):
		if not await _recover_batch(fixture, batch * 10):
			return false
		if batch < 16:
			_check(fixture.progress.get_stage() == ColonyProgress.Stage.EXPANDED
				and not fixture.capabilities.can_expand_second_digestive_chamber()
				and fixture.stomach.get_digestion_snapshot()["chamber_count"] == 1,
				"Through 150 actual recovered units the real second chamber remains locked")
	var expansion_started: float = _now()
	var expansion: Dictionary = fixture.stomach.get_digestion_snapshot()
	_check(fixture.progress.get_stage() == ColonyProgress.Stage.MATURE
		and fixture.progress.get_total_recovered() == 160
		and fixture.capabilities.can_expand_second_digestive_chamber()
		and expansion["expansion_state"] == &"expanding" and expansion["chamber_count"] == 1
		and float(expansion["expansion_remaining"]) >= 2.9,
		"The sixteenth actual return unlocks maturity and begins the original three-second expansion")
	var before_expansion: Dictionary = _resources(fixture)
	await _wait_seconds(fixture, 2.5)
	_check(fixture.stomach.get_digestion_snapshot()["expansion_state"] == &"expanding"
		and fixture.stomach.get_digestion_snapshot()["chamber_count"] == 1,
		"A mature stage still exposes only one functioning chamber before the real timer finishes")
	if not await _until(fixture, func() -> bool:
		return fixture.stomach.get_digestion_snapshot()["expansion_state"] == &"ready",
		"The original expansion timer makes the second chamber genuinely ready"):
		return false
	var expansion_elapsed: float = _now() - expansion_started
	_check(expansion_elapsed >= DigestiveOrgan.EXPANSION_DURATION - 0.05
		and fixture.stomach.get_digestion_snapshot()["chamber_count"] == 2
		and _resources(fixture) == before_expansion,
		"Real three-second chamber expansion changes capability without creating or consuming resources")
	if not await _dual_and_disconnect(fixture):
		return false
	_check(fixture.progress.get_total_recovered() == SOURCE_TOTAL
		and fixture.first.get_harvested_nutrition() == 80 and fixture.second.get_harvested_nutrition() == 120
		and fixture.first.get_remaining_nutrition() == 0 and fixture.second.get_remaining_nutrition() == 0
		and fixture.transitions == [Vector2i(0, 1), Vector2i(1, 2)]
		and fixture.unlocks == [ColonyProgress.Stage.EXPANDED, ColonyProgress.Stage.MATURE],
		"All two hundred original carcass units traverse the real cycle and each threshold unlocks exactly once")
	_checkpoint(fixture, "full_original_200_cycle_complete", true)
	evidence.append({"case": "full_original_progression_cycle", "initial_capital": CAPITAL,
		"initial_organs": fixture.initial_stock, "original_carcasses": [80, 120],
		"recovered": fixture.progress.get_total_recovered(), "real_receipts": fixture.receipts.size(),
		"real_digestion_tasks": fixture.starts.size(), "real_outputs": fixture.completions.size(),
		"expansion_elapsed_seconds": expansion_elapsed,
		"stage_transitions": [[0, 1], [1, 2]], "natural_upgrades": fixture.upgrades.duplicate(true),
		"max_active_chambers": fixture.maximum_active, "max_products": fixture.maximum_products,
		"max_output_nutrition": fixture.maximum_output_nutrition,
		"enemy_drop_nutrition": fixture.enemy_drop_nutrition, "combat_shots_spent": fixture.shots_spent,
		"resources": _resources(fixture), "checkpoints": fixture.checkpoints.duplicate(true)})
	return true


func _dual_and_disconnect(fixture: Fixture) -> bool:
	var before: int = fixture.progress.get_total_recovered()
	var before_balance: int = fixture.core.nutrition
	var before_completed: int = fixture.completions.size()
	if not await _until(fixture, func() -> bool:
		return fixture.stomach.get_queued_count() == 4 and fixture.stomach.incoming_remains == 0,
		"Four remaining original ten-unit batches physically fill the unchanged stomach intake", false, true):
		return false
	var digestion: Dictionary = fixture.stomach.get_digestion_snapshot()
	var active: Array[Dictionary] = []
	for chamber: Dictionary in digestion["chambers"]:
		if not String(chamber["task_id"]).is_empty():
			active.append(chamber)
	_check(int(digestion["active_count"]) == 2 and active.size() == 2
		and active[0]["task_id"] != active[1]["task_id"]
		and active[0]["input_id"] != active[1]["input_id"]
		and fixture.stomach.get_output_snapshot()["reserved_count"] == 2
		and fixture.stomach.get_output_snapshot()["reserved_nutrition"] == 20,
		"Two true digestive tasks independently own real inputs and reserve the exact output boundary")
	if active.size() != 2:
		return false
	# 正式地图有两条母核入口；同时断开两条原边，不能留下备用回流路径。
	var core_edges: Array[HyphaEdge] = [
		fixture.level.get_node("World/Colony/Connections/HyphaEdge") as HyphaEdge,
		fixture.level.get_node("World/Colony/Connections/DigestionEdge") as HyphaEdge,
	]
	var endpoints: Array[Node2D] = []
	for edge: HyphaEdge in core_edges:
		endpoints.append(edge.end_node)
		edge.end_node = null
	await _wait_seconds(fixture, 2.0, true)
	var blocked: Dictionary = fixture.stomach.get_output_snapshot()
	_check(fixture.completions.size() == before_completed + 2 and int(blocked["count"]) == 2
		and int(blocked["nutrition"]) == 20 and int(blocked["reserved_count"]) == 0
		and fixture.stomach.get_digestion_snapshot()["active_count"] == 0
		and fixture.stomach.get_waiting_count() == 2 and fixture.stomach.get_queued_nutrition() == 20,
		"True disconnected dual digestion stops at two products and twenty units while preserving waiting intake")
	_check(fixture.core.nutrition == before_balance and fixture.progress.get_total_recovered() == before
		and fixture.returns.get_in_transit_count() == 0
		and fixture.returns.get_return_snapshot()["wait_reason"] == &"disconnected",
		"A genuinely disconnected core cannot credit or claim the bounded real output")
	var product_ids: Array[String] = []
	for product: Dictionary in fixture.stomach.get_output_products():
		product_ids.append(String(product["product_id"]))
	for index: int in range(core_edges.size()):
		core_edges[index].end_node = endpoints[index]
	fixture.level.call("_process", 0.0)
	fixture.field.advance(1.0)
	_check(fixture.returns.try_dispatch() and fixture.returns.try_dispatch()
		and fixture.returns.get_in_transit_count() == 2,
		"Restored original routes launch both retained products as real green packets")
	for product: Dictionary in fixture.stomach.get_output_products():
		_check(product_ids.has(String(product["product_id"])) and product["status"] == &"in_transit",
			"Disconnect and reconnect preserve each original output product identity and ownership")
	await _step(fixture)
	_check(fixture.core.nutrition == before_balance and fixture.stomach.get_output_nutrition() == 20
		and fixture.stomach.get_output_snapshot()["reserved_count"] == 0,
		"Actual in-flight products retain both bounded output slots before arrival")
	if not await _until(fixture, func() -> bool: return fixture.progress.get_total_recovered() == before + 20,
		"Both originally retained output identities arrive through their true green packets"):
		return false
	_check(fixture.stomach.get_digestion_snapshot()["active_count"] == 2
		and fixture.stomach.get_output_snapshot()["reserved_count"] == 2
		and fixture.stomach.get_output_snapshot()["reserved_nutrition"] == 20,
		"Only real return settlement frees output capacity and resumes both retained intake tasks")
	if not await _until(fixture, func() -> bool: return fixture.progress.get_total_recovered() == before + 40,
		"Reconnected true dual digestion returns all forty remaining original units", false, false, true):
		return false
	_check(fixture.core.nutrition == before_balance + 40 and fixture.stomach.get_queued_count() == 0
		and fixture.stomach.get_output_count() == 0 and fixture.returns.get_in_transit_count() == 0,
		"Real disconnect recovery leaves no orphan intake, output, packet or credited resource")
	evidence.append({"case": "real_dual_digestion_disconnect_reconnect", "active_inputs": 2,
		"dispatch_isolation": "return_dispatch_held_to_observe_real_output_backpressure",
		"physical_module_step_seconds": STEP, "digestion_timer_seconds": 1.5,
		"distinct_task_ids": [active[0]["task_id"], active[1]["task_id"]],
		"retained_product_ids": product_ids, "blocked_output_count": 2,
		"blocked_output_nutrition": 20, "retained_waiting_nutrition": 20, "recovered_after_reconnect": 40})
	return true


func _cancel_identity(fixture: Fixture) -> bool:
	var cancelled_id: String = _admit(fixture, &"growth", fixture.left, Vector2(280, 620))
	var survivor_id: String = _admit(fixture, &"growth", fixture.right, Vector2(1090, 260))
	var cancelled: ConstructionWorker = fixture.coordinator.get_worker(cancelled_id)
	var survivor: ConstructionWorker = fixture.coordinator.get_worker(survivor_id)
	if cancelled == null or survivor == null:
		_check(false, "Cancellation fixture requires two actual independently admitted workers")
		return false
	_check(_fund(fixture) == 2 and fixture.coordinator.pause_request(cancelled_id),
		"Cancellation fixture pays both original workers and pauses only its intended tip")
	if not await _until(fixture, func() -> bool:
		return cancelled.growth_supply_system.get_in_transit_count() == 0 \
			and survivor.growth_supply_system.get_in_transit_count() == 0,
		"Cancellation fixture obtains an actually delivered unused cache"):
		return false
	_check(int(cancelled.get_resource_snapshot()["growth_buffer"]) == 1
		and is_zero_approx(float(_growth(fixture, cancelled_id).get("distance", 0.0))),
		"Cancellation cache comes from a physical arrival while the original tip is paused")
	_check(fixture.coordinator.resume_request(cancelled_id) and _fund(fixture) == 2
		and fixture.coordinator.pause_request(cancelled_id),
		"Original resumed demand launches another real paid packet before cancellation")
	var own: Dictionary = cancelled.get_resource_snapshot()
	var other: Dictionary = survivor.get_resource_snapshot().duplicate(true)
	var survivor_identity: Dictionary = _identity(fixture.queue.get_request(survivor_id))
	var balance: int = fixture.core.nutrition
	var unused: int = int(own["growth_buffer"]) + int(own["growth_transit"])
	var structure: int = int(fixture.coordinator.get_resource_snapshot()["network_structure"])
	_check(unused == 2 and int(own["growth_buffer"]) == 1 and int(own["growth_transit"]) == 1,
		"Actual cancellation owns one physically delivered cache and one original paid in-flight unit")
	_check(fixture.coordinator.cancel_request(cancelled_id)
		and fixture.core.nutrition == balance + unused
		and int(fixture.coordinator.get_resource_snapshot()["network_structure"]) == structure,
		"Cancel refunds exactly the intended cache and transit while preserving all consumed structure")
	_check(fixture.coordinator.get_worker(survivor_id) == survivor
		and survivor.get_resource_snapshot() == other
		and _identity(fixture.queue.get_request(survivor_id)) == survivor_identity,
		"Cancelling one task cannot replace its peer's identity, payer or resource ownership")
	var after_cancel: int = fixture.core.nutrition
	_check(not fixture.coordinator.cancel_request(cancelled_id) and fixture.core.nutrition == after_cancel,
		"Repeated cancellation cannot refund the same original shipment twice")
	if not await _until(fixture, func() -> bool:
		return survivor.growth_supply_system.get_in_transit_count() == 0 \
			and float(_growth(fixture, survivor_id).get("distance", 0.0)) > 0.0,
		"The preserved independent original tip continues actual movement after peer cancellation"):
		return false
	var peer_resources: Dictionary = survivor.get_resource_snapshot()
	var peer_unused: int = int(peer_resources["growth_buffer"]) + int(peer_resources["growth_transit"])
	var peer_balance: int = fixture.core.nutrition
	_check(fixture.coordinator.cancel_request(survivor_id) and fixture.core.nutrition == peer_balance + peer_unused,
		"The surviving actual tip later refunds only its own unused nutrition")
	_checkpoint(fixture, "actual_cancel_identity_and_conservation", true)
	evidence.append({"case": "actual_cancel_identity_and_conservation", "cancelled_id": cancelled_id,
		"surviving_id": survivor_id, "actual_cached_refund": int(own["growth_buffer"]),
		"actual_transit_refund": int(own["growth_transit"]), "survivor_unused_refund": peer_unused,
		"recovered_unchanged": fixture.progress.get_total_recovered(), "resources": _resources(fixture)})
	return true


func _escrow_withdraw(fixture: Fixture, target_balance: int) -> void:
	var amount: int = fixture.core.nutrition - target_balance
	_check(amount > 0 and fixture.core.try_spend_nutrition(amount),
		"Isolated low-balance fixture withdraws only previously owned spendable original core funds")
	if amount > 0 and fixture.core.nutrition == target_balance:
		fixture.escrow += amount


func _escrow_release(fixture: Fixture, amount: int) -> void:
	_check(amount > 0 and amount <= fixture.escrow,
		"Isolated escrow release must own every returned original unit")
	if amount <= 0 or amount > fixture.escrow:
		return
	fixture.escrow -= amount
	fixture.core.add_nutrition(amount)


func _isolated_budget(fixture: Fixture) -> bool:
	var first_id: String = _admit(fixture, &"growth", fixture.left, Vector2(240, 600))
	var second_id: String = _admit(fixture, &"growth", fixture.right, Vector2(1080, 580))
	var first: ConstructionWorker = fixture.coordinator.get_worker(first_id)
	var second: ConstructionWorker = fixture.coordinator.get_worker(second_id)
	if first == null or second == null:
		_check(false, "Isolated shared-budget fixture must allocate two real demand-bearing workers")
		return false
	var organ: AttackOrgan = fixture.left.get_node("AttackOrgan") as AttackOrgan
	var stock: int = organ.nutrition
	_check(stock > 0 and organ.consume_nutrition(stock),
		"Isolated budget fixture creates refill demand by explicitly consuming actual existing organ stock")
	fixture.fixture_consumed += stock
	var repair_edge: HyphaEdge = fixture.level.get_node("World/Colony/Connections/HyphaEdge") as HyphaEdge
	repair_edge.take_damage(20.0)
	var missing_health: float = maxf(repair_edge.max_health - repair_edge.health, 0.0)
	var quote: Dictionary = fixture.repair.preview_repair(repair_edge)
	var quoted_cost: int = int(quote.get("estimated_cost", 0))
	var expected_cost: int = ceili(missing_health / RepairSystem.HEALTH_PER_NUTRITION)
	_check(bool(quote.get("valid", false)) and missing_health > 0.0 and quoted_cost > 0
		and quoted_cost == expected_cost and is_equal_approx(float(quote.get("missing_health", -1.0)), missing_health),
		"Original repair quote exactly prices the live pre-request missing health at its unchanged material rate")
	var repair_id: int = fixture.repair.request_repair(repair_edge)
	fixture.repair_supply.refresh_budget()
	var repair_reserve: int = int(fixture.repair_supply.get_supply_snapshot()["reserved_nutrition"])
	var combat_reserve: int = first.growth_supply_system.get_combat_reserve()
	_check(repair_id > 0 and repair_reserve == quoted_cost and repair_reserve > 0 and combat_reserve == 2
		and second.growth_supply_system.get_combat_reserve() == combat_reserve,
		"Original repair reserves its exact quoted material and both workers protect the same two-shot combat stock")
	var recovered: int = fixture.progress.get_total_recovered()
	_escrow_withdraw(fixture, repair_reserve + combat_reserve + 1)
	_checkpoint(fixture, "isolated_low_balance_conserved_escrow", true)
	var successful: Dictionary = {first_id: 0, second_id: 0}
	for round_index: int in range(4):
		if round_index > 0:
			_escrow_release(fixture, 1)
		if not await _until(fixture, func() -> bool:
			return first.growth_supply_system.can_dispatch_scheduled(fixture.scheduler) \
				and second.growth_supply_system.can_dispatch_scheduled(fixture.scheduler),
			"Both original budget workers expose demand before isolated effective round %d" % round_index):
			return false
		var first_before: int = _paid_count(first)
		var second_before: int = _paid_count(second)
		_check(first.growth_supply_system.get_available_growth_nutrition() == 1
			and second.growth_supply_system.get_available_growth_nutrition() == 1,
			"Both actual workers see the same single unit above the shared protected budgets")
		_check(_fund(fixture) == 1, "One conserved spendable unit pays exactly one real worker in an effective round")
		successful[first_id] = int(successful[first_id]) + _paid_count(first) - first_before
		successful[second_id] = int(successful[second_id]) + _paid_count(second) - second_before
		_check(fixture.core.nutrition == repair_reserve + combat_reserve
			and int(fixture.core.get_budget_snapshot()["reserved"]) == repair_reserve
			and absi(int(successful[first_id]) - int(successful[second_id])) <= 1,
			"Original fair dispatch protects repair and combat funds without starving either direction")
		if not await _until(fixture, func() -> bool:
			return first.growth_supply_system.get_in_transit_count() == 0 \
				and second.growth_supply_system.get_in_transit_count() == 0,
			"Isolated unit-funded original payment physically settles in round %d" % round_index):
			return false
	_check(successful[first_id] == 2 and successful[second_id] == 2
		and float(_growth(fixture, first_id).get("distance", 0.0)) > 0.0
		and float(_growth(fixture, second_id).get("distance", 0.0)) > 0.0
		and _fund(fixture) == 0 and fixture.progress.get_total_recovered() == recovered,
		"Four real low-balance rounds fund both moving tips equally and never count escrow as recovery")
	var refunds: Dictionary = {}
	for construction_id: String in [first_id, second_id]:
		var worker: ConstructionWorker = fixture.coordinator.get_worker(construction_id)
		var resources: Dictionary = worker.get_resource_snapshot()
		var unused: int = int(resources["growth_buffer"]) + int(resources["growth_transit"])
		var balance: int = fixture.core.nutrition
		refunds[construction_id] = unused
		_check(fixture.coordinator.cancel_request(construction_id) and fixture.core.nutrition == balance + unused,
			"Original isolated worker cancellation refunds only its own actual unused units")
	_check(int(fixture.core.get_budget_snapshot()["reserved"]) == repair_reserve
		and fixture.repair_supply.try_dispatch(),
		"Construction cancellation leaves the real protected repair reservation available to its original payer")
	if not await _until(fixture, func() -> bool:
		if fixture.repair.has_active_task():
			fixture.repair_supply.try_dispatch()
		return not fixture.repair.has_active_task(), "Actual protected repair packets arrive and heal through the original repair system"):
		return false
	_check(is_equal_approx(repair_edge.health, repair_edge.max_health)
		and int(fixture.repair.get_task_snapshot()["consumed_nutrition"]) == quoted_cost
		and repair_reserve == quoted_cost
		and int(fixture.core.get_budget_snapshot()["reserved"]) == 0,
		"Original protected repair consumes its exact quoted %d-unit material and releases unpaid locks" % quoted_cost)
	_check(fixture.combat.request_supply(organ) and fixture.combat.request_supply(organ),
		"Both protected combat units launch through the actual original supply dispatcher")
	if not await _until(fixture, func() -> bool: return fixture.combat.get_in_transit_count() == 0,
		"Protected combat nutrition physically arrives on the shared original FIFO"):
		return false
	_check(organ.nutrition == combat_reserve and organ.incoming_nutrition == 0,
		"The original two-shot reserve becomes real organ inventory after physical transport")
	var returned_escrow: int = fixture.escrow
	_escrow_release(fixture, returned_escrow)
	_check(fixture.escrow == 0 and fixture.progress.get_total_recovered() == recovered
		and fixture.nested_dispatches > 0,
		"All conserved escrow returns without recovered receipts or recursively duplicated scheduler payments")
	_checkpoint(fixture, "isolated_budget_fixture_complete", true)
	evidence.append({"case": "isolated_conserved_low_balance_budget_fixture", "formal_demo_resource_grant": false,
		"escrow_returned": returned_escrow, "explicit_existing_stock_consumption": stock,
		"paid_rounds": successful, "actual_unused_refunds": refunds,
		"missing_health_before_repair_request": missing_health, "original_repair_quote": quoted_cost,
		"protected_repair_units": repair_reserve, "protected_combat_units": combat_reserve,
		"recovered_unchanged": recovered, "nested_dispatches_rejected": fixture.nested_dispatches,
		"resources": _resources(fixture)})
	return true


func _progress_callback(fixture: Fixture) -> Callable:
	var callback: Callable
	for connection: Dictionary in fixture.core.get_signal_connection_list(&"digestion_product_arrived"):
		var candidate: Callable = connection["callable"]
		if candidate.get_object() == fixture.progress:
			callback = candidate
	return callback


func _restart(fixture: Fixture) -> Fixture:
	var first_id: String = _admit(fixture, &"growth", fixture.left, Vector2(300, 240))
	var second_id: String = _admit(fixture, &"growth", fixture.right, Vector2(1120, 340))
	var first_worker: ConstructionWorker = fixture.coordinator.get_worker(first_id)
	var second_worker: ConstructionWorker = fixture.coordinator.get_worker(second_id)
	if first_worker == null or second_worker == null:
		_check(false, "Real restart fixture requires two independently live construction workers")
		await _dispose(fixture)
		return null
	_check(_fund(fixture) == 2, "Real R fixture owns two original paid physical growth packets")
	var edge: HyphaEdge = fixture.level.get_node("World/Colony/Connections/RightEdge") as HyphaEdge
	edge.take_damage(7.0)
	_check(fixture.repair.request_repair(edge) > 0, "Real R fixture also admits one genuine damaged-edge repair")
	fixture.repair_supply.refresh_budget()
	_check(fixture.repair_supply.try_dispatch(), "Real R fixture pays its original protected physical repair packet")
	var before: Dictionary = _resources(fixture)
	var refunded_balance: int = int(before["core"])
	for field: String in ["growth_buffer", "cultivation_buffer", "startup_reserved", "growth_transit",
		"cultivation_transit", "repair_buffer", "repair_transit", "combat_transit"]:
		refunded_balance += int(before[field])
	var old_worker_refs: Array[WeakRef] = []
	for worker: ConstructionWorker in fixture.coordinator.get_workers(true):
		old_worker_refs.append(weakref(worker))
	var old_packet_refs: Array[WeakRef] = []
	var handles: Array[Dictionary] = []
	for path: String in PACKET_PATHS:
		for child: Node in fixture.level.get_node(path).get_children():
			if (child is NutrientPacket or child is RemainsPacket) and not child.is_queued_for_deletion():
				old_packet_refs.append(weakref(child))
				var transport: Dictionary = child.call("get_transport_snapshot")
				handles.append({"token": String(transport.get("token", "")),
					"request_id": String(transport.get("request_id", ""))})
	var old_core_id: int = fixture.core.get_instance_id()
	var old_coordinator_id: int = fixture.coordinator.get_instance_id()
	var old_scheduler_id: int = fixture.scheduler.get_instance_id()
	var old_traffic_id: int = fixture.traffic.get_instance_id()
	var old_sources: Array[String] = [fixture.first.get_resource_id(), fixture.second.get_resource_id()]
	var actual_old_product_id: String = String(fixture.receipts.keys()[0])
	var old_receipt_callback: Callable = _progress_callback(fixture)
	var balances: Array[int] = []
	fixture.core.nutrition_changed.connect(func(amount: int) -> void: balances.append(amount))
	var reset_evidence: Dictionary = {"actual_old_receipt_rejected": false, "old_world_conserved": false,
		"all_digestion_stopped": false, "old_refunded_balance": -1}
	fixture.progress.progress_changed.connect(func(total: int, _count: int) -> void:
		if total != 0 or not fixture.retiring:
			return
		var balance: int = fixture.core.nutrition
		# 只重放已在本次真实移动并实际收件的旧产品；没有构造首次到达或新产品。
		if old_receipt_callback.is_valid():
			old_receipt_callback.call(actual_old_product_id, 10)
		reset_evidence["actual_old_receipt_rejected"] = (
			fixture.progress.get_total_recovered() == 0 and fixture.core.nutrition == balance)
		var all_stopped: bool = true
		for organ: DigestiveOrgan in fixture.level.call("get_digestive_organs"):
			all_stopped = all_stopped and not organ.enabled
		reset_evidence["all_digestion_stopped"] = all_stopped
		reset_evidence["old_refunded_balance"] = fixture.core.nutrition
		_checkpoint(fixture, "actual_R_old_world_after_refund_before_disposal", true)
		reset_evidence["old_world_conserved"] = (
			int(_resources(fixture)["total"]) == fixture.initial_total + fixture.enemy_drop_nutrition))
	_checkpoint(fixture, "actual_R_live_paid_ownership_before_reload", true)
	fixture.retiring = true
	root.child_entered_tree.connect(_prepare_reload)
	var old_level_ref: WeakRef = weakref(fixture.level)
	var restart: InputEventKey = InputEventKey.new()
	restart.keycode = KEY_R
	restart.physical_keycode = KEY_R
	restart.pressed = true
	root.push_input(restart)
	for _frame: int in range(90):
		await physics_frame
		await process_frame
		if is_instance_valid(current_scene) and current_scene != old_level_ref.get_ref() and current_scene.is_node_ready():
			break
	if root.child_entered_tree.is_connected(_prepare_reload):
		root.child_entered_tree.disconnect(_prepare_reload)
	fixture.active = false
	var level: Node2D = current_scene as Node2D
	var replaced: bool = is_instance_valid(level) and level != old_level_ref.get_ref()
	_check(replaced and old_level_ref.get_ref() == null, "Actual R input destroys the old demo and creates a fresh demo")
	if not replaced:
		await _dispose(fixture)
		return null
	_check(bool(reset_evidence["actual_old_receipt_rejected"]) and bool(reset_evidence["all_digestion_stopped"])
		and bool(reset_evidence["old_world_conserved"])
		and int(reset_evidence["old_refunded_balance"]) == refunded_balance,
		"Actual R stops old digestion, rejects its old real receipt and conserves exact refunded old-world ownership")
	_check(not balances.is_empty() and balances.back() == refunded_balance,
		"Actual R refunds every original unused paid unit exactly once before its payer is destroyed")
	for balance: int in balances:
		_check(balance <= refunded_balance, "Real R cannot refund permanent structure or duplicate old shipment ownership")
	for reference: WeakRef in old_worker_refs:
		_check(reference.get_ref() == null, "Actual R destroys every old worker and its mutable original executor identity")
	for reference: WeakRef in old_packet_refs:
		_check(reference.get_ref() == null, "Actual R destroys every old physical growth and repair packet")
	_check(not is_instance_valid(instance_from_id(old_core_id))
		and not is_instance_valid(instance_from_id(old_coordinator_id))
		and not is_instance_valid(instance_from_id(old_scheduler_id))
		and not is_instance_valid(instance_from_id(old_traffic_id)),
		"Real R destroys the old payer, coordinator, scheduler and shared traffic system")
	var fresh: Fixture = await _new_fixture(level)
	if fresh == null:
		return null
	for handle: Dictionary in handles:
		var token: String = String(handle["token"])
		var request_id: String = String(handle["request_id"])
		_check(fresh.traffic.get_lease(token).is_empty() and fresh.traffic.get_request(request_id).is_empty()
			and not fresh.traffic.release(token) and not fresh.traffic.cancel_request(request_id),
			"Old transport handles cannot operate on the fresh real traffic generation")
	_check(fresh.core.nutrition == CAPITAL and fresh.progress.get_total_recovered() == 0
		and fresh.progress.get_product_count() == 0 and fresh.core.get_received_product_count() == 0
		and int(fresh.coordinator.get_snapshot()["tip_limit"]) == 1
		and fresh.stomach.get_digestion_snapshot()["chamber_count"] == 1
		and fresh.stomach.get_digestion_snapshot()["expansion_state"] == &"locked"
		and fresh.first.get_remaining_nutrition() == 80 and fresh.second.get_remaining_nutrition() == 120,
		"Fresh actual R run restores original resources and zero product, progress, tip and chamber histories")
	_check(not old_sources.has(fresh.first.get_resource_id()) and not old_sources.has(fresh.second.get_resource_id()),
		"Fresh real carcasses have new source identities rather than adopting old exhausted source ledgers")
	var fresh_id: String = _admit(fresh, &"remote_cultivation", fresh.right, FIRST_TARGET)
	if not await _until(fresh, func() -> bool: return fresh.matured.has(fresh_id) and _access(fresh, 1),
		"Fresh R run independently rebuilds its own real first resource route", true):
		await _dispose(fresh)
		return null
	if not await _recover_batch(fresh, 10):
		await _dispose(fresh)
		return null
	_check(fresh.progress.get_stage() == ColonyProgress.Stage.NASCENT
		and fresh.core.nutrition == CAPITAL - 23 + 10 and fresh.receipts.size() == 1
		and not fixture.receipts.has(String(fresh.receipts.keys()[0])),
		"Fresh physical income stays isolated from old mature progress and every previous product identity")
	evidence.append({"case": "actual_R_restart_identity_and_conservation", "old_recovered": SOURCE_TOTAL,
		"old_resources_before_R": before, "expected_old_refunded_balance": refunded_balance,
		"reset_evidence": reset_evidence, "old_workers_destroyed": old_worker_refs.size(),
		"old_live_packets_destroyed": old_packet_refs.size(), "old_handles_rejected": handles.size(),
		"new_generation_initial_total": fresh.initial_total, "new_real_recovered": 10,
		"new_core_balance": fresh.core.nutrition, "new_resources": _resources(fresh)})
	return fresh


func _dispose(fixture: Fixture) -> void:
	fixture.active = false
	if is_instance_valid(fixture.level):
		if current_scene == fixture.level:
			current_scene = null
		fixture.level.queue_free()
	await process_frame
	await process_frame
