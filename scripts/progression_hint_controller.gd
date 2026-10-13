class_name ProgressionHintController
extends Node

## 只观察真实来源；每轮首次提示独立去重，关闭期间发生的提示也记为已见。

signal hint_changed(snapshot: Dictionary)

const HINT_IDS: Array[StringName] = [
	&"first_resource_connected", &"expanded", &"two_tips_available",
	&"second_resource_connected", &"mature", &"second_chamber_ready",
	&"first_vein_upgrade",
]
const HINT_TEXT: Dictionary = {
	&"first_resource_connected": "第一处资源已首次接入菌网。保持通向胃室与母核的通路，才能持续采集与回流。",
	&"expanded": "群落已展开：累计回收达到 60。成长只累计真正到达母核的消化产物。",
	&"two_tips_available": "当前施工系统已允许 2 个延伸尖端。实际施工仍需要可用通路与营养供给。",
	&"second_resource_connected": "第二处资源已首次接入菌网。两处资源的采集与回流仍需要保持各自通路可用。",
	&"mature": "群落已成熟：累计回收达到 160。第二消化腔室须完成扩建后才可工作。",
	&"second_chamber_ready": "第二消化腔室已完成扩建，现在可并行消化。两腔室仍共用有限的产物库存。",
	&"first_vein_upgrade": "第一条菌脉已升级。确认完成的运输经过会推动主脉成长，并提高通行容量。",
}

var _enabled: bool = true
var _configured: bool = false
var _generation: int = 0
var _configuration_ids: Array[int] = []
var _source_refs: Dictionary[StringName, WeakRef] = {}
var _bindings: Array[Dictionary] = []
var _current_id: StringName = &""
var _pending_ids: Array[StringName] = []
var _seen_ids: Dictionary[StringName, bool] = {}
var _seen_order: Array[StringName] = []
var _notification_queue: Array[Dictionary] = []
var _last_queued_snapshot: Dictionary = {}
var _last_emitted_snapshot: Dictionary = {}
var _is_notifying: bool = false


func _init() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	# 来源的字段与可用性可能在没有新业务信号时改变，展示前仍以当前查询为准。
	_observe_current_state()


func _exit_tree() -> void:
	reset()


func _on_progress_changed(_total: int, _count: int, generation: int, source_id: int) -> void:
	_observe_callback(&"progress", generation, source_id)


func _on_stage_changed(
	_previous: ColonyProgress.Stage, _current: ColonyProgress.Stage,
	generation: int, source_id: int
) -> void:
	_observe_callback(&"progress", generation, source_id)


func _on_stage_unlocked(_stage: ColonyProgress.Stage, generation: int, source_id: int) -> void:
	_observe_callback(&"progress", generation, source_id)


func _on_construction_changed(_snapshot: Dictionary, generation: int, source_id: int) -> void:
	_observe_callback(&"coordinator", generation, source_id)


func _on_digestion_changed(_snapshot: Dictionary, generation: int, source_id: int) -> void:
	_observe_callback(&"stomach", generation, source_id)


func _on_edge_upgraded(
	_edge: HyphaEdge, _previous: int, _current: int, generation: int, source_id: int
) -> void:
	_observe_callback(&"veins", generation, source_id)


func _on_resource_access_changed(
	_index: int, _connected: bool, generation: int, source_id: int
) -> void:
	_observe_callback(&"resources", generation, source_id)


func configure(
	progress: ColonyProgress, capabilities: ColonyCapabilities,
	coordinator: ConstructionCoordinator, stomach: DigestiveOrgan,
	veins: MainVeinSystem, resource_source: Node
) -> void:
	var sources: Array[Node] = [progress, capabilities, coordinator, stomach, veins, resource_source]
	var source_ids: Array[int] = []
	for source: Node in sources:
		source_ids.append(source.get_instance_id() if _node_is_available(source) else 0)
	if _configured and source_ids == _configuration_ids:
		_observe_current_state()
		return

	_generation += 1
	_disconnect_sources()
	_clear_playthrough()
	_configured = true
	_configuration_ids = source_ids
	var keys: Array[StringName] = [
		&"progress", &"capabilities", &"coordinator", &"stomach", &"veins", &"resources",
	]
	for index: int in range(sources.size()):
		if _node_is_available(sources[index]):
			_source_refs[keys[index]] = weakref(sources[index])
	_bind_source(&"progress", &"progress_changed", _on_progress_changed)
	_bind_source(&"progress", &"stage_changed", _on_stage_changed)
	_bind_source(&"progress", &"stage_unlocked", _on_stage_unlocked)
	_bind_source(&"coordinator", &"changed", _on_construction_changed)
	_bind_source(&"stomach", &"digestion_changed", _on_digestion_changed)
	_bind_source(&"veins", &"edge_upgraded", _on_edge_upgraded)
	_bind_source(&"resources", &"resource_access_changed", _on_resource_access_changed)
	set_process(true)
	_observe_current_state()


func get_snapshot() -> Dictionary:
	return _build_snapshot()


func dismiss_current() -> void:
	if not _configured or not _enabled or _current_id == &"":
		return
	_current_id = &""
	_refresh_presentation()
	_queue_snapshot_notification()


func set_hints_enabled(value: bool) -> void:
	if _enabled == value:
		return
	if value:
		# 先在关闭状态下补采当前事实，避免没有信号的关闭期间变化在重开时涌入。
		_observe_current_state()
		_enabled = true
	else:
		_enabled = false
		_current_id = &""
		_pending_ids.clear()
	_observe_current_state()
	_queue_snapshot_notification()


func reset() -> void:
	_generation += 1
	_configured = false
	_disconnect_sources()
	_clear_playthrough()
	_configuration_ids.clear()
	_enabled = true
	set_process(false)
	_queue_snapshot_notification()


func _observe_callback(key: StringName, generation: int, source_id: int) -> void:
	if not _configured or generation != _generation or not _node_is_available(self):
		return
	var source: Node = _live_source(key)
	if source == null or source.get_instance_id() != source_id:
		return
	# 信号参数只触发重查，不作为资源接入、阶段、腔室或主脉升级的证据。
	_observe_current_state()


func _observe_current_state() -> void:
	if not _configured or not _node_is_available(self):
		return
	for id: StringName in HINT_IDS:
		if not _seen_ids.has(id) and _hint_is_ready(id):
			# 必须先提交全部身份，再对外通知；同步重入不能重复排入同一提示。
			_seen_ids[id] = true
			_seen_order.append(id)
			if _enabled:
				_pending_ids.append(id)
	_refresh_presentation()
	_queue_snapshot_notification()


func _refresh_presentation() -> void:
	if not _enabled:
		_current_id = &""
		_pending_ids.clear()
	else:
		if _current_id != &"" and not _hint_is_ready(_current_id):
			_current_id = &""
		var usable_pending: Array[StringName] = []
		for id: StringName in _pending_ids:
			if _hint_is_ready(id):
				usable_pending.append(id)
		_pending_ids = usable_pending
		if _current_id == &"" and not _pending_ids.is_empty():
			_current_id = _pending_ids.pop_front()


func _hint_is_ready(id: StringName) -> bool:
	match id:
		&"first_resource_connected":
			return _resource_is_connected(1)
		&"second_resource_connected":
			return _resource_is_connected(2)
		&"expanded", &"mature":
			var progress: ColonyProgress = _live_source(&"progress") as ColonyProgress
			var threshold: ColonyProgress.Stage = ColonyProgress.Stage.MATURE \
				if id == &"mature" else ColonyProgress.Stage.EXPANDED
			return progress != null and progress.get_stage() >= threshold
		&"two_tips_available":
			var capabilities: ColonyCapabilities = _live_source(&"capabilities") as ColonyCapabilities
			var coordinator: ConstructionCoordinator = _live_source(&"coordinator") as ConstructionCoordinator
			return capabilities != null and coordinator != null \
				and capabilities.get_extension_tip_limit() >= 2 and coordinator.multi_worker_enabled \
				and int(coordinator.get_snapshot().get("tip_limit", 0)) >= 2
		&"second_chamber_ready":
			var stomach: DigestiveOrgan = _live_source(&"stomach") as DigestiveOrgan
			if stomach == null:
				return false
			var digestion: Dictionary = stomach.get_digestion_snapshot()
			return bool(digestion.get("enabled", false)) \
				and digestion.get("expansion_state", &"") == &"ready" \
				and int(digestion.get("chamber_count", 0)) >= 2
		&"first_vein_upgrade":
			return _has_upgraded_registered_edge()
		_:
			return false


func _resource_is_connected(index: int) -> bool:
	var source: Node = _live_source(&"resources")
	if source == null or not source.has_method(&"get_resource_access_snapshot"):
		return false
	var resources: Variant = source.call(&"get_resource_access_snapshot")
	if not resources is Array:
		return false
	for entry: Variant in resources:
		if entry is Dictionary and int(entry.get("index", 0)) == index \
				and bool(entry.get("connected", false)):
			return true
	return false


func _has_upgraded_registered_edge() -> bool:
	var veins: MainVeinSystem = _live_source(&"veins") as MainVeinSystem
	if veins == null:
		return false
	var snapshot: Dictionary = veins.get_snapshot()
	if not bool(snapshot.get("enabled", false)) or bool(snapshot.get("stopped", true)):
		return false
	for edge: Dictionary in snapshot.get("edges", []):
		if int(edge.get("edge_id", 0)) > 0 and int(edge.get("grade", 0)) >= 1:
			return true
	return false


func _build_snapshot() -> Dictionary:
	var visible: bool = _configured and _enabled and _current_id != &"" \
		and _hint_is_ready(_current_id)
	var pending_count: int = 0
	if _configured and _enabled:
		for id: StringName in _pending_ids:
			if _hint_is_ready(id):
				pending_count += 1
	return {
		"enabled": _enabled, "visible": visible, "id": _current_id if visible else &"",
		"text": String(HINT_TEXT.get(_current_id, "")) if visible else "",
		"pending_count": pending_count, "seen_ids": _seen_order.duplicate(),
		"generation": _generation,
	}


func _bind_source(key: StringName, signal_name: StringName, handler: Callable) -> void:
	var source: Node = _live_source(key)
	if source == null or not source.has_signal(signal_name):
		return
	var callback: Callable = handler.bind(_generation, source.get_instance_id())
	if source.connect(signal_name, callback) == OK:
		_bindings.append({"source": weakref(source), "signal": signal_name, "callback": callback})


func _disconnect_sources() -> void:
	var bindings: Array[Dictionary] = _bindings.duplicate()
	_bindings.clear()
	_source_refs.clear()
	for binding: Dictionary in bindings:
		var reference: WeakRef = binding["source"]
		var source: Node = reference.get_ref() as Node
		if is_instance_valid(source) and source.is_connected(binding["signal"], binding["callback"]):
			source.disconnect(binding["signal"], binding["callback"])


func _live_source(key: StringName) -> Node:
	var reference: WeakRef = _source_refs.get(key)
	var source: Node = reference.get_ref() as Node if reference != null else null
	return source if _node_is_available(source) else null


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion() \
		and node.is_inside_tree()


func _clear_playthrough() -> void:
	_current_id = &""
	_pending_ids.clear()
	_seen_ids.clear()
	_seen_order.clear()
	_notification_queue.clear()
	_last_queued_snapshot.clear()


func _queue_snapshot_notification() -> void:
	var snapshot: Dictionary = _build_snapshot()
	if snapshot == _last_queued_snapshot:
		return
	_last_queued_snapshot = snapshot.duplicate(true)
	_notification_queue.append({"generation": _generation, "snapshot": snapshot})
	_flush_notifications()


func _flush_notifications() -> void:
	if _is_notifying:
		return
	_is_notifying = true
	while not _notification_queue.is_empty():
		var notification: Dictionary = _notification_queue.pop_front()
		if notification["generation"] == _generation and _node_is_available(self):
			var snapshot: Dictionary = notification["snapshot"]
			# 重入关闭、dismiss、替换来源或 reset 后，跳过已经过时的待发快照。
			if snapshot == _build_snapshot() and snapshot != _last_emitted_snapshot:
				_last_emitted_snapshot = snapshot.duplicate(true)
				hint_changed.emit(snapshot.duplicate(true))
	_is_notifying = false
