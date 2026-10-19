extends Node
## 只读取已经冻结的弹丸类型；伤害与命中仍由 SporeProjectile 负责。

@export var normal_texture: Texture2D
@export var piercing_texture: Texture2D
var _last_type: int = -1
@onready var projectile: SporeProjectile = get_parent()
@onready var art: Sprite2D = get_parent().get_node("Art")


func _ready() -> void:
	_refresh()


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	var type := projectile.get_damage_type()
	if _last_type == type:
		return
	_last_type = type
	WorldArt.fit_sprite(art, piercing_texture if type == WeaponProfile.DamageType.ARMOR_PIERCING else normal_texture, Vector2(15, 15), false)
	art.rotation = PI
	art.modulate = Color("e6adc4") if type == WeaponProfile.DamageType.SCATTER else Color.WHITE
