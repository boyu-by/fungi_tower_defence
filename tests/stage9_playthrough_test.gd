extends SceneTree
## 正式新场景的真实时钟流程：无直接伤害、无营养注入、无加速生产或预置分化。
const LEVEL: PackedScene = preload("res://scenes/levels/terrain_threat_demo.tscn")
var level: TerrainThreatDemo
var failures: Array[String] = []
var checks: int = 0
var samples: int = 0
var first_imbalance: Dictionary = {}
var evidence: Dictionary = {}
var blocked_seen: bool = false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1200, 800)
	level = LEVEL.instantiate() as TerrainThreatDemo
	root.add_child(level)
	current_scene = level
	await _frames(3)
	var initial: int = level.mother_core.nutrition
	level.growth_input_controller.enter_placement_mode()
	_check(not level.growth_input_controller.place_target(Vector2(875, 415)), "G rejects a rock interior")
	_check(level.mother_core.nutrition == initial, "Invalid landing does not charge capital")
	level.growth_input_controller.exit_placement_mode()
	await _grow(Vector2(970, 440))
	await _grow(Vector2(180, 450))
	for _frame: int in range(22000):
		await _frames(1)
		if level.colony_progress.get_total_recovered() >= 200:
			break
	_check(level.colony_progress.get_total_recovered() == 200, "Both 80/120 resources actually return through digestion and traffic")
	_check(level.colony_progress.get_stage() == ColonyProgress.Stage.MATURE, "Real recovery unlocks maturity")
	evidence["after_resources"] = level.get_combat_resource_snapshot()
	var front: HyphaNode = _node_at(Vector2(970, 440))
	_check(front != null, "Frontier resource node exists")
	if front != null:
		level._select_node(front)
		_check(level.cultivation_input_controller.request_cultivation(), "Player C submits paid forward defense")
		for _frame: int in range(2600):
			await _frames(1)
			if front.get_organ_occupant() is AttackOrgan:
				break
		_check(front.get_organ_occupant() is AttackOrgan, "Forward defense matures through real supply")
	await _grow(Vector2(1100, 530))
	var exposed: HyphaNode = _node_at(Vector2(1100, 530))
	_check(exposed != null, "An exposed paid frontier is established")
	# 正常付费分化，仍保留刚建立的前沿普通器官，保护撤退方向。
	var left: HyphaNode = level.get_node("World/Colony/Nodes/HyphaNode") as HyphaNode
	var left_organ: AttackOrgan = left.get_organ_occupant() as AttackOrgan
	var diff: int = level.differentiation_system.start_differentiation(left_organ, 1)
	_check(diff > 0, "Paid differentiation coexists with new terrain")
	for _frame: int in range(2600):
		await _frames(1)
		if not level.differentiation_system.has_active_task():
			break
	_check(left_organ.has_completed_differentiation(), "Actual eight-material differentiation completes")
	level.select_test_batch(&"gnawer")
	_check(not level.start_test_batch().is_empty(), "Starts configured batch containing exactly one gnawer")
	for _frame: int in range(6500):
		await _frames(1)
		if level.network_break_count > 0 and level.enemy_spawner.get_active_count() == 0 \
				and level.enemy_spawner.get_batch_snapshot().get("state") == &"completed":
			break
	_check(level.tissue_attack_count > 0 and level.network_break_count > 0, "Real enemy movement and timer attacks break the network")
	_check(level.enemy_spawner.defeated_count == 3, "Existing weapons protect the inner frontier and kill all three attackers")
	evidence["after_attack"] = level.get_frontier_snapshot()
	var damaged_nodes: Array[HyphaNode] = []
	var damaged_edges: Array[HyphaEdge] = []
	for node: Node2D in level.network_system.get_registered_nodes():
		if node is HyphaNode and node.health < node.max_health:
			damaged_nodes.append(node)
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		if edge.health < edge.max_health:
			damaged_edges.append(edge)
	# 接入前沿的断段先修，再修枯结；其余自然主脉升级缺口无需为验收全部补满。
	for edge: HyphaEdge in damaged_edges:
		if edge.health <= 0.0:
			await _repair(edge)
	for node: HyphaNode in damaged_nodes:
		await _repair(node)
	_check(exposed != null and exposed.is_functional() and level.network_system.is_available_connected_to_core(exposed),
		"Real nutrition repair restores exposed frontier function and connection")
	# L 绕路连接演示两翼，验证已有终点没有再生成或收费。
	var right: HyphaNode = level.get_node("World/Colony/Nodes/RightNode") as HyphaNode
	var quote: Dictionary = level.connection_system.preview_connection(left, right)
	level.connection_input_controller.enter_placement_mode()
	level.connection_input_controller.select_endpoint(left)
	_check(level.connection_input_controller.select_endpoint(right), "L submits an actual cross-network bypass")
	for _frame: int in range(4000):
		await _frames(1)
		if level.network_system.has_direct_connection(left, right):
			break
	_check(level.network_system.has_direct_connection(left, right), "Paid bypass connects original endpoints")
	evidence["bypass_quote"] = quote.get("total_cost", 0)
	await _frames(2400)
	_check(level.mother_core.health > 0, "Mother core survives the playable process")
	_check(first_imbalance.is_empty(), "Income, inventory, spend, transit and loss balance throughout the process")
	for edge: HyphaEdge in level.network_system.get_registered_edges():
		if edge.has_endpoints():
			_check(level.terrain_navigation.is_segment_clear(edge.start_node.global_position, edge.end_node.global_position),
				"Actual hypha and logistics segments never cross rock")
	evidence["final"] = level.get_frontier_snapshot()
	evidence["blocked_packet_seen"] = blocked_seen
	level.queue_free()
	await _frames(3, false)
	print("STAGE9_PLAYTHROUGH_RESULT ", JSON.stringify({"checks": checks, "failures": failures,
		"samples": samples, "first_imbalance": first_imbalance, "evidence": evidence,
		"clock": "unmodified physics/production timers; no injected resources or damage"}))
	quit(0 if failures.is_empty() else 1)

func _grow(point: Vector2) -> void:
	level.growth_input_controller.enter_placement_mode()
	var quote: Dictionary = level.growth_input_controller.preview_at(point)
	_check(bool(quote.get("valid", false)), "Growth preview finds a reachable detour")
	_check(level.growth_input_controller.place_target(point), "G accepts its current preview")
	for _frame: int in range(4500):
		await _frames(1)
		if _node_at(point) != null:
			break
	_check(_node_at(point) != null, "Actual paid growth reaches quoted target")
	var requests: Array[Dictionary] = level.construction_coordinator.get_all_requests()
	for request: Dictionary in requests:
		if request.get("parameters", {}).get("target_position") == point:
			var worker: ConstructionWorker = level.construction_coordinator.get_worker(String(request["construction_id"]))
			if worker != null:
				_check(int(worker.growth_system.get_resource_snapshot()["consumed_nutrition"]) == int(quote["plan"]["total_cost"]),
					"Built route spends exactly the preview's routed-length quote")

func _repair(target: Node2D) -> void:
	var task: int = level.repair_system.request_repair(target)
	_check(task > 0, "Damaged object accepts existing paid repair operation")
	for _frame: int in range(3200):
		await _frames(1)
		if not level.repair_system.has_active_task():
			break
	_check(float(target.get("health")) > 0.0, "Real supplied repair revives damaged tissue")

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
			samples += 1
			if samples % 30 == 0:
				var snapshot: Dictionary = level.get_combat_resource_snapshot()
				if snapshot.get("valid", false) and not snapshot.get("balanced", false) and first_imbalance.is_empty():
					first_imbalance = snapshot
				for node: Node in level.get_node("World").find_children("*", "", true, false):
					if node is NutrientPacket or node is RemainsPacket:
						blocked_seen = blocked_seen or node.get_transport_snapshot().get("state") in [&"blocked", &"waiting"]

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)
