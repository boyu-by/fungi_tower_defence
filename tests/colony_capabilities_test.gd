extends SceneTree
## 能力查询验收；收件夹具只模拟 MotherCore 的到达结算边界，不验证物理运输。
## 独立 SceneTree 验收脚本，由主代理统一运行。

const PROGRESS_SCRIPT: GDScript = preload("res://scripts/colony_progress.gd")
const CAPABILITIES_SCRIPT: GDScript = preload("res://scripts/colony_capabilities.gd")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_boundaries_and_read_only_queries()
	_test_reset_is_immediate()
	_test_missing_dependency_and_replacement()
	_test_freed_dependency_and_replacement()
	await _test_queued_dependency_and_replacement()
	print("COLONY_CAPABILITIES_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_progress() -> ColonyProgress:
	return PROGRESS_SCRIPT.new() as ColonyProgress


func _new_core(initial_nutrition: int = 72) -> MotherCore:
	var core := CORE_SCENE.instantiate() as MotherCore
	core.initial_nutrition = initial_nutrition
	root.add_child(core)
	return core


func _new_capabilities(progress: ColonyProgress = null) -> ColonyCapabilities:
	var capabilities := CAPABILITIES_SCRIPT.new() as ColonyCapabilities
	capabilities.colony_progress = progress
	return capabilities


func _observe(progress: ColonyProgress) -> Array[String]:
	var events: Array[String] = []
	progress.progress_changed.connect(func(total: int, count: int) -> void:
		events.append("p:%d:%d" % [total, count])
	)
	progress.stage_changed.connect(func(previous: ColonyProgress.Stage, current: ColonyProgress.Stage) -> void:
		events.append("s:%d:%d" % [previous, current])
	)
	progress.stage_unlocked.connect(func(stage: ColonyProgress.Stage) -> void:
		events.append("u:%d" % stage)
	)
	return events


func _check_values(
	capabilities: ColonyCapabilities, expected_tips: int, expected_chamber: bool, context: String
) -> void:
	_check(capabilities.get_external_target_limit() == 3, context + ": external target limit remains three")
	_check(capabilities.get_extension_tip_limit() == expected_tips, context + ": extension tip limit")
	_check(capabilities.can_expand_second_digestive_chamber() == expected_chamber,
		context + ": second digestive chamber capability")


func _check_read_only_queries(
	capabilities: ColonyCapabilities, progress: ColonyProgress, core: MotherCore,
	events: Array[String], expected_tips: int, expected_chamber: bool, context: String
) -> void:
	var total_before: int = progress.get_total_recovered()
	var count_before: int = progress.get_product_count()
	var stage_before: ColonyProgress.Stage = progress.get_stage()
	var threshold_before: int = progress.get_next_stage_threshold()
	var label_before: String = progress.get_stage_name()
	var balance_before: int = core.nutrition
	var health_before: int = core.health
	var receipts_before: int = core.get_received_product_count()
	var budget_before: Dictionary = core.get_budget_snapshot()
	var events_before: Array[String] = events.duplicate()
	for index: int in range(8):
		_check_values(capabilities, expected_tips, expected_chamber, context + " query %d" % index)
	_check(progress.get_total_recovered() == total_before and progress.get_product_count() == count_before,
		context + ": queries changed cumulative recovery or receipt count")
	_check(progress.get_stage() == stage_before and progress.get_next_stage_threshold() == threshold_before
		and progress.get_stage_name() == label_before, context + ": queries changed progress stage metadata")
	_check(core.nutrition == balance_before and core.health == health_before
		and core.get_received_product_count() == receipts_before and core.get_budget_snapshot() == budget_before,
		context + ": queries changed core balance, receipts, health, or reservations")
	_check(events == events_before, context + ": queries emitted progress, stage, or unlock events")


func _test_boundaries_and_read_only_queries() -> void:
	var progress := _new_progress()
	var core := _new_core()
	var capabilities := _new_capabilities(progress)
	var events := _observe(progress)
	_check(progress.register_source(core), "Capabilities boundary source registration")
	_check(progress.get_total_recovered() == 0 and core.nutrition == 72, "Initial balance receipt exclusion fixture")
	_check_read_only_queries(capabilities, progress, core, events, 1, false, "At zero")
	_check(core.accept_digestion_product("capability:59", 59), "Capabilities receipt reaching 59")
	_check(progress.get_stage() == ColonyProgress.Stage.NASCENT, "Progress stage at 59")
	_check_read_only_queries(capabilities, progress, core, events, 1, false, "At 59")
	_check(core.accept_digestion_product("capability:60", 1), "Capabilities receipt reaching 60")
	_check(progress.get_stage() == ColonyProgress.Stage.EXPANDED, "Progress stage at 60")
	_check_read_only_queries(capabilities, progress, core, events, 2, false, "At 60")
	_check(core.accept_digestion_product("capability:159", 99), "Capabilities receipt reaching 159")
	_check_read_only_queries(capabilities, progress, core, events, 2, false, "At 159")
	_check(core.accept_digestion_product("capability:160", 1), "Capabilities receipt reaching 160")
	_check(progress.get_stage() == ColonyProgress.Stage.MATURE, "Progress stage at 160")
	_check_read_only_queries(capabilities, progress, core, events, 2, true, "At 160")
	_check(core.accept_digestion_product("capability:161", 1), "Capabilities receipt after maturity")
	_check_read_only_queries(capabilities, progress, core, events, 2, true, "At 161")
	_check(progress.get_total_recovered() == 161 and progress.get_product_count() == 5,
		"Capabilities boundary receipts retained cumulative recovery and unique count")
	_check(core.nutrition == 72 + 161, "Capability observer changed true receipt credits")
	_check(events == [
		"p:59:1", "p:60:2", "s:0:1", "u:1", "p:159:3",
		"p:160:4", "s:1:2", "u:2", "p:161:5",
	], "Capabilities queries added or removed progression notifications")
	for product_id: String in ["capability:59", "capability:60", "capability:159", "capability:160", "capability:161"]:
		_check(progress.has_product(product_id), "Read-only queries lost receipt ID " + product_id)
	_check(core.try_spend_nutrition(core.get_spendable_nutrition()), "Spend capability fixture balance")
	core.take_damage(5)
	_check_read_only_queries(capabilities, progress, core, events, 2, true, "After spending and damage")
	_check(progress.get_stage() == ColonyProgress.Stage.MATURE, "Spending or damage lowered capability stage")
	capabilities.free()
	progress.free()
	core.free()


func _test_reset_is_immediate() -> void:
	for recovered: int in [60, 160]:
		var progress := _new_progress()
		var core := _new_core(0)
		var capabilities := _new_capabilities(progress)
		var events := _observe(progress)
		_check(progress.register_source(core), "Reset fixture source registration at %d" % recovered)
		_check(core.accept_digestion_product("reset:before", recovered), "Capabilities reset setup at %d" % recovered)
		_check_values(capabilities, 2, recovered >= 160, "Before reset at %d" % recovered)
		events.clear()
		var balance_before: int = core.nutrition
		progress.reset()
		_check_values(capabilities, 1, false, "Immediately after reset at %d" % recovered)
		_check(progress.get_total_recovered() == 0 and progress.get_product_count() == 0
			and progress.get_stage() == ColonyProgress.Stage.NASCENT,
			"Reset did not expose nascent progress immediately at %d" % recovered)
		_check(not progress.has_product("reset:before") and progress.get_next_stage_threshold() == 60,
			"Reset retained receipt IDs or mature threshold at %d" % recovered)
		_check(core.nutrition == balance_before, "Reset changed core balance at %d" % recovered)
		var old_stage: int = 1 if recovered == 60 else 2
		_check(events == ["p:0:0", "s:%d:0" % old_stage], "Capability reset notification sequence at %d" % recovered)
		_check_read_only_queries(capabilities, progress, core, events, 1, false, "Reset queries at %d" % recovered)
		_check(core.accept_digestion_product("reset:unregistered", 160), "Retired source receipt fixture at %d" % recovered)
		_check_values(capabilities, 1, false, "Retired source cannot advance capabilities at %d" % recovered)
		_check(progress.get_total_recovered() == 0 and progress.get_product_count() == 0,
			"Retired source advanced progress after reset at %d" % recovered)
		_check(progress.register_source(core), "Source registration for new capability run at %d" % recovered)
		_check(core.accept_digestion_product("reset:fresh", 160), "Fresh capability receipt at %d" % recovered)
		_check_read_only_queries(capabilities, progress, core, events, 2, true, "Same dependency in new run at %d" % recovered)
		capabilities.free()
		progress.free()
		core.free()


func _test_missing_dependency_and_replacement() -> void:
	var capabilities := _new_capabilities()
	for index: int in range(8):
		_check_values(capabilities, 1, false, "Missing dependency query %d" % index)
	var replacement := _new_progress()
	var core := _new_core(0)
	var events := _observe(replacement)
	_check(replacement.register_source(core), "Missing dependency replacement source registration")
	_check(core.accept_digestion_product("replacement:expanded", 60), "Missing dependency replacement receipt")
	capabilities.colony_progress = replacement
	_check_read_only_queries(capabilities, replacement, core, events, 2, false, "Replacement after missing dependency")
	capabilities.colony_progress = null
	_check_values(capabilities, 1, false, "Dependency explicitly cleared")
	capabilities.colony_progress = replacement
	_check(core.accept_digestion_product("replacement:mature", 100), "Replacement live stage change receipt")
	_check_read_only_queries(capabilities, replacement, core, events, 2, true, "Replacement observed live maturity")
	capabilities.free()
	replacement.free()
	core.free()


func _test_freed_dependency_and_replacement() -> void:
	var progress := _new_progress()
	var core := _new_core(0)
	var events := _observe(progress)
	var capabilities := _new_capabilities(progress)
	_check(progress.register_source(core), "Freed dependency source registration")
	_check(core.accept_digestion_product("freed:mature", 160), "Freed dependency mature setup")
	_check_values(capabilities, 2, true, "Live dependency before free")
	var balance_before: int = core.nutrition
	var events_before: Array[String] = events.duplicate()
	progress.free()
	_check(not is_instance_valid(progress), "Dependency was not freed")
	for index: int in range(8):
		_check_values(capabilities, 1, false, "Freed dependency query %d" % index)
	_check(core.nutrition == balance_before and events == events_before, "Freed dependency fallback changed balance or events")
	var replacement := _new_progress()
	var replacement_core := _new_core(0)
	var replacement_events := _observe(replacement)
	_check(replacement.register_source(replacement_core), "Freed dependency replacement source registration")
	_check(replacement_core.accept_digestion_product("freed:replacement", 60), "Freed dependency replacement receipt")
	capabilities.colony_progress = replacement
	_check_read_only_queries(capabilities, replacement, replacement_core, replacement_events, 2, false,
		"Replacement after freed dependency")
	capabilities.free()
	replacement.free()
	core.free()
	replacement_core.free()


func _test_queued_dependency_and_replacement() -> void:
	var progress := _new_progress()
	root.add_child(progress)
	var core := _new_core(0)
	var events := _observe(progress)
	var capabilities := _new_capabilities(progress)
	_check(progress.register_source(core), "Queued dependency source registration")
	_check(core.accept_digestion_product("queued:mature", 160), "Queued dependency mature setup")
	_check_values(capabilities, 2, true, "Live dependency before queue_free")
	progress.queue_free()
	_check(is_instance_valid(progress) and progress.is_queued_for_deletion(), "Dependency is queued but still valid")
	_check_read_only_queries(capabilities, progress, core, events, 1, false, "Queued dependency before deletion")
	_check(progress.get_stage() == ColonyProgress.Stage.MATURE, "Fallback mutated queued dependency stage")
	var balance_before: int = core.nutrition
	var events_before: Array[String] = events.duplicate()
	await process_frame
	_check(not is_instance_valid(progress), "Queued dependency was not deleted after a frame")
	_check_values(capabilities, 1, false, "Queued dependency after deletion")
	_check(core.nutrition == balance_before and events == events_before, "Queued deletion fallback changed balance or events")
	var replacement := _new_progress()
	var replacement_core := _new_core(0)
	var replacement_events := _observe(replacement)
	_check(replacement.register_source(replacement_core), "Queued dependency replacement source registration")
	_check(replacement_core.accept_digestion_product("queued:replacement", 160), "Queued dependency replacement receipt")
	capabilities.colony_progress = replacement
	_check_read_only_queries(capabilities, replacement, replacement_core, replacement_events, 2, true,
		"Replacement after queued deletion")
	capabilities.free()
	replacement.free()
	core.free()
	replacement_core.free()
