extends Sprite2D
## 设施的待机、损伤与生产提示读取实际状态，不控制产兵和优先攻击。

const DISPLAY_BOUNDS := Vector2(76.0, 76.0)

var _facility: AIFacility
var _theme: WorldArtTheme
var _pulse_time: float = 0.0


func _ready() -> void:
	_facility = get_parent().get_parent().get_parent() as AIFacility
	_theme = WorldArt.find_theme(self)
	if _facility == null or _theme == null or _theme.facility_idle == null:
		hide()
		set_process(false)
		return
	for path: String in ["Body", "Screen", "Grille"]:
		var legacy := get_parent().get_node_or_null(path) as CanvasItem
		if legacy != null:
			legacy.hide()
	show()
	WorldArt.fit_sprite(self, _theme.facility_idle, DISPLAY_BOUNDS)
	_facility.died.connect(_on_facility_died)


func _process(delta: float) -> void:
	if not is_instance_valid(_facility):
		return
	var damaged := float(_facility.health) <= float(_facility.max_health) * 0.5
	var next_texture := _theme.facility_damaged if damaged and _theme.facility_damaged != null else _theme.facility_idle
	if texture != next_texture:
		WorldArt.fit_sprite(self, next_texture, DISPLAY_BOUNDS)
	_pulse_time += delta
	# 只有设施真实处于生成预警/生成状态时才呼吸亮起；优先目标圆环仍由设施绘制。
	if _facility.is_alive() and _facility.production_phase in [&"warning", &"generating"]:
		var glow := 1.0 + 0.08 * (0.5 + 0.5 * sin(_pulse_time * 6.0))
		modulate = Color(glow, glow, glow)
	else:
		modulate = Color.WHITE


func _on_facility_died(_source: BasicEnemy) -> void:
	if _theme.facility_damaged != null:
		WorldArt.fit_sprite(self, _theme.facility_damaged, DISPLAY_BOUNDS)
	modulate = Color.WHITE
