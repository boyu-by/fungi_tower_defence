extends SceneTree
## 主菜单与进度定向验收；胜利只在解锁夹具中注入，不作为关卡通关证据。

const SAVE: String = "res://.artifact_work/menu-integration-progress.cfg"
const STORE_SAVE: String = "res://.artifact_work/menu-store-progress.cfg"
var checks: int = 0
var failures: Array[String] = []
var navigator: CampaignNavigator


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)


func _frames(count: int) -> void:
	for _index: int in range(count):
		await physics_frame
		await process_frame


func _remove_test_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if FileAccess.file_exists(path + ".tmp"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".tmp"))


func _store_checks() -> void:
	_remove_test_file(STORE_SAVE)
	var store := CampaignProgressStore.new(STORE_SAVE)
	_check(not store.load_progress() and not store.get_snapshot().has_save, "missing record starts without continue")
	_check(store.start_new_game() and store.get_snapshot().continue_level == 1, "start persists a first-level checkpoint")
	_check(not store.record_entry(2) and not store.record_victory(3), "unreached levels cannot be entered or unlocked through store")
	_check(store.record_victory(1) and store.get_snapshot().highest_unlocked == 2, "first victory unlocks second")
	_check(store.record_entry(1) and store.get_snapshot().continue_level == 2, "replaying an earlier chapter never regresses title continue progress")
	_check(store.record_victory(1), "duplicate completion is idempotent")
	_check(store.record_entry(2), "second entry persists on an existing record")
	var reload := CampaignProgressStore.new(STORE_SAVE)
	_check(reload.load_progress() and reload.get_snapshot().continue_level == 2, "record survives a fresh store instance")
	_check(reload.record_victory(2) and reload.record_entry(3) and reload.record_victory(3), "all chapters complete through valid transitions")
	_check(reload.get_snapshot().completed and reload.get_snapshot().continue_level == 3, "completion retains replayable final chapter")
	var snapshot: Dictionary = reload.get_snapshot()
	snapshot.highest_unlocked = 99
	_check(reload.get_snapshot().highest_unlocked == 3, "returned progress dictionary is detached")
	var config := ConfigFile.new()
	config.load(STORE_SAVE)
	_check(config.get_section_keys("campaign").size() == 4 and not config.has_section_key("campaign", "nutrition"), "progress stores no in-level resources or network")
	config.set_value("campaign", "continue_level", 99)
	config.save(STORE_SAVE)
	_check(not reload.load_progress() and not reload.get_snapshot().has_save and not reload.last_error.is_empty(), "corrupt chapter indices disable continue safely")
	_check(reload.start_new_game(), "new game can replace an invalid record")
	config.set_value("campaign", "version", 999)
	config.save(STORE_SAVE)
	_check(not reload.load_progress(), "unsupported schema does not unlock chapters")
	var invalid := CampaignProgressStore.new("res://.artifact_work/missing-menu-directory/record.cfg")
	_check(not invalid.start_new_game() and not invalid.get_snapshot().has_save, "failed save does not publish a fabricated checkpoint")
	_remove_test_file(STORE_SAVE)


func _run() -> void:
	_store_checks()
	navigator = CampaignNavigator.ensure(self)
	_remove_test_file(SAVE)
	navigator.progress_store = CampaignProgressStore.new(SAVE)
	_check(String(ProjectSettings.get_setting("application/run/main_scene")) == CampaignNavigator.MENU_SCENE, "application now starts at title")
	change_scene_to_file(CampaignNavigator.MENU_SCENE)
	await _frames(5)
	var menu := current_scene as MainMenu
	_check(menu != null and not paused and menu.continue_button.disabled, "fresh title has disabled continue and no pause residue")
	_check(menu.start_button.text == "开始游戏" and menu.quit_button.text == "退出游戏", "title exposes the planned actions")
	_click(menu.start_button.get_global_rect().get_center())
	_check(not navigator.start_new_game(), "pending scene transitions cannot be duplicated")
	await _frames(5)
	_check(current_scene is FirstLevel and current_scene.mother_core.nutrition == 72, "real start click enters unchanged first level")
	_check(navigator.active_run and navigator.progress_store.get_snapshot().has_save, "main-menu launch owns a persisted campaign session")
	await _pause_and_return()
	menu = current_scene as MainMenu
	_check(not menu.continue_button.disabled, "returning to title enables continue")
	_click(menu.continue_button.get_global_rect().get_center())
	await _frames(5)
	_check(current_scene is FirstLevel and current_scene.mother_core.nutrition == 72, "continue starts chapter fresh without carrying resources")
	await _unlock_second()
	await _second_and_third()
	await _reset_confirmation()
	await _failure_and_restart()
	# 独立F6/回归场景不属于主线会话，不写玩家记录。
	var before: Dictionary = navigator.progress_store.get_snapshot()
	navigator.active_run = false
	change_scene_to_file(CampaignNavigator.LEVEL_SCENES[2])
	await _frames(5)
	_check(navigator.progress_store.get_snapshot() == before, "direct debugging does not overwrite campaign record")
	current_scene.compact_hud.level_menu.result_title_button.pressed.emit()
	await _frames(5)
	_check(current_scene is MainMenu and not paused, "directly run third level can still return to title")
	_remove_test_file(SAVE)
	var quit_seen := [false]
	navigator.quit_requested.connect(func() -> void: quit_seen[0] = true)
	current_scene.quit_button.pressed.emit()
	_check(quit_seen[0], "title exit reaches application quit intent")
	print("MAIN_MENU_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _pause_and_return() -> void:
	var level := current_scene as FirstLevel
	var layer: LevelMenuLayer = level.compact_hud.level_menu
	level.growth_input_controller.enter_placement_mode()
	_check(level.growth_input_controller.place_target(Vector2(330, 395)), "return fixture creates a real paid construction request")
	level.growth_input_controller.exit_placement_mode()
	await _frames(3)
	var old_network: WeakRef = weakref(level.network_system)
	_check(level.compact_hud.goal_label.text.contains("六波"), "first objective is visible in upper-left HUD")
	_click(level.compact_hud.menu_button.get_global_rect().get_center())
	await _frames(3)
	_check(layer.is_open() and paused, "real menu click freezes game with modal menu")
	var clock_before: float = level.elapsed_seconds
	var capital: int = level.mother_core.nutrition
	var id: int = level.get_instance_id()
	_key(KEY_G)
	_key(KEY_B)
	_key(KEY_R)
	_key(KEY_SPACE)
	await _frames(8)
	_check(layer.is_open() and paused and current_scene.get_instance_id() == id, "Space and restart cannot leak through open menu")
	_check(not level.growth_input_controller.is_placing() and not level.cultivation_input_controller.is_remote_placing(), "menu captures construction shortcuts")
	_check(level.elapsed_seconds == clock_before and level.mother_core.nutrition == capital, "modal menu creates no simulation or payment")
	_click(layer.resume_button.get_global_rect().get_center())
	await _frames(3)
	_check(not layer.is_open() and not paused, "continue restores an originally running world")
	level.pause_controller.set_paused(true)
	layer.open_menu()
	_key(KEY_ESCAPE)
	await _frames(3)
	_check(not layer.is_open() and paused, "closing menu preserves manual planning pause")
	layer.open_menu()
	_click(layer.title_button.get_global_rect().get_center())
	await _frames(5)
	_check(current_scene is MainMenu and not paused, "paused return cleans world and global pause")
	_check(old_network.get_ref() == null, "return retires old network and active construction identities")


func _unlock_second() -> void:
	var first := current_scene as FirstLevel
	# 导航夹具：注入一次已结算的胜利快照，测试不修改六波实现。
	first._result_snapshot = {"victory": true}
	first.level_finished.emit(first._result_snapshot)
	_check(navigator.progress_store.get_snapshot().continue_level == 2, "first completion persists second checkpoint before next button")
	first.compact_hud.level_menu.result_title_button.pressed.emit()
	await _frames(5)
	_check(current_scene.progress_label.text.contains("第二关"), "title identifies the actual continue chapter")
	_click(current_scene.continue_button.get_global_rect().get_center())
	await _frames(5)
	_check(current_scene is SecondLevel and current_scene.mother_core.nutrition == 90, "continue loads second with its own initial capital")


func _second_and_third() -> void:
	var second := current_scene as SecondLevel
	var layer: LevelMenuLayer = second.compact_hud.level_menu
	layer.open_menu()
	var production_clock: float = second.wave_flow.elapsed_seconds
	_key(KEY_R)
	_key(KEY_SPACE)
	await _frames(5)
	_check(current_scene == second and paused and second.wave_flow.elapsed_seconds == production_clock, "second menu captures restart and freezes facility production")
	layer.close_menu()
	for facility: AIFacility in second.get_facility_targets(): facility.take_damage(999)
	await _frames(4)
	_check(navigator.progress_store.get_snapshot().continue_level == 3, "second objective unlocks third once")
	second.flow_hud.result_continue_button.pressed.emit()
	await _frames(5)
	_check(current_scene is ThirdLevel and not paused and current_scene.mother_core.nutrition == 100, "existing next-level button retains clean third entry")
	var third := current_scene as ThirdLevel
	third.fragment_collection.set_process(false)
	third.get_fragment_targets()[0].position = third.mother_core.position
	third.fungal_field.advance(1)
	third.fragment_collection._process(1)
	third.compact_hud.level_menu.open_menu()
	third.fragment_collection._process(5)
	_key(KEY_R)
	await _frames(5)
	_check(current_scene == third and paused and third.get_fragment_targets()[0].progress_seconds == 1, "third menu freezes partial collection and captures restart")
	third.compact_hud.level_menu.close_menu()
	for fragment: MemoryFragment in third.get_fragment_targets():
		fragment.position = third.mother_core.position
	third.fungal_field.advance(1)
	third.fragment_collection._process(5)
	await _frames(5)
	_check(navigator.progress_store.get_snapshot().completed, "third completion persists completed campaign")
	_check(third.flow_hud._ending_pending, "menu integration preserves existing CG4 ending")
	third.flow_hud.finish_ending()
	_check(third.compact_hud.level_menu.result_title_button.is_visible_in_tree(), "ending result offers return to title")
	third.compact_hud.level_menu.result_title_button.pressed.emit()
	await _frames(5)
	_check(current_scene is MainMenu and current_scene.progress_label.text.contains("已通关"), "completed title remains replayable")
	var reloaded := CampaignProgressStore.new(SAVE)
	_check(reloaded.load_progress() and reloaded.get_snapshot().completed, "completed record survives reload")


func _reset_confirmation() -> void:
	var menu := current_scene as MainMenu
	menu.start_button.pressed.emit()
	await _frames(3)
	_check(menu.reset_dialog.visible and current_scene == menu, "new game asks before resetting unlocked progress")
	menu.reset_dialog.hide()
	_check(navigator.progress_store.get_snapshot().completed, "cancelling new game preserves old record")
	menu.start_button.pressed.emit()
	menu.reset_dialog.confirmed.emit()
	await _frames(5)
	_check(current_scene is FirstLevel and navigator.progress_store.get_snapshot().highest_unlocked == 1, "confirmed new game resets progress and starts first")


func _failure_and_restart() -> void:
	var first := current_scene as FirstLevel
	first.mother_core.take_damage(999)
	await _frames(4)
	_check(first.flow_hud.result_panel.visible and first.compact_hud.level_menu.result_title_button.is_visible_in_tree(), "failure presents restart and exit navigation")
	_check(navigator.progress_store.get_snapshot().highest_unlocked == 1, "failure never unlocks another chapter")
	first.compact_hud.level_menu.result_title_button.pressed.emit()
	await _frames(5)
	current_scene.continue_button.pressed.emit()
	await _frames(5)
	var old_id: int = current_scene.get_instance_id()
	var layer: LevelMenuLayer = current_scene.compact_hud.level_menu
	layer.open_menu()
	layer.restart_button.pressed.emit()
	await _frames(6)
	_check(current_scene is FirstLevel and current_scene.get_instance_id() != old_id and not paused, "menu restart clears modal and global pause")
	_check(not current_scene.compact_hud.level_menu.is_open() and current_scene.mother_core.nutrition == 72, "restart has fresh layout and capital")


func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.position = point
	down.global_position = point
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	root.push_input(down, true)
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	root.push_input(up, true)


func _key(code: Key) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.pressed = true
	root.push_input(down, true)
	var up := down.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up, true)
