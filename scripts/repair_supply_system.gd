class_name RepairSupplySystem
extends Node
## 修复预留不产生资源；真实一单位营养包仍通过同一交通调度器运到固定施工点。

signal supply_changed(snapshot: Dictionary)
signal notice(message: String)

const PACKET_NUTRITION: int = 1
const DEFAULT_PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
const MAX_SERIAL: int = 9223372036854775807

class TaskAccount:
	extends RefCounted

	var receiver: RepairSystem
	var receiver_id: int = 0
	var task_id: int = 0
	var source: MotherCore
	var source_id: int = 0
	var network: NetworkSystem
	var target: Node2D
	var target_id: int = 0
	var edge: HyphaEdge
	var edge_id: int = 0
	var point: Node2D
	var point_id: int = 0
	var budget_key: String = ""
	var generation: int = 0
	var reservation_goal: int = 0
	var consumed: int = 0
	var refunded: int = 0
	var lots: Array[Shipment] = []
	var closed: bool = false
	var draining: bool = false
	var last_task_snapshot: Dictionary = {}

class Shipment:
	extends RefCounted

	var cargo_id: String = ""
	var cargo_generation: int = -1
	var cargo_tracker_ref: WeakRef

	var shipment_id: String = ""
	var task_id: int = 0
	var source: MotherCore
	var source_id: int = 0
	var receiver: RepairSystem
	var target: Node2D
	var target_id: int = 0
	var edge: HyphaEdge
	var edge_id: int = 0
	var point: Node2D
	var point_id: int = 0
	var network: NetworkSystem
	var packet: NutrientPacket
	# 系统登记表持有账户；批次只反向弱引用，避免 account.lots 与批次互相保活。
	var account: TaskAccount:
		get:
			return _account_ref.get_ref() as TaskAccount if _account_ref != null else null
		set(value):
			_account_ref = weakref(value) if value != null else null
	var _account_ref: WeakRef
	var transport_task_id: String = ""
	var budget_key: String = ""
	var generation: int = 0
	var nutrition: int = PACKET_NUTRITION
	var started: bool = false
	var debit_pending: bool = false
	var debited: bool = false
	var settled: bool = false
	var accepted: bool = false
	var receiving: bool = false
	var refunded: bool = false
	var refundable: int = 0
	var consumed: int = 0
	var status: StringName = &"reserved"

@export var repair_system: RepairSystem
@export var mother_core: MotherCore
@export var cargo_passage_tracker: CargoPassageTracker
@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var packet_container: Node2D
@export var packet_scene: PackedScene = DEFAULT_PACKET_SCENE
@export var traffic_required: bool = true
@export var auto_supply: bool = true
@export var dispatch_interval: float = 0.35

var _accounts: Dictionary[String, TaskAccount] = {}
var _shipments: Dictionary[String, Shipment] = {}
var _in_transit: Dictionary[String, Shipment] = {}
var _current: TaskAccount
var _receivers: Dictionary[int, RepairSystem] = {}
var _sources: Dictionary[int, MotherCore] = {}
var _networks: Dictionary[int, NetworkSystem] = {}
var _watched_edges: Dictionary[int, HyphaEdge] = {}
var _bindings: Array[Dictionary] = []
var _next_shipment_serial: int = 1
var _generation: int = 0
var _elapsed: float = 0.0
var _refreshing: bool = false
var _refresh_pending: bool = false
var _dispatching: bool = false
var _resetting: bool = false
var _exiting: bool = false
var _dispatch_sealed: bool = false
var _settlement_depth: int = 0
var _emitting_snapshot: bool = false
var _last_snapshot: Dictionary = {}
var _last_notice: String = ""


func _ready() -> void:
	_ensure_receiver_binding(repair_system)
	refresh_budget()


func _process(delta: float) -> void:
	if _exiting or _resetting:
		return
	refresh_budget()
	if auto_supply and not _dispatch_sealed:
		_elapsed += maxf(delta, 0.0)
		var interval: float = maxf(dispatch_interval, 0.001)
		if _elapsed >= interval:
			_elapsed = fmod(_elapsed, interval)
			try_dispatch()


func _exit_tree() -> void:
	_exiting = true
	reset(true)


func _on_task_changed(snapshot: Dictionary, receiver_id: int) -> void:
	var receiver: Variant = _receivers.get(receiver_id)
	if not is_instance_valid(receiver):
		return
	var live_snapshot: Dictionary = receiver.get_task_snapshot()
	if int(live_snapshot.get("task_id", 0)) != int(snapshot.get("task_id", 0)):
		return
	var account: TaskAccount = _accounts.get(_account_key(receiver_id, int(live_snapshot.get("task_id", 0))))
	if account != null:
		_sync_consumption(account, live_snapshot)
		if _is_terminal(live_snapshot):
			_finish_account(account)
	if not _resetting and not _exiting:
		# request_repair 发出的同步通知在任何后续买家行动前建立真实余额锁。
		refresh_budget()


func _on_task_terminal(task_id: int, receiver_id: int) -> void:
	var account: TaskAccount = _accounts.get(_account_key(receiver_id, task_id))
	if account != null:
		_finish_account(account)
	_emit_supply_changed()


func _on_receiver_exiting(receiver_id: int) -> void:
	for account: TaskAccount in _accounts.values():
		if account.receiver_id == receiver_id and not account.closed:
			_stop_account(account)


func _on_source_changed(_snapshot: Dictionary) -> void:
	refresh_budget()


func _on_source_depleted(source_id: int) -> void:
	for account: TaskAccount in _accounts.values():
		if account.source_id == source_id and not account.closed:
			_stop_account(account)
	_emit_supply_changed()


func _on_network_changed() -> void:
	refresh_budget()


func _on_dependency_exiting(node_id: int) -> void:
	for account: TaskAccount in _accounts.values():
		if not account.closed and (account.source_id == node_id or account.target_id == node_id \
				or account.point_id == node_id or _object_id(account.network) == node_id):
			_stop_account(account)
	_emit_supply_changed()


func _on_packet_arrived(packet: NutrientPacket, shipment_id: String) -> void:
	var shipment: Shipment = _in_transit.get(shipment_id)
	if shipment != null and shipment.packet == packet:
		_settle_shipment(shipment, true)


func _on_packet_interrupted(packet: NutrientPacket, shipment_id: String) -> void:
	var shipment: Shipment = _in_transit.get(shipment_id)
	if shipment != null and shipment.packet == packet:
		_settle_shipment(shipment, false)


func _on_packet_exiting(shipment_id: String) -> void:
	var shipment: Shipment = _in_transit.get(shipment_id)
	if shipment != null:
		_settle_shipment(shipment, false)


## 无付款、无私有库存；暂停、不可达和终态只解除尚未付款的目标。
func refresh_budget() -> void:
	if _resetting or _exiting:
		return
	if _refreshing:
		_refresh_pending = true
		return
	_refreshing = true
	_refresh_pending = true
	while _refresh_pending and not _resetting and not _exiting:
		_refresh_pending = false
		_ensure_receiver_binding(repair_system)
		if _current != null and not _current.closed and not _same_configuration(_current):
			_stop_account(_current)
		if _is_live(repair_system):
			repair_system.refresh_access()
			_capture_current_task()
		_sweep_shipments()
		if _current != null and not _current.closed:
			_update_goal(_current)
	_refreshing = false
	_emit_supply_changed()


func try_dispatch() -> bool:
	if _exiting or _resetting or _dispatch_sealed or _dispatching or _settlement_depth > 0:
		return false
	_dispatching = true
	var attempt_generation: int = _generation
	refresh_budget()
	var shipment: Shipment = _dispatch_one()
	refresh_budget()
	_dispatching = false
	return shipment != null and attempt_generation == _generation \
		and (shipment.accepted or (shipment.debited and not shipment.settled))


func get_in_transit_count() -> int:
	return _in_transit.size()


func get_in_transit_nutrition() -> int:
	var amount: int = 0
	for shipment: Shipment in _in_transit.values():
		if shipment.debited and not shipment.settled and not shipment.refunded:
			amount += shipment.nutrition
	return amount


func get_supply_snapshot() -> Dictionary:
	var account: TaskAccount = _current
	var task_snapshot: Dictionary = {}
	if account != null:
		task_snapshot = account.last_task_snapshot
		if _is_live(account.receiver):
			var current_snapshot: Dictionary = account.receiver.get_task_snapshot()
			if int(current_snapshot.get("task_id", 0)) == account.task_id:
				task_snapshot = current_snapshot
	var source: Variant = account.source if account != null else mother_core
	var reserved: int = 0
	var spendable: int = 0
	if is_instance_valid(source) and source is MotherCore:
		spendable = source.get_spendable_nutrition()
		if account != null and not account.closed:
			reserved = source.get_nutrition_reservation(account.budget_key)
	return {
		"task_id": account.task_id if account != null else 0,
		"target": account.target if account != null and is_instance_valid(account.target) else null,
		"target_id": account.target_id if account != null else 0,
		"target_name": task_snapshot.get("target_name", ""),
		"target_kind": task_snapshot.get("target_kind", &""),
		"edge": account.edge if account != null and is_instance_valid(account.edge) else null,
		"edge_id": account.edge_id if account != null else 0,
		"source_core": source if is_instance_valid(source) else null,
		"repair_point": account.point if account != null and is_instance_valid(account.point) else null,
		"reserved_nutrition": reserved,
		"reservation_goal": account.reservation_goal if account != null and not account.closed else 0,
		"spendable_nutrition": spendable,
		"in_transit_nutrition": get_in_transit_nutrition(),
		"buffered_nutrition": int(task_snapshot.get("buffered_nutrition", 0)),
		"consumed_nutrition": account.consumed if account != null else 0,
		"refunded_nutrition": account.refunded if account != null else 0,
		"wait_reason": _get_wait_reason(account, task_snapshot),
		"budget_key": account.budget_key if account != null else "",
		"generation": _generation,
	}


func get_shipment_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for shipment: Shipment in _shipments.values():
		records.append({
			"shipment_id": shipment.shipment_id, "task_id": shipment.task_id,
			"source": shipment.source, "source_core": shipment.source, "source_id": shipment.source_id,
			"target": shipment.target, "target_id": shipment.target_id,
			"edge": shipment.edge, "edge_id": shipment.edge_id,
			"repair_point": shipment.point, "final_target": shipment.point, "point_id": shipment.point_id,
			"receiver": shipment.receiver, "packet": shipment.packet,
			"cargo_id": shipment.cargo_id, "cargo_generation": shipment.cargo_generation,
			"transport_task_id": shipment.transport_task_id, "transport_id": shipment.transport_task_id,
			"budget_key": shipment.budget_key, "generation": shipment.generation,
			"nutrition": shipment.nutrition, "debit_pending": shipment.debit_pending,
			"started": shipment.started, "debited": shipment.debited,
			"settled": shipment.settled, "status": shipment.status,
			"accepted": shipment.accepted, "refunded": shipment.refunded,
			"refundable_nutrition": shipment.nutrition if shipment.debited and not shipment.settled \
				and not shipment.refunded else shipment.refundable,
			"refunded_nutrition": shipment.nutrition if shipment.refunded else 0,
			"buffered_nutrition": shipment.refundable, "consumed_nutrition": shipment.consumed,
		})
	return records


## 先关闭账户和任务，之后退款；保留结算证据，运输序号和代次不复用。
func reset(stop_dispatch: bool = false) -> void:
	if _resetting:
		return
	_resetting = true
	_generation += 1
	_dispatch_sealed = _dispatch_sealed or stop_dispatch
	_ensure_receiver_binding(repair_system)
	for account: TaskAccount in _accounts.values():
		if not account.closed:
			_stop_account(account)
	# 尚未建立账户的外部任务也应取消，不能在 reset 后重新锁回旧任务。
	for receiver: RepairSystem in _receivers.values():
		if _is_live(receiver) and receiver.has_active_task():
			receiver.cancel_task()
	for shipment: Shipment in _in_transit.values():
		_cancel_shipment(shipment)
	_disconnect_bindings()
	_current = null
	_elapsed = 0.0
	_last_snapshot = {}
	_last_notice = ""
	_resetting = false
	if not _exiting:
		_ensure_receiver_binding(repair_system)
		_emit_supply_changed()


func _capture_current_task() -> void:
	if _dispatch_sealed or not _is_live(repair_system) or not repair_system.has_active_task():
		return
	var receiver: RepairSystem = repair_system
	var snapshot: Dictionary = receiver.get_task_snapshot()
	var task_id: int = int(snapshot.get("task_id", 0))
	var key: String = _account_key(receiver.get_instance_id(), task_id)
	var account: TaskAccount = _accounts.get(key)
	if account != null:
		if not account.closed:
			_current = account
		return
	var source: Variant = snapshot.get("source_core")
	var target: Variant = snapshot.get("target", snapshot.get("edge"))
	if task_id <= 0 or not _is_alive_source(source) or not _is_live(target) \
			or not target is Node2D or not _is_live(receiver.network_system):
		return
	if _current != null and not _current.closed:
		_stop_account(_current)
	account = TaskAccount.new()
	account.receiver = receiver
	account.receiver_id = receiver.get_instance_id()
	account.task_id = task_id
	account.source = source as MotherCore
	account.source_id = source.get_instance_id()
	account.target = target as Node2D
	account.target_id = target.get_instance_id()
	account.edge = target as HyphaEdge
	account.edge_id = account.edge.get_instance_id() if account.edge != null else 0
	account.network = receiver.network_system
	account.generation = _generation
	account.budget_key = "repair:%d:%d:%d:%d" % [get_instance_id(), _generation, account.receiver_id, task_id]
	account.last_task_snapshot = snapshot.duplicate()
	account.consumed = int(snapshot.get("consumed_nutrition", 0))
	_accounts[key] = account
	_current = account
	_ensure_source_binding(account.source)
	_ensure_network_binding(account.network)
	_watch_dependency(account.target)
	_assign_point(account, snapshot)
	if not _same_configuration(account):
		_stop_account(account)


func _assign_point(account: TaskAccount, snapshot: Dictionary) -> void:
	if account.point_id != 0:
		return
	var point: Variant = snapshot.get("repair_point")
	if _is_live(point) and point is Node2D:
		account.point = point as Node2D
		account.point_id = point.get_instance_id()
		_watch_dependency(account.point)


func _update_goal(account: TaskAccount) -> void:
	if not _same_active_account(account):
		_stop_account(account)
		return
	var snapshot: Dictionary = account.receiver.get_task_snapshot()
	_sync_consumption(account, snapshot)
	_assign_point(account, snapshot)
	if not _same_identity(account, snapshot):
		_stop_account(account)
		return
	var goal: int = 0
	if StringName(snapshot.get("state", &"idle")) != &"paused" \
			and account.point_id != 0 and bool(snapshot.get("supply_reachable", false)):
		goal = maxi(0, account.receiver.get_requested_nutrition(account.task_id) - _outstanding(account))
	account.reservation_goal = goal
	# 回调内 reset/cancel 先 closed 再 release；外层不在通知后重写任何锁。
	if goal > 0:
		account.source.set_nutrition_reservation(account.budget_key, goal)
	else:
		account.source.release_nutrition_reservation(account.budget_key)


func _dispatch_one() -> Shipment:
	var account: TaskAccount = _current
	if account == null or not _same_active_account(account) or account.reservation_goal < PACKET_NUTRITION:
		return null
	var snapshot: Dictionary = account.receiver.get_task_snapshot()
	if StringName(snapshot.get("state", &"idle")) == &"paused" \
			or not bool(snapshot.get("supply_reachable", false)) or not _same_identity(account, snapshot):
		return null
	if not _transport_configuration_is_valid(account.network, traffic_system, traffic_required) \
			or not _is_live(packet_container) or packet_scene == null:
		_reject("修复供给缺少可用的共享运输配置")
		return null
	if account.source.get_nutrition_reservation(account.budget_key) < PACKET_NUTRITION:
		_reject("修复营养预留正在等待真实营养收入")
		return null
	if _next_shipment_serial >= MAX_SERIAL or not _is_live(account.point) or not _is_live(account.target):
		return null
	var network: NetworkSystem = account.network
	var exclusions: Array[HyphaEdge] = account.receiver.get_delivery_exclusions(account.task_id)
	var route: NetworkRoute = network.find_available_route_avoiding(account.source, account.point, exclusions)
	if not route.found:
		return null
	var container: Node2D = packet_container
	var dispatcher: NetworkTrafficSystem = traffic_system
	var required: bool = traffic_required or dispatcher != null
	var instance: Node = packet_scene.instantiate()
	if not instance is NutrientPacket:
		if is_instance_valid(instance):
			instance.free()
		_reject("修复营养包场景类型不正确")
		return null
	var packet: NutrientPacket = instance as NutrientPacket
	packet.traffic_required = required
	if not _same_active_account(account):
		packet.free()
		return null
	if not packet.set_route_exclusions(exclusions) or not _same_active_account(account):
		packet.free()
		return null
	var shipment: Shipment = Shipment.new()
	shipment.shipment_id = "repair:%d:%d" % [get_instance_id(), _next_shipment_serial]
	_next_shipment_serial += 1
	shipment.task_id = account.task_id
	shipment.source = account.source
	shipment.source_id = account.source_id
	shipment.receiver = account.receiver
	shipment.target = account.target
	shipment.target_id = account.target_id
	shipment.edge = account.edge
	shipment.edge_id = account.edge_id
	shipment.point = account.point
	shipment.point_id = account.point_id
	shipment.network = account.network
	shipment.packet = packet
	shipment.account = account
	shipment.transport_task_id = shipment.shipment_id
	_bind_passage_tracking(shipment)
	shipment.budget_key = account.budget_key
	shipment.generation = _generation
	_shipments[shipment.shipment_id] = shipment
	_in_transit[shipment.shipment_id] = shipment
	packet.arrived.connect(_on_packet_arrived.bind(shipment.shipment_id))
	packet.interrupted.connect(_on_packet_interrupted.bind(shipment.shipment_id))
	packet.tree_exiting.connect(_on_packet_exiting.bind(shipment.shipment_id))
	container.add_child(packet)
	if shipment.settled or not _shipment_can_start(shipment, container, dispatcher, required):
		_cancel_shipment(shipment)
		return shipment
	# 扣款意图与来源先入账，core 提交减额后发出的回调可直接结算此包。
	shipment.debit_pending = true
	shipment.debited = true
	var spent: bool = shipment.source.try_spend_reserved_nutrition(shipment.budget_key, shipment.nutrition)
	shipment.debit_pending = false
	if not spent:
		shipment.debited = false
		_cancel_shipment(shipment)
	elif shipment.settled or not _shipment_can_start(shipment, container, dispatcher, required):
		_cancel_shipment(shipment)
	else:
		shipment.status = &"in_transit"
		shipment.started = true
		packet.start_route(route, network, dispatcher, shipment.transport_task_id, &"supply")
	return shipment


func _shipment_can_start(
	shipment: Shipment, container: Variant, dispatcher: Variant, required: bool
) -> bool:
	return not _resetting and not _exiting and shipment.generation == _generation \
		and _is_live(container) and container == packet_container and _is_live(shipment.packet) \
		and _same_active_account(shipment.account) and _same_shipment_identity(shipment) \
		and _transport_configuration_is_valid(shipment.network, dispatcher, required)


func _settle_shipment(shipment: Shipment, arrived: bool) -> void:
	if shipment.settled:
		return
	if arrived and not _has_arrived(shipment):
		return
	_settlement_depth += 1
	shipment.settled = true
	_in_transit.erase(shipment.shipment_id)
	shipment.status = &"settling"
	var accepted: bool = false
	var account: TaskAccount = shipment.account
	if arrived and shipment.debited and shipment.generation == _generation \
			and _same_active_account(account) and _same_shipment_identity(shipment):
		_sync_consumption(account, shipment.receiver.get_task_snapshot())
		# receive 发出的通知可以同步消费或取消，退款来源必须先登记。
		shipment.refundable = shipment.nutrition
		shipment.receiving = true
		account.lots.append(shipment)
		accepted = shipment.receiver.receive_nutrition(shipment.task_id, shipment.shipment_id, shipment.nutrition)
	shipment.receiving = false
	shipment.accepted = accepted
	if accepted:
		shipment.status = &"refunded" if shipment.refunded else (&"consumed" if shipment.consumed > 0 else &"delivered")
		if is_instance_valid(shipment.receiver):
			var snapshot: Dictionary = shipment.receiver.get_task_snapshot()
			if int(snapshot.get("task_id", 0)) == account.task_id:
				_sync_consumption(account, snapshot)
	else:
		account.lots.erase(shipment)
		shipment.refundable = 0
		_refund_shipment(shipment)
	_settlement_depth -= 1
	refresh_budget()


func _cancel_shipment(shipment: Shipment) -> void:
	if not shipment.settled:
		_settle_shipment(shipment, false)
	var packet: Variant = shipment.packet
	if is_instance_valid(packet):
		packet.cancel_transport()
		if is_instance_valid(packet) and not packet.is_queued_for_deletion():
			packet.queue_free()


func _refund_shipment(shipment: Shipment) -> void:
	if shipment.refunded or shipment.consumed > 0:
		return
	shipment.refundable = 0
	_discard_passage_tracking(shipment)
	if not shipment.debited:
		shipment.status = &"not_debited"
		return
	# 先提交退款标记，add_nutrition 的同步回调不能再次退款。
	shipment.refunded = true
	shipment.status = &"refunded"
	if is_instance_valid(shipment.source):
		shipment.account.refunded += shipment.nutrition
		shipment.source.add_nutrition(shipment.nutrition)
	else:
		shipment.status = &"source_unavailable"


func _finish_account(account: TaskAccount) -> void:
	if account.closed:
		return
	account.closed = true
	account.reservation_goal = 0
	_settlement_depth += 1
	if is_instance_valid(account.source):
		account.source.release_nutrition_reservation(account.budget_key)
	for shipment: Shipment in _in_transit.values():
		if shipment.account == account:
			_cancel_shipment(shipment)
	_drain_buffer(account)
	_settlement_depth -= 1


func _stop_account(account: TaskAccount) -> void:
	if account.closed:
		return
	# 先封闭，cancel 的观察者再请求刷新也无法重新锁回此任务。
	_finish_account(account)
	if is_instance_valid(account.receiver):
		var snapshot: Dictionary = account.receiver.get_task_snapshot()
		if int(snapshot.get("task_id", 0)) == account.task_id and account.receiver.has_active_task():
			account.receiver.cancel_task()
			_drain_buffer(account)


func _drain_buffer(account: TaskAccount) -> void:
	if account.draining:
		return
	account.draining = true
	var remaining: int = 0
	var receiver: Variant = account.receiver
	if is_instance_valid(receiver):
		var snapshot: Dictionary = receiver.get_task_snapshot()
		if int(snapshot.get("task_id", 0)) == account.task_id:
			_sync_consumption(account, snapshot)
			if _is_terminal(snapshot):
				remaining = receiver.take_unspent_nutrition(account.task_id)
				# RepairSystem.reset 可在 take 内切回 idle；保留的终态证据不能显示旧缓冲。
				account.last_task_snapshot["buffered_nutrition"] = 0
	else:
		for lot: Shipment in account.lots:
			remaining += lot.refundable
	for lot: Shipment in account.lots:
		if remaining > 0 and lot.refundable > 0:
			remaining -= lot.refundable
			_refund_shipment(lot)
	account.draining = false


func _sync_consumption(account: TaskAccount, snapshot: Dictionary) -> void:
	if int(snapshot.get("task_id", 0)) != account.task_id:
		return
	account.last_task_snapshot = snapshot.duplicate()
	var consumed: int = int(snapshot.get("consumed_nutrition", account.consumed))
	var remaining: int = maxi(0, consumed - account.consumed)
	account.consumed = maxi(account.consumed, consumed)
	var committed_lots: Array[Shipment] = []
	for lot: Shipment in account.lots:
		if remaining > 0 and lot.refundable > 0:
			var used: int = mini(remaining, lot.refundable)
			lot.refundable -= used
			lot.consumed += used
			remaining -= used
			lot.status = &"consumed"
			if used > 0:
				committed_lots.append(lot)

	# 先完成全部原 FIFO 核销，升级通知再重入也看不到半提交的来源账本。
	for lot: Shipment in committed_lots:
		_confirm_passage_tracking(lot)


func _sweep_shipments() -> void:
	for shipment: Shipment in _in_transit.values():
		if not _same_active_account(shipment.account) or not _same_shipment_identity(shipment) \
				or not _is_live(shipment.packet):
			_cancel_shipment(shipment)
		elif shipment.started and not shipment.packet.is_transport_valid(shipment.point, shipment.transport_task_id):
			# 纯查询允许等待、阻塞和改道，不再扫描已走或尚未走的原路线。
			_cancel_shipment(shipment)


func _outstanding(account: TaskAccount) -> int:
	var amount: int = 0
	for shipment: Shipment in _in_transit.values():
		if shipment.account == account and (shipment.debited or shipment.debit_pending):
			amount += shipment.nutrition
	# receive 可能先刷新访问并发通知、之后才提交 buffer。仅覆盖尚未入 buffer 的到账意图，
	# buffer 已提交后的通知不能又减一次同一包。
	var receiving: int = 0
	var known_buffer: int = 0
	for lot: Shipment in account.lots:
		known_buffer += lot.refundable
		if lot.receiving:
			receiving += lot.refundable
	if receiving > 0 and is_instance_valid(account.receiver):
		var snapshot: Dictionary = account.receiver.get_task_snapshot()
		amount += mini(receiving, maxi(0, known_buffer - int(snapshot.get("buffered_nutrition", 0))))
	return amount


func _same_configuration(account: TaskAccount) -> bool:
	return repair_system == account.receiver and mother_core == account.source \
		and network_system == account.network and _is_live(account.receiver) \
		and account.receiver.network_system == account.network


func _same_active_account(account: TaskAccount) -> bool:
	if account.closed or account.generation != _generation or not _same_configuration(account) \
			or not _is_alive_source(account.source) or not _is_live(account.network) \
			or not _is_live(account.target) or not account.receiver.has_active_task():
		return false
	var snapshot: Dictionary = account.receiver.get_task_snapshot()
	return _same_identity(account, snapshot)


func _same_identity(account: TaskAccount, snapshot: Dictionary) -> bool:
	if int(snapshot.get("task_id", 0)) != account.task_id or snapshot.get("source_core") != account.source \
			or snapshot.get("target", snapshot.get("edge")) != account.target \
			or int(snapshot.get("target_id", snapshot.get("edge_id", 0))) != account.target_id \
			or not _is_live(account.target) or not _is_live(account.network) \
			or not account.receiver.is_target_valid(account.task_id):
		return false
	return account.point_id == 0 or (_is_live(account.point) \
		and snapshot.get("repair_point") == account.point \
		and account.receiver.get_delivery_target(account.task_id) == account.point)


func _same_shipment_identity(shipment: Shipment) -> bool:
	return _is_live(shipment.point) and _is_live(shipment.target) \
		and _is_live(shipment.receiver) \
		and shipment.point_id == shipment.account.point_id and shipment.point == shipment.account.point \
		and shipment.source == shipment.account.source and shipment.target == shipment.account.target \
		and shipment.target_id == shipment.account.target_id \
		and shipment.receiver.get_delivery_target(shipment.task_id) == shipment.point


func _has_arrived(shipment: Shipment) -> bool:
	return shipment.started and _is_live(shipment.point) and is_instance_valid(shipment.packet) \
		and shipment.packet.has_arrived_at(shipment.point, shipment.transport_task_id)


func _transport_configuration_is_valid(network: Variant, dispatcher: Variant, required: bool) -> bool:
	if dispatcher == null:
		return not required and _is_live(network)
	return _is_live(network) and _is_live(dispatcher) and dispatcher is NetworkTrafficSystem \
		and dispatcher.network_system == network


func _is_terminal(snapshot: Dictionary) -> bool:
	var state: StringName = StringName(snapshot.get("state", &"idle"))
	return state == &"cancelled" or state == &"completed"


func _is_live(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _is_alive_source(source: Variant) -> bool:
	return _is_live(source) and source is MotherCore and source.health > 0


func _object_id(node: Variant) -> int:
	return node.get_instance_id() if is_instance_valid(node) else 0


func _account_key(receiver_id: int, task_id: int) -> String:
	return "%d:%d" % [receiver_id, task_id]


func _get_wait_reason(account: TaskAccount, snapshot: Dictionary) -> StringName:
	if account == null or account.closed:
		return &""
	if StringName(snapshot.get("state", &"idle")) == &"paused":
		return &"paused"
	if not bool(snapshot.get("supply_reachable", false)):
		return &"disconnected"
	if get_in_transit_nutrition() > 0:
		return &"in_transit"
	if account.reservation_goal > 0 and account.source.get_nutrition_reservation(account.budget_key) == 0:
		return &"core_empty"
	return StringName(snapshot.get("wait_reason", &""))


func _ensure_receiver_binding(receiver: Variant) -> void:
	if not _is_live(receiver) or not receiver is RepairSystem or _receivers.has(receiver.get_instance_id()):
		return
	var receiver_id: int = receiver.get_instance_id()
	_receivers[receiver_id] = receiver
	_connect(receiver, &"task_changed", _on_task_changed.bind(receiver_id))
	_connect(receiver, &"task_cancelled", _on_task_terminal.bind(receiver_id))
	_connect(receiver, &"task_completed", _on_task_terminal.bind(receiver_id))
	_connect(receiver, &"tree_exiting", _on_receiver_exiting.bind(receiver_id))


func _ensure_source_binding(source: MotherCore) -> void:
	var source_id: int = source.get_instance_id()
	if _sources.has(source_id):
		return
	_sources[source_id] = source
	_connect(source, &"budget_changed", _on_source_changed)
	_connect(source, &"depleted", _on_source_depleted.bind(source_id))
	_watch_dependency(source)


func _ensure_network_binding(network: NetworkSystem) -> void:
	var network_id: int = network.get_instance_id()
	if not _networks.has(network_id):
		_networks[network_id] = network
		_connect(network, &"network_changed", _on_network_changed)
		_watch_dependency(network)
	for edge: HyphaEdge in network.get_registered_edges():
		var edge_id: int = edge.get_instance_id()
		if not _watched_edges.has(edge_id):
			_watched_edges[edge_id] = edge
			_connect(edge, &"traffic_settings_changed", _on_network_changed)


func _watch_dependency(node: Node) -> void:
	var callback: Callable = _on_dependency_exiting.bind(node.get_instance_id())
	if not node.tree_exiting.is_connected(callback):
		_connect(node, &"tree_exiting", callback)


func _connect(node: Object, signal_name: StringName, callback: Callable) -> void:
	node.connect(signal_name, callback)
	_bindings.append({"node": node, "signal": signal_name, "callback": callback})


func _disconnect_bindings() -> void:
	for binding: Dictionary in _bindings:
		var node: Variant = binding["node"]
		if is_instance_valid(node) and node.is_connected(binding["signal"], binding["callback"]):
			node.disconnect(binding["signal"], binding["callback"])
	_bindings.clear()
	_receivers.clear()
	_sources.clear()
	_networks.clear()
	_watched_edges.clear()


func _reject(message: String) -> void:
	if not _exiting and message != _last_notice:
		_last_notice = message
		notice.emit(message)


func _emit_supply_changed() -> void:
	if _exiting or _resetting or _emitting_snapshot:
		return
	var snapshot: Dictionary = get_supply_snapshot()
	if snapshot == _last_snapshot:
		return
	_emitting_snapshot = true
	_last_snapshot = snapshot.duplicate()
	supply_changed.emit(snapshot)
	_emitting_snapshot = false


func _bind_passage_tracking(shipment: Shipment) -> void:
	if not is_instance_valid(cargo_passage_tracker) or cargo_passage_tracker.is_queued_for_deletion():
		return
	shipment.cargo_id = "supply:" + shipment.transport_task_id
	shipment.cargo_generation = cargo_passage_tracker.register_cargo(shipment.cargo_id, &"repair")
	if shipment.cargo_generation >= 0:
		shipment.cargo_tracker_ref = weakref(cargo_passage_tracker)
		shipment.packet.bind_cargo(cargo_passage_tracker, shipment.cargo_id, shipment.cargo_generation)


func _confirm_passage_tracking(shipment: Shipment) -> void:
	if shipment.cargo_tracker_ref == null:
		return
	var tracker: CargoPassageTracker = shipment.cargo_tracker_ref.get_ref() as CargoPassageTracker
	if is_instance_valid(tracker):
		tracker.confirm_cargo(shipment.cargo_id, shipment.cargo_generation)


func _discard_passage_tracking(shipment: Shipment) -> void:
	if shipment.cargo_tracker_ref == null:
		return
	var tracker: CargoPassageTracker = shipment.cargo_tracker_ref.get_ref() as CargoPassageTracker
	if is_instance_valid(tracker):
		tracker.discard_cargo(shipment.cargo_id, shipment.cargo_generation)
