class_name CombatResourceLedger
extends Node
## 只观察单局实际来源与去向。缓存/运输采用唯一持有者，记录历史消费但不结算游戏资源。

const PARTS: Array[String] = [
	"core", "organ_stock", "combat_transit", "network_structure", "organ_structure",
	"growth_buffer", "cultivation_buffer", "startup_reserved", "growth_transit", "cultivation_transit",
	"differentiation_buffer", "differentiation_transit", "differentiation_consumed",
	"repair_buffer", "repair_transit", "repair_consumed", "carcass_stock", "ground_remains",
	"remains_transit", "stomach_intake", "output_queued", "return_transit",
	"combat_consumed", "removed_organ_stock", "destroyed_stomach_intake", "destroyed_stomach_output",
	"decayed_remains", "transplant_stock", "transplant_buffer", "transplant_transit", "transplant_consumed", "transplant_lost",
]
const CONSTRUCTION_PARTS: Array[String] = [
	"network_structure", "organ_structure", "growth_buffer", "cultivation_buffer",
	"startup_reserved", "growth_transit", "cultivation_transit",
]

var _level_ref: WeakRef
var _level_id: int = 0
var _initial_total: int = 0
var _configured: bool = false
var _stopped: bool = false
var _bindings: Array[Dictionary] = []
var _enemy_bounties: Dictionary[int, int] = {}
var _watched_enemies: Dictionary[int, bool] = {}
var _committed_organs: Dictionary[int, WeakRef] = {}
var _removed_stock: Dictionary[int, int] = {}
var _tissue_losses: Dictionary[int, Dictionary] = {}
var _decay_losses: Dictionary[int, int] = {}
var _repair_costs: Dictionary[int, int] = {}
var _local_growth_costs: Dictionary[int, int] = {}
var _last_snapshot: Dictionary = {}


func _init() -> void:
	set_process(false)


func _exit_tree() -> void:
	stop()


func configure(level: Node) -> void:
	if not _live(level) or (_configured and level.get_instance_id() == _level_id):
		return
	stop()
	_level_ref = weakref(level)
	_level_id = level.get_instance_id()
	_configured = true
	_stopped = false
	_enemy_bounties.clear()
	_watched_enemies.clear()
	_committed_organs.clear()
	_removed_stock.clear()
	_tissue_losses.clear()
	_decay_losses.clear()
	_repair_costs.clear()
	_local_growth_costs.clear()
	var remains: Node = level.get_node("World/Remains")
	_bind(remains, &"child_entered_tree", _on_remains_added)
	for corpse: Node in remains.get_children():
		_on_remains_added(corpse)
	var enemies: Node = level.get_node("World/Enemies")
	_bind(enemies, &"child_entered_tree", _on_enemy_added)
	for enemy: Node in enemies.get_children():
		_on_enemy_added(enemy)
	for organ: AttackOrgan in _organs(level):
		_track_committed_organ(organ)
	var coordinator: ConstructionCoordinator = level.get_node("Systems/ConstructionCoordinator")
	_bind(coordinator, &"organ_matured", _on_worker_organ_matured)
	var cultivation: CultivationSystem = level.get_node("Systems/CultivationSystem")
	_bind(cultivation, &"organ_matured", _on_local_organ_matured)
	var repair: RepairSystem = level.get_node("Systems/RepairSystem")
	_bind(repair, &"task_changed", _on_repair_changed)
	_on_repair_changed(repair.get_resource_snapshot())
	var growth: GrowthSystem = level.get_node("Systems/GrowthSystem")
	_bind(growth, &"task_changed", _on_local_growth_changed)
	_on_local_growth_changed(growth.get_resource_snapshot())
	var parts: Dictionary = _read_parts(level)
	_initial_total = _sum(parts)
	_last_snapshot = _snapshot(parts, level)


func get_snapshot() -> Dictionary:
	var level: Node = _level()
	if not _configured or _stopped or not _live(level):
		var closed: Dictionary = _last_snapshot.duplicate(true)
		closed["valid"] = false
		return closed
	var parts: Dictionary = _read_parts(level)
	_last_snapshot = _snapshot(parts, level)
	return _last_snapshot.duplicate(true)


func stop() -> void:
	if _stopped:
		return
	_stopped = true
	for binding: Dictionary in _bindings:
		var source: Object = (binding["source"] as WeakRef).get_ref()
		if is_instance_valid(source) and source.is_connected(binding["signal"], binding["callback"]):
			source.disconnect(binding["signal"], binding["callback"])
	_bindings.clear()


func _snapshot(parts: Dictionary, level: Node) -> Dictionary:
	var created: int = _sum(_enemy_bounties)
	var expected: int = _initial_total + created
	var total: int = _sum(parts)
	return {"valid": true, "initial_total": _initial_total, "enemy_created_nutrition": created,
		"expected_total": expected, "accounted_total": total, "error": total - expected,
		"balanced": total == expected, "parts": parts.duplicate(),
		"combat": level.call("get_combat_statistics").duplicate()}


func _read_parts(level: Node) -> Dictionary:
	var parts: Dictionary = {}
	for key: String in PARTS:
		parts[key] = 0
	var core: MotherCore = level.get_node_or_null("World/Colony/MotherCore") as MotherCore
	if is_instance_valid(core):
		parts["core"] = core.nutrition
	for organ: AttackOrgan in _organs(level):
		var location: String = "organ_stock" if organ.get_parent() is HyphaNode else "transplant_stock"
		parts[location] += organ.nutrition
	# 战斗供养登记发生在扣款后；预约数量不再另加为库存。
	var combat_supply: SupplySystem = level.get_node("Systems/SupplySystem")
	parts["combat_transit"] = combat_supply.get_in_transit_count()
	var coordinator: ConstructionCoordinator = level.get_node("Systems/ConstructionCoordinator")
	var construction: Dictionary = coordinator.get_resource_snapshot()
	for key: String in CONSTRUCTION_PARTS:
		parts[key] = int(construction.get(key, 0))
	# 多worker场景仍保留兼容的独立本地模块；它们不在worker总量内。
	if coordinator.multi_worker_enabled:
		var growth: GrowthSystem = level.get_node("Systems/GrowthSystem")
		var growth_resources: Dictionary = growth.get_resource_snapshot()
		parts["network_structure"] += _sum(_local_growth_costs)
		parts["growth_buffer"] += int(growth_resources.get("buffered_nutrition", 0))
		var cultivation: CultivationSystem = level.get_node("Systems/CultivationSystem")
		var cultivation_resources: Dictionary = cultivation.get_resource_snapshot()
		parts["organ_structure"] += int(cultivation_resources.get("structure_consumed", 0))
		parts["cultivation_buffer"] += int(cultivation_resources.get("buffered_nutrition", 0))
		parts["startup_reserved"] += int(cultivation_resources.get("startup_reserved", 0))
		parts["growth_transit"] += _paid_transit(level.get_node("Systems/GrowthSupplySystem"))
		parts["cultivation_transit"] += _paid_transit(level.get_node("Systems/CultivationSupplySystem"))
	var differentiation: DifferentiationSystem = level.get_node("Systems/DifferentiationSystem")
	var material: Dictionary = differentiation.get_resource_snapshot()
	parts["differentiation_buffer"] = int(material.get("buffered_nutrition", 0))
	parts["differentiation_consumed"] = int(material.get("consumed_nutrition", 0))
	parts["differentiation_transit"] = (level.get_node("Systems/DifferentiationSupplySystem") as DifferentiationSupplySystem).get_in_transit_nutrition()
	var repair: RepairSystem = level.get_node("Systems/RepairSystem")
	parts["repair_buffer"] = int(repair.get_resource_snapshot().get("buffered_nutrition", 0))
	parts["repair_consumed"] = _sum(_repair_costs)
	parts["repair_transit"] = (level.get_node("Systems/RepairSupplySystem") as RepairSupplySystem).get_in_transit_nutrition()
	for child: Node in level.get_node("World/Remains").get_children():
		if child.is_queued_for_deletion():
			continue
		if child is LargeCarcass:
			parts["carcass_stock"] += child.get_remaining_nutrition()
		elif child is EnemyRemains:
			var key: String = "ground_remains" if child.is_available() else "remains_transit"
			parts[key] += child.nutrition_value
	var output: int = 0
	for stomach: DigestiveOrgan in level.call("get_digestive_organs"):
		if _live(stomach):
			parts["stomach_intake"] += stomach.get_queued_nutrition()
			output += stomach.get_output_nutrition()
	parts["return_transit"] = (level.get_node("Systems/NutritionReturnSystem") as NutritionReturnSystem).get_in_transit_nutrition()
	parts["output_queued"] = output - int(parts["return_transit"])
	parts["combat_consumed"] = int(level.call("get_combat_statistics").get("nutrition_spent", 0))
	parts["removed_organ_stock"] = _sum(_removed_stock)
	parts["decayed_remains"] = _sum(_decay_losses)
	var transplant: Node = level.get_node_or_null("Systems/TransplantSystem")
	if is_instance_valid(transplant):
		var moving: Dictionary = transplant.get_resource_snapshot()
		parts["transplant_buffer"] = int(moving.get("buffered_nutrition", 0))
		parts["transplant_transit"] = int(moving.get("in_transit_nutrition", 0))
		parts["transplant_consumed"] = int(moving.get("consumed_nutrition", 0))
		parts["transplant_lost"] = int(moving.get("lost_nutrition", 0))
	for loss: Dictionary in _tissue_losses.values():
		parts["destroyed_stomach_intake"] += int(loss.get("input_nutrition", 0))
		parts["destroyed_stomach_output"] += int(loss.get("output_nutrition", 0))
	# queue_free到退出信号之间，也把已不可用的原库存划入损耗，不能短暂丢账。
	for organ_id: int in _committed_organs:
		var organ: AttackOrgan = _committed_organs[organ_id].get_ref() as AttackOrgan
		if not _removed_stock.has(organ_id) and is_instance_valid(organ) and organ.is_queued_for_deletion():
			parts["removed_organ_stock"] += organ.nutrition
	return parts


func _on_enemy_added(node: Node) -> void:
	if _stopped or not node is BasicEnemy or not node.creates_remains() or _watched_enemies.has(node.get_instance_id()):
		return
	_watched_enemies[node.get_instance_id()] = true
	_bind(node, &"died", _on_enemy_died)


func _on_enemy_died(enemy: BasicEnemy) -> void:
	if _stopped or not is_instance_valid(enemy) or _enemy_bounties.has(enemy.get_instance_id()):
		return
	_enemy_bounties[enemy.get_instance_id()] = enemy.remains_nutrition


func _on_worker_organ_matured(_id: String, _host: HyphaNode, organ: AttackOrgan, _weapon: SporeWeapon) -> void:
	_track_committed_organ(organ)


func _on_local_organ_matured(_id: int, _host: HyphaNode, organ: AttackOrgan, _weapon: SporeWeapon) -> void:
	_track_committed_organ(organ)


func _track_committed_organ(organ: AttackOrgan) -> void:
	if _stopped or not _live(organ) or _committed_organs.has(organ.get_instance_id()):
		return
	var organ_id: int = organ.get_instance_id()
	_committed_organs[organ_id] = weakref(organ)
	_bind(organ, &"tree_exiting", _on_organ_exiting.bind(organ_id))


func _on_organ_exiting(organ_id: int) -> void:
	if _stopped or _removed_stock.has(organ_id):
		return
	var organ: AttackOrgan = _committed_organs[organ_id].get_ref() as AttackOrgan
	if is_instance_valid(organ):
		# 移植的同一对象暂时离树，只更换宿主，不构成死亡损耗。
		if organ.is_transplanting() and not organ.is_queued_for_deletion() and organ.health > 0.0:
			return
		_removed_stock[organ_id] = organ.nutrition


func _on_repair_changed(snapshot: Dictionary) -> void:
	if not _stopped:
		_remember_cost(_repair_costs, snapshot)


func _on_local_growth_changed(snapshot: Dictionary) -> void:
	if not _stopped:
		_remember_cost(_local_growth_costs, snapshot)


func _remember_cost(costs: Dictionary[int, int], snapshot: Dictionary) -> void:
	var task_id: int = int(snapshot.get("task_id", 0))
	if task_id > 0:
		costs[task_id] = maxi(int(costs.get(task_id, 0)), int(snapshot.get("consumed_nutrition", 0)))


func _organs(level: Node) -> Array[AttackOrgan]:
	var organs: Array[AttackOrgan] = []
	for node: Node in level.find_children("*", "", true, false):
		if node is AttackOrgan and _live(node):
			organs.append(node)
	return organs


func _paid_transit(supply: Node) -> int:
	var amount: int = 0
	for shipment: Dictionary in supply.call("get_shipment_records"):
		if bool(shipment.get("debited", false)) and not bool(shipment.get("settled", false)) \
				and not bool(shipment.get("refunded", false)):
			amount += 1
	return amount


func _bind(source: Node, signal_name: StringName, callback: Callable) -> void:
	if is_instance_valid(source) and not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)
		_bindings.append({"source": weakref(source), "signal": signal_name, "callback": callback})


func _level() -> Node:
	return _level_ref.get_ref() as Node if _level_ref != null else null


func _live(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and node.is_inside_tree() and not node.is_queued_for_deletion()


func _sum(values: Dictionary) -> int:
	var total: int = 0
	for amount: Variant in values.values():
		total += int(amount)
	return total


## 死亡事务已停止物流；唯一旧身份只归档一次，不向母核退款。
func record_destroyed_stock(organ: AttackOrgan) -> void:
	if not _stopped and is_instance_valid(organ) and not _removed_stock.has(organ.get_instance_id()) \
		and (_committed_organs.has(organ.get_instance_id()) or bool(organ.get_meta("cultivation_committed", false))):
		_removed_stock[organ.get_instance_id()] = organ.nutrition


func record_destroyed_stomach(organ: DigestiveOrgan, loss: Dictionary) -> void:
	if not _stopped and is_instance_valid(organ) and not _tissue_losses.has(organ.get_instance_id()):
		_tissue_losses[organ.get_instance_id()] = loss.duplicate()


func _on_remains_added(node: Node) -> void:
	if not _stopped and node is EnemyRemains:
		_bind(node, &"decayed", _on_remains_decayed.bind(node.get_instance_id()))


func _on_remains_decayed(nutrition: int, identity: int) -> void:
	if not _stopped and not _decay_losses.has(identity):
		_decay_losses[identity] = maxi(0, nutrition)
