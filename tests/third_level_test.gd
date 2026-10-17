extends SceneTree
## 定向隔离验收：显式移动目标、缩短生产周期或注入终局伤害，不作为正常通关记录。

const LEVEL: PackedScene = preload("res://scenes/levels/third_level.tscn")
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _initial_and_collection()
	await _production()
	await _removed_sources()
	for order: Array in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]:
		await _order(order)
	await _death_priority(false)
	await _death_priority(true)
	await _restart_and_link()
	print("THIRD_LEVEL_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)


func _frames(count: int) -> void:
	for _index: int in range(count):
		await physics_frame
		await process_frame


func _fresh() -> ThirdLevel:
	var level := LEVEL.instantiate() as ThirdLevel
	root.add_child(level)
	await _frames(3)
	return level


func _dispose(level: ThirdLevel) -> void:
	level.queue_free()
	await _frames(3)
	_check(not paused, "scene disposal clears global pause")


func _initial_and_collection() -> void:
	var level: ThirdLevel = await _fresh()
	var controller: FragmentCollectionController = level.fragment_collection
	controller.set_process(false)
	var targets: Array[MemoryFragment] = level.get_fragment_targets()
	_check(level.mother_core.health == 240 and level.mother_core.nutrition == 100, "third level owns independent planned initial values")
	_check(level.get_weapons().size() == 3, "three connected starting attack organs")
	_check(level.get_node("World/Remains").get_children().map(func(c: Node) -> int: return c.total_nutrition) == [80, 80, 80, 120], "four planned large carcasses")
	_check(targets.size() == 3 and targets.all(func(f: MemoryFragment) -> bool: return f.collection_seconds == 5), "three visible unique five-second objectives")
	_check(targets.all(func(f: MemoryFragment) -> bool: return f.is_visible_in_tree()), "all objectives visible before exploration")
	_check(level.compact_hud.wave_button.text == "收集碎片 0/3", "compact interface uses fragment objective")
	level.compact_hud.open_page(&"wave")
	_check(level.compact_hud._drawer_title.text == "碎片与来袭", "objective drawer retains existing interface style")
	level.compact_hud.close_drawer()
	controller._process(5)
	_check(controller.collected_ids.is_empty(), "remote initial fragments do not collect without coverage")
	var fragment: MemoryFragment = targets[0]
	fragment.position = Vector2(600, 535)
	level.fungal_field.advance(1)
	_check(level.fungal_field.get_collecting_nodes(fragment.global_position).size() >= 2, "overlap fixture has multiple real coverage sources")
	var nutrition: int = level.mother_core.nutrition
	var recovered: int = level.colony_progress.get_total_recovered()
	controller._process(2)
	_check(is_equal_approx(fragment.progress_seconds, 2), "overlap advances once rather than once per source")
	_check(level.mother_core.nutrition == nutrition and level.colony_progress.get_total_recovered() == recovered, "collection neither spends nor creates nutrition or growth credit")
	level.pause_controller.set_paused(true)
	var before: float = level.wave_flow.elapsed_seconds
	controller._process(2)
	await _frames(5)
	_check(fragment.progress_seconds == 2 and level.wave_flow.elapsed_seconds == before, "global pause freezes collection and production")
	_check(not level.start_next_wave(), "paused begin cannot queue deferred production")
	level.pause_controller.set_paused(false)
	# 菌域快照暂未同步时，也必须核实实际网络可达，不能从旧覆盖偷取一帧。
	fragment.position = Vector2(365, 470)
	var edge: HyphaEdge = level.get_node("World/Colony/Connections/CoreLeft")
	level.network_system.unregister_edge(edge)
	_check(not controller.has_effective_coverage(fragment.position), "actual network blocks a stale connected field snapshot")
	level._sync_fungal_sources()
	var state: Dictionary = level.fungal_field.get_source_snapshot(level.get_node("World/Colony/Nodes/LeftGuard"))
	_check(float(state.display_radius) > 0 and not bool(state.connected), "disconnected source retains visible remnant")
	controller._process(2)
	_check(fragment.progress_seconds == 2 and not fragment.collecting, "visual remnant does not collect and partial progress is retained")
	level.network_system.register_edge(edge)
	level._sync_fungal_sources()
	level.fungal_field.advance(1)
	var emitted := [0]
	controller.fragment_collected.connect(func(_id: StringName, _text: String) -> void: emitted[0] += 1)
	controller._process(3)
	_check(fragment.collected and controller.collected_ids.size() == 1, "reconnection resumes retained progress to completion")
	level.network_system.unregister_edge(edge)
	level._sync_fungal_sources()
	controller._process(20)
	_check(fragment.collected and emitted[0] == 1, "completed fragments persist and publish once after disconnection")
	_check(level.wave_flow.get_snapshot().sources.all(func(s: Dictionary) -> bool: return s.remaining >= 15), "collection provides at least fifteen seconds before next batch")
	var duplicate := MemoryFragment.new()
	duplicate.fragment_id = targets[1].fragment_id
	var invalid := FragmentCollectionController.new()
	level.add_child(invalid)
	var invalid_targets: Array[MemoryFragment] = [targets[0], targets[1], duplicate]
	_check(not invalid.configure(level, invalid_targets), "duplicate objective IDs rejected")
	duplicate.free()
	await _dispose(level)


func _production() -> void:
	var level: ThirdLevel = await _fresh()
	var flow: ExplorationProductionController = level.wave_flow
	_check(flow.profile.preparation_seconds == 25 and flow.profile.cycle_seconds == 30, "third-level production timings independent of second level")
	_check(flow.profile.is_valid() and flow.profile.max_alive_per_source == 12, "finite pressure cap is configured")
	var kinds: Array[int] = []
	for index: int in range(3):
		for scene: PackedScene in flow.profile.get_exploration_scenes(999, 1, index, 0):
			var enemy := scene.instantiate() as BasicEnemy
			if not kinds.has(enemy.archetype): kinds.append(enemy.archetype)
			enemy.free()
	_check(kinds.size() == 5 and not kinds.has(BasicEnemy.Archetype.GNAWER), "late pressure includes exactly five formal types without legacy mixed gnawer")
	_check(flow.profile.get_stage(999, 0) == 2 and flow.profile.get_stage(0, 2) == 2, "time and fragment progress independently advance capped stages")
	_check(flow.profile.get_exploration_scenes(999, 1, 2, 0).size() == flow.profile.get_exploration_scenes(99999, 1, 2, 3).size(), "late pressure does not rise without bound")
	flow.profile.cycle_seconds = 0.3
	flow.profile.member_interval = 0.1
	flow.profile.source_stagger_seconds = 0
	flow.profile.max_alive_per_source = 3
	flow.enemy_created.connect(func(enemy: BasicEnemy) -> void: enemy.move_speed = 0)
	_check(level.start_next_wave() and not level.start_next_wave(), "preparation skip accepted once")
	await _frames(100)
	var snapshot: Dictionary = flow.get_snapshot()
	_check(int(snapshot.spawned) == 9, "overlapping batches continue with live previous members and respect per-source cap")
	var ids: Array[String] = []
	for enemy: Node in level.get_node("World/Enemies").get_children():
		var id: String = String(enemy.get_meta("spawn_id", ""))
		ids.append(id)
		_check(enemy.has_meta("source_id") and enemy.has_meta("batch_id"), "source and batch identity retained")
	var unique: Dictionary = {}
	for id: String in ids: unique[id] = true
	_check(unique.size() == ids.size() and not ids.has(""), "all overlapping members have distinct spawn identities")
	_check(not flow._point_is_clear(level.mother_core.global_position), "production rejects tissue overlap")
	_check(not flow._point_is_clear(Vector2(550, 330)), "production rejects terrain obstacle")
	_check(flow.get_snapshot().sources.all(func(s: Dictionary) -> bool: return s.load <= 3), "all alive and pending members count toward cap")
	flow.on_fragment_collected(&"first_creation", "")
	flow.on_fragment_collected(&"first_creation", "")
	_check(flow.get_snapshot().stage == 1, "duplicate collection callback does not advance pressure twice")
	flow.stop(&"test_stop")
	var time: float = flow.elapsed_seconds
	await _frames(10)
	_check(flow.elapsed_seconds == time and flow.get_snapshot().spawned == snapshot.spawned, "stop freezes clocks and pending production without deleting live enemies")
	await _dispose(level)


func _removed_sources() -> void:
	var level: ThirdLevel = await _fresh()
	level.get_fragment_targets()[0].queue_free()
	level.get_node("World/SpawnPoints/LeftEntrance").queue_free()
	await _frames(4)
	_check(level.wave_flow.get_snapshot().state == "stopped", "removed production marker safely stops without freed references")
	_check(level.get_result_snapshot().is_empty() and level.fragment_collection.collected_ids.is_empty(), "removing a fragment cannot fabricate collection or victory")
	await _dispose(level)


func _order(order: Array) -> void:
	var level: ThirdLevel = await _fresh()
	level.fragment_collection.set_process(false)
	var targets: Array[MemoryFragment] = level.get_fragment_targets()
	var finishes := [0]
	level.level_finished.connect(func(_snapshot: Dictionary) -> void: finishes[0] += 1)
	var survivor := preload("res://scenes/enemies/basic_enemy.tscn").instantiate() as BasicEnemy
	survivor.position = Vector2(1100, 500)
	survivor.mother_core = level.mother_core
	level.get_node("World/Enemies").add_child(survivor)
	# 目标验收移动位置；正常地图路线另由 playthrough_test 验证。
	for index: int in order:
		targets[index].global_position = level.mother_core.global_position
		level.fungal_field.advance(1)
		level.fragment_collection._process(5)
	await _frames(3)
	_check(bool(level.get_result_snapshot().get("victory", false)) and finishes[0] == 1, "all collection orders finish once: %s" % [order])
	_check(level.get_result_snapshot().objective.completed == 3 and paused, "terminal snapshot records all three and freezes world")
	_check(survivor.is_alive() and level.wave_flow.get_snapshot().state == "stopped", "third fragment wins without clearing surviving enemies and immediately stops production")
	level.fragment_collection._process(10)
	_check(finishes[0] == 1, "terminal callbacks cannot finish twice")
	await _frames(100)
	_check(is_instance_valid(level.flow_hud._ending_panel) and not level.flow_hud.result_panel.visible, "CG4 placeholder appears after frozen network view")
	level.flow_hud.finish_ending()
	_check(level.flow_hud.result_panel.visible and not level.compact_hud.visible, "CG4 continues to accessible terminal summary")
	await _dispose(level)


func _death_priority(core_first: bool) -> void:
	var level: ThirdLevel = await _fresh()
	level.fragment_collection.set_process(false)
	if core_first: level.mother_core.take_damage(999)
	for fragment: MemoryFragment in level.get_fragment_targets():
		fragment.global_position = level.mother_core.global_position
	level.fungal_field.advance(1)
	# 直接提出目标候选，模拟与母核死亡同帧的两种回调顺序。
	level.finish_level(true, {"completed": 3, "total": 3})
	if not core_first: level.mother_core.take_damage(999)
	await _frames(3)
	_check(not bool(level.get_result_snapshot().get("victory", true)), "core death wins same-frame arbitration in order %s" % core_first)
	_check(not level.flow_hud._ending_pending and level.flow_hud.result_panel.visible, "failure bypasses CG4")
	await _dispose(level)


func _restart_and_link() -> void:
	change_scene_to_packed(LEVEL)
	await _frames(4)
	var old: int = current_scene.get_instance_id()
	current_scene.get_fragment_targets()[0].progress_seconds = 3
	current_scene.pause_controller.set_paused(true)
	current_scene.restart_level()
	await _frames(5)
	_check(current_scene is ThirdLevel and current_scene.get_instance_id() != old and not paused, "paused restart creates fresh third level without global pause residue")
	_check(current_scene.mother_core.nutrition == 100 and current_scene.fragment_collection.collected_ids.is_empty(), "restart restores capital and clears collected IDs")
	_check(current_scene.get_fragment_targets().all(func(f: MemoryFragment) -> bool: return f.progress_seconds == 0), "restart clears partial objective progress")
	# 结尾等待期间重开；旧CG4计时连接必须随旧场景退出断开。
	current_scene.finish_level(true, {"completed": 3, "total": 3})
	await _frames(3)
	_check(current_scene.flow_hud._ending_pending, "victory enters replaceable ending flow")
	current_scene.restart_level()
	await _frames(105)
	_check(current_scene is ThirdLevel and current_scene.get_result_snapshot().is_empty() \
			and not is_instance_valid(current_scene.flow_hud._ending_panel) and not paused, "old ending timer cannot overlay a restarted level")
	current_scene.queue_free()
	await _frames(3)
	change_scene_to_file("res://scenes/levels/second_level.tscn")
	await _frames(4)
	var second := current_scene as SecondLevel
	for facility: AIFacility in second.get_facility_targets(): facility.take_damage(999)
	await _frames(4)
	_check(second.flow_hud.result_continue_button.visible, "second victory exposes third-level transition")
	second.flow_hud.result_continue_button.pressed.emit()
	await _frames(5)
	_check(current_scene is ThirdLevel and not paused, "second-level continue opens third with clean pause state")
	current_scene.queue_free()
	await _frames(3)
