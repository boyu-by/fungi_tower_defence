extends SceneTree
## 首关真实 GUI / 输入路由回归；伤害只用于修复与终局夹具，不作为正常通关证据。

const LEVEL: PackedScene = preload("res://scenes/levels/first_level.tscn")
var level: FirstLevel
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _fresh()
	var ui: CompactColonyHUD = level.compact_hud
	_check(ui.active_page == &"" and not ui.drawer.visible, "details start collapsed")
	_check(not level.flow_hud.flow_panel.visible and not level.flow_hud.colony_panel.visible,
		"old summary panels are hidden")
	_check(level.construction_queue_controller.is_visible_in_tree()
		and not level.construction_queue_controller.get_node("Panel").visible,
		"map task markers remain alive when queue panel is hidden")
	_check(not level.construction_queue_controller.is_pointer_over_panel(Vector2(500, 150)),
		"hidden queue does not block its former screen rectangle")
	_check(not ui.is_pointer_over_ui(Vector2(1000, 400)), "closed drawer releases battlefield hit testing")
	_check(ui.nutrition_button.text.contains("72") and ui.health_button.text.contains("240/240"),
		"top bar displays actual starting resources")
	_check(ui.top_right.get_global_rect().end.x <= root.get_visible_rect().size.x - 20,
		"wave controls and more button stay inside the viewport after captions update")
	_check(not level.digestive_organ.queue_label.visible, "detailed map counters start hidden")
	for node: Node in ui.find_children("*", "Label", true, false):
		_check(not (node as Label).text.contains("极简工具坞"), "preview explanation is absent from game labels")
	_click(ui.dock_buttons[&"queue"].get_global_rect().get_center())
	await _frames(2)
	_check(ui.active_page == &"queue", "real dock click opens queue")
	_click(ui.dock_buttons[&"queue"].get_global_rect().get_center())
	_check(ui.active_page == &"", "second click collapses queue")
	_key(KEY_G)
	await _frames(2)
	_check(level.growth_input_controller.is_placing(), "G starts planning with all details hidden")
	ui.open_page(&"queue")
	await _frames(2)
	var count: int = level.construction_coordinator.get_snapshot().entries.size()
	_click(ui.drawer.get_global_rect().position + Vector2(10, 280))
	await _frames(2)
	_check(level.construction_coordinator.get_snapshot().entries.size() == count,
		"clicking an open drawer cannot place a construction target behind it")
	ui.close_drawer()
	_click(Vector2(330, 395))
	await _frames(3)
	var id: String = String(level.construction_coordinator.get_snapshot().selected_id)
	_check(not id.is_empty() and level.construction_coordinator.get_snapshot().entries.size() == 1,
		"map click still creates a real queued target")
	_key(KEY_ESCAPE)
	_key(KEY_SPACE)
	await _frames(2)
	_check(paused, "Space globally pauses while hidden controllers remain alive")
	var capital: int = level.mother_core.nutrition
	var clock_before: float = level.elapsed_seconds
	_click(ui.dock_buttons[&"queue"].get_global_rect().get_center())
	await _frames(2)
	_check(ui.active_page == &"queue", "drawer can open during global pause")
	var state: StringName = level.construction_coordinator.get_request(id).get("state", &"")
	_key(KEY_P)
	await _frames(4)
	_check(level.construction_coordinator.get_request(id).get("state") == state
		and level.mother_core.nutrition == capital and level.elapsed_seconds == clock_before,
		"paused UI does not advance, spend, or alter a construction task")
	_key(KEY_G)
	await _frames(2)
	_check(level.growth_input_controller.is_placing(), "paused G preview still works")
	_key(KEY_ESCAPE)
	_key(KEY_SPACE)
	await _frames(2)
	_check(not paused, "Space resumes simulation")
	level.construction_queue_controller.select_request(id)
	ui.close_drawer()
	_key(KEY_P)
	_check(level.construction_coordinator.get_request(id).get("state") == &"paused",
		"hidden queue retains P pause")
	_key(KEY_P)
	_check(level.construction_coordinator.get_request(id).get("state") != &"paused",
		"hidden queue retains P resume")
	_key(KEY_T)
	_check(level._operation_mode == &"retarget", "T retains target retargeting")
	_click(ui.dock_buttons[&"grow"].get_global_rect().get_center())
	_check(level._operation_mode == &"" and level.growth_input_controller.is_placing(),
		"dock planning exits an old retarget mode just like G")
	_key(KEY_ESCAPE)
	level.construction_queue_controller.select_request(id)
	_key(KEY_X)
	await _frames(3)
	_check(level.construction_coordinator.get_request(id).get("state", &"cancelled") == &"cancelled",
		"hidden queue retains X cancellation")
	_key(KEY_O)
	_check(level.cultivation_input_controller.selected_organ_kind == &"digestive", "O still selects stomach")
	_key(KEY_B)
	_check(level.cultivation_input_controller.is_remote_placing(), "B still previews remote cultivation")
	_key(KEY_ESCAPE)
	_key(KEY_L)
	_check(level.connection_input_controller.is_placing(), "L still previews connections")
	_key(KEY_ESCAPE)
	var host: HyphaNode = level.get_node("World/Colony/Nodes/HyphaNode")
	level._select_node(host)
	await _frames(2)
	_check(ui.selection_button.visible and not level.differentiation_input_controller.visible,
		"selection exposes a details entry without reopening legacy panels")
	_key(KEY_M)
	_check(level._operation_mode == &"transplant", "M retains transplant preview")
	_key(KEY_Y)
	_key(KEY_ESCAPE)
	ui.open_page(&"differentiation")
	await _frames(2)
	_check(_button(ui.pages[&"differentiation"], "破甲").disabled,
		"locked differentiation mirrors the real growth gate")
	ui.close_drawer()
	_key(KEY_F)
	_check(level.repair_input_controller.is_selecting(), "F works with repair details hidden")
	var edge: HyphaEdge = level.get_node("World/Colony/Connections/HyphaEdge")
	edge.take_damage(5)
	_check(level.repair_input_controller.select_edge(edge), "fixture selects damaged edge through original repair controller")
	_key(KEY_J)
	_check(level.repair_system.has_active_task(), "J creates a real repair task")
	_key(KEY_K)
	_check(level.repair_system.get_task_snapshot().get("state") == &"paused", "K still pauses repair")
	_key(KEY_BACKSPACE)
	_check(not level.repair_system.has_active_task(), "Backspace still cancels repair")
	_key(KEY_ESCAPE)
	for page: StringName in ui.pages:
		ui.open_page(page)
		await _frames(2)
		_check(ui.drawer.visible and ui.pages[page].is_visible_in_tree(), "preserved page opens: " + page)
	ui.open_page(&"more")
	(ui.pages[&"more"].get_node("MapDetails") as CheckButton).set_pressed(true)
	await _frames(2)
	_check(level.digestive_organ.queue_label.visible, "map detail switch restores hidden counters")
	(ui.pages[&"more"].get_node("MapDetails") as CheckButton).set_pressed(false)
	ui.open_page(&"help")
	var guide: CheckButton = ui.pages[&"help"].get_child(0) as CheckButton
	guide.set_pressed(false)
	_check(not level.first_guide.is_enabled, "guide switch still controls the original guide")
	guide.set_pressed(true)
	ui.close_drawer()
	_click(ui.start_button.get_global_rect().get_center())
	await _frames(3)
	_check(level.wave_flow.get_snapshot().state == &"fighting", "top start button begins the original wave flow")
	_key(KEY_SPACE)
	_key(KEY_R)
	await _frames(5)
	level = current_scene as FirstLevel
	_check(not paused and level.compact_hud.active_page == &"" and level.mother_core.nutrition == 72,
		"R from paused combat restores a clean collapsed HUD")
	level.mother_core.take_damage(240)
	await _frames(4)
	_check(not level.compact_hud.visible and level.flow_hud.result_panel.visible,
		"terminal settlement remains above the new HUD")
	_click(level.flow_hud.result_restart_button.get_global_rect().get_center())
	await _frames(5)
	level = current_scene as FirstLevel
	_check(level.compact_hud.visible and not paused, "settlement restart restores the compact HUD")
	await _test_cultivation_and_supply()
	for index: int in range(6):
		if index > 0:
			await _fresh()
		if index == 1:
			level.pause_controller.set_paused(true)
		_key(KEY_F5 + index)
		await _frames(5)
		var paths: Array[String] = ["large_carcass_demo", "traffic_recovery_demo", "progression_demo",
			"combat_specialization_demo", "terrain_threat_demo", "colony_operations_demo"]
		_check(current_scene.scene_file_path.ends_with(paths[index] + ".tscn") and not paused,
			"developer shortcut and pause cleanup: F%d" % (5 + index))
	if is_instance_valid(current_scene):
		current_scene.queue_free()
	await _frames(3)
	print("COMPACT_HUD_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _test_cultivation_and_supply() -> void:
	level._select_node(level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode)
	# 独立的输入夹具：关闭自动补给并消耗一份库存，以观察 N 的真实派送。
	level.supply_system.set_process(false)
	level.attack_organ.consume_nutrition()
	var before: int = level.supply_system.get_in_transit_count()
	_key(KEY_N)
	_check(level.supply_system.get_in_transit_count() > before, "N still dispatches real supply while details are closed")
	await _fresh()
	_key(KEY_G)
	_click(Vector2(330, 395))
	_key(KEY_ESCAPE)
	var target: HyphaNode
	for frame: int in range(1800):
		await process_frame
		for node: Node2D in level.network_system.get_registered_nodes():
			if node is HyphaNode and node.global_position.distance_to(Vector2(330, 395)) < 3:
				target = node as HyphaNode
		if is_instance_valid(target):
			break
	_check(is_instance_valid(target), "real paid growth produces an empty cultivation host")
	if is_instance_valid(target):
		level._select_node(target)
		_key(KEY_O)
		_key(KEY_C)
		await _frames(3)
		var has_cultivation: bool = false
		var snapshot: Dictionary = level.construction_coordinator.get_snapshot()
		for entry: Dictionary in snapshot.get("entries", []) + snapshot.get("maturing", []):
			if entry.get("kind") == &"cultivation":
				has_cultivation = true
		_check(has_cultivation, "C admits real local cultivation with its panel hidden")


func _fresh() -> void:
	paused = false
	if is_instance_valid(current_scene):
		current_scene.queue_free()
		await _frames(3)
	level = LEVEL.instantiate() as FirstLevel
	root.add_child(level)
	current_scene = level
	await _frames(4)


func _frames(count: int) -> void:
	for index: int in range(count):
		await process_frame


func _key(code: int) -> void:
	for pressed_value: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = pressed_value
		root.push_input(event, true)


func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed_value: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed_value
		root.push_input(event, true)


func _button(parent: Node, caption: String) -> Button:
	var found: Button
	for node: Node in parent.find_children("*", "Button", true, false):
		if (node as Button).text == caption:
			found = node as Button
	return found


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)
