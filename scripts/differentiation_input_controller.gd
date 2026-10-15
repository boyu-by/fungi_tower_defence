class_name DifferentiationInputController
extends PanelContainer
## 只转交所选器官的分化操作，显示后端快照；不收件、不扣费、不保存分化进度。

signal notice(message: String)
signal status_changed(snapshot: Dictionary)

const PIERCING: int = WeaponProfile.DamageType.ARMOR_PIERCING
const SCATTER: int = WeaponProfile.DamageType.SCATTER
const RULES_SUMMARY: String = "成熟（累计回收≥160）后，普通攻击器官可分化。\n分化需8材料营养、至少5秒有效时间。\n分化与暂停均停火；取消保留方向和已付进度。\n点击「规则」查看供养、取消与继续规则。"
const RULES_FULL: String = "累计回收达到160进入成熟期。只有已长成的普通攻击器官可分化；也可继续保留普通。\n选择破甲或散射，开始后方向锁定。全群落同时只能有一个分化任务，暂停也占用这个名额。\n每次分化共需8材料营养；每份到达的材料支持0.625秒，累计至少5秒有效时间才完成。缺材料时不推进，断网时保留进度。\n分化和暂停期间都停止射击与新弹药供养；开始前已付费的在途弹药仍可送达。\n取消会退回尚未使用的缓存和在途材料；已经付费的进度与方向保留。原普通攻击恢复，并重新等待完整射击冷却。\n继续只能沿原方向补足剩余材料与时间，并再次停火。完成后不能再次分化或退回普通。\n始终使用原器官、原武器与原弹药库存；分化不会赠送弹药。"
const TYPE_INFO: String = "普通：单体，每轮1营养；破甲：无视护甲，每轮2。\n散射：至多3目标，整轮1营养。"
const REASON_TEXT: Dictionary = {
	&"ready": "可选择破甲或散射，也可保留普通攻击。",
	&"continuable": "方向已锁定；可继续原分化，保留已付进度。",
	&"active": "分化中，射击与新弹药供养已停止。",
	&"paused": "已暂停；仍停火，可继续或取消。",
	&"completed": "分化已完成；不能再次分化或退回普通。",
	&"no_selection": "请选择承载攻击器官的成熟菌结。",
	&"not_mature_organ": "只有已长成的普通攻击器官可分化。",
	&"not_normal": "当前器官已非普通攻击，不能再次分化。",
	&"direction_locked": "方向已锁定；只能继续原分化方向。",
	&"invalid_direction": "请选择破甲或散射方向。",
	&"stage_locked": "累计回收达到160、进入成熟期后解锁分化。",
	&"busy": "已有另一器官正在分化，请选择该器官操作。",
	&"settlement_pending": "材料退款仍在结算，结算后可继续。",
	&"disconnected": "所选菌结未与存活母核连通；分化进度保留。",
	&"core_unavailable": "母核不可用，等待恢复后再分化。",
	&"invalid_configuration": "分化系统或供养尚未就绪。",
	&"organ_unavailable": "所选器官已不可用，请重新选择。",
	&"stopped": "当前战局已停止分化。",
	&"nutrition": "等待材料；没有材料不推进。",
	&"no_material": "等待材料；没有材料不推进。",
	&"insufficient_nutrition": "可用材料不足，等待母核供养。",
	&"core_empty": "可用材料不足，等待母核供养。",
	&"in_transit": "材料正在送达；未到达前不推进。",
	&"combat_reserve": "先为其他攻击器官保留弹药，等待更多营养。",
	&"repair_budget": "母核营养正在预留给修复，等待可用材料。",
	&"differentiation_budget": "等待母核分配分化材料。",
	&"traffic_busy": "运输通道繁忙，等待材料送达。",
	&"": "",
}

@export var differentiation_system: DifferentiationSystem
@export var differentiation_supply_system: DifferentiationSupplySystem

var _selected_node: HyphaNode
var panel_presentation_enabled: bool = true
var _observed_organ: AttackOrgan
var _interaction_suspended: bool = false
var _rules_expanded: bool = false
var _last_status: Dictionary = {}
var _dependency_sources: Array[Node] = []
var _dependency_bindings: Array[Dictionary] = []
var _selection_bindings: Array[Dictionary] = []
var _organ_bindings: Array[Dictionary] = []
var _refreshing: bool = false
var _refresh_pending: bool = false

@onready var piercing_button: Button = get_node_or_null("%PiercingButton") as Button
@onready var scatter_button: Button = get_node_or_null("%ScatterButton") as Button
@onready var pause_button: Button = get_node_or_null("%PauseButton") as Button
@onready var continue_button: Button = get_node_or_null("%ContinueButton") as Button
@onready var cancel_button: Button = get_node_or_null("%CancelButton") as Button
@onready var status_label: Label = get_node_or_null("%StatusLabel") as Label
@onready var progress_bar: ProgressBar = get_node_or_null("%ProgressBar") as ProgressBar
@onready var rules_label: Label = get_node_or_null("%RulesLabel") as Label
@onready var type_info_label: Label = get_node_or_null("%TypeInfoLabel") as Label
@onready var rules_button: Button = get_node_or_null("%RulesButton") as Button


func _ready() -> void:
	set_process(false)
	_connect_button(piercing_button, _on_piercing_pressed)
	_connect_button(scatter_button, _on_scatter_pressed)
	_connect_button(pause_button, _on_pause_pressed)
	_connect_button(continue_button, _on_continue_pressed)
	_connect_button(cancel_button, _on_cancel_pressed)
	_connect_button(rules_button, _on_rules_pressed)
	if rules_label != null:
		rules_label.text = RULES_SUMMARY
		rules_label.tooltip_text = RULES_FULL
	if type_info_label != null:
		type_info_label.text = TYPE_INFO
	refresh()
	refresh.call_deferred()


func _exit_tree() -> void:
	_disconnect_bindings(_dependency_bindings)
	_disconnect_bindings(_selection_bindings)
	_disconnect_bindings(_organ_bindings)
	_dependency_sources.clear()
	_selected_node = null
	_observed_organ = null


func _on_piercing_pressed() -> void:
	request_start(PIERCING)


func _on_scatter_pressed() -> void:
	request_start(SCATTER)


func _on_pause_pressed() -> void:
	pause_differentiation()


func _on_continue_pressed() -> void:
	resume_differentiation()


func _on_cancel_pressed() -> void:
	cancel_differentiation()


func _on_rules_pressed() -> void:
	_rules_expanded = not _rules_expanded
	if rules_label != null:
		rules_label.text = RULES_FULL if _rules_expanded else RULES_SUMMARY
	if rules_button != null:
		rules_button.text = "收起" if _rules_expanded else "规则"
	var scroll := get_node_or_null("Margin/Content/RulesScroll") as ScrollContainer
	if scroll != null:
		scroll.scroll_vertical = 0


func _on_snapshot_changed(_snapshot: Dictionary) -> void:
	refresh()


func _on_task_terminal(_task_id: int) -> void:
	refresh()


func _on_organ_differentiated(_task_id: int, _organ: AttackOrgan, _direction: int) -> void:
	refresh()


func _on_progress_changed(_total: int, _products: int) -> void:
	refresh()


func _on_nutrition_changed(_nutrition: int) -> void:
	refresh()


func _on_health_changed(_health: int, _maximum: int) -> void:
	refresh()


func _on_structure_changed() -> void:
	refresh()


func _on_selected_host_exiting() -> void:
	select_node(null)


func _on_selected_organ_exiting() -> void:
	refresh.call_deferred()


func configure(system: DifferentiationSystem, supply: DifferentiationSupplySystem) -> void:
	differentiation_system = system
	differentiation_supply_system = supply
	refresh()


func select_node(host: HyphaNode) -> void:
	_disconnect_bindings(_selection_bindings)
	_selected_node = host if _is_live_node(host) else null
	if _selected_node != null:
		_bind_signal(_selected_node, &"organ_slot_changed", _on_structure_changed, _selection_bindings)
		_bind_signal(_selected_node, &"tree_exiting", _on_selected_host_exiting, _selection_bindings)
	refresh()


func get_selected_organ() -> AttackOrgan:
	if not _is_live_node(_selected_node):
		return null
	var occupant: Variant = _selected_node.get_organ_occupant()
	return occupant as AttackOrgan if _is_live_node(occupant) and occupant is AttackOrgan else null


func get_status() -> Dictionary:
	var host: HyphaNode = _selected_node if _is_live_node(_selected_node) else null
	var organ: AttackOrgan = get_selected_organ()
	var availability: StringName = &"no_selection" if host == null else &"not_mature_organ"
	var active_task: Dictionary = {}
	var task: Dictionary = {}
	var supply: Dictionary = {}
	var active: bool = false
	var can_start_piercing: bool = false
	var can_start_scatter: bool = false
	if _is_live_node(differentiation_supply_system):
		supply = differentiation_supply_system.get_supply_snapshot().duplicate(true)
	if _is_live_node(differentiation_system):
		active = differentiation_system.has_active_task()
		active_task = differentiation_system.get_task_snapshot()
		if organ != null:
			task = differentiation_system.get_organ_snapshot(organ)
			availability = differentiation_system.get_availability(organ)
			can_start_piercing = differentiation_system.get_availability(organ, PIERCING) == &"ready"
			can_start_scatter = differentiation_system.get_availability(organ, SCATTER) == &"ready"
		elif host != null and differentiation_system.is_stopped():
			availability = &"stopped"
	elif host != null:
		availability = &"invalid_configuration"
	var owns_active: bool = active and organ != null and active_task.get("organ") == organ \
		and active_task.get("host") == host and int(active_task.get("task_id", 0)) > 0
	if owns_active:
		task = active_task
	var state: StringName = StringName(task.get("state", &"idle"))
	var can_pause: bool = owns_active and availability == &"active" and state != &"paused"
	var can_continue: bool = (owns_active and availability == &"paused" and state == &"paused") \
		or (availability == &"continuable" and state == &"cancelled" \
			and int(task.get("direction", -1)) in [PIERCING, SCATTER])
	var can_cancel: bool = owns_active and state in [&"waiting", &"differentiating", &"paused"]
	var message: String = String(REASON_TEXT.get(availability, "当前无法分化，请检查器官与连接。"))
	if active and not owns_active:
		var active_host: Variant = active_task.get("host")
		var host_name: String = active_host.display_name if _is_live_node(active_host) and active_host is HyphaNode else "另一菌结"
		message = "%s有分化任务；请选择该菌结继续、暂停或取消。" % host_name
	return {
		"host": host, "organ": organ, "availability": availability,
		"message": message, "task": task.duplicate(true), "supply": supply,
		"active_task": active_task.duplicate(true), "owns_active_task": owns_active,
		"can_start_piercing": can_start_piercing, "can_start_scatter": can_start_scatter,
		"can_pause": can_pause, "can_continue": can_continue, "can_cancel": can_cancel,
	}


func refresh() -> void:
	if _refreshing:
		_refresh_pending = true
		return
	_refreshing = true
	_connect_dependencies()
	_observe_selected_organ()
	var snapshot: Dictionary = get_status()
	_update_controls(snapshot)
	if snapshot != _last_status:
		_last_status = snapshot.duplicate(true)
		status_changed.emit(snapshot.duplicate(true))
	_refreshing = false
	if _refresh_pending:
		_refresh_pending = false
		refresh.call_deferred()


func set_interaction_suspended(value: bool) -> void:
	_interaction_suspended = value
	refresh()


func is_pointer_over_panel(viewport_position: Vector2) -> bool:
	return is_inside_tree() and is_visible_in_tree() and get_global_rect().has_point(viewport_position)


func request_start(direction: int) -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var status: Dictionary = get_status()
	var organ: AttackOrgan = status.get("organ") as AttackOrgan
	if direction not in [PIERCING, SCATTER]:
		notice.emit(String(REASON_TEXT[&"invalid_direction"]))
		return false
	var allowed: bool = bool(status.get("can_start_piercing", false)) if direction == PIERCING \
		else bool(status.get("can_start_scatter", false))
	if not allowed or not _is_live_node(differentiation_system):
		notice.emit(String(status.get("message", "当前无法开始分化。")))
		refresh()
		return false
	var task_id: int = differentiation_system.start_differentiation(organ, direction)
	refresh()
	if task_id <= 0:
		notice.emit(String(get_status().get("message", "分化未能开始，请检查连接。")))
		return false
	notice.emit("已开始%s分化；射击与新弹药供养停止，等待材料送达。" % _direction_name(direction))
	return true


func pause_differentiation() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var status: Dictionary = get_status()
	if not bool(status.get("can_pause", false)):
		notice.emit(String(status.get("message", "请先选择正在分化的器官。")))
		return false
	var accepted: bool = differentiation_system.pause_task()
	refresh()
	if accepted:
		notice.emit("分化已暂停，进度保留；射击与新弹药供养仍停止。")
	return accepted


func resume_differentiation() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var status: Dictionary = get_status()
	if not bool(status.get("can_continue", false)):
		notice.emit(String(status.get("message", "请先选择可继续的器官。")))
		return false
	var task: Dictionary = status.get("task", {})
	var accepted: bool = differentiation_system.resume_task() if task.get("state") == &"paused" \
		else differentiation_system.continue_differentiation(status.get("organ")) > 0
	refresh()
	if accepted:
		notice.emit("已沿原%s方向继续，保留已付进度；射击与新弹药供养停止。" % _direction_name(int(task.get("direction", -1))))
	return accepted


func cancel_differentiation() -> bool:
	if is_inside_tree() and get_tree().paused:
		notice.emit("全局暂停中：可以查看和预览，恢复后再确认操作。")
		return false
	var status: Dictionary = get_status()
	if not bool(status.get("can_cancel", false)):
		notice.emit(String(status.get("message", "请先选择正在分化的器官。")))
		return false
	var accepted: bool = differentiation_system.cancel_task()
	refresh()
	if accepted:
		notice.emit("已取消：未使用材料退回，已付进度与方向保留；普通攻击重新等待完整冷却。")
	return accepted


func _update_controls(snapshot: Dictionary) -> void:
	var active_task: Dictionary = snapshot.get("active_task", {})
	var global_active: bool = active_task.get("state", &"idle") in [&"waiting", &"differentiating", &"paused"]
	visible = panel_presentation_enabled and not _interaction_suspended and (_is_live_node(_selected_node) or global_active)
	if not is_node_ready():
		return
	if piercing_button != null:
		piercing_button.disabled = not bool(snapshot.get("can_start_piercing", false))
	if scatter_button != null:
		scatter_button.disabled = not bool(snapshot.get("can_start_scatter", false))
	if pause_button != null:
		pause_button.disabled = not bool(snapshot.get("can_pause", false))
	if continue_button != null:
		continue_button.disabled = not bool(snapshot.get("can_continue", false))
	if cancel_button != null:
		cancel_button.disabled = not bool(snapshot.get("can_cancel", false))
	var task: Dictionary = snapshot.get("task", {})
	var displayed_task: Dictionary = task if not task.is_empty() else active_task if global_active else {}
	if progress_bar != null:
		progress_bar.value = clampf(float(displayed_task.get("progress", 0.0)), 0.0, 1.0) * 100.0
		progress_bar.tooltip_text = "已付材料 %d / 8 · 有效时间 %.2f / 5 秒" % [int(displayed_task.get("consumed_nutrition", 0)), float(displayed_task.get("effective_time", 0.0))]
	if status_label != null:
		status_label.text = _status_text(snapshot, displayed_task)
		status_label.tooltip_text = status_label.text


func _status_text(snapshot: Dictionary, task: Dictionary) -> String:
	var supply: Dictionary = snapshot.get("supply", {})
	var message: String = String(snapshot.get("message", ""))
	var state: StringName = StringName(task.get("state", &"idle"))
	if state == &"idle" or task.is_empty():
		return "%s\n可用材料 %d / 需8 · 战斗预留 %d" % [message, int(supply.get("available", 0)), int(supply.get("combat_reserve", 0))]
	var state_names: Dictionary = {&"waiting": "等待材料", &"differentiating": "分化中", &"paused": "已暂停", &"cancelled": "已取消 · 可沿原方向继续", &"completed": "已完成"}
	var direction: String = _direction_name(int(task.get("direction", -1)))
	var headline: String = "%s · %s" % [direction, String(state_names.get(state, "未开始"))]
	var wait_reason: StringName = StringName(task.get("wait_reason", &""))
	if wait_reason == &"" and int(supply.get("task_id", 0)) == int(task.get("task_id", 0)):
		wait_reason = StringName(supply.get("wait_reason", &""))
	if bool(snapshot.get("owns_active_task", false)) and wait_reason != &"":
		message = String(REASON_TEXT.get(wait_reason, message))
	var in_transit: int = int(supply.get("in_transit", 0)) if int(supply.get("task_id", 0)) == int(task.get("task_id", 0)) else 0
	return "%s · 材料%d/8 · 有效%.1f/5秒\n缓存%d · 在途%d · 尚需%d\n%s" % [
		headline, int(task.get("consumed_nutrition", 0)), float(task.get("effective_time", 0.0)),
		int(task.get("buffered_nutrition", 0)), in_transit, int(task.get("remaining_cost", 8)), message,
	]


func _connect_dependencies() -> void:
	var sources: Array[Node] = []
	if _is_live_node(differentiation_system):
		sources.append(differentiation_system)
		if _is_live_node(differentiation_system.network_system):
			sources.append(differentiation_system.network_system)
		if _is_live_node(differentiation_system.colony_capabilities):
			var progress: Variant = differentiation_system.colony_capabilities.colony_progress
			if _is_live_node(progress):
				sources.append(progress)
	if _is_live_node(differentiation_supply_system):
		sources.append(differentiation_supply_system)
		if _is_live_node(differentiation_supply_system.mother_core):
			sources.append(differentiation_supply_system.mother_core)
	if sources == _dependency_sources:
		return
	_disconnect_bindings(_dependency_bindings)
	_dependency_sources = sources
	for source: Node in sources:
		_bind_signal(source, &"task_changed", _on_snapshot_changed, _dependency_bindings)
		_bind_signal(source, &"supply_changed", _on_snapshot_changed, _dependency_bindings)
		_bind_signal(source, &"budget_changed", _on_snapshot_changed, _dependency_bindings)
		_bind_signal(source, &"task_cancelled", _on_task_terminal, _dependency_bindings)
		_bind_signal(source, &"task_completed", _on_task_terminal, _dependency_bindings)
		_bind_signal(source, &"organ_differentiated", _on_organ_differentiated, _dependency_bindings)
		_bind_signal(source, &"network_changed", _on_structure_changed, _dependency_bindings)
		_bind_signal(source, &"progress_changed", _on_progress_changed, _dependency_bindings)
		_bind_signal(source, &"nutrition_changed", _on_nutrition_changed, _dependency_bindings)
		_bind_signal(source, &"health_changed", _on_health_changed, _dependency_bindings)
		_bind_signal(source, &"depleted", _on_structure_changed, _dependency_bindings)


func _observe_selected_organ() -> void:
	var organ: AttackOrgan = get_selected_organ()
	if organ == _observed_organ:
		return
	_disconnect_bindings(_organ_bindings)
	_observed_organ = organ
	if organ != null:
		_bind_signal(organ, &"differentiation_changed", _on_snapshot_changed, _organ_bindings)
		_bind_signal(organ, &"tree_exiting", _on_selected_organ_exiting, _organ_bindings)


func _bind_signal(source: Node, signal_name: StringName, callback: Callable, bindings: Array[Dictionary]) -> void:
	if not is_instance_valid(source) or not source.has_signal(signal_name) or source.is_connected(signal_name, callback):
		return
	source.connect(signal_name, callback)
	bindings.append({"source": source, "signal": signal_name, "callback": callback})


func _disconnect_bindings(bindings: Array[Dictionary]) -> void:
	for binding: Dictionary in bindings:
		var source: Variant = binding.get("source")
		if is_instance_valid(source) and source.is_connected(binding["signal"], binding["callback"]):
			source.disconnect(binding["signal"], binding["callback"])
	bindings.clear()


func _connect_button(button: Button, callback: Callable) -> void:
	if button != null and not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _direction_name(direction: int) -> String:
	match direction:
		PIERCING:
			return "破甲"
		SCATTER:
			return "散射"
		_:
			return "普通"


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and node.is_inside_tree() and not node.is_queued_for_deletion()
