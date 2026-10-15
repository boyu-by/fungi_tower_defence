extends SceneTree
## 隔离集成夹具：清波部分显式压缩出怪间隔并注入伤害，不作为正常游玩证据。
const LEVEL: PackedScene = preload("res://scenes/levels/first_level.tscn")
var level: FirstLevel
var failures: Array[String] = []
var checks: int = 0
var settlements: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await _fresh()
	_check(level.mother_core.nutrition == 72 and level.mother_core.health == 240, "initial core baseline")
	_check(level.wave_flow.get_snapshot().state == "initial_preparation" and level.enemy_spawner.spawned_count == 0, "initial manual preparation")
	_check(level.attack_organ.nutrition == 4 and level.get_weapons().size() == 2, "initial organs and stock")
	level.growth_input_controller.enter_placement_mode()
	_check(level.growth_input_controller.place_target(Vector2(330, 395)), "normal paid growth accepted")
	var task_id: String = String(level.construction_coordinator.get_snapshot().selected_id)
	var before_nutrition: int = level.mother_core.nutrition
	level.pause_controller.set_paused(true)
	var before_clock: float = level.elapsed_seconds
	await _frames(20)
	_check(level.mother_core.nutrition == before_nutrition, "deferred queue pump cannot pay during pause")
	_check(level.construction_coordinator.get_workers().is_empty(), "deferred queue pump cannot create worker during pause")
	_check(level.elapsed_seconds == before_clock and not level.start_next_wave(), "paused clock and wave start frozen")
	level.growth_input_controller.enter_placement_mode()
	var preview: Dictionary = level.growth_input_controller.preview_at(Vector2(925, 390))
	_check(bool(preview.get("valid", false)), "paused planning has real preview")
	_check(not level.growth_input_controller.place_target(Vector2(925, 390)), "paused planning cannot enqueue")
	level._select_node(level.get_node("World/Colony/Nodes/HyphaNode"))
	_check(level.selected_node != null, "paused selection works")
	_check(not level.construction_queue_controller.cancel_selected(), "paused queue cannot settle/refund")
	level.pause_controller.set_paused(false)
	await _frames(90)
	_check(level.construction_coordinator.get_workers().size() == 1, "resume dispatches pending worker")
	_check(level.elapsed_seconds < before_clock + 2.0, "resume has no catch-up time")
	_check(level.start_next_wave() and not level.start_next_wave(), "one first wave without mature gate")
	await _frames(180)
	level.pause_controller.set_paused(true)
	await _frames(2)
	var frozen: Dictionary = _simulation_snapshot()
	await _frames(120)
	_check(_simulation_snapshot() == frozen, "combat, transports, construction, decay, timers, clock frozen together")
	_check(level.get_combat_resource_snapshot().balanced, "paused resource conservation")
	var old_core: WeakRef = weakref(level.mother_core)
	level.restart_level()
	await _frames(5)
	level = current_scene as FirstLevel
	_check(old_core.get_ref() == null, "restart retires old scene identities")
	_check(_is_clean(), "restart while paused yields clean unpaused preparation")
	_check(level.start_next_wave(), "battle starts after pause restart")
	await _frames(3)
	level.restart_level()
	await _frames(5)
	level = current_scene as FirstLevel
	_check(_is_clean(), "restart during battle clears enemies and counters")
	await _finish_fixture(false, false)
	_check(bool(level.get_result_snapshot().get("victory", false)), "six real batch identities create one victory")
	_check(level.get_result_snapshot().get("total_defeated") == 66, "victory reports exactly66")
	_check(level.get_result_snapshot().get("completed_waves") == 6, "six waves completed")
	_check(level.get_result_snapshot().get("resources", {}).get("balanced", false), "end snapshot balanced before cleanup")
	var result: Dictionary = level.get_result_snapshot()
	level._resolve_result()
	await _frames(4)
	_check(level.get_result_snapshot() == result and settlements == 1, "terminal repeated callbacks settle once")
	_check(not level.start_next_wave(), "no seventh wave")
	level.restart_level()
	await _frames(5)
	level = current_scene as FirstLevel
	_check(_is_clean(), "restart after victory is clean")
	await _finish_fixture(true, false)
	_check(not bool(level.get_result_snapshot().get("victory", true)) and level.mother_core.health == 0, "same frame last enemy then core death fails")
	level.restart_level()
	await _frames(5)
	level = current_scene as FirstLevel
	_check(_is_clean(), "restart after failure is clean")
	await _finish_fixture(true, true)
	_check(not bool(level.get_result_snapshot().get("victory", true)), "same frame core death then last enemy also fails")
	level.restart_level()
	await _frames(5)
	level = current_scene as FirstLevel
	level.mother_core.take_damage(240)
	await _frames(3)
	_check(not level.get_result_snapshot().is_empty() and not level.get_result_snapshot().victory, "initial preparation core death settles failure immediately")
	paused = false
	level.queue_free()
	await _frames(3)
	print("STAGE11_INTEGRATION checks=", checks, " failures=", failures)
	quit(0 if failures.is_empty() else 1)

func _fresh() -> void:
	level = LEVEL.instantiate() as FirstLevel
	root.add_child(level)
	current_scene = level
	await _frames(2)

func _finish_fixture(fail_same_frame: bool, core_first: bool) -> void:
	# Fixture-only spawn rhythm; production configs and all costs are unchanged on disk.
	var fixture_waves: Array[FirstLevelWave] = []
	for wave: FirstLevelWave in level.wave_flow.waves:
		var fixture: FirstLevelWave = wave.duplicate(true) as FirstLevelWave
		for entry: EnemySpawnEntry in fixture.entries:
			entry.group_interval = 0.02
			entry.member_interval = 0.02
		fixture_waves.append(fixture)
	level.wave_flow.waves = fixture_waves
	level.level_finished.connect(func(_snapshot: Dictionary) -> void: settlements += 1)
	for wave_number: int in range(1, 7):
		_check(level.start_next_wave(), "fixture starts wave%d" % wave_number)
		var nutrition_before: int = level.mother_core.nutrition
		for _frame: int in range(300):
			var batch: Dictionary = level.enemy_spawner.get_batch_snapshot()
			var final_enemy: bool = wave_number == 6 and batch.unspawned == 0 and batch.active == 1
			for child: Node in level.get_node("World/Enemies").get_children():
				if child is BasicEnemy and child.is_alive():
					if fail_same_frame and core_first and final_enemy:
						level.mother_core.take_damage(240)
					child.take_damage(10000)
					if fail_same_frame and not core_first and final_enemy:
						level.mother_core.take_damage(240)
			await _frames(1)
			if level.wave_flow.get_snapshot().state != "fighting":
				break
		if wave_number < 6:
			_check(level.wave_flow.get_snapshot().state == "preparation", "normal clear only prepares wave%d" % wave_number)
			_check(level.mother_core.nutrition == nutrition_before, "wave boundary does not reset or grant nutrition")
			if wave_number == 1:
				level.pause_controller.set_paused(true)
				var preparation: float = level.wave_flow.get_snapshot().preparation_remaining
				await _frames(60)
				_check(level.wave_flow.get_snapshot().preparation_remaining == preparation, "intermission freezes while paused")
				level.pause_controller.set_paused(false)
	await _frames(4)

func _is_clean() -> bool:
	var ledger: Dictionary = level.get_combat_resource_snapshot()
	return not paused and level.wave_flow.get_snapshot().state == "initial_preparation" \
		and level.mother_core.health == 240 and level.mother_core.nutrition == 72 \
		and level.colony_progress.get_total_recovered() == 0 and level.get_weapons().size() == 2 \
		and level.get_digestive_organs().size() == 1 and level.enemy_spawner.spawned_count == 0 \
		and level.get_node("World/Enemies").get_child_count() == 0 \
		and level.construction_coordinator.get_workers().is_empty() \
		and level.first_guide.get_snapshot().seen.is_empty() and level.get_result_snapshot().is_empty() \
		and ledger.balanced and ledger.parts.decayed_remains == 0 and ledger.parts.transplant_lost == 0

func _simulation_snapshot() -> Dictionary:
	var timers: Array = []
	var positions: Array = []
	for node: Node in level.find_children("*", "", true, false):
		# 提示气泡的寿命属于观察界面，可在暂停中消退；游戏计时器仍全部核验冻结。
		if node is Timer and not level.compact_hud.is_ancestor_of(node):
			timers.append([node.get_instance_id(), node.time_left, node.is_stopped()])
		if node is BasicEnemy or node is NutrientPacket or node is RemainsPacket or node is GrowthTip or node is SporeProjectile:
			positions.append([node.get_instance_id(), node.global_position])
	return {"timers": timers, "positions": positions, "clock": level.elapsed_seconds,
		"flow": level.wave_flow.get_snapshot(), "ledger": level.get_combat_resource_snapshot(),
		"repair": level.repair_system.get_task_snapshot(), "transplant": level.transplant_system.get_task_snapshot(),
		"construction": level.construction_coordinator.get_resource_snapshot()}

func _frames(count: int) -> void:
	for _i: int in range(count):
		await process_frame

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)
