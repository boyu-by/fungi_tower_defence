extends SceneTree
## 主代理串行执行：真实有限侧枝、显式菌结接入、同任务改向与唯一材料退款。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const EPSILON: float = 0.001

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var start: HyphaNode
	var network: NetworkSystem
	var planner: GrowthPlanner
	var growth: GrowthSystem
	var nodes: Node2D
	var edges: Node2D
	var tips: Node2D
	var packets: Node2D
	var supply: GrowthSupplySystem
	var tracker: CargoPassageTracker
	var formed: PackedVector2Array = PackedVector2Array()

	func dispose() -> void:
		if is_instance_valid(supply):
			supply.reset()
		world.free()

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_bounded_paid_branches()
	_test_explicit_auto_join()
	_test_crossing_is_not_a_junction()
	_test_deferred_retarget()
	_test_unpaid_and_paused_retarget()
	_test_buffer_excess_refund()
	_test_transit_excess_refund()
	print("STAGE10_GROWTH_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _container(parent: Node2D) -> Node2D:
	var result: Node2D = Node2D.new()
	parent.add_child(result)
	return result


func _fixture(with_supply: bool = false) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.world.add_child(fixture.core)
	fixture.core.global_position = Vector2(40.0, 200.0)
	fixture.nodes = _container(fixture.world)
	fixture.edges = _container(fixture.world)
	fixture.tips = _container(fixture.world)
	fixture.packets = _container(fixture.world)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.network.register_node(fixture.core, true)
	fixture.start = _node(fixture, Vector2(120.0, 200.0))
	_edge(fixture, fixture.core, fixture.start)
	fixture.planner = GrowthPlanner.new()
	fixture.growth = GrowthSystem.new()
	fixture.growth.planner = fixture.planner
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = fixture.nodes
	fixture.growth.edge_container = fixture.edges
	fixture.growth.tip_container = fixture.tips
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_physics_process(false)
	fixture.growth.junction_formed.connect(func(node: HyphaNode) -> void:
		fixture.formed.append(node.global_position)
	)
	if with_supply:
		fixture.tracker = CargoPassageTracker.new()
		fixture.world.add_child(fixture.tracker)
		fixture.supply = GrowthSupplySystem.new()
		fixture.supply.growth_system = fixture.growth
		fixture.supply.mother_core = fixture.core
		fixture.supply.network_system = fixture.network
		fixture.supply.packet_container = fixture.packets
		fixture.supply.cargo_passage_tracker = fixture.tracker
		fixture.supply.auto_supply = false
		fixture.world.add_child(fixture.supply)
		fixture.supply.set_process(false)
	return fixture


func _node(fixture: Fixture, position: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.nodes.add_child(node)
	node.global_position = position
	fixture.network.register_node(node)
	return node


func _edge(fixture: Fixture, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	fixture.edges.add_child(edge)
	edge.set_process(false)
	fixture.network.register_edge(edge)
	return edge


func _test_bounded_paid_branches() -> void:
	var fixture: Fixture = _fixture()
	var target: Vector2 = Vector2(540.0, 200.0)
	var legacy: Dictionary = fixture.planner.plan(fixture.core.global_position, target)
	_check(fixture.growth.preview_target(fixture.core, target)["total_cost"] == legacy["total_cost"], "Stage10 options default to the original price")
	var terrain: TerrainNavigation = TerrainNavigation.new()
	terrain.bounds = Rect2(0.0, 0.0, 600.0, 400.0)
	terrain.obstacles = [Rect2(260.0, 110.0, 80.0, 180.0)]
	fixture.world.add_child(terrain)
	fixture.planner.terrain_navigation = terrain
	fixture.planner.bounded_branches_enabled = true
	var plan: Dictionary = fixture.growth.preview_target(fixture.core, target)
	_check(bool(plan["valid"]) and int(plan["branch_count"]) > 0, "A terrain route quotes suitable finite branches")
	_check(plan == fixture.growth.preview_target(fixture.core, target), "Network-aware plans are deterministic")
	var branch_counts: Dictionary[int, int] = {}
	var quoted: int = 0
	for segment: Dictionary in plan["segments"]:
		quoted += int(segment["total_cost"])
		_check(terrain.is_segment_clear(segment["start_position"], segment["end_position"], 10.0), "Every quoted main and side edge clears terrain")
		if bool(segment.get("is_branch", false)):
			var main_index: int = int(segment["main_segment_index"])
			branch_counts[main_index] = branch_counts.get(main_index, 0) + 1
			_check(float(segment["length"]) <= 48.0 + EPSILON, "A side branch is at most 48 pixels")
			_check(branch_counts[main_index] <= 1, "At most one branch belongs to a main segment")
	_check(quoted == int(plan["total_cost"]), "The full quote pays for every actual edge and junction")
	var task_id: int = fixture.growth.create_target(fixture.core, target)
	_check(fixture.growth.receive_nutrition(task_id, 1, quoted), "Only delivered materials fund the bounded plan")
	fixture.growth.advance(float(plan["distance"]) / fixture.growth.growth_speed + 1.0)
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"completed" and int(snapshot["consumed_nutrition"]) == quoted, "Finite branches finish at exactly their quoted cost")
	_check(fixture.formed == plan["junction_positions"], "Every paid main and side junction is actually formed")
	_check(fixture.edges.get_child_count() == (plan["segments"] as Array).size() + 1, "All quoted branches are real edges")
	_check(fixture.growth.get_completed_endpoint(task_id).global_position == target, "Completion retains the main endpoint identity")
	for edge: HyphaEdge in fixture.network.get_registered_edges():
		_check(terrain.is_segment_clear(edge.start_node.global_position, edge.end_node.global_position, 10.0), "Actual branch geometry also clears terrain")
	fixture.dispose()


func _test_explicit_auto_join() -> void:
	var fixture: Fixture = _fixture()
	fixture.planner.auto_join_enabled = true
	fixture.planner.bounded_branches_enabled = true
	var endpoint: HyphaNode = _node(fixture, Vector2(440.0, 200.0))
	var requested: Vector2 = endpoint.global_position + Vector2(8.0, 3.0)
	var plan: Dictionary = fixture.growth.preview_target(fixture.start, requested)
	_check(bool(plan["valid"]) and plan["join_node"] == endpoint, "Growth selects a distinct nearby registered HyphaNode")
	_check(plan["end_position"] == endpoint.global_position, "Auto join quotes the real snapped route")
	var segments: Array[Dictionary] = plan["segments"]
	_check(int(segments[-1]["junction_cost"]) == 0, "The existing endpoint has no second node fee")
	var old_node_count: int = fixture.nodes.get_child_count()
	var task_id: int = fixture.growth.create_target(fixture.start, requested)
	fixture.growth.receive_nutrition(task_id, 1, int(plan["total_cost"]))
	fixture.growth.advance(float(plan["distance"]) / fixture.growth.growth_speed + 1.0)
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"completed" and fixture.growth.get_completed_endpoint(task_id) == endpoint, "Auto join commits the existing endpoint identity")
	_check(snapshot["target_position"] == requested and snapshot["resolved_target_position"] == endpoint.global_position, "Requested and snapped target positions stay distinct")
	_check(fixture.nodes.get_child_count() == old_node_count + fixture.formed.size(), "Auto join creates no duplicate endpoint node")
	_check(fixture.network.has_direct_connection(fixture.start, endpoint), "The real construction corridor is registered")
	var edges_before: int = fixture.edges.get_child_count()
	_check(fixture.growth.create_target(fixture.start, endpoint.global_position) == 0 \
		and fixture.edges.get_child_count() == edges_before, "An existing corridor cannot be constructed twice")
	fixture.dispose()


func _test_crossing_is_not_a_junction() -> void:
	var fixture: Fixture = _fixture()
	fixture.planner.auto_join_enabled = true
	var upper: HyphaNode = _node(fixture, Vector2(240.0, 100.0))
	var lower: HyphaNode = _node(fixture, Vector2(240.0, 300.0))
	_edge(fixture, upper, lower)
	var target: Vector2 = Vector2(440.0, 200.0)
	var plan: Dictionary = fixture.growth.preview_target(fixture.core, target)
	var task_id: int = fixture.growth.create_target(fixture.core, target)
	fixture.growth.receive_nutrition(task_id, 1, int(plan["total_cost"]))
	fixture.growth.advance(100.0)
	_check(not fixture.network.find_route(upper, fixture.growth.get_completed_endpoint(task_id)).found, "Crossing edges do not create an implicit graph junction")
	for node: Node2D in fixture.network.get_registered_nodes():
		_check(node.global_position != Vector2(240.0, 200.0), "A geometric crossing creates no free junction")
	fixture.dispose()


func _test_deferred_retarget() -> void:
	var fixture: Fixture = _fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(400.0, 200.0), 7)
	var original: Dictionary = fixture.growth.get_task_snapshot()
	fixture.growth.receive_nutrition(task_id, 1, int(original["total_cost"]))
	fixture.growth.advance(0.5)
	var before: Dictionary = fixture.growth.get_task_snapshot()
	var before_tip: Node2D = fixture.growth.get_delivery_target(task_id)
	var replacement: Vector2 = Vector2(160.0, 320.0)
	var preview: Dictionary = fixture.growth.preview_retarget(replacement)
	_check(bool(preview["valid"]) and bool(preview["deferred"]) \
		and preview["effective_point"] == Vector2(160.0, 200.0), "Paid-segment retarget takes effect at its original endpoint")
	_check(int(preview["old_remaining_cost"]) == int(before["remaining_cost"]) \
		and int(preview["cost_delta"]) == int(preview["new_remaining_cost"]) - int(before["remaining_cost"]), "Retarget reports the exact remaining price change")
	_check(fixture.growth.retarget_target(replacement), "A live growth task accepts the replacement route")
	var changed: Dictionary = fixture.growth.get_task_snapshot()
	_check(int(changed["task_id"]) == task_id and int(changed["plan_version"]) == 8 \
		and fixture.growth.get_delivery_target(task_id) == before_tip, "Retarget preserves task and tip identities and advances the adopted plan version")
	_check(changed["target_position"] == replacement and bool(changed["retarget_pending"]) \
		and changed["tip_position"] == before["tip_position"] \
		and changed["consumed_nutrition"] == before["consumed_nutrition"], "The desired target changes immediately while paid geometry and consumption are preserved")
	var withdrawn: int = fixture.growth.take_excess_nutrition(task_id)
	_check(withdrawn == maxi(0, int(before["buffered_nutrition"]) - int(changed["remaining_cost"])) \
		and fixture.growth.take_excess_nutrition(task_id) == 0, "Only real unconsumed excess can be withdrawn once")
	var stable: Dictionary = fixture.growth.get_task_snapshot()
	_check(not fixture.growth.retarget_target(Vector2(INF, 320.0)) \
		and stable == fixture.growth.get_task_snapshot(), "An invalid replacement leaves the old live task intact")
	var terrain: TerrainNavigation = TerrainNavigation.new()
	terrain.bounds = Rect2(0.0, 0.0, 600.0, 400.0)
	terrain.obstacles = [Rect2(290.0, 300.0, 20.0, 40.0)]
	fixture.world.add_child(terrain)
	fixture.planner.terrain_navigation = terrain
	_check(not fixture.growth.retarget_target(Vector2(300.0, 320.0)) \
		and stable == fixture.growth.get_task_snapshot(), "A terrain-blocked replacement preserves the already paid route and version")
	fixture.growth.advance(100.0)
	var completed: Dictionary = fixture.growth.get_task_snapshot()
	_check(completed["state"] == &"completed" and not bool(completed["retarget_pending"]) \
		and fixture.growth.get_completed_endpoint(task_id).global_position == replacement, "The replacement route finishes without retaining the obsolete route")
	_check(fixture.formed.has(Vector2(160.0, 200.0)) and not fixture.formed.has(Vector2(280.0, 200.0)), "The paid segment survives and unpaid old junctions are never formed")
	_check(completed["consumed_nutrition"] == completed["total_cost"], "Paid boundary plus new route consume exactly the revised total")
	fixture.dispose()


func _test_unpaid_and_paused_retarget() -> void:
	var fixture: Fixture = _fixture()
	var task_id: int = fixture.growth.create_target(fixture.start, Vector2(480.0, 200.0))
	fixture.growth.pause_task()
	var replacement: Vector2 = Vector2(180.0, 260.0)
	var preview: Dictionary = fixture.growth.preview_retarget(replacement)
	_check(bool(preview["valid"]) and not bool(preview["deferred"]) \
		and preview["effective_point"] == fixture.start.global_position, "An unpaid segment replans immediately from its current anchor")
	_check(fixture.growth.retarget_target(replacement), "A paused growth task can safely change its unpaid route")
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"paused" and int(snapshot["plan_version"]) == 2 \
		and not bool(snapshot["retarget_pending"]), "Changing a paused route retains its paused state")
	fixture.growth.receive_nutrition(task_id, 1, int(snapshot["total_cost"]))
	fixture.growth.advance(100.0)
	_check(fixture.formed.is_empty(), "Paused retarget does not build geometry")
	fixture.growth.resume_task()
	fixture.growth.advance(100.0)
	_check(fixture.growth.get_completed_endpoint(task_id).global_position == replacement, "Resuming uses only the replacement plan")
	fixture.dispose()


func _dispatch_all(fixture: Fixture) -> int:
	var count: int = 0
	for attempt: int in range(128):
		if not fixture.supply.try_dispatch():
			break
		count += 1
	for child: Node in fixture.packets.get_children():
		child.set_physics_process(false)
	return count


func _deliver_all(fixture: Fixture) -> void:
	for record: Dictionary in fixture.supply.get_shipment_records():
		var packet: Variant = record["packet"]
		if not bool(record["settled"]) and is_instance_valid(packet) and not packet.is_queued_for_deletion():
			packet._physics_process(1000.0)


func _test_buffer_excess_refund() -> void:
	var fixture: Fixture = _fixture(true)
	fixture.planner.junction_spacing = 2000.0
	var task_id: int = fixture.growth.create_target(fixture.start, Vector2(1200.0, 200.0))
	var sent: int = _dispatch_all(fixture)
	_deliver_all(fixture)
	var old_balance: int = fixture.core.nutrition
	_check(sent > 5 and int(fixture.growth.get_task_snapshot()["buffered_nutrition"]) == sent, "Real supply packets arrive before any growth investment")
	_check(fixture.growth.retarget_target(fixture.start.global_position + Vector2(1.0, 0.0)), "Shortening an unpaid route retains its task")
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(int(snapshot["buffered_nutrition"]) == 5 and fixture.core.nutrition == old_balance + sent - 5, "Only buffered material above the revised total returns to its original source")
	var refunded: int = 0
	for record: Dictionary in fixture.supply.get_shipment_records():
		var cargo: Dictionary = fixture.tracker.get_cargo_snapshot(String(record["cargo_id"]))
		if bool(record["refunded"]):
			refunded += 1
			_check(cargo["status"] == &"discarded", "Refunded buffer cargo cannot confirm main-vein passage")
			var packet: Variant = record["packet"]
			if is_instance_valid(packet):
				packet.arrived.emit(packet)
	_check(refunded == sent - 5 and fixture.core.nutrition == 72 - 5, "Replayed old arrival callbacks cannot duplicate the excess refund")
	fixture.growth.advance(100.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed" \
		and int(fixture.growth.get_task_snapshot()["consumed_nutrition"]) == 5, "Kept buffer funds the exact revised construction")
	_check(fixture.tracker.get_confirmed_passages().size() == 5, "Only the five actually consumed cargo identities confirm passage")
	_check(fixture.core.nutrition + int(fixture.growth.get_resource_snapshot()["consumed_nutrition"]) == 72, "Retarget refunds preserve the original capital ledger")
	fixture.dispose()


func _test_transit_excess_refund() -> void:
	var fixture: Fixture = _fixture(true)
	fixture.planner.junction_spacing = 2000.0
	var task_id: int = fixture.growth.create_target(fixture.start, Vector2(1200.0, 200.0))
	var sent: int = _dispatch_all(fixture)
	_check(sent > 5 and fixture.supply.get_in_transit_count() == sent, "Long first investment has uniquely paid packets in flight")
	_check(fixture.growth.retarget_target(fixture.start.global_position + Vector2(1.0, 0.0)), "Retarget accepts a smaller route with existing transit")
	_check(fixture.supply.get_in_transit_count() == 5 and fixture.core.nutrition == 72 - 5, "Only transit exceeding the full revised obligation is cancelled and refunded")
	for record: Dictionary in fixture.supply.get_shipment_records():
		if int(record["shipment_id"]) <= 5:
			_check(not bool(record["settled"]) and not bool(record["refunded"]) \
				and int(record["task_id"]) == task_id, "Useful old packets retain their cargo and task identity")
		else:
			_check(bool(record["refunded"]) \
				and fixture.tracker.get_cargo_snapshot(String(record["cargo_id"]))["status"] == &"discarded", "True excess transit is discarded exactly once")
	_deliver_all(fixture)
	fixture.growth.advance(100.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed" \
		and int(fixture.growth.get_task_snapshot()["consumed_nutrition"]) == 5 \
		and fixture.core.nutrition == 67, "Preserved old cargo completes the new route without redispatch or duplicate debit")
	fixture.dispose()
