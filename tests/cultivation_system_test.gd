extends SceneTree
## 手动推进培育状态；显式投递代表已支付到货，不使用母核扣费或免费初始库存。

const Cultivation = preload("res://scripts/cultivation_system.gd")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const EPSILON: float = 0.00001
const SNAPSHOT_KEYS: Array[String] = [
	"task_id", "bud_id", "organ_kind", "host", "state", "wait_reason", "progress", "effective_time",
	"minimum_time", "total_cost", "structure_cost", "startup_cost", "structure_consumed", "buffered_nutrition",
	"startup_reserved", "startup_transferred", "consumed_nutrition", "remaining_cost", "requested_nutrition",
]

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var host: HyphaNode
	var edge: HyphaEdge
	var network: NetworkSystem
	var cultivation: CultivationSystem
	var enemies: Node2D
	var projectiles: Node2D
	var completed: Array[int] = []
	var cancelled: Array[int] = []
	var matured: Array[Dictionary] = []
	var terminal_snapshots: Array[Dictionary] = []

	func dispose() -> void:
		cultivation.reset()
		world.queue_free()

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_slots_and_selection()
	_test_admission_and_configuration()
	_test_paid_stages_and_minimum_time()
	_test_pause_and_disconnect()
	_test_cancel_continue_and_history()
	_test_startup_reservation_and_continue()
	_test_receive_and_transition_reentry()
	_test_maturation_rollback()
	_test_host_removal_during_maturation()
	_test_host_removal_and_reset()
	await process_frame
	print("CULTIVATION_SYSTEM_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _make_fixture() -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.core = MotherCore.new()
	var health_bar: ProgressBar = ProgressBar.new()
	health_bar.name = "HealthBar"
	fixture.core.add_child(health_bar)
	fixture.world.add_child(fixture.core)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.network.register_node(fixture.core, true)
	fixture.host = _append_host(fixture, Vector2(100.0, 0.0))
	fixture.edge = fixture.world.get_child(fixture.world.get_child_count() - 1) as HyphaEdge
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.projectiles)
	fixture.cultivation = Cultivation.new()
	fixture.cultivation.network_system = fixture.network
	fixture.cultivation.enemy_container = fixture.enemies
	fixture.cultivation.projectile_container = fixture.projectiles
	fixture.world.add_child(fixture.cultivation)
	fixture.cultivation.set_physics_process(false)
	fixture.cultivation.task_completed.connect(func(task_id: int) -> void:
		fixture.completed.append(task_id)
		fixture.terminal_snapshots.append(fixture.cultivation.get_task_snapshot(task_id))
	)
	fixture.cultivation.task_cancelled.connect(func(task_id: int) -> void:
		fixture.cancelled.append(task_id)
		fixture.terminal_snapshots.append(fixture.cultivation.get_task_snapshot(task_id))
	)
	fixture.cultivation.organ_matured.connect(func(task_id: int, host: HyphaNode,
			organ: AttackOrgan, weapon: SporeWeapon) -> void:
		fixture.matured.append({"task_id": task_id, "host": host, "organ": organ, "weapon": weapon})
	)
	return fixture


func _append_host(fixture: Fixture, position: Vector2) -> HyphaNode:
	var host: HyphaNode = NODE_SCENE.instantiate()
	fixture.world.add_child(host)
	host.global_position = position
	fixture.network.register_node(host)
	var edge: HyphaEdge = EDGE_SCENE.instantiate()
	edge.start_node = fixture.core
	edge.end_node = host
	fixture.world.add_child(edge)
	fixture.network.register_edge(edge)
	return host


func _count_kind(host: HyphaNode, kind: StringName) -> int:
	var count: int = 0
	for child: Node in host.get_children():
		if child.is_queued_for_deletion():
			continue
		if (kind == &"bud" and child is OrganBud) or (kind == &"attack" and child is AttackOrgan) \
				or (kind == &"weapon" and child is SporeWeapon):
			count += 1
	return count


func _assert_snapshot(snapshot: Dictionary, description: String) -> void:
	_check(snapshot.has_all(SNAPSHOT_KEYS) and snapshot.size() == SNAPSHOT_KEYS.size(),
		description + ": exact task snapshot contract")
	if not snapshot.has_all(SNAPSHOT_KEYS):
		return
	_check(typeof(snapshot["task_id"]) == TYPE_INT and typeof(snapshot["bud_id"]) == TYPE_STRING
		and typeof(snapshot["state"]) == TYPE_STRING_NAME and typeof(snapshot["wait_reason"]) == TYPE_STRING_NAME,
		description + ": typed identity and states")
	_check(typeof(snapshot["progress"]) == TYPE_FLOAT and typeof(snapshot["effective_time"]) == TYPE_FLOAT
		and snapshot["minimum_time"] == 3.0 and snapshot["total_cost"] == 12,
		description + ": fixed paid time and cost")
	_check(snapshot["consumed_nutrition"] == snapshot["structure_consumed"] + snapshot["startup_transferred"]
		and snapshot["remaining_cost"] == 12 - snapshot["consumed_nutrition"]
		and snapshot["buffered_nutrition"] + snapshot["startup_reserved"] <= snapshot["remaining_cost"],
		description + ": sunk structure and refundable funds never overlap")


func _bad_scene() -> PackedScene:
	var node: Node2D = Node2D.new()
	var scene: PackedScene = PackedScene.new()
	scene.pack(node)
	node.queue_free()
	return scene


func _test_slots_and_selection() -> void:
	var host: HyphaNode = HyphaNode.new()
	_check(host.is_organ_slot_available() and host.get_organ_slot_state() == &"empty", "Bare mature slot is empty")
	_check(not host.try_reserve_organ_slot("") and host.try_reserve_organ_slot("one"), "Only nonempty lease identity is admitted")
	_check(host.get_organ_slot_state() == &"reserved" and not host.try_reserve_organ_slot("two"), "Lease prevents a second reservation")
	var foreign: AttackOrgan = AttackOrgan.new()
	_check(not host.commit_organ_slot("one", foreign), "A foreign child cannot commit a slot")
	_check(not host.release_organ_slot("two") and host.release_organ_slot("one")
		and not host.try_reserve_organ_slot("one"), "Released lease identity cannot be replayed")
	host.add_child(foreign)
	var digestive: DigestiveOrgan = DigestiveOrgan.new()
	host.add_child(digestive)
	_check(host.get_organ_occupant() == foreign and host.get_organ_slot_state() == &"attack"
		and not host.try_reserve_organ_slot("three"), "Unregistered preplaced organs occupy the slot")
	_check(host.get_child_count() == 2, "Manual multiple organs are preserved")
	host.queue_free()

	host = HyphaNode.new()
	var bud: OrganBud = OrganBud.new()
	host.add_child(bud)
	_check(host.get_organ_bud() == bud and not host.is_organ_slot_available(), "Preplaced bud occupies the slot")
	_check(host.try_reserve_organ_slot("mature", bud), "Only the exact existing bud can be replaced")
	var organ: AttackOrgan = AttackOrgan.new()
	host.add_child(organ)
	_check(host.commit_organ_slot("mature", organ) and host.get_organ_occupant() == organ
		and host.get_organ_slot_state() == &"attack", "Slot handoff commits the mature occupant before notifications")
	_check(bud.get_parent() == host and not bud.is_queued_for_deletion(), "Slot handoff never deletes an existing child itself")
	host.queue_free()

	var fixture: Fixture = _make_fixture()
	fixture.host.set_selected(true)
	_check(fixture.host.selection_ring.visible, "Existing selection-ring behavior is preserved")
	fixture.host.set_selected(false)
	_check(not fixture.host.selection_ring.visible, "Existing deselection behavior is preserved")
	fixture.dispose()


func _test_admission_and_configuration() -> void:
	var fixture: Fixture = _make_fixture()
	_assert_snapshot(fixture.cultivation.get_task_snapshot(), "Idle")
	_check(fixture.cultivation.get_cultivation_availability(null) == &"no_selection"
		and fixture.cultivation.start_cultivation(null) == 0, "Missing selection cannot create a bud")
	fixture.network.unregister_edge(fixture.edge)
	_check(fixture.cultivation.get_cultivation_availability(fixture.host) == &"disconnected"
		and fixture.cultivation.start_cultivation(fixture.host) == 0, "Disconnected mature node is rejected")
	fixture.network.register_edge(fixture.edge)
	var invalid_scene: PackedScene = _bad_scene()
	var original_attack: PackedScene = fixture.cultivation.attack_organ_scene
	fixture.cultivation.attack_organ_scene = invalid_scene
	_check(fixture.cultivation.get_cultivation_availability(fixture.host) == &"invalid_configuration"
		and fixture.cultivation.start_cultivation(fixture.host) == 0, "Invalid output scene creates no bud or charge")
	fixture.cultivation.attack_organ_scene = original_attack

	var growth: GrowthSystem = GrowthSystem.new()
	growth.network_system = fixture.network
	growth.node_container = fixture.world
	growth.edge_container = fixture.world
	growth.tip_container = fixture.world
	fixture.world.add_child(growth)
	growth.set_physics_process(false)
	fixture.cultivation.growth_system = growth
	_check(growth.create_target(fixture.host, Vector2(200.0, 0.0)) > 0 and growth.pause_task(), "Real paused growth fixture owns its build request")
	_check(fixture.cultivation.get_cultivation_availability(fixture.host) == &"construction_busy"
		and fixture.cultivation.start_cultivation(fixture.host) == 0, "Paused growth excludes cultivation")
	growth.cancel_task()
	fixture.core.nutrition = 0
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	_check(task_id > 0 and fixture.cultivation.get_delivery_target(task_id) == fixture.host,
		"Connected empty node can wait for real supply with an empty core")
	_check(fixture.cultivation.start_cultivation(fixture.host) == 0 and _count_kind(fixture.host, &"bud") == 1,
		"Repeated request cannot duplicate a bud")
	_check(fixture.cultivation.receive_nutrition(task_id, "configuration-paid", 12), "Delivered funds are accepted")
	var original_weapon: PackedScene = fixture.cultivation.weapon_scene
	fixture.cultivation.weapon_scene = invalid_scene
	fixture.cultivation.advance(20.0)
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(snapshot["wait_reason"] == &"invalid_configuration" and snapshot["structure_consumed"] == 0
		and snapshot["buffered_nutrition"] == 12, "Invalid changed scene freezes all refundable funds")
	fixture.cultivation.weapon_scene = original_weapon
	fixture.cultivation.advance(3.0)
	_check(fixture.completed == [task_id] and fixture.core.nutrition == 0, "Restored configuration completes without touching core funds")
	fixture.dispose()


func _test_paid_stages_and_minimum_time() -> void:
	var fixture: Fixture = _make_fixture()
	var initial_core: int = fixture.core.nutrition
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.advance(100.0)
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(snapshot["effective_time"] == 0.0 and snapshot["structure_consumed"] == 0
		and snapshot["requested_nutrition"] == 12, "Unfunded waiting consumes neither time nor nutrition")
	_check(_count_kind(fixture.host, &"attack") == 0 and _count_kind(fixture.host, &"weapon") == 0,
		"Inert bud has no weapon or battle inventory")
	fixture.cultivation.receive_nutrition(task_id, "full-paid", 12)
	for delta: float in [0.0, -1.0, NAN, INF]:
		fixture.cultivation.advance(delta)
	_check(fixture.cultivation.get_task_snapshot()["structure_consumed"] == 0, "Invalid delta cannot preconsume a stage")
	fixture.cultivation.advance(2.999)
	snapshot = fixture.cultivation.get_task_snapshot()
	_check(_near(snapshot["effective_time"], 2.999) and snapshot["structure_consumed"] == 8
		and fixture.completed.is_empty() and _count_kind(fixture.host, &"weapon") == 0,
		"Eight paid stages still require all three effective seconds")
	fixture.cultivation.advance(0.002)
	snapshot = fixture.cultivation.get_task_snapshot()
	_assert_snapshot(snapshot, "Completed")
	_check(fixture.completed == [task_id] and fixture.matured.size() == 1
		and snapshot["state"] == &"completed" and snapshot["effective_time"] == 3.0,
		"Maturation and completion are each emitted once")
	_check(snapshot["consumed_nutrition"] == 12 and snapshot["startup_transferred"] == 4
		and snapshot["startup_reserved"] == 0 and snapshot["buffered_nutrition"] == 0,
		"Exactly eight structure and four paid startup nutrition are consumed")
	var organ: AttackOrgan = fixture.matured[0]["organ"]
	var weapon: SporeWeapon = fixture.matured[0]["weapon"]
	_check(organ.get_parent() == fixture.host and weapon.get_parent() == fixture.host
		and organ.nutrition == 4 and organ.initial_nutrition == 4 and organ.incoming_nutrition == 0,
		"Sibling mature organ receives exactly the paid startup allocation before _ready")
	_check(weapon.inventory_owner == organ and weapon.enemy_container == fixture.enemies
		and weapon.projectile_container == fixture.projectiles and weapon.position == Vector2(0.0, -28.0)
		and weapon.attack_range == 100.0, "Mature weapon has configured references and ordinary range")
	_check(fixture.network.is_connected_to_core(fixture.host) and fixture.edge.end_node == fixture.host,
		"Maturation preserves the host and its network edge")
	_check(fixture.cultivation.get_resource_snapshot() == {
		"structure_consumed": 8, "buffered_nutrition": 0, "startup_reserved": 0,
	}, "Transferred startup is inventory history, not a second owned-resource category")
	fixture.cultivation.advance(100.0)
	_check(fixture.completed.size() == 1 and _count_kind(fixture.host, &"attack") == 1
		and _count_kind(fixture.host, &"weapon") == 1 and _count_kind(fixture.host, &"bud") == 0,
		"Completed bud cannot create another organ or weapon")
	_check(fixture.cultivation.start_cultivation(fixture.host) == 0
		and fixture.cultivation.get_bud_snapshot(fixture.host).is_empty()
		and fixture.core.nutrition == initial_core, "Occupied host rejects more cultivation and state never writes the core")
	fixture.dispose()


func _test_pause_and_disconnect() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.receive_nutrition(task_id, "first-stage", 1)
	fixture.cultivation.advance(0.2)
	fixture.cultivation.advance(10.0)
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(snapshot["effective_time"] == 0.375 and snapshot["structure_consumed"] == 1
		and snapshot["buffered_nutrition"] == 0, "One delivered nutrient pays exactly one 0.375-second stage")
	fixture.cultivation.receive_nutrition(task_id, "second-stage", 1)
	fixture.cultivation.advance(0.05)
	_check(fixture.cultivation.pause_task() and fixture.cultivation.has_active_task(), "Paused cultivation retains the build request")
	_check(fixture.cultivation.get_requested_nutrition(task_id) == 0
		and fixture.cultivation.receive_nutrition(task_id, "paid-before-pause", 3), "Pause suppresses demand but accepts paid arrivals")
	fixture.cultivation.advance(10.0)
	snapshot = fixture.cultivation.get_task_snapshot()
	_check(_near(snapshot["effective_time"], 0.425) and snapshot["structure_consumed"] == 2
		and snapshot["buffered_nutrition"] == 3, "Pause freezes the partially elapsed paid stage")
	fixture.cultivation.resume_task()
	fixture.network.unregister_edge(fixture.edge)
	fixture.cultivation.advance(10.0)
	snapshot = fixture.cultivation.get_task_snapshot()
	_check(snapshot["wait_reason"] == &"disconnected" and snapshot["requested_nutrition"] == 0
		and _near(snapshot["effective_time"], 0.425) and snapshot["buffered_nutrition"] == 3,
		"Disconnection freezes both funded progress and new demand")
	fixture.network.register_edge(fixture.edge)
	fixture.cultivation.advance(0.325)
	snapshot = fixture.cultivation.get_task_snapshot()
	_check(_near(snapshot["effective_time"], 0.75) and snapshot["structure_consumed"] == 2
		and snapshot["buffered_nutrition"] == 3, "Reconnect finishes the already-paid stage without paying it twice")
	fixture.cultivation.cancel_task()
	_check(fixture.cultivation.take_unspent_nutrition(task_id) == 3, "Only unspent arrivals remain refundable")
	fixture.dispose()


func _test_cancel_continue_and_history() -> void:
	var fixture: Fixture = _make_fixture()
	var first_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.receive_nutrition(first_id, "first-attempt-paid", 12)
	fixture.cultivation.advance(0.5)
	var bud: OrganBud = fixture.host.get_organ_bud()
	var bud_id: String = fixture.cultivation.get_bud_snapshot(fixture.host)["bud_id"]
	_check(fixture.cultivation.cancel_task() and not fixture.cultivation.cancel_task(), "Cancellation commits one terminal attempt")
	var cancelled: Dictionary = fixture.cultivation.get_task_snapshot(first_id)
	_assert_snapshot(cancelled, "Cancelled")
	_check(cancelled["structure_consumed"] == 2 and _near(cancelled["effective_time"], 0.5)
		and cancelled["buffered_nutrition"] == 10 and fixture.host.get_organ_bud() == bud,
		"Cancellation keeps paid structure and the same persistent bud")
	_check(fixture.cultivation.get_cultivation_availability(fixture.host) == &"settlement_pending"
		and fixture.cultivation.continue_cultivation(fixture.host) == 0, "Undrained old funds block continuation")
	_check(fixture.cultivation.take_unspent_nutrition(first_id) == 10
		and fixture.cultivation.take_unspent_nutrition(first_id) == 0, "Cancelled funds are atomically drained once")
	_check(fixture.cultivation.get_cultivation_availability(fixture.host) == &"continuable", "Drained cancelled bud is continuable")
	var second_id: int = fixture.cultivation.continue_cultivation(fixture.host)
	_check(second_id > first_id and fixture.host.get_organ_bud() == bud
		and fixture.cultivation.get_task_snapshot()["bud_id"] == bud_id
		and fixture.cultivation.get_requested_nutrition(second_id) == 10,
		"New attempt identity pays only the remaining ten nutrition")
	_check(not fixture.cultivation.receive_nutrition(first_id, "stale-paid", 1)
		and not fixture.cultivation.receive_nutrition(second_id, "first-attempt-paid", 1),
		"Stale task and globally duplicated shipment identities cannot fund a resumed bud")
	fixture.cultivation.receive_nutrition(second_id, "second-attempt-paid", 10)
	fixture.cultivation.advance(2.5)
	var old_snapshot: Dictionary = fixture.cultivation.get_task_snapshot(first_id)
	_check(old_snapshot["state"] == &"cancelled" and old_snapshot["structure_consumed"] == 2
		and old_snapshot["consumed_nutrition"] == 2 and old_snapshot["startup_transferred"] == 0
		and _near(old_snapshot["effective_time"], 0.5) and old_snapshot["buffered_nutrition"] == 0,
		"Old attempt accounting and progress do not follow the resumed bud")
	_check(fixture.completed == [second_id] and fixture.cultivation.get_total_structure_consumed() == 8,
		"Resumed partial stage completes once and unique-bud structure is counted once")
	fixture.dispose()


func _test_startup_reservation_and_continue() -> void:
	var fixture: Fixture = _make_fixture()
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.receive_nutrition(task_id, "structure-plus-two", 10)
	fixture.cultivation.advance(3.0)
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(snapshot["structure_consumed"] == 8 and snapshot["effective_time"] == 3.0
		and snapshot["startup_reserved"] == 2 and snapshot["buffered_nutrition"] == 0
		and snapshot["consumed_nutrition"] == 8 and snapshot["requested_nutrition"] == 2,
		"Full structure can wait with two refundable startup nutrients reserved")
	fixture.cultivation.cancel_task()
	_check(fixture.cultivation.take_unspent_nutrition(task_id) == 2, "Cancellation refunds reserved startup without refunding structure")
	var resumed_id: int = fixture.cultivation.continue_cultivation(fixture.host)
	_check(resumed_id > task_id and fixture.cultivation.get_requested_nutrition(resumed_id) == 4,
		"Fully paid structure needs only new paid startup after cancellation")
	fixture.cultivation.receive_nutrition(resumed_id, "replacement-startup", 4)
	fixture.cultivation.advance(0.001)
	_check(fixture.completed == [resumed_id] and fixture.cultivation.get_task_snapshot()["effective_time"] == 3.0
		and fixture.cultivation.get_task_snapshot(task_id)["startup_transferred"] == 0,
		"Waiting for startup adds no free time or retroactive old-attempt consumption")
	fixture.dispose()


func _test_receive_and_transition_reentry() -> void:
	var fixture: Fixture = _make_fixture()
	var reentry: Dictionary = {"duplicate_start": -1, "refund": 0, "seen_buffer": 0, "duplicate_receipt": true}
	fixture.host.organ_slot_changed.connect(func() -> void:
		if fixture.host.get_organ_slot_state() == &"reserved":
			reentry["duplicate_start"] = fixture.cultivation.start_cultivation(fixture.host)
	)
	fixture.cultivation.task_changed.connect(func(snapshot: Dictionary) -> void:
		if snapshot["buffered_nutrition"] == 12 and snapshot["state"] != &"cancelled":
			reentry["duplicate_receipt"] = fixture.cultivation.receive_nutrition(snapshot["task_id"], "reentrant-paid", 1)
			fixture.cultivation.cancel_task()
	)
	fixture.cultivation.task_cancelled.connect(func(task_id: int) -> void:
		reentry["seen_buffer"] = fixture.cultivation.get_task_snapshot(task_id)["buffered_nutrition"]
		reentry["refund"] = fixture.cultivation.take_unspent_nutrition(task_id)
		reentry["duplicate_start"] = fixture.cultivation.continue_cultivation(fixture.host)
	)
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	_check(reentry["duplicate_start"] == 0 and _count_kind(fixture.host, &"bud") == 1,
		"Slot notification cannot reenter creation")
	_check(fixture.cultivation.receive_nutrition(task_id, "reentrant-paid", 12)
		and not reentry["duplicate_receipt"] and reentry["seen_buffer"] == 12 and reentry["refund"] == 12,
		"Accepted receipt remains true when its signal cancels, deduplicates, and refunds synchronously")
	_check(fixture.cancelled == [task_id] and reentry["duplicate_start"] == 0
		and fixture.cultivation.get_task_snapshot()["consumed_nutrition"] == 0,
		"Terminal guard prevents synchronous continuation during cancellation")
	fixture.dispose()


func _test_maturation_rollback() -> void:
	var fixture: Fixture = _make_fixture()
	var observed: Dictionary = {"injected": false, "consumed": -1, "state": &"", "manual": null}
	fixture.host.child_entered_tree.connect(func(child: Node) -> void:
		if child is AttackOrgan and not observed["injected"]:
			observed["injected"] = true
			var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
			observed["consumed"] = snapshot["consumed_nutrition"]
			observed["state"] = snapshot["state"]
			var manual: AttackOrgan = ATTACK_SCENE.instantiate()
			manual.initial_nutrition = 0
			observed["manual"] = manual
			fixture.host.add_child(manual)
	)
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.receive_nutrition(task_id, "rollback-paid", 12)
	fixture.cultivation.advance(3.0)
	var snapshot: Dictionary = fixture.cultivation.get_task_snapshot()
	_check(observed["consumed"] == 8 and observed["state"] != &"completed",
		"Draft child callbacks never observe irreversible startup consumption before slot commit")
	_check(fixture.completed.is_empty() and fixture.matured.is_empty() and snapshot["startup_transferred"] == 0
		and snapshot["startup_reserved"] == 4 and snapshot["consumed_nutrition"] == 8,
		"Failed slot handoff restores four refundable startup nutrients")
	var manual: AttackOrgan = observed["manual"]
	_check(manual.get_parent() == fixture.host and not manual.is_queued_for_deletion()
		and _count_kind(fixture.host, &"attack") == 1 and _count_kind(fixture.host, &"bud") == 1,
		"Rollback removes only draft children and preserves the manually inserted organ")
	fixture.cultivation.cancel_task()
	_check(fixture.cultivation.take_unspent_nutrition(task_id) == 4, "Failed handoff leaves startup available for the supply owner to refund")
	fixture.dispose()


func _test_host_removal_during_maturation() -> void:
	var fixture: Fixture = _make_fixture()
	var observed: Dictionary = {"removed": false, "draft_consumed": -1, "cancel_consumed": -1, "refundable": -1, "refund": 0}
	fixture.host.child_entered_tree.connect(func(child: Node) -> void:
		if child is AttackOrgan and not observed["removed"]:
			observed["removed"] = true
			observed["draft_consumed"] = fixture.cultivation.get_task_snapshot()["consumed_nutrition"]
			fixture.host.queue_free()
	)
	fixture.cultivation.task_cancelled.connect(func(task_id: int) -> void:
		var snapshot: Dictionary = fixture.cultivation.get_task_snapshot(task_id)
		observed["cancel_consumed"] = snapshot["consumed_nutrition"]
		observed["refundable"] = snapshot["startup_reserved"] + snapshot["buffered_nutrition"]
		observed["refund"] = fixture.cultivation.take_unspent_nutrition(task_id)
	)
	var task_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.receive_nutrition(task_id, "removed-draft-paid", 12)
	fixture.cultivation.advance(3.0)
	_check(observed["draft_consumed"] == 8 and observed["cancel_consumed"] == 8
		and observed["refundable"] == 4 and observed["refund"] == 4,
		"Host removal restores draft startup before synchronous cancellation accounting")
	_check(fixture.cancelled == [task_id] and fixture.completed.is_empty() and fixture.matured.is_empty()
		and fixture.cultivation.get_total_structure_consumed() == 8
		and fixture.cultivation.take_unspent_nutrition(task_id) == 0,
		"Interrupted maturity cancels once, retains sunk structure, and cannot double-refund")
	fixture.dispose()


func _test_host_removal_and_reset() -> void:
	var fixture: Fixture = _make_fixture()
	var refunded: Dictionary = {"amount": 0}
	fixture.cultivation.task_cancelled.connect(func(task_id: int) -> void:
		refunded["amount"] += fixture.cultivation.take_unspent_nutrition(task_id)
	)
	var first_id: int = fixture.cultivation.start_cultivation(fixture.host)
	fixture.cultivation.receive_nutrition(first_id, "lost-host-paid", 4)
	fixture.cultivation.advance(0.1)
	fixture.world.remove_child(fixture.host)
	_check(fixture.cancelled == [first_id] and refunded["amount"] == 3
		and fixture.cultivation.get_total_structure_consumed() == 1,
		"Host tree exit cancels and drains while retaining lost sunk structure")
	fixture.host.queue_free()
	fixture.cultivation.reset()
	var replacement: HyphaNode = _append_host(fixture, Vector2(0.0, 100.0))
	var second_id: int = fixture.cultivation.start_cultivation(replacement)
	_check(second_id > first_id and not fixture.cultivation.receive_nutrition(second_id, "lost-host-paid", 1),
		"Reset never reuses attempt or accepted shipment identities")
	fixture.cultivation.receive_nutrition(second_id, "post-reset-paid", 12)
	fixture.cultivation.advance(3.0)
	fixture.cultivation.reset()
	_check(replacement.get_organ_slot_state() == &"attack" and _count_kind(replacement, &"weapon") == 1
		and fixture.cultivation.get_total_structure_consumed() == 9,
		"Reset preserves mature organs and sums completed plus lost unique-bud structure")
	fixture.dispose()
