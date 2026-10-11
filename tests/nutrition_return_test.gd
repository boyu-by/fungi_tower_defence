extends SceneTree
## 独立验证有限消化输出和真实营养回流，不启动关卡战斗。

class Fixture:
	extends RefCounted

	var host: Node2D
	var stomach_node: Node2D
	var organ: DigestiveOrgan
	var core: MotherCore
	var network: NetworkSystem
	var packets: Node2D
	var system: NutritionReturnSystem
	var nodes: Array[Node2D] = []
	var edges: Array[HyphaEdge] = []
	var admitted_nutrition: int = 0
	var initial_balance: int = 0
	var arrivals: Array[Dictionary] = []
	var creations: Array[Dictionary] = []
	var digestions: Array[int] = []

const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")

var failures: Array[String] = []
var checks: int = 0
var _hosts: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_real_arrival_and_green_route()
	_test_disconnection_capacity_and_retry()
	_test_value_reservation_and_oversize()
	_test_reset_and_duplicate_callbacks()
	_test_reentrant_claim_and_receipt()
	_test_captured_configuration()
	_test_lifecycle_interruptions()
	await _test_automatic_dispatch_and_resume()
	_free_fixtures()
	await process_frame
	await process_frame
	_check(root.get_child_count() == initial_children, "Return tests left fixture nodes in the tree")
	print("NUTRITION_RETURN_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _check_position(actual: Vector2, expected: Vector2, description: String) -> void:
	_check(actual.distance_to(expected) < 0.001, description)


func _new_core(parent: Node2D, point: Vector2) -> MotherCore:
	var core: MotherCore = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	core.add_child(health_bar)
	parent.add_child(core)
	core.position = point
	return core


func _new_fixture() -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.host = Node2D.new()
	_hosts.append(weakref(fixture.host))
	root.add_child(fixture.host)
	fixture.network = NetworkSystem.new()
	fixture.host.add_child(fixture.network)
	fixture.stomach_node = Node2D.new()
	fixture.host.add_child(fixture.stomach_node)
	fixture.stomach_node.position = Vector2(240.0, 120.0)
	fixture.nodes.append(fixture.stomach_node)
	for point: Vector2 in [Vector2(160.0, 120.0), Vector2(160.0, 40.0)]:
		var node: Node2D = Node2D.new()
		fixture.host.add_child(node)
		node.position = point
		fixture.nodes.append(node)
	fixture.core = _new_core(fixture.host, Vector2(0.0, 40.0))
	fixture.nodes.append(fixture.core)
	for node: Node2D in fixture.nodes:
		_check(fixture.network.register_node(node, node == fixture.core), "Fixture node registration failed")
	for index: int in range(3):
		var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
		edge.start_node = fixture.nodes[index + 1] if index == 1 else fixture.nodes[index]
		edge.end_node = fixture.nodes[index] if index == 1 else fixture.nodes[index + 1]
		fixture.host.add_child(edge)
		edge.set_process(false)
		fixture.edges.append(edge)
		_check(fixture.network.register_edge(edge), "Fixture edge registration failed")
	fixture.organ = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	fixture.organ.mother_core = fixture.core
	fixture.organ.core_edge = fixture.edges[0]
	fixture.stomach_node.add_child(fixture.organ)
	fixture.organ.digest_timer.wait_time = 1000.0
	fixture.packets = Node2D.new()
	fixture.host.add_child(fixture.packets)
	fixture.system = NutritionReturnSystem.new()
	fixture.system.digestive_organ = fixture.organ
	fixture.system.mother_core = fixture.core
	fixture.system.network_system = fixture.network
	fixture.system.packet_container = fixture.packets
	fixture.system.auto_return = false
	fixture.host.add_child(fixture.system)
	fixture.system.get_node("DispatchTimer").stop()
	fixture.initial_balance = fixture.core.nutrition
	fixture.core.digestion_product_arrived.connect(func(product_id: String, nutrition: int) -> void:
		fixture.arrivals.append({"product_id": product_id, "nutrition": nutrition})
	)
	fixture.organ.product_created.connect(func(product_id: String, nutrition: int) -> void:
		fixture.creations.append({"product_id": product_id, "nutrition": nutrition})
	)
	fixture.organ.digested.connect(func(nutrition: int) -> void: fixture.digestions.append(nutrition))
	return fixture


func _feed(fixture: Fixture, nutrition: int) -> void:
	_check(fixture.organ.reserve_remains(), "Valid corpse intake reservation failed")
	_check(fixture.organ.complete_delivery(nutrition), "Reserved corpse did not enter stomach")
	fixture.admitted_nutrition += nutrition


func _complete_digest(fixture: Fixture) -> void:
	fixture.organ.digest_timer.stop()
	fixture.organ._on_digest_timer_timeout()


func _dispatch(fixture: Fixture) -> Dictionary:
	_check(fixture.system.try_dispatch(), "Available return product was not dispatched")
	var records: Array[Dictionary] = fixture.system.get_shipment_records()
	if records.is_empty():
		return {}
	var record: Dictionary = records.back()
	var packet: NutrientPacket = record["packet"] as NutrientPacket
	if is_instance_valid(packet):
		packet.set_physics_process(false)
	return record


func _finish_packet(record: Dictionary) -> void:
	if record.is_empty():
		return
	var packet: NutrientPacket = record["packet"] as NutrientPacket
	if is_instance_valid(packet):
		packet._physics_process(10.0)


func _check_output_bound(organ: DigestiveOrgan, context: String) -> void:
	var snapshot: Dictionary = organ.get_output_snapshot()
	_check(int(snapshot["count"]) + int(snapshot["reserved_count"]) <= 2,
		context + ": output slots plus reservation exceeded two")
	_check(int(snapshot["nutrition"]) + int(snapshot["reserved_nutrition"]) <= 20,
		context + ": output nutrition plus reservation exceeded twenty")
	_check(int(snapshot["count"]) == int(snapshot["queued_count"]) + int(snapshot["in_transit_count"]),
		context + ": output status counts did not partition ownership")


func _check_conservation(fixture: Fixture, context: String) -> void:
	var organ: DigestiveOrgan = fixture.organ
	var received: int = fixture.core.nutrition - fixture.initial_balance
	_check(received + organ.get_output_nutrition() == organ.total_nutrition_produced,
		context + ": produced nutrition was lost or counted twice")
	_check(organ.get_queued_nutrition() + organ.get_output_nutrition() + received == fixture.admitted_nutrition,
		context + ": corpse/output/received nutrition did not conserve intake")
	var snapshot: Dictionary = fixture.system.get_return_snapshot()
	_check(int(snapshot["queued_nutrition"]) + int(snapshot["in_transit_nutrition"]) == organ.get_output_nutrition(),
		context + ": transport records duplicated or omitted stomach inventory")
	_check_output_bound(organ, context)


func _test_real_arrival_and_green_route() -> void:
	var fixture: Fixture = _new_fixture()
	_feed(fixture, 6)
	var reserved: Dictionary = fixture.organ.get_output_snapshot()
	_check(reserved["count"] == 0 and reserved["reserved_count"] == 1 and reserved["reserved_nutrition"] == 6,
		"Digestion did not reserve output capacity before its timer")
	_check(fixture.organ.get_queued_count() == 1 and fixture.organ.get_queued_nutrition() == 6,
		"Actively digesting corpse disappeared from the intake queue")
	_check_conservation(fixture, "Before production")
	_complete_digest(fixture)
	_check(fixture.core.nutrition == fixture.initial_balance and fixture.arrivals.is_empty(),
		"Digestion credited income or emitted an arrival before a return packet")
	_check(fixture.organ.digested_count == 1 and fixture.organ.total_nutrition_produced == 6,
		"Production counters were not committed exactly once")
	_check(fixture.creations.size() == 1 and fixture.digestions == [6], "Production signals were lost or duplicated")
	var products: Array[Dictionary] = fixture.organ.get_output_products()
	_check(products.size() == 1 and products[0]["status"] == &"queued" and products[0]["nutrition"] == 6,
		"Production did not create a queued output record")
	var product_id: String = String(products[0]["product_id"])
	products[0]["nutrition"] = 999
	_check(fixture.organ.get_output_nutrition() == 6, "Output snapshot allowed outside mutation of authoritative inventory")
	_check_conservation(fixture, "Queued production")
	var record: Dictionary = _dispatch(fixture)
	var packet: NutrientPacket = record["packet"] as NutrientPacket
	var route: NetworkRoute = record["route"] as NetworkRoute
	_check(packet is NutrientPacket and packet.speed == 80.0, "Return did not instantiate the real packet with default speed")
	_check(packet.name.begins_with("NutritionReturn_") and String(packet.get_meta("return_product_id")) == product_id,
		"Return packet name or product metadata was missing")
	_check(route.segments.size() == 3 and route.segments[0].forward and not route.segments[1].forward
		and route.segments[2].forward, "Return route did not retain mixed edge directions")
	var body: Polygon2D = packet.get_node("Body") as Polygon2D
	var glow: Polygon2D = packet.get_node("Glow") as Polygon2D
	var trail: Line2D = packet.get_node("Trail") as Line2D
	_check(body.color.g > body.color.r and body.color.g > body.color.b, "Return Body was not green")
	_check(glow.color.g > glow.color.r and glow.color.g > glow.color.b, "Return Glow was not green")
	_check(trail.default_color.g > trail.default_color.r and trail.default_color.g > trail.default_color.b,
		"Return Trail was not green")
	var base_packet: NutrientPacket = PACKET_SCENE.instantiate() as NutrientPacket
	_check((base_packet.get_node("Body") as Polygon2D).color.r > (base_packet.get_node("Body") as Polygon2D).color.g,
		"Styling a return instance changed the shared supply packet scene")
	base_packet.free()
	_check(not fixture.system.try_dispatch(), "One product was claimed by two packets")
	_check_output_bound(fixture.organ, "Return in flight")
	_check(fixture.organ.get_output_nutrition() == 6 and fixture.system.get_in_transit_nutrition() == 6,
		"Transit released output ownership or lost its value")
	packet._physics_process(0.5)
	_check_position(packet.global_position, Vector2(200.0, 120.0), "Green packet did not traverse the first segment")
	packet._physics_process(1.0)
	_check_position(packet.global_position, Vector2(160.0, 80.0), "Green packet did not traverse a reverse stored segment")
	_check(fixture.core.nutrition == fixture.initial_balance, "Partway return was credited")
	_check_conservation(fixture, "Partway return")
	packet._physics_process(1.0)
	_check_position(packet.global_position, Vector2(120.0, 40.0), "Green packet did not continue into the last segment")
	packet._physics_process(2.0)
	_check_position(packet.global_position, fixture.core.global_position, "Return arrival position was wrong")
	_check(fixture.core.nutrition == fixture.initial_balance + 6 and fixture.core.has_received_product(product_id),
		"Actual return arrival was not accepted by the mother core")
	_check(fixture.arrivals.size() == 1 and fixture.arrivals[0]["product_id"] == product_id,
		"Mother core receipt event was not emitted once for the arrived product")
	_check(fixture.organ.get_output_count() == 0 and fixture.system.delivered_count == 1
		and fixture.system.delivered_nutrition == 6, "Arrival did not settle output and observed counters")
	packet.arrived.emit(packet)
	packet.arrived.emit(packet)
	packet.cancel_transport()
	packet.cancel_transport()
	fixture.system._on_packet_arrived(packet, String(record["attempt_id"]))
	_check(fixture.core.nutrition == fixture.initial_balance + 6 and fixture.arrivals.size() == 1
		and fixture.system.delivered_count == 1, "Duplicate arrival/cancel callbacks credited or counted twice")
	_check_conservation(fixture, "Receipt complete")


func _test_disconnection_capacity_and_retry() -> void:
	var fixture: Fixture = _new_fixture()
	var old_endpoint: Node2D = fixture.edges[1].end_node
	fixture.edges[1].end_node = null
	_feed(fixture, 4)
	_complete_digest(fixture)
	_feed(fixture, 5)
	_complete_digest(fixture)
	_feed(fixture, 6)
	_check(fixture.organ.digested_count == 2 and fixture.organ.get_output_nutrition() == 9,
		"Disconnected stomach could not digest already received corpses with free space")
	_check(fixture.organ.get_queued_count() == 1 and fixture.organ.get_queued_nutrition() == 6,
		"Full output consumed the waiting corpse")
	var snapshot: Dictionary = fixture.organ.get_output_snapshot()
	_check(snapshot["count"] == 2 and snapshot["reserved_count"] == 0
		and snapshot["wait_reason"] == &"output_full" and fixture.organ.digest_timer.is_stopped(),
		"Full slot capacity did not pause before starting another digest timer")
	_check(not fixture.system.try_dispatch() and fixture.system.get_return_snapshot()["wait_reason"] == &"disconnected",
		"Disconnected output started a return or reported the wrong wait reason")
	_check_conservation(fixture, "Disconnected full output")
	fixture.edges[1].end_node = old_endpoint
	var first: Dictionary = _dispatch(fixture)
	var packet: NutrientPacket = first["packet"] as NutrientPacket
	packet._physics_process(0.6)
	fixture.edges[1].end_node = null
	packet._physics_process(0.1)
	_check(fixture.system.interrupted_count == 0 and fixture.system.get_in_transit_count() == 1,
		"A future broken segment does not interrupt cargo on a still-valid current edge")
	packet._physics_process(10.0)
	_check(packet.get_transport_snapshot()["state"] == &"waiting"
		and fixture.organ.get_output_products()[0]["status"] == &"in_transit"
		and fixture.core.nutrition == fixture.initial_balance,
		"Return reaches the next node and retains the original uncredited product while no route exists")
	packet.arrived.emit(packet)
	_check(fixture.system.get_in_transit_count() == 1 and fixture.core.nutrition == fixture.initial_balance,
		"A spurious arrival while waiting cannot release the product or credit the core")
	packet.cancel_transport()
	_check(fixture.system.interrupted_count == 1 and fixture.system.get_in_transit_count() == 0,
		"Explicitly cancelling the waiting return interrupts once")
	_check(fixture.organ.get_output_products()[0]["product_id"] == first["product_id"]
		and fixture.organ.get_output_products()[0]["nutrition"] == first["nutrition"]
		and fixture.organ.get_output_products()[0]["status"] == &"queued",
		"Interruption changed or lost the product instead of returning its claim")
	packet.arrived.emit(packet)
	fixture.system._on_packet_arrived(packet, String(first["attempt_id"]))
	_check(fixture.core.nutrition == fixture.initial_balance, "Late arrival of an interrupted attempt credited nutrition")
	_check_conservation(fixture, "Interrupted return")
	fixture.edges[1].end_node = old_endpoint
	var retry: Dictionary = _dispatch(fixture)
	_check(retry["product_id"] == first["product_id"] and retry["nutrition"] == first["nutrition"]
		and retry["attempt_id"] != first["attempt_id"], "Retry did not reuse the same immutable product with a new attempt")
	_check(fixture.organ.get_output_snapshot()["reserved_count"] == 0, "Dispatch freed capacity before actual receipt")
	_finish_packet(retry)
	_check(fixture.organ.get_output_snapshot()["reserved_count"] == 1
		and fixture.organ.get_output_snapshot()["reserved_nutrition"] == 6
		and not fixture.organ.digest_timer.is_stopped(), "Receipt did not automatically resume blocked digestion")
	_check(fixture.organ.get_queued_count() == 1 and fixture.organ.get_output_nutrition() == 5,
		"Resumed reservation was copied into produced nutrition or removed its corpse")
	_check_conservation(fixture, "Resumed digest")
	_complete_digest(fixture)
	var second: Dictionary = _dispatch(fixture)
	var third: Dictionary = _dispatch(fixture)
	_check(fixture.system.get_in_transit_count() == 2 and fixture.system.get_in_transit_nutrition() == 11,
		"Two distinct output slots could not return concurrently")
	_check(fixture.organ.get_output_snapshot()["in_transit_count"] == 2
		and fixture.organ.get_output_nutrition() == 11, "In-flight products did not occupy both output slots")
	_check_conservation(fixture, "Two returns in flight")
	_finish_packet(second)
	_finish_packet(third)
	_check(fixture.core.nutrition == fixture.initial_balance + 15 and fixture.arrivals.size() == 3
		and fixture.system.delivered_count == 3 and fixture.system.interrupted_count == 1,
		"Disconnect/recovery cycle lost or duplicated nutrition")
	_check_conservation(fixture, "Recovered all output")


func _test_value_reservation_and_oversize() -> void:
	var fixture: Fixture = _new_fixture()
	_feed(fixture, 12)
	_feed(fixture, 9)
	_check(fixture.organ.get_queued_count() == 2 and fixture.organ.get_queued_nutrition() == 21,
		"Serial digestion did not retain both corpses in its queue")
	_check(fixture.organ.get_output_snapshot()["reserved_count"] == 1
		and fixture.organ.get_output_snapshot()["reserved_nutrition"] == 12,
		"A second corpse obtained a concurrent output reservation")
	_check_conservation(fixture, "Serial reservation")
	_complete_digest(fixture)
	_check(fixture.organ.get_output_count() == 1 and fixture.organ.get_output_nutrition() == 12,
		"First value-limited product was not produced")
	_check(fixture.organ.digest_timer.is_stopped() and fixture.organ.get_output_snapshot()["reserved_count"] == 0
		and fixture.organ.get_output_snapshot()["wait_reason"] == &"output_full",
		"Nutrition capacity allowed 12 + 9 before freeing an output")
	fixture.organ._on_digest_timer_timeout()
	_check(fixture.organ.digested_count == 1 and fixture.organ.get_queued_nutrition() == 9,
		"Spurious timeout bypassed an output capacity reservation")
	var record: Dictionary = _dispatch(fixture)
	_check(fixture.organ.get_output_snapshot()["reserved_count"] == 0,
		"Sending value-limited output prematurely started the blocked corpse")
	_finish_packet(record)
	_check(fixture.organ.get_output_snapshot()["reserved_nutrition"] == 9,
		"Successful receipt failed to reserve value for the next digest")
	_check_conservation(fixture, "Value capacity released")
	_complete_digest(fixture)
	_finish_packet(_dispatch(fixture))
	_check_conservation(fixture, "Value-limited batch complete")
	var boundary: Fixture = _new_fixture()
	_feed(boundary, 20)
	_check(boundary.organ.get_output_snapshot()["reserved_nutrition"] == 20,
		"Exactly twenty nutrition was incorrectly rejected")
	_complete_digest(boundary)
	_check_output_bound(boundary.organ, "Twenty-nutrition output")
	_finish_packet(_dispatch(boundary))
	_check_conservation(boundary, "Twenty-nutrition receipt")
	var oversize: Fixture = _new_fixture()
	_feed(oversize, 21)
	_feed(oversize, 4)
	var oversized_snapshot: Dictionary = oversize.organ.get_output_snapshot()
	_check(oversized_snapshot["wait_reason"] == &"output_too_large"
		and oversized_snapshot["reserved_count"] == 0 and oversize.organ.digest_timer.is_stopped(),
		"Oversized corpse did not wait without reserving output space")
	_complete_digest(oversize)
	_check(oversize.organ.get_queued_count() == 2 and oversize.organ.get_queued_nutrition() == 25
		and oversize.organ.digested_count == 0, "Oversized corpse was lost or the serial queue was bypassed")
	_check_conservation(oversize, "Oversized queue retained")
	_check(oversize.organ.reserve_remains(), "Invalid-value test could not reserve an intake slot")
	_check(not oversize.organ.complete_delivery(0) and oversize.organ.incoming_remains == 1,
		"Invalid intake consumed its reservation")
	_check(oversize.organ.cancel_reservation() and not oversize.organ.cancel_reservation(),
		"Intake reservation cancellation was not bounded")


func _test_reset_and_duplicate_callbacks() -> void:
	var fixture: Fixture = _new_fixture()
	_feed(fixture, 4)
	_complete_digest(fixture)
	_feed(fixture, 7)
	_complete_digest(fixture)
	var first: Dictionary = _dispatch(fixture)
	var second: Dictionary = _dispatch(fixture)
	var old_packet: NutrientPacket = first["packet"] as NutrientPacket
	fixture.system.reset()
	var reset_snapshot: Dictionary = fixture.system.get_return_snapshot()
	_check(reset_snapshot["in_transit_count"] == 0 and reset_snapshot["delivered_count"] == 0
		and reset_snapshot["interrupted_count"] == 0 and fixture.system.get_shipment_records().is_empty(),
		"Return reset retained attempt records or counters")
	_check(not fixture.system.auto_return and fixture.organ.get_output_nutrition() == 11,
		"Return reset changed auto mode or discarded uncredited stomach output")
	var outputs: Array[Dictionary] = fixture.organ.get_output_products()
	_check(outputs[0]["product_id"] == first["product_id"] and outputs[1]["product_id"] == second["product_id"]
		and outputs[0]["status"] == &"queued" and outputs[1]["status"] == &"queued",
		"Reset did not return both claims with unchanged product ids")
	old_packet.arrived.emit(old_packet)
	old_packet.interrupted.emit(old_packet)
	fixture.system._on_packet_arrived(old_packet, String(first["attempt_id"]))
	_check(fixture.core.nutrition == fixture.initial_balance and fixture.system.interrupted_count == 0,
		"Stale callbacks after reset recreated old transport accounting")
	_check_conservation(fixture, "Return reset")
	var retry: Dictionary = _dispatch(fixture)
	_check(retry["product_id"] == first["product_id"] and retry["attempt_id"] != first["attempt_id"],
		"Reset recycled a shipment id or changed its product")
	_finish_packet(retry)
	_finish_packet(_dispatch(fixture))
	_check_conservation(fixture, "Reset products redelivered")
	var discarded: Fixture = _new_fixture()
	_feed(discarded, 4)
	_complete_digest(discarded)
	var original: Dictionary = _dispatch(discarded)
	var original_packet: NutrientPacket = original["packet"] as NutrientPacket
	discarded.system.reset()
	discarded.organ.reset()
	_check(discarded.organ.get_output_count() == 0 and discarded.organ.get_queued_count() == 0
		and discarded.organ.incoming_remains == 0 and discarded.organ.get_output_snapshot()["reserved_count"] == 0,
		"Organ reset left output, corpses, or reservations")
	_feed(discarded, 4)
	_complete_digest(discarded)
	var new_attempt: Dictionary = _dispatch(discarded)
	_check(new_attempt["product_id"] != original["product_id"] and new_attempt["attempt_id"] != original["attempt_id"],
		"A restart reused a product or attempt serial")
	original_packet.arrived.emit(original_packet)
	discarded.system._on_packet_arrived(original_packet, String(original["attempt_id"]))
	_check(discarded.core.nutrition == discarded.initial_balance, "Old product arrival credited after organ restart")
	_finish_packet(new_attempt)
	_check(discarded.core.nutrition == discarded.initial_balance + 4 and discarded.arrivals.size() == 1,
		"New product after reset was lost or confused with its predecessor")


func _test_reentrant_claim_and_receipt() -> void:
	var fixture: Fixture = _new_fixture()
	_feed(fixture, 4)
	_complete_digest(fixture)
	var reset_on_claim: Array[bool] = [false]
	fixture.organ.output_changed.connect(func(snapshot: Dictionary) -> void:
		if not reset_on_claim[0] and snapshot["in_transit_count"] == 1:
			reset_on_claim[0] = true
			fixture.system.reset()
	)
	_check(not fixture.system.try_dispatch(), "Reentrant claim reset returned an active shipment")
	_check(fixture.organ.get_output_count() == 1 and fixture.organ.get_output_products()[0]["status"] == &"queued"
		and fixture.system.get_shipment_records().is_empty(), "Claim callback reset lost output or retained a ghost record")
	_check_conservation(fixture, "Reentrant claim reset")
	var returned: Dictionary = _dispatch(fixture)
	var packet: NutrientPacket = returned["packet"] as NutrientPacket
	var reset_on_receipt: Array[bool] = [false]
	fixture.core.nutrition_changed.connect(func(_nutrition: int) -> void:
		if not reset_on_receipt[0]:
			reset_on_receipt[0] = true
			packet.arrived.emit(packet)
			fixture.system._on_packet_arrived(packet, String(returned["attempt_id"]))
			fixture.system.reset()
	)
	_finish_packet(returned)
	_check(fixture.core.nutrition == fixture.initial_balance + 4 and fixture.arrivals.size() == 1,
		"Reentrant balance callback credited the same receipt more than once")
	_check(fixture.organ.get_output_count() == 0 and fixture.system.get_shipment_records().is_empty()
		and fixture.system.delivered_count == 0 and fixture.system.get_in_transit_count() == 0,
		"Receipt reset requeued credited output or resurrected cleared counters")
	_check_conservation(fixture, "Reentrant receipt reset")
	_feed(fixture, 5)
	_complete_digest(fixture)
	_finish_packet(_dispatch(fixture))
	_check(fixture.core.nutrition == fixture.initial_balance + 9 and fixture.system.delivered_count == 1
		and fixture.arrivals.size() == 2, "Reset during receipt prevented a subsequent valid return")
	_check_conservation(fixture, "Following reentrant receipt")


func _test_captured_configuration() -> void:
	var fixture: Fixture = _new_fixture()
	_feed(fixture, 8)
	_complete_digest(fixture)
	var original: Dictionary = _dispatch(fixture)
	var other_core: MotherCore = _new_core(fixture.host, Vector2(500.0, 500.0))
	var other_stomach_node: Node2D = Node2D.new()
	fixture.host.add_child(other_stomach_node)
	var other_organ: DigestiveOrgan = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	other_stomach_node.add_child(other_organ)
	fixture.system.mother_core = other_core
	fixture.system.digestive_organ = other_organ
	_finish_packet(original)
	_check(fixture.core.nutrition == fixture.initial_balance + 8 and other_core.nutrition == fixture.initial_balance,
		"Changing exported core redirected a pre-existing return")
	_check(fixture.organ.get_output_count() == 0 and other_organ.get_output_count() == 0,
		"Changing exported source settled or populated the wrong stomach")
	_check(fixture.system.delivered_count == 1 and fixture.arrivals.size() == 1,
		"Original return was dropped after changing configuration")


func _test_lifecycle_interruptions() -> void:
	var batch: Fixture = _new_fixture()
	_feed(batch, 4)
	_complete_digest(batch)
	_feed(batch, 5)
	_complete_digest(batch)
	_dispatch(batch)
	_dispatch(batch)
	batch.core.take_damage(999)
	_check(batch.system.get_in_transit_count() == 0 and batch.organ.get_output_snapshot()["queued_count"] == 2,
		"One shared core lifetime event cancels every simultaneous return")
	_check(batch.core.nutrition == batch.initial_balance and batch.organ.get_output_nutrition() == 9,
		"Shared owner cancellation retains all output without phantom income")
	_check_conservation(batch, "Shared owner with two returns")
	var removed_packet: Fixture = _new_fixture()
	_feed(removed_packet, 4)
	_complete_digest(removed_packet)
	var packet_record: Dictionary = _dispatch(removed_packet)
	var packet: NutrientPacket = packet_record["packet"] as NutrientPacket
	packet.free()
	_check(removed_packet.system.get_in_transit_count() == 0 and removed_packet.system.interrupted_count == 1
		and removed_packet.organ.get_output_count() == 1, "Direct packet removal leaked its product claim")
	_check_conservation(removed_packet, "Direct packet removal")
	var cancellation: Fixture = _new_fixture()
	_feed(cancellation, 4)
	_complete_digest(cancellation)
	var cancel_record: Dictionary = _dispatch(cancellation)
	var cancel_packet: NutrientPacket = cancel_record["packet"] as NutrientPacket
	cancel_packet.cancel_transport()
	cancel_packet.cancel_transport()
	cancel_packet.interrupted.emit(cancel_packet)
	_check(cancellation.system.interrupted_count == 1 and cancellation.organ.get_output_count() == 1
		and cancellation.organ.get_output_products()[0]["product_id"] == cancel_record["product_id"],
		"Repeated live cancellation lost output or settled an attempt twice")
	_check_conservation(cancellation, "Repeated cancellation")
	var source_reset: Fixture = _new_fixture()
	_feed(source_reset, 5)
	_complete_digest(source_reset)
	var source_reset_record: Dictionary = _dispatch(source_reset)
	var source_reset_packet: NutrientPacket = source_reset_record["packet"] as NutrientPacket
	source_reset.organ.reset()
	source_reset_packet.arrived.emit(source_reset_packet)
	_check(source_reset.system.get_in_transit_count() == 0 and source_reset.organ.get_output_count() == 0
		and source_reset.core.nutrition == source_reset.initial_balance and source_reset.arrivals.is_empty(),
		"Independent source reset left a ghost return or accepted its stale arrival")
	var detached_source: Fixture = _new_fixture()
	_feed(detached_source, 6)
	_complete_digest(detached_source)
	var detached_record: Dictionary = _dispatch(detached_source)
	var detached_packet: NutrientPacket = detached_record["packet"] as NutrientPacket
	detached_source.stomach_node.remove_child(detached_source.organ)
	_check(detached_source.system.get_in_transit_count() == 0 and detached_source.organ.get_output_nutrition() == 6
		and detached_source.organ.get_output_products()[0]["status"] == &"queued",
		"Source exit discarded a still-owned product or leaked transport")
	detached_packet.arrived.emit(detached_packet)
	_check(detached_source.core.nutrition == detached_source.initial_balance, "Detached source produced phantom return income")
	detached_source.stomach_node.add_child(detached_source.organ)
	_finish_packet(_dispatch(detached_source))
	_check_conservation(detached_source, "Source restored")
	var freed_source: Fixture = _new_fixture()
	_feed(freed_source, 4)
	_complete_digest(freed_source)
	var freed_record: Dictionary = _dispatch(freed_source)
	var freed_packet: NutrientPacket = freed_record["packet"] as NutrientPacket
	freed_source.organ.free()
	freed_packet.arrived.emit(freed_packet)
	_check(freed_source.system.get_in_transit_count() == 0 and freed_source.core.nutrition == freed_source.initial_balance,
		"Freed source credited a late arrival or retained transport")
	_check(not freed_source.system.try_dispatch(), "Freed exported source was dereferenced or accepted")
	var depleted_core: Fixture = _new_fixture()
	_feed(depleted_core, 4)
	_complete_digest(depleted_core)
	var dead_record: Dictionary = _dispatch(depleted_core)
	var dead_packet: NutrientPacket = dead_record["packet"] as NutrientPacket
	depleted_core.core.take_damage(999)
	dead_packet.arrived.emit(dead_packet)
	_check(depleted_core.system.get_in_transit_count() == 0 and depleted_core.organ.get_output_count() == 1
		and depleted_core.core.nutrition == depleted_core.initial_balance,
		"Dead core accepted return nutrition or caused output loss")
	_check(not depleted_core.system.try_dispatch(), "Dead core allowed a new return")
	_check_conservation(depleted_core, "Dead core storage")
	var freed_core: Fixture = _new_fixture()
	_feed(freed_core, 4)
	_complete_digest(freed_core)
	var core_record: Dictionary = _dispatch(freed_core)
	var core_packet: NutrientPacket = core_record["packet"] as NutrientPacket
	freed_core.core.free()
	core_packet.arrived.emit(core_packet)
	_check(freed_core.system.get_in_transit_count() == 0 and freed_core.organ.get_output_count() == 1
		and freed_core.arrivals.is_empty(), "Freed target leaked transport or emitted a late receipt")
	_check(not freed_core.system.try_dispatch(), "Freed exported target was dereferenced or accepted")
	var wrong_scene: Fixture = _new_fixture()
	_feed(wrong_scene, 4)
	_complete_digest(wrong_scene)
	wrong_scene.system.packet_scene = EDGE_SCENE
	_check(not wrong_scene.system.try_dispatch() and wrong_scene.system.get_in_transit_count() == 0
		and wrong_scene.organ.get_output_products()[0]["status"] == &"queued",
		"Incorrect return scene consumed product ownership")
	_check_conservation(wrong_scene, "Incorrect packet configuration")


func _test_automatic_dispatch_and_resume() -> void:
	var fixture: Fixture = _new_fixture()
	_feed(fixture, 4)
	_complete_digest(fixture)
	_feed(fixture, 4)
	_complete_digest(fixture)
	_feed(fixture, 4)
	_check(fixture.organ.get_output_snapshot()["wait_reason"] == &"output_full",
		"Automatic resume fixture did not begin with full output")
	fixture.organ.digest_timer.wait_time = 0.025
	fixture.system.dispatch_interval = 0.025
	fixture.system.packet_speed = 600.0
	fixture.system.auto_return = true
	fixture.system.get_node("DispatchTimer").start(0.025)
	for frame: int in range(240):
		if fixture.system.delivered_count == 3:
			break
		await physics_frame
	await process_frame
	_check(fixture.organ.digested_count == 3 and fixture.system.delivered_count == 3
		and fixture.organ.get_queued_count() == 0 and fixture.organ.get_output_count() == 0,
		"Automatic dispatch/receipt did not resume and finish blocked digestion")
	_check(fixture.arrivals.size() == 3 and fixture.core.nutrition == fixture.initial_balance + 12,
		"Automatic return missed or duplicated receipt income")
	_check_conservation(fixture, "Automatic return completed")
	fixture.system.reset()
	_check(fixture.system.auto_return, "Return reset changed enabled automatic dispatch mode")


func _free_fixtures() -> void:
	for reference: WeakRef in _hosts:
		var host: Variant = reference.get_ref()
		if is_instance_valid(host):
			host.free()
	_hosts.clear()
