extends SceneTree
## 大型尸骸的真实关卡验收：分批采集、运输、消化、绿色回流、资源守恒和 R 重启。
## 只推进场景帧和正常计时器；首次生产与入账不使用伪造回调或直接注入营养。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const SOURCE_NUTRITION: int = 80
const BATCH_NUTRITION: int = 10
const ORDINARY_NUTRITION: int = 4
const GROWTH_COST: int = 16
const GROWTH_TARGET: Vector2 = Vector2(1100, 400)
const SOURCE_POSITION: Vector2 = Vector2(1120, 440)
const POSITION_EPSILON: float = 0.05


## 首个覆盖候选仍与母核连通，仅拒绝其到胃囊的查询，模拟查询间路线变化。
class SelectiveNetwork:
	extends NetworkSystem

	var rejected_start: Node2D
	var rejected_end: Node2D
	var reject_as_invalid: bool = false

	func find_route(start: Node2D, end: Node2D) -> NetworkRoute:
		var route: NetworkRoute = super.find_route(start, end)
		if not reject_as_invalid and start == rejected_start and end == rejected_end:
			route.found = false
			route.segments.clear()
		return route

	# 6.4 新采集使用可用路线，候选失败替身保持相同拒绝条件。
	func find_available_route(start: Node2D, end: Node2D, units: int = 1) -> NetworkRoute:
		var route: NetworkRoute = super.find_available_route(start, end, units)
		if not reject_as_invalid and start == rejected_start and end == rejected_end:
			route.found = false
			route.segments.clear()
		return route

	func is_route_valid(route: NetworkRoute) -> bool:
		if reject_as_invalid and route != null and (
			route.start_node == rejected_start and route.end_node == rejected_end
		):
			return false
		return super.is_route_valid(route)


var checks: int = 0
var failures: Array[String] = []
var conservation_checks: int = 0
var milestones: Array[Dictionary] = []
var cycle_result: Dictionary = {}
var interruption_result: Dictionary = {}
var candidate_result: Dictionary = {}
var mixed_result: Dictionary = {}
var restart_result: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_complete_eighty_cycle()
	await _test_haul_interruption_and_recovery()
	await _test_competing_coverage_candidates()
	await _test_mixed_paid_expansion()
	await _test_restart_with_pending_packets()
	_check(root.get_child_count() == 0, "Teardown leaves no level or packet objects")
	print("CARCASS_CYCLE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures,
		"conservation_checks": conservation_checks, "milestones": milestones,
		"cycle": cycle_result, "interruption": interruption_result,
		"candidates": candidate_result, "mixed": mixed_result, "restart": restart_result,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _prepare_level(level: Node2D, mixed: bool = false) -> void:
	# 旧单执行器兼容夹具；正式 7.3 多实例路径由 multitip_construction_test 验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	level.carcass_demo_enabled = true
	level.expansion_demo_enabled = mixed
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/GrowthSupplySystem").auto_supply = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _stop_unrelated_timers(level: Node2D) -> void:
	level.enemy_spawner.stop_spawning()
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_level(mixed: bool = false) -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level, mixed)
	root.add_child(level)
	current_scene = level
	_stop_unrelated_timers(level)
	# 接收到胃囊后保留可观察窗口，仍由正常的 DigestTimer 完成生产。
	level.digestive_organ.digest_timer.wait_time = 1.0
	await _wait_frames(2)
	return level


func _remove_level(level: Node2D, evidence: Dictionary) -> void:
	evidence["observe_resources"] = false
	if current_scene == level:
		current_scene = null
	level.queue_free()
	await process_frame
	await process_frame


func _step() -> void:
	await physics_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for _frame: int in range(count):
		await _step()


func _source(level: Node2D) -> LargeCarcass:
	var source: LargeCarcass = level.get_node_or_null("World/Remains/LargeCarcass") as LargeCarcass
	_check(source != null, "Enabled demo contains the real LargeCarcass node")
	return source


func _sum_nutrition(records: Array) -> int:
	var total: int = 0
	for record: Dictionary in records:
		total += int(record["nutrition"])
	return total


func _observe(level: Node2D, source: LargeCarcass, label: String, mixed: bool = false) -> Dictionary:
	var evidence: Dictionary = {
		"label": label, "observe_resources": true, "mixed": mixed,
		"resource_id": source.get_resource_id(), "last_harvested": 0,
		"initial_core": int(level.mother_core.nutrition),
		"initial_resources": 0, "external_nutrition": ORDINARY_NUTRITION if mixed else 0,
		"shots": 0, "resource_events": [], "batches": {}, "production": [],
		"arrivals": [], "progress": [], "return_packets": {},
		"packet_arrivals": [], "packet_interruptions": [], "replayed_callbacks": 0,
		"exhausted_signals": 0,
	}
	evidence["initial_resources"] = int(_resource_snapshot(level, source, evidence)["total"])
	source.resources_changed.connect(func(snapshot: Dictionary) -> void:
		if not bool(evidence["observe_resources"]):
			return
		var events: Array = evidence["resource_events"]
		events.append(snapshot.duplicate())
		var harvested: int = int(snapshot["harvested_nutrition"])
		var phase: String = "source_status"
		if int(snapshot["reserved_nutrition"]) > 0:
			phase = "source_reserved"
		elif harvested > int(evidence["last_harvested"]):
			phase = "source_committed_%d" % harvested
		evidence["last_harvested"] = harvested
		# 批次先成为独立的隐藏尸块，提交扣源后才检查守恒；预留不另算资源。
		_checkpoint(level, source, evidence, phase, phase != "source_status"))
	source.exhausted.connect(func() -> void:
		evidence["exhausted_signals"] = int(evidence["exhausted_signals"]) + 1)
	level.get_node("World/Remains").child_entered_tree.connect(func(child: Node) -> void:
		if child is EnemyRemains and child.has_meta("carcass_batch_id"):
			_record_batch(child as EnemyRemains, level, source, evidence))
	level.get_node("World/RecoveryPackets").child_entered_tree.connect(func(child: Node) -> void:
		if child is RemainsPacket:
			_watch_packet(child as Node2D, level.recycling_system, level, source, evidence, "haul"))
	level.get_node("World/ReturnPackets").child_entered_tree.connect(func(child: Node) -> void:
		if child is NutrientPacket:
			var packet: NutrientPacket = child as NutrientPacket
			var product_id: String = String(packet.get_meta("return_product_id", ""))
			var tracked: Dictionary = evidence["return_packets"]
			tracked[product_id] = packet
			var body: Polygon2D = packet.get_node("Body") as Polygon2D
			var glow: Polygon2D = packet.get_node("Glow") as Polygon2D
			var trail: Line2D = packet.get_node("Trail") as Line2D
			_check(not product_id.is_empty() and packet.speed == 80.0,
				"%s uses the real default-speed return packet and product ID" % label)
			_check(body.color.g > body.color.r and body.color.g > body.color.b
				and glow.color.g > glow.color.r and glow.color.g > glow.color.b
				and trail.default_color.g > trail.default_color.r
				and trail.default_color.g > trail.default_color.b,
				"%s physically returns nutrition in the green packet scene" % label)
			_watch_packet(packet, level.nutrition_return_system, level, source, evidence, "return"))
	level.digestive_organ.product_created.connect(func(product_id: String, nutrition: int) -> void:
		var production: Array = evidence["production"]
		for previous: Dictionary in production:
			_check(String(previous["product_id"]) != product_id,
				"%s never creates the same product ID twice" % label)
		production.append({"product_id": product_id, "nutrition": nutrition}))
	level.digestive_organ.inventory_changed.connect(func(_queued: int, _incoming: int) -> void:
		if bool(evidence["observe_resources"]) and not mixed:
			# 接收通知也必须已完成营养所有权移交，隐藏原批次不能与队列各算一次。
			_checkpoint(level, source, evidence, "synchronous_stomach_inventory", false))
	level.mother_core.digestion_product_arrived.connect(func(product_id: String, nutrition: int) -> void:
		var tracked: Dictionary = evidence["return_packets"]
		var packet: Variant = tracked.get(product_id)
		var live: bool = is_instance_valid(packet)
		var point: Vector2 = packet.global_position if live else Vector2.ZERO
		_check(live and point.distance_to(level.mother_core.global_position) < POSITION_EPSILON,
			"%s credits only after its tracked green packet physically arrives at the core" % label)
		var arrivals: Array = evidence["arrivals"]
		for previous: Dictionary in arrivals:
			_check(String(previous["product_id"]) != product_id,
				"%s emits one actual receipt per unique product" % label)
		arrivals.append({
			"product_id": product_id, "nutrition": nutrition,
			"balance": int(level.mother_core.nutrition), "packet_live": live,
			"packet_position": point,
		}))
	level.colony_progress.progress_changed.connect(func(total: int, count: int) -> void:
		var progress: Array = evidence["progress"]
		progress.append({"total": total, "count": count}))
	for weapon: SporeWeapon in level.get_weapons():
		weapon.shot_fired.connect(func(_enemy: BasicEnemy) -> void:
			evidence["shots"] = int(evidence["shots"]) + 1)
	return evidence


func _record_batch(batch: EnemyRemains, level: Node2D, source: LargeCarcass, evidence: Dictionary) -> void:
	var batch_id: Variant = batch.get_meta("carcass_batch_id", "")
	var source_id: Variant = batch.get_meta("carcass_source_id", "")
	var request_id: Variant = batch.get_meta("carcass_request_id", "")
	_check(batch_id is String and source_id is String and request_id is String,
		"Materialized batch provenance consists of Strings")
	_check(not String(batch_id).is_empty() and not String(request_id).is_empty()
		and String(source_id) == source.get_resource_id(),
		"Materialized batch has a unique batch/request ID and its real source ID")
	var reserved: int = source.get_reservation_nutrition(String(request_id))
	_check(not batch.visible and not batch.is_available() and not batch.is_queued_for_deletion()
		and batch.nutrition_value == 0 and reserved == BATCH_NUTRITION,
		"A claimed zero-value draft enters the container while its ten nutrition still belongs to the reserved source")
	var batches: Dictionary = evidence["batches"]
	_check(not batches.has(String(batch_id)), "Each committed batch is materialized exactly once")
	for previous: Dictionary in batches.values():
		_check(String(previous["request_id"]) != String(request_id),
			"Independent batches never share a source request ID")
	batches[String(batch_id)] = {
		"batch_id": String(batch_id), "source_id": String(source_id),
		"request_id": String(request_id), "nutrition": reserved,
		"owner_instance_id": batch.get_instance_id(),
	}
	_checkpoint(level, source, evidence, "claimed_draft_before_source_commit")


func _packet_callbacks(packet: Node, owner: Node, signal_name: StringName) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in packet.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.get_object() == owner:
			callbacks.append(callback)
	return callbacks


func _replay_settled_callbacks(packet: Node2D, arrived: Array[Callable],
		interrupted: Array[Callable], evidence: Dictionary) -> void:
	for callback: Callable in arrived:
		if callback.is_valid():
			callback.call(packet)
			callback.call(packet)
			evidence["replayed_callbacks"] = int(evidence["replayed_callbacks"]) + 2
	for callback: Callable in interrupted:
		if callback.is_valid():
			callback.call(packet)
			callback.call(packet)
			evidence["replayed_callbacks"] = int(evidence["replayed_callbacks"]) + 2


func _watch_packet(packet: Node2D, owner: Node, level: Node2D, source: LargeCarcass,
		evidence: Dictionary, kind: String) -> void:
	var arrived: Array[Callable] = _packet_callbacks(packet, owner, &"arrived")
	var interrupted: Array[Callable] = _packet_callbacks(packet, owner, &"interrupted")
	_check(not arrived.is_empty() and not interrupted.is_empty(),
		"%s packet connects both real settlement callbacks before entering its container" % kind)
	# 观察者后连接；仅在系统完成一次真实到达/中断后重放，绝不伪造首次收入。
	packet.connect(&"arrived", func(finished: Node2D) -> void:
		var arrivals: Array = evidence["packet_arrivals"]
		arrivals.append({"kind": kind, "position": finished.global_position})
		var destination: Node2D = level.mother_core if kind == "return" else level.digestive_organ.get_parent()
		_check(finished.global_position.distance_to(destination.global_position) < POSITION_EPSILON,
			"%s packet finishes at its actual receiving node" % kind)
		_replay_settled_callbacks(finished, arrived, interrupted, evidence)
		if bool(evidence["observe_resources"]):
			_checkpoint(level, source, evidence, kind + "_settled_and_replayed"))
	packet.connect(&"interrupted", func(finished: Node2D) -> void:
		var interruptions: Array = evidence["packet_interruptions"]
		interruptions.append({"kind": kind, "position": finished.global_position})
		_replay_settled_callbacks(finished, arrived, interrupted, evidence)
		if bool(evidence["observe_resources"]):
			_checkpoint(level, source, evidence, kind + "_interrupted_and_replayed"))


func _resource_snapshot(level: Node2D, source: LargeCarcass, evidence: Dictionary) -> Dictionary:
	var remains_nutrition: int = 0
	for child: Node in level.get_node("World/Remains").get_children():
		# 隐藏的 claimed 尸块仍是搬运的唯一所有者；queue_free 尸块已转入胃囊。
		if child is EnemyRemains and not child.is_queued_for_deletion():
			remains_nutrition += child.nutrition_value
	var organ_nutrition: int = 0
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		organ_nutrition += organ.nutrition + organ.incoming_nutrition
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	var parts: Dictionary = {
		"source_remaining_including_reserved": source.get_remaining_nutrition(),
		"live_remains_including_claimed": remains_nutrition,
		"digestive_queue": int(level.digestive_organ.get_queued_nutrition()),
		# output 本身已包括返运在途；空间预留、搬运包和返运账本不能再加一份。
		"digestive_output_including_return_transit": int(level.digestive_organ.get_output_nutrition()),
		"core": int(level.mother_core.nutrition), "organs_and_incoming_supply": organ_nutrition,
		"growth_buffer": int(growth["buffered_nutrition"]),
		"growth_in_transit": int(level.growth_supply_system.get_in_transit_count()),
		"growth_consumed": int(growth["consumed_nutrition"]),
		"shots_consumed": int(evidence["shots"]) * SporeWeapon.SHOT_NUTRITION,
	}
	var total: int = 0
	for amount: int in parts.values():
		total += amount
	parts["total"] = total
	parts["actual_credited"] = _sum_nutrition(evidence["arrivals"])
	parts["resource_point_total"] = source.get_remaining_nutrition() + remains_nutrition + (
		int(level.digestive_organ.get_queued_nutrition()) + int(level.digestive_organ.get_output_nutrition())
		+ int(parts["actual_credited"])
	)
	return parts


func _checkpoint(level: Node2D, source: LargeCarcass, evidence: Dictionary,
		phase: String, remember: bool = true) -> void:
	var parts: Dictionary = _resource_snapshot(level, source, evidence)
	var label: String = "%s/%s" % [String(evidence["label"]), phase]
	conservation_checks += 1
	_check(int(parts["total"]) == int(evidence["initial_resources"]),
		"%s conserves the whole colony including paid growth and supply: %s" % [label, parts])
	_check(int(parts["resource_point_total"]) == SOURCE_NUTRITION + int(evidence["external_nutrition"]),
		"%s conserves remaining source + live corpse + digestion + output + actual receipts" % label)
	var snapshot: Dictionary = source.get_snapshot()
	_check(String(snapshot["resource_id"]) == String(evidence["resource_id"])
		and int(snapshot["total_nutrition"]) == SOURCE_NUTRITION
		and int(snapshot["remaining_nutrition"]) == source.get_remaining_nutrition()
		and int(snapshot["reserved_nutrition"]) == source.get_reserved_nutrition()
		and int(snapshot["available_nutrition"]) == source.get_available_nutrition()
		and int(snapshot["harvested_nutrition"]) == source.get_harvested_nutrition(),
		"%s exposes stable identity and the authoritative resource snapshot" % label)
	_check(source.get_remaining_nutrition() + source.get_harvested_nutrition() == SOURCE_NUTRITION
		and source.get_available_nutrition() + source.get_reserved_nutrition() == source.get_remaining_nutrition()
		and source.get_reserved_nutrition() >= 0 and source.get_available_nutrition() >= 0,
		"%s treats source reservations as included ownership rather than extra nutrition" % label)
	_check(source.is_exhausted() == (source.get_remaining_nutrition() == 0),
		"%s becomes exhausted only after all eighty nutrition is committed" % label)
	_check([&"out_of_field", &"no_route", &"capacity_full", &"ready", &"harvesting", &"exhausted"].has(
		StringName(snapshot["status"])), "%s uses a declared harvest status" % label)
	_check(int(evidence["shots"]) == 0 and level.get_node("World/Enemies").get_child_count() == 0
		and level.get_node("World/Projectiles").get_child_count() == 0,
		"%s excludes combat, enemy-created resources and firing income from this fixture" % label)
	var output: Dictionary = level.digestive_organ.get_output_snapshot()
	var returning: Dictionary = level.nutrition_return_system.get_return_snapshot()
	_check(int(output["count"]) + int(output["reserved_count"]) <= 2
		and int(output["nutrition"]) + int(output["reserved_nutrition"]) <= 20
		and int(output["reserved_count"]) >= 0 and int(output["reserved_nutrition"]) >= 0,
		"%s keeps two output slots / twenty nutrition including digestion space reservation" % label)
	_check(int(output["queued_count"]) + int(output["in_transit_count"]) == int(output["count"])
		and int(output["count"]) == level.digestive_organ.get_output_count()
		and int(output["nutrition"]) == level.digestive_organ.get_output_nutrition(),
		"%s partitions every outstanding output exactly once" % label)
	_check(int(returning["in_transit_count"]) == int(output["in_transit_count"])
		and int(returning["queued_count"]) == int(output["queued_count"])
		and int(returning["queued_nutrition"]) + int(returning["in_transit_nutrition"]) == int(output["nutrition"]),
		"%s return records reference stomach output instead of creating another resource copy" % label)
	_check(level.digestive_organ.get_queued_count() + level.digestive_organ.incoming_remains
		<= level.digestive_organ.capacity, "%s obeys stomach intake capacity" % label)
	var actual_credited: int = int(parts["actual_credited"])
	_check(level.colony_progress.get_total_recovered() == actual_credited
		and level.colony_progress.get_product_count() == evidence["arrivals"].size()
		and level.mother_core.get_received_product_count() == evidence["arrivals"].size(),
		"%s counts only unique physically arrived products as recovered income" % label)
	if not bool(evidence["mixed"]):
		_check(level.mother_core.nutrition == int(evidence["initial_core"]) + actual_credited,
			"%s has no core income before a real return receipt" % label)
	if remember:
		milestones.append({"phase": label, "source": snapshot.duplicate(), "resources": parts})


func _wait_for(level: Node2D, source: LargeCarcass, evidence: Dictionary, phase: String,
		condition: Callable, frame_limit: int = 1800) -> bool:
	for frame: int in range(frame_limit):
		if bool(condition.call()):
			break
		await _step()
		if frame % 30 == 0:
			_checkpoint(level, source, evidence, phase + "_frame_%d" % frame, false)
	var finished: bool = bool(condition.call())
	_check(finished, "%s completes through real scene frames before timeout" % phase)
	return finished


func _wait_coverage(level: Node2D, source: LargeCarcass, evidence: Dictionary) -> bool:
	return await _wait_for(level, source, evidence, "field_coverage", func() -> bool:
		return level.fungal_field.is_covered(source.global_position), 1800)


func _wait_hauls(level: Node2D, source: LargeCarcass, evidence: Dictionary) -> bool:
	var settled: bool = await _wait_for(level, source, evidence, "haul", func() -> bool:
		return level.recycling_system.get_in_transit_count() == 0)
	await _wait_frames(2)
	_check(level.get_node("World/RecoveryPackets").get_child_count() == 0,
		"Settled haul removes its physical packet")
	_checkpoint(level, source, evidence, "haul_settled")
	return settled


func _wait_products(level: Node2D, source: LargeCarcass, evidence: Dictionary, count: int) -> bool:
	var produced: bool = await _wait_for(level, source, evidence, "digest_%d_products" % count,
		func() -> bool: return level.digestive_organ.get_output_count() >= count)
	_checkpoint(level, source, evidence, "real_digest_timer_produced_%d" % count)
	return produced


func _wait_credited(level: Node2D, source: LargeCarcass, evidence: Dictionary, amount: int) -> bool:
	var arrived: bool = await _wait_for(level, source, evidence, "return_%d" % amount,
		func() -> bool: return level.colony_progress.get_total_recovered() >= amount)
	_check(level.colony_progress.get_total_recovered() == amount,
		"Return checkpoints observe the exact expected cumulative income")
	_checkpoint(level, source, evidence, "actual_return_credited_%d" % amount)
	return arrived


func _first_haul_packet(level: Node2D) -> RemainsPacket:
	var found: RemainsPacket = null
	for child: Node in level.get_node("World/RecoveryPackets").get_children():
		if child is RemainsPacket and not child.is_queued_for_deletion():
			found = child as RemainsPacket
			break
	_check(found != null, "Real dispatch exposes its live RemainsPacket")
	return found


func _first_live_batch(level: Node2D) -> EnemyRemains:
	var found: EnemyRemains = null
	for child: Node in level.get_node("World/Remains").get_children():
		if child is EnemyRemains and child.has_meta("carcass_batch_id") and not child.is_queued_for_deletion():
			found = child as EnemyRemains
			break
	_check(found != null, "Committed source nutrition has an independently owned EnemyRemains batch")
	return found


func _check_committed_ids(source: LargeCarcass, batch: EnemyRemains) -> void:
	var request_id: String = String(batch.get_meta("carcass_request_id"))
	var batch_id: String = String(batch.get_meta("carcass_batch_id"))
	var before: Dictionary = source.get_snapshot()
	_check(source.get_reservation_nutrition(request_id) == 0
		and not source.commit_batch(request_id, batch_id)
		and not source.release_batch(request_id)
		and source.reserve_batch(request_id) == 0,
		"A committed request cannot commit twice, refund its source or reserve again")
	_check(source.get_snapshot() == before, "Duplicate committed source operations preserve every resource counter")


func _wait_movement(packet: Node2D, phase: String) -> void:
	var origin: Vector2 = packet.global_position
	for _frame: int in range(20):
		await _step()
		if not is_instance_valid(packet) or packet.global_position.distance_to(origin) > 1.0:
			break
	_check(is_instance_valid(packet) and packet.global_position.distance_to(origin) > 1.0,
		"%s physically moves before settlement" % phase)


func _launch_return(level: Node2D, source: LargeCarcass, evidence: Dictionary) -> Dictionary:
	var dispatched: bool = level.nutrition_return_system.try_dispatch()
	_check(dispatched, "Stored output launches a real green return through the ordinary system")
	var found: Dictionary = {}
	for record: Dictionary in level.nutrition_return_system.get_shipment_records():
		if StringName(record["status"]) == &"in_transit" and is_instance_valid(record["packet"]):
			found = record
			break
	_check(not found.is_empty(), "Return dispatch has a real live attempt record")
	if not found.is_empty():
		var route: NetworkRoute = found["route"] as NetworkRoute
		var packet: NutrientPacket = found["packet"] as NutrientPacket
		_check(level.network_system.is_route_valid(route) and route.start_node == level.digestive_organ.get_parent()
			and route.end_node == level.mother_core and not route.segments.is_empty(),
			"Green return uses a valid nonempty stomach-to-core route")
		_check(packet.global_position.distance_to(route.start_node.global_position) < POSITION_EPSILON,
			"Green return physically starts at the stomach junction")
	_checkpoint(level, source, evidence, "return_dispatched_uncredited")
	return found


func _drain_cycle(level: Node2D, source: LargeCarcass, evidence: Dictionary, expected: int) -> bool:
	level.nutrition_return_system.auto_return = true
	# 保留正常派遣计时器、尸块路线、胃囊计时器与默认 80 速度的绿色回流。
	level.recycling_system.get_node("DispatchTimer").start()
	var completed: bool = await _wait_for(level, source, evidence, "automatic_cycle", func() -> bool:
		return source.is_exhausted() and (
			level.colony_progress.get_total_recovered() >= expected
			and level.recycling_system.get_in_transit_count() == 0
			and level.digestive_organ.get_queued_count() == 0
			and level.digestive_organ.get_output_count() == 0
			and level.nutrition_return_system.get_in_transit_count() == 0
		), 6000)
	level.recycling_system.get_node("DispatchTimer").stop()
	level.nutrition_return_system.auto_return = false
	await _wait_frames(2)
	_check(level.colony_progress.get_total_recovered() == expected,
		"Automatic cycle recovers exactly the initial resource supply")
	_checkpoint(level, source, evidence, "all_resources_actually_credited")
	return completed


func _check_eight_batches(evidence: Dictionary, ordinary_products: int = 0) -> void:
	var batches: Dictionary = evidence["batches"]
	var production: Array = evidence["production"]
	var tens: int = 0
	var fours: int = 0
	for product: Dictionary in production:
		if int(product["nutrition"]) == BATCH_NUTRITION:
			tens += 1
		elif int(product["nutrition"]) == ORDINARY_NUTRITION:
			fours += 1
	_check(batches.size() == 8 and tens == 8 and fours == ordinary_products
		and production.size() == 8 + ordinary_products,
		"Eighty source nutrition yields eight unique ten-nutrition products plus only the expected ordinary corpse")
	_check(_sum_nutrition(production) == SOURCE_NUTRITION + ordinary_products * ORDINARY_NUTRITION,
		"Product creation totals exactly the committed source and ordinary nutrition")
	_check(evidence["arrivals"].size() == production.size()
		and _sum_nutrition(evidence["arrivals"]) == _sum_nutrition(production),
		"Every unique produced batch physically returns exactly once")
	_check(int(evidence["exhausted_signals"]) == 1 and int(evidence["replayed_callbacks"]) > 0,
		"Exhaustion fires once while duplicate post-settlement callbacks remain harmless")


func _test_complete_eighty_cycle() -> void:
	var level: Node2D = await _new_level()
	var source: LargeCarcass = _source(level)
	if source == null:
		await _remove_level(level, {})
		return
	var evidence: Dictionary = _observe(level, source, "isolated_eighty")
	_check(not (source as Node2D) is EnemyRemains and source.total_nutrition == SOURCE_NUTRITION
		and source.batch_size == BATCH_NUTRITION and source.global_position.is_equal_approx(SOURCE_POSITION),
		"Demo source is a separate 80/10 resource point at the intended location")
	_check(level.get_node("World/Remains").get_child_count() == 1
		and int(evidence["initial_resources"]) == 160 and int(evidence["initial_core"]) == 72,
		"Isolated scene starts with only the 80 source, 72 core and eight organ nutrition")
	_checkpoint(level, source, evidence, "initial")
	_check(source.reserve_batch("test_release_a") == BATCH_NUTRITION
		and source.reserve_batch("test_release_b", 100) == BATCH_NUTRITION,
		"Independent source reservations cap a requested batch at ten")
	_check(source.get_remaining_nutrition() == SOURCE_NUTRITION and source.get_reserved_nutrition() == 20
		and source.get_available_nutrition() == 60
		and source.get_reservation_nutrition("test_release_a") == BATCH_NUTRITION,
		"Precommit reservations leave remaining source nutrition unchanged")
	_check(source.release_batch("test_release_a") and source.release_batch("test_release_b"),
		"Releasing uncommitted requests restores only their availability")
	_check(not source.release_batch("test_release_a") and source.reserve_batch("test_release_a") == 0
		and not source.commit_batch("test_release_a", "late_batch"),
		"Released request IDs are single-use and cannot later commit")
	_checkpoint(level, source, evidence, "released_source_requests")
	var events_before: int = evidence["resource_events"].size()
	_check(not level.recycling_system.try_dispatch() and source.get_snapshot()["status"] == &"out_of_field",
		"Uncovered source cannot reserve, materialize or dispatch a batch")
	_check(source.get_reserved_nutrition() == 0 and source.get_harvested_nutrition() == 0
		and level.digestive_organ.incoming_remains == 0 and evidence["batches"].is_empty(),
		"No coverage leaves all eighty source nutrition and stomach capacity untouched")
	for index: int in range(events_before, evidence["resource_events"].size()):
		_check(int(evidence["resource_events"][index]["reserved_nutrition"]) == 0,
			"Coverage failure happens before any source reservation")

	var receiver_node: Node2D = level.digestive_organ.get_parent()
	source.global_position = level.mother_core.global_position + Vector2(0, 20)
	if not await _wait_coverage(level, source, evidence):
		await _remove_level(level, evidence)
		return
	var direct_edge: HyphaEdge = level.get_node("World/Colony/Connections/DigestionEdge") as HyphaEdge
	var alternate_edge: HyphaEdge = level.get_node("World/Colony/Connections/RecoveryEdge") as HyphaEdge
	direct_edge.end_node = null
	alternate_edge.end_node = null
	await _wait_frames(2)
	events_before = evidence["resource_events"].size()
	_check(level.fungal_field.is_covered(source.global_position) and not level.recycling_system.try_dispatch()
		and source.get_snapshot()["status"] == &"no_route",
		"A covered core candidate cannot mine without a real route to the stomach")
	_check(source.get_remaining_nutrition() == SOURCE_NUTRITION and source.get_reserved_nutrition() == 0
		and source.get_harvested_nutrition() == 0 and level.digestive_organ.incoming_remains == 0,
		"No route never spends source nutrition or stomach capacity")
	for index: int in range(events_before, evidence["resource_events"].size()):
		_check(int(evidence["resource_events"][index]["reserved_nutrition"]) == 0,
			"Route validation happens before source reservation")
	direct_edge.end_node = receiver_node
	alternate_edge.end_node = receiver_node
	await _wait_frames(2)

	var valid_batch_scene: PackedScene = level.recycling_system.batch_scene
	var invalid_batch_scene: PackedScene = PackedScene.new()
	var wrong_batch: Node2D = Node2D.new()
	_check(invalid_batch_scene.pack(wrong_batch) == OK, "Precommit failure fixture packs a non-remains node")
	wrong_batch.free()
	level.recycling_system.batch_scene = invalid_batch_scene
	_check(not level.recycling_system.try_dispatch(), "Invalid batch materialization cannot start a shipment")
	level.recycling_system.batch_scene = valid_batch_scene
	_check(source.get_remaining_nutrition() == SOURCE_NUTRITION and source.get_reserved_nutrition() == 0
		and source.get_harvested_nutrition() == 0 and level.digestive_organ.incoming_remains == 0
		and evidence["batches"].is_empty() and level.recycling_system.get_in_transit_count() == 0,
		"Failed precommit materialization releases the request and leaves no packet, batch or income")
	_checkpoint(level, source, evidence, "materialization_failed_and_released")

	source.global_position = receiver_node.global_position + Vector2(0, 55)
	if not await _wait_coverage(level, source, evidence):
		await _remove_level(level, evidence)
		return
	level.digestive_organ.capacity = 1
	_check(level.recycling_system.try_dispatch(), "First real mining batch starts transport")
	var first_batch: EnemyRemains = _first_live_batch(level)
	if first_batch != null:
		_check_committed_ids(source, first_batch)
	_check(source.get_remaining_nutrition() == 70 and source.get_harvested_nutrition() == 10
		and source.get_reserved_nutrition() == 0 and level.digestive_organ.incoming_remains == 1
		and level.digestive_organ.get_queued_nutrition() == 0,
		"Commit transfers ten from the source into the claimed original, before stomach arrival")
	events_before = evidence["resource_events"].size()
	_check(not level.recycling_system.try_dispatch() and source.get_snapshot()["status"] == &"capacity_full",
		"A full incoming stomach slot rejects another source batch")
	for index: int in range(events_before, evidence["resource_events"].size()):
		_check(int(evidence["resource_events"][index]["reserved_nutrition"]) == 0,
			"Stomach capacity is checked before reserving source nutrition")
	_checkpoint(level, source, evidence, "claimed_and_stomach_full")
	var first_packet: RemainsPacket = _first_haul_packet(level)
	if first_packet != null:
		await _wait_movement(first_packet, "first corpse haul")
	await _wait_hauls(level, source, evidence)
	_check(level.digestive_organ.get_queued_nutrition() == 10
		and level.digestive_organ.get_output_snapshot()["reserved_nutrition"] == 10
		and not level.digestive_organ.digest_timer.is_stopped() and not level.recycling_system.try_dispatch(),
		"Actual haul arrival enters digestion once and the active corpse still occupies stomach capacity")
	await _wait_products(level, source, evidence, 1)
	_check(level.recycling_system.try_dispatch(), "Second batch starts only after the first real digestion frees intake")
	await _wait_hauls(level, source, evidence)
	await _wait_products(level, source, evidence, 2)
	_check(level.digestive_organ.get_output_nutrition() == 20 and evidence["arrivals"].is_empty(),
		"Two real products fill twenty output nutrition without early core income")
	_check(level.recycling_system.try_dispatch(), "A third real batch can wait in the separate stomach intake")
	await _wait_hauls(level, source, evidence)
	var blocked: Dictionary = level.digestive_organ.get_output_snapshot()
	_check(level.digestive_organ.get_queued_nutrition() == 10 and int(blocked["reserved_nutrition"]) == 0
		and blocked["wait_reason"] == &"output_full" and level.digestive_organ.digest_timer.is_stopped(),
		"Output backpressure leaves the third corpse owned by the queue and stops its digestion timer")
	_check(not level.recycling_system.try_dispatch() and source.get_remaining_nutrition() == 50,
		"Blocked intake cannot mine a fourth batch or debit the source")
	await _wait_frames(90)
	_check(level.digestive_organ.digested_count == 2 and level.digestive_organ.get_queued_nutrition() == 10
		and level.digestive_organ.get_output_nutrition() == 20
		and level.mother_core.nutrition == 72 and level.colony_progress.get_total_recovered() == 0,
		"Waiting beyond a real digestion interval cannot bypass full output or create first income")
	_checkpoint(level, source, evidence, "output_backpressure_stable")
	var returning: Dictionary = _launch_return(level, source, evidence)
	if not returning.is_empty():
		await _wait_movement(returning["packet"] as NutrientPacket, "first green return")
	_check(level.digestive_organ.get_output_nutrition() == 20
		and level.digestive_organ.get_output_snapshot()["reserved_nutrition"] == 0
		and level.nutrition_return_system.get_in_transit_nutrition() == 10
		and level.mother_core.nutrition == 72 and level.colony_progress.get_total_recovered() == 0,
		"Dispatch and physical return movement retain output capacity and grant no early income")
	_checkpoint(level, source, evidence, "first_return_physically_in_transit")
	await _wait_credited(level, source, evidence, 10)
	_check(level.digestive_organ.get_output_snapshot()["reserved_nutrition"] == 10
		and not level.digestive_organ.digest_timer.is_stopped(),
		"Only actual core acceptance frees output capacity and resumes the blocked real digestion")
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, 20)
	await _wait_products(level, source, evidence, 1)
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, 30)
	await _drain_cycle(level, source, evidence, SOURCE_NUTRITION)
	_check_eight_batches(evidence)
	_check(level.mother_core.nutrition == 152 and level.colony_progress.get_total_recovered() == 80
		and level.colony_progress.get_product_count() == 8 and source.get_harvested_nutrition() == 80,
		"Isolated real resource point finishes with exactly +80 core nutrition and cumulative 80")
	var exhausted_snapshot: Dictionary = source.get_snapshot()
	var productions_before: int = evidence["production"].size()
	var arrivals_before: int = evidence["arrivals"].size()
	for _attempt: int in range(8):
		_check(not level.recycling_system.try_dispatch(), "Exhausted source never dispatches another batch")
	for record: Dictionary in evidence["batches"].values():
		_check(not source.commit_batch(String(record["request_id"]), String(record["batch_id"]))
			and not source.release_batch(String(record["request_id"])),
			"Settled batch IDs cannot replenish an exhausted source")
	await _wait_frames(180)
	_check(source.get_snapshot() == exhausted_snapshot and evidence["production"].size() == productions_before
		and evidence["arrivals"].size() == arrivals_before and int(evidence["exhausted_signals"]) == 1,
		"Exhaustion and all eight credits remain stable after stale source operations and extra timer time")
	_checkpoint(level, source, evidence, "exhaustion_stable")
	cycle_result = {"core_gain": 80, "recovered": 80, "batches": evidence["batches"].values(),
		"products": evidence["production"], "receipts": evidence["arrivals"],
		"replayed_callbacks": evidence["replayed_callbacks"], "source": source.get_snapshot()}
	await _remove_level(level, evidence)


func _test_haul_interruption_and_recovery() -> void:
	var level: Node2D = await _new_level()
	var source: LargeCarcass = _source(level)
	if source == null:
		await _remove_level(level, {})
		return
	var evidence: Dictionary = _observe(level, source, "haul_interruption")
	source.global_position = level.mother_core.global_position + Vector2(0, 40)
	if not await _wait_coverage(level, source, evidence):
		await _remove_level(level, evidence)
		return
	_check(level.recycling_system.try_dispatch(), "Interruption fixture launches a committed real batch")
	var packet: RemainsPacket = _first_haul_packet(level)
	var batch: EnemyRemains = _first_live_batch(level)
	if packet == null or batch == null:
		await _remove_level(level, evidence)
		return
	var original_batch_id: String = String(batch.get_meta("carcass_batch_id"))
	var original_owner_id: int = batch.get_instance_id()
	await _wait_movement(packet, "interrupted real haul")
	# 6.4 拾取期间的未来断段只会等待；本例仍验证永久损坏当前占用段的唯一落地结算。
	if not await _wait_for(level, source, evidence, "haul_entered_network_before_permanent_removal", func() -> bool:
		return is_instance_valid(packet) and packet.get_transport_snapshot()["state"] == &"moving" \
			and packet.progress > 0.0):
		await _remove_level(level, evidence)
		return
	var receiver_node: Node2D = level.digestive_organ.get_parent()
	var direct_edge: HyphaEdge = level.get_node("World/Colony/Connections/DigestionEdge") as HyphaEdge
	var alternate_edge: HyphaEdge = level.get_node("World/Colony/Connections/RecoveryEdge") as HyphaEdge
	direct_edge.end_node = null
	alternate_edge.end_node = null
	await _wait_hauls(level, source, evidence)
	var interruptions: Array = evidence["packet_interruptions"]
	_check(not interruptions.is_empty(), "Permanently invalidating the occupied edge emits one physical haul interruption")
	if not interruptions.is_empty():
		var drop_position: Vector2 = interruptions.back()["position"]
		_check(batch.global_position.distance_to(drop_position) < POSITION_EPSILON,
			"Interruption drops the original batch at the actual packet position")
	_check(batch.visible and batch.is_available() and batch.nutrition_value == 10
		and source.get_remaining_nutrition() == 70 and source.get_harvested_nutrition() == 10
		and source.get_reserved_nutrition() == 0 and level.digestive_organ.incoming_remains == 0
		and level.digestive_organ.get_queued_nutrition() == 0 and evidence["arrivals"].is_empty(),
		"Postcommit interruption returns a ground batch without source refund, duplication or income")
	_checkpoint(level, source, evidence, "committed_batch_on_ground")
	direct_edge.end_node = receiver_node
	alternate_edge.end_node = receiver_node
	await _wait_frames(2)
	_check(level.fungal_field.is_covered(batch.global_position) and level.recycling_system.try_dispatch(),
		"Reconnection physically recovers the covered ground batch")
	_check(batch.get_instance_id() == original_owner_id
		and String(batch.get_meta("carcass_batch_id")) == original_batch_id
		and evidence["batches"].size() == 1 and source.get_remaining_nutrition() == 70
		and source.get_harvested_nutrition() == 10,
		"Ordinary remains priority reclaims the same batch before mining another ten")
	await _wait_hauls(level, source, evidence)
	await _wait_products(level, source, evidence, 1)
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, 10)
	_check(level.recycling_system.interrupted_count == 1 and level.recycling_system.delivered_count == 1
		and evidence["production"].size() == 1 and evidence["arrivals"].size() == 1
		and source.get_remaining_nutrition() == 70 and level.mother_core.nutrition == 82,
		"Interrupted and recovered batch is digested and credited once, with seventy still at its source")
	_checkpoint(level, source, evidence, "ground_recovery_actually_credited")
	interruption_result = {"remaining": 70, "harvested": 10, "recovered": 10,
		"batch_id": original_batch_id, "interruptions": interruptions,
		"replayed_callbacks": evidence["replayed_callbacks"]}
	await _remove_level(level, evidence)


func _test_competing_coverage_candidates() -> void:
	var level: Node2D = await _new_level()
	var source: LargeCarcass = _source(level)
	if source == null:
		await _remove_level(level, {})
		return
	var evidence: Dictionary = _observe(level, source, "candidate_fallback")
	var receiver_node: Node2D = level.digestive_organ.get_parent()
	source.global_position = Vector2(675, 570)
	var alternate: SelectiveNetwork = SelectiveNetwork.new()
	level.get_node("Systems").add_child(alternate)
	for node: Node2D in level.network_system.get_registered_nodes():
		_check(alternate.register_node(node, node == level.mother_core), "Fallback network registers the real level node")
	for child: Node in level.hypha_edges.get_children():
		if child is HyphaEdge:
			_check(alternate.register_edge(child as HyphaEdge), "Fallback network retains the same physical level edge")
	alternate.rejected_start = level.mother_core
	alternate.rejected_end = receiver_node
	level.recycling_system.network_system = alternate
	# 候选查询替身沿用关卡唯一调度器；替换网络时同步绑定，不绕过容量。
	level.traffic_system.network_system = alternate
	level.traffic_system.refresh()
	_check(level.recycling_system.traffic_required
		and level.recycling_system.traffic_system == level.traffic_system,
		"Candidate fallback preserves the mandatory shared traffic dispatcher")
	if not await _wait_for(level, source, evidence, "overlapping_real_coverage", func() -> bool:
		return level.fungal_field.get_collecting_nodes(source.global_position).size() >= 2):
		await _remove_level(level, evidence)
		return
	var candidates: Array[Node2D] = level.fungal_field.get_collecting_nodes(source.global_position)
	_check(candidates[0] == level.mother_core and candidates.has(receiver_node)
		and alternate.is_connected_to_core(candidates[0]),
		"The nearest core and stomach junction both cover the same resource point")
	for rejection: int in range(2):
		alternate.reject_as_invalid = rejection == 1
		_check(level.recycling_system.try_dispatch(), "A failed nearest candidate permits the second actual coverage candidate")
		var packet: RemainsPacket = _first_haul_packet(level)
		if packet == null:
			await _remove_level(level, evidence)
			return
		await _wait_frames(4)
		_check(is_instance_valid(packet) and packet.global_position.x > source.global_position.x,
			"Fallback pickup physically moves toward the stomach rather than the rejected nearest core")
		await _wait_hauls(level, source, evidence)
	_check(source.get_harvested_nutrition() == 20 and source.get_remaining_nutrition() == 60
		and evidence["batches"].size() == 2 and source.get_reserved_nutrition() == 0,
		"Both candidate failure modes commit exactly one independent batch each")
	level.recycling_system.network_system = level.network_system
	level.traffic_system.network_system = level.network_system
	level.traffic_system.refresh()
	await _wait_products(level, source, evidence, 2)
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, 10)
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, 20)
	_checkpoint(level, source, evidence, "candidate_fallbacks_actually_credited")
	candidate_result = {"failure_modes": ["route_not_found", "route_invalid"],
		"batches": evidence["batches"].size(), "remaining": source.get_remaining_nutrition(),
		"recovered": level.colony_progress.get_total_recovered()}
	await _remove_level(level, evidence)


func _test_mixed_paid_expansion() -> void:
	var level: Node2D = await _new_level(true)
	var source: LargeCarcass = _source(level)
	if source == null:
		await _remove_level(level, {})
		return
	var evidence: Dictionary = _observe(level, source, "mixed_paid_growth", true)
	var ordinary: EnemyRemains = level.get_node("World/Remains/ExpansionRemains") as EnemyRemains
	_check(ordinary.nutrition_value == ORDINARY_NUTRITION and ordinary.is_available()
		and int(evidence["initial_resources"]) == 164,
		"Mixed level contains the source eighty plus the original ordinary four and complete colony funds")
	_check(not level.recycling_system.try_dispatch() and source.get_harvested_nutrition() == 0,
		"The distant ordinary corpse and resource point wait for paid expansion")
	# 实际器官供养也参与全账本；incoming 已拥有核心扣除的营养，不重复加运输包。
	var organs_before: int = int(_resource_snapshot(level, source, evidence)["organs_and_incoming_supply"])
	_check(level.supply_system.request_supply(level.attack_organ), "Mixed fixture dispatches real ordinary organ supply")
	_check(level.supply_system.get_in_transit_count() > 0 and level.attack_organ.incoming_nutrition > 0,
		"Ordinary supply is prepaid and owned by the organ incoming ledger while physically in transit")
	_checkpoint(level, source, evidence, "ordinary_supply_in_transit")
	var controller: GrowthInputController = level.growth_input_controller
	_check(controller.enter_placement_mode() and controller.place_target(GROWTH_TARGET),
		"Real placement controller starts the recommended paid expansion")
	# 正式放置只入队；推进调度后继续原真实付费与守恒验收。
	level.construction_coordinator.pump()
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	_check(growth["start_node"] == level.get_node("World/Colony/Nodes/RightNode")
		and int(growth["total_cost"]) == GROWTH_COST and is_equal_approx(float(growth["total_distance"]), 320.0),
		"The real 320-pixel expansion costs sixteen nutrition")
	_check(level.growth_supply_system.try_dispatch() and level.growth_system.pause_task(),
		"Expansion is funded by a real prepaid growth packet before pausing growth")
	_checkpoint(level, source, evidence, "growth_funding_in_transit")
	if not await _wait_for(level, source, evidence, "paid_growth_first_arrival", func() -> bool:
		return level.growth_supply_system.get_in_transit_count() == 0):
		await _remove_level(level, evidence)
		return
	growth = level.growth_system.get_task_snapshot()
	_check(growth["state"] == &"paused" and int(growth["buffered_nutrition"]) == 1
		and int(growth["consumed_nutrition"]) == 0 and is_zero_approx(float(growth["distance"])),
		"Physically arrived growth nutrition remains buffered without unpaid extension")
	_checkpoint(level, source, evidence, "growth_buffer_owned")
	level.growth_supply_system.auto_supply = true
	_check(level.growth_system.resume_task(), "Paid growth resumes from the delivered buffer")
	if not await _wait_for(level, source, evidence, "paid_expansion_complete", func() -> bool:
		return level.growth_system.get_task_snapshot()["state"] == &"completed", 6000):
		await _remove_level(level, evidence)
		return
	level.growth_supply_system.auto_supply = false
	growth = level.growth_system.get_task_snapshot()
	var organ_nutrition: int = int(_resource_snapshot(level, source, evidence)["organs_and_incoming_supply"])
	var supply_cost: int = organ_nutrition - organs_before
	_check(int(growth["consumed_nutrition"]) == GROWTH_COST and int(growth["formed_junctions"]) == 3
		and int(growth["buffered_nutrition"]) == 0 and level.growth_supply_system.get_in_transit_count() == 0
		and level.supply_system.get_in_transit_count() == 0 and supply_cost > 0,
		"Completed growth and supply reconcile consumed sixteen and the physically supplied organ inventory")
	_check(level.mother_core.nutrition == int(evidence["initial_core"]) - GROWTH_COST - supply_cost
		and level.fungal_field.is_covered(source.global_position)
		and level.fungal_field.is_covered(ordinary.global_position)
		and evidence["arrivals"].is_empty() and source.get_harvested_nutrition() == 0,
		"Paid growth reaches both real resources while preserving zero premature recovery income")
	_checkpoint(level, source, evidence, "paid_expansion_before_harvest")
	var core_before_harvest: int = level.mother_core.nutrition
	# 把资源点置于容器首位，仍必须先取后面的可用普通尸体。
	level.get_node("World/Remains").move_child(source, 0)
	_check(level.recycling_system.try_dispatch() and not ordinary.visible and not ordinary.is_available()
		and source.get_harvested_nutrition() == 0 and source.get_reserved_nutrition() == 0,
		"Available ordinary remains outrank new mining even when the source is first in the container")
	_checkpoint(level, source, evidence, "ordinary_priority_claimed")
	await _wait_hauls(level, source, evidence)
	await _wait_products(level, source, evidence, 1)
	_check(level.digestive_organ.get_output_nutrition() == ORDINARY_NUTRITION
		and source.get_remaining_nutrition() == SOURCE_NUTRITION,
		"Ordinary priority delivers and digests only the original four before any source debit")
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, ORDINARY_NUTRITION)
	await _drain_cycle(level, source, evidence, SOURCE_NUTRITION + ORDINARY_NUTRITION)
	_check_eight_batches(evidence, 1)
	_check(level.mother_core.nutrition == core_before_harvest + 84
		and level.colony_progress.get_total_recovered() == 84 and level.colony_progress.get_product_count() == 9,
		"Mixed scene credits exactly eighty plus four after separately paying growth and organ supply")
	_checkpoint(level, source, evidence, "mixed_full_ledger_settled")
	mixed_result = {"initial_resources": evidence["initial_resources"], "growth_consumed": GROWTH_COST,
		"supply_transferred": supply_cost, "core_before_harvest": core_before_harvest,
		"core_after_harvest": int(level.mother_core.nutrition), "recovered": 84,
		"products": evidence["production"], "final_resources": _resource_snapshot(level, source, evidence)}
	await _remove_level(level, evidence)


func _press_restart() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = KEY_R
	event.pressed = true
	root.push_input(event)
	event = InputEventKey.new()
	event.keycode = KEY_R
	root.push_input(event)


func _test_restart_with_pending_packets() -> void:
	var level: Node2D = await _new_level()
	var source: LargeCarcass = _source(level)
	if source == null:
		await _remove_level(level, {})
		return
	var evidence: Dictionary = _observe(level, source, "restart_old_scene")
	source.global_position = level.digestive_organ.get_parent().global_position + Vector2(0, 55)
	if not await _wait_coverage(level, source, evidence):
		await _remove_level(level, evidence)
		return
	_check(level.recycling_system.try_dispatch(), "Restart setup launches the first actual batch")
	await _wait_hauls(level, source, evidence)
	await _wait_products(level, source, evidence, 1)
	_launch_return(level, source, evidence)
	await _wait_credited(level, source, evidence, 10)
	var credited_id: String = String(evidence["arrivals"][0]["product_id"])
	_check(level.recycling_system.try_dispatch(), "Restart setup produces its second committed batch")
	await _wait_hauls(level, source, evidence)
	await _wait_products(level, source, evidence, 1)
	var pending: Dictionary = _launch_return(level, source, evidence)
	if pending.is_empty():
		await _remove_level(level, evidence)
		return
	var old_return: NutrientPacket = pending["packet"] as NutrientPacket
	await _wait_movement(old_return, "restart pending green return")
	_check(level.recycling_system.try_dispatch(), "Restart setup also commits a third real haul")
	var old_haul: RemainsPacket = _first_haul_packet(level)
	if old_haul == null:
		await _remove_level(level, evidence)
		return
	var progress_callbacks: Array[Callable] = _packet_callbacks(level.mother_core, level.colony_progress,
		&"digestion_product_arrived")
	var old_registration: RefCounted = null
	if not progress_callbacks.is_empty():
		var arguments: Array = progress_callbacks[0].get_bound_arguments()
		if arguments.size() == 2:
			old_registration = arguments[1] as RefCounted
	_check(old_registration != null, "Restart captures the real old progress registration token")
	var old_core_id: int = level.mother_core.get_instance_id()
	var old_return_id: int = old_return.get_instance_id()
	var old_haul_id: int = old_haul.get_instance_id()
	var old_attempt_id: String = String(pending["attempt_id"])
	var pending_id: String = String(pending["product_id"])
	var old_arrivals: int = evidence["arrivals"].size()
	_check(source.get_remaining_nutrition() == 50 and source.get_harvested_nutrition() == 30
		and level.recycling_system.get_in_transit_count() == 1
		and level.nutrition_return_system.get_in_transit_nutrition() == 10
		and level.colony_progress.get_total_recovered() == 10,
		"R begins with positive harvested/recovered ledgers and both a real haul and real return pending")
	_checkpoint(level, source, evidence, "before_R_with_two_pending_packets")
	# 重载会销毁旧世界中的资源；仅停止对旧世界做守恒采样，仍观察取消和旧回调。
	evidence["observe_resources"] = false
	root.child_entered_tree.connect(_prepare_reload_child, CONNECT_ONE_SHOT)
	_press_restart()
	# 包的旧回调由上面的真实取消观察者在结算后重放；不提前伪造待到达的包。
	for callback: Callable in progress_callbacks:
		if callback.is_valid():
			callback.call(pending_id, BATCH_NUTRITION)
	for _frame: int in range(30):
		await _step()
		if is_instance_valid(current_scene) and current_scene != level and current_scene.is_node_ready():
			break
	await _wait_frames(2)
	var fresh: Node2D = current_scene as Node2D
	_check(is_instance_valid(fresh) and fresh != level and not is_instance_valid(level),
		"Actual R input reloads the level and removes the old scene")
	if not is_instance_valid(fresh) or fresh == level:
		if root.child_entered_tree.is_connected(_prepare_reload_child):
			root.child_entered_tree.disconnect(_prepare_reload_child)
		if is_instance_valid(level):
			await _remove_level(level, evidence)
		return
	_stop_unrelated_timers(fresh)
	var fresh_source: LargeCarcass = _source(fresh)
	if fresh_source == null:
		await _remove_level(fresh, {})
		return
	var fresh_evidence: Dictionary = _observe(fresh, fresh_source, "restart_fresh_scene")
	_check(not is_instance_valid(instance_from_id(old_return_id)) and not is_instance_valid(instance_from_id(old_haul_id))
		and evidence["arrivals"].size() == old_arrivals,
		"R removes both old physical packets and all cancellation replays produce no unreturned credit")
	_check(fresh_source.get_remaining_nutrition() == 80 and fresh_source.get_available_nutrition() == 80
		and fresh_source.get_reserved_nutrition() == 0 and fresh_source.get_harvested_nutrition() == 0
		and not fresh_source.is_exhausted() and fresh_source.global_position.is_equal_approx(SOURCE_POSITION)
		and fresh.get_node("World/Remains").get_child_count() == 1,
		"R restores one fresh eighty-nutrition source with no reservations, mined batches or harvested count")
	_check(fresh.mother_core.nutrition == 72 and fresh.mother_core.get_received_product_count() == 0
		and not fresh.mother_core.has_received_product(credited_id)
		and not fresh.mother_core.has_received_product(pending_id)
		and fresh.colony_progress.get_total_recovered() == 0 and fresh.colony_progress.get_product_count() == 0,
		"R restores initial core nutrition and clears previously nonzero recovered and receipt ledgers")
	var output: Dictionary = fresh.digestive_organ.get_output_snapshot()
	var returning: Dictionary = fresh.nutrition_return_system.get_return_snapshot()
	var growth: Dictionary = fresh.growth_system.get_task_snapshot()
	_check(fresh.digestive_organ.incoming_remains == 0 and fresh.digestive_organ.get_queued_nutrition() == 0
		and fresh.digestive_organ.digested_count == 0 and fresh.digestive_organ.total_nutrition_produced == 0
		and int(output["count"]) == 0 and int(output["nutrition"]) == 0
		and int(output["reserved_count"]) == 0 and int(output["reserved_nutrition"]) == 0,
		"R clears old intake, digestion, output products and output-space reservations")
	_check(fresh.recycling_system.get_in_transit_count() == 0 and fresh.recycling_system.delivered_count == 0
		and fresh.recycling_system.interrupted_count == 0
		and int(returning["in_transit_count"]) == 0 and int(returning["queued_count"]) == 0
		and int(returning["delivered_count"]) == 0 and int(returning["delivered_nutrition"]) == 0
		and fresh.nutrition_return_system.get_shipment_records().is_empty(),
		"R clears all pending and settled recycling/return counters")
	_check(growth["state"] == &"idle" and int(growth["buffered_nutrition"]) == 0
		and int(growth["consumed_nutrition"]) == 0 and fresh.growth_supply_system.get_in_transit_count() == 0
		and fresh.supply_system.get_in_transit_count() == 0,
		"R has no inherited growth or organ supply investment")
	for path: String in ["World/Packets", "World/RecoveryPackets", "World/ReturnPackets", "World/GrowthPackets",
			"World/GrowthTips", "World/GrowthTargets", "World/Enemies", "World/Projectiles"]:
		_check(fresh.get_node(path).get_child_count() == 0, "R clears old objects from %s" % path)
	# 旧身份的延迟清理回调在新系统中没有匹配账本；旧注册令牌也不能成为新周期收入。
	fresh.recycling_system._on_packet_removed(old_haul_id)
	fresh.nutrition_return_system._on_attempt_removed(old_attempt_id)
	fresh.nutrition_return_system._on_owner_removed(old_core_id)
	if old_registration != null:
		fresh.colony_progress._on_digestion_product_arrived(pending_id, BATCH_NUTRITION,
			old_core_id, old_registration)
	_checkpoint(fresh, fresh_source, fresh_evidence, "old_callback_identities_rejected")
	await _wait_frames(360)
	_check(fresh.mother_core.nutrition == 72 and fresh.colony_progress.get_total_recovered() == 0
		and fresh.mother_core.get_received_product_count() == 0
		and fresh_evidence["arrivals"].is_empty() and fresh_evidence["production"].is_empty()
		and fresh_source.get_harvested_nutrition() == 0 and fresh_source.get_remaining_nutrition() == 80,
		"Waiting past both old transport durations cannot credit or harvest anything in the new scene")
	_checkpoint(fresh, fresh_source, fresh_evidence, "restart_no_late_income")
	restart_result = {"before": {"harvested": 30, "recovered": 10, "haul_pending": 1, "return_pending": 1},
		"after": {"remaining": 80, "harvested": 0, "recovered": 0, "core": 72, "pending": 0},
		"old_callback_replays": evidence["replayed_callbacks"], "stale_progress_registration_rejected": true}
	await _remove_level(fresh, fresh_evidence)
