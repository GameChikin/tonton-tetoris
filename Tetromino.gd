extends RigidBody2D
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

@export_group("Physics Sleep Settings")
@export var sleep_threshold_velocity: float = 15.0
@export var sleep_delay_time: float = 0.2

@export_group("Magnetic Snap Settings")
@export var snap_rotation_strength: float = 12.0 # 角度を引き寄せる力の強さ
@export var snap_rotation_limit: float = 25.0    # 目標角度から何度以内なら磁力をかけるか
@export var snap_x_strength: float = 8.0         # X座標を引き寄せる力の強さ
@export var snap_x_limit: float = 12.0           # 目標X座標から何px以内なら磁力をかけるか

var board: Board
var blocks: Array[Node] = []
var local_cells: Array[Vector2i] = []
var pivot := Vector2i.ZERO
var current_color := Color.WHITE
var current_shape_key := "I"

var _fall_timer := 0.0
var _still_timer: float = 0.0
var _is_locked := false
var _is_input_paused := false


func _ready() -> void:
	board = get_node_or_null(board_path) as Board
	pivot = initial_pivot
	_select_shape_data()
	_spawn_blocks()
	_sync_block_positions()


func _physics_process(delta: float) -> void:
	if _is_locked:
		# --- 磁力（スナップ）補正 ---
		# 回転（Rotation）補正：最も近い90度の倍数に引き寄せる
		var current_deg = rad_to_deg(rotation)
		var target_deg = round(current_deg / 90.0) * 90.0
		var angle_diff = target_deg - current_deg
		
		# 指定された角度以内に近づいた場合のみ、角速度(Angular Velocity)に介入して姿勢を戻す
		if abs(angle_diff) <= snap_rotation_limit and abs(angle_diff) > 0.1:
			var target_ang_vel = deg_to_rad(angle_diff) * snap_rotation_strength
			angular_velocity = lerp(angular_velocity, target_ang_vel, delta * 15.0)
			
		# X座標（Position）補正：最も近い32px(CELL_SIZE)のグリッドに引き寄せる
		var cell_size = 32.0
		var target_x = round(global_position.x / cell_size) * cell_size
		var x_diff = target_x - global_position.x
		
		# 指定されたピクセル以内に近づいた場合のみ、横方向の速度(Linear Velocity X)に介入して引き寄せる
		if abs(x_diff) <= snap_x_limit and abs(x_diff) > 0.5:
			var target_vx = x_diff * snap_x_strength
			linear_velocity.x = lerp(linear_velocity.x, target_vx, delta * 15.0)
			
		return

	# 操作中の自然落下のみ（プレイヤー入力は無効、AI専用）
	if _is_input_paused:
		return

	_fall_timer += delta
	if _fall_timer >= fall_interval:
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
	var color_rect = block.get_node_or_null("ColorRect")
	if color_rect and color_rect is ColorRect:
		color_rect.color = color


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

	# 自身（テトロミノ全体の塊）をBoardの子ノードへ移籍
	reparent(board)

	# 物理演算を有効化。内包する4つのブロックが1つの物体として落下を開始する
	freeze = false

	# Board側の管理用メソッドへ通知
	var abs_cells = _get_absolute_cells()
	board.lock_blocks(blocks, abs_cells)
	locked_to_board.emit()


func _set_block_position(block: Node, pixel: Vector2) -> void:
	if not is_instance_valid(block):
		return

	if block is Node2D:
		(block as Node2D).position = pixel
	elif block is Control:
		(block as Control).position = pixel


# AIからの操作を受け入れ、指定X座標へ移動後に即座に物理落下を開始する
func execute_ai_drop(target_x: float) -> void:
	if _is_locked or _is_input_paused:
		return

	# プレイヤーの操作権限を剥奪
	_is_input_paused = true

	# 指定されたX座標へ瞬時に移動（Y座標は現在の生成位置を維持）
	global_position.x = target_x

	# 即座に盤面へ固定（物理演算の有効化と自由落下処理）へ移行
	_lock_to_board()
