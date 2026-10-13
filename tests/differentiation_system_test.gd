extends SceneTree
## 单位边界测试：人工阶段累计与 receive_nutrition 只模拟准入/已付款到货。
## 真正成熟玩法、母核付款、在途包与退款链路由独立集成测试证明。

const Differentiation = preload("res://scripts/differentiation_system.gd")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ORGAN_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const WEAPON_SCENE: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
const BUD_SCENE: PackedScene = preload("res://scenes/colony/organ_bud.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const NORMAL_PROFILE: WeaponProfile = preload("res://resources/weapons/normal_spore.tres")
const AP_PROFILE: WeaponProfile = preload("res://resources/weapons/armor_piercing_spore.tres")
const SCATTER_PROFILE: WeaponProfile = preload("res://resources/weapons/scatter_spore.tres")
const AP: int = WeaponProfile.DamageType.ARMOR_PIERCING
const SCATTER: int = WeaponProfile.DamageType.SCATTER
const EPSILON: float = 0.00001
const SNAPSHOT_KEYS: Array[String] = [
	"task_id", "organ", "host", "weapon", "direction", "state", "wait_reason",
	"total_cost", "consumed_nutrition", "buffered_nutrition", "remaining_cost",
	"requested_nutrition", "effective_time", "minimum_time", "stage_paid",
	"stage_elapsed", "progress", "can_progress",
]

class Mount:
	extends RefCounted
	var host: HyphaNode
	var edge: HyphaEdge
	var organ: AttackOrgan
	var weapon: SporeWeapon

class Fixture:
	extends RefCounted
	var world: Node2D
	var core: MotherCore
	var network: NetworkSystem
	var progress: ColonyProgress
	var capabilities: ColonyCapabilities
	var system: DifferentiationSystem
	var enemies: Node2D
	var projectiles: Node2D
	var mount: Mount
	var completed: Array[int] = []
	var cancelled: Array[int] = []
	var differentiated: Array[Dictionary] = []

var failures: Array[String] = []
var checks: int = 0
var cases: Array[String] = []
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_initial_root_children = root.get_child_count()
	await _test_eligibility_and_queries()
	await _test_paid_cost_and_time()
	await _test_pause_disconnect_and_supply_hints()
	await _test_real_edge_traversability_and_congestion()
	await _test_cancel_continue_and_history()
	await _test_direction_lock_before_delivery()
	await _test_invalid_hosts_and_lifetime()
	await _test_reentry_and_once_completion()
	await _test_stock_clock_and_old_shots()
	await _test_stop_reset_and_exit_settlement()
	_check(root.get_child_count() == _initial_root_children, "All differentiation fixtures leave the tree")
	print("DIFFERENTIATION_SYSTEM_TEST_RESULT ", JSON.stringify({
		"checks": checks,
		"failures": failures,
		"cases": cases,
		"evidence_boundary": "unit_boundary_artificial_maturity_and_delivered_materials",
		"gameplay_maturity_and_paid_transport": "not_proved_by_this_suite",
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _make_fixture(recovered: int = 160, stock: int = 4) -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.world.name = "DifferentiationUnitBoundary"
	root.add_child(fixture.world)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.world.add_child(fixture.core)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	_check(fixture.network.register_node(fixture.core, true), "Unit fixture registers the actual core")
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.projectiles)
	fixture.progress = ColonyProgress.new()
	fixture.world.add_child(fixture.progress)
	if recovered > 0:
		_check(fixture.progress.record_arrival("unit-boundary:artificial-maturity", recovered),
			"Unit fixture explicitly seeds stage eligibility without claiming gameplay digestion")
	fixture.capabilities = ColonyCapabilities.new()
	fixture.capabilities.colony_progress = fixture.progress
	fixture.world.add_child(fixture.capabilities)
	fixture.mount = _append_mount(fixture, Vector2(100.0, 0.0), stock)
	fixture.system = Differentiation.new()
	fixture.system.network_system = fixture.network
	fixture.system.colony_capabilities = fixture.capabilities
	fixture.world.add_child(fixture.system)
	fixture.system.set_physics_process(false)
	fixture.system.task_completed.connect(func(task_id: int) -> void: fixture.completed.append(task_id))
	fixture.system.task_cancelled.connect(func(task_id: int) -> void: fixture.cancelled.append(task_id))
	fixture.system.organ_differentiated.connect(func(task_id: int, organ: AttackOrgan, direction: int) -> void:
		fixture.differentiated.append({"task_id": task_id, "organ": organ, "direction": direction})
	)
	return fixture


func _append_mount(fixture: Fixture, position: Vector2, stock: int = 4) -> Mount:
	var mount := Mount.new()
	mount.host = NODE_SCENE.instantiate() as HyphaNode
	fixture.world.add_child(mount.host)
	mount.host.position = position
	_check(fixture.network.register_node(mount.host), "Unit fixture registers an actual host")
	mount.edge = EDGE_SCENE.instantiate() as HyphaEdge
	mount.edge.start_node = fixture.core
	mount.edge.end_node = mount.host
	fixture.world.add_child(mount.edge)
	_check(fixture.network.register_edge(mount.edge), "Unit fixture has physical core connectivity")
	mount.organ = ORGAN_SCENE.instantiate() as AttackOrgan
	mount.organ.initial_nutrition = stock
	mount.host.add_child(mount.organ)
	mount.weapon = WEAPON_SCENE.instantiate() as SporeWeapon
	mount.weapon.inventory_owner = mount.organ
	mount.weapon.enemy_container = fixture.enemies
	mount.weapon.projectile_container = fixture.projectiles
	mount.weapon.position = Vector2(0.0, -28.0)
	mount.host.add_child(mount.weapon)
	_check(mount.weapon.configure_profile(NORMAL_PROFILE), "Unit mount explicitly uses ordinary profile")
	return mount


func _dispose(fixture: Fixture) -> void:
	if is_instance_valid(fixture.system):
		fixture.system.stop()
	fixture.world.queue_free()
	await process_frame


func _assert_snapshot(snapshot: Dictionary, description: String) -> void:
	_check(snapshot.has_all(SNAPSHOT_KEYS) and snapshot.size() == SNAPSHOT_KEYS.size(),
		description + ": exact frozen snapshot keys")
	if not snapshot.has_all(SNAPSHOT_KEYS):
		return
	_check(typeof(snapshot["task_id"]) == TYPE_INT and typeof(snapshot["direction"]) == TYPE_INT
		and typeof(snapshot["state"]) == TYPE_STRING_NAME and typeof(snapshot["wait_reason"]) == TYPE_STRING_NAME,
		description + ": typed identity, direction and state")
	_check(snapshot["total_cost"] == 8 and snapshot["minimum_time"] == 5.0
		and typeof(snapshot["effective_time"]) == TYPE_FLOAT and typeof(snapshot["stage_elapsed"]) == TYPE_FLOAT
		and typeof(snapshot["progress"]) == TYPE_FLOAT and typeof(snapshot["can_progress"]) == TYPE_BOOL,
		description + ": fixed cost, minimum time and typed local clock")
	_check(snapshot["consumed_nutrition"] >= 0 and snapshot["consumed_nutrition"] <= 8
		and snapshot["buffered_nutrition"] >= 0 and snapshot["remaining_cost"] == 8 - snapshot["consumed_nutrition"]
		and snapshot["consumed_nutrition"] + snapshot["buffered_nutrition"] <= 8
		and snapshot["requested_nutrition"] >= 0
		and snapshot["requested_nutrition"] <= snapshot["remaining_cost"] - snapshot["buffered_nutrition"],
		description + ": consumed, cached and requested material do not overlap")


func _test_eligibility_and_queries() -> void:
	var fixture := _make_fixture(159)
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	_check(not fixture.capabilities.can_differentiate_attack_organs()
		and system.get_availability(organ, AP) == &"stage_locked"
		and system.start_differentiation(organ, AP) == 0, "159 recovered units cannot admit differentiation")
	fixture.progress.record_arrival("unit-boundary:threshold", 1)
	_check(fixture.capabilities.can_differentiate_attack_organs()
		and system.get_availability(organ, AP) == &"ready", "Mature gate opens at exactly 160")
	_check(system.get_availability(null) == &"no_selection"
		and system.get_availability("not an organ") == &"not_mature_organ"
		and system.get_availability(fixture.mount.host) == &"not_mature_organ", "Variant selection rejects null and non-organ inputs safely")
	for direction: int in [-1, 0, 3, 100]:
		_check(system.start_differentiation(organ, direction) == 0, "Only AP and scatter are accepted directions")
		if direction != -1:
			_check(system.get_availability(organ, direction) == &"invalid_direction", "Unsupported requested direction is visible")
	var idle: Dictionary = system.get_organ_snapshot(organ)
	_assert_snapshot(idle, "Idle organ")
	_check(idle["direction"] == -1 and idle["state"] == &"idle" and organ.get_attack_type() == 0,
		"Ordinary organ starts unlocked and reads actual weapon type")
	var core_stock: int = fixture.core.nutrition
	var ordinary_stock: int = organ.nutrition
	for _query: int in range(20):
		system.get_availability(organ, SCATTER)
		system.get_task_snapshot()
		system.get_organ_snapshot(organ)
		organ.get_differentiation_snapshot()
		system.get_resource_snapshot()
	_check(system.get_organ_snapshot(organ) == idle and fixture.core.nutrition == core_stock
		and organ.nutrition == ordinary_stock, "Availability and snapshot reads never lock, pay, refill or advance")
	fixture.mount.weapon.configure_profile(AP_PROFILE)
	_check(organ.get_attack_type() == AP and not organ.has_completed_differentiation()
		and system.get_availability(organ, SCATTER) == &"not_normal", "Explicit test reconfiguration does not manufacture completed differentiation")
	fixture.mount.weapon.configure_profile(NORMAL_PROFILE)
	fixture.mount.weapon.inventory_owner = null
	_check(system.get_availability(organ, AP) == &"not_mature_organ"
		and organ.get_attack_type() == 0, "Unmatched weapon cannot admit legacy no-weapon organ")
	fixture.mount.weapon.inventory_owner = organ
	fixture.mount.weapon.process_mode = Node.PROCESS_MODE_DISABLED
	_check(system.get_availability(organ, AP) == &"not_mature_organ", "Incomplete disabled materialization is ineligible")
	fixture.mount.weapon.process_mode = Node.PROCESS_MODE_INHERIT
	var bud: OrganBud = BUD_SCENE.instantiate() as OrganBud
	fixture.mount.host.add_child(bud)
	_check(system.get_availability(bud, AP) == &"not_mature_organ"
		and system.get_availability(organ, AP) == &"not_mature_organ", "Bud and ambiguous two-occupant slot cannot differentiate")
	fixture.mount.host.remove_child(bud)
	bud.free()
	fixture.network.unregister_node(fixture.mount.host)
	_check(system.get_availability(organ, AP) == &"organ_unavailable", "Actual organ on unregistered host is ineligible")
	fixture.network.register_node(fixture.mount.host)
	fixture.network.unregister_edge(fixture.mount.edge)
	_check(system.get_availability(organ, AP) == &"disconnected", "Disconnected actual organ is ineligible")
	fixture.network.register_edge(fixture.mount.edge)
	fixture.core.health = 0
	_check(system.get_availability(organ, AP) == &"core_unavailable", "Dead core cannot admit local differentiation")
	fixture.core.health = fixture.core.max_health
	_check(system.get_availability(organ, AP) == &"ready" and not system.has_active_task(),
		"Restoring exact same fixture makes eligibility ready without opening a task")
	await _dispose(fixture)
	cases.append("mature_160_variant_directions_normal_ready_slot_and_pure_queries")


func _test_paid_cost_and_time() -> void:
	for direction: int in [AP, SCATTER]:
		var fixture := _make_fixture()
		var organ: AttackOrgan = fixture.mount.organ
		var system: DifferentiationSystem = fixture.system
		var stock: int = organ.nutrition
		var core_stock: int = fixture.core.nutrition
		var task_id: int = system.start_differentiation(organ, direction)
		_check(task_id > 0 and not organ.is_work_enabled() and system.has_active_task(), "Accepted direction occupies one slot and ceases fire")
		_check(system.get_requested_nutrition(task_id) == 8 and system.get_delivery_target(task_id) == fixture.mount.host,
			"Initial demand is eight delivered differentiation units at actual host")
		system.advance(100.0)
		_check(system.get_task_snapshot()["effective_time"] == 0.0 and system.get_task_snapshot()["consumed_nutrition"] == 0,
			"Unfunded waiting cannot accrue any free time")
		_check(not system.receive_nutrition(task_id, "", 1) and not system.receive_nutrition(task_id, "bad", 0)
			and not system.receive_nutrition(task_id + 1, "wrong-id", 1)
			and not system.receive_nutrition(task_id, "too-large", 9), "Receipts require current identity, unique nonempty shipment and bounded amount")
		_check(system.receive_nutrition(task_id, "unit-boundary:seven", 7), "Unit boundary receives seven prepaid units")
		_check(not system.receive_nutrition(task_id, "unit-boundary:seven", 1), "Receipt ID cannot pay twice")
		var received: Dictionary = system.get_task_snapshot()
		_assert_snapshot(received, "Received materials")
		_check(received["buffered_nutrition"] == 7 and received["consumed_nutrition"] == 0
			and received["effective_time"] == 0.0 and received["requested_nutrition"] == 1,
			"Material arrival only enters buffer and leaves paid/time counters untouched")
		system.advance(100.0)
		var seven: Dictionary = system.get_task_snapshot()
		_check(seven["consumed_nutrition"] == 7 and seven["buffered_nutrition"] == 0
			and _near(seven["effective_time"], 4.375) and not seven["stage_paid"]
			and seven["state"] == &"waiting" and fixture.completed.is_empty(), "Seven materials grant exactly seven paid stages and cannot complete")
		_check(system.receive_nutrition(task_id, "unit-boundary:eighth", 1), "Unit boundary receives final material")
		system.advance(0.5625)
		var partial: Dictionary = system.get_task_snapshot()
		_check(partial["consumed_nutrition"] == 8 and partial["stage_paid"]
			and _near(partial["stage_elapsed"], 0.5625) and _near(partial["effective_time"], 4.9375)
			and fixture.completed.is_empty() and organ.get_attack_type() == 0,
			"Eight materials without five effective seconds retain ordinary profile")
		system.advance(0.0625)
		var completed: Dictionary = system.get_task_snapshot()
		_assert_snapshot(completed, "Completed organ")
		_check(completed["state"] == &"completed" and completed["consumed_nutrition"] == 8
			and completed["effective_time"] == 5.0 and completed["progress"] == 1.0
			and not completed["stage_paid"] and not completed["can_progress"]
			and fixture.completed == [task_id] and fixture.differentiated.size() == 1,
			"Exactly eight materials and five effective seconds complete once")
		_check(completed["organ"] == organ and completed["weapon"] == fixture.mount.weapon
			and organ.get_attack_type() == direction and organ.has_completed_differentiation()
			and organ.is_work_enabled() and organ.nutrition == stock and fixture.core.nutrition == core_stock,
			"Completion transforms the same weapon and restores work without touching ammunition or core")
		_check(organ.get_differentiation_snapshot() == completed
			and system.get_availability(organ) == &"completed" and not system.has_active_task(), "Organ and system share authoritative completed state")
		_check(system.get_resource_snapshot() == {"consumed_nutrition": 8, "buffered_nutrition": 0}, "Unique organ owns exactly eight sunk materials")
		await _dispose(fixture)
	cases.append("eight_delivered_units_and_five_paid_seconds_same_weapon_once_for_both_directions")


func _test_pause_disconnect_and_supply_hints() -> void:
	var fixture := _make_fixture()
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var task_id: int = system.start_differentiation(organ, AP)
	system.receive_nutrition(task_id, "unit-boundary:first-four", 4)
	system.advance(0.25)
	var partial: Dictionary = system.get_task_snapshot()
	_check(partial["consumed_nutrition"] == 1 and partial["buffered_nutrition"] == 3
		and partial["stage_paid"] and _near(partial["stage_elapsed"], 0.25), "First step is charged before its partial clock")
	_check(system.pause_task() and not system.pause_task()
		and system.get_availability(organ) == &"paused", "Pause is idempotent and retains the active slot")
	organ.set_work_enabled(true)
	_check(not organ.is_work_enabled() and (fixture.mount.weapon.get_node("FireTimer") as Timer).is_stopped(),
		"External work enable cannot break active differentiation ceasefire")
	_check(system.receive_nutrition(task_id, "unit-boundary:paid-paused-arrival", 2), "Already prepaid material can arrive while paused")
	var paused: Dictionary = system.get_task_snapshot()
	system.advance(100.0)
	_check(system.get_task_snapshot() == paused and system.get_requested_nutrition(task_id) == 0
		and system.get_delivery_target(task_id) == fixture.mount.host, "Paused arrivals preserve clock and request zero new material")
	_check(system.resume_task() and not system.resume_task(), "Resume does not create another task or reset the paid step")
	fixture.network.unregister_edge(fixture.mount.edge)
	var disconnected: Dictionary = system.get_task_snapshot()
	_check(disconnected["state"] == &"waiting" and disconnected["wait_reason"] == &"disconnected"
		and not disconnected["can_progress"] and system.get_requested_nutrition(task_id) == 0,
		"Disconnected task waits with unchanged paid step and zero new requests")
	system.advance(100.0)
	_check(system.get_task_snapshot() == disconnected, "Disconnected effective time does not advance")
	fixture.network.register_edge(fixture.mount.edge)
	system.set_supply_wait_reason(task_id, &"core_empty")
	_check(system.get_task_snapshot()["can_progress"] and system.get_task_snapshot()["wait_reason"] == &"",
		"Supply wait text cannot block valid buffered work")
	system.advance(0.375)
	var one: Dictionary = system.get_task_snapshot()
	_check(one["consumed_nutrition"] == 1 and not one["stage_paid"] and _near(one["effective_time"], 0.625),
		"Reconnect resumes the remaining 0.375 seconds without paying a second unit")
	system.advance(0.625)
	_check(system.get_task_snapshot()["consumed_nutrition"] == 2
		and _near(system.get_task_snapshot()["effective_time"], 1.25), "Next paid step can run despite external empty-core hint")
	fixture.core.health = 0
	var stopped_time: float = float(system.get_task_snapshot()["effective_time"])
	system.advance(100.0)
	_check(_near(system.get_task_snapshot()["effective_time"], stopped_time)
		and system.get_task_snapshot()["wait_reason"] == &"core_unavailable", "Dead core stops funded effective work without deleting progress")
	fixture.core.health = fixture.core.max_health
	_check(system.cancel_task() and system.take_unspent_nutrition(task_id) == 4,
		"Only four unused cached units remain refundable after two paid steps")
	await _dispose(fixture)
	cases.append("partial_step_pause_paid_arrival_disconnect_reconnect_and_funded_supply_hint")


func _test_real_edge_traversability_and_congestion() -> void:
	var fixture := _make_fixture()
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var edge: HyphaEdge = fixture.mount.edge
	var timer: Timer = fixture.mount.weapon.get_node("FireTimer") as Timer
	var task_id: int = system.start_differentiation(organ, AP)
	system.receive_nutrition(task_id, "unit-boundary:edge-state-four", 4)
	system.advance(0.25)
	var traffic := NetworkTrafficSystem.new()
	traffic.network_system = fixture.network
	fixture.world.add_child(traffic)
	var owner := Node.new()
	fixture.world.add_child(owner)
	var lease: Dictionary = traffic.request_passage("unit-boundary:full-edge", owner,
		"unit-boundary:occupancy", edge, fixture.core, fixture.mount.host, &"remains")
	var capacity: Dictionary = traffic.get_edge_snapshot(edge)
	_check(lease["state"] == &"granted" and capacity["occupied_units"] == capacity["capacity"]
		and capacity["available_units"] == 0, "Actual traffic lease occupies every seat of the live edge")
	_check(system.get_task_snapshot()["can_progress"] and system.get_requested_nutrition(task_id) == 4,
		"Temporary full occupancy does not disconnect already buffered differentiation work")
	system.advance(0.125)
	_check(_near(system.get_task_snapshot()["stage_elapsed"], 0.375)
		and system.get_task_snapshot()["consumed_nutrition"] == 1
		and system.get_task_snapshot()["buffered_nutrition"] == 3,
		"Paid partial step advances while actual traffic capacity is fully occupied")
	_check(traffic.release(String(lease["token"])), "Unit occupancy lease releases normally")
	_check(edge.take_damage(edge.health) > 0.0 and edge.health == 0.0
		and fixture.network.is_edge_valid(edge), "Real lethal edge damage keeps registered topology but closes traversal")
	var broken: Dictionary = system.get_task_snapshot()
	_check(broken["state"] == &"waiting" and broken["wait_reason"] == &"disconnected"
		and not broken["can_progress"] and broken["requested_nutrition"] == 0
		and broken["stage_paid"] and _near(broken["stage_elapsed"], 0.375),
		"Zero-health edge stops the actual paid partial clock even though topology still contains it")
	system.advance(100.0)
	_check(system.get_task_snapshot() == broken and not organ.is_work_enabled() and timer.is_stopped(),
		"Broken edge preserves paid partial time, all three cached units and ceasefire")
	# 单位边界直接恢复生命值；这里不声称证明维修付款或运输链路。
	_check(edge.restore_health(edge.max_health) > 0.0, "Unit boundary restores the same damaged edge")
	system.advance(0.125)
	_check(_near(system.get_task_snapshot()["stage_elapsed"], 0.5)
		and system.get_task_snapshot()["consumed_nutrition"] == 1, "Restored traversal resumes original paid step without another debit")
	edge.entry_enabled = false
	var forbidden: Dictionary = system.get_task_snapshot()
	system.advance(100.0)
	_check(forbidden["wait_reason"] == &"disconnected" and not forbidden["can_progress"]
		and forbidden["requested_nutrition"] == 0 and system.get_task_snapshot() == forbidden
		and not organ.is_work_enabled() and timer.is_stopped(),
		"Explicit entry prohibition stops cached work and retains the paid half-second and ceasefire")
	edge.entry_enabled = true
	system.advance(0.0625)
	_check(_near(system.get_task_snapshot()["stage_elapsed"], 0.5625)
		and system.get_task_snapshot()["buffered_nutrition"] == 3, "Reopening entry preserves the same partial stage and cached material")
	edge.take_damage(edge.health)
	var relay: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.world.add_child(relay)
	relay.position = Vector2(50.0, 60.0)
	fixture.network.register_node(relay)
	var bypass_first: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	bypass_first.start_node = fixture.core
	bypass_first.end_node = relay
	fixture.world.add_child(bypass_first)
	fixture.network.register_edge(bypass_first)
	var bypass_last: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	bypass_last.start_node = relay
	bypass_last.end_node = fixture.mount.host
	fixture.world.add_child(bypass_last)
	fixture.network.register_edge(bypass_last)
	_check(edge.health == 0.0 and system.get_task_snapshot()["can_progress"]
		and system.get_requested_nutrition(task_id) == 4, "Available registered bypass preserves connectivity while original edge stays broken")
	system.advance(0.0625)
	_check(system.get_task_snapshot()["consumed_nutrition"] == 1
		and not system.get_task_snapshot()["stage_paid"]
		and _near(system.get_task_snapshot()["effective_time"], 0.625),
		"Bypass completes only the original step remainder without consuming another cached unit")
	system.advance(0.125)
	bypass_last.entry_enabled = false
	var all_blocked: Dictionary = system.get_task_snapshot()
	system.advance(100.0)
	_check(all_blocked["wait_reason"] == &"disconnected" and system.get_task_snapshot() == all_blocked
		and all_blocked["consumed_nutrition"] == 2 and all_blocked["buffered_nutrition"] == 2
		and all_blocked["stage_paid"] and _near(all_blocked["stage_elapsed"], 0.125),
		"Blocking the only bypass freezes the next paid partial stage and remaining cache")
	edge.restore_health(edge.max_health)
	system.advance(0.5)
	_check(system.get_task_snapshot()["consumed_nutrition"] == 2
		and system.get_task_snapshot()["buffered_nutrition"] == 2
		and _near(system.get_task_snapshot()["effective_time"], 1.25)
		and not organ.is_work_enabled() and timer.is_stopped(),
		"Restoring direct edge resumes paid remainder while forbidden bypass stays excluded and ceasefire stays active")
	_check(system.cancel_task() and system.take_unspent_nutrition(task_id) == 2,
		"Actual edge-state interruptions do not consume the two unused refundable units")
	await _dispose(fixture)
	cases.append("real_zero_health_entry_prohibition_restoration_bypass_and_full_traffic_partial_steps")


func _test_cancel_continue_and_history() -> void:
	var fixture := _make_fixture()
	var second: Mount = _append_mount(fixture, Vector2(200.0, 0.0))
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var stock: int = organ.nutrition
	var first_id: int = system.start_differentiation(organ, AP)
	_check(system.get_availability(second.organ, SCATTER) == &"busy"
		and system.start_differentiation(second.organ, SCATTER) == 0, "One differentiation slot is global across actual organs")
	system.receive_nutrition(first_id, "unit-boundary:first-attempt", 4)
	system.advance(0.25)
	_check(system.cancel_task() and not system.cancel_task() and not system.has_active_task()
		and organ.is_work_enabled() and organ.get_attack_type() == 0, "Cancellation releases active slot and resumes original ordinary weapon")
	_check(system.get_availability(organ, SCATTER) == &"direction_locked"
		and system.get_availability(second.organ, SCATTER) == &"settlement_pending"
		and system.continue_differentiation(organ) == 0, "Direction is locked and unspent cache must settle before any attempt")
	_check(system.take_unspent_nutrition(first_id) == 3 and system.take_unspent_nutrition(first_id) == 0,
		"Cancellation returns only three unconsumed units once")
	var frozen_first: Dictionary = system.get_task_snapshot(first_id)
	_check(frozen_first["stage_paid"] and _near(frozen_first["stage_elapsed"], 0.25)
		and frozen_first["consumed_nutrition"] == 1, "Paid partial stage survives settled cancellation")
	var other_id: int = system.start_differentiation(second.organ, SCATTER)
	_check(other_id > first_id and system.has_active_task(), "A different organ can use the freed independent slot")
	system.receive_nutrition(other_id, "unit-boundary:other-organ", 1)
	system.advance(0.625)
	system.cancel_task()
	var frozen_other: Dictionary = system.get_task_snapshot(other_id)
	var continued_id: int = system.continue_differentiation(organ)
	var continued: Dictionary = system.get_task_snapshot(continued_id)
	_check(continued_id > other_id and continued["consumed_nutrition"] == 1
		and continued["stage_paid"] and _near(continued["stage_elapsed"], 0.25)
		and _near(continued["effective_time"], 0.25) and continued["requested_nutrition"] == 7,
		"Continue creates new monotone ID and shares cumulative payment and partial clock")
	_check(not organ.is_work_enabled() and not system.receive_nutrition(first_id, "old-task-arrival", 1),
		"Continue ceases fire and refuses delivery to cancelled old task")
	_check(system.receive_nutrition(continued_id, "unit-boundary:remaining-seven", 7), "Continued attempt receives only the seven unpaid units")
	system.advance(4.75)
	_check(fixture.completed == [continued_id] and organ.nutrition == stock and organ.has_completed_differentiation(),
		"Original partial step and seven new materials complete at five cumulative seconds")
	_check(system.get_task_snapshot(first_id) == frozen_first and system.get_task_snapshot(other_id) == frozen_other,
		"Continuing and completing never mutate settled historical snapshots")
	_check(system.get_resource_snapshot() == {"consumed_nutrition": 9, "buffered_nutrition": 0},
		"Totals count each organ once across old and continued attempts")
	await _dispose(fixture)
	cases.append("cancel_refundable_cache_new_ids_other_organ_continue_and_frozen_history")


func _test_direction_lock_before_delivery() -> void:
	var fixture := _make_fixture()
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var first_id: int = system.start_differentiation(organ, SCATTER)
	_check(system.get_availability(organ, AP) == &"direction_locked"
		and system.start_differentiation(organ, AP) == 0, "Accepted waiting task locks direction before any material exists")
	system.cancel_task()
	var history: Dictionary = system.get_task_snapshot(first_id)
	system.stop()
	_check(system.is_stopped() and system.get_availability(organ) == &"stopped", "Stop closes admission")
	system.reset()
	_check(not system.is_stopped() and system.get_availability(organ) == &"continuable"
		and system.get_availability(organ, AP) == &"direction_locked", "Reset preserves zero-payment accepted direction")
	var continued_id: int = system.continue_differentiation(organ)
	_check(continued_id > first_id and system.get_task_snapshot()["direction"] == SCATTER
		and system.get_task_snapshot(first_id) == history, "Waiting cancellation continues same locked direction under a fresh ID")
	_check(system.take_unspent_nutrition(continued_id) == 0 and system.get_task_snapshot()["state"] == &"waiting",
		"Active tasks cannot expose a refundable cache")
	await _dispose(fixture)
	cases.append("direction_locked_on_first_acceptance_even_unfunded_and_across_reset")


func _test_invalid_hosts_and_lifetime() -> void:
	var fixture := _make_fixture()
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var task_id: int = system.start_differentiation(organ, AP)
	system.receive_nutrition(task_id, "unit-boundary:invalid-host", 3)
	system.advance(0.25)
	var plain_host := Node2D.new()
	fixture.world.add_child(plain_host)
	fixture.mount.host.remove_child(organ)
	plain_host.add_child(organ)
	_check(system.get_availability(organ) == &"settlement_pending" or system.get_availability(organ) == &"organ_unavailable",
		"Reparented organ cannot start on invalid host")
	system.advance(100.0)
	var cancelled: Dictionary = system.get_task_snapshot(task_id)
	_check(cancelled["state"] == &"cancelled" and cancelled["consumed_nutrition"] == 1
		and _near(cancelled["effective_time"], 0.25) and fixture.cancelled == [task_id],
		"Host identity loss cancels once without granting additional paid time")
	_check(system.take_unspent_nutrition(task_id) == 2, "Host identity loss exposes original refundable cache")
	plain_host.remove_child(organ)
	fixture.mount.host.add_child(organ)
	_check(system.get_availability(organ) == &"continuable", "Restoring exact original host and weapon retains sunk direction and clock")
	var continued_id: int = system.continue_differentiation(organ)
	system.receive_nutrition(continued_id, "unit-boundary:weapon-loss", 2)
	fixture.mount.weapon.queue_free()
	system.advance(100.0)
	_check(system.get_task_snapshot(continued_id)["state"] == &"cancelled"
		and system.get_task_snapshot(continued_id)["weapon"] == null
		and system.get_task_snapshot(continued_id)["consumed_nutrition"] == 1
		and system.take_unspent_nutrition(continued_id) == 2, "Queued weapon deletion exposes safe terminal snapshot and refunds cache once")
	await process_frame
	_check(system.get_task_snapshot(continued_id)["weapon"] == null
		and system.get_resource_snapshot()["consumed_nutrition"] == 1, "Freed weapon cannot erase material accounting or leak a stale typed reference")
	await _dispose(fixture)
	cases.append("reparented_host_queued_and_freed_weapon_safe_terminal_accounting")


func _test_reentry_and_once_completion() -> void:
	var fixture := _make_fixture()
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var second: Mount = _append_mount(fixture, Vector2(200.0, 0.0))
	var controls: Dictionary = {"cancel_on_first_paid": true, "cancelled": false, "reentrant_attempts": 0}
	system.task_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["state"] == &"waiting" or snapshot["state"] == &"differentiating":
			controls["reentrant_attempts"] += 1
			_check(system.start_differentiation(second.organ, SCATTER) == 0, "Synchronous observer cannot admit another attempt")
			var before: float = float(system.get_task_snapshot()["effective_time"])
			system.advance(100.0)
			_check(_near(system.get_task_snapshot()["effective_time"], before), "Synchronous observer cannot reenter paid time advance")
		if controls["cancel_on_first_paid"] and snapshot["consumed_nutrition"] == 1 and snapshot["stage_paid"]:
			controls["cancel_on_first_paid"] = false
			controls["cancelled"] = system.cancel_task()
	)
	var first_id: int = system.start_differentiation(organ, AP)
	system.receive_nutrition(first_id, "unit-boundary:reentrant-eight", 8)
	system.advance(5.0)
	var cancelled: Dictionary = system.get_task_snapshot(first_id)
	_check(controls["cancelled"] and controls["reentrant_attempts"] > 0 and cancelled["state"] == &"cancelled"
		and cancelled["consumed_nutrition"] == 1 and cancelled["stage_paid"]
		and cancelled["effective_time"] == 0.0 and cancelled["stage_elapsed"] == 0.0,
		"Cancel callback at step start preserves one sunk material and zero granted time")
	_check(system.take_unspent_nutrition(first_id) == 7, "Reentrant cancellation makes remaining seven units refundable once")
	var continued_id: int = system.continue_differentiation(organ)
	system.receive_nutrition(continued_id, "unit-boundary:reentrant-continue", 7)
	system.organ_differentiated.connect(func(id: int, completed_organ: AttackOrgan, direction: int) -> void:
		_check(id == continued_id and completed_organ == organ and direction == AP
			and completed_organ.has_completed_differentiation(), "Completion observers already see authoritative completed organ")
		_check(not system.cancel_task() and not system.pause_task() and not system.resume_task()
			and system.start_differentiation(completed_organ, SCATTER) == 0
			and system.continue_differentiation(completed_organ) == 0, "Completion callback cannot cancel, reverse or complete a second attempt")
		system.advance(100.0)
	)
	system.advance(5.0)
	var frozen: Dictionary = system.get_task_snapshot(continued_id)
	var stock: int = organ.nutrition
	for _repeat: int in range(5):
		system.advance(100.0)
		system.resume_task()
		system.cancel_task()
		system.start_differentiation(organ, AP)
		system.continue_differentiation(organ)
		system.reset()
	_check(fixture.completed == [continued_id] and fixture.differentiated.size() == 1
		and organ.nutrition == stock and system.get_task_snapshot(continued_id) == frozen
		and system.get_availability(organ) == &"completed", "Repeated operations and reset cannot reverse completion or recreate stock")
	await _dispose(fixture)
	cases.append("reentrant_paid_start_cancel_guard_and_exactly_once_completion")


func _test_stock_clock_and_old_shots() -> void:
	var fixture := _make_fixture()
	var organ: AttackOrgan = fixture.mount.organ
	var weapon: SporeWeapon = fixture.mount.weapon
	var timer: Timer = weapon.get_node("FireTimer") as Timer
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = 200
	enemy.armor = 10
	enemy.move_speed = 0.0
	fixture.enemies.add_child(enemy)
	enemy.position = fixture.mount.host.position + Vector2(80.0, 0.0)
	weapon._on_fire_timer_timeout()
	_check(fixture.projectiles.get_child_count() == 1 and organ.nutrition == 3,
		"Actual ordinary weapon commits one paid flying projectile before differentiation")
	var old_shot: SporeProjectile = fixture.projectiles.get_child(0) as SporeProjectile
	_check(organ.reserve_nutrition(1), "Old ordinary paid packet has a real inventory reservation")
	var task_id: int = fixture.system.start_differentiation(organ, SCATTER)
	var stopped_statistics: Dictionary = weapon.get_shot_statistics()
	weapon._on_fire_timer_timeout()
	_check(timer.is_stopped() and weapon.get_shot_statistics() == stopped_statistics
		and not organ.is_combat_active() and organ.incoming_nutrition == 1,
		"Differentiation ceases ordinary fire and pauses fresh supply without deleting incoming reservation")
	_check(organ.complete_delivery(1) and organ.nutrition == 4 and organ.incoming_nutrition == 0,
		"Already paid ordinary packet remains deliverable during ceasefire")
	fixture.system.receive_nutrition(task_id, "unit-boundary:scatter-eight", 8)
	fixture.system.advance(5.0)
	_check(organ.nutrition == 4 and weapon.get_shot_statistics() == stopped_statistics
		and organ.get_attack_type() == SCATTER and _near(timer.time_left, 0.9),
		"Successful scatter differentiation preserves stock/statistics and starts one full new cooldown")
	old_shot._physics_process(10.0)
	_check(enemy.health == 198, "Already flying ordinary shot retains original normal damage after scatter differentiation")
	await physics_frame
	await physics_frame
	var clock: float = timer.time_left
	_check(clock > 0.0 and clock < 0.9, "Actual cooldown advances after completion")
	for _operation: int in range(5):
		fixture.system.start_differentiation(organ, SCATTER)
		fixture.system.continue_differentiation(organ)
		fixture.system.resume_task()
		fixture.system.advance(100.0)
		fixture.system.get_organ_snapshot(organ)
	_check(_near(timer.time_left, clock) and organ.nutrition == 4,
		"Rejected repeated operations and reads do not refresh cooldown or inventory")
	await _dispose(fixture)

	fixture = _make_fixture()
	organ = fixture.mount.organ
	weapon = fixture.mount.weapon
	timer = weapon.get_node("FireTimer") as Timer
	var ordinary_interval: float = weapon.get_weapon_profile().fire_interval
	var cancel_id: int = fixture.system.start_differentiation(organ, AP)
	fixture.system.advance(100.0)
	fixture.system.cancel_task()
	_check(organ.get_attack_type() == 0 and _near(timer.time_left, ordinary_interval),
		"Unfunded cancellation restores original ordinary profile at a full normal cooldown")
	await physics_frame
	await physics_frame
	clock = timer.time_left
	_check(not fixture.system.cancel_task() and not fixture.system.resume_task()
		and _near(timer.time_left, clock), "Repeated terminal operations cannot refresh the resumed normal clock")
	weapon.set_firing_enabled(false)
	var continued_id: int = fixture.system.continue_differentiation(organ)
	fixture.system.receive_nutrition(continued_id, "unit-boundary:disabled-ap", 8)
	fixture.system.advance(5.0)
	_check(continued_id > cancel_id and organ.is_work_enabled() and not weapon.is_firing_enabled()
		and timer.is_stopped() and organ.nutrition == 4 and organ.get_attack_type() == AP,
		"Completed AP preserves independent weapon disable and original ordinary stock")
	await _dispose(fixture)

	fixture = _make_fixture()
	organ = fixture.mount.organ
	organ.set_work_enabled(false)
	var paused_work_id: int = fixture.system.start_differentiation(organ, AP)
	_check(paused_work_id > 0 and fixture.system.cancel_task() and not organ.is_work_enabled(),
		"Cancel restores an originally work-disabled organ without enabling it")
	await _dispose(fixture)
	cases.append("original_stock_old_paid_ammo_old_shot_full_cooldown_and_independent_disable")


func _test_stop_reset_and_exit_settlement() -> void:
	var fixture := _make_fixture()
	var system: DifferentiationSystem = fixture.system
	var organ: AttackOrgan = fixture.mount.organ
	var task_id: int = system.start_differentiation(organ, AP)
	system.receive_nutrition(task_id, "unit-boundary:lifecycle-three", 3)
	system.advance(0.25)
	system.stop()
	system.stop()
	_check(system.is_stopped() and fixture.cancelled == [task_id] and not system.has_active_task()
		and system.get_task_snapshot(task_id)["buffered_nutrition"] == 2
		and system.start_differentiation(organ, AP) == 0, "Repeated stop cancels once and retains accessible refundable cache")
	system.reset()
	_check(not system.is_stopped() and system.get_availability(organ) == &"settlement_pending"
		and system.get_task_snapshot(task_id)["consumed_nutrition"] == 1, "Reset reopens admission but cannot erase unpaid settlement or sunk progress")
	_check(system.take_unspent_nutrition(task_id) == 2, "Reset still lets original task settle unused material")
	var continued_id: int = system.continue_differentiation(organ)
	_check(continued_id > task_id and system.get_task_snapshot()["stage_paid"]
		and _near(system.get_task_snapshot()["stage_elapsed"], 0.25), "Reset continues same partial stage under a fresh ID")
	system.receive_nutrition(continued_id, "unit-boundary:exit-two", 2)
	var settlement: Dictionary = {"count": 0, "refund": 0, "snapshot": {}}
	system.task_cancelled.connect(func(id: int) -> void:
		if id == continued_id:
			settlement["count"] += 1
			settlement["snapshot"] = system.get_task_snapshot(id)
			settlement["refund"] = system.take_unspent_nutrition(id)
	)
	system.queue_free()
	await process_frame
	_check(settlement["count"] == 1 and settlement["refund"] == 2
		and settlement["snapshot"]["state"] == &"cancelled"
		and settlement["snapshot"]["consumed_nutrition"] == 1,
		"System exit exposes terminal record before releasing the two-unit cache")
	_check(organ.get_differentiation_snapshot()["direction"] == AP
		and organ.get_differentiation_snapshot()["consumed_nutrition"] == 1
		and _near(organ.get_differentiation_snapshot()["stage_elapsed"], 0.25),
		"Organ retains authoritative direction and partial paid state after controller exits")
	await _dispose(fixture)
	cases.append("stop_idempotence_reset_retention_and_exit_before_original_cache_settlement")
