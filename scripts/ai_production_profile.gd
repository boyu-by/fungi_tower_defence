class_name AIProductionProfile
extends Resource
## 有限压力上限的持续生产配置；各设施在相同阶段保持独立周期。

@export var preparation_seconds: float = 30.0
@export var cycle_seconds: float = 35.0
@export var warning_seconds: float = 5.0
@export var destruction_grace_seconds: float = 20.0
@export var advanced_after_seconds: float = 70.0
@export var full_after_seconds: float = 210.0
@export var max_alive_per_source: int = 18
@export var normal_count: int = 1
@export var swarm_size: int = 2
@export var member_interval: float = 1.2
@export var normal_scene: PackedScene = preload("res://scenes/enemies/basic_enemy.tscn")
@export var swarm_scene: PackedScene = preload("res://scenes/enemies/swarm_enemy.tscn")
@export var armored_scene: PackedScene = preload("res://scenes/enemies/armored_enemy.tscn")
@export var silk_scene: PackedScene = preload("res://scenes/enemies/silk_gnawer_enemy.tscn")
@export var junction_scene: PackedScene = preload("res://scenes/enemies/junction_gnawer_enemy.tscn")


func is_valid() -> bool:
	for value: float in [preparation_seconds, warning_seconds, destruction_grace_seconds,
			advanced_after_seconds, full_after_seconds]:
		if not is_finite(value) or value < 0:
			return false
	if not is_finite(cycle_seconds) or cycle_seconds <= 0 or not is_finite(member_interval) or member_interval <= 0 \
			or normal_count < 1 or swarm_size < 1 or max_alive_per_source < 1 \
			or full_after_seconds < advanced_after_seconds:
		return false
	for scene: PackedScene in [normal_scene, swarm_scene, armored_scene, silk_scene, junction_scene]:
		if scene == null or not scene.can_instantiate():
			return false
	return true


func get_scenes_for_cycle(elapsed: float, cycle: int, source_index: int) -> Array[PackedScene]:
	var scenes: Array[PackedScene] = []
	for _index: int in range(maxi(1, normal_count)):
		scenes.append(normal_scene)
	if elapsed >= advanced_after_seconds:
		for _index: int in range(maxi(1, swarm_size)):
			scenes.append(swarm_scene)
	if elapsed >= full_after_seconds:
		scenes.append(armored_scene)
		scenes.append(silk_scene if (cycle + source_index) % 2 == 0 else junction_scene)
	return scenes
