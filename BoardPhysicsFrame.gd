extends AnimatableBody2D

# 盤面を掴んで動かすための「持ち手（ジョッキの取っ手）」を管理する。
# 以前は盤面全域が掴み判定だったため、積まれたブロックと被って意図せず掴んでしまう問題があった。
# 盤面の右下に専用の取っ手を設け、そこだけを掴み判定にすることで誤操作を防ぐ。

var settings: GameSettings = preload("res://game_settings.tres")

# 枠がこの速度(px/秒)未満になったら「止まった」とみなし、ブロックへの引きずりを解除して
# 慣性で自由に飛ばす（鍋を止めた瞬間に米が舞う＝ブレーキをかけないためのしきい値）。
const RELEASE_SPEED := 15.0
# 枠速度がこの量(px/秒)以上「下がった」ら減速中とみなし、運びを止めて慣性に任せる。
# ノイズで運ぶ/離すがチラつかないための不感帯。
const DECEL_TOLERANCE := 20.0

# 掴み判定の外接矩形（取っ手の当たり判定）。update_grab_area / _rebuild_handle で算出する。
var _grab_rect: Rect2 = Rect2()

# 描画と判定の基準にする盤面サイズ（Boardから渡される）
var _board_width: float = 320.0
var _board_height: float = 640.0

var _is_dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

# 加速/減速の判定用：平滑化した枠速度と、前フレームのその速さ。
# 「減速し始めたら運びを止めて慣性に任せる」ためにフレーム間で保持する。
var _frame_vel_smooth: Vector2 = Vector2.ZERO
var _prev_frame_speed: float = 0.0


func _ready() -> void:
	input_pickable = false
	# 壁の移動を物理サーバ経由で同期し、触れているブロックを正しく押し出す（テレポート扱いを避ける）
	sync_to_physics = true
	# Boardからの初期化呼び出し前でも描画・判定が成立するようフォールバック構築する
	_rebuild_handle(_board_width, _board_height)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var local_mouse_pos: Vector2 = get_local_mouse_position()
			# 取っ手の外接矩形内を掴んだときのみドラッグ開始する（盤面本体では掴めない）
			if _grab_rect.has_point(local_mouse_pos):
				_is_dragging = true
				_drag_offset = get_global_mouse_position() - global_position
				# 掴み直しのたびに加速/減速判定をクリーンに始める
				_frame_vel_smooth = Vector2.ZERO
				_prev_frame_speed = 0.0
				get_viewport().set_input_as_handled()
		else:
			_is_dragging = false


# 外部（Board）から、いま枠が掴まれて動かされている最中かを取得する。
# ゲームオーバー判定で「枠を振り回してブロックを飛ばし続け、速度除外で耐える」抜け道を
# ふさぐために参照する（ドラッグ中は速度に関わらずデッドライン越えを危険とみなす）。
func is_being_dragged() -> bool:
	return _is_dragging


func _physics_process(delta: float) -> void:
	if _is_dragging:
		# マウス追従先を、まず可動範囲（枠＋取っ手が画面端からはみ出さない範囲）にクランプする
		var target_pos: Vector2 = _clamp_to_view(get_global_mouse_position() - _drag_offset)
		# 1物理フレームの移動量に上限を設ける。壁が一度にブロックをまたぐほど飛ぶと
		# すり抜け（トンネリング）が起きるため、最大追従速度でクランプする。
		var max_speed: float = _get_setting("max_frame_drag_speed", 0.0)
		var max_step: float = max_speed * delta
		var prev_pos: Vector2 = global_position
		var to_target: Vector2 = target_pos - prev_pos
		# ※sync_to_physics=true の AnimatableBody2D は global_position への書き込みが物理サーバへ
		#   遅延反映され、同フレーム内で読み返すと古い値のままになる。よって移動量は読み返しでは
		#   なく「これから設定する新座標」をローカル変数 new_pos で保持して算出する。
		var new_pos: Vector2
		if max_step <= 0.0 or to_target.length() <= max_step:
			new_pos = target_pos
		else:
			new_pos = prev_pos + to_target.normalized() * max_step
		global_position = new_pos

		# 枠の移動速度を求め、中のブロックを粘性ドラッグで引きずる（チャーハンの鍋＝慣性追従）。
		# 速度を上書きせず「力（インパルス）」を加えるだけなので、重力など本来の物理はそのまま生きる。
		# 加速/減速の判定をマウスのジッターで暴れさせないよう、平滑化した速度を使う。
		if delta > 0.0:
			var frame_velocity: Vector2 = (new_pos - prev_pos) / delta
			_frame_vel_smooth = _frame_vel_smooth.lerp(frame_velocity, 0.4)
			_drag_inner_blocks(_frame_vel_smooth, delta)


# 枠の速度へ向けて各テトリミノに粘性ドラッグのインパルスを加え、慣性で“遅れて”追従させる。
#   Δv = strength * delta * (枠速度 - ブロック速度) を毎フレーム与える（= 連続的な力と等価）
# ・速度を上書きせず差分を足すだけなので重力と共存し、落下や物理の手触りを壊さない。
# ・ブロック速度は枠速度を超えないため暴れにくく、枠開口部から飛び出しにくい。
# ・strength が小さいほど“もっさり”遅れて付いてくる（鍋の米のイメージ）。
# ・apply_central_force と違いインパルスは眠った剛体も確実に起こして即反映される。
func _drag_inner_blocks(frame_velocity: Vector2, delta: float) -> void:
	var strength: float = _get_setting("frame_drag_follow_strength", 2.0)
	if strength <= 0.0:
		return

	# 鍋を振る挙動の肝：「加速・等速のときだけ運び、減速し始めたら運びを止めて慣性に任せる」。
	# こうすると振り続けても、一振りごとに『押す(加速で運ぶ)→返す/止める(減速で解放)』が起き、
	# 解放された瞬間に勢いのついたブロックが慣性で飛び、重力と壁で転がる＝チャーハンが舞う。
	# ※減速時に運ぶ（=速度0へ引き戻す）と鍋を止めた瞬間に吸い付いて止まり、舞わない。
	var frame_speed: float = frame_velocity.length()
	var decelerating: bool = frame_speed < _prev_frame_speed - DECEL_TOLERANCE
	_prev_frame_speed = frame_speed
	# 止まりかけ or 減速中は運ばず、慣性に任せる
	var is_carrying: bool = frame_speed >= RELEASE_SPEED and not decelerating

	var board: Node = get_parent()
	if board == null:
		return
	if is_carrying:
		var lerp_t: float = clampf(strength * delta, 0.0, 1.0)
		var dir: Vector2 = frame_velocity / frame_speed
		for child in board.get_children():
			if not (child is Tetromino):
				continue
			var tet := child as Tetromino
			if not is_instance_valid(tet) or tet.is_queued_for_deletion():
				continue
			# 凍結中・演出・操作中の塊は触らない（落下停止／ドラッグ／結合アニメ／連鎖ロックを邪魔しない）
			if tet.freeze or tet.get("_is_dragging_by_player") or tet.get("_is_docking_animating") or tet.get("_is_chain_locked"):
				continue
			# 【慣性に任せる肝】すでに枠の進行方向と逆向きに動いているブロックは、
			# 跳ね飛ばされて宙を舞っている最中とみなし運ばない。これが無いと振り返した瞬間に
			# 掴み直して逆向きの勢いで上書きしてしまい、飛ばずに連れ戻される。
			# 壁・重力で向きが戻って枠と同方向になれば（=着地）再び運ぶ対象に戻る。
			if tet.linear_velocity.dot(dir) < 0.0:
				continue
			tet.sleeping = false
			# 運ぶ向き（枠の進行方向）成分だけ加速し、枠より速い分にはブレーキをかけない。
			var rel: Vector2 = frame_velocity - tet.linear_velocity
			var along: float = rel.dot(dir)  # 枠の進行方向に対し、まだ追いついていない分(正)だけ運ぶ
			if along > 0.0:
				tet.apply_central_impulse(dir * along * lerp_t * tet.mass)


# 見える内容（盤面＋取っ手）の外接矩形を、枠原点(global_position)からの相対座標で返す
func _get_content_rect() -> Rect2:
	var content: Rect2 = Rect2(Vector2.ZERO, Vector2(_board_width, _board_height))
	# 右へ膨らむ取っ手の掴み判定矩形を含める
	return content.merge(_grab_rect)


# 枠＋取っ手（＋マージン）がカメラの表示領域からはみ出さないよう、目標位置をクランプする
func _clamp_to_view(pos: Vector2) -> Vector2:
	var vp: Viewport = get_viewport()
	if vp == null:
		return pos
	var cam: Camera2D = vp.get_camera_2d()
	if cam == null:
		return pos

	# カメラの表示領域（ワールド座標）
	var view_size: Vector2 = vp.get_visible_rect().size / cam.zoom
	var view_center: Vector2 = cam.get_screen_center_position()
	var view_min: Vector2 = view_center - view_size * 0.5
	var view_max: Vector2 = view_center + view_size * 0.5

	var margin: float = _get_setting("frame_drag_screen_margin", 24.0)
	var content: Rect2 = _get_content_rect()

	# pos + content が [view_min+margin, view_max-margin] に収まる原点の許容範囲
	var min_pos: Vector2 = view_min + Vector2(margin, margin) - content.position
	var max_pos: Vector2 = view_max - Vector2(margin, margin) - (content.position + content.size)

	var result: Vector2 = pos
	# 内容が表示領域より大きい軸は、はみ出しを最小化するため中央に固定する
	result.x = clamp(pos.x, min_pos.x, max_pos.x) if min_pos.x <= max_pos.x else (min_pos.x + max_pos.x) * 0.5
	result.y = clamp(pos.y, min_pos.y, max_pos.y) if min_pos.y <= max_pos.y else (min_pos.y + max_pos.y) * 0.5
	return result


# 盤面のサイズ変更に合わせて、取っ手（掴み判定＋見た目）を再構築する
func update_grab_area(new_width: float, new_height: float) -> void:
	_rebuild_handle(new_width, new_height)


# 取っ手の当たり判定矩形を盤面サイズから算出し、再描画を要求する
func _rebuild_handle(new_width: float, new_height: float) -> void:
	_board_width = new_width
	_board_height = new_height

	var radius: float = _get_setting("handle_radius", 60.0)
	var thickness: float = _get_setting("handle_thickness", 16.0)
	var bottom_margin: float = _get_setting("handle_bottom_margin", 40.0)

	var center: Vector2 = _get_handle_center(new_width, new_height, radius, bottom_margin)

	# 掴み判定の外接矩形（半円の膨らみ＋太さ分の余白を含めて、見た目より少し広く取り掴みやすくする）
	var pad: float = thickness / 2.0 + 4.0
	var rect_pos: Vector2 = Vector2(new_width - pad, center.y - radius - pad)
	var rect_size: Vector2 = Vector2(radius + pad * 2.0, radius * 2.0 + pad * 2.0)
	_grab_rect = Rect2(rect_pos, rect_size)

	queue_redraw()


# 取っ手の中心座標（フレームのローカル座標）を返す。
# X：盤面の右端（半円はここから右へ膨らむ）／ Y：下端から (bottom_margin + radius) 上
func _get_handle_center(w: float, h: float, radius: float, bottom_margin: float) -> Vector2:
	return Vector2(w, h - bottom_margin - radius)


func _draw() -> void:
	var radius: float = _get_setting("handle_radius", 60.0)
	var thickness: float = _get_setting("handle_thickness", 16.0)
	var bottom_margin: float = _get_setting("handle_bottom_margin", 40.0)
	var color: Color = _get_setting("handle_color", Color(0.85, 0.65, 0.3, 1.0))

	var center: Vector2 = _get_handle_center(_board_width, _board_height, radius, bottom_margin)

	# ジョッキの取っ手モチーフ：盤面右端から右へ膨らむ半円（-90°→90°）を描く。
	# 縁取り（濃色）→本体 の順に重ね描きして立体感を出す。
	var outline: Color = color.darkened(0.4)
	draw_arc(center, radius, deg_to_rad(-90.0), deg_to_rad(90.0), 32, outline, thickness + 4.0, true)
	draw_arc(center, radius, deg_to_rad(-90.0), deg_to_rad(90.0), 32, color, thickness, true)


# GameSettingsからキー欠損に強く値を読む（既存スクリプトのフォールバックパターンに倣う）
func _get_setting(key: String, fallback: Variant) -> Variant:
	if settings != null and settings.get(key) != null:
		return settings.get(key)
	return fallback
