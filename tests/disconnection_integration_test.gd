extends SceneTree
## 真实验证关卡、可用采集连通性、暂时失联、恢复与 R 重开；不注入营养。

const DEMO: PackedScene = preload("res://scenes/levels/traffic_recovery_demo.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 800)
	_check(InputMap.action_get_events("traffic_recovery_demo")[0].keycode == KEY_F6,
		"F6 is the explicit recovery demonstration entry")
	_test_available_topology_and_handoff()
	_test_node_bypass_and_traversed_break()
	_test_occupied_break_and_restore()
	_test_no_route_field_and_restore()
	_test_cancel_and_permanent_removal()
	await _test_restart()
	await _test_demo_entry_roundtrip()
	print("DISCONNECTION_INTEGRATION_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _quiet(level: Node2D) -> void:
	level.set_process(false)
	level.supply_system.get_node("DispatchTimer").stop()
	level.recycling_system.get_node("DispatchTimer").stop()
	level.growth_supply_system.auto_supply = false
	level.cultivation_supply_system.auto_supply = false
	level.nutrition_return_system.auto_return = false
	level.fungal_field.set_process(false)
	level.traffic_system.set_process(false)
	for weapon: SporeWeapon in level.get_weapons():
		weapon.get_node("FireTimer").stop()


func _new_demo() -> Node2D:
	var level: Node2D = DEMO.instantiate() as Node2D
	root.add_child(level)
	current_scene = level
	_quiet(level)
	level.fungal_field.advance(1.0)
	return level


func _dispose(level: Node2D) -> void:
	if current_scene == level:
		current_scene = null
	level.free()


func _right(level: Node2D) -> AttackOrgan:
	return level.get_node("World/Colony/Nodes/RightNode/AttackOrgan") as AttackOrgan


func _dispatch(level: Node2D) -> NutrientPacket:
	_check(level.supply_system.request_supply(_right(level)), "Real paid supply dispatch succeeds")
	for child: Node in level.get_node("World/Packets").get_children():
		if child is NutrientPacket and not child.is_queued_for_deletion():
			child.set_physics_process(false)
			return child as NutrientPacket
	_check(false, "Real dispatch must expose its production packet")
	return null


func _step_packet(level: Node2D, packet: NutrientPacket, delta: float = 0.1) -> void:
	level.traffic_system.refresh()
	if is_instance_valid(packet) and not packet.is_queued_for_deletion():
		packet._physics_process(delta)
	for row: Dictionary in level.traffic_system.get_snapshot()["edges"]:
		_check(int(row["occupied_units"]) >= 0 and int(row["occupied_units"]) <= int(row["capacity"]),
			"Both directions remain inside the same edge capacity")


func _deliver(level: Node2D, packet: NutrientPacket) -> void:
	for _tick: int in range(250):
		if not is_instance_valid(packet) or packet.is_queued_for_deletion():
			break
		_step_packet(level, packet)
	_check(level.supply_system.delivered_packets == 1 and level.supply_system.interrupted_packets == 0,
		"Actual route completion delivers once without an interruption")
	_check(_right(level).nutrition == 5 and _right(level).incoming_nutrition == 0
		and level.mother_core.nutrition == 71, "Exactly one payment becomes exactly one organ nutrition")


func _test_available_topology_and_handoff() -> void:
	var level: Node2D = _new_demo()
	var right: Node2D = _right(level).get_parent()
	level.set_demo_primary_closed(true)
	_check(level.network_system.find_available_route(level.mother_core, right).found,
		"Closing the primary leaves the physical bypass available")
	level.set_demo_bypass_closed(true)
	_check(level.network_system.find_route(level.mother_core, right).found
		and not level.network_system.find_available_route(level.mother_core, right).found,
		"Temporary closure preserves physical edges but separates available connectivity")
	_check(not level.recycling_system.try_dispatch()
		and level.get_node("World/Remains/LargeCarcass").get_remaining_nutrition() == 80,
		"Disconnected residual field is not a new carcass collection entry")
	level.restore_demo_edges()
	var tip: GrowthTip = GrowthTip.new()
	level.get_node("World/GrowthTips").add_child(tip)
	tip.global_position = Vector2(600, 600)
	var junction: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	level.hypha_nodes.add_child(junction)
	junction.global_position = tip.global_position
	level.network_system.register_node(tip)
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = level.mother_core
	edge.end_node = tip
	level.hypha_edges.add_child(edge)
	var owner: Node = Node.new()
	level.add_child(owner)
	var request: Dictionary = level.traffic_system.request_passage("handoff", owner, "paid-growth", edge,
		level.mother_core, tip, &"supply")
	var token: String = request["token"]
	var observed: Array[bool] = []
	level.traffic_system.request_changed.connect(func(s: Dictionary) -> void:
		if s["request_id"] == request["request_id"] and s["state"] == &"granted":
			observed.append(edge.end_node == junction and s["to_node"] == junction and s["token"] == token))
	_check(level.traffic_system.handoff_growth_endpoint(edge, tip, junction), "Paid junction handoff commits")
	_check(level.network_system.get_growth_handoff(edge, tip.get_instance_id()) == junction
		and level.traffic_system.get_lease(token)["to_node"] == junction
		and observed == [true], "Handoff observer sees new endpoint and same already-committed token")
	_check(level.traffic_system.release(token) and not level.traffic_system.release(token),
		"Transferred token still releases exactly once")
	var generation: int = level.traffic_system.get_generation()
	level.traffic_system.cancel_owner(owner)
	_check(not level.traffic_system.is_transport_identity_valid(owner, "no-route-owner", generation),
		"Owner cancellation without a request prevents no-route resurrection")
	level.traffic_system.reset()
	_check(level.traffic_system.is_transport_identity_valid(owner, "new-generation", level.traffic_system.get_generation()),
		"A reset isolates retirement to the former generation")
	_dispose(level)


func _test_node_bypass_and_traversed_break() -> void:
	var level: Node2D = _new_demo()
	level.set_demo_primary_closed(true)
	var packet: NutrientPacket = _dispatch(level)
	if packet != null:
		_check(packet.get_transport_snapshot()["reroute_count"] >= 1 and packet.edge == level.bypass_edge,
			"Node packet chooses real bypass while retaining its target")
		for _tick: int in range(25):
			_step_packet(level, packet)
		level.set_demo_bypass_closed(true)
		_deliver(level, packet)
	_dispose(level)


func _test_occupied_break_and_restore() -> void:
	var level: Node2D = _new_demo()
	var packet: NutrientPacket = _dispatch(level)
	if packet != null:
		_step_packet(level, packet, 0.4)
		var position: Vector2 = packet.global_position
		var token: String = packet.get_transport_snapshot()["token"]
		level.set_demo_primary_closed(true)
		for _tick: int in range(50):
			_step_packet(level, packet)
			_check(packet.global_position == position and packet.get_transport_snapshot()["state"] == &"blocked"
				and packet.get_transport_snapshot()["token"] == token, "Closed occupied edge freezes position and preserves lease")
		_check(level.mother_core.nutrition == 71 and _right(level).incoming_nutrition == 1,
			"Stopped cargo retains payment and receiving reservation")
		level.restore_demo_edges()
		_deliver(level, packet)
	_dispose(level)


func _test_no_route_field_and_restore() -> void:
	var level: Node2D = _new_demo()
	var host: Node2D = _right(level).get_parent()
	level.set_demo_primary_closed(true)
	level.set_demo_bypass_closed(true)
	var packet: NutrientPacket = _dispatch(level)
	if packet != null:
		var initial: Vector2 = packet.global_position
		for _tick: int in range(80):
			_step_packet(level, packet)
			_check(packet.get_transport_snapshot()["state"] == &"waiting" and packet.global_position == initial,
				"No route stays at its actual node without moving or failing")
		_check(level.mother_core.nutrition == 71 and _right(level).incoming_nutrition == 1
			and level.supply_system.interrupted_packets == 0, "No-route wait cannot refund or unreserve")
		level.fungal_field.advance(5.0)
		_check(is_equal_approx(level.fungal_field.get_source_snapshot(host)["display_radius"], 110.0)
			and level.fungal_field.get_effective_radius(host) == 0.0, "Five-second residual is visible but not collectible")
		level.fungal_field.advance(5.0)
		var fading: Dictionary = level.fungal_field.get_source_snapshot(host)
		_check(is_equal_approx(fading["display_radius"], 55.0) and is_equal_approx(fading["brightness"], 0.5),
			"Halfway through decay, real level radius and brightness are halved")
		level.set_demo_primary_closed(false)
		_check(is_equal_approx(level.fungal_field.get_source_snapshot(host)["display_radius"], 55.0),
			"Restore retains the visible radius instead of jumping to maturity")
		level.fungal_field.advance(0.1)
		_check(level.fungal_field.get_effective_radius(host) > 55.0
			and level.fungal_field.get_effective_radius(host) < 110.0, "Restoration expands gradually")
		_deliver(level, packet)
	_dispose(level)


func _test_cancel_and_permanent_removal() -> void:
	for permanent: bool in [false, true]:
		var level: Node2D = _new_demo()
		var packet: NutrientPacket = _dispatch(level)
		if packet != null:
			_step_packet(level, packet, 0.2)
			if permanent:
				level.network_system.unregister_edge(level.primary_edge)
				_step_packet(level, packet)
			else:
				level.set_demo_primary_closed(true)
				_step_packet(level, packet)
				packet.cancel_transport()
				level.restore_demo_edges()
				packet.cancel_transport()
			_check(level.supply_system.interrupted_packets == 1 and level.mother_core.nutrition == 72
				and _right(level).incoming_nutrition == 0, "Permanent removal/cancel settles exactly once")
			_check(level.traffic_system.get_snapshot()["occupied_units"] == 0,
				"Terminated transport retains no occupancy")
		_dispose(level)


func _test_restart() -> void:
	var level: Node2D = _new_demo()
	level.set_demo_primary_closed(true)
	level.set_demo_bypass_closed(true)
	var packet: NutrientPacket = _dispatch(level)
	_check(packet != null and level.mother_core.nutrition == 71, "Restart begins with one real paid waiting packet")
	var event: InputEventKey = InputEventKey.new()
	event.keycode = KEY_R
	event.pressed = true
	root.push_input(event)
	for _frame: int in range(4):
		await process_frame
	var fresh: Node2D = current_scene as Node2D
	_check(is_instance_valid(fresh) and fresh != level, "R reloads the actual recovery scene")
	if is_instance_valid(fresh):
		_quiet(fresh)
		_check(fresh.mother_core.nutrition == 72 and _right(fresh).incoming_nutrition == 0
			and fresh.traffic_system.get_snapshot()["active_request_count"] == 0,
			"Fresh scene has original balance and no old waiting/occupancy")
		_check(fresh.primary_edge.entry_enabled and fresh.bypass_edge.entry_enabled,
			"Restart restores simulated closures")
		_dispose(fresh)


func _test_demo_entry_roundtrip() -> void:
	_new_demo()
	for expected: String in ["res://scenes/levels/large_carcass_demo.tscn", DEMO.resource_path]:
		var previous_id: int = current_scene.get_instance_id()
		var key: InputEventKey = InputEventKey.new()
		key.keycode = KEY_F6
		key.pressed = true
		root.push_input(key)
		key = key.duplicate() as InputEventKey
		key.pressed = false
		root.push_input(key)
		for _frame: int in range(4):
			await process_frame
		var scene: Node2D = current_scene as Node2D
		_check(is_instance_valid(scene) and scene.get_instance_id() != previous_id
			and scene.scene_file_path == expected, "F6 switches between the actual demo scenes")
		if not is_instance_valid(scene):
			return
		_quiet(scene)
		_check(scene.mother_core.nutrition == 72 and scene.supply_system.get_in_transit_count() == 0,
			"F6 roundtrip preserves each scene's clean original resources")
		_check(scene.traffic_system.get_snapshot()["active_request_count"] == 0,
			"F6 does not transfer traffic records into the new scene")
	_dispose(current_scene as Node2D)
