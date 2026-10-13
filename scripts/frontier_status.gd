class_name FrontierStatus
extends Node2D
## 只读战场标记：生命、失联、敌人目标和预览中的未保护路段。

@export var compact_labels: bool = false
@export var exposure_label_position: Vector2 = Vector2(405, 245)

var level: Node2D
var preview: Dictionary = {}
var _font: SystemFont


func _ready() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC"])
	z_index = 15


func _process(_delta: float) -> void:
	queue_redraw()


func show_preview(value: Dictionary) -> void:
	preview = value.duplicate(true)


func clear_preview(placing: bool) -> void:
	if not placing:
		preview.clear()


func get_exposed_length(plan: Dictionary) -> float:
	var length: float = 0.0
	for segment: Dictionary in plan.get("segments", []):
		var start: Vector2 = segment["start_position"]
		var end: Vector2 = segment["end_position"]
		var steps: int = maxi(1, ceili(start.distance_to(end) / 12.0))
		for index: int in range(steps):
			if not _protected(start.lerp(end, (float(index) + 0.5) / steps)):
				length += start.distance_to(end) / steps
	return length


func _draw() -> void:
	if not is_instance_valid(level) or _font == null:
		return
	var network: NetworkSystem = level.get("network_system") as NetworkSystem
	for node: Node in get_tree().get_nodes_in_group("colony_tissues"):
		if not level.is_ancestor_of(node) or node.is_queued_for_deletion() or not node is Node2D:
			continue
		var health: Dictionary = node.call("get_health_snapshot")
		var hp: float = float(health.get("health", 0.0))
		var maximum: float = float(health.get("max_health", 1.0))
		if compact_labels and hp >= maximum:
			var selected: Variant = level.get("selected_node")
			var repair: RepairInputController = level.get("repair_input_controller") as RepairInputController
			var inspecting: bool = node == selected or node.get_parent() == selected \
				or (is_instance_valid(repair) and repair.get_selected_target() == node)
			var disconnected: bool = node is HyphaNode and not network.is_available_connected_to_core(node)
			if not inspecting and not disconnected and not node is GrowthTip and not node is OrganBud:
				continue
		var point: Vector2 = (node as Node2D).global_position
		var caption: String = ""
		if node is MotherCore:
			continue
		elif node is HyphaEdge:
			if hp >= maximum or not node.has_endpoints() \
					or (hp > 0.0 and not bool(node.get_meta("combat_injured", false))):
				continue
			point = node.get_point_at(0.5)
			caption = "断路" if hp <= 0.0 else "菌丝"
		elif node is HyphaNode:
			caption = "枯结" if hp <= 0.0 else ("失联" if not network.is_available_connected_to_core(node) else "菌结")
			if hp <= 0.0:
				var center: Vector2 = to_local(point)
				draw_circle(center, 17.0, Color("665953"), true)
				draw_line(center - Vector2(8, 8), center + Vector2(8, 8), Color("e8a06d"), 2.0, true)
				draw_line(center + Vector2(-8, 8), center + Vector2(8, -8), Color("e8a06d"), 2.0, true)
			point += Vector2(-24.0, 40.0 if node.get_organ_occupant() != null else 23.0)
		elif node is GrowthTip:
			point += Vector2(-16.0, -22.0)
			caption = "尖端"
		else:
			point += Vector2(38.0, -40.0) if node is DigestiveOrgan else Vector2(-30.0, -76.0)
			if point.x > 730.0 and point.y < 360.0:
				point.y = 360.0
			caption = "胃囊" if node is DigestiveOrgan else ("芽" if node is OrganBud else "器官")
		var color: Color = Color("e98272") if hp < maximum else Color("b2ceb7")
		if caption == "失联" or caption == "枯结":
			color = Color("e8a06d")
		draw_string(_font, to_local(point), "%s %.0f/%.0f" % [caption, hp, maximum], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, color)
	for enemy: Node in level.get_node("World/Enemies").get_children():
		if not enemy is BasicEnemy or not enemy.is_alive():
			continue
		var target: Dictionary = enemy.get_target_snapshot()
		if not is_instance_valid(target.get("target")):
			continue
		var point: Vector2 = target.get("position", enemy.global_position)
		draw_dashed_line(to_local(enemy.global_position), to_local(point), Color(0.95, 0.35, 0.24, 0.75), 1.0, 5.0)
		draw_arc(to_local(point), 17.0, 0.0, TAU, 24, Color("ed795d"), 2.0, true)
	_draw_exposure()


func _draw_exposure() -> void:
	if not bool(preview.get("valid", false)):
		return
	var plan: Dictionary = preview.get("plan", {})
	for segment: Dictionary in plan.get("segments", []):
		var start: Vector2 = segment["start_position"]
		var end: Vector2 = segment["end_position"]
		var steps: int = maxi(1, ceili(start.distance_to(end) / 12.0))
		for index: int in range(steps):
			var a: Vector2 = start.lerp(end, float(index) / steps)
			var b: Vector2 = start.lerp(end, float(index + 1) / steps)
			if not _protected((a + b) * 0.5):
				draw_line(to_local(a), to_local(b), Color("f59b53"), 3.0, true)
	var exposed: float = get_exposed_length(plan)
	if exposed > 0.0:
		draw_string(_font, exposure_label_position, "橙段 %.0f 像素缺少火力保护 · 仍可建设" % exposed, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color("f5b879"))


func _protected(point: Vector2) -> bool:
	if not is_instance_valid(level):
		return false
	for weapon: SporeWeapon in level.call("get_weapons"):
		var owner: AttackOrgan = weapon.inventory_owner
		if is_instance_valid(owner) and owner.is_functional() and weapon.is_firing_enabled() \
				and point.distance_to(owner.global_position) <= weapon.attack_range:
			return true
	return false
