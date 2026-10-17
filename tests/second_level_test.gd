extends SceneTree
## 设施攻击使用真实弹丸；生命周期夹具明确缩短生产时间并直接造成终局伤害。

const LEVEL: PackedScene = preload("res://scenes/levels/second_level.tscn")
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _initial_and_real_attack()
	await _production_and_targets()
	await _death_priority(false)
	await _death_priority(true)
	await _removed_facility()
	await _first_level_link()
	await _restart()
	print("SECOND_LEVEL_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _frames(count: int) -> void:
	for _index: int in range(count):
		await physics_frame
		await process_frame


func _fresh() -> SecondLevel:
	var level := LEVEL.instantiate() as SecondLevel
	root.add_child(level)
	await _frames(3)
	return level


func _dispose(level: SecondLevel) -> void:
	level.queue_free()
	await _frames(3)
	_check(not paused, "scene disposal clears global pause")


func _initial_and_real_attack() -> void:
	var level: SecondLevel = await _fresh()
	_check(level.mother_core.health == 240 and level.mother_core.nutrition == 90, "second level has independent initial capital")
	var configured := preload("res://resources/ai/second_level_production.tres") as AIProductionProfile
	_check(level.wave_flow.profile.is_valid() and level.wave_flow.profile != configured \
			and level.wave_flow.profile.preparation_seconds == configured.preparation_seconds \
			and level.wave_flow.profile.cycle_seconds == configured.cycle_seconds,
		"production uses an isolated copy of the current editable second-level timing configuration")
	_check(level.wave_flow.profile.destruction_grace_seconds == 20, "destruction provides a configured twenty-second grace")
	_check(level.get_facility_targets().map(func(ai: AIFacility) -> int: return ai.health) == [120, 180, 240],
		"three stable facilities retain their independent initial health")
	_check(level.get_node("World/Remains").get_child_count() == 2, "two eighty-nutrient sources are present")
	_check(level.compact_hud.visible and not level.compact_hud.drawer.visible,
		"existing compact interface starts with details collapsed")
	_check(level.compact_hud.wave_button.text == "摧毁 AI 0/3" and not level.compact_hud.pages.has(&"development"),
		"objective replaces finite-wave display without development entries")
	level.compact_hud.open_page(&"wave")
	_check(level.compact_hud._objective_buttons.size() == 3, "objective drawer offers all three selectable targets")
	level.compact_hud.close_drawer()
	_check((level.get_attack_preview(Vector2(330, 440)).covered as PackedStringArray).has("左侧AI"),
		"remote attack preview identifies a covered facility")
	_check((level.get_attack_preview(level.mother_core.global_position).covered as PackedStringArray).is_empty(),
		"initial rear location does not pretend to reach facilities")
	var exit_point: Vector2 = level.get_node("World/Enemies/LeftAI/SpawnPoints/Exit").global_position
	var temporary_tip := Node2D.new()
	level.get_node("World/GrowthTips").add_child(temporary_tip)
	temporary_tip.global_position = exit_point
	temporary_tip.add_to_group("colony_tissues")
	_check(not level.wave_flow._point_is_clear(exit_point), "production avoids a live growth tip at the exit")
	temporary_tip.free()
	_check(not level.wave_flow._point_is_clear(Vector2(530, 645)), "production avoids overlapping an existing silk connection")
	var left: AIFacility = level.get_facility_targets()[0]
	level.prioritize_facility(&"left")
	_check(level.combat_targeting_system.get_priority_target() == left, "AI selection reaches shared damage coordination")
	level.prioritize_facility(&"left")
	_check(level.combat_targeting_system.get_priority_target() == null and not left.prioritized,
		"clicking the same priority target restores automatic threat selection")
	level.prioritize_facility(&"left")
	var probe := preload("res://scenes/enemies/basic_enemy.tscn").instantiate() as BasicEnemy
	probe.mother_core = level.mother_core
	probe.position = Vector2(450, 570)
	level.get_node("World/Enemies").add_child(probe)
	var retired := Node2D.new()
	level.add_child(retired)
	probe._target = retired
	retired.free()
	_check(probe.get_target_snapshot().get("target") == null, "a freed bud target can be inspected safely")
	probe._physics_process(0.1)
	_check(is_instance_valid(probe._target), "an enemy retargets safely after its previous tissue is freed")
	probe.queue_free()
	await _frames(2)
	# Isolated firing fixture: move an existing paid organ into range, without granting ammo or direct damage.
	level.get_node("World/Colony/Nodes/LeftGuard").global_position = left.global_position + Vector2(0, 100)
	var rival := preload("res://scenes/enemies/basic_enemy.tscn").instantiate() as BasicEnemy
	rival.mother_core = level.mother_core
	rival.position = left.position + Vector2(20, 110)
	level.get_node("World/Enemies").add_child(rival)
	var test_weapon: SporeWeapon = level.get_node("World/Colony/Nodes/LeftGuard/SporeWeapon") as SporeWeapon
	var targets: Array[BasicEnemy] = test_weapon._select_targets(test_weapon.get_weapon_profile(),
		test_weapon.inventory_owner.global_position, level.get_node("World/Enemies") as Node2D)
	_check(not targets.is_empty() and targets[0] == left, "selected AI takes priority over a closer ordinary target within range")
	rival.queue_free()
	for record: Dictionary in level.wave_flow._sources.values(): record.remaining = 1000.0
	for _index: int in range(2400):
		if not left.is_alive(): break
		await _frames(1)
	_check(not left.is_alive(), "ordinary projectiles destroy a facility through real ammunition and supply")
	_check(level.get_node("World/Remains").get_child_count() == 2, "facility destruction creates no enemy corpse")
	var ledger: Dictionary = level.get_combat_resource_snapshot()
	_check(ledger.enemy_created_nutrition == 0 and ledger.balanced, "facility destruction provides no income and preserves the resource ledger")
	left.take_damage(999)
	_check(level.wave_flow.destroyed_ids == [&"left"], "repeated facility damage cannot count a target twice")
	_check(level.combat_targeting_system.get_priority_target() == null and not left.prioritized, "destroyed priority target is retired")
	await _dispose(level)


func _production_and_targets() -> void:
	var level: SecondLevel = await _fresh()
	var producer: AIProductionController = level.wave_flow
	producer.profile.cycle_seconds = 0.35
	producer.profile.normal_count = 2
	producer.profile.member_interval = 0.8
	producer.profile.destruction_grace_seconds = 0.1
	producer.profile.max_alive_per_source = 18
	producer.enemy_created.connect(func(enemy: BasicEnemy) -> void: enemy.move_speed = 0.0)
	_check(level.start_next_wave(), "initial preparation may be ended through the existing start intent")
	_check(not level.start_next_wave(), "repeated start intent cannot repeat initial preparation")
	await _frames(80)
	_check(int(producer._sources[&"left"].cycles) > 1 and producer._source_load(&"left") > 2,
		"new batches are produced while older members are alive")
	var before: Dictionary = producer.get_snapshot()
	level.pause_controller.set_paused(true)
	var frozen_time: float = producer.elapsed_seconds
	await _frames(20)
	_check(producer.elapsed_seconds == frozen_time and producer.get_snapshot().spawned == before.spawned,
		"pause freezes production without spawning catch-up members")
	level.pause_controller.set_paused(false)
	var left_survivors: Array[BasicEnemy] = []
	for enemy: Node in level.get_node("World/Enemies").get_children():
		if enemy is BasicEnemy and enemy.get_meta("source_id", &"") == &"left": left_survivors.append(enemy)
	level.get_facility_targets()[0].take_damage(999)
	var left_cycles: int = int(producer._sources[&"left"].cycles)
	var center_cycles: int = int(producer._sources[&"center"].cycles)
	await _frames(80)
	_check(int(producer._sources[&"left"].cycles) == left_cycles,
		"destroyed facility permanently stops all its future batches")
	_check(int(producer._sources[&"center"].cycles) > center_cycles,
		"other facility continues its own production")
	_check(left_survivors.all(func(enemy: BasicEnemy) -> bool: return is_instance_valid(enemy) and enemy.is_alive()),
		"source destruction preserves already spawned enemies and their identities")
	_check(producer._source_load(&"left") == left_survivors.size(),
		"destroying a source cancels its pending members instead of releasing them later")
	await _frames(120)
	_check(producer._source_load(&"center") <= 18, "production remains bounded by configured live-plus-pending pressure")
	# Target strategy fixtures use a live map with closer, nonmatching tissues.
	for spec: Array in [["silk_gnawer_enemy", HyphaEdge], ["junction_gnawer_enemy", HyphaNode]]:
		var gnawer := load("res://scenes/enemies/%s.tscn" % spec[0]).instantiate() as BasicEnemy
		gnawer.mother_core = level.mother_core
		gnawer.network_system = level.network_system
		gnawer.terrain_navigation = level.terrain_navigation
		gnawer.position = Vector2(480, 610)
		level.get_node("World/Enemies").add_child(gnawer)
		var choice: Dictionary = gnawer._choose_target()
		_check(not choice.is_empty() and is_instance_of(choice.get("target"), spec[1]),
			"%s only selects its own legal tissue" % spec[0])
		gnawer.position = Vector2(1120, 160)
		_check(gnawer._choose_target().is_empty(), "%s never falls back to core or organs" % spec[0])
		gnawer.queue_free()
	var kinds: Array[int] = []
	for source: int in range(3):
		for scene: PackedScene in producer.profile.get_scenes_for_cycle(producer.profile.full_after_seconds + 1, 0, source):
			var sample := scene.instantiate() as BasicEnemy
			if not kinds.has(sample.get_archetype()): kinds.append(sample.get_archetype())
			sample.free()
	kinds.sort()
	_check(kinds == [0, 1, 2, 4, 5], "capped advanced production includes all five formal enemies, excluding legacy gnawer")
	level.get_facility_targets()[1].take_damage(999)
	level.get_facility_targets()[2].take_damage(999)
	await _frames(3)
	_check(bool(level.get_result_snapshot().get("victory", false)), "all facilities win immediately with live spawned enemies remaining")
	_check(level.flow_hud.result_panel.visible and not level.compact_hud.visible,
		"objective result is visible and compact controls close at the same terminal event")
	await _dispose(level)


func _death_priority(core_first: bool) -> void:
	var level: SecondLevel = await _fresh()
	var count := [0]
	level.level_finished.connect(func(_snapshot: Dictionary) -> void: count[0] += 1)
	if core_first: level.mother_core.take_damage(999)
	for facility: AIFacility in level.get_facility_targets(): facility.take_damage(999)
	if not core_first: level.mother_core.take_damage(999)
	await _frames(3)
	_check(not bool(level.get_result_snapshot().get("victory", true)) and count[0] == 1,
		"same-frame core death overrides all objectives in callback order %s" % core_first)
	await _dispose(level)


func _restart() -> void:
	change_scene_to_packed(LEVEL)
	await _frames(3)
	var old_id: int = current_scene.get_instance_id()
	current_scene.pause_controller.set_paused(true)
	current_scene.restart_level()
	await _frames(4)
	_check(current_scene is SecondLevel and current_scene.get_instance_id() != old_id and not paused,
		"paused restart replaces the scene and clears pause")
	_check(current_scene.mother_core.nutrition == 90 and current_scene.wave_flow.destroyed_ids.is_empty(),
		"restart restores independent second-level capital and all targets")
	current_scene.queue_free()
	await _frames(3)


func _removed_facility() -> void:
	var level: SecondLevel = await _fresh()
	level.get_facility_targets()[0].queue_free()
	await _frames(3)
	_check(level.wave_flow.destroyed_ids.is_empty() and level.get_result_snapshot().is_empty(),
		"removing a facility does not fabricate destruction or victory")
	_check(level.wave_flow.get_snapshot().state == "stopped", "invalid facility removal safely stops production")
	await _dispose(level)


func _first_level_link() -> void:
	change_scene_to_file("res://scenes/levels/first_level.tscn")
	await _frames(4)
	var first := current_scene as FirstLevel
	# Navigation fixture: result evidence is injected only to exercise the accepted next-scene intent.
	first._result_snapshot = {"victory": true}
	first.flow_hud.show_result(first._result_snapshot)
	first.flow_hud.show_continue("进入第二关")
	_check(first.flow_hud.result_continue_button.visible, "first-level victory offers a visible next-level button")
	first.flow_hud.result_continue_button.pressed.emit()
	await _frames(4)
	_check(current_scene is SecondLevel and not paused and current_scene.mother_core.nutrition == 90,
		"next-level button starts a fresh second level with its own capital")
	current_scene.queue_free()
	await _frames(3)
