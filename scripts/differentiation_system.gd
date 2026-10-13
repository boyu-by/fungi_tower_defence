class_name DifferentiationSystem
extends Node
## 已投递材料按阶段开工扣除；器官保留方向与付款进度，取消只释放全局工作位。

signal task_changed(snapshot: Dictionary)
signal task_cancelled(task_id: int)
signal task_completed(task_id: int)
signal organ_differentiated(task_id: int, organ: AttackOrgan, direction: int)

const TOTAL_COST: int = 8
const MINIMUM_EFFECTIVE_TIME: float = 5.0
const STAGE_TIME: float = 0.625
const MAX_TASK_ID: int = 9223372036854775807
const Record = AttackOrgan.DifferentiationRecord
const ARMOR_PIERCING_PROFILE: WeaponProfile = preload("res://resources/weapons/armor_piercing_spore.tres")
const SCATTER_PROFILE: WeaponProfile = preload("res://resources/weapons/scatter_spore.tres")
const SUPPLY_WAIT_REASONS: Array[StringName] = [
	&"", &"nutrition", &"in_transit", &"core_empty", &"combat_reserve", &"repair_budget",
	&"disconnected", &"invalid_configuration", &"core_unavailable", &"paused",
	&"differentiation_budget", &"traffic_busy",
]

@export var colony_capabilities: ColonyCapabilities
@export var network_system: NetworkSystem

var _last_task_id: int = 0
var _task_id: int = 0
var _current: Record
var _organs: Dictionary[int, Record] = {}
var _attempt_records: Dictionary[int, Record] = {}
var _attempt_snapshots: Dictionary[int, Dictionary] = {}
var _settled_attempts: Dictionary[int, bool] = {}
var _shipments: Dictionary[String, bool] = {}
var _watched_nodes: Array[Dictionary] = []
var _watched_network: NetworkSystem
var _pending_records: Array[Record] = []
var _transitioning: bool = false
var _advancing: bool = false
var _notifying: bool = false
var _stopped: bool = false


func _ready() -> void:
	_bind_network()


func _physics_process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	# 终态、缓存和通知先可见，供养系统仍可按原付款账户结算。
	stop()
	_disconnect_watched_nodes()
	_disconnect_network()


func _on_network_changed() -> void:
	if has_active_task() and not _transitioning:
		_refresh_current()
		_publish_record(_current)


func _on_owned_node_tree_exiting(task_id: int) -> void:
	if task_id == _task_id and has_active_task():
		_cancel_current(true)


func _on_host_slot_changed(task_id: int) -> void:
	if task_id == _task_id and has_active_task() and not _transitioning:
		_refresh_current()
		_publish_record(_current)


func get_availability(organ: Variant, direction: int = -1) -> StringName:
	if _stopped:
		return &"stopped"
	if organ == null:
		return &"no_selection"
	if not _is_attack_organ(organ):
		return &"not_mature_organ"
	if organ.is_transplanting():
		return &"transplanting"
	if direction != -1 and not _direction_is_valid(direction):
		return &"invalid_direction"
	var record: Record = organ._get_differentiation_record()
	if record.completed:
		return &"completed"
	if record.direction != -1 and direction != -1 and record.direction != direction:
		return &"direction_locked"
	if has_active_task():
		if record == _current:
			return &"paused" if record.state == &"paused" else &"active"
		return &"busy"
	if record.is_active():
		return &"busy"
	if _has_pending_settlement() or record.buffered_nutrition > 0:
		return &"settlement_pending"
	if not _configuration_is_valid() or _last_task_id == MAX_TASK_ID:
		return &"invalid_configuration"
	if not colony_capabilities.can_differentiate_attack_organs():
		return &"stage_locked"
	var problem: StringName = _organ_problem(organ, record if record.direction != -1 else null)
	if problem != &"":
		return problem
	var chosen_direction: int = record.direction if direction == -1 else direction
	if chosen_direction != -1 and _preset_for(chosen_direction) == null:
		return &"invalid_configuration"
	if record.direction != -1 and not _record_profile_is_valid(record):
		return &"invalid_configuration"
	var core: MotherCore = _get_live_core()
	if core == null:
		return &"core_unavailable"
	var host: HyphaNode = organ.get_parent() as HyphaNode
	if not _is_connected(host, core):
		return &"disconnected"
	return &"continuable" if record.direction != -1 else &"ready"


func start_differentiation(organ: Variant, direction: int) -> int:
	if _transitioning or _advancing or _notifying or not _direction_is_valid(direction):
		return 0
	if get_availability(organ, direction) != &"ready":
		return 0
	var preset: WeaponProfile = _preset_for(direction)
	if preset == null:
		return 0
	var record: Record = organ._get_differentiation_record()
	# 先锁定方向，再发布停止工作的同步通知；等待材料也不能改选。
	record.direction = direction
	record.target_profile = preset.copy_for_instance()
	record.host_ref = weakref(organ.get_parent())
	record.weapon_ref = weakref(organ._find_matching_weapon())
	return _begin_attempt(record)


func continue_differentiation(organ: Variant) -> int:
	if _transitioning or _advancing or _notifying:
		return 0
	if get_availability(organ) != &"continuable":
		return 0
	return _begin_attempt(organ._get_differentiation_record())


func pause_task() -> bool:
	if not has_active_task() or _current.state == &"paused" or _transitioning:
		return false
	_current.state = &"paused"
	_current.wait_reason = &"paused"
	_publish_record(_current)
	return true


func resume_task() -> bool:
	if not has_active_task() or _current.state != &"paused" or _transitioning or _stopped:
		return false
	_current.state = &"waiting"
	_refresh_current()
	_publish_record(_current)
	return true


func cancel_task() -> bool:
	return _cancel_current(false)


func has_active_task() -> bool:
	return _current != null and _current.task_id == _task_id \
		and _current.get_controller() == self and _current.is_active()


func advance(delta: float) -> void:
	if not has_active_task() or _advancing or _transitioning or _notifying or _stopped \
		or not is_finite(delta) or delta <= 0.0:
		return
	_advancing = true
	_bind_network()
	var advancing_id: int = _task_id
	var remaining_time: float = delta
	while _can_advance(advancing_id):
		var record: Record = _current
		if record.consumed_nutrition == TOTAL_COST and not record.stage_paid:
			_complete_current(record)
			break
		if remaining_time <= 0.0:
			break
		if not record.stage_paid:
			if record.buffered_nutrition == 0:
				break
			# 此阶段的材料在开工瞬间成为不可退的消耗；到货本身不触发这里。
			record.buffered_nutrition -= 1
			record.consumed_nutrition += 1
			record.stage_paid = true
			record.stage_elapsed = 0.0
			_refresh_current()
			_publish_record(record)
		if not _can_advance(advancing_id):
			break
		var elapsed: float = minf(STAGE_TIME - record.stage_elapsed, remaining_time)
		record.stage_elapsed += elapsed
		record.effective_time = minf(MINIMUM_EFFECTIVE_TIME, record.effective_time + elapsed)
		remaining_time = maxf(0.0, remaining_time - elapsed)
		if record.stage_elapsed >= STAGE_TIME:
			record.stage_paid = false
			record.stage_elapsed = 0.0
			if record.consumed_nutrition == TOTAL_COST:
				record.effective_time = MINIMUM_EFFECTIVE_TIME
		_refresh_current()
		_publish_record(record)
	_advancing = false


func stop() -> void:
	_stopped = true
	_cancel_current(true)


func reset() -> void:
	# 仅重开系统准入。场景未替换时，器官付款、方向、完成标记不能被洗掉。
	var previous_transition: bool = _transitioning
	_transitioning = true
	_cancel_current(true)
	_stopped = false
	_transitioning = previous_transition


func is_stopped() -> bool:
	return _stopped


func get_task_snapshot(task_id: int = 0) -> Dictionary:
	var queried_id: int = _task_id if task_id == 0 else task_id
	if queried_id == 0:
		return Record.new().get_snapshot()
	if not _attempt_snapshots.has(queried_id):
		return {}
	if has_active_task() and queried_id == _task_id:
		return _snapshot_for(_current)
	return _sanitize_snapshot(_attempt_snapshots[queried_id])


func get_organ_snapshot(organ: Variant) -> Dictionary:
	if not _is_attack_organ(organ):
		return {}
	var record: Record = organ._get_differentiation_record()
	if record.get_controller() != self:
		var controller: Node = record.get_controller()
		if is_instance_valid(controller) and controller.has_method("get_organ_snapshot"):
			return controller.get_organ_snapshot(organ)
		return record.get_snapshot()
	return _snapshot_for(record)


## 移植只交接原记录的宿主和武器引用，不重开尝试或改变方向/阶段付款。
func rebind_organ_host(organ: AttackOrgan) -> bool:
	if not _is_attack_organ(organ) or organ._get_differentiation_record().is_active():
		return false
	var host: HyphaNode = organ.get_parent() as HyphaNode
	var weapon: SporeWeapon = organ._find_matching_weapon()
	if not _node_is_live(host) or not _node_is_live(weapon) or weapon.inventory_owner != organ:
		return false
	organ.rebind_host(host)
	var record: Record = organ._get_differentiation_record()
	if record.get_controller() == self:
		_publish_record(record)
	return true


func get_resource_snapshot() -> Dictionary:
	var consumed: int = 0
	var buffered: int = 0
	# 一次器官被取消/继续多次，也只有这一份共享记录进入资源总量。
	for record: Record in _organs.values():
		consumed += record.consumed_nutrition
		buffered += record.buffered_nutrition
	return {"consumed_nutrition": consumed, "buffered_nutrition": buffered}


func get_delivery_target(task_id: int) -> HyphaNode:
	if task_id != _task_id or not has_active_task() or not _owned_nodes_exist(_current):
		return null
	return _current.get_host()


func get_requested_nutrition(task_id: int) -> int:
	if task_id != _task_id or not has_active_task() or _current.state == &"paused" \
		or _active_problem(_current) != &"":
		return 0
	return _unfunded(_current)


func receive_nutrition(task_id: int, shipment_id: String, amount: int) -> bool:
	if task_id != _task_id or not has_active_task() or _transitioning or _stopped \
		or shipment_id.is_empty() or amount <= 0 or _shipments.has(shipment_id) \
		or not _owned_nodes_exist(_current) or amount > _unfunded(_current):
		return false
	# 已付款的货物仍能到达暂停器官；不动普通弹药、母核或阶段时钟。
	_shipments[shipment_id] = true
	_current.buffered_nutrition += amount
	_refresh_current()
	_publish_record(_current)
	return true


func take_unspent_nutrition(task_id: int) -> int:
	if not _attempt_snapshots.has(task_id) or _settled_attempts.has(task_id):
		return 0
	var snapshot: Dictionary = _attempt_snapshots[task_id]
	if snapshot["state"] != &"cancelled" and snapshot["state"] != &"completed":
		return 0
	_settled_attempts[task_id] = true
	var record: Record = _attempt_records[task_id]
	if record.task_id != task_id:
		return 0
	var unspent: int = record.buffered_nutrition
	record.buffered_nutrition = 0
	# 退款结算是历史快照唯一允许的缓存变更；后续尝试不再改写此快照。
	snapshot = snapshot.duplicate()
	snapshot["buffered_nutrition"] = 0
	_attempt_snapshots[task_id] = snapshot
	if unspent > 0:
		_publish_record(record)
	return unspent


func set_supply_wait_reason(task_id: int, reason: StringName) -> void:
	if task_id != _task_id or not has_active_task() or not SUPPLY_WAIT_REASONS.has(reason) \
		or _current.supply_wait_reason == reason:
		return
	_current.supply_wait_reason = reason
	_refresh_current()
	_publish_record(_current)


func _begin_attempt(record: Record) -> int:
	_transitioning = true
	_bind_network()
	_last_task_id += 1
	record.task_id = _last_task_id
	record.controller_ref = weakref(self)
	record.state = &"waiting"
	record.wait_reason = &"nutrition"
	record.supply_wait_reason = &""
	var organ: AttackOrgan = record.get_organ()
	# 休眠/宿主暂停是临时门控，不能把它们保存成玩家永久停工意图。
	record.previous_work_enabled = organ.get_requested_work_enabled()
	_current = record
	_task_id = record.task_id
	_organs[organ.get_instance_id()] = record
	_attempt_records[record.task_id] = record
	_attempt_snapshots[record.task_id] = record.get_snapshot()
	_watch_current(record)
	organ.set_work_enabled(false)
	var created_id: int = record.task_id
	_transitioning = false
	_refresh_current()
	_publish_record(record)
	return created_id


func _cancel_current(force: bool) -> bool:
	if not has_active_task() or (not force and _transitioning):
		return false
	var record: Record = _current
	var cancelled_id: int = record.task_id
	var previous_transition: bool = _transitioning
	_transitioning = true
	record.state = &"cancelled"
	record.wait_reason = &""
	record.supply_wait_reason = &""
	_disconnect_watched_nodes()
	_attempt_snapshots[cancelled_id] = record.get_snapshot()
	_restore_work(record)
	_publish_record(record)
	task_cancelled.emit(cancelled_id)
	_transitioning = previous_transition
	return true


func _complete_current(record: Record) -> void:
	if record != _current or not has_active_task() or record.completed \
		or record.consumed_nutrition != TOTAL_COST or record.stage_paid \
		or record.effective_time < MINIMUM_EFFECTIVE_TIME or _active_problem(record) != &"":
		return
	_transitioning = true
	var weapon: SporeWeapon = record.get_weapon()
	if not weapon.configure_profile(record.target_profile):
		record.state = &"waiting"
		record.wait_reason = &"invalid_configuration"
		_transitioning = false
		_publish_record(record)
		return
	# 同一武器只在这里采用副本；没有替换节点、_ready、补库存或重新收费。
	record.completed = true
	record.state = &"completed"
	record.wait_reason = &""
	record.supply_wait_reason = &""
	var completed_id: int = record.task_id
	var organ: AttackOrgan = record.get_organ()
	var direction: int = record.direction
	_disconnect_watched_nodes()
	_attempt_snapshots[completed_id] = record.get_snapshot()
	_restore_work(record)
	_publish_record(record)
	organ_differentiated.emit(completed_id, organ if _node_is_live(organ) else null, direction)
	task_completed.emit(completed_id)
	_transitioning = false


func _restore_work(record: Record) -> void:
	var organ: AttackOrgan = record.get_organ()
	if _node_is_live(organ):
		organ.set_work_enabled(record.previous_work_enabled)


func _refresh_current() -> void:
	if not has_active_task() or _transitioning:
		return
	if not _owned_nodes_exist(_current):
		_cancel_current(true)
	else:
		var snapshot: Dictionary = _snapshot_for(_current)
		_current.state = snapshot["state"]
		_current.wait_reason = snapshot["wait_reason"]


func _can_advance(task_id: int) -> bool:
	_refresh_current()
	return task_id == _task_id and has_active_task() and not _stopped \
		and _current.state != &"paused" and _active_problem(_current) == &"" \
		and (_current.stage_paid or _current.buffered_nutrition > 0 \
			or _current.consumed_nutrition == TOTAL_COST)


func _snapshot_for(record: Record) -> Dictionary:
	var snapshot: Dictionary = record.get_snapshot()
	if record != _current or not has_active_task():
		return snapshot
	var problem: StringName = _active_problem(record)
	var unpaused: bool = record.state != &"paused"
	var funded: bool = record.stage_paid or record.buffered_nutrition > 0 \
		or record.consumed_nutrition == TOTAL_COST
	snapshot["can_progress"] = unpaused and problem == &"" and funded
	snapshot["requested_nutrition"] = _unfunded(record) if unpaused and problem == &"" else 0
	if not unpaused:
		snapshot["state"] = &"paused"
		snapshot["wait_reason"] = &"paused"
	elif problem != &"":
		snapshot["state"] = &"waiting"
		snapshot["wait_reason"] = problem
	elif funded:
		snapshot["state"] = &"differentiating"
		snapshot["wait_reason"] = &""
	else:
		snapshot["state"] = &"waiting"
		snapshot["wait_reason"] = record.supply_wait_reason if record.supply_wait_reason != &"" else &"nutrition"
	return snapshot


func _sanitize_snapshot(source: Dictionary) -> Dictionary:
	var snapshot: Dictionary = source.duplicate()
	for key: String in ["organ", "host", "weapon"]:
		if not _node_is_live(snapshot[key]):
			snapshot[key] = null
	return snapshot


func _active_problem(record: Record) -> StringName:
	if _stopped:
		return &"stopped"
	if not _configuration_is_valid() or not _record_profile_is_valid(record):
		return &"invalid_configuration"
	if not colony_capabilities.can_differentiate_attack_organs():
		return &"stage_locked"
	var problem: StringName = _organ_problem(record.get_organ(), record)
	if problem != &"":
		return problem
	var core: MotherCore = _get_live_core()
	if core == null:
		return &"core_unavailable"
	return &"" if _is_connected(record.get_host(), core) else &"disconnected"


func _organ_problem(organ: Variant, expected: Record = null) -> StringName:
	if not _is_attack_organ(organ) or not _node_is_live(organ) or not organ.is_attackable():
		return &"organ_unavailable"
	if organ.is_transplanting():
		return &"transplanting"
	var host: HyphaNode = organ.get_parent() as HyphaNode
	if not _node_is_live(host) or not network_system.is_node_registered(host):
		return &"organ_unavailable"
	if host.get_organ_slot_state() != &"attack" or host.get_organ_occupant() != organ:
		return &"not_mature_organ"
	var occupants: int = 0
	var matches: int = 0
	var weapon: SporeWeapon
	for child: Node in host.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is AttackOrgan or child is DigestiveOrgan or child is OrganBud:
			occupants += 1
		if child is SporeWeapon and child.inventory_owner == organ:
			matches += 1
			weapon = child as SporeWeapon
	if occupants != 1 or matches != 1 or not _node_is_live(weapon) \
		or not organ.can_process() or not host.can_process() or not weapon.can_process():
		return &"not_mature_organ"
	if expected != null and (host != expected.get_host() or weapon != expected.get_weapon()):
		return &"organ_unavailable"
	if not weapon.has_valid_profile() or not _node_is_live(weapon.get_node_or_null("FireTimer")):
		return &"invalid_configuration"
	return &"" if organ.get_attack_type() == int(WeaponProfile.DamageType.NORMAL) else &"not_normal"


func _owned_nodes_exist(record: Record) -> bool:
	var organ: AttackOrgan = record.get_organ()
	var host: HyphaNode = record.get_host()
	var weapon: SporeWeapon = record.get_weapon()
	return _node_is_live(organ) and _node_is_live(host) and _node_is_live(weapon) \
		and organ.get_parent() == host and weapon.get_parent() == host \
		and weapon.inventory_owner == organ and organ.is_attackable()


func _configuration_is_valid() -> bool:
	return _node_is_live(self) and _node_is_live(network_system) \
		and _node_is_live(colony_capabilities) and _node_is_live(colony_capabilities.colony_progress)


func _get_live_core() -> MotherCore:
	var core: MotherCore = network_system.peek_registered_core() as MotherCore \
		if _node_is_live(network_system) else null
	return core if _node_is_live(core) and core.health > 0 else null


func _is_connected(host: HyphaNode, core: MotherCore) -> bool:
	# 只读通行连通性：断裂/禁行边不连通；已缓存工作不受实时席位占满影响。
	if not _node_is_live(host) or not _node_is_live(core):
		return false
	var topology: Dictionary = network_system.get_topology_snapshot()
	var edges: Array = topology["edges"]
	var reached: Dictionary[int, bool] = {host.get_instance_id(): true}
	var pending: Array[Node2D] = [host]
	var index: int = 0
	while index < pending.size() and not reached.has(core.get_instance_id()):
		var node: Node2D = pending[index]
		index += 1
		for edge: Dictionary in edges:
			if not bool(edge["entry_enabled"]):
				continue
			var neighbor: Node2D = null
			if edge["start_node"] == node:
				neighbor = edge["end_node"]
			elif edge["end_node"] == node:
				neighbor = edge["start_node"]
			if _node_is_live(neighbor) and not reached.has(neighbor.get_instance_id()):
				reached[neighbor.get_instance_id()] = true
				pending.append(neighbor)
	return reached.has(core.get_instance_id())


func _has_pending_settlement() -> bool:
	for record: Record in _organs.values():
		if not record.is_active() and record.buffered_nutrition > 0:
			return true
	return false


func _unfunded(record: Record) -> int:
	return maxi(0, TOTAL_COST - record.consumed_nutrition - record.buffered_nutrition)


func _record_profile_is_valid(record: Record) -> bool:
	return record.target_profile != null and record.target_profile.is_valid() \
		and int(record.target_profile.damage_type) == record.direction


func _preset_for(direction: int) -> WeaponProfile:
	var profile: WeaponProfile = null
	if direction == int(WeaponProfile.DamageType.ARMOR_PIERCING):
		profile = ARMOR_PIERCING_PROFILE
	elif direction == int(WeaponProfile.DamageType.SCATTER):
		profile = SCATTER_PROFILE
	return profile if profile != null and profile.is_valid() and int(profile.damage_type) == direction else null


func _direction_is_valid(direction: int) -> bool:
	return direction == int(WeaponProfile.DamageType.ARMOR_PIERCING) \
		or direction == int(WeaponProfile.DamageType.SCATTER)


func _is_attack_organ(organ: Variant) -> bool:
	return typeof(organ) == TYPE_OBJECT and is_instance_valid(organ) and organ is AttackOrgan


func _node_is_live(node: Variant) -> bool:
	return typeof(node) == TYPE_OBJECT and is_instance_valid(node) and node is Node \
		and not node.is_queued_for_deletion() and node.is_inside_tree() and node.is_node_ready()


func _watch_current(record: Record) -> void:
	_disconnect_watched_nodes()
	var callback: Callable = _on_owned_node_tree_exiting.bind(record.task_id)
	for node: Node in [record.get_organ(), record.get_host(), record.get_weapon()]:
		node.tree_exiting.connect(callback)
		_watched_nodes.append({"node": weakref(node), "signal": &"tree_exiting", "callback": callback})
	var host: HyphaNode = record.get_host()
	callback = _on_host_slot_changed.bind(record.task_id)
	host.organ_slot_changed.connect(callback)
	_watched_nodes.append({"node": weakref(host), "signal": &"organ_slot_changed", "callback": callback})


func _disconnect_watched_nodes() -> void:
	var bindings: Array[Dictionary] = _watched_nodes.duplicate()
	_watched_nodes.clear()
	for binding: Dictionary in bindings:
		var reference: WeakRef = binding["node"]
		var node: Node = reference.get_ref() as Node
		var callback: Callable = binding["callback"]
		var signal_name: StringName = binding["signal"]
		if is_instance_valid(node) and node.is_connected(signal_name, callback):
			node.disconnect(signal_name, callback)


func _bind_network() -> void:
	if _watched_network != network_system:
		_disconnect_network()
		_watched_network = network_system if _node_is_live(network_system) else null
		if _watched_network != null:
			_watched_network.network_changed.connect(_on_network_changed)


func _disconnect_network() -> void:
	if is_instance_valid(_watched_network) and _watched_network.network_changed.is_connected(_on_network_changed):
		_watched_network.network_changed.disconnect(_on_network_changed)
	_watched_network = null


func _publish_record(record: Record) -> void:
	if record == null:
		return
	if not _pending_records.has(record):
		_pending_records.append(record)
	if _notifying:
		return
	_notifying = true
	while not _pending_records.is_empty():
		var publishing: Record = _pending_records.pop_front()
		var snapshot: Dictionary = _snapshot_for(publishing)
		if publishing.is_active():
			_attempt_snapshots[publishing.task_id] = snapshot.duplicate()
		task_changed.emit(snapshot.duplicate())
		var organ: AttackOrgan = publishing.get_organ()
		if _node_is_live(organ):
			organ.differentiation_changed.emit(_snapshot_for(publishing))
	_notifying = false


func abort_destroyed_organ(organ: AttackOrgan) -> bool:
	if _current == null or _current.get_organ() != organ or not has_active_task():
		return false
	return _cancel_current(true)
