class_name ExplorationProductionProfile
extends AIProductionProfile
## 第三关独立配比；复用五类敌人资源和批次身份，不修改第二关配置。

@export var source_stagger_seconds: float = 6.0
@export var collection_grace_seconds: float = 15.0


func is_valid() -> bool:
	return super.is_valid() and is_finite(source_stagger_seconds) and source_stagger_seconds >= 0 \
		and is_finite(collection_grace_seconds) and collection_grace_seconds >= 0


func get_stage(elapsed: float, collected: int) -> int:
	if elapsed >= full_after_seconds or collected >= 2:
		return 2
	return 1 if elapsed >= advanced_after_seconds or collected >= 1 else 0


func get_exploration_scenes(elapsed: float, cycle: int, source_index: int, collected: int) -> Array[PackedScene]:
	var result: Array[PackedScene] = []
	for _index: int in range(normal_count):
		result.append(normal_scene)
	var stage: int = get_stage(elapsed, collected)
	if stage >= 1 and source_index == 1:
		for _index: int in range(swarm_size):
			result.append(swarm_scene)
		result.append(silk_scene)
	if stage >= 2 and source_index == 2:
		result.append(armored_scene)
		result.append(junction_scene)
	# 左上区域保持较轻压力；后期交替补充一种专职啃食者。
	if stage >= 2 and source_index == 0 and cycle % 2 == 1:
		result.append(silk_scene)
	return result
