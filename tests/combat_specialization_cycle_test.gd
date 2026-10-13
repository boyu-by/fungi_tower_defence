extends SceneTree
## 8.6：新演示场景、原玩家输入、原物理/计时器与有限资源的整体验收。
## 主流程不补钱、不强设成熟、不直接投递营养，也不手动推进任何生产时钟。
## 断边、损伤、移除及旧回调重入是明示的故障边界；首次结算始终来自真实运输。

const DEMO_PATH: String = "res://scenes/levels/combat_specialization_demo.tscn"
const LEGACY: PackedScene = preload("res://scenes/levels/level_01.tscn")
const INITIAL_TOTAL: int = 280
const FIRST_TARGET: Vector2 = Vector2(970, 440)
const SECOND_TARGET: Vector2 = Vector2(180, 450)
const MATURITY_LIMIT: int = 36000
const TASK_LIMIT: int = 3600
const COMBAT_LIMIT: int = 9000
const RETURN_LIMIT: int = 18000
const REQUIRED_PARTS: Array[String] = [
	"core", "organ_stock", "combat_transit", "network_structure", "organ_structure",
	"growth_buffer", "cultivation_buffer", "startup_reserved", "growth_transit",
	"cultivation_transit", "differentiation_buffer", "differentiation_transit",
	"differentiation_consumed", "repair_buffer", "repair_transit", "repair_consumed",
	"carcass_stock", "ground_remains", "remains_transit", "stomach_intake", "output_queued",
	"return_transit", "combat_consumed", "removed_organ_stock",
]
const PACKET_PATHS: Array[String] = [
	"World/Packets", "World/GrowthPackets", "World/CultivationPackets",
	"World/DifferentiationPackets", "World/RepairPackets", "World/RecoveryPackets",
	"World/ReturnPackets",
]
const PACKET_KINDS: Array[String] = [
	"combat", "growth", "cultivation", "differentiation", "repair", "remains", "return",
]
const BATCH_TYPES: Dictionary = {
	"normal": [6, 0, 0], "swarm": [0, 3, 0],
	"armored": [0, 0, 1], "mixed": [2, 3, 1],
}

class Fixture:
	extends RefCounted
	var level: Node2D
	var core: MotherCore
	var progress: ColonyProgress
	var coordinator: ConstructionCoordinator
	var network: NetworkSystem
	var tracker: CargoPassageTracker
	var targeting: CombatTargetingSystem
	var combat: SupplySystem
	var differentiation: DifferentiationSystem
	var materials: DifferentiationSupplySystem
	var repair: RepairSystem
	var repair_supply: RepairSupplySystem
	var recycling: RecyclingSystem
	var returns: NutritionReturnSystem
	var stomach: DigestiveOrgan
	var panel: DifferentiationInputController
	var spawner: EnemySpawner
	var left: HyphaNode
	var right: HyphaNode
	var active: bool = true
	var retiring: bool = false
	var tick: int = 0
	var spent: int = 0
	var bounty: int = 0
	var removed_stock: int = 0
	var audit_samples: int = 0
	var node_callback: Callable
	var worker_ids: Dictionary = {}
	var growth_costs: Dictionary = {}
	var cultivation_costs: Dictionary = {}
	var repair_costs: Dictionary = {}
	var watched_organs: Dictionary = {}
	var watched_weapons: Dictionary = {}
	var birth_profiles: Dictionary = {}
	var matured: Dictionary = {}
	var receipts: Dictionary = {}
	var products: Dictionary = {}
	var digest_tasks: Dictionary = {}
	var digest_completed: Dictionary = {}
	var packets: Dictionary = {}
	var return_packets: Dictionary = {}
	var spawn_ids: Dictionary = {}
	var enemies: Dictionary = {}
	var deaths: Dictionary = {}
	var corpses: Dictionary = {}
	var harvest_ids: Dictionary = {}
	var shots: Dictionary = {}
	var projectiles: Dictionary = {}
	var completions: Dictionary = {}
	var passage_ids: Dictionary = {}
	var batch_finishes: Dictionary = {}
	var reserve_examples: Dictionary = {}
	var last_parts: Dictionary = {}
	var first_resource_failure: Dictionary = {}
	var milestones: Array[Dictionary] = []
	var births: Array[Dictionary] = []
	var hits: Array[Dictionary] = []
	var stopping_reasons: Array[String] = []

var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {
	"clock": "original physics, FireTimer, digestion timers and physical nutrient routes",
	"formal_sources": "72 core + 4 left + 4 right + original carcasses80+120 = 280",
	"synthetic_maturity_or_materials": false,
	"changed_default_speeds": false,
	"formal_batches": [], "paid_specializations": [], "fault_boundaries": [],
}
var fixture: Fixture


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	_verify_legacy_profile()
	fixture = await _new_fixture()
	if fixture == null:
		await _finish()
		return
	await _verify_initial_and_choices(fixture)
	await _build_original_resource_access(fixture)
	var mature: bool = await _until(fixture, func() -> bool:
		return fixture.progress.get_total_recovered() >= 160,
		MATURITY_LIMIT, "Original collection, digestion and real green arrivals reach160")
	if not mature:
		evidence["maturity_failure"] = _diagnostic(fixture)
		await _finish()
		return
	_check(fixture.progress.get_stage() == ColonyProgress.Stage.MATURE
		and fixture.progress.get_total_recovered() == _sum(fixture.receipts),
		"MATURE is backed by the exact sum of unique physical product receipts")
	_check(fixture.bounty == 0 and fixture.spawn_ids.is_empty() and fixture.core.health == 240,
		"Maturity uses only the two original carcasses and no automatically created enemies")
	_checkpoint(fixture, "natural_maturity")
	var west: HyphaNode = _host_at(fixture, SECOND_TARGET)
	_check(west != null, "Normal G construction creates the actual western connected host")
	if west == null:
		await _finish()
		return
	var extra: AttackOrgan = await _paid_normal(fixture, west, "first_C")
	if extra == null:
		await _finish()
		return
	var left_organ: AttackOrgan = fixture.left.get_node("AttackOrgan") as AttackOrgan
	var right_organ: AttackOrgan = fixture.right.get_node("AttackOrgan") as AttackOrgan
	var left_ok: bool = await _paid_specialization(fixture, left_organ,
		WeaponProfile.DamageType.ARMOR_PIERCING, true)
	var right_ok: bool = await _paid_specialization(fixture, right_organ,
		WeaponProfile.DamageType.SCATTER, false)
	if not left_ok or not right_ok:
		evidence["specialization_failure"] = _diagnostic(fixture)
		await _finish()
		return
	await _repair_history_boundary(fixture)
	await _remove_paid_organ_boundary(fixture, extra)
	var automatic_supply_baseline: int = fixture.combat.delivered_packets
	await _run_batch(fixture, "swarm")
	await _run_batch(fixture, "armored")
	await _run_batch(fixture, "mixed")
	var returned: bool = await _until(fixture, func() -> bool:
		return _recovery_empty(fixture) and fixture.progress.get_total_recovered() == 200 + fixture.bounty,
		RETURN_LIMIT, "Every original carcass and real enemy corpse finishes automatic digestion and return")
	_check(returned and fixture.bounty == 40 and fixture.deaths.size() == 10
		and fixture.corpses.size() == 10,
		"Three actual controlled batches create exactly ten unique four-nutrition corpses")
	_check(fixture.combat.delivered_packets > automatic_supply_baseline
		and _delivered_packet_count(fixture, "combat") > automatic_supply_baseline,
		"Actual battle depletion receives automatically paid physical ammunition")
	_check(fixture.reserve_examples.has("ap_deficit") and fixture.reserve_examples.has("paid_coverage"),
		"Actual AP ammunition depletion and paid transit exercise dynamic two-round reserves")
	_check(fixture.reserve_examples.has("incoming_damage_excluded"),
		"Real committed incoming damage is observed while the complete nutrient sum remains unchanged")
	_checkpoint(fixture, "all_formal_carcasses_returned")
	evidence["recovery"] = {"returned": returned, "recovered": fixture.progress.get_total_recovered(),
		"bounty": fixture.bounty, "unique_deaths": fixture.deaths.size(),
		"unique_corpses": fixture.corpses.size(), "unique_products": fixture.products.size(),
		"unique_receipts": fixture.receipts.size(),
		"automatic_ammunition": fixture.combat.delivered_packets - automatic_supply_baseline,
		"actual_packet_deliveries": _packet_summary(fixture)}
	await _stop_button_boundary(fixture)
	await _until(fixture, func() -> bool: return _live_enemy_count(fixture) == 0,
		COMBAT_LIMIT, "Any actor retained by Stop finishes through real paid combat")
	await _until(fixture, func() -> bool: return _recovery_empty(fixture),
		RETURN_LIMIT, "Stopped-batch real corpses settle before the restart boundary")
	var restart_organ: AttackOrgan = await _paid_normal(fixture, west, "second_C_for_restart")
	if restart_organ != null:
		await _restart_boundary(fixture, restart_organ)
	evidence["resource_audit"] = {"samples": fixture.audit_samples,
		"workers_seen": fixture.worker_ids.size(), "worker_growth_history": fixture.growth_costs,
		"worker_cultivation_history": fixture.cultivation_costs, "repair_history": fixture.repair_costs,
		"removed_stock": fixture.removed_stock, "reserve_examples": fixture.reserve_examples,
		"first_failure": fixture.first_resource_failure, "milestones": fixture.milestones,
		"births": fixture.births, "stopping_reasons": fixture.stopping_reasons}
	await _finish()


func _new_fixture() -> Fixture:
	if not FileAccess.file_exists(DEMO_PATH):
		_check(false, "Frozen combat_specialization_demo scene exists")
		return null
	var packed: PackedScene = load(DEMO_PATH) as PackedScene
	if packed == null:
		_check(false, "Frozen combat specialization scene loads as a PackedScene")
		return null
	var value: Fixture = Fixture.new()
	value.level = packed.instantiate() as Node2D
	if value.level == null:
		_check(false, "Combat specialization scene has its real Node2D root")
		return null
	for method: String in ["get_batch_choices", "select_test_batch", "start_test_batch",
			"stop_test_batch", "get_combat_demo_snapshot", "get_combat_resource_snapshot", "stop_demo"]:
		if not value.level.has_method(method):
			_check(false, "Frozen demo API exists: " + method)
			value.level.free()
			return null
	value.core = value.level.get_node("World/Colony/MotherCore") as MotherCore
	value.left = value.level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode
	value.right = value.level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	value.progress = value.level.get_node("Systems/ColonyProgress") as ColonyProgress
	value.coordinator = value.level.get_node("Systems/ConstructionCoordinator") as ConstructionCoordinator
	value.network = value.level.get_node("Systems/NetworkSystem") as NetworkSystem
	value.tracker = value.level.get_node("Systems/CargoPassageTracker") as CargoPassageTracker
	value.targeting = value.level.get_node("Systems/CombatTargetingSystem") as CombatTargetingSystem
	value.combat = value.level.get_node("Systems/SupplySystem") as SupplySystem
	value.differentiation = value.level.get_node("Systems/DifferentiationSystem") as DifferentiationSystem
	value.materials = value.level.get_node("Systems/DifferentiationSupplySystem") as DifferentiationSupplySystem
	value.repair = value.level.get_node("Systems/RepairSystem") as RepairSystem
	value.repair_supply = value.level.get_node("Systems/RepairSupplySystem") as RepairSupplySystem
	value.recycling = value.level.get_node("Systems/RecyclingSystem") as RecyclingSystem
	value.returns = value.level.get_node("Systems/NutritionReturnSystem") as NutritionReturnSystem
	value.stomach = value.level.get_node("World/Colony/Nodes/RearNode/DigestiveOrgan") as DigestiveOrgan
	value.panel = value.level.get_node("HUD/DifferentiationPanel") as DifferentiationInputController
	value.spawner = value.level.get_node("Systems/EnemySpawner") as EnemySpawner
	for host: HyphaNode in [value.left, value.right]:
		var weapon: SporeWeapon = host.get_node("SporeWeapon") as SporeWeapon
		_assert_profile(weapon, WeaponProfile.DamageType.NORMAL,
			"New preplaced ordinary weapon already has its correct profile before entering the tree")
	_observe(value)
	root.add_child(value.level)
	current_scene = value.level
	await _frames(value, 4)
	return value


func _verify_legacy_profile() -> void:
	var legacy: Node2D = LEGACY.instantiate() as Node2D
	for path: String in ["World/Colony/Nodes/HyphaNode/SporeWeapon", "World/Colony/Nodes/RightNode/SporeWeapon"]:
		var weapon: SporeWeapon = legacy.get_node(path) as SporeWeapon
		_check(weapon.attack_range == 100.0 and weapon.get_weapon_profile().attack_range == 100.0,
			"Legacy level_01 retains each explicit100 ordinary range")
	var cultivation: CultivationSystem = legacy.get_node("Systems/CultivationSystem") as CultivationSystem
	_check(cultivation.weapon_attack_range == 100.0, "Legacy paid cultivation retains its explicit100 compatibility setting")
	legacy.free()


func _observe(value: Fixture) -> void:
	value.node_callback = _on_tree_node_added.bind(value)
	node_added.connect(value.node_callback)
	value.core.digestion_product_arrived.connect(_on_core_receipt.bind(value))
	value.stomach.digestion_started.connect(_on_digestion_started.bind(value))
	value.stomach.digestion_completed.connect(_on_digestion_completed.bind(value))
	value.stomach.product_created.connect(_on_product_created.bind(value))
	value.spawner.enemy_spawned.connect(_on_enemy_spawned.bind(value))
	value.spawner.batch_finished.connect(func(id: String) -> void:
		if value.active:
			value.batch_finishes[id] = int(value.batch_finishes.get(id, 0)) + 1
			_check(int(value.batch_finishes[id]) == 1, "Each controlled batch emits one real completion"))
	value.differentiation.organ_differentiated.connect(func(_task: int, organ: AttackOrgan, _kind: int) -> void:
		if value.active:
			var id: int = organ.get_instance_id()
			value.completions[id] = int(value.completions.get(id, 0)) + 1
			_check(int(value.completions[id]) == 1, "Each paid organ differentiates exactly once"))
	value.coordinator.organ_matured.connect(_on_cultivation_matured.bind(value))
	value.coordinator.changed.connect(func(_snapshot: Dictionary) -> void:
		if value.active and not value.retiring:
			_sync_workers(value))
	value.repair.task_changed.connect(func(snapshot: Dictionary) -> void:
		_remember_cost(value.repair_costs, "repair", snapshot, "consumed_nutrition"))
	value.tracker.passage_confirmed.connect(func(cargo: String, edge: HyphaEdge, generation: int) -> void:
		if value.active and not value.retiring:
			var key: String = "%s:%d:%d" % [cargo, edge.get_instance_id(), generation]
			_check(not value.passage_ids.has(key), "Each actual cargo-edge-generation passage is confirmed once")
			value.passage_ids[key] = true)
	if value.level.has_signal("level_stopping"):
		value.level.connect("level_stopping", func(reason: StringName) -> void:
			value.stopping_reasons.append(String(reason)))
	else:
		_check(false, "Level exposes the common level_stopping lifecycle notification")
	value.level.get_node("World/Projectiles").child_entered_tree.connect(_on_projectile_added.bind(value))
	value.level.get_node("World/Remains").child_entered_tree.connect(_on_remains_added.bind(value))
	for index: int in range(PACKET_PATHS.size()):
		value.level.get_node(PACKET_PATHS[index]).child_entered_tree.connect(_on_packet_added.bind(PACKET_KINDS[index], value))
	for host: HyphaNode in [value.left, value.right]:
		_watch_organ(value, host.get_node("AttackOrgan") as AttackOrgan)
		_watch_weapon(value, host.get_node("SporeWeapon") as SporeWeapon, false)
	var local_growth: GrowthSystem = value.level.get_node("Systems/GrowthSystem") as GrowthSystem
	var local_cultivation: CultivationSystem = value.level.get_node("Systems/CultivationSystem") as CultivationSystem
	local_growth.task_changed.connect(func(snapshot: Dictionary) -> void:
		_remember_cost(value.growth_costs, "local", snapshot, "consumed_nutrition"))
	local_cultivation.task_changed.connect(func(_snapshot: Dictionary) -> void:
		value.cultivation_costs["local"] = maxi(int(value.cultivation_costs.get("local", 0)),
			int(local_cultivation.get_resource_snapshot().get("structure_consumed", 0))))


func _on_tree_node_added(node: Node, value: Fixture) -> void:
	if not value.active or value.retiring or not value.level.is_ancestor_of(node):
		return
	if node is ConstructionWorker:
		_watch_worker(value, node as ConstructionWorker)
	elif node is AttackOrgan:
		_watch_organ(value, node as AttackOrgan)
	elif node is SporeWeapon:
		_watch_weapon(value, node as SporeWeapon, true)


func _watch_organ(value: Fixture, organ: AttackOrgan) -> void:
	var id: int = organ.get_instance_id()
	if value.watched_organs.has(id):
		return
	value.watched_organs[id] = true
	organ.tree_exiting.connect(func() -> void:
		if value.active and not value.retiring:
			value.removed_stock += organ.nutrition)


func _watch_weapon(value: Fixture, weapon: SporeWeapon, dynamic: bool) -> void:
	var id: int = weapon.get_instance_id()
	if value.watched_weapons.has(id):
		return
	value.watched_weapons[id] = true
	if dynamic:
		_assert_profile(weapon, WeaponProfile.DamageType.NORMAL,
			"New paid ordinary weapon is born178 and never enters the tree as legacy100")
		value.birth_profiles[id] = _profile_summary(weapon)
		value.births.append({"weapon_id": id, "moment": "node_added_before_ready",
			"profile": _profile_summary(weapon)})
	weapon.volley_committed.connect(_on_volley.bind(weapon, value))


func _watch_worker(value: Fixture, worker: ConstructionWorker) -> void:
	var id: int = worker.worker_id
	if value.worker_ids.has(id):
		return
	value.worker_ids[id] = true
	worker.growth_system.task_changed.connect(func(snapshot: Dictionary) -> void:
		_remember_cost(value.growth_costs, str(id), snapshot, "consumed_nutrition"))
	worker.cultivation_system.task_changed.connect(func(_snapshot: Dictionary) -> void:
		_remember_worker(value, worker))
	worker.tree_exiting.connect(func() -> void: _remember_worker(value, worker))
	_remember_worker(value, worker)


func _remember_cost(history: Dictionary, owner: String, snapshot: Dictionary, field: String) -> void:
	var id: int = int(snapshot.get("task_id", 0))
	if id > 0:
		var key: String = "%s:%d" % [owner, id]
		history[key] = maxi(int(history.get(key, 0)), int(snapshot.get(field, 0)))


func _remember_worker(value: Fixture, worker: ConstructionWorker) -> void:
	if not is_instance_valid(worker) or not is_instance_valid(worker.growth_system) \
			or not is_instance_valid(worker.cultivation_system):
		return
	_remember_cost(value.growth_costs, str(worker.worker_id), worker.growth_system.get_task_snapshot(), "consumed_nutrition")
	var id: String = str(worker.worker_id)
	value.cultivation_costs[id] = maxi(int(value.cultivation_costs.get(id, 0)),
		int(worker.cultivation_system.get_resource_snapshot().get("structure_consumed", 0)))


func _sync_workers(value: Fixture) -> void:
	for worker: ConstructionWorker in value.coordinator.get_workers(true):
		_watch_worker(value, worker)
		_remember_worker(value, worker)


func _on_cultivation_matured(id: String, host: HyphaNode, organ: AttackOrgan,
		weapon: SporeWeapon, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(not value.matured.has(id) and organ.nutrition == 4 and organ.incoming_nutrition == 0
		and organ.get_parent() == host and weapon.inventory_owner == organ,
		"A real C request creates one organ with its four paid startup units")
	_assert_profile(weapon, WeaponProfile.DamageType.NORMAL, "Real C maturation retains the ordinary12/.8/178/1 profile")
	_check(value.birth_profiles.has(weapon.get_instance_id()), "C weapon profile was observed at birth before maturation notification")
	var worker: ConstructionWorker = value.coordinator.get_worker(id)
	var task: Dictionary = worker.cultivation_system.get_task_snapshot() if is_instance_valid(worker) else {}
	_check(int(task.get("structure_consumed", -1)) == 8 and int(task.get("startup_transferred", -1)) == 4
		and int(task.get("consumed_nutrition", -1)) == 12 and float(task.get("effective_time", 0.0)) >= 3.0,
		"Real C pays exactly eight irreversible structure plus four startup stock and waits three funded seconds")
	value.matured[id] = {"host_id": host.get_instance_id(), "organ_id": organ.get_instance_id(),
		"weapon_id": weapon.get_instance_id(), "task": task, "organ": weakref(organ)}


func _on_packet_added(node: Node, kind: String, value: Fixture) -> void:
	if not value.active or value.retiring or not (node is NutrientPacket or node is RemainsPacket):
		return
	var packet: Node2D = node as Node2D
	var id: int = packet.get_instance_id()
	_check(not value.packets.has(id), "Each actual physical cargo packet enters the world once")
	value.packets[id] = {"kind": kind, "arrivals": 0, "interruptions": 0,
		"speed": packet.get("speed"), "ref": weakref(packet)}
	packet.connect("arrived", _on_packet_arrived.bind(kind, value))
	packet.connect("interrupted", _on_packet_interrupted.bind(kind, value))
	if kind == "return":
		var product: String = String(packet.get_meta("return_product_id", ""))
		_check(not product.is_empty(), "Each real green packet identifies its actual digestive product")
		value.return_packets[product] = weakref(packet)
		_check(is_equal_approx(float(packet.get("speed")), 80.0), "Real green return keeps its original eighty-pixel speed")


func _on_packet_arrived(packet: Node2D, kind: String, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	var id: int = packet.get_instance_id()
	var record: Dictionary = value.packets.get(id, {})
	_check(not record.is_empty(), "An actual arrival belongs to an observed real packet")
	if record.is_empty():
		return
	record["arrivals"] = int(record["arrivals"]) + 1
	_check(int(record["arrivals"]) == 1 and int(record["interruptions"]) == 0,
		"A real cargo packet has one terminal arrival and no interruption")
	var transport: Dictionary = packet.call("get_transport_snapshot")
	var segments: int = int(transport.get("completed_segments", 0))
	var local_repair: bool = (kind == "repair" and segments == 0 and packet is NutrientPacket
		and (packet as NutrientPacket).has_arrived_at(value.core)
		and value.repair.get_task_snapshot().get("repair_point") == value.core
		and packet.global_position.distance_to(value.core.global_position) < 0.01)
	_check(segments > 0 or local_repair,
		"Observed delivery completes a real positive-length route or a validated repair route at the source core")
	if local_repair:
		record["local_repair_arrival"] = true


func _on_packet_interrupted(packet: Node2D, _kind: String, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	var record: Dictionary = value.packets.get(packet.get_instance_id(), {})
	if record.is_empty():
		return
	record["interruptions"] = int(record["interruptions"]) + 1
	_check(int(record["interruptions"]) == 1 and int(record["arrivals"]) == 0,
		"A real cargo packet has one terminal interruption and no arrival")


func _on_core_receipt(product: String, amount: int, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(not value.receipts.has(product) and value.products.has(product),
		"Mother core credits each previously created real product once")
	var packet: NutrientPacket = null
	var reference: WeakRef = value.return_packets.get(product) as WeakRef
	if reference != null and is_instance_valid(reference.get_ref()):
		packet = reference.get_ref() as NutrientPacket
	_check(packet != null and packet.has_arrived_at(value.core) and value.core.has_received_product(product),
		"Core income is backed by the physical green packet at its actual destination")
	if value.products.has(product):
		_check(int(value.products[product]["nutrition"]) == amount,
			"Core receipt preserves the actual product amount without a second bounty")
	value.receipts[product] = amount


func _on_digestion_started(task: String, chamber: int, input_id: String,
		amount: int, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(not task.is_empty() and not value.digest_tasks.has(task) and not input_id.is_empty(),
		"Each physical intake starts one uniquely identified digestion task")
	for previous: Dictionary in value.digest_tasks.values():
		_check(String(previous["input_id"]) != input_id, "Each actual input is digested once")
	var chambers: Array = value.stomach.get_digestion_snapshot().get("chambers", [])
	var duration: float = float(chambers[chamber].get("duration", 0.0))
	_check(is_equal_approx(duration, 1.5) and amount in [4, 10],
		"Formal intake uses the unchanged1.5-second timer and real four/ten-unit sources")
	value.digest_tasks[task] = {"input_id": input_id, "nutrition": amount,
		"duration": duration, "tick": Engine.get_physics_frames()}


func _on_product_created(product: String, amount: int, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(not product.is_empty() and not value.products.has(product)
		and not value.core.has_received_product(product),
		"Real digestion creates one product without early core income")
	value.products[product] = {"nutrition": amount}


func _on_digestion_completed(task: String, _chamber: int, product: String,
		amount: int, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(value.digest_tasks.has(task) and not value.digest_completed.has(task)
		and value.products.has(product), "Each actual digestion task completes once into its actual product")
	if not value.digest_tasks.has(task):
		return
	var start: Dictionary = value.digest_tasks[task]
	var elapsed: float = _physics_seconds(Engine.get_physics_frames() - int(start["tick"]))
	_check(elapsed + _physics_seconds(2) >= float(start["duration"])
		and int(start["nutrition"]) == amount,
		"Physical digestion waits its full default duration and preserves the intake nutrition")
	value.digest_completed[task] = product
	if value.products.has(product):
		value.products[product]["task_id"] = task
		value.products[product]["input_id"] = start["input_id"]


func _on_remains_added(node: Node, value: Fixture) -> void:
	if not value.active or value.retiring or not node is EnemyRemains or not node.has_meta("carcass_batch_id"):
		return
	var id: String = String(node.get_meta("carcass_batch_id", ""))
	_check(not id.is_empty() and not value.harvest_ids.has(id), "Each original carcass mining batch has one identity")
	value.harvest_ids[id] = node.get_meta("carcass_source_id", "")


func _on_enemy_spawned(enemy: BasicEnemy, spawn_id: String, batch_id: String, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(not spawn_id.is_empty() and not batch_id.is_empty() and not value.spawn_ids.has(spawn_id),
		"Every actual controlled enemy has a unique spawn and batch identity")
	var stats: Array = [[24, 0, 52.0, 12], [12, 0, 66.0, 6], [72, 4, 26.0, 15]]
	var expected: Array = stats[enemy.get_archetype()]
	_check(enemy.health == int(expected[0]) and enemy.armor == int(expected[1])
		and is_equal_approx(enemy.move_speed, float(expected[2])) and enemy.attack_damage == int(expected[3])
		and enemy.remains_nutrition == 4,
		"Real batch actor retains its unchanged archetype health, armor, speed, contact damage and bounty")
	value.spawn_ids[spawn_id] = true
	value.enemies[enemy.get_instance_id()] = {"ref": weakref(enemy), "spawn_id": spawn_id,
		"batch_id": batch_id, "archetype": enemy.get_archetype(),
		"spawn_position": enemy.global_position, "spawn_tick": Engine.get_physics_frames()}
	enemy.died.connect(_on_enemy_died.bind(value))


func _on_enemy_died(enemy: BasicEnemy, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	var id: int = enemy.get_instance_id()
	_check(value.enemies.has(id) and not value.deaths.has(id) and enemy.health == 0,
		"Each actually spawned enemy reports one genuine lethal hit")
	if value.deaths.has(id):
		return
	value.deaths[id] = true
	value.bounty += enemy.remains_nutrition
	var matches: int = 0
	var corpse: EnemyRemains = null
	for node: Node in value.level.get_node("World/Remains").get_children():
		if node is EnemyRemains and not node.has_meta("carcass_batch_id") \
				and node.global_position.distance_to(enemy.global_position) < 0.01:
			matches += 1
			corpse = node as EnemyRemains
	_check(matches == 1 and corpse != null, "Real RemainsSpawner creates exactly one corpse at each lethal position")
	if corpse != null:
		_check(not value.corpses.has(corpse.get_instance_id()) and corpse.nutrition_value == enemy.remains_nutrition,
			"Each unique death owns one corpse with its original finite bounty")
		value.corpses[corpse.get_instance_id()] = {"enemy_id": id, "nutrition": corpse.nutrition_value,
			"archetype": enemy.get_archetype(), "position": corpse.global_position}
	# 此探针只检查已经真实死亡的对象，不触发第一份尸体或首次伤害。
	var corpse_count: int = value.level.get_node("World/Remains").get_child_count()
	var rejected: int = enemy.apply_damage({"raw_damage": 24, "damage_type": WeaponProfile.DamageType.ARMOR_PIERCING})
	_check(rejected == 0 and value.level.get_node("World/Remains").get_child_count() == corpse_count,
		"A settled real death rejects reentry without creating another corpse or bounty")


func _on_projectile_added(node: Node, value: Fixture) -> void:
	if not value.active or value.retiring or not node is SporeProjectile:
		return
	var projectile: SporeProjectile = node as SporeProjectile
	var target: BasicEnemy = projectile.target
	if not is_instance_valid(target):
		_check(false, "Actual projectile draft retains its selected live target")
		return
	var id: int = projectile.get_instance_id()
	value.projectiles[id] = {"ref": weakref(projectile), "target_ref": weakref(target),
		"target_id": target.get_instance_id(), "draft_health": target.health,
		"exits": 0, "shot_id": "", "committed_tick": -1}
	projectile.tree_exiting.connect(_on_projectile_exiting.bind(id, value))


func _on_volley(shot_id: String, spent: int, count: int, weapon: SporeWeapon, value: Fixture) -> void:
	if not value.active or value.retiring:
		return
	_check(not shot_id.is_empty() and not value.shots.has(shot_id), "Each real paid volley has one unique authoritative receipt")
	if shot_id.is_empty() or value.shots.has(shot_id):
		return
	var profile: WeaponProfile = weapon.get_weapon_profile()
	_check(spent == profile.nutrition_cost and spent == (2 if profile.damage_type == WeaponProfile.DamageType.ARMOR_PIERCING else 1),
		"Real AP volleys cost2; actual scatter and ordinary volleys cost1")
	var task_state: StringName = StringName(weapon.inventory_owner.get_differentiation_snapshot().get("state", &"idle"))
	_check(weapon.inventory_owner.is_work_enabled() and task_state not in [&"waiting", &"differentiating", &"paused"],
		"No committed volley fires while its organ is differentiating")
	var targets: Dictionary = {}
	var actual: int = 0
	for node: Node in value.level.get_node("World/Projectiles").get_children():
		if not node is SporeProjectile or String(node.get_meta("shot_id", "")) != shot_id:
			continue
		var projectile: SporeProjectile = node as SporeProjectile
		var target: BasicEnemy = projectile.target
		var record: Dictionary = value.projectiles.get(projectile.get_instance_id(), {})
		var commitment: Dictionary = value.targeting.get_commitment(projectile.get_damage_commitment_id())
		_check(not record.is_empty() and target.health == int(record.get("draft_health", -1)),
			"Submitting a real damage commitment deducts no health before the projectile flies")
		_check(not targets.has(target.get_instance_id()), "One actual scatter volley assigns at most one projectile per target")
		targets[target.get_instance_id()] = true
		_check(value.targeting.is_commitment_committed(projectile.get_damage_commitment_id())
			and int(commitment.get("projectile_id", 0)) == projectile.get_instance_id()
			and int(commitment.get("owner_id", 0)) == weapon.get_instance_id()
			and int(commitment.get("raw_damage", -1)) == profile.damage
			and int(commitment.get("damage_type", -1)) == int(profile.damage_type)
			and int(commitment.get("expected_damage", -1)) == target.estimate_damage(profile.create_damage_request()),
			"Each actual paid projectile owns its one committed incoming-damage record")
		_check(is_equal_approx(projectile.speed, 360.0)
			and projectile.global_position.distance_to(target.get_aim_position()) > 0.0,
			"Actual receipt is observed before positive-distance flight at the original projectile speed")
		record["shot_id"] = shot_id
		record["committed_tick"] = Engine.get_physics_frames()
		record["expected_damage"] = int(commitment.get("expected_damage", 0))
		record["damage_type"] = int(profile.damage_type)
		record["archetype"] = target.get_archetype()
		actual += 1
	_check(actual == count and count > 0 and count <= profile.max_targets,
		"Receipt count exactly describes the actually committed projectile set")
	var batch: Dictionary = _demo_snapshot(value)
	value.shots[shot_id] = {"nutrition_spent": spent, "projectile_count": count,
		"weapon_id": weapon.get_instance_id(), "organ_id": weapon.inventory_owner.get_instance_id(),
		"damage_type": int(profile.damage_type), "batch_id": batch.get("batch_id", ""),
		"selected_batch": batch.get("selected_batch", ""), "targets": targets.keys()}
	value.spent += spent
	_assert_reserve(value)


func _on_projectile_exiting(id: int, value: Fixture) -> void:
	if not value.active or value.retiring or not value.projectiles.has(id):
		return
	var record: Dictionary = value.projectiles[id]
	record["exits"] = int(record["exits"]) + 1
	_check(int(record["exits"]) == 1, "Each actual projectile reaches one terminal exit")
	var target_ref: WeakRef = record.get("target_ref") as WeakRef
	var target: BasicEnemy = target_ref.get_ref() as BasicEnemy if target_ref != null and is_instance_valid(target_ref.get_ref()) else null
	if target == null or String(record.get("shot_id", "")).is_empty():
		return
	var lost: int = int(record["draft_health"]) - target.health
	if lost > 0:
		_check(Engine.get_physics_frames() > int(record["committed_tick"]),
			"First actual damage waits for a later physical flight tick")
		if (int(record["damage_type"]) == WeaponProfile.DamageType.ARMOR_PIERCING
			and int(record["archetype"]) == BasicEnemy.Archetype.ARMORED):
			_check(lost == 24, "Real AP impact ignores armor4 and removes exactly twenty-four armored HP")
		elif (int(record["damage_type"]) == WeaponProfile.DamageType.SCATTER
			and int(record["archetype"]) == BasicEnemy.Archetype.SWARM):
			_check(lost == 6, "Each actual scatter impact removes exactly six swarm HP")
		value.hits.append({"projectile_id": id, "shot_id": record["shot_id"],
			"damage_type": record["damage_type"], "archetype": record["archetype"],
			"health_lost": lost, "expected_damage": record["expected_damage"]})


func _independent_parts(value: Fixture) -> Dictionary:
	_sync_workers(value)
	_remember_cost(value.repair_costs, "repair", value.repair.get_task_snapshot(), "consumed_nutrition")
	var parts: Dictionary = {}
	for key: String in REQUIRED_PARTS:
		parts[key] = 0
	parts["core"] = value.core.nutrition
	parts["network_structure"] = _sum(value.growth_costs)
	parts["organ_structure"] = _sum(value.cultivation_costs)
	parts["repair_consumed"] = _sum(value.repair_costs)
	parts["combat_consumed"] = value.spent
	parts["removed_organ_stock"] = value.removed_stock
	for organ: AttackOrgan in value.combat.get_registered_organs():
		parts["organ_stock"] += organ.nutrition
		parts["combat_transit"] += organ.incoming_nutrition
	for worker: ConstructionWorker in value.coordinator.get_workers(true):
		_add_construction_parts(parts, worker.growth_system, worker.cultivation_system,
			worker.growth_supply_system, worker.cultivation_supply_system)
	# 独立旧执行器若被实际使用，也只加它们自己的缓存、在途和历史，不重复 coordinator 汇总。
	_add_construction_parts(parts, value.level.get_node("Systems/GrowthSystem") as GrowthSystem,
		value.level.get_node("Systems/CultivationSystem") as CultivationSystem,
		value.level.get_node("Systems/GrowthSupplySystem"), value.level.get_node("Systems/CultivationSupplySystem"))
	for shipment: Dictionary in value.materials.get_shipment_records():
		if bool(shipment.get("debited", false)) and not bool(shipment.get("settled", false)) \
				and not bool(shipment.get("refunded", false)):
			parts["differentiation_transit"] += 1
		parts["differentiation_buffer"] += int(shipment.get("buffered_nutrition", 0))
		if bool(shipment.get("consumed", false)):
			parts["differentiation_consumed"] += 1
	var repair: Dictionary = value.repair.get_task_snapshot()
	parts["repair_buffer"] = int(repair.get("buffered_nutrition", 0))
	parts["repair_transit"] = _paid_transit(value.repair_supply)
	for node: Node in value.level.get_node("World/Remains").get_children():
		if node.is_queued_for_deletion():
			continue
		if node is LargeCarcass:
			parts["carcass_stock"] += (node as LargeCarcass).get_remaining_nutrition()
		elif node is EnemyRemains:
			var key: String = "ground_remains" if (node as EnemyRemains).is_available() else "remains_transit"
			parts[key] += (node as EnemyRemains).nutrition_value
	for stomach: DigestiveOrgan in value.level.call("get_digestive_organs"):
		parts["stomach_intake"] += stomach.get_queued_nutrition()
		for product: Dictionary in stomach.get_output_products():
			var key: String = "return_transit" if product.get("status") == &"in_transit" else "output_queued"
			parts[key] += int(product.get("nutrition", 0))
	return parts


func _add_construction_parts(parts: Dictionary, growth: GrowthSystem, cultivation: CultivationSystem,
		growth_supply: Node, cultivation_supply: Node) -> void:
	var current_growth: Dictionary = growth.get_task_snapshot()
	var current_cultivation: Dictionary = cultivation.get_resource_snapshot()
	parts["growth_buffer"] += int(current_growth.get("buffered_nutrition", 0))
	parts["cultivation_buffer"] += int(current_cultivation.get("buffered_nutrition", 0))
	parts["startup_reserved"] += int(current_cultivation.get("startup_reserved", 0))
	parts["growth_transit"] += _paid_transit(growth_supply)
	parts["cultivation_transit"] += _paid_transit(cultivation_supply)


func _paid_transit(supply: Node) -> int:
	var amount: int = 0
	var records: Array = supply.call("get_shipment_records")
	for record: Dictionary in records:
		if bool(record.get("debited", false)) and not bool(record.get("settled", false)) \
				and not bool(record.get("refunded", false)):
			amount += int(record.get("nutrition", 1))
	return amount


func _audit(value: Fixture, label: String = "physics_audit") -> void:
	if not value.active or value.retiring or not is_instance_valid(value.level):
		return
	var parts: Dictionary = _independent_parts(value)
	var expected: int = INITIAL_TOTAL + value.bounty
	var actual: int = _sum(parts)
	var ledger: Dictionary = value.level.call("get_combat_resource_snapshot")
	var reported: Dictionary = ledger.get("parts", {})
	value.audit_samples += 1
	value.last_parts = parts.duplicate(true)
	if (actual != expected or reported != parts) and value.first_resource_failure.is_empty():
		value.first_resource_failure = {"at": label, "expected": expected, "independent_total": actual,
			"independent_parts": parts.duplicate(true), "reported": ledger}
	_check(actual == expected, "Independent resource ownership conserves280 plus unique real-death bounty")
	_check(bool(ledger.get("valid", false)) and int(ledger.get("initial_total", -1)) == INITIAL_TOTAL
		and int(ledger.get("enemy_created_nutrition", -1)) == value.bounty
		and int(ledger.get("expected_total", -1)) == expected,
		"Public resource ledger has the independently observed original sources and unique death bounty")
	_check(reported.size() == REQUIRED_PARTS.size(), "Public ledger exposes exactly the frozen mutually exclusive resource parts")
	for key: String in REQUIRED_PARTS:
		_check(reported.has(key) and typeof(reported.get(key)) == TYPE_INT and int(reported.get(key, -1)) >= 0,
			"Public resource part is a nonnegative integer: " + key)
		_check(int(reported.get(key, -1)) == int(parts[key]), "Independent ownership matches public part: " + key)
	_check(int(ledger.get("accounted_total", -1)) == _sum(reported)
		and int(ledger.get("accounted_total", -1)) == actual and int(ledger.get("error", 1)) == 0
		and bool(ledger.get("balanced", false)), "Public balanced flag is backed by both independent and reported sums")
	var construction: Dictionary = value.coordinator.get_resource_snapshot()
	for key: String in ["network_structure", "organ_structure", "growth_buffer", "cultivation_buffer",
			"startup_reserved", "growth_transit", "cultivation_transit"]:
		_check(int(construction.get(key, -1)) == int(parts[key]),
			"Live and archived multi-worker accounting matches independent history: " + key)
	var differentiation: Dictionary = value.differentiation.get_resource_snapshot()
	_check(int(differentiation.get("consumed_nutrition", -1)) == int(parts["differentiation_consumed"])
		and int(differentiation.get("buffered_nutrition", -1)) == int(parts["differentiation_buffer"]),
		"Differentiation resource history equals unique consumed shipments and refundable delivery buffers")
	var budget: Dictionary = value.core.get_budget_snapshot()
	_check(int(budget.get("balance", -1)) == value.core.nutrition
		and int(budget.get("reserved", 0)) + int(budget.get("spendable", 0)) == value.core.nutrition,
		"Repair reservations partition the existing core balance and create no second nutrient bucket")
	_check(int(parts["combat_transit"]) == value.combat.get_in_transit_count()
		and int(parts["return_transit"]) == value.returns.get_in_transit_nutrition(),
		"Paid ammunition and authoritative in-flight green products are counted once")
	_check(value.progress.get_total_recovered() == _sum(value.receipts)
		and value.progress.get_product_count() == value.receipts.size()
		and value.core.get_received_product_count() == value.receipts.size(),
		"Only observed unique actual arrivals advance colony recovery")
	var combat: Dictionary = value.level.call("get_combat_statistics")
	var projectile_count: int = 0
	for shot: Dictionary in value.shots.values():
		projectile_count += int(shot["projectile_count"])
	_check(int(combat.get("rounds", -1)) == value.shots.size()
		and int(combat.get("projectiles", -1)) == projectile_count
		and int(combat.get("nutrition_spent", -1)) == value.spent
		and ledger.get("combat", {}) == combat,
		"Scene and resource statistics equal independently observed authoritative volley receipts")
	var damage: int = int(value.targeting.get_snapshot().get("total_expected_damage", 0))
	if damage > 0 and not value.reserve_examples.has("incoming_damage_excluded"):
		value.reserve_examples["incoming_damage_excluded"] = {"incoming_damage": damage,
			"resource_total": actual, "source_total": expected}
	_assert_reserve(value)
	_assert_material_passages(value)


func _assert_reserve(value: Fixture) -> void:
	var expected: int = 0
	for organ: AttackOrgan in value.combat.get_active_organs():
		var cost: int = organ.get_shot_nutrition_cost()
		var unfunded: int = maxi(0, 2 * cost - organ.nutrition - organ.incoming_nutrition)
		expected += unfunded
		if cost == 2 and unfunded > 0 and not value.reserve_examples.has("ap_deficit"):
			value.reserve_examples["ap_deficit"] = {"cost": cost, "stock": organ.nutrition,
				"paid_transit": organ.incoming_nutrition, "two_round_unfunded": unfunded}
		if organ.incoming_nutrition > 0 and organ.nutrition < 2 * cost \
				and not value.reserve_examples.has("paid_coverage"):
			value.reserve_examples["paid_coverage"] = {"cost": cost, "stock": organ.nutrition,
				"paid_transit": organ.incoming_nutrition, "two_round_unfunded": unfunded}
	_check(value.materials.get_combat_reserve() == expected,
		"Two-round reserve uses each active weapon's real cost and covers paid ammunition transit once")
	_check(value.materials.get_available_differentiation_nutrition()
		== maxi(0, value.core.get_spendable_nutrition() - expected),
		"Available differentiation budget does not subtract already debited material transit again")


func _assert_material_passages(value: Fixture) -> void:
	var seen: Dictionary = {}
	for record: Dictionary in value.materials.get_shipment_records():
		var id: String = String(record.get("shipment_id", ""))
		var cargo: Dictionary = value.tracker.get_cargo_snapshot(String(record.get("cargo_id", "")))
		_check(not id.is_empty() and not seen.has(id), "Paid material shipment identities remain unique across cancellations and continuations")
		seen[id] = true
		_check(not bool(record.get("debited", false)) or int(record.get("source_id", 0)) == value.core.get_instance_id(),
			"Each actually debited differentiation material retains its original real mother-core payer")
		if bool(record.get("consumed", false)):
			_check(bool(record.get("debited", false)) and bool(record.get("accepted", false))
				and not bool(record.get("refunded", false)) and cargo.get("status") == &"confirmed"
				and int(cargo.get("confirmed_count", 0)) > 0
				and int(cargo.get("confirmed_count", -1)) == int(cargo.get("candidate_count", -2)),
				"Only a debited, accepted and irreversibly consumed material confirms its actual passage")
		elif bool(record.get("refunded", false)):
			_check(cargo.get("status") == &"discarded" and int(cargo.get("confirmed_count", -1)) == 0,
				"A refunded in-flight or cached material never earns a main-vein passage")
		elif bool(record.get("debited", false)):
			_check(cargo.get("status") == &"pending" and int(cargo.get("confirmed_count", -1)) == 0,
				"Physical transit or refundable arrival cache alone cannot grow a main vein")


func _checkpoint(value: Fixture, label: String) -> void:
	_audit(value, label)
	value.milestones.append({"at": label, "recovered": value.progress.get_total_recovered(),
		"parts": value.last_parts.duplicate(true), "source_total": INITIAL_TOTAL + value.bounty,
		"demo": _demo_snapshot(value)})


func _verify_initial_and_choices(value: Fixture) -> void:
	var snapshot: Dictionary = _demo_snapshot(value)
	_check(value.core.nutrition == 72 and value.progress.get_total_recovered() == 0
		and int(value.last_parts.get("organ_stock", -1)) == 8
		and int(value.last_parts.get("carcass_stock", -1)) == 200,
		"Fresh demonstration has exactly72 capital, two stocks4 and the original200 carcass source")
	_check(not value.spawner.auto_start and value.spawner.spawned_count == 0
		and value.spawner.start_timer.is_stopped() and value.spawner.spawn_timer.is_stopped()
		and not bool(snapshot.get("mature", true)) and not bool(snapshot.get("can_start", true))
		and String(snapshot.get("phase", "")) == "preparing" and snapshot.get("start_reason") == &"stage_locked",
		"Fresh demo never automatically starts an enemy batch and locks combat until true maturity")
	var choices: Array = value.level.call("get_batch_choices")
	_check(choices.size() == 4, "Demo exposes exactly the four finite batch choices")
	var seen: Dictionary = {}
	for choice: Dictionary in choices:
		var id: String = String(choice.get("id", ""))
		_check(BATCH_TYPES.has(id) and not seen.has(id) and not String(choice.get("title", "")).is_empty(),
			"Each batch choice has one frozen identifier and a visible title")
		seen[id] = true
		if BATCH_TYPES.has(id):
			var counts: Array = BATCH_TYPES[id]
			_check(int(choice.get("planned", -1)) == int(counts[0]) + int(counts[1]) + int(counts[2]),
				"Batch preview quotes the actual finite planned count: " + id)
		await _combat_button(value, id.capitalize() + "Button")
		_check(String(_demo_snapshot(value).get("selected_batch", "")) == id,
			"Real HUD button selects the preview while immature: " + id)
		_check(String(value.level.call("start_test_batch")).is_empty() and value.spawner.spawned_count == 0,
			"Immature start rejects without spawning or granting resources: " + id)
		_assert_batch_configuration(value, id)
	var before: Dictionary = value.level.call("get_combat_resource_snapshot")
	_check(not bool(value.level.call("select_test_batch", "invalid_batch"))
		and value.level.call("get_combat_resource_snapshot") == before,
		"Invalid batch selection leaves the finite resource ledger unchanged")
	var start: Button = value.level.get_node("HUD/CombatDemoPanel/StartButton") as Button
	_check(start.disabled, "Immature real StartButton is visibly disabled")
	for name: String in ["NormalButton", "SwarmButton", "ArmoredButton", "MixedButton", "StartButton", "StopButton", "Status"]:
		_check(value.level.has_node("HUD/CombatDemoPanel/" + name), "Frozen combat HUD control exists: " + name)
	var first: LargeCarcass = value.level.get_node("World/Remains/FirstCarcass") as LargeCarcass
	var second: LargeCarcass = value.level.get_node("World/Remains/SecondCarcass") as LargeCarcass
	_check(first.total_nutrition == 80 and second.total_nutrition == 120
		and first.batch_size == 10 and second.batch_size == 10,
		"The demonstration retains the original80/120 carcasses and ten-unit mining batches")
	var guide_toggle: Button = value.level.get_node_or_null("HUD/ProgressionHintPanel/Toggle") as Button
	if guide_toggle != null and guide_toggle.is_visible_in_tree() and not guide_toggle.disabled:
		await _click(value, guide_toggle.get_global_rect().get_center())
	_checkpoint(value, "initial_preview_no_enemy")


func _assert_batch_configuration(value: Fixture, id: String) -> void:
	var by_type: Dictionary = {}
	# 选择仅更新预览；真实生成器在 start 接受时才冻结/安装这些正式场景导出条目。
	var entries: Array = value.level.get(id + "_batch_entries")
	for entry: EnemySpawnEntry in entries:
		var enemy: BasicEnemy = entry.enemy_scene.instantiate() as BasicEnemy
		var archetype: int = enemy.get_archetype()
		enemy.free()
		_check(not by_type.has(archetype), "Each finite batch has one explicit spawn entry per archetype")
		by_type[archetype] = entry
		if archetype == BasicEnemy.Archetype.NORMAL:
			_check(entry.group_count == (6 if id == "normal" else 2) and entry.group_size == 1
				and is_equal_approx(entry.group_interval, 3.0) and entry.spawn_point_index == -1,
				"Ordinary entry uses six/two single-member groups, three-second spacing and point rotation")
		elif archetype == BasicEnemy.Archetype.SWARM:
			_check(entry.group_count == 1 and entry.group_size == 3 and entry.spawn_point_index == 0
				and is_equal_approx(entry.member_interval, 0.12) and is_equal_approx(entry.member_spacing, 24.0),
				"Swarm entry uses the actual right point, three members, .12-second delay and24px spacing")
		elif archetype == BasicEnemy.Archetype.ARMORED:
			_check(entry.group_count == 1 and entry.group_size == 1 and entry.spawn_point_index == 1,
				"Armored entry is one actual left-point enemy")
	var expected: Array = BATCH_TYPES[id]
	for archetype: int in range(3):
		var count: int = (by_type[archetype] as EnemySpawnEntry).get_total_count() if by_type.has(archetype) else 0
		_check(count == int(expected[archetype]), "Real selected entry set matches the advertised type count")


func _build_original_resource_access(value: Fixture) -> void:
	await _click(value, value.right.global_position + Vector2(0, -25))
	_press(KEY_G)
	await _frames(value, 2)
	await _click(value, FIRST_TARGET)
	_press(KEY_ESCAPE)
	await _frames(value, 2)
	await _click(value, value.left.global_position + Vector2(0, -25))
	_press(KEY_G)
	await _frames(value, 2)
	await _click(value, SECOND_TARGET)
	_press(KEY_ESCAPE)
	await _frames(value, 2)
	_check(value.coordinator.get_all_requests().size() == 2,
		"Original G input creates both real paid construction requests at the frozen targets")
	_checkpoint(value, "both_original_G_requests")


func _paid_normal(value: Fixture, host: HyphaNode, label: String) -> AttackOrgan:
	var before_core: int = value.core.nutrition
	var before_income: int = _sum(value.receipts)
	var before_structure: int = _sum(value.cultivation_costs)
	var before_requests: Dictionary = {}
	for request: Dictionary in value.coordinator.get_all_requests():
		before_requests[String(request.get("construction_id", ""))] = true
	await _click(value, host.global_position)
	_check(value.level.get("selected_node") == host, "Actual endpoint click selects the paid C host")
	_press(KEY_C)
	await _frames(value, 3)
	var request_id: String = ""
	for request: Dictionary in value.coordinator.get_all_requests():
		var id: String = String(request.get("construction_id", ""))
		if not before_requests.has(id):
			request_id = id
	_check(not request_id.is_empty(), "Original C input admits one real local cultivation request")
	if request_id.is_empty():
		return null
	var done: bool = await _until(value, func() -> bool: return value.matured.has(request_id),
		TASK_LIMIT, "Real C material delivery and the original maturation timer finish: " + label)
	if not done:
		evidence["C_failure_" + label] = value.coordinator.get_request(request_id)
		return null
	var reference: WeakRef = value.matured[request_id]["organ"] as WeakRef
	var organ: AttackOrgan = reference.get_ref() as AttackOrgan
	_check(organ != null and organ.nutrition == 4 and _sum(value.cultivation_costs) - before_structure == 8
		and before_core + _sum(value.receipts) - before_income - value.core.nutrition == 12,
		"C ordinary birth is financed by exactly twelve real nutrients, eight structure and stock4")
	_checkpoint(value, label + "_real_paid_birth")
	return organ


func _paid_specialization(value: Fixture, organ: AttackOrgan, direction: int, boundaries: bool) -> bool:
	var host: HyphaNode = organ.get_parent() as HyphaNode
	var weapon: SporeWeapon = host.get_node("SporeWeapon") as SporeWeapon
	await _click(value, organ.global_position + Vector2(0, -25))
	_check(value.panel.get_selected_organ() == organ, "Actual organ click selects its real differentiation panel")
	if boundaries:
		var before_supply: int = value.core.nutrition
		_check(value.combat.request_supply(organ) and organ.incoming_nutrition == 1
			and value.core.nutrition == before_supply - 1,
			"Real production supply pays one legal ordinary ammunition packet before differentiation")
	var old_organ: int = organ.get_instance_id()
	var old_weapon: int = weapon.get_instance_id()
	var stock: int = organ.nutrition
	var incoming: int = organ.incoming_nutrition
	var old_cap: PackedVector2Array = (organ.get_node("Cap") as Polygon2D).polygon.duplicate()
	var before_core: int = value.core.nutrition
	var before_income: int = _sum(value.receipts)
	var before_refund: int = int(value.materials.get_supply_snapshot().get("refunded", 0))
	var requests: int = value.coordinator.get_all_requests().size()
	await _diff_button(value, "PiercingButton" if direction == WeaponProfile.DamageType.ARMOR_PIERCING else "ScatterButton")
	var first_id: int = int(value.differentiation.get_task_snapshot().get("task_id", 0))
	_check(first_id > 0 and value.differentiation.has_active_task() and not organ.is_work_enabled()
		and weapon.fire_timer.is_stopped(), "Real differentiation button starts a paid task and full ceasefire")
	_check(_demo_snapshot(value).get("start_reason") == &"differentiating"
		and String(value.level.call("start_test_batch")).is_empty(),
		"The demo blocks real batch admission throughout active differentiation")
	_check(value.coordinator.get_all_requests().size() == requests
		and value.materials.get_dispatch_owner() == value.level.get_node("Systems/ConstructionSupplyScheduler")
		and not value.materials.auto_supply,
		"Differentiation uses the original shared scheduler and owns no extra construction request")
	if first_id <= 0:
		return false
	var cancellation_refund: int = 0
	var final_id: int = first_id
	if boundaries:
		await _diff_button(value, "PauseButton")
		var early_pause: Dictionary = value.differentiation.get_organ_snapshot(organ)
		var ordinary_arrived: bool = await _until(value, func() -> bool: return organ.incoming_nutrition == 0,
			600, "Legal already-paid ordinary ammunition finishes its original physical route during actual pause")
		var after_ordinary: Dictionary = value.differentiation.get_organ_snapshot(organ)
		_check(ordinary_arrived and after_ordinary.get("state") == &"paused" and not organ.is_work_enabled()
			and organ.nutrition == stock + incoming
			and int(after_ordinary.get("consumed_nutrition", -1)) == int(early_pause.get("consumed_nutrition", 0))
			and is_equal_approx(float(after_ordinary.get("effective_time", -1.0)), float(early_pause.get("effective_time", 0.0))),
			"Paused ordinary organ retains and accepts its legitimate old paid ammunition without advancing differentiation")
		await _diff_button(value, "ContinueButton")
		_check(int(value.differentiation.get_task_snapshot().get("task_id", 0)) == first_id,
			"Continuing a paused task resumes its same attempt before the separate cancel/continue boundary")
		var paid: bool = await _until(value, func() -> bool:
			return int(value.differentiation.get_organ_snapshot(organ).get("consumed_nutrition", 0)) >= 2,
			TASK_LIMIT, "Original physical material delivery funds initial differentiation stages")
		if not paid:
			return false
		await _diff_button(value, "PauseButton")
		var paused: Dictionary = value.differentiation.get_organ_snapshot(organ)
		await _frames(value, 90)
		var settled_pause: Dictionary = value.differentiation.get_organ_snapshot(organ)
		_check(settled_pause.get("state") == &"paused"
			and is_equal_approx(float(settled_pause.get("effective_time", -1.0)), float(paused.get("effective_time", 0.0)))
			and int(settled_pause.get("consumed_nutrition", -1)) == int(paused.get("consumed_nutrition", 0))
			and not organ.is_work_enabled() and organ.nutrition == stock + incoming and organ.incoming_nutrition == 0,
			"Real pause freezes funded work while legal already-paid ordinary ammunition still arrives")
		_check(int(settled_pause.get("buffered_nutrition", 0)) > 0,
			"Paused task receives real refundable material cache without consuming or growing a main vein")
		var refund_budget: int = int(settled_pause.get("buffered_nutrition", 0)) + value.materials.get_in_transit_nutrition()
		var cancel_balance: int = value.core.nutrition
		var cancel_income: int = _sum(value.receipts)
		await _diff_button(value, "CancelButton")
		var cancelled: Dictionary = value.differentiation.get_task_snapshot(first_id)
		_check(not value.differentiation.has_active_task() and cancelled.get("state") == &"cancelled"
			and organ.is_work_enabled() and organ.get_attack_type() == WeaponProfile.DamageType.NORMAL,
			"Cancel restores the same still-ordinary organ and closes its paid attempt")
		_check(value.core.nutrition - cancel_balance - (_sum(value.receipts) - cancel_income) == refund_budget
			and value.materials.get_in_transit_nutrition() == 0
			and int(value.differentiation.get_organ_snapshot(organ).get("buffered_nutrition", -1)) == 0,
			"Cancel refunds every actual cached/in-flight material once to its original finite payer")
		cancellation_refund = refund_budget
		_check(value.differentiation.start_differentiation(organ, WeaponProfile.DamageType.SCATTER) == 0
			and value.differentiation.get_availability(organ, WeaponProfile.DamageType.SCATTER) == &"direction_locked",
			"Cancel cannot change the already-paid specialization direction")
		await _diff_button(value, "ContinueButton")
		final_id = int(value.differentiation.get_task_snapshot().get("task_id", 0))
		var resumed: Dictionary = value.differentiation.get_organ_snapshot(organ)
		_check(final_id > first_id and int(resumed.get("direction", -1)) == direction
			and int(resumed.get("consumed_nutrition", 0)) >= int(cancelled.get("consumed_nutrition", 0))
			and float(resumed.get("effective_time", 0.0)) >= float(cancelled.get("effective_time", 0.0)),
			"Continue creates a new attempt identity and retains the same paid direction and cumulative progress")
		await _until(value, func() -> bool:
			return int(value.differentiation.get_organ_snapshot(organ).get("consumed_nutrition", 0)) >= 3,
			TASK_LIMIT, "Continuation resumes actual paid-stage consumption")
		await _disconnect_boundary(value, organ)
		var old_attempt: Dictionary = value.differentiation.get_task_snapshot(first_id)
		_check(int(old_attempt.get("consumed_nutrition", -1)) == int(cancelled.get("consumed_nutrition", 0))
			and is_equal_approx(float(old_attempt.get("effective_time", -1.0)), float(cancelled.get("effective_time", 0.0))),
			"A continued attempt cannot rewrite the prior cancelled attempt's paid history")
	var completed: bool = await _until(value, func() -> bool: return organ.has_completed_differentiation(),
		TASK_LIMIT, "Real paid specialization completes after all eight materials and five effective seconds")
	var task: Dictionary = value.differentiation.get_organ_snapshot(organ)
	if not completed:
		return false
	_check(task.get("state") == &"completed" and int(task.get("consumed_nutrition", -1)) == 8
		and is_equal_approx(float(task.get("effective_time", -1.0)), 5.0)
		and int(value.completions.get(old_organ, 0)) == 1, "Each real specialization consumes net8 and completes once at five effective seconds")
	_check(organ.get_instance_id() == old_organ and weapon.get_instance_id() == old_weapon
		and organ.get_parent() == host and weapon.inventory_owner == organ
		and organ.nutrition == stock + incoming and organ.incoming_nutrition == 0,
		"Specialization preserves the actual organ, weapon, host and all old/legally-paid ammunition")
	_check(before_core + _sum(value.receipts) - before_income - value.core.nutrition == 8,
		"Actual core balance and intervening real receipts prove net8 despite pause/cancel/continue")
	var account: Dictionary = _material_account(value, host.get_instance_id())
	_check(int(account["buffered"]) == 0 and int(account["in_transit"]) == 0
		and int(value.materials.get_supply_snapshot().get("refunded", 0)) - before_refund == int(account["refunded"]),
		"Completed specialization has no refundable residue and each unique refund matches the original payer ledger")
	_assert_profile(weapon, direction, "Paid completion applies the exact requested actual weapon profile")
	_check(not weapon.fire_timer.is_stopped() and weapon.fire_timer.time_left > weapon.fire_timer.wait_time - _physics_seconds(3),
		"Paid completion resumes with a full matching weapon cooldown")
	var view: OrganDifferentiationView = organ.get_node("DifferentiationView") as OrganDifferentiationView
	var cap: PackedVector2Array = (organ.get_node("Cap") as Polygon2D).polygon
	var expected_cap: PackedVector2Array = PackedVector2Array(OrganDifferentiationView.PIERCING_CAP
		if direction == WeaponProfile.DamageType.ARMOR_PIERCING else OrganDifferentiationView.SCATTER_CAP)
	_check(int(view.get_visual_state().get("attack_type", -1)) == direction
		and not bool(view.get_visual_state().get("differentiating", true)) and cap != old_cap and cap == expected_cap,
		"Same organ visibly adopts its actual hard-spike/scatter cap only after paid completion")
	var consumed: int = int(account["consumed"])
	var refunded: int = int(account["refunded"])
	_check(consumed == 8 and int(account["debited"]) - refunded == 8 and refunded >= cancellation_refund,
		"Unique real shipment debits minus all actual cancel/interruption refunds equal exactly eight consumed materials")
	var result: Dictionary = {"organ_id": old_organ, "weapon_id": old_weapon, "host_id": host.get_instance_id(),
		"direction": direction, "first_attempt": first_id, "final_attempt": final_id,
		"consumed": consumed, "debited": account["debited"], "refunded": refunded,
		"cancel_refunded": cancellation_refund, "interruption_refunded": refunded - cancellation_refund,
		"refund_ids": account["refund_ids"], "effective_time": task.get("effective_time"),
		"stock_before": stock, "paid_incoming_before": incoming, "stock_after": organ.nutrition,
		"profile": _profile_summary(weapon), "same_objects": true}
	(evidence["paid_specializations"] as Array).append(result)
	_checkpoint(value, "paid_AP_completed" if boundaries else "paid_scatter_completed")
	return true


func _disconnect_boundary(value: Fixture, organ: AttackOrgan) -> void:
	var host: HyphaNode = organ.get_parent() as HyphaNode
	var route: NetworkRoute = value.network.find_route(value.core, host)
	_check(route.found and not route.segments.is_empty(), "Differentiation has a real existing edge to disconnect")
	if not route.found or route.segments.is_empty():
		return
	# 先用原按钮停住当前已付款阶段，避免把本帧正在结束的真实工作当成断路后推进。
	await _diff_button(value, "PauseButton")
	var before: Dictionary = value.differentiation.get_organ_snapshot(organ)
	var cut_edges: Array[Dictionary] = []
	for edge: HyphaEdge in value.network.get_registered_edges():
		if edge.start_node == host or edge.end_node == host:
			cut_edges.append({"edge": edge, "start": edge.start_node, "end": edge.end_node,
				"edge_id": edge.get_instance_id()})
	_check(not cut_edges.is_empty(), "A real host cut identifies every original incident edge, including possible alternate routes")
	for cut: Dictionary in cut_edges:
		var edge: HyphaEdge = cut["edge"] as HyphaEdge
		value.network.unregister_edge(edge)
		_check(not value.network.is_edge_valid(edge), "Production network unregisters an actually cut original edge")
		if edge.start_node == host:
			edge.start_node = null
		else:
			edge.end_node = null
	_check(not value.network.find_available_route(value.core, host).found,
		"The real endpoint cut leaves no existing alternate core route")
	await _diff_button(value, "ContinueButton")
	var blocked_start: Dictionary = value.differentiation.get_organ_snapshot(organ)
	_check(blocked_start.get("wait_reason") == &"disconnected"
		and int(blocked_start.get("consumed_nutrition", -1)) == int(before.get("consumed_nutrition", 0))
		and is_equal_approx(float(blocked_start.get("effective_time", -1.0)), float(before.get("effective_time", 0.0))),
		"Resuming the actually disconnected same task consumes no material or effective time")
	await _frames(value, 90)
	var blocked: Dictionary = value.differentiation.get_organ_snapshot(organ)
	_check(not value.network.find_available_route(value.core, host).found
		and blocked.get("wait_reason") == &"disconnected" and not bool(blocked.get("can_progress", true))
		and int(blocked.get("consumed_nutrition", -1)) == int(blocked_start.get("consumed_nutrition", 0))
		and is_equal_approx(float(blocked.get("effective_time", -1.0)), float(blocked_start.get("effective_time", 0.0)))
		and not organ.is_work_enabled(), "A real endpoint cut freezes the same paid differentiation without unpaid progress")
	_checkpoint(value, "actual_edge_disconnected")
	var ids: Array[int] = []
	for cut: Dictionary in cut_edges:
		var edge: HyphaEdge = cut["edge"] as HyphaEdge
		edge.start_node = cut["start"] as Node2D
		edge.end_node = cut["end"] as Node2D
		_check(value.network.register_edge(edge), "Production network restores the same original edge and endpoints")
		ids.append(int(cut["edge_id"]))
	await _frames(value, 2)
	_check(value.network.find_available_route(value.core, host).found
		and int(value.differentiation.get_organ_snapshot(organ).get("task_id", 0)) == int(before.get("task_id", -1)),
		"Restoring the original edge resumes the same attempt without a free replacement route")
	(evidence["fault_boundaries"] as Array).append({"case": "actual_edge_cut_and_restore",
		"edge_ids": ids, "paid_consumed": before.get("consumed_nutrition"),
		"before_effective_time": before.get("effective_time"),
		"blocked_start_effective_time": blocked_start.get("effective_time"),
		"frozen_effective_time": blocked.get("effective_time"),
		"blocked_reason": blocked.get("wait_reason")})


func _material_account(value: Fixture, host_id: int) -> Dictionary:
	var account: Dictionary = {"debited": 0, "refunded": 0, "consumed": 0,
		"buffered": 0, "in_transit": 0, "refund_ids": []}
	var seen: Dictionary = {}
	for shipment: Dictionary in value.materials.get_shipment_records():
		if int(shipment.get("host_id", 0)) != host_id:
			continue
		var id: String = String(shipment.get("shipment_id", ""))
		_check(not id.is_empty() and not seen.has(id), "Specialization account includes each real shipment identity once")
		if id.is_empty() or seen.has(id):
			continue
		seen[id] = true
		var debited: bool = bool(shipment.get("debited", false))
		var refunded: bool = bool(shipment.get("refunded", false))
		account["debited"] += 1 if debited else 0
		account["refunded"] += 1 if refunded else 0
		account["consumed"] += 1 if bool(shipment.get("consumed", false)) else 0
		account["buffered"] += int(shipment.get("buffered_nutrition", 0))
		if debited and not bool(shipment.get("settled", false)) and not refunded:
			account["in_transit"] += 1
		if refunded:
			_check(debited and not bool(shipment.get("consumed", false))
				and int(shipment.get("source_id", 0)) == value.core.get_instance_id(),
				"Each unique cancel or transport-interruption refund returns a paid unconsumed unit to its original core")
			(account["refund_ids"] as Array).append(id)
	return account


func _repair_history_boundary(value: Fixture) -> void:
	var route: NetworkRoute = value.network.find_route(value.core, value.right)
	if not route.found or route.segments.is_empty():
		_check(false, "Repair boundary uses an original live colony edge")
		return
	var edge: HyphaEdge = route.segments[0].edge
	var ids: Array[int] = []
	var tasks: Array[Dictionary] = []
	var before: int = _sum(value.repair_costs)
	var expected_history: int = 0
	for _attempt: int in range(2):
		# 明示损伤边界；后续一切修复付款、运送和时钟仍由原生产模块完成。
		var previous_health: float = edge.health
		var maximum: float = edge.max_health
		var preexisting_missing: float = maxf(maximum - previous_health, 0.0)
		var damage: float = edge.take_damage(10.0)
		_check(is_equal_approx(damage, 10.0), "Explicit repair fixture inflicts exactly ten edge HP")
		var missing: float = maxf(maximum - edge.health, 0.0)
		var expected_cost: int = int(ceil(missing / RepairSystem.HEALTH_PER_NUTRITION))
		var preview: Dictionary = value.repair.preview_repair(edge)
		_check(bool(preview.get("valid", false)) and int(preview.get("estimated_cost", -1)) == expected_cost,
			"Real repair quote exactly covers independent current HP deficit including prior natural vein growth")
		var core_before: int = value.core.nutrition
		var income_before: int = _sum(value.receipts)
		var start_tick: int = Engine.get_physics_frames()
		var id: int = value.repair.request_repair(edge)
		_check(id > 0 and not ids.has(id), "Each real repair request has a new task identity")
		ids.append(id)
		var completed: bool = await _until(value, func() -> bool:
			return value.repair.get_task_snapshot().get("state") == &"completed",
			TASK_LIMIT, "Real paid packet and original repair clock restore the explicit ten-HP damage")
		var task: Dictionary = value.repair.get_task_snapshot()
		_check(completed and is_equal_approx(edge.max_health, maximum) and is_equal_approx(edge.health, maximum)
			and int(task.get("consumed_nutrition", -1)) == expected_cost
			and is_equal_approx(float(task.get("restored_health", -1.0)), missing)
			and core_before + _sum(value.receipts) - income_before - value.core.nutrition == expected_cost,
			"Each real repair pays its full actual HP deficit once, restores that exact HP and debits the same finite core cost")
		_check(_physics_seconds(Engine.get_physics_frames() - start_tick) + _physics_seconds(2)
			>= missing / RepairSystem.HEALING_SPEED,
			"The actual repair clock spends the full required healing time")
		expected_history += expected_cost
		tasks.append({"task_id": id, "previous_health": previous_health, "maximum_health": maximum,
			"preexisting_missing": preexisting_missing, "explicit_damage": damage,
			"actual_missing": missing, "expected_cost": expected_cost,
			"consumed": task.get("consumed_nutrition"), "restored_health": task.get("restored_health")})
		_checkpoint(value, "repair_history_task_" + str(id))
	_check(_sum(value.repair_costs) - before == expected_history
		and expected_history >= 2 and is_equal_approx(edge.health, edge.max_health),
		"Two completed real repairs preserve every irreversible unit from both independently priced HP deficits")
	(evidence["fault_boundaries"] as Array).append({"case": "explicit_damage_real_paid_repairs",
		"task_ids": ids, "tasks": tasks, "expected_history": expected_history,
		"historical_consumed": _sum(value.repair_costs) - before})


func _remove_paid_organ_boundary(value: Fixture, organ: AttackOrgan) -> void:
	var host: HyphaNode = organ.get_parent() as HyphaNode
	var weapon: SporeWeapon = host.get_node("SporeWeapon") as SporeWeapon
	await _click(value, organ.global_position + Vector2(0, -25))
	await _diff_button(value, "PiercingButton")
	var id: int = int(value.differentiation.get_task_snapshot().get("task_id", 0))
	var funded: bool = await _until(value, func() -> bool:
		return int(value.differentiation.get_organ_snapshot(organ).get("consumed_nutrition", 0)) >= 1,
		TASK_LIMIT, "Additional genuinely paid C organ consumes one real differentiation material before removal")
	if not funded:
		return
	await _diff_button(value, "PauseButton")
	await _frames(value, 90)
	var task: Dictionary = value.differentiation.get_organ_snapshot(organ)
	var refundable: int = int(task.get("buffered_nutrition", 0)) + value.materials.get_in_transit_nutrition()
	_check(int(task.get("buffered_nutrition", 0)) > 0 and value.materials.get_in_transit_nutrition() > 0,
		"Removal boundary owns both actually arrived cache and still-paid physical material transit")
	var stock: int = organ.nutrition
	var sink_before: int = value.removed_stock
	var before_core: int = value.core.nutrition
	var before_income: int = _sum(value.receipts)
	var callbacks: Array[Dictionary] = _material_callbacks(value, id)
	var replay: Dictionary = {"calls": 0, "stable": true}
	# 连接晚于生产退出监听；这里只重放已经因实际移除而结算的旧身份。
	organ.tree_exiting.connect(func() -> void:
		var balance: int = value.core.nutrition
		for binding: Dictionary in callbacks:
			var packet_ref: WeakRef = binding["packet"] as WeakRef
			var packet: NutrientPacket = packet_ref.get_ref() as NutrientPacket if is_instance_valid(packet_ref.get_ref()) else null
			var callback: Callable = binding["callback"]
			if packet != null and callback.is_valid():
				callback.call(packet)
				callback.call(packet)
				replay["calls"] += 2
		replay["stable"] = value.core.nutrition == balance)
	organ.queue_free()
	weapon.queue_free()
	await _frames(value, 3)
	_check(not is_instance_valid(organ) and host.is_organ_slot_available()
		and not value.differentiation.has_active_task() and value.materials.get_in_transit_nutrition() == 0,
		"Actual organ removal closes its task, frees the real slot and settles paid material transport")
	_check(value.core.nutrition - before_core - (_sum(value.receipts) - before_income) == refundable,
		"Actual removal returns only the real refundable cache and paid material packets")
	_check(value.removed_stock - sink_before == stock and stock == 4
		and bool(replay["stable"]) and int(replay["calls"]) > 0,
		"Removed C inventory becomes one stock sink; replayed settled callbacks cannot duplicate refunds")
	var cancelled: Dictionary = value.differentiation.get_task_snapshot(id)
	_check(cancelled.get("state") == &"cancelled" and int(cancelled.get("consumed_nutrition", -1)) == int(task.get("consumed_nutrition", 0)),
		"Removal preserves irreversible paid differentiation consumption after the organ disappears")
	_checkpoint(value, "real_paid_organ_removed")
	(evidence["fault_boundaries"] as Array).append({"case": "remove_real_C_organ",
		"task_id": id, "consumed": cancelled.get("consumed_nutrition"),
		"refunded": refundable, "stock_sink": stock, "settled_callback_replay": replay})


func _run_batch(value: Fixture, kind: String) -> void:
	await _combat_button(value, kind.capitalize() + "Button")
	var before: Dictionary = _demo_snapshot(value)
	_check(bool(before.get("mature", false)) and bool(before.get("can_start", false))
		and before.get("start_reason") == &"", "True mature idle state admits the selected real batch: " + kind)
	var spent_before: int = value.spent
	var health_before: int = value.core.health
	await _combat_button(value, "StartButton")
	var started: Dictionary = _demo_snapshot(value)
	var id: String = String(started.get("batch_id", ""))
	_check(not id.is_empty() and String(started.get("phase", "")) == "fighting"
		and not bool(started.get("can_start", true))
		and String(value.level.call("start_test_batch")).is_empty(),
		"Real StartButton opens one finite batch and rejects a second start: " + kind)
	_check(not bool(value.level.call("select_test_batch", "normal")),
		"A running or live-enemy batch cannot change the selected test plan")
	_assert_batch_configuration(value, kind)
	var finished: bool = await _until(value, func() -> bool:
		return String(_demo_snapshot(value).get("phase", "")) == "cleared",
		COMBAT_LIMIT, "Actual specialized weapons defeat the entire controlled batch: " + kind)
	var result: Dictionary = _demo_snapshot(value)
	var types: Array[int] = [0, 0, 0]
	for record: Dictionary in value.enemies.values():
		if String(record["batch_id"]) == id:
			types[int(record["archetype"])] += 1
	var expected: Array = BATCH_TYPES[kind]
	var total: int = int(expected[0]) + int(expected[1]) + int(expected[2])
	_check(finished and types == expected and int(result.get("planned", -1)) == total
		and int(result.get("spawned", -1)) == total and int(result.get("defeated", -1)) == total
		and int(result.get("active", -1)) == 0 and int(value.batch_finishes.get(id, 0)) == 1,
		"Real batch clears exactly its advertised finite archetypes with one completion: " + kind)
	_check(value.core.health == health_before and value.core.health > 0,
		"Recommended paid left AP/right scatter complete the actual batch without core damage: " + kind)
	_check(int(result.get("batch_spent", -1)) == value.spent - spent_before,
		"Batch spending equals actual receipt-measured ammunition cost: " + kind)
	var ap_rounds: int = 0
	var scatter_rounds: int = 0
	var scatter_targets: int = 0
	for shot: Dictionary in value.shots.values():
		if String(shot["batch_id"]) != id:
			continue
		if int(shot["damage_type"]) == WeaponProfile.DamageType.ARMOR_PIERCING:
			ap_rounds += 1
		elif int(shot["damage_type"]) == WeaponProfile.DamageType.SCATTER:
			scatter_rounds += 1
			scatter_targets = maxi(scatter_targets, int(shot["projectile_count"]))
	if kind in ["swarm", "mixed"]:
		_check(scatter_rounds >= 2 and scatter_targets == 3,
			"Actual scatter combats the real three-member right group with three-target volleys")
	if kind in ["armored", "mixed"]:
		_check(ap_rounds >= 3, "Actual AP pays at least three two-nutrition volleys for the real seventy-two-HP armored target")
	_verify_spawn_geometry(value, id)
	var spawned: int = value.spawner.spawned_count
	await _frames(value, 190)
	_check(value.spawner.spawned_count == spawned and value.spawner.spawn_timer.is_stopped()
		and value.spawner.start_timer.is_stopped() and int(value.batch_finishes.get(id, 0)) == 1,
		"Cleared finite batch creates no automatic next wave or duplicate victory")
	_checkpoint(value, "actual_" + kind + "_cleared")
	(evidence["formal_batches"] as Array).append({"kind": kind, "id": id, "planned": total,
		"types": types, "spawned": result.get("spawned"), "defeated": result.get("defeated"),
		"actual_spent": value.spent - spent_before, "AP_rounds": ap_rounds,
		"scatter_rounds": scatter_rounds, "largest_scatter_volley": scatter_targets,
		"core_health": value.core.health})


func _verify_spawn_geometry(value: Fixture, id: String) -> void:
	var swarm: Array[Dictionary] = []
	var ordinary: Array[Dictionary] = []
	var points: Node2D = value.level.get_node("World/SpawnPoints") as Node2D
	var east: Vector2 = (points.get_child(0) as Node2D).global_position
	var west: Vector2 = (points.get_child(1) as Node2D).global_position
	for record: Dictionary in value.enemies.values():
		if String(record["batch_id"]) != id:
			continue
		var position: Vector2 = record["spawn_position"]
		match int(record["archetype"]):
			BasicEnemy.Archetype.NORMAL:
				ordinary.append(record)
			BasicEnemy.Archetype.SWARM:
				swarm.append(record)
				_check(position.distance_to(east) <= 24.01, "Each actual swarm member spawns around the frozen right point")
			BasicEnemy.Archetype.ARMORED:
				_check(position.distance_to(west) < 0.01, "Actual armored actor enters from the frozen left point")
	for index: int in range(1, swarm.size()):
		var previous: Dictionary = swarm[index - 1]
		var current: Dictionary = swarm[index]
		_check((current["spawn_position"] as Vector2).distance_to(previous["spawn_position"]) > 23.99
			and (current["spawn_position"] as Vector2).distance_to(previous["spawn_position"]) < 24.01,
			"Real grouped swarm placement has exactly twenty-four-pixel member spacing")
		_check(_physics_seconds(int(current["spawn_tick"]) - int(previous["spawn_tick"])) + _physics_seconds(1) >= 0.12,
			"Actual group members wait the original .12-second spawn timer")
	for index: int in range(ordinary.size()):
		var position: Vector2 = ordinary[index]["spawn_position"]
		_check(position.distance_to(east if index % 2 == 0 else west) < 0.01,
			"Actual ordinary single-member groups rotate between the original spawn points")
		if index > 0:
			_check(_physics_seconds(int(ordinary[index]["spawn_tick"]) - int(ordinary[index - 1]["spawn_tick"]))
				+ _physics_seconds(1) >= 3.0, "Actual ordinary groups wait the unchanged three-second interval")


func _stop_button_boundary(value: Fixture) -> void:
	await _combat_button(value, "NormalButton")
	await _combat_button(value, "StartButton")
	_check(value.spawner.spawned_count == 1 and not value.spawner.spawn_timer.is_stopped(),
		"Real StopButton is exercised after one normal spawn and before the next timed group")
	var stale: Array[Callable] = []
	for binding: Dictionary in value.spawner.spawn_timer.timeout.get_connections():
		stale.append(binding["callable"])
	await _combat_button(value, "StopButton")
	var before: int = value.spawner.spawned_count
	var snapshot: Dictionary = _demo_snapshot(value)
	for callback: Callable in stale:
		if callback.is_valid():
			callback.call()
	_check(String(snapshot.get("phase", "")) == "stopped" and before == 1
		and value.spawner.spawned_count == before and value.spawner.spawn_timer.is_stopped()
		and value.spawner.start_timer.is_stopped(),
		"Manual stop closes pending spawn timers before old timeout callbacks are replayed")
	_check(_live_enemy_count(value) > 0 and snapshot.get("start_reason") == &"enemies_remaining"
		and String(value.level.call("start_test_batch")).is_empty(),
		"Manual Stop preserves its live actor and blocks a new batch until actual combat clears it")
	await _frames(value, 190)
	_check(value.spawner.spawned_count == before, "Stopped group creates no delayed second member")
	(evidence["fault_boundaries"] as Array).append({"case": "real_StopButton_mid_normal_batch",
		"spawned_at_stop": before, "retained_actors": snapshot.get("active"),
		"old_timeout_callbacks": stale.size()})


func _material_callbacks(value: Fixture, task_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in value.materials.get_shipment_records():
		if int(record.get("task_id", 0)) != task_id:
			continue
		var packet: Variant = record.get("packet")
		if not is_instance_valid(packet):
			continue
		for signal_name: StringName in [&"arrived", &"interrupted"]:
			for binding: Dictionary in packet.get_signal_connection_list(signal_name):
				var callback: Callable = binding["callable"]
				if callback.get_object() == value.materials:
					result.append({"callback": callback, "packet": weakref(packet)})
	return result


func _restart_boundary(value: Fixture, organ: AttackOrgan) -> void:
	await _click(value, organ.global_position + Vector2(0, -25))
	await _diff_button(value, "ScatterButton")
	var id: int = int(value.differentiation.get_task_snapshot().get("task_id", 0))
	var in_flight: bool = await _until(value, func() -> bool: return value.materials.get_in_transit_nutrition() > 0,
		TASK_LIMIT, "Real R boundary begins while a newly paid differentiation material is physically in flight")
	if not in_flight:
		return
	_checkpoint(value, "before_actual_R")
	var refundable: int = (value.materials.get_in_transit_nutrition()
		+ int(value.differentiation.get_resource_snapshot().get("buffered_nutrition", 0))
		+ value.combat.get_in_transit_count())
	var callbacks: Array[Dictionary] = _material_callbacks(value, id)
	var old_core: MotherCore = value.core
	var old_system: DifferentiationSystem = value.differentiation
	var old_materials: DifferentiationSupplySystem = value.materials
	var audit: Dictionary = {"refundable": refundable, "positive_refunds": 0,
		"last_balance": old_core.nutrition, "stopped_before_refund": true,
		"callback_replays": 0, "replay_stable": true, "replayed": false}
	old_core.nutrition_changed.connect(func(balance: int) -> void:
		if balance > int(audit["last_balance"]):
			audit["positive_refunds"] += balance - int(audit["last_balance"])
			audit["stopped_before_refund"] = bool(audit["stopped_before_refund"]) and old_system.is_stopped()
		audit["last_balance"] = balance)
	old_materials.supply_changed.connect(func(snapshot: Dictionary) -> void:
		if (bool(audit["replayed"]) or not bool(snapshot.get("stopped", false))
			or old_materials.get_in_transit_nutrition() != 0):
			return
		audit["replayed"] = true
		var before: int = old_core.nutrition
		for binding: Dictionary in callbacks:
			var reference: WeakRef = binding["packet"] as WeakRef
			var packet: NutrientPacket = reference.get_ref() as NutrientPacket if is_instance_valid(reference.get_ref()) else null
			var callback: Callable = binding["callback"]
			if packet != null and callback.is_valid():
				callback.call(packet)
				callback.call(packet)
				audit["callback_replays"] += 2
		audit["replay_stable"] = old_core.nutrition == before)
	value.retiring = true
	_press(KEY_R)
	await _frames(value, 6)
	_check(not is_instance_valid(value.level) and current_scene != null
		and current_scene.scene_file_path == DEMO_PATH,
		"Real R destroys the old scene and reloads the actual combat specialization demo")
	_check(value.stopping_reasons.has("restart") and int(audit["positive_refunds"]) == refundable
		and bool(audit["stopped_before_refund"]) and int(audit["callback_replays"]) > 0
		and bool(audit["replay_stable"]),
		"R closes old admission before exact refunds; stale old material callbacks cannot settle again")
	if current_scene == null or current_scene.scene_file_path != DEMO_PATH:
		return
	var fresh: Node2D = current_scene as Node2D
	var fresh_core: MotherCore = fresh.get_node("World/Colony/MotherCore") as MotherCore
	var fresh_diff: DifferentiationSystem = fresh.get_node("Systems/DifferentiationSystem") as DifferentiationSystem
	var fresh_materials: DifferentiationSupplySystem = fresh.get_node("Systems/DifferentiationSupplySystem") as DifferentiationSupplySystem
	var fresh_progress: ColonyProgress = fresh.get_node("Systems/ColonyProgress") as ColonyProgress
	var fresh_spawner: EnemySpawner = fresh.get_node("Systems/EnemySpawner") as EnemySpawner
	var snapshot: Dictionary = fresh.call("get_combat_demo_snapshot")
	_check(fresh_core.nutrition == 72 and fresh_core.health == 240 and fresh_progress.get_total_recovered() == 0
		and not fresh_diff.has_active_task() and fresh_diff.get_task_snapshot().get("state") == &"idle"
		and fresh_materials.get_shipment_records().is_empty()
		and fresh_spawner.spawned_count == 0 and not fresh_spawner.auto_start
		and String(snapshot.get("phase", "")) == "preparing" and snapshot.get("start_reason") == &"stage_locked",
		"Fresh R scene restores original finite capital, immature state and empty batch/material history")
	for path: String in ["World/Colony/Nodes/HyphaNode", "World/Colony/Nodes/RightNode"]:
		var host: HyphaNode = fresh.get_node(path) as HyphaNode
		var fresh_organ: AttackOrgan = host.get_node("AttackOrgan") as AttackOrgan
		_check(fresh_organ.nutrition == 4 and fresh_organ.incoming_nutrition == 0
			and not fresh_organ.has_completed_differentiation(), "Fresh ordinary organ keeps original stock4 without old specialization")
		_assert_profile(host.get_node("SporeWeapon") as SporeWeapon, WeaponProfile.DamageType.NORMAL,
			"Fresh R ordinary weapons retain the actual new178 configuration")
	var resources: Dictionary = fresh.call("get_combat_resource_snapshot")
	_check(int(resources.get("initial_total", -1)) == INITIAL_TOTAL
		and int(resources.get("accounted_total", -1)) == INITIAL_TOTAL
		and int(resources.get("enemy_created_nutrition", -1)) == 0,
		"Fresh R resource ledger contains only the new original280 source, with no old bounty or stock sink")
	evidence["restart"] = audit
	await _fresh_lifecycle_boundaries(value, fresh)


func _fresh_lifecycle_boundaries(value: Fixture, fresh: Node2D) -> void:
	# 明示独立生命周期边界；这个新的未成熟场景不贡献正式战斗、成长或收入证据。
	var lifecycle: Dictionary = {"core_death": [], "scene_change": []}
	fresh.connect("level_stopping", func(reason: StringName) -> void:
		(lifecycle["core_death"] as Array).append(String(reason)))
	var core: MotherCore = fresh.get_node("World/Colony/MotherCore") as MotherCore
	core.take_damage(core.health)
	await _frames(value, 3)
	var snapshot: Dictionary = fresh.call("get_combat_demo_snapshot")
	var spawner: EnemySpawner = fresh.get_node("Systems/EnemySpawner") as EnemySpawner
	_check(String(snapshot.get("phase", "")) == "defeated" and not bool(snapshot.get("can_start", true))
		and String(fresh.call("start_test_batch")).is_empty() and spawner.start_timer.is_stopped()
		and spawner.spawn_timer.is_stopped() and (lifecycle["core_death"] as Array).has("core_depleted"),
		"Actual core-death lifecycle stops the demo before any future batch can be admitted")
	fresh.call("stop_demo")
	fresh.call("stop_demo")
	_check(String((fresh.call("get_combat_demo_snapshot") as Dictionary).get("phase", "")) == "defeated",
		"Repeated demo stop preserves the actual defeated terminal state")
	# R 的存活新场景再次用于真实换场景通知；不注入成熟、不运行任何战斗。
	_press(KEY_R)
	await _frames(value, 6)
	var changing: Node2D = current_scene as Node2D
	_check(changing != null and changing.scene_file_path == DEMO_PATH,
		"R from defeated demo produces another clean real scene")
	if changing == null:
		return
	changing.connect("level_stopping", func(reason: StringName) -> void:
		(lifecycle["scene_change"] as Array).append(String(reason)))
	_press_action(&"progression_demo")
	await _frames(value, 5)
	_check(not is_instance_valid(changing) and current_scene != null
		and current_scene.scene_file_path == "res://scenes/levels/progression_demo.tscn"
		and (lifecycle["scene_change"] as Array).has("scene_change"),
		"Original scene-change input notifies and disposes the old combat demo before entering progression_demo")
	evidence["isolated_fresh_lifecycle"] = lifecycle


func _demo_snapshot(value: Fixture) -> Dictionary:
	return value.level.call("get_combat_demo_snapshot")


func _host_at(value: Fixture, position: Vector2) -> HyphaNode:
	for node: Node2D in value.network.get_registered_nodes():
		if node is HyphaNode and node.global_position.distance_to(position) < 0.1:
			return node as HyphaNode
	return null


func _live_enemy_count(value: Fixture) -> int:
	var count: int = 0
	for node: Node in value.level.get_node("World/Enemies").get_children():
		if node is BasicEnemy and not node.is_queued_for_deletion() and (node as BasicEnemy).is_alive():
			count += 1
	return count


func _recovery_empty(value: Fixture) -> bool:
	if (value.recycling.get_in_transit_count() > 0 or value.returns.get_in_transit_count() > 0
		or value.combat.get_in_transit_count() > 0):
		return false
	for stomach: DigestiveOrgan in value.level.call("get_digestive_organs"):
		if stomach.get_queued_nutrition() > 0 or stomach.incoming_remains > 0 or stomach.get_output_nutrition() > 0:
			return false
	for node: Node in value.level.get_node("World/Remains").get_children():
		if node.is_queued_for_deletion():
			continue
		if node is LargeCarcass and (node as LargeCarcass).get_remaining_nutrition() > 0:
			return false
		if node is EnemyRemains and (node as EnemyRemains).nutrition_value > 0:
			return false
	return true


func _assert_profile(weapon: SporeWeapon, kind: int, description: String) -> void:
	var profile: WeaponProfile = weapon.get_weapon_profile()
	var stats: Dictionary = {
		WeaponProfile.DamageType.NORMAL: [12, 0.8, 178.0, 1, 1, 0.0],
		WeaponProfile.DamageType.ARMOR_PIERCING: [24, 1.8, 178.0, 2, 1, 0.0],
		WeaponProfile.DamageType.SCATTER: [6, 0.9, 145.0, 1, 3, 60.0],
	}
	var expected: Array = stats[kind]
	_check(profile.damage_type == kind and profile.damage == int(expected[0])
		and is_equal_approx(profile.fire_interval, float(expected[1]))
		and is_equal_approx(profile.attack_range, float(expected[2]))
		and profile.nutrition_cost == int(expected[3]) and profile.max_targets == int(expected[4])
		and is_equal_approx(profile.spread_angle_degrees, float(expected[5]))
		and is_equal_approx(weapon.attack_range, profile.attack_range)
		and is_equal_approx((weapon.get_node("FireTimer") as Timer).wait_time, profile.fire_interval), description)


func _profile_summary(weapon: SporeWeapon) -> Dictionary:
	var profile: WeaponProfile = weapon.get_weapon_profile()
	return {"damage_type": int(profile.damage_type), "damage": profile.damage,
		"interval": profile.fire_interval, "range": profile.attack_range,
		"cost": profile.nutrition_cost, "max_targets": profile.max_targets,
		"spread": profile.spread_angle_degrees}


func _diagnostic(value: Fixture) -> Dictionary:
	return {"core_health": value.core.health, "core_nutrition": value.core.nutrition,
		"recovered": value.progress.get_total_recovered(), "access": value.level.call("get_resource_access_snapshot"),
		"construction": value.coordinator.get_snapshot(), "demo": _demo_snapshot(value),
		"differentiation": value.differentiation.get_task_snapshot(), "materials": value.materials.get_supply_snapshot(),
		"resources": value.last_parts, "first_resource_failure": value.first_resource_failure}


func _packet_summary(value: Fixture) -> Dictionary:
	var result: Dictionary = {}
	for record: Dictionary in value.packets.values():
		var kind: String = String(record["kind"])
		if not result.has(kind):
			result[kind] = {"created": 0, "arrived": 0, "interrupted": 0, "local_source_arrivals": 0}
		result[kind]["created"] += 1
		result[kind]["arrived"] += int(record["arrivals"])
		result[kind]["interrupted"] += int(record["interruptions"])
		result[kind]["local_source_arrivals"] += 1 if bool(record.get("local_repair_arrival", false)) else 0
	return result


func _delivered_packet_count(value: Fixture, kind: String) -> int:
	var count: int = 0
	for record: Dictionary in value.packets.values():
		if String(record["kind"]) == kind:
			count += int(record["arrivals"])
	return count


func _combat_button(value: Fixture, name: String) -> bool:
	var button: Button = value.level.get_node_or_null("HUD/CombatDemoPanel/" + name) as Button
	if button == null or not button.is_visible_in_tree() or button.disabled:
		_check(false, "Real combat HUD button is available: " + name)
		return false
	await _click(value, button.get_global_rect().get_center())
	return true


func _diff_button(value: Fixture, name: String) -> bool:
	var button: Button = value.panel.get_node_or_null("%" + name) as Button
	if button == null or not button.is_visible_in_tree() or button.disabled:
		_check(false, "Real differentiation HUD button is available: " + name)
		return false
	await _click(value, button.get_global_rect().get_center())
	return true


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event, true)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	root.push_input(release, true)


func _press_action(action: StringName) -> void:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event, true)
	var release: InputEventAction = event.duplicate() as InputEventAction
	release.pressed = false
	root.push_input(release, true)


func _click(value: Fixture, point: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = true
	root.push_input(event, true)
	await _frames(value, 2)
	var release: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	release.pressed = false
	root.push_input(release, true)
	await _frames(value, 2)


func _step(value: Fixture) -> void:
	await physics_frame
	await process_frame
	value.tick += 1
	if value.active and not value.retiring and is_instance_valid(value.level):
		_audit(value)
		if value.tick % 3600 == 0:
			print("COMBAT_SPECIALIZATION_FLOW ", JSON.stringify({"frame": value.tick,
				"recovered": value.progress.get_total_recovered(), "core": value.core.nutrition,
				"demo": _demo_snapshot(value)}))


func _frames(value: Fixture, count: int) -> void:
	for _frame: int in range(count):
		await _step(value)


func _until(value: Fixture, condition: Callable, limit: int, description: String) -> bool:
	var reached: bool = bool(condition.call())
	for _frame: int in range(limit):
		if reached or value.core.health <= 0:
			break
		await _step(value)
		reached = bool(condition.call())
	_check(reached, description)
	return reached


func _physics_seconds(ticks: int) -> float:
	return float(ticks) / float(Engine.physics_ticks_per_second)


func _sum(values: Dictionary) -> int:
	var amount: int = 0
	for value: Variant in values.values():
		amount += int(value)
	return amount


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition and not failures.has(description):
		failures.append(description)
		push_error(description)


func _json_ready(value: Variant) -> Variant:
	if typeof(value) == TYPE_OBJECT:
		if not is_instance_valid(value):
			return null
		if value is WeakRef:
			return _json_ready(value.get_ref())
		return {"instance_id": value.get_instance_id()}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[str(key)] = _json_ready(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_json_ready(item))
		return result
	if value is Vector2:
		return [value.x, value.y]
	return value


func _finish() -> void:
	if fixture != null:
		fixture.retiring = true
		fixture.active = false
		if node_added.is_connected(fixture.node_callback):
			node_added.disconnect(fixture.node_callback)
		# bound Fixture -> Callable -> Fixture 是自环；仅 disconnect 不释放其绑定参数。
		fixture.node_callback = Callable()
		evidence["real_hit_samples"] = fixture.hits
		evidence["unique_volley_receipts"] = fixture.shots.size()
		evidence["independent_combat_consumed"] = fixture.spent
	var scene: Node = current_scene
	current_scene = null
	if is_instance_valid(scene):
		if scene.has_method("stop_demo"):
			scene.call("stop_demo")
		scene.queue_free()
	for _frame: int in range(4):
		await physics_frame
		await process_frame
	_check(root.get_child_count() == 0, "Acceptance releases all formal scenes and physical cargo containers")
	var result: Dictionary = {"checks": checks, "failures": failures, "evidence": _json_ready(evidence)}
	_release_fixture_references()
	print("COMBAT_SPECIALIZATION_CYCLE_TEST_RESULT ", JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)


func _release_fixture_references() -> void:
	if fixture == null:
		return
	# 已复制纯 JSON 证据，所有原场景也已退出；立刻释放观察用 WeakRef 与历史节点句柄。
	fixture.node_callback = Callable()
	fixture.packets.clear()
	fixture.return_packets.clear()
	fixture.projectiles.clear()
	fixture.enemies.clear()
	fixture.matured.clear()
	fixture = null
