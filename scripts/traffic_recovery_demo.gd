extends "res://scripts/level_01.gd"
## 专用网络验证关卡：玩家测试性伤害调用真实生命接口，恢复必须支付营养修复。

@onready var primary_edge: HyphaEdge = $World/Colony/Connections/DigestionEdge
@onready var bypass_edge: HyphaEdge = $World/Colony/Connections/HyphaEdge
@onready var access_edge: HyphaEdge = $World/Colony/Connections/RightEdge
@onready var demo_status: Label = $RecoveryHUD/Status

var demo_consumed_nutrition: int = 0
var _demo_route_counts: Dictionary[int, int] = {}


func _ready() -> void:
	super._ready()
	$RecoveryHUD/Buttons/Primary.pressed.connect(func() -> void:
		damage_demo_edge(primary_edge))
	$RecoveryHUD/Buttons/Bypass.pressed.connect(func() -> void:
		damage_demo_edge(bypass_edge))
	$RecoveryHUD/Buttons/Restore.pressed.connect(request_demo_repair)
	$RecoveryHUD/Buttons/Supply.pressed.connect(dispatch_demo_supply)
	$RecoveryHUD/Buttons/Access.pressed.connect(func() -> void:
		damage_demo_edge(access_edge))
	hud.show_notice("测试性伤害：1 主路、2 旁路、5 采集段；J / 3 支付营养修复，K 暂停，Backspace 取消")
	_refresh_demo_status()


func _process(delta: float) -> void:
	super._process(delta)
	if is_node_ready():
		_refresh_demo_status()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				damage_demo_edge(primary_edge)
			KEY_2:
				damage_demo_edge(bypass_edge)
			KEY_3:
				request_demo_repair()
			KEY_4:
				dispatch_demo_supply()
			KEY_5:
				damage_demo_edge(access_edge)
			KEY_F6:
				# 场景切换立即使旧节点离树，先标记输入，不能再访问旧视口。
				get_viewport().set_input_as_handled()
				get_tree().change_scene_to_file("res://scenes/levels/large_carcass_demo.tscn")
				return
			_:
				super._unhandled_input(event)
				return
		get_viewport().set_input_as_handled()
	else:
		super._unhandled_input(event)


## 测试入口只伤害所选边；没有免费恢复，实际敌人尚未啃食菌丝。
func damage_demo_edge(edge: HyphaEdge, amount: float = 35.0) -> void:
	if not is_instance_valid(edge) or not network_system.is_edge_valid(edge):
		return
	edge.take_damage(amount)
	repair_input_controller.enter_selection_mode()
	repair_input_controller.select_edge(edge)
	_sync_fungal_sources()
	hud.show_notice("测试性伤害：菌丝生命 %.1f / %.0f；按 J 修复，只有真实营养抵达才恢复" % [edge.health, edge.max_health])
	_refresh_demo_status()


func request_demo_repair() -> void:
	repair_input_controller.request_repair()


## 6.4 自动回归保留的临时禁行接口；正常演示按钮不调用这些方法。

func set_demo_primary_closed(closed: bool) -> void:
	primary_edge.entry_enabled = not closed
	_after_demo_toggle("主路", closed)


func set_demo_bypass_closed(closed: bool) -> void:
	bypass_edge.entry_enabled = not closed
	_after_demo_toggle("旁路入口", closed)


func set_demo_access_closed(closed: bool) -> void:
	access_edge.entry_enabled = not closed
	_after_demo_toggle("右翼采集段", closed)


func restore_demo_edges() -> void:
	for edge: HyphaEdge in network_system.get_registered_edges():
		edge.entry_enabled = true
	_sync_fungal_sources()
	hud.show_notice("仅清除旧测试的临时禁行开关；生命为 0 的菌丝仍需支付营养修复")
	_refresh_demo_status()


## 明示的测试需求也走真实扣款/预留/供养，不注入营养或直接增加库存。
func dispatch_demo_supply() -> void:
	var receiver: AttackOrgan = $World/Colony/Nodes/RightNode/AttackOrgan
	if receiver.consume_nutrition():
		demo_consumed_nutrition += 1
	supply_system.request_supply(receiver)
	_refresh_demo_status()


func _after_demo_toggle(label: String, closed: bool) -> void:
	_sync_fungal_sources()
	hud.show_notice("模拟%s%s：只改变通行开关，保留边、货物和原预留" % [
		label, "断路" if closed else "恢复"])
	_refresh_demo_status()


func get_recovery_demo_snapshot() -> Dictionary:
	var packets: Array[Dictionary] = []
	var waiting: int = 0
	var blocked: int = 0
	for path: String in ["Packets", "GrowthPackets", "CultivationPackets", "RecoveryPackets", "ReturnPackets", "RepairPackets"]:
		for packet: Node in get_node("World/" + path).get_children():
			if packet.is_queued_for_deletion():
				continue
			if packet is NutrientPacket or packet is RemainsPacket:
				var snapshot: Dictionary = packet.get_transport_snapshot()
				snapshot["packet_id"] = packet.get_instance_id()
				snapshot["category"] = path
				packets.append(snapshot)
				waiting += 1 if snapshot.get("state") == &"waiting" else 0
				blocked += 1 if snapshot.get("state") == &"blocked" else 0
	return {
		"primary_closed": not primary_edge.is_traversable(),
		"bypass_closed": not bypass_edge.is_traversable(),
		"access_closed": not access_edge.is_traversable(),
		"waiting": waiting, "blocked": blocked, "packets": packets,
		"traffic": traffic_system.get_snapshot(), "core_nutrition": mother_core.nutrition,
		"stomach_incoming": digestive_organ.incoming_remains,
		"demo_consumed_nutrition": demo_consumed_nutrition,
		"field": fungal_field.get_visual_snapshot(),
		"primary_health": primary_edge.get_health_snapshot(),
		"bypass_health": bypass_edge.get_health_snapshot(),
		"access_health": access_edge.get_health_snapshot(),
		"repair": repair_system.get_task_snapshot(),
		"repair_supply": repair_supply_system.get_supply_snapshot(),
		"budget": mother_core.get_budget_snapshot(),
	}


func _refresh_demo_status() -> void:
	var snapshot: Dictionary = get_recovery_demo_snapshot()
	for packet: Dictionary in snapshot["packets"]:
		_demo_route_counts[int(packet["packet_id"])] = int(packet.get("reroute_count", 0))
	var reroutes: int = 0
	for count: int in _demo_route_counts.values():
		reroutes += count
	demo_status.text = "生命：主路 %.0f · 旁路 %.0f · 采集段 %.0f / 35  |  节点等待 %d · 段内停留 %d · 改道 %d 次" % [
		primary_edge.health, bypass_edge.health, access_edge.health,
		snapshot["waiting"], snapshot["blocked"], reroutes]
