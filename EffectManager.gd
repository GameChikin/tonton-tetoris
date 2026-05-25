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
	# 時間停止（ポーズ）中もこのノードの処理（演出）を続行するための設定
	process_mode = Node.PROCESS_MODE_ALWAYS

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

	# 1. 時間停止（物理演算・ゲーム進行を一時ストップ）
	get_tree().paused = true

	var valid_color_rects: Array[ColorRect] = []
	for block in blocks:
		if is_instance_valid(block):
			var cr = block.get_node_or_null("ColorRect") as ColorRect
			if is_instance_valid(cr):
				valid_color_rects.append(cr)

	if valid_color_rects.is_empty():
		get_tree().paused = false
		return

	# 2. 画面全体のフラッシュ演出（FlashLayer）
	if is_instance_valid(_flash_rect):
		_flash_rect.modulate.a = 0.6
		var flash_tween = create_tween()
		flash_tween.tween_property(_flash_rect, "modulate:a", 0.0, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# 3. ラインの点滅演出（チカチカさせる）
	var blink_tween = create_tween()
	var blink_duration = 0.06
	var blink_count = 4

	for i in range(blink_count):
		# 透明にする
		blink_tween.tween_callback(func(): _set_blocks_alpha(valid_color_rects, 0.0))
		blink_tween.tween_interval(blink_duration)
		# 元に戻す
		blink_tween.tween_callback(func(): _set_blocks_alpha(valid_color_rects, 1.0))
		blink_tween.tween_interval(blink_duration)

	await blink_tween.finished

	# 4. 消失演出（縮小しながらフェードアウト）
	var vanish_tween = create_tween().set_parallel(true)
	for cr in valid_color_rects:
		if is_instance_valid(cr):
			vanish_tween.tween_property(cr, "scale", Vector2.ZERO, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
			vanish_tween.tween_property(cr, "modulate:a", 0.0, 0.2)

	await vanish_tween.finished

	# 5. 演出完了後、時間停止を解除
	get_tree().paused = false


# 点滅演出用のアルファ値一括変更ヘルパー
func _set_blocks_alpha(rects: Array[ColorRect], alpha: float) -> void:
	for cr in rects:
		if is_instance_valid(cr):
			cr.modulate.a = alpha
