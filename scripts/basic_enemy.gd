class_name BasicEnemy
extends Node2D
## 敌人变体共享寻路、接触攻击、受伤与死亡反馈；类型标签不改写场景参数。

signal died(enemy: BasicEnemy)
signal attacked_tissue(target: Node2D, amount: float)

enum Archetype { NORMAL = 0, SWARM = 1, ARMORED = 2, GNAWER = 3 }

const CONTACT_TOLERANCE: float = 0.01
const NAVIGATION_CLEARANCE: float = 10.0
const RETARGET_INTERVAL: float = 0.4
const PATH_REFRESH_INTERVAL: float = 0.5
const OPPORTUNISTIC_RANGE: float = 72.0
const GNAWER_SEARCH_RANGE: float = 240.0
const EDGE_SAMPLE_COUNT: int = 12

@export var mother_core: MotherCore
@export var terrain_navigation: TerrainNavigation
@export var network_system: NetworkSystem
@export var archetype: Archetype = Archetype.NORMAL
@export_range(1, 200, 1) var max_health: int = 24
@export var armor: int = 0:
	set(value):
		if value < 0:
			return
		armor = value
		if is_node_ready():
			_update_armor_hint()
@export_range(0.0, 200.0, 1.0) var move_speed: float = 52.0
@export_range(1, 100, 1) var attack_damage: int = 12
@export_range(1.0, 100.0, 1.0) var contact_range: float = 28.0
@export_range(1, 100, 1) var remains_nutrition: int = 4

var health: int = 0
var _hit_tween: Tween
var _death_started: bool = false
var _target: Node2D
var _target_point := Vector2.ZERO
var _target_kind: StringName = &""
var _edge_progress: float = 0.0
var _path := PackedVector2Array()
var _path_index: int = 0
var _retarget_time_left: float = 0.0
var _path_time_left: float = 0.0

@onready var visuals: Node2D = $Visuals
@onready var sprite: AnimatedSprite2D = $Visuals/Sprite
@onready var health_bar: ProgressBar = $HealthBar
@onready var attack_timer: Timer = $AttackTimer


func _ready() -> void:
	health = max_health
	health_bar.max_value = max_health
	health_bar.value = health
	_update_armor_hint()
	_resolve_scene_context()


func get_archetype() -> int:
	return int(archetype)


func get_archetype_snapshot() -> Dictionary:
	# 查询实例中的真实计时器，在进入场景树前也能读取场景覆盖值。
	var timer := get_node_or_null("AttackTimer") as Timer
	return {
		"archetype": get_archetype(),
		"max_health": max_health,
		"armor": armor,
		"move_speed": move_speed,
		"attack_damage": attack_damage,
		"attack_interval": timer.wait_time if is_instance_valid(timer) else 0.0,
		"remains_nutrition": remains_nutrition,
	}


func is_alive() -> bool:
	return health > 0 and not _death_started and not is_queued_for_deletion()


func get_aim_position() -> Vector2:
	return sprite.global_position


func is_attacking_core() -> bool:
	if not can_process() or not is_finite(get_core_distance_squared()) \
			or not is_instance_valid(attack_timer) or attack_timer.is_queued_for_deletion() \
			or not attack_timer.is_inside_tree() or not attack_timer.can_process() \
			or attack_timer.is_stopped() or attack_timer.paused:
		return false
	if _target == mother_core:
		return _has_clear_contact()
	# 无地形旧夹具允许直接启动既有计时器；纯查询仍不修改目标。
	var reach: float = contact_range + CONTACT_TOLERANCE
	return _target == null and not _has_terrain() and archetype != Archetype.GNAWER \
		and get_core_distance_squared() <= reach * reach


func get_core_distance_squared() -> float:
	if not is_inside_tree() or not is_alive() or not is_instance_valid(mother_core) \
			or mother_core.is_queued_for_deletion() or not mother_core.is_inside_tree() \
			or mother_core.health <= 0:
		return INF
	return global_position.distance_squared_to(mother_core.global_position)


func _physics_process(delta: float) -> void:
	if not is_finite(get_core_distance_squared()):
		_clear_target()
		return

	_retarget_time_left -= maxf(delta, 0.0)
	_path_time_left -= maxf(delta, 0.0)
	if not _is_target_available(_target):
		_clear_target()
	# 活着且可达的组织保持锁定；母核是普通敌人的长期目标，也是啃食者的兜底。
	if _retarget_time_left <= 0.0:
		_retarget_time_left = RETARGET_INTERVAL
		_resolve_scene_context()
		if _target == null or _target == mother_core:
			var candidate := _choose_target()
			if not candidate.is_empty() and candidate["target"] != _target:
				_lock_target(candidate)
	if not _is_target_available(_target):
		attack_timer.stop()
		sprite.play("idle")
		return

	_target_point = _get_locked_target_point()
	if _path_time_left <= 0.0:
		_path_time_left = PATH_REFRESH_INTERVAL
		if not _refresh_target_path():
			_clear_target()
			sprite.play("idle")
			return
	if _has_clear_contact():
		sprite.play("idle")
		if attack_timer.is_stopped():
			attack_timer.start()
	else:
		sprite.play("walk")
		attack_timer.stop()
		_follow_path(maxf(move_speed, 0.0) * maxf(delta, 0.0))


## 只读取已锁定的目标；HUD 查询不寻路、不重选，也不改变计时器。
func get_target_snapshot() -> Dictionary:
	if not is_alive() or not _is_target_available(_target):
		return {"target": null, "target_id": 0, "position": Vector2.ZERO, "kind": ""}
	return {"target": _target, "target_id": _target.get_instance_id(),
		"position": _get_locked_target_point(), "kind": String(_target_kind)}


func estimate_damage(request: Dictionary) -> int:
	if not WeaponProfile.is_valid_damage_request(request):
		return 0
	var raw_damage: int = request["raw_damage"]
	var damage_type: int = request["damage_type"]
	var damage := raw_damage
	if damage_type != WeaponProfile.DamageType.ARMOR_PIERCING:
		damage = maxi(1, raw_damage - armor)
	return damage


func apply_damage(request: Dictionary) -> int:
	if not is_alive():
		return 0
	var damage := estimate_damage(request)
	if damage <= 0:
		return 0
	var health_lost := mini(damage, health)
	health -= health_lost
	health_bar.value = health
	if health == 0:
		_die()
	else:
		_play_hit_feedback()
	return health_lost


func take_damage(amount: int) -> void:
	apply_damage({
		"raw_damage": amount,
		"damage_type": WeaponProfile.DamageType.NORMAL,
	})


func _on_attack_timer_timeout() -> void:
	if not is_finite(get_core_distance_squared()) or not _has_clear_contact():
		attack_timer.stop()
		return
	var attacked := _target
	var before := _get_tissue_health(attacked)
	attacked.call("take_damage", attack_damage)
	if not is_instance_valid(self) or not is_instance_valid(attacked):
		return
	var actual := maxf(0.0, before - _get_tissue_health(attacked))
	if actual > 0.0:
		attacked_tissue.emit(attacked, actual)
	if is_instance_valid(self) and not _is_target_available(_target):
		_clear_target()


func _scene_scope() -> Node:
	if not is_inside_tree():
		return null
	var scene := get_tree().current_scene
	if is_instance_valid(scene) and (scene == self or scene.is_ancestor_of(self)):
		return scene
	var scope: Node = self
	while scope.get_parent() != null and scope.get_parent() != get_tree().root:
		scope = scope.get_parent()
	return scope


func _is_scene_local(node: Node) -> bool:
	if not is_instance_valid(node) or not node.is_inside_tree() or node.is_queued_for_deletion():
		return false
	var scope := _scene_scope()
	return is_instance_valid(scope) and (node == scope or scope.is_ancestor_of(node))


func _resolve_scene_context() -> void:
	if not is_inside_tree():
		return
	if not _is_scene_local(terrain_navigation):
		terrain_navigation = null
		for node: Node in get_tree().get_nodes_in_group(&"terrain_navigation"):
			if node is TerrainNavigation and _is_scene_local(node):
				terrain_navigation = node as TerrainNavigation
				break
	if not _is_scene_local(network_system):
		network_system = null
		for node: Node in get_tree().get_nodes_in_group(&"network_system"):
			if node is NetworkSystem and _is_scene_local(node):
				network_system = node as NetworkSystem
				break


func _has_terrain() -> bool:
	return _is_scene_local(terrain_navigation)


func _is_target_available(target: Node2D) -> bool:
	if not _is_scene_local(target) or not target.has_method("take_damage"):
		return false
	if target == mother_core:
		return mother_core.health > 0
	if not target.has_method("is_attackable") or not bool(target.call("is_attackable")):
		return false
	return not target is HyphaEdge or (target as HyphaEdge).has_endpoints()


func _get_tissue_health(tissue: Node2D) -> float:
	if tissue == mother_core:
		return float(mother_core.health)
	if tissue.has_method("get_health_snapshot"):
		var snapshot: Dictionary = tissue.call("get_health_snapshot")
		return float(snapshot.get("health", 0.0))
	return 0.0


func _get_point_target_position(tissue: Node2D) -> Vector2:
	# 器官和器官芽的逻辑接触点在宿主菌结，视觉子节点的偏移不改变地面距离。
	if (tissue is AttackOrgan or tissue is DigestiveOrgan or tissue is OrganBud) \
			and tissue.get_parent() is HyphaNode:
		return (tissue.get_parent() as HyphaNode).global_position
	return tissue.global_position


func _get_locked_target_point() -> Vector2:
	if _target is HyphaEdge:
		return (_target as HyphaEdge).get_point_at(_edge_progress)
	return _get_point_target_position(_target)


func _get_tissue_kind(tissue: Node2D) -> StringName:
	if tissue == mother_core:
		return &"core"
	if tissue is HyphaEdge:
		return &"edge"
	if tissue is HyphaNode:
		return &"junction"
	if tissue is OrganBud:
		return &"bud"
	if tissue is GrowthTip:
		return &"tip"
	return &"organ"


func _candidate_tissues() -> Array[Node2D]:
	var tissues: Array[Node2D] = []
	for node: Node in get_tree().get_nodes_in_group(&"colony_tissues"):
		if node is Node2D and _is_scene_local(node):
			tissues.append(node as Node2D)
	if _is_scene_local(network_system):
		for node: Node2D in network_system.get_registered_nodes():
			if _is_scene_local(node) and not tissues.has(node):
				tissues.append(node)
		for edge: HyphaEdge in network_system.get_registered_edges():
			if _is_scene_local(edge) and not tissues.has(edge):
				tissues.append(edge)
	return tissues


func _choose_target() -> Dictionary:
	var best: Dictionary = {}
	var best_distance: float = INF
	# 无地形的原有关卡保持三个老类型直达母核的行为。
	if archetype == Archetype.GNAWER or _has_terrain():
		var range_limit := GNAWER_SEARCH_RANGE if archetype == Archetype.GNAWER else OPPORTUNISTIC_RANGE
		for tissue: Node2D in _candidate_tissues():
			var eligible := (tissue is HyphaNode or tissue is HyphaEdge) \
				if archetype == Archetype.GNAWER else \
				(tissue is AttackOrgan or tissue is DigestiveOrgan or tissue is OrganBud or tissue is GrowthTip)
			if not eligible or not _is_target_available(tissue):
				continue
			var candidate := _propose_target(tissue, range_limit)
			if not candidate.is_empty() and float(candidate["distance"]) < best_distance:
				best = candidate
				best_distance = float(candidate["distance"])
	if best.is_empty() and _is_target_available(mother_core):
		best = _propose_target(mother_core, INF)
	return best


func _find_path(point: Vector2) -> PackedVector2Array:
	if _has_terrain():
		return terrain_navigation.find_path(global_position, point, NAVIGATION_CLEARANCE)
	return PackedVector2Array([global_position, point])


func _path_length(path: PackedVector2Array) -> float:
	var length: float = 0.0
	for index: int in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return length


func _propose_point(target: Node2D, point: Vector2, range_limit: float) -> Dictionary:
	if global_position.distance_to(point) > range_limit \
			or (_has_terrain() and not terrain_navigation.is_point_walkable(point, NAVIGATION_CLEARANCE)):
		return {}
	var path := _find_path(point)
	if path.is_empty():
		return {}
	var distance := _path_length(path)
	if distance > range_limit:
		return {}
	return {"target": target, "point": point, "path": path, "distance": distance}


func _propose_target(target: Node2D, range_limit: float) -> Dictionary:
	if not target is HyphaEdge:
		return _propose_point(target, _get_point_target_position(target), range_limit)
	var edge := target as HyphaEdge
	if not edge.has_endpoints():
		return {}
	var start := edge.start_node.global_position
	var end := edge.end_node.global_position
	var points := PackedVector2Array([Geometry2D.get_closest_point_to_segment(global_position, start, end)])
	for index: int in range(EDGE_SAMPLE_COUNT + 1):
		var point := start.lerp(end, float(index) / float(EDGE_SAMPLE_COUNT))
		if not points.has(point):
			points.append(point)
	var best: Dictionary = {}
	var best_distance: float = INF
	for point: Vector2 in points:
		var candidate := _propose_point(target, point, range_limit)
		if not candidate.is_empty() and float(candidate["distance"]) < best_distance:
			best = candidate
			best_distance = float(candidate["distance"])
	return best


func _lock_target(candidate: Dictionary) -> void:
	_clear_target()
	_target = candidate["target"] as Node2D
	_target_point = candidate["point"]
	_target_kind = _get_tissue_kind(_target)
	if _target is HyphaEdge:
		var edge := _target as HyphaEdge
		var segment := edge.end_node.global_position - edge.start_node.global_position
		_edge_progress = clampf((_target_point - edge.start_node.global_position).dot(segment) \
			/ segment.length_squared(), 0.0, 1.0) if not segment.is_zero_approx() else 0.0
	_path = candidate["path"]
	_path_index = 1
	_path_time_left = PATH_REFRESH_INTERVAL


func _refresh_target_path() -> bool:
	var path := _find_path(_target_point)
	if path.is_empty() and _target is HyphaEdge:
		# 锁定的是边的身份；原采样点受阻时可换同一条边上的可达采样点。
		var candidate := _propose_target(_target, INF)
		if not candidate.is_empty():
			_lock_target(candidate)
			path = _path
	if path.is_empty():
		return false
	_path = path
	_path_index = 1
	return true


func _has_clear_contact() -> bool:
	if not is_alive() or not _is_target_available(_target):
		return false
	var point := _get_locked_target_point()
	var reach := contact_range + CONTACT_TOLERANCE
	return global_position.distance_squared_to(point) <= reach * reach \
		and (not _has_terrain() or terrain_navigation.is_segment_clear(global_position, point, 0.0))


func _follow_path(budget: float) -> void:
	while budget > 0.0 and _path_index < _path.size() and not _has_clear_contact():
		var waypoint := _path[_path_index]
		var distance := global_position.distance_to(waypoint)
		# 必须真正抵达岩石拐角；提前略过微小余距会切进障碍的净空区域。
		if distance == 0.0:
			_path_index += 1
			continue
		var step := minf(budget, distance)
		if _path_index == _path.size() - 1 \
				and (not _has_terrain() or terrain_navigation.is_segment_clear(global_position, _target_point, 0.0)):
			step = minf(step, maxf(0.0, global_position.distance_to(_target_point) - contact_range))
		if step <= 0.0:
			break
		var next_position := global_position.move_toward(waypoint, step)
		if _has_terrain() and not terrain_navigation.is_segment_clear(global_position, next_position, NAVIGATION_CLEARANCE):
			_path_time_left = 0.0
			break
		global_position = next_position
		budget -= step
		if step >= distance:
			_path_index += 1
			# 单个物理帧停在拐角；显示/碰撞插值也不会把两个子步连成穿角弦。
			break


func _clear_target() -> void:
	_target = null
	_target_point = Vector2.ZERO
	_target_kind = &""
	_edge_progress = 0.0
	_path.clear()
	_path_index = 0
	_path_time_left = 0.0
	if is_instance_valid(attack_timer):
		attack_timer.stop()


func _play_hit_feedback() -> void:
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	sprite.modulate = Color(2.0, 1.3, 1.0)
	_hit_tween = create_tween()
	_hit_tween.tween_property(sprite, "modulate", Color.WHITE, 0.16)


func _update_armor_hint() -> void:
	var hint := get_node_or_null("Visuals/ArmorHint") as CanvasItem
	if not is_instance_valid(hint):
		return
	hint.visible = armor > 0
	var value_label := hint.get_node_or_null("Value") as Label
	if is_instance_valid(value_label):
		value_label.text = str(armor)


func _die() -> void:
	if _death_started:
		return
	_death_started = true
	attack_timer.stop()
	health_bar.hide()
	sprite.stop()
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	sprite.modulate = Color.WHITE
	died.emit(self)
	var fade := create_tween().set_parallel(true)
	fade.tween_property(visuals, "modulate:a", 0.0, 0.2)
	fade.tween_property(visuals, "scale", Vector2(1.15, 0.6), 0.2)
	fade.chain().tween_callback(queue_free)
