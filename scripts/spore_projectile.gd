class_name SporeProjectile
extends Node2D
## 一发孢子追踪发射时选定的目标；目标消失则消散，不重新寻找目标。

signal hit(enemy: BasicEnemy, actual_damage: int)

@export_range(1.0, 1200.0, 1.0) var speed: float = 360.0

var target: BasicEnemy
var _raw_damage: int = 0
var _damage_type: int = WeaponProfile.DamageType.NORMAL
var _launched: bool = false
var _finished: bool = false
var _settling_damage: bool = false
var _damage_commitment_system_ref: WeakRef
var _damage_commitment_id: String = ""


func _exit_tree() -> void:
	_finished = true
	_release_damage_commitment()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_finished = true
		_release_damage_commitment()


func launch_request(enemy: BasicEnemy, request: Dictionary) -> bool:
	if _launched or _finished or is_queued_for_deletion():
		return false
	if not is_instance_valid(enemy) or not enemy.is_inside_tree() or not enemy.is_alive():
		return false
	if not WeaponProfile.is_valid_damage_request(request):
		return false
	target = enemy
	# 仅保留已校验的标量，调用方之后修改请求不会改变飞行中的伤害。
	_raw_damage = request["raw_damage"]
	_damage_type = request["damage_type"]
	_launched = true
	return true


func launch(enemy: BasicEnemy, damage: int) -> void:
	launch_request(enemy, {
		"raw_damage": damage,
		"damage_type": WeaponProfile.DamageType.NORMAL,
	})


func bind_damage_commitment(system: CombatTargetingSystem, commitment_id: String) -> bool:
	if not _launched or _finished or is_queued_for_deletion() \
			or not _damage_commitment_id.is_empty() or commitment_id.is_empty() \
			or not is_instance_valid(system):
		return false
	if not system._bind_projectile(commitment_id, self):
		return false
	_damage_commitment_system_ref = weakref(system)
	_damage_commitment_id = commitment_id
	return true


func get_damage_commitment_id() -> String:
	return _damage_commitment_id


func get_damage_type() -> int:
	return _damage_type


func cancel_flight() -> void:
	_finish()


func _physics_process(delta: float) -> void:
	# 齐射草稿尚未提交时禁用处理；同步回调手动重入也必须遵守同一暂停边界。
	if not _launched or _finished or not is_inside_tree() or not can_process():
		return
	if not _damage_commitment_id.is_empty():
		var system := _get_damage_commitment_system()
		if not is_instance_valid(system) or not system.is_commitment_live(_damage_commitment_id):
			_finish()
			return
		if not system.is_commitment_committed(_damage_commitment_id):
			return
	if not is_instance_valid(target) or not target.is_inside_tree() or not target.is_alive():
		_finish()
		return

	var aim := target.get_aim_position()
	var movement := maxf(speed, 0.0) * delta
	global_rotation = (aim - global_position).angle()
	if global_position.distance_to(aim) <= movement:
		# 先阻止重入命中，但保留承诺直到受伤入口的所有同步回调返回。
		_finished = true
		_settling_damage = true
		var actual_damage := target.apply_damage({
			"raw_damage": _raw_damage,
			"damage_type": _damage_type,
		})
		_settling_damage = false
		_release_damage_commitment()
		if actual_damage > 0:
			hit.emit(target, actual_damage)
		if not is_queued_for_deletion():
			queue_free()
	else:
		global_position = global_position.move_toward(aim, movement)


func _on_lifetime_timer_timeout() -> void:
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_release_damage_commitment()
	queue_free()


func _get_damage_commitment_system() -> CombatTargetingSystem:
	if _damage_commitment_system_ref == null:
		return null
	var object: Object = _damage_commitment_system_ref.get_ref()
	return object as CombatTargetingSystem if is_instance_valid(object) else null


func _release_damage_commitment() -> void:
	var system := _get_damage_commitment_system()
	if is_instance_valid(system) and not _damage_commitment_id.is_empty():
		system.release_commitment(_damage_commitment_id)
