class_name ArtUI
extends RefCounted
## 只处理界面表现；按钮文字仍保留供提示、无障碍及业务读取。
const INK := Color("55494b")
const FONT = preload("res://resources/ui/ui_font.tres")
const HEADING_FONT = preload("res://resources/ui/ui_heading_font.tres")
const UI := "res://assets/ui/handdrawn/controls/"
const WINDOW_PADDING := Vector4(56, 80, 56, 80)
const WIDE_WINDOW_PADDING := Vector4(56, 64, 32, 40)
static var _themes: Dictionary = {}

static func paper(path: String, margin: float = 12.0) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = load(path)
	for side: int in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		box.set_texture_margin(side, 80.0 if path.ends_with("/窗口.png") else 16.0)
		box.set_content_margin(side, margin)
	if path.ends_with("/窗口.png") or path.ends_with("/窗口 (2).png"):
		var padding: Vector4 = WINDOW_PADDING if path.ends_with("/窗口.png") else WIDE_WINDOW_PADDING
		for side: int in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			box.set_content_margin(side, maxf(margin, padding[side]))
			box.set_texture_margin(side, 80 if path.ends_with("/窗口.png") else 64)
	return box

static func theme(size: int = 22) -> Theme:
	if _themes.has(size):
		return _themes[size]
	var result := Theme.new()
	result.default_font = FONT
	result.default_font_size = size
	result.set_constant("line_spacing", "Label", 4)
	for type: String in ["Button", "OptionButton", "CheckButton", "Label", "RichTextLabel", "LineEdit", "PopupMenu", "ProgressBar"]:
		for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "default_color"]:
			result.set_color(state, type, INK)
		result.set_color("font_disabled_color", type, Color("998c8e"))
	for type: String in ["Button", "OptionButton", "CheckButton"]:
		for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			var box := paper(UI + "框底(1).png", 10)
			box.content_margin_left = 18
			box.content_margin_right = 18
			box.modulate_color = Color("ded1c1") if state in ["pressed", "hover_pressed"] else (Color("fff2df") if state == "hover" else Color.WHITE)
			result.set_stylebox(state, type, box)
		var focus := StyleBoxFlat.new()
		focus.bg_color = Color.TRANSPARENT
		focus.border_color = INK
		focus.set_border_width_all(2)
		result.set_stylebox("focus", type, focus)
	for type: String in ["Panel", "PanelContainer", "PopupPanel", "Window", "AcceptDialog"]:
		result.set_stylebox("panel", type, paper(UI + "窗口.png", 40))
	result.set_stylebox("background", "ProgressBar", paper(UI + "框底(1).png", 0))
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("a0ad85")
	result.set_stylebox("fill", "ProgressBar", fill)
	_themes[size] = result
	return result

static func skin_tree(node: Node, size: int = 22) -> void:
	if node is Control:
		node.theme = theme(size)
		for color: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			node.remove_theme_color_override(color)
		if node is Panel or node is PanelContainer:
			node.add_theme_stylebox_override("panel", paper(UI + "窗口.png", 40))
	for child: Node in node.get_children():
		skin_tree(child, size)

static func typography(control: Control, size: int, heading: bool = false) -> void:
	control.add_theme_font_override("font", HEADING_FONT if heading else FONT)
	control.add_theme_font_size_override("font_size", size)

static func bitmap(button: Button, normal: String, hover: String = "", dimensions: Vector2 = Vector2(270, 88)) -> void:
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var path: String = hover if not hover.is_empty() and state in ["hover", "pressed", "hover_pressed"] else normal
		var box := StyleBoxTexture.new()
		box.texture = load(path)
		if state == "disabled":
			box.modulate_color = Color(1, 1, 1, 0.35)
		button.add_theme_stylebox_override(state, box)
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		button.add_theme_color_override(state, Color.TRANSPARENT)
	button.custom_minimum_size = dimensions
	button.clip_text = true
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.tooltip_text = button.text
	button.set_meta("art_bitmap", true)

static func menu_button(button: Button, caption: String, failure: bool = false, dimensions: Vector2 = Vector2(270, 88)) -> void:
	var stem: String = "res://assets/ui/handdrawn/buttons/" + ("失败-" if failure else "") + caption
	bitmap(button, stem + ".png", stem + "-悬浮.png", dimensions)
