class_name RepairInputController
extends Node2D
## 关卡显式转交维修输入；选择网络组织、发布报价和操作任务，不扣款或恢复生命。

signal mode_changed(active: bool)
signal selection_changed(target: Node2D)
signal preview_changed(snapshot: Dictionary)
signal status_changed(snapshot: Dictionary)
signal notice(message: String)

const EDGE_PICK_RADIUS: float = 16.0
const TISSUE_PICK_RADIUS: float = 24.0
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
var _selected_target: Node2D = null
var _last_preview: Dictionary = {}
var _bound_repair_system: RepairSystem = null
var _bound_supply_system: RepairSupplySystem = null
var _bound_network_system: NetworkSystem = null
var _bound_target: Node2D = null
var _publishing_status: bool = false


func _ready() -> void:
	z_index = 20
	set_process(false)
	_connect_services()
	_connect_services.call_deferred()
	_publish_preview()
	_publish_status()


func _exit_tree() -> void:
	_disconnect_selected_target()
	_disconnect_repair_system()
	_disconnect_supply_system()
	_disconnect_network_system()
	_selected_target = null
	_selecting = false


func _process(_delta: float) -> void:
	if _selected_target != null and not _is_selectable_target(_selected_target):
		_clear_selection()
	queue_redraw()


func _draw() -> void:
	var target: Node2D = get_selected_target()
	if target == null or not global_transform.is_finite() \
			or is_zero_approx(global_transform.determinant()):
		return
	draw_set_transform_matrix(global_transform.affine_inverse())
	var health: Dictionary = target.call("get_health_snapshot")
	var color: Color = SELECTED_COLOR if bool(health.get("damaged", false)) else HEALTHY_COLOR
	var center: Vector2 = _tissue_pick_point(target)
	if target is HyphaEdge:
		var first: Vector2 = target.start_node.global_position
		var second: Vector2 = target.end_node.global_position
		var highlighted_width: float = float(target.get_vein_snapshot().get("width", 6.0)) + 3.0
		draw_line(first, second, color, highlighted_width, true)
		draw_circle(first, 8.0, color, false, 2.0, true)
		draw_circle(second, 8.0, color, false, 2.0, true)
		center = first.lerp(second, 0.5)
	else:
		draw_circle(center, TISSUE_PICK_RADIUS + 4.0, color, false, 2.0, true)
	var preview: Dictionary = get_preview()
	var point: Node2D = preview.get("repair_point") as Node2D
	if _is_live_node(point):
		draw_circle(point.global_position, 13.0, WORK_POINT_COLOR, false, 2.0, true)
	var caption: String = "HP %.1f / %.1f | %d 营养" % [
		float(health.get("health", 0.0)), float(health.get("max_health", 0.0)),
		int(preview.get("estimated_cost", 0)),
	]
	draw_string(ThemeDB.fallback_font, center + Vector2(10, -12),
		caption, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, color)


func _on_task_changed(_snapshot: Dictionary) -> void:
	# 不采用通知内的旧任务；reset 后迟到的信号只能重读当前身份。
	_publish_preview()
	_publish_status()


func _on_supply_changed(_snapshot: Dictionary) -> void:
	_publish_status()


func _on_network_changed() -> void:
	if _selected_target != null and not _is_selectable_target(_selected_target):
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
	notice.emit("左键选择组织或菌丝；J 开始维修，K 暂停 / 继续，Backspace 取消维修；Esc / 右键退出选择")
	return true


func exit_selection_mode() -> void:
	if not _selecting:
		return
	_selecting = false
	set_process(get_selected_target() != null)
	mode_changed.emit(false)
	_publish_preview()


func is_selecting() -> bool:
	return _selecting


func select_edge(edge: HyphaEdge) -> bool:
	return select_target(edge)


func select_target(target: Node2D) -> bool:
	if not _selecting:
		notice.emit("按 F 进入维修选择")
		return false
	if not _is_selectable_target(target):
		_publish_failure(&"invalid_target", "请选择当前网络中可修复的组织")
		return false
	if _selected_target != target:
		_disconnect_selected_target()
		_selected_target = target
		_bound_target = target
		target.connect("health_changed", _on_selected_health_changed)
		target.tree_exiting.connect(_on_selected_tree_exiting)
		selection_changed.emit(target)
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
		_publish_failure(&"outside_bounds", "请在可生长区域内选择组织")
		return false
	var target: Node2D = _tissue_at(world_position)
	var edge: HyphaEdge = _edge_at(world_position)
	if edge != null:
		var edge_point: Vector2 = Geometry2D.get_closest_point_to_segment(
			world_position, edge.start_node.global_position, edge.end_node.global_position)
		# 拐角附近短菌丝不能被两端的组织拾取圆完全遮住。点击中心保留节点优先，
		# 点击连线则按实际距离选择菌丝，原 F/J 操作不增加另一种模式。
		if target == null or world_position.distance_squared_to(edge_point) + DISTANCE_EPSILON \
				< world_position.distance_squared_to(_tissue_pick_point(target)):
			target = edge
	if target == null:
		_publish_failure(&"target_required", "请点击菌结、器官或菌丝附近")
		return false
	return select_target(target)


func get_selected_edge() -> HyphaEdge:
	return get_selected_target() as HyphaEdge


func get_selected_target() -> Node2D:
	return _selected_target if _is_selectable_target(_selected_target) else null


func get_preview() -> Dictionary:
	return _make_preview().duplicate(true)


func request_repair() -> int:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return 0
	_connect_services()
	var error: String = _configuration_error()
	if not error.is_empty():
		_publish_failure(&"invalid_configuration", error)
		return 0
	var target: Node2D = get_selected_target()
	if target == null:
		_publish_failure(&"target_required", "请先按 F 并选择受损组织")
		return 0
	var preview: Dictionary = repair_system.preview_repair(target)
	if not bool(preview.get("valid", false)):
		_publish_preview()
		notice.emit(_describe_preview(preview))
		return 0
	var task_id: int = repair_system.request_repair(target)
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
		notice.emit("维修请求未接受；请重新确认所选组织与当前维修任务")
	return task_id


func toggle_pause() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
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
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
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


func _disconnect_selected_target() -> void:
	if is_instance_valid(_bound_target):
		if _bound_target.is_connected("health_changed", _on_selected_health_changed):
			_bound_target.disconnect("health_changed", _on_selected_health_changed)
		if _bound_target.tree_exiting.is_connected(_on_selected_tree_exiting):
			_bound_target.tree_exiting.disconnect(_on_selected_tree_exiting)
	_bound_target = null


func _clear_selection() -> void:
	var had_selection: bool = _selected_target != null
	_disconnect_selected_target()
	_selected_target = null
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
	var target: Node2D = get_selected_target()
	var snapshot: Dictionary = {
		"valid": false, "reason": &"target_required", "target": target, "target_id": 0,
		"target_name": "", "target_kind": &"", "edge": null, "edge_id": 0,
		"health": 0.0, "max_health": 0.0, "missing_health": 0.0,
		"estimated_cost": 0, "repair_point": null, "access_edge": null, "supply_reachable": false,
	}
	var error: String = _configuration_error()
	if not error.is_empty():
		snapshot["reason"] = &"invalid_configuration"
	elif target != null:
		snapshot = repair_system.preview_repair(target).duplicate(true)
	if target != null and _is_live_node(repair_system):
		var task: Dictionary = repair_system.get_task_snapshot()
		if task.get("target", task.get("edge")) == target and repair_system.has_active_task():
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
	var target: Node2D = snapshot.get("target", snapshot.get("edge")) as Node2D
	if not _is_live_node(target):
		return "按 F 并左键选择组织或菌丝，预览生命和维修费用"
	var health: float = float(snapshot.get("health", 0.0))
	var maximum: float = float(snapshot.get("max_health", 0.0))
	var price: int = int(snapshot.get("estimated_cost", 0))
	var result: String = "HP %.1f / %.1f，预计 %d 营养；%s" % [
		health, maximum, price, _describe_access(snapshot),
	]
	if float(snapshot.get("missing_health", 0.0)) <= 0.0:
		result += "；组织健康，无需维修"
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


func _tissue_at(world_position: Vector2) -> Node2D:
	var best: Node2D = null
	var best_distance: float = TISSUE_PICK_RADIUS * TISSUE_PICK_RADIUS
	if not is_inside_tree():
		return null
	for candidate: Node in get_tree().get_nodes_in_group("colony_tissues"):
		if candidate is HyphaEdge or not _is_selectable_target(candidate):
			continue
		var target: Node2D = candidate as Node2D
		var distance: float = world_position.distance_squared_to(_tissue_pick_point(target))
		if distance > TISSUE_PICK_RADIUS * TISSUE_PICK_RADIUS:
			continue
		if best == null or distance < best_distance - DISTANCE_EPSILON \
				or (absf(distance - best_distance) <= DISTANCE_EPSILON \
				and target.get_instance_id() < best.get_instance_id()):
			best = target
			best_distance = distance
	return best


func _tissue_pick_point(target: Node2D) -> Vector2:
	if target is AttackOrgan or target is DigestiveOrgan:
		return target.to_global(Vector2(0.0, -32.0))
	if target is OrganBud:
		return target.to_global(Vector2(0.0, -15.0))
	if target is MotherCore:
		return target.to_global(Vector2(0.0, -35.0))
	return target.global_position


func _is_selectable_target(candidate: Variant) -> bool:
	if not _is_live_node(candidate) or not candidate is Node2D or not _is_live_node(network_system):
		return false
	if candidate is HyphaEdge:
		return _is_selectable_edge(candidate)
	if not candidate.has_method("get_health_snapshot") or not candidate.has_method("is_attackable"):
		return false
	if not candidate.global_position.is_finite():
		return false
	if candidate is HyphaNode:
		return network_system.is_node_registered(candidate)
	if candidate is MotherCore:
		return network_system.peek_registered_core() == candidate and bool(candidate.call("is_attackable"))
	if not bool(candidate.call("is_attackable")):
		return false
	if candidate is GrowthTip:
		return network_system.is_node_registered(candidate)
	if candidate is AttackOrgan or candidate is DigestiveOrgan or candidate is OrganBud:
		var host: HyphaNode = candidate.get_parent() as HyphaNode
		return _is_live_node(host) and network_system.is_node_registered(host)
	return false


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
