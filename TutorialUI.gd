extends CanvasLayer
class_name TutorialUI

# HELPボタンから開く操作チュートリアル。
# 極力テキストを使わず、実ゲームと同じ見た目のミニチュアをループアニメで見せて操作を伝える。
# 文字は補助（DRAG / SPACE / ×4 / CLICK）のみ。
#
# 設計方針：
# ・UI（暗幕・カード・閉じるボタン・ページドット）はすべて _ready() でコード生成する。
#   → プランナーは TutorialUI.tscn を1つ置くだけでよく、複雑なノード構成を手で組む必要がない。
# ・各ページのデモは _stage（Control）の draw コールバックで毎フレーム描画し、_t（累積時間）で動かす。
# ・ポーズ中（ゲーム内メニューから開いた時）もアニメ・入力が生きるよう process_mode は ALWAYS。
# ・ホスト（Main / Title）は open() を呼ぶだけ。閉じたら closed を emit する（疎結合）。

signal closed

# ページ総数。各ページ＝伝えたい操作1つ。
const PAGE_COUNT: int = 5

# カード（説明領域）のサイズ。解像度に依存せず中央に固定表示する。
const CARD_SIZE: Vector2 = Vector2(460.0, 520.0)
# デモを描画するステージ領域のサイズ（カード内の上側）。
const STAGE_SIZE: Vector2 = Vector2(460.0, 420.0)

# 実ゲームと色を揃えるため Tetromino のパレットを参照する（同色判定の見た目を一致させる）。
const COL_RED: Color = Color(0.92, 0.31, 0.31)    # Z
const COL_BLUE: Color = Color(0.31, 0.45, 0.93)   # J
const COL_GREEN: Color = Color(0.35, 0.86, 0.39)  # S
const COL_YELLOW: Color = Color(0.95, 0.86, 0.20) # O

const BLOCK_OUTLINE: Color = Color(0.05, 0.05, 0.08, 0.95)
const FRAME_BG: Color = Color(0.24, 0.24, 0.24, 1.0)
const HANDLE_COL: Color = Color(0.85, 0.65, 0.3, 1.0)

var settings: GameSettings = preload("res://game_settings.tres")

var _page: int = 0
# アニメ用の累積時間（ページ切替でリセット）。
var _t: float = 0.0

var _root: Control
var _dim: ColorRect
var _card: Control
var _stage: Control
var _dots: Control
var _close_btn: Button
var _prev_btn: Button
var _next_btn: Button


func _ready() -> void:
	layer = 15  # ゲーム内メニュー(layer=5)より手前に出す
	process_mode = Node.PROCESS_MODE_ALWAYS  # ポーズ中も動かす
	visible = false
	_build_ui()


# --- 外部API -------------------------------------------------------------

# チュートリアルを最初のページから開く。ホスト（Main/Title）が呼ぶ。
func open() -> void:
	_page = 0
	_t = 0.0
	visible = true
	_refresh_page()


# --- UI構築（コード生成）-------------------------------------------------

func _build_ui() -> void:
	# 画面全体を覆う暗幕兼クリック受付。ここをクリックすると次のページへ進む。
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.0, 0.0, 0.0, 0.78)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(_on_dim_gui_input)
	_root.add_child(_dim)

	# 中央のカード（説明パネル）。解像度が変わっても中央に固定。
	_card = Control.new()
	_card.set_anchors_preset(Control.PRESET_CENTER)
	_card.custom_minimum_size = CARD_SIZE
	_card.size = CARD_SIZE
	_card.offset_left = -CARD_SIZE.x * 0.5
	_card.offset_top = -CARD_SIZE.y * 0.5
	_card.offset_right = CARD_SIZE.x * 0.5
	_card.offset_bottom = CARD_SIZE.y * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE  # クリックは暗幕へ素通しさせる
	_root.add_child(_card)

	# カードの背景パネル（やや明るいスレート＋枠）。
	var panel := ColorRect.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.color = Color(0.12, 0.13, 0.16, 1.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(panel)
	var border := ReferenceRect.new()
	border.set_anchors_preset(Control.PRESET_FULL_RECT)
	border.border_color = Color(1.0, 1.0, 1.0, 0.22)
	border.border_width = 2.0
	border.editor_only = false
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(border)

	# デモ描画ステージ（カード上側）。draw シグナルで毎フレーム描く。
	_stage = Control.new()
	_stage.position = Vector2(0.0, 0.0)
	_stage.custom_minimum_size = STAGE_SIZE
	_stage.size = STAGE_SIZE
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.draw.connect(_on_stage_draw)
	_card.add_child(_stage)

	# ページ進捗ドット（カード下側）。
	_dots = Control.new()
	_dots.position = Vector2(0.0, STAGE_SIZE.y + 24.0)
	_dots.custom_minimum_size = Vector2(CARD_SIZE.x, 24.0)
	_dots.size = Vector2(CARD_SIZE.x, 24.0)
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.draw.connect(_on_dots_draw)
	_card.add_child(_dots)

	# 閉じる（スキップ）ボタン。カード右上の「✕」。
	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.focus_mode = Control.FOCUS_NONE
	_close_btn.add_theme_font_size_override("font_size", 28)
	_close_btn.custom_minimum_size = Vector2(44.0, 44.0)
	_close_btn.position = Vector2(CARD_SIZE.x - 52.0, 8.0)
	_close_btn.pressed.connect(_finish)
	_card.add_child(_close_btn)

	# ページ送りの ＜ ＞ ボタン。画面端ではなく、カード自身の左右の端（縦中央）に置く。
	_prev_btn = _make_nav_button("＜")
	_prev_btn.position = Vector2(6.0, (CARD_SIZE.y - 48.0) * 0.5)
	_prev_btn.pressed.connect(_prev)
	_card.add_child(_prev_btn)

	_next_btn = _make_nav_button("＞")
	_next_btn.position = Vector2(CARD_SIZE.x - 54.0, (CARD_SIZE.y - 48.0) * 0.5)
	_next_btn.pressed.connect(_advance)
	_card.add_child(_next_btn)


# ページ送り用の矢印ボタンを生成する（カード左右端に置く、背景なしのフラット表示）。
func _make_nav_button(label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 40)
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	b.add_theme_color_override("font_hover_color", Color(1, 0.85, 0.4, 1.0))
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.custom_minimum_size = Vector2(48.0, 48.0)
	b.size = Vector2(48.0, 48.0)
	return b


# --- 入力・ページ送り ----------------------------------------------------

func _on_dim_gui_input(event: InputEvent) -> void:
	# カード外の暗幕をクリックしたら次のページへ進む（戻るは ＜ ボタンで明示操作）。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_advance()


func _advance() -> void:
	_page += 1
	if _page >= PAGE_COUNT:
		_finish()
		return
	_t = 0.0
	_refresh_page()


# 前のページへ戻る。最初のページより前へは行かない（閉じない）。
func _prev() -> void:
	if _page <= 0:
		return
	_page -= 1
	_t = 0.0
	_refresh_page()


func _finish() -> void:
	visible = false
	closed.emit()


func _refresh_page() -> void:
	# 先頭ページでは戻る（＜）を隠す。
	if is_instance_valid(_prev_btn):
		_prev_btn.visible = _page > 0
	if is_instance_valid(_dots):
		_dots.queue_redraw()
	if is_instance_valid(_stage):
		_stage.queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	var speed: float = 1.0
	if settings != null and settings.get("tutorial_anim_speed") != null:
		speed = settings.get("tutorial_anim_speed")
	_t += delta * speed
	if is_instance_valid(_stage):
		_stage.queue_redraw()


# --- 描画：ページドット --------------------------------------------------

func _on_dots_draw() -> void:
	var gap: float = 22.0
	var total: float = gap * float(PAGE_COUNT - 1)
	var start_x: float = (CARD_SIZE.x - total) * 0.5
	var y: float = 12.0
	for i in range(PAGE_COUNT):
		var c: Vector2 = Vector2(start_x + gap * float(i), y)
		if i == _page:
			_dots.draw_circle(c, 6.0, Color(1.0, 0.85, 0.4, 1.0))
		else:
			_dots.draw_circle(c, 4.0, Color(1.0, 1.0, 1.0, 0.35))


# --- 描画：ステージ（ページ別デモ）--------------------------------------

func _on_stage_draw() -> void:
	# 各ページは period 秒でループする。phase は 0..1。
	match _page:
		0:
			_draw_page_move_frame()
		1:
			_draw_page_grab_block()
		2:
			_draw_page_dock()
		3:
			_draw_page_clear()
		4:
			_draw_page_space()


# ページ0：枠（取っ手）を掴んで左右に振れる。中のブロックが慣性で揺れる。
func _draw_page_move_frame() -> void:
	var period: float = 2.6
	var ph: float = fmod(_t, period) / period
	var swing: float = sin(ph * TAU)            # -1..1 左右振り
	var fw: float = 150.0
	var fh: float = 220.0
	var base_x: float = STAGE_SIZE.x * 0.5 - fw * 0.5
	var origin: Vector2 = Vector2(base_x + swing * 46.0, 70.0)

	_draw_frame(origin, fw, fh)

	# 中のブロックは枠より少し遅れて揺れる（慣性表現）。
	var lag: float = sin((ph - 0.06) * TAU)
	var bw: float = 30.0
	var floor_y: float = origin.y + fh - bw - 4.0
	var cx: float = origin.x + fw * 0.5
	_draw_block(Vector2(cx - bw - 4.0 + lag * 10.0, floor_y), bw, COL_RED)
	_draw_block(Vector2(cx + 4.0 + lag * 14.0, floor_y), bw, COL_BLUE)
	_draw_block(Vector2(cx - bw * 0.5 + lag * 12.0, floor_y - bw - 4.0), bw, COL_GREEN)

	# 取っ手を掴むカーソル。
	var handle: Vector2 = origin + Vector2(fw + 14.0, fh * 0.6)
	_draw_cursor(handle, true)
	_draw_tag(Vector2(STAGE_SIZE.x * 0.5, 40.0), "DRAG", true)


# ページ1：ブロックを掴んで運ぶ。
func _draw_page_grab_block() -> void:
	var period: float = 2.8
	var ph: float = fmod(_t, period) / period
	var fw: float = 150.0
	var fh: float = 220.0
	var origin: Vector2 = Vector2(STAGE_SIZE.x * 0.5 - fw * 0.5, 70.0)
	_draw_frame(origin, fw, fh)

	var bw: float = 30.0
	var floor_y: float = origin.y + fh - bw - 4.0
	var cx: float = origin.x + fw * 0.5
	# 据え置きのブロック。
	_draw_block(Vector2(cx - bw - 4.0, floor_y), bw, COL_BLUE)
	_draw_block(Vector2(cx + 4.0, floor_y), bw, COL_GREEN)

	# 運ばれるブロック：左下→持ち上げ→右へ、を弧で往復。
	var t01: float = 0.5 - 0.5 * cos(ph * TAU)  # 0→1→0 のイージング往復
	var from_p: Vector2 = Vector2(cx - bw - 4.0, floor_y - bw - 4.0)
	var to_p: Vector2 = Vector2(cx + 4.0, floor_y - bw - 4.0)
	var carry: Vector2 = from_p.lerp(to_p, t01)
	carry.y -= sin(t01 * PI) * 40.0  # 中間で持ち上がる弧
	_draw_block(carry, bw, COL_RED)

	# カーソルはブロックの上端中央を掴む。
	_draw_cursor(carry + Vector2(bw * 0.5, 2.0), true)
	_draw_tag(Vector2(STAGE_SIZE.x * 0.5, 40.0), "DRAG", true)


# ページ2：同色ブロックを近づけるとピタッと吸着（ドッキング）。
func _draw_page_dock() -> void:
	var period: float = 2.8
	var ph: float = fmod(_t, period) / period
	var bw: float = 38.0
	var cy: float = STAGE_SIZE.y * 0.5 - 10.0
	var cx: float = STAGE_SIZE.x * 0.5
	# 左ブロックは中央のすぐ左に据え置き。接着面(seam)はちょうど中央。
	var left_anchor: Vector2 = Vector2(cx - bw, cy)
	var seam_x: float = cx  # 左ブロックの右端＝右ブロックの左端（ここでピタッと付く）

	# 接近フェーズ(0..0.55)で右の赤が左の赤へ寄る → 合体後フラッシュ → 静止 → リセット。
	var approach: float = clampf(ph / 0.55, 0.0, 1.0)
	var eased: float = 1.0 - pow(1.0 - approach, 3.0)
	var far_x: float = cx + 70.0
	var near_x: float = seam_x  # 接着時は左ブロックの右端にぴったり付く（隙間ゼロ）
	var right_x: float = lerp(far_x, near_x, eased)
	var right_p: Vector2 = Vector2(right_x, cy)

	# 据え置きの左ブロック（赤）。
	_draw_block(left_anchor, bw, COL_RED)

	var docked: bool = approach >= 1.0
	if docked:
		# 吸着成立：接着面の中心から白いリングのフラッシュを一瞬出す。
		var flash_t: float = clampf((ph - 0.55) / 0.18, 0.0, 1.0)
		if flash_t < 1.0:
			var ring_c: Vector2 = Vector2(seam_x, cy + bw * 0.5)
			_stage.draw_arc(ring_c, 26.0 + flash_t * 26.0, 0, TAU, 32,
				Color(1, 1, 1, 0.7 * (1.0 - flash_t)), 4.0)
	_draw_block(right_p, bw, COL_RED)

	# 接近中はカーソルが右ブロックを押す。矢印で向きを補助。
	if not docked:
		_draw_cursor(right_p + Vector2(bw + 6.0, bw * 0.5), true)
		_draw_arrow(Vector2(right_x + bw + 30.0, cy + bw * 0.5),
			Vector2(right_x + bw + 6.0, cy + bw * 0.5))
	_draw_tag(Vector2(STAGE_SIZE.x * 0.5, 56.0), "SAME COLOR", false)


# ページ3：同色4つで破壊（連鎖）。
func _draw_page_clear() -> void:
	var period: float = 3.0
	var ph: float = fmod(_t, period) / period
	var bw: float = 34.0
	var cx: float = STAGE_SIZE.x * 0.5
	var cy: float = STAGE_SIZE.y * 0.5
	# 田の字に4つを隙間なく敷き詰める（隣り合う辺を共有させてピタッと接着して見せる）。
	var slots: Array = [
		Vector2(cx - bw, cy - bw),  # 左上
		Vector2(cx, cy - bw),       # 右上
		Vector2(cx - bw, cy),       # 左下
	]
	var fourth: Vector2 = Vector2(cx, cy)  # 右下（4つ目）

	# フェーズ：接近(0..0.4) → 白発光チャージ(0.4..0.6) → 破壊バースト(0.6..0.85) → 余韻。
	for s in slots:
		_draw_block_phase(s, bw, COL_GREEN, ph)

	if ph < 0.4:
		# 4つ目が下から寄ってくる。
		var a: float = ph / 0.4
		var start_p: Vector2 = fourth + Vector2(0.0, 70.0)
		var p: Vector2 = start_p.lerp(fourth, 1.0 - pow(1.0 - a, 3.0))
		_draw_block(p, bw, COL_GREEN)
		_draw_cursor(p + Vector2(bw * 0.5, 2.0), true)
		_draw_tag(Vector2(cx, 46.0), "x4", true)
	elif ph < 0.6:
		# 4つ揃って白く発光（チャージ）。3つは上の for ループが、4つ目はここで描く。
		var g: float = (ph - 0.4) / 0.2
		_draw_block(fourth, bw, COL_GREEN, g)
		_draw_tag(Vector2(cx, 46.0), "x4", true)
	elif ph < 0.85:
		# 破壊バースト：白フラッシュ＋四方に飛ぶ破片。
		var b: float = (ph - 0.6) / 0.25
		var burst_center: Vector2 = Vector2(cx, cy)
		_stage.draw_circle(burst_center, 40.0 * (1.0 - b), Color(1, 1, 1, 0.8 * (1.0 - b)))
		for i in range(8):
			var ang: float = TAU * float(i) / 8.0
			var dist: float = b * 90.0
			var pc: Vector2 = burst_center + Vector2(cos(ang), sin(ang)) * dist
			var sz: float = (1.0 - b) * 12.0
			if sz > 0.5:
				_stage.draw_rect(Rect2(pc - Vector2(sz, sz) * 0.5, Vector2(sz, sz)),
					Color(0.6, 1.0, 0.6, 1.0 - b), true)
	# 余韻(0.85..1.0)は何も描かずクールダウン。


# ページ4：スペースキーでブロックを早く落とせる。
func _draw_page_space() -> void:
	var period: float = 2.4
	var ph: float = fmod(_t, period) / period
	var fw: float = 150.0
	var fh: float = 230.0
	var origin: Vector2 = Vector2(STAGE_SIZE.x * 0.5 - fw * 0.5, 56.0)
	_draw_frame(origin, fw, fh)

	# キーは前半周期で「押下」状態。押している間はブロックが速く落ちる。
	var pressed: bool = fmod(_t, period) < period * 0.6
	var bw: float = 28.0
	var cx: float = origin.x + fw * 0.5
	var top_y: float = origin.y + 6.0
	var floor_y: float = origin.y + fh - bw - 4.0

	# 落下中ブロック（押下中は速い）。複数を時間差で落とす。
	var fall_speed: float = 2.6 if pressed else 1.0
	for i in range(3):
		var fp: float = fmod(_t * fall_speed + float(i) * 0.34, 1.0)
		var y: float = lerp(top_y, floor_y, fp)
		var cols: Array = [COL_RED, COL_YELLOW, COL_BLUE]
		_draw_block(Vector2(cx - bw * 0.5 + (float(i) - 1.0) * (bw + 4.0), y), bw, cols[i])

	# スペースキーアイコン（カード下部）。
	_draw_key(Vector2(STAGE_SIZE.x * 0.5, STAGE_SIZE.y - 46.0), "SPACE", pressed)


# --- 描画ヘルパー --------------------------------------------------------

# 実ゲームのブロックに寄せた見た目（外枠＋本体＋上部ツヤ＋任意の白発光）。
func _draw_block(pos: Vector2, s: float, col: Color, glow: float = 0.0) -> void:
	var r := Rect2(pos, Vector2(s, s))
	_stage.draw_rect(r.grow(2.0), BLOCK_OUTLINE, true)
	# 白発光（破壊チャージ）は本体色を白へ寄せて表現。
	var body: Color = col.lerp(Color.WHITE, clampf(glow, 0.0, 1.0) * 0.85)
	_stage.draw_rect(r, body, true)
	_stage.draw_rect(Rect2(pos, Vector2(s, s * 0.28)), Color(1, 1, 1, 0.22), true)
	if glow > 0.0:
		_stage.draw_rect(r.grow(2.0 + glow * 3.0), Color(1, 1, 1, 0.6 * glow), false, 2.0)


# glow を ph 連動にしたい据え置きブロック用（ページ3で4つ同時発光させる）。
func _draw_block_phase(pos: Vector2, s: float, col: Color, ph: float, forced_glow: float = -1.0) -> void:
	var g: float = forced_glow
	if g < 0.0:
		g = 0.0
		if ph >= 0.4 and ph < 0.6:
			g = (ph - 0.4) / 0.2
	# 破壊フェーズ(0.6〜)では据え置きブロックは消える（バーストへ移行）。
	if ph >= 0.6:
		return
	_draw_block(pos, s, col, g)


# 物理枠（盤面＋取っ手）のミニチュア。
func _draw_frame(origin: Vector2, w: float, h: float) -> void:
	var r := Rect2(origin, Vector2(w, h))
	_stage.draw_rect(r, FRAME_BG, true)
	_stage.draw_rect(r, Color(1, 1, 1, 0.9), false, 2.0)
	# 右側の取っ手（ジョッキの取っ手モチーフの半円）。
	var hc: Vector2 = origin + Vector2(w, h * 0.6)
	_stage.draw_arc(hc, 18.0, deg_to_rad(-90.0), deg_to_rad(90.0), 16, HANDLE_COL.darkened(0.4), 9.0)
	_stage.draw_arc(hc, 18.0, deg_to_rad(-90.0), deg_to_rad(90.0), 16, HANDLE_COL, 5.0)


# マウスカーソル（矢印）。pressed の時はクリック波紋を添える。
func _draw_cursor(tip: Vector2, pressed: bool = false) -> void:
	var pts := PackedVector2Array([
		tip,
		tip + Vector2(0.0, 22.0),
		tip + Vector2(6.0, 16.0),
		tip + Vector2(10.0, 25.0),
		tip + Vector2(14.0, 23.0),
		tip + Vector2(10.0, 14.0),
		tip + Vector2(18.0, 13.0),
	])
	_stage.draw_colored_polygon(pts, Color.WHITE)
	var outline := pts
	outline.append(tip)
	_stage.draw_polyline(outline, Color(0, 0, 0, 0.9), 1.5)
	if pressed:
		_stage.draw_arc(tip + Vector2(2.0, 2.0), 16.0, 0, TAU, 20, Color(1, 1, 1, 0.5), 2.0)


# 向きを示す矢印（from→to）。
func _draw_arrow(from_p: Vector2, to_p: Vector2) -> void:
	var col := Color(1, 1, 1, 0.85)
	_stage.draw_line(from_p, to_p, col, 3.0)
	var dir: Vector2 = (to_p - from_p).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var head: Vector2 = to_p
	_stage.draw_colored_polygon(PackedVector2Array([
		head,
		head - dir * 12.0 + perp * 7.0,
		head - dir * 12.0 - perp * 7.0,
	]), col)


# キーキャップ風アイコン。
func _draw_key(center: Vector2, label: String, pressed: bool) -> void:
	var w: float = 150.0
	var h: float = 40.0
	var off: float = 3.0 if pressed else 0.0
	var r := Rect2(center - Vector2(w * 0.5, h * 0.5) + Vector2(0.0, off), Vector2(w, h))
	_stage.draw_rect(r.grow(3.0), Color(0.05, 0.05, 0.08, 1.0), true)
	var top: Color = Color(0.9, 0.9, 0.95, 1.0) if pressed else Color(0.78, 0.8, 0.86, 1.0)
	_stage.draw_rect(r, top, true)
	var font := ThemeDB.fallback_font
	var fs: int = 20
	var tw: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_stage.draw_string(font, r.position + Vector2((w - tw) * 0.5, h * 0.5 + fs * 0.35),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.1, 0.1, 0.12, 1.0))


# 補助の短い文字タグ（DRAG / x4 など）。emphasized で強調色。
func _draw_tag(center: Vector2, text: String, emphasized: bool) -> void:
	var font := ThemeDB.fallback_font
	var fs: int = 26 if emphasized else 20
	var col: Color = Color(1.0, 0.85, 0.4, 1.0) if emphasized else Color(1, 1, 1, 0.75)
	var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_stage.draw_string(font, center - Vector2(tw * 0.5, 0.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
