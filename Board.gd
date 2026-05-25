extends Node2D
class_name Board

signal resolve_started
signal resolve_finished

const WIDTH := 10
const HEIGHT := 20
const CELL_SIZE := 32

enum GameRule { TETRIS, PUYO }
@export var current_rule: GameRule = GameRule.TETRIS
@export var effect_manager_path: NodePath = NodePath("../EffectManager")
@export var score_manager_path: NodePath = NodePath("../ScoreManager")
@export var block_scene: PackedScene = preload("res://Block.tscn")
@export var tonton_drop_speed: float = 0.02
@export var tonton_drop_distance: int = 20

@export_group("Physics Rule Settings")
@export var clear_threshold: int = 8
@export var line_clear_hold_time: float = 1.5
@export var board_width_px: float = 320.0

var effect_manager: EffectManager
var score_manager: Node
var _is_resolving: bool = false
var _line_timers: Dictionary = {}


func _ready() -> void:
	_initialize_grid()
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	if effect_manager == null:
		effect_manager = get_parent().get_node_or_null("EffectManager") as EffectManager
	score_manager = get_node_or_null(score_manager_path)


func _initialize_grid() -> void:
	pass


func _build_empty_grid() -> Array[Array]:
	return []


func grid_to_pixel(cell_x: int, cell_y: int) -> Vector2:
	return Vector2(cell_x * CELL_SIZE, cell_y * CELL_SIZE)


func pixel_to_grid(pixel: Vector2) -> Vector2i:
	return Vector2i(int(pixel.x / CELL_SIZE), int(pixel.y / CELL_SIZE))


func is_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < WIDTH and cell.y >= 0 and cell.y < HEIGHT


func is_cell_empty(_cell: Vector2i) -> bool:
	return true


func lock_blocks(_blocks: Array[Node], _cells: Array[Vector2i]) -> void:
	pass


func apply_tonton_drop() -> void:
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		return

	# 盤面内のすべてのTetromino（親RigidBody2D）のFreezeを解除
	for child in get_children():
		if child is Tetromino:
			child.freeze = false
			var random_impulse = Vector2(randf_range(-60, 60), randf_range(-20, 0))
			child.apply_central_impulse(random_impulse)

	# 物理枠をTweenでシェイク
	var tween = create_tween().set_loops(3)
	var original_pos = physics_frame.position
	var shake_offset_1 = original_pos + Vector2(randf_range(-6, 6), randf_range(4, 12))
	var shake_offset_2 = original_pos + Vector2(randf_range(-6, 6), randf_range(-4, -8))

	tween.tween_property(physics_frame, "position", shake_offset_1, 0.03)
	tween.tween_property(physics_frame, "position", shake_offset_2, 0.03)
	tween.tween_property(physics_frame, "position", original_pos, 0.02)


func is_line_full(_y: int) -> bool:
	return false


func apply_tetris_gravity(_full_rows: Array[int]) -> void:
	pass


func resolve_lines() -> void:
	pass


func force_set_grid_from_data(_preset_matrix: Array) -> void:
	pass


func _find_full_rows() -> Array[int]:
	var rows: Array[int] = []
	for y in range(HEIGHT - 1, -1, -1):
		if is_line_full(y):
			rows.append(y)
	return rows


func _sanitize_invalid_blocks() -> void:
	pass


func _clear_all_grid_blocks() -> void:
	pass


func _instantiate_block() -> Node:
	if block_scene == null:
		push_warning("Board: block_scene is not assigned.")
		return null
	var instance: Node = block_scene.instantiate()
	if instance == null:
		push_warning("Board: failed to instantiate block_scene.")
	return instance


func _is_filled_preset_cell(value: Variant) -> bool:
	if value is bool:
		return value as bool
	if value is int:
		return (value as int) != 0
	if value is float:
		return not is_zero_approx(value as float)
	if value is String:
		var marker := (value as String).strip_edges()
		return marker == "#" or marker == "1" or marker == "X" or marker == "x" or marker == "O" or marker == "o" or marker == "*" or marker == "@"
	return false


func _collect_tonton_drop_targets() -> Array[Dictionary]:
	return []


func _set_block_position(block: Node, pixel: Vector2) -> void:
	if not is_instance_valid(block):
		return

	if block is Node2D:
		(block as Node2D).position = pixel
	elif block is Control:
		(block as Control).position = pixel


func _move_block_down_by_one_cell(block: Node) -> void:
	if not is_instance_valid(block):
		return

	if block is Node2D:
		(block as Node2D).position.y += CELL_SIZE
	elif block is Control:
		(block as Control).position.y += CELL_SIZE


func _debug_collect_grid_block_info(target_grid: Array[Array]) -> Dictionary:
	var count: int = 0
	var coords: Array[String] = []
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var block: Variant = target_grid[y][x]
			if block == null:
				continue
			if not is_instance_valid(block):
				continue
			count += 1
			coords.append("(%d,%d)" % [x, y])
	return {"count": count, "coords": coords}


func _debug_print_grid_state(method_name: String, label: String, target_grid: Array[Array]) -> void:
	var info: Dictionary = _debug_collect_grid_block_info(target_grid)
	var coords_text: String = ", ".join(info["coords"])
	print(
		"Debug: [%s] %s block_count=%d coords=[%s]"
		% [method_name, label, info["count"], coords_text]
	 )


# ぷよぷよ用：空きマスを埋めるように個別に落下する重力
func apply_puyo_gravity() -> bool:
	return false


# ぷよぷよ用：上下左右に同色が4つ以上繋がっているブロック群を検索
func _find_puyo_matches() -> Array[Node]:
	return []


func _physics_process(delta: float) -> void:
	if _is_resolving:
		return

	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		return

	var blocks_by_row: Dictionary = {}
	var row_size = CELL_SIZE

	# ブロックの収集と枠内判定
	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					# ブロックの座標を物理枠のローカル座標に変換して枠内かチェック
					var local_pos = physics_frame.to_local(block.global_position)
					# 左右の壁の内側(0〜320)に存在するか（少しマージンを設ける）
					if local_pos.x >= -4.0 and local_pos.x <= board_width_px + 4.0:
						var row_idx = int(round(block.global_position.y / row_size))
						if not blocks_by_row.has(row_idx):
							blocks_by_row[row_idx] = []
						blocks_by_row[row_idx].append(block)

	var current_full_rows = []
	var lines_to_clear: Array[Node] = []
	var ready_to_clear = false

	# 揃っているラインのタイマー進行と色変更
	for row_idx in blocks_by_row.keys():
		var row_blocks = blocks_by_row[row_idx]
		if row_blocks.size() >= clear_threshold:
			current_full_rows.append(row_idx)
			if not _line_timers.has(row_idx):
				_line_timers[row_idx] = 0.0

			_line_timers[row_idx] += delta
			var progress = clampf(_line_timers[row_idx] / line_clear_hold_time, 0.0, 1.0)

			for block in row_blocks:
				if is_instance_valid(block):
					# 徐々に明るく、発光していく演出（値を1.0以上にすることで白く輝く）
					var glow = progress * 2.5
					block.modulate = Color(1.0 + glow, 1.0 + glow, 1.0 + glow, 1.0)

			if _line_timers[row_idx] >= line_clear_hold_time:
				ready_to_clear = true
				lines_to_clear.append_array(row_blocks)

	# 崩れてラインから外れた行のタイマーをリセット
	var to_erase = []
	for row_idx in _line_timers.keys():
		if not current_full_rows.has(row_idx):
			to_erase.append(row_idx)
	for row_idx in to_erase:
		_line_timers.erase(row_idx)

	# 状態がリセットされたブロックの色を戻す
	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					var row_idx = int(round(block.global_position.y / row_size))
					if not current_full_rows.has(row_idx):
						block.modulate = Color.WHITE

	# 判定時間を越えたら消去実行
	if ready_to_clear:
		_line_timers.clear()
		_is_resolving = true
		_do_line_clear(lines_to_clear)


func _do_line_clear(lines_to_clear: Array[Node]) -> void:
	for block in lines_to_clear:
		if is_instance_valid(block):
			block.set_deferred("disabled", true)
			block.modulate = Color.WHITE # エフェクト用に色を戻す

	if is_instance_valid(effect_manager):
		await effect_manager.play_line_vanish_and_flash(lines_to_clear)
	else:
		await get_tree().create_timer(0.3).timeout

	var affected_tetrominos: Dictionary = {}
	for block in lines_to_clear:
		if is_instance_valid(block):
			var parent = block.get_parent()
			if is_instance_valid(parent) and parent is Tetromino:
				affected_tetrominos[parent] = true
			block.queue_free()

	await get_tree().process_frame
	for tet in affected_tetrominos:
		if is_instance_valid(tet) and tet.get_child_count() == 0:
			tet.queue_free()

	_is_resolving = false
