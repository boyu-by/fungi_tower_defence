class_name ColonyHUD
extends CanvasLayer
## 只显示模型数据，不参与扣款、运输或库存结算。

signal growth_mode_requested
signal growth_pause_requested
signal growth_cancel_requested
signal cultivation_requested
signal remote_cultivation_requested
signal connection_mode_requested
signal repair_mode_requested
signal repair_requested
signal repair_pause_requested
signal repair_cancel_requested

var _traffic_snapshot: Dictionary = {}
var _construction_queue_snapshot: Dictionary = {}
var _node_waiting_count: int = 0
var _edge_blocked_count: int = 0

@onready var selection_label: Label = $SelectionLabel
@onready var stock_label: Label = $StockLabel
@onready var transport_label: Label = $TransportLabel
@onready var traffic_label: Label = $TrafficLabel
@onready var notice_label: Label = $NoticeLabel
@onready var battle_label: Label = $BattleLabel
@onready var recovery_label: Label = $RecoveryLabel
@onready var colony_label: Label = $ColonyLabel
@onready var stage_label: Label = $StageLabel
@onready var growth_label: Label = $GrowthLabel
@onready var growth_supply_label: Label = $GrowthSupplyLabel
@onready var growth_mode_button: Button = $GrowthButtons/ModeButton
@onready var growth_pause_button: Button = $GrowthButtons/PauseButton
@onready var growth_cancel_button: Button = $GrowthButtons/CancelButton
@onready var cultivation_button: Button = $GrowthButtons/CultivationButton
@onready var remote_cultivation_button: Button = $GrowthButtons/RemoteCultivationButton
@onready var connection_mode_button: Button = $GrowthButtons/ConnectionButton
@onready var cultivation_reason_label: Label = $CultivationReasonLabel
@onready var repair_info_label: Label = $RepairPanel/Info
@onready var repair_mode_button: Button = $RepairPanel/Buttons/Mode
@onready var repair_request_button: Button = $RepairPanel/Buttons/Request
@onready var repair_pause_button: Button = $RepairPanel/Buttons/Pause
@onready var repair_cancel_button: Button = $RepairPanel/Buttons/Cancel

var _core_nutrition: int = 0
var _organ_nutrition: int = 0
var _incoming_nutrition: int = 0
var _organ_capacity: int = 0
var _battle_result: String = ""
var _recycling_in_transit: int = 0
var _recycling_delivered: int = 0
var _recycling_interrupted: int = 0
var _digestive_queued: int = 0
var _digestive_incoming: int = 0
var _digested_count: int = 0
var _recovered_nutrition: int = 0
var _recovered_products: int = 0
var _output_snapshot: Dictionary = {}
var _digestion_snapshot: Dictionary = {}
var _return_in_transit: int = 0
var _return_nutrition: int = 0
var _growth_snapshot: Dictionary = {}
var _growth_preview: Dictionary = {}
var _growth_placing: bool = false
var _growth_supply_snapshot: Dictionary = {}
var _cultivation_snapshot: Dictionary = {}
var _cultivation_selection: Dictionary = {}
var _cultivation_supply_snapshot: Dictionary = {}
var _remote_snapshot: Dictionary = {}
var _remote_preview: Dictionary = {}
var _remote_placing: bool = false
var _connection_placing: bool = false
var _connection_preview: Dictionary = {}
var _connection_visible: bool = false


func _ready() -> void:
	growth_mode_button.pressed.connect(func() -> void: growth_mode_requested.emit())
	growth_pause_button.pressed.connect(func() -> void: growth_pause_requested.emit())
	growth_cancel_button.pressed.connect(func() -> void: growth_cancel_requested.emit())
	cultivation_button.pressed.connect(func() -> void: cultivation_requested.emit())
	remote_cultivation_button.pressed.connect(func() -> void: remote_cultivation_requested.emit())
	connection_mode_button.pressed.connect(func() -> void: connection_mode_requested.emit())
	repair_mode_button.pressed.connect(func() -> void: repair_mode_requested.emit())
	repair_request_button.pressed.connect(func() -> void: repair_requested.emit())
	repair_pause_button.pressed.connect(func() -> void: repair_pause_requested.emit())
	repair_cancel_button.pressed.connect(func() -> void: repair_cancel_requested.emit())


func show_repair(preview: Dictionary, task: Dictionary, supply: Dictionary,
		budget: Dictionary, selecting: bool, vein_snapshot: Dictionary = {}) -> void:
	var state: StringName = task.get("state", &"idle")
	var active: bool = state in [&"waiting", &"repairing", &"paused"]
	var selected: Variant = preview.get("edge")
	var has_selection: bool = is_instance_valid(selected)
	var health_text: String = "修复：按 F 选择受损菌丝"
	var cost_text: String = "每营养最多恢复 10 生命 · 每秒最多 10"
	var short_cost: String = ""
	var point: Variant = preview.get("repair_point")
	if active:
		point = task.get("repair_point")
	if has_selection:
		health_text = "菌丝生命 %.1f / %.0f" % [
			float(preview.get("health", 0.0)), float(preview.get("max_health", 35.0))]
		cost_text = "预计 %d 营养 · 最后不足 10 生命也计 1" % int(preview.get("estimated_cost", 0))
		short_cost = " · 费用 %d" % int(preview.get("estimated_cost", 0))
	if active and has_selection and task.get("edge") == selected:
		cost_text = "本次预计共 %d 营养 · 尚需 %d（含缓存/在途）" % [
			int(task.get("estimated_total_cost", 0)), int(task.get("remaining_cost", 0))]
		short_cost = " · 共 %d / 尚需 %d" % [int(task.get("estimated_total_cost", 0)), int(task.get("remaining_cost", 0))]
	var point_name: String = "无可达端" if not is_instance_valid(point) else _traffic_node_name(point)
	var reason: StringName = supply.get("wait_reason", task.get("wait_reason", &"")) if active else preview.get("reason", &"")
	var reasons: Dictionary = {
		&"disconnected": "等待连通", &"work_point_disconnected": "作业端失联", &"nutrition": "等待营养",
		&"in_transit": "营养在途", &"insufficient_nutrition": "资金不足", &"core_empty": "资金不足",
		&"paused": "已暂停", &"core_unavailable": "母核不可用", &"invalid_configuration": "配置不可用",
		&"edge_required": "未选择", &"invalid_edge": "未选择", &"full": "无需修复", &"ready": "可开始修复", &"settlement_pending": "等待结算",
		&"undamaged": "无需修复", &"healthy": "无需修复", &"busy": "已有修复任务", &"": "",
	}
	var reason_text: String = String(reasons.get(reason, "等待作业条件"))
	var states: Dictionary = {&"idle": "未开始", &"waiting": "等待修复", &"repairing": "修复中",
		&"paused": "暂停中", &"completed": "已修复", &"cancelled": "已取消"}
	var task_name: String = String(states.get(state, "未开始"))
	if active and has_selection and task.get("edge") != selected:
		task_name = "另一段" + task_name
	var headline: String = health_text + short_cost
	var vein_detail: String = ""
	if has_selection and not vein_snapshot.is_empty():
		headline = "菌脉%d · 通过%d · 容量%d · 生命%.1f/%.0f" % [
			int(vein_snapshot.get("level", 1)), int(vein_snapshot.get("confirmed_passages", 0)),
			int(vein_snapshot.get("traffic_capacity", 2)), float(vein_snapshot.get("health", 0.0)),
			float(vein_snapshot.get("max_health", 35.0))]
		vein_detail = "\n%s；有效通过量只统计已接收或已使用的独立货物。" % String(vein_snapshot.get("grade_name", "细菌丝"))
		if int(vein_snapshot.get("next_threshold", 0)) > 0:
			vein_detail += " 下一门槛 %d。" % int(vein_snapshot["next_threshold"])
	repair_info_label.text = "%s\n作业端：%s  %s\n%s · 已用 %d · 缓存 %d · 在途 %d\n预留 %d / 需求 %d · 其他可花 %d" % [
		headline, point_name, reason_text, task_name,
		int(task.get("consumed_nutrition", 0)), int(task.get("buffered_nutrition", 0)),
		int(supply.get("in_transit_nutrition", 0)), int(supply.get("reserved_nutrition", 0)),
		int(supply.get("reservation_goal", 0)), int(budget.get("spendable", 0)),
	]
	repair_info_label.tooltip_text = repair_info_label.text + vein_detail + "\n" + cost_text + "\n预留仍在余额中；只有实际派送才扣款，未送达不能恢复生命。"
	repair_mode_button.text = "退出选择" if selecting else "F 选择"
	repair_request_button.disabled = active or not bool(preview.get("valid", false))
	repair_pause_button.disabled = not active
	repair_pause_button.text = "K 继续" if state == &"paused" else "K 暂停"
	repair_cancel_button.disabled = not active


func show_connection_mode(placing: bool) -> void:
	_connection_placing = placing
	_connection_preview = {}
	_update_growth_label()


func show_connection_preview(preview: Dictionary) -> void:
	_connection_preview = preview
	if _connection_placing:
		_update_growth_label()


func show_connection_status(snapshot: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if snapshot.get("task_kind", &"") == &"connection" and task_id > 0 \
			and task_id >= int(_growth_snapshot.get("task_id", 0)):
		show_growth_status(snapshot)


func show_remote_mode(placing: bool) -> void:
	_remote_placing = placing
	_remote_preview = {}
	_update_growth_label()


func show_remote_preview(preview: Dictionary) -> void:
	_remote_preview = preview
	if _remote_placing:
		_update_growth_label()


func show_remote_status(snapshot: Dictionary) -> void:
	_remote_snapshot = snapshot
	if _remote_is_active():
		_connection_visible = false
	if int(snapshot.get("cultivation_task_id", 0)) > 0:
		_cultivation_snapshot = snapshot.get("cultivation_snapshot", {})
	_update_growth_label()


func show_construction_status(snapshot: Dictionary) -> void:
	if int(snapshot.get("request_id", 0)) > 0:
		show_remote_status(snapshot)
	else:
		show_cultivation_status(snapshot)


func show_growth_mode(placing: bool) -> void:
	_growth_placing = placing
	_growth_preview = {}
	_update_growth_label()


func show_growth_preview(preview: Dictionary) -> void:
	_growth_preview = preview
	if _growth_placing:
		_update_growth_label()


func show_growth_status(snapshot: Dictionary) -> void:
	_growth_snapshot = snapshot
	if snapshot.get("state", &"idle") in [&"waiting", &"extending", &"paused"]:
		_connection_visible = snapshot.get("task_kind", &"growth") == &"connection"
	if not _remote_is_active() and snapshot.get("state", &"idle") in [&"waiting", &"extending", &"paused"]:
		_remote_snapshot = {}
	_update_growth_label()


func show_growth_supply(snapshot: Dictionary) -> void:
	_growth_supply_snapshot = snapshot
	_update_construction_supply()


func show_cultivation_selection(snapshot: Dictionary) -> void:
	_cultivation_selection = snapshot
	cultivation_button.disabled = not (bool(snapshot.get("can_cultivate", false))
		or bool(snapshot.get("can_continue", false)))
	cultivation_button.text = "C 继续培育" if bool(snapshot.get("can_continue", false)) else "C 培育"
	var message: String = String(snapshot.get("message", "选择空菌结培育：12 营养 = 8 结构 + 4 库存"))
	if bool(snapshot.get("can_continue", false)) and snapshot.get("reason") != &"insufficient_nutrition":
		message += " · 尚需 %d 营养" % int(snapshot.get("remaining_cost", 12))
	cultivation_button.tooltip_text = message + "\n总费 12 营养：结构 8 + 启动库存 4；有效培育至少 3 秒"
	cultivation_reason_label.text = message
	cultivation_reason_label.tooltip_text = message
	_update_growth_label()


func show_cultivation_status(snapshot: Dictionary) -> void:
	_cultivation_snapshot = snapshot
	if _cultivation_is_active():
		_connection_visible = false
	if not _remote_is_active() and snapshot.get("state", &"idle") in [&"waiting", &"cultivating", &"paused"]:
		_remote_snapshot = {}
	_update_growth_label()


func show_cultivation_supply(snapshot: Dictionary) -> void:
	_cultivation_supply_snapshot = snapshot
	_update_construction_supply()


func _cultivation_is_active() -> bool:
	return _cultivation_snapshot.get("state", &"idle") in [&"waiting", &"cultivating", &"paused"]


func _remote_is_active() -> bool:
	return int(_remote_snapshot.get("request_id", 0)) > 0 and _remote_snapshot.get("state", &"idle") \
		in [&"waiting", &"extending", &"connected", &"cultivating", &"paused"]


func _cultivation_display_snapshot() -> Dictionary:
	if _cultivation_is_active():
		return _cultivation_snapshot
	var selected_task: Dictionary = _cultivation_selection.get("task", {})
	var host: Variant = _cultivation_selection.get("host")
	if is_instance_valid(host) and selected_task.get("host") == host and int(selected_task.get("task_id", 0)) > 0:
		return selected_task
	return {}


func _update_construction_supply() -> void:
	if bool(_construction_queue_snapshot.get("multi_worker_enabled", false)):
		var resources: Dictionary = _construction_queue_snapshot.get("resources", {})
		growth_supply_label.text = "建设在途 %d · 战斗储备 %d · 建设可用 %d" % [
			int(resources.get("growth_transit", 0)) + int(resources.get("cultivation_transit", 0)),
			int(_construction_queue_snapshot.get("combat_reserve", 0)),
			int(_construction_queue_snapshot.get("available", 0))]
		return
	var growth_active: bool = _growth_snapshot.get("state", &"idle") in [&"waiting", &"extending", &"paused"]
	var cultivation_visible: bool = not growth_active and not _growth_placing and not _connection_placing \
		and not _connection_visible and not _cultivation_display_snapshot().is_empty()
	if _remote_is_active():
		cultivation_visible = _remote_snapshot.get("phase", &"") == &"cultivation"
	var snapshot: Dictionary = _cultivation_supply_snapshot if cultivation_visible else _growth_supply_snapshot
	growth_supply_label.text = "%s在途 %d · 战斗储备 %d · 可用营养 %d" % [
		"培育" if cultivation_visible else ("连接" if _connection_visible or _connection_placing else "生长"), int(snapshot.get("in_transit", 0)),
		int(snapshot.get("combat_reserve", 0)), int(snapshot.get("available", 0)),
	]


func _update_growth_label() -> void:
	var state: StringName = _growth_snapshot.get("state", &"idle")
	var active: bool = state == &"waiting" or state == &"extending" or state == &"paused"
	var cultivation_active: bool = _cultivation_is_active()
	var cultivation: Dictionary = _cultivation_display_snapshot()
	var current_state: StringName = _cultivation_snapshot.get("state", &"idle") if cultivation_active else state
	var subject: String = "培育" if cultivation_active else "生长"
	if _connection_visible and not cultivation_active:
		subject = "连接"
	var remote_active: bool = _remote_is_active()
	if remote_active:
		current_state = _remote_snapshot.get("state", &"idle")
		subject = "建设"
	growth_mode_button.disabled = active or cultivation_active or remote_active
	growth_mode_button.text = "G 退出" if _growth_placing else "G 伸展"
	remote_cultivation_button.disabled = active or cultivation_active or remote_active
	remote_cultivation_button.text = "B 退出" if _remote_placing else "B 种攻击芽"
	connection_mode_button.disabled = active or cultivation_active or remote_active
	connection_mode_button.text = "L 退出" if _connection_placing else "L 连接菌结"
	growth_pause_button.disabled = not active and not cultivation_active and not remote_active
	growth_pause_button.text = "P 恢复" if current_state == &"paused" else "P 暂停"
	growth_pause_button.tooltip_text = "暂停或恢复当前" + subject + "；已付款的在途营养仍可送达"
	growth_cancel_button.disabled = not active and not cultivation_active and not remote_active
	growth_cancel_button.text = "X 取消"
	growth_cancel_button.tooltip_text = "取消当前" + subject + "；退还未消费营养，保留已投入结构"
	if not _construction_queue_snapshot.is_empty():
		# G/B/L 始终可以预览下一目标，第四个由同一入队接口明确拒绝。
		growth_mode_button.disabled = false
		remote_cultivation_button.disabled = false
		connection_mode_button.disabled = false
		var selected: Dictionary = {}
		for request: Dictionary in _construction_queue_snapshot.get("entries", []) \
				+ _construction_queue_snapshot.get("maturing", []):
			if request.get("construction_id") == _construction_queue_snapshot.get("selected_id"):
				selected = request
		var host: Variant = _cultivation_selection.get("host")
		var local_selected: bool = is_instance_valid(host) \
			and bool(_construction_queue_snapshot.get("local_control_selected", false)) \
			and String(_construction_queue_snapshot.get("active_id", "")).is_empty() \
			and ((cultivation_active and cultivation.get("host") == host) \
				or (remote_active and _remote_snapshot.get("endpoint") == host))
		growth_pause_button.disabled = selected.is_empty() and not local_selected
		growth_cancel_button.disabled = growth_pause_button.disabled
		if not selected.is_empty():
			growth_pause_button.text = "P 继续" if selected.get("state") == &"paused" else "P 暂停"
			growth_pause_button.tooltip_text = "只操作选中的队列目标 #%d" % int(selected.get("sequence", 0))
			growth_cancel_button.tooltip_text = growth_pause_button.tooltip_text
		elif not local_selected:
			growth_pause_button.tooltip_text = "先选择队列目标或正在就地培育的菌结"
			growth_cancel_button.tooltip_text = growth_pause_button.tooltip_text
	if bool(_construction_queue_snapshot.get("multi_worker_enabled", false)) \
			and not _connection_placing and not _growth_placing and not _remote_placing:
		_show_multi_construction_status()
		_update_construction_supply()
		return
	if _connection_placing:
		_show_connection_preview_text()
	elif _connection_visible and not _growth_placing and not _remote_placing and not cultivation_active and not remote_active:
		_show_connection_status_text()
	elif _remote_placing:
		_show_remote_preview_text()
	elif int(_remote_snapshot.get("request_id", 0)) > 0 and not _growth_placing \
			and (remote_active or (not active and not cultivation_active)):
		_show_remote_status_text()
	elif not cultivation.is_empty() and not active and not _growth_placing:
		var descriptions: Dictionary = {
			&"waiting": "等待培育", &"cultivating": "培育中", &"paused": "培育已暂停",
			&"cancelled": "幼芽已保留，可继续", &"completed": "攻击器官已成熟",
		}
		var cultivation_state: StringName = cultivation.get("state", &"idle")
		var cultivation_title: String = descriptions.get(cultivation_state, "等待培育")
		if cultivation_state == &"waiting":
			var waiting_text: Dictionary = {
				&"nutrition": "等待培育营养", &"in_transit": "等待营养送达",
				&"core_empty": "营养不足，等待供养", &"combat_reserve": "等待战斗储备释放", &"repair_budget": "营养优先用于修复",
				&"disconnected": "宿主失联，保留进度", &"core_unavailable": "母核无法供养",
				&"invalid_configuration": "培育配置不可用", &"occupied": "宿主槽位已占用",
			}
			cultivation_title = waiting_text.get(cultivation.get("wait_reason", &""), cultivation_title)
		var startup: String = "已转库存 %d" % int(cultivation.get("startup_transferred", 0)) if cultivation_state == &"completed" else (
			"启动 %d/4" % int(cultivation.get("startup_reserved", 0)))
		var cost: String = "尚需 %d" % int(cultivation.get("remaining_cost", 12)) if cultivation_state == &"cancelled" else "总费 12"
		growth_label.text = "%s · %d%% · 有效 %.1f/3.0 秒\n%s · 结构 %d/8 · %s · 缓存 %d" % [
			cultivation_title,
			int(round(float(cultivation.get("progress", 0.0)) * 100.0)),
			float(cultivation.get("effective_time", 0.0)), cost, int(cultivation.get("structure_consumed", 0)),
			startup, int(cultivation.get("buffered_nutrition", 0)),
		]
	elif _growth_placing:
		if bool(_growth_preview.get("valid", false)):
			var plan: Dictionary = _growth_preview.get("plan", {})
			growth_label.text = "放置目标 · 距离 %.0f · 左键确认\n预计营养 %d · 新菌结 %d · 右键/Esc 退出" % [
				float(plan.get("distance", 0.0)), int(plan.get("total_cost", 0)),
				plan.get("junction_positions", PackedVector2Array()).size(),
			]
		else:
			growth_label.text = "放置目标 · 在地图内移动鼠标\n" + String(_growth_preview.get("error", "左键确认 · 右键/Esc 退出"))
	elif state == &"idle":
		growth_label.text = "按 G 指定伸展目标\n营养沿菌丝送达尖端后，才会开始生长"
	else:
		var reason: StringName = _growth_snapshot.get("wait_reason", &"")
		var state_text: String = GrowthTarget.STATE_TEXT.get(state, String(state))
		if reason != &"" and reason != &"paused":
			state_text += "：" + String(GrowthTarget.WAIT_TEXT.get(reason, String(reason)))
		growth_label.text = "%s · %d%% · 菌结 %d\n营养投入 %d/%d · 尖端缓存 %d" % [
			state_text, int(round(float(_growth_snapshot.get("progress", 0.0)) * 100.0)),
			int(_growth_snapshot.get("formed_junctions", 0)), int(_growth_snapshot.get("consumed_nutrition", 0)),
			int(_growth_snapshot.get("total_cost", 0)), int(_growth_snapshot.get("buffered_nutrition", 0)),
		]
	_update_construction_supply()


func _connection_node_name(node: Variant) -> String:
	return node.display_name if is_instance_valid(node) and node is HyphaNode else "菌结"


func _show_connection_preview_text() -> void:
	if not bool(_connection_preview.get("valid", false)):
		var selected: Variant = _connection_preview.get("first_node")
		var title: String = "已选 %s · 请选第二个菌结" % _connection_node_name(selected) \
			if is_instance_valid(selected) else "连接菌结 · 请先选择第一个菌结"
		growth_label.text = title + "\n" + String(_connection_preview.get("error", "依次左键选择两个菌结")) \
			+ "\n右键 / Esc 退出 · 预览不扣款"
	else:
		var plan: Dictionary = _connection_preview.get("plan", {})
		growth_label.text = "%s → %s%s\n菌丝 %d + 中继 %d = %d · 新菌结 %d · 两端免菌结费\n左键确认连接 · 右键 / Esc 退出" % [
			_connection_node_name(_connection_preview.get("start_node")),
			_connection_node_name(_connection_preview.get("target_node")),
			"（反向供养）" if bool(_connection_preview.get("reversed", false)) else "",
			int(plan.get("extension_cost", 0)), int(plan.get("junction_cost", 0)), int(plan.get("total_cost", 0)),
			plan.get("junction_positions", PackedVector2Array()).size(),
		]


func _show_multi_construction_status() -> void:
	var selected: Dictionary = {}
	for request: Dictionary in _construction_queue_snapshot.get("entries", []) \
			+ _construction_queue_snapshot.get("maturing", []):
		if request.get("construction_id") == _construction_queue_snapshot.get("selected_id"):
			selected = request
	if selected.is_empty():
		growth_label.text = "尖端 %d/%d · 等待目标 %d · 独立成熟 %d\n选择队列编号或成熟列表，单独暂停、继续或取消" % [
			int(_construction_queue_snapshot.get("tip_count", 0)), int(_construction_queue_snapshot.get("tip_limit", 1)),
			int(_construction_queue_snapshot.get("waiting_count", 0)), int(_construction_queue_snapshot.get("maturing_count", 0))]
		return
	var kinds: Dictionary = {&"growth": "伸展", &"remote_cultivation": "远处种芽",
		&"connection": "连接", &"cultivation": "就地培育"}
	var detail: Dictionary = selected.get("detail", {})
	var phase: String = "独立成熟" if selected.get("phase") == &"maturing" else "延伸中"
	if not bool(selected.get("started", false)):
		phase = "等待开始" if selected.get("phase") == &"maturing" else "等待尖端"
	if selected.get("state") == &"paused":
		phase = "已暂停 · " + phase
	var reason: StringName = selected.get("wait_reason", &"")
	var reasons: Dictionary = {&"queued": "排队中", &"pipeline_busy": "等待执行位置", &"tip_limit": "等待空闲尖端",
		&"nutrition": "等待营养", &"in_transit": "营养在途", &"core_empty": "营养不足", &"combat_reserve": "保留战斗营养",
		&"repair_budget": "营养优先用于修复", &"disconnected": "等待菌路恢复", &"paused": "保持进度与原有在途", &"": "正常推进"}
	var consumed: int = int(detail.get("consumed_nutrition", int(detail.get("structure_consumed", 0))
		+ int(detail.get("startup_transferred", 0))))
	growth_label.text = "#%d %s · %s · %d%%\n%s\n已投入 %d · 缓存 %d · 启动库存 %d/4" % [
		int(selected.get("sequence", 0)), kinds.get(selected.get("kind"), "建设"), phase,
		int(round(float(detail.get("progress", 0.0)) * 100.0)), reasons.get(reason, String(reason)), consumed,
		int(detail.get("buffered_nutrition", 0)),
		int(detail.get("startup_reserved", 0)) + int(detail.get("startup_transferred", 0))]


func _show_connection_status_text() -> void:
	var state: StringName = _growth_snapshot.get("state", &"idle")
	var titles: Dictionary = {
		&"waiting": "等待供养", &"extending": "生长中", &"paused": "已暂停",
		&"completed": "连接完成", &"cancelled": "已取消，保留已付网络",
	}
	var title: String = String(titles.get(state, "等待连接"))
	var reason: StringName = _growth_snapshot.get("wait_reason", &"")
	if reason != &"" and reason != &"paused":
		title += " · " + String(GrowthTarget.WAIT_TEXT.get(reason, String(reason)))
	var heading: String = "连接施工" if not _construction_queue_snapshot.is_empty() else \
		"连接 #%d" % int(_growth_snapshot.get("task_id", 0))
	growth_label.text = "%s · %s · %d%%\n%s → %s · 中继 %d\n投入 %d/%d · 缓存 %d · 两端免菌结费" % [
		heading, title,
		int(round(float(_growth_snapshot.get("progress", 0.0)) * 100.0)),
		_connection_node_name(_growth_snapshot.get("start_node")),
		_connection_node_name(_growth_snapshot.get("target_node")),
		int(_growth_snapshot.get("formed_junctions", 0)), int(_growth_snapshot.get("consumed_nutrition", 0)),
		int(_growth_snapshot.get("total_cost", 0)), int(_growth_snapshot.get("buffered_nutrition", 0)),
	]


func _show_remote_preview_text() -> void:
	if not bool(_remote_preview.get("valid", false)):
		growth_label.text = "种攻击芽 · 左键确认 · 右键 / Esc 退出\n" \
			+ String(_remote_preview.get("error", "请在地图内指定落点"))
	else:
		var plan: Dictionary = _remote_preview.get("plan", {})
		growth_label.text = "种攻击芽 · 距离 %.0f · 新菌结 %d\n网络 %d + 器官 %d（结构 8 + 库存 4）= %d\n左键确认 · 右键 / Esc 退出 · 预览不扣款" % [
			float(plan.get("distance", 0.0)), plan.get("junction_positions", PackedVector2Array()).size(),
			int(_remote_preview.get("network_cost", 0)), int(_remote_preview.get("organ_cost", 12)),
			int(_remote_preview.get("total_cost", 0)),
		]


func _show_remote_status_text() -> void:
	var state: StringName = _remote_snapshot.get("state", &"idle")
	var phase: StringName = _remote_snapshot.get("phase", &"")
	var descriptions: Dictionary = {
		&"waiting": "等待供养", &"extending": "延伸网络", &"connected": "已接通，交接培育",
		&"cultivating": "培育攻击芽", &"paused": "已暂停", &"completed": "攻击器官已成熟",
		&"cancelled": "已取消，保留已付结构",
	}
	var title: String = String(descriptions.get(state, "等待建设"))
	if state == &"paused":
		title += "（培育）" if phase == &"cultivation" else "（延伸 / 接通）"
	var reason: StringName = _remote_snapshot.get("wait_reason", &"")
	if reason != &"" and reason != &"paused":
		title += " · " + String(GrowthTarget.WAIT_TEXT.get(reason, String(reason)))
	var startup: int = int(_remote_snapshot.get("startup_transferred", 0)) if state == &"completed" \
		else int(_remote_snapshot.get("startup_reserved", 0))
	# 正式队列只在列表和地图展示外部编号，避免把内部远处请求号误认作目标编号。
	var heading: String = "远处培育" if not _construction_queue_snapshot.is_empty() else \
		"建设 #%d" % int(_remote_snapshot.get("request_id", 0))
	growth_label.text = "%s · %s\n网络 %d + 器官 %d = %d · 已投入 %d · 剩余需求 %d\n器官结构 %d/8 · 启动库存 %d/4 · 缓存 %d" % [
		heading, title,
		int(_remote_snapshot.get("network_cost", 0)), int(_remote_snapshot.get("organ_cost", 12)),
		int(_remote_snapshot.get("total_cost", 0)), int(_remote_snapshot.get("consumed_nutrition", 0)),
		int(_remote_snapshot.get("remaining_demand", 0)), int(_remote_snapshot.get("structure_consumed", 0)),
		startup, int(_remote_snapshot.get("buffered_nutrition", 0)),
	]


func show_selection(display_name: String) -> void:
	selection_label.text = "未选择菌结" if display_name.is_empty() else "已选择：%s" % display_name


func show_core_nutrition(current: int) -> void:
	_core_nutrition = current
	_update_stock_label()


func show_organ_inventory(stored: int, incoming: int, capacity: int) -> void:
	_organ_nutrition = stored
	_incoming_nutrition = incoming
	_organ_capacity = capacity
	_update_stock_label()


func show_colony_inventory(stored: int, incoming: int, capacity: int, count: int) -> void:
	colony_label.text = "攻击器官：%d · 总库存：%d/%d · 在途供养：%d" % [
		count, stored, capacity, incoming
	]


func show_transport(in_transit: int, delivered: int, interrupted: int) -> void:
	transport_label.text = "营养包：在途 %d · 已到达 %d · 中止 %d" % [
		in_transit, delivered, interrupted
	]


func show_notice(message: String) -> void:
	notice_label.text = message
	notice_label.tooltip_text = message


func show_battle(spawned: int, defeated: int, active: int, total: int) -> void:
	if not _battle_result.is_empty():
		return
	battle_label.text = "本轮敌人：%d/%d · 场上：%d\n已击败：%d" % [
		spawned, total, active, defeated
	]


func show_battle_result(won: bool) -> void:
	_battle_result = "本轮防守成功" if won else "母核已被摧毁"
	battle_label.text = _battle_result + "\n按 R 重新开始"
	battle_label.modulate = Color("c2dc9a") if won else Color("e6a099")


func show_recycling(in_transit: int, delivered: int, interrupted: int) -> void:
	_recycling_in_transit = in_transit
	_recycling_delivered = delivered
	_recycling_interrupted = interrupted
	_update_recovery_label()


func show_digestion(queued: int, incoming: int) -> void:
	_digestive_queued = queued
	_digestive_incoming = incoming
	_update_recovery_label()


func show_production(digested_count: int) -> void:
	_digested_count = digested_count
	_update_recovery_label()


func show_recovered_progress(total_recovered: int, product_count: int) -> void:
	_recovered_nutrition = total_recovered
	_recovered_products = product_count
	_update_recovery_label()


func show_construction_queue(snapshot: Dictionary) -> void:
	_construction_queue_snapshot = snapshot.duplicate(true)
	_update_growth_label()


## 阶段和门槛来自 ColonyProgress；界面不判断门槛，也不改变余额或能力。
func show_growth_stage(stage_name: String, total_recovered: int, next_threshold: int) -> void:
	var next_text: String = "已达最终阶段"
	if next_threshold > 0:
		next_text = "下一门槛 %d（还差 %d）" % [
			next_threshold, maxi(next_threshold - total_recovered, 0)]
	stage_label.text = "成长：%s · 累计回收 %d · %s" % [
		stage_name, total_recovered, next_text]
	stage_label.tooltip_text = stage_label.text + "\n只累计真实抵达母核的回流；消费和组织损失不会降低阶段。"


func show_digestive_output(snapshot: Dictionary) -> void:
	_output_snapshot = snapshot
	_update_recovery_label()


func show_digestive_chambers(snapshot: Dictionary) -> void:
	_digestion_snapshot = snapshot.duplicate(true)
	_update_recovery_label()


func show_nutrition_return(snapshot: Dictionary) -> void:
	_return_in_transit = int(snapshot.get("in_transit_count", 0))
	_return_nutrition = int(snapshot.get("in_transit_nutrition", 0))
	_update_recovery_label()


func _update_recovery_label() -> void:
	var waiting: String = ""
	if _output_snapshot.get("wait_reason", &"") == &"output_full":
		waiting = " · 输出已满"
	elif _output_snapshot.get("wait_reason", &"") == &"output_too_large":
		waiting = " · 产物超限"
	var stomach_text: String = "胃囊：待处理 %d（含消化中）· 待送达 %d" % [
		_digestive_queued, _digestive_incoming]
	if not _digestion_snapshot.is_empty():
		stomach_text = "胃囊：处理 %d/%d · 等待 %d · 待送达 %d" % [
			int(_digestion_snapshot.get("active_count", 0)), int(_digestion_snapshot.get("chamber_count", 1)),
			int(_digestion_snapshot.get("waiting_count", 0)), _digestive_incoming]
		if not bool(_digestion_snapshot.get("enabled", true)):
			stomach_text += " · 已停止"
		elif _digestion_snapshot.get("expansion_state", &"locked") == &"expanding":
			stomach_text += " · 二腔展开 %.1fs" % float(_digestion_snapshot.get("expansion_remaining", 0.0))
	recovery_label.text = (
		"尸体：在途 %d · 已送达 %d · 中断 %d\n" +
		"%s\n" +
		"输出：%d (+%d预留)/2 · 营养 %d (+%d)/20%s\n" +
		"绿色回流：在途 %d 包 / %d 营养\n累计回收：+%d · 已到达 %d 份 · 已消化 %d"
	) % [
		_recycling_in_transit, _recycling_delivered, _recycling_interrupted,
		stomach_text,
		int(_output_snapshot.get("count", 0)), int(_output_snapshot.get("reserved_count", 0)),
		int(_output_snapshot.get("nutrition", 0)), int(_output_snapshot.get("reserved_nutrition", 0)), waiting,
		_return_in_transit, _return_nutrition, _recovered_nutrition, _recovered_products, _digested_count,
	]


func _update_stock_label() -> void:
	stock_label.text = "母核营养：%d · 器官库存：%d/%d · 在途供养：%d" % [
		_core_nutrition, _organ_nutrition, _organ_capacity, _incoming_nutrition
	]


## 通行单位单独显示；不把队列或凭证加到营养库存里。
func show_transport_states(node_waiting: int, edge_blocked: int) -> void:
	if node_waiting == _node_waiting_count and edge_blocked == _edge_blocked_count:
		return
	_node_waiting_count = node_waiting
	_edge_blocked_count = edge_blocked
	show_traffic(_traffic_snapshot)


func show_traffic(snapshot: Dictionary) -> void:
	_traffic_snapshot = snapshot
	var capacity: int = 0
	var busiest: Dictionary = {}
	var busiest_score: int = -1
	var waiting_by_kind: Dictionary = {&"supply": 0, &"return": 0, &"remains": 0}
	for row: Dictionary in snapshot.get("edges", []):
		if not bool(row.get("exists", false)):
			continue
		capacity += int(row.get("capacity", 0))
		var queue: Array = row.get("queue", [])
		for request: Dictionary in queue:
			var kind: StringName = request.get("cargo_kind", &"")
			if waiting_by_kind.has(kind):
				waiting_by_kind[kind] = int(waiting_by_kind[kind]) + 1
		var score: int = queue.size() * 1000 + int(row.get("occupied_units", 0))
		if score > busiest_score:
			busiest_score = score
			busiest = row
	var detail: String = "菌丝空闲 · 每条默认容量 2（双向共用）"
	if not busiest.is_empty() and busiest_score > 0:
		var strand: HyphaEdge = busiest.get("edge") as HyphaEdge
		if is_instance_valid(strand):
			detail = "%s ↔ %s：%d/%d · 排队 %d" % [
				_traffic_node_name(strand.start_node), _traffic_node_name(strand.end_node),
				int(busiest.get("occupied_units", 0)), int(busiest.get("capacity", 0)),
				busiest.get("queue", []).size(),
			]
	traffic_label.text = "通行占用 %d/%d · 容量排队 %d 包\n%s\n排队：黄 %d · 绿 %d · 紫 %d（紫包占 2）\n菌结等候 %d · 段内停留 %d" % [
		int(snapshot.get("occupied_units", 0)), capacity, int(snapshot.get("queued_count", 0)), detail,
		int(waiting_by_kind[&"supply"]), int(waiting_by_kind[&"return"]), int(waiting_by_kind[&"remains"]),
		_node_waiting_count, _edge_blocked_count,
	]
	traffic_label.tooltip_text = traffic_label.text + "\n排队保留付款和预留；真正抵达后才结算"


func _traffic_node_name(node: Variant) -> String:
	if not is_instance_valid(node):
		return "节点"
	if node is MotherCore:
		return "母核"
	if node is HyphaNode:
		return node.display_name
	if node is GrowthTip:
		return "生长尖端"
	return "节点"
