extends SceneTree
## 独立验证阶段十生产后端；实际包走共享网络，手动推进可控时钟和已领取的消化任务。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const REMAINS_PACKET_SCENE: PackedScene = preload("res://scenes/recycling/remains_packet.tscn")
const EPSILON: float = 0.00001

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var host_a: HyphaNode
	var host_b: HyphaNode
	var edge_a: HyphaEdge
	var edge_b: HyphaEdge
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var field: FungalField
	var ground: Node2D
	var recovery_packets: Node2D
	var nutrient_packets: Node2D
	var cultivation: CultivationSystem
	var supply: CultivationSupplySystem
	var recycling: RecyclingSystem
	var returns: NutritionReturnSystem
	var stomach_a: DigestiveOrgan
	var stomach_b: DigestiveOrgan
	var decay_losses: Array[int] = []

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_paid_recipes_and_frozen_continuation()
	await _test_unspent_and_in_transit_refunds()
	await _test_receiver_selection_and_fixed_identity()
	await _test_receiver_reservation_before_claim()
	await _test_receiver_reset_and_old_reservation()
	await _test_shared_traffic_selection()
	await _test_multi_source_returns_and_dormancy()
	await _test_source_loss_during_core_receipt()
	await _test_ground_decay_and_atomic_claim()
	await _test_cut_batch_decay_and_teardown()
	_check(root.get_child_count() == 0, "Production fixtures leave no scene objects")
	print("STAGE10_PRODUCTION_TEST_RESULT ", JSON.stringify({
		"groups": 10, "checks": checks, "failures": failures,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(value: float, expected: float) -> bool:
	return absf(value - expected) <= EPSILON


func _new_container(world: Node2D) -> Node2D:
	var container: Node2D = Node2D.new()
	world.add_child(container)
	return container


func _new_fixture(with_stomachs: bool = false) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.world.add_child(fixture.core)
	fixture.host_a = NODE_SCENE.instantiate() as HyphaNode
	fixture.host_a.position = Vector2(80.0, 0.0)
	fixture.world.add_child(fixture.host_a)
	fixture.host_b = NODE_SCENE.instantiate() as HyphaNode
	fixture.host_b.position = Vector2(160.0, 0.0)
	fixture.world.add_child(fixture.host_b)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Fixture core registered")
	_check(fixture.network.register_node(fixture.host_a), "Fixture first host registered")
	_check(fixture.network.register_node(fixture.host_b), "Fixture second host registered")
	fixture.edge_a = _new_edge(fixture, fixture.host_a)
	fixture.edge_b = _new_edge(fixture, fixture.host_b)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.field = FungalField.new()
	fixture.world.add_child(fixture.field)
	fixture.field.set_process(false)
	fixture.field.set_sources([
		{"node": fixture.core, "kind": &"core", "connected": true},
		{"node": fixture.host_a, "kind": &"junction", "connected": true},
		{"node": fixture.host_b, "kind": &"junction", "connected": true},
	])
	fixture.field.advance(1.0)
	fixture.ground = _new_container(fixture.world)
	fixture.recovery_packets = _new_container(fixture.world)
	fixture.nutrient_packets = _new_container(fixture.world)
	fixture.cultivation = CultivationSystem.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.enemy_container = _new_container(fixture.world)
	fixture.cultivation.projectile_container = _new_container(fixture.world)
	fixture.world.add_child(fixture.cultivation)
	fixture.cultivation.set_physics_process(false)
	fixture.supply = CultivationSupplySystem.new()
	fixture.supply.cultivation_system = fixture.cultivation
	fixture.supply.mother_core = fixture.core
	fixture.supply.network_system = fixture.network
	fixture.supply.traffic_system = fixture.traffic
	fixture.supply.traffic_required = true
	fixture.supply.packet_container = fixture.nutrient_packets
	fixture.supply.auto_supply = false
	fixture.world.add_child(fixture.supply)
	fixture.supply.set_process(false)
	fixture.recycling = RecyclingSystem.new()
	fixture.recycling.network_system = fixture.network
	fixture.recycling.traffic_system = fixture.traffic
	fixture.recycling.traffic_required = true
	fixture.recycling.fungal_field = fixture.field
	fixture.recycling.remains_container = fixture.ground
	fixture.recycling.packet_container = fixture.recovery_packets
	fixture.recycling.packet_scene = REMAINS_PACKET_SCENE
	fixture.world.add_child(fixture.recycling)
	fixture.returns = NutritionReturnSystem.new()
	fixture.returns.mother_core = fixture.core
	fixture.returns.network_system = fixture.network
	fixture.returns.traffic_system = fixture.traffic
	fixture.returns.traffic_required = true
	fixture.returns.packet_container = fixture.nutrient_packets
	fixture.returns.auto_return = false
	fixture.world.add_child(fixture.returns)
	fixture.returns.get_node("DispatchTimer").stop()
	if with_stomachs:
		fixture.stomach_a = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
		fixture.host_a.add_child(fixture.stomach_a)
		fixture.stomach_a.digest_timer.wait_time = 1000.0
		fixture.stomach_b = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
		fixture.host_b.add_child(fixture.stomach_b)
		fixture.stomach_b.digest_timer.wait_time = 1000.0
		fixture.recycling.digestive_organ = fixture.stomach_a
		fixture.returns.digestive_organ = fixture.stomach_a
		_check(fixture.recycling.register_digestive(fixture.stomach_b), "Second recycling receiver registered")
		_check(fixture.returns.register_digestive(fixture.stomach_b), "Second return source registered")
	return fixture


func _new_edge(fixture: Fixture, host: HyphaNode) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = fixture.core
	edge.end_node = host
	edge.traffic_capacity = 2
	fixture.world.add_child(edge)
	_check(fixture.network.register_edge(edge), "Fixture route registered")
	return edge


func _dispose(fixture: Fixture) -> void:
	fixture.supply.reset()
	fixture.cultivation.reset()
	fixture.recycling.reset(true)
	fixture.returns.reset()
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _deliver_paid(fixture: Fixture, count: int) -> void:
	for index: int in range(count):
		var dispatched: bool = fixture.supply.try_dispatch()
		_check(dispatched, "Real paid cultivation shipment %d dispatched" % index)
		if not dispatched:
			break
		var records: Array[Dictionary] = fixture.supply.get_shipment_records()
		var packet: NutrientPacket = records.back()["packet"] as NutrientPacket
		packet.set_physics_process(false)
		packet._physics_process(10.0)


func _new_remains(fixture: Fixture, nutrition: int = 4) -> EnemyRemains:
	var remains: EnemyRemains = REMAINS_SCENE.instantiate() as EnemyRemains
	remains.nutrition_value = nutrition
	fixture.ground.add_child(remains)
	remains.set_physics_process(false)
	remains.decayed.connect(func(amount: int) -> void: fixture.decay_losses.append(amount))
	return remains


func _feed(organ: DigestiveOrgan, nutrition: int) -> void:
	_check(organ.reserve_remains() and organ.complete_delivery(nutrition), "Reserved input delivered")


func _complete_digest(organ: DigestiveOrgan) -> void:
	organ.digest_timer.stop()
	organ._on_digest_timer_timeout()


func _test_paid_recipes_and_frozen_continuation() -> void:
	var attack_recipe: Dictionary = CultivationSystem.get_recipe(&"attack")
	var stomach_recipe: Dictionary = CultivationSystem.get_recipe(&"digestive")
	_check(attack_recipe["total_cost"] == 12 and attack_recipe["startup_cost"] == 4,
		"Attack recipe retains twelve paid materials and four startup nutrition")
	_check(stomach_recipe["total_cost"] == 8 and stomach_recipe["structure_cost"] == 8
		and stomach_recipe["startup_cost"] == 0 and stomach_recipe["minimum_time"] == 3.0,
		"Stomach recipe is eight structure, zero startup, three effective seconds")
	_check(CultivationSystem.get_recipe(&"unknown").is_empty(), "Unknown organ recipe rejected")
	stomach_recipe["total_cost"] = 999
	var fixture: Fixture = _new_fixture()
	fixture.host_a.set_meta("rebuild_digestive", true)
	# 胃囊不依赖战斗配置；任务身份承接空 kind 的旧重建选择。
	var enemies: Node2D = fixture.cultivation.enemy_container
	fixture.cultivation.enemy_container = null
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host_a)
	_check(task_id > 0 and fixture.cultivation.get_task_snapshot()["organ_kind"] == &"digestive",
		"Empty kind uses legacy stomach rebuild marker without combat configuration")
	_deliver_paid(fixture, 8)
	_check(fixture.core.nutrition == 64 and not fixture.supply.try_dispatch(),
		"Eight real deliveries spend eight from original seventy-two capital")
	fixture.cultivation.advance(1.0)
	var paid: int = int(fixture.cultivation.get_task_snapshot()["structure_consumed"])
	_check(paid == 3 and fixture.cultivation.cancel_task(), "Partial stomach stage cancels after three sunk units")
	_check(fixture.core.nutrition == 72 - paid and fixture.cultivation.take_unspent_nutrition(task_id) == 0,
		"Cancellation refunds only the five unspent units once")
	fixture.host_a.remove_meta("rebuild_digestive")
	var resumed_id: int = fixture.cultivation.continue_cultivation(fixture.host_a)
	var continued: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(resumed_id > task_id and continued["organ_kind"] == &"digestive"
		and continued["total_cost"] == 8 and continued["structure_cost"] == 8
		and continued["startup_cost"] == 0 and continued["requested_nutrition"] == 5,
		"Continuation freezes original kind and recipe after metadata and returned-recipe mutation")
	_check(not fixture.cultivation.receive_nutrition(task_id, "stale-stomach", 1), "Old task rejects stale delivery")
	_deliver_paid(fixture, 5)
	fixture.cultivation.advance(1.99)
	_check(fixture.cultivation.has_active_task(), "Stomach cannot mature before three total effective seconds")
	fixture.cultivation.advance(0.02)
	var completed: Dictionary = fixture.cultivation.get_task_snapshot()
	var stomach: DigestiveOrgan = fixture.host_a.get_organ_occupant() as DigestiveOrgan
	_check(completed["state"] == &"completed" and completed["structure_consumed"] == 8
		and completed["startup_reserved"] == 0 and completed["startup_transferred"] == 0
		and completed["consumed_nutrition"] == 8 and fixture.core.nutrition == 64,
		"Completed stomach owns exactly eight structure with no historical or startup refund")
	_check(is_instance_valid(stomach) and stomach.get_queued_nutrition() == 0
		and stomach.get_output_nutrition() == 0 and stomach.incoming_remains == 0 and stomach.is_dormant(),
		"Fresh stomach starts empty and dormant")
	_check(fixture.cultivation.get_task_snapshot(task_id)["state"] == &"cancelled",
		"Old cancelled attempt remains separate from completed continuation")
	fixture.cultivation.enemy_container = enemies
	fixture.host_b.set_meta("rebuild_digestive", true)
	var attack_id: int = fixture.cultivation.start_cultivation(fixture.host_b, &"attack")
	_check(attack_id > resumed_id and fixture.cultivation.get_task_snapshot()["total_cost"] == 12,
		"Explicit attack overrides a stomach tombstone")
	_deliver_paid(fixture, 12)
	fixture.cultivation.advance(3.0)
	var attack: AttackOrgan = fixture.host_b.get_organ_occupant() as AttackOrgan
	_check(is_instance_valid(attack) and attack.nutrition == 4
		and fixture.cultivation.get_task_snapshot()["structure_consumed"] == 8
		and fixture.cultivation.get_task_snapshot()["startup_transferred"] == 4,
		"Attack still commits eight structure plus four real startup nutrition")
	await _dispose(fixture)


func _test_unspent_and_in_transit_refunds() -> void:
	var fixture: Fixture = _new_fixture()
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host_a, &"digestive")
	_check(task_id > 0 and fixture.supply.try_dispatch() and fixture.supply.try_dispatch(),
		"Explicit new stomach accepts two paid in-transit shipments")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	_check(fixture.core.nutrition == 70 and fixture.cultivation.cancel_task(), "Cancellation begins with two debited units")
	_check(fixture.core.nutrition == 72 and fixture.supply.get_in_transit_count() == 0,
		"Undelivered stomach funding returns to its original core")
	for record: Dictionary in records:
		var packet: Variant = record["packet"]
		if is_instance_valid(packet):
			packet.arrived.emit(packet)
	_check(fixture.core.nutrition == 72 and fixture.cultivation.get_total_structure_consumed() == 0,
		"Late arrival cannot spend or refund cancelled stomach funding twice")
	await _dispose(fixture)


func _test_receiver_selection_and_fixed_identity() -> void:
	var fixture: Fixture = _new_fixture(true)
	_check(fixture.recycling.register_digestive(fixture.stomach_a)
		and fixture.recycling.register_digestive(fixture.stomach_b)
		and fixture.recycling.get_digestive_organs().size() == 2, "Receiver registration is idempotent with legacy singleton")
	for index: int in range(3):
		_feed(fixture.stomach_a, 4)
	var remains: EnemyRemains = _new_remains(fixture, 7)
	remains.advance_decay(9.0)
	_check(fixture.recycling.try_dispatch(), "Lower receiver queue wins over a shorter route")
	var records: Array[Dictionary] = fixture.recycling.get_shipment_records()
	if not records.is_empty():
		var record: Dictionary = records[0]
		_check(record["receiver"] == fixture.stomach_b and fixture.stomach_b.incoming_remains == 1
			and fixture.stomach_a.incoming_remains == 0, "Chosen receiver owns exactly one input reservation")
		var packet: RemainsPacket = record["packet"] as RemainsPacket
		packet.set_physics_process(false)
		remains.advance_decay(100.0)
		_check(_near(float(remains.get_decay_snapshot()["elapsed_seconds"]), 9.0),
			"A claimed transported corpse pauses its ground exposure")
		fixture.recycling.unregister_digestive(fixture.stomach_b)
		_check(fixture.recycling.get_in_transit_count() == 0 and fixture.stomach_b.incoming_remains == 0
			and remains.is_available() and _near(float(remains.get_decay_snapshot()["remaining_seconds"]), 46.0),
			"Removing receiver drops the same corpse with its original remaining decay time")
		packet.arrived.emit(packet)
		_check(fixture.stomach_b.get_queued_count() == 0, "Late packet cannot deliver into a removed receiver")
	_check(fixture.recycling.try_dispatch() and not fixture.recycling.try_dispatch(),
		"Subsequent claim falls back to remaining stomach and still claims corpse once")
	var fallback: Array[Dictionary] = fixture.recycling.get_shipment_records()
	if not fallback.is_empty():
		_check(fallback[0]["receiver"] == fixture.stomach_a and fallback[0]["remains"] == remains,
			"Fallback changes receiver only on a fresh claim")
		var packet: RemainsPacket = fallback[0]["packet"] as RemainsPacket
		packet.set_physics_process(false)
		packet._physics_process(10.0)
		_check(fixture.stomach_a.get_queued_nutrition() == 19 and fixture.recycling.delivered_count == 1,
			"Fallback corpse keeps exact nutrition and delivers only once")
	await _dispose(fixture)


func _test_receiver_reservation_before_claim() -> void:
	var fixture: Fixture = _new_fixture(true)
	var remains: EnemyRemains = _new_remains(fixture)
	var competitor: Array[bool] = [false]
	fixture.stomach_a.inventory_changed.connect(func(_queued: int, incoming: int) -> void:
		if incoming > 0 and not competitor[0]:
			competitor[0] = remains.try_claim()
	)
	_check(not fixture.recycling.try_dispatch() and competitor[0],
		"Receiver reservation is visible before the unique corpse claim")
	_check(fixture.stomach_a.incoming_remains == 0 and fixture.stomach_b.incoming_remains == 0
		and fixture.recycling.get_in_transit_count() == 0, "A competing claim releases only the unused receiver reservation")
	await _dispose(fixture)


func _test_shared_traffic_selection() -> void:
	var fixture: Fixture = _new_fixture(true)
	var blocker: Node2D = _new_container(fixture.world)
	var waiter: Node2D = _new_container(fixture.world)
	var first: Dictionary = fixture.traffic.request_passage("ahead-1", blocker, "ahead-1",
		fixture.edge_a, fixture.core, fixture.host_a, &"remains")
	var second: Dictionary = fixture.traffic.request_passage("ahead-2", waiter, "ahead-2",
		fixture.edge_a, fixture.core, fixture.host_a, &"remains")
	_check(first.get("state", &"") == &"granted" and second.get("state", &"") == &"queued",
		"Shared traffic fixture occupies and queues the short receiver route")
	_new_remains(fixture)
	_check(fixture.recycling.try_dispatch(), "Reachable receiver dispatches despite another receiver's traffic queue")
	var records: Array[Dictionary] = fixture.recycling.get_shipment_records()
	_check(not records.is_empty() and records[0]["receiver"] == fixture.stomach_b,
		"Route plus shared traffic wait score selects the longer unqueued receiver")
	fixture.traffic.cancel_owner(blocker)
	fixture.traffic.cancel_owner(waiter)
	await _dispose(fixture)


func _test_receiver_reset_and_old_reservation() -> void:
	var fixture: Fixture = _new_fixture(true)
	var old_corpse: EnemyRemains = _new_remains(fixture, 7)
	old_corpse.advance_decay(9.0)
	_check(fixture.recycling.try_dispatch(), "Old receiver generation reserves its corpse")
	var old_records: Array[Dictionary] = fixture.recycling.get_shipment_records()
	if not old_records.is_empty():
		var old_record: Dictionary = old_records[0]
		fixture.stomach_a.reset()
		var new_corpse: EnemyRemains = _new_remains(fixture, 4)
		_check(fixture.recycling.try_dispatch() and fixture.stomach_a.incoming_remains == 1,
			"New receiver generation owns one separate input reservation")
		var new_records: Array[Dictionary] = fixture.recycling.get_shipment_records()
		var old_packet: RemainsPacket = old_record["packet"] as RemainsPacket
		old_packet.set_physics_process(false)
		old_packet._physics_process(10.0)
		_check(fixture.stomach_a.incoming_remains == 1 and fixture.stomach_a.get_queued_count() == 0
			and old_corpse.is_available() and _near(float(old_corpse.get_decay_snapshot()["elapsed_seconds"]), 9.0),
			"Old packet cannot consume new reservation and returns its original timed corpse")
		_check(not fixture.stomach_a.reserve_remains(String(old_record["reservation_id"])),
			"Settled or invalidated input reservation identity cannot be reused")
		if new_records.size() == 2:
			var new_packet: RemainsPacket = new_records.back()["packet"] as RemainsPacket
			new_packet.set_physics_process(false)
			new_packet._physics_process(10.0)
			_check(fixture.stomach_a.get_queued_nutrition() == 4
				and fixture.stomach_a.incoming_remains == 0 and new_corpse.is_queued_for_deletion(),
				"Current input identity delivers only its own four nutrition")
	await _dispose(fixture)


func _test_multi_source_returns_and_dormancy() -> void:
	var fixture: Fixture = _new_fixture(true)
	_check(fixture.stomach_a.is_dormant() and fixture.stomach_a.is_functional(), "Empty sleeping stomach retains function")
	_feed(fixture.stomach_a, 10)
	_feed(fixture.stomach_b, 10)
	_check(not fixture.stomach_a.is_dormant(), "Delivery wakes stomach immediately")
	_complete_digest(fixture.stomach_a)
	_complete_digest(fixture.stomach_b)
	var product_a: String = fixture.stomach_a.get_output_products()[0]["product_id"]
	var product_b: String = fixture.stomach_b.get_output_products()[0]["product_id"]
	_check(product_a != product_b and fixture.stomach_a.is_dormant() and fixture.stomach_b.is_dormant(),
		"Sources produce globally distinct output identities while returning to idle sleep")
	_check(fixture.returns.get_return_snapshot()["queued_nutrition"] == 20
		and fixture.returns.get_return_snapshot()["source_count"] == 2, "Return snapshot aggregates both independent stomachs")
	fixture.network.unregister_edge(fixture.edge_a)
	_check(fixture.returns.try_dispatch(), "Disconnected source cannot block another stomach's green return")
	var records: Array[Dictionary] = fixture.returns.get_shipment_records()
	if not records.is_empty():
		var record: Dictionary = records.back()
		_check(record["source_id"] == fixture.stomach_b.get_instance_id() and record["product_id"] == product_b,
			"Green return captures its own valid source")
		fixture.returns.unregister_digestive(fixture.stomach_a)
		var packet: NutrientPacket = record["packet"] as NutrientPacket
		packet.set_physics_process(false)
		packet._physics_process(10.0)
		packet.arrived.emit(packet)
		_check(fixture.core.nutrition == 82 and fixture.core.has_received_product(product_b)
			and fixture.stomach_b.get_output_count() == 0 and fixture.stomach_a.get_output_nutrition() == 10,
			"Unregistering other source preserves fixed return and one core receipt")
	fixture.network.register_edge(fixture.edge_a)
	fixture.returns.register_digestive(fixture.stomach_a)
	_check(fixture.returns.try_dispatch(), "Reconnected sleeping source still sends its preserved product")
	var retry: Array[Dictionary] = fixture.returns.get_shipment_records()
	if not retry.is_empty():
		var packet: NutrientPacket = retry.back()["packet"] as NutrientPacket
		packet.set_physics_process(false)
		packet._physics_process(10.0)
	_check(fixture.core.nutrition == 92 and fixture.returns.delivered_nutrition == 20,
		"Multiple source receipts conserve the original twenty nutrition")
	for index: int in range(3):
		_feed(fixture.stomach_a, 10)
		_complete_digest(fixture.stomach_a)
	_feed(fixture.stomach_b, 10)
	_complete_digest(fixture.stomach_b)
	_check(fixture.stomach_a.get_output_count() == 2 and fixture.stomach_a.get_output_nutrition() == 20
		and fixture.stomach_a.get_queued_nutrition() == 10 and not fixture.stomach_a.is_dormant(),
		"Each stomach enforces two outputs and twenty nutrition without sleeping blocked input")
	_check(fixture.stomach_b.get_output_nutrition() == 10 and fixture.stomach_b.is_dormant(),
		"One full stomach cannot consume another source's real output capacity")
	_check(fixture.returns.try_dispatch(), "Dormancy never blocks preserved green output")
	await _dispose(fixture)


func _test_ground_decay_and_atomic_claim() -> void:
	var fixture: Fixture = _new_fixture()
	var remains: EnemyRemains = _new_remains(fixture, 7)
	remains.advance_decay(54.0)
	_check(remains.try_claim(), "Ground corpse is claimable before decay deadline")
	remains.advance_decay(999.0)
	_check(_near(float(remains.get_decay_snapshot()["elapsed_seconds"]), 54.0)
		and fixture.decay_losses.is_empty(), "Claimed corpse cannot decay in transport or processing")
	remains.release_claim(Vector2(18.0, 9.0))
	_check(_near(float(remains.get_decay_snapshot()["remaining_seconds"]), 1.0),
		"Interrupted same corpse keeps one second of ground lifetime")
	var reentrant_claim: Array[bool] = [true]
	remains.decayed.connect(func(_amount: int) -> void:
		reentrant_claim[0] = remains.try_claim()
		remains.advance_decay(55.0)
	)
	remains.advance_decay(0.99)
	_check(fixture.decay_losses.is_empty() and remains.is_available(), "Partial remaining ground lifetime keeps nutrition")
	remains.advance_decay(0.02)
	_check(remains.is_decayed() and remains.nutrition_value == 0 and fixture.decay_losses == [7]
		and not reentrant_claim[0] and not remains.try_claim(), "Expiry commits the sole loss before same-frame and reentrant claim")
	var claimed_first: EnemyRemains = _new_remains(fixture, 6)
	claimed_first.advance_decay(54.99)
	_check(claimed_first.try_claim(), "Claim atomically wins when submitted before expiry")
	claimed_first.advance_decay(1.0)
	_check(not claimed_first.is_decayed() and fixture.decay_losses == [7], "Claim winner keeps nutrition past nominal ground deadline")
	await _dispose(fixture)
	_check(fixture.decay_losses == [7], "Scene cleanup never creates a second natural loss")


func _test_source_loss_during_core_receipt() -> void:
	var fixture: Fixture = _new_fixture(true)
	_feed(fixture.stomach_a, 10)
	_complete_digest(fixture.stomach_a)
	_check(fixture.returns.try_dispatch(), "Receipt race starts a real green return")
	var losses: Array[Dictionary] = []
	fixture.core.digestion_product_arrived.connect(func(_product_id: String, _nutrition: int) -> void:
		fixture.stomach_a.take_damage(999.0)
		fixture.returns.unregister_digestive(fixture.stomach_a)
		losses.append(fixture.stomach_a.clear_destroyed_inventory())
	)
	var records: Array[Dictionary] = fixture.returns.get_shipment_records()
	if not records.is_empty():
		var packet: NutrientPacket = records.back()["packet"] as NutrientPacket
		packet.set_physics_process(false)
		packet._physics_process(10.0)
	_check(fixture.core.nutrition == 82 and losses.size() == 1
		and losses[0]["output_nutrition"] == 0 and fixture.returns.delivered_nutrition == 10,
		"Source death inside core receipt cannot lose the same already accepted product twice")
	_check(fixture.stomach_b.is_functional() and fixture.returns.get_digestive_organs().has(fixture.stomach_b),
		"Synchronous source death preserves other stomach registrations")
	await _dispose(fixture)


func _test_cut_batch_decay_and_teardown() -> void:
	var fixture: Fixture = _new_fixture(true)
	var source: LargeCarcass = LargeCarcass.new()
	source.total_nutrition = 40
	fixture.ground.add_child(source)
	_check(not source.has_method("advance_decay") and fixture.recycling.try_dispatch(),
		"Large body does not decay and starts one finite harvest batch")
	var records: Array[Dictionary] = fixture.recycling.get_shipment_records()
	if not records.is_empty():
		var record: Dictionary = records[0]
		var batch: EnemyRemains = record["remains"] as EnemyRemains
		batch.set_physics_process(false)
		batch.decayed.connect(func(amount: int) -> void: fixture.decay_losses.append(amount))
		var packet: RemainsPacket = record["packet"] as RemainsPacket
		packet.set_physics_process(false)
		packet.cancel_transport()
		_check(batch.is_available() and source.get_remaining_nutrition() == 30
			and source.get_harvested_nutrition() == 10, "Cancelled finite batch remains independent ground nutrition")
		batch.advance_decay(55.0)
		_check(batch.is_decayed() and fixture.decay_losses == [10]
			and source.get_remaining_nutrition() == 30 and source.get_harvested_nutrition() == 10,
			"Ground batch decay loses ten once and never replenishes original large source")
	var unexpired: EnemyRemains = _new_remains(fixture, 9)
	unexpired.advance_decay(20.0)
	unexpired.queue_free()
	await process_frame
	_check(fixture.decay_losses == [10], "Freeing an unexpired scene corpse emits no decay loss")
	await _dispose(fixture)
