extends SceneTree
## 两具真实 80 单位尸骸经采集、消化和绿色回流推进成长；不伪造首次抵达。
## 只关闭无关自动派送，以逐份检查阶段、显示和能力；原速度、费用与容量不变。

const DEMO: PackedScene = preload("res://scenes/levels/traffic_recovery_demo.tscn")
const CARCASS: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const FRAME_LIMIT: int = 1800

var checks: int = 0
var failures: Array[String] = []
var milestones: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	if OS.get_cmdline_user_args().has("--capture-stage-ui"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await _test_real_recovery_and_restart()
	_check(root.get_child_count() == 0, "All integration fixtures are removed")
	print("PROGRESSION_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "milestones": milestones,
		"first_arrivals_fabricated": false, "motion": "real_engine_physics_frames",
		"carcasses": 2, "nutrition_per_carcass": 80,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _quiet(level: Node2D) -> void:
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.growth_supply_system.auto_supply = false
	level.cultivation_supply_system.auto_supply = false
	level.repair_supply_system.auto_supply = false
	level.nutrition_return_system.auto_return = false
	level.nutrition_return_system.get_node("DispatchTimer").stop()
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _until(predicate: Callable, message: String) -> bool:
	for _frame: int in range(FRAME_LIMIT):
		if predicate.call():
			break
		await physics_frame
		await process_frame
	var reached: bool = bool(predicate.call())
	_check(reached, message)
	return reached


func _check_stage(level: Node2D, total: int, stage: ColonyProgress.Stage,
		stage_name: String, threshold: int) -> void:
	_check(level.colony_progress.get_total_recovered() == total
		and level.colony_progress.get_stage() == stage,
		"Formal scene progress and stage reflect only arrived recovery at %d" % total)
	_check(level.colony_progress.get_next_stage_threshold() == threshold,
		"Formal scene exposes the next threshold at %d" % total)
	var label: Label = level.hud.stage_label
	_check(label.text.contains("成长：" + stage_name)
		and label.text.contains("累计回收 %d" % total), "HUD displays stage and total at %d" % total)
	_check(label.text.contains("已达最终阶段") if threshold == 0 else
		label.text.contains("下一门槛 %d（还差 %d）" % [threshold, threshold - total]),
		"HUD displays the next threshold or final-stage state at %d" % total)
	_check(level.colony_capabilities.colony_progress == level.colony_progress,
		"Scene capability queries use the one existing progress object")
	_check(level.colony_capabilities.get_external_target_limit() == 3
		and level.colony_capabilities.get_extension_tip_limit() == (
			1 if stage == ColonyProgress.Stage.NASCENT else 2)
		and level.colony_capabilities.can_expand_second_digestive_chamber() == (
			stage == ColonyProgress.Stage.MATURE), "Scene capability rules match the current stage")


func _dispose(level: Node2D) -> void:
	current_scene = null
	level.queue_free()
	await process_frame
	await process_frame


func _capture_stage(total: int) -> void:
	if not OS.get_cmdline_user_args().has("--capture-stage-ui"):
		return
	await RenderingServer.frame_post_draw
	var directory: String = "/tmp/fungi_stage7_round1/visual"
	DirAccess.make_dir_recursive_absolute(directory)
	var result: Error = root.get_texture().get_image().save_png(
		directory.path_join("stage_%d.png" % total))
	_check(result == OK, "Rendered growth HUD capture saved")


func _test_real_recovery_and_restart() -> void:
	var level: Node2D = DEMO.instantiate() as Node2D
	level.get_node("Systems/NutritionReturnSystem").auto_return = false
	root.add_child(level)
	current_scene = level
	_quiet(level)
	await physics_frame
	await process_frame
	level.fungal_field.advance(1.0)
	_check(level.mother_core.nutrition == 72, "Original initial balance remains 72")
	_check_stage(level, 0, ColonyProgress.Stage.NASCENT, "初生", 60)
	await _capture_stage(0)
	var unlocks: Array[int] = []
	var transitions: Array[Vector2i] = []
	level.colony_progress.stage_unlocked.connect(func(stage: ColonyProgress.Stage) -> void:
		unlocks.append(stage))
	level.colony_progress.stage_changed.connect(func(before: ColonyProgress.Stage,
			after: ColonyProgress.Stage) -> void:
		transitions.append(Vector2i(before, after)))
	# 第二具尸骸是明示的外部资源夹具，使用默认 80 总量和 10 单位批次。
	var second: LargeCarcass = CARCASS.instantiate() as LargeCarcass
	second.position = Vector2(1120, 455)
	level.get_node("World/Remains").add_child(second)
	var old_callback: Callable = level.mother_core.get_signal_connection_list(
		&"digestion_product_arrived")[0]["callable"]
	for batch: int in range(1, 17):
		var before_total: int = (batch - 1) * 10
		var before_stage: ColonyProgress.Stage = level.colony_progress.get_stage()
		_check(level.recycling_system.try_dispatch(), "Real carcass dispatch %d succeeds" % batch)
		if not await _until(func() -> bool:
			return level.digestive_organ.get_output_count() == 1,
			"Physical haul and normal digestion produce batch %d" % batch):
			await _dispose(level)
			return
		_check(level.colony_progress.get_total_recovered() == before_total
			and level.colony_progress.get_stage() == before_stage,
			"Collection and digestion alone cannot advance growth")
		var product: Dictionary = level.digestive_organ.get_output_products()[0]
		var product_id: String = product["product_id"]
		_check(int(product["nutrition"]) == 10, "Original carcass batch size is preserved")
		_check(level.nutrition_return_system.try_dispatch(), "Real green return dispatch succeeds")
		for _frame: int in range(6):
			await physics_frame
			await process_frame
		_check(level.nutrition_return_system.get_in_transit_count() == 1
			and level.colony_progress.get_total_recovered() == before_total
			and level.colony_progress.get_stage() == before_stage,
			"In-flight nutrition cannot advance growth before core arrival")
		if not await _until(func() -> bool:
			return level.colony_progress.get_total_recovered() == batch * 10,
			"Real green physics packet arrives once for batch %d" % batch):
			await _dispose(level)
			return
		var total: int = batch * 10
		var expected_stage: ColonyProgress.Stage = ColonyProgress.Stage.NASCENT
		var expected_name: String = "初生"
		var next_threshold: int = 60
		if total >= 160:
			expected_stage = ColonyProgress.Stage.MATURE
			expected_name = "成熟"
			next_threshold = 0
		elif total >= 60:
			expected_stage = ColonyProgress.Stage.EXPANDED
			expected_name = "展开"
			next_threshold = 160
		_check_stage(level, total, expected_stage, expected_name, next_threshold)
		_check(level.mother_core.nutrition == 72 + total
			and level.mother_core.get_received_product_count() == batch,
			"Stage observation neither credits extra income nor changes the original balance")
		_check(not level.mother_core.accept_digestion_product(product_id, 10),
			"Replaying an actually received product cannot credit it again")
		old_callback.call(product_id, 999)
		_check(level.colony_progress.get_total_recovered() == total
			and level.colony_progress.get_product_count() == batch,
			"Duplicate observed arrival with another amount cannot advance progress")
		if total in [50, 60, 150, 160]:
			milestones.append({"total": total, "stage": expected_name, "hud": level.hud.stage_label.text,
				"balance": level.mother_core.nutrition, "unlocks": unlocks.duplicate()})
		if total in [60, 160]:
			await _capture_stage(total)
	_check(unlocks == [ColonyProgress.Stage.EXPANDED, ColonyProgress.Stage.MATURE]
		and transitions == [Vector2i(0, 1), Vector2i(1, 2)],
		"The two real thresholds each emit exactly one transition and unlock")
	_check(level.get_node("World/GrowthTips").get_child_count() == 0
		and level.digestive_organ.capacity == 4,
		"Read-only unlocks create no tips and do not alter the existing stomach")
	_check(level.mother_core.try_spend_nutrition(200), "Spend recovered balance through the original core")
	level.mother_core.add_nutrition(200)
	level.primary_edge.take_damage(35.0)
	_check_stage(level, 160, ColonyProgress.Stage.MATURE, "成熟", 0)
	_check(unlocks.size() == 2, "Spending, refunds and structural damage cannot unlock again")
	var reset_evidence: Dictionary = {"old_callback_rejected": false}
	level.colony_progress.progress_changed.connect(func(total: int, _count: int) -> void:
		if total == 0:
			old_callback.call("retired_before_scene_free", 160)
			reset_evidence["old_callback_rejected"] = (level.colony_progress.get_total_recovered() == 0
				and level.colony_progress.get_stage() == ColonyProgress.Stage.NASCENT))
	var restart: InputEventKey = InputEventKey.new()
	restart.keycode = KEY_R
	restart.pressed = true
	root.push_input(restart)
	for _frame: int in range(4):
		await process_frame
	var fresh: Node2D = current_scene as Node2D
	_check(is_instance_valid(fresh) and fresh != level, "Actual R input replaces the old scene")
	_check(bool(reset_evidence["old_callback_rejected"]), "R invalidates old callbacks before scene disposal")
	if is_instance_valid(fresh):
		_quiet(fresh)
		_check_stage(fresh, 0, ColonyProgress.Stage.NASCENT, "初生", 60)
		_check(fresh.mother_core.nutrition == 72 and fresh.colony_progress.get_product_count() == 0,
			"Fresh run restores original balance, zero recovery and no product IDs")
		await _dispose(fresh)
