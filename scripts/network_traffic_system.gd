class_name NetworkTrafficSystem
extends Node

## 只登记每次过边的逻辑等待位置和占用，不移动运输包，也不结算营养。
## 两个方向共享同一 FIFO；所有状态先提交，随后通知观察者。

signal request_changed(snapshot: Dictionary)
signal traffic_changed

@export var network_system: NetworkSystem

var _generation: int = 1
var _sequence: int = 0
var _token_sequence: int = 0
var _requests: Dictionary[String, Dictionary] = {}
var _request_keys: Dictionary[String, String] = {}
var _owner_requests: Dictionary[int, String] = {}
var _queues: Dictionary[int, Array] = {}
var _leases: Dictionary[String, String] = {}
var _edge_leases: Dictionary[int, Array] = {}
var _retired_tasks: Dictionary[String, bool] = {}
var _cancelled_owners: Dictionary[int, bool] = {}
var _owner_bindings: Dictionary[int, Dictionary] = {}
var _exiting_owners: Dictionary[int, WeakRef] = {}
var _edge_bindings: Dictionary[int, Dictionary] = {}
var _edge_order: Array[int] = []
var _bound_network: Variant = null
var _bound_network_id: int = 0
var _network_callbacks: Dictionary[String, Callable] = {}
var _network_exited: bool = false
var _mutation_depth: int = 0
var _notifying: bool = false
var _notifications: Array[Dictionary] = []
var _traffic_dirty: bool = false


func _ready() -> void:
	refresh()


func _exit_tree() -> void:
	_disconnect_network()
	_disconnect_edges()
	_clear_records()
	_exiting_owners.clear()
	_bound_network = null
	_bound_network_id = 0
	_network_exited = false
	_notifications.clear()
	_traffic_dirty = false


func _process(_delta: float) -> void:
	refresh()


func _on_network_changed(network_id: int) -> void:
	if network_id == _bound_network_id:
		refresh()


func _on_network_tree_exiting(network_id: int) -> void:
	if network_id == _bound_network_id:
		_network_exited = true
		refresh()


func _on_network_tree_entered(network_id: int) -> void:
	if network_id == _bound_network_id:
		_network_exited = false
		refresh()


func _on_edge_settings_changed(edge_id: int, network_id: int) -> void:
	if network_id == _bound_network_id and _edge_bindings.has(edge_id):
		refresh()


func _on_edge_tree_exiting(edge_id: int, network_id: int) -> void:
	if network_id != _bound_network_id:
		return
	_begin_mutation()
	_refresh_internal()
	for request_id: String in _requests:
		var record: Dictionary = _requests[request_id]
		if int(record["edge_id"]) == edge_id and _is_active(record):
			_finish_request(record, &"cancelled", &"edge_removed")
	_drain_all_edges()
	_end_mutation()


func _on_owner_tree_exiting(owner_id: int, generation: int) -> void:
	if generation != _generation or not _owner_requests.has(owner_id):
		return
	var request_id: String = _owner_requests[owner_id]
	var owner: Variant = _requests[request_id]["owner"]
	if is_instance_valid(owner):
		_exiting_owners[owner_id] = weakref(owner)
	_begin_mutation()
	_refresh_internal()
	if _requests.has(request_id) and _is_active(_requests[request_id]):
		_finish_request(_requests[request_id], &"cancelled", &"owner_removed")
	_drain_all_edges()
	_end_mutation()


static func units_for_kind(cargo_kind: StringName) -> int:
	match cargo_kind:
		&"supply", &"return":
			return 1
		&"remains", &"transplant":
			return 2
		_:
			return 0


func request_passage(
	request_key: String, owner: Node, task_id: String, edge: HyphaEdge,
	from_node: Node2D, to_node: Node2D, cargo_kind: StringName
) -> Dictionary:
	_begin_mutation()
	_refresh_internal()
	var payload: Dictionary = _new_payload(
		request_key, owner, task_id, edge, from_node, to_node, cargo_kind
	)
	var request_id: String = ""
	var rejection: StringName = &""
	if _request_keys.has(request_key):
		var previous_id: String = _request_keys[request_key]
		if _same_payload(_requests[previous_id], payload):
			request_id = previous_id
		else:
			rejection = &"request_key_conflict"
	else:
		rejection = _admission_failure(payload)
		if rejection == &"":
			_sequence += 1
			request_id = "request:%d:%d:%d" % [get_instance_id(), _generation, _sequence]
			payload["request_id"] = request_id
			payload["sequence"] = _sequence
			payload["state"] = &"queued"
			payload["reason"] = &"queued"
			payload["_revision"] = 1
			payload["_owner_was_inside_tree"] = owner.is_inside_tree()
			payload["_edge_start_id"] = _object_id(edge.start_node)
			payload["_edge_end_id"] = _object_id(edge.end_node)
			_requests[request_id] = payload
			_request_keys[request_key] = request_id
			_owner_requests[int(payload["owner_id"])] = request_id
			var edge_id: int = int(payload["edge_id"])
			if not _queues.has(edge_id):
				_queues[edge_id] = []
			_queues[edge_id].append(request_id)
			_bind_owner(payload)
			_queue_notification(payload)
			_drain_all_edges()
	_end_mutation()
	# 回调可能释放、取消或重置刚才的申请；返回当前状态，绝不泄漏旧租约。
	if not request_id.is_empty():
		if _requests.has(request_id):
			return _request_snapshot(_requests[request_id])
		rejection = &"generation_changed"
	return _rejected_snapshot(payload, rejection)


func get_request(request_id: String) -> Dictionary:
	if not _requests.has(request_id):
		return {}
	return _request_snapshot(_requests[request_id])


func get_lease(token: String) -> Dictionary:
	if not _leases.has(token):
		return {}
	var request_id: String = _leases[token]
	if not _requests.has(request_id):
		return {}
	var record: Dictionary = _requests[request_id]
	if record["state"] != &"granted" or record["token"] != token:
		return {}
	return _request_snapshot(record)


func cancel_request(request_id: String) -> bool:
	_begin_mutation()
	_refresh_internal()
	var cancelled: bool = _requests.has(request_id) and _is_active(_requests[request_id])
	if cancelled:
		_finish_request(_requests[request_id], &"cancelled", &"cancelled")
		_drain_all_edges()
	_end_mutation()
	return cancelled


func release(token: String) -> bool:
	_begin_mutation()
	_refresh_internal()
	var released: bool = _leases.has(token)
	if released:
		var request_id: String = _leases[token]
		_finish_request(_requests[request_id], &"released", &"released")
		_drain_all_edges()
	_end_mutation()
	return released


func cancel_owner(owner: Node) -> int:
	_begin_mutation()
	_refresh_internal()
	var owner_id: int = _object_id(owner)
	var cancelled: int = 0
	if owner_id != 0:
		_cancelled_owners[owner_id] = true
	if _owner_requests.has(owner_id):
		var request_id: String = _owner_requests[owner_id]
		_finish_request(_requests[request_id], &"cancelled", &"owner_cancelled")
		cancelled = 1
		_drain_all_edges()
	_end_mutation()
	return cancelled


func cancel_task(task_id: String, generation: int) -> int:
	_begin_mutation()
	_refresh_internal()
	var cancelled: int = 0
	if generation == _generation and not task_id.is_empty():
		# 没有记录的任务也退役，阻止迟到回调用新 key 复活任务。
		_retired_tasks[task_id] = true
		for request_id: String in _requests:
			var record: Dictionary = _requests[request_id]
			if record["task_id"] == task_id and _is_active(record):
				_finish_request(record, &"cancelled", &"task_cancelled")
				cancelled += 1
		_drain_all_edges()
	_end_mutation()
	return cancelled


func get_generation() -> int:
	return _generation


## 无路等待/拾取时可能还没有申请；显式取消依然使本代身份失效。
func is_transport_identity_valid(owner: Node, task_id: String, generation: int) -> bool:
	return generation == _generation and not task_id.is_empty() \
		and is_instance_valid(owner) \
		and not _cancelled_owners.has(owner.get_instance_id()) \
		and not _exiting_owners.has(owner.get_instance_id()) and not _retired_tasks.has(task_id)


## 付费生长在同一坐标形成实际菌结，原边几何不变；原通行凭证原子交接。
## 普通外部端点编辑不走此接口，仍按永久失效清理。
func handoff_growth_endpoint(edge: HyphaEdge, old_tip: GrowthTip, new_endpoint: HyphaNode) -> bool:
	var network: NetworkSystem = _live_network()
	if network == null or not is_instance_valid(old_tip) or not is_instance_valid(new_endpoint) \
			or not network.is_edge_valid(edge) or edge.end_node != old_tip \
			or not network.is_node_registered(new_endpoint) \
			or old_tip.global_position.distance_to(new_endpoint.global_position) > 0.01:
		return false
	_begin_mutation()
	_refresh_internal()
	var old_id: int = old_tip.get_instance_id()
	var new_id: int = new_endpoint.get_instance_id()
	var edge_id: int = edge.get_instance_id()
	edge.set_meta("growth_handoff_from_id", old_id)
	edge.set_meta("growth_handoff_to_ref", weakref(new_endpoint))
	edge.end_node = new_endpoint
	for request_id: String in _requests:
		var record: Dictionary = _requests[request_id]
		if int(record["edge_id"]) != edge_id or not _is_active(record):
			continue
		record["_edge_end_id"] = new_id
		if int(record["from_id"]) == old_id:
			record["from_node"] = new_endpoint
			record["from_id"] = new_id
		if int(record["to_id"]) == old_id:
			record["to_node"] = new_endpoint
			record["to_id"] = new_id
		record["_revision"] = int(record["_revision"]) + 1
		_queue_notification(record)
	_traffic_dirty = true
	_end_mutation()
	# 通知可以立刻重开/删除；返回的是本次交接已提交，而不是对回调后对象寿命的承诺。
	return true


func get_edge_snapshot(edge: HyphaEdge) -> Dictionary:
	var edge_id: int = _object_id(edge)
	var capacity: int = maxi(0, edge.traffic_capacity) if is_instance_valid(edge) else 0
	var entry_enabled: bool = edge.is_traversable() if is_instance_valid(edge) else false
	var occupied: int = _occupied_units(edge_id)
	var queue: Array[Dictionary] = []
	var leases: Array[Dictionary] = []
	if _queues.has(edge_id):
		for request_id: String in _queues[edge_id]:
			if _requests.has(request_id) and _requests[request_id]["state"] == &"queued":
				queue.append(_request_snapshot(_requests[request_id]))
	if _edge_leases.has(edge_id):
		for token: String in _edge_leases[edge_id]:
			var lease: Dictionary = get_lease(token)
			if not lease.is_empty():
				leases.append(lease)
	return {
		"exists": _is_edge_valid(edge), "edge": _live_reference(edge), "edge_id": edge_id,
		"capacity": capacity, "entry_enabled": entry_enabled, "occupied_units": occupied,
		"available_units": maxi(0, capacity - occupied), "queue": queue, "leases": leases,
	}


func get_snapshot() -> Dictionary:
	var edges: Array[Dictionary] = []
	var network: NetworkSystem = _live_network()
	if network != null:
		for edge: HyphaEdge in network.get_registered_edges():
			edges.append(get_edge_snapshot(edge))
	var queued: int = 0
	var occupied: int = 0
	for request_id: String in _requests:
		var record: Dictionary = _requests[request_id]
		if record["state"] == &"queued":
			queued += 1
		elif record["state"] == &"granted":
			occupied += int(record["units"])
	return {
		"generation": _generation, "occupied_units": occupied, "queued_count": queued,
		"active_lease_count": _leases.size(), "active_request_count": _owner_requests.size(),
		"edges": edges,
	}


## 规划启发式：每个名义过边周期清空上一批；不预测实际进度或未来来包。
func estimate_wait_seconds(edge: HyphaEdge, units: int, speed: float) -> float:
	if not _is_edge_valid(edge) or not edge.is_traversable() or not is_finite(speed) or speed <= 0.0:
		return INF
	var capacity: int = maxi(0, edge.traffic_capacity)
	var length: float = edge.get_length()
	if units <= 0 or units > capacity or not is_finite(length) or length < 0.0:
		return INF
	var sizes: Array[int] = []
	var edge_id: int = edge.get_instance_id()
	if _queues.has(edge_id):
		for request_id: String in _queues[edge_id]:
			if _requests.has(request_id) and _requests[request_id]["state"] == &"queued":
				var queued_units: int = int(_requests[request_id]["units"])
				if queued_units > capacity:
					return INF
				sizes.append(queued_units)
	var available: int = maxi(0, capacity - _occupied_units(edge_id))
	var rounds: int = 0
	sizes.append(units)
	for size: int in sizes:
		if size > available:
			rounds += 1
			available = capacity
		available -= size
	return 0.0 if rounds == 0 else float(rounds) * (length / speed)


func refresh() -> void:
	_begin_mutation()
	_refresh_internal()
	_end_mutation()


func reset() -> void:
	_begin_mutation()
	# reset 本身只增加一次代次，即使依赖也在同一入口被替换。
	_refresh_internal(false)
	_generation += 1
	_clear_records()
	_notifications.clear()
	_traffic_dirty = true
	_end_mutation()


func _object_id(object: Variant) -> int:
	return object.get_instance_id() if is_instance_valid(object) else 0


func _live_reference(object: Variant) -> Variant:
	return object if is_instance_valid(object) else null


func _live_network() -> NetworkSystem:
	if not is_instance_valid(network_system) or network_system.is_queued_for_deletion():
		return null
	if network_system == _bound_network and _network_exited:
		return null
	return network_system


func _is_edge_valid(edge: HyphaEdge) -> bool:
	var network: NetworkSystem = _live_network()
	return network != null and is_instance_valid(edge) and network.is_edge_valid(edge)


func _new_payload(
	request_key: String, owner: Node, task_id: String, edge: HyphaEdge,
	from_node: Node2D, to_node: Node2D, cargo_kind: StringName
) -> Dictionary:
	return {
		"accepted": true, "request_key": request_key, "request_id": "", "generation": _generation,
		"state": &"queued", "reason": &"", "owner": owner, "owner_id": _object_id(owner),
		"task_id": task_id, "edge": edge, "edge_id": _object_id(edge),
		"from_node": from_node, "from_id": _object_id(from_node),
		"to_node": to_node, "to_id": _object_id(to_node), "cargo_kind": cargo_kind,
		"units": units_for_kind(cargo_kind), "sequence": 0, "token": "",
	}


func _same_payload(record: Dictionary, payload: Dictionary) -> bool:
	for field: String in ["owner_id", "task_id", "edge_id", "from_id", "to_id", "cargo_kind", "units"]:
		if record[field] != payload[field]:
			return false
	return true


func _admission_failure(payload: Dictionary) -> StringName:
	if String(payload["request_key"]).is_empty():
		return &"empty_request_key"
	if String(payload["task_id"]).is_empty():
		return &"empty_task_id"
	var owner: Variant = payload["owner"]
	if not is_instance_valid(owner) or owner.is_queued_for_deletion() \
			or _exiting_owners.has(int(payload["owner_id"])):
		return &"invalid_owner"
	if _cancelled_owners.has(int(payload["owner_id"])):
		return &"owner_cancelled"
	if _retired_tasks.has(String(payload["task_id"])):
		return &"task_retired"
	var network: NetworkSystem = _live_network()
	if network == null:
		return &"missing_network"
	var edge: Variant = payload["edge"]
	if not is_instance_valid(edge) or not network.is_edge_valid(edge):
		return &"invalid_edge"
	var from_node: Variant = payload["from_node"]
	var to_node: Variant = payload["to_node"]
	if not is_instance_valid(from_node) or not is_instance_valid(to_node):
		return &"invalid_direction"
	if not network.is_node_registered(from_node) or not network.is_node_registered(to_node) \
			or from_node == to_node or not edge.connects(from_node, to_node):
		return &"invalid_direction"
	var units: int = int(payload["units"])
	if units <= 0:
		return &"unknown_cargo_kind"
	if units > maxi(0, edge.traffic_capacity):
		return &"capacity_exceeded"
	if _owner_requests.has(int(payload["owner_id"])):
		return &"owner_busy"
	return &""


func _request_snapshot(record: Dictionary) -> Dictionary:
	var snapshot: Dictionary = {}
	for field: String in [
		"accepted", "request_key", "request_id", "generation", "state", "reason", "owner_id",
		"task_id", "edge_id", "from_id", "to_id", "cargo_kind", "units", "sequence", "token",
	]:
		snapshot[field] = record[field]
	for field: String in ["owner", "edge", "from_node", "to_node"]:
		snapshot[field] = _live_reference(record[field])
	return snapshot


func _rejected_snapshot(payload: Dictionary, reason: StringName) -> Dictionary:
	var snapshot: Dictionary = _request_snapshot(payload)
	snapshot["accepted"] = false
	snapshot["state"] = &"rejected"
	snapshot["reason"] = reason
	snapshot["request_id"] = ""
	snapshot["token"] = ""
	snapshot["sequence"] = 0
	return snapshot


func _is_active(record: Dictionary) -> bool:
	return record["state"] == &"queued" or record["state"] == &"granted"


func _occupied_units(edge_id: int) -> int:
	var occupied: int = 0
	if _edge_leases.has(edge_id):
		for token: String in _edge_leases[edge_id]:
			if _leases.has(token):
				occupied += int(_requests[_leases[token]]["units"])
	return occupied


func _bind_owner(record: Dictionary) -> void:
	var owner: Node = record["owner"]
	var owner_id: int = int(record["owner_id"])
	var callback: Callable = _on_owner_tree_exiting.bind(owner_id, _generation)
	_owner_bindings[owner_id] = {"owner": owner, "callback": callback}
	owner.tree_exiting.connect(callback)


func _unbind_owner(owner_id: int) -> void:
	if not _owner_bindings.has(owner_id):
		return
	var binding: Dictionary = _owner_bindings[owner_id]
	var owner: Variant = binding["owner"]
	var callback: Callable = binding["callback"]
	if is_instance_valid(owner) and owner.tree_exiting.is_connected(callback):
		owner.tree_exiting.disconnect(callback)
	_owner_bindings.erase(owner_id)


func _finish_request(record: Dictionary, state: StringName, reason: StringName) -> void:
	var request_id: String = record["request_id"]
	var edge_id: int = int(record["edge_id"])
	var owner_id: int = int(record["owner_id"])
	if record["state"] == &"queued" and _queues.has(edge_id):
		_queues[edge_id].erase(request_id)
	var token: String = record["token"]
	if not token.is_empty():
		_leases.erase(token)
		if _edge_leases.has(edge_id):
			_edge_leases[edge_id].erase(token)
	_owner_requests.erase(owner_id)
	_unbind_owner(owner_id)
	record["state"] = state
	record["reason"] = reason
	record["token"] = ""
	record["_revision"] = int(record["_revision"]) + 1
	_queue_notification(record)


func _drain_all_edges() -> void:
	for edge_id: int in _edge_order:
		if not _edge_bindings.has(edge_id) or not _queues.has(edge_id):
			continue
		var edge: Variant = _edge_bindings[edge_id]["edge"]
		if not is_instance_valid(edge) or not _is_edge_valid(edge) or not edge.is_traversable():
			continue
		var available: int = maxi(0, edge.traffic_capacity - _occupied_units(edge_id))
		while not _queues[edge_id].is_empty():
			var request_id: String = _queues[edge_id][0]
			var record: Dictionary = _requests[request_id]
			var units: int = int(record["units"])
			# 大包挡住所有后来者；缩容后不取消已合法排队的大包。
			if units > available:
				break
			_queues[edge_id].pop_front()
			_token_sequence += 1
			var token: String = "lease:%d:%d:%d" % [get_instance_id(), _generation, _token_sequence]
			record["state"] = &"granted"
			record["reason"] = &"granted"
			record["token"] = token
			record["_revision"] = int(record["_revision"]) + 1
			_leases[token] = request_id
			if not _edge_leases.has(edge_id):
				_edge_leases[edge_id] = []
			_edge_leases[edge_id].append(token)
			available -= units
			_queue_notification(record)


func _refresh_internal(increment_replacement_generation: bool = true) -> void:
	if network_system != _bound_network:
		_disconnect_network()
		_disconnect_edges()
		_clear_records()
		_notifications.clear()
		if increment_replacement_generation:
			_generation += 1
		_bound_network = network_system
		_bound_network_id = _object_id(network_system)
		_network_exited = false
		_connect_network()
		_traffic_dirty = true
	for owner_id: int in _exiting_owners.keys():
		var owner: Variant = _exiting_owners[owner_id].get_ref()
		if not is_instance_valid(owner) or not owner.is_inside_tree():
			_exiting_owners.erase(owner_id)
	_sync_edge_bindings()
	for request_id: String in _requests:
		var record: Dictionary = _requests[request_id]
		if not _is_active(record):
			continue
		var reason: StringName = _live_request_failure(record)
		if reason != &"":
			_finish_request(record, &"cancelled", reason)
	_drain_all_edges()


func _live_request_failure(record: Dictionary) -> StringName:
	var owner: Variant = record["owner"]
	if not is_instance_valid(owner) or owner.is_queued_for_deletion() \
			or _exiting_owners.has(int(record["owner_id"])) \
			or (bool(record["_owner_was_inside_tree"]) and not owner.is_inside_tree()):
		return &"owner_removed"
	var network: NetworkSystem = _live_network()
	if network == null:
		return &"network_removed"
	var edge: Variant = record["edge"]
	if not is_instance_valid(edge) or not network.is_edge_valid(edge):
		return &"edge_removed"
	if _object_id(edge.start_node) != int(record["_edge_start_id"]) \
			or _object_id(edge.end_node) != int(record["_edge_end_id"]):
		return &"endpoints_changed"
	return &""


func _connect_network() -> void:
	if not is_instance_valid(_bound_network):
		return
	_network_callbacks = {
		"changed": _on_network_changed.bind(_bound_network_id),
		"exiting": _on_network_tree_exiting.bind(_bound_network_id),
		"entered": _on_network_tree_entered.bind(_bound_network_id),
	}
	_bound_network.network_changed.connect(_network_callbacks["changed"])
	_bound_network.tree_exiting.connect(_network_callbacks["exiting"])
	_bound_network.tree_entered.connect(_network_callbacks["entered"])


func _disconnect_network() -> void:
	if is_instance_valid(_bound_network) and not _network_callbacks.is_empty():
		for field: String in _network_callbacks:
			var callback: Callable = _network_callbacks[field]
			var source: Signal = _bound_network.network_changed
			if field == "exiting":
				source = _bound_network.tree_exiting
			elif field == "entered":
				source = _bound_network.tree_entered
			if source.is_connected(callback):
				source.disconnect(callback)
	_network_callbacks.clear()


func _sync_edge_bindings() -> void:
	var edges: Array[HyphaEdge] = []
	var network: NetworkSystem = _live_network()
	if network != null:
		edges = network.get_registered_edges()
	var new_order: Array[int] = []
	for edge: HyphaEdge in edges:
		var edge_id: int = edge.get_instance_id()
		new_order.append(edge_id)
		var settings: Dictionary = {
			"capacity": maxi(0, edge.traffic_capacity), "entry_enabled": edge.is_traversable(),
			"start_id": _object_id(edge.start_node), "end_id": _object_id(edge.end_node),
		}
		if not _edge_bindings.has(edge_id):
			var settings_callback: Callable = _on_edge_settings_changed.bind(edge_id, _bound_network_id)
			var exit_callback: Callable = _on_edge_tree_exiting.bind(edge_id, _bound_network_id)
			_edge_bindings[edge_id] = {
				"edge": edge, "settings_callback": settings_callback,
				"exit_callback": exit_callback, "settings": settings,
			}
			edge.traffic_settings_changed.connect(settings_callback)
			edge.tree_exiting.connect(exit_callback)
			_traffic_dirty = true
		elif _edge_bindings[edge_id]["settings"] != settings:
			_edge_bindings[edge_id]["settings"] = settings
			_traffic_dirty = true
	for edge_id: int in _edge_bindings.keys():
		if not new_order.has(edge_id):
			_disconnect_edge(edge_id)
			_traffic_dirty = true
	if new_order != _edge_order:
		_traffic_dirty = true
	_edge_order = new_order


func _disconnect_edge(edge_id: int) -> void:
	if not _edge_bindings.has(edge_id):
		return
	var binding: Dictionary = _edge_bindings[edge_id]
	var edge: Variant = binding["edge"]
	if is_instance_valid(edge):
		var settings_callback: Callable = binding["settings_callback"]
		var exit_callback: Callable = binding["exit_callback"]
		if edge.traffic_settings_changed.is_connected(settings_callback):
			edge.traffic_settings_changed.disconnect(settings_callback)
		if edge.tree_exiting.is_connected(exit_callback):
			edge.tree_exiting.disconnect(exit_callback)
	_edge_bindings.erase(edge_id)


func _disconnect_edges() -> void:
	for edge_id: int in _edge_bindings.keys():
		_disconnect_edge(edge_id)
	_edge_order.clear()


func _clear_records() -> void:
	for owner_id: int in _owner_bindings.keys():
		_unbind_owner(owner_id)
	_requests.clear()
	_request_keys.clear()
	_owner_requests.clear()
	_queues.clear()
	_leases.clear()
	_edge_leases.clear()
	_retired_tasks.clear()
	_cancelled_owners.clear()
	# 退出信号尚在栈上时，reset/替换依赖也不能抹掉 owner 的退出屏障。
	# 下一次 refresh 在该对象确实离树后才移除屏障，允许合法的树外 owner。


func _begin_mutation() -> void:
	_mutation_depth += 1


func _end_mutation() -> void:
	_mutation_depth -= 1
	if _mutation_depth == 0:
		_flush_notifications()


func _queue_notification(record: Dictionary) -> void:
	_notifications.append({
		"request_id": record["request_id"], "generation": _generation,
		"revision": record["_revision"],
	})
	_traffic_dirty = true


func _flush_notifications() -> void:
	if _notifying:
		return
	_notifying = true
	while not _notifications.is_empty() or _traffic_dirty:
		if not _notifications.is_empty():
			var notification: Dictionary = _notifications.pop_front()
			var request_id: String = notification["request_id"]
			if int(notification["generation"]) != _generation or not _requests.has(request_id):
				continue
			var record: Dictionary = _requests[request_id]
			if int(notification["revision"]) != int(record["_revision"]):
				continue
			request_changed.emit(_request_snapshot(record))
		else:
			_traffic_dirty = false
			traffic_changed.emit()
	_notifying = false
