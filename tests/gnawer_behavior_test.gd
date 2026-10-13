extends SceneTree
## 使用真实地形、物理帧与 AttackTimer；不手动驱动敌人移动或攻击回调。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const GNAWER_SCENE: PackedScene = preload("res://scenes/enemies/gnawer_enemy.tscn")
const NORMAL_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const SWARM_SCENE: PackedScene = preload("res://scenes/enemies/swarm_enemy.tscn")
const ARMORED_SCENE: PackedScene = preload("res://scenes/enemies/armored_enemy.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const BUD_SCENE: PackedScene = preload("res://scenes/colony/organ_bud.tscn")
const TIP_SCENE: PackedScene = preload("res://scenes/colony/growth_tip.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const GNAWER_ENTRY: EnemySpawnEntry = preload("res://resources/enemies/spawn_entries/gnawer_single.tres")
const GNAWER_BATCH: PackedScene = preload("res://scenes/systems/gnawer_enemy_batch.tscn")
const WORLD_OFFSET := Vector2(400.0, 200.0)

class Fixture:
	extends RefCounted
	var world: Node2D
	var core: MotherCore
	var terrain: TerrainNavigation
	var network: NetworkSystem
	var enemies: Node2D
	var tissues: Node2D
	var remains: Node2D


var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {}
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_initial_root_children = root.get_child_count()
	_test_presets_and_frozen_profiles()
	await _test_old_types_follow_real_rock_paths()
	await _test_edge_world_position_stickiness_and_timer_death()
	await _test_rock_separates_contact()
	await _test_unreachable_lock_reselects()
	await _test_ordinary_opportunistic_tissues()
	await _test_scene_local_fallback_and_one_corpse()
	_check(root.get_child_count() == _initial_root_children, "Every focused fixture leaves the tree")
	print("GNAWER_BEHAVIOR_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
		"movement": "actual physics frames", "damage": "actual one-second AttackTimer",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _step() -> void:
	await physics_frame
	await process_frame


func _wait_until(condition: Callable, seconds: float) -> bool:
	for _frame: int in range(ceili(seconds * Engine.physics_ticks_per_second)):
		if bool(condition.call()):
			return true
		await _step()
	return bool(condition.call())


func _new_fixture(with_terrain: bool = true) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.world.position = WORLD_OFFSET
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.position = Vector2(190.0, 120.0)
	fixture.enemies = Node2D.new()
	fixture.tissues = Node2D.new()
	fixture.remains = Node2D.new()
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.core)
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.tissues)
	fixture.world.add_child(fixture.remains)
	fixture.world.add_child(fixture.network)
	if with_terrain:
		fixture.terrain = TerrainNavigation.new()
		fixture.terrain.bounds = Rect2(WORLD_OFFSET, Vector2(300.0, 240.0))
		fixture.world.add_child(fixture.terrain)
	var spawner := RemainsSpawner.new()
	spawner.enemy_container = fixture.enemies
	spawner.remains_container = fixture.remains
	spawner.remains_scene = REMAINS_SCENE
	fixture.world.add_child(spawner)
	root.add_child(fixture.world)
	current_scene = fixture.world
	fixture.network.add_to_group(&"network_system")
	fixture.network.register_node(fixture.core, true)
	if with_terrain:
		fixture.terrain.add_to_group(&"terrain_navigation")
	return fixture


func _dispose(fixture: Fixture) -> void:
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _add_enemy(fixture: Fixture, scene: PackedScene = GNAWER_SCENE,
		point: Vector2 = Vector2(35.0, 120.0), inject: bool = true) -> BasicEnemy:
	var enemy := scene.instantiate() as BasicEnemy
	enemy.position = point
	enemy.mother_core = fixture.core
	if inject:
		enemy.terrain_navigation = fixture.terrain
		enemy.network_system = fixture.network
	fixture.enemies.add_child(enemy)
	return enemy


func _add_junction(fixture: Fixture, point: Vector2) -> HyphaNode:
	var junction := NODE_SCENE.instantiate() as HyphaNode
	junction.position = point
	fixture.tissues.add_child(junction)
	fixture.network.register_node(junction)
	return junction


func _add_edge(fixture: Fixture, start: HyphaNode, end: HyphaNode) -> HyphaEdge:
	var edge := EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	# 刻意让边自身原点远离整条世界坐标线段，禁止把 Node2D 原点当目标。
	edge.position = Vector2(900.0, 500.0)
	edge.max_health = 20.0
	fixture.tissues.add_child(edge)
	fixture.network.register_edge(edge)
	return edge


func _health(tissue: Node2D) -> float:
	var snapshot: Dictionary = tissue.call("get_health_snapshot")
	return float(snapshot["health"])


func _point(value: Vector2) -> Array[float]:
	return [value.x, value.y]


func _test_presets_and_frozen_profiles() -> void:
	var rows: Array[Dictionary] = [
		{"scene": NORMAL_SCENE, "kind": 0, "hp": 24, "armor": 0, "speed": 52.0, "damage": 12},
		{"scene": SWARM_SCENE, "kind": 1, "hp": 12, "armor": 0, "speed": 66.0, "damage": 6},
		{"scene": ARMORED_SCENE, "kind": 2, "hp": 72, "armor": 4, "speed": 26.0, "damage": 15},
		{"scene": GNAWER_SCENE, "kind": 3, "hp": 36, "armor": 0, "speed": 38.0, "damage": 10},
	]
	var observed: Array[Dictionary] = []
	for row: Dictionary in rows:
		var scene: PackedScene = row["scene"]
		var enemy := scene.instantiate() as BasicEnemy
		var snapshot := enemy.get_archetype_snapshot()
		_check(snapshot == {"archetype": row["kind"], "max_health": row["hp"],
			"armor": row["armor"], "move_speed": row["speed"], "attack_damage": row["damage"],
			"attack_interval": 1.0, "remains_nutrition": 4}, "Each authored archetype retains its frozen profile")
		_check(enemy.get_target_snapshot()["target_id"] == 0 and not enemy.is_attacking_core(),
			"Unready target queries are pure and show no threat")
		observed.append(snapshot)
		enemy.free()
	_check(BasicEnemy.Archetype.GNAWER == 3 and GNAWER_ENTRY.is_valid()
		and GNAWER_ENTRY.get_total_count() == 1, "The new single preset has an additive enum and exactly one gnawer")
	var batch := GNAWER_BATCH.instantiate() as EnemySpawner
	_check(batch.spawn_entries.size() == 1 and batch.spawn_entries[0].enemy_scene == GNAWER_SCENE
		and batch.spawn_entries[0].get_total_count() == 1, "The batch uses the authored single gnawer entry")
	batch.free()
	evidence["profiles"] = observed


func _test_old_types_follow_real_rock_paths() -> void:
	var rows: Array[PackedScene] = [NORMAL_SCENE, SWARM_SCENE, ARMORED_SCENE]
	var observations: Array[Dictionary] = []
	for scene: PackedScene in rows:
		var fixture := _new_fixture()
		fixture.terrain.obstacles.assign([Rect2(WORLD_OFFSET + Vector2(100.0, 65.0), Vector2(25.0, 110.0))])
		var enemy := _add_enemy(fixture, scene)
		var start := enemy.global_position
		var previous := start
		var clear_steps: bool = true
		var walkable_positions: bool = true
		var maximum_y_deviation: float = 0.0
		var travel_frames: int = 0
		var core_health := fixture.core.health
		for _frame: int in range(ceili(11.0 * Engine.physics_ticks_per_second)):
			await _step()
			travel_frames += 1
			clear_steps = clear_steps and fixture.terrain.is_segment_clear(previous, enemy.global_position, 10.0)
			walkable_positions = walkable_positions and fixture.terrain.is_point_walkable(enemy.global_position, 10.0)
			maximum_y_deviation = maxf(maximum_y_deviation, absf(enemy.global_position.y - start.y))
			previous = enemy.global_position
			if enemy.is_attacking_core():
				break
		_check(enemy.is_attacking_core() and enemy.global_position != start,
			"An original enemy reaches core contact through its actual physics processing")
		_check(clear_steps and walkable_positions and maximum_y_deviation > 55.0,
			"Every recorded movement step goes around the real rock with ground clearance")
		_check(enemy.get_target_snapshot()["kind"] == "core" and fixture.core.health == core_health,
			"Movement toward the core deals no immediate arrival damage")
		await create_timer(0.75, false, true).timeout
		_check(fixture.core.health == core_health, "Actual core contact waits for the authored one-second timer")
		await create_timer(0.4, false, true).timeout
		_check(fixture.core.health == core_health - enemy.attack_damage,
			"The actual timer preserves each original archetype's core damage")
		observations.append({"archetype": enemy.get_archetype(), "start": _point(start),
			"arrival": _point(enemy.global_position), "travel_frames": travel_frames,
			"maximum_y_deviation": maximum_y_deviation, "all_steps_clear": clear_steps,
			"all_positions_walkable": walkable_positions, "core_health_lost": core_health - fixture.core.health})
		await _dispose(fixture)
	evidence["real_old_archetype_rock_movement"] = observations


func _test_edge_world_position_stickiness_and_timer_death() -> void:
	var fixture := _new_fixture()
	var start := _add_junction(fixture, Vector2(100.0, 90.0))
	var end := _add_junction(fixture, Vector2(100.0, 150.0))
	var edge := _add_edge(fixture, start, end)
	var enemy := _add_enemy(fixture)
	var observed: Dictionary = {"hits": [], "edge_deaths": 0}
	enemy.attacked_tissue.connect(func(target: Node2D, amount: float) -> void:
		observed.hits.append({"target_id": target.get_instance_id(), "amount": amount}))
	edge.tissue_destroyed.connect(func(_tissue: Node2D) -> void: observed.edge_deaths += 1)
	await _step()
	var snapshot := enemy.get_target_snapshot()
	var locked_point: Vector2 = snapshot["position"]
	var segment_point := Geometry2D.get_closest_point_to_segment(locked_point, start.global_position, end.global_position)
	_check(snapshot["target"] == edge and snapshot["kind"] == "edge"
		and locked_point.distance_to(segment_point) < 0.01 and locked_point.distance_to(edge.global_position) > 500.0,
		"The gnawer locks a reachable world-space point on the edge, never the edge origin")
	var nearer := _add_junction(fixture, enemy.position + Vector2(1.0, 0.0))
	var saved_id: int = snapshot["target_id"]
	snapshot["target"] = nearer
	snapshot["target_id"] = 0
	snapshot["position"] = Vector2.ZERO
	_check(enemy.get_target_snapshot()["target_id"] == saved_id,
		"Mutating a target snapshot cannot replace the locked target")
	var first_hit := await _wait_until(func() -> bool: return not observed.hits.is_empty(), 4.0)
	_check(first_hit and _health(edge) == 10.0 and enemy.get_target_snapshot()["target"] == edge,
		"The real movement and one-second timer damage the edge while retaining the lock")
	_check(not enemy.is_attacking_core() and fixture.core.health == fixture.core.max_health,
		"Attacking an edge does not report a core attack or damage the mother core")
	var destroyed := await _wait_until(func() -> bool: return _health(edge) <= 0.0, 1.5)
	_check(destroyed and observed.edge_deaths == 1 and observed.hits.size() == 2
		and observed.hits[0]["amount"] == 10.0 and observed.hits[1]["amount"] == 10.0,
		"Two real timer hits destroy the test edge exactly once and report actual damage")
	var reselected := await _wait_until(func() -> bool: return enemy.get_target_snapshot()["target"] == nearer, 1.5)
	_check(reselected and _health(edge) == 0.0, "Death invalidates the lock and the next bounded scan selects live tissue")
	evidence["edge_lock_and_timer_death"] = {"locked_point": _point(locked_point),
		"edge_origin": _point(edge.global_position), "edge_id": saved_id,
		"replacement_id": nearer.get_instance_id(), "observed": observed}
	await _dispose(fixture)


func _test_rock_separates_contact() -> void:
	var fixture := _new_fixture()
	fixture.terrain.obstacles.assign([Rect2(WORLD_OFFSET + Vector2(106.0, 75.0), Vector2(4.0, 90.0))])
	var junction := _add_junction(fixture, Vector2(120.0, 120.0))
	var enemy := _add_enemy(fixture, GNAWER_SCENE, Vector2(96.0, 120.0))
	enemy.move_speed = 0.0
	var before := _health(junction)
	await _step()
	_check(enemy.get_target_snapshot()["target"] == junction
		and enemy.global_position.distance_to(junction.global_position) < enemy.contact_range,
		"The test locks a reachable junction across a rock at less than contact range")
	await create_timer(1.25, false, true).timeout
	_check(_health(junction) == before and enemy.attack_timer.is_stopped() and not enemy.is_attacking_core(),
		"A real timer cannot deal contact damage through the intervening rock")
	enemy.move_speed = 38.0
	var start := enemy.global_position
	var reached := await _wait_until(func() -> bool: return _health(junction) < before, 6.0)
	_check(reached and enemy.global_position != start
		and fixture.terrain.is_segment_clear(enemy.global_position, junction.global_position, 0.0),
		"Restored real movement walks around the rock before timer contact can damage the junction")
	evidence["rock_contact_guard"] = {"start": _point(start), "attack_position": _point(enemy.global_position),
		"health_lost": before - _health(junction), "target": enemy.get_target_snapshot()["kind"]}
	await _dispose(fixture)


func _test_unreachable_lock_reselects() -> void:
	var fixture := _new_fixture()
	var original := _add_junction(fixture, Vector2(110.0, 120.0))
	var enemy := _add_enemy(fixture)
	await _step()
	_check(enemy.get_target_snapshot()["target"] == original, "A reachable junction is locked before the terrain change")
	var before := _health(original)
	var replacement := _add_junction(fixture, Vector2(20.0, 150.0))
	fixture.terrain.obstacles.assign([Rect2(WORLD_OFFSET + Vector2(70.0, 0.0), Vector2(20.0, 240.0))])
	_check(fixture.terrain.find_path(enemy.global_position, original.global_position, 10.0).is_empty(),
		"The real changed terrain makes the original target unreachable")
	var reselected := await _wait_until(func() -> bool: return enemy.get_target_snapshot()["target"] == replacement, 2.0)
	_check(reselected and _health(original) == before and enemy.attack_timer.is_stopped(),
		"An unreachable locked target is replaced on bounded cadence without stale contact damage")
	var replacement_before := _health(replacement)
	var hit := await _wait_until(func() -> bool: return _health(replacement) < replacement_before, 3.0)
	_check(hit and _health(original) == before, "Real timer contact damages the reachable replacement only")
	evidence["unreachable_reselection"] = {"original_id": original.get_instance_id(),
		"replacement_id": replacement.get_instance_id(), "original_health_lost": before - _health(original),
		"replacement_health_lost": replacement_before - _health(replacement)}
	await _dispose(fixture)


func _test_ordinary_opportunistic_tissues() -> void:
	var rows: Array[Dictionary] = [
		{"enemy": NORMAL_SCENE, "tissue": ATTACK_SCENE, "kind": "organ"},
		{"enemy": SWARM_SCENE, "tissue": BUD_SCENE, "kind": "bud"},
		{"enemy": ARMORED_SCENE, "tissue": TIP_SCENE, "kind": "tip"},
	]
	var observed: Array[Dictionary] = []
	for row: Dictionary in rows:
		var fixture := _new_fixture()
		var host := _add_junction(fixture, Vector2(55.0, 120.0))
		var tissue_scene: PackedScene = row["tissue"]
		var tissue := tissue_scene.instantiate() as Node2D
		if tissue is GrowthTip:
			tissue.position = host.position
			fixture.tissues.add_child(tissue)
		else:
			# 验证器官使用宿主地面位置，而非其视觉根节点偏移。
			tissue.position = Vector2(80.0, -60.0)
			host.add_child(tissue)
		if tissue is AttackOrgan:
			(tissue as AttackOrgan).set_work_enabled(false)
		var enemy_scene: PackedScene = row["enemy"]
		var enemy := _add_enemy(fixture, enemy_scene)
		var before := _health(tissue)
		await _step()
		var snapshot := enemy.get_target_snapshot()
		_check(snapshot["target"] == tissue and snapshot["kind"] == row["kind"]
			and (snapshot["position"] as Vector2).is_equal_approx(host.global_position),
			"An ordinary archetype selects a nearby reachable organ, bud, or tip at its logical ground point")
		_check(not enemy.is_attacking_core(), "Nearby tissue contact never reports a core attack")
		var hit := await _wait_until(func() -> bool: return _health(tissue) < before, 1.5)
		_check(hit and before - _health(tissue) == float(enemy.attack_damage)
			and fixture.core.health == fixture.core.max_health, "An actual ordinary enemy timer damages its opportunistic tissue")
		tissue.call("take_damage", _health(tissue))
		var returned := await _wait_until(func() -> bool: return enemy.get_target_snapshot()["target"] == fixture.core, 1.0)
		_check(returned, "After destroying the nearby tissue the ordinary enemy resumes its long-term core goal")
		observed.append({"archetype": enemy.get_archetype(), "kind": row["kind"],
			"damage": enemy.attack_damage, "returned_to_core": returned})
		await _dispose(fixture)
	evidence["ordinary_opportunism"] = observed


func _test_scene_local_fallback_and_one_corpse() -> void:
	var unrelated := _new_fixture()
	var foreign_junction := _add_junction(unrelated, Vector2(35.0, 120.0))
	var fixture := _new_fixture()
	var local_junction := _add_junction(fixture, Vector2(90.0, 120.0))
	var enemy := _add_enemy(fixture, GNAWER_SCENE, Vector2(35.0, 120.0), false)
	var observed: Dictionary = {"deaths": 0}
	enemy.died.connect(func(_enemy: BasicEnemy) -> void: observed.deaths += 1)
	await _step()
	_check(enemy.terrain_navigation == fixture.terrain and enemy.network_system == fixture.network
		and enemy.get_target_snapshot()["target"] == local_junction
		and enemy.get_target_snapshot()["target"] != foreign_junction,
		"Group fallback resolves the enemy's own scene and ignores closer tissues in another scene")
	var death_position := enemy.global_position
	var request := {"raw_damage": 36, "damage_type": WeaponProfile.DamageType.NORMAL}
	_check(enemy.apply_damage(request) == 36 and enemy.apply_damage(request) == 0,
		"The gnawer retains the BasicEnemy damage and repeated-death guard")
	_check(observed.deaths == 1 and fixture.remains.get_child_count() == 1
		and not enemy.is_attacking_core() and enemy.get_target_snapshot()["target_id"] == 0,
		"One gnawer death emits once, retires the target query and produces one actual corpse")
	var remains := fixture.remains.get_child(0) as EnemyRemains
	_check(remains.nutrition_value == 4 and remains.global_position.is_equal_approx(death_position),
		"The existing corpse pipeline places exactly four nutrition at the actual death position")
	await create_timer(0.3, false, true).timeout
	_check(not is_instance_valid(enemy) and fixture.remains.get_child_count() == 1,
		"The original death fade frees the gnawer without producing an extra corpse")
	evidence["scene_scope_and_corpse"] = {"deaths": observed.deaths,
		"corpse_nutrition": remains.nutrition_value, "corpse_position": _point(remains.global_position)}
	await _dispose(fixture)
	await _dispose(unrelated)
