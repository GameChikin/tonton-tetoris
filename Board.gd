extends Node2D
class_name Board

const WIDTH := 10
const HEIGHT := 20
const CELL_SIZE := 32

@export var effect_manager_path: NodePath = NodePath("../EffectManager")

var grid: Array[Array] = []
var effect_manager: EffectManager


func _ready() -> void:
	_initialize_grid()
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	if effect_manager == null:
		effect_manager = get_parent().get_node_or_null("EffectManager") as EffectManager


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
	return grid[cell.y][cell.x] == null


func lock_blocks(blocks: Array[Node], cells: Array[Vector2i]) -> void:
	for i in range(min(blocks.size(), cells.size())):
		var block: Node = blocks[i]
		var cell: Vector2i = cells[i]
		if not is_inside(cell):
			continue

		_set_block_position(block, grid_to_pixel(cell.x, cell.y))
		grid[cell.y][cell.x] = block


func apply_tonton_drop() -> bool:
	return apply_gravity()


func is_line_full(y: int) -> bool:
	if y < 0 or y >= HEIGHT:
		return false
	for x in range(WIDTH):
		if grid[y][x] == null:
			return false
	return true


func remove_line(y: int) -> void:
	if y < 0 or y >= HEIGHT:
		return
	for x in range(WIDTH):
		var block: Node = grid[y][x]
		if block != null and effect_manager != null:
			effect_manager.enqueue_line_clear(block)
		grid[y][x] = null


func apply_gravity() -> bool:
	var moved := false
	for y in range(HEIGHT - 2, -1, -1):
		for x in range(WIDTH):
			var block: Node = grid[y][x]
			if block == null:
				continue
			if grid[y + 1][x] != null:
				continue

			grid[y + 1][x] = block
			grid[y][x] = null
			_move_block_down_by_one_cell(block)
			moved = true
	return moved


func resolve_lines() -> void:
	while true:
		var full_rows: Array[int] = _find_full_rows()
		if full_rows.is_empty():
			break

		for row in full_rows:
			remove_line(row)
		if effect_manager != null:
			await effect_manager.flush_line_clear_queue()

		while apply_gravity():
			pass


func _find_full_rows() -> Array[int]:
	var rows: Array[int] = []
	for y in range(HEIGHT - 1, -1, -1):
		if is_line_full(y):
			rows.append(y)
	return rows

func _set_block_position(block: Node, pixel: Vector2) -> void:
	if block is Node2D:
		(block as Node2D).position = pixel
	elif block is Control:
		(block as Control).position = pixel


func _move_block_down_by_one_cell(block: Node) -> void:
	if block is Node2D:
		(block as Node2D).position.y += CELL_SIZE
	elif block is Control:
		(block as Control).position.y += CELL_SIZE
