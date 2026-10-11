class_name RemainsPacket
extends Node2D
## 只在实际节点修复路线；关闭的已占用边保留租约与原地进度。

signal arrived(packet: RemainsPacket)
signal interrupted(packet: RemainsPacket)
signal status_changed(snapshot: Dictionary)

const CARGO_UNITS: int = 2

@export_range(1.0, 600.0, 1.0) var speed: float = 140.0
@export var traffic_required: bool = false

var edge: HyphaEdge = null
var progress: float = 0.0
var segment_index: int = 0

var _route: NetworkRoute = null
var _retry_route: NetworkRoute = null
var _network_system: NetworkSystem = null
var _has_network_system: bool = false
var _network_was_inside_tree: bool = false
var _traffic_system: NetworkTrafficSystem = null
var _traffic_system_id: int = 0
var _traffic_generation: int = -1
var _traffic_enabled: bool = false
var _captured_traffic_required: bool = false
var _traffic_was_inside_tree: bool = false
var _task_id: String = ""
var _cargo_kind: StringName = &"remains"
var _cargo_tracker_ref: WeakRef = null
var _cargo_id: String = ""
var _cargo_generation: int = -1
var _segment_has_moved: bool = false
var _request_key: String = ""
var _request_id: String = ""
var _token: String = ""
var _requesting: bool = false
var _current_node: Node2D = null
var _pickup_node: Node2D = null
var _final_target: Node2D = null
var _final_target_id: int = 0
var _node_tree_lifetimes: Dictionary[int, bool] = {}
var _edge_tree_lifetimes: Dictionary[int, bool] = {}
var _location_kind: StringName = &"ground"
var _completed_segments: int = 0
var _route_revision: int = 0
var _reroute_count: int = 0
var _hop_serial: int = 0
var _has_plan: bool = false
var _retry_signature: Array = []
var _resume_from_blocked: bool = false
var _arrival_committed: bool = false
var _own_completion_queue: bool = false
var _state: StringName = &"idle"
var _wait_reason: StringName = &""
var _last_status_snapshot: Dictionary = {}
var _travelling: bool = false
var _started: bool = false
var _finished: bool = false
var _terminal_signal_emitted: bool = false
var _exiting: bool = false
var _updating: bool = false


func _physics_process(delta: float) -> void:
	if not _travelling or _finished or _updating:
		return
	_updating = true
	if _validate_active_transport():
		_advance(maxf(speed, 0.0) * maxf(delta, 0.0))
	if is_instance_valid(self):
		_updating = false


func _exit_tree() -> void:
	_exiting = true
	if not _finished:
		_finish(false, &"owner_removed")
	elif not _terminal_signal_emitted:
		_state = &"interrupted"
		_wait_reason = &"owner_removed"
		_clear_passage(true)
		if is_instance_valid(self):
			_emit_terminal_result()


## 身份在启动前固定；可在入树前绑定，跟踪失效不会改变原运输结算。
func bind_cargo(tracker: CargoPassageTracker, cargo_id: String, generation: int) -> bool:
	if _started or _finished or _exiting or is_queued_for_deletion() \
			or not is_instance_valid(tracker) or tracker.is_queued_for_deletion() \
			or generation != tracker.get_generation():
		return false
	var snapshot: Dictionary = tracker.get_cargo_snapshot(cargo_id)
	if snapshot.is_empty() or snapshot.get("status", &"") != &"pending" \
			or int(snapshot.get("generation", -1)) != generation:
		return false
	if _cargo_tracker_ref != null:
		return _cargo_tracker_ref.get_ref() == tracker and _cargo_id == cargo_id \
			and _cargo_generation == generation
	_cargo_tracker_ref = weakref(tracker)
	_cargo_id = cargo_id
	_cargo_generation = generation
	return true


## 旧接口保留拾取步骤与 source / destination 的行进方向。
func start_transport(connection: HyphaEdge, source: Node2D, destination: Node2D,
		network_system: NetworkSystem = null, traffic_system: NetworkTrafficSystem = null,
		task_id: String = "") -> void:
	if _started or _finished or _exiting:
		return
	var route: NetworkRoute = NetworkRoute.new()
	if is_instance_valid(connection) and is_instance_valid(source) and is_instance_valid(destination):
		if connection.connects(source, destination):
			route.found = true
			route.start_node = source
			route.end_node = destination
			var segment: NetworkRoute.Segment = NetworkRoute.Segment.new()
			segment.edge = connection
			segment.start_node = source
			segment.end_node = destination
			segment.forward = connection.start_node == source
			route.segments.append(segment)
	start_route(route, network_system, traffic_system, task_id)


## 先固定目标、任务、来源和代次；零段路线仍可同步结束。
func start_route(route: NetworkRoute, network_system: NetworkSystem = null,
		traffic_system: NetworkTrafficSystem = null, task_id: String = "") -> void:
	if _started or _finished or _exiting:
		return
	_started = true
	_travelling = true
	_updating = true
	_has_network_system = network_system != null
	if is_instance_valid(network_system):
		_network_system = network_system
		_network_was_inside_tree = network_system.is_inside_tree()
	_captured_traffic_required = traffic_required
	_traffic_enabled = _captured_traffic_required or traffic_system != null
	if is_instance_valid(traffic_system):
		_traffic_system = traffic_system
		_traffic_system_id = traffic_system.get_instance_id()
		_traffic_was_inside_tree = traffic_system.is_inside_tree()
	_task_id = task_id if not task_id.is_empty() else "remains:%d" % get_instance_id()
	_cargo_kind = &"remains"
	_route = _snapshot_route(route)
	if _route != null:
		_final_target = _route.end_node
		_final_target_id = _final_target.get_instance_id()
		_pickup_node = _route.start_node
		_remember_plan_lifetimes(_route)
		_has_plan = true
		_route_revision = 1
	if not _initial_plan_is_valid():
		_finish(false, &"route_invalid")
		return
	var failure: StringName = _dependency_failure()
	if failure != &"":
		_finish(false, failure)
		return
	if _traffic_enabled:
		_traffic_system.refresh()
		if not is_instance_valid(self) or _finished or not _travelling:
			return
		failure = _dependency_failure()
		if failure != &"":
			_finish(false, failure)
			return
		_traffic_generation = _traffic_system.get_generation()
	failure = _active_failure()
	if failure != &"":
		_finish(false, failure)
		return
	segment_index = 0
	progress = 0.0
	_location_kind = &"ground"
	_state = &"pickup"
	_publish_status()
	edge = _segment_edge(_route.segments[0]) if not _route.segments.is_empty() else null
	if _validate_active_transport():
		_advance(0.0)
	if is_instance_valid(self):
		_updating = false


func cancel_transport() -> void:
	_finish(false, &"cancelled")


## 纯查询：不刷新网络或调度器，不提交、取消或移动任何运输。
func get_transport_snapshot() -> Dictionary:
	return {
		"state": _state, "wait_reason": _wait_reason,
		"traffic_enabled": _traffic_enabled,
		"traffic_required": _captured_traffic_required if _started else traffic_required,
		"traffic_system_id": _traffic_system_id, "task_id": _task_id,
		"cargo_kind": _cargo_kind, "units": CARGO_UNITS,
		"cargo_id": _cargo_id, "cargo_generation": _cargo_generation,
		"request_id": _request_id, "token": _token,
		"current_node": _current_node if is_instance_valid(_current_node) else null,
		"edge": edge if is_instance_valid(edge) else null,
		"segment_index": segment_index,
		"segment_count": _route.segments.size() if _route != null else 0,
		"completed_segments": _completed_segments,
		"progress": progress, "position": global_position,
		"started": _started,
		"final_target": _final_target if is_instance_valid(_final_target) else null,
		"final_target_id": _final_target_id,
		"location_kind": _location_kind,
		"route_revision": _route_revision, "reroute_count": _reroute_count,
		"terminal": _finished,
	}


## 等候与边上阻塞仍属同一运输；后续和已走路段不参与业务身份校验。
func is_transport_valid(expected_target: Node2D, expected_task_id: String = "") -> bool:
	if not _started or _state == &"interrupted" or not is_instance_valid(expected_target):
		return false
	if expected_target != _final_target or expected_target.get_instance_id() != _final_target_id:
		return false
	if not expected_task_id.is_empty() and expected_task_id != _task_id:
		return false
	return _active_failure() == &""


## arrived 信号本身不能伪造交付；必须已提交实际抵达原目标的终态。
func has_arrived_at(expected_target: Node2D, expected_task_id: String = "") -> bool:
	return _arrival_committed and _finished and _state == &"completed" \
		and _location_kind == &"node" and _current_node == _final_target \
		and is_transport_valid(expected_target, expected_task_id)


func _snapshot_route(route: NetworkRoute) -> NetworkRoute:
	if route == null or not route.found:
		return null
	if not is_instance_valid(route.start_node) or not is_instance_valid(route.end_node):
		return null
	var snapshot: NetworkRoute = NetworkRoute.new()
	snapshot.found = true
	snapshot.start_node = route.start_node
	snapshot.end_node = route.end_node
	for original: NetworkRoute.Segment in route.segments:
		if original == null or not is_instance_valid(original.edge) \
				or not is_instance_valid(original.start_node) or not is_instance_valid(original.end_node):
			return null
		var segment: NetworkRoute.Segment = NetworkRoute.Segment.new()
		segment.edge = original.edge
		segment.start_node = original.start_node
		segment.end_node = original.end_node
		segment.forward = original.forward
		snapshot.segments.append(segment)
	return snapshot


## 只拒绝输入中不连续或有环的计划；闭路和登记变化留给节点规划处理。
func _initial_plan_is_valid() -> bool:
	if _route == null:
		return false
	var cursor: Node2D = _route.start_node
	var visited: Dictionary[int, bool] = {cursor.get_instance_id(): true}
	for segment: NetworkRoute.Segment in _route.segments:
		if segment.start_node != cursor or visited.has(segment.end_node.get_instance_id()):
			return false
		var actual_start: Variant = segment.edge.start_node if segment.forward else segment.edge.end_node
		var actual_end: Variant = segment.edge.end_node if segment.forward else segment.edge.start_node
		if actual_start != segment.start_node or actual_end != segment.end_node:
			if not _has_network_system or not is_instance_valid(_network_system):
				return false
			if _segment_endpoints(segment).size() != 2:
				return false
		cursor = segment.end_node
		visited[cursor.get_instance_id()] = true
	return cursor == _final_target


func _remember_node_lifetime(node: Node2D) -> void:
	if is_instance_valid(node) and not _node_tree_lifetimes.has(node.get_instance_id()):
		_node_tree_lifetimes[node.get_instance_id()] = node.is_inside_tree()


func _remember_plan_lifetimes(route: NetworkRoute) -> void:
	_remember_node_lifetime(route.start_node)
	_remember_node_lifetime(route.end_node)
	for segment: NetworkRoute.Segment in route.segments:
		_remember_node_lifetime(segment.start_node)
		_remember_node_lifetime(segment.end_node)
		if is_instance_valid(segment.edge) and not _edge_tree_lifetimes.has(segment.edge.get_instance_id()):
			_edge_tree_lifetimes[segment.edge.get_instance_id()] = segment.edge.is_inside_tree()


func _node_is_available(node: Variant) -> bool:
	if not is_instance_valid(node) or not node is Node2D or node.is_queued_for_deletion():
		return false
	if bool(_node_tree_lifetimes.get(node.get_instance_id(), false)) and not node.is_inside_tree():
		return false
	return not _has_network_system or _network_system.is_node_registered(node)


func _dependency_failure() -> StringName:
	if _has_network_system or _traffic_enabled:
		if not is_instance_valid(_network_system) or _network_system.is_queued_for_deletion() \
				or (_network_was_inside_tree and not _network_system.is_inside_tree()):
			return &"missing_network"
	if not _traffic_enabled:
		return &""
	if not is_instance_valid(_traffic_system) or _traffic_system.is_queued_for_deletion() \
			or (_traffic_was_inside_tree and not _traffic_system.is_inside_tree()):
		return &"missing_traffic"
	if _traffic_system.get_instance_id() != _traffic_system_id \
			or _traffic_system.network_system != _network_system:
		return &"traffic_network_mismatch"
	if _traffic_generation >= 0 and _traffic_system.get_generation() != _traffic_generation:
		return &"traffic_reset"
	if _traffic_generation >= 0 and not _traffic_system.is_transport_identity_valid(
		self, _task_id, _traffic_generation
	):
		return &"identity_cancelled"
	return &""


func _segment_edge(segment: NetworkRoute.Segment) -> HyphaEdge:
	return segment.edge if segment != null and is_instance_valid(segment.edge) else null


func _current_segment() -> NetworkRoute.Segment:
	if _route == null or segment_index < 0 or segment_index >= _route.segments.size():
		return null
	return _route.segments[segment_index]


## 唯一允许的端点替换是网络登记的生长交接；任意 retarget 不获此许可。
func _effective_endpoint(connection: HyphaEdge, former: Variant, actual: Variant) -> Node2D:
	if not is_instance_valid(former) or not is_instance_valid(actual):
		return null
	if former == actual:
		return actual if _node_is_available(actual) else null
	if not _has_network_system:
		return null
	var handed: Node2D = _network_system.get_growth_handoff(connection, former.get_instance_id())
	return handed if handed == actual and _node_is_available(handed) else null


func _segment_endpoints(segment: NetworkRoute.Segment) -> Array[Node2D]:
	var endpoints: Array[Node2D] = []
	if segment == null or not is_instance_valid(segment.edge) or segment.edge.is_queued_for_deletion():
		return endpoints
	if bool(_edge_tree_lifetimes.get(segment.edge.get_instance_id(), false)) \
			and not segment.edge.is_inside_tree():
		return endpoints
	if _has_network_system and not _network_system.is_edge_valid(segment.edge):
		return endpoints
	var actual_start: Variant = segment.edge.start_node if segment.forward else segment.edge.end_node
	var actual_end: Variant = segment.edge.end_node if segment.forward else segment.edge.start_node
	var first: Node2D = _effective_endpoint(segment.edge, segment.start_node, actual_start)
	var last: Node2D = _effective_endpoint(segment.edge, segment.end_node, actual_end)
	if first != null and last != null and first != last:
		endpoints.assign([first, last])
	return endpoints


func _adapt_segment_handoff(segment: NetworkRoute.Segment) -> void:
	var endpoints: Array[Node2D] = _segment_endpoints(segment)
	if endpoints.size() == 2:
		segment.start_node = endpoints[0]
		segment.end_node = endpoints[1]
		_remember_node_lifetime(endpoints[0])
		_remember_node_lifetime(endpoints[1])


func _is_topology_cancellation(request: Dictionary) -> bool:
	return StringName(request.get("reason", &"")) in [
		&"edge_removed", &"endpoints_changed", &"invalid_edge", &"invalid_direction",
	]


func _request_identity_matches(request: Dictionary) -> bool:
	return bool(request.get("accepted", false)) \
		and int(request.get("generation", -1)) == _traffic_generation \
		and String(request.get("request_key", "")) == _request_key \
		and String(request.get("request_id", "")) == _request_id \
		and int(request.get("owner_id", 0)) == get_instance_id() \
		and String(request.get("task_id", "")) == _task_id \
		and StringName(request.get("cargo_kind", &"")) == _cargo_kind \
		and int(request.get("units", 0)) == CARGO_UNITS


func _passage_matches(request: Dictionary) -> bool:
	var segment: NetworkRoute.Segment = _current_segment()
	var endpoints: Array[Node2D] = _segment_endpoints(segment)
	return _request_identity_matches(request) and endpoints.size() == 2 \
		and int(request.get("edge_id", 0)) == segment.edge.get_instance_id() \
		and int(request.get("from_id", 0)) == endpoints[0].get_instance_id() \
		and int(request.get("to_id", 0)) == endpoints[1].get_instance_id()


## 全部调用均是纯访问器；不检查完整原路线，也不清理失效登记。
func _active_failure() -> StringName:
	if _exiting or (is_queued_for_deletion() and not _own_completion_queue):
		return &"owner_removed"
	var failure: StringName = _dependency_failure()
	if failure != &"":
		return failure
	if not _node_is_available(_final_target) or _final_target.get_instance_id() != _final_target_id:
		return &"target_removed"
	if _location_kind == &"ground":
		if not _node_is_available(_pickup_node):
			return &"pickup_node_removed"
	elif _location_kind == &"node":
		if not _node_is_available(_current_node):
			return &"current_node_removed"
	elif _location_kind == &"edge":
		if _segment_endpoints(_current_segment()).size() != 2:
			return &"occupied_edge_removed"
	if not _request_id.is_empty():
		var request: Dictionary = _traffic_system.get_request(_request_id)
		if not _request_identity_matches(request):
			return &"request_lost"
		if request.get("state", &"") not in [&"queued", &"granted"]:
			if _location_kind != &"node" or not _is_topology_cancellation(request):
				return StringName(request.get("reason", &"request_cancelled"))
		elif _location_kind == &"edge" and not _passage_matches(request):
			return &"lease_lost"
	if _traffic_enabled and _location_kind == &"edge":
		if _token.is_empty() or not _passage_matches(_traffic_system.get_lease(_token)):
			return &"lease_lost"
	return &""


func _validate_active_transport() -> bool:
	if _finished or not _travelling:
		return false
	var failure: StringName = _active_failure()
	if failure != &"":
		_finish(false, failure)
		return false
	if _location_kind == &"edge":
		_adapt_segment_handoff(_current_segment())
	return true


func _remaining_plan_is_usable() -> bool:
	if _route == null or segment_index >= _route.segments.size():
		return false
	var cursor: Node2D = _current_node
	var visited: Dictionary[int, bool] = {cursor.get_instance_id(): true}
	for index: int in range(segment_index, _route.segments.size()):
		var segment: NetworkRoute.Segment = _route.segments[index]
		var endpoints: Array[Node2D] = _segment_endpoints(segment)
		if endpoints.size() != 2 or endpoints[0] != cursor \
				or visited.has(endpoints[1].get_instance_id()) or not segment.edge.is_traversable():
			return false
		cursor = endpoints[1]
		visited[cursor.get_instance_id()] = true
	# 名义容量不足只等待；既有 FIFO 身份不因容量或排队成本波动被替换。
	return cursor == _final_target


## 重试指纹只含登记、端点、入口与名义容量，排除占用和动态几何。
func _planning_signature() -> Array:
	var signature: Array = []
	if _has_network_system:
		var topology: Dictionary = _network_system.get_topology_snapshot()
		for node: Node2D in topology["nodes"]:
			signature.append(node.get_instance_id())
		for row: Dictionary in topology["edges"]:
			signature.append([
				row["edge_id"], row["start_id"], row["end_id"], row["entry_enabled"], row["capacity"],
			])
	elif _retry_route != null:
		for segment: NetworkRoute.Segment in _retry_route.segments:
			var connection: Variant = segment.edge
			if is_instance_valid(connection):
				signature.append([
					connection.get_instance_id(), _object_id(connection.start_node),
					_object_id(connection.end_node), connection.is_traversable(), connection.traffic_capacity,
				])
			else:
				signature.append(0)
	return signature


func _object_id(object: Variant) -> int:
	return object.get_instance_id() if is_instance_valid(object) else 0


func _find_replacement_plan() -> NetworkRoute:
	if _traffic_enabled:
		var router: TransportRouter = TransportRouter.new()
		router.network_system = _network_system
		router.traffic_system = _traffic_system
		var result: Dictionary = router.find_route(_current_node, _final_target, _cargo_kind, speed)
		router.free()
		if bool(result.get("found", false)):
			return _snapshot_route(result.get("route"))
		if result.get("reason", &"") != &"no_route":
			return null
		# INF 排队估计不是物理断路；例如缩容后队首大包会挡住一条仍可准入的边。
		return _snapshot_route(_network_system.find_available_route(
			_current_node, _final_target, CARGO_UNITS
		))
	if _has_network_system:
		return _snapshot_route(_network_system.find_available_route(_current_node, _final_target, CARGO_UNITS))
	# 树外单边 API 不创建私有网络；只能等原物理计划重新开放。
	if _retry_route != null:
		_route = _retry_route
		if _remaining_plan_is_usable():
			var plan: NetworkRoute = NetworkRoute.new()
			plan.found = true
			plan.start_node = _current_node
			plan.end_node = _final_target
			for index: int in range(segment_index, _retry_route.segments.size()):
				plan.segments.append(_retry_route.segments[index])
			return _snapshot_route(plan)
	return null


func _ensure_node_plan() -> bool:
	if not _validate_active_transport():
		return false
	var obsolete_request: bool = false
	if not _request_id.is_empty():
		var request: Dictionary = _traffic_system.get_request(_request_id)
		obsolete_request = request.get("state", &"") not in [&"queued", &"granted"]
	if _has_plan:
		for index: int in range(segment_index, _route.segments.size()):
			_adapt_segment_handoff(_route.segments[index])
		if not obsolete_request and _remaining_plan_is_usable():
			return true
	else:
		if _planning_signature() == _retry_signature:
			_wait_at_node(&"no_route")
			return false
	# 先清空旧句柄，通知中的取消/reset 不会被下一份计划复活。
	_route_revision += 1
	_reroute_count += 1
	_has_plan = false
	_retry_route = _route if _route != null else _retry_route
	_state = &"waiting"
	_wait_reason = &"no_route"
	edge = null
	_clear_passage(false)
	if not is_instance_valid(self) or not _validate_active_transport():
		return false
	_retry_signature = _planning_signature()
	var replacement: NetworkRoute = _find_replacement_plan()
	if not is_instance_valid(self) or not _validate_active_transport():
		return false
	if replacement == null:
		if _has_network_system:
			_route = null
		_wait_at_node(&"no_route")
		return false
	_route = replacement
	_retry_route = null
	_has_plan = true
	segment_index = 0
	progress = 0.0
	_remember_plan_lifetimes(_route)
	edge = _segment_edge(_route.segments[0]) if not _route.segments.is_empty() else null
	return _remaining_plan_is_usable()


func _wait_at_node(reason: StringName) -> void:
	_state = &"waiting"
	_wait_reason = reason
	global_position = _current_node.global_position
	_publish_status()
	if is_instance_valid(self):
		_validate_active_transport()


func _enter_segment() -> bool:
	if not _traffic_enabled:
		_location_kind = &"edge"
		_segment_has_moved = false
		return _set_transport_state(&"moving")
	if _request_id.is_empty():
		if edge.traffic_capacity < CARGO_UNITS:
			_wait_at_node(&"capacity")
			return false
		_request_key = "remains:%d:revision:%d:hop:%d" % [
			get_instance_id(), _route_revision, _hop_serial,
		]
		_requesting = true
		_state = &"waiting"
		_wait_reason = &"capacity"
		var dispatcher: NetworkTrafficSystem = _traffic_system
		var segment: NetworkRoute.Segment = _current_segment()
		var result: Dictionary = dispatcher.request_passage(
			_request_key, self, _task_id, edge, segment.start_node, segment.end_node, _cargo_kind
		)
		if not is_instance_valid(self) or _finished or not _travelling:
			RemainsPacket._discard_result(dispatcher, result)
			return false
		_requesting = false
		if not _validate_active_transport():
			RemainsPacket._discard_result(dispatcher, result)
			return false
		if not bool(result.get("accepted", false)):
			var rejection: StringName = StringName(result.get("reason", &"request_rejected"))
			if rejection == &"capacity_exceeded":
				_wait_at_node(&"capacity")
			else:
				_finish(false, rejection)
			return false
		_request_id = String(result.get("request_id", ""))
		# 申请通知可能关闭/交接边；先在节点修复，绝不采用陈旧 grant。
		if not _validate_active_transport():
			return false
		if not _remaining_plan_is_usable():
			_ensure_node_plan()
			return false
	var request: Dictionary = _traffic_system.get_request(_request_id)
	if not _passage_matches(request):
		_finish(false, &"request_lost")
		return false
	if request.get("state", &"") == &"queued":
		_wait_at_node(&"capacity")
		return false
	if request.get("state", &"") != &"granted":
		_finish(false, StringName(request.get("reason", &"request_cancelled")))
		return false
	_token = String(request.get("token", ""))
	_location_kind = &"edge"
	_segment_has_moved = false
	if not _validate_active_transport():
		return false
	return _set_transport_state(&"moving")


static func _discard_result(dispatcher: Variant, result: Dictionary) -> void:
	if not is_instance_valid(dispatcher):
		return
	var token: String = String(result.get("token", ""))
	var request_id: String = String(result.get("request_id", ""))
	if not token.is_empty():
		dispatcher.release(token)
	elif not request_id.is_empty():
		dispatcher.cancel_request(request_id)


func _publish_status() -> void:
	var snapshot: Dictionary = get_transport_snapshot()
	if snapshot != _last_status_snapshot:
		_last_status_snapshot = snapshot
		status_changed.emit(snapshot)


func _set_transport_state(state: StringName, reason: StringName = &"") -> bool:
	_state = state
	_wait_reason = reason
	_publish_status()
	return is_instance_valid(self) and _validate_active_transport()


## 地面拾取与当帧已获准的菌丝共用距离；等候不积存时间或过冲。
func _advance(distance: float) -> void:
	var remaining: float = distance
	if _location_kind == &"ground":
		var pickup_position: Vector2 = _pickup_node.global_position
		var direction: Vector2 = pickup_position - global_position
		var pickup_distance: float = direction.length()
		if pickup_distance > 0.0:
			global_rotation = direction.angle()
		if remaining < pickup_distance:
			global_position = global_position.move_toward(pickup_position, remaining)
			_publish_status()
			if is_instance_valid(self):
				_validate_active_transport()
			return
		global_position = pickup_position
		remaining = maxf(remaining - pickup_distance, 0.0)
		_current_node = _pickup_node
		_location_kind = &"node"
	_advance_segments(remaining)


func _advance_segments(distance: float) -> void:
	var remaining: float = distance
	while _travelling and not _finished:
		if not _validate_active_transport():
			return
		if _location_kind == &"node":
			if _current_node == _final_target:
				_arrival_committed = true
				_finish(true)
				return
			if not _ensure_node_plan():
				return
			edge = _segment_edge(_current_segment())
			global_position = _current_node.global_position
			if not _enter_segment():
				return
		if not _validate_active_transport():
			return
		if not edge.is_traversable():
			_resume_from_blocked = true
			_set_transport_state(&"blocked", &"entry_closed")
			return
		if _state == &"blocked":
			if not _set_transport_state(&"moving"):
				return
			if not edge.is_traversable():
				_set_transport_state(&"blocked", &"entry_closed")
				return
		var segment: NetworkRoute.Segment = _current_segment()
		var start_position: Vector2 = segment.start_node.global_position
		var end_position: Vector2 = segment.end_node.global_position
		var length: float = start_position.distance_to(end_position)
		# 平时沿实时几何保留归一化进度；解封第一步从冻结世界坐标继续。
		var distance_left: float = global_position.distance_to(end_position) if _resume_from_blocked \
			else length * (1.0 - progress)
		var completed: bool = remaining >= distance_left
		if remaining > 0.0 and distance_left > 0.0:
			_segment_has_moved = true
		if completed:
			progress = 1.0
			global_position = end_position
			remaining = maxf(remaining - distance_left, 0.0)
		elif _resume_from_blocked:
			global_position = global_position.move_toward(end_position, remaining)
			progress = clampf(1.0 - global_position.distance_to(end_position) / length, 0.0, 1.0) \
				if length > 0.0 else 0.0
		else:
			progress += remaining / length
			global_position = start_position.lerp(end_position, progress)
		_resume_from_blocked = false
		if length > 0.0:
			global_rotation = (end_position - start_position).angle()
		if not completed:
			_publish_status()
			if is_instance_valid(self):
				_validate_active_transport()
			return
		_current_node = segment.end_node
		_completed_segments += 1
		_location_kind = &"node"
		if _current_node == _final_target:
			_arrival_committed = true
			_finish(true, &"", segment.edge if length > 0.0 and _segment_has_moved else null)
			return
		# 真正抵达后再提交下一跳索引并交还；重入看见已到节点且无旧句柄。
		_hop_serial += 1
		segment_index += 1
		progress = 0.0
		_state = &"waiting"
		_wait_reason = &""
		if length > 0.0 and _segment_has_moved:
			_record_completed_cargo_passage(segment.edge)
		if not is_instance_valid(self) or _finished or not _travelling:
			return
		edge = _segment_edge(_current_segment())
		_clear_passage(false)
		if not is_instance_valid(self) or not _validate_active_transport():
			return


func _record_completed_cargo_passage(completed_edge: HyphaEdge) -> void:
	if _cargo_tracker_ref == null:
		return
	var tracker: CargoPassageTracker = _cargo_tracker_ref.get_ref() as CargoPassageTracker
	if not is_instance_valid(tracker) or tracker.is_queued_for_deletion() \
			or tracker.get_generation() != _cargo_generation:
		return
	tracker.record_candidate(_cargo_id, completed_edge, _cargo_generation)


## 先清本地句柄；成功只 release，避免把自己的已抵达身份退役。
func _clear_passage(retire_owner: bool) -> void:
	var dispatcher: Variant = _traffic_system
	var old_token: String = _token
	var old_request: String = _request_id
	var was_requesting: bool = _requesting
	_token = ""
	_request_id = ""
	_request_key = ""
	_requesting = false
	if not is_instance_valid(dispatcher):
		return
	if not old_token.is_empty():
		dispatcher.release(old_token)
	elif not old_request.is_empty():
		dispatcher.cancel_request(old_request)
	if (retire_owner or was_requesting) and is_instance_valid(self) and is_instance_valid(dispatcher):
		dispatcher.cancel_owner(self)


func _revalidate_pending_handoff() -> void:
	if _terminal_signal_emitted or _state != &"completed":
		return
	var failure: StringName = _active_failure()
	if failure == &"" and (not _arrival_committed or _location_kind != &"node" \
			or _current_node != _final_target):
		failure = &"arrival_not_committed"
	if failure != &"":
		_state = &"interrupted"
		_wait_reason = failure


func _emit_terminal_result() -> void:
	if _terminal_signal_emitted:
		return
	_revalidate_pending_handoff()
	if not is_instance_valid(self) or _terminal_signal_emitted:
		return
	if _state == &"interrupted":
		_publish_status()
		if not is_instance_valid(self) or _terminal_signal_emitted:
			return
	_terminal_signal_emitted = true
	if _state == &"completed":
		# 发出交付前已完成全部复核；业务监听者随后 queue_free 仍可查询同一交付。
		_own_completion_queue = true
		arrived.emit(self)
	else:
		interrupted.emit(self)


func _finish(was_delivered: bool, reason: StringName = &"", completed_edge: HyphaEdge = null) -> void:
	if _finished:
		if not was_delivered and not _terminal_signal_emitted and _state == &"completed":
			_state = &"interrupted"
			_wait_reason = reason
		return
	_finished = true
	_travelling = false
	_state = &"completed" if was_delivered else &"interrupted"
	_wait_reason = &"" if was_delivered else reason
	if was_delivered and is_instance_valid(completed_edge):
		_record_completed_cargo_passage(completed_edge)
	if not is_instance_valid(self):
		return
	_clear_passage(not was_delivered)
	if not is_instance_valid(self) or _terminal_signal_emitted:
		return
	_revalidate_pending_handoff()
	_publish_status()
	if not is_instance_valid(self) or _terminal_signal_emitted:
		return
	_emit_terminal_result()
	if is_instance_valid(self) and not _exiting and not is_queued_for_deletion():
		_own_completion_queue = _state == &"completed"
		queue_free()
