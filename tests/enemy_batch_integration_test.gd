extends SceneTree
## 8.5 正式接线验收：测试夹具选择预设，不改默认关卡或建立连续六波。
## 明示配套武器夹具隔离生成验收；敌人移动、生成间隔、资本和供养实际运行。
## 配置指定不是付费分化，也不要求旧100射程关卡能处理所有新重甲。

const LEVEL: PackedScene = preload("res://scenes/levels/level_01.tscn")
const PIERCING: WeaponProfile = preload("res://resources/weapons/armor_piercing_spore.tres")
const SCATTER: WeaponProfile = preload("res://resources/weapons/scatter_spore.tres")
const PRESETS: Array[String] = [
	"res://scenes/systems/swarm_enemy_batch.tscn",
	"res://scenes/systems/armored_enemy_batch.tscn",
	"res://scenes/systems/mixed_enemy_batch.tscn",
]
const TYPES: Array[PackedScene] = [
	preload("res://scenes/enemies/basic_enemy.tscn"),
	preload("res://scenes/enemies/swarm_enemy.tscn"),
	preload("res://scenes/enemies/armored_enemy.tscn"),
]

var checks: int = 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	root.physics_object_picking = true
	await _run_preset(PRESETS[0], [0, 3, 0])
	await _run_preset(PRESETS[1], [0, 0, 1])
	await _run_preset(PRESETS[2], [2, 3, 1])
	await _restart_during_group()
	await _core_death_during_group()
	if OS.get_cmdline_user_args().has("--visual"):
		await _capture_archetypes()
	_check(root.get_child_count() == 0, "Integration disposes all formal scenes and gallery nodes")
	print("ENEMY_BATCH_INTEGRATION_TEST_RESULT ", JSON.stringify({"checks": checks,
		"failures": failures, "evidence": evidence, "default_level_replaced": false,
		"weapon_fixture": "explicit matched presets: scatter for swarm, piercing for armor, mixed left piercing/right scatter; real finite capital and supply, not paid differentiation",
		"clock": "original fixed60 timers"}))
	quit(0 if failures.is_empty() else 1)


func _new_level(preset_path: String) -> Node2D:
	var preset: EnemySpawner = (load(preset_path) as PackedScene).instantiate() as EnemySpawner
	var level: Node2D = LEVEL.instantiate() as Node2D
	level.set("expansion_demo_enabled", false)
	level.set("carcass_demo_enabled", false)
	var spawner: EnemySpawner = level.get_node("Systems/EnemySpawner") as EnemySpawner
	spawner.spawn_entries.clear()
	for entry: EnemySpawnEntry in preset.spawn_entries:
		spawner.spawn_entries.append(entry.copy_for_instance())
	preset.free()
	for host_name: String in ["HyphaNode", "RightNode"]:
		var weapon: SporeWeapon = level.get_node("World/Colony/Nodes/" + host_name + "/SporeWeapon")
		var profile: WeaponProfile = SCATTER if preset_path == PRESETS[0] \
			or (preset_path == PRESETS[2] and host_name == "RightNode") else PIERCING
		_check(weapon.configure_profile(profile), "Explicit test-only matched profile isolates batch completion")
	root.add_child(level)
	current_scene = level
	await _frames(2)
	return level


func _run_preset(path: String, expected: Array) -> void:
	var level: Node2D = await _new_level(path)
	var spawner: EnemySpawner = level.get_node("Systems/EnemySpawner") as EnemySpawner
	var core: MotherCore = level.get_node("World/Colony/MotherCore") as MotherCore
	var total: int = int(expected[0]) + int(expected[1]) + int(expected[2])
	var observed: Dictionary = {"types": [0, 0, 0], "finished": 0, "legacy_finished": 0, "spawn_ids": {}}
	spawner.enemy_spawned.connect(func(enemy: BasicEnemy, spawn_id: String, batch_id: String) -> void:
		_check(not observed.spawn_ids.has(spawn_id) and not batch_id.is_empty(), "Every real spawn has a unique identity")
		observed.spawn_ids[spawn_id] = true
		observed.types[enemy.get_archetype()] += 1)
	spawner.batch_finished.connect(func(_id: String) -> void: observed.finished += 1)
	spawner.wave_finished.connect(func() -> void: observed.legacy_finished += 1)
	_check(spawner.get_planned_count() == total and spawner.spawned_count == 0,
		"Preset preview exposes its actual total before the original start delay")
	var hud: ColonyHUD = level.get_node("HUD") as ColonyHUD
	_check(hud.battle_label.text.contains("0/%d" % total), "Formal HUD displays the configured total")
	for _frame: int in range(6000):
		await _step()
		if observed.finished > 0 or core.health <= 0:
			break
	var snapshot: Dictionary = spawner.get_batch_snapshot()
	_check(observed.types == expected and spawner.spawned_count == total
		and spawner.defeated_count == total and spawner.get_active_count() == 0,
		"Controlled real combat defeats every actual preset member of the expected types")
	_check(snapshot.state == &"completed" and observed.finished == 1 and observed.legacy_finished == 1,
		"Formal preset finishes and reports victory exactly once only after clearing its actors")
	_check(core.health > 0 and spawner.start_timer.is_stopped() and spawner.spawn_timer.is_stopped(),
		"Completed batch has no timer able to silently start another batch")
	await _frames(200)
	_check(spawner.spawned_count == total and observed.finished == 1 and observed.legacy_finished == 1,
		"Waiting after completion creates no extra wave or completion")
	evidence.append({"preset": path, "planned": total, "types": observed.types,
		"spawned": spawner.spawned_count, "defeated": spawner.defeated_count,
		"core_health": core.health, "combat": level.call("get_combat_statistics"),
		"batch_id": snapshot.batch_id})
	await _dispose(level)


func _restart_during_group() -> void:
	var level: Node2D = await _new_level(PRESETS[0])
	var spawner: EnemySpawner = level.get_node("Systems/EnemySpawner") as EnemySpawner
	for _frame: int in range(250):
		await _step()
		if spawner.spawned_count == 1:
			break
	_check(spawner.spawned_count == 1 and not spawner.spawn_timer.is_stopped(),
		"Real R is exercised between the first and second member of a group")
	var stale: Array[Callable] = []
	for binding: Dictionary in spawner.spawn_timer.timeout.get_connections():
		stale.append(binding.callable)
	var captured: Dictionary = {"old_batch": spawner.get_batch_snapshot().batch_id,
		"stopped": false, "spawned_at_stop": -1, "replayed": 0, "extra_spawns": 0}
	spawner.batch_stopped.connect(func(_id: String, reason: StringName) -> void:
		if reason != &"restart":
			return
		captured.stopped = true
		captured.spawned_at_stop = spawner.spawned_count
		for callback: Callable in stale:
			if callback.is_valid():
				callback.call()
				captured.replayed += 1
		captured.extra_spawns = spawner.spawned_count - int(captured.spawned_at_stop))
	_press(KEY_R)
	await _frames(5)
	_check(not is_instance_valid(level) and current_scene != null, "R destroys the old configured scene")
	_check(captured.stopped and captured.replayed > 0 and captured.extra_spawns == 0,
		"R closes the old batch before stale member timeouts are replayed")
	if current_scene != null:
		var fresh: Node2D = current_scene as Node2D
		var fresh_spawner: EnemySpawner = fresh.get_node("Systems/EnemySpawner") as EnemySpawner
		_check(fresh_spawner.spawn_entries.is_empty() and fresh_spawner.get_planned_count() == 6
			and fresh_spawner.spawned_count == 0 and fresh_spawner.defeated_count == 0
			and fresh_spawner.get_active_count() == 0,
			"Reload restores the unchanged legacy six-normal configuration and empty counters")
		fresh_spawner.start_wave()
		_check(fresh_spawner.spawned_count == 1
			and fresh_spawner.get_batch_snapshot().batch_id != captured.old_batch,
			"New scene starts under a distinct batch identity")
		await _dispose(fresh)
	evidence.append({"case": "actual_R_mid_group", "audit": captured})


func _core_death_during_group() -> void:
	var level: Node2D = await _new_level(PRESETS[0])
	var spawner: EnemySpawner = level.get_node("Systems/EnemySpawner") as EnemySpawner
	spawner.start_wave()
	var before: int = spawner.spawned_count
	var core: MotherCore = level.get_node("World/Colony/MotherCore") as MotherCore
	core.take_damage(core.health)
	await _frames(200)
	_check(spawner.get_batch_snapshot().state == &"stopped" and spawner.spawned_count == before
		and spawner.start_timer.is_stopped() and spawner.spawn_timer.is_stopped(),
		"Formal core-death lifecycle stops the rest of a grouped spawn")
	await _dispose(level)


func _capture_archetypes() -> void:
	# 这是只看形态的静止图鉴，三个真实场景未设置mother_core；不作为伤害实测。
	var gallery: Node2D = Node2D.new()
	root.add_child(gallery)
	var background: ColorRect = ColorRect.new()
	background.color = Color("17221e")
	background.size = Vector2(1200, 800)
	gallery.add_child(background)
	var font: SystemFont = SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC"])
	var title: Label = Label.new()
	title.text = "8.5 普通 / 小型群体 / 重甲"
	title.position = Vector2(300, 120)
	title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 28)
	gallery.add_child(title)
	var labels: Array[String] = ["普通", "小型群体", "重甲"]
	for index: int in range(TYPES.size()):
		var enemy: BasicEnemy = TYPES[index].instantiate() as BasicEnemy
		gallery.add_child(enemy)
		enemy.position = Vector2(260 + index * 340, 365)
		var label: Label = Label.new()
		label.position = Vector2(160 + index * 340, 400)
		label.text = "%s\n生命 %d · 护甲 %d\n速度 %.0f · 接触伤害 %d\n攻击间隔 %.1f 秒 · 尸体 %d 营养" % [
			labels[index], enemy.max_health, enemy.armor, enemy.move_speed, enemy.attack_damage,
			enemy.attack_timer.wait_time, enemy.remains_nutrition]
		label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", 18)
		gallery.add_child(label)
	await _frames(3)
	RenderingServer.force_draw(false)
	var path: String = "/private/tmp/fungi_stage8_round5/enemy_archetypes.png"
	_check(root.get_texture().get_image().save_png(path) == OK, "Three-archetype graphical evidence saved")
	gallery.queue_free()
	await _frames(2)


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate() as InputEventKey
	event.pressed = false
	root.push_input(event, true)


func _dispose(level: Node) -> void:
	current_scene = null
	level.queue_free()
	await _frames(3)


func _step() -> void:
	await physics_frame
	await process_frame


func _frames(count: int) -> void:
	for _frame: int in range(count):
		await _step()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
		push_error(message)
