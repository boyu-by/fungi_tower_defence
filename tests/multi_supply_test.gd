extends SceneTree
## 独立夹具验证多器官调度，不依赖关卡、武器、HUD 或运行中的自动计时器。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const SUPPLY_SCENE: PackedScene = preload("res://scenes/systems/supply_system.tscn")

class Fixture:
	extends RefCounted

	var scene: Node2D
	var source: MotherCore
	var hub: Node2D
	var hosts: Array[Node2D] = []
	var organs: Array[AttackOrgan] = []
	var edges: Array[HyphaEdge] = []
	var network: NetworkSystem
	var packets: Node2D
	var supply: SupplySystem

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_root_children: int = root.get_child_count()
	await _test_registration_and_default_target()
	await _test_fair_scarce_replenishment()
	await _test_disconnected_and_full_targets()
	await _test_balance_capacity_and_duplicate_refund()
	await _test_synchronous_failed_branch()
	await _test_unregister_and_receiver_exit()
	await _test_queued_receiver_and_packet_removal()
	await _test_immutable_shipment_owners()
	await _test_legacy_direct_route()
	await _test_active_organs_query()
	await _test_freed_exported_configuration()
	await _test_same_node_route()
	await _test_supply_system_exit()
	_check(root.get_child_count() == initial_root_children, "Fixtures left orphan root nodes")
	print("MULTI_SUPPLY_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(organ_count: int = 2, balance: int = 72,
		local_stock: int = 0, use_network: bool = true) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.scene = Node2D.new()
	root.add_child(fixture.scene)
	fixture.source = CORE_SCENE.instantiate() as MotherCore
	fixture.source.initial_nutrition = balance
	fixture.scene.add_child(fixture.source)
	fixture.hub = Node2D.new()
	fixture.hub.position = Vector2(80.0, 0.0)
	fixture.scene.add_child(fixture.hub)
	fixture.network = NetworkSystem.new()
	fixture.scene.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.source, true), "Fixture core registration")
	_check(fixture.network.register_node(fixture.hub), "Fixture hub registration")
	fixture.edges.append(_new_edge(fixture.scene, fixture.source, fixture.hub))
	for index: int in range(organ_count):
		var host: Node2D = Node2D.new()
		host.position = Vector2(160.0, float(index) * 50.0 - 25.0)
		fixture.scene.add_child(host)
		var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
		organ.initial_nutrition = local_stock
		organ.refill_target = 3
		host.add_child(organ)
		fixture.hosts.append(host)
		fixture.organs.append(organ)
		_check(fixture.network.register_node(host), "Fixture host registration " + str(index))
		fixture.edges.append(_new_edge(fixture.scene, fixture.hub, host))
	for edge: HyphaEdge in fixture.edges:
		_check(fixture.network.register_edge(edge), "Fixture edge registration")
	fixture.packets = Node2D.new()
	fixture.scene.add_child(fixture.packets)
	fixture.supply = SUPPLY_SCENE.instantiate() as SupplySystem
	fixture.supply.mother_core = fixture.source
	fixture.supply.target_organ = fixture.organs[0]
	fixture.supply.packet_container = fixture.packets
	if use_network:
		fixture.supply.network_system = fixture.network
	else:
		fixture.supply.supply_edge = _new_edge(
			fixture.scene, fixture.source, fixture.hosts[0]
		)
	fixture.scene.add_child(fixture.supply)
	(fixture.supply.get_node("DispatchTimer") as Timer).stop()
	for organ: AttackOrgan in fixture.organs:
		_check(fixture.supply.register_organ(organ), "Fixture organ registration")
	return fixture


func _new_edge(parent: Node2D, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	parent.add_child(edge)
	return edge


func _wait_until_empty(fixture: Fixture) -> void:
	for frame: int in range(360):
		if fixture.supply.get_in_transit_count() == 0:
			break
		await physics_frame
	await process_frame
	await process_frame
	_check(fixture.supply.get_in_transit_count() == 0, "Transport timed out")
	_check(fixture.packets.get_child_count() == 0, "Finished packets remain in container")


func _remove_fixture(fixture: Fixture) -> void:
	fixture.scene.queue_free()
	await process_frame
	await process_frame
	_check(not is_instance_valid(fixture.scene), "Fixture teardown failed")


func _check_capacity(organ: AttackOrgan, context: String) -> void:
	_check(organ.nutrition >= 0 and organ.incoming_nutrition >= 0, context + ": negative stock")
	_check(organ.nutrition + organ.incoming_nutrition <= organ.capacity,
		context + ": capacity exceeded")


func _test_registration_and_default_target() -> void:
	var fixture: Fixture = _new_fixture(2, 10)
	var supply: SupplySystem = fixture.supply
	_check(supply.get_registered_organs().size() == 2, "Ready target was not registered")
	_check(supply.register_organ(fixture.organs[0]), "Duplicate registration was rejected")
	_check(supply.get_registered_organs().size() == 2, "Duplicate registration added an organ")
	_check(not supply.register_organ(null), "Null organ was registered")
	var outsider_host: Node2D = Node2D.new()
	fixture.scene.add_child(outsider_host)
	var outsider: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
	outsider.initial_nutrition = 0
	outsider_host.add_child(outsider)
	_check(not supply.request_supply(outsider), "Explicit unregistered receiver was accepted")
	_check(fixture.source.nutrition == 10 and outsider.incoming_nutrition == 0,
		"Unregistered request changed resources")
	_check(supply.register_organ(outsider), "Runtime registration failed")
	_check(supply.get_registered_organs().size() == 3, "Runtime registration missing")
	supply.unregister_organ(outsider)
	supply.target_organ = fixture.organs[1]
	_check(supply.request_supply(), "Configured default receiver was rejected")
	_check(fixture.organs[0].incoming_nutrition == 0
		and fixture.organs[1].incoming_nutrition == 1, "Default target was redirected")
	supply.unregister_organ(fixture.organs[1])
	_check(fixture.source.nutrition == 10, "Default target unregister did not refund")
	_check(supply.request_supply(), "Unregistered default did not use first registered organ")
	_check(fixture.organs[0].incoming_nutrition == 1, "First registered fallback was incorrect")
	await _wait_until_empty(fixture)
	_check(fixture.source.nutrition == 9 and fixture.organs[0].nutrition == 1,
		"Default fallback did not deliver")
	await _remove_fixture(fixture)


func _test_fair_scarce_replenishment() -> void:
	var fixture: Fixture = _new_fixture(2, 1)
	var route: NetworkRoute = fixture.network.find_route(fixture.source, fixture.hosts[0])
	_check(route.found and route.segments.size() == 2, "Fixture is not a multi-hop route")
	for tick: int in range(6):
		if tick > 0:
			fixture.source.add_nutrition(1)
		fixture.supply._on_dispatch_timer_timeout()
		var expected_first: int = ceili(float(tick + 1) / 2.0)
		var expected_second: int = floori(float(tick + 1) / 2.0)
		_check(fixture.organs[0].incoming_nutrition == expected_first
			and fixture.organs[1].incoming_nutrition == expected_second,
			"Scarce replenishment lost round-robin fairness at tick " + str(tick))
		_check(fixture.source.nutrition == 0, "Tick overdrew or failed to spend one nutrient")
		_check(fixture.supply.get_in_transit_count() == tick + 1,
			"Tick dispatched more than one successful packet")
		fixture.supply._on_dispatch_timer_timeout()
		_check(fixture.supply.get_in_transit_count() == tick + 1,
			"Zero balance dispatched another packet")
		_check_capacity(fixture.organs[0], "Fair first organ")
		_check_capacity(fixture.organs[1], "Fair second organ")
	await _wait_until_empty(fixture)
	_check(fixture.organs[0].nutrition == 3 and fixture.organs[1].nutrition == 3,
		"Multi-hop automatic deliveries did not replenish both organs")
	_check(fixture.supply.delivered_packets == 6 and fixture.supply.interrupted_packets == 0,
		"Fair deliveries had incorrect terminal counts")
	_check(fixture.source.nutrition + fixture.organs[0].nutrition
		+ fixture.organs[1].nutrition == 6, "Fair supply did not conserve scarce resources")
	await _remove_fixture(fixture)


func _test_disconnected_and_full_targets() -> void:
	var fixture: Fixture = _new_fixture(3, 8)
	fixture.network.unregister_edge(fixture.edges[1])
	fixture.supply.supply_edge = _new_edge(fixture.scene, fixture.source, fixture.hosts[0])
	_check(fixture.organs[2].reserve_nutrition(6), "Unable to prepare full third organ")
	_check(fixture.organs[2].complete_delivery(6), "Unable to fill third organ")
	_check(not fixture.supply.request_supply(), "Disconnected default target was redirected")
	_check(not fixture.supply.request_supply(fixture.organs[0]),
		"Configured disconnected network used the legacy edge")
	_check(fixture.source.nutrition == 8, "Disconnected rejection spent nutrition")
	for tick: int in range(3):
		fixture.supply._on_dispatch_timer_timeout()
		_check(fixture.organs[1].incoming_nutrition == tick + 1,
			"Disconnected or full target blocked a usable branch")
		_check(fixture.supply.get_in_transit_count() == tick + 1,
			"Automatic tick exceeded one successful dispatch")
	fixture.supply._on_dispatch_timer_timeout()
	_check(fixture.source.nutrition == 5 and fixture.supply.get_in_transit_count() == 3,
		"Automatic supply exceeded refill target")
	var active: Array[AttackOrgan] = fixture.supply.get_active_organs()
	_check(active.size() == 2 and active.has(fixture.organs[1]) and active.has(fixture.organs[2]),
		"Active query did not distinguish disconnected and full organs")
	await _wait_until_empty(fixture)
	_check(fixture.organs[0].nutrition == 0 and fixture.organs[1].nutrition == 3
		and fixture.organs[2].nutrition == 6, "Branch skipping changed the wrong inventory")
	await _remove_fixture(fixture)


func _test_balance_capacity_and_duplicate_refund() -> void:
	var fixture: Fixture = _new_fixture(2, 1)
	var supply: SupplySystem = fixture.supply
	_check(supply.request_supply(fixture.organs[0]), "First low-balance request failed")
	_check(not supply.request_supply(fixture.organs[1]), "Low balance accepted a second packet")
	_check(fixture.source.nutrition == 0 and fixture.organs[1].incoming_nutrition == 0,
		"Insufficient balance did not roll back capacity reservation")
	var packet: NutrientPacket = fixture.packets.get_child(0) as NutrientPacket
	packet.cancel_transport()
	packet.cancel_transport()
	# 重复信号和 tree_exiting 兜底均不能让同一运输再次结算。
	packet.interrupted.emit(packet)
	packet.arrived.emit(packet)
	_check(fixture.source.nutrition == 1 and fixture.organs[0].incoming_nutrition == 0,
		"Repeated terminal events refunded more than once")
	_check(supply.interrupted_packets == 1 and supply.delivered_packets == 0,
		"Repeated terminal events changed counters")
	await _wait_until_empty(fixture)
	fixture.source.add_nutrition(10)
	var original_scene: PackedScene = supply.packet_scene
	supply.packet_scene = ORGAN_SCENE
	_check(not supply.request_supply(fixture.organs[0]), "Incorrect packet scene was accepted")
	_check(fixture.source.nutrition == 11 and fixture.organs[0].incoming_nutrition == 0,
		"Incorrect packet scene changed resources")
	_check(fixture.packets.get_child_count() == 0, "Incorrect packet scene leaked a node")
	supply.packet_scene = original_scene
	for request: int in range(6):
		_check(supply.request_supply(fixture.organs[0]), "Manual supply failed before capacity")
		_check_capacity(fixture.organs[0], "Manual capacity request " + str(request))
	_check(not supply.request_supply(fixture.organs[0]), "Capacity accepted a seventh nutrient")
	_check(fixture.source.nutrition == 5 and fixture.organs[0].incoming_nutrition == 6,
		"Manual capacity included neither stock nor incoming correctly")
	await _wait_until_empty(fixture)
	_check(fixture.organs[0].nutrition == 6, "Manual supply stopped at automatic refill target")
	_check(fixture.source.nutrition + fixture.organs[0].nutrition == 11,
		"Capacity and rollback did not conserve resources")
	await _remove_fixture(fixture)


func _test_synchronous_failed_branch() -> void:
	var fixture: Fixture = _new_fixture(2, 3)
	var callback: Callable = _break_branch_on_debit.bind(fixture.network, fixture.edges[1])
	fixture.source.nutrition_changed.connect(callback)
	fixture.supply._on_dispatch_timer_timeout()
	fixture.source.nutrition_changed.disconnect(callback)
	_check(fixture.supply.interrupted_packets == 0, "A newly unavailable future route is waiting, not failure")
	_check(fixture.source.nutrition == 2 and fixture.supply.get_in_transit_count() == 1,
		"Route loss preserves exactly the first packet's debit")
	_check(fixture.organs[0].incoming_nutrition == 1
		and fixture.organs[1].incoming_nutrition == 0, "Waiting branch retains its own reservation")
	var waiting: NutrientPacket = fixture.packets.get_child(0) as NutrientPacket
	waiting.cancel_transport()
	_check(fixture.source.nutrition == 3 and fixture.organs[0].incoming_nutrition == 0
		and fixture.supply.interrupted_packets == 1, "Explicit cancellation refunds the waiting branch once")
	fixture.supply._on_dispatch_timer_timeout()
	await _wait_until_empty(fixture)
	_check(fixture.organs[1].nutrition == 1 and fixture.supply.delivered_packets == 1,
		"Valid branch after synchronous rejection failed to deliver")
	await _remove_fixture(fixture)


func _break_branch_on_debit(_balance: int, network: NetworkSystem, edge: HyphaEdge) -> void:
	network.unregister_edge(edge)


func _test_unregister_and_receiver_exit() -> void:
	var fixture: Fixture = _new_fixture(2, 10)
	var supply: SupplySystem = fixture.supply
	_check(supply.request_supply(fixture.organs[0]), "First unregister fixture dispatch")
	_check(supply.request_supply(fixture.organs[0]), "Second unregister fixture dispatch")
	_check(supply.request_supply(fixture.organs[1]), "Other unregister fixture dispatch")
	var packet: NutrientPacket = fixture.packets.get_child(0) as NutrientPacket
	supply.unregister_organ(fixture.organs[0])
	supply.unregister_organ(fixture.organs[0])
	packet.cancel_transport()
	packet.arrived.emit(packet)
	_check(fixture.source.nutrition == 9 and supply.get_in_transit_count() == 1,
		"Unregister did not cancel only its own pending shipments")
	_check(fixture.organs[0].incoming_nutrition == 0
		and fixture.organs[1].incoming_nutrition == 1, "Unregister changed another reservation")
	_check(supply.interrupted_packets == 2, "Duplicate unregister or cancellation refunded twice")
	_check(supply.get_registered_organs().size() == 1, "Unregistered organ remained registered")
	_check(not supply.request_supply(fixture.organs[0]), "Unregistered explicit target dispatched")
	await _wait_until_empty(fixture)
	_check(supply.register_organ(fixture.organs[0]), "Removed registration could not be restored")
	_check(supply.request_supply(), "Restored configured target could not dispatch")
	var removed: AttackOrgan = fixture.organs[0]
	fixture.hosts[0].remove_child(removed)
	_check(supply.get_in_transit_count() == 0 and removed.incoming_nutrition == 0,
		"Receiver tree exit did not cancel promptly")
	_check(fixture.source.nutrition == 9 and supply.interrupted_packets == 3,
		"Receiver tree exit refunded incorrectly")
	removed.free()
	await _wait_until_empty(fixture)
	_check(supply.request_supply(fixture.organs[1]), "Host removal fixture dispatch failed")
	fixture.hosts[1].queue_free()
	await process_frame
	await process_frame
	_check(fixture.source.nutrition == 9 and supply.get_in_transit_count() == 0,
		"Host removal did not refund its original source")
	_check(supply.get_registered_organs().is_empty() and supply.interrupted_packets == 4,
		"Host removal did not deregister its organ exactly once")
	await _remove_fixture(fixture)


func _test_queued_receiver_and_packet_removal() -> void:
	var fixture: Fixture = _new_fixture(2, 10)
	_check(fixture.supply.request_supply(fixture.organs[0]), "Queued receiver dispatch failed")
	_check(fixture.supply.request_supply(fixture.organs[1]), "Forced removal dispatch failed")
	(fixture.packets.get_child(0) as NutrientPacket).queue_free()
	fixture.organs[0].queue_free()
	_check(not fixture.supply.register_organ(fixture.organs[0]), "Queued organ registered again")
	_check(fixture.supply.get_registered_organs().size() == 1,
		"Queued receiver remained in registered query")
	_check(fixture.source.nutrition == 9 and fixture.supply.get_in_transit_count() == 1,
		"Queued receiver query did not promptly cancel its shipment")
	fixture.supply.get_registered_organs()
	_check(fixture.source.nutrition == 9 and fixture.supply.interrupted_packets == 1,
		"Repeated pruning refunded a queued receiver twice")
	(fixture.packets.get_child(1) as NutrientPacket).queue_free()
	await _wait_until_empty(fixture)
	_check(fixture.source.nutrition == 10 and fixture.supply.interrupted_packets == 2,
		"Packet exit and receiver exit double-refunded or lost nutrition")
	_check(fixture.organs[1].nutrition == 0 and fixture.organs[1].incoming_nutrition == 0,
		"Forced packet removal delivered or retained its reservation")
	await _remove_fixture(fixture)


func _test_immutable_shipment_owners() -> void:
	var fixture: Fixture = _new_fixture(2, 10)
	var other_source: MotherCore = CORE_SCENE.instantiate() as MotherCore
	other_source.initial_nutrition = 22
	other_source.position = Vector2(0.0, 80.0)
	fixture.scene.add_child(other_source)
	_check(fixture.supply.request_supply(fixture.organs[0]), "Ownership fixture dispatch failed")
	fixture.supply.mother_core = other_source
	fixture.supply.target_organ = fixture.organs[1]
	var other_network: NetworkSystem = NetworkSystem.new()
	fixture.scene.add_child(other_network)
	fixture.supply.network_system = other_network
	await _wait_until_empty(fixture)
	_check(fixture.source.nutrition == 9 and fixture.organs[0].nutrition == 1,
		"Reconfiguration changed original delivery owners or route network")
	_check(other_source.nutrition == 22 and fixture.organs[1].nutrition == 0,
		"Reconfiguration redirected an existing shipment")
	fixture.supply.network_system = fixture.network
	_check(not fixture.supply.request_supply(), "Unregistered replacement source dispatched")
	fixture.supply.mother_core = fixture.source
	_check(fixture.supply.request_supply(fixture.organs[0]), "Refund ownership fixture dispatch")
	fixture.supply.mother_core = other_source
	var packet: NutrientPacket = fixture.packets.get_child(0) as NutrientPacket
	packet.cancel_transport()
	packet.cancel_transport()
	await _wait_until_empty(fixture)
	_check(fixture.source.nutrition == 9 and other_source.nutrition == 22,
		"Cancellation refunded the reconfigured source instead of original source")
	_check(fixture.organs[0].nutrition == 1 and fixture.organs[0].incoming_nutrition == 0,
		"Ownership cancellation changed delivered stock")
	_check(fixture.network.register_node(other_source), "New source network registration failed")
	var source_edge: HyphaEdge = _new_edge(fixture.scene, other_source, fixture.hub)
	_check(fixture.network.register_edge(source_edge), "New source edge registration failed")
	_check(fixture.supply.request_supply(), "Connected replacement source did not dispatch")
	await _wait_until_empty(fixture)
	_check(other_source.nutrition == 21 and fixture.organs[1].nutrition == 1,
		"New shipment did not use new configuration")
	_check(fixture.source.nutrition + other_source.nutrition
		+ fixture.organs[0].nutrition + fixture.organs[1].nutrition == 32,
		"Source ownership changes did not conserve resources")
	await _remove_fixture(fixture)


func _test_legacy_direct_route() -> void:
	var fixture: Fixture = _new_fixture(1, 4, 0, false)
	_check(fixture.supply.get_registered_organs().size() == 1,
		"Legacy configured target was not auto-registered")
	_check(fixture.supply.get_active_organs().size() == 1, "Legacy direct route was not active")
	for request: int in range(4):
		_check(fixture.supply.request_supply(), "Legacy manual dispatch failed " + str(request))
	_check(not fixture.supply.request_supply(), "Empty legacy source dispatched")
	_check(fixture.source.nutrition == 0 and fixture.organs[0].incoming_nutrition == 4,
		"Legacy balance rollback changed reservations")
	await _wait_until_empty(fixture)
	_check(fixture.organs[0].nutrition == 4 and fixture.supply.delivered_packets == 4,
		"Legacy route did not preserve direct delivery")
	fixture.source.add_nutrition(1)
	fixture.supply.supply_edge.start_node = fixture.hosts[0]
	fixture.supply.supply_edge.end_node = fixture.source
	_check(not fixture.supply.request_supply(), "Legacy route accepted mismatched directed endpoints")
	_check(fixture.supply.get_active_organs().is_empty(), "Mismatched legacy route remained active")
	_check(fixture.source.nutrition == 1, "Invalid legacy route spent nutrition")
	await _remove_fixture(fixture)


func _test_active_organs_query() -> void:
	var fixture: Fixture = _new_fixture(3, 0, 6)
	fixture.network.unregister_edge(fixture.edges[3])
	fixture.organs[1].process_mode = Node.PROCESS_MODE_DISABLED
	fixture.supply.packet_scene = null
	fixture.supply.packet_container = null
	var active: Array[AttackOrgan] = fixture.supply.get_active_organs()
	_check(fixture.supply.get_registered_organs().size() == 3,
		"Active query removed paused or disconnected registrations")
	_check(active.size() == 1 and active[0] == fixture.organs[0],
		"Active query must use processing, core life and reachability")
	_check(fixture.source.nutrition == 0 and fixture.organs[0].nutrition == 6,
		"Active query depended on balance, capacity or packet configuration")
	_check(fixture.organs[0].incoming_nutrition == 0
		and fixture.supply.get_in_transit_count() == 0, "Active query reserved or dispatched nutrition")
	fixture.organs[1].process_mode = Node.PROCESS_MODE_INHERIT
	_check(fixture.supply.get_active_organs().size() == 2, "Reenabled organ did not become active")
	paused = true
	_check(fixture.supply.get_active_organs().is_empty(), "Paused organs were treated as processable")
	paused = false
	fixture.source.take_damage(fixture.source.max_health)
	_check(fixture.supply.get_active_organs().is_empty(), "Dead mother core retained active organs")
	fixture.source.queue_free()
	_check(fixture.supply.get_active_organs().is_empty(), "Queued mother core retained active organs")
	await _remove_fixture(fixture)


func _test_freed_exported_configuration() -> void:
	var fixture: Fixture = _new_fixture(2, 10)
	fixture.organs[0].free()
	_check(not is_instance_valid(fixture.supply.target_organ),
		"Default target was not fully freed before testing stale configuration")
	_check(fixture.supply.get_registered_organs().size() == 1,
		"Freed default target remained registered")
	_check(fixture.supply.get_active_organs().size() == 1,
		"Freed default target blocked another active organ")
	_check(fixture.supply.request_supply(), "Freed default target did not use live fallback")
	await _wait_until_empty(fixture)
	_check(fixture.source.nutrition == 9 and fixture.organs[1].nutrition == 1,
		"Freed default target redirected or lost fallback delivery")
	fixture.source.free()
	_check(not is_instance_valid(fixture.supply.mother_core),
		"Mother core was not fully freed before testing stale configuration")
	_check(fixture.supply.get_active_organs().is_empty(), "Freed mother core retained active organs")
	_check(not fixture.supply.request_supply(), "Freed mother core allowed default dispatch")
	_check(fixture.supply.get_registered_organs().size() == 1
		and fixture.organs[1].nutrition == 1 and fixture.organs[1].incoming_nutrition == 0,
		"Freed mother core query changed the remaining organ")
	var replacement: MotherCore = CORE_SCENE.instantiate() as MotherCore
	replacement.initial_nutrition = 5
	fixture.scene.add_child(replacement)
	_check(fixture.network.register_node(replacement, true), "Replacement core registration failed")
	var edge: HyphaEdge = _new_edge(fixture.scene, replacement, fixture.hub)
	_check(fixture.network.register_edge(edge), "Replacement core route registration failed")
	fixture.supply.mother_core = replacement
	_check(fixture.supply.get_active_organs().size() == 1,
		"Live replacement core did not restore the remaining active organ")
	_check(fixture.supply.request_supply(), "Stale default target blocked replacement core delivery")
	await _wait_until_empty(fixture)
	_check(replacement.nutrition == 4 and fixture.organs[1].nutrition == 2,
		"Replacement core did not supply the remaining live organ")
	await _remove_fixture(fixture)


func _test_same_node_route() -> void:
	var fixture: Fixture = _new_fixture(1, 3)
	var same_node_organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
	same_node_organ.initial_nutrition = 0
	fixture.source.add_child(same_node_organ)
	_check(fixture.supply.register_organ(same_node_organ), "Same-node organ registration failed")
	_check(fixture.supply.get_active_organs().has(same_node_organ), "Zero-edge route was not active")
	_check(fixture.supply.request_supply(same_node_organ), "Zero-edge delivery was reported rejected")
	await _wait_until_empty(fixture)
	_check(fixture.source.nutrition == 2 and same_node_organ.nutrition == 1
		and same_node_organ.incoming_nutrition == 0, "Zero-edge route did not settle correctly")
	_check(fixture.supply.delivered_packets == 1 and fixture.supply.interrupted_packets == 0,
		"Zero-edge terminal event was duplicated")
	await _remove_fixture(fixture)


func _test_supply_system_exit() -> void:
	var fixture: Fixture = _new_fixture(2, 10)
	_check(fixture.supply.request_supply(fixture.organs[0]), "Supply exit first dispatch failed")
	_check(fixture.supply.request_supply(fixture.organs[1]), "Supply exit second dispatch failed")
	fixture.scene.remove_child(fixture.supply)
	_check(fixture.source.nutrition == 10 and fixture.supply.get_in_transit_count() == 0,
		"Supply system exit did not refund pending shipments")
	_check(fixture.organs[0].incoming_nutrition == 0
		and fixture.organs[1].incoming_nutrition == 0, "Supply exit retained reservations")
	_check(fixture.supply.interrupted_packets == 2, "Supply exit settled shipments more than once")
	await process_frame
	await process_frame
	_check(fixture.packets.get_child_count() == 0, "Supply exit left packets outside system")
	fixture.supply.free()
	await _remove_fixture(fixture)
