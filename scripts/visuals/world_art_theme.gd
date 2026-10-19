class_name WorldArtTheme
extends Resource
## 每章只切换展示素材，不携带生命、库存、碰撞或关卡规则。

@export_range(1, 3) var chapter: int = 1
@export var large_resource: Texture2D
@export var remains: Texture2D
@export var obstacle: Texture2D
@export var nutrients: Array[Texture2D] = []
@export var enemy_normal: Texture2D
@export var enemy_armored: Texture2D
@export var enemy_swarm: Texture2D
@export var enemy_gnawer: Texture2D
@export var enemy_hit: Texture2D
@export var enemy_dead: Texture2D
@export var facility_idle: Texture2D
@export var facility_damaged: Texture2D
