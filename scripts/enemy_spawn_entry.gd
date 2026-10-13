class_name EnemySpawnEntry
extends Resource
## 一条混合生成计划；无效数据由调用者拒绝，不在 setter 中改写。

const MAX_BATCH_COUNT: int = 500
const MAX_INTEGER: int = 9223372036854775807

@export var enemy_scene: PackedScene
@export var group_count: int = 1
@export var group_size: int = 1
@export var group_interval: float = 3.0
@export var member_interval: float = 0.0
@export var member_spacing: float = 24.0
@export var spawn_point_index: int = -1


func is_valid() -> bool:
	return get_validation_errors().is_empty()


func get_validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if enemy_scene == null or not enemy_scene.can_instantiate():
		errors.append("enemy_scene must be an instantiable BasicEnemy scene")
	else:
		var instance: Node = enemy_scene.instantiate()
		if not instance is BasicEnemy:
			errors.append("enemy_scene root must inherit BasicEnemy")
		if is_instance_valid(instance):
			instance.free()
	if group_count <= 0:
		errors.append("group_count must be positive")
	if group_size <= 0:
		errors.append("group_size must be positive")
	if not is_finite(group_interval) or group_interval <= 0.0:
		errors.append("group_interval must be finite and positive")
	if not is_finite(member_interval) or member_interval < 0.0:
		errors.append("member_interval must be finite and nonnegative")
	if not is_finite(member_spacing) or member_spacing < 0.0:
		errors.append("member_spacing must be finite and nonnegative")
	elif group_size > 1 and member_spacing <= 0.0:
		errors.append("multiple members require positive member_spacing")
	if spawn_point_index < -1:
		errors.append("spawn_point_index must be -1 or a child index")
	var total := get_total_count()
	if total < 0 or total > MAX_BATCH_COUNT:
		errors.append("an entry cannot exceed 500 enemies")
	return errors


func get_total_count() -> int:
	if group_count <= 0 or group_size <= 0:
		return 0
	@warning_ignore("integer_division")
	if group_count > MAX_INTEGER / group_size:
		return -1
	return group_count * group_size


func copy_for_instance() -> EnemySpawnEntry:
	var copy := EnemySpawnEntry.new()
	if enemy_scene != null:
		copy.enemy_scene = enemy_scene.duplicate(true) as PackedScene
	copy.group_count = group_count
	copy.group_size = group_size
	copy.group_interval = group_interval
	copy.member_interval = member_interval
	copy.member_spacing = member_spacing
	copy.spawn_point_index = spawn_point_index
	return copy
