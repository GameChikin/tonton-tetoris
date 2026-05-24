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

var grid: Array[Array] = []
var effect_manager: EffectManager
var score_manager: Node
var _is_resolving: bool = false
var _resolve_requested: bool = false


func _ready() -> void:
	_initialize_grid()
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	if effect_manager == null:
		effect_manager = get_parent().get_node_or_null("EffectManager") as EffectManager
	score_manager = get_node_or_null(score_manager_path)


func _initialize_grid() -> void:
	grid = _build_empty_grid()


func _build_empty_grid() -> Array[Array]:
	var next_grid: Array[Array] = []
	for y in range(HEIGHT):
		var row: Array = []
		row.resize(WIDTH)
		for x in range(WIDTH):
			row[x] = null
		next_grid.append(row)
	return next_grid


func grid_to_pixel(cell_x: int, cell_y: int) -> Vector2:
	return Vector2(cell_x * CELL_SIZE, cell_y * CELL_SIZE)


func pixel_to_grid(pixel: Vector2) -> Vector2i:
	return Vector2i(int(pixel.x / CELL_SIZE), int(pixel.y / CELL_SIZE))


func is_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < WIDTH and cell.y >= 0 and cell.y < HEIGHT


func is_cell_empty(cell: Vector2i) -> bool:
	if not is_inside(cell):
		return false
	var value: Variant = grid[cell.y][cell.x]
	return value == null or not is_instance_valid(value)


func lock_blocks(blocks: Array[Node], cells: Array[Vector2i]) -> void:
	for i in range(min(blocks.size(), cells.size())):
		var block: Node = blocks[i]
		var cell: Vector2i = cells[i]
		if not is_inside(cell):
			continue
		if not is_instance_valid(block):
			continue

		_set_block_position(block, grid_to_pixel(cell.x, cell.y))
		grid[cell.y][cell.x] = block


func apply_tonton_drop():
	_sanitize_invalid_blocks()
	var drop_targets: Array[Dictionary] = _collect_tonton_drop_targets()
	if drop_targets.is_empty():
		return

	var tween_duration: float = 0.0
	for target in drop_targets:
		var drop_cells: int = target["drop_cells"] as int
		tween_duration = max(tween_duration, tonton_drop_speed * float(drop_cells))

	if tween_duration > 0.0:
		var tween := create_tween()
		tween.set_parallel(true)
		for target in drop_targets:
			var block: Node = target["block"] as Node
			if not is_instance_valid(block):
				continue
			var drop_cells: int = target["drop_cells"] as int
			if drop_cells <= 0:
				continue
			var duration: float = tonton_drop_speed * float(drop_cells)
			var target_pixel: Vector2 = target["target_pixel"] as Vector2
			tween.tween_property(block, "position", target_pixel, duration)

		await tween.finished
	else:
		for target in drop_targets:
			var block: Node = target["block"] as Node
			if not is_instance_valid(block):
				continue
			_set_block_position(block, target["target_pixel"] as Vector2)

	var next_grid := _build_empty_grid()
	for target in drop_targets:
		var block: Node = target["block"] as Node
		if not is_instance_valid(block):
			continue
		var x: int = target["x"] as int
		var target_y: int = target["target_y"] as int
		_set_block_position(block, target["target_pixel"] as Vector2)
		next_grid[target_y][x] = block
		
		# --- 追加: 描画プロパティの強制リセット ---
		if block is CanvasItem:
			block.visible = true
			block.modulate.a = 1.0

	grid = next_grid
	_sanitize_invalid_blocks()


func is_line_full(y: int) -> bool:
	if y < 0 or y >= HEIGHT:
		return false
	for x in range(WIDTH):
		var block: Variant = grid[y][x]
		if block == null:
			return false
		if not is_instance_valid(block):
			return false
	return true


func apply_tetris_gravity(full_rows: Array[int]) -> void:
	if full_rows.is_empty():
		return

	var next_grid := _build_empty_grid()
	var write_y := HEIGHT - 1

	# 下の行から上に向かって走査
	for y in range(HEIGHT - 1, -1, -1):
		# この行が消去された行リストに含まれている場合は、データ読み込みをスキップ（行を詰める）
		if y in full_rows:
			continue

		for x in range(WIDTH):
			var block: Node = grid[y][x] as Node
			if block != null and is_instance_valid(block):
				next_grid[write_y][x] = block
				# 移動先と元の行に差分がある場合、見た目のY座標をまとめてスライドダウン
				if write_y != y:
					var dy := write_y - y
					if block is Node2D:
						block.position.y += dy * CELL_SIZE
					elif block is Control:
						block.position.y += dy * CELL_SIZE
		write_y -= 1

	grid = next_grid


func resolve_lines() -> void:
	if _is_resolving:
		_resolve_requested = true
		await resolve_finished
		return

	_is_resolving = true
	resolve_started.emit()

	# 連続消去（テトリスでの全消しや、ぷよルールでの連鎖）を処理するためのメインループ
	while true:
		_resolve_requested = false
		_sanitize_invalid_blocks()

		var blocks_to_clear: Array[Node] = []
		var lowest_y: int = -1
		var match_count: int = 0

		# 【判定フェーズ】現在のルールに応じて消去対象の検索のみを切り替え
		if current_rule == GameRule.TETRIS:
			var full_rows: Array[int] = _find_full_rows()
			match_count = full_rows.size()
			if not full_rows.is_empty():
				for row in full_rows:
					lowest_y = max(lowest_y, row)
					for x in range(WIDTH):
						var block: Node = grid[row][x] as Node
						grid[row][x] = null
						if block != null and is_instance_valid(block):
							blocks_to_clear.append(block)
		else:
			# ぷよぷよルール：同色4つ以上マッチ
			var puyo_matches: Array[Node] = _find_puyo_matches()
			match_count = 1 if not puyo_matches.is_empty() else 0
			if not puyo_matches.is_empty():
				for block in puyo_matches:
					if block != null and is_instance_valid(block):
						blocks_to_clear.append(block)
						var b_pos := pixel_to_grid(block.position if "position" in block else Vector2.ZERO)
						lowest_y = max(lowest_y, b_pos.y)
						if b_pos.y >= 0 and b_pos.y < HEIGHT and b_pos.x >= 0 and b_pos.x < WIDTH:
							grid[b_pos.y][b_pos.x] = null

		# 消去対象が何もなければ、ルール解決ループを終了
		if blocks_to_clear.is_empty():
			if _resolve_requested:
				continue
			break

		# 【共通演出フェーズ】
		# 1. 点滅演出
		if effect_manager != null and effect_manager.has_method("play_line_blink"):
			await effect_manager.play_line_blink(blocks_to_clear)
		
		# 2. スコア加算とポップアップ
		if score_manager != null and score_manager.has_method("add_score_for_lines"):
			var target_y = lowest_y if lowest_y != -1 else int(HEIGHT / 2.0)
			var popup_pos := grid_to_pixel(int(WIDTH / 2.0), target_y)
			score_manager.call("add_score_for_lines", match_count, popup_pos)
		
		# 3. フラッシュと左からの消去フェードアウト
		if effect_manager != null and effect_manager.has_method("play_line_vanish_and_flash"):
			await effect_manager.play_line_vanish_and_flash(blocks_to_clear)
		
		# 4. 全演出完了後に安全に実体を破棄
		for block in blocks_to_clear:
			if is_instance_valid(block):
				block.queue_free()

		# 【重力フェーズ】ルールに関わらず、常にテトリス型（形状・空洞維持の一括行シフト）を適用
		_sanitize_invalid_blocks()
		
		var empty_rows: Array[int] = []
		for y in range(HEIGHT):
			var is_empty_row := true
			for x in range(WIDTH):
				if grid[y][x] != null:
					is_empty_row = false
					break
			if is_empty_row:
				var has_block_above := false
				for ay in range(0, y):
					for ax in range(WIDTH):
						if grid[ay][ax] != null:
							has_block_above = true
							break
				if has_block_above:
					empty_rows.append(y)
					
		apply_tetris_gravity(empty_rows)
		_sanitize_invalid_blocks()

	_is_resolving = false
	resolve_finished.emit()


func force_set_grid_from_data(preset_matrix: Array) -> void:
	_clear_all_grid_blocks()
	grid = _build_empty_grid()

	if preset_matrix.is_empty():
		return

	# Tetrominoの形状キーのリストを取得（ランダム選択用）
	var shape_keys: Array = Tetromino.SHAPE_KEYS
	var tetromino_data: Dictionary = Tetromino.TETROMINO_DATA

	for y in range(min(HEIGHT, preset_matrix.size())):
		var row_data: Variant = preset_matrix[y]
		if not (row_data is Array):
			continue

		var row: Array = row_data as Array
		for x in range(min(WIDTH, row.size())):
			if not _is_filled_preset_cell(row[x]):
				continue

			var block: Node = _instantiate_block()
			if block == null:
				continue

			# 形状キーからランダムに1つ選んで、色と論理IDを決定する
			var random_key: String = shape_keys[randi() % shape_keys.size()] as String
			var chosen_color: Color = Color.WHITE
			
			if tetromino_data.has(random_key):
				var shape_def: Dictionary = tetromino_data[random_key] as Dictionary
				chosen_color = shape_def.get("color", Color.WHITE) as Color

			if block is ColorRect:
				block.color = chosen_color
			if block is CanvasItem:
				block.visible = true
				block.modulate.a = 1.0

			# ランダムに選ばれた形状キー（"I", "O", "T" など）をメタデータとして正確に付与
			block.set_meta("color_id", random_key)

			add_child(block)
			_set_block_position(block, grid_to_pixel(x, y))
			grid[y][x] = block


func _find_full_rows() -> Array[int]:
	var rows: Array[int] = []
	for y in range(HEIGHT - 1, -1, -1):
		if is_line_full(y):
			rows.append(y)
	return rows


func _sanitize_invalid_blocks() -> void:
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var block: Variant = grid[y][x]
			if block != null and not is_instance_valid(block):
				grid[y][x] = null


func _clear_all_grid_blocks() -> void:
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var block: Node = grid[y][x] as Node
			grid[y][x] = null # 参照エラーを防ぐためノード破棄の前に必ずnull化

			if block == null:
				continue
			if not is_instance_valid(block):
				continue
			block.queue_free()


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
	var targets: Array[Dictionary] = []
	var grid_snapshot: Array[Array] = _build_empty_grid()
	for y in range(HEIGHT):
		for x in range(WIDTH):
			grid_snapshot[y][x] = grid[y][x]

	var placement_scratch: Array[Array] = _build_empty_grid()
	var max_drop_distance: int = max(tonton_drop_distance, 0)

	for x in range(WIDTH):
		var write_y := HEIGHT - 1
		for y in range(HEIGHT - 1, -1, -1):
			var block: Node = grid_snapshot[y][x] as Node
			if block == null:
				continue
			if not is_instance_valid(block):
				continue

			var target_y: int = min(write_y, y + max_drop_distance)
			placement_scratch[target_y][x] = block
			targets.append({
				"block": block,
				"x": x,
				"target_y": target_y,
				"drop_cells": target_y - y,
				"target_pixel": grid_to_pixel(x, target_y),
			})
			write_y = target_y - 1

	return targets


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
	var moved := false
	for y in range(HEIGHT - 2, -1, -1):
		for x in range(WIDTH):
			var block: Node = grid[y][x] as Node
			if block == null or not is_instance_valid(block):
				continue

			var below: Node = grid[y + 1][x] as Node
			if below != null and not is_instance_valid(below):
				grid[y + 1][x] = null
				below = null
			
			if below == null:
				grid[y + 1][x] = block
				grid[y][x] = null
				if block is Node2D:
					block.position.y += CELL_SIZE
				elif block is Control:
					block.position.y += CELL_SIZE
				moved = true
	return moved


# ぷよぷよ用：上下左右に同色が4つ以上繋がっているブロック群を検索
func _find_puyo_matches() -> Array[Node]:
	var matched_blocks: Array[Node] = []
	var visited: Array[Array] = []
	for y in range(HEIGHT):
		var row: Array[bool] = []
		row.resize(WIDTH)
		row.fill(false)
		visited.append(row)

	var directions := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

	for y in range(HEIGHT):
		for x in range(WIDTH):
			if visited[y][x]:
				continue
				
			var block: Node = grid[y][x] as Node
			if block == null or not is_instance_valid(block):
				continue

			var color_id: String = block.get_meta("color_id", "")
			if color_id == "" or color_id == "PRESET":
				visited[y][x] = true
				continue

			# 幅優先探索 (BFS) で同色ブロックのグループを検出
			var group: Array[Node] = []
			var queue: Array[Vector2i] = [Vector2i(x, y)]
			visited[y][x] = true

			var head := 0
			while head < queue.size():
				var curr := queue[head]
				head += 1
				var curr_block: Node = grid[curr.y][curr.x] as Node
				if curr_block != null and is_instance_valid(curr_block):
					group.append(curr_block)

				for d: Vector2i in directions:
					var nx := curr.x + d.x
					var ny := curr.y + d.y
					if nx >= 0 and nx < WIDTH and ny >= 0 and ny < HEIGHT:
						if not visited[ny][nx]:
							var n_block: Node = grid[ny][nx] as Node
							if n_block != null and is_instance_valid(n_block):
								if n_block.get_meta("color_id", "") == color_id:
									visited[ny][nx] = true
									queue.append(Vector2i(nx, ny))

			# グループが4つ以上繋がっていれば消去対象に追加
			if group.size() >= 4:
				matched_blocks.append_array(group)

	return matched_blocks
