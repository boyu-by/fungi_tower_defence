extends Node
## 仅监听本场景的按钮，不响应悬停、聚焦或程序刷新。

@onready var audio: GameAudio = get_parent()
@onready var scope: Node = get_parent().get_parent()

var _scopes: Array[WeakRef] = []


func _ready() -> void:
	observe_scope(scope)
	get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if not node is BaseButton:
		return
	for reference in _scopes:
		var observed := reference.get_ref() as Node
		if is_instance_valid(observed) and observed.is_ancestor_of(node):
			_bind_button(node)
			return


func observe_scope(observed: Node) -> void:
	if not is_instance_valid(observed):
		return
	for reference in _scopes:
		if reference.get_ref() == observed:
			return
	_scopes.append(weakref(observed))
	for node in observed.find_children("*", "BaseButton", true, false):
		_bind_button(node)


func _bind_button(button: BaseButton) -> void:
	var callback := _on_button_pressed.bind(button)
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _on_button_pressed(button: BaseButton) -> void:
	if button.disabled or not button.is_visible_in_tree():
		return
	audio.play(&"ui_click")
