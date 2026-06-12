extends Node2D

@export var board_path: NodePath = NodePath("Board")
@export var effect_manager_path: NodePath = NodePath("EffectManager")
@export var audio_manager_path: NodePath = NodePath("AudioManager")
@export var tetromino_scene: PackedScene

@onready var ai_controller: AIController = get_node_or_null("AIController")

var board: Board
var effect_manager: EffectManager
var audio_manager: AudioManager
var active_tetromino: Tetromino
var _is_busy: bool = false
var game_settings: GameSettings = preload("res://game_settings.tres")
var deadline_line: Line2D
var warning_rect: ColorRect
var game_over_timer: float = 0.0
var _spawn_timer: float = 0.0
var _survival_time: float = 0.0

# --- タイムアタック関連 ---
var _is_time_attack: bool = false
var _time_remaining: float = 0.0
var time_label: Label


func _ready() -> void:
	board = get_node_or_null(board_path) as Board
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	audio_manager = get_node_or_null(audio_manager_path) as AudioManager

	# 連鎖完了時に保留していた新しいブロックを生成するためシグナルを接続
	if is_instance_valid(board):
		board.resolve_finished.connect(_spawn_tetromino)
		# サウンド連携：ドッキング/ブロック破壊のSEを AudioManager へ橋渡し（シグナルで疎結合）
		if is_instance_valid(audio_manager):
			board.block_docked.connect(audio_manager.play_dock_se)
			board.block_cleared.connect(audio_manager.play_break_se)

	# ゲーム本編開始：BGMをループ再生する
	if is_instance_valid(audio_manager):
		audio_manager.play_bgm()

	# メニューのサウンドボタンへ現在のミュート状態を反映する
	_update_mute_button_text()

	_spawn_tetromino()

	# AIControllerが存在する場合、Mainの参照を渡してセットアップを実行
	if is_instance_valid(ai_controller):
		ai_controller.setup(self)

	deadline_line = get_node_or_null("DeadlineLine")
	warning_rect = get_node_or_null("WarningRect")

	# 警告線の初期設定 (Y=0を基準に生成。位置は_processで動的に更新する)
	if is_instance_valid(deadline_line):
		deadline_line.clear_points()
		deadline_line.add_point(Vector2(-5000, 0))
		deadline_line.add_point(Vector2(5000, 0))
		deadline_line.default_color = Color(1.0, 0.2, 0.2, 0.8) # 薄い赤色
		deadline_line.width = 4.0
		
	# 警告背景の初期設定
	if is_instance_valid(warning_rect):
		warning_rect.size = Vector2(10000, 5000)
		warning_rect.color = Color(1.0, 0.0, 0.0, 0.0) # 透明

	# --- ゲームモードの初期化（タイトルで選択された値を参照）---
	_is_time_attack = SaveManager.selected_mode == SaveManager.GameMode.TIME_ATTACK
	time_label = get_node_or_null("ScoreUI/TimeLabel")
	var time_panel = get_node_or_null("ScoreUI/TimePanel")
	if _is_time_attack and is_instance_valid(game_settings):
		_time_remaining = game_settings.time_attack_duration
	# エンドレスモードでは中央上のタイム表示を隠す
	if is_instance_valid(time_label):
		time_label.visible = _is_time_attack
	if is_instance_valid(time_panel):
		time_panel.visible = _is_time_attack
	_update_time_label()


func _input(_event: InputEvent) -> void:
	# トントンギミックは廃止され、_processでの入力ポーリングへ移行したため破棄
	pass

func _spawn_tetromino() -> void:
	if tetromino_scene == null:
		push_warning("Main: tetromino_scene is not assigned.")
		return
	if _is_busy:
		return
		
	if is_instance_valid(board) and board.has_method("is_chain_active") and board.is_chain_active():
		return

	var instance: Tetromino = tetromino_scene.instantiate() as Tetromino
	if instance == null:
		push_warning("Main: failed to instantiate Tetromino.")
		return

	# 並列の物理落下システムへ移行：生成後、即座に物理演算を有効化して自由落下（重力とスナップの適用）を開始させる
	add_child(instance)
	# 枠（盤面）の基準点を起点に、設定したXYオフセットだけずらした位置から出現させる
	instance.global_position = _get_spawn_position()
	active_tetromino = instance
	if instance.has_method("_lock_to_board"):
		instance._lock_to_board()


# プレイヤーのブロック出現座標を、枠の基準点＋設定オフセット(XY)で算出する（枠ドラッグに追従）
func _get_spawn_position() -> Vector2:
	var offset := Vector2(160.0, 0.0)
	if is_instance_valid(game_settings):
		offset = Vector2(game_settings.spawn_center_offset_x, game_settings.spawn_center_offset_y)
	if is_instance_valid(board):
		var frame = board.get_node_or_null("BoardPhysicsFrame")
		if is_instance_valid(frame):
			return frame.global_position + offset
	return offset


func _process(delta: float) -> void:
	if _is_busy:
		return

	# --- タイムアタック：制限時間のカウントダウン（0でゲームオーバー）---
	if _is_time_attack:
		var ta_resolving: bool = is_instance_valid(board) and board.has_method("is_chain_active") and board.is_chain_active()
		# 連鎖演出中はデッドライン判定と同様にタイマーも凍結する
		if not ta_resolving:
			_time_remaining = max(0.0, _time_remaining - delta)
			_update_time_label()
			if _time_remaining <= 0.0:
				game_over(true) # 制限時間切れは「TIME UP」表示にする
				return

	if is_instance_valid(board) and board.has_method("check_deadline_exceeded"):
		var threshold_offset = 0.0
		var grace = 2.0
		if is_instance_valid(game_settings):
			threshold_offset = game_settings.game_over_y_threshold
			grace = game_settings.game_over_grace_period
			
		var ref_node = board.get_node_or_null("BoardPhysicsFrame")
		if not ref_node:
			ref_node = board
			
		var current_deadline_y = ref_node.global_position.y + threshold_offset
		
		if is_instance_valid(deadline_line):
			deadline_line.global_position = Vector2(0, current_deadline_y)
		if is_instance_valid(warning_rect):
			warning_rect.global_position = Vector2(-5000, current_deadline_y - 5000)
			
		# 連鎖（ブロック破壊・スロー演出）中はゲームオーバー判定を凍結する。
		# 理由: ライン上にブロックがある状態で連鎖が起きると、スロー中もタイマーが
		# 加算され続け「連鎖するだけでゲームオーバー」になってしまうため。
		# 連鎖中は game_over_timer を加算もリセットもせず保持し、通常速度に戻ってから
		# 途中の値のまま加算を再開させる。警告色も更新しないことで、止まった瞬間の濃さで固定する。
		var is_resolving: bool = board.has_method("is_chain_active") and board.is_chain_active()
		if not is_resolving:
			if board.check_deadline_exceeded(current_deadline_y):
				game_over_timer += delta
				if is_instance_valid(warning_rect):
					var warning_alpha = clamp(game_over_timer / grace, 0.0, 1.0) * 0.4
					warning_rect.color = Color(1.0, 0.0, 0.0, warning_alpha)
					
				if game_over_timer >= grace:
					if is_instance_valid(warning_rect):
						warning_rect.color = Color(1.0, 0.0, 0.0, 0.6)
					game_over()
			else:
				# ラインより下に戻った場合は即ゼロリセットせず、徐々に減衰させる。
				# 理由: 物理ブロックの一瞬の振動でタイマーが消えると警告(赤)がチラつき、
				# 「いつ死ぬのか読めない」不公平・ストレスにつながるため。減衰式にすることで
				# 越えている間はジワジワ濃くなり、下げればスーッと引く危険ゲージとして機能する。
				var recovery_rate = 1.5
				if is_instance_valid(game_settings) and game_settings.get("game_over_recovery_rate") != null:
					recovery_rate = game_settings.get("game_over_recovery_rate")
				game_over_timer = max(0.0, game_over_timer - delta * recovery_rate)
				if is_instance_valid(warning_rect):
					var warning_alpha = clamp(game_over_timer / grace, 0.0, 1.0) * 0.4
					warning_rect.color = Color(1.0, 0.0, 0.0, warning_alpha)

	# --- スポーンタイマー処理 ---
	if is_instance_valid(board) and board.has_method("is_chain_active") and board.is_chain_active():
		pass # 連鎖中はスポーンをストップ
	else:
		_survival_time += delta
		var current_interval = 3.0
		var fast_forward = 0.15
		
		if is_instance_valid(game_settings):
			# 0除算を防ぎつつ、難易度上昇ステップを計算
			var safe_interval = max(1.0, game_settings.get("spawn_speedup_interval"))
			var speedup_steps = floor(_survival_time / safe_interval)
			var target_interval = game_settings.get("base_spawn_interval") - (speedup_steps * game_settings.get("spawn_speedup_amount"))
			current_interval = max(target_interval, game_settings.get("min_spawn_interval"))
			fast_forward = game_settings.get("fast_forward_spawn_interval")
			
		# スペースキー入力で間隔を早送りに上書き
		if Input.is_action_pressed("tonton"):
			current_interval = fast_forward
			
		_spawn_timer += delta
		if _spawn_timer >= current_interval:
			_spawn_timer = 0.0
			_spawn_tetromino()


func _update_time_label() -> void:
	if not is_instance_valid(time_label):
		return
	# 残り時間を切り上げた秒数のみで表示（例: 120 → 0 で終了）
	time_label.text = str(int(ceil(_time_remaining)))


func load_preset_board(preset_matrix: Array) -> void:
	if _is_busy:
		return

	for child in get_children():
		if child is Tetromino and not child.get("_is_locked"):
			child.queue_free()
	active_tetromino = null

	if board != null and is_instance_valid(board):
		board.force_set_grid_from_data(preset_matrix)

	_spawn_timer = 0.0
	_spawn_tetromino()


# is_time_up: タイムアタックの制限時間切れによる終了なら true（リザルトの見出しを変える）
func game_over(is_time_up: bool = false) -> void:
	if _is_busy: return
	# デバッグ無敵化：ゲームオーバー処理自体を行わない（デッドライン・時間切れ両経路をここで一括バイパス）。
	# 危険警告タイマーが溜まりっぱなしにならないよう、ついでにリセットしておく。
	if is_instance_valid(game_settings) and game_settings.get("debug_invincible") == true:
		game_over_timer = 0.0
		return
	_is_busy = true
	
	# --- ゲームの完全停止 ---
	# フェイルセーフ：連鎖スロー演出が残っていれば解除する
	if is_instance_valid(board) and board.has_method("set_board_slow_motion"):
		board.set_board_slow_motion(false)
	# すべてのテトリミノ（ロック済みも含む）を完全停止させる
	for child in get_children():
		if child is Tetromino and child.has_method("force_stop_for_game_over"):
			child.force_stop_for_game_over()
	# Board / EffectManager は通常 PROCESS_MODE_ALWAYS のため、ツリーポーズに従うよう戻す。
	# （ALWAYS のままだとポーズ中も Board._input がドラッグを受け付けてしまう）
	if is_instance_valid(board):
		board.process_mode = Node.PROCESS_MODE_PAUSABLE
	if is_instance_valid(effect_manager):
		effect_manager.process_mode = Node.PROCESS_MODE_PAUSABLE
	# リザルトUIだけはポーズ中も操作できるよう常時処理にする
	var result_ui_node = get_node_or_null("ResultUI")
	if is_instance_valid(result_ui_node):
		result_ui_node.process_mode = Node.PROCESS_MODE_ALWAYS
	# ツリー全体をポーズして物理・連鎖・入力を完全停止
	get_tree().paused = true

	var final_score = 0
	var max_chain = 0
	var score_mgr = get_node_or_null("ScoreManager")
	if is_instance_valid(score_mgr):
		final_score = score_mgr.current_score
		if score_mgr.has_method("get_max_chain"):
			max_chain = score_mgr.get_max_chain()
			
	SaveManager.update_score(final_score, max_chain)
	
	# リザルトUIの表示（存在する場合）。ハイスコアは現在のモードの記録を参照する
	var result_ui = get_node_or_null("ResultUI")
	if is_instance_valid(result_ui):
		result_ui.show()
		if result_ui.has_method("show_result"):
			result_ui.show_result(final_score, max_chain, SaveManager.get_high_score(), is_time_up)

func toggle_menu() -> void:
	# ゲームオーバー中はメニュー操作でポーズ状態を解除しないようにする
	if _is_busy:
		return
	var menu_panel = get_node_or_null("MenuUI/MenuPanel")
	if not is_instance_valid(menu_panel):
		return
	var opening: bool = not menu_panel.visible
	menu_panel.visible = opening
	# メニューを開いている間はゲーム全体を一時停止し、時間（とブロックの落下）を止める。
	# Board は通常 PROCESS_MODE_ALWAYS で一時停止を無視するため、メニュー中だけ
	# PAUSABLE に切り替えて確実に処理を止め、閉じたら ALWAYS に戻す。
	if is_instance_valid(board):
		board.process_mode = Node.PROCESS_MODE_PAUSABLE if opening else Node.PROCESS_MODE_ALWAYS
	get_tree().paused = opening


# メニューのサウンドボタンから接続。Masterバスのミュートを切り替えて保存する
func toggle_mute() -> void:
	SaveManager.toggle_mute()
	_update_mute_button_text()


func _update_mute_button_text() -> void:
	var btn = get_node_or_null("MenuUI/MenuPanel/MarginContainer/VBoxContainer/Button_Mute") as Button
	if is_instance_valid(btn):
		btn.text = "SOUND: OFF" if SaveManager.is_muted else "SOUND: ON"


func retry_game() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

func go_to_title() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Title.tscn")
