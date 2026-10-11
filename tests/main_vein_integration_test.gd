extends SceneTree
## 主脉只观察真实业务提交；包运动、付款、缓存、消耗及重试均使用生产系统。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const STOMACH_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const REMAINS_PACKET_SCENE: PackedScene = preload("res://scenes/recycling/remains_packet.tscn")
const KINDS: Array[StringName] = [&"supply", &"growth", &"cultivation", &"repair", &"remains", &"return"]
const REFUNDABLE_KINDS: Array[StringName] = [&"growth", &"cultivation", &"repair"]
const STEP: float = 0.05
const STEP_LIMIT: int = 400
const DIGEST_FRAME_LIMIT: int = 180

class Fixture:
	extends RefCounted

	var world: Node2D
	var nodes: Node2D
	var edges: Node2D
	var tips: Node2D
	var packets: Node2D
	var remains: Node2D
	var core: MotherCore
	var middle: HyphaNode
	var host: HyphaNode
	var attack_host: HyphaNode
	var stomach_host: HyphaNode
	var bypass: HyphaNode
	var attack: AttackOrgan
	var stomach: DigestiveOrgan
	var carcass: LargeCarcass
	var original_remains: EnemyRemains
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var field: FungalField
	var tracker: CargoPassageTracker
	var veins: MainVeinSystem
	var combat: SupplySystem
	var growth: GrowthSystem
	var growth_supply: GrowthSupplySystem
	var cultivation: CultivationSystem
	var cultivation_supply: CultivationSupplySystem
	var repair: RepairSystem
	var repair_supply: RepairSupplySystem
	var recycling: RecyclingSystem
	var returns: NutritionReturnSystem
	var trunk: Array[HyphaEdge] = []
	var detour: Array[HyphaEdge] = []
	var attack_edge: HyphaEdge
	var stomach_edge: HyphaEdge
	var all_edges: Array[HyphaEdge] = []
	var initial_total: int = 0
	var shot_consumption: int = 0
	var task_id: int = 0
	var matured: Array[AttackOrgan] = []
	var produced_ids: Array[String] = []
	var received_ids: Array[String] = []
	var notifications: Array[Dictionary] = []

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	for kind: StringName in KINDS:
		await _test_queued_and_partial_cancellation(kind)
	for kind: StringName in REFUNDABLE_KINDS:
		await _test_cache_refund_cannot_farm(kind)
	await _test_growth_fifo_and_paid_junction()
	await _test_consumption_fifo(&"cultivation")
	await _test_consumption_fifo(&"repair")
	await _test_startup_reservation_and_commit()
	await _test_materialization_rollback()
	for batch: bool in [false, true]:
		await _test_remains_identity_retry(batch)
	await _test_return_product_retry()
	for kind: StringName in [&"supply", &"growth", &"cultivation", &"return"]:
		await _test_reverse_reroute_identity(kind)
	await _test_eighty_nutrition_is_sixteen_cargos()
	await _test_upgrade_keeps_live_repair_credit()
	await _test_capacity_upgrade_keeps_real_fifo()
	for kind: StringName in KINDS:
		await _test_restart_rejects_old_callbacks(kind)
	await _test_reset_inside_real_return_receipt()
	await _test_stop_retains_grade_and_rejects_old_completion()
	_check(root.get_child_count() == initial_children, "Integration fixtures leave no root children")
	print("MAIN_VEIN_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"runtime": "EXECUTED", "status": "PASS" if failures.is_empty() else "FAIL",
		"checks": checks, "conservation_checks": conservation_checks, "failures": failures,
		"evidence": evidence, "business_entrypoints": KINDS,
		"motion": "production_packet_physics", "first_settlements": "real_business_commits",
		"direct_tracker_candidate_or_confirmation_calls": false,
		"default_prices_and_packet_units": true, "step_limit": STEP_LIMIT,
		"digest_frame_limit": DIGEST_FRAME_LIMIT,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _container(parent: Node, node_name: String) -> Node2D:
	var container: Node2D = Node2D.new()
	container.name = node_name
	parent.add_child(container)
	return container


func _node(fixture: Fixture, point: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.nodes.add_child(node)
	node.global_position = point
	_check(fixture.network.register_node(node), "Physical junction registers")
	return node


func _edge(fixture: Fixture, first: Node2D, second: Node2D, enabled: bool = true) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	edge.entry_enabled = enabled
	fixture.edges.add_child(edge)
	edge.set_process(false)
	_check(edge.traffic_capacity == 2 and is_equal_approx(edge.max_health, 35.0)
		and fixture.network.register_edge(edge) and fixture.veins.register_edge(edge),
		"Physical edge starts at the original capacity and maximum health")
	fixture.all_edges.append(edge)
	return edge


func _new_fixture(balance: int = 128) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = _container(root, "MainVeinBusinessFixture")
	fixture.nodes = _container(fixture.world, "Nodes")
	fixture.edges = _container(fixture.world, "Edges")
	fixture.tips = _container(fixture.world, "Tips")
	fixture.packets = _container(fixture.world, "Packets")
	fixture.remains = _container(fixture.world, "Remains")
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.tracker = CargoPassageTracker.new()
	fixture.world.add_child(fixture.tracker)
	fixture.veins = MainVeinSystem.new()
	fixture.veins.cargo_passage_tracker = fixture.tracker
	fixture.world.add_child(fixture.veins)
	fixture.veins.configure_tracker(fixture.tracker)
	fixture.tracker.passage_confirmed.connect(func(cargo_id: String, edge: HyphaEdge, generation: int) -> void:
		fixture.notifications.append({"cargo_id": cargo_id, "edge_id": edge.get_instance_id(), "generation": generation})
	)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = balance
	fixture.nodes.add_child(fixture.core)
	_check(fixture.network.register_node(fixture.core, true), "Original mother core registers")
	fixture.middle = _node(fixture, Vector2(80, 0))
	fixture.host = _node(fixture, Vector2(160, 0))
	fixture.attack_host = _node(fixture, Vector2(240, -40))
	fixture.stomach_host = _node(fixture, Vector2(240, 40))
	fixture.bypass = _node(fixture, Vector2(0, 100))
	fixture.trunk.append(_edge(fixture, fixture.core, fixture.middle))
	# 端点反向存储；所有外送业务真实经过反向段，回流则沿相反方向。
	fixture.trunk.append(_edge(fixture, fixture.host, fixture.middle))
	fixture.attack_edge = _edge(fixture, fixture.host, fixture.attack_host)
	fixture.stomach_edge = _edge(fixture, fixture.host, fixture.stomach_host)
	fixture.detour.append(_edge(fixture, fixture.core, fixture.bypass, false))
	fixture.detour.append(_edge(fixture, fixture.bypass, fixture.host, false))
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.field = FungalField.new()
	fixture.world.add_child(fixture.field)
	fixture.field.set_process(false)
	fixture.field.set_sources([
		{"node": fixture.core, "kind": &"core", "connected": true},
		{"node": fixture.middle, "kind": &"junction", "connected": true},
		{"node": fixture.host, "kind": &"junction", "connected": true},
	])
	fixture.field.advance(1.0)
	fixture.attack = ORGAN_SCENE.instantiate() as AttackOrgan
	fixture.attack.initial_nutrition = 0
	fixture.attack_host.add_child(fixture.attack)
	fixture.stomach = STOMACH_SCENE.instantiate() as DigestiveOrgan
	fixture.stomach.mother_core = fixture.core
	fixture.stomach_host.add_child(fixture.stomach)
	fixture.stomach.set_process(false)
	fixture.stomach.digest_timer.stop()
	fixture.combat = SupplySystem.new()
	fixture.combat.mother_core = fixture.core
	fixture.combat.network_system = fixture.network
	fixture.combat.traffic_system = fixture.traffic
	fixture.combat.traffic_required = true
	fixture.combat.cargo_passage_tracker = fixture.tracker
	fixture.combat.packet_container = fixture.packets
	fixture.combat.packet_scene = PACKET_SCENE
	fixture.world.add_child(fixture.combat)
	_check(fixture.combat.register_organ(fixture.attack), "Ordinary receiver registers with its default capacity")
	fixture.growth = GrowthSystem.new()
	fixture.growth.network_system = fixture.network
	fixture.growth.traffic_system = fixture.traffic
	fixture.growth.node_container = fixture.nodes
	fixture.growth.edge_container = fixture.edges
	fixture.growth.tip_container = fixture.tips
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_physics_process(false)
	fixture.growth_supply = GrowthSupplySystem.new()
	fixture.growth_supply.growth_system = fixture.growth
	fixture.growth_supply.mother_core = fixture.core
	fixture.growth_supply.network_system = fixture.network
	fixture.growth_supply.traffic_system = fixture.traffic
	fixture.growth_supply.traffic_required = true
	fixture.growth_supply.cargo_passage_tracker = fixture.tracker
	fixture.growth_supply.packet_container = fixture.packets
	fixture.growth_supply.auto_supply = false
	fixture.world.add_child(fixture.growth_supply)
	fixture.growth_supply.set_process(false)
	fixture.cultivation = CultivationSystem.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.growth_system = fixture.growth
	fixture.cultivation.enemy_container = _container(fixture.world, "Enemies")
	fixture.cultivation.projectile_container = _container(fixture.world, "Projectiles")
	fixture.world.add_child(fixture.cultivation)
	fixture.cultivation.set_physics_process(false)
	fixture.cultivation.organ_matured.connect(func(_task_id: int, _host: HyphaNode, organ: AttackOrgan, _weapon: SporeWeapon) -> void:
		fixture.matured.append(organ)
	)
	fixture.cultivation_supply = CultivationSupplySystem.new()
	fixture.cultivation_supply.cultivation_system = fixture.cultivation
	fixture.cultivation_supply.mother_core = fixture.core
	fixture.cultivation_supply.network_system = fixture.network
	fixture.cultivation_supply.traffic_system = fixture.traffic
	fixture.cultivation_supply.traffic_required = true
	fixture.cultivation_supply.cargo_passage_tracker = fixture.tracker
	fixture.cultivation_supply.packet_container = fixture.packets
	fixture.cultivation_supply.auto_supply = false
	fixture.world.add_child(fixture.cultivation_supply)
	fixture.cultivation_supply.set_process(false)
	fixture.repair = RepairSystem.new()
	fixture.repair.network_system = fixture.network
	fixture.world.add_child(fixture.repair)
	fixture.repair.set_physics_process(false)
	fixture.repair_supply = RepairSupplySystem.new()
	fixture.repair_supply.repair_system = fixture.repair
	fixture.repair_supply.mother_core = fixture.core
	fixture.repair_supply.network_system = fixture.network
	fixture.repair_supply.traffic_system = fixture.traffic
	fixture.repair_supply.traffic_required = true
	fixture.repair_supply.cargo_passage_tracker = fixture.tracker
	fixture.repair_supply.packet_container = fixture.packets
	fixture.repair_supply.auto_supply = false
	fixture.world.add_child(fixture.repair_supply)
	fixture.repair_supply.set_process(false)
	fixture.recycling = RecyclingSystem.new()
	fixture.recycling.network_system = fixture.network
	fixture.recycling.traffic_system = fixture.traffic
	fixture.recycling.traffic_required = true
	fixture.recycling.cargo_passage_tracker = fixture.tracker
	fixture.recycling.fungal_field = fixture.field
	fixture.recycling.digestive_organ = fixture.stomach
	fixture.recycling.remains_container = fixture.remains
	fixture.recycling.packet_container = fixture.packets
	fixture.recycling.packet_scene = REMAINS_PACKET_SCENE
	fixture.world.add_child(fixture.recycling)
	fixture.returns = NutritionReturnSystem.new()
	fixture.returns.digestive_organ = fixture.stomach
	fixture.returns.mother_core = fixture.core
	fixture.returns.network_system = fixture.network
	fixture.returns.traffic_system = fixture.traffic
	fixture.returns.traffic_required = true
	fixture.returns.cargo_passage_tracker = fixture.tracker
	fixture.returns.packet_container = fixture.packets
	fixture.returns.auto_return = false
	fixture.world.add_child(fixture.returns)
	fixture.returns.get_node("DispatchTimer").call("stop")
	fixture.packets.child_entered_tree.connect(func(child: Node) -> void:
		child.set_physics_process(false)
		child.set("speed", 80.0)
	)
	fixture.stomach.product_created.connect(func(product_id: String, _nutrition: int) -> void:
		fixture.produced_ids.append(product_id)
	)
	fixture.core.digestion_product_arrived.connect(func(product_id: String, _nutrition: int) -> void:
		fixture.received_ids.append(product_id)
	)
	fixture.initial_total = balance
	return fixture


func _add_carcass(fixture: Fixture) -> void:
	fixture.carcass = CARCASS_SCENE.instantiate() as LargeCarcass
	fixture.remains.add_child(fixture.carcass)
	fixture.carcass.global_position = Vector2(-40, 0)
	fixture.initial_total += fixture.carcass.get_remaining_nutrition()
	_check(fixture.carcass.get_remaining_nutrition() == 80, "Real carcass starts with the default eighty nutrition")


func _add_original_remains(fixture: Fixture) -> void:
	fixture.original_remains = REMAINS_SCENE.instantiate() as EnemyRemains
	fixture.remains.add_child(fixture.original_remains)
	fixture.original_remains.global_position = Vector2(-40, 0)
	fixture.initial_total += fixture.original_remains.nutrition_value


func _service(fixture: Fixture, kind: StringName) -> Node:
	match kind:
		&"supply": return fixture.combat
		&"growth": return fixture.growth_supply
		&"cultivation": return fixture.cultivation_supply
		&"repair": return fixture.repair_supply
		&"remains": return fixture.recycling
		&"return": return fixture.returns
	return null


func _transport(packet: Node2D) -> Dictionary:
	return packet.call("get_transport_snapshot") as Dictionary


func _cargo_id(packet: Node2D) -> String:
	return String(_transport(packet).get("cargo_id", ""))


func _launch(fixture: Fixture, kind: StringName) -> Node2D:
	var before: Array[Node] = fixture.packets.get_children()
	var dispatched: bool = fixture.combat.request_supply(fixture.attack) if kind == &"supply" \
		else bool(_service(fixture, kind).call("try_dispatch"))
	_check(dispatched, String(kind) + " dispatches through its actual business controller")
	var packet: Node2D = null
	for child: Node in fixture.packets.get_children():
		if child is Node2D and not before.has(child) and not child.is_queued_for_deletion():
			packet = child as Node2D
	_check(packet != null, String(kind) + " creates a real paid or claimed packet")
	if packet != null:
		var snapshot: Dictionary = _transport(packet)
		var cargo_id: String = String(snapshot.get("cargo_id", ""))
		_check(bool(snapshot.get("started", false)) and not cargo_id.is_empty()
			and int(snapshot.get("cargo_generation", -1)) == fixture.tracker.get_generation(),
			String(kind) + " captures its stable cargo and tracking generation before movement")
		var cargo: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
		_check(cargo.get("kind") == kind and cargo.get("status") == &"pending",
			String(kind) + " registers the correct pending business identity")
		if kind in [&"supply", &"growth", &"cultivation", &"repair"]:
			_check(cargo_id == "supply:" + String(snapshot.get("task_id", "")),
				String(kind) + " uses the original unique payment transport identity")
	return packet


func _prepare(fixture: Fixture, kind: StringName, continuation: bool = false) -> void:
	match kind:
		&"growth":
			fixture.task_id = fixture.growth.create_target(fixture.host, fixture.host.global_position + Vector2(180, 0))
			_check(fixture.task_id > 0, "Growth creates an unpaid target with default costs")
		&"cultivation":
			fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host) if continuation \
				else fixture.cultivation.start_cultivation(fixture.host)
			_check(fixture.task_id > 0, "Cultivation owns an unpaid real organ bud")
		&"repair":
			if is_equal_approx(fixture.trunk[1].health, fixture.trunk[1].max_health):
				fixture.trunk[1].take_damage(25.0)
			fixture.task_id = fixture.repair.request_repair(fixture.trunk[1])
			_check(fixture.task_id > 0, "Repair admits one actual damaged edge")
		&"remains":
			if not is_instance_valid(fixture.carcass) and not is_instance_valid(fixture.original_remains):
				_add_carcass(fixture)
		&"return":
			_add_carcass(fixture)
			var input: Node2D = _launch(fixture, &"remains")
			_finish(fixture, input)
			_check(fixture.stomach.get_queued_nutrition() == 10, "Return input arrives through actual corpse transport")
			await _digest_one(fixture)


func _refresh(fixture: Fixture) -> void:
	fixture.traffic.refresh()
	fixture.growth_supply.call("_process", 0.0)
	fixture.cultivation_supply.call("_process", 0.0)
	fixture.repair_supply.refresh_budget()
	fixture.returns.call("_on_dispatch_timer_timeout")


func _tick(fixture: Fixture, packet: Node2D) -> void:
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet.call("_physics_process", STEP)
	_refresh(fixture)


func _until(fixture: Fixture, packet: Node2D, condition: Callable, context: String) -> bool:
	for _step: int in range(STEP_LIMIT):
		if bool(condition.call()) or not is_instance_valid(packet) or packet.is_queued_for_deletion():
			break
		_tick(fixture, packet)
	var reached: bool = bool(condition.call())
	_check(reached, context + " within bounded production physics steps")
	return reached


func _finish(fixture: Fixture, packet: Node2D) -> bool:
	if packet == null:
		return false
	return _until(fixture, packet, func() -> bool:
		return (is_instance_valid(packet) and _transport(packet).get("state") == &"completed"),
		"Real packet reaches its committed destination")


func _reach_edge(fixture: Fixture, packet: Node2D, edge: HyphaEdge) -> bool:
	if packet == null:
		return false
	return _until(fixture, packet, func() -> bool:
		var snapshot: Dictionary = _transport(packet)
		return (snapshot.get("edge") == edge and snapshot.get("location_kind") == &"edge"
			and float(snapshot.get("progress", 0.0)) > 0.2),
		"Real packet occupies the chosen nonzero edge")


func _digest_one(fixture: Fixture) -> void:
	var before: int = fixture.stomach.digested_count
	# 沿用默认 1.5 秒及已经绑定真实任务身份的 Timer，首笔产物不由测试伪造。
	_check(is_equal_approx(fixture.stomach.digest_timer.wait_time, 1.5), "Digestion retains the production default duration")
	fixture.stomach.digest_timer.start()
	for _frame: int in range(DIGEST_FRAME_LIMIT):
		await physics_frame
		await process_frame
		if fixture.stomach.digested_count > before:
			break
	fixture.stomach.digest_timer.stop()
	_check(fixture.stomach.digested_count == before + 1 and fixture.stomach.get_output_count() > 0,
		"Real digestive Timer creates exactly one uniquely identified product")
	_conservation(fixture, "real digestion")


func _edge_counts(fixture: Fixture) -> Array[int]:
	var result: Array[int] = []
	for edge: HyphaEdge in fixture.all_edges:
		var snapshot: Dictionary = fixture.veins.get_edge_snapshot(edge)
		result.append(int(snapshot.get("confirmed_passages", 0)))
	return result


func _count(fixture: Fixture, edge: HyphaEdge) -> int:
	return int(fixture.veins.get_edge_snapshot(edge).get("confirmed_passages", 0))


func _assert_cargo(fixture: Fixture, cargo_id: String, status: StringName,
		expected_edges: Array[HyphaEdge] = []) -> void:
	var snapshot: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
	_check(not snapshot.is_empty() and snapshot.get("status") == status,
		cargo_id + " has the expected business settlement status " + String(status))
	if status == &"confirmed":
		_check(int(snapshot.get("confirmed_count", -1)) == expected_edges.size(),
			cargo_id + " counts distinct traversed edges without an amount or units multiplier")
		for edge: HyphaEdge in expected_edges:
			_check(fixture.tracker.has_confirmed_passage(cargo_id, edge, fixture.tracker.get_generation()),
				cargo_id + " confirms its actual completed edge")
	elif status == &"discarded":
		_check(int(snapshot.get("candidate_count", -1)) == 0 and int(snapshot.get("confirmed_count", -1)) == 0,
			cargo_id + " cannot retain refundable history after cancellation")
	elif status == &"pending":
		_check(int(snapshot.get("confirmed_count", -1)) == 0,
			cargo_id + " cannot publish an effective passage before its business commits")


func _callbacks(packet: Node2D, owner: Node) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for signal_name: StringName in [&"arrived", &"interrupted"]:
		for connection: Dictionary in packet.get_signal_connection_list(signal_name):
			var callback: Callable = connection["callable"]
			if callback.get_object() == owner:
				callbacks.append(callback)
	_check(not callbacks.is_empty(), "Capture actual business callbacks before terminal transport")
	return callbacks


func _replay(callbacks: Array[Callable], packet: Node2D) -> void:
	for callback: Callable in callbacks:
		callback.call(packet)
	packet.emit_signal("arrived", packet)


func _conservation(fixture: Fixture, context: String) -> void:
	conservation_checks += 1
	var growth: Dictionary = fixture.growth.get_task_snapshot()
	var cultivation: Dictionary = fixture.cultivation.get_resource_snapshot()
	var repair: Dictionary = fixture.repair.get_task_snapshot()
	var amount: int = fixture.core.nutrition + fixture.attack.nutrition + fixture.shot_consumption \
		+ fixture.combat.get_in_transit_count() + fixture.growth_supply.get_in_transit_count() \
		+ fixture.cultivation_supply.get_in_transit_nutrition() + fixture.repair_supply.get_in_transit_nutrition() \
		+ int(growth.get("consumed_nutrition", 0)) + int(growth.get("buffered_nutrition", 0)) \
		+ int(cultivation.get("structure_consumed", 0)) + int(cultivation.get("buffered_nutrition", 0)) \
		+ int(cultivation.get("startup_reserved", 0)) \
		+ int(repair.get("consumed_nutrition", 0)) + int(repair.get("buffered_nutrition", 0)) \
		+ fixture.stomach.get_queued_nutrition() + fixture.stomach.get_output_nutrition()
	if is_instance_valid(fixture.carcass):
		amount += fixture.carcass.get_remaining_nutrition()
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and not child.is_queued_for_deletion():
			amount += (child as EnemyRemains).nutrition_value
	for organ: AttackOrgan in fixture.matured:
		if is_instance_valid(organ) and not organ.is_queued_for_deletion():
			amount += organ.nutrition
	_check(amount == fixture.initial_total, context + " conserves original capital, paid lots, corpse stock and products")
	_check(fixture.stomach.get_queued_count() + fixture.stomach.incoming_remains <= fixture.stomach.capacity
		and fixture.stomach.get_output_count() <= 2 and fixture.stomach.get_output_nutrition() <= 20,
		context + " respects the original digestive inventory and output limits")
	for edge: HyphaEdge in fixture.network.get_registered_edges():
		_check(int(fixture.traffic.get_edge_snapshot(edge).get("occupied_units", 0)) <= edge.traffic_capacity,
			context + " respects the live physical edge capacity")


func _cancel_business(fixture: Fixture, kind: StringName) -> void:
	match kind:
		&"growth": fixture.growth.cancel_task()
		&"cultivation": fixture.cultivation.cancel_task()
		&"repair": fixture.repair.cancel_task()
		&"supply": fixture.combat.reset(true)
		&"remains": fixture.recycling.reset(true)
		&"return": fixture.returns.reset()
	_refresh(fixture)


func _consume_once(fixture: Fixture, kind: StringName) -> void:
	match kind:
		&"growth": fixture.growth.advance(0.001)
		&"cultivation": fixture.cultivation.advance(0.05)
		&"repair": fixture.repair.advance(0.1)
	_refresh(fixture)


func _reset_businesses(fixture: Fixture, stop_dispatch: bool = false) -> void:
	fixture.combat.reset(stop_dispatch)
	fixture.growth_supply.reset()
	fixture.cultivation_supply.reset()
	fixture.repair_supply.reset(stop_dispatch)
	fixture.recycling.reset(stop_dispatch)
	fixture.returns.reset()
	fixture.traffic.reset()


func _dispose(fixture: Fixture) -> void:
	fixture.veins.stop()
	fixture.tracker.reset()
	_reset_businesses(fixture, true)
	fixture.world.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.world), "Business fixture teardown completes")


func _test_queued_and_partial_cancellation(kind: StringName) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var bottleneck: HyphaEdge = fixture.trunk[1] if kind == &"return" else fixture.trunk[0]
	var first: Node2D = _launch(fixture, &"supply")
	var second: Node2D = _launch(fixture, &"supply")
	if not _reach_edge(fixture, first, bottleneck) or not _reach_edge(fixture, second, bottleneck):
		await _dispose(fixture)
		return
	var before: Array[int] = _edge_counts(fixture)
	var balance: int = fixture.core.nutrition
	var packet: Node2D = _launch(fixture, kind)
	if packet == null:
		await _dispose(fixture)
		return
	var cargo_id: String = _cargo_id(packet)
	var callbacks: Array[Callable] = _callbacks(packet, _service(fixture, kind))
	_until(fixture, packet, func() -> bool: return _transport(packet).get("state") == &"waiting",
		String(kind) + " actually queues behind two paid one-unit occupants")
	var queued_candidates: int = int(fixture.tracker.get_cargo_snapshot(cargo_id).get("candidate_count", -1))
	for _wait_step: int in range(5):
		_tick(fixture, packet)
	# 早到通知只走 arrived；interrupted 是真实取消入口，留到终态后才重放。
	packet.emit_signal("arrived", packet)
	_check(_edge_counts(fixture) == before and int(fixture.tracker.get_cargo_snapshot(cargo_id).get("candidate_count", -2)) == queued_candidates,
		String(kind) + " waiting and premature callbacks cannot create a passage or settle stock")
	_conservation(fixture, String(kind) + " queued")
	first.call("cancel_transport")
	if kind == &"remains":
		_tick(fixture, packet)
		_check(_transport(packet).get("state") == &"waiting", "Two-unit corpse cannot enter a one-unit vacancy")
	second.call("cancel_transport")
	if _reach_edge(fixture, packet, bottleneck):
		_check(_edge_counts(fixture) == before and int(fixture.tracker.get_cargo_snapshot(cargo_id).get("candidate_count", -1)) == queued_candidates,
			String(kind) + " partial nonzero traversal still cannot create the unfinished-edge candidate")
		packet.call("cancel_transport")
		_refresh(fixture)
		var after_cancel: Array[int] = _edge_counts(fixture)
		_replay(callbacks, packet)
		_check(after_cancel == before and _edge_counts(fixture) == before,
			String(kind) + " half-cancellation and old callbacks never grow an edge")
		var refunded: bool = kind in [&"supply", &"growth", &"cultivation", &"repair"]
		_assert_cargo(fixture, cargo_id, &"discarded" if refunded else &"pending")
		_check(fixture.core.nutrition == balance + 2,
			String(kind) + " cancellation refunds only the two blockers and this cargo's genuine payment")
	_conservation(fixture, String(kind) + " half cancelled")
	evidence.append({"case": "queued_and_half_cancel", "kind": kind,
		"queued_candidates": queued_candidates, "edge_counts_before": before, "edge_counts_after": _edge_counts(fixture)})
	await _dispose(fixture)


func _test_cache_refund_cannot_farm(kind: StringName) -> void:
	var fixture: Fixture = _new_fixture()
	var previous_cargo: String = ""
	for cycle: int in range(2):
		await _prepare(fixture, kind, cycle > 0 and kind == &"cultivation")
		var before: Array[int] = _edge_counts(fixture)
		var packet: Node2D = _launch(fixture, kind)
		if packet == null:
			break
		var cargo_id: String = _cargo_id(packet)
		_check(cargo_id != previous_cargo, "A refunded " + String(kind) + " payment is never reused")
		previous_cargo = cargo_id
		var callbacks: Array[Callable] = _callbacks(packet, _service(fixture, kind))
		_finish(fixture, packet)
		var cargo: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
		_check(cargo.get("status") == &"pending" and int(cargo.get("candidate_count", 0)) > 0
			and _edge_counts(fixture) == before, String(kind) + " full delivery is a refundable cache, without growth")
		_conservation(fixture, String(kind) + " refundable arrival")
		_cancel_business(fixture, kind)
		_assert_cargo(fixture, cargo_id, &"discarded")
		_replay(callbacks, packet)
		_check(fixture.core.nutrition == fixture.initial_total and _edge_counts(fixture) == before
			and fixture.core.get_received_product_count() == 0,
			String(kind) + " cancelled cache refunds once and cannot farm growth or digestion income")
		_conservation(fixture, String(kind) + " refunded cache")
	evidence.append({"case": "full_route_refundable_cache", "kind": kind, "cycles": 2,
		"edge_counts": _edge_counts(fixture), "final_balance": fixture.core.nutrition})
	await _dispose(fixture)


func _confirmation_order(fixture: Fixture, ids: Array[String], edge: HyphaEdge) -> Array[String]:
	var order: Array[String] = []
	for row: Dictionary in fixture.notifications:
		if int(row["edge_id"]) == edge.get_instance_id() and ids.has(String(row["cargo_id"])):
			order.append(String(row["cargo_id"]))
	return order


func _test_growth_fifo_and_paid_junction() -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, &"growth")
	_check(fixture.growth.get_requested_nutrition(fixture.task_id) == 2,
		"Default first 120-pixel extension costs two nutrition")
	var first: Node2D = _launch(fixture, &"growth")
	var second: Node2D = _launch(fixture, &"growth")
	if first == null or second == null:
		await _dispose(fixture)
		return
	var ids: Array[String] = [_cargo_id(second), _cargo_id(first)]
	_finish(fixture, second)
	_finish(fixture, first)
	_check(_count(fixture, fixture.trunk[0]) == 0, "Both growth arrivals remain refundable before the extension investment")
	fixture.tracker.passage_confirmed.connect(func(cargo_id: String, edge: HyphaEdge, _generation: int) -> void:
		if ids.has(cargo_id) and edge == fixture.trunk[0]:
			for record: Dictionary in fixture.growth_supply.get_shipment_records():
				_check(int(record.get("buffered_nutrition", -1)) == 0,
					"FIFO observers see the entire two-unit investment retired before the first confirmation")
	)
	fixture.growth.advance(0.001)
	_refresh(fixture)
	_check(int(fixture.growth.get_task_snapshot().get("consumed_nutrition", -1)) == 2
		and _confirmation_order(fixture, ids, fixture.trunk[0]) == ids,
		"Committed extension confirms exactly both paid lots in acceptance FIFO order")
	for cargo_id: String in ids:
		_assert_cargo(fixture, cargo_id, &"confirmed", [fixture.trunk[0], fixture.trunk[1]])
	fixture.growth.advance(100.0)
	_check(fixture.growth.get_requested_nutrition(fixture.task_id) == 4,
		"Default mature junction waits for its separate four-unit investment")
	var junction_ids: Array[String] = []
	for _lot: int in range(4):
		var packet: Node2D = _launch(fixture, &"growth")
		if packet != null:
			junction_ids.append(_cargo_id(packet))
			_finish(fixture, packet)
	_check(_count(fixture, fixture.trunk[0]) == 2, "Junction supplies cannot count upon refundable arrival")
	fixture.growth.advance(0.001)
	_refresh(fixture)
	_check(int(fixture.growth.get_task_snapshot().get("consumed_nutrition", -1)) == 6
		and _confirmation_order(fixture, junction_ids, fixture.trunk[0]) == junction_ids
		and _count(fixture, fixture.trunk[0]) == 6,
		"Separate junction commitment confirms the exact four FIFO lots once")
	for record: Dictionary in fixture.growth_supply.get_shipment_records():
		_check(int(record.get("buffered_nutrition", -1)) == 0 and not bool(record.get("refunded", true)),
			"All committed growth lots are retired before observer notification")
	fixture.growth.cancel_task()
	_check(fixture.core.nutrition == fixture.initial_total - 6 and _count(fixture, fixture.trunk[0]) == 6,
		"Cancelling a later growth phase never refunds paid structure or removes its passage history")
	_conservation(fixture, "growth FIFO and junction")
	evidence.append({"case": "growth_fifo", "extension_order": ids, "junction_order": junction_ids,
		"consumed": 6, "confirmed_on_ingress": _count(fixture, fixture.trunk[0])})
	await _dispose(fixture)


func _test_consumption_fifo(kind: StringName) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var packets: Array[Node2D] = []
	for _lot: int in range(2):
		var packet: Node2D = _launch(fixture, kind)
		if packet != null:
			packets.append(packet)
	var arrival_ids: Array[String] = []
	for index: int in range(packets.size() - 1, -1, -1):
		arrival_ids.append(_cargo_id(packets[index]))
		_finish(fixture, packets[index])
	_check(arrival_ids.size() == 2 and _count(fixture, fixture.trunk[0]) == 0,
		String(kind) + " accepts two real paid lots without counting refundable cache")
	_consume_once(fixture, kind)
	var task: Dictionary = fixture.cultivation.get_task_snapshot() if kind == &"cultivation" \
		else fixture.repair.get_task_snapshot()
	var used: int = int(task.get("structure_consumed", 0)) + int(task.get("startup_transferred", 0)) \
		if kind == &"cultivation" else int(task.get("consumed_nutrition", 0))
	_check(used > 0 and used < arrival_ids.size(), String(kind) + " commits a strict FIFO prefix before cancellation")
	for index: int in range(arrival_ids.size()):
		if index < used:
			var traversed: Array[HyphaEdge] = [fixture.trunk[0]]
			if kind == &"cultivation":
				traversed.append(fixture.trunk[1])
			_assert_cargo(fixture, arrival_ids[index], &"confirmed", traversed)
		else:
			_assert_cargo(fixture, arrival_ids[index], &"pending")
	_check(_confirmation_order(fixture, arrival_ids, fixture.trunk[0]) == arrival_ids.slice(0, used)
		and _count(fixture, fixture.trunk[0]) == used,
		String(kind) + " confirmations follow actual acceptance FIFO rather than dispatch order")
	_cancel_business(fixture, kind)
	for index: int in range(used, arrival_ids.size()):
		_assert_cargo(fixture, arrival_ids[index], &"discarded")
	_check(fixture.core.nutrition == fixture.initial_total - used and _count(fixture, fixture.trunk[0]) == used,
		String(kind) + " refunds only unspent lots and retains irreversible consumption")
	_conservation(fixture, String(kind) + " consumed FIFO prefix")
	evidence.append({"case": "consumption_fifo", "kind": kind, "acceptance_order": arrival_ids,
		"confirmed_order": _confirmation_order(fixture, arrival_ids, fixture.trunk[0]), "consumed": used})
	await _dispose(fixture)


func _deliver_lots(fixture: Fixture, kind: StringName, amount: int) -> Array[String]:
	var ids: Array[String] = []
	for _lot: int in range(amount):
		var packet: Node2D = _launch(fixture, kind)
		if packet != null:
			ids.append(_cargo_id(packet))
			_finish(fixture, packet)
	return ids


func _test_startup_reservation_and_commit() -> void:
	var fixture: Fixture = _new_fixture(64)
	await _prepare(fixture, &"cultivation")
	var structure: Array[String] = _deliver_lots(fixture, &"cultivation", 8)
	fixture.cultivation.advance(3.1)
	_check(int(fixture.cultivation.get_task_snapshot().get("structure_consumed", -1)) == 8
		and fixture.matured.is_empty() and _count(fixture, fixture.trunk[0]) == 8,
		"Eight real structure payments commit before unfunded startup stock")
	var old_startup: Array[String] = _deliver_lots(fixture, &"cultivation", 3)
	fixture.cultivation.advance(0.1)
	var transit: Node2D = _launch(fixture, &"cultivation")
	if transit != null:
		old_startup.append(_cargo_id(transit))
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(int(snapshot.get("startup_reserved", -1)) == 3
		and int(snapshot.get("startup_transferred", -1)) == 0 and _count(fixture, fixture.trunk[0]) == 8,
		"Reserved startup stock and its final in-flight payment cannot count as consumption")
	_conservation(fixture, "refundable startup reservation")
	fixture.cultivation.cancel_task()
	for cargo_id: String in old_startup:
		_assert_cargo(fixture, cargo_id, &"discarded")
	_check(fixture.core.nutrition == 56 and _count(fixture, fixture.trunk[0]) == 8,
		"Startup cancellation refunds all four payments without refunding structure")
	await _prepare(fixture, &"cultivation", true)
	var committed_startup: Array[String] = _deliver_lots(fixture, &"cultivation", 4)
	_check(_count(fixture, fixture.trunk[0]) == 8, "Replacement startup payments wait for a real organ-slot commitment")
	fixture.cultivation.advance(0.1)
	snapshot = fixture.cultivation.get_task_snapshot()
	_check(snapshot.get("state") == &"completed" and int(snapshot.get("startup_transferred", -1)) == 4
		and fixture.matured.size() == 1 and fixture.matured[0].nutrition == 4
		and _count(fixture, fixture.trunk[0]) == 12 and fixture.core.nutrition == 52,
		"Accepted organ materialization transfers exactly four paid units and four cargo passages")
	for cargo_id: String in structure + committed_startup:
		_assert_cargo(fixture, cargo_id, &"confirmed", [fixture.trunk[0], fixture.trunk[1]])
	for cargo_id: String in old_startup:
		_check(not committed_startup.has(cargo_id), "Startup retry uses new genuine payment identities")
	fixture.cultivation.advance(10.0)
	_check(_count(fixture, fixture.trunk[0]) == 12 and fixture.core.get_received_product_count() == 0,
		"Repeated completed cultivation cannot reconfirm stock or create income")
	_conservation(fixture, "accepted startup transfer")
	evidence.append({"case": "startup_reserve_then_transfer", "structure": 8, "refunded_startup": 4,
		"committed_startup": 4, "confirmed_on_ingress": _count(fixture, fixture.trunk[0])})
	await _dispose(fixture)


func _test_materialization_rollback() -> void:
	var fixture: Fixture = _new_fixture(64)
	await _prepare(fixture, &"cultivation")
	_deliver_lots(fixture, &"cultivation", 8)
	fixture.cultivation.advance(3.1)
	var startup: Array[String] = _deliver_lots(fixture, &"cultivation", 4)
	var intercepted: Array[bool] = [false]
	fixture.host.child_entered_tree.connect(func(child: Node) -> void:
		if child is AttackOrgan:
			intercepted[0] = true
			_check(int(fixture.cultivation.get_task_snapshot().get("startup_transferred", -1)) == 0
				and _count(fixture, fixture.trunk[0]) == 8,
				"Disabled materialization draft cannot publish startup consumption")
			fixture.host.queue_free()
			fixture.network.get_registered_nodes()
	)
	fixture.cultivation.advance(0.1)
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(intercepted[0] and fixture.matured.is_empty() and snapshot.get("state") == &"cancelled"
		and int(snapshot.get("startup_transferred", -1)) == 0
		and fixture.core.nutrition == 56 and _count(fixture, fixture.trunk[0]) == 8,
		"Failed organ-slot commitment refunds the actual startup payer and keeps only sunk structure")
	for cargo_id: String in startup:
		_assert_cargo(fixture, cargo_id, &"discarded")
	_conservation(fixture, "materialization rollback")
	evidence.append({"case": "materialization_rollback", "refunded_startup": startup.size(),
		"confirmed_on_surviving_ingress": _count(fixture, fixture.trunk[0])})
	await _dispose(fixture)


func _test_remains_identity_retry(batch: bool) -> void:
	var fixture: Fixture = _new_fixture()
	if batch:
		_add_carcass(fixture)
	else:
		_add_original_remains(fixture)
	var first: Node2D = _launch(fixture, &"remains")
	if first == null:
		await _dispose(fixture)
		return
	var original: EnemyRemains = fixture.original_remains
	if batch:
		for child: Node in fixture.remains.get_children():
			if child is EnemyRemains:
				original = child as EnemyRemains
	var cargo_id: String = _cargo_id(first)
	var expected_id: String = "remains:" + String(original.get_meta("carcass_batch_id")) if batch \
		else "remains:instance:" + str(original.get_instance_id())
	var nutrition: int = original.nutrition_value
	_check(cargo_id == expected_id and int(_transport(first).get("units", 0)) == 2,
		"Corpse identity comes from its original source or committed batch, while traffic still uses two units")
	var callbacks: Array[Callable] = _callbacks(first, fixture.recycling)
	if not _reach_edge(fixture, first, fixture.trunk[0]):
		await _dispose(fixture)
		return
	fixture.trunk[1].entry_enabled = false
	_until(fixture, first, func() -> bool:
		return (_transport(first).get("current_node") == fixture.middle
			and _transport(first).get("state") == &"waiting"),
		"Corpse completes ground pickup and its first edge before a blocked route")
	_check(int(fixture.tracker.get_cargo_snapshot(cargo_id).get("candidate_count", -1)) == 1
		and _count(fixture, fixture.trunk[0]) == 0, "Ground pickup never counts and failed corpse delivery leaves only a pending edge")
	first.call("cancel_transport")
	_check(original.is_available() and original.nutrition_value == nutrition,
		"Interrupted corpse drops the same original nutrition and identity")
	fixture.trunk[1].entry_enabled = true
	var retry: Node2D = _launch(fixture, &"remains")
	if retry != null:
		_check(_cargo_id(retry) == cargo_id and _transport(retry).get("task_id") != _transport(first).get("task_id"),
			"New corpse attempt preserves cargo identity without reusing its transport task")
		_replay(callbacks, first)
		_check(fixture.recycling.get_in_transit_count() == 1 and fixture.stomach.get_queued_nutrition() == 0,
			"Old corpse callbacks cannot accept the retry's claim")
		_finish(fixture, retry)
		_assert_cargo(fixture, cargo_id, &"confirmed", [fixture.trunk[0], fixture.trunk[1], fixture.stomach_edge])
		_check(_count(fixture, fixture.trunk[0]) == 1 and _count(fixture, fixture.trunk[1]) == 1
			and fixture.stomach.get_queued_nutrition() == nutrition and fixture.recycling.delivered_count == 1,
			"Accepted retry confirms the original candidate union once, independent of corpse nutrition")
		_replay(callbacks, first)
		retry.emit_signal("arrived", retry)
		_check(_count(fixture, fixture.trunk[0]) == 1 and fixture.stomach.get_queued_nutrition() == nutrition,
			"Repeated corpse receipt cannot duplicate nutrition or an edge passage")
	if batch:
		_check(fixture.carcass.get_remaining_nutrition() == 70 and fixture.carcass.get_harvested_nutrition() == 10,
			"Batch retry cannot harvest or restore the source's ten units twice")
	_conservation(fixture, "corpse original identity retry")
	evidence.append({"case": "corpse_retry", "batch": batch, "cargo_id": cargo_id,
		"nutrition": nutrition, "units": 2, "confirmed_on_ingress": _count(fixture, fixture.trunk[0])})
	await _dispose(fixture)


func _test_return_product_retry() -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, &"return")
	var product_id: String = String(fixture.stomach.get_output_products()[0]["product_id"])
	var first: Node2D = _launch(fixture, &"return")
	if first == null:
		await _dispose(fixture)
		return
	var cargo_id: String = _cargo_id(first)
	_check(cargo_id == "return:" + product_id, "Return cargo is the immutable digestion product, never the attempt ID")
	var baseline: Array[int] = _edge_counts(fixture)
	var callbacks: Array[Callable] = _callbacks(first, fixture.returns)
	if not _reach_edge(fixture, first, fixture.trunk[1]):
		await _dispose(fixture)
		return
	fixture.trunk[0].entry_enabled = false
	_until(fixture, first, func() -> bool:
		return (_transport(first).get("current_node") == fixture.middle
			and _transport(first).get("state") == &"waiting"),
		"Return completes two nonzero reverse segments before its original receipt")
	_check(int(fixture.tracker.get_cargo_snapshot(cargo_id).get("candidate_count", -1)) == 2
		and _edge_counts(fixture) == baseline, "Unreceived product has pending reverse candidates without edge growth")
	first.call("cancel_transport")
	_check(fixture.stomach.get_output_products()[0]["status"] == &"queued" and fixture.core.get_received_product_count() == 0,
		"Interrupted return retains its exact unpaid product")
	fixture.trunk[0].entry_enabled = true
	var retry: Node2D = _launch(fixture, &"return")
	if retry != null:
		var records: Array[Dictionary] = fixture.returns.get_shipment_records()
		_check(_cargo_id(retry) == cargo_id and records.size() == 2
			and records[0]["product_id"] == records[1]["product_id"] and records[0]["attempt_id"] != records[1]["attempt_id"],
			"Product retry has one stable business identity and two distinct original attempt records")
		_replay(callbacks, first)
		_finish(fixture, retry)
		_assert_cargo(fixture, cargo_id, &"confirmed", [fixture.stomach_edge, fixture.trunk[1], fixture.trunk[0]])
		_check(fixture.core.nutrition == 138 and fixture.core.get_received_product_count() == 1
			and fixture.stomach.get_output_count() == 0 and _count(fixture, fixture.trunk[0]) == 2,
			"One accepted ten-unit product counts one return cargo per edge after repeated traversal")
		_replay(callbacks, first)
		retry.emit_signal("arrived", retry)
		_check(fixture.core.nutrition == 138 and fixture.core.get_received_product_count() == 1
			and _count(fixture, fixture.trunk[0]) == 2, "Old and repeated return callbacks cannot create repeated income")
	_conservation(fixture, "return product retry")
	evidence.append({"case": "product_retry", "product_id": product_id, "nutrition": 10,
		"attempts": 2, "received_products": fixture.core.get_received_product_count(), "confirmed_on_ingress": 2})
	await _dispose(fixture)


func _test_reverse_reroute_identity(kind: StringName) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var packet: Node2D = _launch(fixture, kind)
	if packet == null:
		await _dispose(fixture)
		return
	var cargo_id: String = _cargo_id(packet)
	var original_task: String = String(_transport(packet).get("task_id", ""))
	var repeated_edge: HyphaEdge = fixture.trunk[1] if kind == &"return" else fixture.trunk[0]
	var unavailable: HyphaEdge = fixture.trunk[0] if kind == &"return" else fixture.trunk[1]
	var before: int = _count(fixture, repeated_edge)
	if not _reach_edge(fixture, packet, repeated_edge):
		await _dispose(fixture)
		return
	unavailable.entry_enabled = false
	_until(fixture, packet, func() -> bool:
		return (_transport(packet).get("current_node") == fixture.middle
			and _transport(packet).get("state") == &"waiting"),
		String(kind) + " completes one route section before an actual reroute")
	for edge: HyphaEdge in fixture.detour:
		edge.entry_enabled = true
	_finish(fixture, packet)
	if kind == &"growth":
		# 两单位默认投资：第二份付款也必须真实抵达。
		var second: Node2D = _launch(fixture, &"growth")
		_finish(fixture, second)
		_consume_once(fixture, kind)
	elif kind == &"cultivation":
		_consume_once(fixture, kind)
	_check(String(_transport(packet).get("task_id", "")) == original_task
		and int(_transport(packet).get("reroute_count", 0)) >= 1,
		String(kind) + " reverse reroute preserves the actual business transport identity")
	var traversed: Array[HyphaEdge] = [repeated_edge, fixture.detour[0], fixture.detour[1]]
	if kind == &"supply":
		traversed.append(fixture.attack_edge)
	elif kind == &"return":
		traversed.append(fixture.stomach_edge)
	_assert_cargo(fixture, cargo_id, &"confirmed", traversed)
	_check(_count(fixture, repeated_edge) == before + 1,
		String(kind) + " forward and reverse passage of one edge count once for the same cargo")
	var snapshot: Dictionary = fixture.tracker.get_cargo_snapshot(cargo_id)
	packet.emit_signal("arrived", packet)
	_refresh(fixture)
	_check(fixture.tracker.get_cargo_snapshot(cargo_id) == snapshot,
		String(kind) + " accepted cargo seals its candidate union after the reroute")
	_conservation(fixture, String(kind) + " reverse reroute")
	evidence.append({"case": "reverse_reroute", "kind": kind, "cargo_id": cargo_id,
		"distinct_confirmed_edges": snapshot.get("confirmed_count", 0), "repeated_edge_delta": 1})
	await _dispose(fixture)


func _test_eighty_nutrition_is_sixteen_cargos() -> void:
	var fixture: Fixture = _new_fixture(72)
	_add_carcass(fixture)
	var batches: Dictionary[String, bool] = {}
	var products: Dictionary[String, bool] = {}
	for _batch: int in range(8):
		var remains: Node2D = _launch(fixture, &"remains")
		if remains == null:
			break
		batches[_cargo_id(remains)] = true
		_finish(fixture, remains)
		await _digest_one(fixture)
		var returns: Node2D = _launch(fixture, &"return")
		if returns == null:
			break
		products[_cargo_id(returns)] = true
		_finish(fixture, returns)
		returns.emit_signal("arrived", returns)
		_conservation(fixture, "bounded carcass cycle")
	_check(fixture.carcass.get_remaining_nutrition() == 0 and fixture.carcass.get_harvested_nutrition() == 80
		and batches.size() == 8 and products.size() == 8 and fixture.core.nutrition == 152
		and fixture.core.get_received_product_count() == 8 and _count(fixture, fixture.trunk[0]) == 16
		and int(fixture.tracker.get_snapshot().get("confirmed_count", -1)) == 16,
		"Eighty real nutrition creates exactly eight batch cargos and eight product cargos, never 160 or units-scaled passages")
	_check(not fixture.recycling.try_dispatch() and fixture.stomach.get_output_count() == 0,
		"An exhausted source cannot create a ninth batch or product")
	evidence.append({"case": "whole_carcass", "source_nutrition": 80, "batches": batches.size(),
		"products": products.size(), "confirmed_cargos": 16, "edge_passages": _count(fixture, fixture.trunk[0])})
	await _dispose(fixture)


func _warm_ordinary_passages(fixture: Fixture, amount: int) -> void:
	for _payment: int in range(amount):
		var packet: Node2D = _launch(fixture, &"supply")
		if packet == null:
			break
		_finish(fixture, packet)
		_check(fixture.attack.consume_nutrition(1), "Accepted ordinary stock is really consumed before the next supply")
		fixture.shot_consumption += 1
	_check(_count(fixture, fixture.trunk[1]) == amount, "Warmup uses one real accepted payment per passage")
	_conservation(fixture, "real ordinary warmup")


func _test_upgrade_keeps_live_repair_credit() -> void:
	var fixture: Fixture = _new_fixture()
	_warm_ordinary_passages(fixture, 19)
	await _prepare(fixture, &"repair")
	var repair_ids: Array[String] = _deliver_lots(fixture, &"repair", 2)
	_check(_count(fixture, fixture.trunk[0]) == 19, "Unspent repair buffer cannot produce the twentieth passage")
	fixture.repair.advance(0.1)
	_refresh(fixture)
	var before: Dictionary = fixture.repair.get_task_snapshot()
	_check(int(before.get("consumed_nutrition", -1)) == 1 and int(before.get("buffered_nutrition", -1)) == 1
		and is_equal_approx(float(before.get("paid_heal_remaining", -1.0)), 9.0)
		and is_equal_approx(fixture.trunk[1].health, 11.0)
		and int(fixture.repair_supply.get_supply_snapshot().get("reservation_goal", -1)) == 1,
		"One genuine repair unit buys ten restoration points and leaves nine paid points plus one refundable lot")
	var accepted: Node2D = _launch(fixture, &"supply")
	_finish(fixture, accepted)
	var after: Dictionary = fixture.repair.get_task_snapshot()
	var supply: Dictionary = fixture.repair_supply.get_supply_snapshot()
	_check(_count(fixture, fixture.trunk[1]) == 20 and fixture.trunk[1].traffic_capacity == 3
		and is_equal_approx(fixture.trunk[1].max_health, 50.0) and is_equal_approx(fixture.trunk[1].health, 11.0),
		"Twentieth accepted ordinary cargo upgrades the live repair target without free healing")
	_check(int(after.get("task_id", -1)) == int(before.get("task_id", -2))
		and int(after.get("consumed_nutrition", -1)) == 1 and int(after.get("buffered_nutrition", -1)) == 1
		and is_equal_approx(float(after.get("paid_heal_remaining", -1.0)), 9.0)
		and int(after.get("remaining_demand", -1)) == 2
		and int(supply.get("reservation_goal", -1)) == 2 and int(supply.get("reserved_nutrition", -1)) == 2,
		"Maximum-health growth updates the real repair demand and funded budget while preserving paid credit")
	fixture.repair.advance(0.9)
	_refresh(fixture)
	_check(is_equal_approx(fixture.trunk[1].health, 20.0)
		and int(fixture.repair.get_task_snapshot().get("consumed_nutrition", -1)) == 1,
		"Existing nine paid restoration points heal exactly once without spending another unit")
	var extra: Array[String] = _deliver_lots(fixture, &"repair", 2)
	fixture.repair.advance(100.0)
	_refresh(fixture)
	after = fixture.repair.get_task_snapshot()
	_check(after.get("state") == &"completed" and int(after.get("consumed_nutrition", -1)) == 4
		and is_equal_approx(fixture.trunk[1].health, 50.0)
		and fixture.core.nutrition == fixture.initial_total - 24
		and fixture.core.get_received_product_count() == 0
		and int(fixture.repair_supply.get_supply_snapshot().get("reserved_nutrition", -1)) == 0,
		"Upgraded repair finishes with four actually spent units and twenty real ordinary payments")
	for cargo_id: String in repair_ids + extra:
		_assert_cargo(fixture, cargo_id, &"confirmed", [fixture.trunk[0]])
	var counted: Array[int] = _edge_counts(fixture)
	fixture.repair.advance(100.0)
	fixture.repair.cancel_task()
	_check(_edge_counts(fixture) == counted and fixture.core.nutrition == fixture.initial_total - 24,
		"Completed upgrade and repair cannot heal, credit or confirm repeatedly")
	_conservation(fixture, "live repair target upgrade")
	evidence.append({"case": "live_repair_upgrade", "health_before": 11, "health_after_upgrade": 11,
		"max_health": 50, "paid_credit_preserved": 9, "demand_before": 1, "demand_after": 2,
		"actual_repair_spend": 4, "final_health": fixture.trunk[1].health})
	await _dispose(fixture)


func _test_capacity_upgrade_keeps_real_fifo() -> void:
	var fixture: Fixture = _new_fixture()
	_warm_ordinary_passages(fixture, 19)
	fixture.trunk[1].take_damage(10.0)
	var packets: Array[Node2D] = []
	for _payment: int in range(5):
		var packet: Node2D = _launch(fixture, &"supply")
		if packet != null:
			packets.append(packet)
	if packets.size() != 5:
		await _dispose(fixture)
		return
	_reach_edge(fixture, packets[0], fixture.trunk[1])
	_reach_edge(fixture, packets[1], fixture.trunk[1])
	var retained_token: String = String(_transport(packets[1]).get("token", ""))
	for index: int in range(2, 5):
		_until(fixture, packets[index], func() -> bool:
			return (_transport(packets[index]).get("current_node") == fixture.middle
				and _transport(packets[index]).get("state") == &"waiting"),
			"Later real supply joins the saturated target-edge FIFO")
	# 反向存储不改变实际等待节点；容量扩张必须保留这些已排队请求。
	_finish(fixture, packets[0])
	_refresh(fixture)
	_check(fixture.trunk[1].traffic_capacity == 3 and _count(fixture, fixture.trunk[1]) == 20
		and is_equal_approx(fixture.trunk[1].health, 25.0)
		and String(_transport(packets[1]).get("token", "")) == retained_token,
		"Real acceptance expands capacity without replacing the occupied lease or healing damage")
	for index: int in range(2, 4):
		_tick(fixture, packets[index])
		_check(not String(_transport(packets[index]).get("token", "")).is_empty()
			and _transport(packets[index]).get("edge") == fixture.trunk[1],
			"The two oldest real waiters receive the new capacity slots")
	_tick(fixture, packets[4])
	_check(_transport(packets[4]).get("state") == &"waiting"
		and String(_transport(packets[4]).get("token", "")).is_empty(),
		"The newest waiter cannot overtake the existing two FIFO requests")
	_check(fixture.core.get_received_product_count() == 0 and _count(fixture, fixture.trunk[1]) == 20,
		"Capacity grants do not create an accepted cargo, heal or credit income")
	for index: int in range(1, packets.size()):
		_finish(fixture, packets[index])
	_check(_count(fixture, fixture.trunk[1]) == 24 and fixture.attack.nutrition == 5
		and fixture.core.nutrition == fixture.initial_total - 24 and is_equal_approx(fixture.trunk[1].health, 25.0),
		"All original FIFO supplies settle exactly once after expansion without new debit or free healing")
	_conservation(fixture, "capacity upgrade with real FIFO")
	evidence.append({"case": "capacity_upgrade_fifo", "old_capacity": 2, "new_capacity": 3,
		"original_waiters": 3, "admitted_oldest": 2, "lease_retained": true, "confirmed_final": 24})
	await _dispose(fixture)


func _test_restart_rejects_old_callbacks(kind: StringName) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var old: Node2D = _launch(fixture, kind)
	if old == null:
		await _dispose(fixture)
		return
	var old_id: String = _cargo_id(old)
	var old_generation: int = int(_transport(old).get("cargo_generation", -1))
	var callbacks: Array[Callable] = _callbacks(old, _service(fixture, kind))
	var entered: HyphaEdge = fixture.stomach_edge if kind == &"return" else fixture.trunk[0]
	_reach_edge(fixture, old, entered)
	fixture.veins.stop()
	fixture.tracker.reset()
	_reset_businesses(fixture)
	fixture.veins.reset()
	_check(fixture.tracker.get_generation() > old_generation
		and int(fixture.tracker.get_snapshot().get("cargo_count", -1)) == 0
		and _count(fixture, fixture.trunk[0]) == 0,
		String(kind) + " restart invalidates old cargo before business cancellation and clears traffic before main reset")
	if kind == &"growth" or kind == &"cultivation" or kind == &"repair":
		await _prepare(fixture, kind, kind == &"cultivation")
	var fresh: Node2D = _launch(fixture, kind)
	if fresh != null:
		var balance: int = fixture.core.nutrition
		var transit: int = int(_service(fixture, kind).call("get_in_transit_count"))
		var counts: Array[int] = _edge_counts(fixture)
		_replay(callbacks, old)
		old.call("_physics_process", 10.0)
		_refresh(fixture)
		_check(fixture.core.nutrition == balance and _edge_counts(fixture) == counts
			and int(_service(fixture, kind).call("get_in_transit_count")) == transit,
			String(kind) + " old packet movement and callbacks cannot affect the new generation or payment")
		_check(int(_transport(fresh).get("cargo_generation", -1)) == fixture.tracker.get_generation(),
			"Replacement packet captures the new tracking generation")
		if kind in [&"remains", &"return"]:
			_check(_cargo_id(fresh) == old_id, "Unaccepted organic retry keeps the business ID across a lifecycle generation")
		else:
			_check(_cargo_id(fresh) != old_id, "Refunded paid shipment receives a new payment ID after restart")
		_finish(fixture, fresh)
		if kind == &"growth":
			var additional: Node2D = _launch(fixture, kind)
			_finish(fixture, additional)
		if kind in REFUNDABLE_KINDS:
			_consume_once(fixture, kind)
		_check(fixture.tracker.get_cargo_snapshot(_cargo_id(fresh)).get("status") == &"confirmed",
			String(kind) + " new generation still accepts its first genuine receipt or consumption")
		var settled: Array[int] = _edge_counts(fixture)
		_replay(callbacks, old)
		_check(_edge_counts(fixture) == settled, "Old settlement replay cannot append effective passages after a new commit")
	_conservation(fixture, String(kind) + " restart")
	evidence.append({"case": "restart_old_callbacks", "kind": kind, "old_generation": old_generation,
		"new_generation": fixture.tracker.get_generation(), "edge_counts": _edge_counts(fixture)})
	await _dispose(fixture)


func _test_reset_inside_real_return_receipt() -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, &"return")
	var packet: Node2D = _launch(fixture, &"return")
	if packet == null:
		await _dispose(fixture)
		return
	var callbacks: Array[Callable] = _callbacks(packet, fixture.returns)
	var generation: int = fixture.tracker.get_generation()
	fixture.core.digestion_product_arrived.connect(func(_product_id: String, _nutrition: int) -> void:
		fixture.veins.stop()
		fixture.tracker.reset()
		fixture.returns.reset()
		fixture.traffic.reset()
		fixture.veins.reset()
	, CONNECT_ONE_SHOT)
	_finish(fixture, packet)
	_replay(callbacks, packet)
	_check(fixture.core.nutrition == 138 and fixture.core.get_received_product_count() == 1
		and fixture.stomach.get_output_count() == 0 and fixture.tracker.get_generation() > generation
		and int(fixture.tracker.get_snapshot().get("confirmed_passage_count", -1)) == 0
		and _count(fixture, fixture.trunk[0]) == 0,
		"Reset during the actual core receipt preserves one original income but cannot grade the replacement generation")
	_conservation(fixture, "reset inside real product receipt")
	evidence.append({"case": "reset_during_receipt", "real_income": 10, "received_products": 1,
		"new_generation_passages": 0})
	await _dispose(fixture)


func _test_stop_retains_grade_and_rejects_old_completion() -> void:
	var fixture: Fixture = _new_fixture()
	_warm_ordinary_passages(fixture, 20)
	fixture.trunk[1].take_damage(8.0)
	var packet: Node2D = _launch(fixture, &"supply")
	if packet == null:
		await _dispose(fixture)
		return
	var before: Dictionary = fixture.veins.get_edge_snapshot(fixture.trunk[1])
	fixture.veins.stop()
	fixture.tracker.reset()
	_finish(fixture, packet)
	_check(fixture.veins.get_edge_snapshot(fixture.trunk[1]) == before
		and fixture.trunk[1].traffic_capacity == 3 and is_equal_approx(fixture.trunk[1].health, 27.0),
		"Death-style stop retains developed edge health and ignores an old packet's late completion")
	fixture.traffic.reset()
	fixture.veins.reset()
	var reset: Dictionary = fixture.veins.get_edge_snapshot(fixture.trunk[1])
	_check(int(reset.get("grade", -1)) == 0 and int(reset.get("confirmed_passages", -1)) == 0
		and fixture.trunk[1].traffic_capacity == 2 and is_equal_approx(fixture.trunk[1].max_health, 35.0)
		and is_equal_approx(fixture.trunk[1].health, 27.0),
		"Restart-style reset restores base abilities only after traffic cleanup and cannot heal damage")
	_conservation(fixture, "stop then reset")
	evidence.append({"case": "stop_and_reset", "retained_count": 20, "retained_grade": 1,
		"health_before_and_after": 27, "reset_capacity": 2})
	await _dispose(fixture)
