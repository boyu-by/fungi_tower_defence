class_name TransportRouter
extends Node

## 只计算运输路线，不申请通行或操作营养库存。
## 边成本为行进秒数加调度器的名义排队估计，估计不是实际到达时间保证。

@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
var excluded_edges: Array[HyphaEdge] = []


func find_route(
	start: Node2D, end: Node2D, cargo_kind: StringName = &"supply", speed: float = 150.0
) -> Dictionary:
	var result: Dictionary = _empty_result(start, end)
	var units: int = NetworkTrafficSystem.units_for_kind(cargo_kind)
	result["units"] = units
	if units <= 0:
		result["reason"] = &"invalid_cargo_kind"
		return result
	if not is_finite(speed) or speed <= 0.0:
		result["reason"] = &"invalid_speed"
		return result
	if not is_instance_valid(network_system) or network_system.is_queued_for_deletion() \
			or not is_instance_valid(traffic_system) or traffic_system.is_queued_for_deletion() \
			or traffic_system.network_system != network_system:
		result["reason"] = &"invalid_configuration"
		return result
	if not is_instance_valid(start) or not is_instance_valid(end) \
			or not network_system.is_node_registered(start) or not network_system.is_node_registered(end):
		result["reason"] = &"invalid_endpoints"
		return result

	var route: NetworkRoute = result["route"]
	if start == end:
		route.found = true
		result["found"] = true
		result["reason"] = &""
		return result

	var topology: Dictionary = network_system.get_topology_snapshot()
	var adjacency: Dictionary[int, Array] = _build_adjacency(topology, units, speed)
	var previous: Dictionary[int, Dictionary] = _find_previous(
		start.get_instance_id(), end.get_instance_id(), adjacency
	)
	if not previous.has(end.get_instance_id()):
		result["reason"] = &"no_route"
		return result

	_fill_route_result(result, previous, start.get_instance_id(), end.get_instance_id())
	return result


func _empty_result(start: Node2D, end: Node2D) -> Dictionary:
	var route: NetworkRoute = NetworkRoute.new()
	if is_instance_valid(start):
		route.start_node = start
	if is_instance_valid(end):
		route.end_node = end
	return {
		"found": false,
		"route": route,
		"total_distance": 0.0,
		"travel_seconds": 0.0,
		"estimated_wait_seconds": 0.0,
		"total_cost_seconds": 0.0,
		"units": 0,
		"reason": &"no_route",
	}


## 按边登记顺序构造双向邻接；成本只读取现有队列，不触发刷新或授予。
func _build_adjacency(topology: Dictionary, units: int, speed: float) -> Dictionary[int, Array]:
	var adjacency: Dictionary[int, Array] = {}
	for row: Dictionary in topology["edges"]:
		var edge: HyphaEdge = row["edge"]
		if excluded_edges.has(edge):
			continue
		if not network_system.can_enter_edge(edge, units):
			continue
		var length: float = float(row["length"])
		if not is_finite(length) or length < 0.0:
			continue
		var travel_seconds: float = length / speed
		var wait_seconds: float = traffic_system.estimate_wait_seconds(edge, units, speed)
		var cost: float = travel_seconds + wait_seconds
		if not is_finite(cost) or wait_seconds < 0.0:
			continue
		_append_arc(adjacency, row, true, travel_seconds, wait_seconds, cost)
		_append_arc(adjacency, row, false, travel_seconds, wait_seconds, cost)
	return adjacency


func _append_arc(
	adjacency: Dictionary[int, Array], row: Dictionary, forward: bool,
	travel_seconds: float, wait_seconds: float, cost: float
) -> void:
	var start_id: int = int(row["start_id"] if forward else row["end_id"])
	var end_id: int = int(row["end_id"] if forward else row["start_id"])
	if not adjacency.has(start_id):
		adjacency[start_id] = []
	adjacency[start_id].append({
		"edge": row["edge"],
		"start_node": row["start_node"] if forward else row["end_node"],
		"end_node": row["end_node"] if forward else row["start_node"],
		"start_id": start_id,
		"end_id": end_id,
		"forward": forward,
		"length": row["length"],
		"travel_seconds": travel_seconds,
		"wait_seconds": wait_seconds,
		"cost": cost,
	})


## 开放表保持首次发现顺序；相等成本不替换前驱，零长度环也不会重复节点。
func _find_previous(
	start_id: int, end_id: int, adjacency: Dictionary[int, Array]
) -> Dictionary[int, Dictionary]:
	var costs: Dictionary[int, float] = {start_id: 0.0}
	var settled: Dictionary[int, bool] = {}
	var discovered: Dictionary[int, bool] = {start_id: true}
	var previous: Dictionary[int, Dictionary] = {}
	var open_nodes: Array[int] = [start_id]
	while not open_nodes.is_empty():
		var best_index: int = 0
		for index: int in range(1, open_nodes.size()):
			if costs[open_nodes[index]] < costs[open_nodes[best_index]]:
				best_index = index
		var node_id: int = open_nodes[best_index]
		open_nodes.remove_at(best_index)
		settled[node_id] = true
		if node_id == end_id:
			break
		if not adjacency.has(node_id):
			continue
		for arc: Dictionary in adjacency[node_id]:
			var next_id: int = int(arc["end_id"])
			if settled.has(next_id):
				continue
			var next_cost: float = costs[node_id] + float(arc["cost"])
			if not is_finite(next_cost) or (costs.has(next_id) and next_cost >= costs[next_id]):
				continue
			costs[next_id] = next_cost
			previous[next_id] = arc
			if not discovered.has(next_id):
				discovered[next_id] = true
				open_nodes.append(next_id)
	return previous


func _fill_route_result(
	result: Dictionary, previous: Dictionary[int, Dictionary], start_id: int, end_id: int
) -> void:
	var route: NetworkRoute = result["route"]
	var arcs: Array[Dictionary] = []
	var cursor_id: int = end_id
	while cursor_id != start_id:
		var arc: Dictionary = previous[cursor_id]
		arcs.append(arc)
		cursor_id = int(arc["start_id"])
	arcs.reverse()
	var total_distance: float = 0.0
	var travel_seconds: float = 0.0
	var wait_seconds: float = 0.0
	for arc: Dictionary in arcs:
		var segment: NetworkRoute.Segment = NetworkRoute.Segment.new()
		segment.edge = arc["edge"]
		segment.start_node = arc["start_node"]
		segment.end_node = arc["end_node"]
		segment.forward = bool(arc["forward"])
		route.segments.append(segment)
		total_distance += float(arc["length"])
		travel_seconds += float(arc["travel_seconds"])
		wait_seconds += float(arc["wait_seconds"])
	route.found = true
	result["found"] = true
	result["total_distance"] = total_distance
	result["travel_seconds"] = travel_seconds
	result["estimated_wait_seconds"] = wait_seconds
	result["total_cost_seconds"] = travel_seconds + wait_seconds
	result["reason"] = &""
