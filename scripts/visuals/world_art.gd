class_name WorldArt
extends Node
## 地图上的美术主题入口；Sprite节点保留在各自场景中供编辑器检查。

@export var theme: WorldArtTheme


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_style_world.call_deferred()


func _style_world() -> void:
	var world := get_parent().get_node_or_null("World")
	if world == null:
		return
	for node in world.find_children("*", "Label", true, false):
		_style_label(weakref(node))


func _on_node_added(node: Node) -> void:
	var world := get_parent().get_node_or_null("World")
	if node is Label and world != null and world.is_ancestor_of(node):
		_style_label.call_deferred(weakref(node))


func _style_label(reference: WeakRef) -> void:
	var label := reference.get_ref() as Label
	if not is_instance_valid(label) or label.is_queued_for_deletion():
		return
	if label.get_parent().name == &"ArmorHint":
		return
	# 世界标签保留紧凑布局，但手写字体需要至少15px才能看清。
	ArtUI.typography(label, maxi(15, label.get_theme_font_size("font_size")))
	label.add_theme_color_override("font_color", ArtUI.INK)
	label.add_theme_color_override("font_outline_color", Color("f4efdf"))
	label.add_theme_constant_override("outline_size", 3)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


static func find_theme(context: Node) -> WorldArtTheme:
	var cursor: Node = context
	while is_instance_valid(cursor):
		var art := cursor.get_node_or_null("WorldArt") as WorldArt
		if art != null and art.theme != null:
			return art.theme
		cursor = cursor.get_parent()
	return load("res://resources/art/chapter_1.tres") as WorldArtTheme


static func fit_sprite(sprite: Sprite2D, image: Texture2D, bounds: Vector2, grounded: bool = true) -> void:
	if not is_instance_valid(sprite) or image == null:
		return
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.texture = image
	var size := image.get_size()
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var factor := minf(bounds.x / size.x, bounds.y / size.y)
	sprite.scale = Vector2.ONE * factor
	sprite.position.y = -size.y * factor * 0.5 if grounded else 0.0
