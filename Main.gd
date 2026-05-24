extends Node2D

@export var board_path: NodePath = NodePath("Board")
@export var effect_manager_path: NodePath = NodePath("EffectManager")
@export var tetromino_scene: PackedScene

var board: Board
var effect_manager: EffectManager
var active_tetromino: Tetromino
var is_tonton_in_progress: bool = false


func _ready() -> void:
	board = get_node_or_null(board_path) as Board
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	_spawn_tetromino()


func _process(_delta: float) -> void:
	if active_tetromino == null or not is_instance_valid(active_tetromino):
		_spawn_tetromino()


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("tonton"):
		return
	if is_tonton_in_progress:
		return
	await _run_tonton()


func _spawn_tetromino() -> void:
	if tetromino_scene == null:
		push_warning("Main: tetromino_scene is not assigned.")
		return
	if active_tetromino != null and is_instance_valid(active_tetromino):
		return

	var instance: Tetromino = tetromino_scene.instantiate() as Tetromino
	add_child(instance)
	active_tetromino = instance


func _run_tonton() -> void:
	if is_tonton_in_progress:
		return

	is_tonton_in_progress = true

	if active_tetromino != null and is_instance_valid(active_tetromino):
		active_tetromino.pause_input()

	if effect_manager != null:
		await effect_manager.shake_camera()

	if board != null:
		board.apply_tonton_drop()
		await board.resolve_lines()

	if active_tetromino != null and is_instance_valid(active_tetromino):
		active_tetromino.resume_input()

	is_tonton_in_progress = false
