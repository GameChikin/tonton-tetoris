extends Node2D
class_name Board

signal resolve_started
signal resolve_finished

const WIDTH := 10
const HEIGHT := 20
const CELL_SIZE := 32

enum GameRule { TETRIS, PUYO }
@export var effect_manager_path: NodePath = NodePath("../EffectManager")
@export var score_manager_path: NodePath = NodePath("../ScoreManager")
@export var block_scene: PackedScene = preload("res://Block.tscn")

@export_group("Docking Settings")
@export var docking_distance_threshold: float = 38.0 # 吸着判定を行う直線距離
@export var require_same_color: bool = true # 同色ブロックとしか結合できないようにするか
@export var show_debug_docking: bool = false # 判定エリアと拒否理由を画面に描画するか

var settings: GameSettings = preload("res://game_settings.tres")

var effect_manager: EffectManager
var score_manager: Node
var _is_resolving: bool = false
var _line_timers: Dictionary = {}
var _auto_dock_timer: float = 0.0


func _ready() -> void:
	# Board自体は時間停止中も入力を監視するために常に動作させる
	process_mode = Node.PROCESS_MODE_ALWAYS
	_initialize_grid()
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	if effect_manager == null:
		effect_manager = get_parent().get_node_or_null("EffectManager") as EffectManager
	score_manager = get_node_or_null(score_manager_path)


# ポーズ中（連鎖インターバル中）のプレイヤー介入（アクティブ連鎖）を検知する
func _input(event: InputEvent) -> void:
	if get_tree().paused and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var mouse_pos = get_global_mouse_position()
		for child in get_children():
			if child is Tetromino and child.has_method("is_clicked"):
				if child.is_clicked(mouse_pos):
					child.start_drag(mouse_pos)
					get_viewport().set_input_as_handled()
					break


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

	# 1. 物理枠をTweenでシェイク（打撃感の演出）
	var tween = create_tween().set_loops(3)
	var original_pos = physics_frame.position
	var shake_offset_1 = original_pos + Vector2(randf_range(-6, 6), randf_range(4, 12))
	var shake_offset_2 = original_pos + Vector2(randf_range(-6, 6), randf_range(-4, -8))

	tween.tween_property(physics_frame, "position", shake_offset_1, 0.03)
	tween.tween_property(physics_frame, "position", shake_offset_2, 0.03)
	tween.tween_property(physics_frame, "position", original_pos, 0.02)

	# 2. すべてのテトリミノを物理演算から切り離し（Freeze）、Y座標の降順（下にある順）にソート
	var tetrominos: Array[Node] = []
	for child in get_children():
		if child is Tetromino and child.get("_is_locked"):
			child.freeze = true
			tetrominos.append(child)

	tetrominos.sort_custom(func(a, b): return a.global_position.y > b.global_position.y)

	# 3. 仮想グリッドによる重ならない目標位置の計算
	var frame_origin = physics_frame.global_position
	var occupied_cells: Dictionary = {}
	var snap_tween = create_tween().set_parallel(true)

	for tet in tetrominos:
		var current_deg = rad_to_deg(tet.rotation)
		var target_deg = round(current_deg / 90.0) * 90.0
		var target_rad = deg_to_rad(target_deg)

		var local_pos = tet.global_position - frame_origin
		var grid_x = round(local_pos.x / CELL_SIZE)
		var grid_y = round(local_pos.y / CELL_SIZE)

		var valid_position_found = false
		var target_global_pos = Vector2.ZERO
		var x_offset = 0

		# 衝突しない安全な配置座標を探索
		while not valid_position_found and grid_y >= -5:
			valid_position_found = true
			target_global_pos = frame_origin + Vector2((grid_x + x_offset) * CELL_SIZE, grid_y * CELL_SIZE)

			var out_of_left = false
			var out_of_right = false

			for block in tet.get_children():
				if block is CollisionShape2D:
					var block_offset = block.position.rotated(target_rad)
					var b_local = (target_global_pos + block_offset) - frame_origin
					var bx = round(b_local.x / CELL_SIZE)
					var by = round(b_local.y / CELL_SIZE)

					if bx < 0: out_of_left = true
					if bx >= WIDTH: out_of_right = true
					if by >= HEIGHT or occupied_cells.has(Vector2i(bx, by)):
						valid_position_found = false

			if out_of_left:
				x_offset += 1
				valid_position_found = false
			elif out_of_right:
				x_offset -= 1
				valid_position_found = false
			elif not valid_position_found:
				# 床や他のブロックに被った場合は1段上へ
				grid_y -= 1
				x_offset = 0 # 横ズレはリセット

		# 確定した位置を仮想グリッドに登録
		for block in tet.get_children():
			if block is CollisionShape2D:
				var block_offset = block.position.rotated(target_rad)
				var b_local = (target_global_pos + block_offset) - frame_origin
				var bx = round(b_local.x / CELL_SIZE)
				var by = round(b_local.y / CELL_SIZE)
				occupied_cells[Vector2i(bx, by)] = true

		# Tweenでシュッと吸い込まれるように移動
		snap_tween.tween_property(tet, "global_position", target_global_pos, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		snap_tween.tween_property(tet, "rotation", target_rad, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# 4. 移動完了後、物理演算を再開（パズル的緊張感の維持）
	snap_tween.chain().tween_callback(func():
		for tet in tetrominos:
			if is_instance_valid(tet):
				tet.freeze = false
	)


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
	# 毎フレーム、物理演算の前に画面外のゴミ掃除を実行する
	_cleanup_out_of_bounds()
	
	# 【ステップ3】低頻度自動ドッキングスキャン（処理負荷軽減のため0.2秒間隔で実行）
	_auto_dock_timer += delta
	if _auto_dock_timer >= 0.2:
		_auto_dock_timer = 0.0
		_scan_for_auto_docking()
	
	if _is_resolving:
		return

	if settings.current_rule == 0: # Tetris
		_evaluate_tetris_lines(delta)
	elif settings.current_rule == 1: # Puyo
		_evaluate_puyo_matches(delta)


func _evaluate_tetris_lines(delta: float) -> void:
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		return

	var blocks_by_row: Dictionary = {}
	var row_size = CELL_SIZE

	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					var local_pos = physics_frame.to_local(block.global_position)
					if local_pos.x >= -4.0 and local_pos.x <= settings.board_width_px + 4.0:
						var row_idx = int(round(block.global_position.y / row_size))
						if not blocks_by_row.has(row_idx):
							blocks_by_row[row_idx] = []
						blocks_by_row[row_idx].append(block)

	var current_full_rows = []
	var trigger_chain = false

	for row_idx in blocks_by_row.keys():
		var row_blocks = blocks_by_row[row_idx]
		if row_blocks.size() >= settings.clear_threshold:
			current_full_rows.append(row_idx)
			if not _line_timers.has(row_idx):
				_line_timers[row_idx] = 0.0

			_line_timers[row_idx] += delta
			var progress = clampf(_line_timers[row_idx] / settings.line_clear_hold_time, 0.0, 1.0)

			for block in row_blocks:
				if is_instance_valid(block):
					var glow = progress * 2.5
					block.modulate = Color(1.0 + glow, 1.0 + glow, 1.0 + glow, 1.0)

			if _line_timers[row_idx] >= settings.line_clear_hold_time:
				trigger_chain = true

	var to_erase = []
	for key in _line_timers.keys():
		if typeof(key) == TYPE_INT and not current_full_rows.has(key):
			to_erase.append(key)
	for key in to_erase:
		_line_timers.erase(key)

	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					var row_idx = int(round(block.global_position.y / row_size))
					if not current_full_rows.has(row_idx):
						block.modulate = Color.WHITE

	# いずれかの待機条件が満了したら、タイマーが動いていた全ての行を一斉に連鎖爆発に巻き込む
	if trigger_chain:
		var chain_groups: Array = []
		for row_idx in current_full_rows:
			if _line_timers.has(row_idx):
				chain_groups.append(blocks_by_row[row_idx])
				_line_timers.erase(row_idx)
				
		if not chain_groups.is_empty():
			_execute_chain_clear(chain_groups, 0)


func _evaluate_puyo_matches(delta: float) -> void:
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		return
		
	var active_blocks: Array[Node] = []
	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					var local_pos = physics_frame.to_local(block.global_position)
					if local_pos.x >= -4.0 and local_pos.x <= settings.board_width_px + 4.0:
						active_blocks.append(block)
						
	var visited: Dictionary = {}
	var matched_groups: Array[Array] = []
	var neighbor_dist: float = 38.0
	var min_clear_count: int = 4
	
	for block in active_blocks:
		if visited.has(block):
			continue
			
		if not block.has_meta("color_id"):
			continue
		var color_id = block.get_meta("color_id")
		
		var group: Array[Node] = []
		var stack: Array[Node] = [block]
		
		while not stack.is_empty():
			var curr = stack.pop_back()
			if visited.has(curr):
				continue
			visited[curr] = true
			group.append(curr)
			
			for other in active_blocks:
				if not visited.has(other) and other.has_meta("color_id") and other.get_meta("color_id") == color_id:
					if curr.global_position.distance_to(other.global_position) <= neighbor_dist:
						stack.append(other)
						
		if group.size() >= min_clear_count:
			matched_groups.append(group)
			
	var current_group_keys: Dictionary = {}
	var all_matched_blocks: Dictionary = {}
	var trigger_chain = false
	
	for group in matched_groups:
		var key = _get_group_key(group)
		current_group_keys[key] = true
		
		if not _line_timers.has(key):
			_line_timers[key] = 0.0
			
		_line_timers[key] += delta
		var progress = clampf(_line_timers[key] / settings.line_clear_hold_time, 0.0, 1.0)
		
		for block in group:
			all_matched_blocks[block] = true
			if is_instance_valid(block):
				var glow = progress * 2.5
				block.modulate = Color(1.0 + glow, 1.0 + glow, 1.0 + glow, 1.0)
				
		if _line_timers[key] >= settings.line_clear_hold_time:
			trigger_chain = true
			
	var to_erase = []
	for key in _line_timers.keys():
		if typeof(key) == TYPE_STRING and not current_group_keys.has(key):
			to_erase.append(key)
	for key in to_erase:
		_line_timers.erase(key)
		
	for block in active_blocks:
		if not all_matched_blocks.has(block):
			block.modulate = Color.WHITE
			
	# いずれかの待機条件が満了したら、現在待機状態にある全てのグループを連鎖に巻き込む
	if trigger_chain:
		var chain_groups: Array = []
		for group in matched_groups:
			var key = _get_group_key(group)
			if _line_timers.has(key):
				chain_groups.append(group)
				_line_timers.erase(key)
				
		if not chain_groups.is_empty():
			_execute_chain_clear(chain_groups, 1)


func _execute_chain_clear(chain_groups: Array, rule: int) -> void:
	_is_resolving = true
	var chain_count := 0
	
	for group in chain_groups:
		# 途中の衝撃波などで既に消去済みのブロックがないか生存確認
		var valid_group: Array[Node] = []
		for block in group:
			if is_instance_valid(block) and not block.is_queued_for_deletion() and not block.disabled:
				valid_group.append(block)
				
		if valid_group.is_empty():
			continue
			
		chain_count += 1
		
		# スコア加算（連鎖数 chain を含める）
		if is_instance_valid(score_manager) and score_manager.has_method("add_score"):
			var popup_pos: Vector2 = _calculate_center_position(valid_group)
			var rule_data := {}
			if rule == 0:
				rule_data = {"lines": 1, "chain": chain_count}
			else:
				rule_data = {"puyo_count": valid_group.size(), "chain": chain_count}
			score_manager.add_score(rule, rule_data, popup_pos)
			
		# ぷよルールの場合は衝撃波を適用
		if rule == 1:
			var active_blocks: Array[Node] = []
			var physics_frame = get_node_or_null("BoardPhysicsFrame")
			if physics_frame:
				for child in get_children():
					if child is Tetromino:
						for block in child.get_children():
							if block is CollisionShape2D and not block.disabled:
								var local_pos = physics_frame.to_local(block.global_position)
								if local_pos.x >= -4.0 and local_pos.x <= settings.board_width_px + 4.0:
									active_blocks.append(block)
			_apply_shockwave(valid_group, active_blocks)
			
		# 消去エフェクトとノード破棄の実行（現在のグループの破壊を同期待機）
		await _do_line_clear(valid_group)
		
		# 次の連鎖がある場合は、時を止めて次の予兆演出とインターバル待機へ
		if chain_count < chain_groups.size():
			get_tree().paused = true # エフェクト終了によるポーズ解除に対抗してポーズを維持
			
			# 1. 次に消去予定のグループを先読みして生存しているブロックを抽出
			var next_group: Array = chain_groups[chain_count]
			var next_valid_group: Array[Node] = []
			for block in next_group:
				if is_instance_valid(block) and not block.is_queued_for_deletion() and not block.disabled:
					next_valid_group.append(block)
			
			var interval = settings.get("chain_interval_time") if settings.get("chain_interval_time") != null else 0.3
			
			# 2. 次のグループが存在する場合、中心座標に向けて収縮波（インプロージョン）予兆演出を実行
			if not next_valid_group.is_empty() and is_instance_valid(effect_manager):
				# 強発光状態をリセットして視認性を担保しつつ、プレイヤーが触れないようにロック
				for block in next_valid_group:
					if is_instance_valid(block):
						block.modulate = Color.WHITE
						var parent = block.get_parent()
						if parent != null and parent.has_method("set"):
							parent.set("_is_chain_locked", true)
				
				var center_pos := _calculate_center_position(next_valid_group)
				var radius = settings.get("shockwave_radius") if settings.get("shockwave_radius") != null else 96.0
				
				# 収縮アニメーションの再生（演出時間自体がインターバル待機を兼ねる）
				await effect_manager.play_implosion_effect(center_pos, radius, interval)
			else:
				# 予兆対象がない場合の安全フォールバック待機
				await get_tree().create_timer(interval, true, false, true).timeout
			
	_is_resolving = false


func _get_group_key(group: Array) -> String:
	var ids: Array[int] = []
	for b in group:
		if is_instance_valid(b):
			ids.append(b.get_instance_id())
	ids.sort()
	return str(ids)


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


func _apply_shockwave(cleared_blocks: Array[Node], all_active_blocks: Array[Node]) -> void:
	if cleared_blocks.is_empty():
		return
		
	var center = _calculate_center_position(cleared_blocks)
	var radius = settings.get("shockwave_radius") if settings.get("shockwave_radius") != null else 96.0
	
	# エフェクトの呼び出し
	if is_instance_valid(effect_manager) and effect_manager.has_method("play_shockwave_effect"):
		effect_manager.play_shockwave_effect(center, radius)
	
	var affected_blocks: Array[Node] = []
	for block in all_active_blocks:
		if cleared_blocks.has(block):
			continue
		if is_instance_valid(block) and block.global_position.distance_to(center) <= radius:
			affected_blocks.append(block)
			
	var blocks_to_detach: Array[Node] = []
	var neighbor_dist = 38.0
	
	for block in affected_blocks:
		var is_isolated = true
		var color_id = block.get_meta("color_id") if block.has_meta("color_id") else ""
		
		for other in all_active_blocks:
			if block == other or cleared_blocks.has(other):
				continue
			if is_instance_valid(other) and other.has_meta("color_id") and other.get_meta("color_id") == color_id:
				if block.global_position.distance_to(other.global_position) <= neighbor_dist:
					is_isolated = false
					break
					
		if is_isolated:
			blocks_to_detach.append(block)
			
	if not blocks_to_detach.is_empty():
		# 物理演算中のノードツリー変更によるエラーを防ぐため、遅延呼び出しで分離を実行
		call_deferred("_detach_and_recreate_blocks", blocks_to_detach)


func _detach_and_recreate_blocks(blocks: Array[Node]) -> void:
	for block in blocks:
		if not is_instance_valid(block) or block.is_queued_for_deletion():
			continue
			
		var parent = block.get_parent()
		if not is_instance_valid(parent) or not (parent is Tetromino):
			continue
			
		var global_pos = block.global_position
		var block_rotation = parent.rotation
		var color_id = block.get_meta("color_id")
		
		# 単独ブロックとして新しいTetrominoを生成
		var tet_scene = load("res://Tetromino.tscn") as PackedScene
		if not tet_scene:
			continue
		var new_tet = tet_scene.instantiate() as Tetromino
		
		# シーンツリーに追加（_ready呼び出し）される前に自動生成フラグを無効化する
		new_tet.disable_auto_spawn = true
		
		new_tet.global_position = global_pos
		new_tet.rotation = block_rotation
		new_tet.set("_is_locked", true)
		new_tet.freeze = false # 分離後に物理落下を再開させる
		
		var block_scene_res = load("res://Block.tscn") as PackedScene
		if block_scene_res:
			var new_block = block_scene_res.instantiate()
			new_block.set_meta("color_id", color_id)
			
			var current_color = Color.WHITE
			if new_tet.TETROMINO_DATA.has(color_id):
				var shape_def = new_tet.TETROMINO_DATA[color_id] as Dictionary
				current_color = shape_def.get("color", Color.WHITE)
				
			var cr = new_block.get_node_or_null("ColorRect") as ColorRect
			if cr:
				cr.color = current_color
				
			new_block.position = Vector2.ZERO
			new_tet.add_child(new_block)
		
		add_child(new_tet)
		
		# 修正: 分離・独立させた直後に内部配列(blocks, local_cells)を再構築し、不正オブジェクトになるのを防ぐ
		if new_tet.has_method("_rebuild_internal_arrays"):
			new_tet._rebuild_internal_arrays()
			
		block.queue_free()


func _calculate_center_position(blocks: Array[Node]) -> Vector2:
	if blocks.is_empty():
		return Vector2.ZERO
		
	var center := Vector2.ZERO
	var valid_count := 0
	
	for block in blocks:
		if is_instance_valid(block) and block is Node2D:
			center += block.global_position
			valid_count += 1
			
	if valid_count > 0:
		return center / float(valid_count)
	return Vector2.ZERO


# ==============================================================================
# 中央集権型 ドッキング（マージ）管理ロジック
# ==============================================================================

var _debug_info: Dictionary = {}

func request_docking(source_tet: Tetromino) -> bool:
	var eval = _evaluate_docking(source_tet)
	_debug_info = eval
	
	
	if eval.can_dock:
		var physics_frame = get_node_or_null("BoardPhysicsFrame")
		if physics_frame:
			# ★ eval.target_data を追加で渡す
			return _execute_docking(source_tet, eval.target_tet, eval.source_blocks, eval.target_cells, eval.target_data, physics_frame.global_position)
	return false

# 判定ロジックの本体（距離と最寄りマスに基づく寛容な判定）
func _evaluate_docking(source_tet: Tetromino) -> Dictionary:
	var result = {
		"can_dock": false,
		"target_tet": null,
		"target_cells": [],
		"source_blocks": [],
		"target_data": null,
		"reason": "",
		"debug_points": []
	}
	
	# デバッグのため判定を分割して詳細なログを出す
	if not is_instance_valid(source_tet):
		result.reason = "Invalid source (null or freed)"
		print("[Debug Docking] 失敗: 掴んだ対象(source_tet)が既に破棄されているか無効です。")
		return result
		
	if source_tet.blocks.is_empty():
		result.reason = "Invalid source (blocks is empty)"
		print("[Debug Docking] 致命的失敗: 掴んだ対象の blocks 配列が空っぽです！(分離時の自己修復漏れの可能性大)")
		return result
		
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		result.reason = "No physics frame"
		return result
	var frame_origin = physics_frame.global_position

	var occupied_cells := {}
	var all_active_blocks := []
	for child in get_children():
		if child is Tetromino and child != source_tet and child.get("_is_locked"):
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					var local_pos = block.global_position - frame_origin
					var bx = round(local_pos.x / CELL_SIZE)
					var by = round(local_pos.y / CELL_SIZE)
					occupied_cells[Vector2i(bx, by)] = child
					all_active_blocks.append({
						"block": block,
						"tet": child,
						"cell": Vector2i(bx, by),
						"pos": block.global_position,
						"color_id": block.get_meta("color_id") if block.has_meta("color_id") else ""
					})
					
	if all_active_blocks.is_empty():
		result.reason = "Board is empty"
		return result

	var source_blocks = []
	for block in source_tet.get_children():
		if block is CollisionShape2D and not block.disabled:
			source_blocks.append(block)

	# 1. 有効距離内にあるすべてのペアを候補として収集
	var candidate_matches = []
	for s_block in source_blocks:
		var s_pos = s_block.global_position
		var s_color_id = s_block.get_meta("color_id") if s_block.has_meta("color_id") else ""
		
		for t_data in all_active_blocks:
			var dist = s_pos.distance_to(t_data.pos)
			if dist <= docking_distance_threshold:
				# 色チェックフラグが有効かつ色が異なる場合は、デバッグ点のみ登録して候補から除外
				if require_same_color and s_color_id != "" and t_data.color_id != "" and s_color_id != t_data.color_id:
					result.debug_points.append({"pos": t_data.pos, "reason": "Color Mismatch"})
					continue
					
				candidate_matches.append({
					"source_block": s_block,
					"target_data": t_data,
					"dist": dist
				})

	if candidate_matches.is_empty():
		result.reason = "Too Far or Color Mismatch"
		print("[Debug Docking] 失敗: 有効距離内に結合候補が存在しないか、同色条件を満たしていません。")
		return result
		
	# 2. 近い順に最優先で評価されるようソートを実行
	candidate_matches.sort_custom(func(a, b): return a.dist < b.dist)

	# 3. 候補リストを走査し、条件（空きマス検証・重なり検証）を最初にクリアしたペアで結合を確定
	for match_data in candidate_matches:
		var t_data = match_data.target_data
		var s_block = match_data.source_block
		var s_pos = s_block.global_position
		
		var adjacent_offsets = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
		var best_target_cell = Vector2i.ZERO
		var min_cell_dist = INF
		var found_empty_adjacent = false
		
		for offset in adjacent_offsets:
			var candidate_cell = t_data.cell + offset
			# 物理座標ベースで結合先予定地を算出
			var candidate_pos = t_data.pos + Vector2(offset.x * CELL_SIZE, offset.y * CELL_SIZE)
			
			var is_occupied = false
			for other in all_active_blocks:
				# 自身（source_blocks）は障害物として判定しない
				if source_blocks.has(other.block): continue
				
				# CELL_SIZE(32)の60% = 約19.2px以内に別のブロックがいれば物理的に重なっていると判定
				if candidate_pos.distance_to(other.pos) < CELL_SIZE * 0.6:
					is_occupied = true
					break
					
			if is_occupied:
				continue
				
			var dist = s_pos.distance_to(candidate_pos)
			if dist < min_cell_dist:
				min_cell_dist = dist
				best_target_cell = candidate_cell
				found_empty_adjacent = true
				
		if not found_empty_adjacent:
			result.debug_points.append({"pos": t_data.pos, "reason": "No Space"})
			print("[Debug Docking] 候補除外 (No Space): 結合先候補の周囲4方向に空きマスがありません。対象座標=", t_data.pos)
			continue # 次の次点ペアの検証へフォールバック

		var relative_cell_offsets = []
		for b in source_blocks:
			var rel_pos = (b.position - s_block.position)
			var rx = round(rel_pos.x / CELL_SIZE)
			var ry = round(rel_pos.y / CELL_SIZE)
			relative_cell_offsets.append(Vector2i(rx, ry))

		var final_target_cells = []
		var has_overlap = false
		for offset in relative_cell_offsets:
			var cell = best_target_cell + offset
			# source側の相対配置をターゲット物理座標ベースへ変換して検証
			var exact_global_pos = t_data.pos + Vector2((cell.x - t_data.cell.x) * CELL_SIZE, (cell.y - t_data.cell.y) * CELL_SIZE)
			
			var is_occupied = false
			for other in all_active_blocks:
				# 自身（source_blocks）は障害物として判定しない
				if source_blocks.has(other.block): continue
				
				if exact_global_pos.distance_to(other.pos) < CELL_SIZE * 0.6:
					is_occupied = true
					break
					
			if is_occupied:
				has_overlap = true
				result.debug_points.append({"pos": exact_global_pos, "reason": "Overlap"})
				break
			final_target_cells.append(cell)
				
		if has_overlap:
			print("[Debug Docking] 候補除外 (Overlap): 結合予定地に既に別のブロックが存在します。")
			continue # 次の次点ペアの検証へフォールバック

		# すべてのパズル空間チェックを通過したため吸着を確定する
		result.can_dock = true
		result.target_tet = t_data.tet
		result.target_cells = final_target_cells
		result.source_blocks = source_blocks
		result.target_data = t_data
		result.reason = "OK"
		return result

	if result.reason == "":
		result.reason = "All Candidates Blocked"
		print("[Debug Docking] 失敗: 候補はありましたが、周囲に十分な空きマスがない等の理由で全てブロックされました。")
	return result

func _execute_docking(source_tet: Tetromino, target_tet: Tetromino, source_blocks: Array, target_cells: Array, target_data: Dictionary, frame_origin: Vector2) -> bool:
	# 1. source_tet の物理演算と入力を無効化（アニメーション中の干渉を防止）
	source_tet.freeze = true
	source_tet.process_mode = Node.PROCESS_MODE_DISABLED
	
	var base_block = target_data.block
	var base_cell = target_data.cell
	
	# 修正: target_tet が破壊されたらTweenも即座にキャンセルされるようバインド
	var tween = create_tween().bind_node(target_tet).set_parallel(true)
	var anim_duration = 0.15 # 吸着アニメーションの時間
	
	for i in range(source_blocks.size()):
		var block = source_blocks[i]
		var target_cell = target_cells[i]
		
		# 絶対グリッドでのマス目差分を計算
		var cell_diff = target_cell - base_cell
		
		# 結合先（target_tet）のローカル座標系で、基準ブロックから差分マス目分ズラした正確な位置を算出
		var exact_local_pos = base_block.position + Vector2(cell_diff.x * CELL_SIZE, cell_diff.y * CELL_SIZE)
		
		# 移籍による位置ズレを防ぐため、現在の見た目の絶対座標・角度を保存
		var current_global_pos = block.global_position
		var current_global_rot = block.global_rotation
		
		# ターゲットに移籍
		block.get_parent().remove_child(block)
		target_tet.add_child(block)
		
		# 一旦元のグローバル座標・角度を復元（見た目を維持）
		block.global_position = current_global_pos
		block.global_rotation = current_global_rot
		
		# 目標のローカル座標・角度(0.0)へアニメーション
		tween.tween_property(block, "position", exact_local_pos, anim_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(block, "rotation", 0.0, anim_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# クラッシュ対策：アニメーション中にオブジェクトが破棄される可能性を考慮し、事前にエフェクト再生用の座標をキャッシュしておく
	var snap_effect_pos = source_blocks[0].global_position if not source_blocks.is_empty() else Vector2.ZERO

	# アニメーション完了後の処理を遅延実行
	tween.chain().tween_callback(func():
		if is_instance_valid(target_tet) and target_tet.has_method("_rebuild_internal_arrays"):
			target_tet._rebuild_internal_arrays()

		# キャッシュした安全な座標を用いてエフェクトを再生
		if is_instance_valid(effect_manager) and effect_manager.has_method("play_snap_particles") and snap_effect_pos != Vector2.ZERO:
			effect_manager.play_snap_particles(snap_effect_pos)

		# 解除: アニメーションが完全終了したので、結合先の排他ロックを解除して物理演算や次の結合を許可する
		if is_instance_valid(target_tet):
			target_tet.set("_is_docking_animating", false)
	)
	
	# 抜け殻(source_tet)は中身を移籍した直後に即座に破棄する（アニメーション完了を待たない）
	if is_instance_valid(source_tet):
		source_tet.queue_free()
	
	return true

# ==============================================================================
# プレビュー描画およびデバッグロジック
# ==============================================================================
var _preview_rects: Array[Rect2] = []
var _preview_fill_color: Color = Color(1.0, 1.0, 1.0, 0.3)
var _preview_line_color: Color = Color(1.0, 1.0, 1.0, 0.8)

func update_docking_preview(source_tet: Tetromino) -> void:
	_preview_rects.clear()
	var eval = _evaluate_docking(source_tet)
	_debug_info = eval
	
	if eval.can_dock:
		var physics_frame = get_node_or_null("BoardPhysicsFrame")
		if physics_frame:
			var frame_origin = physics_frame.global_position
			var half_size = CELL_SIZE / 2.0
			for cell in eval.target_cells:
				var exact_global_pos = frame_origin + Vector2(cell.x * CELL_SIZE, cell.y * CELL_SIZE)
				var local_draw_pos = to_local(exact_global_pos)
				_preview_rects.append(Rect2(local_draw_pos - Vector2(half_size, half_size), Vector2(CELL_SIZE, CELL_SIZE)))
		
	queue_redraw()

func clear_docking_preview() -> void:
	_preview_rects.clear()
	_debug_info.clear()
	queue_redraw()

func _draw() -> void:
	# プレビュー矩形の描画
	for rect in _preview_rects:
		draw_rect(rect, _preview_fill_color, true)
		draw_rect(rect, _preview_line_color, false, 2.0)

	# デバッグ可視化（フラグON時のみ）
	if show_debug_docking:
		var physics_frame = get_node_or_null("BoardPhysicsFrame")
		if physics_frame:
			for child in get_children():
				if child is Tetromino and child.get("_is_locked"):
					for block in child.get_children():
						if block is CollisionShape2D and not block.disabled:
							var local_pos = to_local(block.global_position)
							# 吸着エリアを示す赤い円を描画
							draw_arc(local_pos, docking_distance_threshold, 0, TAU, 32, Color(1, 0, 0, 0.5), 1.0)
							
		# 拒否された理由をテキスト表示
		if not _debug_info.is_empty() and not _debug_info.get("can_dock", true):
			var font = ThemeDB.fallback_font
			var points = _debug_info.get("debug_points", [])
			for pt in points:
				var local_pos = to_local(pt.pos)
				draw_string(font, local_pos + Vector2(0, -20), pt.reason, HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.RED)


# 盤面上の非操作ブロック同士を監視し、条件を満たせば自動結合を発火させる（ステップ2）
func _scan_for_auto_docking() -> void:
	if _is_resolving:
		return

	for child in get_children():
		if child is Tetromino and child.get("_is_locked"):
			# 自分自身がドラッグ中、アニメーション中、または連鎖ロック中ならスキップ
			if child.get("_is_dragging_by_player") or child.get("_is_docking_animating") or child.get("_is_chain_locked"):
				continue
				
			# 既存の優秀な吸着判定ロジックを流用して周囲を評価
			var eval = _evaluate_docking(child)
			if eval.can_dock and is_instance_valid(eval.target_tet):
				var target_tet = eval.target_tet
				
				# 相手側もドラッグ中、アニメーション中、または連鎖ロック中ならスキップして競合を防ぐ
				if target_tet.get("_is_dragging_by_player") or target_tet.get("_is_docking_animating") or target_tet.get("_is_chain_locked"):
					continue
					
				# 【仕様確保】結合後の合計ブロック数が設定値以下になる場合のみ自動結合を許可
				var total_blocks = child.blocks.size() + target_tet.blocks.size()
				if total_blocks <= settings.max_auto_dock_blocks:
					# アニメーション中の多重処理（クラッシュ原因）を防ぐため、双方に即座に排他ロックをかける
					child.set("_is_docking_animating", true)
					target_tet.set("_is_docking_animating", true)
					
					# 結合処理を実行
					var physics_frame = get_node_or_null("BoardPhysicsFrame")
					var frame_origin = physics_frame.global_position if physics_frame else Vector2.ZERO
					_execute_docking(child, target_tet, eval.source_blocks, eval.target_cells, eval.target_data, frame_origin)
					return # 1フレーム中の安全のため、1組結合したらスキャンを抜ける


# 画面外に落ちてしまったテトリミノを検知して破棄するガベージコレクション
func _cleanup_out_of_bounds() -> void:
	var kill_y_threshold: float = 1500.0 # 画面外と判定するY座標のデッドゾーン
	for child in get_children():
		if child is Tetromino:
			# 画面外はるか下方に落ちたオブジェクトを破棄
			if child.global_position.y > kill_y_threshold:
				child.queue_free()
