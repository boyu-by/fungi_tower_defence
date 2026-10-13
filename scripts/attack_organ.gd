class_name AttackOrgan
extends Node2D
## 器官管理本地库存、工作状态和外观；暂停不会清空库存或在途预约。

signal inventory_changed(stored: int, incoming: int, capacity: int)
signal selection_requested
signal work_state_changed(enabled: bool)
signal differentiation_changed(snapshot: Dictionary)
signal health_changed(current: float, maximum: float)
signal tissue_destroyed(tissue: Node2D)
signal dormancy_changed(dormant: bool)
signal transplant_state_changed(transplanting: bool)

const STORED_COLOR := Color("f5d577")
const INCOMING_COLOR := Color("8d794a")
const EMPTY_COLOR := Color("3b4b42")
const DORMANCY_DELAY: float = 12.0

## 器官与分化系统共享这一份记录；历史任务只保存不可推进的审计快照。
class DifferentiationRecord:
	extends RefCounted

	var organ_ref: WeakRef
	var host_ref: WeakRef
	var weapon_ref: WeakRef
	var controller_ref: WeakRef
	var target_profile: WeaponProfile
	var task_id: int = 0
	var direction: int = -1
	var state: StringName = &"idle"
	var wait_reason: StringName = &""
	var supply_wait_reason: StringName = &""
	var consumed_nutrition: int = 0
	var buffered_nutrition: int = 0
	var effective_time: float = 0.0
	var stage_paid: bool = false
	var stage_elapsed: float = 0.0
	var completed: bool = false
	var previous_work_enabled: bool = true

	func get_organ() -> AttackOrgan:
		return _get_object(organ_ref) as AttackOrgan

	func get_host() -> HyphaNode:
		return _get_object(host_ref) as HyphaNode

	func get_weapon() -> SporeWeapon:
		return _get_object(weapon_ref) as SporeWeapon

	func get_controller() -> Node:
		return _get_object(controller_ref) as Node

	func is_active() -> bool:
		return state == &"waiting" or state == &"differentiating" or state == &"paused"

	func get_snapshot() -> Dictionary:
		var organ: AttackOrgan = get_organ()
		var host: HyphaNode = get_host()
		var weapon: SporeWeapon = get_weapon()
		if state == &"idle" and _is_live(organ):
			host = organ.get_parent() as HyphaNode
			weapon = organ._find_matching_weapon()
		return {
			"task_id": task_id,
			"organ": organ if _is_live(organ) else null,
			"host": host if _is_live(host) else null,
			"weapon": weapon if _is_live(weapon) else null,
			"direction": direction,
			"state": state,
			"wait_reason": wait_reason,
			"total_cost": 8,
			"consumed_nutrition": consumed_nutrition,
			"buffered_nutrition": buffered_nutrition,
			"remaining_cost": 8 - consumed_nutrition,
			"requested_nutrition": 0,
			"effective_time": effective_time,
			"minimum_time": 5.0,
			"stage_paid": stage_paid,
			"stage_elapsed": stage_elapsed,
			"progress": clampf(effective_time / 5.0, 0.0, 1.0),
			"can_progress": false,
		}

	func _get_object(reference: WeakRef) -> Object:
		if reference == null:
			return null
		var object: Object = reference.get_ref()
		return object if is_instance_valid(object) else null

	func _is_live(node: Variant) -> bool:
		return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion() \
			and node.is_inside_tree() and node.is_node_ready()

@export_range(1, 6, 1) var capacity: int = 6
@export_range(0, 6, 1) var initial_nutrition: int = 4
@export_range(0, 6, 1) var refill_target: int = 3
@export var max_health: float = 60.0:
	set(value):
		if not is_finite(value) or value <= 0.0 or max_health == value:
			return
		max_health = value
		_health = minf(_health, value) if _health_was_changed else value
		health_changed.emit(health, max_health)

var health: float:
	get:
		return _health
var is_dormant: bool:
	get:
		return _dormant
var nutrition: int = 0
var incoming_nutrition: int = 0
var _work_enabled: bool = true
var _volley_inventory_pending: bool = false
var _fire_tween: Tween
var _differentiation_record: DifferentiationRecord
var _health: float = 60.0
var _health_was_changed: bool = false
var _host: HyphaNode
var _last_work_state: bool = true
var _dormant: bool = false
var _enemy_absence_time: float = 0.0
var _transplanting: bool = false
var _inventory_initialized: bool = false

@onready var inventory_slots: HBoxContainer = $InventorySlots
@onready var cap: Polygon2D = $Cap


func _init() -> void:
	_differentiation_record = DifferentiationRecord.new()
	_differentiation_record.organ_ref = weakref(self)


func _ready() -> void:
	rebind_host(get_parent() as HyphaNode)
	if not _inventory_initialized:
		_inventory_initialized = true
		nutrition = clampi(initial_nutrition, 0, capacity)
	_update_inventory()
	_publish_work_state()
	_update_closed_visual()


func _physics_process(delta: float) -> void:
	advance_dormancy(delta)


func _enter_tree() -> void:
	add_to_group("colony_tissues")


func _exit_tree() -> void:
	if is_instance_valid(_host) and _host.health_changed.is_connected(_on_host_health_changed):
		_host.health_changed.disconnect(_on_host_health_changed)
	_host = null


func _on_host_health_changed(_current: float, _maximum: float) -> void:
	_publish_work_state()


func is_attackable() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func is_functional() -> bool:
	return is_work_enabled()


func is_repairable() -> bool:
	return is_attackable() and health < max_health


func take_damage(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or not is_attackable():
		return 0.0
	var actual: float = minf(amount, health)
	_health = maxf(health - actual, 0.0)
	_health_was_changed = true
	var destroyed: bool = health <= 0.0
	if destroyed and _fire_tween != null and _fire_tween.is_valid():
		_fire_tween.kill()
	_publish_work_state()
	if destroyed and is_instance_valid(self):
		# 本地实物和在途预留仍在，由生命周期监听者捕获后结算。
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


func _host_is_functional() -> bool:
	var host: HyphaNode = get_parent() as HyphaNode
	return host == null or host.is_functional()


func _publish_work_state() -> void:
	var current: bool = is_work_enabled()
	if _last_work_state != current:
		_last_work_state = current
		work_state_changed.emit(current)


func needs_supply() -> bool:
	return is_functional() and nutrition + incoming_nutrition < clampi(refill_target, 0, capacity)


func reserve_nutrition(amount: int) -> bool:
	if not is_attackable() or not _host_is_functional() or _dormant or _transplanting or amount <= 0 \
			or nutrition + incoming_nutrition + amount > capacity:
		return false

	incoming_nutrition += amount
	_update_inventory()
	return true


func complete_delivery(amount: int) -> bool:
	if not is_attackable() or not _host_is_functional() or amount <= 0 \
			or incoming_nutrition < amount or nutrition + amount > capacity:
		return false

	incoming_nutrition -= amount
	nutrition += amount
	_update_inventory()
	return true


func cancel_reservation(amount: int) -> bool:
	if amount <= 0 or incoming_nutrition < amount:
		return false

	incoming_nutrition -= amount
	_update_inventory()
	return true


func consume_nutrition(amount: int = 1) -> bool:
	if not is_functional() or amount <= 0 or nutrition < amount:
		return false

	nutrition -= amount
	_update_inventory()
	return true


func get_shot_nutrition_cost() -> int:
	var weapon := _find_matching_weapon()
	if weapon != null:
		return weapon.get_nutrition_cost()
	return SporeWeapon.SHOT_NUTRITION


func set_work_enabled(value: bool) -> void:
	if _work_enabled == value or (value and _differentiation_record.is_active()):
		return
	_work_enabled = value
	_publish_work_state()


func is_work_enabled() -> bool:
	return _work_enabled and not _dormant and not _transplanting \
		and is_attackable() and _host_is_functional()


## 缺弹、停工、分化和伤害预约均不代表敌人消失。
func advance_dormancy(delta: float) -> void:
	if not is_inside_tree() or not is_attackable() or not is_finite(delta) or delta < 0.0:
		return
	var weapon: SporeWeapon = _find_matching_weapon()
	if weapon == null:
		return
	if weapon.has_live_enemy_in_range():
		_enemy_absence_time = 0.0
		_set_dormant(false)
	else:
		_enemy_absence_time = minf(DORMANCY_DELAY, _enemy_absence_time + delta)
		if _enemy_absence_time >= DORMANCY_DELAY:
			_set_dormant(true)


func get_dormancy_snapshot() -> Dictionary:
	return {"is_dormant": _dormant, "absence_time": _enemy_absence_time,
		"delay": DORMANCY_DELAY, "is_transplanting": _transplanting}


func is_transplanting() -> bool:
	return _transplanting


## 移植门控不改写玩家停工意图、库存或同一份分化记录。
func set_transplanting(value: bool) -> void:
	if _transplanting == value:
		return
	_transplanting = value
	set_meta("is_transplanting", value)
	_publish_work_state()
	_update_closed_visual()
	transplant_state_changed.emit(value)


## reparent 不会再次执行 _ready；宿主监听和历史记录需要显式交接。
func rebind_host(host: HyphaNode) -> void:
	if is_instance_valid(_host) and _host.health_changed.is_connected(_on_host_health_changed):
		_host.health_changed.disconnect(_on_host_health_changed)
	_host = host
	if is_instance_valid(_host) and not _host.health_changed.is_connected(_on_host_health_changed):
		_host.health_changed.connect(_on_host_health_changed)
	_differentiation_record.host_ref = weakref(host) if is_instance_valid(host) else null
	var weapon: SporeWeapon = _find_matching_weapon()
	_differentiation_record.weapon_ref = weakref(weapon) if is_instance_valid(weapon) else null
	_publish_work_state()


func get_requested_work_enabled() -> bool:
	return _work_enabled


func get_differentiation_snapshot() -> Dictionary:
	var controller: Node = _differentiation_record.get_controller()
	if is_instance_valid(controller) and controller.has_method("get_organ_snapshot"):
		return controller.get_organ_snapshot(self)
	return _differentiation_record.get_snapshot()


func get_attack_type() -> int:
	var weapon: SporeWeapon = _find_matching_weapon()
	if weapon == null:
		return int(WeaponProfile.DamageType.NORMAL)
	var profile: WeaponProfile = weapon.get_weapon_profile()
	return int(profile.damage_type) if profile != null else int(WeaponProfile.DamageType.NORMAL)


func has_completed_differentiation() -> bool:
	return _differentiation_record.completed


## 内部共享句柄，不复制或另存累计付款、方向与阶段进度。
func _get_differentiation_record() -> DifferentiationRecord:
	return _differentiation_record


func is_combat_active() -> bool:
	if not is_functional() or not is_inside_tree() or not is_node_ready() \
			or is_queued_for_deletion() or not can_process():
		return false
	var weapon := _find_matching_weapon()
	# 没有武器的旧库存夹具仍按器官自身的工作状态供养。
	if weapon == null:
		return true
	return weapon.is_inside_tree() and weapon.is_node_ready() and weapon.can_process() \
			and weapon.is_firing_enabled() and weapon.has_valid_profile()


func play_fire_feedback() -> void:
	if _fire_tween != null and _fire_tween.is_valid():
		_fire_tween.kill()
	cap.scale = Vector2(1.12, 0.9)
	_fire_tween = create_tween()
	_fire_tween.tween_property(cap, "scale", Vector2.ONE, 0.18)


func _set_dormant(value: bool) -> void:
	if _dormant == value:
		return
	_dormant = value
	_publish_work_state()
	_update_closed_visual()
	dormancy_changed.emit(value)


func _update_closed_visual() -> void:
	var closed: bool = _dormant or _transplanting
	modulate.a = 0.55 if closed else 1.0
	var cap_node: Polygon2D = get_node_or_null("Cap") as Polygon2D
	if cap_node != null:
		if _fire_tween != null and _fire_tween.is_valid():
			_fire_tween.kill()
		cap_node.scale = Vector2(0.65, 0.55) if closed else Vector2.ONE
	var highlight: Polygon2D = get_node_or_null("CapHighlight") as Polygon2D
	if highlight != null:
		highlight.scale = Vector2(0.65, 0.55) if closed else Vector2.ONE


## 仅供武器齐射事务使用：扣费不发布信号，避免观察到一轮中的部分弹丸。
func _consume_volley_nutrition(amount: int) -> bool:
	if not is_functional() or _volley_inventory_pending or amount <= 0 or nutrition < amount:
		return false
	nutrition -= amount
	_volley_inventory_pending = true
	return true


## 武器先发布齐射账目，再统一刷新库存；清除标志后才进入公开回调。
func _publish_volley_inventory() -> void:
	if not _volley_inventory_pending:
		return
	_volley_inventory_pending = false
	_update_inventory()


func _find_matching_weapon() -> SporeWeapon:
	var host := get_parent()
	if host == null:
		return null
	for child: Node in host.get_children():
		if child is SporeWeapon and not child.is_queued_for_deletion() \
				and child.inventory_owner == self:
			return child as SporeWeapon
	return null


func _update_inventory() -> void:
	for index in range(inventory_slots.get_child_count()):
		var slot := inventory_slots.get_child(index) as ColorRect
		slot.visible = index < capacity
		if index < nutrition:
			slot.color = STORED_COLOR
		elif index < nutrition + incoming_nutrition:
			slot.color = INCOMING_COLOR
		else:
			slot.color = EMPTY_COLOR
	inventory_changed.emit(nutrition, incoming_nutrition, capacity)


func _on_hit_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			selection_requested.emit()
			get_viewport().set_input_as_handled()
