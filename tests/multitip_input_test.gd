extends "res://tests/construction_queue_input_test.gd"
## 隔离的界面测试：使用真实队列与假执行器数据，只验证成熟列表/目标路由。
## 双尖端与付款的真实性由 multitip_construction_test 单独验证。


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_test_maturing_selector_and_identity()
	_check(root.get_child_count() == 0, "Multi-task UI fixtures leave no scene objects")
	print("MULTITIP_INPUT_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _test_maturing_selector_and_identity() -> void:
	var fixture: Dictionary = _fixture()
	var queue: ConstructionQueue = fixture["queue"]
	var coordinator: InputSpyCoordinator = fixture["coordinator"]
	var controller: ConstructionQueueController = fixture["controller"]
	var core: MotherCore = fixture["core"]
	var before: int = core.nutrition
	queue.multi_execution = true
	coordinator.multi_worker_enabled = true
	var ids: Array[String] = _enqueue_three(fixture)
	var generation: int = queue.get_generation()
	_check(queue._coordinator_start(ids[1], generation), "UI fixture represents an extending remote target")
	var internal: Dictionary = {"growth_task_id": 1, "remote_request_id": 1, "cultivation_task_id": 1}
	_check(queue._coordinator_release_tip(ids[1], generation,
		{"progress": 0.25, "endpoint": fixture["first"]}, internal), "UI fixture moves the same identity to maturing")
	var local: Dictionary = queue._coordinator_enqueue_cultivation(fixture["second"], core)
	_check(bool(local["accepted"]) and queue._coordinator_start_local(String(local["construction_id"]), generation),
		"Local C has an independently selectable maturing row")
	var fourth: Dictionary = queue.enqueue(&"growth", {
		"start_node": core, "target_position": Vector2(950, 350)}, core)
	_check(bool(fourth["accepted"]) and queue.get_snapshot()["external_count"] == 3
		and queue.get_snapshot()["maturing_count"] == 2 and queue.get_snapshot()["tip_count"] == 0,
		"Maturing rows do not hide or consume the three external slots")
	controller.refresh()
	var selector: OptionButton = controller.get_node("Panel/Maturing") as OptionButton
	_check(selector.visible and not selector.disabled and selector.item_count == 3,
		"Maturity dropdown exposes both active maturation requests plus its summary")
	_check(_title(controller).text.contains("目标 3/3") and _title(controller).text.contains("尖端 0/1"),
		"Title distinguishes target count and actual extension slot count")
	var index: int = -1
	for item: int in range(selector.item_count):
		if selector.get_item_metadata(item) == ids[1]:
			index = item
	_check(index > 0 and selector.get_item_text(index).contains("#2")
		and selector.get_item_text(index).contains("25%"), "Maturity entry preserves permanent ID and its own progress")
	selector.item_selected.emit(index)
	_check(queue.get_snapshot()["selected_id"] == ids[1]
		and _button(controller, "MoveUp").disabled and _button(controller, "MoveDown").disabled
		and not _button(controller, "Pause").disabled,
		"Selecting a maturing request enables its own controls without external reordering")
	coordinator.refuse_commands = true
	_check(controller.handle_input(_action(&"growth_pause"))
		and _last_call_is(coordinator, &"pause", ids[1]), "P sends the maturing ID and consumes refusal without fallback")
	_check(controller.handle_input(_action(&"growth_cancel"))
		and _last_call_is(coordinator, &"cancel", ids[1]), "X cannot switch from selected maturity to an extending row")
	coordinator.refuse_commands = false
	var host: HyphaNode = fixture["second"]
	var markers: Node2D = fixture["markers"]
	var point: Vector2 = markers.get_global_transform_with_canvas() * markers.to_local(host.global_position)
	_check(controller.handle_input(_click(point))
		and queue.get_snapshot()["selected_id"] == local["construction_id"],
		"The local C map marker selects the corresponding maturity list identity")
	queue._coordinator_finish(String(local["construction_id"]), generation, &"completed", &"", {})
	controller.refresh()
	_check(queue.get_snapshot()["selected_id"] == "" and _button(controller, "Pause").disabled
		and _button(controller, "Cancel").disabled and selector.item_count == 2,
		"Completing selected maturity removes its row and leaves no automatic control target")
	_check(core.nutrition == before, "Displaying and selecting all multi-task states never changes nutrition")
	queue.reset()
	controller.refresh()
	_check(selector.disabled and queue.get_snapshot()["maturing_count"] == 0
		and queue.get_snapshot()["tip_count"] == 0, "Reset empties maturity selector and tip count")
	_dispose(fixture)
