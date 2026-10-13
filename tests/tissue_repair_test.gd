extends SceneTree
## 组织生命、可逆宿主暂停，以及真实维修包的邻点收件和营养守恒。

const CORE_SCENE: PackedScene = preload("res://scenes/colony/mother_core.tscn")
const NODE_SCENE: PackedScene = preload("res://scenes/colony/hypha_node.tscn")
const EDGE_SCENE: PackedScene = preload("res://scenes/colony/hypha_edge.tscn")
const ATTACK_SCENE: PackedScene = preload("res://scenes/colony/attack_organ.tscn")
const DIGEST_SCENE: PackedScene = preload("res://scenes/colony/digestive_organ.tscn")

class Fixture:
	extends RefCounted

	var world: Node2D
	var core: MotherCore
	var neighbor: HyphaNode
	var junction: HyphaNode
	var downstream: HyphaNode
	var ingress: HyphaEdge
	var last_edge: HyphaEdge
	var network: NetworkSystem
	var traffic: NetworkTrafficSystem
	var repair: RepairSystem
	var supply: RepairSupplySystem
	var packets: Node2D

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_tissue_defaults_and_death_transitions()
	_test_attack_host_intent()
	_test_digestive_pause_and_loss_settlement()
	_test_paid_neighbor_repair_and_integer_core()
	_test_work_connection()
	_check(root.get_child_count() == 0, "All tissue fixtures released")
	print("TISSUE_REPAIR_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


func _close(actual: float, expected: float, description: String) -> void:
	_check(absf(actual - expected) < 0.000001, description)


func _node(fixture: Fixture, point: Vector2) -> HyphaNode:
	var node: HyphaNode = NODE_SCENE.instantiate() as HyphaNode
	fixture.world.add_child(node)
	node.position = point
	_check(fixture.network.register_node(node), "Junction registers")
	return node


func _edge(fixture: Fixture, first: Node2D, second: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = EDGE_SCENE.instantiate() as HyphaEdge
	edge.start_node = first
	edge.end_node = second
	fixture.world.add_child(edge)
	edge.set_process(false)
	_check(fixture.network.register_edge(edge), "Edge registers")
	return edge


func _fixture() -> Fixture:
	var fixture: Fixture = Fixture.new()
	fixture.world = Node2D.new()
	root.add_child(fixture.world)
	fixture.network = NetworkSystem.new()
	fixture.world.add_child(fixture.network)
	fixture.core = CORE_SCENE.instantiate() as MotherCore
	fixture.core.initial_nutrition = 32
	fixture.world.add_child(fixture.core)
	_check(fixture.network.register_node(fixture.core, true), "Core registers")
	fixture.neighbor = _node(fixture, Vector2(100.0, 0.0))
	fixture.junction = _node(fixture, Vector2(200.0, 0.0))
	fixture.downstream = _node(fixture, Vector2(300.0, 0.0))
	fixture.ingress = _edge(fixture, fixture.core, fixture.neighbor)
	fixture.last_edge = _edge(fixture, fixture.neighbor, fixture.junction)
	_edge(fixture, fixture.junction, fixture.downstream)
	fixture.traffic = NetworkTrafficSystem.new()
	fixture.traffic.network_system = fixture.network
	fixture.world.add_child(fixture.traffic)
	fixture.traffic.set_process(false)
	fixture.repair = RepairSystem.new()
	fixture.repair.network_system = fixture.network
	fixture.world.add_child(fixture.repair)
	fixture.repair.set_physics_process(false)
	fixture.packets = Node2D.new()
	fixture.world.add_child(fixture.packets)
	fixture.supply = RepairSupplySystem.new()
	fixture.supply.repair_system = fixture.repair
	fixture.supply.network_system = fixture.network
	fixture.supply.mother_core = fixture.core
	fixture.supply.traffic_system = fixture.traffic
	fixture.supply.packet_container = fixture.packets
	fixture.supply.auto_supply = false
	fixture.world.add_child(fixture.supply)
	fixture.supply.set_process(false)
	return fixture


func _deliver_one(fixture: Fixture) -> void:
	_check(fixture.supply.try_dispatch(), "One real repair unit dispatched")
	var records: Array[Dictionary] = fixture.supply.get_shipment_records()
	if records.is_empty():
		return
	var shipment: Dictionary = records.back()
	var packet: NutrientPacket = shipment["packet"] as NutrientPacket
	packet.set_physics_process(false)
	for _step: int in range(200):
		if bool(packet.get_transport_snapshot().get("terminal", false)):
			break
		fixture.traffic.refresh()
		packet._physics_process(0.05)
		fixture.supply.refresh_budget()
	_check(bool(shipment.get("debited", false)) and packet.has_arrived_at(
		fixture.repair.get_delivery_target(int(shipment["task_id"])), String(shipment["transport_task_id"])
	), "Repair stock comes from the original real packet arrival")


func _test_tissue_defaults_and_death_transitions() -> void:
	var fixture: Fixture = _fixture()
	var attack: AttackOrgan = ATTACK_SCENE.instantiate() as AttackOrgan
	fixture.world.add_child(attack)
	var digestive: DigestiveOrgan = DIGEST_SCENE.instantiate() as DigestiveOrgan
	fixture.world.add_child(digestive)
	var bud: OrganBud = OrganBud.new()
	fixture.world.add_child(bud)
	var tip: GrowthTip = GrowthTip.new()
	fixture.world.add_child(tip)
	var tissues: Array[Node2D] = [fixture.core, fixture.junction, fixture.last_edge, attack, digestive, bud, tip]
	var maximums: Array[float] = [240.0, 45.0, 35.0, 60.0, 60.0, 25.0, 25.0]
	for index: int in range(tissues.size()):
		var tissue: Node2D = tissues[index]
		var snapshot: Dictionary = tissue.call("get_health_snapshot")
		_close(float(snapshot["max_health"]), maximums[index], "Default health is authoritative")
		_check(snapshot.has("destroyed") and snapshot.has("functional") and tissue.is_in_group("colony_tissues"),
			"Frozen health snapshot and targeting group exposed")
	var deaths: Array[int] = [0]
	fixture.junction.tissue_destroyed.connect(func(_tissue: Node2D) -> void: deaths[0] += 1)
	fixture.junction.take_damage(45.0)
	fixture.junction.take_damage(1.0)
	_check(deaths[0] == 1 and fixture.network.is_node_registered(fixture.junction), "Dead junction persists and signals once")
	fixture.junction.heal(1.0)
	fixture.junction.take_damage(1.0)
	_check(deaths[0] == 2, "A second actual death after revival gets a new transition signal")
	for tissue: Node2D in [attack, digestive, bud, tip]:
		tissue.call("take_damage", 1000.0)
		_close(float(tissue.call("heal", 1000.0)), 0.0, "Destroyed organ or growing tissue cannot resurrect")
		_check(not bool(tissue.call("is_functional")) and not bool(tissue.call("is_repairable")), "Destroyed tissue stays disabled")
	fixture.core.take_damage(fixture.core.health)
	_close(fixture.core.heal(240.0), 0.0, "Dead core cannot heal")
	fixture.world.free()


func _test_attack_host_intent() -> void:
	var fixture: Fixture = _fixture()
	var organ: AttackOrgan = ATTACK_SCENE.instantiate() as AttackOrgan
	fixture.junction.add_child(organ)
	organ.take_damage(1.0)
	_check(organ.is_functional(), "Living damaged organ works")
	var stock: int = organ.nutrition
	fixture.junction.take_damage(45.0)
	_check(not organ.is_work_enabled() and organ.get_requested_work_enabled() and organ.nutrition == stock,
		"Host death gates work while preserving original enabled state and stock")
	_check(not organ.reserve_nutrition(1) and not organ.consume_nutrition(1), "Dead host rejects intake and firing consumption")
	fixture.junction.heal(1.0)
	_check(organ.is_work_enabled(), "Host revival restores prior active organ")
	organ.set_work_enabled(false)
	fixture.junction.take_damage(1.0)
	fixture.junction.heal(1.0)
	_check(not organ.is_work_enabled() and not organ.get_requested_work_enabled(), "Manual pause remains after host revival")
	organ.set_work_enabled(true)
	var observed_stock: Array[int] = [0]
	organ.tissue_destroyed.connect(func(tissue: Node2D) -> void: observed_stock[0] = (tissue as AttackOrgan).nutrition)
	organ.take_damage(100.0)
	_check(observed_stock[0] == stock and organ.nutrition == stock and not organ.complete_delivery(1),
		"Organ death exposes actual inventory before root settlement and rejects deliveries")
	fixture.world.free()


func _test_digestive_pause_and_loss_settlement() -> void:
	var fixture: Fixture = _fixture()
	var organ: DigestiveOrgan = DIGEST_SCENE.instantiate() as DigestiveOrgan
	fixture.junction.add_child(organ)
	_check(organ.reserve_remains() and organ.complete_delivery(6), "First digestion accepts actual intake")
	organ._on_digest_timer_timeout()
	_check(organ.reserve_remains() and organ.complete_delivery(4), "Second digestion starts behind its original output")
	var before: Dictionary = organ.get_digestion_snapshot()
	var chamber: Dictionary = (before["chambers"] as Array)[0]
	var old_generation: int = int(before["generation"])
	var task_id: String = String(chamber["task_id"])
	fixture.junction.take_damage(45.0)
	var paused: Dictionary = organ.get_digestion_snapshot()
	_check(organ.enabled and not organ.is_functional() and bool(paused["host_paused"]), "Digest enabled intent survives host death")
	_check(String(((paused["chambers"] as Array)[0] as Dictionary)["task_id"]) == task_id,
		"Host pause retains digestion task identity and owned input")
	organ._on_chamber_timeout(0, old_generation, task_id)
	fixture.junction.heal(1.0)
	organ._on_chamber_timeout(0, old_generation, task_id)
	_check(organ.get_output_count() == 1 and organ.get_queued_nutrition() == 4, "Old callbacks stay invalid after revival")
	organ._on_digest_timer_timeout()
	_check(organ.get_output_count() == 2 and organ.get_output_nutrition() == 10, "Revived chamber completes exactly once")
	_check(organ.reserve_remains() and organ.complete_delivery(3), "Output backpressure preserves waiting intake")
	var product_id: String = String(organ.get_output_products()[0]["product_id"])
	_check(organ.claim_output_product(product_id, "return-proof"), "Root can identify held in-flight product")
	var observed: Array[int] = [0, 0]
	organ.tissue_destroyed.connect(func(tissue: Node2D) -> void:
		var stomach: DigestiveOrgan = tissue as DigestiveOrgan
		observed[0] = stomach.get_queued_nutrition()
		observed[1] = stomach.get_output_nutrition())
	organ.take_damage(100.0)
	_check(observed == [3, 10], "Digest death emits before any inventory is cleared")
	_check(organ.settle_output_product(product_id, "return-proof") and not organ.settle_output_product(product_id, "return-proof"),
		"Already delivered product settles once after death")
	var losses: Dictionary = organ.clear_destroyed_inventory()
	_check(losses["input_nutrition"] == 3 and losses["output_nutrition"] == 4, "Losses include only still-held inputs and outputs")
	var repeat: Dictionary = organ.clear_destroyed_inventory()
	_check(repeat["input_nutrition"] == 0 and repeat["output_nutrition"] == 0, "Destroyed inventory losses cannot be booked twice")
	fixture.world.free()


func _test_paid_neighbor_repair_and_integer_core() -> void:
	var fixture: Fixture = _fixture()
	fixture.junction.take_damage(45.0)
	_check(not fixture.network.find_route(fixture.core, fixture.downstream).found \
		and not fixture.network.find_available_route(fixture.core, fixture.junction).found \
		and not fixture.network.can_enter_edge(fixture.last_edge), "Ordinary traffic cannot traverse a dead junction")
	var preview: Dictionary = fixture.repair.preview_repair(fixture.junction)
	_check(preview["valid"] and preview["repair_point"] == fixture.neighbor \
		and preview["access_edge"] == fixture.last_edge and int(preview["estimated_cost"]) == 5,
		"Dead-junction repair selects a genuinely connected healthy neighbor")
	var task_id: int = fixture.repair.request_repair(fixture.junction)
	_check(task_id > 0 and fixture.core.nutrition == 32 and fixture.core.get_spendable_nutrition() == 27,
		"Repair budget takes priority without making or debiting stock")
	_deliver_one(fixture)
	fixture.repair.advance(0.25)
	_close(fixture.junction.health, 2.5, "Paid healing is bounded by ten HP per second")
	fixture.last_edge.take_damage(35.0)
	fixture.repair.advance(5.0)
	_close(fixture.junction.health, 2.5, "Broken last work edge stops even already paid healing")
	_check(fixture.core.get_spendable_nutrition() == fixture.core.nutrition, "Disconnected repair releases unpaid budget priority")
	fixture.last_edge.heal(35.0)
	for _unit: int in range(4):
		_deliver_one(fixture)
	fixture.repair.advance(5.0)
	_close(fixture.junction.health, 45.0, "Real supply restores original junction health")
	_check(fixture.core.nutrition == 27 and int(fixture.repair.get_task_snapshot()["consumed_nutrition"]) == 5,
		"Exactly five actual nutrition units pay for forty-five HP")
	_check(fixture.network.find_available_route(fixture.core, fixture.downstream).found,
		"Revival restores normal downstream connectivity")
	fixture.neighbor.take_damage(45.0)
	fixture.junction.take_damage(45.0)
	var isolated_id: int = fixture.repair.request_repair(fixture.junction)
	_check(isolated_id > 0 and not fixture.repair.is_supply_reachable(isolated_id) \
		and not fixture.supply.try_dispatch(), "No repair grant crosses another dead intermediary")
	fixture.repair.cancel_task()
	fixture.core.take_damage(7)
	_check(fixture.repair.request_repair(fixture.core) > 0, "Living damaged core is repairable")
	_deliver_one(fixture)
	for _frame: int in range(10):
		fixture.repair.advance(0.02)
	_check(fixture.core.health == 235, "Integer core retains short-frame repair time without a second health source")
	fixture.repair.advance(1.0)
	_check(fixture.core.health == 240 and fixture.core.nutrition == 26, "Core tail repair costs one real unit")
	fixture.world.free()


func _test_work_connection() -> void:
	var fixture: Fixture = _fixture()
	fixture.last_edge.entry_enabled = false
	_check(fixture.network.is_work_connected_to_core(fixture.junction)
		and not fixture.network.is_available_connected_to_core(fixture.junction),
		"A temporary traffic gate does not strand already-delivered construction cache")
	fixture.last_edge.take_damage(35.0)
	_check(not fixture.network.is_work_connected_to_core(fixture.junction),
		"A truly destroyed edge stops construction work")
	_edge(fixture, fixture.neighbor, fixture.downstream)
	_check(fixture.network.is_work_connected_to_core(fixture.junction),
		"Living bypass restores work without using the destroyed edge")
	fixture.junction.take_damage(45.0)
	_check(not fixture.network.is_work_connected_to_core(fixture.junction)
		and fixture.network.is_work_connected_to_core(fixture.downstream),
		"Dead junction remains disabled while bypassed downstream stays functional")
	fixture.world.free()
