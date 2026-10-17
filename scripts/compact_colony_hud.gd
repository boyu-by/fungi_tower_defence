class_name CompactColonyHUD
extends CanvasLayer
## 首关工具坞：隐藏旧显示层，复用其真实数据、按钮意图和地图控制器。

const PAGE_TITLES: Dictionary = {
	&"overview": "菌落概况", &"wave": "波次详情", &"build": "培育与建设",
	&"queue": "施工队列", &"selection": "所选组织", &"repair": "组织修复",
	&"differentiation": "攻击分化", &"operations": "改向与移植", &"logistics": "运输与回收",
	&"help": "操作手册", &"more": "更多", &"messages": "消息记录", &"development": "开发演示",
}
const DEMO_ACTIONS: Dictionary = {
	"F5  尸骸回收": &"original_carcass_demo", "F6  断路恢复": &"traffic_recovery_demo",
	"F7  成长解锁": &"progression_demo", "F8  战斗分工": &"combat_specialization_demo",
	"F9  地形危机": &"terrain_threat_demo", "F10  菌落运营": &"colony_operations_demo",
}

var active_page: StringName = &""
var pages: Dictionary[StringName, CompactHUDPage] = {}
var dock_buttons: Dictionary[StringName, Button] = {}
var drawer: PanelContainer
var top_left: PanelContainer
var top_right: PanelContainer
var dock: PanelContainer
var selection_button: Button
var health_button: Button
var nutrition_button: Button
var wave_button: Button
var start_button: Button
var pause_button: Button
var more_button: Button
var menu_button: Button
var goal_label: Label
var level_menu: LevelMenuLayer
var maturing_selector: OptionButton

var _level
var _objective_buttons: Dictionary[StringName, Button] = {}
var _root: Control
var _drawer_title: Label
var _scroll: ScrollContainer
var _page_host: VBoxContainer
var _mode_panel: PanelContainer
var _mode_label: Label
var _toast: Button
var _toast_timer: Timer
var _history: PackedStringArray = []
var _history_label: Label
var _guide_label: Label
var _guide_toggle: CheckButton
var _guide_dismiss: Button
var _selection_health: Label
var _selection_supply: Button
var _attack_choice: Button
var _stomach_choice: Button
var _maturing_signature: Array = []
var _last_mode: StringName = &""
var _configured: bool = false
var _map_details_enabled: bool = false


func _init() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	_configured = false
	if is_instance_valid(_level) and is_instance_valid(_level.hud) \
			and _level.hud.notice_changed.is_connected(_on_notice):
		_level.hud.notice_changed.disconnect(_on_notice)
	if is_instance_valid(_level) and is_instance_valid(_level.first_guide) \
			and _level.first_guide.changed.is_connected(_on_guide_changed):
		_level.first_guide.changed.disconnect(_on_guide_changed)


func configure(level: Node2D) -> void:
	_level = level
	level_menu = preload("res://scenes/ui/level_menu.tscn").instantiate() as LevelMenuLayer
	_level.add_child(level_menu)
	level_menu.configure(_level)
	_build_shell()
	_build_pages()
	_hide_legacy_panels()
	_level.hud.notice_changed.connect(_on_notice)
	_level.first_guide.changed.connect(_on_guide_changed)
	get_viewport().size_changed.connect(_layout)
	top_left.minimum_size_changed.connect(_layout)
	top_right.minimum_size_changed.connect(_layout)
	_configured = true
	_layout()
	refresh()


func _build_shell() -> void:
	_root = Control.new()
	_root.name = "Interface"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = _make_theme()
	add_child(_root)
	top_left = _surface("Resources")
	var resource_column := VBoxContainer.new()
	top_left.add_child(resource_column)
	var resources: HBoxContainer = _horizontal(resource_column)
	health_button = _button(resources, "母核 240/240", toggle_page.bind(&"overview"))
	nutrition_button = _button(resources, "营养 72", toggle_page.bind(&"overview"))
	goal_label = Label.new()
	goal_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_label.add_theme_font_size_override("font_size", 13)
	goal_label.text = "目标：收集三个碎片，保护母核" if _level.has_method("get_fragment_targets") else (
		"目标：摧毁三台AI，保护母核" if _level.has_method("get_facility_targets") else "目标：清除六波敌人，保护母核")
	resource_column.add_child(goal_label)
	top_right = _surface("WaveControls")
	var flow: HBoxContainer = _horizontal(top_right)
	wave_button = _button(flow, "初始准备 · 1/6", toggle_page.bind(&"wave"))
	start_button = _button(flow, "开始第 1 波", _level.start_next_wave)
	start_button.add_theme_stylebox_override("normal", _box(Color("c7d9a2"), Color("c7d9a2"), 8))
	start_button.add_theme_color_override("font_color", Color("17251b"))
	pause_button = _button(flow, "暂停", _level.pause_controller.toggle_pause)
	pause_button.tooltip_text = "Space 全局暂停 / 恢复；暂停中仍可选择和预览"
	menu_button = _button(flow, "菜单", level_menu.open_menu)
	more_button = _button(flow, "⋯", toggle_page.bind(&"more"))
	more_button.tooltip_text = "更多：物流、操作手册、引导与重开"
	dock = _surface("Dock")
	var commands: HBoxContainer = _horizontal(dock)
	for item: Array in [[&"grow", "伸展\nG"], [&"seed", "种芽\nB"], [&"build", "培育\nC"],
			[&"link", "接合\nL"], [&"repair", "修复\nF"], [&"queue", "队列\n0"]]:
		var button: Button = _button(commands, item[1], _on_dock_pressed.bind(item[0]))
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(90, 60)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dock_buttons[item[0]] = button
	selection_button = _button(_root, "所选组织 · 详情", toggle_page.bind(&"selection"))
	selection_button.name = "SelectedDetails"
	selection_button.hide()
	_mode_panel = _surface("PlacementHint")
	var mode_row: HBoxContainer = _horizontal(_mode_panel)
	_mode_label = Label.new()
	_mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_label.max_lines_visible = 3
	_mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_label.add_theme_font_size_override("font_size", 13)
	mode_row.add_child(_mode_label)
	_button(mode_row, "详情", _open_mode_details)
	_mode_panel.hide()
	_toast = _button(_root, "", toggle_page.bind(&"messages"))
	_toast.name = "Notice"
	_toast.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_toast.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_toast.clip_text = true
	_toast.add_theme_font_size_override("font_size", 13)
	_toast.hide()
	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.wait_time = 5.0
	_toast_timer.timeout.connect(_toast.hide)
	add_child(_toast_timer)
	drawer = _surface("Details")
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	drawer.add_child(column)
	var heading: HBoxContainer = _horizontal(column)
	_drawer_title = Label.new()
	_drawer_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawer_title.add_theme_font_size_override("font_size", 19)
	heading.add_child(_drawer_title)
	var close: Button = _button(heading, "×", close_drawer)
	close.tooltip_text = "收起面板；不会取消任务"
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_scroll)
	_page_host = VBoxContainer.new()
	_page_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_page_host)
	drawer.hide()


func _build_pages() -> void:
	var hud: ColonyHUD = _level.hud
	var flow: FirstLevelHUD = _level.flow_hud
	var page: CompactHUDPage = _page(&"overview")
	page.mirror_label(flow.colony_label)
	page.mirror_label(hud.stage_label)
	page.mirror_label(hud.colony_label)
	var row: GridContainer = page.row()
	page.action("运输与回收", open_page.bind(&"logistics"), row)
	page.action("施工队列", open_page.bind(&"queue"), row)
	page.mirror_label(hud.stock_label, false, page.disclosure("库存明细"))
	page = _page(&"wave")
	for label: Label in [flow.wave_label, flow.progress_label, flow.counts_label, flow.next_label, flow.pause_label]:
		page.mirror_label(label)
	page.mirror_button(flow.start_button, page, true)
	page.mirror_button(flow.pause_button)
	if _level.has_method("get_facility_targets"):
		for facility: AIFacility in _level.get_facility_targets():
			_objective_buttons[facility.facility_id] = page.action(facility.display_name,
				_level.prioritize_facility.bind(facility.facility_id))
		page.action("恢复自动选敌", _level.clear_facility_priority)
		page.text("点击设施设为优先目标，再次点击取消。只有射程内的器官会向它开火。")
	elif _level.has_method("get_fragment_targets"):
		page.text("用有效菌域覆盖碎片并保持连通5秒。多处覆盖不加速，断路保留进度，收齐立即结束。")
	page = _page(&"build")
	page.heading("培育类型 · O 切换")
	row = page.row()
	_attack_choice = page.mirror_button(_level._attack_choice, row)
	_stomach_choice = page.mirror_button(_level._stomach_choice, row)
	_attack_choice.toggle_mode = true
	_stomach_choice.toggle_mode = true
	row = page.row()
	page.mirror_button(hud.cultivation_button, row, true)
	page.action("B 远处种芽", _on_dock_pressed.bind(&"seed"), row)
	page.mirror_label(hud.cultivation_reason_label)
	page.heading("网络")
	row = page.row()
	page.action("G 伸展", _on_dock_pressed.bind(&"grow"), row)
	page.action("L 接合", _on_dock_pressed.bind(&"link"), row)
	page.mirror_label(hud.growth_label)
	row = page.row()
	page.mirror_button(hud.growth_pause_button, row, true)
	page.mirror_button(hud.growth_cancel_button, row, true)
	var details: VBoxContainer = page.disclosure("材料与费用")
	page.mirror_label(hud.growth_supply_label, false, details)
	page.text("攻击器官 12＝8 结构＋4 库存；胃囊 8 全计结构。远处种芽另付实际网络费用。", details)
	page.action("目标改向 / 移植", open_page.bind(&"operations"))
	_build_queue_page()
	page = _page(&"selection")
	page.mirror_label(hud.selection_label)
	_selection_health = page.text("")
	page.mirror_label(hud.stock_label)
	row = page.row()
	_selection_supply = page.action("N 供养", _request_supply, row, true)
	page.action("攻击分化", open_page.bind(&"differentiation"), row)
	row = page.row()
	page.action("培育", open_page.bind(&"build"), row)
	page.action("改向 / 移植", open_page.bind(&"operations"), row)
	page.action("F 选择组织修复", _on_dock_pressed.bind(&"repair"))
	page.mirror_label(hud.cultivation_reason_label, true, page.disclosure("培育条件"))
	page.mirror_label(hud.recovery_label, true, page.disclosure("消化与回收明细"))
	_build_differentiation_page()
	page = _page(&"repair")
	page.mirror_label(hud.repair_info_label)
	row = page.row()
	page.mirror_button(hud.repair_mode_button, row)
	page.mirror_button(hud.repair_request_button, row, true)
	row = page.row()
	page.mirror_button(hud.repair_pause_button, row, true)
	page.mirror_button(hud.repair_cancel_button, row, true)
	page.mirror_label(hud.repair_info_label, true, page.disclosure("修复账目与菌脉详情"))
	page = _page(&"operations")
	row = page.row()
	page.action("T 目标改向", _begin_operation.bind(&"retarget"), row)
	page.action("M 移植 · 6", _begin_operation.bind(&"transplant"), row)
	page.mirror_button(_level._cancel_transplant, page, true)
	page.mirror_label(_level._operations_status)
	page.action("选择施工任务", open_page.bind(&"queue"))
	page = _page(&"logistics")
	page.heading("营养与通行")
	page.mirror_label(hud.transport_label)
	page.mirror_label(hud.traffic_label)
	page.heading("回收与消化")
	page.mirror_label(hud.recovery_label)
	page.mirror_label(hud.get_node("FieldLegend") as Label, false,
		page.disclosure("地图图例"))
	_build_help_page()
	page = _page(&"more")
	row = page.row()
	var more_items: Array = [[&"overview", "菌落概况"], [&"logistics", "运输回收"], [&"wave", "波次详情"],
			[&"help", "操作手册 / 引导"], [&"messages", "消息记录"]]
	if _level.has_method("get_facility_targets"):
		more_items[2][1] = "AI目标与生产"
	elif _level.has_method("get_fragment_targets"):
		more_items[2][1] = "碎片与来袭"
	if _level.has_method("open_development_demo"):
		more_items.append([&"development", "开发演示"])
	for item: Array in more_items:
		page.action(item[1], open_page.bind(item[0]), row)
	page.mirror_button(flow.restart_button)
	page.action("游戏菜单", level_menu.open_menu)
	var map_toggle := CheckButton.new()
	map_toggle.name = "MapDetails"
	map_toggle.text = "地图详细标注"
	map_toggle.focus_mode = Control.FOCUS_NONE
	map_toggle.toggled.connect(func(enabled: bool) -> void: _map_details_enabled = enabled)
	page.add_child(map_toggle)
	page = _page(&"messages")
	_history_label = page.text("暂无消息")
	if _level.has_method("open_development_demo"):
		page = _page(&"development")
		for caption: String in DEMO_ACTIONS:
			page.action(caption, _level.open_development_demo.bind(DEMO_ACTIONS[caption]))
		page.text("各阶段演示保留原批次、调试操作与快捷键。")


func _build_queue_page() -> void:
	var page: CompactHUDPage = _page(&"queue")
	var queue: ConstructionQueueController = _level.construction_queue_controller
	page.mirror_label(queue._title_label)
	for source: Button in queue._row_buttons:
		var button: Button = page.mirror_button(source)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var row: GridContainer = page.row()
	page.mirror_button(queue._up_button, row, true)
	page.mirror_button(queue._down_button, row, true)
	row = page.row(3)
	page.mirror_button(queue._pause_button, row, true)
	page.mirror_button(queue._resume_button, row, true)
	page.mirror_button(queue._cancel_button, row, true)
	maturing_selector = OptionButton.new()
	maturing_selector.focus_mode = Control.FOCUS_NONE
	maturing_selector.fit_to_longest_item = false
	maturing_selector.clip_text = true
	maturing_selector.custom_minimum_size.y = 38
	maturing_selector.item_selected.connect(_on_maturing_selected)
	page.add_child(maturing_selector)
	page.action("T 改向所选目标", _begin_operation.bind(&"retarget"))
	page.mirror_label(_level.hud.growth_label)
	var details: VBoxContainer = page.disclosure("建设材料与运营详情")
	page.mirror_label(_level.hud.growth_supply_label, false, details)
	page.mirror_label(_level._operations_status, false, details)


func _build_differentiation_page() -> void:
	var page: CompactHUDPage = _page(&"differentiation")
	var source: DifferentiationInputController = _level.differentiation_input_controller
	page.mirror_label(_level.hud.selection_label)
	page.mirror_label(source.status_label)
	page.mirror_progress(source.progress_bar)
	var row: GridContainer = page.row()
	page.mirror_button(source.piercing_button, row, true)
	page.mirror_button(source.scatter_button, row, true)
	row = page.row(3)
	page.mirror_button(source.pause_button, row, true)
	page.mirror_button(source.continue_button, row, true)
	page.mirror_button(source.cancel_button, row, true)
	var details: VBoxContainer = page.disclosure("分化规则与退款")
	page.mirror_label(source.type_info_label, false, details)
	page.text(DifferentiationInputController.RULES_FULL, details)


func _build_help_page() -> void:
	var page: CompactHUDPage = _page(&"help")
	_guide_toggle = CheckButton.new()
	_guide_toggle.text = "首次事件引导"
	_guide_toggle.focus_mode = Control.FOCUS_NONE
	_guide_toggle.toggled.connect(_level.first_guide.set_enabled)
	page.add_child(_guide_toggle)
	_guide_label = page.text("")
	_guide_dismiss = page.action("知道了 / 下一条", _level.first_guide.dismiss_current)
	page.heading("建造与运营")
	page.text("G 伸展 · B 远处种芽 · C 原位培育\nO 切换器官 · L 连接菌结\nT 目标改向 · M 移植 · Y 取消移植准备")
	page.heading("任务与修复")
	page.text("P 建设暂停 / 继续 · X 取消建设\nF 选择组织 · J 修复 · K 修复暂停 / 继续\nBackspace 取消修复 · N 供养所选攻击器官")
	page.heading("全局")
	page.text("Space 全局暂停 / 恢复 · R 重开\n右键 / Esc 退出当前操作" +
		("\nF5–F10 各阶段开发演示" if _level.has_method("open_development_demo") else ""))
	var details: VBoxContainer = page.disclosure("首关地图与资源提示")
	for path: String in ["World/FirstResourceGuide/Hint", "World/SecondResourceGuide/Hint", "World/BypassLabel"]:
		var label: Label = _level.get_node_or_null(path) as Label
		if label != null:
			page.mirror_label(label, false, details)
	page.text("暂停时仍可选择与预览；恢复后重新确认付费操作。收起面板不取消任何任务。", details)


func _hide_legacy_panels() -> void:
	# 队列根节点还在画地图标记，不能隐藏或停用整个控制器。
	for child: Node in _level.hud.get_children():
		if child is CanvasItem and child != _level.construction_queue_controller:
			(child as CanvasItem).hide()
	_level.construction_queue_controller.get_node("Panel").hide()
	_level.construction_queue_controller.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level.differentiation_input_controller.panel_presentation_enabled = false
	_level.differentiation_input_controller.hide()
	_level.flow_hud.colony_panel.hide()
	_level.flow_hud.flow_panel.hide()
	for path: String in ["World/FirstResourceGuide/Hint", "World/SecondResourceGuide/Hint", "World/BypassLabel"]:
		var label: CanvasItem = _level.get_node_or_null(path) as CanvasItem
		if label != null:
			label.hide()


func refresh() -> void:
	if not _configured:
		return
	visible = _level.get_result_snapshot().is_empty()
	if not visible:
		return
	var core: MotherCore = _level.mother_core
	health_button.text = "母核 %d/%d" % [ceili(core.health), ceili(core.max_health)]
	nutrition_button.text = "营养 %d" % core.nutrition
	health_button.tooltip_text = _level.flow_hud.colony_label.text
	nutrition_button.tooltip_text = "点击查看成长、累计回收与完整库存"
	var flow: Dictionary = _level.wave_flow.get_snapshot()
	var state: StringName = flow.get("state", &"initial_preparation")
	var wave: int = maxi(1, int(flow.get("wave_index", 0)))
	if state == &"preparation":
		wave = mini(6, int(flow.get("completed_waves", 0)) + 1)
		wave_button.text = "%d/6 波 · %ds" % [wave, ceili(float(flow.get("preparation_remaining", 0.0)))]
	else:
		wave_button.text = "%d/6 波 · %s" % [wave, "战斗" if state == &"fighting" else "准备"]
	if _level.has_method("get_objective_caption"):
		wave_button.text = _level.get_objective_caption()
	if _level.has_method("get_facility_targets"):
		for facility: AIFacility in _level.get_facility_targets():
			var button: Button = _objective_buttons[facility.facility_id]
			button.text = "%s · %d/%d%s" % [facility.display_name, facility.health,
				facility.max_health, " · 优先" if facility.prioritized else ""]
			button.disabled = not facility.is_alive()
	wave_button.tooltip_text = _level.flow_hud.next_label.text + "\n点击查看波次详情"
	if not _objective_buttons.is_empty():
		wave_button.tooltip_text = _level.flow_hud.next_label.text + "\n点击查看AI目标与生产"
	elif _level.has_method("get_fragment_targets"):
		wave_button.tooltip_text = _level.flow_hud.next_label.text + "\n点击查看碎片与来袭"
	start_button.text = _level.flow_hud.start_button.text
	start_button.disabled = _level.flow_hud.start_button.disabled
	pause_button.text = "恢复 · Space" if get_tree().paused else "暂停 · Space"
	pause_button.disabled = _level.flow_hud.pause_button.disabled
	var snapshot: Dictionary = _level.construction_coordinator.get_snapshot()
	var count: int = snapshot.get("entries", []).size() + snapshot.get("maturing", []).size()
	dock_buttons[&"queue"].text = "队列\n%d" % count
	_refresh_selection()
	_refresh_map_labels()
	_refresh_mode()
	if active_page != &"":
		pages[active_page].refresh()
		if active_page == &"queue":
			_refresh_maturing()
		if active_page == &"build":
			_attack_choice.set_pressed_no_signal(_level.cultivation_input_controller.selected_organ_kind == &"attack")
			_stomach_choice.set_pressed_no_signal(_level.cultivation_input_controller.selected_organ_kind == &"digestive")
		if active_page == &"selection":
			_selection_supply.disabled = get_tree().paused or not is_instance_valid(_level._get_selected_organ())
	_refresh_guide()


func _refresh_selection() -> void:
	var selected: HyphaNode = _level.selected_node
	selection_button.visible = is_instance_valid(selected)
	_selection_health.text = "未选择组织；点击地图上的菌结后查看。"
	if is_instance_valid(selected):
		selection_button.text = "%s · 详情" % selected.display_name
		_selection_health.text = "菌结生命 %.0f/%.0f · %s" % [selected.health, selected.max_health,
			"已连通" if _level.network_system.is_available_connected_to_core(selected) else "失联"]
		var organ: Node = selected.get_organ_occupant()
		if is_instance_valid(organ) and organ.has_method("get_health_snapshot"):
			var health: Dictionary = organ.get_health_snapshot()
			_selection_health.text += "\n器官生命 %.0f/%.0f" % [float(health.get("health", 0)), float(health.get("max_health", 0))]


func _refresh_map_labels() -> void:
	for organ: DigestiveOrgan in _level.get_digestive_organs():
		for path: String in ["QueueLabel", "ChamberStatus", "SecondChamber/StateLabel"]:
			var label: CanvasItem = organ.get_node_or_null(path) as CanvasItem
			if label != null:
				label.visible = _map_details_enabled
	for path: String in ["World/FirstResourceGuide/Hint", "World/SecondResourceGuide/Hint", "World/BypassLabel"]:
		var label: CanvasItem = _level.get_node_or_null(path) as CanvasItem
		if label != null:
			label.visible = _map_details_enabled


func _refresh_mode() -> void:
	var mode: StringName = &""
	var message: String = ""
	if _level._operation_mode != &"":
		mode = _level._operation_mode
		message = _level._operations_status.text
	elif _level.growth_input_controller.is_placing() or _level.cultivation_input_controller.is_remote_placing() \
			or _level.connection_input_controller.is_placing():
		mode = &"build"
		message = _level.hud.growth_label.text
	elif _level.repair_input_controller.is_selecting():
		mode = &"repair"
		message = _level.hud.repair_info_label.text.get_slice("\n", 0) + " · J 修复 / K 暂停 / Backspace 取消"
	_mode_panel.visible = mode != &""
	_mode_label.text = message
	_mode_label.tooltip_text = message
	if mode != _last_mode and mode != &"" and active_page != &"repair":
		close_drawer()
	_last_mode = mode
	selection_button.visible = selection_button.visible and not _mode_panel.visible
	for id: StringName in dock_buttons:
		var active: bool = id == active_page or (id == &"grow" and _level.growth_input_controller.is_placing()) \
			or (id == &"seed" and _level.cultivation_input_controller.is_remote_placing()) \
			or (id == &"link" and _level.connection_input_controller.is_placing()) \
			or (id == &"repair" and _level.repair_input_controller.is_selecting())
		dock_buttons[id].set_pressed_no_signal(active)


func _refresh_maturing() -> void:
	if maturing_selector.get_popup().visible:
		return
	var source: OptionButton = _level.construction_queue_controller._maturing_selector
	var signature: Array = []
	for index: int in range(source.item_count):
		signature.append([source.get_item_text(index), source.get_item_metadata(index), source.is_item_disabled(index)])
	if signature != _maturing_signature:
		_maturing_signature = signature
		maturing_selector.clear()
		for item: Array in signature:
			maturing_selector.add_item(item[0])
			var index: int = maturing_selector.item_count - 1
			maturing_selector.set_item_metadata(index, item[1])
			maturing_selector.set_item_disabled(index, item[2])
	if source.selected >= 0 and source.selected < maturing_selector.item_count:
		maturing_selector.select(source.selected)
	maturing_selector.visible = source.visible


func _refresh_guide() -> void:
	var guide: Dictionary = _level.first_guide.get_snapshot()
	_guide_toggle.set_pressed_no_signal(bool(guide.get("enabled", true)))
	_guide_label.text = String(guide.get("text", "")) if bool(guide.get("visible", false)) else "新的操作提示会在这里保留。"
	_guide_dismiss.disabled = not bool(guide.get("visible", false))


func open_page(id: StringName) -> void:
	if not pages.has(id):
		return
	active_page = id
	for key: StringName in pages:
		pages[key].visible = key == id
	_drawer_title.text = "AI目标与生产" if id == &"wave" and not _objective_buttons.is_empty() else PAGE_TITLES[id]
	if id == &"wave" and _level.has_method("get_fragment_targets"):
		_drawer_title.text = "碎片与来袭"
	_scroll.scroll_vertical = 0
	drawer.show()
	_layout()
	refresh()


func toggle_page(id: StringName) -> void:
	if active_page == id:
		close_drawer()
	else:
		open_page(id)


func close_drawer() -> void:
	active_page = &""
	drawer.hide()
	if is_instance_valid(maturing_selector):
		maturing_selector.get_popup().hide()
	_layout()


func is_pointer_over_ui(point: Vector2) -> bool:
	if not visible or not _configured:
		return false
	if maturing_selector.get_popup().visible:
		return true
	for control: Control in [top_left, top_right, dock, drawer, selection_button, _mode_panel, _toast]:
		if control.is_visible_in_tree() and control.get_global_rect().has_point(point):
			return true
	return false


func _on_dock_pressed(id: StringName) -> void:
	if id in [&"build", &"queue"]:
		toggle_page(id)
	else:
		close_drawer()
		_level._end_operation_mode()
		match id:
			&"grow": _level.hud.growth_mode_requested.emit()
			&"seed": _level.hud.remote_cultivation_requested.emit()
			&"link": _level.hud.connection_mode_requested.emit()
			&"repair":
				_level.hud.repair_mode_requested.emit()
				open_page(&"repair")
	refresh()


func _begin_operation(kind: StringName) -> void:
	var accepted: bool = _level.begin_retarget() if kind == &"retarget" else _level.begin_transplant()
	if accepted:
		close_drawer()
	refresh()


func _open_mode_details() -> void:
	var page: StringName = &"operations" if _level._operation_mode != &"" else (
		&"repair" if _level.repair_input_controller.is_selecting() else &"build")
	open_page(page)


func _request_supply() -> void:
	if get_tree().paused:
		return
	var organ: AttackOrgan = _level._get_selected_organ()
	if is_instance_valid(organ):
		_level.supply_system.request_supply(organ)


func _on_maturing_selected(index: int) -> void:
	if index >= 0 and index < maturing_selector.item_count:
		_level.construction_queue_controller.select_request(String(maturing_selector.get_item_metadata(index)))
	refresh()


func _on_notice(message: String) -> void:
	if message.is_empty() or not _configured or not is_inside_tree():
		return
	if _history.is_empty() or _history[0] != message:
		_history.insert(0, message)
		if _history.size() > 24:
			_history.resize(24)
	_history_label.text = "\n\n".join(_history)
	_toast.text = message.replace("\n", " · ")
	_toast.tooltip_text = message + "\n点击查看完整消息记录"
	_toast.show()
	_toast_timer.start()


func _on_guide_changed(snapshot: Dictionary) -> void:
	if not _configured or not is_inside_tree():
		return
	_refresh_guide()
	if bool(snapshot.get("visible", false)):
		_on_notice("操作提示：" + String(snapshot.get("text", "")).replace("\n", " "))


func _page(id: StringName) -> CompactHUDPage:
	var page := CompactHUDPage.new()
	page.name = String(id).capitalize().replace(" ", "")
	_page_host.add_child(page)
	page.hide()
	pages[id] = page
	return page


func _surface(node_name: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	_root.add_child(panel)
	return panel


func _horizontal(parent: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row


func _button(parent: Node, caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 38
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _layout() -> void:
	if not is_inside_tree():
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	_root.size = viewport_size
	top_left.position = Vector2(24, 18)
	top_left.size = top_left.get_combined_minimum_size()
	top_right.size = top_right.get_combined_minimum_size()
	top_right.position = Vector2(viewport_size.x - top_right.size.x - 24, 18)
	dock.size = Vector2(620, 80)
	dock.position = Vector2((viewport_size.x - dock.size.x) * 0.5, viewport_size.y - 104)
	drawer.position = Vector2(viewport_size.x - 436, 88)
	drawer.size = Vector2(412, maxf(300, viewport_size.y - 224))
	selection_button.position = Vector2(24, viewport_size.y - 151)
	selection_button.size = Vector2(320, 38)
	var hint_width: float = minf(700, drawer.position.x - 48) if drawer.visible else 700.0
	_mode_panel.position = Vector2(24 if drawer.visible else (viewport_size.x - hint_width) * 0.5, viewport_size.y - 202)
	_mode_panel.size = Vector2(hint_width, 86)
	_toast.position = Vector2(24, 112)
	_toast.size = Vector2(minf(660, viewport_size.x - 484), 38)
	if is_instance_valid(_level.frontier_status):
		_level.frontier_status.exposure_label_position = Vector2(24, viewport_size.y - 216)


func _box(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = background
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	return box


func _make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = _level.hud.selection_label.get_theme_font("font")
	theme.default_font_size = 14
	var normal: StyleBoxFlat = _box(Color("14221c"), Color("3c5144"), 8)
	var hover: StyleBoxFlat = _box(Color("263e2e"), Color("66805a"), 8)
	var pressed: StyleBoxFlat = _box(Color("3a5236"), Color("c7d9a2"), 8)
	var disabled: StyleBoxFlat = _box(Color("18241d"), Color("2d3c32"), 8)
	for type: StringName in [&"Button", &"OptionButton", &"CheckButton"]:
		theme.set_stylebox("normal", type, normal)
		theme.set_stylebox("hover", type, hover)
		theme.set_stylebox("pressed", type, pressed)
		theme.set_stylebox("hover_pressed", type, pressed)
		theme.set_stylebox("disabled", type, disabled)
		theme.set_color("font_color", type, Color("e6edde"))
		theme.set_color("font_hover_color", type, Color("f2f4e7"))
		theme.set_color("font_pressed_color", type, Color("e6edde"))
		theme.set_color("font_disabled_color", type, Color("788d79"))
	theme.set_color("font_color", "Label", Color("c3d1bf"))
	theme.set_stylebox("panel", "PanelContainer", _box(Color("14221c"), Color("3c5144"), 12))
	var track := StyleBoxFlat.new()
	track.bg_color = Color("293b2e")
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("c7d9a2")
	theme.set_stylebox("background", "ProgressBar", track)
	theme.set_stylebox("fill", "ProgressBar", fill)
	return theme
