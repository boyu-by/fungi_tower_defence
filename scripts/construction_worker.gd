class_name ConstructionWorker
extends Node
## 一个建设身份独占一套原执行器；共享场景、网络和交通，不复制付款或成长逻辑。

signal changed(snapshot: Dictionary)
signal maturation_started(construction_id: String)
signal finished(construction_id: String, state: StringName)
signal organ_matured(construction_id: String, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon)

const TERMINAL_STATES: Array[StringName] = [&"completed", &"cancelled", &"failed"]

@export var growth_system: GrowthSystem
@export var growth_supply_system: GrowthSupplySystem
@export var cultivation_system: CultivationSystem
@export var cultivation_supply_system: CultivationSupplySystem
@export var remote_cultivation_system: RemoteCultivationSystem
@export var connection_system: ConnectionSystem

var worker_id: int = 0

var _config: Dictionary = {}
var _configured: bool = false
var _construction_id: String = ""
var _kind: StringName = &""
var _parameters: Dictionary = {}
var _phase: StringName = &"queued"
var _state: StringName = &"waiting"
var _wait_reason: StringName = &"queued"
var _internal_ids: Dictionary = {"growth_task_id": 0, "remote_request_id": 0, "cultivation_task_id": 0}
var _detail: Dictionary = {}
var _terminal_snapshot: Dictionary = {}
var _initial_growth_id: int = 0
var _initial_remote_id: int = 0
var _initial_cultivation_id: int = 0
var _generation: int = 0
var _starting: bool = false
var _syncing: bool = false
var _finishing: bool = false
var _maturation_notified: bool = false
var _cultivation_completion_seen: bool = false
var _organ_notified: bool = false
var _pause_after_start: bool = false
var _cancel_pending: bool = false
var _cancelling: bool = false
var _shutting_down: bool = false
var _shutdown_complete: bool = false
var _shutdown_queued: bool = false
var _bindings: Array[Dictionary] = []
var _last_snapshot: Dictionary = {}


func _init() -> void:
	worker_id = get_instance_id()


func _ready() -> void:
	_resolve_systems()
	_bind_systems()


func _process(_delta: float) -> void:
	if _cancel_pending:
		_cancel_owned_tasks()
		if is_settled():
			_cancel_pending = false
	_sync_request()


func _exit_tree() -> void:
	shutdown()
	for binding: Dictionary in _bindings:
		var source: Node = binding["source"]
		if is_instance_valid(source) and source.is_connected(binding["signal"], binding["callback"]):
			source.disconnect(binding["signal"], binding["callback"])
	_bindings.clear()


func _on_source_changed(_snapshot: Dictionary, _source: Node) -> void:
	if _shutting_down or _cancel_pending:
		_cancel_owned_tasks()
		return
	_sync_request()


func _on_source_terminal(task_id: int, source: Node) -> void:
	if _shutting_down or not _has_live_request() or task_id <= 0:
		return
	if source == cultivation_system and task_id == int(_internal_ids["cultivation_task_id"]):
		var actual: Dictionary = cultivation_system.get_task_snapshot(task_id)
		if actual.get("state") == &"completed" and _cultivation_is_complete(actual):
			_cultivation_completion_seen = true
	_sync_request()


func _on_remote_maturation(
	request_id: int, growth_task_id: int, cultivation_task_id: int, _endpoint: HyphaNode
) -> void:
	if _kind != &"remote_cultivation" or not _has_live_request() or _shutting_down \
			or request_id != int(_internal_ids["remote_request_id"]) \
			or growth_task_id != int(_internal_ids["growth_task_id"]) \
			or cultivation_task_id != int(_internal_ids["cultivation_task_id"]):
		return
	_sync_request()


func _on_organ_matured(task_id: int, host: HyphaNode, organ: AttackOrgan, weapon: SporeWeapon) -> void:
	if _shutting_down or _organ_notified or not _has_live_request() \
			or task_id != int(_internal_ids["cultivation_task_id"]):
		return
	var actual: Dictionary = cultivation_system.get_task_snapshot(task_id)
	if not _cultivation_is_complete(actual) or actual.get("host") != host \
			or not _node_is_available(organ) or not _node_is_available(weapon) \
			or host.get_organ_occupant() != organ or weapon.get_parent() != host \
			or weapon.inventory_owner != organ:
		return
	_organ_notified = true
	organ_matured.emit(_construction_id, host, organ, weapon)


func configure(config: Dictionary) -> bool:
	if _configured or _starting or _shutting_down or not _construction_id.is_empty():
		return false
	_resolve_systems()
	if not _owned_systems_are_available():
		return false
	if not _node_is_available(config.get("mother_core")) or not config.get("mother_core") is MotherCore \
			or not _node_is_available(config.get("network_system")) or not config.get("network_system") is NetworkSystem \
			or not config.get("planner") is GrowthPlanner:
		return false
	if config.get("traffic_system") != null and (not _node_is_available(config.get("traffic_system")) \
			or not config.get("traffic_system") is NetworkTrafficSystem):
		return false
	if config.get("combat_supply_system") != null and (not _node_is_available(config.get("combat_supply_system")) \
			or not config.get("combat_supply_system") is SupplySystem):
		return false
	if config.get("cargo_passage_tracker") != null and (not _node_is_available(config.get("cargo_passage_tracker")) \
			or not config.get("cargo_passage_tracker") is CargoPassageTracker):
		return false
	for key: String in ["node_container", "edge_container", "tip_container", "growth_packet_container", \
			"cultivation_packet_container", "enemy_container", "projectile_container"]:
		if not _node_is_available(config.get(key)) or not config.get(key) is Node2D:
			return false
	_config = config.duplicate()
	var network: NetworkSystem = config["network_system"]
	var payer: MotherCore = config["mother_core"]
	var traffic: NetworkTrafficSystem = config.get("traffic_system") as NetworkTrafficSystem
	var combat_supply: SupplySystem = config.get("combat_supply_system") as SupplySystem
	var passage_tracker: CargoPassageTracker = config.get("cargo_passage_tracker") as CargoPassageTracker
	growth_system.network_system = network
	growth_system.traffic_system = traffic
	growth_system.planner = config["planner"]
	growth_system.node_container = config["node_container"]
	growth_system.edge_container = config["edge_container"]
	growth_system.tip_container = config["tip_container"]
	growth_supply_system.growth_system = growth_system
	growth_supply_system.mother_core = payer
	growth_supply_system.cargo_passage_tracker = passage_tracker
	growth_supply_system.network_system = network
	growth_supply_system.traffic_system = traffic
	growth_supply_system.traffic_required = traffic != null
	growth_supply_system.combat_supply_system = combat_supply
	growth_supply_system.packet_container = config["growth_packet_container"]
	growth_supply_system.auto_supply = false
	cultivation_system.network_system = network
	cultivation_system.growth_system = growth_system
	cultivation_system.enemy_container = config["enemy_container"]
	cultivation_system.projectile_container = config["projectile_container"]
	cultivation_supply_system.cultivation_system = cultivation_system
	cultivation_supply_system.mother_core = payer
	cultivation_supply_system.cargo_passage_tracker = passage_tracker
	cultivation_supply_system.network_system = network
	cultivation_supply_system.traffic_system = traffic
	cultivation_supply_system.traffic_required = traffic != null
	cultivation_supply_system.combat_supply_system = combat_supply
	cultivation_supply_system.packet_container = config["cultivation_packet_container"]
	cultivation_supply_system.auto_supply = false
	remote_cultivation_system.growth_system = growth_system
	remote_cultivation_system.growth_supply_system = growth_supply_system
	remote_cultivation_system.cultivation_system = cultivation_system
	remote_cultivation_system.cultivation_supply_system = cultivation_supply_system
	connection_system.growth_system = growth_system
	connection_system.mother_core = payer
	_configured = true
	if is_node_ready():
		_bind_systems()
	return true


func start_request(construction_id: String, kind: StringName, parameters: Dictionary) -> bool:
	if not _configured or construction_id.is_empty() or _shutting_down or _starting \
			or _has_live_request() or not is_settled() \
			or not [&"growth", &"remote_cultivation", &"connection", &"cultivation"].has(kind):
		return false
	if not _construction_id.is_empty() and (kind != &"cultivation" \
			or not bool(parameters.get("continue_existing", false)) or _state != &"cancelled"):
		return false
	_generation += 1
	_bind_systems()
	var generation: int = _generation
	_construction_id = construction_id
	_kind = kind
	_parameters = parameters.duplicate(true)
	_phase = &"maturing" if kind == &"cultivation" else &"extension"
	_state = &"maturing" if kind == &"cultivation" else &"executing"
	_wait_reason = &""
	_internal_ids = {"growth_task_id": 0, "remote_request_id": 0, "cultivation_task_id": 0}
	_terminal_snapshot = {}
	_detail = {}
	_last_snapshot = {}
	_maturation_notified = false
	_cultivation_completion_seen = false
	_organ_notified = false
	_pause_after_start = false
	_cancel_pending = false
	_initial_growth_id = int(growth_system.get_task_snapshot().get("task_id", 0))
	_initial_remote_id = int(remote_cultivation_system.get_request_snapshot().get("request_id", 0))
	_initial_cultivation_id = int(cultivation_system.get_task_snapshot().get("task_id", 0))
	_starting = true
	_publish_changed()
	var internal_id: int = 0
	if _is_current(construction_id, generation):
		match kind:
			&"growth":
				internal_id = growth_system.create_target(parameters.get("start_node"), \
					parameters.get("target_position", Vector2.ZERO), int(parameters.get("plan_version", 1)))
			&"remote_cultivation":
				internal_id = remote_cultivation_system.request_remote(parameters.get("start_node"), \
					parameters.get("target_position", Vector2.ZERO), parameters.get("organ_kind", &"attack"), int(parameters.get("plan_version", 1)))
			&"connection":
				var first: HyphaNode = parameters.get("first_node") as HyphaNode
				var second: HyphaNode = parameters.get("second_node") as HyphaNode
				var frozen_start: HyphaNode = parameters.get("connection_start_node", first) as HyphaNode
				internal_id = connection_system.request_connection(frozen_start, second if frozen_start == first else first)
			&"cultivation":
				var host: HyphaNode = parameters.get("host") as HyphaNode
				internal_id = cultivation_system.continue_cultivation(host) \
					if bool(parameters.get("continue_existing", false)) else cultivation_system.start_cultivation(host, parameters.get("organ_kind", &""))
	if _construction_id == construction_id and internal_id > 0:
		var key: String = "growth_task_id"
		if kind == &"remote_cultivation":
			key = "remote_request_id"
		elif kind == &"cultivation":
			key = "cultivation_task_id"
		_capture_internal_id(key, internal_id)
	_starting = false
	if not _is_current(construction_id, generation):
		_cancel_owned_tasks()
		if _shutting_down:
			_complete_shutdown()
		return false
	if internal_id <= 0:
		_finish_request(&"failed", &"start_rejected", true)
		return false
	if _pause_after_start:
		_pause_after_start = false
		_change_pause(true)
	_sync_request()
	return not _shutting_down and _construction_id == construction_id


func pause_request() -> bool:
	return _change_pause(true)


func resume_request() -> bool:
	return _change_pause(false)


func cancel_request() -> bool:
	if not _has_live_request() or _shutting_down or _finishing:
		return false
	_capture_starting_ids()
	_finish_request(&"cancelled", &"", true)
	return true


func get_snapshot() -> Dictionary:
	if not _terminal_snapshot.is_empty():
		return _terminal_snapshot.duplicate(true)
	return {
		"construction_id": _construction_id, "worker_id": worker_id,
		"phase": _phase, "state": _state, "wait_reason": _wait_reason,
		"internal_ids": _internal_ids.duplicate(), "detail": _detail.duplicate(true),
	}


func get_resource_snapshot() -> Dictionary:
	var growth: Dictionary = growth_system.get_resource_snapshot() if _node_is_available(growth_system) else {}
	var cultivation: Dictionary = cultivation_system.get_resource_snapshot() if _node_is_available(cultivation_system) else {}
	return {
		"network_structure": int(growth.get("consumed_nutrition", 0)),
		"organ_structure": int(cultivation.get("structure_consumed", 0)),
		"growth_buffer": int(growth.get("buffered_nutrition", 0)),
		"cultivation_buffer": int(cultivation.get("buffered_nutrition", 0)),
		"startup_reserved": int(cultivation.get("startup_reserved", 0)),
		"growth_transit": _paid_transit(growth_supply_system),
		"cultivation_transit": _paid_transit(cultivation_supply_system),
		"startup_transferred": cultivation_system.get_startup_transferred_nutrition() \
			if _node_is_available(cultivation_system) else 0,
	}


func is_settled() -> bool:
	if _starting or _finishing or _syncing or not _owned_systems_are_available():
		return false
	if growth_system.has_active_task() or cultivation_system.has_active_task() \
			or remote_cultivation_system.has_active_request() or connection_system.has_active_task() \
			or _sources_are_transitioning():
		return false
	var resources: Dictionary = get_resource_snapshot()
	if int(resources["growth_buffer"]) + int(resources["cultivation_buffer"]) + int(resources["startup_reserved"]) > 0:
		return false
	for source: Variant in [growth_system, cultivation_system, remote_cultivation_system]:
		if bool(source.get("_emitting_changed")):
			return false
	for supply: Variant in [growth_supply_system, cultivation_supply_system]:
		if supply.get_in_transit_count() > 0 or int(supply.get("_settlement_depth")) > 0 \
				or bool(supply.get("_dispatching")) or bool(supply.get("_resetting")) \
				or bool(supply.get("_emitting_snapshot")):
			return false
	return true


func shutdown() -> void:
	if _shutdown_complete:
		return
	if not _shutting_down:
		_capture_starting_ids()
		_shutting_down = true
		_generation += 1
		set_process(false)
		for child: Node in get_children():
			child.set_process(false)
			child.set_physics_process(false)
		if _node_is_available(growth_supply_system):
			growth_supply_system.auto_supply = false
		if _node_is_available(cultivation_supply_system):
			cultivation_supply_system.auto_supply = false
		if _node_is_available(cultivation_system) and cultivation_system.get("_materializing") != null:
			# 原成熟提交自己的回滚标记；供养账本会在原系统回滚后退回启动库存。
			cultivation_system.set("_materialization_invalid", true)
	_cancel_owned_tasks()
	_complete_shutdown()


func _change_pause(paused: bool) -> bool:
	if not _has_live_request() or _shutting_down or _finishing:
		return false
	if _starting:
		if _pause_after_start == paused:
			return false
		_pause_after_start = paused
		_state = &"paused" if paused else (&"maturing" if _phase == &"maturing" else &"executing")
		_wait_reason = &"paused" if paused else &""
		_publish_changed()
		return true
	var did_change: bool = false
	match _kind:
		&"growth":
			did_change = growth_system.pause_task() if paused else growth_system.resume_task()
		&"remote_cultivation":
			did_change = remote_cultivation_system.pause_request() if paused else remote_cultivation_system.resume_request()
		&"connection":
			did_change = connection_system.pause_task() if paused else connection_system.resume_task()
		&"cultivation":
			did_change = cultivation_system.pause_task() if paused else cultivation_system.resume_task()
	_sync_request()
	return did_change


func _sync_request() -> void:
	if _syncing or _finishing or _shutting_down or not _has_live_request():
		return
	_syncing = true
	var construction_id: String = _construction_id
	var generation: int = _generation
	_capture_starting_ids()
	var actual: Dictionary = _actual_snapshot()
	if _is_current(construction_id, generation) and not actual.is_empty():
		_detail = actual.duplicate(true)
		_detail["growth_shipments"] = growth_supply_system.get_shipment_records()
		_detail["cultivation_shipments"] = cultivation_supply_system.get_shipment_records()
		var reason: StringName = _identity_reason(actual)
		if reason != &"" and not _starting:
			_finish_request(&"failed", reason, true)
		elif reason == &"":
			var source_state: StringName = StringName(actual.get("state", &"idle"))
			if source_state == &"cancelled" and not _starting:
				_finish_request(&"cancelled", &"", false)
			elif source_state == &"completed" and not _starting:
				if _completion_is_valid(actual):
					if _kind != &"cultivation" or _cultivation_completion_seen:
						_finish_request(&"completed", &"", false)
				else:
					_finish_request(&"failed", &"invalid_completion", true)
			else:
				if _kind == &"remote_cultivation" and _remote_handoff_is_valid(actual):
					_phase = &"maturing"
				_state = &"paused" if source_state == &"paused" or _pause_after_start else (&"maturing" if _phase == &"maturing" else &"executing")
				_wait_reason = &"paused" if _pause_after_start else StringName(actual.get("wait_reason", &""))
				_publish_changed()
				if _is_current(construction_id, generation) and _phase == &"maturing" \
						and _kind == &"remote_cultivation" and not _maturation_notified:
					_maturation_notified = true
					maturation_started.emit(construction_id)
	elif not _starting and _is_current(construction_id, generation):
		_finish_request(&"failed", &"executor_replaced", true)
	_syncing = false


func _actual_snapshot() -> Dictionary:
	if _kind == &"remote_cultivation":
		var remote: Dictionary = remote_cultivation_system.get_request_snapshot()
		if int(remote.get("request_id", 0)) != int(_internal_ids["remote_request_id"]) \
				or int(_internal_ids["remote_request_id"]) <= 0:
			return {}
		_capture_internal_id("growth_task_id", int(remote.get("growth_task_id", 0)))
		_capture_internal_id("cultivation_task_id", int(remote.get("cultivation_task_id", 0)))
		return remote
	if _kind == &"cultivation":
		var task: Dictionary = cultivation_system.get_task_snapshot(int(_internal_ids["cultivation_task_id"]))
		return task if int(task.get("task_id", 0)) == int(_internal_ids["cultivation_task_id"]) \
			and int(_internal_ids["cultivation_task_id"]) > 0 else {}
	var growth: Dictionary = growth_system.get_task_snapshot()
	if int(growth.get("task_id", 0)) != int(_internal_ids["growth_task_id"]) \
			or int(_internal_ids["growth_task_id"]) <= 0:
		return {}
	if _kind == &"connection":
		var forwarded: Dictionary = connection_system.get_task_snapshot()
		if int(forwarded.get("task_id", 0)) != int(_internal_ids["growth_task_id"]):
			return {}
	return growth


func _capture_starting_ids() -> void:
	if not _starting or not _configured or _shutting_down:
		return
	if _kind == &"remote_cultivation":
		var remote: Dictionary = remote_cultivation_system.get_request_snapshot()
		if int(remote.get("request_id", 0)) > _initial_remote_id \
				and remote.get("target_position") == _parameters.get("target_position"):
			_capture_internal_id("remote_request_id", int(remote["request_id"]))
			_capture_internal_id("growth_task_id", int(remote.get("growth_task_id", 0)))
			_capture_internal_id("cultivation_task_id", int(remote.get("cultivation_task_id", 0)))
	elif _kind == &"cultivation":
		var task: Dictionary = cultivation_system.get_task_snapshot()
		if int(task.get("task_id", 0)) > _initial_cultivation_id and task.get("host") == _parameters.get("host"):
			_capture_internal_id("cultivation_task_id", int(task["task_id"]))
	else:
		var growth: Dictionary = growth_system.get_task_snapshot()
		if int(growth.get("task_id", 0)) > _initial_growth_id and _growth_parameters_match(growth):
			_capture_internal_id("growth_task_id", int(growth["task_id"]))


func _capture_internal_id(key: String, value: int) -> void:
	if value <= 0:
		return
	var previous: int = int(_internal_ids[key])
	if previous == 0:
		_internal_ids[key] = value
	elif previous != value:
		_wait_reason = &"executor_replaced"


func _identity_reason(actual: Dictionary) -> StringName:
	if not _owned_systems_are_available():
		return &"invalid_configuration"
	var payer: MotherCore = _config.get("mother_core") as MotherCore
	var network: NetworkSystem = _config.get("network_system") as NetworkSystem
	if not _node_is_available(payer) or payer.health <= 0:
		return &"core_unavailable"
	if not _node_is_available(network) or network.peek_registered_core() != payer \
			or growth_supply_system.mother_core != payer or cultivation_supply_system.mother_core != payer:
		return &"payer_replaced"
	if growth_system.network_system != network or cultivation_system.network_system != network \
			or growth_supply_system.network_system != network or cultivation_supply_system.network_system != network \
			or growth_supply_system.growth_system != growth_system \
			or cultivation_supply_system.cultivation_system != cultivation_system \
			or remote_cultivation_system.growth_system != growth_system \
			or remote_cultivation_system.growth_supply_system != growth_supply_system \
			or remote_cultivation_system.cultivation_system != cultivation_system \
			or remote_cultivation_system.cultivation_supply_system != cultivation_supply_system \
			or connection_system.growth_system != growth_system or connection_system.mother_core != payer:
		return &"invalid_configuration"
	if _wait_reason == &"executor_replaced":
		return &"executor_replaced"
	if _kind == &"cultivation":
		if actual.get("host") != _parameters.get("host"):
			return &"executor_replaced"
		return _cultivation_endpoint_reason(actual)
	var growth: Dictionary = growth_system.get_task_snapshot()
	if int(growth.get("task_id", 0)) != int(_internal_ids["growth_task_id"]) or not _growth_parameters_match(growth):
		return &"executor_replaced"
	if _kind == &"connection":
		for key: String in ["first_node", "second_node"]:
			var node: Node2D = _parameters.get(key) as Node2D
			if not _node_is_available(node) or not network.is_node_registered(node):
				return &"invalid_endpoint"
		var target: Node2D = actual.get("target_node") as Node2D
		if not _node_is_available(target) or target.global_position != actual.get("target_position"):
			return &"invalid_target"
	else:
		var start: Node2D = _parameters.get("start_node") as Node2D
		if not _node_is_available(start) or not network.is_node_registered(start):
			return &"invalid_endpoint"
	if _kind == &"remote_cultivation" and [&"connected", &"cultivation"].has(actual.get("phase")):
		var endpoint: HyphaNode = actual.get("endpoint") as HyphaNode
		if not _node_is_available(endpoint) or not network.is_node_registered(endpoint):
			return &"invalid_endpoint"
		if bool(remote_cultivation_system.get("_transitioning")) or bool(cultivation_system.get("_transitioning")):
			return &""
		if actual.get("phase") == &"connected":
			return &"" if endpoint.is_organ_slot_available() else &"occupied_target"
		var cultivation: Dictionary = cultivation_system.get_task_snapshot(int(_internal_ids["cultivation_task_id"]))
		if int(cultivation.get("task_id", 0)) != int(_internal_ids["cultivation_task_id"]) \
				or cultivation.get("host") != endpoint:
			return &"executor_replaced"
		return _cultivation_endpoint_reason(cultivation)
	return &""


func _cultivation_endpoint_reason(task: Dictionary) -> StringName:
	var host: HyphaNode = task.get("host") as HyphaNode
	var network: NetworkSystem = _config.get("network_system") as NetworkSystem
	if not _node_is_available(host) or not network.is_node_registered(host):
		return &"invalid_endpoint"
	if task.get("state") == &"cancelled" or bool(cultivation_system.get("_transitioning")):
		return &""
	if task.get("state") == &"completed":
		return &"" if _cultivation_is_complete(task) else &"invalid_completion"
	if task.get("wait_reason") == &"occupied":
		return &"occupied_target"
	var bud: OrganBud = host.get_organ_bud()
	if not _node_is_available(bud) or host.get_organ_occupant() != bud \
			or bud.get_snapshot().get("bud_id") != task.get("bud_id"):
		return &"occupied_target"
	return &""


func _growth_parameters_match(task: Dictionary) -> bool:
	if _kind == &"connection":
		var first: Variant = _parameters.get("first_node")
		var second: Variant = _parameters.get("second_node")
		return task.get("task_kind") == &"connection" \
			and ((task.get("start_node") == first and task.get("target_node") == second) \
				or (task.get("start_node") == second and task.get("target_node") == first))
	return task.get("task_kind") == &"growth" and task.get("start_node") == _parameters.get("start_node") \
		and task.get("target_position") == _parameters.get("target_position")


func _remote_handoff_is_valid(actual: Dictionary) -> bool:
	if not bool(actual.get("extension_released", false)) or actual.get("phase") != &"cultivation":
		return false
	var growth: Dictionary = growth_system.get_task_snapshot()
	var task: Dictionary = cultivation_system.get_task_snapshot(int(_internal_ids["cultivation_task_id"]))
	var endpoint: HyphaNode = actual.get("endpoint") as HyphaNode
	if not _node_is_available(endpoint) or int(_internal_ids["growth_task_id"]) <= 0 \
			or int(_internal_ids["cultivation_task_id"]) <= 0 \
			or growth.get("state") != &"completed" \
			or growth_system.get_completed_endpoint(int(_internal_ids["growth_task_id"])) != endpoint \
			or int(growth.get("buffered_nutrition", 0)) != 0 or growth_supply_system.get_in_transit_count() > 0 \
			or int(growth_supply_system.get("_settlement_depth")) > 0 or bool(growth_supply_system.get("_dispatching")) \
			or task.get("host") != endpoint or int(task.get("task_id", 0)) != int(_internal_ids["cultivation_task_id"]):
		return false
	var bud: OrganBud = endpoint.get_organ_bud()
	return cultivation_system.has_active_task() and _node_is_available(bud) \
		and endpoint.get_organ_occupant() == bud and bud.get_snapshot().get("bud_id") == task.get("bud_id") \
		and task.get("wait_reason") != &"occupied"


func _completion_is_valid(actual: Dictionary) -> bool:
	var network: NetworkSystem = _config.get("network_system") as NetworkSystem
	if _kind == &"cultivation":
		return _cultivation_is_complete(actual)
	var endpoint: HyphaNode = growth_system.get_completed_endpoint(int(_internal_ids["growth_task_id"]))
	if growth_system.has_active_task() or not _node_is_available(endpoint) or not network.is_node_registered(endpoint):
		return false
	if _kind == &"connection":
		return endpoint == actual.get("target_node") \
			and network.has_direct_connection(_parameters.get("first_node"), _parameters.get("second_node"))
	if endpoint.global_position.distance_to(growth_system.get_task_snapshot().get("resolved_target_position", _parameters.get("target_position", Vector2.ZERO))) > 1.0:
		return false
	if _kind == &"remote_cultivation":
		var growth: Dictionary = growth_system.get_task_snapshot()
		var task: Dictionary = cultivation_system.get_task_snapshot(int(_internal_ids["cultivation_task_id"]))
		return not remote_cultivation_system.has_active_request() and growth.get("state") == &"completed" \
			and bool(actual.get("extension_released", false)) and actual.get("endpoint") == endpoint \
			and task.get("host") == endpoint and _cultivation_is_complete(task)
	return actual.get("state") == &"completed"


func _cultivation_is_complete(task: Dictionary) -> bool:
	var host: HyphaNode = task.get("host") as HyphaNode
	var network: NetworkSystem = _config.get("network_system") as NetworkSystem
	var digestive: bool = task.get("organ_kind", &"attack") == &"digestive"
	var structure_cost: int = int(task.get("structure_cost", CultivationSystem.STRUCTURE_COST))
	var startup_cost: int = int(task.get("startup_cost", 0 if digestive else CultivationSystem.STARTUP_COST))
	if task.get("state") != &"completed" or int(task.get("task_id", 0)) <= 0 \
			or int(task.get("task_id", 0)) != int(_internal_ids["cultivation_task_id"]) \
			or cultivation_system.has_active_task() \
			or int(task.get("structure_consumed", 0)) != structure_cost \
			or int(task.get("startup_transferred", 0)) != startup_cost \
			or float(task.get("effective_time", 0.0)) < CultivationSystem.MINIMUM_EFFECTIVE_TIME \
			or int(task.get("buffered_nutrition", 0)) != 0 or int(task.get("startup_reserved", 0)) != 0 \
			or not _node_is_available(host) or not _node_is_available(network) or not network.is_node_registered(host):
		return false
	var organ: Variant = host.get_organ_occupant()
	if not _node_is_available(organ) or organ.get_parent() != host or (digestive and not organ is DigestiveOrgan) or (not digestive and not organ is AttackOrgan):
		return false
	var occupants: int = 0
	for child: Node in host.get_children():
		if _node_is_available(child) and (child is OrganBud or child is AttackOrgan or child is DigestiveOrgan):
			occupants += 1
	return occupants == 1


func _finish_request(state: StringName, reason: StringName, cancel_executor: bool) -> void:
	if _finishing or _shutting_down or not _has_live_request():
		return
	_finishing = true
	var construction_id: String = _construction_id
	_state = state
	_phase = &"terminal"
	_wait_reason = reason
	_generation += 1
	if cancel_executor:
		_cancel_pending = true
		_cancel_owned_tasks()
	var actual: Dictionary = _actual_snapshot()
	if not actual.is_empty():
		_detail = actual.duplicate(true)
	_detail["growth_shipments"] = growth_supply_system.get_shipment_records()
	_detail["cultivation_shipments"] = cultivation_supply_system.get_shipment_records()
	_terminal_snapshot = get_snapshot().duplicate(true)
	_finishing = false
	_publish_changed()
	if not _shutting_down and _construction_id == construction_id:
		finished.emit(construction_id, state)


func _cancel_owned_tasks() -> void:
	if not _configured or _cancelling:
		return
	_cancelling = true
	if _kind == &"remote_cultivation" and _node_is_available(remote_cultivation_system) \
			and remote_cultivation_system.has_active_request() \
			and int(remote_cultivation_system.get_request_snapshot().get("request_id", 0)) == int(_internal_ids["remote_request_id"]):
		remote_cultivation_system.cancel_request()
	if _node_is_available(connection_system) and _kind == &"connection" \
			and connection_system.has_active_task() \
			and int(connection_system.get_task_snapshot().get("task_id", 0)) == int(_internal_ids["growth_task_id"]):
		connection_system.cancel_task()
	if _node_is_available(growth_system) and growth_system.has_active_task() \
			and int(growth_system.get_task_snapshot().get("task_id", 0)) == int(_internal_ids["growth_task_id"]):
		growth_system.cancel_task()
	if _node_is_available(cultivation_system) and cultivation_system.has_active_task() \
			and int(cultivation_system.get_task_snapshot().get("task_id", 0)) == int(_internal_ids["cultivation_task_id"]):
		cultivation_system.cancel_task()
	_cancelling = false


func _complete_shutdown() -> void:
	_shutdown_queued = false
	if not _shutting_down or _shutdown_complete:
		return
	var supply_busy: bool = false
	for supply: Variant in [growth_supply_system, cultivation_supply_system]:
		if _node_is_available(supply) and (bool(supply.get("_dispatching")) or int(supply.get("_settlement_depth")) > 0):
			supply_busy = true
	if _starting or _sources_are_transitioning() or supply_busy:
		if not _shutdown_queued and is_inside_tree():
			_shutdown_queued = true
			_complete_shutdown.call_deferred()
		return
	if _node_is_available(remote_cultivation_system):
		remote_cultivation_system.reset()
	if _node_is_available(connection_system):
		connection_system.reset()
	if _node_is_available(growth_supply_system):
		growth_supply_system.reset()
	if _node_is_available(cultivation_supply_system):
		cultivation_supply_system.reset()
	if _node_is_available(cultivation_system):
		cultivation_system.reset()
	_shutdown_complete = true


func _sources_are_transitioning() -> bool:
	return (_node_is_available(growth_system) and (bool(growth_system.get("_changing_topology")) \
			or bool(growth_system.get("_advancing")))) \
		or (_node_is_available(cultivation_system) and (bool(cultivation_system.get("_transitioning")) \
			or bool(cultivation_system.get("_advancing")))) \
		or (_node_is_available(remote_cultivation_system) and bool(remote_cultivation_system.get("_transitioning")))


func _paid_transit(supply: Variant) -> int:
	if not _node_is_available(supply):
		return 0
	var amount: int = 0
	for shipment: Dictionary in supply.get_shipment_records():
		if bool(shipment.get("debited", false)) and not bool(shipment.get("settled", false)) \
				and not bool(shipment.get("refunded", false)):
			amount += 1
	return amount


func _has_live_request() -> bool:
	return not _construction_id.is_empty() and not TERMINAL_STATES.has(_state)


func _is_current(construction_id: String, generation: int) -> bool:
	return _construction_id == construction_id and _generation == generation \
		and not _shutting_down and _has_live_request()


func _resolve_systems() -> void:
	if growth_system == null:
		growth_system = get_node_or_null("GrowthSystem") as GrowthSystem
	if growth_supply_system == null:
		growth_supply_system = get_node_or_null("GrowthSupplySystem") as GrowthSupplySystem
	if cultivation_system == null:
		cultivation_system = get_node_or_null("CultivationSystem") as CultivationSystem
	if cultivation_supply_system == null:
		cultivation_supply_system = get_node_or_null("CultivationSupplySystem") as CultivationSupplySystem
	if remote_cultivation_system == null:
		remote_cultivation_system = get_node_or_null("RemoteCultivationSystem") as RemoteCultivationSystem
	if connection_system == null:
		connection_system = get_node_or_null("ConnectionSystem") as ConnectionSystem


func _owned_systems_are_available() -> bool:
	for system: Node in [growth_system, growth_supply_system, cultivation_system, \
			cultivation_supply_system, remote_cultivation_system, connection_system]:
		if not _node_is_available(system) or system.get_parent() != self:
			return false
	return true


func _bind_systems() -> void:
	if not _bindings.is_empty() or not _owned_systems_are_available():
		return
	for source: Node in [growth_system, cultivation_system, connection_system]:
		_bind(source, &"task_changed", _on_source_changed.bind(source))
		_bind(source, &"task_completed", _on_source_terminal.bind(source))
		_bind(source, &"task_cancelled", _on_source_terminal.bind(source))
	_bind(remote_cultivation_system, &"request_changed", _on_source_changed.bind(remote_cultivation_system))
	_bind(remote_cultivation_system, &"request_completed", _on_source_terminal.bind(remote_cultivation_system))
	_bind(remote_cultivation_system, &"request_cancelled", _on_source_terminal.bind(remote_cultivation_system))
	_bind(remote_cultivation_system, &"maturation_started", _on_remote_maturation)
	_bind(cultivation_system, &"organ_matured", _on_organ_matured)
	_bind(growth_supply_system, &"supply_changed", _on_source_changed.bind(growth_supply_system))
	_bind(cultivation_supply_system, &"supply_changed", _on_source_changed.bind(cultivation_supply_system))


func _bind(source: Node, signal_name: StringName, callback: Callable) -> void:
	source.connect(signal_name, callback)
	_bindings.append({"source": source, "signal": signal_name, "callback": callback})


func _publish_changed() -> void:
	if _shutting_down:
		return
	var snapshot: Dictionary = get_snapshot()
	if snapshot != _last_snapshot:
		_last_snapshot = snapshot.duplicate(true)
		changed.emit(snapshot)


func _node_is_available(node: Variant) -> bool:
	return is_instance_valid(node) and node is Node and not node.is_queued_for_deletion()


func preview_retarget(position: Vector2) -> Dictionary:
	if not _has_live_request() or _shutting_down or _phase == &"maturing" or _kind not in [&"growth", &"remote_cultivation"]:
		return {"valid": false, "error": "此目标已成熟或不能改向。"}
	return remote_cultivation_system.preview_retarget(position) if _kind == &"remote_cultivation" else growth_system.preview_retarget(position)


func retarget_target(position: Vector2) -> bool:
	if not bool(preview_retarget(position).get("valid", false)) or _syncing:
		return false
	# 先屏蔽执行器同步通知；新几何和请求参数作为同一操作发布。
	_syncing = true
	var previous: Vector2 = _parameters.get("target_position", Vector2.ZERO)
	_parameters["target_position"] = position
	var accepted: bool = remote_cultivation_system.retarget_target(position) if _kind == &"remote_cultivation" else growth_system.retarget_target(position)
	if not accepted:
		_parameters["target_position"] = previous
	_syncing = false
	_sync_request()
	return accepted
