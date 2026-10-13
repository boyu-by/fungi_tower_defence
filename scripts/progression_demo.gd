extends "res://scripts/level_01.gd"
## 两处有限尸骸沿用正式采集链路；本脚本只显示指引并观察真实接入。

signal resource_access_changed(resource_index: int, connected: bool)

const RESOURCE_PATHS: Array[NodePath] = [
	^"World/Remains/FirstCarcass", ^"World/Remains/SecondCarcass",
]
const RESOURCE_POSITIONS: Array[Vector2] = [Vector2(1030, 450), Vector2(110, 460)]
const RECOMMENDED_TARGETS: Array[Vector2] = [Vector2(970, 440), Vector2(180, 450)]
const GUIDE_PATHS: Array[NodePath] = [
	^"World/FirstResourceGuide/Hint", ^"World/SecondResourceGuide/Hint",
]
const ORIGIN_PATHS: Array[NodePath] = [
	^"World/Colony/Nodes/RightNode", ^"World/Colony/Nodes/HyphaNode",
]
const CULTIVATION_COST: int = CultivationSystem.TOTAL_COST

var _observed_access: Array[bool] = [false, false]
var _last_resource_snapshots: Array[Dictionary] = []
var _is_observing_access: bool = false
var _observation_stopped: bool = false


func _ready() -> void:
	super._ready()
	_position_digestive_queue_label()
	_refresh_resource_guides()
	_observe_resource_access()


func _process(delta: float) -> void:
	super._process(delta)
	# 菌域半径逐帧扩张且没有扩张信号，不能把建造完成当作已接入。
	_observe_resource_access()


func _exit_tree() -> void:
	_observation_stopped = true
	super._exit_tree()


## 每次返回新的有序快照；查询不会采集、预留、补给或推进成长。
func get_resource_access_snapshot() -> Array[Dictionary]:
	var resources: Array[Dictionary] = []
	for resource_offset: int in range(RESOURCE_PATHS.size()):
		resources.append(_read_resource_snapshot(resource_offset))
	return resources


func get_demo_snapshot() -> Dictionary:
	return {
		"resources": get_resource_access_snapshot(),
		"first_target": RECOMMENDED_TARGETS[0],
		"second_target": RECOMMENDED_TARGETS[1],
	}


func _observe_resource_access() -> void:
	if _is_observing_access or not _observer_can_run():
		return
	_is_observing_access = true
	var observer_reference: WeakRef = weakref(self)
	for resource_offset: int in range(RESOURCE_PATHS.size()):
		if not _observer_can_run():
			break
		# 前一个接入回调可能删除资源或母核，下一条必须重新读取真实状态。
		var snapshot: Dictionary = _read_resource_snapshot(resource_offset)
		if resource_offset < _last_resource_snapshots.size():
			_last_resource_snapshots[resource_offset] = snapshot
		else:
			_last_resource_snapshots.append(snapshot)
		var connected: bool = bool(snapshot["connected"])
		if connected == _observed_access[resource_offset]:
			continue
		_observed_access[resource_offset] = connected
		resource_access_changed.emit(resource_offset + 1, connected)
		if not is_instance_valid(observer_reference.get_ref()):
			return
	_is_observing_access = false


func _read_resource_snapshot(resource_offset: int) -> Dictionary:
	var snapshot: Dictionary = {
		"index": resource_offset + 1,
		"resource_id": "",
		"connected": false,
		"position": RESOURCE_POSITIONS[resource_offset],
		"recommended_target": RECOMMENDED_TARGETS[resource_offset],
		"remaining_nutrition": 0,
		"harvested_nutrition": 0,
	}
	if resource_offset < _last_resource_snapshots.size():
		snapshot = _last_resource_snapshots[resource_offset].duplicate()
		snapshot["connected"] = false
	var carcass: LargeCarcass = get_node_or_null(RESOURCE_PATHS[resource_offset]) as LargeCarcass
	if not _is_live_demo_node(carcass):
		return snapshot
	var stock: Dictionary = carcass.get_snapshot()
	snapshot["resource_id"] = String(stock["resource_id"])
	snapshot["position"] = carcass.global_position
	snapshot["remaining_nutrition"] = int(stock["remaining_nutrition"])
	snapshot["harvested_nutrition"] = int(stock["harvested_nutrition"])
	snapshot["connected"] = _has_resource_access(carcass)
	return snapshot


func _has_resource_access(carcass: LargeCarcass) -> bool:
	if not _access_dependencies_are_live() or not _is_live_demo_node(carcass):
		return false
	if network_system.peek_registered_core() != mother_core:
		return false
	for stomach: DigestiveOrgan in get_digestive_organs():
		if not _is_live_demo_node(stomach) or not stomach.is_functional():
			continue
		var stomach_node: Node2D = stomach.get_parent() as Node2D
		for candidate: Node2D in fungal_field.get_collecting_nodes(carcass.global_position):
			if not _is_live_demo_node(candidate):
				continue
			var stomach_route: NetworkRoute = network_system.find_available_route(candidate, stomach_node, 2)
			var core_route: NetworkRoute = network_system.find_available_route(candidate, mother_core)
			if stomach_route.found and core_route.found:
				return true
	return false


func _observer_can_run() -> bool:
	return not _observation_stopped and is_inside_tree() and not is_queued_for_deletion()


func _access_dependencies_are_live() -> bool:
	return _observer_can_run() and not _is_tearing_down \
		and _is_live_demo_node(mother_core) and mother_core.health > 0 \
		and not get_digestive_organs().is_empty() and _is_live_demo_node(network_system) \
		and _is_live_demo_node(fungal_field)


func _is_live_demo_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion() \
		and node.is_inside_tree() and is_ancestor_of(node)


func _position_digestive_queue_label() -> void:
	var queue_label: Label = get_node_or_null("World/Colony/Nodes/RearNode/DigestiveOrgan/QueueLabel") as Label
	if is_instance_valid(queue_label):
		queue_label.position = Vector2(-248, -4)


func _refresh_resource_guides() -> void:
	for resource_offset: int in range(GUIDE_PATHS.size()):
		var guide: Label = get_node_or_null(GUIDE_PATHS[resource_offset]) as Label
		var origin: Node2D = get_node_or_null(ORIGIN_PATHS[resource_offset]) as Node2D
		if not is_instance_valid(guide) or not is_instance_valid(origin) or growth_planner == null:
			continue
		var plan: Dictionary = growth_system.preview_target(origin, RECOMMENDED_TARGETS[resource_offset])
		if not bool(plan.get("valid", false)):
			guide.text = "推荐点规划不可用，请查看伸展预览"
			continue
		var network_cost: int = int(plan["total_cost"])
		var title: String = "① 尸骸80｜右翼菌结" if resource_offset == 0 \
			else "② 尸骸120｜左翼菌结"
		var target: Vector2 = RECOMMENDED_TARGETS[resource_offset]
		var cycle_text: String = "实际回流满60 → 展开，解锁双尖端" if resource_offset == 0 \
			else "实际回流满160 → 成熟，可扩第二胃室"
		guide.text = "%s → 十字(%d,%d)\nG %d｜B %d+%d=%d｜每批10\n%s" % [
			title, int(target.x), int(target.y), network_cost, network_cost, CULTIVATION_COST,
			network_cost + CULTIVATION_COST, cycle_text,
		]
		if growth_planner.bounded_branches_enabled:
			guide.text = "%s → 十字(%d,%d)\n初次网络 %d（含侧枝）｜B另加攻击12/胃8\n%s" % [title, int(target.x), int(target.y), network_cost, cycle_text]
