extends SceneTree
## 两种推进顺序的正常资源试玩：真实培育、修复、分化与射击，无伤害或营养注入。

const LEVEL: PackedScene = preload("res://scenes/levels/second_level.tscn")
const POINTS: Dictionary = {&"left": Vector2(330, 440), &"center": Vector2(600, 350), &"right": Vector2(930, 410)}

# 功能测试另行验证工具坞；长局规则试玩只省略显示刷新，不改动任何玩法处理。
class QuietSecondLevel:
	extends SecondLevel
	func _refresh_second_hud() -> void:
		pass

var failures: Array[String] = []
var _active_level: SecondLevel
var _next_maintenance: float = 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _play([&"left", &"center", &"right"])
	await _play([&"right", &"center", &"left"])
	print("SECOND_LEVEL_PLAYTHROUGH_RESULT ", JSON.stringify({"failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _frames(count: int) -> void:
	for _index: int in range(count):
		await physics_frame
		await process_frame
		if is_instance_valid(_active_level) and _active_level.elapsed_seconds >= _next_maintenance:
			_next_maintenance = _active_level.elapsed_seconds + 0.5
			_maintain_network()


func _play(order: Array[StringName]) -> void:
	var level := LEVEL.instantiate() as SecondLevel
	var weapon_profile: WeaponProfile = level.normal_weapon_profile
	level.set_script(QuietSecondLevel)
	level.normal_weapon_profile = weapon_profile
	root.add_child(level)
	_active_level = level
	_next_maintenance = 0.5
	await _frames(4)
	print("SECOND_LEVEL_ROUTE_START ", order)
	for id: StringName in order:
		if not level.get_result_snapshot().is_empty(): break
		level.choose_organ(&"attack")
		# 自动选敌优先保护前沿，空闲射击设施；优先目标按钮由独立功能测试覆盖。
		var support: Vector2 = Vector2(355, 535) if id == &"left" else (
			Vector2(820, 535) if id == &"right" else (Vector2(445, 355) if order[0] == &"left" else Vector2(790, 385)))
		var firing_point: Vector2 = POINTS[id] if id != &"center" else (
			Vector2(550, 340) if order[0] == &"left" else Vector2(650, 340))
		if not await _build(level, support) or not await _build(level, firing_point):
			failures.append("route %s could not build protected route to %s" % [order, id])
			break
		var destroyed: bool = false
		var wait_started: float = level.elapsed_seconds
		var next_log: float = wait_started + 30
		for frame: int in range(18000):
			if level.wave_flow.destroyed_ids.has(id):
				destroyed = true
				break
			if not level.get_result_snapshot().is_empty(): break
			if level.elapsed_seconds >= wait_started + 300: break
			if level.elapsed_seconds >= next_log:
				next_log += 30
				print("SECOND_LEVEL_ROUTE_WAIT ", id, " time=", level.elapsed_seconds,
					" core=", level.mother_core.health, " capital=", level.mother_core.nutrition,
					" recovered=", level.colony_progress.get_total_recovered(),
					" facilities=", level.get_facility_targets().map(func(ai: AIFacility) -> int: return ai.health))
			await _frames(1)
		print("SECOND_LEVEL_OBJECTIVE ", id, " destroyed=", destroyed, " time=", level.elapsed_seconds,
			" core=", level.mother_core.health, " capital=", level.mother_core.nutrition)
		if not destroyed:
			failures.append("route %s failed at %s" % [order, id])
			break
	await _frames(4)
	var result: Dictionary = level.get_result_snapshot()
	var ledger: Dictionary = result.get("resources", level.get_combat_resource_snapshot())
	if not bool(result.get("victory", false)):
		failures.append("route %s did not win" % [order])
	if not bool(ledger.get("balanced", false)):
		failures.append("route %s resource ledger diverged" % [order])
	print("SECOND_LEVEL_ROUTE_RESULT ", JSON.stringify({"order": order, "result": result,
		"production": level.wave_flow.get_snapshot(), "ledger": ledger}))
	_active_level = null
	level.queue_free()
	await _frames(4)


func _build(level: SecondLevel, point: Vector2, retry: int = 0) -> bool:
	var controller: CultivationInputController = level.cultivation_input_controller
	controller.enter_remote_placement_mode()
	var preview: Dictionary = controller.preview_remote_at(point)
	print("SECOND_LEVEL_BUILD ", point, " valid=", preview.get("valid"), " cost=", preview.get("total_cost"),
		" reason=", preview.get("error"), " capital=", level.mother_core.nutrition)
	if not controller.place_remote_target(point): return false
	var construction_id: String = String(level.construction_coordinator.get_snapshot().get("selected_id", ""))
	var build_started: float = level.elapsed_seconds
	for frame: int in range(3600):
		if not level.get_result_snapshot().is_empty(): return false
		if level.elapsed_seconds >= build_started + 60: break
		for weapon: SporeWeapon in level.get_weapons():
			if weapon.get_parent().global_position.distance_to(point) < 2.0:
				print("SECOND_LEVEL_ORGAN_READY ", point, " time=", level.elapsed_seconds)
				return true
		var request: Dictionary = level.construction_coordinator.get_request(construction_id)
		if request.get("state") in [&"failed", &"cancelled"]:
			print("SECOND_LEVEL_REBUILD ", point, " reason=", request.get("wait_reason"))
			return await _build(level, point, retry + 1) if retry < 2 else false
		await _frames(1)
	print("SECOND_LEVEL_BUILD_TIMEOUT ", point, " queue=", level.construction_coordinator.get_snapshot())
	return false


func _maintain_network() -> void:
	if not is_instance_valid(_active_level) or not _active_level.get_result_snapshot().is_empty():
		return
	_specialize_support()
	if _active_level.repair_system.has_active_task(): return
	var chosen: Node2D
	var ratio: float = 0.85
	for tissue: Node in get_nodes_in_group("colony_tissues"):
		if not _active_level.is_ancestor_of(tissue) or tissue is MotherCore or tissue.is_queued_for_deletion():
			continue
		var preview: Dictionary = _active_level.repair_system.preview_repair(tissue as Node2D)
		if not preview.get("valid", false) or not preview.get("supply_reachable", false) \
				or float(preview.get("missing_health", 0)) < 10:
			continue
		var health_ratio: float = float(preview.health) / maxf(1.0, float(preview.max_health))
		if health_ratio < ratio:
			ratio = health_ratio
			chosen = tissue as Node2D
	if chosen != null:
		_active_level.repair_system.request_repair(chosen)


func _specialize_support() -> void:
	if _active_level.differentiation_system.has_active_task() \
			or not _active_level.colony_capabilities.can_differentiate_attack_organs():
		return
	for weapon: SporeWeapon in _active_level.get_weapons():
		if weapon.get_weapon_profile().damage_type != WeaponProfile.DamageType.NORMAL:
			continue
		var point: Vector2 = weapon.get_parent().global_position
		var supporting: bool = false
		for support: Vector2 in [Vector2(355, 535), Vector2(820, 535), Vector2(445, 355), Vector2(790, 385)]:
			if point.distance_to(support) < 2.0: supporting = true
		if supporting:
			var input: DifferentiationInputController = _active_level.differentiation_input_controller
			input.select_node(weapon.get_parent() as HyphaNode)
			input.request_start(WeaponProfile.DamageType.SCATTER)
			return
