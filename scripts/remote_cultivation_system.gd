class_name RemoteCultivationSystem
extends Node
## 同一个建设请求先连接真实菌结，再交给既有培育和供给系统；本系统不持有营养。

signal request_changed(snapshot: Dictionary)
signal request_completed(request_id: int)
signal request_cancelled(request_id: int)
signal maturation_started(request_id: int, growth_task_id: int, cultivation_task_id: int, endpoint: HyphaNode)

const MAX_REQUEST_ID: int = 9223372036854775807
const EXISTING_NODE_RADIUS: float = 24.0
const EXISTING_NODE_REASON: String = "目标附近已有成熟菌结或器官，请选中已有节点并按 C 培育或继续培育。"

@export var growth_system: GrowthSystem
@export var cultivation_system: CultivationSystem
@export var growth_supply_system: GrowthSupplySystem
@export var cultivation_supply_system: CultivationSupplySystem

var _last_request_id: int = 0
var _request_id: int = 0
var _growth_task_id: int = 0
var _cultivation_task_id: int = 0
var _generation: int = 0
var _phase: StringName = &""
var _state: StringName = &"idle"
var _wait_reason: StringName = &""
var _start_node: Node2D = null
var _endpoint: HyphaNode = null
var _target_position: Vector2 = Vector2.ZERO
var _network_cost: int = 0
var _growth_snapshot: Dictionary = {}
var _cultivation_snapshot: Dictionary = {}
var _request_growth: GrowthSystem = null
var _request_cultivation: CultivationSystem = null
var _request_growth_supply: GrowthSupplySystem = null
var _request_cultivation_supply: CultivationSupplySystem = null
var _starting_phase: StringName = &""
var _starting_after_task_id: int = 0
var _creating_growth: bool = false
var _handoff_queued: bool = false
var _handoff_started: bool = false
var _extension_released: bool = false
var _transitioning: bool = false
var _resetting: bool = false
var _refreshing: bool = false
var _emitting_changed: bool = false
var _changed_pending: bool = false
var _cancel_notified: bool = false
var _watched_growth: GrowthSystem = null
var _watched_cultivation: CultivationSystem = null
var _watched_growth_supply: GrowthSupplySystem = null
var _watched_cultivation_supply: CultivationSupplySystem = null
var _watched_network: NetworkSystem = null
var _growth_callbacks: Array[Callable] = []
var _cultivation_callbacks: Array[Callable] = []
var _previous_growth_blocker: Callable = Callable()
var _growth_blocker: Callable = Callable()


func _ready() -> void:
	_bind_systems()


func _exit_tree() -> void:
	reset()
	_disconnect_growth()
	_disconnect_cultivation()
	_disconnect_supply(_watched_growth_supply)
	_disconnect_supply(_watched_cultivation_supply)
	_disconnect_network()


func _on_growth_changed(_snapshot: Dictionary, source: GrowthSystem) -> void:
	if source != _request_growth or _request_id == 0:
		return
	_refresh_snapshots()
	if has_active_request() and _phase == &"growth" \
			and StringName(_growth_snapshot.get("state", &"idle")) == &"cancelled":
		_mark_cancelled()
	else:
		_publish_changed()


func _on_growth_completed(task_id: int, source: GrowthSystem) -> void:
	if source != _request_growth or not has_active_request() or _phase != &"growth" \
			or task_id <= 0 or task_id != _growth_task_id:
		return
	var generation: int = _generation
	_refresh_snapshots()
	var actual: Dictionary = source.get_task_snapshot()
	if generation != _generation or not has_active_request() \
			or int(actual.get("task_id", 0)) != task_id \
			or StringName(actual.get("state", &"idle")) != &"completed" \
			or source.has_active_task():
		return
	_growth_snapshot = actual.duplicate()
	var endpoint: HyphaNode = source.get_completed_endpoint(task_id)
	if not _node_is_available(endpoint):
		_mark_cancelled()
		return
	_endpoint = endpoint
	_phase = &"connected"
	_state = &"connected"
	_wait_reason = &""
	_publish_changed()
	_queue_handoff()


func _on_growth_cancelled(task_id: int, source: GrowthSystem) -> void:
	if source != _request_growth or not has_active_request() or _phase != &"growth" \
			or task_id != _growth_task_id:
		return
	_refresh_snapshots()
	if StringName(_growth_snapshot.get("state", &"idle")) == &"cancelled":
		_mark_cancelled()


func _on_cultivation_changed(_snapshot: Dictionary, source: CultivationSystem) -> void:
	if source != _request_cultivation or _request_id == 0:
		return
	_refresh_snapshots()
	if has_active_request() and _phase == &"cultivation" \
			and StringName(_cultivation_snapshot.get("state", &"idle")) == &"cancelled":
		_mark_cancelled()
	else:
		_publish_changed()
		_queue_handoff()


func _on_cultivation_completed(task_id: int, source: CultivationSystem) -> void:
	if source != _request_cultivation or not has_active_request() or _phase != &"cultivation" \
			or task_id <= 0 or task_id != _cultivation_task_id:
		return
	var generation: int = _generation
	_refresh_snapshots()
	if generation != _generation or not has_active_request() \
			or StringName(_cultivation_snapshot.get("state", &"idle")) != &"completed" \
			or _cultivation_snapshot.get("host") != _endpoint \
			or not _node_is_available(_endpoint) \
			or not _endpoint.get_organ_occupant() is AttackOrgan \
			or int(_cultivation_snapshot.get("startup_transferred", 0)) != CultivationSystem.STARTUP_COST \
			or int(_cultivation_snapshot.get("structure_consumed", 0)) != CultivationSystem.STRUCTURE_COST \
			or float(_cultivation_snapshot.get("effective_time", 0.0)) < CultivationSystem.MINIMUM_EFFECTIVE_TIME \
			or int(_cultivation_snapshot.get("buffered_nutrition", 0)) != 0 \
			or int(_cultivation_snapshot.get("startup_reserved", 0)) != 0:
		return
	var completed_id: int = _request_id
	_state = &"completed"
	_wait_reason = &""
	_generation += 1
	_handoff_queued = false
	_publish_changed()
	request_completed.emit(completed_id)


func _on_cultivation_cancelled(task_id: int, source: CultivationSystem) -> void:
	if source != _request_cultivation or not has_active_request() or _phase != &"cultivation" \
			or task_id != _cultivation_task_id:
		return
	_refresh_snapshots()
	if StringName(_cultivation_snapshot.get("state", &"idle")) == &"cancelled":
		_mark_cancelled()


func _on_supply_changed(_snapshot: Dictionary) -> void:
	if _request_id == 0:
		return
	_refresh_snapshots()
	_publish_changed()
	_queue_handoff()


func _on_network_changed() -> void:
	_queue_handoff()


func preview_request(start_node: Node2D, target_position: Vector2) -> Dictionary:
	var result: Dictionary = {
		"valid": false, "error": "", "start_node": start_node if _node_is_available(start_node) else null,
		"target_position": target_position, "plan": {}, "network_cost": 0,
		"organ_cost": CultivationSystem.TOTAL_COST, "total_cost": 0, "remaining_cost": 0,
	}
	if not _configuration_is_valid():
		result["error"] = "远程培育系统配置尚未就绪。"
		return result
	if not _node_is_available(start_node) or not (start_node is HyphaNode or start_node is MotherCore):
		result["error"] = "请从已连接母核的成熟菌结或母核开始。"
		return result
	if not target_position.is_finite():
		result["error"] = "目标坐标无效。"
		return result
	if _target_is_near_existing_node(target_position):
		result["error"] = EXISTING_NODE_REASON
		return result
	if not growth_system.network_system.is_connected_to_core(start_node):
		result["error"] = "起点未连接母核。"
		return result
	var plan: Dictionary = growth_system.planner.plan(start_node.global_position, target_position, false)
	result["plan"] = plan
	if not bool(plan.get("valid", false)) or float(plan.get("distance", 0.0)) <= 0.0:
		result["error"] = "无法规划该生长目标：" + String(plan.get("error", "距离必须大于零。"))
		return result
	var network_cost: int = int(plan.get("total_cost", 0))
	if network_cost > MAX_REQUEST_ID - CultivationSystem.TOTAL_COST:
		result["error"] = "建设费用超出整数范围。"
		return result
	result["network_cost"] = network_cost
	result["total_cost"] = network_cost + CultivationSystem.TOTAL_COST
	result["remaining_cost"] = result["total_cost"]
	result["valid"] = true
	return result


func request_remote(start_node: Node2D, target_position: Vector2) -> int:
	if _transitioning or _resetting or _last_request_id == MAX_REQUEST_ID \
			or has_active_request() or not _construction_systems_are_idle():
		return 0
	_bind_systems()
	var preview: Dictionary = preview_request(start_node, target_position)
	if not bool(preview["valid"]) or not _construction_systems_are_idle():
		return 0
	_begin_request()
	_start_node = start_node
	_target_position = target_position
	_network_cost = int(preview["network_cost"])
	_growth_task_id = 0
	_cultivation_task_id = 0
	_endpoint = null
	_growth_snapshot = {}
	_cultivation_snapshot = {}
	_phase = &"growth"
	_state = &"waiting"
	_wait_reason = &"nutrition"
	_transitioning = true
	var created_id: int = _request_id
	var generation: int = _generation
	var receiver: GrowthSystem = _request_growth
	_publish_changed()
	var task_id: int = 0
	if _is_current_request(created_id, generation):
		_starting_phase = &"growth"
		_creating_growth = true
		task_id = receiver.create_target(start_node, target_position)
		_creating_growth = false
		_starting_phase = &""
		if _request_id == created_id and task_id > 0:
			_growth_task_id = task_id
			_refresh_snapshots()
		if not _is_current_request(created_id, generation):
			_cancel_started_growth(receiver, task_id)
	_transitioning = false
	if _request_id == created_id:
		_refresh_snapshots()
		if task_id == 0 and has_active_request():
			_mark_cancelled()
		else:
			_publish_changed()
	return created_id if task_id > 0 else 0


func has_active_request() -> bool:
	return _request_id > 0 and (_state == &"waiting" or _state == &"extending" \
		or _state == &"connected" or _state == &"cultivating" or _state == &"paused")


func get_request_snapshot() -> Dictionary:
	_refresh_snapshots()
	var growth_consumed: int = int(_growth_snapshot.get("consumed_nutrition", 0))
	var structure_consumed: int = int(_cultivation_snapshot.get("structure_consumed", 0))
	var startup_reserved: int = int(_cultivation_snapshot.get("startup_reserved", 0))
	var startup_transferred: int = int(_cultivation_snapshot.get("startup_transferred", 0))
	var buffered: int = int(_growth_snapshot.get("buffered_nutrition", 0)) \
		+ int(_cultivation_snapshot.get("buffered_nutrition", 0))
	var consumed: int = growth_consumed + structure_consumed + startup_transferred
	var total: int = _network_cost + CultivationSystem.TOTAL_COST if _request_id > 0 else 0
	var progress: float = 0.0
	if total > 0:
		progress = clampf((float(_growth_snapshot.get("progress", 0.0)) * _network_cost \
			+ float(_cultivation_snapshot.get("progress", 0.0)) * CultivationSystem.TOTAL_COST) / total, 0.0, 1.0)
	if _state == &"completed":
		progress = 1.0
	return {
		"request_id": _request_id, "task_id": _request_id,
		"growth_task_id": _growth_task_id, "cultivation_task_id": _cultivation_task_id,
		"phase": _phase, "state": _state, "wait_reason": _wait_reason,
		"extension_released": _extension_released,
		"endpoint": _endpoint if _node_is_available(_endpoint) else null,
		"target_position": _target_position, "progress": progress,
		"network_cost": _network_cost, "organ_cost": CultivationSystem.TOTAL_COST, "total_cost": total,
		"growth_consumed": growth_consumed, "structure_consumed": structure_consumed,
		"startup_reserved": startup_reserved, "startup_transferred": startup_transferred,
		"buffered_nutrition": buffered, "consumed_nutrition": consumed,
		"remaining_cost": maxi(0, total - consumed),
		"remaining_demand": maxi(0, total - consumed - buffered - startup_reserved),
		"growth_snapshot": _growth_snapshot.duplicate(), "cultivation_snapshot": _cultivation_snapshot.duplicate(),
	}


func pause_request() -> bool:
	if not has_active_request() or _state == &"paused" or _transitioning or _resetting:
		return false
	if _phase == &"connected":
		_state = &"paused"
		_wait_reason = &"paused"
		_publish_changed()
		return true
	return _change_stage_pause(true)


func resume_request() -> bool:
	if not has_active_request() or _state != &"paused" or _transitioning or _resetting:
		return false
	if _phase == &"connected":
		_state = &"connected"
		_wait_reason = &""
		_publish_changed()
		_queue_handoff()
		return true
	return _change_stage_pause(false)


func cancel_request() -> bool:
	if not has_active_request() or _resetting:
		return false
	_refresh_snapshots()
	if not has_active_request():
		return false
	var cancelled_id: int = _request_id
	var old_phase: StringName = _phase
	var growth_id: int = _growth_task_id
	var cultivation_id: int = _cultivation_task_id
	var receiver_growth: GrowthSystem = _request_growth
	var receiver_cultivation: CultivationSystem = _request_cultivation
	var previous_transition: bool = _transitioning
	var should_notify: bool = not _cancel_notified
	_cancel_notified = true
	_transitioning = true
	# 先提交请求终态，再调用会同步退款、发信号或触发重新放置的外部系统。
	_state = &"cancelled"
	_wait_reason = &""
	_generation += 1
	_handoff_queued = false
	_starting_phase = &""
	if old_phase == &"growth":
		_cancel_started_growth(receiver_growth, growth_id)
	elif old_phase == &"cultivation":
		_cancel_started_cultivation(receiver_cultivation, cultivation_id)
	_transitioning = previous_transition
	if _request_id == cancelled_id:
		_refresh_snapshots()
		_publish_changed()
	if should_notify:
		request_cancelled.emit(cancelled_id)
	return true


func continue_request() -> int:
	if _transitioning or _resetting or _state != &"cancelled" or _phase != &"cultivation" \
			or _cultivation_task_id <= 0 or not _node_is_available(_endpoint) \
			or _last_request_id == MAX_REQUEST_ID or not _construction_systems_are_idle() \
			or not _request_configuration_is_valid():
		return 0
	var availability: StringName = _request_cultivation.get_cultivation_availability(_endpoint)
	var bud_snapshot: Dictionary = _request_cultivation.get_bud_snapshot(_endpoint)
	if availability != &"continuable" or int(bud_snapshot.get("task_id", 0)) != _cultivation_task_id:
		return 0
	var prior_task_id: int = _cultivation_task_id
	var endpoint: HyphaNode = _endpoint
	var receiver: CultivationSystem = _request_cultivation
	_begin_request()
	_cultivation_task_id = 0
	_phase = &"cultivation"
	_state = &"waiting"
	_wait_reason = &"nutrition"
	_handoff_started = true
	_transitioning = true
	var created_id: int = _request_id
	var generation: int = _generation
	_publish_changed()
	var task_id: int = 0
	if _is_current_request(created_id, generation):
		_starting_phase = &"cultivation"
		_starting_after_task_id = prior_task_id
		task_id = receiver.continue_cultivation(endpoint)
		_starting_phase = &""
		if _request_id == created_id and task_id > 0:
			_cultivation_task_id = task_id
			_refresh_snapshots()
		if not _is_current_request(created_id, generation):
			_cancel_started_cultivation(receiver, task_id)
	_transitioning = false
	if _request_id == created_id:
		_refresh_snapshots()
		if task_id == 0 and has_active_request():
			_mark_cancelled()
		else:
			_notify_maturation_started(created_id, generation)
			_publish_changed()
	return created_id if task_id > 0 else 0


func reset() -> void:
	if _resetting:
		return
	_refresh_snapshots()
	var receiver_growth: GrowthSystem = _request_growth
	var receiver_cultivation: CultivationSystem = _request_cultivation
	var growth_id: int = _growth_task_id
	var cultivation_id: int = _cultivation_task_id
	_resetting = true
	_transitioning = true
	# 废弃身份在先；旧运输回调和已排队的交接只能看见 idle。
	_generation += 1
	_request_id = 0
	_growth_task_id = 0
	_cultivation_task_id = 0
	_phase = &""
	_state = &"idle"
	_wait_reason = &""
	_start_node = null
	_endpoint = null
	_target_position = Vector2.ZERO
	_network_cost = 0
	_growth_snapshot = {}
	_cultivation_snapshot = {}
	_request_growth = null
	_request_cultivation = null
	_request_growth_supply = null
	_request_cultivation_supply = null
	_starting_phase = &""
	_creating_growth = false
	_handoff_queued = false
	_handoff_started = false
	_extension_released = false
	_cancel_started_growth(receiver_growth, growth_id)
	_cancel_started_cultivation(receiver_cultivation, cultivation_id)
	_transitioning = false
	_resetting = false
	_publish_changed()


func _begin_request() -> void:
	_last_request_id += 1
	_request_id = _last_request_id
	_generation += 1
	_request_growth = growth_system
	_request_cultivation = cultivation_system
	_request_growth_supply = growth_supply_system
	_request_cultivation_supply = cultivation_supply_system
	_handoff_queued = false
	_handoff_started = false
	_extension_released = false
	_cancel_notified = false


func _refresh_snapshots() -> void:
	if _refreshing or _request_id == 0:
		return
	_refreshing = true
	var checked_id: int = _request_id
	var generation: int = _generation
	if _node_is_available(_request_growth):
		var snapshot: Dictionary = _request_growth.get_task_snapshot()
		if _is_same_identity(checked_id, generation):
			if _starting_phase == &"growth" and _growth_task_id == 0 \
					and _request_growth.has_active_task() and snapshot.get("start_node") == _start_node \
					and snapshot.get("target_position") == _target_position:
				_growth_task_id = int(snapshot.get("task_id", 0))
			if _growth_task_id > 0 and int(snapshot.get("task_id", 0)) == _growth_task_id:
				_growth_snapshot = snapshot.duplicate()
	if _is_same_identity(checked_id, generation) and _node_is_available(_request_cultivation):
		var snapshot: Dictionary = _request_cultivation.get_task_snapshot(_cultivation_task_id)
		if _is_same_identity(checked_id, generation):
			if _starting_phase == &"cultivation" and _cultivation_task_id == 0 \
					and int(snapshot.get("task_id", 0)) > _starting_after_task_id \
					and snapshot.get("host") == _endpoint:
				_cultivation_task_id = int(snapshot.get("task_id", 0))
			if _cultivation_task_id > 0 and int(snapshot.get("task_id", 0)) == _cultivation_task_id:
				_cultivation_snapshot = snapshot.duplicate()
	if _is_same_identity(checked_id, generation) and has_active_request():
		if _phase == &"growth" and not _growth_snapshot.is_empty():
			_sync_stage_state(_growth_snapshot, &"extending")
		elif _phase == &"cultivation" and not _cultivation_snapshot.is_empty():
			_sync_stage_state(_cultivation_snapshot, &"cultivating")
	_refreshing = false


func _sync_stage_state(snapshot: Dictionary, working_state: StringName) -> void:
	var stage_state: StringName = StringName(snapshot.get("state", &"idle"))
	if stage_state == &"paused" or stage_state == &"waiting" or stage_state == working_state:
		_state = stage_state
		_wait_reason = StringName(snapshot.get("wait_reason", &""))


func _queue_handoff() -> void:
	if not has_active_request() or _phase != &"connected" or _state == &"paused" \
			or _handoff_queued or _handoff_started or _resetting:
		return
	_handoff_queued = true
	_handoff.call_deferred(_generation, _request_id)


func _handoff(generation: int, request_id: int) -> void:
	if not _is_current_request(request_id, generation) or _phase != &"connected":
		return
	_handoff_queued = false
	if _state == &"paused" or _handoff_started or _transitioning:
		return
	if not _request_configuration_is_valid():
		_set_connected_wait_reason(&"invalid_configuration")
		return
	_refresh_snapshots()
	if not _is_current_request(request_id, generation):
		return
	var actual_growth: Dictionary = _request_growth.get_task_snapshot()
	if not _is_current_request(request_id, generation):
		return
	if not _node_is_available(_endpoint) \
			or _request_growth.get_completed_endpoint(_growth_task_id) != _endpoint \
			or int(actual_growth.get("task_id", 0)) != _growth_task_id \
			or StringName(actual_growth.get("state", &"idle")) != &"completed":
		_mark_cancelled()
		return
	_growth_snapshot = actual_growth.duplicate()
	# 该调用已离开 task_completed 的同步栈，GrowthSupply 的终态结算必须已经结束。
	if _request_growth_supply.get_in_transit_count() > 0 \
			or int(_growth_snapshot.get("buffered_nutrition", 0)) > 0 \
			or int(_request_growth_supply.get("_settlement_depth")) > 0 \
			or bool(_request_growth_supply.get("_dispatching")):
		_set_connected_wait_reason(&"settlement_pending")
		return
	var availability: StringName = _request_cultivation.get_cultivation_availability(_endpoint)
	if not _is_current_request(request_id, generation) or _state == &"paused":
		return
	if availability != &"ready":
		_set_connected_wait_reason(availability)
		return
	_handoff_started = true
	_transitioning = true
	_phase = &"cultivation"
	_state = &"waiting"
	_wait_reason = &"nutrition"
	var receiver: CultivationSystem = _request_cultivation
	var endpoint: HyphaNode = _endpoint
	_starting_after_task_id = int(receiver.get_task_snapshot().get("task_id", 0))
	_starting_phase = &"cultivation"
	var task_id: int = receiver.start_cultivation(endpoint)
	_starting_phase = &""
	if _request_id == request_id and task_id > 0:
		_cultivation_task_id = task_id
		_refresh_snapshots()
	if not _is_current_request(request_id, generation):
		_cancel_started_cultivation(receiver, task_id)
	_transitioning = false
	if _request_id == request_id:
		_refresh_snapshots()
		if task_id == 0 and has_active_request():
			_mark_cancelled()
		else:
			_notify_maturation_started(request_id, generation)
			_publish_changed()


## 只承认原培育系统已经提交的芽和任务；连接预览与完成通知本身不释放尖端。
func _notify_maturation_started(request_id: int, generation: int) -> void:
	if not _is_current_request(request_id, generation) or _extension_released \
			or _phase != &"cultivation" or _cultivation_task_id <= 0 \
			or not _node_is_available(_endpoint) or not _request_cultivation.has_active_task():
		return
	var growth: Dictionary = _request_growth.get_task_snapshot()
	var cultivation: Dictionary = _request_cultivation.get_task_snapshot(_cultivation_task_id)
	var bud: OrganBud = _endpoint.get_organ_bud()
	if not _is_current_request(request_id, generation) \
			or int(growth.get("task_id", 0)) != _growth_task_id or growth.get("state") != &"completed" \
			or _request_growth.get_completed_endpoint(_growth_task_id) != _endpoint \
			or int(growth.get("buffered_nutrition", 0)) != 0 \
			or _request_growth_supply.get_in_transit_count() != 0 \
			or int(_request_growth_supply.get("_settlement_depth")) > 0 \
			or bool(_request_growth_supply.get("_dispatching")) \
			or int(cultivation.get("task_id", 0)) != _cultivation_task_id \
			or cultivation.get("host") != _endpoint or not _node_is_available(bud) \
			or _endpoint.get_organ_occupant() != bud \
			or bud.get_snapshot().get("bud_id") != cultivation.get("bud_id") \
			or cultivation.get("wait_reason") == &"occupied":
		return
	_extension_released = true
	_publish_changed()
	if _is_current_request(request_id, generation) and _extension_released:
		maturation_started.emit(request_id, _growth_task_id, _cultivation_task_id, _endpoint)


func _set_connected_wait_reason(reason: StringName) -> void:
	if _wait_reason != reason:
		_wait_reason = reason
		_publish_changed()


func _change_stage_pause(paused: bool) -> bool:
	var request_id: int = _request_id
	var generation: int = _generation
	var changed: bool = false
	_transitioning = true
	if _phase == &"growth" and _same_growth_task(_request_growth, _growth_task_id):
		changed = _request_growth.pause_task() if paused else _request_growth.resume_task()
	elif _phase == &"cultivation" and _same_cultivation_task(_request_cultivation, _cultivation_task_id):
		changed = _request_cultivation.pause_task() if paused else _request_cultivation.resume_task()
	_transitioning = false
	if _is_current_request(request_id, generation):
		_refresh_snapshots()
		_publish_changed()
	return changed


func _mark_cancelled() -> void:
	if not has_active_request():
		return
	_state = &"cancelled"
	_wait_reason = &""
	_generation += 1
	_handoff_queued = false
	_starting_phase = &""
	_notify_cancelled()


func _notify_cancelled() -> void:
	if _cancel_notified or _request_id == 0:
		return
	var cancelled_id: int = _request_id
	_cancel_notified = true
	_publish_changed()
	request_cancelled.emit(cancelled_id)


func _is_same_identity(request_id: int, generation: int) -> bool:
	return _request_id == request_id and _generation == generation and not _resetting


func _is_current_request(request_id: int, generation: int) -> bool:
	return _is_same_identity(request_id, generation) and has_active_request()


func _same_growth_task(receiver: Variant, task_id: int) -> bool:
	return _node_is_available(receiver) and task_id > 0 and receiver.has_active_task() \
		and int(receiver.get_task_snapshot().get("task_id", 0)) == task_id


func _same_cultivation_task(receiver: Variant, task_id: int) -> bool:
	return _node_is_available(receiver) and task_id > 0 and receiver.has_active_task() \
		and int(receiver.get_task_snapshot().get("task_id", 0)) == task_id


func _cancel_started_growth(receiver: Variant, task_id: int) -> void:
	if _same_growth_task(receiver, task_id):
		receiver.cancel_task()


func _cancel_started_cultivation(receiver: Variant, task_id: int) -> void:
	if _same_cultivation_task(receiver, task_id):
		receiver.cancel_task()


func _construction_systems_are_idle() -> bool:
	if not _configuration_is_valid() or growth_system.has_active_task() or cultivation_system.has_active_task():
		return false
	var growth: Dictionary = growth_system.get_task_snapshot()
	var cultivation: Dictionary = cultivation_system.get_resource_snapshot()
	return not growth_system.has_active_task() and not cultivation_system.has_active_task() \
		and int(growth.get("buffered_nutrition", 0)) == 0 \
		and int(cultivation.get("buffered_nutrition", 0)) == 0 \
		and int(cultivation.get("startup_reserved", 0)) == 0 \
		and growth_supply_system.get_in_transit_count() == 0 \
		and cultivation_supply_system.get_in_transit_count() == 0


func _configuration_is_valid() -> bool:
	return _node_is_available(growth_system) and _node_is_available(cultivation_system) \
		and _node_is_available(growth_supply_system) and _node_is_available(cultivation_supply_system) \
		and growth_system.planner != null and _node_is_available(growth_system.network_system) \
		and _node_is_available(growth_system.node_container) and _node_is_available(growth_system.edge_container) \
		and _node_is_available(growth_system.tip_container) \
		and cultivation_system.network_system == growth_system.network_system \
		and growth_supply_system.growth_system == growth_system \
		and cultivation_supply_system.cultivation_system == cultivation_system \
		and growth_supply_system.network_system == growth_system.network_system \
		and cultivation_supply_system.network_system == cultivation_system.network_system


func _request_configuration_is_valid() -> bool:
	return _configuration_is_valid() and _request_growth == growth_system \
		and _request_cultivation == cultivation_system and _request_growth_supply == growth_supply_system \
		and _request_cultivation_supply == cultivation_supply_system


func _target_is_near_existing_node(target_position: Vector2) -> bool:
	var candidates: Array[Node] = []
	for registered: Node2D in growth_system.network_system.get_registered_nodes():
		candidates.append(registered)
	var container: Node = growth_system.node_container
	var placement_root: Node = container.get_parent() if container.get_parent() != null else container
	candidates.append(placement_root)
	while not candidates.is_empty():
		var candidate: Node = candidates.pop_back()
		if not _node_is_available(candidate):
			continue
		if candidate is HyphaNode or candidate is MotherCore:
			if candidate.global_position.distance_to(target_position) <= EXISTING_NODE_RADIUS:
				return true
			for child: Node in candidate.get_children():
				if _node_is_available(child) and (child is AttackOrgan or child is DigestiveOrgan or child is OrganBud) \
						and child.global_position.distance_to(target_position) <= EXISTING_NODE_RADIUS:
					return true
		candidates.append_array(candidate.get_children())
	return false


func _blocks_growth(source: GrowthSystem) -> bool:
	var own_creation: bool = source == _request_growth and _creating_growth \
		and _phase == &"growth" and _growth_task_id == 0 and has_active_request()
	if own_creation:
		# 仅放行本次 create_target 的入口；其同步回调不能借用同一许可另起生长。
		_creating_growth = false
	if _resetting or ((_transitioning or has_active_request()) and not own_creation):
		return true
	if _node_is_available(cultivation_system) and cultivation_system.has_active_task():
		return true
	return _previous_growth_blocker.is_valid() and bool(_previous_growth_blocker.call())


func _bind_systems() -> void:
	if _watched_growth != growth_system:
		_disconnect_growth()
		_watched_growth = growth_system if _node_is_available(growth_system) else null
		if _node_is_available(_watched_growth):
			_growth_callbacks = [_on_growth_changed.bind(_watched_growth),
				_on_growth_completed.bind(_watched_growth), _on_growth_cancelled.bind(_watched_growth)]
			_watched_growth.task_changed.connect(_growth_callbacks[0])
			_watched_growth.task_completed.connect(_growth_callbacks[1])
			_watched_growth.task_cancelled.connect(_growth_callbacks[2])
			_growth_blocker = _blocks_growth.bind(_watched_growth)
	if _node_is_available(_watched_growth) and _watched_growth.construction_blocker != _growth_blocker:
		_previous_growth_blocker = _watched_growth.construction_blocker
		_watched_growth.construction_blocker = _growth_blocker
	if _watched_cultivation != cultivation_system:
		_disconnect_cultivation()
		_watched_cultivation = cultivation_system if _node_is_available(cultivation_system) else null
		if _node_is_available(_watched_cultivation):
			_cultivation_callbacks = [_on_cultivation_changed.bind(_watched_cultivation),
				_on_cultivation_completed.bind(_watched_cultivation), _on_cultivation_cancelled.bind(_watched_cultivation)]
			_watched_cultivation.task_changed.connect(_cultivation_callbacks[0])
			_watched_cultivation.task_completed.connect(_cultivation_callbacks[1])
			_watched_cultivation.task_cancelled.connect(_cultivation_callbacks[2])
	if _watched_growth_supply != growth_supply_system:
		_disconnect_supply(_watched_growth_supply)
		_watched_growth_supply = growth_supply_system if _node_is_available(growth_supply_system) else null
		if _node_is_available(_watched_growth_supply):
			_watched_growth_supply.supply_changed.connect(_on_supply_changed)
	if _watched_cultivation_supply != cultivation_supply_system:
		_disconnect_supply(_watched_cultivation_supply)
		_watched_cultivation_supply = cultivation_supply_system if _node_is_available(cultivation_supply_system) else null
		if _node_is_available(_watched_cultivation_supply):
			_watched_cultivation_supply.supply_changed.connect(_on_supply_changed)
	var network: NetworkSystem = growth_system.network_system if _node_is_available(growth_system) else null
	if _watched_network != network:
		_disconnect_network()
		_watched_network = network if _node_is_available(network) else null
		if _node_is_available(_watched_network):
			_watched_network.network_changed.connect(_on_network_changed)


func _disconnect_growth() -> void:
	if is_instance_valid(_watched_growth):
		if _growth_callbacks.size() == 3:
			_watched_growth.task_changed.disconnect(_growth_callbacks[0])
			_watched_growth.task_completed.disconnect(_growth_callbacks[1])
			_watched_growth.task_cancelled.disconnect(_growth_callbacks[2])
		if _watched_growth.construction_blocker == _growth_blocker:
			_watched_growth.construction_blocker = _previous_growth_blocker
	_growth_callbacks.clear()
	_previous_growth_blocker = Callable()
	_growth_blocker = Callable()


func _disconnect_cultivation() -> void:
	if is_instance_valid(_watched_cultivation) and _cultivation_callbacks.size() == 3:
		_watched_cultivation.task_changed.disconnect(_cultivation_callbacks[0])
		_watched_cultivation.task_completed.disconnect(_cultivation_callbacks[1])
		_watched_cultivation.task_cancelled.disconnect(_cultivation_callbacks[2])
	_cultivation_callbacks.clear()


func _disconnect_supply(supply: Variant) -> void:
	if is_instance_valid(supply) and supply.supply_changed.is_connected(_on_supply_changed):
		supply.supply_changed.disconnect(_on_supply_changed)


func _disconnect_network() -> void:
	if is_instance_valid(_watched_network) and _watched_network.network_changed.is_connected(_on_network_changed):
		_watched_network.network_changed.disconnect(_on_network_changed)


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion()


func _publish_changed() -> void:
	_changed_pending = true
	if _emitting_changed:
		return
	_emitting_changed = true
	while _changed_pending:
		_changed_pending = false
		request_changed.emit(get_request_snapshot())
	_emitting_changed = false
