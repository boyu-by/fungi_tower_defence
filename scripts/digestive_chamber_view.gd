extends Node
## 只读消化快照；时间、输入占有和产物生成均由 DigestiveOrgan 管理。

const IDLE_ART: Texture2D = preload("res://resources/art/textures/digest_idle.tres")
const WORK_ART_1: Texture2D = preload("res://resources/art/textures/digest_work_1.tres")
const WORK_ART_2: Texture2D = preload("res://resources/art/textures/digest_work_2.tres")
const ART_BOUNDS := Vector2(68, 76)
const FRAME_DURATION: float = 0.16

const IDLE_CAP_COLOR := Color(0.53, 0.32, 0.52, 1.0)
const DORMANT_CAP_COLOR := Color(0.38, 0.31, 0.41, 1.0)
const PROCESSING_CAP_COLOR := Color(0.72, 0.40, 0.67, 1.0)
const BLOCKED_CAP_COLOR := Color(0.67, 0.43, 0.29, 1.0)
const TOO_LARGE_CAP_COLOR := Color(0.63, 0.31, 0.39, 1.0)
const STOPPED_CAP_COLOR := Color(0.36, 0.32, 0.38, 1.0)
const NORMAL_TEXT_COLOR := Color("594e61")
const WORKING_TEXT_COLOR := Color("95712c")
const BLOCKED_TEXT_COLOR := Color("ad623e")
const STOPPED_TEXT_COLOR := Color("817981")
const MIN_EXPANSION_SCALE := 0.08

var _organ: DigestiveOrgan
var _visuals_ready: bool = false
var _queue_label_center_offset: float = 0.0

@onready var _primary_progress: ProgressBar = get_parent().get_node("ProgressBar") as ProgressBar
@onready var _primary_status: Label = get_parent().get_node("ChamberStatus") as Label
@onready var _primary_cap: Polygon2D = get_parent().get_node("Cap") as Polygon2D
@onready var _primary_pores: Line2D = get_parent().get_node("Pores") as Line2D
@onready var _primary_sprite: Sprite2D = get_parent().get_node("ArtSprite") as Sprite2D
@onready var _queue_label: Label = get_parent().get_node("QueueLabel") as Label
@onready var _second_chamber: Node2D = get_parent().get_node("SecondChamber") as Node2D
@onready var _second_body: Node2D = get_parent().get_node("SecondChamber/Body") as Node2D
@onready var _second_progress: ProgressBar = get_parent().get_node("SecondChamber/ProgressBar") as ProgressBar
@onready var _second_status: Label = get_parent().get_node("SecondChamber/StateLabel") as Label
@onready var _second_cap: Polygon2D = get_parent().get_node("SecondChamber/Body/Cap") as Polygon2D
@onready var _second_pores: Line2D = get_parent().get_node("SecondChamber/Body/Pores") as Line2D
@onready var _second_sprite: Sprite2D = get_parent().get_node("SecondChamber/Body/ArtSprite") as Sprite2D


func _enter_tree() -> void:
	# 重新入树不会再次调用 _ready；已有视觉引用可立即重新绑定。
	if _visuals_ready:
		_bind_digestion_changed()
		_refresh_view()


func _ready() -> void:
	_visuals_ready = true
	_bind_digestion_changed()
	# 首次子节点 ready 时，父器官的 @onready 引用尚未完成初始化。
	if is_instance_valid(_organ) and _organ.is_node_ready():
		_refresh_view()


func _exit_tree() -> void:
	_disconnect_digestion_changed()


func _process(_delta: float) -> void:
	# 逐帧读取只让进度显示跟随真实计时器。
	_refresh_view()


func _on_digestion_changed(_snapshot: Dictionary) -> void:
	# 同步刷新不依赖下一帧；重入通知时重新读取权威快照，避免旧通知覆盖新状态。
	_refresh_view()


func _bind_digestion_changed() -> void:
	_disconnect_digestion_changed()
	_organ = get_parent() as DigestiveOrgan
	if not is_instance_valid(_organ) or _organ.is_queued_for_deletion():
		return
	if not _organ.digestion_changed.is_connected(_on_digestion_changed):
		_organ.digestion_changed.connect(_on_digestion_changed)


func _disconnect_digestion_changed() -> void:
	if is_instance_valid(_organ) and _organ.digestion_changed.is_connected(_on_digestion_changed):
		_organ.digestion_changed.disconnect(_on_digestion_changed)
	_organ = null


func _refresh_view() -> void:
	if not _visuals_ready or not is_inside_tree() or is_queued_for_deletion() or (
		not is_instance_valid(_organ) or _organ.is_queued_for_deletion()
	):
		return
	_render_snapshot(_organ.get_digestion_snapshot(), _organ.get_output_snapshot())


func _render_snapshot(snapshot: Dictionary, output: Dictionary) -> void:
	var chambers: Array = snapshot["chambers"]
	if chambers.size() != 2:
		return

	var primary: Dictionary = chambers[0]
	var secondary: Dictionary = chambers[1]
	var expansion_state: StringName = StringName(snapshot["expansion_state"])
	var is_expanding: bool = expansion_state == &"expanding"
	var has_two_chambers: bool = int(snapshot["chamber_count"]) == 2
	var primary_name: String = "一腔" if is_expanding or has_two_chambers else "单腔"
	_primary_status.text = "%s\n%s" % [primary_name, _state_text(primary)]
	_primary_status.modulate = _text_color(primary)
	_primary_progress.value = clampf(float(primary["progress"]), 0.0, 1.0)
	_primary_cap.color = _cap_color(primary)
	_primary_pores.default_color = _primary_cap.color.lightened(0.30)
	_render_chamber_art(_primary_sprite, primary)

	_second_chamber.visible = is_expanding or has_two_chambers
	_second_progress.value = clampf(float(secondary["progress"]), 0.0, 1.0)
	_second_progress.visible = has_two_chambers
	_second_cap.color = _cap_color(secondary)
	_second_pores.default_color = _second_cap.color.lightened(0.30)
	_render_chamber_art(_second_sprite, secondary)
	_second_status.modulate = _text_color(secondary)
	if is_expanding:
		var progress: float = clampf(float(snapshot["expansion_progress"]), 0.0, 1.0)
		var duration: float = float(snapshot["expansion_duration"])
		var elapsed: float = clampf(duration - float(snapshot["expansion_remaining"]), 0.0, duration)
		_second_body.scale = Vector2.ONE * lerpf(MIN_EXPANSION_SCALE, 1.0, progress)
		_second_body.modulate.a = lerpf(0.25, 1.0, progress)
		_second_status.text = "扩张二腔\n%.1f / %.1f 秒" % [elapsed, duration]
	else:
		_second_body.scale = Vector2.ONE
		_second_body.modulate.a = 1.0
		_second_status.text = "二腔\n%s" % _state_text(secondary)

	# 入库包含正在消化的尸体；输出包含在途产物，括号内仅展示各自预留。
	_queue_label.text = "入库 %d (+%d)/%d\n输出 %d (+%d)/%d" % [
		int(snapshot["intake_count"]), int(snapshot["incoming_count"]), int(snapshot["capacity"]),
		int(output["count"]), int(output["reserved_count"]), DigestiveOrgan.MAX_OUTPUT_PRODUCTS
	]
	var visual_center: float = _second_chamber.position.x * 0.5 if _second_chamber.visible else 0.0
	# 只追加双腔带来的居中位移，保留演示场景给文字安排的锚点与尺寸。
	_queue_label.position.x += visual_center - _queue_label_center_offset
	_queue_label_center_offset = visual_center
	var wait_reason: StringName = StringName(output["wait_reason"])
	_queue_label.modulate = BLOCKED_TEXT_COLOR if wait_reason in [
		&"output_full", &"output_too_large"
	] else NORMAL_TEXT_COLOR


func _render_chamber_art(sprite: Sprite2D, chamber: Dictionary) -> void:
	var state: StringName = StringName(chamber["state"])
	var image: Texture2D = IDLE_ART
	if state == &"processing":
		# 动画取真实消化计时进度：暂停后不会因为现实时间经过而自行跳帧。
		var elapsed: float = maxf(float(chamber["duration"]) - float(chamber["remaining"]), 0.0)
		image = WORK_ART_1 if int(elapsed / FRAME_DURATION) % 2 == 0 else WORK_ART_2
	if sprite.texture != image:
		WorldArt.fit_sprite(sprite, image, ART_BOUNDS)
	sprite.modulate = Color(0.78, 0.75, 0.77) if state in [
		&"dormant", &"stopped", &"locked", &"host_paused"
	] else Color.WHITE


func _state_text(chamber: Dictionary) -> String:
	var state: StringName = StringName(chamber["state"])
	match state:
		&"processing":
			return "消化 %.1f 秒" % maxf(float(chamber["remaining"]), 0.0)
		&"dormant":
			return "休眠·到货唤醒"
		&"output_full":
			return "输出已满"
		&"output_too_large":
			return "输入过大"
		&"stopped":
			return "已停止"
		&"host_paused":
			return "菌结停摆"
		&"locked":
			return "尚未解锁"
		&"expanding":
			return "扩张中"
		_:
			return "空闲"


func _cap_color(chamber: Dictionary) -> Color:
	var state: StringName = StringName(chamber["state"])
	match state:
		&"processing":
			return PROCESSING_CAP_COLOR
		&"dormant":
			return DORMANT_CAP_COLOR
		&"output_full":
			return BLOCKED_CAP_COLOR
		&"output_too_large":
			return TOO_LARGE_CAP_COLOR
		&"stopped":
			return STOPPED_CAP_COLOR
		_:
			return IDLE_CAP_COLOR


func _text_color(chamber: Dictionary) -> Color:
	var state: StringName = StringName(chamber["state"])
	match state:
		&"processing", &"expanding":
			return WORKING_TEXT_COLOR
		&"output_full", &"output_too_large":
			return BLOCKED_TEXT_COLOR
		&"stopped", &"locked", &"dormant":
			return STOPPED_TEXT_COLOR
		_:
			return NORMAL_TEXT_COLOR
