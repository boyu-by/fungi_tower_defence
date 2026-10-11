class_name GrowthPlanner extends Resource
## 为无障碍的直线主枝提供分段、节点位置和统一费用，不创建场景对象。

const MAX_SEGMENTS: int = 100000
const MAX_INTEGER_COST: int = 9223372036854775807
# 只吸附正整数单位边界，最多 0.00001 像素，且不超过单位长度的百万分之一。
# 这用于 Vector2 的表示误差；零距离仍严格判断，正的短距离至少算一个单位。
const BOUNDARY_EPSILON: float = 0.00001
const RELATIVE_BOUNDARY_EPSILON: float = 0.000001

@export var junction_cost: int = 4
@export var extension_unit_length: float = 80.0
@export var junction_spacing: float = 120.0


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
