extends SceneTree
## 8.5：用真实武器齐射、默认弹速和死亡尸体验证敌人与武器的对应关系。
## configure_profile 仅为隔离测试接线，不代表玩家已完成付费分化。
## 九轮普通弹与混合循环使用 ready 前声明的有限九点容量/库存，测试中不补弹。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const NORMAL_ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const SWARM_ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/swarm_enemy.tscn")
const ARMORED_ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/armored_enemy.tscn")
const REMAINS_SPAWNER_SCENE: PackedScene = preload("res://scenes/systems/remains_spawner.tscn")
const NORMAL_PROFILE: WeaponProfile = preload("res://resources/weapons/normal_spore.tres")
const PIERCING_PROFILE: WeaponProfile = preload("res://resources/weapons/armor_piercing_spore.tres")
const SCATTER_PROFILE: WeaponProfile = preload("res://resources/weapons/scatter_spore.tres")
const FINITE_NINE_STOCK: int = 9
const ENEMY_STATS: Dictionary = {
	BasicEnemy.Archetype.NORMAL: {"archetype": 0, "max_health": 24, "armor": 0,
		"move_speed": 52.0, "attack_damage": 12, "attack_interval": 1.0, "remains_nutrition": 4},
	BasicEnemy.Archetype.SWARM: {"archetype": 1, "max_health": 12, "armor": 0,
		"move_speed": 66.0, "attack_damage": 6, "attack_interval": 1.0, "remains_nutrition": 4},
	BasicEnemy.Archetype.ARMORED: {"archetype": 2, "max_health": 72, "armor": 4,
		"move_speed": 26.0, "attack_damage": 15, "attack_interval": 1.0, "remains_nutrition": 4},
}

class CombatFixture:
	extends RefCounted
	var world: Node2D
	var enemies: Node2D
	var projectiles: Node2D
	var remains: Node2D
	var core: MotherCore
	var tracker: CombatTargetingSystem
	var organ: AttackOrgan
	var weapon: SporeWeapon
	var organs: Array[AttackOrgan] = []
	var initial_stock: int = 0
	var initial_core: int = 0
	var spent: int = 0
	var projectile_count: int = 0
	var round_started_tick: int = 0
	var round_health: Dictionary[int, int] = {}
	var round_positions: Dictionary[int, Vector2] = {}
	var receipts: Array[Dictionary] = []
	var hits: Array[Dictionary] = []
	var projectile_refs: Dictionary[int, WeakRef] = {}
	var projectile_exits: Dictionary[int, int] = {}
	var death_counts: Dictionary[int, int] = {}
	var corpses: Array[Dictionary] = []
	var corpse_refs: Dictionary[int, WeakRef] = {}

class RecoveryEvidence:
	extends RefCounted
	var recycling: RecyclingSystem
	var digestive: DigestiveOrgan
	var returns: NutritionReturnSystem
	var field: FungalField
	var recovery_packets: Array[Dictionary] = []
	var recovery_arrivals: Array[Dictionary] = []
	var recovery_terminal_ids: Dictionary[int, bool] = {}
	var digestion_tasks: Dictionary[String, Dictionary] = {}
	var products: Array[Dictionary] = []
	var completed_tasks: Dictionary[String, bool] = {}
	var return_packet_refs: Dictionary[String, WeakRef] = {}
	var return_arrivals: Array[Dictionary] = []
	var return_terminal_ids: Dictionary[int, bool] = {}
	var core_receipts: Array[Dictionary] = []
	var received_ids: Dictionary[String, bool] = {}
	var conservation_samples: Array[Dictionary] = []

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []
var _seen_shot_ids: Dictionary[String, bool] = {}
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_armored_matchup("normal_vs_armored", NORMAL_PROFILE, 9, 8, FINITE_NINE_STOCK)
	await _test_armored_matchup("piercing_vs_armored", PIERCING_PROFILE, 3, 24, 6)
	await _test_scatter_vs_three_swarm()
	await _test_mixed_archetypes_real_recovery()
	_check(root.get_child_count() == _initial_root_children, "All matchup fixtures leave the tree")
	print("ENEMY_WEAPON_MATCHUP_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _physics_seconds(ticks: int) -> float:
	return float(ticks) / float(Engine.physics_ticks_per_second)


func _wait_until(condition: Callable, seconds: float, description: String) -> bool:
	var limit: int = ceili(seconds * float(Engine.physics_ticks_per_second)) + 2
	for tick: int in range(limit):
		if condition.call():
			break
		await physics_frame
	var completed: bool = condition.call()
	_check(completed, description)
	return completed


func _container(parent: Node, node_name: String) -> Node2D:
	var node := Node2D.new()
	node.name = node_name
	parent.add_child(node)
	return node


func _new_combat_fixture(label: String, profile: WeaponProfile, finite_stock: int) -> CombatFixture:
	var fixture := CombatFixture.new()
	fixture.world = Node2D.new()
	fixture.world.name = label + "FiniteStockFixture"
	fixture.enemies = _container(fixture.world, "Enemies")
	fixture.projectiles = _container(fixture.world, "Projectiles")
	fixture.remains = _container(fixture.world, "Remains")
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = 0
	fixture.core.position = Vector2(0, 300)
	fixture.world.add_child(fixture.core)
	fixture.tracker = CombatTargetingSystem.new()
	fixture.world.add_child(fixture.tracker)
	var remains_spawner: RemainsSpawner = REMAINS_SPAWNER_SCENE.instantiate() as RemainsSpawner
	remains_spawner.enemy_container = fixture.enemies
	remains_spawner.remains_container = fixture.remains
	fixture.world.add_child(remains_spawner)
	var host: Node2D = _container(fixture.world, "IsolatedWeaponHost")
	fixture.organ = ORGAN_SCENE.instantiate() as AttackOrgan
	# 仅九点夹具越过常规六点容量；有限初始库存只在 ready 前写入这一次。
	fixture.organ.capacity = maxi(6, finite_stock)
	fixture.organ.initial_nutrition = finite_stock
	host.add_child(fixture.organ)
	fixture.organs.append(fixture.organ)
	fixture.weapon = WEAPON_SCENE.instantiate() as SporeWeapon
	fixture.weapon.inventory_owner = fixture.organ
	fixture.weapon.enemy_container = fixture.enemies
	fixture.weapon.projectile_container = fixture.projectiles
	fixture.weapon.targeting_system = fixture.tracker
	fixture.weapon.targeting_required = true
	fixture.weapon.position = Vector2(0, -28)
	(fixture.weapon.get_node("FireTimer") as Timer).autostart = false
	_check(fixture.weapon.configure_profile(profile), label + " configures the actual preset for isolation")
	host.add_child(fixture.weapon)
	root.add_child(fixture.world)
	current_scene = fixture.world
	_bind_combat(fixture)
	_check(fixture.organ.nutrition == finite_stock, label + " starts with its declared finite inventory")
	return fixture


func _bind_combat(fixture: CombatFixture) -> void:
	(fixture.weapon.get_node("FireTimer") as Timer).stop()
	fixture.initial_core = fixture.core.nutrition
	for organ: AttackOrgan in fixture.organs:
		fixture.initial_stock += organ.nutrition
	fixture.weapon.volley_committed.connect(_capture_volley.bind(fixture))
	_check(fixture.tracker.is_accepting(), "Real targeting tracker accepts the isolated weapon")


func _spawn_enemy(fixture: CombatFixture, scene: PackedScene, archetype: int,
		position: Vector2) -> BasicEnemy:
	var enemy: BasicEnemy = scene.instantiate() as BasicEnemy
	var snapshot: Dictionary = enemy.get_archetype_snapshot()
	var expected: Dictionary = ENEMY_STATS[archetype]
	for key: String in expected:
		_check(snapshot.get(key) == expected[key], "Actual enemy scene preserves frozen " + key)
	_check(enemy.get_archetype() == archetype, "Actual scene reports the frozen archetype")
	enemy.mother_core = fixture.core
	fixture.enemies.add_child(enemy)
	enemy.global_position = position
	# 保留场景生命、护甲、速度和攻击参数；只停止移动处理与接触计时器。
	enemy.set_physics_process(false)
	(enemy.get_node("AttackTimer") as Timer).stop()
	enemy.died.connect(_capture_death.bind(fixture))
	_check(enemy.health == int(expected["max_health"]), "Scene ready initializes the actual full health")
	return enemy


func _capture_volley(shot_id: String, spent: int, count: int, fixture: CombatFixture) -> void:
	(fixture.weapon.get_node("FireTimer") as Timer).stop()
	_check(not shot_id.is_empty() and not _seen_shot_ids.has(shot_id),
		"Each authoritative volley has one unique nonempty receipt")
	if shot_id.is_empty() or _seen_shot_ids.has(shot_id):
		return
	_seen_shot_ids[shot_id] = true
	fixture.spent += spent
	fixture.projectile_count += count
	var profile: WeaponProfile = fixture.weapon.get_weapon_profile()
	var targets: Array[Dictionary] = []
	var unique_targets: Dictionary[int, bool] = {}
	for child: Node in fixture.projectiles.get_children():
		if not child is SporeProjectile or String(child.get_meta("shot_id", "")) != shot_id:
			continue
		var projectile: SporeProjectile = child as SporeProjectile
		var target: BasicEnemy = projectile.target
		var target_id: int = target.get_instance_id()
		var projectile_id: int = projectile.get_instance_id()
		var record: Dictionary = fixture.tracker.get_commitment(projectile.get_damage_commitment_id())
		_check(not unique_targets.has(target_id), "One real projectile per selected target in a volley")
		unique_targets[target_id] = true
		_check(target.health == int(fixture.round_health.get(target_id, -1)),
			"Volley commitment has not deducted health before the real projectile hits")
		_check(target.global_position == fixture.round_positions.get(target_id, Vector2.INF),
			"Enemy movement is explicitly isolated while the weapon cooldown runs")
		_check(is_equal_approx(projectile.speed, 360.0), "Actual projectile retains its default speed")
		_check(projectile.global_position.distance_to(target.get_aim_position()) > projectile.speed * _physics_seconds(2),
			"The unchanged-health receipt is observed before a positive-duration real flight")
		_check(fixture.tracker.is_commitment_committed(projectile.get_damage_commitment_id())
			and int(record.get("owner_id", 0)) == fixture.weapon.get_instance_id()
			and int(record.get("projectile_id", 0)) == projectile_id,
			"The actual projectile owns its committed damage record")
		targets.append({"target_id": target_id, "archetype": target.get_archetype(),
			"health_before_hit": target.health, "projectile_id": projectile_id,
			"expected_damage": int(record.get("expected_damage", 0))})
		fixture.projectile_refs[projectile_id] = weakref(projectile)
		projectile.tree_exiting.connect(_capture_projectile_exit.bind(weakref(projectile),
			fixture, target_id, target.health, shot_id, int(profile.damage), int(profile.damage_type)))
	_check(targets.size() == count and spent == profile.nutrition_cost,
		"Receipt describes the actual spawned projectiles and actual preset cost")
	var elapsed: float = _physics_seconds(Engine.get_physics_frames() - fixture.round_started_tick)
	_check(elapsed + _physics_seconds(2) >= profile.fire_interval,
		"Actual FireTimer observes the unmodified preset cooldown")
	fixture.receipts.append({"shot_id": shot_id, "nutrition_spent": spent,
		"projectile_count": count, "raw_damage": profile.damage,
		"damage_type": int(profile.damage_type), "fire_interval": profile.fire_interval,
		"cooldown_physics_seconds": elapsed, "targets": targets})
	_check(fixture.weapon.get_shot_statistics() == {"rounds": fixture.receipts.size(),
		"projectiles": fixture.projectile_count, "nutrition_spent": fixture.spent,
		"last_shot_id": shot_id}, "Weapon statistics match the unique authoritative receipts")
	_combat_conservation(fixture, "Committed volley")


func _capture_projectile_exit(reference: WeakRef, fixture: CombatFixture, target_id: int,
		health_before: int, shot_id: String, raw_damage: int, damage_type: int) -> void:
	var raw_projectile: Variant = reference.get_ref()
	if not is_instance_valid(raw_projectile):
		return
	var projectile: SporeProjectile = raw_projectile as SporeProjectile
	var projectile_id: int = projectile.get_instance_id()
	fixture.projectile_exits[projectile_id] = int(fixture.projectile_exits.get(projectile_id, 0)) + 1
	_check(fixture.projectile_exits[projectile_id] == 1, "Each real projectile exits once")
	var raw_target: Variant = projectile.target
	_check(is_instance_valid(raw_target), "The real hit still has its original target at projectile exit")
	if not is_instance_valid(raw_target):
		return
	var target: BasicEnemy = raw_target as BasicEnemy
	var health_after: int = target.health
	# 只在实际飞行已经终结之后重入同一个弹丸；不能制造首次命中。
	projectile._physics_process(_physics_seconds(1))
	projectile._physics_process(_physics_seconds(1))
	_check(target.health == health_after, "Repeated completed-projectile processing cannot hit twice")
	fixture.hits.append({"shot_id": shot_id, "projectile_id": projectile_id,
		"target_id": target_id, "archetype": target.get_archetype(),
		"raw_damage": raw_damage, "damage_type": damage_type,
		"health_before": health_before, "health_after": health_after,
		"health_lost": health_before - health_after})


func _capture_death(enemy: BasicEnemy, fixture: CombatFixture) -> void:
	var enemy_id: int = enemy.get_instance_id()
	fixture.death_counts[enemy_id] = int(fixture.death_counts.get(enemy_id, 0)) + 1
	_check(fixture.death_counts[enemy_id] == 1, "A real lethal hit emits exactly one death notification")
	if fixture.death_counts[enemy_id] != 1:
		return
	var corpse: EnemyRemains = null
	var matches: int = 0
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and child.global_position.distance_to(enemy.global_position) < 0.01:
			corpse = child as EnemyRemains
			matches += 1
	_check(matches == 1 and corpse != null, "Real RemainsSpawner creates one corpse at the death position")
	if corpse != null:
		_check(corpse.nutrition_value == 4, "Every real archetype corpse contains four nutrition")
		var corpse_id: int = corpse.get_instance_id()
		fixture.corpse_refs[corpse_id] = weakref(corpse)
		fixture.corpses.append({"enemy_id": enemy_id, "archetype": enemy.get_archetype(),
			"corpse_id": corpse_id, "nutrition": corpse.nutrition_value,
			"position": [corpse.global_position.x, corpse.global_position.y]})
	var corpse_count: int = fixture.remains.get_child_count()
	for reference: WeakRef in fixture.projectile_refs.values():
		var raw_projectile: Variant = reference.get_ref()
		if is_instance_valid(raw_projectile) and raw_projectile.target == enemy:
			raw_projectile._physics_process(_physics_seconds(1))
			raw_projectile._physics_process(_physics_seconds(1))
	# 已由真实弹丸击杀后才探测重复致死入口，绝不用于生成第一份尸体。
	var rejected_first: int = enemy.apply_damage(NORMAL_PROFILE.create_damage_request())
	var rejected_second: int = enemy.apply_damage(PIERCING_PROFILE.create_damage_request())
	_check(rejected_first == 0 and rejected_second == 0 and enemy.health == 0,
		"An already dead enemy rejects repeated damage without a second lethal notification")
	_check(fixture.death_counts[enemy_id] == 1 and fixture.remains.get_child_count() == corpse_count,
		"Repeated projectile and lethal probes cannot produce a second corpse")


func _combat_conservation(fixture: CombatFixture, description: String) -> void:
	var balance: int = fixture.core.nutrition + fixture.spent
	for organ: AttackOrgan in fixture.organs:
		balance += organ.nutrition + organ.incoming_nutrition
	_check(balance == fixture.initial_core + fixture.initial_stock,
		description + " conserves finite initial stock and receipt-measured ammunition spending")


func _fire_one_round(fixture: CombatFixture) -> bool:
	fixture.round_health.clear()
	fixture.round_positions.clear()
	for child: Node in fixture.enemies.get_children():
		if child is BasicEnemy and child.is_alive():
			fixture.round_health[child.get_instance_id()] = child.health
			fixture.round_positions[child.get_instance_id()] = child.global_position
	var before_receipts: int = fixture.receipts.size()
	var before_hits: int = fixture.hits.size()
	var profile: WeaponProfile = fixture.weapon.get_weapon_profile()
	_check(fixture.organ.nutrition >= profile.nutrition_cost, "Finite fixture can pay its next actual volley")
	fixture.round_started_tick = Engine.get_physics_frames()
	(fixture.weapon.get_node("FireTimer") as Timer).start()
	var committed: bool = await _wait_until(func() -> bool: return fixture.receipts.size() > before_receipts,
		profile.fire_interval + 0.6, "Real FireTimer commits the requested round")
	(fixture.weapon.get_node("FireTimer") as Timer).stop()
	if not committed:
		return false
	_check(fixture.receipts.size() == before_receipts + 1, "One timer run creates exactly one paid round")
	var receipt: Dictionary = fixture.receipts.back()
	var completed: bool = await _wait_until(func() -> bool: return fixture.projectiles.get_child_count() == 0,
		1.2, "Default-speed real projectiles finish their flight and leave the tree")
	var all_hits_observed: bool = fixture.hits.size() - before_hits == int(receipt["projectile_count"])
	_check(all_hits_observed,
		"Every actual receipt projectile has one observed completed flight")
	_check(int(fixture.tracker.get_snapshot().get("total_count", -1)) == 0,
		"Actual flight completion clears all damage commitments")
	_combat_conservation(fixture, "Actual impacts")
	return completed and all_hits_observed


func _remove_fixture(fixture: CombatFixture) -> void:
	fixture.weapon.set_firing_enabled(false)
	if current_scene == fixture.world:
		current_scene = null
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _test_armored_matchup(label: String, profile: WeaponProfile, expected_rounds: int,
		expected_health_lost: int, finite_stock: int) -> void:
	var fixture: CombatFixture = _new_combat_fixture(label, profile, finite_stock)
	var enemy: BasicEnemy = _spawn_enemy(fixture, ARMORED_ENEMY_SCENE,
		BasicEnemy.Archetype.ARMORED, fixture.organ.global_position + Vector2(80, 0))
	var enemy_id: int = enemy.get_instance_id()
	var health_timeline: Array[int] = [enemy.health]
	for round_index: int in range(expected_rounds):
		var round_completed: bool = await _fire_one_round(fixture)
		if not round_completed:
			break
		var hit: Dictionary = fixture.hits.back()
		_check(int(hit["target_id"]) == enemy_id and int(hit["raw_damage"]) == profile.damage,
			label + " uses the actual preset projectile against the actual armored scene")
		_check(int(hit["health_lost"]) == expected_health_lost,
			label + " observes the required health loss on every real impact")
		health_timeline.append(int(hit["health_after"]))
		_check(int(hit["health_after"]) == 72 - (round_index + 1) * expected_health_lost,
			label + " preserves the full measured health timeline")
		_check(fixture.corpses.size() == (1 if int(hit["health_after"]) == 0 else 0),
			label + " creates a corpse only on the actual final hit")
	_check(fixture.receipts.size() == expected_rounds and fixture.projectile_count == expected_rounds,
		label + " has the required receipt-measured rounds and actual projectile count")
	_check(health_timeline.back() == 0 and int(fixture.death_counts.get(enemy_id, 0)) == 1,
		label + " kills the real armored enemy exactly once")
	_check(fixture.organ.nutrition == 0 and fixture.spent == finite_stock,
		label + " consumes exactly the finite initial inventory without refill")
	_check(fixture.corpses.size() == 1 and fixture.remains.get_child_count() == 1,
		label + " leaves exactly one real four-nutrition corpse")
	evidence.append({"case": label, "fixture": String(fixture.world.name),
		"boundary": "isolated configure_profile; real FireTimer and flight; movement disabled; no supply",
		"initial_capacity": fixture.organ.capacity, "initial_stock_before_ready": finite_stock,
		"health_timeline": health_timeline, "rounds": fixture.receipts.size(),
		"projectiles": fixture.projectile_count, "nutrition_spent_from_receipts": fixture.spent,
		"receipts": fixture.receipts.duplicate(true), "actual_hits": fixture.hits.duplicate(true),
		"corpses": fixture.corpses.duplicate(true)})
	await _remove_fixture(fixture)


func _test_scatter_vs_three_swarm() -> void:
	var fixture: CombatFixture = _new_combat_fixture("scatter_vs_three_swarm", SCATTER_PROFILE, 2)
	var enemy_ids: Array[int] = []
	var angles: Array[float] = [-10.0, 0.0, 10.0]
	for angle: float in angles:
		var position: Vector2 = fixture.organ.global_position + Vector2.from_angle(deg_to_rad(angle)) * 80.0
		var enemy: BasicEnemy = _spawn_enemy(fixture, SWARM_ENEMY_SCENE, BasicEnemy.Archetype.SWARM, position)
		enemy_ids.append(enemy.get_instance_id())
		_check(absf(angle) <= SCATTER_PROFILE.spread_angle_degrees * 0.5,
			"Real swarm targets are inside the same sixty-degree sector")
	var health_by_round: Array[Array] = [[12, 12, 12]]
	for round_index: int in range(2):
		var first_hit: int = fixture.hits.size()
		var round_completed: bool = await _fire_one_round(fixture)
		if not round_completed:
			break
		var receipt: Dictionary = fixture.receipts.back()
		_check(int(receipt["projectile_count"]) == 3 and int(receipt["nutrition_spent"]) == 1,
			"Each real scatter receipt charges one nutrition for three projectiles")
		var measured_health: Dictionary[int, int] = {}
		for hit_index: int in range(first_hit, fixture.hits.size()):
			var hit: Dictionary = fixture.hits[hit_index]
			var target_id: int = int(hit["target_id"])
			_check(enemy_ids.has(target_id) and not measured_health.has(target_id),
				"Each scatter round actually hits all three distinct real swarm targets once")
			_check(int(hit["raw_damage"]) == 6 and int(hit["health_lost"]) == 6,
				"Each actual scatter projectile removes six health from the twelve-health swarm scene")
			measured_health[target_id] = int(hit["health_after"])
		var row: Array[int] = []
		for enemy_id: int in enemy_ids:
			row.append(int(measured_health.get(enemy_id, -1)))
			_check(row.back() == 12 - (round_index + 1) * 6,
				"Actual scatter health is six after round one and zero after round two")
		health_by_round.append(row)
		_check(fixture.corpses.size() == (0 if round_index == 0 else 3),
			"Scatter deaths and corpse creation follow the actual second impacts")
	_check(fixture.receipts.size() == 2 and fixture.projectile_count == 6 and fixture.spent == 2,
		"Unique scatter receipts measure two rounds, six projectiles and only two nutrition spent")
	_check(fixture.organ.nutrition == 0 and fixture.organ.incoming_nutrition == 0,
		"Actual scatter inventory loses exactly the two declared nutrition without supply")
	_check(fixture.death_counts.size() == 3 and fixture.remains.get_child_count() == 3,
		"Three actual swarm deaths leave exactly three four-nutrition corpses")
	evidence.append({"case": "scatter_vs_three_swarm", "angles_degrees": angles,
		"boundary": "three real swarm scenes; isolated scatter preset; default cooldown and projectile speed; no refill",
		"initial_stock_before_ready": 2, "health_by_round": health_by_round,
		"rounds": fixture.receipts.size(), "projectiles": fixture.projectile_count,
		"nutrition_spent_from_receipts": fixture.spent, "receipts": fixture.receipts.duplicate(true),
		"actual_hits": fixture.hits.duplicate(true), "corpses": fixture.corpses.duplicate(true)})
	await _remove_fixture(fixture)


func _new_mixed_level_fixture() -> CombatFixture:
	var fixture := CombatFixture.new()
	fixture.world = LEVEL_SCENE.instantiate() as Node2D
	fixture.world.name = "MixedArchetypeFiniteNineStockLevelFixture"
	fixture.world.set("expansion_demo_enabled", false)
	fixture.world.set("carcass_demo_enabled", false)
	fixture.enemies = fixture.world.get_node("World/Enemies") as Node2D
	fixture.projectiles = fixture.world.get_node("World/Projectiles") as Node2D
	fixture.remains = fixture.world.get_node("World/Remains") as Node2D
	fixture.core = fixture.world.get_node("World/Colony/MotherCore") as MotherCore
	fixture.tracker = fixture.world.get_node("Systems/CombatTargetingSystem") as CombatTargetingSystem
	fixture.organ = fixture.world.get_node("World/Colony/Nodes/HyphaNode/AttackOrgan") as AttackOrgan
	fixture.organ.capacity = FINITE_NINE_STOCK
	fixture.organ.initial_nutrition = FINITE_NINE_STOCK
	fixture.organs.append(fixture.organ)
	fixture.organs.append(fixture.world.get_node("World/Colony/Nodes/RightNode/AttackOrgan") as AttackOrgan)
	fixture.weapon = fixture.world.get_node("World/Colony/Nodes/HyphaNode/SporeWeapon") as SporeWeapon
	(fixture.weapon.get_node("FireTimer") as Timer).autostart = false
	_check(fixture.weapon.configure_profile(NORMAL_PROFILE), "Mixed isolated level configures the normal preset")
	var other_weapon: SporeWeapon = fixture.world.get_node("World/Colony/Nodes/RightNode/SporeWeapon") as SporeWeapon
	other_weapon.set_firing_enabled(false)
	(other_weapon.get_node("FireTimer") as Timer).autostart = false
	var spawner: EnemySpawner = fixture.world.get_node("Systems/EnemySpawner") as EnemySpawner
	spawner.auto_start = false
	var supply: SupplySystem = fixture.world.get_node("Systems/SupplySystem") as SupplySystem
	supply.process_mode = Node.PROCESS_MODE_DISABLED
	(supply.get_node("DispatchTimer") as Timer).autostart = false
	var recycling: RecyclingSystem = fixture.world.get_node("Systems/RecyclingSystem") as RecyclingSystem
	(recycling.get_node("DispatchTimer") as Timer).autostart = false
	var returns: NutritionReturnSystem = fixture.world.get_node("Systems/NutritionReturnSystem") as NutritionReturnSystem
	returns.auto_return = false
	root.add_child(fixture.world)
	current_scene = fixture.world
	spawner.stop_spawning()
	(supply.get_node("DispatchTimer") as Timer).stop()
	(recycling.get_node("DispatchTimer") as Timer).stop()
	_bind_combat(fixture)
	_check(fixture.enemies.get_child_count() == 0 and fixture.remains.get_child_count() == 0,
		"Formal fixture removes the expansion sample and disables original enemy and carcass batches")
	_check(fixture.organ.nutrition == FINITE_NINE_STOCK and supply.get_in_transit_count() == 0,
		"Formal fixture has declared finite nine-stock ammunition and no combat supply")
	return fixture


func _test_mixed_archetypes_real_recovery() -> void:
	var fixture: CombatFixture = _new_mixed_level_fixture()
	var flow := RecoveryEvidence.new()
	flow.recycling = fixture.world.get_node("Systems/RecyclingSystem") as RecyclingSystem
	flow.digestive = fixture.world.get_node("World/Colony/Nodes/RearNode/DigestiveOrgan") as DigestiveOrgan
	flow.returns = fixture.world.get_node("Systems/NutritionReturnSystem") as NutritionReturnSystem
	flow.field = fixture.world.get_node("World/FungalField") as FungalField
	flow.digestive.digestion_started.connect(_capture_digestion_started.bind(flow))
	flow.digestive.product_created.connect(_capture_product_created.bind(fixture, flow))
	flow.digestive.digestion_completed.connect(_capture_digestion_completed.bind(flow))
	fixture.core.digestion_product_arrived.connect(_capture_core_receipt.bind(fixture, flow))
	fixture.world.get_node("World/ReturnPackets").child_entered_tree.connect(_capture_return_packet.bind(fixture, flow))
	var origin: Vector2 = fixture.organ.global_position
	# 三类同时在场；下列位置让普通、群袭、重甲依次更远离母核，使用真实选敌排序。
	var normal: BasicEnemy = _spawn_enemy(fixture, NORMAL_ENEMY_SCENE,
		BasicEnemy.Archetype.NORMAL, origin + Vector2(80, 20))
	var swarm: BasicEnemy = _spawn_enemy(fixture, SWARM_ENEMY_SCENE,
		BasicEnemy.Archetype.SWARM, origin + Vector2(70, 10))
	var armored: BasicEnemy = _spawn_enemy(fixture, ARMORED_ENEMY_SCENE,
		BasicEnemy.Archetype.ARMORED, origin + Vector2(60, 0))
	var normal_id: int = normal.get_instance_id()
	var swarm_id: int = swarm.get_instance_id()
	var armored_id: int = armored.get_instance_id()
	_check(fixture.enemies.get_child_count() == 3, "The formal fixture starts with all three real archetypes together")
	var collecting_host: Node2D = fixture.organ.get_parent() as Node2D
	await _wait_until(func() -> bool: return flow.field.get_effective_radius(collecting_host) >= 110.0,
		1.5, "Formal field matures through its actual default expansion time")
	for expected_id: int in [normal_id, normal_id, swarm_id]:
		var round_completed: bool = await _fire_one_round(fixture)
		if not round_completed:
			break
		_check(int(fixture.hits.back()["target_id"]) == expected_id,
			"Actual normal weapon kills the normal and swarm scenes using live target priority")
	_check(fixture.weapon.configure_profile(PIERCING_PROFILE),
		"Mixed isolated fixture explicitly configures piercing after the first two real deaths")
	for round_index: int in range(3):
		var round_completed: bool = await _fire_one_round(fixture)
		if not round_completed:
			break
		_check(int(fixture.hits.back()["target_id"]) == armored_id
			and int(fixture.hits.back()["health_lost"]) == 24,
			"Mixed fixture kills the actual armored scene with three real piercing impacts")
	fixture.weapon.set_firing_enabled(false)
	_check(fixture.death_counts.size() == 3 and fixture.corpses.size() == 3,
		"Actual mixed combat creates one real corpse for each of the three archetypes")
	_check(fixture.spent == 9 and fixture.receipts.size() == 6 and fixture.projectile_count == 6
		and fixture.organ.nutrition == 0, "Mixed combat receipts account for all nine finite ammunition nutrition")
	_check(fixture.core.nutrition == fixture.initial_core and fixture.core.get_received_product_count() == 0,
		"Real enemy death and corpse generation cannot credit early core income")
	_check(is_equal_approx(flow.digestive.digest_timer.wait_time, 1.5)
		and is_equal_approx(flow.returns.packet_speed, 80.0)
		and is_equal_approx(flow.returns.dispatch_interval, 0.35),
		"Formal recovery keeps its default digestion and nutrient-return timing and speed")
	_full_conservation(fixture, flow, "all_actual_deaths", true)
	for corpse: Dictionary in fixture.corpses:
		_dispatch_real_corpse(fixture, flow, corpse)
	_check(flow.recycling.get_in_transit_count() == 3 and flow.digestive.incoming_remains == 3,
		"Three real corpse shipments own three digestive reservations")
	_check(not flow.recycling.try_dispatch(), "Already claimed real corpses cannot dispatch twice")
	_check(fixture.core.nutrition == fixture.initial_core and flow.digestive.get_queued_count() == 0,
		"Actual dispatch and reservation cannot manufacture arrival or digestion income")
	_full_conservation(fixture, flow, "all_actual_dispatches", true)
	# 仅打开正式回流调度；运输包、消化 Timer 与母核的实际收件自行推进。
	flow.returns.auto_return = true
	var limit: int = ceili(20.0 * float(Engine.physics_ticks_per_second))
	var recorded_progress := Vector3i.ZERO
	for tick: int in range(limit):
		if _recovery_finished(fixture, flow):
			break
		await physics_frame
		if tick % 6 == 0:
			_full_conservation(fixture, flow, "default_physics_recovery")
		var progress := Vector3i(flow.recycling.delivered_count, flow.digestive.digested_count,
			fixture.core.get_received_product_count())
		if progress != recorded_progress:
			_full_conservation(fixture, flow, "actual_deliveries_%d_digestions_%d_core_receipts_%d" %
				[progress.x, progress.y, progress.z], true)
			recorded_progress = progress
	await process_frame
	await process_frame
	_check(_recovery_finished(fixture, flow), "All actual mixed corpses finish transport, digestion and core return")
	_check(flow.recovery_arrivals.size() == 3 and flow.recycling.delivered_count == 3
		and flow.recycling.interrupted_count == 0, "All three actual corpse transports settle once without interruption")
	_check(flow.products.size() == 3 and flow.completed_tasks.size() == 3
		and flow.digestive.digested_count == 3 and flow.digestive.total_nutrition_produced == 12,
		"Actual default digestion creates exactly three unique four-nutrition products")
	_check(flow.core_receipts.size() == 3 and flow.return_arrivals.size() == 3
		and fixture.core.get_received_product_count() == 3 and flow.returns.delivered_count == 3
		and flow.returns.delivered_nutrition == 12 and flow.returns.interrupted_count == 0,
		"Actual nutrient returns deliver all three unique products to the real mother core exactly once")
	_check(fixture.core.nutrition == fixture.initial_core + 12,
		"Real core balance increases by exactly the three four-nutrition corpses")
	for reference: WeakRef in fixture.corpse_refs.values():
		_check(reference.get_ref() == null, "Every actually delivered original corpse leaves the ground container")
	_full_conservation(fixture, flow, "all_actual_core_receipts", true)
	var final_balance: int = fixture.core.nutrition
	var final_delivered: int = flow.returns.delivered_count
	# 超过原消化周期继续运行默认调度，验证不会有重复产物或第二次收入。
	for tick: int in range(ceili(1.8 * float(Engine.physics_ticks_per_second))):
		await physics_frame
	_check(fixture.core.nutrition == final_balance and flow.returns.delivered_count == final_delivered
		and flow.digestive.digested_count == 3 and flow.core_receipts.size() == 3,
		"Further default timers cannot settle an already recovered corpse or product again")
	_full_conservation(fixture, flow, "settled_after_extra_default_timers", true)
	var other_weapon: SporeWeapon = fixture.world.get_node("World/Colony/Nodes/RightNode/SporeWeapon") as SporeWeapon
	_check(int(other_weapon.get_shot_statistics().get("rounds", -1)) == 0
		and fixture.organs[1].nutrition == fixture.organs[1].initial_nutrition,
		"Other formal weapons and inventories remain isolated for the whole real resource cycle")
	evidence.append({"case": "mixed_archetypes_real_recovery", "scene": "res://scenes/levels/level_01.tscn",
		"boundary": "isolated presets; ready-before finite nine-stock left organ; no supply, original enemy batch, sample remains or large carcass; right weapon disabled; only movement processing and contact timers suppressed",
		"resource_ownership": "claimed corpses counted once on the ground; return shipments counted in the digestive output ledger until actual core receipt",
		"initial_core_nutrition": fixture.initial_core, "initial_organ_nutrition": fixture.initial_stock,
		"initial_left_capacity_and_stock": FINITE_NINE_STOCK, "nutrition_spent_from_receipts": fixture.spent,
		"receipts": fixture.receipts.duplicate(true), "actual_hits": fixture.hits.duplicate(true),
		"corpses": fixture.corpses.duplicate(true), "recovery_packets": flow.recovery_packets.duplicate(true),
		"actual_recovery_arrivals": flow.recovery_arrivals.duplicate(true),
		"actual_products": flow.products.duplicate(true), "actual_return_arrivals": flow.return_arrivals.duplicate(true),
		"actual_core_receipts": flow.core_receipts.duplicate(true), "core_final_nutrition": fixture.core.nutrition,
		"conservation": flow.conservation_samples.duplicate(true)})
	await _remove_fixture(fixture)


func _dispatch_real_corpse(fixture: CombatFixture, flow: RecoveryEvidence, record: Dictionary) -> void:
	var corpse_id: int = int(record["corpse_id"])
	var raw_corpse: Variant = fixture.corpse_refs[corpse_id].get_ref()
	_check(is_instance_valid(raw_corpse), "Actual dead archetype corpse is present before collection")
	if not is_instance_valid(raw_corpse):
		return
	var corpse: EnemyRemains = raw_corpse as EnemyRemains
	_check(corpse.is_available() and flow.field.is_covered(corpse.global_position),
		"Real corpse is available inside the actual mature field")
	var packets: Node2D = fixture.world.get_node("World/RecoveryPackets") as Node2D
	var previous_ids: Array[int] = []
	for child: Node in packets.get_children():
		previous_ids.append(child.get_instance_id())
	_check(flow.recycling.try_dispatch(), "Real RecyclingSystem accepts an actual archetype corpse")
	_check(not corpse.is_available() and not corpse.visible, "The real shipment uniquely claims and hides its corpse")
	var new_packets: int = 0
	for child: Node in packets.get_children():
		if previous_ids.has(child.get_instance_id()) or not child is RemainsPacket:
			continue
		var packet: RemainsPacket = child as RemainsPacket
		new_packets += 1
		_check(is_equal_approx(packet.speed, 140.0), "Actual corpse packet keeps its default transport speed")
		var snapshot: Dictionary = packet.get_transport_snapshot()
		_check(bool(snapshot.get("started", false)) and not bool(snapshot.get("terminal", true))
			and bool(snapshot.get("traffic_enabled", false)) and int(snapshot.get("segment_count", 0)) > 0,
			"Actual corpse shipment starts a real positive-length shared-traffic route")
		packet.arrived.connect(_capture_recovery_arrival.bind(fixture, flow, corpse_id))
		flow.recovery_packets.append({"packet_id": packet.get_instance_id(), "corpse_id": corpse_id,
			"archetype": int(record["archetype"]), "nutrition": int(record["nutrition"]),
			"speed": packet.speed, "segment_count": int(snapshot.get("segment_count", 0))})
	_check(new_packets == 1, "One actually claimed corpse creates one real transport packet")


func _capture_recovery_arrival(packet: RemainsPacket, fixture: CombatFixture,
		flow: RecoveryEvidence, corpse_id: int) -> void:
	var packet_id: int = packet.get_instance_id()
	_check(not flow.recovery_terminal_ids.has(packet_id), "One actual corpse packet has one arrival terminal event")
	flow.recovery_terminal_ids[packet_id] = true
	var destination: Node2D = flow.digestive.get_parent() as Node2D
	var snapshot: Dictionary = packet.get_transport_snapshot()
	_check(packet.has_arrived_at(destination) and int(snapshot.get("completed_segments", 0)) > 0,
		"Corpse arrival evidence is an actually completed route to the digestive host")
	flow.recovery_arrivals.append({"packet_id": packet_id, "corpse_id": corpse_id,
		"completed_segments": int(snapshot.get("completed_segments", 0)),
		"destination_id": destination.get_instance_id(), "state": String(snapshot.get("state", ""))})
	var delivered: int = flow.recycling.delivered_count
	var incoming: int = flow.digestive.incoming_remains
	packet._physics_process(_physics_seconds(1))
	packet.cancel_transport()
	packet.cancel_transport()
	_check(flow.recycling.delivered_count == delivered and flow.digestive.incoming_remains == incoming
		and fixture.core.nutrition == fixture.initial_core + _received_nutrition(flow),
		"Reprocessing or cancelling a really arrived corpse cannot settle it twice or create income")


func _capture_digestion_started(task_id: String, chamber_id: int, input_id: String,
		nutrition: int, flow: RecoveryEvidence) -> void:
	_check(not task_id.is_empty() and not flow.digestion_tasks.has(task_id) and nutrition == 4,
		"Real digestion starts one uniquely identified four-nutrition task")
	var snapshot: Dictionary = flow.digestive.get_digestion_snapshot()
	var chambers: Array = snapshot.get("chambers", [])
	var chamber: Dictionary = chambers[chamber_id]
	var duration: float = float(chamber.get("duration", 0.0))
	_check(is_equal_approx(duration, 1.5), "Actual digestion task uses the unchanged 1.5-second duration")
	flow.digestion_tasks[task_id] = {"task_id": task_id, "input_id": input_id,
		"nutrition": nutrition, "chamber_id": chamber_id, "duration": duration,
		"started_physics_tick": Engine.get_physics_frames()}


func _capture_product_created(product_id: String, nutrition: int,
		fixture: CombatFixture, flow: RecoveryEvidence) -> void:
	var matches: int = 0
	for product: Dictionary in flow.digestive.get_output_products():
		if String(product.get("product_id", "")) != product_id:
			continue
		matches += 1
		_check(int(product.get("nutrition", 0)) == 4 and nutrition == 4,
			"Actual digestive output preserves the real corpse's four nutrition")
		flow.products.append({"product_id": product_id, "nutrition": nutrition,
			"task_id": String(product.get("task_id", "")),
			"input_id": String(product.get("input_id", "")),
			"chamber_id": int(product.get("chamber_id", -1))})
	_check(matches == 1 and not fixture.core.has_received_product(product_id),
		"Actual product creation stores one product without early mother-core receipt")
	_check(fixture.core.nutrition == fixture.initial_core + _received_nutrition(flow),
		"Actual digestion changes the output ledger, while core income matches only real receipts")


func _capture_digestion_completed(task_id: String, _chamber_id: int, product_id: String,
		nutrition: int, flow: RecoveryEvidence) -> void:
	_check(flow.digestion_tasks.has(task_id) and not flow.completed_tasks.has(task_id) and nutrition == 4,
		"Each real digestion task completes exactly once with four nutrition")
	if not flow.digestion_tasks.has(task_id):
		return
	flow.completed_tasks[task_id] = true
	var start: Dictionary = flow.digestion_tasks[task_id]
	var elapsed: float = _physics_seconds(Engine.get_physics_frames() - int(start["started_physics_tick"]))
	_check(elapsed + _physics_seconds(2) >= float(start["duration"]),
		"Actual digestion completion waits for the full default physical timer")
	for product: Dictionary in flow.products:
		if String(product["product_id"]) == product_id:
			product["digestion_physics_seconds"] = elapsed


func _capture_return_packet(node: Node, fixture: CombatFixture, flow: RecoveryEvidence) -> void:
	if not node is NutrientPacket:
		return
	var packet: NutrientPacket = node as NutrientPacket
	var product_id: String = String(packet.get_meta("return_product_id", ""))
	_check(not product_id.is_empty() and not flow.return_packet_refs.has(product_id),
		"One real return packet is attached to each unique digestive product")
	flow.return_packet_refs[product_id] = weakref(packet)
	_check(is_equal_approx(packet.speed, 80.0), "Real return packet uses the unchanged eighty-pixel speed")
	packet.arrived.connect(_capture_return_arrival.bind(fixture, flow, product_id))


func _capture_core_receipt(product_id: String, nutrition: int,
		fixture: CombatFixture, flow: RecoveryEvidence) -> void:
	_check(not flow.received_ids.has(product_id) and nutrition == 4,
		"Mother core receives each actual four-nutrition product only once")
	flow.received_ids[product_id] = true
	var raw_packet: Variant = flow.return_packet_refs[product_id].get_ref() \
		if flow.return_packet_refs.has(product_id) else null
	var actual_arrival: bool = is_instance_valid(raw_packet) and raw_packet.has_arrived_at(fixture.core)
	_check(actual_arrival and fixture.core.has_received_product(product_id),
		"Core receipt is backed by a real completed nutrient route and the core's own product ledger")
	flow.core_receipts.append({"product_id": product_id, "nutrition": nutrition,
		"packet_id": raw_packet.get_instance_id() if is_instance_valid(raw_packet) else 0,
		"actual_packet_arrival": actual_arrival, "core_balance": fixture.core.nutrition})
	_check(fixture.core.nutrition == fixture.initial_core + _received_nutrition(flow),
		"Every real core receipt increases the balance exactly once by four nutrition")


func _capture_return_arrival(packet: NutrientPacket, fixture: CombatFixture,
		flow: RecoveryEvidence, product_id: String) -> void:
	var packet_id: int = packet.get_instance_id()
	_check(not flow.return_terminal_ids.has(packet_id), "Each actual nutrient packet arrives only once")
	flow.return_terminal_ids[packet_id] = true
	var snapshot: Dictionary = packet.get_transport_snapshot()
	_check(packet.has_arrived_at(fixture.core) and int(snapshot.get("completed_segments", 0)) > 0
		and fixture.core.has_received_product(product_id),
		"Actual return arrival completes a positive-length route and settles in the real core")
	flow.return_arrivals.append({"packet_id": packet_id, "product_id": product_id,
		"completed_segments": int(snapshot.get("completed_segments", 0)),
		"state": String(snapshot.get("state", "")), "speed": packet.speed})
	var balance: int = fixture.core.nutrition
	var delivered: int = flow.returns.delivered_count
	packet._physics_process(_physics_seconds(1))
	packet.cancel_transport()
	packet.cancel_transport()
	_check(fixture.core.nutrition == balance and flow.returns.delivered_count == delivered,
		"Completed real nutrient packet reentry and repeated cancellation cannot credit twice")


func _received_nutrition(flow: RecoveryEvidence) -> int:
	var amount: int = 0
	for receipt: Dictionary in flow.core_receipts:
		amount += int(receipt["nutrition"])
	return amount


func _full_conservation(fixture: CombatFixture, flow: RecoveryEvidence,
		label: String, record_sample: bool = false) -> void:
	var corpse_nutrition: int = 0
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and not child.is_queued_for_deletion():
			corpse_nutrition += child.nutrition_value
	var local_nutrition: int = 0
	for organ: AttackOrgan in fixture.organs:
		local_nutrition += organ.nutrition + organ.incoming_nutrition
	var corpse_budget: int = 0
	for corpse: Dictionary in fixture.corpses:
		corpse_budget += int(corpse["nutrition"])
	# 包只是原库存的运输引用；已领取尸体与在途输出分别只在原所有者中计算一次。
	var intake: int = flow.digestive.get_queued_nutrition()
	var output: int = flow.digestive.get_output_nutrition()
	var total: int = fixture.core.nutrition + local_nutrition + fixture.spent + corpse_nutrition + intake + output
	var budget: int = fixture.initial_core + fixture.initial_stock + corpse_budget
	_check(total == budget, label + " conserves finite ammunition, real corpse nutrition and real core income")
	if record_sample:
		flow.conservation_samples.append({"at": label, "core": fixture.core.nutrition,
			"local_inventory": local_nutrition, "ammunition_spent": fixture.spent,
			"ground_or_claimed_corpses": corpse_nutrition, "digestive_intake": intake,
			"digestive_output_including_return_shipments": output, "total": total, "budget": budget})


func _recovery_finished(fixture: CombatFixture, flow: RecoveryEvidence) -> bool:
	return fixture.core.get_received_product_count() == 3 and flow.recycling.get_in_transit_count() == 0 \
		and flow.returns.get_in_transit_count() == 0 and flow.digestive.get_queued_count() == 0 \
		and flow.digestive.incoming_remains == 0 and flow.digestive.get_output_count() == 0 \
		and fixture.remains.get_child_count() == 0 \
		and fixture.world.get_node("World/RecoveryPackets").get_child_count() == 0 \
		and fixture.world.get_node("World/ReturnPackets").get_child_count() == 0
