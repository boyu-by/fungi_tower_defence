class_name GrowthSupplySystem
extends Node
## 生长只消费实际送达的营养；本系统独占生长运输的扣款、结算和退款。

signal supply_changed(snapshot: Dictionary)
signal notice(message: String)

const PACKET_NUTRITION: int = 1
const DEFAULT_PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")

class Shipment:
	extends RefCounted

	var cargo_id: String = ""
	var cargo_generation: int = -1
	var cargo_tracker_ref: WeakRef

	var shipment_id: int = 0
	var task_id: int = 0
	var receiver_id: int = 0
	var source_id: int = 0
	var epoch: int = 0
	var source: MotherCore
	var receiver: GrowthSystem
	var packet: NutrientPacket
	var network: NetworkSystem
	var route: NetworkRoute
	var final_target: Node2D
	var transport_task_id: String = ""
	var started: bool = false
	var debited: bool = false
	var settled: bool = false
	var accepted: bool = false
	var refunded: bool = false
	var buffered: int = 0
	var status: StringName = &"reserved"

class TaskAccount:
	extends RefCounted

	var receiver: GrowthSystem
	var receiver_id: int = 0
	var task_id: int = 0
	var consumed: int = 0
	var lots: Array[Shipment] = []
	var draining: bool = false

@export var growth_system: GrowthSystem
@export var mother_core: MotherCore
@export var cargo_passage_tracker: CargoPassageTracker
@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var traffic_required: bool = false
@export var combat_supply_system: SupplySystem
@export var packet_container: Node2D
@export var packet_scene: PackedScene = DEFAULT_PACKET_SCENE
@export var dispatch_interval: float = 0.35
@export var auto_supply: bool = true

var _shipments: Dictionary[int, Shipment] = {}
var _in_transit: Dictionary[int, Shipment] = {}
var _accounts: Dictionary[String, TaskAccount] = {}
var _receivers: Dictionary[int, GrowthSystem] = {}
var _receiver_callbacks: Dictionary[int, Array] = {}
var _sources: Dictionary[int, MotherCore] = {}
var _source_callbacks: Dictionary[int, Callable] = {}
var _networks: Dictionary[int, NetworkSystem] = {}
var _network_callbacks: Dictionary[int, Callable] = {}
var _next_shipment_id: int = 1
var _epoch: int = 0
var _delivered: int = 0
var _refunded: int = 0
var _elapsed: float = 0.0
var _dispatching: bool = false
var _resetting: bool = false
var _exiting: bool = false
var _sweeping: bool = false
var _settlement_depth: int = 0
var _emitting_snapshot: bool = false
var _last_snapshot: Dictionary = {}
var _last_notice: String = ""
var _invalid_packet_scene: PackedScene
var _dispatch_owner_ref: WeakRef
# 引用失效仍保持托管锁，只允许显式释放或由新所有者重新认领。
var _dispatch_owner_id: int = 0
var _dispatch_owner_generation: int = 0
var _auto_supply_before_owner: bool = false


func _ready() -> void:
	_ensure_receiver_binding(growth_system)
	_emit_supply_changed()


func _process(delta: float) -> void:
	if _exiting or _resetting:
		return
	_ensure_receiver_binding(growth_system)
	_sweep_shipments()
	_refresh_wait_reason()
	if auto_supply and _dispatch_owner_id == 0:
		_elapsed += maxf(delta, 0.0)
		var interval: float = maxf(dispatch_interval, 0.001)
		if _elapsed >= interval:
			# 每次更新至多派发一包，不因一次长帧提前支付多个投资。
			_elapsed = fmod(_elapsed, interval)
			try_dispatch()
	_emit_supply_changed()


func _exit_tree() -> void:
	_exiting = true
	reset()


func _on_packet_arrived(packet: NutrientPacket, shipment_id: int) -> void:
	var shipment: Shipment = _in_transit.get(shipment_id)
	if shipment == null or shipment.packet != packet:
		return
	_settle_shipment(shipment, true)


func _on_packet_interrupted(packet: NutrientPacket, shipment_id: int) -> void:
	var shipment: Shipment = _in_transit.get(shipment_id)
	if shipment == null or shipment.packet != packet:
		return
	_settle_shipment(shipment, false)


func _on_packet_tree_exiting(shipment_id: int) -> void:
	var shipment: Shipment = _in_transit.get(shipment_id)
	if shipment != null:
		_settle_shipment(shipment, false)


func _on_task_changed(snapshot: Dictionary, receiver_id: int) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	var account: TaskAccount = _accounts.get(_account_key(receiver_id, task_id))
	if account == null:
		return
	_sync_consumption(account, snapshot)
	if _is_terminal_snapshot(snapshot):
		_finish_task(account)
	# 不在 task_changed 中更新等待原因，否则 set_supply_wait_reason 会重入此信号。


func _on_task_terminal(task_id: int, receiver_id: int) -> void:
	var account: TaskAccount = _accounts.get(_account_key(receiver_id, task_id))
	if account != null:
		_finish_task(account)
	_emit_supply_changed()


func _on_receiver_tree_exiting(receiver_id: int) -> void:
	for account: TaskAccount in _accounts.values():
		if account.receiver_id == receiver_id:
			_stop_task(account)
	_emit_supply_changed()


func _on_source_tree_exiting(source_id: int) -> void:
	for shipment: Shipment in _in_transit.values():
		if shipment.source_id == source_id:
			_cancel_shipment(shipment)
	for account: TaskAccount in _accounts.values():
		if _has_buffer_from_source(account, source_id):
			_stop_task(account)
	_emit_supply_changed()


func _on_network_changed() -> void:
	_sweep_shipments()


## 明确请求或计时器才派发；放置生长目标本身不会扣款。
func try_dispatch() -> bool:
	if _dispatch_owner_id != 0:
		return false
	return _try_dispatch(null, _dispatch_owner_generation)


func claim_dispatch_owner(owner: Node) -> bool:
	if _exiting or _resetting or not _is_live_node(owner):
		return false
	var current: Node = get_dispatch_owner()
	if current != null and current != owner:
		return false
	if current != owner:
		if _dispatch_owner_id == 0:
			_auto_supply_before_owner = auto_supply
		_dispatch_owner_generation += 1
		_dispatch_owner_id = owner.get_instance_id()
		_dispatch_owner_ref = weakref(owner)
	_elapsed = 0.0
	auto_supply = false
	return true


func release_dispatch_owner(owner: Node) -> void:
	if not is_instance_valid(owner) or _dispatch_owner_id != owner.get_instance_id():
		return
	_dispatch_owner_generation += 1
	_dispatch_owner_id = 0
	_dispatch_owner_ref = null
	_elapsed = 0.0
	auto_supply = _auto_supply_before_owner


func get_dispatch_owner() -> Node:
	if _dispatch_owner_ref == null:
		return null
	var owner: Variant = _dispatch_owner_ref.get_ref()
	return owner as Node if _is_live_node(owner) else null


func try_dispatch_scheduled(owner: Node) -> bool:
	if not can_dispatch_scheduled(owner):
		return false
	return _try_dispatch(owner, _dispatch_owner_generation)


func can_dispatch_scheduled(owner: Node) -> bool:
	if _exiting or _resetting or _dispatching or _settlement_depth > 0 \
			or not _is_matching_dispatch_owner(owner) \
			or not _is_live_receiver(growth_system) or not growth_system.has_active_task():
		return false
	var attempt_epoch: int = _epoch
	var owner_generation: int = _dispatch_owner_generation
	var receiver: GrowthSystem = growth_system
	var snapshot: Dictionary = receiver.get_task_snapshot()
	var task_id: int = int(snapshot.get("task_id", 0))
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _same_active_task(receiver, task_id) \
			or StringName(snapshot.get("state", &"idle")) == &"paused":
		return false
	var demand: int = receiver.get_requested_nutrition(task_id)
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _same_active_task(receiver, task_id) \
			or demand - _outstanding_for(receiver, task_id) <= 0 \
			or not _has_transport_configuration() or not _is_alive_source(mother_core):
		return false
	var source: MotherCore = mother_core
	var network: NetworkSystem = network_system
	var container: Node2D = packet_container
	var target: Node2D = receiver.get_delivery_target(task_id)
	if not _is_live_node(target):
		return false
	var route: NetworkRoute = network.find_available_route(source, target)
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_alive_source(source) or not _is_live_node(network) \
			or not _same_active_task(receiver, task_id) or not route.found:
		return false
	var available: int = get_available_growth_nutrition()
	return _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
		and receiver == growth_system and source == mother_core and network == network_system \
		and container == packet_container and _is_live_node(container) \
		and _is_alive_source(source) and _same_active_task(receiver, task_id) \
		and receiver.get_delivery_target(task_id) == target \
		and receiver.get_requested_nutrition(task_id) - _outstanding_for(receiver, task_id) > 0 \
		and available >= PACKET_NUTRITION \
		and _managed_route_is_available(owner, owner_generation, attempt_epoch,
			source, network, target)


func _try_dispatch(owner: Node, owner_generation: int) -> bool:
	if _exiting or _resetting or _dispatching or _settlement_depth > 0:
		return false
	_dispatching = true
	var attempt_epoch: int = _epoch
	_ensure_receiver_binding(growth_system)
	_sweep_shipments()
	var shipment: Shipment = _dispatch_one(owner, owner_generation, attempt_epoch)
	_sweep_shipments()
	_refresh_wait_reason()
	_emit_supply_changed()
	_dispatching = false
	return shipment != null and attempt_epoch == _epoch \
		and (shipment.accepted or (shipment.debited and not shipment.settled))


func get_in_transit_count() -> int:
	return _in_transit.size()


## 库存与已付款的器官在途包都覆盖两次射击的缺口，不更改任何战斗库存。
func get_combat_reserve() -> int:
	if not is_instance_valid(combat_supply_system) or combat_supply_system.is_queued_for_deletion():
		return 0
	var reserve: int = 0
	var organs: Array[AttackOrgan] = combat_supply_system.get_active_organs()
	for organ: AttackOrgan in organs:
		if is_instance_valid(organ) and not organ.is_queued_for_deletion():
			reserve += maxi(0, 2 * SporeWeapon.SHOT_NUTRITION \
				- organ.nutrition - organ.incoming_nutrition)
	return reserve


func get_available_growth_nutrition() -> int:
	if not _is_alive_source(mother_core):
		return 0
	var source: MotherCore = mother_core
	var reserve: int = get_combat_reserve()
	if not _is_alive_source(source):
		return 0
	# 母核余额已经扣除所有派发包；生长在途不能再次扣除。
	return maxi(0, source.get_spendable_nutrition() - reserve)


func get_shipment_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for shipment: Shipment in _shipments.values():
		records.append({
			"shipment_id": shipment.shipment_id,
			"task_id": shipment.task_id,
			"source": shipment.source,
			"packet": shipment.packet,
			"final_target": shipment.final_target,
			"cargo_id": shipment.cargo_id, "cargo_generation": shipment.cargo_generation,
			"transport_task_id": shipment.transport_task_id,
			"started": shipment.started,
			"debited": shipment.debited,
			"settled": shipment.settled,
			"status": shipment.status,
			"accepted": shipment.accepted,
			"refunded": shipment.refunded,
			"buffered_nutrition": shipment.buffered,
		})
	return records


## 先取消任务并清空缓存，再退款；旧包仍绑定旧编号，编号绝不复用。
func reset() -> void:
	if _resetting:
		return
	_resetting = true
	_epoch += 1
	_ensure_receiver_binding(growth_system)
	for receiver: Variant in _receivers.values():
		if is_instance_valid(receiver) and receiver.has_active_task():
			receiver.cancel_task()
	for shipment: Shipment in _in_transit.values():
		_cancel_shipment(shipment)
	for account: TaskAccount in _accounts.values():
		_drain_buffer(account)
	_disconnect_bindings()
	_shipments.clear()
	_in_transit.clear()
	_accounts.clear()
	_delivered = 0
	_refunded = 0
	_elapsed = 0.0
	_last_snapshot = {}
	_last_notice = ""
	_invalid_packet_scene = null
	_resetting = false
	if not _exiting:
		_ensure_receiver_binding(growth_system)
		_emit_supply_changed()


func _dispatch_one(owner: Node, owner_generation: int, attempt_epoch: int) -> Shipment:
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_live_receiver(growth_system) or not growth_system.has_active_task():
		return null
	var receiver: GrowthSystem = growth_system
	var snapshot: Dictionary = receiver.get_task_snapshot()
	var task_id: int = int(snapshot.get("task_id", 0))
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _same_active_task(receiver, task_id):
		return null
	if receiver.get_requested_nutrition(task_id) - _outstanding_for(receiver, task_id) <= 0:
		return null
	if not _is_alive_source(mother_core):
		_reject("母核当前无法供给生长")
		return null
	if not _has_transport_configuration():
		_reject("生长供给缺少网络或营养包配置")
		return null
	var source: MotherCore = mother_core
	var network: NetworkSystem = network_system
	var dispatcher: Variant = traffic_system
	var require_traffic: bool = traffic_required or dispatcher != null
	var container: Node2D = packet_container
	var scene: PackedScene = packet_scene
	var target: Node2D = receiver.get_delivery_target(task_id)
	if not _is_live_node(target):
		_reject("生长端点已失效")
		return null
	var route: NetworkRoute = network.find_route(source, target)
	if not route.found:
		_reject("母核到生长端点的运输线路已断开")
		return null
	var instance: Node = scene.instantiate()
	if not instance is NutrientPacket:
		instance.free()
		_invalid_packet_scene = scene
		_reject("生长营养包场景类型不正确")
		return null
	var packet: NutrientPacket = instance as NutrientPacket
	packet.traffic_required = require_traffic
	# 路线查询、实例化和战斗器官查询都可能触发外部回调，扣款前重新核验。
	var reserve: int = get_combat_reserve()
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_alive_source(source) \
			or not _is_live_node(container) or not _same_active_task(receiver, task_id) \
			or not _is_live_node(network) or not _is_live_node(target):
		packet.free()
		return null
	if source.get_spendable_nutrition() - reserve < PACKET_NUTRITION \
			or receiver.get_requested_nutrition(task_id) - _outstanding_for(receiver, task_id) <= 0:
		packet.free()
		return null
	if not _traffic_configuration_is_valid(network, dispatcher, require_traffic) \
			or not network.is_route_valid(route) or not _same_active_task(receiver, task_id) \
			or receiver.get_delivery_target(task_id) != target or not _is_alive_source(source) \
			or not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch):
		packet.free()
		return null

	var shipment: Shipment = Shipment.new()
	shipment.shipment_id = _next_shipment_id
	_next_shipment_id += 1
	shipment.task_id = task_id
	shipment.receiver_id = receiver.get_instance_id()
	shipment.source_id = source.get_instance_id()
	shipment.epoch = _epoch
	shipment.source = source
	shipment.receiver = receiver
	shipment.packet = packet
	shipment.network = network
	shipment.route = route
	shipment.final_target = target
	shipment.transport_task_id = "growth:%d:%s" % [get_instance_id(), str(shipment.shipment_id)]
	_bind_passage_tracking(shipment)
	_get_account(receiver, task_id, snapshot)
	_shipments[shipment.shipment_id] = shipment
	_in_transit[shipment.shipment_id] = shipment
	packet.arrived.connect(_on_packet_arrived.bind(shipment.shipment_id))
	packet.interrupted.connect(_on_packet_interrupted.bind(shipment.shipment_id))
	packet.tree_exiting.connect(_on_packet_tree_exiting.bind(shipment.shipment_id))
	_ensure_source_binding(source)
	_ensure_network_binding(network)
	container.add_child(packet)
	if shipment.settled or not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_alive_source(source) \
			or not _same_active_task(receiver, task_id) or not _is_live_node(container):
		_cancel_shipment(shipment)
		return shipment
	reserve = get_combat_reserve()
	if shipment.settled or not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_alive_source(source) \
			or not _same_active_task(receiver, task_id) or not _is_live_node(packet) \
			or not _is_live_node(container) or not _is_live_node(network) \
			or receiver.get_requested_nutrition(task_id) <= 0 \
			or source.get_spendable_nutrition() - reserve < PACKET_NUTRITION:
		_cancel_shipment(shipment)
		return shipment

	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _traffic_configuration_is_valid(network, dispatcher, require_traffic) \
			or not _managed_route_is_available(owner, owner_generation, attempt_epoch,
				source, network, target) \
			or shipment.settled or not _is_live_node(packet) or not _is_live_node(container) \
			or not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch):
		_cancel_shipment(shipment)
		return shipment

	# try_spend 先减余额再发信号；提前标记付款让信号内的取消能立即退款。
	# 此标记与调用之间不发出信号，也不执行其他外部代码。
	shipment.debited = true
	var spent: bool = source.try_spend_nutrition(PACKET_NUTRITION)
	if not spent:
		shipment.debited = false
		_cancel_shipment(shipment)
	elif shipment.settled or not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_alive_source(source) or not _same_active_task(receiver, task_id) \
			or not _is_live_node(container) or not _is_live_node(packet):
		_cancel_shipment(shipment)
	else:
		shipment.status = &"in_transit"
		# 无效路线、零长度路线都可同步完成；此时账本和回调已全部提交。
		if _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
				and _traffic_configuration_is_valid(network, dispatcher, require_traffic):
			shipment.started = true
			packet.start_route(route, network, dispatcher, shipment.transport_task_id, &"supply")
		else:
			_cancel_shipment(shipment)
	return shipment


func _is_matching_dispatch_owner(owner: Node) -> bool:
	return _is_live_node(owner) and _dispatch_owner_id == owner.get_instance_id() \
		and get_dispatch_owner() == owner


func _dispatch_attempt_is_current(owner: Node, owner_generation: int, attempt_epoch: int) -> bool:
	if _exiting or _resetting or attempt_epoch != _epoch \
			or owner_generation != _dispatch_owner_generation:
		return false
	return _dispatch_owner_id == 0 if owner == null else _is_matching_dispatch_owner(owner)


## 托管新付款要求实际可通行；最后查路线，覆盖需求查询和入树回调中的禁行。
func _managed_route_is_available(
	owner: Node, owner_generation: int, attempt_epoch: int,
	source: MotherCore, network: NetworkSystem, target: Node2D
) -> bool:
	if owner == null:
		return true
	if not _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
			or not _is_alive_source(source) or source != mother_core or network != network_system \
			or not _is_live_node(network) or not _is_live_node(target):
		return false
	var route: NetworkRoute = network.find_available_route(source, target)
	return route.found and _dispatch_attempt_is_current(owner, owner_generation, attempt_epoch) \
		and source == mother_core and network == network_system and _is_alive_source(source) \
		and _is_live_node(network) and _is_live_node(target)


func _settle_shipment(shipment: Shipment, arrived: bool) -> void:
	if shipment.settled:
		return
	# 提前重放 arrived 不代表已抵达；账本继续持有同一付款与需求占位。
	if arrived and not _has_arrived(shipment):
		return
	_settlement_depth += 1
	shipment.settled = true
	_in_transit.erase(shipment.shipment_id)
	shipment.status = &"settling"
	var accepted: bool = false
	var account: TaskAccount = _accounts.get(_account_key(shipment.receiver_id, shipment.task_id))
	if arrived and shipment.debited and shipment.epoch == _epoch and account != null \
			and _is_alive_source(shipment.source) and _same_target_task(shipment):
		_sync_consumption(account, shipment.receiver.get_task_snapshot())
		# receive 可发信号并同步取消任务。先记录临时来源，使取消能归还新缓存。
		shipment.buffered = PACKET_NUTRITION
		account.lots.append(shipment)
		accepted = shipment.receiver.receive_nutrition(
			shipment.task_id, shipment.shipment_id, PACKET_NUTRITION)
	shipment.accepted = accepted
	if accepted:
		shipment.status = &"buffer_refunded" if shipment.refunded else &"delivered"
		if shipment.epoch == _epoch:
			_delivered += PACKET_NUTRITION
	else:
		if account != null:
			account.lots.erase(shipment)
		shipment.buffered = 0
		_refund_shipment(shipment)
	_settlement_depth -= 1
	_emit_supply_changed()


func _cancel_shipment(shipment: Shipment) -> void:
	# 先结算再通知包，包的 interrupted / tree_exiting 重放只会命中已终结记录。
	if not shipment.settled:
		_settle_shipment(shipment, false)
	var packet: Variant = shipment.packet
	if is_instance_valid(packet):
		packet.cancel_transport()
		if is_instance_valid(packet) and not packet.is_queued_for_deletion():
			packet.queue_free()


func _refund_shipment(shipment: Shipment) -> void:
	if shipment.refunded:
		return
	shipment.buffered = 0
	_discard_passage_tracking(shipment)
	if not shipment.debited:
		shipment.status = &"not_debited"
		return
	shipment.refunded = true
	shipment.status = &"buffer_refunded" if shipment.accepted else &"refunded"
	# 保存原付款来源，允许导出 mother_core 被换成另一个母核。
	var source: Variant = shipment.source
	if is_instance_valid(source):
		if shipment.epoch == _epoch:
			_refunded += PACKET_NUTRITION
		source.add_nutrition(PACKET_NUTRITION)
	else:
		shipment.status = &"source_unavailable"


func _finish_task(account: TaskAccount) -> void:
	_settlement_depth += 1
	for shipment: Shipment in _in_transit.values():
		if shipment.receiver_id == account.receiver_id and shipment.task_id == account.task_id:
			_cancel_shipment(shipment)
	_drain_buffer(account)
	_settlement_depth -= 1


func _stop_task(account: TaskAccount) -> void:
	var receiver: Variant = account.receiver
	if is_instance_valid(receiver):
		var snapshot: Dictionary = receiver.get_task_snapshot()
		if int(snapshot.get("task_id", 0)) == account.task_id and receiver.has_active_task():
			receiver.cancel_task()
	_finish_task(account)


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
			if _is_terminal_snapshot(snapshot):
				remaining = receiver.take_unspent_nutrition(account.task_id)
	else:
		# tree_exiting 通常已经清空；直接 free 的兜底沿用最后一次消费快照。
		for lot: Shipment in account.lots:
			remaining += lot.buffered
	for lot: Shipment in account.lots.duplicate():
		if remaining <= 0:
			break
		if lot.buffered > 0:
			remaining -= lot.buffered
			_refund_shipment(lot)
	account.draining = false


func _sync_consumption(account: TaskAccount, snapshot: Dictionary) -> void:
	var consumed: int = int(snapshot.get("consumed_nutrition", account.consumed))
	var remaining: int = maxi(0, consumed - account.consumed)
	account.consumed = maxi(account.consumed, consumed)
	var committed_lots: Array[Shipment] = []
	# 每包一单位，按接受顺序核销来源；退款只归还尚未消费的批次。
	for lot: Shipment in account.lots:
		if remaining <= 0:
			break
		var used: int = mini(lot.buffered, remaining)
		lot.buffered -= used
		remaining -= used
		if used > 0:
			committed_lots.append(lot)

	# 先完成全部原 FIFO 核销，升级通知再重入也看不到半提交的来源账本。
	for lot: Shipment in committed_lots:
		_confirm_passage_tracking(lot)


func _get_account(receiver: GrowthSystem, task_id: int, snapshot: Dictionary) -> TaskAccount:
	var key: String = _account_key(receiver.get_instance_id(), task_id)
	var account: TaskAccount = _accounts.get(key)
	if account == null:
		account = TaskAccount.new()
		account.receiver = receiver
		account.receiver_id = receiver.get_instance_id()
		account.task_id = task_id
		account.consumed = int(snapshot.get("consumed_nutrition", 0))
		_accounts[key] = account
	return account


func _account_key(receiver_id: int, task_id: int) -> String:
	return "%d:%d" % [receiver_id, task_id]


func _outstanding_for(receiver: GrowthSystem, task_id: int) -> int:
	var count: int = 0
	var receiver_id: int = receiver.get_instance_id()
	for shipment: Shipment in _in_transit.values():
		if shipment.receiver_id == receiver_id and shipment.task_id == task_id:
			count += PACKET_NUTRITION
	return count


func _sweep_shipments() -> void:
	if _sweeping or _resetting or _exiting:
		return
	_sweeping = true
	for shipment: Shipment in _in_transit.values():
		if not _is_alive_source(shipment.source) \
				or not _same_target_task(shipment) \
				or not _is_live_node(shipment.packet) or not _is_live_node(shipment.network):
			_cancel_shipment(shipment)
		elif shipment.started and not shipment.packet.is_transport_valid(
				shipment.final_target, shipment.transport_task_id):
			_cancel_shipment(shipment)
		elif not shipment.started and not shipment.network.is_route_valid(shipment.route):
			# 扣款/入树的同步通知期间包尚未启动，仍执行原有入场核验。
			_cancel_shipment(shipment)
	for account: TaskAccount in _accounts.values():
		var receiver: Variant = account.receiver
		if not is_instance_valid(receiver) or receiver.is_queued_for_deletion():
			_stop_task(account)
		else:
			var snapshot: Dictionary = receiver.get_task_snapshot()
			if int(snapshot.get("task_id", 0)) == account.task_id and _is_terminal_snapshot(snapshot):
				_finish_task(account)
			else:
				for lot: Shipment in account.lots:
					if lot.buffered > 0 and not _is_alive_source(lot.source):
						_stop_task(account)
						break
	_sweeping = false


func _refresh_wait_reason() -> void:
	if not _is_live_receiver(growth_system) or not growth_system.has_active_task():
		return
	var receiver: GrowthSystem = growth_system
	var snapshot: Dictionary = receiver.get_task_snapshot()
	var task_id: int = int(snapshot.get("task_id", 0))
	var reason: StringName = &""
	if StringName(snapshot.get("state", &"idle")) == &"paused":
		reason = &"paused"
	elif receiver.get_requested_nutrition(task_id) > 0:
		if _outstanding_for(receiver, task_id) > 0:
			reason = &"in_transit"
		elif not _has_transport_configuration():
			reason = &"invalid_configuration"
		elif not _is_alive_source(mother_core):
			reason = &"core_unavailable"
		else:
			var source: MotherCore = mother_core
			var network: NetworkSystem = network_system
			var target: Node2D = receiver.get_delivery_target(task_id)
			var connected: bool = _is_live_node(target) and network.find_route(source, target).found
			if not _is_alive_source(source):
				reason = &"core_unavailable"
			elif not connected:
				reason = &"disconnected"
			elif source.nutrition <= 0:
				reason = &"core_empty"
			elif source.get_spendable_nutrition() <= get_combat_reserve() and source.nutrition > get_combat_reserve():
				reason = &"repair_budget"
			elif get_available_growth_nutrition() <= 0:
				reason = &"combat_reserve"
			else:
				reason = &"nutrition"
	if _same_active_task(receiver, task_id) and StringName(snapshot.get("wait_reason", &"")) != reason:
		receiver.set_supply_wait_reason(task_id, reason)


func _has_transport_configuration() -> bool:
	return _traffic_configuration_is_valid(network_system, traffic_system, traffic_required) \
		and _is_live_node(network_system) and _is_live_node(packet_container) \
		and packet_scene != null and packet_scene != _invalid_packet_scene


func _is_alive_source(source: Variant) -> bool:
	return is_instance_valid(source) and source is MotherCore \
		and not source.is_queued_for_deletion() and source.health > 0


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _is_live_receiver(receiver: Variant) -> bool:
	return _is_live_node(receiver) and receiver is GrowthSystem


func _same_active_task(receiver: Variant, task_id: int) -> bool:
	if not _is_live_receiver(receiver) or not receiver.has_active_task():
		return false
	return int(receiver.get_task_snapshot().get("task_id", 0)) == task_id


func _same_target_task(shipment: Shipment) -> bool:
	return _is_live_node(shipment.final_target) \
		and _same_active_task(shipment.receiver, shipment.task_id) \
		and shipment.receiver.get_delivery_target(shipment.task_id) == shipment.final_target


func _has_arrived(shipment: Shipment) -> bool:
	return shipment.started and _is_live_node(shipment.final_target) and is_instance_valid(shipment.packet) \
		and shipment.packet.has_arrived_at(shipment.final_target, shipment.transport_task_id)


func _is_terminal_snapshot(snapshot: Dictionary) -> bool:
	var state: StringName = StringName(snapshot.get("state", &"idle"))
	return state == &"cancelled" or state == &"completed"


func _has_buffer_from_source(account: TaskAccount, source_id: int) -> bool:
	for lot: Shipment in account.lots:
		if lot.source_id == source_id and lot.buffered > 0:
			return true
	return false


func _ensure_receiver_binding(receiver: Variant) -> void:
	if not is_instance_valid(receiver) or not receiver is GrowthSystem:
		return
	var receiver_id: int = receiver.get_instance_id()
	if _receivers.has(receiver_id):
		return
	var changed: Callable = _on_task_changed.bind(receiver_id)
	var terminal: Callable = _on_task_terminal.bind(receiver_id)
	var exiting: Callable = _on_receiver_tree_exiting.bind(receiver_id)
	_receivers[receiver_id] = receiver
	_receiver_callbacks[receiver_id] = [changed, terminal, exiting]
	receiver.task_changed.connect(changed)
	receiver.task_cancelled.connect(terminal)
	receiver.task_completed.connect(terminal)
	receiver.tree_exiting.connect(exiting)


func _ensure_source_binding(source: MotherCore) -> void:
	var source_id: int = source.get_instance_id()
	if _sources.has(source_id):
		return
	var callback: Callable = _on_source_tree_exiting.bind(source_id)
	_sources[source_id] = source
	_source_callbacks[source_id] = callback
	source.tree_exiting.connect(callback)


func _ensure_network_binding(network: NetworkSystem) -> void:
	var network_id: int = network.get_instance_id()
	if _networks.has(network_id):
		return
	var callback: Callable = _on_network_changed
	_networks[network_id] = network
	_network_callbacks[network_id] = callback
	network.network_changed.connect(callback)


func _disconnect_bindings() -> void:
	for receiver_id: int in _receivers:
		var receiver: Variant = _receivers[receiver_id]
		if is_instance_valid(receiver):
			var callbacks: Array = _receiver_callbacks[receiver_id]
			if receiver.task_changed.is_connected(callbacks[0]):
				receiver.task_changed.disconnect(callbacks[0])
			if receiver.task_cancelled.is_connected(callbacks[1]):
				receiver.task_cancelled.disconnect(callbacks[1])
			if receiver.task_completed.is_connected(callbacks[1]):
				receiver.task_completed.disconnect(callbacks[1])
			if receiver.tree_exiting.is_connected(callbacks[2]):
				receiver.tree_exiting.disconnect(callbacks[2])
	for source_id: int in _sources:
		var source: Variant = _sources[source_id]
		if is_instance_valid(source) and source.tree_exiting.is_connected(_source_callbacks[source_id]):
			source.tree_exiting.disconnect(_source_callbacks[source_id])
	for network_id: int in _networks:
		var network: Variant = _networks[network_id]
		if is_instance_valid(network) and network.network_changed.is_connected(_network_callbacks[network_id]):
			network.network_changed.disconnect(_network_callbacks[network_id])
	_receivers.clear()
	_receiver_callbacks.clear()
	_sources.clear()
	_source_callbacks.clear()
	_networks.clear()
	_network_callbacks.clear()


func _reject(message: String) -> void:
	if not _exiting and message != _last_notice:
		_last_notice = message
		notice.emit(message)


func _emit_supply_changed() -> void:
	if _exiting or _resetting or _emitting_snapshot:
		return
	_emitting_snapshot = true
	var reserve: int = get_combat_reserve()
	var available: int = 0
	if _is_alive_source(mother_core):
		available = maxi(0, mother_core.get_spendable_nutrition() - reserve)
	var snapshot: Dictionary = {
		"in_transit": get_in_transit_count(),
		"delivered": _delivered,
		"refunded": _refunded,
		"combat_reserve": reserve,
		"available": available,
	}
	if snapshot != _last_snapshot:
		_last_snapshot = snapshot.duplicate()
		supply_changed.emit(snapshot)
	_emitting_snapshot = false


## 显式交通配置失效不能退回旧的无容量运输；这里只校验配置，不预留通行。
func _traffic_configuration_is_valid(network: Variant, dispatcher: Variant, required: bool) -> bool:
	if dispatcher == null:
		return not required
	return is_instance_valid(dispatcher) and dispatcher is NetworkTrafficSystem \
		and not dispatcher.is_queued_for_deletion() and is_instance_valid(network) \
		and not network.is_queued_for_deletion() and dispatcher.network_system == network


func _bind_passage_tracking(shipment: Shipment) -> void:
	if not is_instance_valid(cargo_passage_tracker) or cargo_passage_tracker.is_queued_for_deletion():
		return
	shipment.cargo_id = "supply:" + shipment.transport_task_id
	shipment.cargo_generation = cargo_passage_tracker.register_cargo(shipment.cargo_id, &"growth")
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
