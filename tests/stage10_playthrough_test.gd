extends SceneTree
## 正常玩法验收：原72营养、80/120资源、真实运输/成熟/武器；不注入资源、伤害或成长。
const LEVEL: PackedScene = preload("res://scenes/levels/colony_operations_demo.tscn")
var level: ColonyOperationsDemo
var failures: Array[String] = []
var checks: int = 0
var samples: int = 0
var first_imbalance: Dictionary = {}
var evidence: Dictionary = {}
var stomach_capacity_ok: bool = true

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	level = LEVEL.instantiate() as ColonyOperationsDemo
	root.add_child(level)
	current_scene = level
	await _frames(4)
	_check(level.mother_core.nutrition == 72, "Original72 capital is unchanged")
	_check(level.get_digestive_organs().size() == 1, "Original one stomach retained")
	_check(level.growth_planner.bounded_branches_enabled and level.growth_planner.auto_join_enabled, "Stage10 enables finite paid branches and joins")
	level.growth_input_controller.enter_placement_mode()
	_check(not level.growth_input_controller.place_target(Vector2(875, 415)), "Rock interior rejected before payment")
	_check(level.growth_input_controller.place_target(Vector2(990, 440)), "Normal G expansion accepted")
	var first_id: String = String(level.construction_coordinator.get_snapshot()["selected_id"])
	for _i: int in range(1200):
		await _frames(1)
		var started: ConstructionWorker = level.construction_coordinator.get_worker(first_id)
		if started != null and int(started.growth_system.get_task_snapshot().get("consumed_nutrition", 0)) > 0:
			break
	var first_worker: ConstructionWorker = level.construction_coordinator.get_worker(first_id)
	if first_worker == null:
		_check(false, "First worker starts")
		await _finish()
		return
	var before: Dictionary = first_worker.growth_system.get_task_snapshot()
	_check(not level.construction_coordinator.retarget(first_id, Vector2(875, 415)), "Invalid redirection leaves valid task intact")
	_check(first_worker.growth_system.get_task_snapshot()["target_position"] == before["target_position"], "Invalid direction preserves former landing")
	var quote: Dictionary = level.construction_coordinator.preview_retarget(first_id, Vector2(970, 440))
	_check(bool(quote.get("valid", false)), "Paid growth gets a new legal direction")
	_check(level.construction_coordinator.retarget(first_id, Vector2(970, 440)), "Active redirection accepted")
	var after: Dictionary = first_worker.growth_system.get_task_snapshot()
	_check(after["task_id"] == before["task_id"] and int(after["plan_version"]) > int(before["plan_version"]), "Same task with explicit new planning version")
	_check(int(after["consumed_nutrition"]) >= int(before["consumed_nutrition"]), "Redirection never resets spent materials")
	evidence["redirection"] = {"id": first_id, "before_cost": before["total_cost"], "after_cost": after["total_cost"], "deferred": quote.get("deferred"), "effective_point": quote.get("effective_point")}
	level.growth_input_controller.enter_placement_mode()
	_check(level.growth_input_controller.place_target(Vector2(160, 450)), "Second external target queues during first growth")
	var second_id: String = String(level.construction_coordinator.get_snapshot()["selected_id"])
	_check(level.construction_coordinator.retarget(second_id, Vector2(180, 450)), "Unstarted target replans immediately")
	for _i: int in range(7000):
		await _frames(1)
		if _node_at(Vector2(970, 440)) != null:
			break
	var front: HyphaNode = _node_at(Vector2(970, 440))
	_check(front != null, "Original capital and real returns connect first resource")
	var stomach_host: HyphaNode = _empty_near(Vector2(910, 510), front)
	_check(stomach_host != null, "Paid network supplies another empty mature stomach host")
	var stomach_id: String = ""
	if stomach_host != null:
		level._select_node(stomach_host)
		level.choose_organ(&"digestive")
		var preview: Dictionary = level.cultivation_input_controller.get_selection_status()
		_check(int(preview.get("total_cost", 0)) == 8, "UI quotes stomach8")
		_check(level.cultivation_input_controller.request_cultivation(), "Player C starts paid second stomach")
		stomach_id = String(level.construction_coordinator.get_snapshot()["selected_id"])
	for _i: int in range(24000):
		await _frames(1)
		if level.colony_progress.get_total_recovered() >= 200 and level.get_digestive_organs().size() == 2:
			break
	_check(level.colony_progress.get_total_recovered() == 200, "Two real carcasses return200 through shared logistics")
	_check(level.colony_progress.get_stage() == ColonyProgress.Stage.MATURE, "Real returns unlock mature colony")
	_check(level.get_digestive_organs().size() == 2, "Second stomach genuinely matures")
	if not stomach_id.is_empty():
		var request: Dictionary = level.construction_coordinator.get_request(stomach_id)
		var built: Dictionary = request.get("detail", {})
		_check(request.get("state") == &"completed" and int(built.get("structure_consumed", 0)) == 8 and int(built.get("startup_transferred", 0)) == 0, "Stomach consumes eight structure and zero startup")
		_check(float(built.get("effective_time", 0)) >= 3.0, "Paid stomach takes at least3 effective seconds")
	var digestion: Array[Dictionary] = []
	for stomach: DigestiveOrgan in level.get_digestive_organs():
		_check(stomach.digested_count > 0, "Both stomachs handle real collection work")
		digestion.append({"id": stomach.get_instance_id(), "digested": stomach.digested_count, "sleep": stomach.is_dormant()})
	_check(stomach_capacity_ok, "Each stomach always stays within input and two-output20 limits")
	evidence["digestion"] = digestion
	_check(_node_at(Vector2(180, 450)) != null, "Waiting redirected target completes")
	var second_worker: ConstructionWorker = level.construction_coordinator.get_worker(second_id)
	if second_worker != null:
		_check(int(second_worker.growth_system.get_task_snapshot().get("plan_version", 0)) >= 2, "Queued version survives actual start")
	var actual_branches: int = 0
	for grown_worker: ConstructionWorker in level.construction_coordinator.get_workers(true):
		actual_branches += grown_worker.growth_system.get_task_snapshot().get("plan", {}).get("branches", []).size()
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		if bool(edge.get_meta("short_branch", false)) or bool(edge.get_meta("is_side_branch", false)):
			actual_branches += 1
		if edge.has_endpoints():
			_check(level.terrain_navigation.is_segment_clear(edge.start_node.global_position, edge.end_node.global_position), "Actual branch/main edge respects rocks")
	evidence["branch_edges"] = actual_branches
	# A normal G operation touches a preexisting unconnected empty node: auto-join keeps its identity.
	var joined: bool = false
	for origin: Node2D in level.network_system.get_registered_nodes():
		if joined or not origin is HyphaNode:
			continue
		for destination: Node2D in level.network_system.get_registered_nodes():
			if destination == origin or not destination is HyphaNode or origin.global_position.distance_to(destination.global_position) > 190.0 \
				or level.network_system.has_direct_connection(origin, destination):
				continue
			var plan: Dictionary = level.growth_system.preview_target(origin, destination.global_position + Vector2(1, 0))
			if not bool(plan.get("valid", false)) or plan.get("join_node") != destination:
				continue
			var request: Dictionary = level.construction_coordinator.enqueue(&"growth", {"start_node": origin, "target_position": destination.global_position + Vector2(1, 0)})
			if not bool(request.get("accepted", false)):
				continue
			var identifier: String = String(request["construction_id"])
			for _i: int in range(4000):
				await _frames(1)
				if level.construction_coordinator.get_request(identifier).get("state") in ConstructionQueue.TERMINAL_STATES:
					break
			_check(level.construction_coordinator.get_request(identifier).get("state") == &"completed", "Normal G auto joins existing endpoint")
			joined = true
			break
	_check(joined, "Playable map supports actual auto joining")
	var source: HyphaNode = level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var organ: AttackOrgan = source.get_organ_occupant() as AttackOrgan
	_check(organ.is_dormant, "Old defense sleeps after12 seconds with no enemies")
	var identity: int = organ.get_instance_id()
	var diff: int = level.differentiation_system.start_differentiation(organ, WeaponProfile.DamageType.ARMOR_PIERCING)
	_check(diff > 0, "Original defense pays for differentiation")
	for _i: int in range(3500):
		await _frames(1)
		if not level.differentiation_system.has_active_task():
			break
	_check(organ.has_completed_differentiation(), "Differentiation actually completes")
	var stock: int = organ.nutrition
	var health: float = organ.health
	level._select_node(source)
	_check(level.begin_transplant(), "Player M selects original attack organ")
	_check(front != null and level.commit_operation_at(front.global_position), "Player picks paid-frontier destination")
	for _i: int in range(6500):
		await _frames(1)
		if not level.transplant_system.has_active_task():
			break
	var transplant: Dictionary = level.transplant_system.get_task_snapshot()
	_check(transplant.get("state") == &"completed", "Shared FIFO migration and unfolding complete")
	_check(front.get_organ_occupant() == organ and organ.get_instance_id() == identity and source.is_organ_slot_available(), "Same original organ changes host, leaving old node empty")
	_check(organ.nutrition == stock and is_equal_approx(organ.health, health) and organ.has_completed_differentiation(), "Migration preserves actual inventory life and differentiation")
	_check(int(transplant.get("consumed_nutrition", 0)) == 6 and float(transplant.get("effective_time", 0)) >= 3.0, "Transplant consumes true6 and unfolds for3 seconds")
	evidence["transplant"] = {"identity": identity, "stock": stock, "health": health, "task": transplant["task_id"], "fee": transplant["consumed_nutrition"]}
	level.select_test_batch(&"gnawer")
	_check(not level.start_test_batch().is_empty(), "Normal enemy batch starts after migration")
	var spent: int = level.get_combat_statistics()["nutrition_spent"]
	for _i: int in range(8000):
		await _frames(1)
		if level.enemy_spawner.get_active_count() == 0 and level.enemy_spawner.get_batch_snapshot().get("state") == &"completed":
			break
	_check(level.enemy_spawner.defeated_count == 3, "Ordinary weapons defeat actual frontier batch")
	_check(level.get_combat_statistics()["nutrition_spent"] > spent, "Defense wakes and pays ammunition to resume combat")
	_check(level.mother_core.health > 0, "Colony survives playable flow")
	_check(first_imbalance.is_empty(), "Whole normal flow conserves all nutrition across unique holders")
	evidence["final_resources"] = level.get_combat_resource_snapshot()
	evidence["final_batch"] = level.get_combat_demo_snapshot()
	evidence["frontier"] = level.get_frontier_snapshot()
	var enemy_status: Array[Dictionary] = []
	for enemy: Node in level.get_node("World/Enemies").get_children():
		if enemy is BasicEnemy:
			enemy_status.append({"position": enemy.global_position, "health": enemy.health, "kind": enemy.archetype})
	evidence["remaining_enemies"] = enemy_status
	await _finish()

func _empty_near(point: Vector2, excluded: HyphaNode) -> HyphaNode:
	var nearest: HyphaNode
	var distance: float = INF
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and node != excluded and node.is_organ_slot_available() \
			and level.network_system.is_available_connected_to_core(node):
			if point.distance_to(node.global_position) < distance:
				nearest = node
				distance = point.distance_to(node.global_position)
	return nearest

func _node_at(point: Vector2) -> HyphaNode:
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and node.global_position.distance_to(point) < 0.5:
			return node
	return null

func _frames(count: int) -> void:
	for _i: int in range(count):
		await physics_frame
		await process_frame
		samples += 1
		if samples % 1200 == 0 and is_instance_valid(level) and not level.is_queued_for_deletion():
			print("STAGE10_PROGRESS ", JSON.stringify({"sample": samples, "checks": checks, "recovered": level.colony_progress.get_total_recovered(), "core": level.mother_core.nutrition, "targets": level.construction_coordinator.get_snapshot().get("external_count", 0), "transplant": level.transplant_system.get_task_snapshot().get("state")}))
		if is_instance_valid(level) and not level.is_queued_for_deletion() and samples % 15 == 0:
			var ledger: Dictionary = level.get_combat_resource_snapshot()
			if bool(ledger.get("valid", false)) and not bool(ledger.get("balanced", false)) and first_imbalance.is_empty():
				first_imbalance = {"sample": samples, "ledger": ledger}
			for stomach: DigestiveOrgan in level.get_digestive_organs():
				stomach_capacity_ok = stomach_capacity_ok and stomach.get_queued_count() + stomach.incoming_remains <= stomach.capacity \
					and stomach.get_output_count() <= 2 and stomach.get_output_nutrition() <= 20

func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)

func _finish() -> void:
	print("STAGE10_PLAYTHROUGH_RESULT ", JSON.stringify({"checks": checks, "failures": failures, "samples": samples, "first_imbalance": first_imbalance, "evidence": evidence, "fixture": "none; original resources and actual time/transport/combat"}))
	level.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
