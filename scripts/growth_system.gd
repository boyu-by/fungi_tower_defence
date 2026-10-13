class_name GrowthSystem
extends Node
## 沿统一计划推进主枝与有限侧枝；仅消耗已抵达尖端的营养，不读写母核余额。

signal task_changed(snapshot: Dictionary)
signal task_completed(task_id: int)
signal task_cancelled(task_id: int)
signal junction_formed(node: HyphaNode)

const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const TIP_SCENE: PackedScene = preload("res://scenes/colony/growth_tip.tscn")
const MAX_TASK_ID: int = 9223372036854775807
const SUPPLY_WAIT_REASONS: Array[StringName] = [
	&"", &"nutrition", &"in_transit", &"core_empty", &"combat_reserve", &"repair_budget",
	&"disconnected", &"invalid_configuration", &"core_unavailable", &"paused",
]

@export var planner: GrowthPlanner = GrowthPlanner.new()
@export var network_system: NetworkSystem
@export var traffic_system: NetworkTrafficSystem
@export var node_container: Node2D
@export var edge_container: Node2D
@export var tip_container: Node2D
@export var growth_speed: float = 30.0

## 关卡注入另一建设系统的占用查询；独立生长夹具可不绑定。
var construction_blocker: Callable = Callable()

var _last_task_id: int = 0
var _task_id: int = 0
var _state: StringName = &"idle"
var _wait_reason: StringName = &""
var _supply_wait_reason: StringName = &""
var _task_kind: StringName = &"growth"
var _start_node: Node2D = null
var _target_node: HyphaNode = null
var _connection_core: MotherCore = null
var _connection_network: NetworkSystem = null
var _connection_edges: Array[HyphaEdge] = []
var _target_position: Vector2 = Vector2.ZERO
var _resolved_target_position: Vector2 = Vector2.ZERO
var _plan_version: int = 0
var _plan: Dictionary = {}
var _pending_retarget: Dictionary = {}
var _retargeting: bool = false
var _tip_position: Vector2 = Vector2.ZERO
var _total_distance: float = 0.0
var _distance: float = 0.0
var _total_cost: int = 0
var _consumed_nutrition: int = 0
var _buffered_nutrition: int = 0
var _formed_junctions: int = 0
var _segments: Array[Dictionary] = []
var _segment_index: int = 0
var _segment_distance: float = 0.0
var _extension_paid: bool = false
var _shipments: Dictionary[int, bool] = {}
var _completed_endpoints: Dictionary[int, HyphaNode] = {}
var _anchor: Node2D = null
var _branch_anchor: HyphaNode = null
var _tip: GrowthTip = null
var _edge: HyphaEdge = null
var _changing_topology: bool = false
var _advancing: bool = false
var _emitting_changed: bool = false
var _changed_pending: bool = false


func _physics_process(delta: float) -> void:
	advance(delta)


func create_target(start_node: Node2D, target_position: Vector2, initial_plan_version: int = 1) -> int:
	return _create_task(start_node, target_position, &"growth", null, null, initial_plan_version)


## 返回实际建设使用的计划；预览可以在另一任务运行期间读取，供建设队列使用。
func preview_target(start_node: Node2D, target_position: Vector2) -> Dictionary:
	if not _configuration_is_valid() or not _node_is_available(start_node) \
			or not (start_node is MotherCore or start_node is HyphaNode) \
			or not network_system.is_node_registered(start_node):
		return _invalid_target_plan(target_position, "生长起点或网络不可用。")
	var planned: Dictionary = planner.plan_growth(
		start_node.global_position, target_position, network_system, start_node)
	if bool(planned.get("valid", false)) and float(planned.get("distance", 0.0)) <= 0.0:
		planned["valid"] = false
		planned["error"] = "目标必须与生长起点保持距离。"
	return planned


## 已付费段从其终点换路，尚未付费段从当前菌结换路；本方法不修改任务。
func preview_retarget(target_position: Vector2) -> Dictionary:
	var preview: Dictionary = {
		"valid": false, "error": "", "plan": {}, "effective_point": _tip_position,
		"resolved_target_position": target_position,
		"target_position": target_position, "deferred": false,
		"old_remaining_cost": maxi(0, _total_cost - _consumed_nutrition),
		"new_remaining_cost": 0, "cost_delta": 0, "plan_version": _plan_version,
	}
	if not has_active_task() or _task_kind != &"growth" or _changing_topology or _retargeting \
			or _plan_version == MAX_TASK_ID or not _configuration_is_valid() \
			or not _geometry_is_valid() or _segment_index >= _segments.size():
		preview["error"] = "当前生长任务无法改目标。"
		return preview
	var checked_task_id: int = _task_id
	var checked_version: int = _plan_version
	var checked_segment: int = _segment_index
	var checked_anchor: Node2D = _anchor
	var paid: bool = _extension_paid
	var segment_distance: float = _segment_distance
	var current_segment: Dictionary = _segments[_segment_index]
	var start_position: Vector2 = current_segment["end_position"] if paid else _anchor.global_position
	var start_node: Node2D = _anchor if not paid else null
	var paid_endpoint: Variant = current_segment.get("endpoint_node")
	if paid and _node_is_available(paid_endpoint):
		start_node = paid_endpoint as Node2D
	var replacement: Dictionary = planner.plan_growth(start_position, target_position, network_system, start_node)
	if checked_task_id != _task_id or checked_version != _plan_version \
			or checked_segment != _segment_index or checked_anchor != _anchor \
			or paid != _extension_paid or segment_distance != _segment_distance or not has_active_task():
		preview["error"] = "任务已变化，请重新预览。"
		return preview
	if not bool(replacement.get("valid", false)):
		preview["error"] = String(replacement.get("error", "新目标没有可行路线。"))
		return preview
	if float(replacement.get("distance", 0.0)) == 0.0 and not paid and not _anchor is HyphaNode:
		preview["error"] = "目标必须与母核保持距离。"
		return preview
	var locked_cost: int = int(current_segment["junction_cost"]) if paid else 0
	var replacement_cost: int = int(replacement["total_cost"])
	if replacement_cost > MAX_TASK_ID - _consumed_nutrition - locked_cost:
		preview["error"] = "新目标费用超出整数范围。"
		return preview
	preview["valid"] = true
	preview["plan"] = replacement
	preview["effective_point"] = start_position
	preview["resolved_target_position"] = replacement.get("effective_point", target_position)
	preview["deferred"] = paid
	preview["new_remaining_cost"] = locked_cost + replacement_cost
	preview["cost_delta"] = int(preview["new_remaining_cost"]) - int(preview["old_remaining_cost"])
	preview["from_position"] = start_position
	preview["locked_remaining_cost"] = locked_cost
	preview["locked_remaining_distance"] = maxf(0.0, float(current_segment["length"]) - segment_distance) if paid else 0.0
	return preview


func retarget_target(target_position: Vector2) -> bool:
	var checked_task_id: int = _task_id
	var checked_version: int = _plan_version
	var preview: Dictionary = preview_retarget(target_position)
	if not bool(preview["valid"]) or checked_task_id != _task_id or checked_version != _plan_version \
			or not has_active_task() or _changing_topology or _retargeting:
		return false
	_retargeting = true
	var replacement: Dictionary = preview["plan"]
	_target_position = target_position
	_resolved_target_position = preview["resolved_target_position"]
	_target_node = replacement.get("join_node") as HyphaNode
	_plan_version += 1
	_plan = replacement.duplicate(true)
	_total_cost = _consumed_nutrition + int(preview["new_remaining_cost"])
	_total_distance = _distance + float(preview["locked_remaining_distance"]) + float(replacement["distance"])
	_supply_wait_reason = &""
	if bool(preview["deferred"]):
		_pending_retarget = preview.duplicate(true)
		_pending_retarget["plan_version"] = _plan_version
		_segments.resize(_segment_index + 1)
		if bool(_segments[_segment_index].get("is_branch", false)) and not _connection_edges.has(_edge):
			_connection_edges.append(_edge)
	else:
		_pending_retarget = {}
		_set_remaining_segments(replacement)
		if not _connection_edges.has(_edge):
			_connection_edges.append(_edge)
	_retargeting = false
	if _segments.is_empty():
		_complete_at_current_anchor()
	else:
		_refresh_state()
		_publish_changed()
	return true


## 供养账本独占调用：只取因新计划缩短而超出剩余总需求的未消费缓存。
func take_excess_nutrition(task_id: int, maximum: int = MAX_TASK_ID) -> int:
	if task_id != _task_id or maximum <= 0:
		return 0
	var excess: int = mini(maximum, maxi(0, _buffered_nutrition - (_total_cost - _consumed_nutrition)))
	if excess <= 0:
		return 0
	_buffered_nutrition -= excess
	_publish_changed()
	return excess


## 原地使用两个既有菌结；与普通生长共用尖端、任务编号和供养账本。
func create_connection(start_node: HyphaNode, target_node: HyphaNode) -> int:
	if not _configuration_is_valid() or not _node_is_available(start_node) \
			or not _node_is_available(target_node) or start_node == target_node:
		return 0
	var registered: Array[Node2D] = network_system.get_registered_nodes()
	if not registered.has(start_node) or not registered.has(target_node):
		return 0
	var core: MotherCore = network_system.get_registered_core() as MotherCore
	if not _node_is_available(core) or core.health <= 0:
		return 0
	if not _node_is_available(start_node) or not _node_is_available(target_node):
		return 0
	if network_system.has_direct_connection(start_node, target_node):
		return 0
	if not _node_is_available(start_node) or not _node_is_available(target_node) \
			or not _node_is_available(core):
		return 0
	return _create_task(start_node, target_node.global_position, &"connection", target_node, core)


func _create_task(
	start_node: Node2D, target_position: Vector2, task_kind: StringName,
	target_node: HyphaNode = null, connection_core: MotherCore = null, initial_plan_version: int = 1
) -> int:
	if construction_blocker.is_valid() and bool(construction_blocker.call()):
		return 0
	if has_active_task() or _changing_topology or _buffered_nutrition > 0:
		return 0
	if _last_task_id == MAX_TASK_ID or not _configuration_is_valid():
		return 0
	if not _node_is_available(start_node) or not target_position.is_finite():
		return 0
	if not (start_node is HyphaNode or start_node is MotherCore):
		return 0
	if not network_system.is_work_connected_to_core(start_node):
		return 0
	if not _node_is_available(start_node):
		return 0
	if task_kind == &"connection" and not _new_connection_is_valid(
			start_node, target_node, connection_core, target_position):
		return 0
	var planned: Dictionary = preview_target(start_node, target_position) if task_kind == &"growth" else planner.plan(
		start_node.global_position, target_position, true)
	if not planned["valid"] or float(planned["distance"]) <= 0.0:
		return 0
	var joined_node: Variant = planned.get("join_node")
	if task_kind == &"growth" and _node_is_available(joined_node):
		target_node = joined_node as HyphaNode
	# 查询网络可同步触发外部回调；登记前重新拒绝回调中新建的其他任务。
	if has_active_task() or _changing_topology or _buffered_nutrition > 0 \
			or not _configuration_is_valid() or not _node_is_available(start_node):
		return 0

	# 登记过程中暂不公开新任务，network_changed 的同步回调不能启动运输。
	_changing_topology = true
	var new_tip: GrowthTip = TIP_SCENE.instantiate()
	tip_container.add_child(new_tip)
	new_tip.global_position = start_node.global_position
	var new_edge: HyphaEdge = EDGE_SCENE.instantiate()
	new_edge.start_node = start_node
	new_edge.end_node = new_tip
	edge_container.add_child(new_edge)
	var registered: bool = network_system.register_node(new_tip)
	if registered:
		registered = network_system.register_edge(new_edge)
	if registered and task_kind == &"connection":
		registered = _new_connection_is_valid(start_node, target_node, connection_core, target_position)
	if registered and task_kind == &"growth" and target_node != null:
		registered = _node_is_available(target_node) and network_system.is_node_registered(target_node) \
			and target_node.global_position == planned["end_position"] and target_node.is_functional()
	if not registered:
		network_system.unregister_edge(new_edge)
		network_system.unregister_node(new_tip)
		new_edge.free()
		new_tip.free()
		_changing_topology = false
		return 0

	_last_task_id += 1
	var created_task_id: int = _last_task_id
	_task_id = created_task_id
	_state = &"waiting"
	_wait_reason = &""
	_supply_wait_reason = &""
	_task_kind = task_kind
	_start_node = start_node
	_target_node = target_node
	_connection_core = connection_core
	_unbind_connection_network()
	_connection_edges.clear()
	_connection_edges.append(new_edge)
	if task_kind == &"connection":
		_connection_network = network_system
		_connection_network.network_changed.connect(_on_connection_network_changed)
	_target_position = target_position
	_resolved_target_position = planned["end_position"]
	_plan_version = maxi(1, initial_plan_version)
	_plan = planned.duplicate(true)
	_pending_retarget = {}
	_tip_position = new_tip.global_position
	_total_distance = planned["distance"]
	_distance = 0.0
	_total_cost = planned["total_cost"]
	_consumed_nutrition = 0
	_buffered_nutrition = 0
	_formed_junctions = 0
	_segments = planned["segments"]
	_segment_index = 0
	_segment_distance = 0.0
	_extension_paid = false
	_shipments.clear()
	_anchor = start_node
	_branch_anchor = null
	_tip = new_tip
	_edge = new_edge
	_changing_topology = false
	_refresh_state()
	_publish_changed()
	return created_task_id


func pause_task() -> bool:
	if not has_active_task() or _state == &"paused" or _changing_topology:
		return false
	_state = &"paused"
	_wait_reason = &"paused"
	_publish_changed()
	return true


func resume_task() -> bool:
	if not has_active_task() or _state != &"paused" or _changing_topology:
		return false
	_state = &"waiting"
	_refresh_state()
	_publish_changed()
	return true


func cancel_task() -> bool:
	if not has_active_task() or _changing_topology:
		return false
	var cancelled_task_id: int = _task_id
	_state = &"cancelled"
	_wait_reason = &""
	_supply_wait_reason = &""
	_pending_retarget = {}
	_changing_topology = true
	if _node_is_available(_tip):
		_tip_position = _tip.global_position
	var old_tip: GrowthTip = _tip if _node_is_available(_tip) else null
	var old_edge: HyphaEdge = _edge if _node_is_available(_edge) else null
	_tip = null
	_edge = null
	if _node_is_available(old_edge) and old_edge.get_length() > 0.0:
		# 保留已长出的菌丝，但末端仅为惰性 Node2D，不能变成免费的菌结。
		var stump: Node2D = Node2D.new()
		stump.name = "CancelledGrowthStump"
		stump.process_mode = Node.PROCESS_MODE_DISABLED
		if _node_is_available(tip_container):
			tip_container.add_child(stump)
		else:
			add_child(stump)
		stump.global_position = _tip_position
		old_edge.end_node = stump
		if _node_is_available(network_system):
			network_system.register_node(stump)
			network_system.register_edge(old_edge)
	elif _node_is_available(old_edge):
		if _node_is_available(network_system):
			network_system.unregister_edge(old_edge)
		old_edge.free()
	if _node_is_available(old_tip):
		if _node_is_available(network_system):
			network_system.unregister_node(old_tip)
		# 死亡事件在尖端自身发出，不能同步释放正在发信号的对象。
		if not old_tip.is_attackable():
			old_tip.hide()
			old_tip.queue_free()
		else:
			old_tip.free()
	_changing_topology = false
	if _task_kind == &"connection":
		_unbind_connection_network()
		_connection_edges.clear()
	_publish_changed()
	task_cancelled.emit(cancelled_task_id)
	return true


func has_active_task() -> bool:
	return _task_id > 0 and (_state == &"waiting" or _state == &"extending" or _state == &"paused")


## 根生命周期在尖端死亡后调用；沿用取消、退款及保留已付费菌丝的语义。
func abort_destroyed_tip(tip: GrowthTip) -> bool:
	if not is_instance_valid(tip) or tip != _tip or not has_active_task():
		return false
	return cancel_task()


## 统计读取不刷新任务，不因查询触发断路取消或运输结算。
func get_resource_snapshot() -> Dictionary:
	return {"task_id": _task_id, "consumed_nutrition": _consumed_nutrition,
		"buffered_nutrition": _buffered_nutrition}


func get_task_snapshot() -> Dictionary:
	_refresh_state()
	var requested: int = get_requested_nutrition(_task_id)
	var progress: float = 0.0
	if _total_distance > 0.0:
		progress = clampf(_distance / _total_distance, 0.0, 1.0)
	return {
		"task_id": _task_id,
		"task_kind": _task_kind,
		"state": _state,
		"wait_reason": _wait_reason,
		"progress": progress,
		"distance": _distance,
		"total_distance": _total_distance,
		"consumed_nutrition": _consumed_nutrition,
		"buffered_nutrition": _buffered_nutrition,
		"total_cost": _total_cost,
		"remaining_cost": _total_cost - _consumed_nutrition,
		"requested_nutrition": requested,
		"start_node": _start_node if _node_is_available(_start_node) else null,
		"target_node": _target_node if _node_is_available(_target_node) else null,
		"target_position": _target_position,
		"resolved_target_position": _resolved_target_position,
		"plan_version": _plan_version,
		"plan": _plan.duplicate(true),
		"retarget_pending": not _pending_retarget.is_empty(),
		"pending_retarget": _pending_retarget.duplicate(true),
		"excess_nutrition": maxi(0, _buffered_nutrition - (_total_cost - _consumed_nutrition)),
		"tip_position": _tip_position,
		"formed_junctions": _formed_junctions,
	}


func get_delivery_target(task_id: int) -> Node2D:
	if task_id != _task_id or not has_active_task() or not _node_is_available(_tip):
		return null
	return _tip


## 保存提交时的节点身份；后续任务、同坐标节点和重复完成通知都不能替换它。
func get_completed_endpoint(task_id: int) -> HyphaNode:
	var endpoint: Variant = _completed_endpoints.get(task_id)
	return endpoint if _node_is_available(endpoint) else null


func get_requested_nutrition(task_id: int) -> int:
	if task_id != _task_id or not has_active_task() or _state == &"paused" or _changing_topology:
		return 0
	if not _can_advance():
		return 0
	if task_id != _task_id or not has_active_task() or _state == &"paused":
		return 0
	return maxi(0, _next_investment_cost() - _buffered_nutrition)


func receive_nutrition(task_id: int, shipment_id: int, amount: int) -> bool:
	if task_id != _task_id or not has_active_task() or shipment_id <= 0 or amount <= 0:
		return false
	if _shipments.has(shipment_id) or amount > _total_cost - _consumed_nutrition - _buffered_nutrition:
		return false
	_shipments[shipment_id] = true
	_buffered_nutrition += amount
	_refresh_state()
	_publish_changed()
	return true


func take_unspent_nutrition(task_id: int) -> int:
	if task_id != _task_id or (_state != &"completed" and _state != &"cancelled"):
		return 0
	if _buffered_nutrition == 0:
		return 0
	var unspent: int = _buffered_nutrition
	_buffered_nutrition = 0
	_publish_changed()
	return unspent


func set_supply_wait_reason(task_id: int, reason: StringName) -> void:
	if task_id != _task_id or not has_active_task() or not SUPPLY_WAIT_REASONS.has(reason):
		return
	if reason == _supply_wait_reason:
		return
	_supply_wait_reason = reason
	if _refresh_state():
		_publish_changed()


func advance(delta: float) -> void:
	if not has_active_task() or _state == &"paused" or _advancing or _changing_topology or _retargeting:
		return
	if not is_finite(delta) or delta <= 0.0:
		return
	_advancing = true
	var advancing_task_id: int = _task_id
	var remaining_time: float = delta
	while _is_advancing_task(advancing_task_id):
		if _refresh_state():
			_publish_changed()
		if not _is_advancing_task(advancing_task_id) or not _can_advance():
			break
		var segment: Dictionary = _segments[_segment_index]
		if not _extension_paid:
			var extension_cost: int = segment["extension_cost"]
			if _buffered_nutrition < extension_cost or remaining_time <= 0.0:
				break
			_buffered_nutrition -= extension_cost
			_consumed_nutrition += extension_cost
			_extension_paid = true
			_refresh_state()
			_publish_changed()
		if not _is_advancing_task(advancing_task_id) or not _can_advance():
			break
		var segment_length: float = segment["length"]
		if _segment_distance < segment_length:
			var travel: float = minf(segment_length - _segment_distance, growth_speed * remaining_time)
			_segment_distance += travel
			remaining_time = maxf(0.0, remaining_time - travel / growth_speed)
			var segment_end: Vector2 = segment["end_position"]
			if _segment_distance >= segment_length:
				_segment_distance = segment_length
				_distance = segment["cumulative_distance"]
				_tip.global_position = segment_end
			else:
				_distance = float(segment["cumulative_distance"]) - segment_length + _segment_distance
				var segment_start: Vector2 = segment["start_position"]
				_tip.global_position = segment_start.lerp(segment_end, _segment_distance / segment_length)
			_tip_position = _tip.global_position
			_refresh_state()
			_publish_changed()
		if not _is_advancing_task(advancing_task_id) or not _can_advance():
			break
		if _segment_distance < segment_length or _buffered_nutrition < int(segment["junction_cost"]):
			break
		var completing_segment: int = _segment_index
		var completing_anchor: Node2D = _anchor
		_form_junction()
		if remaining_time <= 0.0 or (_segment_index == completing_segment and _anchor == completing_anchor):
			break
	_advancing = false


func _node_is_available(node: Variant) -> bool:
	# 已被外部 free 的引用也可进入本检查，不能先转换为 Node 参数。
	return is_instance_valid(node) and not node.is_queued_for_deletion()


func _configuration_is_valid() -> bool:
	return planner != null and _node_is_available(network_system) \
		and _node_is_available(node_container) and _node_is_available(edge_container) \
		and _node_is_available(tip_container)


func _geometry_is_valid() -> bool:
	if not _node_is_available(_tip) or not _node_is_available(_edge) or not _node_is_available(_anchor) \
			or _edge.start_node != _anchor or _edge.end_node != _tip:
		return false
	if planner == null or planner.terrain_navigation == null:
		return true
	if not is_instance_valid(planner.terrain_navigation) or _segment_index >= _segments.size():
		return false
	var segment: Dictionary = _segments[_segment_index]
	return _anchor.global_position == segment["start_position"] \
		and planner.terrain_navigation.is_segment_clear(
			_anchor.global_position, segment["end_position"], GrowthPlanner.TERRAIN_CLEARANCE)


func _can_advance() -> bool:
	if not _configuration_is_valid() or not _geometry_is_valid() \
		or not is_finite(growth_speed) or growth_speed <= 0.0:
		return false
	var checked_task_id: int = _task_id
	var connected: bool = network_system.is_work_connected_to_core(_tip)
	if _task_kind == &"connection":
		connected = connected and _connection_target_is_valid() and _connection_source_is_available()
	return checked_task_id == _task_id and has_active_task() and _state != &"paused" \
		and connected and _geometry_is_valid()


func _is_advancing_task(task_id: int) -> bool:
	return _task_id == task_id and has_active_task() and _state != &"paused"


func _next_investment_cost() -> int:
	if not has_active_task() or _segment_index >= _segments.size():
		return 0
	var segment: Dictionary = _segments[_segment_index]
	if not _extension_paid:
		return segment["extension_cost"]
	if _segment_distance >= float(segment["length"]):
		return segment["junction_cost"]
	return 0


func _refresh_state() -> bool:
	if not has_active_task() or _changing_topology:
		return false
	if _task_kind == &"connection" and not _connection_target_is_valid():
		cancel_task()
		return true
	if _task_kind == &"growth" and _target_node != null and not _growth_join_is_valid(_target_node, _resolved_target_position):
		cancel_task()
		return true
	var previous_state: StringName = _state
	var previous_reason: StringName = _wait_reason
	var checked_task_id: int = _task_id
	var connected: bool = false
	if _state != &"paused" and _configuration_is_valid() and _geometry_is_valid() \
		and is_finite(growth_speed) and growth_speed > 0.0:
		connected = network_system.is_work_connected_to_core(_tip)
		if _task_kind == &"connection":
			connected = connected and _connection_source_is_available()
	# 网络查询可能同步发出 network_changed；不能覆盖回调已经提交的终态。
	if checked_task_id != _task_id or not has_active_task() or _changing_topology:
		return false
	if _state == &"paused":
		_wait_reason = &"paused"
	elif not _configuration_is_valid() or not _geometry_is_valid() \
		or not is_finite(growth_speed) or growth_speed <= 0.0:
		_state = &"waiting"
		_wait_reason = &"invalid_configuration"
	elif _task_kind == &"connection" and not _connection_core_is_alive():
		_state = &"waiting"
		_wait_reason = &"core_unavailable"
	elif not connected:
		_state = &"waiting"
		_wait_reason = &"disconnected"
	elif _extension_paid and _segment_distance < float(_segments[_segment_index]["length"]):
		_state = &"extending"
		_wait_reason = &""
	else:
		_state = &"waiting"
		_wait_reason = &""
		if _buffered_nutrition < _next_investment_cost():
			_wait_reason = _supply_wait_reason if _supply_wait_reason != &"" else &"nutrition"
	return previous_state != _state or previous_reason != _wait_reason


func _form_junction() -> void:
	if _task_kind == &"connection" and _segment_index == _segments.size() - 1:
		_complete_existing_endpoint()
		return
	var completed_task_id: int = _task_id
	var segment: Dictionary = _segments[_segment_index]
	var was_branch: bool = bool(segment.get("is_branch", false))
	var existing_endpoint: Variant = segment.get("endpoint_node")
	var is_existing: bool = existing_endpoint != null
	if is_existing and (not _growth_join_is_valid(existing_endpoint, segment["end_position"]) \
			or network_system.has_direct_connection(_anchor, existing_endpoint)):
		cancel_task()
		return
	if completed_task_id != _task_id or not has_active_task() or not _geometry_is_valid():
		return
	var junction: HyphaNode = existing_endpoint as HyphaNode if is_existing else NODE_SCENE.instantiate()
	_changing_topology = true
	var junction_cost: int = segment["junction_cost"]
	_buffered_nutrition -= junction_cost
	_consumed_nutrition += junction_cost
	if not is_existing:
		node_container.add_child(junction)
		junction.global_position = segment["end_position"]
		network_system.register_node(junction)
	# 先把已完成边接到成熟节点，再注销尖端，防止网络注销连带移除该边。
	_handoff_tip_endpoint(junction)
	if is_existing and (not network_system.register_edge(_edge) \
			or not _growth_join_is_valid(junction, segment["end_position"])):
		_edge.end_node = _tip
		network_system.register_edge(_edge)
		_changing_topology = false
		cancel_task()
		return
	if is_existing and _pending_retarget.is_empty() and _segment_index == _segments.size() - 1 \
			and _start_node is HyphaNode and _start_node != junction \
			and not network_system.register_connection_corridor(_start_node as HyphaNode, junction, _connection_edges):
		_edge.end_node = _tip
		network_system.register_edge(_edge)
		_changing_topology = false
		cancel_task()
		return
	if not is_existing:
		_formed_junctions += 1
	var next_anchor: Node2D = junction
	if not _pending_retarget.is_empty():
		var replacement: Dictionary = _pending_retarget["plan"]
		_pending_retarget = {}
		_set_remaining_segments(replacement)
	elif was_branch:
		_segment_index += 1
		next_anchor = _branch_anchor
		_branch_anchor = null
	else:
		_segment_index += 1
	_anchor = next_anchor
	var is_final: bool = _segment_index >= _segments.size()
	if is_final:
		_state = &"completed"
		_completed_endpoints[completed_task_id] = junction
		_wait_reason = &""
		_supply_wait_reason = &""
		_distance = _total_distance
		_tip_position = junction.global_position
		var old_tip: GrowthTip = _tip
		_tip = null
		_edge = null
		network_system.unregister_node(old_tip)
		old_tip.free()
	else:
		_segment_distance = 0.0
		_extension_paid = false
		if not _node_is_available(next_anchor):
			_changing_topology = false
			cancel_task()
			return
		_tip.global_position = next_anchor.global_position
		_tip_position = _tip.global_position
		var next_is_branch: bool = bool(_segments[_segment_index].get("is_branch", false))
		if next_is_branch:
			_branch_anchor = next_anchor as HyphaNode
		var next_edge: HyphaEdge = EDGE_SCENE.instantiate()
		next_edge.start_node = next_anchor
		next_edge.end_node = _tip
		edge_container.add_child(next_edge)
		_edge = next_edge
		network_system.register_edge(next_edge)
		if _task_kind == &"connection" or not next_is_branch:
			_connection_edges.append(next_edge)
		_state = &"waiting"
		_supply_wait_reason = &""
	_changing_topology = false
	_refresh_state()
	_publish_changed()
	if not is_existing:
		junction_formed.emit(junction)
	if is_final:
		task_completed.emit(completed_task_id)


func _invalid_target_plan(target_position: Vector2, error: String) -> Dictionary:
	var segments: Array[Dictionary] = []
	return {
		"valid": false, "error": error, "start_position": Vector2.ZERO,
		"end_position": target_position, "requested_position": target_position,
		"effective_point": target_position, "join_node": null, "distance": 0.0,
		"segments": segments, "junction_positions": PackedVector2Array(),
		"extension_cost": 0, "junction_cost": 0, "total_cost": 0,
	}


func _growth_join_is_valid(endpoint: Variant, position: Vector2) -> bool:
	return _node_is_available(endpoint) and endpoint is HyphaNode \
		and _node_is_available(network_system) and network_system.is_node_registered(endpoint) \
		and endpoint.is_functional() and endpoint.global_position == position


func _set_remaining_segments(planned: Dictionary) -> void:
	_segments = []
	for segment: Dictionary in planned.get("segments", []):
		var remaining_segment: Dictionary = segment.duplicate(true)
		remaining_segment["cumulative_distance"] = float(segment["cumulative_distance"]) + _distance
		_segments.append(remaining_segment)
	_segment_index = 0
	_segment_distance = 0.0
	_extension_paid = false
	_branch_anchor = null


func _complete_at_current_anchor() -> void:
	if not has_active_task() or not _anchor is HyphaNode or not _node_is_available(_anchor):
		return
	var completed_task_id: int = _task_id
	var old_tip: GrowthTip = _tip
	var old_edge: HyphaEdge = _edge
	_changing_topology = true
	_state = &"completed"
	_completed_endpoints[completed_task_id] = _anchor as HyphaNode
	_tip_position = _anchor.global_position
	_distance = _total_distance
	_wait_reason = &""
	_supply_wait_reason = &""
	_tip = null
	_edge = null
	if _node_is_available(old_edge):
		network_system.unregister_edge(old_edge)
		old_edge.free()
	if _node_is_available(old_tip):
		network_system.unregister_node(old_tip)
		old_tip.free()
	_changing_topology = false
	_publish_changed()
	task_completed.emit(completed_task_id)


func _new_connection_is_valid(
	start: Node2D, target: HyphaNode, core: MotherCore, target_position: Vector2
) -> bool:
	if not _node_is_available(start) or not start is HyphaNode \
			or not _node_is_available(target) or not _node_is_available(core) or core.health <= 0:
		return false
	var registered: Array[Node2D] = network_system.get_registered_nodes()
	var registered_core: Node2D = network_system.get_registered_core()
	if not _node_is_available(start) or not _node_is_available(target) or not _node_is_available(core) \
			or not registered.has(start) or not registered.has(target) or registered_core != core:
		return false
	var supplied: bool = network_system.find_route(start, core).found
	return supplied and _node_is_available(start) and _node_is_available(target) \
		and _node_is_available(core) and core.health > 0 and target.global_position == target_position


func _connection_target_is_valid() -> bool:
	if not _node_is_available(_target_node) or not _node_is_available(_connection_network):
		return false
	var registered: Array[Node2D] = _connection_network.get_registered_nodes()
	return _node_is_available(_target_node) and registered.has(_target_node) \
		and _target_node.global_position == _target_position


func _connection_core_is_alive() -> bool:
	if not _node_is_available(_connection_core) or _connection_core.health <= 0 \
			or not _node_is_available(_connection_network) or network_system != _connection_network:
		return false
	var checked_network: NetworkSystem = _connection_network
	var registered_core: Node2D = checked_network.get_registered_core()
	return _connection_network == checked_network and _node_is_available(_connection_core) \
		and _connection_core.health > 0 and registered_core == _connection_core


func _connection_source_is_available() -> bool:
	return _connection_core_is_alive() and _node_is_available(_start_node) \
		and _connection_network.find_route(_start_node, _connection_core).found


func _on_connection_network_changed() -> void:
	if _task_kind == &"connection" and has_active_task() and not _changing_topology:
		if not _connection_target_is_valid():
			cancel_task()
		elif _refresh_state():
			_publish_changed()


func _unbind_connection_network() -> void:
	if is_instance_valid(_connection_network) \
			and _connection_network.network_changed.is_connected(_on_connection_network_changed):
		_connection_network.network_changed.disconnect(_on_connection_network_changed)
	_connection_network = null


## 最后一段只接到选中的旧节点，不创建重合菌结，也不发 junction_formed。
func _complete_existing_endpoint() -> void:
	if not _connection_target_is_valid() or not _connection_source_is_available():
		_refresh_state()
		return
	var completed_task_id: int = _task_id
	var source_route: NetworkRoute = _connection_network.find_route(_start_node, _connection_core)
	var old_tip: GrowthTip = _tip
	_changing_topology = true
	_handoff_tip_endpoint(_target_node)
	var committed: bool = _connection_network.register_edge(_edge)
	var cancel_on_failure: bool = not committed
	if committed:
		_connection_network.unregister_node(old_tip)
		# 注销尖端的同步回调可能移除目标或供给边，不能借新终点假造施工供给。
		var target_valid: bool = _connection_target_is_valid()
		cancel_on_failure = not target_valid
		committed = target_valid and _connection_core_is_alive() \
			and _connection_network.is_route_valid(source_route)
	if committed:
		committed = _connection_network.register_connection_corridor(
			_start_node as HyphaNode, _target_node, _connection_edges
		)
		cancel_on_failure = not committed
	if not committed:
		_edge.end_node = old_tip
		_connection_network.register_node(old_tip)
		_connection_network.register_edge(_edge)
		_changing_topology = false
		if cancel_on_failure:
			cancel_task()
		else:
			_refresh_state()
		_publish_changed()
		return
	_state = &"completed"
	_completed_endpoints[completed_task_id] = _target_node
	_anchor = _target_node
	_segment_index += 1
	_wait_reason = &""
	_supply_wait_reason = &""
	_distance = _total_distance
	_tip_position = _target_position
	_tip = null
	_edge = null
	_changing_topology = false
	old_tip.free()
	_unbind_connection_network()
	_publish_changed()
	task_completed.emit(completed_task_id)


## 中继生成只改变末端身份，不撤销仍在原菌丝上移动的供养许可。
func _handoff_tip_endpoint(endpoint: HyphaNode) -> void:
	if is_instance_valid(traffic_system) and traffic_system.network_system == network_system \
			and traffic_system.handoff_growth_endpoint(_edge, _tip, endpoint):
		return
	# 旧独立夹具未绑定交通时仍记录同一合法交接；不创建隐式容量池。
	_edge.set_meta("growth_handoff_from_id", _tip.get_instance_id())
	_edge.set_meta("growth_handoff_to_ref", weakref(endpoint))
	_edge.end_node = endpoint


func _publish_changed() -> void:
	_changed_pending = true
	if _changing_topology or _emitting_changed:
		return
	_emitting_changed = true
	# 同步的接收、暂停或退款回调合并到下一快照，不递归发送旧快照。
	while _changed_pending:
		_changed_pending = false
		task_changed.emit(get_task_snapshot())
	_emitting_changed = false
