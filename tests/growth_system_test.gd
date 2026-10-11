extends SceneTree
## 手动 advance 验证生长阶段；营养通过显式投递注入，不依赖运输或母核扣费。

const Growth = preload("res://scripts/growth_system.gd")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const EPSILON: float = 0.0001
const SNAPSHOT_KEYS: Array[String] = [
	"task_id", "state", "wait_reason", "progress", "distance", "total_distance",
	"consumed_nutrition", "buffered_nutrition", "total_cost", "remaining_cost",
	"requested_nutrition", "start_node", "target_position", "tip_position", "formed_junctions",
	"task_kind", "target_node",
]

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var network: NetworkSystem
	var growth: GrowthSystem
	var nodes: Node2D
	var edges: Node2D
	var tips: Node2D
	var formed: Array[HyphaNode] = []
	var completed: Array[int] = []
	var cancelled: Array[int] = []
	var terminal_snapshots: Array[Dictionary] = []

	func dispose() -> void:
		world.free()


var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_idle_validation_and_creation()
	_test_shortage_and_refill()
	_test_planner_boundaries()
	_test_positions_and_mature_start()
	_test_pause_and_resume()
	_test_disconnection_recovery()
	_test_speed_and_invalid_delta()
	_test_cancelled_buffers_and_ids()
	_test_cancelled_geometry()
	_test_shipments_and_supply_reasons()
	_test_zero_extension_investment()
	_test_freed_references()
	_test_synchronous_callbacks()
	print("GROWTH_SYSTEM_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _make_fixture(start_position: Vector2 = Vector2.ZERO) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	fixture.core.add_child(health_bar)
	fixture.world.add_child(fixture.core)
	fixture.core.global_position = start_position
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.nodes = Node2D.new()
	fixture.edges = Node2D.new()
	fixture.tips = Node2D.new()
	fixture.world.add_child(fixture.nodes)
	fixture.world.add_child(fixture.edges)
	fixture.world.add_child(fixture.tips)
	fixture.growth = Growth.new()
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = fixture.nodes
	fixture.growth.edge_container = fixture.edges
	fixture.growth.tip_container = fixture.tips
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_physics_process(false)
	fixture.network.register_node(fixture.core, true)
	fixture.growth.junction_formed.connect(func(node: HyphaNode) -> void:
		fixture.formed.append(node)
	)
	fixture.growth.task_completed.connect(func(task_id: int) -> void:
		fixture.completed.append(task_id)
		fixture.terminal_snapshots.append(fixture.growth.get_task_snapshot())
	)
	fixture.growth.task_cancelled.connect(func(task_id: int) -> void:
		fixture.cancelled.append(task_id)
		fixture.terminal_snapshots.append(fixture.growth.get_task_snapshot())
	)
	return fixture


func _append_mature_start(fixture: Fixture, position: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate()
	fixture.nodes.add_child(node)
	node.global_position = position
	fixture.network.register_node(node)
	var edge: HyphaEdge = EDGE_SCENE.instantiate()
	edge.start_node = fixture.core
	edge.end_node = node
	fixture.edges.add_child(edge)
	fixture.network.register_edge(edge)
	return node


func _assert_snapshot(snapshot: Dictionary, description: String) -> void:
	_check(snapshot.has_all(SNAPSHOT_KEYS), description + ": complete snapshot contract")
	if not snapshot.has_all(SNAPSHOT_KEYS):
		return
	_check(snapshot.size() == SNAPSHOT_KEYS.size(), description + ": exact snapshot keys")
	for key: String in ["task_id", "consumed_nutrition", "buffered_nutrition", "total_cost",
			"remaining_cost", "requested_nutrition", "formed_junctions"]:
		_check(typeof(snapshot[key]) == TYPE_INT, description + ": integer " + key)
	for key: String in ["progress", "distance", "total_distance"]:
		_check(typeof(snapshot[key]) == TYPE_FLOAT, description + ": float " + key)
	_check(typeof(snapshot["state"]) == TYPE_STRING_NAME
		and typeof(snapshot["wait_reason"]) == TYPE_STRING_NAME, description + ": named states")
	_check(snapshot["remaining_cost"] == snapshot["total_cost"] - snapshot["consumed_nutrition"],
		description + ": remaining includes all unconsumed cost")
	_check(snapshot["buffered_nutrition"] >= 0 and snapshot["buffered_nutrition"] <= snapshot["remaining_cost"],
		description + ": buffer cannot exceed remaining cost")
	_check(snapshot["progress"] >= 0.0 and snapshot["progress"] <= 1.0, description + ": bounded progress")
	_check(snapshot["target_position"] is Vector2 and snapshot["tip_position"] is Vector2,
		description + ": vector positions")


func _test_idle_validation_and_creation() -> void:
	var fixture: Fixture = _make_fixture()
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_assert_snapshot(snapshot, "Idle")
	_check(snapshot["task_id"] == 0 and snapshot["state"] == &"idle"
		and snapshot["wait_reason"] == &"", "Initial idle state")
	_check(not fixture.growth.has_active_task() and fixture.growth.get_delivery_target(0) == null,
		"Idle has no delivery endpoint")
	_check(not fixture.growth.pause_task() and not fixture.growth.resume_task()
		and not fixture.growth.cancel_task(), "Idle controls are inert")
	_check(fixture.growth.create_target(null, Vector2(120.0, 0.0)) == 0, "Null start rejected")
	_check(fixture.growth.create_target(fixture.core, Vector2.ZERO) == 0, "Zero-distance target rejected")
	_check(fixture.growth.create_target(fixture.core, Vector2(INF, 0.0)) == 0, "Infinite target rejected")
	_check(fixture.growth.create_target(fixture.core, Vector2(NAN, 0.0)) == 0, "NaN target rejected")
	var configured_planner: GrowthPlanner = fixture.growth.planner
	fixture.growth.planner = null
	_check(fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0)) == 0, "Missing planner rejected")
	fixture.growth.planner = configured_planner
	configured_planner.extension_unit_length = 0.0
	_check(fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0)) == 0, "Invalid plan rejected")
	configured_planner.extension_unit_length = 80.0
	_check(fixture.nodes.get_child_count() == 0 and fixture.edges.get_child_count() == 0
		and fixture.tips.get_child_count() == 0, "Rejected targets create no network objects")
	var isolated: HyphaNode = NODE_SCENE.instantiate()
	fixture.nodes.add_child(isolated)
	fixture.network.register_node(isolated)
	_check(fixture.growth.create_target(isolated, Vector2(120.0, 0.0)) == 0, "Disconnected mature start rejected")
	fixture.network.unregister_node(isolated)
	isolated.free()
	fixture.core.nutrition = 0
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0))
	_check(task_id > 0, "Connected core can create a task without A checking its balance")
	_check(fixture.growth.growth_speed == 30.0, "Default speed is 30 pixels per second")
	_check(fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0)) == 0, "Only one active target")
	var tip: Node2D = fixture.growth.get_delivery_target(task_id)
	_check(tip is GrowthTip and not tip is HyphaNode, "Delivery endpoint is a nonmature GrowthTip")
	_check(tip.global_position == fixture.core.global_position, "Initial tip coincides with mature start")
	_check(fixture.nodes.get_child_count() == 0 and fixture.tips.get_child_count() == 1
		and fixture.edges.get_child_count() == 1, "Creation adds only tip and temporary edge")
	var edge: HyphaEdge = fixture.edges.get_child(0)
	_check(edge.start_node == fixture.core and edge.end_node == tip and edge.get_length() == 0.0,
		"Initial registered strand has zero length")
	_check(fixture.network.is_connected_to_core(tip), "Initial tip is connected through zero edge")
	_check(fixture.core.nutrition == 0 and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 0,
		"Creation consumes no nutrition")
	_check(fixture.growth.get_requested_nutrition(task_id) == 2, "Initial request is only segment extension")
	fixture.dispose()


func _test_shortage_and_refill() -> void:
	var fixture: Fixture = _make_fixture()
	var initial_balance: int = fixture.core.nutrition
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	var tip: Node2D = fixture.growth.get_delivery_target(task_id)
	var old_route: NetworkRoute = fixture.network.find_route(fixture.core, tip)
	fixture.growth.advance(100.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 0.0, "No nutrition means no growth")
	_check(fixture.growth.receive_nutrition(task_id, 1, 1), "First partial extension delivery accepted")
	fixture.growth.advance(1.0)
	_check(fixture.growth.get_requested_nutrition(task_id) == 1
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 0, "Partial investment is buffered intact")
	_check(fixture.growth.receive_nutrition(task_id, 2, 1), "Extension investment becomes complete")
	_check(tip.global_position == Vector2.ZERO, "Receiving does not advance the tip")
	fixture.growth.advance(1.0)
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"extending" and snapshot["consumed_nutrition"] == 2,
		"Whole extension fee paid before movement")
	_check(tip.global_position == Vector2(30.0, 0.0) and snapshot["distance"] == 30.0,
		"One second moves exactly 30 pixels")
	_check(fixture.growth.get_requested_nutrition(task_id) == 0, "Moving segment requests no junction prepayment")
	fixture.growth.advance(3.0)
	snapshot = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"waiting" and snapshot["wait_reason"] == &"nutrition"
		and snapshot["distance"] == 120.0, "Unpaid endpoint waits at exact spacing")
	_check(fixture.nodes.get_child_count() == 0 and snapshot["consumed_nutrition"] == 2,
		"Endpoint arrival alone never matures a node")
	_check(fixture.growth.get_requested_nutrition(task_id) == 4, "Endpoint requests only its junction fee")
	_check(fixture.growth.receive_nutrition(task_id, 3, 3), "Partial junction delivery accepted")
	fixture.growth.advance(20.0)
	_check(fixture.nodes.get_child_count() == 0 and fixture.growth.get_requested_nutrition(task_id) == 1,
		"Insufficient junction buffer neither spends nor forms")
	_check(fixture.growth.receive_nutrition(task_id, 4, 1), "Junction buffer refilled")
	_check(fixture.nodes.get_child_count() == 0, "Junction receipt alone cannot form a node")
	fixture.growth.advance(0.5)
	snapshot = fixture.growth.get_task_snapshot()
	_check(snapshot["consumed_nutrition"] == 6 and snapshot["formed_junctions"] == 1,
		"Paid junction creates exactly one mature node")
	_check(fixture.formed.size() == 1 and fixture.formed[0].global_position == Vector2(120.0, 0.0),
		"First mature position matches planner")
	_check(fixture.growth.get_delivery_target(task_id) == tip and tip.global_position == Vector2(120.0, 0.0),
		"Promotion retains the same tip instance")
	_check(not fixture.network.is_route_valid(old_route), "Promotion invalidates old endpoint route snapshots")
	_check(fixture.edges.get_child_count() == 2
		and (fixture.edges.get_child(0) as HyphaEdge).end_node == fixture.formed[0]
		and (fixture.edges.get_child(1) as HyphaEdge).get_length() == 0.0,
		"Promotion preserves completed edge and adds a zero edge")
	_check(fixture.growth.get_requested_nutrition(task_id) == 1, "Next segment uses cumulative extension fee")
	_check(fixture.growth.receive_nutrition(task_id, 5, 1), "Second extension delivered")
	fixture.growth.advance(1.0)
	_check(tip.global_position == Vector2(150.0, 0.0), "Refill resumes physical growth")
	_check(fixture.growth.receive_nutrition(task_id, 6, 4), "Explicit full-plan injection can prebuffer final fee")
	fixture.growth.advance(3.0)
	snapshot = fixture.growth.get_task_snapshot()
	_assert_snapshot(snapshot, "Completed 240")
	_check(snapshot["state"] == &"completed" and snapshot["distance"] == 240.0
		and snapshot["progress"] == 1.0 and snapshot["consumed_nutrition"] == 11, "Final cost and progress are exact")
	_check(snapshot["remaining_cost"] == 0 and snapshot["buffered_nutrition"] == 0,
		"Completion accounts for all delivered nutrition")
	_check(fixture.nodes.get_child_count() == 2 and fixture.edges.get_child_count() == 2
		and fixture.tips.get_child_count() == 0, "Completion retains mature network and removes temporary tip")
	_check(fixture.completed == [task_id] and fixture.cancelled.is_empty(), "Exactly one completion signal")
	_check(fixture.terminal_snapshots[0]["state"] == &"completed", "Completion signal observes committed state")
	fixture.growth.advance(100.0)
	_check(not fixture.growth.cancel_task() and not fixture.growth.pause_task()
		and not fixture.growth.resume_task(), "Terminal controls have no effects")
	_check(not fixture.growth.receive_nutrition(task_id, 7, 1), "Terminal deliveries rejected")
	_check(fixture.completed.size() == 1 and fixture.nodes.get_child_count() == 2
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 11, "Repeated advance does not repeat work")
	_check(fixture.growth.get_delivery_target(task_id) == null and fixture.growth.get_requested_nutrition(task_id) == 0,
		"Terminal task has no delivery or demand")
	_check(fixture.core.nutrition == initial_balance, "A never debits or refunds MotherCore")
	fixture.dispose()


func _test_planner_boundaries() -> void:
	var distances: Array[float] = [79.99, 80.0, 80.01, 119.99, 120.0, 120.01, 239.99, 240.0, 240.01]
	var costs: Array[int] = [5, 5, 6, 6, 6, 10, 11, 11, 16]
	for index: int in range(distances.size()):
		var fixture: Fixture = _make_fixture()
		var target: Vector2 = Vector2(distances[index], 0.0)
		var plan: Dictionary = fixture.growth.planner.plan(Vector2.ZERO, target, false)
		var task_id: int = fixture.growth.create_target(fixture.core, target)
		var label: String = "Boundary %s" % distances[index]
		_check(task_id > 0 and fixture.growth.get_task_snapshot()["total_cost"] == costs[index], label + ": expected fee")
		_check(fixture.growth.receive_nutrition(task_id, 1, costs[index]), label + ": full explicit delivery")
		_check(fixture.growth.get_task_snapshot()["consumed_nutrition"] == 0, label + ": receipt does not spend")
		fixture.growth.advance(100.0)
		var snapshot: Dictionary = fixture.growth.get_task_snapshot()
		_check(snapshot["state"] == &"completed" and snapshot["tip_position"] == target, label + ": exact endpoint")
		_check(_near(snapshot["distance"], plan["distance"])
			and snapshot["consumed_nutrition"] == plan["total_cost"], label + ": planner totals authoritative")
		var positions: PackedVector2Array = plan["junction_positions"]
		var segments: Array[Dictionary] = plan["segments"]
		_check(fixture.formed.size() == positions.size() and fixture.nodes.get_child_count() == positions.size(),
			label + ": exact mature count")
		_check(fixture.edges.get_child_count() == segments.size() and fixture.tips.get_child_count() == 0,
			label + ": no residual zero edge")
		for junction_index: int in range(positions.size()):
			_check(fixture.formed[junction_index].global_position == positions[junction_index], label + ": planner position")
			var edge: HyphaEdge = fixture.edges.get_child(junction_index)
			_check(edge.start_node.global_position == segments[junction_index]["start_position"]
				and edge.end_node.global_position == segments[junction_index]["end_position"], label + ": planner edge endpoints")
		_check(fixture.network.find_route(fixture.core, fixture.formed[-1]).found, label + ": completed core connection")
		fixture.dispose()


func _test_positions_and_mature_start() -> void:
	var fixture: Fixture = _make_fixture(Vector2(-20.0, -30.0))
	fixture.nodes.position = Vector2(40.0, -5.0)
	fixture.edges.position = Vector2(-17.0, 8.0)
	fixture.tips.position = Vector2(29.0, 41.0)
	var start: HyphaNode = _append_mature_start(fixture, Vector2(10.0, -20.0))
	var target: Vector2 = Vector2(190.0, 220.0)
	var plan: Dictionary = fixture.growth.planner.plan(start.global_position, target, false)
	var task_id: int = fixture.growth.create_target(start, target)
	_check(task_id > 0, "Connected mature HyphaNode is a valid start")
	_check(fixture.growth.receive_nutrition(task_id, 1, plan["total_cost"]), "Diagonal nutrition injected")
	fixture.growth.advance(1.0)
	_check(fixture.growth.get_delivery_target(task_id).global_position.is_equal_approx(Vector2(28.0, 4.0)),
		"Diagonal tip moves 30 world pixels regardless of container transforms")
	fixture.growth.advance(20.0)
	var expected: PackedVector2Array = PackedVector2Array([Vector2(82.0, 76.0), Vector2(154.0, 172.0), target])
	_check(fixture.formed.size() == expected.size(), "Diagonal planner creates three mature junctions")
	for index: int in range(fixture.formed.size()):
		_check(fixture.formed[index].global_position == expected[index], "Diagonal exact global junction position")
	_check(fixture.growth.get_task_snapshot()["consumed_nutrition"] == 16,
		"Diagonal cumulative fee matches four extension units plus three junctions")
	_check(fixture.network.find_route(fixture.core, fixture.formed[-1]).segments.size() == 4,
		"Original mature connection and new growth edges remain registered")
	fixture.dispose()


func _test_pause_and_resume() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	var tip: Node2D = fixture.growth.get_delivery_target(task_id)
	_check(fixture.growth.receive_nutrition(task_id, 1, 2), "Pause fixture extension delivery")
	_check(fixture.growth.pause_task() and not fixture.growth.pause_task(), "Pause is idempotent")
	_check(fixture.growth.get_requested_nutrition(task_id) == 0
		and fixture.growth.get_task_snapshot()["wait_reason"] == &"paused", "Pause suppresses demand")
	fixture.growth.advance(10.0)
	_check(tip.global_position == Vector2.ZERO and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 0,
		"Pause before movement spends nothing")
	_check(fixture.growth.receive_nutrition(task_id, 2, 4), "In-flight nutrition may arrive while paused")
	_check(fixture.growth.get_delivery_target(task_id) == tip, "Paused task retains delivery endpoint")
	_check(fixture.growth.resume_task() and not fixture.growth.resume_task(), "Resume is idempotent")
	fixture.growth.advance(1.0)
	_check(tip.global_position == Vector2(30.0, 0.0), "Resume advances paid segment")
	fixture.growth.pause_task()
	fixture.growth.advance(100.0)
	_check(tip.global_position == Vector2(30.0, 0.0), "Pause during movement freezes physical position")
	_check(fixture.growth.receive_nutrition(task_id, 3, 1), "Second extension can be buffered during pause")
	fixture.growth.resume_task()
	fixture.growth.advance(3.0)
	_check(fixture.growth.get_task_snapshot()["consumed_nutrition"] == 6
		and tip.global_position == Vector2(120.0, 0.0), "Exact endpoint frame does not preconsume next extension")
	fixture.growth.pause_task()
	_check(fixture.growth.receive_nutrition(task_id, 4, 4), "Paused endpoint accepts final in-flight buffer")
	fixture.growth.resume_task()
	fixture.growth.advance(4.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed"
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 11, "Pause/resume preserves exact total cost")
	fixture.dispose()


func _test_disconnection_recovery() -> void:
	var fixture: Fixture = _make_fixture()
	var start: HyphaNode = _append_mature_start(fixture, Vector2(20.0, 0.0))
	var trunk: HyphaEdge = fixture.edges.get_child(0)
	var task_id: int = fixture.growth.create_target(start, Vector2(260.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 11)
	fixture.growth.advance(1.0)
	fixture.network.unregister_edge(trunk)
	fixture.growth.advance(100.0)
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"waiting" and snapshot["wait_reason"] == &"disconnected",
		"Disconnected paid tip waits automatically")
	_check(snapshot["distance"] == 30.0 and snapshot["consumed_nutrition"] == 2
		and snapshot["buffered_nutrition"] == 9, "Disconnection freezes position and spending despite buffer")
	_check(fixture.growth.get_requested_nutrition(task_id) == 0, "Disconnected tip requests no new supply")
	fixture.network.register_edge(trunk)
	fixture.growth.advance(1.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 60.0
		and fixture.growth.get_task_snapshot()["state"] == &"extending", "Connectivity restoration resumes automatically")
	fixture.growth.advance(20.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed", "Recovered path finishes normally")
	fixture.dispose()

	fixture = _make_fixture()
	start = _append_mature_start(fixture, Vector2(20.0, 0.0))
	trunk = fixture.edges.get_child(0)
	task_id = fixture.growth.create_target(start, Vector2(260.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 2)
	fixture.growth.advance(4.0)
	fixture.network.unregister_edge(trunk)
	_check(fixture.growth.receive_nutrition(task_id, 2, 4), "Disconnected nonterminal task may buffer arrived nutrition")
	fixture.growth.advance(10.0)
	_check(fixture.formed.is_empty() and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 2,
		"Disconnected endpoint cannot spend a buffered junction fee")
	fixture.network.register_edge(trunk)
	fixture.growth.advance(1.0)
	_check(fixture.formed.size() == 1 and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 6,
		"Restored endpoint can pay and mature")
	fixture.dispose()


func _test_speed_and_invalid_delta() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 6)
	var invalid_speeds: Array[float] = [0.0, -30.0, NAN, INF]
	for speed: float in invalid_speeds:
		fixture.growth.growth_speed = speed
		fixture.growth.advance(10.0)
		var snapshot: Dictionary = fixture.growth.get_task_snapshot()
		_check(snapshot["distance"] == 0.0 and snapshot["consumed_nutrition"] == 0
			and snapshot["buffered_nutrition"] == 6, "Invalid speed cannot preconsume an extension")
		_check(snapshot["wait_reason"] == &"invalid_configuration" and snapshot["requested_nutrition"] == 0,
			"Invalid speed reports configuration wait")
	fixture.growth.growth_speed = 30.0
	for delta: float in [0.0, -1.0, NAN, INF]:
		fixture.growth.advance(delta)
		_check(fixture.growth.get_task_snapshot()["distance"] == 0.0
			and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 0, "Invalid time step is inert")
	fixture.growth.advance(4.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed", "Valid speed and delta restore growth")
	fixture.dispose()


func _test_cancelled_buffers_and_ids() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 11)
	_check(fixture.growth.take_unspent_nutrition(task_id) == 0, "Active buffer cannot be refunded")
	_check(fixture.growth.cancel_task() and not fixture.growth.cancel_task(), "Cancellation is idempotent")
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_assert_snapshot(snapshot, "Cancelled before growth")
	_check(snapshot["state"] == &"cancelled" and snapshot["consumed_nutrition"] == 0
		and snapshot["buffered_nutrition"] == 11, "Cancellation retains unspent buffer for C")
	_check(fixture.nodes.get_child_count() == 0 and fixture.edges.get_child_count() == 0
		and fixture.tips.get_child_count() == 0, "Zero-length cancellation discards all temporary geometry")
	_check(fixture.cancelled == [task_id] and fixture.terminal_snapshots[0]["state"] == &"cancelled",
		"One cancellation signal observes committed terminal state")
	_check(fixture.growth.create_target(fixture.core, Vector2(80.0, 0.0)) == 0,
		"Undrained cancelled buffer prevents task replacement")
	_check(fixture.growth.take_unspent_nutrition(task_id + 1) == 0, "Stale refund request rejected")
	_check(fixture.growth.take_unspent_nutrition(task_id) == 11
		and fixture.growth.take_unspent_nutrition(task_id) == 0, "Terminal buffer drained exactly once")
	var next_id: int = fixture.growth.create_target(fixture.core, Vector2(80.0, 0.0))
	_check(next_id > task_id, "Successful task ids increase monotonically")
	_check(not fixture.growth.receive_nutrition(task_id, 2, 1), "Previous task delivery cannot enter replacement")
	_check(fixture.growth.receive_nutrition(next_id, 1, 5), "Replacement has its own shipment deduplication")
	fixture.growth.cancel_task()
	_check(fixture.growth.take_unspent_nutrition(next_id) == 5, "Replacement buffer is independent")
	_check(fixture.core.nutrition == fixture.core.initial_nutrition, "Terminal refund API never credits core itself")
	fixture.dispose()


func _test_cancelled_geometry() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 11)
	fixture.growth.advance(1.0)
	fixture.growth.cancel_task()
	_check(fixture.nodes.get_child_count() == 0 and fixture.edges.get_child_count() == 1
		and fixture.tips.get_child_count() == 1, "Partial cancellation retains a strand and inert stump only")
	var edge: HyphaEdge = fixture.edges.get_child(0)
	var stump: Node2D = edge.end_node
	_check(not stump is GrowthTip and not stump is HyphaNode and stump.get_script() == null,
		"Cancelled partial endpoint is generic Node2D")
	_check(stump.global_position == Vector2(30.0, 0.0) and edge.get_length() == 30.0,
		"Partial strand freezes at its actual grown length")
	_check(fixture.network.find_route(fixture.core, stump).found, "Retained partial strand stays registered")
	_check(fixture.growth.take_unspent_nutrition(task_id) == 9, "Partial cancellation refunds only unspent buffer")
	_check(fixture.growth.create_target(stump, Vector2(100.0, 0.0)) == 0,
		"Connected stump can never serve as a mature growth start")
	fixture.growth.advance(100.0)
	_check(stump.global_position == Vector2(30.0, 0.0) and fixture.nodes.get_child_count() == 0,
		"Cancelled stump never moves or matures")
	fixture.dispose()

	fixture = _make_fixture()
	task_id = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 2)
	fixture.growth.advance(4.0)
	fixture.growth.cancel_task()
	edge = fixture.edges.get_child(0)
	_check(edge.get_length() == 120.0 and not edge.end_node is HyphaNode,
		"Cancelling at an unpaid endpoint retains strand without minting a mature node")
	_check(fixture.nodes.get_child_count() == 0 and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 2,
		"Unpaid endpoint cancellation spends no junction fee")
	fixture.dispose()

	fixture = _make_fixture()
	task_id = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 6)
	fixture.growth.advance(4.0)
	fixture.growth.cancel_task()
	_check(fixture.nodes.get_child_count() == 1 and fixture.edges.get_child_count() == 1
		and fixture.tips.get_child_count() == 0, "Cancellation after a paid junction discards redundant zero edge")
	_check(fixture.network.find_route(fixture.core, fixture.formed[0]).found,
		"Paid mature network survives cancellation")
	_check(fixture.growth.create_target(fixture.formed[0], Vector2(240.0, 0.0)) > task_id,
		"Preserved mature junction remains a valid new start")
	fixture.dispose()

	fixture = _make_fixture()
	task_id = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 7)
	fixture.growth.advance(5.0)
	fixture.growth.cancel_task()
	_check(fixture.nodes.get_child_count() == 1 and fixture.edges.get_child_count() == 2,
		"Cancellation during second segment preserves mature and partial strands")
	edge = fixture.edges.get_child(1)
	_check(edge.start_node == fixture.formed[0] and edge.get_length() == 30.0
		and edge.end_node.global_position == Vector2(150.0, 0.0), "Second partial strand freezes beyond the paid junction")
	_check(fixture.network.find_route(fixture.core, edge.end_node).segments.size() == 2,
		"Retained second partial strand remains attached to mature network")
	fixture.dispose()


func _test_shipments_and_supply_reasons() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	var reasons: Array[StringName] = [&"in_transit", &"core_empty", &"combat_reserve", &"core_unavailable", &"nutrition"]
	for reason: StringName in reasons:
		fixture.growth.set_supply_wait_reason(task_id, reason)
		_check(fixture.growth.get_task_snapshot()["wait_reason"] == reason,
			"Supply shortage reason is exposed without changing demand")
	fixture.growth.set_supply_wait_reason(task_id + 1, &"in_transit")
	fixture.growth.set_supply_wait_reason(task_id, &"unknown")
	_check(fixture.growth.get_task_snapshot()["wait_reason"] == &"nutrition", "Stale or unknown supply reason ignored")
	fixture.growth.set_supply_wait_reason(task_id, &"")
	_check(fixture.growth.get_task_snapshot()["wait_reason"] == &"nutrition", "Empty supply reason uses nutrition fallback")
	_check(not fixture.growth.receive_nutrition(task_id + 1, 1, 1), "Wrong task shipment rejected")
	_check(not fixture.growth.receive_nutrition(task_id, 0, 1)
		and not fixture.growth.receive_nutrition(task_id, -1, 1), "Nonpositive shipment ids rejected")
	_check(not fixture.growth.receive_nutrition(task_id, 1, 0)
		and not fixture.growth.receive_nutrition(task_id, 1, -1), "Nonpositive shipment amount rejected")
	_check(not fixture.growth.receive_nutrition(task_id, 1, 12), "Plan overflow rejected")
	_check(fixture.growth.receive_nutrition(task_id, 1, 1), "Rejected shipment id is not prematurely claimed")
	_check(not fixture.growth.receive_nutrition(task_id, 1, 2), "Duplicate shipment id rejected")
	_check(fixture.growth.receive_nutrition(task_id, 2, 10), "Available remaining buffer accepted")
	_check(not fixture.growth.receive_nutrition(task_id, 3, 1), "Buffered plus consumed cost cannot overflow total")
	fixture.growth.advance(1.0)
	fixture.growth.set_supply_wait_reason(task_id, &"core_empty")
	_check(fixture.growth.get_task_snapshot()["wait_reason"] == &""
		and fixture.growth.get_requested_nutrition(task_id) == 0, "Moving phase ignores supply shortage labels")
	fixture.growth.cancel_task()
	fixture.growth.set_supply_wait_reason(task_id, &"in_transit")
	_check(fixture.growth.get_task_snapshot()["wait_reason"] == &"", "Terminal reason cannot be overwritten by supply")
	fixture.dispose()


func _test_zero_extension_investment() -> void:
	var fixture: Fixture = _make_fixture()
	fixture.growth.planner.extension_unit_length = 100.0
	fixture.growth.planner.junction_spacing = 50.0
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(150.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 1)
	fixture.growth.advance(2.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 50.0, "Configured first endpoint reached")
	fixture.growth.receive_nutrition(task_id, 2, 4)
	fixture.growth.advance(1.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 80.0
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 5,
		"Zero-cost second extension uses globally paid units")
	fixture.growth.advance(2.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 100.0
		and fixture.growth.get_requested_nutrition(task_id) == 4, "Zero-cost extension still needs endpoint fee")
	fixture.growth.receive_nutrition(task_id, 3, 4)
	fixture.growth.advance(1.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 100.0
		and fixture.growth.get_requested_nutrition(task_id) == 1, "Next global unit is requested before third extension")
	fixture.growth.receive_nutrition(task_id, 4, 1)
	fixture.growth.advance(2.0)
	fixture.growth.receive_nutrition(task_id, 5, 4)
	fixture.growth.advance(0.1)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed"
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 14, "Configured cumulative cost remains exact")
	fixture.dispose()

	fixture = _make_fixture()
	fixture.growth.planner.extension_unit_length = 100.0
	fixture.growth.planner.junction_spacing = 50.0
	fixture.growth.planner.junction_cost = 0
	task_id = fixture.growth.create_target(fixture.core, Vector2(150.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 2)
	fixture.growth.advance(10.0)
	_check(fixture.formed.size() == 3 and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 2,
		"Planner-authorized zero junction fees still form exact positions")
	fixture.dispose()


func _test_freed_references() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 11)
	fixture.growth.advance(1.0)
	fixture.nodes.free()
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["wait_reason"] == &"invalid_configuration" and snapshot["requested_nutrition"] == 0,
		"Freed exported container is handled before typed conversion")
	fixture.growth.advance(10.0)
	_check(fixture.growth.get_task_snapshot()["distance"] == 30.0
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 2, "Freed configuration freezes work")
	_check(fixture.growth.cancel_task() and fixture.growth.take_unspent_nutrition(task_id) == 9,
		"Freed mature container does not block cancellation or buffer recovery")
	fixture.dispose()

	fixture = _make_fixture()
	task_id = fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 6)
	fixture.growth.advance(1.0)
	fixture.core.free()
	snapshot = fixture.growth.get_task_snapshot()
	_check(snapshot["start_node"] == null and snapshot["requested_nutrition"] == 0,
		"Freed retained start produces a safe null snapshot reference")
	_check(fixture.growth.cancel_task() and fixture.growth.take_unspent_nutrition(task_id) == 4,
		"Freed start permits safe cancellation and terminal drain")
	fixture.dispose()

	fixture = _make_fixture()
	task_id = fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 6)
	fixture.growth.get_delivery_target(task_id).free()
	_check(fixture.growth.get_delivery_target(task_id) == null
		and fixture.growth.get_task_snapshot()["requested_nutrition"] == 0, "Freed delivery tip is handled safely")
	_check(fixture.growth.cancel_task() and fixture.growth.take_unspent_nutrition(task_id) == 6,
		"Freed temporary endpoint does not leave refundable buffer locked")
	fixture.dispose()


func _test_synchronous_callbacks() -> void:
	var fixture: Fixture = _make_fixture()
	var delivery: Dictionary = {"shipment": 0, "amount": 0, "requests": [], "accepted": true}
	fixture.growth.task_changed.connect(func(snapshot: Dictionary) -> void:
		var requested: int = snapshot["requested_nutrition"]
		if requested > 0:
			delivery["shipment"] += 1
			delivery["amount"] += requested
			delivery["requests"].append(requested)
			delivery["accepted"] = fixture.growth.receive_nutrition(
				snapshot["task_id"], delivery["shipment"], requested
			) and delivery["accepted"]
	)
	var task_id: int = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.advance(100.0)
	_check(delivery["accepted"] and delivery["amount"] == 11
		and delivery["requests"] == [2, 4, 1, 4], "Synchronous refill observes only successive investments")
	_check(fixture.completed == [task_id] and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 11,
		"Synchronous receipts never recursively advance or duplicate completion")
	fixture.dispose()

	fixture = _make_fixture()
	var replacement: Dictionary = {"state": &"", "refund": -1, "task_id": 0}
	fixture.growth.task_completed.connect(func(completed_id: int) -> void:
		replacement["state"] = fixture.growth.get_task_snapshot()["state"]
		replacement["refund"] = fixture.growth.take_unspent_nutrition(completed_id)
		replacement["task_id"] = fixture.growth.create_target(fixture.core, Vector2(80.0, 0.0))
	)
	task_id = fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 6)
	fixture.growth.advance(100.0)
	_check(replacement["state"] == &"completed" and replacement["refund"] == 0
		and replacement["task_id"] > task_id, "Completion callback sees terminal state and may replace drained task")
	_check(fixture.growth.get_task_snapshot()["distance"] == 0.0
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 0,
		"Remaining time from previous task never advances synchronous replacement")
	fixture.dispose()

	fixture = _make_fixture()
	var refund: Dictionary = {"amount": 0, "seen_buffer": -1, "duplicate": -1}
	fixture.growth.task_cancelled.connect(func(cancelled_id: int) -> void:
		refund["amount"] = fixture.growth.take_unspent_nutrition(cancelled_id)
		refund["seen_buffer"] = fixture.growth.get_task_snapshot()["buffered_nutrition"]
		refund["duplicate"] = fixture.growth.take_unspent_nutrition(cancelled_id)
	)
	fixture.growth.task_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == &"extending":
			fixture.growth.cancel_task()
	)
	task_id = fixture.growth.create_target(fixture.core, Vector2(240.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 11)
	fixture.growth.advance(100.0)
	_check(refund["amount"] == 9 and refund["seen_buffer"] == 0 and refund["duplicate"] == 0,
		"Cancellation callback drains buffer before any nested snapshot")
	_check(fixture.growth.get_task_snapshot()["state"] == &"cancelled"
		and fixture.growth.get_task_snapshot()["distance"] == 0.0 and fixture.formed.is_empty(),
		"Synchronous cancellation stops advance before moving or maturing")
	_check(fixture.cancelled == [task_id], "Synchronous cancellation signal emitted once")
	fixture.dispose()

	fixture = _make_fixture()
	fixture.growth.task_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == &"waiting" and snapshot["distance"] == 120.0:
			fixture.growth.pause_task()
	)
	task_id = fixture.growth.create_target(fixture.core, Vector2(120.0, 0.0))
	fixture.growth.receive_nutrition(task_id, 1, 6)
	fixture.growth.advance(100.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"paused" and fixture.formed.is_empty()
		and fixture.growth.get_task_snapshot()["consumed_nutrition"] == 2,
		"Endpoint callback may pause before junction investment even with buffer")
	fixture.dispose()
