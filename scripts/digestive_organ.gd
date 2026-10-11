class_name DigestiveOrgan
extends Node2D
## 每个腔室独立占有输入和输出预留；回流真正收件后才释放产物库存。

signal inventory_changed(queued: int, incoming: int)
signal digested(nutrition: int)
signal output_changed(snapshot: Dictionary)
signal product_created(product_id: String, nutrition: int)
signal selection_requested
signal digestion_changed(snapshot: Dictionary)
signal digestion_started(task_id: String, chamber_id: int, input_id: String, nutrition: int)
signal digestion_completed(task_id: String, chamber_id: int, product_id: String, nutrition: int)

const MAX_OUTPUT_PRODUCTS: int = 2
const MAX_OUTPUT_NUTRITION: int = 20
const EXPANSION_DURATION: float = 3.0

# 保留旧场景的引用；消化本身不依赖母核连接。
@export var mother_core: MotherCore
@export var core_edge: HyphaEdge
@export_range(1, 10, 1) var capacity: int = 4
@export var colony_capabilities: ColonyCapabilities

var incoming_remains: int = 0
var digested_count: int = 0
var total_nutrition_produced: int = 0
var enabled: bool = true

# 活动输入仍在 intake 中，直到预留和输入一起原子地换成产物。
var _queue: Array[Dictionary] = []
var _input_claims: Dictionary[String, String] = {}
var _tasks: Array[Dictionary] = [{}, {}]
var _products: Dictionary[String, Dictionary] = {}
var _product_order: Array[String] = []
var _product_claims: Dictionary[String, String] = {}
var _next_input_serial: int = 1
var _next_task_serial: int = 1
var _next_product_serial: int = 1
var _next_expansion_serial: int = 1
var _generation: int = 0
var _intake_generation: int = 0
var _expansion_state: StringName = &"locked"
var _expansion_id: String = ""
var _expansion_callback: Callable
var _observed_progress: ColonyProgress
var _stage_callback: Callable
var _capability_binding_serial: int = 0
var _notification_queue: Array[Dictionary] = []
var _is_notifying: bool = false
var _is_resetting: bool = false
var _is_exiting: bool = false
var _gain_tween: Tween

@onready var digest_timer: Timer = $DigestTimer
@onready var second_digest_timer: Timer = $SecondDigestTimer
@onready var chamber_expansion_timer: Timer = $ChamberExpansionTimer
@onready var progress_bar: ProgressBar = $ProgressBar
@onready var gain_feedback: Node2D = $GainFeedback
@onready var gain_label: Label = $GainFeedback/Label
@onready var queue_label: Label = $QueueLabel


func _enter_tree() -> void:
	_is_exiting = false
	_resume_current_generation.call_deferred(_generation)


func _ready() -> void:
	configure_capabilities(colony_capabilities)
	if not is_instance_valid(self):
		return
	_queue_state_notifications()
	_flush_notifications()


func _exit_tree() -> void:
	_is_exiting = true
	_generation += 1
	_notification_queue.clear()
	_release_all_tasks()
	_cancel_expansion_timer()
	if _expansion_state == &"expanding":
		_expansion_state = &"locked"
	_disconnect_capability_observation()
	_stop_gain_feedback()


## 仅供旧单腔室手动测试使用；真实 Timer 只绑定带任务身份的回调。
func _on_digest_timer_timeout() -> void:
	if _tasks[0].is_empty():
		return
	var task: Dictionary = _tasks[0]
	_on_chamber_timeout(0, int(task["generation"]), String(task["task_id"]))


func _on_chamber_timeout(chamber_id: int, generation: int, task_id: String) -> void:
	if not _owns_task(chamber_id, generation, task_id):
		return
	var task: Dictionary = _tasks[chamber_id]
	var input_id: String = task["input_id"]
	var input_index: int = _find_input_index(input_id)
	if input_index < 0 or _input_claims.get(input_id, "") != task_id:
		return

	var nutrition: int = task["nutrition"]
	var product_id: String = "%d:%d" % [get_instance_id(), _next_product_serial]
	_next_product_serial += 1
	_retire_task(chamber_id)
	_queue.remove_at(input_index)
	_products[product_id] = {
		"product_id": product_id, "nutrition": nutrition,
		"status": &"queued", "source_id": get_instance_id(),
		"task_id": task_id, "input_id": input_id, "chamber_id": chamber_id,
	}
	_product_order.append(product_id)
	digested_count += 1
	total_nutrition_produced += nutrition
	# 不使用跨腔室 completing 锁，另一个有效回调可以同步重入。
	_start_next_digestion()
	_publish_production(product_id, nutrition, generation)


func _on_chamber_expansion_timeout(generation: int, expansion_id: String) -> void:
	if not _is_current_generation(generation) or not enabled or (
		_expansion_state != &"expanding" or _expansion_id != expansion_id
	):
		return
	# 当前回调也不能提前解锁；计时遵循与主腔室相同的游戏物理时间。
	if chamber_expansion_timer.time_left > 0.0:
		return

	_cancel_expansion_timer()
	_expansion_state = &"ready"
	_start_next_digestion()
	_queue_state_notifications(false)
	_flush_notifications()


func _on_capability_stage_changed(
	_previous_stage: ColonyProgress.Stage, _current_stage: ColonyProgress.Stage,
	generation: int, binding_serial: int
) -> void:
	if not _is_current_generation(generation) or binding_serial != _capability_binding_serial:
		return
	_refresh_capability()
	_flush_notifications()


func _on_hit_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			selection_requested.emit()
			get_viewport().set_input_as_handled()


func configure_capabilities(value: ColonyCapabilities) -> void:
	colony_capabilities = value
	_bind_capability_observation()
	_refresh_capability()
	_flush_notifications()


func get_queued_count() -> int:
	return _queue.size()


func get_queued_nutrition() -> int:
	var total: int = 0
	for input: Dictionary in _queue:
		total += int(input["nutrition"])
	return total


func get_waiting_count() -> int:
	return _queue.size() - _input_claims.size()


func reserve_remains() -> bool:
	if not enabled or _is_resetting or _is_exiting or is_queued_for_deletion() or (
		_queue.size() + incoming_remains >= capacity
	):
		return false
	var intake_generation: int = _intake_generation
	incoming_remains += 1
	_queue_state_notifications(true, false)
	_flush_notifications()
	# 退出/停止保留已提交预留，由调用者复核生命周期后撤销；重置才使它失效。
	return is_instance_valid(self) and not is_queued_for_deletion() and (
		_intake_generation == intake_generation and incoming_remains > 0
	)


func complete_delivery(nutrition: int) -> bool:
	if not enabled or _is_resetting or _is_exiting or is_queued_for_deletion() or nutrition <= 0 or (
		incoming_remains <= 0 or _queue.size() >= capacity
	):
		return false
	incoming_remains -= 1
	var input_id: String = "%d:input:%d" % [get_instance_id(), _next_input_serial]
	_next_input_serial += 1
	_queue.append({"input_id": input_id, "nutrition": nutrition})
	_start_next_digestion()
	_queue_state_notifications()
	_flush_notifications()
	return true


func cancel_reservation() -> bool:
	if incoming_remains <= 0:
		return false
	incoming_remains -= 1
	if _is_exiting or is_queued_for_deletion():
		_queue_reservation_cleanup_notification()
	else:
		_queue_state_notifications(true, false)
	_flush_notifications()
	return true


## 只返回深副本，运输记录不能成为第二份可修改的产物库存。
func get_output_products() -> Array[Dictionary]:
	var products: Array[Dictionary] = []
	for product_id: String in _product_order:
		products.append(_products[product_id].duplicate(true))
	return products


func get_output_count() -> int:
	return _products.size()


func get_output_nutrition() -> int:
	var nutrition: int = 0
	for product: Dictionary in _products.values():
		nutrition += int(product["nutrition"])
	return nutrition


func get_output_snapshot() -> Dictionary:
	var in_transit: int = _product_claims.size()
	return {
		"count": get_output_count(), "nutrition": get_output_nutrition(),
		"reserved_count": _get_reserved_count(), "reserved_nutrition": _get_reserved_nutrition(),
		"queued_count": get_output_count() - in_transit,
		"in_transit_count": in_transit, "wait_reason": _get_wait_reason(),
	}


func get_digestion_snapshot() -> Dictionary:
	var expansion_remaining: float = _get_expansion_remaining()
	var expansion_progress: float = 0.0
	if _expansion_state == &"ready":
		expansion_progress = 1.0
	elif _expansion_state == &"expanding":
		expansion_progress = clampf(1.0 - expansion_remaining / EXPANSION_DURATION, 0.0, 1.0)
	var chambers: Array[Dictionary] = [_get_chamber_snapshot(0), _get_chamber_snapshot(1)]
	return {
		"generation": _generation, "enabled": enabled,
		"expansion_state": _expansion_state, "expansion_duration": EXPANSION_DURATION,
		"expansion_remaining": expansion_remaining, "expansion_progress": expansion_progress,
		"chamber_count": 2 if _expansion_state == &"ready" else 1,
		"active_count": _get_reserved_count(), "waiting_count": get_waiting_count(),
		"intake_count": get_queued_count(), "incoming_count": incoming_remains, "capacity": capacity,
		"chambers": chambers,
	}.duplicate(true)


func claim_output_product(product_id: String, claim_id: String) -> bool:
	if _is_resetting or _is_exiting or is_queued_for_deletion() or (
		claim_id.is_empty() or not _products.has(product_id)
	):
		return false
	if _product_claims.has(product_id) or _products[product_id]["status"] != &"queued":
		return false
	var generation: int = _generation
	_product_claims[product_id] = claim_id
	_products[product_id]["status"] = &"in_transit"
	_queue_state_notifications(false)
	_flush_notifications()
	return is_instance_valid(self) and _is_current_generation(generation) and owns_output_claim(product_id, claim_id)


func owns_output_claim(product_id: String, claim_id: String) -> bool:
	return not claim_id.is_empty() and _products.has(product_id) and (
		_product_claims.get(product_id, "") == claim_id
	)


## 中断只归还领取权，不释放输出空间、不改变编号或营养值。
func return_output_product(product_id: String, claim_id: String) -> bool:
	if not owns_output_claim(product_id, claim_id):
		return false
	_product_claims.erase(product_id)
	_products[product_id]["status"] = &"queued"
	_queue_state_notifications(false)
	_flush_notifications()
	return true


## 只由回流系统确认已收件后调用；空凭据用于清理已收件的排队产物。
func settle_output_product(product_id: String, claim_id: String = "") -> bool:
	if not _products.has(product_id):
		return false
	if claim_id.is_empty() and _product_claims.has(product_id):
		return false
	if not claim_id.is_empty() and not owns_output_claim(product_id, claim_id):
		return false
	_product_claims.erase(product_id)
	_products.erase(product_id)
	_product_order.erase(product_id)
	_start_next_digestion()
	_queue_state_notifications(false)
	_flush_notifications()
	return true


func reset() -> void:
	if _is_resetting:
		return
	_is_resetting = true
	_generation += 1
	_intake_generation += 1
	_notification_queue.clear()
	_release_all_tasks()
	_cancel_expansion_timer()
	_stop_gain_feedback()
	_queue.clear()
	_products.clear()
	_product_order.clear()
	_product_claims.clear()
	incoming_remains = 0
	digested_count = 0
	total_nutrition_produced = 0
	_expansion_state = &"locked"
	enabled = true
	_is_resetting = false
	# 换观察身份但不查询旧轮次成熟能力；配置或后续阶段事件再刷新。
	_bind_capability_observation()
	_queue_state_notifications()
	_flush_notifications()


func stop_processing() -> void:
	if not enabled:
		return
	_generation += 1
	_notification_queue.clear()
	enabled = false
	_release_all_tasks()
	_cancel_expansion_timer()
	_expansion_state = &"locked"
	_disconnect_capability_observation()
	_stop_gain_feedback()
	_queue_state_notifications()
	_flush_notifications()


func _resume_current_generation(generation: int) -> void:
	if not _is_current_generation(generation):
		return
	_resume_digestion()


func _resume_digestion() -> void:
	if not _can_process():
		return
	_bind_capability_observation()
	_refresh_capability()
	_start_next_digestion()
	_queue_state_notifications(false)
	_flush_notifications()


func _start_next_digestion() -> void:
	if not _can_process():
		return
	var chamber_count: int = 2 if _expansion_state == &"ready" else 1
	for chamber_id: int in range(chamber_count):
		if not _tasks[chamber_id].is_empty():
			continue
		var input: Dictionary = _get_waiting_input()
		if input.is_empty():
			break
		var nutrition: int = input["nutrition"]
		# FIFO：过大或暂时放不下的头部输入不能被后面的输入越过。
		if nutrition > MAX_OUTPUT_NUTRITION or (
			get_output_count() + _get_reserved_count() >= MAX_OUTPUT_PRODUCTS
			or get_output_nutrition() + _get_reserved_nutrition() + nutrition > MAX_OUTPUT_NUTRITION
		):
			break
		var task_id: String = "%d:task:%d" % [get_instance_id(), _next_task_serial]
		_next_task_serial += 1
		var duration: float = digest_timer.wait_time
		var input_id: String = input["input_id"]
		var callback: Callable = _on_chamber_timeout.bind(chamber_id, _generation, task_id)
		# 先同时提交输入领取权和精确输出预留，再启动该腔室计时器。
		_input_claims[input_id] = task_id
		_tasks[chamber_id] = {
			"task_id": task_id, "input_id": input_id, "chamber_id": chamber_id,
			"generation": _generation, "nutrition": nutrition, "duration": duration,
			"callback": callback,
		}
		var timer: Timer = _get_chamber_timer(chamber_id)
		timer.timeout.connect(callback)
		timer.start(duration)
		_queue_notification(&"digestion_started", {
			"task_id": task_id, "chamber_id": chamber_id,
			"input_id": input_id, "nutrition": nutrition,
		})


func _get_wait_reason() -> StringName:
	var chamber_count: int = 2 if _expansion_state == &"ready" else 1
	if _get_reserved_count() >= chamber_count:
		return &"empty"
	return _get_idle_wait_reason()


func _get_idle_wait_reason() -> StringName:
	var input: Dictionary = _get_waiting_input()
	if input.is_empty():
		return &"empty"
	var nutrition: int = input["nutrition"]
	if nutrition > MAX_OUTPUT_NUTRITION:
		return &"output_too_large"
	if get_output_count() + _get_reserved_count() >= MAX_OUTPUT_PRODUCTS or (
		get_output_nutrition() + _get_reserved_nutrition() + nutrition > MAX_OUTPUT_NUTRITION
	):
		return &"output_full"
	return &"empty"


func _get_waiting_input() -> Dictionary:
	for input: Dictionary in _queue:
		if not _input_claims.has(String(input["input_id"])):
			return input
	return {}


func _find_input_index(input_id: String) -> int:
	for index: int in range(_queue.size()):
		if _queue[index]["input_id"] == input_id:
			return index
	return -1


func _get_reserved_count() -> int:
	var count: int = 0
	for task: Dictionary in _tasks:
		if not task.is_empty():
			count += 1
	return count


func _get_reserved_nutrition() -> int:
	var nutrition: int = 0
	for task: Dictionary in _tasks:
		if not task.is_empty():
			nutrition += int(task["nutrition"])
	return nutrition


func _get_chamber_timer(chamber_id: int) -> Timer:
	return digest_timer if chamber_id == 0 else second_digest_timer


func _get_chamber_snapshot(chamber_id: int) -> Dictionary:
	var unlocked: bool = chamber_id == 0 or _expansion_state == &"ready"
	var task: Dictionary = _tasks[chamber_id]
	var state: StringName = &"idle"
	var duration: float = 0.0
	var remaining: float = 0.0
	var progress: float = 0.0
	if not enabled or _is_exiting:
		state = &"stopped"
	elif not unlocked:
		state = _expansion_state
	elif not task.is_empty():
		state = &"processing"
		duration = float(task["duration"])
		var timer: Timer = _get_chamber_timer(chamber_id)
		if is_instance_valid(timer):
			remaining = clampf(timer.time_left, 0.0, duration)
		progress = clampf(1.0 - remaining / maxf(duration, 0.001), 0.0, 1.0)
	else:
		var wait_reason: StringName = _get_idle_wait_reason()
		if wait_reason != &"empty":
			state = wait_reason
	return {
		"chamber_id": chamber_id, "unlocked": unlocked, "state": state,
		"task_id": String(task.get("task_id", "")), "input_id": String(task.get("input_id", "")),
		"nutrition": int(task.get("nutrition", 0)), "duration": duration,
		"remaining": remaining, "progress": progress,
		"reserved_nutrition": int(task.get("nutrition", 0)),
	}


func _owns_task(chamber_id: int, generation: int, task_id: String) -> bool:
	if chamber_id < 0 or chamber_id >= _tasks.size() or not _can_process() or (
		not _is_current_generation(generation) or task_id.is_empty()
	):
		return false
	var task: Dictionary = _tasks[chamber_id]
	return not task.is_empty() and task["generation"] == generation and task["task_id"] == task_id


func _retire_task(chamber_id: int) -> void:
	var task: Dictionary = _tasks[chamber_id]
	var timer: Timer = _get_chamber_timer(chamber_id)
	if is_instance_valid(timer):
		timer.stop()
		if not task.is_empty():
			var callback: Callable = task["callback"]
			if timer.timeout.is_connected(callback):
				timer.timeout.disconnect(callback)
	if not task.is_empty():
		var input_id: String = task["input_id"]
		if _input_claims.get(input_id, "") == task["task_id"]:
			_input_claims.erase(input_id)
	_tasks[chamber_id] = {}


func _release_all_tasks() -> void:
	_retire_task(0)
	_retire_task(1)
	_input_claims.clear()


func _bind_capability_observation() -> void:
	_disconnect_capability_observation()
	if _is_exiting or not enabled or not is_instance_valid(colony_capabilities) or (
		colony_capabilities.is_queued_for_deletion()
	):
		return
	var progress: ColonyProgress = colony_capabilities.colony_progress
	if not is_instance_valid(progress) or progress.is_queued_for_deletion():
		return
	_observed_progress = progress
	_stage_callback = _on_capability_stage_changed.bind(_generation, _capability_binding_serial)
	progress.stage_changed.connect(_stage_callback)


func _disconnect_capability_observation() -> void:
	_capability_binding_serial += 1
	if is_instance_valid(_observed_progress) and _stage_callback.is_valid() and (
		_observed_progress.stage_changed.is_connected(_stage_callback)
	):
		_observed_progress.stage_changed.disconnect(_stage_callback)
	_observed_progress = null
	_stage_callback = Callable()


func _refresh_capability() -> void:
	if not _can_process():
		return
	var can_expand: bool = is_instance_valid(colony_capabilities) and (
		not colony_capabilities.is_queued_for_deletion()
		and colony_capabilities.can_expand_second_digestive_chamber()
	)
	if can_expand:
		if _expansion_state == &"locked":
			_begin_expansion()
	elif _expansion_state != &"locked":
		_cancel_expansion_timer()
		_retire_task(1)
		_expansion_state = &"locked"
		_start_next_digestion()
		_queue_state_notifications(false)


func _begin_expansion() -> void:
	_expansion_state = &"expanding"
	_expansion_id = "%d:expansion:%d" % [get_instance_id(), _next_expansion_serial]
	_next_expansion_serial += 1
	_expansion_callback = _on_chamber_expansion_timeout.bind(_generation, _expansion_id)
	chamber_expansion_timer.timeout.connect(_expansion_callback)
	chamber_expansion_timer.start(EXPANSION_DURATION)
	_queue_state_notifications(false, false)


func _cancel_expansion_timer() -> void:
	if is_instance_valid(chamber_expansion_timer):
		chamber_expansion_timer.stop()
		if _expansion_callback.is_valid() and chamber_expansion_timer.timeout.is_connected(_expansion_callback):
			chamber_expansion_timer.timeout.disconnect(_expansion_callback)
	_expansion_callback = Callable()
	_expansion_id = ""


func _get_expansion_remaining() -> float:
	if _expansion_state != &"expanding":
		return 0.0
	var remaining: float = 0.0
	if is_instance_valid(chamber_expansion_timer):
		remaining = chamber_expansion_timer.time_left
	return clampf(remaining, 0.0, EXPANSION_DURATION)


func _can_process() -> bool:
	return enabled and not _is_resetting and not _is_exiting and not is_queued_for_deletion() and (
		is_inside_tree() and is_instance_valid(digest_timer) and is_instance_valid(second_digest_timer)
		and is_instance_valid(chamber_expansion_timer)
	)


func _publish_production(product_id: String, nutrition: int, generation: int) -> void:
	if not _is_current_generation(generation) or not _products.has(product_id):
		return
	var product: Dictionary = _products[product_id]
	_queue_state_notifications()
	_queue_notification(&"product_created", {"product_id": product_id, "nutrition": nutrition})
	_queue_notification(&"digested", {"nutrition": nutrition})
	_queue_notification(&"digestion_completed", {
		"task_id": product["task_id"], "chamber_id": product["chamber_id"],
		"product_id": product_id, "nutrition": nutrition,
	})
	_queue_notification(&"gain_feedback", {"nutrition": nutrition})
	_flush_notifications()


func _queue_state_notifications(with_inventory: bool = true, with_output: bool = true) -> void:
	if with_inventory:
		_queue_notification(&"inventory_changed")
	if with_output:
		_queue_notification(&"output_changed")
	_queue_notification(&"digestion_changed")


func _queue_notification(signal_name: StringName, payload: Dictionary = {}) -> void:
	if not _is_current_generation(_generation):
		return
	var notification: Dictionary = payload.duplicate(true)
	notification["generation"] = _generation
	notification["signal"] = signal_name
	_notification_queue.append(notification)


## 撤销真实已提交预留时，即使接收器正在删除，也必须交付库存清理结果。
## 此入口仅发布库存，不允许生产、任务或扩建事件绕过生命周期校验。
func _queue_reservation_cleanup_notification() -> void:
	_notification_queue.append({
		"generation": _generation, "signal": &"reservation_cleanup",
	})


func _flush_notifications() -> void:
	if _is_notifying:
		return
	_is_notifying = true
	while not _notification_queue.is_empty():
		var notification: Dictionary = _notification_queue.pop_front()
		var generation: int = int(notification["generation"])
		if notification["signal"] == &"reservation_cleanup":
			if is_instance_valid(self) and _generation == generation:
				_emit_inventory_changed()
		elif _is_current_generation(generation):
			match notification["signal"]:
				&"inventory_changed":
					_emit_inventory_changed()
				&"output_changed":
					_emit_output_changed()
				&"digestion_changed":
					digestion_changed.emit(get_digestion_snapshot())
				&"digestion_started":
					if _owns_task(int(notification["chamber_id"]), int(notification["generation"]), String(notification["task_id"])):
						digestion_started.emit(notification["task_id"], notification["chamber_id"], notification["input_id"], notification["nutrition"])
				&"product_created":
					product_created.emit(notification["product_id"], notification["nutrition"])
				&"digested":
					digested.emit(notification["nutrition"])
				&"digestion_completed":
					digestion_completed.emit(notification["task_id"], notification["chamber_id"], notification["product_id"], notification["nutrition"])
				&"gain_feedback":
					_play_gain_feedback(int(notification["nutrition"]))
		if not is_instance_valid(self):
			return
	_is_notifying = false


func _is_current_generation(generation: int) -> bool:
	return is_instance_valid(self) and _generation == generation and not _is_exiting and not is_queued_for_deletion()


func _emit_inventory_changed() -> void:
	if is_instance_valid(queue_label):
		queue_label.text = "%d (+%d)/%d" % [get_queued_count(), incoming_remains, capacity]
	inventory_changed.emit(get_queued_count(), incoming_remains)


func _emit_output_changed() -> void:
	output_changed.emit(get_output_snapshot())


func _stop_gain_feedback() -> void:
	if _gain_tween != null and _gain_tween.is_valid():
		_gain_tween.kill()
	if is_instance_valid(gain_feedback):
		gain_feedback.hide()


func _play_gain_feedback(nutrition: int) -> void:
	if not is_inside_tree() or not is_instance_valid(gain_feedback) or not is_instance_valid(gain_label):
		return
	if _gain_tween != null and _gain_tween.is_valid():
		_gain_tween.kill()
	gain_label.text = "产出 %d 营养" % nutrition
	gain_feedback.position = Vector2(0, -66)
	gain_feedback.modulate.a = 1.0
	gain_feedback.show()
	_gain_tween = create_tween().set_parallel(true)
	_gain_tween.tween_property(gain_feedback, "position:y", -88.0, 0.8)
	_gain_tween.tween_property(gain_feedback, "modulate:a", 0.0, 0.8)
	_gain_tween.chain().tween_callback(gain_feedback.hide)
