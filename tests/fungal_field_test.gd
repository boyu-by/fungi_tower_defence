extends SceneTree
## 独立验证覆盖扩张、唯一采集候选和绘制所使用的世界空间几何。
## 采集候选是互相替代的选择，不会领取资源或成为多个资源所有者。

const FIELD_SCRIPT: Script = preload("res://scripts/fungal_field.gd")

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_default_boundaries()
	_test_configured_boundaries()
	_test_expansion_and_snapshots()
	_test_unique_collectors()
	await _test_loss_removal_and_recovery()
	_test_invalid_inputs()
	_test_world_geometry()
	_test_union_boundary()
	_check(root.get_child_count() == 0, "Fixture cleanup left nodes behind")
	print("FUNGAL_FIELD_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_world() -> Node2D:
	var world: Node2D = Node2D.new()
	root.add_child(world)
	return world


func _new_field(world: Node2D) -> FungalField:
	var field: FungalField = FIELD_SCRIPT.new() as FungalField
	world.add_child(field)
	# 自动推进会让测试取决于机器帧速，所有增长由测试显式调用。
	field.set_process(false)
	return field


func _new_source(parent: Node2D, world_position: Vector2) -> Node2D:
	var source_node: Node2D = Node2D.new()
	parent.add_child(source_node)
	source_node.global_position = world_position
	return source_node


func _source(node: Node2D, kind: StringName = &"junction", connected: bool = true,
	radius_override: Variant = null) -> Dictionary:
	var snapshot: Dictionary = {"node": node, "kind": kind, "connected": connected}
	if radius_override != null:
		snapshot["radius"] = radius_override
	return snapshot


func _check_disc_queries(field: FungalField, context: String) -> void:
	var discs: Array[Dictionary] = field._get_draw_discs()
	for disc: Dictionary in discs:
		var source_node: Node2D = disc["node"]
		var center: Vector2 = disc["center"]
		var radius: float = disc["radius"]
		_check(center.is_equal_approx(source_node.global_position), context + ": draw world center")
		_check(is_equal_approx(radius, field.get_effective_radius(source_node)),
			context + ": draw and query radius")
		_check(field.get_collecting_nodes(center + Vector2(radius, 0.0)).has(source_node),
			context + ": draw boundary is collectable")
		_check(not field.get_collecting_nodes(center + Vector2(radius + 0.25, 0.0)).has(source_node),
			context + ": collector excludes outside its drawn radius")


func _test_default_boundaries() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var core: Node2D = _new_source(world, Vector2.ZERO)
	var junction: Node2D = _new_source(world, Vector2(500.0, 0.0))
	_check(field.core_radius == 140.0 and field.node_radius == 110.0,
		"Default radii changed")
	_check(field.expansion_speed == 140.0, "Default expansion speed changed")
	field.set_sources([_source(core, &"core"), _source(junction)])
	_check(field.get_effective_radius(core) == 0.0, "New core did not start at zero")
	_check(field.get_effective_radius(junction) == 0.0, "New junction did not start at zero")
	_check(not field.is_covered(core.global_position), "Zero radius covered its center")
	_check(field.get_collection_node(core.global_position) == null,
		"Zero radius provided a collector")
	_check(field._get_draw_discs().is_empty(), "Zero radius produced visible discs")
	field.advance(1.0)
	_check(field.get_effective_radius(core) == 140.0, "Core did not reach default radius")
	_check(field.get_effective_radius(junction) == 110.0, "Junction did not reach default radius")
	_check(field.is_covered(Vector2(140.0, 0.0)), "Default core boundary not covered")
	_check(not field.is_covered(Vector2(140.25, 0.0)), "Outside default core covered")
	_check(field.is_covered(Vector2(610.0, 0.0)), "Default junction boundary not covered")
	_check(not field.is_covered(Vector2(610.25, 0.0)), "Outside default junction covered")
	_check(field.get_collection_node(Vector2(140.0, 0.0)) == core,
		"Boundary query selected wrong default source")
	_check_disc_queries(field, "Default")
	world.free()


func _test_configured_boundaries() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	field.core_radius = 180.0
	field.node_radius = 75.0
	field.expansion_speed = 60.0
	var core: Node2D = _new_source(world, Vector2.ZERO)
	var junction: Node2D = _new_source(world, Vector2(500.0, 0.0))
	var overridden: Node2D = _new_source(world, Vector2(1000.0, 0.0))
	field.set_sources([_source(core, &"core"), _source(junction),
		_source(overridden, &"core", true, 50.0)])
	field.advance(3.0)
	_check(field.get_effective_radius(core) == 180.0, "Configured core radius ignored")
	_check(field.get_effective_radius(junction) == 75.0, "Configured junction radius ignored")
	_check(field.get_effective_radius(overridden) == 50.0, "Snapshot radius override ignored")
	_check(field.is_covered(Vector2(180.0, 0.0)), "Configured core boundary not covered")
	_check(not field.is_covered(Vector2(180.25, 0.0)), "Outside configured core covered")
	_check(field.is_covered(Vector2(575.0, 0.0)), "Configured junction boundary not covered")
	_check(not field.is_covered(Vector2(575.25, 0.0)), "Outside configured junction covered")
	_check(field.is_covered(Vector2(1050.0, 0.0)), "Override boundary not covered")
	_check(not field.is_covered(Vector2(1050.25, 0.0)), "Outside override radius covered")
	field.core_radius = 90.0
	field.node_radius = 0.0
	_check(field.get_effective_radius(core) == 90.0, "Smaller default did not clamp immediately")
	_check(field.get_effective_radius(junction) == 0.0, "Zero default left coverage active")
	_check(not field.is_covered(junction.global_position), "Zero default left junction visible")
	_check(field.get_effective_radius(overridden) == 50.0,
		"Default edit replaced explicit radius override")
	field.core_radius = 190.0
	_check(field.get_effective_radius(core) == 90.0, "Larger default skipped expansion")
	field.advance(0.5)
	_check(field.get_effective_radius(core) == 120.0, "Expansion toward edited default incorrect")
	field.set_sources([_source(core, &"core"), _source(overridden, &"core", true, 25.0)])
	_check(field.get_effective_radius(overridden) == 25.0, "Smaller override did not clamp")
	_check_disc_queries(field, "Configured")
	world.free()


func _test_expansion_and_snapshots() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var core: Node2D = _new_source(world, Vector2.ZERO)
	var snapshot: Array[Dictionary] = [_source(core, &"core")]
	field.set_sources(snapshot)
	field.advance(0.25)
	_check(field.get_effective_radius(core) == 35.0, "Partial expansion incorrect")
	_check(field.is_covered(Vector2(35.0, 0.0)), "Partial expansion boundary uncovered")
	_check(not field.is_covered(Vector2(35.25, 0.0)), "Partial expansion exposed full radius")
	field.set_sources(snapshot)
	_check(field.get_effective_radius(core) == 35.0, "Repeated snapshot reset expansion")
	snapshot[0]["connected"] = false
	snapshot[0]["radius"] = 12.0
	_check(field.get_effective_radius(core) == 35.0,
		"External dictionary mutation changed stored snapshot")
	field.set_sources([_source(core, &"core", true, 80.0)])
	_check(field.get_effective_radius(core) == 35.0, "Radius edit reset existing expansion")
	field.advance(0.25)
	_check(field.get_effective_radius(core) == 70.0, "Second deterministic step incorrect")
	field.advance(20.0)
	_check(field.get_effective_radius(core) == 80.0, "Expansion overshot target radius")
	field.set_sources([_source(core, &"core", true, 80.0), _source(core, &"core", true, 80.0)])
	field.advance(0.0)
	_check(field.get_effective_radius(core) == 80.0, "Duplicate snapshot altered grown radius")
	_check(field._get_draw_discs().size() == 1, "Duplicate snapshot created duplicate draw disc")
	field.set_sources([_source(core, &"core", false)])
	_check(field.get_effective_radius(core) == 0.0, "Disconnect removes collection eligibility immediately")
	field.set_sources([_source(core, &"core")])
	_check(field.get_effective_radius(core) == 80.0, "Reconnect retains the radius displayed during grace")
	field._process(0.125)
	_check(field.get_effective_radius(core) == 97.5, "Process callback grows from the retained display radius")
	_check_disc_queries(field, "Partial expansion")
	world.free()


func _test_unique_collectors() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var left: Node2D = _new_source(world, Vector2.ZERO)
	var right: Node2D = _new_source(world, Vector2(80.0, 0.0))
	var upper: Node2D = _new_source(world, Vector2(0.0, 50.0))
	left.set_meta(&"nutrition", 17)
	right.set_meta(&"nutrition", 23)
	upper.set_meta(&"nutrition", 31)
	field.set_sources([_source(right), _source(left), _source(left), _source(upper), _source(right)])
	field.advance(1.0)
	var candidates: Array[Node2D] = field.get_collecting_nodes(Vector2(10.0, 0.0))
	_check(candidates.size() == 3, "Overlap candidates were not deduplicated")
	_check(candidates == [left, upper, right], "Candidates not ordered by squared distance")
	_check(field.get_collection_node(Vector2(10.0, 0.0)) == left,
		"Unique collection query did not return the nearest candidate")
	var tie_first: Node2D = left if left.get_instance_id() < right.get_instance_id() else right
	var tie_second: Node2D = right if tie_first == left else left
	candidates = field.get_collecting_nodes(Vector2(40.0, 0.0))
	_check(candidates == [tie_first, tie_second, upper], "Equal-distance instance ID tie incorrect")
	field.set_sources([_source(upper), _source(right), _source(left), _source(right)])
	_check(field.get_collecting_nodes(Vector2(40.0, 0.0)) == candidates,
		"Snapshot order changed deterministic candidate order")
	for _query: int in range(4):
		_check(field.get_collection_node(Vector2(40.0, 0.0)) == tie_first,
			"Repeated query changed unique collector")
	_check(left.get_meta(&"nutrition") == 17 and right.get_meta(&"nutrition") == 23
		and upper.get_meta(&"nutrition") == 31,
		"Alternative-candidate query mutated source resources")
	right.global_position = Vector2(1000.0, 0.0)
	_check(field.get_collecting_nodes(Vector2(40.0, 0.0)) == [left, upper],
		"Moved source retained stale candidate position")
	_check(field.get_collection_node(Vector2(5000.0, 0.0)) == null,
		"Uncovered point returned a resource owner")
	_check_disc_queries(field, "Overlap")
	world.free()


func _test_loss_removal_and_recovery() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var core: Node2D = _new_source(world, Vector2.ZERO)
	var junction: Node2D = _new_source(world, Vector2(120.0, 0.0))
	field.set_sources([_source(core, &"core"), _source(junction)])
	field.advance(1.0)
	_check(field.get_collecting_nodes(Vector2(100.0, 0.0)).size() == 2,
		"Initial connected overlap missing")
	field.set_sources([_source(core, &"core", false), _source(junction)])
	_check(field.get_effective_radius(core) == 0.0, "Lost core remained effective")
	_check(not field.is_covered(Vector2(-120.0, 0.0)), "Lost core-only coverage survived")
	_check(field.is_covered(Vector2(130.0, 0.0)), "Connected overlap lost surviving coverage")
	_check(field.get_collection_node(Vector2(100.0, 0.0)) == junction,
		"Disconnected source remained a collector")
	_check(field._get_draw_discs().size() == 1, "Disconnected source remained in active coverage discs")
	field.advance(2.0)
	_check(field.get_effective_radius(core) == 0.0, "Disconnected source expanded")
	field.set_sources([_source(core, &"core"), _source(junction)])
	_check(field.get_effective_radius(core) == 140.0, "Grace-period recovery preserves the existing radius")
	field.advance(0.5)
	_check(field.get_effective_radius(core) == 140.0, "Recovered mature radius does not overshoot")
	_check(field.get_effective_radius(junction) == 110.0, "Recovery reset surviving node")
	field.set_sources([_source(core, &"core")])
	_check(field.get_effective_radius(junction) == 0.0, "Snapshot removal retained source state")
	_check(not field.is_covered(Vector2(200.0, 0.0)), "Removed-only coverage survived beyond the restored core")
	_check(field.is_covered(Vector2(130.0, 0.0)), "Restored core still covers the former overlap")
	field.set_sources([_source(core, &"core"), _source(junction)])
	_check(field.get_effective_radius(junction) == 0.0, "Reinserted source retained deleted radius")
	field.advance(0.1)
	_check(is_equal_approx(field.get_effective_radius(junction), 14.0),
		"Reinserted source expansion incorrect")
	var stale_snapshot: Array[Dictionary] = [_source(core, &"core"), _source(junction)]
	junction.queue_free()
	_check(field.get_effective_radius(junction) == 0.0, "Queued source remained effective")
	_check(not field.get_collecting_nodes(Vector2(120.0, 0.0)).has(junction),
		"Queued source cannot collect within surviving core coverage")
	_check(field._get_draw_discs().size() == 1, "Queued source remained drawn")
	await process_frame
	_check(not is_instance_valid(junction), "Queued fixture source was not freed")
	field.set_sources(stale_snapshot)
	_check(field._get_draw_discs().size() == 1, "Freed snapshot source was accepted")
	_check(field.get_collection_node(Vector2.ZERO) == core, "Freed source harmed surviving core")
	var overlap: Node2D = _new_source(world, Vector2(30.0, 0.0))
	stale_snapshot = [_source(core, &"core"), _source(overlap)]
	field.set_sources(stale_snapshot)
	field.advance(1.0)
	overlap.free()
	_check(field.get_collecting_nodes(Vector2.ZERO) == [core],
		"Immediately freed source remained a collector")
	_check(field.is_covered(Vector2(100.0, 0.0)), "Freeing overlap removed surviving coverage")
	field.set_sources(stale_snapshot)
	var replacement: Node2D = _new_source(world, Vector2(30.0, 0.0))
	field.set_sources([_source(core, &"core"), _source(replacement)])
	_check(field.get_effective_radius(replacement) == 0.0,
		"New instance inherited freed source radius")
	field.advance(0.25)
	_check(field.get_effective_radius(replacement) == 35.0, "Replacement expansion incorrect")
	field.set_sources([])
	_check(field._get_draw_discs().is_empty(), "Empty snapshot retained drawing")
	_check(not field.is_covered(Vector2.ZERO), "Empty snapshot retained coverage")
	_check(field.get_collecting_nodes(Vector2.ZERO).is_empty(), "Empty snapshot retained collectors")
	field.set_sources([_source(core, &"core")])
	_check(field.get_effective_radius(core) == 0.0, "Deleted core state restored on reinsert")
	world.free()


func _test_invalid_inputs() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var source_node: Node2D = _new_source(world, Vector2.ZERO)
	field.set_sources([_source(source_node)])
	field.advance(0.25)
	var invalid_deltas: Array[float] = [0.0, -1.0, NAN, INF, -INF]
	for delta: float in invalid_deltas:
		field.advance(delta)
		_check(field.get_effective_radius(source_node) == 35.0, "Unusable delta changed expansion")
	field.expansion_speed = -1.0
	field.advance(1.0)
	_check(field.expansion_speed == 0.0 and field.get_effective_radius(source_node) == 35.0,
		"Negative expansion speed was not clamped")
	field.expansion_speed = NAN
	_check(field.expansion_speed == 0.0, "NaN expansion speed was not rejected")
	field.expansion_speed = INF
	_check(field.expansion_speed == 0.0, "Infinite expansion speed was not rejected")
	field.expansion_speed = 140.0
	var invalid_radii: Array[float] = [-5.0, 0.0, NAN, INF, -INF, 1.0e100]
	for radius: float in invalid_radii:
		field.set_sources([_source(source_node, &"junction", true, radius)])
		field.advance(1.0)
		_check(field.get_effective_radius(source_node) == 0.0, "Unusable override radius was active")
		_check(not field.is_covered(Vector2.ZERO), "Unusable override covered its center")
		_check(field._get_draw_discs().is_empty(), "Unusable override was drawn")
	field.core_radius = NAN
	field.node_radius = -10.0
	_check(field.core_radius == 0.0 and field.node_radius == 0.0,
		"Unusable default radius was not clamped")
	field.core_radius = INF
	_check(field.core_radius == 0.0, "Infinite default radius was not rejected")
	field.node_radius = 110.0
	field.set_sources([_source(source_node)])
	field.advance(1.0)
	_check(field.get_effective_radius(source_node) == 110.0, "Valid default did not recover")
	_check(not field.is_covered(Vector2(INF, 0.0)), "Nonfinite point was covered")
	_check(field.get_collecting_nodes(Vector2(NAN, 0.0)).is_empty(),
		"Nonfinite point returned collector alternatives")
	_check(field.get_collection_node(Vector2(-INF, 0.0)) == null,
		"Nonfinite point returned a unique collector")
	_check(field.get_effective_radius(null) == 0.0, "Null source had effective radius")
	var invalid_node: Node = Node.new()
	world.add_child(invalid_node)
	field.set_sources([
		{"node": invalid_node, "kind": &"core", "connected": true},
		{"node": null, "kind": &"core", "connected": true},
		{"node": source_node, "kind": &"unknown", "connected": true},
		_source(source_node),
	])
	_check(field.get_effective_radius(source_node) == 110.0,
		"Invalid record prevented later valid record for the same node")
	_check(field._get_draw_discs().size() == 1, "Invalid source records produced drawing")
	field.set_sources([_source(source_node, &"junction", true, "invalid")])
	field.advance(1.0)
	_check(field.get_effective_radius(source_node) == 0.0, "Nonnumeric radius was accepted")
	field.set_sources([{"node": source_node, "kind": &"junction", "connected": "true"}])
	field.advance(1.0)
	_check(field.get_effective_radius(source_node) == 0.0, "Nonboolean connectivity was accepted")
	world.free()


func _test_world_geometry() -> void:
	var world: Node2D = _new_world()
	world.position = Vector2(240.0, -80.0)
	world.rotation = 0.37
	world.scale = Vector2(1.5, 0.7)
	var field: FungalField = _new_field(world)
	field.position = Vector2(-90.0, 45.0)
	field.rotation = -0.6
	field.scale = Vector2(-0.45, 2.3)
	field.skew = 0.2
	field.node_radius = 80.0
	field.expansion_speed = 80.0
	var source_parent: Node2D = Node2D.new()
	world.add_child(source_parent)
	source_parent.position = Vector2(120.0, 75.0)
	source_parent.rotation = 0.4
	source_parent.scale = Vector2(2.0, 0.5)
	var source_node: Node2D = Node2D.new()
	source_parent.add_child(source_node)
	source_node.position = Vector2(30.0, -25.0)
	source_node.scale = Vector2(3.0, 0.2)
	field.set_sources([_source(source_node)])
	field.advance(0.25)
	var center: Vector2 = source_node.global_position
	_check(field.get_effective_radius(source_node) == 20.0, "Source scale changed world radius")
	_check(field.is_covered(center + Vector2(20.0, 0.0)), "Transformed world boundary uncovered")
	_check(not field.is_covered(center + Vector2(20.25, 0.0)),
		"Field scale enlarged logical world radius")
	var draw_world: Transform2D = field.global_transform * field._get_world_draw_transform()
	_check(draw_world.is_equal_approx(Transform2D.IDENTITY),
		"Draw transform did not cancel parent scale, reflection, rotation and skew")
	_check_disc_queries(field, "Transformed")
	source_node.position += Vector2(200.0, 80.0)
	_check(not field.is_covered(center), "Moved source left stale coverage")
	center = source_node.global_position
	_check(field.get_collection_node(center) == source_node, "Moved source lost current coverage")
	_check_disc_queries(field, "Moved source")
	field.position += Vector2(300.0, -200.0)
	_check(field.is_covered(center + Vector2(20.0, 0.0)), "Field movement moved logical coverage")
	draw_world = field.global_transform * field._get_world_draw_transform()
	_check(draw_world.is_equal_approx(Transform2D.IDENTITY), "Moved field used stale draw transform")
	world.position += Vector2(100.0, 30.0)
	_check(not field.is_covered(center), "Moved common parent left stale coverage")
	_check_disc_queries(field, "Moved common parent")
	world.free()


func _check_exposed_arcs(field: FungalField, discs: Array[Dictionary]) -> void:
	for index: int in range(discs.size()):
		var disc: Dictionary = discs[index]
		var center: Vector2 = disc["center"]
		var radius: float = disc["radius"]
		for arc: Vector2 in field._get_exposed_arcs(index, discs):
			_check(arc.y > arc.x, "Union boundary contains reversed or empty arc")
			for sample: int in range(5):
				var angle: float = lerpf(arc.x, arc.y, (float(sample) + 0.5) / 5.0)
				var point: Vector2 = center + Vector2(cos(angle), sin(angle)) * radius
				for other_index: int in range(discs.size()):
					if other_index == index:
						continue
					var other_center: Vector2 = discs[other_index]["center"]
					var other_radius: float = discs[other_index]["radius"]
					_check(point.distance_to(other_center) >= other_radius - 0.001,
						"Union renderer kept an internal circular outline")


func _test_union_boundary() -> void:
	var world: Node2D = _new_world()
	var field: FungalField = _new_field(world)
	var left: Node2D = _new_source(world, Vector2.ZERO)
	var right: Node2D = _new_source(world, Vector2(90.0, 0.0))
	field.set_sources([_source(left, &"junction", true, 100.0),
		_source(right, &"junction", true, 100.0)])
	field.advance(1.0)
	_check(FungalField.FILL_COLOR.a == 1.0, "Overlap fill can accumulate brightness")
	var discs: Array[Dictionary] = field._get_draw_discs()
	for index: int in range(discs.size()):
		var visible_angle: float = 0.0
		for arc: Vector2 in field._get_exposed_arcs(index, discs):
			visible_angle += arc.y - arc.x
		_check(visible_angle > 0.0 and visible_angle < TAU - 0.001,
			"Overlapping disc retained complete circle outline")
	_check_exposed_arcs(field, discs)
	right.global_position = Vector2.ZERO
	var inner: Node2D = _new_source(world, Vector2.ZERO)
	field.set_sources([_source(right, &"junction", true, 100.0),
		_source(inner, &"junction", true, 30.0), _source(left, &"junction", true, 100.0)])
	field.advance(1.0)
	discs = field._get_draw_discs()
	var boundary_count: int = 0
	var boundary_angle: float = 0.0
	for index: int in range(discs.size()):
		var arcs: Array[Vector2] = field._get_exposed_arcs(index, discs)
		if not arcs.is_empty():
			boundary_count += 1
		for arc: Vector2 in arcs:
			boundary_angle += arc.y - arc.x
	_check(boundary_count == 1 and is_equal_approx(boundary_angle, TAU),
		"Coincident or contained discs produced internal or double boundary")
	_check(field.get_collecting_nodes(Vector2.ZERO).size() == 3,
		"Union drawing incorrectly collapsed distinct alternative collectors")
	_check_exposed_arcs(field, discs)
	field.set_sources([_source(left, &"junction", false, 100.0),
		_source(right, &"junction", true, 100.0), _source(inner, &"junction", true, 30.0)])
	_check(field.is_covered(Vector2(100.0, 0.0)), "Coincident surviving disc lost its boundary")
	_check(field.get_collection_node(Vector2(100.0, 0.0)) == right,
		"Coincident disconnected disc retained collection ownership")
	_check_exposed_arcs(field, field._get_draw_discs())
	world.free()
