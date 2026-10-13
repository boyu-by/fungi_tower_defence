class_name ColonyCapabilities
extends Node

## 实时读取群落阶段，提供只读能力查询。

@export var colony_progress: ColonyProgress


func get_external_target_limit() -> int:
	return 3


func get_extension_tip_limit() -> int:
	var stage: ColonyProgress.Stage = _get_stage()
	match stage:
		ColonyProgress.Stage.EXPANDED, ColonyProgress.Stage.MATURE:
			return 2
		_:
			return 1


func can_expand_second_digestive_chamber() -> bool:
	return _get_stage() == ColonyProgress.Stage.MATURE


func can_differentiate_attack_organs() -> bool:
	return _get_stage() == ColonyProgress.Stage.MATURE


func _get_stage() -> ColonyProgress.Stage:
	if not is_instance_valid(colony_progress) or colony_progress.is_queued_for_deletion():
		return ColonyProgress.Stage.NASCENT
	return colony_progress.get_stage()
