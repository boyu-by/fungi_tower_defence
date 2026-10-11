extends SceneTree
## 独立网络测试：不加载关卡、供养系统或运输脚本。

var failures: Array[String] = []
var checks: int = 0
var _objects: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_registration()
	_test_direct_and_same_node_routes()
	_test_multi_hop_routes()
	_test_cycles_and_alternate_routes()
	_test_disconnected_peers()
	_test_edge_removal()
	_test_node_removal()
	_test_live_endpoints()
	await _test_queued_objects()
	_test_freed_objects()
	_test_tree_exit()
	_free_objects()
	_check(root.get_child_count() == 0, "Test cleanup left nodes in the scene tree")
	print("NETWORK_TEST_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


## 所有断言都计数，失败时继续执行其余独立场景。
func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error(description)


## 弱引用清理名单也兼容测试中主动 free 的对象。
func _track(node: Node) -> void:
	_objects.append(weakref(node))


func _new_network() -> NetworkSystem:
	var network: NetworkSystem = NetworkSystem.new()
	_track(network)
	return network


func _new_node() -> Node2D:
	var node: Node2D = Node2D.new()
	_track(node)
	return node


## Vein 使边进入场景树时也满足 HyphaEdge 自身的绘制接口。
func _new_edge(start: Node2D, end: Node2D) -> HyphaEdge:
	var edge: HyphaEdge = HyphaEdge.new()
	edge.start_node = start
	edge.end_node = end
	var vein: Line2D = Line2D.new()
	vein.name = "Vein"
	edge.add_child(vein)
	edge.set_process(false)
	_track(edge)
	return edge


## 同时验证边顺序、每段行进端点、正反向标志与无环性。
func _check_route(route: NetworkRoute, edges: Array[HyphaEdge], nodes: Array[Node2D],
		directions: Array[bool], context: String) -> void:
	if route == null:
		_check(false, context + ": returned null")
		return
	_check(route.found, context + ": route was not found")
	_check(route.start_node == nodes[0] and route.end_node == nodes[-1],
		context + ": route endpoints")
	_check(route.segments.size() == edges.size(), context + ": segment count")
	var visited: Array[Node2D] = [nodes[0]]
	for index: int in range(mini(route.segments.size(), edges.size())):
		var segment: NetworkRoute.Segment = route.segments[index]
		_check(segment.edge == edges[index], context + ": edge order %d" % index)
		_check(segment.start_node == nodes[index] and segment.end_node == nodes[index + 1],
			context + ": segment endpoints %d" % index)
		_check(segment.forward == directions[index], context + ": direction %d" % index)
		_check(not visited.has(segment.end_node), context + ": route contains a cycle")
		visited.append(segment.end_node)


## 未找到与同节点零段成功路线必须通过 found 区分。
func _check_no_route(route: NetworkRoute, context: String) -> void:
	if route == null:
		_check(false, context + ": returned null")
		return
	_check(not route.found, context + ": unexpected route")
	_check(route.segments.is_empty(), context + ": failed route retained segments")


func _test_registration() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var other: Node2D = _new_node()
	var absent: Node2D = _new_node()
	var changes: Array[int] = [0]
	network.network_changed.connect(func() -> void: changes[0] += 1)
	_check(network.register_node(core, true), "Core registration failed")
	_check(network.register_node(core, true), "Repeated core registration failed")
	_check(network.register_node(core), "Repeated ordinary registration of core failed")
	_check(changes[0] == 1, "Idempotent node registration emitted a change")
	_check(not network.register_node(null), "Null node was registered")
	_check(not network.register_node(other, true), "A second mother core was accepted")
	_check(not network.get_registered_nodes().has(other), "Rejected core was partly registered")
	_check(network.register_node(other), "Ordinary node registration failed")
	_check(not network.register_node(other, true), "Registered peer replaced the existing core")
	var snapshot: Array[Node2D] = network.get_registered_nodes()
	snapshot.clear()
	_check(network.get_registered_nodes().size() == 2, "Returned node array changed the registry")
	_check(network.is_connected_to_core(core), "Core was not connected to itself")
	_check(not network.is_connected_to_core(other), "Isolated node connected to core")
	var edge: HyphaEdge = _new_edge(core, absent)
	_check(not network.register_edge(edge), "Edge with unregistered endpoint was accepted")
	_check(not network.register_edge(null), "Null edge was registered")
	edge.end_node = null
	_check(not network.register_edge(edge), "Edge with null endpoint was accepted")
	edge.end_node = other
	_check(network.register_edge(edge), "Valid edge registration failed")
	_check(network.register_edge(edge), "Repeated edge registration failed")
	_check(changes[0] == 3, "Rejected or repeated registration emitted a change")
	network.unregister_node(absent)
	network.unregister_node(null)
	network.unregister_edge(_new_edge(core, other))
	network.unregister_edge(null)
	_check(changes[0] == 3, "Unknown object removal emitted a change")
	network.unregister_node(core)
	_check(changes[0] == 4, "Node removal emitted duplicate changes for incident edges")
	_check(network.register_node(other, true), "Core designation was not released on removal")
	_check(changes[0] == 5, "Promoting an existing node did not emit a change")
	_check(is_instance_valid(core) and is_instance_valid(edge), "Unregistration freed owned objects")


func _test_direct_and_same_node_routes() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var peer: Node2D = _new_node()
	var isolated: Node2D = _new_node()
	var absent: Node2D = _new_node()
	network.register_node(core, true)
	network.register_node(peer)
	network.register_node(isolated)
	var edge: HyphaEdge = _new_edge(core, peer)
	network.register_edge(edge)
	_check_route(network.find_route(core, peer), [edge], [core, peer], [true], "Direct route")
	_check_route(network.find_route(peer, core), [edge], [peer, core], [false], "Reverse route")
	_check(network.is_connected_to_core(peer), "Direct peer did not connect to core")
	_check(not network.is_connected_to_core(isolated), "Isolated node connected to core")
	_check_route(network.find_route(core, core), [], [core], [], "Core same-node route")
	_check_route(network.find_route(isolated, isolated), [], [isolated], [], "Isolated same-node route")
	_check_no_route(network.find_route(core, isolated), "Registered unreachable nodes")
	_check_no_route(network.find_route(absent, absent), "Unregistered same-node route")
	_check_no_route(network.find_route(core, absent), "Unregistered endpoint")
	_check_no_route(network.find_route(null, peer), "Null start")
	_check_no_route(network.find_route(core, null), "Null end")
	_check_no_route(network.find_route(null, null), "Both endpoints null")
	var missing: NetworkRoute = network.find_route(core, absent)
	_check(missing.start_node == core and missing.end_node == absent,
		"Failed route lost valid query endpoints")


func _test_multi_hop_routes() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var first: Node2D = _new_node()
	var second: Node2D = _new_node()
	var tip: Node2D = _new_node()
	network.register_node(core, true)
	for node: Node2D in [first, second, tip]:
		network.register_node(node)
	var first_edge: HyphaEdge = _new_edge(core, first)
	var second_edge: HyphaEdge = _new_edge(second, first)
	var third_edge: HyphaEdge = _new_edge(second, tip)
	for edge: HyphaEdge in [first_edge, second_edge, third_edge]:
		network.register_edge(edge)
	_check_route(network.find_route(core, tip), [first_edge, second_edge, third_edge],
		[core, first, second, tip], [true, false, true], "Mixed-direction multi-hop route")
	_check_route(network.find_route(tip, core), [third_edge, second_edge, first_edge],
		[tip, second, first, core], [false, true, false], "Reverse multi-hop route")
	_check(network.is_connected_to_core(tip), "Generic temporary tip did not connect to core")


func _test_cycles_and_alternate_routes() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var first: Node2D = _new_node()
	var second: Node2D = _new_node()
	var target: Node2D = _new_node()
	var isolated: Node2D = _new_node()
	network.register_node(core, true)
	for node: Node2D in [first, second, target, isolated]:
		network.register_node(node)
	var first_edge: HyphaEdge = _new_edge(core, first)
	var cross_edge: HyphaEdge = _new_edge(first, second)
	var direct_edge: HyphaEdge = _new_edge(core, second)
	var first_target: HyphaEdge = _new_edge(first, target)
	var second_target: HyphaEdge = _new_edge(second, target)
	for edge: HyphaEdge in [first_edge, cross_edge, direct_edge, first_target, second_target]:
		network.register_edge(edge)
	_check(network.register_edge(_new_edge(first, first)), "Registered self-loop was rejected")
	_check_route(network.find_route(core, second), [direct_edge], [core, second], [true],
		"BFS prefers later direct edge over earlier two-hop chain")
	_check_route(network.find_route(second, core), [direct_edge], [second, core], [false],
		"Reverse triangle route")
	for repeat: int in range(3):
		_check_route(network.find_route(core, target), [first_edge, first_target],
			[core, first, target], [true, true], "Deterministic equal-hop choice %d" % repeat)
	_check_no_route(network.find_route(core, isolated), "Cycle cannot reach isolated node")
	network.unregister_edge(direct_edge)
	_check_route(network.find_route(core, second), [first_edge, cross_edge],
		[core, first, second], [true, true], "Triangle alternate path after edge removal")
	network.unregister_edge(first_edge)
	_check_no_route(network.find_route(core, target), "Isolated core after bridge removals")
	_check_route(network.find_route(first, target), [first_target], [first, target], [true],
		"Routes inside remaining cyclic component")


func _test_disconnected_peers() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var first: Node2D = _new_node()
	var second: Node2D = _new_node()
	network.register_node(core, true)
	network.register_node(first)
	network.register_node(second)
	var edge: HyphaEdge = _new_edge(first, second)
	network.register_edge(edge)
	_check(not network.is_connected_to_core(first) and not network.is_connected_to_core(second),
		"Disconnected component reached core")
	_check_route(network.find_route(first, second), [edge], [first, second], [true],
		"Disconnected peers still have a route")
	network.unregister_node(core)
	_check(not network.is_connected_to_core(first), "Coreless network reported core connectivity")
	_check_route(network.find_route(second, first), [edge], [second, first], [false],
		"Peer route without designated core")
	_check_route(network.find_route(first, first), [], [first], [], "Same-node route without core")
	_check(network.register_node(first, true), "Coreless network rejected core designation")
	_check(network.is_connected_to_core(second), "New core designation did not connect peers")


func _test_edge_removal() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var peer: Node2D = _new_node()
	network.register_node(core, true)
	network.register_node(peer)
	var edge: HyphaEdge = _new_edge(core, peer)
	network.register_edge(edge)
	network.unregister_edge(edge)
	network.unregister_edge(edge)
	_check_no_route(network.find_route(core, peer), "Explicit edge removal")
	_check(is_instance_valid(edge), "Edge removal freed the edge")
	_check(network.register_edge(edge), "Removed edge could not be registered again")
	var alternate: HyphaEdge = _new_edge(core, peer)
	network.register_edge(alternate)
	_check_route(network.find_route(core, peer), [edge], [core, peer], [true], "Parallel edge order")
	network.unregister_edge(edge)
	_check_route(network.find_route(core, peer), [alternate], [core, peer], [true],
		"Parallel alternate after removal")
	network.register_edge(edge)
	_check_route(network.find_route(core, peer), [alternate], [core, peer], [true],
		"Re-registered edge joins the end of deterministic order")
	network.free()
	_check(is_instance_valid(core) and is_instance_valid(peer) and is_instance_valid(edge),
		"Freeing network freed registered external objects")
	root.add_child(core)
	root.remove_child(core)


func _test_node_removal() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var bridge: Node2D = _new_node()
	var peer: Node2D = _new_node()
	var other: Node2D = _new_node()
	network.register_node(core, true)
	for node: Node2D in [bridge, peer, other]:
		network.register_node(node)
	var first_edge: HyphaEdge = _new_edge(core, bridge)
	var second_edge: HyphaEdge = _new_edge(bridge, peer)
	var unrelated: HyphaEdge = _new_edge(peer, other)
	for edge: HyphaEdge in [first_edge, second_edge, unrelated]:
		network.register_edge(edge)
	network.unregister_node(bridge)
	network.unregister_node(bridge)
	_check_no_route(network.find_route(core, peer), "Bridge node removal")
	_check(not network.get_registered_nodes().has(bridge), "Removed bridge remained registered")
	_check_route(network.find_route(peer, other), [unrelated], [peer, other], [true],
		"Unrelated edge survives node removal")
	network.register_node(bridge)
	_check_no_route(network.find_route(core, bridge), "Node re-registration did not restore first edge")
	_check_no_route(network.find_route(bridge, peer), "Node re-registration did not restore second edge")
	network.register_edge(first_edge)
	_check_no_route(network.find_route(core, peer), "Only one incident edge was re-registered")
	network.register_edge(second_edge)
	_check_route(network.find_route(core, peer), [first_edge, second_edge], [core, bridge, peer],
		[true, true], "Explicit incident edge re-registration")
	network.unregister_node(core)
	_check(not network.is_connected_to_core(peer), "Removed core retained its designation")
	_check_route(network.find_route(bridge, peer), [second_edge], [bridge, peer], [true],
		"Removing core leaves peer routes available")
	network.register_node(core, true)
	_check_no_route(network.find_route(core, peer), "Core re-registration resurrected old edge")
	network.register_edge(first_edge)
	_check(network.is_connected_to_core(peer), "Restoring core edge did not restore connectivity")


func _test_live_endpoints() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var first: Node2D = _new_node()
	var second: Node2D = _new_node()
	var absent: Node2D = _new_node()
	network.register_node(core, true)
	network.register_node(first)
	network.register_node(second)
	var edge: HyphaEdge = _new_edge(core, first)
	network.register_edge(edge)
	var old_route: NetworkRoute = network.find_route(core, first)
	edge.end_node = second
	_check_no_route(network.find_route(core, first), "Old endpoint after mutation")
	_check_route(network.find_route(core, second), [edge], [core, second], [true],
		"New endpoint is read immediately")
	_check(not network.is_connected_to_core(first) and network.is_connected_to_core(second),
		"Connectivity ignored live endpoint change")
	_check_route(old_route, [edge], [core, first], [true], "Existing route keeps traversal snapshot")
	edge.start_node = second
	edge.end_node = core
	_check_route(network.find_route(core, second), [edge], [core, second], [false],
		"Swapped edge endpoints change direction")
	edge.start_node = null
	_check_no_route(network.find_route(core, second), "Null start endpoint")
	_check(not network.register_edge(edge), "Invalid live edge could be registered")
	edge.start_node = core
	edge.end_node = null
	_check_no_route(network.find_route(core, second), "Null end endpoint")
	edge.end_node = second
	_check_route(network.find_route(core, second), [edge], [core, second], [true],
		"Restored endpoints are read without edge re-registration")
	edge.end_node = absent
	_check_no_route(network.find_route(core, absent), "Mutated unregistered endpoint")
	_check(not network.register_edge(edge), "Unregistered live endpoint allowed edge registration")
	network.register_node(absent)
	_check_route(network.find_route(core, absent), [edge], [core, absent], [true],
		"Newly registered live endpoint becomes usable")
	network.unregister_node(absent)
	network.register_node(absent)
	_check_no_route(network.find_route(core, absent), "Removing mutated endpoint deleted its edge")
	network.register_edge(edge)
	edge.start_node = first
	edge.end_node = second
	_check_no_route(network.find_route(core, second), "Both endpoints moved away from core")
	_check_route(network.find_route(first, second), [edge], [first, second], [true],
		"Both mutated peer endpoints are live")


func _test_queued_objects() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var bridge: Node2D = _new_node()
	var peer: Node2D = _new_node()
	network.register_node(core, true)
	network.register_node(bridge)
	network.register_node(peer)
	var queued_edge: HyphaEdge = _new_edge(core, bridge)
	network.register_edge(queued_edge)
	queued_edge.queue_free()
	_check_no_route(network.find_route(core, bridge), "Queued edge ignored immediately")
	_check(not network.register_edge(queued_edge), "Queued edge could be re-registered")
	await process_frame
	await process_frame
	_check(not is_instance_valid(queued_edge), "Queued edge was not freed")
	_check_no_route(network.find_route(core, bridge), "Freed queued edge left usable topology")
	var first_edge: HyphaEdge = _new_edge(core, bridge)
	var second_edge: HyphaEdge = _new_edge(bridge, peer)
	network.register_edge(first_edge)
	network.register_edge(second_edge)
	bridge.queue_free()
	_check_no_route(network.find_route(core, peer), "Queued bridge ignored immediately")
	_check(not network.register_node(bridge), "Queued node could be re-registered")
	_check(not network.get_registered_nodes().has(bridge), "Queued node remained in registry snapshot")
	_check_no_route(network.find_route(bridge, bridge), "Queued same-node route is not successful")
	await process_frame
	await process_frame
	_check(not is_instance_valid(bridge), "Queued bridge was not freed")
	_check(network.get_registered_nodes().size() == 2, "Freed bridge left stale node registration")
	first_edge.end_node = peer
	_check_no_route(network.find_route(core, peer), "Changing removed incident edge did not restore it")
	network.register_edge(first_edge)
	_check_route(network.find_route(core, peer), [first_edge], [core, peer], [true],
		"Explicit registration after queued node removal")
	core.queue_free()
	_check(not network.is_connected_to_core(peer), "Queued core retained connectivity")
	_check_route(network.find_route(peer, peer), [], [peer], [], "Peer same-node route after core loss")
	await process_frame
	await process_frame
	_check(network.get_registered_nodes().size() == 1, "Queued core retained registration")
	_check(network.register_node(peer, true), "Queued core designation was not released")


func _test_freed_objects() -> void:
	var network: NetworkSystem = _new_network()
	var core: Node2D = _new_node()
	var bridge: Node2D = _new_node()
	var peer: Node2D = _new_node()
	network.register_node(core, true)
	network.register_node(bridge)
	network.register_node(peer)
	var freed_edge: HyphaEdge = _new_edge(core, bridge)
	network.register_edge(freed_edge)
	freed_edge.free()
	_check_no_route(network.find_route(core, bridge), "Directly freed tree-external edge")
	var first_edge: HyphaEdge = _new_edge(core, bridge)
	var second_edge: HyphaEdge = _new_edge(bridge, peer)
	network.register_edge(first_edge)
	network.register_edge(second_edge)
	bridge.free()
	_check_no_route(network.find_route(core, peer), "Directly freed tree-external bridge")
	_check(network.get_registered_nodes().size() == 2, "Freed node remained registered")
	first_edge.end_node = peer
	second_edge.start_node = core
	_check_no_route(network.find_route(core, peer), "Freed node incident edges were still registered")
	network.register_edge(second_edge)
	_check_route(network.find_route(core, peer), [second_edge], [core, peer], [true],
		"Edge can be explicitly restored after freed endpoint replacement")
	core.free()
	_check(not network.is_connected_to_core(peer), "Directly freed core retained connectivity")
	_check(network.register_node(peer, true), "Freed core designation was not released")
	_check(network.is_connected_to_core(peer), "Replacement core did not connect to itself")


func _test_tree_exit() -> void:
	var network: NetworkSystem = _new_network()
	var container: Node2D = _new_node()
	var core: Node2D = _new_node()
	var peer: Node2D = _new_node()
	var edge: HyphaEdge = _new_edge(core, peer)
	root.add_child(container)
	container.add_child(core)
	container.add_child(peer)
	container.add_child(edge)
	network.register_node(core, true)
	network.register_node(peer)
	network.register_edge(edge)
	container.remove_child(edge)
	_check_no_route(network.find_route(core, peer), "Edge tree exit unregisters edge")
	container.add_child(edge)
	_check_no_route(network.find_route(core, peer), "Edge tree re-entry did not restore registration")
	network.register_edge(edge)
	_check_route(network.find_route(core, peer), [edge], [core, peer], [true],
		"Edge registration after tree re-entry")
	container.remove_child(peer)
	_check(not network.get_registered_nodes().has(peer), "Node tree exit did not unregister node")
	container.add_child(peer)
	network.register_node(peer)
	_check_no_route(network.find_route(core, peer), "Node re-entry resurrected incident edge")
	network.register_edge(edge)
	_check(network.is_connected_to_core(peer), "Tree re-entry edge registration failed")
	root.remove_child(container)
	_check(network.get_registered_nodes().is_empty(), "Container tree exit retained child registrations")
	_check(not network.is_connected_to_core(peer), "Container tree exit retained core designation")
	_check(network.register_node(core, true) and network.register_node(peer),
		"Exited nodes cannot be registered while outside tree")
	_check_no_route(network.find_route(core, peer), "Container exit retained old edge registration")
	network.register_edge(edge)
	_check_route(network.find_route(core, peer), [edge], [core, peer], [true],
		"Tree-external registration after container exit")


## 网络先释放，外部对象随后自行清理，避免测试退出时孤儿对象。
func _free_objects() -> void:
	for reference: WeakRef in _objects:
		var node: Node = reference.get_ref() as Node
		if is_instance_valid(node):
			node.free()
	_objects.clear()
