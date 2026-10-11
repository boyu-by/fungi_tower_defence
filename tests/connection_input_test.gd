extends SceneTree
## 通过公开选择和连接接口验证输入及标记；无供养推进，预览和提交不能扣款。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_check(InputMap.has_action("connection_mode"), "Input map defines the L connection action")
	await _test_input_modes()
	await _test_quotes_selection_orders_and_slots()
	await _test_same_endpoint_clear_and_reselect()
	await _test_rejection_reasons()
	await _test_confirmation_status_and_exit()
	await _test_lower_endpoint_label_layout()
	await _test_bounds_coordinates_and_forward_binding()
	_check(root.get_child_count() == 0, "Connection input teardown leaves no orphan nodes")
	print("CONNECTION_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture(initial_nutrition: int = 64, controller_first: bool = false) -> Dictionary:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	var nodes: Node2D = Node2D.new()
	var edges: Node2D = Node2D.new()
	var tips: Node2D = Node2D.new()
	var targets: Node2D = Node2D.new()
	for container: Node2D in [nodes, edges, tips, targets]:
		world.add_child(container)
	var core: MotherCore = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	core.add_child(health_bar)
	core.position = Vector2(200, 400)
	core.initial_nutrition = initial_nutrition
	world.add_child(core)
	var network: NetworkSystem = NetworkSystem.new()
	world.add_child(network)
	_check(network.register_node(core, true), "Fixture registers its actual mother core")
	var fixture: Dictionary = {
		"world": world, "nodes": nodes, "edges": edges, "tips": tips,
		"targets": targets, "core": core, "network": network,
	}
	var front: HyphaNode = _add_junction(fixture, Vector2(400, 400))
	var remote: HyphaNode = _add_junction(fixture, Vector2(800, 400))
	_add_edge(fixture, core, front)
	var planner: GrowthPlanner = GrowthPlanner.new()
	var growth: GrowthSystem = GrowthSystem.new()
	growth.planner = planner
	growth.network_system = network
	growth.node_container = nodes
	growth.edge_container = edges
	growth.tip_container = tips
	world.add_child(growth)
	growth.set_process(false)
	growth.set_physics_process(false)
	var connection: ConnectionSystem = ConnectionSystem.new()
	connection.growth_system = growth
	connection.mother_core = core
	var controller: ConnectionInputController = ConnectionInputController.new()
	controller.connection_system = connection
	controller.network_system = network
	controller.target_container = targets
	if controller_first:
		world.add_child(controller)
	world.add_child(connection)
	if not controller_first:
		world.add_child(controller)
	fixture["front"] = front
	fixture["remote"] = remote
	fixture["planner"] = planner
	fixture["growth"] = growth
	fixture["connection"] = connection
	fixture["controller"] = controller
	return fixture


func _remove_fixture(fixture: Dictionary) -> void:
	var connection: ConnectionSystem = fixture["connection"]
	connection.reset()
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


func _add_junction(fixture: Dictionary, point: Vector2) -> HyphaNode:
	var junction: HyphaNode = HyphaNode.new()
	var selection_ring: Line2D = Line2D.new()
	selection_ring.name = "SelectionRing"
	junction.add_child(selection_ring)
	var nodes: Node2D = fixture["nodes"]
	nodes.add_child(junction)
	junction.global_position = point
	var network: NetworkSystem = fixture["network"]
	_check(network.register_node(junction), "Fixture registers an existing mature junction")
	return junction


func _add_edge(fixture: Dictionary, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	var edges: Node2D = fixture["edges"]
	edges.add_child(edge)
	var network: NetworkSystem = fixture["network"]
	_check(network.register_edge(edge), "Fixture registers a real physical edge")
	return edge


func _action(action: StringName, pressed: bool = true) -> InputEventAction:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = pressed
	return event


func _key(key: Key, echo: bool = false) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	event.echo = echo
	return event


func _mouse(button: MouseButton, point: Vector2, pressed: bool = true) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.position = point
	event.global_position = point
	event.pressed = pressed
	return event


func _motion(point: Vector2) -> InputEventMouseMotion:
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	return event


func _markers(fixture: Dictionary, preview: bool) -> Array[ConnectionTarget]:
	var markers: Array[ConnectionTarget] = []
	var targets: Node2D = fixture["targets"]
	for child: Node in targets.get_children():
		if child is ConnectionTarget and not child.is_queued_for_deletion() \
				and child.is_preview() == preview:
			markers.append(child)
	return markers


func _enter(fixture: Dictionary) -> void:
	var controller: ConnectionInputController = fixture["controller"]
	_check(controller.enter_placement_mode(), "Can enter connection selection")
	controller.set_process(false)


func _test_input_modes() -> void:
	var fixture: Dictionary = _fixture()
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var front: HyphaNode = fixture["front"]
	var modes: Array[bool] = []
	controller.mode_changed.connect(func(placing: bool) -> void: modes.append(placing))
	_check(not controller.is_placing(), "Connection input starts outside placement")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, front.global_position)),
		"Ordinary left click passes through to normal selection")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, Vector2.ZERO)),
		"Ordinary right click is not consumed")
	_check(not controller.handle_input(_key(KEY_ESCAPE)), "Ordinary Escape is not consumed")
	_check(not controller.handle_input(_motion(front.global_position)), "Ordinary pointer motion passes through")
	_check(not controller.handle_input(_action(&"connection_mode", false)), "L release does not enter selection")
	_check(not controller.handle_input(_key(KEY_L, true)), "L key echo is ignored")
	_check(controller.handle_input(_key(KEY_L)), "Configured L action enters selection")
	controller.set_process(false)
	_check(controller.is_placing() and _markers(fixture, true).size() == 1,
		"Entering creates one visible connection preview")
	_check(controller.enter_placement_mode() and modes == [true], "Repeated enter preserves one mode transition")
	_check(controller.handle_input(_key(KEY_L)) and not controller.is_placing() \
		and not connection.has_active_task(), "A second L toggles selection off without creating or cancelling a build")
	_check(controller.handle_input(_key(KEY_L)) and controller.is_placing(), "L toggles selection back on")
	controller.set_process(false)
	for action: StringName in [&"growth_mode", &"remote_cultivation_mode", &"cultivate_attack",
			&"growth_pause", &"growth_cancel"]:
		_check(not controller.handle_input(_action(action)), "G/B/C/P/X remain owned by the level dispatcher")
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, front.global_position)), "First selection click is consumed")
	_check(controller.get_selection_snapshot().get("first_node") == front and not connection.has_active_task(),
		"First click selects a host without creating a task")
	_check(not controller.handle_input(_key(KEY_ESCAPE, true)) and controller.is_placing(),
		"Escape echo preserves endpoint selection")
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, Vector2.ZERO)), "Placement right click is consumed")
	_check(not controller.is_placing() and controller.get_selection_snapshot().get("first_node") == null \
		and not connection.has_active_task(), "Right click clears the unconfirmed endpoints and exits")
	_enter(fixture)
	_check(controller.handle_input(_key(KEY_ESCAPE)), "Placement Escape is consumed")
	_check(not controller.is_placing() and not connection.has_active_task(), "Escape exits without requesting a build")
	_check(modes == [true, false, true, false, true, false], "Mode notifications follow actual transitions")
	await _remove_fixture(fixture)


func _test_quotes_selection_orders_and_slots() -> void:
	var fixture: Dictionary = _fixture(0)
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var network: NetworkSystem = fixture["network"]
	var planner: GrowthPlanner = fixture["planner"]
	var growth: GrowthSystem = fixture["growth"]
	var core: MotherCore = fixture["core"]
	var front: HyphaNode = fixture["front"]
	var remote: HyphaNode = fixture["remote"]
	var nodes: Node2D = fixture["nodes"]
	var edges: Node2D = fixture["edges"]
	var tips: Node2D = fixture["tips"]
	_check(front.try_reserve_organ_slot("connection_input_test"), "Fixture retains an unrelated reserved organ slot")
	var occupant: AttackOrgan = ATTACK_SCENE.instantiate() as AttackOrgan
	remote.add_child(occupant)
	var existing_nodes: Array[Node2D] = network.get_registered_nodes()
	var node_count: int = nodes.get_child_count()
	var edge_count: int = edges.get_child_count()
	_enter(fixture)
	_check(controller.select_endpoint(front), "Connected first host is selectable despite its reserved organ slot")
	var quote: Dictionary = controller.preview_at(remote.global_position)
	_check(bool(quote.get("valid", false)) and quote.get("first_node") == front \
		and quote.get("second_node") == remote and quote.get("start_node") == front \
		and quote.get("target_node") == remote and not bool(quote.get("reversed", true)),
		"Connected-first selection preserves actual supply direction and both exact hosts")
	var expected_plan: Dictionary = planner.plan(front.global_position, remote.global_position, true)
	_check(quote.get("plan") == expected_plan and int(quote.get("total_cost", 0)) == int(expected_plan["total_cost"]),
		"Preview uses the coordinator's exact endpoint-existing planner quote")
	var segments: Array = expected_plan["segments"]
	_check(int(segments.back().get("junction_cost", -1)) == 0 \
		and int(expected_plan["extension_cost"]) == 5 and int(expected_plan["junction_cost"]) == 12,
		"Both existing endpoints are free while three relays and extension remain paid")
	var marker: ConnectionTarget = _markers(fixture, true)[0]
	_check(marker.get_route_plan() == expected_plan and marker.first_label.visible and marker.second_label.visible,
		"Preview visibly retains the exact route and both endpoint markers")
	_check(marker.status_label.text.contains("延伸 5 + 中继菌结 12 = 总计 17") \
		and marker.status_label.text.contains("已有两端各 0") and marker.status_label.text.contains("付费中继 3"),
		"Marker explains extension fees, paid relays and free existing hosts")
	_check(marker.first_label.text.contains("供养起点") and marker.second_label.text.contains("接入终点"),
		"Endpoint labels distinguish the real source and target")
	controller.clear_endpoints()
	_check(controller.get_selection_snapshot().get("first_node") == null \
		and controller.get_selection_snapshot().get("second_node") == null,
		"Clear removes both selections while leaving placement available")
	_check(controller.is_placing() and controller.select_endpoint(remote),
		"Disconnected occupied host can be reselected first")
	quote = controller.preview_at(front.global_position)
	_check(bool(quote.get("valid", false)) and bool(quote.get("reversed", false)) \
		and quote.get("first_node") == remote and quote.get("second_node") == front \
		and quote.get("start_node") == front and quote.get("target_node") == remote,
		"Disconnected-first selection reverses construction without changing either chosen host")
	_check(quote.get("plan") == expected_plan and marker.get_route_plan() == expected_plan,
		"Reversed input retains the same source-oriented planner fees")
	_check(marker.status_label.text.contains("② → ①") and marker.status_label.text.contains("自动反向") \
		and marker.first_label.text.contains("接入终点") and marker.second_label.text.contains("供养起点"),
		"Preview clearly displays the reversed route and actual endpoint roles")
	_check(marker.get_endpoint_snapshot().get("first_node") == remote \
		and marker.get_endpoint_snapshot().get("second_node") == front,
		"Visible endpoint identity preserves both click orders")
	_check(network.get_registered_nodes() == existing_nodes and nodes.get_child_count() == node_count \
		and edges.get_child_count() == edge_count and tips.get_child_count() == 0,
		"Repeated preview creates no topology, mature hosts or growth tips")
	_check(core.nutrition == 0 and not growth.has_active_task() and not connection.has_active_task(),
		"Preview neither requires funds nor debits nutrition or creates a task")
	_check(front.get_organ_slot_state() == &"reserved" and remote.get_organ_occupant() == occupant,
		"Organ reservation and exact occupant survive both selection orders and every preview")
	planner.junction_cost = 0
	var free_relay_plan: Dictionary = planner.plan(front.global_position, remote.global_position, true)
	quote = controller.preview_at(front.global_position)
	var free_relay_positions: PackedVector2Array = marker.get_route_plan().get("junction_positions", PackedVector2Array())
	_check(bool(quote.get("valid", false)) and marker.get_route_plan() == free_relay_plan \
		and free_relay_positions.size() == 3 and marker.status_label.text.contains("中继菌结 0 = 总计 5"),
		"A zero relay price preserves every planned relay point while quoting only actual extension fees")
	await _remove_fixture(fixture)


func _test_same_endpoint_clear_and_reselect() -> void:
	var fixture: Dictionary = _fixture()
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var front: HyphaNode = fixture["front"]
	var remote: HyphaNode = fixture["remote"]
	_enter(fixture)
	_check(controller.place_at(front.global_position), "First place_at selects an existing host")
	_check(not controller.select_endpoint(front), "A repeated host refuses confirmation")
	var selection: Dictionary = controller.get_selection_snapshot()
	_check(selection.get("reason") == &"same_node" and selection.get("first_node") == front \
		and not connection.has_active_task(), "Same-host error retains the first endpoint and creates no task")
	_check(not controller.place_at(Vector2(600, 500)), "An empty point cannot become an endpoint")
	_check(controller.get_selection_snapshot().get("reason") == &"endpoint_required" \
		and controller.get_selection_snapshot().get("first_node") == front,
		"Empty-point failure explains choosing another existing host and preserves first selection")
	controller.clear_endpoints()
	_check(controller.get_selection_snapshot().get("reason") == &"choose_first" \
		and _markers(fixture, true).size() == 1, "Clear restores the first-click prompt on the same preview marker")
	_check(controller.select_endpoint(remote), "Clear allows a different first endpoint")
	_check(bool(controller.preview_at(front.global_position).get("valid", false)),
		"Reselection reaches a valid reversed preview")
	await _remove_fixture(fixture)


func _test_rejection_reasons() -> void:
	var fixture: Dictionary = _fixture()
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var growth: GrowthSystem = fixture["growth"]
	var core: MotherCore = fixture["core"]
	var front: HyphaNode = fixture["front"]
	var remote: HyphaNode = fixture["remote"]
	_enter(fixture)
	_check(controller.select_endpoint(front), "Selects first before another ordinary build starts")
	_check(growth.create_target(front, Vector2(550, 450)) > 0, "Fixture creates an ordinary build through its API")
	var quote: Dictionary = controller.preview_at(remote.global_position)
	_check(not bool(quote.get("valid", false)) and quote.get("reason") == &"busy" \
		and quote.get("reason") == connection.preview_connection(front, remote).get("reason"),
		"Busy preview preserves the coordinator's reason without quoting another construction")
	_check(not controller.select_endpoint(remote) and not controller.enter_placement_mode(),
		"An active ordinary build blocks confirmation and mode entry")
	_check(growth.cancel_task(), "Fixture cancels its own ordinary task")
	controller.clear_endpoints()
	_check(controller.select_endpoint(front), "Can choose a host after the ordinary build ends")
	connection.construction_blocker = func() -> bool:
		return true
	quote = controller.preview_at(remote.global_position)
	_check(not bool(quote.get("valid", false)) and quote.get("reason") == &"construction_busy",
		"Other construction blockers retain their explicit coordinator reason")
	connection.construction_blocker = Callable()
	var disconnected: HyphaNode = _add_junction(fixture, Vector2(800, 520))
	controller.clear_endpoints()
	_check(controller.select_endpoint(remote), "Disconnected hosts remain first-selectable")
	quote = controller.preview_at(disconnected.global_position)
	_check(not bool(quote.get("valid", false)) and quote.get("reason") == &"disconnected" \
		and not controller.select_endpoint(disconnected), "Two disconnected hosts report unavailable core supply")
	controller.clear_endpoints()
	_check(controller.select_endpoint(front), "Restores connected first selection for direct-link validation")
	_add_edge(fixture, front, remote)
	quote = controller.preview_at(remote.global_position)
	_check(not bool(quote.get("valid", false)) and quote.get("reason") == &"already_connected" \
		and not controller.place_at(remote.global_position), "A duplicate direct link is rejected with the coordinator's reason")
	core.health = 0
	quote = controller.preview_at(disconnected.global_position)
	_check(not bool(quote.get("valid", false)) and quote.get("reason") == &"core_unavailable",
		"A depleted mother core cannot supply a proposed connection")
	_check(core.nutrition == 64 and not connection.has_active_task(), "Rejected requests never debit nutrition or create connection tasks")
	await _remove_fixture(fixture)


func _test_confirmation_status_and_exit() -> void:
	var fixture: Dictionary = _fixture()
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var growth: GrowthSystem = fixture["growth"]
	var core: MotherCore = fixture["core"]
	var network: NetworkSystem = fixture["network"]
	var front: HyphaNode = fixture["front"]
	var remote: HyphaNode = fixture["remote"]
	var observed: Array[Dictionary] = []
	controller.status_changed.connect(func(snapshot: Dictionary) -> void: observed.append(snapshot))
	_enter(fixture)
	_check(controller.place_at(front.global_position), "First click accepts a source selection")
	var quote: Dictionary = controller.preview_at(remote.global_position)
	_check(controller.place_at(remote.global_position), "Second valid click confirms a real connection")
	var snapshot: Dictionary = connection.get_task_snapshot()
	var task_id: int = int(snapshot.get("task_id", 0))
	_check(task_id > 0 and snapshot.get("task_kind") == &"connection" \
		and task_id == int(growth.get_task_snapshot().get("task_id", 0)),
		"Coordinator and existing growth system own the same connection task identity")
	_check(snapshot.get("start_node") == front and snapshot.get("target_node") == remote \
		and int(snapshot.get("total_cost", 0)) == int(quote.get("total_cost", 0)),
		"Confirmation retains the exact chosen hosts and quoted planner cost")
	_check(not controller.is_placing() and _markers(fixture, true).is_empty() \
		and _markers(fixture, false).size() == 1, "Confirmation replaces preview with one persistent task marker")
	var marker: ConnectionTarget = _markers(fixture, false)[0]
	_check(marker.get_task_id() == task_id and marker.get_status_snapshot() == snapshot \
		and marker.get_route_plan() == quote.get("plan"), "Status marker retains the accepted route and actual snapshot")
	_check(not network.get_registered_nodes().has(marker) and core.nutrition == 64,
		"Input and task markers never join the topology or debit core funds")
	controller.exit_placement_mode()
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, remote.global_position)) \
		and not controller.handle_input(_key(KEY_ESCAPE)) and connection.has_active_task() \
		and int(connection.get_task_snapshot().get("task_id", 0)) == task_id,
		"Exiting and ordinary Right/Escape preserve the confirmed connection build")
	_check(controller.handle_input(_key(KEY_L)) and not controller.is_placing() \
		and connection.has_active_task() and int(connection.get_task_snapshot().get("task_id", 0)) == task_id,
		"L during a confirmed build preserves its task and refuses another placement")
	_check(not controller.handle_input(_key(KEY_P)) and not controller.handle_input(_key(KEY_X)),
		"Connection controller leaves confirmed-build P/X routing to its parent")
	growth.set_supply_wait_reason(task_id, &"combat_reserve")
	_check(marker.status_label.text.contains("保留战斗营养"), "Actual growth supply status reaches the connection marker")
	_check(connection.pause_task() and marker.get_status_snapshot().get("state") == &"paused",
		"Parent coordinator pause synchronizes the persistent marker")
	_check(connection.resume_task() and connection.cancel_task(), "Parent coordinator owns resume and actual cancellation")
	snapshot = connection.get_task_snapshot()
	_check(marker.get_status_snapshot() == snapshot and snapshot.get("state") == &"cancelled",
		"Terminal cancellation remains visible with the same real task snapshot")
	_enter(fixture)
	_check(controller.select_endpoint(remote), "A replacement preview can select a different first host")
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, Vector2.ZERO)) \
		and marker.get_status_snapshot() == snapshot and marker.get_task_id() == task_id,
		"Right-click replacement exit preserves the prior task and its terminal marker")
	_enter(fixture)
	_check(controller.handle_input(_key(KEY_ESCAPE)) and marker.get_status_snapshot() == snapshot,
		"Escape replacement exit likewise preserves the prior confirmed task")
	_check(not observed.is_empty() and observed.back() == snapshot, "Status signal reports the coordinator's committed status")
	connection.reset()
	_check(_markers(fixture, false).is_empty(), "Reset removes the old task marker")
	connection.task_changed.emit(snapshot)
	_check(_markers(fixture, false).is_empty() and not connection.has_active_task(),
		"Late task notification cannot resurrect a reset marker or build")
	await _remove_fixture(fixture)


func _label_world_rect(marker: ConnectionTarget, label: Label) -> Rect2:
	return marker.get_global_transform() * Rect2(label.position, label.size)


func _test_lower_endpoint_label_layout() -> void:
	var fixture: Dictionary = _fixture(0)
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var growth: GrowthSystem = fixture["growth"]
	var front: HyphaNode = fixture["front"]
	var remote: HyphaNode = fixture["remote"]
	# 与默认宽度不同，确认预览和正式标记都使用控制器传入的同一地图边界。
	controller.placement_bounds = Rect2(0, 230, 1180, 410)
	remote.global_position = Vector2(780, 400)
	_enter(fixture)
	_check(controller.select_endpoint(front), "Can choose a source for upper-map status layout")
	controller.preview_at(remote.global_position)
	var marker: ConnectionTarget = _markers(fixture, true)[0]
	_check(marker.placement_bounds == controller.placement_bounds,
		"Preview marker receives the controller's exact map bounds")
	var preview_rect: Rect2 = _label_world_rect(marker, marker.status_label)
	var role_rect: Rect2 = _label_world_rect(marker, marker.second_label)
	_check(controller.placement_bounds.encloses(preview_rect) and preview_rect.end.y <= role_rect.position.y,
		"Right-endpoint preview prefers the space above its role label inside the map")
	_check(controller.select_endpoint(remote), "Can confirm the right endpoint without changing the label contract")
	marker = _markers(fixture, false)[0]
	var task_id: int = int(connection.get_task_snapshot().get("task_id", 0))
	growth.set_supply_wait_reason(task_id, &"combat_reserve")
	var status_rect: Rect2 = _label_world_rect(marker, marker.status_label)
	role_rect = _label_world_rect(marker, marker.second_label)
	_check(controller.placement_bounds.encloses(status_rect) and status_rect.position.y < remote.global_position.y,
		"Multiline right-endpoint status uses upper or side space instead of resource hints below the target")
	_check(not status_rect.intersects(role_rect) \
		and not status_rect.intersects(_label_world_rect(marker, marker.first_label)),
		"Full waiting status keeps space around both endpoint role labels")
	_check(connection.cancel_task(), "Fixture ends the first layout task through its real coordinator")
	remote.global_position = Vector2(750, 590)
	_enter(fixture)
	_check(controller.select_endpoint(front), "Can select a source for a lower-map endpoint")
	controller.preview_at(remote.global_position)
	marker = _markers(fixture, true)[0]
	preview_rect = _label_world_rect(marker, marker.status_label)
	role_rect = _label_world_rect(marker, marker.second_label)
	_check(controller.placement_bounds.encloses(preview_rect) and preview_rect.end.y <= role_rect.position.y,
		"Lower-endpoint preview stays above the role label and outside the bottom HUD")
	_check(controller.select_endpoint(remote), "Can confirm a lower-map connection")
	marker = _markers(fixture, false)[0]
	task_id = int(connection.get_task_snapshot().get("task_id", 0))
	growth.set_supply_wait_reason(task_id, &"combat_reserve")
	status_rect = _label_world_rect(marker, marker.status_label)
	role_rect = _label_world_rect(marker, marker.second_label)
	_check(marker.placement_bounds == controller.placement_bounds \
		and controller.placement_bounds.encloses(status_rect) and status_rect.end.y <= role_rect.position.y,
		"Lower-endpoint multiline status fits above its role label inside the supplied map bounds")
	for label: Label in [marker.status_label, marker.first_label, marker.second_label]:
		var label_rect: Rect2 = _label_world_rect(marker, label)
		_check(controller.placement_bounds.encloses(label_rect) and label_rect.end.y < 650.0,
			"Every lower-endpoint label remains in the map without covering the bottom HUD")
	_check(marker.status_label.text.contains("方向 ① → ②") \
		and marker.status_label.text.contains("延伸 5 + 中继菌结 12 = 总计 17") \
		and marker.status_label.text.contains("已有两端各 0") \
		and marker.status_label.text.contains("已投入") \
		and marker.status_label.text.contains("保留战斗营养"),
		"Layout retains direction, all planner fees, investment and waiting information")
	await _remove_fixture(fixture)


func _test_bounds_coordinates_and_forward_binding() -> void:
	var fixture: Dictionary = _fixture(0, true)
	var controller: ConnectionInputController = fixture["controller"]
	var connection: ConnectionSystem = fixture["connection"]
	var network: NetworkSystem = fixture["network"]
	var core: MotherCore = fixture["core"]
	var front: HyphaNode = fixture["front"]
	var remote: HyphaNode = fixture["remote"]
	var observed: Array[Dictionary] = []
	controller.status_changed.connect(func(snapshot: Dictionary) -> void: observed.append(snapshot))
	await process_frame
	_enter(fixture)
	for point: Vector2 in [Vector2(-1, 400), Vector2(1200, 400), Vector2(400, 229), Vector2(400, 640),
			Vector2(INF, 400), Vector2(NAN, 400)]:
		var quote: Dictionary = controller.preview_at(point)
		_check(not bool(quote.get("valid", false)) and quote.get("hover_node") == null \
			and not controller.place_at(point), "Invalid bounds and nonfinite coordinates cannot select an endpoint")
	var outside: HyphaNode = _add_junction(fixture, Vector2(1200, 450))
	_check(not controller.select_endpoint(outside), "Direct selection respects endpoint placement bounds")
	var temporary: Node2D = Node2D.new()
	var tips: Node2D = fixture["tips"]
	tips.add_child(temporary)
	temporary.global_position = Vector2(600, 500)
	_check(network.register_node(temporary), "Fixture registers a temporary network tip")
	_check(not controller.place_at(core.global_position) and not controller.place_at(temporary.global_position),
		"Mother core and temporary tips cannot replace existing mature junction endpoints")
	var top_left: HyphaNode = _add_junction(fixture, Vector2(0, 230))
	var bottom_right: HyphaNode = _add_junction(fixture, Vector2(1199, 639))
	_add_edge(fixture, core, top_left)
	_check(controller.select_endpoint(top_left) \
		and bool(controller.preview_at(bottom_right.global_position).get("valid", false)),
		"Bounds include their top-left corner and interior beside the bottom-right corner")
	controller.clear_endpoints()
	var original_transform: Transform2D = root.canvas_transform
	root.canvas_transform = Transform2D(Vector2(1.5, 0), Vector2(0, 1.5), Vector2(30, 45))
	controller.position = Vector2(77, 31)
	var screen_remote: Vector2 = root.canvas_transform * remote.global_position
	var screen_front: Vector2 = root.canvas_transform * front.global_position
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, screen_remote)),
		"Transformed first click is consumed by a translated controller")
	_check(controller.get_selection_snapshot().get("first_node") == remote,
		"First selection converts viewport coordinates into world coordinates")
	_check(controller.handle_input(_motion(screen_front)), "Transformed hover updates the second endpoint")
	var marker: ConnectionTarget = _markers(fixture, true)[0]
	var quote: Dictionary = controller.get_selection_snapshot()
	_check(bool(quote.get("valid", false)) and bool(quote.get("reversed", false)) \
		and quote.get("second_node") == front and marker.global_position.is_equal_approx(front.global_position),
		"World-coordinate preview finds the powered second host and shows actual reversed direction")
	var label_rect: Rect2 = marker.get_global_transform_with_canvas() * Rect2(
		marker.status_label.position, marker.status_label.size)
	_check(label_rect.position.x >= 0 and label_rect.end.x <= root.size.x,
		"Transformed fee label remains inside the viewport")
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, screen_front)),
		"Transformed second click confirms one reversed connection")
	var snapshot: Dictionary = connection.get_task_snapshot()
	_check(snapshot.get("start_node") == front and snapshot.get("target_node") == remote \
		and snapshot.get("target_position") == remote.global_position,
		"Accepted reversed build retains world coordinates and exact original host identities")
	_check(not observed.is_empty() and observed.back() == snapshot,
		"Forward-referenced connection coordinator delivers its actual task status")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, screen_front, false)),
		"Release after confirmation cannot consume a normal click or create another task")
	marker = _markers(fixture, false)[0]
	_check(marker.status_label.text.contains("② → ①") \
		and marker.get_endpoint_snapshot().get("first_node") == remote \
		and marker.get_endpoint_snapshot().get("second_node") == front,
		"Confirmed marker preserves reversed click order and source-target direction")
	root.canvas_transform = original_transform
	await _remove_fixture(fixture)
