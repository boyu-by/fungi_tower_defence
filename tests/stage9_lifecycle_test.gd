extends SceneTree
## 隔离故障验收：明确使用损伤注入和成熟门槛夹具；所有材料仍由真实付款/运输结算。
const LEVEL: PackedScene = preload("res://scenes/levels/terrain_threat_demo.tscn")
var checks: int = 0
var failures: Array[String] = []
var level: TerrainThreatDemo
var audit_samples: int = 0
var first_imbalance: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1200, 800)
	level = LEVEL.instantiate() as TerrainThreatDemo
	(level.get_node("World/Colony/MotherCore") as MotherCore).initial_nutrition = 260
	(level.get_node("World/Colony/Nodes/RightNode/AttackOrgan") as AttackOrgan).initial_nutrition = 2
	root.add_child(level)
	current_scene = level
	await _frames(3)
	# 此项仅解锁分化/双尖端用于故障隔离，不增加母核余额或伪造经济来源。
	level.colony_progress.record_arrival("fixture-stage-unlock", 160)
	await _test_junction()
	await _test_differentiation_death()
	await _test_bud_and_tip()
	await _test_stomach()
	_check(first_imbalance.is_empty(), "All stable samples conserve nutrition across failures, refunds and losses")
	evidence["final_resources"] = level.get_combat_resource_snapshot()
	level.queue_free()
	await _frames(3, false)
	level = LEVEL.instantiate() as TerrainThreatDemo
	root.add_child(level)
	current_scene = level
	await _frames(3)
	_check(level.mother_core.nutrition == 72 and level.colony_progress.get_total_recovered() == 0,
		"Fresh scene resets capital and progression")
	var parts: Dictionary = level.get_combat_resource_snapshot()["parts"]
	_check(parts["removed_organ_stock"] == 0 and parts["destroyed_stomach_intake"] == 0
		and parts["destroyed_stomach_output"] == 0, "Fresh scene has no prior loss/identity state")
	level.queue_free()
	await _frames(2, false)
	print("STAGE9_LIFECYCLE_RESULT ", JSON.stringify({"checks": checks, "failures": failures,
		"audit_samples": audit_samples, "first_imbalance": first_imbalance, "evidence": evidence,
		"fixture": "260 initial capital, stage-only unlock and explicit damage injection; actual supply/timers"}))
	quit(0 if failures.is_empty() else 1)

func _test_junction() -> void:
	var host: HyphaNode = level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var organ: AttackOrgan = host.get_organ_occupant() as AttackOrgan
	var identity: int = host.get_instance_id()
	_check(level.supply_system.request_supply(organ), "A real paid combat shipment is in transit before failure")
	var transit: int = level.supply_system.get_in_transit_count()
	host.take_damage(45)
	_check(host.health == 0 and not organ.is_work_enabled() and organ.nutrition == 2,
		"Dead host pauses existing organ without losing its ammo or intent")
	_check(not level.network_system.is_available_connected_to_core(host), "Dead junction blocks normal network")
	await _frames(60)
	_check(organ.nutrition == 2 and level.supply_system.get_in_transit_count() == transit,
		"Already-paid cargo waits at the failed node instead of refunding or arriving")
	var task: int = level.repair_system.request_repair(host)
	_check(task > 0, "A dead junction accepts paid repair from its healthy neighbor")
	for _frame: int in range(1800):
		await _frames(1)
		if not level.repair_system.has_active_task():
			break
	_check(host.get_instance_id() == identity and is_equal_approx(host.health, 45.0), "Repair restores same junction to 45")
	_check(organ.is_work_enabled() and level.network_system.is_available_connected_to_core(host), "Repair resumes host function and network")
	_check(int(level.repair_system.get_task_snapshot().get("consumed_nutrition", 0)) == 5, "45 HP costs five actual nutrition")
	_check(organ.nutrition == 3 and level.supply_system.get_in_transit_count() == 0, "Original cargo resumes and settles once after repair")
	evidence["junction_repair"] = level.repair_system.get_task_snapshot().duplicate()

func _test_differentiation_death() -> void:
	var host: HyphaNode = level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode
	var organ: AttackOrgan = host.get_organ_occupant() as AttackOrgan
	var identity: int = organ.get_instance_id()
	var task: int = level.differentiation_system.start_differentiation(organ, 1)
	_check(task > 0, "Fixture unlocked organ starts real paid differentiation")
	for _frame: int in range(1000):
		await _frames(1)
		if int(level.differentiation_system.get_task_snapshot().get("consumed_nutrition", 0)) > 0:
			break
	var consumed: int = int(level.differentiation_system.get_task_snapshot().get("consumed_nutrition", 0))
	_check(consumed > 0 and consumed < 8, "Organ dies during actual material investment")
	organ.take_damage(60)
	await _frames(3)
	_check(not level.differentiation_system.has_active_task() and host.is_organ_slot_available(), "Destroyed organ retires task and leaves host slot")
	_check(not level.differentiation_system.receive_nutrition(task, "late-old-material", 1), "Old material callback cannot be accepted")
	_check(int(level.differentiation_system.get_resource_snapshot()["consumed_nutrition"]) == consumed, "Invested differentiation is never refunded")
	var accepted: Dictionary = level.construction_coordinator.enqueue_local_cultivation(host)
	_check(bool(accepted.get("accepted", false)), "Same host accepts paid base-organ rebuild")
	for _frame: int in range(2400):
		await _frames(1)
		if host.get_organ_occupant() is AttackOrgan:
			break
	var rebuilt: AttackOrgan = host.get_organ_occupant() as AttackOrgan
	_check(is_instance_valid(rebuilt), "Rebuild actually matures")
	if is_instance_valid(rebuilt):
		_check(rebuilt.get_instance_id() != identity and rebuilt.get_attack_type() == 0
			and not rebuilt.has_completed_differentiation() and rebuilt.nutrition == 4,
			"Rebuilt organ has fresh identity, normal profile and only its paid four starter ammo")
		_check(int(level.get_combat_resource_snapshot()["parts"]["removed_organ_stock"]) == 4, "Destroyed ammo counts as loss exactly once")

func _test_bud_and_tip() -> void:
	var start: HyphaNode = level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var request: Dictionary = level.construction_coordinator.enqueue(&"growth", {"start_node": start, "target_position": Vector2(790, 535)})
	var endpoint: HyphaNode
	for _frame: int in range(2400):
		await _frames(1)
		endpoint = _node_at(Vector2(790, 535))
		if endpoint != null:
			break
	_check(endpoint != null, "Paid expansion provides an empty host for bud fixture")
	if endpoint == null:
		return
	request = level.construction_coordinator.enqueue_local_cultivation(endpoint)
	var worker: ConstructionWorker
	for _frame: int in range(1600):
		await _frames(1)
		worker = level.construction_coordinator.get_worker(String(request.get("construction_id", "")))
		if worker != null and int(worker.cultivation_system.get_resource_snapshot()["structure_consumed"]) > 0:
			break
	var bud: OrganBud = endpoint.get_organ_bud()
	_check(is_instance_valid(bud) and worker != null, "Bud exists with paid investment")
	if is_instance_valid(bud) and worker != null:
		var old_task: int = int(worker.cultivation_system.get_task_snapshot()["task_id"])
		var invested: int = worker.cultivation_system.get_total_structure_consumed()
		bud.take_damage(25)
		await _frames(5)
		_check(endpoint.is_organ_slot_available() and not worker.cultivation_system.has_active_task(), "Bud death terminates only its task")
		_check(worker.cultivation_system.get_total_structure_consumed() == invested
			and not worker.cultivation_system.receive_nutrition(old_task, "late-bud", 1), "Dead bud keeps invested cost and rejects late shipment")
	request = level.construction_coordinator.enqueue(&"growth", {"start_node": start, "target_position": Vector2(1000, 575)})
	for _frame: int in range(1800):
		await _frames(1)
		worker = level.construction_coordinator.get_worker(String(request.get("construction_id", "")))
		if worker != null and float(worker.growth_system.get_task_snapshot().get("distance", 0.0)) > 12.0:
			break
	var tip: GrowthTip = worker.growth_system.get("_tip") as GrowthTip if worker != null else null
	_check(is_instance_valid(tip), "Real supplied extension has live tip")
	if is_instance_valid(tip):
		var invested: int = int(worker.growth_system.get_resource_snapshot()["consumed_nutrition"])
		tip.take_damage(25)
		await _frames(5)
		_check(not worker.growth_system.has_active_task(), "Tip death ends the extending task")
		_check(int(worker.growth_system.get_resource_snapshot()["consumed_nutrition"]) == invested,
			"Paid network is retained after tip death")

func _test_stomach() -> void:
	var stomach: DigestiveOrgan = level.digestive_organ
	var host: HyphaNode = stomach.get_parent() as HyphaNode
	var old_id: int = stomach.get_instance_id()
	level.nutrition_return_system.auto_return = false
	# 转换夹具资本为胃囊输入；每份先从同一母核扣款，未制造额外资源。
	for _i: int in range(2):
		_check(level.mother_core.try_spend_nutrition(10) and stomach.reserve_remains()
			and stomach.complete_delivery(10), "Fixture transfers ten existing nutrition into digestion")
	for _frame: int in range(1000):
		await _frames(1)
		if stomach.get_output_nutrition() == 20:
			break
	_check(level.mother_core.try_spend_nutrition(10) and stomach.reserve_remains()
		and stomach.complete_delivery(10), "Third fixture input is paid")
	level.nutrition_return_system.try_dispatch()
	var held_input: int = stomach.get_queued_nutrition()
	var held_output: int = stomach.get_output_nutrition()
	_check(held_input == 10 and held_output == 20, "Stomach death fixture includes inputs and products")
	stomach.take_damage(60)
	await _frames(4)
	var parts: Dictionary = level.get_combat_resource_snapshot()["parts"]
	_check(parts["destroyed_stomach_intake"] == held_input and parts["destroyed_stomach_output"] == held_output
		and parts["return_transit"] == 0, "Destroyed stomach holdings become losses, including canceled output transit")
	_check(host.is_organ_slot_available(), "Stomach death preserves host")
	var request: Dictionary = level.construction_coordinator.enqueue_local_cultivation(host)
	_check(bool(request.get("accepted", false)), "Paid stomach rebuilding uses construction queue")
	for _frame: int in range(2400):
		await _frames(1)
		if is_instance_valid(level.digestive_organ):
			break
	var rebuilt: DigestiveOrgan = level.digestive_organ
	_check(is_instance_valid(rebuilt), "Base stomach actually regrows")
	if is_instance_valid(rebuilt):
		_check(rebuilt.get_instance_id() != old_id and rebuilt.get_queued_nutrition() == 0
			and rebuilt.get_output_nutrition() == 0, "New stomach inherits no old products or inputs")
		var worker: ConstructionWorker = level.construction_coordinator.get_worker(String(request.get("construction_id", "")))
		_check(worker != null and worker.cultivation_system.get_total_structure_consumed() == 8,
			"Stomach rebuild charges eight materials as structure")

func _node_at(point: Vector2) -> HyphaNode:
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and node.global_position.distance_to(point) < 0.5:
			return node as HyphaNode
	return null

func _frames(count: int, audit: bool = true) -> void:
	for _i: int in range(count):
		await physics_frame
		await process_frame
		if audit and is_instance_valid(level) and not level.is_queued_for_deletion():
			audit_samples += 1
			if audit_samples % 20 == 0:
				var snapshot: Dictionary = level.get_combat_resource_snapshot()
				if snapshot.get("valid", false) and not snapshot.get("balanced", false) and first_imbalance.is_empty():
					first_imbalance = snapshot

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)
