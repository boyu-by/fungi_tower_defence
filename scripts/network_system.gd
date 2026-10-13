class_name NetworkSystem
extends Node

## 登记外部节点和菌丝边，不负责其所有权；查询实时读取边端点。
## 同长度路线按边登记顺序选择，network_changed 通知登记变化。

signal network_changed

var _nodes: Dictionary[int, Node2D] = {}
var _edges: Dictionary[int, HyphaEdge] = {}
var _edge_order: Array[int] = []
var _node_exit_callbacks: Dictionary[int, Callable] = {}
var _edge_exit_callbacks: Dictionary[int, Callable] = {}
var _node_health_callbacks: Dictionary[int, Callable] = {}
var _edge_traffic_callbacks: Dictionary[int, Callable] = {}
var _mother_core_id: int = 0
var _connection_corridors: Array[NetworkRoute] = []


func _on_node_tree_exiting(node_id: int) -> void:
	if _remove_node_registration(node_id):
		network_changed.emit()


func _on_edge_tree_exiting(edge_id: int) -> void:
	if _remove_edge_registration(edge_id):
		network_changed.emit()


func _on_node_health_changed(_current: float, _maximum: float) -> void:
	# 失效和复活保留物理登记，只通知可用连通性及共享交通重读生命门控。
	network_changed.emit()


func _on_edge_traffic_changed() -> void:
	network_changed.emit()


func register_node(node: Node2D, is_mother_core: bool = false) -> bool:
	_prune_registrations()
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return false
	var node_id: int = node.get_instance_id()
	if is_mother_core and _mother_core_id != 0 and _mother_core_id != node_id:
		return false

	var changed: bool = not _nodes.has(node_id)
	if changed:
		var exit_callback: Callable = _on_node_tree_exiting.bind(node_id)
		_nodes[node_id] = node
		_node_exit_callbacks[node_id] = exit_callback
		node.tree_exiting.connect(exit_callback)
		if node.has_signal("health_changed"):
			var health_callback: Callable = _on_node_health_changed
			_node_health_callbacks[node_id] = health_callback
			node.connect("health_changed", health_callback)
	if is_mother_core and _mother_core_id != node_id:
		_mother_core_id = node_id
		changed = true
	if changed:
		network_changed.emit()
	return true


func unregister_node(node: Node2D) -> void:
	_prune_registrations()
	if not is_instance_valid(node):
		return
	if _remove_node_registration(node.get_instance_id()):
		network_changed.emit()


func register_edge(edge: HyphaEdge) -> bool:
	_prune_registrations()
	if not is_instance_valid(edge) or edge.is_queued_for_deletion():
		return false
	if not _has_registered_endpoints(edge):
		return false
	var edge_id: int = edge.get_instance_id()
	if _edges.has(edge_id):
		return true

	var exit_callback: Callable = _on_edge_tree_exiting.bind(edge_id)
	_edges[edge_id] = edge
	_edge_order.append(edge_id)
	_edge_exit_callbacks[edge_id] = exit_callback
	edge.tree_exiting.connect(exit_callback)
	var traffic_callback: Callable = _on_edge_traffic_changed
	_edge_traffic_callbacks[edge_id] = traffic_callback
	edge.traffic_settings_changed.connect(traffic_callback)
	network_changed.emit()
	return true


func unregister_edge(edge: HyphaEdge) -> void:
	_prune_registrations()
	if not is_instance_valid(edge):
		return
	if _remove_edge_registration(edge.get_instance_id()):
		network_changed.emit()


func get_registered_nodes() -> Array[Node2D]:
	_prune_registrations()
	var nodes: Array[Node2D] = []
	for node_id: int in _nodes:
		nodes.append(_nodes[node_id])
	return nodes


## 纯查询：跳过失效对象，但不清理登记表，也不要求边端点当前可用。
func get_registered_edges() -> Array[HyphaEdge]:
	var edges: Array[HyphaEdge] = []
	for edge_id: int in _edge_order:
		var edge: HyphaEdge = _get_registered_edge(edge_id)
		if edge != null:
			edges.append(edge)
	return edges


func is_node_registered(node: Node2D) -> bool:
	return _is_registered_node(node)


func is_node_functional(node: Node2D) -> bool:
	return _is_registered_node(node) and _node_is_functional(node)


## 物理有效性与通行开关、容量无关；临时关闭仍保留同一条边。
func is_edge_valid(edge: HyphaEdge) -> bool:
	if not is_instance_valid(edge) or edge.is_queued_for_deletion():
		return false
	return _get_registered_edge(edge.get_instance_id()) == edge \
		and _has_registered_endpoints(edge)


## 只检查静态通行条件，不承诺当前有空闲容量，也不预留席位。
func can_enter_edge(edge: HyphaEdge, units: int = 1) -> bool:
	return is_edge_valid(edge) and edge.is_traversable() \
		and units > 0 and units <= edge.traffic_capacity


## 纯物理拓扑快照；数组和边行都是新容器，关闭的有效边仍在快照中。
func get_topology_snapshot() -> Dictionary:
	var nodes: Array[Node2D] = []
	for node_id: int in _nodes:
		var node: Node2D = _get_registered_node(node_id)
		if node != null:
			nodes.append(node)
	var edges: Array[Dictionary] = []
	for edge_id: int in _edge_order:
		var edge: HyphaEdge = _get_registered_edge(edge_id)
		if edge == null or not _has_registered_endpoints(edge):
			continue
		edges.append({
			"edge": edge,
			"edge_id": edge_id,
			"start_node": edge.start_node,
			"end_node": edge.end_node,
			"start_id": edge.start_node.get_instance_id(),
			"end_id": edge.end_node.get_instance_id(),
			"length": edge.get_length(),
			"capacity": edge.traffic_capacity,
			"entry_enabled": edge.is_traversable(),
		})
	return {"nodes": nodes, "edges": edges}


func get_registered_core() -> Node2D:
	_prune_registrations()
	return _get_registered_node(_mother_core_id)


## 只读母核引用，供修复预览使用；不借查询清理登记或发出信号。
func peek_registered_core() -> Node2D:
	return _get_registered_node(_mother_core_id)


## 普通绕行路线不算直接连接；明确完成的连接可包含已付款的中继菌结。
func has_direct_connection(first: Node2D, second: Node2D) -> bool:
	_prune_registrations()
	if not _is_registered_node(first) or not _is_registered_node(second) or first == second:
		return false
	for edge_id: int in _edge_order:
		var edge: HyphaEdge = _get_registered_edge(edge_id)
		if edge != null and _has_registered_endpoints(edge) and edge.connects(first, second):
			return true
	var found: bool = false
	for corridor: NetworkRoute in _connection_corridors:
		if is_route_valid(corridor):
			if (corridor.start_node == first and corridor.end_node == second) \
					or (corridor.start_node == second and corridor.end_node == first):
				found = true
	# 暂时注销再登记同一条边不抹去任务身份；断路期间仅判为不可用。
	return found


## 只接受生长任务实际铺设的连续边，不通过 BFS 把另一条间接路线登记成连接。
func register_connection_corridor(
	first: HyphaNode, second: HyphaNode, edges: Array[HyphaEdge]
) -> bool:
	_prune_registrations()
	if not _is_registered_node(first) or not _is_registered_node(second) \
			or first == second or edges.is_empty():
		return false
	var corridor: NetworkRoute = NetworkRoute.new()
	corridor.start_node = first
	corridor.end_node = second
	var cursor: Node2D = first
	for edge: HyphaEdge in edges:
		if not is_instance_valid(edge) or edge.is_queued_for_deletion() \
				or _get_registered_edge(edge.get_instance_id()) != edge \
				or not _has_registered_endpoints(edge):
			return false
		var segment: NetworkRoute.Segment = NetworkRoute.Segment.new()
		segment.edge = edge
		segment.start_node = cursor
		if edge.start_node == cursor:
			segment.end_node = edge.end_node
			segment.forward = true
		elif edge.end_node == cursor:
			segment.end_node = edge.start_node
			segment.forward = false
		else:
			return false
		corridor.segments.append(segment)
		cursor = segment.end_node
	corridor.found = cursor == second
	if not is_route_valid(corridor):
		return false
	_connection_corridors.append(corridor)
	return true


func is_connected_to_core(node: Node2D) -> bool:
	_prune_registrations()
	var core: Node2D = _get_registered_node(_mother_core_id)
	return find_route(node, core).found


## 可用供养连通性不把临时禁行当作删边，也不受实时容量占用影响。
func is_available_connected_to_core(node: Node2D) -> bool:
	return find_available_route(node, _get_registered_node(_mother_core_id)).found


## 已送达的建设缓存不依赖交通入口临时开关；真实断丝和枯结仍停止工作。
func is_work_connected_to_core(node: Node2D) -> bool:
	var core: Node2D = _get_registered_node(_mother_core_id)
	if not is_node_functional(node) or not is_node_functional(core):
		return false
	if node == core:
		return true
	var broken: Dictionary[int, bool] = {}
	for edge: HyphaEdge in get_registered_edges():
		if edge.health <= 0.0:
			broken[edge.get_instance_id()] = true
	return not _find_segments(node.get_instance_id(), core.get_instance_id(), 0, broken).is_empty()


## 只读的最少段数可用路线；用于采集准入，运输改道仍由 TransportRouter 计成本。
func find_available_route(start: Node2D, end: Node2D, units: int = 1) -> NetworkRoute:
	var route: NetworkRoute = NetworkRoute.new()
	if is_instance_valid(start):
		route.start_node = start
	if is_instance_valid(end):
		route.end_node = end
	if units <= 0 or not is_node_functional(start) or not is_node_functional(end):
		return route
	if start == end:
		route.found = true
	else:
		route.segments = _find_segments(start.get_instance_id(), end.get_instance_id(), units)
		route.found = not route.segments.is_empty()
	return route


## 修复从可达端作业，不能借目标菌丝本身到达作业点。
func find_available_route_excluding(start: Node2D, end: Node2D,
		excluded_edge: HyphaEdge, units: int = 1) -> NetworkRoute:
	if not is_instance_valid(excluded_edge):
		return NetworkRoute.new()
	return find_available_route_avoiding(start, end, [excluded_edge], units)


## 同一 BFS 的排除版；包的后续改道也沿用捕获的排除集合。
func find_available_route_avoiding(start: Node2D, end: Node2D,
		excluded_edges: Array[HyphaEdge], units: int = 1) -> NetworkRoute:
	var route: NetworkRoute = NetworkRoute.new()
	if is_instance_valid(start):
		route.start_node = start
	if is_instance_valid(end):
		route.end_node = end
	if units <= 0 or not is_node_functional(start) or not is_node_functional(end):
		return route
	var excluded_ids: Dictionary[int, bool] = {}
	for edge: HyphaEdge in excluded_edges:
		if is_instance_valid(edge):
			excluded_ids[edge.get_instance_id()] = true
	if start == end:
		route.found = true
	else:
		route.segments = _find_segments(start.get_instance_id(), end.get_instance_id(), units, excluded_ids)
		route.found = not route.segments.is_empty()
	return route


## 只认可施工系统明确提交的尖端交接，不把任意改端点解释为合法替换。
func get_growth_handoff(edge: HyphaEdge, former_endpoint_id: int) -> Node2D:
	if not is_edge_valid(edge) or former_endpoint_id <= 0 \
			or int(edge.get_meta("growth_handoff_from_id", 0)) != former_endpoint_id:
		return null
	var reference: Variant = edge.get_meta("growth_handoff_to_ref", null)
	if not reference is WeakRef:
		return null
	var endpoint: Variant = reference.get_ref()
	if not is_instance_valid(endpoint) or not endpoint is HyphaNode \
			or not _is_registered_node(endpoint) or edge.end_node != endpoint:
		return null
	return endpoint as Node2D


func find_route(start: Node2D, end: Node2D) -> NetworkRoute:
	var route: NetworkRoute = NetworkRoute.new()
	if is_instance_valid(start):
		route.start_node = start
	if is_instance_valid(end):
		route.end_node = end
	_prune_registrations()
	if not is_node_functional(start) or not is_node_functional(end):
		return route
	if start == end:
		route.found = true
		return route

	route.segments = _find_segments(start.get_instance_id(), end.get_instance_id())
	route.found = not route.segments.is_empty()
	return route


## 检查一份既定路线仍属于当前网络；供运输识别注销、删除与端点变更。
## 这是物理快照校验；6.4 在途包按自身当前段/目标判断，不再据此取消整笔运输。
func is_route_valid(route: NetworkRoute) -> bool:
	_prune_registrations()
	if route == null or not route.found:
		return false
	# 快照可比场景节点活得更久；先验证引用，再传给 Node2D 类型的内部函数。
	if not is_instance_valid(route.start_node) or not is_instance_valid(route.end_node):
		return false
	if not _is_registered_node(route.start_node) or not _is_registered_node(route.end_node):
		return false
	var cursor: Node2D = route.start_node
	var visited: Dictionary[int, bool] = {cursor.get_instance_id(): true}
	for segment: NetworkRoute.Segment in route.segments:
		if segment == null or not is_instance_valid(segment.edge):
			return false
		if _get_registered_edge(segment.edge.get_instance_id()) != segment.edge or not _has_registered_endpoints(segment.edge):
			return false
		if not is_instance_valid(segment.start_node) or not is_instance_valid(segment.end_node):
			return false
		if not _is_registered_node(segment.start_node) or not _is_registered_node(segment.end_node):
			return false
		if segment.start_node != cursor or visited.has(segment.end_node.get_instance_id()):
			return false
		var expected_start: Node2D = segment.edge.start_node if segment.forward else segment.edge.end_node
		var expected_end: Node2D = segment.edge.end_node if segment.forward else segment.edge.start_node
		if expected_start != segment.start_node or expected_end != segment.end_node:
			return false
		cursor = segment.end_node
		visited[cursor.get_instance_id()] = true
	return cursor == route.end_node


## 只在确认对象有效后解引用，兼容树外节点及直接 free 的对象。
func _get_registered_node(node_id: int) -> Node2D:
	if not _nodes.has(node_id) or not is_instance_valid(_nodes[node_id]):
		return null
	var node: Node2D = _nodes[node_id]
	if node.is_queued_for_deletion():
		return null
	return node


## 按实例编号安全读取边，已排队删除的边立即不可用。
func _get_registered_edge(edge_id: int) -> HyphaEdge:
	if not _edges.has(edge_id) or not is_instance_valid(_edges[edge_id]):
		return null
	var edge: HyphaEdge = _edges[edge_id]
	if edge.is_queued_for_deletion():
		return null
	return edge


## 登记检查不依赖节点是否已经进入场景树。
func _is_registered_node(node: Variant) -> bool:
	if not is_instance_valid(node) or not node is Node2D or node.is_queued_for_deletion():
		return false
	return _nodes.has(node.get_instance_id())


func _node_is_functional(node: Node2D) -> bool:
	return not node.has_method("is_functional") or bool(node.call("is_functional"))


## null 或外部修改后的未登记端点暂时停用边，不缓存邻接关系。
func _has_registered_endpoints(edge: HyphaEdge) -> bool:
	if not is_instance_valid(edge.start_node) or not is_instance_valid(edge.end_node):
		return false
	return _is_registered_node(edge.start_node) and _is_registered_node(edge.end_node)


## 移除节点也移除当前关联边，之后登记节点不会恢复这些边。
func _remove_node_registration(node_id: int) -> bool:
	if not _nodes.has(node_id):
		return false
	# 保留 Variant，便于比较已经 free 的端点，而不把它赋给类型化变量。
	var removed_node: Variant = _nodes[node_id]
	var edge_ids: Array[int] = _edge_order.duplicate()
	for edge_id: int in edge_ids:
		var edge: HyphaEdge = _get_registered_edge(edge_id)
		if edge == null or edge.start_node == removed_node or edge.end_node == removed_node:
			_remove_edge_registration(edge_id)
	if is_instance_valid(removed_node):
		var exit_callback: Callable = _node_exit_callbacks[node_id]
		if removed_node.tree_exiting.is_connected(exit_callback):
			removed_node.tree_exiting.disconnect(exit_callback)
		if _node_health_callbacks.has(node_id):
			var health_callback: Callable = _node_health_callbacks[node_id]
			if removed_node.is_connected("health_changed", health_callback):
				removed_node.disconnect("health_changed", health_callback)
	_nodes.erase(node_id)
	_node_exit_callbacks.erase(node_id)
	_node_health_callbacks.erase(node_id)
	if _mother_core_id == node_id:
		_mother_core_id = 0
	return true


## 注销只断开本系统的回调，不释放外部对象。
func _remove_edge_registration(edge_id: int) -> bool:
	if not _edges.has(edge_id):
		return false
	if is_instance_valid(_edges[edge_id]):
		var edge: HyphaEdge = _edges[edge_id]
		var exit_callback: Callable = _edge_exit_callbacks[edge_id]
		if edge.tree_exiting.is_connected(exit_callback):
			edge.tree_exiting.disconnect(exit_callback)
		var traffic_callback: Callable = _edge_traffic_callbacks.get(edge_id, Callable())
		if traffic_callback.is_valid() and edge.traffic_settings_changed.is_connected(traffic_callback):
			edge.traffic_settings_changed.disconnect(traffic_callback)
	_edges.erase(edge_id)
	_edge_order.erase(edge_id)
	_edge_exit_callbacks.erase(edge_id)
	_edge_traffic_callbacks.erase(edge_id)
	return true


## 处理树外直接 free 和尚未触发 tree_exiting 的 queue_free。
func _prune_registrations() -> void:
	var changed: bool = false
	for node_id: int in _nodes.keys():
		if _get_registered_node(node_id) == null:
			changed = _remove_node_registration(node_id) or changed
	var edge_ids: Array[int] = _edge_order.duplicate()
	for edge_id: int in edge_ids:
		if _get_registered_edge(edge_id) == null:
			changed = _remove_edge_registration(edge_id) or changed
	if changed:
		network_changed.emit()


## 查询时建立双向邻接表，边登记顺序决定同层遍历顺序。
func _build_adjacency(units: int = 0, excluded_ids: Dictionary = {}) -> Dictionary[int, Array]:
	var adjacency: Dictionary[int, Array] = {}
	for edge_id: int in _edge_order:
		var edge: HyphaEdge = _get_registered_edge(edge_id)
		if edge == null or not _has_registered_endpoints(edge):
			continue
		if not _node_is_functional(edge.start_node) or not _node_is_functional(edge.end_node):
			continue
		if excluded_ids.has(edge_id):
			continue
		if units > 0 and not can_enter_edge(edge, units):
			continue
		_append_segment(adjacency, edge, edge.start_node, edge.end_node, true)
		_append_segment(adjacency, edge, edge.end_node, edge.start_node, false)
	return adjacency


## 邻接项直接保存有方向的路线段，反向行进时交换端点。
func _append_segment(adjacency: Dictionary[int, Array], edge: HyphaEdge,
		start: Node2D, end: Node2D, forward: bool) -> void:
	var segment: NetworkRoute.Segment = NetworkRoute.Segment.new()
	segment.edge = edge
	segment.start_node = start
	segment.end_node = end
	segment.forward = forward
	var node_id: int = start.get_instance_id()
	if not adjacency.has(node_id):
		adjacency[node_id] = []
	adjacency[node_id].append(segment)


## BFS 每个节点最多入队一次，返回最少边数且无环的路线。
func _find_segments(start_id: int, end_id: int, units: int = 0,
		excluded_ids: Dictionary = {}) -> Array[NetworkRoute.Segment]:
	var adjacency: Dictionary[int, Array] = _build_adjacency(units, excluded_ids)
	var queue: Array[int] = [start_id]
	var visited: Dictionary[int, bool] = {start_id: true}
	var previous: Dictionary[int, NetworkRoute.Segment] = {}
	var queue_index: int = 0
	while queue_index < queue.size() and not visited.has(end_id):
		var node_id: int = queue[queue_index]
		queue_index += 1
		if not adjacency.has(node_id):
			continue
		for segment: NetworkRoute.Segment in adjacency[node_id]:
			var next_id: int = segment.end_node.get_instance_id()
			if visited.has(next_id):
				continue
			visited[next_id] = true
			previous[next_id] = segment
			queue.append(next_id)
	return _trace_segments(start_id, end_id, previous)


## 从终点追溯首次到达的边，再反转为实际行进顺序。
func _trace_segments(start_id: int, end_id: int,
		previous: Dictionary[int, NetworkRoute.Segment]) -> Array[NetworkRoute.Segment]:
	if not previous.has(end_id):
		return []
	var segments: Array[NetworkRoute.Segment] = []
	var node_id: int = end_id
	while node_id != start_id:
		var segment: NetworkRoute.Segment = previous[node_id]
		segments.append(segment)
		node_id = segment.start_node.get_instance_id()
	segments.reverse()
	return segments
