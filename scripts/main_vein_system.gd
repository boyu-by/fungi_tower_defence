class_name MainVeinSystem
extends Node

## 仅消费运输候选经过业务结算后的确认；不移动货物或操作营养账本。
## 历史只保存弱边引用，货物身份在来源与代次内按每条边去重。
signal edge_progress_changed(edge: HyphaEdge, snapshot: Dictionary)
signal edge_upgraded(edge: HyphaEdge, previous_grade: int, current_grade: int)

enum Grade { BASIC = 0, DEVELOPED = 1, MATURE = 2 }

@export var cargo_passage_tracker: CargoPassageTracker
@export var enabled: bool = true

var _generation: int = 1
var _stopped: bool = false
var _resetting: bool = false
var _edges: Dictionary[int, Dictionary] = {}
var _tracker_ref: WeakRef = null
var _tracker_id: int = 0
var _tracker_callback: Callable
var _mutation_depth: int = 0
var _notifying: bool = false
var _notifications: Array[Dictionary] = []


func _ready() -> void:
	configure_tracker(cargo_passage_tracker)


func _exit_tree() -> void:
	stop()
	_disconnect_tracker()


func _on_passage_confirmed(
	cargo_id: String, edge: HyphaEdge, cargo_generation: int,
	source_id: int, binding_generation: int
) -> void:
	_begin_mutation()
	_consume_confirmation(cargo_id, edge, cargo_generation, source_id, binding_generation)
	if not is_instance_valid(self):
		return
	_end_mutation()


## 重绑不重开旧货物；回放与同步通知使用同一权威校验和去重路径。
func configure_tracker(value: CargoPassageTracker) -> void:
	_disconnect_tracker()
	_generation += 1
	_notifications.clear()
	cargo_passage_tracker = value
	if not is_instance_valid(value) or value.is_queued_for_deletion():
		return
	_tracker_ref = weakref(value)
	_tracker_id = value.get_instance_id()
	var binding_generation: int = _generation
	var source_id: int = _tracker_id
	_tracker_callback = _on_passage_confirmed.bind(source_id, binding_generation)
	value.passage_confirmed.connect(_tracker_callback)
	_begin_mutation()
	var passages: Array[Dictionary] = value.get_confirmed_passages()
	for passage: Dictionary in passages:
		var edge_reference: WeakRef = passage.get("edge_ref") as WeakRef
		var edge: HyphaEdge = _edge_from_ref(edge_reference)
		_consume_confirmation(
			String(passage.get("cargo_id", "")), edge, int(passage.get("generation", -1)),
			source_id, binding_generation
		)
		if not is_instance_valid(self):
			return
	_end_mutation()


func register_edge(edge: HyphaEdge) -> bool:
	if not _is_live_edge(edge):
		return false
	var edge_id: int = edge.get_instance_id()
	if _edges.has(edge_id) and _edge_from_record(_edges[edge_id]) == edge:
		return true
	_begin_mutation()
	_edges[edge_id] = _new_edge_record(edge)
	if enabled:
		edge.apply_vein_growth(Grade.BASIC, 0)
	if not is_instance_valid(self):
		return true
	_end_mutation()
	return true


func get_edge_snapshot(edge: HyphaEdge) -> Dictionary:
	if not _is_live_edge(edge) or not _edges.has(edge.get_instance_id()) \
			or _edge_from_record(_edges[edge.get_instance_id()]) != edge:
		return {}
	return edge.get_vein_snapshot()


func get_snapshot() -> Dictionary:
	var snapshots: Array[Dictionary] = []
	var edge_ids: Array = _edges.keys()
	edge_ids.sort()
	for edge_id: int in edge_ids:
		var edge: HyphaEdge = _edge_from_record(_edges[edge_id])
		if edge != null:
			snapshots.append(edge.get_vein_snapshot())
	return {
		"enabled": enabled,
		"stopped": _stopped,
		"generation": _generation,
		"edges": snapshots,
	}


func stop() -> void:
	_stopped = true
	_generation += 1
	_notifications.clear()


## 调用方已先清空交通和业务任务；重置能力只截断血量，不赠送恢复。
func reset() -> void:
	if _resetting:
		return
	_resetting = true
	_stopped = true
	_generation += 1
	var reset_generation: int = _generation
	_notifications.clear()
	var tracker: CargoPassageTracker = _live_tracker()
	_disconnect_tracker()
	if tracker != null:
		tracker.reset()
	for edge_id: int in _edges:
		var record: Dictionary = _edges[edge_id]
		record["grade"] = Grade.BASIC
		record["confirmed_passages"] = 0
		record["receipts"] = {}
	# 信号回调可以登记新边；只遍历本次开始时的身份副本。
	for edge_id: int in _edges.keys():
		var edge: HyphaEdge = _edge_from_record(_edges[edge_id])
		if edge != null:
			edge.apply_vein_growth(Grade.BASIC, 0)
			if not is_instance_valid(self):
				return
	_resetting = false
	if _generation == reset_generation:
		_stopped = false
		configure_tracker(cargo_passage_tracker)


func _consume_confirmation(
	cargo_id: String, edge: HyphaEdge, cargo_generation: int,
	source_id: int, binding_generation: int
) -> void:
	if not _is_current_source(source_id, binding_generation) or not _is_live_edge(edge):
		return
	var tracker: CargoPassageTracker = _live_tracker()
	if tracker == null or not tracker.has_confirmed_passage(cargo_id, edge, cargo_generation):
		return
	var edge_id: int = edge.get_instance_id()
	if not _edges.has(edge_id):
		_edges[edge_id] = _new_edge_record(edge)
	var record: Dictionary = _edges[edge_id]
	var receipts: Dictionary = record["receipts"]
	var receipt_key: String = "%d:%d:%s" % [source_id, cargo_generation, cargo_id]
	if receipts.has(receipt_key):
		return
	var previous_grade: int = int(record["grade"])
	var count: int = int(record["confirmed_passages"]) + 1
	var current_grade: int = _grade_for_count(count)
	# 去重、计数和通知身份都先提交，边的 health_changed 可同步重入。
	receipts[receipt_key] = true
	record["confirmed_passages"] = count
	record["grade"] = current_grade
	_notifications.append({
		"generation": binding_generation,
		"source_id": source_id,
		"cargo_generation": cargo_generation,
		"cargo_id": cargo_id,
		"receipt_key": receipt_key,
		"edge_id": edge_id,
		"previous_grade": previous_grade,
		"current_grade": current_grade,
	})
	edge.apply_vein_growth(current_grade, count)


func _grade_for_count(count: int) -> int:
	if count >= HyphaEdge.VEIN_THRESHOLDS[1]:
		return Grade.MATURE
	if count >= HyphaEdge.VEIN_THRESHOLDS[0]:
		return Grade.DEVELOPED
	return Grade.BASIC


func _new_edge_record(edge: HyphaEdge) -> Dictionary:
	return {
		"edge_ref": weakref(edge),
		"grade": Grade.BASIC,
		"confirmed_passages": 0,
		"receipts": {},
	}


func _is_live_edge(edge: HyphaEdge) -> bool:
	return is_instance_valid(edge) and not edge.is_queued_for_deletion() \
		and edge.has_endpoints() and not edge.start_node.is_queued_for_deletion() \
		and not edge.end_node.is_queued_for_deletion()


func _edge_from_ref(reference: WeakRef) -> HyphaEdge:
	var edge: HyphaEdge = reference.get_ref() as HyphaEdge if reference != null else null
	return edge if _is_live_edge(edge) else null


func _edge_from_record(record: Dictionary) -> HyphaEdge:
	return _edge_from_ref(record.get("edge_ref") as WeakRef)


func _live_tracker() -> CargoPassageTracker:
	var tracker: CargoPassageTracker = _tracker_ref.get_ref() as CargoPassageTracker \
		if _tracker_ref != null else null
	return tracker if is_instance_valid(tracker) and not tracker.is_queued_for_deletion() else null


func _is_current_source(source_id: int, binding_generation: int) -> bool:
	return enabled and not _stopped and not _resetting \
		and binding_generation == _generation and source_id == _tracker_id \
		and _live_tracker() != null


func _disconnect_tracker() -> void:
	var tracker: CargoPassageTracker = _live_tracker()
	if tracker != null and _tracker_callback.is_valid() \
			and tracker.passage_confirmed.is_connected(_tracker_callback):
		tracker.passage_confirmed.disconnect(_tracker_callback)
	_tracker_ref = null
	_tracker_id = 0
	_tracker_callback = Callable()


func _begin_mutation() -> void:
	_mutation_depth += 1


func _end_mutation() -> void:
	_mutation_depth -= 1
	if _mutation_depth == 0:
		_flush_notifications()


func _notification_edge(event: Dictionary) -> HyphaEdge:
	if not _is_current_source(int(event["source_id"]), int(event["generation"])):
		return null
	var edge_id: int = int(event["edge_id"])
	if not _edges.has(edge_id):
		return null
	var record: Dictionary = _edges[edge_id]
	var receipts: Dictionary = record["receipts"]
	var edge: HyphaEdge = _edge_from_record(record)
	var tracker: CargoPassageTracker = _live_tracker()
	if edge == null or tracker == null or not receipts.has(event["receipt_key"]) \
			or not tracker.has_confirmed_passage(String(event["cargo_id"]), edge, int(event["cargo_generation"])):
		return null
	return edge


func _flush_notifications() -> void:
	if _notifying or _mutation_depth > 0:
		return
	_notifying = true
	while not _notifications.is_empty():
		var event: Dictionary = _notifications.pop_front()
		var edge: HyphaEdge = _notification_edge(event)
		if edge == null:
			continue
		edge_progress_changed.emit(edge, edge.get_vein_snapshot())
		if not is_instance_valid(self):
			return
		for grade: int in range(int(event["previous_grade"]) + 1, int(event["current_grade"]) + 1):
			edge = _notification_edge(event)
			if edge == null:
				break
			edge_upgraded.emit(edge, grade - 1, grade)
			if not is_instance_valid(self):
				return
	_notifying = false
