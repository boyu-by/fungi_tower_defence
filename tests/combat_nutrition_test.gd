extends SceneTree
## 真实付款/运输/命中验收；射击消耗只累计 volley_committed 的 nutrition_spent。
## 切换配置均为显式测试接线，不代表玩家的免费或付费分化。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const PRESET_PATHS: Dictionary = {
	"normal": "res://resources/weapons/normal_spore.tres",
	"armor_piercing": "res://resources/weapons/armor_piercing_spore.tres",
	"scatter": "res://resources/weapons/scatter_spore.tres",
}

class Fixture:
	extends RefCounted
	var world: Node2D
	var nodes: Node2D
	var edges_container: Node2D
	var core: MotherCore
	var hub: HyphaNode
	var hosts: Array[HyphaNode] = []
	var edges: Array[HyphaEdge] = []
	var organs: Array[AttackOrgan] = []
	var weapons: Array[SporeWeapon] = []
	var enemies: Node2D
	var projectiles: Node2D
	var battle_packets: Node2D
	var growth_packets: Node2D
	var cultivation_packets: Node2D
	var repair_packets: Node2D
	var network: NetworkSystem
	var battle: SupplySystem
	var growth: GrowthSystem
	var growth_supply: GrowthSupplySystem
	var cultivation: CultivationSystem
	var cultivation_supply: CultivationSupplySystem
	var cultivation_host: HyphaNode
	var cultivation_task_id: int = 0
	var traffic: NetworkTrafficSystem
	var repair: RepairSystem
	var repair_supply: RepairSupplySystem
	var initial_total: int = 0
	var income: int = 0
	var nutrition_spent: int = 0
	var projectile_count: int = 0
	var events: Array[Dictionary] = []
	var legacy_rounds: int = 0

var failures: Array[String] = []
var checks: int = 0
var cases: Array[String] = []
var _seen_shot_ids: Dictionary[String, bool] = {}
var _all_spent: int = 0
var _all_projectiles: int = 0
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_two_round_reserve_by_mode()
	await _test_mixed_cost_and_owner_lookup()
	await _test_real_paid_incoming_and_work_pause()
	await _test_inactive_supply_and_rotation()
	await _test_core_connectivity_and_processing()
	await _test_construction_transit_is_not_subtracted_twice()
	await _test_real_combat_supply_and_event_conservation()
	await _test_paid_miss_conservation()
	await _test_real_repair_budget_priority()
	_check(root.get_child_count() == _initial_root_children, "All combat nutrition fixtures leave the tree")
	print("COMBAT_NUTRITION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases,
		"committed_rounds": _seen_shot_ids.size(), "nutrition_spent": _all_spent,
		"projectiles": _all_projectiles, "accounting": "actual_volley_committed_cost",
		"transport": "real_paid_nutrient_packets", "configuration": "explicit_test_setup",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _preset(mode: String) -> WeaponProfile:
	var source: WeaponProfile = load(PRESET_PATHS[mode]) as WeaponProfile
	_check(source != null and source.is_valid(), mode + " preset validates")
	return source.copy_for_instance() if source != null else WeaponProfile.new()


func _container(parent: Node, node_name: String) -> Node2D:
	var container := Node2D.new()
	container.name = node_name
	parent.add_child(container)
	return container


func _node(fixture: Fixture, point: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	node.position = point
	fixture.nodes.add_child(node)
	_check(fixture.network.register_node(node), "Real nutrition network node registers")
	return node


func _edge(fixture: Fixture, first: Node2D, second: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	fixture.edges_container.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Real nutrition network edge registers")
	fixture.edges.append(edge)
	return edge


func _new_fixture(modes: Array[String], balance: int = 32, stocks: Array[int] = []) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = _container(root, "CombatNutritionFixture")
	current_scene = fixture.world
	fixture.nodes = _container(fixture.world, "Nodes")
	fixture.edges_container = _container(fixture.world, "Edges")
	fixture.enemies = _container(fixture.world, "Enemies")
	fixture.projectiles = _container(fixture.world, "Projectiles")
	fixture.battle_packets = _container(fixture.world, "BattlePackets")
	fixture.growth_packets = _container(fixture.world, "GrowthPackets")
	fixture.cultivation_packets = _container(fixture.world, "CultivationPackets")
	fixture.repair_packets = _container(fixture.world, "RepairPackets")
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = balance
	fixture.nodes.add_child(fixture.core)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Nutrition source registers as the core")
	fixture.hub = _node(fixture, Vector2(80, 0))
	_edge(fixture, fixture.core, fixture.hub)
	fixture.battle = SupplySystem.new()
	fixture.battle.mother_core = fixture.core
	fixture.battle.network_system = fixture.network
	fixture.battle.packet_container = fixture.battle_packets
	fixture.battle.packet_scene = PACKET_SCENE
	fixture.world.add_child(fixture.battle)
	fixture.initial_total = balance
	for index: int in range(modes.size()):
		var host: HyphaNode = _node(fixture, Vector2(160, index * 70))
		# 反向记录第二段，使真实到达需要跨越双向多段网络。
		_edge(fixture, host, fixture.hub)
		fixture.hosts.append(host)
		var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
		organ.initial_nutrition = stocks[index] if index < stocks.size() else 0
		host.add_child(organ)
		fixture.organs.append(organ)
		fixture.initial_total += organ.nutrition
		var weapon: SporeWeapon = WEAPON_SCENE.instantiate() as SporeWeapon
		weapon.name = "ConfiguredWeapon_%d" % index
		weapon.position = Vector2(0, -28)
		weapon.inventory_owner = organ
		weapon.enemy_container = fixture.enemies
		weapon.projectile_container = fixture.projectiles
		(weapon.get_node("FireTimer") as Timer).autostart = false
		_check(weapon.configure_profile(_preset(modes[index])), "Explicit nutrition fixture configuration succeeds")
		host.add_child(weapon)
		(weapon.get_node("FireTimer") as Timer).stop()
		fixture.weapons.append(weapon)
		weapon.volley_committed.connect(_capture_volley.bind(weapon, fixture))
		weapon.shot_fired.connect(_capture_legacy.bind(fixture))
		_check(fixture.battle.register_organ(organ), "Configured combat organ registers")
	fixture.growth = GrowthSystem.new()
	fixture.growth.planner = GrowthPlanner.new()
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = fixture.nodes
	fixture.growth.edge_container = fixture.edges_container
	fixture.growth.tip_container = _container(fixture.world, "GrowthTips")
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_process(false)
	fixture.growth.set_physics_process(false)
	fixture.growth_supply = GrowthSupplySystem.new()
	fixture.growth_supply.growth_system = fixture.growth
	fixture.growth_supply.mother_core = fixture.core
	fixture.growth_supply.network_system = fixture.network
	fixture.growth_supply.combat_supply_system = fixture.battle
	fixture.growth_supply.packet_container = fixture.growth_packets
	fixture.growth_supply.auto_supply = false
	fixture.world.add_child(fixture.growth_supply)
	fixture.growth_supply.set_process(false)
	fixture.cultivation_host = _node(fixture, Vector2(240, 210))
	_edge(fixture, fixture.hub, fixture.cultivation_host)
	fixture.cultivation = CultivationSystem.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.enemy_container = fixture.enemies
	fixture.cultivation.projectile_container = fixture.projectiles
	fixture.world.add_child(fixture.cultivation)
	fixture.cultivation.set_process(false)
	fixture.cultivation.set_physics_process(false)
	fixture.cultivation_supply = CultivationSupplySystem.new()
	fixture.cultivation_supply.cultivation_system = fixture.cultivation
	fixture.cultivation_supply.mother_core = fixture.core
	fixture.cultivation_supply.network_system = fixture.network
	fixture.cultivation_supply.combat_supply_system = fixture.battle
	fixture.cultivation_supply.packet_container = fixture.cultivation_packets
	fixture.cultivation_supply.auto_supply = false
	fixture.world.add_child(fixture.cultivation_supply)
	fixture.cultivation_supply.set_process(false)
	return fixture


func _capture_volley(shot_id: String, nutrition_spent: int, projectile_count: int,
		weapon: SporeWeapon, fixture: Fixture) -> void:
	_check(not shot_id.is_empty() and not _seen_shot_ids.has(shot_id),
		"Resource accounting accepts a globally unique round identifier")
	_seen_shot_ids[shot_id] = true
	fixture.nutrition_spent += nutrition_spent
	fixture.projectile_count += projectile_count
	_all_spent += nutrition_spent
	_all_projectiles += projectile_count
	fixture.events.append({"shot_id": shot_id, "nutrition_spent": nutrition_spent,
		"projectile_count": projectile_count, "weapon_id": weapon.get_instance_id()})
	_check(nutrition_spent > 0 and projectile_count > 0, "Resource event contains actual positive paid quantities")
	var stats: Dictionary = weapon.get_shot_statistics()
	_check(String(stats.get("last_shot_id", "")) == shot_id
		and int(stats.get("nutrition_spent", 0)) >= nutrition_spent,
		"Committed cost and identifier are observable before resource event callbacks")
	_conservation(fixture, "Inside authoritative commit callback")


func _capture_legacy(_enemy: BasicEnemy, fixture: Fixture) -> void:
	fixture.legacy_rounds += 1
	_check(fixture.legacy_rounds == fixture.events.size(), "Legacy compatibility signal follows one actual paid round")


func _reserve(fixture: Fixture, expected: int, context: String) -> void:
	_check(fixture.growth_supply.get_combat_reserve() == expected,
		context + " growth reserve sums actual two-round costs")
	_check(fixture.cultivation_supply.get_combat_reserve() == expected,
		context + " cultivation reserve matches growth")
	var available: int = maxi(0, fixture.core.get_spendable_nutrition() - expected)
	_check(fixture.growth_supply.get_available_growth_nutrition() == available
		and fixture.cultivation_supply.get_available_cultivation_nutrition() == available,
		context + " uses spendable core balance once")


func _conservation(fixture: Fixture, context: String) -> void:
	var total: int = fixture.core.nutrition + fixture.nutrition_spent
	# 战斗包由真实已扣款账本计数；一包始终为一单位，与射击成本无关。
	total += fixture.battle.get_in_transit_count() * SupplySystem.PACKET_NUTRITION
	total += fixture.growth_supply.get_in_transit_count() * GrowthSupplySystem.PACKET_NUTRITION
	total += fixture.cultivation_supply.get_in_transit_count() * CultivationSupplySystem.PACKET_NUTRITION
	for organ: AttackOrgan in fixture.organs:
		_check(organ.nutrition >= 0 and organ.incoming_nutrition >= 0
			and organ.nutrition + organ.incoming_nutrition <= organ.capacity,
			context + " keeps every real inventory within capacity")
		total += organ.nutrition
	var growth_snapshot: Dictionary = fixture.growth.get_task_snapshot()
	total += int(growth_snapshot.get("buffered_nutrition", 0)) + int(growth_snapshot.get("consumed_nutrition", 0))
	if fixture.cultivation_task_id > 0:
		var cultivation_snapshot: Dictionary = fixture.cultivation.get_task_snapshot(fixture.cultivation_task_id)
		# 已移交启动库存若有成熟会计入器官；结构投资才是永久消耗。
		total += int(cultivation_snapshot.get("buffered_nutrition", 0)) \
			+ int(cultivation_snapshot.get("structure_consumed", 0))
	if fixture.repair_supply != null:
		var repair_snapshot: Dictionary = fixture.repair.get_task_snapshot()
		total += fixture.repair_supply.get_in_transit_nutrition() \
			+ int(repair_snapshot.get("buffered_nutrition", 0)) \
			+ int(repair_snapshot.get("consumed_nutrition", 0))
	_check(total == fixture.initial_total + fixture.income,
		context + " conserves balance, paid transit, stock, buffers and actual committed event costs")


func _freeze_packets(container: Node2D) -> void:
	for child: Node in container.get_children():
		if child is NutrientPacket:
			child.set_physics_process(false)


func _dispatch_battle(fixture: Fixture, index: int) -> bool:
	var accepted: bool = fixture.battle.request_supply(fixture.organs[index])
	_freeze_packets(fixture.battle_packets)
	return accepted


func _deliver(container: Node2D) -> void:
	for child: Node in container.get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			var packet: NutrientPacket = child as NutrientPacket
			packet._physics_process(1000.0)
			_check(bool(packet.get_transport_snapshot().get("terminal", false))
				and packet.get_transport_snapshot().get("state") == &"completed",
				"Real paid packet reaches its captured destination through production transport")
	await process_frame
	await process_frame
	_check(container.get_child_count() == 0, "Delivered real packets cleanly leave their container")


func _enemy(fixture: Fixture, organ_index: int, offset: Vector2, armor_value: int = 4) -> BasicEnemy:
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = 200
	enemy.armor = armor_value
	enemy.move_speed = 0.0
	fixture.enemies.add_child(enemy)
	enemy.global_position = fixture.organs[organ_index].global_position + offset
	enemy.set_physics_process(false)
	return enemy


func _fire(fixture: Fixture, index: int) -> void:
	(fixture.weapons[index].get_node("FireTimer") as Timer).stop()
	fixture.weapons[index]._on_fire_timer_timeout()
	for child: Node in fixture.projectiles.get_children():
		if child is SporeProjectile:
			child.set_physics_process(false)
			(child.get_node("LifetimeTimer") as Timer).stop()


func _hit_all(fixture: Fixture) -> void:
	for child: Node in fixture.projectiles.get_children():
		if child is SporeProjectile and not child.is_queued_for_deletion():
			(child as SporeProjectile)._physics_process(10.0)
			(child as SporeProjectile)._physics_process(10.0)
	await process_frame
	await process_frame
	_check(fixture.projectiles.get_child_count() == 0, "Real combat projectiles settle once and are freed")
	_conservation(fixture, "After real projectile settlement")


func _stop_clocks(fixture: Fixture) -> void:
	for weapon: SporeWeapon in fixture.weapons:
		(weapon.get_node("FireTimer") as Timer).stop()


func _dispose(fixture: Fixture) -> void:
	fixture.growth_supply.reset()
	fixture.cultivation_supply.reset()
	if fixture.repair_supply != null:
		fixture.repair_supply.reset()
	if current_scene == fixture.world:
		current_scene = null
	fixture.world.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.world), "Nutrition fixture and all packets are fully freed")


func _test_two_round_reserve_by_mode() -> void:
	for mode: String in PRESET_PATHS:
		var cost: int = _preset(mode).nutrition_cost
		for stock: int in range(7):
			var fixture: Fixture = _new_fixture([mode], 12, [stock])
			_check(fixture.organs[0].get_shot_nutrition_cost() == cost
				and SporeWeapon.get_organ_nutrition_cost(fixture.organs[0]) == cost,
				mode + " organ and legacy static lookup expose their matching weapon's actual cost")
			_check(fixture.organs[0].is_work_enabled() and fixture.organs[0].is_combat_active()
				and fixture.battle.get_active_organs().size() == 1,
				mode + " empty or full stock remains an active organ")
			_reserve(fixture, maxi(0, 2 * cost - stock), mode + " stock " + str(stock))
			_check(fixture.organs[0].capacity == 6 and fixture.organs[0].refill_target == 3,
				mode + " configuration preserves the capacity and three-unit refill target")
			_conservation(fixture, mode + " pure reserve query")
			await _dispose(fixture)
	cases.append("normal_scatter_two_ap_four_reserve_and_zero_floor_for_all_local_stocks")


func _test_mixed_cost_and_owner_lookup() -> void:
	var fixture: Fixture = _new_fixture(["normal", "armor_piercing", "scatter"], 24, [1, 1, 0])
	_reserve(fixture, 6, "Mixed one/one/zero stock")
	var queried: WeaponProfile = fixture.weapons[1].get_weapon_profile()
	queried.nutrition_cost = 6
	_reserve(fixture, 6, "Independent query mutation")
	_check(fixture.weapons[1].configure_profile(_preset("normal")), "Explicit test changes AP cost to normal")
	_reserve(fixture, 4, "Mixed explicit reconfiguration")
	_check(fixture.organs[0].nutrition == 1 and fixture.organs[1].nutrition == 1
		and fixture.organs[2].nutrition == 0 and fixture.events.is_empty(),
		"Mixed configuration and reserve queries create no stock or shooting events")
	var unarmed: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
	unarmed.initial_nutrition = 0
	fixture.cultivation_host.add_child(unarmed)
	fixture.organs.append(unarmed)
	_check(fixture.battle.register_organ(unarmed) and unarmed.get_shot_nutrition_cost() == 1
		and SporeWeapon.get_organ_nutrition_cost(unarmed) == 1 and unarmed.is_combat_active(),
		"Unarmed old fixture preserves its active one-unit fallback")
	_reserve(fixture, 6, "Mixed modes plus unarmed compatibility fixture")
	_conservation(fixture, "Mixed cost and fallback queries")
	await _dispose(fixture)
	cases.append("mixed_sibling_owner_cost_independent_copy_and_legacy_unarmed_fallback")


func _test_real_paid_incoming_and_work_pause() -> void:
	var fixture: Fixture = _new_fixture(["armor_piercing", "normal", "scatter"], 24)
	_reserve(fixture, 8, "Three empty modes")
	_check(_dispatch_battle(fixture, 0) and _dispatch_battle(fixture, 0)
		and _dispatch_battle(fixture, 1) and _dispatch_battle(fixture, 2),
		"Four real combat packets pay their original one-unit costs")
	_check(fixture.core.nutrition == 20 and fixture.battle.get_in_transit_count() == 4
		and fixture.organs[0].incoming_nutrition == 2
		and fixture.organs[1].incoming_nutrition == 1 and fixture.organs[2].incoming_nutrition == 1,
		"Paid transit is backed by core debits and receiver reservations")
	var route: NetworkRoute = fixture.network.find_route(fixture.core, fixture.hosts[0])
	_check(route.found and route.segments.size() == 2 and not route.segments[1].forward,
		"Incoming fixture is a real multi-hop reversed-segment route")
	_reserve(fixture, 4, "Already paid mixed incoming")
	_conservation(fixture, "Paid incoming is counted once")
	fixture.organs[0].set_work_enabled(false)
	_check(fixture.battle.get_registered_organs().size() == 3
		and fixture.battle.get_active_organs().size() == 2
		and fixture.organs[0].incoming_nutrition == 2 and fixture.organs[0].nutrition == 0,
		"Work pause preserves registration, stock and existing paid transit")
	_reserve(fixture, 2, "Paused AP is excluded from new combat reserve")
	_check(not _dispatch_battle(fixture, 0), "New manual supply skips a work-paused organ")
	await _deliver(fixture.battle_packets)
	_check(fixture.organs[0].nutrition == 2 and fixture.organs[0].incoming_nutrition == 0
		and fixture.battle.delivered_packets == 4 and fixture.battle.interrupted_packets == 0,
		"Legitimate paid incoming still delivers to a paused organ exactly once")
	_reserve(fixture, 2, "Delivered paused AP")
	fixture.organs[0].set_work_enabled(true)
	_stop_clocks(fixture)
	_reserve(fixture, 4, "Resumed AP's two-round deficit")
	_check(fixture.core.nutrition == 20 and fixture.organs[0].nutrition == 2,
		"Resume changes activity without creating or refunding resources")
	_conservation(fixture, "Pause and resume actual paid deliveries")
	await _dispose(fixture)
	cases.append("paid_incoming_no_double_count_work_pause_registered_delivery_and_resume")


func _test_inactive_supply_and_rotation() -> void:
	var fixture: Fixture = _new_fixture(["normal", "armor_piercing", "scatter"], 16)
	fixture.organs[0].set_work_enabled(false)
	fixture.weapons[1].set_firing_enabled(false)
	_check(fixture.battle.get_registered_organs().size() == 3
		and fixture.battle.get_active_organs() == [fixture.organs[2]],
		"Registration includes paused organs while activity follows work and weapon enable")
	_check(not _dispatch_battle(fixture, 0) and not _dispatch_battle(fixture, 1),
		"Manual supply skips paused and independently disabled weapons")
	_reserve(fixture, 2, "Only scatter is currently active")
	for tick: int in range(3):
		fixture.battle._on_dispatch_timer_timeout()
		_freeze_packets(fixture.battle_packets)
		_check(fixture.organs[2].incoming_nutrition == tick + 1
			and fixture.organs[0].incoming_nutrition == 0 and fixture.organs[1].incoming_nutrition == 0,
			"Automatic supply skips inactive organs and dispatches one one-unit packet")
	fixture.battle._on_dispatch_timer_timeout()
	_check(fixture.battle.get_in_transit_count() == 3 and fixture.core.nutrition == 13,
		"Automatic supply stops at unchanged refill target three")
	fixture.organs[0].set_work_enabled(true)
	fixture.weapons[1].set_firing_enabled(true)
	_stop_clocks(fixture)
	for tick: int in range(6):
		fixture.battle._on_dispatch_timer_timeout()
		_freeze_packets(fixture.battle_packets)
		_check(fixture.organs[0].incoming_nutrition == ceili(float(tick + 1) / 2.0)
			and fixture.organs[1].incoming_nutrition == floori(float(tick + 1) / 2.0),
			"Resumed eligible organs retain round-robin rotation")
	_check(fixture.battle.get_in_transit_count() == 9 and fixture.core.nutrition == 7,
		"AP supply still uses one-unit transport and refill target three")
	_reserve(fixture, 1, "AP has only three paid units toward its four-unit two-round reserve")
	_conservation(fixture, "Round-robin paid refill")
	await _deliver(fixture.battle_packets)
	_check(fixture.organs[0].nutrition == 3 and fixture.organs[1].nutrition == 3
		and fixture.organs[2].nutrition == 3, "All resumed real refills settle without changing capacities")
	_reserve(fixture, 1, "Delivered round-robin refill")
	_conservation(fixture, "Delivered round-robin refill")
	await _dispose(fixture)
	cases.append("inactive_manual_auto_supply_one_unit_packets_refill_three_and_fair_rotation")


func _test_core_connectivity_and_processing() -> void:
	var fixture: Fixture = _new_fixture(["armor_piercing"], 8)
	_reserve(fixture, 4, "Connected live AP")
	fixture.weapons[0].process_mode = Node.PROCESS_MODE_DISABLED
	_check(fixture.battle.get_active_organs().is_empty() and not _dispatch_battle(fixture, 0),
		"Unprocessable matching weapon is excluded from queries and new manual supply")
	_reserve(fixture, 0, "Unprocessable weapon")
	fixture.weapons[0].process_mode = Node.PROCESS_MODE_INHERIT
	fixture.organs[0].process_mode = Node.PROCESS_MODE_DISABLED
	_check(fixture.battle.get_active_organs().is_empty() and not _dispatch_battle(fixture, 0),
		"Unprocessable inventory owner is excluded from new supply")
	_reserve(fixture, 0, "Unprocessable owner")
	fixture.organs[0].process_mode = Node.PROCESS_MODE_INHERIT
	fixture.network.unregister_edge(fixture.edges[0])
	_check(fixture.battle.get_active_organs().is_empty() and not _dispatch_battle(fixture, 0),
		"Disconnected organs remain registered but cannot receive new supply")
	_reserve(fixture, 0, "Disconnected weapon")
	_check(fixture.network.register_edge(fixture.edges[0]), "Connectivity restores through the same real edge")
	_reserve(fixture, 4, "Restored AP connection")
	fixture.core.take_damage(fixture.core.health)
	_check(fixture.battle.get_active_organs().is_empty() and not _dispatch_battle(fixture, 0)
		and fixture.growth_supply.get_combat_reserve() == 0
		and fixture.cultivation_supply.get_combat_reserve() == 0
		and fixture.growth_supply.get_available_growth_nutrition() == 0
		and fixture.cultivation_supply.get_available_cultivation_nutrition() == 0,
		"Dead core yields neither active supply nor spendable construction nutrition")
	_check(fixture.battle.get_registered_organs().size() == 1,
		"Core death and connectivity queries preserve registration")
	_conservation(fixture, "Inactive source and network queries")
	await _dispose(fixture)
	cases.append("activity_requires_live_core_connectivity_and_processable_owner_weapon")


func _start_construction(fixture: Fixture, kind: String) -> void:
	if kind == "growth":
		var task_id: int = fixture.growth.create_target(fixture.hosts[0],
			fixture.hosts[0].global_position + Vector2(180, 0))
		_check(task_id > 0, "Real growth task is admitted")
	else:
		fixture.cultivation_task_id = fixture.cultivation.start_cultivation(fixture.cultivation_host)
		_check(fixture.cultivation_task_id > 0, "Real cultivation task is admitted on an empty connected host")


func _test_construction_transit_is_not_subtracted_twice() -> void:
	for kind: String in ["growth", "cultivation"]:
		var fixture: Fixture = _new_fixture(["armor_piercing"], 6)
		_start_construction(fixture, kind)
		var supply: Node = fixture.growth_supply if kind == "growth" else fixture.cultivation_supply
		var packets: Node2D = fixture.growth_packets if kind == "growth" else fixture.cultivation_packets
		_reserve(fixture, 4, kind + " before dispatch")
		_check(bool(supply.call("try_dispatch")), kind + " dispatches one actual paid construction packet")
		_freeze_packets(packets)
		_check(fixture.core.nutrition == 5 and int(supply.call("get_in_transit_count")) == 1,
			kind + " construction packet debits exactly one real unit")
		_reserve(fixture, 4, kind + " paid construction transit leaves one unit available")
		_check(_dispatch_battle(fixture, 0) and _dispatch_battle(fixture, 0),
			kind + " reserved AP supply dispatches two actual battle packets")
		_check(fixture.core.nutrition == 3 and fixture.organs[0].incoming_nutrition == 2,
			kind + " battle incoming is backed by its own paid units")
		_reserve(fixture, 2, kind + " both paid transit classes are subtracted only in the core debit")
		_conservation(fixture, kind + " mixed paid transit")
		await _deliver(packets)
		var snapshot: Dictionary = fixture.growth.get_task_snapshot() if kind == "growth" \
			else fixture.cultivation.get_task_snapshot(fixture.cultivation_task_id)
		_check(int(snapshot.get("buffered_nutrition", 0)) == 1,
			kind + " real arrival becomes one actual refundable construction buffer")
		_reserve(fixture, 2, kind + " delivered construction buffer")
		_conservation(fixture, kind + " construction arrival")
		if kind == "growth":
			fixture.growth.cancel_task()
		else:
			fixture.cultivation.cancel_task()
		_check(fixture.core.nutrition == 4 and fixture.organs[0].incoming_nutrition == 2
			and fixture.battle.get_in_transit_count() == 2,
			kind + " cancellation refunds only its own real construction buffer")
		_reserve(fixture, 2, kind + " cancelled construction")
		await _deliver(fixture.battle_packets)
		_check(fixture.organs[0].nutrition == 2 and fixture.organs[0].incoming_nutrition == 0,
			kind + " independent combat ownership survives construction cancellation")
		_enemy(fixture, 0, Vector2(60, 0))
		_fire(fixture, 0)
		_check(fixture.events.size() == 1 and fixture.nutrition_spent == 2
			and fixture.organs[0].nutrition == 0, kind + " paid AP stock funds one real two-unit round")
		await _hit_all(fixture)
		_reserve(fixture, 4, kind + " actual AP shot recreates its two-round deficit")
		await _dispose(fixture)
	cases.append("growth_cultivation_real_paid_transit_arrival_cancel_and_no_double_subtraction")


func _test_real_combat_supply_and_event_conservation() -> void:
	var fixture: Fixture = _new_fixture(["normal", "armor_piercing", "scatter"], 30, [3, 3, 3])
	var normal_target: BasicEnemy = _enemy(fixture, 0, Vector2(60, 0))
	var ap_target: BasicEnemy = _enemy(fixture, 1, Vector2(60, 0))
	var scatter_target: BasicEnemy = _enemy(fixture, 2, Vector2(60, 0))
	var scatter_second: BasicEnemy = _enemy(fixture, 2, Vector2(95, 0))
	var scatter_third: BasicEnemy = _enemy(fixture, 2, Vector2(120, 12))
	for index: int in range(3):
		_fire(fixture, index)
	_check(fixture.events.size() == 3 and fixture.legacy_rounds == 3
		and fixture.nutrition_spent == 4 and fixture.projectile_count == 5,
		"Three real mixed rounds account for four actual paid units and five projectiles")
	_check(normal_target.health == 200 and ap_target.health == 200 and scatter_target.health == 200,
		"Mixed committed rounds do not apply damage before arrival")
	_conservation(fixture, "Mixed real launches")
	_reserve(fixture, 3, "Mixed local stocks two/one/two after firing")
	for _tick: int in range(4):
		fixture.battle._on_dispatch_timer_timeout()
		_freeze_packets(fixture.battle_packets)
	_check(fixture.core.nutrition == 26 and fixture.battle.get_in_transit_count() == 4,
		"Normal/AP/scatter refill through four real one-unit payments")
	_conservation(fixture, "Mixed combat and paid refill transit")
	fixture.organs[1].set_work_enabled(false)
	await _deliver(fixture.battle_packets)
	fixture.organs[1].set_work_enabled(true)
	_stop_clocks(fixture)
	_check(fixture.organs[0].nutrition == 3 and fixture.organs[1].nutrition == 3
		and fixture.organs[2].nutrition == 3, "Paid supply reaches all original inventories including work-paused AP")
	_check(fixture.weapons[0].configure_profile(_preset("armor_piercing"))
		and fixture.weapons[1].configure_profile(_preset("normal"))
		and fixture.weapons[2].configure_profile(_preset("normal")),
		"Explicit next-round test configuration succeeds with old shots still alive")
	_check(fixture.organs[0].nutrition == 3 and fixture.organs[1].nutrition == 3
		and fixture.organs[2].nutrition == 3, "Configuration adds no stock after real refill")
	await _hit_all(fixture)
	_check(normal_target.health == 192 and ap_target.health == 176 and scatter_target.health == 198
		and scatter_second.health == 198 and scatter_third.health == 198,
		"Old mixed projectiles retain original normal/AP/scatter armor snapshots")
	for index: int in range(3):
		_fire(fixture, index)
	_check(fixture.events.size() == 6 and fixture.nutrition_spent == 8
		and fixture.projectile_count == 8 and fixture.legacy_rounds == 6,
		"Changing modes preserves counters and records each following round's real cost")
	await _hit_all(fixture)
	_check(normal_target.health == 168 and ap_target.health == 168 and scatter_target.health == 190
		and scatter_second.health == 198 and scatter_third.health == 198,
		"Following actual impacts use only the newly copied configurations")
	_conservation(fixture, "Full mixed shooting/refill/configuration cycle")
	await _dispose(fixture)
	cases.append("actual_event_cost_conserves_three_modes_real_refill_and_immutable_old_shots")


func _test_paid_miss_conservation() -> void:
	for outcome: String in ["dead_target", "expired"]:
		var fixture: Fixture = _new_fixture(["armor_piercing"], 6, [2])
		var enemy: BasicEnemy = _enemy(fixture, 0, Vector2(90, 0))
		_fire(fixture, 0)
		_check(fixture.nutrition_spent == 2 and fixture.organs[0].nutrition == 0,
			"Miss fixture commits a real two-unit AP payment")
		for child: Node in fixture.projectiles.get_children():
			if child is SporeProjectile:
				if outcome == "dead_target":
					enemy.take_damage(999)
					(child as SporeProjectile)._physics_process(10.0)
				else:
					(child.get_node("LifetimeTimer") as Timer).timeout.emit()
					(child as SporeProjectile)._physics_process(10.0)
		await process_frame
		await process_frame
		_check(fixture.projectiles.get_child_count() == 0 and fixture.events.size() == 1
			and fixture.nutrition_spent == 2 and fixture.organs[0].nutrition == 0
			and fixture.core.nutrition == 6, outcome + " dissipates without refunds or extra debit events")
		_conservation(fixture, outcome + " keeps consumed event cost in the resource ledger")
		await _dispose(fixture)
	cases.append("paid_target_loss_and_expiration_conserve_actual_two_unit_ap_cost")


func _install_repair(fixture: Fixture) -> void:
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.repair = RepairSystem.new()
	fixture.repair.network_system = fixture.network
	fixture.world.add_child(fixture.repair)
	fixture.repair.set_process(false)
	fixture.repair.set_physics_process(false)
	fixture.repair_supply = RepairSupplySystem.new()
	fixture.repair_supply.repair_system = fixture.repair
	fixture.repair_supply.mother_core = fixture.core
	fixture.repair_supply.network_system = fixture.network
	fixture.repair_supply.traffic_system = fixture.traffic
	fixture.repair_supply.traffic_required = true
	fixture.repair_supply.packet_container = fixture.repair_packets
	fixture.repair_supply.auto_supply = false
	fixture.world.add_child(fixture.repair_supply)
	fixture.repair_supply.set_process(false)


func _deliver_repair(fixture: Fixture) -> void:
	for record: Dictionary in fixture.repair_supply.get_shipment_records():
		var packet: NutrientPacket = record.get("packet") as NutrientPacket
		if not bool(record.get("settled", false)) and is_instance_valid(packet):
			var completed: bool = false
			for _step: int in range(400):
				var snapshot: Dictionary = packet.get_transport_snapshot()
				if bool(snapshot.get("terminal", false)):
					completed = snapshot.get("state") == &"completed"
					break
				fixture.traffic.refresh()
				fixture.repair_supply.refresh_budget()
				packet._physics_process(0.1)
			_check(completed, "Funded repair packet really arrives using shared traffic")
	await process_frame
	await process_frame
	fixture.repair_supply.refresh_budget()


func _test_real_repair_budget_priority() -> void:
	var fixture: Fixture = _new_fixture(["normal", "armor_piercing", "scatter"], 3)
	_install_repair(fixture)
	fixture.edges[1].take_damage(25.0)
	var repair_task_id: int = fixture.repair.request_repair(fixture.edges[1])
	_check(repair_task_id > 0, "Real damaged edge admits its three-unit repair task")
	fixture.repair_supply.refresh_budget()
	var repair_budget: Dictionary = fixture.repair_supply.get_supply_snapshot()
	_check(int(repair_budget.get("reservation_goal", 0)) == 3
		and int(repair_budget.get("reserved_nutrition", 0)) == 3
		and fixture.core.nutrition == 3 and fixture.core.get_spendable_nutrition() == 0,
		"Repair goal locks real funds without another inventory or debit")
	_reserve(fixture, 8, "Funded repair and mixed combat demand")
	_check(not _dispatch_battle(fixture, 0) and fixture.core.nutrition == 3,
		"Combat supply cannot spend the funded repair budget")
	fixture.core.add_nutrition(10)
	fixture.income += 10
	_check(fixture.core.nutrition == 13 and fixture.core.get_spendable_nutrition() == 10,
		"Surplus becomes spendable after preserving the funded repair goal")
	_reserve(fixture, 8, "Repair priority with two construction units above combat reserve")
	_start_construction(fixture, "growth")
	_start_construction(fixture, "cultivation")
	_check(fixture.growth_supply.try_dispatch() and fixture.cultivation_supply.try_dispatch(),
		"Both real construction systems spend only the two surplus units")
	_freeze_packets(fixture.growth_packets)
	_freeze_packets(fixture.cultivation_packets)
	_check(fixture.core.nutrition == 11 and fixture.core.get_spendable_nutrition() == 8
		and not fixture.growth_supply.try_dispatch() and not fixture.cultivation_supply.try_dispatch(),
		"New construction cannot cross the repair-funded and combat-demand budget")
	_reserve(fixture, 8, "Actual paid construction leaves zero surplus")
	_check(_dispatch_battle(fixture, 1) and fixture.core.nutrition == 10,
		"AP combat receives one legitimate paid unit outside the repair lock")
	_reserve(fixture, 7, "AP paid incoming reduces its demand without a second deduction")
	_check(fixture.repair_supply.try_dispatch(), "Repair dispatch spends its own funded budget")
	_freeze_packets(fixture.repair_packets)
	fixture.repair_supply.refresh_budget()
	_check(fixture.core.nutrition == 9 and fixture.core.get_spendable_nutrition() == 7
		and fixture.repair_supply.get_in_transit_nutrition() == 1
		and int(fixture.repair_supply.get_supply_snapshot().get("reserved_nutrition", 0)) == 2,
		"Paid repair transit reduces funded demand once without consuming unreserved surplus")
	_reserve(fixture, 7, "Paid repair transit preserves construction budget priority")
	_conservation(fixture, "Mixed real repair/construction/combat paid transit")
	await _deliver_repair(fixture)
	_check(int(fixture.repair.get_task_snapshot().get("buffered_nutrition", 0)) == 1,
		"Real repair arrival is retained as one paid buffer")
	_conservation(fixture, "Repair arrival alongside independent paid transit")
	fixture.repair.cancel_task()
	fixture.growth.cancel_task()
	fixture.cultivation.cancel_task()
	_check(fixture.core.nutrition == 12 and fixture.core.get_spendable_nutrition() == 12
		and fixture.organs[1].incoming_nutrition == 1 and fixture.battle.get_in_transit_count() == 1,
		"Cancelling repair and construction refunds only their three actual paid units and releases unspent locks")
	_reserve(fixture, 7, "Cancelled construction and repair retain legitimate combat incoming")
	await _deliver(fixture.battle_packets)
	_conservation(fixture, "Repair priority and cancellation complete with paid combat delivery")
	await _dispose(fixture)
	cases.append("real_repair_funded_priority_spendable_surplus_paid_transit_and_isolated_refunds")
