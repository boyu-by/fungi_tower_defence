extends SceneTree
## 用真实物理帧验证战斗行为，并跑完场景默认配置的一轮防守。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")

var failures: Array[String] = []
var checks: int = 0
var full_wave_result: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	await _test_range_damage_and_stock()
	await _test_empty_inventory_and_missing_target()
	await _test_enemy_contact()
	await _test_defeat_and_restart()
	await _test_default_wave()
	print("COMBAT_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "default_wave": full_wave_result
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_level() -> Node2D:
	var level := LEVEL_SCENE.instantiate() as Node2D
	level.expansion_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	# 单武器行为测试保留 300 的独立基线；默认双器官布局由完整波次测试覆盖。
	level.get_node("World/Colony/Nodes/HyphaNode/SporeWeapon").attack_range = 300.0
	root.add_child(level)
	current_scene = level
	await physics_frame
	await process_frame
	level.supply_system.get_node("DispatchTimer").stop()
	for current_weapon in level.get_weapons():
		current_weapon.get_node("FireTimer").stop()
	return level


func _remove_level(level: Node2D) -> void:
	level.queue_free()
	await process_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame


func _add_enemy(level: Node2D, position: Vector2, speed: float = 0.0) -> BasicEnemy:
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.mother_core = level.mother_core
	enemy.move_speed = speed
	level.get_node("World/Enemies").add_child(enemy)
	enemy.global_position = position
	return enemy


func _fire_once(level: Node2D) -> void:
	var timer := level.weapon.get_node("FireTimer") as Timer
	timer.one_shot = true
	timer.start(0.05)
	await _wait_frames(6)


func _press_restart() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_R
	event.pressed = true
	root.push_input(event)
	event = InputEventKey.new()
	event.keycode = KEY_R
	root.push_input(event)
	await process_frame
	await process_frame
	await physics_frame


func _test_range_damage_and_stock() -> void:
	var level := await _new_level()
	await _fire_once(level)
	_check(level.attack_organ.nutrition == 4, "Idle weapon spent nutrition")
	var outside := _add_enemy(level, level.attack_organ.global_position + Vector2(350, 0))
	await _fire_once(level)
	_check(level.attack_organ.nutrition == 4 and outside.health == 24, "Out-of-range target was shot")
	var enemy := _add_enemy(level, level.attack_organ.global_position + Vector2(150, 0))
	var deaths := [0]
	var selected_targets: Array[BasicEnemy] = []
	enemy.died.connect(func(_enemy: BasicEnemy) -> void: deaths[0] += 1)
	level.weapon.shot_fired.connect(func(target: BasicEnemy) -> void: selected_targets.append(target))
	await _fire_once(level)
	_check(selected_targets.size() == 1 and selected_targets[0] == enemy, "Wrong target selected")
	_check(level.attack_organ.nutrition == 3 and level.mother_core.nutrition == 72,
		"Shot must consume local stock only")
	_check(enemy.health == 24, "Damage was applied before projectile arrived")
	_check(level.get_node("World/Projectiles").get_child_count() == 1, "Shot scene was not spawned")
	await _wait_frames(40)
	_check(enemy.health == 12, "First shot damage was incorrect")
	_check(enemy.health_bar.value == 12, "Enemy health bar did not update")
	_check(level.get_node("World/Projectiles").get_child_count() == 0, "Hit projectile was not freed")
	await _wait_frames(12)
	_check(enemy.health == 12, "Projectile damaged target twice")
	await _fire_once(level)
	await _wait_frames(50)
	_check(not is_instance_valid(enemy) and deaths[0] == 1, "Death was not finalized once")
	_check(outside.health == 24 and level.attack_organ.nutrition == 2, "Shots affected wrong enemy or stock")
	await _remove_level(level)


func _test_empty_inventory_and_missing_target() -> void:
	var level := await _new_level()
	var enemy := _add_enemy(level, level.attack_organ.global_position + Vector2(180, 0))
	level.attack_organ.consume_nutrition(4)
	await _fire_once(level)
	_check(level.get_node("World/Projectiles").get_child_count() == 0, "Empty weapon fired")
	_check(enemy.health == 24 and level.attack_organ.nutrition == 0, "Empty weapon applied damage")
	level.attack_organ.reserve_nutrition(1)
	level.attack_organ.complete_delivery(1)
	await _fire_once(level)
	_check(level.attack_organ.nutrition == 0, "Weapon did not resume after refill")
	enemy.queue_free()
	await _wait_frames(12)
	_check(level.get_node("World/Projectiles").get_child_count() == 0, "Lost target left projectile")
	_check(level.attack_organ.nutrition == 0, "Missed shot incorrectly refunded nutrition")

	# 一发很慢的弹丸也应被场景中的寿命计时器清理。
	enemy = _add_enemy(level, level.attack_organ.global_position + Vector2(180, 0))
	level.attack_organ.reserve_nutrition(1)
	level.attack_organ.complete_delivery(1)
	await _fire_once(level)
	var projectile := level.get_node("World/Projectiles").get_child(0) as SporeProjectile
	projectile.speed = 1.0
	projectile.get_node("LifetimeTimer").start(0.1)
	await _wait_frames(18)
	_check(level.get_node("World/Projectiles").get_child_count() == 0, "Lifetime timer failed")
	_check(enemy.health == 24, "Expired projectile applied damage")
	await _remove_level(level)


func _test_enemy_contact() -> void:
	var level := await _new_level()
	var enemy := _add_enemy(level, level.mother_core.global_position + Vector2(60, 0), 52.0)
	var initial_position := enemy.global_position
	await _wait_frames(12)
	_check(enemy.global_position.distance_to(level.mother_core.global_position) <
		initial_position.distance_to(level.mother_core.global_position), "Enemy did not approach core")
	_check(level.mother_core.health == 240, "Enemy dealt damage before reaching core")
	for frame in range(120):
		if level.mother_core.health < 240:
			break
		await physics_frame
	_check(level.mother_core.health == 228, "Enemy contact attack damage")
	var distance := enemy.global_position.distance_to(level.mother_core.global_position)
	_check(absf(distance - enemy.contact_range) < 0.01, "Enemy walked through core")
	enemy.take_damage(999)
	enemy.take_damage(999)
	await _wait_frames(80)
	_check(level.mother_core.health == 228, "Dead enemy kept attacking")
	_check(not is_instance_valid(enemy), "Dead enemy was not removed")
	await _remove_level(level)


func _test_defeat_and_restart() -> void:
	var level := await _new_level()
	level.mother_core.take_damage(228)
	level.enemy_spawner.spawn_points.get_child(0).global_position = (
		level.mother_core.global_position + Vector2(0, 28)
	)
	level.enemy_spawner.start_wave()
	for frame in range(120):
		if level.mother_core.health == 0:
			break
		await physics_frame
	_check(level.mother_core.health == 0, "Enemy did not cause defeat")
	_check(level.hud.battle_label.text.contains("母核已被摧毁"), "Defeat result was missing")
	_check(level.get_node("World").process_mode == Node.PROCESS_MODE_DISABLED, "World continued after defeat")
	_check(level.enemy_spawner.spawn_timer.is_stopped(), "Spawner continued after defeat")
	await _wait_frames(200)
	_check(level.enemy_spawner.spawned_count == 1, "More enemies spawned after defeat")
	await _press_restart()
	_check(not is_instance_valid(level), "Restart kept old scene")
	level = current_scene as Node2D
	level.enemy_spawner.stop_spawning()
	_check(level.mother_core.health == 240 and level.mother_core.nutrition == 72,
		"Restart did not reset core")
	_check(level.attack_organ.nutrition == 4 and level.enemy_spawner.spawned_count == 0,
		"Restart did not reset combat stock and counters")
	_check(level.get_node("World").process_mode != Node.PROCESS_MODE_DISABLED, "Restart remained frozen")
	await _remove_level(level)


func _test_default_wave() -> void:
	# 保持默认速度、数量、出生点和计时器，验证正常运行的一整轮。
	var level := LEVEL_SCENE.instantiate() as Node2D
	level.expansion_demo_enabled = false
	root.add_child(level)
	current_scene = level
	var shots := [0]
	var completions := [0]
	var initial_resources: int = level.mother_core.nutrition
	for organ in level.supply_system.get_registered_organs():
		initial_resources += organ.nutrition
	for current_weapon in level.get_weapons():
		current_weapon.shot_fired.connect(func(_enemy: BasicEnemy) -> void: shots[0] += 1)
	level.enemy_spawner.wave_finished.connect(func() -> void: completions[0] += 1)
	for frame in range(1800):
		if completions[0] > 0 or level.mother_core.health == 0:
			break
		await physics_frame
	await _wait_frames(180)
	_check(completions[0] == 1, "Default wave did not finish successfully once")
	_check(level.enemy_spawner.spawned_count == 6 and level.enemy_spawner.defeated_count == 6,
		"Default wave spawn or defeat count")
	_check(level.mother_core.health == 240, "Default practice wave overwhelmed initial layout")
	_check(level.hud.battle_label.text.contains("本轮防守成功"), "Wave result not displayed")
	_check(level.get_node("World/Enemies").get_child_count() == 0, "Wave left enemies")
	_check(level.get_node("World/Projectiles").get_child_count() == 0, "Wave left projectiles")
	_check(shots[0] >= 12, "Default wave applied damage without enough shots")
	var in_transit: int = level.supply_system.get_in_transit_count()
	var recovered: int = level.digestive_organ.total_nutrition_produced
	var stored: int = 0
	for organ in level.supply_system.get_registered_organs():
		stored += organ.nutrition
	_check(level.mother_core.nutrition + stored + in_transit + shots[0]
		+ level.digestive_organ.get_output_nutrition() == initial_resources + recovered,
		"Combat and supply failed resource conservation")
	_check(level.supply_system.delivered_packets > 0, "Combat never used automatic supply")
	full_wave_result = {
		"spawned": level.enemy_spawner.spawned_count,
		"defeated": level.enemy_spawner.defeated_count,
		"shots": shots[0],
		"core_health": level.mother_core.health,
		"core_nutrition": level.mother_core.nutrition,
		"local_nutrition": stored,
		"produced_nutrition": recovered,
		"recovered_nutrition": level.colony_progress.get_total_recovered(),
		"uncredited_output": level.digestive_organ.get_output_nutrition(),
		"in_transit": in_transit
	}
	await _remove_level(level)
	_check(root.get_child_count() == 0, "Combat teardown left orphan nodes")
