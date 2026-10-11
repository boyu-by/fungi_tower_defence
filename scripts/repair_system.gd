class_name RepairSystem
extends Node
## 单独推进一条受损菌丝的维修；只消费已投递缓冲，不操作母核钱包。

signal task_changed(snapshot: Dictionary)
signal task_completed(task_id: int)
signal task_cancelled(task_id: int)

const HEALTH_PER_NUTRITION: float = 10.0
const HEALING_SPEED: float = 10.0
const MAX_TASK_ID: int = 9223372036854775807

class Watch:
	extends RefCounted

	var node: Node
	var signal_name: StringName
	var callback: Callable

class RepairTask:
	extends RefCounted

	var task_id: int = 0
	var state: StringName = &"waiting"
	var wait_reason: StringName = &"nutrition"
	var network: NetworkSystem
	var edge: HyphaEdge
	var edge_id: int = 0
	var source_core: MotherCore
	var start_node: Node2D
	var end_node: Node2D
	var end_id: int = 0
	var repair_point: Node2D = null
	var supply_reachable: bool = false
	var health: float = 0.0
	var max_health: float = 0.0
	var initial_cost: int = 0
	var consumed_nutrition: int = 0
	var buffered_nutrition: int = 0
	var paid_heal_remaining: float = 0.0
	var restored_health: float = 0.0
	var shipments: Dictionary[String, bool] = {}
	var watches: Array[Watch] = []
	var terminal_notified: bool = false

@export var network_system: NetworkSystem:
	set(value):
		if network_system == value:
			return
		network_system = value
		refresh_access()

var _last_task_id: int = 0
var _current: RepairTask = null
var _requesting: bool = false
var _refreshing: bool = false
var _advancing: bool = false
var _resetting: bool = false
var _reset_requested: bool = false
var _emitting_changed: bool = false
var _changed_pending: bool = false


func _physics_process(delta: float) -> void:
	refresh_access()
	advance(delta)


func _exit_tree() -> void:
	if has_active_task():
		_finish(_current, &"cancelled", &"system_unavailable")
	elif _current != null:
		_unwatch(_current)


func _on_access_changed(task_id: int) -> void:
	if _is_current_active(task_id):
		refresh_access()


func _on_source_health_changed(_health: int, _maximum: int, task_id: int) -> void:
	_on_access_changed(task_id)


func _on_edge_health_changed(_health: float, _maximum: float, task_id: int) -> void:
	_on_access_changed(task_id)


func _on_dependency_exiting(task_id: int, kind: StringName) -> void:
	if not _is_current_active(task_id):
		return
	if kind == &"endpoint":
		# 已付费的尖端交接可先换端点再释放旧尖端；先核对新身份。
		refresh_access()
	else:
		_finish(_current, &"cancelled", kind)


## 纯预览：无路径仍可创建等待任务；报价对最后不足 10 HP 向上取整。
func preview_repair(edge: HyphaEdge) -> Dictionary:
	var available_edge: bool = _node_is_available(edge)
	var current_health: float = edge.health if available_edge else 0.0
	var maximum: float = edge.max_health if available_edge else 0.0
	var missing: float = maxf(maximum - current_health, 0.0)
	var preview: Dictionary = {
		"valid": false,
		"reason": &"invalid_edge",
		"edge": edge if available_edge else null,
		"edge_id": edge.get_instance_id() if available_edge else 0,
		"health": current_health,
		"max_health": maximum,
		"missing_health": missing,
		"estimated_cost": _cost_for(missing),
		"repair_point": null,
		"supply_reachable": false,
	}
	if not available_edge:
		return preview
	if not _node_is_available(network_system):
		preview["reason"] = &"invalid_configuration"
		return preview
	if not network_system.is_edge_valid(edge) or not _node_is_available(edge.start_node) \
			or not _node_is_available(edge.end_node):
		return preview
	var source: MotherCore = network_system.peek_registered_core() as MotherCore
	if not _node_is_available(source) or source.health <= 0:
		preview["reason"] = &"core_unavailable"
		return preview
	var point: Node2D = _choose_point(network_system, source, edge)
	preview["repair_point"] = point
	preview["supply_reachable"] = point != null
	if missing <= 0.0:
		preview["reason"] = &"full"
	elif has_active_task() or _requesting or _resetting:
		preview["reason"] = &"busy"
	elif _current != null and _current.buffered_nutrition > 0:
		preview["reason"] = &"settlement_pending"
	elif _last_task_id == MAX_TASK_ID:
		preview["reason"] = &"task_id_exhausted"
	else:
		preview["valid"] = true
		preview["reason"] = &"ready" if point != null else &"disconnected"
	return preview


func request_repair(edge: HyphaEdge) -> int:
	if _requesting or _resetting:
		return 0
	var preview: Dictionary = preview_repair(edge)
	if not preview["valid"]:
		return 0
	_requesting = true
	if _current != null:
		_unwatch(_current)
	_last_task_id += 1
	var record: RepairTask = RepairTask.new()
	record.task_id = _last_task_id
	record.network = network_system
	record.edge = edge
	record.edge_id = edge.get_instance_id()
	record.source_core = network_system.peek_registered_core() as MotherCore
	record.start_node = edge.start_node
	record.end_node = edge.end_node
	record.end_id = edge.end_node.get_instance_id()
	record.repair_point = preview["repair_point"] as Node2D
	record.supply_reachable = bool(preview["supply_reachable"])
	record.health = float(preview["health"])
	record.max_health = float(preview["max_health"])
	record.initial_cost = int(preview["estimated_cost"])
	record.wait_reason = &"nutrition" if record.supply_reachable else &"disconnected"
	_current = record
	_reset_requested = false
	_watch_task(record)
	_requesting = false
	# 之后的同步通知可取消、结算并新建任务；只返回本次已经创建的编号。
	_publish_changed()
	return record.task_id


func has_active_task() -> bool:
	return _current != null and _record_is_active(_current)


## 此 getter 及所有访问查询均不选点、不刷新、不结算、不发送信号。
func get_task_snapshot() -> Dictionary:
	return _idle_snapshot() if _current == null else _snapshot(_current)


func get_delivery_target(task_id: int) -> Node2D:
	if not _is_current_active(task_id) or _identity_reason(_current) != &"":
		return null
	return _current.repair_point if _node_is_available(_current.repair_point) else null


func is_supply_reachable(task_id: int) -> bool:
	return _is_current_active(task_id) and _supply_is_reachable(_current)


func get_requested_nutrition(task_id: int) -> int:
	if not _is_current_active(task_id) or _identity_reason(_current) != &"":
		return 0
	return _remaining_demand(_current)


## 显式变更：首次可达时固定工作点，之后断路只等待原点恢复。
func refresh_access() -> void:
	if _refreshing or not has_active_task():
		return
	_refreshing = true
	var record: RepairTask = _current
	var changed: bool = _refresh_record(record)
	_refreshing = false
	if changed and _current == record:
		_publish_changed()


func receive_nutrition(task_id: int, shipment_id: String, amount: int) -> bool:
	if not _is_current_active(task_id) or shipment_id.is_empty() or amount <= 0:
		return false
	var record: RepairTask = _current
	refresh_access()
	if _current != record or not _record_is_active(record) or _identity_reason(record) != &"" \
			or record.repair_point == null or record.shipments.has(shipment_id) \
			or amount > _remaining_demand(record) \
			or amount > MAX_TASK_ID - record.buffered_nutrition:
		return false
	# 先登记唯一收件，回调重放同一包不会再次增加缓冲。
	record.shipments[shipment_id] = true
	record.buffered_nutrition += amount
	_refresh_record(record)
	_publish_changed()
	return true


## 只结算终态未消费整数营养；已经消费的恢复额度永不退款。
func take_unspent_nutrition(task_id: int) -> int:
	if _current == null or _current.task_id != task_id or _record_is_active(_current) \
			or _current.buffered_nutrition <= 0:
		return 0
	var record: RepairTask = _current
	var unspent: int = record.buffered_nutrition
	record.buffered_nutrition = 0
	if _reset_requested and not _resetting:
		_unwatch(record)
		_current = null
		_reset_requested = false
	_publish_changed()
	return unspent


func advance(delta: float) -> void:
	if _advancing or not is_finite(delta) or delta <= 0.0 or not has_active_task():
		return
	_advancing = true
	var record: RepairTask = _current
	var remaining_time: float = delta
	refresh_access()
	while _can_advance(record) and remaining_time > 0.0:
		var missing: float = maxf(record.edge.max_health - record.edge.health, 0.0)
		if missing <= 0.0:
			_finish(record, &"completed", &"")
			break
		if record.paid_heal_remaining <= 0.0:
			if record.buffered_nutrition <= 0:
				break
			record.buffered_nutrition -= 1
			record.consumed_nutrition += 1
			record.paid_heal_remaining = minf(HEALTH_PER_NUTRITION, missing)
		var step: float = minf(minf(missing, record.paid_heal_remaining), remaining_time * HEALING_SPEED)
		if step <= 0.0:
			break
		# 所有账本先于 health_changed 提交。回调暂停/取消/重启不能重花这一单位。
		# 与预计的新生命值共用同一差值，避免 0.1 HP 尾数因浮点误差多报价一单位。
		var unpaid_missing: float = maxf(missing - record.paid_heal_remaining, 0.0)
		var next_health: float = minf(record.edge.health + step, record.edge.max_health)
		record.paid_heal_remaining = maxf(record.edge.max_health - next_health - unpaid_missing, 0.0)
		record.restored_health += step
		remaining_time = maxf(remaining_time - step / HEALING_SPEED, 0.0)
		var restored: float = record.edge.restore_health(step)
		if _current != record or not _record_is_active(record):
			break
		# HyphaEdge 返回本次实际恢复量，而非同步回调之后的净生命值变化。
		if restored != step:
			record.restored_health -= step - restored
			record.paid_heal_remaining += step - restored
		_refresh_record(record)
		if _current == record:
			_publish_changed()
	_advancing = false


func pause_task() -> bool:
	if not has_active_task() or _current.state == &"paused":
		return false
	var record: RepairTask = _current
	refresh_access()
	if _current != record or not _record_is_active(record):
		return false
	record.state = &"paused"
	record.wait_reason = &"paused"
	_publish_changed()
	return true


func resume_task() -> bool:
	if not has_active_task() or _current.state != &"paused":
		return false
	var record: RepairTask = _current
	record.state = &"waiting"
	refresh_access()
	if _current == record and _record_is_active(record):
		_publish_changed()
	return true


func cancel_task() -> bool:
	if not has_active_task():
		return false
	_finish(_current, &"cancelled", &"")
	return true


## Supply 应先取消并退款再 reset；直接 reset 仍保留未结算缓冲，防止丢账。
func reset() -> void:
	if _resetting:
		return
	_resetting = true
	_reset_requested = true
	var record: RepairTask = _current
	if has_active_task():
		_finish(record, &"cancelled", &"reset")
	if _current == record and (record == null or record.buffered_nutrition == 0):
		if record != null:
			_unwatch(record)
		_current = null
		_reset_requested = false
	_resetting = false
	_publish_changed()


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion() and node.is_inside_tree()


func _record_is_active(record: RepairTask) -> bool:
	return record.state in [&"waiting", &"repairing", &"paused"]


func _is_current_active(task_id: int) -> bool:
	return has_active_task() and _current.task_id == task_id


func _cost_for(missing: float) -> int:
	return ceili(maxf(missing, 0.0) / HEALTH_PER_NUTRITION)


func _health_values(record: RepairTask) -> PackedFloat64Array:
	if _record_is_active(record) and is_instance_valid(record.edge):
		return PackedFloat64Array([record.edge.health, record.edge.max_health])
	return PackedFloat64Array([record.health, record.max_health])


func _remaining_cost(record: RepairTask) -> int:
	var values: PackedFloat64Array = _health_values(record)
	return _cost_for(maxf(values[1] - values[0] - record.paid_heal_remaining, 0.0))


func _remaining_demand(record: RepairTask) -> int:
	return maxi(_remaining_cost(record) - record.buffered_nutrition, 0)


func _choose_point(network: NetworkSystem, source: MotherCore, edge: HyphaEdge) -> Node2D:
	if network.find_available_route_excluding(source, edge.start_node, edge, 1).found:
		return edge.start_node
	if network.find_available_route_excluding(source, edge.end_node, edge, 1).found:
		return edge.end_node
	return null


func _resolved_end(record: RepairTask) -> Node2D:
	if record.edge.end_node == record.end_node:
		return record.end_node if _node_is_available(record.end_node) else null
	return record.network.get_growth_handoff(record.edge, record.end_id)


func _identity_reason(record: RepairTask) -> StringName:
	if not _node_is_available(record.network) or network_system != record.network:
		return &"network_unavailable"
	if not _node_is_available(record.source_core) \
			or record.network.peek_registered_core() != record.source_core \
			or record.source_core.health <= 0:
		return &"core_unavailable"
	if not _node_is_available(record.edge) or not record.network.is_edge_valid(record.edge):
		return &"invalid_target"
	if record.edge.start_node != record.start_node or not _node_is_available(record.start_node):
		return &"target_changed"
	var endpoint: Node2D = _resolved_end(record)
	if endpoint == null or endpoint != record.edge.end_node:
		return &"target_changed"
	if record.repair_point != null:
		if record.repair_point != record.edge.start_node and record.repair_point != record.edge.end_node:
			return &"repair_point_changed"
		if not _node_is_available(record.repair_point) or not record.network.is_node_registered(record.repair_point):
			return &"repair_point_unavailable"
	return &""


func _supply_is_reachable(record: RepairTask) -> bool:
	return _identity_reason(record) == &"" and record.source_core.health > 0 \
		and _node_is_available(record.repair_point) \
		and record.network.find_available_route_excluding(
			record.source_core, record.repair_point, record.edge, 1
		).found


func _can_advance(record: RepairTask) -> bool:
	return _current == record and _record_is_active(record) and record.state != &"paused" \
		and _supply_is_reachable(record)


func _refresh_record(record: RepairTask) -> bool:
	if _current != record or not _record_is_active(record):
		return false
	var invalid_reason: StringName = _identity_reason(record)
	if invalid_reason != &"":
		_finish(record, &"cancelled", invalid_reason)
		return false
	var changed: bool = false
	var endpoint: Node2D = _resolved_end(record)
	if endpoint != record.end_node:
		record.end_node = endpoint
		record.end_id = endpoint.get_instance_id()
		changed = true
	if record.repair_point == null and record.source_core.health > 0:
		var point: Node2D = _choose_point(record.network, record.source_core, record.edge)
		if point != null:
			record.repair_point = point
			changed = true
	_watch_task(record)
	var reachable: bool = _supply_is_reachable(record)
	changed = changed or reachable != record.supply_reachable \
		or record.health != record.edge.health or record.max_health != record.edge.max_health
	record.supply_reachable = reachable
	record.health = record.edge.health
	record.max_health = record.edge.max_health
	if record.health >= record.max_health:
		_finish(record, &"completed", &"")
		return false
	var state: StringName = &"waiting"
	var reason: StringName = &""
	if record.state == &"paused":
		state = &"paused"
		reason = &"paused"
	elif record.source_core.health <= 0:
		reason = &"core_unavailable"
	elif not reachable:
		reason = &"disconnected"
	elif record.paid_heal_remaining > 0.0 or record.buffered_nutrition > 0:
		state = &"repairing"
	else:
		reason = &"nutrition"
	changed = changed or state != record.state or reason != record.wait_reason
	record.state = state
	record.wait_reason = reason
	return changed


func _finish(record: RepairTask, state: StringName, reason: StringName) -> void:
	if _current != record or not _record_is_active(record) or record.terminal_notified:
		return
	if is_instance_valid(record.edge):
		record.health = record.edge.health
		record.max_health = record.edge.max_health
	record.state = state
	record.wait_reason = reason
	record.supply_reachable = false
	record.paid_heal_remaining = 0.0
	record.terminal_notified = true
	_unwatch(record)
	var finished_id: int = record.task_id
	_publish_changed()
	if state == &"completed":
		task_completed.emit(finished_id)
	else:
		task_cancelled.emit(finished_id)


func _watch_task(record: RepairTask) -> void:
	_watch(record, record.network, &"network_changed", _on_access_changed.bind(record.task_id))
	_watch(record, record.network, &"tree_exiting", _on_dependency_exiting.bind(record.task_id, &"network_unavailable"))
	_watch(record, record.source_core, &"health_changed", _on_source_health_changed.bind(record.task_id))
	_watch(record, record.source_core, &"tree_exiting", _on_dependency_exiting.bind(record.task_id, &"core_unavailable"))
	_watch(record, record.edge, &"health_changed", _on_edge_health_changed.bind(record.task_id))
	_watch(record, record.edge, &"tree_exiting", _on_dependency_exiting.bind(record.task_id, &"invalid_target"))
	_watch(record, record.start_node, &"tree_exiting", _on_dependency_exiting.bind(record.task_id, &"endpoint"))
	_watch(record, record.end_node, &"tree_exiting", _on_dependency_exiting.bind(record.task_id, &"endpoint"))
	for edge: HyphaEdge in record.network.get_registered_edges():
		_watch(record, edge, &"traffic_settings_changed", _on_access_changed.bind(record.task_id))


func _watch(record: RepairTask, node: Node, signal_name: StringName, callback: Callable) -> void:
	if not _node_is_available(node) or node.is_connected(signal_name, callback):
		return
	var watch: Watch = Watch.new()
	watch.node = node
	watch.signal_name = signal_name
	watch.callback = callback
	record.watches.append(watch)
	node.connect(signal_name, callback)


func _unwatch(record: RepairTask) -> void:
	for watch: Watch in record.watches:
		if is_instance_valid(watch.node) and watch.node.is_connected(watch.signal_name, watch.callback):
			watch.node.disconnect(watch.signal_name, watch.callback)
	record.watches.clear()


func _snapshot(record: RepairTask) -> Dictionary:
	var values: PackedFloat64Array = _health_values(record)
	var missing: float = maxf(values[1] - values[0], 0.0)
	var remaining_cost: int = _remaining_cost(record)
	var state: StringName = record.state
	var reason: StringName = record.wait_reason
	var reachable: bool = _record_is_active(record) and _supply_is_reachable(record)
	if _record_is_active(record) and state != &"paused":
		var invalid_reason: StringName = _identity_reason(record)
		if invalid_reason != &"":
			state = &"waiting"
			reason = invalid_reason
		elif record.source_core.health <= 0:
			state = &"waiting"
			reason = &"core_unavailable"
		elif not reachable:
			state = &"waiting"
			reason = &"disconnected"
	return {
		"task_id": record.task_id,
		"state": state,
		"wait_reason": reason,
		"edge": record.edge if is_instance_valid(record.edge) else null,
		"edge_id": record.edge_id,
		"source_core": record.source_core if is_instance_valid(record.source_core) else null,
		"repair_point": record.repair_point if is_instance_valid(record.repair_point) else null,
		"supply_reachable": reachable,
		"health": values[0],
		"max_health": values[1],
		"missing_health": missing,
		"initial_cost": record.initial_cost,
		"estimated_total_cost": record.consumed_nutrition + remaining_cost,
		"consumed_nutrition": record.consumed_nutrition,
		"buffered_nutrition": record.buffered_nutrition,
		"paid_heal_remaining": record.paid_heal_remaining,
		"restored_health": record.restored_health,
		"remaining_cost": remaining_cost,
		"remaining_demand": maxi(remaining_cost - record.buffered_nutrition, 0),
	}


func _idle_snapshot() -> Dictionary:
	return {
		"task_id": 0, "state": &"idle", "wait_reason": &"", "edge": null,
		"edge_id": 0, "source_core": null, "repair_point": null, "supply_reachable": false,
		"health": 0.0, "max_health": 0.0, "missing_health": 0.0,
		"initial_cost": 0, "estimated_total_cost": 0, "consumed_nutrition": 0,
		"buffered_nutrition": 0, "paid_heal_remaining": 0.0, "restored_health": 0.0,
		"remaining_cost": 0, "remaining_demand": 0,
	}


func _publish_changed() -> void:
	_changed_pending = true
	if _emitting_changed:
		return
	_emitting_changed = true
	while _changed_pending:
		_changed_pending = false
		task_changed.emit(get_task_snapshot())
	_emitting_changed = false
