extends SceneTree
## 独立夹具验证场域采集、网络运输和唯一资源所有权；不依赖关卡或 HUD。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const SYSTEM_SCENE: PackedScene = preload("res://scenes/systems/recycling_system.tscn")
const POSITION_EPSILON: float = 0.01

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var source: HyphaNode
	var relay: HyphaNode
	var receiver_node: HyphaNode
	var receiver: DigestiveOrgan
	var core_edge: HyphaEdge
	var relay_edge: HyphaEdge
	var source_edge: HyphaEdge
	var network: NetworkSystem
	var field: FungalField
	var system: RecyclingSystem
	var remains: Node2D
	var packets: Node2D
	var return_system: NutritionReturnSystem


## 有意拒绝一个候选的目的地查询，模拟候选查询间路线发生变化。
## 母核连通性查询仍使用真实网络，验证不能在首个候选失败时提前放弃。
class SelectiveNetwork:
	extends NetworkSystem

	var rejected_start: Node2D
	var rejected_end: Node2D
	var reject_as_invalid: bool = false

	func find_route(start: Node2D, end: Node2D) -> NetworkRoute:
		var route: NetworkRoute = super.find_route(start, end)
		if not reject_as_invalid and start == rejected_start and end == rejected_end:
			route.found = false
			route.segments.clear()
		return route

	# 6.4 新采集使用可用路线，候选失败替身保持相同拒绝条件。
	func find_available_route(start: Node2D, end: Node2D, units: int = 1) -> NetworkRoute:
		var route: NetworkRoute = super.find_available_route(start, end, units)
		if not reject_as_invalid and start == rejected_start and end == rejected_end:
			route.found = false
			route.segments.clear()
		return route

	func is_route_valid(route: NetworkRoute) -> bool:
		if reject_as_invalid and route != null and (
			route.start_node == rejected_start and route.end_node == rejected_end
		):
			return false
		return super.is_route_valid(route)


var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	await _test_field_expansion_and_delayed_income()
	await _test_overlap_competition_and_order()
	await _test_reservation_claim_race()
	await _test_reverse_route_and_ground_pickup()
	await _test_candidate_fallback()
	await _test_zero_edge_and_mother_core_pickup()
	await _test_capacity_and_digestion_connection()
	await _test_shared_receiver_removal()
	await _test_no_route_and_reconnection()
	await _test_break_cancel_and_packet_removal()
	await _test_receiver_snapshot_and_owner_removal()
	await _test_freed_receiver_rejects_dispatch()
	await _test_system_exit_and_startup_invalidation()
	await _test_invalid_packet_scene()
	print("FIELD_HARVEST_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(network_override: NetworkSystem = null) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.network = network_override if network_override != null else NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.field = FungalField.new()
	fixture.field.expansion_speed = 100.0
	fixture.world.add_child(fixture.field)
	fixture.field.set_process(false)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.world.add_child(fixture.core)
	fixture.core.global_position = Vector2.ZERO
	_check(fixture.network.register_node(fixture.core, true), "Fixture core registration failed")
	fixture.receiver_node = _add_node(fixture, Vector2(140.0, 0.0))
	fixture.relay = _add_node(fixture, Vector2(280.0, 0.0))
	fixture.source = _add_node(fixture, Vector2(420.0, 0.0))
	fixture.core_edge = _add_edge(fixture, fixture.core, fixture.receiver_node)
	fixture.relay_edge = _add_edge(fixture, fixture.receiver_node, fixture.relay)
	fixture.source_edge = _add_edge(fixture, fixture.relay, fixture.source)
	fixture.receiver = _add_receiver(fixture, fixture.receiver_node)
	fixture.receiver.core_edge = fixture.core_edge
	fixture.remains = Node2D.new()
	fixture.world.add_child(fixture.remains)
	fixture.packets = Node2D.new()
	fixture.world.add_child(fixture.packets)
	fixture.system = _add_system(fixture)
	var return_packets := Node2D.new()
	fixture.world.add_child(return_packets)
	fixture.return_system = NutritionReturnSystem.new()
	fixture.return_system.digestive_organ = fixture.receiver
	fixture.return_system.mother_core = fixture.core
	fixture.return_system.network_system = fixture.network
	fixture.return_system.packet_container = return_packets
	fixture.return_system.auto_return = false
	fixture.world.add_child(fixture.return_system)
	fixture.field.set_sources([
		{"node": fixture.core, "kind": &"core", "connected": true, "radius": 80.0},
		{"node": fixture.receiver_node, "kind": &"junction", "connected": true, "radius": 90.0},
		{"node": fixture.relay, "kind": &"junction", "connected": true, "radius": 90.0},
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 90.0},
	])
	fixture.field.advance(1.0)
	return fixture


func _add_node(fixture: Fixture, world_position: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.world.add_child(node)
	node.global_position = world_position
	_check(fixture.network.register_node(node), "Fixture junction registration failed")
	return node


func _add_edge(fixture: Fixture, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	fixture.world.add_child(edge)
	_check(fixture.network.register_edge(edge), "Fixture edge registration failed")
	return edge


func _add_receiver(fixture: Fixture, parent_node: Node2D) -> DigestiveOrgan:
	var receiver: DigestiveOrgan = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	receiver.mother_core = fixture.core
	parent_node.add_child(receiver)
	receiver.digest_timer.wait_time = 120.0
	receiver.digest_timer.stop()
	return receiver


func _add_system(fixture: Fixture) -> RecyclingSystem:
	var system: RecyclingSystem = SYSTEM_SCENE.instantiate() as RecyclingSystem
	system.network_system = fixture.network
	system.fungal_field = fixture.field
	system.digestive_organ = fixture.receiver
	system.remains_container = fixture.remains
	system.packet_container = fixture.packets
	fixture.world.add_child(system)
	var dispatch_timer: Timer = system.get_node("DispatchTimer") as Timer
	dispatch_timer.stop()
	return system


func _add_remains(fixture: Fixture, world_position: Vector2, nutrition: int = 4) -> EnemyRemains:
	var remains: EnemyRemains = REMAINS_SCENE.instantiate() as EnemyRemains
	remains.nutrition_value = nutrition
	fixture.remains.add_child(remains)
	remains.global_position = world_position
	return remains


func _return_outputs(fixture: Fixture) -> void:
	fixture.return_system.auto_return = true
	for frame in range(600):
		if fixture.receiver.get_output_count() == 0 and fixture.return_system.get_in_transit_count() == 0:
			break
		await physics_frame
	await _wait_frames(2)
	fixture.return_system.auto_return = false
	_check(fixture.receiver.get_output_count() == 0, "Retained output arrives through real return transport")


func _first_packet(fixture: Fixture) -> RemainsPacket:
	_check(fixture.packets.get_child_count() > 0, "Expected an active remains packet")
	if fixture.packets.get_child_count() == 0:
		return null
	return fixture.packets.get_child(0) as RemainsPacket


func _wait_frames(count: int) -> void:
	for _frame: int in range(count):
		await physics_frame
	await process_frame


func _wait_for_transport(fixture: Fixture) -> void:
	for _frame: int in range(900):
		if fixture.system.get_in_transit_count() == 0 and fixture.packets.get_child_count() == 0:
			break
		await physics_frame
	await process_frame
	await process_frame
	_check(fixture.system.get_in_transit_count() == 0, "Remains transport timed out")
	_check(fixture.packets.get_child_count() == 0, "Terminal transport left a packet")


func _dispose_fixture(fixture: Fixture) -> void:
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _test_field_expansion_and_delayed_income() -> void:
	var fixture: Fixture = _new_fixture()
	var death_position: Vector2 = fixture.source.global_position + Vector2(130.0, 0.0)
	var remains: EnemyRemains = _add_remains(fixture, death_position)
	_check(not fixture.field.is_covered(death_position), "Outside-field fixture was covered")
	_check(not fixture.system.try_dispatch(), "Outside field used a legacy pickup radius")
	_check(remains.is_available() and remains.visible and remains.global_position == death_position,
		"Outside-field wait changed the corpse")
	_check(fixture.receiver.incoming_remains == 0 and fixture.packets.get_child_count() == 0,
		"Outside-field wait reserved capacity or created a packet")
	fixture.field.set_sources([
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 160.0},
	])
	fixture.field.advance(0.2)
	_check(not fixture.system.try_dispatch(), "Pickup ran ahead of the expanded field")
	fixture.field.advance(0.3)
	_check(fixture.field.is_covered(death_position) and fixture.system.try_dispatch(),
		"Expanded field did not enable corpse collection")
	_check(not remains.is_available() and not remains.visible and fixture.receiver.incoming_remains == 1,
		"Pickup did not claim and reserve exactly once")
	_check(not fixture.system.try_dispatch(), "Claimed corpse was dispatched twice")
	_check(fixture.core.nutrition == 72 and fixture.receiver.get_queued_count() == 0,
		"Pickup credited income or queued a corpse before arrival")
	remains.nutrition_value = 99
	fixture.field.set_sources([])
	await _wait_for_transport(fixture)
	_check(not is_instance_valid(remains), "Delivered original corpse was not removed")
	_check(fixture.system.delivered_count == 1 and fixture.system.interrupted_count == 0,
		"Transport required field coverage after pickup")
	_check(fixture.receiver.incoming_remains == 0 and fixture.receiver.get_queued_nutrition() == 4,
		"Arrival failed to use the reserved slot and nutrition snapshot")
	_check(fixture.core.nutrition == 72, "Arrival bypassed digestion")
	fixture.receiver.digest_timer.start(0.05)
	await _wait_frames(12)
	_check(fixture.core.nutrition == 72 and fixture.receiver.digested_count == 1
		and fixture.receiver.get_output_nutrition() == 4,
		"Digestion keeps original value as uncredited output")
	await _return_outputs(fixture)
	await _wait_frames(12)
	_check(fixture.core.nutrition == 76 and fixture.system.delivered_count == 1,
		"A terminal callback or digestion credited the resource twice")
	await _dispose_fixture(fixture)


func _test_overlap_competition_and_order() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.field.set_sources([
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 180.0},
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 180.0},
		{"node": fixture.relay, "kind": &"junction", "connected": true, "radius": 180.0},
	])
	fixture.field.advance(2.0)
	var first: EnemyRemains = _add_remains(fixture, Vector2(350.0, 0.0))
	var other: RecyclingSystem = _add_system(fixture)
	_check(fixture.field.get_collecting_nodes(first.global_position).size() == 2,
		"Overlapping snapshots did not produce deduplicated candidates")
	_check(fixture.system.try_dispatch() and not other.try_dispatch(),
		"Competing systems both claimed the same corpse")
	_check(fixture.receiver.incoming_remains == 1 and fixture.packets.get_child_count() == 1,
		"Overlap created multiple reservations or packets")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	packet.cancel_transport()
	packet.cancel_transport()
	await _wait_for_transport(fixture)
	var second: EnemyRemains = _add_remains(fixture, Vector2(340.0, 0.0))
	_check(fixture.system.try_dispatch() and not first.is_available() and second.is_available(),
		"Dispatch did not follow stable corpse container order")
	_check(other.try_dispatch() and not second.is_available() and not fixture.system.try_dispatch(),
		"One successful dispatch claimed more than one corpse")
	_check(fixture.receiver.incoming_remains == 2 and fixture.packets.get_child_count() == 2,
		"Competing systems did not share capacity accurately")
	await _wait_for_transport(fixture)
	_check(other.get_in_transit_count() == 0 and fixture.receiver.get_queued_nutrition() == 8,
		"Competing systems lost or duplicated delivered nutrition")
	_check(fixture.system.delivered_count + other.delivered_count == 2 and
		fixture.system.interrupted_count == 1, "Competing systems settled a shipment twice")
	_check(fixture.core.nutrition == 72, "Competing transport produced early income")
	await _dispose_fixture(fixture)


func _test_reservation_claim_race() -> void:
	var fixture: Fixture = _new_fixture()
	var other: RecyclingSystem = _add_system(fixture)
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position)
	var attempted: Array[bool] = [false]
	var other_started: Array[bool] = [false]
	var race_for_claim: Callable = func(_queued: int, incoming: int) -> void:
		if incoming == 1 and not attempted[0]:
			attempted[0] = true
			other_started[0] = other.try_dispatch()
	fixture.receiver.inventory_changed.connect(race_for_claim)
	var outer_started: bool = fixture.system.try_dispatch()
	fixture.receiver.inventory_changed.disconnect(race_for_claim)
	_check(not outer_started and other_started[0] and not remains.is_available(),
		"Reservation signal allowed both systems to claim the same corpse")
	_check(fixture.receiver.incoming_remains == 1 and fixture.packets.get_child_count() == 1 and
		fixture.system.get_in_transit_count() == 0 and other.get_in_transit_count() == 1,
		"Failed claim did not release only its own reservation")
	await _wait_for_transport(fixture)
	_check(other.delivered_count == 1 and fixture.system.delivered_count == 0 and
		fixture.receiver.incoming_remains == 0 and fixture.receiver.get_queued_nutrition() == 4,
		"Claim race lost or duplicated nutrition")
	await _dispose_fixture(fixture)


func _test_reverse_route_and_ground_pickup() -> void:
	var fixture: Fixture = _new_fixture()
	var route: NetworkRoute = fixture.network.find_route(fixture.source, fixture.receiver_node)
	_check(route.found and route.segments.size() == 2 and fixture.network.is_route_valid(route),
		"Multi-hop fixture did not provide a valid route")
	if route.segments.size() == 2:
		_check(route.segments[0].edge == fixture.source_edge and not route.segments[0].forward and
			route.segments[1].edge == fixture.relay_edge and not route.segments[1].forward,
			"Return route lost its reverse direction or ordered segments")
	var death_position: Vector2 = fixture.source.global_position + Vector2(0.0, 64.0)
	var remains: EnemyRemains = _add_remains(fixture, death_position, 7)
	_check(fixture.system.try_dispatch(), "Multi-hop pickup was rejected")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	_check(packet.global_position.distance_to(death_position) < POSITION_EPSILON,
		"Packet teleported from the ground to its route start")
	await _wait_frames(2)
	_check(absf(packet.global_position.x - fixture.source.global_position.x) < POSITION_EPSILON and
		packet.global_position.y > 0.0 and packet.global_position.y < death_position.y,
		"Ground pickup did not approach the route start before network travel")
	await _wait_for_transport(fixture)
	_check(not is_instance_valid(remains) and fixture.receiver.get_queued_nutrition() == 7,
		"Reverse multi-hop transport did not deliver the original payload")
	_check(fixture.core.nutrition == 72, "Reverse route delivery bypassed digestion")
	await _dispose_fixture(fixture)


func _test_candidate_fallback() -> void:
	var network: SelectiveNetwork = SelectiveNetwork.new()
	var fixture: Fixture = _new_fixture(network)
	network.rejected_start = fixture.source
	network.rejected_end = fixture.receiver_node
	fixture.field.set_sources([
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 90.0},
		{"node": fixture.relay, "kind": &"junction", "connected": true, "radius": 180.0},
	])
	fixture.field.advance(2.0)
	for rejection: int in range(2):
		network.reject_as_invalid = rejection == 1
		var death_position: Vector2 = Vector2(390.0, 0.0)
		var remains: EnemyRemains = _add_remains(fixture, death_position)
		var candidates: Array[Node2D] = fixture.field.get_collecting_nodes(death_position)
		_check(candidates.size() == 2 and candidates[0] == fixture.source and
			network.is_connected_to_core(fixture.source), "Fallback fixture lacks the first candidate")
		_check(fixture.system.try_dispatch(), "First failed candidate prevented a valid fallback")
		var packet: RemainsPacket = _first_packet(fixture)
		if packet == null:
			await _dispose_fixture(fixture)
			return
		await _wait_frames(2)
		_check(packet.global_position.x < death_position.x,
			"Fallback transport picked the rejected nearest source")
		await _wait_for_transport(fixture)
		_check(not is_instance_valid(remains) and fixture.system.delivered_count == rejection + 1,
			"Fallback did not produce one delivery")
	await _dispose_fixture(fixture)


func _test_zero_edge_and_mother_core_pickup() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.field.set_sources([
		{"node": fixture.receiver_node, "kind": &"junction", "connected": true, "radius": 90.0},
	])
	fixture.field.advance(1.0)
	var route: NetworkRoute = fixture.network.find_route(fixture.receiver_node, fixture.receiver_node)
	_check(route.found and route.segments.is_empty() and fixture.network.is_route_valid(route),
		"Same-node route was not a valid zero-edge route")
	var death_position: Vector2 = fixture.receiver_node.global_position + Vector2(0.0, 55.0)
	_add_remains(fixture, death_position)
	_check(fixture.system.try_dispatch(), "Zero-edge route rejected a covered corpse")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	_check(packet.global_position.distance_to(death_position) < POSITION_EPSILON,
		"Zero-edge shipment skipped the ground pickup")
	await _wait_frames(2)
	_check(fixture.receiver.get_queued_count() == 0 and packet.global_position.y > 0.0 and
		packet.global_position.y < death_position.y, "Zero-edge route arrived before completing pickup")
	await _wait_for_transport(fixture)
	_check(fixture.receiver.get_queued_count() == 1 and fixture.receiver.incoming_remains == 0,
		"Zero-edge pickup did not enqueue once")
	fixture.field.set_sources([
		{"node": fixture.core, "kind": &"core", "connected": true, "radius": 80.0},
	])
	fixture.field.advance(1.0)
	var core_remains: EnemyRemains = _add_remains(fixture, Vector2(0.0, 40.0))
	_check(fixture.field.get_collection_node(core_remains.global_position) == fixture.core and
		fixture.system.try_dispatch(), "Mother core was not an eligible pickup source")
	await _wait_for_transport(fixture)
	_check(fixture.receiver.get_queued_nutrition() == 8 and fixture.system.delivered_count == 2,
		"Mother-core collection did not deliver once")
	await _dispose_fixture(fixture)


func _test_capacity_and_digestion_connection() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.receiver.capacity = 2
	_add_remains(fixture, fixture.source.global_position + Vector2(10.0, 0.0))
	_add_remains(fixture, fixture.source.global_position + Vector2(20.0, 0.0))
	var waiting: EnemyRemains = _add_remains(fixture, fixture.source.global_position + Vector2(30.0, 0.0))
	_check(fixture.system.try_dispatch() and fixture.system.try_dispatch() and not fixture.system.try_dispatch(),
		"Incoming shipments exceeded stomach capacity")
	_check(waiting.is_available() and fixture.receiver.incoming_remains == 2,
		"Full incoming capacity claimed a waiting corpse")
	await _wait_for_transport(fixture)
	_check(fixture.receiver.get_queued_count() == 2 and fixture.receiver.incoming_remains == 0 and
		not fixture.system.try_dispatch() and waiting.is_available(), "Full stomach accepted another corpse")
	fixture.core_edge.end_node = null
	fixture.receiver.digest_timer.start(0.05)
	await _wait_frames(12)
	_check(fixture.receiver.get_queued_count() == 0 and fixture.receiver.get_output_count() == 2
		and fixture.receiver.get_output_nutrition() == 8 and fixture.core.nutrition == 72,
		"Disconnected digestion retains two produced outputs without crediting the core")
	fixture.core_edge.end_node = fixture.receiver_node
	await _return_outputs(fixture)
	_check(fixture.receiver.get_queued_count() == 0 and fixture.core.nutrition == 80,
		"Restored network returns both outputs exactly once")
	fixture.receiver.digest_timer.wait_time = 120.0
	_check(fixture.system.try_dispatch(), "Released stomach capacity did not resume collection")
	await _wait_for_transport(fixture)
	_check(fixture.receiver.get_queued_count() == 1 and fixture.receiver.incoming_remains == 0 and
		fixture.core.nutrition == 80, "Resumed collection lost capacity or produced early income")
	await _dispose_fixture(fixture)


func _test_shared_receiver_removal() -> void:
	var fixture: Fixture = _new_fixture()
	var corpses: Array[EnemyRemains] = [
		_add_remains(fixture, fixture.source.global_position + Vector2(10.0, 0.0)),
		_add_remains(fixture, fixture.source.global_position + Vector2(20.0, 0.0)),
	]
	_check(fixture.system.try_dispatch() and fixture.system.try_dispatch(),
		"Shared receiver accepts two independent reservations")
	_check(fixture.receiver.incoming_remains == 2, "Two shipments reserve two slots")
	var packets: Array[RemainsPacket] = []
	for child in fixture.packets.get_children():
		packets.append(child as RemainsPacket)
	fixture.receiver_node.remove_child(fixture.receiver)
	_check(fixture.system.get_in_transit_count() == 0 and fixture.receiver.incoming_remains == 0,
		"One receiver exit cancels every pending shipment")
	_check(corpses[0].is_available() and corpses[1].is_available(),
		"Receiver exit restores both original corpses")
	for packet in packets:
		packet.cancel_transport()
		packet.interrupted.emit(packet)
	_check(fixture.system.interrupted_count == 2 and fixture.core.nutrition == 72,
		"Repeated callbacks cannot duplicate shared-receiver settlement")
	fixture.receiver_node.add_child(fixture.receiver)
	await _wait_frames(2)
	_check(fixture.system.try_dispatch() and fixture.system.try_dispatch(),
		"Reattached receiver accepts both restored corpses")
	await _wait_for_transport(fixture)
	_check(fixture.system.delivered_count == 2 and fixture.receiver.get_queued_count() == 2 and
		fixture.receiver.incoming_remains == 0, "Shared receiver delivers both retries once")
	await _dispose_fixture(fixture)


func _test_no_route_and_reconnection() -> void:
	var fixture: Fixture = _new_fixture()
	_add_edge(fixture, fixture.core, fixture.source)
	fixture.network.unregister_edge(fixture.core_edge)
	fixture.network.unregister_edge(fixture.relay_edge)
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position)
	_check(fixture.network.is_connected_to_core(fixture.source) and
		not fixture.network.find_route(fixture.source, fixture.receiver_node).found,
		"No-route fixture did not isolate the receiver")
	_check(not fixture.system.try_dispatch() and remains.is_available() and remains.visible,
		"Missing receiver route claimed the corpse")
	_check(fixture.receiver.incoming_remains == 0 and fixture.packets.get_child_count() == 0,
		"Missing receiver route reserved capacity or created a packet")
	_check(fixture.network.register_edge(fixture.core_edge) and fixture.system.try_dispatch(),
		"Reconnected receiver did not enable pickup")
	await _wait_for_transport(fixture)
	_check(fixture.system.delivered_count == 1 and fixture.receiver.get_queued_count() == 1,
		"Reconnection did not deliver once")
	await _dispose_fixture(fixture)


func _test_break_cancel_and_packet_removal() -> void:
	var fixture: Fixture = _new_fixture()
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position + Vector2(40.0, 0.0))
	_check(fixture.system.try_dispatch(), "Interruption fixture did not dispatch")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(12)
	var drop_position: Vector2 = packet.global_position
	fixture.network.unregister_edge(fixture.relay_edge)
	# 6.4 未来断段不再强制落地；先抵达实际菌结并保持原领取/胃囊预留。
	for _frame: int in range(180):
		if packet.get_transport_snapshot()["state"] == &"waiting":
			break
		await _wait_frames(1)
	_check(packet.get_transport_snapshot()["state"] == &"waiting" and not remains.is_available()
		and fixture.receiver.incoming_remains == 1 and fixture.system.interrupted_count == 0,
		"Broken future route waits without releasing corpse claim or stomach reservation")
	drop_position = packet.global_position
	packet.cancel_transport()
	await _wait_for_transport(fixture)
	_check(remains.is_available() and remains.visible and
		remains.global_position.distance_to(drop_position) < POSITION_EPSILON,
		"Explicitly cancelling the no-route wait restores the same corpse at the actual node")
	_check(fixture.receiver.incoming_remains == 0 and fixture.system.interrupted_count == 1 and
		fixture.core.nutrition == 72, "Route break leaked a reservation or produced income")
	_check(fixture.network.register_edge(fixture.relay_edge) and fixture.system.try_dispatch(),
		"Reconnected original route did not recollect the restored corpse")
	packet = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(3)
	drop_position = packet.global_position
	packet.cancel_transport()
	packet.cancel_transport()
	packet.arrived.emit(packet)
	await _wait_for_transport(fixture)
	_check(remains.is_available() and remains.global_position.distance_to(drop_position) < POSITION_EPSILON and
		fixture.system.interrupted_count == 2 and fixture.system.delivered_count == 0,
		"Repeated cancel or late arrival settled the shipment twice")
	_check(fixture.system.try_dispatch(), "Cancelled corpse could not be recollected")
	packet = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(3)
	drop_position = packet.global_position
	packet.queue_free()
	await _wait_for_transport(fixture)
	_check(remains.is_available() and remains.visible and
		remains.global_position.distance_to(drop_position) < POSITION_EPSILON and
		fixture.system.interrupted_count == 3 and fixture.receiver.incoming_remains == 0,
		"Forced packet removal lost the corpse or leaked capacity")
	_check(fixture.system.try_dispatch(), "Packet removal prevented reconnection and retry")
	await _wait_for_transport(fixture)
	_check(not is_instance_valid(remains) and fixture.system.delivered_count == 1 and
		fixture.receiver.get_queued_count() == 1, "Retried corpse was not delivered exactly once")
	await _dispose_fixture(fixture)


func _test_receiver_snapshot_and_owner_removal() -> void:
	var fixture: Fixture = _new_fixture()
	var original: DigestiveOrgan = fixture.receiver
	var other_node: HyphaNode = _add_node(fixture, Vector2(700.0, 0.0))
	var other: DigestiveOrgan = _add_receiver(fixture, other_node)
	_add_remains(fixture, fixture.source.global_position)
	_check(fixture.system.try_dispatch(), "Receiver ownership fixture did not dispatch")
	fixture.system.digestive_organ = other
	await _wait_for_transport(fixture)
	_check(original.get_queued_count() == 1 and original.incoming_remains == 0 and
		other.get_queued_count() == 0 and other.incoming_remains == 0,
		"Configuration change retargeted an already reserved shipment")
	fixture.system.digestive_organ = original
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position + Vector2(35.0, 0.0))
	_check(fixture.system.try_dispatch(), "Receiver-loss fixture did not dispatch")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(3)
	var drop_position: Vector2 = packet.global_position
	fixture.receiver_node.remove_child(original)
	_check(fixture.system.get_in_transit_count() == 0 and original.incoming_remains == 0 and
		remains.is_available() and remains.global_position.distance_to(drop_position) < POSITION_EPSILON,
		"Receiver removal did not promptly release its own reservation and corpse")
	_check(not fixture.system.try_dispatch(), "Detached receiver accepted a new shipment")
	packet.interrupted.emit(packet)
	packet.arrived.emit(packet)
	_check(fixture.system.interrupted_count == 1 and fixture.system.delivered_count == 1,
		"Removed receiver settled more than once")
	fixture.receiver_node.add_child(original)
	await _wait_for_transport(fixture)
	_check(fixture.system.try_dispatch(), "Reattached original receiver could not reserve capacity")
	packet = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(3)
	drop_position = packet.global_position
	fixture.remains.remove_child(remains)
	_check(fixture.system.get_in_transit_count() == 0 and original.incoming_remains == 0 and
		remains.is_available() and remains.global_position.distance_to(drop_position) < POSITION_EPSILON,
		"Corpse removal did not promptly cancel and release the reservation")
	packet.cancel_transport()
	_check(fixture.system.interrupted_count == 2, "Corpse removal and cancel settled twice")
	remains.queue_free()
	await _wait_for_transport(fixture)
	await _dispose_fixture(fixture)


func _test_freed_receiver_rejects_dispatch() -> void:
	var fixture: Fixture = _new_fixture()
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position + Vector2(30.0, 0.0))
	_check(fixture.system.try_dispatch(), "Freed-receiver fixture did not dispatch")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(3)
	var drop_position: Vector2 = packet.global_position
	var incoming_history: Array[int] = []
	var record_incoming: Callable = func(_queued: int, incoming: int) -> void:
		incoming_history.append(incoming)
	fixture.receiver.inventory_changed.connect(record_incoming)
	fixture.receiver.queue_free()
	await _wait_for_transport(fixture)
	_check(not is_instance_valid(fixture.receiver), "Receiver was not actually freed")
	_check(not fixture.system.try_dispatch() and fixture.system.get_in_transit_count() == 0,
		"Actually freed receiver did not reject a later dispatch safely")
	_check(incoming_history.has(0) and remains.is_available() and remains.visible and
		remains.global_position.distance_to(drop_position) < POSITION_EPSILON,
		"Freed receiver lost the corpse or its original reservation")
	_check(fixture.system.interrupted_count == 1 and fixture.system.delivered_count == 0 and
		fixture.core.nutrition == 72, "Freed receiver produced income or settled twice")
	await _dispose_fixture(fixture)


func _test_system_exit_and_startup_invalidation() -> void:
	var fixture: Fixture = _new_fixture()
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position + Vector2(20.0, 0.0))
	_check(fixture.system.try_dispatch(), "System-exit fixture did not dispatch")
	var packet: RemainsPacket = _first_packet(fixture)
	if packet == null:
		await _dispose_fixture(fixture)
		return
	await _wait_frames(3)
	var drop_position: Vector2 = packet.global_position
	fixture.world.remove_child(fixture.system)
	packet.cancel_transport()
	packet.interrupted.emit(packet)
	_check(fixture.system.get_in_transit_count() == 0 and fixture.receiver.incoming_remains == 0 and
		fixture.system.interrupted_count == 1 and remains.is_available() and
		remains.global_position.distance_to(drop_position) < POSITION_EPSILON,
		"System exit fallback leaked capacity or settled twice")
	_check(not fixture.system.try_dispatch(), "Exited system dispatched a new shipment")
	fixture.system.queue_free()
	await process_frame
	await process_frame
	_check(fixture.packets.get_child_count() == 0, "System exit left an orphan packet")
	await _dispose_fixture(fixture)

	fixture = _new_fixture()
	remains = _add_remains(fixture, fixture.source.global_position + Vector2(20.0, 0.0))
	var invalidate_after_reservation: Callable = func(_queued: int, incoming: int) -> void:
		if incoming > 0:
			fixture.network.unregister_edge(fixture.source_edge)
	fixture.receiver.inventory_changed.connect(invalidate_after_reservation)
	_check(not fixture.system.try_dispatch(), "Startup-invalidated collection route must reject admission")
	fixture.receiver.inventory_changed.disconnect(invalidate_after_reservation)
	_check(fixture.system.get_in_transit_count() == 0 and fixture.system.interrupted_count == 0 and
		fixture.receiver.incoming_remains == 0 and remains.is_available(),
		"Rejected admission retains original resources and releases its provisional reservation")
	await _wait_for_transport(fixture)
	_check(fixture.system.interrupted_count == 0 and fixture.system.delivered_count == 0,
		"Rejected admission and packet removal cannot invent a transport settlement")
	await _dispose_fixture(fixture)


func _test_invalid_packet_scene() -> void:
	var fixture: Fixture = _new_fixture()
	var remains: EnemyRemains = _add_remains(fixture, fixture.source.global_position)
	fixture.system.packet_scene = NODE_SCENE
	_check(not fixture.system.try_dispatch(), "Invalid packet scene was accepted")
	_check(remains.is_available() and remains.visible and fixture.receiver.incoming_remains == 0 and
		fixture.packets.get_child_count() == 0, "Invalid packet scene leaked a claim or reservation")
	await _dispose_fixture(fixture)
