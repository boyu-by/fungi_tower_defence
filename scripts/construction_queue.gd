class_name ConstructionQueue
extends Node
## 保存外部建设意图；排序只交换身份，不移动已开始的施工或任何营养。

signal changed(snapshot: Dictionary)

const MAX_SERIAL: int = 9223372036854775807
const KINDS: Array[StringName] = [&"growth", &"remote_cultivation", &"connection"]
const TERMINAL_STATES: Array[StringName] = [&"completed", &"cancelled", &"failed"]

@export var capabilities: ColonyCapabilities
var multi_execution: bool = false

var _requests: Dictionary[String, Dictionary] = {}
var _entry_ids: Array[String] = []
var _maturing_ids: Array[String] = []
var _active_ids: Array[String] = []
var _selected_id: String = ""
var _active_id: String = ""
var _serial: int = 0
var _generation: int = 0
var _emitting_changed: bool = false
var _changed_pending: bool = false


func enqueue(kind: StringName, parameters: Dictionary, payer: MotherCore) -> Dictionary:
	if not KINDS.has(kind):
		return _enqueue_result(false, "", &"invalid_kind")
	if not _parameters_have_shape(kind, parameters):
		return _enqueue_result(false, "", &"invalid_parameters")
	var duplicate_id: String = _find_duplicate(kind, parameters)
	if not duplicate_id.is_empty():
		_selected_id = duplicate_id
		_publish_changed()
		return _enqueue_result(false, duplicate_id, &"duplicate")
	if _entry_ids.size() >= _get_limit():
		return _enqueue_result(false, "", &"queue_full")
	if not _node_is_available(payer):
		return _enqueue_result(false, "", &"core_unavailable")
	if _serial == MAX_SERIAL:
		return _enqueue_result(false, "", &"id_exhausted")
	_serial += 1
	var construction_id: String = "construction:%d:%d" % [get_instance_id(), _serial]
	_requests[construction_id] = {
		"construction_id": construction_id,
		"sequence": _serial,
		"kind": kind,
		"parameters": parameters.duplicate(true),
		"payer": payer,
		"payer_id": payer.get_instance_id(),
		"state": &"waiting",
		"wait_reason": &"queued",
		"started": false,
		"internal_ids": _empty_internal_ids(),
		"detail": {},
		"worker_id": 0, "phase": &"queued",
		"occupies_external_slot": true, "occupies_tip_slot": false,
	}
	_entry_ids.append(construction_id)
	_selected_id = construction_id
	_publish_changed()
	return _enqueue_result(true, construction_id, &"")


func get_snapshot() -> Dictionary:
	var entries: Array[Dictionary] = []
	var maturing: Array[Dictionary] = []
	var waiting_count: int = 0
	for construction_id: String in _entry_ids:
		entries.append(_requests[construction_id].duplicate(true))
		if not bool(_requests[construction_id]["started"]):
			waiting_count += 1
	for construction_id: String in _maturing_ids:
		maturing.append(_requests[construction_id].duplicate(true))
	return {
		"entries": entries,
		"maturing": maturing, "active_ids": _active_ids.duplicate(),
		"tip_count": _active_ids.size(), "tip_limit": _get_tip_limit(),
		"external_count": entries.size(), "waiting_count": waiting_count,
		"maturing_count": maturing.size(),
		"selected_id": _selected_id,
		"active_id": _active_id,
		"limit": _get_limit(),
		"generation": _generation,
	}


func get_all_requests() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for request: Dictionary in _requests.values():
		result.append(request.duplicate(true))
	return result


func get_active_requests() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for construction_id: String in _entry_ids + _maturing_ids:
		result.append(_requests[construction_id].duplicate(true))
	return result


func get_request(construction_id: String) -> Dictionary:
	if not _requests.has(construction_id):
		return {}
	return _requests[construction_id].duplicate(true)


func get_generation() -> int:
	return _generation


func select_request(construction_id: String) -> bool:
	if construction_id.is_empty():
		if not _selected_id.is_empty():
			_selected_id = ""
			_publish_changed()
		return true
	if not _entry_ids.has(construction_id) and not _maturing_ids.has(construction_id):
		return false
	if _selected_id != construction_id:
		_selected_id = construction_id
		_publish_changed()
	return true


func move_request(construction_id: String, direction: int) -> bool:
	if direction != -1 and direction != 1:
		return false
	if not _entry_ids.has(construction_id) or not _is_pending(construction_id):
		return false
	var index: int = _entry_ids.find(construction_id)
	var destination: int = index + direction
	if destination < 0 or destination >= _entry_ids.size() \
			or not _is_pending(_entry_ids[destination]):
		return false
	var other_id: String = _entry_ids[destination]
	_entry_ids[destination] = construction_id
	_entry_ids[index] = other_id
	_publish_changed()
	return true


func pause_request(construction_id: String) -> bool:
	if not _is_pending(construction_id) or _requests[construction_id]["state"] != &"waiting":
		return false
	_requests[construction_id]["state"] = &"paused"
	_requests[construction_id]["wait_reason"] = &"paused"
	_publish_changed()
	return true


func resume_request(construction_id: String) -> bool:
	if not _is_pending(construction_id) or _requests[construction_id]["state"] != &"paused":
		return false
	_requests[construction_id]["state"] = &"waiting"
	_requests[construction_id]["wait_reason"] = &"queued"
	_publish_changed()
	return true


func cancel_request(construction_id: String) -> bool:
	if not _is_pending(construction_id):
		return false
	return _coordinator_finish(construction_id, _generation, &"cancelled", &"", {})


func reset() -> void:
	var generation: int = _invalidate_generation()
	_clear_generation(generation)


## 协调器先废弃代次，再使用仍存活的原供养来源取消施工，最后清空记录。
func _invalidate_generation() -> int:
	_generation += 1
	return _generation


func _clear_generation(generation: int) -> void:
	if generation != _generation:
		return
	_requests.clear()
	_entry_ids.clear()
	_maturing_ids.clear()
	_active_ids.clear()
	_selected_id = ""
	_active_id = ""
	_publish_changed()


func _coordinator_start(construction_id: String, generation: int) -> bool:
	if generation != _generation or _active_ids.size() >= _get_tip_limit() \
			or not _entry_ids.has(construction_id) \
			or not _is_pending(construction_id) or _requests[construction_id]["state"] != &"waiting":
		return false
	_active_ids.append(construction_id)
	_sync_active_id()
	_requests[construction_id]["started"] = true
	_requests[construction_id]["state"] = &"executing"
	_requests[construction_id]["wait_reason"] = &""
	_requests[construction_id]["phase"] = &"extension"
	_requests[construction_id]["occupies_tip_slot"] = true
	_publish_changed()
	return generation == _generation and _active_ids.has(construction_id)


## 初始通知中出现临时断路/就地培育时，尚未调用原入口的行可安全回到等待。
func _coordinator_unstart(
	construction_id: String, generation: int, wait_reason: StringName, detail: Dictionary
) -> bool:
	if generation != _generation or not _active_ids.has(construction_id) \
			or not _entry_ids.has(construction_id):
		return false
	var request: Dictionary = _requests[construction_id]
	if request["internal_ids"] != _empty_internal_ids():
		return false
	request["started"] = false
	request["state"] = &"waiting"
	request["wait_reason"] = wait_reason
	request["detail"] = detail.duplicate(true)
	request["phase"] = &"queued"
	request["worker_id"] = 0
	request["occupies_tip_slot"] = false
	_active_ids.erase(construction_id)
	_sync_active_id()
	_publish_changed()
	return true


func _coordinator_update(
	construction_id: String, generation: int, state: StringName, wait_reason: StringName,
	internal_ids: Dictionary, detail: Dictionary
) -> bool:
	if generation != _generation or not (_entry_ids.has(construction_id) or _maturing_ids.has(construction_id)) \
			or not [&"waiting", &"executing", &"paused", &"maturing"].has(state):
		return false
	var request: Dictionary = _requests[construction_id]
	if bool(request["started"]) and not (_active_ids.has(construction_id) or _maturing_ids.has(construction_id)):
		return false
	var ids: Dictionary = request["internal_ids"].duplicate()
	for key: String in ids:
		var next_id: int = int(internal_ids.get(key, ids[key]))
		if next_id < 0 or (int(ids[key]) > 0 and next_id != int(ids[key])):
			return false
		ids[key] = next_id
	var copied_detail: Dictionary = detail.duplicate(true)
	var reason: StringName = &"paused" if state == &"paused" else wait_reason
	var did_change: bool = request["state"] != state or request["wait_reason"] != reason \
		or request["internal_ids"] != ids or request["detail"] != copied_detail
	request["state"] = state
	request["wait_reason"] = reason
	request["internal_ids"] = ids
	request["detail"] = copied_detail
	if did_change:
		_publish_changed()
	return generation == _generation and (_entry_ids.has(construction_id) or _maturing_ids.has(construction_id))


func _coordinator_finish(
	construction_id: String, generation: int, state: StringName, wait_reason: StringName,
	detail: Dictionary, internal_ids: Dictionary = {}
) -> bool:
	if generation != _generation or not (_entry_ids.has(construction_id) or _maturing_ids.has(construction_id)) \
			or not TERMINAL_STATES.has(state):
		return false
	var request: Dictionary = _requests[construction_id]
	var ids: Dictionary = request["internal_ids"].duplicate()
	for key: String in ids:
		var next_id: int = int(internal_ids.get(key, ids[key]))
		if next_id < 0 or (int(ids[key]) > 0 and next_id != int(ids[key])):
			return false
		ids[key] = next_id
	request["state"] = state
	request["wait_reason"] = wait_reason
	request["internal_ids"] = ids
	request["detail"] = detail.duplicate(true)
	request["phase"] = &"terminal"
	request["occupies_external_slot"] = false
	request["occupies_tip_slot"] = false
	_entry_ids.erase(construction_id)
	_maturing_ids.erase(construction_id)
	_active_ids.erase(construction_id)
	if _selected_id == construction_id:
		_selected_id = ""
	_sync_active_id()
	_publish_changed()
	return true


func _find_duplicate(kind: StringName, parameters: Dictionary) -> String:
	if not _parameters_have_shape(kind, parameters):
		return ""
	for construction_id: String in _entry_ids:
		var request: Dictionary = _requests[construction_id]
		if request["kind"] != kind:
			continue
		var saved: Dictionary = request["parameters"]
		if kind == &"connection":
			if (saved["first_node"] == parameters["first_node"] \
					and saved["second_node"] == parameters["second_node"]) \
					or (saved["first_node"] == parameters["second_node"] \
					and saved["second_node"] == parameters["first_node"]):
				return construction_id
		elif saved["start_node"] == parameters["start_node"]:
			var saved_position: Vector2 = saved["target_position"]
			if saved_position.distance_to(parameters["target_position"]) <= 1.0:
				return construction_id
	return ""


func _parameters_have_shape(kind: StringName, parameters: Dictionary) -> bool:
	if kind == &"connection":
		return parameters.has("first_node") and parameters.has("second_node") \
			and _node_is_available(parameters["first_node"]) and parameters["first_node"] is HyphaNode \
			and _node_is_available(parameters["second_node"]) and parameters["second_node"] is HyphaNode
	if kind == &"growth" or kind == &"remote_cultivation":
		return parameters.has("start_node") and parameters.has("target_position") \
			and _node_is_available(parameters["start_node"]) and parameters["start_node"] is Node2D \
			and parameters["target_position"] is Vector2
	return false


func _is_pending(construction_id: String) -> bool:
	return (_entry_ids.has(construction_id) or _maturing_ids.has(construction_id)) \
		and not bool(_requests[construction_id]["started"]) \
		and [&"waiting", &"paused"].has(_requests[construction_id]["state"])


func _get_limit() -> int:
	return capabilities.get_external_target_limit() if _node_is_available(capabilities) else 3


func _get_tip_limit() -> int:
	return clampi(capabilities.get_extension_tip_limit(), 1, 2) \
		if multi_execution and _node_is_available(capabilities) else 1


func _sync_active_id() -> void:
	_active_id = _active_ids[0] if not _active_ids.is_empty() else ""


func _coordinator_bind_worker(construction_id: String, generation: int, worker_id: int) -> bool:
	if generation != _generation or worker_id <= 0 \
			or not (_entry_ids.has(construction_id) or _maturing_ids.has(construction_id)):
		return false
	var request: Dictionary = _requests[construction_id]
	if int(request["worker_id"]) != 0 and int(request["worker_id"]) != worker_id:
		return false
	request["worker_id"] = worker_id
	_publish_changed()
	return generation == _generation and _requests.has(construction_id)


func _coordinator_release_tip(construction_id: String, generation: int,
		detail: Dictionary, internal_ids: Dictionary) -> bool:
	if not multi_execution or generation != _generation or not _requests.has(construction_id):
		return false
	if _maturing_ids.has(construction_id):
		return true
	var request: Dictionary = _requests[construction_id]
	if request["kind"] != &"remote_cultivation" or not _active_ids.has(construction_id) \
			or not _entry_ids.has(construction_id):
		return false
	var ids: Dictionary = request["internal_ids"].duplicate()
	for key: String in ids:
		var next_id: int = int(internal_ids.get(key, ids[key]))
		if next_id <= 0 or (int(ids[key]) > 0 and next_id != int(ids[key])):
			return false
		ids[key] = next_id
	request["internal_ids"] = ids
	request["detail"] = detail.duplicate(true)
	request["phase"] = &"maturing"
	request["state"] = &"paused" if request["state"] == &"paused" else &"maturing"
	request["occupies_external_slot"] = false
	request["occupies_tip_slot"] = false
	_entry_ids.erase(construction_id)
	_active_ids.erase(construction_id)
	_maturing_ids.append(construction_id)
	_sync_active_id()
	_publish_changed()
	return generation == _generation and _maturing_ids.has(construction_id)


func _coordinator_enqueue_cultivation(host: HyphaNode, payer: MotherCore) -> Dictionary:
	if not multi_execution or not _node_is_available(host) or not _node_is_available(payer):
		return _enqueue_result(false, "", &"invalid_configuration")
	for request: Dictionary in get_active_requests():
		if request["parameters"].get("host") == host or request["detail"].get("endpoint") == host:
			select_request(String(request["construction_id"]))
			return _enqueue_result(false, String(request["construction_id"]), &"duplicate")
	if _serial == MAX_SERIAL:
		return _enqueue_result(false, "", &"id_exhausted")
	_serial += 1
	var construction_id: String = "construction:%d:%d" % [get_instance_id(), _serial]
	_requests[construction_id] = {
		"construction_id": construction_id, "sequence": _serial, "kind": &"cultivation",
		"parameters": {"host": host}, "payer": payer, "payer_id": payer.get_instance_id(),
		"state": &"waiting", "wait_reason": &"queued", "started": false,
		"internal_ids": _empty_internal_ids(), "detail": {}, "worker_id": 0,
		"phase": &"maturing", "occupies_external_slot": false, "occupies_tip_slot": false,
	}
	_maturing_ids.append(construction_id)
	_selected_id = construction_id
	_publish_changed()
	return _enqueue_result(true, construction_id, &"")


func _coordinator_start_local(construction_id: String, generation: int) -> bool:
	if not multi_execution or generation != _generation or not _maturing_ids.has(construction_id) \
			or not _is_pending(construction_id) or _requests[construction_id]["state"] != &"waiting":
		return false
	_requests[construction_id]["started"] = true
	_requests[construction_id]["state"] = &"maturing"
	_requests[construction_id]["wait_reason"] = &"nutrition"
	_publish_changed()
	return generation == _generation and _maturing_ids.has(construction_id)


func _empty_internal_ids() -> Dictionary:
	return {"growth_task_id": 0, "remote_request_id": 0, "cultivation_task_id": 0}


func _enqueue_result(accepted: bool, construction_id: String, reason: StringName) -> Dictionary:
	return {"accepted": accepted, "construction_id": construction_id, "reason": reason}


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _publish_changed() -> void:
	_changed_pending = true
	if _emitting_changed:
		return
	_emitting_changed = true
	while _changed_pending:
		_changed_pending = false
		changed.emit(get_snapshot())
	_emitting_changed = false
