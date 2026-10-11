extends SceneTree
## 独立累计回收验证；引擎执行由主代理完成，此文件当前未执行。

const PROGRESS_SCRIPT: GDScript = preload("res://scripts/colony_progress.gd")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const ARRIVAL_SIGNAL: StringName = &"digestion_product_arrived"
const MAX_RECOVERED: int = 9223372036854775807


class ArrivalSource:
	extends Node

	signal digestion_product_arrived(product_id: String, nutrition: int)

	func arrive(product_id: String, nutrition: int) -> void:
		digestion_product_arrived.emit(product_id, nutrition)


var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_record_arrival()
	_test_core_receipts_and_balance_changes()
	_test_multiple_sources()
	_test_registration_and_lifetime()
	_test_reset_and_retired_callbacks()
	_test_overflow()
	print("COLONY_PROGRESS_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
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


func _observe(progress: ColonyProgress) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	progress.progress_changed.connect(func(total_recovered: int, product_count: int) -> void:
		events.append({"total_recovered": total_recovered, "product_count": product_count})
	)
	return events


func _check_progress(
	progress: ColonyProgress, total_recovered: int, product_count: int, context: String
) -> void:
	_check(progress.get_total_recovered() == total_recovered, context + ": cumulative recovery")
	_check(progress.get_product_count() == product_count, context + ": unique product count")


func _test_record_arrival() -> void:
	var progress := _new_progress()
	var events := _observe(progress)
	_check_progress(progress, 0, 0, "Initial progress")
	_check(not progress.has_product("adapter:1"), "Unseen product was reported as received")
	_check(progress.record_arrival("adapter:1", 7), "Valid adapter arrival was rejected")
	_check_progress(progress, 7, 1, "First arrival")
	_check(progress.has_product("adapter:1"), "Accepted arrival ID was not retained")
	_check(events == [{"total_recovered": 7, "product_count": 1}],
		"First arrival did not emit its updated total and count")
	_check(not progress.record_arrival("adapter:1", 7), "Repeated product was accepted")
	_check(not progress.record_arrival("adapter:1", 999), "Changed amount bypassed ID deduplication")
	_check(not progress.record_arrival("", 3), "Empty product ID was accepted")
	_check(not progress.record_arrival("adapter:zero", 0), "Zero nutrition was accepted")
	_check(not progress.record_arrival("adapter:negative", -4), "Negative nutrition was accepted")
	_check_progress(progress, 7, 1, "Rejected arrivals")
	_check(events.size() == 1, "Rejected arrivals emitted progress changes")
	_check(not progress.has_product("adapter:zero") and not progress.has_product("adapter:negative"),
		"Rejected arrivals reserved their product IDs")
	_check(progress.record_arrival("adapter:zero", 2), "Invalid amount permanently reserved an ID")
	_check_progress(progress, 9, 2, "Valid retry after invalid amount")
	var nested_results: Array[bool] = []
	progress.progress_changed.connect(func(_total_recovered: int, _product_count: int) -> void:
		nested_results.append(progress.record_arrival("adapter:reentrant", 3))
	)
	_check(progress.record_arrival("adapter:reentrant", 3), "Reentrant test arrival was rejected")
	_check(nested_results == [false], "Product ID was not committed before notifying observers")
	_check_progress(progress, 12, 3, "Reentrant duplicate")
	progress.free()


func _test_core_receipts_and_balance_changes() -> void:
	var progress := _new_progress()
	var core := CORE_SCENE.instantiate() as MotherCore
	core.initial_nutrition = 72
	_check(progress.register_source(core), "Core source registration before ready failed")
	var events := _observe(progress)
	root.add_child(core)
	_check(core.nutrition == 72, "Core initial balance was not initialized")
	_check_progress(progress, 0, 0, "Initial balance is excluded")
	_check(events.is_empty(), "Core initial balance emitted recovery progress")
	_check(core.accept_digestion_product("core:1", 8), "Core rejected a valid receipt")
	_check(core.nutrition == 80, "Receipt did not credit the core exactly once")
	_check_progress(progress, 8, 1, "Core receipt")
	_check(core.has_received_product("core:1") and core.get_received_product_count() == 1,
		"Core did not retain its accepted receipt")
	_check(events.size() == 1, "Core receipt did not produce exactly one progress change")
	_check(core.try_spend_nutrition(11), "Spending from core balance failed")
	_check_progress(progress, 8, 1, "Spending preserves cumulative recovery")
	core.add_nutrition(5)
	_check_progress(progress, 8, 1, "Generic balance credit is excluded")
	_check(core.try_spend_nutrition(4), "Refund setup debit failed")
	core.add_nutrition(4)
	_check_progress(progress, 8, 1, "Refund is excluded")
	_check(core.try_spend_nutrition(3), "Internal transfer setup debit failed")
	core.add_nutrition(2)
	_check_progress(progress, 8, 1, "Internal debit and credit are excluded")
	_check(events.size() == 1, "Ordinary balance changes emitted recovery progress")
	var balance_before_duplicate: int = core.nutrition
	_check(not core.accept_digestion_product("core:1", 8), "Core accepted a repeated receipt")
	_check(not core.accept_digestion_product("core:1", 50), "Core accepted a repeated ID with new amount")
	_check(core.nutrition == balance_before_duplicate, "Duplicate receipt credited the core")
	_check_progress(progress, 8, 1, "Duplicate core receipt")
	_check(events.size() == 1, "Duplicate core receipt emitted progress")
	_check(core.accept_digestion_product("core:2", 4), "Second core receipt was rejected")
	_check_progress(progress, 12, 2, "Second core receipt")
	_check(core.nutrition == balance_before_duplicate + 4, "Observer changed the credited balance")
	progress.free()
	core.free()


func _test_multiple_sources() -> void:
	var progress := _new_progress()
	var first_core := _new_core(0)
	var second_core := _new_core(0)
	var fixture := ArrivalSource.new()
	var events := _observe(progress)
	_check(progress.register_source(first_core), "First core registration failed")
	_check(progress.register_source(second_core), "Second core registration failed")
	_check(progress.register_source(fixture), "Typed signal source registration failed")
	_check(first_core.accept_digestion_product("shared:1", 4), "First source receipt failed")
	_check(second_core.accept_digestion_product("shared:1", 50), "Second core local receipt failed")
	fixture.arrive("shared:1", 99)
	_check_progress(progress, 4, 1, "Same ID across sources and amounts")
	_check(events.size() == 1, "Cross-source duplicate emitted progress")
	_check(second_core.accept_digestion_product("second:2", 3), "Unique second source receipt failed")
	fixture.arrive("fixture:3", 5)
	_check_progress(progress, 12, 3, "Unique products from multiple sources")
	_check(events.size() == 3, "Multiple sources did not emit once per unique product")
	_check(first_core.nutrition == 4 and second_core.nutrition == 53,
		"Observer changed a source balance while applying global deduplication")
	_check(progress.has_product("shared:1") and progress.has_product("second:2")
		and progress.has_product("fixture:3"), "Multiple source product IDs were not retained")
	progress.free()
	first_core.free()
	second_core.free()
	fixture.free()


func _test_registration_and_lifetime() -> void:
	var progress := _new_progress()
	var source := ArrivalSource.new()
	var unsupported := Node.new()
	_check(not progress.register_source(null), "Null source registration was accepted")
	_check(not progress.register_source(unsupported), "Source without arrival signal was accepted")
	_check(progress.register_source(source), "Signal source registration failed")
	_check(not progress.register_source(source), "Duplicate source registration was accepted")
	_check(source.get_signal_connection_list(ARRIVAL_SIGNAL).size() == 1,
		"Duplicate registration created an additional subscription")
	source.arrive("lifecycle:1", 3)
	_check_progress(progress, 3, 1, "Registered source")
	var old_callback: Callable = source.get_signal_connection_list(ARRIVAL_SIGNAL)[0]["callable"]
	progress.unregister_source(source)
	progress.unregister_source(source)
	progress.unregister_source(unsupported)
	progress.unregister_source(null)
	_check(source.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty(),
		"Unregistration left a source subscription")
	source.arrive("lifecycle:2", 2)
	_check_progress(progress, 3, 1, "Unregistered source is ignored")
	_check(not progress.has_product("lifecycle:2"), "Unregistered source reserved a product ID")
	_check(progress.register_source(source), "Source could not register again after unregistration")
	old_callback.call("lifecycle:old_callback", 20)
	_check_progress(progress, 3, 1, "Old registration callback is ignored")
	source.arrive("lifecycle:2", 2)
	_check_progress(progress, 5, 2, "Fresh registration accepts arrivals")
	source.free()
	progress.reset()
	_check_progress(progress, 0, 0, "Reset safely skips a freed source")
	var surviving_source := ArrivalSource.new()
	_check(progress.register_source(surviving_source), "Registration failed after source was freed")
	progress.free()
	_check(surviving_source.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty(),
		"Freeing progress left a callable connected to a freed observer")
	surviving_source.arrive("lifecycle:after_observer_free", 6)
	surviving_source.free()
	unsupported.free()


func _test_reset_and_retired_callbacks() -> void:
	var progress := _new_progress()
	var first_source := ArrivalSource.new()
	var second_source := ArrivalSource.new()
	var new_source := ArrivalSource.new()
	var events := _observe(progress)
	_check(progress.register_source(first_source), "First reset source registration failed")
	_check(progress.register_source(second_source), "Second reset source registration failed")
	first_source.arrive("reset:1", 8)
	second_source.arrive("reset:2", 3)
	_check_progress(progress, 11, 2, "Before reset")
	var retired_callback: Callable = first_source.get_signal_connection_list(ARRIVAL_SIGNAL)[0]["callable"]
	progress.reset()
	_check_progress(progress, 0, 0, "Reset clears cumulative progress")
	_check(not progress.has_product("reset:1") and not progress.has_product("reset:2"),
		"Reset left product IDs reserved")
	_check(first_source.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty()
		and second_source.get_signal_connection_list(ARRIVAL_SIGNAL).is_empty(),
		"Reset did not disconnect every source")
	_check(events.size() == 3 and events[2] == {"total_recovered": 0, "product_count": 0},
		"Reset did not notify observers with zero totals")
	first_source.arrive("reset:retired_first", 20)
	second_source.arrive("reset:retired_second", 30)
	retired_callback.call("reset:retired_callback", 40)
	_check_progress(progress, 0, 0, "Retired sources and callbacks stay ignored")
	_check(events.size() == 3, "Retired sources emitted progress after reset")
	_check(progress.register_source(new_source), "New source registration after reset failed")
	new_source.arrive("reset:1", 6)
	_check_progress(progress, 6, 1, "New source starts a fresh observation period")
	_check(progress.register_source(first_source), "Retired source could not explicitly register again")
	retired_callback.call("reset:old_generation", 40)
	_check_progress(progress, 6, 1, "Callback from pre-reset registration remains retired")
	first_source.arrive("reset:retired_first", 2)
	_check_progress(progress, 8, 2, "Explicitly registered source resumes observation")
	progress.reset()
	_check_progress(progress, 0, 0, "Repeated reset")
	progress.free()
	first_source.free()
	second_source.free()
	new_source.free()


func _test_overflow() -> void:
	var progress := _new_progress()
	var events := _observe(progress)
	_check(progress.record_arrival("overflow:1", 1), "Overflow setup arrival failed")
	_check(progress.record_arrival("overflow:maximum", MAX_RECOVERED - 1),
		"Arrival reaching maximum integer total was rejected")
	_check_progress(progress, MAX_RECOVERED, 2, "Maximum cumulative recovery")
	_check(not progress.record_arrival("overflow:rejected", 1), "Overflowing arrival was accepted")
	_check(not progress.record_arrival("overflow:maximum", MAX_RECOVERED),
		"Duplicate at maximum total bypassed deduplication")
	_check_progress(progress, MAX_RECOVERED, 2, "Overflow rejection retains state")
	_check(not progress.has_product("overflow:rejected"), "Overflow rejection reserved its product ID")
	_check(events.size() == 2, "Overflow rejection emitted a progress change")
	progress.reset()
	_check(progress.record_arrival("overflow:rejected", 1), "Overflow rejected ID failed after reset")
	_check_progress(progress, 1, 1, "Overflow rejected ID is reusable in a fresh period")
	progress.free()
