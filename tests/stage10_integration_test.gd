extends SceneTree
## 隔离破坏性整合验收：显式260初始资本、直接损伤与腐坏时间推进；全部建设和移植费用仍真实运输。
const LEVEL: PackedScene = preload("res://scenes/levels/colony_operations_demo.tscn")
const REMAINS: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
var level: ColonyOperationsDemo
var checks: int = 0
var failures: Array[String] = []
var samples: int = 0
var imbalance: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	level = LEVEL.instantiate() as ColonyOperationsDemo
	(level.get_node("World/Colony/MotherCore") as MotherCore).initial_nutrition = 260
	# Fixture corpse is included in the ledger's initial total before ready; no later counterfeit income.
	var decay_corpse: EnemyRemains = REMAINS.instantiate() as EnemyRemains
	decay_corpse.name = "DecayFixture"
	decay_corpse.position = Vector2(30, 260)
	level.get_node("World/Remains").add_child(decay_corpse)
	root.add_child(level)
	current_scene = level
	await _frames(3)
	var before_decay: int = level.get_combat_resource_snapshot()["parts"]["decayed_remains"]
	decay_corpse.advance_decay(55.0)
	await _frames(2)
	_check(int(level.get_combat_resource_snapshot()["parts"]["decayed_remains"]) == before_decay + 4, "Natural ground expiry becomes explicit4 loss, no income")
	var source: HyphaNode = level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var destination: Vector2 = Vector2(785, 510)
	var remote: Dictionary = level.construction_coordinator.enqueue(&"remote_cultivation", {"start_node": source, "target_position": destination, "organ_kind": &"digestive"})
	_check(bool(remote.get("accepted", false)), "Explicit remote stomach accepts actual network plus8 quote")
	var identifier: String = String(remote.get("construction_id", ""))
	var duplicate: Dictionary = level.construction_coordinator.enqueue(&"growth", {"start_node": level.mother_core, "target_position": destination})
	_check(not bool(duplicate.get("accepted", false)) and duplicate.get("construction_id") == identifier, "Different source or construction kind cannot duplicate a reserved landing")
	for _i: int in range(4000):
		await _frames(1)
		if level.construction_coordinator.get_request(identifier).get("state") in ConstructionQueue.TERMINAL_STATES:
			break
	var completed: Dictionary = level.construction_coordinator.get_request(identifier)
	_check(completed.get("state") == &"completed", "Remote stomach handoff and independent maturation actually finish")
	var host: HyphaNode = _node_at(destination)
	var stomach: DigestiveOrgan = host.get_organ_occupant() as DigestiveOrgan if host != null else null
	_check(stomach != null and level.get_digestive_organs().size() == 2, "New stomach registered beside original")
	_check(int(completed.get("detail", {}).get("organ_cost", 0)) == 8, "Remote stomach has no extra endpoint charge or attack starter ammo")
	_check(not level.construction_coordinator.retarget(identifier, Vector2(800, 550)), "Matured remote stomach cannot change host by retarget")
	if stomach != null:
		# Explicit failure fixture: remove only the original stomach, preserving its registered replacement.
		var old: DigestiveOrgan = level.digestive_organ
		var old_id: int = old.get_instance_id()
		old.take_damage(old.health)
		await _frames(3)
		_check(level.recycling_system.get_digestive_organs().has(stomach) and level.nutrition_return_system.get_digestive_organs().has(stomach), "Other receiver and return source survive initial stomach death")
		_check(level.recycling_system.get_digestive_organs().size() == 1, "Dead original receiver is retired exactly once")
		evidence["destroyed_original"] = old_id
	# Source is same original attack instance; explicit damage is only this failure fixture.
	var organ: AttackOrgan = source.get_organ_occupant() as AttackOrgan
	organ.take_damage(9)
	var old_organ_id: int = organ.get_instance_id()
	var old_stock: int = organ.nutrition
	var empty: HyphaNode = _find_empty()
	_check(empty != null, "Paid side network offers an empty transplant target")
	var task: int = level.transplant_system.request_transplant(organ, empty)
	_check(task > 0, "Injured original organ accepts real6 paid transplant")
	for _i: int in range(2000):
		await _frames(1)
		if level.transplant_system.get_task_snapshot().get("state") == &"migrating":
			break
	_check(level.transplant_system.get_task_snapshot().get("state") == &"migrating", "Body departs only after six real deliveries")
	organ.take_damage(organ.health)
	await _frames(3)
	_check(level.transplant_system.get_task_snapshot().get("state") == &"failed" and not level.transplant_system.has_active_task(), "In-transit tissue death closes one task")
	_check(empty.is_organ_slot_available(), "Destroyed body releases its destination")
	var parts: Dictionary = level.get_combat_resource_snapshot()["parts"]
	_check(int(parts["removed_organ_stock"]) == old_stock and int(parts["transplant_consumed"]) == 6, "Destroyed carried stock and committed six fee each have one destination")
	_check(int(parts["transplant_stock"]) == 0 and int(parts["transplant_transit"]) == 0, "No ghost body or old fee transport remains")
	evidence["destroyed_transplant"] = {"organ_id": old_organ_id, "stock": old_stock, "parts": parts}
	_check(imbalance.is_empty(), "Destructive fixtures preserve the whole-level ledger")
	# Close a real preparing task and retain the old packet references across scene replacement.
	var left: HyphaNode = level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode
	var survivor: AttackOrgan = left.get_organ_occupant() as AttackOrgan
	var reopening: int = level.transplant_system.request_transplant(survivor, source)
	_check(reopening > 0, "A second original organ can prepare a subsequent transplant")
	await _frames(30)
	var records: Array[Dictionary] = level.transplant_system.get_shipment_records()
	level._announce_level_stopping(&"restart")
	level.queue_free()
	await process_frame
	await process_frame
	level = LEVEL.instantiate() as ColonyOperationsDemo
	root.add_child(level)
	current_scene = level
	await _frames(4)
	for record: Dictionary in records:
		var packet: Variant = record.get("packet")
		_check(not is_instance_valid(packet), "Old paid callback carrier removed before new scene")
	_check(level.mother_core.nutrition == 72 and level.colony_progress.get_total_recovered() == 0, "New scene starts original72 and zero recovered")
	parts = level.get_combat_resource_snapshot()["parts"]
	_check(int(parts["decayed_remains"]) == 0 and int(parts["removed_organ_stock"]) == 0 and int(parts["transplant_consumed"]) == 0, "Old natural decay and transplant death do not leak into new ledger")
	print("STAGE10_INTEGRATION_RESULT ", JSON.stringify({"checks": checks, "failures": failures, "samples": samples, "first_imbalance": imbalance, "evidence": evidence, "fixture": "260 initial core +4 initial ground corpse; direct damage/expiry only; construction and6 fees use actual supply"}))
	level.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _node_at(point: Vector2) -> HyphaNode:
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and node.global_position.distance_to(point) < 0.5:
			return node
	return null

func _find_empty() -> HyphaNode:
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and node.is_organ_slot_available() and level.network_system.is_available_connected_to_core(node):
			return node
	return null

func _frames(count: int) -> void:
	for _i: int in range(count):
		await physics_frame
		await process_frame
		samples += 1
		if is_instance_valid(level) and not level.is_queued_for_deletion() and samples % 10 == 0:
			var ledger: Dictionary = level.get_combat_resource_snapshot()
			if bool(ledger.get("valid", false)) and not bool(ledger.get("balanced", false)) and imbalance.is_empty():
				imbalance = ledger

func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)
