extends Sprite2D
## 母核以完整花簇呈现；生命条与营养仍由 MotherCore 管理。

@export var display_bounds: Vector2 = Vector2(106, 104)


func _ready() -> void:
	WorldArt.fit_sprite(self, texture, display_bounds)
	var core: MotherCore = get_parent() as MotherCore
	if core != null:
		core.health_changed.connect(_on_health_changed)
	# 子节点 ready 早于母核初始化，首次保持正常花色。
	modulate = Color.WHITE


func _on_health_changed(current: int, _maximum: int) -> void:
	modulate = Color(0.55, 0.47, 0.45, 0.8) if current <= 0 else Color.WHITE
