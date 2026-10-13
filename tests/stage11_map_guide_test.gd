extends SceneTree
## 固定地图几何与首次事件组件；生长夹具直接送达已扣款材料，不代表运输或六波试玩。
## 地图只离线实例化，旧演示的资源快照与动态指引由正式 FirstLevel 脚本覆盖。

const MAP_SCENE: PackedScene = preload("res://scenes/levels/first_level_map.tscn")
const BASE_SCRIPT: GDScript = preload("res://scripts/colony_operations_demo.gd")
const GUIDE_SCRIPT: GDScript = preload("res://scripts/first_event_guide.gd")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const EVENT_IDS: Array[StringName] = [
	&"target_placed", &"remains_returned", &"nutrition_returned",
	&"stage_unlocked", &"differentiated", &"network_broken",
]
const EXPECTED_BOUNDS: Rect2 = Rect2(16, 258, 1168, 362)
const FIRST_TARGET: Vector2 = Vector2(330, 395)
const SECOND_TARGET: Vector2 = Vector2(925, 390)

class BuildFixture:
	extends RefCounted

	var world: Node2D
	var terrain: TerrainNavigation
	var core: MotherCore
	var network: NetworkSystem
	var planner: GrowthPlanner
	var growth: GrowthSystem
	var connection: ConnectionSystem
	var nodes: Node2D
	var edges: Node2D
	var tips: Node2D
	var left: HyphaNode
	var right: HyphaNode
	var rear: HyphaNode
	var left_core_edge: HyphaEdge
	var left_rear_edge: HyphaEdge
	var spent: int = 0

	func dispose() -> void:
		world.free()

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_map_geometry_and_initial_state()
	_test_paid_expansions_and_bypass()
	_test_first_events_and_snapshot_isolation()
	_test_disable_reset_and_paused_buttons()
	_check(root.get_child_count() == 0, "Map and guide fixtures leave no scene nodes")
	print("STAGE11_MAP_GUIDE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
		"fixture_scope": "offline_map; production_growth_with_direct_paid_delivery; independent_guide",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _test_map_geometry_and_initial_state() -> void:
	var map: Node2D = MAP_SCENE.instantiate() as Node2D
	_check(map.get_script() == BASE_SCRIPT, "Map inherits the operations script without a custom root script")
	var terrain: TerrainNavigation = map.get_node("World/TerrainNavigation") as TerrainNavigation
	var core: MotherCore = map.get_node("World/Colony/MotherCore") as MotherCore
	var left: HyphaNode = map.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode
	var right: HyphaNode = map.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var rear: HyphaNode = map.get_node("World/Colony/Nodes/RearNode") as HyphaNode
	var first: LargeCarcass = map.get_node("World/Remains/FirstCarcass") as LargeCarcass
	var second: LargeCarcass = map.get_node("World/Remains/SecondCarcass") as LargeCarcass
	_check(terrain.bounds == EXPECTED_BOUNDS and terrain.obstacles.size() == 3,
		"Fixed map has the formal battlefield bounds and three rocks")
	_check(core.position == Vector2(600, 555) and core.initial_nutrition == 72 and core.max_health == 240,
		"Map preserves 72 nutrition and 240 health at the middle rear core")
	_check(rear.position.y > core.position.y and rear.has_node("DigestiveOrgan"),
		"The original stomach remains behind the core")
	_check(map.get_node("World/Colony/Nodes").get_child_count() == 3 \
		and map.get_node("World/Colony/Connections").get_child_count() == 4,
		"Map creates no free initial growth or lateral connection")
	for host: HyphaNode in [left, right]:
		var organ: AttackOrgan = host.get_node("AttackOrgan") as AttackOrgan
		var weapon: SporeWeapon = host.get_node("SporeWeapon") as SporeWeapon
		var profile: WeaponProfile = weapon.get_weapon_profile()
		_check(organ.initial_nutrition == 4, "Both original attack organs retain four initial rounds")
		# 武器返回每实例配置副本，资源路径不是普通武器身份的有效契约。
		_check(profile != null and profile.is_valid() and profile.damage_type == WeaponProfile.DamageType.NORMAL \
			and profile.nutrition_cost == 1 and profile.max_targets == 1,
			"Both original organs use valid normal single-target profiles")
	# Real first-play regression: a leak during differentiation must remain targetable at the core.
	for index: int in range(24):
		var contact: Vector2 = core.position + Vector2.from_angle(TAU * index / 24.0) * 28.0
		var protected: bool = left.position.distance_to(contact) <= 178.0 or right.position.distance_to(contact) <= 178.0
		_check(protected, "The core contact ring has no blind spot between the starting weapons")
	for point: Vector2 in [core.position, left.position, right.position, rear.position, first.position, second.position]:
		_check(terrain.is_point_walkable(point, GrowthPlanner.TERRAIN_CLEARANCE),
			"Original tissues and carcasses lie on usable terrain")
	for child: Node in map.get_node("World/Colony/Connections").get_children():
		var edge: HyphaEdge = child as HyphaEdge
		_check(is_instance_valid(edge.start_node) and is_instance_valid(edge.end_node),
			"All inherited base edges keep their explicit endpoints")
		if is_instance_valid(edge.start_node) and is_instance_valid(edge.end_node):
			_check(terrain.is_segment_clear(edge.start_node.position, edge.end_node.position, 10.0),
				"All four base edges clear fixed rocks")
	_check(first.total_nutrition == 80 and second.total_nutrition == 120 \
		and first.position.x < core.position.x and second.position.x > core.position.x,
		"FirstCarcass80 stays on the left and SecondCarcass120 stays on the right")
	_check((map.get_node("World/FirstResourceGuide") as Node2D).position == FIRST_TARGET \
		and (map.get_node("World/SecondResourceGuide") as Node2D).position == SECOND_TARGET,
		"Both visible cross markers use the formal recommended targets")
	_check(first.position.distance_to(FIRST_TARGET) <= 110.0 \
		and second.position.distance_to(SECOND_TARGET) <= 110.0,
		"Each recommended new junction can cover its matching finite carcass")
	for host: HyphaNode in [left, right, rear]:
		_check(host.position.distance_to(first.position) > 110.0 \
			and host.position.distance_to(second.position) > 110.0,
			"Neither large carcass is unlocked by an original junction")
	_check(core.position.distance_to(first.position) > 140.0 \
		and core.position.distance_to(second.position) > 140.0,
		"Neither large carcass is initially covered by the mother core")
	var planner: GrowthPlanner = GrowthPlanner.new()
	planner.terrain_navigation = terrain
	var first_plan: Dictionary = planner.plan(left.position, FIRST_TARGET)
	var second_plan: Dictionary = planner.plan(right.position, SECOND_TARGET)
	_check(bool(first_plan["valid"]) and (first_plan["segments"] as Array).size() <= 2 \
		and int(first_plan["total_cost"]) > 0 and int(first_plan["total_cost"]) <= 12,
		"The early80 target takes one or two paid main segments from the left organ")
	_check(bool(second_plan["valid"]) and float(second_plan["distance"]) > float(first_plan["distance"]),
		"The right120 expansion has a longer paid route even when rounded costs tie")
	var points: Node2D = map.get_node("World/SpawnPoints") as Node2D
	var front: Node2D = points.get_child(0) as Node2D
	var side: Node2D = points.get_child(1) as Node2D
	_check(front.name == &"East" and front.position == Vector2(600, 280) \
		and side.name == &"West" and side.position == Vector2(1130, 330),
		"Formal front and side entries retain exact indices0 and1")
	_check(not (points.get_child(2) as Node2D).visible,
		"The inherited third entry is hidden and unused by the formal map")
	_check(front.has_node("EntryLabel") and side.has_node("EntryLabel"),
		"Exactly the two formal entries have visible direction labels")
	_check(side.position.distance_to(SECOND_TARGET) < side.position.distance_to(FIRST_TARGET),
		"The higher120 target is exposed to the side entry")
	for entry: Node2D in [front, side]:
		var path: PackedVector2Array = terrain.find_path(entry.position, core.position, 10.0)
		_check(path.size() >= 2 and path[0] == entry.position and path[-1] == core.position,
			"Both enemy entries have usable routes toward the core")
		for index: int in range(1, path.size()):
			_check(terrain.is_segment_clear(path[index - 1], path[index], 10.0),
				"Enemy route segments clear the same fixed rocks")
	evidence.append({"first_expansion": first_plan["total_cost"], "second_expansion": second_plan["total_cost"],
		"first_target": FIRST_TARGET, "second_target": SECOND_TARGET, "bounds": EXPECTED_BOUNDS})
	map.free()


func _container(parent: Node2D) -> Node2D:
	var result: Node2D = Node2D.new()
	parent.add_child(result)
	return result


func _make_build_fixture(map: Node2D) -> BuildFixture:
	var fixture: BuildFixture = BuildFixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.terrain = TerrainNavigation.new()
	var map_terrain: TerrainNavigation = map.get_node("World/TerrainNavigation") as TerrainNavigation
	fixture.terrain.bounds = map_terrain.bounds
	fixture.terrain.obstacles = map_terrain.obstacles.duplicate()
	fixture.world.add_child(fixture.terrain)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.position = (map.get_node("World/Colony/MotherCore") as Node2D).position
	fixture.world.add_child(fixture.core)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.network.register_node(fixture.core, true)
	fixture.nodes = _container(fixture.world)
	fixture.edges = _container(fixture.world)
	fixture.tips = _container(fixture.world)
	fixture.left = _node(fixture, (map.get_node("World/Colony/Nodes/HyphaNode") as Node2D).position)
	fixture.right = _node(fixture, (map.get_node("World/Colony/Nodes/RightNode") as Node2D).position)
	fixture.rear = _node(fixture, (map.get_node("World/Colony/Nodes/RearNode") as Node2D).position)
	fixture.left_core_edge = _edge(fixture, fixture.core, fixture.left)
	fixture.left_rear_edge = _edge(fixture, fixture.left, fixture.rear)
	_edge(fixture, fixture.core, fixture.rear)
	_edge(fixture, fixture.rear, fixture.right)
	fixture.planner = GrowthPlanner.new()
	fixture.planner.terrain_navigation = fixture.terrain
	fixture.planner.bounded_branches_enabled = true
	fixture.planner.auto_join_enabled = true
	fixture.growth = GrowthSystem.new()
	fixture.growth.planner = fixture.planner
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = fixture.nodes
	fixture.growth.edge_container = fixture.edges
	fixture.growth.tip_container = fixture.tips
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_physics_process(false)
	fixture.connection = ConnectionSystem.new()
	fixture.connection.growth_system = fixture.growth
	fixture.connection.mother_core = fixture.core
	fixture.world.add_child(fixture.connection)
	return fixture


func _node(fixture: BuildFixture, point: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	node.position = point
	fixture.nodes.add_child(node)
	fixture.network.register_node(node)
	return node


func _edge(fixture: BuildFixture, first: Node2D, second: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	fixture.edges.add_child(edge)
	edge.set_process(false)
	fixture.network.register_edge(edge)
	return edge


func _paid_expansion(fixture: BuildFixture, start: HyphaNode, target: Vector2) -> HyphaNode:
	var plan: Dictionary = fixture.growth.preview_target(start, target)
	var cost: int = int(plan["total_cost"])
	var task_id: int = fixture.growth.create_target(start, target)
	_check(task_id > 0 and cost > 0, "Recommended expansion starts as a real paid growth task")
	if task_id <= 0 or cost <= 0:
		return null
	fixture.growth.advance(1000.0)
	_check(fixture.growth.get_completed_endpoint(task_id) == null,
		"A recommended marker creates no free completed junction")
	var paid: bool = fixture.core.try_spend_nutrition(cost)
	_check(paid, "Expansion materials are deducted from the original72 capital")
	if not paid:
		return null
	fixture.spent += cost
	_check(fixture.growth.receive_nutrition(task_id, task_id, cost), "Fixture delivers exactly the paid expansion quote")
	fixture.growth.advance(1000.0)
	var endpoint: HyphaNode = fixture.growth.get_completed_endpoint(task_id)
	_check(endpoint != null and endpoint.global_position == target,
		"Paid expansion forms the exact explicit recommended junction")
	_check(int(fixture.growth.get_task_snapshot()["consumed_nutrition"]) == cost,
		"The real growth system consumes the complete quote including bounded branches")
	return endpoint


func _test_paid_expansions_and_bypass() -> void:
	var map: Node2D = MAP_SCENE.instantiate() as Node2D
	var fixture: BuildFixture = _make_build_fixture(map)
	map.free()
	var first: HyphaNode = _paid_expansion(fixture, fixture.left, FIRST_TARGET)
	var second: HyphaNode = _paid_expansion(fixture, fixture.right, SECOND_TARGET)
	if first == null or second == null:
		fixture.dispose()
		return
	_check(not fixture.network.has_direct_connection(first, second),
		"Two paid expansion arms do not unlock a free lateral connection")
	_check(not fixture.terrain.is_segment_clear(FIRST_TARGET, SECOND_TARGET, 10.0),
		"The fixed central rock requires a real lateral detour")
	var preview: Dictionary = fixture.connection.preview_connection(first, second)
	_check(bool(preview["valid"]) and int(preview["total_cost"]) > 0,
		"L connection between the explicit expansion nodes has a paid valid preview")
	if not bool(preview["valid"]):
		fixture.dispose()
		return
	var cost: int = int(preview["total_cost"])
	var task_id: int = fixture.connection.request_connection(first, second)
	_check(task_id > 0, "The actual connection system accepts both expansion endpoints")
	fixture.growth.advance(1000.0)
	_check(not fixture.network.has_direct_connection(first, second),
		"An unpaid L construction cannot connect crossed or nearby lines")
	var paid: bool = fixture.core.try_spend_nutrition(cost)
	_check(paid, "The lateral bypass is affordable only after paying both original expansion quotes")
	if not paid:
		fixture.dispose()
		return
	fixture.spent += cost
	_check(fixture.growth.receive_nutrition(task_id, task_id, cost), "Fixture delivers the paid bypass quote")
	fixture.growth.advance(1000.0)
	_check(fixture.network.has_direct_connection(first, second) \
		and fixture.growth.get_completed_endpoint(task_id) == second,
		"The completed paid corridor joins the existing endpoint identities")
	_check(fixture.core.nutrition == 72 - fixture.spent \
		and int(fixture.growth.get_task_snapshot()["consumed_nutrition"]) == cost,
		"No marker, branch, connection or completed bypass grants nutrition")
	fixture.left_core_edge.take_damage(fixture.left_core_edge.max_health)
	fixture.left_rear_edge.take_damage(fixture.left_rear_edge.max_health)
	_check(fixture.network.find_available_route(first, fixture.core, 2).found,
		"The paid lateral loop remains usable after both old left base links break")
	for edge: HyphaEdge in fixture.network.get_registered_edges():
		_check(fixture.terrain.is_segment_clear(edge.start_node.global_position, edge.end_node.global_position, 10.0),
			"Every real expansion and bypass edge clears the fixed map rocks")
	evidence.append({"expansions_and_bypass_spent": fixture.spent, "bypass_cost": cost,
		"capital_remaining": fixture.core.nutrition, "loop_survives_left_base_break": true})
	fixture.dispose()


func _guide() -> FirstEventGuide:
	var guide: FirstEventGuide = GUIDE_SCRIPT.new() as FirstEventGuide
	root.add_child(guide)
	return guide


func _test_first_events_and_snapshot_isolation() -> void:
	var guide: FirstEventGuide = _guide()
	var notifications: Array[Dictionary] = []
	guide.changed.connect(func(snapshot: Dictionary) -> void: notifications.append(snapshot.duplicate(true)))
	guide.record_event(&"not_a_real_event")
	_check(notifications.is_empty() and (guide.get_snapshot()["seen"] as Array).is_empty(),
		"Unknown events do not enter the first occurrence queue")
	var facts: Dictionary = {"stage_name": "展开", "nested": {"amount": 80}}
	var original_facts: Dictionary = facts.duplicate(true)
	for event_id: StringName in EVENT_IDS:
		guide.record_event(event_id, facts)
	_check(facts == original_facts, "The guide does not mutate supplied event facts")
	_check(guide.get_snapshot()["current_event"] == EVENT_IDS[0] \
		and (guide.get_snapshot()["seen"] as Array).size() == 6,
		"Six distinct first events queue without replacing the active hint")
	var count_before: int = notifications.size()
	for event_id: StringName in EVENT_IDS:
		guide.record_event(event_id)
	_check(notifications.size() == count_before, "Repeated gameplay events do not enqueue hints or emit redundant screens")
	var snapshot: Dictionary = guide.get_snapshot()
	(snapshot["seen"] as Array).clear()
	snapshot["text"] = "changed outside"
	_check((guide.get_snapshot()["seen"] as Array).size() == 6 \
		and guide.get_snapshot()["text"] != "changed outside",
		"Returned snapshots cannot change the guide's occurrence records or message")
	for event_id: StringName in EVENT_IDS:
		_check(guide.get_snapshot()["current_event"] == event_id and bool(guide.get_snapshot()["visible"]),
			"Queued first events appear once in arrival order")
		if event_id == &"stage_unlocked":
			_check(String(guide.get_snapshot()["text"]).contains("展开"), "The unlock hint can name the supplied real stage")
		guide.dismiss_current()
	_check(not bool(guide.get_snapshot()["visible"]) and guide.get_snapshot()["current_event"] == &"",
		"Dismissing all first events leaves no repeated screen")
	guide.free()


func _test_disable_reset_and_paused_buttons() -> void:
	var guide: FirstEventGuide = _guide()
	var panel: Panel = guide.get_node("MessagePanel") as Panel
	var dismiss: Button = guide.get_node("MessagePanel/Dismiss") as Button
	var toggle: Button = guide.get_node("Toggle") as Button
	_check(guide.process_mode == Node.PROCESS_MODE_ALWAYS \
		and dismiss.focus_mode == Control.FOCUS_NONE and toggle.focus_mode == Control.FOCUS_NONE,
		"First event UI remains usable while paused and never takes keyboard focus")
	guide.record_event(&"target_placed")
	guide.record_event(&"remains_returned")
	paused = true
	_check(guide.can_process() and dismiss.can_process() and toggle.can_process(),
		"Hint controls inherit always processing during a game pause")
	dismiss.pressed.emit()
	_check(guide.get_snapshot()["current_event"] == &"remains_returned",
		"The actual dismiss button advances the queue during pause")
	toggle.toggled.emit(false)
	_check(not bool(guide.get_snapshot()["enabled"]) and not bool(guide.get_snapshot()["visible"]) \
		and not panel.visible and toggle.visible,
		"The actual toggle hides the message and leaves re-enable available")
	guide.record_event(&"nutrition_returned")
	_check(not bool(guide.get_snapshot()["visible"]) \
		and (guide.get_snapshot()["seen"] as Array).has(&"nutrition_returned"),
		"Events that occur while disabled stay silent")
	toggle.toggled.emit(true)
	guide.record_event(&"target_placed")
	guide.record_event(&"nutrition_returned")
	_check(bool(guide.get_snapshot()["enabled"]) and not bool(guide.get_snapshot()["visible"]),
		"Re-enabling does not replay dismissed, queued or muted historical first events")
	guide.record_event(&"network_broken")
	_check(guide.get_snapshot()["current_event"] == &"network_broken" and panel.visible,
		"A new first event after re-enabling still displays normally")
	guide.reset()
	_check(bool(guide.get_snapshot()["enabled"]) and not bool(guide.get_snapshot()["visible"]) \
		and (guide.get_snapshot()["seen"] as Array).is_empty(),
		"Reset clears current, pending and seen records for a new run")
	guide.record_event(&"target_placed")
	_check(guide.get_snapshot()["current_event"] == &"target_placed",
		"A reset run can show the same first gameplay event again")
	guide.set_enabled(false)
	guide.reset()
	_check(not bool(guide.get_snapshot()["enabled"]) and (guide.get_snapshot()["seen"] as Array).is_empty(),
		"Reset preserves an explicitly disabled setting on a reused component")
	paused = false
	guide.free()
