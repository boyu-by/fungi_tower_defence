class_name ConnectionInputController
extends Node2D
## 关卡转交 L 和放置输入；只选择已有菌结、显示报价并提交连接，不结算营养或网络。

signal mode_changed(placing: bool)
signal preview_changed(preview: Dictionary)
signal status_changed(snapshot: Dictionary)
signal notice(message: String)

const TARGET_SCENE: PackedScene = preload("res://scenes/colony/connection_target.tscn")
const ENDPOINT_RADIUS: float = 24.0

@export var connection_system: ConnectionSystem:
	set(value):
		_disconnect_connection_system()
		connection_system = value
		if is_node_ready():
			_connect_connection_system()
@export var network_system: NetworkSystem
@export var construction_coordinator: ConstructionCoordinator
@export var target_container: Node2D
@export var placement_bounds: Rect2 = Rect2(0, 230, 1200, 410)

var _placing: bool = false
var _first_node: HyphaNode = null
var _second_node: HyphaNode = null
var _pointer_world_position: Vector2 = Vector2.ZERO
var _last_preview: Dictionary = {}
var _preview_marker: ConnectionTarget = null
var _target_marker: ConnectionTarget = null
var _bound_connection_system: ConnectionSystem = null


func _ready() -> void:
	set_process(false)
	_connect_connection_system()
	_connect_connection_system.call_deferred()


func _exit_tree() -> void:
	_disconnect_connection_system()
	_dispose_marker(_preview_marker)
	_dispose_marker(_target_marker)
	_preview_marker = null
	_target_marker = null
	_first_node = null
	_second_node = null
	_placing = false


func _process(_delta: float) -> void:
	if _placing and _is_live_node(target_container):
		preview_at(target_container.get_global_mouse_position())


func _on_task_changed(_snapshot: Dictionary) -> void:
	if not _is_live_node(connection_system):
		return
	# 协调器是任务身份的唯一来源；重读可忽略 reset 后迟到的旧通知。
	var current: Dictionary = connection_system.get_task_snapshot()
	var task_id: int = int(current.get("task_id", 0))
	if task_id <= 0:
		_dispose_marker(_target_marker)
		_target_marker = null
	elif is_instance_valid(_target_marker) and _target_marker.get_task_id() == task_id:
		_target_marker.placement_bounds = placement_bounds
		_target_marker.show_status(current)
	if _placing and not is_instance_valid(construction_coordinator) and connection_system.has_active_task():
		exit_placement_mode()
	status_changed.emit(current.duplicate(true))


func enter_placement_mode() -> bool:
	_connect_connection_system()
	var error: String = _configuration_error()
	if not error.is_empty():
		notice.emit(error)
		return false
	if _has_active_build():
		notice.emit("已有建造任务；请先完成或取消当前任务")
		return false
	if _placing:
		return true
	var marker: ConnectionTarget = TARGET_SCENE.instantiate() as ConnectionTarget
	marker.placement_bounds = placement_bounds
	marker.name = "ConnectionPreview"
	target_container.add_child(marker)
	_preview_marker = marker
	_first_node = null
	_second_node = null
	_placing = true
	set_process(true)
	mode_changed.emit(true)
	preview_at(target_container.get_global_mouse_position())
	return true


func exit_placement_mode() -> void:
	if not _placing:
		return
	_placing = false
	set_process(false)
	_dispose_marker(_preview_marker)
	_preview_marker = null
	clear_endpoints()
	mode_changed.emit(false)


func is_placing() -> bool:
	return _placing


func preview_at(world_position: Vector2) -> Dictionary:
	_pointer_world_position = world_position
	var preview: Dictionary = _make_preview(world_position)
	_publish_preview(preview)
	return preview


func select_endpoint(endpoint: HyphaNode) -> bool:
	if not _placing:
		notice.emit("按 L 进入已有菌结连接")
		return false
	_connect_connection_system()
	var error: String = _configuration_error()
	if not error.is_empty():
		_publish_failure(&"invalid_configuration", error)
		return false
	var endpoint_error: Dictionary = _endpoint_error(endpoint)
	if not endpoint_error.is_empty():
		_publish_failure(endpoint_error["reason"], endpoint_error["error"])
		return false
	if not _is_selectable_node(_first_node):
		if _has_active_build():
			_publish_failure(&"construction_busy", "已有建造任务；请先完成或取消当前任务")
			return false
		_first_node = endpoint
		_second_node = null
		_pointer_world_position = endpoint.global_position
		var waiting: Dictionary = _empty_preview(_pointer_world_position)
		waiting["reason"] = &"choose_second"
		waiting["error"] = "已选第一个菌结；移动到另一个已有菌结预览，左键确认"
		_publish_preview(waiting)
		return true
	var preview: Dictionary = _preview_endpoint(endpoint, endpoint.global_position)
	_publish_preview(preview)
	if not bool(preview.get("valid", false)):
		notice.emit(String(preview.get("error", "连接不可创建")))
		return false
	if is_instance_valid(construction_coordinator):
		var result: Dictionary = construction_coordinator.enqueue(&"connection", {
			"first_node": _first_node, "second_node": endpoint})
		if not bool(result.get("accepted", false)):
			return false
		exit_placement_mode()
		return true
	# 信号可在 request_connection 内退出放置；先保存两端身份和报价。
	var first: HyphaNode = _first_node
	var second: HyphaNode = endpoint
	var marker: ConnectionTarget = TARGET_SCENE.instantiate() as ConnectionTarget
	marker.placement_bounds = placement_bounds
	var task_id: int = connection_system.request_connection(first, second)
	if task_id <= 0:
		marker.free()
		var rejected: Dictionary = connection_system.preview_connection(first, second)
		if bool(rejected.get("valid", false)):
			rejected["valid"] = false
			rejected["reason"] = &"request_rejected"
			rejected["error"] = "连接请求未接受；请重新确认当前端点与建造状态"
		_publish_preview(rejected)
		notice.emit(String(rejected.get("error", "连接请求未接受")))
		return false
	_dispose_marker(_target_marker)
	marker.name = "ConnectionTarget"
	target_container.add_child(marker)
	_target_marker = marker
	# 报价保留最初选择顺序；任务快照提供实际进度，不重新规划或计算费用。
	marker.show_preview(preview)
	marker.show_status(connection_system.get_task_snapshot())
	exit_placement_mode()
	return true


func place_at(world_position: Vector2) -> bool:
	if not _placing:
		notice.emit("按 L 进入已有菌结连接")
		return false
	var preview: Dictionary = preview_at(world_position)
	var hover: Variant = preview.get("hover_node")
	var endpoint: HyphaNode = hover as HyphaNode if _is_live_node(hover) else null
	if not _is_selectable_node(endpoint):
		notice.emit(String(preview.get("error", "请点击已有菌结")))
		return false
	return select_endpoint(endpoint)


func get_selection_snapshot() -> Dictionary:
	var snapshot: Dictionary = _last_preview.duplicate(true)
	snapshot["placing"] = _placing
	snapshot["first_node"] = _first_node if _is_selectable_node(_first_node) else null
	snapshot["second_node"] = _second_node if _is_selectable_node(_second_node) else null
	return snapshot


func clear_endpoints() -> void:
	_first_node = null
	_second_node = null
	var preview: Dictionary = _empty_preview(_pointer_world_position)
	preview["reason"] = &"choose_first"
	preview["error"] = "左键选择第一个已有菌结，再选择第二个菌结连接；右键 / Esc 退出"
	_publish_preview(preview)


func handle_input(event: InputEvent) -> bool:
	if event == null or (event is InputEventKey and event.echo):
		return false
	if event.is_action_pressed("connection_mode"):
		if _placing:
			exit_placement_mode()
		else:
			enter_placement_mode()
		return true
	if not _placing:
		return false
	if event.is_action_pressed("cancel_selection"):
		exit_placement_mode()
		return true
	if event is InputEventMouseMotion:
		preview_at(_mouse_world_position(event.position))
		return true
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			exit_placement_mode()
			return true
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				place_at(_mouse_world_position(event.position))
			return true
	return false


func _make_preview(world_position: Vector2) -> Dictionary:
	var preview: Dictionary = _empty_preview(world_position)
	var error: String = _configuration_error()
	if not error.is_empty():
		preview["reason"] = &"invalid_configuration"
		preview["error"] = error
		return preview
	if not world_position.is_finite():
		preview["reason"] = &"invalid_coordinates"
		preview["error"] = "鼠标坐标必须有限"
		return preview
	if not placement_bounds.has_point(world_position):
		preview["reason"] = &"outside_bounds"
		preview["error"] = "连接端点必须位于可生长区域内"
		return preview
	var endpoint: HyphaNode = _endpoint_at(world_position)
	preview["hover_node"] = endpoint
	if not _is_selectable_node(_first_node):
		_first_node = null
		preview["first_node"] = null
		preview["reason"] = &"construction_busy" if _has_active_build() else &"choose_first"
		preview["error"] = "已有建造任务；请先完成或取消当前任务" if _has_active_build() \
			else "左键选择第一个已有菌结，再选择第二个菌结连接"
		return preview
	if endpoint == null:
		preview["reason"] = &"endpoint_required"
		preview["error"] = "已选第一个菌结；请将鼠标移到另一个已有菌结"
		return preview
	return _preview_endpoint(endpoint, world_position)


func _preview_endpoint(endpoint: HyphaNode, world_position: Vector2) -> Dictionary:
	var preview: Dictionary = _empty_preview(world_position)
	preview["second_node"] = endpoint
	preview["hover_node"] = endpoint
	var endpoint_error: Dictionary = _endpoint_error(endpoint)
	if not endpoint_error.is_empty():
		preview.merge(endpoint_error, true)
		return preview
	var first_error: Dictionary = _endpoint_error(_first_node)
	if not first_error.is_empty():
		preview.merge(first_error, true)
		return preview
	preview = construction_coordinator.preview(&"connection", {
		"first_node": _first_node, "second_node": endpoint}) if is_instance_valid(construction_coordinator) \
		else connection_system.preview_connection(_first_node, endpoint).duplicate(true)
	preview["first_node"] = _first_node
	preview["second_node"] = endpoint
	preview["target_position"] = endpoint.global_position
	preview["pointer_position"] = world_position
	preview["hover_node"] = endpoint
	return preview


func _empty_preview(world_position: Vector2) -> Dictionary:
	return {
		"valid": false, "error": "", "reason": &"",
		"first_node": _first_node if _is_live_node(_first_node) else null,
		"second_node": null, "start_node": null, "target_node": null,
		"reversed": false, "plan": {}, "total_cost": 0,
		"target_position": world_position, "pointer_position": world_position, "hover_node": null,
	}


func _publish_preview(preview: Dictionary) -> void:
	_last_preview = preview.duplicate(true)
	var second: Variant = preview.get("second_node")
	_second_node = second as HyphaNode if _is_live_node(second) else null
	if _placing and is_instance_valid(_preview_marker):
		_preview_marker.placement_bounds = placement_bounds
		_preview_marker.show_preview(preview)
	preview_changed.emit(preview.duplicate(true))


func _publish_failure(reason: StringName, message: String) -> void:
	var preview: Dictionary = _empty_preview(_pointer_world_position)
	preview["reason"] = reason
	preview["error"] = message
	_publish_preview(preview)
	notice.emit(message)


func _configuration_error() -> String:
	if not _is_live_node(connection_system) or not _is_live_node(network_system):
		return "连接系统或网络尚未配置"
	if not _is_live_node(connection_system.growth_system) \
			or connection_system.growth_system.network_system != network_system:
		return "连接预览与生长必须使用同一网络"
	if not _is_live_node(target_container):
		return "连接标记容器尚未配置"
	return ""


func _endpoint_error(endpoint: Variant) -> Dictionary:
	if not _is_selectable_node(endpoint):
		return {"reason": &"invalid_endpoint", "error": "请选择网络中的已有成熟菌结"}
	if not endpoint.global_position.is_finite():
		return {"reason": &"invalid_coordinates", "error": "菌结坐标必须有限"}
	if not placement_bounds.has_point(endpoint.global_position):
		return {"reason": &"outside_bounds", "error": "连接端点必须位于可生长区域内"}
	return {}


func _endpoint_at(world_position: Vector2) -> HyphaNode:
	var nearest: HyphaNode = null
	var nearest_distance: float = ENDPOINT_RADIUS * ENDPOINT_RADIUS
	for node: Node2D in network_system.get_registered_nodes():
		if not node is HyphaNode or not _is_live_node(node) or not node.global_position.is_finite():
			continue
		var distance: float = node.global_position.distance_squared_to(world_position)
		if distance > nearest_distance:
			continue
		if distance < nearest_distance or nearest == null \
				or node.get_instance_id() < nearest.get_instance_id():
			nearest = node as HyphaNode
			nearest_distance = distance
	return nearest


func _has_active_build() -> bool:
	if is_instance_valid(construction_coordinator):
		return false
	if not _is_live_node(connection_system):
		return false
	if connection_system.has_active_task():
		return true
	if _is_live_node(connection_system.growth_system) and connection_system.growth_system.has_active_task():
		return true
	return connection_system.construction_blocker.is_valid() \
		and bool(connection_system.construction_blocker.call())


func _connect_connection_system() -> void:
	if not is_inside_tree() or not _is_live_node(connection_system):
		return
	if _bound_connection_system != connection_system:
		_disconnect_connection_system()
		_bound_connection_system = connection_system
	if not connection_system.task_changed.is_connected(_on_task_changed):
		connection_system.task_changed.connect(_on_task_changed)
		_on_task_changed(connection_system.get_task_snapshot())


func _disconnect_connection_system() -> void:
	if is_instance_valid(_bound_connection_system):
		if _bound_connection_system.task_changed.is_connected(_on_task_changed):
			_bound_connection_system.task_changed.disconnect(_on_task_changed)
	_bound_connection_system = null


func _is_selectable_node(node: Variant) -> bool:
	return _is_live_node(node) and node is HyphaNode and _is_live_node(network_system) \
		and network_system.get_registered_nodes().has(node)


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and node.is_inside_tree() \
		and not node.is_queued_for_deletion()


func _dispose_marker(marker: ConnectionTarget) -> void:
	if is_instance_valid(marker) and not marker.is_queued_for_deletion():
		marker.hide()
		marker.queue_free()


func _mouse_world_position(viewport_position: Vector2) -> Vector2:
	return target_container.get_canvas_transform().affine_inverse() * viewport_position \
		if _is_live_node(target_container) else viewport_position
