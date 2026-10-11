extends SceneTree
## 只调用公开输入/生长 API：测试放置隔离、连通起点和真实状态同步。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_check(InputMap.has_action("growth_mode"), "Root input map defines growth_mode")
	_check(InputMap.has_action("growth_pause"), "Root input map defines growth_pause")
	_check(InputMap.has_action("growth_cancel"), "Root input map defines growth_cancel")
	await _test_input_modes()
	await _test_preview_and_connected_start()
	await _test_controls_and_status()
	await _test_mouse_coordinates()
	_check(root.get_child_count() == 0, "Input test teardown leaves no orphan nodes")
	print("GROWTH_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture() -> Dictionary:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	var nodes: Node2D = Node2D.new()
	var edges: Node2D = Node2D.new()
	var tips: Node2D = Node2D.new()
	var targets: Node2D = Node2D.new()
	world.add_child(nodes)
	world.add_child(edges)
	world.add_child(tips)
	world.add_child(targets)
	var core: MotherCore = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	core.add_child(health_bar)
	core.position = Vector2(200, 400)
	core.initial_nutrition = 0
	world.add_child(core)
	var network: NetworkSystem = NetworkSystem.new()
	world.add_child(network)
	_check(network.register_node(core, true), "Fixture registers the real mother core")
	var fixture: Dictionary = {
		"world": world, "nodes": nodes, "edges": edges, "tips": tips,
		"targets": targets, "core": core, "network": network,
	}
	var front: HyphaNode = _add_junction(fixture, Vector2(400, 400))
	_add_edge(fixture, core, front)
	fixture["front"] = front
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
	var field: FungalField = FungalField.new()
	world.add_child(field)
	var sources: Array[Dictionary] = [
		{"node": core, "kind": &"core", "connected": true},
		{"node": front, "kind": &"junction", "connected": true},
	]
	field.set_sources(sources)
	field.advance(1.0)
	var controller: GrowthInputController = GrowthInputController.new()
	controller.growth_system = growth
	controller.planner = planner
	controller.network_system = network
	controller.target_container = targets
	world.add_child(controller)
	fixture["planner"] = planner
	fixture["growth"] = growth
	fixture["controller"] = controller
	fixture["field"] = field
	return fixture


func _remove_fixture(fixture: Dictionary) -> void:
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
	_check(network.register_node(junction), "Fixture registers a mature junction")
	return junction


func _add_edge(fixture: Dictionary, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	var edges: Node2D = fixture["edges"]
	edges.add_child(edge)
	var network: NetworkSystem = fixture["network"]
	_check(network.register_edge(edge), "Fixture registers an edge")
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


func _markers(fixture: Dictionary, preview: bool) -> Array[GrowthTarget]:
	var markers: Array[GrowthTarget] = []
	var targets: Node2D = fixture["targets"]
	for child: Node in targets.get_children():
		if child is GrowthTarget and not child.is_queued_for_deletion():
			if child.is_preview() == preview:
				markers.append(child)
	return markers


func _test_input_modes() -> void:
	var fixture: Dictionary = _fixture()
	var controller: GrowthInputController = fixture["controller"]
	var growth: GrowthSystem = fixture["growth"]
	var modes: Array[bool] = []
	controller.mode_changed.connect(func(placing: bool) -> void: modes.append(placing))
	_check(not controller.is_placing(), "Starts outside placement mode")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, Vector2(400, 400))),
		"Ordinary left click passes through to selection")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, Vector2.ZERO)),
		"Ordinary right click passes through to selection")
	_check(not controller.handle_input(_key(KEY_ESCAPE)), "Ordinary Escape passes through to selection")
	_check(not controller.handle_input(_motion(Vector2(600, 400))), "Ordinary pointer motion passes through")
	_check(not controller.handle_input(_action(&"growth_mode", false)), "Key release does not enter placement")
	_check(not controller.handle_input(_key(KEY_G, true)), "G key echo is ignored")
	_check(not controller.is_placing(), "Echo leaves placement mode unchanged")
	_check(controller.handle_input(_key(KEY_G)), "Configured G action is handled")
	controller.set_process(false)
	_check(controller.is_placing(), "G enters placement")
	_check(controller.enter_placement_mode() and modes.size() == 1, "Repeated enter does not duplicate mode signal")
	_check(not controller.handle_input(_key(KEY_ESCAPE, true)) and controller.is_placing(),
		"Escape echo leaves current placement intact")
	_check(controller.handle_input(_motion(Vector2(700, 460))), "Placement pointer motion is handled")
	var previews: Array[GrowthTarget] = _markers(fixture, true)
	_check(previews.size() == 1 and previews[0].global_position == Vector2(700, 460),
		"Ghost marker follows world pointer")
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, Vector2.ZERO)), "Placement right click is consumed")
	_check(not controller.is_placing() and not growth.has_active_task(), "Right click only exits placement")
	_check(controller.enter_placement_mode(), "Can enter again after right-click exit")
	controller.set_process(false)
	_check(controller.handle_input(_key(KEY_ESCAPE)), "Placement Escape is consumed")
	_check(not controller.is_placing() and not growth.has_active_task(), "Escape only exits placement")
	_check(controller.enter_placement_mode(), "Can enter after Escape")
	controller.set_process(false)
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, Vector2(700, 200))),
		"Invalid placement click is consumed without selecting underneath")
	_check(controller.is_placing() and not growth.has_active_task(), "Invalid click keeps placement available")
	controller.exit_placement_mode()
	_check(modes == [true, false, true, false, true, false], "Mode notifications reflect actual transitions")
	await _remove_fixture(fixture)


func _test_preview_and_connected_start() -> void:
	var fixture: Dictionary = _fixture()
	var controller: GrowthInputController = fixture["controller"]
	var network: NetworkSystem = fixture["network"]
	var core: MotherCore = fixture["core"]
	var front: HyphaNode = fixture["front"]
	var planner: GrowthPlanner = fixture["planner"]
	var growth: GrowthSystem = fixture["growth"]
	var field: FungalField = fixture["field"]
	var nodes: Node2D = fixture["nodes"]
	var edges: Node2D = fixture["edges"]
	var tips: Node2D = fixture["tips"]
	var original_nodes: Array[Node2D] = network.get_registered_nodes()
	var original_node_count: int = nodes.get_child_count()
	var original_edge_count: int = edges.get_child_count()
	var original_route: NetworkRoute = network.find_route(core, front)
	var sample_points: PackedVector2Array = PackedVector2Array([
		core.global_position, front.global_position, Vector2(700, 460), Vector2(1080, 400),
	])
	var original_coverage: Array[Node2D] = []
	for point: Vector2 in sample_points:
		original_coverage.append(field.get_collection_node(point))
	_check(controller.enter_placement_mode(), "Can preview with an empty core balance")
	controller.set_process(false)
	for point: Vector2 in sample_points.slice(2):
		var preview: Dictionary = controller.preview_at(point)
		_check(bool(preview["valid"]), "Preview accepts a new point without checking funds")
		var plan: Dictionary = preview["plan"]
		_check(plan == planner.plan(front.global_position, point, false),
			"Preview uses the shared straight-line planner and charges a new endpoint")
	var marker: GrowthTarget = _markers(fixture, true)[0]
	_check(marker.status_label.text.contains("预计营养"), "Preview displays planned nutrition cost")
	var screen_rect: Rect2 = marker.get_global_transform_with_canvas() * Rect2(
		marker.status_label.position, marker.status_label.size)
	_check(screen_rect.position.x >= 0 and screen_rect.end.x <= root.size.x,
		"Right-edge preview label remains within the viewport")
	_check(network.get_registered_nodes() == original_nodes and network.is_route_valid(original_route),
		"Preview does not register nodes or invalidate routes")
	_check(nodes.get_child_count() == original_node_count and edges.get_child_count() == original_edge_count,
		"Preview does not create mature nodes or edges")
	_check(tips.get_child_count() == 0 and not growth.has_active_task(), "Preview does not create a task or tip")
	_check(core.nutrition == 0, "Preview does not debit the core")
	field.advance(1.0)
	for index: int in sample_points.size():
		_check(field.get_collection_node(sample_points[index]) == original_coverage[index],
			"Preview leaves actual field collection ownership unchanged")
	_check(not network.get_registered_nodes().has(marker), "Ghost marker never joins the network")
	controller.exit_placement_mode()
	var middle: HyphaNode = _add_junction(fixture, Vector2(500, 460))
	var other: HyphaNode = _add_junction(fixture, Vector2(600, 460))
	_add_edge(fixture, front, middle)
	_add_edge(fixture, middle, other)
	_add_edge(fixture, other, front)
	var disconnected: HyphaNode = _add_junction(fixture, Vector2(530, 505))
	var tip: Node2D = Node2D.new()
	tips.add_child(tip)
	tip.global_position = Vector2(530, 500)
	_check(network.register_node(tip), "Fixture registers a connected temporary tip")
	_add_edge(fixture, front, tip)
	var stump: Node2D = Node2D.new()
	tips.add_child(stump)
	stump.global_position = Vector2(550, 500)
	_check(network.register_node(stump), "Fixture registers a cancelled partial endpoint")
	_add_edge(fixture, front, stump)
	var nearest: Dictionary = controller.preview_at(Vector2(530, 500))
	_check(bool(nearest["valid"]) and nearest["start_node"] == middle,
		"Chooses a connected interior junction in a loop, excluding nearer disconnected/tip nodes")
	var tie: Dictionary = controller.preview_at(Vector2(550, 500))
	var tie_start: HyphaNode = middle if middle.get_instance_id() < other.get_instance_id() else other
	_check(bool(tie["valid"]) and tie["start_node"] == tie_start,
		"Equal-distance mature starts use instance id and exclude a cancelled stump")
	_check(controller.preview_at(Vector2(220, 420))["start_node"] == core,
		"Mother core is eligible when it is the nearest connected mature start")
	for point: Vector2 in [core.global_position, middle.global_position, disconnected.global_position]:
		_check(not bool(controller.preview_at(point)["valid"]), "Rejects a coincident existing mature endpoint")
	for point: Vector2 in [Vector2(-1, 400), Vector2(1200, 400), Vector2(200, 229),
			Vector2(200, 640), Vector2(INF, 400), Vector2(NAN, 400)]:
		_check(not bool(controller.preview_at(point)["valid"]), "Rejects out-of-bounds or nonfinite coordinates")
	_check(bool(controller.preview_at(Vector2(0, 230))["valid"]), "Bounds include the top-left corner")
	_check(bool(controller.preview_at(Vector2(1199, 639))["valid"]), "Bounds include interior near bottom-right")
	network.unregister_node(core)
	_check(not bool(controller.preview_at(Vector2(700, 500))["valid"]), "Rejects placement with no core-connected start")
	await _remove_fixture(fixture)


func _test_controls_and_status() -> void:
	var fixture: Dictionary = _fixture()
	var controller: GrowthInputController = fixture["controller"]
	var growth: GrowthSystem = fixture["growth"]
	var core: MotherCore = fixture["core"]
	var network: NetworkSystem = fixture["network"]
	var observed: Array[Dictionary] = []
	controller.status_changed.connect(func(snapshot: Dictionary) -> void: observed.append(snapshot))
	_check(controller.enter_placement_mode(), "Enters placement for a real growth task")
	controller.set_process(false)
	_check(controller.place_target(Vector2(600, 400)), "Creates a target despite an empty core")
	_check(not controller.is_placing() and growth.has_active_task(), "Successful placement exits mode and starts one task")
	var snapshot: Dictionary = growth.get_task_snapshot()
	var task_id: int = int(snapshot["task_id"])
	var marker: GrowthTarget = _markers(fixture, false)[0]
	_check(task_id > 0 and marker.get_task_id() == task_id, "Marker belongs to the accepted task")
	_check(marker.get_status_snapshot() == snapshot, "Marker displays the real initial task snapshot")
	_check(not network.get_registered_nodes().has(marker), "Actual target marker is not a network node")
	_check(core.nutrition == 0, "Input acceptance does not debit nutrition")
	_check(not controller.enter_placement_mode(), "An active task rejects another placement mode")
	_check(not controller.place_target(Vector2(700, 500)), "Cannot place outside placement mode")
	_check(not bool(controller.preview_at(Vector2(700, 500))["valid"]), "Active task blocks new preview")
	_check(int(growth.get_task_snapshot()["task_id"]) == task_id, "Rejected second target retains the task id")
	growth.set_supply_wait_reason(task_id, &"combat_reserve")
	_check(marker.get_status_snapshot()["wait_reason"] == &"combat_reserve", "Supply wait reason reaches marker")
	_check(marker.status_label.text.contains("保留战斗营养"), "Wait reason is readable on the marker")
	_check(not controller.handle_input(_key(KEY_P, true)), "P echo never toggles growth")
	_check(controller.handle_input(_key(KEY_P)), "Configured P action pauses growth")
	_check(growth.get_task_snapshot()["state"] == &"paused", "Pause is committed by the growth system")
	_check(marker.get_status_snapshot()["state"] == &"paused", "Marker follows actual paused state")
	var paused_distance: float = float(growth.get_task_snapshot()["distance"])
	growth.advance(20.0)
	_check(float(growth.get_task_snapshot()["distance"]) == paused_distance, "Paused growth remains stationary")
	_check(not paused and core.process_mode != Node.PROCESS_MODE_DISABLED, "Growth pause leaves the SceneTree and core running")
	_check(controller.handle_input(_key(KEY_P)), "Second P resumes growth")
	_check(growth.get_task_snapshot()["state"] != &"paused", "Resume uses the real system state")
	_check(controller.pause_growth() and controller.resume_growth(), "Public pause/resume methods forward successfully")
	_check(controller.handle_input(_key(KEY_X)), "Configured X action cancels growth")
	_check(not growth.has_active_task() and growth.get_task_snapshot()["state"] == &"cancelled",
		"Cancel terminates the real active task")
	_check(marker.get_status_snapshot()["state"] == &"cancelled", "Marker reflects cancellation")
	_check(_markers(fixture, false).size() == 1, "Terminal marker remains visible")
	_check(controller.enter_placement_mode(), "Can enter placement after cancellation")
	controller.set_process(false)
	_check(controller.handle_input(_key(KEY_ESCAPE)), "Escape exits replacement preview")
	_check(marker.get_task_id() == task_id and marker.get_status_snapshot()["state"] == &"cancelled",
		"Exiting preview preserves the previous task marker and its status")
	_check(controller.enter_placement_mode(), "Can enter a fresh target again")
	controller.set_process(false)
	_check(controller.place_target(Vector2(800, 400)), "A new accepted task replaces the terminal marker")
	_check(_markers(fixture, false).size() == 1, "Only one live actual target marker remains")
	marker = _markers(fixture, false)[0]
	task_id = int(growth.get_task_snapshot()["task_id"])
	for step: int in range(100):
		if not growth.has_active_task():
			break
		var requested: int = growth.get_requested_nutrition(task_id)
		if requested > 0:
			_check(growth.receive_nutrition(task_id, 1000 + step, requested), "Test shipment reaches the real delivered buffer")
		growth.advance(1.0)
	snapshot = growth.get_task_snapshot()
	_check(snapshot["state"] == &"completed" and not growth.has_active_task(), "Real buffered growth reaches completion")
	_check(marker.get_status_snapshot() == snapshot and float(snapshot["progress"]) == 1.0,
		"Marker follows final state, position, costs and 100 percent progress")
	_check(not observed.is_empty() and observed.back() == snapshot, "Status signal relays the latest committed snapshot")
	_check(core.nutrition == 0, "Controller never settles supplied test nutrition against core balance")
	_check(not controller.pause_growth() and not controller.resume_growth() and not controller.cancel_growth(),
		"Terminal task controls preserve the system's rejected return values")
	await _remove_fixture(fixture)


func _test_mouse_coordinates() -> void:
	var fixture: Dictionary = _fixture()
	var controller: GrowthInputController = fixture["controller"]
	var growth: GrowthSystem = fixture["growth"]
	var original_transform: Transform2D = root.canvas_transform
	root.canvas_transform = Transform2D(Vector2(1.5, 0), Vector2(0, 1.5), Vector2(30, 45))
	var world_point: Vector2 = Vector2(700, 400)
	var screen_point: Vector2 = root.canvas_transform * world_point
	_check(controller.enter_placement_mode(), "Can place under a transformed canvas")
	controller.set_process(false)
	_check(controller.handle_input(_motion(screen_point)), "Transformed pointer preview is handled")
	var preview: GrowthTarget = _markers(fixture, true)[0]
	_check(preview.global_position.is_equal_approx(world_point), "Preview converts viewport coordinates to world coordinates")
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, screen_point)), "Transformed placement click is consumed")
	_check(not controller.is_placing() and growth.has_active_task(), "Transformed left click accepts exactly one task")
	var snapshot: Dictionary = growth.get_task_snapshot()
	var actual_point: Vector2 = snapshot["target_position"]
	_check(actual_point.is_equal_approx(world_point), "Task target uses world coordinates rather than screen coordinates")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, screen_point, false)),
		"Release after placement passes through without creating another task")
	root.canvas_transform = original_transform
	await _remove_fixture(fixture)
