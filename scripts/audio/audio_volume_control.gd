extends HBoxContainer
## 主菜单、暂停菜单和剧情共用一个音量控件。

var _audio: GameAudio
@onready var toggle: Button = $Toggle
@onready var slider: HSlider = $Volume
@onready var value_label: Label = $Value


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audio = GameAudio.find_for(self)
	if _audio == null:
		return
	_audio.volume_changed.connect(_show_volume)
	toggle.pressed.connect(_audio.toggle_mute)
	slider.value_changed.connect(_on_value_changed)
	_show_volume(_audio.effects_volume)


func _on_value_changed(value: float) -> void:
	if is_instance_valid(_audio):
		_audio.set_effects_volume(value / 100.0)


func _show_volume(value: float) -> void:
	slider.set_value_no_signal(value * 100.0)
	toggle.text = "静音" if value <= 0.0 else "音效"
	toggle.tooltip_text = "点击恢复音效" if value <= 0.0 else "点击静音"
	value_label.text = "%d%%" % roundi(value * 100.0)
