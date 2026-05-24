extends Node2D
class_name Board

signal resolve_started
signal resolve_finished

const WIDTH := 10
const HEIGHT := 20
const CELL_SIZE := 32

@export var effect_manager_path: NodePath = NodePath("../EffectManager")
@export var tonton_drop_speed: float = 0.02
@export var tonton_drop_distance: int = 20

var grid: Array[Array] = []
var effect_manager: EffectManager
var _is_resolving: bool = false
var _resolve_requested: bool = false


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

	if tween_duration <= 0.0:
		for target in drop_targets:
			var block: Node = target["block"] as Node
			if not is_instance_valid(block):
				continue
			_set_block_position(block, target["target_pixel"] as Vector2)
		return

	var tween := create_tween()
	tween.set_parallel(true)
	for target in drop_targets:
		var block: Node = target["block"] as Node
		if not is_instance_valid(block):
			continue
		var duration: float = tonton_drop_speed * float(target["drop_cells"] as int)
		var target_pixel: Vector2 = target["target_pixel"] as Vector2
		tween.tween_property(block, "position", target_pixel, duration)

	await tween.finished

	for target in drop_targets:
		var block: Node = target["block"] as Node
		if not is_instance_valid(block):
			continue
		_set_block_position(block, target["target_pixel"] as Vector2)

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


func remove_line(y: int) -> void:
	if y < 0 or y >= HEIGHT:
		return
	for x in range(WIDTH):
		var block: Node = grid[y][x] as Node
		grid[y][x] = null

		if block == null:
			continue
		if not is_instance_valid(block):
			continue
		var effect_block := _create_line_clear_dummy(block)
		block.queue_free()
		if effect_manager != null and is_instance_valid(effect_manager):
			effect_manager.enqueue_line_clear(effect_block)
		elif is_instance_valid(effect_block):
			effect_block.queue_free()


func apply_gravity() -> bool:
	var moved := false
	for y in range(HEIGHT - 2, -1, -1):
		for x in range(WIDTH):
			var block: Node = grid[y][x] as Node
			if block == null:
				continue
			if not is_instance_valid(block):
				grid[y][x] = null
				continue

			var below: Node = grid[y + 1][x] as Node
			if below != null and not is_instance_valid(below):
				grid[y + 1][x] = null
				below = null
			if below != null:
				continue

			grid[y + 1][x] = block
			grid[y][x] = null
			_move_block_down_by_one_cell(block)
			moved = true
	return moved


func resolve_lines() -> void:
	if _is_resolving:
		_resolve_requested = true
		await resolve_finished
		return

	_is_resolving = true
	resolve_started.emit()

	while true:
		_resolve_requested = false
		_sanitize_invalid_blocks()

		var full_rows: Array[int] = _find_full_rows()
		if full_rows.is_empty():
			if _resolve_requested:
				continue
			break

		for row in full_rows:
			remove_line(row)
		if effect_manager != null and is_instance_valid(effect_manager):
			await effect_manager.flush_line_clear_queue()

		_sanitize_invalid_blocks()
		while apply_gravity():
			_sanitize_invalid_blocks()

	_is_resolving = false
	resolve_finished.emit()


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


func _collect_tonton_drop_targets() -> Array[Dictionary]:
	var targets: Array[Dictionary] = []
	var next_grid: Array[Array] = _build_empty_grid()
	var max_drop_distance: int = max(tonton_drop_distance, 0)

	for x in range(WIDTH):
		var write_y := HEIGHT - 1
		for y in range(HEIGHT - 1, -1, -1):
			var block: Node = grid[y][x] as Node
			if block == null:
				continue
			if not is_instance_valid(block):
				continue

			var target_y: int = min(write_y, y + max_drop_distance)
			next_grid[target_y][x] = block
			if target_y > y:
				targets.append({
					"block": block,
					"drop_cells": target_y - y,
					"target_pixel": grid_to_pixel(x, target_y),
				})
			write_y = target_y - 1

	grid = next_grid
	return targets


func _create_line_clear_dummy(source_block: Node) -> Node:
	var dummy := ColorRect.new()
	dummy.name = "LineClearDummy"
	dummy.size = Vector2(CELL_SIZE, CELL_SIZE)
	dummy.color = Color.WHITE

	if source_block is ColorRect:
		var source_rect: ColorRect = source_block as ColorRect
		dummy.size = source_rect.size
		dummy.color = source_rect.color

	var source_position := Vector2.ZERO
	if source_block is Node2D:
		source_position = (source_block as Node2D).position
	elif source_block is Control:
		source_position = (source_block as Control).position

	dummy.position = source_position
	add_child(dummy)
	return dummy

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
