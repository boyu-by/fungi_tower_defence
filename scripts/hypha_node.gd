class_name HyphaNode
extends Node2D

signal selection_requested(node: HyphaNode)
signal organ_slot_changed
signal health_changed(current: float, maximum: float)
signal tissue_destroyed(tissue: Node2D)

@export var display_name: String = "菌结"
@export var max_health: float = 45.0:
	set(value):
		if not is_finite(value) or value <= 0.0 or max_health == value:
			return
		max_health = value
		_health = minf(_health, value) if _health_was_changed else value
		health_changed.emit(health, max_health)

var health: float:
	get:
		return _health

var _health: float = 45.0
var _health_was_changed: bool = false
var _reservation_id: String = ""
var _reservation_replacing: Node = null
var _used_reservations: Dictionary[String, bool] = {}
var _committed_occupant: Node = null

@onready var selection_ring: Line2D = $SelectionRing


func _init() -> void:
	# 树外手动放置的器官同样占位，不要求先向某个系统登记。
	child_order_changed.connect(_on_child_order_changed)


func _enter_tree() -> void:
	add_to_group("colony_tissues")


func is_attackable() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func is_functional() -> bool:
	return is_attackable()


func is_repairable() -> bool:
	return health < max_health and not is_queued_for_deletion()


func take_damage(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or not is_attackable():
		return 0.0
	var actual: float = minf(amount, health)
	_health = maxf(health - actual, 0.0)
	_health_was_changed = true
	# 菌结保留身份和端点；邻接器官通过生命通知暂停，不改写其工作意图。
	if health <= 0.0:
		tissue_destroyed.emit(self)
	if is_instance_valid(self) and not is_queued_for_deletion():
		health_changed.emit(health, max_health)
	return actual


func heal(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or not is_repairable():
		return 0.0
	var actual: float = minf(amount, max_health - health)
	_health = minf(health + actual, max_health)
	_health_was_changed = true
	health_changed.emit(health, max_health)
	return actual


func get_health_snapshot() -> Dictionary:
	return {
		"health": health, "max_health": max_health,
		"destroyed": health <= 0.0, "functional": is_functional(),
		"missing_health": maxf(max_health - health, 0.0), "damaged": health < max_health,
	}


func _on_child_order_changed() -> void:
	organ_slot_changed.emit()


func _on_hit_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			selection_requested.emit(self)
			get_viewport().set_input_as_handled()


func set_selected(is_selected: bool) -> void:
	if is_instance_valid(selection_ring):
		selection_ring.visible = is_selected


func get_organ_occupant() -> Node:
	if _is_slot_child(_committed_occupant):
		return _committed_occupant
	var occupants: Array[Node] = _get_organ_children()
	return occupants[0] if not occupants.is_empty() else null


func get_organ_bud() -> OrganBud:
	return get_organ_occupant() as OrganBud


func get_organ_slot_state() -> StringName:
	if not _reservation_id.is_empty():
		return &"reserved"
	var occupant: Node = get_organ_occupant()
	if occupant is AttackOrgan:
		return &"attack"
	if occupant is DigestiveOrgan:
		return &"digestive"
	if occupant is OrganBud:
		return &"bud"
	return &"empty"


func is_organ_slot_available() -> bool:
	return not is_queued_for_deletion() and _reservation_id.is_empty() \
		and _get_organ_children().is_empty()


func try_reserve_organ_slot(reservation_id: String, replacing: Node = null) -> bool:
	if reservation_id.is_empty() or _used_reservations.has(reservation_id) \
		or not _reservation_id.is_empty() or is_queued_for_deletion():
		return false
	var occupants: Array[Node] = _get_organ_children()
	if replacing == null and not occupants.is_empty():
		return false
	if replacing != null and (not replacing is OrganBud or not _is_slot_child(replacing) \
			or occupants.size() != 1 or occupants[0] != replacing):
		return false

	_used_reservations[reservation_id] = true
	_reservation_id = reservation_id
	_reservation_replacing = replacing
	organ_slot_changed.emit()
	return true


func commit_organ_slot(reservation_id: String, occupant: Node) -> bool:
	if reservation_id.is_empty() or reservation_id != _reservation_id \
		or is_queued_for_deletion() or not _is_slot_child(occupant):
		return false
	var occupants: Array[Node] = _get_organ_children()
	if _reservation_replacing == null and (occupants.size() != 1 or occupants[0] != occupant):
		return false
	if _reservation_replacing != null:
		if not _is_slot_child(_reservation_replacing) or not _reservation_replacing is OrganBud \
				or not (occupant is AttackOrgan or occupant is DigestiveOrgan) or occupants.size() != 2:
			return false
		if not occupants.has(_reservation_replacing) or not occupants.has(occupant):
			return false

	_committed_occupant = occupant
	_reservation_id = ""
	_reservation_replacing = null
	organ_slot_changed.emit()
	return true


func release_organ_slot(reservation_id: String) -> bool:
	if reservation_id.is_empty() or reservation_id != _reservation_id:
		return false
	_reservation_id = ""
	_reservation_replacing = null
	organ_slot_changed.emit()
	return true


func _is_slot_child(node: Variant) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion() \
		and node.get_parent() == self \
		and (node is AttackOrgan or node is DigestiveOrgan or node is OrganBud)


func _get_organ_children() -> Array[Node]:
	var occupants: Array[Node] = []
	for child: Node in get_children():
		if _is_slot_child(child):
			occupants.append(child)
	return occupants
