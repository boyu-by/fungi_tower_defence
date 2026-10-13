class_name ColonyOperationsDemo
extends "res://scripts/terrain_threat_demo.gd"
## 第十阶段的可玩入口。所有按钮只提交原系统操作，不生成资源或跳过成熟。

var transplant_system: TransplantSystem
var _operations_panel: Panel
var _operations_status: Label
var _attack_choice: Button
var _stomach_choice: Button
var _cancel_transplant: Button
var _operation_view: Node2D
var _operation_mode: StringName = &""
var _retarget_id: String = ""
var _transplant_source: AttackOrgan
var _operation_preview: Dictionary = {}
var _operations_closing: bool = false
var _old_content_size := Vector2i(1200, 800)


func _ready() -> void:
	growth_planner = growth_planner.duplicate(true) as GrowthPlanner
	growth_planner.bounded_branches_enabled = true
	growth_planner.auto_join_enabled = true
	_old_content_size = get_window().content_scale_size
	get_window().content_scale_size = Vector2i(1200, 920)
	get_window().size = Vector2i(1200, 920)
	# 注册在 ledger 建立初始快照之前；本系统不创造任何初始资源。
	var material_packets := Node2D.new()
	material_packets.name = "TransplantPackets"
	$World.add_child(material_packets)
	var migrating := Node2D.new()
	migrating.name = "MigratingOrgans"
	$World.add_child(migrating)
	transplant_system = TransplantSystem.new()
	transplant_system.name = "TransplantSystem"
	transplant_system.mother_core = mother_core
	transplant_system.network_system = network_system
	transplant_system.traffic_system = traffic_system
	transplant_system.combat_supply_system = supply_system
	transplant_system.repair_system = repair_system
	transplant_system.cargo_passage_tracker = cargo_passage_tracker
	transplant_system.packet_container = material_packets
	transplant_system.migration_container = migrating
	$Systems.add_child(transplant_system)
	super._ready()
	construction_supply_scheduler.register_supply("transplant", transplant_system)
	level_stopping.connect(_close_operations)
	transplant_system.task_completed.connect(_on_transplant_completed)
	transplant_system.task_failed.connect(_on_transplant_failed)
	cultivation_input_controller.set_organ_kind(&"attack")
	_build_operations_panel()
	_operation_view = Node2D.new()
	_operation_view.name = "OperationRoutes"
	_operation_view.z_index = 50
	$World.add_child(_operation_view)
	_operation_view.draw.connect(_draw_operation_route)
	(hud.get_node("HelpLabel") as Label).text = "G 伸展 · B 远处种芽 · C 原位培育 · O 切换器官 · T 改向 · M 移植 · L 接合 · P 暂停 · X 取消 · R 重开 · F5–F10 各阶段"
	(hud.get_node("HelpLabel") as Label).add_theme_font_size_override("font_size", 14)
	hud.show_notice("第十阶段：G扩张→T改向；下方选胃囊后C/B培育；选成熟攻击器官M移植，真实付款6。")
	_refresh_operations_status()


func _exit_tree() -> void:
	_close_operations(&"scene_exit")
	get_window().content_scale_size = _old_content_size
	super._exit_tree()


func _process(delta: float) -> void:
	super._process(delta)
	if _operations_closing or not is_instance_valid(_operations_panel):
		return
	_refresh_operations_status()
	if is_instance_valid(_operation_view):
		_operation_view.queue_redraw()


func _input(event: InputEvent) -> void:
	if _operations_closing or not is_instance_valid(_operations_panel):
		super._input(event)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_O:
				choose_organ(&"attack" if cultivation_input_controller.selected_organ_kind == &"digestive" else &"digestive")
				get_viewport().set_input_as_handled()
				return
			KEY_T:
				begin_retarget()
				get_viewport().set_input_as_handled()
				return
			KEY_M:
				begin_transplant()
				get_viewport().set_input_as_handled()
				return
			KEY_Y:
				cancel_transplant_preparation()
				get_viewport().set_input_as_handled()
				return
			KEY_ESCAPE:
				if _operation_mode != &"":
					_end_operation_mode()
					get_viewport().set_input_as_handled()
					return
			KEY_G, KEY_B, KEY_L, KEY_F:
				_end_operation_mode()
	if event is InputEventMouse and _operations_panel.get_global_rect().has_point(event.position):
		return
	if _operation_mode != &"" and event is InputEventMouse:
		var point: Vector2 = get_canvas_transform().affine_inverse() * event.position
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_end_operation_mode()
			get_viewport().set_input_as_handled()
			return
		if _point_over_existing_panel(event.position) or not growth_input_controller.placement_bounds.has_point(point):
			return
		_update_operation_preview(point)
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			commit_operation_at(point)
		get_viewport().set_input_as_handled()
		return
	super._input(event)


func choose_organ(kind: StringName) -> void:
	cultivation_input_controller.set_organ_kind(kind)
	_refresh_operations_status()
	hud.show_notice("已选择胃囊：原位8营养全计结构；远处另付真实网络费用。" if kind == &"digestive" else "已选择攻击器官：原位12＝8结构＋4启动库存；远处另付网络费用。")


func begin_retarget() -> bool:
	var selected: String = String(construction_coordinator.get_snapshot().get("selected_id", ""))
	var request: Dictionary = construction_coordinator.get_request(selected)
	if request.is_empty() or request.get("kind") not in [&"growth", &"remote_cultivation"] \
			or request.get("state") in ConstructionQueue.TERMINAL_STATES or request.get("phase") == &"maturing":
		hud.show_notice("先点击队列中的 G/B 目标，再按 T；已进入成熟的器官不能改宿主。")
		return false
	_exit_other_placement()
	_retarget_id = selected
	_operation_mode = &"retarget"
	_sync_differentiation_presentation()
	_update_operation_preview(get_global_mouse_position())
	return true


func begin_transplant() -> bool:
	var organ: AttackOrgan = selected_node.get_organ_occupant() as AttackOrgan if is_instance_valid(selected_node) else null
	if organ == null or transplant_system.has_active_task():
		hud.show_notice("选中成熟攻击器官后按 M，再点击连通的空菌结；同时最多一项移植。")
		return false
	_exit_other_placement()
	_transplant_source = organ
	_operation_mode = &"transplant"
	_sync_differentiation_presentation()
	_operation_preview = {}
	_refresh_operations_status()
	return true


func commit_operation_at(point: Vector2) -> bool:
	if is_inside_tree() and get_tree().paused:
		hud.show_notice("全局暂停中：预览保留，恢复后重新确认。")
		return false
	_update_operation_preview(point)
	if not bool(_operation_preview.get("valid", false)):
		hud.show_notice(String(_operation_preview.get("error", "请选择合法的目标菌结。")))
		return false
	var accepted: bool = false
	if _operation_mode == &"retarget":
		accepted = construction_coordinator.retarget(_retarget_id, point)
	elif _operation_mode == &"transplant":
		accepted = transplant_system.request_transplant(_transplant_source, _node_near(point)) > 0
	if accepted:
		hud.show_notice("改向已接受：保留原编号、已付段和已形成网络。" if _operation_mode == &"retarget" else "目的地已预留：6营养送抵源器官后出发；准备阶段可按Y取消。")
		var was_transplant: bool = _operation_mode == &"transplant"
		_end_operation_mode()
		if was_transplant:
			_select_node(null)
	return accepted


func cancel_transplant_preparation() -> bool:
	if is_inside_tree() and get_tree().paused:
		hud.show_notice("全局暂停中：预览保留，恢复后重新确认。")
		return false
	var cancelled: bool = transplant_system.cancel_task()
	hud.show_notice("移植准备已取消，可返还材料按原账目结算。" if cancelled else "正式出发后目的地锁定，不能取消或换目标。")
	return cancelled


func _update_operation_preview(point: Vector2) -> void:
	if _operation_mode == &"retarget":
		_operation_preview = construction_coordinator.preview_retarget(_retarget_id, point)
		_operation_preview["target_position"] = point
	elif _operation_mode == &"transplant":
		_operation_preview = transplant_system.preview_transplant(_transplant_source, _node_near(point))
	_refresh_operations_status()
	_operation_view.queue_redraw()


func _node_near(point: Vector2) -> HyphaNode:
	var nearest: HyphaNode
	var distance: float = 25.0
	for node: Node2D in network_system.get_registered_nodes():
		if node is HyphaNode and node.global_position.distance_to(point) < distance:
			nearest = node
			distance = node.global_position.distance_to(point)
	return nearest


func _exit_other_placement() -> void:
	growth_input_controller.exit_placement_mode()
	cultivation_input_controller.exit_remote_placement_mode()
	connection_input_controller.exit_placement_mode()
	repair_input_controller.exit_selection_mode()


func _end_operation_mode() -> void:
	_operation_mode = &""
	_operation_preview = {}
	_retarget_id = ""
	_transplant_source = null
	_refresh_operations_status()
	if is_instance_valid(_operation_view):
		_operation_view.queue_redraw()


func _point_over_existing_panel(point: Vector2) -> bool:
	return hud.is_pointer_over_repair_panel(point) or hud.is_pointer_over_combat_demo_panel(point) \
		or hud.is_pointer_over_differentiation_panel(point) or hud.is_pointer_over_progression_hint(point) \
		or construction_queue_controller.is_pointer_over_panel(point)


func _build_operations_panel() -> void:
	_operations_panel = Panel.new()
	_operations_panel.name = "OperationsPanel"
	_operations_panel.position = Vector2(24, 808)
	_operations_panel.size = Vector2(1152, 102)
	var theme := Theme.new()
	theme.default_font = (hud.get_node("HelpLabel") as Label).get_theme_font("font")
	theme.default_font_size = 14
	_operations_panel.theme = theme
	hud.add_child(_operations_panel)
	_attack_choice = _operation_button("攻击器官 12", 10, choose_organ.bind(&"attack"))
	_stomach_choice = _operation_button("胃囊 8", 165, choose_organ.bind(&"digestive"))
	_operation_button("T 目标改向", 320, begin_retarget)
	_operation_button("M 移植 6", 475, begin_transplant)
	_cancel_transplant = _operation_button("Y 取消移植准备", 630, cancel_transplant_preparation)
	_operation_button("F10 第十阶段", 820, _reload_operations)
	_operations_status = Label.new()
	_operations_status.position = Vector2(12, 45)
	_operations_status.size = Vector2(1128, 52)
	_operations_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_operations_status.add_theme_font_size_override("font_size", 14)
	_operations_panel.add_child(_operations_status)


func _operation_button(text: String, x: float, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.position = Vector2(x, 8)
	button.size = Vector2(145, 30)
	button.pressed.connect(callback)
	_operations_panel.add_child(button)
	return button


func _refresh_operations_status() -> void:
	if not is_instance_valid(_operations_status):
		return
	var stomach_selected: bool = cultivation_input_controller.selected_organ_kind == &"digestive"
	_attack_choice.modulate = Color(0.6, 0.7, 0.65) if stomach_selected else Color(1, 0.88, 0.5)
	_stomach_choice.modulate = Color(1, 0.88, 0.5) if stomach_selected else Color(0.6, 0.7, 0.65)
	hud.remote_cultivation_button.text = "B 退出" if cultivation_input_controller.is_remote_placing() else ("B 种胃囊" if stomach_selected else "B 种攻击芽")
	var status: Dictionary = transplant_system.get_task_snapshot()
	_cancel_transplant.disabled = not bool(status.get("can_cancel", false))
	if _operation_mode == &"retarget":
		if bool(_operation_preview.get("valid", false)):
			var point: Vector2 = _operation_preview.get("effective_point", Vector2.ZERO)
			_operations_status.text = "改向预览 v%d｜生效点 (%.0f, %.0f) · %s｜剩余 %d → %d（%+d）\n青色线为新剩余路线；已形成网络和费用保留。左键确认，右键/Esc退出。" % [
				int(_operation_preview.get("plan_version", 1)), point.x, point.y,
				"当前已付段完成后" if bool(_operation_preview.get("deferred", false)) else "立即生效",
				int(_operation_preview.get("old_remaining_cost", 0)), int(_operation_preview.get("new_remaining_cost", 0)), int(_operation_preview.get("cost_delta", 0))]
		else:
			_operations_status.text = "改向：" + String(_operation_preview.get("error", "请指定新落点")) + "\n原任务保持有效；右键/Esc退出。"
	elif _operation_mode == &"transplant":
		_operations_status.text = "移植：点击连通、存活且空闲的成熟菌结。6营养送抵源器官后出发，到达后至少3秒展开。\n" + ("目的地有效 · 左键确认" if bool(_operation_preview.get("valid", false)) else String(_operation_preview.get("reason", "选择目标菌结")))
	else:
		var names: Dictionary = {&"idle": "无", &"preparing": "准备供养", &"waiting": "等待", &"migrating": "沿菌丝迁移", &"unfolding": "重新展开", &"completed": "完成", &"cancelled": "已取消", &"failed": "已终止"}
		var state: StringName = status.get("state", &"idle")
		var count: int = get_digestive_organs().size()
		_operations_status.text = "培育类型：%s · C原位 / B远处｜胃囊 %d处独立容量、共用回收和绿色回流｜尸体地面暴露55秒腐坏\n移植：%s · 2通行单位 · 不重置生命/弹药/分化｜休眠：射程内12秒无活敌，接近立即唤醒。" % [
			"胃囊（8结构）" if stomach_selected else "攻击（8结构＋4启动库存）", count, names.get(state, String(state))]
		if transplant_system.has_active_task():
			var reason_names: Dictionary = {&"nutrition": "等待材料", &"in_transit": "材料在途", &"queued": "FIFO排队", &"no_route": "断路等候", &"withered": "等待菌结恢复", &"disconnected": "等待接通", &"edge_closed": "菌丝停运", &"": "正常推进"}
			_operations_status.text = "移植 #%d · %s · %s｜费用缓存%d/6 · 在途%d · 已消费%d
目的地已锁定 · 2单位共用FIFO · 展开 %.1f/3.0秒；准备阶段可Y取消，出发后保留同一器官。" % [
				int(status.get("task_id", 0)), names.get(state, String(state)), reason_names.get(status.get("wait_reason"), String(status.get("wait_reason", ""))),
				int(status.get("buffered_nutrition", 0)), int(status.get("in_transit_nutrition", 0)), int(status.get("consumed_nutrition", 0)), float(status.get("effective_time", 0.0))]


func _draw_operation_route() -> void:
	var color := Color(0.32, 0.95, 0.84, 0.9)
	if _operation_mode == &"retarget" and bool(_operation_preview.get("valid", false)):
		var plan: Dictionary = _operation_preview.get("plan", {})
		for segment: Dictionary in plan.get("segments", []):
			_operation_view.draw_line(segment["start_position"], segment["end_position"], color, 3.0, true)
		var effective: Vector2 = _operation_preview.get("effective_point", Vector2.ZERO)
		_operation_view.draw_circle(effective, 10, Color(1.0, 0.65, 0.3), false, 3, true)
	elif _operation_mode == &"transplant":
		var destination: HyphaNode = _operation_preview.get("destination") as HyphaNode
		if is_instance_valid(destination):
			_operation_view.draw_circle(destination.global_position, 23, color, false, 3, true)
		var route: NetworkRoute = _operation_preview.get("route") as NetworkRoute
		if route != null:
			for segment: NetworkRoute.Segment in route.segments:
				_operation_view.draw_line(segment.start_node.global_position, segment.end_node.global_position, color, 3, true)

	elif transplant_system.has_active_task():
		var task: Dictionary = transplant_system.get_task_snapshot()
		var destination: HyphaNode = task.get("destination") as HyphaNode
		if is_instance_valid(destination):
			_operation_view.draw_circle(destination.global_position, 23, Color(0.98, 0.75, 0.36), false, 3, true)
		var route: NetworkRoute = task.get("route") as NetworkRoute
		if route != null:
			for segment: NetworkRoute.Segment in route.segments:
				if is_instance_valid(segment.start_node) and is_instance_valid(segment.end_node):
					_operation_view.draw_line(segment.start_node.global_position, segment.end_node.global_position, Color(color, 0.4), 2, true)


func _close_operations(_reason: StringName) -> void:
	if _operations_closing:
		return
	_operations_closing = true
	_operation_mode = &""
	if is_instance_valid(transplant_system):
		transplant_system.stop()
		if is_instance_valid(construction_supply_scheduler):
			construction_supply_scheduler.unregister_supply(transplant_system)


func _reload_operations() -> void:
	_announce_level_stopping(&"restart")
	get_tree().reload_current_scene()


func _sync_differentiation_presentation() -> void:
	super._sync_differentiation_presentation()
	if _operation_mode != &"" and is_instance_valid(differentiation_input_controller):
		differentiation_input_controller.set_interaction_suspended(true)


func _on_transplant_completed(_task_id: int) -> void:
	if not _operations_closing:
		hud.show_notice("移植展开完成：原器官已就位，生命、弹药与分化保留；敌人接近即可唤醒战斗。")


func _on_transplant_failed(_task_id: int, reason: StringName) -> void:
	if not _operations_closing:
		var reasons: Dictionary = {&"organ_destroyed": "本体被毁", &"destination_removed": "目的地被永久移除", &"transport_lost": "运输终止"}
		hud.show_notice("移植已终止：%s，预留与损失已按原身份结算。" % reasons.get(reason, String(reason)))
