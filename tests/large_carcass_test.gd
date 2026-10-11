extends SceneTree
## 独立有限资源验证；运行结果记录在 README 的统一验收章节。

const SOURCE_SCRIPT: GDScript = preload("res://scripts/large_carcass.gd")
const SOURCE_SCENE: PackedScene = preload("res://scenes/recycling/large_carcass.tscn")
const MAX_NUTRITION: int = 9223372036854775807

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_default_eight_batches()
	_test_tail_and_batch_limits()
	_test_competing_reservations()
	_test_ids_and_invalid_operations()
	_test_frozen_configuration_and_identity()
	_test_status_and_notifications()
	_test_reentrant_commit_and_release()
	await _test_deletion_during_commit_notifications()
	_test_placeholder_scene()
	print("LARGE_CARCASS_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_source(total: int = 80, limit: int = 10) -> LargeCarcass:
	var source := SOURCE_SCRIPT.new() as LargeCarcass
	source.total_nutrition = total
	source.batch_size = limit
	return source


func _observe(source: LargeCarcass) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	source.resources_changed.connect(func(snapshot: Dictionary) -> void:
		events.append(snapshot.duplicate(true))
	)
	return events


func _check_ledger(
	source: LargeCarcass, initial: int, remaining: int, reserved: int,
	harvested: int, context: String
) -> void:
	var snapshot: Dictionary = source.get_snapshot()
	_check(snapshot.get("resource_id", "") == source.get_resource_id(), context + ": resource identity")
	_check(snapshot.get("total_nutrition", -1) == initial, context + ": frozen initial total")
	_check(snapshot.get("remaining_nutrition", -1) == remaining, context + ": snapshot remaining")
	_check(snapshot.get("reserved_nutrition", -1) == reserved, context + ": snapshot reservations")
	_check(snapshot.get("available_nutrition", -1) == remaining - reserved,
		context + ": snapshot availability")
	_check(snapshot.get("harvested_nutrition", -1) == harvested, context + ": snapshot harvested")
	_check(source.get_remaining_nutrition() == remaining, context + ": remaining includes reservations")
	_check(source.get_reserved_nutrition() == reserved, context + ": reserved query")
	_check(source.get_available_nutrition() == remaining - reserved, context + ": available query")
	_check(source.get_harvested_nutrition() == harvested, context + ": harvested query")
	_check(int(snapshot.get("available_nutrition", -1))
		+ int(snapshot.get("reserved_nutrition", -1))
		+ int(snapshot.get("harvested_nutrition", -1)) == initial,
		context + ": nutrition is conserved")


func _test_default_eight_batches() -> void:
	var source := SOURCE_SCRIPT.new() as LargeCarcass
	var events := _observe(source)
	var exhaustion_events: Array[bool] = []
	source.exhausted.connect(func() -> void: exhaustion_events.append(true))
	_check(source.total_nutrition == 80 and source.batch_size == 10, "Default exports changed")
	_check_ledger(source, 80, 80, 0, 0, "Default stock")
	_check(not source.is_exhausted(), "A fresh 80-unit source is exhausted")
	for index in range(8):
		var request_id: String = "default:request:%d" % index
		var batch_id: String = "default:batch:%d" % index
		_check(source.reserve_batch(request_id) == 10, "Default batch was not ten units")
		_check(source.get_reservation_nutrition(request_id) == 10, "Live reservation has wrong amount")
		_check_ledger(source, 80, 80 - index * 10, 10, index * 10, "Reserved default batch")
		_check(source.commit_batch(request_id, batch_id), "Default batch commit failed")
		_check(source.get_reservation_nutrition(request_id) == 0, "Committed reservation remains live")
		_check_ledger(source, 80, 70 - index * 10, 0, (index + 1) * 10, "Committed default batch")
	_check(source.is_exhausted(), "Eight ten-unit commits did not exhaust stock")
	_check(source.get_snapshot().get("status") == &"exhausted", "Exhaustion did not override status")
	_check(exhaustion_events.size() == 1, "Exhaustion was not emitted exactly once")
	_check(events.size() == 16, "Each accepted reserve and commit must emit one change")
	for index in range(12):
		_check(source.reserve_batch("exhausted:%d" % index) == 0, "Exhausted source created a reservation")
		_check(not source.commit_batch("default:request:0", "default:batch:0"),
			"Repeated committed batch succeeded")
		_check(not source.release_batch("default:request:0"), "Committed stock was refunded")
	_check_ledger(source, 80, 0, 0, 80, "Rejected exhausted operations")
	_check(events.size() == 16 and exhaustion_events.size() == 1,
		"Exhausted no-op requests emitted changes or repeated exhaustion")
	source.free()


func _test_tail_and_batch_limits() -> void:
	var tail_source := _new_source(23)
	var tail_amounts: Array[int] = []
	for index in range(3):
		var request_id: String = "tail:%d" % index
		tail_amounts.append(tail_source.reserve_batch(request_id, 100))
		_check(tail_source.commit_batch(request_id, "tail:batch:%d" % index), "Tail batch commit failed")
	_check(tail_amounts == [10, 10, 3], "Custom total did not produce its exact final tail")
	_check_ledger(tail_source, 23, 0, 0, 23, "Tail total")
	tail_source.free()
	var capped_source := _new_source(80, 999)
	_check(capped_source.reserve_batch("capped", 999) == 10, "Exported batch size bypassed cap of ten")
	_check_ledger(capped_source, 80, 80, 10, 0, "Capped oversized reservation")
	capped_source.free()
	var small_source := _new_source(25, 6)
	_check(small_source.reserve_batch("small:requested", 4) == 4, "Smaller requested amount was ignored")
	_check(small_source.reserve_batch("small:configured", 100) == 6, "Configured smaller batch was ignored")
	_check_ledger(small_source, 25, 25, 10, 0, "Smaller batches")
	small_source.free()
	for limit in [0, -8]:
		var disabled_source := _new_source(10, int(limit))
		_check(disabled_source.reserve_batch("disabled") == 0, "Nonpositive batch size reserved nutrition")
		_check_ledger(disabled_source, 10, 10, 0, 0, "Nonpositive batch size")
		disabled_source.free()
	var negative_source := _new_source(-20)
	_check(negative_source.is_exhausted(), "Negative total was not normalized to an empty source")
	_check(negative_source.reserve_batch("negative") == 0, "Negative total created nutrition")
	_check_ledger(negative_source, 0, 0, 0, 0, "Normalized negative total")
	negative_source.free()
	var maximum_source := _new_source(MAX_NUTRITION)
	_check(maximum_source.reserve_batch("maximum") == 10, "Maximum integer total could not reserve")
	_check(maximum_source.commit_batch("maximum", "maximum:batch"), "Maximum integer total commit failed")
	_check_ledger(maximum_source, MAX_NUTRITION, MAX_NUTRITION - 10, 0, 10, "Maximum integer total")
	maximum_source.free()


func _test_competing_reservations() -> void:
	var source := _new_source(25)
	_check(source.reserve_batch("first") == 10, "First competing reservation failed")
	_check(source.reserve_batch("second") == 10, "Second competing reservation failed")
	_check(source.reserve_batch("tail") == 5, "Competing reservation did not respect available tail")
	_check(source.reserve_batch("blocked") == 0, "Competing reservations overlapped stock")
	_check_ledger(source, 25, 25, 25, 0, "Fully reserved stock")
	_check(source.release_batch("second"), "Live competing reservation could not release")
	_check(not source.release_batch("second"), "Repeated release succeeded")
	_check(source.reserve_batch("second") == 0, "Released request ID was reused")
	_check(source.reserve_batch("blocked") == 0, "Failed request ID was reused after capacity returned")
	_check_ledger(source, 25, 25, 15, 0, "Released reservation preserves stock")
	_check(source.reserve_batch("replacement") == 10, "Fresh request did not reclaim released availability")
	_check(source.commit_batch("first", "shared:batch"), "First competing commit failed")
	_check(not source.commit_batch("tail", "shared:batch"), "Same batch ID committed a second reservation")
	_check(source.get_reservation_nutrition("tail") == 5, "Rejected duplicate batch lost its live reservation")
	_check_ledger(source, 25, 15, 15, 10, "Committed first competing batch")
	_check(source.commit_batch("tail", "tail:batch"), "Tail could not retry with a fresh batch ID")
	_check(source.commit_batch("replacement", "replacement:batch"), "Replacement competing commit failed")
	_check_ledger(source, 25, 0, 0, 25, "All competing stock committed once")
	_check(not source.release_batch("first") and not source.release_batch("replacement"),
		"A completed competing commit restored source nutrition")
	source.free()


func _test_ids_and_invalid_operations() -> void:
	var source := _new_source(20)
	var events := _observe(source)
	_check(source.reserve_batch("") == 0, "Empty request ID was accepted")
	_check(source.reserve_batch("zero", 0) == 0, "Zero requested amount was accepted")
	_check(source.reserve_batch("negative", -1) == 0, "Negative requested amount was accepted")
	_check(source.reserve_batch("zero", 10) == 0, "Failed zero-amount request ID was reused")
	_check(source.reserve_batch("negative", 10) == 0, "Failed negative-amount request ID was reused")
	_check(source.get_reservation_nutrition("") == 0
		and source.get_reservation_nutrition("unknown") == 0, "Unknown reservation reported nutrition")
	_check(not source.commit_batch("unknown", "unused:batch"), "Unknown reservation was committed")
	_check(not source.release_batch("unknown"), "Unknown reservation was released")
	_check(events.is_empty(), "Rejected requests emitted resource changes")
	_check(source.reserve_batch("live") == 10, "Valid request after rejection failed")
	_check(source.reserve_batch("live", 1) == 0, "Live request ID was reused with a new amount")
	_check(not source.commit_batch("live", ""), "Empty batch ID was accepted")
	_check(not source.commit_batch("", "unused:batch"), "Empty request ID was committed")
	_check_ledger(source, 20, 20, 10, 0, "Invalid commits retain a live reservation")
	_check(source.commit_batch("live", "unused:batch"), "Failed commit attempt reserved its batch ID")
	_check(not source.commit_batch("live", "fresh:batch"), "Committed request ID was reused with a fresh batch")
	_check(source.reserve_batch("live") == 0, "Committed request ID was reserved again")
	_check(not source.release_batch("live"), "Committed reservation was released")
	_check(source.reserve_batch("final") == 10, "Final unique reservation failed")
	_check(not source.commit_batch("final", "unused:batch"), "Committed batch ID was reused")
	_check(source.release_batch("final"), "Reservation after invalid duplicate batch could not release")
	_check(source.reserve_batch("final") == 0, "Released final request ID was reused")
	_check_ledger(source, 20, 10, 0, 10, "Invalid and repeated operations conserve stock")
	_check(events.size() == 4, "Rejected or repeated operations emitted extra changes")
	source.free()


func _test_frozen_configuration_and_identity() -> void:
	var source := _new_source()
	var identity: String = source.get_resource_id()
	_check(not identity.is_empty() and source.get_resource_id() == identity, "Resource ID was not stable")
	source.total_nutrition = 27
	source.batch_size = 6
	_check_ledger(source, 27, 27, 0, 0, "Identity lookup leaves configuration editable")
	_check(source.reserve_batch("freeze:first") == 6, "Pre-use configured batch was not applied")
	_check(source.commit_batch("freeze:first", "freeze:batch"), "Configuration freeze setup commit failed")
	source.total_nutrition = 99999
	source.batch_size = 999
	_check(source.reserve_batch("freeze:second", 100) == 6, "Changing exports altered frozen batch size")
	_check_ledger(source, 27, 21, 6, 6, "Changing exports cannot refill stock")
	_check(source.release_batch("freeze:second"), "Frozen-source reservation release failed")
	source.total_nutrition = 0
	_check_ledger(source, 27, 21, 0, 6, "Changing exports cannot erase committed history")
	var other_source := _new_source()
	_check(other_source.get_resource_id() != identity, "Different source instances share a resource ID")
	var snapshot: Dictionary = source.get_snapshot()
	snapshot["remaining_nutrition"] = 9000
	_check_ledger(source, 27, 21, 0, 6, "Caller cannot mutate the ledger through a snapshot")
	source.free()
	other_source.free()


func _test_status_and_notifications() -> void:
	var source := _new_source(10)
	var events := _observe(source)
	_check(source.get_snapshot().get("status") == &"out_of_field", "Initial harvest status changed")
	source.set_harvest_status(&"out_of_field")
	source.set_harvest_status(&"unknown_status")
	source.set_harvest_status(&"exhausted")
	_check(source.get_snapshot().get("status") == &"out_of_field",
		"External exhausted status hid a source with remaining stock")
	source.get_snapshot()
	source.get_remaining_nutrition()
	source.get_available_nutrition()
	_check(events.is_empty(), "Queries or unchanged/invalid status emitted changes")
	var statuses: Array[StringName] = [
		&"no_route", &"capacity_full", &"ready", &"harvesting", &"out_of_field"
	]
	for status in statuses:
		source.set_harvest_status(status)
		_check(source.get_snapshot().get("status") == status, "Valid harvest status was ignored")
		source.set_harvest_status(status)
	_check(events.size() == statuses.size(), "Status changes did not notify exactly once")
	_check(not source.is_exhausted(), "External display status changed the actual stock query")
	source.set_harvest_status(&"harvesting")
	_check(source.reserve_batch("status:last") == 10, "Status exhaustion setup reservation failed")
	_check(source.commit_batch("status:last", "status:batch"), "Status exhaustion setup commit failed")
	var changes_after_exhaustion: int = events.size()
	for status in statuses:
		source.set_harvest_status(status)
	source.set_harvest_status(&"exhausted")
	_check(source.get_snapshot().get("status") == &"exhausted", "External status overrode exhaustion")
	_check(events.size() == changes_after_exhaustion, "Exhaustion override emitted unchanged status")
	_check_ledger(source, 10, 0, 0, 10, "Status changes preserve nutrition")
	source.free()


func _test_reentrant_commit_and_release() -> void:
	var source := _new_source(10)
	var events := _observe(source)
	var duplicate_reservations: Array[int] = []
	var commits: Array[bool] = []
	var rejected_commits: Array[bool] = []
	var releases: Array[bool] = []
	var exhaustion_events: Array[bool] = []
	source.resources_changed.connect(func(snapshot: Dictionary) -> void:
		if int(snapshot.get("reserved_nutrition", 0)) == 10:
			_check(source.get_reservation_nutrition("reentrant") == 10,
				"Reservation bookkeeping was not updated before notification")
			duplicate_reservations.append(source.reserve_batch("reentrant"))
			commits.append(source.commit_batch("reentrant", "reentrant:batch"))
		else:
			_check(source.get_harvested_nutrition() == 10 and source.get_available_nutrition() == 0,
				"Commit bookkeeping was not updated before notification")
			rejected_commits.append(source.commit_batch("reentrant", "reentrant:batch"))
			releases.append(source.release_batch("reentrant"))
			duplicate_reservations.append(source.reserve_batch("exhausted:reentrant"))
	)
	source.exhausted.connect(func() -> void:
		exhaustion_events.append(true)
		rejected_commits.append(source.commit_batch("reentrant", "reentrant:fresh"))
		source.set_harvest_status(&"ready")
	)
	_check(source.reserve_batch("reentrant") == 10, "Reentrant reservation did not return accepted amount")
	_check(commits == [true] and rejected_commits == [false, false],
		"Reentrant commit was not committed exactly once")
	_check(duplicate_reservations == [0, 0] and releases == [false],
		"Reentrant duplicate or release created/refunded nutrition")
	_check(events.size() == 2 and exhaustion_events.size() == 1, "Reentrant operations repeated notifications")
	_check_ledger(source, 10, 0, 0, 10, "Reentrant commit ledger")
	source.free()
	var released_source := _new_source(10)
	var released_results: Array[bool] = []
	var release_callback: Callable = func(snapshot: Dictionary) -> void:
		if int(snapshot.get("reserved_nutrition", 0)) == 10:
			released_results.append(released_source.release_batch("reentrant:release"))
		else:
			released_results.append(released_source.release_batch("reentrant:release"))
			_check(released_source.get_available_nutrition() == 10,
				"Release bookkeeping was not updated before notification")
	released_source.resources_changed.connect(release_callback)
	_check(released_source.reserve_batch("reentrant:release") == 10, "Reentrant release setup failed")
	_check(released_results == [false, true], "Reentrant release was not applied exactly once")
	_check(not released_source.commit_batch("reentrant:release", "released:batch"),
		"Released reservation committed after a callback")
	_check(released_source.reserve_batch("reentrant:release") == 0, "Reentrant release allowed request ID reuse")
	_check_ledger(released_source, 10, 10, 0, 0, "Reentrant release ledger")
	released_source.resources_changed.disconnect(release_callback)
	_check(released_source.reserve_batch("released:fresh") == 10, "Fresh request could not use released stock")
	released_source.free()


func _test_deletion_during_commit_notifications() -> void:
	var source := _new_source(10)
	root.add_child(source)
	_check(source.reserve_batch("delete:change") == 10, "Deletion callback setup reservation failed")
	# Godot 会锁定正在发信号的对象；生命周期删除必须使用 queue_free。
	source.resources_changed.connect(func(_snapshot: Dictionary) -> void: source.queue_free())
	var committed_during_change: bool = source.commit_batch("delete:change", "delete:change:batch")
	_check(committed_during_change, "Deleting source in resources_changed changed an executed commit result")
	_check(source.is_queued_for_deletion() and source.get_harvested_nutrition() == 10,
		"Resource change deletion must preserve the committed deduction")
	var exhausted_source := _new_source(10)
	root.add_child(exhausted_source)
	_check(exhausted_source.reserve_batch("delete:exhausted") == 10, "Exhaustion deletion setup failed")
	exhausted_source.exhausted.connect(func() -> void: exhausted_source.queue_free())
	var committed_during_exhaustion: bool = exhausted_source.commit_batch(
		"delete:exhausted", "delete:exhausted:batch"
	)
	_check(committed_during_exhaustion, "Deleting source in exhausted changed an executed commit result")
	_check(exhausted_source.is_queued_for_deletion(), "Exhaustion did not schedule source removal")
	await process_frame
	await process_frame
	_check(not is_instance_valid(source), "Resource change deletion callback did not free the source")
	_check(not is_instance_valid(exhausted_source), "Exhaustion deletion callback did not free the source")


func _test_placeholder_scene() -> void:
	var source := SOURCE_SCENE.instantiate() as LargeCarcass
	source.total_nutrition = 13
	root.add_child(source)
	var title_label := source.get_node("TitleLabel") as Label
	var stock_label := source.get_node("StockLabel") as Label
	var status_label := source.get_node("StatusLabel") as Label
	_check(title_label.text == "大型尸骸", "Placeholder did not use the project source terminology")
	var chinese_font := stock_label.get_theme_font("font") as SystemFont
	_check(chinese_font != null, "Placeholder did not provide a Chinese system font")
	if chinese_font != null:
		_check(chinese_font.font_names == PackedStringArray([
			"PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC"
		]), "Placeholder Chinese font fallback names changed")
	_check(stock_label.text == "剩余营养：13/13", "Placeholder did not show initialized remaining stock")
	_check(status_label.text == "菌域外", "Placeholder did not show Chinese initial state")
	source.set_harvest_status(&"exhausted")
	_check(status_label.text == "菌域外", "Placeholder claimed depletion before its stock was committed")
	source.set_harvest_status(&"capacity_full")
	_check(status_label.text == "胃囊已满", "Placeholder did not update its Chinese state")
	_check(source.reserve_batch("view:first") == 10, "Placeholder reserve failed")
	_check(stock_label.text == "剩余营养：13/13", "Placeholder deducted reserved stock before commit")
	_check(source.commit_batch("view:first", "view:first:batch"), "Placeholder commit failed")
	_check(stock_label.text == "剩余营养：3/13", "Placeholder did not show committed remaining stock")
	_check(source.reserve_batch("view:tail") == 3, "Placeholder tail reserve failed")
	_check(source.commit_batch("view:tail", "view:tail:batch"), "Placeholder tail commit failed")
	_check(stock_label.text == "剩余营养：0/13" and status_label.text == "已耗尽",
		"Placeholder did not show depleted stock and exhausted state")
	source.free()
	var empty_source := SOURCE_SCENE.instantiate() as LargeCarcass
	empty_source.total_nutrition = 0
	var exhaustion_events: Array[bool] = []
	empty_source.exhausted.connect(func() -> void: exhaustion_events.append(true))
	root.add_child(empty_source)
	_check(empty_source.is_exhausted() and exhaustion_events.size() == 1,
		"Initially empty scene did not announce exhaustion once on ready")
	root.remove_child(empty_source)
	empty_source.request_ready()
	root.add_child(empty_source)
	_check(exhaustion_events.size() == 1, "Repeated ready emitted exhaustion again")
	empty_source.free()
