class_name ThirdLevelGuide
extends SecondLevelGuide

const THIRD_TEXTS: Dictionary = {
	&"opening": "三个角落的碎片从开局可见。让连通母核的有效菌域覆盖目标5秒；顺序不限，也可双线探索。",
	&"nutrition_returned": "尸骸已形成真实回流。四处大型尸骸分别提供80、80、80和120养分，可先接资源再探索。",
	&"fragment_collected": "碎片已永久保留，断路不会丢失；未完成目标失联时暂停计时，接通后继续。",
	&"armored": "重甲会削减普通伤害。先在前沿建立破甲火力，等分化完成后再继续种芽；分化期间该器官停火。",
}


func record_event(event_id: StringName, facts: Dictionary = {}) -> void:
	if not THIRD_TEXTS.has(event_id):
		super.record_event(event_id, facts)
		return
	if _seen.has(event_id):
		return
	_seen[event_id] = true
	_seen_order.append(event_id)
	if is_enabled:
		_pending.append({"id": event_id, "text": String(THIRD_TEXTS[event_id])})
		_show_next()
	_publish()
