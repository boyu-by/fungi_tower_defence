extends SceneTree
## 伤害承诺的只读预测、整批提交与一次性生命周期；命中仍使用真实敌人和弹丸。

const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/spore_projectile.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")

class Fixture:
	extends RefCounted
	var world: Node2D
	var enemies: Node2D
	var projectiles: Node2D
	var owners: Node
	var remains: Node2D
	var owner: Node
	var system: CombatTargetingSystem

# 只初始化被查询的生命值，避免母核的其他系统干扰只读威胁夹具。
class QuietCore:
	extends MotherCore
	func _ready() -> void:
		health = 100

class PreparationProbe:
	extends SporeProjectile
	static var observed_system: CombatTargetingSystem
	static var observed_target: BasicEnemy
	static var observations: Array[Dictionary] = []

	func _init() -> void:
		_capture("init")

	func launch_request(enemy: BasicEnemy, request: Dictionary) -> bool:
		_capture("launch_before")
		var accepted := super.launch_request(enemy, request)
		_capture("launch_after")
		return accepted

	func _enter_tree() -> void:
		_capture("enter")
		_physics_process(100.0)

	func _ready() -> void:
		_capture("ready")
		_physics_process(100.0)

	func _capture(stage: String) -> void:
		if is_instance_valid(observed_system) and is_instance_valid(observed_target):
			observations.append({"stage": stage,
				"snapshot": observed_system.get_snapshot(),
				"incoming": observed_system.get_incoming_damage(observed_target),
				"remaining": observed_system.get_remaining_health(observed_target),
				"health": observed_target.health})

class HoldingEnemy:
	extends BasicEnemy
	var system: CombatTargetingSystem
	var projectile: SporeProjectile
	var observer_owner: Node
	var damage_calls: int = 0
	var hp_on_entry: int = 0
	var incoming_on_entry: int = 0
	var remaining_on_entry: int = 0
	var incoming_after_reentry: int = 0
	var live_after_application: bool = false
	var attempted_duplicate: String = ""

	func apply_damage(request: Dictionary) -> int:
		damage_calls += 1
		hp_on_entry = health
		incoming_on_entry = system.get_incoming_damage(self)
		remaining_on_entry = system.get_remaining_health(self)
		projectile._physics_process(100.0)
		projectile.cancel_flight()
		incoming_after_reentry = system.get_incoming_damage(self)
		if estimate_damage(request) >= health:
			attempted_duplicate = system.prepare_commitment(self, request, observer_owner)
		var lost := super.apply_damage(request)
		live_after_application = system.is_commitment_live(projectile.get_damage_commitment_id())
		return lost

var checks: int = 0
var failures: Array[String] = []
var cases: Array[String] = []
var _initial_root_children: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_initial_root_children = root.get_child_count()
	await _test_readonly_estimate_and_threat()
	await _test_rejections_and_snapshot_isolation()
	await _test_prepared_coverage_and_callback_visibility()
	await _test_dynamic_armor_and_frozen_attacks()
	await _test_binding_and_atomic_batches()
	await _test_holding_promise_during_damage()
	await _test_projectile_terminal_paths()
	await _test_target_terminal_paths()
	await _test_owner_lifetime_and_shared_listener()
	await _test_repeated_target_listener_lifecycle()
	await _test_stale_listener_replay()
	await _test_reset_stop_and_stale_projectiles()
	await _test_legacy_unbound_projectiles()
	_check(root.get_child_count() == _initial_root_children, "All incoming-damage fixtures leave the tree")
	print("INCOMING_DAMAGE_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "cases": cases,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _request(raw_damage: int = 12, damage_type: int = 0) -> Dictionary:
	return {"raw_damage": raw_damage, "damage_type": damage_type}


func _new_fixture() -> Fixture:
	var fixture := Fixture.new()
	fixture.world = Node2D.new()
	fixture.enemies = Node2D.new()
	fixture.projectiles = Node2D.new()
	fixture.owners = Node.new()
	fixture.remains = Node2D.new()
	fixture.owner = Node.new()
	fixture.system = CombatTargetingSystem.new()
	fixture.world.add_child(fixture.enemies)
	fixture.world.add_child(fixture.projectiles)
	fixture.world.add_child(fixture.owners)
	fixture.world.add_child(fixture.remains)
	fixture.owners.add_child(fixture.owner)
	fixture.world.add_child(fixture.system)
	var spawner := RemainsSpawner.new()
	spawner.enemy_container = fixture.enemies
	spawner.remains_container = fixture.remains
	spawner.remains_scene = REMAINS_SCENE
	fixture.world.add_child(spawner)
	root.add_child(fixture.world)
	current_scene = fixture.world
	return fixture


func _dispose(fixture: Fixture) -> void:
	fixture.world.queue_free()
	await process_frame
	await process_frame


func _enemy(fixture: Fixture, hp: int = 100, armor_value: int = 0,
		position_value: Vector2 = Vector2(120, 52)) -> BasicEnemy:
	var enemy := ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.max_health = hp
	enemy.armor = armor_value
	enemy.move_speed = 0.0
	enemy.remains_nutrition = 7
	fixture.enemies.add_child(enemy)
	enemy.global_position = position_value
	enemy.set_physics_process(false)
	return enemy


func _blank_projectile() -> SporeProjectile:
	var projectile := PROJECTILE_SCENE.instantiate() as SporeProjectile
	(projectile.get_node("LifetimeTimer") as Timer).autostart = false
	projectile.set_physics_process(false)
	return projectile


func _draft(fixture: Fixture, target: BasicEnemy, request: Dictionary,
		id: String, mount: bool = true) -> SporeProjectile:
	var projectile := _blank_projectile()
	_check(projectile.launch_request(target, request), "Draft accepts a validated frozen launch")
	_check(projectile.bind_damage_commitment(fixture.system, id), "Draft binds its prepared commitment")
	if mount:
		fixture.projectiles.add_child(projectile)
		projectile.global_position = Vector2.ZERO
	return projectile


func _assert_snapshot(system: CombatTargetingSystem, prepared: int,
		committed: int, expected: int, label: String) -> void:
	var snapshot := system.get_snapshot()
	_check(snapshot.has_all(["generation", "accepting", "prepared_count", "committed_count",
		"total_count", "total_expected_damage", "commitments"]), label + " exposes the frozen snapshot fields")
	_check(int(snapshot["prepared_count"]) == prepared
		and int(snapshot["committed_count"]) == committed
		and int(snapshot["total_count"]) == prepared + committed,
		label + " counts every state exactly once")
	_check(int(snapshot["total_expected_damage"]) == expected,
		label + " sums current uncapped expected damage")
	var entries: Array = snapshot["commitments"]
	_check(entries.size() == prepared + committed, label + " owns one scalar entry per live commitment")


func _tracker_callbacks(signal_value: Signal, system: CombatTargetingSystem) -> Array[Callable]:
	var callbacks: Array[Callable] = []
	for connection: Dictionary in signal_value.get_connections():
		var callback: Callable = connection["callable"]
		if callback.get_object() == system:
			callbacks.append(callback)
	return callbacks


func _assert_target_watches(enemy: BasicEnemy, system: CombatTargetingSystem,
		expected: int, label: String) -> void:
	_check(_tracker_callbacks(enemy.died, system).size() == expected,
		label + " has one shared death listener while needed")
	_check(_tracker_callbacks(enemy.tree_exiting, system).size() == expected,
		label + " has one shared exit listener while needed")


func _test_readonly_estimate_and_threat() -> void:
	var unready := ENEMY_SCENE.instantiate() as BasicEnemy
	unready.armor = 4
	_check(unready.estimate_damage(_request()) == 8 and unready.health == 0,
		"Pure estimate remains valid before ready and independent of HP")
	_check(not unready.is_attacking_core() and is_inf(unready.get_core_distance_squared()),
		"Unready enemy has no attack or core distance")
	unready.free()
	var fixture := _new_fixture()
	var enemy := _enemy(fixture, 100, 4)
	var core_instance: Node = CORE_SCENE.instantiate()
	core_instance.set_script(QuietCore)
	var core := core_instance as QuietCore
	core.process_mode = Node.PROCESS_MODE_DISABLED
	fixture.world.add_child(core)
	core.global_position = Vector2(300, 200)
	enemy.mother_core = core
	enemy.global_position = core.global_position + Vector2(3, 4)
	enemy.contact_range = 6.0
	var timer := enemy.attack_timer
	timer.stop()
	for _repeat: int in range(5):
		_check(enemy.get_core_distance_squared() == 25.0 and not enemy.is_attacking_core(),
			"Ground distance ignores raised aim point; reach alone does not start attacking")
		_check(enemy.estimate_damage(_request()) == 8 and enemy.health == 100
			and enemy.health_bar.value == 100 and core.health == 100 and timer.is_stopped()
			and fixture.remains.get_child_count() == 0,
			"Readonly estimate and threat queries leave HP, timer and corpses unchanged")
	timer.start(20.0)
	_check(enemy.is_attacking_core(), "Live enemy in reach with a running AttackTimer threatens core")
	var remaining := timer.time_left
	timer.paused = true
	_check(not enemy.is_attacking_core() and timer.time_left == remaining,
		"Paused timer does not count as an actual attack and query does not restart it")
	timer.paused = false
	enemy.global_position += Vector2(30, 0)
	_check(not enemy.is_attacking_core() and not timer.is_stopped(),
		"Out-of-reach query does not stop an otherwise running timer")
	enemy.global_position = core.global_position + Vector2(3, 4)
	enemy.process_mode = Node.PROCESS_MODE_DISABLED
	_check(not enemy.is_attacking_core(), "Disabled enemy is not an active core attacker")
	enemy.process_mode = Node.PROCESS_MODE_INHERIT
	timer.process_mode = Node.PROCESS_MODE_DISABLED
	_check(not enemy.is_attacking_core(), "Disabled AttackTimer is not an actual running attack")
	timer.process_mode = Node.PROCESS_MODE_INHERIT
	_check(enemy.is_attacking_core(), "Restored processability preserves the running attack")
	core.health = 0
	_check(is_inf(enemy.get_core_distance_squared()) and not enemy.is_attacking_core(),
		"Dead core has no distance or threat")
	core.health = 100
	core.queue_free()
	_check(is_inf(enemy.get_core_distance_squared()) and not enemy.is_attacking_core(),
		"Queued core is unavailable even before its tree exit")
	await _dispose(fixture)
	cases.append("pure_estimates_ground_distance_and_actual_timer_threat")


func _test_rejections_and_snapshot_isolation() -> void:
	var fixture := _new_fixture()
	var enemy := _enemy(fixture, 100, 4)
	var invalid: Array[Dictionary] = [
		{}, {"raw_damage": 12}, {"damage_type": 0},
		_request(0), _request(-1), _request(12, 99),
		{"raw_damage": 12.0, "damage_type": 0},
		{"raw_damage": true, "damage_type": 0},
		{"raw_damage": 12, "damage_type": "0"},
	]
	for request: Dictionary in invalid:
		_check(fixture.system.prepare_commitment(enemy, request, fixture.owner).is_empty(),
			"Malformed commitment request is rejected without damage")
	var detached_owner := Node.new()
	_check(fixture.system.prepare_commitment(enemy, _request(), detached_owner).is_empty()
		and fixture.system.prepare_commitment(enemy, _request(), null).is_empty(),
		"Detached and missing prepared owners are rejected")
	detached_owner.free()
	_check(fixture.system.prepare_commitment(null, _request(), fixture.owner).is_empty()
		and fixture.system.get_incoming_damage(null) == 0
		and fixture.system.get_remaining_health(null) == 0, "Missing target is unavailable")
	enemy.health = 0
	_check(fixture.system.prepare_commitment(enemy, _request(), fixture.owner).is_empty(),
		"Dead target cannot be reserved")
	enemy.health = 100
	var request := _request()
	var id := fixture.system.prepare_commitment(enemy, request, fixture.owner)
	_check(not id.is_empty(), "Valid preparation gets a unique nonempty ID")
	var commitment := fixture.system.get_commitment(id)
	_check(commitment.size() == 9 and commitment.has_all(["id", "generation", "target_id",
		"owner_id", "projectile_id", "raw_damage", "damage_type", "expected_damage", "state"]),
		"Commitment exposes only the frozen scalar fields")
	for value: Variant in commitment.values():
		_check(typeof(value) in [TYPE_INT, TYPE_STRING, TYPE_STRING_NAME],
			"Snapshot contains no mutable request, node or weak reference")
	_check(commitment["state"] == &"prepared" and int(commitment["projectile_id"]) == 0
		and int(commitment["target_id"]) == enemy.get_instance_id()
		and int(commitment["owner_id"]) == fixture.owner.get_instance_id(),
		"Unbound preparation identifies its target and owner")
	request["raw_damage"] = 999
	request["damage_type"] = 1
	commitment["raw_damage"] = 777
	var snapshot := fixture.system.get_snapshot()
	var entries: Array = snapshot["commitments"]
	entries[0]["expected_damage"] = 999
	entries.clear()
	snapshot["accepting"] = false
	_check(fixture.system.get_incoming_damage(enemy) == 8
		and int(fixture.system.get_commitment(id)["raw_damage"]) == 12
		and fixture.system.is_accepting(), "Caller mutations cannot alter requests or snapshots")
	var other := CombatTargetingSystem.new()
	fixture.world.add_child(other)
	var other_id := other.prepare_commitment(enemy, _request(), fixture.owner)
	_check(not other_id.is_empty() and other_id != id, "Separate system instances never reuse an ID")
	_check(fixture.system.get_commitment("missing").is_empty()
		and not fixture.system.is_commitment_live("missing")
		and not fixture.system.is_commitment_committed(id)
		and not fixture.system.release_commitment("missing"), "Missing IDs are inert")
	_check(enemy.health == 100 and enemy.health_bar.value == 100
		and fixture.remains.get_child_count() == 0, "All predictions and rejects leave actual combat untouched")
	await _dispose(fixture)
	cases.append("validated_scalar_requests_independent_snapshots_and_instance_ids")


func _test_prepared_coverage_and_callback_visibility() -> void:
	var fixture := _new_fixture()
	var enemy := _enemy(fixture, 10, 4)
	var first := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
	var second := fixture.system.prepare_commitment(enemy, _request(6, 2), fixture.owner)
	_check(fixture.system.get_incoming_damage(enemy) == 10
		and fixture.system.get_remaining_health(enemy) == 0, "Prepared promises immediately cover HP")
	_check(fixture.system.get_incoming_damage(enemy, PackedStringArray([first])) == 2
		and fixture.system.get_remaining_health(enemy, PackedStringArray([first])) == 8,
		"Ignored IDs alter only the caller's prediction")
	_check(fixture.system.get_remaining_health(enemy, PackedStringArray([first, second])) == 10
		and fixture.system.prepare_commitment(enemy, _request(100), fixture.owner).is_empty(),
		"Query ignores do not allow preparing against fully covered HP")
	_check(fixture.system.release_commitment(first) and not fixture.system.release_commitment(first),
		"Release succeeds exactly once")
	_check(fixture.system.release_commitment(second), "Other independent preparation is releasable")
	var huge := fixture.system.prepare_commitment(enemy, _request(100), fixture.owner)
	_check(fixture.system.get_incoming_damage(enemy) == 96
		and fixture.system.get_remaining_health(enemy) == 0, "Expected damage is uncapped by remaining HP")
	fixture.system.release_commitment(huge)
	var id := fixture.system.prepare_commitment(enemy, _request(14), fixture.owner)
	PreparationProbe.observed_system = fixture.system
	PreparationProbe.observed_target = enemy
	PreparationProbe.observations.clear()
	var instance: Node = PROJECTILE_SCENE.instantiate()
	instance.set_script(PreparationProbe)
	var projectile := instance as PreparationProbe
	(projectile.get_node("LifetimeTimer") as Timer).autostart = false
	_check(projectile.launch_request(enemy, _request(14)), "Probe launches after preparation is visible")
	_check(projectile.bind_damage_commitment(fixture.system, id), "Probe binds before entering tree")
	fixture.projectiles.add_child(projectile)
	projectile.set_physics_process(false)
	_check(PreparationProbe.observations.size() >= 5, "Probe exercised init, launch and tree callbacks")
	for observation: Dictionary in PreparationProbe.observations:
		var state: Dictionary = observation["snapshot"]
		_check(int(state["prepared_count"]) == 1 and int(state["committed_count"]) == 0
			and int(observation["incoming"]) == 10 and int(observation["remaining"]) == 0
			and int(observation["health"]) == 10,
			"Every synchronous projectile callback sees the complete prepared promise")
	_check(enemy.health == 10 and fixture.remains.get_child_count() == 0,
		"Prepared projectile cannot hit even with manual physics reentry")
	_check(fixture.system.commit_batch(PackedStringArray([id])), "Prepared probe commits once tree-ready")
	projectile._physics_process(100.0)
	_check(enemy.health == 0 and fixture.remains.get_child_count() == 1
		and not fixture.system.release_commitment(id), "Committed probe deals one hit and releases its promise")
	PreparationProbe.observed_system = null
	PreparationProbe.observed_target = null
	PreparationProbe.observations.clear()
	await _dispose(fixture)
	cases.append("prepared_visibility_ignored_query_ids_uncapped_coverage_and_inert_drafts")


func _test_dynamic_armor_and_frozen_attacks() -> void:
	var fixture := _new_fixture()
	var enemy := _enemy(fixture, 100, 4)
	var ids := PackedStringArray()
	var projectiles: Array[SporeProjectile] = []
	for damage_type: int in range(3):
		var request := _request(6 if damage_type == 2 else 12, damage_type)
		var id := fixture.system.prepare_commitment(enemy, request, fixture.owner)
		ids.append(id)
		projectiles.append(_draft(fixture, enemy, request, id))
		request["raw_damage"] = 999
		request["damage_type"] = 1
	_assert_snapshot(fixture.system, 3, 0, 22, "Three frozen prepared attacks")
	_assert_target_watches(enemy, fixture.system, 1, "Overlapping target promises")
	_check(_tracker_callbacks(fixture.owner.tree_exiting, fixture.system).size() == 1,
		"One prepared owner shares a listener across all three IDs")
	enemy.armor = 20
	_check(fixture.system.get_incoming_damage(enemy) == 14, "Prepared estimates follow increased current armor")
	_check(fixture.system.commit_batch(ids), "Complete matching draft batch commits atomically")
	_check(_tracker_callbacks(fixture.owner.tree_exiting, fixture.system).is_empty(),
		"Committing the batch detaches all promises from owner lifetime")
	enemy.armor = 0
	_assert_snapshot(fixture.system, 0, 3, 30, "Committed attacks after armor removal")
	enemy.health = 5
	_check(fixture.system.get_incoming_damage(enemy) == 30
		and fixture.system.get_remaining_health(enemy) == 0, "Low current HP does not cap any estimate")
	enemy.health = 100
	enemy.armor = 9
	_check(fixture.system.get_incoming_damage(enemy) == 16, "Normal and scatter mitigate; AP stays frozen and ignores armor")
	projectiles[0]._physics_process(100.0)
	_check(enemy.health == 97 and fixture.system.get_incoming_damage(enemy) == 13,
		"Normal impact uses frozen raw damage with armor at hit time")
	projectiles[1]._physics_process(100.0)
	_check(enemy.health == 85 and fixture.system.get_incoming_damage(enemy) == 1,
		"AP impact retains frozen type and raw damage")
	projectiles[2]._physics_process(100.0)
	_check(enemy.health == 84 and fixture.system.get_incoming_damage(enemy) == 0,
		"Scatter impact retains minimum-one mitigation")
	_assert_target_watches(enemy, fixture.system, 0, "Last settled impact")
	await _dispose(fixture)
	cases.append("frozen_raw_type_with_dynamic_prepared_and_committed_armor")


func _test_binding_and_atomic_batches() -> void:
	var fixture := _new_fixture()
	var first := _enemy(fixture)
	var second := _enemy(fixture, 100, 0, Vector2(180, 52))
	var third := _enemy(fixture, 100, 0, Vector2(240, 52))
	var first_id := fixture.system.prepare_commitment(first, _request(), fixture.owner)
	var second_id := fixture.system.prepare_commitment(second, _request(), fixture.owner)
	var third_id := fixture.system.prepare_commitment(third, _request(), fixture.owner)
	var unlaunched := _blank_projectile()
	_check(not unlaunched.bind_damage_commitment(fixture.system, first_id), "Binding requires launch first")
	unlaunched.free()
	for mismatch: String in ["target", "raw", "type"]:
		var wrong := _blank_projectile()
		var request := _request(13 if mismatch == "raw" else 12, 1 if mismatch == "type" else 0)
		_check(wrong.launch_request(second if mismatch == "target" else first, request),
			"Mismatched binding fixture still has a valid launch")
		_check(not wrong.bind_damage_commitment(fixture.system, first_id),
			"Binding rejects a mismatched " + mismatch)
		wrong.free()
	var a := _draft(fixture, first, _request(), first_id)
	var b := _draft(fixture, second, _request(), second_id, false)
	_check(not a.bind_damage_commitment(fixture.system, first_id)
		and not a.bind_damage_commitment(fixture.system, second_id), "Projectile cannot bind twice or switch IDs")
	var duplicate := _blank_projectile()
	_check(duplicate.launch_request(first, _request())
		and not duplicate.bind_damage_commitment(fixture.system, first_id), "An ID belongs to at most one projectile")
	duplicate.free()
	_check(not fixture.system.commit_batch(PackedStringArray()), "Empty batch is rejected")
	_check(not fixture.system.commit_batch(PackedStringArray([first_id, first_id])), "Duplicate batch IDs are rejected")
	_check(not fixture.system.commit_batch(PackedStringArray([first_id, "missing"])), "Unknown suffix cannot partially commit a valid prefix")
	_check(not fixture.system.commit_batch(PackedStringArray([first_id, third_id])), "Unbound suffix cannot partially commit a valid prefix")
	_check(not fixture.system.commit_batch(PackedStringArray([first_id, second_id])), "Off-tree draft cannot commit")
	_assert_snapshot(fixture.system, 3, 0, 36, "Failed batches retain valid preparations for rollback")
	b.process_mode = Node.PROCESS_MODE_DISABLED
	fixture.projectiles.add_child(b)
	_check(fixture.system.commit_batch(PackedStringArray([first_id, second_id])),
		"Tree-ready disabled drafts may commit before activation")
	_assert_snapshot(fixture.system, 1, 2, 36, "One atomic successful batch")
	_check(not fixture.system.commit_batch(PackedStringArray([first_id, third_id]))
		and not fixture.system.is_commitment_committed(third_id), "Mixed committed/prepared batch cannot partly transition")
	var c := _draft(fixture, third, _request(), third_id)
	c.target = first
	_check(not fixture.system.commit_batch(PackedStringArray([third_id])),
		"Changed launched target cannot commit a matching-looking ID")
	c._physics_process(100.0)
	_check(first.health == 100 and third.health == 100, "Invalid linked draft dissipates without untracked fallback")
	a.cancel_flight()
	b.cancel_flight()
	await _dispose(fixture)
	cases.append("one_to_one_matching_binding_and_all_or_none_unique_ready_batches")


func _test_holding_promise_during_damage() -> void:
	for hp: int in [100, 8]:
		var fixture := _new_fixture()
		var instance: Node = ENEMY_SCENE.instantiate()
		instance.set_script(HoldingEnemy)
		var enemy := instance as HoldingEnemy
		enemy.max_health = hp
		enemy.armor = 4
		enemy.system = fixture.system
		enemy.observer_owner = fixture.owner
		fixture.enemies.add_child(enemy)
		enemy.set_physics_process(false)
		enemy.global_position = Vector2(40, 52)
		var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
		var projectile := _draft(fixture, enemy, _request(), id)
		enemy.projectile = projectile
		_check(fixture.system.commit_batch(PackedStringArray([id])), "Holding fixture commits one live promise")
		projectile._physics_process(100.0)
		projectile._physics_process(100.0)
		_check(enemy.damage_calls == 1 and enemy.hp_on_entry == hp
			and enemy.incoming_on_entry == 8 and enemy.incoming_after_reentry == 8
			and enemy.remaining_on_entry == maxi(0, hp - 8),
			"Damage entry sees covered old HP despite hit/cancel reentry")
		_check(enemy.health == hp - 8 and not fixture.system.is_commitment_live(id),
			"Hit applies exactly once and releases only after application returns")
		_check(enemy.live_after_application == (hp > 8),
			"Nonlethal synchronous callbacks retain promise; lethal callbacks release it with death")
		_check(enemy.attempted_duplicate.is_empty() and fixture.remains.get_child_count() == (1 if hp == 8 else 0),
			"Covered lethal old HP cannot create a duplicate promise or corpse")
		await _dispose(fixture)
	cases.append("promise_held_through_synchronous_damage_and_finished_before_reentry")


func _test_projectile_terminal_paths() -> void:
	for committed: bool in [false, true]:
		for outcome: String in ["timeout", "cancel", "queue_free", "free", "exit"]:
			var fixture := _new_fixture()
			var enemy := _enemy(fixture)
			var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
			var projectile := _draft(fixture, enemy, _request(), id)
			if committed:
				_check(fixture.system.commit_batch(PackedStringArray([id])), "Terminal fixture commits before outcome")
			match outcome:
				"timeout":
					projectile.speed = 0.0
					(projectile.get_node("LifetimeTimer") as Timer).start(0.01)
					for _frame: int in range(4):
						await physics_frame
				"cancel":
					projectile.cancel_flight()
					projectile.cancel_flight()
					projectile._physics_process(100.0)
				"queue_free": projectile.queue_free()
				"free": projectile.free()
				"exit": fixture.projectiles.remove_child(projectile)
			_check(not fixture.system.is_commitment_live(id) and not fixture.system.release_commitment(id),
				outcome + " releases prepared/committed promise once")
			_check(enemy.health == 100 and fixture.remains.get_child_count() == 0,
				outcome + " finishes without damage or corpse")
			if outcome == "exit":
				projectile.free()
			await _dispose(fixture)
	var fixture := _new_fixture()
	var enemy := _enemy(fixture)
	var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
	var detached := _draft(fixture, enemy, _request(), id, false)
	detached.free()
	_check(not fixture.system.release_commitment(id), "Freeing a bound pre-tree draft releases immediately")
	_assert_target_watches(enemy, fixture.system, 0, "Freed pre-tree draft")
	await _dispose(fixture)
	cases.append("real_timeout_cancel_free_queue_and_tree_exit_once_without_damage")


func _test_target_terminal_paths() -> void:
	for committed: bool in [false, true]:
		for outcome: String in ["death", "queue_free", "free", "exit"]:
			var fixture := _new_fixture()
			var enemy := _enemy(fixture)
			var bystander := _enemy(fixture, 100, 0, Vector2(60, 52))
			var ids := PackedStringArray()
			var projectiles: Array[SporeProjectile] = []
			for raw: int in [12, 1]:
				var id := fixture.system.prepare_commitment(enemy, _request(raw), fixture.owner)
				ids.append(id)
				projectiles.append(_draft(fixture, enemy, _request(raw), id))
			if committed:
				_check(fixture.system.commit_batch(ids), "Target outcome fixture commits overlapping promises")
			match outcome:
				"death": enemy.take_damage(999)
				"queue_free": enemy.queue_free()
				"free": enemy.free()
				"exit": fixture.enemies.remove_child(enemy)
			if outcome != "free":
				_check(fixture.system.get_incoming_damage(enemy) == 0
					and fixture.system.get_remaining_health(enemy) == 0, "Unavailable target has zero prediction")
			for id: String in ids:
				_check(not fixture.system.release_commitment(id), outcome + " releases every overlapping target member")
			for projectile: SporeProjectile in projectiles:
				projectile._physics_process(100.0)
			_check(bystander.health == 100 and fixture.remains.get_child_count() == (1 if outcome == "death" else 0),
				outcome + " never retargets or adds a second corpse")
			if outcome == "exit":
				enemy.free()
			await _dispose(fixture)
	cases.append("target_death_exit_and_free_release_all_without_retargeting")


func _test_owner_lifetime_and_shared_listener() -> void:
	var fixture := _new_fixture()
	var ids := PackedStringArray()
	for offset: int in range(3):
		var enemy := _enemy(fixture, 100, 0, Vector2(100 + offset * 40, 52))
		ids.append(fixture.system.prepare_commitment(enemy, _request(), fixture.owner))
	_check(_tracker_callbacks(fixture.owner.tree_exiting, fixture.system).size() == 1,
		"Scatter-style three-target preparation connects one owner listener")
	fixture.owners.remove_child(fixture.owner)
	for id: String in ids:
		_check(not fixture.system.release_commitment(id), "Owner exit immediately releases every prepared member")
	_check(_tracker_callbacks(fixture.owner.tree_exiting, fixture.system).is_empty(),
		"Final prepared member disconnects owner listener")
	fixture.owner.free()
	await _dispose(fixture)
	for outcome: String in ["pause", "exit", "free", "queue_free"]:
		fixture = _new_fixture()
		var prepared_target := _enemy(fixture)
		var committed_target := _enemy(fixture, 100, 0, Vector2(180, 52))
		var prepared_id := fixture.system.prepare_commitment(prepared_target, _request(), fixture.owner)
		var committed_id := fixture.system.prepare_commitment(committed_target, _request(), fixture.owner)
		var projectile := _draft(fixture, committed_target, _request(), committed_id)
		_check(fixture.system.commit_batch(PackedStringArray([committed_id])), "Mixed-owner fixture commits just its launched member")
		match outcome:
			"pause": fixture.owner.process_mode = Node.PROCESS_MODE_DISABLED
			"exit": fixture.owners.remove_child(fixture.owner)
			"free": fixture.owner.free()
			"queue_free": fixture.owner.queue_free()
		_check(fixture.system.is_commitment_committed(committed_id)
			and fixture.system.get_incoming_damage(committed_target) == 12,
			outcome + " cannot cancel a projectile-owned committed promise")
		if outcome != "pause":
			_check(not fixture.system.is_commitment_live(prepared_id), outcome + " retires only the prepared member")
		projectile._physics_process(100.0)
		_check(committed_target.health == 88 and prepared_target.health == 100,
			outcome + " retains actual committed damage and leaves unlaunched target untouched")
		if outcome == "exit":
			fixture.owner.free()
		await _dispose(fixture)
	cases.append("shared_prepared_owner_listener_and_projectile_owned_commit_survival")


func _test_repeated_target_listener_lifecycle() -> void:
	var fixture := _new_fixture()
	var enemy := _enemy(fixture, 100)
	var live_ids := PackedStringArray()
	var projectiles: Array[SporeProjectile] = []
	for _round: int in range(4):
		var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
		live_ids.append(id)
		var projectile := _draft(fixture, enemy, _request(), id)
		projectiles.append(projectile)
		_check(fixture.system.commit_batch(PackedStringArray([id])), "Repeated same-target round commits a fresh ID")
		_assert_target_watches(enemy, fixture.system, 1, "Same target across overlapping rounds")
	_check(fixture.system.get_incoming_damage(enemy) == 48, "Overlapping rounds count four independent promises")
	projectiles[0].cancel_flight()
	_assert_target_watches(enemy, fixture.system, 1, "Partial same-target release")
	enemy.take_damage(999)
	for id: String in live_ids:
		_check(not fixture.system.release_commitment(id), "Death releases all remaining repeated-round members once")
	_assert_target_watches(enemy, fixture.system, 0, "Last same-target death release")
	await _dispose(fixture)
	fixture = _new_fixture()
	enemy = _enemy(fixture)
	for _round: int in range(4):
		var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
		_assert_target_watches(enemy, fixture.system, 1, "Reconnected same-target reservation")
		_check(fixture.system.release_commitment(id), "Each renewed reservation releases once")
		_assert_target_watches(enemy, fixture.system, 0, "Last member removes both listeners")
	await _dispose(fixture)
	cases.append("overlapping_repeated_rounds_and_last_member_listener_cleanup")


func _test_stale_listener_replay() -> void:
	for renewal: String in ["reset", "last_release"]:
		var fixture := _new_fixture()
		var enemy := _enemy(fixture)
		var old_id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
		var old_died: Callable = _tracker_callbacks(enemy.died, fixture.system)[0]
		var old_target_exit: Callable = _tracker_callbacks(enemy.tree_exiting, fixture.system)[0]
		var old_owner_exit: Callable = _tracker_callbacks(fixture.owner.tree_exiting, fixture.system)[0]
		if renewal == "reset":
			fixture.system.reset()
		else:
			fixture.system.release_commitment(old_id)
		var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
		_check(id != old_id and fixture.system.is_commitment_live(id), "Renewed same-node watch gets a fresh promise")
		old_died.call(enemy)
		old_target_exit.call()
		old_owner_exit.call()
		_check(fixture.system.is_commitment_live(id) and not fixture.system.release_commitment(old_id)
			and fixture.system.get_incoming_damage(enemy) == 12,
			renewal + " old target/owner callback tokens cannot release current membership")
		_assert_target_watches(enemy, fixture.system, 1, renewal + " current watcher survived stale callbacks")
		_check(_tracker_callbacks(fixture.owner.tree_exiting, fixture.system).size() == 1,
			renewal + " current owner watcher survived stale callbacks")
		fixture.owners.remove_child(fixture.owner)
		_check(not fixture.system.release_commitment(id), "Current owner callback still releases its real member")
		fixture.owner.free()
		await _dispose(fixture)
	cases.append("stale_generation_and_same_epoch_listener_tokens_cannot_edit_new_records")


func _test_reset_stop_and_stale_projectiles() -> void:
	var fixture := _new_fixture()
	var enemy := _enemy(fixture)
	var old_ids := PackedStringArray()
	var old_projectiles: Array[SporeProjectile] = []
	for committed: bool in [false, true]:
		var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
		old_ids.append(id)
		old_projectiles.append(_draft(fixture, enemy, _request(), id))
		if committed:
			_check(fixture.system.commit_batch(PackedStringArray([id])), "Reset fixture includes a committed flight")
	var generation: int = fixture.system.get_snapshot()["generation"]
	fixture.system.reset()
	_check(fixture.system.is_accepting() and int(fixture.system.get_snapshot()["generation"]) > generation,
		"Reset advances epoch and accepts new work")
	_assert_snapshot(fixture.system, 0, 0, 0, "Reset cancelled all old states")
	var new_id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
	_check(not new_id.is_empty() and not old_ids.has(new_id), "Reset serial reuse still gets a globally fresh epoch ID")
	for projectile: SporeProjectile in old_projectiles:
		projectile._physics_process(100.0)
		projectile._on_lifetime_timer_timeout()
		projectile.cancel_flight()
	for old_id: String in old_ids:
		_check(not fixture.system.release_commitment(old_id)
			and not fixture.system.commit_batch(PackedStringArray([old_id])), "Old ID callbacks cannot commit or release new epoch")
	_check(enemy.health == 100 and fixture.system.is_commitment_live(new_id)
		and fixture.system.get_incoming_damage(enemy) == 12, "Cancelled stale flights never hit or edit new records")
	var next := _draft(fixture, enemy, _request(), new_id)
	_check(fixture.system.commit_batch(PackedStringArray([new_id])), "New epoch can commit normally")
	var before_stop: int = fixture.system.get_snapshot()["generation"]
	fixture.system.stop()
	_check(not fixture.system.is_accepting() and int(fixture.system.get_snapshot()["generation"]) > before_stop
		and fixture.system.prepare_commitment(enemy, _request(), fixture.owner).is_empty(), "Stop clears and rejects until reset")
	next._physics_process(100.0)
	_check(enemy.health == 100 and not fixture.system.release_commitment(new_id), "Stopped committed flight is cancelled without impact")
	fixture.system.reset()
	var exit_id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
	var exiting := _draft(fixture, enemy, _request(), exit_id)
	_check(fixture.system.commit_batch(PackedStringArray([exit_id])), "Exit fixture includes committed work")
	fixture.world.remove_child(fixture.system)
	_check(not fixture.system.is_accepting() and fixture.system.get_commitment(exit_id).is_empty(),
		"Tracker tree exit stops and clears it")
	exiting._physics_process(100.0)
	_check(enemy.health == 100, "Tracker exit cancels flight without legacy fallback")
	fixture.system.free()
	await _dispose(fixture)
	cases.append("reset_stop_exit_cancel_old_flights_and_reject_stale_ids")


func _test_legacy_unbound_projectiles() -> void:
	var fixture := _new_fixture()
	var enemy := _enemy(fixture, 100, 4)
	var unbound := _blank_projectile()
	_check(unbound.launch_request(enemy, _request()), "Legacy unbound request is still accepted")
	fixture.projectiles.add_child(unbound)
	unbound.process_mode = Node.PROCESS_MODE_DISABLED
	unbound._physics_process(100.0)
	_check(enemy.health == 100, "Manual physics respects process-disabled guard for unbound flight")
	unbound.process_mode = Node.PROCESS_MODE_INHERIT
	unbound._physics_process(100.0)
	unbound._physics_process(100.0)
	_check(enemy.health == 92 and unbound.get_damage_commitment_id().is_empty(),
		"Unbound request deals one normal armored hit")
	var legacy := _blank_projectile()
	legacy.launch(enemy, 12)
	fixture.projectiles.add_child(legacy)
	legacy._physics_process(100.0)
	_check(enemy.health == 84 and fixture.system.get_incoming_damage(enemy) == 0,
		"Legacy launch remains untracked and compatible")
	var id := fixture.system.prepare_commitment(enemy, _request(), fixture.owner)
	var linked := _draft(fixture, enemy, _request(), id)
	_check(fixture.system.commit_batch(PackedStringArray([id])), "Missing-record fixture has a real linked flight")
	fixture.system.release_commitment(id)
	linked._physics_process(100.0)
	_check(enemy.health == 84, "Released linked flight never falls back to untracked damage")
	await _dispose(fixture)
	cases.append("legacy_compatibility_processing_guard_and_no_linked_fallback")
