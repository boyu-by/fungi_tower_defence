class_name SecondLevelHUD
extends FirstLevelHUD
## 共用结算面板与工具坞的数据源；第二关按设施目标显示，不套用六波语义。


func _render_flow() -> void:
	var completed: int = int(_flow_snapshot.get("completed", 0))
	var facilities: Array = _flow_snapshot.get("facilities", [])
	wave_label.text = "第二关 · AI冲击"
	progress_label.text = "摧毁 AI %d/3 · 持续生产没有固定波数" % completed
	var rows: PackedStringArray = []
	var next_spawn: float = INF
	for facility: Dictionary in facilities:
		rows.append("%s：%s" % [facility.get("name", "AI"),
			"已摧毁" if facility.get("destroyed", false) else "%d/%d 生命 · %.0fs" % [
				facility.get("health", 0), facility.get("max_health", 0), facility.get("remaining", 0)]])
		if not facility.get("destroyed", false):
			next_spawn = minf(next_spawn, float(facility.get("remaining", 0)))
	counts_label.text = "\n".join(rows)
	next_label.text = "下次生产约 %ds · 摧毁设施永久停掉该来源" % ceili(next_spawn) if is_finite(next_spawn) else "三台设施均已摧毁"
	pause_label.text = "已暂停 · 生产与运输计时冻结" if _paused else "推进、培育前沿火力，正常射击摧毁设施"
	start_button.text = "提前开始进攻"
	start_button.disabled = _paused or _has_result or not bool(_flow_snapshot.get("can_start", false))
	pause_button.text = "恢复 · Space" if _paused else "暂停 · Space"
	pause_button.disabled = _has_result
	for label: Label in [wave_label, progress_label, counts_label, next_label, pause_label]:
		label.tooltip_text = label.text
	start_button.tooltip_text = "提前结束开局准备；此后设施各自持续生产。"


func _render_result() -> void:
	result_panel.visible = _has_result
	if not _has_result:
		return
	var won: bool = bool(_result_snapshot.get("victory", false))
	var objective: Dictionary = _result_snapshot.get("objective", {})
	result_title.text = "AI冲击 · 第二关胜利" if won else "母核失守"
	result_subtitle.text = "三台AI均已摧毁" if won else "重新组织前沿防线后再次挑战"
	result_left_label.text = "摧毁设施：%d / 3\n累计回收：%d 营养" % [
		int(objective.get("completed", 0)), int(_result_snapshot.get("total_recovered", 0))]
	result_right_label.text = "母核生命：%s\n本局用时：%s" % [
		_health_text(float(_result_snapshot.get("core_health", 0))),
		_time_text(float(_result_snapshot.get("elapsed_seconds", 0)))]
