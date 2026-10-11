class_name CultivationInputController
extends Node
## 关卡转交选择与输入；管理远程目标标记，仅调用建造 API，不结算营养。

signal selection_status_changed(snapshot: Dictionary)
signal status_changed(snapshot: Dictionary)
signal remote_mode_changed(placing: bool)
signal remote_preview_changed(preview: Dictionary)
signal notice(message: String)

const TOTAL_COST: int = 12
const TARGET_SCENE: PackedScene = preload("res://scenes/colony/growth_target.tscn")
const OVERLAP_RADIUS: float = 24.0
const REASON_TEXT: Dictionary = {
	&"no_selection": "请先选择一个成熟菌结",
	&"occupied": "器官槽位已占用；请选择空菌结或已取消的培育芽",
	&"disconnected": "所选菌结未与存活的母核连通",
	&"construction_busy": "已有建造任务；请先完成或取消当前生长或培育",
	&"invalid_configuration": "培育系统或供养配置尚未就绪",
	&"settlement_pending": "上一轮培育退款尚未结算，请等待后再继续",
	&"ready": "可培育攻击器官：结构 8 + 库存 4，共 12 营养",
	&"continuable": "可继续培育芽，保留已付结构与进度",
}

@export var cultivation_system: CultivationSystem
@export var cultivation_supply_system: CultivationSupplySystem
@export var growth_system: GrowthSystem
@export var network_system: NetworkSystem
@export var mother_core: MotherCore
@export var construction_coordinator: ConstructionCoordinator
@export var remote_cultivation_system: RemoteCultivationSystem
@export var growth_input_controller: GrowthInputController
@export var target_container: Node2D
@export var placement_bounds: Rect2 = Rect2(0, 230, 1200, 410)

var _selected_node: HyphaNode = null
var _remote_placing: bool = false
var _remote_preview_marker: GrowthTarget = null
var _remote_target_marker: GrowthTarget = null
var _remote_quote: Dictionary = {}
var _observed_remote_request_id: int = 0
var _remote_growth_task_id: int = 0
var _remote_cultivation_task_id: int = 0
var _bound_dependencies: Array = []
var _dependency_bindings: Array[Dictionary] = []
var _last_selection_snapshot: Dictionary = {}
var _last_task_snapshot: Dictionary = {}
var _refreshing: bool = false
var _refresh_pending: bool = false


func _ready() -> void:
	set_process(false)
	refresh()
	refresh.call_deferred()


func _exit_tree() -> void:
	_disconnect_dependencies()
	_disconnect_selection()
	_selected_node = null
	_dispose_marker(_remote_preview_marker)
	_dispose_marker(_remote_target_marker)
	_remote_preview_marker = null
	_remote_target_marker = null
	_remote_placing = false


func _process(_delta: float) -> void:
	if _remote_placing and _is_live_node(target_container):
		preview_remote_at(target_container.get_global_mouse_position())


func _on_remote_request_changed(_snapshot: Dictionary) -> void:
	# 从协调器重读当前身份，忽略旧尝试迟到的通知。
	refresh()


func _on_growth_mode_changed(placing: bool) -> void:
	if placing:
		exit_remote_placement_mode()


func _on_dependency_changed(_snapshot: Dictionary) -> void:
	refresh()


func _on_network_changed() -> void:
	refresh()


func _on_core_nutrition_changed(_nutrition: int) -> void:
	refresh()


func _on_core_depleted() -> void:
	refresh()


func _on_slot_changed() -> void:
	refresh()


func _on_selected_node_exiting() -> void:
	select_node(null)


func select_node(node: HyphaNode) -> void:
	_disconnect_selection()
	_selected_node = node if _is_live_node(node) else null
	if _selected_node != null:
		_selected_node.organ_slot_changed.connect(_on_slot_changed)
		_selected_node.tree_exiting.connect(_on_selected_node_exiting)
	refresh()


func get_selection_status() -> Dictionary:
	var host: HyphaNode = _selected_node if _is_live_node(_selected_node) else null
	if is_instance_valid(construction_coordinator) and construction_coordinator.multi_worker_enabled:
		return construction_coordinator.get_cultivation_selection(host)
	var task: Dictionary = {}
	var active: bool = false
	if _is_live_node(cultivation_system):
		task = cultivation_system.get_task_snapshot()
		active = cultivation_system.has_active_task()
	if _has_active_remote_request():
		task = remote_cultivation_system.get_request_snapshot()
		active = true
	var state: StringName = StringName(task.get("state", &"idle"))
	var available: int = 0
	if _is_live_node(cultivation_supply_system):
		available = cultivation_supply_system.get_available_cultivation_nutrition()
	var remaining: int = TOTAL_COST
	if host != null and _is_live_node(cultivation_system):
		var bud: Dictionary = cultivation_system.get_bud_snapshot(host)
		if not bud.is_empty():
			remaining = int(bud.get("remaining_cost", TOTAL_COST))
			if not active:
				task = bud.duplicate(true)
		elif task.get("host") == host:
			remaining = int(task.get("remaining_cost", TOTAL_COST))
	var reason: StringName = &"no_selection"
	if host != null:
		if not _configuration_is_valid():
			reason = &"invalid_configuration"
		elif mother_core.health <= 0:
			reason = &"disconnected"
		else:
			reason = cultivation_system.get_cultivation_availability(host)
			if (reason == &"ready" or reason == &"continuable") \
					and ((_is_live_node(growth_system) and growth_system.has_active_task()) \
					or _has_active_remote_request()):
				reason = &"construction_busy"
	var can_cultivate: bool = reason == &"ready"
	var can_continue: bool = reason == &"continuable"
	var message: String = String(REASON_TEXT.get(reason, "当前无法培育，请检查任务与连接"))
	# 缺粮只影响提示；允许创建等待任务，真实运输送达以后才会推进。
	if (can_cultivate or can_continue) and available < remaining:
		reason = &"insufficient_nutrition"
		message = "营养不足：培育可用 %d，尚需 %d；可先创建任务等待供养" % [available, remaining]
	return {
		"host": host, "reason": reason, "message": message,
		"can_cultivate": can_cultivate, "can_continue": can_continue,
		"can_pause": active and state != &"paused",
		"can_resume": active and state == &"paused", "can_cancel": active,
		"task": task.duplicate(true), "total_cost": TOTAL_COST,
		"remaining_cost": remaining, "available_nutrition": available,
	}


func refresh() -> void:
	if _refreshing:
		_refresh_pending = true
		return
	_refreshing = true
	_connect_dependencies()
	if _remote_placing and _has_active_build():
		exit_remote_placement_mode()
	var remote_snapshot: Dictionary = remote_cultivation_system.get_request_snapshot() \
		if _is_live_node(remote_cultivation_system) else {}
	_refresh_remote_marker(remote_snapshot)
	var selection: Dictionary = get_selection_status()
	var task: Dictionary = _get_current_build_snapshot(remote_snapshot)
	if selection != _last_selection_snapshot:
		_last_selection_snapshot = selection.duplicate(true)
		selection_status_changed.emit(selection.duplicate(true))
	if task != _last_task_snapshot:
		_last_task_snapshot = task.duplicate(true)
		status_changed.emit(task.duplicate(true))
	_refreshing = false
	if _refresh_pending:
		_refresh_pending = false
		refresh.call_deferred()


func request_cultivation() -> bool:
	if is_instance_valid(construction_coordinator) and construction_coordinator.multi_worker_enabled:
		var result: Dictionary = construction_coordinator.enqueue_local_cultivation(_selected_node)
		if bool(result.get("accepted", false)):
			exit_remote_placement_mode()
			if _is_live_node(growth_input_controller):
				growth_input_controller.exit_placement_mode()
		refresh()
		return bool(result.get("accepted", false))
	refresh()
	var selection: Dictionary = get_selection_status()
	if not bool(selection["can_cultivate"]) and not bool(selection["can_continue"]):
		notice.emit(String(selection["message"]))
		return false
	var host: HyphaNode = selection["host"] as HyphaNode
	var continuing: bool = bool(selection["can_continue"])
	if continuing and _matches_cancelled_remote_bud(host):
		return _continue_remote_bud()
	exit_remote_placement_mode()
	if _is_live_node(growth_input_controller):
		growth_input_controller.exit_placement_mode()
	var task_id: int = cultivation_system.continue_cultivation(host) if continuing \
		else cultivation_system.start_cultivation(host)
	refresh()
	if task_id <= 0:
		notice.emit("培育任务创建失败；请检查当前任务、连接和器官槽位")
		return false
	if selection["reason"] == &"insufficient_nutrition":
		notice.emit("已创建培育任务；营养不足，等待真实供养送达")
	else:
		notice.emit("已继续所选培育芽" if continuing else "已开始培育普通攻击器官")
	return true


func pause_cultivation() -> bool:
	if is_instance_valid(construction_coordinator) and construction_coordinator.multi_worker_enabled:
		return construction_coordinator.pause_request(String(construction_coordinator.get_snapshot().get("selected_id", "")))
	if _has_active_remote_request():
		var paused_remote: bool = remote_cultivation_system.pause_request()
		refresh()
		return paused_remote
	if not _is_live_node(cultivation_system):
		notice.emit("培育系统尚未配置")
		return false
	var paused_task: bool = cultivation_system.pause_task()
	refresh()
	if not paused_task:
		notice.emit("当前没有可暂停的培育任务")
	return paused_task


func resume_cultivation() -> bool:
	if is_instance_valid(construction_coordinator) and construction_coordinator.multi_worker_enabled:
		return construction_coordinator.resume_request(String(construction_coordinator.get_snapshot().get("selected_id", "")))
	if _has_active_remote_request():
		var resumed_remote: bool = remote_cultivation_system.resume_request()
		refresh()
		return resumed_remote
	if not _is_live_node(cultivation_system):
		notice.emit("培育系统尚未配置")
		return false
	var resumed_task: bool = cultivation_system.resume_task()
	refresh()
	if not resumed_task:
		notice.emit("当前没有可恢复的培育任务")
	return resumed_task


func cancel_cultivation() -> bool:
	if is_instance_valid(construction_coordinator) and construction_coordinator.multi_worker_enabled:
		return construction_coordinator.cancel_request(String(construction_coordinator.get_snapshot().get("selected_id", "")))
	if _has_active_remote_request():
		var cancelled_remote: bool = remote_cultivation_system.cancel_request()
		refresh()
		return cancelled_remote
	if not _is_live_node(cultivation_system):
		notice.emit("培育系统尚未配置")
		return false
	var cancelled_task: bool = cultivation_system.cancel_task()
	refresh()
	if not cancelled_task:
		notice.emit("当前没有可取消的培育任务")
	return cancelled_task


func handle_input(event: InputEvent) -> bool:
	if event == null or (event is InputEventKey and event.echo):
		return false
	if event.is_action_pressed("remote_cultivation_mode"):
		if _remote_placing:
			exit_remote_placement_mode()
		else:
			enter_remote_placement_mode()
		return true
	if event.is_action_pressed("cultivate_attack"):
		request_cultivation()
		return true
	if event.is_action_pressed("growth_mode"):
		exit_remote_placement_mode()
		if not is_instance_valid(construction_coordinator) and (_has_active_remote_request() \
				or (_is_live_node(cultivation_system) and cultivation_system.has_active_task())):
			notice.emit(String(REASON_TEXT[&"construction_busy"]))
			return true
		# 关卡随后转交普通生长输入；同一 G 事件只进入一次。
		return false
	var controls_cultivation: bool = _has_active_remote_request() \
		or (_is_live_node(cultivation_system) and cultivation_system.has_active_task())
	if controls_cultivation and event.is_action_pressed("growth_pause"):
		var snapshot: Dictionary = _get_current_build_snapshot()
		if snapshot.get("state", &"idle") == &"paused":
			resume_cultivation()
		else:
			pause_cultivation()
		return true
	if controls_cultivation and event.is_action_pressed("growth_cancel"):
		cancel_cultivation()
		return true
	if not _remote_placing:
		return false
	if event.is_action_pressed("cancel_selection"):
		exit_remote_placement_mode()
		return true
	if event is InputEventMouseMotion:
		preview_remote_at(_mouse_world_position(event.position))
		return true
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			exit_remote_placement_mode()
			return true
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				place_remote_target(_mouse_world_position(event.position))
			return true
	return false


func enter_remote_placement_mode() -> bool:
	refresh()
	var error: String = _remote_configuration_error()
	if not error.is_empty():
		notice.emit(error)
		return false
	if _has_active_build():
		notice.emit(String(REASON_TEXT[&"construction_busy"]))
		return false
	if _remote_placing:
		return true
	var marker: GrowthTarget = _instantiate_marker()
	if marker == null:
		return false
	if _is_live_node(growth_input_controller):
		growth_input_controller.exit_placement_mode()
	marker.name = "RemoteCultivationPreview"
	target_container.add_child(marker)
	_remote_preview_marker = marker
	_remote_placing = true
	set_process(true)
	remote_mode_changed.emit(true)
	preview_remote_at(target_container.get_global_mouse_position())
	return true


func exit_remote_placement_mode() -> void:
	if not _remote_placing:
		return
	_remote_placing = false
	set_process(false)
	_dispose_marker(_remote_preview_marker)
	_remote_preview_marker = null
	remote_mode_changed.emit(false)


func is_remote_placing() -> bool:
	return _remote_placing


func preview_remote_at(world_position: Vector2) -> Dictionary:
	var preview: Dictionary = _make_remote_preview(world_position)
	if _remote_placing and is_instance_valid(_remote_preview_marker):
		_remote_preview_marker.show_preview(preview)
	remote_preview_changed.emit(preview.duplicate(true))
	return preview


func place_remote_target(world_position: Vector2) -> bool:
	if not _remote_placing:
		notice.emit("按 B 进入远程攻击芽放置")
		return false
	var preview: Dictionary = preview_remote_at(world_position)
	if not bool(preview.get("valid", false)):
		notice.emit(String(preview.get("error", "目标不可放置")))
		return false
	if is_instance_valid(construction_coordinator):
		var result: Dictionary = construction_coordinator.enqueue(&"remote_cultivation", {
			"start_node": preview["start_node"], "target_position": world_position})
		if not bool(result.get("accepted", false)):
			return false
		exit_remote_placement_mode()
		return true
	# 可视场景准备好后才提交同一报价的起点；协调器复核并创建真实建造任务。
	var marker: GrowthTarget = _instantiate_marker()
	if marker == null:
		return false
	var start: Node2D = preview.get("start_node") as Node2D
	var request_id: int = remote_cultivation_system.request_remote(start, world_position)
	if request_id <= 0:
		marker.free()
		notice.emit("远程攻击芽创建失败；请检查当前任务、连接和器官槽位")
		refresh()
		return false
	_remote_quote = preview.duplicate(true)
	_replace_remote_marker(marker)
	exit_remote_placement_mode()
	refresh()
	notice.emit("已创建远程攻击芽：先延伸菌路，再供养攻击芽")
	return true


func _configuration_is_valid() -> bool:
	return _is_live_node(cultivation_system) and _is_live_node(cultivation_supply_system) \
		and _is_live_node(network_system) and _is_live_node(mother_core) \
		and cultivation_system.network_system == network_system \
		and cultivation_supply_system.cultivation_system == cultivation_system \
		and cultivation_supply_system.network_system == network_system \
		and cultivation_supply_system.mother_core == mother_core


func _remote_configuration_error() -> String:
	if not _is_live_node(remote_cultivation_system):
		return "远程培育系统尚未配置"
	if not _configuration_is_valid() or not _is_live_node(growth_system):
		return String(REASON_TEXT[&"invalid_configuration"])
	if remote_cultivation_system.growth_system != growth_system \
			or remote_cultivation_system.cultivation_system != cultivation_system \
			or remote_cultivation_system.cultivation_supply_system != cultivation_supply_system \
			or growth_system.network_system != network_system:
		return "预览与远程建造必须使用同一生长、培育和供养配置"
	if not _is_live_node(target_container):
		return "远程目标容器尚未配置"
	return ""


func _has_active_remote_request() -> bool:
	return _is_live_node(remote_cultivation_system) \
		and remote_cultivation_system.has_active_request()


func _has_active_build() -> bool:
	if is_instance_valid(construction_coordinator):
		return false
	return _has_active_remote_request() \
		or (_is_live_node(growth_system) and growth_system.has_active_task()) \
		or (_is_live_node(cultivation_system) and cultivation_system.has_active_task())


func _get_current_build_snapshot(remote_snapshot: Dictionary = {}) -> Dictionary:
	var current_remote: Dictionary = remote_snapshot
	if current_remote.is_empty() and _is_live_node(remote_cultivation_system):
		current_remote = remote_cultivation_system.get_request_snapshot()
	if _remote_owns_build(current_remote):
		return current_remote.duplicate(true)
	return cultivation_system.get_task_snapshot() if _is_live_node(cultivation_system) else {}


func _remote_owns_build(snapshot: Dictionary) -> bool:
	var request_id: int = int(snapshot.get("request_id", 0))
	if request_id <= 0:
		_observed_remote_request_id = 0
		return false
	var current_growth_id: int = int(growth_system.get_task_snapshot().get("task_id", 0)) \
		if _is_live_node(growth_system) else 0
	var current_cultivation_id: int = int(cultivation_system.get_task_snapshot().get("task_id", 0)) \
		if _is_live_node(cultivation_system) else 0
	if request_id != _observed_remote_request_id:
		_observed_remote_request_id = request_id
		_remote_growth_task_id = current_growth_id
		_remote_cultivation_task_id = current_cultivation_id
	_remote_growth_task_id = maxi(_remote_growth_task_id, int(snapshot.get("growth_task_id", 0)))
	_remote_cultivation_task_id = maxi(_remote_cultivation_task_id, int(snapshot.get("cultivation_task_id", 0)))
	if _has_active_remote_request():
		return true
	# 完成/取消标记保留到下一次建造；新普通任务身份不再被旧远程快照覆盖。
	return current_growth_id <= _remote_growth_task_id \
		and current_cultivation_id <= _remote_cultivation_task_id


func _matches_cancelled_remote_bud(host: HyphaNode) -> bool:
	if not _is_live_node(remote_cultivation_system) or not _is_live_node(host) \
			or not _is_live_node(cultivation_system):
		return false
	var snapshot: Dictionary = remote_cultivation_system.get_request_snapshot()
	var bud_snapshot: Dictionary = cultivation_system.get_bud_snapshot(host)
	return snapshot.get("state", &"idle") == &"cancelled" \
		and snapshot.get("phase", &"") == &"cultivation" \
		and snapshot.get("endpoint") == host \
		and int(snapshot.get("cultivation_task_id", 0)) > 0 \
		and int(bud_snapshot.get("task_id", 0)) == int(snapshot.get("cultivation_task_id", 0))


func _continue_remote_bud() -> bool:
	var error: String = _remote_configuration_error()
	if not error.is_empty():
		notice.emit(error)
		return false
	var marker: GrowthTarget = _instantiate_marker()
	if marker == null:
		return false
	var request_id: int = remote_cultivation_system.continue_request()
	if request_id <= 0:
		marker.free()
		notice.emit("远程培育芽暂时无法继续；请检查连接和退款结算")
		refresh()
		return false
	exit_remote_placement_mode()
	if _is_live_node(growth_input_controller):
		growth_input_controller.exit_placement_mode()
	_replace_remote_marker(marker)
	refresh()
	notice.emit("已继续远程攻击芽，保留已建菌路与已付结构")
	return true


func _make_remote_preview(world_position: Vector2) -> Dictionary:
	var preview: Dictionary = {
		"valid": false, "error": "", "start_node": null,
		"target_position": world_position, "plan": {},
		"network_cost": 0, "organ_cost": TOTAL_COST,
		"total_cost": TOTAL_COST, "remaining_cost": TOTAL_COST,
	}
	var error: String = _remote_configuration_error()
	if not error.is_empty():
		preview["error"] = error
		return preview
	if _has_active_build():
		preview["error"] = String(REASON_TEXT[&"construction_busy"])
		return preview
	if not world_position.is_finite() or not placement_bounds.has_point(world_position):
		preview["error"] = "目标必须位于可生长区域内"
		return preview
	if mother_core.health <= 0:
		preview["error"] = "母核不可用，无法放置远程攻击芽"
		return preview
	var start: Node2D = null
	var nearest_distance: float = INF
	for node: Node2D in network_system.get_registered_nodes():
		if not _is_live_node(node) or not (node is MotherCore or node is HyphaNode):
			continue
		if _overlaps_existing_host(node, world_position):
			preview["error"] = "目标在已有母核、菌结或器官的 24 像素范围内；请选择已有菌结后按 C 培育"
			return preview
		if not node.global_position.is_finite() or not network_system.is_connected_to_core(node):
			continue
		var distance: float = node.global_position.distance_squared_to(world_position)
		var nearer: bool = distance < nearest_distance
		var tie: bool = distance == nearest_distance and is_instance_valid(start)
		if nearer or (tie and node.get_instance_id() < start.get_instance_id()):
			start = node
			nearest_distance = distance
	if start == null:
		preview["error"] = "没有与存活母核连通的成熟生长起点"
		return preview
	if is_instance_valid(construction_coordinator):
		preview = construction_coordinator.preview(&"remote_cultivation", {
			"start_node": start, "target_position": world_position})
		preview["start_node"] = start
		preview["target_position"] = world_position
		return preview
	# 不裁减段数，也不另算费用；预览和提交均交给同一协调器复核。
	return remote_cultivation_system.preview_request(start, world_position).duplicate(true)


func _overlaps_existing_host(host: Node2D, point: Vector2) -> bool:
	var radius_squared: float = OVERLAP_RADIUS * OVERLAP_RADIUS
	if host.global_position.is_finite() \
			and host.global_position.distance_squared_to(point) <= radius_squared:
		return true
	for child: Node in host.get_children():
		if _is_live_node(child) and (child is AttackOrgan or child is OrganBud or child is DigestiveOrgan):
			var organ: Node2D = child as Node2D
			if organ.global_position.is_finite() \
					and organ.global_position.distance_squared_to(point) <= radius_squared:
				return true
	return false


func _instantiate_marker() -> GrowthTarget:
	var instance: Node = TARGET_SCENE.instantiate()
	if not instance is GrowthTarget:
		instance.free()
		notice.emit("目标场景必须使用 GrowthTarget")
		return null
	return instance as GrowthTarget


func _replace_remote_marker(marker: GrowthTarget) -> void:
	_dispose_marker(_remote_target_marker)
	marker.name = "RemoteCultivationTarget"
	target_container.add_child(marker)
	_remote_target_marker = marker
	if not _remote_quote.is_empty():
		_remote_target_marker.show_preview(_remote_quote)
	_remote_target_marker.show_status(remote_cultivation_system.get_request_snapshot())


func _refresh_remote_marker(snapshot: Dictionary) -> void:
	if not is_instance_valid(_remote_target_marker):
		return
	var request_id: int = int(snapshot.get("request_id", 0))
	if request_id <= 0:
		_dispose_marker(_remote_target_marker)
		_remote_target_marker = null
		_remote_quote = {}
	elif _remote_target_marker.get_task_id() == request_id:
		_remote_target_marker.show_status(snapshot)


func _dispose_marker(marker: GrowthTarget) -> void:
	if is_instance_valid(marker) and not marker.is_queued_for_deletion():
		marker.hide()
		marker.queue_free()


func _mouse_world_position(viewport_position: Vector2) -> Vector2:
	return target_container.get_canvas_transform().affine_inverse() * viewport_position \
		if _is_live_node(target_container) else viewport_position


func _connect_dependencies() -> void:
	var dependencies: Array = [
		cultivation_system, cultivation_supply_system, growth_system, network_system, mother_core,
		remote_cultivation_system, growth_input_controller,
	]
	if dependencies != _bound_dependencies:
		_disconnect_dependencies()
		_bound_dependencies = dependencies
	# 场景中向前引用的兄弟节点可能尚未入树；每次刷新重试未绑定信号。
	_bind_signal(cultivation_system, &"task_changed", _on_dependency_changed)
	_bind_signal(cultivation_supply_system, &"supply_changed", _on_dependency_changed)
	_bind_signal(growth_system, &"task_changed", _on_dependency_changed)
	_bind_signal(remote_cultivation_system, &"request_changed", _on_remote_request_changed)
	_bind_signal(growth_input_controller, &"mode_changed", _on_growth_mode_changed)
	_bind_signal(network_system, &"network_changed", _on_network_changed)
	_bind_signal(mother_core, &"nutrition_changed", _on_core_nutrition_changed)
	_bind_signal(mother_core, &"depleted", _on_core_depleted)


func _bind_signal(emitter: Variant, signal_name: StringName, callback: Callable) -> void:
	if not _is_live_node(emitter) or not emitter.has_signal(signal_name):
		return
	if emitter.is_connected(signal_name, callback):
		return
	emitter.connect(signal_name, callback)
	_dependency_bindings.append({"emitter": emitter, "signal": signal_name, "callback": callback})


func _disconnect_dependencies() -> void:
	for binding: Dictionary in _dependency_bindings:
		var emitter: Variant = binding["emitter"]
		var callback: Callable = binding["callback"]
		var signal_name: StringName = binding["signal"]
		if is_instance_valid(emitter) and emitter.is_connected(signal_name, callback):
			emitter.disconnect(signal_name, callback)
	_dependency_bindings.clear()
	_bound_dependencies = []


func _disconnect_selection() -> void:
	if not is_instance_valid(_selected_node):
		return
	if _selected_node.organ_slot_changed.is_connected(_on_slot_changed):
		_selected_node.organ_slot_changed.disconnect(_on_slot_changed)
	if _selected_node.tree_exiting.is_connected(_on_selected_node_exiting):
		_selected_node.tree_exiting.disconnect(_on_selected_node_exiting)


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and node.is_inside_tree() \
		and not node.is_queued_for_deletion()
