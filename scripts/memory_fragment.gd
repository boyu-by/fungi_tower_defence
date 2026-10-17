class_name MemoryFragment
extends Node2D
## 目标只保存身份、收集进度和占位表现；有效覆盖由关卡目标控制器判断。

@export var fragment_id: StringName = &""
@export var display_name: String = "记忆碎片"
@export_multiline var memory_text: String = ""
@export_range(0.1, 60.0) var collection_seconds: float = 5.0

var progress_seconds: float = 0.0
var collected: bool = false
var collecting: bool = false
var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(-100, 27)
	_label.size = Vector2(200, 50)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC"])
	_label.add_theme_font_override("font", font)
	add_child(_label)
	refresh_view()


func refresh_view() -> void:
	if is_instance_valid(_label):
		_label.text = "%s\n%s" % [display_name, "已收集" if collected else (
			"收集中 %.1f / %.0fs" % [progress_seconds, collection_seconds] if collecting else (
				"收集暂停 %.1f / %.0fs" % [progress_seconds, collection_seconds] if progress_seconds > 0 else "连通菌域后收集"))]
	queue_redraw()


func get_snapshot() -> Dictionary:
	return {"id": fragment_id, "name": display_name, "text": memory_text,
		"progress": progress_seconds, "duration": collection_seconds,
		"collected": collected, "collecting": collecting}


func _draw() -> void:
	var color := Color("bce3b2") if collected else Color("efcf8d")
	draw_circle(Vector2.ZERO, 24, Color(color, 0.12))
	draw_colored_polygon(PackedVector2Array([Vector2(0, -20), Vector2(15, 0), Vector2(0, 20), Vector2(-15, 0)]), color)
	if progress_seconds > 0:
		draw_arc(Vector2.ZERO, 29, -PI / 2, -PI / 2 + TAU * clampf(progress_seconds / collection_seconds, 0, 1),
			32, color, 3, true)
