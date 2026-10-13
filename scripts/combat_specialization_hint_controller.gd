class_name CombatSpecializationHintController
extends Node

## 只观察本场景的真实分化、活体批次与弹药状态；关闭期间仍记录首次发生。

signal hint_changed(snapshot: Dictionary)

const HINT_IDS: Array[StringName] = [
	&"mature_unlocked", &"differentiation_started", &"differentiation_ceasefire",
	&"piercing_completed", &"scatter_completed", &"armored_encounter",
	&"swarm_encounter", &"ammunition_wait",
]
const HINT_TEXT: Dictionary = {
	&"mature_unlocked": "累计回收达到160，攻击器官可分化。选择普通攻击器官，再选破甲或散射；费用8材料，至少5秒有效工作。",
	&"differentiation_started": "分化已开始：方向已锁定，材料到达后逐段工作；付款进度会保留。",
	&"differentiation_ceasefire": "分化器官正在停火：等待材料和暂停时也不会射击，完成或取消后恢复工作。",
	&"piercing_completed": "破甲分化完成：24伤害、1.8秒、178射程，每轮2营养；破甲可忽略护甲。",
	&"scatter_completed": "散射分化完成：6伤害、0.9秒、145射程，整轮1营养；完整60度内最多命中3个不同目标，适合小型群。",
	&"armored_encounter": "当前批次出现了重甲敌人。护甲会削减普通和散射伤害，可考虑用破甲应对左翼。",
	&"swarm_encounter": "当前批次出现了小型敌人。可考虑右翼散射覆盖多个不同目标；同一敌人不会承受三弹集中。",
	&"ammunition_wait": "射程内有活敌，但活动武器库存不足支付一整轮，正在等待弹药；保持供养通路可用。",
}

var _enabled: bool = true
var _configured: bool = false
var _generation: int = 0
var _configuration_ids: Array[int] = []
var _source_refs: Dictionary[StringName, WeakRef] = {}
var _bindings: Array[Dictionary] = []
var _encounters: Dictionary[int, Dictionary] = {}
var _current_id: StringName = &""
var _pending_ids: Array[StringName] = []
var _seen_ids: Dictionary[StringName, bool] = {}
var _seen_order: Array[StringName] = []
var _notification_queue: Array[Dictionary] = []
var _last_queued_snapshot: Dictionary = {}
var _last_emitted_snapshot: Dictionary = {}
var _is_notifying: bool = false


func _init() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	# 新培育武器、静默库存变化和射程变化都通过原 get_weapons 接口只读采样。
	_observe_current_state()


func _exit_tree() -> void:
	stop()


func _on_progress_changed(_total: int, _count: int, generation: int, source_id: int) -> void:
	_observe_callback(&"progress", generation, source_id)


func _on_stage_changed(
	_previous: ColonyProgress.Stage, _current: ColonyProgress.Stage,
	generation: int, source_id: int
) -> void:
	_observe_callback(&"progress", generation, source_id)


func _on_stage_unlocked(_stage: ColonyProgress.Stage, generation: int, source_id: int) -> void:
	_observe_callback(&"progress", generation, source_id)


func _on_task_changed(_snapshot: Dictionary, generation: int, source_id: int) -> void:
	_observe_callback(&"differentiation", generation, source_id)


func _on_task_terminal(_task_id: int, generation: int, source_id: int) -> void:
	_observe_callback(&"differentiation", generation, source_id)


func _on_organ_differentiated(
	_task_id: int, _organ: AttackOrgan, _direction: int,
	generation: int, source_id: int
) -> void:
	_observe_callback(&"differentiation", generation, source_id)


func _on_batch_changed(_snapshot: Dictionary, generation: int, source_id: int) -> void:
	_observe_callback(&"spawner", generation, source_id)


func _on_enemy_spawned(
	enemy: BasicEnemy, spawn_id: String, batch_id: String,
	generation: int, source_id: int
) -> void:
	if not _callback_is_current(&"spawner", generation, source_id):
		return
	var spawner: EnemySpawner = _live_source(&"spawner") as EnemySpawner
	var batch: Dictionary = spawner.get_batch_snapshot()
	var encounter: Dictionary = {
		"enemy": weakref(enemy) if is_instance_valid(enemy) else null,
		"spawn_id": spawn_id, "batch_id": batch_id,
		"batch_generation": int(batch.get("generation", -1)),
	}
	if _encounter_is_current(encounter, spawner, batch):
		_encounters[enemy.get_instance_id()] = encounter
	_observe_current_state()


func _on_supply_changed(
	_in_transit: int, _delivered: int, _interrupted: int,
	generation: int, source_id: int
) -> void:
	_observe_callback(&"supply", generation, source_id)


func configure(
	progress: ColonyProgress, differentiation: DifferentiationSystem,
	spawner: EnemySpawner, combat_supply: SupplySystem, weapon_source: Node
) -> void:
	var sources: Array[Node] = [progress, differentiation, spawner, combat_supply, weapon_source]
	var source_ids: Array[int] = []
	for source: Node in sources:
		source_ids.append(source.get_instance_id() if _node_is_available(source) else 0)
	if _configured and source_ids == _configuration_ids:
		_observe_current_state()
		return

	_generation += 1
	_disconnect_sources()
	_clear_presentation(true)
	_configuration_ids = source_ids
	_configured = true
	var keys: Array[StringName] = [
		&"progress", &"differentiation", &"spawner", &"supply", &"weapons",
	]
	for index: int in range(sources.size()):
		if _node_is_available(sources[index]):
			_source_refs[keys[index]] = weakref(sources[index])
	_bind_source(&"progress", &"progress_changed", _on_progress_changed)
	_bind_source(&"progress", &"stage_changed", _on_stage_changed)
	_bind_source(&"progress", &"stage_unlocked", _on_stage_unlocked)
	_bind_source(&"differentiation", &"task_changed", _on_task_changed)
	_bind_source(&"differentiation", &"task_cancelled", _on_task_terminal)
	_bind_source(&"differentiation", &"task_completed", _on_task_terminal)
	_bind_source(&"differentiation", &"organ_differentiated", _on_organ_differentiated)
	_bind_source(&"spawner", &"batch_changed", _on_batch_changed)
	_bind_source(&"spawner", &"enemy_spawned", _on_enemy_spawned)
	_bind_source(&"supply", &"transport_changed", _on_supply_changed)
	set_process(true)
	_observe_current_state()


func get_snapshot() -> Dictionary:
	return _build_snapshot().duplicate(true)


func dismiss_current() -> bool:
	if not _configured or not _enabled or _current_id == &"":
		return false
	var was_visible: bool = _hint_is_ready(_current_id)
	_current_id = &""
	_refresh_presentation()
	_queue_snapshot_notification()
	return was_visible


func set_enabled(value: bool) -> void:
	if _enabled == value:
		return
	if value:
		# 关闭期间没有业务信号的变化也先记已见，重新开启不回放历史。
		_observe_current_state()
		_enabled = true
	else:
		_enabled = false
		_current_id = &""
		_pending_ids.clear()
	_observe_current_state()
	_queue_snapshot_notification()


func is_enabled() -> bool:
	return _enabled


func reset() -> void:
	_retire_sources(true)


func stop() -> void:
	_retire_sources(false)


func _retire_sources(clear_seen: bool) -> void:
	_generation += 1
	_configured = false
	_disconnect_sources()
	_clear_presentation(clear_seen)
	_configuration_ids.clear()
	set_process(false)
	_queue_snapshot_notification()


func _observe_callback(key: StringName, generation: int, source_id: int) -> void:
	if not _callback_is_current(key, generation, source_id):
		return
	# 载荷只负责唤醒；真实任务、配置、计时器和批次身份才是提示证据。
	_observe_current_state()


func _callback_is_current(key: StringName, generation: int, source_id: int) -> bool:
	if not _configured or generation != _generation or not _node_is_available(self):
		return false
	var source: Node = _live_source(key)
	return source != null and source.get_instance_id() == source_id


func _observe_current_state() -> void:
	if not _configured or not _node_is_available(self):
		return
	var generation: int = _generation
	var ready: Array[StringName] = []
	_prune_encounters()
	for id: StringName in HINT_IDS:
		if not _seen_ids.has(id) and _hint_is_ready(id):
			ready.append(id)
		if generation != _generation or not _configured:
			return
	# 先提交整批身份再发通知，同步关闭或 dismiss 不会重复入队。
	for id: StringName in ready:
		_seen_ids[id] = true
		_seen_order.append(id)
		if _enabled:
			_pending_ids.append(id)
	_refresh_presentation()
	_queue_snapshot_notification()


func _hint_is_ready(id: StringName) -> bool:
	if not _configured:
		return false
	match id:
		&"mature_unlocked":
			var progress: ColonyProgress = _live_source(&"progress") as ColonyProgress
			return progress != null and progress.can_process() \
				and progress.get_stage() == ColonyProgress.Stage.MATURE
		&"differentiation_started":
			return not _active_task_snapshot().is_empty()
		&"differentiation_ceasefire":
			var task: Dictionary = _active_task_snapshot()
			if task.is_empty():
				return false
			var organ: AttackOrgan = task["organ"]
			var weapon: SporeWeapon = task["weapon"]
			var timer: Timer = weapon.get_node_or_null("FireTimer") as Timer
			return not organ.is_work_enabled() and _node_is_available(timer) \
				and timer.is_stopped() and not bool(weapon.get_firing_state().get("active", true))
		&"piercing_completed":
			return _has_completed_type(int(WeaponProfile.DamageType.ARMOR_PIERCING))
		&"scatter_completed":
			return _has_completed_type(int(WeaponProfile.DamageType.SCATTER))
		&"armored_encounter":
			return _has_live_encounter(int(BasicEnemy.Archetype.ARMORED))
		&"swarm_encounter":
			return _has_live_encounter(int(BasicEnemy.Archetype.SWARM))
		&"ammunition_wait":
			return _has_ammunition_wait()
		_:
			return false


func _active_task_snapshot() -> Dictionary:
	var differentiation: DifferentiationSystem = _live_source(&"differentiation") as DifferentiationSystem
	if differentiation == null or differentiation.is_stopped() or not differentiation.can_process() \
		or not differentiation.has_active_task():
		return {}
	var task: Dictionary = differentiation.get_task_snapshot()
	var organ: Variant = task.get("organ")
	var weapon: Variant = task.get("weapon")
	var host: Variant = task.get("host")
	if not _actor_is_live(organ) or not organ is AttackOrgan or not _actor_is_live(weapon) \
		or not weapon is SporeWeapon or not _actor_is_live(host):
		return {}
	var organ_task: Dictionary = organ.get_differentiation_snapshot()
	if int(task.get("task_id", 0)) <= 0 \
		or int(organ_task.get("task_id", 0)) != int(task["task_id"]) \
		or organ_task.get("state", &"") not in [&"waiting", &"differentiating", &"paused"] \
		or task.get("state", &"") not in [&"waiting", &"differentiating", &"paused"] \
		or organ.get_parent() != host or weapon.get_parent() != host or weapon.inventory_owner != organ:
		return {}
	return task


func _has_completed_type(damage_type: int) -> bool:
	var differentiation: DifferentiationSystem = _live_source(&"differentiation") as DifferentiationSystem
	if differentiation == null or differentiation.is_stopped() or not differentiation.can_process():
		return false
	for weapon: SporeWeapon in _get_weapons():
		var organ: AttackOrgan = weapon.inventory_owner
		if not _actor_is_live(organ) or not organ.has_completed_differentiation() \
			or organ.get_attack_type() != damage_type:
			continue
		var organ_task: Dictionary = organ.get_differentiation_snapshot()
		var task_id: int = int(organ_task.get("task_id", 0))
		if task_id <= 0 or organ_task.get("state", &"") != &"completed":
			continue
		# 来源的历史任务与器官公开快照必须指向同一次真实完成，不持有内部可写记录。
		var task: Dictionary = differentiation.get_task_snapshot(task_id)
		if int(task.get("task_id", 0)) == task_id \
			and task.get("state", &"") == &"completed" and task.get("organ") == organ \
			and task.get("weapon") == weapon and task.get("host") == organ.get_parent() \
			and int(task.get("direction", -1)) == damage_type \
			and int(task.get("consumed_nutrition", 0)) == DifferentiationSystem.TOTAL_COST \
			and float(task.get("effective_time", 0.0)) >= DifferentiationSystem.MINIMUM_EFFECTIVE_TIME:
			return true
	return false


func _get_weapons() -> Array[SporeWeapon]:
	var weapons: Array[SporeWeapon] = []
	var source: Node = _live_source(&"weapons")
	if source == null or not source.can_process() or not source.has_method(&"get_weapons"):
		return weapons
	var generation: int = _generation
	var candidates: Variant = source.call(&"get_weapons")
	if generation != _generation or _live_source(&"weapons") != source or not candidates is Array:
		return weapons
	for candidate: Variant in candidates:
		if _actor_is_live(candidate) and candidate is SporeWeapon and not weapons.has(candidate):
			var organ: AttackOrgan = candidate.inventory_owner
			if _actor_is_live(organ) and _actor_is_live(organ.get_parent()) \
				and candidate.get_parent() == organ.get_parent():
				weapons.append(candidate as SporeWeapon)
	return weapons


func _has_ammunition_wait() -> bool:
	var supply: SupplySystem = _live_source(&"supply") as SupplySystem
	if supply == null or supply.is_stopped() or not supply.can_process():
		return false
	for weapon: SporeWeapon in _get_weapons():
		var organ: AttackOrgan = weapon.inventory_owner
		var timer: Timer = weapon.get_node_or_null("FireTimer") as Timer
		var differentiation_state: StringName = organ.get_differentiation_snapshot().get("state", &"")
		if not supply.has_registered_organ(organ) or not organ.is_work_enabled() \
			or differentiation_state in [&"waiting", &"differentiating", &"paused"] \
			or not _actor_is_live(timer) \
			or timer.is_stopped() or timer.paused:
			continue
		var firing: Dictionary = weapon.get_firing_state()
		var cost: int = weapon.get_nutrition_cost()
		if not bool(firing.get("active", false)) or bool(firing.get("committing", true)) \
			or cost <= 0 or organ.nutrition >= cost \
			or not _actor_is_live(weapon.enemy_container) \
			or not _actor_is_live(weapon.projectile_container) \
			or weapon.projectile_scene == null or not weapon.projectile_scene.can_instantiate():
			continue
		var attack_range: float = weapon.attack_range + SporeWeapon.RANGE_TOLERANCE
		for child: Node in weapon.enemy_container.get_children():
			if child is BasicEnemy and _actor_is_live(child) and child.is_alive():
				var distance: float = organ.global_position.distance_squared_to(child.global_position)
				if is_finite(distance) and distance <= attack_range * attack_range:
					return true
	return false


func _has_live_encounter(archetype: int) -> bool:
	var spawner: EnemySpawner = _live_source(&"spawner") as EnemySpawner
	if spawner == null:
		return false
	var batch: Dictionary = spawner.get_batch_snapshot()
	for encounter: Dictionary in _encounters.values():
		if _encounter_is_current(encounter, spawner, batch):
			var enemy: BasicEnemy = (encounter["enemy"] as WeakRef).get_ref() as BasicEnemy
			if enemy.get_archetype() == archetype \
				and (archetype != int(BasicEnemy.Archetype.ARMORED) or enemy.armor > 0):
				return true
	return false


func _encounter_is_current(encounter: Dictionary, spawner: EnemySpawner, batch: Dictionary) -> bool:
	if spawner == null or not spawner.can_process() \
		or batch.get("state", "") not in ["spawning", "draining"] \
		or String(encounter.get("batch_id", "")).is_empty() \
		or String(encounter.get("spawn_id", "")).is_empty() \
		or encounter.get("batch_id") != batch.get("batch_id") \
		or int(encounter.get("batch_generation", -1)) != int(batch.get("generation", -2)):
		return false
	var reference: WeakRef = encounter.get("enemy")
	var enemy: BasicEnemy = reference.get_ref() as BasicEnemy if reference != null else null
	if not _actor_is_live(enemy) or not enemy.is_alive() \
		or not _node_is_available(spawner.enemy_container) or enemy.get_parent() != spawner.enemy_container \
		or enemy.get_meta(&"spawn_id", "") != encounter["spawn_id"] \
		or enemy.get_meta(&"batch_id", "") != encounter["batch_id"]:
		return false
	# 仅有同名 metadata 或伪造 enemy_spawned 参数不能证明属于实际批次。
	return spawner.has_active_enemy(enemy)


func _prune_encounters() -> void:
	var spawner: EnemySpawner = _live_source(&"spawner") as EnemySpawner
	var batch: Dictionary = spawner.get_batch_snapshot() if spawner != null else {}
	for enemy_id: int in _encounters.keys():
		if not _encounter_is_current(_encounters[enemy_id], spawner, batch):
			_encounters.erase(enemy_id)


func _refresh_presentation() -> void:
	if not _enabled:
		_current_id = &""
		_pending_ids.clear()
	else:
		if _current_id != &"" and not _hint_is_ready(_current_id):
			_current_id = &""
		var pending: Array[StringName] = []
		for id: StringName in _pending_ids:
			if _hint_is_ready(id):
				pending.append(id)
		_pending_ids = pending
		if _current_id == &"" and not _pending_ids.is_empty():
			_current_id = _pending_ids.pop_front()


func _build_snapshot() -> Dictionary:
	var visible: bool = _configured and _enabled and _current_id != &"" \
		and _hint_is_ready(_current_id)
	var pending_count: int = 0
	if _configured and _enabled:
		for id: StringName in _pending_ids:
			if _hint_is_ready(id):
				pending_count += 1
	return {
		"enabled": _enabled, "visible": visible, "id": _current_id if visible else &"",
		"text": String(HINT_TEXT.get(_current_id, "")) if visible else "",
		"pending_count": pending_count, "seen_ids": _seen_order.duplicate(),
		"generation": _generation,
	}


func _bind_source(key: StringName, signal_name: StringName, handler: Callable) -> void:
	var source: Node = _live_source(key)
	if source == null or not source.has_signal(signal_name):
		return
	var callback: Callable = handler.bind(_generation, source.get_instance_id())
	if source.connect(signal_name, callback) == OK:
		_bindings.append({"source": weakref(source), "signal": signal_name, "callback": callback})


func _disconnect_sources() -> void:
	var bindings: Array[Dictionary] = _bindings.duplicate()
	_bindings.clear()
	_source_refs.clear()
	for binding: Dictionary in bindings:
		var source: Node = (binding["source"] as WeakRef).get_ref() as Node
		if is_instance_valid(source) and source.is_connected(binding["signal"], binding["callback"]):
			source.disconnect(binding["signal"], binding["callback"])


func _live_source(key: StringName) -> Node:
	var reference: WeakRef = _source_refs.get(key)
	var source: Node = reference.get_ref() as Node if reference != null else null
	return source if _node_is_available(source) else null


func _node_is_available(node: Variant) -> bool:
	if not is_instance_valid(node) or not node is Node or node.is_queued_for_deletion() \
		or not node.is_inside_tree():
		return false
	var parent: Node = node.get_parent()
	while parent != null:
		if parent.is_queued_for_deletion():
			return false
		parent = parent.get_parent()
	return true


func _actor_is_live(node: Variant) -> bool:
	return _node_is_available(node) and node.is_node_ready() and node.can_process()


func _clear_presentation(clear_seen: bool) -> void:
	_current_id = &""
	_pending_ids.clear()
	_encounters.clear()
	_notification_queue.clear()
	_last_queued_snapshot.clear()
	if clear_seen:
		_seen_ids.clear()
		_seen_order.clear()


func _queue_snapshot_notification() -> void:
	var snapshot: Dictionary = _build_snapshot()
	if snapshot == _last_queued_snapshot:
		return
	_last_queued_snapshot = snapshot.duplicate(true)
	_notification_queue.append({"generation": _generation, "snapshot": snapshot})
	_flush_notifications()


func _flush_notifications() -> void:
	if _is_notifying:
		return
	_is_notifying = true
	while not _notification_queue.is_empty():
		var notification: Dictionary = _notification_queue.pop_front()
		if notification["generation"] == _generation and _node_is_available(self):
			var snapshot: Dictionary = notification["snapshot"]
			if snapshot == _build_snapshot() and snapshot != _last_emitted_snapshot:
				_last_emitted_snapshot = snapshot.duplicate(true)
				hint_changed.emit(snapshot.duplicate(true))
	_is_notifying = false
