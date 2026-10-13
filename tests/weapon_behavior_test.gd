extends SceneTree
## 显式测试配置三种真实射击；配置入口不代表玩家付费分化。

const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/spore_projectile.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PRESET_PATHS: Dictionary = {
	"normal": "res://resources/weapons/normal_spore.tres",
	"armor_piercing": "res://resources/weapons/armor_piercing_spore.tres",
	"scatter": "res://resources/weapons/scatter_spore.tres",
}
const POSITION_EPSILON: float = 0.0001

class Fixture:
	extends RefCounted
	var world: Node2D
	var host: Node2D
	var organ: AttackOrgan
	var weapon: SporeWeapon
	var enemies: Node2D
	var projectiles: Node2D
	var initial_stock: int = 0
	var spent: int = 0
	var projectile_total: int = 0
	var events: Array[Dictionary] = []
	var primary_ids: Array[int] = []
	var timeline: Array[String] = []

# 只替换测试打包场景的请求入口；命中、伤害与销毁仍继承真实弹丸。
class PreparationProjectile:
	extends SporeProjectile
	static var attempts: int = 0
	static var reject_at: int = 0
	static var hook: Callable = Callable()
	static var drafts: Array[WeakRef] = []

	func _init() -> void:
		drafts.append(weakref(self))

	func launch_request(enemy: BasicEnemy, request: Dictionary) -> bool:
		attempts += 1
		var ordinal: int = attempts
		if reject_at == ordinal:
			return false
		var accepted: bool = super.launch_request(enemy, request)
		if hook.is_valid():
			hook.call(self, ordinal)
		return accepted

var failures: Array[String] = []
var checks: int = 0
var cases: Array[String] = []
var _seen_shot_ids: Dictionary[String, bool] = {}
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_real_modes()
	await _test_scatter_target_counts()
	await _test_ground_range_and_cone()
	await _test_wraparound_and_coincident_primary()
	await _test_stable_nearest_order()
	await _test_no_commit_conditions()
	await _test_preparation_failures()
	await _test_preparation_reentry()
	await _test_commit_callbacks_and_snapshot()
	await _test_consumed_projectiles_do_not_refund()
	await _test_configuration_cooldown_and_enable()
	_check(root.get_child_count() == _initial_root_children, "All weapon fixtures leave the tree")
	print("WEAPON_BEHAVIOR_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases,
		"unique_committed_rounds": _seen_shot_ids.size(),
		"configuration": "explicit_test_setup",
		"damage": "real_projectile_and_enemy_hp",
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


func _values(profile: WeaponProfile) -> Dictionary:
	if profile == null:
		return {}
	return {
		"damage": profile.damage, "fire_interval": profile.fire_interval,
		"attack_range": profile.attack_range, "nutrition_cost": profile.nutrition_cost,
		"max_targets": profile.max_targets, "spread_angle_degrees": profile.spread_angle_degrees,
		"damage_type": int(profile.damage_type),
	}


func _new_fixture(profile: WeaponProfile, stock: int = 6,
		ground: Vector2 = Vector2.ZERO, muzzle_offset: Vector2 = Vector2(0, -28)) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.world.name = "WeaponBehaviorFixture"
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.host = Node2D.new()
	fixture.host.position = ground
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.projectiles)
	fixture.world.add_child(fixture.host)
	fixture.organ = ORGAN_SCENE.instantiate() as AttackOrgan
	fixture.organ.initial_nutrition = stock
	fixture.host.add_child(fixture.organ)
	fixture.weapon = WEAPON_SCENE.instantiate() as SporeWeapon
	fixture.weapon.inventory_owner = fixture.organ
	fixture.weapon.enemy_container = fixture.enemies
	fixture.weapon.projectile_container = fixture.projectiles
	fixture.weapon.position = muzzle_offset
	var timer: Timer = fixture.weapon.get_node("FireTimer") as Timer
	timer.autostart = false
	fixture.host.add_child(fixture.weapon)
	_check(fixture.weapon.configure_profile(profile), "Explicit fixture configuration succeeds")
	root.add_child(fixture.world)
	current_scene = fixture.world
	timer.stop()
	fixture.initial_stock = fixture.organ.nutrition
	fixture.weapon.volley_committed.connect(_capture_volley.bind(fixture))
	fixture.weapon.shot_fired.connect(_capture_primary.bind(fixture))
	fixture.organ.inventory_changed.connect(_capture_inventory.bind(fixture))
	_check(fixture.weapon.has_valid_profile() and fixture.weapon.is_firing_enabled(),
		"Mounted weapon has a valid enabled configuration")
	return fixture


func _capture_volley(shot_id: String, nutrition_spent: int,
		projectile_count: int, fixture: Fixture) -> void:
	_check(not shot_id.is_empty() and not _seen_shot_ids.has(shot_id),
		"Committed round has a globally new nonempty identifier")
	_seen_shot_ids[shot_id] = true
	fixture.spent += nutrition_spent
	fixture.projectile_total += projectile_count
	fixture.events.append({"shot_id": shot_id, "nutrition_spent": nutrition_spent,
		"projectile_count": projectile_count})
	fixture.timeline.append("volley")
	_check(nutrition_spent > 0 and projectile_count >= 1 and projectile_count <= 3,
		"Committed event contains actual positive cost and bounded projectile count")
	_check(fixture.organ.nutrition + fixture.spent == fixture.initial_stock,
		"Authoritative event observes the complete local debit")
	var statistics: Dictionary = fixture.weapon.get_shot_statistics()
	_check(statistics == {"rounds": fixture.events.size(),
		"projectiles": fixture.projectile_total, "nutrition_spent": fixture.spent,
		"last_shot_id": shot_id}, "Counters and ID are committed before event callbacks")
	for child: Node in fixture.projectiles.get_children():
		_check(child is SporeProjectile and child.is_inside_tree()
			and child.get_parent() == fixture.projectiles,
			"Event observes actual projectiles owned by their captured container")


func _capture_primary(enemy: BasicEnemy, fixture: Fixture) -> void:
	fixture.primary_ids.append(enemy.get_instance_id())
	fixture.timeline.append("legacy")
	_check(fixture.events.size() == fixture.primary_ids.size(),
		"Legacy signal occurs once per round after its authoritative event")


func _capture_inventory(_stored: int, _incoming: int, _capacity: int, fixture: Fixture) -> void:
	fixture.timeline.append("inventory")
	_check(fixture.organ.nutrition + fixture.spent == fixture.initial_stock,
		"Inventory notification follows the authoritative committed cost")


func _enemy(fixture: Fixture, offset: Vector2, armor_value: int = 4) -> BasicEnemy:
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = 200
	enemy.move_speed = 0.0
	enemy.armor = armor_value
	fixture.enemies.add_child(enemy)
	enemy.global_position = fixture.organ.global_position + offset
	enemy.set_physics_process(false)
	return enemy


func _projectiles(fixture: Fixture) -> Array[SporeProjectile]:
	var result: Array[SporeProjectile] = []
	for child: Node in fixture.projectiles.get_children():
		if child is SporeProjectile and not child.is_queued_for_deletion():
			result.append(child as SporeProjectile)
	return result


func _freeze_projectiles(fixture: Fixture) -> void:
	for projectile: SporeProjectile in _projectiles(fixture):
		projectile.set_physics_process(false)
		var lifetime: Timer = projectile.get_node_or_null("LifetimeTimer") as Timer
		if lifetime != null:
			lifetime.stop()


func _fire(fixture: Fixture) -> void:
	# 仅隔离夹具显式调用调度入口；生产计时器的冷却另有真实帧验收。
	(fixture.weapon.get_node("FireTimer") as Timer).stop()
	fixture.weapon._on_fire_timer_timeout()
	_freeze_projectiles(fixture)


func _hit_all(fixture: Fixture) -> void:
	for projectile: SporeProjectile in _projectiles(fixture):
		projectile._physics_process(10.0)
		projectile._physics_process(10.0)
	await process_frame
	await process_frame
	_check(fixture.projectiles.get_child_count() == 0, "Real hit projectiles are removed once")


func _targets(fixture: Fixture) -> Array[int]:
	var result: Array[int] = []
	for projectile: SporeProjectile in _projectiles(fixture):
		if is_instance_valid(projectile.target):
			result.append(projectile.target.get_instance_id())
	return result


func _expect_targets(fixture: Fixture, expected: Array[BasicEnemy], context: String) -> void:
	var expected_ids: Array[int] = []
	for enemy: BasicEnemy in expected:
		expected_ids.append(enemy.get_instance_id())
	var actual: Array[int] = _targets(fixture)
	_check(actual == expected_ids, context + " selects distinct targets in nearest order")
	var unique: Dictionary[int, bool] = {}
	for target_id: int in actual:
		unique[target_id] = true
	_check(unique.size() == actual.size(), context + " never repeats a target within one round")
	if not expected_ids.is_empty():
		_check(fixture.primary_ids.back() == expected_ids[0], context + " legacy target is the primary")


func _expect_no_commit(fixture: Fixture, context: String) -> void:
	_check(fixture.organ.nutrition == fixture.initial_stock and fixture.spent == 0,
		context + " does not charge nutrition")
	_check(fixture.events.is_empty() and fixture.primary_ids.is_empty()
		and fixture.timeline.is_empty(), context + " emits no combat or inventory events")
	_check(fixture.weapon.get_shot_statistics() == {"rounds": 0, "projectiles": 0,
		"nutrition_spent": 0, "last_shot_id": ""}, context + " retains zero statistics")
	_check(fixture.projectiles.get_child_count() == 0, context + " leaves no owned projectile drafts")


func _dispose(fixture: Fixture) -> void:
	PreparationProjectile.hook = Callable()
	if current_scene == fixture.world:
		current_scene = null
	fixture.world.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.world), "Weapon fixture is fully freed")


func _test_real_modes() -> void:
	var expected_presets: Dictionary = {
		"normal": [12, 0.8, 178.0, 1, 1, 0.0, 0],
		"armor_piercing": [24, 1.8, 178.0, 2, 1, 0.0, 1],
		"scatter": [6, 0.9, 145.0, 1, 3, 60.0, 2],
	}
	for mode: String in PRESET_PATHS:
		var profile: WeaponProfile = _preset(mode)
		_check([profile.damage, profile.fire_interval, profile.attack_range,
			profile.nutrition_cost, profile.max_targets, profile.spread_angle_degrees,
			int(profile.damage_type)] == expected_presets[mode], mode + " has frozen preset parameters")
		var fixture: Fixture = _new_fixture(profile)
		var first: BasicEnemy = _enemy(fixture, Vector2(60, 0))
		var second: BasicEnemy = _enemy(fixture, Vector2(95, 0))
		var third: BasicEnemy = _enemy(fixture, Vector2(120, 12))
		_fire(fixture)
		var selected: Array[BasicEnemy] = [first]
		if mode == "scatter":
			selected.append(second)
			selected.append(third)
		_expect_targets(fixture, selected, mode)
		_check(first.health == 200 and second.health == 200 and third.health == 200,
			mode + " causes no early damage at launch")
		_check(fixture.events.size() == 1 and fixture.spent == profile.nutrition_cost
			and fixture.projectile_total == selected.size(), mode + " pays once for its whole round")
		await _hit_all(fixture)
		var expected_damage: int = 24 if mode == "armor_piercing" else maxi(1, profile.damage - 4)
		for enemy: BasicEnemy in selected:
			_check(enemy.health == 200 - expected_damage and enemy.health_bar.value == enemy.health,
				mode + " real impact applies armor rule and updates HP display")
		if mode != "scatter":
			_check(second.health == 200 and third.health == 200, mode + " produces exactly one impact")
		_fire(fixture)
		await _hit_all(fixture)
		_check(fixture.events.size() == 2 and fixture.primary_ids.size() == 2
			and fixture.organ.nutrition + fixture.spent == 6, mode + " consecutive rounds conserve actual event cost")
		await _dispose(fixture)
	cases.append("three_real_modes_hp_armor_cost_and_single_legacy_event")


func _test_scatter_target_counts() -> void:
	for maximum: int in [1, 2, 3]:
		for available: int in [1, 2, 3, 4]:
			var profile: WeaponProfile = _preset("scatter")
			profile.max_targets = maximum
			var fixture: Fixture = _new_fixture(profile)
			var enemies: Array[BasicEnemy] = []
			for index: int in range(available):
				enemies.append(_enemy(fixture, Vector2(50 + 20 * index, 0), 20))
			_fire(fixture)
			var expected: Array[BasicEnemy] = []
			for index: int in range(mini(maximum, available)):
				expected.append(enemies[index])
			_expect_targets(fixture, expected, "Scatter %d/%d" % [maximum, available])
			_check(fixture.spent == 1 and fixture.primary_ids.size() == 1,
				"Scatter with one, two or three pellets still costs one round")
			await _hit_all(fixture)
			for index: int in range(enemies.size()):
				_check(enemies[index].health == (199 if index < expected.size() else 200),
					"Scatter high armor floors actual selected damage at one")
			await _dispose(fixture)
	cases.append("scatter_one_two_three_targets_distinct_and_maximum_damage_floor")


func _test_ground_range_and_cone() -> void:
	for mode: String in PRESET_PATHS:
		var profile: WeaponProfile = _preset(mode)
		var fixture: Fixture = _new_fixture(profile, 6, Vector2(400, 400), Vector2(0, -350))
		var boundary: BasicEnemy = _enemy(fixture, Vector2(profile.attack_range, 0))
		boundary.sprite.position = Vector2(0, -600)
		_fire(fixture)
		_expect_targets(fixture, [boundary], mode + " inclusive ground range")
		fixture.weapon.set_range_visible(true)
		var outline: Line2D = fixture.weapon.get_node("RangeOutline") as Line2D
		_check(outline.visible and outline.global_position.distance_to(fixture.organ.global_position)
			<= POSITION_EPSILON, mode + " displayed range is centered on the ground owner")
		for point: Vector2 in outline.points:
			_check(absf(outline.to_global(point).distance_to(fixture.organ.global_position)
				- profile.attack_range) <= POSITION_EPSILON, mode + " displayed radius matches targeting radius")
		await _hit_all(fixture)
		await _dispose(fixture)
		fixture = _new_fixture(profile, 6, Vector2(400, 400), Vector2(0, -350))
		var outside: BasicEnemy = _enemy(fixture, Vector2(0, -profile.attack_range - 0.001))
		_fire(fixture)
		_expect_no_commit(fixture, mode + " ground range plus 0.001")
		_check(outside.health == 200, mode + " high muzzle cannot extend ground range")
		await _dispose(fixture)
	for sign_value: float in [-1.0, 1.0]:
		var fixture: Fixture = _new_fixture(_preset("scatter"), 6,
			Vector2(400, 400), Vector2(0, -350))
		var primary: BasicEnemy = _enemy(fixture, Vector2(50, 0))
		var boundary: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(30.0 * sign_value)) * 90.0)
		var inside: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(-29.999 * sign_value)) * 110.0)
		var outside: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(30.001 * sign_value)) * 80.0)
		boundary.sprite.position.y = 500.0
		inside.sprite.position.y = -500.0
		_fire(fixture)
		_expect_targets(fixture, [primary, boundary, inside], "Inclusive signed half-cone 30 degrees")
		await _hit_all(fixture)
		_check(outside.health == 200, "Angle outside by 0.001 degrees is excluded despite being closer")
		await _dispose(fixture)
	cases.append("ground_range_exact_boundary_high_muzzle_sprite_height_and_cone_precision")


func _test_wraparound_and_coincident_primary() -> void:
	for sign_value: float in [-1.0, 1.0]:
		var fixture: Fixture = _new_fixture(_preset("scatter"))
		var primary: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(179.0 * sign_value)) * 50.0)
		var wrapped: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(-179.0 * sign_value)) * 80.0)
		var boundary: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(149.0 * sign_value)) * 110.0)
		var outside: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(148.999 * sign_value)) * 70.0)
		_fire(fixture)
		_expect_targets(fixture, [primary, wrapped, boundary], "Wrapped signed PI cone")
		await _hit_all(fixture)
		_check(outside.health == 200, "Wraparound keeps the full 60 degree cone bounded")
		await _dispose(fixture)
	var fixture: Fixture = _new_fixture(_preset("scatter"))
	var coincident: BasicEnemy = _enemy(fixture, Vector2.ZERO)
	var right: BasicEnemy = _enemy(fixture, Vector2(40, 0))
	var boundary: BasicEnemy = _enemy(fixture, Vector2.from_angle(deg_to_rad(30.0)) * 70.0)
	var vertical: BasicEnemy = _enemy(fixture, Vector2(0, 50))
	_fire(fixture)
	_expect_targets(fixture, [coincident, right, boundary], "Coincident primary uses Vector2.RIGHT")
	await _hit_all(fixture)
	_check(vertical.health == 200, "Coincident direction is independent of muzzle displacement")
	await _dispose(fixture)
	cases.append("pi_wraparound_and_coincident_primary_right_direction")


func _test_stable_nearest_order() -> void:
	for mode: String in PRESET_PATHS:
		var fixture: Fixture = _new_fixture(_preset(mode))
		var first: BasicEnemy = _enemy(fixture, Vector2(70, 0))
		var second: BasicEnemy = _enemy(fixture, Vector2(70, 0))
		var third: BasicEnemy = _enemy(fixture, Vector2(90, 0))
		fixture.enemies.move_child(second, 0)
		_check(first.get_instance_id() < second.get_instance_id(), "Equal-distance fixture IDs are ordered")
		_fire(fixture)
		var expected: Array[BasicEnemy] = [first]
		if mode == "scatter":
			expected.append(second)
			expected.append(third)
		_expect_targets(fixture, expected, mode + " distance then instance ID tie-break")
		await _hit_all(fixture)
		await _dispose(fixture)
	cases.append("stable_nearest_and_instance_id_order_independent_of_tree_order")


func _test_no_commit_conditions() -> void:
	for mode: String in PRESET_PATHS:
		var profile: WeaponProfile = _preset(mode)
		var fixture: Fixture = _new_fixture(profile)
		_check(bool(fixture.weapon.get_firing_state().get("active", false)),
			mode + " is active without targets")
		_fire(fixture)
		_expect_no_commit(fixture, mode + " missing target")
		await _dispose(fixture)
		fixture = _new_fixture(profile, profile.nutrition_cost - 1)
		var enemy: BasicEnemy = _enemy(fixture, Vector2(60, 0))
		_check(bool(fixture.weapon.get_firing_state().get("active", false)),
			mode + " activity does not depend on sufficient stock")
		_fire(fixture)
		_expect_no_commit(fixture, mode + " insufficient whole-round nutrition")
		_check(enemy.health == 200, mode + " insufficient stock cannot damage target")
		await _dispose(fixture)
	for reason: String in ["disabled", "work_paused", "weapon_process_disabled", "owner_process_disabled", "detached"]:
		var fixture: Fixture = _new_fixture(_preset("scatter"))
		_enemy(fixture, Vector2(60, 0))
		match reason:
			"disabled": fixture.weapon.set_firing_enabled(false)
			"work_paused": fixture.organ.set_work_enabled(false)
			"weapon_process_disabled": fixture.weapon.process_mode = Node.PROCESS_MODE_DISABLED
			"owner_process_disabled": fixture.organ.process_mode = Node.PROCESS_MODE_DISABLED
			"detached": fixture.host.remove_child(fixture.weapon)
		_check(not bool(fixture.weapon.get_firing_state().get("active", true)), reason + " is inactive")
		fixture.weapon._on_fire_timer_timeout()
		_expect_no_commit(fixture, reason)
		if reason == "detached":
			fixture.weapon.free()
		await _dispose(fixture)
	cases.append("no_target_insufficient_disabled_paused_unprocessable_and_detached_no_charge")


func _pack_test_scene(prototype: Node) -> PackedScene:
	for child: Node in prototype.get_children():
		child.owner = prototype
	var packed := PackedScene.new()
	_check(packed.pack(prototype) == OK, "Adversarial test scene packs in memory")
	prototype.free()
	return packed


func _preparation_scene(reject_at: int = 0) -> PackedScene:
	var prototype: Node = PROJECTILE_SCENE.instantiate()
	prototype.set_script(PreparationProjectile)
	var packed: PackedScene = _pack_test_scene(prototype)
	PreparationProjectile.attempts = 0
	PreparationProjectile.reject_at = reject_at
	PreparationProjectile.hook = Callable()
	PreparationProjectile.drafts.clear()
	return packed


func _test_preparation_failures() -> void:
	for failure_mode: String in ["missing", "wrong_type", "launch_rejected", "second_launch_rejected", "container_lost"]:
		var fixture: Fixture = _new_fixture(_preset("scatter"))
		var enemies: Array[BasicEnemy] = [
			_enemy(fixture, Vector2(50, 0)), _enemy(fixture, Vector2(80, 0)),
			_enemy(fixture, Vector2(110, 0)),
		]
		match failure_mode:
			"missing": fixture.weapon.projectile_scene = null
			"wrong_type": fixture.weapon.projectile_scene = _pack_test_scene(Node2D.new())
			"launch_rejected": fixture.weapon.projectile_scene = _preparation_scene(1)
			"second_launch_rejected": fixture.weapon.projectile_scene = _preparation_scene(2)
			"container_lost":
				fixture.weapon.projectile_scene = _preparation_scene()
				PreparationProjectile.hook = func(_draft: SporeProjectile, ordinal: int) -> void:
					if ordinal == 1:
						fixture.weapon.projectile_container = null
		_fire(fixture)
		_expect_no_commit(fixture, failure_mode)
		for enemy: BasicEnemy in enemies:
			_check(enemy.health == 200, failure_mode + " rolled back every prepared impact")
		if failure_mode == "second_launch_rejected":
			_check(PreparationProjectile.attempts == 2, "Partial failure really follows one successful preparation")
		await process_frame
		await process_frame
		if failure_mode in ["launch_rejected", "second_launch_rejected", "container_lost"]:
			for draft: WeakRef in PreparationProjectile.drafts:
				_check(draft.get_ref() == null, failure_mode + " frees all instantiated drafts")
		await _dispose(fixture)
	cases.append("missing_wrong_scene_launch_and_partial_preparation_rollback")


func _test_preparation_reentry() -> void:
	var fixture: Fixture = _new_fixture(_preset("scatter"))
	var primary: BasicEnemy = _enemy(fixture, Vector2(50, 0))
	var second: BasicEnemy = _enemy(fixture, Vector2(80, 0))
	var third: BasicEnemy = _enemy(fixture, Vector2(110, 0))
	fixture.weapon.projectile_scene = _preparation_scene()
	fixture.projectiles.child_entered_tree.connect(func(child: Node) -> void:
		if child is SporeProjectile:
			var projectile: SporeProjectile = child as SporeProjectile
			projectile.visibility_changed.connect(func() -> void:
				if projectile.visible:
					_check(fixture.events.size() == 1 and fixture.spent == 1
						and fixture.events[0]["shot_id"] == projectile.get_meta("shot_id", ""),
						"Projectile visibility activation follows its authoritative committed cost receipt")
			)
	)
	PreparationProjectile.hook = func(_draft: SporeProjectile, ordinal: int) -> void:
		_check(bool(fixture.weapon.get_firing_state().get("committing", false)),
			"Preparation callback observes the transaction guard")
		_check(fixture.organ.nutrition == 6 and fixture.events.is_empty(),
			"Every projectile prepares before any debit or combat event")
		if ordinal == 1:
			fixture.weapon._on_fire_timer_timeout()
		for child: Node in fixture.projectiles.get_children():
			if child is SporeProjectile:
				(child as SporeProjectile)._physics_process(10.0)
		_check(primary.health == 200 and second.health == 200 and third.health == 200,
			"Owned preparation drafts stay inert before commit")
	_fire(fixture)
	_check(PreparationProjectile.attempts == 3 and fixture.events.size() == 1,
		"Preparation timer reentry cannot duplicate any part of a round")
	_expect_targets(fixture, [primary, second, third], "Reentrant preparation")
	await _hit_all(fixture)
	_check(primary.health == 198 and second.health == 198 and third.health == 198,
		"Preparation transaction releases all actual impacts only after commit")
	await _dispose(fixture)
	cases.append("inert_preparation_and_reentrant_scheduler_guard")


func _test_commit_callbacks_and_snapshot() -> void:
	var fixture: Fixture = _new_fixture(_preset("scatter"))
	var primary: BasicEnemy = _enemy(fixture, Vector2(50, 0))
	var second: BasicEnemy = _enemy(fixture, Vector2(80, 0))
	var third: BasicEnemy = _enemy(fixture, Vector2(110, 0))
	var next_profile: WeaponProfile = _preset("armor_piercing")
	fixture.weapon.volley_committed.connect(func(_id: String, spent: int, count: int) -> void:
		_check(spent == 1 and count == 3 and fixture.organ.nutrition == 5,
			"Scatter event observes its original complete debit")
		_check(fixture.projectiles.get_child_count() == 3,
			"All scatter projectiles are owned before the first external commit callback")
		fixture.weapon._on_fire_timer_timeout()
	, CONNECT_ONE_SHOT)
	fixture.organ.inventory_changed.connect(func(_stored: int, _incoming: int, _capacity: int) -> void:
		_check(fixture.events.size() == 1 and fixture.spent == 1,
			"Inventory observer already has the authoritative cost event")
		fixture.weapon._on_fire_timer_timeout()
		_check(fixture.weapon.configure_profile(next_profile), "Inventory callback can explicitly configure the next round")
		fixture.weapon.set_firing_enabled(false)
		fixture.weapon.set_firing_enabled(true)
		fixture.weapon._on_fire_timer_timeout()
	, CONNECT_ONE_SHOT)
	_fire(fixture)
	(fixture.weapon.get_node("FireTimer") as Timer).stop()
	_check(fixture.events.size() == 1 and fixture.primary_ids.size() == 1 and fixture.spent == 1,
		"Reentrant event/configuration/state callbacks cannot create a second round")
	_check(fixture.timeline.size() == 3 and fixture.timeline[0] == "volley"
		and fixture.timeline.count("inventory") == 1 and fixture.timeline.count("legacy") == 1,
		"Authoritative commit event precedes inventory and legacy observers")
	_expect_targets(fixture, [primary, second, third], "Committed scatter snapshot")
	next_profile.damage = 99
	next_profile.nutrition_cost = 5
	await _hit_all(fixture)
	_check(primary.health == 198 and second.health == 198 and third.health == 198,
		"Configuration and source edits cannot rewrite committed scatter requests")
	_fire(fixture)
	_expect_targets(fixture, [primary], "Following AP snapshot")
	_check(fixture.spent == 3 and fixture.organ.nutrition == 3 and fixture.events.size() == 2,
		"Following AP round has a new ID and its own actual two-unit cost")
	await _hit_all(fixture)
	_check(primary.health == 174 and second.health == 198 and third.health == 198,
		"Following AP impact uses the copied 24 damage and ignores armor")
	await _dispose(fixture)
	cases.append("authoritative_event_order_atomic_callbacks_global_ids_and_immutable_shots")


func _test_consumed_projectiles_do_not_refund() -> void:
	for mode: String in PRESET_PATHS:
		for outcome: String in ["target_dead", "lifetime_expired"]:
			var fixture: Fixture = _new_fixture(_preset(mode))
			var enemy: BasicEnemy = _enemy(fixture, Vector2(90, 0))
			_fire(fixture)
			var spent: int = fixture.spent
			var statistics: Dictionary = fixture.weapon.get_shot_statistics()
			var projectiles: Array[SporeProjectile] = _projectiles(fixture)
			_check(projectiles.size() == 1, "Dissipation fixture owns one real paid projectile")
			if outcome == "target_dead":
				enemy.take_damage(999)
				for projectile: SporeProjectile in projectiles:
					projectile._physics_process(10.0)
					projectile._physics_process(10.0)
			else:
				for projectile: SporeProjectile in projectiles:
					projectile.speed = 0.0
					(projectile.get_node("LifetimeTimer") as Timer).start(0.01)
				for _frame: int in range(4):
					await physics_frame
				_check(enemy.health == 200, "Real lifetime timeout does not apply damage")
			await process_frame
			await process_frame
			_check(fixture.projectiles.get_child_count() == 0, mode + " " + outcome + " dissipates real projectile")
			_check(fixture.organ.nutrition + spent == fixture.initial_stock
				and fixture.spent == spent and fixture.events.size() == 1
				and fixture.weapon.get_shot_statistics() == statistics,
				mode + " " + outcome + " neither refunds nor duplicates committed cost")
			await _dispose(fixture)
	cases.append("paid_target_loss_and_real_lifetime_timeout_never_refund")


func _check_clock(weapon: SporeWeapon, enabled: bool, active: bool, context: String) -> void:
	var timer: Timer = weapon.get_node("FireTimer") as Timer
	var profile: WeaponProfile = weapon.get_weapon_profile()
	var state: Dictionary = weapon.get_firing_state()
	_check(state.has_all(["enabled", "active", "committing", "cooldown_remaining", "fire_interval"]),
		context + " query includes all frozen clock fields")
	_check(bool(state.get("enabled", not enabled)) == enabled
		and bool(state.get("active", not active)) == active
		and not bool(state.get("committing", true)), context + " reports independent enable and activity")
	_check(absf(float(state.get("fire_interval", -1.0)) - profile.fire_interval) <= POSITION_EPSILON
		and absf(timer.wait_time - profile.fire_interval) <= POSITION_EPSILON
		and absf(float(state.get("cooldown_remaining", -1.0)) - timer.time_left) <= POSITION_EPSILON,
		context + " profile, timer and clock query agree")


func _test_configuration_cooldown_and_enable() -> void:
	var fixture: Fixture = _new_fixture(_preset("normal"), 3)
	var weapon: SporeWeapon = fixture.weapon
	var timer: Timer = weapon.get_node("FireTimer") as Timer
	var stock: int = fixture.organ.nutrition
	for mode: String in PRESET_PATHS:
		var source: WeaponProfile = _preset(mode)
		_check(weapon.configure_profile(source), mode + " explicit test reconfiguration succeeds")
		_check(timer.is_stopped() and fixture.organ.nutrition == stock,
			mode + " stopped fixture stays stopped and configuration adds no stock")
		_check(weapon.damage == source.damage and weapon.attack_range == source.attack_range,
			mode + " aliases reflect the current profile")
		_check_clock(weapon, true, true, mode + " stopped fixture")
		var query: WeaponProfile = weapon.get_weapon_profile()
		_check(query != source and query != weapon.get_weapon_profile(), "Profile queries return independent resources")
		query.damage = 99
		query.nutrition_cost = 6
		source.damage = 88
		_check(weapon.damage != 99 and weapon.damage != 88, "Getter and caller mutations cannot edit live profile")
	var before: Dictionary = _values(weapon.get_weapon_profile())
	var invalid: WeaponProfile = _preset("scatter")
	invalid.max_targets = 4
	_check(not weapon.configure_profile(invalid) and not weapon.configure_profile(null),
		"Invalid and null reconfiguration fail atomically")
	_check(_values(weapon.get_weapon_profile()) == before and timer.is_stopped()
		and fixture.organ.nutrition == stock, "Failed configuration preserves profile, timer and inventory")
	_check(weapon.configure_profile(_preset("normal")), "Clock fixture selects normal explicitly")
	timer.start()
	for _frame: int in range(4):
		await physics_frame
	var elapsed_remaining: float = timer.time_left
	_check(elapsed_remaining > 0.0 and elapsed_remaining < 0.8, "Real clock advances without targets")
	weapon.set_firing_enabled(true)
	_check(absf(timer.time_left - elapsed_remaining) <= POSITION_EPSILON,
		"Idempotent enable does not restart elapsed cooldown")
	_check(weapon.configure_profile(_preset("armor_piercing")), "Running clock accepts AP profile")
	_check(absf(timer.time_left - 1.8) <= POSITION_EPSILON, "Running configuration restarts the full new interval")
	_check_clock(weapon, true, true, "Running AP")
	weapon.set_firing_enabled(false)
	_check(timer.is_stopped(), "Independent disable stops the scheduler")
	_check(weapon.configure_profile(_preset("scatter")) and timer.is_stopped(),
		"Disabled configuration cannot restart the scheduler")
	_check_clock(weapon, false, false, "Disabled scatter")
	weapon.set_firing_enabled(true)
	_check(absf(timer.time_left - 0.9) <= POSITION_EPSILON, "Reenable starts a full current interval")
	var work_events: Array[bool] = []
	fixture.organ.work_state_changed.connect(func(enabled: bool) -> void: work_events.append(enabled))
	fixture.organ.set_work_enabled(false)
	fixture.organ.set_work_enabled(false)
	_check(timer.is_stopped() and work_events == [false], "Idempotent work pause stops firing and emits once")
	_check(weapon.configure_profile(_preset("normal")) and timer.is_stopped(),
		"Work-paused configuration stays stopped")
	_check_clock(weapon, true, false, "Work-paused normal")
	fixture.organ.set_work_enabled(true)
	_check(absf(timer.time_left - 0.8) <= POSITION_EPSILON, "Work resume starts a full current interval")
	fixture.organ.set_work_enabled(false)
	weapon.set_firing_enabled(false)
	fixture.organ.set_work_enabled(true)
	_check(timer.is_stopped() and not weapon.is_firing_enabled(),
		"Work resume preserves independent weapon disable")
	weapon.set_firing_enabled(true)
	timer.wait_time = 0.42
	_check(absf(weapon.get_weapon_profile().fire_interval - 0.42) <= POSITION_EPSILON,
		"Legacy Timer.wait_time edits are reflected in the current profile")
	_check_clock(weapon, true, true, "Legacy timer edit")
	_check(fixture.organ.nutrition == stock and fixture.events.is_empty()
		and fixture.primary_ids.is_empty(), "Configuration, enable and cooldown changes never refill inventory or commit idle shots")
	await _dispose(fixture)
	cases.append("atomic_copies_cooldown_queries_legacy_timer_enable_work_pause_and_no_stock_creation")
