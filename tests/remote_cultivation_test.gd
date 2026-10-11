extends SceneTree
## 用真实网络、营养包、供给和培育系统验证两阶段请求；所有推进均由测试手动控制。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const SNAPSHOT_KEYS: Array[String] = [
	"request_id", "task_id", "growth_task_id", "cultivation_task_id", "phase", "state",
	"wait_reason", "endpoint", "target_position", "progress", "network_cost", "organ_cost",
	"total_cost", "growth_consumed", "structure_consumed", "startup_reserved", "startup_transferred",
	"buffered_nutrition", "consumed_nutrition", "remaining_cost", "remaining_demand",
	"growth_snapshot", "cultivation_snapshot",
]

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var network: NetworkSystem
	var nodes: Node2D
	var edges: Node2D
	var tips: Node2D
	var packets: Node2D
	var growth: GrowthSystem
	var cultivation: CultivationSystem
	var growth_supply: GrowthSupplySystem
	var cultivation_supply: CultivationSupplySystem
	var remote: RemoteCultivationSystem
	var initial_total: int = 100
	var growth_costs: Dictionary[int, int] = {}
	var formed: Array[HyphaNode] = []
	var completed: Array[int] = []
	var cancelled: Array[int] = []
	var connected_snapshots: Array[Dictionary] = []
	var organs: Array[AttackOrgan] = []
	var maturations: int = 0

class Trigger:
	extends RefCounted

	var fired: bool = false

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var initial_children: int = root.get_child_count()
	await _test_preview_and_admission()
	await _test_existing_node_and_organ_rejection()
	await _test_normal_handoff_and_exact_budget()
	await _test_spurious_and_duplicate_completion()
	await _test_cancelled_growth_preserves_network()
	await _test_cancel_vs_connection()
	await _test_pause_each_stage()
	await _test_continue_partial_structure()
	await _test_continue_reserved_startup()
	await _test_synchronous_start_cancellation()
	await _test_endpoint_identity_and_history()
	await _test_reset_and_old_callbacks()
	await _test_reset_during_startup()
	_check(root.get_child_count() == initial_children, "Remote fixtures left root children")
	print("REMOTE_CULTIVATION_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_container(parent: Node2D) -> Node2D:
	var container: Node2D = Node2D.new()
	parent.add_child(container)
	return container


func _new_fixture(balance: int = 100, prior_blocker: bool = true) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.initial_total = balance
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = balance
	fixture.world.add_child(fixture.core)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Fixture core registration")
	fixture.nodes = _new_container(fixture.world)
	fixture.edges = _new_container(fixture.world)
	fixture.tips = _new_container(fixture.world)
	fixture.packets = _new_container(fixture.world)
	fixture.growth = GrowthSystem.new()
	fixture.growth.network_system = fixture.network
	fixture.growth.node_container = fixture.nodes
	fixture.growth.edge_container = fixture.edges
	fixture.growth.tip_container = fixture.tips
	fixture.growth.growth_speed = 320.0
	fixture.world.add_child(fixture.growth)
	fixture.growth.set_physics_process(false)
	fixture.growth.task_changed.connect(_capture_growth_cost.bind(fixture))
	fixture.growth.junction_formed.connect(func(node: HyphaNode) -> void:
		fixture.formed.append(node)
	)
	fixture.cultivation = CultivationSystem.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.growth_system = fixture.growth
	fixture.cultivation.enemy_container = _new_container(fixture.world)
	fixture.cultivation.projectile_container = _new_container(fixture.world)
	fixture.world.add_child(fixture.cultivation)
	fixture.cultivation.set_physics_process(false)
	fixture.cultivation.organ_matured.connect(_capture_maturity.bind(fixture))
	if prior_blocker:
		fixture.growth.construction_blocker = fixture.cultivation.has_active_task
	fixture.growth_supply = GrowthSupplySystem.new()
	fixture.growth_supply.growth_system = fixture.growth
	fixture.growth_supply.mother_core = fixture.core
	fixture.growth_supply.network_system = fixture.network
	fixture.growth_supply.packet_container = fixture.packets
	fixture.growth_supply.auto_supply = false
	fixture.world.add_child(fixture.growth_supply)
	fixture.growth_supply.set_process(false)
	fixture.cultivation_supply = CultivationSupplySystem.new()
	fixture.cultivation_supply.cultivation_system = fixture.cultivation
	fixture.cultivation_supply.mother_core = fixture.core
	fixture.cultivation_supply.network_system = fixture.network
	fixture.cultivation_supply.packet_container = fixture.packets
	fixture.cultivation_supply.auto_supply = false
	fixture.world.add_child(fixture.cultivation_supply)
	fixture.cultivation_supply.set_process(false)
	fixture.remote = RemoteCultivationSystem.new()
	fixture.remote.growth_system = fixture.growth
	fixture.remote.cultivation_system = fixture.cultivation
	fixture.remote.growth_supply_system = fixture.growth_supply
	fixture.remote.cultivation_supply_system = fixture.cultivation_supply
	fixture.world.add_child(fixture.remote)
	fixture.remote.request_completed.connect(func(request_id: int) -> void:
		fixture.completed.append(request_id)
	)
	fixture.remote.request_cancelled.connect(func(request_id: int) -> void:
		fixture.cancelled.append(request_id)
	)
	fixture.remote.request_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot.get("phase") == &"connected":
			fixture.connected_snapshots.append(snapshot.duplicate())
	)
	return fixture


func _dispose(fixture: Fixture) -> void:
	fixture.remote.reset()
	fixture.growth_supply.reset()
	fixture.cultivation_supply.reset()
	fixture.cultivation.reset()
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _capture_growth_cost(_snapshot: Dictionary, fixture: Fixture) -> void:
	var snapshot: Dictionary = fixture.growth.get_task_snapshot()
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		fixture.growth_costs[task_id] = maxi(int(fixture.growth_costs.get(task_id, 0)),
			int(snapshot.get("consumed_nutrition", 0)))


func _capture_maturity(_task_id: int, _host: HyphaNode, organ: AttackOrgan,
		weapon: SporeWeapon, fixture: Fixture) -> void:
	fixture.maturations += 1
	fixture.organs.append(organ)
	weapon.set_physics_process(false)


func _snapshot(fixture: Fixture) -> Dictionary:
	return fixture.remote.get_request_snapshot()


func _assert_snapshot(snapshot: Dictionary, context: String) -> void:
	_check(snapshot.has_all(SNAPSHOT_KEYS), context + ": complete request snapshot")
	if not snapshot.has_all(SNAPSHOT_KEYS):
		return
	_check(snapshot["task_id"] == snapshot["request_id"], context + ": task alias is request identity")
	_check(typeof(snapshot["phase"]) == TYPE_STRING_NAME and typeof(snapshot["state"]) == TYPE_STRING_NAME
		and typeof(snapshot["wait_reason"]) == TYPE_STRING_NAME, context + ": typed phase and states")
	_check(snapshot["organ_cost"] == 12 and snapshot["consumed_nutrition"] == snapshot["growth_consumed"]
		+ snapshot["structure_consumed"] + snapshot["startup_transferred"],
		context + ": startup transfer is part of the construction investment")
	_check(snapshot["remaining_cost"] == snapshot["total_cost"] - snapshot["consumed_nutrition"]
		and snapshot["remaining_demand"] == maxi(0, int(snapshot["remaining_cost"])
			- int(snapshot["buffered_nutrition"]) - int(snapshot["startup_reserved"])),
		context + ": refundable reserves are outside consumed investment")
	_check(float(snapshot["progress"]) >= 0.0 and float(snapshot["progress"]) <= 1.0,
		context + ": bounded progress")


func _freeze_packets(fixture: Fixture) -> void:
	for child: Node in fixture.packets.get_children():
		if child is NutrientPacket:
			child.set_physics_process(false)


func _dispatch_growth(fixture: Fixture) -> bool:
	var dispatched: bool = fixture.growth_supply.try_dispatch()
	_freeze_packets(fixture)
	return dispatched


func _dispatch_cultivation(fixture: Fixture) -> bool:
	var dispatched: bool = fixture.cultivation_supply.try_dispatch()
	_freeze_packets(fixture)
	return dispatched


func _dispatch_all_growth(fixture: Fixture) -> int:
	var dispatched: int = 0
	for attempt: int in range(32):
		if not _dispatch_growth(fixture):
			break
		dispatched += 1
	return dispatched


func _dispatch_all_cultivation(fixture: Fixture) -> int:
	var dispatched: int = 0
	for attempt: int in range(16):
		if not _dispatch_cultivation(fixture):
			break
		dispatched += 1
	return dispatched


func _deliver_records(records: Array[Dictionary]) -> void:
	for record: Dictionary in records:
		var packet: Variant = record.get("packet")
		if not bool(record.get("settled", false)) and is_instance_valid(packet) \
				and not packet.is_queued_for_deletion():
			packet._physics_process(1000.0)


func _finish_growth(fixture: Fixture) -> void:
	for step: int in range(32):
		if not fixture.growth.has_active_task():
			break
		_dispatch_all_growth(fixture)
		_deliver_records(fixture.growth_supply.get_shipment_records())
		fixture.growth.advance(20.0)
	_check(not fixture.growth.has_active_task(), "Manual growth did not reach a terminal state")


func _flush_handoff() -> void:
	await process_frame
	await process_frame


func _start(fixture: Fixture, target: Vector2 = Vector2(320.0, 0.0)) -> int:
	var request_id: int = fixture.remote.request_remote(fixture.core, target)
	_check(request_id > 0, "Remote request admission")
	return request_id


func _connect(fixture: Fixture) -> void:
	_start(fixture)
	_finish_growth(fixture)
	await _flush_handoff()
	_check(_snapshot(fixture).get("phase") == &"cultivation" and fixture.cultivation.has_active_task(),
		"Deferred handoff did not start cultivation")


func _count_buds(host: HyphaNode) -> int:
	var count: int = 0
	if is_instance_valid(host):
		for child: Node in host.get_children():
			if child is OrganBud and not child.is_queued_for_deletion():
				count += 1
	return count


func _count_tips(fixture: Fixture) -> int:
	var count: int = 0
	for child: Node in fixture.tips.get_children():
		if child is GrowthTip and not child.is_queued_for_deletion():
			count += 1
	return count


func _tip_has_no_organ(tip: Node2D) -> bool:
	if not is_instance_valid(tip):
		return false
	for child: Node in tip.get_children():
		if child is AttackOrgan or child is SporeWeapon or child is OrganBud:
			return false
	return true


func _in_transit(records: Array[Dictionary]) -> int:
	var amount: int = 0
	for record: Dictionary in records:
		if bool(record.get("debited", false)) and not bool(record.get("settled", false)) \
				and not bool(record.get("refunded", false)):
			amount += 1
	return amount


func _check_conservation(fixture: Fixture, context: String) -> void:
	var accounted: int = fixture.core.nutrition
	for consumed: int in fixture.growth_costs.values():
		accounted += consumed
	accounted += int(fixture.growth.get_task_snapshot().get("buffered_nutrition", 0))
	var cultivation_resources: Dictionary = fixture.cultivation.get_resource_snapshot()
	accounted += int(cultivation_resources.get("structure_consumed", 0))
	accounted += int(cultivation_resources.get("buffered_nutrition", 0))
	accounted += int(cultivation_resources.get("startup_reserved", 0))
	accounted += _in_transit(fixture.growth_supply.get_shipment_records())
	accounted += _in_transit(fixture.cultivation_supply.get_shipment_records())
	for organ: AttackOrgan in fixture.organs:
		if is_instance_valid(organ):
			accounted += organ.nutrition + organ.incoming_nutrition
	_check(accounted == fixture.initial_total, context + ": nutrition conservation")


func _assert_terminal_no_debits(fixture: Fixture, context: String) -> void:
	var balance: int = fixture.core.nutrition
	for attempt: int in range(4):
		_check(not _dispatch_growth(fixture) and not _dispatch_cultivation(fixture),
			context + ": terminal systems accepted a new shipment")
	fixture.growth.advance(100.0)
	fixture.cultivation.advance(100.0)
	_check(fixture.core.nutrition == balance, context + ": terminal balance changed")
	_check_conservation(fixture, context)


func _append_existing_node(fixture: Fixture, position: Vector2, registered: bool = true) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.nodes.add_child(node)
	node.global_position = position
	if registered:
		fixture.network.register_node(node)
	return node


func _test_preview_and_admission() -> void:
	var fixture: Fixture = _new_fixture()
	_assert_snapshot(_snapshot(fixture), "Idle")
	_check(_snapshot(fixture).get("state") == &"idle" and _snapshot(fixture).get("phase") == &""
		and not fixture.remote.has_active_request(), "Initial idle request")
	_check(not fixture.remote.pause_request() and not fixture.remote.resume_request()
		and not fixture.remote.cancel_request() and fixture.remote.continue_request() == 0,
		"Idle controls are inert")
	var preview: Dictionary = fixture.remote.preview_request(fixture.core, Vector2(320.0, 0.0))
	_check(bool(preview.get("valid", false)) and int(preview.get("network_cost", 0)) == 16
		and int(preview.get("organ_cost", 0)) == 12 and int(preview.get("total_cost", 0)) == 28
		and int(preview.get("remaining_cost", 0)) == 28, "320 px preview costs exactly 16 + 12")
	_check(preview.get("plan") == fixture.growth.planner.plan(Vector2.ZERO, Vector2(320.0, 0.0), false),
		"Preview uses the full existing growth plan without another endpoint fee")
	_check(fixture.core.nutrition == 100 and _count_tips(fixture) == 0, "Preview creates no geometry or payment")
	_check(not bool(fixture.remote.preview_request(fixture.core, Vector2(INF, 0.0)).get("valid", true)),
		"Invalid coordinates rejected")
	var request_id: int = _start(fixture)
	var snapshot: Dictionary = _snapshot(fixture)
	_assert_snapshot(snapshot, "Growth admission")
	_check(snapshot.get("request_id") == request_id and int(snapshot.get("growth_task_id", 0)) > 0
		and snapshot.get("cultivation_task_id") == 0 and snapshot.get("endpoint") == null,
		"New request explicitly maps one growth task and no cultivation task")
	var tip: Node2D = fixture.growth.get_delivery_target(int(snapshot.get("growth_task_id", 0)))
	_check(tip is GrowthTip and _count_tips(fixture) == 1 and _tip_has_no_organ(tip),
		"Only one temporary tip exists without an organ")
	_check(fixture.remote.request_remote(fixture.core, Vector2(0.0, 320.0)) == 0,
		"Another request cannot replace active growth")
	_check(fixture.remote.cancel_request(), "Cancel empty growth")
	_assert_terminal_no_debits(fixture, "Empty cancellation")
	await _dispose(fixture)


func _test_existing_node_and_organ_rejection() -> void:
	var fixture: Fixture = _new_fixture()
	var empty: HyphaNode = _append_existing_node(fixture, Vector2(320.0, 0.0))
	var disconnected: HyphaNode = _append_existing_node(fixture, Vector2(500.0, 0.0), false)
	var organ: AttackOrgan = ORGAN_SCENE.instantiate() as AttackOrgan
	organ.initial_nutrition = 0
	organ.position = Vector2(0.0, -28.0)
	empty.add_child(organ)
	for target: Vector2 in [Vector2(24.0, 0.0), Vector2(343.0, 0.0), Vector2(320.0, -50.0),
			disconnected.global_position + Vector2(23.0, 0.0)]:
		var preview: Dictionary = fixture.remote.preview_request(fixture.core, target)
		_check(not bool(preview.get("valid", true)) and String(preview.get("error", "")).contains("C")
			and String(preview.get("error", "")).contains("已有节点"),
			"Existing core / empty / occupied / unregistered node directs C cultivation")
		_check(fixture.remote.request_remote(fixture.core, target) == 0,
			"Execution repeats the existing-node and organ rejection")
	_check(fixture.core.nutrition == 100 and _count_tips(fixture) == 0,
		"Rejected placement creates no tip or payment")
	await _dispose(fixture)


func _test_normal_handoff_and_exact_budget() -> void:
	var fixture: Fixture = _new_fixture()
	var request_id: int = _start(fixture)
	var growth_id: int = int(_snapshot(fixture).get("growth_task_id", 0))
	_finish_growth(fixture)
	var connected: Dictionary = _snapshot(fixture)
	_assert_snapshot(connected, "Connected")
	var endpoint: HyphaNode = connected.get("endpoint") as HyphaNode
	_check(connected.get("phase") == &"connected" and connected.get("state") == &"connected"
		and endpoint == fixture.growth.get_completed_endpoint(growth_id)
		and endpoint == fixture.formed.back(), "Connected phase captures the actual final junction")
	_check(fixture.core.nutrition == 84 and connected.get("growth_consumed") == 16
		and connected.get("remaining_cost") == 12 and _count_buds(endpoint) == 0
		and fixture.cultivation.get_task_snapshot().get("task_id") == 0,
		"Synchronous completion has not started cultivation or charged the organ")
	_check(fixture.growth.create_target(fixture.core, Vector2(0.0, 320.0)) == 0,
		"Connected handoff gap reserves construction against external growth")
	await _flush_handoff()
	var cultivation: Dictionary = _snapshot(fixture)
	_assert_snapshot(cultivation, "Cultivation handoff")
	_check(cultivation.get("phase") == &"cultivation" and cultivation.get("request_id") == request_id
		and int(cultivation.get("cultivation_task_id", 0)) > 0 and _count_buds(endpoint) == 1
		and fixture.cultivation.get_delivery_target(int(cultivation.get("cultivation_task_id", 0))) == endpoint,
		"One deferred cultivation starts on the captured mature endpoint")
	_check(cultivation.get("growth_consumed") == 16 and cultivation.get("total_cost") == 28,
		"Handoff preserves paid network cost and the complete budget")
	_check(_dispatch_all_cultivation(fixture) == 12, "Cultivation dispatches exactly its existing twelve units")
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(3.1)
	var completed: Dictionary = _snapshot(fixture)
	_assert_snapshot(completed, "Mature request")
	_check(completed.get("state") == &"completed" and completed.get("phase") == &"cultivation"
		and fixture.completed == [request_id] and fixture.maturations == 1
		and endpoint.get_organ_occupant() is AttackOrgan and _count_buds(endpoint) == 0,
		"Only actual organ maturity completes the remote request")
	_check(fixture.core.nutrition == 72 and completed.get("consumed_nutrition") == 28
		and completed.get("structure_consumed") == 8 and completed.get("startup_transferred") == 4
		and completed.get("remaining_cost") == 0 and fixture.organs[0].nutrition == 4,
		"Exact 28-unit investment retains startup stock in the organ")
	_assert_terminal_no_debits(fixture, "Completed request")
	await _dispose(fixture)


func _test_spurious_and_duplicate_completion() -> void:
	var fixture: Fixture = _new_fixture()
	var request_id: int = _start(fixture)
	var growth_id: int = int(_snapshot(fixture).get("growth_task_id", 0))
	fixture.growth.task_completed.emit(growth_id)
	fixture.growth.task_completed.emit(growth_id + 999)
	fixture.growth.task_changed.emit({"task_id": growth_id, "state": &"completed"})
	_check(_snapshot(fixture).get("phase") == &"growth" and _snapshot(fixture).get("endpoint") == null
		and _snapshot(fixture).get("cultivation_task_id") == 0, "Spurious growth completion cannot trigger handoff")
	_finish_growth(fixture)
	for replay: int in range(4):
		fixture.growth.task_completed.emit(growth_id)
		fixture.growth.task_cancelled.emit(growth_id)
	await _flush_handoff()
	var cultivation_id: int = int(_snapshot(fixture).get("cultivation_task_id", 0))
	var endpoint: HyphaNode = _snapshot(fixture).get("endpoint") as HyphaNode
	_check(cultivation_id == 1 and _count_buds(endpoint) == 1,
		"Repeated growth completion starts only one cultivation attempt")
	fixture.cultivation.task_completed.emit(cultivation_id)
	fixture.cultivation.task_completed.emit(cultivation_id + 999)
	fixture.cultivation.task_changed.emit({"task_id": cultivation_id, "state": &"completed"})
	fixture.cultivation.task_cancelled.emit(cultivation_id)
	_check(fixture.remote.has_active_request() and fixture.completed.is_empty()
		and fixture.cancelled.is_empty(), "Spurious cultivation events cannot commit a request terminal state")
	_dispatch_all_cultivation(fixture)
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(3.1)
	for replay: int in range(4):
		fixture.growth.task_completed.emit(growth_id)
		fixture.cultivation.task_completed.emit(cultivation_id)
		fixture.cultivation.task_cancelled.emit(cultivation_id)
	_check(fixture.completed == [request_id] and fixture.maturations == 1 and _count_buds(endpoint) == 0,
		"Terminal replay does not emit a second request completion or create a second bud")
	_assert_terminal_no_debits(fixture, "Duplicate completion")
	await _dispose(fixture)


func _test_cancelled_growth_preserves_network() -> void:
	var fixture: Fixture = _new_fixture()
	var request_id: int = _start(fixture)
	_check(_dispatch_all_growth(fixture) == 2, "First extension requests its two-unit investment")
	_deliver_records(fixture.growth_supply.get_shipment_records())
	fixture.growth.advance(1.0)
	_check(_dispatch_growth(fixture), "Unfinished junction has one paid in-flight unit")
	_check(fixture.remote.cancel_request(), "Cancel growth with a paid extension and transit")
	var cancelled: Dictionary = _snapshot(fixture)
	_assert_snapshot(cancelled, "Cancelled growth")
	_check(cancelled.get("state") == &"cancelled" and cancelled.get("phase") == &"growth"
		and cancelled.get("growth_consumed") == 2 and fixture.core.nutrition == 98
		and cancelled.get("endpoint") == null and _count_tips(fixture) == 0
		and fixture.edges.get_child_count() == 1, "Cancelled growth keeps paid geometry and refunds only transit")
	_check(fixture.remote.continue_request() == 0 and fixture.cancelled == [request_id],
		"Cancelled growth requires fresh placement and only one cancellation event")
	_assert_terminal_no_debits(fixture, "Cancelled partial growth")
	var replacement: int = _start(fixture, Vector2(0.0, 320.0))
	_check(replacement > request_id and _count_tips(fixture) == 1, "Fresh placement uses a new identity and one tip")
	fixture.remote.cancel_request()
	_check_conservation(fixture, "Fresh placement after cancellation")
	await _dispose(fixture)


func _cancel_when_connected(snapshot: Dictionary, remote: RemoteCultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired and snapshot.get("phase") == &"connected" and snapshot.get("state") == &"connected":
		trigger.fired = true
		remote.cancel_request()


func _cancel_when_final(node: HyphaNode, fixture: Fixture, trigger: Trigger) -> void:
	if not trigger.fired and node.global_position == Vector2(320.0, 0.0):
		trigger.fired = true
		fixture.remote.cancel_request()


func _test_cancel_vs_connection() -> void:
	for timing: String in ["final_junction", "connected_signal", "deferred_gap"]:
		var fixture: Fixture = _new_fixture()
		var trigger: Trigger = Trigger.new()
		var request_id: int = _start(fixture)
		var growth_id: int = int(_snapshot(fixture).get("growth_task_id", 0))
		if timing == "final_junction":
			fixture.growth.junction_formed.connect(_cancel_when_final.bind(fixture, trigger))
		elif timing == "connected_signal":
			fixture.remote.request_changed.connect(_cancel_when_connected.bind(fixture.remote, trigger))
		_finish_growth(fixture)
		if timing == "deferred_gap":
			_check(fixture.remote.cancel_request(), "Cancellation in queued handoff gap")
		await _flush_handoff()
		fixture.growth.task_completed.emit(growth_id)
		var snapshot: Dictionary = _snapshot(fixture)
		_check(snapshot.get("state") == &"cancelled" and snapshot.get("cultivation_task_id") == 0
			and fixture.cancelled == [request_id] and fixture.maturations == 0,
			timing + ": late connection completion cannot resurrect a cancelled request")
		var endpoint: HyphaNode = fixture.growth.get_completed_endpoint(growth_id)
		_check(is_instance_valid(endpoint) and _count_buds(endpoint) == 0
			and fixture.core.nutrition == 84 and snapshot.get("growth_consumed") == 16,
			timing + ": already-paid mature network stays without organ payment")
		_assert_terminal_no_debits(fixture, timing)
		await _dispose(fixture)


func _pause_when_connected(snapshot: Dictionary, remote: RemoteCultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired and snapshot.get("phase") == &"connected" and snapshot.get("state") == &"connected":
		trigger.fired = true
		remote.pause_request()


func _test_pause_each_stage() -> void:
	var fixture: Fixture = _new_fixture(100, false)
	_start(fixture)
	_check(fixture.remote.pause_request() and _snapshot(fixture).get("state") == &"paused"
		and _snapshot(fixture).get("phase") == &"growth", "Growth-stage pause delegates to its task")
	_check(not _dispatch_growth(fixture) and fixture.core.nutrition == 100,
		"Paused growth dispatches no new payment")
	_check(fixture.remote.resume_request(), "Growth-stage resume")
	var trigger: Trigger = Trigger.new()
	fixture.remote.request_changed.connect(_pause_when_connected.bind(fixture.remote, trigger))
	_finish_growth(fixture)
	await _flush_handoff()
	var connected: Dictionary = _snapshot(fixture)
	var endpoint: HyphaNode = connected.get("endpoint") as HyphaNode
	_check(trigger.fired and connected.get("phase") == &"connected" and connected.get("state") == &"paused"
		and connected.get("wait_reason") == &"paused" and _count_buds(endpoint) == 0,
		"Connected-stage pause delays the deferred handoff")
	_check(fixture.growth.create_target(fixture.core, Vector2(0.0, 320.0)) == 0,
		"Paused connected request blocks external growth without any prior blocker")
	_check(fixture.remote.resume_request(), "Connected-stage resume")
	await _flush_handoff()
	_check(_count_buds(endpoint) == 1 and fixture.growth.construction_blocker.is_valid(),
		"Resume starts one bud and retains a construction blocker")
	_check(_dispatch_all_cultivation(fixture) == 12 and fixture.remote.pause_request(),
		"Cultivation pause with paid transit")
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(10.0)
	var paused: Dictionary = _snapshot(fixture)
	_assert_snapshot(paused, "Paused cultivation")
	_check(paused.get("phase") == &"cultivation" and paused.get("state") == &"paused"
		and paused.get("buffered_nutrition") == 12 and paused.get("structure_consumed") == 0
		and fixture.maturations == 0 and not _dispatch_cultivation(fixture),
		"Paused cultivation accepts previously paid arrivals without consuming them")
	_check(fixture.growth.create_target(fixture.core, Vector2(0.0, 320.0)) == 0,
		"Active cultivation is blocked even when the original growth blocker was empty")
	_check(fixture.remote.resume_request(), "Cultivation-stage resume")
	fixture.cultivation.advance(3.1)
	_check(_snapshot(fixture).get("state") == &"completed" and fixture.core.nutrition == 72,
		"Paused arrivals mature once after resume")
	_check_conservation(fixture, "Stage pause")
	await _dispose(fixture)


func _test_continue_partial_structure() -> void:
	var fixture: Fixture = _new_fixture()
	await _connect(fixture)
	var first: Dictionary = _snapshot(fixture)
	var request_id: int = int(first.get("request_id", 0))
	var cultivation_id: int = int(first.get("cultivation_task_id", 0))
	var endpoint: HyphaNode = first.get("endpoint") as HyphaNode
	var bud: OrganBud = endpoint.get_organ_bud()
	var node_count: int = fixture.nodes.get_child_count()
	var edge_count: int = fixture.edges.get_child_count()
	_dispatch_all_cultivation(fixture)
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(0.5)
	_check(fixture.remote.cancel_request(), "Cancel partially paid cultivation")
	var cancelled: Dictionary = _snapshot(fixture)
	var structure: int = int(cancelled.get("structure_consumed", 0))
	_check(structure > 0 and structure < 8 and cancelled.get("growth_consumed") == 16
		and fixture.core.nutrition == 100 - 16 - structure and endpoint.get_organ_bud() == bud,
		"Cancellation preserves structure and the original bud while refunding unused arrivals")
	_assert_terminal_no_debits(fixture, "Cancelled cultivation")
	var replacement: int = fixture.remote.continue_request()
	var resumed: Dictionary = _snapshot(fixture)
	_assert_snapshot(resumed, "Continued partial cultivation")
	_check(replacement > request_id and int(resumed.get("cultivation_task_id", 0)) > cultivation_id
		and resumed.get("growth_task_id") == first.get("growth_task_id") and resumed.get("endpoint") == endpoint
		and resumed.get("total_cost") == 28 and resumed.get("consumed_nutrition") == 16 + structure,
		"Continue uses new request and cultivation identities with the full historical budget")
	_check(fixture.nodes.get_child_count() == node_count and fixture.edges.get_child_count() == edge_count
		and _count_tips(fixture) == 0 and endpoint.get_organ_bud() == bud and _count_buds(endpoint) == 1,
		"Continue retains the network and original bud without regrowth")
	fixture.growth.task_completed.emit(int(first.get("growth_task_id", 0)))
	fixture.cultivation.task_completed.emit(cultivation_id)
	fixture.cultivation.task_cancelled.emit(cultivation_id)
	_check(fixture.remote.has_active_request() and _snapshot(fixture).get("request_id") == replacement,
		"Old task callbacks cannot terminate a continuation")
	_check(_dispatch_all_cultivation(fixture) == 12 - structure, "Continuation pays only the unfinished cultivation budget")
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(3.1)
	_check(fixture.completed == [replacement] and fixture.cancelled == [request_id]
		and fixture.core.nutrition == 72 and fixture.maturations == 1,
		"Continuation matures once at a total of exactly twenty-eight paid units")
	_check(fixture.cultivation.get_task_snapshot(cultivation_id).get("state") == &"cancelled",
		"Old cultivation audit keeps its cancelled attempt")
	_check_conservation(fixture, "Continued structure")
	await _dispose(fixture)


func _test_continue_reserved_startup() -> void:
	var fixture: Fixture = _new_fixture()
	await _connect(fixture)
	var request_id: int = int(_snapshot(fixture).get("request_id", 0))
	for unit: int in range(8):
		_check(_dispatch_cultivation(fixture), "Structure-only cultivation payment")
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(3.1)
	for unit: int in range(3):
		_check(_dispatch_cultivation(fixture), "Partial startup payment")
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(0.1)
	var reserved: Dictionary = _snapshot(fixture)
	_assert_snapshot(reserved, "Reserved startup")
	_check(reserved.get("startup_reserved") == 3 and reserved.get("buffered_nutrition") == 0
		and reserved.get("consumed_nutrition") == 24 and reserved.get("remaining_cost") == 4
		and reserved.get("remaining_demand") == 1 and reserved.get("state") == &"waiting"
		and reserved.get("phase") == &"cultivation" and fixture.maturations == 0,
		"Reserved startup is neither destroyed nutrition nor completed maturity")
	_check_conservation(fixture, "Startup reservation")
	_check(_dispatch_cultivation(fixture) and fixture.remote.cancel_request(), "Cancel with startup reserve and transit")
	var cancelled: Dictionary = _snapshot(fixture)
	_check(fixture.core.nutrition == 76 and cancelled.get("startup_reserved") == 0
		and cancelled.get("consumed_nutrition") == 24 and cancelled.get("remaining_demand") == 4,
		"Cancellation refunds all four unfinished startup units and retains twenty-four invested units")
	var replacement: int = fixture.remote.continue_request()
	_check(replacement > request_id and _snapshot(fixture).get("total_cost") == 28
		and _dispatch_all_cultivation(fixture) == 4, "Startup continuation retains full budget and pays only four units")
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(0.1)
	_check(_snapshot(fixture).get("state") == &"completed" and fixture.core.nutrition == 72
		and fixture.organs[0].nutrition == 4, "Startup continuation transfers paid stock into one mature organ")
	_check_conservation(fixture, "Startup continuation counts transfer only in organ stock")
	await _dispose(fixture)


func _cancel_on_bud_entry(child: Node, remote: RemoteCultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired and child is OrganBud:
		trigger.fired = true
		remote.cancel_request()


func _test_synchronous_start_cancellation() -> void:
	var fixture: Fixture = _new_fixture()
	var first_request: int = _start(fixture)
	_finish_growth(fixture)
	var endpoint: HyphaNode = _snapshot(fixture).get("endpoint") as HyphaNode
	var trigger: Trigger = Trigger.new()
	endpoint.child_entered_tree.connect(_cancel_on_bud_entry.bind(fixture.remote, trigger))
	await _flush_handoff()
	var cancelled: Dictionary = _snapshot(fixture)
	_check(trigger.fired and cancelled.get("state") == &"cancelled" and cancelled.get("phase") == &"cultivation"
		and int(cancelled.get("cultivation_task_id", 0)) > 0 and not fixture.cultivation.has_active_task()
		and _count_buds(endpoint) == 1 and fixture.core.nutrition == 84,
		"Synchronous cancellation before start returns commits request identity and cancels the resulting task")
	_assert_terminal_no_debits(fixture, "Synchronous bud-entry cancellation")
	var replacement: int = fixture.remote.continue_request()
	_check(replacement > first_request and _count_buds(endpoint) == 1,
		"Synchronous cancellation keeps one continuable bud")
	_dispatch_all_cultivation(fixture)
	_deliver_records(fixture.cultivation_supply.get_shipment_records())
	fixture.cultivation.advance(3.1)
	_check(fixture.completed == [replacement] and fixture.cancelled == [first_request]
		and fixture.maturations == 1 and fixture.core.nutrition == 72,
		"Reentrant cancellation and continuation do not create a second bud or extra payment")
	_check_conservation(fixture, "Synchronous cancellation")
	await _dispose(fixture)


func _test_endpoint_identity_and_history() -> void:
	var fixture: Fixture = _new_fixture()
	_start(fixture)
	var growth_id: int = int(_snapshot(fixture).get("growth_task_id", 0))
	_check(fixture.growth.get_completed_endpoint(growth_id) == null
		and fixture.growth.get_completed_endpoint(growth_id + 100) == null,
		"Unfinished and unknown tasks have no committed endpoint")
	_finish_growth(fixture)
	var actual: HyphaNode = fixture.growth.get_completed_endpoint(growth_id)
	fixture.remote.cancel_request()
	var decoy: HyphaNode = _append_existing_node(fixture, actual.global_position)
	_check(fixture.growth.get_completed_endpoint(growth_id) == actual and actual != decoy,
		"Same-coordinate decoy never replaces the task's actual endpoint")
	var next_id: int = fixture.growth.create_target(fixture.core, Vector2(0.0, 80.0))
	_check(next_id > growth_id and fixture.growth.get_completed_endpoint(growth_id) == actual,
		"New growth retains the older task's endpoint identity")
	fixture.growth.cancel_task()
	fixture.network.unregister_node(actual)
	actual.free()
	_check(fixture.growth.get_completed_endpoint(growth_id) == null,
		"Freed committed endpoint returns null instead of a same-position replacement")
	await _flush_handoff()
	_check(fixture.maturations == 0 and _count_buds(decoy) == 0, "Cancelled old handoff cannot use the decoy")
	await _dispose(fixture)


func _test_reset_and_old_callbacks() -> void:
	var fixture: Fixture = _new_fixture()
	var old_request_id: int = _start(fixture)
	var old_growth_id: int = int(_snapshot(fixture).get("growth_task_id", 0))
	_check(_dispatch_growth(fixture), "Reset fixture has paid growth transit")
	var old_packet: Variant = fixture.growth_supply.get_shipment_records()[0].get("packet")
	fixture.remote.reset()
	fixture.growth_supply.reset()
	fixture.cultivation_supply.reset()
	fixture.cultivation.reset()
	var idle: Dictionary = _snapshot(fixture)
	_assert_snapshot(idle, "Reset idle")
	_check(idle.get("request_id") == 0 and idle.get("growth_task_id") == 0
		and idle.get("cultivation_task_id") == 0 and idle.get("state") == &"idle"
		and fixture.core.nutrition == 100 and _count_tips(fixture) == 0,
		"Reset invalidates identities before cancellation and refunds paid transport")
	var replacement: int = _start(fixture, Vector2(0.0, 320.0))
	_check(replacement > old_request_id, "Reset never reuses a positive request identity")
	if is_instance_valid(old_packet):
		old_packet.arrived.emit(old_packet)
		old_packet.interrupted.emit(old_packet)
		old_packet.tree_exiting.emit()
	fixture.growth.task_completed.emit(old_growth_id)
	fixture.growth.task_cancelled.emit(old_growth_id)
	fixture.cultivation.task_completed.emit(1)
	_check(_snapshot(fixture).get("request_id") == replacement and _snapshot(fixture).get("phase") == &"growth"
		and _snapshot(fixture).get("cultivation_task_id") == 0 and fixture.core.nutrition == 100,
		"Old packets and task callbacks cannot debit or hand off the replacement")
	_finish_growth(fixture)
	var queued_request: int = int(_snapshot(fixture).get("request_id", 0))
	fixture.remote.reset()
	fixture.growth_supply.reset()
	fixture.cultivation_supply.reset()
	fixture.cultivation.reset()
	var after_queue: int = _start(fixture, Vector2(-320.0, 0.0))
	await _flush_handoff()
	_check(after_queue > queued_request and _snapshot(fixture).get("phase") == &"growth"
		and _snapshot(fixture).get("cultivation_task_id") == 0 and _count_tips(fixture) == 1,
		"Generation invalidates the old deferred handoff after restart")
	fixture.remote.cancel_request()
	_check_conservation(fixture, "Restart and old callbacks")
	await _dispose(fixture)


func _reset_on_child_entry(child: Node, remote: RemoteCultivationSystem, trigger: Trigger) -> void:
	if not trigger.fired and (child is GrowthTip or child is OrganBud):
		trigger.fired = true
		remote.reset()


func _test_reset_during_startup() -> void:
	for stage: String in ["growth", "cultivation"]:
		var fixture: Fixture = _new_fixture()
		var trigger: Trigger = Trigger.new()
		if stage == "growth":
			fixture.tips.child_entered_tree.connect(_reset_on_child_entry.bind(fixture.remote, trigger))
			_start(fixture)
		else:
			_start(fixture)
			_finish_growth(fixture)
			var endpoint: HyphaNode = _snapshot(fixture).get("endpoint") as HyphaNode
			endpoint.child_entered_tree.connect(_reset_on_child_entry.bind(fixture.remote, trigger))
			await _flush_handoff()
		_check(trigger.fired and _snapshot(fixture).get("state") == &"idle"
			and _snapshot(fixture).get("request_id") == 0 and not fixture.growth.has_active_task()
			and not fixture.cultivation.has_active_task() and _count_tips(fixture) == 0,
			stage + ": startup unwind cancels the task returned after reset invalidated its request")
		_check_conservation(fixture, "Reset during " + stage + " startup")
		await _dispose(fixture)
