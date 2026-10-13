extends SceneTree
## 共享伤害承诺的跨器官验收；显式武器配置只用于隔离夹具。
## 正式关卡的新增器官通过真实 C 培育、付款包送达和有效时间成熟，R 走实际输入。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/spore_projectile.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const REMAINS_SPAWNER_SCENE: PackedScene = preload("res://scenes/systems/remains_spawner.tscn")
const PRESET_PATHS: Dictionary = {
	"normal": "res://resources/weapons/normal_spore.tres",
	"armor_piercing": "res://resources/weapons/armor_piercing_spore.tres",
	"scatter": "res://resources/weapons/scatter_spore.tres",
}

class Fixture:
	extends RefCounted
	var world: Node2D
	var enemies: Node2D
	var projectiles: Node2D
	var remains: Node2D
	var core: MotherCore
	var tracker: CombatTargetingSystem
	var organs: Array[AttackOrgan] = []
	var weapons: Array[SporeWeapon] = []
	var initial_stock: int = 0
	var spent: int = 0
	var projectile_total: int = 0
	var deaths: int = 0
	var events: Array[Dictionary] = []
	var primary_ids: Array[int] = []

# 仅给实例化/发射添加同步观察与失败入口；移动、命中及清理仍由真实弹丸执行。
class PreparationProjectile:
	extends SporeProjectile
	static var attempts: int = 0
	static var reject_at: int = 0
	static var creation_hook: Callable = Callable()
	static var launch_hook: Callable = Callable()
	static var drafts: Array[WeakRef] = []

	func _init() -> void:
		drafts.append(weakref(self))
		if creation_hook.is_valid():
			creation_hook.call()

	func launch_request(enemy: BasicEnemy, request: Dictionary) -> bool:
		attempts += 1
		var ordinal: int = attempts
		if ordinal == reject_at:
			return false
		var accepted: bool = super.launch_request(enemy, request)
		if launch_hook.is_valid():
			launch_hook.call(self, ordinal)
		return accepted

var checks: int = 0
var failures: Array[String] = []
var cases: Array[String] = []
var evidence: Array[Dictionary] = []
var _seen_shot_ids: Dictionary[String, bool] = {}
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_two_organs_and_real_remains()
	await _test_priority_and_stable_ties()
	await _test_armor_and_frozen_rounds()
	await _test_scatter_coverage_and_geometry()
	await _test_synchronous_preparation_reentry()
	await _test_failed_volley_preserves_other_owner()
	await _test_terminal_paths_and_projectile_ownership()
	await _test_required_tracker_and_reset()
	await _test_paid_cultivation_and_real_restart()
	await _test_formal_level_exit()
	_check(root.get_child_count() == _initial_root_children, "All coordinated fixtures leave the tree")
	print("COORDINATED_COMBAT_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases, "evidence": evidence,
		"unique_committed_rounds": _seen_shot_ids.size(),
		"cultivated_binding": "real_paid_delivery_and_maturation",
		"restart": "actual_R_input",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _preset(mode: String) -> WeaponProfile:
	var source: WeaponProfile = load(PRESET_PATHS[mode]) as WeaponProfile
	_check(source != null and source.is_valid(), mode + " preset is valid")
	return source.copy_for_instance() if source != null else WeaponProfile.new()


func _container(parent: Node, node_name: String) -> Node2D:
	var container := Node2D.new()
	container.name = node_name
	parent.add_child(container)
	return container


func _new_fixture(modes: Array[String]) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.world.name = "CoordinatedCombatFixture"
	fixture.enemies = _container(fixture.world, "Enemies")
	fixture.projectiles = _container(fixture.world, "Projectiles")
	fixture.remains = _container(fixture.world, "Remains")
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = 0
	fixture.core.position = Vector2(100, 0)
	fixture.world.add_child(fixture.core)
	fixture.tracker = CombatTargetingSystem.new()
	fixture.tracker.name = "CombatTargetingSystem"
	fixture.world.add_child(fixture.tracker)
	var spawner: RemainsSpawner = REMAINS_SPAWNER_SCENE.instantiate() as RemainsSpawner
	spawner.enemy_container = fixture.enemies
	spawner.remains_container = fixture.remains
	fixture.world.add_child(spawner)
	for mode: String in modes:
		var host: Node2D = _container(fixture.world, "Host%d" % fixture.organs.size())
		var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
		organ.initial_nutrition = 6
		host.add_child(organ)
		var weapon: SporeWeapon = WEAPON_SCENE.instantiate() as SporeWeapon
		weapon.inventory_owner = organ
		weapon.enemy_container = fixture.enemies
		weapon.projectile_container = fixture.projectiles
		weapon.targeting_system = fixture.tracker
		weapon.targeting_required = true
		weapon.position = Vector2(0, -28)
		(weapon.get_node("FireTimer") as Timer).autostart = false
		host.add_child(weapon)
		_check(weapon.configure_profile(_preset(mode)), "Isolated " + mode + " fixture configures explicitly")
		fixture.organs.append(organ)
		fixture.weapons.append(weapon)
	root.add_child(fixture.world)
	current_scene = fixture.world
	for index: int in range(fixture.weapons.size()):
		var weapon: SporeWeapon = fixture.weapons[index]
		(weapon.get_node("FireTimer") as Timer).stop()
		fixture.initial_stock += fixture.organs[index].nutrition
		weapon.volley_committed.connect(_capture_volley.bind(fixture, index))
		weapon.shot_fired.connect(_capture_primary.bind(fixture))
	_check(fixture.tracker.is_accepting(), "Mounted shared tracker accepts commitments")
	return fixture


func _capture_volley(shot_id: String, spent: int, count: int, fixture: Fixture, index: int) -> void:
	_check(not shot_id.is_empty() and not _seen_shot_ids.has(shot_id), "Every paid round has a new nonempty ID")
	_seen_shot_ids[shot_id] = true
	fixture.spent += spent
	fixture.projectile_total += count
	fixture.events.append({"shot_id": shot_id, "nutrition_spent": spent,
		"projectile_count": count, "weapon_index": index})
	_check(spent > 0 and count >= 1 and count <= 3, "Paid event contains actual cost and projectile count")
	var rounds: int = 0
	var owner_spent: int = 0
	var owner_projectiles: int = 0
	for event: Dictionary in fixture.events:
		if int(event["weapon_index"]) == index:
			rounds += 1
			owner_spent += int(event["nutrition_spent"])
			owner_projectiles += int(event["projectile_count"])
	_check(fixture.weapons[index].get_shot_statistics() == {
		"rounds": rounds, "projectiles": owner_projectiles,
		"nutrition_spent": owner_spent, "last_shot_id": shot_id,
	}, "Weapon's original 8.2 statistics commit before the authoritative callback")
	var owned_count: int = 0
	for projectile: SporeProjectile in _projectiles(fixture.projectiles):
		if String(projectile.get_meta("shot_id", "")) == shot_id:
			owned_count += 1
			var id: String = projectile.get_damage_commitment_id()
			var record: Dictionary = fixture.tracker.get_commitment(id)
			_check(fixture.tracker.is_commitment_committed(id)
				and String(record.get("state", "")) == "committed"
				and int(record.get("projectile_id", 0)) == projectile.get_instance_id()
				and int(record.get("owner_id", 0)) == fixture.weapons[index].get_instance_id(),
				"Every event-visible projectile owns its committed matching promise")
	_check(owned_count == count, "Authoritative event sees the whole actual volley")
	_conservation(fixture, "Committed event")


func _capture_primary(enemy: BasicEnemy, fixture: Fixture) -> void:
	fixture.primary_ids.append(enemy.get_instance_id() if is_instance_valid(enemy) else 0)
	_check(fixture.primary_ids.size() == fixture.events.size(), "Legacy shot_fired occurs once after each paid round")


func _conservation(fixture: Fixture, context: String) -> void:
	var owned: int = fixture.spent + fixture.core.nutrition
	for organ: AttackOrgan in fixture.organs:
		owned += organ.nutrition + organ.incoming_nutrition
	_check(owned == fixture.initial_stock, context + " conserves actual event-spent and original local inventories")


func _ledger(tracker: CombatTargetingSystem, prepared: int, committed: int, context: String) -> void:
	var snapshot: Dictionary = tracker.get_snapshot()
	_check(int(snapshot.get("prepared_count", -1)) == prepared
		and int(snapshot.get("committed_count", -1)) == committed
		and int(snapshot.get("total_count", -1)) == prepared + committed,
		context + " has exactly its expected prepared and committed ledger")
	_check(prepared >= 0 and committed >= 0 and int(snapshot.get("total_expected_damage", -1)) >= 0,
		context + " never reports negative damage or ownership")


func _enemy(fixture: Fixture, point: Vector2, hp: int = 8, armor: int = 4,
		with_core: bool = false) -> BasicEnemy:
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = hp
	enemy.armor = armor
	enemy.move_speed = 0.0
	enemy.mother_core = fixture.core if with_core else null
	fixture.enemies.add_child(enemy)
	enemy.global_position = point
	enemy.set_physics_process(false)
	(enemy.get_node("AttackTimer") as Timer).stop()
	enemy.died.connect(func(_dead: BasicEnemy) -> void: fixture.deaths += 1)
	return enemy


func _projectiles(container: Node2D) -> Array[SporeProjectile]:
	var result: Array[SporeProjectile] = []
	for child: Node in container.get_children():
		if child is SporeProjectile and not child.is_queued_for_deletion():
			result.append(child as SporeProjectile)
	return result


func _freeze_projectiles(container: Node2D) -> void:
	for projectile: SporeProjectile in _projectiles(container):
		projectile.set_physics_process(false)
		(projectile.get_node("LifetimeTimer") as Timer).stop()


func _fire_weapon(weapon: SporeWeapon, container: Node2D) -> void:
	(weapon.get_node("FireTimer") as Timer).stop()
	weapon._on_fire_timer_timeout()
	(weapon.get_node("FireTimer") as Timer).stop()
	_freeze_projectiles(container)


func _fire(fixture: Fixture, index: int) -> void:
	_fire_weapon(fixture.weapons[index], fixture.projectiles)


func _owned_projectiles(fixture: Fixture, index: int) -> Array[SporeProjectile]:
	var result: Array[SporeProjectile] = []
	for projectile: SporeProjectile in _projectiles(fixture.projectiles):
		var record: Dictionary = fixture.tracker.get_commitment(projectile.get_damage_commitment_id())
		if int(record.get("owner_id", 0)) == fixture.weapons[index].get_instance_id():
			result.append(projectile)
	return result


func _expect_targets(fixture: Fixture, index: int, expected: Array[BasicEnemy], context: String) -> void:
	var actual_ids: Array[int] = []
	var expected_ids: Array[int] = []
	var unique: Dictionary[int, bool] = {}
	for enemy: BasicEnemy in expected:
		expected_ids.append(enemy.get_instance_id())
	for projectile: SporeProjectile in _owned_projectiles(fixture, index):
		actual_ids.append(projectile.target.get_instance_id())
		unique[projectile.target.get_instance_id()] = true
	_check(actual_ids == expected_ids, context + " chooses the expected uncovered targets in order")
	_check(unique.size() == actual_ids.size(), context + " never duplicates a target within a volley")


func _impact(projectile: SporeProjectile) -> void:
	if is_instance_valid(projectile):
		projectile._physics_process(10.0)
		if is_instance_valid(projectile):
			projectile._physics_process(10.0)


func _hit_all(fixture: Fixture) -> void:
	for projectile: SporeProjectile in _projectiles(fixture.projectiles):
		_impact(projectile)
	await process_frame
	await process_frame
	_ledger(fixture.tracker, 0, 0, "After all actual impacts")
	_check(fixture.projectiles.get_child_count() == 0, "Impacted projectiles leave no duplicate cleanup")
	_conservation(fixture, "Actual impacts")


func _clear_probes() -> void:
	PreparationProjectile.creation_hook = Callable()
	PreparationProjectile.launch_hook = Callable()
	PreparationProjectile.attempts = 0
	PreparationProjectile.reject_at = 0
	PreparationProjectile.drafts.clear()


func _preparation_scene(reject_at: int = 0) -> PackedScene:
	_clear_probes()
	var prototype: Node = PROJECTILE_SCENE.instantiate()
	prototype.set_script(PreparationProjectile)
	for child: Node in prototype.get_children():
		child.owner = prototype
	var packed := PackedScene.new()
	_check(packed.pack(prototype) == OK, "Instrumented real projectile packs in memory")
	prototype.free()
	_clear_probes()
	PreparationProjectile.reject_at = reject_at
	return packed


func _dispose(fixture: Fixture) -> void:
	_clear_probes()
	fixture.tracker.stop()
	if current_scene == fixture.world:
		current_scene = null
	fixture.world.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.world), "Coordinated fixture is fully freed")


func _test_two_organs_and_real_remains() -> void:
	var fixture: Fixture = _new_fixture(["normal", "normal"])
	var first: BasicEnemy = _enemy(fixture, Vector2(50, 0))
	var second: BasicEnemy = _enemy(fixture, Vector2(80, 0))
	_fire(fixture, 0)
	_expect_targets(fixture, 0, [first], "First organ's fatal normal promise")
	_check(first.health == 8 and second.health == 8 and fixture.deaths == 0
		and fixture.remains.get_child_count() == 0, "Launch does not mutate HP or produce a corpse")
	_check(fixture.tracker.get_incoming_damage(first) == 8
		and fixture.tracker.get_remaining_health(first) == 0, "Fatal incoming damage covers the first target")
	_fire(fixture, 1)
	_expect_targets(fixture, 1, [second], "Second same-frame organ avoids fatal overkill")
	_ledger(fixture.tracker, 0, 2, "Both simultaneous organs")
	_fire(fixture, 0)
	_fire(fixture, 1)
	_check(fixture.events.size() == 2 and fixture.spent == 2
		and fixture.organs[0].nutrition == 5 and fixture.organs[1].nutrition == 5,
		"All-covered enemies make both organs wait at zero further cost")
	var first_point: Vector2 = first.global_position
	_impact(_owned_projectiles(fixture, 0)[0])
	_check(first.health == 0 and fixture.deaths == 1 and fixture.remains.get_child_count() == 1,
		"One real fatal impact emits one death and one real RemainsSpawner corpse")
	var corpse: EnemyRemains = fixture.remains.get_child(0) as EnemyRemains
	_check(corpse != null and corpse.nutrition_value == first.remains_nutrition
		and corpse.global_position.is_equal_approx(first_point), "Corpse retains the actual enemy value and death ground point")
	_ledger(fixture.tracker, 0, 1, "First duplicate impact cleanup")
	evidence.append({"case": "two_organs", "rounds_before_hits": 2,
		"spent_before_hits": 2, "first_actual_deaths": fixture.deaths,
		"first_real_corpses": fixture.remains.get_child_count()})
	await _hit_all(fixture)
	_check(fixture.deaths == 2 and fixture.remains.get_child_count() == 2, "Second actual impact also settles exactly once")
	await _dispose(fixture)
	cases.append("same_frame_fatal_coverage_all_covered_wait_and_real_remains")


func _test_priority_and_stable_ties() -> void:
	var fixture: Fixture = _new_fixture(["normal", "normal", "normal"])
	var near_weapon: BasicEnemy = _enemy(fixture, Vector2(15, 0), 8, 4, true)
	var near_core: BasicEnemy = _enemy(fixture, Vector2(60, 0), 8, 4, true)
	var attacking: BasicEnemy = _enemy(fixture, Vector2(80, 0), 8, 4, true)
	var no_core: BasicEnemy = _enemy(fixture, Vector2(5, 0))
	attacking._physics_process(0.0)
	_check(attacking.is_attacking_core() and not near_core.is_attacking_core(), "Priority follows a real running contact AttackTimer")
	attacking.attack_timer.paused = true
	_check(not attacking.is_attacking_core(), "Paused contact timer is not an active core attack")
	attacking.attack_timer.paused = false
	_check(is_inf(no_core.get_core_distance_squared()), "Missing core is assigned infinite core distance")
	_fire(fixture, 0)
	_fire(fixture, 1)
	_fire(fixture, 2)
	_expect_targets(fixture, 0, [attacking], "Active core attacker priority")
	_expect_targets(fixture, 1, [near_core], "Uncovered nearest-core priority")
	_expect_targets(fixture, 2, [near_weapon], "Live core outranks closer missing-core enemy")
	_check(no_core.health == 8 and fixture.core.health > 0, "Readonly priority queries do not apply damage")
	await _hit_all(fixture)
	await _dispose(fixture)
	fixture = _new_fixture(["normal", "normal"])
	var lower_id: BasicEnemy = _enemy(fixture, Vector2(70, 0))
	var higher_id: BasicEnemy = _enemy(fixture, Vector2(70, 0))
	fixture.enemies.move_child(higher_id, 0)
	_check(lower_id.get_instance_id() < higher_id.get_instance_id(), "Tie fixture has ordered independent instance IDs")
	_fire(fixture, 0)
	_fire(fixture, 1)
	_expect_targets(fixture, 0, [lower_id], "Equal priority ignores reversed child order")
	_expect_targets(fixture, 1, [higher_id], "Second organ consumes the next uncovered stable tie")
	await _hit_all(fixture)
	await _dispose(fixture)
	cases.append("real_core_attack_core_distance_ground_distance_and_stable_id_priority")


func _test_armor_and_frozen_rounds() -> void:
	var fixture: Fixture = _new_fixture(["normal", "armor_piercing"])
	var enemy: BasicEnemy = _enemy(fixture, Vector2(60, 0), 28, 4)
	_fire(fixture, 0)
	_check(fixture.tracker.get_incoming_damage(enemy) == 8
		and fixture.tracker.get_remaining_health(enemy) == 20, "Normal prediction uses armor without changing real HP")
	_fire(fixture, 1)
	var normal: SporeProjectile = _owned_projectiles(fixture, 0)[0]
	var ap: SporeProjectile = _owned_projectiles(fixture, 1)[0]
	var normal_id: String = normal.get_damage_commitment_id()
	var ap_id: String = ap.get_damage_commitment_id()
	_check(enemy.health == 28 and fixture.spent == 3 and fixture.projectile_total == 2
		and fixture.tracker.get_incoming_damage(enemy) == 32
		and fixture.tracker.get_remaining_health(enemy) == 0, "AP fills remaining demand with armor-independent 24 at real cost two")
	enemy.armor = 20
	var normal_record: Dictionary = fixture.tracker.get_commitment(normal_id)
	var ap_record: Dictionary = fixture.tracker.get_commitment(ap_id)
	_check(int(normal_record.get("raw_damage", 0)) == 12
		and int(normal_record.get("damage_type", -1)) == WeaponProfile.DamageType.NORMAL
		and int(normal_record.get("expected_damage", 0)) == 1
		and int(ap_record.get("raw_damage", 0)) == 24
		and int(ap_record.get("damage_type", -1)) == WeaponProfile.DamageType.ARMOR_PIERCING
		and int(ap_record.get("expected_damage", 0)) == 24, "Frozen requests re-estimate against current armor, including the one-damage floor")
	_check(fixture.tracker.get_incoming_damage(enemy) == 25
		and fixture.tracker.get_remaining_health(enemy) == 3 and enemy.health == 28,
		"Changing armor restores unmet demand without any prediction damage")
	_check(fixture.weapons[0].configure_profile(_preset("armor_piercing"))
		and fixture.weapons[1].configure_profile(_preset("normal")), "Only the isolated fixture explicitly configures following rounds")
	_check(fixture.tracker.get_commitment(normal_id) == normal_record
		and fixture.tracker.get_commitment(ap_id) == ap_record, "8.2 configuration copies leave existing shot promises unchanged")
	_impact(normal)
	_impact(ap)
	_check(enemy.health == 3 and fixture.spent == 3, "Real old impacts keep their original normal/AP requests after configuration")
	_ledger(fixture.tracker, 0, 0, "Old mixed impacts")
	_fire(fixture, 0)
	_fire(fixture, 1)
	_check(fixture.events.size() == 3 and fixture.spent == 5 and fixture.projectile_total == 3,
		"Following configured AP costs two and covered configured normal waits for free")
	await _hit_all(fixture)
	evidence.append({"case": "armor", "normal_at_armor_20": 1, "ap_at_armor_20": 24,
		"old_impact_hp": 3, "actual_total_spent": fixture.spent})
	await _dispose(fixture)
	cases.append("current_armor_derived_estimates_frozen_8_2_requests_and_actual_costs")


func _test_scatter_coverage_and_geometry() -> void:
	var fixture: Fixture = _new_fixture(["scatter", "normal"])
	fixture.weapons[0].position.y = -350.0
	var covered: BasicEnemy = _enemy(fixture, Vector2(40, 0), 6, 0)
	var primary: BasicEnemy = _enemy(fixture, Vector2(50, 0), 6, 0)
	var boundary: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(30.0)) * 90.0, 6, 0)
	var range_boundary: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(-30.0)) * 145.0, 6, 0)
	var outside: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(30.001)) * 70.0, 6, 0)
	boundary.sprite.position.y = 500.0
	range_boundary.sprite.position.y = -500.0
	_fire(fixture, 1)
	_fire(fixture, 0)
	_expect_targets(fixture, 1, [covered], "Independent fatal normal coverage")
	_expect_targets(fixture, 0, [primary, boundary, range_boundary], "Scatter filters prior coverage and uses full sixty-degree ground cone")
	_check(fixture.events.size() == 2 and fixture.spent == 2 and fixture.projectile_total == 4,
		"Three distinct scatter promises cost one whole round alongside one normal round")
	_check(covered.health == 6 and primary.health == 6 and boundary.health == 6
		and range_boundary.health == 6 and outside.health == 6, "Scatter predictions and high visual offsets cause no early HP change")
	_ledger(fixture.tracker, 0, 4, "Mixed normal and scatter coverage")
	await _hit_all(fixture)
	_check(outside.health == 6 and fixture.deaths == 4, "Outside half-cone is excluded while all distinct real impacts settle")
	await _dispose(fixture)
	fixture = _new_fixture(["scatter"])
	var left: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(179.0)) * 50.0, 6, 0)
	var wrapped: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(-179.0)) * 80.0, 6, 0)
	var edge: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(149.0)) * 110.0, 6, 0)
	var off_edge: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(148.999)) * 70.0, 6, 0)
	_fire(fixture, 0)
	_expect_targets(fixture, 0, [left, wrapped, edge], "Tracked scatter wraps across PI at the inclusive half-cone boundary")
	await _hit_all(fixture)
	_check(off_edge.health == 6, "PI wraparound preserves the cone exclusion")
	await _dispose(fixture)
	cases.append("scatter_distinct_uncovered_targets_ground_range_half_cone_and_pi_wrap")


func _test_synchronous_preparation_reentry() -> void:
	var fixture: Fixture = _new_fixture(["scatter", "normal"])
	var first: BasicEnemy = _enemy(fixture, Vector2(50, 0), 6, 0)
	var second: BasicEnemy = _enemy(fixture, Vector2(80, 0), 6, 0)
	var third: BasicEnemy = _enemy(fixture, Vector2(110, 0), 6, 0)
	var spare: BasicEnemy = _enemy(fixture, Vector2(130, 0), 12, 0)
	fixture.weapons[0].projectile_scene = _preparation_scene()
	var observed: Dictionary = {"created": 0, "tree_callbacks": 0, "reentered": false}
	PreparationProjectile.creation_hook = func() -> void:
		observed["created"] = int(observed["created"]) + 1
		_check(fixture.organs[0].nutrition == 6, "Instancing callback observes no premature scatter debit")
		_ledger(fixture.tracker, 3, 1 if bool(observed["reentered"]) else 0, "All promises precede every instance callback")
		if not bool(observed["reentered"]):
			observed["reentered"] = true
			_fire(fixture, 1)
			fixture.weapons[0]._on_fire_timer_timeout()
			_expect_targets(fixture, 1, [spare], "Synchronous second weapon sees the entire prepared scatter coverage")
	PreparationProjectile.launch_hook = func(draft: SporeProjectile, _ordinal: int) -> void:
		_ledger(fixture.tracker, 3, 1, "Launch callback retains whole prepared batch")
		draft._physics_process(10.0)
		fixture.weapons[1]._on_fire_timer_timeout()
		_check(first.health == 6 and second.health == 6 and third.health == 6 and spare.health == 12,
			"Synchronous launch reentry cannot hit any uncommitted or frozen projectile")
	fixture.projectiles.child_entered_tree.connect(func(child: Node) -> void:
		if child is PreparationProjectile:
			observed["tree_callbacks"] = int(observed["tree_callbacks"]) + 1
			_ledger(fixture.tracker, 3, 1, "Tree callback sees all still-prepared scatter promises")
			(child as SporeProjectile)._physics_process(10.0)
			fixture.weapons[1]._on_fire_timer_timeout())
	_fire(fixture, 0)
	_check(int(observed["created"]) == 3 and int(observed["tree_callbacks"]) == 3
		and PreparationProjectile.attempts == 3 and fixture.events.size() == 2,
		"Actual instance, launch and tree callbacks observe one complete scatter and one independent round")
	_expect_targets(fixture, 0, [first, second, third], "Own-ID exclusion keeps fatal prepared targets valid for atomic commit")
	_ledger(fixture.tracker, 0, 4, "Atomic commit after synchronous reentry")
	_check(fixture.spent == 2 and fixture.primary_ids.size() == 2
		and first.health == 6 and second.health == 6 and third.health == 6 and spare.health == 12,
		"Successful reentry charges two real rounds and still causes no pre-hit damage")
	_clear_probes()
	_fire(fixture, 0)
	_fire(fixture, 1)
	_check(fixture.events.size() == 2 and fixture.spent == 2
		and fixture.projectile_total == 4, "All-covered scatter and normal organs wait without another cost or projectile")
	await _hit_all(fixture)
	evidence.append({"case": "synchronous_reentry", "instance_callbacks": observed["created"],
		"tree_callbacks": observed["tree_callbacks"], "prepared_before_callbacks": 3,
		"actual_rounds": fixture.events.size(), "actual_spent": fixture.spent})
	await _dispose(fixture)
	cases.append("all_promises_before_instance_launch_tree_reentry_and_atomic_batch_commit")


func _test_failed_volley_preserves_other_owner() -> void:
	var fixture: Fixture = _new_fixture(["scatter", "normal"])
	var first: BasicEnemy = _enemy(fixture, Vector2(50, 0), 6, 0)
	var second: BasicEnemy = _enemy(fixture, Vector2(80, 0), 6, 0)
	var third: BasicEnemy = _enemy(fixture, Vector2(110, 0), 6, 0)
	var spare: BasicEnemy = _enemy(fixture, Vector2(130, 0), 12, 0)
	fixture.weapons[0].projectile_scene = _preparation_scene(2)
	var reentered: Dictionary = {"done": false}
	PreparationProjectile.creation_hook = func() -> void:
		if not bool(reentered["done"]):
			reentered["done"] = true
			_ledger(fixture.tracker, 3, 0, "Failing volley prepares every target before independent reentry")
			_fire(fixture, 1)
	_fire(fixture, 0)
	_check(PreparationProjectile.attempts == 2 and fixture.events.size() == 1
		and int(fixture.events[0]["weapon_index"]) == 1
		and fixture.organs[0].nutrition == 6 and fixture.organs[1].nutrition == 5,
		"Second launch failure rolls back only its unpaid scatter round")
	_ledger(fixture.tracker, 0, 1, "Failed partial volley releases only its own promises")
	var independent: SporeProjectile = _owned_projectiles(fixture, 1)[0]
	var independent_id: String = independent.get_damage_commitment_id()
	_check(fixture.tracker.is_commitment_committed(independent_id)
		and fixture.tracker.get_incoming_damage(spare) == 12
		and fixture.tracker.get_remaining_health(first) == 6
		and fixture.tracker.get_remaining_health(second) == 6
		and fixture.tracker.get_remaining_health(third) == 6,
		"Independent paid promise survives while all three failed targets regain demand")
	for draft: WeakRef in PreparationProjectile.drafts:
		_check(draft.get_ref() == null, "Partial failure frees every actual instantiated scatter draft")
	_check(first.health == 6 and second.health == 6 and third.health == 6 and spare.health == 12,
		"Failed preparation and independent launch apply no early damage")
	_clear_probes()
	fixture.weapons[0].projectile_scene = PROJECTILE_SCENE
	_fire(fixture, 0)
	_expect_targets(fixture, 0, [first, second, third], "Only restored failed demands are retried")
	_check(fixture.tracker.is_commitment_committed(independent_id) and fixture.spent == 2,
		"Successful retry leaves the original other-owner promise and accounting intact")
	await _hit_all(fixture)
	await _dispose(fixture)
	cases.append("partial_launch_failure_releases_only_own_promises_and_preserves_paid_reentry")


func _test_terminal_paths_and_projectile_ownership() -> void:
	for outcome: String in ["target_died", "target_freed", "timeout", "cancel", "projectile_exit", "weapon_removed"]:
		var fixture: Fixture = _new_fixture(["normal", "normal"])
		var first: BasicEnemy = _enemy(fixture, Vector2(50, 0))
		var second: BasicEnemy = _enemy(fixture, Vector2(80, 0))
		_fire(fixture, 0)
		var shot: SporeProjectile = _owned_projectiles(fixture, 0)[0]
		var old_id: String = shot.get_damage_commitment_id()
		match outcome:
			"target_died":
				first.take_damage(999)
				_impact(shot)
				_check(fixture.deaths == 1 and fixture.remains.get_child_count() == 1,
					"Early real enemy death makes exactly one corpse despite a stale paid shot")
			"target_freed":
				first.queue_free()
				await process_frame
				await process_frame
				_impact(shot)
			"timeout":
				(shot.get_node("LifetimeTimer") as Timer).timeout.emit()
				(shot.get_node("LifetimeTimer") as Timer).timeout.emit()
				shot.cancel_flight()
			"cancel":
				shot.cancel_flight()
				shot.cancel_flight()
				_impact(shot)
			"projectile_exit":
				shot.queue_free()
				await process_frame
				await process_frame
			"weapon_removed":
				fixture.weapons[0].queue_free()
				await process_frame
				await process_frame
		if outcome == "weapon_removed":
			_check(fixture.tracker.is_commitment_committed(old_id)
				and fixture.tracker.get_incoming_damage(first) == 8, "Committed projectile owns its promise after weapon removal")
			_fire(fixture, 1)
			_expect_targets(fixture, 1, [second], "Surviving organ respects removed weapon's paid in-flight coverage")
		else:
			_ledger(fixture.tracker, 0, 0, outcome + " releases the old promise exactly once")
			_check(not fixture.tracker.release_commitment(old_id), outcome + " duplicate old release is harmless")
			_fire(fixture, 1)
			var expected: BasicEnemy = second if outcome in ["target_died", "target_freed"] else first
			_expect_targets(fixture, 1, [expected], outcome + " restores the correct remaining target choice")
			var next: SporeProjectile = _owned_projectiles(fixture, 1)[0]
			var next_id: String = next.get_damage_commitment_id()
			_check(next_id != old_id and not fixture.tracker.release_commitment(old_id)
				and fixture.tracker.is_commitment_committed(next_id)
				and fixture.tracker.get_incoming_damage(expected) == 8,
				outcome + " stale cleanup cannot release a later independent shot")
		_check(fixture.events.size() == 2 and fixture.spent == 2
			and fixture.organs[0].nutrition == 5 and fixture.organs[1].nutrition == 5,
			outcome + " never refunds paid rounds or duplicates cost receipts")
		await _hit_all(fixture)
		await _dispose(fixture)
	cases.append("early_death_free_timeout_cancel_exit_duplicate_cleanup_and_projectile_owned_promises")


func _test_required_tracker_and_reset() -> void:
	var fixture: Fixture = _new_fixture(["armor_piercing", "normal"])
	var enemy: BasicEnemy = _enemy(fixture, Vector2(60, 0), 24, 0)
	fixture.weapons[0].targeting_system = null
	_fire(fixture, 0)
	_check(fixture.events.is_empty() and fixture.spent == 0, "Required absent tracker prevents firing and debit")
	fixture.weapons[0].targeting_system = fixture.tracker
	fixture.tracker.stop()
	_fire(fixture, 0)
	_fire(fixture, 1)
	_check(fixture.events.is_empty() and fixture.organs[0].nutrition == 6
		and fixture.organs[1].nutrition == 6, "Required stopped tracker makes all organs wait without fallback firing")
	fixture.tracker.reset()
	_fire(fixture, 0)
	var shot: SporeProjectile = _owned_projectiles(fixture, 0)[0]
	var old_id: String = shot.get_damage_commitment_id()
	var old_generation: int = int(fixture.tracker.get_snapshot()["generation"])
	fixture.tracker.reset()
	_ledger(fixture.tracker, 0, 0, "Reset cancels all bound shots")
	_check(fixture.tracker.is_accepting()
		and int(fixture.tracker.get_snapshot()["generation"]) > old_generation
		and enemy.health == 24 and fixture.organs[0].nutrition == 4 and fixture.spent == 2,
		"Reset advances the generation and retains the original paid AP debit without damage")
	_impact(shot)
	_fire(fixture, 1)
	var next: SporeProjectile = _owned_projectiles(fixture, 1)[0]
	var next_id: String = next.get_damage_commitment_id()
	_check(next_id != old_id and not fixture.tracker.release_commitment(old_id)
		and fixture.tracker.is_commitment_committed(next_id) and enemy.health == 24,
		"Reset's cancelled old projectile and release cannot damage or clear a new generation")
	await _hit_all(fixture)
	_check(enemy.health == 12 and fixture.spent == 3, "Only the later real normal shot hits after reset")
	await _dispose(fixture)
	cases.append("required_absent_stopped_tracker_reset_generation_and_no_paid_refund")


func _prepare_level(level: Node2D) -> void:
	# 保留本地 C 的既有单执行器入口；器官付款、运输和成熟仍用实际正式系统。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	level.get_node("Systems/CultivationSupplySystem").auto_supply = false
	(level.get_node("Systems/SupplySystem/DispatchTimer") as Timer).autostart = false
	for path: String in ["World/Colony/Nodes/HyphaNode/SporeWeapon", "World/Colony/Nodes/RightNode/SporeWeapon"]:
		(level.get_node(path + "/FireTimer") as Timer).autostart = false


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _new_level() -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level)
	root.add_child(level)
	current_scene = level
	level.enemy_spawner.stop_spawning()
	(level.supply_system.get_node("DispatchTimer") as Timer).stop()
	(level.recycling_system.get_node("DispatchTimer") as Timer).stop()
	await _wait_frames(2)
	_check(level.get_node("World/Enemies").get_child_count() == 0
		and level.get_node("World/Remains").get_child_count() == 0, "Formal isolated fixture has no wave or external resource income")
	return level


func _step() -> void:
	await physics_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for _frame: int in range(count):
		await _step()


func _press(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event)
	var released: InputEventKey = event.duplicate() as InputEventKey
	released.pressed = false
	root.push_input(released)


func _level_accounted(level: Node2D) -> int:
	var statistics: Dictionary = level.get_combat_statistics()
	var total: int = level.mother_core.nutrition + int(statistics["nutrition_spent"])
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		total += organ.nutrition + organ.incoming_nutrition
	var cultivation: Dictionary = level.cultivation_system.get_resource_snapshot()
	total += int(cultivation.get("structure_consumed", 0))
	total += int(cultivation.get("buffered_nutrition", 0)) + int(cultivation.get("startup_reserved", 0))
	total += level.cultivation_supply_system.get_in_transit_nutrition()
	# 已转交的四点启动营养只在器官库存中计入一次。
	return total


func _connected_empty_host(level: Node2D) -> HyphaNode:
	var host: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	host.name = "CoordinatedPaidHost"
	host.position = level.weapon.inventory_owner.global_position + Vector2(40, 0)
	level.hypha_nodes.add_child(host)
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.name = "CoordinatedHostEdge"
	edge.start_node = level.weapon.inventory_owner.get_parent() as Node2D
	edge.end_node = host
	level.hypha_edges.add_child(edge)
	_check(host.is_organ_slot_available() and level.network_system.is_connected_to_core(host),
		"Explicit mature-host fixture is empty and connected by a real registered edge")
	return host


func _level_enemy(level: Node2D, point: Vector2, hp: int = 8, armor: int = 4) -> BasicEnemy:
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = hp
	enemy.armor = armor
	enemy.move_speed = 0.0
	enemy.mother_core = level.mother_core
	level.get_node("World/Enemies").add_child(enemy)
	enemy.global_position = point
	enemy.set_physics_process(false)
	(enemy.get_node("AttackTimer") as Timer).stop()
	return enemy


func _remove_level(level: Node2D) -> void:
	if current_scene == level:
		current_scene = null
	level.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(level), "Formal coordinated level is fully freed")


func _test_paid_cultivation_and_real_restart() -> void:
	var level: Node2D = await _new_level()
	var tracker: CombatTargetingSystem = level.get_node_or_null("Systems/CombatTargetingSystem") as CombatTargetingSystem
	_check(is_instance_valid(tracker) and level.combat_targeting_system == tracker,
		"Formal level exposes its owned Systems/CombatTargetingSystem")
	if not is_instance_valid(tracker):
		await _remove_level(level)
		return
	_ledger(tracker, 0, 0, "Initial formal ledger")
	for weapon: SporeWeapon in level.get_weapons():
		_check(weapon.targeting_required and weapon.targeting_system == tracker,
			"Both actual preplaced weapons require the same formal tracker")
	var initial_total: int = _level_accounted(level)
	var initial_core: int = level.mother_core.nutrition
	var host: HyphaNode = _connected_empty_host(level)
	var maturity: Dictionary = {"count": 0, "registered": false, "organ": null, "weapon": null}
	host.child_entered_tree.connect(func(child: Node) -> void:
		if child is SporeWeapon:
			maturity["registered"] = child.targeting_required and child.targeting_system == tracker
			_check(bool(maturity["registered"]), "The existing child registration hook binds the real new weapon immediately"))
	level.cultivation_system.organ_matured.connect(func(task_id: int, matured_host: HyphaNode,
			organ: AttackOrgan, weapon: SporeWeapon) -> void:
		if matured_host == host:
			maturity["count"] = int(maturity["count"]) + 1
			maturity["organ"] = organ
			maturity["weapon"] = weapon
			(weapon.get_node("FireTimer") as Timer).stop()
			var task: Dictionary = level.cultivation_system.get_task_snapshot(task_id)
			_check(int(task.get("structure_consumed", 0)) == 8
				and int(task.get("startup_transferred", 0)) == 4
				and int(task.get("consumed_nutrition", 0)) == 12
				and float(task.get("effective_time", 0.0)) >= 3.0,
				"Actual maturation commits eight structure, four startup and three funded effective seconds")
			_check(organ.nutrition == 4 and organ.incoming_nutrition == 0
				and weapon.inventory_owner == organ and weapon.targeting_required
				and weapon.targeting_system == tracker, "Real paid startup inventory and the shared tracker reach the mature sibling weapon"))
	host.selection_requested.emit(host)
	_press(KEY_C)
	var task_id: int = int(level.cultivation_system.get_task_snapshot().get("task_id", 0))
	_check(task_id > 0 and level.cultivation_system.has_active_task()
		and host.get_organ_bud() != null and level.mother_core.nutrition == initial_core,
		"Actual C starts an unfunded noncombat bud without fabricating an organ or receipt")
	if task_id <= 0:
		await _remove_level(level)
		return
	var payments: int = 0
	var observed_transit: bool = false
	var observed_partial: bool = false
	for _frame: int in range(6000):
		var task: Dictionary = level.cultivation_system.get_task_snapshot(task_id)
		if task.get("state") == &"completed":
			break
		var before: int = level.mother_core.nutrition
		if level.cultivation_supply_system.try_dispatch():
			payments += 1
			_check(level.mother_core.nutrition == before - 1, "Every real cultivation dispatch pays exactly one original-core nutrient")
		if not observed_transit and level.cultivation_supply_system.get_in_transit_count() > 0:
			observed_transit = true
			_check(int(task.get("structure_consumed", 0)) == 0
				and float(task.get("effective_time", 0.0)) == 0.0
				and level.get_weapons().size() == 2, "Paid flight has not supplied structure, time or a premature combat weapon")
		if not observed_partial and int(task.get("structure_consumed", 0)) > 0:
			observed_partial = true
			_check(level.get_weapons().size() == 2 and int(maturity["count"]) == 0,
				"Actually delivered partial structure cannot register a combat organ before maturity")
		await _step()
		if _frame % 120 == 0:
			_check(_level_accounted(level) == initial_total, "Real cultivation frames conserve paid transit, structure and local stock")
	var completed: Dictionary = level.cultivation_system.get_task_snapshot(task_id)
	_check(completed.get("state") == &"completed" and payments == 12
		and observed_transit and observed_partial and int(maturity["count"]) == 1
		and bool(maturity["registered"]), "Twelve real payments and packet arrivals mature exactly one hooked combat organ")
	var paid_organ: AttackOrgan = maturity.get("organ") as AttackOrgan
	var paid_weapon: SporeWeapon = maturity.get("weapon") as SporeWeapon
	if not is_instance_valid(paid_organ) or not is_instance_valid(paid_weapon):
		await _remove_level(level)
		return
	_check(level.mother_core.nutrition == initial_core - 12
		and level.cultivation_supply_system.get_in_transit_nutrition() == 0
		and level.supply_system.get_registered_organs().has(paid_organ)
		and level.get_weapons().size() == 3 and _level_accounted(level) == initial_total,
		"Paid mature organ joins ordinary supply and conserves the unique startup transfer")
	var projectiles: Node2D = level.get_node("World/Projectiles") as Node2D
	var enemy: BasicEnemy = _level_enemy(level, level.weapon.inventory_owner.global_position + Vector2(20, 0))
	_fire_weapon(level.weapon, projectiles)
	_fire_weapon(paid_weapon, projectiles)
	_check(level.get_combat_statistics() == {"rounds": 1, "projectiles": 1, "nutrition_spent": 1}
		and paid_organ.nutrition == 4 and enemy.health == 8,
		"Real cultivated weapon respects a preplaced fatal promise and waits with all its paid startup stock")
	var first_shot: SporeProjectile = _projectiles(projectiles)[0]
	first_shot.cancel_flight()
	first_shot.cancel_flight()
	_fire_weapon(paid_weapon, projectiles)
	_fire_weapon(level.weapon, projectiles)
	_check(level.get_combat_statistics() == {"rounds": 2, "projectiles": 2, "nutrition_spent": 2}
		and paid_organ.nutrition == 3 and level.weapon.inventory_owner.nutrition == 3
		and tracker.get_incoming_damage(enemy) == 8 and _level_accounted(level) == initial_total,
		"Cancelled preplaced shot stays paid and real cultivated stock funds the next shared promise")
	var second_shot: SporeProjectile = _projectiles(projectiles)[0]
	second_shot.cancel_flight()
	_fire_weapon(paid_weapon, projectiles)
	var old_shot: SporeProjectile = _projectiles(projectiles)[0]
	var old_commitment_id: String = old_shot.get_damage_commitment_id()
	_check(paid_organ.nutrition == 2 and level.supply_system.request_supply(paid_organ),
		"Real paid combat stock creates a legitimate separately paid ordinary supply shipment")
	for child: Node in level.supply_system.packet_container.get_children():
		if child is NutrientPacket:
			child.set_physics_process(false)
	_check(paid_organ.incoming_nutrition == 1 and _level_accounted(level) == initial_total,
		"Pending ordinary shipment owns one paid nutrient exactly once before restart")
	var old_packet: NutrientPacket = null
	for child: Node in level.supply_system.packet_container.get_children():
		if child is NutrientPacket:
			old_packet = child as NutrientPacket
	var old_callbacks: Array[Callable] = []
	if is_instance_valid(old_packet):
		for connection: Dictionary in old_packet.get_signal_connection_list(&"arrived"):
			old_callbacks.append(connection["callable"])
	var old_tracker_id: int = tracker.get_instance_id()
	var old_level_id: int = level.get_instance_id()
	var old_tracker_ref: WeakRef = weakref(tracker)
	var old_shot_ref: WeakRef = weakref(old_shot)
	var old_packet_ref: WeakRef = weakref(old_packet) if is_instance_valid(old_packet) else null
	var restart: Dictionary = {"refund_callbacks": 0, "stopped_before_refund": false,
		"last_balance": level.mother_core.nutrition, "refunded_nutrition": 0}
	level.mother_core.nutrition_changed.connect(func(balance: int) -> void:
		restart["refund_callbacks"] = int(restart["refund_callbacks"]) + 1
		restart["refunded_nutrition"] = int(restart["refunded_nutrition"]) + maxi(0, balance - int(restart["last_balance"]))
		restart["last_balance"] = balance
		var old_tracker: CombatTargetingSystem = old_tracker_ref.get_ref() as CombatTargetingSystem
		if is_instance_valid(old_tracker):
			restart["stopped_before_refund"] = not old_tracker.is_accepting() \
				and int(old_tracker.get_snapshot().get("total_count", -1)) == 0
			_check(bool(restart["stopped_before_refund"]), "Actual R stops and cancels the old combat ledger before supply refund callbacks"))
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	await _wait_frames(6)
	root.child_entered_tree.disconnect(_prepare_reload_child)
	var restarted: Node2D = current_scene as Node2D
	_check(is_instance_valid(restarted) and restarted.get_instance_id() != old_level_id,
		"Actual R input reloads the scene with paid stock and a committed shot in flight")
	if not is_instance_valid(restarted) or restarted.get_instance_id() == old_level_id:
		if is_instance_valid(level):
			await _remove_level(level)
		return
	var new_tracker: CombatTargetingSystem = restarted.combat_targeting_system
	_check(is_instance_valid(new_tracker) and new_tracker.get_instance_id() != old_tracker_id
		and new_tracker.is_accepting(), "Reload constructs a new accepting tracker with a different identity")
	_ledger(new_tracker, 0, 0, "Reloaded formal ledger starts empty")
	_check(int(restart["refund_callbacks"]) >= 1 and int(restart["refunded_nutrition"]) == 1
		and bool(restart["stopped_before_refund"])
		and old_tracker_ref.get_ref() == null and old_shot_ref.get_ref() == null
		and old_packet_ref != null and old_packet_ref.get_ref() == null,
		"Old paid shipment refunds its source once and all old tracker/projectile/packet objects retire")
	for callback: Callable in old_callbacks:
		_check(not callback.is_valid(), "Old shipment callbacks cannot be invoked into the restarted scene")
	_check(restarted.mother_core.nutrition == 72 and restarted.get_weapons().size() == 2
		and restarted.hypha_nodes.get_child_count() == 3
		and restarted.cultivation_system.get_task_snapshot().get("state") == &"idle"
		and restarted.get_combat_statistics() == {"rounds": 0, "projectiles": 0, "nutrition_spent": 0},
		"Actual reload restores ordinary core, nodes, cultivation state and zero 8.2 combat statistics")
	for weapon: SporeWeapon in restarted.get_weapons():
		_check(weapon.targeting_required and weapon.targeting_system == new_tracker,
			"Every reloaded preplaced weapon binds the new shared tracker")
	var new_projectiles: Node2D = restarted.get_node("World/Projectiles") as Node2D
	var new_enemy: BasicEnemy = _level_enemy(restarted, restarted.weapon.inventory_owner.global_position + Vector2(40, 0), 12, 0)
	_fire_weapon(restarted.weapon, new_projectiles)
	var new_shot: SporeProjectile = _projectiles(new_projectiles)[0]
	var new_id: String = new_shot.get_damage_commitment_id()
	_check(new_id != old_commitment_id and not new_tracker.release_commitment(old_commitment_id)
		and new_tracker.is_commitment_committed(new_id)
		and new_tracker.get_incoming_damage(new_enemy) == 12, "Stale old identity cannot release a real new-scene promise")
	await _wait_frames(30)
	_check(new_enemy.health == 12 and new_tracker.get_incoming_damage(new_enemy) == 12
		and restarted.mother_core.nutrition == 72
		and restarted.get_combat_statistics() == {"rounds": 1, "projectiles": 1, "nutrition_spent": 1},
		"Late old cleanup changes neither new ledger, actual HP, source funds nor paid statistics")
	evidence.append({"case": "paid_cultivation_and_R", "cultivation_payments": payments,
		"structure": 8, "startup": 4, "effective_time": completed.get("effective_time", 0.0),
		"matured": maturity["count"], "bound_by_child_hook": maturity["registered"],
		"old_tracker_id": old_tracker_id, "new_tracker_id": new_tracker.get_instance_id(),
		"stopped_before_refund": restart["stopped_before_refund"], "old_refunded_nutrition": restart["refunded_nutrition"]})
	restarted.mother_core.take_damage(restarted.mother_core.health)
	_check(not new_tracker.is_accepting() and new_enemy.health == 12,
		"Actual core defeat stops the formal tracker and dissipates the paid shot before a hit")
	_ledger(new_tracker, 0, 0, "Defeated core ledger")
	var defeated_statistics: Dictionary = restarted.get_combat_statistics()
	_fire_weapon(restarted.weapon, new_projectiles)
	_check(restarted.get_combat_statistics() == defeated_statistics,
		"Defeated required weapon cannot create a fallback shot or another debit")
	await _remove_level(restarted)
	cases.append("formal_preplaced_paid_cultivated_child_binding_actual_R_stale_isolation_and_core_defeat")


func _test_formal_level_exit() -> void:
	var level: Node2D = await _new_level()
	var tracker: CombatTargetingSystem = level.combat_targeting_system
	var enemy: BasicEnemy = _level_enemy(level, level.weapon.inventory_owner.global_position + Vector2(40, 0))
	var projectiles: Node2D = level.get_node("World/Projectiles") as Node2D
	_fire_weapon(level.weapon, projectiles)
	_ledger(tracker, 0, 1, "Live formal level before exit")
	current_scene = null
	root.remove_child(level)
	_check(not tracker.is_accepting() and enemy.health == 8
		and level.get_combat_statistics() == {"rounds": 1, "projectiles": 1, "nutrition_spent": 1},
		"Leaving a live formal level stops its tracker and retains the actual paid round")
	_ledger(tracker, 0, 0, "Exited formal ledger")
	level.free()
	await process_frame
	await process_frame
	cases.append("formal_level_exit_stops_and_cancels_live_commitments")
