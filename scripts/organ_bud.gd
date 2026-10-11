class_name OrganBud
extends Node2D
## 惰性的器官芽只展示培育快照；营养和阶段由 CultivationSystem 独占修改。

const STEM_COLOR := Color("779c66")
const ACTIVE_COLOR := Color("dab665")
const DORMANT_COLOR := Color("788278")

var _snapshot: Dictionary = {}


func _draw() -> void:
	var progress: float = float(_snapshot.get("progress", 0.0))
	var state: StringName = _snapshot.get("state", &"idle")
	var bud_color: Color = DORMANT_COLOR if state == &"cancelled" or state == &"paused" else ACTIVE_COLOR
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
