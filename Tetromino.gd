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

# 一元管理された設定リソースを読み込み
var settings: GameSettings = preload("res://game_settings.tres")

var board: Board
var blocks: Array[Node] = []
var local_cells: Array[Vector2i] = []
var pivot := Vector2i.ZERO
var current_color := Color.WHITE
var current_shape_key := "I"

var effect_manager: EffectManager:
	get:
		return board.effect_manager if is_instance_valid(board) else null

var _fall_timer := 0.0
var _still_timer: float = 0.0
var _is_locked := false
var _is_input_paused := false
var _is_dragging_by_player: bool = false
var _player_drag_offset: Vector2 = Vector2.ZERO
var _original_collision_mask: int = 0
var disable_auto_spawn: bool = false
var _drag_anchor: StaticBody2D
var _drag_joint: PinJoint2D
var _has_snapped_this_drag: bool = false
var _is_chain_locked: bool = false
var _is_docking_animating: bool = false


func _ready() -> void:
	board = get_node_or_null(board_path) as Board
	pivot = initial_pivot
	
	# 子ノード（ブロック）の削除を検知して自動分離をトリガーする
	child_exiting_tree.connect(_on_child_exiting_tree)
	
	# 元の衝突マスクを記憶（後で復元するため）
	_original_collision_mask = collision_mask
	
	# 外部から分離用として生成された場合は、ランダムな4ブロックの自動生成をスキップする
	if not disable_auto_spawn:
		_select_shape_data()
		_spawn_blocks()
		_sync_block_positions()


# 自身がクリックされたか判定（ロック中は無視）
func is_clicked(mouse_pos: Vector2) -> bool:
	if _is_chain_locked or _is_docking_animating: return false
	for block in get_children():
		if block is CollisionShape2D:
			if block.global_position.distance_to(mouse_pos) < 24.0:
				return true
	return false


# ドラッグ開始（Boardからも呼ばれる）
func start_drag(mouse_pos: Vector2) -> void:
	if _is_chain_locked or _is_docking_animating: return
	_is_dragging_by_player = true
	_has_snapped_this_drag = false
	
	# ポーズ中（連鎖待機中）でも物理演算と入力を受け付けるように局所的に覚醒させる
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	_drag_anchor = StaticBody2D.new()
	_drag_anchor.global_position = mouse_pos
	get_parent().add_child(_drag_anchor)
	
	_drag_joint = PinJoint2D.new()
	_drag_anchor.add_child(_drag_joint)
	_drag_joint.global_position = mouse_pos
	_drag_joint.node_a = _drag_joint.get_path_to(_drag_anchor)
	_drag_joint.node_b = _drag_joint.get_path_to(self)
	
	freeze = false
	collision_mask = 0


# ドラッグ解除（強制リリース時にも呼ばれる）
func release_drag() -> void:
	_is_dragging_by_player = false
	collision_mask = _original_collision_mask
	if is_instance_valid(_drag_anchor):
		_drag_anchor.queue_free()
	
	# 手を離した瞬間にプレビューを消去し、Boardに対してドッキング判定をリクエストする
	if is_instance_valid(board):
		if board.has_method("clear_docking_preview"):
			board.clear_docking_preview()
			
		if board.has_method("request_docking"):
			if board.request_docking(self):
				return
			
	# ドッキングしなかった場合、ゲーム全体がポーズ中であれば再び時間を止める（凍結）
	if get_tree().paused:
		process_mode = Node.PROCESS_MODE_INHERIT


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 通常時（非ポーズ時）のクリック検知
			if not get_tree().paused and _is_locked and is_clicked(get_global_mouse_position()):
				start_drag(get_global_mouse_position())
				get_viewport().set_input_as_handled()
		else:
			if _is_dragging_by_player:
				release_drag()


func _physics_process(delta: float) -> void:
	# アニメーション中は物理補正やドラッグ判定を完全に停止する
	if _is_docking_animating:
		return
		
	if _is_locked:
		# プレイヤーがドラッグ中の場合、ジョイントのアンカーをマウス座標へ追従させる
		if _is_dragging_by_player:
			if is_instance_valid(_drag_anchor):
				_drag_anchor.global_position = get_global_mouse_position()
			
			# ドラッグ中は常にプレビューの更新と、リアルタイムの吸着判定を要求する
			if is_instance_valid(board):
				if board.has_method("update_docking_preview"):
					board.update_docking_preview(self)
				
				# 自動吸着の実行（近づいたら自動で手が離れ、結合する）
				if board.has_method("request_docking"):
					if board.request_docking(self):
						# メモリリーク防止：結合成功時、自身が消滅する前にアンカーを安全に破棄する
						_is_dragging_by_player = false
						collision_mask = _original_collision_mask
						
						if is_instance_valid(_drag_anchor):
							_drag_anchor.queue_free()
							
						# 描画済みのプレビュー枠を確実に消去
						if board.has_method("clear_docking_preview"):
							board.clear_docking_preview()
							
						if get_tree().paused:
							process_mode = Node.PROCESS_MODE_INHERIT
							
						return # 以降の処理を遮断し、安全に消滅を待つ
				
			return # ドラッグ中は以下の磁力補正などはスキップ

		# --- 磁力（スナップ）補正 ---
		# 回転（Rotation）補正：最も近い90度の倍数に引き寄せる
		var current_deg = rad_to_deg(rotation)
		var target_deg = round(current_deg / 90.0) * 90.0
		var angle_diff = target_deg - current_deg
		
		# 指定された角度以内に近づいた場合のみ、角速度(Angular Velocity)に介入して姿勢を戻す
		if abs(angle_diff) <= settings.snap_rotation_limit and abs(angle_diff) > 0.1:
			var target_ang_vel = deg_to_rad(angle_diff) * settings.snap_rotation_strength
			angular_velocity = lerp(angular_velocity, target_ang_vel, delta * 15.0)
			
		# X座標（Position）補正：最も近い32px(CELL_SIZE)のグリッドに引き寄せる
		var cell_size = 32.0
		var target_x = round(global_position.x / cell_size) * cell_size
		var x_diff = target_x - global_position.x
		
		# 指定されたピクセル以内に近づいた場合のみ、横方向の速度(Linear Velocity X)に介入して引き寄せる
		if abs(x_diff) <= settings.snap_x_limit and abs(x_diff) > 0.5:
			var target_vx = x_diff * settings.snap_x_strength
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
	# 以前の「ぷよルール時に強制的に縦2マスにする」分岐処理は撤廃しました。
	# 常にテトリス形状（4ブロック）ベースで構築します。
	
	var key := shape_id
	if key == "RANDOM" or not TETROMINO_DATA.has(key):
		# 形状の候補を I, O, S に限定
		var allowed_shapes: Array[String] = ["I", "O", "S"]
		key = allowed_shapes[randi() % allowed_shapes.size()]
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

	# ルール設定（Tetris/Puyo）に関わらず、常に各ブロック個別の色配列を生成する
	# （_generate_puyo_colorsは、4ブロック形状でも「最低1組は同色隣接」を満たすよう機能します）
	var puyo_colors: Array[String] = _generate_puyo_colors()

	for _i in range(local_cells.size()):
		var block: Node = block_scene.instantiate()
		add_child(block)
		
		var final_color := current_color
		var final_meta_id := current_shape_key

		# 生成された個別の色情報でブロックのメタデータと見た目を上書き
		if _i < puyo_colors.size():
			var key: String = puyo_colors[_i]
			if TETROMINO_DATA.has(key):
				var shape_def: Dictionary = TETROMINO_DATA[key] as Dictionary
				final_color = shape_def.get("color", Color.WHITE) as Color
				final_meta_id = key

		_apply_block_color(block, final_color)
		block.set_meta("color_id", final_meta_id)
		blocks.append(block)


func _generate_puyo_colors() -> Array[String]:
	var colors: Array[String] = []
	var size: int = local_cells.size()
	
	# 【安全性・仕様確保】サイズが2以下（正規のぷよ形状）の場合は、
	# 同色強制（リジェクションサンプリング）をバイパスし、完全に独立したランダムな色のペアを返す
	if size <= 2:
		for i in range(size):
			colors.append(SHAPE_KEYS[randi() % SHAPE_KEYS.size()])
		return colors

	var adjacency: Array = []
	for i in range(size):
		var adj = []
		for j in range(size):
			if i != j:
				var dist = abs(local_cells[i].x - local_cells[j].x) + abs(local_cells[i].y - local_cells[j].y)
				if dist == 1:
					adj.append(j)
		adjacency.append(adj)

	# 物理的に隣接するペアが最低1組は同色になるまでリジェクションサンプリング
	while true:
		colors.clear()
		for i in range(size):
			colors.append(SHAPE_KEYS[randi() % SHAPE_KEYS.size()])
			
		var has_adjacent_same_color = false
		for i in range(size):
			for j in adjacency[i]:
				if colors[i] == colors[j]:
					has_adjacent_same_color = true
					break
			if has_adjacent_same_color:
				break
				
		if has_adjacent_same_color:
			return colors
			
	return []


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


func _process_magnetic_snap() -> void:
	pass


func _check_and_steal_from(_other_tet: Tetromino, _dist: float, _snap_duration: float = 0.2) -> bool:
	return false


func _get_my_colors() -> Dictionary:
	var colors = {}
	for b in blocks:
		if is_instance_valid(b) and b.has_meta("color_id"):
			colors[b.get_meta("color_id")] = true
	return colors


# 実際のノード構造から、blocksとlocal_cellsの配列を正確に再構築（自己修復）する
func _rebuild_internal_arrays() -> void:
	blocks.clear()
	local_cells.clear()
	for child in get_children():
		if child is CollisionShape2D and not child.is_queued_for_deletion():
			blocks.append(child)
			# 現在のローカル座標からグリッドマス目を逆算して登録
			var cell = Vector2i(round(child.position.x / 32.0), round(child.position.y / 32.0)) - pivot
			local_cells.append(cell)
			
	# ガベージコレクション：ブロックをすべて失って空箱になった場合、自身を安全に破棄する
	if blocks.is_empty() and not is_queued_for_deletion():
		queue_free()


# ブロックが消去や奪取によって自身から離れる直前に呼ばれる
func _on_child_exiting_tree(node: Node) -> void:
	if node is CollisionShape2D and not is_queued_for_deletion():
		# 削除処理が完了し、ツリーから完全に外れた次のフレームで診断を実行
		call_deferred("_check_and_split_if_needed")


# 自身のブロック群が分断されていないかFlood Fillアルゴリズムで診断
func _check_and_split_if_needed() -> void:
	if is_queued_for_deletion(): return
	
	# 現在の実体から配列を最新化
	if has_method("_rebuild_internal_arrays"):
		_rebuild_internal_arrays()
		
	if local_cells.size() <= 1:
		return
		
	var unvisited = local_cells.duplicate()
	var groups = []
	var adjacent_offsets = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	
	# 繋がっているブロックの島（グループ）を探索
	while not unvisited.is_empty():
		var start_cell = unvisited.pop_front()
		var current_group = [start_cell]
		var queue = [start_cell]
		
		while not queue.is_empty():
			var cell = queue.pop_front()
			for offset in adjacent_offsets:
				var neighbor = cell + offset
				var idx = unvisited.find(neighbor)
				if idx != -1:
					unvisited.remove_at(idx)
					current_group.append(neighbor)
					queue.append(neighbor)
		groups.append(current_group)
		
	# グループが1つだけ（分断されていない）なら何もしない
	if groups.size() <= 1:
		return
		
	# 最大のグループを自身に残し、他の島を分離
	groups.sort_custom(func(a, b): return a.size() > b.size())
	
	for i in range(1, groups.size()):
		_detach_group(groups[i])


# 孤立したブロックグループを新しいテトリミノとして独立させる
func _detach_group(sub_group: Array) -> void:
	var tet_scene = load("res://Tetromino.tscn") as PackedScene
	if not tet_scene: return
	var new_tet = tet_scene.instantiate() as Tetromino
	
	# 以前追加した自動生成スキップフラグを有効化
	new_tet.disable_auto_spawn = true
	
	new_tet.global_position = global_position
	new_tet.rotation = rotation
	new_tet.set("_is_locked", true)
	new_tet.freeze = false # 分離後は物理落下を再開
	
	get_parent().add_child(new_tet)
	
	# 対象のブロックを自身から引き剥がし、新テトリミノへ移動
	var blocks_to_move = []
	for cell in sub_group:
		var idx = local_cells.find(cell)
		if idx != -1:
			blocks_to_move.append(blocks[idx])
			
	for block in blocks_to_move:
		remove_child(block)
		new_tet.add_child(block)
		
	# 両者の内部配列を正常化
	_rebuild_internal_arrays()
	if new_tet.has_method("_rebuild_internal_arrays"):
		new_tet._rebuild_internal_arrays()


# 毎フレーム描画を更新する（ブロックの移動や結合に追従）
func _process(_delta: float) -> void:
	queue_redraw()


# ブロックの境界線と塊の外周を描画する
func _draw() -> void:
	if blocks.is_empty() or local_cells.is_empty():
		return

	var cell_size = 32.0
	var half_size = cell_size / 2.0
	var thin_line_color = Color(1.0, 1.0, 1.0, 0.3) # 個別の細い線（半透明の白）
	var thick_line_color = Color(1.0, 1.0, 1.0, 0.9) # 塊の外周の太い線（はっきりした白）
	var thick_width = 3.0
	var thin_width = 1.0

	# 1. 各ブロックの細い境界線を描画
	for block in blocks:
		if is_instance_valid(block):
			var rect = Rect2(block.position - Vector2(half_size, half_size), Vector2(cell_size, cell_size))
			draw_rect(rect, thin_line_color, false, thin_width)

	# 2. 塊全体の外周（太い線）を描画（隣接マスがない辺のみ線を引く）
	var adjacent_edges = [
		{"dir": Vector2i(0, -1), "p1": Vector2(-half_size, -half_size), "p2": Vector2(half_size, -half_size)}, # 上辺
		{"dir": Vector2i(0, 1),  "p1": Vector2(-half_size, half_size),  "p2": Vector2(half_size, half_size)},  # 下辺
		{"dir": Vector2i(-1, 0), "p1": Vector2(-half_size, -half_size), "p2": Vector2(-half_size, half_size)}, # 左辺
		{"dir": Vector2i(1, 0),  "p1": Vector2(half_size, -half_size),  "p2": Vector2(half_size, half_size)}   # 右辺
	]

	for i in range(blocks.size()):
		var block = blocks[i]
		var cell = local_cells[i]
		if not is_instance_valid(block): continue

		for edge in adjacent_edges:
			var neighbor_cell = cell + edge["dir"]
			# 隣のマスに自身のブロックが存在しない場合のみ、その辺は「外周」となる
			if not local_cells.has(neighbor_cell):
				var p1 = block.position + edge["p1"]
				var p2 = block.position + edge["p2"]
				draw_line(p1, p2, thick_line_color, thick_width)
