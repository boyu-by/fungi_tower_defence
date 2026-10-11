extends SceneTree
## 显式 advance 验证断连残影、可采集覆盖和重连恢复；不依赖网络或帧速。

const FIELD_SCRIPT: Script = preload("res://scripts/fungal_field.gd")
const EPSILON: float = 0.00001
const WORLD_POINT_EPSILON: float = 0.001

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_growth_and_initial_disconnect()
	_test_exact_grace_and_decay()
	_test_repeated_loss_snapshots_and_partial_baseline()
	_test_midway_recovery_and_repeated_snapshots()
	_test_recovery_before_grace_and_after_gone()
	_test_brightness_and_radius_recover_independently()
	_test_second_loss_uses_current_recovery_baseline()
	_test_active_overlap_and_union()
	_test_active_fill_order_and_coincident_brightness()
	await _test_removal_and_deletion()
	_test_world_transforms_and_movement()
	_test_invalid_delta_and_configuration()
	_test_snapshot_queries_are_pure()
	_check(root.get_child_count() == 0, "Decay fixture cleanup left nodes behind")
	print("FUNGAL_FIELD_DECAY_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _close(actual: float, expected: float, description: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= EPSILON, description)


func _check_world_draw_transform(field: FungalField, center: Vector2,
	radius: float, context: String) -> void:
	var draw_world: Transform2D = field.global_transform * field._get_world_draw_transform()
	var origin_error: float = draw_world.origin.length()
	var x_basis_error: float = (draw_world.x - Vector2.RIGHT).length()
	var y_basis_error: float = (draw_world.y - Vector2.DOWN).length()
	_check(draw_world.is_finite(), context + ": finite world draw transform")
	_check(origin_error <= WORLD_POINT_EPSILON, context + ": translation error <= 0.001 world pixels")
	_check(x_basis_error <= EPSILON and y_basis_error <= EPSILON,
		context + ": unit basis error <= 0.00001")
	var points: Array[Vector2] = [Vector2.ZERO, center,
		center + Vector2(radius, 0.0), center - Vector2(radius, 0.0),
		center + Vector2(0.0, radius), center - Vector2(0.0, radius)]
	var diagnostics: Array[Dictionary] = []
	for point: Vector2 in points:
		var transformed: Vector2 = draw_world * point
		var error: float = transformed.distance_to(point)
		_check(error <= WORLD_POINT_EPSILON,
			context + ": sampled world point error <= 0.001 pixels at " + str(point))
		diagnostics.append({
			"input": [point.x, point.y],
			"output": [transformed.x, transformed.y],
			"error_px": error,
		})
	# 显式保留矩阵、单位基和世界坐标误差，主代理运行时可核对实际精度。
	print("FUNGAL_FIELD_WORLD_TRANSFORM_DIAGNOSTIC ", JSON.stringify({
		"context": context,
		"basis_x": [draw_world.x.x, draw_world.x.y],
		"basis_y": [draw_world.y.x, draw_world.y.y],
		"origin": [draw_world.origin.x, draw_world.origin.y],
		"origin_error_px": origin_error,
		"basis_x_error": x_basis_error,
		"basis_y_error": y_basis_error,
		"world_point_tolerance_px": WORLD_POINT_EPSILON,
		"basis_tolerance": EPSILON,
		"points": diagnostics,
	}))


func _new_world() -> Node2D:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	return world


func _new_field(world: Node2D, radius: float = 200.0, speed: float = 100.0) -> FungalField:
	var field: FungalField = FIELD_SCRIPT.new() as FungalField
	world.add_child(field)
	field.set_process(false)
	field.core_radius = radius
	field.node_radius = radius
	field.expansion_speed = speed
	return field


func _new_source(world: Node2D, world_position: Vector2 = Vector2.ZERO) -> Node2D:
	var node: Node2D = Node2D.new()
	world.add_child(node)
	node.global_position = world_position
	return node


func _source(node: Node2D, connected: bool = true, radius: Variant = null) -> Dictionary:
	var snapshot: Dictionary = {"node": node, "kind": &"junction", "connected": connected}
	if radius != null:
		snapshot["radius"] = radius
	return snapshot


func _check_source(field: FungalField, node: Node2D, phase: StringName,
	display_radius: float, brightness: float, seconds: float, context: String) -> void:
	var snapshot: Dictionary = field.get_source_snapshot(node)
	_check(not snapshot.is_empty(), context + ": source snapshot exists")
	if snapshot.is_empty():
		return
	_check(snapshot["node"] == node and snapshot["state"] == phase, context + ": node and state")
	_close(snapshot["display_radius"], display_radius, context + ": display radius")
	_close(snapshot["brightness"], brightness, context + ": brightness")
	_close(snapshot["disconnected_seconds"], seconds, context + ": disconnected seconds")
	var effective: float = display_radius if bool(snapshot["connected"]) else 0.0
	_close(snapshot["effective_radius"], effective, context + ": effective snapshot radius")
	_close(field.get_effective_radius(node), effective, context + ": effective query radius")


func _test_growth_and_initial_disconnect() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var growing: Node2D = _new_source(world)
	var disconnected: Node2D = _new_source(world, Vector2(600.0, 0.0))
	field.set_sources([_source(growing), _source(disconnected, false)])
	_check_source(field, growing, &"growing", 0.0, 1.0, 0.0, "New connected source")
	_check_source(field, disconnected, &"gone", 0.0, 0.0, 0.0, "Initial disconnected source")
	_check(field._get_remnant_discs().is_empty(), "Initially disconnected node invented a ghost")
	field.advance(0.5)
	_check_source(field, growing, &"growing", 50.0, 1.0, 0.0, "Partial initial growth")
	_check_source(field, disconnected, &"gone", 0.0, 0.0, 0.5, "Initial disconnected clock")
	field.advance(1.5)
	_check_source(field, growing, &"mature", 200.0, 1.0, 0.0, "Initial mature source")
	_check(not field.is_covered(disconnected.global_position)
		and field.get_collection_node(disconnected.global_position) == null,
		"Initially disconnected source was collectable")
	field.set_sources([_source(growing), _source(disconnected)])
	_check_source(field, disconnected, &"recovering", 0.0, 0.0, 0.0, "First connection after absence")
	field.advance(0.5)
	_check_source(field, disconnected, &"recovering", 50.0, 0.25, 0.0, "First connection restores gradually")
	world.free()


func _test_exact_grace_and_decay() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	field.set_sources([_source(node)])
	field.advance(2.0)
	field.set_sources([_source(node, false)])
	_check_source(field, node, &"grace", 200.0, 1.0, 0.0, "Disconnect instant")
	_check(not field.is_covered(Vector2(100.0, 0.0))
		and field.get_collecting_nodes(Vector2.ZERO).is_empty()
		and field.get_collection_node(Vector2.ZERO) == null,
		"Size grace retained harvest coverage")
	_check(field._get_draw_discs().is_empty() and field._get_remnant_discs().size() == 1,
		"Disconnected disc was not separated from active geometry")
	_check(FungalField.REMNANT_FILL_COLOR.r == FungalField.REMNANT_FILL_COLOR.g
		and FungalField.REMNANT_FILL_COLOR.g == FungalField.REMNANT_FILL_COLOR.b
		and FungalField.REMNANT_BOUNDARY_COLOR.r == FungalField.REMNANT_BOUNDARY_COLOR.g
		and FungalField.REMNANT_BOUNDARY_COLOR.g == FungalField.REMNANT_BOUNDARY_COLOR.b
		and FungalField.REMNANT_DASH_RATIO > 0.0 and FungalField.REMNANT_DASH_RATIO < 1.0,
		"Remnant style did not provide grey separated dashes")
	field.advance(4.999)
	_check_source(field, node, &"grace", 200.0, 1.0, 4.999, "Immediately before grace boundary")
	field.advance(0.001)
	_check_source(field, node, &"decaying", 200.0, 1.0, 5.0, "Exact five-second boundary")
	field.advance(2.5)
	_check_source(field, node, &"decaying", 150.0, 0.75, 7.5, "Quarter of decay")
	field.advance(5.0)
	_check_source(field, node, &"decaying", 50.0, 0.25, 12.5, "Three quarters of decay")
	field.advance(2.5)
	_check_source(field, node, &"gone", 0.0, 0.0, 15.0, "Exact fifteen-second endpoint")
	_check(field._get_remnant_discs().is_empty(), "Fully decayed source retained a visible ghost")
	field.advance(20.0)
	_check_source(field, node, &"gone", 0.0, 0.0, 35.0, "Past decay endpoint")
	world.free()


func _test_repeated_loss_snapshots_and_partial_baseline() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	field.set_sources([_source(node)])
	field.advance(0.7)
	var loss: Array[Dictionary] = [_source(node, false)]
	field.set_sources(loss)
	for second: int in range(10):
		field.set_sources(loss)
		field.set_sources([_source(node, false), _source(node)])
		field.advance(1.0)
		var elapsed: float = float(second + 1)
		var expected_radius: float = 70.0 if elapsed <= 5.0 else 70.0 * (15.0 - elapsed) / 10.0
		var expected_brightness: float = 1.0 if elapsed <= 5.0 else (15.0 - elapsed) / 10.0
		var phase: StringName = &"grace" if elapsed < 5.0 else &"decaying"
		_check_source(field, node, phase, expected_radius, expected_brightness, elapsed,
			"Repeated loss snapshot at second " + str(second + 1))
	_check_source(field, node, &"decaying", 35.0, 0.5, 10.0, "Loss baseline was partial growth")
	field.node_radius = 500.0
	field.set_sources([_source(node, false, 10.0)])
	_check_source(field, node, &"decaying", 35.0, 0.5, 10.0, "Lost target edit retains loss baseline")
	field.advance(1.0)
	_check_source(field, node, &"decaying", 28.0, 0.4, 11.0, "Lost target edit continues original decay")
	field.set_sources([_source(node, true, 100.0), _source(node, false)])
	_check_source(field, node, &"recovering", 28.0, 0.4, 0.0, "First duplicate record wins on recovery")
	world.free()


func _test_midway_recovery_and_repeated_snapshots() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	field.set_sources([_source(node)])
	field.advance(2.0)
	field.set_sources([_source(node, false)])
	field.advance(10.0)
	_check_source(field, node, &"decaying", 100.0, 0.5, 10.0, "Half-decayed source")
	var restored: Array[Dictionary] = [_source(node)]
	field.set_sources(restored)
	_check_source(field, node, &"recovering", 100.0, 0.5, 0.0, "Midway reconnect instant")
	_check(field.is_covered(Vector2(100.0, 0.0)) and not field.is_covered(Vector2(100.25, 0.0))
		and field.get_collection_node(Vector2(80.0, 0.0)) == node,
		"Reconnect did not use the retained radius as active coverage")
	field.set_sources(restored)
	field.advance(0.25)
	_check_source(field, node, &"recovering", 125.0, 0.625, 0.0, "First recovery step")
	field.set_sources(restored)
	field.advance(0.25)
	_check_source(field, node, &"recovering", 150.0, 0.75, 0.0, "Repeated reconnect snapshot")
	field.set_sources(restored)
	field.advance(0.5)
	_check_source(field, node, &"mature", 200.0, 1.0, 0.0, "Recovery reaches both targets")
	field.advance(100.0)
	_check_source(field, node, &"mature", 200.0, 1.0, 0.0, "Recovery does not overshoot")
	world.free()


func _test_recovery_before_grace_and_after_gone() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	field.set_sources([_source(node)])
	field.advance(0.6)
	field.set_sources([_source(node, false)])
	field.advance(4.0)
	field.set_sources([_source(node)])
	_check_source(field, node, &"recovering", 60.0, 1.0, 0.0, "Reconnect during grace")
	field.advance(0.5)
	_check_source(field, node, &"recovering", 110.0, 1.0, 0.0, "Grace reconnect resumes expansion")
	field.advance(0.9)
	_check_source(field, node, &"mature", 200.0, 1.0, 0.0, "Grace reconnect matures normally")
	field.set_sources([_source(node, false)])
	field.advance(5.0)
	field.set_sources([_source(node)])
	_check_source(field, node, &"recovering", 200.0, 1.0, 0.0, "Full-size reconnect reports recovery first")
	field.advance(0.0)
	_check_source(field, node, &"recovering", 200.0, 1.0, 0.0, "Zero delta does not advance recovery")
	field.advance(0.01)
	_check_source(field, node, &"mature", 200.0, 1.0, 0.0, "Already full recovery completes on advance")
	field.set_sources([_source(node, false)])
	field.advance(15.0)
	field.set_sources([_source(node)])
	_check_source(field, node, &"recovering", 0.0, 0.0, 0.0, "Reconnect after complete decay")
	field.advance(1.0)
	_check_source(field, node, &"recovering", 100.0, 0.5, 0.0, "Dark source after one second")
	field.advance(0.999)
	_check_source(field, node, &"recovering", 199.9, 0.9995, 0.0, "Immediately before full dark recovery")
	field.advance(0.001)
	_check_source(field, node, &"mature", 200.0, 1.0, 0.0, "Dark brightness restores in exactly two seconds")
	world.free()


func _test_brightness_and_radius_recover_independently() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var slow: Node2D = _new_source(world)
	var fast: Node2D = _new_source(world, Vector2(600.0, 0.0))
	field.set_sources([_source(slow), _source(fast, true, 40.0)])
	field.advance(2.0)
	field.set_sources([_source(slow, false), _source(fast, false, 40.0)])
	field.expansion_speed = 0.0
	field.advance(15.0)
	_check_source(field, slow, &"gone", 0.0, 0.0, 15.0, "Decay ignores disabled expansion")
	field.set_sources([_source(slow), _source(fast, true, 40.0)])
	field.advance(1.0)
	_check_source(field, slow, &"recovering", 0.0, 0.5, 0.0, "Brightness recovers with zero expansion")
	field.expansion_speed = 20.0
	field.advance(1.0)
	_check_source(field, slow, &"recovering", 20.0, 1.0, 0.0, "Slow radius remains recovering after full brightness")
	_check_source(field, fast, &"recovering", 20.0, 1.0, 0.0, "Smaller target still awaits radius")
	field.advance(1.0)
	_check_source(field, fast, &"mature", 40.0, 1.0, 0.0, "Smaller target completes first")
	field.set_sources([_source(slow), _source(fast, false, 40.0)])
	field.advance(15.0)
	field.expansion_speed = 400.0
	field.set_sources([_source(slow), _source(fast, true, 40.0)])
	field.advance(0.1)
	_check_source(field, fast, &"recovering", 40.0, 0.05, 0.0, "Full radius awaits brightness")
	field.advance(1.9)
	_check_source(field, fast, &"mature", 40.0, 1.0, 0.0, "Full radius finishes brightness restoration")
	world.free()


func _test_second_loss_uses_current_recovery_baseline() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	field.set_sources([_source(node)])
	field.advance(2.0)
	field.set_sources([_source(node, false)])
	field.advance(10.0)
	field.set_sources([_source(node)])
	field.advance(0.5)
	field.set_sources([_source(node, false)])
	_check_source(field, node, &"grace", 150.0, 0.75, 0.0, "Second loss captures current recovery")
	field.advance(10.0)
	_check_source(field, node, &"decaying", 75.0, 0.375, 10.0, "Second loss halves its new baseline")
	field.set_sources([_source(node)])
	_check_source(field, node, &"recovering", 75.0, 0.375, 0.0, "Second reconnect retains second remnant")
	world.free()


func _test_active_overlap_and_union() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world, 100.0)
	var lost: Node2D = _new_source(world)
	var active: Node2D = _new_source(world, Vector2(80.0, 0.0))
	var other_active: Node2D = _new_source(world, Vector2(130.0, 0.0))
	field.set_sources([_source(lost), _source(active), _source(other_active)])
	field.advance(1.0)
	field.set_sources([_source(lost, false), _source(active), _source(other_active)])
	_check(field.get_visual_snapshot().size() == 3 and field._get_remnant_discs().size() == 1
		and field._get_draw_discs().size() == 2, "Active and remnant visual layers were mixed")
	_check(not field.is_covered(Vector2(-50.0, 0.0))
		and field.get_collection_node(Vector2(-50.0, 0.0)) == null,
		"Lost-only remnant was effective")
	_check(field.is_covered(Vector2(40.0, 0.0))
		and field.get_collecting_nodes(Vector2(40.0, 0.0)) == [active, other_active],
		"Lost overlap removed or polluted active alternative collectors")
	_check(field.get_collection_node(Vector2(40.0, 0.0)) == active,
		"Lost source remained nearest collector")
	var discs: Array[Dictionary] = field._get_draw_discs()
	for index: int in range(discs.size()):
		var angle_sum: float = 0.0
		for arc: Vector2 in field._get_exposed_arcs(index, discs):
			angle_sum += arc.y - arc.x
			var center: Vector2 = discs[index]["center"]
			var radius: float = discs[index]["radius"]
			var angle: float = (arc.x + arc.y) * 0.5
			var point: Vector2 = center + Vector2(cos(angle), sin(angle)) * radius
			var other_center: Vector2 = discs[1 - index]["center"]
			_check(point.distance_to(other_center) >= radius - 0.001,
				"Active union retained an internal outline after loss")
		_check(angle_sum > 0.0 and angle_sum < TAU, "Active overlap lost its exposed union arcs")
	field.advance(10.0)
	_check(field.get_collecting_nodes(Vector2(40.0, 0.0)) == [active, other_active],
		"Shrinking ghost changed active union collection")
	active.global_position = lost.global_position
	field.set_sources([_source(lost, false), _source(active)])
	_check(field.is_covered(Vector2(100.0, 0.0)) and field.get_collection_node(Vector2.ZERO) == active,
		"Coincident active source lost coverage behind a remnant")
	world.free()


func _test_active_fill_order_and_coincident_brightness() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world, 100.0, 1000.0)
	var recovering: Node2D = _new_source(world)
	var mature: Node2D = _new_source(world, Vector2(60.0, 0.0))
	field.set_sources([_source(recovering), _source(mature)])
	field.advance(1.0)
	field.set_sources([_source(recovering, false), _source(mature)])
	field.advance(15.0)
	field.set_sources([_source(recovering), _source(mature)])
	field.advance(0.1)
	_check_source(field, recovering, &"recovering", 100.0, 0.05, 0.0,
		"Full dim source overlaps mature coverage")
	for reverse_order: bool in [false, true]:
		var snapshots: Array[Dictionary] = [_source(recovering), _source(mature)]
		if reverse_order:
			snapshots.reverse()
		field.set_sources(snapshots)
		var discs: Array[Dictionary] = field._get_draw_discs()
		var original_first: Node2D = discs[0]["node"]
		var fills: Array[Dictionary] = field._get_fill_discs(discs)
		_check(fills[0]["node"] == recovering and fills[1]["node"] == mature,
			"Dim fill can paint over mature coverage after source reorder")
		_check(discs[0]["node"] == original_first,
			"Fill ordering mutated the query geometry container")
		_check(field.get_collecting_nodes(Vector2(40.0, 0.0)) == [mature, recovering],
			"Fill ordering changed collector distance ordering")
	mature.global_position = recovering.global_position
	var discs: Array[Dictionary] = field._get_draw_discs()
	var boundary_count: int = 0
	for index: int in range(discs.size()):
		var arcs: Array[Vector2] = field._get_exposed_arcs(index, discs)
		if not arcs.is_empty():
			boundary_count += 1
			_check(discs[index]["node"] == mature and arcs.size() == 1
				and is_equal_approx(arcs[0].y - arcs[0].x, TAU),
				"Dim coincident source suppressed a mature active boundary")
	_check(boundary_count == 1, "Coincident active circles produced duplicate outlines")
	field.advance(1.9)
	var first_id: int = mini(recovering.get_instance_id(), mature.get_instance_id())
	for reverse_order: bool in [false, true]:
		var snapshots: Array[Dictionary] = [_source(recovering), _source(mature)]
		if reverse_order:
			snapshots.reverse()
		field.set_sources(snapshots)
		var fills: Array[Dictionary] = field._get_fill_discs(field._get_draw_discs())
		_check(int(fills[0]["instance_id"]) == first_id,
			"Equal-brightness active fill order was nondeterministic")
	world.free()


func _test_removal_and_deletion() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var removed: Node2D = _new_source(world)
	var queued: Node2D = _new_source(world, Vector2(600.0, 0.0))
	var freed: Node2D = _new_source(world, Vector2(1200.0, 0.0))
	field.set_sources([_source(removed), _source(queued), _source(freed)])
	field.advance(2.0)
	field.set_sources([_source(removed, false), _source(queued, false), _source(freed, false)])
	field.set_sources([_source(queued, false), _source(freed, false)])
	_check(field.get_source_snapshot(removed).is_empty() and field._get_remnant_discs().size() == 2,
		"Snapshot removal kept a ghost or state")
	field.set_sources([_source(removed), _source(queued, false), _source(freed, false)])
	_check_source(field, removed, &"growing", 0.0, 1.0, 0.0, "Reinserted source starts fresh")
	var stale: Array[Dictionary] = [_source(removed), _source(queued, false), _source(freed, false)]
	queued.queue_free()
	_check(field.get_source_snapshot(queued).is_empty() and field.get_visual_snapshot().size() == 2
		and field._get_remnant_discs().size() == 1,
		"Queue deletion did not immediately erase visual remnant")
	freed.free()
	_check(not is_instance_valid(freed) and field.get_visual_snapshot().size() == 1
		and field._get_remnant_discs().is_empty(), "Immediate free retained a visual remnant")
	field.set_sources(stale)
	_check(field.get_visual_snapshot().size() == 1, "Stale snapshot resurrected invalid sources")
	await process_frame
	_check(not is_instance_valid(queued), "Queue-deleted source was not freed")
	field.set_sources(stale)
	_check(field.get_visual_snapshot().size() == 1, "Freed stale snapshot was accepted")
	field.advance(0.5)
	field.set_sources([])
	_check(field.get_visual_snapshot().is_empty() and field._get_draw_discs().is_empty()
		and field._get_remnant_discs().is_empty(), "Empty snapshot retained visual or effective coverage")
	world.free()


func _test_world_transforms_and_movement() -> void:
	var world: Node2D = _new_world()
	world.position = Vector2(300.0, -100.0)
	world.rotation = 0.37
	world.scale = Vector2(1.5, 0.7)
	var field: FungalField = _new_field(world, 80.0, 80.0)
	field.position = Vector2(-90.0, 45.0)
	field.rotation = -0.6
	field.scale = Vector2(-0.45, 2.3)
	field.skew = 0.2
	var parent: Node2D = Node2D.new()
	world.add_child(parent)
	parent.position = Vector2(120.0, 75.0)
	parent.rotation = 0.4
	parent.scale = Vector2(2.0, 0.5)
	var node: Node2D = Node2D.new()
	parent.add_child(node)
	node.position = Vector2(30.0, -25.0)
	node.scale = Vector2(3.0, 0.2)
	field.set_sources([_source(node)])
	field.advance(1.0)
	field.set_sources([_source(node, false)])
	field.advance(10.0)
	_check_source(field, node, &"decaying", 40.0, 0.5, 10.0, "Transformed remnant uses world radius")
	var center: Vector2 = node.global_position
	var remnant: Dictionary = field._get_remnant_discs()[0]
	_check(remnant["center"].is_equal_approx(center), "Transformed remnant used local center")
	_close(remnant["radius"], 40.0, "Transformed remnant radius was scaled")
	_check_world_draw_transform(field, center, 40.0, "Remnant world transform cancellation")
	node.position += Vector2(50.0, 25.0)
	remnant = field._get_remnant_discs()[0]
	_check(remnant["center"].is_equal_approx(node.global_position)
		and not remnant["center"].is_equal_approx(center), "Remnant retained a stale moved center")
	field.position += Vector2(400.0, -100.0)
	world.position += Vector2(120.0, 30.0)
	center = node.global_position
	field.set_sources([_source(node)])
	_check(field.is_covered(center + Vector2(40.0, 0.0))
		and not field.is_covered(center + Vector2(40.25, 0.0)),
		"Transformed recovery did not use world radius")
	field.advance(0.25)
	_check_source(field, node, &"recovering", 60.0, 0.625, 0.0, "Transformed recovery continues world expansion")
	_check(field.get_collection_node(center + Vector2(60.0, 0.0)) == node,
		"Transformed recovered boundary was not collectable")
	_check_world_draw_transform(field, center, 60.0, "Moved recovery world transform cancellation")
	world.free()


func _test_invalid_delta_and_configuration() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	field.set_sources([_source(node)])
	field.advance(2.0)
	field.set_sources([_source(node, false)])
	field.advance(8.0)
	var before: Dictionary = field.get_source_snapshot(node)
	var invalid_deltas: Array[float] = [0.0, -1.0, NAN, INF, -INF]
	for delta: float in invalid_deltas:
		field.advance(delta)
		_check(field.get_source_snapshot(node) == before, "Invalid delta changed remnant or loss clock")
	field.set_sources([_source(node)])
	before = field.get_source_snapshot(node)
	for delta: float in invalid_deltas:
		field.advance(delta)
		_check(field.get_source_snapshot(node) == before, "Invalid delta changed recovery")
	var invalid_speeds: Array[float] = [-1.0, NAN, INF, -INF, 1.0e100]
	for speed: float in invalid_speeds:
		field.expansion_speed = speed
		_close(field.expansion_speed, 0.0, "Invalid expansion configuration was accepted")
		field.advance(0.01)
		_close(field.get_effective_radius(node), 140.0, "Invalid expansion changed radius")
	field.expansion_speed = 100.0
	var invalid_radii: Array[float] = [-1.0, NAN, INF, -INF, 1.0e100]
	for radius: float in invalid_radii:
		field.set_sources([_source(node, true, radius)])
		field.advance(1.0)
		_close(field.get_effective_radius(node), 0.0, "Invalid override radius was collectable")
		_check(not field.is_covered(Vector2.ZERO), "Invalid override covered its center")
	field.core_radius = NAN
	field.node_radius = -1.0
	_check(field.core_radius == 0.0 and field.node_radius == 0.0,
		"Invalid default configuration was accepted")
	field.node_radius = 200.0
	field.set_sources([_source(node)])
	field.advance(2.0)
	field.set_sources([_source(node, false)])
	field.advance(1.0e308)
	field.advance(1.0e308)
	var snapshot: Dictionary = field.get_source_snapshot(node)
	_check(snapshot["state"] == &"gone" and is_finite(snapshot["disconnected_seconds"]),
		"Huge finite delta overflowed the loss clock")
	field.set_sources([_source(node)])
	field.advance(1.0e308)
	_check_source(field, node, &"mature", 200.0, 1.0, 0.0, "Huge finite recovery delta clamps safely")
	_check(field.get_source_snapshot(null).is_empty(), "Null source returned a visual snapshot")
	_check(not field.is_covered(Vector2(INF, 0.0))
		and field.get_collecting_nodes(Vector2(NAN, 0.0)).is_empty(), "Nonfinite point was collectable")
	world.free()


func _test_snapshot_queries_are_pure() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var node: Node2D = _new_source(world)
	node.set_meta(&"nutrition", 17)
	field.set_sources([_source(node)])
	field.advance(2.0)
	var input: Array[Dictionary] = [_source(node, false)]
	field.set_sources(input)
	field.advance(8.0)
	var before: Dictionary = field.get_source_snapshot(node)
	input[0]["connected"] = true
	input[0]["radius"] = 1.0
	_check(field.get_source_snapshot(node) == before, "Caller input mutation changed internal state")
	for query: int in range(5):
		var single: Dictionary = field.get_source_snapshot(node)
		var visuals: Array[Dictionary] = field.get_visual_snapshot()
		_check(single == before and visuals.size() == 1 and visuals[0] == before,
			"Snapshot reads changed internal state on query " + str(query))
		single["connected"] = true
		single["display_radius"] = 999.0
		single["brightness"] = 99.0
		single.clear()
		visuals[0]["node"] = null
		visuals[0]["state"] = &"mature"
		visuals[0]["disconnected_seconds"] = 0.0
		visuals.clear()
		field.get_effective_radius(node)
		field.is_covered(Vector2.ZERO)
		field.get_collecting_nodes(Vector2.ZERO)
		field.get_collection_node(Vector2.ZERO)
		field._get_draw_discs()
		field._get_remnant_discs()
		_check(field.get_source_snapshot(node) == before, "Snapshot mutation leaked into field state")
	_check(node.get_meta(&"nutrition") == 17, "Field queries mutated source resources")
	field.advance(1.0)
	_check_source(field, node, &"decaying", 120.0, 0.6, 9.0, "Pure reads did not reset loss baseline")
	world.free()
