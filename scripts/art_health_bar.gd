class_name ArtHealthBar
extends Control
## 图中的心形保持不动，只按真实百分比裁出横条填充区域。
const EMPTY = preload("res://assets/ui/handdrawn/controls/属性条 (1).png")
const FILLED = preload("res://assets/ui/handdrawn/controls/属性演示 (2).png")
var value: float = 0.0:
	set(next):
		value = next
		queue_redraw()
var max_value: float = 100.0:
	set(next):
		max_value = next
		queue_redraw()

func _draw() -> void:
	draw_texture_rect(EMPTY, Rect2(Vector2.ZERO, size), false)
	var ratio: float = clampf(value / maxf(1.0, max_value), 0, 1)
	# 原图230x35，心形及间隔占前40px，右侧190px为实际生命条。
	var source := Rect2(40, 0, 190 * ratio, 35)
	var target := Rect2(size.x * 40.0 / 230.0, 0, size.x * 190.0 / 230.0 * ratio, size.y)
	if ratio > 0:
		draw_texture_rect_region(FILLED, target, source)
