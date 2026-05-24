extends Node
class_name EffectManager

signal shake_finished

@export var camera_path: NodePath = NodePath("../Camera2D")
@export var shake_intensity: float = 12.0
@export var shake_duration: float = 0.14
@export_range(1, 20, 1) var shake_count: int = 2

var camera: Camera2D
var _base_offset: Vector2 = Vector2.ZERO
var _line_clear_queue: Array[Node] = []
@export var flash_rect_path: NodePath
var _flash_rect: ColorRect


func _ready() -> void:
	camera = get_node_or_null(camera_path) as Camera2D
	if camera == null:
		camera = get_parent().get_node_or_null("Camera2D") as Camera2D
	if camera != null:
		_base_offset = camera.offset
	_flash_rect = get_node_or_null(flash_rect_path) as ColorRect
	if _flash_rect != null:
		_flash_rect.modulate.a = 0.0


func shake_camera() -> void:
	if camera == null or not is_instance_valid(camera):
		shake_finished.emit()
		return

	_base_offset = camera.offset
	var amplitude: float = absf(shake_intensity)
	var resolved_count: int = maxi(1, shake_count)
	var segment_count: int = resolved_count * 2 + 1
	var segment_duration: float = maxf(0.01, shake_duration / float(segment_count))

	var tween: Tween = create_tween()
	for _i in range(resolved_count):
		var up_offset: Vector2 = _base_offset + Vector2(0.0, -amplitude)
		var down_offset: Vector2 = _base_offset + Vector2(0.0, amplitude)
		# Keep the motion deterministic: always start by moving up, then down.
		tween.tween_property(camera, "offset", up_offset, segment_duration)
		tween.tween_property(camera, "offset", down_offset, segment_duration)
	tween.tween_property(camera, "offset", _base_offset, segment_duration)

	await tween.finished
	if is_instance_valid(camera):
		camera.offset = _base_offset
	shake_finished.emit()


func enqueue_line_clear(block_node: Node) -> void:
	if block_node == null:
		return
	if not is_instance_valid(block_node):
		return
	_line_clear_queue.append(block_node)


func flush_line_clear_queue() -> void:
	while not _line_clear_queue.is_empty():
		var block_node: Node = _line_clear_queue.pop_front()
		if not is_instance_valid(block_node):
			continue
		await play_line_clear_effect(block_node)


func play_line_clear_effect(block_node: Node) -> void:
	# Board passes disposable effect-only dummy nodes.
	if not is_instance_valid(block_node):
		return

	if not (block_node is CanvasItem):
		if is_instance_valid(block_node):
			block_node.queue_free()
		return

	if not is_instance_valid(block_node):
		return

	var tween: Tween = create_tween()
	tween.tween_property(block_node, "modulate:a", 0.0, 0.08)
	await tween.finished

	if not is_instance_valid(block_node):
		return

	block_node.queue_free()


func play_line_blink(blocks: Array[Node]) -> void:
	if blocks.is_empty():
		return
	var tween := create_tween()
	var blink_duration := 0.08
	var blink_count := 3
	for i in range(blink_count):
		for block in blocks:
			if is_instance_valid(block) and block is CanvasItem:
				tween.parallel().tween_property(block, "modulate:a", 0.2, blink_duration)
		tween.chain()
		for block in blocks:
			if is_instance_valid(block) and block is CanvasItem:
				tween.parallel().tween_property(block, "modulate:a", 1.0, blink_duration)
		tween.chain()
	await tween.finished

func play_line_vanish_and_flash(blocks: Array[Node]) -> void:
	if blocks.is_empty():
		return
		
	if _flash_rect != null and is_instance_valid(_flash_rect):
		var flash_tween := create_tween()
		_flash_rect.modulate.a = 0.8
		flash_tween.tween_property(_flash_rect, "modulate:a", 0.0, 0.3)
		
	blocks.sort_custom(func(a, b): 
		if not is_instance_valid(a) or not is_instance_valid(b): return false
		var ax = a.position.x if "position" in a else 0
		var bx = b.position.x if "position" in b else 0
		return ax < bx
	)
	
	var tween := create_tween()
	var fade_time := 0.1
	var delay_step := 0.02
	var current_delay := 0.0
	
	for block in blocks:
		if is_instance_valid(block) and block is CanvasItem:
			tween.parallel().tween_property(block, "modulate:a", 0.0, fade_time).set_delay(current_delay)
			current_delay += delay_step
			
	await tween.finished
