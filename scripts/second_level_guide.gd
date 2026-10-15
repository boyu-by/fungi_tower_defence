class_name SecondLevelGuide
extends FirstEventGuide

const SECOND_TEXTS: Dictionary = {
	&"remains_returned": "尸骸已送到胃囊。前沿扩张仍要保护回收与供养路线。",
	&"nutrition_returned": "回收营养已入账。两侧80尸骸可支持向AI设施推进。",
	&"facility_destroyed": "AI已停产，已出生敌人仍会行动。其余设施至少留出20秒整备。",
	&"silk_gnawer": "菌丝啃食者只直接攻击菌丝。保护运输线路，必要时修复或建立旁路。",
	&"junction_gnawer": "菌结啃食者只直接攻击菌结。保护据点，器官失联后无法正常工作。",
	&"swarm": "小型敌人成组靠近。成熟后可用散射分化增加应对能力。",
	&"armored": "重甲敌人会抵扣普通伤害。成熟后可用破甲分化应对。",
}


func record_event(event_id: StringName, _facts: Dictionary = {}) -> void:
	if not SECOND_TEXTS.has(event_id) or _seen.has(event_id):
		return
	_seen[event_id] = true
	_seen_order.append(event_id)
	if is_enabled:
		_pending.append({"id": event_id, "text": String(SECOND_TEXTS[event_id])})
		_show_next()
	_publish()
