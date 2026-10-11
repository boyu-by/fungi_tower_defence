extends SceneTree
## 实际拾取后才排队；真实遗骸包和黄包共用调度器，不加载业务或关卡。

class Fixture:
	extends RefCounted

	var host: Node2D
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var nodes: Array[Node2D] = []
	var edges: Array[HyphaEdge] = []


class Outcome:
	extends RefCounted

	var arrivals: int = 0
	var interruptions: int = 0
	var position: Vector2 = Vector2.ZERO
	var statuses: Array[Dictionary] = []


class Reentry:
	extends RefCounted

	var done: bool = false
	var notifications: int = 0
	var token: String = ""
	var request_id: String = ""


const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/remains_packet.tscn")
const NUTRIENT_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")

var failures: Array[String] = []
var checks: int = 0
var _objects: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_pickup_before_capacity_and_pure_snapshots()
	_test_remains_exclusive_occupancy()
	_test_large_fifo_head_blocks_small_packets()
	_test_multi_hop_wait_and_motion_budget()
	_test_closed_entry_and_capacity_changes()
	_test_zero_length_requires_a_lease()
	_test_cancel_pickup_wait_and_move()
	_test_target_and_traversed_edge_invalidation()
	_test_required_dependencies()
	_test_dispatcher_loss_reset_and_cancellation()
	_test_legacy_and_zero_routes()
	_test_request_reentry()
	_test_release_reentry()
	_test_status_reentry()
	await _test_direct_packet_removal()
	_free_objects()
	_check(root.get_child_count() == initial_children, "Cleanup left traffic fixtures in the tree")
	print("REMAINS_TRAFFIC_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _position(actual: Vector2, expected: Vector2, context: String) -> void:
	_check(actual.distance_to(expected) < 0.001, context + ": position %s expected %s" % [actual, expected])


func _outcome(outcome: Outcome, arrivals: int, interruptions: int, context: String) -> void:
	_check(outcome.arrivals == arrivals and outcome.interruptions == interruptions,
		context + ": arrived/interrupted %d/%d expected %d/%d" %
		[outcome.arrivals, outcome.interruptions, arrivals, interruptions])


func _track(node: Node) -> void:
	_objects.append(weakref(node))


func _fixture(points: PackedVector2Array = PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0)])) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.host = Node2D.new()
	_track(fixture.host)
	root.add_child(fixture.host)
	fixture.network = NetworkSystem.new()
	fixture.host.add_child(fixture.network)
	for point: Vector2 in points:
		var node: Node2D = Node2D.new()
		fixture.host.add_child(node)
		node.global_position = point
		fixture.nodes.append(node)
		_check(fixture.network.register_node(node, fixture.nodes.size() == 1), "Register fixture node")
	for index: int in range(points.size() - 1):
		var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
		edge.start_node = fixture.nodes[index + 1] if index % 2 == 1 else fixture.nodes[index]
		edge.end_node = fixture.nodes[index] if index % 2 == 1 else fixture.nodes[index + 1]
		fixture.host.add_child(edge)
		edge.set_process(false)
		fixture.edges.append(edge)
		_check(fixture.network.register_edge(edge), "Register fixture edge")
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.host.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	return fixture


func _route(fixture: Fixture, reverse: bool = false) -> NetworkRoute:
	return fixture.network.find_route(
		fixture.nodes[-1] if reverse else fixture.nodes[0],
		fixture.nodes[0] if reverse else fixture.nodes[-1])


func _remains(fixture: Fixture, outcome: Outcome, at: Vector2 = Vector2.ZERO) -> RemainsPacket:
	var packet: RemainsPacket = REMAINS_SCENE.instantiate() as RemainsPacket
	_track(packet)
	packet.arrived.connect(_on_arrived.bind(outcome))
	packet.interrupted.connect(_on_interrupted.bind(outcome))
	packet.status_changed.connect(_on_status.bind(outcome))
	packet.speed = 100.0
	fixture.host.add_child(packet)
	packet.global_position = at
	packet.set_physics_process(false)
	return packet


func _small(fixture: Fixture, outcome: Outcome, reverse: bool, kind: StringName) -> NutrientPacket:
	var packet: NutrientPacket = NUTRIENT_SCENE.instantiate() as NutrientPacket
	_track(packet)
	packet.arrived.connect(_on_arrived.bind(outcome))
	packet.interrupted.connect(_on_interrupted.bind(outcome))
	packet.speed = 100.0
	fixture.host.add_child(packet)
	packet.set_physics_process(false)
	packet.start_route(_route(fixture, reverse), fixture.network, fixture.traffic,
		"small:%d" % packet.get_instance_id(), kind)
	return packet


func _on_arrived(packet: Node2D, outcome: Outcome) -> void:
	outcome.arrivals += 1
	outcome.position = packet.global_position


func _on_interrupted(packet: Node2D, outcome: Outcome) -> void:
	outcome.interruptions += 1
	outcome.position = packet.global_position


func _on_status(snapshot: Dictionary, outcome: Outcome) -> void:
	outcome.statuses.append(snapshot.duplicate())


func _block(fixture: Fixture, edge_index: int, kind: StringName = &"supply") -> Dictionary:
	var owner: Node = Node.new()
	fixture.host.add_child(owner)
	return fixture.traffic.request_passage("block:%d" % owner.get_instance_id(), owner,
		"block-task:%d" % owner.get_instance_id(), fixture.edges[edge_index],
		fixture.nodes[edge_index + 1], fixture.nodes[edge_index], kind)


func _start(packet: RemainsPacket, fixture: Fixture, task_id: String = "") -> void:
	packet.start_route(_route(fixture), fixture.network, fixture.traffic, task_id)


func _step(packet: RemainsPacket, delta: float) -> void:
	packet._physics_process(delta)


func _test_pickup_before_capacity_and_pure_snapshots() -> void:
	var fixture: Fixture = _fixture()
	var outcome: Outcome = Outcome.new()
	var packet: RemainsPacket = _remains(fixture, outcome, Vector2(-100.0, 0.0))
	var idle: Dictionary = packet.get_transport_snapshot()
	_check(idle["state"] == &"idle" and idle["cargo_kind"] == &"remains" and idle["units"] == 2,
		"Idle snapshot has the fixed remains cargo contract")
	_start(packet, fixture, "pickup-task")
	_position(packet.global_position, Vector2(-100.0, 0.0), "Start preserves ground position")
	_check(packet.get_transport_snapshot()["state"] == &"pickup"
		and packet.get_transport_snapshot()["current_node"] == null, "Ground pickup is a separate state")
	_step(packet, 0.25)
	_position(packet.global_position, Vector2(-75.0, 0.0), "Pickup actually moves on the ground")
	_check(fixture.traffic.get_snapshot()["active_request_count"] == 0,
		"Pickup does not queue or occupy an edge")
	var blocker: Dictionary = _block(fixture, 0)
	_step(packet, 1.75)
	var waiting: Dictionary = packet.get_transport_snapshot()
	_position(packet.global_position, Vector2.ZERO, "Overshooting pickup waits at the collection node")
	_check(waiting["state"] == &"waiting" and waiting["wait_reason"] == &"capacity"
		and waiting["current_node"] == fixture.nodes[0] and waiting["token"] == "",
		"Pickup then capacity wait exposes the collection node without a token")
	var request_id: String = waiting["request_id"]
	_check(not request_id.is_empty() and fixture.traffic.get_snapshot()["queued_count"] == 1,
		"Exactly one remains request is queued after pickup")
	var reentry: Reentry = Reentry.new()
	fixture.traffic.traffic_changed.connect(func() -> void: reentry.notifications += 1)
	var sequence: int = int(fixture.traffic.get_request(request_id)["sequence"])
	for _read: int in range(5):
		var snapshot: Dictionary = packet.get_transport_snapshot()
		snapshot["state"] = &"completed"
		snapshot["token"] = "fake"
		fixture.traffic.get_request(request_id)
		fixture.traffic.get_lease("missing")
	_check(reentry.notifications == 0 and packet.get_transport_snapshot()["state"] == &"waiting",
		"Snapshot reads and caller mutation have no transport or scheduler effects")
	_step(packet, 5.0)
	_check(packet.get_transport_snapshot()["request_id"] == request_id
		and int(fixture.traffic.get_request(request_id)["sequence"]) == sequence,
		"Waiting preserves one request and its FIFO sequence")
	_outcome(outcome, 0, 0, "Long wait has no premature terminal event")
	fixture.traffic.release(String(blocker["token"]))
	_step(packet, 0.25)
	_position(packet.global_position, Vector2(25.0, 0.0), "Wait and pickup overshoot never accumulate motion")
	_check(fixture.traffic.get_edge_snapshot(fixture.edges[0])["occupied_units"] == 2,
		"Remains holds both units only after grant")
	_step(packet, 0.75)
	var terminal: Dictionary = packet.get_transport_snapshot()
	_outcome(outcome, 1, 0, "Picked up packet arrives once")
	_check(terminal["state"] == &"completed" and terminal["request_id"] == "" and terminal["token"] == ""
		and terminal["task_id"] == "pickup-task" and terminal["traffic_system_id"] == fixture.traffic.get_instance_id()
		and terminal["completed_segments"] == 1 and is_equal_approx(terminal["progress"], 1.0),
		"Terminal clears handles and retains task, dispatcher and legacy progress")
	_check(fixture.traffic.get_snapshot()["occupied_units"] == 0, "Arrival releases both units")


func _test_remains_exclusive_occupancy() -> void:
	var fixture: Fixture = _fixture()
	var ordinary_outcome: Outcome = Outcome.new()
	var ordinary: RemainsPacket = _remains(fixture, ordinary_outcome)
	ordinary.set_meta("nutrition_value", 4)
	_start(ordinary, fixture)
	var batch_outcome: Outcome = Outcome.new()
	var batch: RemainsPacket = _remains(fixture, batch_outcome)
	batch.set_meta("nutrition_value", 80)
	batch.set_meta("carcass_batch_id", "large-batch")
	_start(batch, fixture)
	var small_outcome: Outcome = Outcome.new()
	var small: NutrientPacket = _small(fixture, small_outcome, true, &"return")
	var edge_snapshot: Dictionary = fixture.traffic.get_edge_snapshot(fixture.edges[0])
	_check(edge_snapshot["occupied_units"] == 2 and edge_snapshot["leases"].size() == 1,
		"An ordinary remains packet exclusively occupies the shared edge")
	_check(ordinary.get_transport_snapshot()["task_id"] != batch.get_transport_snapshot()["task_id"],
		"Empty task ids use unique packet instance scopes")
	_check(batch.get_transport_snapshot()["units"] == 2 and edge_snapshot["queue"].size() == 2,
		"A large carcass batch uses the same two units irrespective of nutrition")
	_outcome(batch_outcome, 0, 0, "Batch waiting is not an interruption")
	_outcome(small_outcome, 0, 0, "Opposite direction small packet also waits")
	_step(ordinary, 1.0)
	edge_snapshot = fixture.traffic.get_edge_snapshot(fixture.edges[0])
	_check(edge_snapshot["leases"][0]["owner_id"] == batch.get_instance_id()
		and edge_snapshot["occupied_units"] == 2, "Batch becomes the sole lease after the corpse")
	_step(batch, 1.0)
	_check(fixture.traffic.get_edge_snapshot(fixture.edges[0])["occupied_units"] == 1,
		"Yellow return gets one unit after the batch releases")
	small._physics_process(1.0)
	_outcome(ordinary_outcome, 1, 0, "Ordinary remains terminal result")
	_outcome(batch_outcome, 1, 0, "Carcass batch terminal result")
	_outcome(small_outcome, 1, 0, "Yellow return terminal result")


func _test_large_fifo_head_blocks_small_packets() -> void:
	var fixture: Fixture = _fixture()
	var first_outcome: Outcome = Outcome.new()
	var first: NutrientPacket = _small(fixture, first_outcome, false, &"supply")
	var big_outcome: Outcome = Outcome.new()
	var big: RemainsPacket = _remains(fixture, big_outcome, Vector2(100.0, 0.0))
	big.start_route(_route(fixture, true), fixture.network, fixture.traffic, "large-head")
	var later_outcome: Outcome = Outcome.new()
	var later: NutrientPacket = _small(fixture, later_outcome, false, &"return")
	var edge_snapshot: Dictionary = fixture.traffic.get_edge_snapshot(fixture.edges[0])
	_check(edge_snapshot["available_units"] == 1 and edge_snapshot["queue"].size() == 2
		and edge_snapshot["queue"][0]["owner_id"] == big.get_instance_id()
		and edge_snapshot["queue"][1]["owner_id"] == later.get_instance_id(),
		"Large FIFO head blocks a later small even when one unit is available")
	later._physics_process(10.0)
	_position(later.global_position, Vector2.ZERO, "Yellow packet cannot bypass the large head")
	_outcome(later_outcome, 0, 0, "FIFO wait never reports arrival or failure")
	first._physics_process(1.0)
	_step(big, 0.5)
	_position(big.global_position, Vector2(50.0, 0.0), "Reverse remains moves with both shared units")
	_check(fixture.traffic.get_edge_snapshot(fixture.edges[0])["occupied_units"] == 2,
		"Reverse travel occupies the same pool")
	_step(big, 0.5)
	later._physics_process(0.1)
	_position(later.global_position, Vector2(10.0, 0.0), "Yellow waiting budget was discarded")
	later._physics_process(0.9)
	_outcome(big_outcome, 1, 0, "Large head finishes once")
	_outcome(later_outcome, 1, 0, "Later yellow finishes in FIFO order")


func _test_multi_hop_wait_and_motion_budget() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0), Vector2(300.0, 0.0)]))
	var blocker: Dictionary = _block(fixture, 1, &"remains")
	var outcome: Outcome = Outcome.new()
	var packet: RemainsPacket = _remains(fixture, outcome)
	_start(packet, fixture)
	var first: Dictionary = packet.get_transport_snapshot()
	_step(packet, 10.0)
	var waiting: Dictionary = packet.get_transport_snapshot()
	_position(packet.global_position, Vector2(100.0, 0.0), "Next-hop queue waits at the intermediate node")
	_check(waiting["segment_index"] == 1 and waiting["completed_segments"] == 1
		and waiting["current_node"] == fixture.nodes[1] and is_zero_approx(waiting["progress"])
		and waiting["token"] == "" and waiting["request_id"] != first["request_id"],
		"Cross-hop commit releases the old handle and queues one new hop")
	_check(fixture.traffic.get_edge_snapshot(fixture.edges[0])["occupied_units"] == 0
		and fixture.traffic.get_edge_snapshot(fixture.edges[2])["occupied_units"] == 0,
		"No old or future edge is held while the next hop waits")
	_check(not fixture.traffic.release(String(first["token"])), "Duplicate old-hop release has no effect")
	_step(packet, 5.0)
	_position(packet.global_position, Vector2(100.0, 0.0), "Long wait never resets to the route source")
	_outcome(outcome, 0, 0, "Intermediate wait has no terminal event")
	fixture.traffic.release(String(blocker["token"]))
	_step(packet, 0.25)
	_position(packet.global_position, Vector2(125.0, 0.0), "Next hop uses only the new frame distance")
	_check(fixture.traffic.get_snapshot()["active_lease_count"] == 1,
		"A packet has at most one active edge lease")
	_step(packet, 1.75)
	_outcome(outcome, 1, 0, "One overshoot can cross later granted hops")
	_position(outcome.position, Vector2(300.0, 0.0), "Multi-hop endpoint")
	var completed: Dictionary = packet.get_transport_snapshot()
	_check(completed["completed_segments"] == 3 and completed["segment_index"] == 2
		and completed["token"] == "" and completed["request_id"] == "", "Multi-hop terminal counters and handles")


func _test_closed_entry_and_capacity_changes() -> void:
	var fixture: Fixture = _fixture()
	fixture.edges[0].traffic_capacity = 0
	var outcome: Outcome = Outcome.new()
	var packet: RemainsPacket = _remains(fixture, outcome)
	_start(packet, fixture)
	_check(packet.get_transport_snapshot()["state"] == &"waiting"
		and packet.get_transport_snapshot()["wait_reason"] == &"capacity"
		and packet.get_transport_snapshot()["request_id"] == "",
		"Nominal capacity below two is a normal pre-admission wait")
	_step(packet, 10.0)
	_check(fixture.traffic.get_snapshot()["active_request_count"] == 0,
		"Too-small nominal capacity never submits repeated rejected requests")
	fixture.edges[0].entry_enabled = false
	fixture.edges[0].traffic_capacity = 2
	_step(packet, 0.0)
	var request_id: String = packet.get_transport_snapshot()["request_id"]
	_check(request_id.is_empty() and packet.get_transport_snapshot()["wait_reason"] == &"no_route",
		"Closed only route retains cargo at its node without an obsolete edge request")
	fixture.edges[0].traffic_capacity = 1
	_step(packet, 10.0)
	fixture.edges[0].entry_enabled = true
	_step(packet, 10.0)
	_check(packet.get_transport_snapshot()["request_id"] == request_id
		and packet.get_transport_snapshot()["wait_reason"] == &"no_route"
		and fixture.traffic.get_snapshot()["active_request_count"] == 0,
		"Still-undersized route remains a nonterminal wait without repeated admission")
	_position(packet.global_position, Vector2.ZERO, "Closed or undersized edge never moves the packet")
	_outcome(outcome, 0, 0, "Temporary entry and capacity changes are not failures")
	fixture.edges[0].traffic_capacity = 2
	_step(packet, 1.0)
	_outcome(outcome, 1, 0, "Restoring capacity grants the existing request")


func _test_zero_length_requires_a_lease() -> void:
	var fixture: Fixture = _fixture(PackedVector2Array([Vector2.ZERO, Vector2.ZERO]))
	fixture.edges[0].entry_enabled = false
	var outcome: Outcome = Outcome.new()
	var packet: RemainsPacket = _remains(fixture, outcome)
	_start(packet, fixture)
	_step(packet, 100.0)
	_outcome(outcome, 0, 0, "Zero-length edge still waits for admission")
	fixture.edges[0].entry_enabled = true
	_outcome(outcome, 0, 0, "Scheduler grant alone does not move or terminate a packet")
	_step(packet, 0.0)
	_outcome(outcome, 1, 0, "Granted zero-length edge completes exactly once")
	var saw_token: bool = false
	for snapshot: Dictionary in outcome.statuses:
		if snapshot["state"] == &"moving" and not String(snapshot["token"]).is_empty():
			saw_token = true
	_check(saw_token and packet.get_transport_snapshot()["completed_segments"] == 1,
		"Even zero-length movement observed a valid two-unit token")
	_check(fixture.traffic.get_snapshot()["active_lease_count"] == 0, "Zero-length completion released its token")


func _test_cancel_pickup_wait_and_move() -> void:
	for phase: String in ["pickup", "waiting", "moving"]:
		var fixture: Fixture = _fixture()
		fixture.edges[0].entry_enabled = phase != "waiting"
		var outcome: Outcome = Outcome.new()
		var packet: RemainsPacket = _remains(fixture, outcome,
			Vector2(-100.0, 0.0) if phase == "pickup" else Vector2.ZERO)
		_start(packet, fixture, "cancel:" + phase)
		_step(packet, 0.25)
		var before: Dictionary = packet.get_transport_snapshot()
		packet.cancel_transport()
		packet.cancel_transport()
		_step(packet, 100.0)
		_outcome(outcome, 0, 1, phase + " cancel stays unique")
		_position(outcome.position, before["position"], phase + " cancel preserves the actual position")
		var terminal: Dictionary = packet.get_transport_snapshot()
		_check(terminal["state"] == &"interrupted" and terminal["token"] == "" and terminal["request_id"] == ""
			and terminal["task_id"] == "cancel:" + phase, phase + " cancellation clears handles and retains task")
		_check(fixture.traffic.get_snapshot()["active_request_count"] == 0
			and fixture.traffic.get_snapshot()["occupied_units"] == 0, phase + " cancellation cleans the scheduler")
		_check(not fixture.traffic.release(String(before["token"]))
			and not fixture.traffic.cancel_request(String(before["request_id"])), phase + " duplicate cleanup is harmless")


func _test_target_and_traversed_edge_invalidation() -> void:
	for phase: String in ["pickup", "waiting", "moving"]:
		for operation: String in ["free", "queue", "unregister"]:
			var fixture: Fixture = _fixture()
			fixture.edges[0].entry_enabled = phase != "waiting"
			var outcome: Outcome = Outcome.new()
			var packet: RemainsPacket = _remains(fixture, outcome,
				Vector2(-100.0, 0.0) if phase == "pickup" else Vector2.ZERO)
			_start(packet, fixture)
			_step(packet, 0.25)
			var before: Vector2 = packet.global_position
			match operation:
				"free": fixture.nodes[-1].free()
				"queue": fixture.nodes[-1].queue_free()
				"unregister": fixture.network.unregister_node(fixture.nodes[-1])
			_step(packet, 100.0)
			packet.cancel_transport()
			_outcome(outcome, 0, 1, phase + " target " + operation + " interrupts once")
			_position(outcome.position, before, "Invalid target never permits further motion")
			_check(fixture.traffic.get_snapshot()["occupied_units"] == 0,
				"Invalid target releases scheduler capacity")
	var fixture: Fixture = _fixture(PackedVector2Array([
		Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)]))
	var outcome: Outcome = Outcome.new()
	var packet: RemainsPacket = _remains(fixture, outcome)
	_start(packet, fixture)
	_step(packet, 1.5)
	fixture.edges[0].free()
	_step(packet, 1.0)
	_outcome(outcome, 1, 0, "Already traversed physical edge no longer invalidates the surviving transport")
	_position(outcome.position, Vector2(200.0, 0.0), "Past-edge loss still reaches the original real destination")


func _test_required_dependencies() -> void:
	for operation: String in ["missing_traffic", "missing_network", "mismatch"]:
		var fixture: Fixture = _fixture()
		var outcome: Outcome = Outcome.new()
		var packet: RemainsPacket = _remains(fixture, outcome, Vector2(-50.0, 0.0))
		match operation:
			"missing_traffic":
				packet.traffic_required = true
				packet.start_route(_route(fixture), fixture.network)
			"missing_network":
				packet.start_route(_route(fixture), null, fixture.traffic)
			"mismatch":
				var other: NetworkSystem = NetworkSystem.new()
				fixture.host.add_child(other)
				fixture.traffic.network_system = other
				_start(packet, fixture)
		_outcome(outcome, 0, 1, operation + " never falls back to legacy movement")
		_position(outcome.position, Vector2(-50.0, 0.0), operation + " interrupts before pickup")
		_check(packet.get_transport_snapshot()["traffic_enabled"], operation + " retains the traffic requirement")


func _test_dispatcher_loss_reset_and_cancellation() -> void:
	for phase: String in ["pickup", "waiting", "moving"]:
		for operation: String in ["reset", "free", "queue", "detach", "replace_network", "free_network", "queue_network", "cancel_request"]:
			if phase == "pickup" and operation == "cancel_request":
				continue
			var fixture: Fixture = _fixture()
			fixture.edges[0].entry_enabled = phase != "waiting"
			var outcome: Outcome = Outcome.new()
			var packet: RemainsPacket = _remains(fixture, outcome,
				Vector2(-100.0, 0.0) if phase == "pickup" else Vector2.ZERO)
			_start(packet, fixture, "loss:" + phase + ":" + operation)
			_step(packet, 0.25)
			var before: Dictionary = packet.get_transport_snapshot()
			match operation:
				"reset": fixture.traffic.reset()
				"free": fixture.traffic.free()
				"queue": fixture.traffic.queue_free()
				"detach":
					fixture.host.remove_child(fixture.traffic)
					_track(fixture.traffic)
				"replace_network":
					var other: NetworkSystem = NetworkSystem.new()
					fixture.host.add_child(other)
					fixture.traffic.network_system = other
				"free_network": fixture.network.free()
				"queue_network": fixture.network.queue_free()
				"cancel_request": fixture.traffic.cancel_request(String(before["request_id"]))
			# 读快照不会偷偷处理调度器丢失；下一运输 tick 才进行终态转换。
			_check(packet.get_transport_snapshot()["state"] == before["state"], "Loss snapshot remains a pure read")
			_step(packet, 100.0)
			packet.cancel_transport()
			_outcome(outcome, 0, 1, phase + " dispatcher " + operation + " interrupts exactly once")
			_position(outcome.position, before["position"], "Dependency loss never falls back to movement")
			var terminal: Dictionary = packet.get_transport_snapshot()
			_check(terminal["traffic_system_id"] == before["traffic_system_id"]
				and terminal["task_id"] == before["task_id"] and terminal["request_id"] == ""
				and terminal["token"] == "", "Dispatcher loss clears active handles and retains original identity")
			if is_instance_valid(fixture.traffic):
				_check(fixture.traffic.get_snapshot()["active_lease_count"] == 0,
					"Surviving dispatcher has no interrupted packet lease")


func _test_legacy_and_zero_routes() -> void:
	var fixture: Fixture = _fixture()
	var outcome: Outcome = Outcome.new()
	var packet: RemainsPacket = _remains(fixture, outcome, Vector2(-50.0, 0.0))
	packet.start_transport(fixture.edges[0], fixture.nodes[0], fixture.nodes[1])
	_step(packet, 0.75)
	_position(packet.global_position, Vector2(25.0, 0.0), "Legacy single-edge pickup shares leftover distance")
	_check(not packet.get_transport_snapshot()["traffic_enabled"] and packet.get_transport_snapshot()["token"] == "",
		"Optional null dispatcher preserves isolated legacy behavior")
	_step(packet, 0.75)
	_outcome(outcome, 1, 0, "Legacy single-edge transport remains valid")
	var reverse_outcome: Outcome = Outcome.new()
	var reverse: RemainsPacket = _remains(fixture, reverse_outcome, Vector2(150.0, 0.0))
	reverse.start_transport(fixture.edges[0], fixture.nodes[1], fixture.nodes[0], fixture.network, fixture.traffic)
	_step(reverse, 1.5)
	_outcome(reverse_outcome, 1, 0, "Extended legacy API supports reverse traffic with pickup")
	var zero: Fixture = _fixture(PackedVector2Array([Vector2.ZERO]))
	var zero_outcome: Outcome = Outcome.new()
	var zero_packet: RemainsPacket = _remains(zero, zero_outcome, Vector2(-50.0, 0.0))
	zero_packet.traffic_required = true
	_start(zero_packet, zero)
	_step(zero_packet, 0.4)
	_position(zero_packet.global_position, Vector2(-10.0, 0.0), "Zero-route still needs actual ground pickup")
	_outcome(zero_outcome, 0, 0, "Zero-route never arrives before pickup")
	_step(zero_packet, 0.1)
	_outcome(zero_outcome, 1, 0, "Zero-route arrives on reaching its collection node")
	_check(zero_packet.get_transport_snapshot()["edge"] == null
		and zero_packet.get_transport_snapshot()["completed_segments"] == 0
		and zero.traffic.get_snapshot()["active_request_count"] == 0,
		"Zero-route creates no edge request or completed segment")


func _test_request_reentry() -> void:
	for operation: String in ["cancel", "remove", "detach_then_free", "reset"]:
		var fixture: Fixture = _fixture()
		var outcome: Outcome = Outcome.new()
		var packet: RemainsPacket = _remains(fixture, outcome)
		var owner_id: int = packet.get_instance_id()
		var reentry: Reentry = Reentry.new()
		fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
			if reentry.done or snapshot["owner_id"] != owner_id or snapshot["state"] != &"granted":
				return
			reentry.done = true
			packet._physics_process(100.0)
			_position(packet.global_position, Vector2.ZERO, "Reentered request callback cannot advance movement")
			match operation:
				"cancel": packet.cancel_transport()
				"remove": fixture.host.remove_child(packet)
				"detach_then_free": fixture.host.remove_child(packet)
				"reset": fixture.traffic.reset()
		)
		_start(packet, fixture)
		if operation == "detach_then_free":
			_free_detached_after_return(packet, outcome, fixture.nodes[0], 0, 0, 0.0,
				"Request callback removes before adopting its request")
		_outcome(outcome, 0, 1, "Request callback " + operation + " terminates once")
		_check(fixture.traffic.get_snapshot()["active_request_count"] == 0
			and fixture.traffic.get_snapshot()["occupied_units"] == 0,
			"Request callback cannot leak an unadopted lease")


func _test_release_reentry() -> void:
	for terminal: bool in [false, true]:
		for operation: String in ["remove", "detach_then_free", "free_target", "reset", "duplicate_release"]:
			var fixture: Fixture = _fixture(PackedVector2Array([
				Vector2.ZERO, Vector2(100.0, 0.0)] if terminal else [
				Vector2.ZERO, Vector2(100.0, 0.0), Vector2(200.0, 0.0)]))
			var outcome: Outcome = Outcome.new()
			var packet: RemainsPacket = _remains(fixture, outcome)
			_start(packet, fixture)
			var reentry: Reentry = Reentry.new()
			reentry.token = packet.get_transport_snapshot()["token"]
			reentry.request_id = packet.get_transport_snapshot()["request_id"]
			var owner_id: int = packet.get_instance_id()
			fixture.traffic.request_changed.connect(func(snapshot: Dictionary) -> void:
				if reentry.done or snapshot["owner_id"] != owner_id or snapshot["state"] != &"released":
					return
				reentry.done = true
				var committed: Dictionary = packet.get_transport_snapshot()
				_check(committed["token"] == "" and committed["request_id"] == ""
					and committed["completed_segments"] == 1 and committed["current_node"] == fixture.nodes[1],
					"Release callback sees committed node and cleared handles")
				packet._physics_process(100.0)
				_position(packet.global_position, Vector2(100.0, 0.0), "Reentered release cannot consume another hop")
				match operation:
					"remove": fixture.host.remove_child(packet)
					"detach_then_free": fixture.host.remove_child(packet)
					"free_target": fixture.nodes[-1].free()
					"reset": fixture.traffic.reset()
					"duplicate_release":
						_check(not fixture.traffic.release(reentry.token)
							and not fixture.traffic.release(reentry.token)
							and not fixture.traffic.cancel_request(reentry.request_id),
							"Duplicate release/cancel during notification is harmless")
			)
			_step(packet, 2.0)
			if operation == "detach_then_free":
				_free_detached_after_return(packet, outcome, fixture.nodes[1],
					0 if terminal else 1, 1, 1.0 if terminal else 0.0,
					"Release callback removes at its committed node")
			_outcome(outcome, 1 if operation == "duplicate_release" else 0,
				0 if operation == "duplicate_release" else 1, "Release callback " + operation + " unique terminal result")
			_check(fixture.traffic.get_snapshot()["occupied_units"] == 0,
				"Release reentry leaves no lease on an old or next edge")


func _test_status_reentry() -> void:
	for state: StringName in [&"waiting", &"moving", &"completed"]:
		for operation: String in ["remove", "detach_then_free", "free_target", "reset"]:
			var fixture: Fixture = _fixture()
			fixture.edges[0].entry_enabled = state != &"waiting"
			var outcome: Outcome = Outcome.new()
			var packet: RemainsPacket = _remains(fixture, outcome)
			var reentry: Reentry = Reentry.new()
			packet.status_changed.connect(func(snapshot: Dictionary) -> void:
				if reentry.done or snapshot["state"] != state:
					return
				reentry.done = true
				match operation:
					"remove": fixture.host.remove_child(packet)
					"detach_then_free": fixture.host.remove_child(packet)
					"free_target": fixture.nodes[-1].free()
					"reset": fixture.traffic.reset()
			)
			_start(packet, fixture)
			if is_instance_valid(packet):
				_step(packet, 1.0)
			if is_instance_valid(packet):
				packet.cancel_transport()
			if operation == "detach_then_free":
				_free_detached_after_return(packet, outcome,
					fixture.nodes[1] if state == &"completed" else fixture.nodes[0], 0,
					1 if state == &"completed" else 0, 1.0 if state == &"completed" else 0.0,
					"Status callback removes without completing delivery")
			_outcome(outcome, 0, 1, "Status " + String(state) + " callback " + operation + " never delivers")
			_check((not is_instance_valid(packet) or packet.get_transport_snapshot()["state"] == &"interrupted")
				and fixture.traffic.get_snapshot()["occupied_units"] == 0,
				"Status reentry commits one interruption and cleans capacity")


## Godot 锁住正在调用或发信号的对象：回调内先离树，调用返回后才实际 free。
func _free_detached_after_return(packet: RemainsPacket, outcome: Outcome, current_node: Node2D,
		segment: int, completed: int, progress: float, context: String) -> void:
	if not is_instance_valid(packet):
		_check(false, context + ": packet should remain valid until the transport call returns")
		return
	_check(not packet.is_inside_tree() and packet.get_parent() == null,
		context + ": callback synchronously exited the tree")
	var snapshot: Dictionary = packet.get_transport_snapshot()
	_check(snapshot["state"] == &"interrupted" and snapshot["wait_reason"] == &"owner_removed"
		and snapshot["request_id"] == "" and snapshot["token"] == "",
		context + ": exit committed interruption and cleared adopted or unadopted handles")
	_check(snapshot["current_node"] == current_node and snapshot["segment_index"] == segment
		and snapshot["completed_segments"] == completed and is_equal_approx(snapshot["progress"], progress),
		context + ": removal preserved current node, completed hops and segment progress")
	_position(snapshot["position"], current_node.global_position, context + ": removal preserved position")
	_outcome(outcome, 0, 1, context + " before physical free")
	packet.free()
	_check(not is_instance_valid(packet), context + ": unlocked detached packet was actually freed")
	_outcome(outcome, 0, 1, context + " after physical free remains unique")


func _test_direct_packet_removal() -> void:
	for waiting: bool in [false, true]:
		var fixture: Fixture = _fixture()
		fixture.edges[0].entry_enabled = not waiting
		var outcome: Outcome = Outcome.new()
		var packet: RemainsPacket = _remains(fixture, outcome)
		_start(packet, fixture)
		packet.queue_free()
		await process_frame
		await process_frame
		_outcome(outcome, 0, 1, "Direct queued removal emits one interruption without another physics tick")
		_check(not is_instance_valid(packet) and fixture.traffic.get_snapshot()["active_request_count"] == 0
			and fixture.traffic.get_snapshot()["occupied_units"] == 0, "Direct removal clears queue and occupancy")


func _free_objects() -> void:
	for reference: WeakRef in _objects:
		var node: Node = reference.get_ref() as Node
		if is_instance_valid(node):
			node.free()
	_objects.clear()
