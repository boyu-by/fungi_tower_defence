extends SceneTree
## 验证护甲结算、发射快照、重入防护和真实死亡/尸体生命周期。

const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/spore_projectile.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")

# 在受伤入口同步重入真实弹丸，观察其是否已经结束；不读取内部命中标记。
class ReentrantEnemy:
	extends BasicEnemy
	var projectile: SporeProjectile
	var damage_calls: int = 0
	var _has_reentered: bool = false

	func apply_damage(request: Dictionary) -> int:
		damage_calls += 1
		if not _has_reentered and is_instance_valid(projectile):
			_has_reentered = true
			projectile._physics_process(1.0)
		return super.apply_damage(request)


var failures: Array[String] = []
var checks: int = 0
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	_test_armor_assignment_and_unready_estimates()
	await _test_armor_damage_matrix()
	await _test_invalid_requests_and_queued_enemy()
	await _test_capped_loss_and_single_remains()
	await _test_launch_rejections_do_not_consume_slot()
	await _test_launch_snapshot_and_no_penetration()
	await _test_duplicate_and_reentrant_hit()
	await _test_missing_and_dead_targets()
	await _test_legacy_damage_and_launch()
	_check(root.get_child_count() == _initial_root_children, "Armor fixtures left orphan nodes")
	print("ARMOR_DAMAGE_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _request(raw_damage: int = 12, damage_type: int = 0) -> Dictionary:
	return {"raw_damage": raw_damage, "damage_type": damage_type}


func _invalid_requests() -> Array[Dictionary]:
	return [
		{}, {"raw_damage": 12}, {"damage_type": 0},
		{"raw_damage": 0, "damage_type": 0}, {"raw_damage": -1, "damage_type": 0},
		{"raw_damage": 12.0, "damage_type": 0}, {"raw_damage": true, "damage_type": 0},
		{"raw_damage": "12", "damage_type": 0}, {"raw_damage": null, "damage_type": 0},
		{"raw_damage": [], "damage_type": 0}, {"raw_damage": {}, "damage_type": 0},
		{"raw_damage": NAN, "damage_type": 0}, {"raw_damage": INF, "damage_type": 0},
		{"raw_damage": 12, "damage_type": -1}, {"raw_damage": 12, "damage_type": 3},
		{"raw_damage": 12, "damage_type": 99}, {"raw_damage": 12, "damage_type": 0.0},
		{"raw_damage": 12, "damage_type": false}, {"raw_damage": 12, "damage_type": "0"},
		{"raw_damage": 12, "damage_type": null}, {"raw_damage": 12, "damage_type": INF},
	]


func _new_fixture() -> Dictionary:
	var world := Node2D.new()
	var enemies := Node2D.new()
	var projectiles := Node2D.new()
	var remains := Node2D.new()
	world.add_child(enemies)
	world.add_child(projectiles)
	world.add_child(remains)
	var spawner := RemainsSpawner.new()
	spawner.enemy_container = enemies
	spawner.remains_container = remains
	spawner.remains_scene = REMAINS_SCENE
	world.add_child(spawner)
	root.add_child(world)
	current_scene = world
	return {"world": world, "enemies": enemies, "projectiles": projectiles, "remains": remains}


func _remove_fixture(fixture: Dictionary) -> void:
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame


func _add_enemy(fixture: Dictionary, health_value: int = 100, armor_value: int = 0,
		position: Vector2 = Vector2(120, 52)) -> BasicEnemy:
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = health_value
	enemy.armor = armor_value
	enemy.move_speed = 0.0
	enemy.remains_nutrition = 7
	var enemies: Node2D = fixture["enemies"]
	enemies.add_child(enemy)
	enemy.global_position = position
	return enemy


func _add_projectile(fixture: Dictionary) -> SporeProjectile:
	var projectile := PROJECTILE_SCENE.instantiate() as SporeProjectile
	var projectiles: Node2D = fixture["projectiles"]
	projectiles.add_child(projectile)
	projectile.global_position = Vector2.ZERO
	return projectile


func _test_armor_assignment_and_unready_estimates() -> void:
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	_check(enemy.armor == 0, "Legacy enemy has zero armor by default")
	enemy.armor = -1
	_check(enemy.armor == 0, "Negative assignment retains initial armor")
	enemy.armor = 4
	enemy.armor = -20
	_check(enemy.armor == 4, "Negative assignment retains previous positive armor")
	_check(enemy.health == 0 and enemy.estimate_damage(_request()) == 8,
		"Unready zero-health enemy provides a pure uncapped estimate")
	enemy.health = 1
	for repeat in range(3):
		_check(enemy.estimate_damage(_request()) == 8 and enemy.health == 1,
			"Repeated estimates ignore remaining HP and leave it untouched")
	enemy.armor = 0
	_check(enemy.armor == 0 and enemy.estimate_damage(_request()) == 12, "Armor can be reset to zero")
	enemy.free()


func _test_armor_damage_matrix() -> void:
	var fixture := _new_fixture()
	var rows: Array[Dictionary] = [
		{"armor": 0, "expected": [12, 12, 12]},
		{"armor": 4, "expected": [8, 12, 8]},
		{"armor": 20, "expected": [1, 12, 1]},
	]
	var deaths := [0]
	for row: Dictionary in rows:
		for damage_type in range(3):
			var armor_value: int = row["armor"]
			var expected: int = row["expected"][damage_type]
			var enemy := _add_enemy(fixture, 100, armor_value)
			enemy.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
			var request := _request(12, damage_type)
			var label := "Armor %d / damage type %d" % [armor_value, damage_type]
			for repeat in range(3):
				_check(enemy.estimate_damage(request) == expected, label + ": deterministic estimate")
			_check(enemy.health == 100 and enemy.health_bar.value == 100 and enemy.is_alive(),
				label + ": estimate has no health/UI/lifecycle side effects")
			_check(enemy.apply_damage(request) == expected and enemy.health == 100 - expected,
				label + ": actual HP loss agrees with mitigation")
			_check(enemy.health_bar.value == enemy.health and enemy.estimate_damage(request) == expected,
				label + ": UI updates and later estimate remains uncapped")
			_check(request == _request(12, damage_type), label + ": request not mutated")
	_check(deaths[0] == 0 and (fixture["remains"] as Node2D).get_child_count() == 0,
		"Nonlethal damage and pure estimates create no death/corpse")
	await _remove_fixture(fixture)


func _test_invalid_requests_and_queued_enemy() -> void:
	var fixture := _new_fixture()
	var enemy := _add_enemy(fixture, 100, 4)
	var deaths := [0]
	enemy.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
	for request: Dictionary in _invalid_requests():
		_check(enemy.estimate_damage(request) == 0, "Invalid request has zero estimate: %s" % request)
		_check(enemy.apply_damage(request) == 0, "Invalid request has zero actual loss: %s" % request)
		_check(enemy.health == 100 and enemy.health_bar.value == 100 and enemy.is_alive(),
			"Invalid request preserves live health and UI")
	var extra: Dictionary = {"raw_damage": 12, "damage_type": 0, "unused": {"anything": true}}
	_check(enemy.estimate_damage(extra) == 8 and enemy.apply_damage(extra) == 8,
		"Valid damage request ignores unrelated extra fields")
	enemy.queue_free()
	_check(enemy.apply_damage(_request(999, 1)) == 0 and enemy.health == 92,
		"Queued live enemy cannot lose more health")
	_check(enemy.estimate_damage(_request()) == 8, "Pure estimate is independent of queued state")
	await _wait_frames(2)
	_check(deaths[0] == 0 and (fixture["remains"] as Node2D).get_child_count() == 0,
		"Invalid requests and removing a live enemy create no remains")
	await _remove_fixture(fixture)


func _test_capped_loss_and_single_remains() -> void:
	var fixture := _new_fixture()
	var remains: Node2D = fixture["remains"]
	var estimates: Array[int] = [8, 12, 8]
	var killed: Array[BasicEnemy] = []
	for damage_type in range(3):
		var death_position := Vector2(80 + damage_type * 50, 52)
		var enemy := _add_enemy(fixture, 3, 4, death_position)
		killed.append(enemy)
		var deaths := [0]
		enemy.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
		var request := _request(12, damage_type)
		_check(enemy.estimate_damage(request) == estimates[damage_type], "Estimate remains uncapped for low HP")
		_check(enemy.apply_damage(request) == 3 and enemy.health == 0, "Lethal result reports only actual remaining HP")
		_check(enemy.estimate_damage(request) == estimates[damage_type], "Dead enemy still gives health-independent estimate")
		_check(enemy.apply_damage(request) == 0 and enemy.apply_damage(_request(999, 1)) == 0,
			"Dead enemy rejects repeated normal and AP application")
		enemy.take_damage(999)
		_check(deaths[0] == 1 and not enemy.is_alive(), "Lethal damage emits one death signal")
		_check(remains.get_child_count() == damage_type + 1, "Real RemainsSpawner makes one corpse per enemy")
		var corpse := remains.get_child(damage_type) as EnemyRemains
		_check(corpse != null and corpse.nutrition_value == 7 and corpse.global_position == death_position,
			"Real corpse preserves nutrition and death position")
	await _wait_frames(24)
	for enemy: BasicEnemy in killed:
		_check(not is_instance_valid(enemy), "Dead enemy finishes its fade and removal")
	_check(remains.get_child_count() == 3, "Removal does not duplicate death remains")
	await _remove_fixture(fixture)


func _test_launch_rejections_do_not_consume_slot() -> void:
	var fixture := _new_fixture()
	var target := _add_enemy(fixture, 100, 4)
	var projectile := _add_projectile(fixture)
	for request: Dictionary in _invalid_requests():
		_check(not projectile.launch_request(target, request), "Malformed launch request is rejected: %s" % request)
	_check(not projectile.launch_request(null, _request()), "Null target is rejected without launch")
	var outside_tree := ENEMY_SCENE.instantiate() as BasicEnemy
	outside_tree.health = 100
	_check(not projectile.launch_request(outside_tree, _request()), "Live-looking target outside tree is rejected")
	outside_tree.free()
	var dead := _add_enemy(fixture)
	dead.apply_damage(_request(100, 1))
	_check(not projectile.launch_request(dead, _request()), "Dead target is rejected without launch")
	var queued := _add_enemy(fixture)
	queued.queue_free()
	_check(not projectile.launch_request(queued, _request()), "Queued target is rejected without launch")
	_check(projectile.launch_request(target, _request()), "Same projectile accepts valid launch after all rejections")
	_check(not projectile.launch_request(target, _request(99, 1)), "Successful launch occupies slot exactly once")
	_check(target.health == 100, "Rejected and valid launches cause no immediate damage")
	await _wait_frames(50)
	_check(target.health == 92 and not is_instance_valid(projectile), "One valid launch eventually deals one normal hit")
	await _remove_fixture(fixture)


func _test_launch_snapshot_and_no_penetration() -> void:
	var fixture := _new_fixture()
	var target := _add_enemy(fixture, 100, 40, Vector2(240, 52))
	var bystander := _add_enemy(fixture, 100, 0, Vector2(120, 52))
	var profile := WeaponProfile.new()
	profile.damage = 24
	profile.damage_type = WeaponProfile.DamageType.ARMOR_PIERCING
	var request: Dictionary = profile.create_damage_request()
	var projectile := _add_projectile(fixture)
	_check(projectile.launch_request(target, request), "AP request launches")
	_check(target.health == 100 and bystander.health == 100, "Launch does not settle damage before travel")
	request["raw_damage"] = 1
	request["damage_type"] = 0
	profile.damage = 90
	profile.damage_type = WeaponProfile.DamageType.SCATTER
	profile.spread_angle_degrees = 60.0
	_check(not projectile.launch_request(bystander, _request(99, 1)), "Later launch cannot replace target or damage")
	await _wait_frames(2)
	_check(target.health == 100, "Projectile still traveling has not damaged target")
	await _wait_frames(60)
	_check(target.health == 76, "Old projectile retains AP type and raw damage despite request/profile mutation")
	_check(bystander.health == 100, "AP projectile passes through an intervening enemy without penetration damage")
	_check(not is_instance_valid(projectile), "Hit projectile is removed")
	await _wait_frames(6)
	_check(target.health == 76, "Completed projectile never repeats damage")
	await _remove_fixture(fixture)


func _test_duplicate_and_reentrant_hit() -> void:
	var fixture := _new_fixture()
	var instance: Node = ENEMY_SCENE.instantiate()
	instance.set_script(ReentrantEnemy)
	var enemy := instance as ReentrantEnemy
	enemy.max_health = 100
	enemy.armor = 4
	enemy.move_speed = 0.0
	(fixture["enemies"] as Node2D).add_child(enemy)
	enemy.global_position = Vector2(40, 52)
	var projectile := _add_projectile(fixture)
	enemy.projectile = projectile
	_check(projectile.launch_request(enemy, _request()), "Reentrant fixture accepts valid launch")
	# 驱动一次足以抵达目标的物理更新；受伤回调会在返回前再次驱动更新。
	projectile._physics_process(1.0)
	_check(enemy.damage_calls == 1 and enemy.health == 92, "Hit finishes before applying damage, preventing synchronous reentry")
	projectile._physics_process(1.0)
	projectile._physics_process(1.0)
	_check(enemy.damage_calls == 1 and enemy.health == 92, "Duplicate callbacks before deferred free cannot hit twice")
	_check(not projectile.launch_request(enemy, _request()), "Finished projectile cannot launch again")
	await _wait_frames(2)
	_check(not is_instance_valid(projectile) and (fixture["remains"] as Node2D).get_child_count() == 0,
		"Single nonlethal reentrant hit cleans projectile without a corpse")
	await _remove_fixture(fixture)


func _test_missing_and_dead_targets() -> void:
	var fixture := _new_fixture()
	var target := _add_enemy(fixture, 100, 0, Vector2(240, 52))
	var bystander := _add_enemy(fixture, 100, 0, Vector2(120, 52))
	var deaths := [0]
	target.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
	var projectile := _add_projectile(fixture)
	_check(projectile.launch_request(target, _request(24, 1)), "Missing-target fixture launches")
	target.queue_free()
	await _wait_frames(4)
	_check(not is_instance_valid(projectile) and bystander.health == 100,
		"Removed target dissipates projectile without retargeting")
	_check(deaths[0] == 0 and (fixture["remains"] as Node2D).get_child_count() == 0,
		"Removing live target creates no death damage or corpse")
	await _remove_fixture(fixture)
	fixture = _new_fixture()
	target = _add_enemy(fixture, 100, 0, Vector2(240, 52))
	bystander = _add_enemy(fixture, 100, 0, Vector2(120, 52))
	deaths = [0]
	target.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
	projectile = _add_projectile(fixture)
	_check(projectile.launch_request(target, _request(24, 1)), "Dead-target fixture launches")
	_check(target.apply_damage(_request(100, 1)) == 100, "Another damage source kills target before projectile arrives")
	await _wait_frames(4)
	_check(not is_instance_valid(projectile) and bystander.health == 100, "Dead target dissipates projectile without a new hit")
	await _wait_frames(24)
	_check(deaths[0] == 1 and (fixture["remains"] as Node2D).get_child_count() == 1,
		"Lost dead-target projectile cannot repeat death or produce another corpse")
	await _remove_fixture(fixture)


func _test_legacy_damage_and_launch() -> void:
	var fixture := _new_fixture()
	var enemy := _add_enemy(fixture, 100, 4)
	enemy.take_damage(0)
	enemy.take_damage(-1)
	_check(enemy.health == 100, "Legacy take_damage ignores nonpositive amounts")
	enemy.take_damage(12)
	_check(enemy.health == 92, "Legacy take_damage uses normal armor mitigation")
	enemy.armor = 20
	enemy.take_damage(1)
	_check(enemy.health == 91, "Legacy normal damage keeps minimum one against high armor")
	enemy.armor = 4
	var projectile := _add_projectile(fixture)
	projectile.launch(enemy, 0)
	projectile.launch(enemy, 12)
	projectile.launch(enemy, 99)
	_check(enemy.health == 91, "Legacy launch preserves delayed impact")
	await _wait_frames(50)
	_check(enemy.health == 83 and not is_instance_valid(projectile), "Legacy launch deals one normal hit after invalid retry")
	var deaths := [0]
	enemy.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
	enemy.take_damage(999)
	enemy.take_damage(999)
	_check(enemy.health == 0 and deaths[0] == 1 and (fixture["remains"] as Node2D).get_child_count() == 1,
		"Legacy lethal damage keeps exactly one death and real corpse")
	await _remove_fixture(fixture)
