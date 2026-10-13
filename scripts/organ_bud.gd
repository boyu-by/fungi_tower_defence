class_name OrganBud
extends Node2D
## 惰性的器官芽只展示培育快照；营养和阶段由 CultivationSystem 独占修改。

signal health_changed(current: float, maximum: float)
signal tissue_destroyed(tissue: Node2D)

const STEM_COLOR := Color("779c66")
const ACTIVE_COLOR := Color("dab665")
const DIGESTIVE_ACTIVE_COLOR := Color("ba82c4")
const DORMANT_COLOR := Color("788278")

var _snapshot: Dictionary = {}


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
	var host: HyphaNode = get_parent() as HyphaNode
	return is_attackable() and (host == null or host.is_functional())


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




func _draw() -> void:
	var progress: float = float(_snapshot.get("progress", 0.0))
	var state: StringName = _snapshot.get("state", &"idle")
	var active_color: Color = DIGESTIVE_ACTIVE_COLOR if _snapshot.get("organ_kind", &"attack") == &"digestive" else ACTIVE_COLOR
	var bud_color: Color = DORMANT_COLOR if state == &"cancelled" or state == &"paused" or not is_functional() else active_color
	draw_line(Vector2.ZERO, Vector2(0.0, -12.0), STEM_COLOR, 5.0, true)
	draw_circle(Vector2(0.0, -15.0), 10.0, bud_color)
	draw_arc(Vector2(0.0, -15.0), 13.0, -PI / 2.0,
		-PI / 2.0 + TAU * progress, 32, Color("f4db8b"), 2.0, true)


func get_snapshot() -> Dictionary:
	var snapshot: Dictionary = _snapshot.duplicate()
	if snapshot.has("host") and (not is_instance_valid(snapshot["host"]) \
			or snapshot["host"].is_queued_for_deletion()):
		snapshot["host"] = null
	return snapshot


func _set_snapshot(snapshot: Dictionary) -> void:
	# 内部入口仅供 CultivationSystem 使用，不提供自行收款或生长的方法。
	_snapshot = snapshot.duplicate()
	queue_redraw()
