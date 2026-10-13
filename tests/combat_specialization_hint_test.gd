extends SceneTree
## UNIT 提示契约：成熟收件、分化材料和有效时间均由测试显式构造。
## 使用生产场景/任务/批次身份，但不代表真实采集收入、付费运输或完整实机战斗验收。
## 提示控制器始终只观察；所有分化命令只由本测试独立发起。

class WeaponSourceFixture:
	extends Node

	var weapons: Array[SporeWeapon] = []

	func get_weapons() -> Array[SporeWeapon]:
		return weapons.duplicate()

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var nodes: Node2D
	var edges: Node2D
	var enemies: Node2D
	var projectiles: Node2D
	var points: Node2D
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var network: NetworkSystem
	var differentiation: DifferentiationSystem
	var supply: SupplySystem
	var spawner: EnemySpawner
	var source: WeaponSourceFixture
	var controller: CombatSpecializationHintController
	var organs: Array[AttackOrgan] = []
	var events: Array[Dictionary] = []

const HINT_SCRIPT: GDScript = preload("res://scripts/combat_specialization_hint_controller.gd")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const HOST_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const SPAWNER_SCENE: PackedScene = preload("res://scenes/systems/enemy_spawner.tscn")
const NORMAL_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const SWARM_SCENE: PackedScene = preload("res://scenes/enemies/swarm_enemy.tscn")
const ARMORED_SCENE: PackedScene = preload("res://scenes/enemies/armored_enemy.tscn")
const PIERCING_PROFILE: WeaponProfile = preload("res://resources/weapons/armor_piercing_spore.tres")
const SCATTER_PROFILE: WeaponProfile = preload("res://resources/weapons/scatter_spore.tres")
const PIERCING: int = WeaponProfile.DamageType.ARMOR_PIERCING
const SCATTER: int = WeaponProfile.DamageType.SCATTER
const EXPECTED_IDS: Array[StringName] = [
	&"mature_unlocked", &"differentiation_started", &"differentiation_ceasefire",
	&"piercing_completed", &"scatter_completed", &"armored_encounter",
	&"swarm_encounter", &"ammunition_wait",
]

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []
var _worlds: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_false_payloads_and_copies()
	_test_read_only_and_idempotent_configuration()
	_test_all_eight_and_real_task_states()
	_test_completed_type_requires_matching_record()
	_test_ammunition_requires_active_in_range_combat()
	_test_dynamic_weapons_and_paused_differentiation()
	_test_pending_facts_expire_without_replay()
	_test_disabled_history_and_reset_preferences()
	_test_reentrant_dismiss()
	_test_reentrant_disable()
	_test_replacement_reset_and_retired_callbacks()
	_test_stopped_sources_and_invalid_spawn_members()
	await _test_queued_and_freed_sources()
	_free_fixtures()
	await process_frame
	await process_frame
	_check(root.get_child_count() == initial_children, "Hint fixture teardown leaves no scene nodes")
	print("COMBAT_SPECIALIZATION_HINT_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(configure_now: bool = true) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	_worlds.append(weakref(fixture.world))
	root.add_child(fixture.world)
	fixture.nodes = Node2D.new()
	fixture.edges = Node2D.new()
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.points = Node2D.new()
	for container: Node2D in [
		fixture.nodes, fixture.edges, fixture.enemies, fixture.projectiles, fixture.points,
	]:
		fixture.world.add_child(container)
	for point: Vector2 in [Vector2(800, 350), Vector2(100, 350)]:
		var anchor := Marker2D.new()
		anchor.position = point
		fixture.points.add_child(anchor)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = 72
	fixture.core.position = Vector2(400, 500)
	fixture.world.add_child(fixture.core)
	fixture.progress = ColonyProgress.new()
	fixture.world.add_child(fixture.progress)
	fixture.capabilities = ColonyCapabilities.new()
	fixture.capabilities.colony_progress = fixture.progress
	fixture.world.add_child(fixture.capabilities)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "UNIT registers the production core")
	fixture.source = WeaponSourceFixture.new()
	fixture.world.add_child(fixture.source)
	fixture.supply = SupplySystem.new()
	fixture.supply.mother_core = fixture.core
	fixture.supply.network_system = fixture.network
	fixture.world.add_child(fixture.supply)
	# 没有派送计时器/运输夹具，观察测试不会自动扣款或运送材料。
	_add_pair(fixture, Vector2(300, 350))
	_add_pair(fixture, Vector2(500, 350))
	fixture.differentiation = DifferentiationSystem.new()
	fixture.differentiation.colony_capabilities = fixture.capabilities
	fixture.differentiation.network_system = fixture.network
	fixture.world.add_child(fixture.differentiation)
	fixture.differentiation.set_physics_process(false)
	fixture.spawner = SPAWNER_SCENE.instantiate() as EnemySpawner
	fixture.spawner.auto_start = false
	fixture.spawner.mother_core = fixture.core
	fixture.spawner.enemy_container = fixture.enemies
	fixture.spawner.spawn_points = fixture.points
	fixture.world.add_child(fixture.spawner)
	fixture.spawner.enemy_spawned.connect(func(enemy: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
		# UNIT 冻结移动，保留活体、真实入树和生产批次身份。
		if is_instance_valid(enemy):
			enemy.set_physics_process(false)
	)
	fixture.controller = HINT_SCRIPT.new() as CombatSpecializationHintController
	fixture.world.add_child(fixture.controller)
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.events.append(snapshot.duplicate(true))
		_check_snapshot_shape(snapshot)
		_check(snapshot == fixture.controller.get_snapshot(), "Published snapshot matches current live presentation")
	)
	if configure_now:
		_configure(fixture)
	return fixture


func _add_pair(fixture: Fixture, position: Vector2) -> SporeWeapon:
	var host := HOST_SCENE.instantiate() as HyphaNode
	host.position = position
	fixture.nodes.add_child(host)
	_check(fixture.network.register_node(host), "UNIT registers a production attack host")
	var edge := EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = fixture.core
	edge.end_node = host
	fixture.edges.add_child(edge)
	_check(fixture.network.register_edge(edge), "UNIT registers the host's real connection")
	var organ := ORGAN_SCENE.instantiate() as AttackOrgan
	organ.initial_nutrition = 4
	host.add_child(organ)
	fixture.organs.append(organ)
	_check(fixture.supply.register_organ(organ), "UNIT registers its ordinary combat inventory")
	var weapon := WEAPON_SCENE.instantiate() as SporeWeapon
	weapon.inventory_owner = organ
	weapon.enemy_container = fixture.enemies
	weapon.projectile_container = fixture.projectiles
	host.add_child(weapon)
	fixture.source.weapons.append(weapon)
	return weapon


func _configure(fixture: Fixture, sources: Fixture = null) -> void:
	var current: Fixture = sources if sources != null else fixture
	fixture.controller.configure(current.progress, current.differentiation,
		current.spawner, current.supply, current.source)


func _check_snapshot_shape(snapshot: Dictionary) -> void:
	_check(snapshot.has_all(["enabled", "visible", "id", "text", "pending_count", "seen_ids", "generation"]),
		"Snapshot contains the frozen public fields")
	_check(snapshot.get("enabled") is bool and snapshot.get("visible") is bool
		and snapshot.get("id") is StringName and snapshot.get("text") is String
		and snapshot.get("pending_count") is int and snapshot.get("seen_ids") is Array
		and snapshot.get("generation") is int, "Snapshot fields have the public types")
	_check(int(snapshot.get("pending_count", -1)) >= 0, "Pending count is never negative")
	if bool(snapshot.get("visible", false)):
		_check(EXPECTED_IDS.has(snapshot["id"]) and not String(snapshot["text"]).is_empty(),
			"Visible hint uses exactly one of the eight IDs")
	else:
		_check(snapshot.get("id") == &"" and snapshot.get("text") == "",
			"Hidden snapshot has no visible ID or text")


func _drain(fixture: Fixture) -> Array[StringName]:
	var shown: Array[StringName] = []
	for _index: int in range(EXPECTED_IDS.size() + 1):
		var snapshot: Dictionary = fixture.controller.get_snapshot()
		if snapshot["visible"]:
			shown.append(snapshot["id"])
			_check(fixture.controller.dismiss_current(), "A visible current hint can be dismissed")
	_check(not fixture.controller.get_snapshot()["visible"]
		and fixture.controller.get_snapshot()["pending_count"] == 0, "Dismiss drains the bounded queue")
	_check(not fixture.controller.dismiss_current(), "Empty dismissal returns false")
	return shown


func _unit_mature(fixture: Fixture) -> void:
	# UNIT ONLY：收件边界是合成的，母核没有得到对应营养收入。
	var missing: int = ColonyProgress.MATURE_THRESHOLD - fixture.progress.get_total_recovered()
	if missing > 0:
		_check(fixture.progress.record_arrival("unit:hint:mature", missing),
			"UNIT synthesized maturity receipt; not paid gameplay income")
	_check(fixture.core.nutrition == 72 and fixture.core.get_received_product_count() == 0,
		"UNIT maturity fixture never credits mother-core funds")


func _unit_start(fixture: Fixture, organ: AttackOrgan, direction: int) -> int:
	# 测试模拟玩家命令；控制器没有开工/推进接口，也不作为命令来源。
	var task_id: int = fixture.differentiation.start_differentiation(organ, direction)
	_check(task_id > 0, "UNIT test command independently starts a production differentiation task")
	return task_id


func _unit_fund_and_complete(fixture: Fixture, task_id: int) -> void:
	if task_id <= 0:
		return
	_check(fixture.differentiation.receive_nutrition(task_id, "unit:hint:materials:%d" % task_id, 8),
		"UNIT synthesized material delivery; not transported or debited from the core")
	fixture.differentiation.advance(5.0)
	_check(fixture.differentiation.get_task_snapshot(task_id).get("state") == &"completed",
		"Production task reaches completion after UNIT effective-time advancement")


func _unit_deplete_to(organ: AttackOrgan, remaining: int) -> void:
	var amount: int = organ.nutrition - remaining
	if amount > 0:
		_check(organ.consume_nutrition(amount), "UNIT explicitly constructs a low-stock inventory")


func _start_batch(fixture: Fixture, scene: PackedScene, point: int = 0, count: int = 1) -> String:
	var entry := EnemySpawnEntry.new()
	entry.enemy_scene = scene
	entry.group_count = 1
	entry.group_size = count
	entry.group_interval = 1.0
	entry.member_interval = 0.0
	entry.member_spacing = 24.0
	entry.spawn_point_index = point
	fixture.spawner.spawn_entries = [entry]
	var batch_id: String = fixture.spawner.start_batch()
	_check(not batch_id.is_empty(), "UNIT actual production batch accepts its manual start command")
	_check(fixture.spawner.get_active_count() == count,
		"Production enemy_spawned members have actual registered live identities")
	return batch_id


func _batch_enemy(fixture: Fixture) -> BasicEnemy:
	var result: BasicEnemy = null
	for child: Node in fixture.enemies.get_children():
		if child is BasicEnemy and fixture.spawner.has_active_enemy(child) and child.is_alive():
			result = child as BasicEnemy
	return result


func _unit_enemy(fixture: Fixture, position: Vector2, scene: PackedScene = NORMAL_SCENE) -> BasicEnemy:
	# UNIT ONLY：射程/活体负例不声称敌人是已生成批次成员。
	var enemy := scene.instantiate() as BasicEnemy
	enemy.mother_core = fixture.core
	enemy.position = position
	fixture.enemies.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy


func _economic_snapshot(fixture: Fixture) -> Dictionary:
	var organs: Array[Dictionary] = []
	var weapons: Array[Dictionary] = []
	var enemies: Array[Dictionary] = []
	for organ: AttackOrgan in fixture.organs:
		organs.append({"id": organ.get_instance_id(), "stored": organ.nutrition,
			"incoming": organ.incoming_nutrition, "work_enabled": organ.is_work_enabled()})
	for weapon: SporeWeapon in fixture.source.weapons:
		var timer: Timer = weapon.get_node("FireTimer") as Timer
		var profile: WeaponProfile = weapon.get_weapon_profile()
		weapons.append({"id": weapon.get_instance_id(), "statistics": weapon.get_shot_statistics(),
			"damage": profile.damage, "type": int(profile.damage_type), "cost": profile.nutrition_cost,
			"range": profile.attack_range, "interval": profile.fire_interval,
			"timer_stopped": timer.is_stopped(), "timer_paused": timer.paused,
			"timer_left": timer.time_left, "timer_interval": timer.wait_time})
	for child: Node in fixture.enemies.get_children():
		if child is BasicEnemy and not child.is_queued_for_deletion():
			var timer: Timer = child.get_node("AttackTimer") as Timer
			enemies.append({"id": child.get_instance_id(), "health": child.health,
				"position": child.global_position, "timer_stopped": timer.is_stopped(),
				"timer_left": timer.time_left, "timer_interval": timer.wait_time})
	return {
		"balance": fixture.core.nutrition, "core_health": fixture.core.health,
		"received_products": fixture.core.get_received_product_count(),
		"recovered": fixture.progress.get_total_recovered(), "organs": organs,
		"weapons": weapons, "enemies": enemies,
		"task": fixture.differentiation.get_task_snapshot().duplicate(true),
		"resources": fixture.differentiation.get_resource_snapshot(),
		"batch": fixture.spawner.get_batch_snapshot(),
		"in_transit": fixture.supply.get_in_transit_count(),
		"delivered": fixture.supply.delivered_packets, "interrupted": fixture.supply.interrupted_packets,
		"projectile_count": fixture.projectiles.get_child_count(),
	}


func _check_observation_read_only(fixture: Fixture, description: String) -> void:
	var before: Dictionary = _economic_snapshot(fixture)
	for _index: int in range(12):
		fixture.controller.get_snapshot()
		fixture.controller._process(0.0)
	_check(_economic_snapshot(fixture) == before, description)


func _connection_count(source: Node, signal_name: StringName, controller: CombatSpecializationHintController) -> int:
	var count: int = 0
	for connection: Dictionary in source.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == controller:
			count += 1
	return count


func _capture_callback(source: Node, signal_name: StringName, controller: CombatSpecializationHintController) -> Callable:
	var result: Callable = Callable()
	_check(_connection_count(source, signal_name, controller) == 1, "Exactly one binding for " + String(signal_name))
	for connection: Dictionary in source.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == controller:
			result = callback
	return result


func _emit_duplicates(fixture: Fixture) -> void:
	fixture.progress.progress_changed.emit(160, 1)
	fixture.progress.stage_unlocked.emit(ColonyProgress.Stage.MATURE)
	fixture.differentiation.task_changed.emit({"state": &"completed"})
	fixture.differentiation.task_completed.emit(9999)
	fixture.spawner.batch_changed.emit({"state": "draining", "active": 99})
	fixture.supply.transport_changed.emit(99, 99, 99)
	fixture.controller._process(0.0)


func _test_false_payloads_and_copies() -> void:
	var fixture: Fixture = _new_fixture()
	_emit_duplicates(fixture)
	fixture.progress.stage_changed.emit(ColonyProgress.Stage.NASCENT, ColonyProgress.Stage.MATURE)
	fixture.differentiation.organ_differentiated.emit(9999, fixture.organs[0], PIERCING)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Claimed maturity/completion payloads do not prove actual state")
	_check(not fixture.controller.get_snapshot()["visible"], "Initial funds and ordinary stocks do not unlock hints")
	var fake: BasicEnemy = _unit_enemy(fixture, Vector2(600, 350), ARMORED_SCENE)
	fake.set_meta(&"spawn_id", "unit:forged")
	fake.set_meta(&"batch_id", "unit:forged_batch")
	fixture.spawner.enemy_spawned.emit(fake, "unit:forged", "unit:forged_batch")
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "An idle spawner's forged enemy payload is ignored")
	var batch_id: String = _start_batch(fixture, NORMAL_SCENE)
	fake.set_meta(&"batch_id", batch_id)
	fixture.spawner.enemy_spawned.emit(fake, "unit:forged", batch_id)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(),
		"Matching batch metadata cannot replace actual spawner member registration")
	_check(fixture.progress.record_arrival("unit:hint:159", 159), "UNIT constructs the maturity boundary at 159")
	_check(not fixture.controller.get_snapshot()["visible"], "Recovery below 160 stays locked")
	_check(fixture.progress.record_arrival("unit:hint:160", 1), "UNIT reaches the exact maturity boundary")
	var snapshot: Dictionary = fixture.controller.get_snapshot()
	_check(snapshot["id"] == &"mature_unlocked" and String(snapshot["text"]).contains("8材料")
		and String(snapshot["text"]).contains("5秒") and String(snapshot["text"]).contains("破甲"),
		"Actual current MATURE unlocks the brief rule hint with the official armor-breaking name")
	snapshot["seen_ids"].append(&"ammunition_wait")
	snapshot["text"] = "changed outside controller"
	snapshot["generation"] = -1
	_check(fixture.controller.get_snapshot()["seen_ids"] == [&"mature_unlocked"]
		and fixture.controller.get_snapshot()["generation"] > 0, "Queries return independent snapshot copies")
	_check(_drain(fixture) == [&"mature_unlocked"], "Maturity appears once")
	_emit_duplicates(fixture)
	_check(not fixture.controller.get_snapshot()["visible"], "Duplicate claimed events cannot replay dismissed hints")
	evidence.append({"case": "source_truth_and_copies", "scope": "UNIT synthetic maturity and forged negative payloads",
		"forged_members_rejected": true, "threshold": 160})


func _test_read_only_and_idempotent_configuration() -> void:
	var fixture: Fixture = _new_fixture(false)
	_unit_mature(fixture)
	var before: Dictionary = _economic_snapshot(fixture)
	_configure(fixture)
	var generation: int = fixture.controller.get_snapshot()["generation"]
	var event_count: int = fixture.events.size()
	for _index: int in range(12):
		_configure(fixture)
		fixture.controller.get_snapshot()
		fixture.controller._process(0.0)
	_check(_economic_snapshot(fixture) == before, "Configure/query/refresh preserve balance, stocks, health, clocks and configuration")
	_check(fixture.controller.get_snapshot()["generation"] == generation and fixture.events.size() == event_count,
		"Identical source configure preserves generation and notification deduplication")
	for binding: Array in [
		[fixture.progress, &"progress_changed"], [fixture.differentiation, &"task_changed"],
		[fixture.spawner, &"enemy_spawned"], [fixture.supply, &"transport_changed"],
	]:
		_check(_connection_count(binding[0], binding[1], fixture.controller) == 1,
			"Identical configure keeps one source signal binding")
	evidence.append({"case": "read_only_and_same_sources", "scope": "UNIT synchronous observation",
		"balance": fixture.core.nutrition, "inventories": [fixture.organs[0].nutrition, fixture.organs[1].nutrition],
		"business_snapshot_unchanged": true})


func _test_all_eight_and_real_task_states() -> void:
	var fixture: Fixture = _new_fixture()
	var shown: Array[StringName] = []
	_unit_mature(fixture)
	shown.append_array(_drain(fixture))
	var piercing_id: int = _unit_start(fixture, fixture.organs[0], PIERCING)
	var waiting: Dictionary = fixture.differentiation.get_task_snapshot(piercing_id)
	var timer: Timer = fixture.source.weapons[0].get_node("FireTimer") as Timer
	_check(waiting.get("state") == &"waiting" and not fixture.organs[0].is_work_enabled() and timer.is_stopped(),
		"Actual waiting task and real stopped timer precede ceasefire hints")
	_check(fixture.controller.get_snapshot()["id"] == &"differentiation_started"
		and fixture.controller.get_snapshot()["pending_count"] == 1, "Start and ceasefire queue once in order")
	_check_observation_read_only(fixture, "Active-task queries cannot pay stages or advance effective time")
	shown.append_array(_drain(fixture))
	_check(fixture.differentiation.pause_task(), "UNIT player command pauses the real task")
	_check(not fixture.organs[0].is_work_enabled() and timer.is_stopped(), "Pause retains real differentiation ceasefire")
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["seen_ids"].has(&"ammunition_wait"), "Paused differentiation is never an ammo shortage")
	_check(fixture.differentiation.resume_task(), "UNIT player command resumes the real task")
	_check(fixture.differentiation.receive_nutrition(piercing_id, "unit:hint:early_material", 8),
		"UNIT synthetic materials reach the production task")
	fixture.differentiation.advance(4.9)
	fixture.differentiation.organ_differentiated.emit(piercing_id, fixture.organs[0], PIERCING)
	fixture.differentiation.task_completed.emit(piercing_id)
	_check(not fixture.controller.get_snapshot()["seen_ids"].has(&"piercing_completed"),
		"Claimed completion cannot skip the real minimum effective interval")
	_check_observation_read_only(fixture, "Near-completion hint reads preserve paid/time state")
	fixture.differentiation.advance(0.2)
	_check(fixture.organs[0].has_completed_differentiation() and fixture.organs[0].get_attack_type() == PIERCING,
		"Actual paid record and actual weapon type prove piercing completion")
	_check(String(fixture.controller.get_snapshot()["text"]).contains("每轮2")
		and String(fixture.controller.get_snapshot()["text"]).contains("破甲分化完成"),
		"Piercing text uses the official armor-breaking name and actual whole-round fee")
	shown.append_array(_drain(fixture))
	var scatter_id: int = _unit_start(fixture, fixture.organs[1], SCATTER)
	_unit_fund_and_complete(fixture, scatter_id)
	var scatter_hint: Dictionary = fixture.controller.get_snapshot()
	_check(scatter_hint["id"] == &"scatter_completed" and String(scatter_hint["text"]).contains("60度")
		and String(scatter_hint["text"]).contains("3个不同目标") and String(scatter_hint["text"]).contains("整轮1"),
		"Scatter text describes distinct targets and its real whole-round fee")
	shown.append_array(_drain(fixture))
	_start_batch(fixture, SWARM_SCENE, 0, 3)
	_check(fixture.controller.get_snapshot()["id"] == &"swarm_encounter", "Real current-batch live small members trigger the swarm hint")
	shown.append_array(_drain(fixture))
	fixture.spawner.reset()
	_start_batch(fixture, ARMORED_SCENE, 1)
	var armored: BasicEnemy = _batch_enemy(fixture)
	_check(armored != null and armored.armor == 4 and armored.get_archetype() == BasicEnemy.Archetype.ARMORED,
		"Encounter comes from a real current-batch armored scene")
	shown.append_array(_drain(fixture))
	if armored != null:
		armored.global_position = fixture.organs[0].global_position + Vector2(80, 0)
	_unit_deplete_to(fixture.organs[0], 1)
	fixture.controller._process(0.0)
	_check(fixture.controller.get_snapshot()["id"] == &"ammunition_wait"
		and fixture.source.weapons[0].get_nutrition_cost() == 2, "One stored nutrient cannot pay a real two-nutrient active piercing round")
	_check_observation_read_only(fixture, "Combat hint queries never damage, shoot, dispatch or restart clocks")
	shown.append_array(_drain(fixture))
	var seen: Array = fixture.controller.get_snapshot()["seen_ids"]
	_check(shown.size() == 8 and seen.size() == 8, "UNIT sequence observes exactly eight distinct contracted hint IDs")
	for id: StringName in EXPECTED_IDS:
		_check(shown.count(id) == 1 and seen.count(id) == 1, "Exactly once hint identity: " + String(id))
	var event_count: int = fixture.events.size()
	_emit_duplicates(fixture)
	_configure(fixture)
	_check(fixture.events.size() == event_count, "Duplicate callbacks and identical configure cannot repeat the completed sequence")
	evidence.append({"case": "all_eight_actual_source_states", "scope": "UNIT synthetic maturity/materials/effective time; production task and spawn identities",
		"shown_ids": shown, "material_fixture_debits_core": false,
		"minimum_effective_time": fixture.differentiation.get_task_snapshot(scatter_id).get("effective_time"),
		"live_gameplay_acceptance": false})


func _test_completed_type_requires_matching_record() -> void:
	var fixture: Fixture = _new_fixture(false)
	_unit_mature(fixture)
	var task_id: int = _unit_start(fixture, fixture.organs[0], PIERCING)
	_unit_fund_and_complete(fixture, task_id)
	_check(fixture.source.weapons[0].configure_profile(SCATTER_PROFILE), "UNIT constructs an actual profile/record mismatch")
	_configure(fixture)
	_check(_drain(fixture) == [&"mature_unlocked"] and fixture.controller.get_snapshot()["seen_ids"] == [&"mature_unlocked"],
		"A completed piercing record with actual scatter type proves neither matching completion hint")
	fixture.differentiation.organ_differentiated.emit(task_id, fixture.organs[0], SCATTER)
	_check(not fixture.controller.get_snapshot()["visible"], "Completion signal direction cannot override the owned record's actual direction")
	_check(fixture.source.weapons[0].configure_profile(PIERCING_PROFILE), "UNIT restores the true completed profile")
	fixture.controller._process(0.0)
	_check(_drain(fixture) == [&"piercing_completed"], "Only the matching actual completed record and actual type unlock the hint")


func _test_ammunition_requires_active_in_range_combat() -> void:
	var fixture: Fixture = _new_fixture()
	var weapon: SporeWeapon = fixture.source.weapons[0]
	var organ: AttackOrgan = fixture.organs[0]
	_check(weapon.configure_profile(PIERCING_PROFILE), "UNIT installs a two-nutrient cost solely for ammo boundary checks")
	_unit_deplete_to(organ, 1)
	fixture.controller._process(0.0)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Low stock without enemies never opens an ammo hint")
	var enemy: BasicEnemy = _unit_enemy(fixture, organ.global_position + Vector2(179, 0))
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "Live out-of-range enemy cannot trigger ammo wait")
	enemy.global_position = organ.global_position + Vector2(100, 0)
	weapon.set_firing_enabled(false)
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "Disabled weapon cannot be reported as waiting for ammunition")
	weapon.set_firing_enabled(true)
	var timer: Timer = weapon.get_node("FireTimer") as Timer
	timer.paused = true
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "Paused firing timer cannot be reported as an active weapon")
	timer.paused = false
	weapon.process_mode = Node.PROCESS_MODE_DISABLED
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "Unprocessable weapon cannot trigger ammo wait")
	weapon.process_mode = Node.PROCESS_MODE_INHERIT
	fixture.supply.unregister_organ(organ)
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "Unregistered combat stock is not a supplied weapon's ammo wait")
	_check(fixture.supply.register_organ(organ), "UNIT restores the real combat registration")
	enemy.health = 0
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "UNIT dead enemy is not a live in-range target")
	enemy.health = enemy.max_health
	_check(organ.reserve_nutrition(1) and organ.complete_delivery(1), "UNIT raises stock to the exact actual volley fee")
	fixture.controller._process(0.0)
	_check(not fixture.controller.get_snapshot()["visible"], "Stock equal to the whole-round cost is sufficient")
	_unit_deplete_to(organ, 1)
	fixture.controller._process(0.0)
	_check(_drain(fixture) == [&"ammunition_wait"], "Active, registered, underfunded, in-range live combat produces the single ammo hint")
	evidence.append({"case": "ammo_predicates", "scope": "UNIT direct range/health and stock fixture",
		"no_enemy_empty_stock_rejected": true, "paused_weapon_rejected": true, "actual_cost": 2})


func _test_dynamic_weapons_and_paused_differentiation() -> void:
	var dynamic: Fixture = _new_fixture()
	dynamic.source.weapons.clear()
	var added: SporeWeapon = _add_pair(dynamic, Vector2(650, 350))
	dynamic.source.weapons.clear()
	_unit_deplete_to(added.inventory_owner, 0)
	_unit_enemy(dynamic, added.inventory_owner.global_position + Vector2(20, 0))
	dynamic.controller._process(0.0)
	_check(not dynamic.controller.get_snapshot()["visible"], "Unlisted newly cultivated weapon is not fabricated by the hint observer")
	dynamic.source.weapons.append(added)
	dynamic.controller._process(0.0)
	_check(_drain(dynamic) == [&"ammunition_wait"], "Original get_weapons API discovers a newly added combat weapon")
	var paused: Fixture = _new_fixture()
	_unit_mature(paused)
	_drain(paused)
	_unit_deplete_to(paused.organs[0], 0)
	_unit_enemy(paused, paused.organs[0].global_position + Vector2(20, 0))
	var task_id: int = _unit_start(paused, paused.organs[0], PIERCING)
	_check(task_id > 0 and paused.differentiation.pause_task(), "UNIT constructs a genuinely paused production differentiation task")
	_drain(paused)
	paused.controller._process(0.0)
	_check(not paused.controller.get_snapshot()["seen_ids"].has(&"ammunition_wait"),
		"Real waiting/paused differentiation with empty stock is never ammo wait")
	_check_observation_read_only(paused, "Paused differentiation queries preserve stock, stage time and the stopped timer")


func _test_pending_facts_expire_without_replay() -> void:
	var fixture: Fixture = _new_fixture()
	_unit_mature(fixture)
	_unit_start(fixture, fixture.organs[0], PIERCING)
	_check(fixture.controller.get_snapshot()["pending_count"] == 2, "Mature presentation holds two real pending task hints")
	_check(fixture.differentiation.cancel_task(), "UNIT cancels the real queued task")
	_check(fixture.controller.get_snapshot()["pending_count"] == 0, "Cancelled task facts are removed before presentation")
	_check(_drain(fixture) == [&"mature_unlocked"], "Dismiss does not claim current ceasefire after cancellation")
	var continuation: int = fixture.differentiation.continue_differentiation(fixture.organs[0])
	_check(continuation > 0 and not fixture.controller.get_snapshot()["visible"],
		"Continuation cannot replay first-time task hints discarded after cancellation")
	var still: Fixture = _new_fixture()
	_unit_mature(still)
	_drain(still)
	_unit_start(still, still.organs[0], PIERCING)
	_check(still.controller.dismiss_current(), "UNIT dismisses the actual start hint")
	var timer: Timer = still.source.weapons[0].get_node("FireTimer") as Timer
	timer.start()
	_check(not still.controller.get_snapshot()["visible"], "A work-disabled organ with a running timer is not proof of real stopped-timer ceasefire")
	still.controller._process(0.0)
	timer.stop()
	still.controller._process(0.0)
	_check(not still.controller.get_snapshot()["visible"], "Restoring a ceased timer cannot replay a previously seen hint")


func _test_disabled_history_and_reset_preferences() -> void:
	var fixture: Fixture = _new_fixture()
	_unit_mature(fixture)
	var piercing_id: int = _unit_start(fixture, fixture.organs[0], PIERCING)
	fixture.controller.set_enabled(false)
	_check(not fixture.controller.is_enabled() and not fixture.controller.get_snapshot()["visible"]
		and fixture.controller.get_snapshot()["pending_count"] == 0, "Disabling closes the current hint and the complete queue")
	_unit_fund_and_complete(fixture, piercing_id)
	var scatter_id: int = _unit_start(fixture, fixture.organs[1], SCATTER)
	_unit_fund_and_complete(fixture, scatter_id)
	_start_batch(fixture, SWARM_SCENE, 0)
	fixture.spawner.reset()
	_start_batch(fixture, ARMORED_SCENE, 1)
	var armored: BasicEnemy = _batch_enemy(fixture)
	if armored != null:
		armored.global_position = fixture.organs[0].global_position + Vector2(30, 0)
	_unit_deplete_to(fixture.organs[0], 1)
	fixture.controller._process(0.0)
	_check(fixture.controller.get_snapshot()["seen_ids"].size() == 8
		and fixture.controller.get_snapshot()["pending_count"] == 0, "All eight real UNIT facts are remembered while hidden")
	fixture.controller.set_enabled(true)
	_check(fixture.controller.is_enabled() and not fixture.controller.get_snapshot()["visible"]
		and fixture.controller.get_snapshot()["pending_count"] == 0, "Re-enable never floods disabled history")
	_emit_duplicates(fixture)
	_check(not fixture.controller.get_snapshot()["visible"], "Duplicate muted history remains dismissed after re-enable")
	fixture.controller.set_enabled(false)
	var generation: int = fixture.controller.get_snapshot()["generation"]
	fixture.controller.stop()
	_check(not fixture.controller.is_enabled() and fixture.controller.get_snapshot()["seen_ids"].size() == 8
		and fixture.controller.get_snapshot()["generation"] > generation, "Stop preserves the preference and seen history while retiring sources")
	fixture.controller.reset()
	_check(not fixture.controller.is_enabled() and fixture.controller.get_snapshot()["seen_ids"].is_empty()
		and fixture.controller.get_snapshot()["pending_count"] == 0, "Reset clears the playthrough and preserves the disabled preference")
	_emit_duplicates(fixture)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Reset requires explicit configure before observing further source events")
	_check(_connection_count(fixture.progress, &"progress_changed", fixture.controller) == 0
		and _connection_count(fixture.spawner, &"enemy_spawned", fixture.controller) == 0,
		"Stop/reset disconnect all original source subscriptions")
	_configure(fixture)
	_check(not fixture.controller.is_enabled() and not fixture.controller.get_snapshot()["visible"],
		"Explicit reconfigure retains the reset preference")
	var fresh: Fixture = _new_fixture()
	_check(fresh.controller.is_enabled() and fresh.controller.get_snapshot()["seen_ids"].is_empty(),
		"A fresh scene instance starts enabled and unseen")
	var silent: Fixture = _new_fixture()
	silent.controller.set_enabled(false)
	silent.controller.set_process(false)
	# UNIT ONLY：构造关闭期间无信号的当前 MATURE，验证开启前的补采样。
	silent.progress._total_recovered = 160
	silent.controller.set_enabled(true)
	_check(silent.controller.get_snapshot()["seen_ids"] == [&"mature_unlocked"]
		and not silent.controller.get_snapshot()["visible"], "Re-enable records silent disabled facts before enabling presentation")
	evidence.append({"case": "disabled_history_and_scene_defaults", "scope": "UNIT actual task/batch states and explicit silent maturity state",
		"muted_seen_count": 8, "historical_replay": false, "reset_preserves_preference": true})


func _test_reentrant_dismiss() -> void:
	var fixture: Fixture = _new_fixture()
	var shown: Array[StringName] = []
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["visible"]:
			shown.append(snapshot["id"])
			if snapshot["id"] == &"mature_unlocked":
				_unit_start(fixture, fixture.organs[0], PIERCING)
				_emit_duplicates(fixture)
			fixture.controller.dismiss_current()
	)
	_unit_mature(fixture)
	_check(shown == [&"mature_unlocked", &"differentiation_started", &"differentiation_ceasefire"],
		"Synchronous source notifications and dismiss preserve queue order exactly once")
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["seen_ids"].size() == 3,
		"Reentrant dismissal commits all seen identities before notification")
	var event_count: int = fixture.events.size()
	_emit_duplicates(fixture)
	_check(fixture.events.size() == event_count, "Repeated callbacks after reentrant dismiss do not republish")


func _test_reentrant_disable() -> void:
	var fixture: Fixture = _new_fixture()
	var shown: Array[StringName] = []
	fixture.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["visible"]:
			shown.append(snapshot["id"])
			if snapshot["id"] == &"mature_unlocked":
				var task_id: int = _unit_start(fixture, fixture.organs[0], PIERCING)
				fixture.controller.set_enabled(false)
				_unit_fund_and_complete(fixture, task_id)
				_start_batch(fixture, SWARM_SCENE, 0)
	)
	_unit_mature(fixture)
	_check(shown == [&"mature_unlocked"] and not fixture.controller.is_enabled(),
		"Synchronous disable prevents old queued visible snapshots from escaping")
	_check(fixture.controller.get_snapshot()["seen_ids"].size() == 5,
		"Hidden reentrant task/ceasefire/completion/spawn occurrences remain seen")
	fixture.controller.set_enabled(true)
	_check(not fixture.controller.get_snapshot()["visible"] and fixture.controller.get_snapshot()["pending_count"] == 0,
		"Synchronous re-enable cannot replay suppressed reentrant history")
	evidence.append({"case": "synchronous_notifications", "scope": "UNIT commands inside hint listeners",
		"shown_before_disable": shown, "stale_visible_snapshots": false})


func _test_replacement_reset_and_retired_callbacks() -> void:
	var old: Fixture = _new_fixture()
	var fresh: Fixture = _new_fixture(false)
	var retired: Callable = _capture_callback(old.progress, &"progress_changed", old.controller)
	_unit_mature(old)
	var generation: int = old.controller.get_snapshot()["generation"]
	_configure(old, fresh)
	_check(old.controller.get_snapshot()["generation"] > generation
		and old.controller.get_snapshot()["seen_ids"].is_empty(), "Replacement sources retire the entire previous observation generation")
	_check(_connection_count(old.progress, &"progress_changed", old.controller) == 0
		and _connection_count(old.differentiation, &"task_changed", old.controller) == 0
		and _connection_count(old.spawner, &"enemy_spawned", old.controller) == 0
		and _connection_count(old.supply, &"transport_changed", old.controller) == 0, "Replacement disconnects all old business subscriptions")
	# UNIT ONLY：静默状态使旧回调错误进入新来源时会有可检测的正例。
	fresh.progress._total_recovered = 160
	if retired.is_valid():
		retired.call(160, 1)
	_check(old.controller.get_snapshot()["seen_ids"].is_empty(), "Captured callback cannot enter replacement sources with current positive state")
	fresh.progress.progress_changed.emit(160, 1)
	_check(old.controller.get_snapshot()["id"] == &"mature_unlocked", "Replacement's own callback observes its true current state")
	var old_reset_callback: Callable = _capture_callback(fresh.progress, &"progress_changed", old.controller)
	old.controller.reset()
	fresh.progress.reset()
	_configure(old, fresh)
	fresh.progress._total_recovered = 160
	if old_reset_callback.is_valid():
		old_reset_callback.call(160, 1)
	_check(old.controller.get_snapshot()["seen_ids"].is_empty(), "Old generation callback cannot enter the same sources after reset")
	fresh.progress.progress_changed.emit(160, 1)
	_check(old.controller.get_snapshot()["seen_ids"] == [&"mature_unlocked"], "New generation can observe the same current sources normally")
	var resetting: Fixture = _new_fixture()
	var next: Fixture = _new_fixture(false)
	var did_reset: Array[bool] = [false]
	var published: Array[Dictionary] = []
	resetting.controller.hint_changed.connect(func(snapshot: Dictionary) -> void:
		published.append(snapshot.duplicate(true))
		if snapshot["visible"] and snapshot["id"] == &"mature_unlocked" and not did_reset[0]:
			did_reset[0] = true
			_unit_start(resetting, resetting.organs[0], PIERCING)
			resetting.controller.reset()
			_configure(resetting, next)
			_unit_mature(next)
	)
	_unit_mature(resetting)
	_check(did_reset[0] and resetting.controller.get_snapshot()["seen_ids"] == [&"mature_unlocked"],
		"Reset/reconfigure inside publication isolates the fresh generation's seen queue")
	for snapshot: Dictionary in published:
		_check(not snapshot["visible"] or snapshot["id"] == &"mature_unlocked",
			"Reentrant replacement never publishes an old generation's task queue")
	evidence.append({"case": "retired_callbacks_and_replacement", "scope": "UNIT explicit silent maturity states",
		"old_source_identity_rejected": true, "old_same_source_generation_rejected": true})


func _test_stopped_sources_and_invalid_spawn_members() -> void:
	var stopped: Fixture = _new_fixture()
	var weapon: SporeWeapon = stopped.source.weapons[0]
	_unit_deplete_to(stopped.organs[0], 0)
	_unit_enemy(stopped, stopped.organs[0].global_position + Vector2(30, 0))
	stopped.supply.reset(true)
	_check(stopped.supply.is_stopped() and weapon.is_firing_enabled(), "UNIT stops supply while retaining a live weapon and enemy")
	stopped.controller._process(0.0)
	_check(not stopped.controller.get_snapshot()["seen_ids"].has(&"ammunition_wait"), "A stopped supply source cannot create an ammo hint")
	var differentiation: Fixture = _new_fixture(false)
	_unit_mature(differentiation)
	var task_id: int = _unit_start(differentiation, differentiation.organs[0], PIERCING)
	_unit_fund_and_complete(differentiation, task_id)
	differentiation.differentiation.stop()
	_configure(differentiation)
	_check(_drain(differentiation) == [&"mature_unlocked"], "A stopped differentiation source cannot present its historic completion as a new hint")
	var invalid: Fixture = _new_fixture(false)
	invalid.spawner.enemy_spawned.connect(func(_enemy: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
		invalid.spawner.stop_spawning(&"unit:synchronous_stop")
	)
	_configure(invalid)
	var old_spawn: Callable = _capture_callback(invalid.spawner, &"enemy_spawned", invalid.controller)
	_start_batch(invalid, ARMORED_SCENE, 1)
	var enemy: BasicEnemy = _batch_enemy(invalid)
	_check(invalid.spawner.get_batch_snapshot()["state"] == "stopped"
		and not invalid.controller.get_snapshot()["seen_ids"].has(&"armored_encounter"),
		"Source stop before the hint callback invalidates a real synchronous enemy_spawned event")
	if enemy != null and old_spawn.is_valid():
		old_spawn.call(enemy, String(enemy.get_meta(&"spawn_id")), String(enemy.get_meta(&"batch_id")))
	_check(not invalid.controller.get_snapshot()["visible"], "Saved spawn callback cannot revive a stopped batch")
	var removed: Fixture = _new_fixture(false)
	removed.spawner.enemy_spawned.connect(func(member: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
		member.queue_free()
	)
	_configure(removed)
	_start_batch(removed, SWARM_SCENE)
	_check(not removed.controller.get_snapshot()["seen_ids"].has(&"swarm_encounter"),
		"Queued deletion before the observer callback cannot prove a live encounter")
	var dead: Fixture = _new_fixture(false)
	dead.spawner.enemy_spawned.connect(func(member: BasicEnemy, _spawn_id: String, _batch_id: String) -> void:
		# UNIT 活体负例；不把直接改 health 当作真实击杀证据。
		member.health = 0
	)
	_configure(dead)
	_start_batch(dead, ARMORED_SCENE, 1)
	_check(not dead.controller.get_snapshot()["seen_ids"].has(&"armored_encounter"),
		"Dead member before the observer callback cannot prove a live armored encounter")


func _test_queued_and_freed_sources() -> void:
	var fixture: Fixture = _new_fixture()
	var retired: Callable = _capture_callback(fixture.progress, &"progress_changed", fixture.controller)
	fixture.progress.queue_free()
	fixture.progress.record_arrival("unit:hint:queued", 160)
	if retired.is_valid():
		retired.call(160, 1)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Queued progress deletion rejects positive events and captured callbacks")
	await process_frame
	_check(not is_instance_valid(fixture.progress), "Queued progress source actually frees")
	if retired.is_valid():
		retired.call(160, 1)
	fixture.controller._process(0.0)
	_check(fixture.controller.get_snapshot()["seen_ids"].is_empty(), "Weak source references reject callbacks after actual free")
	var source: Fixture = _new_fixture()
	_unit_mature(source)
	_drain(source)
	var task_id: int = _unit_start(source, source.organs[0], PIERCING)
	_drain(source)
	source.source.queue_free()
	_unit_fund_and_complete(source, task_id)
	_check(not source.controller.get_snapshot()["seen_ids"].has(&"piercing_completed"),
		"A queued weapon-list source cannot generate a new completion hint")
	var detached: Fixture = _new_fixture()
	var callback: Callable = _capture_callback(detached.progress, &"progress_changed", detached.controller)
	detached.world.remove_child(detached.controller)
	_check(_connection_count(detached.progress, &"progress_changed", detached.controller) == 0,
		"Controller tree exit disconnects observations")
	detached.world.add_child(detached.controller)
	detached.progress._total_recovered = 160
	if callback.is_valid():
		callback.call(160, 1)
	_check(detached.controller.get_snapshot()["seen_ids"].is_empty(), "Controller reentry requires explicit configure and cannot revive old bindings")
	_configure(detached)
	_check(_drain(detached) == [&"mature_unlocked"], "Explicit configure restores valid observation after reentry")
	evidence.append({"case": "queued_freed_and_detached", "scope": "UNIT positive source states and actual queue_free boundary",
		"queued_sources_ignored": true, "freed_callbacks_ignored": true, "explicit_reconfigure_required": true})


func _free_fixtures() -> void:
	for reference: WeakRef in _worlds:
		var world: Node2D = reference.get_ref() as Node2D
		if is_instance_valid(world):
			world.free()
	_worlds.clear()
