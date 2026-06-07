extends Node2D
class_name Board

signal resolve_started
signal resolve_finished

var WIDTH: int = 10
var HEIGHT: int = 20
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
var _chain_queue: Array = []
var _is_chain_active: bool = false
var _current_chain_count: int = 0
var _line_timers: Dictionary = {}
var _auto_dock_timer: float = 0.0
# 現在盤面が演出用のスローモーション（泥沼状態）にあるかどうかのフラグ
var _is_slow_motion: bool = false
# ウォッチドッグ用：連鎖処理が最後に「進捗」した時刻(ms)。長い連鎖を誤って打ち切らないよう、
# 総経過ではなく「進捗が一定時間止まったか」でハングを判定するために使う。
var _chain_progress_msec: int = 0


# 外部（Mainなど）から現在連鎖中かどうかを取得する
func is_chain_active() -> bool:
	return _is_chain_active


func _ready() -> void:
	# Settingsからマスのサイズを読み込む
	if settings != null:
		var w = settings.get("board_width_cells")
		var h = settings.get("board_height_cells")
		if w != null: WIDTH = w
		if h != null: HEIGHT = h

	# Board自体は時間停止中も入力を監視するために常に動作させる
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	_apply_dynamic_board_size() # ★追加：盤面サイズの自動適応
	
	_initialize_grid()
	effect_manager = get_node_or_null(effect_manager_path) as EffectManager
	if effect_manager == null:
		effect_manager = get_parent().get_node_or_null("EffectManager") as EffectManager
	score_manager = get_node_or_null(score_manager_path)
	# EffectManagerの演出開始/終了に合わせて、盤面をスローモーション（泥沼状態）にするシグナルを接続
	if is_instance_valid(effect_manager) and not effect_manager.slow_motion_requested.is_connected(set_board_slow_motion):
		effect_manager.slow_motion_requested.connect(set_board_slow_motion)


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
	# 枠を高速で振った際などに壁をすり抜けたブロックを内側へ戻す安全網
	_contain_blocks_inside_frame()
	# 重なり緩和(緩和B): テレポート（ドッキング配置・ドラッグ貫通）で生じた同一セルの重なりを検出し、
	# 該当剛体を起こして物理ソルバに自然に押し離させる（物理の手触りは維持）
	_separate_overlapping_blocks()

	# 【ステップ3】低頻度自動ドッキングスキャン（処理負荷軽減のため0.2秒間隔で実行）
	_auto_dock_timer += delta
	if _auto_dock_timer >= 0.2:
		_auto_dock_timer = 0.0
		_scan_for_auto_docking()
	
	# 連鎖中も判定を回し続けるため、_is_resolving によるブロックを撤廃

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
		for row_idx in current_full_rows:
			if _line_timers.has(row_idx):
				_chain_queue.append(blocks_by_row[row_idx])
				_line_timers.erase(row_idx)
				
		# キューに追加後、連鎖処理が稼働していなければスタートさせる
		if not _chain_queue.is_empty() and not _is_chain_active:
			_execute_chain_queue(0)


func _evaluate_puyo_matches(delta: float) -> void:
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		return
		
	var min_clear_count: int = 4

	# 1. 盤面内の全ブロックを「色 → セル(Vector2i) → そのセルに居るブロック配列」へ集約する。
	#    セル単位で扱うことで、物理的に重なった/極端に接近したブロックが同一セルに畳まれ、
	#    連結数を水増しして「見た目4つ未満なのに連鎖」が起きるのを防ぐ（重なりは1セル＝1カウント）。
	var color_cells: Dictionary = {}  # color_id -> { Vector2i: Array[block] }
	var active_blocks: Array[Node] = []  # 後段のグロー解除用に、判定対象の全ブロックを保持
	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if not (block is CollisionShape2D) or block.disabled:
					continue
				if not block.has_meta("color_id"):
					continue
				var local_pos: Vector2 = physics_frame.to_local(block.global_position)
				# 盤面の左右からはみ出した（落下中など）ブロックは判定対象外
				if local_pos.x < -4.0 or local_pos.x > settings.board_width_px + 4.0:
					continue
				active_blocks.append(block)
				var cell := _cell_of(block, physics_frame)
				var color_id = block.get_meta("color_id")
				if not color_cells.has(color_id):
					color_cells[color_id] = {}
				var cells: Dictionary = color_cells[color_id]
				if not cells.has(cell):
					cells[cell] = []
				cells[cell].append(block)

	# 2. 同色セルの4近傍フラッドフィルで連結成分を求め、ユニークなセル数で消去判定する。
	var matched_groups: Array[Array] = []
	var adjacent_offsets := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	for color_id in color_cells.keys():
		var cells: Dictionary = color_cells[color_id]
		var visited_cells: Dictionary = {}
		for start_cell in cells.keys():
			if visited_cells.has(start_cell):
				continue
			var component: Array[Vector2i] = []
			var stack: Array[Vector2i] = [start_cell]
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				if visited_cells.has(c):
					continue
				visited_cells[c] = true
				component.append(c)
				for off in adjacent_offsets:
					var n: Vector2i = c + off
					if cells.has(n) and not visited_cells.has(n):
						stack.append(n)
			# ユニークセル数が閾値以上なら、そのセル群に属する全ブロックを消去対象にする
			if component.size() >= min_clear_count:
				var group: Array[Node] = []
				for cc in component:
					for b in cells[cc]:
						group.append(b)
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
		for group in matched_groups:
			var key = _get_group_key(group)
			if _line_timers.has(key):
				_chain_queue.append(group)
				_line_timers.erase(key)
				
		# キューに追加後、連鎖処理が稼働していなければスタートさせる
		if not _chain_queue.is_empty() and not _is_chain_active:
			_execute_chain_queue(1)


func _execute_chain_queue(rule: int) -> void:
	# [SlowTrace] 連鎖開始。ハング検出用にウォッチドッグを起動（awaitしない＝バックグラウンド監視）
	var _chain_start_msec: int = Time.get_ticks_msec()
	_chain_progress_msec = _chain_start_msec # 進捗時刻を初期化
	print("[SlowTrace] _execute_chain_queue 開始 rule=", rule, " t=", _chain_start_msec, " queue=", _chain_queue.size(), " slow=", _is_slow_motion)
	_chain_watchdog(_chain_start_msec)

	_is_chain_active = true
	resolve_started.emit()

	while not _chain_queue.is_empty():
		var group = _chain_queue.pop_front()
		
		# 途中の衝撃波などで既に消去済みのブロックがないか生存確認
		var valid_group: Array[Node] = []
		for block in group:
			if is_instance_valid(block) and not block.is_queued_for_deletion() and not block.disabled:
				valid_group.append(block)
				
		if valid_group.is_empty():
			continue
			
		_current_chain_count += 1
		
		# スコア加算（連鎖数 chain を含める）
		if is_instance_valid(score_manager) and score_manager.has_method("add_score"):
			var popup_pos: Vector2 = _calculate_center_position(valid_group)
			var rule_data := {}
			if rule == 0:
				rule_data = {"lines": 1, "chain": _current_chain_count}
			else:
				rule_data = {"puyo_count": valid_group.size(), "chain": _current_chain_count}
			score_manager.add_score(rule, rule_data, popup_pos)
			
		# ぷよルールの場合は衝撃波（視覚演出のみ）を適用
		if rule == 1:
			_apply_shockwave(valid_group)
			
		# 消去エフェクトとノード破棄の実行（現在のグループの破壊を同期待機）
		print("[SlowTrace] _do_line_clear 待機開始 chain=", _current_chain_count, " blocks=", valid_group.size(), " t=", Time.get_ticks_msec())
		await _do_line_clear(valid_group)
		_chain_progress_msec = Time.get_ticks_msec() # 1段消化＝進捗あり。ウォッチドッグの誤発火を防ぐ
		print("[SlowTrace] _do_line_clear 待機完了 chain=", _current_chain_count, " t=", _chain_progress_msec, " slow=", _is_slow_motion)

		# 次の連鎖がキューに積まれている場合は、スローモーションを維持して予兆演出・インターバル待機へ
		if not _chain_queue.is_empty():
			print("[SlowTrace] 次連鎖あり→スロー維持 set_board_slow_motion(true) t=", Time.get_ticks_msec())
			set_board_slow_motion(true) # エフェクト終了によるスロー解除に対抗して泥沼状態を維持
			
			# 1. 次に消去予定のグループを先読みして生存しているブロックを抽出
			var next_group: Array = _chain_queue[0]
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
			
	# キューが空になったら連鎖を完全に終了し、カウントをリセットする
	_is_chain_active = false
	_current_chain_count = 0
	# 先読み演出で立てた連鎖ロックを必ず解除（戻し忘れると結合・ドラッグ不能になる）
	_clear_all_chain_locks()

	# フェイルセーフ：途中でブロックが消失して消去エフェクトがスキップされた場合でも、
	# 連鎖の完全終了時には確実にスローモーションを解除してバグを防ぐ
	print("[SlowTrace] 連鎖ループ脱出→解除へ到達 set_board_slow_motion(false) t=", Time.get_ticks_msec())
	print("[Debug Chain] 連鎖完了: スローモーションを強制解除します。")
	set_board_slow_motion(false)

	resolve_finished.emit()


# 連鎖ハング検出＆自動復旧ウォッチドッグ（多重防御の安全網）。
# 「総経過時間」ではなく「進捗が止まってからの時間」で判定するため、長い連鎖を誤って
# 打ち切らない。進捗(_chain_progress_msec)が一定時間更新されなければハングとみなし、
# 原因が何であれ強制的にスローを解除してゲームが永久スローで固まるのを防ぐ。
# 本来はEffectManager側の修正で詰まらないが、将来別経路で詰まっても復帰不能にしないための保険。
func _chain_watchdog(_start_msec: int) -> void:
	var stall_limit_msec: int = 5000 # 進捗が5秒止まったらハングとみなす
	while _is_chain_active:
		await get_tree().create_timer(1.0, true, false, true).timeout
		if not _is_chain_active:
			return
		var stalled: int = Time.get_ticks_msec() - _chain_progress_msec
		if stalled >= stall_limit_msec:
			push_error("[SlowTrace] 連鎖の進捗が%d ms停止＝ハング検出。強制復旧します。slow=%s queue=%d chain=%d" % [stalled, str(_is_slow_motion), _chain_queue.size(), _current_chain_count])
			# 強制復旧：スローを解除し、連鎖状態をリセットして次のブロック生成を再開させる
			set_board_slow_motion(false)
			_is_chain_active = false
			_current_chain_count = 0
			_chain_queue.clear()
			_clear_all_chain_locks()
			resolve_finished.emit()
			return


# ブロックのグローバル座標を、枠ローカルの整数セル(Vector2i)へ変換する単一基準関数。
# 占有判定（ドッキング）とマッチング判定の双方でこれを用い、
# 「座標→セル」の計算式を一本化する（各所で個別に丸めて齟齬が出るのを防ぐ）。
# physics_frame.to_local は枠の位置・回転・スケールを考慮するため、生の減算より正確。
func _cell_of(block: Node2D, physics_frame: Node2D = null) -> Vector2i:
	if physics_frame == null:
		physics_frame = get_node_or_null("BoardPhysicsFrame")
	if physics_frame == null:
		return Vector2i.ZERO
	var local: Vector2 = physics_frame.to_local(block.global_position)
	return Vector2i(round(local.x / CELL_SIZE), round(local.y / CELL_SIZE))


# 連鎖の先読み演出で立てた _is_chain_locked を、盤面上の全Tetrominoから解除する。
# このフラグは「立てるだけ」で戻し忘れると、対象Tetrominoが永久に
# ドラッグ・自動結合の対象外になる（同色でもくっつかない）ため、
# 連鎖の終了経路（正常終了・ウォッチドッグ復旧）で必ず呼んでリセットする。
func _clear_all_chain_locks() -> void:
	for child in get_children():
		if child is Tetromino and child.get("_is_chain_locked"):
			child.set("_is_chain_locked", false)


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


func _apply_shockwave(cleared_blocks: Array[Node]) -> void:
	# 衝撃波は視覚演出のみ。以前あった「孤立ブロックを分離してバラバラに崩す」仕様は、
	# ぷよルールでブロックが分解されてしまうため撤廃した（塊単位の物理落下のみとする）。
	if cleared_blocks.is_empty():
		return

	var center = _calculate_center_position(cleared_blocks)
	var radius = settings.get("shockwave_radius") if settings.get("shockwave_radius") != null else 96.0

	if is_instance_valid(effect_manager) and effect_manager.has_method("play_shockwave_effect"):
		effect_manager.play_shockwave_effect(center, radius)


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
		return result
		
	if source_tet.blocks.is_empty():
		result.reason = "Invalid source (blocks is empty)"
		return result
		
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not physics_frame:
		result.reason = "No physics frame"
		return result
	var frame_origin = physics_frame.global_position

	var occupied_cells := {}
	var all_active_blocks := []
	for child in get_children():
		if child is Tetromino and child != source_tet:
			var child_locked: bool = child.get("_is_locked")
			for block in child.get_children():
				if block is CollisionShape2D and not block.disabled:
					# マッチング判定と同じ _cell_of を用いて座標→セルを一本化する
					var cell := _cell_of(block, physics_frame)
					# 重なり防止(緩和A): ロック有無に関わらず全ての他ブロックを占有セルとして登録し、
					# 既にブロックがある場所へ配置されるのを防ぐ（落下中の塊への重なりも回避）。
					occupied_cells[cell] = child
					# ただし結合先（ターゲット）候補は、安定しているロック済みブロックのみとする。
					if child_locked:
						all_active_blocks.append({
							"block": block,
							"tet": child,
							"cell": cell,
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

	var is_player_dragging = source_tet.get("_is_dragging_by_player") if source_tet.has_method("get") else false

	# 1. 有効距離内にあるすべてのペアを候補として収集
	var candidate_matches = []
	var closest_dist_for_debug = INF
	
	for s_block in source_blocks:
		var s_pos = s_block.global_position
		var s_color_id = s_block.get_meta("color_id") if s_block.has_meta("color_id") else ""
		
		for t_data in all_active_blocks:
			var dist = s_pos.distance_to(t_data.pos)
			if dist < closest_dist_for_debug: closest_dist_for_debug = dist
			
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
		return result
		
	# 2. 近い順に最優先で評価されるようソートを実行
	candidate_matches.sort_custom(func(a, b): return a.dist < b.dist)

	# 3. 候補リストを走査し、条件（空きマス検証・重なり検証）を最初にクリアしたペアで結合を確定
	for match_data in candidate_matches:
		var t_data = match_data.target_data
		var s_block = match_data.source_block
		var s_pos = s_block.global_position
		
		# 修正A: 物理的な揺れや傾きで形状が歪むのを防ぐため、
		# Tetrominoのローカル座標を現在の回転角度（90度単位にスナップ）で回して、絶対的なマス目形状を算出する
		var snapped_rot = 0.0
		if is_instance_valid(source_tet) and "rotation" in source_tet:
			snapped_rot = round(source_tet.rotation / (PI / 2.0)) * (PI / 2.0)
			
		var s_local_rot = s_block.position.rotated(snapped_rot)
		
		var relative_cell_offsets = []
		for b in source_blocks:
			var b_local_rot = b.position.rotated(snapped_rot)
			var rel_pos = b_local_rot - s_local_rot
			var rx = round(rel_pos.x / CELL_SIZE)
			var ry = round(rel_pos.y / CELL_SIZE)
			relative_cell_offsets.append(Vector2i(rx, ry))

		var adjacent_offsets = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
		var valid_target_cells = []
		
		for offset in adjacent_offsets:
			var candidate_cell = t_data.cell + offset
			if occupied_cells.has(candidate_cell):
				continue
				
			var candidate_pos = frame_origin + Vector2(candidate_cell.x * CELL_SIZE, candidate_cell.y * CELL_SIZE)
			var dist = s_pos.distance_to(candidate_pos)
			valid_target_cells.append({"cell": candidate_cell, "dist": dist})
			
		if valid_target_cells.is_empty():
			result.debug_points.append({"pos": t_data.pos, "reason": "No Space"})
			continue # 周囲に空きマスなし
			
		# 修正B: 距離が近い順に「全ての空きマス」をテストする。
		# （1番近いマスが壁被りでダメでも、2番目のマスなら綺麗に収まるケースを救済するため）
		valid_target_cells.sort_custom(func(a, b): return a.dist < b.dist)
		
		var best_target_cell = Vector2i.ZERO
		var docked_successfully = false
		var final_target_cells = []
		
		for vt in valid_target_cells:
			var candidate_base_cell = vt.cell
			var has_overlap = false
			var temp_cells = []
			
			for offset in relative_cell_offsets:
				var cell = candidate_base_cell + offset
				if occupied_cells.has(cell):
					has_overlap = true
					break
				temp_cells.append(cell)
				
			if not has_overlap:
				best_target_cell = candidate_base_cell
				final_target_cells = temp_cells
				docked_successfully = true
				break
				
		if not docked_successfully:
			result.debug_points.append({"pos": t_data.pos, "reason": "Overlap"})
			continue # どの隣接マスに置いても全体のどこかが被ってしまう場合は次点ペアへ
			
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
	return result

func _execute_docking(source_tet: Tetromino, target_tet: Tetromino, source_blocks: Array, target_cells: Array, target_data: Dictionary, frame_origin: Vector2) -> bool:
	# [SlowTrace] ドッキング実行。連鎖演出中(slow=true)に発火していれば、解放されるブロックが
	# 消去Tweenの対象と被ってハングする可能性がある。時刻と状態を記録して相関を取る。
	print("[SlowTrace] _execute_docking 実行 src_blocks=", source_blocks.size(), " slow=", _is_slow_motion, " chain_active=", _is_chain_active, " t=", Time.get_ticks_msec())

	# 1. source_tet の物理演算と入力を無効化（アニメーション中の干渉を防止）
	source_tet.freeze = true
	source_tet.process_mode = Node.PROCESS_MODE_DISABLED
	
	var base_block = target_data.block
	var base_cell = target_data.cell

	# 補間時間は設定から参照（0なら瞬間移動）。配置ブロック・グリッド吸着で共通利用する。
	var anim_duration: float = 0.15
	if settings != null and settings.get("docking_anim_duration") != null:
		anim_duration = maxf(0.0, settings.docking_anim_duration)

	# --- グリッド吸着（重なり防止 / 原因Bの根治）---
	# 結合先(target_tet)を最寄りの90度＋絶対グリッドの目標姿勢へ寄せる。
	# 各Tetrominoが物理で蓄積した微小オフセット（最大±16px）を取り除くことで、
	# ローカル座標が常に CELL_SIZE の整数倍になり、配置ブロックが検証済みの絶対セルに
	# 正確に収まる（既存ブロックと重ならない）。_rebuild_internal_arrays の整合も保たれる。
	# 瞬間移動ではなく anim_duration で補間するため、目標姿勢を「解析的に」先に求める。
	var pf_node := get_node_or_null("BoardPhysicsFrame") as Node2D
	var target_pose_valid := false
	var target_rot_final := 0.0
	var target_pos_final := Vector2.ZERO
	if is_instance_valid(target_tet) and is_instance_valid(pf_node) and is_instance_valid(base_block):
		target_rot_final = round(target_tet.rotation / (PI / 2.0)) * (PI / 2.0)
		# base_block を base_cell の中心へ合わせる target_tet の最終位置を逆算
		var desired_base_global: Vector2 = pf_node.to_global(Vector2(base_cell.x * CELL_SIZE, base_cell.y * CELL_SIZE))
		target_pos_final = desired_base_global - base_block.position.rotated(target_rot_final)
		target_pose_valid = true
		# アニメ中は対象を凍結・ロックして物理干渉を防ぐ（完了時に解除）
		target_tet.set("_is_docking_animating", true)
		target_tet.freeze = true
		target_tet.linear_velocity = Vector2.ZERO
		target_tet.angular_velocity = 0.0

	# 修正: target_tet が破壊されたらTweenも即座にキャンセルされるようバインド
	var tween = create_tween().bind_node(target_tet).set_parallel(true)

	# 結合先の姿勢をグリッドへ補間（既存ブロックも一緒にカチッと整列する）
	if target_pose_valid:
		tween.tween_property(target_tet, "global_position", target_pos_final, anim_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(target_tet, "rotation", target_rot_final, anim_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

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

		# 解除: アニメーションが完全終了したので、結合先の凍結・排他ロックを解除して
		# 物理演算や次の結合を許可する。速度を打ち消してから戻すことで飛び跳ねを防ぐ。
		if is_instance_valid(target_tet):
			target_tet.linear_velocity = Vector2.ZERO
			target_tet.angular_velocity = 0.0
			target_tet.freeze = false
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


# 壁の外へすり抜けてしまったブロックを盤面内へ戻す封じ込め処理（多重防御の安全網）。
# 物理対策（sync_to_physics＋移動量クランプ＋CCD）をすり抜けた例外を確実に救済する。
# 接触時のジッタを避けるため、壁から escape_margin 以上はみ出したブロックのみ矯正する。
func _contain_blocks_inside_frame() -> void:
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if not is_instance_valid(physics_frame):
		return
	var width_px: float = settings.board_width_px if settings != null else float(WIDTH * CELL_SIZE)
	var floor_y: float = float(HEIGHT * CELL_SIZE)
	var escape_margin: float = float(CELL_SIZE)  # この距離以上はみ出したブロックのみ矯正
	var min_x: float = 0.0
	var max_x: float = width_px
	for child in get_children():
		if not (child is Tetromino):
			continue
		var tet := child as Tetromino
		if not is_instance_valid(tet) or tet.is_queued_for_deletion():
			continue
		for block in tet.get_children():
			if not (block is CollisionShape2D) or block.disabled:
				continue
			# 壁(physics_frame)のローカル座標系で内外を判定する（枠の位置・スケールに追従）
			var local_pos: Vector2 = physics_frame.to_local(block.global_position)
			var clamped: Vector2 = local_pos
			var escaped: bool = false
			if local_pos.x < min_x - escape_margin:
				clamped.x = min_x
				escaped = true
			elif local_pos.x > max_x + escape_margin:
				clamped.x = max_x
				escaped = true
			if local_pos.y > floor_y + escape_margin:
				clamped.y = floor_y
				escaped = true
			if escaped:
				# はみ出したブロックを内側へ戻し、暴れないよう速度を打ち消す。
				# 個別ブロックではなく親Tetromino(剛体)を移動させて整合を保つ。
				var target_global: Vector2 = physics_frame.to_global(clamped)
				var correction: Vector2 = target_global - block.global_position
				tet.global_position += correction
				tet.linear_velocity = Vector2.ZERO
				tet.angular_velocity = 0.0
				break  # 1Tetrominoにつき1回矯正したら次へ（過補正を防ぎ、次フレームで収束させる）


# 重なり緩和（緩和B）：複数のTetrominoが同一セルを占有している＝物理的な重なりを検出し、
# 該当する剛体を「起こす(sleeping=false)」ことで、物理ソルバの貫通解消（押し離し）を再作動させる。
# テレポート（ドッキング配置・ドラッグ中の貫通）でめり込んだまま眠ってしまったブロックを救済する。
# 直接座標を動かさず物理に任せるため、落下・積み上げの手触りは保たれる。
func _separate_overlapping_blocks() -> void:
	var pf = get_node_or_null("BoardPhysicsFrame")
	if pf == null:
		return
	var cell_owners: Dictionary = {}  # Vector2i -> Array[Tetromino]
	for child in get_children():
		if not (child is Tetromino):
			continue
		# 演出・操作中の対象は触らない（ドッキングアニメやドラッグを邪魔しない）
		if child.get("_is_docking_animating") or child.get("_is_dragging_by_player"):
			continue
		for block in child.get_children():
			if not (block is CollisionShape2D) or block.disabled:
				continue
			var cell: Vector2i = _cell_of(block, pf)
			if not cell_owners.has(cell):
				cell_owners[cell] = []
			var owners: Array = cell_owners[cell]
			if not owners.has(child):
				owners.append(child)

	# 同一セルを2つ以上のTetrominoが占有していれば重なり。該当剛体を起こして分離を促す。
	for cell in cell_owners:
		var owners: Array = cell_owners[cell]
		if owners.size() >= 2:
			for t in owners:
				if t.freeze:
					continue
				t.sleeping = false


# 盤面上の全テトリミノの物理スロー状態を一斉に切り替える（ステップ2）
func set_board_slow_motion(is_slow: bool) -> void:
	var _tet_count: int = 0
	for child in get_children():
		if child is Tetromino and child.has_method("set_slow_motion"):
			child.set_slow_motion(is_slow)
			_tet_count += 1
	_is_slow_motion = is_slow
	# [SlowTrace] 呼び出し元・対象数・適用後の状態を記録（true/false の最終順序を特定するため）
	print("[SlowTrace] set_board_slow_motion(", is_slow, ") 対象Tetromino数=", _tet_count, " t=", Time.get_ticks_msec())
	print("[SlowTrace]   呼び出し元スタック=", get_stack())
	print("[Debug Board] 盤面がスローモーション要求を受信しました: is_slow = ", is_slow)


# 盤面の定数（WIDTH, HEIGHT）に基づいて、背景と物理枠（壁・床）を自動でリサイズ・再構築する
func _apply_dynamic_board_size() -> void:
	var pixel_width = WIDTH * CELL_SIZE
	var pixel_height = HEIGHT * CELL_SIZE
	
	# 1. GameSettingsの更新（ブロックが画面外へ出たかどうかの判定用）
	if settings != null:
		settings.set("board_width_px", pixel_width)
		
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if physics_frame:
		# 盤面サイズに合わせてドラッグ可能な掴み判定エリアも自動更新
		if physics_frame.has_method("update_grab_area"):
			physics_frame.update_grab_area(pixel_width, pixel_height)
			
		# 2. 実際のシーン構造に合わせた背景と枠線の自動リサイズ
		var bg = physics_frame.get_node_or_null("BoardBackground") as ColorRect
		if bg:
			bg.size = Vector2(pixel_width, pixel_height)
			bg.position = Vector2.ZERO
			
		var border = physics_frame.get_node_or_null("BoardBorder") as ReferenceRect
		if border:
			border.size = Vector2(pixel_width, pixel_height)
			border.position = Vector2.ZERO
			
		# 3. 物理枠（壁・床）の自動再構築
		for child in physics_frame.get_children():
			if child is CollisionShape2D:
				child.queue_free()
				
		var wall_thickness: float = 100.0 # 壁の厚さ
		
		# 床の生成
		var floor_shape = CollisionShape2D.new()
		var floor_rect = RectangleShape2D.new()
		floor_rect.size = Vector2(pixel_width + wall_thickness * 2, wall_thickness)
		floor_shape.shape = floor_rect
		floor_shape.position = Vector2(pixel_width / 2.0, pixel_height + wall_thickness / 2.0)
		physics_frame.call_deferred("add_child", floor_shape)
		
		# 左壁の生成
		var left_shape = CollisionShape2D.new()
		var left_rect = RectangleShape2D.new()
		left_rect.size = Vector2(wall_thickness, pixel_height + wall_thickness * 2)
		left_shape.shape = left_rect
		left_shape.position = Vector2(-wall_thickness / 2.0, pixel_height / 2.0)
		physics_frame.call_deferred("add_child", left_shape)
		
		# 右壁の生成
		var right_shape = CollisionShape2D.new()
		var right_rect = RectangleShape2D.new()
		right_rect.size = Vector2(wall_thickness, pixel_height + wall_thickness * 2)
		right_shape.shape = right_rect
		right_shape.position = Vector2(pixel_width + wall_thickness / 2.0, pixel_height / 2.0)
		physics_frame.call_deferred("add_child", right_shape)

		# 4. カメラを「盤面＋取っ手」の中心に合わせる（取っ手が画面外に切れないようにする）
		var cam = get_node_or_null("../Camera2D") as Camera2D
		if cam:
			var handle_radius: float = settings.handle_radius if settings != null else 60.0
			var handle_thickness: float = settings.handle_thickness if settings != null else 16.0
			# 取っ手は盤面右端から右へ膨らむため、見える内容の右端はここまで伸びる
			var content_right: float = pixel_width + handle_radius + handle_thickness / 2.0 + 4.0
			cam.global_position = physics_frame.global_position + Vector2(content_right / 2.0, pixel_height / 2.0)


func check_deadline_exceeded(y_threshold: float) -> bool:
	for child in get_children():
		if child is Tetromino and child.get("_is_locked"):
			# プレイヤーが操作中のブロックや、ドッキングアニメーション中のものは除外
			var is_dragging = child.get("_is_dragging_by_player") if "_is_dragging_by_player" in child else false
			var is_animating = child.get("_is_docking_animating") if "_is_docking_animating" in child else false
			if is_dragging or is_animating:
				continue

			# 速度がほぼゼロ（物理的に静止している）ブロックのみを判定対象とする
			var v_len = child.linear_velocity.length()
			var a_len = abs(child.angular_velocity)
			if v_len < 10.0 and a_len < 2.0:
				for block in child.get_children():
					if block is CollisionShape2D and not block.disabled:
						# Godotでは画面上部に行くほどY座標が小さくなる
						if block.global_position.y < y_threshold:
							return true
	return false
