extends Sprite2D
## 只观察敌人的真实生命与类型；保留原动画节点供寻路、瞄准和旧章节使用。

const HIT_DURATION: float = 0.16
const WALK_FRAME_DURATION: float = 0.18

var _enemy: BasicEnemy
var _theme: WorldArtTheme
var _idle_texture: Texture2D
var _bounds := Vector2(60.0, 54.0)
var _last_health: int = 0
var _hit_remaining: float = 0.0
var _dead: bool = false
var _last_position := Vector2.ZERO
var _walk_elapsed: float = 0.0
var _moving: bool = false


func _ready() -> void:
	_enemy = get_parent().get_parent() as BasicEnemy
	if _enemy == null or _enemy is AIFacility:
		hide()
		set_process(false)
		set_physics_process(false)
		return
	_theme = WorldArt.find_theme(self)
	_idle_texture = _choose_texture()
	if _idle_texture == null:
		hide()
		set_process(false)
		set_physics_process(false)
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
	_last_position = _enemy.global_position
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


func _physics_process(delta: float) -> void:
	if _dead or not is_instance_valid(_enemy):
		return
	# 跟随父节点物理帧采样，避免高刷新率显示器在两个移动帧之间重置步态。
	_moving = _enemy.global_position.distance_squared_to(_last_position) > 0.0001
	_last_position = _enemy.global_position
	_walk_elapsed = _walk_elapsed + delta if _moving else 0.0


func _process(delta: float) -> void:
	if _dead or not is_instance_valid(_enemy):
		return
	if _enemy.health < _last_health and _enemy.is_alive():
		_hit_remaining = HIT_DURATION
	_last_health = _enemy.health
	_hit_remaining = maxf(0.0, _hit_remaining - delta)
	var next_texture := _walking_texture() if _moving else _idle_texture
	if _hit_remaining > 0.0:
		var hit_texture := _choose_hit_texture()
		if hit_texture != null:
			next_texture = hit_texture
			modulate = Color.WHITE
		else:
			modulate = Color.WHITE.lerp(Color(1.7, 1.25, 1.1), _hit_remaining / HIT_DURATION)
	else:
		modulate = Color.WHITE
	if texture != next_texture:
		WorldArt.fit_sprite(self, next_texture, _bounds)


func _walking_texture() -> Texture2D:
	# 只有实际走动的普通/群体敌人使用步态；攻击停步或全局暂停不会原地踏步。
	if _enemy.get_archetype() not in [BasicEnemy.Archetype.NORMAL, BasicEnemy.Archetype.SWARM] \
			or _theme.enemy_walk_frames.is_empty():
		return _idle_texture
	var frame := int(_walk_elapsed / WALK_FRAME_DURATION) % _theme.enemy_walk_frames.size()
	var frame_texture := _theme.enemy_walk_frames[frame]
	return frame_texture if frame_texture != null else _idle_texture


func _choose_hit_texture() -> Texture2D:
	if _enemy.get_archetype() == BasicEnemy.Archetype.NORMAL:
		return _theme.enemy_hit
	if not _theme.enemy_shared_states:
		return null
	if _idle_texture == _theme.enemy_armored and _theme.enemy_armored_hit != null:
		return _theme.enemy_armored_hit
	return _theme.enemy_hit


func _on_enemy_died(_source: BasicEnemy) -> void:
	_dead = true
	modulate = Color.WHITE
	if (_enemy.get_archetype() == BasicEnemy.Archetype.NORMAL or _theme.enemy_shared_states) \
			and _theme.enemy_dead != null:
		WorldArt.fit_sprite(self, _theme.enemy_dead, _bounds)
	# 父级原有死亡淡出统一处理贴图、阴影与类型提示，不延迟死亡结算。
