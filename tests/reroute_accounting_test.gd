extends SceneTree
## 五类真实运输共享容量二；暂时断路只改变位置状态，不改变原业务资源所有权。

const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const STOMACH_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const REMAINS_PACKET_SCENE: PackedScene = preload("res://scenes/recycling/remains_packet.tscn")
const KINDS: Array[String] = ["combat", "growth", "cultivation", "remains", "return"]
const STEP: float = 0.05
const STEP_LIMIT: int = 400

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
	var bypass: HyphaNode
	var stomach_host: HyphaNode
	var attack_host: HyphaNode
	var blocker_host: HyphaNode
	var attack: AttackOrgan
	var blocker: AttackOrgan
	var stomach: DigestiveOrgan
	var carcass: LargeCarcass
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var field: FungalField
	var combat: SupplySystem
	var growth: GrowthSystem
	var growth_supply: GrowthSupplySystem
	var cultivation: CultivationSystem
	var cultivation_supply: CultivationSupplySystem
	var recycling: RecyclingSystem
	var returns: NutritionReturnSystem
	var main_edges: Array[HyphaEdge] = []
	var bypass_edges: Array[HyphaEdge] = []
	var stomach_edge: HyphaEdge
	var all_edges: Array[HyphaEdge] = []
	var initial_total: int = 0
	var task_id: int = 0
	var batch_ids: Dictionary[String, bool] = {}
	var received_ids: Array[String] = []
	var produced_ids: Array[String] = []

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for kind: String in KINDS:
		await _test_prestart_reentry(kind)
		await _test_capacity_queue(kind)
		await _test_block_wait_and_bypass(kind)
		await _test_cancel_during_restore(kind)
		await _test_target_removal(kind)
		await _test_reset_and_old_callbacks(kind)
	await _test_receiver_reparenting("combat")
	await _test_receiver_reparenting("remains")
	await _test_new_harvest_admission()
	await _test_full_carcass_cycle()
	_check(root.get_child_count() == 0, "All accounting fixtures leave the tree")
	print("REROUTE_ACCOUNTING_TEST_RESULT ", JSON.stringify({
		"runtime": "EXECUTED", "status": "PASS" if failures.is_empty() else "FAIL",
		"checks": checks, "conservation_checks": conservation_checks, "failures": failures,
		"cases": cases, "business_entrypoints": KINDS, "shared_dispatcher": true,
		"edge_capacity": 2, "initial_carcass_nutrition": 80,
		"motion": "production_packet_physics", "first_settlements": "real_committed_arrivals",
		"early_arrival_signals": "negative_cases_only", "artificial_resource_pools": false,
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
	_check(edge.traffic_capacity == 2 and fixture.network.register_edge(edge),
		"Every physical edge registers with unchanged capacity two")
	fixture.all_edges.append(edge)
	return edge


func _new_fixture() -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = _container(root, "RerouteAccountingFixture")
	fixture.nodes = _container(fixture.world, "Nodes")
	fixture.edges = _container(fixture.world, "Edges")
	fixture.tips = _container(fixture.world, "Tips")
	fixture.packets = _container(fixture.world, "Packets")
	fixture.remains = _container(fixture.world, "Remains")
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.core = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	fixture.core.add_child(health_bar)
	fixture.nodes.add_child(fixture.core)
	_check(fixture.network.register_node(fixture.core, true), "Original mother core registers")
	fixture.middle = _node(fixture, Vector2(100, 0))
	fixture.host = _node(fixture, Vector2(200, 0))
	fixture.bypass = _node(fixture, Vector2(100, 100))
	fixture.stomach_host = _node(fixture, Vector2(240, 40))
	fixture.attack_host = _node(fixture, Vector2(280, -40))
	fixture.blocker_host = _node(fixture, Vector2(280, 40))
	fixture.main_edges.append(_edge(fixture, fixture.core, fixture.middle))
	fixture.main_edges.append(_edge(fixture, fixture.middle, fixture.host))
	fixture.bypass_edges.append(_edge(fixture, fixture.core, fixture.bypass, false))
	fixture.bypass_edges.append(_edge(fixture, fixture.middle, fixture.bypass, false))
	fixture.bypass_edges.append(_edge(fixture, fixture.bypass, fixture.host, false))
	fixture.stomach_edge = _edge(fixture, fixture.host, fixture.stomach_host)
	_edge(fixture, fixture.host, fixture.attack_host)
	_edge(fixture, fixture.host, fixture.blocker_host)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.field = FungalField.new()
	fixture.world.add_child(fixture.field)
	fixture.field.set_process(false)
	fixture.field.set_sources([{"node": fixture.core, "kind": &"core", "connected": true}])
	fixture.field.advance(1.0)
	fixture.attack = ORGAN_SCENE.instantiate() as AttackOrgan
	fixture.attack_host.add_child(fixture.attack)
	fixture.blocker = ORGAN_SCENE.instantiate() as AttackOrgan
	fixture.blocker_host.add_child(fixture.blocker)
	fixture.stomach = STOMACH_SCENE.instantiate() as DigestiveOrgan
	fixture.stomach.mother_core = fixture.core
	fixture.stomach_host.add_child(fixture.stomach)
	fixture.stomach.set_process(false)
	fixture.stomach.digest_timer.stop()
	fixture.carcass = CARCASS_SCENE.instantiate() as LargeCarcass
	fixture.remains.add_child(fixture.carcass)
	fixture.carcass.global_position = Vector2(-40, 0)
	fixture.combat = SupplySystem.new()
	fixture.combat.mother_core = fixture.core
	fixture.combat.network_system = fixture.network
	fixture.combat.traffic_system = fixture.traffic
	fixture.combat.traffic_required = true
	fixture.combat.packet_container = fixture.packets
	fixture.combat.packet_scene = PACKET_SCENE
	fixture.world.add_child(fixture.combat)
	_check(fixture.combat.register_organ(fixture.attack) and fixture.combat.register_organ(fixture.blocker),
		"Both original-capacity attack organs register for actual supply")
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
	fixture.cultivation_supply = CultivationSupplySystem.new()
	fixture.cultivation_supply.cultivation_system = fixture.cultivation
	fixture.cultivation_supply.mother_core = fixture.core
	fixture.cultivation_supply.network_system = fixture.network
	fixture.cultivation_supply.traffic_system = fixture.traffic
	fixture.cultivation_supply.traffic_required = true
	fixture.cultivation_supply.packet_container = fixture.packets
	fixture.cultivation_supply.auto_supply = false
	fixture.world.add_child(fixture.cultivation_supply)
	fixture.cultivation_supply.set_process(false)
	fixture.recycling = RecyclingSystem.new()
	fixture.recycling.network_system = fixture.network
	fixture.recycling.traffic_system = fixture.traffic
	fixture.recycling.traffic_required = true
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
	fixture.returns.packet_container = fixture.packets
	fixture.returns.auto_return = false
	fixture.world.add_child(fixture.returns)
	fixture.returns.get_node("DispatchTimer").stop()
	fixture.packets.child_entered_tree.connect(func(child: Node) -> void:
		child.set_physics_process(false)
		child.set("speed", 80.0)
	)
	fixture.core.digestion_product_arrived.connect(func(product_id: String, _amount: int) -> void:
		fixture.received_ids.append(product_id)
	)
	fixture.stomach.product_created.connect(func(product_id: String, _amount: int) -> void:
		fixture.produced_ids.append(product_id)
	)
	fixture.initial_total = fixture.core.nutrition + fixture.attack.nutrition \
		+ fixture.blocker.nutrition + fixture.carcass.get_remaining_nutrition()
	_check(fixture.core.nutrition == 72 and fixture.attack.capacity == 6 \
		and fixture.blocker.capacity == 6 and fixture.stomach.capacity == 4 \
		and fixture.carcass.get_remaining_nutrition() == 80,
		"Fixture preserves original capital, receiver caps, and eighty-unit resource")
	return fixture


func _service(fixture: Fixture, kind: String) -> Node:
	match kind:
		"combat": return fixture.combat
		"growth": return fixture.growth_supply
		"cultivation": return fixture.cultivation_supply
		"remains": return fixture.recycling
		"return": return fixture.returns
	return null


func _transport(packet: Node2D) -> Dictionary:
	return packet.call("get_transport_snapshot") as Dictionary


func _last_packet(fixture: Fixture) -> Node2D:
	var children: Array[Node] = fixture.packets.get_children()
	children.reverse()
	for child: Node in children:
		if child is Node2D and not child.is_queued_for_deletion():
			return child as Node2D
	return null


func _launch(fixture: Fixture, kind: String, receiver: AttackOrgan = null) -> Node2D:
	var dispatched: bool = false
	if kind == "combat":
		dispatched = fixture.combat.request_supply(fixture.attack if receiver == null else receiver)
	else:
		dispatched = bool(_service(fixture, kind).call("try_dispatch"))
	_check(dispatched, kind + " dispatches through its real business entrypoint")
	if not dispatched:
		return null
	var packet: Node2D = _last_packet(fixture)
	_check(packet != null, kind + " produces one actual packet")
	if packet != null:
		packet.set("speed", 80.0)
		_check(bool(_transport(packet).get("started", false)), kind + " captures a started transport identity")
	return packet


func _prepare(fixture: Fixture, kind: String) -> void:
	if kind == "growth":
		fixture.task_id = fixture.growth.create_target(fixture.host, fixture.host.global_position + Vector2(70, 0))
		_check(fixture.task_id > 0, "Growth has a real unpaid seventy-pixel target")
	elif kind == "cultivation":
		fixture.task_id = fixture.cultivation.start_cultivation(fixture.host)
		_check(fixture.task_id > 0, "Cultivation owns a real unpaid bud on an empty host")
	elif kind == "return":
		var packet: Node2D = _launch(fixture, "remains")
		_finish_real_packet(fixture, packet)
		_check(fixture.stomach.get_queued_nutrition() == 10, "Return input is a physically delivered carcass batch")
		await _digest_one(fixture)
		_check(fixture.stomach.get_output_nutrition() == 10 and fixture.core.nutrition == 72,
			"A real digestive output remains uncredited before return")


func _digest_one(fixture: Fixture) -> void:
	var before: int = fixture.stomach.digested_count
	fixture.stomach.digest_timer.start(0.01)
	for _frame: int in range(30):
		await physics_frame
		await process_frame
		if fixture.stomach.digested_count > before:
			break
	fixture.stomach.digest_timer.stop()
	_check(fixture.stomach.digested_count == before + 1, "Actual DigestTimer creates exactly one output product")
	_conservation(fixture, "real digestion")


func _refresh_services(fixture: Fixture) -> void:
	fixture.traffic.refresh()
	fixture.growth_supply.call("_process", 0.0)
	fixture.cultivation_supply.call("_process", 0.0)
	fixture.returns.call("_on_dispatch_timer_timeout")
	fixture.growth.advance(STEP)
	fixture.cultivation.advance(STEP)


func _tick(fixture: Fixture, packet: Node2D) -> void:
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet.call("_physics_process", STEP)
	_refresh_services(fixture)
	_conservation(fixture, "physical tick")


func _until(fixture: Fixture, packet: Node2D, condition: Callable, description: String) -> bool:
	for _step: int in range(STEP_LIMIT):
		if bool(condition.call()) or not is_instance_valid(packet) or packet.is_queued_for_deletion():
			break
		_tick(fixture, packet)
	var reached: bool = bool(condition.call())
	_check(reached, description)
	return reached


func _finish_real_packet(fixture: Fixture, packet: Node2D) -> bool:
	if packet == null:
		return false
	return _until(fixture, packet, func() -> bool:
		return _transport(packet).get("state") == &"completed",
		"Packet completes from actual physics movement")


func _entry_edge(fixture: Fixture, kind: String) -> HyphaEdge:
	return fixture.main_edges[1] if kind == "return" else fixture.main_edges[0]


func _future_edge(fixture: Fixture, kind: String) -> HyphaEdge:
	return fixture.main_edges[0] if kind == "return" else fixture.main_edges[1]


func _reach_occupied_edge(fixture: Fixture, packet: Node2D, edge: HyphaEdge) -> bool:
	if packet == null:
		return false
	return _until(fixture, packet, func() -> bool:
		var snapshot: Dictionary = _transport(packet)
		return snapshot.get("edge") == edge and snapshot.get("location_kind") == &"edge" \
			and float(snapshot.get("progress", 0.0)) > 0.1,
		"Packet physically occupies the selected shared edge")


func _callbacks(packet: Node2D, owner: Node) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(&"arrived"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	_check(not callbacks.is_empty(), "Capture real business arrival callbacks before cancellation")
	return callbacks


func _replay(callbacks: Array[Callable], packet: Node2D) -> void:
	for callback: Callable in callbacks:
		callback.call(packet)


func _resources(fixture: Fixture, kind: String) -> Dictionary:
	var growth: Dictionary = fixture.growth.get_task_snapshot()
	var cultivation: Dictionary = fixture.cultivation.get_resource_snapshot()
	var batches: Array[Dictionary] = []
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and not child.is_queued_for_deletion():
			var remains: EnemyRemains = child as EnemyRemains
			batches.append({"id": String(remains.get_meta("carcass_batch_id", "")),
				"nutrition": remains.nutrition_value, "available": remains.is_available()})
	return {
		"balance": fixture.core.nutrition, "received_count": fixture.core.get_received_product_count(),
		"organ": fixture.attack.nutrition, "organ_incoming": fixture.attack.incoming_nutrition,
		"blocker": fixture.blocker.nutrition, "blocker_incoming": fixture.blocker.incoming_nutrition,
		"stomach_incoming": fixture.stomach.incoming_remains,
		"stomach_queue": fixture.stomach.get_queued_nutrition(),
		"products": fixture.stomach.get_output_products(), "batches": batches,
		"carcass_remaining": fixture.carcass.get_remaining_nutrition(),
		"carcass_reserved": fixture.carcass.get_reserved_nutrition(),
		"carcass_harvested": fixture.carcass.get_harvested_nutrition(),
		"growth_consumed": int(growth.get("consumed_nutrition", 0)),
		"growth_buffer": int(growth.get("buffered_nutrition", 0)),
		"growth_distance": float(growth.get("distance", 0.0)),
		"cultivation": cultivation, "transit": int(_service(fixture, kind).call("get_in_transit_count")),
	}


func _growth_transit(fixture: Fixture) -> int:
	var amount: int = 0
	for record: Dictionary in fixture.growth_supply.get_shipment_records():
		if bool(record["debited"]) and not bool(record["settled"]) and not bool(record["refunded"]):
			amount += 1
	return amount


func _conservation(fixture: Fixture, phase: String) -> void:
	conservation_checks += 1
	var growth: Dictionary = fixture.growth.get_task_snapshot()
	var cultivation: Dictionary = fixture.cultivation.get_resource_snapshot()
	var ground_nutrition: int = 0
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and not child.is_queued_for_deletion():
			var remains: EnemyRemains = child as EnemyRemains
			ground_nutrition += remains.nutrition_value
			var batch_id: String = String(remains.get_meta("carcass_batch_id", ""))
			if not batch_id.is_empty():
				fixture.batch_ids[batch_id] = true
	var total: int = fixture.core.nutrition + fixture.attack.nutrition + fixture.blocker.nutrition \
		+ fixture.combat.get_in_transit_count() + _growth_transit(fixture) \
		+ fixture.cultivation_supply.get_in_transit_nutrition() \
		+ int(growth.get("consumed_nutrition", 0)) + int(growth.get("buffered_nutrition", 0)) \
		+ int(cultivation["structure_consumed"]) + int(cultivation["buffered_nutrition"]) \
		+ int(cultivation["startup_reserved"]) + fixture.carcass.get_remaining_nutrition() \
		+ ground_nutrition + fixture.stomach.get_queued_nutrition() + fixture.stomach.get_output_nutrition()
	_check(total == fixture.initial_total, phase + ": capital, claimed batches, outputs and paid construction conserve nutrition")
	_check(fixture.carcass.get_harvested_nutrition() <= 80 and fixture.batch_ids.size() <= 8,
		phase + ": reroutes cannot mint more than the original eight ten-unit batches")
	_check(fixture.stomach.get_queued_count() + fixture.stomach.incoming_remains <= 4 \
		and fixture.stomach.get_output_count() <= 2 and fixture.stomach.get_output_nutrition() <= 20,
		phase + ": original stomach and output limits hold")
	for edge: HyphaEdge in fixture.network.get_registered_edges():
		var traffic: Dictionary = fixture.traffic.get_edge_snapshot(edge)
		_check(edge.traffic_capacity == 2 and int(traffic.get("occupied_units", 0)) <= 2,
			phase + ": all cargo shares the unchanged two-unit edge capacity")


func _assert_arrival(fixture: Fixture, kind: String, packet: Node2D, original: Dictionary,
		before: Dictionary) -> void:
	var target: Node2D = original["final_target"] as Node2D
	var task_id: String = String(original["task_id"])
	_check(bool(packet.call("has_arrived_at", target, task_id)), kind + " commits arrival at the captured target and task")
	_check(not bool(packet.call("has_arrived_at", fixture.bypass, task_id)) \
		and not bool(packet.call("has_arrived_at", target, task_id + ":old")),
		kind + " rejects another target or transport task even after route replacement")
	_check(int(_service(fixture, kind).call("get_in_transit_count")) == 0, kind + " settles its original shipment once")
	match kind:
		"combat":
			_check(fixture.attack.nutrition == int(before["organ"]) + 1 \
				and fixture.attack.incoming_nutrition == 0 and fixture.core.nutrition == int(before["balance"]),
				"Combat receives one reserved unit without a second debit")
		"growth":
			var snapshot: Dictionary = fixture.growth.get_task_snapshot()
			_check(int(snapshot["consumed_nutrition"]) + int(snapshot["buffered_nutrition"]) == 1 \
				and fixture.core.nutrition == int(before["balance"]), "Growth owns exactly the one originally paid unit")
		"cultivation":
			var snapshot: Dictionary = fixture.cultivation.get_resource_snapshot()
			_check(int(snapshot["structure_consumed"]) + int(snapshot["buffered_nutrition"]) \
				+ int(snapshot["startup_reserved"]) == 1 and fixture.core.nutrition == int(before["balance"]),
				"Cultivation owns exactly one originally paid unit after rerouting")
		"remains":
			_check(fixture.stomach.get_queued_nutrition() == int(before["stomach_queue"]) + 10 \
				and fixture.stomach.incoming_remains == 0 and fixture.carcass.get_remaining_nutrition() == 70,
				"The original claimed batch enters the originally reserved stomach once")
		"return":
			_check(fixture.core.nutrition == int(before["balance"]) + 10 \
				and fixture.stomach.get_output_count() == 0 and fixture.received_ids.size() == 1,
				"The original product credits once and releases its original output slot")
	var after: Dictionary = _resources(fixture, kind)
	_replay(_callbacks_if_connected(packet, _service(fixture, kind)), packet)
	packet.emit_signal("arrived", packet)
	_check(_resources(fixture, kind) == after, kind + " terminal arrival replay cannot settle or credit twice")
	_conservation(fixture, kind + " delivered")


func _callbacks_if_connected(packet: Node2D, owner: Node) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(&"arrived"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _test_prestart_reentry(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var reentered: Array[bool] = [false]
	fixture.packets.child_entered_tree.connect(func(child: Node) -> void:
		reentered[0] = true
		child.emit_signal("arrived", child)
		fixture.network.network_changed.emit()
		_refresh_services(fixture)
	, CONNECT_ONE_SHOT)
	var packet: Node2D = _launch(fixture, kind)
	if packet != null:
		_check(reentered[0] and int(_service(fixture, kind).call("get_in_transit_count")) == 1,
			kind + " admission survives idle-packet sweep and fake arrival reentry")
		var original: Dictionary = _transport(packet)
		var before: Dictionary = _resources(fixture, kind)
		if _finish_real_packet(fixture, packet):
			_assert_arrival(fixture, kind, packet, original, before)
	cases.append({"kind": kind, "case": "prestart_reentry"})
	await _dispose(fixture)


func _test_capacity_queue(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var first: Node2D = _launch(fixture, "combat", fixture.blocker)
	var second: Node2D = _launch(fixture, "combat", fixture.blocker)
	var shared_edge: HyphaEdge = _entry_edge(fixture, kind)
	if first == null or second == null:
		await _dispose(fixture)
		return
	_reach_occupied_edge(fixture, first, shared_edge)
	_reach_occupied_edge(fixture, second, shared_edge)
	_check(int(fixture.traffic.get_edge_snapshot(shared_edge)["occupied_units"]) == 2,
		"Two paid real supplies occupy the entire shared bottleneck")
	var packet: Node2D = _launch(fixture, kind)
	if packet != null:
		_until(fixture, packet, func() -> bool: return _transport(packet).get("state") == &"waiting",
			kind + " waits behind the actual occupied capacity")
		var original: Dictionary = _transport(packet)
		var before: Dictionary = _resources(fixture, kind)
		for _step: int in range(5):
			_tick(fixture, packet)
		packet.emit_signal("arrived", packet)
		_check(_resources(fixture, kind) == before and int(_transport(packet)["reroute_count"]) == 0,
			kind + " capacity waiting retains reservations and never changes route or pays twice")
		first.call("cancel_transport")
		if kind == "remains":
			_tick(fixture, packet)
			_check(_transport(packet).get("state") == &"waiting",
				"Two-unit remains cannot enter a one-unit vacancy")
		second.call("cancel_transport")
		before = _resources(fixture, kind)
		if _finish_real_packet(fixture, packet):
			_assert_arrival(fixture, kind, packet, original, before)
	cases.append({"kind": kind, "case": "capacity_wait", "capacity": 2})
	await _dispose(fixture)


func _test_block_wait_and_bypass(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var packet: Node2D = _launch(fixture, kind)
	var occupied_edge: HyphaEdge = _entry_edge(fixture, kind)
	if not _reach_occupied_edge(fixture, packet, occupied_edge):
		await _dispose(fixture)
		return
	var original: Dictionary = _transport(packet)
	var callbacks: Array[Callable] = _callbacks(packet, _service(fixture, kind))
	var before: Dictionary = _resources(fixture, kind)
	_future_edge(fixture, kind).entry_enabled = false
	occupied_edge.entry_enabled = false
	for _step: int in range(5):
		_tick(fixture, packet)
	var blocked: Dictionary = _transport(packet)
	_check(blocked.get("state") == &"blocked" and blocked.get("token") == original.get("token") \
		and (blocked["position"] as Vector2).distance_to(original["position"] as Vector2) < 0.001,
		kind + " closes mid-edge without moving or replacing its occupied lease")
	_check(_resources(fixture, kind) == before, kind + " blocked cargo preserves every original ledger reservation")
	_replay(callbacks, packet)
	packet.emit_signal("arrived", packet)
	_check(_resources(fixture, kind) == before, kind + " fake blocked arrival neither delivers nor refunds")
	occupied_edge.entry_enabled = true
	_until(fixture, packet, func() -> bool:
		var snapshot: Dictionary = _transport(packet)
		return snapshot.get("state") == &"waiting" and snapshot.get("current_node") == fixture.middle,
		kind + " reaches the next node and waits for an available remaining route")
	fixture.network.unregister_edge(occupied_edge)
	if kind == "remains":
		fixture.field.set_sources([])
	for _step: int in range(5):
		_tick(fixture, packet)
	_check(_resources(fixture, kind) == before and _transport(packet).get("location_kind") == &"node" \
		and String(_transport(packet).get("token", "")).is_empty(),
		kind + " removing a traversed edge preserves the same node-held cargo without a lease")
	_replay(callbacks, packet)
	_check(_resources(fixture, kind) == before, kind + " fake no-route arrival keeps its original claim and payment")
	for edge: HyphaEdge in fixture.bypass_edges:
		edge.entry_enabled = true
	if _finish_real_packet(fixture, packet):
		_check(int(_transport(packet)["reroute_count"]) >= 1 and _transport(packet)["task_id"] == original["task_id"],
			kind + " bypass replaces the remaining route while retaining transport identity")
		_assert_arrival(fixture, kind, packet, original, before)
	cases.append({"kind": kind, "case": "blocked_no_route_bypass", "traversed_edge_removed": true})
	await _dispose(fixture)


func _assert_cancelled(fixture: Fixture, kind: String, before: Dictionary) -> void:
	_check(int(_service(fixture, kind).call("get_in_transit_count")) == 0,
		kind + " cancellation clears its original transit ledger")
	var paid: bool = kind == "combat" or kind == "growth" or kind == "cultivation"
	_check(fixture.core.nutrition == int(before["balance"]) + (1 if paid else 0),
		kind + " cancellation returns exactly the original debit and grants no product credit")
	_check(fixture.attack.incoming_nutrition == 0 and fixture.stomach.incoming_remains == 0,
		kind + " cancellation releases original receiving reservations")
	if kind == "return":
		_check(fixture.stomach.get_output_count() == 1 \
			and fixture.stomach.get_output_products()[0]["status"] == &"queued",
			"Cancelled return preserves the exact original product for a new attempt")
	if kind == "remains":
		var ground: int = 0
		for child: Node in fixture.remains.get_children():
			if child is EnemyRemains and not child.is_queued_for_deletion():
				ground += (child as EnemyRemains).nutrition_value
				_check((child as EnemyRemains).is_available(), "Cancelled cargo releases its existing batch claim")
		_check(ground == 10 and fixture.carcass.get_remaining_nutrition() == 70,
			"Cancellation drops the same committed ten-unit batch without restoring or mining source stock")
	_check(int(fixture.traffic.get_snapshot()["occupied_units"]) == 0,
		kind + " cancellation leaves no shared edge lease")
	_conservation(fixture, kind + " cancelled")


func _test_cancel_during_restore(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var packet: Node2D = _launch(fixture, kind)
	var edge: HyphaEdge = _entry_edge(fixture, kind)
	if not _reach_occupied_edge(fixture, packet, edge):
		await _dispose(fixture)
		return
	var callbacks: Array[Callable] = _callbacks(packet, _service(fixture, kind))
	var before: Dictionary = _resources(fixture, kind)
	edge.entry_enabled = false
	_tick(fixture, packet)
	edge.traffic_settings_changed.connect(func() -> void:
		_service(fixture, kind).call("reset")
	, CONNECT_ONE_SHOT)
	edge.entry_enabled = true
	_refresh_services(fixture)
	_assert_cancelled(fixture, kind, before)
	var settled: Dictionary = _resources(fixture, kind)
	_replay(callbacks, packet)
	packet.emit_signal("arrived", packet)
	_check(_resources(fixture, kind) == settled, kind + " restore/cancel race rejects every old arrival callback")
	cases.append({"kind": kind, "case": "cancel_during_restore"})
	await _dispose(fixture)


func _test_target_removal(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var packet: Node2D = _launch(fixture, kind)
	if packet != null:
		var original: Dictionary = _transport(packet)
		var callbacks: Array[Callable] = _callbacks(packet, _service(fixture, kind))
		var before: Dictionary = _resources(fixture, kind)
		var target: Node2D = original["final_target"] as Node2D
		target.queue_free()
		_tick(fixture, packet)
		_assert_cancelled(fixture, kind, before)
		var settled: Dictionary = _resources(fixture, kind)
		_replay(callbacks, packet)
		var arrived: bool = false
		if is_instance_valid(target):
			arrived = bool(packet.call("has_arrived_at", target, String(original["task_id"])))
		_check(_resources(fixture, kind) == settled and not arrived,
			kind + " removed target cannot receive even through stale callbacks")
	cases.append({"kind": kind, "case": "target_removed"})
	await _dispose(fixture)


func _test_reset_and_old_callbacks(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	await _prepare(fixture, kind)
	var old_packet: Node2D = _launch(fixture, kind)
	if old_packet == null:
		await _dispose(fixture)
		return
	var callbacks: Array[Callable] = _callbacks(old_packet, _service(fixture, kind))
	var old_transport: Dictionary = _transport(old_packet)
	var before: Dictionary = _resources(fixture, kind)
	_service(fixture, kind).call("reset")
	_assert_cancelled(fixture, kind, before)
	if kind == "growth":
		await _prepare(fixture, kind)
	elif kind == "cultivation":
		fixture.task_id = fixture.cultivation.continue_cultivation(fixture.host)
		_check(fixture.task_id > 0, "Restarted cultivation creates a new attempt on the original unpaid bud")
	var packet: Node2D = _launch(fixture, kind)
	if packet != null:
		var restarted: Dictionary = _resources(fixture, kind)
		var original: Dictionary = _transport(packet)
		_check(original["task_id"] != old_transport["task_id"], kind + " restart never reuses old transport identity")
		_replay(callbacks, old_packet)
		old_packet.emit_signal("arrived", old_packet)
		_check(_resources(fixture, kind) == restarted, kind + " old callbacks cannot deliver or refund its replacement shipment")
		if kind == "return":
			var record: Dictionary = fixture.returns.get_shipment_records().back()
			_check(String(record["product_id"]) == String((before["products"] as Array)[0]["product_id"]),
				"New return attempt references the existing immutable product")
		if _finish_real_packet(fixture, packet):
			_assert_arrival(fixture, kind, packet, original, restarted)
	cases.append({"kind": kind, "case": "restart_old_callbacks"})
	await _dispose(fixture)


func _test_receiver_reparenting(kind: String) -> void:
	var fixture: Fixture = _new_fixture()
	var packet: Node2D = _launch(fixture, kind)
	if packet != null:
		var original: Dictionary = _transport(packet)
		var callbacks: Array[Callable] = _callbacks(packet, _service(fixture, kind))
		var before: Dictionary = _resources(fixture, kind)
		var receiver: Node2D = fixture.attack if kind == "combat" else fixture.stomach
		# reparent 会先发出 tree_exiting；接收者离开原宿主即可合法取消，不必继续抵达。
		receiver.reparent(fixture.bypass, true)
		_refresh_services(fixture)
		_assert_cancelled(fixture, kind, before)
		var terminal: Dictionary = _transport(packet)
		_check(terminal.get("state") == &"interrupted" and bool(terminal.get("terminal", false)) \
			and terminal.get("final_target") == original["final_target"] \
			and terminal.get("final_target_id") == original["final_target_id"] \
			and terminal.get("task_id") == original["task_id"],
			kind + " receiver tree exit cancels exactly the original target and transport identity")
		_check(not bool(packet.call("has_arrived_at", original["final_target"], String(original["task_id"]))) \
			and not bool(packet.call("has_arrived_at", fixture.bypass, String(original["task_id"]))),
			kind + " reparenting cannot retarget an interrupted shipment or fabricate arrival")
		_check(fixture.attack.nutrition == int(before["organ"]) \
			and fixture.stomach.get_queued_nutrition() == int(before["stomach_queue"]),
			kind + " moved receiver receives no stock or queued nutrition")
		var settled: Dictionary = _resources(fixture, kind)
		if kind == "remains":
			var original_batches: Array = before["batches"] as Array
			var dropped_batches: Array = settled["batches"] as Array
			_check(original_batches.size() == 1 and dropped_batches.size() == 1 \
				and dropped_batches[0]["id"] == original_batches[0]["id"] \
				and dropped_batches[0]["nutrition"] == original_batches[0]["nutrition"] \
				and bool(dropped_batches[0]["available"]),
				"Receiver reparenting releases the exact existing batch without a new claim or duplicate batch")
		_replay(callbacks, packet)
		packet.emit_signal("arrived", packet)
		_check(_resources(fixture, kind) == settled,
			kind + " stale reparenting callbacks cannot deliver, refund or release a claim twice")
		_conservation(fixture, kind + " receiver reparenting")
	cases.append({"kind": kind, "case": "receiver_identity", "outcome": "cancelled_on_tree_exit"})
	await _dispose(fixture)


func _test_new_harvest_admission() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.carcass.global_position = fixture.host.global_position + Vector2(0, 80)
	fixture.field.set_sources([{"node": fixture.host, "kind": &"junction", "connected": true}])
	fixture.field.advance(1.0)
	var remains: EnemyRemains = REMAINS_SCENE.instantiate() as EnemyRemains
	fixture.remains.add_child(remains)
	remains.global_position = fixture.carcass.global_position
	fixture.initial_total += remains.nutrition_value
	fixture.main_edges[1].entry_enabled = false
	_check(not fixture.recycling.try_dispatch() and remains.is_available() \
		and fixture.carcass.get_remaining_nutrition() == 80 and fixture.stomach.incoming_remains == 0,
		"Stale field coverage cannot admit ground remains or a new batch through an unavailable collector")
	fixture.main_edges[1].entry_enabled = true
	fixture.stomach_edge.entry_enabled = false
	_check(not fixture.recycling.try_dispatch() and remains.is_available() \
		and fixture.carcass.get_remaining_nutrition() == 80 and fixture.stomach.incoming_remains == 0,
		"Available collector still needs an available two-unit path to the stomach before harvest admission")
	_conservation(fixture, "new harvest admission rejected")
	cases.append({"kind": "remains", "case": "available_harvest_admission"})
	await _dispose(fixture)


func _test_full_carcass_cycle() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.main_edges[1].entry_enabled = false
	for edge: HyphaEdge in fixture.bypass_edges:
		edge.entry_enabled = true
	for _batch: int in range(8):
		var remains_packet: Node2D = _launch(fixture, "remains")
		if not _finish_real_packet(fixture, remains_packet):
			break
		await _digest_one(fixture)
		var return_packet: Node2D = _launch(fixture, "return")
		if not _finish_real_packet(fixture, return_packet):
			break
		var after: Dictionary = _resources(fixture, "return")
		return_packet.emit_signal("arrived", return_packet)
		_check(_resources(fixture, "return") == after, "Repeated receipt cannot duplicate one of the eight original products")
	_check(fixture.core.nutrition == 152 and fixture.carcass.get_remaining_nutrition() == 0 \
		and fixture.carcass.get_harvested_nutrition() == 80 and fixture.batch_ids.size() == 8 \
		and fixture.produced_ids.size() == 8 and fixture.received_ids.size() == 8 \
		and fixture.core.get_received_product_count() == 8 and fixture.stomach.get_output_count() == 0,
		"Physical bypass harvest/digestion/return credits exactly the original eighty units with eight unique products")
	var unique: Dictionary[String, bool] = {}
	for product_id: String in fixture.received_ids:
		unique[product_id] = true
	_check(unique.size() == 8 and not fixture.recycling.try_dispatch(), "Exhausted source cannot mint a ninth batch or repeated product")
	_conservation(fixture, "full eighty-unit cycle")
	cases.append({"kind": "remains_return", "case": "full_carcass_cycle", "unique_products": unique.size()})
	await _dispose(fixture)


func _dispose(fixture: Fixture) -> void:
	fixture.combat.reset(true)
	fixture.growth_supply.reset()
	fixture.cultivation_supply.reset()
	fixture.recycling.reset(true)
	fixture.returns.reset()
	fixture.traffic.reset()
	fixture.world.queue_free()
	await process_frame
	await process_frame
