class_name ConstructionSupplyScheduler
extends Node
## 按建造请求轮流申请原供给系统派包；付款、需求占位和结算仍归各自账本。

signal changed(snapshot: Dictionary)

class SupplyRegistration:
	extends RefCounted

	var construction_id: String = ""
	var supply_ref: WeakRef
	var supply_id: int = 0
	var priority: int = 0
	var serial: int = 0

@export var auto_dispatch: bool = true
@export var dispatch_interval: float = 0.35

var _registrations: Dictionary[int, SupplyRegistration] = {}
var _registering: Dictionary[int, bool] = {}
var _order: Array[String] = []
var _next_construction_id: String = ""
var _cursor: int = 0
var _next_registration_serial: int = 1
var _epoch: int = 0
var _round: int = 0
var _elapsed: float = 0.0
var _dispatching: bool = false
var _resetting: bool = false
var _exiting: bool = false
var _emitting_snapshot: bool = false
var _last_dispatch_count: int = 0
var _last_successful_ids: Array[String] = []
var _last_snapshot: Dictionary = {}


func _ready() -> void:
	_emit_changed()


func _process(delta: float) -> void:
	if _exiting or _resetting or _dispatching:
		return
	var attempt_epoch: int = _epoch
	var removed: bool = _prune_registrations(attempt_epoch)
	if attempt_epoch != _epoch or _exiting or _resetting:
		return
	if auto_dispatch:
		_elapsed += maxf(delta, 0.0)
		var interval: float = maxf(dispatch_interval, 0.001)
		if _elapsed >= interval:
			# 一次长帧也只开启一轮，不追补多个已付款包。
			_elapsed = fmod(_elapsed, interval)
			dispatch_round()
	if removed:
		_emit_changed()


func _exit_tree() -> void:
	_exiting = true
	reset()


func register_supply(construction_id: String, supply: Node, priority: int = 0) -> bool:
	if _exiting or _resetting or construction_id.is_empty() or not _has_supply_api(supply):
		return false
	var supply_id: int = supply.get_instance_id()
	var existing: SupplyRegistration = _registrations.get(supply_id)
	if _registering.has(supply_id) \
			or (existing != null and existing.construction_id != construction_id):
		return false
	var attempt_epoch: int = _epoch
	_registering[supply_id] = true
	var claimed: bool = bool(supply.call(&"claim_dispatch_owner", self))
	_registering.erase(supply_id)
	if not claimed:
		return false
	if _exiting or _resetting or attempt_epoch != _epoch or not _is_live_node(supply) \
			or supply.call(&"get_dispatch_owner") != self or attempt_epoch != _epoch \
			or _registrations.get(supply_id) != existing:
		_release_unused_claim(supply)
		return false
	var registration: SupplyRegistration = existing
	if registration == null:
		registration = SupplyRegistration.new()
		registration.construction_id = construction_id
		registration.supply_ref = weakref(supply)
		registration.supply_id = supply_id
		registration.serial = _next_registration_serial
		_next_registration_serial += 1
		_registrations[supply_id] = registration
	registration.priority = priority
	_emit_changed()
	return _registration_is_current(registration, attempt_epoch)


## 分化不占建造队列或生长端；稳定身份沿用通用分组轮转与独占派发。
func register_differentiation_supply(supply: Node) -> bool:
	if not _is_live_node(supply):
		return false
	return register_supply("differentiation:%d" % supply.get_instance_id(), supply, 0)


func unregister_supply(supply: Node) -> void:
	if not is_instance_valid(supply):
		return
	var registration: SupplyRegistration = _registrations.get(supply.get_instance_id())
	if registration == null:
		return
	_detach_registration(registration)
	_emit_changed()


## 未登记的等待请求也保留在目标顺序内，后续登记会沿用这份顺序。
func set_order(construction_ids: Array[String]) -> void:
	if _exiting or _resetting:
		return
	var next_order: Array[String] = []
	for construction_id: String in construction_ids:
		if not construction_id.is_empty() and not next_order.has(construction_id):
			next_order.append(construction_id)
	if next_order != _order:
		_order = next_order
		# 保留下一位请求的身份，调整目标顺序不能反复把游标重置到队首。
		_emit_changed()


func dispatch_round() -> int:
	if _exiting or _resetting or _dispatching or _emitting_snapshot:
		return 0
	_dispatching = true
	var attempt_epoch: int = _epoch
	_prune_registrations(attempt_epoch)
	var construction_ids: Array[String] = _ordered_construction_ids()
	var groups: Dictionary[String, Array] = {}
	for construction_id: String in construction_ids:
		groups[construction_id] = _supplies_for(construction_id)
	var start: int = _start_index(construction_ids)
	var first_success: int = -1
	var successful_ids: Array[String] = []
	if attempt_epoch == _epoch and not _exiting and not _resetting:
		_round += 1
		for offset: int in range(construction_ids.size()):
			if attempt_epoch != _epoch or _exiting or _resetting:
				break
			var index: int = (start + offset) % construction_ids.size()
			var construction_id: String = construction_ids[index]
			# 本轮捕获登记对象；回调内新登记或复用的供给必须等待下一轮。
			for registration: SupplyRegistration in groups[construction_id]:
				if not _registration_is_current(registration, attempt_epoch):
					continue
				var supply: Node = _get_supply(registration)
				if not bool(supply.call(&"can_dispatch_scheduled", self)):
					continue
				if not _registration_is_current(registration, attempt_epoch):
					continue
				var dispatched: bool = bool(supply.call(&"try_dispatch_scheduled", self))
				if attempt_epoch != _epoch or _exiting or _resetting:
					break
				if dispatched:
					successful_ids.append(construction_id)
					if first_success < 0:
						first_success = index
					# 生长和培育共享 construction_id，一次成功就用完本组本轮机会。
					break
	var dispatched_count: int = 0
	if attempt_epoch == _epoch and not _exiting and not _resetting:
		dispatched_count = successful_ids.size()
		_last_dispatch_count = dispatched_count
		_last_successful_ids = successful_ids
		_advance_cursor(construction_ids, first_success if first_success >= 0 else start)
		# changed 的同步回调也在本轮锁内，不能递归开始下一轮。
		_emit_changed()
	_dispatching = false
	return dispatched_count if attempt_epoch == _epoch else 0


func get_snapshot() -> Dictionary:
	var construction_ids: Array[String] = _ordered_construction_ids()
	var cursor: int = _start_index(construction_ids)
	var registrations: Array[Dictionary] = []
	for construction_id: String in construction_ids:
		for registration: SupplyRegistration in _supplies_for(construction_id):
			registrations.append({
				"construction_id": construction_id,
				"supply_id": registration.supply_id,
				"priority": registration.priority,
				"serial": registration.serial,
			})
	return {
		"registrations": registrations,
		"registered_count": registrations.size(),
		"group_count": construction_ids.size(),
		"order": _order.duplicate(),
		"construction_ids": construction_ids,
		"cursor": cursor,
		"next_construction_id": construction_ids[cursor] if not construction_ids.is_empty() else "",
		"round": _round,
		"last_dispatch_count": _last_dispatch_count,
		"last_successful_ids": _last_successful_ids.duplicate(),
	}


## 只解除登记与派发归属，不取消任务、清空账本或改动已经付款的运输。
func reset() -> void:
	if _resetting:
		return
	_resetting = true
	_epoch += 1
	var registrations: Array = _registrations.values()
	_registrations.clear()
	_order.clear()
	_next_construction_id = ""
	_cursor = 0
	_round = 0
	_elapsed = 0.0
	_last_dispatch_count = 0
	_last_successful_ids.clear()
	_last_snapshot = {}
	for registration: SupplyRegistration in registrations:
		var supply: Variant = registration.supply_ref.get_ref()
		if is_instance_valid(supply) and supply is Node:
			supply.call(&"release_dispatch_owner", self)
	# 不解除正在退栈的 dispatch_round 锁，reset 的回调也不能重入派发。
	_resetting = false
	_emit_changed()


func _ordered_construction_ids() -> Array[String]:
	var groups: Dictionary[String, Dictionary] = {}
	for registration: SupplyRegistration in _registrations.values():
		if _get_supply(registration) == null:
			continue
		var construction_id: String = registration.construction_id
		if not groups.has(construction_id):
			groups[construction_id] = {
				"construction_id": construction_id,
				"priority": registration.priority,
				"serial": registration.serial,
			}
		else:
			groups[construction_id]["priority"] = maxi(
				int(groups[construction_id]["priority"]), registration.priority)
			groups[construction_id]["serial"] = mini(
				int(groups[construction_id]["serial"]), registration.serial)
	var construction_ids: Array[String] = []
	for construction_id: String in _order:
		if groups.has(construction_id):
			construction_ids.append(construction_id)
	var remaining: Array[Dictionary] = []
	for construction_id: String in groups:
		if not construction_ids.has(construction_id):
			remaining.append(groups[construction_id])
	remaining.sort_custom(_group_precedes)
	for group: Dictionary in remaining:
		construction_ids.append(String(group["construction_id"]))
	return construction_ids


func _supplies_for(construction_id: String) -> Array[SupplyRegistration]:
	var registrations: Array[SupplyRegistration] = []
	for registration: SupplyRegistration in _registrations.values():
		if registration.construction_id == construction_id and _get_supply(registration) != null:
			registrations.append(registration)
	registrations.sort_custom(_registration_precedes)
	return registrations


func _group_precedes(first: Dictionary, second: Dictionary) -> bool:
	if int(first["priority"]) != int(second["priority"]):
		return int(first["priority"]) > int(second["priority"])
	return int(first["serial"]) < int(second["serial"])


func _registration_precedes(first: SupplyRegistration, second: SupplyRegistration) -> bool:
	if first.priority != second.priority:
		return first.priority > second.priority
	return first.serial < second.serial


func _start_index(construction_ids: Array[String]) -> int:
	if construction_ids.is_empty():
		return 0
	var index: int = construction_ids.find(_next_construction_id)
	return index if index >= 0 else _cursor % construction_ids.size()


func _advance_cursor(round_ids: Array[String], serviced_index: int) -> void:
	var current_ids: Array[String] = _ordered_construction_ids()
	_next_construction_id = ""
	if current_ids.is_empty():
		_cursor = 0
	else:
		_cursor %= current_ids.size()
		_next_construction_id = current_ids[_cursor]
		for offset: int in range(1, round_ids.size() + 1):
			var candidate: String = round_ids[(serviced_index + offset) % round_ids.size()]
			if current_ids.has(candidate):
				_next_construction_id = candidate
				_cursor = current_ids.find(candidate)
				break


func _registration_is_current(registration: SupplyRegistration, attempt_epoch: int) -> bool:
	if _exiting or _resetting or attempt_epoch != _epoch \
			or _registrations.get(registration.supply_id) != registration:
		return false
	var supply: Node = _get_supply(registration)
	if supply == null:
		return false
	var owned: bool = supply.call(&"get_dispatch_owner") == self
	return owned and attempt_epoch == _epoch and not _exiting and not _resetting \
		and _registrations.get(registration.supply_id) == registration and _is_live_node(supply)


func _prune_registrations(attempt_epoch: int) -> bool:
	var removed: bool = false
	for registration: SupplyRegistration in _registrations.values():
		if attempt_epoch != _epoch or _exiting or _resetting:
			break
		if not _registration_is_current(registration, attempt_epoch) and attempt_epoch == _epoch:
			_detach_registration(registration)
			removed = true
	return removed


func _detach_registration(registration: SupplyRegistration) -> void:
	if _registrations.get(registration.supply_id) != registration:
		return
	_registrations.erase(registration.supply_id)
	var supply: Variant = registration.supply_ref.get_ref()
	if is_instance_valid(supply) and supply is Node:
		supply.call(&"release_dispatch_owner", self)


func _release_unused_claim(supply: Node) -> void:
	if is_instance_valid(supply) and not _registrations.has(supply.get_instance_id()):
		supply.call(&"release_dispatch_owner", self)


func _get_supply(registration: SupplyRegistration) -> Node:
	var supply: Variant = registration.supply_ref.get_ref()
	return supply as Node if _is_live_node(supply) else null


func _has_supply_api(supply: Node) -> bool:
	return _is_live_node(supply) and supply.has_method(&"claim_dispatch_owner") \
		and supply.has_method(&"release_dispatch_owner") and supply.has_method(&"get_dispatch_owner") \
		and supply.has_method(&"can_dispatch_scheduled") and supply.has_method(&"try_dispatch_scheduled")


func _is_live_node(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func _emit_changed() -> void:
	if _exiting or _resetting or _emitting_snapshot:
		return
	_emitting_snapshot = true
	var snapshot: Dictionary = get_snapshot()
	if snapshot != _last_snapshot:
		_last_snapshot = snapshot.duplicate(true)
		changed.emit(snapshot)
	_emitting_snapshot = false
