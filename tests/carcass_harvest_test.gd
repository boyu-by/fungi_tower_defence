extends SceneTree
## 有限残骸接入原回收/消化/回流链的独立夹具；运输记录不是第二份营养库存。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const DIGESTIVE_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")
const REMAINS_SCENE: PackedScene = preload("res://scenes/recycling/enemy_remains.tscn")
const SYSTEM_SCENE: PackedScene = preload("res://scenes/systems/recycling_system.tscn")
const POSITION_EPSILON: float = 0.01

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var source: HyphaNode
	var receiver_node: HyphaNode
	var receiver: DigestiveOrgan
	var core_edge: HyphaEdge
	var source_edge: HyphaEdge
	var network: NetworkSystem
	var field: FungalField
	var system: RecyclingSystem
	var remains: Node2D
	var packets: Node2D
	var return_system: NutritionReturnSystem
	var initial_core_nutrition: int


class SelectiveNetwork:
	extends NetworkSystem

	var rejected_start: Node2D
	var rejected_end: Node2D
	var reject_as_invalid: bool = false

	func find_route(start: Node2D, end: Node2D) -> NetworkRoute:
		var route: NetworkRoute = super.find_route(start, end)
		if not reject_as_invalid and start == rejected_start and end == rejected_end:
			route.found = false
			route.segments.clear()
		return route


	# 6.4 新采集使用可用路线，候选失败替身保持相同拒绝条件。
	func find_available_route(start: Node2D, end: Node2D, units: int = 1) -> NetworkRoute:
		var route: NetworkRoute = super.find_available_route(start, end, units)
		if not reject_as_invalid and start == rejected_start and end == rejected_end:
			route.found = false
			route.segments.clear()
		return route

	func is_route_valid(route: NetworkRoute) -> bool:
		if reject_as_invalid and route != null and (
			route.start_node == rejected_start and route.end_node == rejected_end
		):
			return false
		return super.is_route_valid(route)


var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1000, 700)
	await _test_field_route_and_capacity_gates()
	await _test_overlap_fallback_and_rival_request()
	await _test_reentry_and_claim_before_exposure()
	await _test_partial_final_batch()
	await _test_creation_failure()
	await _test_precommit_signal_invalidation()
	await _test_postcommit_signal_invalidation()
	await _test_interruption_and_recovery_priority()
	await _test_ordinary_corpse_priority()
	await _test_source_deletion_after_commit()
	await _test_system_and_receiver_teardown()
	await _test_full_conservation_and_exhaustion()
	print("CARCASS_HARVEST_TEST_RESULT ", JSON.stringify({
		"checks": checks, "failures": failures
	}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _new_fixture(network_override: NetworkSystem = null) -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.network = network_override if network_override != null else NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.field = FungalField.new()
	fixture.field.expansion_speed = 100.0
	fixture.world.add_child(fixture.field)
	fixture.field.set_process(false)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.world.add_child(fixture.core)
	fixture.initial_core_nutrition = fixture.core.nutrition
	_check(fixture.network.register_node(fixture.core, true), "Fixture core registration failed")
	fixture.receiver_node = _add_node(fixture, Vector2(160.0, 0.0))
	fixture.source = _add_node(fixture, Vector2(320.0, 0.0))
	fixture.core_edge = _add_edge(fixture, fixture.core, fixture.receiver_node)
	fixture.source_edge = _add_edge(fixture, fixture.receiver_node, fixture.source)
	fixture.receiver = DIGESTIVE_SCENE.instantiate() as DigestiveOrgan
	fixture.receiver.mother_core = fixture.core
	fixture.receiver.core_edge = fixture.core_edge
	fixture.receiver_node.add_child(fixture.receiver)
	fixture.receiver.digest_timer.wait_time = 120.0
	fixture.receiver.digest_timer.stop()
	fixture.remains = Node2D.new()
	fixture.world.add_child(fixture.remains)
	fixture.packets = Node2D.new()
	fixture.world.add_child(fixture.packets)
	fixture.system = _add_system(fixture)
	var return_packets: Node2D = Node2D.new()
	fixture.world.add_child(return_packets)
	fixture.return_system = NutritionReturnSystem.new()
	fixture.return_system.digestive_organ = fixture.receiver
	fixture.return_system.mother_core = fixture.core
	fixture.return_system.network_system = fixture.network
	fixture.return_system.packet_container = return_packets
	fixture.return_system.auto_return = false
	fixture.world.add_child(fixture.return_system)
	fixture.field.set_sources([
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 80.0},
	])
	fixture.field.advance(1.0)
	return fixture


func _add_node(fixture: Fixture, position: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.world.add_child(node)
	node.global_position = position
	_check(fixture.network.register_node(node), "Fixture junction registration failed")
	return node


func _add_edge(fixture: Fixture, start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = start
	edge.end_node = end
	fixture.world.add_child(edge)
	_check(fixture.network.register_edge(edge), "Fixture edge registration failed")
	return edge


func _add_system(fixture: Fixture) -> RecyclingSystem:
	var system: RecyclingSystem = SYSTEM_SCENE.instantiate() as RecyclingSystem
	system.network_system = fixture.network
	system.fungal_field = fixture.field
	system.digestive_organ = fixture.receiver
	system.remains_container = fixture.remains
	system.packet_container = fixture.packets
	fixture.world.add_child(system)
	(system.get_node("DispatchTimer") as Timer).stop()
	return system


func _add_carcass(fixture: Fixture, nutrition: int = 80,
		position: Vector2 = Vector2(340.0, 0.0)) -> LargeCarcass:
	var carcass: LargeCarcass = LargeCarcass.new()
	carcass.total_nutrition = nutrition
	fixture.remains.add_child(carcass)
	carcass.global_position = position
	return carcass


func _add_remains(fixture: Fixture) -> EnemyRemains:
	var remains: EnemyRemains = REMAINS_SCENE.instantiate() as EnemyRemains
	fixture.remains.add_child(remains)
	remains.global_position = Vector2(350.0, 0.0)
	return remains


func _live_batches(fixture: Fixture) -> Array[EnemyRemains]:
	var batches: Array[EnemyRemains] = []
	for child: Node in fixture.remains.get_children():
		if child is EnemyRemains and not child.is_queued_for_deletion() and (
			child.has_meta("carcass_batch_id")
		):
			batches.append(child as EnemyRemains)
	return batches


func _first_batch(fixture: Fixture) -> EnemyRemains:
	var batches: Array[EnemyRemains] = _live_batches(fixture)
	_check(not batches.is_empty(), "Expected an independently materialized carcass batch")
	return null if batches.is_empty() else batches[0]


func _first_packet(fixture: Fixture) -> RemainsPacket:
	for child: Node in fixture.packets.get_children():
		if child is RemainsPacket and not child.is_queued_for_deletion():
			return child as RemainsPacket
	_check(false, "Expected an active carcass shipment packet")
	return null


func _finish_transport(fixture: Fixture) -> void:
	for child: Node in fixture.packets.get_children():
		if child is RemainsPacket and not child.is_queued_for_deletion():
			(child as RemainsPacket)._physics_process(20.0)
	await _flush_deletions()
	_check(fixture.system.get_in_transit_count() == 0 and fixture.packets.get_child_count() == 0,
		"Terminal carcass transport left a shipment or packet")


func _flush_deletions() -> void:
	await process_frame
	await process_frame


func _dispose_fixture(fixture: Fixture) -> void:
	fixture.world.queue_free()
	await _flush_deletions()


func _check_conservation(fixture: Fixture, expected: int, description: String) -> void:
	var nutrition: int = fixture.core.nutrition - fixture.initial_core_nutrition
	for child: Node in fixture.remains.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is LargeCarcass:
			nutrition += (child as LargeCarcass).get_remaining_nutrition()
		elif child is EnemyRemains:
			# 领取后隐藏的原尸体仍拥有在途营养，包和容量预留都不能再加一次。
			nutrition += (child as EnemyRemains).nutrition_value
	nutrition += fixture.receiver.get_queued_nutrition()
	# 回流途中的产物仍由胃囊库存持有；消化预留已包含在 queued_nutrition 中。
	nutrition += fixture.receiver.get_output_nutrition()
	_check(nutrition == expected, "%s: expected %d, got %d" % [description, expected, nutrition])


func _return_outputs(fixture: Fixture, expected: int) -> void:
	fixture.return_system.auto_return = true
	var checked_transit: bool = false
	for _frame: int in range(600):
		if fixture.receiver.get_output_count() == 0 and fixture.return_system.get_in_transit_count() == 0:
			break
		await physics_frame
		if not checked_transit and fixture.return_system.get_in_transit_count() > 0:
			checked_transit = true
			_check_conservation(fixture, expected, "Return transit retains one product owner")
	fixture.return_system.auto_return = false
	await _flush_deletions()
	_check(checked_transit, "Carcass output did not use the real return transport")
	_check(fixture.receiver.get_output_count() == 0 and
		fixture.return_system.get_in_transit_count() == 0, "Carcass output return timed out")
	_check_conservation(fixture, expected, "Returned output is credited exactly once")


func _test_field_route_and_capacity_gates() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture, 80, Vector2(440.0, 0.0))
	_check(not fixture.system.try_dispatch() and carcass.get_snapshot()["status"] == &"out_of_field",
		"Outside effective field must report an out-of-field wait")
	fixture.field.set_sources([
		{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 150.0},
	])
	fixture.field.advance(0.2)
	_check(not fixture.system.try_dispatch(), "Carcass collection ran ahead of field expansion")
	fixture.field.advance(0.6)
	_check(fixture.field.is_covered(carcass.global_position), "Expanded field did not cover the carcass")
	_add_edge(fixture, fixture.core, fixture.source)
	fixture.network.unregister_edge(fixture.source_edge)
	fixture.network.unregister_edge(fixture.core_edge)
	_check(fixture.network.is_connected_to_core(fixture.source), "No-route fixture lacks core connectivity")
	_check(not fixture.system.try_dispatch() and carcass.get_snapshot()["status"] == &"no_route",
		"A core-connected source without a receiver route must wait")
	_check(fixture.network.register_edge(fixture.core_edge), "Receiver route reconnection failed")
	fixture.receiver.capacity = 1
	_check(fixture.receiver.reserve_remains(), "Capacity gate fixture could not reserve a slot")
	_check(not fixture.system.try_dispatch() and carcass.get_snapshot()["status"] == &"capacity_full",
		"Full incoming capacity must prevent mining and report its wait")
	_check(carcass.get_remaining_nutrition() == 80 and carcass.get_reserved_nutrition() == 0 and
		_live_batches(fixture).is_empty() and fixture.packets.get_child_count() == 0,
		"Waiting gates deducted nutrition, reserved the source or created a ground pile")
	_check_conservation(fixture, 80, "Every waiting gate conserves the source")
	fixture.receiver.cancel_reservation()
	_check(fixture.system.try_dispatch(), "Freed capacity did not resume carcass mining")
	_check(carcass.get_remaining_nutrition() == 70 and fixture.receiver.incoming_remains == 1,
		"Resumed mining must produce one ten-nutrition reservation")
	await _finish_transport(fixture)
	await _dispose_fixture(fixture)


func _test_overlap_fallback_and_rival_request() -> void:
	for reject_as_invalid: bool in [false, true]:
		var network: SelectiveNetwork = SelectiveNetwork.new()
		var fixture: Fixture = _new_fixture(network)
		network.rejected_start = fixture.source
		network.rejected_end = fixture.receiver_node
		network.reject_as_invalid = reject_as_invalid
		fixture.field.set_sources([
			{"node": fixture.source, "kind": &"junction", "connected": true, "radius": 80.0},
			{"node": fixture.receiver_node, "kind": &"junction", "connected": true, "radius": 240.0},
		])
		fixture.field.advance(3.0)
		var carcass: LargeCarcass = _add_carcass(fixture, 10)
		_check(fixture.field.get_collecting_nodes(carcass.global_position).size() == 2,
			"Overlap fixture does not offer two alternative candidates")
		_check(fixture.system.try_dispatch(), "Rejected first candidate prevented valid carcass fallback")
		var packet: RemainsPacket = _first_packet(fixture)
		if packet != null:
			_check(packet.edge == null, "Fallback did not choose the receiver's zero-edge route")
		_check(_live_batches(fixture).size() == 1 and carcass.is_exhausted(),
			"Overlapping coverage duplicated the final source batch")
		_check_conservation(fixture, 10, "Overlap alternatives have one materialized owner")
		await _finish_transport(fixture)
		await _dispose_fixture(fixture)

	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture, 10)
	var rival: RecyclingSystem = _add_system(fixture)
	fixture.receiver.capacity = 2
	var rival_results: Array[bool] = []
	var compete: Callable = func(_queued: int, incoming: int) -> void:
		if incoming == 1 and rival_results.is_empty():
			# 标记先于递归容量通知，避免监听者自身无限重入。
			rival_results.append(false)
			rival_results[0] = rival.try_dispatch()
	fixture.receiver.inventory_changed.connect(compete)
	_check(not fixture.system.try_dispatch(), "Outer attempt mined nutrition already taken by its rival")
	fixture.receiver.inventory_changed.disconnect(compete)
	_check(rival_results == [true] and rival.get_in_transit_count() == 1 and
		fixture.system.get_in_transit_count() == 0 and fixture.receiver.incoming_remains == 1,
		"Rival request did not own exactly one capacity reservation")
	_check(carcass.is_exhausted() and _live_batches(fixture).size() == 1,
		"Rival source reservations created duplicate batches")
	_check_conservation(fixture, 10, "Rival attempts conserve their shared finite source")
	await _finish_transport(fixture)
	_check(rival.delivered_count == 1 and fixture.receiver.get_queued_nutrition() == 10,
		"Rival batch delivery was lost or counted twice")
	await _dispose_fixture(fixture)

	fixture = _new_fixture()
	carcass = _add_carcass(fixture, 20)
	rival = _add_system(fixture)
	fixture.receiver.capacity = 2
	rival_results.clear()
	var on_draft_exposed: Callable = func(child: Node) -> void:
		if child is EnemyRemains and rival_results.is_empty():
			rival_results.append(false)
			_check_conservation(fixture, 20, "Exposed draft is still owned by its reserved source")
			rival_results[0] = rival.try_dispatch()
	var on_competing_source_change: Callable = func(_snapshot: Dictionary) -> void:
		_check_conservation(fixture, 20, "Rival commit while another draft exists conserves resources")
	fixture.remains.child_entered_tree.connect(on_draft_exposed)
	carcass.resources_changed.connect(on_competing_source_change)
	_check(fixture.system.try_dispatch(), "Owning draft failed after a rival mined a separate reservation")
	fixture.remains.child_entered_tree.disconnect(on_draft_exposed)
	carcass.resources_changed.disconnect(on_competing_source_change)
	_check(rival_results == [true] and _live_batches(fixture).size() == 2 and carcass.is_exhausted() and
		fixture.receiver.incoming_remains == 2, "Draft-entry competition did not produce two unique ten-nutrition owners")
	await _finish_transport(fixture)
	_check(fixture.system.delivered_count == 1 and rival.delivered_count == 1 and
		fixture.receiver.get_queued_nutrition() == 20, "Draft-entry rival deliveries were duplicated or lost")
	await _dispose_fixture(fixture)


func _test_reentry_and_claim_before_exposure() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	var reentry_results: Array[bool] = []
	var exposed_batches: Array[EnemyRemains] = []
	var on_inventory: Callable = func(_queued: int, _incoming: int) -> void:
		reentry_results.append(fixture.system.try_dispatch())
	var on_resources: Callable = func(_snapshot: Dictionary) -> void:
		reentry_results.append(fixture.system.try_dispatch())
		_check_conservation(fixture, 80, "Source notification follows reservation/commit mutations")
	var on_child: Callable = func(child: Node) -> void:
		if child is EnemyRemains:
			var batch: EnemyRemains = child as EnemyRemains
			exposed_batches.append(batch)
			_check(not batch.is_available() and not batch.visible,
				"Batch was exposed in the shared container before being claimed")
			_check(batch.nutrition_value == 0, "Uncommitted visible draft already duplicated source nutrition")
			_check_conservation(fixture, 80, "Child-entry notification retains nutrition in the reserved source")
			_check(batch.get_meta("carcass_batch_id", null) is String and
				batch.get_meta("carcass_source_id", null) is String and
				batch.get_meta("carcass_request_id", null) is String,
				"Materialized batch metadata must contain stable String identifiers")
			reentry_results.append(fixture.system.try_dispatch())
	fixture.receiver.inventory_changed.connect(on_inventory)
	carcass.resources_changed.connect(on_resources)
	fixture.remains.child_entered_tree.connect(on_child)
	_check(fixture.system.try_dispatch(), "Guarded signal reentry prevented the owning dispatch")
	fixture.receiver.inventory_changed.disconnect(on_inventory)
	carcass.resources_changed.disconnect(on_resources)
	fixture.remains.child_entered_tree.disconnect(on_child)
	_check(not reentry_results.is_empty() and not reentry_results.has(true) and exposed_batches.size() == 1,
		"Signal reentry dispatched additional batches")
	_check(carcass.get_remaining_nutrition() == 70 and carcass.get_reserved_nutrition() == 0 and
		fixture.receiver.incoming_remains == 1 and fixture.system.get_in_transit_count() == 1,
		"One guarded attempt did not transfer exactly ten nutrition")
	_check(carcass.get_snapshot()["status"] == &"harvesting", "Active source did not report harvesting")
	await _finish_transport(fixture)
	await _dispose_fixture(fixture)


func _test_partial_final_batch() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture, 23)
	var batch_ids: Array[String] = []
	var request_ids: Array[String] = []
	var expected_remaining: int = 23
	for nutrition: int in [10, 10, 3]:
		_check(fixture.system.try_dispatch(), "Partial-final source stopped before exhaustion")
		var batch: EnemyRemains = _first_batch(fixture)
		if batch == null:
			await _dispose_fixture(fixture)
			return
		var batch_id: String = batch.get_meta("carcass_batch_id")
		var request_id: String = batch.get_meta("carcass_request_id")
		_check(not batch_ids.has(batch_id) and not request_ids.has(request_id),
			"Successful batches reused a batch or request identifier")
		batch_ids.append(batch_id)
		request_ids.append(request_id)
		expected_remaining -= nutrition
		_check(batch.nutrition_value == nutrition and carcass.get_remaining_nutrition() == expected_remaining and
			carcass.get_reserved_nutrition() == 0, "Final batch lost its partial nutrition or leaked a reservation")
		_check_conservation(fixture, 23, "Partial-final transport conserves nutrition")
		await _finish_transport(fixture)
	_check(carcass.is_exhausted() and carcass.get_snapshot()["status"] == &"exhausted" and
		carcass.get_harvested_nutrition() == 23, "Partial-final source did not exhaust exactly once")
	_check(not fixture.system.try_dispatch() and not fixture.system.try_dispatch() and
		_live_batches(fixture).is_empty() and fixture.receiver.get_queued_nutrition() == 23,
		"Exhausted source resumed mining or left a second resource owner")
	_check_conservation(fixture, 23, "Exhaustion leaves all nutrition in the digestive queue")
	await _dispose_fixture(fixture)


func _test_creation_failure() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	fixture.system.batch_scene = NODE_SCENE
	_check(not fixture.system.try_dispatch(), "Non-remains batch scene was accepted")
	_check(carcass.get_remaining_nutrition() == 80 and carcass.get_reserved_nutrition() == 0 and
		fixture.receiver.incoming_remains == 0 and _live_batches(fixture).is_empty() and
		fixture.packets.get_child_count() == 0, "Batch creation failure did not roll back both reservations")
	fixture.system.batch_scene = REMAINS_SCENE
	var valid_transport: PackedScene = fixture.system.packet_scene
	fixture.system.packet_scene = NODE_SCENE
	_check(not fixture.system.try_dispatch(), "Non-packet scene committed a source batch")
	_check(carcass.get_harvested_nutrition() == 0 and carcass.get_reserved_nutrition() == 0 and
		fixture.receiver.incoming_remains == 0 and _live_batches(fixture).is_empty(),
		"Packet creation failure left a draft or deducted source nutrition")
	fixture.system.packet_scene = valid_transport
	_check(fixture.system.try_dispatch(), "Fresh request did not recover after failed creation attempts")
	_check(carcass.get_remaining_nutrition() == 70 and _live_batches(fixture).size() == 1,
		"Creation retries mined more than one batch")
	_check_conservation(fixture, 80, "Creation failure and retry conserve nutrition")
	await _finish_transport(fixture)
	await _dispose_fixture(fixture)


func _test_precommit_signal_invalidation() -> void:
	for invalidate_field: bool in [false, true]:
		var fixture: Fixture = _new_fixture()
		var carcass: LargeCarcass = _add_carcass(fixture)
		var invalidate: Callable = func(snapshot: Dictionary) -> void:
			if int(snapshot["reserved_nutrition"]) > 0:
				if invalidate_field:
					fixture.field.set_sources([])
				else:
					fixture.network.unregister_edge(fixture.source_edge)
		carcass.resources_changed.connect(invalidate)
		_check(not fixture.system.try_dispatch(), "Reservation notification bypassed a changed harvest gate")
		carcass.resources_changed.disconnect(invalidate)
		_check(carcass.get_remaining_nutrition() == 80 and carcass.get_reserved_nutrition() == 0 and
			fixture.receiver.incoming_remains == 0 and _live_batches(fixture).is_empty(),
			"Precommit gate invalidation left resources committed or capacity reserved")
		_check(carcass.get_snapshot()["status"] == (&"out_of_field" if invalidate_field else &"no_route"),
			"Failed dispatch did not refresh the source's actual waiting reason")
		_check_conservation(fixture, 80, "Precommit signal invalidation restores source ownership")
		await _dispose_fixture(fixture)

	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	var remove_receiver: Callable = func(_queued: int, incoming: int) -> void:
		if incoming > 0:
			fixture.receiver_node.remove_child(fixture.receiver)
	fixture.receiver.inventory_changed.connect(remove_receiver)
	_check(not fixture.system.try_dispatch(), "Detached receiver allowed precommit mining")
	fixture.receiver.inventory_changed.disconnect(remove_receiver)
	_check(carcass.get_remaining_nutrition() == 80 and carcass.get_reserved_nutrition() == 0 and
		fixture.receiver.incoming_remains == 0 and _live_batches(fixture).is_empty(),
		"Receiver removal during reservation leaked source or capacity ownership")
	fixture.receiver_node.add_child(fixture.receiver)
	await _dispose_fixture(fixture)

	fixture = _new_fixture()
	carcass = _add_carcass(fixture)
	var reset_capacity: Callable = func(_queued: int, incoming: int) -> void:
		if incoming > 0:
			fixture.receiver.reset()
	fixture.receiver.inventory_changed.connect(reset_capacity)
	_check(not fixture.system.try_dispatch(), "Lost receiver reservation still allowed source commitment")
	fixture.receiver.inventory_changed.disconnect(reset_capacity)
	_check(carcass.get_remaining_nutrition() == 80 and carcass.get_reserved_nutrition() == 0 and
		fixture.receiver.incoming_remains == 0 and _live_batches(fixture).is_empty(),
		"Capacity reset during its notification did not roll back the uncommitted source")
	_check_conservation(fixture, 80, "Lost capacity reservation leaves all nutrition at the source")
	await _dispose_fixture(fixture)


func _test_postcommit_signal_invalidation() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	var invalidate: Callable = func(snapshot: Dictionary) -> void:
		if int(snapshot["harvested_nutrition"]) > 0:
			fixture.network.unregister_edge(fixture.source_edge)
	carcass.resources_changed.connect(invalidate)
	_check(not fixture.system.try_dispatch(), "Commit notification ignored a removed transport route")
	carcass.resources_changed.disconnect(invalidate)
	var batch: EnemyRemains = _first_batch(fixture)
	if batch != null:
		_check(batch.is_available() and batch.visible and batch.nutrition_value == 10,
			"Postcommit failure did not drop the sole independent batch")
	_check(carcass.get_remaining_nutrition() == 70 and carcass.get_reserved_nutrition() == 0 and
		fixture.receiver.incoming_remains == 0 and fixture.packets.get_child_count() == 0 and
		fixture.system.interrupted_count == 1, "Postcommit failure restored the source or leaked a reservation")
	_check(carcass.get_snapshot()["status"] == &"no_route", "Postcommit source wait did not reflect the broken route")
	_check_conservation(fixture, 80, "Committed failure transfers ownership to its ground batch")
	_check(fixture.network.register_edge(fixture.source_edge) and fixture.system.try_dispatch(),
		"Postcommit ground batch could not be recovered after reconnection")
	_check(carcass.get_remaining_nutrition() == 70 and _live_batches(fixture).size() == 1,
		"Recovery of a committed failure mined another batch")
	await _finish_transport(fixture)
	await _dispose_fixture(fixture)


func _test_interruption_and_recovery_priority() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	_check(fixture.system.try_dispatch(), "Interruption fixture did not mine its first batch")
	var batch: EnemyRemains = _first_batch(fixture)
	var packet: RemainsPacket = _first_packet(fixture)
	if batch == null or packet == null:
		await _dispose_fixture(fixture)
		return
	var batch_id: String = batch.get_meta("carcass_batch_id")
	packet._physics_process(0.15)
	var drop_position: Vector2 = packet.global_position
	fixture.network.unregister_edge(fixture.source_edge)
	packet._physics_process(0.0)
	fixture.system._on_packet_arrived(packet)
	fixture.system._on_packet_interrupted(packet)
	fixture.system._on_packet_removed(packet.get_instance_id())
	_check(batch.is_available() and batch.visible and
		batch.global_position.distance_to(drop_position) < POSITION_EPSILON,
		"Route break did not restore the original batch at its last packet position")
	_check(carcass.get_remaining_nutrition() == 70 and fixture.receiver.incoming_remains == 0 and
		fixture.system.interrupted_count == 1 and fixture.system.delivered_count == 0,
		"Duplicate interruption callbacks changed source nutrition or settled twice")
	_check_conservation(fixture, 80, "Interrupted transport leaves one ground batch owner")
	await _flush_deletions()
	_check(fixture.network.register_edge(fixture.source_edge) and fixture.system.try_dispatch(),
		"Reconnected route did not recollect the interrupted batch")
	_check(carcass.get_remaining_nutrition() == 70 and _live_batches(fixture).size() == 1 and
		String(batch.get_meta("carcass_batch_id")) == batch_id,
		"Available interrupted batch was not prioritized over new mining")
	packet = _first_packet(fixture)
	if packet != null:
		packet.cancel_transport()
		packet.cancel_transport()
		fixture.system._on_packet_arrived(packet)
	_check(batch.is_available() and fixture.system.interrupted_count == 2 and
		fixture.receiver.incoming_remains == 0 and carcass.get_remaining_nutrition() == 70,
		"Explicit repeated cancellation did not return the same committed batch once")
	await _flush_deletions()
	_check(fixture.system.try_dispatch(), "Cancelled batch could not be recovered again")
	packet = _first_packet(fixture)
	if packet != null:
		packet.queue_free()
	await _flush_deletions()
	_check(batch.is_available() and fixture.system.interrupted_count == 3 and
		fixture.receiver.incoming_remains == 0 and carcass.get_remaining_nutrition() == 70,
		"Forced packet removal lost the batch or leaked its original capacity reservation")
	_check(fixture.system.try_dispatch(), "Removed packet prevented re-recovery of the same batch")
	packet = _first_packet(fixture)
	var check_delivery_inventory: Callable = func(queued: int, _incoming: int) -> void:
		if queued > 0:
			_check_conservation(fixture, 80, "Delivery notification publishes one queued resource owner")
	fixture.receiver.inventory_changed.connect(check_delivery_inventory)
	if packet != null:
		packet._physics_process(20.0)
		fixture.system._on_packet_arrived(packet)
		fixture.system._on_packet_interrupted(packet)
		fixture.system._on_packet_removed(packet.get_instance_id())
	fixture.receiver.inventory_changed.disconnect(check_delivery_inventory)
	_check(fixture.system.delivered_count == 1 and fixture.system.interrupted_count == 3 and
		fixture.receiver.get_queued_nutrition() == 10 and fixture.receiver.incoming_remains == 0,
		"Recovered delivery or late callbacks duplicated a capacity settlement")
	_check_conservation(fixture, 80, "Recovered batch transfers to the queue exactly once")
	await _flush_deletions()
	await _dispose_fixture(fixture)


func _test_ordinary_corpse_priority() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	var ordinary: EnemyRemains = _add_remains(fixture)
	_check(fixture.system.try_dispatch() and not ordinary.is_available(),
		"An ordinary corpse behind the source in container order did not have priority")
	_check(ordinary.nutrition_value == 4 and not ordinary.has_meta("carcass_batch_id") and
		carcass.get_remaining_nutrition() == 80 and _live_batches(fixture).is_empty(),
		"Ordinary four-nutrition corpse dispatch changed source resources or metadata")
	_check_conservation(fixture, 84, "Ordinary corpse remains the original transport owner")
	await _finish_transport(fixture)
	_check(fixture.receiver.get_queued_nutrition() == 4 and fixture.core.nutrition == fixture.initial_core_nutrition,
		"Ordinary corpse was not queued unchanged or produced early income")
	_check_conservation(fixture, 84, "Ordinary delivery preserves its original nutrition")
	await _dispose_fixture(fixture)


func _test_source_deletion_after_commit() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture, 10)
	var delete_source: Callable = func(snapshot: Dictionary) -> void:
		if int(snapshot["harvested_nutrition"]) == 10:
			carcass.queue_free()
	carcass.resources_changed.connect(delete_source)
	_check(fixture.system.try_dispatch(), "Source deletion after commit cancelled an independent batch")
	await _flush_deletions()
	_check(not is_instance_valid(carcass) and _live_batches(fixture).size() == 1 and
		fixture.system.get_in_transit_count() == 1 and fixture.receiver.incoming_remains == 1,
		"Actually deleted source erased its independently owned shipment")
	_check_conservation(fixture, 10, "Deleted exhausted source leaves its batch intact")
	await _finish_transport(fixture)
	_check(fixture.receiver.get_queued_nutrition() == 10 and fixture.system.delivered_count == 1,
		"Batch from a deleted source did not deliver once")
	_check_conservation(fixture, 10, "Deleted source batch transfers to digestion")
	await _dispose_fixture(fixture)


func _test_system_and_receiver_teardown() -> void:
	var fixture: Fixture = _new_fixture()
	var carcass: LargeCarcass = _add_carcass(fixture)
	_check(fixture.system.try_dispatch(), "System teardown fixture did not dispatch")
	var batch: EnemyRemains = _first_batch(fixture)
	var packet: RemainsPacket = _first_packet(fixture)
	if batch == null or packet == null:
		await _dispose_fixture(fixture)
		return
	packet._physics_process(0.1)
	var drop_position: Vector2 = packet.global_position
	fixture.world.remove_child(fixture.system)
	fixture.system._on_packet_arrived(packet)
	fixture.system._on_packet_interrupted(packet)
	_check(not fixture.system.try_dispatch() and fixture.system.get_in_transit_count() == 0 and
		fixture.receiver.incoming_remains == 0 and fixture.system.interrupted_count == 1,
		"System exit leaked a reservation or permitted a new shipment")
	_check(batch.is_available() and batch.global_position.distance_to(drop_position) < POSITION_EPSILON and
		carcass.get_remaining_nutrition() == 70, "System exit lost its committed batch or restored the source")
	_check_conservation(fixture, 80, "System teardown returns only its batch ownership")
	fixture.world.add_child(fixture.system)
	(fixture.system.get_node("DispatchTimer") as Timer).stop()
	await _flush_deletions()
	_check(fixture.system.try_dispatch(), "Reattached system could not recollect its own dropped batch")
	packet = _first_packet(fixture)
	fixture.receiver_node.remove_child(fixture.receiver)
	if packet != null:
		fixture.system._on_packet_arrived(packet)
		fixture.system._on_packet_interrupted(packet)
	_check(batch.is_available() and fixture.receiver.incoming_remains == 0 and
		fixture.system.get_in_transit_count() == 0 and fixture.system.interrupted_count == 2 and
		carcass.get_remaining_nutrition() == 70, "Receiver teardown did not settle its committed batch once")
	fixture.receiver_node.add_child(fixture.receiver)
	await _flush_deletions()
	_check(fixture.system.try_dispatch(), "Reattached receiver could not recover the same committed batch")
	_check(carcass.get_remaining_nutrition() == 70, "Teardown recovery mined fresh source nutrition")
	await _finish_transport(fixture)
	_check_conservation(fixture, 80, "Both teardown paths preserve nutrition")
	await _dispose_fixture(fixture)


func _test_full_conservation_and_exhaustion() -> void:
	var fixture: Fixture = _new_fixture()
	fixture.receiver.capacity = 10
	var carcass: LargeCarcass = _add_carcass(fixture)
	for batch_index: int in range(8):
		_check(fixture.system.try_dispatch(), "Default eighty-nutrition source stopped before eight batches")
		_check(carcass.get_remaining_nutrition() == 80 - (batch_index + 1) * 10 and
			carcass.get_reserved_nutrition() == 0, "Default source deduction was not exactly ten per batch")
		_check_conservation(fixture, 80, "Default source shipment conserves all eighty nutrition")
		await _finish_transport(fixture)
	_check(carcass.is_exhausted() and not fixture.system.try_dispatch() and
		fixture.receiver.get_queued_nutrition() == 80 and fixture.receiver.incoming_remains == 0,
		"Eight deliveries did not exhaust the finite source and preserve its queue")
	_check(fixture.core.nutrition == fixture.initial_core_nutrition,
		"Carcass transport credited income before digestion and return")
	for _cycle: int in range(4):
		fixture.receiver._on_digest_timer_timeout()
		fixture.receiver._on_digest_timer_timeout()
		_check(fixture.receiver.get_output_count() == 2 and fixture.receiver.get_output_nutrition() == 20,
			"Two carcass digestions did not fill the existing finite output inventory")
		_check_conservation(fixture, 80, "Queued digestion and produced outputs share one total")
		await _return_outputs(fixture, 80)
	_check(fixture.core.nutrition == fixture.initial_core_nutrition + 80 and
		fixture.receiver.get_queued_nutrition() == 0 and fixture.receiver.get_output_nutrition() == 0 and
		fixture.receiver.total_nutrition_produced == 80 and fixture.system.delivered_count == 8,
		"Final return income did not equal the finite source's eighty nutrition")
	_check(not fixture.system.try_dispatch() and carcass.get_snapshot()["status"] == &"exhausted",
		"Freed digestive capacity resumed an exhausted source")
	_check_conservation(fixture, 80, "Final credited income conserves the initial resource")
	await _dispose_fixture(fixture)
