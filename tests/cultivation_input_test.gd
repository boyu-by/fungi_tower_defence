extends SceneTree
## 只调用公开选择/培育接口；真实营养包由隔离夹具显式推进，不伪造母核收入。

const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_check(InputMap.has_action("cultivate_attack"), "Input map defines cultivate_attack")
	_check(InputMap.has_action("growth_mode") and InputMap.has_action("growth_pause") \
		and InputMap.has_action("growth_cancel"), "Cultivation shares the existing G/P/X actions")
	await _test_selection_eligibility()
	await _test_low_funds_and_controls()
	await _test_paid_cancel_and_continue()
	await _test_selected_host_removal()
	_check(root.get_child_count() == 0, "Input teardown leaves no fixture objects")
	print("CULTIVATION_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture(initial_nutrition: int = 24) -> Dictionary:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	var nodes: Node2D = Node2D.new()
	var edges: Node2D = Node2D.new()
	var tips: Node2D = Node2D.new()
	var packets: Node2D = Node2D.new()
	var enemies: Node2D = Node2D.new()
	var projectiles: Node2D = Node2D.new()
	for container: Node2D in [nodes, edges, tips, packets, enemies, projectiles]:
		world.add_child(container)
	var core: MotherCore = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	core.add_child(health_bar)
	core.position = Vector2(100, 400)
	core.initial_nutrition = initial_nutrition
	world.add_child(core)
	var network: NetworkSystem = NetworkSystem.new()
	world.add_child(network)
	_check(network.register_node(core, true), "Fixture registers the live mother core")
	var fixture: Dictionary = {
		"world": world, "nodes": nodes, "edges": edges, "tips": tips,
		"packets": packets, "core": core, "network": network,
	}
	var host: HyphaNode = _add_host(fixture, Vector2(140, 400))
	var other: HyphaNode = _add_host(fixture, Vector2(180, 400))
	_add_edge(fixture, core, host)
	_add_edge(fixture, core, other)
	fixture["host"] = host
	fixture["other"] = other
	fixture["disconnected"] = _add_host(fixture, Vector2(240, 400))
	var growth: GrowthSystem = GrowthSystem.new()
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
	var supply: CultivationSupplySystem = CultivationSupplySystem.new()
	supply.cultivation_system = cultivation
	supply.mother_core = core
	supply.network_system = network
	supply.packet_container = packets
	supply.auto_supply = false
	world.add_child(supply)
	supply.set_process(false)
	var controller: CultivationInputController = CultivationInputController.new()
	controller.cultivation_system = cultivation
	controller.cultivation_supply_system = supply
	controller.growth_system = growth
	controller.network_system = network
	controller.mother_core = core
	world.add_child(controller)
	fixture["growth"] = growth
	fixture["cultivation"] = cultivation
	fixture["supply"] = supply
	fixture["controller"] = controller
	return fixture


func _add_host(fixture: Dictionary, point: Vector2) -> HyphaNode:
	var host: HyphaNode = HyphaNode.new()
	var ring: Line2D = Line2D.new()
	ring.name = "SelectionRing"
	host.add_child(ring)
	var nodes: Node2D = fixture["nodes"]
	nodes.add_child(host)
	host.global_position = point
	var network: NetworkSystem = fixture["network"]
	_check(network.register_node(host), "Fixture registers a mature HyphaNode")
	return host


func _add_edge(fixture: Dictionary, start: Node2D, end: Node2D) -> void:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	var edges: Node2D = fixture["edges"]
	edges.add_child(edge)
	var network: NetworkSystem = fixture["network"]
	_check(network.register_edge(edge), "Fixture registers a real transport edge")


func _remove_fixture(fixture: Dictionary) -> void:
	var supply: CultivationSupplySystem = fixture["supply"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	supply.reset()
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


func _dispatch_and_deliver(supply: CultivationSupplySystem) -> void:
	var dispatched: bool = supply.try_dispatch()
	_check(dispatched, "Real cultivation supply debits and launches a packet")
	if not dispatched:
		return
	var records: Array[Dictionary] = supply.get_shipment_records()
	var packet: NutrientPacket = records.back()["packet"] as NutrientPacket
	_check(is_instance_valid(packet), "Shipment owns the actual NutrientPacket")
	if not is_instance_valid(packet):
		return
	packet.set_physics_process(false)
	packet._physics_process(10.0)


func _arrival_callbacks(packet: NutrientPacket) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(&"arrived"):
		callbacks.append(connection["callable"])
	return callbacks


func _test_selection_eligibility() -> void:
	var fixture: Dictionary = _fixture()
	var controller: CultivationInputController = fixture["controller"]
	var growth: GrowthSystem = fixture["growth"]
	var host: HyphaNode = fixture["host"]
	var other: HyphaNode = fixture["other"]
	var disconnected: HyphaNode = fixture["disconnected"]
	var status: Dictionary = controller.get_selection_status()
	_check(status.reason == &"no_selection" and status.message.contains("选择"),
		"No selection has a clear Chinese eligibility message")
	_check(not controller.request_cultivation(), "No selection cannot create cultivation")
	controller.select_node(host)
	status = controller.get_selection_status()
	_check(status.reason == &"ready" and status.can_cultivate and not status.can_continue,
		"Connected empty mature node can start ordinary attack cultivation")
	_check(status.total_cost == 12 and status.remaining_cost == 12 and status.available_nutrition == 24,
		"Selection quotes real available funds and the exact 8+4 fee")
	var core: MotherCore = fixture["core"]
	core.health = 0
	status = controller.get_selection_status()
	_check(status.reason == &"disconnected" and not status.can_cultivate,
		"A depleted mother core cannot advertise an eligible cultivation host")
	_check(not controller.request_cultivation(), "Depleted core blocks requests without creating a bud")
	core.health = core.max_health
	var occupant: AttackOrgan = ATTACK_SCENE.instantiate() as AttackOrgan
	host.add_child(occupant)
	status = controller.get_selection_status()
	_check(status.reason == &"occupied" and status.message.contains("占用") and not status.can_cultivate,
		"Preplaced attack organ occupies its host without slot registration")
	controller.select_node(disconnected)
	status = controller.get_selection_status()
	_check(status.reason == &"disconnected" and status.message.contains("连通"),
		"Disconnected mature node reports the live network failure")
	controller.select_node(other)
	var task_id: int = growth.create_target(other, Vector2(260, 400))
	_check(task_id > 0 and growth.has_active_task(), "A real unfunded growth task holds the build request")
	status = controller.get_selection_status()
	_check(status.reason == &"construction_busy" and status.message.contains("建造"),
		"Waiting growth prevents cultivation with a Chinese busy message")
	_check(not controller.request_cultivation(), "Cultivation controller rejects concurrent growth")
	_check(growth.pause_task(), "Growth can enter its paused state")
	_check(controller.get_selection_status().reason == &"construction_busy",
		"Paused growth still owns the single build request")
	await _remove_fixture(fixture)


func _test_low_funds_and_controls() -> void:
	var fixture: Dictionary = _fixture(0)
	var controller: CultivationInputController = fixture["controller"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	var growth: GrowthSystem = fixture["growth"]
	var core: MotherCore = fixture["core"]
	var host: HyphaNode = fixture["host"]
	var other: HyphaNode = fixture["other"]
	var notices: Array[String] = []
	controller.notice.connect(func(message: String) -> void: notices.append(message))
	_check(not controller.handle_input(_action(&"growth_mode")) \
		and not controller.handle_input(_action(&"growth_pause")) \
		and not controller.handle_input(_action(&"growth_cancel")),
		"Inactive cultivation passes G/P/X through to GrowthInputController")
	_check(not controller.handle_input(_action(&"cultivate_attack", false)) \
		and not controller.handle_input(_key(KEY_C, true)), "Release and keyboard echo do not create tasks")
	controller.select_node(host)
	var status: Dictionary = controller.get_selection_status()
	_check(status.reason == &"insufficient_nutrition" and status.message.contains("营养不足") \
		and status.can_cultivate, "Low balance is informative and still permits a waiting task")
	_check(controller.handle_input(_key(KEY_C)), "Configured C input is consumed by cultivation")
	var task: Dictionary = cultivation.get_task_snapshot()
	_check(cultivation.has_active_task() and task.state == &"waiting" and task.progress == 0.0,
		"Zero funds creates one waiting bud with no effective progress")
	_check(core.nutrition == 0 and task.consumed_nutrition == 0 and task.buffered_nutrition == 0,
		"Input creation never invents, spends or injects nutrition")
	_check(controller.handle_input(_key(KEY_G)) and notices.back().contains("建造"),
		"G is consumed with a busy notice while cultivation waits")
	_check(growth.create_target(other, Vector2(260, 400)) == 0,
		"The GrowthSystem admission gate also blocks API creation during waiting cultivation")
	controller.select_node(other)
	_check(not controller.request_cultivation() and cultivation.get_task_snapshot().task_id == task.task_id,
		"Selecting another empty node cannot replace a waiting cultivation")
	_check(controller.handle_input(_key(KEY_P)) and cultivation.get_task_snapshot().state == &"paused",
		"P pauses the current cultivation without depending on selected host")
	status = controller.get_selection_status()
	_check(status.can_resume and status.can_cancel and not status.can_pause,
		"Selection exposes paused task controls for the shared HUD buttons")
	_check(growth.create_target(other, Vector2(260, 400)) == 0 and not controller.request_cultivation(),
		"Paused cultivation keeps both build APIs mutually exclusive")
	_check(controller.handle_input(_key(KEY_P)) and cultivation.get_task_snapshot().state == &"waiting",
		"Second P resumes cultivation rather than reaching growth controls")
	_check(controller.handle_input(_key(KEY_X)) and not cultivation.has_active_task(),
		"X cancels the active cultivation request")
	_check(host.get_organ_bud() != null and host.get_organ_slot_state() == &"bud",
		"Cancellation leaves the persistent noncombat bud in its occupied slot")
	controller.select_node(host)
	status = controller.get_selection_status()
	_check(status.can_continue and not status.can_cultivate and status.remaining_cost == 12,
		"Selected cancelled bud exposes continuation instead of a second bud")
	_check(controller.request_cultivation() and cultivation.get_task_snapshot().task_id > task.task_id,
		"Continuation uses a new monotonically increasing attempt ID")
	_check(core.nutrition == 0, "Continuing an unfunded bud still leaves the core empty")
	await _remove_fixture(fixture)


func _test_paid_cancel_and_continue() -> void:
	var fixture: Dictionary = _fixture()
	var controller: CultivationInputController = fixture["controller"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	var supply: CultivationSupplySystem = fixture["supply"]
	var core: MotherCore = fixture["core"]
	var host: HyphaNode = fixture["host"]
	var selection_events: Array[Dictionary] = []
	var task_events: Array[Dictionary] = []
	controller.selection_status_changed.connect(func(snapshot: Dictionary) -> void:
		selection_events.append(snapshot))
	controller.status_changed.connect(func(snapshot: Dictionary) -> void: task_events.append(snapshot))
	controller.select_node(host)
	_check(controller.request_cultivation() and core.nutrition == 24,
		"Creating cultivation calls its API without debiting the core")
	for _packet_index: int in range(3):
		_dispatch_and_deliver(supply)
	cultivation.advance(0.60)
	var before: Dictionary = cultivation.get_task_snapshot()
	_check(before.structure_consumed == 2 and is_equal_approx(before.effective_time, 0.60) \
		and before.buffered_nutrition == 1, "Delivered funding pays two structure stages and retains one refundable nutrient")
	_check(supply.try_dispatch(), "Cancellation fixture also owns an actual prepaid packet in transit")
	var records: Array[Dictionary] = supply.get_shipment_records()
	var stale_packet: NutrientPacket = records.back()["packet"] as NutrientPacket
	var stale_callbacks: Array[Callable] = _arrival_callbacks(stale_packet)
	_check(controller.pause_cultivation(), "Paid cultivation can pause")
	cultivation.advance(5.0)
	_check(is_equal_approx(cultivation.get_task_snapshot().effective_time, before.effective_time) \
		and not supply.try_dispatch(), "Pause freezes effective time and creates no further demand")
	_check(controller.cancel_cultivation() and core.nutrition == 22,
		"Cancel refunds buffer and paid transit once, retaining exactly two sunk structure nutrients")
	var cancelled: Dictionary = cultivation.get_task_snapshot(before.task_id)
	var bud_id: String = before.bud_id
	_check(cancelled.state == &"cancelled" and cancelled.remaining_cost == 10 \
		and cancelled.buffered_nutrition == 0 and cancelled.startup_reserved == 0,
		"Cancelled attempt is drained before its bud can continue")
	_check(controller.get_selection_status().can_continue and controller.request_cultivation(),
		"C/HUD continuation reuses the selected paid bud")
	var continued: Dictionary = cultivation.get_task_snapshot()
	_check(continued.task_id > before.task_id and continued.bud_id == bud_id \
		and continued.structure_consumed == 2 and continued.remaining_cost == 10,
		"New attempt retains bud identity, paid progress and original remaining fee")
	for callback: Callable in stale_callbacks:
		if callback.is_valid() and is_instance_valid(stale_packet):
			callback.call(stale_packet)
	_check(not cultivation.receive_nutrition(before.task_id, "stale-input-test", 1) and core.nutrition == 22,
		"Old arrival callbacks and old task IDs cannot fund or refund the resumed attempt")
	cultivation.advance(0.15)
	var after: Dictionary = cultivation.get_task_snapshot()
	_check(after.structure_consumed == 2 and is_equal_approx(after.effective_time, 0.75),
		"Continuation completes a partially elapsed paid stage without charging it again")
	var historic: Dictionary = cultivation.get_task_snapshot(before.task_id)
	_check(historic.state == &"cancelled" and is_equal_approx(historic.effective_time, before.effective_time),
		"Old attempt snapshots do not follow new attempt progress")
	_check(not selection_events.is_empty() and selection_events.back().has("can_cancel") \
		and not task_events.is_empty() and task_events.back().has("structure_consumed") \
		and not task_events.back().has("can_cultivate"),
		"HUD selection and task signals carry their distinct public snapshot formats")
	await _remove_fixture(fixture)


func _test_selected_host_removal() -> void:
	var fixture: Dictionary = _fixture()
	var controller: CultivationInputController = fixture["controller"]
	var cultivation: CultivationSystem = fixture["cultivation"]
	var supply: CultivationSupplySystem = fixture["supply"]
	var core: MotherCore = fixture["core"]
	var host: HyphaNode = fixture["host"]
	controller.select_node(host)
	_check(controller.request_cultivation() and supply.try_dispatch(),
		"Selected host owns a live task and paid packet before removal")
	host.queue_free()
	await process_frame
	await process_frame
	var selection: Dictionary = controller.get_selection_status()
	_check(selection.host == null and selection.reason == &"no_selection",
		"Selected host removal clears controller selection safely")
	_check(not cultivation.has_active_task() and supply.get_in_transit_count() == 0 and core.nutrition == 24,
		"Host removal cancels and refunds paid transit without freeing an active signal emitter")
	await _remove_fixture(fixture)
