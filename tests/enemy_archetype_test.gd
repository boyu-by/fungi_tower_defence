extends SceneTree
## 真实继承场景的参数、视觉、接触攻击、受伤与唯一尸体生命周期。

const NORMAL_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const SWARM_SCENE: PackedScene = preload("res://scenes/enemies/swarm_enemy.tscn")
const ARMORED_SCENE: PackedScene = preload("res://scenes/enemies/armored_enemy.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/spore_projectile.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")

class Fixture:
	extends RefCounted
	var world: Node2D
	var enemies: Node2D
	var projectiles: Node2D
	var remains: Node2D
	var core: MotherCore


var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {}
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_inherited_profiles_and_shapes()
	await _test_explicit_overrides_and_snapshot()
	await _test_live_armor_hint()
	await _test_ground_movement_and_real_attack_timer()
	await _test_diagonal_contact_rounding_and_real_attack()
	await _test_repeated_damage_and_one_actual_corpse()
	await _test_locked_projectiles()
	_check(root.get_child_count() == _initial_root_children, "All archetype fixtures leave the tree")
	print("ENEMY_ARCHETYPE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _rows() -> Array[Dictionary]:
	return [
		{"label": "normal", "scene": NORMAL_SCENE, "archetype": BasicEnemy.Archetype.NORMAL,
			"max_health": 24, "armor": 0, "move_speed": 52.0, "attack_damage": 12},
		{"label": "swarm", "scene": SWARM_SCENE, "archetype": BasicEnemy.Archetype.SWARM,
			"max_health": 12, "armor": 0, "move_speed": 66.0, "attack_damage": 6},
		{"label": "armored", "scene": ARMORED_SCENE, "archetype": BasicEnemy.Archetype.ARMORED,
			"max_health": 72, "armor": 4, "move_speed": 26.0, "attack_damage": 15},
	]


func _expected_snapshot(row: Dictionary) -> Dictionary:
	return {"archetype": int(row["archetype"]), "max_health": row["max_health"],
		"armor": row["armor"], "move_speed": row["move_speed"],
		"attack_damage": row["attack_damage"], "attack_interval": 1.0, "remains_nutrition": 4}


func _request(raw_damage: int = 12,
		damage_type: int = WeaponProfile.DamageType.NORMAL) -> Dictionary:
	return {"raw_damage": raw_damage, "damage_type": damage_type}


func _new_fixture() -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.remains = Node2D.new()
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.position = Vector2(300, 240)
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.projectiles)
	fixture.world.add_child(fixture.remains)
	fixture.world.add_child(fixture.core)
	var spawner := RemainsSpawner.new()
	spawner.enemy_container = fixture.enemies
	spawner.remains_container = fixture.remains
	spawner.remains_scene = REMAINS_SCENE
	fixture.world.add_child(spawner)
	root.add_child(fixture.world)
	current_scene = fixture.world
	return fixture


func _dispose(fixture: Fixture) -> void:
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _add_enemy(fixture: Fixture, scene: PackedScene,
		position_value: Vector2 = Vector2(120, 52)) -> BasicEnemy:
	var enemy := scene.instantiate() as BasicEnemy
	enemy.position = position_value
	fixture.enemies.add_child(enemy)
	# 仅手动驱动敌人移动，AttackTimer 保持真实物理计时。
	enemy.set_physics_process(false)
	return enemy


func _polygon_width(points: PackedVector2Array) -> float:
	if points.is_empty():
		return 0.0
	var left := points[0].x
	var right := left
	for point: Vector2 in points:
		left = minf(left, point.x)
		right = maxf(right, point.x)
	return right - left


func _test_inherited_profiles_and_shapes() -> void:
	var fixture := _new_fixture()
	var base := _add_enemy(fixture, NORMAL_SCENE)
	var base_shadow := base.get_node("Visuals/Shadow") as Polygon2D
	var observations: Array[Dictionary] = []
	for row: Dictionary in _rows():
		var label: String = row["label"]
		var scene: PackedScene = row["scene"]
		var unready := scene.instantiate() as BasicEnemy
		_check(unready.get_archetype_snapshot() == _expected_snapshot(row),
			label + " exposes authored parameters before ready")
		_check(unready.health == 0 and not unready.is_attacking_core()
			and is_inf(unready.get_core_distance_squared()), label + " unready queries are pure")
		unready.free()
		var enemy := _add_enemy(fixture, scene)
		var snapshot := enemy.get_archetype_snapshot()
		_check(enemy.get_archetype() == int(row["archetype"]) and snapshot == _expected_snapshot(row),
			label + " ready instance retains its full archetype profile")
		_check(snapshot.size() == 7 and typeof(snapshot["archetype"]) == TYPE_INT
			and typeof(snapshot["attack_interval"]) == TYPE_FLOAT, label + " snapshot has the frozen scalar contract")
		_check(enemy.health == int(row["max_health"]) and enemy.health_bar.max_value == enemy.max_health
			and enemy.health_bar.value == enemy.health, label + " ready initializes actual HP and health bar")
		_check(enemy.get_script() == base.get_script() and enemy.sprite.sprite_frames == base.sprite.sprite_frames,
			label + " shares the existing enemy code and animation resource")
		_check(enemy.scale == Vector2.ONE and enemy.visuals.scale == Vector2.ONE
			and enemy.contact_range == base.contact_range, label + " preserves ground scale and contact distance")
		_check(enemy.attack_timer.wait_time == 1.0
			and enemy.attack_timer.process_callback == Timer.TIMER_PROCESS_PHYSICS,
			label + " inherits one-second physics attack timing")
		if enemy.get_archetype() == BasicEnemy.Archetype.SWARM:
			var shadow := enemy.get_node("Visuals/Shadow") as Polygon2D
			_check(enemy.sprite.scale.x < base.sprite.scale.x and enemy.sprite.scale.y < base.sprite.scale.y
				and _polygon_width(shadow.polygon) < _polygon_width(base_shadow.polygon),
				"Swarm shrinks only its rendered body and shadow")
		elif enemy.get_archetype() == BasicEnemy.Archetype.ARMORED:
			var outline := enemy.get_node_or_null("Visuals/ArmorOutline") as Polygon2D
			var rim := enemy.get_node_or_null("Visuals/ArmorRim") as Line2D
			_check(is_instance_valid(outline) and is_instance_valid(rim), "Armored instance has its heavy silhouette")
			if is_instance_valid(outline) and is_instance_valid(rim):
				_check(_polygon_width(outline.polygon) > _polygon_width(base_shadow.polygon)
					and rim.width >= 4.0 and rim.closed, "Armored contour is visibly broad and thick")
		observations.append({"label": label, "snapshot": snapshot,
			"sprite_scale": [enemy.sprite.scale.x, enemy.sprite.scale.y],
			"ground_contact_range": enemy.contact_range})
	evidence["scene_parameters"] = observations
	await _dispose(fixture)


func _test_explicit_overrides_and_snapshot() -> void:
	var fixture := _new_fixture()
	var enemy := NORMAL_SCENE.instantiate() as BasicEnemy
	enemy.max_health = 91
	enemy.armor = 3
	enemy.move_speed = 17.0
	enemy.attack_damage = 9
	enemy.contact_range = 37.0
	enemy.remains_nutrition = 11
	var timer := enemy.get_node("AttackTimer") as Timer
	timer.wait_time = 1.75
	enemy.archetype = BasicEnemy.Archetype.SWARM
	var expected := {"archetype": BasicEnemy.Archetype.SWARM, "max_health": 91,
		"armor": 3, "move_speed": 17.0, "attack_damage": 9, "attack_interval": 1.75,
		"remains_nutrition": 11}
	_check(enemy.get_archetype_snapshot() == expected, "Changing an unready normal scene tag retains explicit overrides")
	fixture.enemies.add_child(enemy)
	enemy.set_physics_process(false)
	_check(enemy.get_archetype_snapshot() == expected and enemy.health == 91 and enemy.contact_range == 37.0,
		"Ready does not replace an explicitly configured normal scene with archetype defaults")
	enemy.archetype = BasicEnemy.Archetype.ARMORED
	expected["archetype"] = BasicEnemy.Archetype.ARMORED
	_check(enemy.get_archetype_snapshot() == expected, "Changing a live tag also preserves authored combat parameters")
	var snapshot := enemy.get_archetype_snapshot()
	snapshot["max_health"] = 1
	snapshot["armor"] = 99
	snapshot["attack_interval"] = 99.0
	_check(enemy.get_archetype_snapshot() == expected and enemy.health == 91,
		"Mutating a returned snapshot cannot mutate the enemy")
	timer.wait_time = 2.25
	expected["attack_interval"] = 2.25
	_check(enemy.get_archetype_snapshot() == expected, "Snapshot reads a later change from the existing AttackTimer")
	_check(not enemy.has_node("Visuals/ArmorHint") and enemy.estimate_damage(_request()) == 9,
		"Explicit armor on a normal scene works without an optional armor hint")
	evidence["explicit_normal_overrides"] = enemy.get_archetype_snapshot()
	await _dispose(fixture)


func _test_live_armor_hint() -> void:
	var fixture := _new_fixture()
	var default_enemy := _add_enemy(fixture, ARMORED_SCENE)
	var default_hint := default_enemy.get_node("Visuals/ArmorHint") as CanvasItem
	var default_value := default_hint.get_node("Value") as Label
	_check(default_hint.visible and default_value.text == "4", "Authored armored enemy displays its real initial armor")
	var enemy := ARMORED_SCENE.instantiate() as BasicEnemy
	enemy.armor = 0
	fixture.enemies.add_child(enemy)
	enemy.set_physics_process(false)
	var hint := enemy.get_node("Visuals/ArmorHint") as CanvasItem
	var value_label := hint.get_node("Value") as Label
	_check(not hint.visible and value_label.text == "0" and enemy.estimate_damage(_request()) == 12,
		"Armor overridden before ready hides the shield and removes mitigation")
	enemy.armor = 7
	_check(hint.visible and value_label.text == "7" and enemy.estimate_damage(_request()) == 5
		and int(enemy.get_archetype_snapshot()["armor"]) == 7, "Armor setter updates hint, snapshot and real mitigation together")
	var positive_override_label := value_label.text
	enemy.armor = -20
	_check(enemy.armor == 7 and hint.visible and value_label.text == "7", "Rejected negative armor cannot corrupt the live hint")
	enemy.armor = 0
	_check(not hint.visible and value_label.text == "0", "Resetting armor to zero hides its hint immediately")
	var zero_hides := not hint.visible
	enemy.armor = 4
	_check(hint.visible and value_label.text == "4"
		and enemy.estimate_damage(_request(12, WeaponProfile.DamageType.ARMOR_PIERCING)) == 12,
		"Restored armor displays four while AP remains compatible")
	evidence["armor_hint"] = {"initial": default_enemy.armor, "initial_visible": default_hint.visible,
		"positive_override_label": positive_override_label, "zero_hides": zero_hides,
		"restored": enemy.armor, "restored_label": value_label.text}
	await _dispose(fixture)


func _test_ground_movement_and_real_attack_timer() -> void:
	var observations: Array[Dictionary] = []
	for row: Dictionary in _rows():
		var fixture := _new_fixture()
		var label: String = row["label"]
		var scene: PackedScene = row["scene"]
		var enemy := _add_enemy(fixture, scene)
		enemy.mother_core = fixture.core
		enemy.global_position = fixture.core.global_position + Vector2(enemy.contact_range + enemy.move_speed * 2.0, 0)
		var starting_distance := enemy.global_position.distance_to(fixture.core.global_position)
		var core_health := fixture.core.health
		var core_hits := [0]
		fixture.core.health_changed.connect(func(_health: int, _maximum: int) -> void: core_hits[0] += 1)
		enemy._physics_process(0.5)
		var moved := starting_distance - enemy.global_position.distance_to(fixture.core.global_position)
		_check(is_equal_approx(moved, enemy.move_speed * 0.5) and enemy.attack_timer.is_stopped(),
			label + " moves by its real world speed while outside contact")
		enemy._physics_process(100.0)
		_check(is_equal_approx(enemy.global_position.distance_to(fixture.core.global_position), enemy.contact_range)
			and is_equal_approx(enemy.get_core_distance_squared(), enemy.contact_range * enemy.contact_range),
			label + " clamps at the shared ground contact distance without overshoot")
		enemy._physics_process(0.0)
		_check(enemy.is_attacking_core() and is_equal_approx(enemy.attack_timer.time_left, 1.0)
			and fixture.core.health == core_health, label + " contact starts one-second timing without immediate damage")
		await create_timer(0.75, false, true).timeout
		_check(core_hits[0] == 0 and fixture.core.health == core_health, label + " cannot attack before one second")
		await create_timer(0.4, false, true).timeout
		_check(core_hits[0] == 1 and fixture.core.health == core_health - enemy.attack_damage,
			label + " first real timer timeout damages only the mother core")
		await create_timer(1.0, false, true).timeout
		_check(core_hits[0] == 2 and fixture.core.health == core_health - enemy.attack_damage * 2,
			label + " repeats its configured damage at one-second intervals")
		enemy.attack_timer.paused = true
		_check(not enemy.is_attacking_core(), label + " paused attacks do not report a live core threat")
		enemy.attack_timer.paused = false
		enemy.global_position += Vector2(10, 0)
		enemy._physics_process(0.0)
		_check(enemy.attack_timer.is_stopped() and not enemy.is_attacking_core(),
			label + " leaving ground contact stops attacking")
		_check(fixture.remains.get_child_count() == 0 and fixture.core.nutrition == fixture.core.initial_nutrition,
			label + " movement and core attacks create no corpse or extra yield")
		observations.append({"label": label, "move_in_half_second": moved,
			"contact_range": enemy.contact_range, "attack_interval": enemy.attack_timer.wait_time,
			"core_hits": core_hits[0], "core_health_lost": core_health - fixture.core.health})
		await _dispose(fixture)
	evidence["movement_and_core_attacks"] = observations


func _test_diagonal_contact_rounding_and_real_attack() -> void:
	var fixture := _new_fixture()
	fixture.core.global_position = Vector2(600, 560)
	# 回放混合批次已实测的完整重甲出生路线，保留原速度与母核坐标。
	var enemy := _add_enemy(fixture, ARMORED_SCENE, Vector2(260, 300))
	enemy.mother_core = fixture.core
	var start_position := enemy.global_position
	var start_offset := start_position - fixture.core.global_position
	var minimum_distance := start_offset.length()
	var core_health := fixture.core.health
	var core_hits := [0]
	fixture.core.health_changed.connect(func(_health: int, _maximum: int) -> void: core_hits[0] += 1)
	enemy.set_physics_process(true)
	var arrived := false
	var arrival_distance := minimum_distance
	var travel_frames: int = 0
	var max_frames := ceili(20.0 * Engine.physics_ticks_per_second)
	for _frame: int in range(max_frames):
		await physics_frame
		travel_frames += 1
		var distance := enemy.global_position.distance_to(fixture.core.global_position)
		minimum_distance = minf(minimum_distance, distance)
		if distance <= enemy.contact_range + BasicEnemy.CONTACT_TOLERANCE:
			arrived = true
			arrival_distance = distance
			break
	_check(arrived and enemy.global_position != start_position and enemy.move_speed == 26.0,
		"Armored enemy reaches contact through actual diagonal physics movement")
	_check(arrival_distance > enemy.contact_range
		and arrival_distance <= enemy.contact_range + BasicEnemy.CONTACT_TOLERANCE,
		"Actual diagonal arrival retains the slightly-outside-contact floating-point boundary")
	for _frame: int in range(4):
		if not enemy.attack_timer.is_stopped():
			break
		await physics_frame
	_check(enemy.is_attacking_core() and not enemy.attack_timer.is_stopped()
		and enemy.attack_timer.wait_time == 1.0 and enemy.attack_timer.time_left >= 0.94,
		"Rounded diagonal arrival starts the real one-second attack timer")
	_check(core_hits[0] == 0 and fixture.core.health == core_health,
		"Rounded contact does not deal immediate mother-core damage")
	await create_timer(0.75, false, true).timeout
	_check(core_hits[0] == 0 and fixture.core.health == core_health,
		"Rounded contact still waits for the one-second attack interval")
	await create_timer(0.4, false, true).timeout
	_check(core_hits[0] == 1 and fixture.core.health == core_health - enemy.attack_damage,
		"Rounded diagonal contact delivers one real timed armored attack")
	var final_offset := enemy.global_position - fixture.core.global_position
	minimum_distance = minf(minimum_distance, final_offset.length())
	_check(minimum_distance >= enemy.contact_range - BasicEnemy.CONTACT_TOLERANCE
		and final_offset.dot(start_offset) > 0.0,
		"Contact tolerance preserves the ground stopping point without crossing the mother core")
	evidence["diagonal_contact_rounding"] = {"arrival_distance": arrival_distance,
		"contact_range": enemy.contact_range, "minimum_ground_distance": minimum_distance,
		"spawn_position": [start_position.x, start_position.y],
		"core_position": [fixture.core.global_position.x, fixture.core.global_position.y],
		"move_speed": enemy.move_speed,
		"arrival_elapsed_seconds": float(travel_frames) / float(Engine.physics_ticks_per_second),
		"attack_interval": enemy.attack_timer.wait_time, "core_hits": core_hits[0],
		"core_health_lost": core_health - fixture.core.health,
		"final_ground_position": [enemy.global_position.x, enemy.global_position.y]}
	await _dispose(fixture)


func _test_repeated_damage_and_one_actual_corpse() -> void:
	var observations: Array[Dictionary] = []
	for row: Dictionary in _rows():
		var fixture := _new_fixture()
		var label: String = row["label"]
		var scene: PackedScene = row["scene"]
		var death_position := Vector2(144, 96)
		var enemy := _add_enemy(fixture, scene, death_position)
		var initial_health := enemy.health
		var expected_loss := maxi(1, 2 - enemy.armor)
		var deaths := [0]
		var reentrant_losses: Array[int] = []
		enemy.died.connect(func(dying: BasicEnemy) -> void:
			deaths[0] += 1
			reentrant_losses.append(dying.apply_damage(_request(999, WeaponProfile.DamageType.ARMOR_PIERCING))))
		_check(enemy.estimate_damage(_request(2)) == expected_loss and enemy.health == initial_health,
			label + " damage estimate remains pure and uses real armor")
		for repeat: int in range(2):
			_check(enemy.apply_damage(_request(2)) == expected_loss
				and enemy.health == initial_health - expected_loss * (repeat + 1)
				and enemy.health_bar.value == enemy.health, label + " accepts repeated real nonlethal damage")
		_check(deaths[0] == 0 and fixture.remains.get_child_count() == 0, label + " repeated nonlethal hits create no corpse")
		var remaining_health := enemy.health
		var lethal_loss := enemy.apply_damage(_request(999, WeaponProfile.DamageType.ARMOR_PIERCING))
		_check(lethal_loss == remaining_health,
			label + " lethal hit returns only actual remaining HP")
		_check(enemy.apply_damage(_request(999)) == 0
			and enemy.apply_damage(_request(999, WeaponProfile.DamageType.ARMOR_PIERCING)) == 0,
			label + " repeated lethal requests do not settle twice")
		enemy.take_damage(999)
		_check(deaths[0] == 1 and reentrant_losses == [0] and not enemy.is_alive()
			and enemy.attack_timer.is_stopped() and not enemy.health_bar.visible,
			label + " dies once even with synchronous damage reentry")
		_check(fixture.remains.get_child_count() == 1, label + " actual RemainsSpawner creates exactly one corpse")
		var corpse: EnemyRemains = fixture.remains.get_child(0) as EnemyRemains if fixture.remains.get_child_count() > 0 else null
		_check(is_instance_valid(corpse) and corpse.nutrition_value == 4
			and corpse.global_position == death_position, label + " real corpse keeps four nutrition at the ground death position")
		await create_timer(0.35).timeout
		_check(not is_instance_valid(enemy) and deaths[0] == 1 and fixture.remains.get_child_count() == 1,
			label + " inherited fade removes the enemy without duplicating remains")
		observations.append({"label": label, "nonlethal_hit_loss": expected_loss,
			"lethal_health_loss": lethal_loss, "death_signals": deaths[0],
			"actual_corpses": fixture.remains.get_child_count(),
			"corpse_nutrition": corpse.nutrition_value if is_instance_valid(corpse) else -1})
		await _dispose(fixture)
	evidence["repeated_damage_and_remains"] = observations


func _test_locked_projectiles() -> void:
	var observations: Array[Dictionary] = []
	for row: Dictionary in _rows():
		var fixture := _new_fixture()
		var label: String = row["label"]
		var scene: PackedScene = row["scene"]
		var target := _add_enemy(fixture, scene)
		var bystander := _add_enemy(fixture, NORMAL_SCENE, Vector2(240, 52))
		var health_before := target.health
		var request := _request(6)
		var expected_loss := target.estimate_damage(request)
		var projectile := PROJECTILE_SCENE.instantiate() as SporeProjectile
		fixture.projectiles.add_child(projectile)
		projectile.global_position = target.get_aim_position() - Vector2(60, 0)
		_check(projectile.launch_request(target, request), label + " is a valid real projectile target")
		request["raw_damage"] = 999
		request["damage_type"] = WeaponProfile.DamageType.ARMOR_PIERCING
		_check(not projectile.launch_request(bystander, request), label + " locked projectile refuses a replacement target")
		projectile._physics_process(1.0)
		projectile._physics_process(1.0)
		var actual_hit_loss := health_before - target.health
		_check(target.health == health_before - expected_loss and bystander.health == bystander.max_health
			and projectile.is_queued_for_deletion(), label + " frozen projectile deals one armor-aware hit to its original target")
		var lost_target_projectile := PROJECTILE_SCENE.instantiate() as SporeProjectile
		fixture.projectiles.add_child(lost_target_projectile)
		_check(lost_target_projectile.launch_request(target, _request(6)), label + " can receive another locked flight")
		target.take_damage(999)
		lost_target_projectile._physics_process(1.0)
		_check(lost_target_projectile.is_queued_for_deletion() and bystander.health == bystander.max_health
			and fixture.remains.get_child_count() == 1, label + " dead-target projectile dissipates without retargeting or another corpse")
		observations.append({"label": label, "locked_hit_loss": actual_hit_loss,
			"bystander_health": bystander.health, "actual_corpses": fixture.remains.get_child_count()})
		await _dispose(fixture)
	evidence["locked_projectiles"] = observations
