extends Node2D

@export var board_path: NodePath = NodePath("Board")
@export var effect_manager_path: NodePath = NodePath("EffectManager")
@export var tetromino_scene: PackedScene

@onready var ai_controller: AIController = get_node_or_null("AIController")

var board: Board
var effect_manager: EffectManager
var active_tetromino: Tetromino
var _is_busy: bool = false


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


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("tonton"):
		return
	if _is_busy:
		return
	await _run_tonton()


func _spawn_tetromino() -> void:
	if tetromino_scene == null:
		push_warning("Main: tetromino_scene is not assigned.")
		return
	if _is_busy:
		return
	if active_tetromino != null and is_instance_valid(active_tetromino):
		return
		
	# 連鎖中（スロー中）は上からの新しいブロック投下を保留する
	if is_instance_valid(board) and board.has_method("is_chain_active") and board.is_chain_active():
		return

	var instance: Tetromino = tetromino_scene.instantiate() as Tetromino
	if instance == null:
		push_warning("Main: failed to instantiate Tetromino.")
		return

	if not instance.locked_to_board.is_connected(_on_active_tetromino_locked):
		instance.locked_to_board.connect(_on_active_tetromino_locked)

	add_child(instance)
	active_tetromino = instance


func _on_active_tetromino_locked() -> void:
	active_tetromino = null
	_spawn_tetromino()


func _run_tonton() -> void:
	if _is_busy:
		return
	_is_busy = true

	if is_instance_valid(active_tetromino):
		active_tetromino.pause_input()

	if is_instance_valid(effect_manager):
		effect_manager.shake_camera()

	if is_instance_valid(board):
		board.apply_tonton_drop()

	# 物理挙動が落ち着くまでの猶予
	await get_tree().create_timer(1.5).timeout

	if is_instance_valid(active_tetromino):
		active_tetromino.resume_input()

	_is_busy = false


func load_preset_board(preset_matrix: Array) -> void:
	if _is_busy:
		return

	if active_tetromino != null and is_instance_valid(active_tetromino):
		active_tetromino.queue_free()
		active_tetromino = null

	if board != null and is_instance_valid(board):
		board.force_set_grid_from_data(preset_matrix)

	_spawn_tetromino()
