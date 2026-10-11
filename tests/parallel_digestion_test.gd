extends SceneTree
## 双腔室的局部所有权测试；只安排 intake，完成使用真实计时器或保存的任务回调。

class Fixture:
	extends RefCounted

	var host: Node2D
	var organ: DigestiveOrgan
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var expansion_callback: Callable
	var admitted_nutrition: int = 0
	var settled_nutrition: int = 0
	var starts: Array[Dictionary] = []
	var completions: Array[Dictionary] = []
	var creations: Array[Dictionary] = []
	var digestions: Array[int] = []
	var inventories: Array[Dictionary] = []
	var outputs: Array[Dictionary] = []
	var changes: Array[Dictionary] = []

const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")

var failures: Array[String] = []
var checks: int = 0
var evidence: Array[Dictionary] = []
var _hosts: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	_test_legacy_primary_and_intake()
	await _test_reservation_lifecycle_compatibility()
	await _test_reservation_cleanup_notifications()
	var overlap: Fixture = _new_fixture(false)
	_feed(overlap, 4)
	_feed(overlap, 6)
	var first_task: Dictionary = _chamber(overlap, 0)
	var started_at: float = _now()
	_mature(overlap)
	overlap.expansion_callback = _timer_callback(overlap.organ.chamber_expansion_timer)
	_test_expansion_binding(overlap, first_task)

	# 同时等待各局部 fixture 的真实 3 秒扩建，避免串行重复等待。
	var parallel: Fixture = _new_fixture(true)
	var values: Fixture = _new_fixture(true)
	var oversize: Fixture = _new_fixture(true)
	var reentrant: Fixture = _new_fixture(true)
	var refeed: Fixture = _new_fixture(true)
	var reset_during_completion: Fixture = _new_fixture(true)
	var stop: Fixture = _new_fixture(true)
	var downgrade: Fixture = _new_fixture(true)
	var removed: Fixture = _new_fixture(true)
	var remove_during_completion: Fixture = _new_fixture(true)
	var actual: Fixture = _new_fixture(true, 1.5)
	var expanded: Array[Fixture] = [
		overlap, parallel, values, oversize, reentrant, refeed, reset_during_completion,
		stop, downgrade, removed, remove_during_completion, actual,
	]
	await create_timer(0.3, true, true).timeout
	var growing: Dictionary = overlap.organ.get_digestion_snapshot()
	_check(growing["chamber_count"] == 1 and growing["expansion_state"] == &"expanding",
		"Second chamber unlocked before three seconds elapsed")
	_check(growing["expansion_progress"] > 0.0 and growing["expansion_progress"] < 1.0,
		"Expansion snapshot did not follow real elapsed progress")
	_check(_chamber(overlap, 0)["task_id"] == first_task["task_id"],
		"Expansion replaced the active primary task")
	await _wait_for_expansion(expanded)
	var elapsed: float = _now() - started_at
	_check(elapsed >= 3.0, "Expansion completed without three game physics seconds")
	_check(_chamber(overlap, 0)["task_id"] == first_task["task_id"]
		and is_equal_approx(float(_chamber(overlap, 0)["duration"]), float(first_task["duration"])),
		"Expansion changed primary task identity or captured duration")
	_check(float(_chamber(overlap, 0)["remaining"]) < float(first_task["remaining"]) - 2.5,
		"Expansion restarted the primary timer instead of preserving remaining time")
	_check(overlap.organ.get_digestion_snapshot()["active_count"] == 2,
		"Ready second chamber did not claim the waiting input")
	evidence.append({
		"case": "actual_expansion_overlap", "elapsed": elapsed,
		"duration": first_task["duration"],
		"primary_remaining_before": first_task["remaining"],
		"primary_remaining_after": _chamber(overlap, 0)["remaining"],
		"primary_task_preserved": _chamber(overlap, 0)["task_id"] == first_task["task_id"],
	})
	_test_independent_ownership_and_capacity(parallel)
	_test_value_bounds_and_fifo(values, oversize)
	_test_reentrant_second_completion(reentrant)
	_test_reentrant_settlement_and_refeed(refeed)
	_test_reentrant_reset(reset_during_completion)
	_test_stop_reset_and_stale_callbacks(stop)
	_test_capability_downgrade(downgrade)
	await _test_remove_and_reenter(removed)
	await _test_remove_during_completion(remove_during_completion)
	_test_expansion_reset_identity()
	await _test_actual_same_frame_completion(actual)
	await _test_queue_free_during_publication()
	_free_fixtures()
	await process_frame
	await process_frame
	_check(root.get_child_count() == initial_children, "Parallel tests left fixture nodes in the tree")
	print("PARALLEL_DIGESTION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "evidence": evidence,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _new_fixture(mature: bool, duration: float = 1000.0) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.host = Node2D.new()
	_hosts.append(weakref(fixture.host))
	root.add_child(fixture.host)
	fixture.progress = ColonyProgress.new()
	fixture.host.add_child(fixture.progress)
	fixture.capabilities = ColonyCapabilities.new()
	fixture.capabilities.colony_progress = fixture.progress
	fixture.host.add_child(fixture.capabilities)
	if mature:
		_mature(fixture)
	fixture.organ = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	var primary: Timer = fixture.organ.get_node("DigestTimer") as Timer
	_check(is_equal_approx(primary.wait_time, 1.5) and primary.one_shot
		and primary.process_callback == Timer.TIMER_PROCESS_PHYSICS,
		"Scene changed the original primary timer defaults")
	primary.wait_time = duration
	fixture.organ.colony_capabilities = fixture.capabilities
	fixture.organ.digestion_started.connect(func(
		task_id: String, chamber_id: int, input_id: String, nutrition: int
	) -> void:
		fixture.starts.append({
			"task_id": task_id, "chamber_id": chamber_id, "input_id": input_id, "nutrition": nutrition,
		})
		_check_bounds(fixture.organ, "Started callback")
	)
	fixture.organ.digestion_completed.connect(func(
		task_id: String, chamber_id: int, product_id: String, nutrition: int
	) -> void:
		fixture.completions.append({
			"task_id": task_id, "chamber_id": chamber_id, "product_id": product_id,
			"nutrition": nutrition, "physics_frame": Engine.get_physics_frames(),
		})
		_check_bounds(fixture.organ, "Completed callback")
	)
	fixture.organ.product_created.connect(func(product_id: String, nutrition: int) -> void:
		fixture.creations.append({"product_id": product_id, "nutrition": nutrition})
	)
	fixture.organ.digested.connect(func(nutrition: int) -> void: fixture.digestions.append(nutrition))
	fixture.organ.inventory_changed.connect(func(queued: int, incoming: int) -> void:
		fixture.inventories.append({"queued": queued, "incoming": incoming})
		_check(queued == fixture.organ.get_queued_count() and incoming == fixture.organ.incoming_remains,
			"Inventory notification published stale ownership counts")
		_check_bounds(fixture.organ, "Inventory callback")
	)
	fixture.organ.output_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.outputs.append(snapshot.duplicate(true))
		_check_bounds(fixture.organ, "Output callback")
	)
	fixture.organ.digestion_changed.connect(func(snapshot: Dictionary) -> void:
		fixture.changes.append(snapshot.duplicate(true))
		_check_snapshot(snapshot, "Structural callback")
	)
	fixture.host.add_child(fixture.organ)
	if mature:
		fixture.expansion_callback = _timer_callback(fixture.organ.chamber_expansion_timer)
	return fixture


func _mature(fixture: Fixture) -> void:
	_check(fixture.progress.record_arrival("unit_maturity", ColonyProgress.MATURE_THRESHOLD),
		"Unit capability fixture could not reach maturity")


func _feed(fixture: Fixture, nutrition: int) -> void:
	var reserved: bool = fixture.organ.reserve_remains()
	_check(reserved, "Valid intake could not reserve a slot")
	if reserved:
		_check(fixture.organ.complete_delivery(nutrition), "Reserved input was not accepted")
		fixture.admitted_nutrition += nutrition


func _chamber(fixture: Fixture, chamber_id: int) -> Dictionary:
	var chambers: Array = fixture.organ.get_digestion_snapshot()["chambers"]
	return chambers[chamber_id]


func _timer_callback(timer: Timer) -> Callable:
	var connections: Array = timer.timeout.get_connections()
	_check(connections.size() == 1, "Active timer did not have exactly one captured callback")
	if connections.is_empty():
		return Callable()
	var callback: Callable = connections[0]["callable"]
	_check(callback.get_method() != &"_on_digest_timer_timeout",
		"Real timer connected the unversioned legacy wrapper")
	return callback


func _complete(callback: Callable) -> void:
	_check(callback.is_valid(), "Saved task callback is unavailable")
	if callback.is_valid():
		callback.call()


func _settle(fixture: Fixture, product_id: String, claim_id: String = "") -> void:
	var nutrition: int = 0
	for product: Dictionary in fixture.organ.get_output_products():
		if product["product_id"] == product_id:
			nutrition = int(product["nutrition"])
	_check(nutrition > 0 and fixture.organ.settle_output_product(product_id, claim_id),
		"Unit settlement did not remove the owned product")
	fixture.settled_nutrition += nutrition


func _check_snapshot(snapshot: Dictionary, context: String) -> void:
	var chambers: Array = snapshot["chambers"]
	_check(chambers.size() == 2, context + ": snapshot omitted a chamber")
	var active: int = 0
	var claimed_inputs: Dictionary = {}
	var task_ids: Dictionary = {}
	for index: int in range(chambers.size()):
		var chamber: Dictionary = chambers[index]
		_check(chamber["chamber_id"] == index, context + ": chamber order changed")
		_check(float(chamber["progress"]) >= 0.0 and float(chamber["progress"]) <= 1.0
			and float(chamber["remaining"]) >= 0.0,
			context + ": chamber progress or remaining time was outside its range")
		var task_id: String = chamber["task_id"]
		if not task_id.is_empty():
			active += 1
			var input_id: String = chamber["input_id"]
			_check(not input_id.is_empty() and not task_ids.has(task_id) and not claimed_inputs.has(input_id),
				context + ": two tasks owned the same identity or input")
			_check(int(chamber["nutrition"]) == int(chamber["reserved_nutrition"]),
				context + ": active task did not reserve its exact nutrition")
			task_ids[task_id] = true
			claimed_inputs[input_id] = true
	_check(active == int(snapshot["active_count"])
		and int(snapshot["waiting_count"]) + active == int(snapshot["intake_count"]),
		context + ": waiting and active counts did not partition intake")
	_check(int(snapshot["intake_count"]) + int(snapshot["incoming_count"]) <= int(snapshot["capacity"]),
		context + ": intake plus incoming exceeded capacity")
	_check(int(snapshot["chamber_count"]) >= 1 and int(snapshot["chamber_count"]) <= 2
		and float(snapshot["expansion_progress"]) >= 0.0 and float(snapshot["expansion_progress"]) <= 1.0,
		context + ": expansion created an invalid chamber count or progress")


func _check_bounds(organ: DigestiveOrgan, context: String) -> void:
	var snapshot: Dictionary = organ.get_output_snapshot()
	_check(int(snapshot["count"]) + int(snapshot["reserved_count"]) <= 2,
		context + ": products plus reservations exceeded two")
	_check(int(snapshot["nutrition"]) + int(snapshot["reserved_nutrition"]) <= 20,
		context + ": nutrition plus reservations exceeded twenty")
	_check(int(snapshot["queued_count"]) + int(snapshot["in_transit_count"]) == int(snapshot["count"]),
		context + ": in-transit products were counted twice")
	var digestion: Dictionary = organ.get_digestion_snapshot()
	_check(int(snapshot["reserved_count"]) == int(digestion["active_count"]),
		context + ": output reservations and chamber task count disagree")


func _check_conservation(fixture: Fixture, context: String) -> void:
	_check(fixture.organ.get_queued_nutrition() + fixture.organ.get_output_nutrition()
		+ fixture.settled_nutrition == fixture.admitted_nutrition,
		context + ": active intake or return transit was lost or counted twice")
	_check(fixture.organ.get_output_nutrition() + fixture.settled_nutrition
		== fixture.organ.total_nutrition_produced,
		context + ": products did not conserve committed nutrition")
	_check_bounds(fixture.organ, context)


func _wait_for_expansion(fixtures: Array[Fixture]) -> void:
	var deadline: float = _now() + 7.0
	var all_ready: bool = false
	while _now() < deadline and not all_ready:
		all_ready = true
		for fixture: Fixture in fixtures:
			if fixture.organ.get_digestion_snapshot()["expansion_state"] != &"ready":
				all_ready = false
		if not all_ready:
			await physics_frame
	for fixture: Fixture in fixtures:
		_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 2,
			"Real three-second expansion did not unlock its second chamber")
		_check(fixture.organ.chamber_expansion_timer.timeout.get_connections().is_empty(),
			"Completed expansion retained its timer binding")


func _test_legacy_primary_and_intake() -> void:
	var fixture: Fixture = _new_fixture(false)
	_feed(fixture, 4)
	_feed(fixture, 6)
	var before: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(before["chamber_count"] == 1 and before["active_count"] == 1
		and before["waiting_count"] == 1 and fixture.organ.get_queued_count() == 2
		and fixture.organ.get_queued_nutrition() == 10,
		"Legacy counts stopped including the processing input")
	var first_callback: Callable = _timer_callback(fixture.organ.digest_timer)
	var first_task: Dictionary = _chamber(fixture, 0)
	fixture.organ._on_digest_timer_timeout()
	_check(fixture.organ.digested_count == 1 and fixture.organ.get_queued_nutrition() == 6,
		"Legacy manual adapter did not complete exactly the primary task")
	var next: Dictionary = _chamber(fixture, 0)
	_check(next["task_id"] != first_task["task_id"] and next["input_id"] != first_task["input_id"],
		"Successor task reused its predecessor's task or input identity")
	_complete(first_callback)
	_check(fixture.organ.digested_count == 1 and _chamber(fixture, 0)["task_id"] == next["task_id"],
		"Saved retired primary callback completed a successor task")
	_complete(_timer_callback(fixture.organ.digest_timer))
	_check(fixture.creations.size() == 2 and fixture.digestions.size() == 2
		and fixture.completions.size() == 2, "Legacy production events were missing or duplicated")
	_check_conservation(fixture, "Legacy primary adapter")
	_check(fixture.organ.reserve_remains(), "Invalid input fixture could not reserve")
	_check(not fixture.organ.complete_delivery(0) and fixture.organ.incoming_remains == 1,
		"Invalid input consumed its incoming reservation")
	_check(fixture.organ.cancel_reservation() and not fixture.organ.cancel_reservation(),
		"Reservation cancellation was not bounded")


func _test_reservation_lifecycle_compatibility() -> void:
	var removed: Fixture = _new_fixture(false)
	var removed_once: Array[bool] = [false]
	removed.organ.inventory_changed.connect(func(_queued: int, incoming: int) -> void:
		if incoming == 1 and not removed_once[0]:
			removed_once[0] = true
			removed.host.remove_child(removed.organ)
	)
	_check(removed.organ.reserve_remains() and removed.organ.incoming_remains == 1,
		"Receiver removal changed an already committed reservation into a failed reservation")
	_check(removed.organ.cancel_reservation() and removed.organ.incoming_remains == 0,
		"Caller could not cancel the reservation retained through receiver removal")
	removed.host.add_child(removed.organ)
	var reset: Fixture = _new_fixture(false)
	var reset_once: Array[bool] = [false]
	var replacement_reserved: Array[bool] = [false]
	reset.organ.inventory_changed.connect(func(_queued: int, incoming: int) -> void:
		if incoming == 1 and not reset_once[0]:
			reset_once[0] = true
			reset.organ.reset()
			replacement_reserved[0] = reset.organ.reserve_remains()
	)
	_check(not reset.organ.reserve_remains() and replacement_reserved[0]
		and reset.organ.incoming_remains == 1,
		"Reset confused an obsolete intake reservation with a replacement-cycle reservation")
	_check(reset.organ.cancel_reservation(), "Replacement-cycle reservation could not be cancelled")
	var freed: Fixture = _new_fixture(false)
	_feed(freed, 4)
	var old_task: Callable = _timer_callback(freed.organ.digest_timer)
	freed.organ.inventory_changed.connect(func(_queued: int, incoming: int) -> void:
		if incoming == 1:
			freed.organ.queue_free()
	)
	_check(not freed.organ.reserve_remains() and freed.organ.is_queued_for_deletion(),
		"Queued removal during intake reservation returned usable receiver ownership")
	_complete(old_task)
	_check(freed.creations.is_empty() and freed.completions.is_empty(),
		"Queued receiver deletion accepted a saved active task callback")
	await process_frame
	_check(not is_instance_valid(freed.organ) and not old_task.is_valid(),
		"Queued receiver deletion did not invalidate its instance and saved callback")


func _test_reservation_cleanup_notifications() -> void:
	var queued: Fixture = _new_fixture(true)
	_feed(queued, 4)
	var queued_task: Callable = _timer_callback(queued.organ.digest_timer)
	var queued_expansion: Callable = queued.expansion_callback
	_check(queued.organ.reserve_remains() and queued.organ.reserve_remains(),
		"Queued cleanup fixture could not establish its original reservations")
	var queued_history: Array[int] = []
	queued.organ.inventory_changed.connect(func(_count: int, incoming: int) -> void:
		queued_history.append(incoming)
	)
	queued.organ.queue_free()
	_check(queued.organ.cancel_reservation() and queued.organ.cancel_reservation()
		and not queued.organ.cancel_reservation() and queued_history == [1, 0],
		"Deleting receiver did not publish each committed reservation cleanup exactly once")
	_complete(queued_task)
	_complete(queued_expansion)
	_check(queued.organ.digested_count == 0 and queued.organ.get_output_count() == 0
		and queued.organ.get_queued_nutrition() == 4
		and queued.organ.get_digestion_snapshot()["chamber_count"] == 1
		and queued.creations.is_empty() and queued.completions.is_empty(),
		"Cleanup notification allowed obsolete task, expansion or production callbacks")
	await process_frame
	_check(not is_instance_valid(queued.organ) and not queued_task.is_valid()
		and not queued_expansion.is_valid() and not queued_history.is_empty()
		and queued_history.back() == 0,
		"Deleting receiver failed to retain its final cleanup notification")

	var exited: Fixture = _new_fixture(false)
	_feed(exited, 5)
	var exited_task: Callable = _timer_callback(exited.organ.digest_timer)
	_check(exited.organ.reserve_remains(), "Exit cleanup fixture could not reserve intake")
	var exited_history: Array[int] = []
	exited.organ.inventory_changed.connect(func(_count: int, incoming: int) -> void:
		exited_history.append(incoming)
	)
	var cleanup_once: Array[bool] = [false]
	exited.organ.tree_exiting.connect(func() -> void:
		if not cleanup_once[0]:
			cleanup_once[0] = true
			_check(exited.organ.cancel_reservation(), "Tree-exit cleanup could not cancel its original reservation")
	)
	exited.host.remove_child(exited.organ)
	_check(cleanup_once[0] and exited_history == [0] and exited.organ.incoming_remains == 0,
		"Tree-exiting receiver suppressed its final inventory cleanup notification")
	_complete(exited_task)
	_check(exited.organ.get_output_count() == 0 and exited.organ.get_queued_nutrition() == 5,
		"Exit cleanup resumed an obsolete task or lost retained intake")
	exited.host.add_child(exited.organ)
	await process_frame
	_complete(exited_task)
	_check(exited.organ.digested_count == 0,
		"Cleanup notification weakened saved-task isolation after reentry")
	_complete(_timer_callback(exited.organ.digest_timer))
	_check_conservation(exited, "Exit cleanup followed by fresh task")

	var reentrant: Fixture = _new_fixture(false)
	_feed(reentrant, 6)
	var reentrant_task: Callable = _timer_callback(reentrant.organ.digest_timer)
	var reentrant_history: Array[int] = []
	var cancelled_once: Array[bool] = [false]
	reentrant.organ.inventory_changed.connect(func(_count: int, incoming: int) -> void:
		reentrant_history.append(incoming)
		if incoming == 1 and not cancelled_once[0]:
			cancelled_once[0] = true
			reentrant.organ.queue_free()
			_check(reentrant.organ.cancel_reservation(), "Reentrant deletion could not cancel intake")
	)
	_check(not reentrant.organ.reserve_remains() and cancelled_once[0]
		and reentrant_history == [1, 0] and reentrant.organ.incoming_remains == 0,
		"Pending cleanup notification was lost inside the current inventory publication")
	_complete(reentrant_task)
	_check(reentrant.organ.digested_count == 0 and reentrant.creations.is_empty()
		and reentrant.completions.is_empty(),
		"Reentrant cleanup published obsolete production")
	await process_frame
	_check(not is_instance_valid(reentrant.organ) and not reentrant_task.is_valid(),
		"Reentrant cleanup retained a deleting receiver or callback")
	evidence.append({
		"case": "reservation_cleanup_during_receiver_lifecycle",
		"queued_history": queued_history, "exit_history": exited_history,
		"reentrant_history": reentrant_history, "obsolete_production": 0,
	})


func _test_expansion_binding(fixture: Fixture, first_task: Dictionary) -> void:
	var before: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(before["expansion_state"] == &"expanding" and before["chamber_count"] == 1,
		"Capability maturity did not start a single-chamber expansion")
	_complete(fixture.expansion_callback)
	_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 1,
		"Calling a current expansion callback early bypassed its duration")
	for repeat: int in range(3):
		fixture.organ.configure_capabilities(fixture.capabilities)
		fixture.progress.stage_changed.emit(ColonyProgress.Stage.EXPANDED, ColonyProgress.Stage.MATURE)
	var after: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(_timer_callback(fixture.organ.chamber_expansion_timer) == fixture.expansion_callback
		and float(after["expansion_remaining"]) <= float(before["expansion_remaining"]) + 0.01,
		"Repeated capability binding or notification restarted expansion")
	_check(fixture.progress.stage_changed.get_connections().size() == 1,
		"Repeated capability binding duplicated stage observers")
	_check(_chamber(fixture, 0)["task_id"] == first_task["task_id"]
		and fixture.organ.get_output_snapshot()["reserved_count"] == 1,
		"Expansion changed primary ownership or prematurely reserved a second output")


func _test_independent_ownership_and_capacity(fixture: Fixture) -> void:
	for nutrition: int in [4, 6, 3, 7]:
		_feed(fixture, nutrition)
	var snapshot: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(snapshot["active_count"] == 2 and snapshot["waiting_count"] == 2
		and snapshot["intake_count"] == 4 and fixture.organ.get_queued_nutrition() == 20,
		"Dual task ownership changed legacy intake capacity or nutrition")
	_check(not fixture.organ.reserve_remains(), "Active inputs did not consume intake capacity")
	var first: Dictionary = _chamber(fixture, 0)
	var second: Dictionary = _chamber(fixture, 1)
	_check(first["nutrition"] == 4 and second["nutrition"] == 6
		and first["task_id"] != second["task_id"] and first["input_id"] != second["input_id"],
		"Dual chambers did not claim distinct FIFO inputs")
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var inventories_before: int = fixture.inventories.size()
	var outputs_before: int = fixture.outputs.size()
	_complete(secondary)
	_check(_chamber(fixture, 0)["task_id"] == first["task_id"]
		and fixture.organ.get_queued_nutrition() == 14 and fixture.organ.get_output_nutrition() == 6,
		"Secondary completion removed or restarted the primary input")
	_complete(primary)
	_complete(primary)
	_complete(secondary)
	_check(fixture.organ.digested_count == 2 and fixture.organ.get_waiting_count() == 2
		and fixture.organ.get_output_count() == 2 and fixture.organ.get_output_nutrition() == 10,
		"Same-frame saved callbacks duplicated products or exceeded output capacity")
	_check(fixture.inventories.size() - inventories_before == 2
		and fixture.outputs.size() - outputs_before == 2 and fixture.creations.size() == 2
		and fixture.digestions.size() == 2 and fixture.completions.size() == 2,
		"A commit did not publish its legacy and completion events exactly once")
	var products: Array[Dictionary] = fixture.organ.get_output_products()
	_check(products[0]["task_id"] == second["task_id"] and products[0]["input_id"] == second["input_id"]
		and products[0]["chamber_id"] == 1 and products[1]["task_id"] == first["task_id"],
		"Product metadata did not preserve its immutable task/input/chamber owner")
	_check(fixture.organ.claim_output_product(products[0]["product_id"], "return_a")
		and not fixture.organ.claim_output_product(products[0]["product_id"], "return_b"),
		"One product accepted duplicate return claims")
	_check(fixture.organ.get_output_snapshot()["in_transit_count"] == 1
		and fixture.organ.get_output_snapshot()["reserved_count"] == 0,
		"Dispatch freed an output slot before actual settlement")
	_check(not fixture.organ.settle_output_product(products[0]["product_id"])
		and not fixture.organ.settle_output_product(products[0]["product_id"], "wrong"),
		"Invalid settlement released a claimed product")
	_check(fixture.organ.return_output_product(products[0]["product_id"], "return_a")
		and not fixture.organ.return_output_product(products[0]["product_id"], "return_a"),
		"Returning a claim was not exactly once")
	_settle(fixture, products[0]["product_id"])
	_check(_chamber(fixture, 0)["nutrition"] == 3 and fixture.organ.get_waiting_count() == 1,
		"Actual settlement did not resume the FIFO waiting head")
	_complete(primary)
	_check(_chamber(fixture, 0)["nutrition"] == 3,
		"Old callback completed a task created after settlement")
	_check_conservation(fixture, "Distinct parallel ownership")
	var copied: Dictionary = fixture.organ.get_digestion_snapshot()
	copied["chambers"][0]["nutrition"] = 999
	copied["chambers"].clear()
	products[1]["nutrition"] = 999
	_check(_chamber(fixture, 0)["nutrition"] == 3 and fixture.organ.get_output_nutrition() == 4,
		"Public snapshots exposed mutable authoritative ownership")


func _test_value_bounds_and_fifo(values: Fixture, oversize: Fixture) -> void:
	_feed(values, 12)
	_feed(values, 9)
	_check(values.organ.get_digestion_snapshot()["active_count"] == 1
		and values.organ.get_output_snapshot()["reserved_nutrition"] == 12
		and _chamber(values, 1)["state"] == &"output_full",
		"Second chamber reserved twelve plus nine nutrition")
	_complete(_timer_callback(values.organ.digest_timer))
	var product: Dictionary = values.organ.get_output_products()[0]
	_check(values.organ.get_output_snapshot()["wait_reason"] == &"output_full"
		and values.organ.get_output_snapshot()["reserved_count"] == 0,
		"Committed output bypassed the exact nutrition bound")
	_check(values.organ.claim_output_product(product["product_id"], "value_return"),
		"Value-bound output could not be claimed")
	_check(values.organ.get_digestion_snapshot()["active_count"] == 0,
		"Claiming output prematurely released its nutrition capacity")
	_settle(values, product["product_id"], "value_return")
	_check(_chamber(values, 0)["nutrition"] == 9, "Settlement did not admit the value-blocked input")
	_complete(_timer_callback(values.organ.digest_timer))
	_settle(values, values.organ.get_output_products()[0]["product_id"])
	_feed(values, 20)
	_check(values.organ.get_output_snapshot()["reserved_nutrition"] == 20,
		"Exact twenty-nutrition input was incorrectly blocked")
	_check_conservation(values, "Exact value reservation")
	_feed(oversize, 21)
	_feed(oversize, 4)
	_check(oversize.organ.get_digestion_snapshot()["active_count"] == 0
		and oversize.organ.get_waiting_count() == 2
		and _chamber(oversize, 0)["state"] == &"output_too_large"
		and _chamber(oversize, 1)["state"] == &"output_too_large",
		"Oversized FIFO head was skipped by a parallel chamber")
	oversize.organ._on_digest_timer_timeout()
	_check(oversize.organ.digested_count == 0 and oversize.organ.get_queued_nutrition() == 25,
		"Unreserved oversized input produced a product")
	_check_conservation(oversize, "Oversized FIFO head")


func _test_reentrant_second_completion(fixture: Fixture) -> void:
	_feed(fixture, 5)
	_feed(fixture, 7)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var called: Array[bool] = [false]
	fixture.organ.inventory_changed.connect(func(_queued: int, _incoming: int) -> void:
		if not called[0] and fixture.organ.digested_count == 1:
			called[0] = true
			_complete(secondary)
	)
	_complete(primary)
	_check(called[0] and fixture.organ.digested_count == 2 and fixture.organ.get_output_nutrition() == 12,
		"Completion publication swallowed a valid reentrant second-chamber completion")
	_check(fixture.completions.size() == 2 and fixture.creations.size() == 2
		and fixture.digestions.size() == 2, "Reentrant completions lost or duplicated events")
	_complete(primary)
	_complete(secondary)
	_check(fixture.organ.digested_count == 2, "Duplicate reentrant callbacks committed again")
	_check_conservation(fixture, "Reentrant second completion")
	evidence.append({"case": "reentrant_independent_completion", "products": 2, "nutrition": 12})


func _test_reentrant_settlement_and_refeed(fixture: Fixture) -> void:
	_feed(fixture, 5)
	_feed(fixture, 7)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var handled: Array[bool] = [false]
	fixture.organ.product_created.connect(func(product_id: String, _nutrition: int) -> void:
		if not handled[0]:
			handled[0] = true
			_check(fixture.organ.claim_output_product(product_id, "sync_receipt"),
				"Reentrant product listener could not claim committed output")
			_settle(fixture, product_id, "sync_receipt")
			_feed(fixture, 3)
			_complete(secondary)
	)
	_complete(primary)
	_check(handled[0] and fixture.completions.size() == 2 and fixture.creations.size() == 2
		and fixture.organ.digested_count == 2 and fixture.organ.get_queued_nutrition() == 3,
		"Reentrant claim/settle/refeed corrupted independent completion ownership")
	_check(_chamber(fixture, 0)["nutrition"] == 3
		and fixture.organ.get_output_snapshot()["reserved_nutrition"] == 3,
		"Reentrant refed input did not retain its own reservation")
	_check_conservation(fixture, "Synchronous receipt and refeed")


func _test_reentrant_reset(fixture: Fixture) -> void:
	_feed(fixture, 5)
	_feed(fixture, 7)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var old_generation: int = fixture.organ.get_digestion_snapshot()["generation"]
	var reset_once: Array[bool] = [false]
	fixture.organ.inventory_changed.connect(func(_queued: int, _incoming: int) -> void:
		if not reset_once[0] and fixture.organ.digested_count == 1:
			reset_once[0] = true
			fixture.organ.reset()
			fixture.admitted_nutrition = 0
			fixture.settled_nutrition = 0
			_feed(fixture, 3)
	)
	_complete(primary)
	_complete(secondary)
	_check(reset_once[0] and fixture.organ.get_digestion_snapshot()["generation"] > old_generation
		and fixture.creations.is_empty() and fixture.completions.is_empty() and fixture.digestions.is_empty(),
		"Reset during publication emitted obsolete production or completion events")
	_check(fixture.organ.get_output_count() == 0 and fixture.organ.get_queued_nutrition() == 3
		and fixture.organ.get_digestion_snapshot()["chamber_count"] == 1,
		"Reentrant reset lost refed intake or immediately re-expanded on old maturity")
	_complete(_timer_callback(fixture.organ.digest_timer))
	_check(fixture.creations.size() == 1 and fixture.completions.size() == 1
		and fixture.organ.total_nutrition_produced == 3,
		"New generation could not publish its independent valid completion")
	_check_conservation(fixture, "Reset then refeed")


func _test_stop_reset_and_stale_callbacks(fixture: Fixture) -> void:
	_feed(fixture, 4)
	_feed(fixture, 6)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var old_primary: Dictionary = _chamber(fixture, 0)
	var old_secondary: Dictionary = _chamber(fixture, 1)
	_complete(primary)
	var old_product: Dictionary = fixture.organ.get_output_products()[0]
	fixture.organ.stop_processing()
	_complete(primary)
	_complete(secondary)
	_complete(fixture.expansion_callback)
	fixture.organ.configure_capabilities(fixture.capabilities)
	fixture.progress.stage_changed.emit(ColonyProgress.Stage.EXPANDED, ColonyProgress.Stage.MATURE)
	var stopped: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(not stopped["enabled"] and stopped["active_count"] == 0 and stopped["waiting_count"] == 1
		and fixture.organ.get_output_nutrition() == 4 and fixture.organ.get_queued_nutrition() == 6,
		"Stop discarded intake/products or retained task reservations")
	_check(fixture.organ.digest_timer.timeout.get_connections().is_empty()
		and fixture.organ.second_digest_timer.timeout.get_connections().is_empty()
		and fixture.organ.chamber_expansion_timer.timeout.get_connections().is_empty(),
		"Stop retained timer bindings")
	_check(not fixture.organ.reserve_remains() and fixture.organ.get_output_snapshot()["reserved_count"] == 0
		and stopped["expansion_state"] == &"locked",
		"Capability notification restarted stopped processing")
	_check_conservation(fixture, "Stopped cycle")
	fixture.organ.reset()
	fixture.admitted_nutrition = 0
	fixture.settled_nutrition = 0
	_check(fixture.organ.get_digestion_snapshot()["enabled"]
		and fixture.organ.get_digestion_snapshot()["chamber_count"] == 1
		and fixture.organ.get_queued_count() == 0 and fixture.organ.get_output_count() == 0,
		"Reset did not start a clean locked single-chamber cycle")
	_feed(fixture, 4)
	var new_task: Dictionary = _chamber(fixture, 0)
	_check(new_task["task_id"] != old_primary["task_id"] and new_task["task_id"] != old_secondary["task_id"]
		and new_task["input_id"] != old_primary["input_id"] and new_task["input_id"] != old_secondary["input_id"],
		"Reset reused task or input serial identities")
	_complete(primary)
	_complete(secondary)
	_check(fixture.organ.digested_count == 0, "Old callback completed new-round intake")
	_complete(_timer_callback(fixture.organ.digest_timer))
	_check(fixture.organ.get_output_products()[0]["product_id"] != old_product["product_id"],
		"Reset reused an existing product ID")
	fixture.organ.configure_capabilities(fixture.capabilities)
	_check(fixture.organ.get_digestion_snapshot()["expansion_state"] == &"expanding",
		"Explicit configuration after reset did not refresh mature capability")
	_complete(fixture.expansion_callback)
	_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 1,
		"Retired expansion callback completed a new expansion")
	_check_conservation(fixture, "Reset serial isolation")


func _test_capability_downgrade(fixture: Fixture) -> void:
	_feed(fixture, 5)
	_feed(fixture, 6)
	var primary_task: Dictionary = _chamber(fixture, 0)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var cancelled: Dictionary = _chamber(fixture, 1)
	fixture.progress.reset()
	_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 1
		and fixture.organ.get_digestion_snapshot()["waiting_count"] == 1
		and fixture.organ.get_output_snapshot()["reserved_nutrition"] == 5,
		"Capability downgrade did not release only the second task reservation")
	_check(_chamber(fixture, 0)["task_id"] == primary_task["task_id"]
		and is_equal_approx(float(_chamber(fixture, 0)["remaining"]), float(primary_task["remaining"])),
		"Capability downgrade restarted primary work")
	_complete(secondary)
	_check(fixture.organ.digested_count == 0, "Cancelled secondary callback still committed")
	_complete(primary)
	var resumed: Dictionary = _chamber(fixture, 0)
	_check(resumed["input_id"] == cancelled["input_id"] and resumed["task_id"] != cancelled["task_id"]
		and resumed["nutrition"] == 6,
		"Cancelled input was lost instead of being reclaimed with a fresh task ID")
	_complete(secondary)
	_complete(_timer_callback(fixture.organ.digest_timer))
	_check(fixture.organ.digested_count == 2 and fixture.organ.get_output_nutrition() == 11,
		"Downgrade replay duplicated or lost accepted inputs")
	_check_conservation(fixture, "Capability downgrade")


func _test_remove_and_reenter(fixture: Fixture) -> void:
	_feed(fixture, 5)
	_feed(fixture, 7)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var previous: Dictionary = fixture.organ.get_digestion_snapshot()
	var stage_connections: Array = fixture.progress.stage_changed.get_connections()
	var stage_callback: Callable = stage_connections[0]["callable"]
	fixture.host.remove_child(fixture.organ)
	_check(fixture.progress.stage_changed.get_connections().is_empty()
		and fixture.organ.get_output_snapshot()["reserved_count"] == 0
		and fixture.organ.get_waiting_count() == 2,
		"Exit retained observation/bindings or lost active intake")
	_complete(primary)
	_complete(secondary)
	stage_callback.call(ColonyProgress.Stage.EXPANDED, ColonyProgress.Stage.MATURE)
	fixture.host.add_child(fixture.organ)
	await process_frame
	var current: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(current["generation"] > previous["generation"] and current["active_count"] == 2
		and _chamber(fixture, 0)["task_id"] != previous["chambers"][0]["task_id"]
		and _chamber(fixture, 1)["task_id"] != previous["chambers"][1]["task_id"],
		"Reentry did not reclaim retained input with fresh task identities")
	_complete(primary)
	_complete(secondary)
	_check(fixture.organ.digested_count == 0, "Removed-instance callbacks completed new reentry tasks")
	_complete(_timer_callback(fixture.organ.digest_timer))
	_complete(_timer_callback(fixture.organ.second_digest_timer))
	_check(fixture.completions.size() == 2 and fixture.organ.get_output_nutrition() == 12,
		"Reentry could not independently finish both retained inputs")
	_check_conservation(fixture, "Remove/readd isolation")


func _test_remove_during_completion(fixture: Fixture) -> void:
	_feed(fixture, 4)
	_feed(fixture, 6)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var secondary: Callable = _timer_callback(fixture.organ.second_digest_timer)
	var removed_once: Array[bool] = [false]
	fixture.organ.inventory_changed.connect(func(_queued: int, _incoming: int) -> void:
		if not removed_once[0] and fixture.organ.digested_count == 1:
			removed_once[0] = true
			fixture.host.remove_child(fixture.organ)
			fixture.host.add_child(fixture.organ)
	)
	_complete(primary)
	_complete(secondary)
	_check(removed_once[0] and fixture.creations.is_empty() and fixture.completions.is_empty()
		and fixture.organ.get_output_nutrition() == 4 and fixture.organ.get_queued_nutrition() == 6,
		"Removal during completion published obsolete events or lost committed ownership")
	await process_frame
	_check(fixture.organ.get_digestion_snapshot()["active_count"] == 1,
		"Removal during publication failed to resume retained input")
	_complete(_timer_callback(fixture.organ.digest_timer))
	_check(fixture.creations.size() == 1 and fixture.completions.size() == 1
		and fixture.organ.digested_count == 2,
		"Fresh callback after publication-time removal was lost")
	_check_conservation(fixture, "Reentrant removal")


func _test_expansion_reset_identity() -> void:
	var fixture: Fixture = _new_fixture(true)
	var old_expansion: Callable = fixture.expansion_callback
	fixture.organ.reset()
	_complete(old_expansion)
	_check(fixture.organ.get_digestion_snapshot()["expansion_state"] == &"locked"
		and fixture.organ.chamber_expansion_timer.timeout.get_connections().is_empty(),
		"Reset restarted expansion on the old progress object")
	fixture.organ.configure_capabilities(fixture.capabilities)
	var new_expansion: Callable = _timer_callback(fixture.organ.chamber_expansion_timer)
	_check(new_expansion.get_bound_arguments() != old_expansion.get_bound_arguments(),
		"New expansion reused retired generation/expansion callback identity")
	_complete(old_expansion)
	_complete(new_expansion)
	_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 1
		and fixture.organ.get_digestion_snapshot()["expansion_state"] == &"expanding",
		"Old or early expansion callback unlocked the second chamber")
	fixture.progress.reset()
	_complete(new_expansion)
	_check(fixture.organ.get_digestion_snapshot()["expansion_state"] == &"locked"
		and fixture.organ.chamber_expansion_timer.timeout.get_connections().is_empty(),
		"Expansion downgrade retained an active timer or accepted its saved callback")


func _test_actual_same_frame_completion(fixture: Fixture) -> void:
	_feed(fixture, 4)
	_feed(fixture, 6)
	var primary: Dictionary = _chamber(fixture, 0)
	var secondary: Dictionary = _chamber(fixture, 1)
	_check(is_equal_approx(float(primary["duration"]), 1.5)
		and is_equal_approx(float(secondary["duration"]), 1.5),
		"Second chamber changed the original primary digestion duration")
	var before: float = _now()
	var deadline: float = _now() + 4.0
	while fixture.completions.size() < 2 and _now() < deadline:
		await physics_frame
	_check(fixture.completions.size() == 2 and fixture.creations.size() == 2
		and fixture.digestions.size() == 2 and fixture.organ.digested_count == 2,
		"Real same-frame timers did not complete each task exactly once")
	var same_frame: bool = fixture.completions.size() == 2 and (
		fixture.completions[0]["physics_frame"] == fixture.completions[1]["physics_frame"]
	)
	_check(same_frame, "Two same-frame task starts did not complete in the same physics frame")
	_check(fixture.organ.digest_timer.timeout.get_connections().is_empty()
		and fixture.organ.second_digest_timer.timeout.get_connections().is_empty(),
		"Real completion did not disconnect retired task bindings")
	fixture.organ.configure_capabilities(fixture.capabilities)
	_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 2
		and fixture.organ.chamber_expansion_timer.is_stopped(),
		"Ready capability refresh started a third chamber or repeated expansion")
	_check_conservation(fixture, "Real parallel timers")
	evidence.append({
		"case": "actual_same_frame_timers", "duration": 1.5, "same_frame": same_frame,
		"elapsed": _now() - before,
		"products": fixture.organ.get_output_count(), "nutrition": fixture.organ.get_output_nutrition(),
	})


func _test_queue_free_during_publication() -> void:
	var fixture: Fixture = _new_fixture(false)
	_feed(fixture, 4)
	var primary: Callable = _timer_callback(fixture.organ.digest_timer)
	var freed_once: Array[bool] = [false]
	fixture.organ.inventory_changed.connect(func(_queued: int, _incoming: int) -> void:
		if not freed_once[0] and fixture.organ.digested_count == 1:
			freed_once[0] = true
			fixture.organ.queue_free()
	)
	_complete(primary)
	_check(freed_once[0] and fixture.organ.is_queued_for_deletion()
		and fixture.creations.is_empty() and fixture.completions.is_empty(),
		"Queued deletion during publication emitted obsolete production events")
	_complete(primary)
	_check(fixture.organ.digested_count == 1, "Queued deletion allowed duplicate task commitment")
	await process_frame
	_check(not is_instance_valid(fixture.organ) and not primary.is_valid()
		and fixture.creations.is_empty() and fixture.completions.is_empty(),
		"Queued deletion during publication retained a live owner or obsolete callbacks")


func _free_fixtures() -> void:
	for reference: WeakRef in _hosts:
		var host: Variant = reference.get_ref()
		if is_instance_valid(host):
			host.free()
	_hosts.clear()
