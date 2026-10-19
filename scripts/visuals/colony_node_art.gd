extends Sprite2D
## 生长尖端显示花苞，已形成的菌结显示盛开花朵；受损枯萎由真实生命值决定。

const BUD: Texture2D = preload("res://resources/art/textures/node_idle.tres")
const BLOOM: Texture2D = preload("res://resources/art/textures/node_growing.tres")
const WILTED: Texture2D = preload("res://resources/art/textures/node_dead.tres")

@export var is_growth_tip: bool = false
@export var display_bounds: Vector2 = Vector2(36, 34)


func _ready() -> void:
	var tissue: Node2D = get_parent() as Node2D
	if tissue.has_signal("health_changed"):
		tissue.connect("health_changed", _on_health_changed)
	_refresh()


func _on_health_changed(_current: float, _maximum: float) -> void:
	_refresh()


func _refresh() -> void:
	var tissue: Node2D = get_parent() as Node2D
	var alive: bool = bool(tissue.call("is_functional"))
	var image: Texture2D = WILTED if not alive else (BUD if is_growth_tip else BLOOM)
	WorldArt.fit_sprite(self, image, display_bounds)
