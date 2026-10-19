extends Node
## 三关共用的声音观察器：只订阅已发生的事实，不控制战斗、建设或资源。

@onready var audio: GameAudio = get_parent()
@onready var scope: Node = get_parent().get_parent()

var _core_health: int = 0
var _growth_tasks: Dictionary[int, int] = {}
var _stopping: bool = false
var _result_played: bool = false


func _ready() -> void:
	if not scope.has_node("World/Colony/MotherCore"):
		return
	audio.play_music(&"battle")
	for node in scope.find_children("*", "", true, false):
		_bind_node(node)
	if scope.has_signal("level_finished"):
		scope.connect("level_finished", _on_level_finished)
	if scope.has_signal("level_stopping"):
		scope.connect("level_stopping", _on_level_stopping)
	get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if not _stopping and scope.is_ancestor_of(node):
		_bind_node(node)


func _bind_node(node: Node) -> void:
	if node is SporeWeapon:
		node.volley_committed.connect(_on_volley.bind(weakref(node)))
	elif node is SporeProjectile:
		node.hit.connect(_on_hit)
	elif node is BasicEnemy:
		node.died.connect(_on_enemy_died)
	elif node is MotherCore:
		_core_health = node.health
		node.health_changed.connect(_on_core_health_changed)
		node.digestion_product_arrived.connect(_on_income)
	elif node is GrowthSystem:
		node.task_changed.connect(_on_growth_task.bind(node.get_instance_id()))
		node.junction_formed.connect(_on_junction_formed)
		node.task_completed.connect(_on_growth_completed)
	elif node is CultivationSystem:
		node.organ_matured.connect(_on_organ_matured)
		node.digestive_matured.connect(_on_digestive_matured)
	elif node is DifferentiationSystem:
		node.organ_differentiated.connect(_on_differentiated)
	elif node is ColonyProgress:
		node.stage_changed.connect(_on_stage_changed)
	elif node is FragmentCollectionController:
		node.fragment_collected.connect(_on_fragment_collected)


func _play(id: StringName) -> void:
	if not _stopping:
		audio.play(id)


func _on_volley(_id: String, _spent: int, _count: int, reference: WeakRef) -> void:
	var weapon := reference.get_ref() as SporeWeapon
	if not is_instance_valid(weapon):
		return
	var profile := weapon.get_weapon_profile()
	if profile == null:
		return
	match profile.damage_type:
		WeaponProfile.DamageType.ARMOR_PIERCING: _play(&"shoot_heavy")
		WeaponProfile.DamageType.SCATTER: _play(&"shoot_scatter")
		_: _play(&"shoot")


func _on_hit(_enemy: BasicEnemy, _actual_damage: int) -> void:
	_play(&"hit")


func _on_enemy_died(_enemy: BasicEnemy) -> void:
	_play(&"death")


func _on_core_health_changed(current: int, _maximum: int) -> void:
	if current < _core_health and current > 0:
		_play(&"core_hit")
	_core_health = current


func _on_income(_id: String, _amount: int) -> void:
	_play(&"income")


func _on_growth_task(snapshot: Dictionary, source_id: int) -> void:
	var id := int(snapshot.get("task_id", 0))
	if id > 0 and _growth_tasks.get(source_id, 0) != id:
		_growth_tasks[source_id] = id
		_play(&"place")


func _on_junction_formed(_node: HyphaNode) -> void:
	_play(&"grow")


func _on_growth_completed(_id: int) -> void:
	_play(&"built")


func _on_organ_matured(_id: int, _host: HyphaNode, _organ: AttackOrgan, _weapon: SporeWeapon) -> void:
	_play(&"built")


func _on_digestive_matured(_id: int, _host: HyphaNode, _organ: DigestiveOrgan) -> void:
	_play(&"built")


func _on_differentiated(_id: int, _organ: AttackOrgan, _direction: int) -> void:
	_play(&"evolve")


func _on_stage_changed(_previous: ColonyProgress.Stage, _current: ColonyProgress.Stage) -> void:
	_play(&"stage")


func _on_fragment_collected(_id: StringName, _text: String) -> void:
	_play(&"fragment")


func _on_level_stopping(reason: StringName) -> void:
	_stopping = true
	audio.stop_music()
	if reason in [&"victory", &"core_depleted"]:
		audio.stop_world()
	else:
		audio.stop_all()


func _on_level_finished(snapshot: Dictionary) -> void:
	if _result_played:
		return
	_result_played = true
	_stopping = true
	audio.stop_music()
	audio.stop_world()
	audio.play(&"victory" if bool(snapshot.get("victory", false)) else &"defeat")
