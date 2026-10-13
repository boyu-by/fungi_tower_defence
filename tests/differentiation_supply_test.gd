extends SceneTree
## 真实分化系统、付款、营养包、交通和主脉；单位 fixture 显式解锁能力，手动推进。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const PIERCING: int = 1
const SCATTER: int = 2

class Fixture:
	extends RefCounted

	var world: Node2D
	var source: MotherCore
	var extra_sources: Array[MotherCore] = []
	var middle: HyphaNode
	var host: HyphaNode
	var other_host: HyphaNode
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var tracker: CargoPassageTracker
	var veins: MainVeinSystem
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var differentiation: DifferentiationSystem
	var supply: DifferentiationSupplySystem
	var combat: SupplySystem
	var organ: AttackOrgan
	var weapon: SporeWeapon
	var others: Array[AttackOrgan] = []
	var edges: Array[HyphaEdge] = []
	var packets: Node2D
	var scheduler: ConstructionSupplyScheduler
	var cultivation: CultivationSystem
	var cultivation_supply: CultivationSupplySystem
	var task_id: int = 0
	var initial_total: int = 0
	var recovery_events: int = 0
	var completions: int = 0
	var last_supply_snapshot: Dictionary = {}
	var confirmations: Array[Dictionary] = []

class Trigger:
	extends RefCounted

	var fired: bool = false

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	await _test_real_paid_material_and_completion()
	await _test_pause_and_existing_ordinary_arrival()
	await _test_original_sources_fifo_and_continuation()
	await _test_repair_and_combat_budget()
	await _test_traffic_queue_block_and_reroute()
	await _test_host_and_source_removal()
	await _test_reset_and_reentry_callbacks()
	await _test_shared_scheduler_and_dispatch_ownership()
	await _test_consumption_notification_reentry()
	_check(root.get_child_count() == initial_children, "Differentiation supply fixtures leave no root children")
	print("DIFFERENTIATION_SUPPLY_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
		"capability_setup": "unit-only explicit maturity receipt; no end-to-end recovery claim",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _container(parent: Node) -> Node2D:
	var node: Node2D = Node2D.new()
	parent.add_child(node)
	return node


func _node(fixture: Fixture, point: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	node.position = point
	fixture.world.add_child(node)
	_check(fixture.network.register_node(node), "Unit fixture physical junction registers")
	return node


func _edge(fixture: Fixture, first: Node2D, last: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = last
	fixture.world.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Unit fixture physical edge registers")
	_check(fixture.veins.register_edge(edge), "Unit fixture main vein observes the real edge")
	fixture.edges.append(edge)
	return edge


func _organ(fixture: Fixture, host: HyphaNode, stock: int) -> Dictionary:
	var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
	organ.initial_nutrition = stock
	host.add_child(organ)
	var weapon: SporeWeapon = WEAPON_SCENE.instantiate() as SporeWeapon
	(weapon.get_node("FireTimer") as Timer).autostart = false
	weapon.inventory_owner = organ
	host.add_child(weapon)
	weapon.set_process(false)
	weapon.set_physics_process(false)
	(weapon.get_node("FireTimer") as Timer).stop()
	_check(fixture.combat.register_organ(organ), "Mature scene organ registers with ordinary combat supply")
	return {"organ": organ, "weapon": weapon}


func _new_fixture(balance: int = 64, stock: int = 0, other_stock: int = -1) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = _container(root)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.tracker = CargoPassageTracker.new()
	fixture.world.add_child(fixture.tracker)
	fixture.veins = MainVeinSystem.new()
	fixture.veins.cargo_passage_tracker = fixture.tracker
	fixture.world.add_child(fixture.veins)
	fixture.tracker.passage_confirmed.connect(func(cargo_id: String, edge: HyphaEdge, generation: int) -> void:
		fixture.confirmations.append({"cargo_id": cargo_id, "edge_id": edge.get_instance_id(),
			"generation": generation})
	)
	fixture.source = CORE_SCENE.instantiate() as MotherCore
	fixture.source.initial_nutrition = balance
	fixture.world.add_child(fixture.source)
	_check(fixture.network.register_node(fixture.source, true), "Original mother core registers")
	fixture.source.digestion_product_arrived.connect(func(_product_id: String, _nutrition: int) -> void:
		fixture.recovery_events += 1
	)
	fixture.middle = _node(fixture, Vector2(80.0, 0.0))
	fixture.host = _node(fixture, Vector2(160.0, 0.0))
	_edge(fixture, fixture.source, fixture.middle)
	# 第二段反向存储端点，分化外送必须实际走过反向路段。
	_edge(fixture, fixture.host, fixture.middle)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.packets = _container(fixture.world)
	fixture.packets.child_entered_tree.connect(func(child: Node) -> void:
		if child is NutrientPacket:
			child.set_physics_process(false)
			child.set("speed", 80.0)
	)
	fixture.combat = SupplySystem.new()
	fixture.combat.mother_core = fixture.source
	fixture.combat.network_system = fixture.network
	fixture.combat.traffic_system = fixture.traffic
	fixture.combat.traffic_required = true
	fixture.combat.cargo_passage_tracker = fixture.tracker
	fixture.combat.packet_container = fixture.packets
	fixture.combat.packet_scene = PACKET_SCENE
	fixture.world.add_child(fixture.combat)
	fixture.combat.set_process(false)
	var pair: Dictionary = _organ(fixture, fixture.host, stock)
	fixture.organ = pair["organ"] as AttackOrgan
	fixture.weapon = pair["weapon"] as SporeWeapon
	if other_stock >= 0:
		fixture.other_host = _node(fixture, Vector2(160.0, 80.0))
		_edge(fixture, fixture.middle, fixture.other_host)
		var other: Dictionary = _organ(fixture, fixture.other_host, other_stock)
		fixture.others.append(other["organ"] as AttackOrgan)
	fixture.progress = ColonyProgress.new()
	fixture.world.add_child(fixture.progress)
	fixture.capabilities = ColonyCapabilities.new()
	fixture.capabilities.colony_progress = fixture.progress
	fixture.world.add_child(fixture.capabilities)
	# 仅为单位测试解除成熟能力门槛，不增加母核余额或模拟真实回收。
	_check(fixture.progress.record_arrival("unit-maturity", 160), "UNIT setup explicitly unlocks mature capability")
	fixture.differentiation = DifferentiationSystem.new()
	fixture.differentiation.network_system = fixture.network
	fixture.differentiation.colony_capabilities = fixture.capabilities
	fixture.world.add_child(fixture.differentiation)
	fixture.differentiation.set_physics_process(false)
	fixture.differentiation.task_completed.connect(func(_task_id: int) -> void:
		fixture.completions += 1
	)
	fixture.supply = DifferentiationSupplySystem.new()
	fixture.supply.differentiation_system = fixture.differentiation
	fixture.supply.mother_core = fixture.source
	fixture.supply.network_system = fixture.network
	fixture.supply.traffic_system = fixture.traffic
	fixture.supply.traffic_required = true
	fixture.supply.combat_supply_system = fixture.combat
	fixture.supply.cargo_passage_tracker = fixture.tracker
	fixture.supply.packet_container = fixture.packets
	fixture.supply.auto_supply = false
	fixture.supply.supply_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.last_supply_snapshot = snapshot.duplicate()
	)
	fixture.world.add_child(fixture.supply)
	fixture.supply.set_process(false)
	fixture.initial_total = balance + stock + maxi(other_stock, 0)
	return fixture


func _start(fixture: Fixture, direction: int = PIERCING) -> int:
	var availability: StringName = fixture.differentiation.get_availability(fixture.organ, direction)
	fixture.task_id = fixture.differentiation.start_differentiation(fixture.organ, direction)
	_check(fixture.task_id > 0, "Real differentiation starts on a mature connected scene organ (availability=%s)" % availability)
	return fixture.task_id


func _snapshot(fixture: Fixture) -> Dictionary:
	return fixture.differentiation.get_task_snapshot(fixture.task_id)


func _add_source(fixture: Fixture, balance: int) -> MotherCore:
	var source: MotherCore = CORE_SCENE.instantiate() as MotherCore
	source.initial_nutrition = balance
	source.position = Vector2(0.0, 80.0)
	fixture.world.add_child(source)
	_check(fixture.network.register_node(source), "Replacement source registers without replacing captured payer")
	_edge(fixture, source, fixture.middle)
	fixture.extra_sources.append(source)
	fixture.initial_total += balance
	source.digestion_product_arrived.connect(func(_product_id: String, _nutrition: int) -> void:
		fixture.recovery_events += 1
	)
	return source


func _active_packets(fixture: Fixture) -> Array[NutrientPacket]:
	var packets: Array[NutrientPacket] = []
	for record: Dictionary in fixture.supply.get_shipment_records():
		var packet: Variant = record.get("packet")
		if not bool(record.get("settled", false)) and is_instance_valid(packet):
			packets.append(packet as NutrientPacket)
	return packets


func _launch(fixture: Fixture) -> NutrientPacket:
	var old_records: int = fixture.supply.get_shipment_records().size()
	var dispatched: bool = fixture.supply.try_dispatch()
	_check(dispatched, "Differentiation pays for one real material packet")
	if not dispatched:
		return null
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	if records.size() <= old_records:
		return null
	var record: Dictionary = records.back()
	var packet: NutrientPacket = record["packet"] as NutrientPacket
	_check(bool(record.get("debited", false)) and bool(record.get("started", false)),
		"Shipment is paid and started before exposure")
	if is_instance_valid(packet):
		var transport: Dictionary = packet.get_transport_snapshot()
		_check(transport.get("cargo_kind") == &"supply" and bool(transport.get("traffic_required", false))
			and bool(transport.get("traffic_enabled", false)), "Material uses the supported real supply cargo and shared traffic")
		_check(String(transport.get("task_id", "")).begins_with("differentiation:"),
			"Transport ID includes its distinct differentiation namespace")
	return packet


func _tick(fixture: Fixture, packet: NutrientPacket, delta: float = 0.25) -> void:
	fixture.traffic.refresh()
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet._physics_process(delta)
	fixture.supply._process(0.0)


func _finish(fixture: Fixture, packet: NutrientPacket) -> bool:
	if not is_instance_valid(packet):
		_check(false, "Expected a real nutrient packet to finish")
		return false
	for _attempt: int in range(160):
		if bool(packet.get_transport_snapshot().get("terminal", false)):
			break
		_tick(fixture, packet)
	var completed: bool = packet.get_transport_snapshot().get("state", &"") == &"completed"
	_check(completed, "Real packet reaches the captured host through complete segments")
	return completed


func _deliver(fixture: Fixture, count: int) -> Array[String]:
	var ids: Array[String] = []
	for _index: int in range(count):
		var packet: NutrientPacket = _launch(fixture)
		if is_instance_valid(packet):
			ids.append(String(packet.get_transport_snapshot().get("cargo_id", "")))
			_finish(fixture, packet)
	return ids


func _count(fixture: Fixture, edge: HyphaEdge) -> int:
	return int(fixture.veins.get_edge_snapshot(edge).get("confirmed_passages", 0))


func _assert_cargo(fixture: Fixture, cargo_id: String, status: StringName, candidate_count: int = -1) -> void:
	var snapshot: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
	_check(snapshot.get("kind") == &"differentiation" and snapshot.get("status") == status,
		"Differentiation cargo has the expected consumed or refundable status: " + cargo_id)
	if candidate_count >= 0:
		_check(int(snapshot.get("candidate_count", -1)) == candidate_count,
			"Cargo candidates reflect only actual complete route sections")


func _conservation(fixture: Fixture, context: String) -> void:
	var accounted: int = fixture.source.nutrition
	for source: MotherCore in fixture.extra_sources:
		if is_instance_valid(source):
			accounted += source.nutrition
	var resources: Dictionary = fixture.differentiation.get_resource_snapshot()
	accounted += int(resources.get("consumed_nutrition", 0)) + int(resources.get("buffered_nutrition", 0))
	accounted += fixture.supply.get_in_transit_nutrition()
	if is_instance_valid(fixture.organ):
		accounted += fixture.organ.nutrition + fixture.organ.incoming_nutrition
	for organ: AttackOrgan in fixture.others:
		if is_instance_valid(organ):
			accounted += organ.nutrition + organ.incoming_nutrition
	_check(accounted == fixture.initial_total, context + ": original currency, cache, paid transit, sunk material and ammo conserve")
	_check(fixture.recovery_events == 0 and fixture.progress.get_total_recovered() == 160,
		context + ": material refunds never publish recovered digestion receipts")


func _dispose(fixture: Fixture) -> void:
	if is_instance_valid(fixture.differentiation):
		fixture.differentiation.stop()
	if is_instance_valid(fixture.supply):
		fixture.supply.reset(true)
	if is_instance_valid(fixture.cultivation_supply):
		fixture.cultivation_supply.reset()
	if is_instance_valid(fixture.cultivation):
		fixture.cultivation.reset()
	if is_instance_valid(fixture.scheduler):
		fixture.scheduler.reset()
	fixture.combat.reset(true)
	fixture.traffic.reset()
	fixture.veins.stop()
	if is_instance_valid(fixture.source) and fixture.source.get_parent() == null:
		fixture.source.queue_free()
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _test_real_paid_material_and_completion() -> void:
	var fixture: Fixture = _new_fixture(64, 3, 0)
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	fixture.differentiation.advance(20.0)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0
		and is_zero_approx(float(_snapshot(fixture).get("effective_time", -1.0))),
		"A stocked weapon cannot spend its ammunition as differentiation material")
	var ids: Array[String] = _deliver(fixture, 8)
	_check(ids.size() == 8 and fixture.source.nutrition == 56
		and fixture.supply.get_in_transit_count() == 0 and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 8,
		"Exactly eight one-unit paid packets arrive as separate refundable material")
	_check(not fixture.supply.try_dispatch(), "Buffered and paid material reserve the total demand without overdispatch")
	_check(fixture.organ.nutrition == 3 and _count(fixture, fixture.edges[0]) == 0
		and _count(fixture, fixture.edges[1]) == 0, "Refundable delivery changes neither ammo nor main-vein history")
	for cargo_id: String in ids:
		_assert_cargo(fixture, cargo_id, &"pending", 2)
	fixture.differentiation.advance(4.9)
	_check(fixture.completions == 0 and fixture.differentiation.has_active_task(),
		"Paying all material cannot complete before five effective seconds")
	fixture.differentiation.advance(0.11)
	_check(fixture.completions == 1 and _snapshot(fixture).get("state") == &"completed"
		and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 8
		and is_equal_approx(float(_snapshot(fixture).get("effective_time", -1.0)), 5.0),
		"Eight real paid steps complete once after five effective seconds")
	_check(_count(fixture, fixture.edges[0]) == 8 and _count(fixture, fixture.edges[1]) == 8,
		"Every irreversible one-unit step confirms its two actual route sections exactly once")
	for cargo_id: String in ids:
		_assert_cargo(fixture, cargo_id, &"confirmed", 2)
	fixture.differentiation.advance(100.0)
	fixture.supply._process(0.0)
	_check(fixture.completions == 1 and fixture.source.nutrition == 56 and fixture.organ.nutrition == 3,
		"Repeated terminal updates preserve sunk material and existing ammunition")
	var other_task: int = fixture.differentiation.start_differentiation(fixture.others[0], SCATTER)
	_check(other_task > fixture.task_id, "A second ordinary organ can differentiate after the first completes")
	var expected_reserve: int = maxi(0, 2 * fixture.organ.get_shot_nutrition_cost()
		- fixture.organ.nutrition - fixture.organ.incoming_nutrition)
	_check(fixture.supply.get_combat_reserve() == expected_reserve,
		"Other completed weapons reserve their actual current shot cost")
	_conservation(fixture, "Completed material and second-organ work gate")
	evidence.append({"case": "paid_completion", "paid_material": 8, "effective_time": 5.0,
		"confirmations_per_edge": _count(fixture, fixture.edges[0]), "ammo": fixture.organ.nutrition})
	await _dispose(fixture)


func _test_pause_and_existing_ordinary_arrival() -> void:
	var fixture: Fixture = _new_fixture()
	var ordinary_paid: bool = fixture.combat.request_supply(fixture.organ)
	_check(ordinary_paid, "Ordinary payment precedes differentiation")
	if not ordinary_paid:
		await _dispose(fixture)
		return
	_check(fixture.packets.get_child_count() > 0, "The successful ordinary payment creates its real packet")
	if fixture.packets.get_child_count() <= 0:
		await _dispose(fixture)
		return
	var ordinary: NutrientPacket = fixture.packets.get_child(0) as NutrientPacket
	_check(is_instance_valid(ordinary), "The ordinary arrival fixture uses a real NutrientPacket")
	if not is_instance_valid(ordinary) or _start(fixture) <= 0:
		await _dispose(fixture)
		return
	_check(not fixture.combat.get_active_organs().has(fixture.organ)
		and not fixture.combat.request_supply(fixture.organ), "Differentiating organ rejects every new ordinary supply")
	var material: NutrientPacket = _launch(fixture)
	if not is_instance_valid(material):
		await _dispose(fixture)
		return
	_check(fixture.differentiation.pause_task(), "Differentiation pauses while two legitimate packets are already paid")
	_check(fixture.differentiation.get_requested_nutrition(fixture.task_id) == 0
		and not fixture.supply.try_dispatch() and not fixture.combat.request_supply(fixture.organ),
		"Paused work has zero new material demand and keeps the ordinary work gate closed")
	_finish(fixture, ordinary)
	_finish(fixture, material)
	_check(fixture.organ.nutrition == 1 and fixture.organ.incoming_nutrition == 0
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 1,
		"Old ordinary arrival and paid paused material reach their distinct inventories")
	fixture.differentiation.advance(10.0)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0
		and is_zero_approx(float(_snapshot(fixture).get("effective_time", -1.0))), "Pause spends no material and accrues no effective time")
	_check(fixture.differentiation.resume_task(), "Paused real task resumes")
	fixture.differentiation.advance(0.125)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 1 and fixture.organ.nutrition == 1,
		"Resumed step consumes material while preserving legitimate arrived ammunition")
	_check(fixture.differentiation.cancel_task(), "Partially elapsed paid step cancels")
	_check(fixture.combat.get_active_organs().has(fixture.organ) and fixture.combat.request_supply(fixture.organ),
		"Cancellation restores ordinary work without refunding its paid partial step")
	_conservation(fixture, "Paused paid arrivals and restored ordinary supply")
	evidence.append({"case": "paused_arrival", "ordinary_stock": fixture.organ.nutrition,
		"sunk_material": int(fixture.differentiation.get_resource_snapshot().get("consumed_nutrition", 0))})
	await _dispose(fixture)


func _test_original_sources_fifo_and_continuation() -> void:
	var fixture: Fixture = _new_fixture(40)
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	var first_task: int = fixture.task_id
	var first: NutrientPacket = _launch(fixture)
	if not is_instance_valid(first):
		await _dispose(fixture)
		return
	var first_id: String = String(first.get_transport_snapshot().get("cargo_id", ""))
	var second_source: MotherCore = _add_source(fixture, 40)
	var second_source_edge: HyphaEdge = fixture.edges.back()
	fixture.supply.mother_core = second_source
	var second: NutrientPacket = _launch(fixture)
	if not is_instance_valid(second):
		await _dispose(fixture)
		return
	var second_id: String = String(second.get_transport_snapshot().get("cargo_id", ""))
	# 反向交付：FIFO 按真实接收顺序，不能按派发或当前导出来源推断。
	_finish(fixture, second)
	_finish(fixture, first)
	fixture.differentiation.advance(0.125)
	_assert_cargo(fixture, second_id, &"confirmed", 2)
	_assert_cargo(fixture, first_id, &"pending", 2)
	_check(_count(fixture, second_source_edge) == 1 and _count(fixture, fixture.edges[0]) == 0,
		"The first accepted source lot alone earns irreversible passage credit")
	_check(fixture.differentiation.cancel_task(), "Mixed-source task cancels with one unspent lot")
	_check(fixture.source.nutrition == 40 and second_source.nutrition == 39,
		"Unspent FIFO remainder returns to its original payer after source replacement")
	_assert_cargo(fixture, first_id, &"discarded", 0)
	var frozen: Dictionary = fixture.differentiation.get_task_snapshot(first_task).duplicate(true)
	fixture.task_id = fixture.differentiation.continue_differentiation(fixture.organ)
	_check(fixture.task_id > first_task and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 1,
		"Continue allocates a new identity and retains its already-paid cumulative step")
	fixture.supply.mother_core = fixture.source
	var continued_ids: Array[String] = _deliver(fixture, 3)
	fixture.differentiation.advance(0.125)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 1,
		"Continuing the paid partial step never consumes a fresh material lot")
	for cargo_id: String in continued_ids:
		_assert_cargo(fixture, cargo_id, &"pending", 2)
	_check(int(fixture.differentiation.get_resource_snapshot().get("consumed_nutrition", -1)) == 1,
		"Resource aggregation counts the persistent organism once across historical tasks")
	fixture.differentiation.advance(0.5)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 2,
		"Only a newly paid next step advances the new account beyond its baseline")
	if not continued_ids.is_empty():
		_assert_cargo(fixture, continued_ids[0], &"confirmed", 2)
	fixture.differentiation.cancel_task()
	_check(fixture.source.nutrition == 39 and second_source.nutrition == 39,
		"Continuing refunds only two fresh unspent lots and never refunds either sunk step")
	_check(fixture.differentiation.get_task_snapshot(first_task) == frozen,
		"Continuation cannot rewrite the cancelled historical attempt snapshot")
	fixture.supply._process(0.0)
	fixture.differentiation.take_unspent_nutrition(first_task)
	_check(fixture.source.nutrition == 39 and second_source.nutrition == 39,
		"Terminal replay and repeated cache extraction cannot duplicate refunds")
	_check(_count(fixture, fixture.edges[1]) == 2, "Main vein counts two newly consumed lots across the two attempts")
	_conservation(fixture, "Original FIFO sources and continued consumption baseline")
	evidence.append({"case": "original_sources_and_continue", "first_source": fixture.source.nutrition,
		"second_source": second_source.nutrition, "cumulative_consumed": 2, "old_task_id": first_task,
		"new_task_id": fixture.task_id})
	await _dispose(fixture)


func _test_repair_and_combat_budget() -> void:
	var fixture: Fixture = _new_fixture(6, 0, 0)
	_check(fixture.source.set_nutrition_reservation("unit-repair", 3) == 3,
		"UNIT setup reserves a real repair budget in the source ledger")
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	var other: AttackOrgan = fixture.others[0]
	_check(fixture.supply.get_combat_reserve() == 2 * other.get_shot_nutrition_cost()
		and fixture.supply.get_available_differentiation_nutrition() == 1,
		"Repair reservation wins first, then other active organs reserve two real shots")
	_launch(fixture)
	_check(not fixture.supply.try_dispatch() and fixture.source.get_nutrition_reservation("unit-repair") == 3,
		"Material cannot borrow the protected repair or combat reserve")
	_check(fixture.combat.request_supply(other) and fixture.combat.request_supply(other),
		"Other active weapon may use its retained reserve for legitimate paid supplies")
	_check(other.incoming_nutrition == 2 and fixture.supply.get_combat_reserve() == 0,
		"Already paid ordinary incoming units cover the exact two-shot reserve")
	_check(fixture.supply.get_available_differentiation_nutrition() == 0 and not fixture.supply.try_dispatch(),
		"Paid ordinary reserve is not subtracted from the source a second time")
	fixture.source.add_nutrition(1)
	fixture.initial_total += 1
	_launch(fixture)
	_check(fixture.source.nutrition == 3 and fixture.source.get_spendable_nutrition() == 0
		and fixture.source.get_nutrition_reservation("unit-repair") == 3,
		"One extra unit funds exactly one extra material packet above the untouched repair lock")
	var packets: Array[NutrientPacket] = []
	for child: Node in fixture.packets.get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			packets.append(child as NutrientPacket)
	for packet: NutrientPacket in packets:
		_finish(fixture, packet)
	_check(other.nutrition == 2 and fixture.organ.nutrition == 0
		and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 2,
		"Material and ordinary ammo stay in separate inventories under the shared budget")
	fixture.differentiation.cancel_task()
	_check(fixture.source.nutrition == 5 and fixture.source.get_nutrition_reservation("unit-repair") == 3,
		"Cancellation refunds only the two material packets and retains repair priority")
	_conservation(fixture, "Repair-first and paid incoming combat reserve")
	evidence.append({"case": "repair_and_combat_budget", "repair_reserved": 3,
		"combat_stock": other.nutrition, "refunded_material": int(fixture.supply.get_supply_snapshot().get("refunded", 0))})
	await _dispose(fixture)


func _test_traffic_queue_block_and_reroute() -> void:
	var fixture: Fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	var ingress: HyphaEdge = fixture.edges[0]
	var old_last: HyphaEdge = fixture.edges[1]
	ingress.traffic_capacity = 1
	var blocker: Node = Node.new()
	fixture.world.add_child(blocker)
	var request: Dictionary = fixture.traffic.request_passage("unit-blocker", blocker, "unit-blocker-task",
		ingress, fixture.source, fixture.middle, &"supply")
	_check(request.get("state") == &"granted", "UNIT blocker acquires the single real ingress lease")
	var packet: NutrientPacket = _launch(fixture)
	if not is_instance_valid(packet):
		await _dispose(fixture)
		return
	var cargo_id: String = String(packet.get_transport_snapshot().get("cargo_id", ""))
	_tick(fixture, packet)
	_check(packet.get_transport_snapshot().get("state") == &"waiting"
		and fixture.supply.get_in_transit_nutrition() == 1 and fixture.source.nutrition == 63,
		"Queueing retains the same paid material without delivery or refund")
	_assert_cargo(fixture, cargo_id, &"pending", 0)
	fixture.traffic.release(String(request.get("token", "")))
	_tick(fixture, packet)
	ingress.entry_enabled = false
	var frozen_position: Vector2 = packet.global_position
	_tick(fixture, packet)
	_check(packet.get_transport_snapshot().get("state") == &"blocked" and packet.global_position == frozen_position
		and fixture.supply.get_in_transit_nutrition() == 1,
		"Closing an occupied edge freezes the paid packet and preserves its lease")
	_assert_cargo(fixture, cargo_id, &"pending", 0)
	old_last.entry_enabled = false
	ingress.entry_enabled = true
	_tick(fixture, packet, 1.0)
	_check(packet.get_transport_snapshot().get("location_kind") == &"node"
		and packet.get_transport_snapshot().get("current_node") == fixture.middle,
		"Disconnected remaining plan waits at the actual completed middle junction")
	_assert_cargo(fixture, cargo_id, &"pending", 1)
	var bypass: HyphaNode = _node(fixture, Vector2(80.0, 80.0))
	var detour_first: HyphaEdge = _edge(fixture, fixture.middle, bypass)
	var detour_last: HyphaEdge = _edge(fixture, fixture.host, bypass)
	_finish(fixture, packet)
	_check(int(packet.get_transport_snapshot().get("reroute_count", 0)) > 0
		and String(packet.get_transport_snapshot().get("cargo_id", "")) == cargo_id,
		"Actual reroute preserves the captured payer, task, host and cargo identity")
	_assert_cargo(fixture, cargo_id, &"pending", 3)
	_check(_count(fixture, ingress) == 0 and _count(fixture, old_last) == 0,
		"Queued, blocked, rerouted and cached material still earns no confirmation")
	# 到货缓存已归接收方；真实断路暂停推进，但单纯容量占用不能停止本地已付款步骤。
	detour_last.entry_enabled = false
	fixture.differentiation.advance(1.0)
	var disconnected: Dictionary = _snapshot(fixture)
	_check(not bool(disconnected.get("can_progress", true))
		and int(disconnected.get("buffered_nutrition", -1)) == 1
		and int(disconnected.get("consumed_nutrition", -1)) == 0
		and is_zero_approx(float(disconnected.get("effective_time", -1.0))),
		"A real cut after delivery preserves refundable cache and freezes effective work")
	_assert_cargo(fixture, cargo_id, &"pending", 3)
	detour_last.entry_enabled = true
	detour_last.traffic_capacity = 1
	var congestion: Dictionary = fixture.traffic.request_passage("unit-cache-congestion", blocker,
		"unit-cache-congestion-task", detour_last, bypass, fixture.host, &"supply")
	_check(congestion.get("state") == &"granted", "UNIT congestion occupies the restored real final route")
	fixture.differentiation.advance(0.125)
	_check(int(_snapshot(fixture).get("consumed_nutrition", -1)) == 1
		and is_equal_approx(float(_snapshot(fixture).get("effective_time", -1.0)), 0.125),
		"Capacity congestion alone cannot stop work on already arrived local material")
	fixture.traffic.release(String(congestion.get("token", "")))
	_assert_cargo(fixture, cargo_id, &"confirmed", 3)
	_check(_count(fixture, ingress) == 1 and _count(fixture, old_last) == 0
		and _count(fixture, detour_first) == 1 and _count(fixture, detour_last) == 1,
		"Consumed rerouted cargo credits exactly its actual completed edge union")
	_conservation(fixture, "Shared queue, occupied-edge block, route loss and real reroute")
	evidence.append({"case": "queue_block_reroute", "cargo_id": cargo_id,
		"actual_candidates": 3, "old_untraversed_edge": _count(fixture, old_last)})
	await _dispose(fixture)


func _test_host_and_source_removal() -> void:
	var fixture: Fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	_deliver(fixture, 1)
	_launch(fixture)
	_launch(fixture)
	fixture.host.queue_free()
	fixture.supply._process(0.0)
	_check(fixture.source.nutrition == 64 and fixture.supply.get_in_transit_count() == 0
		and not fixture.differentiation.has_active_task(), "Host deletion refunds cached and paid transit material once")
	fixture.supply.reset(true)
	_check(fixture.source.nutrition == 64 and fixture.source.get_received_product_count() == 0,
		"Reset after host deletion cannot duplicate refunds or publish recovered receipts")
	await _dispose(fixture)

	fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	_deliver(fixture, 1)
	_launch(fixture)
	var replacement: MotherCore = _add_source(fixture, 32)
	fixture.supply.mother_core = replacement
	fixture.world.remove_child(fixture.source)
	_check(fixture.source.nutrition == 64 and replacement.nutrition == 32
		and fixture.supply.get_in_transit_count() == 0 and not fixture.differentiation.has_active_task(),
		"Original source tree exit refunds its own cache and transit after export replacement")
	fixture.supply._process(0.0)
	_check(fixture.source.nutrition == 64 and replacement.nutrition == 32,
		"Source exit replay never credits the current replacement payer")
	_conservation(fixture, "Captured original source removal")
	await _dispose(fixture)


func _test_reset_and_reentry_callbacks() -> void:
	var fixture: Fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	var old_task_id: int = fixture.task_id
	var packet: NutrientPacket = _launch(fixture)
	if not is_instance_valid(packet):
		await _dispose(fixture)
		return
	var old_record: Dictionary = fixture.supply.get_shipment_records().back()
	var old_id: String = String(old_record.get("shipment_id", ""))
	fixture.differentiation.stop()
	fixture.supply.reset(true)
	fixture.supply.auto_supply = true
	fixture.supply._on_packet_arrived(packet, old_id)
	fixture.supply._on_packet_interrupted(packet, old_id)
	fixture.supply._on_packet_tree_exiting(old_id)
	fixture.supply._process(100.0)
	_check(fixture.source.nutrition == 64 and fixture.supply.get_in_transit_count() == 0
		and not fixture.supply.try_dispatch(), "Stopped reset and every stale packet signal reject new or duplicate settlement")
	fixture.differentiation.reset()
	fixture.supply.reset(false)
	fixture.supply.auto_supply = false
	_check(fixture.differentiation.get_availability(fixture.organ, PIERCING) == &"continuable",
		"Same-scene reset retains the chosen direction even before the first paid step")
	fixture.task_id = fixture.differentiation.continue_differentiation(fixture.organ)
	_check(fixture.task_id > old_task_id and int(_snapshot(fixture).get("consumed_nutrition", -1)) == 0,
		"Reentry continues retained direction with a new monotonic task ID and zero-consumption baseline")
	if fixture.task_id <= old_task_id:
		await _dispose(fixture)
		return
	var fresh: NutrientPacket = _launch(fixture)
	if not is_instance_valid(fresh):
		await _dispose(fixture)
		return
	var fresh_record: Dictionary = fixture.supply.get_shipment_records().back()
	_check(String(fresh_record.get("shipment_id", "")) != old_id,
		"Explicit reentry keeps shipment serials unique across reset")
	fixture.supply._on_packet_arrived(packet, old_id)
	_check(fixture.source.nutrition == 63 and fixture.supply.get_in_transit_count() == 1,
		"Old callback cannot reach a new attempt in the same supply instance")
	# arrived.emit 自身不能伪造真实到货。
	fresh.arrived.emit(fresh)
	_check(fixture.supply.get_in_transit_count() == 1 and int(_snapshot(fixture).get("buffered_nutrition", -1)) == 0,
		"Public arrival replay cannot accept material before the actual terminal host handoff")
	_finish(fixture, fresh)
	_conservation(fixture, "Stopped reset and explicit same-instance reentry")
	await _dispose(fixture)

	fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	var debit_reset: Trigger = Trigger.new()
	fixture.source.nutrition_changed.connect(func(current: int) -> void:
		if not debit_reset.fired and current == 63:
			debit_reset.fired = true
			fixture.differentiation.stop()
			fixture.supply.reset(true)
	)
	_check(not fixture.supply.try_dispatch() and debit_reset.fired and fixture.source.nutrition == 64
		and fixture.supply.get_in_transit_count() == 0,
		"Reset reentered from the real debit callback returns its registered original payment exactly once")
	await _dispose(fixture)

	fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	packet = _launch(fixture)
	if not is_instance_valid(packet):
		await _dispose(fixture)
		return
	var arrival_reset: Trigger = Trigger.new()
	fixture.differentiation.task_changed.connect(func(snapshot: Dictionary) -> void:
		if not arrival_reset.fired and int(snapshot.get("buffered_nutrition", 0)) > 0:
			arrival_reset.fired = true
			fixture.differentiation.stop()
			fixture.supply.reset(true)
	)
	_finish(fixture, packet)
	_check(arrival_reset.fired and fixture.source.nutrition == 64 and fixture.supply.get_in_transit_count() == 0,
		"Reset inside real receive notification finds the pre-registered accepted source lot")
	await _dispose(fixture)


func _test_shared_scheduler_and_dispatch_ownership() -> void:
	var fixture: Fixture = _new_fixture(1)
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	fixture.scheduler = ConstructionSupplyScheduler.new()
	fixture.scheduler.auto_dispatch = false
	fixture.world.add_child(fixture.scheduler)
	fixture.scheduler.set_process(false)
	var empty_host: HyphaNode = _node(fixture, Vector2(160.0, -80.0))
	_edge(fixture, fixture.middle, empty_host)
	fixture.cultivation = CultivationSystem.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.enemy_container = _container(fixture.world)
	fixture.cultivation.projectile_container = _container(fixture.world)
	fixture.world.add_child(fixture.cultivation)
	fixture.cultivation.set_physics_process(false)
	var cultivation_task: int = fixture.cultivation.start_cultivation(empty_host)
	_check(cultivation_task > 0, "Real cultivation starts independently of differentiation")
	if cultivation_task <= 0:
		await _dispose(fixture)
		return
	fixture.cultivation_supply = CultivationSupplySystem.new()
	fixture.cultivation_supply.cultivation_system = fixture.cultivation
	fixture.cultivation_supply.mother_core = fixture.source
	fixture.cultivation_supply.network_system = fixture.network
	fixture.cultivation_supply.traffic_system = fixture.traffic
	fixture.cultivation_supply.traffic_required = true
	fixture.cultivation_supply.combat_supply_system = fixture.combat
	fixture.cultivation_supply.packet_container = fixture.packets
	fixture.cultivation_supply.auto_supply = false
	fixture.world.add_child(fixture.cultivation_supply)
	fixture.cultivation_supply.set_process(false)
	_check(fixture.scheduler.register_supply("unit-construction", fixture.cultivation_supply)
		and fixture.scheduler.register_differentiation_supply(fixture.supply),
		"Real construction and material supply share one original dispatch owner")
	var group_id: String = "differentiation:%d" % fixture.supply.get_instance_id()
	fixture.scheduler.set_order(["unit-construction"])
	_check(fixture.scheduler.get_snapshot().get("construction_ids", []).has(group_id)
		and int(fixture.scheduler.get_snapshot().get("group_count", 0)) == 2,
		"Construction set_order retains the independent stable differentiation group")
	_check(fixture.scheduler.register_differentiation_supply(fixture.supply)
		and int(fixture.scheduler.get_snapshot().get("registered_count", 0)) == 2,
		"Duplicate differentiation registration stays idempotent")
	var foreign: Node = Node.new()
	fixture.world.add_child(foreign)
	fixture.supply.auto_supply = true
	_check(not fixture.supply.try_dispatch() and not fixture.supply.claim_dispatch_owner(foreign)
		and not fixture.supply.can_dispatch_scheduled(foreign) and not fixture.supply.try_dispatch_scheduled(foreign),
		"Managed material rejects direct, auto and foreign-owner dispatch paths")
	fixture.supply.release_dispatch_owner(foreign)
	fixture.supply._process(100.0)
	_check(fixture.source.nutrition == 1 and fixture.supply.get_dispatch_owner() == fixture.scheduler,
		"External auto toggle and foreign release cannot create a second supply driver")
	fixture.source.nutrition_changed.connect(func(balance: int) -> void:
		if balance == 0:
			_check(fixture.scheduler.dispatch_round() == 0, "Debit callbacks cannot recursively start another scheduler round")
	)
	for round_index: int in range(6):
		if round_index > 0:
			fixture.source.add_nutrition(1)
		_check(fixture.scheduler.dispatch_round() == 1 and fixture.source.nutrition == 0,
			"Each scarce shared unit pays exactly one real group in its scheduler round")
	_check(fixture.supply.get_in_transit_nutrition() == 3
		and fixture.cultivation_supply.get_in_transit_nutrition() == 3,
		"Construction and differentiation rotate fairly under six scarce shared units")
	fixture.source.add_nutrition(1)
	fixture.edges[1].entry_enabled = false
	_check(not fixture.supply.can_dispatch_scheduled(fixture.scheduler)
		and fixture.scheduler.dispatch_round() == 1 and fixture.supply.get_in_transit_nutrition() == 3,
		"A blocked differentiation route cannot steal the other construction group's payable turn")
	fixture.edges[1].entry_enabled = true
	var paid_before_reset: int = fixture.supply.get_in_transit_nutrition()
	fixture.scheduler.reset()
	_check(fixture.supply.get_dispatch_owner() == null and fixture.supply.get_in_transit_nutrition() == paid_before_reset,
		"Scheduler reset releases ownership while preserving all legitimate paid transports")
	_check(fixture.scheduler.register_differentiation_supply(fixture.supply),
		"Active supply can re-register its same stable group after scheduler reset")
	fixture.differentiation.cancel_task()
	fixture.scheduler.unregister_supply(fixture.supply)
	_check(fixture.supply.get_dispatch_owner() == null and int(fixture.scheduler.get_snapshot().get("registered_count", -1)) == 0,
		"Generic terminal unregistration removes the independent differentiation supply")
	_check(fixture.progress.get_total_recovered() == 160 and fixture.recovery_events == 0,
		"Shared scheduler never treats material refunds as recovery")
	evidence.append({"case": "shared_scheduling", "construction_paid_before_cancel": 4,
		"differentiation_paid_before_cancel": paid_before_reset, "stable_group": group_id})
	await _dispose(fixture)


func _test_consumption_notification_reentry() -> void:
	var fixture: Fixture = _new_fixture()
	if _start(fixture) <= 0:
		await _dispose(fixture)
		return
	_deliver(fixture, 4)
	var triggered: Trigger = Trigger.new()
	fixture.tracker.passage_confirmed.connect(func(_cargo_id: String, _edge: HyphaEdge, _generation: int) -> void:
		if not triggered.fired:
			triggered.fired = true
			var consumed: int = int(_snapshot(fixture).get("consumed_nutrition", 0))
			var refundable: int = 0
			var committed: int = 0
			for record: Dictionary in fixture.supply.get_shipment_records():
				refundable += int(record.get("buffered_nutrition", 0))
				if bool(record.get("consumed", false)):
					committed += 1
			_check(refundable == 4 - consumed and committed == consumed,
				"All FIFO deductions finish before the first public main-vein consumption notification")
			fixture.differentiation.cancel_task()
	)
	fixture.differentiation.advance(1.3)
	var consumed: int = int(fixture.differentiation.get_resource_snapshot().get("consumed_nutrition", 0))
	_check(triggered.fired and fixture.source.nutrition == 64 - consumed
		and int(fixture.differentiation.get_resource_snapshot().get("buffered_nutrition", -1)) == 0,
		"Cancellation reentered from public confirmation refunds only the fully deducted FIFO remainder")
	fixture.supply._process(0.0)
	_check(_count(fixture, fixture.edges[0]) == consumed and _count(fixture, fixture.edges[1]) == consumed,
		"Reentrant cancellation confirms exactly the actually sunk prefix and never the refundable remainder")
	_conservation(fixture, "Consumption confirmation reentry")
	evidence.append({"case": "consumption_notification_reentry", "consumed": consumed,
		"refunded": int(fixture.supply.get_supply_snapshot().get("refunded", 0))})
	await _dispose(fixture)
