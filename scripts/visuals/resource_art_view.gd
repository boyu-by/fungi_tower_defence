class_name ResourceArtView
extends Sprite2D
## 资源与运输物的外观入口；只读取库存和场景主题，不参与物流结算。

enum Kind { LARGE_RESOURCE, REMAINS, REMAINS_PACKET, NUTRIENT, OBSTACLE }

@export var kind: Kind = Kind.LARGE_RESOURCE
@export var art_bounds: Vector2 = Vector2(108.0, 98.0)
@export var grounded: bool = true
@export var fallback_paths: Array[NodePath] = []

var _theme: WorldArtTheme
var _variant: int = 0
static var _next_nutrient_variant: int = 0


func _ready() -> void:
	_theme = WorldArt.find_theme(self)
	# 每个包只选择一次颜色，不在运输更新中消耗随机数或切换贴图。
	if kind == Kind.NUTRIENT:
		_variant = _next_nutrient_variant
		_next_nutrient_variant = posmod(_next_nutrient_variant + 1, 3)
	refresh_view()
	if kind == Kind.LARGE_RESOURCE:
		var source := get_parent() as LargeCarcass
		if source != null:
			source.resources_changed.connect(_on_resources_changed)
			_refresh_stock(source.get_snapshot())


func refresh_view() -> void:
	if _theme == null:
		return
	var image: Texture2D = _select_texture()
	if image == null:
		return
	var bounds := art_bounds
	var footprint := Vector2.ZERO
	if kind == Kind.OBSTACLE:
		footprint = get_parent().get("size")
		if not footprint.is_finite() or footprint.x <= 0.0 or footprint.y <= 0.0:
			hide()
			return
		bounds = Vector2(footprint.x + 6.0, maxf(footprint.y * 1.6, 72.0))
	WorldArt.fit_sprite(self, image, bounds, grounded)
	if kind == Kind.OBSTACLE:
		# 碰撞矩形以中心定位，贴图底边落在同一矩形的下缘。
		position.y += footprint.y * 0.5
	show()
	for fallback_path: NodePath in fallback_paths:
		var fallback := get_node_or_null(fallback_path) as CanvasItem
		if fallback != null:
			fallback.hide()


func _select_texture() -> Texture2D:
	match kind:
		Kind.LARGE_RESOURCE:
			return _theme.large_resource
		Kind.REMAINS:
			# 只读生成方提供的美术种类，避免地形贴图反向依赖敌人和导航脚本。
			# 开采批次、未标记尸体始终使用通用碎片。
			if _theme.normal_remains != null and not get_parent().has_meta("carcass_batch_id") \
				and StringName(get_parent().get_meta(&"art_remains_kind", &"generic")) == &"camera":
				return _theme.normal_remains
			return _theme.remains
		Kind.REMAINS_PACKET:
			return _theme.remains
		Kind.NUTRIENT:
			if not _theme.nutrients.is_empty():
				return _theme.nutrients[posmod(_variant, _theme.nutrients.size())]
		Kind.OBSTACLE:
			return _theme.obstacle
	return null


func _on_resources_changed(snapshot: Dictionary) -> void:
	_refresh_stock(snapshot)


func _refresh_stock(snapshot: Dictionary) -> void:
	modulate = Color(0.6, 0.6, 0.6, 0.6) \
		if int(snapshot.get("remaining_nutrition", 0)) == 0 else Color.WHITE
