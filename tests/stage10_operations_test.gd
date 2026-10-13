extends SceneTree
## 手动推进真实运输验证移植付款/FIFO；分化记录仅作为明确标注的既有状态夹具。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const AP_PROFILE: WeaponProfile = preload("res://resources/weapons/armor_piercing_spore.tres")

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var tracker: CargoPassageTracker
	var scheduler: ConstructionSupplyScheduler
	var supply: SupplySystem
	var repair: RepairSystem
	var system: TransplantSystem
	var source: HyphaNode
	var destination: HyphaNode
	var organ: AttackOrgan
	var weapon: SporeWeapon
	var source_edge: HyphaEdge
	var migration_edge: HyphaEdge
	var packets: Node2D
	var migration: Node2D
	var enemies: Node2D
	var completed: Array[int] = []
	var cancelled: Array[int] = []
	var failed: Array[int] = []
	var observed_lost_stock: Array[int] = []
	var initial_pool: int = 0

var checks: int = 0
var failures: Array[String] = []
var cases: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_dormancy_presence_and_existing_delivery()
	_test_admission_and_reservation()
	_test_preparation_refund_and_old_callbacks()
	_test_real_cost_state_identity_and_unfold_waits()
	_test_dormant_paid_differentiation_then_transplant_fire()
	_test_paid_old_ammo_cancellation()
	_test_shared_fifo_two_units()
	_test_same_body_reroute()
	_test_destroyed_destination_and_body()
	_test_removed_fee_source()
	_test_reentrant_debit_cancellation()
	_test_reset_closes_migration()
	_check(root.get_child_count() == 0, "Operations fixtures leave no nodes")
	print("STAGE10_OPERATIONS_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases,
		"evidence_boundary": "real_transplant_fees_and_paid_dormant_differentiation; stage_eligibility_is_seeded; separate_state_identity_case_uses_preexisting_record",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) < 0.000001


func _node(fixture: Fixture, position: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.world.add_child(node)
	node.position = position
	_check(fixture.network.register_node(node), "Fixture registers a physical junction")
	return node


func _edge(fixture: Fixture, first: Node2D, second: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	edge.traffic_capacity = 2
	fixture.world.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Fixture registers a two-unit physical edge")
	return edge


func _fixture(capital: int = 30) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = capital
	fixture.world.add_child(fixture.core)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Fixture registers the original paying core")
	fixture.source = _node(fixture, Vector2(100.0, 0.0))
	fixture.destination = _node(fixture, Vector2(300.0, 0.0))
	fixture.source_edge = _edge(fixture, fixture.core, fixture.source)
	fixture.migration_edge = _edge(fixture, fixture.source, fixture.destination)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.tracker = CargoPassageTracker.new()
	fixture.world.add_child(fixture.tracker)
	fixture.packets = Node2D.new()
	fixture.migration = Node2D.new()
	fixture.enemies = Node2D.new()
	fixture.world.add_child(fixture.packets)
	fixture.world.add_child(fixture.migration)
	fixture.world.add_child(fixture.enemies)
	fixture.organ = ORGAN_SCENE.instantiate() as AttackOrgan
	fixture.source.add_child(fixture.organ)
	fixture.organ.set_physics_process(false)
	fixture.weapon = WEAPON_SCENE.instantiate() as SporeWeapon
	fixture.weapon.inventory_owner = fixture.organ
	fixture.weapon.enemy_container = fixture.enemies
	fixture.weapon.position = Vector2(0.0, -28.0)
	fixture.source.add_child(fixture.weapon)
	fixture.weapon.set_process(false)
	fixture.weapon.fire_timer.stop()
	fixture.supply = SupplySystem.new()
	fixture.supply.mother_core = fixture.core
	fixture.supply.network_system = fixture.network
	fixture.supply.traffic_system = fixture.traffic
	fixture.supply.packet_container = fixture.packets
	fixture.supply.packet_scene = PACKET_SCENE
	fixture.world.add_child(fixture.supply)
	fixture.supply.set_process(false)
	_check(fixture.supply.register_organ(fixture.organ), "Original organ is registered for combat supplies")
	fixture.repair = RepairSystem.new()
	fixture.repair.network_system = fixture.network
	fixture.world.add_child(fixture.repair)
	fixture.repair.set_physics_process(false)
	fixture.system = TransplantSystem.new()
	fixture.system.mother_core = fixture.core
	fixture.system.network_system = fixture.network
	fixture.system.traffic_system = fixture.traffic
	fixture.system.combat_supply_system = fixture.supply
	fixture.system.repair_system = fixture.repair
	fixture.system.cargo_passage_tracker = fixture.tracker
	fixture.system.packet_container = fixture.packets
	fixture.system.migration_container = fixture.migration
	fixture.world.add_child(fixture.system)
	fixture.system.set_physics_process(false)
	fixture.system.task_completed.connect(func(task_id: int) -> void: fixture.completed.append(task_id))
	fixture.system.task_cancelled.connect(func(task_id: int) -> void: fixture.cancelled.append(task_id))
	fixture.system.task_failed.connect(func(task_id: int, _reason: StringName) -> void: fixture.failed.append(task_id))
	fixture.organ.tissue_destroyed.connect(func(_organ: Node2D) -> void:
		fixture.observed_lost_stock.append(fixture.organ.nutrition))
	fixture.scheduler = ConstructionSupplyScheduler.new()
	fixture.scheduler.auto_dispatch = false
	fixture.world.add_child(fixture.scheduler)
	fixture.scheduler.set_process(false)
	fixture.initial_pool = fixture.core.nutrition + fixture.organ.nutrition
	return fixture


func _dispose(fixture: Fixture) -> void:
	fixture.scheduler.reset()
	fixture.system.stop()
	fixture.world.free()


func _pool(fixture: Fixture) -> int:
	var resources: Dictionary = fixture.system.get_resource_snapshot()
	return fixture.core.nutrition + fixture.organ.nutrition \
		+ int(resources["buffered_nutrition"]) + int(resources["in_transit_nutrition"]) \
		+ int(resources["consumed_nutrition"]) + int(resources["lost_nutrition"]) \
		+ fixture.supply.get_in_transit_count()


func _deliver_fee(fixture: Fixture, scheduled: bool = false) -> NutrientPacket:
	var dispatched: bool = fixture.scheduler.dispatch_round() == 1 if scheduled else fixture.system.try_dispatch()
	_check(dispatched, "One real fee packet is debited through the selected dispatcher")
	if not dispatched:
		return null
	var shipment: Dictionary = fixture.system.get_shipment_records().back()
	var packet: NutrientPacket = shipment["packet"] as NutrientPacket
	packet.set_physics_process(false)
	for _step: int in range(120):
		if bool(packet.get_transport_snapshot()["terminal"]):
			break
		fixture.traffic.refresh()
		packet._physics_process(0.05)
	_check(packet.has_arrived_at(fixture.source, String(shipment["transport_task_id"])),
		"Fee packet actually arrives at the original source host")
	_check(_pool(fixture) == fixture.initial_pool, "Real fee delivery balances the same source account")
	return packet


func _pay_all(fixture: Fixture) -> void:
	for _unit: int in range(TransplantSystem.TOTAL_COST):
		_deliver_fee(fixture)
	_check(fixture.system.get_task_snapshot()["buffered_nutrition"] == 6,
		"Six arrived units remain refundable before departure")
	_check(fixture.system.get_resource_snapshot()["consumed_nutrition"] == 0,
		"Packet arrival alone does not pretend the operation has consumed its fee")


func _depart(fixture: Fixture) -> NutrientPacket:
	fixture.system.advance(0.01)
	var snapshot: Dictionary = fixture.system.get_task_snapshot()
	_check(snapshot["state"] == &"migrating" and snapshot["consumed_nutrition"] == 6,
		"Departure commits all six fee units once")
	_check(not fixture.system.cancel_task(), "Departure closes preparation cancellation")
	for child: Node in fixture.migration.get_children():
		if child is NutrientPacket:
			var packet: NutrientPacket = child as NutrientPacket
			packet.set_physics_process(false)
			_check(packet.get_transport_snapshot()["units"] == 2,
				"The body uses two units from the existing shared traffic scheduler")
			_check(String(packet.get_transport_snapshot()["cargo_id"]).is_empty(),
				"The migrating body has no candidate-passage or income receipt")
			return packet
	_check(false, "Departure creates exactly one transport carrier")
	return null


func _arrive(fixture: Fixture, packet: NutrientPacket) -> void:
	if not is_instance_valid(packet):
		return
	for _step: int in range(500):
		if bool(packet.get_transport_snapshot()["terminal"]):
			break
		fixture.traffic.refresh()
		packet._physics_process(0.05)
	_check(packet.has_arrived_at(fixture.destination), "The original body reaches the reserved destination")
	_check(fixture.system.get_task_snapshot()["state"] == &"unfolding",
		"Actual arrival begins the deployment period")


func _test_dormancy_presence_and_existing_delivery() -> void:
	cases.append("twelve_second_absence_and_immediate_presence")
	var fixture: Fixture = _fixture()
	var organ: AttackOrgan = fixture.organ
	organ.nutrition = 0
	_check(organ.reserve_nutrition(1), "A paid-before-sleep reservation is lawful")
	organ.advance_dormancy(11.999)
	_check(not organ.is_dormant, "True absence below twelve seconds cannot close the organ")
	organ.advance_dormancy(0.0011)
	_check(organ.is_dormant and not organ.needs_supply(), "Twelve seconds closes work and new supply")
	_check(organ.complete_delivery(1) and organ.nutrition == 1,
		"Dormancy accepts the earlier reservation without refilling the organ")
	_check(not organ.reserve_nutrition(1), "A dormant organ rejects a new supply reservation")
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	fixture.enemies.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.position = organ.global_position + Vector2(10.0, 0.0)
	organ.set_work_enabled(false)
	fixture.weapon.set_firing_enabled(false)
	organ.advance_dormancy(0.0)
	_check(not organ.is_dormant and not organ.is_work_enabled() and not fixture.weapon.is_firing_enabled(),
		"Presence wakes immediately while retaining both independent work gates")
	organ.nutrition = 0
	var record: AttackOrgan.DifferentiationRecord = organ._get_differentiation_record()
	record.state = &"differentiating"
	var targeting := CombatTargetingSystem.new()
	fixture.world.add_child(targeting)
	fixture.weapon.targeting_system = targeting
	var reserved_profile: WeaponProfile = AP_PROFILE.copy_for_instance()
	reserved_profile.damage = enemy.health * 2
	_check(not targeting.prepare_commitment(enemy, reserved_profile.create_damage_request(), fixture.weapon).is_empty()
		and targeting.get_remaining_health(enemy) == 0,
		"Existing damage reservations fully cover an enemy that is still alive")
	organ.advance_dormancy(20.0)
	_check(not organ.is_dormant and _near(float(organ.get_dormancy_snapshot()["absence_time"]), 0.0),
		"A live enemy prevents dormancy despite empty ammo, damage reservations and differentiation")
	enemy.position += Vector2(1000.0, 0.0)
	organ.advance_dormancy(12.0)
	_check(organ.is_dormant and not organ.get_requested_work_enabled(),
		"Absence preserves the requested work intent and differentiation record")
	_check(organ.modulate.a < 1.0 and organ.cap.scale.y < 1.0,
		"Closed dormant tissue is translucent and visibly folded")
	record.state = &"cancelled"
	_dispose(fixture)


func _test_admission_and_reservation() -> void:
	cases.append("mature_identity_and_unique_slot_admission")
	var fixture: Fixture = _fixture()
	_check(fixture.system.preview_transplant(fixture.organ, fixture.source)["reason"] == &"same_destination",
		"A transplant cannot claim its own occupied source")
	fixture.organ.take_damage(10.0)
	_check(fixture.repair.request_repair(fixture.organ) > 0, "A real repair task owns the same tissue")
	_check(fixture.system.preview_transplant(fixture.organ, fixture.destination)["reason"] == &"repairing",
		"Active repair prevents conflicting migration")
	fixture.repair.cancel_task()
	fixture.organ._get_differentiation_record().state = &"waiting"
	_check(fixture.system.request_transplant(fixture.organ, fixture.destination) == 0,
		"Active differentiation cannot be transplanted")
	fixture.organ._get_differentiation_record().state = &"idle"
	var preview: Dictionary = fixture.system.preview_transplant(fixture.organ, fixture.destination)
	_check(preview["valid"] and preview["route"] is NetworkRoute and preview["route"].found,
		"Read-only preview includes the reachable two-unit migration route")
	var initial_balance: int = fixture.core.nutrition
	var task_id: int = fixture.system.request_transplant(fixture.organ, fixture.destination)
	_check(task_id > 0 and fixture.core.nutrition == initial_balance,
		"Admission reserves a unique slot without inventing a fee debit")
	_check(not fixture.destination.try_reserve_organ_slot("competing-operation"),
		"The reserved destination cannot accept another operation")
	_check(fixture.system.request_transplant(fixture.organ, fixture.destination) == 0,
		"Only one task can be active")
	_check(fixture.system.cancel_task() and fixture.destination.is_organ_slot_available(),
		"Preparation cancellation releases the exact destination reservation")
	_dispose(fixture)


func _test_preparation_refund_and_old_callbacks() -> void:
	cases.append("mixed_buffer_transit_once_refund_and_generation")
	var fixture: Fixture = _fixture()
	var task_id: int = fixture.system.request_transplant(fixture.organ, fixture.destination)
	_check(fixture.scheduler.register_supply("transplant", fixture.system),
		"Transplant fees register directly with the existing construction dispatcher")
	_check(not fixture.system.try_dispatch(), "Managed fees cannot escape the exclusive dispatcher")
	var old_packet: NutrientPacket = _deliver_fee(fixture, true)
	_deliver_fee(fixture, true)
	_check(fixture.scheduler.dispatch_round() == 1 and fixture.system.get_in_transit_nutrition() == 1,
		"Two buffered units and one paid moving unit occupy distinct accounting buckets")
	_check(fixture.system.cancel_task() and fixture.cancelled == [task_id],
		"Preparation cancellation has one terminal notification")
	_check(fixture.core.nutrition + fixture.organ.nutrition == fixture.initial_pool,
		"Buffered and moving unconsumed fees refund exactly once to their original core")
	_check(not fixture.system.cancel_task(), "A cancelled task cannot repeat its refund")
	old_packet.arrived.emit(old_packet)
	fixture.system.reset()
	var new_id: int = fixture.system.request_transplant(fixture.organ, fixture.destination)
	_check(new_id > task_id, "Task identity never repeats across reset")
	old_packet.arrived.emit(old_packet)
	_check(fixture.system.get_task_snapshot()["buffered_nutrition"] == 0
		and fixture.core.nutrition + fixture.organ.nutrition == fixture.initial_pool,
		"Old packet signals cannot fund or refund a new generation")
	_dispose(fixture)


func _test_real_cost_state_identity_and_unfold_waits() -> void:
	cases.append("same_injured_specialized_body_with_paid_unfold_waits")
	var fixture: Fixture = _fixture()
	fixture.organ.take_damage(37.0)
	_check(fixture.weapon.configure_profile(AP_PROFILE), "Fixture applies an existing AP weapon configuration")
	# 此夹具明确表示此前已完成的分化，不宣称在本组重新证明那八份付款。
	var record: AttackOrgan.DifferentiationRecord = fixture.organ._get_differentiation_record()
	record.direction = WeaponProfile.DamageType.ARMOR_PIERCING
	record.target_profile = AP_PROFILE.copy_for_instance()
	record.consumed_nutrition = 8
	record.effective_time = 5.0
	record.completed = true
	record.state = &"completed"
	record.host_ref = weakref(fixture.source)
	record.weapon_ref = weakref(fixture.weapon)
	var organ_id: int = fixture.organ.get_instance_id()
	var weapon_id: int = fixture.weapon.get_instance_id()
	var stock: int = fixture.organ.nutrition
	_check(fixture.system.request_transplant(fixture.organ, fixture.destination) > 0,
		"An injured mature AP organ can migrate")
	_pay_all(fixture)
	for shipment: Dictionary in fixture.system.get_shipment_records():
		_check(fixture.tracker.get_cargo_snapshot(String(shipment["cargo_id"]))["status"] == &"pending",
			"Refundable fee deliveries do not promote candidate passages prematurely")
	var carrier: NutrientPacket = _depart(fixture)
	_check(fixture.source.get_organ_slot_state() == &"empty" and fixture.organ.is_in_group("colony_tissues"),
		"Departure keeps source edges and carries the sole damageable original tissue")
	_check(_pool(fixture) == fixture.initial_pool, "Departure transfers buffered fees into six sunk units")
	for shipment: Dictionary in fixture.system.get_shipment_records():
		_check(fixture.tracker.get_cargo_snapshot(String(shipment["cargo_id"]))["status"] == &"confirmed",
			"Only consumed fee packets confirm their real passage")
	_arrive(fixture, carrier)
	_check(fixture.organ.get_instance_id() == organ_id and fixture.weapon.get_instance_id() == weapon_id
		and fixture.organ.nutrition == stock and _near(fixture.organ.health, 23.0),
		"Arrival retains identity, original weapon, stock and injured health")
	_check(record == fixture.organ._get_differentiation_record() and record.get_host() == fixture.destination
		and record.get_weapon() == fixture.weapon and record.consumed_nutrition == 8
		and record.completed and _near(record.effective_time, 5.0),
		"Arrival rebinds the same locked differentiation record without resetting paid progress")
	_check(fixture.organ.get_attack_type() == WeaponProfile.DamageType.ARMOR_PIERCING
		and fixture.supply.has_registered_organ(fixture.organ) and not fixture.organ.is_work_enabled(),
		"Arrival restores registration while keeping the deployment work gate")
	fixture.destination.take_damage(fixture.destination.max_health)
	fixture.system.advance(10.0)
	_check(_near(float(fixture.system.get_task_snapshot()["effective_time"]), 0.0),
		"Withered destination waits without consuming deployment time")
	fixture.destination.heal(fixture.destination.max_health)
	fixture.system.advance(1.0)
	fixture.source_edge.take_damage(fixture.source_edge.max_health)
	fixture.system.advance(10.0)
	_check(_near(float(fixture.system.get_task_snapshot()["effective_time"]), 1.0),
		"A real disconnect freezes the already-paid deployment clock")
	fixture.source_edge.heal(fixture.source_edge.max_health)
	fixture.system.advance(1.99)
	_check(fixture.system.has_active_task() and fixture.organ.is_transplanting(),
		"The body cannot unfold before three effective seconds")
	fixture.system.advance(0.02)
	_check(fixture.completed.size() == 1 and not fixture.organ.is_transplanting()
		and fixture.organ.is_work_enabled() and _pool(fixture) == fixture.initial_pool,
		"Three paid connected seconds complete once without free stock or health")
	_dispose(fixture)


func _test_paid_old_ammo_cancellation() -> void:
	cases.append("source_ammo_shipments_cancel_before_body_leaves")
	var fixture: Fixture = _fixture()
	fixture.organ.nutrition = 1
	fixture.organ.refill_target = 6
	fixture.initial_pool = fixture.core.nutrition + fixture.organ.nutrition
	_check(fixture.supply.request_supply(fixture.organ) and fixture.organ.incoming_nutrition == 1,
		"A preexisting combat shipment reserves one actual unit")
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_pay_all(fixture)
	var carrier: NutrientPacket = _depart(fixture)
	_check(fixture.supply.get_in_transit_count() == 0 and fixture.organ.incoming_nutrition == 0
		and fixture.organ.nutrition == 1, "Departure cancels old ammo cargo and its unique reservation")
	_check(_pool(fixture) == fixture.initial_pool, "Cancelled combat ammo refunds once before migration")
	_arrive(fixture, carrier)
	_dispose(fixture)


func _test_dormant_paid_differentiation_then_transplant_fire() -> void:
	cases.append("dormant_real_paid_differentiation_transplant_and_wakeup_fire")
	var fixture: Fixture = _fixture()
	fixture.organ.take_damage(37.0)
	fixture.organ.advance_dormancy(12.0)
	_check(fixture.organ.is_dormant and fixture.organ.get_requested_work_enabled()
		and not fixture.organ.is_work_enabled(),
		"Dormancy closes effective work while keeping the original enabled intent")
	# 只注入阶段准入；下面八份材料全部从真实母核经真实包送达并消耗。
	var progress := ColonyProgress.new()
	fixture.world.add_child(progress)
	_check(progress.record_arrival("operations:seeded-stage-eligibility", 160),
		"Regression explicitly seeds only differentiation stage eligibility")
	var capabilities := ColonyCapabilities.new()
	capabilities.colony_progress = progress
	fixture.world.add_child(capabilities)
	var differentiation := DifferentiationSystem.new()
	differentiation.network_system = fixture.network
	differentiation.colony_capabilities = capabilities
	fixture.world.add_child(differentiation)
	differentiation.set_physics_process(false)
	var differentiation_supply := DifferentiationSupplySystem.new()
	differentiation_supply.differentiation_system = differentiation
	differentiation_supply.mother_core = fixture.core
	differentiation_supply.network_system = fixture.network
	differentiation_supply.traffic_system = fixture.traffic
	differentiation_supply.combat_supply_system = fixture.supply
	differentiation_supply.cargo_passage_tracker = fixture.tracker
	differentiation_supply.packet_container = fixture.packets
	differentiation_supply.auto_supply = false
	fixture.world.add_child(differentiation_supply)
	differentiation_supply.set_process(false)
	var task_id: int = differentiation.start_differentiation(
		fixture.organ, WeaponProfile.DamageType.ARMOR_PIERCING)
	_check(task_id > 0, "A dormant mature original organ actually starts differentiation")
	var record: AttackOrgan.DifferentiationRecord = fixture.organ._get_differentiation_record()
	_check(record.previous_work_enabled, "Differentiation saves raw enabled intent instead of dormant effective state")
	var balance_before: int = fixture.core.nutrition
	for _unit: int in range(8):
		var dispatched: bool = differentiation_supply.try_dispatch()
		_check(dispatched, "Dormant differentiation dispatches one actual paid material packet")
		if not dispatched:
			break
		var shipment: Dictionary = differentiation_supply.get_shipment_records().back()
		var packet: NutrientPacket = shipment["packet"] as NutrientPacket
		packet.set_physics_process(false)
		for _step: int in range(120):
			if bool(packet.get_transport_snapshot()["terminal"]):
				break
			fixture.traffic.refresh()
			packet._physics_process(0.05)
		_check(packet.has_arrived_at(fixture.source, String(shipment["transport_task_id"])),
			"Actual differentiation material reaches the dormant source host")
		differentiation.advance(0.625)
	_check(record.completed and record.consumed_nutrition == 8
		and _near(record.effective_time, 5.0) and fixture.core.nutrition == balance_before - 8,
		"The same dormant organ finishes its real eight-paid-unit five-second differentiation")
	_check(fixture.organ.is_dormant and fixture.organ.get_requested_work_enabled(),
		"Completed differentiation restores the original intent while remaining dormant")
	fixture.initial_pool = fixture.core.nutrition + fixture.organ.nutrition
	_check(fixture.system.request_transplant(fixture.organ, fixture.destination) > 0,
		"The actually differentiated dormant organ admits its real transplant")
	_pay_all(fixture)
	var carrier: NutrientPacket = _depart(fixture)
	_arrive(fixture, carrier)
	fixture.system.advance(3.0)
	_check(fixture.completed.size() == 1 and fixture.organ.is_dormant
		and fixture.organ.get_requested_work_enabled()
		and record.get_host() == fixture.destination and record.get_weapon() == fixture.weapon,
		"Transplant preserves the completed record and dormant enabled intent")
	var projectiles := Node2D.new()
	fixture.world.add_child(projectiles)
	fixture.weapon.projectile_container = projectiles
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	fixture.enemies.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.position = fixture.organ.global_position + Vector2(10.0, 0.0)
	fixture.organ.advance_dormancy(0.0)
	_check(not fixture.organ.is_dormant and fixture.organ.is_work_enabled()
		and _near(fixture.organ.health, 23.0),
		"A real enemy immediately wakes the same injured transplanted organ")
	var stock_before: int = fixture.organ.nutrition
	fixture.weapon._on_fire_timer_timeout()
	_check(int(fixture.weapon.get_shot_statistics()["rounds"]) == 1
		and fixture.organ.nutrition == stock_before - fixture.weapon.get_nutrition_cost()
		and projectiles.get_child_count() == 1,
		"The original AP weapon really fires a paid projectile after dormant differentiation and transplant")
	differentiation_supply.reset(true)
	_dispose(fixture)


func _test_shared_fifo_two_units() -> void:
	cases.append("fifo_body_waits_for_two_units_without_overtaking")
	var fixture: Fixture = _fixture()
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_pay_all(fixture)
	var route: NetworkRoute = fixture.network.find_available_route(fixture.source, fixture.destination)
	var leader := NutrientPacket.new()
	fixture.packets.add_child(leader)
	leader.set_physics_process(false)
	leader.start_route(route, fixture.network, fixture.traffic, "fifo:leader", &"supply")
	var carrier: NutrientPacket = _depart(fixture)
	var trailer := NutrientPacket.new()
	fixture.packets.add_child(trailer)
	trailer.set_physics_process(false)
	trailer.start_route(route, fixture.network, fixture.traffic, "fifo:trailer", &"supply")
	_check(carrier.get_transport_snapshot()["state"] == &"waiting"
		and trailer.get_transport_snapshot()["state"] == &"waiting",
		"The two-unit body and later one-unit cargo wait behind the granted leader")
	carrier._physics_process(0.5)
	_check(fixture.organ.global_position == fixture.source.global_position,
		"A queued body stays at the real source instead of teleporting")
	leader._physics_process(2.0)
	fixture.traffic.refresh()
	carrier._physics_process(0.05)
	_check(carrier.get_transport_snapshot()["state"] == &"moving"
		and trailer.get_transport_snapshot()["state"] == &"waiting",
		"The body obtains both shared units before the later small cargo")
	_check(fixture.organ.global_position == carrier.global_position,
		"The original damageable organ follows the carrier while moving")
	_arrive(fixture, carrier)
	_dispose(fixture)


func _test_same_body_reroute() -> void:
	cases.append("reroute_at_real_intermediate_node")
	var fixture: Fixture = _fixture()
	fixture.network.unregister_edge(fixture.migration_edge)
	fixture.migration_edge.free()
	var middle: HyphaNode = _node(fixture, Vector2(200.0, 0.0))
	var detour: HyphaNode = _node(fixture, Vector2(200.0, 100.0))
	_edge(fixture, fixture.source, middle)
	var later: HyphaEdge = _edge(fixture, middle, fixture.destination)
	_edge(fixture, middle, detour)
	_edge(fixture, detour, fixture.destination)
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_pay_all(fixture)
	var carrier: NutrientPacket = _depart(fixture)
	later.take_damage(later.max_health)
	_arrive(fixture, carrier)
	_check(int(carrier.get_transport_snapshot()["reroute_count"]) >= 1
		and fixture.organ.get_parent() == fixture.destination,
		"A later broken edge reroutes the same two-unit body at an actual junction")
	_dispose(fixture)


func _test_destroyed_destination_and_body() -> void:
	cases.append("postdeparture_failure_once_with_original_stock")
	var fixture: Fixture = _fixture()
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_pay_all(fixture)
	var carrier: NutrientPacket = _depart(fixture)
	fixture.network.unregister_node(fixture.destination)
	_check(fixture.failed.size() == 1 and not fixture.system.has_active_task()
		and fixture.destination.is_organ_slot_available(),
		"Permanent destination loss closes the task and releases its slot once")
	_check(fixture.observed_lost_stock == [4] and fixture.organ.nutrition == 4
		and fixture.organ.health == 0.0, "Failure exposes original stock to the owning tissue lifecycle")
	_check(fixture.system.get_resource_snapshot()["consumed_nutrition"] == 6
		and fixture.core.nutrition == 24, "Departure fees remain sunk on permanent loss")
	carrier.arrived.emit(carrier)
	fixture.system.reset()
	_check(fixture.failed.size() == 1 and fixture.completed.is_empty(),
		"Old completion and reset cannot restore a lost organ or repeat failure")
	_dispose(fixture)
	fixture = _fixture()
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_pay_all(fixture)
	_depart(fixture)
	fixture.organ.take_damage(100.0)
	_check(fixture.failed.size() == 1 and fixture.destination.is_organ_slot_available()
		and fixture.observed_lost_stock == [4], "Body death aborts before one stock-loss settlement")
	_dispose(fixture)


func _test_removed_fee_source() -> void:
	cases.append("fee_loss_only_when_original_refund_source_removed")
	var fixture: Fixture = _fixture(1)
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_deliver_fee(fixture)
	fixture.core.free()
	var resources: Dictionary = fixture.system.get_resource_snapshot()
	_check(resources["lost_nutrition"] == 1 and resources["buffered_nutrition"] == 0
		and resources["in_transit_nutrition"] == 0 and resources["consumed_nutrition"] == 0,
		"A removed paying core archives the only fee that cannot lawfully refund")
	_check(fixture.failed.size() == 1 and fixture.destination.is_organ_slot_available(),
		"Removed source releases preparation instead of debiting a replacement core")
	_dispose(fixture)


func _test_reentrant_debit_cancellation() -> void:
	cases.append("synchronous_core_debit_cancel_is_balanced")
	var fixture: Fixture = _fixture()
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	var debit_balance: int = fixture.core.nutrition - 1
	fixture.core.nutrition_changed.connect(func(balance: int) -> void:
		if balance == debit_balance:
			fixture.system.cancel_task())
	_check(not fixture.system.try_dispatch(), "A cancelled synchronous debit cannot remain a dispatched fee")
	_check(fixture.cancelled.size() == 1 and fixture.core.nutrition + fixture.organ.nutrition == fixture.initial_pool
		and fixture.system.get_in_transit_nutrition() == 0,
		"Core notification cancellation refunds the prepaid marker exactly once")
	_dispose(fixture)


func _test_reset_closes_migration() -> void:
	cases.append("reset_invalidates_old_transport_before_cleanup")
	var fixture: Fixture = _fixture()
	fixture.system.request_transplant(fixture.organ, fixture.destination)
	_pay_all(fixture)
	var carrier: NutrientPacket = _depart(fixture)
	fixture.system.reset()
	carrier.arrived.emit(carrier)
	_check(fixture.failed.size() == 1 and fixture.completed.is_empty()
		and fixture.destination.is_organ_slot_available() and fixture.source.get_organ_slot_state() == &"empty",
		"Reset closes the old generation without restoring its migrated body to the source")
	_check(fixture.system.get_resource_snapshot()["consumed_nutrition"] == 6,
		"Reset cannot refund or forget already-consumed structural operation costs")
	_dispose(fixture)
