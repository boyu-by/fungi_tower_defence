class_name TerrainNavigation
extends Node2D
## 固定世界坐标岩石；查询不修改场景，所有调用共享同一条确定性路线。

const ROCK_SCENE: PackedScene = preload("res://scenes/terrain/rock.tscn")
const CORNER_MARGIN: float = 0.25
const MAX_GRAPH_POINTS: int = 1024

@export var bounds: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
@export var obstacles: Array[Rect2] = []:
	set(value):
		obstacles = value
		if is_inside_tree():
			_rebuild_rocks()

var _rocks: Array[TerrainRock] = []


func _ready() -> void:
	add_to_group("terrain_navigation")
	_rebuild_rocks()


func find_path(start: Vector2, end: Vector2, clearance: float = 10.0) -> PackedVector2Array:
	if not is_point_walkable(start, clearance) or not is_point_walkable(end, clearance):
		return PackedVector2Array()
	if start == end:
		return PackedVector2Array([start])
	if is_segment_clear(start, end, clearance):
		return PackedVector2Array([start, end])
	if obstacles.size() * 4 + 2 > MAX_GRAPH_POINTS:
		return PackedVector2Array()

	# 矩形障碍的拐角构成可见图，用 Godot AStar2D 寻路。
	# 正净空允许恰好相距 clearance 的边界；登记顺序固定以稳定等长路线。
	var points: PackedVector2Array = PackedVector2Array([start, end])
	for obstacle: Rect2 in obstacles:
		var padded: Rect2 = obstacle.abs().grow(clearance if clearance > 0.0 else CORNER_MARGIN)
		if obstacle.size.x == 0.0 or obstacle.size.y == 0.0:
			continue
		var corners: PackedVector2Array = PackedVector2Array([
			padded.position, Vector2(padded.end.x, padded.position.y),
			padded.end, Vector2(padded.position.x, padded.end.y),
		])
		for corner: Vector2 in corners:
			if is_point_walkable(corner, clearance) and not points.has(corner):
				points.append(corner)
	var graph: AStar2D = AStar2D.new()
	for point_index: int in range(points.size()):
		graph.add_point(point_index, points[point_index])
	for first: int in range(points.size()):
		for second: int in range(first + 1, points.size()):
			if is_segment_clear(points[first], points[second], clearance):
				graph.connect_points(first, second)
	var path: PackedVector2Array = graph.get_point_path(0, 1)
	return _simplify_path(path, clearance)


func is_point_walkable(point: Vector2, clearance: float = 0.0) -> bool:
	if not point.is_finite() or not _configuration_is_valid(clearance):
		return false
	var usable: Rect2 = bounds.grow(-clearance)
	if not _contains_inclusive(usable, point):
		return false
	var walkable: bool = true
	for obstacle: Rect2 in obstacles:
		if obstacle.size.x != 0.0 and obstacle.size.y != 0.0 \
				and _contains_obstacle(obstacle.abs().grow(clearance), point, clearance == 0.0):
			walkable = false
	return walkable


func is_segment_clear(start: Vector2, end: Vector2, clearance: float = 0.0) -> bool:
	if not is_point_walkable(start, clearance) or not is_point_walkable(end, clearance):
		return false
	var clear: bool = true
	for obstacle: Rect2 in obstacles:
		if obstacle.size.x != 0.0 and obstacle.size.y != 0.0 \
				and _segment_intersects_rect(start, end, obstacle.abs().grow(clearance), clearance == 0.0):
			clear = false
	return clear


func _configuration_is_valid(clearance: float) -> bool:
	if not is_finite(clearance) or clearance < 0.0 or not bounds.position.is_finite() \
			or not bounds.size.is_finite() or not bounds.end.is_finite() \
			or bounds.size.x <= clearance * 2.0 or bounds.size.y <= clearance * 2.0:
		return false
	var valid: bool = true
	for obstacle: Rect2 in obstacles:
		if not obstacle.position.is_finite() or not obstacle.size.is_finite() \
				or not obstacle.end.is_finite():
			valid = false
	return valid


func _contains_inclusive(rect: Rect2, point: Vector2) -> bool:
	return point.x >= rect.position.x and point.x <= rect.end.x \
		and point.y >= rect.position.y and point.y <= rect.end.y


func _contains_obstacle(rect: Rect2, point: Vector2, include_boundary: bool) -> bool:
	if include_boundary:
		return _contains_inclusive(rect, point)
	return point.x > rect.position.x and point.x < rect.end.x \
		and point.y > rect.position.y and point.y < rect.end.y


func _segment_intersects_rect(start: Vector2, end: Vector2, rect: Rect2, include_boundary: bool) -> bool:
	var minimum: float = 0.0
	var maximum: float = 1.0
	var intersects: bool = true
	for axis: int in range(2):
		var direction: float = float(end[axis]) - float(start[axis])
		if direction == 0.0:
			var outside: bool = start[axis] < rect.position[axis] or start[axis] > rect.end[axis]
			if outside or (not include_boundary \
					and (start[axis] == rect.position[axis] or start[axis] == rect.end[axis])):
				intersects = false
		else:
			var first: float = (float(rect.position[axis]) - float(start[axis])) / direction
			var second: float = (float(rect.end[axis]) - float(start[axis])) / direction
			minimum = maxf(minimum, minf(first, second))
			maximum = minf(maximum, maxf(first, second))
			if minimum > maximum or (not include_boundary and minimum == maximum):
				intersects = false
	return intersects


func _simplify_path(path: PackedVector2Array, clearance: float) -> PackedVector2Array:
	if path.size() < 3:
		return path
	var simplified: PackedVector2Array = PackedVector2Array([path[0]])
	var anchor_index: int = 0
	while anchor_index < path.size() - 1:
		var next_index: int = anchor_index + 1
		for candidate: int in range(path.size() - 1, anchor_index, -1):
			if is_segment_clear(path[anchor_index], path[candidate], clearance):
				next_index = candidate
				break
		simplified.append(path[next_index])
		anchor_index = next_index
	return simplified


func _rebuild_rocks() -> void:
	for rock: TerrainRock in _rocks:
		if is_instance_valid(rock):
			rock.free()
	_rocks.clear()
	for obstacle: Rect2 in obstacles:
		var footprint: Rect2 = obstacle.abs()
		if not footprint.position.is_finite() or not footprint.size.is_finite() \
				or footprint.size.x <= 0.0 or footprint.size.y <= 0.0:
			continue
		var rock: TerrainRock = ROCK_SCENE.instantiate()
		rock.size = footprint.size
		# 世界坐标字段不随导航节点/父节点的变换改变碰撞与绘制。
		rock.top_level = true
		add_child(rock)
		rock.global_position = footprint.get_center()
		_rocks.append(rock)
