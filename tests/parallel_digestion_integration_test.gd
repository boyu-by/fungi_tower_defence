extends SceneTree
## 7.4：真实尸体运输、物理消化计时器和真实回流；不伪造首次生产或收件。
## 父任务运行：Godot --headless --fixed-fps 60 --path . --script tests/parallel_digestion_integration_test.gd

class Fixture:
	extends RefCounted

	var host: Node2D
	var organ: DigestiveOrgan
	var core: MotherCore
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var field: FungalField
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var recycling: RecyclingSystem
	var returns: NutritionReturnSystem
	var remains: Node2D
	var recovery_packets: Node2D
	var return_packets: Node2D
	var stomach_node: Node2D
	var collection_node: Node2D
	var return_edge: HyphaEdge
	var initial_balance: int = 0
	var initial_recovered: int = 0
	var source_nutrition: int = 0
	var starts: Array[Dictionary] = []
	var completions: Array[Dictionary] = []
	var products: Array[Dictionary] = []
	var digestions: Array[int] = []
	var receipts: Array[Dictionary] = []
	var maximum_intake: int = 0
	var maximum_active: int = 0
	var maximum_waiting: int = 0
	var maximum_reserved_count: int = 0
	var maximum_reserved_nutrition: int = 0
	var maximum_output_count: int = 0
	var maximum_output_nutrition: int = 0
	var dual_busy_frames: int = 0
	var audit: bool = true
	var context: String = ""

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const HYPHA_NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const RECYCLING_SCENE: PackedScene = preload("res://scenes/systems/recycling_system.tscn")
const FRAME_LIMIT: int = 2400
const RUN_FRAME_LIMIT: int = 24000
const BENCHMARK_CORPSES: int = 12
const BENCHMARK_NUTRITION: int = 4
const TIMING_EPSILON: float = 0.034

var checks: int = 0
var conservation_checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []
var _sampled_frames: int = 0
var _source_serial: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	_check(is_equal_approx(Engine.time_scale, 1.0), "Engine time scale retains its default one")
	var initial_children: int = root.get_child_count()
	var formal: Fixture = await _new_formal_fixture()
	if await _test_real_threshold_and_expansion(formal):
		await _test_throughput_same_frame_and_recovery(formal)
		await _test_late_binding_and_real_restart(formal)
	if is_instance_valid(formal.host) and formal.host.is_inside_tree():
		await _dispose(formal)
	await process_frame
	await process_frame
	_check(root.get_child_count() == initial_children, "All parallel digestion integration fixtures are removed")
	_finish()


func _finish() -> void:
	print("PARALLEL_DIGESTION_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "conservation_checks": conservation_checks,
		"evidence": evidence, "sampled_frames": _sampled_frames,
		"first_production_fabricated": false, "first_arrivals_fabricated": false,
		"stage_receipts_fabricated": false, "balance_or_cache_injected": false,
		"digest_duration_changed": false, "packet_speed_changed": false,
		"capacity_changed": false, "motion": "real_engine_physics_frames",
		"conservation": "ground + remains_transit + intake_including_active + outputs_including_return_transit + actual_receipts",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
		push_error(message)


func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _prepare_formal(level: Node2D) -> void:
	level.set("expansion_demo_enabled", false)
	level.set("carcass_demo_enabled", false)
	level.get_node("Systems/EnemySpawner").set("auto_start", false)
	for path: String in ["GrowthSupplySystem", "CultivationSupplySystem", "RepairSupplySystem"]:
		level.get_node("Systems/" + path).set("auto_supply", false)
	level.get_node("Systems/NutritionReturnSystem").set("auto_return", false)
	level.get_node("Systems/SupplySystem/DispatchTimer").set("autostart", false)
	level.get_node("Systems/RecyclingSystem/DispatchTimer").set("autostart", false)
	level.get_node("Systems/ConstructionCoordinator").set("auto_execute", false)
	level.get_node("Systems/ConstructionSupplyScheduler").set("auto_dispatch", false)
	for path: String in ["HyphaNode", "RightNode"]:
		level.get_node("World/Colony/Nodes/" + path + "/SporeWeapon/FireTimer").set("autostart", false)


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_formal(child as Node2D)


func _quiet_formal(level: Node2D) -> void:
	level.set_process(false)
	(level.get_node("Systems/EnemySpawner") as EnemySpawner).stop_spawning()
	for path: String in ["SupplySystem", "RecyclingSystem", "NutritionReturnSystem"]:
		(level.get_node("Systems/" + path + "/DispatchTimer") as Timer).stop()
	for path: String in ["GrowthSystem", "CultivationSystem", "RepairSystem"]:
		level.get_node("Systems/" + path).set_physics_process(false)
	for path: String in ["GrowthSupplySystem", "CultivationSupplySystem", "RepairSupplySystem", "ConstructionSupplyScheduler"]:
		level.get_node("Systems/" + path).set_process(false)
	for path: String in ["HyphaNode", "RightNode"]:
		(level.get_node("World/Colony/Nodes/" + path + "/SporeWeapon/FireTimer") as Timer).stop()
	(level.get_node("World/FungalField") as FungalField).advance(1.0)


func _new_formal_fixture() -> Fixture:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_formal(level)
	root.add_child(level)
	current_scene = level
	_quiet_formal(level)
	await process_frame
	await process_frame
	var fixture: Fixture = _attach_formal(level)
	_check(fixture.core.nutrition == 72 and fixture.progress.get_total_recovered() == 0,
		"Formal scene retains original 72 nutrition and zero recovered products")
	_check(fixture.organ.colony_capabilities == fixture.capabilities
		and fixture.capabilities.colony_progress == fixture.progress,
		"Formal stomach is bound to the one real colony capability and progress source")
	_check_defaults(fixture)
	return fixture


func _attach_formal(level: Node2D) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.host = level
	fixture.organ = level.get_node("World/Colony/Nodes/RearNode/DigestiveOrgan") as DigestiveOrgan
	fixture.stomach_node = fixture.organ.get_parent() as Node2D
	fixture.collection_node = fixture.stomach_node
	fixture.core = level.get_node("World/Colony/MotherCore") as MotherCore
	fixture.network = level.get_node("Systems/NetworkSystem") as NetworkSystem
	fixture.traffic = level.get_node("Systems/NetworkTrafficSystem") as NetworkTrafficSystem
	fixture.field = level.get_node("World/FungalField") as FungalField
	fixture.progress = level.get_node("Systems/ColonyProgress") as ColonyProgress
	fixture.capabilities = level.get_node("Systems/ColonyCapabilities") as ColonyCapabilities
	fixture.recycling = level.get_node("Systems/RecyclingSystem") as RecyclingSystem
	fixture.returns = level.get_node("Systems/NutritionReturnSystem") as NutritionReturnSystem
	fixture.remains = level.get_node("World/Remains") as Node2D
	fixture.recovery_packets = level.get_node("World/RecoveryPackets") as Node2D
	fixture.return_packets = level.get_node("World/ReturnPackets") as Node2D
	fixture.return_edge = level.get_node("World/Colony/Connections/DigestionEdge") as HyphaEdge
	fixture.context = "Formal scene"
	fixture.initial_balance = fixture.core.nutrition
	fixture.initial_recovered = fixture.progress.get_total_recovered()
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains:
			fixture.source_nutrition += (child as EnemyRemains).nutrition_value
	_observe(fixture)
	return fixture


func _new_benchmark_fixture(mature_capabilities: ColonyCapabilities = null) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.context = "Single chamber benchmark" if mature_capabilities == null else "Dual chamber benchmark"
	fixture.host = Node2D.new()
	root.add_child(fixture.host)
	fixture.core = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	fixture.core.add_child(health_bar)
	fixture.host.add_child(fixture.core)
	fixture.stomach_node = Node2D.new()
	fixture.stomach_node.position = Vector2(16.0, 0.0)
	fixture.host.add_child(fixture.stomach_node)
	fixture.collection_node = Node2D.new()
	fixture.collection_node.position = Vector2(32.0, 0.0)
	fixture.host.add_child(fixture.collection_node)
	fixture.network = NetworkSystem.new()
	fixture.host.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Benchmark core enters its real network")
	_check(fixture.network.register_node(fixture.stomach_node), "Benchmark stomach node enters its real network")
	_check(fixture.network.register_node(fixture.collection_node), "Benchmark collecting node enters its real network")
	for pair: Array in [[fixture.core, fixture.stomach_node], [fixture.stomach_node, fixture.collection_node]]:
		var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
		edge.start_node = pair[0] as Node2D
		edge.end_node = pair[1] as Node2D
		fixture.host.add_child(edge)
		_check(fixture.network.register_edge(edge), "Benchmark uses registered real sixteen-pixel edges")
		_check(edge.traffic_capacity == 2 and is_equal_approx(edge.get_length(), 16.0),
			"Benchmark preserves original edge capacity on a finite free-flowing route")
		if pair[0] == fixture.core:
			fixture.return_edge = edge
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.host.add_child(fixture.traffic)
	fixture.field = FungalField.new()
	fixture.host.add_child(fixture.field)
	var sources: Array[Dictionary] = []
	for node: Node2D in [fixture.core, fixture.stomach_node, fixture.collection_node]:
		sources.append({"node": node, "kind": &"core" if node == fixture.core else &"junction", "connected": true})
	fixture.field.set_sources(sources)
	fixture.field.advance(1.0)
	if mature_capabilities == null:
		fixture.progress = ColonyProgress.new()
		fixture.host.add_child(fixture.progress)
		fixture.capabilities = ColonyCapabilities.new()
		fixture.capabilities.colony_progress = fixture.progress
		fixture.host.add_child(fixture.capabilities)
	else:
		fixture.capabilities = mature_capabilities
		fixture.progress = mature_capabilities.colony_progress
	_check(fixture.progress.register_source(fixture.core), "Benchmark progress observes only its core's real receipts")
	fixture.organ = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	fixture.organ.mother_core = fixture.core
	fixture.organ.core_edge = fixture.return_edge
	fixture.organ.colony_capabilities = fixture.capabilities
	fixture.stomach_node.add_child(fixture.organ)
	fixture.remains = Node2D.new()
	fixture.recovery_packets = Node2D.new()
	fixture.return_packets = Node2D.new()
	for container: Node2D in [fixture.remains, fixture.recovery_packets, fixture.return_packets]:
		fixture.host.add_child(container)
	fixture.recycling = RECYCLING_SCENE.instantiate() as RecyclingSystem
	fixture.recycling.network_system = fixture.network
	fixture.recycling.traffic_system = fixture.traffic
	fixture.recycling.traffic_required = true
	fixture.recycling.fungal_field = fixture.field
	fixture.recycling.digestive_organ = fixture.organ
	fixture.recycling.remains_container = fixture.remains
	fixture.recycling.packet_container = fixture.recovery_packets
	(fixture.recycling.get_node("DispatchTimer") as Timer).autostart = false
	fixture.host.add_child(fixture.recycling)
	(fixture.recycling.get_node("DispatchTimer") as Timer).stop()
	fixture.returns = NutritionReturnSystem.new()
	fixture.returns.digestive_organ = fixture.organ
	fixture.returns.mother_core = fixture.core
	fixture.returns.network_system = fixture.network
	fixture.returns.traffic_system = fixture.traffic
	fixture.returns.traffic_required = true
	fixture.returns.packet_container = fixture.return_packets
	fixture.returns.auto_return = false
	fixture.host.add_child(fixture.returns)
	(fixture.returns.get_node("DispatchTimer") as Timer).stop()
	fixture.initial_balance = fixture.core.nutrition
	fixture.initial_recovered = fixture.progress.get_total_recovered()
	_observe(fixture)
	_check_defaults(fixture)
	return fixture


func _observe(fixture: Fixture) -> void:
	fixture.organ.digestion_started.connect(func(task_id: String, chamber_id: int, input_id: String, nutrition: int) -> void:
		fixture.starts.append({"task_id": task_id, "chamber_id": chamber_id, "input_id": input_id,
			"nutrition": nutrition, "frame": Engine.get_physics_frames(), "time": _now()}))
	fixture.organ.digestion_completed.connect(func(task_id: String, chamber_id: int, product_id: String, nutrition: int) -> void:
		fixture.completions.append({"task_id": task_id, "chamber_id": chamber_id, "product_id": product_id,
			"nutrition": nutrition, "frame": Engine.get_physics_frames(), "time": _now()}))
	fixture.organ.product_created.connect(func(product_id: String, nutrition: int) -> void:
		fixture.products.append({"product_id": product_id, "nutrition": nutrition, "frame": Engine.get_physics_frames()}))
	fixture.organ.digested.connect(func(nutrition: int) -> void: fixture.digestions.append(nutrition))
	fixture.core.digestion_product_arrived.connect(func(product_id: String, nutrition: int) -> void:
		fixture.receipts.append({"product_id": product_id, "nutrition": nutrition,
			"frame": Engine.get_physics_frames(), "time": _now()}))


func _check_defaults(fixture: Fixture) -> void:
	_check(fixture.organ.capacity == 4 and is_equal_approx(fixture.organ.digest_timer.wait_time, 1.5),
		fixture.context + ": original intake capacity four and primary duration 1.5 are retained")
	for path: String in ["DigestTimer", "SecondDigestTimer"]:
		var timer: Timer = fixture.organ.get_node(path) as Timer
		_check(timer.one_shot and timer.process_callback == Timer.TIMER_PROCESS_PHYSICS
			and is_equal_approx(timer.wait_time, 1.5), fixture.context + ": chamber Timer keeps frozen defaults")
	var expansion: Timer = fixture.organ.get_node("ChamberExpansionTimer") as Timer
	_check(expansion.one_shot and expansion.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and is_equal_approx(expansion.wait_time, 3.0), fixture.context + ": expansion uses its real three-second Timer")
	_check(is_equal_approx(fixture.returns.packet_speed, 80.0)
		and is_equal_approx(fixture.returns.dispatch_interval, 0.35),
		fixture.context + ": return speed and dispatch interval retain original defaults")


func _add_source(fixture: Fixture, nutrition: int, at_stomach: bool = false) -> EnemyRemains:
	var remains: EnemyRemains = REMAINS_SCENE.instantiate() as EnemyRemains
	_source_serial += 1
	remains.name = "ExplicitCorpse_%d" % _source_serial
	remains.nutrition_value = nutrition
	var source_node: Node2D = fixture.stomach_node if at_stomach else fixture.collection_node
	# 同一位置的独立尸体在同一物理帧拾取，仍走 RemainsPacket 的真实地面移动。
	remains.position = fixture.remains.to_local(source_node.global_position + Vector2(4.0 if at_stomach else 2.0, 0.0))
	fixture.remains.add_child(remains)
	fixture.source_nutrition += nutrition
	return remains


func _pump_recycling(fixture: Fixture) -> void:
	for _attempt: int in range(fixture.organ.capacity):
		if fixture.organ.get_queued_count() + fixture.organ.incoming_remains >= fixture.organ.capacity:
			break
		if not fixture.recycling.try_dispatch():
			break


func _pump_returns(fixture: Fixture) -> void:
	for _attempt: int in range(2):
		if not fixture.returns.try_dispatch():
			break


func _step(fixture: Fixture, collect: bool = false, return_output: bool = false) -> void:
	if collect:
		_pump_recycling(fixture)
	if return_output:
		_pump_returns(fixture)
	await physics_frame
	await process_frame
	_sampled_frames += 1
	if fixture.audit:
		_check_conservation(fixture)
	if _sampled_frames >= RUN_FRAME_LIMIT:
		_check(false, "Parallel digestion integration exceeded its bounded global frame budget")
		_finish()


func _until(fixture: Fixture, predicate: Callable, message: String,
		collect: bool = false, return_output: bool = false) -> bool:
	for _frame: int in range(FRAME_LIMIT):
		if bool(predicate.call()):
			break
		await _step(fixture, collect, return_output)
	var reached: bool = bool(predicate.call())
	_check(reached, message)
	return reached


func _advance_seconds(fixture: Fixture, seconds: float,
		collect: bool = false, return_output: bool = false) -> void:
	var deadline: float = _now() + seconds
	for _frame: int in range(FRAME_LIMIT):
		if _now() >= deadline:
			break
		await _step(fixture, collect, return_output)
	_check(_now() >= deadline, fixture.context + ": bounded real physics wait reached its deadline")


func _check_conservation(fixture: Fixture) -> void:
	var digestion: Dictionary = fixture.organ.get_digestion_snapshot()
	var output: Dictionary = fixture.organ.get_output_snapshot()
	var transport: Dictionary = fixture.returns.get_return_snapshot()
	var ground: int = 0
	var remains_transit: int = 0
	var claimed_sources: int = 0
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and not child.is_queued_for_deletion():
			var source: EnemyRemains = child as EnemyRemains
			if source.is_available():
				ground += source.nutrition_value
			else:
				remains_transit += source.nutrition_value
				claimed_sources += 1
		elif child is LargeCarcass and not child.is_queued_for_deletion():
			ground += (child as LargeCarcass).get_remaining_nutrition()
	var received: int = fixture.core.nutrition - fixture.initial_balance
	var receipt_nutrition: int = 0
	for receipt: Dictionary in fixture.receipts:
		receipt_nutrition += int(receipt["nutrition"])
	var intake: int = fixture.organ.get_queued_nutrition()
	var products: int = fixture.organ.get_output_nutrition()
	conservation_checks += 1
	_check(ground + remains_transit + intake + products + received == fixture.source_nutrition,
		fixture.context + ": unused ground, claimed corpse transit, intake, outputs and receipts conserve all explicit sources")
	_check(received == receipt_nutrition and products + received == fixture.organ.total_nutrition_produced,
		fixture.context + ": only actual receipts credit the core and all produced nutrition has one owner")
	_check(claimed_sources == fixture.recycling.get_in_transit_count()
		and fixture.organ.incoming_remains == claimed_sources,
		fixture.context + ": incoming reservations reference the one claimed corpse cargo instead of adding nutrition")
	_check(fixture.organ.get_queued_count() == int(digestion["intake_count"])
		and int(digestion["intake_count"]) == int(digestion["waiting_count"]) + int(digestion["active_count"])
		and fixture.organ.get_waiting_count() == int(digestion["waiting_count"]),
		fixture.context + ": authoritative intake already includes each active chamber's corpse")
	_check(fixture.organ.get_queued_count() + fixture.organ.incoming_remains <= 4,
		fixture.context + ": accepted intake and incoming reservations respect capacity four")
	_check(int(output["count"]) + int(output["reserved_count"]) <= 2
		and int(output["nutrition"]) + int(output["reserved_nutrition"]) <= 20,
		fixture.context + ": products plus active reservations respect both output bounds")
	_check(int(output["count"]) == int(output["queued_count"]) + int(output["in_transit_count"])
		and int(transport["queued_nutrition"]) + int(transport["in_transit_nutrition"]) == products
		and int(output["in_transit_count"]) == fixture.returns.get_in_transit_count(),
		fixture.context + ": return transit remains inside product ownership and is never added a second time")
	var chambers: Array = digestion["chambers"]
	_check(chambers.size() == 2, fixture.context + ": snapshot always exposes both chamber positions")
	var reserved_count: int = 0
	var reserved_nutrition: int = 0
	var inputs: Dictionary = {}
	var tasks: Dictionary = {}
	for chamber: Dictionary in chambers:
		if not String(chamber["task_id"]).is_empty():
			_check(not inputs.has(chamber["input_id"]) and not tasks.has(chamber["task_id"]),
				fixture.context + ": simultaneous chambers have unique input and task ownership")
			inputs[chamber["input_id"]] = true
			tasks[chamber["task_id"]] = true
			reserved_count += 1
			reserved_nutrition += int(chamber["reserved_nutrition"])
			_check(is_equal_approx(float(chamber["duration"]), 1.5)
				and int(chamber["reserved_nutrition"]) == int(chamber["nutrition"]),
				fixture.context + ": each live task captures default duration and reserves its exact nutrition")
	_check(reserved_count == int(output["reserved_count"])
		and reserved_nutrition == int(output["reserved_nutrition"]),
		fixture.context + ": aggregate reservations equal the sum of active tasks")
	_check(fixture.progress.get_total_recovered() - fixture.initial_recovered == receipt_nutrition,
		fixture.context + ": progression follows real receipts without inventory or balance edits")
	fixture.maximum_intake = maxi(fixture.maximum_intake, int(digestion["intake_count"]))
	fixture.maximum_active = maxi(fixture.maximum_active, int(digestion["active_count"]))
	fixture.maximum_waiting = maxi(fixture.maximum_waiting, int(digestion["waiting_count"]))
	fixture.maximum_reserved_count = maxi(fixture.maximum_reserved_count, int(output["reserved_count"]))
	fixture.maximum_reserved_nutrition = maxi(fixture.maximum_reserved_nutrition, int(output["reserved_nutrition"]))
	fixture.maximum_output_count = maxi(fixture.maximum_output_count, int(output["count"]))
	fixture.maximum_output_nutrition = maxi(fixture.maximum_output_nutrition, int(output["nutrition"]))
	if int(digestion["active_count"]) == 2:
		fixture.dual_busy_frames += 1
	for packet: Node in fixture.recovery_packets.get_children():
		if packet is RemainsPacket:
			_check(is_equal_approx((packet as RemainsPacket).speed, 140.0),
				fixture.context + ": physical corpse packets retain their default speed")
	for packet: Node in fixture.return_packets.get_children():
		if packet is NutrientPacket:
			_check(is_equal_approx((packet as NutrientPacket).speed, 80.0),
				fixture.context + ": physical return packets retain their default speed")


func _test_real_threshold_and_expansion(fixture: Fixture) -> bool:
	var transitions: Array[Vector2i] = []
	fixture.progress.stage_changed.connect(func(before: ColonyProgress.Stage, after: ColonyProgress.Stage) -> void:
		transitions.append(Vector2i(before, after)))
	# 十五具十营养尸体和一具九营养尸体；不写余额、累计缓存或首次信号。
	for batch: int in range(16):
		var nutrition: int = 9 if batch == 15 else 10
		var before: int = fixture.progress.get_total_recovered()
		_add_source(fixture, nutrition, true)
		if not await _until(fixture, func() -> bool: return fixture.organ.get_output_count() == 1,
			"Real corpse haul and normal digestion produce pre-threshold batch %d" % batch, true):
			return false
		_check(fixture.progress.get_total_recovered() == before and fixture.core.nutrition == 72 + before,
			"Collection and timer completion cannot credit nutrition before return arrival")
		_check(fixture.returns.try_dispatch(), "Pre-threshold product starts a real green return")
		_check(fixture.returns.get_in_transit_count() == 1 and fixture.progress.get_total_recovered() == before,
			"An in-flight threshold product does not advance recovery")
		if not await _until(fixture, func() -> bool: return fixture.progress.get_total_recovered() == before + nutrition,
			"The physical pre-threshold return arrives exactly once"):
			return false
		_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 1,
			"Every actual receipt below 160 preserves the original single chamber")
	var at_159: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(fixture.progress.get_total_recovered() == 159
		and fixture.progress.get_stage() == ColonyProgress.Stage.EXPANDED
		and not fixture.capabilities.can_expand_second_digestive_chamber()
		and at_159["expansion_state"] == &"locked" and at_159["chamber_count"] == 1,
		"Exactly 159 real recovered nutrition leaves the second chamber locked")
	evidence.append({"case": "159_real_receipts", "recovered": 159, "receipts": fixture.receipts.size(),
		"chamber_count": at_159["chamber_count"], "core_nutrition": fixture.core.nutrition})
	_add_source(fixture, 1, true)
	if not await _until(fixture, func() -> bool: return fixture.organ.get_output_count() == 1,
		"The one-nutrition threshold corpse is digested by the real primary timer", true):
		return false
	_check(fixture.returns.try_dispatch(), "Threshold 160 has a real in-flight return")
	await _advance_seconds(fixture, 1.25)
	_check(fixture.progress.get_total_recovered() == 159 and fixture.returns.get_in_transit_count() == 1,
		"The formal default return distance leaves threshold income uncredited partway")
	_add_source(fixture, 5, true)
	if not await _until(fixture, func() -> bool: return fixture.organ.get_digestion_snapshot()["active_count"] == 1,
		"An independent primary corpse begins before the threshold return arrives", true):
		return false
	var primary_before: Dictionary = (fixture.organ.get_digestion_snapshot()["chambers"] as Array)[0]
	if not await _until(fixture, func() -> bool: return fixture.progress.get_total_recovered() == 160,
		"An actual green packet receipt, rather than production, crosses 160"):
		return false
	var expansion_start: float = _now()
	var expanded: Dictionary = fixture.organ.get_digestion_snapshot()
	var primary_after: Dictionary = (expanded["chambers"] as Array)[0]
	_check(expanded["expansion_state"] == &"expanding" and expanded["chamber_count"] == 1
		and is_equal_approx(float(expanded["expansion_duration"]), 3.0),
		"Receipt 160 begins a real three-second expansion while the organ still has one chamber")
	_check(primary_after["task_id"] == primary_before["task_id"]
		and primary_after["input_id"] == primary_before["input_id"]
		and float(primary_after["remaining"]) > 0.0
		and float(primary_after["remaining"]) < float(primary_before["remaining"]),
		"Unlocking preserves the ongoing primary task, corpse and naturally decreasing remaining time")
	_check(transitions == [Vector2i(0, 1), Vector2i(1, 2)],
		"Only the two real arrival thresholds publish their two stage transitions")
	# 派送真实五营养产物，保证展开结束时有空输出位；靠近结束时再入两具尸体。
	for _frame: int in range(FRAME_LIMIT):
		if _now() - expansion_start >= 2.40:
			break
		await _step(fixture, false, true)
		_check(fixture.organ.get_digestion_snapshot()["chamber_count"] == 1,
			"Second chamber cannot become usable during the first 2.4 real seconds of expansion")
	_add_source(fixture, 6, true)
	_add_source(fixture, 7, true)
	if not await _until(fixture, func() -> bool:
		return (fixture.organ.get_digestion_snapshot()["active_count"] == 1
			and fixture.organ.get_waiting_count() == 1),
		"Before expansion ends one real corpse is active and the other remains waiting", true, true):
		return false
	var before_ready: Dictionary = fixture.organ.get_digestion_snapshot()
	var primary_at_wait: Dictionary = (before_ready["chambers"] as Array)[0]
	var wait_start: float = _now()
	if not await _until(fixture, func() -> bool: return fixture.organ.get_digestion_snapshot()["chamber_count"] == 2,
		"The real expansion timer unlocks exactly two chambers", false, true):
		return false
	var elapsed: float = _now() - expansion_start
	var ready: Dictionary = fixture.organ.get_digestion_snapshot()
	var chambers: Array = ready["chambers"]
	_check(elapsed >= 3.0 - TIMING_EPSILON and elapsed <= 3.0 + TIMING_EPSILON,
		"Opening the second chamber requires the full three physics seconds")
	_check(ready["expansion_state"] == &"ready" and ready["active_count"] == 2
		and int(chambers[0]["nutrition"]) == 6 and int(chambers[1]["nutrition"]) == 7,
		"Ready state overlaps two distinct admitted corpses on two actual timers")
	_check(chambers[0]["task_id"] == primary_at_wait["task_id"]
		and chambers[0]["input_id"] == primary_at_wait["input_id"]
		and absf(float(chambers[0]["remaining"]) - (float(primary_at_wait["remaining"]) - (_now() - wait_start))) <= TIMING_EPSILON,
		"Expansion completion neither restarts nor retimes the first chamber")
	_check(chambers[0]["task_id"] != chambers[1]["task_id"] and chambers[0]["input_id"] != chambers[1]["input_id"],
		"Concurrent real corpses obtain distinct immutable task and input identifiers")
	evidence.append({"case": "160_real_receipt_and_expansion", "threshold": 160,
		"elapsed_seconds": elapsed, "primary_preserved": chambers[0]["task_id"] == primary_at_wait["task_id"],
		"primary_remaining": chambers[0]["remaining"], "secondary_remaining": chambers[1]["remaining"],
		"concurrent_nutrition": [chambers[0]["nutrition"], chambers[1]["nutrition"]]})
	if not await _until(fixture, func() -> bool:
		return (fixture.organ.get_queued_count() == 0 and fixture.organ.get_output_count() == 0
			and fixture.returns.get_in_transit_count() == 0),
		"Both real chambers finish and settle all post-threshold nutrition", false, true):
		return false
	_check(fixture.progress.get_total_recovered() == 178 and fixture.core.nutrition == 250,
		"All real returns conserve original capital and explicit 178 source nutrition")
	_check_exactly_once(fixture, "Formal threshold cycle")
	return true


func _benchmark(fixture: Fixture, chamber_count: int) -> Dictionary:
	for _corpse: int in range(BENCHMARK_CORPSES):
		_add_source(fixture, BENCHMARK_NUTRITION)
	var began: float = _now()
	var complete: bool = await _until(fixture, func() -> bool:
		return fixture.receipts.size() == BENCHMARK_CORPSES,
		fixture.context + ": sufficiently fed queue delivers all twelve real products", true, true)
	var elapsed: float = _now() - began
	_check(fixture.maximum_intake == 4 and fixture.maximum_waiting >= 2,
		fixture.context + ": benchmark fills unchanged intake and retains a real waiting queue")
	_check(fixture.maximum_active == chamber_count,
		fixture.context + ": measured work uses the requested real chamber count")
	_check(fixture.recycling.delivered_count == BENCHMARK_CORPSES
		and fixture.returns.delivered_count == BENCHMARK_CORPSES
		and fixture.core.nutrition == 72 + BENCHMARK_CORPSES * BENCHMARK_NUTRITION,
		fixture.context + ": physical haul, production and receipt counters account for all sources")
	_check_exactly_once(fixture, fixture.context)
	var measurement: Dictionary = {
		"case": fixture.context, "complete": complete, "chambers": chamber_count,
		"corpses": BENCHMARK_CORPSES, "nutrition": BENCHMARK_CORPSES * BENCHMARK_NUTRITION,
		"elapsed_seconds": elapsed, "products_per_second": float(BENCHMARK_CORPSES) / maxf(elapsed, 0.001),
		"return_route_length": fixture.return_edge.get_length(), "return_speed": fixture.returns.packet_speed,
		"intake_capacity": fixture.organ.capacity, "digest_duration": fixture.organ.digest_timer.wait_time,
		"maximum_intake": fixture.maximum_intake, "maximum_waiting": fixture.maximum_waiting,
		"maximum_active": fixture.maximum_active, "dual_busy_frames": fixture.dual_busy_frames,
	}
	evidence.append(measurement)
	return measurement


func _test_throughput_same_frame_and_recovery(formal: Fixture) -> void:
	var single: Fixture = _new_benchmark_fixture()
	_check(single.organ.get_digestion_snapshot()["chamber_count"] == 1
		and single.organ.get_digestion_snapshot()["expansion_state"] == &"locked",
		"Default fixture stays single chamber without mature recovery")
	var single_measurement: Dictionary = await _benchmark(single, 1)
	_check(single.progress.get_total_recovered() == 48 and single.organ.get_digestion_snapshot()["chamber_count"] == 1,
		"Twelve original four-nutrition corpses leave the default organ single chamber")
	await _dispose(single)
	var dual: Fixture = _new_benchmark_fixture(formal.capabilities)
	_check(dual.capabilities.colony_progress == formal.progress and formal.progress.get_total_recovered() >= 160,
		"Dual benchmark binds the formal colony already matured by actual receipts")
	var expansion_began: float = _now()
	if not await _until(dual, func() -> bool: return dual.organ.get_digestion_snapshot()["chamber_count"] == 2,
		"Benchmark late-bound organ waits for its real expansion timer"):
		await _dispose(dual)
		return
	_check(_now() - expansion_began >= 3.0 - TIMING_EPSILON,
		"Benchmark does not bypass real three-second unfolding before measurement")
	var dual_measurement: Dictionary = await _benchmark(dual, 2)
	var gain: float = float(dual_measurement["products_per_second"]) / maxf(float(single_measurement["products_per_second"]), 0.001)
	_check(bool(single_measurement["complete"]) and bool(dual_measurement["complete"])
		and gain >= 1.60 and float(dual_measurement["elapsed_seconds"]) <= float(single_measurement["elapsed_seconds"]) * 0.65,
		"Real dual digestion produces measured throughput gain on the same free-flowing path")
	_check(dual.dual_busy_frames >= 120,
		"Throughput gain includes sustained simultaneous timer work rather than only faster return dispatch")
	evidence.append({"case": "measured_throughput_gain", "gain": gain,
		"single_seconds": single_measurement["elapsed_seconds"], "double_seconds": dual_measurement["elapsed_seconds"],
		"same_source_values_geometry_capacity_duration_and_speeds": true,
		"expansion_excluded_from_steady_state_measurement": true})
	await _test_same_frame_completion(dual)
	await _test_disconnection_recovery(dual)
	await _dispose(dual)


func _timer_callbacks(organ: DigestiveOrgan, paths: Array[String]) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for path: String in paths:
		var timer: Timer = organ.get_node(path) as Timer
		for connection: Dictionary in timer.get_signal_connection_list(&"timeout"):
			var callback: Callable = connection["callable"]
			callbacks.append(callback)
	return callbacks


func _test_same_frame_completion(fixture: Fixture) -> void:
	var start_count: int = fixture.starts.size()
	var completion_count: int = fixture.completions.size()
	var product_count: int = fixture.products.size()
	var digestion_count: int = fixture.digestions.size()
	var receipt_count: int = fixture.receipts.size()
	_add_source(fixture, 6, true)
	_add_source(fixture, 7, true)
	if not await _until(fixture, func() -> bool: return fixture.organ.get_digestion_snapshot()["active_count"] == 2,
		"Two independent real corpses occupy both real chambers in the same pickup frame", true):
		return
	_check(fixture.starts.size() == start_count + 2, "Both real claims publish their required start events")
	if fixture.starts.size() != start_count + 2:
		return
	var started_a: Dictionary = fixture.starts[start_count]
	var started_b: Dictionary = fixture.starts[start_count + 1]
	_check(started_a["frame"] == started_b["frame"] and started_a["input_id"] != started_b["input_id"]
		and started_a["task_id"] != started_b["task_id"] and started_a["chamber_id"] != started_b["chamber_id"],
		"Distinct physical corpses start two task-bound timers in exactly one physics frame")
	var old_callbacks: Array[Callable] = _timer_callbacks(fixture.organ, ["DigestTimer", "SecondDigestTimer"])
	_check(old_callbacks.size() == 2, "Actual processing timers expose two captured task callbacks")
	if not await _until(fixture, func() -> bool: return fixture.completions.size() == completion_count + 2,
		"Both real chamber timers complete their same-frame pair"):
		return
	var completed_a: Dictionary = fixture.completions[completion_count]
	var completed_b: Dictionary = fixture.completions[completion_count + 1]
	_check(completed_a["frame"] == completed_b["frame"]
		and completed_a["task_id"] != completed_b["task_id"]
		and completed_a["product_id"] != completed_b["product_id"],
		"Same-frame completion commits two distinct products exactly once")
	_check(fixture.products.size() == product_count + 2 and fixture.digestions.size() == digestion_count + 2
		and fixture.organ.get_output_count() == 2 and fixture.organ.get_output_nutrition() == 13,
		"Each same-frame commit publishes one legacy product and digestion event")
	_check(fixture.receipts.size() == receipt_count, "Same-frame timer completion never credits either product before transport")
	for product: Dictionary in fixture.organ.get_output_products():
		_check(product.has("task_id") and product.has("input_id") and product.has("chamber_id"),
			"Real output keeps its committed task, input and chamber metadata")
		var expected: Dictionary = started_a if product.get("task_id", "") == started_a["task_id"] else started_b
		_check(product.get("task_id", "") == expected["task_id"]
			and product.get("input_id", "") == expected["input_id"]
			and product.get("chamber_id", -1) == expected["chamber_id"]
			and product["nutrition"] == expected["nutrition"],
			"Each real output identifies exactly the corpse and chamber that committed it")
	_pump_returns(fixture)
	_check(fixture.returns.get_in_transit_count() == 2 and fixture.organ.get_output_count() == 2,
		"Two real return packets retain both same-frame output slots until arrival")
	if not await _until(fixture, func() -> bool: return fixture.receipts.size() == receipt_count + 2,
		"Same-frame product pair reaches the real core exactly once"):
		return
	_check(fixture.receipts[receipt_count]["frame"] == fixture.receipts[receipt_count + 1]["frame"],
		"Equal-speed free-flowing returns settle both distinct products in one physics frame")
	var before_balance: int = fixture.core.nutrition
	for callback: Callable in old_callbacks:
		_check(callback.is_valid(), "Completed task callback remains callable for stale identity testing")
		if callback.is_valid():
			callback.call()
	for receipt: Dictionary in fixture.receipts.slice(receipt_count):
		_check(not fixture.core.accept_digestion_product(String(receipt["product_id"]), int(receipt["nutrition"])),
			"Replaying an actually arrived product cannot credit it a second time")
	_check(fixture.core.nutrition == before_balance and fixture.completions.size() == completion_count + 2
		and fixture.products.size() == product_count + 2 and fixture.receipts.size() == receipt_count + 2,
		"Saved completed timer callbacks and duplicate real receipt IDs have no second effect")
	_check_exactly_once(fixture, "Same-frame pair")
	_check_conservation(fixture)
	evidence.append({"case": "same_frame_real_completion_and_receipt", "start_frame": started_a["frame"],
		"completion_frame": completed_a["frame"], "receipt_frame": fixture.receipts[receipt_count]["frame"],
		"distinct_inputs": [started_a["input_id"], started_b["input_id"]],
		"distinct_products": [completed_a["product_id"], completed_b["product_id"]], "nutrition": 13})


func _test_disconnection_recovery(fixture: Fixture) -> void:
	var received_before: int = fixture.core.nutrition
	var receipt_count: int = fixture.receipts.size()
	var produced_before: int = fixture.organ.digested_count
	for nutrition: int in [8, 12, 5, 5]:
		_add_source(fixture, nutrition, true)
	if not await _until(fixture, func() -> bool:
		return fixture.organ.get_queued_count() == 4 and fixture.organ.incoming_remains == 0,
		"Four real corpses fill unchanged intake before disconnecting the return route", true):
		return
	var initial: Dictionary = fixture.organ.get_output_snapshot()
	_check(initial["reserved_count"] == 2 and initial["reserved_nutrition"] == 20,
		"Two real tasks atomically reserve the exact twenty-nutrition output boundary")
	# 真正断开唯一回流边；临时禁行仍允许产物被真实包领取并在节点等待。
	var return_endpoint: Node2D = fixture.return_edge.end_node
	fixture.return_edge.end_node = null
	await _advance_seconds(fixture, 2.0, false, true)
	var blocked: Dictionary = fixture.organ.get_output_snapshot()
	var digest: Dictionary = fixture.organ.get_digestion_snapshot()
	_check(fixture.organ.digested_count == produced_before + 2 and blocked["count"] == 2
		and blocked["nutrition"] == 20 and blocked["reserved_count"] == 0,
		"Disconnected dual digestion stops at exactly two products and twenty output nutrition")
	_check(digest["active_count"] == 0 and digest["waiting_count"] == 2
		and fixture.organ.get_queued_nutrition() == 10,
		"Full disconnected output preserves both remaining corpses in waiting intake")
	_check(fixture.core.nutrition == received_before and fixture.receipts.size() == receipt_count
		and fixture.returns.get_in_transit_count() == 0
		and fixture.returns.get_return_snapshot()["wait_reason"] == &"disconnected",
		"No disconnected output is credited or lost through a return claim")
	fixture.return_edge.end_node = return_endpoint
	_pump_returns(fixture)
	var in_flight: Dictionary = fixture.organ.get_output_snapshot()
	_check(fixture.returns.get_in_transit_count() == 2 and in_flight["count"] == 2
		and in_flight["nutrition"] == 20 and in_flight["reserved_count"] == 0,
		"Reconnect sends two actual returns while both products still occupy output capacity")
	await _advance_seconds(fixture, 0.10)
	_check(fixture.core.nutrition == received_before and fixture.organ.get_output_nutrition() == 20,
		"Halfway along the real return path cannot release capacity or credit nutrition")
	if not await _until(fixture, func() -> bool: return fixture.receipts.size() == receipt_count + 2,
		"Both full-buffer products actually return after reconnect"):
		return
	var resumed: Dictionary = fixture.organ.get_output_snapshot()
	_check(resumed["reserved_count"] == 2 and resumed["reserved_nutrition"] == 10
		and fixture.organ.get_digestion_snapshot()["active_count"] == 2
		and fixture.organ.get_queued_count() == 2 and fixture.organ.get_queued_nutrition() == 10,
		"Actual settlement frees capacity and resumes both retained corpses while preserving intake ownership")
	if not await _until(fixture, func() -> bool: return fixture.receipts.size() == receipt_count + 4,
		"Recovered dual digestion returns all four corpses with no loss", false, true):
		return
	_check(fixture.core.nutrition == received_before + 30 and fixture.organ.get_output_count() == 0
		and fixture.organ.get_queued_count() == 0,
		"Disconnect and reconnect conserve thirty nutrition with no orphan products or intake")
	_check_exactly_once(fixture, "Disconnected recovery")
	evidence.append({"case": "disconnect_reconnect_output_bounds", "reserved_count": initial["reserved_count"],
		"reserved_nutrition": initial["reserved_nutrition"], "blocked_products": blocked["count"],
		"blocked_nutrition": blocked["nutrition"], "waiting_nutrition": 10,
		"in_flight_products_still_owned": in_flight["count"], "recovered_nutrition": fixture.core.nutrition - received_before})


func _check_exactly_once(fixture: Fixture, context: String) -> void:
	var task_ids: Dictionary = {}
	var input_ids: Dictionary = {}
	var completed_tasks: Dictionary = {}
	var product_ids: Dictionary = {}
	var receipt_ids: Dictionary = {}
	for started: Dictionary in fixture.starts:
		_check(not task_ids.has(started["task_id"]) and not input_ids.has(started["input_id"]),
			context + ": a delivered corpse is claimed by one unique digestion task")
		task_ids[started["task_id"]] = started
		input_ids[started["input_id"]] = true
	for completed: Dictionary in fixture.completions:
		_check(task_ids.has(completed["task_id"]) and not completed_tasks.has(completed["task_id"])
			and not product_ids.has(completed["product_id"]),
			context + ": a real completion belongs to one started task and one unique product")
		completed_tasks[completed["task_id"]] = true
		product_ids[completed["product_id"]] = completed
		if task_ids.has(completed["task_id"]):
			var started: Dictionary = task_ids[completed["task_id"]]
			_check(started["chamber_id"] == completed["chamber_id"] and started["nutrition"] == completed["nutrition"]
				and float(completed["time"]) - float(started["time"]) >= 1.5 - TIMING_EPSILON,
				context + ": task identity and original digestion duration survive the commit")
	for receipt: Dictionary in fixture.receipts:
		_check(product_ids.has(receipt["product_id"]) and not receipt_ids.has(receipt["product_id"]),
			context + ": every actual arrival settles one distinct produced product once")
		if product_ids.has(receipt["product_id"]):
			_check(int(product_ids[receipt["product_id"]]["nutrition"]) == int(receipt["nutrition"]),
				context + ": real receipt value equals the committed immutable product")
		receipt_ids[receipt["product_id"]] = true
	_check(fixture.starts.size() == fixture.completions.size()
		and fixture.completions.size() == fixture.products.size()
		and fixture.products.size() == fixture.digestions.size()
		and fixture.organ.digested_count == fixture.completions.size()
		and fixture.returns.delivered_count == fixture.receipts.size(),
		context + ": per-chamber, legacy production and real receipt counters have matching exactly-once totals")


func _test_late_binding_and_real_restart(fixture: Fixture) -> void:
	fixture.context = "Formal restart cycle"
	# 基准双室的真实收件也被同一进度对象观察；仅更新测试观察基线，不写进度或余额。
	fixture.initial_recovered = fixture.progress.get_total_recovered() - (fixture.core.nutrition - fixture.initial_balance)
	var late: DigestiveOrgan = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	late.name = "LateDigestiveOrgan"
	late.mother_core = fixture.core
	var late_host: HyphaNode = HYPHA_NODE_SCENE.instantiate() as HyphaNode
	late_host.name = "LateDigestiveHost"
	late_host.position = Vector2(900.0, 590.0)
	fixture.host.get_node("World/Colony/Nodes").add_child(late_host)
	late_host.add_child(late)
	await process_frame
	await process_frame
	_check(late.colony_capabilities == fixture.capabilities,
		"An organ added to the formal mature level receives capability through real level registration")
	var late_snapshot: Dictionary = late.get_digestion_snapshot()
	_check(late_snapshot["expansion_state"] == &"expanding" and late_snapshot["chamber_count"] == 1,
		"A late-added stomach queries already mature capability and begins real expansion")
	await _advance_seconds(fixture, 1.0)
	var remaining_before_binding: float = float(late.get_digestion_snapshot()["expansion_remaining"])
	late.configure_capabilities(fixture.capabilities)
	late.configure_capabilities(fixture.capabilities)
	_check(absf(float(late.get_digestion_snapshot()["expansion_remaining"]) - remaining_before_binding) <= TIMING_EPSILON,
		"Repeated binding cannot restart a late organ's running expansion")
	if not await _until(fixture, func() -> bool: return late.get_digestion_snapshot()["chamber_count"] == 2,
		"Formally registered late-added stomach completes its real expansion"):
		return
	late.configure_capabilities(fixture.capabilities)
	_check(late.get_digestion_snapshot()["chamber_count"] == 2
		and late.get_digestion_snapshot()["expansion_state"] == &"ready",
		"Rebinding a ready organ cannot create a third chamber")
	var pending_expansion: DigestiveOrgan = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	pending_expansion.name = "RestartExpandingOrgan"
	pending_expansion.mother_core = fixture.core
	var expansion_host: HyphaNode = HYPHA_NODE_SCENE.instantiate() as HyphaNode
	expansion_host.name = "RestartDigestiveHost"
	expansion_host.position = Vector2(900.0, 710.0)
	fixture.host.get_node("World/Colony/Nodes").add_child(expansion_host)
	expansion_host.add_child(pending_expansion)
	await process_frame
	await process_frame
	var old_expansion: Array[Callable] = _timer_callbacks(pending_expansion, ["ChamberExpansionTimer"])
	_check(old_expansion.size() == 1, "Pending late organ exposes its captured real expansion callback")
	_add_source(fixture, 6, true)
	if not await _until(fixture, func() -> bool: return fixture.organ.get_digestion_snapshot()["active_count"] == 1,
		"First physical main-stomach task starts before the restart fixture's second corpse", true):
		return
	await _advance_seconds(fixture, 0.25)
	_add_source(fixture, 7, true)
	if not await _until(fixture, func() -> bool: return fixture.organ.get_digestion_snapshot()["active_count"] == 2,
		"Two physical main-stomach tasks expose independent restart callbacks", true):
		return
	var old_tasks: Array[Callable] = _timer_callbacks(fixture.organ, ["DigestTimer", "SecondDigestTimer"])
	_check(old_tasks.size() == 2, "Real R saves two captured digestion callbacks")
	if not await _until(fixture, func() -> bool: return fixture.organ.get_output_count() == 1,
		"The first real timer completes while the second restart task is still processing"):
		return
	var has_real_return: bool = fixture.organ.get_digestion_snapshot()["active_count"] == 1 and fixture.returns.try_dispatch()
	_check(has_real_return, "R is staged with one real task active and one real return in flight")
	if not has_real_return:
		return
	var return_record: Dictionary = fixture.returns.get_shipment_records().back()
	var old_return_packet: NutrientPacket = return_record["packet"] as NutrientPacket
	_check(is_instance_valid(old_return_packet), "R fixture retains the live physical return packet")
	if not is_instance_valid(old_return_packet):
		return
	var old_return_callback: Callable = Callable()
	for connection: Dictionary in old_return_packet.get_signal_connection_list(&"arrived"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == fixture.returns:
			old_return_callback = callback
	var pending_corpse: EnemyRemains = _add_source(fixture, 4, true)
	var collection_host: Node2D = fixture.host.get_node("World/Colony/Nodes/HyphaNode") as Node2D
	pending_corpse.global_position = collection_host.global_position + Vector2(8.0, 0.0)
	var has_real_remains: bool = fixture.recycling.try_dispatch()
	_check(has_real_remains, "R also holds a real corpse shipment on the original network")
	if not has_real_remains:
		return
	var old_remains_packet: RemainsPacket = null
	for packet: Node in fixture.recovery_packets.get_children():
		if packet is RemainsPacket and not packet.is_queued_for_deletion():
			old_remains_packet = packet as RemainsPacket
	_check(is_instance_valid(old_remains_packet), "R fixture retains its live physical corpse packet")
	if not is_instance_valid(old_remains_packet):
		return
	var old_remains_callback: Callable = Callable()
	for connection: Dictionary in old_remains_packet.get_signal_connection_list(&"arrived"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == fixture.recycling:
			old_remains_callback = callback
	_check(old_return_callback.is_valid() and old_remains_callback.is_valid()
		and fixture.returns.get_in_transit_count() == 1 and fixture.recycling.get_in_transit_count() == 1,
		"Real R captures both live transport callbacks without simulating either first arrival")
	_check_conservation(fixture)
	var old_progress_callback: Callable = Callable()
	for connection: Dictionary in fixture.core.get_signal_connection_list(&"digestion_product_arrived"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == fixture.progress:
			old_progress_callback = callback
	_check(old_progress_callback.is_valid(), "R saves the existing registered progress receipt callback")
	var all_organs: Array = fixture.host.call("get_digestive_organs")
	_check(all_organs.size() == 3 and all_organs.has(late) and all_organs.has(pending_expansion),
		"Formal lifecycle registry includes original and both late-added stomachs")
	var reset_evidence: Dictionary = {
		"callback_replayed": false, "all_stopped": false, "obsolete_events": -1,
		"old_return_replayed": false, "old_remains_replayed": false,
	}
	var old_completion_count: int = fixture.completions.size()
	var old_balance: int = fixture.core.nutrition
	var actual_old_receipt: Dictionary = fixture.receipts.back()
	fixture.progress.progress_changed.connect(func(total: int, _count: int) -> void:
		if total == 0:
			var all_stopped: bool = true
			for organ: DigestiveOrgan in all_organs:
				all_stopped = all_stopped and not bool(organ.get_digestion_snapshot()["enabled"])
			for callback: Callable in old_tasks + old_expansion:
				if callback.is_valid():
					callback.call()
			if old_return_callback.is_valid() and is_instance_valid(old_return_packet):
				old_return_callback.call(old_return_packet)
				reset_evidence["old_return_replayed"] = true
			if old_remains_callback.is_valid() and is_instance_valid(old_remains_packet):
				old_remains_callback.call(old_remains_packet)
				reset_evidence["old_remains_replayed"] = true
			if old_progress_callback.is_valid():
				old_progress_callback.call(String(actual_old_receipt["product_id"]), int(actual_old_receipt["nutrition"]))
			reset_evidence["callback_replayed"] = true
			reset_evidence["all_stopped"] = all_stopped
			reset_evidence["obsolete_events"] = fixture.completions.size() - old_completion_count
			_check(fixture.progress.get_total_recovered() == 0 and fixture.core.nutrition == old_balance,
				"During actual R reset saved task, expansion and receipt callbacks cannot produce or credit old work")
			_check(pending_expansion.get_digestion_snapshot()["chamber_count"] == 1,
				"A saved pending expansion callback cannot open the second chamber after cycle stop")
			_check(fixture.returns.get_in_transit_count() == 0 and fixture.recycling.get_in_transit_count() == 0,
				"Retired physical transport callbacks cannot restore cleared shipment records"))
	fixture.audit = false
	if not root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.connect(_prepare_reload_child)
	var old_host: WeakRef = weakref(fixture.host)
	var restart: InputEventKey = InputEventKey.new()
	restart.keycode = KEY_R
	restart.physical_keycode = KEY_R
	restart.pressed = true
	root.push_input(restart)
	for _frame: int in range(90):
		await process_frame
		if current_scene != null and current_scene != old_host.get_ref():
			break
	if root.child_entered_tree.is_connected(_prepare_reload_child):
		root.child_entered_tree.disconnect(_prepare_reload_child)
	var fresh_level: Node2D = current_scene as Node2D
	var changed: bool = is_instance_valid(fresh_level) and fresh_level != old_host.get_ref()
	_check(changed, "Actual physical R key input replaces the formal scene")
	_check(bool(reset_evidence["callback_replayed"]) and bool(reset_evidence["all_stopped"])
		and bool(reset_evidence["old_return_replayed"]) and bool(reset_evidence["old_remains_replayed"])
		and int(reset_evidence["obsolete_events"]) == 0,
		"R stops all registered stomachs before progress reset and rejects every obsolete timer callback")
	if not changed:
		return
	_quiet_formal(fresh_level)
	await process_frame
	var fresh: Fixture = _attach_formal(fresh_level)
	fresh.context = "Fresh real R scene"
	_check(fresh.core.nutrition == 72 and fresh.progress.get_total_recovered() == 0
		and fresh.core.get_received_product_count() == 0 and fresh.organ.digested_count == 0,
		"Fresh R round has original capital, zero products and zero observed recovery")
	var fresh_snapshot: Dictionary = fresh.organ.get_digestion_snapshot()
	_check(fresh_snapshot["enabled"] and fresh_snapshot["chamber_count"] == 1
		and fresh_snapshot["expansion_state"] == &"locked"
		and fresh.organ.colony_capabilities == fresh.capabilities,
		"Fresh formal organ starts one enabled locked chamber with its new capability binding")
	_check_defaults(fresh)
	_add_source(fresh, 4, true)
	if await _until(fresh, func() -> bool: return fresh.receipts.size() == 1,
		"Fresh R round completes an independent real corpse-to-core cycle", true, true):
		_check(fresh.progress.get_total_recovered() == 4 and fresh.core.nutrition == 76
			and fresh.organ.get_digestion_snapshot()["chamber_count"] == 1
			and fresh.organ.get_digestion_snapshot()["expansion_state"] == &"locked",
			"Fresh real income stays isolated from old mature progress and stale expansion callbacks")
		_check(fresh.receipts[0]["product_id"] != actual_old_receipt["product_id"],
			"A fresh physical product does not reuse the old received product identity")
		_check_exactly_once(fresh, "Fresh R cycle")
	evidence.append({"case": "late_organ_and_real_r", "late_chambers": 2,
		"registered_organs_before_restart": all_organs.size(), "pending_digest_callbacks": old_tasks.size(),
		"pending_expansion_callbacks": old_expansion.size(), "reset_evidence": reset_evidence,
		"in_flight_return_before_restart": 1, "in_flight_remains_before_restart": 1,
		"new_balance": fresh.core.nutrition, "new_recovered": fresh.progress.get_total_recovered(),
		"new_chambers": fresh.organ.get_digestion_snapshot()["chamber_count"]})
	await _dispose(fresh)


func _dispose(fixture: Fixture) -> void:
	fixture.audit = false
	if is_instance_valid(fixture.progress) and is_instance_valid(fixture.core):
		fixture.progress.unregister_source(fixture.core)
	if is_instance_valid(fixture.host):
		if current_scene == fixture.host:
			current_scene = null
		fixture.host.queue_free()
	await process_frame
	await process_frame
