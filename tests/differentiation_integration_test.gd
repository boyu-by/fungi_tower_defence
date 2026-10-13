extends SceneTree
## 正式演示的真实输入与时钟：原六敌、原尸骸、原速度、回收满160后付费分化。
## 不注入成长/余额/材料。完成后才增加一个明示静止护甲靶，验证新射击。

const DEMO: PackedScene = preload("res://scenes/levels/progression_demo.tscn")
const ENEMY: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
const VISUAL_DIR: String = "/private/tmp/fungi_stage8_round4/visual"

var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {}
var level: Node2D
var core: MotherCore
var progress: ColonyProgress
var system: DifferentiationSystem
var supply: DifferentiationSupplySystem
var panel: DifferentiationInputController
var organ: AttackOrgan
var weapon: SporeWeapon
var visual: bool = false
var direction: int = WeaponProfile.DamageType.ARMOR_PIERCING
var observed_receipts: Dictionary[String, int] = {}
var completed_count: int = 0
var ceased_rounds: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	visual = OS.get_cmdline_user_args().has("--visual")
	if OS.get_cmdline_user_args().has("--scatter"):
		direction = WeaponProfile.DamageType.SCATTER
	if visual:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DirAccess.make_dir_recursive_absolute(VISUAL_DIR)
	level = DEMO.instantiate() as Node2D
	root.add_child(level)
	current_scene = level
	core = level.get_node("World/Colony/MotherCore") as MotherCore
	progress = level.get_node("Systems/ColonyProgress") as ColonyProgress
	system = level.get_node("Systems/DifferentiationSystem") as DifferentiationSystem
	supply = level.get_node("Systems/DifferentiationSupplySystem") as DifferentiationSupplySystem
	panel = level.get_node("HUD/DifferentiationPanel") as DifferentiationInputController
	organ = level.get_node("World/Colony/Nodes/HyphaNode/AttackOrgan") as AttackOrgan
	weapon = level.get_node("World/Colony/Nodes/HyphaNode/SporeWeapon") as SporeWeapon
	core.digestion_product_arrived.connect(func(id: String, amount: int) -> void:
		_check(not observed_receipts.has(id), "Real return identities are unique")
		observed_receipts[id] = amount)
	system.organ_differentiated.connect(func(_id: int, _organ: AttackOrgan, _direction: int) -> void:
		completed_count += 1)
	weapon.volley_committed.connect(func(_id: String, _cost: int, _count: int) -> void:
		if system.has_active_task() and system.get_task_snapshot().get("organ") == organ:
			ceased_rounds += 1)
	await _frames(4)
	_check(core.nutrition == 72 and progress.get_total_recovered() == 0,
		"Formal run begins with original72 capital and zero recovered income")
	_check(organ.nutrition == 4 and weapon.attack_range == 100.0,
		"Original normal inventory and explicit scene range are retained")
	# 使用原关闭引导按钮，让选中器官的菌盖/硬刺不被旧提示层遮住。
	var guide_toggle: Button = level.get_node("HUD/ProgressionHintPanel/Toggle")
	await _click(guide_toggle.get_global_rect().get_center())
	await _click(Vector2(440, 355))
	_check(panel.get_selected_organ() == organ and panel.get_status().availability == &"stage_locked",
		"Formal map selection exposes the locked differentiation panel")
	await _capture("01_locked")
	# 正常G建设接入东80、西120两处原尸骸；只发送玩家可执行的输入。
	await _click(Vector2(780, 375))
	_press(KEY_G)
	await _frames(2)
	await _click(Vector2(970, 440))
	_press(KEY_ESCAPE)
	await _frames(2)
	await _click(Vector2(440, 355))
	_press(KEY_G)
	await _frames(2)
	await _click(Vector2(180, 450))
	_press(KEY_ESCAPE)
	await _frames(2)
	var coordinator: ConstructionCoordinator = level.get_node("Systems/ConstructionCoordinator")
	_check(coordinator.get_all_requests().size() == 2, "Two real G requests enter the normal construction queue")
	var matured: bool = false
	for frame: int in range(36000):
		await _step()
		if progress.get_total_recovered() >= 160:
			matured = true
			break
		if core.health <= 0:
			break
		if frame % 3600 == 0:
			print("DIFFERENTIATION_FLOW ", JSON.stringify({"frame": frame, "recovered": progress.get_total_recovered(),
				"core": core.nutrition, "construction": coordinator.get_snapshot().get("tip_count", -1)}))
	_check(matured, "Original harvesting, digestion and physical returns naturally reach160")
	if not matured:
		evidence["maturity_failure"] = {"recovered": progress.get_total_recovered(), "health": core.health,
			"requests": coordinator.get_snapshot(), "access": level.call("get_resource_access_snapshot")}
		await _finish()
		return
	var sum_receipts: int = 0
	for amount: int in observed_receipts.values():
		sum_receipts += amount
	_check(sum_receipts == progress.get_total_recovered() and sum_receipts >= 160,
		"Maturity is exactly backed by observed unique real return receipts")
	var spawner: EnemySpawner = level.get_node("Systems/EnemySpawner")
	_check(spawner.spawned_count == 6 and spawner.defeated_count == 6 and core.health == 240,
		"Original six-enemy combat remains active and completes without core damage")
	evidence["maturity"] = {"recovered": progress.get_total_recovered(), "receipts": observed_receipts.size(),
		"spawned": spawner.spawned_count, "defeated": spawner.defeated_count, "core_health": core.health,
		"combat": level.call("get_combat_statistics")}
	await _click(Vector2(440, 355))
	_check(panel.get_selected_organ() == organ and panel.get_status().can_start_piercing,
		"Natural mature capability enables selected normal organ")
	await _capture("02_ready")
	var old_organ_id: int = organ.get_instance_id()
	var old_weapon_id: int = weapon.get_instance_id()
	var stock: int = organ.nutrition
	var incoming: int = organ.incoming_nutrition
	var core_before: int = core.nutrition
	var recovered_before: int = progress.get_total_recovered()
	var tips_before: int = int(coordinator.get_snapshot().tip_limit)
	var requests_before: int = coordinator.get_all_requests().size()
	await _button("PiercingButton" if direction == WeaponProfile.DamageType.ARMOR_PIERCING else "ScatterButton")
	_check(system.has_active_task() and not organ.is_work_enabled() and weapon.fire_timer.is_stopped(),
		"Real button starts a ceasefire without replacing the organ")
	_check(supply.get_dispatch_owner() == level.get_node("Systems/ConstructionSupplyScheduler")
		and not supply.auto_supply and supply.traffic_system == level.get_node("Systems/NetworkTrafficSystem"),
		"Formal differentiation uses the one construction scheduler and shared traffic system")
	_check(coordinator.get_all_requests().size() == requests_before and int(coordinator.get_snapshot().tip_limit) == tips_before,
		"Differentiation consumes neither an external construction slot nor an extension tip")
	var paused: bool = false
	for _frame: int in range(2400):
		await _step()
		var task: Dictionary = system.get_organ_snapshot(organ)
		if not paused and int(task.consumed_nutrition) >= 2 and task.state != &"completed":
			await _button("PauseButton")
			var frozen_time: float = float(system.get_organ_snapshot(organ).effective_time)
			var frozen_cost: int = int(system.get_organ_snapshot(organ).consumed_nutrition)
			await _frames(90)
			_check(system.get_organ_snapshot(organ).state == &"paused"
				and is_equal_approx(float(system.get_organ_snapshot(organ).effective_time), frozen_time)
				and int(system.get_organ_snapshot(organ).consumed_nutrition) == frozen_cost
				and not organ.is_work_enabled(), "UI pause preserves paid progress and real ceasefire")
			await _capture("03_paused")
			await _button("ContinueButton")
			paused = true
		if organ.has_completed_differentiation():
			break
		_check(not organ.is_work_enabled() and organ.get_attack_type() == WeaponProfile.DamageType.NORMAL,
			"Every precompletion sample stays normal and stopped")
	var complete: Dictionary = system.get_organ_snapshot(organ)
	_check(complete.state == &"completed" and completed_count == 1 and paused,
		"One paid task completes exactly once after a real pause and continue")
	if complete.state != &"completed":
		evidence["completion_failure"] = complete
		await _finish()
		return
	_check(int(complete.consumed_nutrition) == 8 and is_equal_approx(float(complete.effective_time), 5.0),
		"Eight actually delivered materials fund exactly five effective seconds")
	_check(organ.get_instance_id() == old_organ_id and weapon.get_instance_id() == old_weapon_id
		and weapon.inventory_owner == organ and organ.nutrition == stock + incoming
		and organ.incoming_nutrition == 0 and ceased_rounds == 0,
		"Same organ and weapon retain all old ammunition with zero rounds during differentiation")
	var records: Array[Dictionary] = supply.get_shipment_records()
	_check(records.size() == 8 and int(supply.get_supply_snapshot().refunded) == 0
		and supply.get_in_transit_nutrition() == 0 and int(complete.buffered_nutrition) == 0,
		"Completed ledger contains exactly eight materials and no refundable residue")
	var tracker: CargoPassageTracker = level.get_node("Systems/CargoPassageTracker")
	for shipment: Dictionary in records:
		_check(shipment.debited and shipment.accepted and shipment.consumed and not shipment.refunded
			and int(shipment.source_id) == core.get_instance_id(), "Each material has its original debit and one irreversible consumption")
		var cargo: Dictionary = tracker.get_cargo_snapshot(String(shipment.cargo_id))
		_check(cargo.get("status") == &"confirmed", "Only consumed material confirms its original actual passage")
	_check(core_before + progress.get_total_recovered() - recovered_before - core.nutrition == 8,
		"Actual core balance plus intervening real income proves an exact8 cost")
	var expected_cost: int = 2 if direction == WeaponProfile.DamageType.ARMOR_PIERCING else 1
	var expected_range: float = 178.0 if direction == WeaponProfile.DamageType.ARMOR_PIERCING else 145.0
	var expected_interval: float = 1.8 if direction == WeaponProfile.DamageType.ARMOR_PIERCING else 0.9
	_check(organ.get_attack_type() == direction
		and weapon.get_nutrition_cost() == expected_cost and weapon.attack_range == expected_range
		and is_equal_approx(weapon.fire_timer.wait_time, expected_interval)
		and weapon.fire_timer.time_left > expected_interval - 0.1,
		"Completion applies the paid direction once and resumes at a full matching cooldown")
	evidence["paid_differentiation"] = {"materials": records.size(), "consumed": complete.consumed_nutrition,
		"effective_seconds": complete.effective_time, "stock_before": stock, "stock_after": organ.nutrition,
		"incoming_before": incoming, "refund": supply.get_supply_snapshot().refunded,
		"ceased_rounds": ceased_rounds, "same_objects": true, "cooldown_left": weapon.fire_timer.time_left,
		"attack_type": direction}
	await _capture("04_completed")
	await _button("RulesButton")
	await _capture("05_rules")
	await _button("RulesButton")
	await _verify_new_attack()
	await _verify_restart()
	await _finish()


func _verify_new_attack() -> void:
	# 明示隔离验证靶：分化与成熟已由原正式资源完成；不生成新正式敌人批次。
	var target: BasicEnemy = ENEMY.instantiate() as BasicEnemy
	target.max_health = 200
	target.armor = 20
	level.get_node("World/Enemies").add_child(target)
	target.global_position = organ.global_position + Vector2(-120, 0)
	var before: Dictionary = weapon.get_shot_statistics()
	for _frame: int in range(240):
		await _step()
		if target.health < 200:
			break
	var after: Dictionary = weapon.get_shot_statistics()
	var expected_damage: int = 24 if direction == WeaponProfile.DamageType.ARMOR_PIERCING else 1
	var expected_cost: int = 2 if direction == WeaponProfile.DamageType.ARMOR_PIERCING else 1
	_check(target.health == 200 - expected_damage and int(after.rounds) - int(before.rounds) == 1
		and int(after.projectiles) - int(before.projectiles) == 1
		and int(after.nutrition_spent) - int(before.nutrition_spent) == expected_cost,
		"Actual paid behavior launches with its correct nutrition cost and effective armor20 damage")
	evidence["new_attack_fixture"] = {"distance": 120, "armor": 20, "health_lost": 200 - target.health,
		"actual_nutrition": int(after.nutrition_spent) - int(before.nutrition_spent), "formal_extra_wave": false}
	target.queue_free()
	await _frames(2)


func _verify_restart() -> void:
	await _click(Vector2(780, 375))
	await _button("ScatterButton")
	for _frame: int in range(120):
		await _step()
		if supply.get_in_transit_nutrition() > 0:
			break
	_check(system.has_active_task() and supply.get_in_transit_nutrition() > 0,
		"Restart is exercised while another real paid material is in flight")
	var old_system: DifferentiationSystem = system
	var old_core: MotherCore = core
	var refundable_material: int = supply.get_in_transit_nutrition() \
		+ int(system.get_resource_snapshot().buffered_nutrition)
	var refundable_ammunition: int = 0
	for original_organ: AttackOrgan in (level.get_node("Systems/SupplySystem") as SupplySystem).get_registered_organs():
		refundable_ammunition += original_organ.incoming_nutrition
	var restart_audit: Dictionary = {"positive_refunds": 0, "last_balance": old_core.nutrition,
		"stopped_before_refund": true, "refundable_material": refundable_material,
		"refundable_ammunition": refundable_ammunition}
	old_core.nutrition_changed.connect(func(balance: int) -> void:
		if balance > int(restart_audit.last_balance):
			restart_audit.positive_refunds += balance - int(restart_audit.last_balance)
			restart_audit.stopped_before_refund = restart_audit.stopped_before_refund and old_system.is_stopped()
		restart_audit.last_balance = balance)
	_press(KEY_R)
	await _frames(5)
	_check(current_scene != null and current_scene != level, "Real R input replaces the old scene")
	if current_scene == null or current_scene == level:
		return
	level = current_scene as Node2D
	var fresh_system: DifferentiationSystem = level.get_node("Systems/DifferentiationSystem")
	var fresh_supply: DifferentiationSupplySystem = level.get_node("Systems/DifferentiationSupplySystem")
	var fresh_organ: AttackOrgan = level.get_node("World/Colony/Nodes/HyphaNode/AttackOrgan")
	var fresh_core: MotherCore = level.get_node("World/Colony/MotherCore")
	_check(not fresh_system.has_active_task() and fresh_system.get_task_snapshot().state == &"idle"
		and fresh_supply.get_shipment_records().is_empty() and not fresh_organ.has_completed_differentiation()
		and fresh_organ.get_attack_type() == WeaponProfile.DamageType.NORMAL and fresh_core.nutrition == 72,
		"Fresh scene has original inventory, normal profiles and no old tasks or shipment records")
	_check(bool(restart_audit.stopped_before_refund)
		and int(restart_audit.positive_refunds) == refundable_material + refundable_ammunition,
		"Restart closes admission and refunds each paid material/ammunition unit exactly once")
	evidence["restart"] = restart_audit


func _step() -> void:
	await physics_frame
	await process_frame


func _frames(count: int) -> void:
	for _frame: int in range(count):
		await _step()


func _press(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event, true)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	root.push_input(release, true)


func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = true
	root.push_input(event, true)
	await _frames(2)
	var release: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	release.pressed = false
	root.push_input(release, true)
	await _frames(2)


func _button(control_name: String) -> void:
	var button: Button = panel.get_node("%" + control_name) as Button
	_check(button.is_visible_in_tree() and not button.disabled, "UI action available: " + control_name)
	await _click(button.get_global_rect().get_center())


func _capture(label: String) -> void:
	if not visual:
		return
	# macOS 后台/被遮挡窗口可能跳过自然绘帧；主动绘制仅用于截图，不推进游戏时钟。
	await process_frame
	RenderingServer.force_draw(false)
	var screenshot: Image = root.get_texture().get_image()
	var prefix: String = "piercing_" if direction == WeaponProfile.DamageType.ARMOR_PIERCING else "scatter_"
	_check(screenshot.save_png(VISUAL_DIR.path_join(prefix + label + ".png")) == OK,
		"Graphical screenshot saved: " + label)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
		push_error(message)


func _finish() -> void:
	current_scene = null
	if is_instance_valid(level):
		level.queue_free()
	await _frames(3)
	print("DIFFERENTIATION_INTEGRATION_TEST_RESULT ", JSON.stringify({"checks": checks,
		"failures": failures, "evidence": evidence, "visual": visual,
		"synthetic_maturity_or_materials": false, "changed_default_speeds": false,
		"input": "real viewport key and mouse events", "clock": "original fixed60 physics"}))
	quit(0 if failures.is_empty() else 1)
