class_name NetworkRoute
extends RefCounted

## 一次查询的路线快照；未找到路线时，segments 为空。

class Segment:
	extends RefCounted

	## start_node / end_node 是行进方向，forward 对应边的原始端点方向。
	var edge: HyphaEdge = null
	var start_node: Node2D = null
	var end_node: Node2D = null
	var forward: bool = false


var found: bool = false
var start_node: Node2D = null
var end_node: Node2D = null
var segments: Array[Segment] = []
