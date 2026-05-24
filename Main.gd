extends Node2D

@export var board_path: NodePath = NodePath("Board")
@export var effect_manager_path: NodePath = NodePath("EffectManager")
@export var tetromino_scene: PackedScene

var board: Board
var effect_manager: EffectManager
var active_tetromino: Tetromino
var _is_busy: bool = false


func _ready() -> void:
	board = get_node_or_null(board_path) as Board
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	_spawn_tetromino()


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
	_is_busy = true

	if board != null and is_instance_valid(board):
		await board.resolve_lines()

	_is_busy = false
	_spawn_tetromino()


func _run_tonton() -> void:
	if _is_busy:
		return

	_is_busy = true

	if active_tetromino != null and is_instance_valid(active_tetromino):
		active_tetromino.pause_input()

	if effect_manager != null and is_instance_valid(effect_manager):
		await effect_manager.shake_camera()

	if board != null and is_instance_valid(board):
		await board.apply_tonton_drop()
		await board.resolve_lines()

	if active_tetromino != null and is_instance_valid(active_tetromino):
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
