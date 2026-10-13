class_name GrowthPlanner extends Resource
## 为直线或地形路线提供分段、节点位置和统一费用，不创建场景对象。

const MAX_SEGMENTS: int = 100000
const MAX_INTEGER_COST: int = 9223372036854775807
# 只吸附正整数单位边界，最多 0.00001 像素，且不超过单位长度的百万分之一。
# 这用于 Vector2 的表示误差；零距离仍严格判断，正的短距离至少算一个单位。
const BOUNDARY_EPSILON: float = 0.00001
const RELATIVE_BOUNDARY_EPSILON: float = 0.000001
const TERRAIN_CLEARANCE: float = 10.0
const MAX_BRANCH_LENGTH: float = 48.0

@export var junction_cost: int = 4
@export var extension_unit_length: float = 80.0
@export var junction_spacing: float = 120.0
@export var bounded_branches_enabled: bool = false
@export var auto_join_enabled: bool = false
@export var branch_length: float = 40.0
@export var auto_join_radius: float = 24.0

## 由关卡注入；所有建设尖端共用同一规划器和固定地形。
var terrain_navigation: TerrainNavigation = null


func plan(
	start_position: Vector2, end_position: Vector2, endpoint_exists: bool = false
) -> Dictionary:
	if not start_position.is_finite() or not end_position.is_finite():
		return _empty_result(start_position, end_position, "Coordinates must be finite.")
	if not is_finite(extension_unit_length) or extension_unit_length <= 0.0:
		return _empty_result(start_position, end_position, "Extension unit must be finite and positive.")
	if not is_finite(junction_spacing) or junction_spacing <= 0.0:
		return _empty_result(start_position, end_position, "Junction spacing must be finite and positive.")
	if junction_cost < 0:
		return _empty_result(start_position, end_position, "Junction cost must be nonnegative.")
	if terrain_navigation != null:
		return _plan_terrain(start_position, end_position, endpoint_exists)

	# 用标量浮点计算，避免 Vector2 的单精度平方或坐标相减溢出。
	var delta_x: float = float(end_position.x) - float(start_position.x)
	var delta_y: float = float(end_position.y) - float(start_position.y)
	var distance: float = _distance(delta_x, delta_y)
	if not is_finite(distance):
		return _empty_result(start_position, end_position, "Distance exceeds the finite numeric range.")
	if distance == 0.0:
		var empty_result: Dictionary = _empty_result(start_position, end_position, "")
		empty_result["valid"] = true
		return empty_result

	var segment_units: float = _ceil_units(distance, junction_spacing)
	# 先检查段数，再转换为整数或分配数组；有限但极大的输入也不会耗尽内存。
	if not is_finite(segment_units) or segment_units > float(MAX_SEGMENTS):
		return _empty_result(start_position, end_position, "Plan exceeds the 100000 segment limit.")
	var extension_units: float = _ceil_units(distance, extension_unit_length)
	# INT64_MAX 转为 float 后是 2^63，不能再安全地转回 int。
	if not is_finite(extension_units) or extension_units >= float(MAX_INTEGER_COST):
		return _empty_result(start_position, end_position, "Extension cost exceeds the integer range.")

	var segment_count: int = int(segment_units)
	var new_junction_count: int = segment_count - (1 if endpoint_exists else 0)
	var total_extension_cost: int = int(extension_units)
	var remaining_cost_range: int = MAX_INTEGER_COST - total_extension_cost
	if new_junction_count > 0:
		@warning_ignore("integer_division")
		var maximum_junction_cost: int = remaining_cost_range / new_junction_count
		if junction_cost > maximum_junction_cost:
			return _empty_result(start_position, end_position, "Total cost exceeds the integer range.")

	var segments: Array[Dictionary] = []
	var junction_positions: PackedVector2Array = PackedVector2Array()
	var previous_position: Vector2 = start_position
	var previous_distance: float = 0.0
	# 以整数索引计算每个分界，避免不断累加浮点间距导致循环不能前进。
	for junction_index: int in range(1, segment_count):
		var cumulative_distance: float = float(junction_index) * junction_spacing
		var fraction: float = cumulative_distance / distance
		var junction_position: Vector2 = Vector2(
			float(start_position.x) + delta_x * fraction,
			float(start_position.y) + delta_y * fraction
		)
		# 坐标过大或间距过小时，Vector2 可能无法表示不同节点；不返回重合的新节点。
		if junction_position == previous_position or junction_position == end_position:
			return _empty_result(
				start_position, end_position, "Junction spacing is below the coordinate precision."
			)
		segments.append(_make_segment(
			previous_position, junction_position, previous_distance, cumulative_distance, junction_cost
		))
		junction_positions.append(junction_position)
		previous_position = junction_position
		previous_distance = cumulative_distance

	var endpoint_cost: int = 0 if endpoint_exists else junction_cost
	segments.append(_make_segment(
		previous_position, end_position, previous_distance, distance, endpoint_cost
	))
	if not endpoint_exists:
		junction_positions.append(end_position)

	var total_junction_cost: int = new_junction_count * junction_cost
	return {
		"valid": true,
		"error": "",
		"start_position": start_position,
		"end_position": end_position,
		"distance": distance,
		"segments": segments,
		"junction_positions": junction_positions,
		"extension_cost": total_extension_cost,
		"junction_cost": total_junction_cost,
		"total_cost": total_extension_cost + total_junction_cost,
	}


## 普通生长的预览与实际建设共用此入口；L 连接仍使用 plan 的原定终点。
func plan_growth(
	start_position: Vector2, requested_position: Vector2,
	network: NetworkSystem, start_node: Node2D = null
) -> Dictionary:
	var result: Dictionary = plan(start_position, requested_position)
	var join_node: HyphaNode = null
	if not bool(result.get("valid", false)):
		return result
	if auto_join_enabled:
		if not is_finite(auto_join_radius) or auto_join_radius < 0.0:
			return _empty_result(start_position, requested_position, "自动接入范围无效。")
		if not is_instance_valid(network) or network.is_queued_for_deletion():
			return _empty_result(start_position, requested_position, "自动接入网络不可用。")
		var nearest_distance: float = INF
		for candidate: Node2D in network.get_registered_nodes():
			if not candidate is HyphaNode or not _join_node_is_usable(candidate, start_position, start_node):
				continue
			var distance: float = candidate.global_position.distance_to(requested_position)
			if distance > auto_join_radius:
				continue
			if is_instance_valid(start_node) and network.has_direct_connection(start_node, candidate):
				if distance == 0.0:
					return _empty_result(start_position, requested_position, "两个菌结已有连接；未重复建设。")
				continue
			if not _join_node_is_usable(candidate, start_position, start_node) or not network.is_node_registered(candidate):
				continue
			var snapped: Dictionary = plan(start_position, candidate.global_position, true)
			if not bool(snapped.get("valid", false)):
				continue
			var nearer: bool = distance < nearest_distance
			var tie: bool = distance == nearest_distance and is_instance_valid(join_node)
			if nearer or (tie and candidate.get_instance_id() < join_node.get_instance_id()):
				join_node = candidate as HyphaNode
				nearest_distance = distance
				result = snapped
	result["requested_position"] = requested_position
	result["effective_point"] = result["end_position"]
	result["join_node"] = join_node
	result["branch_count"] = 0
	result["branch_distance"] = 0.0
	result["branches"] = []
	result["main_distance"] = result["distance"]
	if not bool(result["valid"]) or float(result["distance"]) <= 0.0:
		return result
	var main_segments: Array[Dictionary] = result["segments"]
	for main_index: int in range(main_segments.size()):
		main_segments[main_index]["is_branch"] = false
		main_segments[main_index]["main_segment_index"] = main_index
	if is_instance_valid(join_node):
		main_segments[-1]["endpoint_node"] = join_node
	if bounded_branches_enabled:
		if not is_finite(branch_length) or branch_length <= 0.0 or branch_length > MAX_BRANCH_LENGTH:
			return _empty_result(start_position, requested_position, "短侧枝长度必须在 0 到 48 像素内。")
		result = _add_bounded_branches(result, network)
	return result


func _join_node_is_usable(candidate: Node2D, start_position: Vector2, start_node: Node2D) -> bool:
	return is_instance_valid(candidate) and not candidate.is_queued_for_deletion() \
		and candidate != start_node and candidate.global_position.is_finite() \
		and candidate.global_position != start_position and (candidate as HyphaNode).is_functional()


## 每个非终点主段至多一条侧枝；侧枝自身不再规划分枝，费用全部进入同一报价。
func _add_bounded_branches(result: Dictionary, network: NetworkSystem) -> Dictionary:
	var main_segments: Array[Dictionary] = result["segments"]
	var segments: Array[Dictionary] = []
	var branches: Array[Dictionary] = []
	var junction_positions: PackedVector2Array = PackedVector2Array()
	var blocked_points: PackedVector2Array = result["junction_positions"].duplicate()
	blocked_points.append(result["start_position"])
	if is_instance_valid(network) and not network.is_queued_for_deletion():
		for node: Node2D in network.get_registered_nodes():
			if is_instance_valid(node) and not node.is_queued_for_deletion() and node.global_position.is_finite():
				blocked_points.append(node.global_position)
	var cumulative_distance: float = 0.0
	var extra_extension: int = 0
	var extra_junctions: int = 0
	var branch_distance: float = 0.0
	for main_index: int in range(main_segments.size()):
		var segment: Dictionary = main_segments[main_index].duplicate(true)
		cumulative_distance += float(segment["length"])
		segment["cumulative_distance"] = cumulative_distance
		segments.append(segment)
		if not segment.has("endpoint_node"):
			junction_positions.append(segment["end_position"])
		if main_index >= main_segments.size() - 1 \
				or segments.size() + main_segments.size() - main_index >= MAX_SEGMENTS:
			continue
		var start: Vector2 = segment["start_position"]
		var junction: Vector2 = segment["end_position"]
		var direction: Vector2 = start.direction_to(junction)
		var perpendicular: Vector2 = Vector2(-direction.y, direction.x)
		var side: float = 1.0 if main_index % 2 == 0 else -1.0
		var endpoint: Vector2 = junction + perpendicular * branch_length * side
		if not _branch_is_clear(junction, endpoint, blocked_points):
			endpoint = junction - perpendicular * branch_length * side
		if not _branch_is_clear(junction, endpoint, blocked_points):
			continue
		var real_length: float = _distance(float(endpoint.x) - float(junction.x), float(endpoint.y) - float(junction.y))
		var extension_units: float = _ceil_units(real_length, extension_unit_length)
		if not is_finite(extension_units) or extension_units >= float(MAX_INTEGER_COST):
			return _empty_result(result["start_position"], result["requested_position"], "侧枝费用超出整数范围。")
		var extension: int = int(extension_units)
		if int(result["total_cost"]) > MAX_INTEGER_COST - extra_extension - extra_junctions \
				or extension > MAX_INTEGER_COST - int(result["total_cost"]) - extra_extension - extra_junctions \
				or junction_cost > MAX_INTEGER_COST - int(result["total_cost"]) - extra_extension - extra_junctions - extension:
			return _empty_result(result["start_position"], result["requested_position"], "侧枝总费用超出整数范围。")
		cumulative_distance += real_length
		var branch: Dictionary = {
			"start_position": junction, "end_position": endpoint, "length": real_length,
			"cumulative_distance": cumulative_distance, "extension_cost": extension,
			"junction_cost": junction_cost, "total_cost": extension + junction_cost,
			"is_branch": true, "main_segment_index": main_index, "resume_position": junction,
		}
		segments.append(branch)
		branches.append(branch.duplicate(true))
		junction_positions.append(endpoint)
		blocked_points.append(endpoint)
		extra_extension += extension
		extra_junctions += junction_cost
		branch_distance += real_length
	result["segments"] = segments
	result["junction_positions"] = junction_positions
	result["branches"] = branches
	result["branch_count"] = branches.size()
	result["branch_distance"] = branch_distance
	result["distance"] = cumulative_distance
	result["extension_cost"] = int(result["extension_cost"]) + extra_extension
	result["junction_cost"] = int(result["junction_cost"]) + extra_junctions
	result["total_cost"] = int(result["total_cost"]) + extra_extension + extra_junctions
	return result


func _branch_is_clear(start: Vector2, end: Vector2, blocked_points: PackedVector2Array) -> bool:
	if not end.is_finite() or start == end or start.distance_to(end) > MAX_BRANCH_LENGTH + BOUNDARY_EPSILON:
		return false
	if terrain_navigation != null and (not is_instance_valid(terrain_navigation) \
			or not terrain_navigation.is_segment_clear(start, end, TERRAIN_CLEARANCE)):
		return false
	for point: Vector2 in blocked_points:
		if end.distance_to(point) <= TERRAIN_CLEARANCE:
			return false
	return true


func _plan_terrain(start_position: Vector2, end_position: Vector2, endpoint_exists: bool) -> Dictionary:
	if not is_instance_valid(terrain_navigation) or terrain_navigation.is_queued_for_deletion():
		return _empty_result(start_position, end_position, "地形规划不可用。")
	if not terrain_navigation.is_point_walkable(start_position, TERRAIN_CLEARANCE):
		return _empty_result(start_position, end_position, "起点在岩石内或战场边界外。")
	if not terrain_navigation.is_point_walkable(end_position, TERRAIN_CLEARANCE):
		return _empty_result(start_position, end_position, "目标在岩石内或战场边界外；未扣款。")
	var path: PackedVector2Array = terrain_navigation.find_path(start_position, end_position, TERRAIN_CLEARANCE)
	if path.is_empty() or path[0] != start_position or path[-1] != end_position:
		return _empty_result(start_position, end_position, "没有可行的绕行路径；未扣款。")
	if start_position == end_position:
		var empty_result: Dictionary = _empty_result(start_position, end_position, "")
		empty_result["valid"] = true
		return empty_result

	var cumulative: PackedFloat64Array = PackedFloat64Array([0.0])
	var distance: float = 0.0
	for path_index: int in range(1, path.size()):
		var start: Vector2 = path[path_index - 1]
		var end: Vector2 = path[path_index]
		var length: float = _distance(float(end.x) - float(start.x), float(end.y) - float(start.y))
		if length <= 0.0 or not terrain_navigation.is_segment_clear(start, end, TERRAIN_CLEARANCE):
			return _empty_result(start_position, end_position, "地形路线含不可通行路段。")
		distance += length
		cumulative.append(distance)
	if not is_finite(distance):
		return _empty_result(start_position, end_position, "Distance exceeds the finite numeric range.")
	var spacing_units: float = _ceil_units(distance, junction_spacing)
	if not is_finite(spacing_units) or spacing_units > float(MAX_SEGMENTS):
		return _empty_result(start_position, end_position, "Plan exceeds the 100000 segment limit.")
	var extension_units: float = _ceil_units(distance, extension_unit_length)
	if not is_finite(extension_units) or extension_units >= float(MAX_INTEGER_COST):
		return _empty_result(start_position, end_position, "Extension cost exceeds the integer range.")

	# 合并全路线等距点与真实转角；重合时保留精确转角，不收费两次。
	var positions: PackedVector2Array = PackedVector2Array()
	var distances: PackedFloat64Array = PackedFloat64Array()
	var corner_index: int = 1
	var spacing_index: int = 1
	var spacing_count: int = int(spacing_units)
	var tolerance: float = minf(BOUNDARY_EPSILON, junction_spacing * RELATIVE_BOUNDARY_EPSILON)
	var previous_position: Vector2 = start_position
	while corner_index < path.size():
		var corner_distance: float = cumulative[corner_index]
		var spacing_distance: float = float(spacing_index) * junction_spacing if spacing_index < spacing_count else INF
		var position: Vector2 = path[corner_index]
		var marker_distance: float = corner_distance
		if spacing_distance < corner_distance - tolerance:
			var segment_start: Vector2 = path[corner_index - 1]
			var fraction: float = (spacing_distance - cumulative[corner_index - 1]) \
				/ (corner_distance - cumulative[corner_index - 1])
			position = segment_start.lerp(path[corner_index], fraction)
			marker_distance = spacing_distance
			spacing_index += 1
		else:
			if absf(spacing_distance - corner_distance) <= tolerance:
				spacing_index += 1
			corner_index += 1
		if position == previous_position or not terrain_navigation.is_segment_clear(
				previous_position, position, TERRAIN_CLEARANCE):
			return _empty_result(start_position, end_position, "Junction spacing is below the coordinate precision.")
		positions.append(position)
		distances.append(marker_distance)
		previous_position = position
		if positions.size() > MAX_SEGMENTS:
			return _empty_result(start_position, end_position, "Plan exceeds the 100000 segment limit.")

	var total_extension_cost: int = int(extension_units)
	var new_junction_count: int = positions.size() - (1 if endpoint_exists else 0)
	var remaining_cost_range: int = MAX_INTEGER_COST - total_extension_cost
	if new_junction_count > 0:
		@warning_ignore("integer_division")
		var maximum_junction_cost: int = remaining_cost_range / new_junction_count
		if junction_cost > maximum_junction_cost:
			return _empty_result(start_position, end_position, "Total cost exceeds the integer range.")
	var segments: Array[Dictionary] = []
	var junction_positions: PackedVector2Array = PackedVector2Array()
	previous_position = start_position
	var previous_distance: float = 0.0
	for position_index: int in range(positions.size()):
		var is_existing_end: bool = endpoint_exists and position_index == positions.size() - 1
		segments.append(_make_segment(previous_position, positions[position_index], previous_distance,
			distances[position_index], 0 if is_existing_end else junction_cost))
		if not is_existing_end:
			junction_positions.append(positions[position_index])
		previous_position = positions[position_index]
		previous_distance = distances[position_index]
	var total_junction_cost: int = new_junction_count * junction_cost
	return {
		"valid": true, "error": "", "start_position": start_position, "end_position": end_position,
		"distance": distance, "segments": segments, "junction_positions": junction_positions,
		"extension_cost": total_extension_cost, "junction_cost": total_junction_cost,
		"total_cost": total_extension_cost + total_junction_cost,
	}


func _empty_result(start_position: Vector2, end_position: Vector2, error: String) -> Dictionary:
	var segments: Array[Dictionary] = []
	return {
		"valid": false,
		"error": error,
		"start_position": start_position,
		"end_position": end_position,
		"distance": 0.0,
		"segments": segments,
		"junction_positions": PackedVector2Array(),
		"extension_cost": 0,
		"junction_cost": 0,
		"total_cost": 0,
	}


func _distance(delta_x: float, delta_y: float) -> float:
	var scale: float = maxf(absf(delta_x), absf(delta_y))
	if scale == 0.0:
		return 0.0
	if not is_finite(scale):
		return INF
	var scaled_x: float = delta_x / scale
	var scaled_y: float = delta_y / scale
	return scale * sqrt(scaled_x * scaled_x + scaled_y * scaled_y)


func _ceil_units(distance: float, unit_length: float) -> float:
	if distance == 0.0:
		return 0.0
	var ratio: float = distance / unit_length
	if not is_finite(ratio):
		return INF
	var nearest_count: float = round(ratio)
	var tolerance: float = minf(BOUNDARY_EPSILON, unit_length * RELATIVE_BOUNDARY_EPSILON)
	if nearest_count >= 1.0 and absf(distance - nearest_count * unit_length) <= tolerance:
		return nearest_count
	return maxf(1.0, ceil(ratio))


func _make_segment(
	start_position: Vector2,
	end_position: Vector2,
	cumulative_start: float,
	cumulative_end: float,
	new_junction_cost: int
) -> Dictionary:
	var extension_start: int = int(_ceil_units(cumulative_start, extension_unit_length))
	var extension_end: int = int(_ceil_units(cumulative_end, extension_unit_length))
	var segment_extension_cost: int = extension_end - extension_start
	return {
		"start_position": start_position,
		"end_position": end_position,
		"length": cumulative_end - cumulative_start,
		"cumulative_distance": cumulative_end,
		"extension_cost": segment_extension_cost,
		"junction_cost": new_junction_cost,
		"total_cost": segment_extension_cost + new_junction_cost,
	}
