class_name CultivationSystem
extends Node
## 一个成熟菌结保留一个器官芽；仅花费已投递营养，取消后的结构和付费阶段可继续。

signal task_changed(snapshot: Dictionary)
signal task_cancelled(task_id: int)
signal task_completed(task_id: int)
signal organ_matured(task_id: int, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon)
signal digestive_matured(task_id: int, host: HyphaNode, organ: DigestiveOrgan)

const TOTAL_COST: int = 12
const STRUCTURE_COST: int = 8
const STARTUP_COST: int = 4
const DIGESTIVE_TOTAL_COST: int = 8
const MINIMUM_EFFECTIVE_TIME: float = 3.0
const STAGE_TIME: float = MINIMUM_EFFECTIVE_TIME / float(STRUCTURE_COST)
const MAX_TASK_ID: int = 9223372036854775807
const SUPPLY_WAIT_REASONS: Array[StringName] = [
	&"", &"nutrition", &"in_transit", &"core_empty", &"combat_reserve", &"repair_budget",
	&"disconnected", &"invalid_configuration", &"core_unavailable", &"paused",
]

class BudRecord:
	extends RefCounted

	var organ_kind: StringName = &"attack"
	var total_cost: int = 12
	var structure_cost: int = 8
	var startup_cost: int = 4
	var minimum_time: float = 3.0
	var bud_id: String = ""
	var bud: OrganBud = null
	var host: HyphaNode = null
	var task_id: int = 0
	var state: StringName = &"waiting"
	var wait_reason: StringName = &"nutrition"
	var supply_wait_reason: StringName = &""
	var effective_time: float = 0.0
	var structure_consumed: int = 0
	var buffered_nutrition: int = 0
	var startup_reserved: int = 0
	var startup_transferred: int = 0
	var stage_paid: bool = false
	var stage_elapsed: float = 0.0
	var can_progress: bool = false
	var host_exit_callback: Callable
	var bud_exit_callback: Callable

@export var network_system: NetworkSystem
@export var growth_system: GrowthSystem
@export var enemy_container: Node2D
@export var projectile_container: Node2D
@export var bud_scene: PackedScene = preload("res://scenes/colony/organ_bud.tscn")
@export var attack_organ_scene: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
@export var digestive_organ_scene: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
@export var weapon_scene: PackedScene = preload("res://scenes/combat/spore_weapon.tscn")
@export var weapon_attack_range: float = 100.0
@export var normal_weapon_profile: WeaponProfile

var _last_task_id: int = 0
var _last_bud_id: int = 0
var _last_reservation_id: int = 0
var _task_id: int = 0
var _current: BudRecord = null
var _materializing: BudRecord = null
var _materialization_invalid: bool = false
var _buds: Dictionary[String, BudRecord] = {}
var _task_bud_ids: Dictionary[int, String] = {}
var _attempt_snapshots: Dictionary[int, Dictionary] = {}
var _shipments: Dictionary[String, bool] = {}
var _scene_validations: Dictionary[StringName, Dictionary] = {}
var _watched_network: NetworkSystem = null
var _transitioning: bool = false
var _resetting: bool = false
var _advancing: bool = false
var _refreshing: bool = false
var _emitting_changed: bool = false
var _changed_pending: bool = false


func _ready() -> void:
	_bind_network()


func _physics_process(delta: float) -> void:
	advance(delta)


func _on_network_changed() -> void:
	if _transitioning or _refreshing or _resetting:
		_changed_pending = true
	elif _refresh_current_state():
		_publish_changed()


func _on_owned_node_tree_exiting(bud_id: String) -> void:
	if not _buds.has(bud_id):
		return
	var record: BudRecord = _buds[bud_id]
	if record == _materializing:
		# 草稿器官持有启动营养时先回滚，再通知运输系统退款。
		_materialization_invalid = true
	elif record == _current and has_active_task():
		_cancel_current(true)


static func get_recipe(organ_kind: StringName) -> Dictionary:
	if organ_kind == &"digestive":
		return {
			"organ_kind": &"digestive", "total_cost": DIGESTIVE_TOTAL_COST,
			"structure_cost": STRUCTURE_COST, "startup_cost": 0,
			"minimum_time": MINIMUM_EFFECTIVE_TIME,
		}
	if organ_kind == &"attack" or organ_kind == &"":
		return {
			"organ_kind": &"attack", "total_cost": TOTAL_COST,
			"structure_cost": STRUCTURE_COST, "startup_cost": STARTUP_COST,
			"minimum_time": MINIMUM_EFFECTIVE_TIME,
		}
	return {}


func get_cultivation_availability(host: HyphaNode, organ_kind: StringName = &"") -> StringName:
	if not _node_is_available(host):
		return &"no_selection"
	if has_active_task() or (_node_is_available(growth_system) and growth_system.has_active_task()):
		return &"construction_busy"
	var record: BudRecord = _find_owned_bud(host)
	if record == null and not host.is_organ_slot_available():
		return &"occupied"
	if record != null and (record.state != &"cancelled" or not _slot_contains_only_bud(record)):
		return &"occupied"
	if _has_pending_settlement():
		return &"settlement_pending"
	# 已有芽的继续请求只能使用当初冻结的配方，宿主重建标记不再影响它。
	var resolved_kind: StringName = record.organ_kind if record != null else _resolve_kind(host, organ_kind)
	if _last_task_id == MAX_TASK_ID or not _configuration_is_valid(resolved_kind):
		return &"invalid_configuration"
	if not network_system.is_work_connected_to_core(host):
		return &"disconnected"
	# 网络查询可能注销失效节点并同步进入本系统，故再核对占位和建造请求。
	if not _node_is_available(host):
		return &"no_selection"
	if has_active_task() or (_node_is_available(growth_system) and growth_system.has_active_task()):
		return &"construction_busy"
	if record != null:
		return &"continuable" if _slot_contains_only_bud(record) else &"occupied"
	return &"ready" if host.is_organ_slot_available() else &"occupied"


func start_cultivation(host: HyphaNode, organ_kind: StringName = &"") -> int:
	if _transitioning or _resetting or _advancing or _emitting_changed or not _node_is_available(host):
		return 0
	_transitioning = true
	var admitted_kind: StringName = _resolve_kind(host, organ_kind)
	var availability: StringName = get_cultivation_availability(host, admitted_kind)
	if availability != &"ready":
		_transitioning = false
		return 0
	var recipe: Dictionary = get_recipe(admitted_kind)
	var instance: Node = bud_scene.instantiate()
	if not instance is OrganBud:
		_discard_node(instance)
		_transitioning = false
		return 0
	var new_bud: OrganBud = instance as OrganBud
	var reservation_id: String = _new_reservation_id()
	if not host.try_reserve_organ_slot(reservation_id):
		_discard_node(new_bud)
		_transitioning = false
		return 0
	if not _node_is_available(host):
		if is_instance_valid(host):
			host.release_organ_slot(reservation_id)
		_discard_node(new_bud)
		_transitioning = false
		return 0

	_last_task_id += 1
	_last_bud_id += 1
	var record: BudRecord = BudRecord.new()
	record.bud_id = "bud:%d:%d" % [get_instance_id(), _last_bud_id]
	record.bud = new_bud
	record.host = host
	record.organ_kind = StringName(recipe["organ_kind"])
	record.total_cost = int(recipe["total_cost"])
	record.structure_cost = int(recipe["structure_cost"])
	record.startup_cost = int(recipe["startup_cost"])
	record.minimum_time = float(recipe["minimum_time"])
	record.task_id = _last_task_id
	_buds[record.bud_id] = record
	_task_bud_ids[record.task_id] = record.bud_id
	_current = record
	_task_id = record.task_id
	_watch_record(record)
	_sync_record(record)
	host.add_child(new_bud)
	var committed: bool = _node_is_available(host) and _node_is_available(new_bud) \
		and host.commit_organ_slot(reservation_id, new_bud)
	if not committed or not has_active_task():
		if is_instance_valid(host):
			host.release_organ_slot(reservation_id)
		_cancel_current(true)
		_disconnect_record(record)
		record.bud = null
		_discard_node(new_bud)
		_transitioning = false
		return 0

	var created_task_id: int = record.task_id
	_transitioning = false
	_refresh_current_state()
	_publish_changed()
	return created_task_id


func continue_cultivation(host: HyphaNode) -> int:
	if _transitioning or _resetting or _advancing or _emitting_changed:
		return 0
	_transitioning = true
	if get_cultivation_availability(host) != &"continuable":
		_transitioning = false
		return 0
	var record: BudRecord = _find_owned_bud(host)
	# 上一尝试先完整冻结；新尝试沿用芽的付费阶段，而不是共享旧快照。
	_sync_record(record)
	_last_task_id += 1
	record.task_id = _last_task_id
	record.state = &"waiting"
	record.wait_reason = &"nutrition"
	record.supply_wait_reason = &""
	_current = record
	_task_id = record.task_id
	_task_bud_ids[record.task_id] = record.bud_id
	# 新身份须先有可查询的快照，供养与输入的同步通知才能识别这一尝试。
	_sync_record(record)
	var created_task_id: int = record.task_id
	_transitioning = false
	_refresh_current_state()
	_publish_changed()
	return created_task_id


func pause_task() -> bool:
	if not has_active_task() or _current.state == &"paused" or _transitioning or _resetting:
		return false
	_current.state = &"paused"
	_current.wait_reason = &"paused"
	_publish_changed()
	return true


func resume_task() -> bool:
	if not has_active_task() or _current.state != &"paused" or _transitioning or _resetting:
		return false
	_current.state = &"waiting"
	_refresh_current_state()
	_publish_changed()
	return true


func cancel_task() -> bool:
	return _cancel_current(false)


func has_active_task() -> bool:
	return _current != null and _current.task_id == _task_id \
		and (_current.state == &"waiting" or _current.state == &"cultivating" or _current.state == &"paused")


func get_task_snapshot(task_id: int = 0) -> Dictionary:
	var queried_id: int = _task_id if task_id == 0 else task_id
	if queried_id == 0:
		return _idle_snapshot()
	if not _attempt_snapshots.has(queried_id):
		return {}
	if _current != null and queried_id == _current.task_id:
		_refresh_current_state()
		if _current != null and queried_id == _current.task_id:
			_sync_record(_current)
	var snapshot: Dictionary = _attempt_snapshots[queried_id].duplicate()
	if not _node_is_available(snapshot["host"]):
		snapshot["host"] = null
	return snapshot


func get_bud_snapshot(host: HyphaNode) -> Dictionary:
	var record: BudRecord = _find_owned_bud(host)
	if record == null:
		return {}
	if record == _current:
		_refresh_current_state()
	_sync_record(record)
	return record.bud.get_snapshot() if _node_is_available(record.bud) else {}


func get_resource_snapshot() -> Dictionary:
	var structure: int = 0
	var buffered: int = 0
	var startup: int = 0
	# 按唯一芽记账，历史尝试只作为审计快照，不能再次计入资源总量。
	for record: BudRecord in _buds.values():
		structure += record.structure_consumed
		buffered += record.buffered_nutrition
		startup += record.startup_reserved
	return {"structure_consumed": structure, "buffered_nutrition": buffered, "startup_reserved": startup}


func get_total_structure_consumed() -> int:
	return int(get_resource_snapshot()["structure_consumed"])


func get_startup_transferred_nutrition() -> int:
	var transferred: int = 0
	for record: BudRecord in _buds.values():
		transferred += record.startup_transferred
	return transferred


func get_delivery_target(task_id: int) -> HyphaNode:
	if task_id != _task_id or not has_active_task() or not _record_nodes_are_available(_current):
		return null
	return _current.host


func get_requested_nutrition(task_id: int) -> int:
	if task_id != _task_id or not has_active_task():
		return 0
	_refresh_current_state()
	return _requested_for(_current) if has_active_task() and task_id == _task_id else 0


func receive_nutrition(task_id: int, shipment_id: String, amount: int) -> bool:
	if task_id != _task_id or not has_active_task() or _transitioning or _resetting \
			or shipment_id.is_empty() or amount <= 0 or _shipments.has(shipment_id):
		return false
	if not _record_nodes_are_available(_current) or amount > _unfunded_nutrition(_current):
		return false
	# 已付费到货可以进入暂停任务；先登记和入账，再公开任何同步回调。
	_shipments[shipment_id] = true
	_current.buffered_nutrition += amount
	_refresh_current_state()
	_publish_changed()
	return true


func take_unspent_nutrition(task_id: int) -> int:
	if not _attempt_snapshots.has(task_id) or not _task_bud_ids.has(task_id):
		return 0
	var snapshot: Dictionary = _attempt_snapshots[task_id]
	if snapshot["state"] != &"cancelled" and snapshot["state"] != &"completed":
		return 0
	var record: BudRecord = _buds[_task_bud_ids[task_id]]
	if record.task_id != task_id:
		return 0
	var unspent: int = record.buffered_nutrition + record.startup_reserved
	if unspent == 0:
		return 0
	record.buffered_nutrition = 0
	record.startup_reserved = 0
	_sync_record(record)
	_publish_changed()
	return unspent


func set_supply_wait_reason(task_id: int, reason: StringName) -> void:
	if task_id != _task_id or not has_active_task() or not SUPPLY_WAIT_REASONS.has(reason):
		return
	if _current.supply_wait_reason == reason:
		return
	_current.supply_wait_reason = reason
	if _refresh_current_state():
		_publish_changed()


func advance(delta: float) -> void:
	if not has_active_task() or _advancing or _transitioning or _resetting \
			or not is_finite(delta) or delta <= 0.0:
		return
	_advancing = true
	var advancing_task_id: int = _task_id
	var remaining_time: float = delta
	while _is_advancing_task(advancing_task_id):
		if _refresh_current_state():
			_publish_changed()
		if not _can_advance(advancing_task_id):
			break
		var record: BudRecord = _current
		if record.structure_consumed < record.structure_cost or record.stage_paid:
			if not record.stage_paid:
				if remaining_time <= 0.0 or record.buffered_nutrition < 1:
					break
				record.buffered_nutrition -= 1
				record.structure_consumed += 1
				record.stage_paid = true
				record.stage_elapsed = 0.0
				_refresh_current_state()
				_publish_changed()
			if not _can_advance(advancing_task_id) or remaining_time <= 0.0:
				break
			var stage_time: float = record.minimum_time / float(record.structure_cost)
			var elapsed: float = minf(stage_time - record.stage_elapsed, remaining_time)
			record.stage_elapsed += elapsed
			record.effective_time = minf(record.minimum_time, record.effective_time + elapsed)
			remaining_time = maxf(0.0, remaining_time - elapsed)
			if record.stage_elapsed >= stage_time:
				record.stage_paid = false
				record.stage_elapsed = 0.0
				if record.structure_consumed == record.structure_cost:
					record.effective_time = record.minimum_time
			_refresh_current_state()
			_publish_changed()
		else:
			var reserve: int = mini(record.startup_cost - record.startup_reserved, record.buffered_nutrition)
			if reserve > 0:
				record.buffered_nutrition -= reserve
				record.startup_reserved += reserve
				_refresh_current_state()
				_publish_changed()
			if _can_advance(advancing_task_id) and record.startup_reserved == record.startup_cost \
					and record.effective_time >= record.minimum_time:
				_mature_current(record)
			break
	_advancing = false


func reset() -> void:
	if _resetting or _transitioning or _current == null:
		return
	_resetting = true
	_transitioning = true
	_cancel_current(true)
	for record: BudRecord in _buds.values():
		_disconnect_record(record)
		if record.state != &"completed":
			var old_bud: OrganBud = record.bud if _node_is_available(record.bud) else null
			record.bud = null
			_discard_node(old_bud)
		_sync_record(record)
	_current = null
	_transitioning = false
	_resetting = false
	# ID、去重记录、终态快照及已花费结构在本对象生命周期内都不能复用或抹去。
	_publish_changed()


func _cancel_current(force: bool) -> bool:
	if not has_active_task() or (not force and (_transitioning or _resetting)):
		return false
	var cancelled_task_id: int = _current.task_id
	var previous_transition: bool = _transitioning
	_transitioning = true
	_current.state = &"cancelled"
	_current.wait_reason = &""
	_current.supply_wait_reason = &""
	_sync_record(_current)
	_publish_changed()
	# 保留芽和预算；只有运输系统可调用 take_unspent_nutrition 退回原付款母核。
	task_cancelled.emit(cancelled_task_id)
	_transitioning = previous_transition
	return true


func _mature_current(record: BudRecord) -> void:
	if record != _current or not has_active_task() or record.startup_reserved != record.startup_cost \
			or record.structure_consumed != record.structure_cost or record.stage_paid \
			or record.effective_time < record.minimum_time or not _configuration_is_valid(record.organ_kind):
		return
	if record.organ_kind == &"digestive":
		_mature_digestive(record)
		return
	_transitioning = true
	var organ_instance: Node = attack_organ_scene.instantiate()
	var weapon_instance: Node = weapon_scene.instantiate()
	if not _attack_instance_is_valid(organ_instance) or not _weapon_instance_is_valid(weapon_instance):
		_scene_validations.erase(&"attack")
		_scene_validations.erase(&"weapon")
		_discard_node(organ_instance)
		_discard_node(weapon_instance)
		record.wait_reason = &"invalid_configuration"
		record.state = &"waiting"
		_transitioning = false
		_publish_changed()
		return
	var organ: AttackOrgan = organ_instance as AttackOrgan
	var weapon: SporeWeapon = weapon_instance as SporeWeapon
	var reservation_id: String = _new_reservation_id()
	if not _record_nodes_are_available(record) \
			or not record.host.try_reserve_organ_slot(reservation_id, record.bud):
		_discard_node(organ)
		_discard_node(weapon)
		_transitioning = false
		_refresh_current_state()
		_publish_changed()
		return
	if not _record_nodes_are_available(record) or not has_active_task() \
			or not _node_is_available(network_system) or not network_system.is_work_connected_to_core(record.host):
		if is_instance_valid(record.host):
			record.host.release_organ_slot(reservation_id)
		_discard_node(organ)
		_discard_node(weapon)
		_transitioning = false
		_refresh_current_state()
		_publish_changed()
		return

	var original_organ_mode: Node.ProcessMode = organ.process_mode
	var original_weapon_mode: Node.ProcessMode = weapon.process_mode
	organ.process_mode = Node.PROCESS_MODE_DISABLED
	weapon.process_mode = Node.PROCESS_MODE_DISABLED
	# _ready 读取的就是这笔已付费分配；没有额外赠送的默认库存。
	organ.initial_nutrition = record.startup_cost
	organ.nutrition = record.startup_cost
	organ.incoming_nutrition = 0
	weapon.inventory_owner = organ
	weapon.enemy_container = enemy_container
	weapon.projectile_container = projectile_container
	weapon.position = Vector2(0.0, -28.0)
	if normal_weapon_profile != null:
		weapon.configure_profile(normal_weapon_profile)
	else:
		weapon.attack_range = weapon_attack_range
	_materializing = record
	_materialization_invalid = false
	# 四点营养暂由禁用的草稿器官持有，消费历史仍为八点结构。
	# 同步查询不能看见尚未提交、日后又回滚的 startup_transferred。
	record.startup_reserved = 0
	_sync_record(record)
	var host: HyphaNode = record.host
	host.add_child(organ)
	if _node_is_available(host) and _node_is_available(organ):
		host.add_child(weapon)
	var committed: bool = _node_is_available(host) and _node_is_available(organ) \
		and _node_is_available(weapon) and weapon.get_parent() == host \
		and not _materialization_invalid \
		and _node_is_available(network_system) and network_system.is_work_connected_to_core(host) \
		and host.commit_organ_slot(reservation_id, organ)
	committed = committed and not _materialization_invalid and _node_is_available(host) \
		and _node_is_available(organ) and organ.get_parent() == host \
		and _node_is_available(weapon) and weapon.get_parent() == host
	if not committed:
		# 入树回调可删除宿主或人工加器官；失败时启动资金仍归芽且可退款。
		_discard_node(organ)
		_discard_node(weapon)
		record.startup_transferred = 0
		record.startup_reserved = record.startup_cost
		record.state = &"waiting"
		_materializing = null
		_materialization_invalid = false
		_sync_record(record)
		if is_instance_valid(host):
			host.release_organ_slot(reservation_id)
		_transitioning = false
		_refresh_current_state()
		_publish_changed()
		return

	organ.set_meta("cultivation_committed", true)
	if host.has_meta("rebuild_digestive"):
		host.remove_meta("rebuild_digestive")
	var matured_task_id: int = record.task_id
	var old_bud: OrganBud = record.bud
	record.startup_transferred = record.startup_cost
	record.state = &"completed"
	record.wait_reason = &""
	record.supply_wait_reason = &""
	_materializing = null
	_materialization_invalid = false
	_disconnect_record(record)
	record.bud = null
	_discard_node(old_bud)
	organ.process_mode = original_organ_mode
	weapon.process_mode = original_weapon_mode
	_sync_record(record)
	_transitioning = false
	_publish_changed()
	organ_matured.emit(matured_task_id, host, organ, weapon)
	task_completed.emit(matured_task_id)


func _refresh_current_state() -> bool:
	if not has_active_task() or _transitioning or _refreshing:
		return false
	_refreshing = true
	var record: BudRecord = _current
	var checked_task_id: int = record.task_id
	var previous_state: StringName = record.state
	var previous_reason: StringName = record.wait_reason
	if not _record_nodes_are_available(record):
		_refreshing = false
		return _cancel_current(true)
	var configured: bool = _configuration_is_valid(record.organ_kind)
	var connected: bool = false
	if configured and record.state != &"paused":
		connected = network_system.is_work_connected_to_core(record.host)
	if _current != record or _task_id != checked_task_id or not has_active_task():
		_refreshing = false
		return false
	if not _record_nodes_are_available(record):
		_refreshing = false
		return _cancel_current(true)
	# 外部供养的等待文案不是本地可推进条件，否则恢复运输配置后会一直请求零营养。
	var owns_slot: bool = _slot_contains_only_bud(record)
	record.can_progress = configured and connected and owns_slot and record.state != &"paused"
	if record.state == &"paused":
		record.wait_reason = &"paused"
	elif not configured:
		record.state = &"waiting"
		record.wait_reason = &"invalid_configuration"
	elif not connected:
		record.state = &"waiting"
		record.wait_reason = &"disconnected"
	elif not owns_slot:
		record.state = &"waiting"
		record.wait_reason = &"occupied"
	elif record.stage_paid or (record.structure_consumed < record.structure_cost and record.buffered_nutrition > 0) \
			or (record.structure_consumed == record.structure_cost \
				and record.buffered_nutrition + record.startup_reserved >= record.startup_cost):
		record.state = &"cultivating"
		record.wait_reason = &""
	else:
		record.state = &"waiting"
		record.wait_reason = record.supply_wait_reason if record.supply_wait_reason != &"" else &"nutrition"
	_refreshing = false
	return previous_state != record.state or previous_reason != record.wait_reason


func _can_advance(task_id: int) -> bool:
	_refresh_current_state()
	return _is_advancing_task(task_id) and _record_nodes_are_available(_current) \
		and _current.can_progress


func _is_advancing_task(task_id: int) -> bool:
	return _task_id == task_id and has_active_task() and _current.state != &"paused" \
		and not _transitioning and not _resetting


func _requested_for(record: BudRecord) -> int:
	if record == null or record != _current or not has_active_task() or record.state == &"paused" \
			or _transitioning or _resetting or not record.can_progress:
		return 0
	return _unfunded_nutrition(record)


func _unfunded_nutrition(record: BudRecord) -> int:
	return maxi(0, record.total_cost - record.structure_consumed - record.buffered_nutrition \
		- record.startup_reserved - record.startup_transferred)


func _sync_record(record: BudRecord) -> void:
	var snapshot: Dictionary = _snapshot_for(record)
	_attempt_snapshots[record.task_id] = snapshot
	if _node_is_available(record.bud):
		record.bud._set_snapshot(snapshot)


func _snapshot_for(record: BudRecord) -> Dictionary:
	var consumed: int = record.structure_consumed + record.startup_transferred
	return {
		"task_id": record.task_id,
		"bud_id": record.bud_id,
		"organ_kind": record.organ_kind,
		"host": record.host if _node_is_available(record.host) else null,
		"state": record.state,
		"wait_reason": record.wait_reason,
		"progress": clampf(record.effective_time / record.minimum_time, 0.0, 1.0),
		"effective_time": record.effective_time,
		"minimum_time": record.minimum_time,
		"total_cost": record.total_cost,
		"structure_cost": record.structure_cost,
		"startup_cost": record.startup_cost,
		"structure_consumed": record.structure_consumed,
		"buffered_nutrition": record.buffered_nutrition,
		"startup_reserved": record.startup_reserved,
		"startup_transferred": record.startup_transferred,
		"consumed_nutrition": consumed,
		"remaining_cost": record.total_cost - consumed,
		"requested_nutrition": _requested_for(record),
	}


func _idle_snapshot() -> Dictionary:
	var snapshot: Dictionary = _snapshot_for(BudRecord.new())
	snapshot["state"] = &"idle"
	snapshot["wait_reason"] = &""
	return snapshot


func _find_owned_bud(host: HyphaNode) -> BudRecord:
	if not _node_is_available(host):
		return null
	var bud: OrganBud = host.get_organ_bud()
	if not _node_is_available(bud):
		return null
	for record: BudRecord in _buds.values():
		if record.bud == bud and record.host == host:
			return record
	return null


func _record_nodes_are_available(record: BudRecord) -> bool:
	return record != null and _node_is_available(record.host) and _node_is_available(record.bud) \
		and record.bud.get_parent() == record.host and record.bud.is_attackable()


func _slot_contains_only_bud(record: BudRecord) -> bool:
	if not _record_nodes_are_available(record) or record.host.get_organ_occupant() != record.bud:
		return false
	var occupants: int = 0
	for child: Node in record.host.get_children():
		if _node_is_available(child) and (child is OrganBud or child is AttackOrgan or child is DigestiveOrgan):
			occupants += 1
	return occupants == 1 and record.host.get_organ_slot_state() == &"bud"


func _has_pending_settlement() -> bool:
	for record: BudRecord in _buds.values():
		if (record.state == &"cancelled" or record.state == &"completed") \
				and record.buffered_nutrition + record.startup_reserved > 0:
			return true
	return false


func _resolve_kind(host: HyphaNode, organ_kind: StringName) -> StringName:
	if organ_kind != &"":
		return organ_kind
	return &"digestive" if bool(host.get_meta("rebuild_digestive", false)) else &"attack"


func _configuration_is_valid(organ_kind: StringName = &"attack") -> bool:
	_bind_network()
	if not _node_is_available(network_system) or not _scene_is_valid(bud_scene, &"bud"):
		return false
	if organ_kind == &"digestive":
		return _scene_is_valid(digestive_organ_scene, &"digestive")
	return organ_kind == &"attack" and _node_is_available(enemy_container) \
		and _node_is_available(projectile_container) and _weapon_configuration_is_valid() \
		and _scene_is_valid(attack_organ_scene, &"attack") and _scene_is_valid(weapon_scene, &"weapon")


func _weapon_configuration_is_valid() -> bool:
	if normal_weapon_profile != null:
		return normal_weapon_profile.is_valid() \
			and normal_weapon_profile.damage_type == WeaponProfile.DamageType.NORMAL
	return is_finite(weapon_attack_range) and weapon_attack_range > 0.0


func _scene_is_valid(scene: PackedScene, kind: StringName) -> bool:
	if scene == null or not scene.can_instantiate():
		return false
	if _scene_validations.has(kind) and _scene_validations[kind]["scene"] == scene:
		return bool(_scene_validations[kind]["valid"])
	# 只在配置资源变更时验证树外实例；它们不会执行 _ready 或开始战斗。
	var instance: Node = scene.instantiate()
	var valid: bool = false
	match kind:
		&"bud":
			valid = instance is OrganBud
		&"attack":
			valid = _attack_instance_is_valid(instance)
		&"weapon":
			valid = _weapon_instance_is_valid(instance)
		&"digestive":
			valid = instance is DigestiveOrgan and instance.get_node_or_null("DigestTimer") is Timer \
				and instance.get_node_or_null("SecondDigestTimer") is Timer \
				and instance.get_node_or_null("ChamberExpansionTimer") is Timer
	_discard_node(instance)
	_scene_validations[kind] = {"scene": scene, "valid": valid}
	return valid


func _attack_instance_is_valid(instance: Node) -> bool:
	return instance is AttackOrgan and instance.capacity >= STARTUP_COST \
		and instance.get_node_or_null("InventorySlots") is HBoxContainer \
		and instance.get_node_or_null("Cap") is Polygon2D


func _weapon_instance_is_valid(instance: Node) -> bool:
	return instance is SporeWeapon and instance.projectile_scene != null \
		and instance.get_node_or_null("RangeOutline") is Line2D \
		and instance.get_node_or_null("Muzzle") is Polygon2D \
		and instance.get_node_or_null("FireTimer") is Timer


func _bind_network() -> void:
	if _watched_network == network_system:
		return
	if _node_is_available(_watched_network) and _watched_network.network_changed.is_connected(_on_network_changed):
		_watched_network.network_changed.disconnect(_on_network_changed)
	_watched_network = network_system if _node_is_available(network_system) else null
	if _node_is_available(_watched_network):
		_watched_network.network_changed.connect(_on_network_changed)


func _watch_record(record: BudRecord) -> void:
	record.host_exit_callback = _on_owned_node_tree_exiting.bind(record.bud_id)
	record.bud_exit_callback = _on_owned_node_tree_exiting.bind(record.bud_id)
	record.host.tree_exiting.connect(record.host_exit_callback)
	record.bud.tree_exiting.connect(record.bud_exit_callback)


func _disconnect_record(record: BudRecord) -> void:
	if is_instance_valid(record.host) and record.host.tree_exiting.is_connected(record.host_exit_callback):
		record.host.tree_exiting.disconnect(record.host_exit_callback)
	if is_instance_valid(record.bud) and record.bud.tree_exiting.is_connected(record.bud_exit_callback):
		record.bud.tree_exiting.disconnect(record.bud_exit_callback)


func _new_reservation_id() -> String:
	_last_reservation_id += 1
	return "cultivation:%d:%d" % [get_instance_id(), _last_reservation_id]


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion()


func _discard_node(node: Node) -> void:
	if is_instance_valid(node):
		node.queue_free()


func _publish_changed() -> void:
	_changed_pending = true
	if _emitting_changed:
		return
	_emitting_changed = true
	while _changed_pending:
		_changed_pending = false
		task_changed.emit(get_task_snapshot())
	_emitting_changed = false


## 死亡不能沿用可继续的旧芽；未消费缓存由既有供养账本结算一次。
func abort_destroyed_bud(bud: OrganBud) -> bool:
	if not is_instance_valid(bud):
		return false
	var matched: bool = false
	for record: BudRecord in _buds.values():
		if record.bud != bud:
			continue
		matched = true
		if record == _materializing:
			_materialization_invalid = true
		if record == _current and has_active_task():
			_cancel_current(true)
		_disconnect_record(record)
		record.bud = null
		_sync_record(record)
	return matched


## 新建与重建共用已付费的八份结构和三秒时钟；胃囊无启动库存。
func _mature_digestive(record: BudRecord) -> void:
	if record != _current or not has_active_task() or not _record_nodes_are_available(record) \
			or not record.host.is_functional():
		return
	_transitioning = true
	var host: HyphaNode = record.host
	var reservation_id: String = _new_reservation_id()
	if not host.try_reserve_organ_slot(reservation_id, record.bud):
		_transitioning = false
		return
	if not _record_nodes_are_available(record) or not has_active_task() \
			or not _node_is_available(network_system) or not network_system.is_work_connected_to_core(host):
		if is_instance_valid(host):
			host.release_organ_slot(reservation_id)
		_transitioning = false
		_refresh_current_state()
		_publish_changed()
		return
	var instance: Node = digestive_organ_scene.instantiate()
	if not instance is DigestiveOrgan:
		_scene_validations.erase(&"digestive")
		_discard_node(instance)
		if is_instance_valid(host):
			host.release_organ_slot(reservation_id)
		_transitioning = false
		_refresh_current_state()
		_publish_changed()
		return
	var organ: DigestiveOrgan = instance as DigestiveOrgan
	organ.name = "DigestiveOrgan"
	organ.mother_core = network_system.peek_registered_core() as MotherCore
	var previous_mode: Node.ProcessMode = organ.process_mode
	organ.process_mode = Node.PROCESS_MODE_DISABLED
	_materializing = record
	_materialization_invalid = false
	host.add_child(organ)
	var committed: bool = not _materialization_invalid and _record_nodes_are_available(record) \
		and _node_is_available(organ) and organ.is_attackable() and host.is_functional() \
		and _node_is_available(network_system) and network_system.is_work_connected_to_core(host) \
		and host.commit_organ_slot(reservation_id, organ)
	committed = committed and not _materialization_invalid and _node_is_available(host) \
		and _node_is_available(organ) and organ.get_parent() == host and organ.is_functional()
	_materializing = null
	_materialization_invalid = false
	if not committed:
		_discard_node(organ)
		if is_instance_valid(host):
			host.release_organ_slot(reservation_id)
		_transitioning = false
		_refresh_current_state()
		_publish_changed()
		return
	var completed_id: int = record.task_id
	var old_bud: OrganBud = record.bud
	organ.set_meta("cultivation_committed", true)
	record.state = &"completed"
	record.wait_reason = &""
	record.supply_wait_reason = &""
	_disconnect_record(record)
	record.bud = null
	_discard_node(old_bud)
	if host.has_meta("rebuild_digestive"):
		host.remove_meta("rebuild_digestive")
	organ.process_mode = previous_mode
	_sync_record(record)
	_transitioning = false
	_publish_changed()
	digestive_matured.emit(completed_id, host, organ)
	task_completed.emit(completed_id)
