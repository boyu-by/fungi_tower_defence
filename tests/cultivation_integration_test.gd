extends SceneTree
## 真实关卡验收：生长空菌结、送达付款、至少三秒有效培育、战斗供养和 R 清理。
## 运输、培育与射击均依靠实际场景帧/计时器，不手动推进模型或补充母核余额。

const LEVEL_SCENE: PackedScene = preload("res://scenes/levels/level_01.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")

var checks: int = 0
var failures: Array[String] = []
var milestones: Array[Dictionary] = []
var maturity_result: Dictionary = {}
var continuation_result: Dictionary = {}
var restart_result: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _test_real_maturity_and_combat_supply()
	await _test_paid_cancellation_and_continuation()
	await _test_restart_during_cultivation_transport()
	_check(root.get_child_count() == 0, "Integration teardown leaves no level objects")
	print("CULTIVATION_INTEGRATION_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures, "milestones": milestones,
		"maturity": maturity_result, "continuation": continuation_result, "restart": restart_result,
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _prepare_level(level: Node2D) -> void:
	# 旧单执行器兼容夹具；正式 7.3 多实例路径由 multitip_construction_test 验收。
	level.get_node("Systems/ConstructionCoordinator").multi_worker_enabled = false
	# 隔离测试不引入默认波次、域外四营养尸体或大型尸骸的外部营养收入。
	level.expansion_demo_enabled = false
	level.carcass_demo_enabled = false
	level.get_node("Systems/EnemySpawner").auto_start = false
	level.get_node("Systems/NutritionReturnSystem").auto_return = false


func _prepare_reload_child(child: Node) -> void:
	if child is Node2D and child.scene_file_path == LEVEL_SCENE.resource_path:
		_prepare_level(child as Node2D)


func _new_level() -> Node2D:
	var level: Node2D = LEVEL_SCENE.instantiate() as Node2D
	_prepare_level(level)
	root.add_child(level)
	current_scene = level
	level.enemy_spawner.stop_spawning()
	level.recycling_system.get_node("DispatchTimer").stop()
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()
	await _wait_frames(2)
	_check(level.get_node("World/Remains").get_child_count() == 0,
		"Isolated scene disables both resource fixtures")
	_check(level.get_node("World/Enemies").get_child_count() == 0,
		"Isolated scene disables the normal enemy wave")
	return level


func _remove_level(level: Node2D) -> void:
	level.cultivation_supply_system.reset()
	level.cultivation_system.reset()
	if current_scene == level:
		current_scene = null
	level.queue_free()
	await process_frame
	await process_frame


func _step() -> void:
	await physics_frame
	await process_frame


func _wait_frames(count: int) -> void:
	for _frame: int in range(count):
		await _step()


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event)
	var released: InputEventKey = event.duplicate() as InputEventKey
	released.pressed = false
	root.push_input(released)


func _click(point: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event)
	var released: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	released.pressed = false
	root.push_input(released)

	# 7.2 入队与执行分开；显式推进调度，不伪造运输或注入施工缓存。
	if is_instance_valid(current_scene):
		current_scene.construction_coordinator.pump()


func _select_host(level: Node2D, host: HyphaNode) -> void:
	# 使用菌结的现有选择信号，验证关卡会同时更新普通选择与培育适配器。
	host.selection_requested.emit(host)
	_check(level.selected_node == host and level.cultivation_input_controller.get_selection_status().host == host,
		"Mature-node selection reaches both level and cultivation controller")


func _check_wiring(level: Node2D) -> void:
	_check(level.cultivation_system == level.get_node_or_null("Systems/CultivationSystem"),
		"Base level exposes Systems/CultivationSystem")
	_check(level.cultivation_supply_system == level.get_node_or_null("Systems/CultivationSupplySystem"),
		"Base level exposes Systems/CultivationSupplySystem")
	_check(level.cultivation_input_controller == level.get_node_or_null("Systems/CultivationInputController"),
		"Base level exposes Systems/CultivationInputController")
	_check(level.cultivation_supply_system.packet_container == level.get_node_or_null("World/CultivationPackets"),
		"Cultivation packets use the promised separate World container")
	_check(level.cultivation_system.network_system == level.network_system \
		and level.cultivation_system.growth_system == level.growth_system \
		and level.cultivation_system.enemy_container == level.get_node("World/Enemies") \
		and level.cultivation_system.projectile_container == level.get_node("World/Projectiles"),
		"Cultivation uses the real growth, network and battle references")
	_check(level.cultivation_input_controller.cultivation_system == level.cultivation_system \
		and level.cultivation_input_controller.cultivation_supply_system == level.cultivation_supply_system \
		and level.cultivation_input_controller.growth_system == level.growth_system,
		"Input adapter shares the level's exact build systems")
	_check(level.growth_system.construction_blocker.is_valid() and InputMap.has_action("cultivate_attack"),
		"Growth admission guard and C action are wired on the actual base level")
	_check(level.hud.cultivation_button != null and level.hud.cultivation_reason_label != null,
		"HUD exposes cultivation button and Chinese eligibility label")


func _grow_empty_host(level: Node2D, target: Vector2) -> HyphaNode:
	var before: int = level.hypha_nodes.get_child_count()
	_press(KEY_G)
	_check(level.growth_input_controller.is_placing(), "Real G input opens growth placement")
	_click(target)
	_check(level.growth_system.has_active_task(), "Real placement creates the prerequisite growth task")
	for _frame: int in range(6000):
		if level.growth_system.get_task_snapshot().state == &"completed":
			break
		await _step()
	_check(level.growth_system.get_task_snapshot().state == &"completed",
		"Actual growth packets and time complete the prerequisite empty node")
	var host: HyphaNode = null
	for child: Node in level.hypha_nodes.get_children():
		if child is HyphaNode and child.global_position.is_equal_approx(target):
			host = child as HyphaNode
	_check(host != null and level.hypha_nodes.get_child_count() > before,
		"Paid growth creates a real mature HyphaNode at the target")
	if host == null:
		return null
	_check(host.is_organ_slot_available() and level.network_system.is_connected_to_core(host),
		"Grown host begins with an empty organ slot connected to the core")
	return host


func _attack_children(host: HyphaNode) -> Array[AttackOrgan]:
	var organs: Array[AttackOrgan] = []
	for child: Node in host.get_children():
		if child is AttackOrgan and not child.is_queued_for_deletion():
			organs.append(child as AttackOrgan)
	return organs


func _weapon_children(host: HyphaNode) -> Array[SporeWeapon]:
	var weapons: Array[SporeWeapon] = []
	for child: Node in host.get_children():
		if child is SporeWeapon and not child.is_queued_for_deletion():
			weapons.append(child as SporeWeapon)
	return weapons


func _observe_maturity(level: Node2D, expected_host: HyphaNode) -> Dictionary:
	var evidence: Dictionary = {
		"matured": 0, "shots": 0, "nutrition_spent": 0, "organ": null, "weapon": null,
		"stock_on_maturity": -1, "effective_time": 0.0, "shot_stocks": [],
	}
	level.cultivation_system.organ_matured.connect(
		func(task_id: int, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon) -> void:
			if host != expected_host:
				return
			evidence["matured"] = int(evidence["matured"]) + 1
			evidence["organ"] = organ
			evidence["weapon"] = weapon
			evidence["stock_on_maturity"] = organ.nutrition
			var task: Dictionary = level.cultivation_system.get_task_snapshot(task_id)
			evidence["effective_time"] = float(task["effective_time"])
			_check(task.state == &"completed" and task.structure_consumed == 8 \
				and task.startup_transferred == 4 and task.consumed_nutrition == 12,
				"Maturation commits eight sunk structure and exactly four paid startup nutrition")
			_check(task.effective_time >= 3.0 and task.minimum_time == 3.0,
				"Maturation waits for at least three funded effective seconds")
			_check(organ.nutrition == 4 and organ.incoming_nutrition == 0,
				"Newborn ready consumes the paid startup stock exactly once")
			_check(organ.get_parent() == host and weapon.get_parent() == host \
				and weapon.inventory_owner == organ and weapon.attack_range == 100.0 \
				and weapon.position == Vector2(0, -28),
				"Mature organ and configured weapon are siblings on their original host")
			_check(weapon.enemy_container == level.get_node("World/Enemies") \
				and weapon.projectile_container == level.get_node("World/Projectiles"),
				"New weapon points at the real level battle containers")
			_check(weapon.targeting_required and weapon.targeting_system == level.combat_targeting_system,
				"Actual paid maturation binds the shared targeting ledger before the new weapon fires")
			var timer: Timer = weapon.get_node("FireTimer") as Timer
			timer.stop()
			weapon.volley_committed.connect(func(_shot_id: String, spent: int, _count: int) -> void:
				evidence["shots"] = int(evidence["shots"]) + 1
				evidence["nutrition_spent"] = int(evidence["nutrition_spent"]) + spent
				var stocks: Array = evidence["shot_stocks"]
				stocks.append(organ.nutrition)
				timer.stop()))
	return evidence


func _wait_maturity(level: Node2D, limit: int = 6000) -> void:
	for _frame: int in range(limit):
		if level.cultivation_system.get_task_snapshot().state == &"completed":
			break
		await _step()
	_check(level.cultivation_system.get_task_snapshot().state == &"completed",
		"Real cultivation transport and physics time mature the organ before timeout")


func _accounted(level: Node2D, nutrition_spent: int = 0) -> int:
	var total: int = level.mother_core.nutrition + nutrition_spent
	for organ: AttackOrgan in level.supply_system.get_registered_organs():
		# incoming 是已经付过款的普通供养包，不能再另加普通 packet 数量。
		total += organ.nutrition + organ.incoming_nutrition
	var growth: Dictionary = level.growth_system.get_task_snapshot()
	total += int(growth.get("consumed_nutrition", 0)) + int(growth.get("buffered_nutrition", 0))
	total += level.growth_supply_system.get_in_transit_count()
	var cultivation: Dictionary = level.cultivation_system.get_resource_snapshot()
	total += int(cultivation.get("structure_consumed", 0)) \
		+ int(cultivation.get("buffered_nutrition", 0)) + int(cultivation.get("startup_reserved", 0))
	# startup_transferred 是历史记录，已经包含在成熟器官库存中，不重复相加。
	total += level.cultivation_supply_system.get_in_transit_nutrition()
	return total


func _checkpoint(level: Node2D, phase: String, expected: int, nutrition_spent: int = 0) -> void:
	var total: int = _accounted(level, nutrition_spent)
	milestones.append({"phase": phase, "total": total, "expected": expected, "nutrition_spent": nutrition_spent})
	_check(total == expected, "%s conserves core, paid transit, unique structure, buffer, startup and shots" % phase)


func _spawn_isolated_enemy(level: Node2D, host: HyphaNode) -> BasicEnemy:
	var enemy: BasicEnemy = ENEMY_SCENE.instantiate() as BasicEnemy
	enemy.mother_core = level.mother_core
	enemy.move_speed = 0.0
	# 两次测试射击不触发死亡产出，资源守恒只包含原有营养与射击消耗。
	enemy.max_health = 240
	enemy.position = host.global_position + Vector2(40, 0)
	level.get_node("World/Enemies").add_child(enemy)
	enemy.set_physics_process(false)
	enemy.get_node("AttackTimer").stop()
	return enemy


func _fire_once(weapon: SporeWeapon, evidence: Dictionary) -> void:
	var previous: int = int(evidence["shots"])
	var timer: Timer = weapon.get_node("FireTimer") as Timer
	timer.start(0.05)
	for _frame: int in range(120):
		if int(evidence["shots"]) > previous:
			break
		await _step()
	_check(int(evidence["shots"]) == previous + 1, "Normal FireTimer produces exactly one observed shot")


func _test_real_maturity_and_combat_supply() -> void:
	var level: Node2D = await _new_level()
	_check_wiring(level)
	var initial: int = _accounted(level)
	var host: HyphaNode = await _grow_empty_host(level, Vector2(1080, 400))
	if host == null:
		await _remove_level(level)
		return
	_checkpoint(level, "grown_empty_host", initial)
	var enemy: BasicEnemy = _spawn_isolated_enemy(level, host)
	var evidence: Dictionary = _observe_maturity(level, host)
	_select_host(level, host)
	_press(KEY_G)
	_check(level.growth_input_controller.is_placing(), "Preview may be open before a cultivation request")
	var before: int = level.mother_core.nutrition
	_press(KEY_C)
	var task_id: int = level.cultivation_system.get_task_snapshot().task_id
	_check(task_id > 0 and level.cultivation_system.has_active_task() \
		and not level.growth_input_controller.is_placing(),
		"C creates cultivation and the level closes the old growth preview")
	_check(level.mother_core.nutrition == before, "C creation itself never pays before real dispatch")
	_check(host.get_organ_bud() != null and _attack_children(host).is_empty() \
		and _weapon_children(host).is_empty(), "A cultivation bud starts without combat organ or weapon")
	_check(level.supply_system.get_registered_organs().size() == 2,
		"Normal SupplySystem never registers the pre-mature bud")
	_press(KEY_G)
	_check(level.growth_input_controller.is_placing() \
		and level.growth_system.create_target(host, Vector2(1160, 400)) == 0,
		"G can preview a queued target but direct growth cannot bypass waiting cultivation")
	_press(KEY_ESCAPE)
	# 本地 C 仍在执行时，取消选中的等待外部目标后，重复 X 不得偷偷改控 C。
	var before_queue: int = level.mother_core.nutrition
	var queued: Dictionary = level.construction_coordinator.enqueue(&"growth", {
		"start_node": host, "target_position": Vector2(1160, 400)})
	_check(bool(queued.get("accepted", false)), "Local C permits a separate uncharged waiting external request")
	_press(KEY_X)
	_press(KEY_X)
	_check(level.construction_coordinator.get_request(String(queued["construction_id"])).get("state") == &"cancelled"
		and level.cultivation_system.has_active_task() and level.cultivation_system.get_task_snapshot().task_id == task_id
		and level.mother_core.nutrition == before_queue,
		"Repeated X after cancelling the selected queue entry cannot switch to the previously selected local C or change its funds")
	_check(level.hud.growth_pause_button.disabled and level.hud.growth_cancel_button.disabled,
		"Cleared external focus leaves P/X disabled until a target is explicitly selected again")
	host.selection_requested.emit(host)
	_check(not level.hud.growth_pause_button.disabled and not level.hud.growth_cancel_button.disabled,
		"Explicitly selecting the local host restores its own cultivation controls")
	for _frame: int in range(3000):
		if level.cultivation_supply_system.get_in_transit_count() > 0:
			break
		await _step()
	var waiting: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(level.cultivation_supply_system.get_in_transit_count() > 0 \
		and waiting.structure_consumed == 0 and waiting.effective_time == 0.0,
		"Actual debited transit provides no structure or time before packet arrival")
	_checkpoint(level, "paid_cultivation_transit", initial)
	for _frame: int in range(3000):
		var current: Dictionary = level.cultivation_system.get_task_snapshot()
		if current.structure_consumed > 0:
			break
		await _step()
	var partial: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(partial.structure_consumed > 0 and partial.effective_time < 3.0 \
		and _attack_children(host).is_empty() and _weapon_children(host).is_empty() \
		and int(evidence["shots"]) == 0,
		"Paid partial cultivation cannot shoot at a real in-range enemy before maturity")
	_check(level.supply_system.get_registered_organs().size() == 2 and enemy.is_alive(),
		"Pre-mature cultivation neither joins ordinary supply nor attacks the isolated enemy")
	_checkpoint(level, "partially_paid_bud", initial)
	await _wait_maturity(level)
	_check(int(evidence["matured"]) == 1 and int(evidence["stock_on_maturity"]) == 4,
		"Real cultivation matures once with exactly four paid inventory")
	var organs: Array[AttackOrgan] = _attack_children(host)
	var weapons: Array[SporeWeapon] = _weapon_children(host)
	_check(organs.size() == 1 and weapons.size() == 1 and host.get_organ_slot_state() == &"attack",
		"Host has a unique sibling attack organ and weapon after maturation")
	if organs.size() != 1 or weapons.size() != 1:
		await _remove_level(level)
		return
	var organ: AttackOrgan = organs[0]
	var weapon: SporeWeapon = weapons[0]
	_check(level.mother_core.nutrition == before - 12 \
		and level.cultivation_system.get_total_structure_consumed() == 8,
		"Total cultivation debit is 12, including startup four rather than charging it again")
	_check(level.supply_system.get_registered_organs().has(organ),
		"Level child registration hands the mature organ to ordinary SupplySystem")
	_checkpoint(level, "paid_maturity", initial)
	_press(KEY_C)
	_check(level.cultivation_system.get_task_snapshot().task_id == task_id \
		and _attack_children(host).size() == 1 and _weapon_children(host).size() == 1,
		"Repeated C on the occupied mature host cannot duplicate organs or weapons")
	await _fire_once(weapon, evidence)
	_check(organ.nutrition == 3 and level.mother_core.nutrition == before - 12,
		"First real shot consumes local paid stock without immediate core spending")
	_checkpoint(level, "first_local_shot", initial, int(evidence["nutrition_spent"]))
	await _fire_once(weapon, evidence)
	var stocks: Array = evidence["shot_stocks"]
	_check(stocks.size() == 2 and int(stocks[0]) == 3 and int(stocks[1]) == 2,
		"Two shots debit the existing organ inventory one nutrient each")
	var deliveries_before: int = level.supply_system.delivered_packets
	var saw_normal_transit: bool = organ.incoming_nutrition > 0
	for _frame: int in range(2400):
		saw_normal_transit = saw_normal_transit or organ.incoming_nutrition > 0
		if organ.nutrition >= 3 and level.supply_system.delivered_packets > deliveries_before:
			break
		await _step()
	_check(saw_normal_transit and organ.nutrition >= 3 \
		and level.supply_system.delivered_packets > deliveries_before,
		"Low mature inventory triggers actual normal supply dispatch and packet arrival")
	_check(level.cultivation_supply_system.get_in_transit_count() == 0 \
		and level.cultivation_system.get_task_snapshot().state == &"completed",
		"Mature resupply does not reopen cultivation funding")
	_checkpoint(level, "normal_supply_handoff", initial, int(evidence["nutrition_spent"]))
	maturity_result = {
		"growth_cost": int(level.growth_system.get_task_snapshot().consumed_nutrition),
		"cultivation_cost": 12, "structure": 8, "startup": evidence["stock_on_maturity"],
		"effective_time": evidence["effective_time"], "matured": evidence["matured"],
		"shots": evidence["shots"], "normal_deliveries": level.supply_system.delivered_packets,
	}
	await _remove_level(level)


func _test_paid_cancellation_and_continuation() -> void:
	var level: Node2D = await _new_level()
	var initial: int = _accounted(level)
	var host: HyphaNode = await _grow_empty_host(level, Vector2(860, 400))
	if host == null:
		await _remove_level(level)
		return
	_select_host(level, host)
	var balance: int = level.mother_core.nutrition
	var evidence: Dictionary = _observe_maturity(level, host)
	_press(KEY_C)
	for _frame: int in range(3000):
		var current: Dictionary = level.cultivation_system.get_task_snapshot()
		if current.structure_consumed >= 2 and current.effective_time > 0.45:
			break
		await _step()
	var paid: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(paid.structure_consumed > 0 and paid.structure_consumed < 8 \
		and paid.effective_time > 0.45 and paid.effective_time < 3.0,
		"Cancellation fixture reaches a genuinely partial paid structure stage")
	_press(KEY_P)
	_check(level.cultivation_system.get_task_snapshot().state == &"paused" \
		and not paused, "P pauses only cultivation while the real scene continues")
	_press(KEY_G)
	_check(level.growth_input_controller.is_placing() \
		and level.growth_system.create_target(host, Vector2(940, 400)) == 0,
		"Paused cultivation holds the sole execution pipeline while G may preview another target")
	_press(KEY_ESCAPE)
	for _frame: int in range(1800):
		if level.cultivation_supply_system.get_in_transit_count() == 0:
			break
		await _step()
	var frozen: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(frozen.state == &"paused" and is_equal_approx(frozen.effective_time, paid.effective_time) \
		and frozen.structure_consumed == paid.structure_consumed,
		"Already paid packets arrive into frozen buffer without advancing paused structure")
	_check(frozen.buffered_nutrition + frozen.startup_reserved > 0 \
		and int(evidence["matured"]) == 0, "Paused task retains refundable delivered funds and never matures")
	_checkpoint(level, "paused_delivered_buffer", initial)
	_press(KEY_X)
	var cancelled: Dictionary = level.cultivation_system.get_task_snapshot(paid.task_id)
	_check(cancelled.state == &"cancelled" and cancelled.buffered_nutrition == 0 \
		and cancelled.startup_reserved == 0 and level.cultivation_supply_system.get_in_transit_count() == 0,
		"X drains both refundable categories and leaves a terminal attempt")
	_check(level.mother_core.nutrition == balance - int(paid.structure_consumed),
		"Actual cancellation refunds all unspent deliveries, never the sunk structure")
	_checkpoint(level, "cancelled_paid_bud", initial)
	_select_host(level, host)
	var selection: Dictionary = level.cultivation_input_controller.get_selection_status()
	_check(selection.can_continue and selection.remaining_cost == 12 - int(paid.structure_consumed) \
		and selection.task.bud_id == paid.bud_id,
		"HUD continuation quotes the selected persistent bud's original remaining cost")
	_press(KEY_C)
	var resumed: Dictionary = level.cultivation_system.get_task_snapshot()
	_check(resumed.task_id > paid.task_id and resumed.bud_id == paid.bud_id \
		and is_equal_approx(resumed.effective_time, paid.effective_time),
		"C continues the same bud on a new attempt while preserving elapsed paid stage")
	_check(not level.cultivation_system.receive_nutrition(paid.task_id, "integration-stale-attempt", 1),
		"Old task identity rejects a stale delivery after continuation")
	await _wait_maturity(level)
	var historic: Dictionary = level.cultivation_system.get_task_snapshot(paid.task_id)
	_check(historic.state == &"cancelled" and historic.structure_consumed == paid.structure_consumed \
		and is_equal_approx(historic.effective_time, paid.effective_time),
		"Historic cancellation snapshots remain independent of the later mature bud")
	_check(level.mother_core.nutrition == balance - 12 \
		and level.cultivation_system.get_total_structure_consumed() == 8 \
		and int(evidence["matured"]) == 1 and _attack_children(host).size() == 1 \
		and _weapon_children(host).size() == 1,
		"Cancel and continue ultimately pay only the original 12 and mature exactly once")
	_checkpoint(level, "continued_maturity", initial)
	continuation_result = {
		"cancelled_task": paid.task_id, "continued_task": resumed.task_id,
		"retained_structure": paid.structure_consumed, "retained_time": paid.effective_time,
		"remaining_cost": selection.remaining_cost, "total_paid": balance - int(level.mother_core.nutrition),
	}
	await _remove_level(level)


func _test_restart_during_cultivation_transport() -> void:
	var level: Node2D = await _new_level()
	var host: HyphaNode = await _grow_empty_host(level, Vector2(860, 400))
	if host == null:
		await _remove_level(level)
		return
	level.cultivation_supply_system.auto_supply = false
	_select_host(level, host)
	var core: MotherCore = level.mother_core
	var balance: int = core.nutrition
	var balance_events: Array[int] = []
	core.nutrition_changed.connect(func(value: int) -> void: balance_events.append(value))
	_press(KEY_C)
	var old_task_id: int = level.cultivation_system.get_task_snapshot().task_id
	_check(level.cultivation_supply_system.try_dispatch() and core.nutrition == balance - 1,
		"R fixture has a real paid cultivation shipment in flight")
	var records: Array[Dictionary] = level.cultivation_supply_system.get_shipment_records()
	var old_packet: NutrientPacket = records.back()["packet"] as NutrientPacket
	var old_callbacks: Array[Callable] = []
	for connection: Dictionary in old_packet.get_signal_connection_list(&"arrived"):
		old_callbacks.append(connection["callable"])
	root.child_entered_tree.connect(_prepare_reload_child)
	_press(KEY_R)
	await _wait_frames(6)
	root.child_entered_tree.disconnect(_prepare_reload_child)
	var restarted: Node2D = current_scene as Node2D
	_check(is_instance_valid(restarted) and restarted != level, "Real R input reloads during cultivation transport")
	if not is_instance_valid(restarted) or restarted == level:
		if is_instance_valid(level):
			await _remove_level(level)
		return
	_check(not balance_events.is_empty() and balance_events.back() == balance,
		"R's supply-first reset refunds the original live source before reloading")
	_check(restarted.cultivation_system.get_task_snapshot().state == &"idle" \
		and not restarted.cultivation_system.has_active_task() \
		and restarted.cultivation_supply_system.get_shipment_records().is_empty() \
		and restarted.cultivation_supply_system.get_in_transit_count() == 0,
		"Reloaded scene has no old cultivation task, shipment or account ledger")
	_check(restarted.get_node("World/CultivationPackets").get_child_count() == 0 \
		and restarted.hypha_nodes.get_child_count() == 3 \
		and restarted.mother_core.nutrition == 72,
		"R removes old buds/packets/grown hosts and restores the exact ordinary initial state")
	var callbacks_retired: bool = true
	for callback: Callable in old_callbacks:
		callbacks_retired = callbacks_retired and not callback.is_valid()
	_check(not is_instance_valid(old_packet) and callbacks_retired,
		"Old packet and its bound callbacks are retired before a new scene can receive them")
	await _wait_frames(90)
	_check(restarted.mother_core.nutrition == 72 \
		and restarted.cultivation_supply_system.get_in_transit_count() == 0 \
		and restarted.cultivation_system.get_task_snapshot().state == &"idle",
		"Late old transport cannot refund, debit or mature anything in the restarted scene")
	restart_result = {"old_task_id": old_task_id, "old_source_refunded_to": balance,
		"new_core": int(restarted.mother_core.nutrition), "callbacks_retired": callbacks_retired}
	await _remove_level(restarted)
