extends Sprite2D
## 只观察敌人的真实生命与类型；保留原动画节点供寻路、瞄准和旧章节使用。

const HIT_DURATION: float = 0.16

var _enemy: BasicEnemy
var _theme: WorldArtTheme
var _idle_texture: Texture2D
var _bounds := Vector2(60.0, 54.0)
var _last_health: int = 0
var _hit_remaining: float = 0.0
var _dead: bool = false


func _ready() -> void:
	_enemy = get_parent().get_parent() as BasicEnemy
	if _enemy == null or _enemy is AIFacility:
		hide()
		set_process(false)
		return
	_theme = WorldArt.find_theme(self)
	_idle_texture = _choose_texture()
	if _idle_texture == null:
		hide()
		set_process(false)
		return
	WorldArt.fit_sprite(self, _idle_texture, _bounds)
	show()
	_enemy.get_node("Visuals/Sprite").hide()
	# 旧轮廓和颚部只属于像素占位图；数值护甲提示仍保留。
	for path: String in ["ArmorOutline", "ArmorRim", "Jaw"]:
		var legacy := get_parent().get_node_or_null(path) as CanvasItem
		if legacy != null:
			legacy.hide()
	var role := get_parent().get_node_or_null("ArtRole") as Label
	if role != null:
		role.visible = not role.text.is_empty()
	_last_health = _enemy.health if _enemy.is_node_ready() else _enemy.max_health
	_enemy.died.connect(_on_enemy_died)


func _choose_texture() -> Texture2D:
	if _theme == null:
		return null
	match _enemy.get_archetype():
		BasicEnemy.Archetype.ARMORED:
			_bounds = Vector2(70.0, 66.0)
			return _theme.enemy_armored
		BasicEnemy.Archetype.SWARM:
			_bounds = Vector2(38.0, 36.0)
			return _theme.enemy_swarm
		BasicEnemy.Archetype.GNAWER, BasicEnemy.Archetype.SILK_GNAWER, BasicEnemy.Archetype.JUNCTION_GNAWER:
			_bounds = Vector2(64.0, 54.0)
			return _theme.enemy_gnawer
	return _theme.enemy_normal


func _process(delta: float) -> void:
	if _dead or not is_instance_valid(_enemy):
		return
	if _enemy.health < _last_health and _enemy.is_alive():
		_hit_remaining = HIT_DURATION
		if _enemy.get_archetype() == BasicEnemy.Archetype.NORMAL and _theme.enemy_hit != null:
			WorldArt.fit_sprite(self, _theme.enemy_hit, _bounds)
	_last_health = _enemy.health
	_hit_remaining = maxf(0.0, _hit_remaining - delta)
	if _hit_remaining > 0.0:
		modulate = Color.WHITE.lerp(Color(1.7, 1.25, 1.1), _hit_remaining / HIT_DURATION)
	else:
		modulate = Color.WHITE
		if texture != _idle_texture:
			WorldArt.fit_sprite(self, _idle_texture, _bounds)


func _on_enemy_died(_source: BasicEnemy) -> void:
	_dead = true
	modulate = Color.WHITE
	if _enemy.get_archetype() == BasicEnemy.Archetype.NORMAL and _theme.enemy_dead != null:
		WorldArt.fit_sprite(self, _theme.enemy_dead, _bounds)
	# 父级原有死亡淡出统一处理贴图、阴影与类型提示，不延迟死亡结算。
