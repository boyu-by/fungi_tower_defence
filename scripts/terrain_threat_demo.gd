class_name TerrainThreatDemo
extends "res://scripts/combat_specialization_demo.gd"
## 第九阶段：固定岩石、前沿损伤与可恢复的真实啃食者危机。

@export var gnawer_batch_entries: Array[EnemySpawnEntry] = []

func _ready() -> void:
	_prepare_terrain_runtime()
	super._ready()
	_connect_terrain_runtime()
	_add_frontier_batch_button()
	combat_hint_controller.set_enabled(false)
	select_test_batch(&"gnawer")
	hud.show_notice("第九阶段｜先 G 接通80/120资源并成长，再开始前沿批次；F选组织、J付费修复，空菌结C重建")








func get_frontier_snapshot() -> Dictionary:
	return {"attacks": tissue_attack_count, "network_breaks": network_break_count,
		"last_attack": _last_attack.duplicate(), "last_loss": _last_loss.duplicate(),
		"resources": get_combat_resource_snapshot(), "batch": get_combat_demo_snapshot()}


func _is_batch_kind(kind: StringName) -> bool:
	return kind == &"gnawer" or super._is_batch_kind(kind)


func _get_batch_title(kind: StringName) -> String:
	return "前沿危机 ×3｜1啃食者从右下入口，2普通轮换" if kind == &"gnawer" else super._get_batch_title(kind)


func _get_batch_entries(kind: StringName) -> Array[EnemySpawnEntry]:
	return gnawer_batch_entries if kind == &"gnawer" else super._get_batch_entries(kind)


func get_batch_choices() -> Array[Dictionary]:
	var choices: Array[Dictionary] = super.get_batch_choices()
	choices.append({"id": &"gnawer", "title": _get_batch_title(&"gnawer"),
		"planned": _get_configured_count(&"gnawer")})
	return choices


func _add_frontier_batch_button() -> void:
	var panel: Control = hud.combat_demo_panel
	var button: Button = Button.new()
	button.name = "GnawerButton"
	button.text = "前沿 ×3"
	button.toggle_mode = true
	button.add_theme_font_size_override("font_size", 13)
	button.tooltip_text = _get_batch_title(&"gnawer")
	button.pressed.connect(func() -> void: hud.combat_batch_selected.emit(&"gnawer"))
	panel.add_child(button)
	var names: Array[String] = ["NormalButton", "SwarmButton", "ArmoredButton", "MixedButton", "GnawerButton"]
	for index: int in range(names.size()):
		var choice: Button = panel.get_node(names[index]) as Button
		choice.position = Vector2(8.0 + 73.0 * index, 24.0)
		choice.size = Vector2(68.0, 25.0)
