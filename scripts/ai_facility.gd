class_name AIFacility
extends BasicEnemy
## 固定设施共用弹丸与受击接口；不移动、不掉落尸体、不属于生产批次成员。

signal facility_destroyed(facility_id: StringName)
signal priority_requested(facility_id: StringName)

@export var facility_id: StringName = &"left"
@export var display_name: String = "AI设施"

var production_phase: StringName = &"preparing"
var production_remaining: float = 30.0
var prioritized: bool = false


func _ready() -> void:
	super._ready()
	sprite.hide()
	get_node("Visuals/Shadow").hide()
	attack_timer.stop()
	_refresh_view()


func _physics_process(_delta: float) -> void:
	pass


func creates_remains() -> bool:
	return false


func is_attacking_core() -> bool:
	return false


func get_core_distance_squared() -> float:
	return INF


func set_production_state(phase: StringName, seconds: float) -> void:
	production_phase = phase
	production_remaining = maxf(seconds, 0.0)
	_refresh_view()


func get_facility_snapshot() -> Dictionary:
	return {"id": String(facility_id), "name": display_name, "health": health,
		"max_health": max_health, "destroyed": not is_alive(),
		"phase": String(production_phase), "remaining": production_remaining,
		"prioritized": prioritized}


func _refresh_view() -> void:
	if not is_node_ready():
		return
	var names := {&"preparing": "蓄能", &"warning": "即将生成", &"generating": "生成中", &"cooldown": "冷却",
		&"blocked": "出口受阻", &"capped": "生产受限", &"stopped": "已停止"}
	($Title as Label).text = display_name + (" · 优先目标" if prioritized and is_alive() else "")
	($Status as Label).text = "%d/%d · %s %ds" % [health, max_health,
		names.get(production_phase, String(production_phase)), ceili(production_remaining)] if is_alive() else "已摧毁 · 永久停产"
	queue_redraw()


func _draw() -> void:
	if prioritized and is_alive():
		draw_arc(Vector2.ZERO, 43.0, 0.0, TAU, 40, Color("ffd889"), 3.0, true)


func _play_hit_feedback() -> void:
	var body := $Visuals/Factory as CanvasItem
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	body.modulate = Color(2, 1.3, 1)
	_hit_tween = create_tween()
	_hit_tween.tween_property(body, "modulate", Color.WHITE, 0.16)
	_refresh_view()


func _die() -> void:
	if _death_started:
		return
	_death_started = true
	prioritized = false
	attack_timer.stop()
	health_bar.hide()
	production_phase = &"stopped"
	production_remaining = 0.0
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	visuals.modulate = Color(0.45, 0.45, 0.45, 0.55)
	died.emit(self)
	facility_destroyed.emit(facility_id)
	_refresh_view()


func _on_hit_area_input(_viewport: Node, event: InputEvent, _shape_index: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		priority_requested.emit(facility_id)
		get_viewport().set_input_as_handled()
