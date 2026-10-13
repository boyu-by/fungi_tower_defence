class_name TissueLifecycle
extends Node
## 关卡的组织销毁事务：先退役旧任务/物流，再记损耗，最后释放原对象。

signal tissue_lost(tissue_id: int, kind: StringName, position: Vector2)

var _level: Node
var _settled: Dictionary[int, bool] = {}
var _watched: Dictionary[int, bool] = {}


func configure(level: Node) -> void:
	_level = level
	get_tree().node_added.connect(_on_node_added)
	for node: Node in level.find_children("*", "", true, false):
		_watch(node)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if is_instance_valid(_level) and _level.is_ancestor_of(node):
		_watch(node)
		if node is DigestiveOrgan:
			_bind_new_stomach.call_deferred(weakref(node))


func _watch(node: Node) -> void:
	if not node.has_signal("tissue_destroyed") or _watched.has(node.get_instance_id()):
		return
	_watched[node.get_instance_id()] = true
	node.connect("tissue_destroyed", _on_tissue_destroyed)


func _on_tissue_destroyed(tissue: Node2D) -> void:
	if not is_instance_valid(_level) or bool(_level.get("_is_tearing_down")):
		return
	# 枯结与断丝保留身份；它们每次从存活跨越零生命均可再次报告。
	if tissue is HyphaNode or tissue is HyphaEdge or tissue is MotherCore:
		var point: Vector2 = tissue.get_point_at(0.5) if tissue is HyphaEdge else tissue.global_position
		tissue_lost.emit(tissue.get_instance_id(), _kind(tissue), point)
		return
	var identity: int = tissue.get_instance_id()
	if _settled.has(identity):
		return
	_settled[identity] = true
	var position: Vector2 = tissue.global_position
	var ledger: CombatResourceLedger = _level.get("combat_resource_ledger") as CombatResourceLedger \
		if _level.has_method("get_combat_resource_snapshot") else null
	if tissue is AttackOrgan:
		var organ: AttackOrgan = tissue as AttackOrgan
		var transplant: Node = _level.get_node_or_null("Systems/TransplantSystem")
		if is_instance_valid(transplant):
			transplant.abort_destroyed_organ(organ)
		(_level.get("differentiation_system") as DifferentiationSystem).abort_destroyed_organ(organ)
		(_level.get("supply_system") as SupplySystem).unregister_organ(organ)
		if is_instance_valid(ledger):
			ledger.record_destroyed_stock(organ)
		organ.nutrition = 0
		for child: Node in organ.get_parent().get_children():
			if child is SporeWeapon and child.inventory_owner == organ:
				child.set_firing_enabled(false)
				child.queue_free()
	elif tissue is DigestiveOrgan:
		var stomach: DigestiveOrgan = tissue as DigestiveOrgan
		(_level.get("nutrition_return_system") as NutritionReturnSystem).cancel_source(stomach)
		(_level.get("recycling_system") as RecyclingSystem).cancel_receiver(stomach)
		(_level.get("nutrition_return_system") as NutritionReturnSystem).unregister_digestive(stomach)
		(_level.get("recycling_system") as RecyclingSystem).unregister_digestive(stomach)
		var loss: Dictionary = stomach.clear_destroyed_inventory()
		if is_instance_valid(ledger):
			ledger.record_destroyed_stomach(stomach, loss)
		stomach.get_parent().set_meta("rebuild_digestive", true)
		if _level.get("digestive_organ") == stomach:
			_level.set("digestive_organ", null)
			(_level.get("nutrition_return_system") as NutritionReturnSystem).digestive_organ = null
			(_level.get("recycling_system") as RecyclingSystem).digestive_organ = null
	elif tissue is OrganBud or tissue is GrowthTip:
		for system: Node in _level.find_children("*", "", true, false):
			if tissue is OrganBud and system is CultivationSystem:
				system.abort_destroyed_bud(tissue as OrganBud)
			elif tissue is GrowthTip and system is GrowthSystem:
				system.abort_destroyed_tip(tissue as GrowthTip)
	if is_instance_valid(tissue) and not tissue.is_queued_for_deletion():
		tissue.queue_free()
	tissue_lost.emit(identity, _kind(tissue), position)
	var hud: ColonyHUD = _level.get("hud") as ColonyHUD
	hud.show_notice("%s被毁：已投入结构保留；空菌结按 C 重新付费培育" % _kind(tissue))


func _bind_new_stomach(reference: WeakRef) -> void:
	var stomach: DigestiveOrgan = reference.get_ref() as DigestiveOrgan
	if not is_instance_valid(stomach) or stomach.is_queued_for_deletion() \
			or not stomach.is_attackable() or not is_instance_valid(_level) or bool(_level.get("_is_tearing_down")):
		return
	_level.call("_register_digestive_capabilities", stomach)
	if not is_instance_valid(_level.get("digestive_organ")):
		_level.set("digestive_organ", stomach)
	var hud: ColonyHUD = _level.get("hud") as ColonyHUD
	hud.show_notice("胃囊付费长成：8结构、空输入与产物，已加入统一回收和绿色回流")


func _kind(tissue: Node) -> StringName:
	if tissue is HyphaNode:
		return &"菌结"
	if tissue is HyphaEdge:
		return &"菌丝"
	if tissue is OrganBud:
		return &"幼芽"
	if tissue is GrowthTip:
		return &"尖端"
	if tissue is DigestiveOrgan:
		return &"胃囊"
	return &"攻击器官" if tissue is AttackOrgan else &"母核"
