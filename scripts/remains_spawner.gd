class_name RemainsSpawner
extends Node
## 监听敌人的死亡通知，把独立尸体场景放在死亡落点。

@export var enemy_container: Node2D
@export var remains_container: Node2D
@export var remains_scene: PackedScene


func _ready() -> void:
	if not is_instance_valid(enemy_container):
		return
	enemy_container.child_entered_tree.connect(_on_enemy_added)
	for child in enemy_container.get_children():
		_on_enemy_added(child)


func _on_enemy_added(child: Node) -> void:
	if child is BasicEnemy and not child.died.is_connected(_on_enemy_died):
		child.died.connect(_on_enemy_died)


func _on_enemy_died(enemy: BasicEnemy) -> void:
	if not enemy.creates_remains() or not is_instance_valid(remains_container) or remains_scene == null:
		return
	var instance := remains_scene.instantiate()
	if not instance is EnemyRemains:
		instance.free()
		return
	var remains := instance as EnemyRemains
	remains.nutrition_value = enemy.remains_nutrition
	remains_container.add_child(remains)
	remains.global_position = enemy.global_position
