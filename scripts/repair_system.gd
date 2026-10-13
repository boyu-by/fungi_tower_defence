class_name RepairSystem
extends Node
## 复用单一付费维修任务修复菌丝或组织；只消费已抵达缓冲，不操作母核钱包。

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
	var target: Node2D
	var target_id: int = 0
	var target_name: String = ""
	var target_kind: StringName = &""
	var access_edge: HyphaEdge
	var core_time_credit: float = 0.0
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
func preview_repair(target: Node2D) -> Dictionary:
	var available_target: bool = _node_is_available(target) and target.has_method("get_health_snapshot")
	var values: PackedFloat64Array = _target_health_values(target) if available_target else PackedFloat64Array([0.0, 0.0])
	var missing: float = maxf(values[1] - values[0], 0.0)
	var edge: HyphaEdge = target as HyphaEdge
	var preview: Dictionary = {
		"valid": false, "reason": &"invalid_edge" if edge != null else &"invalid_target",
		"target": target if available_target else null,
		"target_id": target.get_instance_id() if available_target else 0,
		"target_name": _target_name(target) if available_target else "",
		"target_kind": _target_kind(target),
		"edge": edge if available_target else null,
		"edge_id": edge.get_instance_id() if available_target and edge != null else 0,
		"health": values[0], "max_health": values[1], "missing_health": missing,
		"estimated_cost": _cost_for(missing), "repair_point": null,
		"access_edge": null, "supply_reachable": false,
	}
	if not available_target:
		return preview
	if target is AttackOrgan and target.is_transplanting():
		preview["reason"] = &"transplanting"
		return preview
	if not _node_is_available(network_system):
		preview["reason"] = &"invalid_configuration"
		return preview
	if not _target_is_registered(target, network_system):
		return preview
	var source: MotherCore = network_system.peek_registered_core() as MotherCore
	if not _node_is_available(source) or source.health <= 0:
		preview["reason"] = &"core_unavailable"
		return preview
	if missing > 0.0 and not bool(target.call("is_repairable")):
		preview["reason"] = &"destroyed"
		return preview
	var access: Dictionary = _choose_access(network_system, source, target)
	var point: Node2D = access.get("point") as Node2D
	preview["repair_point"] = point
	preview["access_edge"] = access.get("access_edge")
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


func request_repair(target: Node2D) -> int:
	if _requesting or _resetting:
		return 0
	var preview: Dictionary = preview_repair(target)
	if not preview["valid"]:
		return 0
	_requesting = true
	if _current != null:
		_unwatch(_current)
	_last_task_id += 1
	var record: RepairTask = RepairTask.new()
	record.task_id = _last_task_id
	record.network = network_system
	record.target = target
	record.target_id = target.get_instance_id()
	record.target_name = String(preview["target_name"])
	record.target_kind = StringName(preview["target_kind"])
	record.edge = target as HyphaEdge
	record.edge_id = record.edge.get_instance_id() if record.edge != null else 0
	record.access_edge = preview.get("access_edge") as HyphaEdge
	record.source_core = network_system.peek_registered_core() as MotherCore
	record.start_node = record.edge.start_node if record.edge != null else _target_host(target)
	record.end_node = record.edge.end_node if record.edge != null else record.start_node
	record.end_id = record.end_node.get_instance_id() if record.end_node != null else 0
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


func get_resource_snapshot() -> Dictionary:
	return {"task_id": _current.task_id, "consumed_nutrition": _current.consumed_nutrition,
		"buffered_nutrition": _current.buffered_nutrition} if _current != null else {
		"task_id": 0, "consumed_nutrition": 0, "buffered_nutrition": 0}


func get_delivery_target(task_id: int) -> Node2D:
	if not _is_current_active(task_id) or _identity_reason(_current) != &"":
		return null
	return _current.repair_point if _node_is_available(_current.repair_point) else null


func is_target_valid(task_id: int) -> bool:
	return _is_current_active(task_id) and _identity_reason(_current) == &""


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
	var remaining_time: float = delta + record.core_time_credit
	record.core_time_credit = 0.0
	refresh_access()
	while _can_advance(record) and remaining_time > 0.0:
		var values: PackedFloat64Array = _target_health_values(record.target)
		var missing: float = maxf(values[1] - values[0], 0.0)
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
		if record.target is MotherCore:
			step = floorf(step + 0.000000001)
		if step <= 0.0:
			if record.target is MotherCore:
				record.core_time_credit = minf(remaining_time, 1.0 / HEALING_SPEED)
			break
		# 所有账本先于 health_changed 提交。回调暂停/取消/重启不能重花这一单位。
		# 与预计的新生命值共用同一差值，避免 0.1 HP 尾数因浮点误差多报价一单位。
		var unpaid_missing: float = maxf(missing - record.paid_heal_remaining, 0.0)
		var next_health: float = minf(values[0] + step, values[1])
		record.paid_heal_remaining = maxf(values[1] - next_health - unpaid_missing, 0.0)
		record.restored_health += step
		remaining_time = maxf(remaining_time - step / HEALING_SPEED, 0.0)
		var restored: float = float(record.target.call("heal", step))
		if _current != record or not _record_is_active(record):
			break
		# 组织返回本次实际恢复量，而非同步回调之后的净生命值变化。
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
	if _record_is_active(record) and is_instance_valid(record.target):
		return _target_health_values(record.target)
	return PackedFloat64Array([record.health, record.max_health])


func _target_health_values(target: Node2D) -> PackedFloat64Array:
	var snapshot: Dictionary = target.call("get_health_snapshot")
	return PackedFloat64Array([float(snapshot.get("health", 0.0)), float(snapshot.get("max_health", 0.0))])


func _target_kind(target: Node2D) -> StringName:
	if target is HyphaEdge:
		return &"edge"
	if target is MotherCore:
		return &"core"
	if target is HyphaNode:
		return &"junction"
	if target is AttackOrgan:
		return &"attack"
	if target is DigestiveOrgan:
		return &"digestive"
	if target is OrganBud:
		return &"bud"
	if target is GrowthTip:
		return &"tip"
	return &""


func _target_name(target: Node2D) -> String:
	if target is HyphaNode:
		return target.display_name
	return String(target.name) if not String(target.name).is_empty() else String(_target_kind(target))


func _target_host(target: Node2D) -> Node2D:
	if target is AttackOrgan or target is DigestiveOrgan or target is OrganBud:
		return target.get_parent() as HyphaNode
	return target


func _target_is_registered(target: Node2D, network: NetworkSystem) -> bool:
	if not _node_is_available(target) or not target.has_method("is_repairable"):
		return false
	if target is HyphaEdge:
		return network.is_edge_valid(target) and _node_is_available(target.start_node) and _node_is_available(target.end_node)
	if _target_kind(target) == &"":
		return false
	var host: Node2D = _target_host(target)
	return _node_is_available(host) and network.is_node_registered(host)


func _remaining_cost(record: RepairTask) -> int:
	var values: PackedFloat64Array = _health_values(record)
	return _cost_for(maxf(values[1] - values[0] - record.paid_heal_remaining, 0.0))


func _remaining_demand(record: RepairTask) -> int:
	return maxi(_remaining_cost(record) - record.buffered_nutrition, 0)


func _choose_access(network: NetworkSystem, source: MotherCore, target: Node2D) -> Dictionary:
	if target is HyphaEdge:
		if network.find_available_route_excluding(source, target.start_node, target, 1).found:
			return {"point": target.start_node}
		if network.find_available_route_excluding(source, target.end_node, target, 1).found:
			return {"point": target.end_node}
	elif target is HyphaNode:
		# 最后一条活边只承担邻点到菌结的修复作业；普通包止于邻点。
		# 邻点不能借该边到达，且路线中任何其他死亡菌结都不可通行。
		for candidate: HyphaEdge in network.get_registered_edges():
			if not network.is_edge_valid(candidate) or candidate.health <= 0.0 \
					or not candidate.entry_enabled or candidate.traffic_capacity < 1:
				continue
			var point: Node2D = candidate.end_node if candidate.start_node == target else candidate.start_node
			if not candidate.connects(target, point):
				continue
			if network.find_available_route_excluding(source, point, candidate, 1).found:
				return {"point": point, "access_edge": candidate}
	else:
		var point: Node2D = _target_host(target)
		if network.find_available_route(source, point, 1).found:
			return {"point": point}
	return {}


func get_delivery_exclusions(task_id: int) -> Array[HyphaEdge]:
	if not _is_current_active(task_id):
		return []
	return _route_exclusions(_current)


func _route_exclusions(record: RepairTask) -> Array[HyphaEdge]:
	var exclusions: Array[HyphaEdge] = []
	if is_instance_valid(record.edge):
		exclusions.append(record.edge)
	if is_instance_valid(record.access_edge):
		exclusions.append(record.access_edge)
	return exclusions


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
	if not _node_is_available(record.target):
		return &"invalid_target"
	if not _target_is_registered(record.target, record.network) \
			or record.target.get_instance_id() != record.target_id:
		return &"invalid_target"
	if record.edge != null:
		if record.edge.start_node != record.start_node or not _node_is_available(record.start_node):
			return &"target_changed"
		var endpoint: Node2D = _resolved_end(record)
		if endpoint == null or endpoint != record.edge.end_node:
			return &"target_changed"
		if record.repair_point != null and record.repair_point != record.edge.start_node \
				and record.repair_point != record.edge.end_node:
			return &"repair_point_changed"
	else:
		if _target_host(record.target) != record.start_node:
			return &"target_changed"
		if record.target is MotherCore and record.target != record.source_core:
			return &"invalid_target"
		var values: PackedFloat64Array = _target_health_values(record.target)
		if values[0] <= 0.0 and not record.target is HyphaNode:
			return &"destroyed"
		if record.target is HyphaNode and record.repair_point != null:
			if not is_instance_valid(record.access_edge) or not record.network.is_edge_valid(record.access_edge) \
					or not record.access_edge.connects(record.target, record.repair_point):
				return &"repair_point_changed"
	if record.repair_point != null and (not _node_is_available(record.repair_point) \
			or not record.network.is_node_registered(record.repair_point)):
		return &"repair_point_unavailable"
	return &""


func _supply_is_reachable(record: RepairTask) -> bool:
	if _identity_reason(record) != &"" or not _node_is_available(record.repair_point):
		return false
	if record.target is HyphaNode and (not is_instance_valid(record.access_edge) \
			or record.access_edge.health <= 0.0 or not record.access_edge.entry_enabled \
			or record.access_edge.traffic_capacity < 1):
		return false
	return record.network.find_available_route_avoiding(
		record.source_core, record.repair_point, _route_exclusions(record), 1
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
	var endpoint: Node2D = _resolved_end(record) if record.edge != null else record.end_node
	if endpoint != record.end_node:
		record.end_node = endpoint
		record.end_id = endpoint.get_instance_id()
		changed = true
	if record.repair_point == null and record.source_core.health > 0:
		var access: Dictionary = _choose_access(record.network, record.source_core, record.target)
		var point: Node2D = access.get("point") as Node2D
		if point != null:
			record.repair_point = point
			record.access_edge = access.get("access_edge") as HyphaEdge
			changed = true
	_watch_task(record)
	var reachable: bool = _supply_is_reachable(record)
	var values: PackedFloat64Array = _target_health_values(record.target)
	changed = changed or reachable != record.supply_reachable \
		or record.health != values[0] or record.max_health != values[1]
	record.supply_reachable = reachable
	record.health = values[0]
	record.max_health = values[1]
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
	if is_instance_valid(record.target):
		var values: PackedFloat64Array = _target_health_values(record.target)
		record.health = values[0]
		record.max_health = values[1]
	record.state = state
	record.wait_reason = reason
	record.supply_reachable = false
	record.paid_heal_remaining = 0.0
	record.core_time_credit = 0.0
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
	_watch(record, record.target, &"health_changed", _on_edge_health_changed.bind(record.task_id))
	_watch(record, record.target, &"tree_exiting", _on_dependency_exiting.bind(record.task_id, &"invalid_target"))
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
		"target": record.target if is_instance_valid(record.target) else null,
		"target_id": record.target_id, "target_name": record.target_name,
		"target_kind": record.target_kind,
		"edge": record.edge if is_instance_valid(record.edge) else null,
		"edge_id": record.edge_id,
		"access_edge": record.access_edge if is_instance_valid(record.access_edge) else null,
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
		"target": null, "target_id": 0, "target_name": "", "target_kind": &"",
		"access_edge": null, "edge_id": 0, "source_core": null, "repair_point": null, "supply_reachable": false,
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
