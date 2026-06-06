extends Node2D

@export var board_path: NodePath = NodePath("Board")
@export var effect_manager_path: NodePath = NodePath("EffectManager")
@export var tetromino_scene: PackedScene

@onready var ai_controller: AIController = get_node_or_null("AIController")

var board: Board
var effect_manager: EffectManager
var active_tetromino: Tetromino
var _is_busy: bool = false
var game_settings: GameSettings = preload("res://game_settings.tres")
var deadline_line: Line2D
var warning_rect: ColorRect
var game_over_timer: float = 0.0
var _spawn_timer: float = 0.0
var _survival_time: float = 0.0


func _ready() -> void:
	# --- 設定値のデバッグログ出力 ---
	var settings: GameSettings = preload("res://game_settings.tres")
	if settings and settings.has_method("print_all_settings"):
		settings.print_all_settings()
	# --------------------------------

	board = get_node_or_null(board_path) as Board
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	
	# 連鎖完了時に保留していた新しいブロックを生成するためシグナルを接続
	if is_instance_valid(board):
		board.resolve_finished.connect(_spawn_tetromino)
		
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
	if instance.has_method("_lock_to_board"):
		instance._lock_to_board()


func _process(delta: float) -> void:
	if _is_busy:
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
				game_over_timer = 0.0
				if is_instance_valid(warning_rect):
					warning_rect.color = Color(1.0, 0.0, 0.0, 0.0)

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


func game_over() -> void:
	if _is_busy: return
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
	
	# リザルトUIの表示（存在する場合）
	var result_ui = get_node_or_null("ResultUI")
	if is_instance_valid(result_ui):
		result_ui.show()
		if result_ui.has_method("show_result"):
			result_ui.show_result(final_score, max_chain, SaveManager.high_score)

func retry_game() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

func go_to_title() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Title.tscn")
