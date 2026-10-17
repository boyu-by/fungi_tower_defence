extends SceneTree
## 正常资源与规则的顺序、双线探索；只省略HUD刷新，不注入养分、伤害或免费成长。

const LEVEL: PackedScene = preload("res://scenes/levels/third_level.tscn")
const ROUTES: Dictionary = {
	&"first_creation": [Vector2(350, 395), Vector2(270, 315)],
	&"persistence": [Vector2(765, 460), Vector2(870, 390), Vector2(930, 310)],
	&"own_choice": [Vector2(790, 660), Vector2(875, 670), Vector2(955, 695)],
}

class QuietThirdLevel:
	extends ThirdLevel
	func _refresh_third_hud() -> void:
		pass

var failures: Array[String] = []
var records: Array[Dictionary] = []
var _level: ThirdLevel
var _next_maintenance: float = 0
var _first_recovery: float = -1
var _requests: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _play([&"first_creation", &"persistence", &"own_choice"], false)
	await _play([&"own_choice", &"persistence", &"first_creation"], true)
	print("THIRD_LEVEL_PLAYTHROUGH_RESULT ", JSON.stringify({"failures": failures, "routes": records}))
	quit(0 if failures.is_empty() else 1)


func _tick() -> void:
	await physics_frame
	await process_frame
	if not is_instance_valid(_level): return
	if _first_recovery < 0 and _level.colony_progress.get_total_recovered() > 0:
		_first_recovery = _level.elapsed_seconds
	if _level.elapsed_seconds >= _next_maintenance and _level.get_result_snapshot().is_empty():
		_next_maintenance = _level.elapsed_seconds + 0.5
		_maintain()


func _play(order: Array[StringName], parallel: bool) -> void:
	_level = LEVEL.instantiate() as ThirdLevel
	var profile: WeaponProfile = _level.normal_weapon_profile
	_level.set_script(QuietThirdLevel)
	_level.normal_weapon_profile = profile
	root.add_child(_level)
	_next_maintenance = 0.5
	_first_recovery = -1
	_requests.clear()
	for _frame: int in range(4): await _tick()
	_level.construction_coordinator.request_finished.connect(func(id: String, state: StringName) -> void:
		var request: Dictionary = _level.construction_coordinator.get_request(id)
		print("THIRD_LEVEL_CONSTRUCTION_FINISHED ", id, " state=", state,
			" point=", request.get("parameters", {}).get("target_position"), " reason=", request.get("wait_reason")))
	_level.choose_organ(&"attack")
	var history: Array[Dictionary] = []
	_level.fragment_collection.fragment_collected.connect(func(id: StringName, _text: String) -> void:
		history.append({"id": id, "time": _level.elapsed_seconds,
			"core_health": _level.mother_core.health, "nutrition": _level.mother_core.nutrition})
		print("THIRD_LEVEL_FRAGMENT ", JSON.stringify(history.back())))
	print("THIRD_LEVEL_ROUTE_START ", order, " parallel=", parallel)
	if parallel:
		# 同时提交两个不同方向的正常任务，保留系统原有尖端与队列限制。
		for id: StringName in [order[0], order[1]]:
			if not _submit(ROUTES[id][0]): break
		for id: StringName in order:
			if not await _build_route(id, id != order[2]): break
	else:
		for id: StringName in order:
			if not await _build_route(id, false): break
	for _frame: int in range(5): await _tick()
	var result: Dictionary = _level.get_result_snapshot()
	if not bool(result.get("victory", false)):
		failures.append("route %s parallel=%s did not win" % [order, parallel])
	var ledger: Dictionary = result.get("resources", _level.get_combat_resource_snapshot())
	if not bool(ledger.get("balanced", false)):
		failures.append("route %s ledger diverged" % [order])
	var record := {"order": order, "parallel": parallel, "first_recovery": _first_recovery,
		"objectives": history, "result": result, "production": _level.wave_flow.get_snapshot()}
	records.append(record)
	print("THIRD_LEVEL_ROUTE_RESULT ", JSON.stringify(record))
	_level.queue_free()
	_level = null
	for _frame: int in range(5): await _tick()


func _submit(point: Vector2) -> bool:
	var input: CultivationInputController = _level.cultivation_input_controller
	_level.choose_organ(&"attack")
	# 已形成的菌结仍保留时，通过真实C培育重建，不重复放置重叠的远处目标。
	for node: Node2D in _level.network_system.get_registered_nodes():
		if node is HyphaNode and node.is_functional() and point.distance_to(node.global_position) < 24:
			input.exit_remote_placement_mode()
			input.select_node(node)
			var local_accepted: bool = input.request_cultivation()
			if local_accepted:
				_requests[point] = String(_level.construction_coordinator.get_snapshot().get("selected_id", ""))
			print("THIRD_LEVEL_LOCAL_REBUILD ", point, " accepted=", local_accepted)
			return local_accepted
	input.enter_remote_placement_mode()
	var preview: Dictionary = input.preview_remote_at(point)
	var accepted: bool = input.place_remote_target(point)
	if accepted:
		_requests[point] = String(_level.construction_coordinator.get_snapshot().get("selected_id", ""))
	print("THIRD_LEVEL_BUILD ", point, " accepted=", accepted, " cost=", preview.get("total_cost"),
		" reason=", preview.get("error"), " nutrition=", _level.mother_core.nutrition)
	return accepted


func _build_route(id: StringName, already_submitted: bool) -> bool:
	for index: int in range(ROUTES[id].size()):
		var point: Vector2 = ROUTES[id][index]
		if (index != 0 or not already_submitted) and not _submit(point):
			failures.append("could not submit %s" % point)
			return false
		var start: float = _level.elapsed_seconds
		var ready: bool = false
		var retries: int = 0
		while _level.elapsed_seconds - start < 70 and _level.get_result_snapshot().is_empty():
			for weapon: SporeWeapon in _level.get_weapons():
				if weapon.get_parent().global_position.distance_to(point) < 2:
					ready = true
			if ready: break
			var request: Dictionary = _level.construction_coordinator.get_request(_requests.get(point, ""))
			if request.get("state") in [&"failed", &"cancelled"]:
				print("THIRD_LEVEL_REBUILD ", point, " state=", request.state)
				if retries >= 2 or not _submit(point): break
				retries += 1
			await _tick()
		print("THIRD_LEVEL_BUILD_READY ", point, " ready=", ready, " time=", _level.elapsed_seconds)
		if _level.fragment_collection.collected_ids.has(id):
			return true
		if not ready:
			print("THIRD_LEVEL_BUILD_FAILURE ", _level.construction_coordinator.get_snapshot(),
				" tissue_losses=", _level.network_break_count,
				" weapons=", _level.get_weapons().map(func(w: SporeWeapon) -> Vector2: return w.get_parent().global_position))
			failures.append("route %s build not ready at %s" % [id, point])
			return false
		if id == &"own_choice" and index == 0 and not await _prepare_lower_front(point):
			failures.append("lower forward armor-piercing differentiation could not complete")
			return false
	var started: float = _level.elapsed_seconds
	while not _level.fragment_collection.collected_ids.has(id) and _level.get_result_snapshot().is_empty() \
			and _level.elapsed_seconds - started < 60:
		await _tick()
	return _level.fragment_collection.collected_ids.has(id)


func _prepare_lower_front(point: Vector2) -> bool:
	var start: float = _level.elapsed_seconds
	while _level.elapsed_seconds - start < 35 and _level.get_result_snapshot().is_empty():
		for weapon: SporeWeapon in _level.get_weapons():
			if weapon.get_parent().global_position.distance_to(point) >= 2: continue
			if weapon.get_weapon_profile().damage_type == WeaponProfile.DamageType.ARMOR_PIERCING:
				print("THIRD_LEVEL_FORWARD_ARMOR_READY time=", _level.elapsed_seconds)
				return true
			if not _level.differentiation_system.has_active_task() and _level.colony_capabilities.can_differentiate_attack_organs():
				_level.differentiation_input_controller.select_node(weapon.get_parent() as HyphaNode)
				_level.differentiation_input_controller.request_start(WeaponProfile.DamageType.ARMOR_PIERCING)
		await _tick()
	return false


func _maintain() -> void:
	if not _level.repair_system.has_active_task():
		var chosen: Node2D
		var ratio: float = 0.8
		for tissue: Node in get_nodes_in_group("colony_tissues"):
			if not _level.is_ancestor_of(tissue) or tissue is MotherCore or tissue.is_queued_for_deletion(): continue
			var preview: Dictionary = _level.repair_system.preview_repair(tissue as Node2D)
			if not preview.get("valid", false) or not preview.get("supply_reachable", false) \
					or float(preview.get("missing_health", 0)) < 10: continue
			var health_ratio: float = float(preview.health) / maxf(1, float(preview.max_health))
			if health_ratio < ratio:
				ratio = health_ratio
				chosen = tissue as Node2D
		if chosen != null: _level.repair_system.request_repair(chosen)
	if _level.differentiation_system.has_active_task() or not _level.colony_capabilities.can_differentiate_attack_organs(): return
	for weapon: SporeWeapon in _level.get_weapons():
		if weapon.get_weapon_profile().damage_type != WeaponProfile.DamageType.NORMAL: continue
		var point: Vector2 = weapon.get_parent().global_position
		if point.distance_to(Vector2(680, 510)) < 2 or point.distance_to(Vector2(700, 640)) < 2:
			_level.differentiation_input_controller.select_node(weapon.get_parent() as HyphaNode)
			_level.differentiation_input_controller.request_start(WeaponProfile.DamageType.ARMOR_PIERCING \
				if point.distance_to(Vector2(700, 640)) < 2 else WeaponProfile.DamageType.SCATTER)
			return
