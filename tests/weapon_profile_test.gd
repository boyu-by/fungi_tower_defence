extends SceneTree
## 验证配置契约、器官实例隔离和真实发射/库存行为。

const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const NORMAL_PATH: String = "res://resources/weapons/normal_spore.tres"
const AP_PATH: String = "res://resources/weapons/armor_piercing_spore.tres"
const SCATTER_PATH: String = "res://resources/weapons/scatter_spore.tres"

var failures: Array[String] = []
var checks: int = 0
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	_test_defaults_and_presets()
	_test_validation_boundaries()
	_test_copies_and_requests()
	await _test_legacy_and_before_ready_configuration()
	await _test_shared_profile_isolation_and_cost_lookup()
	await _test_configuration_controls_combat()
	await _test_invalid_configuration_is_atomic()
	await _test_scatter_configuration()
	_check(root.get_child_count() == _initial_root_children, "Weapon fixtures left orphan nodes")
	print("WEAPON_PROFILE_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _values(profile: WeaponProfile) -> Dictionary:
	if profile == null:
		return {}
	return {
		"damage": profile.damage, "fire_interval": profile.fire_interval,
		"attack_range": profile.attack_range, "nutrition_cost": profile.nutrition_cost,
		"max_targets": profile.max_targets, "spread_angle_degrees": profile.spread_angle_degrees,
		"damage_type": int(profile.damage_type),
	}


func _check_profile(profile: WeaponProfile, expected: Dictionary, description: String) -> void:
	_check(profile != null, description + ": missing profile")
	if profile == null:
		return
	_check(profile.is_valid() and profile.get_validation_errors().is_empty(), description + ": valid")
	_check(_values(profile) == expected, description + ": exact parameters")


func _test_defaults_and_presets() -> void:
	var normal_values: Dictionary = {
		"damage": 12, "fire_interval": 0.8, "attack_range": 178.0,
		"nutrition_cost": 1, "max_targets": 1, "spread_angle_degrees": 0.0, "damage_type": 0,
	}
	_check_profile(WeaponProfile.new(), normal_values, "New profile defaults")
	var presets: Array[Dictionary] = [
		{"path": NORMAL_PATH, "values": normal_values},
		{"path": AP_PATH, "values": {
			"damage": 24, "fire_interval": 1.8, "attack_range": 178.0,
			"nutrition_cost": 2, "max_targets": 1, "spread_angle_degrees": 0.0, "damage_type": 1,
		}},
		{"path": SCATTER_PATH, "values": {
			"damage": 6, "fire_interval": 0.9, "attack_range": 145.0,
			"nutrition_cost": 1, "max_targets": 3, "spread_angle_degrees": 60.0, "damage_type": 2,
		}},
	]
	for preset: Dictionary in presets:
		var path: String = preset["path"]
		var resource: Resource = load(path)
		_check(resource is WeaponProfile, path + ": resource type")
		_check_profile(resource as WeaponProfile, preset["values"], path)


func _test_validation_boundaries() -> void:
	var invalid_cases: Array[Dictionary] = [
		{"damage": 0}, {"damage": -1}, {"nutrition_cost": 0}, {"nutrition_cost": -1},
		{"fire_interval": 0.0}, {"fire_interval": -0.1}, {"fire_interval": NAN},
		{"fire_interval": INF}, {"fire_interval": -INF},
		{"attack_range": 0.0}, {"attack_range": -0.1}, {"attack_range": NAN},
		{"attack_range": INF}, {"attack_range": -INF},
		{"max_targets": 0}, {"max_targets": 4},
		{"spread_angle_degrees": -0.1}, {"spread_angle_degrees": 360.1},
		{"spread_angle_degrees": NAN}, {"spread_angle_degrees": INF}, {"spread_angle_degrees": -INF},
		{"damage_type": -1}, {"damage_type": 3}, {"damage_type": 99},
		{"max_targets": 2}, {"spread_angle_degrees": 1.0},
		{"damage_type": 1, "max_targets": 2}, {"damage_type": 1, "spread_angle_degrees": 1.0},
		{"damage_type": 2, "spread_angle_degrees": 0.0},
	]
	for index in range(invalid_cases.size()):
		var profile := WeaponProfile.new()
		for property: String in invalid_cases[index]:
			profile.set(property, invalid_cases[index][property])
		var label := "Invalid profile case %d" % index
		_check(not profile.is_valid(), label + ": rejected")
		_check(not profile.get_validation_errors().is_empty(), label + ": explains failure")
		_check(profile.copy_for_instance() == null, label + ": cannot copy")
		_check(profile.create_damage_request().is_empty(), label + ": cannot attack")
	var smallest := WeaponProfile.new()
	smallest.damage = 1
	smallest.nutrition_cost = 1
	smallest.fire_interval = 0.0001
	smallest.attack_range = 0.0001
	_check(smallest.is_valid(), "Finite positive boundaries remain valid")
	for targets in [1, 2, 3]:
		for angle in [0.0001, 360.0]:
			var scatter := WeaponProfile.new()
			scatter.damage_type = WeaponProfile.DamageType.SCATTER
			scatter.max_targets = targets
			scatter.spread_angle_degrees = angle
			_check(scatter.is_valid(), "Scatter permits targets %d and full cone %s" % [targets, angle])


func _test_copies_and_requests() -> void:
	var profile := WeaponProfile.new()
	var baseline := _values(profile)
	var copy: WeaponProfile = profile.copy_for_instance()
	_check(copy != null and copy != profile and copy.is_valid(), "Copy is an independent valid resource")
	if copy != null:
		copy.damage = 25
		copy.fire_interval = 1.2
		copy.attack_range = 220.0
		copy.nutrition_cost = 3
		copy.max_targets = 3
		copy.spread_angle_degrees = 120.0
		copy.damage_type = WeaponProfile.DamageType.SCATTER
		_check(copy.is_valid() and _values(profile) == baseline, "Mutating every copied field leaves source intact")
	var first: Dictionary = profile.create_damage_request()
	var second: Dictionary = profile.create_damage_request()
	_check(first == {"raw_damage": 12, "damage_type": 0}, "Request contains only frozen damage scalars")
	_check(typeof(first.get("raw_damage")) == TYPE_INT and typeof(first.get("damage_type")) == TYPE_INT,
		"Request damage and enum use strict integers")
	first["raw_damage"] = 99
	first["damage_type"] = 1
	_check(second == {"raw_damage": 12, "damage_type": 0} and _values(profile) == baseline,
		"Requests are independent of each other and profile")
	profile.damage = 30
	_check(second["raw_damage"] == 12, "Later profile edits do not rewrite old request")
	var valid_requests: Array[Dictionary] = [
		{"raw_damage": 1, "damage_type": 0}, {"raw_damage": 12, "damage_type": 1},
		{"raw_damage": 6, "damage_type": 2}, {"raw_damage": 12, "damage_type": 0, "extra": null},
	]
	for request: Dictionary in valid_requests:
		_check(WeaponProfile.is_valid_damage_request(request), "Valid scalar request accepted: %s" % request)
	for request: Dictionary in _invalid_requests():
		_check(not WeaponProfile.is_valid_damage_request(request), "Malformed scalar request rejected: %s" % request)


func _invalid_requests() -> Array[Dictionary]:
	return [
		{}, {"raw_damage": 12}, {"damage_type": 0},
		{"raw_damage": 0, "damage_type": 0}, {"raw_damage": -1, "damage_type": 0},
		{"raw_damage": 12.0, "damage_type": 0}, {"raw_damage": true, "damage_type": 0},
		{"raw_damage": "12", "damage_type": 0}, {"raw_damage": null, "damage_type": 0},
		{"raw_damage": NAN, "damage_type": 0}, {"raw_damage": INF, "damage_type": 0},
		{"raw_damage": 12, "damage_type": -1}, {"raw_damage": 12, "damage_type": 3},
		{"raw_damage": 12, "damage_type": 99}, {"raw_damage": 12, "damage_type": 0.0},
		{"raw_damage": 12, "damage_type": false}, {"raw_damage": 12, "damage_type": "0"},
		{"raw_damage": 12, "damage_type": null}, {"raw_damage": 12, "damage_type": INF},
	]


func _build_fixture(stock: int = 6, legacy_damage: int = 12, legacy_range: float = 300.0,
		legacy_interval: float = 0.8) -> Dictionary:
	var world := Node2D.new()
	var enemies := Node2D.new()
	var projectiles := Node2D.new()
	world.add_child(enemies)
	world.add_child(projectiles)
	var fixture: Dictionary = {"world": world, "enemies": enemies, "projectiles": projectiles}
	var pair := _add_pair(fixture, stock, Vector2.ZERO, legacy_damage, legacy_range, legacy_interval)
	fixture["organ"] = pair["organ"]
	fixture["weapon"] = pair["weapon"]
	return fixture


func _add_pair(fixture: Dictionary, stock: int, position: Vector2, legacy_damage: int = 12,
		legacy_range: float = 300.0, legacy_interval: float = 0.8) -> Dictionary:
	var organ := ORGAN_SCENE.instantiate() as AttackOrgan
	organ.initial_nutrition = stock
	organ.position = position
	var weapon := WEAPON_SCENE.instantiate() as SporeWeapon
	weapon.position = position
	weapon.inventory_owner = organ
	weapon.enemy_container = fixture["enemies"]
	weapon.projectile_container = fixture["projectiles"]
	weapon.damage = legacy_damage
	weapon.attack_range = legacy_range
	var timer := weapon.get_node("FireTimer") as Timer
	timer.autostart = false
	timer.one_shot = true
	timer.wait_time = legacy_interval
	var world: Node2D = fixture["world"]
	world.add_child(organ)
	world.add_child(weapon)
	return {"organ": organ, "weapon": weapon}


func _mount_fixture(fixture: Dictionary) -> void:
	var world: Node2D = fixture["world"]
	root.add_child(world)
	current_scene = world


func _remove_fixture(fixture: Dictionary) -> void:
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame


func _add_enemy(fixture: Dictionary, position: Vector2, armor_value: int = 0) -> BasicEnemy:
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = 200
	enemy.move_speed = 0.0
	enemy.armor = armor_value
	var enemies: Node2D = fixture["enemies"]
	enemies.add_child(enemy)
	enemy.global_position = position
	return enemy


func _trigger_shot(weapon: SporeWeapon) -> void:
	var timer := weapon.get_node("FireTimer") as Timer
	timer.timeout.emit()


func _test_legacy_and_before_ready_configuration() -> void:
	var untouched := WEAPON_SCENE.instantiate() as SporeWeapon
	_check(untouched.damage == 12 and untouched.attack_range == 300.0, "Old standalone weapon defaults stay 12/300")
	untouched.free()
	var fixture := _build_fixture(6, 27, 100.0, 1.35)
	_mount_fixture(fixture)
	var weapon: SporeWeapon = fixture["weapon"]
	var organ: AttackOrgan = fixture["organ"]
	var timer := weapon.get_node("FireTimer") as Timer
	var expected: Dictionary = {
		"damage": 27, "fire_interval": 1.35, "attack_range": 100.0,
		"nutrition_cost": 1, "max_targets": 1, "spread_angle_degrees": 0.0, "damage_type": 0,
	}
	_check_profile(weapon.get_weapon_profile(), expected, "Ready preserves explicit old damage/range/timer")
	var outside := _add_enemy(fixture, Vector2(105, 0))
	_trigger_shot(weapon)
	_check(organ.nutrition == 6 and (fixture["projectiles"] as Node2D).get_child_count() == 0,
		"Explicit old 100 range rejects target at 105")
	var inside := _add_enemy(fixture, Vector2(95, 0))
	_trigger_shot(weapon)
	_check(inside.health == 200 and organ.nutrition == 5, "Old weapon fires without pre-hit damage")
	await _wait_frames(40)
	_check(inside.health == 173 and outside.health == 200, "Old configured damage is used at impact")
	inside.global_position = Vector2(600, 0)
	weapon.damage = 20
	weapon.attack_range = 110.0
	timer.wait_time = 0.12
	expected["damage"] = 20
	expected["attack_range"] = 110.0
	expected["fire_interval"] = 0.12
	_check_profile(weapon.get_weapon_profile(), expected, "Legacy writes change the current snapshot")
	timer.start()
	await _wait_frames(12)
	_check(organ.nutrition == 4, "Direct legacy timer override drives a real timeout")
	await _wait_frames(40)
	_check(outside.health == 180, "Legacy damage/range writes control later firing")
	await _remove_fixture(fixture)
	fixture = _build_fixture(6, 31, 100.0, 2.0)
	weapon = fixture["weapon"]
	var normal := load(NORMAL_PATH) as WeaponProfile
	_check(weapon.configure_profile(normal), "Profile can be chosen before ready")
	_mount_fixture(fixture)
	_check_profile(weapon.get_weapon_profile(), _values(normal), "Ready preserves explicit API configuration")
	await _remove_fixture(fixture)


func _test_shared_profile_isolation_and_cost_lookup() -> void:
	var fixture := _build_fixture()
	var other_pair := _add_pair(fixture, 6, Vector2(0, 400))
	_mount_fixture(fixture)
	var first: SporeWeapon = fixture["weapon"]
	var second: SporeWeapon = other_pair["weapon"]
	var shared := load(AP_PATH) as WeaponProfile
	var baseline := _values(shared)
	_check(first.configure_profile(shared) and second.configure_profile(shared), "Two organs accept one shared preset")
	var queried: WeaponProfile = first.get_weapon_profile()
	_check(queried != shared and queried != second.get_weapon_profile(), "Each queried configuration is a separate resource")
	if queried != null:
		queried.damage = 99
		queried.fire_interval = 3.0
		queried.attack_range = 700.0
		queried.nutrition_cost = 5
		queried.max_targets = 3
		queried.spread_angle_degrees = 360.0
		queried.damage_type = WeaponProfile.DamageType.SCATTER
	_check_profile(first.get_weapon_profile(), baseline, "Getter mutation cannot reconfigure weapon")
	first.damage = 9
	first.attack_range = 88.0
	(first.get_node("FireTimer") as Timer).wait_time = 0.43
	var first_values := baseline.duplicate()
	first_values["damage"] = 9
	first_values["attack_range"] = 88.0
	first_values["fire_interval"] = 0.43
	_check_profile(first.get_weapon_profile(), first_values, "Legacy aliases edit only their own instance")
	_check_profile(second.get_weapon_profile(), baseline, "Sibling weapon retains shared preset values")
	_check(_values(shared) == baseline, "Weapon and getter edits cannot contaminate preset")
	shared.damage = 70
	_check_profile(first.get_weapon_profile(), first_values, "Source mutation cannot change first instance")
	_check_profile(second.get_weapon_profile(), baseline, "Source mutation cannot change second instance")
	shared.damage = baseline["damage"]
	_check(first.get_nutrition_cost() == 2, "AP weapon exposes its configured nutrition cost")
	_check(second.configure_profile(load(NORMAL_PATH) as WeaponProfile), "Sibling can select normal cost independently")
	_check(SporeWeapon.get_organ_nutrition_cost(fixture["organ"]) == 2
		and SporeWeapon.get_organ_nutrition_cost(other_pair["organ"]) == 1,
		"Cost lookup matches each sibling weapon's inventory owner")
	var old_organ := ORGAN_SCENE.instantiate() as AttackOrgan
	(fixture["world"] as Node2D).add_child(old_organ)
	_check(SporeWeapon.get_organ_nutrition_cost(old_organ) == 1, "Unarmed legacy fixture keeps cost fallback")
	await _remove_fixture(fixture)


func _test_configuration_controls_combat() -> void:
	var fixture := _build_fixture(6, 7, 100.0, 1.3)
	_mount_fixture(fixture)
	var weapon: SporeWeapon = fixture["weapon"]
	var organ: AttackOrgan = fixture["organ"]
	var projectiles: Node2D = fixture["projectiles"]
	var enemy := _add_enemy(fixture, Vector2(150, 0), 4)
	var shots := [0]
	weapon.shot_fired.connect(func(_target: BasicEnemy) -> void: shots[0] += 1)
	var normal := load(NORMAL_PATH) as WeaponProfile
	_check(weapon.configure_profile(normal), "Normal preset configuration succeeds")
	_check_profile(weapon.get_weapon_profile(), _values(normal), "Normal configuration snapshot")
	_check(weapon.damage == 12 and weapon.attack_range == 178.0
		and is_equal_approx((weapon.get_node("FireTimer") as Timer).wait_time, 0.8),
		"Configuration updates old aliases and fire timer")
	_trigger_shot(weapon)
	_check(shots[0] == 1 and projectiles.get_child_count() == 1 and organ.nutrition == 5,
		"New range selects a target outside old range and normal shot costs one")
	_check(enemy.health == 200, "Normal launch does not damage target immediately")
	await _wait_frames(50)
	_check(enemy.health == 192 and projectiles.get_child_count() == 0, "Normal preset damage is reduced by armor at hit")
	var ap := load(AP_PATH) as WeaponProfile
	_check(weapon.configure_profile(ap), "AP preset configuration succeeds")
	_check_profile(weapon.get_weapon_profile(), _values(ap), "AP configuration snapshot")
	_trigger_shot(weapon)
	_check(shots[0] == 2 and organ.nutrition == 3 and enemy.health == 192, "AP launch costs two without early damage")
	await _wait_frames(50)
	_check(enemy.health == 168, "AP profile's damage type bypasses armor")
	_trigger_shot(weapon)
	await _wait_frames(50)
	_check(enemy.health == 144 and organ.nutrition == 1, "Each AP round keeps cost two")
	_trigger_shot(weapon)
	_check(shots[0] == 3 and organ.nutrition == 1 and projectiles.get_child_count() == 0,
		"Stock below configured AP cost cannot fire or partially spend")
	await _remove_fixture(fixture)


func _test_invalid_configuration_is_atomic() -> void:
	var fixture := _build_fixture()
	_mount_fixture(fixture)
	var weapon: SporeWeapon = fixture["weapon"]
	var organ: AttackOrgan = fixture["organ"]
	var enemy := _add_enemy(fixture, Vector2(150, 0), 40)
	var ap := load(AP_PATH) as WeaponProfile
	_check(weapon.configure_profile(ap), "Atomic configuration baseline accepted")
	var baseline := _values(weapon.get_weapon_profile())
	var invalid_edits: Array[Dictionary] = [
		{"damage": 0}, {"fire_interval": INF}, {"attack_range": NAN},
		{"nutrition_cost": 0}, {"damage_type": 99}, {"damage_type": 2, "spread_angle_degrees": 0.0},
	]
	_check(not weapon.configure_profile(null), "Null configuration rejected")
	for edits: Dictionary in invalid_edits:
		var invalid := WeaponProfile.new()
		for property: String in edits:
			invalid.set(property, edits[property])
		_check(not weapon.configure_profile(invalid), "Invalid configuration rejected: %s" % edits)
		_check_profile(weapon.get_weapon_profile(), baseline, "Rejected configuration preserves active profile")
		_check(is_equal_approx((weapon.get_node("FireTimer") as Timer).wait_time, 1.8)
			and weapon.attack_range == 178.0 and weapon.damage == 24 and organ.nutrition == 6,
			"Rejected configuration preserves timer/range/damage/stock")
	_trigger_shot(weapon)
	_check(organ.nutrition == 4, "Preserved AP profile retains its cost")
	await _wait_frames(50)
	_check(enemy.health == 176, "Preserved AP profile retains its damage type and amount")
	await _remove_fixture(fixture)


func _test_scatter_configuration() -> void:
	var fixture := _build_fixture()
	_mount_fixture(fixture)
	var weapon: SporeWeapon = fixture["weapon"]
	var organ: AttackOrgan = fixture["organ"]
	var scatter := load(SCATTER_PATH) as WeaponProfile
	_check(weapon.configure_profile(scatter), "Scatter data can be stored")
	_check_profile(weapon.get_weapon_profile(), _values(scatter), "Scatter full cone is stored as 60 degrees")
	_check(organ.nutrition == 6 and (fixture["projectiles"] as Node2D).get_child_count() == 0,
		"Applying scatter config alone cannot spend/refill stock or fire")
	_check(organ.get_shot_nutrition_cost() == 1, "Scatter price describes a whole round, not each pellet")
	_check(weapon.configure_profile(load(NORMAL_PATH) as WeaponProfile), "Normal configuration resumes after stored scatter")
	_check(organ.nutrition == 6, "Repeated configuration cannot reinitialize inventory")
	# 8.2 的真实扇形发射与扣费在 weapon_behavior/combat_nutrition 两组独立验证。
	await _remove_fixture(fixture)
