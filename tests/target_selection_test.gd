extends SceneTree
## 共享伤害账本、威胁选敌与整轮发射事务；伤害仍由真实弹丸落地结算。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/spore_projectile.tscn")
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
	var core: MotherCore
	var tracker: CombatTargetingSystem
	var hosts: Array[Node2D] = []
	var organs: Array[AttackOrgan] = []
	var weapons: Array[SporeWeapon] = []
	var initial_stocks: Array[int] = []
	var events: Array[Dictionary] = []
	var legacy: Array[Dictionary] = []
	var timeline: Array[String] = []
	var extra_ids := PackedStringArray()

class RejectingTracker:
	extends CombatTargetingSystem
	var preparation_attempts: int = 0
	var reject_prepare_at: int = 0
	var reject_commit: bool = false
	var commit_attempts: int = 0
	var successful_commits: int = 0

	func prepare_commitment(target: BasicEnemy, request: Dictionary, owner: Node) -> String:
		preparation_attempts += 1
		if preparation_attempts == reject_prepare_at:
			return ""
		return super.prepare_commitment(target, request, owner)

	func commit_batch(ids: PackedStringArray) -> bool:
		commit_attempts += 1
		if reject_commit:
			return false
		var accepted := super.commit_batch(ids)
		if accepted:
			successful_commits += 1
		return accepted

class PreparationProjectile:
	extends SporeProjectile
	static var created: int = 0
	static var launch_attempts: int = 0
	static var bind_attempts: int = 0
	static var reject_launch_at: int = 0
	static var reject_bind_at: int = 0
	static var on_creation: Callable = Callable()
	static var on_launch: Callable = Callable()
	static var drafts: Array[WeakRef] = []

	func _init() -> void:
		created += 1
		drafts.append(weakref(self))
		if on_creation.is_valid():
			on_creation.call(created)

	func launch_request(enemy: BasicEnemy, request: Dictionary) -> bool:
		launch_attempts += 1
		var ordinal := launch_attempts
		if ordinal == reject_launch_at:
			return false
		var accepted := super.launch_request(enemy, request)
		if on_launch.is_valid():
			on_launch.call(self, ordinal)
		return accepted

	func bind_damage_commitment(system: CombatTargetingSystem, commitment_id: String) -> bool:
		bind_attempts += 1
		if bind_attempts == reject_bind_at:
			return false
		return super.bind_damage_commitment(system, commitment_id)

var checks: int = 0
var failures: Array[String] = []
var cases: Array[String] = []
var _seen_shot_ids: Dictionary[String, bool] = {}
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_threat_queries_and_priority()
	await _test_core_distance_ties_and_fallback()
	await _test_ground_range_and_liveness()
	await _test_priority_scatter_and_cone()
	await _test_wraparound_and_coincident_primary()
	await _test_shared_coverage_skip_and_wait()
	await _test_partial_demand_and_current_armor()
	await _test_whole_round_prices()
	await _test_reserve_before_callbacks_and_self_exclusion()
	await _test_other_weapon_coverage_aborts_only_own_round()
	await _test_partial_failures_and_silent_debit()
	await _test_epoch_reset_during_preparation()
	await _test_configuration_and_target_revalidation()
	await _test_committed_event_and_owner_lifetime()
	await _test_missing_and_invalid_trackers()
	_check(root.get_child_count() == _initial_root_children, "All target-selection fixtures leave the tree")
	print("TARGET_SELECTION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases,
		"unique_committed_rounds": _seen_shot_ids.size(),
		"damage": "real_projectile_and_enemy_hp", "ledger": "shared_prepared_and_committed_damage",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _preset(mode: String) -> WeaponProfile:
	var source := load(PRESET_PATHS[mode]) as WeaponProfile
	_check(source != null and source.is_valid(), mode + " preset is valid")
	return source.copy_for_instance() if source != null else WeaponProfile.new()


func _new_fixture(modes: Array[String], with_core: bool = false, tracked: bool = true,
		tracker_override: CombatTargetingSystem = null, stock: int = 6) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.world.name = "TargetSelectionFixture"
	root.add_child(fixture.world)
	current_scene = fixture.world
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.projectiles)
	if tracked:
		fixture.tracker = tracker_override if tracker_override != null else CombatTargetingSystem.new()
		fixture.world.add_child(fixture.tracker)
	if with_core:
		fixture.core = CORE_SCENE.instantiate() as MotherCore
		fixture.core.initial_nutrition = 0
		fixture.world.add_child(fixture.core)
		fixture.core.global_position = Vector2(540, 400)
	for index: int in range(modes.size()):
		var host := Node2D.new()
		host.position = Vector2(400, 400)
		fixture.world.add_child(host)
		fixture.hosts.append(host)
		var organ := ORGAN_SCENE.instantiate() as AttackOrgan
		organ.initial_nutrition = stock
		host.add_child(organ)
		fixture.organs.append(organ)
		fixture.initial_stocks.append(organ.nutrition)
		var weapon := WEAPON_SCENE.instantiate() as SporeWeapon
		weapon.inventory_owner = organ
		weapon.enemy_container = fixture.enemies
		weapon.projectile_container = fixture.projectiles
		weapon.targeting_system = fixture.tracker
		weapon.targeting_required = tracked
		weapon.position = Vector2(0, -28)
		var timer := weapon.get_node("FireTimer") as Timer
		timer.autostart = false
		_check(weapon.configure_profile(_preset(modes[index])), "Explicit weapon fixture configuration succeeds")
		host.add_child(weapon)
		timer.stop()
		fixture.weapons.append(weapon)
		weapon.volley_committed.connect(_capture_volley.bind(index, fixture))
		weapon.shot_fired.connect(_capture_legacy.bind(index, fixture))
		organ.inventory_changed.connect(_capture_inventory.bind(index, fixture))
	return fixture


func _capture_volley(shot_id: String, spent: int, count: int, index: int, fixture: Fixture) -> void:
	_check(not shot_id.is_empty() and not _seen_shot_ids.has(shot_id), "Every round has a new nonempty shot ID")
	_seen_shot_ids[shot_id] = true
	fixture.events.append({"shot_id": shot_id, "spent": spent, "count": count, "weapon": index})
	fixture.timeline.append("volley:%d" % index)
	var totals := _totals(fixture, index)
	_check(fixture.organs[index].nutrition + int(totals["spent"]) == fixture.initial_stocks[index],
		"Authoritative event observes the complete debit")
	_check(fixture.weapons[index].get_shot_statistics() == {"rounds": totals["rounds"],
		"projectiles": totals["projectiles"], "nutrition_spent": totals["spent"], "last_shot_id": shot_id},
		"Whole-round counters and cost precede public callbacks")
	var actual: int = 0
	for projectile: SporeProjectile in _projectiles(fixture):
		if projectile.get_meta("shot_id", "") != shot_id:
			continue
		actual += 1
		_check(projectile.process_mode == Node.PROCESS_MODE_DISABLED and not projectile.visible,
			"Authoritative event precedes every activation")
		if is_instance_valid(fixture.tracker):
			var commitment_id := projectile.get_damage_commitment_id()
			var record := fixture.tracker.get_commitment(commitment_id)
			_check(fixture.tracker.is_commitment_committed(commitment_id)
				and int(record.get("target_id", 0)) == projectile.target.get_instance_id()
				and int(record.get("projectile_id", 0)) == projectile.get_instance_id(),
				"Every owned projectile has its committed target and projectile identity before the event")
	_check(actual == count, "Event projectile count describes the complete owned round")


func _capture_legacy(target: BasicEnemy, index: int, fixture: Fixture) -> void:
	fixture.legacy.append({"weapon": index, "target_id": target.get_instance_id() if is_instance_valid(target) else 0})
	fixture.timeline.append("legacy:%d" % index)
	var legacy_count: int = 0
	for record: Dictionary in fixture.legacy:
		if int(record["weapon"]) == index:
			legacy_count += 1
	_check(legacy_count == int(_totals(fixture, index)["rounds"]), "Legacy signal remains exactly once per round")


func _capture_inventory(_stored: int, _incoming: int, _capacity: int, index: int, fixture: Fixture) -> void:
	fixture.timeline.append("inventory:%d" % index)
	_check(int(_totals(fixture, index)["rounds"]) > 0,
		"Inventory notification follows the authoritative committed round")


func _totals(fixture: Fixture, index: int) -> Dictionary:
	var result := {"rounds": 0, "projectiles": 0, "spent": 0}
	for event: Dictionary in fixture.events:
		if int(event["weapon"]) == index:
			result["rounds"] += 1
			result["projectiles"] += int(event["count"])
			result["spent"] += int(event["spent"])
	return result


func _enemy(fixture: Fixture, offset: Vector2, health: int = 200, armor_value: int = 0,
		with_core: bool = true) -> BasicEnemy:
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = health
	enemy.armor = armor_value
	enemy.move_speed = 0.0
	enemy.mother_core = fixture.core if with_core else null
	fixture.enemies.add_child(enemy)
	enemy.global_position = fixture.organs[0].global_position + offset
	enemy.set_physics_process(false)
	enemy.attack_timer.stop()
	return enemy


func _projectiles(fixture: Fixture) -> Array[SporeProjectile]:
	var result: Array[SporeProjectile] = []
	for child: Node in fixture.projectiles.get_children():
		if child is SporeProjectile and not child.is_queued_for_deletion():
			result.append(child as SporeProjectile)
	return result


func _fire(fixture: Fixture, index: int = 0) -> void:
	(fixture.weapons[index].get_node("FireTimer") as Timer).stop()
	fixture.weapons[index]._on_fire_timer_timeout()
	for projectile: SporeProjectile in _projectiles(fixture):
		projectile.set_physics_process(false)
		var lifetime := projectile.get_node_or_null("LifetimeTimer") as Timer
		if lifetime != null:
			lifetime.stop()


func _hit_all(fixture: Fixture) -> void:
	for projectile: SporeProjectile in _projectiles(fixture):
		projectile._physics_process(10.0)
		projectile._physics_process(10.0)
	await process_frame
	await process_frame
	_check(fixture.projectiles.get_child_count() == 0, "Real impacts remove their projectiles exactly once")


func _expect_targets(fixture: Fixture, targets: Array[BasicEnemy], context: String) -> void:
	var actual: Array[int] = []
	var expected: Array[int] = []
	var unique: Dictionary[int, bool] = {}
	for projectile: SporeProjectile in _projectiles(fixture):
		actual.append(projectile.target.get_instance_id())
		unique[projectile.target.get_instance_id()] = true
	for target: BasicEnemy in targets:
		expected.append(target.get_instance_id())
	_check(actual == expected, context + " launches the selected targets in priority order")
	_check(actual.size() == unique.size(), context + " never repeats a target within the round")


func _expect_selection(fixture: Fixture, expected: Array[BasicEnemy], context: String) -> void:
	var weapon := fixture.weapons[0]
	_check(weapon._select_targets(weapon.get_weapon_profile(), fixture.organs[0].global_position,
		fixture.enemies) == expected, context)


func _expect_no_round(fixture: Fixture, context: String, index: int = 0) -> void:
	_check(fixture.organs[index].nutrition == fixture.initial_stocks[index]
		and _totals(fixture, index) == {"rounds": 0, "projectiles": 0, "spent": 0}, context + " does not spend or emit")
	_check(fixture.weapons[index].get_shot_statistics() == {"rounds": 0, "projectiles": 0,
		"nutrition_spent": 0, "last_shot_id": ""}, context + " preserves zero round statistics")
	_check(not fixture.timeline.has("legacy:%d" % index) and not fixture.timeline.has("inventory:%d" % index),
		context + " emits no legacy or inventory notification")


func _reserve_foreign(fixture: Fixture, target: BasicEnemy, damage_value: int = 12) -> String:
	var commitment_id := fixture.tracker.prepare_commitment(target,
		{"raw_damage": damage_value, "damage_type": int(WeaponProfile.DamageType.NORMAL)}, fixture.world)
	_check(not commitment_id.is_empty(), "Independent fixture reservation is admitted")
	fixture.extra_ids.append(commitment_id)
	return commitment_id


func _pack_scene(prototype: Node) -> PackedScene:
	for child: Node in prototype.get_children():
		child.owner = prototype
	var packed := PackedScene.new()
	_check(packed.pack(prototype) == OK, "Adversarial projectile scene packs in memory")
	prototype.free()
	return packed


func _preparation_scene() -> PackedScene:
	PreparationProjectile.on_creation = Callable()
	PreparationProjectile.on_launch = Callable()
	var prototype: Node = PROJECTILE_SCENE.instantiate()
	prototype.set_script(PreparationProjectile)
	var packed := _pack_scene(prototype)
	PreparationProjectile.created = 0
	PreparationProjectile.launch_attempts = 0
	PreparationProjectile.bind_attempts = 0
	PreparationProjectile.reject_launch_at = 0
	PreparationProjectile.reject_bind_at = 0
	PreparationProjectile.drafts.clear()
	return packed


func _dispose(fixture: Fixture) -> void:
	PreparationProjectile.on_creation = Callable()
	PreparationProjectile.on_launch = Callable()
	if current_scene == fixture.world:
		current_scene = null
	fixture.world.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.world), "Fixture is fully freed")


func _test_threat_queries_and_priority() -> void:
	var fixture := _new_fixture(["normal"], true)
	var nearest := _enemy(fixture, Vector2(20, 0))
	var approaching := _enemy(fixture, Vector2(100, 0))
	var stopped_at_core := _enemy(fixture, Vector2(137, 0))
	var attacking := _enemy(fixture, Vector2(120, 0))
	attacking.attack_timer.start()
	var original_health := fixture.core.health
	for _iteration: int in range(8):
		_check(attacking.is_attacking_core() and not stopped_at_core.is_attacking_core(),
			"Only an actually running in-contact AttackTimer gives attack priority")
		_expect_selection(fixture, [attacking], "A core attacker wins before closer core and weapon distances")
	_check(fixture.core.health == original_health and attacking.health == 200
		and not attacking.attack_timer.is_stopped() and stopped_at_core.attack_timer.is_stopped(),
		"Threat queries do not start timers or mutate health")
	attacking.attack_timer.stop()
	_expect_selection(fixture, [stopped_at_core], "Stopped contact target falls back to core distance")
	attacking.attack_timer.start()
	attacking.process_mode = Node.PROCESS_MODE_DISABLED
	_check(not attacking.is_attacking_core(), "Disabled enemy is not a current attacker")
	_expect_selection(fixture, [stopped_at_core], "Disabled enemy is not a firing candidate")
	attacking.process_mode = Node.PROCESS_MODE_INHERIT
	attacking.position.x -= 30.0
	_check(not attacking.is_attacking_core(), "A running timer outside contact reach is not attack pressure")
	attacking.position.x += 30.0
	_fire(fixture)
	_expect_targets(fixture, [attacking], "Actual attacker round")
	await _hit_all(fixture)
	_check(attacking.health == 188 and nearest.health == 200 and approaching.health == 200,
		"Threat-selected projectile damages only its frozen target")
	await _dispose(fixture)
	cases.append("pure_running_attack_timer_threat_priority_and_actual_impact")


func _test_core_distance_ties_and_fallback() -> void:
	var fixture := _new_fixture(["normal"], true)
	var near_weapon := _enemy(fixture, Vector2(20, 0))
	var near_core := _enemy(fixture, Vector2(100, 0))
	_expect_selection(fixture, [near_core], "Closer core distance precedes closer weapon distance")
	fixture.core.global_position = fixture.organs[0].global_position + Vector2(100, 0)
	near_weapon.global_position = fixture.organs[0].global_position + Vector2(60, 0)
	near_core.global_position = fixture.organs[0].global_position + Vector2(140, 0)
	_check(near_weapon.get_core_distance_squared() == near_core.get_core_distance_squared(),
		"Core-distance tie uses exact ground distances")
	_expect_selection(fixture, [near_weapon], "Equal core distance uses ground weapon distance")
	var tied := _enemy(fixture, Vector2(60, 0))
	fixture.enemies.move_child(tied, 0)
	_check(near_weapon.get_instance_id() < tied.get_instance_id(), "Tie IDs are ordered independently of tree order")
	_expect_selection(fixture, [near_weapon], "Equal core and weapon distances use ascending instance ID")
	fixture.core.health = 0
	_check(is_inf(near_core.get_core_distance_squared()) and not near_core.is_attacking_core(),
		"Dead core provides no current distance or attack threat")
	_expect_selection(fixture, [near_weapon], "Dead-core distances fall back to nearest enemy and ID")
	fixture.core.free()
	_check(is_inf(tied.get_core_distance_squared()) and not tied.is_attacking_core(),
		"Freed core is unavailable without querying a freed typed node")
	_fire(fixture)
	_expect_targets(fixture, [near_weapon], "Freed-core fallback")
	await _dispose(fixture)
	fixture = _new_fixture(["normal"])
	var far := _enemy(fixture, Vector2(100, 0))
	var near := _enemy(fixture, Vector2(20, 0))
	_check(is_inf(far.get_core_distance_squared()), "Missing core yields INF")
	_fire(fixture)
	_expect_targets(fixture, [near], "All missing-core targets use nearest fallback")
	await _dispose(fixture)
	cases.append("core_ground_distance_weapon_distance_instance_id_and_unavailable_core_fallback")


func _test_ground_range_and_liveness() -> void:
	for mode: String in PRESET_PATHS:
		var fixture := _new_fixture([mode], true)
		var profile := fixture.weapons[0].get_weapon_profile()
		fixture.core.global_position = fixture.organs[0].global_position + Vector2(400, 0)
		fixture.weapons[0].position.y = -350.0
		var outside_attacker := _enemy(fixture, Vector2(390, 0))
		outside_attacker.attack_timer.start()
		var boundary := _enemy(fixture, Vector2(profile.attack_range, 0))
		boundary.sprite.position.y = -600.0
		_fire(fixture)
		_expect_targets(fixture, [boundary], mode + " inclusive ground range despite distant muzzle and sprite")
		_check(outside_attacker.is_attacking_core() and outside_attacker.health == 200,
			mode + " attack pressure cannot expand ground range")
		await _dispose(fixture)
		fixture = _new_fixture([mode])
		profile = fixture.weapons[0].get_weapon_profile()
		var within_tolerance := _enemy(fixture, Vector2(profile.attack_range + 0.00005, 0))
		_fire(fixture)
		_expect_targets(fixture, [within_tolerance], mode + " range plus 0.00005 stays within position tolerance")
		await _dispose(fixture)
		fixture = _new_fixture([mode])
		profile = fixture.weapons[0].get_weapon_profile()
		var outside := _enemy(fixture, Vector2(profile.attack_range + 0.001, 0))
		outside.sprite.position.x = -profile.attack_range
		_fire(fixture)
		_expect_no_round(fixture, mode + " outside range tolerance")
		_check(outside.health == 200 and fixture.tracker.get_snapshot()["total_count"] == 0,
			mode + " visual aim does not admit an out-of-range target")
		await _dispose(fixture)
	var fixture := _new_fixture(["normal"])
	var dead := _enemy(fixture, Vector2(10, 0))
	dead.health = 0
	var disabled := _enemy(fixture, Vector2(20, 0))
	disabled.process_mode = Node.PROCESS_MODE_DISABLED
	var deleting := _enemy(fixture, Vector2(30, 0))
	deleting.queue_free()
	var available := _enemy(fixture, Vector2(60, 0))
	_fire(fixture)
	_expect_targets(fixture, [available], "Dead, unprocessable and deleting targets are excluded")
	await _dispose(fixture)
	cases.append("ground_range_tolerance_visual_height_and_live_processable_candidate_filter")


func _test_priority_scatter_and_cone() -> void:
	var fixture := _new_fixture(["scatter"], true)
	var primary := _enemy(fixture, Vector2(130, 0))
	primary.attack_timer.start()
	var near_weapon := _enemy(fixture, Vector2(50, 0))
	var near_core := _enemy(fixture, Vector2(110, 0))
	_fire(fixture)
	_expect_targets(fixture, [primary, near_core, near_weapon], "Scatter preserves threat order throughout its cone")
	await _dispose(fixture)
	for sign_value: float in [-1.0, 1.0]:
		fixture = _new_fixture(["scatter"], true)
		fixture.core.global_position = fixture.organs[0].global_position + Vector2(0, 115)
		primary = _enemy(fixture, Vector2(0, 90))
		primary.attack_timer.start()
		near_weapon = _enemy(fixture, Vector2(20, 0))
		var boundary := _enemy(fixture,
			Vector2.from_angle(deg_to_rad(90.0 + 30.0 * sign_value)) * 100.0)
		var inside := _enemy(fixture,
			Vector2.from_angle(deg_to_rad(90.0 - 29.999 * sign_value)) * 120.0)
		var outside := _enemy(fixture,
			Vector2.from_angle(deg_to_rad(90.0 + 30.001 * sign_value)) * 80.0)
		boundary.sprite.position.y = 500.0
		inside.sprite.position.y = -500.0
		_fire(fixture)
		_expect_targets(fixture, [primary, boundary, inside], "Highest threat fixes signed inclusive full-cone direction")
		_check(near_weapon.health == 200 and outside.health == 200,
			"Nearest off-axis enemy and angle outside by 0.001 degrees remain uncovered")
		await _dispose(fixture)
	cases.append("scatter_primary_threat_direction_distinct_priority_order_and_full_cone_boundaries")


func _test_wraparound_and_coincident_primary() -> void:
	for sign_value: float in [-1.0, 1.0]:
		var fixture := _new_fixture(["scatter"])
		var primary := _enemy(fixture, Vector2.from_angle(deg_to_rad(179.0 * sign_value)) * 50.0)
		var wrapped := _enemy(fixture, Vector2.from_angle(deg_to_rad(-179.0 * sign_value)) * 80.0)
		var boundary := _enemy(fixture, Vector2.from_angle(deg_to_rad(149.0 * sign_value)) * 110.0)
		var outside := _enemy(fixture, Vector2.from_angle(deg_to_rad(148.999 * sign_value)) * 70.0)
		_fire(fixture)
		_expect_targets(fixture, [primary, wrapped, boundary], "Signed PI wraparound")
		_check(fixture.tracker.get_incoming_damage(outside) == 0, "PI wrapping does not widen the configured cone")
		await _dispose(fixture)
	var fixture := _new_fixture(["scatter"])
	var coincident := _enemy(fixture, Vector2.ZERO)
	var right := _enemy(fixture, Vector2(40, 0))
	var boundary := _enemy(fixture, Vector2.from_angle(deg_to_rad(30.0)) * 70.0)
	var vertical := _enemy(fixture, Vector2(0, 50))
	_fire(fixture)
	_expect_targets(fixture, [coincident, right, boundary], "Coincident primary uses RIGHT at the ground origin")
	_check(fixture.tracker.get_incoming_damage(vertical) == 0, "Coincident primary excludes off-axis targets")
	await _dispose(fixture)
	cases.append("pi_wraparound_and_coincident_primary_right_direction")


func _test_shared_coverage_skip_and_wait() -> void:
	var fixture := _new_fixture(["normal", "normal"])
	var first := _enemy(fixture, Vector2(50, 0), 12)
	var second := _enemy(fixture, Vector2(90, 0), 12)
	_fire(fixture, 0)
	_check(first.health == 12 and fixture.tracker.get_remaining_health(first) == 0,
		"A live first target can be fully covered by one committed projectile")
	_fire(fixture, 1)
	_expect_targets(fixture, [first, second], "Second weapon skips the covered first target")
	var before_events := fixture.events.size()
	var before_statistics := fixture.weapons[0].get_shot_statistics()
	_fire(fixture, 0)
	_fire(fixture, 1)
	_check(fixture.events.size() == before_events and fixture.organs[0].nutrition == 5
		and fixture.organs[1].nutrition == 5 and fixture.weapons[0].get_shot_statistics() == before_statistics,
		"All-covered round waits without another cost, event or statistics change")
	await _hit_all(fixture)
	_check(first.health == 0 and second.health == 0 and fixture.tracker.get_snapshot()["total_count"] == 0,
		"Real exactly-once hits remove all committed demand")
	await _dispose(fixture)
	fixture = _new_fixture(["scatter"])
	first = _enemy(fixture, Vector2(50, 0), 6)
	second = _enemy(fixture, Vector2(70, 0), 6)
	var third := _enemy(fixture, Vector2(90, 0), 6)
	var fourth := _enemy(fixture, Vector2(110, 0), 6)
	var foreign_id := _reserve_foreign(fixture, second, 6)
	_fire(fixture)
	_expect_targets(fixture, [first, third, fourth], "Scatter fills distinct slots while skipping covered candidates")
	_check(fixture.tracker.is_commitment_live(foreign_id) and fixture.organs[0].nutrition == 5,
		"Covered scatter candidate keeps its independent commitment and round price")
	await _dispose(fixture)
	cases.append("shared_covered_skip_all_covered_wait_and_distinct_scatter_fill")


func _test_partial_demand_and_current_armor() -> void:
	var fixture := _new_fixture(["normal", "normal"])
	var target := _enemy(fixture, Vector2(60, 0), 25)
	for index: int in [0, 1, 0]:
		_fire(fixture, index)
	_check(fixture.events.size() == 3 and fixture.tracker.get_incoming_damage(target) == 36
		and fixture.tracker.get_remaining_health(target) == 0 and target.health == 25,
		"Positive partial demand admits another whole frozen projectile, including the final overkill")
	_fire(fixture, 1)
	_check(fixture.events.size() == 3 and fixture.organs[0].nutrition == 4 and fixture.organs[1].nutrition == 5,
		"Only the three committed whole rounds are priced")
	await _hit_all(fixture)
	_check(target.health == 0 and fixture.tracker.get_snapshot()["total_count"] == 0,
		"Overkill projectiles terminate without repeat settlement")
	await _dispose(fixture)
	fixture = _new_fixture(["normal", "armor_piercing"])
	target = _enemy(fixture, Vector2(60, 0), 10, 9)
	_fire(fixture, 0)
	var first_projectile := _projectiles(fixture)[0]
	var first_id := first_projectile.get_damage_commitment_id()
	_check(fixture.tracker.get_incoming_damage(target) == 3 and fixture.tracker.get_remaining_health(target) == 7,
		"Normal demand uses effective current armor instead of raw damage")
	target.armor = 11
	_check(fixture.tracker.get_incoming_damage(target) == 1 and fixture.tracker.get_remaining_health(target) == 9,
		"Existing commitment reevaluates the armor floor against current armor")
	target.armor = 0
	_fire(fixture, 0)
	_check(fixture.tracker.get_incoming_damage(target) == 12 and fixture.events.size() == 1,
		"Reduced armor can cover a target and make its following round wait")
	target.armor = 20
	_check(fixture.weapons[0].configure_profile(_preset("armor_piercing")), "Next-round profile can change with old flight alive")
	(fixture.weapons[0].get_node("FireTimer") as Timer).stop()
	var old_record := fixture.tracker.get_commitment(first_id)
	_check(int(old_record["raw_damage"]) == 12 and int(old_record["damage_type"]) == WeaponProfile.DamageType.NORMAL,
		"Weapon reconfiguration cannot rewrite a frozen old commitment")
	_fire(fixture, 1)
	_check(fixture.tracker.get_incoming_damage(target) == 25 and fixture.tracker.get_remaining_health(target) == 0,
		"AP expected damage ignores armor while normal expected damage retains its floor")
	_check(_totals(fixture, 0)["spent"] == 1 and _totals(fixture, 1)["spent"] == 2,
		"Armor-aware commitment does not change normal or AP whole-round prices")
	await _hit_all(fixture)
	_check(target.health == 0 and fixture.tracker.get_snapshot()["total_count"] == 0,
		"Current-armor real impacts settle their original requests")
	await _dispose(fixture)
	cases.append("positive_partial_demand_current_armor_floor_ap_and_frozen_old_request")


func _test_whole_round_prices() -> void:
	for mode: String in PRESET_PATHS:
		var maximum: int = 3 if mode == "scatter" else 1
		for available: int in range(1, maximum + 1):
			var fixture := _new_fixture([mode])
			var profile := fixture.weapons[0].get_weapon_profile()
			var targets: Array[BasicEnemy] = []
			for ordinal: int in range(available):
				targets.append(_enemy(fixture, Vector2(50 + 25 * ordinal, 0), 200, 4))
			_fire(fixture)
			_expect_targets(fixture, targets, mode + " whole round")
			_check(fixture.events.size() == 1 and int(fixture.events[0]["spent"]) == profile.nutrition_cost
				and int(fixture.events[0]["count"]) == available
				and fixture.tracker.get_snapshot()["prepared_count"] == 0
				and fixture.tracker.get_snapshot()["committed_count"] == available,
				mode + " commits every projectile for exactly one configured round price")
			await _hit_all(fixture)
			var effective: int = 24 if mode == "armor_piercing" else maxi(1, profile.damage - 4)
			for target: BasicEnemy in targets:
				_check(target.health == 200 - effective, mode + " lands one real effective damage request per target")
			_check(fixture.tracker.get_snapshot()["total_count"] == 0,
				mode + " real impacts clear committed ledger records")
			await _dispose(fixture)
	cases.append("normal_ap_scatter_one_two_three_pellets_actual_whole_round_prices_and_impacts")


func _test_reserve_before_callbacks_and_self_exclusion() -> void:
	var fixture := _new_fixture(["scatter", "normal"])
	var targets: Array[BasicEnemy] = [_enemy(fixture, Vector2(50, 0), 6),
		_enemy(fixture, Vector2(80, 0), 6), _enemy(fixture, Vector2(110, 0), 6)]
	fixture.weapons[0].projectile_scene = _preparation_scene()
	PreparationProjectile.on_creation = func(_ordinal: int) -> void:
		_check(fixture.tracker.get_snapshot()["prepared_count"] == 3
			and fixture.tracker.get_snapshot()["committed_count"] == 0,
			"All three target identities are counted before every constructor callback")
		for target: BasicEnemy in targets:
			_check(fixture.tracker.get_remaining_health(target) == 0 and target.health == 6,
				"All pre-instantiation reservations cover demand without touching HP")
	PreparationProjectile.on_launch = func(_draft: SporeProjectile, ordinal: int) -> void:
		_check(fixture.organs[0].nutrition == 6 and fixture.events.is_empty(),
			"All launch callbacks see an unpaid prepared round")
		if ordinal == 1:
			fixture.weapons[0]._on_fire_timer_timeout()
			_fire(fixture, 1)
	fixture.projectiles.child_entered_tree.connect(func(child: Node) -> void:
		if child is SporeProjectile:
			var projectile := child as SporeProjectile
			projectile._physics_process(10.0)
			_check(fixture.events.is_empty() and targets[0].health == 6,
				"Prepared linked tree draft cannot hit through manual physics reentry")
			projectile.visibility_changed.connect(func() -> void:
				if projectile.visible:
					_check(fixture.events.size() == 1 and fixture.tracker.get_snapshot()["committed_count"] == 3,
						"Activation observers already see the authoritative event and the complete committed batch")
			)
	)
	_fire(fixture, 0)
	_expect_targets(fixture, targets, "Self-reservation-excluded reranking")
	_check(PreparationProjectile.created == 3 and PreparationProjectile.launch_attempts == 3
		and fixture.events.size() == 1 and fixture.organs[1].nutrition == 6,
		"Own prepared IDs do not block their volley; same-weapon and shared-weapon reentry create no duplicate round")
	_expect_no_round(fixture, "Covered reentrant second weapon", 1)
	await _hit_all(fixture)
	_check(targets[0].health == 0 and targets[1].health == 0 and targets[2].health == 0,
		"Only the committed first volley lands its three frozen requests")
	await _dispose(fixture)
	cases.append("all_target_preparation_before_constructor_launch_tree_callbacks_own_id_exclusion_and_reentry")


func _test_other_weapon_coverage_aborts_only_own_round() -> void:
	var fixture := _new_fixture(["scatter", "armor_piercing"])
	var primary := _enemy(fixture, Vector2(50, 0), 20)
	var second := _enemy(fixture, Vector2(80, 0), 6)
	var third := _enemy(fixture, Vector2(110, 0), 6)
	fixture.weapons[0].projectile_scene = _preparation_scene()
	PreparationProjectile.on_launch = func(_draft: SporeProjectile, ordinal: int) -> void:
		if ordinal == 1:
			_fire(fixture, 1)
	_fire(fixture, 0)
	_expect_no_round(fixture, "Other weapon covers an outer prepared primary", 0)
	_expect_targets(fixture, [primary], "Independent committed AP survives scatter rollback")
	_check(fixture.events.size() == 1 and int(fixture.events[0]["weapon"]) == 1
		and fixture.organs[1].nutrition == 4 and fixture.tracker.get_snapshot()["committed_count"] == 1
		and fixture.tracker.get_snapshot()["prepared_count"] == 0,
		"Reranking ignores only its own IDs and preserves the other weapon's ledger, debit and event")
	_check(fixture.tracker.get_incoming_damage(primary) == 24
		and fixture.tracker.get_incoming_damage(second) == 0 and fixture.tracker.get_incoming_damage(third) == 0,
		"Rollback releases only the failed outer batch")
	await _hit_all(fixture)
	_check(primary.health == 0 and second.health == 6 and third.health == 6,
		"Surviving AP projectile lands while all failed scatter drafts remain inert")
	await _dispose(fixture)
	cases.append("other_weapon_reservations_count_during_own_id_exclusion_and_rollback_isolation")


func _test_partial_failures_and_silent_debit() -> void:
	for failure_mode: String in ["prepare_2", "launch_2", "bind_2", "commit", "debit", "wrong_type", "missing_scene"]:
		var tracker := RejectingTracker.new()
		var fixture := _new_fixture(["scatter"], false, true, tracker)
		var targets: Array[BasicEnemy] = [_enemy(fixture, Vector2(50, 0), 6),
			_enemy(fixture, Vector2(80, 0), 6), _enemy(fixture, Vector2(110, 0), 6)]
		var unrelated := _enemy(fixture, Vector2(300, 0), 12)
		var unrelated_id := _reserve_foreign(fixture, unrelated)
		fixture.weapons[0].projectile_scene = _preparation_scene()
		match failure_mode:
			"prepare_2": tracker.reject_prepare_at = tracker.preparation_attempts + 2
			"launch_2": PreparationProjectile.reject_launch_at = 2
			"bind_2": PreparationProjectile.reject_bind_at = 2
			"commit": tracker.reject_commit = true
			"debit":
				_check(fixture.organs[0]._consume_volley_nutrition(1), "Debit guard fixture obtains a silent existing inventory transaction")
				fixture.initial_stocks[0] = fixture.organs[0].nutrition
			"wrong_type": fixture.weapons[0].projectile_scene = _pack_scene(Node2D.new())
			"missing_scene": fixture.weapons[0].projectile_scene = null
		_fire(fixture)
		_expect_no_round(fixture, failure_mode)
		_check(fixture.projectiles.get_child_count() == 0 and tracker.get_snapshot()["total_count"] == 1
			and tracker.is_commitment_live(unrelated_id) and tracker.get_incoming_damage(unrelated) == 12,
			failure_mode + " removes every own draft and reservation while preserving foreign ownership")
		for target: BasicEnemy in targets:
			_check(target.health == 6 and tracker.get_incoming_damage(target) == 0,
				failure_mode + " leaves no partial impact or prepared damage")
		if failure_mode == "prepare_2":
			_check(PreparationProjectile.created == 0, "Partial reservation failure creates no projectile scene")
		if failure_mode == "launch_2":
			_check(PreparationProjectile.launch_attempts == 2, "Launch failure follows one bound tree draft")
		if failure_mode == "bind_2":
			_check(PreparationProjectile.bind_attempts == 2, "Bind failure follows one successful binding")
		if failure_mode == "commit":
			_check(tracker.commit_attempts == 1 and tracker.successful_commits == 0,
				"Rejected atomic batch never debits the inventory")
		if failure_mode == "debit":
			_check(tracker.successful_commits == 1,
				"Silent debit failure really rolls back an already atomically committed own batch")
		await process_frame
		for draft: WeakRef in PreparationProjectile.drafts:
			_check(draft.get_ref() == null, failure_mode + " frees every constructed draft")
		await _dispose(fixture)
	cases.append("partial_reservation_launch_bind_atomic_commit_silent_debit_and_scene_failures_preserve_foreign_records")


func _test_epoch_reset_during_preparation() -> void:
	for reset_stage: String in ["constructor", "launch", "tree"]:
		var fixture := _new_fixture(["scatter"])
		var targets: Array[BasicEnemy] = [_enemy(fixture, Vector2(50, 0), 6),
			_enemy(fixture, Vector2(80, 0), 6), _enemy(fixture, Vector2(110, 0), 6)]
		var replacement := _enemy(fixture, Vector2(300, 0), 12)
		var old_generation: int = fixture.tracker.get_snapshot()["generation"]
		fixture.weapons[0].projectile_scene = _preparation_scene()
		var reset_hook := func() -> void:
			fixture.tracker.reset()
			_reserve_foreign(fixture, replacement)
		match reset_stage:
			"constructor":
				PreparationProjectile.on_creation = func(ordinal: int) -> void:
					if ordinal == 1:
						reset_hook.call()
			"launch":
				PreparationProjectile.on_launch = func(_draft: SporeProjectile, ordinal: int) -> void:
					if ordinal == 1:
						reset_hook.call()
			"tree":
				fixture.projectiles.child_entered_tree.connect(func(_child: Node) -> void:
					reset_hook.call()
				, CONNECT_ONE_SHOT)
		_fire(fixture)
		_expect_no_round(fixture, reset_stage + " epoch reset")
		_check(fixture.projectiles.get_child_count() == 0
			and int(fixture.tracker.get_snapshot()["generation"]) == old_generation + 1
			and fixture.tracker.get_snapshot()["total_count"] == 1
			and fixture.tracker.is_commitment_live(fixture.extra_ids[0]),
			reset_stage + " aborts the old epoch without deleting a new-epoch foreign reservation")
		for target: BasicEnemy in targets:
			_check(target.health == 6 and fixture.tracker.get_incoming_damage(target) == 0,
				reset_stage + " old prepared requests never land")
		await _dispose(fixture)
	cases.append("generation_reset_during_constructor_launch_tree_and_new_epoch_cleanup_isolation")


func _test_configuration_and_target_revalidation() -> void:
	for mutation: String in ["profile", "owner_pause", "target_moves", "stop", "owner_exit", "tracker_freed"]:
		var fixture := _new_fixture(["scatter"])
		var first := _enemy(fixture, Vector2(50, 0), 6)
		_enemy(fixture, Vector2(80, 0), 6)
		_enemy(fixture, Vector2(110, 0), 6)
		fixture.weapons[0].projectile_scene = _preparation_scene()
		PreparationProjectile.on_launch = func(_draft: SporeProjectile, ordinal: int) -> void:
			if ordinal != 1:
				return
			match mutation:
				"profile": fixture.weapons[0].configure_profile(_preset("normal"))
				"owner_pause": fixture.organs[0].set_work_enabled(false)
				"target_moves": first.global_position.x += 500.0
				"stop": fixture.tracker.stop()
				"owner_exit": fixture.hosts[0].remove_child(fixture.weapons[0])
				"tracker_freed": fixture.tracker.free()
		_fire(fixture)
		_expect_no_round(fixture, mutation + " preparation revalidation")
		_check(fixture.projectiles.get_child_count() == 0 and first.health == 6,
			mutation + " preparation leaves no launched impact")
		if is_instance_valid(fixture.tracker):
			_check(fixture.tracker.get_snapshot()["total_count"] == 0,
				mutation + " frees all owned preparation identities")
		if mutation == "owner_exit":
			fixture.weapons[0].free()
		await _dispose(fixture)
	cases.append("profile_work_state_target_range_stop_owner_exit_and_freed_tracker_revalidation")


func _test_committed_event_and_owner_lifetime() -> void:
	var fixture := _new_fixture(["scatter"])
	var targets: Array[BasicEnemy] = [_enemy(fixture, Vector2(50, 0), 200),
		_enemy(fixture, Vector2(80, 0), 200), _enemy(fixture, Vector2(110, 0), 200)]
	fixture.weapons[0].volley_committed.connect(func(_shot_id: String, _spent: int, _count: int) -> void:
		fixture.weapons[0]._on_fire_timer_timeout()
		fixture.organs[0].set_work_enabled(false)
		fixture.weapons[0].configure_profile(_preset("armor_piercing"))
	, CONNECT_ONE_SHOT)
	_fire(fixture)
	_expect_targets(fixture, targets, "Committed round survives event reentry and reconfiguration")
	_check(fixture.events.size() == 1 and fixture.organs[0].nutrition == 5
		and fixture.tracker.get_snapshot()["committed_count"] == 3
		and fixture.timeline[0] == "volley:0" and fixture.timeline.count("legacy:0") == 1
		and fixture.timeline.count("inventory:0") == 1,
		"Ledger, stock and statistics precede exactly one authoritative/legacy/inventory round")
	fixture.weapons[0].queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.weapons[0]) and fixture.tracker.get_snapshot()["committed_count"] == 3,
		"Committed projectile records outlive their paused and removed weapon")
	await _hit_all(fixture)
	for target: BasicEnemy in targets:
		_check(target.health == 194, "Owner exit preserves the original scatter request and one actual hit")
	_check(fixture.tracker.get_snapshot()["total_count"] == 0, "Projectile-owned impacts release all records after owner exit")
	await _dispose(fixture)
	fixture = _new_fixture(["armor_piercing"])
	var target := _enemy(fixture, Vector2(60, 0), 200)
	fixture.weapons[0].volley_committed.connect(func(_shot_id: String, _spent: int, _count: int) -> void:
		fixture.tracker.reset()
	, CONNECT_ONE_SHOT)
	_fire(fixture)
	_check(fixture.events.size() == 1 and fixture.organs[0].nutrition == 4
		and fixture.legacy.size() == 1 and fixture.tracker.get_snapshot()["total_count"] == 0,
		"Reset after payment cancels flight while retaining its cost and one round receipt")
	await process_frame
	_check(fixture.projectiles.get_child_count() == 0 and target.health == 200,
		"Cancelled paid AP does not activate or create an early impact")
	await _dispose(fixture)
	cases.append("authoritative_event_before_activation_reentry_frozen_request_owner_exit_and_paid_epoch_reset")


func _test_missing_and_invalid_trackers() -> void:
	for failure_mode: String in ["required_missing", "stopped", "detached", "freed", "disabled"]:
		var fixture := _new_fixture(["normal"], false, failure_mode != "required_missing")
		var target := _enemy(fixture, Vector2(60, 0))
		fixture.weapons[0].targeting_required = failure_mode == "required_missing"
		match failure_mode:
			"stopped": fixture.tracker.stop()
			"detached": fixture.world.remove_child(fixture.tracker)
			"freed": fixture.tracker.free()
			"disabled": fixture.tracker.process_mode = Node.PROCESS_MODE_DISABLED
		_fire(fixture)
		_expect_no_round(fixture, failure_mode + " tracker")
		_check(fixture.projectiles.get_child_count() == 0 and target.health == 200,
			failure_mode + " tracker fails closed without untracked fallback")
		if failure_mode == "detached":
			fixture.tracker.free()
		await _dispose(fixture)
	var fixture := _new_fixture(["normal"], false, false)
	var target := _enemy(fixture, Vector2(60, 0))
	_fire(fixture)
	_expect_targets(fixture, [target], "Null optional tracker legacy fixture")
	_check(fixture.events.size() == 1 and fixture.organs[0].nutrition == 5
		and _projectiles(fixture)[0].get_damage_commitment_id().is_empty(),
		"Explicit null optional tracker preserves legacy untracked shooting")
	await _hit_all(fixture)
	_check(target.health == 188, "Legacy unbound projectile still lands its original normal request")
	await _dispose(fixture)
	cases.append("required_missing_and_explicit_invalid_stopped_tracker_fail_closed_optional_null_legacy")
