@tool
class_name TerrainRock
extends StaticBody2D
## 碰撞保持实际阻挡矩形；Art 子节点仅根据矩形大小适配章节贴图。

@export var size: Vector2 = Vector2(96.0, 80.0):
	set(value):
		size = value
		_sync_shape()
		_sync_art()
		queue_redraw()
@export var body_color: Color = Color(0.27, 0.29, 0.26, 1.0)
@export var rim_color: Color = Color(0.43, 0.45, 0.39, 1.0)


func _ready() -> void:
	_sync_shape()
	queue_redraw()


func _draw() -> void:
	if not size.is_finite() or size.x <= 0.0 or size.y <= 0.0:
		return
	var art := get_node_or_null("Art") as Sprite2D
	if art != null and art.texture != null and art.visible:
		return
	var footprint: Rect2 = Rect2(-size * 0.5, size)
	draw_rect(footprint, body_color)
	draw_rect(footprint.grow(-1.0), rim_color, false, 2.0)
	var center: Vector2 = size * Vector2(0.12, -0.1)
	draw_line(-size * Vector2(0.36, 0.22), center, rim_color, 2.0)
	draw_line(center, size * Vector2(0.28, 0.3), rim_color, 2.0)


func _sync_art() -> void:
	var art := get_node_or_null("Art") as Sprite2D
	if not Engine.is_editor_hint() and art != null and art.is_node_ready():
		art.call("refresh_view")


func _sync_shape() -> void:
	var collision: CollisionShape2D = get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision == null:
		return
	if not size.is_finite() or size.x <= 0.0 or size.y <= 0.0:
		collision.disabled = true
	else:
		var rectangle: RectangleShape2D = RectangleShape2D.new()
		rectangle.size = size
		collision.shape = rectangle
		collision.disabled = false
