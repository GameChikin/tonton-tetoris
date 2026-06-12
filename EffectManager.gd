extends Node
class_name EffectManager

signal shake_finished
# 演出時の物理スローモーション（泥沼状態）を要求するシグナル
signal slow_motion_requested(is_slow: bool)

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
	if blocks.is_empty():
		return
		
	var valid_color_rects: Array[ColorRect] = []
	for block in blocks:
		if is_instance_valid(block):
			var cr = block.get_node_or_null("ColorRect") as ColorRect
			if is_instance_valid(cr):
				valid_color_rects.append(cr)

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

func play_line_vanish_and_flash(blocks: Array[Node]) -> void:
	if blocks.is_empty():
		return

	# 1. 時間停止（物理演算・ゲーム進行を一時ストップ）
	slow_motion_requested.emit(true)

	var valid_color_rects: Array[ColorRect] = []
	for block in blocks:
		if is_instance_valid(block):
			var cr = block.get_node_or_null("ColorRect") as ColorRect
			if is_instance_valid(cr):
				valid_color_rects.append(cr)

	if valid_color_rects.is_empty():
		slow_motion_requested.emit(false)
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

	# 【修正】待機はTweenの寿命ではなくタイマーで行う。
	# 点滅対象(cr)が演出中にドッキング等で解放されてもTweenがkillされてハングしないようにする。
	# blink_tween自体はアルファ変更の見た目を駆動するだけ（_set_blocks_alphaが生存チェック済み）。
	var blink_total: float = blink_duration * 2.0 * float(blink_count)
	await get_tree().create_timer(blink_total).timeout

	# 4. 消失演出（縮小しながらフェードアウト）
	# 【修正】有効なColorRectが1つも無ければTweenを作らない（空Tween=「started with no Tweeners」エラーの根絶）。
	var vanish_duration: float = 0.2
	var has_valid_cr: bool = false
	for cr in valid_color_rects:
		if is_instance_valid(cr):
			has_valid_cr = true
			break

	if has_valid_cr:
		var vanish_tween = create_tween().set_parallel(true)
		for cr in valid_color_rects:
			if is_instance_valid(cr):
				vanish_tween.tween_property(cr, "scale", Vector2.ZERO, vanish_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
				vanish_tween.tween_property(cr, "modulate:a", 0.0, vanish_duration)

	# 【修正】Tweenのfinishedを待たず、必ず時間で復帰する。これによりcrが消えてもここでハングしない。
	await get_tree().create_timer(vanish_duration).timeout

	# 5. 演出完了後、時間停止を解除（何があっても必ずここに到達する）
	slow_motion_requested.emit(false)


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


# ドッキング成立時に、接合点で広がる円形の衝撃波（リング）。
# 以前は磁力ライン(MagneticLink)の終端に内蔵されていたが、パチッ(play_snap_particles)と
# タイミングを完全同期させて任意秒ずらせるよう、独立したエフェクトとして切り出した。
# 呼び出し側(Board)が snap_at で発火するため、ここではタイミングを持たず「広がる」だけに専念する。
func play_dock_shockwave(center: Vector2) -> void:
	var settings: GameSettings = preload("res://game_settings.tres")
	var radius: float = 64.0
	if settings != null and settings.get("dock_shockwave_radius") != null:
		radius = maxf(0.0, settings.dock_shockwave_radius)
	if radius <= 0.0:
		return
	var alpha: float = 0.3
	if settings != null and settings.get("shockwave_fill_alpha") != null:
		alpha = settings.shockwave_fill_alpha

	var wave := ShockwaveNode.new()
	wave.max_radius = radius
	wave.fill_alpha = alpha
	wave.global_position = center
	# 連鎖インターバル（ポーズ）中の結合でもリングが進行・描画されるように常時処理にする
	wave.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(wave)

	# 半径0→max へ一気に広がる。Tween もポーズ中に進むよう明示。
	var tween := create_tween().bind_node(wave)
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(wave, "current_radius", radius, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func():
		if is_instance_valid(wave):
			wave.queue_free()
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


# ==============================================================================
# 磁力ドッキング演出（電撃のように線が走り、その線に沿ってブロックが引き寄せられる）
# ==============================================================================
class MagneticLink extends Node2D:
	# 各線分は { "from": Vector2(global), "to": Vector2(global) }。EffectManager(Node)の
	# 直下に置くため、このNode2Dの変換は原点・等倍＝global座標をそのまま描画に使える。
	var segments: Array = []
	var energy: float = 1.0        # 全体の明るさ・不透明度(0..1)
	var bolt_progress: float = 0.0 # 線が from→to へ伸びていく進捗(0..1)
	var vanish: float = 0.0        # 消滅進捗(0..1)。両端が中点へ吸い込まれ、接合点でポップする。
	var core_color: Color = Color(0.85, 0.95, 1.0, 1.0)  # 中心の明るい芯（ほぼ白）
	var glow_color: Color = Color(0.35, 0.68, 1.0, 1.0)  # 外周のグロー（青）
	var _t: float = 0.0

	func _ready() -> void:
		# ポーズ中（連鎖インターバル中）の結合でも描画が止まらないように
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		if energy <= 0.001:
			return
		for seg in segments:
			_draw_bolt(seg["from"], seg["to"])

	func _draw_bolt(a: Vector2, b: Vector2) -> void:
		var mid: Vector2 = a.lerp(b, 0.5)  # 接合点（ここが本当につながった場所）
		if vanish <= 0.001:
			# 出現〜保持フェーズ：a から先端(tip)まで、細くフラットな発光ラインを伸ばす
			var end_f: float = clampf(bolt_progress, 0.0, 1.0)
			_draw_glow_line(a, a.lerp(b, end_f), 1.0)
			# 走るヘッド（接続が完了したら消す）
			if bolt_progress < 1.0:
				var tip: Vector2 = a.lerp(b, end_f)
				var halo: Color = glow_color
				halo.a = 0.4 * energy
				draw_circle(tip, 6.0, halo)
				draw_circle(tip, 2.5, Color(1, 1, 1, energy))
		else:
			# 消滅フェーズ：両端を中点へ吸い込みつつ細らせ、接合点でポップを弾けさせる
			var v: float = clampf(vanish, 0.0, 1.0)
			_draw_glow_line(a.lerp(mid, v), b.lerp(mid, v), 1.0 - v * 0.7)
			_draw_pop(mid, v)

	# 2点を結ぶ、細くフラットな発光ライン（グロー＋極細の芯）。ゆるい単一波だけで生かす。
	func _draw_glow_line(p0: Vector2, p1: Vector2, width_scale: float) -> void:
		if width_scale <= 0.01:
			return
		var seg_v: Vector2 = p1 - p0
		var length: float = seg_v.length()
		if length < 1.0:
			return
		var dir: Vector2 = seg_v / length
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		var seg_count: int = maxi(2, int(length / 26.0))
		var amp: float = clampf(length * 0.035, 1.0, 5.0)
		var pts: PackedVector2Array = PackedVector2Array()
		for i in range(seg_count + 1):
			var f: float = float(i) / float(seg_count)
			var basep: Vector2 = p0.lerp(p1, f)
			var envelope: float = sin(f * PI)
			var wave: float = sin(f * 5.0 - _t * 12.0) * amp * envelope
			pts.append(basep + perp * wave)
		if pts.size() < 2:
			return
		var gc: Color = glow_color
		gc.a = 0.40 * energy
		draw_polyline(pts, gc, 3.0 * width_scale, true)
		var cc: Color = core_color
		cc.a = energy
		draw_polyline(pts, cc, 1.0 * width_scale, true)

	# 接合点で線が吸い込まれて消える際の、中心の小さな閃光のみ。
	# 「広がる円形リング」と放射スパークは play_dock_shockwave / play_snap_particles 側へ移管し、
	# パチッと同じ snap_at タイミングで弾けるようにした（ここでは線の収束に専念する）。
	func _draw_pop(center: Vector2, v: float) -> void:
		var burst: float = sin(clampf(v, 0.0, 1.0) * PI)  # v=0.5 でピーク（0→1→0）
		if burst > 0.01:
			# 中心の閃光（線が一点に吸い込まれた手応えだけを残す）
			draw_circle(center, 2.0 + 6.0 * burst, Color(1, 1, 1, burst * energy))


# 磁力ラインを走らせ、その間にブロックが引き寄せられる演出を再生する。
# segments: [{ "from": global, "to": global }] / lead_in: 線が走る溜め時間 / pull_duration: 引き寄せ時間
func play_magnetic_dock(segments: Array, lead_in: float, pull_duration: float) -> void:
	if segments == null or segments.is_empty():
		return

	var link := MagneticLink.new()
	link.segments = segments
	link.bolt_progress = 0.0
	link.vanish = 0.0
	link.energy = 1.0
	add_child(link)

	var tween := create_tween()
	# ポーズ中（連鎖インターバル中）の結合でも演出を進行させる
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	# 1) 線が from→to へ一気に走る（チャージ）
	tween.tween_property(link, "bolt_progress", 1.0, maxf(0.01, lead_in)).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# 2) ブロックが引っ張られている間、接続を保持（＝ドッキングアニメ終了まで線を出す）
	tween.tween_interval(maxf(0.0, pull_duration))
	# 3) ドッキング完了と同時にジューシーに消滅：両端が接合点へ吸い込まれ、バースト＋放射スパークが弾ける。
	#    TRANS_BACK/EASE_IN で“タメてからシュッ”と気持ちよく消す。
	tween.tween_property(link, "vanish", 1.0, 0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.tween_callback(func():
		if is_instance_valid(link):
			link.queue_free()
	)


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
