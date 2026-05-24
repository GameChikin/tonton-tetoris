extends Node2D
class_name Tetromino
signal locked_to_board

const TETROMINO_DATA := {
	"I": {
		"cells": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"color": Color(0.20, 0.80, 0.95)
	},
	"O": {
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		"color": Color(0.95, 0.86, 0.20)
	},
	"T": {
		"cells": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		"color": Color(0.69, 0.31, 0.87)
	},
	"S": {
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1)],
		"color": Color(0.35, 0.86, 0.39)
	},
	"Z": {
		"cells": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1)],
		"color": Color(0.92, 0.31, 0.31)
	},
	"J": {
		"cells": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 1)],
		"color": Color(0.31, 0.45, 0.93)
	},
	"L": {
		"cells": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)],
		"color": Color(0.95, 0.56, 0.22)
	}
}

const SHAPE_KEYS: Array[String] = ["I", "O", "T", "S", "Z", "J", "L"]

@export var block_scene: PackedScene
@export var board_path: NodePath = NodePath("../Board")
@export var shape_id := "RANDOM"
@export var initial_pivot := Vector2i(4, 1)
@export var fall_interval := 0.6
@export var soft_drop_interval := 0.06

var board: Board
var blocks: Array[Node] = []
var local_cells: Array[Vector2i] = []
var pivot := Vector2i.ZERO
var current_color := Color.WHITE
var current_shape_key := "I"

var _fall_timer := 0.0
var _is_locked := false
var _is_input_paused := false


func _ready() -> void:
	board = get_node_or_null(board_path) as Board
	pivot = initial_pivot
	_select_shape_data()
	_spawn_blocks()
	_sync_block_positions()


func _process(delta: float) -> void:
	if _is_locked or _is_input_paused:
		return

	_handle_input()

	var interval := fall_interval
	if Input.is_action_pressed("move_down"):
		interval = soft_drop_interval

	_fall_timer += delta
	if _fall_timer >= interval:
		_fall_timer = 0.0
		if not _try_move(Vector2i.DOWN):
			_lock_to_board()


func pause_input() -> void:
	if _is_locked:
		return
	_is_input_paused = true


func resume_input() -> void:
	if _is_locked:
		return
	_is_input_paused = false


func suspend_control() -> void:
	pause_input()


func resume_control() -> void:
	resume_input()


func _select_shape_data() -> void:
	var key := shape_id
	if key == "RANDOM" or not TETROMINO_DATA.has(key):
		key = SHAPE_KEYS[randi() % SHAPE_KEYS.size()]
	current_shape_key = key

	var definition: Dictionary = TETROMINO_DATA[key] as Dictionary
	local_cells.clear()
	var cells_data: Array = definition.get("cells", [])
	for cell_data in cells_data:
		if cell_data is Vector2i:
			local_cells.append(cell_data)

	var color_data: Variant = definition.get("color", Color.WHITE)
	if color_data is Color:
		current_color = color_data
	else:
		current_color = Color.WHITE


func _spawn_blocks() -> void:
	blocks.clear()
	if block_scene == null:
		push_error("Tetromino: block_scene is not assigned.")
		return

	# Boardノードから現在のルールを取得（安全のためにデフォルトはTETRIS扱い）
	var is_puyo_rule := false
	if board != null and is_instance_valid(board):
		if "current_rule" in board and "GameRule" in board:
			# Board.GameRule.PUYO と一致するかチェック
			is_puyo_rule = (board.current_rule == board.GameRule.PUYO)

	for _i in range(local_cells.size()):
		var block: Node = block_scene.instantiate()
		add_child(block)
		
		var final_color := current_color
		var final_meta_id := current_shape_key

		# ぷよぷよルールの場合は、ブロックごとに色と名札をランダム抽選する
		if is_puyo_rule:
			var random_key: String = SHAPE_KEYS[randi() % SHAPE_KEYS.size()] as String
			if TETROMINO_DATA.has(random_key):
				var shape_def: Dictionary = TETROMINO_DATA[random_key] as Dictionary
				final_color = shape_def.get("color", Color.WHITE) as Color
				final_meta_id = random_key

		# 見た目の色を反映
		_apply_block_color(block, final_color)
		
		# 論理的な色ID（メタデータ）を付与
		block.set_meta("color_id", final_meta_id)
		
		blocks.append(block)


func _apply_block_color(block: Node, color: Color) -> void:
	if block is ColorRect:
		(block as ColorRect).color = color


func _handle_input() -> void:
	if Input.is_action_just_pressed("move_left"):
		_try_move(Vector2i.LEFT)
	if Input.is_action_just_pressed("move_right"):
		_try_move(Vector2i.RIGHT)
	if Input.is_action_just_pressed("move_fall"):
		_hard_drop()
	if Input.is_action_just_pressed("rotate"):
		_try_rotate()


func _hard_drop() -> void:
	while _try_move(Vector2i.DOWN):
		pass
	_fall_timer = 0.0
	_lock_to_board()


func _try_move(offset: Vector2i) -> bool:
	var target_pivot := pivot + offset
	if not _can_place(target_pivot, local_cells):
		return false

	pivot = target_pivot
	_sync_block_positions()
	return true


func _try_rotate() -> void:
	if current_shape_key == "O":
		return

	var rotated_cells: Array[Vector2i] = []
	for cell in local_cells:
		rotated_cells.append(Vector2i(-cell.y, cell.x))

	if not _can_place(pivot, rotated_cells):
		return

	local_cells = rotated_cells
	_sync_block_positions()


func _can_place(target_pivot: Vector2i, target_cells: Array[Vector2i]) -> bool:
	if board == null or not is_instance_valid(board):
		return false

	for rel in target_cells:
		var absolute := target_pivot + rel
		if not board.is_inside(absolute):
			return false
		if not board.is_cell_empty(absolute):
			return false
	return true


func _sync_block_positions() -> void:
	if board == null or not is_instance_valid(board):
		return

	for i in range(min(blocks.size(), local_cells.size())):
		var block: Node = blocks[i]
		if not is_instance_valid(block):
			continue
		var absolute := pivot + local_cells[i]
		var pixel := board.grid_to_pixel(absolute.x, absolute.y)
		_set_block_position(block, pixel)


func _get_absolute_cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for rel in local_cells:
		result.append(pivot + rel)
	return result


func _lock_to_board() -> void:
	if _is_locked:
		return

	_is_locked = true
	_is_input_paused = true

	if board == null or not is_instance_valid(board):
		set_process(false)
		if is_instance_valid(self):
			queue_free()
		return

	var absolute_cells: Array[Vector2i] = _get_absolute_cells()
	var locked_blocks: Array[Node] = []
	var locked_cells: Array[Vector2i] = []

	for i in range(min(blocks.size(), absolute_cells.size())):
		var block: Node = blocks[i]
		if not is_instance_valid(block):
			continue

		if block.get_parent() != board:
			block.reparent(board)

		locked_blocks.append(block)
		locked_cells.append(absolute_cells[i])

	board.lock_blocks(locked_blocks, locked_cells)
	locked_to_board.emit()

	set_process(false)
	if is_instance_valid(self):
		queue_free()


func _set_block_position(block: Node, pixel: Vector2) -> void:
	if not is_instance_valid(block):
		return

	if block is Node2D:
		(block as Node2D).position = pixel
	elif block is Control:
		(block as Control).position = pixel
