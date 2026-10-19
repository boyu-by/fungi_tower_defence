class_name OrganDifferentiationView
extends Node2D
## 只读器官的真实攻击类型与分化快照；形态绘制不修改武器、库存或计时。

const PENCIL_ART: Texture2D = preload("res://resources/art/textures/pencil_turret.tres")
const ERASER_ART: Texture2D = preload("res://resources/art/textures/eraser_turret.tres")
const SCATTER_ART: Texture2D = preload("res://resources/art/textures/scatter_turret.tres")

const PIERCING_CAP: Array[Vector2] = [
	Vector2(-25, -25), Vector2(-20, -32), Vector2(-24, -47), Vector2(-12, -36),
	Vector2(-5, -52), Vector2(2, -37), Vector2(13, -49), Vector2(17, -35),
	Vector2(26, -44), Vector2(24, -26), Vector2(12, -20), Vector2(-11, -20),
]
const PIERCING_HIGHLIGHT: Array[Vector2] = [
	Vector2(-16, -31), Vector2(-11, -34), Vector2(-6, -41), Vector2(-2, -34),
	Vector2(10, -39), Vector2(13, -32), Vector2(2, -28), Vector2(-7, -28),
]
const SCATTER_CAP: Array[Vector2] = [
	Vector2(-25, -25), Vector2(-29, -33), Vector2(-26, -41), Vector2(-19, -44),
	Vector2(-12, -40), Vector2(-11, -47), Vector2(-5, -52), Vector2(4, -52),
	Vector2(11, -47), Vector2(12, -40), Vector2(20, -44), Vector2(27, -40),
	Vector2(30, -32), Vector2(25, -25), Vector2(12, -20), Vector2(-11, -20),
]
const SCATTER_HIGHLIGHT: Array[Vector2] = [
	Vector2(-21, -34), Vector2(-18, -39), Vector2(-10, -33), Vector2(-4, -45),
	Vector2(3, -46), Vector2(11, -33), Vector2(20, -39), Vector2(23, -34),
	Vector2(12, -27), Vector2(-10, -27),
]

@export var organ: AttackOrgan

var _bound_organ: AttackOrgan
var _cap: Polygon2D
var _highlight: Polygon2D
var _art_sprite: Sprite2D
var _normal_cap_polygon: PackedVector2Array = PackedVector2Array()
var _normal_highlight_polygon: PackedVector2Array = PackedVector2Array()
var _normal_cap_color: Color = Color.WHITE
var _normal_highlight_color: Color = Color.WHITE
var _last_attack_type: int = -1
var _visual_state: Dictionary = {
	"attack_type": WeaponProfile.DamageType.NORMAL,
	"differentiating": false, "paused": false, "progress": 0.0,
}


func _ready() -> void:
	set_process(false)
	if organ == null:
		organ = get_parent() as AttackOrgan
	refresh()


func _exit_tree() -> void:
	_disconnect_organ()
	_restore_base_cap()


func _draw() -> void:
	if not bool(_visual_state.get("differentiating", false)):
		return
	var center := Vector2(0.0, -31.0)
	var paused: bool = bool(_visual_state.get("paused", false))
	var color := Color(0.95, 0.82, 0.48, 0.95) if not paused else Color(0.69, 0.75, 0.72, 0.95)
	var progress: float = clampf(float(_visual_state.get("progress", 0.0)), 0.0, 1.0)
	draw_arc(center, 32.0, -PI * 0.5, PI * 1.5, 48, Color(color, 0.24), 2.0, true)
	if progress > 0.0:
		draw_arc(center, 32.0, -PI * 0.5, -PI * 0.5 + TAU * progress, 48, color, 3.0, true)
	if paused:
		draw_line(Vector2(-3.0, -12.0), Vector2(-3.0, -6.0), color, 2.0, true)
		draw_line(Vector2(3.0, -12.0), Vector2(3.0, -6.0), color, 2.0, true)


func _on_differentiation_changed(_snapshot: Dictionary) -> void:
	refresh()


func _on_organ_exiting() -> void:
	organ = null
	refresh()


func configure(value: AttackOrgan) -> void:
	organ = value if _is_live_organ(value) else null
	refresh()


func refresh() -> void:
	var current: AttackOrgan = organ if _is_live_organ(organ) else null
	if current != _bound_organ:
		_disconnect_organ()
		_restore_base_cap()
		_bound_organ = current
		_capture_base_cap()
		if current != null:
			current.differentiation_changed.connect(_on_differentiation_changed)
			current.tree_exiting.connect(_on_organ_exiting)
	var state: Dictionary = get_visual_state()
	var attack_type: int = int(state.get("attack_type", WeaponProfile.DamageType.NORMAL))
	if attack_type != _last_attack_type:
		_apply_cap_shape(attack_type)
		_last_attack_type = attack_type
	if state != _visual_state:
		_visual_state = state
		queue_redraw()


func get_visual_state() -> Dictionary:
	if not _is_live_organ(organ):
		return {"attack_type": WeaponProfile.DamageType.NORMAL, "differentiating": false, "paused": false, "progress": 0.0}
	var snapshot: Dictionary = organ.get_differentiation_snapshot()
	var state: StringName = StringName(snapshot.get("state", &"idle"))
	# 目标方向只用于任务；最终形态始终来自匹配武器的实际配置。
	return {
		"attack_type": organ.get_attack_type(),
		"differentiating": state in [&"waiting", &"differentiating", &"paused"],
		"paused": state == &"paused",
		"progress": clampf(float(snapshot.get("progress", 0.0)), 0.0, 1.0),
	}


func _capture_base_cap() -> void:
	_cap = null
	_highlight = null
	_art_sprite = null
	_last_attack_type = -1
	if not _is_live_organ(_bound_organ):
		return
	_cap = _bound_organ.get_node_or_null("Cap") as Polygon2D
	_highlight = _bound_organ.get_node_or_null("CapHighlight") as Polygon2D
	_art_sprite = _bound_organ.get_node_or_null("Cap/ArtSprite") as Sprite2D
	if is_instance_valid(_cap):
		_normal_cap_polygon = _cap.polygon.duplicate()
		_normal_cap_color = _cap.color
	if is_instance_valid(_highlight):
		_normal_highlight_polygon = _highlight.polygon.duplicate()
		_normal_highlight_color = _highlight.color


func _apply_cap_shape(attack_type: int) -> void:
	if not is_instance_valid(_cap):
		return
	# 子贴图沿用 Cap 的真实射击回弹与休眠缩放，旧多边形保留兼容接口。
	var image: Texture2D = PENCIL_ART
	if attack_type == WeaponProfile.DamageType.ARMOR_PIERCING:
		image = ERASER_ART
	elif attack_type == WeaponProfile.DamageType.SCATTER:
		image = SCATTER_ART
	WorldArt.fit_sprite(_art_sprite, image, Vector2(66, 72))
	match attack_type:
		WeaponProfile.DamageType.ARMOR_PIERCING:
			_cap.polygon = PackedVector2Array(PIERCING_CAP)
			_cap.color = Color(0.43, 0.58, 0.55, 1.0)
			if is_instance_valid(_highlight):
				_highlight.polygon = PackedVector2Array(PIERCING_HIGHLIGHT)
				_highlight.color = Color(0.73, 0.84, 0.72, 1.0)
		WeaponProfile.DamageType.SCATTER:
			_cap.polygon = PackedVector2Array(SCATTER_CAP)
			_cap.color = Color(0.71, 0.37, 0.48, 1.0)
			if is_instance_valid(_highlight):
				_highlight.polygon = PackedVector2Array(SCATTER_HIGHLIGHT)
				_highlight.color = Color(0.91, 0.69, 0.59, 1.0)
		_:
			_restore_base_cap()


func _restore_base_cap() -> void:
	if is_instance_valid(_cap):
		_cap.polygon = _normal_cap_polygon
		_cap.color = _normal_cap_color
	if is_instance_valid(_highlight):
		_highlight.polygon = _normal_highlight_polygon
		_highlight.color = _normal_highlight_color


func _disconnect_organ() -> void:
	if is_instance_valid(_bound_organ):
		if _bound_organ.differentiation_changed.is_connected(_on_differentiation_changed):
			_bound_organ.differentiation_changed.disconnect(_on_differentiation_changed)
		if _bound_organ.tree_exiting.is_connected(_on_organ_exiting):
			_bound_organ.tree_exiting.disconnect(_on_organ_exiting)
	_bound_organ = null


func _is_live_organ(value: Variant) -> bool:
	return is_instance_valid(value) and value is AttackOrgan and value.is_inside_tree() and not value.is_queued_for_deletion()
