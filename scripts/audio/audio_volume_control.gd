extends HBoxContainer
## 主菜单、暂停菜单和剧情共用一个音量控件。

enum Channel { EFFECTS, MUSIC }
@export var channel: Channel = Channel.EFFECTS

var _audio: GameAudio
@onready var toggle: Button = $Toggle
@onready var slider: HSlider = $Volume
@onready var value_label: Label = $Value


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audio = GameAudio.find_for(self)
	if _audio == null:
		return
	if channel == Channel.MUSIC:
		_audio.music_volume_changed.connect(_show_volume)
		toggle.pressed.connect(_audio.toggle_music_mute)
	else:
		_audio.volume_changed.connect(_show_volume)
		toggle.pressed.connect(_audio.toggle_mute)
	slider.value_changed.connect(_on_value_changed)
	slider.tooltip_text = "音乐音量" if channel == Channel.MUSIC else "音效音量"
	_show_volume(_audio.music_volume if channel == Channel.MUSIC else _audio.effects_volume)


func _on_value_changed(value: float) -> void:
	if is_instance_valid(_audio):
		if channel == Channel.MUSIC:
			_audio.set_music_volume(value / 100.0)
		else:
			_audio.set_effects_volume(value / 100.0)


func _show_volume(value: float) -> void:
	slider.set_value_no_signal(value * 100.0)
	var label := "音乐" if channel == Channel.MUSIC else "音效"
	toggle.text = "静音" if value <= 0.0 else label
	toggle.tooltip_text = "点击恢复" + label if value <= 0.0 else "点击静音" + label
	value_label.text = "%d%%" % roundi(value * 100.0)
