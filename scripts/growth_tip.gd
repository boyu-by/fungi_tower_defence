class_name GrowthTip
extends Node2D

## 一个任务始终复用同一尖端；它不是成熟菌结，也不提供覆盖或新的生长起点。

signal health_changed(current: float, maximum: float)
signal tissue_destroyed(tissue: Node2D)

@export var max_health: float = 25.0:
	set(value):
		if not is_finite(value) or value <= 0.0 or max_health == value:
			return
		max_health = value
		_health = minf(_health, value) if _health_was_changed else value
		health_changed.emit(health, max_health)

var health: float:
	get:
		return _health

var _health: float = 25.0
var _health_was_changed: bool = false


func _enter_tree() -> void:
	add_to_group("colony_tissues")


func is_attackable() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func is_functional() -> bool:
	return is_attackable()


func is_repairable() -> bool:
	return is_attackable() and health < max_health


func take_damage(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or not is_attackable():
		return 0.0
	var actual: float = minf(amount, health)
	_health = maxf(health - actual, 0.0)
	_health_was_changed = true
	queue_redraw()
	if health <= 0.0:
		tissue_destroyed.emit(self)
	if is_instance_valid(self) and not is_queued_for_deletion():
		health_changed.emit(health, max_health)
	return actual


func heal(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or not is_repairable():
		return 0.0
	var actual: float = minf(amount, max_health - health)
	_health = minf(health + actual, max_health)
	_health_was_changed = true
	health_changed.emit(health, max_health)
	return actual


func get_health_snapshot() -> Dictionary:
	return {
		"health": health, "max_health": max_health,
		"destroyed": health <= 0.0, "functional": is_functional(),
		"missing_health": maxf(max_health - health, 0.0), "damaged": health < max_health,
	}
