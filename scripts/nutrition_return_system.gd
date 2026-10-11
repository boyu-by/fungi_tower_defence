class_name NutritionReturnSystem
extends Node
## 运输尝试只引用胃囊中的产物；母核独占真实到达后的入账权。

signal return_changed(snapshot: Dictionary)
signal notice(message: String)

class Shipment:
	extends RefCounted

	var cargo_id: String = ""
	var cargo_generation: int = -1
	var cargo_tracker_ref: WeakRef

	var attempt_id: String
	var product_id: String
	var nutrition: int
	var source_id: int
	var core_id: int
	var source: DigestiveOrgan
	var source_node: Node2D
	var core: MotherCore
	var network: NetworkSystem
	var packet: NutrientPacket
	var route: NetworkRoute
	var final_target: Node2D
	var transport_task_id: String
	var generation: int
	var status: StringName = &"reserved"
	var started: bool = false
	var arrived_callback: Callable
	var interrupted_callback: Callable
	var packet_exit_callback: Callable
	var source_exit_callback: Callable
	var core_exit_callback: Callable
	var core_depleted_callback: Callable

const BODY_GREEN: Color = Color(0.30, 0.94, 0.48, 1.0)
const GLOW_GREEN: Color = Color(0.30, 0.94, 0.48, 0.20)
const TRAIL_GREEN: Color = Color(0.30, 0.94, 0.48, 0.38)

@export var digestive_organ: DigestiveOrgan
@export var mother_core: MotherCore
@export var cargo_passage_tracker: CargoPassageTracker
@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var traffic_required: bool = false
@export var packet_container: Node2D
@export var packet_scene: PackedScene = preload("res://scenes/colony/nutrient_packet.tscn")
@export var dispatch_interval: float = 0.35
@export var packet_speed: float = 80.0
@export var auto_return: bool = true

var delivered_count: int = 0
var delivered_nutrition: int = 0
var interrupted_count: int = 0

var _shipments: Dictionary[String, Shipment] = {}
var _attempt_records: Array[Shipment] = []
var _delivered_product_ids: Dictionary[String, bool] = {}
var _next_attempt_serial: int = 1
var _generation: int = 0
var _is_dispatching: bool = false
var _is_pruning: bool = false
var _is_resetting: bool = false
var _is_exiting: bool = false
var _wait_reason: StringName = &"empty"
var _dispatch_timer: Timer
var _observed_source: DigestiveOrgan
var _observed_network: NetworkSystem


func _enter_tree() -> void:
	_is_exiting = false


func _ready() -> void:
	_dispatch_timer = get_node_or_null("DispatchTimer") as Timer
	if _dispatch_timer == null:
		_dispatch_timer = Timer.new()
		_dispatch_timer.name = "DispatchTimer"
		add_child(_dispatch_timer)
	_dispatch_timer.one_shot = false
	_dispatch_timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	_dispatch_timer.wait_time = maxf(dispatch_interval, 0.01)
	if not _dispatch_timer.timeout.is_connected(_on_dispatch_timer_timeout):
		_dispatch_timer.timeout.connect(_on_dispatch_timer_timeout)
	_sync_dependency_listeners()
	# 保持计时器运行，auto_return 在运行时开关也能立即生效。
	_dispatch_timer.start()
	_emit_return_changed()


func _exit_tree() -> void:
	_is_exiting = true
	reset()
	_disconnect_dependency_listeners()


func _on_dispatch_timer_timeout() -> void:
	if _is_resetting or _is_exiting:
		return
	_dispatch_timer.wait_time = maxf(dispatch_interval, 0.01)
	_sync_dependency_listeners()
	_prune_shipments()
	if is_instance_valid(self) and auto_return:
		try_dispatch()


func _on_source_output_changed(_snapshot: Dictionary) -> void:
	if _is_resetting or _is_exiting:
		return
	_prune_shipments()
	if is_instance_valid(self) and not _is_resetting:
		_emit_return_changed()


func _on_network_changed() -> void:
	if _is_resetting or _is_exiting:
		return
	_prune_shipments()
	if is_instance_valid(self) and not _is_resetting:
		_emit_return_changed()


func _on_packet_arrived(packet: NutrientPacket, attempt_id: String) -> void:
	var shipment: Shipment = _shipments.get(attempt_id) as Shipment
	if shipment != null and shipment.packet == packet:
		_settle_attempt(attempt_id, true)


func _on_packet_interrupted(packet: NutrientPacket, attempt_id: String) -> void:
	var shipment: Shipment = _shipments.get(attempt_id) as Shipment
	if shipment != null and shipment.packet == packet:
		_settle_attempt(attempt_id, false)


func _on_attempt_removed(attempt_id: String) -> void:
	_settle_attempt(attempt_id, false)


func _on_owner_removed(owner_id: int) -> void:
	# 同一胃囊和母核可有两份回流；每个所有者只连接一次，再结算其全部运输。
	for shipment: Shipment in _shipments.values():
		if shipment.source_id == owner_id or shipment.core_id == owner_id:
			_settle_attempt(shipment.attempt_id, false)


func try_dispatch() -> bool:
	if _is_dispatching or _is_resetting or _is_exiting or not is_inside_tree():
		return false

	_is_dispatching = true
	var generation: int = _generation
	_sync_dependency_listeners()
	_prune_shipments()
	var dispatched: bool = false
	if _is_current_generation(generation):
		dispatched = _dispatch_one(generation)
	if is_instance_valid(self):
		_is_dispatching = false
	return dispatched


func get_in_transit_count() -> int:
	return _shipments.size()


func get_in_transit_nutrition() -> int:
	var nutrition: int = 0
	for shipment: Shipment in _shipments.values():
		nutrition += shipment.nutrition
	return nutrition


func get_shipment_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for shipment: Shipment in _attempt_records:
		records.append({
			"attempt_id": shipment.attempt_id, "product_id": shipment.product_id,
			"cargo_id": shipment.cargo_id, "cargo_generation": shipment.cargo_generation,
			"nutrition": shipment.nutrition, "status": shipment.status,
			"packet": shipment.packet if is_instance_valid(shipment.packet) else null,
			"route": shipment.route, "final_target": shipment.final_target,
			"transport_task_id": shipment.transport_task_id, "started": shipment.started
		})
	return records


func get_return_snapshot() -> Dictionary:
	var queued_count: int = 0
	var queued_nutrition: int = 0
	if is_instance_valid(digestive_organ):
		for product: Dictionary in digestive_organ.get_output_products():
			if product["status"] == &"queued":
				queued_count += 1
				queued_nutrition += int(product["nutrition"])
	var reason: StringName = _wait_reason
	if queued_count == 0:
		reason = &"in_transit" if get_in_transit_count() > 0 else &"empty"
	elif not _is_live_node(digestive_organ) or not digestive_organ.is_inside_tree():
		reason = &"source_unavailable"
	elif not _is_alive_core(mother_core) or not mother_core.is_inside_tree():
		reason = &"core_unavailable"
	elif not _is_live_node(network_system):
		reason = &"network_unavailable"
	elif reason == &"empty" or reason == &"in_transit":
		reason = &"ready"
	return {
		"in_transit_count": get_in_transit_count(),
		"in_transit_nutrition": get_in_transit_nutrition(),
		"queued_count": queued_count, "queued_nutrition": queued_nutrition,
		"delivered_count": delivered_count, "delivered_nutrition": delivered_nutrition,
		"interrupted_count": interrupted_count, "wait_reason": reason
	}


## 清空运输账本前使所有旧回调失效，未收件的产物仍归原胃囊所有。
func reset() -> void:
	if _is_resetting:
		return

	_is_resetting = true
	_generation += 1
	var records: Array[Shipment] = _attempt_records.duplicate()
	_shipments.clear()
	_attempt_records.clear()
	_delivered_product_ids.clear()
	delivered_count = 0
	delivered_nutrition = 0
	interrupted_count = 0
	_wait_reason = &"empty"
	for shipment: Shipment in records:
		if shipment.status != &"reserved" and shipment.status != &"in_transit" \
				and shipment.status != &"settling":
			continue
		shipment.status = &"interrupted"
		_disconnect_shipment(shipment)
		_stop_packet(shipment.packet)
		_release_product(shipment, _was_received(shipment))
	if is_instance_valid(self):
		_is_resetting = false
		if not _is_exiting:
			_emit_return_changed()


func _dispatch_one(generation: int) -> bool:
	if not _is_live_node(digestive_organ) or not digestive_organ.is_inside_tree():
		return _reject(&"source_unavailable", "胃囊已退出，无法回流营养")
	if not _is_alive_core(mother_core) or not mother_core.is_inside_tree():
		return _reject(&"core_unavailable", "母核无法接收回流营养")
	if not _is_live_node(network_system):
		return _reject(&"network_unavailable", "回流网络不可用")
	if not _is_live_node(packet_container) or not packet_container.is_inside_tree() or packet_scene == null:
		return _reject(&"packet_unavailable", "回流系统缺少营养包配置")

	if not _traffic_configuration_is_valid(network_system, traffic_system, traffic_required):
		return _reject(&"traffic_unavailable", "回流缺少有效的共享交通调度器")

	# 固定本次运输依赖；导出引用修改只能影响之后的派遣。
	var source: DigestiveOrgan = digestive_organ
	var core: MotherCore = mother_core
	var network: NetworkSystem = network_system
	var dispatcher: Variant = traffic_system
	var require_traffic: bool = traffic_required or dispatcher != null
	var container: Node2D = packet_container
	var scene: PackedScene = packet_scene
	var source_node: Node2D = source.get_parent() as Node2D
	if not _is_live_node(source_node):
		return _reject(&"source_unavailable", "胃囊所在菌结已退出")
	var product: Dictionary = _choose_product(source, core, generation)
	if not _is_current_generation(generation) or not _is_live_node(source) or (
		not _is_alive_core(core) or not _is_live_node(network) or not _is_live_node(container)
	):
		return false
	if product.is_empty():
		return _reject(&"empty", "")
	var route: NetworkRoute = network.find_route(source_node, core)
	if not _is_current_generation(generation) or not _is_live_node(source) or (
		not _is_alive_core(core) or not _is_live_node(network) or not _is_live_node(container)
	):
		return false
	var valid_route: bool = route.found and network.is_route_valid(route)
	if not _is_current_generation(generation) or not _is_live_node(source) or (
		not _is_live_node(source_node) or not _is_alive_core(core)
		or not _is_live_node(network) or not _is_live_node(container)
	):
		return false
	if not valid_route:
		return _reject(&"disconnected", "胃囊到母核的回流线路已断开")
	var instance: Node = scene.instantiate()
	if not instance is NutrientPacket:
		instance.free()
		return _reject(&"packet_unavailable", "回流营养包场景类型不正确")
	var packet: NutrientPacket = instance as NutrientPacket
	packet.traffic_required = require_traffic
	if not _traffic_configuration_is_valid(network, dispatcher, require_traffic):
		packet.free()
		return false
	var shipment: Shipment = _make_shipment(source, source_node, core, network, packet, route, product)
	# 领取产物也会发出信号，所以完整尝试账本和回调先于领取提交。
	_shipments[shipment.attempt_id] = shipment
	_attempt_records.append(shipment)
	_connect_shipment(shipment)
	var claimed: bool = source.claim_output_product(shipment.product_id, shipment.attempt_id)
	if not claimed or not _attempt_is_active(shipment) or not _is_live_node(container):
		_settle_attempt(shipment.attempt_id, false)
		return false
	packet.speed = maxf(packet_speed, 0.0)
	packet.name = "NutritionReturn_%d_%d" % [get_instance_id(), _next_attempt_serial - 1]
	packet.set_meta("return_product_id", shipment.product_id)
	packet.set_meta("return_attempt_id", shipment.attempt_id)
	_style_packet(packet)
	container.add_child(packet)
	if not _attempt_is_active(shipment):
		return false
	_wait_reason = &"ready"
	_emit_return_changed()
	# start_route 可同步到达或中断；上面的账本已能处理这两种情况。
	if _attempt_is_active(shipment) and _is_live_node(packet):
		if _traffic_configuration_is_valid(network, dispatcher, require_traffic):
			shipment.status = &"in_transit"
			shipment.started = true
			packet.start_route(route, network, dispatcher, shipment.transport_task_id, &"return")
		else:
			_settle_attempt(shipment.attempt_id, false)
	return shipment.status == &"in_transit" or shipment.status == &"delivered"


func _choose_product(source: DigestiveOrgan, core: MotherCore, generation: int) -> Dictionary:
	for product: Dictionary in source.get_output_products():
		if product["status"] != &"queued":
			continue
		var product_id: String = String(product["product_id"])
		if core.has_received_product(product_id):
			_record_delivery(product_id, int(product["nutrition"]))
			source.settle_output_product(product_id)
			if not _is_current_generation(generation) or not _is_live_node(source) or not _is_alive_core(core):
				return {}
		else:
			return product
	return {}


func _make_shipment(source: DigestiveOrgan, source_node: Node2D, core: MotherCore,
		network: NetworkSystem, packet: NutrientPacket, route: NetworkRoute,
		product: Dictionary) -> Shipment:
	var shipment: Shipment = Shipment.new()
	shipment.attempt_id = "%d:%d" % [get_instance_id(), _next_attempt_serial]
	_next_attempt_serial += 1
	shipment.transport_task_id = shipment.attempt_id
	shipment.product_id = String(product["product_id"])
	shipment.nutrition = int(product["nutrition"])
	shipment.source_id = source.get_instance_id()
	shipment.core_id = core.get_instance_id()
	shipment.source = source
	shipment.source_node = source_node
	shipment.core = core
	shipment.final_target = core
	shipment.network = network
	shipment.packet = packet
	shipment.route = route
	shipment.generation = _generation
	_bind_passage_tracking(shipment)
	shipment.arrived_callback = _on_packet_arrived.bind(shipment.attempt_id)
	shipment.interrupted_callback = _on_packet_interrupted.bind(shipment.attempt_id)
	shipment.packet_exit_callback = _on_attempt_removed.bind(shipment.attempt_id)
	shipment.source_exit_callback = _on_owner_removed.bind(shipment.source_id)
	shipment.core_exit_callback = _on_owner_removed.bind(shipment.core_id)
	shipment.core_depleted_callback = _on_owner_removed.bind(shipment.core_id)
	return shipment


func _settle_attempt(attempt_id: String, arrived: bool) -> void:
	var shipment: Shipment = _shipments.get(attempt_id) as Shipment
	if shipment == null or shipment.generation != _generation:
		return
	# 早到信号不能入账，也不能归还正在运输的产物领取权。
	if arrived and not _has_arrived(shipment):
		return

	# 先从在途账本摘除并解绑；入账信号可以重复到达、取消运输或重置系统。
	_shipments.erase(attempt_id)
	shipment.status = &"settling"
	_disconnect_shipment(shipment)
	var generation: int = _generation
	var received: bool = _was_received(shipment)
	if not received and arrived and _can_receive(shipment):
		received = shipment.core.accept_digestion_product(shipment.product_id, shipment.nutrition)
	# reset 可能在母核的入账信号中完成，不能重建旧统计或旧记录。
	if not _is_current_generation(generation):
		return
	shipment.status = &"delivered" if received else &"interrupted"
	if received:
		_record_delivery(shipment.product_id, shipment.nutrition)
	else:
		interrupted_count += 1
	_stop_packet(shipment.packet)
	_release_product(shipment, received)
	if _is_current_generation(generation):
		_wait_reason = &"ready" if not received else &"empty"
		_emit_return_changed()
		if _is_current_generation(generation):
			notice.emit("营养已回流母核" if received else "回流中断，产物保留在胃囊")


func _release_product(shipment: Shipment, received: bool) -> void:
	if is_instance_valid(shipment.source):
		if received:
			var settled: bool = shipment.source.settle_output_product(shipment.product_id, shipment.attempt_id)
			# 入账回调可能已归还领取权；已收件的排队产物也可安全清理。
			if not settled and is_instance_valid(shipment.source):
				shipment.source.settle_output_product(shipment.product_id)
		else:
			shipment.source.return_output_product(shipment.product_id, shipment.attempt_id)
	# 包括入账通知内 reset 的结算路径；跟踪代际由原运输捕获，不能带到新局。
	if received:
		_confirm_passage_tracking(shipment)


func _record_delivery(product_id: String, nutrition: int) -> void:
	if _delivered_product_ids.has(product_id):
		return
	_delivered_product_ids[product_id] = true
	delivered_count += 1
	delivered_nutrition += nutrition


func _can_receive(shipment: Shipment) -> bool:
	return _is_live_node(shipment.source) and shipment.source.is_inside_tree() and (
		_is_live_node(shipment.source_node) and shipment.source_node.is_inside_tree()
		and shipment.source.get_parent() == shipment.source_node
	) and _is_alive_core(shipment.core) and shipment.core.is_inside_tree() and (
		shipment.source.owns_output_claim(shipment.product_id, shipment.attempt_id)
	)


func _was_received(shipment: Shipment) -> bool:
	return is_instance_valid(shipment.core) and shipment.core.has_received_product(shipment.product_id)


func _prune_shipments() -> void:
	if _is_pruning or _is_resetting or _is_exiting:
		return

	_is_pruning = true
	for attempt_id: String in _shipments.keys():
		var shipment: Shipment = _shipments.get(attempt_id) as Shipment
		if shipment == null:
			continue
		var valid: bool = _can_receive(shipment) and _is_live_node(shipment.network)
		if valid and shipment.started:
			valid = _is_live_node(shipment.final_target) and _is_live_node(shipment.packet) \
				and shipment.packet.is_inside_tree() \
				and shipment.packet.is_transport_valid(shipment.final_target, shipment.transport_task_id)
		elif valid:
			# claim / add_child / 通知回调尚未启动包时，保留原来的入场路线校验。
			valid = shipment.network.is_route_valid(shipment.route)
		if not valid or _was_received(shipment):
			_settle_attempt(attempt_id, false)
	if is_instance_valid(self):
		_is_pruning = false


func _has_arrived(shipment: Shipment) -> bool:
	return shipment.started and _is_live_node(shipment.final_target) and is_instance_valid(shipment.packet) \
		and shipment.packet.has_arrived_at(shipment.final_target, shipment.transport_task_id)


func _attempt_is_active(shipment: Shipment) -> bool:
	return _is_current_generation(shipment.generation) and _shipments.get(shipment.attempt_id) == shipment


func _connect_shipment(shipment: Shipment) -> void:
	shipment.packet.arrived.connect(shipment.arrived_callback)
	shipment.packet.interrupted.connect(shipment.interrupted_callback)
	shipment.packet.tree_exiting.connect(shipment.packet_exit_callback)
	if not shipment.source.tree_exiting.is_connected(shipment.source_exit_callback):
		shipment.source.tree_exiting.connect(shipment.source_exit_callback)
	if not shipment.core.tree_exiting.is_connected(shipment.core_exit_callback):
		shipment.core.tree_exiting.connect(shipment.core_exit_callback)
	if not shipment.core.depleted.is_connected(shipment.core_depleted_callback):
		shipment.core.depleted.connect(shipment.core_depleted_callback)


func _disconnect_shipment(shipment: Shipment) -> void:
	if is_instance_valid(shipment.packet):
		_disconnect_signal(shipment.packet.arrived, shipment.arrived_callback)
		_disconnect_signal(shipment.packet.interrupted, shipment.interrupted_callback)
		_disconnect_signal(shipment.packet.tree_exiting, shipment.packet_exit_callback)
	if is_instance_valid(shipment.source) and not _owner_has_shipments(shipment.source_id):
		_disconnect_signal(shipment.source.tree_exiting, shipment.source_exit_callback)
	if is_instance_valid(shipment.core) and not _owner_has_shipments(shipment.core_id):
		_disconnect_signal(shipment.core.tree_exiting, shipment.core_exit_callback)
		_disconnect_signal(shipment.core.depleted, shipment.core_depleted_callback)


func _owner_has_shipments(owner_id: int) -> bool:
	for pending: Shipment in _shipments.values():
		if pending.source_id == owner_id or pending.core_id == owner_id:
			return true
	return false


func _disconnect_signal(event: Signal, callback: Callable) -> void:
	if event.is_connected(callback):
		event.disconnect(callback)


func _stop_packet(packet: Variant) -> void:
	if not is_instance_valid(packet):
		return
	packet.cancel_transport()
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		if packet.is_inside_tree():
			packet.queue_free()
		else:
			packet.free()


func _style_packet(packet: NutrientPacket) -> void:
	var body: Polygon2D = packet.get_node_or_null("Body") as Polygon2D
	var glow: Polygon2D = packet.get_node_or_null("Glow") as Polygon2D
	var trail: Line2D = packet.get_node_or_null("Trail") as Line2D
	if body != null:
		body.color = BODY_GREEN
	if glow != null:
		glow.color = GLOW_GREEN
	if trail != null:
		trail.default_color = TRAIL_GREEN


func _sync_dependency_listeners() -> void:
	if _observed_source != digestive_organ:
		if is_instance_valid(_observed_source):
			_disconnect_signal(_observed_source.output_changed, _on_source_output_changed)
		_observed_source = null
		if _is_live_node(digestive_organ):
			_observed_source = digestive_organ
			_observed_source.output_changed.connect(_on_source_output_changed)
	if _observed_network != network_system:
		if is_instance_valid(_observed_network):
			_disconnect_signal(_observed_network.network_changed, _on_network_changed)
		_observed_network = null
		if _is_live_node(network_system):
			_observed_network = network_system
			_observed_network.network_changed.connect(_on_network_changed)


func _disconnect_dependency_listeners() -> void:
	if is_instance_valid(_observed_source):
		_disconnect_signal(_observed_source.output_changed, _on_source_output_changed)
	if is_instance_valid(_observed_network):
		_disconnect_signal(_observed_network.network_changed, _on_network_changed)
	_observed_source = null
	_observed_network = null


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _is_alive_core(core: Variant) -> bool:
	return _is_live_node(core) and core is MotherCore and core.health > 0


func _is_current_generation(generation: int) -> bool:
	return is_instance_valid(self) and _generation == generation and not _is_resetting and not _is_exiting


func _reject(reason: StringName, message: String) -> bool:
	var changed: bool = _wait_reason != reason
	_wait_reason = reason
	_emit_return_changed()
	if changed and not message.is_empty() and is_instance_valid(self):
		notice.emit(message)
	return false


func _emit_return_changed() -> void:
	return_changed.emit(get_return_snapshot())


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
	shipment.cargo_id = "return:" + shipment.product_id
	shipment.cargo_generation = cargo_passage_tracker.register_cargo(shipment.cargo_id, &"return")
	if shipment.cargo_generation >= 0:
		shipment.cargo_tracker_ref = weakref(cargo_passage_tracker)
		shipment.packet.bind_cargo(cargo_passage_tracker, shipment.cargo_id, shipment.cargo_generation)


func _confirm_passage_tracking(shipment: Shipment) -> void:
	if shipment.cargo_tracker_ref == null:
		return
	var tracker: CargoPassageTracker = shipment.cargo_tracker_ref.get_ref() as CargoPassageTracker
	if is_instance_valid(tracker):
		tracker.confirm_cargo(shipment.cargo_id, shipment.cargo_generation)
