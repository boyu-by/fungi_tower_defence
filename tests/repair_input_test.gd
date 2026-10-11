extends SceneTree
## 维修控制器的独立输入夹具；不启动施工，不注入维修营养，不依赖全局输入处理器。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_test_actions()
	_test_configuration_guard()
	_test_line_selection_and_preview()
	_test_task_controls_and_selection_exit()
	_test_stale_selection()
	await _test_no_duplicate_global_handler()
	_check(root.get_child_count() == 0, "All isolated repair input fixtures are removed")
	print("REPAIR_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _test_actions() -> void:
	var bindings: Dictionary = {
		"repair_mode": KEY_F, "repair_request": KEY_J,
		"repair_pause": KEY_K, "repair_cancel": KEY_BACKSPACE,
	}
	for action: String in bindings:
		_check(InputMap.has_action(action), "Formal input map declares " + action)
		if not InputMap.has_action(action):
			continue
		var matched: bool = false
		for event: InputEvent in InputMap.action_get_events(action):
			if event is InputEventKey:
				matched = matched or event.keycode == bindings[action] \
					or event.physical_keycode == bindings[action]
		_check(matched, "Formal repair binding retains its assigned key: " + action)


func _fixture() -> Dictionary:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	var core: MotherCore = CORE_SCENE.instantiate() as MotherCore
	world.add_child(core)
	core.global_position = Vector2(100, 400)
	var first: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	world.add_child(first)
	first.global_position = Vector2(300, 400)
	var second: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	world.add_child(second)
	second.global_position = Vector2(500, 400)
	var network: NetworkSystem = NetworkSystem.new()
	world.add_child(network)
	network.register_node(core, true)
	network.register_node(first)
	network.register_node(second)
	var feed: HyphaEdge = _edge(world, network, core, first)
	var target: HyphaEdge = _edge(world, network, first, second)
	# 故意偏移边的 Node2D；命中检测必须看真实端点，不能看边原点。
	target.position = Vector2(-900, -900)
	var packets: Node2D = Node2D.new()
	world.add_child(packets)
	var traffic: NetworkTrafficSystem = NetworkTrafficSystem.new()
	traffic.network_system = network
	world.add_child(traffic)
	traffic.set_process(false)
	var repair: RepairSystem = RepairSystem.new()
	repair.network_system = network
	world.add_child(repair)
	repair.set_physics_process(false)
	repair.set_process(false)
	var supply: RepairSupplySystem = RepairSupplySystem.new()
	supply.repair_system = repair
	supply.mother_core = core
	supply.network_system = network
	supply.traffic_system = traffic
	supply.packet_container = packets
	supply.auto_supply = false
	world.add_child(supply)
	supply.set_process(false)
	var controller: RepairInputController = RepairInputController.new()
	controller.repair_system = repair
	controller.repair_supply_system = supply
	controller.network_system = network
	world.add_child(controller)
	return {
		"world": world, "core": core, "first": first, "second": second,
		"network": network, "traffic": traffic, "feed": feed, "target": target,
		"repair": repair, "supply": supply, "controller": controller,
	}


func _edge(world: Node2D, network: NetworkSystem, first: Node2D, second: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	world.add_child(edge)
	network.register_edge(edge)
	return edge


func _dispose(fixture: Dictionary) -> void:
	var world: Node2D = fixture["world"] as Node2D
	world.free()


func _action(action: StringName) -> InputEventAction:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = true
	return event


func _test_configuration_guard() -> void:
	var controller: RepairInputController = RepairInputController.new()
	root.add_child(controller)
	_check(not controller.enter_selection_mode() and not controller.is_selecting(),
		"Missing repair configuration fails without entering selection")
	_check(controller.request_repair() == 0 and not controller.toggle_pause()
		and not controller.cancel_repair(), "Unconfigured commands safely reject operation")
	controller.free()


func _test_line_selection_and_preview() -> void:
	var fixture: Dictionary = _fixture()
	var controller: RepairInputController = fixture["controller"] as RepairInputController
	var target: HyphaEdge = fixture["target"] as HyphaEdge
	var repair: RepairSystem = fixture["repair"] as RepairSystem
	var core: MotherCore = fixture["core"] as MotherCore
	var network: NetworkSystem = fixture["network"] as NetworkSystem
	var selections: Array[HyphaEdge] = []
	controller.selection_changed.connect(func(edge: HyphaEdge) -> void:
		selections.append(edge))
	_check(not controller.select_edge(target), "Selecting an edge requires entering the selection mode")
	_check(controller.enter_selection_mode(), "Configured selection mode opens independently of construction")
	_check(not controller.select_at(Vector2(400, 100))
		and not controller.select_at(Vector2(400, 450))
		and not controller.select_at(Vector2(NAN, 400)),
		"Bounds, distance from actual line, and nonfinite coordinates reject picks")
	_check(controller.select_at(Vector2(400, 412)) and controller.get_selected_edge() == target,
		"Actual world line is selectable despite a displaced edge origin")
	_check(not bool(controller.get_preview()["valid"]) and controller.request_repair() == 0,
		"Healthy edge is selectable for its health display but cannot create a repair")
	target.take_damage(10.25)
	var balance: int = core.nutrition
	var health: float = target.health
	var topology: Dictionary = network.get_topology_snapshot()
	for _read: int in range(5):
		var preview: Dictionary = controller.get_preview()
		_check(bool(preview.get("valid", false)) and int(preview.get("estimated_cost", 0)) == 2
			and is_equal_approx(float(preview.get("health", 0.0)), 24.75)
			and preview.get("repair_point") == fixture["first"] and bool(preview.get("supply_reachable", false)),
			"Preview exposes authoritative HP, ceiling price, and reachable work point")
		preview["health"] = -100.0
		preview["estimated_cost"] = 999
	_check(core.nutrition == balance and target.health == health and not repair.has_active_task()
		and network.get_topology_snapshot() == topology,
		"Selection and repeated snapshot reads never charge, heal, or change topology")
	var duplicate: HyphaEdge = _edge(fixture["world"], network, fixture["first"], fixture["second"])
	var expected: HyphaEdge = target if target.get_instance_id() < duplicate.get_instance_id() else duplicate
	for _pick: int in range(4):
		_check(controller.select_at(Vector2(400, 400)) and controller.get_selected_edge() == expected,
			"Coincident segments use deterministic instance identity tie breaking")
	var fake: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	fake.start_node = fixture["first"]
	fake.end_node = fixture["second"]
	(fixture["world"] as Node2D).add_child(fake)
	_check(not controller.select_edge(fake), "An unregistered visual edge cannot be submitted for repair")
	_check(not selections.is_empty(), "Accepted selection publishes the exact selected edge identity")
	_dispose(fixture)


func _test_task_controls_and_selection_exit() -> void:
	var fixture: Dictionary = _fixture()
	var controller: RepairInputController = fixture["controller"] as RepairInputController
	var repair: RepairSystem = fixture["repair"] as RepairSystem
	var target: HyphaEdge = fixture["target"] as HyphaEdge
	var core: MotherCore = fixture["core"] as MotherCore
	target.take_damage(35.0)
	var original_balance: int = core.nutrition
	_check(controller.handle_input(_action(&"repair_mode")) and controller.is_selecting(),
		"F enters the selection mode through the explicit handle_input entry point")
	_check(controller.select_edge(target), "A broken edge remains selectable")
	_check(controller.handle_input(_action(&"repair_request")) and repair.has_active_task(),
		"J submits an independent repair task")
	var task_id: int = int(repair.get_task_snapshot()["task_id"])
	_check(core.nutrition == original_balance and target.health == 0.0,
		"Confirming a repair does not deduct nutrition or freely reopen the edge")
	_check(controller.request_repair() == 0 and int(repair.get_task_snapshot()["task_id"]) == task_id,
		"A second confirmation cannot replace the active task")
	_check(controller.handle_input(_action(&"cancel_selection")) and not controller.is_selecting()
		and repair.has_active_task() and controller.get_selected_edge() == target,
		"Esc exits selection and retains both confirmed task and selected marker")
	controller.enter_selection_mode()
	var right: InputEventMouseButton = InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	_check(controller.handle_input(right) and not controller.is_selecting() and repair.has_active_task(),
		"Right click exits selection without cancelling a confirmed task")
	_check(controller.handle_input(_action(&"repair_pause"))
		and repair.get_task_snapshot()["state"] == &"paused", "K pauses repair outside selection mode")
	_check(controller.toggle_pause() and repair.get_task_snapshot()["state"] != &"paused",
		"The same repair operation resumes its original task")
	for action: StringName in [&"pause_growth", &"cancel_growth", &"growth_mode", &"connection_mode",
			&"cultivate_organ", &"remote_cultivation_mode"]:
		if InputMap.has_action(action):
			_check(not controller.handle_input(_action(action)), "Repair controller leaves construction input to level: " + action)
	var echo: InputEventKey = InputEventKey.new()
	echo.keycode = KEY_K
	echo.physical_keycode = KEY_K
	echo.pressed = true
	echo.echo = true
	_check(not controller.handle_input(echo) and repair.get_task_snapshot()["state"] != &"paused",
		"Echo events cannot repeatedly toggle task pause")
	_check(controller.handle_input(_action(&"repair_cancel")) and not repair.has_active_task()
		and repair.get_task_snapshot()["state"] == &"cancelled", "Backspace alone explicitly cancels repair")
	_check(not controller.cancel_repair() and core.nutrition == original_balance and target.health == 0.0,
		"Repeated cancellation cannot charge, heal, or refund unpaid nutrition")
	_dispose(fixture)


func _test_stale_selection() -> void:
	var fixture: Dictionary = _fixture()
	var controller: RepairInputController = fixture["controller"] as RepairInputController
	var target: HyphaEdge = fixture["target"] as HyphaEdge
	var network: NetworkSystem = fixture["network"] as NetworkSystem
	controller.enter_selection_mode()
	controller.select_edge(target)
	network.unregister_edge(target)
	_check(controller.get_selected_edge() == null and controller.request_repair() == 0,
		"Unregistering a selected edge clears its identity and prevents stale submission")
	network.register_edge(target)
	controller.select_edge(target)
	target.free()
	_check(controller.get_selected_edge() == null and controller.get_preview().get("edge") == null,
		"Removing a selected edge leaves no freed reference in the UI snapshot")
	_dispose(fixture)


func _test_no_duplicate_global_handler() -> void:
	var fixture: Dictionary = _fixture()
	var controller: RepairInputController = fixture["controller"] as RepairInputController
	var event: InputEventKey = InputEventKey.new()
	event.keycode = KEY_F
	event.physical_keycode = KEY_F
	event.pressed = true
	root.push_input(event)
	var released: InputEventKey = event.duplicate() as InputEventKey
	released.pressed = false
	root.push_input(released)
	await process_frame
	_check(not controller.is_selecting(), "A controller alone has no duplicate global input handler")
	_check(controller.handle_input(event) and controller.is_selecting(),
		"The owning level can forward the same input exactly once")
	_dispose(fixture)
