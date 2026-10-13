class_name RecyclingSystem
extends Node
## 优先采集地面尸体；大型残骸只有在场域、路线和胃囊容量就绪时才生成有限批次。

signal recycling_changed(in_transit: int, delivered: int, interrupted: int)

const TRANSPORT_SPEED: float = 140.0

class CollectionChoice:
	extends RefCounted

	var remains: EnemyRemains
	var carcass: LargeCarcass
	var route: NetworkRoute
	var receiver: DigestiveOrgan
	var score: float = INF
	var generation: int = 0
	var reservation_id: String = ""


class Shipment:
	extends RefCounted

	var cargo_id: String = ""
	var cargo_generation: int = -1
	var cargo_tracker_ref: WeakRef

	var remains: EnemyRemains
	var receiver: DigestiveOrgan
	var receiver_id: int
	var packet: RemainsPacket
	var nutrition: int
	var final_target: Node2D
	var transport_task_id: String = ""
	var started: bool = false
	var generation: int = 0
	var reservation_id: String = ""
	var owner_exit_callback: Callable
	var packet_exit_callback: Callable

	func _init(original_remains: EnemyRemains, original_receiver: DigestiveOrgan,
			transport_packet: RemainsPacket, nutrition_value: int,
			owner_callback: Callable, packet_callback: Callable) -> void:
		remains = original_remains
		receiver = original_receiver
		receiver_id = original_receiver.get_instance_id()
		packet = transport_packet
		nutrition = nutrition_value
		owner_exit_callback = owner_callback
		packet_exit_callback = packet_callback


@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var traffic_required: bool = false
@export var fungal_field: FungalField
@export var digestive_organ: DigestiveOrgan
@export var cargo_passage_tracker: CargoPassageTracker
@export var remains_container: Node2D
@export var packet_container: Node2D
@export var packet_scene: PackedScene
@export var batch_scene: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")

var delivered_count: int = 0
var interrupted_count: int = 0

var _shipments: Dictionary[int, Shipment] = {}
var _receiver_exit_callbacks: Dictionary[int, Callable] = {}
var _registered_digestives: Dictionary[int, DigestiveOrgan] = {}
var _digestive_exit_callbacks: Dictionary[int, Callable] = {}
var _is_exiting: bool = false
var _is_dispatching: bool = false
var _resetting: bool = false
var _next_harvest_serial: int = 1
var _next_reservation_serial: int = 1
var _generation: int = 0


func _enter_tree() -> void:
	_is_exiting = false
	for receiver: DigestiveOrgan in get_digestive_organs():
		_watch_registered_receiver(receiver)


func _exit_tree() -> void:
	_is_exiting = true
	_generation += 1
	for shipment_id: int in _shipments.keys():
		_cancel_shipment(shipment_id)
	for receiver: DigestiveOrgan in get_digestive_organs():
		_unwatch_registered_receiver(receiver)


func _on_dispatch_timer_timeout() -> void:
	try_dispatch()


func _on_packet_arrived(packet: RemainsPacket) -> void:
	_settle_shipment(packet.get_instance_id(), true)


func _on_packet_interrupted(packet: RemainsPacket) -> void:
	_settle_shipment(packet.get_instance_id(), false)


func _on_packet_removed(shipment_id: int) -> void:
	_settle_shipment(shipment_id, false)


func _on_shipment_owner_removed(shipment_id: int) -> void:
	_cancel_shipment(shipment_id)


func _on_receiver_removed(receiver_id: int) -> void:
	for shipment_id: int in _shipments.keys():
		var shipment: Shipment = _shipments.get(shipment_id) as Shipment
		if shipment != null and shipment.receiver_id == receiver_id:
			_cancel_shipment(shipment_id)


func _on_registered_receiver_removed(receiver_id: int) -> void:
	var raw_receiver: Variant = _registered_digestives.get(receiver_id)
	if not is_instance_valid(raw_receiver) and is_instance_valid(digestive_organ) \
			and digestive_organ.get_instance_id() == receiver_id:
		raw_receiver = digestive_organ
	if is_instance_valid(raw_receiver):
		_unwatch_registered_receiver(raw_receiver as DigestiveOrgan)
	_registered_digestives.erase(receiver_id)
	_digestive_exit_callbacks.erase(receiver_id)
	_on_receiver_removed(receiver_id)


func register_digestive(organ: DigestiveOrgan) -> bool:
	if not _is_live_node(organ) or not organ.is_attackable():
		return false
	_registered_digestives[organ.get_instance_id()] = organ
	_watch_registered_receiver(organ)
	return true


func unregister_digestive(organ: DigestiveOrgan) -> void:
	if not is_instance_valid(organ):
		return
	var receiver_id: int = organ.get_instance_id()
	_registered_digestives.erase(receiver_id)
	if digestive_organ == organ:
		digestive_organ = null
	_unwatch_registered_receiver(organ)
	_on_receiver_removed(receiver_id)


func get_digestive_organs() -> Array[DigestiveOrgan]:
	var organs: Array[DigestiveOrgan] = []
	# 导出引用自动参与登记；切换旧兼容引用不会改变已派遣运输的固定接收者。
	if _is_live_node(digestive_organ) and digestive_organ.is_attackable():
		organs.append(digestive_organ)
	for raw_organ: Variant in _registered_digestives.values():
		if _is_live_node(raw_organ) and raw_organ.is_attackable() and not organs.has(raw_organ):
			organs.append(raw_organ as DigestiveOrgan)
	return organs


func _watch_registered_receiver(receiver: DigestiveOrgan) -> void:
	var receiver_id: int = receiver.get_instance_id()
	if _digestive_exit_callbacks.has(receiver_id):
		return
	var callback: Callable = _on_registered_receiver_removed.bind(receiver_id)
	_digestive_exit_callbacks[receiver_id] = callback
	if not receiver.tree_exiting.is_connected(callback):
		receiver.tree_exiting.connect(callback)


func _unwatch_registered_receiver(receiver: DigestiveOrgan) -> void:
	var receiver_id: int = receiver.get_instance_id()
	if not _digestive_exit_callbacks.has(receiver_id):
		return
	var callback: Callable = _digestive_exit_callbacks[receiver_id]
	_digestive_exit_callbacks.erase(receiver_id)
	if receiver.tree_exiting.is_connected(callback):
		receiver.tree_exiting.disconnect(callback)


func get_in_transit_count() -> int:
	return _shipments.size()


func get_shipment_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for shipment: Shipment in _shipments.values():
		records.append({
			"remains": shipment.remains, "receiver": shipment.receiver,
			"receiver_id": shipment.receiver_id, "nutrition": shipment.nutrition,
			"reservation_id": shipment.reservation_id,
			"packet": shipment.packet, "final_target": shipment.final_target,
			"transport_task_id": shipment.transport_task_id, "started": shipment.started,
		})
	return records


func try_dispatch() -> bool:
	if _is_exiting or _resetting or _is_dispatching or not is_inside_tree():
		return false
	# 容量、源库存和网络查询均可能同步通知外部；一次调用只拥有一次派遣。
	_is_dispatching = true
	var dispatched: bool = _dispatch_once()
	if is_instance_valid(self):
		_refresh_carcass_statuses()
	if is_instance_valid(self):
		_is_dispatching = false
	return dispatched


func _dispatch_once() -> bool:
	# 先检查原引用，避免已经 free 的成员赋给强类型局部变量时出错。
	if not _is_live_node(network_system) or not _is_live_node(fungal_field) or (
		get_digestive_organs().is_empty() or not _is_live_node(packet_container)
	):
		return false
	if not _traffic_configuration_is_valid(network_system, traffic_system, traffic_required):
		return false
	# 将本次使用的依赖固定下来；信号回调可以修改下一次派遣的配置。
	var network: NetworkSystem = network_system
	var dispatcher: Variant = traffic_system
	var require_traffic: bool = traffic_required or dispatcher != null
	var field: FungalField = fungal_field
	var generation: int = _generation
	var destination_container: Node2D = packet_container
	var transport_scene: PackedScene = packet_scene
	if not destination_container.is_inside_tree() or transport_scene == null:
		return false
	var choice: CollectionChoice = _find_dispatch_choice(network, field, generation)
	if choice == null:
		choice = _find_carcass_choice(network, field, generation)
		if choice == null:
			return false
		return _harvest_and_dispatch(choice, choice.receiver, network, field,
			destination_container, transport_scene, dispatcher, require_traffic)
	var receiver: DigestiveOrgan = choice.receiver
	if not _is_current_generation(generation) or not _receiver_is_available(receiver) \
			or not _traffic_configuration_is_valid(network, dispatcher, require_traffic):
		return false
	var receiver_node: Node2D = receiver.get_parent() as Node2D
	choice.reservation_id = _new_input_reservation_id()
	if not receiver.reserve_remains(choice.reservation_id):
		return false
	# reserve_remains 发出信号后，尸体可能已被另一个回收系统领取。
	if not _is_current_generation(generation) or not _is_registered_receiver(receiver) \
			or not _is_live_node(receiver) or not receiver.is_functional() or not receiver.is_inside_tree() or (
		not _is_live_node(destination_container) or not destination_container.is_inside_tree()
	) or not _is_live_node(choice.remains) or not _route_is_current(choice.route,
		choice.remains.global_position, receiver_node, network, field) or (
		not _is_live_node(receiver) or receiver.get_parent() != receiver_node
	) or not receiver.owns_remains_reservation(choice.reservation_id) \
			or not _is_live_node(choice.remains) or not choice.remains.try_claim():
		if is_instance_valid(receiver):
			receiver.cancel_reservation(choice.reservation_id)
		return false

	var remains: EnemyRemains = choice.remains
	var nutrition: int = remains.nutrition_value
	var instance: Node = transport_scene.instantiate()
	if not instance is RemainsPacket:
		if is_instance_valid(instance):
			instance.free()
		receiver.cancel_reservation(choice.reservation_id)
		remains.release_claim(remains.global_position)
		return false
	var packet: RemainsPacket = instance as RemainsPacket
	_start_shipment(remains, receiver, packet, nutrition, choice.route, network, destination_container,
		dispatcher, require_traffic, generation, choice.reservation_id)
	return true


func _start_shipment(remains: EnemyRemains, receiver: DigestiveOrgan,
		packet: RemainsPacket, nutrition: int, route: NetworkRoute,
		network: NetworkSystem, destination_container: Node2D,
		dispatcher: Variant, require_traffic: bool, generation: int, reservation_id: String) -> void:
	if not _is_current_generation(generation) or not _is_registered_receiver(receiver) \
			or not receiver.owns_remains_reservation(reservation_id):
		if is_instance_valid(receiver):
			receiver.cancel_reservation(reservation_id)
		if _is_live_node(remains):
			remains.release_claim(remains.global_position)
		_discard_packet(packet)
		return
	packet.traffic_required = require_traffic
	var shipment_id: int = packet.get_instance_id()
	var shipment: Shipment = Shipment.new(remains, receiver, packet, nutrition,
		_on_shipment_owner_removed.bind(shipment_id), _on_packet_removed.bind(shipment_id))
	shipment.generation = generation
	shipment.reservation_id = reservation_id
	shipment.final_target = route.end_node
	shipment.transport_task_id = "remains:%d:%d" % [get_instance_id(), shipment_id]
	_bind_passage_tracking(shipment)
	# start_route 可以同步中断，所以完整记录和所有回调必须先于运输启动。
	_shipments[shipment_id] = shipment
	packet.arrived.connect(_on_packet_arrived)
	packet.interrupted.connect(_on_packet_interrupted)
	packet.tree_exiting.connect(shipment.packet_exit_callback)
	remains.tree_exiting.connect(shipment.owner_exit_callback)
	# 同一胃囊可以有多个在途包，退出监听按接收者登记一次，再统一取消其运输。
	if not _receiver_exit_callbacks.has(shipment.receiver_id):
		var callback: Callable = _on_receiver_removed.bind(shipment.receiver_id)
		_receiver_exit_callbacks[shipment.receiver_id] = callback
		receiver.tree_exiting.connect(callback)
	# 在 add_child 的通知前固定起点；其监听者可能同步取消本次运输。
	packet.position = destination_container.to_local(remains.global_position)
	destination_container.add_child(packet)
	_emit_recycling_changed()
	if _shipments.has(shipment_id):
		if _is_exiting or not _is_live_node(packet) or not packet.is_inside_tree() or (
			not _is_live_node(network) or not _is_live_node(destination_container)
		):
			_cancel_shipment(shipment_id)
		else:
			if _traffic_configuration_is_valid(network, dispatcher, require_traffic):
				shipment.started = true
				packet.start_route(route, network, dispatcher, shipment.transport_task_id)
			else:
				_cancel_shipment(shipment_id)


func _find_dispatch_choice(network: NetworkSystem, field: FungalField,
		generation: int) -> CollectionChoice:
	if not _is_live_node(remains_container):
		return null
	# 保留尸体 FIFO；同一尸体再按路线、交通排队及胃囊输入队列比较接收者。
	for child: Node in remains_container.get_children():
		if not _is_current_generation(generation):
			return null
		if not _is_live_node(child) or not child is EnemyRemains:
			continue
		var remains: EnemyRemains = child as EnemyRemains
		if not remains.is_available():
			continue
		var choice: CollectionChoice = _choose_receiver(remains.global_position, network, field, generation)
		if choice != null and _is_live_node(remains) and remains.is_available():
			choice.remains = remains
			return choice
	return null


func _find_carcass_choice(network: NetworkSystem, field: FungalField,
		generation: int) -> CollectionChoice:
	if not _is_live_node(remains_container):
		return null
	for child: Node in remains_container.get_children():
		if not _is_current_generation(generation):
			return null
		if not _is_live_node(child) or not child is LargeCarcass:
			continue
		var carcass: LargeCarcass = child as LargeCarcass
		if carcass.is_exhausted() or carcass.get_available_nutrition() <= 0:
			continue
		var choice: CollectionChoice = _choose_receiver(carcass.global_position, network, field, generation)
		if choice != null and _is_live_node(carcass):
			choice.carcass = carcass
			return choice
	return null


func _choose_receiver(position: Vector2, network: NetworkSystem, field: FungalField,
		generation: int) -> CollectionChoice:
	if not _is_live_node(network) or not _is_live_node(field):
		return null
	var best: CollectionChoice = null
	var candidates: Array[Node2D] = field.get_collecting_nodes(position)
	for raw_receiver: Variant in get_digestive_organs():
		if not _is_current_generation(generation):
			return null
		if not _receiver_is_available(raw_receiver):
			continue
		var receiver: DigestiveOrgan = raw_receiver as DigestiveOrgan
		var receiver_node: Node2D = receiver.get_parent() as Node2D
		for candidate: Node2D in candidates:
			if not _is_live_node(candidate) or not _is_live_node(network) or not _is_live_node(field):
				continue
			if not network.is_available_connected_to_core(candidate):
				continue
			if not _is_current_generation(generation) or not _receiver_is_available(receiver):
				break
			var route: NetworkRoute = network.find_available_route(candidate, receiver_node, RemainsPacket.CARGO_UNITS)
			if not _is_current_generation(generation) or not _receiver_is_available(receiver):
				break
			if not network.is_route_valid(route):
				continue
			if not _is_current_generation(generation) or not _receiver_is_available(receiver):
				break
			var score: float = _route_score(route, position) + _receiver_queue_seconds(receiver)
			if best == null or not _receiver_is_available(best.receiver) or score < best.score:
				best = CollectionChoice.new()
				best.receiver = receiver
				best.route = route
				best.score = score
				best.generation = generation
			# 一个接收者保留原有覆盖候选顺序，再在不同胃囊之间比较估计成本。
			break
	return best if _is_current_generation(generation) else null


func _route_score(route: NetworkRoute, position: Vector2) -> float:
	if route == null or not _is_live_node(route.start_node):
		return INF
	var score: float = position.distance_to(route.start_node.global_position) / TRANSPORT_SPEED
	for segment: NetworkRoute.Segment in route.segments:
		if not _is_live_node(segment.edge) or not _is_live_node(segment.start_node) \
				or not _is_live_node(segment.end_node):
			return INF
		score += segment.start_node.global_position.distance_to(segment.end_node.global_position) / TRANSPORT_SPEED
		if _is_live_node(traffic_system):
			score += traffic_system.estimate_wait_seconds(segment.edge, RemainsPacket.CARGO_UNITS, TRANSPORT_SPEED)
	return score


func _receiver_queue_seconds(receiver: DigestiveOrgan) -> float:
	var snapshot: Dictionary = receiver.get_digestion_snapshot()
	var duration: float = receiver.digest_timer.wait_time if is_instance_valid(receiver.digest_timer) else 1.0
	return float(receiver.get_queued_count() + receiver.incoming_remains) \
		* duration / float(maxi(1, int(snapshot["chamber_count"])))


func _is_registered_receiver(receiver: Variant) -> bool:
	return _is_live_node(receiver) and get_digestive_organs().has(receiver)


func _receiver_is_available(receiver: Variant) -> bool:
	return _is_registered_receiver(receiver) and receiver.is_inside_tree() \
		and _is_live_node(receiver.get_parent()) and receiver.can_reserve_remains()


func _is_current_generation(generation: int) -> bool:
	return generation == _generation and not _is_exiting and not _resetting and is_inside_tree()


func _new_input_reservation_id() -> String:
	var identity: String = "intake:%d:%d" % [get_instance_id(), _next_reservation_serial]
	_next_reservation_serial += 1
	return identity


func _discard_packet(packet: RemainsPacket) -> void:
	if is_instance_valid(packet):
		packet.free()


func _find_carcass_route(carcass: LargeCarcass, receiver_node: Node2D,
		network: NetworkSystem, field: FungalField) -> NetworkRoute:
	if not _is_live_node(carcass) or not _is_live_node(field):
		return null
	for candidate: Node2D in field.get_collecting_nodes(carcass.global_position):
		if not _is_live_node(network) or not _is_live_node(carcass) or (
			not _is_live_node(receiver_node) or not _is_live_node(field)
		):
			return null
		if not _is_live_node(candidate):
			continue
		if not network.is_available_connected_to_core(candidate):
			continue
		if not _is_live_node(network) or not _is_live_node(carcass) or (
			not _is_live_node(receiver_node) or not _is_live_node(field)
		):
			return null
		if not _is_live_node(candidate):
			continue
		var route: NetworkRoute = network.find_available_route(candidate, receiver_node, 2)
		if _is_live_node(carcass) and _route_is_current(route, carcass.global_position,
			receiver_node, network, field):
			return route
	return null


func _harvest_and_dispatch(choice: CollectionChoice, receiver: DigestiveOrgan,
		network: NetworkSystem, field: FungalField, destination_container: Node2D,
		transport_scene: PackedScene, dispatcher: Variant, require_traffic: bool) -> bool:
	if not _traffic_configuration_is_valid(network, dispatcher, require_traffic) \
			or not _is_live_node(remains_container) or not _is_live_node(choice.carcass):
		return false
	var collection_container: Node2D = remains_container
	var source_scene: PackedScene = batch_scene
	if source_scene == null or not source_scene.can_instantiate() or (
		transport_scene == null or not transport_scene.can_instantiate()
	):
		return false
	choice.reservation_id = _new_input_reservation_id()
	if not _harvest_gate_is_valid(choice, receiver, network, field,
		collection_container, destination_container) or not receiver.reserve_remains(choice.reservation_id):
		return false
	# 胃囊通知可能改变场域/路线、删除源，或让另一个系统先预留源营养。
	if not _traffic_configuration_is_valid(network, dispatcher, require_traffic) or not _harvest_gate_is_valid(choice, receiver, network, field,
		collection_container, destination_container):
		_discard_harvest_draft(null, null, choice.carcass, "", receiver, choice.reservation_id)
		return false
	var carcass: LargeCarcass = choice.carcass
	var source_id: String = carcass.get_resource_id()
	var request_id: String = "recycling:%d:%d" % [get_instance_id(), _next_harvest_serial]
	_next_harvest_serial += 1
	var nutrition: int = carcass.reserve_batch(request_id, 10)
	if nutrition <= 0 or nutrition > 10 or not _uncommitted_harvest_is_valid(choice,
		request_id, nutrition, receiver, network, field, collection_container, destination_container):
		_discard_harvest_draft(null, null, carcass, request_id, receiver, choice.reservation_id)
		return false
	var instance: Node = source_scene.instantiate()
	if not instance is EnemyRemains:
		_discard_harvest_draft(instance, null, carcass, request_id, receiver, choice.reservation_id)
		return false
	var batch: EnemyRemains = instance as EnemyRemains
	batch.nutrition_value = nutrition
	var batch_id: String = "%s:%s:%d" % [source_id, request_id, batch.get_instance_id()]
	batch.set_meta("carcass_batch_id", batch_id)
	batch.set_meta("carcass_source_id", source_id)
	batch.set_meta("carcass_request_id", request_id)
	if not batch.try_claim():
		_discard_harvest_draft(batch, null, carcass, request_id, receiver, choice.reservation_id)
		return false
	var transport_instance: Node = transport_scene.instantiate()
	if not transport_instance is RemainsPacket:
		_discard_harvest_draft(batch, transport_instance, carcass, request_id, receiver, choice.reservation_id)
		return false
	var packet: RemainsPacket = transport_instance as RemainsPacket
	if not _uncommitted_harvest_is_valid(choice, request_id, nutrition, receiver,
		network, field, collection_container, destination_container):
		_discard_harvest_draft(batch, packet, carcass, request_id, receiver, choice.reservation_id)
		return false
	batch.position = collection_container.to_local(carcass.global_position)
	# 暴露到共享容器之前已领取，重入查询不会把这个草稿当成可采集尸体。
	# child_entered_tree 的通知期间营养仍归预留的源所有，草稿不能提前重复持有。
	batch.nutrition_value = 0
	collection_container.add_child(batch)
	if not _uncommitted_harvest_is_valid(choice, request_id, nutrition, receiver,
		network, field, collection_container, destination_container) \
			or not _traffic_configuration_is_valid(network, dispatcher, require_traffic) or not _is_live_node(batch) or (
		batch.is_available() or batch.get_parent() != collection_container
	):
		_discard_harvest_draft(batch, packet, carcass, request_id, receiver, choice.reservation_id)
		return false
	# 赋值不发信号；紧接着 commit 的通知会看到已扣库存和拥有营养的独立批次。
	batch.nutrition_value = nutrition
	if not carcass.commit_batch(request_id, batch_id):
		_discard_harvest_draft(batch, packet, carcass, request_id, receiver, choice.reservation_id)
		return false
	# commit 的通知可以删除源；独立批次从这里开始是营养的唯一拥有者。
	if not _dispatch_dependencies_are_live(receiver, network, field, collection_container,
		destination_container) or not _is_live_node(batch) or batch.is_available() or (
		batch.get_parent() != collection_container or not receiver.owns_remains_reservation(choice.reservation_id)
	) or not _route_is_current(choice.route, batch.global_position,
		receiver.get_parent() as Node2D, network, field) or (
		not _dispatch_dependencies_are_live(receiver, network, field,
			collection_container, destination_container)
	) or not _is_live_node(batch) or batch.is_available() or (
		batch.get_parent() != collection_container or not receiver.owns_remains_reservation(choice.reservation_id)
	):
		_drop_committed_batch(batch, packet, receiver, choice.reservation_id)
		return false
	_start_shipment(batch, receiver, packet, nutrition, choice.route, network, destination_container, dispatcher, require_traffic, choice.generation, choice.reservation_id)
	return true


func _harvest_gate_is_valid(choice: CollectionChoice, receiver: DigestiveOrgan,
		network: NetworkSystem, field: FungalField, collection_container: Node2D,
		destination_container: Node2D) -> bool:
	if not _is_current_generation(choice.generation) or not _is_registered_receiver(receiver) \
			or not _dispatch_dependencies_are_live(receiver, network, field, collection_container,
		destination_container) or not _is_live_node(choice.carcass):
		return false
	if choice.carcass.get_parent() != collection_container:
		return false
	var valid_route: bool = _route_is_current(choice.route, choice.carcass.global_position,
		receiver.get_parent() as Node2D, network, field)
	return valid_route and _is_live_node(choice.carcass) and (
		choice.carcass.get_parent() == collection_container
	) and _dispatch_dependencies_are_live(receiver, network, field,
		collection_container, destination_container)


func _uncommitted_harvest_is_valid(choice: CollectionChoice, request_id: String,
		nutrition: int, receiver: DigestiveOrgan, network: NetworkSystem, field: FungalField,
		collection_container: Node2D, destination_container: Node2D) -> bool:
	return _harvest_gate_is_valid(choice, receiver, network, field,
		collection_container, destination_container) and receiver.owns_remains_reservation(choice.reservation_id) and (
		choice.carcass.get_reservation_nutrition(request_id) == nutrition
	)


func _dispatch_dependencies_are_live(receiver: Variant, network: Variant, field: Variant,
		collection_container: Variant, destination_container: Variant) -> bool:
	return not _is_exiting and is_inside_tree() and _is_live_node(receiver) and (
		receiver.is_inside_tree() and receiver.is_functional() and _is_registered_receiver(receiver)
		and _is_live_node(receiver.get_parent())
	) and _is_live_node(network) and network.is_inside_tree() and (
		_is_live_node(field) and field.is_inside_tree()
	) and _is_live_node(collection_container) and collection_container.is_inside_tree() and (
		_is_live_node(destination_container) and destination_container.is_inside_tree()
	)


func _route_is_current(route: NetworkRoute, position: Vector2, receiver_node: Node2D,
		network: NetworkSystem, field: FungalField) -> bool:
	if route == null or not _is_live_node(network) or not _is_live_node(field) or (
		not _is_live_node(receiver_node) or not _is_live_node(route.start_node)
	) or route.end_node != receiver_node:
		return false
	if not field.get_collecting_nodes(position).has(route.start_node) or (
		not network.is_available_connected_to_core(route.start_node)
	):
		return false
	if not _is_live_node(network) or not _is_live_node(field) or not _is_live_node(receiver_node):
		return false
	var route_valid: bool = network.is_route_valid(route) \
		and network.find_available_route(route.start_node, receiver_node, 2).found
	return route_valid and _is_live_node(network) and _is_live_node(field) and (
		_is_live_node(receiver_node) and field.get_collecting_nodes(position).has(route.start_node)
	)


func _discard_harvest_draft(batch: Variant, packet: Variant, carcass: Variant,
		request_id: String, receiver: Variant, reservation_id: String) -> void:
	if is_instance_valid(batch):
		if batch is EnemyRemains:
			batch.nutrition_value = 0
		batch.free()
	if is_instance_valid(packet):
		packet.free()
	if is_instance_valid(carcass) and not request_id.is_empty():
		carcass.release_batch(request_id)
	if is_instance_valid(receiver):
		receiver.cancel_reservation(reservation_id)


func _drop_committed_batch(batch: Variant, packet: Variant, receiver: Variant, reservation_id: String) -> void:
	if is_instance_valid(packet):
		packet.free()
	# 释放胃囊的通知发生时，批次仍被领取；随后才能再次进入地面采集队列。
	if is_instance_valid(receiver):
		receiver.cancel_reservation(reservation_id)
	if _is_live_node(batch):
		batch.release_claim(batch.global_position)
	interrupted_count += 1
	_emit_recycling_changed()


func _refresh_carcass_statuses() -> void:
	if _is_exiting or not _is_live_node(remains_container):
		return
	for child: Node in remains_container.get_children():
		if not _is_live_node(child) or not child is LargeCarcass:
			continue
		var carcass: LargeCarcass = child as LargeCarcass
		var status: StringName = _get_carcass_wait_status(carcass)
		if _is_live_node(carcass):
			carcass.set_harvest_status(status)


func _get_carcass_wait_status(carcass: LargeCarcass) -> StringName:
	if carcass.is_exhausted():
		return &"exhausted"
	if not _is_live_node(fungal_field) or (
		fungal_field.get_collecting_nodes(carcass.global_position).is_empty()
	):
		return &"out_of_field"
	if not _is_live_node(network_system) or not _is_live_node(packet_container) \
			or not packet_container.is_inside_tree() or packet_scene == null:
		return &"no_route"
	var has_route: bool = false
	var has_capacity: bool = false
	for receiver: DigestiveOrgan in get_digestive_organs():
		if not _is_live_node(receiver) or not receiver.is_inside_tree() or not receiver.is_functional():
			continue
		var receiver_node: Node2D = receiver.get_parent() as Node2D
		if not _is_live_node(receiver_node) or _find_carcass_route(carcass, receiver_node,
			network_system, fungal_field) == null:
			continue
		if not _is_live_node(carcass):
			return &"no_route"
		has_route = true
		if _receiver_is_available(receiver):
			has_capacity = true
	if not has_route:
		return &"no_route"
	if not has_capacity:
		return &"capacity_full"
	if carcass.get_reserved_nutrition() > 0:
		return &"harvesting"
	var source_id: String = carcass.get_resource_id()
	for shipment: Shipment in _shipments.values():
		if _is_live_node(shipment.remains) and (
			String(shipment.remains.get_meta("carcass_source_id", "")) == source_id
		):
			return &"harvesting"
	return &"ready"


func _cancel_shipment(shipment_id: int) -> void:
	var shipment: Shipment = _shipments.get(shipment_id) as Shipment
	if shipment == null:
		return
	if is_instance_valid(shipment.packet):
		shipment.packet.cancel_transport()
	# 未启动或已结束的 packet 可能不再发出信号；兜底仍只结算一次。
	_settle_shipment(shipment_id, false)


func _settle_shipment(shipment_id: int, was_delivered: bool) -> void:
	var shipment: Shipment = _shipments.get(shipment_id) as Shipment
	if shipment == null:
		return
	# 未提交抵达的信号只是一条通知，不释放胃囊预留或原尸体领取权。
	if was_delivered and not _has_arrived(shipment):
		return
	# 先删除记录并解绑，后续库存信号、取消和 tree_exiting 无法重复结算。
	_shipments.erase(shipment_id)
	var drop_position: Vector2 = Vector2.ZERO
	if is_instance_valid(shipment.remains):
		drop_position = shipment.remains.global_position
	if is_instance_valid(shipment.packet):
		drop_position = shipment.packet.global_position
	_disconnect_shipment(shipment)
	var accepted: bool = false
	var handed_off_nutrition: int = 0
	if was_delivered and shipment.generation == _generation and _is_registered_receiver(shipment.receiver) and (
		shipment.receiver.is_inside_tree() and shipment.receiver.get_parent() == shipment.final_target
		and _is_live_node(shipment.remains)
	):
		# 新矿批次的库存交接先移走原节点的营养，再让胃囊同步通知排队库存。
		# 交付值已固定在 Shipment 内；拒收不发库存通知，可以原样恢复同一批次。
		handed_off_nutrition = shipment.remains.nutrition_value
		shipment.remains.nutrition_value = 0
		accepted = shipment.receiver.complete_delivery(shipment.nutrition, shipment.reservation_id)
		if not accepted and is_instance_valid(shipment.remains) and handed_off_nutrition > 0:
			shipment.remains.nutrition_value = handed_off_nutrition
	if accepted:
		if is_instance_valid(shipment.remains):
			shipment.remains.queue_free()
		delivered_count += 1
	else:
		if is_instance_valid(shipment.receiver):
			shipment.receiver.cancel_reservation(shipment.reservation_id)
		if _is_live_node(shipment.remains):
			shipment.remains.release_claim(drop_position)
		interrupted_count += 1
	if is_instance_valid(shipment.packet):
		if not accepted:
			shipment.packet.cancel_transport()
		if is_instance_valid(shipment.packet) and not shipment.packet.is_queued_for_deletion():
			shipment.packet.queue_free()
	_emit_recycling_changed()
	if accepted:
		_confirm_passage_tracking(shipment)


func _has_arrived(shipment: Shipment) -> bool:
	return shipment.started and _is_live_node(shipment.final_target) and is_instance_valid(shipment.packet) \
		and shipment.packet.has_arrived_at(shipment.final_target, shipment.transport_task_id)


func _disconnect_shipment(shipment: Shipment) -> void:
	if is_instance_valid(shipment.packet):
		if shipment.packet.arrived.is_connected(_on_packet_arrived):
			shipment.packet.arrived.disconnect(_on_packet_arrived)
		if shipment.packet.interrupted.is_connected(_on_packet_interrupted):
			shipment.packet.interrupted.disconnect(_on_packet_interrupted)
		if shipment.packet.tree_exiting.is_connected(shipment.packet_exit_callback):
			shipment.packet.tree_exiting.disconnect(shipment.packet_exit_callback)
	if is_instance_valid(shipment.remains) and (
		shipment.remains.tree_exiting.is_connected(shipment.owner_exit_callback)
	):
		shipment.remains.tree_exiting.disconnect(shipment.owner_exit_callback)
	_release_receiver_listener(shipment)


func _release_receiver_listener(settled: Shipment) -> void:
	for pending: Shipment in _shipments.values():
		if pending.receiver_id == settled.receiver_id:
			return
	if not _receiver_exit_callbacks.has(settled.receiver_id):
		return
	var callback: Callable = _receiver_exit_callbacks[settled.receiver_id]
	_receiver_exit_callbacks.erase(settled.receiver_id)
	if is_instance_valid(settled.receiver) and settled.receiver.tree_exiting.is_connected(callback):
		settled.receiver.tree_exiting.disconnect(callback)


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _emit_recycling_changed() -> void:
	recycling_changed.emit(get_in_transit_count(), delivered_count, interrupted_count)


## 显式交通配置失效不能退回旧的无容量运输；这里只校验配置，不预留通行。
func _traffic_configuration_is_valid(network: Variant, dispatcher: Variant, required: bool) -> bool:
	if dispatcher == null:
		return not required
	return is_instance_valid(dispatcher) and dispatcher is NetworkTrafficSystem \
		and not dispatcher.is_queued_for_deletion() and is_instance_valid(network) \
		and not network.is_queued_for_deletion() and dispatcher.network_system == network


func reset(stop_dispatch: bool = false) -> void:
	if _resetting:
		return
	_resetting = true
	_generation += 1
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
	shipment.cargo_id = "remains:" + String(shipment.remains.get_meta("carcass_batch_id")) if shipment.remains.has_meta("carcass_batch_id") else "remains:instance:%d" % shipment.remains.get_instance_id()
	shipment.cargo_generation = cargo_passage_tracker.register_cargo(shipment.cargo_id, &"remains")
	if shipment.cargo_generation >= 0:
		shipment.cargo_tracker_ref = weakref(cargo_passage_tracker)
		shipment.packet.bind_cargo(cargo_passage_tracker, shipment.cargo_id, shipment.cargo_generation)


func _confirm_passage_tracking(shipment: Shipment) -> void:
	if shipment.cargo_tracker_ref == null:
		return
	var tracker: CargoPassageTracker = shipment.cargo_tracker_ref.get_ref() as CargoPassageTracker
	if is_instance_valid(tracker):
		tracker.confirm_cargo(shipment.cargo_id, shipment.cargo_generation)


## 已领取但未送达的尸体仍由原对象持有，按既有中断规则落地。
func cancel_receiver(receiver: DigestiveOrgan) -> void:
	if is_instance_valid(receiver):
		_on_receiver_removed(receiver.get_instance_id())
