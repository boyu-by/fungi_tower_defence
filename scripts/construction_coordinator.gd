class_name ConstructionCoordinator
extends Node
## 按能力分配独立原执行器；默认保留串行夹具，只保存身份和只读资源汇总。

signal changed(snapshot: Dictionary)
signal notice(message: String)
signal request_finished(construction_id: String, state: StringName)
signal organ_matured(construction_id: String, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon)

class WorkerContext:
	extends RefCounted

	var queue_source: ConstructionQueue
	var construction_id: String = ""
	var generation: int = 0
	var epoch: int = 0
	var kind: StringName = &""
	var parameters: Dictionary = {}
	var payer: MotherCore
	var payer_id: int = 0
	var network: NetworkSystem
	var worker: ConstructionWorker
	var admission_order: int = 0
	var starting: bool = false
	var finishing: bool = false
	var pause_on_start: bool = false
	var detail: Dictionary = {}
	var internal_ids: Dictionary = {"growth_task_id": 0, "remote_request_id": 0, "cultivation_task_id": 0}

class ExecutionContext:
	extends RefCounted

	var queue_source: ConstructionQueue
	var construction_id: String = ""
	var generation: int = 0
	var epoch: int = 0
	var kind: StringName = &""
	var parameters: Dictionary = {}
	var payer: MotherCore
	var payer_id: int = 0
	var network: NetworkSystem
	var growth: GrowthSystem
	var growth_supply: GrowthSupplySystem
	var remote: RemoteCultivationSystem
	var connection: ConnectionSystem
	var cultivation: CultivationSystem
	var cultivation_supply: CultivationSupplySystem
	var growth_before: int = 0
	var remote_before: int = 0
	var internal_ids: Dictionary = {
		"growth_task_id": 0, "remote_request_id": 0, "cultivation_task_id": 0,
	}
	var detail: Dictionary = {}
	var starting: bool = false
	var cancel_requested: bool = false
	var identity_lost: bool = false

@export var queue: ConstructionQueue
@export var mother_core: MotherCore
@export var cargo_passage_tracker: CargoPassageTracker
@export var network_system: NetworkSystem
@export var growth_system: GrowthSystem
@export var growth_supply_system: GrowthSupplySystem
@export var remote_cultivation_system: RemoteCultivationSystem
@export var connection_system: ConnectionSystem
@export var cultivation_system: CultivationSystem
@export var cultivation_supply_system: CultivationSupplySystem
@export var auto_execute: bool = true
@export var multi_worker_enabled: bool = false
@export var worker_container: Node
@export var supply_scheduler: ConstructionSupplyScheduler
@export var worker_scene: PackedScene = preload("res://scenes/systems/construction_worker.tscn")

var _execution: ExecutionContext = null
var _retiring: Array[ExecutionContext] = []
var _bindings: Array[Dictionary] = []
var _binding_keys: Dictionary[String, bool] = {}
var _epoch: int = 0
var _operation_depth: int = 0
var _accepting: int = 0
var _pumping: bool = false
var _syncing: bool = false
var _resetting: bool = false
var _exiting: bool = false
var _next_pump_token: int = 0
var _queued_pump_token: int = 0
var _settlement_barrier: bool = false
var _barrier_token: int = 0
var _last_snapshot: Dictionary = {}
var _worker_contexts: Dictionary[String, WorkerContext] = {}
var _request_workers: Dictionary[String, ConstructionWorker] = {}
var _workers: Array[ConstructionWorker] = []
var _worker_registrations: Dictionary[int, ConstructionSupplyScheduler] = {}
var _admissions: Dictionary[String, Dictionary] = {}
var _local_continuations: Dictionary[String, ConstructionWorker] = {}
var _archived_resources: Dictionary = {"network_structure": 0, "organ_structure": 0, "startup_transferred": 0}
var _archived_workers: Dictionary[int, Dictionary] = {}
var _next_worker_admission: int = 0
var _scheduler_paused_for_reset: ConstructionSupplyScheduler
var _scheduler_auto_before_reset: bool = false


func _ready() -> void:
	_set_queue_mode()
	_bind_sources()
	_publish_snapshot()
	_schedule_pump()


func _process(_delta: float) -> void:
	if _resetting or _exiting:
		return
	_bind_sources()
	if multi_worker_enabled:
		_sync_workers()
		_sweep_workers()
		_publish_snapshot()
		if not _worker_contexts.is_empty() or (_node_is_available(queue) and not queue.get_active_requests().is_empty()):
			_schedule_pump()
		return
	_sync_execution()
	if _execution != null or not _retiring.is_empty() \
			or (_node_is_available(queue) and not queue.get_snapshot()["entries"].is_empty()):
		_schedule_pump()


func _exit_tree() -> void:
	_exiting = true
	reset()
	for binding: Dictionary in _bindings:
		var source: Variant = binding["source"]
		if is_instance_valid(source) and source.is_connected(binding["signal"], binding["callback"]):
			source.disconnect(binding["signal"], binding["callback"])
	_bindings.clear()
	_binding_keys.clear()


func _on_queue_changed(_snapshot: Dictionary, source: ConstructionQueue) -> void:
	if source != queue or _exiting:
		return
	if multi_worker_enabled:
		if not _resetting:
			_sync_workers()
		_publish_snapshot()
		_schedule_pump()
		return
	if not _resetting and _execution != null \
			and (_execution.queue_source != source or source.get_generation() != _execution.generation \
				or source.get_request(_execution.construction_id).is_empty()):
		# 即使外部直接 reset 队列，也只取消原编号，不把旧施工领养到新队列。
		var context: ExecutionContext = _execution
		_execution = null
		_epoch += 1
		_queued_pump_token = 0
		_operation_depth += 1
		context.cancel_requested = true
		_retire(context)
		_cancel_context_executor(context)
		_defer_settlement()
		_operation_depth -= 1
	_publish_snapshot()
	_schedule_pump()


func _on_growth_changed(_snapshot: Dictionary, source: GrowthSystem) -> void:
	if source == growth_system or (_execution != null and source == _execution.growth):
		_sync_execution()
		_schedule_pump()


func _on_growth_terminal(task_id: int, source: GrowthSystem) -> void:
	if _execution != null and source == _execution.growth:
		if task_id <= 0 or task_id != int(_execution.internal_ids["growth_task_id"]):
			return
		var actual: Dictionary = source.get_task_snapshot()
		if int(actual.get("task_id", 0)) != task_id \
				or not [&"completed", &"cancelled"].has(actual.get("state")):
			return
		_sync_execution()
	if source == growth_system:
		_schedule_pump()


func _on_remote_changed(_snapshot: Dictionary, source: RemoteCultivationSystem) -> void:
	if source == remote_cultivation_system or (_execution != null and source == _execution.remote):
		_sync_execution()
		_schedule_pump()


func _on_remote_terminal(request_id: int, source: RemoteCultivationSystem) -> void:
	if _execution != null and source == _execution.remote and _execution.kind == &"remote_cultivation":
		if request_id <= 0 or request_id != int(_execution.internal_ids["remote_request_id"]):
			return
		var actual: Dictionary = source.get_request_snapshot()
		if int(actual.get("request_id", 0)) != request_id \
				or not [&"completed", &"cancelled"].has(actual.get("state")):
			return
		_sync_execution()
	if source == remote_cultivation_system:
		_schedule_pump()


func _on_connection_changed(_snapshot: Dictionary, source: ConnectionSystem) -> void:
	if source == connection_system or (_execution != null and source == _execution.connection):
		_sync_execution()
		_schedule_pump()


func _on_connection_terminal(task_id: int, source: ConnectionSystem) -> void:
	if _execution != null and source == _execution.connection and _execution.kind == &"connection":
		if task_id <= 0 or task_id != int(_execution.internal_ids["growth_task_id"]):
			return
		var actual: Dictionary = source.get_task_snapshot()
		if int(actual.get("task_id", 0)) != task_id \
				or not [&"completed", &"cancelled"].has(actual.get("state")):
			return
		_sync_execution()
	if source == connection_system:
		_schedule_pump()


func _on_cultivation_changed(_snapshot: Dictionary, source: CultivationSystem) -> void:
	if source == cultivation_system or (_execution != null and source == _execution.cultivation):
		_sync_execution()
		_schedule_pump()


func _on_cultivation_terminal(task_id: int, source: CultivationSystem) -> void:
	if _execution != null and source == _execution.cultivation \
			and _execution.kind == &"remote_cultivation":
		if task_id <= 0 or task_id != int(_execution.internal_ids["cultivation_task_id"]):
			return
		var actual: Dictionary = source.get_task_snapshot()
		if int(actual.get("task_id", 0)) != task_id \
				or not [&"completed", &"cancelled"].has(actual.get("state")):
			return
		_sync_execution()
	if source == cultivation_system:
		_schedule_pump()


func _on_supply_changed(_snapshot: Dictionary) -> void:
	_sync_execution()
	_schedule_pump()


func _on_network_changed() -> void:
	_sync_execution()
	_schedule_pump()


func preview(kind: StringName, parameters: Dictionary) -> Dictionary:
	_accepting += 1
	var result: Dictionary = _preview_request(kind, parameters, mother_core)
	_accepting -= 1
	return result.duplicate(true)


func enqueue(kind: StringName, parameters: Dictionary) -> Dictionary:
	_set_queue_mode()
	if _resetting or _exiting or not _node_is_available(queue):
		return _enqueue_result(false, "", &"invalid_configuration")
	_accepting += 1
	_bind_sources()
	var source: ConstructionQueue = queue
	var generation: int = source.get_generation()
	var snapshot: Dictionary = source.get_snapshot()
	var result: Dictionary
	# 去重和满额的结果由队列本身决定，不能被实时忙碌或预览状态覆盖。
	if not source._find_duplicate(kind, parameters).is_empty() \
			or snapshot["entries"].size() >= int(snapshot["limit"]):
		result = source.enqueue(kind, parameters, mother_core)
	else:
		var planned: Dictionary = _preview_request(kind, parameters, mother_core)
		if not bool(planned["valid"]) and planned["reason"] != &"disconnected":
			result = _enqueue_result(false, "", StringName(planned["reason"]))
		elif source != queue or source.get_generation() != generation or _resetting or _exiting:
			result = _enqueue_result(false, "", &"reset")
		else:
			result = source.enqueue(kind, parameters, mother_core)
			if bool(result["accepted"]) and source == queue and source.get_generation() == generation:
				if multi_worker_enabled:
					_admissions[String(result["construction_id"])] = planned.duplicate(true)
				source._coordinator_update(String(result["construction_id"]), generation, &"waiting", \
					&"queued", {}, planned)
	if not bool(result["accepted"]):
		notice.emit(_error_for_reason(StringName(result["reason"])))
	_schedule_pump()
	_accepting -= 1
	return result


func get_snapshot() -> Dictionary:
	if not _node_is_available(queue):
		return {"entries": [], "maturing": [], "active_ids": [], "selected_id": "", "active_id": "", \
			"limit": 0, "generation": 0, "tip_count": 0, "tip_limit": 1, "external_count": 0, \
			"waiting_count": 0, "maturing_count": 0}
	_set_queue_mode()
	return queue.get_snapshot()


func get_request(construction_id: String) -> Dictionary:
	return queue.get_request(construction_id) if _node_is_available(queue) else {}


func select_request(construction_id: String) -> bool:
	return not _resetting and not _exiting and _node_is_available(queue) \
		and queue.select_request(construction_id)


func move_request(construction_id: String, direction: int) -> bool:
	if _resetting or _exiting or not _node_is_available(queue):
		return false
	_operation_depth += 1
	var moved: bool = queue.move_request(construction_id, direction)
	_operation_depth -= 1
	if moved:
		_schedule_pump()
	return moved


func pause_request(construction_id: String) -> bool:
	return _change_pause(construction_id, true)


func resume_request(construction_id: String) -> bool:
	return _change_pause(construction_id, false)


func cancel_request(construction_id: String) -> bool:
	if multi_worker_enabled:
		return _cancel_worker_request(construction_id)
	if _resetting or _exiting or not _node_is_available(queue):
		return false
	_sync_execution()
	var request: Dictionary = queue.get_request(construction_id)
	if request.is_empty() or ConstructionQueue.TERMINAL_STATES.has(request["state"]):
		return false
	_operation_depth += 1
	var cancelled: bool = false
	if not bool(request["started"]):
		var generation: int = queue.get_generation()
		cancelled = queue.cancel_request(construction_id)
		if cancelled and _node_is_available(queue) and queue.get_generation() == generation:
			request_finished.emit(construction_id, &"cancelled")
	elif _execution != null and _execution.construction_id == construction_id \
			and _context_is_current(_execution):
		var context: ExecutionContext = _execution
		cancelled = _finish_execution(context, &"cancelled", &"", context.detail, true)
	_operation_depth -= 1
	_schedule_pump()
	return cancelled


func pump() -> void:
	if is_inside_tree() and not can_process():
		return
	if multi_worker_enabled:
		_pump_workers()
		return
	if _resetting or _exiting or _pumping or _operation_depth > 0 or _accepting > 0 \
			or _syncing or _settlement_barrier or not _node_is_available(queue):
		return
	_bind_sources()
	_pumping = true
	var epoch: int = _epoch
	var source: ConstructionQueue = queue
	var generation: int = source.get_generation()
	_sync_execution()
	_sweep_retiring()
	var can_dispatch: bool = _execution == null and _epoch == epoch \
		and source == queue and source.get_generation() == generation and not _settlement_barrier
	while can_dispatch:
		var pending: Dictionary = _first_unpaused_request(source)
		if pending.is_empty():
			break
		var construction_id: String = String(pending["construction_id"])
		var planned: Dictionary = _preview_request(pending["kind"], pending["parameters"], pending["payer"])
		if _epoch != epoch or source != queue or source.get_generation() != generation \
				or source.get_request(construction_id).is_empty():
			break
		if not bool(planned["valid"]) and planned["reason"] != &"disconnected":
			_finish_pending(source, construction_id, generation, &"failed", \
				StringName(planned["reason"]), planned)
			can_dispatch = _epoch == epoch and source == queue \
				and source.get_generation() == generation and _execution == null
		elif planned["reason"] == &"disconnected":
			source._coordinator_update(construction_id, generation, &"waiting", &"disconnected", {}, planned)
			break
		elif not _pipeline_is_idle():
			source._coordinator_update(construction_id, generation, &"waiting", &"pipeline_busy", {}, planned)
			break
		elif _epoch != epoch or source != queue or source.get_generation() != generation \
				or _execution != null:
			break
		else:
			_start_execution(source, pending, generation, epoch)
			break
	_pumping = false


func reset() -> void:
	if multi_worker_enabled or not _workers.is_empty():
		_reset_workers()
		return
	if _resetting:
		return
	_resetting = true
	_epoch += 1
	_queued_pump_token = 0
	_operation_depth += 1
	var source: ConstructionQueue = queue if _node_is_available(queue) else null
	var generation: int = source._invalidate_generation() if source != null else 0
	var context: ExecutionContext = _execution
	_execution = null
	if context != null:
		context.cancel_requested = true
		_retire(context)
	for retired: ExecutionContext in _retiring.duplicate():
		if retired.cancel_requested:
			_cancel_context_executor(retired)
	if source != null:
		source._clear_generation(generation)
	_operation_depth -= 1
	_resetting = false
	_defer_settlement()
	_publish_snapshot()


func _change_pause(construction_id: String, paused: bool) -> bool:
	if multi_worker_enabled:
		return _change_worker_pause(construction_id, paused)
	if _resetting or _exiting or not _node_is_available(queue):
		return false
	_sync_execution()
	var request: Dictionary = queue.get_request(construction_id)
	if request.is_empty() or ConstructionQueue.TERMINAL_STATES.has(request["state"]):
		return false
	_operation_depth += 1
	var did_change: bool = false
	if not bool(request["started"]):
		did_change = queue.pause_request(construction_id) if paused else queue.resume_request(construction_id)
	elif _execution != null and _execution.construction_id == construction_id \
			and _context_is_current(_execution):
		var context: ExecutionContext = _execution
		if _matching_executor_is_active(context):
			match context.kind:
				&"growth":
					did_change = context.growth.pause_task() if paused else context.growth.resume_task()
				&"remote_cultivation":
					did_change = context.remote.pause_request() if paused else context.remote.resume_request()
				&"connection":
					did_change = context.connection.pause_task() if paused else context.connection.resume_task()
		_sync_execution()
	_operation_depth -= 1
	if did_change:
		_schedule_pump()
	return did_change


func _preview_request(kind: StringName, parameters: Dictionary, payer: Variant) -> Dictionary:
	var result: Dictionary = _empty_preview(kind, parameters)
	if _resetting or _exiting:
		return _reject_preview(result, &"reset")
	if not ConstructionQueue.KINDS.has(kind):
		return _reject_preview(result, &"invalid_kind")
	if not _configuration_is_valid(kind):
		return _reject_preview(result, &"invalid_configuration")
	var payer_reason: StringName = _payer_reason(kind, payer)
	if payer_reason != &"":
		return _reject_preview(result, payer_reason)
	if kind == &"connection":
		return _preview_connection(parameters, result, payer)
	var start: Variant = parameters.get("start_node")
	var target: Variant = parameters.get("target_position")
	if not _node_is_available(start) or not (start is HyphaNode or start is MotherCore):
		return _reject_preview(result, &"invalid_endpoint")
	if not network_system.is_node_registered(start):
		return _reject_preview(result, &"unregistered_endpoint")
	if not target is Vector2 or not target.is_finite() or not start.global_position.is_finite():
		return _reject_preview(result, &"invalid_target")
	if kind == &"remote_cultivation":
		var remote_preview: Dictionary = remote_cultivation_system.preview_request(start, target, parameters.get("organ_kind", &"attack"))
		result.merge(remote_preview, true)
		result["reason"] = &""
		if not bool(result["valid"]):
			var reason: StringName = &"invalid_target"
			if result["error"] == RemoteCultivationSystem.EXISTING_NODE_REASON:
				reason = &"occupied_target"
			elif result["error"] == "起点未连接母核。":
				# 即使断网也先保存合法几何，供等待行显示费用。
				reason = &"disconnected"
				var plan: Dictionary = growth_system.preview_target(start, target)
				result["plan"] = plan
				if not bool(plan.get("valid", false)) or float(plan.get("distance", 0.0)) <= 0.0:
					reason = &"invalid_target"
				else:
					result["network_cost"] = int(plan.get("total_cost", 0))
					result["total_cost"] = int(result["network_cost"]) + int(CultivationSystem.get_recipe(parameters.get("organ_kind", &"attack")).get("total_cost", 0))
					result["remaining_cost"] = result["total_cost"]
			result["reason"] = reason
			return result
	else:
		var plan: Dictionary = growth_system.preview_target(start, target)
		result["plan"] = plan
		result["total_cost"] = int(plan.get("total_cost", 0))
		if not bool(plan.get("valid", false)) or float(plan.get("distance", 0.0)) <= 0.0:
			return _reject_preview(result, &"invalid_target", String(plan.get("error", "目标距离必须大于零。")))
	if not _node_is_available(start) or not network_system.is_node_registered(start):
		return _reject_preview(result, &"invalid_endpoint")
	if not network_system.is_available_connected_to_core(start):
		return _reject_preview(result, &"disconnected")
	if _payer_reason(kind, payer) != &"" or not _node_is_available(start):
		return _reject_preview(result, &"payer_replaced")
	result["valid"] = true
	return result


func _preview_connection(parameters: Dictionary, result: Dictionary, payer: MotherCore) -> Dictionary:
	var first: Variant = parameters.get("first_node")
	var second: Variant = parameters.get("second_node")
	if not _node_is_available(first) or not first is HyphaNode \
			or not _node_is_available(second) or not second is HyphaNode:
		return _reject_preview(result, &"invalid_endpoint")
	if first == second:
		return _reject_preview(result, &"same_node")
	if not network_system.is_node_registered(first) or not network_system.is_node_registered(second):
		return _reject_preview(result, &"unregistered_endpoint")
	if not first.global_position.is_finite() or not second.global_position.is_finite():
		return _reject_preview(result, &"invalid_target")
	if network_system.has_direct_connection(first, second):
		return _reject_preview(result, &"already_connected")
	if not _node_is_available(first) or not _node_is_available(second):
		return _reject_preview(result, &"invalid_endpoint")
	var first_connected: bool = network_system.find_route(first, payer).found
	var second_connected: bool = network_system.find_route(second, payer).found
	if not _node_is_available(first) or not _node_is_available(second):
		return _reject_preview(result, &"invalid_endpoint")
	var source: HyphaNode = first if first_connected or not second_connected else second
	var target: HyphaNode = second if source == first else first
	result["start_node"] = source
	result["target_node"] = target
	result["reversed"] = source != first
	var plan: Dictionary = growth_system.planner.plan(source.global_position, target.global_position, true)
	result["plan"] = plan
	result["total_cost"] = int(plan.get("total_cost", 0))
	if not bool(plan.get("valid", false)) or float(plan.get("distance", 0.0)) <= 0.0:
		return _reject_preview(result, &"invalid_target", String(plan.get("error", "重合菌结无法施工。")))
	if (not first_connected and not second_connected) \
			or not network_system.is_available_connected_to_core(source):
		return _reject_preview(result, &"disconnected")
	if _payer_reason(&"connection", payer) != &"" \
			or not _node_is_available(source) or not _node_is_available(target):
		return _reject_preview(result, &"payer_replaced")
	result["valid"] = true
	return result


func _empty_preview(kind: StringName, parameters: Dictionary) -> Dictionary:
	var result: Dictionary = {"valid": false, "reason": &"", "error": "", "plan": {}, "total_cost": 0}
	if kind == &"connection":
		result.merge({"first_node": parameters.get("first_node"), "second_node": parameters.get("second_node"), \
			"start_node": null, "target_node": null, "reversed": false})
	else:
		result.merge({"start_node": parameters.get("start_node"), \
			"target_position": parameters.get("target_position", Vector2.ZERO)})
		if kind == &"remote_cultivation":
			result.merge({"network_cost": 0, "organ_kind": parameters.get("organ_kind", &"attack"), "organ_cost": int(CultivationSystem.get_recipe(parameters.get("organ_kind", &"attack")).get("total_cost", 0)), "remaining_cost": 0})
	return result


func _configuration_is_valid(kind: StringName) -> bool:
	var valid: bool = _node_is_available(network_system) and _node_is_available(growth_system) \
		and _node_is_available(growth_supply_system) and growth_system.planner != null \
		and growth_system.network_system == network_system \
		and growth_supply_system.network_system == network_system \
		and growth_supply_system.growth_system == growth_system \
		and _node_is_available(growth_system.node_container) \
		and _node_is_available(growth_system.edge_container) and _node_is_available(growth_system.tip_container)
	if kind == &"connection":
		valid = valid and _node_is_available(connection_system) and connection_system.growth_system == growth_system
	elif kind == &"remote_cultivation":
		valid = valid and _node_is_available(remote_cultivation_system) \
			and _node_is_available(cultivation_system) and _node_is_available(cultivation_supply_system) \
			and cultivation_system.network_system == network_system \
			and cultivation_supply_system.network_system == network_system \
			and cultivation_supply_system.cultivation_system == cultivation_system \
			and remote_cultivation_system.growth_system == growth_system \
			and remote_cultivation_system.growth_supply_system == growth_supply_system \
			and remote_cultivation_system.cultivation_system == cultivation_system \
			and remote_cultivation_system.cultivation_supply_system == cultivation_supply_system
	if multi_worker_enabled:
		valid = valid and _node_is_available(worker_container) and _node_is_available(supply_scheduler) \
			and worker_scene != null and worker_scene.can_instantiate() \
			and _node_is_available(cultivation_system) and _node_is_available(cultivation_supply_system) \
			and _node_is_available(cultivation_system.enemy_container) \
			and _node_is_available(cultivation_system.projectile_container) \
			and _node_is_available(growth_supply_system.packet_container) \
			and _node_is_available(cultivation_supply_system.packet_container)
	return valid


func _payer_reason(kind: StringName, payer: Variant) -> StringName:
	if not _node_is_available(payer) or not payer is MotherCore or payer.health <= 0:
		return &"core_unavailable"
	if mother_core != payer or not _node_is_available(network_system) \
			or network_system.peek_registered_core() != payer \
			or not _node_is_available(growth_supply_system) or growth_supply_system.mother_core != payer:
		return &"payer_replaced"
	if kind == &"connection" and (not _node_is_available(connection_system) or connection_system.mother_core != payer):
		return &"payer_replaced"
	if (kind == &"remote_cultivation" or kind == &"cultivation") and (not _node_is_available(cultivation_supply_system) \
			or cultivation_supply_system.mother_core != payer):
		return &"payer_replaced"
	return &""


func _first_unpaused_request(source: ConstructionQueue) -> Dictionary:
	for request: Dictionary in source.get_snapshot()["entries"]:
		if not bool(request["started"]) and request["state"] == &"waiting":
			return request
	return {}


func _start_execution(source: ConstructionQueue, request: Dictionary, generation: int, epoch: int) -> void:
	var context: ExecutionContext = ExecutionContext.new()
	context.queue_source = source
	context.construction_id = String(request["construction_id"])
	context.generation = generation
	context.epoch = epoch
	context.kind = request["kind"]
	context.parameters = request["parameters"].duplicate(true)
	context.payer = request["payer"]
	context.payer_id = int(request["payer_id"])
	context.network = network_system
	context.growth = growth_system
	context.growth_supply = growth_supply_system
	context.remote = remote_cultivation_system
	context.connection = connection_system
	context.cultivation = cultivation_system
	context.cultivation_supply = cultivation_supply_system
	context.growth_before = int(context.growth.get_task_snapshot().get("task_id", 0))
	if _node_is_available(context.remote):
		context.remote_before = int(context.remote.get_request_snapshot().get("request_id", 0))
	if source != queue or source.get_generation() != generation or epoch != _epoch \
			or _execution != null or _resetting or _exiting:
		return
	_execution = context
	context.starting = true
	_operation_depth += 1
	var can_start: bool = source._coordinator_start(context.construction_id, generation)
	var internal_id: int = 0
	if can_start and _context_is_current(context):
		# changed 的同步观察者可能刚移动/删除端点；正式入口前再次检查捕获参数。
		var checked: Dictionary = _preview_request(context.kind, context.parameters, context.payer)
		if _context_is_current(context) and checked["reason"] == &"disconnected":
			_execution = null
			source._coordinator_unstart(context.construction_id, generation, &"disconnected", checked)
		elif _context_is_current(context) and bool(checked["valid"]) and not _pipeline_is_idle():
			_execution = null
			source._coordinator_unstart(context.construction_id, generation, &"pipeline_busy", checked)
		elif _context_is_current(context) and bool(checked["valid"]):
			match context.kind:
				&"growth":
					internal_id = context.growth.create_target(context.parameters["start_node"], \
						context.parameters["target_position"], int(context.parameters.get("plan_version", 1)))
				&"remote_cultivation":
					internal_id = context.remote.request_remote(context.parameters["start_node"], \
						context.parameters["target_position"], context.parameters.get("organ_kind", &"attack"), int(context.parameters.get("plan_version", 1)))
				&"connection":
					internal_id = context.connection.request_connection(context.parameters["first_node"], \
						context.parameters["second_node"])
		elif _context_is_current(context):
			_finish_execution(context, &"failed", StringName(checked["reason"]), checked, true)
	if internal_id > 0:
		var key: String = "remote_request_id" if context.kind == &"remote_cultivation" else "growth_task_id"
		_capture_internal_id(context, key, internal_id)
	context.starting = false
	if _context_is_current(context):
		if internal_id > 0:
			_sync_execution()
		else:
			_finish_execution(context, &"failed", &"start_rejected", context.detail, true)
	else:
		# reset/cancel 可以在原入口的初始信号里发生；返回的旧编号仍须由原供养结算。
		context.cancel_requested = true
		_retire(context)
		_cancel_context_executor(context)
	_operation_depth -= 1
	_schedule_pump()


func _sync_execution() -> void:
	if _execution == null or _syncing or _resetting or _exiting or _accepting > 0:
		return
	_syncing = true
	var context: ExecutionContext = _execution
	if not _context_is_current(context):
		_execution = null
		context.cancel_requested = true
		_retire(context)
		_cancel_context_executor(context)
		_defer_settlement()
	else:
		var reason: StringName = _live_context_reason(context)
		if _context_is_current(context) and reason != &"":
			_finish_execution(context, &"failed", reason, context.detail, true)
		elif _context_is_current(context):
			var snapshot: Dictionary = _actual_snapshot(context)
			if _context_is_current(context):
				if context.identity_lost:
					_finish_execution(context, &"failed", &"executor_replaced", context.detail, true)
				elif not snapshot.is_empty():
					context.detail = snapshot.duplicate(true)
					var state: StringName = StringName(snapshot.get("state", &"idle"))
					var endpoint_reason: StringName = _active_endpoint_reason(context, snapshot)
					if endpoint_reason != &"":
						_finish_execution(context, &"failed", endpoint_reason, snapshot, true)
					elif state == &"completed":
						if _can_complete(context, snapshot) and _context_is_current(context):
							_finish_execution(context, &"completed", &"", snapshot, false)
						elif _context_is_current(context):
							_finish_execution(context, &"failed", &"invalid_completion", snapshot, true)
					elif state == &"cancelled":
						_finish_execution(context, &"cancelled", &"", snapshot, false)
					elif context.kind == &"remote_cultivation" \
							and snapshot.get("wait_reason") == &"occupied":
						_finish_execution(context, &"failed", &"occupied_target", snapshot, true)
					else:
						var external_state: StringName = &"paused" if state == &"paused" else &"executing"
						context.queue_source._coordinator_update(context.construction_id, context.generation, \
							external_state, StringName(snapshot.get("wait_reason", &"")), context.internal_ids, snapshot)
	_syncing = false


func _actual_snapshot(context: ExecutionContext) -> Dictionary:
	if context.kind == &"remote_cultivation":
		var snapshot: Dictionary = context.remote.get_request_snapshot()
		if not _context_is_current(context):
			return {}
		var request_id: int = int(snapshot.get("request_id", 0))
		if context.starting and int(context.internal_ids["remote_request_id"]) == 0 \
				and request_id > context.remote_before \
				and snapshot.get("target_position") == context.parameters["target_position"]:
			_capture_internal_id(context, "remote_request_id", request_id)
		if request_id != int(context.internal_ids["remote_request_id"]) or request_id <= 0:
			context.identity_lost = not context.starting
			return {}
		_capture_internal_id(context, "growth_task_id", int(snapshot.get("growth_task_id", 0)))
		_capture_internal_id(context, "cultivation_task_id", int(snapshot.get("cultivation_task_id", 0)))
		var growth_id: int = int(context.internal_ids["growth_task_id"])
		if growth_id > 0:
			var growth: Dictionary = context.growth.get_task_snapshot()
			if int(growth.get("task_id", 0)) != growth_id or not _growth_parameters_match(context, growth):
				context.identity_lost = true
		var cultivation_id: int = int(context.internal_ids["cultivation_task_id"])
		if cultivation_id > 0:
			var cultivation: Dictionary = context.cultivation.get_task_snapshot()
			if int(cultivation.get("task_id", 0)) != cultivation_id \
					or cultivation.get("host") != snapshot.get("endpoint"):
				context.identity_lost = true
		return snapshot
	var actual: Dictionary = context.growth.get_task_snapshot()
	if not _context_is_current(context):
		return {}
	var task_id: int = int(actual.get("task_id", 0))
	if context.starting and int(context.internal_ids["growth_task_id"]) == 0 \
			and task_id > context.growth_before and _growth_parameters_match(context, actual):
		_capture_internal_id(context, "growth_task_id", task_id)
	if task_id != int(context.internal_ids["growth_task_id"]) or task_id <= 0:
		context.identity_lost = not context.starting
		return {}
	if not _growth_parameters_match(context, actual):
		context.identity_lost = true
	if context.kind == &"connection":
		var forwarded: Dictionary = context.connection.get_task_snapshot()
		if int(forwarded.get("task_id", 0)) != task_id \
				or forwarded.get("state") != actual.get("state"):
			context.identity_lost = not context.starting
			return {}
	return actual


func _growth_parameters_match(context: ExecutionContext, snapshot: Dictionary) -> bool:
	if context.kind == &"connection":
		var first: Variant = context.parameters["first_node"]
		var second: Variant = context.parameters["second_node"]
		return snapshot.get("task_kind") == &"connection" \
			and ((snapshot.get("start_node") == first and snapshot.get("target_node") == second) \
				or (snapshot.get("start_node") == second and snapshot.get("target_node") == first))
	return snapshot.get("task_kind") == &"growth" \
		and snapshot.get("start_node") == context.parameters["start_node"] \
		and snapshot.get("target_position") == context.parameters["target_position"]


func _capture_internal_id(context: ExecutionContext, key: String, value: int) -> void:
	if value <= 0:
		return
	var previous: int = int(context.internal_ids[key])
	if previous > 0 and previous != value:
		context.identity_lost = true
	else:
		context.internal_ids[key] = value


func _live_context_reason(context: ExecutionContext) -> StringName:
	if not _node_is_available(context.payer) or context.payer.health <= 0 \
			or context.payer.get_instance_id() != context.payer_id:
		return &"core_unavailable"
	if context.network != network_system or context.growth != growth_system \
			or context.growth_supply != growth_supply_system or not _configuration_is_valid(context.kind):
		return &"invalid_configuration"
	if context.kind == &"remote_cultivation" and (context.remote != remote_cultivation_system \
			or context.cultivation != cultivation_system or context.cultivation_supply != cultivation_supply_system):
		return &"invalid_configuration"
	if context.kind == &"connection" and context.connection != connection_system:
		return &"invalid_configuration"
	var payer_reason: StringName = _payer_reason(context.kind, context.payer)
	if payer_reason != &"":
		return payer_reason
	if context.kind == &"connection":
		for key: String in ["first_node", "second_node"]:
			var endpoint: Variant = context.parameters[key]
			if not _node_is_available(endpoint) or not context.network.is_node_registered(endpoint):
				return &"invalid_endpoint"
	else:
		var start: Variant = context.parameters["start_node"]
		if not _node_is_available(start) or not context.network.is_node_registered(start):
			return &"invalid_endpoint"
	return &""


func _can_complete(context: ExecutionContext, snapshot: Dictionary) -> bool:
	if context.kind != &"remote_cultivation":
		if context.growth.has_active_task() or int(snapshot.get("task_id", 0)) != int(context.internal_ids["growth_task_id"]):
			return false
		var endpoint: HyphaNode = context.growth.get_completed_endpoint(int(context.internal_ids["growth_task_id"]))
		if not _node_is_available(endpoint) or not context.network.is_node_registered(endpoint):
			return false
		if context.kind == &"connection":
			return endpoint == snapshot.get("target_node") and context.network.has_direct_connection( \
				context.parameters["first_node"], context.parameters["second_node"])
		return endpoint.global_position.distance_to(snapshot.get("resolved_target_position", context.parameters["target_position"])) <= 1.0
	if context.remote.has_active_request() or context.growth.has_active_task() or context.cultivation.has_active_task():
		return false
	var growth: Dictionary = context.growth.get_task_snapshot()
	var cultivation: Dictionary = context.cultivation.get_task_snapshot()
	var endpoint: Variant = snapshot.get("endpoint")
	return int(growth.get("task_id", 0)) == int(context.internal_ids["growth_task_id"]) \
		and growth.get("state") == &"completed" \
		and int(cultivation.get("task_id", 0)) > 0 \
		and int(cultivation.get("task_id", 0)) == int(context.internal_ids["cultivation_task_id"]) \
		and cultivation.get("state") == &"completed" and cultivation.get("host") == endpoint \
		and int(cultivation.get("startup_transferred", 0)) == int(cultivation.get("startup_cost", CultivationSystem.STARTUP_COST)) \
		and int(cultivation.get("structure_consumed", 0)) == int(cultivation.get("structure_cost", CultivationSystem.STRUCTURE_COST)) \
		and float(cultivation.get("effective_time", 0.0)) >= CultivationSystem.MINIMUM_EFFECTIVE_TIME \
		and _node_is_available(endpoint) and context.network.is_node_registered(endpoint) \
		and _organ_matches_kind(endpoint.get_organ_occupant(), cultivation.get("organ_kind", &"attack"))


func _active_endpoint_reason(context: ExecutionContext, snapshot: Dictionary) -> StringName:
	if context.kind == &"connection":
		var target: Variant = snapshot.get("target_node")
		if not _node_is_available(target) or target.global_position != snapshot.get("target_position"):
			return &"invalid_target"
	elif context.kind == &"remote_cultivation" \
			and [&"connected", &"cultivation"].has(snapshot.get("phase")):
		var endpoint: Variant = snapshot.get("endpoint")
		if not _node_is_available(endpoint) or not context.network.is_node_registered(endpoint):
			return &"invalid_endpoint"
		# 起芽和成熟提交会同步预留/替换槽位；端点失效仍立即失败，占位待提交后核验。
		if bool(context.remote.get("_transitioning")) or bool(context.cultivation.get("_transitioning")):
			return &""
		if snapshot.get("phase") == &"connected" and not endpoint.is_organ_slot_available():
			return &"occupied_target"
		if snapshot.get("phase") == &"cultivation" and snapshot.get("state") != &"completed":
			var cultivation: Dictionary = context.cultivation.get_task_snapshot()
			var organ: Variant = endpoint.get_organ_occupant()
			# 成熟先提交器官并发 task_changed，remote 要到随后 task_completed 才提交终态。
			# 这里只认可同一真实尝试的完整成熟，外部请求仍占用管线等待 remote 完成。
			if int(context.internal_ids["cultivation_task_id"]) > 0 \
					and int(cultivation.get("task_id", 0)) == int(context.internal_ids["cultivation_task_id"]) \
					and cultivation.get("host") == endpoint and cultivation.get("state") == &"completed" \
					and not context.cultivation.has_active_task() \
					and int(cultivation.get("structure_consumed", 0)) == int(cultivation.get("structure_cost", CultivationSystem.STRUCTURE_COST)) \
					and int(cultivation.get("startup_transferred", 0)) == int(cultivation.get("startup_cost", CultivationSystem.STARTUP_COST)) \
					and float(cultivation.get("effective_time", 0.0)) >= CultivationSystem.MINIMUM_EFFECTIVE_TIME \
					and int(cultivation.get("buffered_nutrition", 0)) == 0 \
					and int(cultivation.get("startup_reserved", 0)) == 0 \
					and _node_is_available(organ) and _organ_matches_kind(organ, cultivation.get("organ_kind", &"attack")) and organ.get_parent() == endpoint \
					and context.growth.get_completed_endpoint(int(context.internal_ids["growth_task_id"])) == endpoint:
				var occupants: int = 0
				for child: Node in endpoint.get_children():
					if _node_is_available(child) and (child is OrganBud or child is AttackOrgan or child is DigestiveOrgan):
						occupants += 1
				if occupants == 1:
					return &""
			var bud: Variant = endpoint.get_organ_bud()
			if not _node_is_available(bud) or endpoint.get_organ_occupant() != bud \
					or bud.get_snapshot().get("bud_id") != cultivation.get("bud_id"):
				return &"occupied_target"
	return &""


func _finish_execution(
	context: ExecutionContext, state: StringName, reason: StringName, detail: Dictionary, cancel_executor: bool
) -> bool:
	if not _context_is_current(context):
		return false
	_operation_depth += 1
	_execution = null
	context.detail = detail.duplicate(true)
	context.cancel_requested = cancel_executor
	_retire(context)
	_defer_settlement()
	var finished: bool = context.queue_source._coordinator_finish(context.construction_id, \
		context.generation, state, reason, context.detail, context.internal_ids)
	if cancel_executor:
		_cancel_context_executor(context)
	if finished and context.epoch == _epoch and _node_is_available(context.queue_source) \
			and context.queue_source.get_generation() == context.generation:
		request_finished.emit(context.construction_id, state)
		if state == &"failed":
			notice.emit(_error_for_reason(reason))
	_operation_depth -= 1
	_schedule_pump()
	return finished


func _finish_pending(
	source: ConstructionQueue, construction_id: String, generation: int,
	state: StringName, reason: StringName, detail: Dictionary
) -> void:
	_operation_depth += 1
	var finished: bool = source._coordinator_finish(construction_id, generation, state, reason, detail)
	if finished and source == queue and source.get_generation() == generation:
		request_finished.emit(construction_id, state)
		notice.emit(String(detail.get("error", _error_for_reason(reason))))
	_operation_depth -= 1


func _matching_executor_is_active(context: ExecutionContext) -> bool:
	if context.kind == &"remote_cultivation":
		return _node_is_available(context.remote) and context.remote.has_active_request() \
			and int(context.internal_ids["remote_request_id"]) > 0 \
			and int(context.remote.get_request_snapshot().get("request_id", 0)) == int(context.internal_ids["remote_request_id"])
	if not _node_is_available(context.growth) or not context.growth.has_active_task():
		return false
	var snapshot: Dictionary = context.growth.get_task_snapshot()
	var matches: bool = int(context.internal_ids["growth_task_id"]) > 0 \
		and int(snapshot.get("task_id", 0)) == int(context.internal_ids["growth_task_id"]) \
		and _growth_parameters_match(context, snapshot)
	if context.kind == &"connection":
		matches = matches and _node_is_available(context.connection) and context.connection.has_active_task() \
			and int(context.connection.get_task_snapshot().get("task_id", 0)) == int(context.internal_ids["growth_task_id"])
	return matches


func _cancel_context_executor(context: ExecutionContext) -> void:
	if context.kind == &"remote_cultivation" and is_instance_valid(context.remote):
		var actual: Dictionary = context.remote.get_request_snapshot()
		if int(context.internal_ids["remote_request_id"]) > 0 \
				and int(actual.get("request_id", 0)) == int(context.internal_ids["remote_request_id"]) \
				and context.remote.has_active_request():
			context.remote.cancel_request()
	# 原请求可能在返回编号前被 reset；仅清理其已捕获的真实子任务。
	if is_instance_valid(context.growth) and int(context.internal_ids["growth_task_id"]) > 0:
		var actual: Dictionary = context.growth.get_task_snapshot()
		if int(actual.get("task_id", 0)) == int(context.internal_ids["growth_task_id"]) \
				and context.growth.has_active_task():
			if context.kind == &"connection" and is_instance_valid(context.connection) \
					and context.connection.has_active_task() \
					and int(context.connection.get_task_snapshot().get("task_id", 0)) == int(context.internal_ids["growth_task_id"]):
				context.connection.cancel_task()
			else:
				context.growth.cancel_task()
	if context.kind == &"remote_cultivation" and is_instance_valid(context.cultivation) \
			and int(context.internal_ids["cultivation_task_id"]) > 0:
		var actual: Dictionary = context.cultivation.get_task_snapshot()
		if int(actual.get("task_id", 0)) == int(context.internal_ids["cultivation_task_id"]) \
				and context.cultivation.has_active_task():
			context.cultivation.cancel_task()


func _context_is_current(context: ExecutionContext) -> bool:
	return context != null and _execution == context and context.epoch == _epoch \
		and not _resetting and not _exiting and _node_is_available(context.queue_source) \
		and context.queue_source == queue and context.queue_source.get_generation() == context.generation \
		and not context.queue_source.get_request(context.construction_id).is_empty()


func _retire(context: ExecutionContext) -> void:
	if not _retiring.has(context):
		_retiring.append(context)


func _sweep_retiring() -> void:
	for context: ExecutionContext in _retiring.duplicate():
		if context.cancel_requested:
			_cancel_context_executor(context)
		if not context.starting and _sources_are_idle(context.growth, context.growth_supply, \
				context.cultivation, context.cultivation_supply, context.remote, context.connection):
			_retiring.erase(context)


func _pipeline_is_idle() -> bool:
	if not _retiring.is_empty():
		return false
	return _sources_are_idle(growth_system, growth_supply_system, cultivation_system, \
		cultivation_supply_system, remote_cultivation_system, connection_system)


func _sources_are_idle(
	growth: Variant, growth_supply: Variant, cultivation: Variant, cultivation_supply: Variant,
	remote: Variant, connection: Variant
) -> bool:
	if _node_is_available(growth):
		if growth.has_active_task() or bool(growth.get("_changing_topology")) or bool(growth.get("_advancing")):
			return false
		if int(growth.get_task_snapshot().get("buffered_nutrition", 0)) > 0:
			return false
	if _node_is_available(cultivation):
		if cultivation.has_active_task() or bool(cultivation.get("_transitioning")) \
				or bool(cultivation.get("_advancing")) or bool(cultivation.get("_emitting_changed")):
			return false
		var resources: Dictionary = cultivation.get_resource_snapshot()
		if int(resources.get("buffered_nutrition", 0)) > 0 or int(resources.get("startup_reserved", 0)) > 0:
			return false
	if _node_is_available(remote) and remote.has_active_request():
		return false
	if _node_is_available(connection) and connection.has_active_task():
		return false
	for supply: Variant in [growth_supply, cultivation_supply]:
		if _node_is_available(supply) and (supply.get_in_transit_count() > 0 \
				or int(supply.get("_settlement_depth")) > 0 or bool(supply.get("_dispatching")) \
				or bool(supply.get("_resetting"))):
			return false
	return (not _node_is_available(growth) or not growth.has_active_task()) \
		and (not _node_is_available(cultivation) or not cultivation.has_active_task())


func _schedule_pump() -> void:
	if not auto_execute or _resetting or _exiting or _queued_pump_token > 0 or not _node_is_available(queue):
		return
	_next_pump_token += 1
	_queued_pump_token = _next_pump_token
	_deferred_pump.call_deferred(_queued_pump_token, _epoch, queue.get_generation(), queue.get_instance_id())


func _deferred_pump(token: int, epoch: int, generation: int, queue_id: int) -> void:
	if token != _queued_pump_token or epoch != _epoch or _resetting or _exiting \
			or not _node_is_available(queue) or queue.get_instance_id() != queue_id \
			or queue.get_generation() != generation:
		return
	_queued_pump_token = 0
	if auto_execute:
		pump()


func _defer_settlement() -> void:
	_settlement_barrier = true
	_barrier_token += 1
	_release_settlement.call_deferred(_barrier_token, _epoch)


func _release_settlement(token: int, epoch: int) -> void:
	if token != _barrier_token or epoch != _epoch or _resetting or _exiting:
		return
	_settlement_barrier = false
	_schedule_pump()


func _bind_sources() -> void:
	_set_queue_mode()
	_ensure_binding(queue, &"changed", _on_queue_changed.bind(queue))
	if multi_worker_enabled:
		_ensure_binding(network_system, &"network_changed", _on_multi_network_changed)
		return
	_ensure_binding(growth_system, &"task_changed", _on_growth_changed.bind(growth_system))
	_ensure_binding(growth_system, &"task_completed", _on_growth_terminal.bind(growth_system))
	_ensure_binding(growth_system, &"task_cancelled", _on_growth_terminal.bind(growth_system))
	_ensure_binding(remote_cultivation_system, &"request_changed", _on_remote_changed.bind(remote_cultivation_system))
	_ensure_binding(remote_cultivation_system, &"request_completed", _on_remote_terminal.bind(remote_cultivation_system))
	_ensure_binding(remote_cultivation_system, &"request_cancelled", _on_remote_terminal.bind(remote_cultivation_system))
	_ensure_binding(connection_system, &"task_changed", _on_connection_changed.bind(connection_system))
	_ensure_binding(connection_system, &"task_completed", _on_connection_terminal.bind(connection_system))
	_ensure_binding(connection_system, &"task_cancelled", _on_connection_terminal.bind(connection_system))
	_ensure_binding(cultivation_system, &"task_changed", _on_cultivation_changed.bind(cultivation_system))
	_ensure_binding(cultivation_system, &"task_completed", _on_cultivation_terminal.bind(cultivation_system))
	_ensure_binding(cultivation_system, &"task_cancelled", _on_cultivation_terminal.bind(cultivation_system))
	_ensure_binding(growth_supply_system, &"supply_changed", _on_supply_changed)
	_ensure_binding(cultivation_supply_system, &"supply_changed", _on_supply_changed)
	_ensure_binding(network_system, &"network_changed", _on_network_changed)


func _ensure_binding(source: Variant, signal_name: StringName, callback: Callable) -> void:
	if not _node_is_available(source):
		return
	var key: String = "%d:%s" % [source.get_instance_id(), String(signal_name)]
	if _binding_keys.has(key):
		return
	_binding_keys[key] = true
	source.connect(signal_name, callback)
	_bindings.append({"source": source, "signal": signal_name, "callback": callback})


func _publish_snapshot() -> void:
	if _exiting:
		return
	var snapshot: Dictionary = get_snapshot()
	if snapshot != _last_snapshot:
		_last_snapshot = snapshot.duplicate(true)
		changed.emit(snapshot)


func _reject_preview(result: Dictionary, reason: StringName, error: String = "") -> Dictionary:
	result["valid"] = false
	result["reason"] = reason
	result["error"] = _error_for_reason(reason) if error.is_empty() else error
	return result


func _enqueue_result(accepted: bool, construction_id: String, reason: StringName) -> Dictionary:
	return {"accepted": accepted, "construction_id": construction_id, "reason": reason}


func _error_for_reason(reason: StringName) -> String:
	match reason:
		&"duplicate":
			return "该建设目标已在队列中，已选中原请求。"
		&"queue_full":
			return "建设队列最多容纳三个目标，请先完成或取消一项。"
		&"disconnected":
			return "施工起点暂时断开，等待恢复到母核的连接。"
		&"core_unavailable", &"payer_replaced":
			return "原付款母核已失效或被替换，请重新放置目标。"
		&"invalid_endpoint", &"unregistered_endpoint":
			return "原施工端点已失效或不属于当前网络。"
		&"already_connected":
			return "两个菌结已有直接连接。"
		&"same_node":
			return "连接需要两个不同菌结。"
		&"occupied_target":
			return RemoteCultivationSystem.EXISTING_NODE_REASON
		&"invalid_target":
			return "建设目标或施工几何已失效。"
		&"invalid_configuration":
			return "建设系统配置尚未就绪。"
		&"executor_replaced":
			return "原施工编号已失效，请重新放置目标。"
		&"invalid_completion":
			return "施工完成身份校验失败。"
		&"reset":
			return "关卡正在重置，请稍后重新放置。"
		&"start_rejected":
			return "原施工系统未接受该建设目标。"
		_:
			return "建设请求无效。"


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func get_all_requests() -> Array[Dictionary]:
	return queue.get_all_requests() if _node_is_available(queue) else []


func get_active_requests() -> Array[Dictionary]:
	return queue.get_active_requests() if _node_is_available(queue) else []


func get_worker(construction_id: String) -> ConstructionWorker:
	var worker: ConstructionWorker = _request_workers.get(construction_id)
	if not _node_is_available(worker) or worker.get_snapshot().get("construction_id") != construction_id \
			or get_request(construction_id).is_empty():
		return null
	return worker


func get_workers(include_retired: bool = false) -> Array[ConstructionWorker]:
	var result: Array[ConstructionWorker] = []
	if include_retired:
		for worker: ConstructionWorker in _workers:
			if _node_is_available(worker) and not result.has(worker):
				result.append(worker)
	else:
		for context: WorkerContext in _worker_contexts.values():
			if _node_is_available(context.worker) and not result.has(context.worker):
				result.append(context.worker)
	return result


func get_resource_snapshot() -> Dictionary:
	var result: Dictionary = {
		"network_structure": int(_archived_resources["network_structure"]),
		"organ_structure": int(_archived_resources["organ_structure"]),
		"startup_transferred": int(_archived_resources["startup_transferred"]),
		"growth_buffer": 0, "cultivation_buffer": 0, "startup_reserved": 0,
		"growth_transit": 0, "cultivation_transit": 0,
		"worker_count": 0, "active_worker_count": _worker_contexts.size(),
	}
	var seen: Dictionary[int, bool] = {}
	for worker: ConstructionWorker in _workers:
		if not _node_is_available(worker) or seen.has(worker.worker_id):
			continue
		seen[worker.worker_id] = true
		result["worker_count"] += 1
		var resources: Dictionary = worker.get_resource_snapshot()
		for key: String in resources:
			result[key] += int(resources[key])
	if not multi_worker_enabled and _workers.is_empty():
		var growth: Dictionary = growth_system.get_resource_snapshot() if _node_is_available(growth_system) else {}
		var cultivation: Dictionary = cultivation_system.get_resource_snapshot() if _node_is_available(cultivation_system) else {}
		result["network_structure"] += int(growth.get("consumed_nutrition", 0))
		result["organ_structure"] += int(cultivation.get("structure_consumed", 0))
		result["growth_buffer"] = int(growth.get("buffered_nutrition", 0))
		result["cultivation_buffer"] = int(cultivation.get("buffered_nutrition", 0))
		result["startup_reserved"] = int(cultivation.get("startup_reserved", 0))
		result["startup_transferred"] += cultivation_system.get_startup_transferred_nutrition() \
			if _node_is_available(cultivation_system) else 0
		result["growth_transit"] = _paid_supply_transit(growth_supply_system)
		result["cultivation_transit"] = _paid_supply_transit(cultivation_supply_system)
	return result


func enqueue_local_cultivation(host: HyphaNode, organ_kind: StringName = &"") -> Dictionary:
	_set_queue_mode()
	if not multi_worker_enabled or _resetting or _exiting or not _node_is_available(queue):
		return _enqueue_result(false, "", &"invalid_configuration")
	_accepting += 1
	var selection: Dictionary = get_cultivation_selection(host, organ_kind)
	var existing_id: String = String(selection["construction_id"])
	var result: Dictionary
	if not existing_id.is_empty():
		queue.select_request(existing_id)
		result = _enqueue_result(false, existing_id, &"duplicate")
	elif not bool(selection["can_cultivate"]) and not bool(selection["can_continue"]):
		result = _enqueue_result(false, "", StringName(selection["reason"]))
	else:
		var source: ConstructionQueue = queue
		var generation: int = source.get_generation()
		var retained: ConstructionWorker = _retained_bud_worker(host)
		result = source._coordinator_enqueue_cultivation(host, mother_core, selection.get("organ_kind", &"attack"))
		if bool(result["accepted"]) and source == queue and source.get_generation() == generation:
			var construction_id: String = String(result["construction_id"])
			if bool(selection["can_continue"]) and retained != null:
				_local_continuations[construction_id] = retained
			_admissions[construction_id] = {"host": host, "organ_kind": selection.get("organ_kind", &"attack"), "total_cost": int(selection["total_cost"]), \
				"remaining_cost": int(selection["remaining_cost"])}
	_schedule_pump()
	_accepting -= 1
	return result


func get_cultivation_selection(host: HyphaNode, organ_kind: StringName = &"") -> Dictionary:
	var kind: StringName = organ_kind
	if kind == &"":
		kind = &"digestive" if _node_is_available(host) and bool(host.get_meta("rebuild_digestive", false)) else &"attack"
	var recipe: Dictionary = CultivationSystem.get_recipe(kind)
	var result: Dictionary = {
		"host": host if _node_is_available(host) else null, "reason": &"no_selection", "message": "请选择成熟菌结。",
		"can_cultivate": false, "can_continue": false, "can_pause": false, "can_resume": false, "can_cancel": false,
		"task": {}, "organ_kind": kind, "total_cost": int(recipe.get("total_cost", 0)), "remaining_cost": int(recipe.get("total_cost", 0)),
		"available_nutrition": 0, "construction_id": "",
	}
	if recipe.is_empty():
		return _cultivation_selection_reason(result, &"invalid_configuration", "器官类型无效。")
	if not _node_is_available(host):
		return result
	if _node_is_available(cultivation_supply_system):
		result["available_nutrition"] = cultivation_supply_system.get_available_cultivation_nutrition()
	var active: Dictionary = _active_cultivation_for_host(host)
	if not active.is_empty():
		var construction_id: String = String(active["construction_id"])
		var worker: ConstructionWorker = get_worker(construction_id)
		var task: Dictionary = worker.cultivation_system.get_task_snapshot(int(active["internal_ids"].get("cultivation_task_id", 0))) \
			if worker != null else {}
		result["construction_id"] = construction_id
		result["task"] = task
		result["organ_kind"] = task.get("organ_kind", kind)
		result["total_cost"] = int(task.get("total_cost", recipe["total_cost"]))
		result["remaining_cost"] = int(task.get("remaining_cost", CultivationSystem.TOTAL_COST))
		result["can_cancel"] = true
		result["can_pause"] = active["state"] != &"paused"
		result["can_resume"] = active["state"] == &"paused"
		result["reason"] = &"paused" if active["state"] == &"paused" else &"construction_busy"
		result["message"] = "培育已暂停。" if active["state"] == &"paused" else "该菌结的培育请求正在进行。"
		return result
	if not multi_worker_enabled or not _configuration_is_valid(&"remote_cultivation") or _payer_reason(&"cultivation", mother_core) != &"":
		return _cultivation_selection_reason(result, &"invalid_configuration", "培育系统配置尚未就绪。")
	if not network_system.is_node_registered(host):
		return _cultivation_selection_reason(result, &"invalid_endpoint", "该菌结不属于当前网络。")
	var retained: ConstructionWorker = _retained_bud_worker(host, false)
	if retained != null:
		var task: Dictionary = retained.cultivation_system.get_task_snapshot()
		result["task"] = task
		result["organ_kind"] = task.get("organ_kind", kind)
		result["total_cost"] = int(task.get("total_cost", recipe["total_cost"]))
		result["remaining_cost"] = int(task.get("remaining_cost", CultivationSystem.TOTAL_COST))
		if not retained.is_settled():
			return _cultivation_selection_reason(result, &"settlement_pending", "上一培育尝试正在结算。")
		var availability: StringName = retained.cultivation_system.get_cultivation_availability(host)
		if availability != &"continuable":
			return _cultivation_selection_reason(result, availability, "器官芽暂时无法继续培育。")
		result["can_continue"] = true
		return _cultivation_selection_reason(result, &"continuable", "可继续原器官芽的培育。")
	if not host.is_organ_slot_available():
		return _cultivation_selection_reason(result, &"occupied", "该菌结已有器官或器官芽。")
	if not network_system.is_available_connected_to_core(host):
		return _cultivation_selection_reason(result, &"disconnected", "该菌结暂时未连接母核。")
	result["can_cultivate"] = true
	return _cultivation_selection_reason(result, &"ready", "培育胃囊：8营养全计结构、至少3秒，空输入与空产物。" if kind == &"digestive" else "培育攻击器官：12营养＝8结构＋4启动库存。")


func _set_queue_mode() -> void:
	if _node_is_available(queue):
		queue.multi_execution = multi_worker_enabled


func _on_multi_network_changed() -> void:
	if _resetting or _exiting:
		return
	_sync_workers()
	_schedule_pump()


func _on_worker_changed(snapshot: Dictionary, worker: ConstructionWorker) -> void:
	var construction_id: String = String(snapshot.get("construction_id", ""))
	var context: WorkerContext = _worker_contexts.get(construction_id)
	if context == null or context.worker != worker or context.finishing \
			or worker.get_snapshot() != snapshot:
		return
	_sync_workers()
	_schedule_pump()


func _on_worker_maturation(construction_id: String, worker: ConstructionWorker) -> void:
	var context: WorkerContext = _worker_contexts.get(construction_id)
	if context == null or context.worker != worker or not _worker_context_is_current(context):
		return
	_sync_workers()
	_schedule_pump()


func _on_worker_finished(construction_id: String, _state: StringName, worker: ConstructionWorker) -> void:
	var context: WorkerContext = _worker_contexts.get(construction_id)
	if context == null or context.worker != worker:
		return
	_sync_workers()
	_schedule_pump()


func _on_worker_organ_matured(
	construction_id: String, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon, worker: ConstructionWorker
) -> void:
	var context: WorkerContext = _worker_contexts.get(construction_id)
	if context == null or context.worker != worker or not _worker_context_is_current(context) \
			or not _node_is_available(host) or not _node_is_available(organ) or not _node_is_available(weapon):
		return
	organ_matured.emit(construction_id, host, organ, weapon)


func _pump_workers() -> void:
	if _resetting or _exiting or _pumping or _operation_depth > 0 or _accepting > 0 \
			or _syncing or _settlement_barrier or not _node_is_available(queue):
		return
	_set_queue_mode()
	_bind_sources()
	_pumping = true
	var epoch: int = _epoch
	var source: ConstructionQueue = queue
	var generation: int = source.get_generation()
	_sync_workers()
	_sweep_workers()
	# 就地培育不占尖端，外部队首断路时仍可以独立成熟。
	for request: Dictionary in source.get_snapshot()["maturing"]:
		if epoch != _epoch or source != queue or source.get_generation() != generation:
			break
		if request["kind"] == &"cultivation" and not bool(request["started"]) and request["state"] == &"waiting":
			var planned: Dictionary = _preview_local_pending(request)
			if not bool(planned["valid"]):
				if [&"disconnected", &"settlement_pending"].has(planned["reason"]):
					source._coordinator_update(String(request["construction_id"]), generation, &"waiting", \
						StringName(planned["reason"]), {}, planned)
				else:
					_finish_pending(source, String(request["construction_id"]), generation, &"failed", \
						StringName(planned["reason"]), planned)
			else:
				_start_worker(source, request, generation, epoch, planned)
	while epoch == _epoch and source == queue and source.get_generation() == generation \
			and not _resetting and not _exiting and int(source.get_snapshot()["tip_count"]) < _get_worker_tip_limit():
		var pending: Dictionary = _first_unpaused_request(source)
		if pending.is_empty():
			break
		var construction_id: String = String(pending["construction_id"])
		var planned: Dictionary = _preview_worker_pending(pending)
		if epoch != _epoch or source != queue or source.get_generation() != generation:
			break
		if not bool(planned["valid"]) and planned["reason"] != &"disconnected":
			_finish_pending(source, construction_id, generation, &"failed", StringName(planned["reason"]), planned)
		elif planned["reason"] == &"disconnected":
			source._coordinator_update(construction_id, generation, &"waiting", &"disconnected", {}, planned)
			break
		else:
			_start_worker(source, pending, generation, epoch, planned)
			var after: Dictionary = source.get_request(construction_id)
			if not after.is_empty() and not bool(after["started"]) and not ConstructionQueue.TERMINAL_STATES.has(after["state"]):
				break
	_pumping = false
	_update_worker_supply_order()


func _get_worker_tip_limit() -> int:
	return clampi(queue.capabilities.get_extension_tip_limit(), 1, 2) \
		if _node_is_available(queue) and _node_is_available(queue.capabilities) else 1


func _preview_worker_pending(request: Dictionary) -> Dictionary:
	var planned: Dictionary = _preview_request(request["kind"], request["parameters"], request["payer"])
	if request["kind"] != &"connection":
		return planned
	var construction_id: String = String(request["construction_id"])
	if not _admissions.has(construction_id):
		_admissions[construction_id] = planned.duplicate(true)
	var frozen: HyphaNode = _admissions[construction_id].get("start_node") as HyphaNode
	if not _node_is_available(frozen) or not network_system.is_node_registered(frozen):
		return _reject_preview(planned, &"invalid_endpoint")
	if not bool(planned["valid"]) and planned["reason"] != &"disconnected":
		return planned
	var parameters: Dictionary = request["parameters"]
	var target: HyphaNode = parameters["second_node"] if frozen == parameters["first_node"] else parameters["first_node"]
	planned["start_node"] = frozen
	planned["target_node"] = target
	planned["reversed"] = frozen != parameters["first_node"]
	planned["plan"] = growth_system.planner.plan(frozen.global_position, target.global_position, true)
	planned["total_cost"] = int(planned["plan"].get("total_cost", 0))
	if not network_system.is_available_connected_to_core(frozen):
		return _reject_preview(planned, &"disconnected")
	planned["valid"] = true
	planned["reason"] = &""
	planned["error"] = ""
	return planned


func _preview_local_pending(request: Dictionary) -> Dictionary:
	var host: HyphaNode = request["parameters"].get("host") as HyphaNode
	var planned: Dictionary = {"valid": false, "reason": &"", "error": "", "host": host, \
		"organ_kind": request["parameters"].get("organ_kind", &"attack"),
		"total_cost": int(CultivationSystem.get_recipe(request["parameters"].get("organ_kind", &"attack"))["total_cost"]),
		"remaining_cost": int(CultivationSystem.get_recipe(request["parameters"].get("organ_kind", &"attack"))["total_cost"])}
	var payer_reason: StringName = _payer_reason(&"cultivation", request["payer"])
	if payer_reason != &"":
		return _reject_preview(planned, payer_reason)
	if not _configuration_is_valid(&"remote_cultivation"):
		return _reject_preview(planned, &"invalid_configuration")
	if not _node_is_available(host) or not network_system.is_node_registered(host):
		return _reject_preview(planned, &"invalid_endpoint")
	var retained: ConstructionWorker = _local_continuations.get(String(request["construction_id"]))
	if retained != null:
		if not _node_is_available(retained):
			return _reject_preview(planned, &"executor_replaced")
		if not retained.is_settled():
			return _reject_preview(planned, &"settlement_pending")
		var availability: StringName = retained.cultivation_system.get_cultivation_availability(host)
		if availability != &"continuable":
			return _reject_preview(planned, availability)
		planned["remaining_cost"] = int(retained.cultivation_system.get_task_snapshot().get("remaining_cost", CultivationSystem.TOTAL_COST))
	elif not host.is_organ_slot_available():
		return _reject_preview(planned, &"occupied_target")
	if not network_system.is_available_connected_to_core(host):
		return _reject_preview(planned, &"disconnected")
	planned["valid"] = true
	return planned


func _start_worker(
	source: ConstructionQueue, request: Dictionary, generation: int, epoch: int, planned: Dictionary
) -> void:
	_operation_depth += 1
	var construction_id: String = String(request["construction_id"])
	var worker: ConstructionWorker = _local_continuations.get(construction_id)
	var continuing: bool = worker != null
	if continuing:
		_unregister_worker_supplies(worker)
	else:
		worker = _create_worker()
	if not _node_is_available(worker) or epoch != _epoch or source != queue or source.get_generation() != generation \
			or _resetting or _exiting:
		if _node_is_available(worker) and not continuing:
			_discard_idle_worker(worker)
		if epoch == _epoch and source == queue and source.get_generation() == generation:
			_finish_pending(source, construction_id, generation, &"failed", &"invalid_configuration", planned)
		_operation_depth -= 1
		return
	var context: WorkerContext = WorkerContext.new()
	context.queue_source = source
	context.construction_id = construction_id
	context.generation = generation
	context.epoch = epoch
	context.kind = request["kind"]
	context.parameters = request["parameters"].duplicate(true)
	context.payer = request["payer"]
	context.payer_id = int(request["payer_id"])
	context.network = network_system
	context.worker = worker
	context.starting = true
	context.detail = planned.duplicate(true)
	_worker_contexts[construction_id] = context
	var can_start: bool = source._coordinator_start_local(construction_id, generation) \
		if context.kind == &"cultivation" else source._coordinator_start(construction_id, generation)
	if can_start and _worker_context_is_current(context):
		_next_worker_admission += 1
		context.admission_order = _next_worker_admission
		var checked: Dictionary = _preview_local_pending(request) if context.kind == &"cultivation" else _preview_worker_pending(request)
		if _worker_context_is_current(context) and checked["reason"] == &"disconnected" and context.kind != &"cultivation":
			_worker_contexts.erase(construction_id)
			source._coordinator_unstart(construction_id, generation, &"disconnected", checked)
			_discard_idle_worker(worker)
		elif _worker_context_is_current(context) and bool(checked["valid"]):
			if source._coordinator_bind_worker(construction_id, generation, worker.worker_id) and _worker_context_is_current(context):
				if continuing:
					var previous_id: String = String(worker.get_snapshot()["construction_id"])
					_request_workers.erase(previous_id)
				_request_workers[construction_id] = worker
				var registered: bool = _register_worker_supplies(construction_id, worker)
				var parameters: Dictionary = context.parameters.duplicate(true)
				if continuing:
					parameters["continue_existing"] = true
				if context.kind == &"connection":
					parameters["connection_start_node"] = checked["start_node"]
				var started: bool = false
				if registered and _worker_context_is_current(context):
					started = worker.start_request(construction_id, context.kind, parameters)
				context.starting = false
				if _worker_context_is_current(context):
					if started:
						if context.pause_on_start:
							worker.pause_request()
						_sync_workers()
					else:
						_finish_worker_context(context, &"failed", &"start_rejected", true)
				elif worker.get_snapshot().get("construction_id") == construction_id:
					worker.cancel_request()
			else:
				context.starting = false
				if _worker_context_is_current(context):
					_finish_worker_context(context, &"failed", &"executor_replaced", true)
		elif _worker_context_is_current(context):
			context.starting = false
			_finish_worker_context(context, &"failed", StringName(checked["reason"]), true)
	else:
		context.starting = false
		if _worker_context_is_current(context):
			_finish_worker_context(context, &"failed", &"start_rejected", false)
		elif not continuing and worker.get_snapshot().get("construction_id", "") == "":
			_discard_idle_worker(worker)
	context.starting = false
	_local_continuations.erase(construction_id)
	_operation_depth -= 1
	_schedule_pump()


func _create_worker() -> ConstructionWorker:
	if not _node_is_available(worker_container) or worker_scene == null or not worker_scene.can_instantiate():
		return null
	var instance: Node = worker_scene.instantiate()
	if not instance is ConstructionWorker:
		instance.free()
		return null
	var worker: ConstructionWorker = instance as ConstructionWorker
	var config: Dictionary = {
		"mother_core": mother_core, "network_system": network_system,
		"cargo_passage_tracker": cargo_passage_tracker if is_instance_valid(cargo_passage_tracker) \
			else growth_supply_system.cargo_passage_tracker,
		"traffic_system": growth_supply_system.traffic_system, "combat_supply_system": growth_supply_system.combat_supply_system,
		"node_container": growth_system.node_container, "edge_container": growth_system.edge_container,
		"tip_container": growth_system.tip_container, "growth_packet_container": growth_supply_system.packet_container,
		"cultivation_packet_container": cultivation_supply_system.packet_container,
		"enemy_container": cultivation_system.enemy_container, "projectile_container": cultivation_system.projectile_container,
		"planner": growth_system.planner,
	}
	if not worker.configure(config):
		worker.free()
		return null
	# 只沿用原公开配置；任务、芽、账本和付款来源始终由各原实例独立保存。
	worker.growth_system.growth_speed = growth_system.growth_speed
	worker.growth_supply_system.packet_scene = growth_supply_system.packet_scene
	worker.growth_supply_system.dispatch_interval = growth_supply_system.dispatch_interval
	worker.growth_supply_system.traffic_required = growth_supply_system.traffic_required
	worker.cultivation_system.bud_scene = cultivation_system.bud_scene
	worker.cultivation_system.attack_organ_scene = cultivation_system.attack_organ_scene
	worker.cultivation_system.weapon_scene = cultivation_system.weapon_scene
	worker.cultivation_system.weapon_attack_range = cultivation_system.weapon_attack_range
	worker.cultivation_system.normal_weapon_profile = cultivation_system.normal_weapon_profile.copy_for_instance() \
		if cultivation_system.normal_weapon_profile != null else null
	worker.cultivation_supply_system.packet_scene = cultivation_supply_system.packet_scene
	worker.cultivation_supply_system.dispatch_interval = cultivation_supply_system.dispatch_interval
	worker.cultivation_supply_system.traffic_required = cultivation_supply_system.traffic_required
	_workers.append(worker)
	_ensure_binding(worker, &"changed", _on_worker_changed.bind(worker))
	_ensure_binding(worker, &"maturation_started", _on_worker_maturation.bind(worker))
	_ensure_binding(worker, &"finished", _on_worker_finished.bind(worker))
	_ensure_binding(worker, &"organ_matured", _on_worker_organ_matured.bind(worker))
	worker_container.add_child(worker)
	return worker


func _sync_workers() -> void:
	if _syncing or _resetting or _exiting or _accepting > 0:
		return
	_syncing = true
	for context: WorkerContext in _worker_contexts.values().duplicate():
		if context.finishing:
			continue
		if not _worker_context_is_current(context):
			_worker_contexts.erase(context.construction_id)
			if _node_is_available(context.worker):
				context.worker.cancel_request()
			_request_workers.erase(context.construction_id)
			continue
		var reason: StringName = _worker_live_reason(context)
		if reason != &"":
			_finish_worker_context(context, &"failed", reason, true)
			continue
		var snapshot: Dictionary = context.worker.get_snapshot()
		if snapshot.get("construction_id") != context.construction_id:
			if not context.starting:
				_finish_worker_context(context, &"failed", &"executor_replaced", true)
			continue
		context.detail = snapshot["detail"].duplicate(true)
		context.internal_ids = snapshot["internal_ids"].duplicate()
		var state: StringName = StringName(snapshot["state"])
		if ConstructionQueue.TERMINAL_STATES.has(state):
			if not context.starting:
				_finish_worker_context(context, state, StringName(snapshot["wait_reason"]), false)
		else:
			var external_state: StringName = &"paused" if context.starting and context.pause_on_start else state
			var wait_reason: StringName = &"paused" if external_state == &"paused" else StringName(snapshot["wait_reason"])
			context.queue_source._coordinator_update(context.construction_id, context.generation, external_state, \
				wait_reason, context.internal_ids, context.detail)
			if _worker_context_is_current(context) and context.kind == &"remote_cultivation" \
					and snapshot["phase"] == &"maturing" and bool(context.detail.get("extension_released", false)):
				context.queue_source._coordinator_release_tip(context.construction_id, context.generation, context.detail, context.internal_ids)
	_syncing = false
	_update_worker_supply_order()


func _worker_context_is_current(context: WorkerContext) -> bool:
	if context == null or _resetting or _exiting or context.epoch != _epoch \
			or _worker_contexts.get(context.construction_id) != context \
			or not _node_is_available(context.queue_source) or context.queue_source != queue \
			or context.queue_source.get_generation() != context.generation:
		return false
	var request: Dictionary = context.queue_source.get_request(context.construction_id)
	return not request.is_empty() and not ConstructionQueue.TERMINAL_STATES.has(request["state"])


func _worker_live_reason(context: WorkerContext) -> StringName:
	if not _node_is_available(context.worker):
		return &"executor_replaced"
	if not _node_is_available(context.payer) or context.payer.health <= 0 \
			or context.payer.get_instance_id() != context.payer_id:
		return &"core_unavailable"
	if context.payer != mother_core or context.network != network_system \
			or not _node_is_available(context.network) or context.network.peek_registered_core() != context.payer:
		return &"payer_replaced"
	return &""


func _finish_worker_context(context: WorkerContext, state: StringName, reason: StringName, cancel_executor: bool) -> bool:
	if not _worker_context_is_current(context) or context.finishing:
		return false
	_operation_depth += 1
	context.finishing = true
	if cancel_executor and _node_is_available(context.worker):
		context.worker.cancel_request()
	if _node_is_available(context.worker):
		var snapshot: Dictionary = context.worker.get_snapshot()
		if snapshot.get("construction_id") == context.construction_id:
			context.detail = snapshot["detail"].duplicate(true)
			context.internal_ids = snapshot["internal_ids"].duplicate()
	_worker_contexts.erase(context.construction_id)
	var finished: bool = context.queue_source._coordinator_finish(context.construction_id, context.generation, \
		state, reason, context.detail, context.internal_ids)
	_admissions.erase(context.construction_id)
	_local_continuations.erase(context.construction_id)
	if _node_is_available(context.worker) and context.worker.is_settled():
		_unregister_worker_supplies(context.worker)
	if finished and context.epoch == _epoch and context.queue_source == queue \
			and context.queue_source.get_generation() == context.generation:
		request_finished.emit(context.construction_id, state)
		if state == &"failed":
			notice.emit(_error_for_reason(reason))
	_operation_depth -= 1
	_schedule_pump()
	return finished


func _cancel_worker_request(construction_id: String) -> bool:
	if _resetting or _exiting or not _node_is_available(queue):
		return false
	_sync_workers()
	var request: Dictionary = queue.get_request(construction_id)
	if request.is_empty() or ConstructionQueue.TERMINAL_STATES.has(request["state"]):
		return false
	_operation_depth += 1
	var did_cancel: bool = false
	var context: WorkerContext = _worker_contexts.get(construction_id)
	if context != null:
		did_cancel = _finish_worker_context(context, &"cancelled", &"", true)
	elif not bool(request["started"]):
		var generation: int = queue.get_generation()
		did_cancel = queue.cancel_request(construction_id)
		_admissions.erase(construction_id)
		_local_continuations.erase(construction_id)
		if did_cancel and _node_is_available(queue) and queue.get_generation() == generation:
			request_finished.emit(construction_id, &"cancelled")
	_operation_depth -= 1
	_schedule_pump()
	return did_cancel


func _change_worker_pause(construction_id: String, paused: bool) -> bool:
	if _resetting or _exiting or not _node_is_available(queue):
		return false
	_sync_workers()
	var request: Dictionary = queue.get_request(construction_id)
	if request.is_empty() or ConstructionQueue.TERMINAL_STATES.has(request["state"]):
		return false
	_operation_depth += 1
	var did_change: bool = false
	var context: WorkerContext = _worker_contexts.get(construction_id)
	if context != null and _worker_context_is_current(context) and _node_is_available(context.worker):
		if context.starting and context.worker.get_snapshot().get("construction_id") != construction_id:
			did_change = context.pause_on_start != paused
			context.pause_on_start = paused
			if did_change:
				queue._coordinator_update(construction_id, context.generation, &"paused" if paused else \
					(&"maturing" if context.kind == &"cultivation" else &"executing"), &"paused" if paused else &"", \
					context.internal_ids, context.detail)
		else:
			did_change = context.worker.pause_request() if paused else context.worker.resume_request()
		_sync_workers()
	elif not bool(request["started"]):
		did_change = queue.pause_request(construction_id) if paused else queue.resume_request(construction_id)
	_operation_depth -= 1
	if did_change:
		_schedule_pump()
	return did_change


func _register_worker_supplies(construction_id: String, worker: ConstructionWorker) -> bool:
	if not _node_is_available(supply_scheduler) or not _node_is_available(worker):
		return false
	var scheduler: ConstructionSupplyScheduler = supply_scheduler
	var growth_registered: bool = scheduler.register_supply(construction_id, worker.growth_supply_system)
	var cultivation_registered: bool = scheduler.register_supply(construction_id, worker.cultivation_supply_system)
	if growth_registered and cultivation_registered:
		_worker_registrations[worker.worker_id] = scheduler
		return true
	# 注册失败时没有活跃原任务；可以完整撤销这一空组的所有权。
	if growth_registered:
		scheduler.unregister_supply(worker.growth_supply_system)
	if cultivation_registered:
		scheduler.unregister_supply(worker.cultivation_supply_system)
	return false


func _unregister_worker_supplies(worker: ConstructionWorker) -> void:
	if not is_instance_valid(worker) or not _worker_registrations.has(worker.worker_id):
		return
	var scheduler: ConstructionSupplyScheduler = _worker_registrations[worker.worker_id]
	if _node_is_available(scheduler):
		scheduler.unregister_supply(worker.growth_supply_system)
		scheduler.unregister_supply(worker.cultivation_supply_system)
	_worker_registrations.erase(worker.worker_id)


func _update_worker_supply_order() -> void:
	if not _node_is_available(supply_scheduler) or _resetting or _exiting:
		return
	var contexts: Array[WorkerContext] = []
	for context: WorkerContext in _worker_contexts.values():
		if _worker_context_is_current(context):
			contexts.append(context)
	contexts.sort_custom(_worker_admission_before)
	var order: Array[String] = []
	for context: WorkerContext in contexts:
		order.append(context.construction_id)
	supply_scheduler.set_order(order)


func _worker_admission_before(first: WorkerContext, second: WorkerContext) -> bool:
	return first.admission_order < second.admission_order


func _sweep_workers() -> void:
	for worker: ConstructionWorker in _workers:
		if _node_is_available(worker) and not _worker_is_active(worker) and worker.is_settled():
			_unregister_worker_supplies(worker)


func _worker_is_active(worker: ConstructionWorker) -> bool:
	for context: WorkerContext in _worker_contexts.values():
		if context.worker == worker:
			return true
	return false


func _active_cultivation_for_host(host: HyphaNode) -> Dictionary:
	for request: Dictionary in get_active_requests():
		if request["parameters"].get("host") == host or request["detail"].get("endpoint") == host:
			return request
	return {}


func _retained_bud_worker(host: HyphaNode, require_settled: bool = true) -> ConstructionWorker:
	for worker: ConstructionWorker in _workers:
		if not _node_is_available(worker) or _worker_is_active(worker):
			continue
		var snapshot: Dictionary = worker.get_snapshot()
		var request: Dictionary = get_request(String(snapshot.get("construction_id", "")))
		if snapshot.get("state") != &"cancelled" or request.get("state") != &"cancelled":
			continue
		var bud: Dictionary = worker.cultivation_system.get_bud_snapshot(host)
		if not bud.is_empty() and (not require_settled or worker.is_settled()):
			return worker
	return null


func _cultivation_selection_reason(result: Dictionary, reason: StringName, message: String) -> Dictionary:
	result["reason"] = reason
	result["message"] = message
	return result


func _reset_workers() -> void:
	if _resetting:
		return
	_resetting = true
	_epoch += 1
	_queued_pump_token = 0
	_settlement_barrier = false
	_barrier_token += 1
	_operation_depth += 1
	var source: ConstructionQueue = queue if _node_is_available(queue) else null
	var generation: int = source._invalidate_generation() if source != null else 0
	var scheduler: ConstructionSupplyScheduler = supply_scheduler if _node_is_available(supply_scheduler) else null
	var was_dispatching: bool = false
	if scheduler != null:
		was_dispatching = _scheduler_auto_before_reset if _scheduler_paused_for_reset == scheduler else scheduler.auto_dispatch
		_scheduler_paused_for_reset = scheduler
		_scheduler_auto_before_reset = was_dispatching
		scheduler.auto_dispatch = false
	_worker_contexts.clear()
	_request_workers.clear()
	_admissions.clear()
	_local_continuations.clear()
	var workers: Array[ConstructionWorker] = _workers.duplicate()
	_workers.clear()
	for worker: ConstructionWorker in workers:
		if not is_instance_valid(worker):
			continue
		_archive_worker(worker)
		worker.shutdown()
		# 原同步提交退出前保留供养锁，避免恢复 auto_supply 后另起付款。
		if bool(worker.get("_shutdown_complete")):
			_unregister_worker_supplies(worker)
			_archive_worker(worker)
			worker.queue_free()
		else:
			_free_shutdown_worker.call_deferred(worker, _epoch)
	if scheduler != null and _worker_registrations.is_empty():
		scheduler.reset()
		scheduler.auto_dispatch = was_dispatching
		_scheduler_paused_for_reset = null
	elif scheduler != null:
		_settlement_barrier = true
		_restore_scheduler_after_shutdown.call_deferred(scheduler, was_dispatching, _epoch)
	if source != null:
		source._clear_generation(generation)
	_operation_depth -= 1
	_resetting = false
	_publish_snapshot()


func _free_shutdown_worker(worker: ConstructionWorker, epoch: int) -> void:
	if not is_instance_valid(worker):
		return
	worker.shutdown()
	if not bool(worker.get("_shutdown_complete")):
		_free_shutdown_worker.call_deferred(worker, epoch)
		return
	_unregister_worker_supplies(worker)
	_archive_worker(worker)
	worker.queue_free()


func _restore_scheduler_after_shutdown(scheduler: ConstructionSupplyScheduler, auto_dispatch: bool, epoch: int) -> void:
	if not _node_is_available(scheduler) or epoch != _epoch:
		return
	for registered: ConstructionSupplyScheduler in _worker_registrations.values():
		if registered == scheduler:
			_restore_scheduler_after_shutdown.call_deferred(scheduler, auto_dispatch, epoch)
			return
	scheduler.reset()
	if not _exiting:
		scheduler.auto_dispatch = auto_dispatch
	_scheduler_paused_for_reset = null
	_settlement_barrier = false
	_schedule_pump()


func _archive_worker(worker: ConstructionWorker) -> void:
	var resources: Dictionary = worker.get_resource_snapshot()
	var previous: Dictionary = _archived_workers.get(worker.worker_id, {})
	for key: String in _archived_resources:
		var value: int = int(resources.get(key, 0))
		_archived_resources[key] += maxi(0, value - int(previous.get(key, 0)))
		previous[key] = maxi(value, int(previous.get(key, 0)))
	_archived_workers[worker.worker_id] = previous


func _discard_idle_worker(worker: ConstructionWorker) -> void:
	if not _node_is_available(worker):
		return
	_workers.erase(worker)
	_archive_worker(worker)
	worker.shutdown()
	_unregister_worker_supplies(worker)
	worker.queue_free()


func _paid_supply_transit(supply: Variant) -> int:
	if not _node_is_available(supply):
		return 0
	var count: int = 0
	for shipment: Dictionary in supply.get_shipment_records():
		if bool(shipment.get("debited", false)) and not bool(shipment.get("settled", false)) \
				and not bool(shipment.get("refunded", false)):
			count += 1
	return count


func _organ_matches_kind(organ: Variant, kind: StringName) -> bool:
	return organ is DigestiveOrgan if kind == &"digestive" else organ is AttackOrgan


func preview_retarget(construction_id: String, position: Vector2) -> Dictionary:
	var request: Dictionary = get_request(construction_id)
	if _resetting or _exiting or request.is_empty() or request["kind"] not in [&"growth", &"remote_cultivation"] \
			or request["state"] in ConstructionQueue.TERMINAL_STATES or not position.is_finite():
		return {"valid": false, "error": "请先选择尚未完成的 G 或 B 目标。"}
	var proposed: Dictionary = request["parameters"].duplicate(true)
	proposed["target_position"] = position
	if not queue._find_duplicate(request["kind"], proposed, construction_id).is_empty():
		return {"valid": false, "error": "另一建设目标已占用此落点。", "reason": &"duplicate"}
	var worker: ConstructionWorker = get_worker(construction_id)
	if worker != null and bool(request.get("started", false)):
		return worker.preview_retarget(position)
	if bool(request.get("started", false)):
		return remote_cultivation_system.preview_retarget(position) if request["kind"] == &"remote_cultivation" else growth_system.preview_retarget(position)
	var parameters: Dictionary = request["parameters"].duplicate(true)
	parameters["target_position"] = position
	var preview: Dictionary = _preview_request(request["kind"], parameters, request["payer"])
	var previous: Dictionary = request.get("detail", {})
	var old_cost: int = int(previous.get("total_cost", 0))
	var new_cost: int = int(preview.get("total_cost", 0))
	preview.merge({"effective_point": parameters["start_node"].global_position,
		"deferred": false, "old_remaining_cost": old_cost, "new_remaining_cost": new_cost,
		"cost_delta": new_cost - old_cost, "plan_version": int(parameters.get("plan_version", 1)) + 1}, true)
	# 断网等待仍允许替换合法几何；任务恢复连接后才付款。
	if preview.get("reason") == &"disconnected" and bool(preview.get("plan", {}).get("valid", false)):
		preview["valid"] = true
	return preview


func retarget(construction_id: String, position: Vector2) -> bool:
	var planned: Dictionary = preview_retarget(construction_id, position)
	if not bool(planned.get("valid", false)) or _accepting > 0 or _syncing:
		return false
	var request: Dictionary = get_request(construction_id)
	var generation: int = queue.get_generation()
	var worker: ConstructionWorker = get_worker(construction_id)
	_accepting += 1
	var accepted: bool = true
	if bool(request.get("started", false)):
		if worker != null:
			accepted = worker.retarget_target(position)
		else:
			var old_position: Vector2 = _execution.parameters["target_position"]
			_execution.parameters["target_position"] = position
			_syncing = true
			accepted = remote_cultivation_system.retarget_target(position) if request["kind"] == &"remote_cultivation" else growth_system.retarget_target(position)
			_syncing = false
			if not accepted:
				_execution.parameters["target_position"] = old_position
	if accepted and not _resetting and not _exiting and queue.get_generation() == generation:
		var context: WorkerContext = _worker_contexts.get(construction_id)
		if context != null:
			context.parameters["target_position"] = position
		_admissions[construction_id] = planned.duplicate(true)
		accepted = queue._coordinator_retarget(construction_id, generation, position, planned)
	_accepting -= 1
	if multi_worker_enabled:
		_sync_workers()
	else:
		_sync_execution()
	_schedule_pump()
	return accepted
