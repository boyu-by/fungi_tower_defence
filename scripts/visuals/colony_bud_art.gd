extends Node2D
## 只读取培育进度，让花苞随实际阶段开放；不推进任务或扣除营养。

const BUD: Texture2D = preload("res://resources/art/textures/node_idle.tres")
const BLOOM: Texture2D = preload("res://resources/art/textures/node_growing.tres")
const WILTED: Texture2D = preload("res://resources/art/textures/node_dead.tres")

var _last_snapshot: Dictionary = {}
var _was_functional: bool = true

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _bud: OrganBud = get_parent() as OrganBud


func _ready() -> void:
	# self_modulate 只遮去父节点的旧绘制，不影响场景中这些子节点。
	_bud.self_modulate.a = 0.0
	_refresh()


func _process(_delta: float) -> void:
	_refresh()


func _draw() -> void:
	var progress: float = clampf(float(_last_snapshot.get("progress", 0.0)), 0.0, 1.0)
	if progress <= 0.0:
		return
	var color := Color("a88043") if _was_functional else Color("8d8583")
	draw_arc(Vector2(0, -21), 25.0, -PI * 0.5, -PI * 0.5 + TAU * progress, 40, color, 2.0, true)


func _refresh() -> void:
	var snapshot: Dictionary = _bud.get_snapshot()
	var functional: bool = _bud.is_functional()
	if snapshot == _last_snapshot and functional == _was_functional and _sprite.texture != null:
		return
	_last_snapshot = snapshot
	_was_functional = functional
	var progress: float = clampf(float(snapshot.get("progress", 0.0)), 0.0, 1.0)
	var image: Texture2D = WILTED if not functional else (BLOOM if progress >= 0.75 else BUD)
	WorldArt.fit_sprite(_sprite, image, Vector2(40, 42) * lerpf(0.7, 1.0, progress))
	_sprite.modulate = Color(0.75, 0.73, 0.75) if snapshot.get("state", &"idle") == &"paused" else Color.WHITE
	queue_redraw()
