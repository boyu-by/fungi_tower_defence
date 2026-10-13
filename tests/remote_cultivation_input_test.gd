extends SceneTree
## 只调用公开输入/建造接口；费用推进使用真实供养包，不伪造母核收入。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const TARGET_SCENE: PackedScene = preload("res://scenes/colony/growth_target.tscn")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_check(InputMap.has_action("remote_cultivation_mode"), "Input map defines the B remote placement action")
	_check(InputMap.has_action("cultivate_attack") and InputMap.has_action("growth_mode") \
		and InputMap.has_action("growth_pause") and InputMap.has_action("growth_cancel"),
		"Remote cultivation retains the existing C/G/P/X actions")
	await _test_mutual_exclusion_and_exit()
	await _test_quotes_and_connected_start()
	await _test_overlap_and_slot_integrity()
	await _test_phase_controls_costs_and_continuation()
	await _test_cancel_growth_and_reset()
	await _test_forward_dependency_and_mouse_coordinates()
	_check(root.get_child_count() == 0, "Remote input teardown leaves no fixture objects")
	print("REMOTE_CULTIVATION_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
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
	var packets: Node2D = Node2D.new()
	var enemies: Node2D = Node2D.new()
	var projectiles: Node2D = Node2D.new()
	for container: Node2D in [nodes, edges, tips, targets, packets, enemies, projectiles]:
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
	_check(network.register_node(core, true), "Fixture registers the real mother core")
	var fixture: Dictionary = {
		"world": world, "nodes": nodes, "edges": edges, "tips": tips, "targets": targets,
		"packets": packets, "core": core, "network": network,
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
	growth.set_physics_process(false)
	var cultivation: CultivationSystem = CultivationSystem.new()
	cultivation.network_system = network
	cultivation.growth_system = growth
	cultivation.enemy_container = enemies
	cultivation.projectile_container = projectiles
	world.add_child(cultivation)
	cultivation.set_physics_process(false)
	cultivation.set_process(false)
	growth.construction_blocker = cultivation.has_active_task
	var growth_supply: GrowthSupplySystem = GrowthSupplySystem.new()
	growth_supply.growth_system = growth
	growth_supply.mother_core = core
	growth_supply.network_system = network
	growth_supply.packet_container = packets
	growth_supply.auto_supply = false
	world.add_child(growth_supply)
	growth_supply.set_process(false)
	var cultivation_supply: CultivationSupplySystem = CultivationSupplySystem.new()
	cultivation_supply.cultivation_system = cultivation
	cultivation_supply.mother_core = core
	cultivation_supply.network_system = network
	cultivation_supply.packet_container = packets
	cultivation_supply.auto_supply = false
	world.add_child(cultivation_supply)
	cultivation_supply.set_process(false)
	var ordinary_input: GrowthInputController = GrowthInputController.new()
	ordinary_input.growth_system = growth
	ordinary_input.planner = planner
	ordinary_input.network_system = network
	ordinary_input.target_container = targets
	world.add_child(ordinary_input)
	var remote: RemoteCultivationSystem = RemoteCultivationSystem.new()
	remote.growth_system = growth
	remote.cultivation_system = cultivation
	remote.growth_supply_system = growth_supply
	remote.cultivation_supply_system = cultivation_supply
	var controller: CultivationInputController = CultivationInputController.new()
	controller.cultivation_system = cultivation
	controller.cultivation_supply_system = cultivation_supply
	controller.growth_system = growth
	controller.network_system = network
	controller.mother_core = core
	controller.remote_cultivation_system = remote
	controller.growth_input_controller = ordinary_input
	controller.target_container = targets
	if controller_first:
		world.add_child(controller)
	world.add_child(remote)
	if not controller_first:
		world.add_child(controller)
	fixture["planner"] = planner
	fixture["growth"] = growth
	fixture["cultivation"] = cultivation
	fixture["growth_supply"] = growth_supply
	fixture["cultivation_supply"] = cultivation_supply
	fixture["ordinary_input"] = ordinary_input
	fixture["remote"] = remote
	fixture["controller"] = controller
	return fixture


func _add_junction(fixture: Dictionary, point: Vector2) -> HyphaNode:
	var junction: HyphaNode = HyphaNode.new()
	var ring: Line2D = Line2D.new()
	ring.name = "SelectionRing"
	junction.add_child(ring)
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
	_check(network.register_edge(edge), "Fixture registers a real transport edge")
	return edge


func _remove_fixture(fixture: Dictionary) -> void:
	var remote: RemoteCultivationSystem = fixture["remote"]
	var growth_supply: GrowthSupplySystem = fixture["growth_supply"]
	var cultivation_supply: CultivationSupplySystem = fixture["cultivation_supply"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	remote.reset()
	growth_supply.reset()
	cultivation_supply.reset()
	cultivation.reset()
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


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


func _dispatch(fixture: Dictionary, event: InputEvent) -> bool:
	var controller: CultivationInputController = fixture["controller"]
	var ordinary: GrowthInputController = fixture["ordinary_input"]
	if controller.handle_input(event):
		return true
	return ordinary.handle_input(event)


func _markers(fixture: Dictionary, preview: bool) -> Array[GrowthTarget]:
	var markers: Array[GrowthTarget] = []
	var targets: Node2D = fixture["targets"]
	for child: Node in targets.get_children():
		if child is GrowthTarget and not child.is_queued_for_deletion() \
				and child.is_preview() == preview:
			markers.append(child)
	return markers


func _deliver_growth(fixture: Dictionary) -> void:
	var supply: GrowthSupplySystem = fixture["growth_supply"]
	var dispatched: bool = supply.try_dispatch()
	_check(dispatched, "Growth supply debits the real core and launches a packet")
	if not dispatched:
		return
	var records: Array[Dictionary] = supply.get_shipment_records()
	_deliver_packet(records.back()["packet"] as NutrientPacket)


func _deliver_cultivation(fixture: Dictionary) -> void:
	var supply: CultivationSupplySystem = fixture["cultivation_supply"]
	var dispatched: bool = supply.try_dispatch()
	_check(dispatched, "Cultivation supply debits the real core and launches a packet")
	if not dispatched:
		return
	var records: Array[Dictionary] = supply.get_shipment_records()
	_deliver_packet(records.back()["packet"] as NutrientPacket)


func _deliver_packet(packet: NutrientPacket) -> void:
	_check(is_instance_valid(packet), "Shipment owns an actual nutrient packet")
	if not is_instance_valid(packet):
		return
	packet.set_physics_process(false)
	packet._physics_process(60.0)


func _reach_cultivation(fixture: Dictionary) -> void:
	var remote: RemoteCultivationSystem = fixture["remote"]
	var growth: GrowthSystem = fixture["growth"]
	for step: int in range(128):
		if remote.get_request_snapshot().get("phase", &"") == &"cultivation":
			break
		if growth.has_active_task():
			var task_id: int = int(growth.get_task_snapshot()["task_id"])
			if growth.get_requested_nutrition(task_id) > 0:
				_deliver_growth(fixture)
			growth.advance(20.0)
		await process_frame
	_check(remote.get_request_snapshot().get("phase", &"") == &"cultivation",
		"Real growth hands the endpoint to the cultivation phase")


func _finish_cultivation(fixture: Dictionary) -> void:
	var remote: RemoteCultivationSystem = fixture["remote"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	var checked_startup: bool = false
	for step: int in range(64):
		if not remote.has_active_request():
			break
		var task_id: int = int(cultivation.get_task_snapshot().get("task_id", 0))
		if cultivation.get_requested_nutrition(task_id) > 0:
			_deliver_cultivation(fixture)
		cultivation.advance(1.0)
		var snapshot: Dictionary = remote.get_request_snapshot()
		var reserved: int = int(snapshot.get("startup_reserved", 0))
		if not checked_startup and reserved > 0:
			_check(int(snapshot.get("remaining_cost", 0)) == 4 \
				and int(snapshot.get("remaining_demand", 0)) == 4 - reserved,
				"Paid startup reserve reduces supply demand without pretending it was transferred to a mature organ")
			checked_startup = true
		await process_frame
	_check(checked_startup, "Real startup deliveries exercise the reserved-inventory accounting stage")
	_check(remote.get_request_snapshot().get("state", &"idle") == &"completed",
		"Real organ supply reaches maturation")


func _test_mutual_exclusion_and_exit() -> void:
	var fixture: Dictionary = _fixture(0)
	var controller: CultivationInputController = fixture["controller"]
	var ordinary: GrowthInputController = fixture["ordinary_input"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var growth: GrowthSystem = fixture["growth"]
	var modes: Array[bool] = []
	controller.remote_mode_changed.connect(func(placing: bool) -> void: modes.append(placing))
	_check(not controller.handle_input(null), "Null input is ignored")
	_check(not controller.handle_input(_key(KEY_B, true)), "B key echo is ignored")
	_check(not controller.handle_input(_action(&"remote_cultivation_mode", false)), "B release does not enter placement")
	_check(not controller.handle_input(_mouse(MOUSE_BUTTON_LEFT, Vector2(400, 400))),
		"Left click outside placement passes through to selection")
	_check(_dispatch(fixture, _key(KEY_G)) and ordinary.is_placing(), "G enters ordinary growth")
	ordinary.set_process(false)
	_check(_dispatch(fixture, _key(KEY_B)), "Configured B action is handled")
	controller.set_process(false)
	_check(controller.is_remote_placing() and not ordinary.is_placing(), "B exits ordinary placement before entering remote mode")
	_check(controller.enter_remote_placement_mode() and modes.size() == 1, "Public repeated enter stays idempotent")
	_check(not controller.handle_input(_key(KEY_ESCAPE, true)) and controller.is_remote_placing(),
		"Escape echo leaves remote placement intact")
	_check(_dispatch(fixture, _key(KEY_B)) and not controller.is_remote_placing(), "Second B exits remote placement")
	_check(_dispatch(fixture, _key(KEY_B)), "B can reenter after toggle exit")
	controller.set_process(false)
	_check(_dispatch(fixture, _key(KEY_G)), "G switches from remote to ordinary placement")
	ordinary.set_process(false)
	_check(ordinary.is_placing() and not controller.is_remote_placing(), "G leaves exactly one placement mode")
	_check(controller.enter_remote_placement_mode(), "Public remote entry also excludes ordinary placement")
	controller.set_process(false)
	_check(ordinary.enter_placement_mode(), "Ordinary mode can be entered directly")
	ordinary.set_process(false)
	_check(not controller.is_remote_placing(), "Ordinary mode_changed signal exits remote mode")
	_check(controller.enter_remote_placement_mode(), "Can reenter remote mode")
	controller.set_process(false)
	_check(_dispatch(fixture, _mouse(MOUSE_BUTTON_RIGHT, Vector2(700, 400))), "Right click exits remote placement")
	_check(not controller.is_remote_placing() and not remote.has_active_request() and not growth.has_active_task(),
		"Right click exits preview without starting or cancelling a build")
	_check(controller.enter_remote_placement_mode(), "Can enter after right-click exit")
	controller.set_process(false)
	_check(_dispatch(fixture, _key(KEY_ESCAPE)), "Escape exits remote placement")
	_check(not remote.has_active_request() and not growth.has_active_task(), "Escape has no construction side effect")
	_check(controller.enter_remote_placement_mode(), "Can enter for a real remote placement")
	controller.set_process(false)
	_check(_dispatch(fixture, _mouse(MOUSE_BUTTON_LEFT, Vector2(720, 400))), "Remote left click is consumed before ordinary input")
	var snapshot: Dictionary = remote.get_request_snapshot()
	_check(remote.has_active_request() and growth.has_active_task() and int(snapshot.get("request_id", 0)) > 0,
		"One click creates one remote request and its growth task")
	_check(not controller.is_remote_placing() and not ordinary.is_placing() and _markers(fixture, false).size() == 1,
		"Accepted remote placement leaves one status marker and no placement mode")
	var request_id: int = int(snapshot.get("request_id", 0))
	_dispatch(fixture, _mouse(MOUSE_BUTTON_RIGHT, Vector2(720, 400)))
	_dispatch(fixture, _key(KEY_ESCAPE))
	_check(remote.has_active_request() and int(remote.get_request_snapshot().get("request_id", 0)) == request_id,
		"Right click and Escape outside placement preserve the ongoing request")
	_check(not controller.enter_remote_placement_mode(), "Active construction blocks another remote placement")
	_check(_dispatch(fixture, _key(KEY_G)) and not ordinary.is_placing(), "G cannot create a concurrent ordinary build")
	_check(_dispatch(fixture, _key(KEY_X)) and not remote.has_active_request() and not growth.has_active_task(),
		"X cancels the current growth phase through the coordinator")
	await _remove_fixture(fixture)


func _test_quotes_and_connected_start() -> void:
	var fixture: Dictionary = _fixture(0)
	var controller: CultivationInputController = fixture["controller"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var planner: GrowthPlanner = fixture["planner"]
	var network: NetworkSystem = fixture["network"]
	var core: MotherCore = fixture["core"]
	var front: HyphaNode = fixture["front"]
	var nodes: Node2D = fixture["nodes"]
	var edges: Node2D = fixture["edges"]
	var tips: Node2D = fixture["tips"]
	var original_nodes: Array[Node2D] = network.get_registered_nodes()
	var node_count: int = nodes.get_child_count()
	var edge_count: int = edges.get_child_count()
	_check(controller.enter_remote_placement_mode(), "An empty core can preview an unfunded remote request")
	controller.set_process(false)
	var preview: Dictionary = controller.preview_remote_at(Vector2(720, 400))
	_check(bool(preview.get("valid", false)) and preview.get("start_node") == front, "Preview chooses the nearest connected mature start")
	var expected_plan: Dictionary = planner.plan(front.global_position, Vector2(720, 400), false)
	var actual_plan: Dictionary = preview.get("plan", {})
	# Stage10 annotates the same charged geometry with main-segment identity.
	for segment_index: int in range(expected_plan["segments"].size()):
		expected_plan["segments"][segment_index]["is_branch"] = false
		expected_plan["segments"][segment_index]["main_segment_index"] = segment_index
	var geometry_matches: bool = true
	for key: Variant in expected_plan:
		geometry_matches = geometry_matches and actual_plan.get(key) == expected_plan[key]
	_check(geometry_matches and actual_plan.get("join_node") == null
		and actual_plan.get("effective_point") == Vector2(720, 400),
		"Remote preview preserves exact geometry/cost and explicit target metadata")
	_check(int(preview.get("network_cost", 0)) == 16 and int(preview.get("organ_cost", 0)) == 12 \
		and int(preview.get("total_cost", 0)) == 28 and int(preview.get("remaining_cost", 0)) == 28,
		"A 320px request quotes exactly 16 network plus 12 organ nutrition")
	_check(preview == remote.preview_request(front, Vector2(720, 400)), "Input returns the coordinator quote without recalculating costs")
	var marker: GrowthTarget = _markers(fixture, true)[0]
	_check(marker.status_label.text.contains("菌路 16 + 器官 12") and marker.status_label.text.contains("总计 28") \
		and marker.status_label.text.contains("新菌结 3"), "Remote marker explains both costs and every planned new node")
	for point: Vector2 in [Vector2(560, 460), Vector2(1080, 400), Vector2(1199, 639)]:
		_check(bool(controller.preview_remote_at(point).get("valid", false)), "Preview accepts free positions independently of funds")
	_check(core.nutrition == 0 and network.get_registered_nodes() == original_nodes,
		"Preview neither debits the core nor registers network objects")
	_check(nodes.get_child_count() == node_count and edges.get_child_count() == edge_count and tips.get_child_count() == 0,
		"Preview does not construct nodes, edges, or growth tips")
	var growth_supply: GrowthSupplySystem = fixture["growth_supply"]
	var cultivation_supply: CultivationSupplySystem = fixture["cultivation_supply"]
	_check(not remote.has_active_request() and growth_supply.get_shipment_records().is_empty() \
		and cultivation_supply.get_shipment_records().is_empty(), "Preview does not launch either type of supply packet")
	_check(not network.get_registered_nodes().has(marker), "Preview marker never becomes a mature start")
	controller.exit_remote_placement_mode()
	var middle: HyphaNode = _add_junction(fixture, Vector2(500, 460))
	var other: HyphaNode = _add_junction(fixture, Vector2(600, 460))
	_add_edge(fixture, front, middle)
	_add_edge(fixture, middle, other)
	_add_edge(fixture, other, front)
	var disconnected: HyphaNode = _add_junction(fixture, Vector2(530, 526))
	var temporary: Node2D = Node2D.new()
	tips.add_child(temporary)
	temporary.global_position = Vector2(530, 500)
	_check(network.register_node(temporary), "Fixture registers a temporary tip")
	_add_edge(fixture, front, temporary)
	var stump: Node2D = Node2D.new()
	tips.add_child(stump)
	stump.global_position = Vector2(550, 500)
	_check(network.register_node(stump), "Fixture registers a cancelled partial endpoint")
	_add_edge(fixture, front, stump)
	controller.select_node(front)
	preview = controller.preview_remote_at(Vector2(530, 500))
	_check(bool(preview.get("valid", false)) and preview.get("start_node") == middle,
		"Nearest connected interior node wins over selection, a disconnected node, and a temporary tip")
	var tie_start: HyphaNode = middle if middle.get_instance_id() < other.get_instance_id() else other
	preview = controller.preview_remote_at(Vector2(550, 500))
	_check(bool(preview.get("valid", false)) and preview.get("start_node") == tie_start,
		"Tied mature starts use instance identity while excluding a coincident stump")
	_check(controller.preview_remote_at(Vector2(260, 400)).get("start_node") == core,
		"Connected mother core can be the nearest mature start")
	for point: Vector2 in [core.global_position, middle.global_position, disconnected.global_position]:
		_check(not bool(controller.preview_remote_at(point).get("valid", false)), "Existing mature endpoints cannot be bypassed by remote placement")
	for point: Vector2 in [Vector2(-1, 400), Vector2(1200, 400), Vector2(200, 229), Vector2(200, 640),
			Vector2(INF, 400), Vector2(NAN, 400)]:
		_check(not bool(controller.preview_remote_at(point).get("valid", false)), "Remote preview rejects invalid bounds or coordinates")
	_check(bool(controller.preview_remote_at(Vector2(0, 230)).get("valid", false)), "Remote bounds include their top-left corner")
	core.health = 0
	_check(not bool(controller.preview_remote_at(Vector2(720, 400)).get("valid", false)), "A depleted core cannot be a remote construction source")
	core.health = core.max_health
	network.unregister_node(core)
	_check(not bool(controller.preview_remote_at(Vector2(720, 400)).get("valid", false)), "Remote preview rejects a network with no connected core")
	await _remove_fixture(fixture)


func _test_overlap_and_slot_integrity() -> void:
	var fixture: Dictionary = _fixture()
	var controller: CultivationInputController = fixture["controller"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var front: HyphaNode = fixture["front"]
	var core: MotherCore = fixture["core"]
	_check(controller.enter_remote_placement_mode(), "Can test overlap in remote placement")
	controller.set_process(false)
	for point: Vector2 in [front.global_position, front.global_position + Vector2(24, 0), core.global_position]:
		var preview: Dictionary = controller.preview_remote_at(point)
		_check(not bool(preview.get("valid", false)) and String(preview.get("error", "")).contains("按 C"),
			"Existing empty node or core overlap explains selection plus C")
		_check(not controller.place_remote_target(point), "Overlap refuses placement without accepting a request")
	_check(front.get_organ_slot_state() == &"empty" and front.is_organ_slot_available(),
		"Refused overlap never reserves the empty organ slot")
	_check(bool(controller.preview_remote_at(front.global_position + Vector2(25, 0)).get("valid", false)),
		"A position outside the 24px boundary remains placeable")
	var occupant: AttackOrgan = ATTACK_SCENE.instantiate() as AttackOrgan
	front.add_child(occupant)
	occupant.position = Vector2(60, 0)
	var near_organ: Vector2 = occupant.global_position + Vector2(10, 0)
	_check(not bool(controller.preview_remote_at(near_organ).get("valid", false)) \
		and not controller.place_remote_target(near_organ), "Offset occupied organ rejects nearby placement too")
	_check(front.get_organ_occupant() == occupant and front.get_organ_slot_state() == &"attack" \
		and front.get_organ_bud() == null, "Occupied organ and slot survive every refused request")
	_check(not bool(remote.preview_request(front, front.global_position).get("valid", false)) \
		and remote.request_remote(front, front.global_position) == 0, "Coordinator independently refuses existing endpoints")
	_check(not remote.has_active_request() and core.nutrition == 64, "Overlap failures create no task or debit")
	controller.exit_remote_placement_mode()
	await _remove_fixture(fixture)


func _test_phase_controls_costs_and_continuation() -> void:
	var fixture: Dictionary = _fixture()
	var controller: CultivationInputController = fixture["controller"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var growth: GrowthSystem = fixture["growth"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	var network: NetworkSystem = fixture["network"]
	var core: MotherCore = fixture["core"]
	var observed: Array[Dictionary] = []
	var phases: Array[StringName] = []
	controller.status_changed.connect(func(snapshot: Dictionary) -> void: observed.append(snapshot))
	remote.request_changed.connect(func(snapshot: Dictionary) -> void: phases.append(StringName(snapshot.get("phase", &""))))
	_check(controller.enter_remote_placement_mode(), "Can enter for a funded remote request")
	controller.set_process(false)
	_check(controller.place_remote_target(Vector2(720, 400)), "Input accepts a remote request")
	var snapshot: Dictionary = remote.get_request_snapshot()
	var request_id: int = int(snapshot.get("request_id", 0))
	var growth_task_id: int = int(snapshot.get("growth_task_id", 0))
	_check(snapshot.get("phase") == &"growth" and snapshot.get("state") == &"waiting" \
		and int(snapshot.get("task_id", 0)) == request_id and snapshot.get("endpoint") == null,
		"Initial unified status distinguishes the request and growth phase")
	_check(int(snapshot.get("network_cost", 0)) == 16 and int(snapshot.get("organ_cost", 0)) == 12 \
		and int(snapshot.get("total_cost", 0)) == 28 and core.nutrition == 64,
		"Acceptance commits the quoted cost without direct debit")
	_check(not observed.is_empty() and observed.back() == snapshot, "Existing status signal relays the unified remote snapshot")
	var marker: GrowthTarget = _markers(fixture, false)[0]
	_check(marker.get_task_id() == request_id and marker.get_status_snapshot() == snapshot,
		"Remote status marker owns the request identity")
	growth.set_supply_wait_reason(growth_task_id, &"combat_reserve")
	controller.refresh()
	_check(marker.status_label.text.contains("保留战斗营养"), "Current phase waiting reason reaches the remote marker")
	_check(not controller.handle_input(_key(KEY_P, true)), "P echo cannot toggle remote phase control")
	_check(_dispatch(fixture, _key(KEY_P)), "P pauses the remote growth phase once")
	_check(remote.get_request_snapshot().get("state") == &"paused" and growth.get_task_snapshot().get("state") == &"paused",
		"Growth pause is committed by the coordinator and stage system")
	var distance: float = float(growth.get_task_snapshot().get("distance", 0.0))
	growth.advance(20.0)
	_check(float(growth.get_task_snapshot().get("distance", 0.0)) == distance and not paused \
		and core.process_mode != Node.PROCESS_MODE_DISABLED, "Phase pause leaves the world running and the tip stationary")
	_check(_dispatch(fixture, _key(KEY_P)), "Second P resumes the growth phase")
	await _reach_cultivation(fixture)
	snapshot = remote.get_request_snapshot()
	var endpoint: HyphaNode = snapshot.get("endpoint") as HyphaNode
	_check(is_instance_valid(endpoint), "Coordinator exposes the actual mature endpoint")
	if not is_instance_valid(endpoint):
		await _remove_fixture(fixture)
		return
	_check(snapshot.get("phase") == &"cultivation" and snapshot.get("state") != &"completed",
		"Connection alone does not mark a remote organ complete")
	_check(phases.has(&"connected") and phases.has(&"cultivation"), "Unified state reports the handoff before cultivation")
	_check(cultivation.get_task_snapshot().get("host") == endpoint and endpoint.get_organ_slot_state() == &"bud",
		"Cultivation owns the exact completed endpoint and one bud slot")
	_check(network.is_connected_to_core(endpoint) and core.nutrition == 48 \
		and int(snapshot.get("growth_consumed", 0)) == 16 and int(snapshot.get("remaining_cost", 0)) == 12,
		"Connection preserves paid network cost and all twelve organ nutrition remain")
	_check(marker.get_status_snapshot() == snapshot and marker.status_label.text.contains("培育攻击芽") \
		and marker.status_label.text.contains("已投入 16") and marker.status_label.text.contains("尚需 12"),
		"Marker follows phase, invested nutrition, and remaining cost")
	var original_cultivation_id: int = int(snapshot.get("cultivation_task_id", 0))
	_deliver_cultivation(fixture)
	snapshot = remote.get_request_snapshot()
	_check(int(snapshot.get("remaining_cost", 0)) == 12 and int(snapshot.get("buffered_nutrition", 0)) == 1 \
		and int(snapshot.get("remaining_demand", 0)) == 11,
		"A paid delivered buffer lowers demand while leaving unconsumed organ cost visible")
	cultivation.advance(0.4)
	var structure: int = int(remote.get_request_snapshot().get("structure_consumed", 0))
	_check(structure > 0, "Delivered organ nutrition pays real structure")
	controller.select_node(endpoint)
	var selection: Dictionary = controller.get_selection_status()
	_check(bool(selection.get("can_pause", false)) and bool(selection.get("can_cancel", false)),
		"Selection controls describe the active remote cultivation phase")
	_check(_dispatch(fixture, _key(KEY_P)), "P pauses the remote cultivation phase")
	var effective_time: float = float(cultivation.get_task_snapshot().get("effective_time", 0.0))
	cultivation.advance(20.0)
	_check(cultivation.get_task_snapshot().get("state") == &"paused" \
		and float(cultivation.get_task_snapshot().get("effective_time", 0.0)) == effective_time,
		"Cultivation pause retains its paid stage and effective time")
	_check(controller.resume_cultivation(), "Public resume routes to the remote cultivation phase")
	_check(controller.pause_cultivation() and controller.resume_cultivation(), "Public pause/resume wrappers control the current remote stage")
	_check(_dispatch(fixture, _key(KEY_X)), "X cancels the remote cultivation phase")
	snapshot = remote.get_request_snapshot()
	_check(snapshot.get("state") == &"cancelled" and snapshot.get("phase") == &"cultivation" \
		and endpoint.get_organ_bud() != null, "Cultivation cancellation retains the paid bud and phase")
	_check(int(snapshot.get("growth_consumed", 0)) == 16 and int(snapshot.get("structure_consumed", 0)) == structure,
		"Cancellation preserves network and paid organ structure")
	var balance: int = core.nutrition
	var registered_count: int = network.get_registered_nodes().size()
	_check(_dispatch(fixture, _key(KEY_C)), "Selection plus C continues a matching cancelled remote bud")
	snapshot = remote.get_request_snapshot()
	_check(int(snapshot.get("request_id", 0)) > request_id \
		and int(snapshot.get("cultivation_task_id", 0)) > original_cultivation_id \
		and int(snapshot.get("growth_task_id", 0)) == growth_task_id,
		"Continue allocates new request/cultivation identities while preserving the paid growth task")
	_check(snapshot.get("endpoint") == endpoint and int(snapshot.get("structure_consumed", 0)) == structure \
		and core.nutrition == balance and network.get_registered_nodes().size() == registered_count,
		"Continue preserves exact endpoint, paid structure, network, and core funds")
	_check(_markers(fixture, false).size() == 1 \
		and _markers(fixture, false)[0].get_task_id() == int(snapshot.get("request_id", 0)),
		"Continue replaces the terminal marker with one current request marker")
	await _finish_cultivation(fixture)
	snapshot = remote.get_request_snapshot()
	_check(snapshot.get("state") == &"completed" and float(snapshot.get("progress", 0.0)) == 1.0 \
		and endpoint.get_organ_slot_state() == &"attack" and endpoint.get_organ_bud() == null,
		"Completed remote request means a mature attack organ")
	_check(int(snapshot.get("growth_consumed", 0)) == 16 and int(snapshot.get("structure_consumed", 0)) == 8 \
		and int(snapshot.get("startup_transferred", 0)) == 4 and int(snapshot.get("consumed_nutrition", 0)) == 28 \
		and int(snapshot.get("remaining_cost", -1)) == 0 and int(snapshot.get("remaining_demand", -1)) == 0,
		"Final unified accounting splits all sixteen plus eight plus four paid nutrition")
	_check(core.nutrition == 36, "The real core pays the quoted twenty-eight exactly once across continuation")
	marker = _markers(fixture, false)[0]
	_check(marker.get_status_snapshot() == snapshot and marker.status_label.text.contains("已成熟"),
		"Marker follows the latest mature snapshot")
	_check(marker.status_label.text.contains("已转入库存 4") \
		and not marker.status_label.text.contains("启动库存 0"),
		"Mature marker reports paid startup inventory transferred into the organ")
	_check(not observed.is_empty() and observed.back() == snapshot, "Existing status signal retains the terminal remote status")
	controller.select_node(fixture["front"] as HyphaNode)
	_check(controller.request_cultivation(), "Original selected-node cultivation still works after a remote completion")
	_check(observed.back() == cultivation.get_task_snapshot() and not observed.back().has("request_id"),
		"A new ordinary cultivation task restores the original status payload")
	await _remove_fixture(fixture)


func _test_cancel_growth_and_reset() -> void:
	var fixture: Dictionary = _fixture()
	var controller: CultivationInputController = fixture["controller"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var growth: GrowthSystem = fixture["growth"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	var front: HyphaNode = fixture["front"]
	_check(controller.enter_remote_placement_mode() and controller.place_remote_target(Vector2(720, 400)),
		"Can start a remote request to cancel during growth")
	_deliver_growth(fixture)
	_deliver_growth(fixture)
	growth.advance(1.0)
	_check(controller.cancel_cultivation(), "Public cancel routes to the active remote growth stage")
	var snapshot: Dictionary = remote.get_request_snapshot()
	var old_request_id: int = int(snapshot.get("request_id", 0))
	_check(snapshot.get("state") == &"cancelled" and snapshot.get("phase") == &"growth" \
		and snapshot.get("endpoint") == null and not cultivation.has_active_task() \
		and front.get_organ_slot_state() == &"empty", "Cancelling an unfinished route never creates a bud or endpoint slot")
	_check(remote.continue_request() == 0, "Cancelled growth requires a new placement instead of bud continuation")
	_check(controller.enter_remote_placement_mode(), "Cancelled growth permits a replacement preview")
	controller.set_process(false)
	var marker: GrowthTarget = _markers(fixture, false)[0]
	_check(controller.handle_input(_mouse(MOUSE_BUTTON_RIGHT, Vector2.ZERO)), "Right click can exit replacement preview")
	_check(marker.get_task_id() == old_request_id and marker.get_status_snapshot().get("state") == &"cancelled",
		"Exiting replacement preview preserves the cancelled request marker")
	_check(controller.enter_remote_placement_mode() and controller.place_remote_target(Vector2(740, 450)),
		"A replacement point can create a fresh remote request")
	snapshot = remote.get_request_snapshot()
	_check(int(snapshot.get("request_id", 0)) > old_request_id and remote.has_active_request(),
		"Replacement allocates a new request identity")
	remote.reset()
	controller.refresh()
	_check(int(remote.get_request_snapshot().get("request_id", 0)) == 0 and _markers(fixture, false).is_empty(),
		"Coordinator reset removes the remote request marker")
	remote.request_changed.emit(snapshot)
	_check(_markers(fixture, false).is_empty() and not remote.has_active_request(),
		"Late request notification cannot recreate a reset marker or request")
	await _remove_fixture(fixture)


func _test_forward_dependency_and_mouse_coordinates() -> void:
	var fixture: Dictionary = _fixture(0, true)
	var controller: CultivationInputController = fixture["controller"]
	var remote: RemoteCultivationSystem = fixture["remote"]
	var growth: GrowthSystem = fixture["growth"]
	var observed: Array[Dictionary] = []
	controller.status_changed.connect(func(snapshot: Dictionary) -> void: observed.append(snapshot))
	await process_frame
	_check(controller.enter_remote_placement_mode(), "Forward-referenced remote system binds after entering the tree")
	controller.set_process(false)
	var original_transform: Transform2D = root.canvas_transform
	root.canvas_transform = Transform2D(Vector2(1.5, 0), Vector2(0, 1.5), Vector2(30, 45))
	var world_point: Vector2 = Vector2(720, 400)
	var screen_point: Vector2 = root.canvas_transform * world_point
	_check(_dispatch(fixture, _motion(screen_point)), "Remote pointer motion is handled under a transformed canvas")
	var preview: GrowthTarget = _markers(fixture, true)[0]
	_check(preview.global_position.is_equal_approx(world_point), "Remote preview converts viewport coordinates to world coordinates")
	var label_rect: Rect2 = preview.get_global_transform_with_canvas() * Rect2(preview.status_label.position, preview.status_label.size)
	_check(label_rect.position.x >= 0 and label_rect.end.x <= root.size.x, "Remote cost label stays within the right viewport boundary")
	_check(_dispatch(fixture, _mouse(MOUSE_BUTTON_LEFT, screen_point)), "Transformed remote click is consumed once")
	var snapshot: Dictionary = remote.get_request_snapshot()
	var target_position: Vector2 = snapshot.get("target_position", Vector2.ZERO)
	_check(target_position.is_equal_approx(world_point) and growth.has_active_task(),
		"Remote task uses world coordinates and owns one actual growth task")
	_check(not observed.is_empty() and observed.back() == snapshot, "Forward reference receives coordinator status notifications")
	_check(not _dispatch(fixture, _mouse(MOUSE_BUTTON_LEFT, screen_point, false)), "Release after acceptance cannot create a second request")
	root.canvas_transform = original_transform
	var ordinary_marker: GrowthTarget = TARGET_SCENE.instantiate() as GrowthTarget
	var targets: Node2D = fixture["targets"]
	targets.add_child(ordinary_marker)
	var planner: GrowthPlanner = fixture["planner"]
	var front: HyphaNode = fixture["front"]
	ordinary_marker.show_preview({
		"valid": true, "target_position": Vector2(900, 400),
		"plan": planner.plan(front.global_position, Vector2(900, 400), false),
	})
	_check(ordinary_marker.status_label.text.contains("预计营养") \
		and not ordinary_marker.status_label.text.contains("远程攻击芽"), "Ordinary growth keeps its original preview label")
	ordinary_marker.show_status(growth.get_task_snapshot())
	_check(ordinary_marker.get_task_id() == int(growth.get_task_snapshot().get("task_id", 0)) \
		and ordinary_marker.status_label.text.contains("生长 #"), "Ordinary marker keeps growth task identity and status text")
	await _remove_fixture(fixture)
