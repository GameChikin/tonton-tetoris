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
@export var snap_particle_scene: PackedScene
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
	print("[Debug: EffectManager] play_line_blink 開始。渡されたブロック数: ", blocks.size())
	if blocks.is_empty():
		return
		
	var valid_color_rects: Array[ColorRect] = []
	for block in blocks:
		if is_instance_valid(block):
			var cr = block.get_node_or_null("ColorRect") as ColorRect
			if is_instance_valid(cr):
				valid_color_rects.append(cr)
				
	print("[Debug: EffectManager] 抽出されたColorRect数: ", valid_color_rects.size())
	if valid_color_rects.is_empty():
		return
		
	var tween := create_tween()
	# ポーズ中（連鎖インターバル中）でも確実にTweenを進行させる明示的な設定
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	
	var blink_duration := 0.08
	var blink_count := 3
	for i in range(blink_count):
		for cr in valid_color_rects:
			if is_instance_valid(cr):
				tween.parallel().tween_property(cr, "modulate:a", 0.2, blink_duration)
		tween.chain()
		for cr in valid_color_rects:
			if is_instance_valid(cr):
				tween.parallel().tween_property(cr, "modulate:a", 1.0, blink_duration)
		tween.chain()
		
	await tween.finished
	print("[Debug: EffectManager] play_line_blink Tween終了")

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


class ShockwaveNode extends Node2D:
	var current_radius: float = 0.0
	var max_radius: float = 0.0
	var fill_alpha: float = 0.3
	var wave_color: Color = Color.WHITE

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if max_radius <= 0:
			return

		var progress = clampf(current_radius / max_radius, 0.0, 1.0)

		# 塗りつぶし円
		var fill_c = wave_color
		fill_c.a = fill_alpha * (1.0 - progress)
		draw_circle(Vector2.ZERO, current_radius, fill_c)

		# 波紋（外枠線）
		var line_c = wave_color
		line_c.a = 1.0 - progress
		draw_arc(Vector2.ZERO, current_radius, 0, TAU, 32, line_c, 3.0)


func play_shockwave_effect(center: Vector2, max_radius: float) -> void:
	var settings: GameSettings = preload("res://game_settings.tres")
	var alpha: float = 0.3
	if settings != null and settings.get("shockwave_fill_alpha") != null:
		alpha = settings.shockwave_fill_alpha

	# 1. 波紋ノードの生成
	var wave := ShockwaveNode.new()
	wave.max_radius = max_radius
	wave.fill_alpha = alpha
	wave.global_position = center
	add_child(wave)

	# 2. はじけるパーティクルの生成
	var particles := CPUParticles2D.new()
	particles.emitting = false
	particles.one_shot = true
	particles.explosiveness = 0.95
	particles.lifetime = 0.6
	particles.direction = Vector2.ZERO
	particles.spread = 180.0
	particles.gravity = Vector2(0, 400)
	particles.initial_velocity_min = 150.0
	particles.initial_velocity_max = 300.0
	particles.scale_amount_min = 3.0
	particles.scale_amount_max = 6.0
	particles.color = Color(1.2, 1.2, 1.2, 1.0) # 少し発光させる
	particles.global_position = center
	add_child(particles)

	# アニメーションと発射の開始
	particles.emitting = true
	var tween := create_tween()
	tween.tween_property(wave, "current_radius", max_radius, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	# 演出終了後にノードを安全に破棄
	var timer_tween := create_tween()
	timer_tween.tween_interval(0.7)
	timer_tween.tween_callback(func():
		if is_instance_valid(wave):
			wave.queue_free()
		if is_instance_valid(particles):
			particles.queue_free()
	)


class ImplosionNode extends Node2D:
	var current_radius: float = 0.0
	var max_radius: float = 0.0
	var fill_alpha: float = 0.3
	var wave_color: Color = Color.WHITE

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if max_radius <= 0:
			return
		
		# current_radius が max_radius(開始) から 0(終了) へ縮む
		var progress = 1.0 - clampf(current_radius / max_radius, 0.0, 1.0)

		# 塗りつぶし円（中心に向かってエネルギーが凝縮されるように徐々に濃く）
		var fill_c = wave_color
		fill_c.a = fill_alpha * progress
		draw_circle(Vector2.ZERO, current_radius, fill_c)

		# 収縮するリング
		var line_c = wave_color
		line_c.a = 1.0 - progress * 0.4
		draw_arc(Vector2.ZERO, current_radius, 0, TAU, 32, line_c, 2.5)


func play_implosion_effect(center: Vector2, max_radius: float, duration: float) -> void:
	var settings: GameSettings = preload("res://game_settings.tres")
	var alpha: float = 0.25
	if settings != null and settings.get("shockwave_fill_alpha") != null:
		alpha = settings.shockwave_fill_alpha

	var wave := ImplosionNode.new()
	wave.max_radius = max_radius
	wave.current_radius = max_radius
	wave.fill_alpha = alpha
	wave.global_position = center
	add_child(wave)

	var tween := create_tween()
	# ポーズ中（連鎖インターバル中）でも確実にTweenを進行させる
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	
	# 半径を最大から0へ収縮させる（設定されたインターバル時間と同期）
	tween.tween_property(wave, "current_radius", 0.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	
	await tween.finished
	if is_instance_valid(wave):
		wave.queue_free()


# 吸着成功時に呼び出されるジューシーなパーティクルエフェクト
func play_snap_particles(pos: Vector2) -> void:
	# ハードコードを廃止し、インスペクターからアサインされたシーンを安全に評価する
	if snap_particle_scene == null:
		return
		
	var particles = snap_particle_scene.instantiate()
	if not is_instance_valid(particles):
		return
		
	particles.global_position = pos

	if particles.has_method("set_emitting"):
		particles.emitting = true

	add_child(particles)

	if particles.has_signal("finished"):
		await particles.finished
		if is_instance_valid(particles):
			particles.queue_free()
	else:
		await get_tree().create_timer(1.0, false).timeout
		if is_instance_valid(particles):
			particles.queue_free()
