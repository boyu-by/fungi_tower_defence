extends SceneTree
## 阶段验收的收件夹具直接调用 MotherCore 的到达结算接口，不代表物理运输验证。
## 独立 SceneTree 验收脚本，由主代理统一运行。

const PROGRESS_SCRIPT: GDScript = preload("res://scripts/colony_progress.gd")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const ARRIVAL_SIGNAL: StringName = &"digestion_product_arrived"
const MAX_RECOVERED: int = 9223372036854775807

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_boundaries_and_once_only_unlocks()
	_test_single_jump_commits_before_callbacks()
	_test_balance_changes_and_damage_are_excluded()
	_test_reset_and_fresh_run()
	_test_retired_registration_callback()
	for trigger: String in ["progress", "stage", "unlock"]:
		_test_reentrant_arrivals(trigger)
		_test_reset_inside_notification(trigger)
	_test_reset_then_new_arrival_inside_callback()
	_test_reset_inside_reset_notification()
	_test_overflow_rejection()
	print("PROGRESSION_STAGE_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_progress() -> ColonyProgress:
	return PROGRESS_SCRIPT.new() as ColonyProgress


func _new_core(initial_nutrition: int = 0) -> MotherCore:
	var core := CORE_SCENE.instantiate() as MotherCore
	core.initial_nutrition = initial_nutrition
	root.add_child(core)
	return core


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


func _check_state(
	progress: ColonyProgress, total: int, count: int, stage: ColonyProgress.Stage,
	stage_name: String, next_threshold: int, context: String
) -> void:
	_check(progress.get_total_recovered() == total, context + ": cumulative recovery")
	_check(progress.get_product_count() == count, context + ": unique receipt count")
	_check(progress.get_stage() == stage, context + ": stage")
	_check(progress.get_stage_name() == stage_name, context + ": stage label")
	_check(progress.get_next_stage_threshold() == next_threshold, context + ": next threshold")


func _capture_callback(core: MotherCore, context: String) -> Callable:
	var connections: Array[Dictionary] = core.get_signal_connection_list(ARRIVAL_SIGNAL)
	_check(connections.size() == 1, context + ": exactly one arrival subscription")
	if connections.is_empty():
		return Callable()
	var callback: Callable = connections[0]["callable"]
	return callback


func _call_retired(callback: Callable, product_id: String, amount: int) -> void:
	if callback.is_valid():
		callback.call(product_id, amount)


func _test_boundaries_and_once_only_unlocks() -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	_check(progress.register_source(core), "Boundary core registration")
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Initial stage")
	_check(events.is_empty(), "Initial state emitted an unlock")

	_check(core.accept_digestion_product("boundary:59", 59), "Receipt reaching 59")
	_check_state(progress, 59, 1, ColonyProgress.Stage.NASCENT, "初生", 60, "At 59")
	_check(events == ["p:59:1"], "Below 60 emitted a stage event")
	_check(core.accept_digestion_product("boundary:60", 1), "Receipt reaching 60")
	_check_state(progress, 60, 2, ColonyProgress.Stage.EXPANDED, "展开", 160, "At 60")
	_check(events == ["p:59:1", "p:60:2", "s:0:1", "u:1"],
		"59 to 60 did not notify progress, stage, then first unlock")
	_check(core.accept_digestion_product("boundary:159", 99), "Receipt reaching 159")
	_check_state(progress, 159, 3, ColonyProgress.Stage.EXPANDED, "展开", 160, "At 159")
	_check(events == ["p:59:1", "p:60:2", "s:0:1", "u:1", "p:159:3"],
		"Expanded stage unlocked again before 160")
	_check(core.accept_digestion_product("boundary:160", 1), "Receipt reaching 160")
	_check_state(progress, 160, 4, ColonyProgress.Stage.MATURE, "成熟", 0, "At 160")
	_check(core.accept_digestion_product("boundary:161", 1), "Receipt after maturity")
	_check_state(progress, 161, 5, ColonyProgress.Stage.MATURE, "成熟", 0, "After maturity")
	_check(events == [
		"p:59:1", "p:60:2", "s:0:1", "u:1", "p:159:3",
		"p:160:4", "s:1:2", "u:2", "p:161:5",
	], "Stage unlocks were not ordered and once only within a run")

	var prior_events: Array[String] = events.duplicate()
	var prior_balance: int = core.nutrition
	_check(not core.accept_digestion_product("boundary:60", 999), "Core accepted duplicate ID with new amount")
	_check(not progress.record_arrival("boundary:160", 999), "Adapter accepted duplicate ID with new amount")
	_check(not progress.record_arrival("", 1), "Empty ID was accepted")
	_check(not progress.record_arrival("boundary:invalid", 0), "Zero receipt was accepted")
	_check(not progress.record_arrival("boundary:invalid", -1), "Negative receipt was accepted")
	_check(not progress.has_product("boundary:invalid"), "Rejected receipt reserved its ID")
	_check_state(progress, 161, 5, ColonyProgress.Stage.MATURE, "成熟", 0, "Rejected receipts")
	_check(events == prior_events, "Rejected or duplicate receipt emitted a notification")
	_check(core.nutrition == prior_balance, "Duplicate receipt changed the core balance")
	progress.free()
	core.free()


func _test_single_jump_commits_before_callbacks() -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	_check(progress.register_source(core), "Single jump core registration")
	var callback_kinds: Array[String] = []
	var assert_committed: Callable = func(kind: String) -> void:
		callback_kinds.append(kind)
		_check_state(progress, 160, 1, ColonyProgress.Stage.MATURE, "成熟", 0, kind + " committed state")
		_check(progress.has_product("jump:160"), kind + ": ID committed before callback")
		_check(core.nutrition == 160, kind + ": fixture receipt was credited before callback")
	progress.progress_changed.connect(func(total: int, count: int) -> void:
		_check(total == 160 and count == 1, "Single jump progress payload")
		assert_committed.call("progress")
	)
	progress.stage_changed.connect(func(previous: ColonyProgress.Stage, current: ColonyProgress.Stage) -> void:
		_check(previous == ColonyProgress.Stage.NASCENT and current == ColonyProgress.Stage.MATURE,
			"Single jump emitted an intermediate stage change")
		assert_committed.call("stage")
	)
	progress.stage_unlocked.connect(func(stage: ColonyProgress.Stage) -> void:
		assert_committed.call("unlock:%d" % stage)
	)
	_check(core.accept_digestion_product("jump:160", 160), "Single receipt crossing both boundaries")
	_check(events == ["p:160:1", "s:0:2", "u:1", "u:2"],
		"Single jump did not emit one final stage change followed by ascending unlocks")
	_check(callback_kinds == ["progress", "stage", "unlock:1", "unlock:2"],
		"Not every single jump callback observed committed state")
	progress.free()
	core.free()


func _test_balance_changes_and_damage_are_excluded() -> void:
	var progress := _new_progress()
	var core := CORE_SCENE.instantiate() as MotherCore
	core.initial_nutrition = 500
	var events := _observe(progress)
	_check(progress.register_source(core), "Pre-ready balance fixture registration")
	root.add_child(core)
	_check(core.nutrition == 500, "Initial funds fixture")
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Initial funds excluded")
	core.add_nutrition(200)
	_check(core.try_spend_nutrition(100), "Refund setup spending")
	core.add_nutrition(100)
	_check(core.try_spend_nutrition(40), "Internal transfer setup spending")
	core.add_nutrition(15)
	core.take_damage(5)
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Ordinary balance changes excluded")
	_check(events.is_empty(), "Initial funds, refunds, internal transfers, or damage advanced progress")

	_check(core.accept_digestion_product("exclusion:60", 60), "Expanded fixture receipt")
	_check(core.try_spend_nutrition(core.get_spendable_nutrition()), "Spend all expanded balance")
	core.take_damage(5)
	_check(core.nutrition == 0, "Expanded spending fixture did not empty balance")
	_check_state(progress, 60, 1, ColonyProgress.Stage.EXPANDED, "展开", 160, "Expanded survives spending and damage")
	_check(events == ["p:60:1", "s:0:1", "u:1"], "Expanded spending or damage emitted stage events")
	_check(core.accept_digestion_product("exclusion:160", 100), "Mature fixture receipt")
	_check(core.try_spend_nutrition(100), "Spend all mature balance")
	core.take_damage(core.max_health)
	_check(core.health == 0 and core.nutrition == 0, "Depletion fixture state")
	_check_state(progress, 160, 2, ColonyProgress.Stage.MATURE, "成熟", 0, "Mature survives spending and lethal damage")
	_check(events == ["p:60:1", "s:0:1", "u:1", "p:160:2", "s:1:2", "u:2"],
		"Spending or damage lowered cumulative stage")
	progress.free()
	core.free()


func _test_reset_and_fresh_run() -> void:
	var progress := _new_progress()
	var first_core := _new_core()
	var second_core := _new_core()
	var events := _observe(progress)
	_check(progress.register_source(first_core), "First reset source registration")
	_check(progress.register_source(second_core), "Second reset source registration")
	_check(first_core.accept_digestion_product("reset:reused", 160), "Mature setup before reset")
	var retired_callback := _capture_callback(first_core, "Pre-reset callback")
	events.clear()
	progress.reset()
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Reset state")
	_check(not progress.has_product("reset:reused"), "Reset retained a receipt ID")
	_check(events == ["p:0:0", "s:2:0"], "Reset notification order or unexpected unlock")
	_check(first_core.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty()
		and second_core.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty(),
		"Reset did not disconnect every arrival source")
	_check(first_core.accept_digestion_product("reset:ignored_first", 10), "Retired first source receipt fixture")
	_check(second_core.accept_digestion_product("reset:ignored_second", 20), "Retired second source receipt fixture")
	_call_retired(retired_callback, "reset:retired_callback", 160)
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Retired sources ignored after reset")
	_check(events == ["p:0:0", "s:2:0"], "Retired source or captured callback notified after reset")
	_check(not progress.has_product("reset:retired_callback"), "Captured callback reserved an ID after reset")

	_check(progress.register_source(first_core), "Explicit source registration after reset")
	_call_retired(retired_callback, "reset:old_generation", 160)
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Pre-reset callback remains retired after registration")
	_check(not progress.has_product("reset:old_generation"), "Re-registration revived a pre-reset callback")
	events.clear()
	_check(first_core.accept_digestion_product("reset:fresh60", 60), "Fresh run expanded receipt")
	_check(first_core.accept_digestion_product("reset:fresh160", 100), "Fresh run mature receipt")
	_check_state(progress, 160, 2, ColonyProgress.Stage.MATURE, "成熟", 0, "Fresh run maturity")
	_check(events == ["p:60:1", "s:0:1", "u:1", "p:160:2", "s:1:2", "u:2"],
		"Reset did not allow each stage to unlock once in the next run")
	progress.reset()
	var replacement_core := _new_core()
	_check(progress.register_source(replacement_core), "Replacement core registration")
	events.clear()
	_check(replacement_core.accept_digestion_product("reset:reused", 160), "Cleared receipt ID reuse through a fresh core")
	_check_state(progress, 160, 1, ColonyProgress.Stage.MATURE, "成熟", 0, "Receipt ID reused in new run")
	_check(events == ["p:160:1", "s:0:2", "u:1", "u:2"], "Second reset left unlock flags or receipt IDs reserved")
	progress.free()
	first_core.free()
	second_core.free()
	replacement_core.free()


func _test_retired_registration_callback() -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	_check(progress.register_source(core), "Registration lifetime source")
	_check(core.accept_digestion_product("registration:59", 59), "Registration lifetime setup")
	var retired_callback := _capture_callback(core, "Pre-unregister callback")
	progress.unregister_source(core)
	_check(core.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty(), "Unregister left an arrival subscription")
	_check(progress.register_source(core), "Source re-registration")
	_call_retired(retired_callback, "registration:retired", 160)
	_check_state(progress, 59, 1, ColonyProgress.Stage.NASCENT, "初生", 60, "Captured callback after re-registration")
	_check(not progress.has_product("registration:retired"), "Retired registration reserved an ID")
	_check(events == ["p:59:1"], "Retired registration emitted stage notifications")
	_check(core.accept_digestion_product("registration:fresh", 1), "Fresh registration receipt")
	_check_state(progress, 60, 2, ColonyProgress.Stage.EXPANDED, "展开", 160, "Fresh registration active")
	_check(events == ["p:59:1", "p:60:2", "s:0:1", "u:1"], "Fresh registration did not notify exactly once")
	progress.free()
	core.free()


func _test_reentrant_arrivals(trigger: String) -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	var control: Dictionary = {"fired": false}
	var nested_results: Array[bool] = []
	var reenter: Callable = func() -> void:
		if control["fired"]:
			return
		control["fired"] = true
		nested_results.append(core.accept_digestion_product("reentrant:outer", 999))
		nested_results.append(progress.record_arrival("reentrant:outer", 999))
		nested_results.append(core.accept_digestion_product("reentrant:second", 99))
		nested_results.append(core.accept_digestion_product("reentrant:second", 999))
		nested_results.append(progress.record_arrival("reentrant:second", 999))
		nested_results.append(core.accept_digestion_product("reentrant:third", 1))
	if trigger == "progress":
		progress.progress_changed.connect(func(total: int, _count: int) -> void:
			if total == 60:
				reenter.call()
		)
	elif trigger == "stage":
		progress.stage_changed.connect(func(_previous: ColonyProgress.Stage, current: ColonyProgress.Stage) -> void:
			if current == ColonyProgress.Stage.EXPANDED:
				reenter.call()
		)
	else:
		progress.stage_unlocked.connect(func(stage: ColonyProgress.Stage) -> void:
			if stage == ColonyProgress.Stage.EXPANDED:
				reenter.call()
		)
	_check(progress.register_source(core), trigger + ": reentrant fixture registration")
	_check(core.accept_digestion_product("reentrant:outer", 60), trigger + ": outer receipt")
	_check(control["fired"], trigger + ": callback was exercised")
	_check(nested_results == [false, false, true, false, false, true],
		trigger + ": reentrant duplicate and new receipt acceptance")
	_check_state(progress, 160, 3, ColonyProgress.Stage.MATURE, "成熟", 0, trigger + ": reentrant final state")
	_check(core.nutrition == 160, trigger + ": reentrant receipts credited exactly once")
	_check(events == ["p:60:1", "s:0:1", "u:1", "p:159:2", "p:160:3", "s:1:2", "u:2"],
		trigger + ": reentrant notifications were not FIFO or unlocked twice")
	progress.free()
	core.free()


func _test_reset_inside_notification(trigger: String) -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	var control: Dictionary = {"fired": false}
	var reset_with_pending_receipt: Callable = func() -> void:
		if control["fired"]:
			return
		control["fired"] = true
		_check(core.accept_digestion_product("notification:obsolete", 1), trigger + ": pending receipt setup")
		progress.reset()
	if trigger == "progress":
		progress.progress_changed.connect(func(total: int, _count: int) -> void:
			if total == 160:
				reset_with_pending_receipt.call()
		)
	elif trigger == "stage":
		progress.stage_changed.connect(func(_previous: ColonyProgress.Stage, current: ColonyProgress.Stage) -> void:
			if current == ColonyProgress.Stage.MATURE:
				reset_with_pending_receipt.call()
		)
	else:
		progress.stage_unlocked.connect(func(stage: ColonyProgress.Stage) -> void:
			if stage == ColonyProgress.Stage.EXPANDED:
				reset_with_pending_receipt.call()
		)
	_check(progress.register_source(core), trigger + ": reset callback source registration")
	_check(core.accept_digestion_product("notification:outer", 160), trigger + ": reset callback outer receipt")
	_check(control["fired"], trigger + ": reset callback was exercised")
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, trigger + ": reset inside notification")
	_check(not progress.has_product("notification:outer") and not progress.has_product("notification:obsolete"),
		trigger + ": reset retained committed or pending receipt IDs")
	_check(core.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty(), trigger + ": reset left a source connected")
	var expected: Array[String] = ["p:160:1"]
	if trigger != "progress":
		expected.append("s:0:2")
	if trigger == "unlock":
		expected.append("u:1")
	expected.append_array(["p:0:0", "s:2:0"])
	_check(events == expected, trigger + ": reset failed to suppress obsolete stage, unlock, or queued progress events")

	_check(progress.register_source(core), trigger + ": fresh source after callback reset")
	_check(core.accept_digestion_product("notification:fresh", 160), trigger + ": fresh receipt after callback reset")
	expected.append_array(["p:160:1", "s:0:2", "u:1", "u:2"])
	_check(events == expected, trigger + ": old notifications survived into the fresh run or fresh unlocks were suppressed")
	_check_state(progress, 160, 1, ColonyProgress.Stage.MATURE, "成熟", 0, trigger + ": fresh run after callback reset")
	progress.free()
	core.free()


func _test_reset_then_new_arrival_inside_callback() -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	var control: Dictionary = {"fired": false}
	progress.progress_changed.connect(func(total: int, _count: int) -> void:
		if total != 160 or control["fired"]:
			return
		control["fired"] = true
		_check(core.accept_digestion_product("generation:obsolete", 1), "Old generation queued receipt")
		progress.reset()
		_check(progress.register_source(core), "New generation source registration inside callback")
		_check(core.accept_digestion_product("generation:fresh", 60), "New generation receipt inside callback")
	)
	_check(progress.register_source(core), "Reset and arrival fixture registration")
	_check(core.accept_digestion_product("generation:outer", 160), "Reset and arrival outer receipt")
	_check_state(progress, 60, 1, ColonyProgress.Stage.EXPANDED, "展开", 160, "New generation committed inside callback")
	_check(not progress.has_product("generation:outer") and not progress.has_product("generation:obsolete")
		and progress.has_product("generation:fresh"), "Generation switch retained obsolete receipt IDs")
	_check(events == ["p:160:1", "p:0:0", "s:2:0", "p:60:1", "s:0:1", "u:1"],
		"Reset did not retain new generation FIFO notifications while suppressing obsolete ones")
	progress.free()
	core.free()


func _test_reset_inside_reset_notification() -> void:
	var progress := _new_progress()
	var core := _new_core()
	_check(progress.register_source(core), "Nested reset fixture registration")
	_check(core.accept_digestion_product("nested_reset:mature", 160), "Nested reset mature setup")
	var events := _observe(progress)
	var control: Dictionary = {"fired": false}
	progress.progress_changed.connect(func(total: int, _count: int) -> void:
		if total != 0 or control["fired"]:
			return
		control["fired"] = true
		progress.reset()
	)
	progress.reset()
	_check_state(progress, 0, 0, ColonyProgress.Stage.NASCENT, "初生", 60, "Nested reset final state")
	_check(events == ["p:0:0", "p:0:0"], "Nested reset did not invalidate the outer reset stage notification")
	events.clear()
	progress.reset()
	_check(events == ["p:0:0"], "Nascent reset emitted a stage change or unlock")
	progress.free()
	core.free()


func _test_overflow_rejection() -> void:
	var progress := _new_progress()
	var core := _new_core()
	var events := _observe(progress)
	_check(progress.register_source(core), "Overflow core registration")
	_check(core.accept_digestion_product("overflow:one", 1), "Overflow first receipt")
	_check(core.accept_digestion_product("overflow:maximum", MAX_RECOVERED - 1), "Receipt reaching maximum integer")
	_check_state(progress, MAX_RECOVERED, 2, ColonyProgress.Stage.MATURE, "成熟", 0, "Maximum recovery")
	_check(events == ["p:1:1", "p:%d:2" % MAX_RECOVERED, "s:0:2", "u:1", "u:2"],
		"Maximum receipt did not emit one ordered stage transition")
	var prior_events: Array[String] = events.duplicate()
	_check(not core.accept_digestion_product("overflow:core_rejected", 1), "Core accepted overflowing receipt")
	_check(not progress.record_arrival("overflow:adapter_rejected", 1), "Progress accepted overflowing receipt")
	_check(not progress.record_arrival("overflow:maximum", MAX_RECOVERED), "Duplicate maximum ID was accepted")
	_check(not progress.has_product("overflow:adapter_rejected")
		and not progress.has_product("overflow:core_rejected"), "Overflow rejection reserved a receipt ID")
	_check_state(progress, MAX_RECOVERED, 2, ColonyProgress.Stage.MATURE, "成熟", 0, "Overflow retains mature state")
	_check(core.nutrition == MAX_RECOVERED, "Overflow rejection changed the core balance")
	_check(events == prior_events, "Overflow or duplicate emitted progress, stage, or unlock notifications")
	progress.reset()
	_check(progress.record_arrival("overflow:adapter_rejected", 1), "Overflow-rejected adapter ID was not reusable after reset")
	_check_state(progress, 1, 1, ColonyProgress.Stage.NASCENT, "初生", 60, "Trusted adapter after overflow reset")
	progress.free()
	core.free()
