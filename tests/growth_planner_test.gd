extends SceneTree
## 独立验证纯直线规划及费用；无需关卡、场景节点、输入或物理帧。

const Planner = preload("res://scripts/growth_planner.gd")
const EPSILON: float = 0.0001
const PLAN_KEYS: Array[String] = [
	"valid", "error", "start_position", "end_position", "distance", "segments",
	"junction_positions", "extension_cost", "junction_cost", "total_cost",
]
const SEGMENT_KEYS: Array[String] = [
	"start_position", "end_position", "length", "cumulative_distance",
	"extension_cost", "junction_cost", "total_cost",
]

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_defaults_and_boundaries()
	_test_positions()
	_test_existing_endpoints()
	_test_cost_distribution_and_configuration()
	_test_invalid_inputs()
	_test_limits()
	print("GROWTH_PLANNER_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _assert_plan(
	planner: Planner,
	result: Dictionary,
	description: String,
	start_position: Vector2,
	end_position: Vector2,
	expected_counts: Vector2i,
	expected_segments: int,
	endpoint_exists: bool = false
) -> void:
	_check(result.has_all(PLAN_KEYS), description + ": result keys")
	if not result.has_all(PLAN_KEYS):
		return
	_check(result.size() == PLAN_KEYS.size(), description + ": exact result contract")
	_check(result["valid"] == true and result["error"] == "", description + ": valid result")
	_check(result["start_position"] == start_position, description + ": exact starting coordinates")
	_check(result["end_position"] == end_position, description + ": exact target coordinates")
	_check(typeof(result["valid"]) == TYPE_BOOL, description + ": boolean validity")
	_check(typeof(result["error"]) == TYPE_STRING, description + ": string error")
	_check(typeof(result["distance"]) == TYPE_FLOAT, description + ": float distance")
	_check(typeof(result["junction_positions"]) == TYPE_PACKED_VECTOR2_ARRAY,
		description + ": packed junction coordinates")
	_check(typeof(result["extension_cost"]) == TYPE_INT, description + ": integer extension cost")
	_check(typeof(result["junction_cost"]) == TYPE_INT, description + ": integer junction cost")
	_check(typeof(result["total_cost"]) == TYPE_INT, description + ": integer total cost")
	var segments: Array[Dictionary] = result["segments"]
	var junction_positions: PackedVector2Array = result["junction_positions"]
	_check(segments.is_typed() and segments.get_typed_builtin() == TYPE_DICTIONARY,
		description + ": typed segment array")
	_check(segments.size() == expected_segments, description + ": segment count")
	_check(junction_positions.size() == expected_counts.y, description + ": new junction count")
	_check(result["extension_cost"] == expected_counts.x, description + ": extension total")
	_check(result["junction_cost"] == expected_counts.y * planner.junction_cost,
		description + ": junction total")
	_check(result["total_cost"] == expected_counts.x + expected_counts.y * planner.junction_cost,
		description + ": overall total")

	var previous_position: Vector2 = start_position
	var cumulative_length: float = 0.0
	var extension_sum: int = 0
	var junction_sum: int = 0
	var cost_sum: int = 0
	var expected_positions: PackedVector2Array = PackedVector2Array()
	for segment_index: int in range(segments.size()):
		var segment: Dictionary = segments[segment_index]
		_check(segment.has_all(SEGMENT_KEYS), description + ": segment keys")
		if not segment.has_all(SEGMENT_KEYS):
			continue
		_check(segment.size() == SEGMENT_KEYS.size(), description + ": exact segment contract")
		var segment_end: Vector2 = segment["end_position"]
		var segment_length: float = segment["length"]
		var cumulative_distance: float = segment["cumulative_distance"]
		var extension_cost: int = segment["extension_cost"]
		var end_junction_cost: int = segment["junction_cost"]
		_check(segment["start_position"] == previous_position, description + ": connected segment chain")
		_check(segment_length > 0.0, description + ": positive segment length")
		_check(_near(previous_position.distance_to(segment_end), segment_length),
			description + ": geometric segment length")
		_check(extension_cost >= 0, description + ": nonnegative segment extension")
		var existing_end: bool = endpoint_exists and segment_index == segments.size() - 1
		_check(end_junction_cost == (0 if existing_end else planner.junction_cost),
			description + ": segment endpoint fee")
		_check(segment["total_cost"] == extension_cost + end_junction_cost,
			description + ": segment fee sum")
		cumulative_length += segment_length
		_check(_near(cumulative_distance, cumulative_length), description + ": cumulative distance")
		if segment_index < segments.size() - 1:
			_check(cumulative_distance < float(result["distance"]),
				description + ": junction strictly before target")
			_check(_near(cumulative_distance, float(segment_index + 1) * planner.junction_spacing),
				description + ": configured junction spacing")
		if not existing_end:
			expected_positions.append(segment_end)
		previous_position = segment_end
		extension_sum += extension_cost
		junction_sum += end_junction_cost
		cost_sum += int(segment["total_cost"])
	_check(previous_position == end_position, description + ": chain reaches exact target")
	_check(_near(cumulative_length, float(result["distance"])), description + ": length sum")
	_check(extension_sum == result["extension_cost"], description + ": authoritative extension sum")
	_check(junction_sum == result["junction_cost"], description + ": authoritative junction sum")
	_check(cost_sum == result["total_cost"], description + ": authoritative cost sum")
	_check(junction_positions == expected_positions, description + ": only new segment endpoints")
	var seen_positions: Dictionary = {}
	for junction_position: Vector2 in junction_positions:
		_check(junction_position != start_position, description + ": existing start is free")
		_check(not seen_positions.has(junction_position), description + ": no duplicate junctions")
		if endpoint_exists:
			_check(junction_position != end_position, description + ": existing endpoint is free")
		seen_positions[junction_position] = true


func _assert_invalid(result: Dictionary, description: String) -> void:
	_check(result.has_all(PLAN_KEYS), description + ": invalid result keys")
	if not result.has_all(PLAN_KEYS):
		return
	_check(result["valid"] == false, description + ": rejected")
	_check(typeof(result["error"]) == TYPE_STRING and not String(result["error"]).is_empty(),
		description + ": descriptive error")
	var segments: Array[Dictionary] = result["segments"]
	var junction_positions: PackedVector2Array = result["junction_positions"]
	_check(segments.is_empty() and junction_positions.is_empty(), description + ": empty failure plan")
	_check(result["distance"] == 0.0, description + ": zero failure distance")
	_check(result["extension_cost"] == 0 and result["junction_cost"] == 0 and result["total_cost"] == 0,
		description + ": zero failure fees")


func _test_defaults_and_boundaries() -> void:
	var planner: Planner = Planner.new()
	_check(planner is Resource, "Planner is a Resource")
	_check(planner.junction_cost == 4 and planner.extension_unit_length == 80.0
		and planner.junction_spacing == 120.0, "Default configuration")
	var point: Vector2 = Vector2(37.25, -14.5)
	_assert_plan(planner, planner.plan(point, point), "Zero distance", point, point, Vector2i.ZERO, 0)
	_assert_plan(planner, planner.plan(point, point, true), "Zero existing endpoint",
		point, point, Vector2i.ZERO, 0, true)
	var short_end: Vector2 = Vector2(1.0, 0.0)
	_assert_plan(planner, planner.plan(Vector2.ZERO, short_end), "Short branch",
		Vector2.ZERO, short_end, Vector2i(1, 1), 1)
	var tiny_end: Vector2 = Vector2(0.000001, 0.0)
	_assert_plan(planner, planner.plan(Vector2.ZERO, tiny_end), "Positive tiny branch",
		Vector2.ZERO, tiny_end, Vector2i(1, 1), 1)

	var extension_distances: Array[float] = [79.99, 80.0, 80.01]
	var expected_extensions: Array[int] = [1, 1, 2]
	for index: int in range(extension_distances.size()):
		var target: Vector2 = Vector2(extension_distances[index], 0.0)
		_assert_plan(planner, planner.plan(Vector2.ZERO, target), "80 boundary %s" % extension_distances[index],
			Vector2.ZERO, target, Vector2i(expected_extensions[index], 1), 1)
	var junction_distances: Array[float] = [119.99, 120.0, 120.01]
	var expected_junctions: Array[int] = [1, 1, 2]
	for index: int in range(junction_distances.size()):
		var target: Vector2 = Vector2(junction_distances[index], 0.0)
		_assert_plan(planner, planner.plan(Vector2.ZERO, target), "120 boundary %s" % junction_distances[index],
			Vector2.ZERO, target, Vector2i(2, expected_junctions[index]), expected_junctions[index])
	var double_distances: Array[float] = [239.99, 240.0, 240.01]
	var double_extensions: Array[int] = [3, 3, 4]
	var double_junctions: Array[int] = [2, 2, 3]
	for index: int in range(double_distances.size()):
		var target: Vector2 = Vector2(double_distances[index], 0.0)
		_assert_plan(planner, planner.plan(Vector2.ZERO, target), "240 boundary %s" % double_distances[index],
			Vector2.ZERO, target, Vector2i(double_extensions[index], double_junctions[index]),
			double_junctions[index])
	var long_end: Vector2 = Vector2(1000.0, 0.0)
	_assert_plan(planner, planner.plan(Vector2.ZERO, long_end), "Long branch",
		Vector2.ZERO, long_end, Vector2i(13, 9), 9)


func _test_positions() -> void:
	var planner: Planner = Planner.new()
	var start_position: Vector2 = Vector2(37.25, -14.5)
	var end_position: Vector2 = Vector2(277.25, -14.5)
	_assert_plan(planner, planner.plan(start_position, end_position), "Offset branch",
		start_position, end_position, Vector2i(3, 2), 2)
	start_position = Vector2(10.0, -20.0)
	end_position = Vector2(190.0, 220.0)
	var diagonal: Dictionary = planner.plan(start_position, end_position)
	_assert_plan(planner, diagonal, "Diagonal branch", start_position, end_position, Vector2i(4, 3), 3)
	var diagonal_junctions: PackedVector2Array = diagonal["junction_positions"]
	_check(diagonal_junctions == PackedVector2Array([
		Vector2(82.0, 76.0), Vector2(154.0, 172.0), end_position,
	]), "Diagonal junction positions")
	start_position = Vector2(27.5, -13.25)
	end_position = Vector2(341.25, 267.75)
	_assert_plan(planner, planner.plan(start_position, end_position), "Arbitrary diagonal target",
		start_position, end_position, Vector2i(6, 4), 4)
	start_position = Vector2(300.0, 40.0)
	end_position = Vector2(60.0, 40.0)
	var reverse: Dictionary = planner.plan(start_position, end_position)
	_assert_plan(planner, reverse, "Reverse branch", start_position, end_position, Vector2i(3, 2), 2)
	_check(reverse["junction_positions"] == PackedVector2Array([Vector2(180.0, 40.0), end_position]),
		"Reverse junction order")


func _test_existing_endpoints() -> void:
	var planner: Planner = Planner.new()
	var distances: Array[float] = [40.0, 120.0, 240.0, 1000.0]
	var extensions: Array[int] = [1, 2, 3, 13]
	var junctions: Array[int] = [0, 0, 1, 8]
	var segment_counts: Array[int] = [1, 1, 2, 9]
	for index: int in range(distances.size()):
		var target: Vector2 = Vector2(distances[index], 0.0)
		_assert_plan(planner, planner.plan(Vector2.ZERO, target, true),
			"Existing endpoint %s" % distances[index], Vector2.ZERO, target,
			Vector2i(extensions[index], junctions[index]), segment_counts[index], true)


func _test_cost_distribution_and_configuration() -> void:
	var planner: Planner = Planner.new()
	var first_plan: Dictionary = planner.plan(Vector2.ZERO, Vector2(240.0, 0.0))
	var default_segments: Array[Dictionary] = first_plan["segments"]
	_check(default_segments[0]["extension_cost"] == 2 and default_segments[1]["extension_cost"] == 1,
		"Cumulative fees avoid independently rounding each 120 pixel segment")
	_check(first_plan == planner.plan(Vector2.ZERO, Vector2(240.0, 0.0)), "Planning is repeatable")
	_check(planner.junction_cost == 4 and planner.extension_unit_length == 80.0
		and planner.junction_spacing == 120.0, "Planning preserves configuration")
	planner.junction_cost = 2
	planner.extension_unit_length = 40.0
	planner.junction_spacing = 90.0
	var target: Vector2 = Vector2(200.0, 0.0)
	var configured: Dictionary = planner.plan(Vector2.ZERO, target)
	_assert_plan(planner, configured, "Configured planner", Vector2.ZERO, target, Vector2i(5, 3), 3)
	var configured_segments: Array[Dictionary] = configured["segments"]
	_check(configured_segments[0]["extension_cost"] == 3
		and configured_segments[1]["extension_cost"] == 2
		and configured_segments[2]["extension_cost"] == 0, "Configured cumulative fees")
	_assert_plan(planner, planner.plan(Vector2.ZERO, target, true), "Configured existing endpoint",
		Vector2.ZERO, target, Vector2i(5, 2), 3, true)
	planner.junction_cost = 0
	planner.extension_unit_length = 100.0
	planner.junction_spacing = 50.0
	target = Vector2(150.0, 0.0)
	var free_junctions: Dictionary = planner.plan(Vector2.ZERO, target)
	_assert_plan(planner, free_junctions, "Zero junction cost", Vector2.ZERO, target, Vector2i(2, 3), 3)
	var free_segments: Array[Dictionary] = free_junctions["segments"]
	_check(free_segments[0]["extension_cost"] == 1 and free_segments[1]["extension_cost"] == 0
		and free_segments[2]["extension_cost"] == 1, "A segment may have no new extension charge")
	planner.junction_cost = 4
	planner.extension_unit_length = 0.1
	planner.junction_spacing = 0.1
	target = Vector2(0.3, 0.0)
	_assert_plan(planner, planner.plan(Vector2.ZERO, target), "Narrow decimal boundary tolerance",
		Vector2.ZERO, target, Vector2i(3, 3), 3)


func _test_invalid_inputs() -> void:
	var planner: Planner = Planner.new()
	var target: Vector2 = Vector2(80.0, 0.0)
	var invalid_coordinates: Array[Vector2] = [
		Vector2(NAN, 0.0), Vector2(INF, 0.0), Vector2(0.0, -INF),
	]
	for index: int in range(invalid_coordinates.size()):
		_assert_invalid(planner.plan(invalid_coordinates[index], target), "Invalid starting coordinate %d" % index)
		_assert_invalid(planner.plan(Vector2.ZERO, invalid_coordinates[index]), "Invalid target coordinate %d" % index)
	var invalid_units: Array[float] = [0.0, -1.0, INF, NAN]
	for index: int in range(invalid_units.size()):
		planner.extension_unit_length = invalid_units[index]
		_assert_invalid(planner.plan(Vector2.ZERO, target), "Invalid extension unit %d" % index)
	planner.extension_unit_length = 80.0
	for index: int in range(invalid_units.size()):
		planner.junction_spacing = invalid_units[index]
		_assert_invalid(planner.plan(Vector2.ZERO, target), "Invalid junction spacing %d" % index)
	planner.junction_spacing = 120.0
	planner.junction_cost = -1
	_assert_invalid(planner.plan(Vector2.ZERO, target), "Negative junction cost")
	_assert_invalid(planner.plan(Vector2.ZERO, Vector2.ZERO), "Invalid configuration on zero distance")
	planner.junction_cost = 4
	planner.extension_unit_length = 1.0e-300
	_assert_invalid(planner.plan(Vector2.ZERO, target), "Finite extension fee overflow")
	planner.extension_unit_length = 80.0
	planner.junction_spacing = 1.0e-300
	_assert_invalid(planner.plan(Vector2.ZERO, target), "Finite segment count overflow")
	planner.junction_spacing = 120.0
	_assert_plan(planner, planner.plan(Vector2.ZERO, target), "Recovery after invalid requests",
		Vector2.ZERO, target, Vector2i(1, 1), 1)
	planner.junction_spacing = 1.0
	_assert_invalid(planner.plan(Vector2(100000000.0, 0.0), Vector2(100000008.0, 0.0)),
		"Junction coordinates collapse at large offsets")


func _test_limits() -> void:
	var planner: Planner = Planner.new()
	planner.junction_spacing = 1.0
	planner.junction_cost = 0
	var target: Vector2 = Vector2(100000.0, 0.0)
	var at_limit: Dictionary = planner.plan(Vector2.ZERO, target)
	_check(at_limit["valid"] == true, "Exactly 100000 segments are allowed")
	var segments: Array[Dictionary] = at_limit["segments"]
	var junctions: PackedVector2Array = at_limit["junction_positions"]
	_check(segments.size() == 100000 and junctions.size() == 100000, "Segment limit has exact counts")
	_check(at_limit["extension_cost"] == 1250 and at_limit["total_cost"] == 1250, "Segment limit fees")
	if not segments.is_empty():
		_check(segments[0]["start_position"] == Vector2.ZERO
			and segments[-1]["end_position"] == target, "Segment limit preserves endpoints")
	var extension_sum: int = 0
	var length_sum: float = 0.0
	for segment: Dictionary in segments:
		extension_sum += int(segment["extension_cost"])
		length_sum += float(segment["length"])
	_check(extension_sum == at_limit["extension_cost"] and length_sum == at_limit["distance"],
		"Segment limit aggregate invariants")
	_assert_invalid(planner.plan(Vector2.ZERO, Vector2(100000.01, 0.0)), "Segment limit exceeded")
	_assert_invalid(planner.plan(Vector2.ZERO, Vector2(100001.0, 0.0), true),
		"Existing endpoint does not bypass the segment limit")
	planner.junction_spacing = 120.0
	planner.junction_cost = Planner.MAX_INTEGER_COST
	_assert_invalid(planner.plan(Vector2.ZERO, Vector2(1.0, 0.0)), "Total integer cost overflow")
	var existing: Dictionary = planner.plan(Vector2.ZERO, Vector2(1.0, 0.0), true)
	_check(existing["valid"] == true and existing["total_cost"] == 1,
		"Existing endpoint does not charge a huge unused junction fee")
	planner.junction_cost = Planner.MAX_INTEGER_COST - 1
	var maximum_cost: Dictionary = planner.plan(Vector2.ZERO, Vector2(1.0, 0.0))
	_check(maximum_cost["valid"] == true and maximum_cost["total_cost"] == Planner.MAX_INTEGER_COST,
		"Exactly INT64_MAX total cost is allowed")
