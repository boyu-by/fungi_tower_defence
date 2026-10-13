extends SceneTree
## UI 单元夹具：成熟期通过显式合成的回收记录解锁，不代表真实战斗收入。
## 材料使用真实供养扣款与 NutrientPacket 场景，隔离夹具手动推进到达边界。
## 库存预约夹具另有 UNIT 标注；本脚本不声称完成实机付费玩法验收。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const HOST_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const BUD_SCENE: PackedScene = preload("res://scenes/colony/organ_bud.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const PANEL_SCENE: PackedScene = preload("res://scenes/ui/differentiation_panel.tscn")
const PIERCING: int = WeaponProfile.DamageType.ARMOR_PIERCING
const SCATTER: int = WeaponProfile.DamageType.SCATTER

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	await _test_panel_and_maturity_boundary()
	await _test_eligibility_and_reasons()
	await _test_waiting_pause_and_wrong_selection()
	await _test_cancel_continue_and_inventory()
	await _test_completed_shapes()
	await _test_stop_reset_and_selection_removal()
	_check(root.get_child_count() == 0, "Input fixture teardown leaves no objects")
	print("DIFFERENTIATION_INPUT_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures,
		"fixture_scope": "UNIT maturity receipts; deterministic paid packet arrivals; no live battle acceptance",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture(initial_balance: int = 12, mature: bool = true) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var nodes := Node2D.new()
	var edges := Node2D.new()
	var packets := Node2D.new()
	var enemies := Node2D.new()
	var projectiles := Node2D.new()
	for container: Node2D in [nodes, edges, packets, enemies, projectiles]:
		world.add_child(container)
	var core := CORE_SCENE.instantiate() as MotherCore
	core.initial_nutrition = initial_balance
	core.position = Vector2(100, 400)
	world.add_child(core)
	var progress := ColonyProgress.new()
	world.add_child(progress)
	var capabilities := ColonyCapabilities.new()
	capabilities.colony_progress = progress
	world.add_child(capabilities)
	var network := NetworkSystem.new()
	world.add_child(network)
	_check(network.register_node(core, true), "Fixture registers the real core scene")
	var fixture: Dictionary = {
		"world": world, "nodes": nodes, "edges": edges, "packets": packets,
		"enemies": enemies, "projectiles": projectiles, "core": core,
		"progress": progress, "capabilities": capabilities, "network": network,
	}
	var host: HyphaNode = _add_host(fixture, Vector2(180, 400), "主菌结")
	var other: HyphaNode = _add_host(fixture, Vector2(240, 440), "副菌结")
	var disconnected: HyphaNode = _add_host(fixture, Vector2(320, 500), "未连接菌结")
	fixture["edge"] = _add_edge(fixture, core, host)
	_add_edge(fixture, core, other)
	fixture["host"] = host
	fixture["other"] = other
	fixture["disconnected"] = disconnected
	fixture["pair"] = _add_attack(fixture, host)
	fixture["other_pair"] = _add_attack(fixture, other)
	fixture["disconnected_pair"] = _add_attack(fixture, disconnected)
	if mature:
		_unit_unlock_maturity(progress)
		_check(core.nutrition == initial_balance, "UNIT maturity record never credits real mother-core funds")
	var system := DifferentiationSystem.new()
	system.colony_capabilities = capabilities
	system.network_system = network
	world.add_child(system)
	system.set_physics_process(false)
	var supply := DifferentiationSupplySystem.new()
	supply.differentiation_system = system
	supply.mother_core = core
	supply.network_system = network
	supply.packet_container = packets
	supply.auto_supply = false
	world.add_child(supply)
	supply.set_process(false)
	var panel := PANEL_SCENE.instantiate() as DifferentiationInputController
	panel.configure(system, supply)
	panel.position = Vector2(802, 348)
	world.add_child(panel)
	fixture["system"] = system
	fixture["supply"] = supply
	fixture["panel"] = panel
	return fixture


func _add_host(fixture: Dictionary, point: Vector2, display_name: String) -> HyphaNode:
	var host := HOST_SCENE.instantiate() as HyphaNode
	host.display_name = display_name
	var nodes: Node2D = fixture["nodes"]
	nodes.add_child(host)
	host.position = point
	var network: NetworkSystem = fixture["network"]
	_check(network.register_node(host), "Fixture registers a real mature host scene")
	return host


func _add_edge(fixture: Dictionary, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge := EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	var edges: Node2D = fixture["edges"]
	edges.add_child(edge)
	var network: NetworkSystem = fixture["network"]
	_check(network.register_edge(edge), "Fixture registers a real material transport edge")
	return edge


func _add_attack(fixture: Dictionary, host: HyphaNode) -> Dictionary:
	var organ := ORGAN_SCENE.instantiate() as AttackOrgan
	organ.initial_nutrition = 3
	host.add_child(organ)
	var cap := organ.get_node("Cap") as Polygon2D
	var normal_polygon: PackedVector2Array = cap.polygon.duplicate()
	var weapon := WEAPON_SCENE.instantiate() as SporeWeapon
	weapon.inventory_owner = organ
	weapon.enemy_container = fixture["enemies"]
	weapon.projectile_container = fixture["projectiles"]
	host.add_child(weapon)
	var view := organ.get_node_or_null("DifferentiationView") as OrganDifferentiationView
	if view == null:
		view = OrganDifferentiationView.new()
		view.name = "DifferentiationView"
		organ.add_child(view)
	view.configure(organ)
	return {"organ": organ, "weapon": weapon, "view": view, "normal_polygon": normal_polygon}


func _unit_unlock_maturity(progress: ColonyProgress) -> void:
	# UNIT ONLY：直接写观察者收件边界，不生成、运输或付费取得消化产物。
	_check(progress.record_arrival("unit:ui:maturity", 160), "UNIT synthesized maturity receipt, not real paid gameplay")


func _dispatch_material(supply: DifferentiationSupplySystem) -> NutrientPacket:
	var accepted: bool = supply.try_dispatch()
	_check(accepted, "Material fixture debits real core balance and launches one paid packet")
	if not accepted:
		return null
	var records: Array[Dictionary] = supply.get_shipment_records()
	var packet: Variant = records.back().get("packet")
	_check(is_instance_valid(packet) and packet is NutrientPacket, "Paid material shipment owns the actual scene packet")
	if not is_instance_valid(packet) or not packet is NutrientPacket:
		return null
	packet.set_physics_process(false)
	return packet as NutrientPacket


func _deliver_material(supply: DifferentiationSupplySystem) -> void:
	var packet: NutrientPacket = _dispatch_material(supply)
	if packet != null:
		# 隔离单元测试显式推进物理到达，不直接调用系统 receive_nutrition。
		packet._physics_process(10.0)


func _remove_fixture(fixture: Dictionary) -> void:
	var system: DifferentiationSystem = fixture["system"]
	var supply: DifferentiationSupplySystem = fixture["supply"]
	var panel: DifferentiationInputController = fixture["panel"]
	panel.select_node(null)
	panel.configure(null, null)
	system.stop()
	supply.reset(true)
	var world: Node2D = fixture["world"]
	world.queue_free()
	await process_frame
	await process_frame


func _test_panel_and_maturity_boundary() -> void:
	var actions_before: Array[StringName] = InputMap.get_actions()
	var fixture: Dictionary = _fixture(8, false)
	var panel: DifferentiationInputController = fixture["panel"]
	var host: HyphaNode = fixture["host"]
	var progress: ColonyProgress = fixture["progress"]
	var core: MotherCore = fixture["core"]
	var status: Dictionary = panel.get_status()
	_check(status.availability == &"no_selection" and not panel.visible, "Idle panel hides with no selection")
	_check(not panel.request_start(PIERCING), "No selection cannot start differentiation")
	for control_name: String in ["PiercingButton", "ScatterButton", "PauseButton", "ContinueButton", "CancelButton", "StatusLabel", "ProgressBar", "RulesLabel", "TypeInfoLabel"]:
		_check(panel.get_node_or_null(NodePath("%" + control_name)) != null, "Scene exposes unique " + control_name)
	panel.select_node(host)
	status = panel.get_status()
	_check(status.availability == &"stage_locked" and not status.can_start_piercing and not status.can_start_scatter,
		"Initial core balance does not unlock mature differentiation")
	_check(progress.record_arrival("unit:ui:159", 159), "UNIT synthesized receipt establishes the 159 boundary")
	_check(panel.get_status().availability == &"stage_locked", "159 synthetic recovery remains stage locked")
	_check(progress.record_arrival("unit:ui:160", 1), "UNIT synthesized receipt reaches exactly 160")
	status = panel.get_status()
	_check(status.availability == &"ready" and status.can_start_piercing and status.can_start_scatter,
		"Exactly 160 unlocks both choices through the live capability query")
	_check(not panel.piercing_button.disabled and not panel.scatter_button.disabled,
		"Stage notification refreshes visible choices without a new selection")
	_check(core.nutrition == 8 and core.get_received_product_count() == 0,
		"UNIT maturity fixture is not claimed as a paid digestion receipt")
	_check(panel.type_info_label.text.contains("每轮2") and panel.type_info_label.text.contains("整轮1"),
		"Visible type information distinguishes whole-round ammo costs")
	_check(panel.rules_label.text.contains("160") and panel.rules_label.text.contains("8材料") and panel.rules_label.text.contains("5秒"),
		"Visible rules state the maturity threshold, material fee and effective time")
	await process_frame
	_check(panel.size.x <= 374.0 and panel.size.y <= 294.0, "Normal panel fits the parent 374 by 294 dock")
	_check(panel.is_pointer_over_panel(panel.get_global_rect().get_center()), "Visible panel guards pointer clicks inside its bounds")
	_check(not panel.is_pointer_over_panel(Vector2(20, 20)), "Map outside the panel remains available")
	var rules_button := panel.get_node("%RulesButton") as Button
	rules_button.pressed.emit()
	await process_frame
	_check(panel.rules_label.text.contains("0.625") and panel.rules_label.text.contains("不会赠送弹药") \
		and panel.rules_label.text.contains("完整射击冷却"), "Expanded help states paid timing, ammo preservation and cancellation cooldown")
	_check(panel.size.y <= 294.0, "Rules expand in a bounded scroll area without enlarging the dock")
	_check(InputMap.get_actions() == actions_before and InputMap.has_action("growth_pause") and InputMap.has_action("growth_cancel"),
		"Panel adds no keyboard shortcuts and preserves the existing construction P/X actions")
	await _remove_fixture(fixture)


func _test_eligibility_and_reasons() -> void:
	var fixture: Dictionary = _fixture()
	var panel: DifferentiationInputController = fixture["panel"]
	var system: DifferentiationSystem = fixture["system"]
	var supply: DifferentiationSupplySystem = fixture["supply"]
	var core: MotherCore = fixture["core"]
	var empty: HyphaNode = _add_host(fixture, Vector2(400, 400), "空菌结")
	panel.select_node(empty)
	_check(panel.get_status().availability == &"not_mature_organ" and panel.get_selected_organ() == null,
		"An empty mature host does not advertise completed attack differentiation")
	var bud := BUD_SCENE.instantiate() as OrganBud
	empty.add_child(bud)
	_check(panel.get_status().availability == &"not_mature_organ" and not panel.request_start(PIERCING),
		"An immature cultivation bud cannot use attack differentiation")
	panel.select_node(fixture["disconnected"])
	_check(panel.get_status().availability == &"disconnected" and not panel.request_start(PIERCING),
		"Disconnected completed attack reports a clear connectivity reason")
	panel.select_node(fixture["host"])
	_check(not panel.request_start(-1) and not panel.request_start(WeaponProfile.DamageType.NORMAL),
		"Only armor piercing and scatter are valid new differentiation directions")
	core.health = 0
	panel.refresh()
	_check(panel.get_status().availability == &"core_unavailable" and panel.status_label.text.contains("母核"),
		"A dead core is shown as unavailable rather than ready")
	core.health = core.max_health
	panel.configure(null, null)
	_check(panel.get_status().availability == &"invalid_configuration" and panel.piercing_button.disabled,
		"Missing backend configuration disables choices")
	panel.configure(system, supply)
	var pair: Dictionary = fixture["pair"]
	var weapon: SporeWeapon = pair["weapon"]
	var preset: WeaponProfile = DifferentiationSystem.ARMOR_PIERCING_PROFILE
	_check(weapon.configure_profile(preset), "UNIT preconfigured non-normal weapon fixture")
	panel.refresh()
	_check(panel.get_status().availability == &"not_normal" and not panel.request_start(SCATTER),
		"A preconfigured non-normal matching weapon cannot be differentiated by UI")
	await _remove_fixture(fixture)


func _test_waiting_pause_and_wrong_selection() -> void:
	var fixture: Dictionary = _fixture(0)
	var panel: DifferentiationInputController = fixture["panel"]
	var system: DifferentiationSystem = fixture["system"]
	var core: MotherCore = fixture["core"]
	var pair: Dictionary = fixture["pair"]
	var organ: AttackOrgan = pair["organ"]
	var view: OrganDifferentiationView = pair["view"]
	panel.select_node(fixture["host"])
	_check(panel.get_status().can_start_piercing and panel.request_start(PIERCING),
		"Zero materials can create one waiting task without free progress")
	var task: Dictionary = system.get_task_snapshot()
	var task_id: int = task.task_id
	_check(task.state == &"waiting" and task.progress == 0.0 and task.consumed_nutrition == 0 and core.nutrition == 0,
		"UI start spends no material and invents no nutrition or effective time")
	_check(not organ.is_work_enabled() and view.get_visual_state().attack_type == WeaponProfile.DamageType.NORMAL,
		"Waiting task stops work while retaining the actual ordinary shape")
	panel.select_node(fixture["other"])
	var status: Dictionary = panel.get_status()
	_check(status.availability == &"busy" and not status.can_pause and not status.can_continue and not status.can_cancel,
		"Selecting another organ reports busy with all foreign-task actions disabled")
	_check(not panel.request_start(SCATTER) and not panel.pause_differentiation() \
		and not panel.resume_differentiation() and not panel.cancel_differentiation(),
		"Wrong selection cannot start, pause, resume or cancel the active organ")
	_check(system.get_task_snapshot().task_id == task_id and system.has_active_task(),
		"Rejected wrong-selection actions preserve the global task identity")
	panel.select_node(null)
	_check(panel.visible and not panel.get_status().can_cancel and panel.status_label.text.contains("主菌结"),
		"Active task remains visible with guidance after selection is cleared")
	panel.select_node(fixture["host"])
	panel.pause_button.pressed.emit()
	status = panel.get_status()
	_check(status.availability == &"paused" and not status.can_pause and status.can_continue and status.can_cancel,
		"Pause button routes only to the selected active task")
	_check(view.get_visual_state().paused and view.get_visual_state().attack_type == WeaponProfile.DamageType.NORMAL,
		"Paused pending direction retains an ordinary cap and a paused progress state")
	panel.set_interaction_suspended(true)
	_check(not panel.visible and not panel.is_pointer_over_panel(panel.get_global_rect().get_center()) \
		and system.has_active_task() and system.get_task_snapshot().state == &"paused",
		"Placement suspension hides UI without changing or releasing the paused task")
	panel.set_interaction_suspended(false)
	panel.continue_button.pressed.emit()
	_check(system.get_task_snapshot().state == &"waiting", "Continue button resumes the selected paused task")
	system.advance(100.0)
	_check(system.get_task_snapshot().progress == 0.0 and core.nutrition == 0,
		"Large elapsed time cannot advance a task without arrived material")
	panel.cancel_button.pressed.emit()
	_check(not system.has_active_task() and panel.get_status().can_continue and not panel.get_status().can_cancel,
		"Cancel button releases the active task but retains its locked resumable direction")
	await _remove_fixture(fixture)


func _test_cancel_continue_and_inventory() -> void:
	var fixture: Dictionary = _fixture(24)
	var panel: DifferentiationInputController = fixture["panel"]
	var system: DifferentiationSystem = fixture["system"]
	var supply: DifferentiationSupplySystem = fixture["supply"]
	var core: MotherCore = fixture["core"]
	var network: NetworkSystem = fixture["network"]
	var pair: Dictionary = fixture["pair"]
	var organ: AttackOrgan = pair["organ"]
	var weapon: SporeWeapon = pair["weapon"]
	var view: OrganDifferentiationView = pair["view"]
	var cap := organ.get_node("Cap") as Polygon2D
	var slots_id: int = organ.get_node("InventorySlots").get_instance_id()
	var hit_area_id: int = organ.get_node("HitArea").get_instance_id()
	# UNIT ONLY：隔离库存预约边界；这份预约不是本测试真实派出的战斗弹药。
	_check(organ.reserve_nutrition(1), "UNIT inventory reservation fixture, not a real paid combat delivery")
	panel.select_node(fixture["host"])
	_check(panel.request_start(PIERCING), "Selected ordinary organ starts armor-piercing differentiation")
	var first_id: int = system.get_task_snapshot().task_id
	_deliver_material(supply)
	_deliver_material(supply)
	system.advance(0.2)
	var paid: Dictionary = system.get_task_snapshot()
	_check(paid.consumed_nutrition == 1 and paid.buffered_nutrition == 1 and is_equal_approx(paid.effective_time, 0.2),
		"Only arrived material pays the first 0.625-second stage")
	_check(organ.nutrition == 3 and organ.incoming_nutrition == 1 and cap.polygon == pair["normal_polygon"],
		"Starting paid progress preserves original ammunition, reservation and ordinary cap")
	var edge: HyphaEdge = fixture["edge"]
	network.unregister_edge(edge)
	_check(not network.get_registered_edges().has(edge), "Fixture disconnects the selected organ's original route")
	system.advance(10.0)
	_check(system.get_task_snapshot().wait_reason == &"disconnected" \
		and is_equal_approx(system.get_task_snapshot().effective_time, paid.effective_time),
		"Disconnected UI task reports waiting and preserves paid progress")
	_check(network.register_edge(edge), "Fixture reconnects the original route")
	var paused_arrival: NutrientPacket = _dispatch_material(supply)
	var cancelled_transit: NutrientPacket = _dispatch_material(supply)
	_check(panel.pause_differentiation(), "Selected paid task can be paused")
	if is_instance_valid(paused_arrival):
		paused_arrival._physics_process(10.0)
	_check(system.get_task_snapshot().buffered_nutrition == 2 and supply.get_in_transit_count() == 1,
		"Already paid material can arrive during pause while another shipment remains in transit")
	system.advance(100.0)
	_check(is_equal_approx(system.get_task_snapshot().effective_time, 0.2) and not organ.is_work_enabled(),
		"Pause freezes effective time and keeps firing stopped")
	_check(panel.cancel_differentiation(), "Selected paused task can be cancelled")
	var cancelled: Dictionary = panel.get_status().task
	_check(cancelled.state == &"cancelled" and cancelled.direction == PIERCING \
		and cancelled.consumed_nutrition == 1 and cancelled.stage_paid \
		and is_equal_approx(cancelled.effective_time, 0.2) and cancelled.buffered_nutrition == 0,
		"Cancelled UI snapshot retains paid stage and direction after material refunds")
	_check(core.nutrition == 23 and supply.get_supply_snapshot().refunded == 3 \
		and supply.get_in_transit_count() == 0, "Cancellation refunds only two cached plus one transit material")
	_check(is_instance_valid(cancelled_transit) and cancelled_transit.is_queued_for_deletion(),
		"Cancelled paid material packet is stopped rather than left able to deliver")
	_check(organ.is_work_enabled() and organ.nutrition == 3 and organ.incoming_nutrition == 1,
		"Cancellation restores ordinary work with the same ammunition inventory")
	var firing: Dictionary = weapon.get_firing_state()
	_check(float(firing.cooldown_remaining) >= float(firing.fire_interval) * 0.95,
		"Cancellation restores a full ordinary-weapon cooldown")
	_check(panel.get_status().can_continue and not panel.get_status().can_start_piercing \
		and not panel.get_status().can_start_scatter and system.get_availability(organ, SCATTER) == &"direction_locked",
		"Cancelled paid direction cannot be replaced by a new choice")
	_check(not panel.request_start(PIERCING) and not panel.request_start(SCATTER),
		"Start API cannot hijack a retained cancelled direction")
	var queried: Dictionary = panel.get_status()
	queried["task"]["direction"] = SCATTER
	queried["task"]["consumed_nutrition"] = 99
	queried["supply"]["available"] = 99
	panel.refresh()
	_check(panel.get_status().task.direction == PIERCING and panel.get_status().task.consumed_nutrition == 1 \
		and core.nutrition == 23, "UI snapshot copies and refreshes cannot mutate progress or material accounting")
	_check(panel.resume_differentiation(), "Continue API resumes the cancelled selected organ along its original direction")
	var continued: Dictionary = panel.get_status().task
	_check(continued.task_id > first_id and continued.direction == PIERCING \
		and is_equal_approx(continued.effective_time, 0.2) and continued.remaining_cost == 7 \
		and continued.organ == organ and continued.weapon == weapon,
		"Continue uses a new attempt ID with the same organ, weapon and already-paid progress")
	_check(not organ.is_work_enabled() and view.get_visual_state().attack_type == WeaponProfile.DamageType.NORMAL,
		"Continuing again stops work without adopting the pending profile")
	for index: int in range(7):
		_deliver_material(supply)
	system.advance(10.0)
	var completed: Dictionary = panel.get_status()
	_check(completed.availability == &"completed" and completed.task.state == &"completed" \
		and completed.task.consumed_nutrition == 8 and completed.task.effective_time == 5.0,
		"Continued UI task completes at eight total paid stages and five total effective seconds")
	_check(core.nutrition == 16 and organ.nutrition == 3 and organ.incoming_nutrition == 1 \
		and completed.task.organ == organ and completed.task.weapon == weapon,
		"Completion neither recreates nodes, repays retained progress nor grants ammunition")
	_check(organ.get_node("InventorySlots").get_instance_id() == slots_id \
		and organ.get_node("HitArea").get_instance_id() == hit_area_id,
		"Visual differentiation preserves inventory slots and hit-area identities")
	await _remove_fixture(fixture)


func _test_completed_shapes() -> void:
	for direction: int in [PIERCING, SCATTER]:
		var fixture: Dictionary = _fixture(8)
		var panel: DifferentiationInputController = fixture["panel"]
		var system: DifferentiationSystem = fixture["system"]
		var supply: DifferentiationSupplySystem = fixture["supply"]
		var pair: Dictionary = fixture["pair"]
		var organ: AttackOrgan = pair["organ"]
		var weapon: SporeWeapon = pair["weapon"]
		var view: OrganDifferentiationView = pair["view"]
		var cap := organ.get_node("Cap") as Polygon2D
		panel.select_node(fixture["host"])
		_check(panel.request_start(direction), "Shape fixture starts direction %d" % direction)
		for index: int in range(8):
			_deliver_material(supply)
		_check(view.get_visual_state().attack_type == WeaponProfile.DamageType.NORMAL \
			and cap.polygon == pair["normal_polygon"], "Arrived materials alone do not change final shape %d" % direction)
		system.advance(4.99)
		_check(not organ.has_completed_differentiation() and view.get_visual_state().attack_type == WeaponProfile.DamageType.NORMAL \
			and view.get_visual_state().progress < 1.0 and cap.polygon == pair["normal_polygon"],
			"Before five effective seconds pending shape stays ordinary %d" % direction)
		_check(panel.pause_differentiation(), "Near-complete task pauses %d" % direction)
		var paused_progress: float = view.get_visual_state().progress
		system.advance(10.0)
		_check(view.get_visual_state().paused and is_equal_approx(view.get_visual_state().progress, paused_progress),
			"Paused shape reflects retained progress without completing %d" % direction)
		_check(panel.resume_differentiation(), "Near-complete task resumes %d" % direction)
		system.advance(1.0)
		view.refresh()
		var visual: Dictionary = view.get_visual_state()
		var status: Dictionary = panel.get_status()
		_check(organ.has_completed_differentiation() and visual.attack_type == direction \
			and not visual.differentiating and not visual.paused and visual.progress == 1.0,
			"Final visual type comes from the actual completed matching weapon %d" % direction)
		var expected := PackedVector2Array(OrganDifferentiationView.PIERCING_CAP if direction == PIERCING \
			else OrganDifferentiationView.SCATTER_CAP)
		_check(cap.polygon == expected and cap.polygon != pair["normal_polygon"],
			"Completed cap uses hard spikes or multiple petals %d" % direction)
		var profile: WeaponProfile = weapon.get_weapon_profile()
		_check(profile.damage_type == direction and profile.nutrition_cost == (2 if direction == PIERCING else 1) \
			and profile.max_targets == (1 if direction == PIERCING else 3),
			"Completed type matches visible round fee and target count %d" % direction)
		_check(not status.can_start_piercing and not status.can_start_scatter and not status.can_pause \
			and not status.can_continue and not status.can_cancel and not panel.request_start(PIERCING) \
			and not panel.request_start(SCATTER), "Completed UI permits no further differentiation or revert %d" % direction)
		var before: Dictionary = organ.get_differentiation_snapshot()
		var ammunition: int = organ.nutrition
		for index: int in range(4):
			view.refresh()
			panel.refresh()
		var core: MotherCore = fixture["core"]
		_check(organ.get_differentiation_snapshot() == before and organ.nutrition == ammunition and core.nutrition == 0,
			"Read-only view and panel refresh preserve completion and all balances %d" % direction)
		await _remove_fixture(fixture)


func _test_stop_reset_and_selection_removal() -> void:
	var fixture: Dictionary = _fixture(8)
	var panel: DifferentiationInputController = fixture["panel"]
	var system: DifferentiationSystem = fixture["system"]
	var supply: DifferentiationSupplySystem = fixture["supply"]
	var progress: ColonyProgress = fixture["progress"]
	panel.select_node(fixture["host"])
	_check(panel.request_start(SCATTER), "Lifecycle UI fixture starts scatter")
	var task_id: int = system.get_task_snapshot().task_id
	system.stop()
	_check(panel.get_status().availability == &"stopped" and not panel.get_status().can_continue \
		and not panel.get_status().can_cancel, "Stopping the backend disables all selected task actions")
	supply.reset(true)
	system.reset()
	supply.reset(false)
	panel.refresh()
	_check(panel.get_status().availability == &"continuable" and panel.get_status().task.direction == SCATTER \
		and panel.get_status().task.task_id == task_id, "Backend reset retains cancelled direction and updates UI eligibility")
	progress.reset()
	_check(panel.get_status().availability == &"stage_locked" and panel.continue_button.disabled,
		"Progress reset immediately removes mature-stage continuation from the panel")
	_unit_unlock_maturity(progress)
	_check(panel.resume_differentiation(), "UNIT mature reset fixture continues the retained scatter direction")
	var host: HyphaNode = fixture["host"]
	host.queue_free()
	await process_frame
	await process_frame
	_check(panel.get_selected_organ() == null and panel.get_status().availability == &"no_selection" \
		and not panel.visible and not system.has_active_task(),
		"Removing the selected host clears guarded UI references and its backend task")
	await _remove_fixture(fixture)
