extends Node2D
## 关卡只协调输入与信号；库存、运输和界面各自管理自己的职责。

const LARGE_CARCASS_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")

@export var growth_planner: GrowthPlanner = GrowthPlanner.new()
@export var expansion_demo_enabled: bool = true
@export var carcass_demo_enabled: bool = false

@onready var mother_core: MotherCore = $World/Colony/MotherCore
@onready var hypha_nodes: Node2D = $World/Colony/Nodes
@onready var hypha_edges: Node2D = $World/Colony/Connections
@onready var network_system: NetworkSystem = $Systems/NetworkSystem
@onready var traffic_system: NetworkTrafficSystem = $Systems/NetworkTrafficSystem
@onready var cargo_passage_tracker: CargoPassageTracker = $Systems/CargoPassageTracker
@onready var main_vein_system: MainVeinSystem = $Systems/MainVeinSystem
@onready var fungal_field: FungalField = $World/FungalField
@onready var attack_organ: AttackOrgan = $World/Colony/Nodes/HyphaNode/AttackOrgan
@onready var weapon: SporeWeapon = $World/Colony/Nodes/HyphaNode/SporeWeapon
@onready var supply_system: SupplySystem = $Systems/SupplySystem
@onready var enemy_spawner: EnemySpawner = $Systems/EnemySpawner
@onready var digestive_organ: DigestiveOrgan = $World/Colony/Nodes/RearNode/DigestiveOrgan
@onready var recycling_system: RecyclingSystem = $Systems/RecyclingSystem
@onready var growth_system: GrowthSystem = $Systems/GrowthSystem
@onready var growth_supply_system: GrowthSupplySystem = $Systems/GrowthSupplySystem
@onready var growth_input_controller: GrowthInputController = $Systems/GrowthInputController
@onready var nutrition_return_system: NutritionReturnSystem = $Systems/NutritionReturnSystem
@onready var colony_progress: ColonyProgress = $Systems/ColonyProgress
@onready var colony_capabilities: ColonyCapabilities = $Systems/ColonyCapabilities
@onready var construction_queue: ConstructionQueue = $Systems/ConstructionQueue
@onready var construction_coordinator: ConstructionCoordinator = $Systems/ConstructionCoordinator
@onready var construction_supply_scheduler: ConstructionSupplyScheduler = $Systems/ConstructionSupplyScheduler
@onready var construction_queue_controller: ConstructionQueueController = $HUD/ConstructionQueue
@onready var cultivation_system: CultivationSystem = $Systems/CultivationSystem
@onready var cultivation_supply_system: CultivationSupplySystem = $Systems/CultivationSupplySystem
@onready var cultivation_input_controller: CultivationInputController = $Systems/CultivationInputController
@onready var remote_cultivation_system: RemoteCultivationSystem = $Systems/RemoteCultivationSystem
@onready var connection_system: ConnectionSystem = $Systems/ConnectionSystem
@onready var connection_input_controller: ConnectionInputController = $Systems/ConnectionInputController
@onready var repair_system: RepairSystem = $Systems/RepairSystem
@onready var repair_supply_system: RepairSupplySystem = $Systems/RepairSupplySystem
@onready var repair_input_controller: RepairInputController = $Systems/RepairInputController
@onready var hud: ColonyHUD = $HUD

var selected_node: HyphaNode = null
var _local_cultivation_control_selected: bool = false
var _is_tearing_down: bool = false


func _ready() -> void:
	if not expansion_demo_enabled:
		$World/Remains/ExpansionRemains.free()
	if carcass_demo_enabled:
		var carcass: LargeCarcass = LARGE_CARCASS_SCENE.instantiate() as LargeCarcass
		carcass.name = "LargeCarcass"
		carcass.position = Vector2(1120, 440)
		$World/Remains.add_child(carcass)
	_register_initial_network()
	_connect_traffic()
	_connect_growth()
	_connect_cultivation()
	_connect_connection()
	_connect_nutrition_return()
	_connect_digestive_capabilities()
	_connect_repair()
	main_vein_system.edge_progress_changed.connect(_on_main_vein_changed)
	_connect_construction_queue()
	mother_core.depleted.connect(_on_mother_core_depleted)
	mother_core.nutrition_changed.connect(hud.show_core_nutrition)
	supply_system.transport_changed.connect(hud.show_transport)
	supply_system.notice.connect(hud.show_notice)
	enemy_spawner.wave_changed.connect(hud.show_battle)
	enemy_spawner.wave_finished.connect(_on_wave_finished)
	digestive_organ.selection_requested.connect(_on_digestive_selection_requested)
	recycling_system.recycling_changed.connect(hud.show_recycling)
	digestive_organ.inventory_changed.connect(hud.show_digestion)
	digestive_organ.digested.connect(_on_remains_digested)
	hud.show_core_nutrition(mother_core.nutrition)
	_refresh_inventory_hud()
	hud.show_transport(supply_system.get_in_transit_count(), 0, 0)
	hud.show_battle(0, 0, 0, enemy_spawner.wave_size)
	hud.show_recycling(0, 0, 0)
	hud.show_digestion(digestive_organ.get_queued_count(), digestive_organ.incoming_remains)
	hud.show_production(digestive_organ.digested_count)
	if carcass_demo_enabled:
		hud.show_notice("L 连接菌结：先选左翼，再选右翼，预览环路；B 在右侧十字种芽，G 伸展，C 培育")


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_digestive_node_added):
		get_tree().node_added.disconnect(_on_digestive_node_added)


func _connect_digestive_capabilities() -> void:
	get_tree().node_added.connect(_on_digestive_node_added)
	for organ: DigestiveOrgan in get_digestive_organs():
		_register_digestive_capabilities(organ)
	digestive_organ.digestion_changed.connect(hud.show_digestive_chambers)
	hud.show_digestive_chambers(digestive_organ.get_digestion_snapshot())


## 只配置本关卡中的胃囊；新增胃囊会立即查询当前能力，不依赖过去的解锁通知。
func _on_digestive_node_added(node: Node) -> void:
	if node is DigestiveOrgan and is_ancestor_of(node):
		_register_added_digestive_organ.call_deferred(weakref(node))


func _register_added_digestive_organ(reference: WeakRef) -> void:
	var organ: DigestiveOrgan = reference.get_ref() as DigestiveOrgan
	if is_instance_valid(organ):
		_register_digestive_capabilities(organ)


func _register_digestive_capabilities(organ: DigestiveOrgan) -> void:
	if _is_tearing_down or not is_instance_valid(organ) or organ.is_queued_for_deletion() \
			or not is_ancestor_of(organ) or not organ.is_inside_tree():
		return
	organ.configure_capabilities(colony_capabilities)


func get_digestive_organs() -> Array[DigestiveOrgan]:
	var organs: Array[DigestiveOrgan] = []
	for node: Node in find_children("*", "", true, false):
		if node is DigestiveOrgan and not node.is_queued_for_deletion():
			organs.append(node as DigestiveOrgan)
	return organs


func _stop_all_digestion() -> void:
	_is_tearing_down = true
	for organ: DigestiveOrgan in get_digestive_organs():
		organ.stop_processing()


func _stop_main_vein_growth() -> void:
	main_vein_system.stop()
	# 先淘汰所有旧货物上下文；随后取消任务的账目通知不能触发新一局成长。
	cargo_passage_tracker.reset()


func _on_main_vein_changed(_edge: HyphaEdge, _snapshot: Dictionary) -> void:
	if not _is_tearing_down:
		_refresh_repair_hud()


func _connect_traffic() -> void:
	traffic_system.traffic_changed.connect(_on_traffic_changed)
	_on_traffic_changed()


func _connect_repair() -> void:
	repair_input_controller.mode_changed.connect(_on_repair_mode_changed)
	repair_input_controller.selection_changed.connect(_on_repair_selection_changed)
	repair_input_controller.preview_changed.connect(_on_repair_snapshot_changed)
	repair_input_controller.status_changed.connect(_on_repair_snapshot_changed)
	repair_input_controller.notice.connect(hud.show_notice)
	repair_supply_system.supply_changed.connect(_on_repair_snapshot_changed)
	repair_supply_system.notice.connect(hud.show_notice)
	mother_core.budget_changed.connect(_on_repair_snapshot_changed)
	hud.repair_mode_requested.connect(_on_repair_mode_requested)
	hud.repair_requested.connect(repair_input_controller.request_repair)
	hud.repair_pause_requested.connect(repair_input_controller.toggle_pause)
	hud.repair_cancel_requested.connect(repair_input_controller.cancel_repair)
	_refresh_repair_hud()


func _on_repair_mode_requested() -> void:
	if mother_core.health <= 0:
		return
	if repair_input_controller.is_selecting():
		repair_input_controller.exit_selection_mode()
	else:
		repair_input_controller.enter_selection_mode()


func _on_repair_mode_changed(selecting: bool) -> void:
	if selecting:
		growth_input_controller.exit_placement_mode()
		cultivation_input_controller.exit_remote_placement_mode()
		connection_input_controller.exit_placement_mode()
		_select_node(null)
	_refresh_repair_hud()


func _on_repair_selection_changed(_edge: HyphaEdge) -> void:
	_refresh_repair_hud()


func _on_repair_snapshot_changed(_snapshot: Dictionary) -> void:
	_refresh_repair_hud()


func _refresh_repair_hud() -> void:
	if not is_instance_valid(hud) or not is_instance_valid(repair_input_controller) \
			or not is_instance_valid(repair_system) or not is_instance_valid(repair_supply_system) \
			or not is_instance_valid(mother_core):
		return
	var preview: Dictionary = repair_input_controller.get_preview()
	var vein_snapshot: Dictionary = {}
	var selected_edge: Variant = preview.get("edge")
	if is_instance_valid(main_vein_system) and is_instance_valid(selected_edge) and selected_edge is HyphaEdge:
		vein_snapshot = main_vein_system.get_edge_snapshot(selected_edge as HyphaEdge)
	hud.show_repair(preview, repair_system.get_task_snapshot(),
		repair_supply_system.get_supply_snapshot(), mother_core.get_budget_snapshot(),
		repair_input_controller.is_selecting(), vein_snapshot)


func _on_traffic_changed() -> void:
	if is_instance_valid(hud) and is_instance_valid(traffic_system):
		hud.show_traffic(traffic_system.get_snapshot())


func _connect_connection() -> void:
	connection_system.construction_blocker = _other_connection_construction_busy
	connection_input_controller.mode_changed.connect(_on_connection_mode_changed)
	connection_input_controller.preview_changed.connect(hud.show_connection_preview)
	connection_input_controller.status_changed.connect(hud.show_connection_status)
	connection_input_controller.notice.connect(hud.show_notice)
	growth_input_controller.mode_changed.connect(_on_other_placement_mode_changed)
	cultivation_input_controller.remote_mode_changed.connect(_on_other_placement_mode_changed)
	hud.connection_mode_requested.connect(_on_connection_mode_requested)
	hud.show_connection_mode(false)


func _other_connection_construction_busy() -> bool:
	return remote_cultivation_system.has_active_request() or cultivation_system.has_active_task()


func _on_connection_mode_requested() -> void:
	if mother_core.health <= 0:
		return
	if connection_input_controller.is_placing():
		connection_input_controller.exit_placement_mode()
	else:
		connection_input_controller.enter_placement_mode()


func _on_connection_mode_changed(placing: bool) -> void:
	if placing:
		repair_input_controller.exit_selection_mode()
		growth_input_controller.exit_placement_mode()
		cultivation_input_controller.exit_remote_placement_mode()
	hud.show_connection_mode(placing)


func _on_other_placement_mode_changed(placing: bool) -> void:
	if placing:
		repair_input_controller.exit_selection_mode()
		connection_input_controller.exit_placement_mode()


func _connect_cultivation() -> void:
	cultivation_input_controller.selection_status_changed.connect(hud.show_cultivation_selection)
	cultivation_input_controller.status_changed.connect(hud.show_construction_status)
	cultivation_input_controller.remote_mode_changed.connect(hud.show_remote_mode)
	cultivation_input_controller.remote_preview_changed.connect(hud.show_remote_preview)
	cultivation_input_controller.notice.connect(hud.show_notice)
	cultivation_supply_system.supply_changed.connect(hud.show_cultivation_supply)
	cultivation_supply_system.notice.connect(hud.show_notice)
	cultivation_system.task_changed.connect(_on_cultivation_task_changed)
	cultivation_system.organ_matured.connect(_on_organ_matured)
	hud.cultivation_requested.connect(_on_cultivation_requested)
	hud.remote_cultivation_requested.connect(_on_remote_cultivation_requested)
	cultivation_input_controller.select_node(selected_node)
	hud.show_cultivation_selection(cultivation_input_controller.get_selection_status())
	hud.show_cultivation_status(cultivation_system.get_task_snapshot())
	hud.show_cultivation_supply(cultivation_supply_system.get_supply_snapshot())
	hud.show_remote_status(remote_cultivation_system.get_request_snapshot())


func _on_remote_cultivation_requested() -> void:
	if mother_core.health <= 0:
		return
	if cultivation_input_controller.is_remote_placing():
		cultivation_input_controller.exit_remote_placement_mode()
	else:
		cultivation_input_controller.enter_remote_placement_mode()


func _on_cultivation_requested() -> void:
	if mother_core.health > 0 and cultivation_input_controller.request_cultivation():
		if not construction_coordinator.multi_worker_enabled:
			construction_coordinator.select_request("")
			_local_cultivation_control_selected = true
		_on_construction_queue_changed(construction_coordinator.get_snapshot())


func _on_cultivation_task_changed(_snapshot: Dictionary) -> void:
	if not is_instance_valid(construction_coordinator) and cultivation_system.has_active_task():
		growth_input_controller.exit_placement_mode()
		connection_input_controller.exit_placement_mode()


func _on_organ_matured(_task_id: int, host: HyphaNode,
		_organ: AttackOrgan, _new_weapon: SporeWeapon) -> void:
	_refresh_inventory_hud()
	_refresh_weapon_ranges.call_deferred()
	if selected_node == host:
		cultivation_input_controller.refresh()
	hud.show_notice("攻击器官已成熟：启动库存 4，现由战斗供养补给")


func _connect_nutrition_return() -> void:
	colony_progress.register_source(mother_core)
	colony_progress.progress_changed.connect(hud.show_recovered_progress)
	colony_progress.progress_changed.connect(_refresh_growth_stage)
	colony_progress.stage_changed.connect(_on_colony_stage_changed)
	digestive_organ.output_changed.connect(hud.show_digestive_output)
	nutrition_return_system.return_changed.connect(hud.show_nutrition_return)
	nutrition_return_system.notice.connect(hud.show_notice)
	hud.show_recovered_progress(colony_progress.get_total_recovered(), colony_progress.get_product_count())
	_refresh_growth_stage()
	hud.show_digestive_output(digestive_organ.get_output_snapshot())
	hud.show_nutrition_return(nutrition_return_system.get_return_snapshot())


func _refresh_growth_stage(_total_recovered: int = 0, _product_count: int = 0) -> void:
	hud.show_growth_stage(colony_progress.get_stage_name(),
		colony_progress.get_total_recovered(), colony_progress.get_next_stage_threshold())


func _on_colony_stage_changed(_previous_stage: ColonyProgress.Stage,
		current_stage: ColonyProgress.Stage) -> void:
	_refresh_growth_stage()
	if current_stage != ColonyProgress.Stage.NASCENT and current_stage == colony_progress.get_stage():
		hud.show_notice("菌落成长至「%s」阶段" % colony_progress.get_stage_name())


func _connect_growth() -> void:
	growth_system.planner = growth_planner
	growth_input_controller.planner = growth_planner
	growth_input_controller.mode_changed.connect(hud.show_growth_mode)
	growth_input_controller.preview_changed.connect(hud.show_growth_preview)
	growth_input_controller.status_changed.connect(hud.show_growth_status)
	growth_input_controller.notice.connect(hud.show_notice)
	growth_supply_system.supply_changed.connect(hud.show_growth_supply)
	growth_supply_system.notice.connect(hud.show_notice)
	hud.growth_mode_requested.connect(_on_growth_mode_requested)
	hud.growth_pause_requested.connect(_on_growth_pause_requested)
	hud.growth_cancel_requested.connect(_on_growth_cancel_requested)
	hud.show_growth_status(growth_system.get_task_snapshot())
	hud.show_growth_supply({
		"in_transit": growth_supply_system.get_in_transit_count(),
		"combat_reserve": growth_supply_system.get_combat_reserve(),
		"available": growth_supply_system.get_available_growth_nutrition(),
	})


func _input(event: InputEvent) -> void:
	# 只让模式意图提前退出修复选择；鼠标仍在 unhandled 阶段处理，避免吞掉 HUD 按钮。
	if is_instance_valid(repair_input_controller) and event is InputEventKey and event.pressed \
			and not event.echo and repair_input_controller.is_selecting():
		for action: StringName in [&"growth_mode", &"remote_cultivation_mode", &"cultivate_attack", &"connection_mode"]:
			if event.is_action_pressed(action):
				repair_input_controller.exit_selection_mode()
				break

	if not is_instance_valid(growth_input_controller) or mother_core.health <= 0:
		return
	if event is InputEventKey and event.echo:
		return
	if event.is_action_pressed("cultivate_attack"):
		_on_cultivation_requested()
		get_viewport().set_input_as_handled()
		return
	# P/X 总是面向明确选择的队列目标；不能再落入“最后一个内部任务”的快捷操作。
	if event.is_action_pressed("growth_pause"):
		_on_growth_pause_requested()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("growth_cancel"):
		_on_growth_cancel_requested()
		get_viewport().set_input_as_handled()
		return
	# 放置先于场景拾取；HUD 区域的左键交给 GUI，避免拦截按钮。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var point: Vector2 = get_canvas_transform().affine_inverse() * event.position
		if not growth_input_controller.placement_bounds.has_point(point) \
				or Rect2(800, 234, 376, 120).has_point(point) \
				or construction_queue_controller.is_pointer_over_panel(event.position):
			return
	if not growth_input_controller.is_placing() and not cultivation_input_controller.is_remote_placing() \
			and not connection_input_controller.is_placing() and not repair_input_controller.is_selecting() \
			and construction_queue_controller.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if connection_input_controller.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if is_instance_valid(cultivation_input_controller) and cultivation_input_controller.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if growth_input_controller.handle_input(event):
		get_viewport().set_input_as_handled()


func _on_growth_mode_requested() -> void:
	if mother_core.health <= 0:
		return
	cultivation_input_controller.exit_remote_placement_mode()
	if growth_input_controller.is_placing():
		growth_input_controller.exit_placement_mode()
	else:
		growth_input_controller.enter_placement_mode()


func _on_growth_pause_requested() -> void:
	if mother_core.health <= 0:
		return
	var selected_id: String = String(construction_coordinator.get_snapshot().get("selected_id", ""))
	if not selected_id.is_empty():
		var request: Dictionary = construction_coordinator.get_request(selected_id)
		if request.get("state") == &"paused":
			construction_coordinator.resume_request(selected_id)
		else:
			construction_coordinator.pause_request(selected_id)
	elif _selected_local_cultivation():
		var snapshot: Dictionary = remote_cultivation_system.get_request_snapshot() \
			if remote_cultivation_system.has_active_request() else cultivation_system.get_task_snapshot()
		if snapshot.state == &"paused":
			cultivation_input_controller.resume_cultivation()
		else:
			cultivation_input_controller.pause_cultivation()
	else:
		hud.show_notice("请先选择队列目标，或选择正在就地培育的菌结")


func _on_growth_cancel_requested() -> void:
	if mother_core.health > 0:
		var selected_id: String = String(construction_coordinator.get_snapshot().get("selected_id", ""))
		if not selected_id.is_empty():
			construction_coordinator.cancel_request(selected_id)
		elif _selected_local_cultivation():
			cultivation_input_controller.cancel_cultivation()
		else:
			hud.show_notice("请先选择队列目标，或选择正在就地培育的菌结")


func _selected_local_cultivation() -> bool:
	if not _local_cultivation_control_selected or not is_instance_valid(selected_node) \
			or not String(construction_coordinator.get_snapshot().get("active_id", "")).is_empty():
		return false
	if remote_cultivation_system.has_active_request():
		return remote_cultivation_system.get_request_snapshot().get("endpoint") == selected_node
	return cultivation_system.has_active_task() and cultivation_system.get_task_snapshot().get("host") == selected_node


func _connect_construction_queue() -> void:
	construction_coordinator.notice.connect(hud.show_notice)
	construction_queue_controller.notice.connect(hud.show_notice)
	construction_coordinator.changed.connect(_on_construction_queue_changed)
	construction_coordinator.organ_matured.connect(_on_worker_organ_matured)
	mother_core.budget_changed.connect(_on_construction_budget_changed)
	_on_construction_queue_changed(construction_coordinator.get_snapshot())
	construction_queue_controller.refresh()


func _on_worker_organ_matured(_construction_id: String, host: HyphaNode,
		organ: AttackOrgan, new_weapon: SporeWeapon) -> void:
	_on_organ_matured(0, host, organ, new_weapon)


func _on_construction_budget_changed(_budget: Dictionary) -> void:
	if construction_coordinator.multi_worker_enabled:
		_on_construction_queue_changed(construction_coordinator.get_snapshot())


func _on_construction_queue_changed(snapshot: Dictionary) -> void:
	# 外部目标取得控制焦点后，终态清空选择不能自动把下一次 P/X 转回旧的本地 C。
	if not String(snapshot.get("selected_id", "")).is_empty():
		_local_cultivation_control_selected = false
	var display: Dictionary = snapshot.duplicate(true)
	display["local_control_selected"] = _local_cultivation_control_selected
	display["multi_worker_enabled"] = construction_coordinator.multi_worker_enabled
	if construction_coordinator.multi_worker_enabled:
		display["resources"] = construction_coordinator.get_resource_snapshot()
		display["combat_reserve"] = growth_supply_system.get_combat_reserve()
		display["available"] = growth_supply_system.get_available_growth_nutrition()
	hud.show_construction_queue(display)
	if construction_coordinator.multi_worker_enabled and is_instance_valid(cultivation_input_controller):
		cultivation_input_controller.refresh()


func _process(_delta: float) -> void:
	# 边端点仍可由现有 demo 直接改动；每帧读取实时连通性，避免覆盖使用旧快照。
	_sync_fungal_sources()
	var waiting: int = 0
	var blocked: int = 0
	for path: String in ["Packets", "GrowthPackets", "CultivationPackets", "RecoveryPackets", "ReturnPackets", "RepairPackets"]:
		for packet: Node in get_node("World/" + path).get_children():
			if not packet.is_queued_for_deletion() and (packet is NutrientPacket or packet is RemainsPacket):
				var state: StringName = packet.get_transport_snapshot().get("state", &"idle")
				waiting += 1 if state == &"waiting" else 0
				blocked += 1 if state == &"blocked" else 0
	hud.show_transport_states(waiting, blocked)
	if is_instance_valid(digestive_organ) and not digestive_organ.is_queued_for_deletion():
		hud.show_digestive_chambers(digestive_organ.get_digestion_snapshot())


func _register_initial_network() -> void:
	network_system.register_node(mother_core, true)
	for child in hypha_nodes.get_children():
		_register_network_node(child)
	for child in hypha_edges.get_children():
		_register_network_edge(child)
	hypha_nodes.child_entered_tree.connect(_register_network_node)
	hypha_nodes.child_exiting_tree.connect(_unregister_network_node)
	hypha_edges.child_entered_tree.connect(_register_network_edge)
	hypha_edges.child_exiting_tree.connect(_unregister_network_edge)
	_sync_fungal_sources()


func _register_network_node(node: Node) -> void:
	if node is Node2D:
		network_system.register_node(node)
		if node is HyphaNode and not node.selection_requested.is_connected(_select_node):
			node.selection_requested.connect(_select_node)
		if not node.child_entered_tree.is_connected(_on_colony_child_entered):
			node.child_entered_tree.connect(_on_colony_child_entered)
			node.child_exiting_tree.connect(_on_colony_child_exiting)
		for child in node.get_children():
			_on_colony_child_entered(child)


func _unregister_network_node(node: Node) -> void:
	for child in node.get_children():
		_on_colony_child_exiting(child)
	if node == selected_node:
		_select_node(null)
	if node is HyphaNode and node.selection_requested.is_connected(_select_node):
		node.selection_requested.disconnect(_select_node)
	if node.child_entered_tree.is_connected(_on_colony_child_entered):
		node.child_entered_tree.disconnect(_on_colony_child_entered)
		node.child_exiting_tree.disconnect(_on_colony_child_exiting)
	if is_instance_valid(network_system) and node is Node2D:
		network_system.unregister_node(node)


func _on_colony_child_entered(child: Node) -> void:
	if child is AttackOrgan:
		supply_system.register_organ(child)
		var callback := _on_organ_selection_requested.bind(child)
		if not child.selection_requested.is_connected(callback):
			child.selection_requested.connect(callback)
		if not child.inventory_changed.is_connected(_on_organ_inventory_changed):
			child.inventory_changed.connect(_on_organ_inventory_changed)
		_refresh_inventory_hud()
	elif child is SporeWeapon:
		_refresh_weapon_ranges.call_deferred()


func _on_colony_child_exiting(child: Node) -> void:
	if child is AttackOrgan:
		var callback := _on_organ_selection_requested.bind(child)
		if child.selection_requested.is_connected(callback):
			child.selection_requested.disconnect(callback)
		if child.inventory_changed.is_connected(_on_organ_inventory_changed):
			child.inventory_changed.disconnect(_on_organ_inventory_changed)
		if is_instance_valid(supply_system):
			supply_system.unregister_organ(child)
		_refresh_inventory_hud()


func get_weapons() -> Array[SporeWeapon]:
	var weapons: Array[SporeWeapon] = []
	if not is_instance_valid(hypha_nodes):
		return weapons
	for node in hypha_nodes.get_children():
		for child in node.get_children():
			if child is SporeWeapon and not child.is_queued_for_deletion():
				weapons.append(child)
	return weapons


func _get_selected_organ() -> AttackOrgan:
	var organs: Array[AttackOrgan] = []
	if is_instance_valid(supply_system):
		organs = supply_system.get_registered_organs()
	if is_instance_valid(selected_node):
		for child in selected_node.get_children():
			if child is AttackOrgan and organs.has(child):
				return child
		return null
	if is_instance_valid(attack_organ) and organs.has(attack_organ):
		return attack_organ
	if not organs.is_empty():
		return organs[0]
	return null


func _on_organ_inventory_changed(_stored: int, _incoming: int, _capacity: int) -> void:
	_refresh_inventory_hud()


func _refresh_inventory_hud() -> void:
	if not is_instance_valid(hud) or not is_instance_valid(supply_system):
		return
	var organs := supply_system.get_registered_organs()
	var stored: int = 0
	var incoming: int = 0
	var capacity: int = 0
	for organ in organs:
		stored += organ.nutrition
		incoming += organ.incoming_nutrition
		capacity += organ.capacity
	hud.show_colony_inventory(stored, incoming, capacity, organs.size())
	var selected := _get_selected_organ()
	if is_instance_valid(selected) and organs.has(selected):
		hud.show_organ_inventory(selected.nutrition, selected.incoming_nutrition, selected.capacity)
	else:
		hud.show_organ_inventory(0, 0, 0)


func _refresh_weapon_ranges() -> void:
	for current_weapon in get_weapons():
		if current_weapon.is_node_ready() and is_instance_valid(current_weapon.range_outline):
			current_weapon.set_range_visible(current_weapon.get_parent() == selected_node)


func _register_network_edge(edge: Node) -> void:
	if edge is HyphaEdge:
		network_system.register_edge(edge)
		if is_instance_valid(main_vein_system) and not _is_tearing_down:
			main_vein_system.register_edge(edge as HyphaEdge)


func _unregister_network_edge(edge: Node) -> void:
	if is_instance_valid(network_system) and edge is HyphaEdge:
		network_system.unregister_edge(edge)


func _sync_fungal_sources() -> void:
	var sources: Array[Dictionary] = []
	var core_alive := is_instance_valid(mother_core) and mother_core.health > 0
	for node in network_system.get_registered_nodes():
		# 临时生长尖端可参与网络，但本阶段只有母核和菌结提供菌域。
		if node == mother_core or node is HyphaNode:
			sources.append({
				"node": node,
				"kind": &"core" if node == mother_core else &"junction",
				"connected": core_alive and network_system.is_available_connected_to_core(node),
			})
	fungal_field.set_sources(sources)


func _unhandled_input(event: InputEvent) -> void:
	var viewport: Viewport = get_viewport()
	if repair_input_controller.handle_input(event):
		if is_instance_valid(viewport):
			viewport.set_input_as_handled()
		return
	if event.is_action_pressed("traffic_recovery_demo"):
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file("res://scenes/levels/traffic_recovery_demo.tscn")
		return
	elif event.is_action_pressed("cancel_selection"):
		_select_node(null)
	elif event.is_action_pressed("debug_damage_core"):
		mother_core.take_damage(30)
	elif event.is_action_pressed("request_supply"):
		var organ := _get_selected_organ()
		if is_instance_valid(organ):
			supply_system.request_supply(organ)
		else:
			hud.show_notice("请选择一个攻击器官所在的菌结")
	elif event.is_action_pressed("debug_consume_nutrition"):
		var organ := _get_selected_organ()
		if is_instance_valid(organ) and organ.consume_nutrition():
			hud.show_notice("器官消耗 1 点营养；库存不足时会自动补给")
		else:
			hud.show_notice("器官库存为空，等待供养")
	elif event.is_action_pressed("restart_level"):
		get_viewport().set_input_as_handled()
		_stop_main_vein_growth()
		_stop_all_digestion()
		construction_coordinator.reset()
		repair_input_controller.exit_selection_mode()
		repair_supply_system.reset(true)
		repair_system.reset()
		supply_system.reset(true)
		recycling_system.reset(true)
		connection_input_controller.exit_placement_mode()
		connection_system.reset()
		growth_input_controller.exit_placement_mode()
		cultivation_input_controller.exit_remote_placement_mode()
		remote_cultivation_system.reset()
		cultivation_supply_system.reset()
		cultivation_system.reset()
		growth_supply_system.reset()
		nutrition_return_system.reset()
		traffic_system.reset()
		main_vein_system.reset()
		colony_progress.reset()
		for organ: DigestiveOrgan in get_digestive_organs():
			organ.reset()
		get_tree().reload_current_scene()
		return
	else:
		return
	get_viewport().set_input_as_handled()


func _select_node(node: HyphaNode) -> void:
	if node != null and is_instance_valid(repair_input_controller) and repair_input_controller.is_selecting():
		return
	if is_instance_valid(selected_node) and is_instance_valid(selected_node.selection_ring):
		selected_node.set_selected(false)

	selected_node = node
	_local_cultivation_control_selected = is_instance_valid(node)
	if is_instance_valid(node) and is_instance_valid(construction_coordinator):
		var construction_id: String = ""
		if construction_coordinator.multi_worker_enabled:
			construction_id = String(construction_coordinator.get_cultivation_selection(node).get("construction_id", ""))
		construction_coordinator.select_request(construction_id)
	if is_instance_valid(selected_node):
		selected_node.set_selected(true)
		if is_instance_valid(hud):
			hud.show_selection(selected_node.display_name)
	else:
		if is_instance_valid(hud):
			hud.show_selection("")
	_refresh_weapon_ranges()
	_refresh_inventory_hud()
	if is_instance_valid(cultivation_input_controller):
		cultivation_input_controller.select_node(selected_node)
	if is_instance_valid(construction_coordinator):
		_on_construction_queue_changed(construction_coordinator.get_snapshot())


func _on_organ_selection_requested(organ: AttackOrgan) -> void:
	if is_instance_valid(organ):
		_select_node(organ.get_parent() as HyphaNode)


func _on_mother_core_depleted() -> void:
	_stop_main_vein_growth()
	_stop_all_digestion()
	construction_coordinator.reset()
	enemy_spawner.stop_spawning()
	repair_input_controller.exit_selection_mode()
	repair_supply_system.reset(true)
	repair_system.reset()
	repair_system.process_mode = Node.PROCESS_MODE_DISABLED
	repair_supply_system.process_mode = Node.PROCESS_MODE_DISABLED
	repair_input_controller.process_mode = Node.PROCESS_MODE_DISABLED
	supply_system.reset(true)
	recycling_system.reset(true)
	connection_input_controller.exit_placement_mode()
	connection_system.reset()
	connection_system.process_mode = Node.PROCESS_MODE_DISABLED
	connection_input_controller.process_mode = Node.PROCESS_MODE_DISABLED
	growth_input_controller.exit_placement_mode()
	cultivation_input_controller.exit_remote_placement_mode()
	remote_cultivation_system.reset()
	cultivation_supply_system.reset()
	cultivation_system.process_mode = Node.PROCESS_MODE_DISABLED
	cultivation_supply_system.process_mode = Node.PROCESS_MODE_DISABLED
	cultivation_input_controller.process_mode = Node.PROCESS_MODE_DISABLED
	growth_supply_system.reset()
	nutrition_return_system.reset()
	traffic_system.reset()
	traffic_system.process_mode = Node.PROCESS_MODE_DISABLED
	nutrition_return_system.process_mode = Node.PROCESS_MODE_DISABLED
	growth_system.process_mode = Node.PROCESS_MODE_DISABLED
	growth_supply_system.process_mode = Node.PROCESS_MODE_DISABLED
	growth_input_controller.process_mode = Node.PROCESS_MODE_DISABLED
	$World.process_mode = Node.PROCESS_MODE_DISABLED
	supply_system.process_mode = Node.PROCESS_MODE_DISABLED
	recycling_system.process_mode = Node.PROCESS_MODE_DISABLED
	hud.show_battle_result(false)
	hud.show_notice("母核生命值归零；按 R 重新开始")


func _on_wave_finished() -> void:
	if mother_core.health > 0:
		hud.show_battle_result(true)


func _on_digestive_selection_requested() -> void:
	_select_node(digestive_organ.get_parent() as HyphaNode)


func _on_remains_digested(_nutrition: int) -> void:
	hud.show_production(digestive_organ.digested_count)
