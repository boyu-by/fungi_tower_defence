class_name CombatTargetingSystem
extends Node
## 预备与已提交弹丸共用的伤害承诺；只记账，不改血量、库存或尸体。

const PREPARED: StringName = &"prepared"
const COMMITTED: StringName = &"committed"

var _generation: int = 1
var _serial: int = 0
var _watch_serial: int = 0
var _accepting: bool = true
var _commitments: Dictionary[String, Dictionary] = {}
var _target_watches: Dictionary[int, Dictionary] = {}
var _owner_watches: Dictionary[int, Dictionary] = {}


func _exit_tree() -> void:
	stop()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop()


func prepare_commitment(target: BasicEnemy, request: Dictionary, owner: Node) -> String:
	if not is_accepting() or not _is_target_available(target) or not _is_live_node(owner) \
			or not WeaponProfile.is_valid_damage_request(request):
		return ""
	if get_remaining_health(target) <= 0:
		return ""
	_serial += 1
	var id := "%d:%d:%d" % [get_instance_id(), _generation, _serial]
	# 在调用方实例化、发射或挂树之前，其他武器已经能看见这份覆盖。
	_commitments[id] = {
		"id": id,
		"generation": _generation,
		"target_id": target.get_instance_id(),
		"owner_id": owner.get_instance_id(),
		"projectile_id": 0,
		"raw_damage": int(request["raw_damage"]),
		"damage_type": int(request["damage_type"]),
		"state": PREPARED,
		"target_ref": weakref(target),
		"owner_ref": weakref(owner),
		"projectile_ref": null,
	}
	_watch_target(target, id)
	_watch_prepared_owner(owner, id)
	return id


func get_incoming_damage(target: BasicEnemy,
		ignored_ids: PackedStringArray = PackedStringArray()) -> int:
	_purge_stale()
	if not _is_target_available(target):
		return 0
	var incoming: int = 0
	var target_id := target.get_instance_id()
	for id: String in _commitments:
		var record: Dictionary = _commitments[id]
		if int(record["target_id"]) == target_id and not ignored_ids.has(id):
			incoming += _expected_damage(record, target)
	return incoming


func get_remaining_health(target: BasicEnemy,
		ignored_ids: PackedStringArray = PackedStringArray()) -> int:
	var incoming := get_incoming_damage(target, ignored_ids)
	return maxi(0, target.health - incoming) if _is_target_available(target) else 0


func get_commitment(id: String) -> Dictionary:
	_purge_stale()
	if not _commitments.has(id):
		return {}
	return _snapshot_record(_commitments[id])


func is_commitment_live(id: String) -> bool:
	_purge_stale()
	return _commitments.has(id)


func is_commitment_committed(id: String) -> bool:
	_purge_stale()
	return _commitments.has(id) and _commitments[id]["state"] == COMMITTED


func commit_batch(ids: PackedStringArray) -> bool:
	if ids.is_empty() or not is_accepting():
		return false
	_purge_stale()
	var seen: Dictionary[String, bool] = {}
	for id: String in ids:
		if seen.has(id) or not _commitments.has(id):
			return false
		seen[id] = true
		var record: Dictionary = _commitments[id]
		if record["state"] != PREPARED or int(record["generation"]) != _generation \
				or not _is_record_live(record) or not _projectile_matches(record, true):
			return false
	# 整批校验后仅更新内部标量；没有弹丸、库存或战斗通知回调。
	for id: String in ids:
		_commitments[id]["state"] = COMMITTED
	for id: String in ids:
		_disconnect_prepared_owner(_commitments[id])
	return true


func release_commitment(id: String) -> bool:
	if not _commitments.has(id):
		return false
	var record: Dictionary = _commitments[id]
	_commitments.erase(id)
	_unwatch_target(record)
	_disconnect_prepared_owner(record)
	return true


func get_snapshot() -> Dictionary:
	_purge_stale()
	var entries: Array[Dictionary] = []
	var prepared_count: int = 0
	var committed_count: int = 0
	var total_expected_damage: int = 0
	for id: String in _commitments:
		var entry := _snapshot_record(_commitments[id])
		entries.append(entry)
		total_expected_damage += int(entry["expected_damage"])
		if entry["state"] == PREPARED:
			prepared_count += 1
		else:
			committed_count += 1
	return {
		"generation": _generation,
		"accepting": is_accepting(),
		"prepared_count": prepared_count,
		"committed_count": committed_count,
		"total_count": entries.size(),
		"total_expected_damage": total_expected_damage,
		"commitments": entries,
	}


func reset() -> void:
	_clear_and_cancel(true)


func stop() -> void:
	_clear_and_cancel(false)


func is_accepting() -> bool:
	return _accepting and not is_queued_for_deletion()


## 弹丸发射后、挂树前的一对一绑定入口；不允许替换已绑定的弹丸。
func _bind_projectile(id: String, projectile: SporeProjectile) -> bool:
	_purge_stale()
	if not is_accepting() or not _commitments.has(id) or not is_instance_valid(projectile) \
			or projectile.is_queued_for_deletion() or not projectile._launched or projectile._finished \
			or not projectile.get_damage_commitment_id().is_empty():
		return false
	var record: Dictionary = _commitments[id]
	if record["state"] != PREPARED or int(record["generation"]) != _generation \
			or int(record["projectile_id"]) != 0 or projectile.target != _get_target(record) \
			or projectile._raw_damage != int(record["raw_damage"]) \
			or projectile._damage_type != int(record["damage_type"]):
		return false
	record["projectile_ref"] = weakref(projectile)
	record["projectile_id"] = projectile.get_instance_id()
	return true


func _on_target_died(_target: BasicEnemy, target_id: int, token: String) -> void:
	_release_target_commitments(target_id, token)


func _on_target_exiting(target_id: int, token: String) -> void:
	_release_target_commitments(target_id, token)


func _on_prepared_owner_exiting(owner_id: int, token: String) -> void:
	if not _owner_watches.has(owner_id) or _owner_watches[owner_id]["token"] != token:
		return
	var ids: Dictionary = _owner_watches[owner_id]["ids"]
	for id: String in ids.keys():
		if _commitments.has(id) and _commitments[id]["state"] == PREPARED:
			release_commitment(id)


func _is_live_node(node: Node) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion() and node.is_inside_tree()


func _is_target_available(target: BasicEnemy) -> bool:
	return _is_live_node(target) and target.is_alive()


func _get_target(record: Dictionary) -> BasicEnemy:
	var ref: WeakRef = record["target_ref"]
	var object: Object = ref.get_ref()
	return object as BasicEnemy if is_instance_valid(object) else null


func _get_owner(record: Dictionary) -> Node:
	var ref: WeakRef = record["owner_ref"]
	var object: Object = ref.get_ref()
	return object as Node if is_instance_valid(object) else null


func _get_projectile(record: Dictionary) -> SporeProjectile:
	var ref: WeakRef = record["projectile_ref"]
	if ref == null:
		return null
	var object: Object = ref.get_ref()
	return object as SporeProjectile if is_instance_valid(object) else null


func _is_record_live(record: Dictionary) -> bool:
	if int(record["generation"]) != _generation or not _is_target_available(_get_target(record)):
		return false
	if record["state"] == PREPARED and not _is_live_node(_get_owner(record)):
		return false
	if int(record["projectile_id"]) != 0:
		return _projectile_matches(record, record["state"] == COMMITTED)
	return record["state"] == PREPARED


func _projectile_matches(record: Dictionary, require_tree: bool) -> bool:
	var projectile := _get_projectile(record)
	if not is_instance_valid(projectile) or projectile.is_queued_for_deletion() \
			or not projectile._launched or (projectile._finished and not projectile._settling_damage):
		return false
	if require_tree and (not projectile.is_inside_tree() or not projectile.is_node_ready()):
		return false
	var system_ref: WeakRef = projectile._damage_commitment_system_ref
	return system_ref != null and system_ref.get_ref() == self \
			and projectile.get_damage_commitment_id() == String(record["id"]) \
			and projectile.target == _get_target(record) \
			and projectile._raw_damage == int(record["raw_damage"]) \
			and projectile._damage_type == int(record["damage_type"])


func _expected_damage(record: Dictionary, target: BasicEnemy) -> int:
	return target.estimate_damage({
		"raw_damage": int(record["raw_damage"]),
		"damage_type": int(record["damage_type"]),
	}) if _is_target_available(target) else 0


func _snapshot_record(record: Dictionary) -> Dictionary:
	return {
		"id": String(record["id"]),
		"generation": int(record["generation"]),
		"target_id": int(record["target_id"]),
		"owner_id": int(record["owner_id"]),
		"projectile_id": int(record["projectile_id"]),
		"raw_damage": int(record["raw_damage"]),
		"damage_type": int(record["damage_type"]),
		"expected_damage": _expected_damage(record, _get_target(record)),
		"state": StringName(record["state"]),
	}


func _disconnect_prepared_owner(record: Dictionary) -> void:
	var owner_id: int = record["owner_id"]
	if not _owner_watches.has(owner_id):
		return
	var watch: Dictionary = _owner_watches[owner_id]
	var ids: Dictionary = watch["ids"]
	ids.erase(String(record["id"]))
	if ids.is_empty():
		_owner_watches.erase(owner_id)
		var ref: WeakRef = watch["owner_ref"]
		var object: Object = ref.get_ref()
		if is_instance_valid(object):
			var owner := object as Node
			var callback: Callable = watch["exit_callback"]
			if owner.tree_exiting.is_connected(callback):
				owner.tree_exiting.disconnect(callback)


func _watch_prepared_owner(owner: Node, id: String) -> void:
	var owner_id := owner.get_instance_id()
	if _owner_watches.has(owner_id):
		var existing_ids: Dictionary = _owner_watches[owner_id]["ids"]
		existing_ids[id] = true
	else:
		var token := _next_watch_token()
		var callback := _on_prepared_owner_exiting.bind(owner_id, token)
		_owner_watches[owner_id] = {
			"owner_ref": weakref(owner),
			"ids": {id: true},
			"token": token,
			"exit_callback": callback,
		}
		owner.tree_exiting.connect(callback)


func _watch_target(target: BasicEnemy, id: String) -> void:
	var target_id := target.get_instance_id()
	if _target_watches.has(target_id):
		var existing_ids: Dictionary = _target_watches[target_id]["ids"]
		existing_ids[id] = true
	else:
		var token := _next_watch_token()
		var died_callback := _on_target_died.bind(target_id, token)
		var exit_callback := _on_target_exiting.bind(target_id, token)
		_target_watches[target_id] = {
			"target_ref": weakref(target),
			"ids": {id: true},
			"token": token,
			"died_callback": died_callback,
			"exit_callback": exit_callback,
		}
		target.died.connect(died_callback)
		target.tree_exiting.connect(exit_callback)


func _unwatch_target(record: Dictionary) -> void:
	var target_id: int = record["target_id"]
	if not _target_watches.has(target_id):
		return
	var watch: Dictionary = _target_watches[target_id]
	var ids: Dictionary = watch["ids"]
	ids.erase(String(record["id"]))
	if ids.is_empty():
		_target_watches.erase(target_id)
		var ref: WeakRef = watch["target_ref"]
		var object: Object = ref.get_ref()
		if is_instance_valid(object):
			var target := object as BasicEnemy
			var died_callback: Callable = watch["died_callback"]
			var exit_callback: Callable = watch["exit_callback"]
			if target.died.is_connected(died_callback):
				target.died.disconnect(died_callback)
			if target.tree_exiting.is_connected(exit_callback):
				target.tree_exiting.disconnect(exit_callback)


func _release_target_commitments(target_id: int, token: String) -> void:
	if not _target_watches.has(target_id) or _target_watches[target_id]["token"] != token:
		return
	var ids: Dictionary = _target_watches[target_id]["ids"]
	for id: String in ids.keys():
		release_commitment(id)


func _next_watch_token() -> String:
	_watch_serial += 1
	return "%d:%d" % [_generation, _watch_serial]


func _purge_stale() -> void:
	for id: String in _commitments.keys():
		if not _is_record_live(_commitments[id]):
			# 查询可以移除失效弱引用，但不能取消弹丸或引发外部写操作。
			release_commitment(id)


func _clear_and_cancel(accept_new: bool) -> void:
	_accepting = false
	_generation += 1
	_serial = 0
	var clearing_generation := _generation
	var projectiles: Array[SporeProjectile] = []
	for id: String in _commitments.keys():
		var projectile := _get_projectile(_commitments[id])
		if is_instance_valid(projectile):
			projectiles.append(projectile)
		release_commitment(id)
	# 先清账并换代，再结束旧弹丸；旧回调没有机会编辑新一代的记录。
	for projectile: SporeProjectile in projectiles:
		if is_instance_valid(projectile):
			projectile.cancel_flight()
	if _generation == clearing_generation:
		_accepting = accept_new
