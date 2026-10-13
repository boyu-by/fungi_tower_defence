class_name FungalField
extends Node2D

## 外部传入连接快照；本节点只管理覆盖扩张、断连残影和采集候选查询。
## 候选节点互为替代者，不代表多个资源所有者；查询不会领取或修改资源。

const FILL_COLOR: Color = Color(0.075, 0.19, 0.155, 1.0)
const BOUNDARY_COLOR: Color = Color(0.22, 0.43, 0.33, 0.85)
const BOUNDARY_WIDTH: float = 1.5
const CIRCLE_STEPS: int = 96
const ARC_EPSILON: float = 0.00001
const DISCONNECT_GRACE_SECONDS: float = 5.0
const DECAY_SECONDS: float = 10.0
const BRIGHTNESS_RECOVERY_SPEED: float = 0.5
const REMNANT_FILL_COLOR: Color = Color(0.13, 0.13, 0.13, 0.7)
const REMNANT_BOUNDARY_COLOR: Color = Color(0.48, 0.48, 0.48, 0.8)
const REMNANT_DASH_STEPS: int = 48
const REMNANT_DASH_RATIO: float = 0.55

@export var core_radius: float = 140.0:
	set(value):
		core_radius = _usable_radius(value)
		_clamp_radii()
		queue_redraw()

@export var node_radius: float = 110.0:
	set(value):
		node_radius = _usable_radius(value)
		_clamp_radii()
		queue_redraw()

@export var expansion_speed: float = 140.0:
	set(value):
		expansion_speed = _usable_radius(value)

var _sources: Dictionary[int, SourceState] = {}


class SourceState:
	extends RefCounted

	var node_ref: WeakRef
	var kind: StringName = &""
	var connected: bool = false
	var has_radius_override: bool = false
	var radius_override: float = 0.0
	var display_radius: float = 0.0
	var brightness: float = 0.0
	var disconnected_seconds: float = 0.0
	var loss_radius: float = 0.0
	var loss_brightness: float = 0.0
	var recovering: bool = false


func _process(delta: float) -> void:
	advance(delta)


func _draw() -> void:
	var world_transform: Transform2D = global_transform
	if not world_transform.is_finite() or world_transform.determinant() == 0.0:
		return

	# 抵消本节点及其父节点的变换，让圆半径和线宽始终使用世界像素。
	draw_set_transform_matrix(_get_world_draw_transform())
	# 灰色虚线及叉号从断连瞬间出现；有效覆盖的不透明填充始终画在上层。
	_draw_remnants(_get_remnant_discs())
	var discs: Array[Dictionary] = _get_draw_discs()
	for disc: Dictionary in _get_fill_discs(discs):
		var center: Vector2 = disc["center"]
		var radius: float = disc["radius"]
		# 不透明填充不会叠加亮度；暗盘先画以保留更亮的重叠覆盖。
		var brightness: float = disc["brightness"]
		var fill: Color = Color(FILL_COLOR.r * brightness, FILL_COLOR.g * brightness,
			FILL_COLOR.b * brightness, FILL_COLOR.a)
		draw_circle(center, radius, fill, true, -1.0, true)

	for index: int in range(discs.size()):
		var disc: Dictionary = discs[index]
		var center: Vector2 = disc["center"]
		var radius: float = disc["radius"]
		var brightness: float = disc["brightness"]
		var boundary: Color = Color(BOUNDARY_COLOR.r, BOUNDARY_COLOR.g,
			BOUNDARY_COLOR.b, BOUNDARY_COLOR.a * brightness)
		for arc: Vector2 in _get_exposed_arcs(index, discs):
			var point_count: int = maxi(2, int(ceil((arc.y - arc.x) / TAU * CIRCLE_STEPS)) + 1)
			draw_arc(center, radius, arc.x, arc.y, point_count,
				boundary, BOUNDARY_WIDTH, true)


## 替换快照；同一节点的首个有效记录生效，后续重复记录忽略。
func set_sources(sources: Array[Dictionary]) -> void:
	var replacement: Dictionary[int, SourceState] = {}
	for snapshot: Dictionary in sources:
		var raw_node: Variant = snapshot.get("node")
		if not is_instance_valid(raw_node) or not raw_node is Node2D:
			continue
		var source_node: Node2D = raw_node as Node2D
		if source_node.is_queued_for_deletion():
			continue
		var kind: StringName = _read_kind(snapshot.get("kind", &""))
		if kind != &"core" and kind != &"junction":
			continue
		var instance_id: int = source_node.get_instance_id()
		if replacement.has(instance_id):
			continue

		var connection: Variant = snapshot.get("connected", false)
		var connected: bool = connection is bool and bool(connection) and _source_is_functional(source_node)
		var state: SourceState = _sources.get(instance_id) as SourceState
		if state == null:
			state = SourceState.new()
			state.node_ref = weakref(source_node)
			state.connected = connected
			state.brightness = 1.0 if connected else 0.0
		else:
			_update_connection(state, connected)
		state.kind = kind
		state.has_radius_override = snapshot.has("radius")
		state.radius_override = _read_radius(snapshot.get("radius", 0.0))
		replacement[instance_id] = state

	_sources = replacement
	_clamp_radii()
	queue_redraw()


## 可由测试或调用者显式推进；负数、NaN 和无穷 delta 不会推进任何计时。
func advance(delta: float) -> void:
	var can_advance: bool = is_finite(delta) and delta > 0.0
	var removed: Array[int] = []
	for instance_id: int in _sources:
		var state: SourceState = _sources[instance_id]
		if _get_valid_node(state) == null:
			removed.append(instance_id)
		else:
			if state.connected and not _source_is_functional(_get_valid_node(state)):
				_update_connection(state, false)
			if not can_advance:
				continue
			if state.connected:
				_advance_connected(state, delta)
			else:
				_advance_disconnected(state, delta)
	for instance_id: int in removed:
		_sources.erase(instance_id)
	# 节点可独立移动或释放，即使半径未变化也要重新采样绘制。
	queue_redraw()


func get_effective_radius(node: Node2D) -> float:
	if not is_instance_valid(node):
		return 0.0
	var state: SourceState = _sources.get(node.get_instance_id()) as SourceState
	if state == null:
		return 0.0
	return _get_state_radius(state)


## 返回新的只读快照容器；调用者修改字典不会改变场域状态。
func get_source_snapshot(node: Node2D) -> Dictionary:
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return {}
	var state: SourceState = _sources.get(node.get_instance_id()) as SourceState
	if state == null or _get_valid_node(state) != node:
		return {}
	return _make_source_snapshot(state, node)


## 包含仍有效的节点及其残影；gone 状态保留供观察，零半径不实际绘制。
func get_visual_snapshot() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for state: SourceState in _sources.values():
		var source_node: Node2D = _get_valid_node(state)
		if source_node != null:
			snapshots.append(_make_source_snapshot(state, source_node))
	return snapshots


func is_covered(world_position: Vector2) -> bool:
	if not world_position.is_finite():
		return false
	var covered: bool = false
	for disc: Dictionary in _get_draw_discs():
		if _disc_contains(disc, world_position):
			covered = true
	return covered


## 返回唯一、有序的替代候选；调用者负责选择其中一个并结算资源。
func get_collecting_nodes(world_position: Vector2) -> Array[Node2D]:
	var result: Array[Node2D] = []
	if not world_position.is_finite():
		return result
	var candidates: Array[Dictionary] = []
	for disc: Dictionary in _get_draw_discs():
		if _disc_contains(disc, world_position):
			var center: Vector2 = disc["center"]
			candidates.append({
				"node": disc["node"],
				"distance_squared": _distance_squared(center, world_position),
				"instance_id": disc["instance_id"],
			})
	candidates.sort_custom(_candidate_precedes)
	for candidate: Dictionary in candidates:
		var source_node: Node2D = candidate["node"]
		result.append(source_node)
	return result


## 重叠覆盖只有一个首选采集节点；本查询不实际领取资源。
func get_collection_node(world_position: Vector2) -> Node2D:
	var candidates: Array[Node2D] = get_collecting_nodes(world_position)
	return null if candidates.is_empty() else candidates[0]


func _usable_radius(value: float) -> float:
	if not is_finite(value) or not Vector2(value, 0.0).is_finite():
		return 0.0
	return maxf(value, 0.0)


func _read_radius(value: Variant) -> float:
	if not value is float and not value is int:
		return 0.0
	return _usable_radius(float(value))


func _read_kind(value: Variant) -> StringName:
	if not value is StringName and not value is String:
		return &""
	return StringName(value)


func _get_target_radius(state: SourceState) -> float:
	if state.has_radius_override:
		return state.radius_override
	return core_radius if state.kind == &"core" else node_radius


func _get_eligible_node(state: SourceState) -> Node2D:
	if not state.connected:
		return null
	var source_node: Node2D = _get_valid_node(state)
	return source_node if source_node != null and _source_is_functional(source_node) else null


func _source_is_functional(source_node: Node2D) -> bool:
	return not source_node.has_method("is_functional") or bool(source_node.call("is_functional"))


func _get_valid_node(state: SourceState) -> Node2D:
	var source_node: Node2D = state.node_ref.get_ref() as Node2D
	if not is_instance_valid(source_node) or source_node.is_queued_for_deletion():
		return null
	if not source_node.global_position.is_finite():
		return null
	return source_node


func _get_state_radius(state: SourceState) -> float:
	if _get_eligible_node(state) == null:
		return 0.0
	return minf(state.display_radius, _get_target_radius(state))


func _clamp_radii() -> void:
	for state: SourceState in _sources.values():
		if state.connected:
			state.display_radius = minf(state.display_radius, _get_target_radius(state))


func _update_connection(state: SourceState, connected: bool) -> void:
	if state.connected == connected:
		return
	state.connected = connected
	state.disconnected_seconds = 0.0
	state.recovering = connected
	if connected:
		# 从当前残影接着扩张、恢复亮度；重复快照不会再次进入此分支。
		state.loss_radius = 0.0
		state.loss_brightness = 0.0
	else:
		state.loss_radius = state.display_radius
		state.loss_brightness = state.brightness if state.display_radius > 0.0 else 0.0
		state.brightness = state.loss_brightness


func _advance_connected(state: SourceState, delta: float) -> void:
	var target_radius: float = _get_target_radius(state)
	state.display_radius = minf(target_radius,
		state.display_radius + expansion_speed * delta)
	if state.recovering:
		state.brightness = minf(1.0, state.brightness + BRIGHTNESS_RECOVERY_SPEED * delta)
		if state.display_radius >= target_radius and state.brightness >= 1.0:
			state.recovering = false


func _advance_disconnected(state: SourceState, delta: float) -> void:
	var elapsed: float = state.disconnected_seconds + delta
	# 极大的有限 delta 相加也可能溢出；仍保存有限计时并完成衰退。
	state.disconnected_seconds = elapsed if is_finite(elapsed) else maxf(
		state.disconnected_seconds, delta)
	var remaining: float = 1.0 - clampf(
		(state.disconnected_seconds - DISCONNECT_GRACE_SECONDS) / DECAY_SECONDS, 0.0, 1.0)
	state.display_radius = state.loss_radius * remaining
	state.brightness = state.loss_brightness * remaining


func _make_source_snapshot(state: SourceState, source_node: Node2D) -> Dictionary:
	var phase: StringName = &"gone"
	var connected: bool = state.connected and _source_is_functional(source_node)
	if connected:
		if state.recovering:
			phase = &"recovering"
		elif state.display_radius < _get_target_radius(state):
			phase = &"growing"
		else:
			phase = &"mature"
	elif state.display_radius > 0.0:
		phase = &"grace" if state.disconnected_seconds < DISCONNECT_GRACE_SECONDS else &"decaying"
	return {
		"node": source_node,
		"connected": connected,
		"state": phase,
		"display_radius": state.display_radius,
		"effective_radius": _get_state_radius(state),
		"brightness": state.brightness,
		"disconnected_seconds": state.disconnected_seconds,
	}


## 此圆盘集合只代表有效覆盖；断连残影不会参与并集或采集查询。
func _get_draw_discs() -> Array[Dictionary]:
	var discs: Array[Dictionary] = []
	for instance_id: int in _sources:
		var state: SourceState = _sources[instance_id]
		var radius: float = _get_state_radius(state)
		if radius > 0.0:
			var source_node: Node2D = _get_eligible_node(state)
			discs.append({
				"node": source_node,
				"instance_id": instance_id,
				"center": source_node.global_position,
				"radius": radius,
				"brightness": state.brightness,
			})
	return discs


func _get_remnant_discs() -> Array[Dictionary]:
	var discs: Array[Dictionary] = []
	for snapshot: Dictionary in get_visual_snapshot():
		var radius: float = snapshot["display_radius"]
		var brightness: float = snapshot["brightness"]
		if not bool(snapshot["connected"]) and radius > 0.0 and brightness > 0.0:
			var source_node: Node2D = snapshot["node"]
			discs.append({
				"node": source_node,
				"instance_id": source_node.get_instance_id(),
				"center": source_node.global_position,
				"radius": radius,
				"brightness": brightness,
			})
	return discs


## 明亮覆盖画在恢复中的暗盘上层；同亮度使用实例 ID 保持顺序确定。
func _get_fill_discs(discs: Array[Dictionary]) -> Array[Dictionary]:
	var ordered: Array[Dictionary] = discs.duplicate()
	ordered.sort_custom(_fill_disc_precedes)
	return ordered


func _fill_disc_precedes(left: Dictionary, right: Dictionary) -> bool:
	var left_brightness: float = left["brightness"]
	var right_brightness: float = right["brightness"]
	if left_brightness == right_brightness:
		return int(left["instance_id"]) < int(right["instance_id"])
	return left_brightness < right_brightness


func _boundary_disc_precedes(left: Dictionary, right: Dictionary) -> bool:
	var left_brightness: float = left.get("brightness", 1.0)
	var right_brightness: float = right.get("brightness", 1.0)
	if left_brightness == right_brightness:
		return int(left["instance_id"]) < int(right["instance_id"])
	return left_brightness > right_brightness


func _draw_remnants(discs: Array[Dictionary]) -> void:
	for disc: Dictionary in discs:
		var brightness: float = disc["brightness"]
		var fill: Color = Color(REMNANT_FILL_COLOR.r, REMNANT_FILL_COLOR.g,
			REMNANT_FILL_COLOR.b, REMNANT_FILL_COLOR.a * brightness)
		draw_circle(disc["center"], disc["radius"], fill, true, -1.0, true)
	for index: int in range(discs.size()):
		var disc: Dictionary = discs[index]
		var center: Vector2 = disc["center"]
		var radius: float = disc["radius"]
		var brightness: float = disc["brightness"]
		var boundary: Color = Color(REMNANT_BOUNDARY_COLOR.r, REMNANT_BOUNDARY_COLOR.g,
			REMNANT_BOUNDARY_COLOR.b, REMNANT_BOUNDARY_COLOR.a * brightness)
		for arc: Vector2 in _get_exposed_arcs(index, discs):
			_draw_dashed_arc(center, radius, arc, boundary)
		var mark_size: float = minf(radius * 0.35, 6.0)
		var mark: Vector2 = Vector2(mark_size, mark_size)
		draw_line(center - mark, center + mark, boundary, BOUNDARY_WIDTH, true)
		mark.x = -mark.x
		draw_line(center - mark, center + mark, boundary, BOUNDARY_WIDTH, true)


func _draw_dashed_arc(center: Vector2, radius: float, arc: Vector2, color: Color) -> void:
	var angle_step: float = TAU / float(REMNANT_DASH_STEPS)
	var first_dash: int = int(floor(arc.x / angle_step))
	var last_dash: int = int(ceil(arc.y / angle_step))
	for index: int in range(first_dash, last_dash):
		var start: float = maxf(arc.x, float(index) * angle_step)
		var end: float = minf(arc.y, (float(index) + REMNANT_DASH_RATIO) * angle_step)
		if end > start:
			var point_count: int = maxi(2, int(ceil((end - start) / TAU * CIRCLE_STEPS)) + 1)
			draw_arc(center, radius, start, end, point_count, color, BOUNDARY_WIDTH, true)


func _get_world_draw_transform() -> Transform2D:
	return global_transform.affine_inverse()


func _distance_squared(left: Vector2, right: Vector2) -> float:
	# 用 GDScript float 运算，避免较大世界坐标的 Vector2 平方提前溢出。
	var delta_x: float = float(left.x) - float(right.x)
	var delta_y: float = float(left.y) - float(right.y)
	return delta_x * delta_x + delta_y * delta_y


func _disc_contains(disc: Dictionary, world_position: Vector2) -> bool:
	var center: Vector2 = disc["center"]
	var radius: float = disc["radius"]
	return radius > 0.0 and _distance_squared(center, world_position) <= radius * radius


func _candidate_precedes(left: Dictionary, right: Dictionary) -> bool:
	var left_distance: float = left["distance_squared"]
	var right_distance: float = right["distance_squared"]
	if left_distance == right_distance:
		return int(left["instance_id"]) < int(right["instance_id"])
	return left_distance < right_distance


## 只保留圆周不在其他圆盘内部的弧；同心同半径由更亮的盘绘制一次边界。
func _get_exposed_arcs(index: int, discs: Array[Dictionary]) -> Array[Vector2]:
	var visible_arcs: Array[Vector2] = [Vector2(0.0, TAU)]
	var disc: Dictionary = discs[index]
	var center: Vector2 = disc["center"]
	var radius: float = disc["radius"]
	for other_index: int in range(discs.size()):
		if other_index == index or visible_arcs.is_empty():
			continue
		var other: Dictionary = discs[other_index]
		var other_center: Vector2 = other["center"]
		var other_radius: float = other["radius"]
		var distance: float = sqrt(_distance_squared(center, other_center))
		if distance == 0.0:
			if other_radius > radius or (other_radius == radius
				and _boundary_disc_precedes(other, disc)):
				visible_arcs.clear()
		elif distance + radius <= other_radius:
			visible_arcs.clear()
		elif distance < radius + other_radius and distance + other_radius > radius:
			var cosine: float = clampf((distance * distance + radius * radius
				- other_radius * other_radius) / (2.0 * distance * radius), -1.0, 1.0)
			var half_angle: float = acos(cosine)
			var angle: float = fposmod(atan2(float(other_center.y) - float(center.y),
				float(other_center.x) - float(center.x)), TAU)
			var start_angle: float = angle - half_angle
			var end_angle: float = angle + half_angle
			if start_angle < 0.0:
				visible_arcs = _subtract_arc(visible_arcs, 0.0, end_angle)
				visible_arcs = _subtract_arc(visible_arcs, start_angle + TAU, TAU)
			elif end_angle > TAU:
				visible_arcs = _subtract_arc(visible_arcs, start_angle, TAU)
				visible_arcs = _subtract_arc(visible_arcs, 0.0, end_angle - TAU)
			else:
				visible_arcs = _subtract_arc(visible_arcs, start_angle, end_angle)
	return visible_arcs


func _subtract_arc(arcs: Array[Vector2], start_angle: float, end_angle: float) -> Array[Vector2]:
	var remaining: Array[Vector2] = []
	for arc: Vector2 in arcs:
		if end_angle <= arc.x or start_angle >= arc.y:
			remaining.append(arc)
		else:
			if start_angle - arc.x > ARC_EPSILON:
				remaining.append(Vector2(arc.x, start_angle))
			if arc.y - end_angle > ARC_EPSILON:
				remaining.append(Vector2(end_angle, arc.y))
	return remaining
