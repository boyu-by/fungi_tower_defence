class_name CampaignProgressStore
extends RefCounted
## 只保存关卡进度，不序列化局内资源、组织、波次或运输任务。

const VERSION: int = 1
var save_path: String
var last_error: String = ""
var _state: Dictionary = _empty_state()


func _init(path: String = "user://campaign_progress.cfg") -> void:
	save_path = path


static func _empty_state() -> Dictionary:
	return {"has_save": false, "highest_unlocked": 1, "continue_level": 1, "completed": false}


func load_progress() -> bool:
	_state = _empty_state()
	last_error = ""
	if not FileAccess.file_exists(save_path):
		return false
	var config := ConfigFile.new()
	if config.load(save_path) != OK:
		last_error = "进度记录无法读取，可以开始新游戏。"
		return false
	var version: Variant = config.get_value("campaign", "version", null)
	var highest: Variant = config.get_value("campaign", "highest_unlocked", null)
	var checkpoint: Variant = config.get_value("campaign", "continue_level", null)
	var completed: Variant = config.get_value("campaign", "completed", null)
	if not version is int or version != VERSION or not highest is int or not checkpoint is int \
			or not completed is bool or highest < 1 or highest > 3 or checkpoint < 1 or checkpoint > highest \
			or (completed and highest != 3):
		last_error = "进度记录无效，可以开始新游戏。"
		return false
	_state = {"has_save": true, "highest_unlocked": highest, "continue_level": checkpoint, "completed": completed}
	return true


func get_snapshot() -> Dictionary:
	return _state.duplicate(true)


func start_new_game() -> bool:
	return _save({"has_save": true, "highest_unlocked": 1, "continue_level": 1, "completed": false})


func record_entry(level_index: int) -> bool:
	if not bool(_state.has_save) or level_index < 1 or level_index > int(_state.highest_unlocked):
		return false
	var next: Dictionary = _state.duplicate(true)
	# 重开已通过的旧关不会把“继续游戏”退回去；标题始终进入最近解锁关卡。
	next.continue_level = int(next.highest_unlocked)
	return true if next == _state else _save(next)


func record_victory(level_index: int) -> bool:
	if not bool(_state.has_save) or level_index < 1 or level_index > int(_state.highest_unlocked):
		return false
	var next: Dictionary = _state.duplicate(true)
	next.highest_unlocked = maxi(int(next.highest_unlocked), mini(3, level_index + 1))
	next.continue_level = int(next.highest_unlocked)
	next.completed = bool(next.completed) or level_index == 3
	return true if next == _state else _save(next)


func _save(next: Dictionary) -> bool:
	var config := ConfigFile.new()
	config.set_value("campaign", "version", VERSION)
	for key: String in ["highest_unlocked", "continue_level", "completed"]:
		config.set_value("campaign", key, next[key])
	var temporary: String = save_path + ".tmp"
	var error: Error = config.save(temporary)
	if error == OK:
		error = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(save_path))
	if error != OK:
		last_error = "无法保存关卡进度，请检查存储空间和文件权限。"
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return false
	_state = next.duplicate(true)
	last_error = ""
	return true
