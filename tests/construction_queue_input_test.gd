extends SceneTree
## 独立队列 UI 输入夹具；使用真实队列和记录调用的协调器，不启动施工执行器。

const CONTROLLER_SCENE: PackedScene = preload("res://scenes/ui/construction_queue.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")


class InputSpyCoordinator extends ConstructionCoordinator:
	var calls: Array[Dictionary] = []
	var refuse_commands: bool = false
	var presented_started_id: String = ""

	func _ready() -> void:
		queue.changed.connect(_forward_queue_snapshot)

	func _process(_delta: float) -> void:
		pass

	func _exit_tree() -> void:
		if is_instance_valid(queue) and queue.changed.is_connected(_forward_queue_snapshot):
			queue.changed.disconnect(_forward_queue_snapshot)

	func get_snapshot() -> Dictionary:
		var snapshot: Dictionary = queue.get_snapshot()
		var entries: Array = snapshot.get("entries", [])
		for entry: Dictionary in entries:
			if String(entry.get("construction_id", "")) == presented_started_id:
				entry["state"] = &"executing"
				entry["started"] = true
		return snapshot

	func get_request(construction_id: String) -> Dictionary:
		return queue.get_request(construction_id)

	func select_request(construction_id: String) -> bool:
		calls.append({"operation": &"select", "construction_id": construction_id})
		return queue.select_request(construction_id)

	func move_request(construction_id: String, direction: int) -> bool:
		calls.append({"operation": &"move", "construction_id": construction_id, "direction": direction})
		return false if refuse_commands else queue.move_request(construction_id, direction)

	func pause_request(construction_id: String) -> bool:
		calls.append({"operation": &"pause", "construction_id": construction_id})
		return false if refuse_commands else queue.pause_request(construction_id)

	func resume_request(construction_id: String) -> bool:
		calls.append({"operation": &"resume", "construction_id": construction_id})
		return false if refuse_commands else queue.resume_request(construction_id)

	func cancel_request(construction_id: String) -> bool:
		calls.append({"operation": &"cancel", "construction_id": construction_id})
		return false if refuse_commands else queue.cancel_request(construction_id)

	func _forward_queue_snapshot(_snapshot: Dictionary) -> void:
		changed.emit(get_snapshot())


var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_test_configuration_guard()
	_test_static_rows_and_identity()
	_test_selected_commands_and_no_fallback()
	_test_reordering_and_shared_buttons()
	_test_explicit_clear_selection()
	_test_map_selection_and_canvas_transform()
	_test_terminal_and_reset_refresh()
	await _test_input_ownership_and_refusal()
	_check(root.get_child_count() == 0, "All isolated construction queue input fixtures are removed")
	print("CONSTRUCTION_QUEUE_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture() -> Dictionary:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	var core: MotherCore = CORE_SCENE.instantiate() as MotherCore
	world.add_child(core)
	core.global_position = Vector2(150, 430)
	var first: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	world.add_child(first)
	first.global_position = Vector2(500, 450)
	var second: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	world.add_child(second)
	second.global_position = Vector2(630, 560)
	var capabilities: ColonyCapabilities = ColonyCapabilities.new()
	world.add_child(capabilities)
	var queue: ConstructionQueue = ConstructionQueue.new()
	queue.capabilities = capabilities
	world.add_child(queue)
	var coordinator: InputSpyCoordinator = InputSpyCoordinator.new()
	coordinator.queue = queue
	coordinator.mother_core = core
	coordinator.auto_execute = false
	world.add_child(coordinator)
	var markers: Node2D = Node2D.new()
	markers.position = Vector2(71, -39)
	markers.rotation = 0.13
	markers.scale = Vector2(0.8, 1.2)
	world.add_child(markers)
	var hud: CanvasLayer = CanvasLayer.new()
	world.add_child(hud)
	var controller: ConstructionQueueController = CONTROLLER_SCENE.instantiate() as ConstructionQueueController
	controller.coordinator = coordinator
	controller.marker_container = markers
	hud.add_child(controller)
	return {"world": world, "core": core, "first": first, "second": second,
		"queue": queue, "coordinator": coordinator, "markers": markers, "controller": controller}


func _enqueue_three(fixture: Dictionary) -> Array[String]:
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var core: MotherCore = fixture["core"] as MotherCore
	var requests: Array[Dictionary] = [
		{"kind": &"growth", "parameters": {"start_node": core, "target_position": Vector2(740, 350)}},
		{"kind": &"remote_cultivation", "parameters": {
			"start_node": fixture["first"], "target_position": Vector2(900, 490)}},
		{"kind": &"connection", "parameters": {"first_node": fixture["first"], "second_node": fixture["second"]}},
	]
	var ids: Array[String] = []
	for request: Dictionary in requests:
		var result: Dictionary = queue.enqueue(request["kind"], request["parameters"], core)
		_check(bool(result.get("accepted", false)) and not String(result.get("construction_id", "")).is_empty(),
			"Input fixture accepts a distinct unstarted queue request: " + String(request["kind"]))
		ids.append(String(result.get("construction_id", "")))
	return ids


func _dispose(fixture: Dictionary) -> void:
	(fixture["world"] as Node2D).free()


func _key(key: Key, pressed: bool = true, echo: bool = false) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	event.echo = echo
	return event


func _action(action: StringName) -> InputEventAction:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = true
	return event


func _click(viewport_position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.position = viewport_position
	event.pressed = true
	return event


func _row(controller: ConstructionQueueController, index: int) -> Button:
	return controller.get_node("Panel/Row%d" % (index + 1)) as Button


func _button(controller: ConstructionQueueController, button_name: String) -> Button:
	return controller.get_node("Panel/Actions/" + button_name) as Button


func _title(controller: ConstructionQueueController) -> Label:
	return controller.get_node("Panel/TitleLabel") as Label


func _last_call_is(coordinator: InputSpyCoordinator, operation: StringName, construction_id: String) -> bool:
	if coordinator.calls.is_empty():
		return false
	var call: Dictionary = coordinator.calls.back()
	return call.get("operation") == operation and String(call.get("construction_id", "")) == construction_id


func _count_nodes(node: Node) -> int:
	var count: int = 1
	for child: Node in node.get_children():
		count += _count_nodes(child)
	return count


func _test_configuration_guard() -> void:
	var controller: ConstructionQueueController = CONTROLLER_SCENE.instantiate() as ConstructionQueueController
	root.add_child(controller)
	controller.refresh()
	_check(not controller.select_request("missing") and not controller.select_request("")
		and not controller.move_selected(-1) and not controller.pause_selected()
		and not controller.resume_selected() and not controller.cancel_selected(),
		"Missing coordinator safely rejects every explicit operation")
	_check(not controller.handle_input(_key(KEY_P)) and not controller.handle_input(_key(KEY_X))
		and not controller.handle_input(_click(Vector2(900, 490))),
		"Unconfigured panel never claims task commands or a map identity")
	for index: int in range(3):
		_check(_row(controller, index).disabled, "Unconfigured row remains a static disabled slot")
	for button_name: String in ["MoveUp", "MoveDown", "Pause", "Resume", "Cancel"]:
		_check(_button(controller, button_name).disabled, "Unconfigured shared control is disabled: " + button_name)
	controller.free()


func _test_static_rows_and_identity() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var core: MotherCore = fixture["core"] as MotherCore
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var original_balance: int = core.nutrition
	var node_count: int = _count_nodes(fixture["world"])
	var ids: Array[String] = _enqueue_three(fixture)
	_check(controller.position == Vector2(408, 64) and controller.size == Vector2(380, 160)
		and controller.get_global_rect().end.y == 224.0,
		"Fixed queue panel fits the top center above the map at y230")
	var types: Array[String] = ["延伸菌路", "远处攻击芽", "连接菌结"]
	for index: int in range(3):
		var entry: Dictionary = queue.get_request(ids[index])
		var row: Button = _row(controller, index)
		_check(not row.disabled and row.text.contains("%d. #%d" % [index + 1, int(entry["sequence"])])
			and row.text.contains(types[index]) and row.text.contains("等待") and row.text.contains("原因："),
			"Every static row displays order, permanent sequence, type, state, and reason")
		_check(row.tooltip_text.contains(ids[index]), "Row exposes its exact construction identity")
	_check(_title(controller).text.contains("已选 #%d" % int(queue.get_request(ids[2])["sequence"]))
		and _title(controller).tooltip_text.contains(ids[2]),
		"Successful enqueue displays the explicitly selected request identity")
	var extra: Dictionary = queue.enqueue(&"growth", {"start_node": core, "target_position": Vector2(980, 320)}, core)
	_check(not bool(extra.get("accepted", false)) and _count_nodes(fixture["world"]) == node_count
		and core.nutrition == original_balance and (fixture["markers"] as Node2D).get_child_count() == 0,
		"Queue presentation and rejected fourth request create no gameplay markers or nutrition debit")
	_dispose(fixture)


func _test_selected_commands_and_no_fallback() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var coordinator: InputSpyCoordinator = fixture["coordinator"] as InputSpyCoordinator
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var core: MotherCore = fixture["core"] as MotherCore
	var original_balance: int = core.nutrition
	var ids: Array[String] = _enqueue_three(fixture)
	_row(controller, 0).pressed.emit()
	_check(String(queue.get_snapshot().get("selected_id", "")) == ids[0]
		and _last_call_is(coordinator, &"select", ids[0]), "Row click selects its explicit ID rather than newest request")
	_check(controller.handle_input(_key(KEY_P)) and queue.get_request(ids[0])["state"] == &"paused"
		and _last_call_is(coordinator, &"pause", ids[0]), "P pauses exactly the selected request through coordinator")
	_check(queue.get_request(ids[1])["state"] == &"waiting" and queue.get_request(ids[2])["state"] == &"waiting",
		"P leaves both other request identities unchanged")
	_check(controller.handle_input(_key(KEY_P)) and queue.get_request(ids[0])["state"] == &"waiting"
		and _last_call_is(coordinator, &"resume", ids[0]), "P resumes the same selected identity")
	_check(controller.handle_input(_action(&"growth_pause")) and queue.get_request(ids[0])["state"] == &"paused",
		"Existing formal pause action reaches the same explicit queue operation")
	_check(controller.handle_input(_action(&"growth_cancel")) and queue.get_request(ids[0])["state"] == &"cancelled"
		and _last_call_is(coordinator, &"cancel", ids[0]), "X action cancels only the selected request")
	var call_count: int = coordinator.calls.size()
	_check(String(queue.get_snapshot().get("selected_id", "")).is_empty()
		and not controller.handle_input(_key(KEY_P)) and not controller.handle_input(_key(KEY_X))
		and not controller.pause_selected() and not controller.resume_selected() and not controller.cancel_selected(),
		"Cancelling selected request clears ownership and all subsequent unselected commands return false")
	_check(coordinator.calls.size() == call_count and queue.get_request(ids[1])["state"] == &"waiting"
		and queue.get_request(ids[2])["state"] == &"waiting" and core.nutrition == original_balance,
		"No selection never falls back to the last created object or charges unpaid work")
	_check(not controller.select_request(ids[0]) and not controller.select_request("unknown-id"),
		"Terminal and unknown IDs cannot become active UI targets")
	_dispose(fixture)


func _test_reordering_and_shared_buttons() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var coordinator: InputSpyCoordinator = fixture["coordinator"] as InputSpyCoordinator
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var ids: Array[String] = _enqueue_three(fixture)
	var sequence: int = int(queue.get_request(ids[1])["sequence"])
	_row(controller, 1).pressed.emit()
	_button(controller, "MoveUp").pressed.emit()
	var entries: Array = queue.get_snapshot()["entries"]
	_check(String(entries[0]["construction_id"]) == ids[1] and _last_call_is(coordinator, &"move", ids[1])
		and int(coordinator.calls.back()["direction"]) == -1,
		"Shared Up control moves only the currently selected unstarted identity")
	_check(int(queue.get_request(ids[1])["sequence"]) == sequence
		and _row(controller, 0).text.contains("1. #%d" % sequence),
		"Reordering changes order while retaining the permanent map/list sequence")
	_button(controller, "MoveDown").pressed.emit()
	entries = queue.get_snapshot()["entries"]
	_check(String(entries[1]["construction_id"]) == ids[1] and int(coordinator.calls.back()["direction"]) == 1,
		"Shared Down control preserves the exact selected request ID")
	_button(controller, "Pause").pressed.emit()
	_check(queue.get_request(ids[1])["state"] == &"paused" and _button(controller, "Pause").disabled
		and not _button(controller, "Resume").disabled, "Shared pause control refreshes authoritative paused state")
	_check(controller.move_selected(-1), "A paused but unstarted request remains explicitly reorderable")
	_row(controller, 1).pressed.emit()
	_check(String(queue.get_snapshot()["selected_id"]) == ids[0],
		"Static row callback reads its current ID after reordering")
	controller.select_request(ids[1])
	_button(controller, "Resume").pressed.emit()
	_check(queue.get_request(ids[1])["state"] == &"waiting" and _last_call_is(coordinator, &"resume", ids[1]),
		"Shared resume control addresses the selected paused request")
	var call_count: int = coordinator.calls.size()
	_check(not controller.move_selected(0) and not controller.move_selected(2)
		and coordinator.calls.size() == call_count, "Invalid reorder directions never reach coordinator")
	_button(controller, "Cancel").pressed.emit()
	_check(queue.get_request(ids[1])["state"] == &"cancelled" and _last_call_is(coordinator, &"cancel", ids[1])
		and _button(controller, "Cancel").disabled, "Shared cancel control clears its own selected identity")
	_dispose(fixture)


func _test_explicit_clear_selection() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var coordinator: InputSpyCoordinator = fixture["coordinator"] as InputSpyCoordinator
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var ids: Array[String] = _enqueue_three(fixture)
	controller.select_request(ids[1])
	var entries_before: Array = queue.get_snapshot()["entries"]
	_check(controller.select_request("") and _last_call_is(coordinator, &"select", "")
		and String(queue.get_snapshot()["selected_id"]).is_empty(), "Empty explicit ID clears only queue selection")
	_check(queue.get_snapshot()["entries"] == entries_before and _title(controller).text.contains("未选择")
		and not _title(controller).tooltip_text.contains(ids[1]),
		"Clearing selection preserves request order/state and clears visible target identity")
	var call_count: int = coordinator.calls.size()
	_check(not controller.handle_input(_key(KEY_P)) and not controller.handle_input(_key(KEY_X))
		and coordinator.calls.size() == call_count, "Explicit deselection yields command ownership to the level")
	_check(controller.select_request(ids[0]) and not controller.select_request("not-an-active-id")
		and String(queue.get_snapshot()["selected_id"]) == ids[0],
		"Invalid nonempty selection never substitutes another identity")
	_dispose(fixture)


func _test_map_selection_and_canvas_transform() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var markers: Node2D = fixture["markers"] as Node2D
	var first: HyphaNode = fixture["first"] as HyphaNode
	var second: HyphaNode = fixture["second"] as HyphaNode
	var ids: Array[String] = _enqueue_three(fixture)
	var saved_canvas: Transform2D = root.canvas_transform
	root.canvas_transform = Transform2D(Vector2(1.1, 0.04), Vector2(-0.03, 0.9), Vector2(35, 22))
	var growth_point: Vector2 = markers.get_canvas_transform() * Vector2(740, 350)
	_check(controller.handle_input(_click(growth_point)) and String(queue.get_snapshot()["selected_id"]) == ids[0],
		"Map marker selection respects canvas transform and avoids double applying marker container origin")
	_check(_row(controller, 0).text.begins_with("▶ ") and _title(controller).tooltip_text.contains(ids[0]),
		"Map selection highlights the same row and construction identity")
	var remote_point: Vector2 = markers.get_canvas_transform() * Vector2(900, 490)
	_check(controller.handle_input(_click(remote_point)) and String(queue.get_snapshot()["selected_id"]) == ids[1],
		"Remote marker selects its own queued request identity")
	var connection_point: Vector2 = markers.get_canvas_transform() * first.global_position.lerp(second.global_position, 0.5)
	_check(controller.handle_input(_click(connection_point)) and String(queue.get_snapshot()["selected_id"]) == ids[2],
		"Connection midpoint marker retains the explicit endpoint-pair request identity")
	first.global_position += Vector2(100, 0)
	second.global_position += Vector2(100, 0)
	controller.select_request(ids[0])
	var moved_point: Vector2 = markers.get_canvas_transform() * first.global_position.lerp(second.global_position, 0.5)
	_check(not controller.handle_input(_click(connection_point)) and controller.handle_input(_click(moved_point))
		and String(queue.get_snapshot()["selected_id"]) == ids[2],
		"Live connection endpoints update marker geometry without changing request ID")
	var panel_point: Vector2 = controller.get_global_rect().get_center()
	_check(controller.is_pointer_over_panel(panel_point)
		and not controller.is_pointer_over_panel(Vector2(407, 64))
		and not controller.is_pointer_over_panel(Vector2(NAN, 64)),
		"GUI point exclusion uses the actual panel rectangle and rejects nonfinite points")
	_check(not controller.handle_input(_click(panel_point)) and not controller.handle_input(_click(remote_point, MOUSE_BUTTON_RIGHT))
		and not controller.handle_input(_click(Vector2(NAN, 500))),
		"Panel clicks, right clicks, and nonfinite map clicks cannot select or operate markers")
	second.free()
	controller.select_request(ids[0])
	_check(not controller.handle_input(_click(moved_point)) and String(queue.get_snapshot()["selected_id"]) == ids[0],
		"Deleted connection endpoint leaves no selectable stale marker")
	root.canvas_transform = saved_canvas
	_dispose(fixture)


func _test_terminal_and_reset_refresh() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var ids: Array[String] = _enqueue_three(fixture)
	controller.select_request(ids[1])
	queue.cancel_request(ids[1])
	_check(_title(controller).text.contains("未选择") and _row(controller, 2).disabled
		and _row(controller, 0).tooltip_text.contains(ids[0]) and _row(controller, 1).tooltip_text.contains(ids[2]),
		"External terminal signal removes only that row and clears the current target")
	queue.reset()
	for index: int in range(3):
		_check(_row(controller, index).disabled and _row(controller, index).tooltip_text.is_empty(),
			"Reset retains each static row while clearing its identity")
	_check(not controller.handle_input(_key(KEY_P)) and not controller.handle_input(_key(KEY_X))
		and not controller.handle_input(_click(Vector2(740, 350))),
		"Reset leaves no stale command owner or selectable map identity")
	controller.coordinator = null
	controller.refresh()
	_check(not controller.pause_selected() and not controller.cancel_selected(),
		"Detached coordinator safely clears controls and explicit selection")
	_dispose(fixture)


func _test_input_ownership_and_refusal() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"] as ConstructionQueue
	var coordinator: InputSpyCoordinator = fixture["coordinator"] as InputSpyCoordinator
	var controller: ConstructionQueueController = fixture["controller"] as ConstructionQueueController
	var ids: Array[String] = _enqueue_three(fixture)
	controller.select_request(ids[1])
	var call_count: int = coordinator.calls.size()
	root.push_input(_key(KEY_P))
	root.push_input(_key(KEY_P, false))
	await process_frame
	_check(coordinator.calls.size() == call_count and queue.get_request(ids[1])["state"] == &"waiting",
		"Queue controller alone has no global input callback and does not duplicate level forwarding")
	coordinator.refuse_commands = true
	coordinator.presented_started_id = ids[1]
	controller.refresh()
	_check(_button(controller, "MoveUp").disabled and _button(controller, "MoveDown").disabled
		and not controller.move_selected(-1), "An executing selected request cannot be reordered by the UI")
	_check(controller.handle_input(_key(KEY_P)) and _last_call_is(coordinator, &"pause", ids[1]),
		"Rejected active pause remains consumed and routes only to the explicitly selected coordinator ID")
	_check(controller.handle_input(_key(KEY_X)) and _last_call_is(coordinator, &"cancel", ids[1])
		and queue.get_request(ids[0])["state"] == &"waiting" and queue.get_request(ids[2])["state"] == &"waiting",
		"Rejected active cancel never falls through to either other construction identity")
	call_count = coordinator.calls.size()
	var modified: InputEventKey = _key(KEY_P)
	modified.ctrl_pressed = true
	_check(not controller.handle_input(_key(KEY_P, true, true)) and not controller.handle_input(_key(KEY_X, false))
		and not controller.handle_input(modified) and not controller.handle_input(_key(KEY_F))
		and not controller.handle_input(_action(&"repair_pause"))
		and not controller.handle_input(InputEventMouseMotion.new()) and coordinator.calls.size() == call_count,
		"Echo, releases, modified shortcuts, unrelated actions, and motion preserve task identity")
	_dispose(fixture)
