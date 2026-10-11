class_name SupplySystem
extends Node
## 登记攻击器官并轮询供养，负责派发扣款、容量预留和一次性结算。

signal transport_changed(in_transit: int, delivered: int, interrupted: int)
signal notice(message: String)

const PACKET_NUTRITION: int = 1

class Shipment:
	extends RefCounted

	var cargo_id: String = ""
	var cargo_generation: int = -1
	var cargo_tracker_ref: WeakRef

	var source: MotherCore
	var receiver: AttackOrgan
	var receiver_id: int
	var packet: NutrientPacket
	var final_target: Node2D
	var transport_task_id: String = ""
	var is_settled: bool = false
	var was_delivered: bool = false

@export var mother_core: MotherCore
@export var cargo_passage_tracker: CargoPassageTracker
@export var target_organ: AttackOrgan
@export var supply_edge: HyphaEdge
@export var packet_container: Node2D
@export var packet_scene: PackedScene
@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var traffic_required: bool = false

var delivered_packets: int = 0
var interrupted_packets: int = 0

var _organs: Dictionary[int, AttackOrgan] = {}
var _organ_order: Array[int] = []
var _organ_exit_callbacks: Dictionary[int, Callable] = {}
var _next_organ_index: int = 0
var _shipments: Dictionary[int, Shipment] = {}
var _next_shipment_id: int = 1
var _is_exiting: bool = false
var _resetting: bool = false
var _reset_epoch: int = 0


func _ready() -> void:
	if is_instance_valid(target_organ):
		register_organ(target_organ)


func _on_dispatch_timer_timeout() -> void:
	if _is_exiting or _resetting:
		return
	_prune_organs()
	if _organ_order.is_empty():
		return

	# 用本次扫描的快照，允许库存信号的监听者在派发时登记或注销器官。
	var organ_ids: Array[int] = _organ_order.duplicate()
	var start_index: int = _next_organ_index % organ_ids.size()
	for offset: int in range(organ_ids.size()):
		var organ_id: int = organ_ids[(start_index + offset) % organ_ids.size()]
		var organ: AttackOrgan = _get_registered_organ(organ_id)
		if organ == null or not organ.can_process() or not organ.needs_supply():
			continue
		var current_index: int = _organ_order.find(organ_id)
		_next_organ_index = (current_index + 1) % _organ_order.size()
		if _dispatch_packet(organ, false):
			break


func _on_organ_tree_exiting(organ_id: int) -> void:
	_remove_organ_registration(organ_id)


func _on_packet_arrived(packet: NutrientPacket, shipment_id: int) -> void:
	var shipment: Shipment = _shipments.get(shipment_id)
	if shipment != null and shipment.packet == packet and _has_arrived(shipment):
		_settle_shipment(shipment_id, true)


func _on_packet_interrupted(packet: NutrientPacket, shipment_id: int) -> void:
	var shipment: Shipment = _shipments.get(shipment_id)
	if shipment != null and shipment.packet == packet:
		_settle_shipment(shipment_id, false)


func _on_packet_removed(shipment_id: int) -> void:
	_settle_shipment(shipment_id, false)


func register_organ(organ: AttackOrgan) -> bool:
	if _is_exiting or not is_instance_valid(organ) or organ.is_queued_for_deletion():
		return false
	_prune_organs()
	if not is_instance_valid(organ) or organ.is_queued_for_deletion():
		return false
	var organ_id: int = organ.get_instance_id()
	if _organs.has(organ_id):
		return true

	var exit_callback: Callable = _on_organ_tree_exiting.bind(organ_id)
	_organs[organ_id] = organ
	_organ_order.append(organ_id)
	_organ_exit_callbacks[organ_id] = exit_callback
	organ.tree_exiting.connect(exit_callback)
	return true


func unregister_organ(organ: AttackOrgan) -> void:
	_prune_organs()
	if not is_instance_valid(organ):
		return
	_remove_organ_registration(organ.get_instance_id())


func get_registered_organs() -> Array[AttackOrgan]:
	_prune_organs()
	var organs: Array[AttackOrgan] = []
	for organ_id: int in _organ_order:
		var organ: AttackOrgan = _get_registered_organ(organ_id)
		if organ != null:
			organs.append(organ)
	return organs


## 只查询参与供给的活动器官，不依赖余额、缺粮状态或运输配置，也不预留资源。
func get_active_organs() -> Array[AttackOrgan]:
	var organs: Array[AttackOrgan] = get_registered_organs()
	var active: Array[AttackOrgan] = []
	if not _is_alive_source(mother_core):
		return active
	if network_system != null and (
			not is_instance_valid(network_system) or network_system.is_queued_for_deletion()):
		return active
	var source: MotherCore = mother_core
	var transport_network: NetworkSystem = network_system
	for organ: AttackOrgan in organs:
		if organ.can_process() and _find_supply_route(source, organ, transport_network).found:
			active.append(organ)
	return active


func request_supply(organ: AttackOrgan = null) -> bool:
	if _is_exiting or _resetting:
		return _reject("供养系统正在退出", true)
	var organs: Array[AttackOrgan] = get_registered_organs()
	var receiver: AttackOrgan = organ
	if organ == null:
		if _is_registered_organ(target_organ):
			receiver = target_organ
		elif not organs.is_empty():
			receiver = organs[0]
	return _dispatch_packet(receiver, true)


func get_in_transit_count() -> int:
	return _shipments.size()


func _dispatch_packet(receiver: AttackOrgan, show_rejection: bool) -> bool:
	if _is_exiting or _resetting or not _is_alive_source(mother_core):
		return _reject("母核无法提供营养：母核无效或生命值已归零", show_rejection)
	if not _is_registered_organ(receiver):
		return _reject("供养器官无效或尚未登记", show_rejection)
	if not is_instance_valid(packet_container) or (
			packet_container.is_queued_for_deletion() or packet_scene == null):
		return _reject("供养系统缺少营养包配置", show_rejection)
	if network_system != null and (
			not is_instance_valid(network_system) or network_system.is_queued_for_deletion()):
		return _reject("供养网络已退出", show_rejection)

	if not _traffic_configuration_is_valid(network_system, traffic_system, traffic_required):
		return _reject("供养缺少有效的共享交通调度器", show_rejection)

	# 后续回调即使修改导出配置，本次运输也沿用这些源、接收者和网络。
	var source: MotherCore = mother_core
	var transport_network: NetworkSystem = network_system
	var dispatcher: Variant = traffic_system
	var require_traffic: bool = traffic_required or dispatcher != null
	var attempt_epoch: int = _reset_epoch
	var container: Node2D = packet_container
	var route: NetworkRoute = _find_supply_route(source, receiver, transport_network)
	if not route.found:
		return _reject("母核到目标菌结没有可用供养线路", show_rejection)

	var instance: Node = packet_scene.instantiate()
	if not instance is NutrientPacket:
		instance.free()
		return _reject("营养包场景类型不正确", show_rejection)
	var packet: NutrientPacket = instance as NutrientPacket
	packet.traffic_required = require_traffic
	if attempt_epoch != _reset_epoch or not _traffic_configuration_is_valid(transport_network, dispatcher, require_traffic) \
			or not _is_alive_source(source) or not _is_registered_organ(receiver):
		packet.free()
		return _reject("母核或供养器官已退出", show_rejection)
	var shipment: Shipment = Shipment.new()
	shipment.source = source
	shipment.receiver = receiver
	shipment.receiver_id = receiver.get_instance_id()
	shipment.packet = packet
	shipment.final_target = route.end_node
	var shipment_id: int = _next_shipment_id
	_next_shipment_id += 1
	shipment.transport_task_id = "combat:%d:%d" % [get_instance_id(), shipment_id]
	if source.get_spendable_nutrition() < PACKET_NUTRITION:
		packet.free()
		return _reject("营养已预留给修复" if source.nutrition > 0 else "母核营养不足", show_rejection)
	if not receiver.reserve_nutrition(PACKET_NUTRITION):
		packet.free()
		return _reject("库存与在途供养已占满容量", show_rejection)
	if attempt_epoch != _reset_epoch or not _is_registered_organ(receiver) or _is_exiting \
			or not _is_alive_source(source) \
			or not _traffic_configuration_is_valid(transport_network, dispatcher, require_traffic):
		if is_instance_valid(receiver):
			receiver.cancel_reservation(PACKET_NUTRITION)
		packet.free()
		return _reject("母核或供养器官已退出", show_rejection)
	if not source.try_spend_nutrition(PACKET_NUTRITION):
		if is_instance_valid(receiver):
			receiver.cancel_reservation(PACKET_NUTRITION)
		packet.free()
		return _reject("母核无法提供营养：余额不足或生命值已归零", show_rejection)

	_bind_passage_tracking(shipment)
	_shipments[shipment_id] = shipment
	packet.arrived.connect(_on_packet_arrived.bind(shipment_id))
	packet.interrupted.connect(_on_packet_interrupted.bind(shipment_id))
	packet.tree_exiting.connect(_on_packet_removed.bind(shipment_id))

	# 库存或余额信号可能已注销接收者；仍由统一的一次性结算归还资源。
	if attempt_epoch != _reset_epoch or not _is_registered_organ(receiver) or _is_exiting or (
			not is_instance_valid(container) or container.is_queued_for_deletion()):
		_cancel_shipment(shipment_id)
		return _reject("供养器官已退出或注销", show_rejection)
	container.add_child(packet)
	_emit_transport_changed()
	# 无效路线可在这里同步中断，所以记录和所有回调必须先提交。
	if not shipment.is_settled and is_instance_valid(packet) and not packet.is_queued_for_deletion() \
			and _traffic_configuration_is_valid(transport_network, dispatcher, require_traffic):
		packet.start_route(route, transport_network, dispatcher, shipment.transport_task_id, &"supply")
	else:
		_cancel_shipment(shipment_id)
	return not shipment.is_settled or shipment.was_delivered


func _find_supply_route(source: MotherCore, receiver: AttackOrgan,
		transport_network: NetworkSystem) -> NetworkRoute:
	var route: NetworkRoute = NetworkRoute.new()
	if not _is_alive_source(source) or not _is_registered_organ(receiver):
		return route
	var host: Node2D = receiver.get_parent() as Node2D
	if not is_instance_valid(host) or host.is_queued_for_deletion():
		return route
	if transport_network != null:
		if not is_instance_valid(transport_network) or transport_network.is_queued_for_deletion():
			return route
		return transport_network.find_route(source, host)
	if not is_instance_valid(supply_edge) or supply_edge.is_queued_for_deletion():
		return route
	if supply_edge.start_node != source or supply_edge.end_node != host:
		return route

	# 单器官场景仍可沿原来的有向直连边供养，但不能绕过已配置的网络。
	var segment: NetworkRoute.Segment = NetworkRoute.Segment.new()
	segment.edge = supply_edge
	segment.start_node = source
	segment.end_node = host
	segment.forward = true
	route.start_node = source
	route.end_node = host
	route.segments.append(segment)
	route.found = true
	return route


## 导出引用可能保留已经 free 的对象；先以 Variant 检查，再读取成员。
func _is_alive_source(source: Variant) -> bool:
	return is_instance_valid(source) and source is MotherCore \
		and not source.is_queued_for_deletion() and source.health > 0


func _is_registered_organ(organ: Variant) -> bool:
	return is_instance_valid(organ) and organ is AttackOrgan \
		and not organ.is_queued_for_deletion() and _organs.has(organ.get_instance_id())


func _get_registered_organ(organ_id: int) -> AttackOrgan:
	if not _organs.has(organ_id) or not is_instance_valid(_organs[organ_id]):
		return null
	var organ: AttackOrgan = _organs[organ_id]
	if organ.is_queued_for_deletion():
		return null
	return organ


func _prune_organs() -> void:
	var organ_ids: Array[int] = _organ_order.duplicate()
	for organ_id: int in organ_ids:
		if _get_registered_organ(organ_id) == null:
			_remove_organ_registration(organ_id)


func _remove_organ_registration(organ_id: int) -> void:
	if not _organs.has(organ_id):
		return
	var removed: Variant = _organs[organ_id]
	if is_instance_valid(removed):
		var exit_callback: Callable = _organ_exit_callbacks[organ_id]
		if removed.tree_exiting.is_connected(exit_callback):
			removed.tree_exiting.disconnect(exit_callback)
	var removed_index: int = _organ_order.find(organ_id)
	_organs.erase(organ_id)
	_organ_order.erase(organ_id)
	_organ_exit_callbacks.erase(organ_id)
	if removed_index < _next_organ_index:
		_next_organ_index -= 1
	if _organ_order.is_empty():
		_next_organ_index = 0
	else:
		_next_organ_index %= _organ_order.size()
	_cancel_shipments_for_organ(organ_id)


func _cancel_shipments_for_organ(organ_id: int) -> void:
	for shipment_id: int in _shipments.keys():
		var shipment: Shipment = _shipments.get(shipment_id)
		if shipment != null and shipment.receiver_id == organ_id:
			_cancel_shipment(shipment_id)


func _cancel_shipment(shipment_id: int) -> void:
	var shipment: Shipment = _shipments.get(shipment_id)
	if shipment == null:
		return
	var packet: Variant = shipment.packet
	if is_instance_valid(packet):
		packet.cancel_transport()
	# 包自身的退出回调与这里的兜底可共存；记录先删除保证只退款一次。
	_settle_shipment(shipment_id, false)
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet.queue_free()


func _settle_shipment(shipment_id: int, was_delivered: bool) -> void:
	var shipment: Shipment = _shipments.get(shipment_id)
	if shipment == null:
		return
	# 到达信号本身不转移库存；伪造的早到通知不能交付或触发退款。
	if was_delivered and not _has_arrived(shipment):
		return

	_shipments.erase(shipment_id)
	shipment.is_settled = true
	var accepted: bool = false
	if was_delivered and _is_registered_organ(shipment.receiver) \
			and shipment.receiver.get_parent() == shipment.final_target:
		accepted = shipment.receiver.complete_delivery(PACKET_NUTRITION)
	shipment.was_delivered = accepted
	if accepted:
		delivered_packets += 1
		notice.emit("营养已送达攻击器官")
	else:
		_discard_passage_tracking(shipment)
		if is_instance_valid(shipment.receiver):
			shipment.receiver.cancel_reservation(PACKET_NUTRITION)
		if is_instance_valid(shipment.source):
			shipment.source.add_nutrition(PACKET_NUTRITION)
		interrupted_packets += 1
		notice.emit("供养已取消，营养退回母核")
	_emit_transport_changed()
	if accepted:
		_confirm_passage_tracking(shipment)


func _has_arrived(shipment: Shipment) -> bool:
	return is_instance_valid(shipment.final_target) and not shipment.final_target.is_queued_for_deletion() \
		and is_instance_valid(shipment.packet) \
		and shipment.packet.has_arrived_at(shipment.final_target, shipment.transport_task_id)


func _reject(message: String, show_rejection: bool) -> bool:
	if show_rejection:
		notice.emit(message)
	return false


func _emit_transport_changed() -> void:
	transport_changed.emit(get_in_transit_count(), delivered_packets, interrupted_packets)


func _exit_tree() -> void:
	_is_exiting = true
	var organ_ids: Array[int] = _organ_order.duplicate()
	for organ_id: int in organ_ids:
		_remove_organ_registration(organ_id)
	for shipment_id: int in _shipments.keys():
		_cancel_shipment(shipment_id)


## 显式交通配置失效不能退回旧的无容量运输；这里只校验配置，不预留通行。
func _traffic_configuration_is_valid(network: Variant, dispatcher: Variant, required: bool) -> bool:
	if dispatcher == null:
		return not required
	return is_instance_valid(dispatcher) and dispatcher is NetworkTrafficSystem \
		and not dispatcher.is_queued_for_deletion() and is_instance_valid(network) \
		and not network.is_queued_for_deletion() and dispatcher.network_system == network


## 清理原账本；关卡重开可同时封闭新派发，避免旧回调再次排队。
func reset(stop_dispatch: bool = false) -> void:
	if _resetting:
		return
	_resetting = true
	_reset_epoch += 1
	if stop_dispatch:
		_is_exiting = true
	for shipment_id: int in _shipments.keys():
		_cancel_shipment(shipment_id)
		if not is_instance_valid(self):
			return
	_resetting = false


func _bind_passage_tracking(shipment: Shipment) -> void:
	if not is_instance_valid(cargo_passage_tracker) or cargo_passage_tracker.is_queued_for_deletion():
		return
	shipment.cargo_id = "supply:" + shipment.transport_task_id
	shipment.cargo_generation = cargo_passage_tracker.register_cargo(shipment.cargo_id, &"supply")
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
