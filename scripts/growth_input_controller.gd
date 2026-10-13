class_name GrowthInputController
extends Node2D
## 关卡显式调用 handle_input；这里只管理放置、预览和生长控制，不结算营养。

signal mode_changed(placing: bool)
signal preview_changed(preview: Dictionary)
signal status_changed(snapshot: Dictionary)
signal notice(message: String)

@export var growth_system: GrowthSystem:
	set(value):
		if is_instance_valid(growth_system):
			if growth_system.task_changed.is_connected(_on_task_changed):
				growth_system.task_changed.disconnect(_on_task_changed)
		growth_system = value
		if is_node_ready():
			_connect_growth_system()
@export var planner: GrowthPlanner
@export var construction_coordinator: ConstructionCoordinator
@export var network_system: NetworkSystem
@export var target_container: Node2D
@export var target_scene: PackedScene = preload("res://scenes/colony/growth_target.tscn")
@export var placement_bounds: Rect2 = Rect2(0, 230, 1200, 410)

var _placing: bool = false
var _preview_marker: GrowthTarget = null
var _target_marker: GrowthTarget = null


func _ready() -> void:
	set_process(false)
	_connect_growth_system()


func _exit_tree() -> void:
	if is_instance_valid(growth_system):
		if growth_system.task_changed.is_connected(_on_task_changed):
			growth_system.task_changed.disconnect(_on_task_changed)
	_dispose_marker(_preview_marker)
	_dispose_marker(_target_marker)
	_preview_marker = null
	_target_marker = null
	_placing = false


func _process(_delta: float) -> void:
	if _placing:
		preview_at(get_global_mouse_position())


func _on_task_changed(snapshot: Dictionary) -> void:
	if is_instance_valid(_target_marker):
		if _target_marker.get_task_id() == int(snapshot.get("task_id", 0)):
			_target_marker.show_status(snapshot)
	if _placing and not is_instance_valid(construction_coordinator) \
			and is_instance_valid(growth_system) and growth_system.has_active_task():
		exit_placement_mode()
	status_changed.emit(snapshot.duplicate(true))


func enter_placement_mode() -> bool:
	_connect_growth_system()
	var error: String = _configuration_error()
	if not error.is_empty():
		notice.emit(error)
		return false
	if not is_instance_valid(construction_coordinator) and growth_system.has_active_task():
		notice.emit("已有生长目标；请先完成或取消当前任务")
		return false
	if _placing:
		return true
	var marker: GrowthTarget = _instantiate_marker()
	if marker == null:
		return false
	marker.name = "GrowthPreview"
	target_container.add_child(marker)
	_preview_marker = marker
	_placing = true
	set_process(true)
	mode_changed.emit(true)
	preview_at(get_global_mouse_position())
	return true


func exit_placement_mode() -> void:
	if not _placing:
		return
	_placing = false
	set_process(false)
	_dispose_marker(_preview_marker)
	_preview_marker = null
	mode_changed.emit(false)


func is_placing() -> bool:
	return _placing


func preview_at(world_position: Vector2) -> Dictionary:
	var preview: Dictionary = _make_preview(world_position)
	if _placing and is_instance_valid(_preview_marker):
		_preview_marker.show_preview(preview)
	preview_changed.emit(preview.duplicate(true))
	return preview


func place_target(world_position: Vector2) -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	if not _placing:
		notice.emit("按 G 进入生长目标放置")
		return false
	var preview: Dictionary = preview_at(world_position)
	if not bool(preview["valid"]):
		notice.emit(String(preview["error"]))
		return false
	if is_instance_valid(construction_coordinator):
		var result: Dictionary = construction_coordinator.enqueue(&"growth", {
			"start_node": preview["start_node"], "target_position": world_position})
		if not bool(result.get("accepted", false)):
			return false
		exit_placement_mode()
		return true
	# 先确认可视场景能创建，再调用生长 API；失败时保留上一目标标记。
	var marker: GrowthTarget = _instantiate_marker()
	if marker == null:
		return false
	var start_node: Node2D = preview["start_node"] as Node2D
	var task_id: int = growth_system.create_target(start_node, world_position)
	if task_id <= 0:
		marker.free()
		notice.emit("生长目标创建失败；请检查起点连接和当前任务")
		return false
	_dispose_marker(_target_marker)
	marker.name = "GrowthTarget"
	target_container.add_child(marker)
	_target_marker = marker
	_target_marker.show_status(growth_system.get_task_snapshot())
	exit_placement_mode()
	return true


func pause_growth() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	if is_instance_valid(construction_coordinator):
		return construction_coordinator.pause_request(String(construction_coordinator.get_snapshot()["selected_id"]))
	_connect_growth_system()
	if not is_instance_valid(growth_system):
		notice.emit("生长系统尚未配置")
		return false
	var paused: bool = growth_system.pause_task()
	if not paused:
		notice.emit("当前没有可暂停的生长任务")
	return paused


func resume_growth() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	if is_instance_valid(construction_coordinator):
		return construction_coordinator.resume_request(String(construction_coordinator.get_snapshot()["selected_id"]))
	_connect_growth_system()
	if not is_instance_valid(growth_system):
		notice.emit("生长系统尚未配置")
		return false
	var resumed: bool = growth_system.resume_task()
	if not resumed:
		notice.emit("当前没有可继续的生长任务")
	return resumed


func cancel_growth() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	if is_instance_valid(construction_coordinator):
		return construction_coordinator.cancel_request(String(construction_coordinator.get_snapshot()["selected_id"]))
	_connect_growth_system()
	if not is_instance_valid(growth_system):
		notice.emit("生长系统尚未配置")
		return false
	var cancelled: bool = growth_system.cancel_task()
	if not cancelled:
		notice.emit("当前没有可取消的生长任务")
	return cancelled


func handle_input(event: InputEvent) -> bool:
	if event == null or (event is InputEventKey and event.echo):
		return false
	if event.is_action_pressed("growth_mode"):
		enter_placement_mode()
		return true
	if event.is_action_pressed("growth_pause"):
		if is_instance_valid(growth_system):
			var snapshot: Dictionary = growth_system.get_task_snapshot()
			if StringName(snapshot.get("state", &"idle")) == &"paused":
				resume_growth()
			else:
				pause_growth()
		else:
			pause_growth()
		return true
	if event.is_action_pressed("growth_cancel"):
		cancel_growth()
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
				place_target(_mouse_world_position(event.position))
			return true
	return false


func _connect_growth_system() -> void:
	if not is_instance_valid(growth_system):
		return
	if not growth_system.task_changed.is_connected(_on_task_changed):
		growth_system.task_changed.connect(_on_task_changed)
		_on_task_changed(growth_system.get_task_snapshot())


func _configuration_error() -> String:
	if not is_instance_valid(growth_system) or growth_system.is_queued_for_deletion():
		return "生长系统尚未配置"
	if not is_instance_valid(planner) or not is_instance_valid(network_system):
		return "生长规划器或网络尚未配置"
	if growth_system.planner != planner or growth_system.network_system != network_system:
		return "预览与生长必须使用同一规划器和网络"
	if not is_instance_valid(target_container) or target_container.is_queued_for_deletion():
		return "生长目标容器尚未配置"
	if target_scene == null:
		return "生长目标场景尚未配置"
	return ""


func _make_preview(world_position: Vector2) -> Dictionary:
	var preview: Dictionary = {
		"valid": false,
		"error": "",
		"start_node": null,
		"target_position": world_position,
		"plan": {},
	}
	var error: String = _configuration_error()
	if not error.is_empty():
		preview["error"] = error
		return preview
	if not is_instance_valid(construction_coordinator) and growth_system.has_active_task():
		preview["error"] = "已有生长目标；请先完成或取消当前任务"
		return preview
	if not world_position.is_finite() or not placement_bounds.has_point(world_position):
		preview["error"] = "目标必须位于可生长区域内"
		return preview
	var terrain: TerrainNavigation = planner.terrain_navigation
	if is_instance_valid(terrain) and not terrain.is_point_walkable(world_position, 10.0):
		preview["error"] = "目标在岩石或战场边界内，无法生长；未扣除营养"
		return preview
	var start_node: Node2D = null
	var nearest_distance: float = INF
	for node: Node2D in network_system.get_registered_nodes():
		# 临时尖端和取消后的残端不属于成熟菌结，不能成为下一次起点。
		if not (node is MotherCore or node is HyphaNode):
			continue
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		if not node.global_position.is_finite():
			continue
		if node.global_position == world_position and not planner.auto_join_enabled:
			preview["error"] = "目标不能与已有菌结或母核重合"
			return preview
		if planner.auto_join_enabled and node is HyphaNode \
				and node.global_position.distance_to(world_position) <= planner.auto_join_radius:
			# 目标附近的菌结是接入终点，不能又被选作零距离或向外短生长的起点。
			continue
		if not network_system.is_available_connected_to_core(node):
			continue
		var candidate: Dictionary = growth_system.preview_target(node, world_position)
		if not bool(candidate.get("valid", false)):
			continue
		var distance: float = float(candidate["distance"])
		var nearer: bool = distance < nearest_distance
		var tie: bool = distance == nearest_distance and is_instance_valid(start_node)
		if nearer or (tie and node.get_instance_id() < start_node.get_instance_id()):
			start_node = node
			nearest_distance = distance
	if start_node == null:
		preview["error"] = "没有与母核连通的生长起点"
		return preview
	if is_instance_valid(construction_coordinator):
		var queued_preview: Dictionary = construction_coordinator.preview(&"growth", {
			"start_node": start_node, "target_position": world_position})
		preview.merge(queued_preview, true)
		preview["start_node"] = start_node
		var queued_plan: Dictionary = preview.get("plan", {})
		preview["effective_point"] = queued_plan.get("effective_point", world_position)
		preview["resolved_target_position"] = preview["effective_point"]
		return preview
	var plan: Dictionary = growth_system.preview_target(start_node, world_position)
	preview["start_node"] = start_node
	preview["plan"] = plan
	preview["effective_point"] = plan.get("effective_point", world_position)
	preview["resolved_target_position"] = preview["effective_point"]
	preview["valid"] = bool(plan.get("valid", false)) and float(plan.get("distance", 0.0)) > 0.0
	preview["error"] = String(plan.get("error", ""))
	if not bool(preview["valid"]) and String(preview["error"]).is_empty():
		preview["error"] = "目标必须与生长起点保持距离"
	return preview


func _instantiate_marker() -> GrowthTarget:
	var instance: Node = target_scene.instantiate()
	if not instance is GrowthTarget:
		instance.free()
		notice.emit("生长目标场景必须使用 GrowthTarget")
		return null
	return instance as GrowthTarget


func _dispose_marker(marker: GrowthTarget) -> void:
	if is_instance_valid(marker) and not marker.is_queued_for_deletion():
		marker.hide()
		marker.queue_free()


func _mouse_world_position(viewport_position: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * viewport_position
