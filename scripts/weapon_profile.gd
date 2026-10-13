class_name WeaponProfile
extends Resource
## Validated weapon configuration. Invalid profiles never produce an attack request.

enum DamageType { NORMAL = 0, ARMOR_PIERCING = 1, SCATTER = 2 }

@export var damage: int = 12
@export var fire_interval: float = 0.8
@export var attack_range: float = 178.0
@export var nutrition_cost: int = 1
@export var max_targets: int = 1
@export var spread_angle_degrees: float = 0.0
@export var damage_type: DamageType = DamageType.NORMAL


func get_validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if damage <= 0:
		errors.append("damage must be positive.")
	if not is_finite(fire_interval) or fire_interval <= 0.0:
		errors.append("fire_interval must be finite and positive.")
	if not is_finite(attack_range) or attack_range <= 0.0:
		errors.append("attack_range must be finite and positive.")
	if nutrition_cost <= 0:
		errors.append("nutrition_cost must be positive.")
	if max_targets < 1 or max_targets > 3:
		errors.append("max_targets must be between 1 and 3.")
	if not is_finite(spread_angle_degrees) or spread_angle_degrees < 0.0 or spread_angle_degrees > 360.0:
		errors.append("spread_angle_degrees must be finite and between 0 and 360.")
	if not _is_supported_damage_type(damage_type):
		errors.append("damage_type must be supported.")

	match damage_type:
		DamageType.NORMAL, DamageType.ARMOR_PIERCING:
			if max_targets != 1:
				errors.append("Normal and armor-piercing profiles require exactly one target.")
			if spread_angle_degrees != 0.0:
				errors.append("Normal and armor-piercing profiles require zero spread angle.")
		DamageType.SCATTER:
			if spread_angle_degrees <= 0.0:
				errors.append("Scatter profiles require a positive spread angle.")
	return errors


func is_valid() -> bool:
	return get_validation_errors().is_empty()


func copy_for_instance() -> WeaponProfile:
	if not is_valid():
		return null
	return duplicate(true) as WeaponProfile


func create_damage_request() -> Dictionary:
	if not is_valid():
		return {}
	return {"raw_damage": damage, "damage_type": int(damage_type)}


static func is_valid_damage_request(request: Dictionary) -> bool:
	if not request.has("raw_damage") or not request.has("damage_type"):
		return false
	if typeof(request["raw_damage"]) != TYPE_INT or typeof(request["damage_type"]) != TYPE_INT:
		return false
	var raw_damage: int = request["raw_damage"]
	var request_damage_type: int = request["damage_type"]
	return raw_damage > 0 and _is_supported_damage_type(request_damage_type)


static func _is_supported_damage_type(value: int) -> bool:
	return value == DamageType.NORMAL or value == DamageType.ARMOR_PIERCING or value == DamageType.SCATTER
