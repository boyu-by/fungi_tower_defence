class_name CompactHUDPage
extends VBoxContainer
## 只镜像原界面的文本和按钮状态；动作仍交给原控制器，不复制游戏规则。

var _labels: Array[Dictionary] = []
var _buttons: Array[Dictionary] = []
var _progress: Array[Dictionary] = []
var mutation_buttons: Array[Button] = []


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)
	mouse_filter = Control.MOUSE_FILTER_PASS


func heading(caption: String) -> Label:
	var label: Label = text(caption)
	label.add_theme_color_override("font_color", Color("c7d9a2"))
	label.add_theme_font_size_override("font_size", 15)
	return label


func text(caption: String, parent: Node = null) -> Label:
	var label := Label.new()
	label.text = caption
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(self if parent == null else parent).add_child(label)
	return label


func mirror_label(source: Label, full_tooltip: bool = false, parent: Node = null) -> Label:
	var target: Label = text(source.text, parent)
	_labels.append({"source": source, "target": target, "full": full_tooltip})
	return target


func row(columns: int = 2) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(grid)
	return grid


func action(caption: String, callback: Callable, parent: Node = null,
		mutates: bool = false) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 38
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	(self if parent == null else parent).add_child(button)
	if mutates:
		mutation_buttons.append(button)
	return button


func mirror_button(source: Button, parent: Node = null, mutates: bool = false) -> Button:
	var target: Button = action(source.text, _activate.bind(source, mutates), parent)
	_buttons.append({"source": source, "target": target, "mutates": mutates})
	return target


func mirror_progress(source: ProgressBar) -> ProgressBar:
	var target := ProgressBar.new()
	target.custom_minimum_size.y = 8
	target.show_percentage = false
	target.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(target)
	_progress.append({"source": source, "target": target})
	return target


func disclosure(caption: String) -> VBoxContainer:
	var button: Button = action(caption + "  ▸", func() -> void: pass)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	content.visible = false
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(content)
	button.toggled.connect(func(open: bool) -> void:
		content.visible = open
		button.text = caption + ("  ▾" if open else "  ▸"))
	return content


func refresh() -> void:
	var paused: bool = is_inside_tree() and get_tree().paused
	for binding: Dictionary in _labels:
		var source: Label = binding.source
		var target: Label = binding.target
		var value: String = source.tooltip_text if binding.full and not source.tooltip_text.is_empty() else source.text
		if target.text != value:
			target.text = value
		target.tooltip_text = source.tooltip_text
	for binding: Dictionary in _buttons:
		var source: Button = binding.source
		var target: Button = binding.target
		target.text = source.text
		target.tooltip_text = source.tooltip_text
		target.disabled = source.disabled or (binding.mutates and paused)
	for button: Button in mutation_buttons:
		button.disabled = paused
	for binding: Dictionary in _progress:
		var source: ProgressBar = binding.source
		var target: ProgressBar = binding.target
		target.max_value = source.max_value
		target.value = source.value


func _activate(source: Button, mutates: bool) -> void:
	if not is_instance_valid(source) or source.disabled or (mutates and get_tree().paused):
		return
	source.pressed.emit()
	refresh()
