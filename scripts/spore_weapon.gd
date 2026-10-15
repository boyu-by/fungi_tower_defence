class_name SporeWeapon
extends Node2D
## 武器持有独立参数副本；整轮弹丸准备成功后统一扣费、记账和发布通知。

signal volley_committed(shot_id: String, nutrition_spent: int, projectile_count: int)
signal shot_fired(target: BasicEnemy)

# 仅供原普通武器测试和没有武器节点的旧供养夹具使用。
const SHOT_NUTRITION: int = 1
const RANGE_SEGMENTS: int = 64
const RANGE_TOLERANCE: float = 0.0001
const ANGLE_TOLERANCE_DEGREES: float = 0.0001

@export var inventory_owner: AttackOrgan:
	set(value):
		if inventory_owner == value:
			return
		_disconnect_owner_work_state()
		inventory_owner = value
		_state_revision += 1
		_connect_owner_work_state()
		_update_range_origin()
		if is_node_ready():
			_refresh_scheduler(true)
@export var enemy_container: Node2D
@export var projectile_container: Node2D
@export var projectile_scene: PackedScene
## 场景也可采用同一配置入口；读取副本，不保留可与当前行为冲突的第二份资源。
@export var weapon_profile: WeaponProfile:
	get:
		return _active_profile.copy_for_instance() if _active_profile != null else null
	set(value):
		if value != null:
			configure_profile(value)
@export var targeting_system: CombatTargetingSystem:
	set(value):
		if targeting_system == value:
			return
		targeting_system = value
		_has_targeting_configuration = value != null
		_state_revision += 1
		if is_node_ready():
			_refresh_scheduler(true)
@export var targeting_required: bool = false:
	set(value):
		if targeting_required == value:
			return
		targeting_required = value
		_state_revision += 1
		if is_node_ready():
			_refresh_scheduler(true)
@export_range(1.0, 800.0, 1.0) var attack_range: float = 300.0:
	get:
		return _get_profile().attack_range
	set(value):
		if is_finite(value) and value > 0.0 and _get_profile().attack_range != value:
			_get_profile().attack_range = value
			_state_revision += 1
			_update_range_outline()
@export_range(1, 100, 1) var damage: int = 12:
	get:
		return _get_profile().damage
	set(value):
		if value > 0 and _get_profile().damage != value:
			_get_profile().damage = value
			_state_revision += 1

var _active_profile: WeaponProfile
var _has_explicit_profile: bool = false
var _firing_enabled: bool = true
var _firing: bool = false
var _state_revision: int = 0
var _shot_sequence: int = 0
var _rounds_fired: int = 0
var _projectiles_fired: int = 0
var _nutrition_spent: int = 0
var _last_shot_id: String = ""
var _connected_owner: AttackOrgan
var _owner_work_callback: Callable
var _flash_tween: Tween
var _has_targeting_configuration: bool = false
var _preparing_system: CombatTargetingSystem
var _preparing_ids := PackedStringArray()

@onready var range_outline: Line2D = $RangeOutline
@onready var muzzle: Polygon2D = $Muzzle
@onready var fire_timer: Timer = $FireTimer


func _ready() -> void:
	# 没有显式采用新配置时接收旧场景计时器的周期，保留原关卡配置。
	if not _has_explicit_profile:
		_sync_legacy_timer_interval()
	_connect_owner_work_state()
	_apply_profile(false)
	if not _firing_enabled or not has_valid_profile() or not is_instance_valid(inventory_owner) \
			or inventory_owner.is_queued_for_deletion() or not inventory_owner.is_work_enabled():
		fire_timer.stop()


func _process(_delta: float) -> void:
	# 射程圆独立于视觉发射口的高度和变换，始终以器官地面点为圆心。
	_update_range_origin()
	# 移入射程的敌人在这一帧就唤醒器官；射击仍经过原有工作和预约门控。
	if is_instance_valid(inventory_owner):
		inventory_owner.advance_dormancy(0.0)


func _exit_tree() -> void:
	_state_revision += 1
	# 已提交记录由弹丸持有；武器退出只取消仍属于当前准备轮的预留。
	if is_instance_valid(_preparing_system):
		for commitment_id: String in _preparing_ids:
			if _preparing_system.is_commitment_live(commitment_id) \
					and not _preparing_system.is_commitment_committed(commitment_id):
				_preparing_system.release_commitment(commitment_id)
	_clear_preparation()
	_disconnect_owner_work_state()


func _on_fire_timer_timeout() -> void:
	if _firing or not _is_active():
		return
	var profile := get_weapon_profile()
	if profile == null or not _has_live_firing_inputs() \
			or inventory_owner.nutrition < profile.nutrition_cost:
		return
	_firing = true
	_commit_round(profile)
	_firing = false


func _on_owner_work_state_changed(_enabled: bool, organ: AttackOrgan) -> void:
	if organ != inventory_owner or organ != _connected_owner:
		return
	_state_revision += 1
	_refresh_scheduler(true)


func set_range_visible(is_visible: bool) -> void:
	var outline := get_node_or_null("RangeOutline") as Line2D
	if outline != null:
		_update_range_origin()
		outline.visible = is_visible


## 程序接线入口；不附带玩家分化操作或付费/免费切换规则。
func configure_profile(profile: WeaponProfile) -> bool:
	if profile == null:
		return false
	var snapshot := profile.copy_for_instance()
	if snapshot == null or not snapshot.is_valid():
		return false
	_active_profile = snapshot
	_has_explicit_profile = true
	_state_revision += 1
	_apply_profile(true)
	return true


## 返回副本，调用方不能通过查询结果改动某个器官或共享的 .tres。
func get_weapon_profile() -> WeaponProfile:
	_sync_legacy_timer_interval()
	return _get_profile().copy_for_instance()


func has_valid_profile() -> bool:
	_sync_legacy_timer_interval()
	return _get_profile().is_valid()


func is_firing_enabled() -> bool:
	return _firing_enabled


func set_firing_enabled(value: bool) -> void:
	if _firing_enabled == value:
		return
	_firing_enabled = value
	_state_revision += 1
	_refresh_scheduler(true)


func get_nutrition_cost() -> int:
	return _get_profile().nutrition_cost


func get_shot_statistics() -> Dictionary:
	return {
		"rounds": _rounds_fired,
		"projectiles": _projectiles_fired,
		"nutrition_spent": _nutrition_spent,
		"last_shot_id": _last_shot_id,
	}


func get_firing_state() -> Dictionary:
	_sync_legacy_timer_interval()
	var timer := get_node_or_null("FireTimer") as Timer
	var remaining: float = 0.0
	if timer != null and not timer.is_stopped():
		remaining = maxf(timer.time_left, 0.0)
	return {
		"enabled": _firing_enabled,
		"active": _is_active(),
		"committing": _firing,
		"cooldown_remaining": remaining,
		"fire_interval": _get_profile().fire_interval,
	}


## 休眠使用真实存活敌人，不使用已预约伤害或弹药/武器工作状态。
func has_live_enemy_in_range() -> bool:
	if not is_instance_valid(inventory_owner) or not inventory_owner.is_inside_tree() \
		or not is_instance_valid(enemy_container) or enemy_container.is_queued_for_deletion() \
		or not enemy_container.is_inside_tree():
		return false
	var maximum_distance: float = _get_profile().attack_range + RANGE_TOLERANCE
	var origin: Vector2 = inventory_owner.global_position
	for child: Node in enemy_container.get_children():
		if child is BasicEnemy and is_instance_valid(child) and child.is_inside_tree() \
			and not child.is_queued_for_deletion() and child.is_alive():
			var distance: float = origin.distance_squared_to(child.global_position)
			if is_finite(distance) and distance <= maximum_distance * maximum_distance:
				return true
	return false


## 原武器搬迁后重新连接库存所有者；配置、统计和开火意图仍属于原实例。
func rebind_after_transplant() -> void:
	_connect_owner_work_state()
	_state_revision += 1
	_update_range_origin()
	_refresh_scheduler(true)


## 既有器官与武器是兄弟节点；按库存所有者查找，不依赖节点名称。
static func get_organ_nutrition_cost(organ: AttackOrgan) -> int:
	if not is_instance_valid(organ) or organ.is_queued_for_deletion():
		return 0
	return organ.get_shot_nutrition_cost()


func _commit_round(profile: WeaponProfile) -> void:
	var organ := inventory_owner
	var enemies := enemy_container
	var container := projectile_container
	var scene := projectile_scene
	var revision := _state_revision
	var system := targeting_system
	var generation: int = int(system.get_snapshot().get("generation", -1)) \
			if is_instance_valid(system) else -1
	var targets := _select_targets(profile, organ.global_position, enemies)
	if targets.is_empty() or not _round_context_is_valid(profile, organ, enemies, container,
			scene, revision, system, generation):
		return
	var primary: BasicEnemy = targets[0]
	var drafts: Array[SporeProjectile] = []
	var original_modes: Array[int] = []
	var original_visibility: Array[bool] = []
	var request := profile.create_damage_request()
	var prepared: bool = WeaponProfile.is_valid_damage_request(request)
	var commitment_ids := PackedStringArray()
	# 整轮同步预留先于实例化和树通知；其他武器重入会立即看到所有待发伤害。
	if prepared and is_instance_valid(system):
		_preparing_system = system
		for target: BasicEnemy in targets:
			var commitment_id := system.prepare_commitment(target, request, self)
			if commitment_id.is_empty():
				prepared = false
				break
			commitment_ids.append(commitment_id)
			_preparing_ids.append(commitment_id)
	for index: int in range(targets.size()):
		if not prepared:
			break
		var target := targets[index]
		var instance: Node = scene.instantiate()
		if not is_instance_valid(instance):
			prepared = false
		elif not instance is SporeProjectile:
			instance.free()
			prepared = false
		else:
			var projectile := instance as SporeProjectile
			drafts.append(projectile)
			original_modes.append(projectile.process_mode)
			original_visibility.append(projectile.visible)
			projectile.process_mode = Node.PROCESS_MODE_DISABLED
			projectile.visible = false
			prepared = _round_context_is_valid(profile, organ, enemies, container, scene,
					revision, system, generation) \
					and _targets_are_current(targets, profile, organ, enemies, commitment_ids)
			if prepared:
				prepared = projectile.launch_request(target, request.duplicate(true))
			if prepared:
				prepared = is_instance_valid(projectile) and not projectile.is_queued_for_deletion() \
						and _round_context_is_valid(profile, organ, enemies, container, scene,
							revision, system, generation) \
						and _targets_are_current(targets, profile, organ, enemies, commitment_ids)
			if prepared and is_instance_valid(system):
				prepared = projectile.bind_damage_commitment(system, commitment_ids[index])
			if prepared:
				prepared = _round_context_is_valid(profile, organ, enemies, container, scene,
							revision, system, generation) \
						and _targets_are_current(targets, profile, organ, enemies, commitment_ids)
			if prepared:
				# 树通知仍正常执行；草稿不能移动、命中或提前成为付费的一发。
				container.add_child(projectile)
				if is_instance_valid(projectile):
					projectile.global_position = global_position
				prepared = _round_context_is_valid(profile, organ, enemies, container, scene,
							revision, system, generation) \
						and _targets_are_current(targets, profile, organ, enemies, commitment_ids) \
						and _drafts_are_valid(drafts, targets, container, system, commitment_ids)
	prepared = prepared and drafts.size() == targets.size() \
			and _round_context_is_valid(profile, organ, enemies, container, scene,
					revision, system, generation) \
			and _targets_are_current(targets, profile, organ, enemies, commitment_ids) \
			and _drafts_are_valid(drafts, targets, container, system, commitment_ids)
	if not prepared:
		_discard_round(drafts, system, commitment_ids)
		return
	# 批量提交与静默扣费之间没有公开回调；失败只撤销本轮记录和草稿。
	if is_instance_valid(system) and not system.commit_batch(commitment_ids):
		_discard_round(drafts, system, commitment_ids)
		return
	if not organ._consume_volley_nutrition(profile.nutrition_cost):
		_discard_round(drafts, system, commitment_ids)
		return
	_clear_preparation()

	# 扣费之后没有回滚：回调暂停、换配置或删除目标都不能改写已经付费的齐射。
	_shot_sequence += 1
	_last_shot_id = "%d:%d" % [get_instance_id(), _shot_sequence]
	_rounds_fired += 1
	_projectiles_fired += drafts.size()
	_nutrition_spent += profile.nutrition_cost
	var shot_id := _last_shot_id
	var projectile_count := drafts.size()
	for projectile: SporeProjectile in drafts:
		projectile.set_meta("shot_id", shot_id)
	# 激活属性会同步通知观察者；先发布已固定的整轮账目。
	volley_committed.emit(shot_id, profile.nutrition_cost, projectile_count)
	for index: int in range(drafts.size()):
		var projectile: Variant = drafts[index]
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.process_mode = original_modes[index]
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.visible = original_visibility[index]
	shot_fired.emit(primary if is_instance_valid(primary) else null)
	if is_instance_valid(organ):
		organ._publish_volley_inventory()
		if not organ.is_queued_for_deletion() and organ.is_inside_tree():
			organ.play_fire_feedback()
	if not is_queued_for_deletion() and is_inside_tree():
		_play_muzzle_flash()


func _round_context_is_valid(profile: WeaponProfile, organ: Variant, enemies: Variant,
		container: Variant, scene: PackedScene, revision: int,
		system: Variant, generation: int) -> bool:
	return revision == _state_revision and organ == inventory_owner and enemies == enemy_container \
			and container == projectile_container and scene == projectile_scene \
			and system == targeting_system and _targeting_epoch_is_current(system, generation) \
			and _is_active() and _has_live_firing_inputs() \
			and organ.nutrition >= profile.nutrition_cost and _profiles_match(profile, _get_profile())


func _targets_are_current(targets: Array[BasicEnemy], profile: WeaponProfile,
		organ: Variant, enemies: Variant, ignored_ids: PackedStringArray) -> bool:
	if not _is_live_processable(organ) or not _is_live_processable(enemies):
		return false
	var current := _select_targets(profile, organ.global_position, enemies, ignored_ids)
	if current.size() != targets.size():
		return false
	for index: int in range(targets.size()):
		if not is_instance_valid(targets[index]) or targets[index] != current[index]:
			return false
	return true


func _drafts_are_valid(drafts: Array[SporeProjectile], targets: Array[BasicEnemy],
		container: Variant, system: Variant, commitment_ids: PackedStringArray) -> bool:
	for index: int in range(drafts.size()):
		var projectile: Variant = drafts[index]
		if not is_instance_valid(projectile) or projectile.is_queued_for_deletion() \
				or not projectile.is_inside_tree() or not projectile.is_node_ready() \
				or projectile.get_parent() != container or projectile.target != targets[index] \
				or projectile.process_mode != Node.PROCESS_MODE_DISABLED or projectile.visible:
			return false
		if is_instance_valid(system) and (index >= commitment_ids.size() \
				or projectile.get_damage_commitment_id() != commitment_ids[index] \
				or not system.is_commitment_live(commitment_ids[index]) \
				or system.is_commitment_committed(commitment_ids[index])):
			return false
	return true


func _discard_round(drafts: Array[SporeProjectile], system: Variant,
		commitment_ids: PackedStringArray) -> void:
	_clear_preparation()
	if is_instance_valid(system):
		for commitment_id: String in commitment_ids:
			system.release_commitment(commitment_id)
	for index: int in range(drafts.size()):
		var projectile: Variant = drafts[index]
		if is_instance_valid(projectile):
			projectile.cancel_flight()
		if is_instance_valid(projectile):
			projectile.free()


func _clear_preparation() -> void:
	_preparing_ids.clear()
	_preparing_system = null


func _targeting_epoch_is_current(system: Variant, generation: int) -> bool:
	if generation < 0:
		return system == null and not _has_targeting_configuration and not targeting_required
	return _is_live_processable(system) and system.is_accepting() \
			and int(system.get_snapshot().get("generation", -1)) == generation


func _select_targets(profile: WeaponProfile, origin: Vector2, enemies: Node2D,
		ignored_ids: PackedStringArray = PackedStringArray()) -> Array[BasicEnemy]:
	var selected: Array[BasicEnemy] = []
	if not _has_live_targeting() or not _is_live_processable(enemies):
		return selected
	var candidates: Array[Dictionary] = []
	var maximum_distance := profile.attack_range + RANGE_TOLERANCE
	for child: Node in enemies.get_children():
		if child is BasicEnemy and _is_live_processable(child) and child.is_alive():
			var distance := origin.distance_squared_to(child.global_position)
			var remaining: int = targeting_system.get_remaining_health(child, ignored_ids) \
					if is_instance_valid(targeting_system) else child.health
			if remaining > 0 and is_finite(distance) and distance <= maximum_distance * maximum_distance:
				candidates.append({"target": child, "distance": distance,
					"preferred": is_instance_valid(targeting_system) and child == targeting_system.get_priority_target(),
					"attacking_core": child.is_attacking_core(),
					"core_distance": child.get_core_distance_squared(), "id": child.get_instance_id()})
	candidates.sort_custom(_target_precedes)
	if candidates.is_empty():
		return selected
	var primary: BasicEnemy = candidates[0]["target"]
	selected.append(primary)
	if profile.damage_type == WeaponProfile.DamageType.SCATTER:
		var primary_direction := primary.global_position - origin
		if primary_direction == Vector2.ZERO:
			primary_direction = Vector2.RIGHT
		var half_angle := deg_to_rad(profile.spread_angle_degrees * 0.5 + ANGLE_TOLERANCE_DEGREES)
		for candidate: Dictionary in candidates:
			if selected.size() >= profile.max_targets:
				break
			var enemy: BasicEnemy = candidate["target"]
			if enemy == primary:
				continue
			var direction := enemy.global_position - origin
			if direction == Vector2.ZERO:
				direction = Vector2.RIGHT
			var angle := absf(wrapf(direction.angle() - primary_direction.angle(), -PI, PI))
			if angle <= half_angle:
				selected.append(enemy)
	return selected


func _target_precedes(first: Dictionary, second: Dictionary) -> bool:
	if bool(first.get("preferred", false)) != bool(second.get("preferred", false)):
		return bool(first.get("preferred", false))
	if bool(first["attacking_core"]) != bool(second["attacking_core"]):
		return bool(first["attacking_core"])
	var first_core_distance: float = first["core_distance"]
	var second_core_distance: float = second["core_distance"]
	if first_core_distance != second_core_distance:
		return first_core_distance < second_core_distance
	var first_distance: float = first["distance"]
	var second_distance: float = second["distance"]
	if first_distance == second_distance:
		return int(first["id"]) < int(second["id"])
	return first_distance < second_distance


func _profiles_match(first: WeaponProfile, second: WeaponProfile) -> bool:
	return first.damage == second.damage and first.fire_interval == second.fire_interval \
			and first.attack_range == second.attack_range and first.nutrition_cost == second.nutrition_cost \
			and first.max_targets == second.max_targets and first.spread_angle_degrees == second.spread_angle_degrees \
			and first.damage_type == second.damage_type


func _is_active() -> bool:
	return _firing_enabled and has_valid_profile() and _is_live_processable(self) \
			and _is_live_processable(inventory_owner) and inventory_owner.is_work_enabled() \
			and _has_live_targeting()


func _has_live_targeting() -> bool:
	if targeting_system == null and not _has_targeting_configuration:
		return not targeting_required
	return _is_live_processable(targeting_system) and targeting_system.is_accepting()


func _has_live_firing_inputs() -> bool:
	return _is_live_processable(enemy_container) and _is_live_processable(projectile_container) \
			and projectile_scene != null and projectile_scene.can_instantiate()


func _is_live_processable(node: Variant) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion() \
			and node.is_inside_tree() and node.is_node_ready() and node.can_process()


func _connect_owner_work_state() -> void:
	if not is_instance_valid(inventory_owner) or _connected_owner == inventory_owner:
		return
	_connected_owner = inventory_owner
	_owner_work_callback = _on_owner_work_state_changed.bind(inventory_owner)
	_connected_owner.work_state_changed.connect(_owner_work_callback)


func _disconnect_owner_work_state() -> void:
	if is_instance_valid(_connected_owner) and _owner_work_callback.is_valid() \
			and _connected_owner.work_state_changed.is_connected(_owner_work_callback):
		_connected_owner.work_state_changed.disconnect(_owner_work_callback)
	_connected_owner = null
	_owner_work_callback = Callable()


func _get_profile() -> WeaponProfile:
	if _active_profile == null:
		_active_profile = WeaponProfile.new()
		# 独立旧武器保持 300，关卡显式 100 和测试覆写均通过兼容属性进入同一副本。
		_active_profile.attack_range = 300.0
	return _active_profile


func _sync_legacy_timer_interval() -> void:
	var timer := get_node_or_null("FireTimer") as Timer
	if timer != null and is_finite(timer.wait_time) and timer.wait_time > 0.0:
		_get_profile().fire_interval = timer.wait_time


func _apply_profile(restart_cooldown: bool) -> void:
	var timer := get_node_or_null("FireTimer") as Timer
	if timer != null:
		var was_running := not timer.is_stopped()
		timer.wait_time = _get_profile().fire_interval
		if not _firing_enabled or (is_instance_valid(inventory_owner) and not inventory_owner.is_work_enabled()):
			timer.stop()
		elif restart_cooldown and timer.is_inside_tree() and was_running:
			timer.start(_get_profile().fire_interval)
	_update_range_outline()


func _refresh_scheduler(restart_cooldown: bool) -> void:
	var timer := get_node_or_null("FireTimer") as Timer
	if timer == null:
		return
	if not _is_active():
		timer.stop()
	elif restart_cooldown and timer.is_inside_tree():
		timer.start(_get_profile().fire_interval)


func _update_range_outline() -> void:
	var outline := get_node_or_null("RangeOutline") as Line2D
	if outline == null:
		return
	var points := PackedVector2Array()
	for index: int in range(RANGE_SEGMENTS):
		points.append(Vector2.from_angle(TAU * index / RANGE_SEGMENTS) * _get_profile().attack_range)
	outline.points = points
	_update_range_origin()


func _update_range_origin() -> void:
	var outline := get_node_or_null("RangeOutline") as Line2D
	if outline == null or not is_inside_tree():
		return
	outline.top_level = true
	if is_instance_valid(inventory_owner) and inventory_owner.is_inside_tree():
		outline.global_position = inventory_owner.global_position
	else:
		outline.global_position = global_position


func _play_muzzle_flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	muzzle.modulate.a = 1.0
	_flash_tween = create_tween()
	_flash_tween.tween_property(muzzle, "modulate:a", 0.0, 0.14)
