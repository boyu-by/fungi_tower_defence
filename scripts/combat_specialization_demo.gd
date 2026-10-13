class_name CombatSpecializationDemo
extends "res://scripts/progression_demo.gd"
## 沿用真实成长和运输；玩家成熟后手动开启一批有限战斗验证。

signal combat_demo_changed(snapshot: Dictionary)

const BATCH_KINDS: Array[StringName] = [&"normal", &"swarm", &"armored", &"mixed"]
const BATCH_TITLES: Dictionary = {
	&"normal": "普通 ×6｜左右轮换",
	&"swarm": "小型 ×3｜右翼进入，推荐右翼散射",
	&"armored": "重甲 ×1｜左翼进入，推荐左翼破甲",
	&"mixed": "混合 ×6｜普通轮换、小型右翼、重甲左翼",
}

@export var normal_batch_entries: Array[EnemySpawnEntry] = []
@export var swarm_batch_entries: Array[EnemySpawnEntry] = []
@export var armored_batch_entries: Array[EnemySpawnEntry] = []
@export var mixed_batch_entries: Array[EnemySpawnEntry] = []

var combat_resource_ledger: CombatResourceLedger
var combat_hint_controller: CombatSpecializationHintController
var _selected_batch: StringName = &"normal"
var _phase: StringName = &"preparing"
var _batch_id: String = ""
var _batch_spend_baseline: int = 0
var _last_batch_snapshot: Dictionary = {}
var _last_demo_snapshot: Dictionary = {}
var _stopped_batch_spent: int = 0
var _demo_stopped: bool = false
var _start_in_progress: bool = false
var _publishing_demo: bool = false
var _publication_pending: bool = false
var _demo_generation: int = 0
var _demo_bindings: Array[Dictionary] = []


func _ready() -> void:
	_bind_demo_signal(self, &"level_stopping", _on_level_stopping)
	super._ready()
	if _demo_stopped:
		return
	combat_resource_ledger = CombatResourceLedger.new()
	combat_resource_ledger.name = "CombatResourceLedger"
	$Systems.add_child(combat_resource_ledger)
	combat_resource_ledger.configure(self)
	hud.set_combat_demo_enabled(true)
	_bind_demo_signal(enemy_spawner, &"batch_started", _on_test_batch_started)
	_bind_demo_signal(enemy_spawner, &"batch_changed", _on_test_batch_changed)
	_bind_demo_signal(colony_progress, &"stage_changed", _on_test_stage_changed)
	_bind_demo_signal(differentiation_system, &"task_changed", _on_test_differentiation_changed)
	_bind_demo_signal(hud, &"combat_batch_selected", _on_combat_batch_selected)
	_bind_demo_signal(hud, &"combat_batch_start_requested", _on_combat_batch_start_requested)
	_bind_demo_signal(hud, &"combat_batch_stop_requested", stop_test_batch)
	_bind_demo_signal(hud, &"combat_hint_dismiss_requested", _on_combat_hint_dismiss_requested)
	_bind_demo_signal(hud, &"combat_hint_toggle_requested", _on_combat_hint_toggle_requested)
	combat_hint_controller = CombatSpecializationHintController.new()
	combat_hint_controller.name = "CombatSpecializationHintController"
	$Systems.add_child(combat_hint_controller)
	_bind_demo_signal(combat_hint_controller, &"hint_changed", _on_combat_hint_changed)
	combat_hint_controller.configure(colony_progress, differentiation_system,
		enemy_spawner, supply_system, self)
	_refresh_combat_demo()
	hud.show_combat_hint(combat_hint_controller.get_snapshot())
	hud.show_notice("先回收两处尸骸并真实回流至成熟；推荐左翼破甲、右翼散射，再选择验证批次并开始")


func _process(delta: float) -> void:
	if _demo_stopped:
		return
	super._process(delta)
	# 全局 volley 统计和非生成器活体可能在任意节点回调中改变。
	_refresh_combat_demo()


func _exit_tree() -> void:
	stop_demo()
	super._exit_tree()


func _on_test_batch_started(accepted_id: String, _planned: int) -> void:
	if _demo_stopped or not _start_in_progress:
		return
	_batch_id = accepted_id
	_phase = &"fighting"
	_last_batch_snapshot = enemy_spawner.get_batch_snapshot().duplicate(true)
	_refresh_combat_demo()


func _on_test_batch_changed(snapshot: Dictionary) -> void:
	if _demo_stopped or _batch_id.is_empty() or String(snapshot.get("batch_id", "")) != _batch_id:
		return
	_last_batch_snapshot = snapshot.duplicate(true)
	match StringName(snapshot.get("state", &"idle")):
		&"completed":
			_phase = &"cleared"
		&"stopped", &"invalid":
			_phase = &"stopped"
		&"spawning", &"draining":
			_phase = &"fighting"
	_refresh_combat_demo()


func _on_test_stage_changed(_previous: ColonyProgress.Stage, _current: ColonyProgress.Stage) -> void:
	_refresh_combat_demo()


func _on_test_differentiation_changed(_snapshot: Dictionary) -> void:
	_refresh_combat_demo()


func _on_combat_batch_selected(kind: StringName) -> void:
	if not select_test_batch(kind) and not _demo_stopped:
		hud.show_notice("请先结束当前生成并处理场上敌人，再选择下一批")


func _on_combat_batch_start_requested() -> void:
	var accepted_id: String = start_test_batch()
	if accepted_id.is_empty() and not _demo_stopped:
		hud.show_notice("暂时无法开启验证批次，请查看战斗面板中的开始条件")


func _on_combat_hint_changed(snapshot: Dictionary) -> void:
	if not _demo_stopped and _is_live_demo_node(hud):
		hud.show_combat_hint(snapshot)


func _on_combat_hint_dismiss_requested() -> void:
	if not _demo_stopped and _is_live_demo_node(combat_hint_controller):
		combat_hint_controller.dismiss_current()


func _on_combat_hint_toggle_requested(enabled: bool) -> void:
	if not _demo_stopped and _is_live_demo_node(combat_hint_controller):
		combat_hint_controller.set_enabled(enabled)


func _on_level_stopping(reason: StringName) -> void:
	if reason == &"core_depleted" or (_is_live_demo_node(mother_core) and mother_core.health <= 0):
		_phase = &"defeated"
	stop_demo()


## 继承关卡的 wave_finished 不把有限验证批次写成关卡通关。
func _on_wave_finished() -> void:
	_refresh_combat_demo()


func get_batch_choices() -> Array[Dictionary]:
	var choices: Array[Dictionary] = []
	for kind: StringName in BATCH_KINDS:
		choices.append({"id": kind, "title": String(BATCH_TITLES[kind]),
			"planned": _get_configured_count(kind)})
	return choices


func select_test_batch(kind: StringName) -> bool:
	if not _is_batch_kind(kind) or not _demo_can_run() or _start_in_progress \
			or _publishing_demo or _has_live_enemies() or _spawner_has_pending_batch():
		return false
	_selected_batch = kind
	_phase = &"preparing"
	_batch_id = ""
	_last_batch_snapshot.clear()
	_stopped_batch_spent = 0
	_refresh_combat_demo()
	return true


func start_test_batch() -> String:
	if not _demo_can_run() or _start_in_progress or _publishing_demo:
		return ""
	if _get_start_reason() != &"":
		_refresh_combat_demo()
		return ""
	_start_in_progress = true
	_demo_generation += 1
	var attempt_generation: int = _demo_generation
	var owner_reference: WeakRef = weakref(self)
	_batch_id = ""
	_last_batch_snapshot.clear()
	_phase = &"preparing"
	# reset 会删除生成器自有活体，所以只能在已验证无活体后调用。
	enemy_spawner.reset()
	if not is_instance_valid(owner_reference.get_ref()):
		return ""
	var accepted_id: String = ""
	if _demo_can_run() and attempt_generation == _demo_generation \
			and _get_start_reason(true) == &"":
		enemy_spawner.spawn_entries.assign(_get_batch_entries(_selected_batch))
		_batch_spend_baseline = int(get_combat_statistics().get("nutrition_spent", 0))
		_stopped_batch_spent = 0
		# 基线和重入门闩先就绪；start_batch 可同步生成、结束或被停止。
		accepted_id = enemy_spawner.start_batch()
	if not is_instance_valid(owner_reference.get_ref()):
		return accepted_id
	_start_in_progress = false
	if not _demo_stopped and attempt_generation == _demo_generation:
		if accepted_id.is_empty():
			_phase = &"preparing"
		else:
			_batch_id = accepted_id
			_last_batch_snapshot = enemy_spawner.get_batch_snapshot().duplicate(true)
	_refresh_combat_demo()
	return accepted_id


## 只停止后续生成；已在场的敌人继续按正式战斗链路结算。
func stop_test_batch() -> void:
	if not _demo_can_run() or (not _start_in_progress and _batch_id.is_empty()):
		return
	var snapshot: Dictionary = _read_spawner_snapshot()
	if not _start_in_progress and String(snapshot.get("state", "")) in ["completed", "stopped"]:
		return
	_demo_generation += 1
	_phase = &"stopped"
	var owner_reference: WeakRef = weakref(self)
	enemy_spawner.stop_spawning(&"manual")
	if not is_instance_valid(owner_reference.get_ref()):
		return
	_refresh_combat_demo()


func get_combat_demo_snapshot() -> Dictionary:
	var combat: Dictionary = get_combat_statistics().duplicate(true)
	var batch: Dictionary = _read_current_batch_snapshot()
	var mature: bool = _is_live_demo_node(colony_progress) \
		and colony_progress.get_stage() == ColonyProgress.Stage.MATURE
	var start_reason: StringName = _get_start_reason()
	var phase: StringName = _phase
	if _is_live_demo_node(mother_core) and mother_core.health <= 0:
		phase = &"defeated"
	var spent: int = _stopped_batch_spent if _demo_stopped else _get_batch_spent(combat)
	return {
		"selected_batch": _selected_batch, "batch_title": _get_batch_title(_selected_batch),
		"phase": String(phase), "can_start": start_reason == &"", "start_reason": start_reason,
		"mature": mature, "planned": int(batch.get("planned", _get_configured_count(_selected_batch))),
		"spawned": int(batch.get("spawned", 0)), "active": int(batch.get("active", 0)),
		"defeated": int(batch.get("defeated", 0)), "batch_id": _batch_id,
		"batch_spent": spent, "combat": combat,
	}


func get_combat_resource_snapshot() -> Dictionary:
	if not is_instance_valid(combat_resource_ledger):
		return {}
	return combat_resource_ledger.get_snapshot()


func stop_demo() -> void:
	if _demo_stopped:
		return
	_stopped_batch_spent = _get_batch_spent(get_combat_statistics())
	var current_batch: Dictionary = _read_current_batch_snapshot()
	if not current_batch.is_empty():
		_last_batch_snapshot = current_batch.duplicate(true)
	_demo_stopped = true
	_observation_stopped = true
	_demo_generation += 1
	if _phase != &"defeated":
		_phase = &"stopped"
	_disconnect_demo_signals()
	if is_instance_valid(combat_hint_controller):
		combat_hint_controller.stop()
	if is_instance_valid(combat_resource_ledger):
		combat_resource_ledger.stop()
	if is_instance_valid(enemy_spawner):
		enemy_spawner.stop_spawning(&"demo_stopped")
	if _is_live_demo_node(hud):
		hud.show_combat_hint({"enabled": false, "visible": false})
	_refresh_combat_demo()


func _get_batch_entries(kind: StringName) -> Array[EnemySpawnEntry]:
	match kind:
		&"normal":
			return normal_batch_entries
		&"swarm":
			return swarm_batch_entries
		&"armored":
			return armored_batch_entries
		&"mixed":
			return mixed_batch_entries
	return []


func _get_configured_count(kind: StringName) -> int:
	var count: int = 0
	for entry: EnemySpawnEntry in _get_batch_entries(kind):
		if entry == null or entry.enemy_scene == null or not entry.enemy_scene.can_instantiate():
			return 0
		var members: int = entry.get_total_count()
		if members <= 0 or members > EnemySpawner.MAX_BATCH_COUNT - count:
			return 0
		count += members
	return count


func _get_start_reason(allow_current_start: bool = false) -> StringName:
	if _demo_stopped or _is_tearing_down:
		return &"stopped"
	if not _is_live_demo_node(mother_core) or mother_core.health <= 0:
		return &"core_unavailable"
	if not _is_live_demo_node(colony_progress) \
			or colony_progress.get_stage() != ColonyProgress.Stage.MATURE:
		return &"stage_locked"
	if not _is_live_demo_node(differentiation_system) or differentiation_system.has_active_task():
		return &"differentiating"
	if not _is_live_demo_node(enemy_spawner):
		return &"invalid_configuration"
	if _start_in_progress and not allow_current_start:
		return &"batch_active"
	if _spawner_has_pending_batch():
		return &"batch_active"
	if _has_live_enemies():
		return &"enemies_remaining"
	if _get_configured_count(_selected_batch) <= 0:
		return &"invalid_configuration"
	return &""


func _has_live_enemies() -> bool:
	if _is_live_demo_node(enemy_spawner) and enemy_spawner.get_active_count() > 0:
		return true
	var container: Node = get_node_or_null("World/Enemies")
	if not _is_live_demo_node(container):
		return false
	for enemy: Node in container.get_children():
		if _is_live_demo_node(enemy) and enemy is BasicEnemy and (enemy as BasicEnemy).is_alive():
			return true
	return false


func _spawner_has_pending_batch() -> bool:
	var snapshot: Dictionary = _read_spawner_snapshot()
	return String(snapshot.get("state", "idle")) in ["waiting", "spawning", "draining"]


func _read_spawner_snapshot() -> Dictionary:
	if not _is_live_demo_node(enemy_spawner):
		return {}
	return enemy_spawner.get_batch_snapshot()


func _read_current_batch_snapshot() -> Dictionary:
	if _batch_id.is_empty():
		return {}
	if not _demo_stopped:
		var snapshot: Dictionary = _read_spawner_snapshot()
		if String(snapshot.get("batch_id", "")) == _batch_id:
			return snapshot
	return _last_batch_snapshot.duplicate(true)


func _get_batch_spent(combat: Dictionary) -> int:
	return maxi(0, int(combat.get("nutrition_spent", 0)) - _batch_spend_baseline) \
		if not _batch_id.is_empty() else 0


func _demo_can_run() -> bool:
	return not _demo_stopped and not _is_tearing_down and is_inside_tree() \
		and not is_queued_for_deletion()


func _refresh_combat_demo() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if _publishing_demo:
		_publication_pending = true
		return
	_publishing_demo = true
	var owner_reference: WeakRef = weakref(self)
	# 同步停止回调最多补发一次终态；选择/开始在发布期间有重入门闩。
	for _pass: int in range(2):
		_publication_pending = false
		var snapshot: Dictionary = get_combat_demo_snapshot()
		if snapshot == _last_demo_snapshot:
			break
		_last_demo_snapshot = snapshot.duplicate(true)
		if _is_live_demo_node(hud):
			hud.show_combat_demo(snapshot)
		combat_demo_changed.emit(snapshot)
		if not is_instance_valid(owner_reference.get_ref()):
			return
		if not _publication_pending:
			break
	_publishing_demo = false


func _bind_demo_signal(source: Node, signal_name: StringName, callback: Callable) -> void:
	if not is_instance_valid(source) or source.is_connected(signal_name, callback):
		return
	source.connect(signal_name, callback)
	_demo_bindings.append({"source": source, "signal": signal_name, "callback": callback})


func _disconnect_demo_signals() -> void:
	for binding: Dictionary in _demo_bindings:
		var source: Node = binding["source"]
		var callback: Callable = binding["callback"]
		if is_instance_valid(source) and source.is_connected(binding["signal"], callback):
			source.disconnect(binding["signal"], callback)
	_demo_bindings.clear()


func _is_batch_kind(kind: StringName) -> bool:
	return kind in BATCH_KINDS


func _get_batch_title(kind: StringName) -> String:
	return String(BATCH_TITLES.get(kind, "测试批次"))
