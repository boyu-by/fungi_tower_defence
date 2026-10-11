class_name ConnectionSystem
extends Node
## 既有菌结连接的薄入口；施工、营养运输与结算均委托同一个 GrowthSystem。

signal task_changed(snapshot: Dictionary)
signal task_completed(task_id: int)
signal task_cancelled(task_id: int)
signal connection_completed(task_id: int, source_node: HyphaNode, target_node: HyphaNode)

@export var growth_system: GrowthSystem
@export var mother_core: MotherCore

var construction_blocker: Callable = Callable()

var _receiver: GrowthSystem = null
var _task_id: int = 0
var _source_node: HyphaNode = null
var _target_node: HyphaNode = null
var _last_snapshot: Dictionary = {}
var _callbacks: Array[Callable] = []
var _requesting: bool = false
var _resetting: bool = false
var _epoch: int = 0
var _completed_emitted: bool = false
var _cancelled_emitted: bool = false


func _ready() -> void:
	_last_snapshot = _idle_snapshot()
	_bind_receiver(growth_system)


func _exit_tree() -> void:
	reset()
	_unbind_receiver()


func preview_connection(first: HyphaNode, second: HyphaNode) -> Dictionary:
	var preview: Dictionary = {
		"valid": false,
		"error": "",
		"reason": &"",
		"first_node": first if _is_live_node(first) else null,
		"second_node": second if _is_live_node(second) else null,
		"start_node": null,
		"target_node": null,
		"reversed": false,
		"plan": {},
		"total_cost": 0,
	}
	if not _configuration_is_valid():
		return _reject_preview(preview, &"invalid_configuration", "连接缺少生长系统、规划器或场景容器")
	if _requesting or _resetting or has_active_task() or growth_system.has_active_task():
		return _reject_preview(preview, &"busy", "当前已有生长或连接任务")
	if construction_blocker.is_valid() and bool(construction_blocker.call()):
		return _reject_preview(preview, &"construction_busy", "另一建设任务正在进行")
	if growth_system.construction_blocker.is_valid() and bool(growth_system.construction_blocker.call()):
		return _reject_preview(preview, &"construction_busy", "另一建设任务正在进行")
	if not _is_live_node(mother_core) or mother_core.health <= 0:
		return _reject_preview(preview, &"core_unavailable", "母核当前无法供给连接")
	if not _is_live_node(first) or not _is_live_node(second):
		return _reject_preview(preview, &"invalid_endpoint", "连接需要两个有效菌结")
	if first == second:
		return _reject_preview(preview, &"same_node", "请选择另一个菌结")
	var network: NetworkSystem = growth_system.network_system
	var registered: Array[Node2D] = network.get_registered_nodes()
	if not _is_live_node(first) or not _is_live_node(second) \
			or not registered.has(first) or not registered.has(second):
		return _reject_preview(preview, &"unregistered_endpoint", "连接端点必须属于当前网络")
	if network.get_registered_core() != mother_core:
		return _reject_preview(preview, &"core_unavailable", "当前网络缺少供给母核")
	if not _is_live_node(first) or not _is_live_node(second) or not _is_live_node(mother_core):
		return _reject_preview(preview, &"invalid_endpoint", "连接端点或母核已失效")
	if network.has_direct_connection(first, second):
		return _reject_preview(preview, &"already_connected", "两个菌结已有直接连接")
	if not _is_live_node(first) or not _is_live_node(second) or not _is_live_node(mother_core):
		return _reject_preview(preview, &"invalid_endpoint", "连接端点或母核已失效")
	var first_connected: bool = network.find_route(first, mother_core).found
	if not _is_live_node(first) or not _is_live_node(second) or not _is_live_node(mother_core):
		return _reject_preview(preview, &"invalid_endpoint", "连接端点或母核已失效")
	var second_connected: bool = network.find_route(second, mother_core).found
	if not _is_live_node(first) or not _is_live_node(second) \
			or not _is_live_node(mother_core) or mother_core.health <= 0:
		return _reject_preview(preview, &"invalid_endpoint", "连接端点或母核已失效")
	if not first_connected and not second_connected:
		return _reject_preview(preview, &"disconnected", "两个菌结都无法从母核取得供给")
	var source: HyphaNode = first if first_connected else second
	var target: HyphaNode = second if first_connected else first
	preview["start_node"] = source
	preview["target_node"] = target
	preview["reversed"] = not first_connected
	var plan: Dictionary = growth_system.planner.plan(source.global_position, target.global_position, true)
	preview["plan"] = plan
	preview["total_cost"] = int(plan["total_cost"])
	if not bool(plan["valid"]):
		return _reject_preview(preview, &"invalid_plan", String(plan["error"]))
	if float(plan["distance"]) <= 0.0:
		return _reject_preview(preview, &"same_position", "重合菌结没有可施工的连接距离")
	preview["valid"] = true
	return preview


func request_connection(first: HyphaNode, second: HyphaNode) -> int:
	var preview: Dictionary = preview_connection(first, second)
	if not bool(preview["valid"]):
		return 0
	_bind_receiver(growth_system)
	var receiver: GrowthSystem = _receiver
	var source: HyphaNode = preview["start_node"]
	var target: HyphaNode = preview["target_node"]
	var request_epoch: int = _epoch
	_requesting = true
	_source_node = source
	_target_node = target
	var created_task_id: int = receiver.create_connection(source, target)
	_requesting = false
	if created_task_id <= 0:
		return 0
	if request_epoch != _epoch:
		# reset 可以发生在初始快照回调中；仍由原供养系统清理刚建立的任务。
		if _is_live_node(receiver) and receiver.has_active_task() \
				and int(receiver.get_task_snapshot().get("task_id", 0)) == created_task_id:
			receiver.cancel_task()
		return 0
	if not _is_live_node(receiver):
		return 0
	var snapshot: Dictionary = receiver.get_task_snapshot()
	if int(snapshot.get("task_id", 0)) != created_task_id \
			or StringName(snapshot.get("task_kind", &"growth")) != &"connection":
		return 0
	# 初始快照通常已同步领养；未进入树的使用方式也得到同一份任务快照。
	if _task_id != created_task_id:
		_adopt_task(created_task_id)
	_forward_snapshot(snapshot)
	if request_epoch != _epoch or _task_id != created_task_id or _receiver != receiver:
		return 0
	return created_task_id


func has_active_task() -> bool:
	if _task_id <= 0 or not _is_live_node(_receiver) or not _receiver.has_active_task():
		return false
	var snapshot: Dictionary = _receiver.get_task_snapshot()
	return int(snapshot.get("task_id", 0)) == _task_id \
		and StringName(snapshot.get("task_kind", &"growth")) == &"connection" \
		and _receiver.has_active_task()


func get_task_snapshot() -> Dictionary:
	if _task_id > 0 and _is_live_node(_receiver):
		var snapshot: Dictionary = _receiver.get_task_snapshot()
		if int(snapshot.get("task_id", 0)) == _task_id \
				and StringName(snapshot.get("task_kind", &"growth")) == &"connection":
			return snapshot
	return _idle_snapshot() if _last_snapshot.is_empty() else _last_snapshot.duplicate()


func pause_task() -> bool:
	return has_active_task() and _receiver.pause_task()


func resume_task() -> bool:
	return has_active_task() and _receiver.resume_task()


func cancel_task() -> bool:
	return has_active_task() and _receiver.cancel_task()


func reset() -> void:
	if _resetting:
		return
	_resetting = true
	_epoch += 1
	if has_active_task():
		_receiver.cancel_task()
	_task_id = 0
	_source_node = null
	_target_node = null
	_completed_emitted = false
	_cancelled_emitted = false
	var snapshot: Dictionary = _idle_snapshot()
	_resetting = false
	_forward_snapshot(snapshot)


func _on_growth_task_changed(snapshot: Dictionary) -> void:
	if not _is_live_node(_receiver) \
			or StringName(snapshot.get("task_kind", &"growth")) != &"connection":
		return
	var task_id: int = int(snapshot.get("task_id", 0))
	if _requesting and not _resetting and task_id > 0 \
			and snapshot.get("start_node") == _source_node and snapshot.get("target_node") == _target_node:
		if _task_id != task_id:
			_adopt_task(task_id)
	if task_id != _task_id or task_id <= 0:
		return
	var current: Dictionary = _receiver.get_task_snapshot()
	if int(current.get("task_id", 0)) == task_id and current == snapshot:
		_forward_snapshot(snapshot)


func _on_growth_task_completed(task_id: int) -> void:
	if task_id != _task_id or _completed_emitted or _cancelled_emitted \
			or not _is_live_node(_receiver):
		return
	var snapshot: Dictionary = _receiver.get_task_snapshot()
	var endpoint: HyphaNode = _receiver.get_completed_endpoint(task_id)
	if int(snapshot.get("task_id", 0)) != task_id or snapshot.get("state") != &"completed" \
			or endpoint != _target_node or not _is_live_node(endpoint) or not _is_live_node(_source_node):
		return
	var completed_source: HyphaNode = _source_node
	var completed_target: HyphaNode = _target_node
	var completed_receiver: GrowthSystem = _receiver
	var completed_epoch: int = _epoch
	_completed_emitted = true
	_forward_snapshot(snapshot)
	if not _same_task_identity(
			task_id, completed_epoch, completed_receiver, completed_source, completed_target) \
			or not _is_live_node(completed_source) or not _is_live_node(completed_target):
		return
	connection_completed.emit(task_id, completed_source, completed_target)
	if _same_task_identity(
			task_id, completed_epoch, completed_receiver, completed_source, completed_target):
		task_completed.emit(task_id)


func _on_growth_task_cancelled(task_id: int) -> void:
	if task_id != _task_id or _cancelled_emitted or _completed_emitted or not _is_live_node(_receiver):
		return
	var snapshot: Dictionary = _receiver.get_task_snapshot()
	if int(snapshot.get("task_id", 0)) != task_id or snapshot.get("state") != &"cancelled":
		return
	var cancelled_epoch: int = _epoch
	var cancelled_receiver: GrowthSystem = _receiver
	var cancelled_source: HyphaNode = _source_node
	var cancelled_target: HyphaNode = _target_node
	_cancelled_emitted = true
	_forward_snapshot(snapshot)
	if _same_task_identity(
			task_id, cancelled_epoch, cancelled_receiver, cancelled_source, cancelled_target):
		task_cancelled.emit(task_id)


func _adopt_task(task_id: int) -> void:
	_task_id = task_id
	_completed_emitted = false
	_cancelled_emitted = false


func _bind_receiver(receiver: GrowthSystem) -> void:
	if _receiver == receiver and not _callbacks.is_empty():
		return
	_unbind_receiver()
	_task_id = 0
	_completed_emitted = false
	_cancelled_emitted = false
	_receiver = receiver
	if not _is_live_node(_receiver):
		return
	_callbacks = [_on_growth_task_changed, _on_growth_task_completed, _on_growth_task_cancelled]
	_receiver.task_changed.connect(_callbacks[0])
	_receiver.task_completed.connect(_callbacks[1])
	_receiver.task_cancelled.connect(_callbacks[2])


func _unbind_receiver() -> void:
	if is_instance_valid(_receiver) and _callbacks.size() == 3:
		if _receiver.task_changed.is_connected(_callbacks[0]):
			_receiver.task_changed.disconnect(_callbacks[0])
		if _receiver.task_completed.is_connected(_callbacks[1]):
			_receiver.task_completed.disconnect(_callbacks[1])
		if _receiver.task_cancelled.is_connected(_callbacks[2]):
			_receiver.task_cancelled.disconnect(_callbacks[2])
	_callbacks.clear()
	_receiver = null


func _configuration_is_valid() -> bool:
	return _is_live_node(growth_system) and growth_system.planner != null \
		and _is_live_node(growth_system.network_system) and _is_live_node(growth_system.node_container) \
		and _is_live_node(growth_system.edge_container) and _is_live_node(growth_system.tip_container)


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _same_task_identity(
	task_id: int, epoch: int, receiver: Variant, source: Variant, target: Variant
) -> bool:
	return _task_id == task_id and _epoch == epoch and _receiver == receiver \
		and _source_node == source and _target_node == target \
		and _is_live_node(receiver)


func _reject_preview(preview: Dictionary, reason: StringName, error: String) -> Dictionary:
	preview["reason"] = reason
	preview["error"] = error
	return preview


func _forward_snapshot(snapshot: Dictionary) -> void:
	if snapshot != _last_snapshot:
		_last_snapshot = snapshot.duplicate()
		task_changed.emit(snapshot)


func _idle_snapshot() -> Dictionary:
	return {
		"task_id": 0, "task_kind": &"connection", "state": &"idle", "wait_reason": &"",
		"progress": 0.0, "distance": 0.0, "total_distance": 0.0,
		"consumed_nutrition": 0, "buffered_nutrition": 0, "total_cost": 0, "remaining_cost": 0,
		"requested_nutrition": 0, "start_node": null, "target_node": null,
		"target_position": Vector2.ZERO, "tip_position": Vector2.ZERO, "formed_junctions": 0,
	}
