class_name FragmentCollectionController
extends Node
## 不领取任何养分；每个碎片每帧最多推进一次，覆盖来源必须仍可正常连通母核。

signal changed(snapshot: Dictionary)
signal fragment_collected(id: StringName, memory_text: String)
signal objective_completed(evidence: Dictionary)

var collected_ids: Array[StringName] = []
var _level: ColonyLevelRuntime
var _fragments: Array[MemoryFragment] = []
var _configured: bool = false
var _stopped: bool = false
var _completed: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func configure(level: ColonyLevelRuntime, fragments: Array[MemoryFragment]) -> bool:
	if _configured or not is_instance_valid(level) or fragments.size() != 3:
		return false
	var ids: Array[StringName] = []
	for fragment: MemoryFragment in fragments:
		if not is_instance_valid(fragment) or fragment.fragment_id.is_empty() or ids.has(fragment.fragment_id) \
				or not is_finite(fragment.collection_seconds) or fragment.collection_seconds <= 0:
			return false
		ids.append(fragment.fragment_id)
	_level = level
	_fragments = fragments.duplicate()
	_configured = true
	changed.emit(get_snapshot())
	return true


func _process(delta: float) -> void:
	if not _configured or _stopped or _completed or not can_process() or not is_finite(delta) or delta <= 0:
		return
	var dirty: bool = false
	for fragment: MemoryFragment in _fragments:
		if not is_instance_valid(fragment) or fragment.is_queued_for_deletion() or fragment.collected:
			continue
		var active: bool = has_effective_coverage(fragment.global_position)
		dirty = dirty or active != fragment.collecting or active
		fragment.collecting = active
		if active:
			fragment.progress_seconds = minf(fragment.collection_seconds, fragment.progress_seconds + delta)
			if fragment.progress_seconds >= fragment.collection_seconds:
				fragment.collected = true
				fragment.collecting = false
				collected_ids.append(fragment.fragment_id)
				fragment_collected.emit(fragment.fragment_id, fragment.memory_text)
		fragment.refresh_view()
	if dirty:
		changed.emit(get_snapshot())
	if collected_ids.size() == 3 and not _completed:
		_completed = true
		objective_completed.emit(get_evidence())


func has_effective_coverage(point: Vector2) -> bool:
	for source: Node2D in _level.fungal_field.get_collecting_nodes(point):
		if is_instance_valid(source) and not source.is_queued_for_deletion() \
				and _level.network_system.is_available_connected_to_core(source) \
				and (not source.has_method("is_functional") or source.is_functional()):
			return true
	return false


func get_snapshot() -> Dictionary:
	var fragments: Array[Dictionary] = []
	for fragment: MemoryFragment in _fragments:
		if is_instance_valid(fragment):
			fragments.append(fragment.get_snapshot())
	return {"completed": collected_ids.size(), "total": 3, "collected_ids": collected_ids.duplicate(),
		"fragments": fragments, "stopped": _stopped}


func get_evidence() -> Dictionary:
	return {"level_id": "third_level", "completed": collected_ids.size(), "total": 3,
		"collected_ids": collected_ids.duplicate()}


func stop(_reason: StringName) -> void:
	_stopped = true
	for fragment: MemoryFragment in _fragments:
		if is_instance_valid(fragment):
			fragment.collecting = false
			fragment.refresh_view()


func _exit_tree() -> void:
	stop(&"scene_exit")
