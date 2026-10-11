class_name CargoPassageTracker
extends Node
## 实际过边先留下候选；业务接受或不可退还的消耗再封存并发布确认。

signal passage_confirmed(cargo_id: String, edge: HyphaEdge, generation: int)

var _generation: int = 1
var _cargos: Dictionary[String, Dictionary] = {}
var _notifications: Array[Dictionary] = []
var _notifying: bool = false
var _exiting: bool = false


func _enter_tree() -> void:
	_exiting = false


func _exit_tree() -> void:
	_exiting = true
	reset()


func get_generation() -> int:
	return _generation


func register_cargo(cargo_id: String, kind: StringName = &"") -> int:
	if not _can_mutate() or cargo_id.strip_edges().is_empty():
		return -1
	if _cargos.has(cargo_id):
		var existing: Dictionary = _cargos[cargo_id]
		if existing["kind"] != kind or existing["status"] == &"discarded":
			return -1
		return int(existing["generation"])
	var candidates: Dictionary[int, WeakRef] = {}
	var confirmed: Dictionary[int, WeakRef] = {}
	_cargos[cargo_id] = {
		"cargo_id": cargo_id, "kind": kind, "generation": _generation,
		"status": &"pending", "candidates": candidates, "confirmed": confirmed,
	}
	return _generation


## 只由运输包的完整非零路段完成分支调用；许可和释放不构成通行。
func record_candidate(cargo_id: String, edge: HyphaEdge, generation: int) -> bool:
	if not _is_pending(cargo_id, generation) or not _edge_has_candidate_geometry(edge):
		return false
	var candidates: Dictionary[int, WeakRef] = _cargos[cargo_id]["candidates"]
	var edge_id: int = edge.get_instance_id()
	if candidates.has(edge_id):
		return false
	candidates[edge_id] = weakref(edge)
	return true


## 所有有效候选先同时确认，再通知；已封存的身份永远不重新收集边。
func confirm_cargo(cargo_id: String, generation: int) -> bool:
	if not _is_pending(cargo_id, generation):
		return false
	var record: Dictionary = _cargos[cargo_id]
	var candidates: Dictionary[int, WeakRef] = record["candidates"]
	var confirmed: Dictionary[int, WeakRef] = record["confirmed"]
	record["status"] = &"confirmed"
	for edge_id: int in candidates:
		if _live_edge(candidates[edge_id], edge_id) == null:
			continue
		confirmed[edge_id] = candidates[edge_id]
		_notifications.append({
			"cargo_id": cargo_id, "edge_id": edge_id, "generation": generation,
		})
	_flush_notifications()
	return true


func discard_cargo(cargo_id: String, generation: int) -> bool:
	if not _is_pending(cargo_id, generation):
		return false
	var record: Dictionary = _cargos[cargo_id]
	record["status"] = &"discarded"
	var candidates: Dictionary[int, WeakRef] = record["candidates"]
	candidates.clear()
	return true


func has_confirmed_passage(cargo_id: String, edge: HyphaEdge, generation: int) -> bool:
	if generation != _generation or not _cargos.has(cargo_id) or not _edge_is_live(edge):
		return false
	var record: Dictionary = _cargos[cargo_id]
	if record["status"] != &"confirmed" or int(record["generation"]) != generation:
		return false
	var confirmed: Dictionary[int, WeakRef] = record["confirmed"]
	var edge_id: int = edge.get_instance_id()
	return confirmed.has(edge_id) and _live_edge(confirmed[edge_id], edge_id) == edge


func get_cargo_snapshot(cargo_id: String) -> Dictionary:
	if not _cargos.has(cargo_id):
		return {}
	return _cargo_snapshot(_cargos[cargo_id])


func get_confirmed_passages() -> Array[Dictionary]:
	var passages: Array[Dictionary] = []
	for cargo_id: String in _cargos:
		var record: Dictionary = _cargos[cargo_id]
		if record["status"] != &"confirmed":
			continue
		var confirmed: Dictionary[int, WeakRef] = record["confirmed"]
		for edge_id: int in confirmed:
			var edge: HyphaEdge = _live_edge(confirmed[edge_id], edge_id)
			if edge != null:
				passages.append({
					"cargo_id": cargo_id, "edge_id": edge_id,
					"edge_ref": weakref(edge), "generation": int(record["generation"]),
				})
	return passages


func get_snapshot() -> Dictionary:
	var cargos: Array[Dictionary] = []
	var pending_count: int = 0
	var confirmed_count: int = 0
	var discarded_count: int = 0
	var candidate_passage_count: int = 0
	var confirmed_passage_count: int = 0
	for cargo_id: String in _cargos:
		var snapshot: Dictionary = _cargo_snapshot(_cargos[cargo_id])
		cargos.append(snapshot)
		candidate_passage_count += int(snapshot["candidate_count"])
		confirmed_passage_count += int(snapshot["confirmed_count"])
		match StringName(snapshot["status"]):
			&"pending": pending_count += 1
			&"confirmed": confirmed_count += 1
			&"discarded": discarded_count += 1
	return {
		"generation": _generation, "cargo_count": _cargos.size(),
		"pending_count": pending_count, "confirmed_count": confirmed_count,
		"discarded_count": discarded_count, "candidate_passage_count": candidate_passage_count,
		"confirmed_passage_count": confirmed_passage_count, "cargos": cargos,
	}


func reset() -> void:
	# 先废弃旧代次及尚未发出的确认，回调中的 reset 也不能继续发布旧历史。
	_generation += 1
	_notifications.clear()
	_cargos.clear()


func _can_mutate() -> bool:
	return not _exiting and not is_queued_for_deletion()


func _is_pending(cargo_id: String, generation: int) -> bool:
	if not _can_mutate() or generation != _generation or not _cargos.has(cargo_id):
		return false
	var record: Dictionary = _cargos[cargo_id]
	return int(record["generation"]) == generation and record["status"] == &"pending"


func _edge_is_live(edge: HyphaEdge) -> bool:
	return is_instance_valid(edge) and not edge.is_queued_for_deletion()


## 只在创建候选时检验几何；后续断开端点不会撤销当时真实完成的通行。
func _edge_has_candidate_geometry(edge: HyphaEdge) -> bool:
	if not _edge_is_live(edge) or not edge.has_endpoints() \
			or edge.start_node.is_queued_for_deletion() or edge.end_node.is_queued_for_deletion():
		return false
	var length: float = edge.get_length()
	return is_finite(length) and length > 0.0


func _live_edge(reference: WeakRef, edge_id: int) -> HyphaEdge:
	var edge: HyphaEdge = reference.get_ref() as HyphaEdge
	return edge if _edge_is_live(edge) and edge.get_instance_id() == edge_id else null


func _live_edge_ids(references: Dictionary[int, WeakRef]) -> Array[int]:
	var edge_ids: Array[int] = []
	for edge_id: int in references:
		if _live_edge(references[edge_id], edge_id) != null:
			edge_ids.append(edge_id)
	return edge_ids


func _cargo_snapshot(record: Dictionary) -> Dictionary:
	var candidates: Dictionary[int, WeakRef] = record["candidates"]
	var confirmed: Dictionary[int, WeakRef] = record["confirmed"]
	var candidate_ids: Array[int] = _live_edge_ids(candidates)
	var confirmed_ids: Array[int] = _live_edge_ids(confirmed)
	return {
		"cargo_id": String(record["cargo_id"]), "kind": StringName(record["kind"]),
		"generation": int(record["generation"]), "status": StringName(record["status"]),
		"candidate_edge_ids": candidate_ids, "confirmed_edge_ids": confirmed_ids,
		"candidate_count": candidate_ids.size(), "confirmed_count": confirmed_ids.size(),
	}


func _flush_notifications() -> void:
	if _notifying or not _can_mutate():
		return
	_notifying = true
	while not _notifications.is_empty():
		if not _can_mutate():
			_notifications.clear()
			break
		var notification: Dictionary = _notifications.pop_front()
		var cargo_id: String = notification["cargo_id"]
		var generation: int = int(notification["generation"])
		var edge_id: int = int(notification["edge_id"])
		if generation != _generation or not _cargos.has(cargo_id):
			continue
		var record: Dictionary = _cargos[cargo_id]
		var confirmed: Dictionary[int, WeakRef] = record["confirmed"]
		if record["status"] != &"confirmed" or not confirmed.has(edge_id):
			continue
		var edge: HyphaEdge = _live_edge(confirmed[edge_id], edge_id)
		if edge == null:
			continue
		passage_confirmed.emit(cargo_id, edge, generation)
		if not is_instance_valid(self):
			return
	_notifying = false
