class_name RepairInputController
extends Node2D
## 关卡显式转交维修输入；只选边、发布报价和操作任务，不扣款或恢复生命。

signal mode_changed(active: bool)
signal selection_changed(edge: HyphaEdge)
signal preview_changed(snapshot: Dictionary)
signal status_changed(snapshot: Dictionary)
signal notice(message: String)

const EDGE_PICK_RADIUS: float = 16.0
const DISTANCE_EPSILON: float = 0.00001
const SELECTED_COLOR: Color = Color(1.0, 0.85, 0.38, 0.85)
const HEALTHY_COLOR: Color = Color(0.55, 0.95, 0.72, 0.8)
const WORK_POINT_COLOR: Color = Color(0.5, 0.9, 1.0, 0.95)

@export var repair_system: RepairSystem:
	set(value):
		_disconnect_repair_system()
		repair_system = value
		if is_node_ready():
			_connect_repair_system()
@export var repair_supply_system: RepairSupplySystem:
	set(value):
		_disconnect_supply_system()
		repair_supply_system = value
		if is_node_ready():
			_connect_supply_system()
@export var network_system: NetworkSystem:
	set(value):
		_disconnect_network_system()
		network_system = value
		if is_node_ready():
			_connect_network_system()
@export var placement_bounds: Rect2 = Rect2(0, 230, 1200, 410)

var _selecting: bool = false
var _selected_edge: HyphaEdge = null
var _last_preview: Dictionary = {}
var _bound_repair_system: RepairSystem = null
var _bound_supply_system: RepairSupplySystem = null
var _bound_network_system: NetworkSystem = null
var _bound_edge: HyphaEdge = null
var _publishing_status: bool = false


func _ready() -> void:
	z_index = 20
	set_process(false)
	_connect_services()
	_connect_services.call_deferred()
	_publish_preview()
	_publish_status()


func _exit_tree() -> void:
	_disconnect_selected_edge()
	_disconnect_repair_system()
	_disconnect_supply_system()
	_disconnect_network_system()
	_selected_edge = null
	_selecting = false


func _process(_delta: float) -> void:
	if _selected_edge != null and not _is_selectable_edge(_selected_edge):
		_clear_selection()
	queue_redraw()


func _draw() -> void:
	var edge: HyphaEdge = get_selected_edge()
	if edge == null or not global_transform.is_finite() \
			or is_zero_approx(global_transform.determinant()):
		return
	# 标记使用世界坐标，控制器可放在任意带变换的 Systems 下。
	draw_set_transform_matrix(global_transform.affine_inverse())
	var first: Vector2 = edge.start_node.global_position
	var second: Vector2 = edge.end_node.global_position
	var health: Dictionary = edge.get_health_snapshot()
	var color: Color = SELECTED_COLOR if bool(health.get("damaged", false)) else HEALTHY_COLOR
	# 选择高亮也跟随真实线宽，避免固定粗线遮住主脉逐级成长的形态。
	var highlighted_width: float = float(edge.get_vein_snapshot().get("width", 6.0)) + 3.0
	draw_line(first, second, color, highlighted_width, true)
	draw_circle(first, 8.0, color, false, 2.0, true)
	draw_circle(second, 8.0, color, false, 2.0, true)
	var preview: Dictionary = get_preview()
	var point: Node2D = preview.get("repair_point") as Node2D
	if _is_live_node(point):
		draw_circle(point.global_position, 13.0, WORK_POINT_COLOR, false, 2.0, true)
	var caption: String = "HP %.1f / %.1f | %d 营养" % [
		float(health.get("health", 0.0)), float(health.get("max_health", 0.0)),
		int(preview.get("estimated_cost", 0)),
	]
	draw_string(ThemeDB.fallback_font, first.lerp(second, 0.5) + Vector2(10, -12),
		caption, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, color)


func _on_task_changed(_snapshot: Dictionary) -> void:
	# 不采用通知内的旧任务；reset 后迟到的信号只能重读当前身份。
	_publish_preview()
	_publish_status()


func _on_supply_changed(_snapshot: Dictionary) -> void:
	_publish_status()


func _on_network_changed() -> void:
	if _selected_edge != null and not _is_selectable_edge(_selected_edge):
		_clear_selection()
	else:
		_publish_preview()
	_publish_status()


func _on_selected_health_changed(_current: float, _maximum: float) -> void:
	_publish_preview()
	_publish_status()


func _on_selected_tree_exiting() -> void:
	_clear_selection()


func enter_selection_mode() -> bool:
	_connect_services()
	var error: String = _configuration_error()
	if not error.is_empty():
		notice.emit(error)
		return false
	if not _selecting:
		_selecting = true
		set_process(true)
		mode_changed.emit(true)
	_publish_preview()
	notice.emit("左键选择菌丝；J 开始维修，K 暂停 / 继续，Backspace 取消维修；Esc / 右键退出选择")
	return true


func exit_selection_mode() -> void:
	if not _selecting:
		return
	_selecting = false
	set_process(get_selected_edge() != null)
	mode_changed.emit(false)
	_publish_preview()


func is_selecting() -> bool:
	return _selecting


func select_edge(edge: HyphaEdge) -> bool:
	if not _selecting:
		notice.emit("按 F 进入维修选择")
		return false
	if not _is_selectable_edge(edge):
		_publish_failure(&"invalid_edge", "请选择当前网络中的有效菌丝")
		return false
	if _selected_edge != edge:
		_disconnect_selected_edge()
		_selected_edge = edge
		_bound_edge = edge
		edge.health_changed.connect(_on_selected_health_changed)
		edge.tree_exiting.connect(_on_selected_tree_exiting)
		selection_changed.emit(edge)
	_publish_preview()
	notice.emit(String(_last_preview.get("message", "")))
	return true


func select_at(world_position: Vector2) -> bool:
	if not _selecting:
		notice.emit("按 F 进入维修选择")
		return false
	if not world_position.is_finite():
		_publish_failure(&"invalid_coordinates", "选择坐标必须有限")
		return false
	if not placement_bounds.has_point(world_position):
		_publish_failure(&"outside_bounds", "请在可生长区域内选择菌丝")
		return false
	var edge: HyphaEdge = _edge_at(world_position)
	if edge == null:
		_publish_failure(&"edge_required", "请点击菌丝线段附近")
		return false
	return select_edge(edge)


func get_selected_edge() -> HyphaEdge:
	return _selected_edge if _is_selectable_edge(_selected_edge) else null


func get_preview() -> Dictionary:
	return _make_preview().duplicate(true)


func request_repair() -> int:
	_connect_services()
	var error: String = _configuration_error()
	if not error.is_empty():
		_publish_failure(&"invalid_configuration", error)
		return 0
	var edge: HyphaEdge = get_selected_edge()
	if edge == null:
		_publish_failure(&"edge_required", "请先按 F 并选择受损菌丝")
		return 0
	var preview: Dictionary = repair_system.preview_repair(edge)
	if not bool(preview.get("valid", false)):
		_publish_preview()
		notice.emit(_describe_preview(preview))
		return 0
	var task_id: int = repair_system.request_repair(edge)
	_publish_preview()
	_publish_status()
	if task_id > 0:
		var task: Dictionary = repair_system.get_task_snapshot()
		notice.emit("维修任务 #%d 已确认，HP %.1f / %.1f，预计 %d 营养；%s" % [
			task_id, float(task.get("health", 0.0)), float(task.get("max_health", 0.0)),
			int(task.get("estimated_total_cost", preview.get("estimated_cost", 0))),
			_describe_access(task),
		])
	else:
		notice.emit("维修请求未接受；请重新确认所选菌丝与当前维修任务")
	return task_id


func toggle_pause() -> bool:
	if not _is_live_node(repair_system) or not repair_system.has_active_task():
		notice.emit("当前没有可暂停或继续的维修任务")
		return false
	var snapshot: Dictionary = repair_system.get_task_snapshot()
	var was_paused: bool = snapshot.get("state") == &"paused"
	var changed: bool = repair_system.resume_task() if was_paused else repair_system.pause_task()
	if changed:
		_publish_status()
		notice.emit("维修已继续" if was_paused else "维修已暂停，已付费运输和已恢复生命保留")
	return changed


func cancel_repair() -> bool:
	if not _is_live_node(repair_system) or not repair_system.has_active_task():
		notice.emit("当前没有可取消的维修任务")
		return false
	var changed: bool = repair_system.cancel_task()
	if changed:
		_publish_preview()
		_publish_status()
		notice.emit("维修已取消，已恢复生命保留；未消耗营养由维修供养系统退回")
	return changed


## 唯一输入入口；关卡在原有 _unhandled_input 前调用，不另设全局处理器。
func handle_input(event: InputEvent) -> bool:
	if event == null or (event is InputEventKey and event.echo):
		return false
	if event.is_action_pressed("repair_mode"):
		if _selecting:
			exit_selection_mode()
		else:
			enter_selection_mode()
		return true
	if event.is_action_pressed("repair_request"):
		request_repair()
		return true
	if event.is_action_pressed("repair_pause"):
		toggle_pause()
		return true
	if event.is_action_pressed("repair_cancel"):
		cancel_repair()
		return true
	if not _selecting:
		return false
	if event.is_action_pressed("cancel_selection"):
		exit_selection_mode()
		return true
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			exit_selection_mode()
			return true
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				select_at(_mouse_world_position(event.position))
			return true
	return false


func _connect_services() -> void:
	_connect_repair_system()
	_connect_supply_system()
	_connect_network_system()


func _connect_repair_system() -> void:
	if not _is_live_node(repair_system) or _bound_repair_system == repair_system:
		return
	_bound_repair_system = repair_system
	repair_system.task_changed.connect(_on_task_changed)


func _disconnect_repair_system() -> void:
	if is_instance_valid(_bound_repair_system) \
			and _bound_repair_system.task_changed.is_connected(_on_task_changed):
		_bound_repair_system.task_changed.disconnect(_on_task_changed)
	_bound_repair_system = null


func _connect_supply_system() -> void:
	if not _is_live_node(repair_supply_system) or _bound_supply_system == repair_supply_system:
		return
	_bound_supply_system = repair_supply_system
	repair_supply_system.supply_changed.connect(_on_supply_changed)


func _disconnect_supply_system() -> void:
	if is_instance_valid(_bound_supply_system) \
			and _bound_supply_system.supply_changed.is_connected(_on_supply_changed):
		_bound_supply_system.supply_changed.disconnect(_on_supply_changed)
	_bound_supply_system = null


func _connect_network_system() -> void:
	if not _is_live_node(network_system) or _bound_network_system == network_system:
		return
	_bound_network_system = network_system
	network_system.network_changed.connect(_on_network_changed)


func _disconnect_network_system() -> void:
	if is_instance_valid(_bound_network_system) \
			and _bound_network_system.network_changed.is_connected(_on_network_changed):
		_bound_network_system.network_changed.disconnect(_on_network_changed)
	_bound_network_system = null


func _disconnect_selected_edge() -> void:
	if is_instance_valid(_bound_edge):
		if _bound_edge.health_changed.is_connected(_on_selected_health_changed):
			_bound_edge.health_changed.disconnect(_on_selected_health_changed)
		if _bound_edge.tree_exiting.is_connected(_on_selected_tree_exiting):
			_bound_edge.tree_exiting.disconnect(_on_selected_tree_exiting)
	_bound_edge = null


func _clear_selection() -> void:
	var had_selection: bool = _selected_edge != null
	_disconnect_selected_edge()
	_selected_edge = null
	set_process(_selecting)
	if had_selection:
		selection_changed.emit(null)
	_publish_preview()


func _configuration_error() -> String:
	if not _is_live_node(repair_system) or not _is_live_node(repair_supply_system) \
			or not _is_live_node(network_system):
		return "维修系统、维修供养与网络尚未配置"
	if repair_system.network_system != network_system \
			or repair_supply_system.repair_system != repair_system \
			or repair_supply_system.network_system != network_system:
		return "维修控制器与维修供养必须使用同一个维修系统和网络"
	return ""


func _make_preview() -> Dictionary:
	var edge: HyphaEdge = get_selected_edge()
	var snapshot: Dictionary = {
		"valid": false, "reason": &"edge_required", "edge": edge, "edge_id": 0,
		"health": 0.0, "max_health": 0.0, "missing_health": 0.0,
		"estimated_cost": 0, "repair_point": null, "supply_reachable": false,
	}
	var error: String = _configuration_error()
	if not error.is_empty():
		snapshot["reason"] = &"invalid_configuration"
	elif edge != null:
		snapshot = repair_system.preview_repair(edge).duplicate(true)
	# 确认后的工作点由任务固定；预览不重新选择任务的另一端。
	if edge != null and _is_live_node(repair_system):
		var task: Dictionary = repair_system.get_task_snapshot()
		if task.get("edge") == edge and repair_system.has_active_task():
			snapshot["repair_point"] = task.get("repair_point")
			snapshot["supply_reachable"] = task.get("supply_reachable", false)
			snapshot["wait_reason"] = task.get("wait_reason", &"")
	snapshot["selecting"] = _selecting
	snapshot["message"] = error if not error.is_empty() else _describe_preview(snapshot)
	snapshot["error"] = "" if bool(snapshot.get("valid", false)) else snapshot["message"]
	return snapshot


func _publish_preview() -> void:
	_last_preview = _make_preview()
	preview_changed.emit(_last_preview.duplicate(true))
	queue_redraw()


func _publish_failure(reason: StringName, message: String) -> void:
	_last_preview = _make_preview()
	_last_preview["valid"] = false
	_last_preview["reason"] = reason
	_last_preview["error"] = message
	_last_preview["message"] = message
	preview_changed.emit(_last_preview.duplicate(true))
	notice.emit(message)


func _publish_status() -> void:
	if _publishing_status or not _is_live_node(repair_system):
		return
	_publishing_status = true
	var snapshot: Dictionary = repair_system.get_task_snapshot().duplicate(true)
	if _is_live_node(repair_supply_system):
		snapshot["supply"] = repair_supply_system.get_supply_snapshot().duplicate(true)
	status_changed.emit(snapshot)
	_publishing_status = false


func _describe_preview(snapshot: Dictionary) -> String:
	var edge: HyphaEdge = snapshot.get("edge") as HyphaEdge
	if not _is_live_node(edge):
		return "按 F 并左键选择菌丝，预览生命和维修费用"
	var health: float = float(snapshot.get("health", 0.0))
	var maximum: float = float(snapshot.get("max_health", 0.0))
	var price: int = int(snapshot.get("estimated_cost", 0))
	var result: String = "HP %.1f / %.1f，预计 %d 营养；%s" % [
		health, maximum, price, _describe_access(snapshot),
	]
	if float(snapshot.get("missing_health", 0.0)) <= 0.0:
		result += "；菌丝健康，无需维修"
	elif _is_live_node(repair_system) and repair_system.has_active_task():
		result += "；已有维修任务，可用 K 暂停 / 继续，Backspace 取消"
	return result


func _describe_access(snapshot: Dictionary) -> String:
	var point: Node2D = snapshot.get("repair_point") as Node2D
	if not _is_live_node(point):
		return "等待可达工作点，当前不支付维修营养"
	if not bool(snapshot.get("supply_reachable", false)):
		return "工作点 %s 暂时断连，等待恢复" % point.name
	return "工作点 %s 可达" % point.name


func _edge_at(world_position: Vector2) -> HyphaEdge:
	if not _is_live_node(network_system):
		return null
	var best: HyphaEdge = null
	var best_distance: float = EDGE_PICK_RADIUS * EDGE_PICK_RADIUS
	for edge: HyphaEdge in network_system.get_registered_edges():
		if not _is_selectable_edge(edge):
			continue
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(
			world_position, edge.start_node.global_position, edge.end_node.global_position)
		var distance: float = world_position.distance_squared_to(closest)
		if distance > EDGE_PICK_RADIUS * EDGE_PICK_RADIUS:
			continue
		if best == null or distance < best_distance - DISTANCE_EPSILON \
				or (absf(distance - best_distance) <= DISTANCE_EPSILON \
				and edge.get_instance_id() < best.get_instance_id()):
			best = edge
			best_distance = distance
	return best


func _is_selectable_edge(candidate: Variant) -> bool:
	if not _is_live_node(candidate) or not candidate is HyphaEdge or not _is_live_node(network_system):
		return false
	var edge: HyphaEdge = candidate as HyphaEdge
	return network_system.is_edge_valid(edge) and _is_live_node(edge.start_node) \
		and _is_live_node(edge.end_node) and edge.start_node.global_position.is_finite() \
		and edge.end_node.global_position.is_finite()


func _mouse_world_position(viewport_position: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * viewport_position


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()
