class_name TransplantSystem
extends Node
## 六份实物先送到原宿主；离开时统一消耗，身体沿共享 FIFO 搬迁且不生成替身。

signal task_changed(snapshot: Dictionary)
signal task_completed(task_id: int)
signal task_cancelled(task_id: int)
signal task_failed(task_id: int, reason: StringName)

const TOTAL_COST: int = 6
const MINIMUM_UNFOLD_TIME: float = 3.0
const MAX_TASK_ID: int = 9223372036854775807
const PACKET_SCENE: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")

class FeeShipment:
	extends RefCounted

	var shipment_id: String = ""
	var transport_task_id: String = ""
	var task_id: int = 0
	var generation: int = 0
	var source: MotherCore
	var source_available: bool = true
	var host: HyphaNode
	var packet: NutrientPacket
	var debited: bool = false
	var settled: bool = false
	var accepted: bool = false
	var refunded: bool = false
	var consumed: bool = false
	var cargo_id: String = ""
	var cargo_generation: int = -1
	var cargo_tracker_ref: WeakRef

class TransplantTask:
	extends RefCounted

	var task_id: int = 0
	var generation: int = 0
	var state: StringName = &"preparing"
	var wait_reason: StringName = &"nutrition"
	var organ: AttackOrgan
	var weapon: SporeWeapon
	var source: HyphaNode
	var destination: HyphaNode
	var core: MotherCore
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var packets: Node2D
	var migration_root: Node2D
	var reservation_id: String = ""
	var slot_reserved: bool = false
	var slot_committed: bool = false
	var departed: bool = false
	var buffered_nutrition: int = 0
	var consumed_nutrition: int = 0
	var unfold_time: float = 0.0
	var organ_transform: Transform2D = Transform2D.IDENTITY
	var weapon_transform: Transform2D = Transform2D.IDENTITY
	var weapon_offset: Vector2 = Vector2.ZERO
	var weapon_visible: bool = true
	var carrier: NutrientPacket
	var transport_task_id: String = ""
	var transport_snapshot: Dictionary = {}
	var route: NetworkRoute
	var fees: Array[FeeShipment] = []
	var watches: Array[Dictionary] = []
	var terminal_notified: bool = false

@export var mother_core: MotherCore
@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var combat_supply_system: SupplySystem
@export var repair_system: RepairSystem
@export var cargo_passage_tracker: CargoPassageTracker
@export var packet_container: Node2D
@export var migration_container: Node2D

var _current: TransplantTask
var _last_task_id: int = 0
var _next_shipment_serial: int = 1
var _generation: int = 1
var _shipments: Dictionary[String, FeeShipment] = {}
var _pending: Dictionary[String, FeeShipment] = {}
var _consumed_nutrition: int = 0
var _lost_nutrition: int = 0
var _refunded_nutrition: int = 0
var _dispatch_owner_ref: WeakRef
var _dispatch_owner_generation: int = 0
var _requesting: bool = false
var _dispatching: bool = false
var _transitioning: bool = false
var _advancing: bool = false
var _resetting: bool = false
var _stopped: bool = false
var _exiting: bool = false
var _reparent_depth: int = 0
var _emitting_changed: bool = false
var _changed_pending: bool = false
var _last_snapshot: Dictionary = {}


func _physics_process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	_exiting = true
	stop()


func preview_transplant(organ: AttackOrgan, destination: HyphaNode) -> Dictionary:
	var source: HyphaNode = organ.get_parent() as HyphaNode if _live(organ) else null
	var preview: Dictionary = {
		"valid": false, "reason": &"invalid_organ", "organ": organ if _live(organ) else null,
		"source": source, "destination": destination if _live(destination) else null,
		"total_cost": TOTAL_COST, "minimum_time": MINIMUM_UNFOLD_TIME, "route": null,
	}
	var reason: StringName = _admission_problem(organ, destination)
	preview["reason"] = reason
	preview["valid"] = reason == &""
	if reason == &"":
		preview["route"] = network_system.find_available_route(source, destination, 2)
	return preview


func request_transplant(organ: AttackOrgan, destination: HyphaNode) -> int:
	if _requesting or _dispatching or _transitioning or _advancing or _resetting \
		or not bool(preview_transplant(organ, destination)["valid"]):
		return 0
	_requesting = true
	_last_task_id += 1
	var record := TransplantTask.new()
	record.task_id = _last_task_id
	record.generation = _generation
	record.organ = organ
	record.weapon = organ._find_matching_weapon()
	record.source = organ.get_parent() as HyphaNode
	record.destination = destination
	record.core = mother_core
	record.network = network_system
	record.traffic = traffic_system
	record.packets = packet_container
	record.migration_root = migration_container
	record.reservation_id = "transplant:%d:%d" % [get_instance_id(), record.task_id]
	record.transport_task_id = record.reservation_id + ":body"
	record.organ_transform = organ.transform
	record.weapon_transform = record.weapon.transform
	record.weapon_offset = record.weapon.global_position - organ.global_position
	record.weapon_visible = record.weapon.visible
	record.route = record.network.find_available_route(record.source, destination, 2)
	_current = record
	# try_reserve 的同步通知内取消也能释放已写入菌结的预留。
	record.slot_reserved = true
	var reserved: bool = destination.try_reserve_organ_slot(record.reservation_id)
	if not reserved:
		record.slot_reserved = false
		_finish(record, &"failed", &"destination_reserved")
	elif _same_task(record):
		_watch_task(record)
		organ.set_transplanting(true)
		if _same_task(record):
			_refresh_task(record)
			_emit_changed()
	_requesting = false
	return record.task_id if _same_task(record) else 0


func cancel_task() -> bool:
	if _resetting or not has_active_task() or _current.state != &"preparing":
		return false
	_finish(_current, &"cancelled", &"cancelled")
	return true


func has_active_task() -> bool:
	return _current != null and _current.state in [&"preparing", &"migrating", &"unfolding"]


func is_transplanting(organ: AttackOrgan) -> bool:
	return has_active_task() and is_instance_valid(organ) and _current.organ == organ


func get_task_snapshot() -> Dictionary:
	if _current == null:
		return {"task_id": 0, "state": &"idle", "wait_reason": &"", "organ": null,
			"weapon": null, "source": null, "destination": null, "total_cost": TOTAL_COST,
			"buffered_nutrition": 0, "in_transit_nutrition": 0, "consumed_nutrition": 0,
			"effective_time": 0.0, "minimum_time": MINIMUM_UNFOLD_TIME,
			"progress": 0.0, "can_cancel": false, "departed": false, "route": null, "transport": {}}
	var record: TransplantTask = _current
	var transport: Dictionary = record.carrier.get_transport_snapshot() \
		if is_instance_valid(record.carrier) else record.transport_snapshot.duplicate()
	return {
		"task_id": record.task_id, "generation": record.generation,
		"state": record.state, "wait_reason": record.wait_reason,
		"organ": record.organ if is_instance_valid(record.organ) else null,
		"weapon": record.weapon if is_instance_valid(record.weapon) else null,
		"source": record.source if is_instance_valid(record.source) else null,
		"destination": record.destination if is_instance_valid(record.destination) else null,
		"total_cost": TOTAL_COST, "buffered_nutrition": record.buffered_nutrition,
		"in_transit_nutrition": _task_in_transit(record),
		"consumed_nutrition": record.consumed_nutrition,
		"effective_time": record.unfold_time, "minimum_time": MINIMUM_UNFOLD_TIME,
		"progress": clampf(record.unfold_time / MINIMUM_UNFOLD_TIME, 0.0, 1.0),
		"can_cancel": record.state == &"preparing", "departed": record.departed,
		"route": record.carrier.get_remaining_route() if is_instance_valid(record.carrier) else record.route, "transport": transport,
	}


func get_resource_snapshot() -> Dictionary:
	return {
		"buffered_nutrition": _current.buffered_nutrition if _current != null else 0,
		"in_transit_nutrition": get_in_transit_nutrition(),
		"consumed_nutrition": _consumed_nutrition, "lost_nutrition": _lost_nutrition,
	}


func get_in_transit_nutrition() -> int:
	var total: int = 0
	for shipment: FeeShipment in _pending.values():
		if shipment.debited and not shipment.settled and not shipment.refunded:
			total += 1
	return total


func get_shipment_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for shipment: FeeShipment in _shipments.values():
		records.append({
			"shipment_id": shipment.shipment_id, "task_id": shipment.task_id,
			"generation": shipment.generation, "transport_task_id": shipment.transport_task_id,
			"packet": shipment.packet if is_instance_valid(shipment.packet) else null,
			"source": shipment.source if is_instance_valid(shipment.source) else null,
			"host": shipment.host if is_instance_valid(shipment.host) else null,
			"debited": shipment.debited, "settled": shipment.settled,
			"accepted": shipment.accepted, "refunded": shipment.refunded,
			"consumed": shipment.consumed, "cargo_id": shipment.cargo_id,
		})
	return records


## 调度器独占派发；每轮仍只送一份费用，不增加第二条建设队列。
func claim_dispatch_owner(owner: Node) -> bool:
	if not _live(owner) or _exiting or _resetting:
		return false
	var current_owner: Node = get_dispatch_owner()
	if current_owner != null and current_owner != owner:
		return false
	if current_owner == null:
		_dispatch_owner_ref = weakref(owner)
		_dispatch_owner_generation += 1
	return true


func get_dispatch_owner() -> Node:
	var owner: Node = _dispatch_owner_ref.get_ref() as Node if _dispatch_owner_ref != null else null
	return owner if _live(owner) else null


func release_dispatch_owner(owner: Node) -> void:
	if _dispatch_owner_ref != null and _dispatch_owner_ref.get_ref() == owner:
		_dispatch_owner_ref = null
		_dispatch_owner_generation += 1


func can_dispatch_scheduled(owner: Node) -> bool:
	return owner != null and get_dispatch_owner() == owner and _can_dispatch()


func try_dispatch_scheduled(owner: Node) -> bool:
	if not can_dispatch_scheduled(owner):
		return false
	return _dispatch_fee(owner)


func try_dispatch() -> bool:
	if get_dispatch_owner() != null or not _can_dispatch():
		return false
	return _dispatch_fee(null)


func advance(delta: float) -> void:
	if not has_active_task() or _advancing or _transitioning or _dispatching \
		or _resetting or _exiting or _stopped or not is_finite(delta) or delta <= 0.0:
		return
	_advancing = true
	var record: TransplantTask = _current
	_refresh_task(record)
	if _same_task(record) and record.state == &"preparing" \
		and record.buffered_nutrition == TOTAL_COST and record.wait_reason == &"":
		_depart(record)
	elif _same_task(record) and record.state == &"migrating":
		_sync_body(record)
	elif _same_task(record) and record.state == &"unfolding" and record.wait_reason == &"":
		record.unfold_time = minf(MINIMUM_UNFOLD_TIME, record.unfold_time + delta)
		if record.unfold_time >= MINIMUM_UNFOLD_TIME:
			_finish(record, &"completed", &"")
	_advancing = false
	_emit_changed()


func abort_destroyed_organ(organ: AttackOrgan) -> void:
	if is_transplanting(organ):
		_finish(_current, &"failed", &"organ_destroyed")


func reset() -> void:
	if _resetting:
		return
	_resetting = true
	_generation += 1
	if has_active_task():
		_finish(_current, &"failed", &"reset")
	_stopped = false
	_resetting = false
	_emit_changed()


func stop() -> void:
	if _resetting:
		return
	_stopped = true
	_resetting = true
	_generation += 1
	if has_active_task():
		_finish(_current, &"failed", &"stopped")
	_resetting = false


func _admission_problem(organ: AttackOrgan, destination: HyphaNode) -> StringName:
	if _stopped or _exiting:
		return &"stopped"
	if _requesting or _transitioning or _resetting or has_active_task():
		return &"busy"
	if _last_task_id == MAX_TASK_ID or not _configuration_valid():
		return &"invalid_configuration"
	if not _live(organ) or not organ.is_attackable() or organ.is_transplanting():
		return &"invalid_organ"
	var source: HyphaNode = organ.get_parent() as HyphaNode
	var weapon: SporeWeapon = organ._find_matching_weapon()
	if not _live(source) or not network_system.is_node_registered(source) \
		or source.get_organ_slot_state() != &"attack" or source.get_organ_occupant() != organ \
		or not _live(weapon) or weapon.inventory_owner != organ or not weapon.has_valid_profile():
		return &"not_mature_organ"
	if organ._get_differentiation_record().is_active():
		return &"differentiating"
	if not _live(destination) or not network_system.is_node_registered(destination):
		return &"invalid_destination"
	if source == destination:
		return &"same_destination"
	if not destination.is_organ_slot_available():
		return &"destination_occupied"
	if _repair_conflicts(organ, source, destination):
		return &"repairing"
	if not source.is_functional() or not destination.is_functional():
		return &"withered"
	if mother_core.health <= 0:
		return &"core_unavailable"
	if not network_system.find_available_route(mother_core, source).found \
		or not network_system.find_available_route(source, destination, 2).found:
		return &"disconnected"
	return &""


func _configuration_valid() -> bool:
	return _live(self) and _live(mother_core) and _live(network_system) \
		and _live(traffic_system) and traffic_system.network_system == network_system \
		and _live(combat_supply_system) and not combat_supply_system.is_stopped() \
		and combat_supply_system.has_method("cancel_organ_shipments") \
		and _live(packet_container) and _live(migration_container) \
		and network_system.is_node_registered(mother_core)


func _repair_conflicts(organ: AttackOrgan, source: HyphaNode, destination: HyphaNode) -> bool:
	if not _live(repair_system) or not repair_system.has_active_task():
		return false
	var target: Variant = repair_system.get_task_snapshot().get("target")
	return target == organ or target == source or target == destination


func _same_task(record: TransplantTask) -> bool:
	return _current == record and record.generation == _generation and has_active_task() \
		and not _stopped and not _exiting and not _resetting


func _permanent_problem(record: TransplantTask) -> StringName:
	if not _live(record.organ) or not record.organ.is_attackable():
		return &"organ_destroyed"
	if not _live(record.weapon) or record.weapon.inventory_owner != record.organ:
		return &"weapon_removed"
	if not _live(record.network) or not _live(record.traffic) \
		or record.traffic.network_system != record.network:
		return &"network_unavailable"
	if record.network != network_system or record.traffic != traffic_system \
		or record.core != mother_core or record.packets != packet_container \
		or record.migration_root != migration_container or not _live(record.migration_root):
		return &"configuration_changed"
	if not _live(record.destination) or not record.network.is_node_registered(record.destination):
		return &"destination_removed"
	var occupant: Node = record.destination.get_organ_occupant()
	if record.slot_committed:
		if occupant != record.organ or record.organ.get_parent() != record.destination \
			or record.weapon.get_parent() != record.destination:
			return &"destination_changed"
	elif not record.slot_reserved or record.destination.get_organ_slot_state() != &"reserved" \
		or occupant != null:
		return &"destination_changed"
	if not record.departed:
		if not _live(record.source) or not record.network.is_node_registered(record.source) \
			or record.organ.get_parent() != record.source or record.weapon.get_parent() != record.source \
			or record.source.get_organ_occupant() != record.organ:
			return &"source_removed"
		if not _live(record.core) or not _live(record.packets):
			return &"core_unavailable"
		if record.organ._get_differentiation_record().is_active():
			return &"differentiating"
	return &""


func _refresh_task(record: TransplantTask) -> void:
	if not _same_task(record) or _transitioning:
		return
	var reason: StringName = _permanent_problem(record)
	if reason != &"":
		_finish(record, &"failed", reason)
	elif record.state == &"preparing":
		record.wait_reason = _preparing_wait(record)
		if record.wait_reason == &"" or record.wait_reason in [&"nutrition", &"in_transit", &"core_empty", &"combat_reserve", &"repair_budget"]:
			record.route = record.network.find_available_route(record.source, record.destination, 2)
	elif record.state == &"unfolding":
		if not record.destination.is_functional():
			record.wait_reason = &"withered"
		elif not _live(record.core) or record.core.health <= 0 \
			or not record.network.is_work_connected_to_core(record.destination):
			record.wait_reason = &"disconnected"
		else:
			record.wait_reason = &""


func _preparing_wait(record: TransplantTask) -> StringName:
	if record.core.health <= 0:
		return &"core_unavailable"
	if not record.source.is_functional() or not record.destination.is_functional():
		return &"withered"
	if _repair_conflicts(record.organ, record.source, record.destination):
		return &"repairing"
	if not record.network.find_available_route(record.core, record.source).found \
		or not record.network.find_available_route(record.source, record.destination, 2).found:
		return &"disconnected"
	if record.buffered_nutrition == TOTAL_COST:
		return &""
	if _task_in_transit(record) > 0:
		return &"in_transit"
	if record.core.get_spendable_nutrition() <= 0:
		return &"repair_budget" if record.core.nutrition > 0 else &"core_empty"
	if _available_nutrition(record.core) <= 0:
		return &"combat_reserve"
	return &"nutrition"


func _combat_reserve() -> int:
	if not _live(combat_supply_system):
		return 0
	var reserve: int = 0
	for organ: AttackOrgan in combat_supply_system.get_active_organs():
		if _live(organ):
			reserve += maxi(0, 2 * organ.get_shot_nutrition_cost() \
				- organ.nutrition - organ.incoming_nutrition)
	return reserve


func _available_nutrition(source: MotherCore) -> int:
	return maxi(0, source.get_spendable_nutrition() - _combat_reserve()) if _live(source) else 0


func _can_dispatch() -> bool:
	if _dispatching or _transitioning or _resetting or _stopped or _exiting \
		or not has_active_task() or _current.state != &"preparing":
		return false
	var record: TransplantTask = _current
	return _same_task(record) and _permanent_problem(record) == &"" \
		and record.core.health > 0 and record.source.is_functional() \
		and record.buffered_nutrition + _task_outstanding(record) < TOTAL_COST \
		and not _repair_conflicts(record.organ, record.source, record.destination) \
		and record.network.find_available_route(record.core, record.source).found \
		and _available_nutrition(record.core) > 0


func _dispatch_is_current(record: TransplantTask, owner: Node, owner_generation: int) -> bool:
	return _same_task(record) and record.state == &"preparing" \
		and owner_generation == _dispatch_owner_generation and get_dispatch_owner() == owner


func _dispatch_fee(owner: Node) -> bool:
	_dispatching = true
	var record: TransplantTask = _current
	var owner_generation: int = _dispatch_owner_generation
	var route: NetworkRoute = record.network.find_available_route(record.core, record.source)
	var packet: NutrientPacket = PACKET_SCENE.instantiate() as NutrientPacket
	packet.traffic_required = true
	var shipment := FeeShipment.new()
	shipment.shipment_id = "transplant_fee:%d:%d" % [get_instance_id(), _next_shipment_serial]
	_next_shipment_serial += 1
	shipment.transport_task_id = shipment.shipment_id
	shipment.task_id = record.task_id
	shipment.generation = record.generation
	shipment.source = record.core
	shipment.host = record.source
	shipment.packet = packet
	record.fees.append(shipment)
	_shipments[shipment.shipment_id] = shipment
	_pending[shipment.shipment_id] = shipment
	_bind_fee_tracking(shipment)
	packet.arrived.connect(_on_fee_arrived.bind(shipment.shipment_id))
	packet.interrupted.connect(_on_fee_interrupted.bind(shipment.shipment_id))
	packet.tree_exiting.connect(_on_fee_removed.bind(shipment.shipment_id))
	record.packets.add_child(packet)
	if not _dispatch_is_current(record, owner, owner_generation) or shipment.settled \
		or not _live(packet) or _permanent_problem(record) != &"" \
		or _available_nutrition(record.core) <= 0 or not route.found \
		or record.buffered_nutrition + _task_outstanding(record) > TOTAL_COST:
		_refund_fee(shipment)
	else:
		# 扣款通知中的取消可以看见这一单位，且结算标志先于任何退款回调。
		shipment.debited = true
		var spent: bool = record.core.try_spend_nutrition(1)
		if not spent:
			shipment.debited = false
			_refund_fee(shipment)
		elif not _dispatch_is_current(record, owner, owner_generation) or shipment.settled \
			or not _live(packet) or _permanent_problem(record) != &"":
			_refund_fee(shipment)
		else:
			packet.start_route(route, record.network, record.traffic, shipment.transport_task_id, &"supply")
	var dispatched: bool = shipment.debited and not shipment.refunded \
		and (shipment.accepted or not shipment.settled)
	_dispatching = false
	if _same_task(record):
		_refresh_task(record)
	_emit_changed()
	return dispatched


func _on_fee_arrived(packet: NutrientPacket, shipment_id: String) -> void:
	var shipment: FeeShipment = _pending.get(shipment_id)
	if shipment == null or shipment.packet != packet or shipment.settled:
		return
	var accepted: bool = shipment.debited and _current != null and _same_task(_current) \
		and _current.task_id == shipment.task_id and _current.generation == shipment.generation \
		and _current.state == &"preparing" and _permanent_problem(_current) == &"" \
		and _current.source == shipment.host \
		and packet.has_arrived_at(shipment.host, shipment.transport_task_id) \
		and _current.buffered_nutrition < TOTAL_COST
	if accepted:
		shipment.settled = true
		shipment.accepted = true
		_pending.erase(shipment_id)
		_current.buffered_nutrition += 1
		_refresh_task(_current)
	else:
		_refund_fee(shipment)
	_emit_changed()


func _on_fee_interrupted(packet: NutrientPacket, shipment_id: String) -> void:
	var shipment: FeeShipment = _pending.get(shipment_id)
	if shipment != null and shipment.packet == packet:
		_refund_fee(shipment)
		_emit_changed()


func _on_fee_removed(shipment_id: String) -> void:
	var shipment: FeeShipment = _pending.get(shipment_id)
	if shipment != null:
		_refund_fee(shipment)
		_emit_changed()


func _refund_fee(shipment: FeeShipment) -> void:
	if shipment.refunded or shipment.consumed:
		return
	shipment.refunded = true
	shipment.settled = true
	_pending.erase(shipment.shipment_id)
	_discard_fee_tracking(shipment)
	if is_instance_valid(shipment.packet) and not shipment.packet.is_queued_for_deletion():
		shipment.packet.cancel_transport()
	if shipment.debited:
		if shipment.source_available and _live(shipment.source):
			_refunded_nutrition += 1
			shipment.source.add_nutrition(1)
		else:
			_lost_nutrition += 1


func _depart(record: TransplantTask) -> void:
	var route: NetworkRoute = record.network.find_available_route(record.source, record.destination, 2)
	if not _same_task(record) or not route.found or _permanent_problem(record) != &"":
		return
	_transitioning = true
	record.route = route
	var carrier: NutrientPacket = PACKET_SCENE.instantiate() as NutrientPacket
	carrier.traffic_required = true
	carrier.visible = false
	record.carrier = carrier
	carrier.arrived.connect(_on_carrier_arrived.bind(record.task_id, record.generation))
	carrier.interrupted.connect(_on_carrier_interrupted.bind(record.task_id, record.generation))
	carrier.status_changed.connect(_on_carrier_status.bind(record.task_id, record.generation))
	carrier.tree_exiting.connect(_on_carrier_removed.bind(record.task_id, record.generation))
	record.migration_root.add_child(carrier)
	if _same_task(record) and _live(carrier) and _permanent_problem(record) == &"":
		# 所有可退费用先同时变成消耗，再开放任何库存、树或候选通行通知。
		record.departed = true
		record.state = &"migrating"
		record.wait_reason = &""
		record.buffered_nutrition = 0
		record.consumed_nutrition = TOTAL_COST
		_consumed_nutrition += TOTAL_COST
		for shipment: FeeShipment in record.fees:
			if shipment.accepted and not shipment.refunded:
				shipment.consumed = true
		combat_supply_system.cancel_organ_shipments(record.organ)
		if _same_task(record):
			combat_supply_system.unregister_organ(record.organ)
		if _same_task(record):
			_transfer_body(record, record.migration_root)
		if _same_task(record):
			record.organ.rebind_host(null)
			record.weapon.rebind_after_transplant()
			record.weapon.visible = false
			carrier.global_position = record.source.global_position
			_sync_body(record)
		for shipment: FeeShipment in record.fees:
			if shipment.consumed:
				_confirm_fee_tracking(shipment)
		if _same_task(record) and _live(carrier):
			carrier.start_route(route, record.network, record.traffic, record.transport_task_id, &"transplant")
	else:
		if is_instance_valid(carrier) and not carrier.is_queued_for_deletion():
			carrier.cancel_transport()
	_transitioning = false


func _transfer_body(record: TransplantTask, target: Node2D) -> void:
	_reparent_depth += 1
	record.organ.reparent(target, true)
	if _same_task(record) and _live(record.weapon):
		record.weapon.reparent(target, true)
	_reparent_depth -= 1


func _sync_body(record: TransplantTask) -> void:
	if record.state != &"migrating" or not _live(record.organ) \
		or not is_instance_valid(record.carrier) or not _live(record.weapon):
		return
	record.organ.global_position = record.carrier.global_position
	record.weapon.global_position = record.organ.global_position + record.weapon_offset


func _on_carrier_status(snapshot: Dictionary, task_id: int, generation: int) -> void:
	if not _matches_carrier_task(task_id, generation) or _current.state != &"migrating":
		return
	_current.transport_snapshot = snapshot.duplicate()
	_current.wait_reason = StringName(snapshot.get("wait_reason", &""))
	_sync_body(_current)
	_emit_changed()


func _on_carrier_arrived(packet: NutrientPacket, task_id: int, generation: int) -> void:
	if not _matches_carrier_task(task_id, generation) or _current.carrier != packet \
		or _current.state != &"migrating":
		return
	var record: TransplantTask = _current
	if not packet.has_arrived_at(record.destination, record.transport_task_id) \
		or _permanent_problem(record) != &"":
		_finish(record, &"failed", &"destination_removed")
		return
	var previous_transition: bool = _transitioning
	_transitioning = true
	_sync_body(record)
	record.transport_snapshot = packet.get_transport_snapshot()
	_transfer_body(record, record.destination)
	if _same_task(record):
		record.organ.transform = record.organ_transform
		record.weapon.transform = record.weapon_transform
		record.organ.rebind_host(record.destination)
		record.weapon.rebind_after_transplant()
		record.state = &"unfolding"
		record.unfold_time = 0.0
		# commit 发出同步槽位通知时，公开记录已经能识别同一器官。
		record.slot_reserved = false
		record.slot_committed = true
		var committed: bool = record.destination.commit_organ_slot(record.reservation_id, record.organ)
		if not committed:
			record.slot_reserved = true
			record.slot_committed = false
			_finish(record, &"failed", &"destination_changed")
		elif _same_task(record):
			combat_supply_system.register_organ(record.organ)
			var controller: Node = record.organ._get_differentiation_record().get_controller()
			if _same_task(record) and is_instance_valid(controller) \
				and controller.has_method("rebind_organ_host"):
				controller.call("rebind_organ_host", record.organ)
	_transitioning = previous_transition
	if _same_task(record):
		_refresh_task(record)
	_emit_changed()


func _on_carrier_interrupted(packet: NutrientPacket, task_id: int, generation: int) -> void:
	if _matches_carrier_task(task_id, generation) and _current.carrier == packet \
		and _current.state == &"migrating":
		_finish(_current, &"failed", StringName(packet.get_transport_snapshot().get("wait_reason", &"transport_lost")))


func _on_carrier_removed(task_id: int, generation: int) -> void:
	if _matches_carrier_task(task_id, generation) and _current.state == &"migrating":
		_finish(_current, &"failed", &"transport_lost")


func _matches_carrier_task(task_id: int, generation: int) -> bool:
	return has_active_task() and _current.task_id == task_id \
		and _current.generation == generation and _same_task(_current)


func _on_owned_node_exiting(task_id: int, generation: int, kind: StringName) -> void:
	if _reparent_depth > 0 or not _matches_carrier_task(task_id, generation):
		return
	if kind == &"source_removed" and _current.departed:
		return
	if kind == &"core_unavailable":
		for shipment: FeeShipment in _current.fees:
			shipment.source_available = false
	_finish(_current, &"failed", kind)


func _on_organ_destroyed(organ: Node2D, task_id: int, generation: int) -> void:
	if _matches_carrier_task(task_id, generation) and _current.organ == organ:
		abort_destroyed_organ(organ as AttackOrgan)


func _on_dependencies_changed(task_id: int, generation: int) -> void:
	if _matches_carrier_task(task_id, generation) and not _transitioning and _reparent_depth == 0:
		_refresh_task(_current)
		_emit_changed()


func _watch_task(record: TransplantTask) -> void:
	for entry: Array in [[record.organ, &"organ_removed"], [record.weapon, &"weapon_removed"],
		[record.source, &"source_removed"], [record.destination, &"destination_removed"],
		[record.core, &"core_unavailable"], [record.network, &"network_unavailable"],
		[record.traffic, &"traffic_unavailable"], [record.migration_root, &"migration_container_removed"]]:
		_watch(record, entry[0] as Node, &"tree_exiting",
			_on_owned_node_exiting.bind(record.task_id, record.generation, entry[1]))
	_watch(record, record.organ, &"tissue_destroyed", _on_organ_destroyed.bind(record.task_id, record.generation))
	_watch(record, record.network, &"network_changed", _on_dependencies_changed.bind(record.task_id, record.generation))
	_watch(record, record.destination, &"organ_slot_changed", _on_dependencies_changed.bind(record.task_id, record.generation))


func _watch(record: TransplantTask, node: Node, signal_name: StringName, callback: Callable) -> void:
	if _live(node) and not node.is_connected(signal_name, callback):
		node.connect(signal_name, callback)
		record.watches.append({"node": weakref(node), "signal": signal_name, "callback": callback})


func _disconnect_task(record: TransplantTask) -> void:
	var watches: Array[Dictionary] = record.watches.duplicate()
	record.watches.clear()
	for watch: Dictionary in watches:
		var reference: WeakRef = watch["node"]
		var node: Node = reference.get_ref() as Node
		var callback: Callable = watch["callback"]
		var signal_name: StringName = watch["signal"]
		if is_instance_valid(node) and node.is_connected(signal_name, callback):
			node.disconnect(signal_name, callback)


func _finish(record: TransplantTask, state: StringName, reason: StringName) -> void:
	if _current != record or record.terminal_notified:
		return
	var previous_transition: bool = _transitioning
	_transitioning = true
	# 在释放预留、退款、伤害或 tree_exiting 之前关闭旧任务和所有回调身份。
	record.state = state
	record.wait_reason = reason
	record.terminal_notified = true
	record.buffered_nutrition = 0
	_disconnect_task(record)
	if record.slot_reserved:
		record.slot_reserved = false
		if is_instance_valid(record.destination):
			record.destination.release_organ_slot(record.reservation_id)
	for shipment: FeeShipment in record.fees:
		if not shipment.consumed:
			_refund_fee(shipment)
	if is_instance_valid(record.carrier):
		record.transport_snapshot = record.carrier.get_transport_snapshot()
		if not record.carrier.is_queued_for_deletion():
			record.carrier.cancel_transport()
	var lost_body: bool = state != &"completed" and (record.departed \
		or reason in [&"organ_removed", &"weapon_removed", &"source_removed"])
	if is_instance_valid(record.organ):
		if lost_body and record.organ.is_attackable():
			# 原组织的生命周期负责唯一库存损耗；这里没有退款或恢复到原宿主。
			record.organ.take_damage(record.organ.health)
		if is_instance_valid(record.organ):
			record.organ.set_transplanting(false)
		if lost_body and is_instance_valid(record.organ) and not record.organ.is_queued_for_deletion():
			record.organ.queue_free()
	if lost_body and is_instance_valid(record.weapon) and not record.weapon.is_queued_for_deletion():
		record.weapon.queue_free()
	elif not lost_body and is_instance_valid(record.weapon):
		record.weapon.visible = record.weapon_visible
		record.weapon.rebind_after_transplant()
	_emit_changed()
	if state == &"completed":
		task_completed.emit(record.task_id)
	elif state == &"cancelled":
		task_cancelled.emit(record.task_id)
	else:
		task_failed.emit(record.task_id, reason)
	_transitioning = previous_transition


func _bind_fee_tracking(shipment: FeeShipment) -> void:
	if not _live(cargo_passage_tracker):
		return
	shipment.cargo_id = shipment.transport_task_id
	shipment.cargo_generation = cargo_passage_tracker.register_cargo(shipment.cargo_id, &"construction")
	if shipment.cargo_generation >= 0:
		shipment.cargo_tracker_ref = weakref(cargo_passage_tracker)
		shipment.packet.bind_cargo(cargo_passage_tracker, shipment.cargo_id, shipment.cargo_generation)


func _confirm_fee_tracking(shipment: FeeShipment) -> void:
	var tracker: CargoPassageTracker = shipment.cargo_tracker_ref.get_ref() as CargoPassageTracker \
		if shipment.cargo_tracker_ref != null else null
	if _live(tracker):
		tracker.confirm_cargo(shipment.cargo_id, shipment.cargo_generation)


func _discard_fee_tracking(shipment: FeeShipment) -> void:
	var tracker: CargoPassageTracker = shipment.cargo_tracker_ref.get_ref() as CargoPassageTracker \
		if shipment.cargo_tracker_ref != null else null
	if _live(tracker):
		tracker.discard_cargo(shipment.cargo_id, shipment.cargo_generation)


func _task_outstanding(record: TransplantTask) -> int:
	var total: int = 0
	for shipment: FeeShipment in record.fees:
		if not shipment.settled:
			total += 1
	return total


func _task_in_transit(record: TransplantTask) -> int:
	var total: int = 0
	for shipment: FeeShipment in record.fees:
		if shipment.debited and not shipment.settled and not shipment.refunded:
			total += 1
	return total


func _live(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion() \
		and node.is_inside_tree() and node.is_node_ready()


func _emit_changed() -> void:
	if _exiting:
		return
	if _emitting_changed:
		_changed_pending = true
		return
	_emitting_changed = true
	_changed_pending = true
	while _changed_pending:
		_changed_pending = false
		var snapshot: Dictionary = get_task_snapshot()
		if snapshot != _last_snapshot:
			_last_snapshot = snapshot.duplicate(true)
			task_changed.emit(snapshot)
	_emitting_changed = false
