extends SceneTree
## 地形路线、真实付费菌结、既有终点与尖端取消；由根代理串行运行。

const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const START: Vector2 = Vector2(60.0, 200.0)
const TARGET: Vector2 = Vector2(540.0, 200.0)
const EPSILON: float = 0.001

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var terrain: TerrainNavigation
	var network: NetworkSystem
	var planner: GrowthPlanner
	var growth: GrowthSystem
	var nodes: Node2D
	var edges: Node2D
	var tips: Node2D
	var formed: PackedVector2Array = PackedVector2Array()

	func dispose() -> void:
		world.free()


var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_routing_and_cost()
	_test_blocked_and_unreachable()
	_test_paid_growth()
	_test_existing_endpoint()
	_test_tip_abort()
	print("TERRAIN_GROWTH_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _make_fixture() -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.terrain = TerrainNavigation.new()
	fixture.terrain.bounds = Rect2(0.0, 0.0, 600.0, 400.0)
	fixture.terrain.obstacles = [Rect2(250.0, 110.0, 100.0, 180.0)]
	fixture.world.add_child(fixture.terrain)
	fixture.core = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	fixture.core.add_child(health_bar)
	fixture.world.add_child(fixture.core)
	fixture.core.global_position = START
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.network.register_node(fixture.core, true)
	fixture.nodes = Node2D.new()
	fixture.edges = Node2D.new()
	fixture.tips = Node2D.new()
	fixture.world.add_child(fixture.nodes)
	fixture.world.add_child(fixture.edges)
	fixture.world.add_child(fixture.tips)
	fixture.planner = GrowthPlanner.new()
	fixture.planner.terrain_navigation = fixture.terrain
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
	return fixture


func _path_length(start: Vector2, end: Vector2) -> float:
	var dx: float = float(end.x) - float(start.x)
	var dy: float = float(end.y) - float(start.y)
	var scale: float = maxf(absf(dx), absf(dy))
	return scale * sqrt((dx / scale) * (dx / scale) + (dy / scale) * (dy / scale)) if scale > 0.0 else 0.0


func _assert_plan(fixture: Fixture, plan: Dictionary, endpoint_exists: bool = false) -> void:
	_check(bool(plan["valid"]), "Routed plan is valid")
	if not bool(plan["valid"]):
		return
	var segments: Array[Dictionary] = plan["segments"]
	var junctions: PackedVector2Array = plan["junction_positions"]
	var length: float = 0.0
	var fees: int = 0
	var seen: Dictionary = {}
	var previous: Vector2 = plan["start_position"]
	for index: int in range(segments.size()):
		var segment: Dictionary = segments[index]
		var end: Vector2 = segment["end_position"]
		_check(segment["start_position"] == previous, "Segments form one connected route")
		_check(fixture.terrain.is_segment_clear(previous, end, 10.0), "Every planned edge clears the rock")
		_check(float(segment["length"]) > 0.0, "No zero length segment")
		_check(not seen.has(end), "Corners and spacing points are distinct")
		seen[end] = true
		length += _path_length(previous, end)
		fees += int(segment["total_cost"])
		var existing_end: bool = endpoint_exists and index == segments.size() - 1
		_check(int(segment["junction_cost"]) == (0 if existing_end else 4), "Each new junction costs 4")
		previous = end
	_check(previous == plan["end_position"], "Route reaches the exact target")
	_check(absf(length - float(plan["distance"])) < EPSILON, "Cost uses actual routed length")
	_check(int(plan["extension_cost"]) == int(ceil(length / 80.0)), "Extension is rounded once for the whole route")
	_check(int(plan["junction_cost"]) == junctions.size() * 4, "Only distinct new junctions are charged")
	_check(fees == int(plan["total_cost"]), "Segment fees equal the preview total")


func _assert_invalid(plan: Dictionary, label: String) -> void:
	_check(not bool(plan["valid"]) and not String(plan["error"]).is_empty(), label + " is rejected with an error")
	_check(int(plan["total_cost"]) == 0 and int(plan["extension_cost"]) == 0 \
		and int(plan["junction_cost"]) == 0, label + " has zero fees")
	var segments: Array[Dictionary] = plan["segments"]
	_check(segments.is_empty(), label + " cannot be built")


func _test_routing_and_cost() -> void:
	var fixture: Fixture = _make_fixture()
	var path: PackedVector2Array = fixture.terrain.find_path(START, TARGET)
	_check(not fixture.terrain.is_segment_clear(START, TARGET), "Direct line intersects the rock")
	_check(path.size() >= 4 and path[0] == START and path[-1] == TARGET, "Navigation includes exact endpoints and real corners")
	var plan: Dictionary = fixture.planner.plan(START, TARGET)
	_assert_plan(fixture, plan)
	_check(plan == fixture.planner.plan(START, TARGET), "Preview and build planning are deterministic")
	_check(float(plan["distance"]) > START.distance_to(TARGET), "Routing charges the longer detour")
	var junctions: PackedVector2Array = plan["junction_positions"]
	for index: int in range(1, path.size() - 1):
		_check(junctions.has(path[index]), "Every corner is a paid junction")
	if path.size() >= 4:
		fixture.planner.junction_spacing = _path_length(START, path[1])
		var coincident: Dictionary = fixture.planner.plan(START, TARGET)
		_assert_plan(fixture, coincident)
		var coincident_points: PackedVector2Array = coincident["junction_positions"]
		var matches: int = 0
		for point: Vector2 in coincident_points:
			if point == path[1]:
				matches += 1
		_check(matches == 1, "A corner coinciding with spacing is charged once")
	fixture.planner.junction_spacing = 120.0
	var existing: Dictionary = fixture.planner.plan(START, TARGET, true)
	_assert_plan(fixture, existing, true)
	_check(int(existing["total_cost"]) == int(plan["total_cost"]) - 4, "An existing endpoint saves exactly 4")
	fixture.planner.terrain_navigation = null
	var straight: Dictionary = fixture.planner.plan(START, TARGET)
	_check(straight["distance"] == 480.0 and straight["extension_cost"] == 6 \
		and straight["junction_cost"] == 16, "No terrain preserves the existing straight planner")
	var rock: TerrainRock = fixture.terrain.get_child(0) as TerrainRock
	var collision: CollisionShape2D = rock.get_node("CollisionShape2D") as CollisionShape2D
	var shape: RectangleShape2D = collision.shape as RectangleShape2D
	_check(rock.global_position == fixture.terrain.obstacles[0].get_center() \
		and shape.size == fixture.terrain.obstacles[0].size, "Rock collision exactly matches the rendered footprint")
	fixture.dispose()


func _test_blocked_and_unreachable() -> void:
	var fixture: Fixture = _make_fixture()
	var blocked: Vector2 = Vector2(300.0, 200.0)
	_assert_invalid(fixture.planner.plan(START, blocked), "Inside-rock target")
	_assert_invalid(fixture.planner.plan(blocked, TARGET), "Inside-rock start")
	_check(fixture.growth.create_target(fixture.core, blocked) == 0, "Blocked growth creates no task")
	fixture.terrain.obstacles = [Rect2(280.0, 0.0, 40.0, 400.0)]
	_check(fixture.terrain.find_path(START, TARGET).is_empty(), "A wall across bounds is unreachable")
	_assert_invalid(fixture.planner.plan(START, TARGET), "Unreachable route")
	_check(fixture.growth.create_target(fixture.core, TARGET) == 0, "Unreachable growth creates no task")
	fixture.terrain.bounds = Rect2(0.0, 0.0, 10.0, 10.0)
	_assert_invalid(fixture.planner.plan(START, TARGET), "Impossible bounds")
	_check(fixture.growth.create_target(fixture.core, TARGET) == 0, "Impossible bounds create no task")
	_check(fixture.nodes.get_child_count() == 0 and fixture.edges.get_child_count() == 0 \
		and fixture.tips.get_child_count() == 0, "Rejected plans create no geometry")
	var snapshot: Dictionary = fixture.growth.get_resource_snapshot()
	_check(snapshot["task_id"] == 0 and snapshot["consumed_nutrition"] == 0 \
		and snapshot["buffered_nutrition"] == 0, "Rejected plans begin no payment")
	fixture.dispose()


func _test_paid_growth() -> void:
	var fixture: Fixture = _make_fixture()
	var plan: Dictionary = fixture.planner.plan(START, TARGET)
	var task_id: int = fixture.growth.create_target(fixture.core, TARGET)
	_check(task_id > 0, "A routed growth task starts")
	fixture.growth.advance(100.0)
	_check(fixture.formed.is_empty() and fixture.growth.get_task_snapshot()["distance"] == 0.0, "Growth waits for actual delivered nutrition")
	_check(fixture.growth.receive_nutrition(task_id, 1, int(plan["total_cost"])), "Routed task accepts the preview cost")
	fixture.growth.advance(float(plan["distance"]) / fixture.growth.growth_speed + 1.0)
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	_check(snapshot["state"] == &"completed" and snapshot["consumed_nutrition"] == plan["total_cost"], "All actual route costs are consumed")
	_check(fixture.formed == plan["junction_positions"], "Built junctions exactly match all planned points")
	var segments: Array[Dictionary] = plan["segments"]
	_check(fixture.edges.get_child_count() == segments.size(), "Every planned segment is a real edge")
	for index: int in range(mini(fixture.edges.get_child_count(), segments.size())):
		var edge: HyphaEdge = fixture.edges.get_child(index) as HyphaEdge
		_check(edge.start_node.global_position == segments[index]["start_position"] \
			and edge.end_node.global_position == segments[index]["end_position"], "Built edge follows its exact segment")
		_check(fixture.terrain.is_segment_clear(edge.start_node.global_position, edge.end_node.global_position, 10.0), "No built edge crosses rock")
	var endpoint: HyphaNode = fixture.growth.get_completed_endpoint(task_id)
	var route: NetworkRoute = fixture.network.find_route(fixture.core, endpoint)
	_check(route.found and route.segments.size() == segments.size(), "Transport uses the complete detour")
	fixture.dispose()


func _add_node(fixture: Fixture, point: Vector2, connected: bool) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate()
	fixture.nodes.add_child(node)
	node.global_position = point
	fixture.network.register_node(node)
	if connected:
		var edge: HyphaEdge = EDGE_SCENE.instantiate()
		edge.start_node = fixture.core
		edge.end_node = node
		fixture.edges.add_child(edge)
		fixture.network.register_edge(edge)
	return node


func _test_existing_endpoint() -> void:
	var fixture: Fixture = _make_fixture()
	var source: HyphaNode = _add_node(fixture, Vector2(80.0, 200.0), true)
	var target: HyphaNode = _add_node(fixture, TARGET, false)
	var plan: Dictionary = fixture.planner.plan(source.global_position, target.global_position, true)
	var task_id: int = fixture.growth.create_connection(source, target)
	_check(task_id > 0, "A routed connection starts with the shared planner")
	_check(fixture.growth.receive_nutrition(task_id, 1, int(plan["total_cost"])), "Connection accepts its existing-endpoint price")
	fixture.growth.advance(float(plan["distance"]) / fixture.growth.growth_speed + 1.0)
	_check(fixture.growth.get_task_snapshot()["state"] == &"completed" \
		and fixture.growth.get_completed_endpoint(task_id) == target, "Connection preserves the selected endpoint identity")
	_check(fixture.formed == plan["junction_positions"], "Connection builds only new corner and spacing junctions")
	_check(fixture.nodes.get_child_count() == fixture.formed.size() + 2, "Existing endpoint is never duplicated")
	for edge: HyphaEdge in fixture.network.get_registered_edges():
		_check(fixture.terrain.is_segment_clear(edge.start_node.global_position, edge.end_node.global_position, 10.0), "Connection transport has no cross-rock edge")
	fixture.dispose()


func _test_tip_abort() -> void:
	var fixture: Fixture = _make_fixture()
	var plan: Dictionary = fixture.planner.plan(START, TARGET)
	var task_id: int = fixture.growth.create_target(fixture.core, TARGET)
	fixture.growth.receive_nutrition(task_id, 1, int(plan["total_cost"]))
	var segments: Array[Dictionary] = plan["segments"]
	fixture.growth.advance((float(segments[0]["length"]) + float(segments[1]["length"]) * 0.5) \
		/ fixture.growth.growth_speed)
	var before: Dictionary = fixture.growth.get_task_snapshot()
	var tip: GrowthTip = fixture.growth.get_delivery_target(task_id) as GrowthTip
	tip.take_damage(10000.0)
	_check(fixture.growth.abort_destroyed_tip(tip), "Root can abort the destroyed current tip")
	var after: Dictionary = fixture.growth.get_task_snapshot()
	_check(after["state"] == &"cancelled" and after["consumed_nutrition"] == before["consumed_nutrition"], "Abort preserves already consumed payment")
	_check(fixture.nodes.get_child_count() == fixture.formed.size() and fixture.formed.size() > 0, "Paid junctions survive tip destruction")
	var partial_edge: HyphaEdge = fixture.edges.get_child(1) as HyphaEdge if fixture.edges.get_child_count() == 2 else null
	_check(is_instance_valid(partial_edge) and is_instance_valid(partial_edge.end_node) \
		and not partial_edge.end_node is GrowthTip and not partial_edge.end_node is HyphaNode \
		and fixture.network.is_node_registered(partial_edge.end_node) \
		and not fixture.network.is_node_registered(tip), "Paid partial edge ends at an inert stump")
	_check(fixture.growth.take_unspent_nutrition(task_id) == before["buffered_nutrition"], "Abort retains the normal unspent refund")
	_check(not fixture.growth.abort_destroyed_tip(null), "An absent tip cannot cancel another task")
	fixture.dispose()
