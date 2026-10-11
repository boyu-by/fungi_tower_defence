class_name MotherCore
extends Node2D

## 母核管理生命值和可用营养。所有余额变化经过这里结算。

signal health_changed(current: int, maximum: int)
signal nutrition_changed(current: int)
signal budget_changed(snapshot: Dictionary)
signal digestion_product_arrived(product_id: String, nutrition: int)
signal depleted

@export var max_health: int = 240
@export var initial_nutrition: int = 72

var health: int = 0
var nutrition: int = 0
var _received_products: Dictionary[String, int] = {}
# 这里只记录需求；funded 每次从真实余额推导，绝不成为另一份库存。
var _nutrition_reservations: Dictionary[String, int] = {}
var _notifying_budget: bool = false
var _budget_dirty: bool = false
var _nutrition_dirty: bool = false

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	health = max_health
	nutrition = maxi(initial_nutrition, 0)
	health_bar.max_value = max_health
	_update_health_bar()


func take_damage(amount: int) -> void:
	if amount <= 0 or health <= 0:
		return

	health = maxi(health - amount, 0)
	_update_health_bar()
	health_changed.emit(health, max_health)

	if health == 0:
		depleted.emit()


func try_spend_nutrition(amount: int) -> bool:
	if amount <= 0 or get_spendable_nutrition() < amount or health <= 0 \
			or is_queued_for_deletion():
		return false

	nutrition -= amount
	_notify_budget(true)
	return true


func add_nutrition(amount: int) -> void:
	if amount <= 0 or amount > 9223372036854775807 - maxi(nutrition, 0):
		return

	nutrition = maxi(nutrition, 0) + amount
	_notify_budget(true)


## 调整未付款目标，返回当前真实 funded。零目标只解锁，不增加余额。
func set_nutrition_reservation(key: String, desired: int) -> int:
	if key.is_empty():
		return 0
	if desired <= 0:
		release_nutrition_reservation(key)
	elif int(_nutrition_reservations.get(key, 0)) != desired:
		_nutrition_reservations[key] = desired
		_notify_budget(false)
	return get_nutrition_reservation(key)


func get_nutrition_reservation(key: String) -> int:
	var available: int = maxi(nutrition, 0)
	for reservation_key: String in _nutrition_reservations:
		var funded: int = mini(_nutrition_reservations[reservation_key], available)
		if reservation_key == key:
			return funded
		available -= funded
	return 0


func release_nutrition_reservation(key: String) -> int:
	if not _nutrition_reservations.has(key):
		return 0
	var unlocked: int = get_nutrition_reservation(key)
	_nutrition_reservations.erase(key)
	_notify_budget(false)
	return unlocked


## 同时提交扣款和目标减少，再通知观察者；同步取消不能重复锁定刚付款的一单位。
func try_spend_reserved_nutrition(key: String, amount: int) -> bool:
	if amount <= 0 or health <= 0 or is_queued_for_deletion() \
			or get_nutrition_reservation(key) < amount:
		return false
	var remaining_goal: int = _nutrition_reservations[key] - amount
	if remaining_goal == 0:
		_nutrition_reservations.erase(key)
	else:
		_nutrition_reservations[key] = remaining_goal
	nutrition -= amount
	_notify_budget(true)
	return true


func get_spendable_nutrition() -> int:
	var available: int = maxi(nutrition, 0)
	for desired: int in _nutrition_reservations.values():
		available -= mini(desired, available)
	return available


func get_budget_snapshot() -> Dictionary:
	var balance: int = maxi(nutrition, 0)
	var available: int = balance
	var reservations: Array[Dictionary] = []
	for key: String in _nutrition_reservations:
		var desired: int = _nutrition_reservations[key]
		var funded: int = mini(desired, available)
		available -= funded
		reservations.append({"key": key, "desired": desired, "funded": funded})
	return {
		"balance": balance, "reserved": balance - available,
		"spendable": available, "reservations": reservations,
	}


## 仅由真实回流包的到达结算调用；退款、初始余额与内部转运仍使用原接口。
func accept_digestion_product(product_id: String, amount: int) -> bool:
	if product_id.is_empty() or amount <= 0 or health <= 0 or is_queued_for_deletion():
		return false
	if _received_products.has(product_id) or amount > 9223372036854775807 - maxi(nutrition, 0):
		return false
	# 在任何余额回调之前登记收件，回调内重放同一到达也不能重复入账。
	_received_products[product_id] = amount
	nutrition = maxi(nutrition, 0) + amount
	_notify_budget(true)
	if is_instance_valid(self):
		digestion_product_arrived.emit(product_id, amount)
	return true


func has_received_product(product_id: String) -> bool:
	return _received_products.has(product_id)


func get_received_product_count() -> int:
	return _received_products.size()


func _notify_budget(nutrition_changed_now: bool) -> void:
	_budget_dirty = true
	_nutrition_dirty = _nutrition_dirty or nutrition_changed_now
	if _notifying_budget:
		return
	_notifying_budget = true
	while _budget_dirty or _nutrition_dirty:
		var emit_nutrition: bool = _nutrition_dirty
		_budget_dirty = false
		_nutrition_dirty = false
		# 所有锁已由余额推导完成；先到的普通买家也只能消费 spendable。
		budget_changed.emit(get_budget_snapshot())
		if emit_nutrition:
			nutrition_changed.emit(nutrition)
	_notifying_budget = false


func _update_health_bar() -> void:
	health_bar.value = health
