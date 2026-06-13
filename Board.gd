extends Node2D
class_name Board

signal resolve_started
signal resolve_finished
# ドッキング（吸着結合）が成立した瞬間。AudioManager がSE再生のために購読する。
signal block_docked
# ブロックが破壊（消去）された瞬間。連鎖数を渡し、SEのピッチ制御に使う。
signal block_cleared(chain_count: int)

var WIDTH: int = 10
var HEIGHT: int = 20
const CELL_SIZE := 32

enum GameRule { TETRIS, PUYO }
@export var effect_manager_path: NodePath = NodePath("../EffectManager")
@export var score_manager_path: NodePath = NodePath("../ScoreManager")
@export var block_scene: PackedScene = preload("res://Block.tscn")

var settings: GameSettings = preload("res://game_settings.tres")

var effect_manager: EffectManager
var score_manager: Node
var _chain_queue: Array = []
var _is_chain_active: bool = false
var _current_chain_count: int = 0
var _line_timers: Dictionary = {}
# Puyoルールの破壊待機を「ブロック単位の充電量」で管理する（block -> 0..hold 秒）。
# グループのキーではなくブロック単位で持つことで、塊のメンバーが少し入れ替わっても
# 充電が維持され、戻り（解除）の判定が緩くなる（入りは等速、解除はゆっくり減衰）。
var _block_charge: Dictionary = {}
# 連鎖キューへ投入済みで消去待ちのブロック（block -> true）。マッチ判定の対象外にして二重投入を防ぐ。
var _pending_clear: Dictionary = {}
var _auto_dock_timer: float = 0.0
# 現在盤面が演出用のスローモーション（泥沼状態）にあるかどうかのフラグ
var _is_slow_motion: bool = false
# ウォッチドッグ用：連鎖処理が最後に「進捗」した時刻(ms)。長い連鎖を誤って打ち切らないよう、
# 総経過ではなく「進捗が一定時間止まったか」でハングを判定するために使う。
var _chain_progress_msec: int = 0
# 連鎖コルーチンの世代ID。ウォッチドッグ強制復旧後に「古い連鎖コルーチン」がawaitから再開して
# 新しい連鎖の状態（_is_chain_active / _pending_clear）を壊す二重実行を防ぐ。
# 復旧・新規開始のたびにインクリメントし、await明けにIDが進んでいたら静かに自滅させる。
var _chain_run_id: int = 0

# --- 原因調査用デバッグ（show_debug_matching）---
# マッチ判定の可視化データ（オーバーレイ描画用）。毎物理フレーム _evaluate_puyo_matches が更新する。
var _debug_match_info: Dictionary = {}
# 「マッチ成立中なのに発火しない」状態の継続時間計測（group_key -> {"t": 経過秒, "logged": 出力済みか}）
var _match_stall: Dictionary = {}
# 結合デッドゾーンログ／連鎖キュー滞留警告のレート制限用タイムスタンプ(ms)
var _last_dockfail_log_msec: int = 0
var _last_leak_log_msec: int = 0
# 手動（ドラッグ）結合の拒否ログのレート制限用タイムスタンプ(ms)
var _last_player_dockfail_log_msec: int = 0


# 調査用フラグの安全な読み出し（キー欠損に強い既存パターンに倣う）
func _is_match_debug_on() -> bool:
	return settings != null and settings.get("show_debug_matching") == true


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

	# デバッグ吸着円を「枠・背景・ブロックより手前」に描くための最前面オーバーレイを生成する。
	# Board本体の_draw()は子ノード（不透明な背景ColorRectなど）に隠れて見えないため、
	# z_index を最大近くに設定した専用ノードへ描画を逃がす（draw シグナルで描画処理を購読）。
	_debug_overlay = Node2D.new()
	_debug_overlay.name = "DebugOverlay"
	_debug_overlay.z_index = 4096          # 同一CanvasLayer内で実質最前面
	_debug_overlay.z_as_relative = false   # 親のzに依存せず絶対的に最前面化
	add_child(_debug_overlay)
	_debug_overlay.draw.connect(_on_debug_overlay_draw)


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

	# デバッグ表示（吸着円・マッチ判定）を最前面オーバーレイで毎フレーム更新。フラグON時のみ。
	if settings != null and (settings.show_debug_docking or _is_match_debug_on()) and is_instance_valid(_debug_overlay):
		_debug_overlay.queue_redraw()

	# 滞留検知（常時ON）：連鎖が動いていないのに消去待ち(_pending_clear)やキューが残っているのは、
	# 「白く光ったまま判定から除外され続ける（凍結）」バグの直接証拠なので、見つけ次第警告を出す。
	if not _is_chain_active and (not _pending_clear.is_empty() or not _chain_queue.is_empty()):
		var now_msec: int = Time.get_ticks_msec()
		if now_msec - _last_leak_log_msec >= 1000:
			_last_leak_log_msec = now_msec
			push_warning("[Debug ChainLeak] 連鎖停止中に残留検知: pending=%d queue=%d（白凍結の原因候補）" % [_pending_clear.size(), _chain_queue.size()])

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

	# 消去に必要な隣接ブロック数はGameSettingsで調整可能（キー欠損時は従来値4へフォールバック）
	var min_clear_count: int = settings.get("clear_threshold") if settings != null and settings.get("clear_threshold") != null else 4

	# 調査用（show_debug_matching）：このフレームの判定内容を可視化・ログするための収集器
	var debug_on: bool = _is_match_debug_on()
	var dbg_blocks: Array = []
	var dbg_components: Array = []
	var dbg_folds: Array = []
	var dbg_edges: Array = []

	# 連結判定の距離パラメータ（GameSettingsから。キー欠損時はフォールバック）
	# connect_dist: この実距離以内の同色ペアを「隣接」とみなす（隣接静止=32px / 斜め接触=約45px の中間）
	# overlap_dist: この実距離以内に重なった同色ブロックは「1個」に統合して数える（水増し防止）
	var connect_dist: float = settings.get("match_connect_distance") if settings != null and settings.get("match_connect_distance") != null else 36.0
	var overlap_dist: float = settings.get("match_overlap_merge_distance") if settings != null and settings.get("match_overlap_merge_distance") != null else 16.0

	# 1. 盤面内の全ブロックを「色 → ブロック配列」へ集約する（除外条件は従来どおり）。
	var color_blocks: Dictionary = {}  # color_id -> Array[block]
	var active_blocks: Array[Node] = []  # 後段のグロー解除用に、判定対象の全ブロックを保持
	for child in get_children():
		if child is Tetromino:
			for block in child.get_children():
				if not (block is CollisionShape2D) or block.disabled:
					continue
				# 連鎖キューへ投入済み（消去待ち）のブロックは判定対象外（二重投入・誤再充電を防ぐ）
				if _pending_clear.has(block):
					# 調査用：除外中＝modulateが更新されず白いまま凍結しうるブロックを可視化対象に記録する
					if debug_on:
						dbg_blocks.append({"pos": block.global_position, "charge": _block_charge.get(block, 0.0), "matched": false, "pending": true})
					continue
				if not block.has_meta("color_id"):
					continue
				var local_pos: Vector2 = physics_frame.to_local(block.global_position)
				# 盤面の左右からはみ出した（落下中など）ブロックは判定対象外
				if local_pos.x < -4.0 or local_pos.x > settings.board_width_px + 4.0:
					continue
				active_blocks.append(block)
				var color_id = block.get_meta("color_id")
				if not color_blocks.has(color_id):
					color_blocks[color_id] = []
				color_blocks[color_id].append(block)

	# 2. 同色ブロックを「実距離」で連結判定する（格子への丸めを廃止）。
	#    格子丸めでは、傾き・ズレたまま積まれたブロックが「同一マスへ畳み込まれる/2マス飛びになる」ことで
	#    見た目どおりに数えられないバグがあった。塊内の隣接ブロック間は傾いていても常に約32pxなので、
	#    実距離で判定すればプレイヤーの見た目と判定が一致する。
	#    (a) overlap_dist 以内に重なったブロックは1つの「スタック」へ統合（連結数の水増し防止＝旧セル畳み込みの距離版）
	#    (b) スタック同士は、所属ブロックの最近接ペアが connect_dist 以内なら「隣接」とみなす
	#    (c) 連結成分のスタック数（＝見た目の個数）が閾値以上なら、その全ブロックを消去対象とする
	var matched_groups: Array[Array] = []
	for color_id in color_blocks.keys():
		var blocks_of_color: Array = color_blocks[color_id]

		# (a) スタック化（既存スタックの代表位置から overlap_dist 以内なら同一スタックへ統合）
		var stacks: Array[Dictionary] = []
		for b in blocks_of_color:
			var placed: bool = false
			for st in stacks:
				if (st["pos"] as Vector2).distance_to(b.global_position) <= overlap_dist:
					(st["blocks"] as Array).append(b)
					placed = true
					break
			if not placed:
				stacks.append({"blocks": [b], "pos": b.global_position})

		# (b) スタック間の隣接グラフを構築
		var stack_count: int = stacks.size()
		var adjacency: Array = []
		for i in range(stack_count):
			adjacency.append([])
		for i in range(stack_count):
			for j in range(i + 1, stack_count):
				if _are_stacks_connected(stacks[i], stacks[j], connect_dist):
					adjacency[i].append(j)
					adjacency[j].append(i)
					if debug_on:
						dbg_edges.append({"a": stacks[i]["pos"], "b": stacks[j]["pos"]})

		# (c) フラッドフィルで連結成分を求め、スタック数（見た目の個数）で消去判定する
		var visited: Dictionary = {}
		for start_idx in range(stack_count):
			if visited.has(start_idx):
				continue
			var component: Array[int] = []
			var dfs_stack: Array[int] = [start_idx]
			while not dfs_stack.is_empty():
				var idx: int = dfs_stack.pop_back()
				if visited.has(idx):
					continue
				visited[idx] = true
				component.append(idx)
				for nb in adjacency[idx]:
					if not visited.has(nb):
						dfs_stack.append(nb)
			# 調査用：連結数を記録（「見た目4つ隣接なのに3」等の確認用）
			if debug_on and component.size() >= 2:
				var centroid := Vector2.ZERO
				for idx in component:
					centroid += stacks[idx]["pos"] as Vector2
				dbg_components.append({"size": component.size(), "center": centroid / float(component.size())})
			# スタック数が閾値以上なら、そのスタック群に属する全ブロックを消去対象にする
			if component.size() >= min_clear_count:
				var group: Array[Node] = []
				for idx in component:
					for b in stacks[idx]["blocks"]:
						group.append(b)
				matched_groups.append(group)

		# 調査用：重なり統合（複数ブロックが1個として数えられている場所）の検出
		if debug_on:
			for st in stacks:
				if (st["blocks"] as Array).size() >= 2:
					dbg_folds.append({"pos": st["pos"], "count": (st["blocks"] as Array).size()})
			
	# --- 破壊待機の充電（ブロック単位）---
	# キー（グループ集合）ではなくブロック単位で充電を持つことで、塊のメンバーが少し
	# 入れ替わっても“白さ”が保たれる。入り＝等速で充電、戻り（解除）＝release_rateでゆっくり減衰。
	var hold: float = settings.line_clear_hold_time
	# 戻り（解除）は充電の半分の速さでゆっくり減衰させ、少しの移動では白さが消えないようにする。
	var release_rate: float = 0.5
	var matched_blocks: Dictionary = {}
	for group in matched_groups:
		for b in group:
			matched_blocks[b] = true

	for b in active_blocks:
		if matched_blocks.has(b):
			_block_charge[b] = minf(hold, _block_charge.get(b, 0.0) + delta)
		else:
			var cur: float = _block_charge.get(b, 0.0)
			if cur > 0.0:
				cur = maxf(0.0, cur - delta * release_rate)
				if cur <= 0.0:
					_block_charge.erase(b)
				else:
					_block_charge[b] = cur

	# グロー表示（charge/hold に応じて発光。0なら通常色）。
	for b in active_blocks:
		if not is_instance_valid(b):
			continue
		var prog: float = clampf(_block_charge.get(b, 0.0) / hold, 0.0, 1.0)
		if prog > 0.0:
			var glow: float = prog * 2.5
			b.modulate = Color(1.0 + glow, 1.0 + glow, 1.0 + glow, 1.0)
		else:
			b.modulate = Color.WHITE

	# トリガー：現在マッチ中かつ構成ブロックが全て満充電(>=hold)の塊を連鎖キューへ投入する。
	# 満充電なら確実に発火するため「白いのに連鎖に加わらない」を防ぐ。
	var triggered: bool = false
	var stalled_groups: Array[Array] = []
	for group in matched_groups:
		if group.is_empty():
			continue
		var all_full: bool = true
		for b in group:
			if _block_charge.get(b, 0.0) < hold:
				all_full = false
				break
		if all_full:
			for b in group:
				_pending_clear[b] = true
			_chain_queue.append(group)
			triggered = true
			if debug_on:
				print("[Debug MatchFire] 発火: %d個のグループを連鎖キューへ投入 (chain_active=%s queue=%d)" % [group.size(), str(_is_chain_active), _chain_queue.size()])
		elif debug_on:
			# 調査用：マッチは成立しているが「全員満充電」に達せず発火していないグループ
			stalled_groups.append(group)

	if triggered and not _chain_queue.is_empty() and not _is_chain_active:
		_execute_chain_queue(1)

	# --- 調査用：可視化データの確定と「発火しないマッチ」の継続監視 ---
	if debug_on:
		for b in active_blocks:
			if is_instance_valid(b):
				dbg_blocks.append({"pos": b.global_position, "charge": _block_charge.get(b, 0.0), "matched": matched_blocks.has(b), "pending": false})
		_debug_match_info = {"blocks": dbg_blocks, "components": dbg_components, "folds": dbg_folds, "edges": dbg_edges}
		_update_match_stall_log(stalled_groups, delta, hold)
	elif not _debug_match_info.is_empty():
		_debug_match_info.clear()


# 2つのスタック（重なり統合済みの同色ブロック群）が「隣接」しているか＝
# 所属ブロックの最近接ペアが connect_dist 以内かどうかを返す（実距離ベースの連結判定で使用）。
func _are_stacks_connected(stack_a: Dictionary, stack_b: Dictionary, connect_dist: float) -> bool:
	for ba in stack_a["blocks"]:
		if not is_instance_valid(ba):
			continue
		for bb in stack_b["blocks"]:
			if not is_instance_valid(bb):
				continue
			if (ba as Node2D).global_position.distance_to((bb as Node2D).global_position) <= connect_dist:
				return true
	return false

func _execute_chain_queue(rule: int) -> void:
	# 連鎖開始。ハング検出用にウォッチドッグを起動（awaitしない＝バックグラウンド監視）
	var _chain_start_msec: int = Time.get_ticks_msec()
	_chain_progress_msec = _chain_start_msec # 進捗時刻を初期化
	_chain_watchdog(_chain_start_msec)

	# 世代IDを進めて自分の世代を記憶する。await明けに世代が変わっていたら
	# （ウォッチドッグ復旧や別経路の連鎖開始があったら）この実行は破棄されたものとして即終了する。
	_chain_run_id += 1
	var my_run_id: int = _chain_run_id

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

		# ブロック破壊SE用に連鎖数を通知（ピッチは購読側で連鎖数に応じて上げる）
		block_cleared.emit(_current_chain_count)

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
		await _do_line_clear(valid_group)
		# 二重実行ガード：待機中に世代交代（ウォッチドッグ復旧等）が起きていたら、状態に一切触れず終了する
		if my_run_id != _chain_run_id:
			return
		_chain_progress_msec = Time.get_ticks_msec() # 1段消化＝進捗あり。ウォッチドッグの誤発火を防ぐ

		# 次の連鎖がキューに積まれている場合は、スローモーションを維持して予兆演出・インターバル待機へ
		if not _chain_queue.is_empty():
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

			# 二重実行ガード：インターバル待機中に世代交代が起きていたら終了（状態は新世代が管理する）
			if my_run_id != _chain_run_id:
				return
			
	# キューが空になったら連鎖を完全に終了し、カウントをリセットする
	_is_chain_active = false
	_current_chain_count = 0
	# 先読み演出で立てた連鎖ロックを必ず解除（戻し忘れると結合・ドラッグ不能になる）
	_clear_all_chain_locks()
	# 充電状態・消去待ちの片付け
	_after_chain_cleanup()

	# フェイルセーフ：途中でブロックが消失して消去エフェクトがスキップされた場合でも、
	# 連鎖の完全終了時には確実にスローモーションを解除してバグを防ぐ
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
			push_error("[SlowTrace] 連鎖の進捗が%d ms停止＝ハング検出。強制復旧します。slow=%s queue=%d chain=%d pending=%d" % [stalled, str(_is_slow_motion), _chain_queue.size(), _current_chain_count, _pending_clear.size()])
			# 世代IDを進め、ハングしている古い連鎖コルーチンがawaitから再開しても
			# 状態へ触れず自滅するようにする（強制復旧後の二重実行・状態破壊を防ぐ）
			_chain_run_id += 1
			# 強制復旧：スローを解除し、連鎖状態をリセットして次のブロック生成を再開させる
			set_board_slow_motion(false)
			_is_chain_active = false
			_current_chain_count = 0
			_chain_queue.clear()
			_clear_all_chain_locks()
			_after_chain_cleanup()
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


# 連鎖終了時の片付け：消去待ち(_pending_clear)を解除し、無効になった充電エントリを掃除する。
# 特にウォッチドッグ中断時にこれを呼ばないと、投入済みブロックが永久にマッチ対象外となり詰む。
func _after_chain_cleanup() -> void:
	_pending_clear.clear()
	var invalid: Array = []
	for k in _block_charge.keys():
		if not is_instance_valid(k):
			invalid.append(k)
	for k in invalid:
		_block_charge.erase(k)


# 調査用：「マッチ成立中なのに全員満充電に達せず発火しない」状態が hold×2 秒以上続いたら、
# 足を引っ張っているブロック（充電不足メンバー）を特定してログへ出す。
# ※グループのメンバーが入れ替わるとキーが変わって計測がリセットされる。それ自体も
#   「メンバーが安定していない＝セル割当が揺れている」証拠になるため、リセット回数も気にして見る。
func _update_match_stall_log(stalled_groups: Array[Array], delta: float, hold: float) -> void:
	var present: Dictionary = {}
	for group in stalled_groups:
		var key: String = _get_group_key(group)
		present[key] = true
		var entry: Dictionary = _match_stall.get(key, {"t": 0.0, "logged": false})
		entry["t"] = float(entry["t"]) + delta
		if float(entry["t"]) >= hold * 2.0 and not bool(entry["logged"]):
			entry["logged"] = true
			var lines: Array[String] = []
			for b in group:
				if is_instance_valid(b):
					var mark: String = " ←満充電未達" if _block_charge.get(b, 0.0) < hold else ""
					lines.append("  color=%s charge=%.2f/%.2f pos=%s%s" % [str(b.get_meta("color_id")), _block_charge.get(b, 0.0), hold, str(b.global_position.round()), mark])
			print("[Debug MatchStall] マッチ成立中なのに%.1f秒以上発火しないグループ(%d個):\n%s" % [hold * 2.0, group.size(), "\n".join(lines)])
		_match_stall[key] = entry
	# 解消した（このフレームに存在しない）グループの計測は破棄する
	var stale_keys: Array = []
	for k in _match_stall.keys():
		if not present.has(k):
			stale_keys.append(k)
	for k in stale_keys:
		_match_stall.erase(k)


# 調査用：自動結合が拒否された際、同色ペアが至近距離(40px以内)に居るのに結合できないケースを記録する。
# 特に「しきい値(30px) < ブロック幅(32px)」のデッドゾーン＝静止した隣接ペアが構造的に結合不能、の実証に使う。
func _log_dock_deadzone(source_tet: Tetromino, eval: Dictionary) -> void:
	if not _is_match_debug_on():
		return
	var d: float = eval.get("closest_same_color_dist", INF)
	if d > 40.0:
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_dockfail_log_msec < 1000:
		return
	_last_dockfail_log_msec = now_msec
	var threshold: float = settings.docking_distance_threshold if settings != null else 38.0
	print("[Debug DockDeadzone] 自動結合不可: 同色最接近=%.1fpx しきい値=%.1fpx reason=%s source=%s" % [d, threshold, str(eval.get("reason")), str(source_tet.name)])


# 調査用（show_debug_matching）：手動（ドラッグ）結合が拒否された理由の内訳をログする。
# 距離内に候補があった（debug_points が空でない）のに結合しなかったケースだけを対象にし、
# 単に届いていない「Too Far」はノイズとして出さない。
# 「Size Limit」が並ぶ場合、結合自体は届いているのに max_auto_dock_blocks 超過で
# 弾かれている＝「くっつかない・精度が悪い」体感の原因がサイズ上限だと確定できる。
func _log_player_dock_reject(source_tet: Tetromino, eval: Dictionary) -> void:
	if not _is_match_debug_on():
		return
	var points: Array = eval.get("debug_points", [])
	if points.is_empty():
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_player_dockfail_log_msec < 1000:
		return
	_last_player_dockfail_log_msec = now_msec
	var counts: Dictionary = {}
	for pt in points:
		var r: String = str(pt.get("reason", "?"))
		counts[r] = int(counts.get(r, 0)) + 1
	var src_n: int = _count_blocks(source_tet)
	var maxv: int = settings.max_auto_dock_blocks if settings != null else 8
	print("[Debug PlayerDockReject] 手動結合不可 source=%d個 max=%d 拒否内訳=%s" % [src_n, maxv, str(counts)])


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
	# プレイヤーがつかんで動かしている塊の結合要求。緩めの距離で判定して気持ちよく吸着させる。
	var eval = _evaluate_docking(source_tet, true)
	_debug_info = eval

	# 調査用（show_debug_matching）：手動結合が「届いているのに弾かれた」内訳をログする
	if not eval.can_dock:
		_log_player_dock_reject(source_tet, eval)

	if eval.can_dock:
		# 排他ガード：相手が結合アニメーション中・連鎖ロック中（消去予告中）なら結合しない。
		# 自動スキャン(_scan_for_auto_docking)と同じ不変条件をドラッグ経路にも適用し、
		# 移動中の塊へ重ねて結合して座標が壊れる「想定外の状態」を防ぐ。
		var target_tet = eval.target_tet
		if not is_instance_valid(target_tet) or target_tet.get("_is_docking_animating") or target_tet.get("_is_chain_locked"):
			return false
		var physics_frame = get_node_or_null("BoardPhysicsFrame")
		if physics_frame:
			# 調査用（show_debug_matching）：どれだけ離れた相手に吸着したかをログする
			# （drag_docking_distance_threshold が大きすぎると、手元から遠い塊へ「勝手に飛んでいく」体感になる）
			if _is_match_debug_on():
				var thr: float = settings.drag_docking_distance_threshold if settings != null else 60.0
				print("[Debug PlayerDock] 手動結合確定 dist=%.1fpx (しきい値=%.1fpx) over_limit_clear=%s" % [float(eval.dock_dist), thr, str(eval.over_limit_clear)])
			# ★ eval.target_data と、きっかけになったソース側マッチブロックを渡す
			return _execute_docking(source_tet, eval.target_tet, eval.source_blocks, eval.target_cells, eval.target_data, physics_frame.global_position, eval.source_match_block)
	return false

# 判定ロジックの本体（距離と最寄りマスに基づく寛容な判定）
# is_player_dock: プレイヤーがつかんで動かしている塊の判定なら true。距離しきい値を緩める。
func _evaluate_docking(source_tet: Tetromino, is_player_dock: bool = false) -> Dictionary:
	var result = {
		"can_dock": false,
		"target_tet": null,
		"target_cells": [],
		"source_blocks": [],
		"target_data": null,
		"source_match_block": null,  # 判定のきっかけになった「同色隣接ペア」のソース側ブロック
		"over_limit_clear": false,   # サイズ上限超過だが「結合即消去」が成立するため特例許可した結合か
		"clear_cells": [],           # 特例許可時に消える予定の同色連結セル（プレビュー発光用）
		"reason": "",
		"debug_points": [],
		"closest_same_color_dist": INF,  # 調査用：同色ペアの最接近距離（デッドゾーン検証）
		"dock_dist": -1.0  # 調査用：結合確定したペアの実距離（吸着が遠すぎないかの検証）
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

	# 1. 有効距離内にあるすべてのペアを候補として収集
	# プレイヤー操作中は緩め、通常（自動結合）は厳しめのしきい値を使い分ける。
	var dock_threshold: float
	if is_player_dock:
		dock_threshold = settings.drag_docking_distance_threshold if settings != null else 60.0
	else:
		dock_threshold = settings.docking_distance_threshold if settings != null else 38.0
	var require_same: bool = settings.require_same_color if settings != null else true
	var candidate_matches = []
	var closest_dist_for_debug = INF

	for s_block in source_blocks:
		var s_pos = s_block.global_position
		var s_color_id = s_block.get_meta("color_id") if s_block.has_meta("color_id") else ""
		
		for t_data in all_active_blocks:
			var dist = s_pos.distance_to(t_data.pos)
			if dist < closest_dist_for_debug: closest_dist_for_debug = dist
			# 調査用：同色ペアの最接近距離を記録（しきい値とブロック幅32pxのデッドゾーン検証）
			var is_same_color: bool = (not require_same) or s_color_id == "" or t_data.color_id == "" or s_color_id == t_data.color_id
			if is_same_color and dist < result.closest_same_color_dist:
				result.closest_same_color_dist = dist

			if dist <= dock_threshold:
				# 色チェックフラグが有効かつ色が異なる場合は、デバッグ点のみ登録して候補から除外
				if require_same and s_color_id != "" and t_data.color_id != "" and s_color_id != t_data.color_id:
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
			
		# サイズ上限：既にロック済み（max_auto_dock_blocks 個以上＝鉄枠）の塊が関わる結合は行わない。
		# 判定は「結合後の合計」ではなく「結合前にどちらかがロック済みか」。未ロックの塊同士なら
		# 合計が上限を超えても結合でき、超えた瞬間にその塊がロック（鉄枠）化する。
		# 塊の最大サイズは (上限-1)+ピースサイズ 程度に抑えられるため、肥大化防止の意図は維持される。
		# これにより「拒否される塊＝鉄枠の塊」が常に一致し、見た目と挙動のズレがなくなる。
		# 手動ドラッグ・自動結合の双方がこの _evaluate_docking を通る。
		var max_dock: int = 8
		if settings != null and settings.get("max_auto_dock_blocks") != null:
			max_dock = settings.max_auto_dock_blocks
		# 【救済仕様】ロック済みの塊でも、プレイヤーの手動ドラッグで「結合した瞬間に clear_threshold
		# 以上の同色連結が成立＝置けば必ず消える」配置だけは特例で許可する。
		# 消去で塊は縮むため肥大化防止の意図は保たれ、ロック塊（鉄枠）にも
		# 「揃えて差し込めば崩せる」という直感的な攻略手段が残る。
		# 自動結合（is_player_dock=false）には適用しない：プレイヤーの意図しない結合を防ぐ。
		var over_limit_clear := false
		var over_limit_clear_cells: Array[Vector2i] = []
		if source_blocks.size() >= max_dock or _count_blocks(t_data.tet) >= max_dock:
			if is_player_dock:
				over_limit_clear_cells = _merged_clear_cells(t_data.tet, t_data.block, t_data.cell, source_blocks, final_target_cells)
				over_limit_clear = not over_limit_clear_cells.is_empty()
			if not over_limit_clear:
				result.debug_points.append({"pos": t_data.pos, "reason": "Size Limit"})
				continue

		# 合体後の全ブロック（結合先の既存＋入ってくるソース）の最終セルを検証する。
		# 結合先を90度スナップ・整列させた結果、傾いた塊の先端などが既存ブロックの
		# 同一セルへ飛び込む「重なり」を、確定前にここで弾く（不可なら次候補へ）。
		if not _merged_placement_ok(t_data.tet, t_data.block, t_data.cell, final_target_cells, occupied_cells):
			result.debug_points.append({"pos": t_data.pos, "reason": "Merge Overlap"})
			continue

		# すべてのパズル空間チェックを通過したため吸着を確定する
		result.can_dock = true
		result.target_tet = t_data.tet
		result.target_cells = final_target_cells
		result.source_blocks = source_blocks
		result.target_data = t_data
		result.source_match_block = s_block  # この同色隣接ペアが結合のきっかけ
		result.over_limit_clear = over_limit_clear
		result.clear_cells = over_limit_clear_cells
		result.dock_dist = match_data.dist  # 調査用：確定ペアの実距離
		result.reason = "OK (Over-Limit Clear)" if over_limit_clear else "OK"
		return result

	if result.reason == "":
		result.reason = "All Candidates Blocked"
	return result


# ドッキング確定前の最終検証（方針1＋2内包）。
# 結合先(target_tet)を最寄り90度へスナップし base_block を base_cell に合わせた「合体後の姿勢」で、
#   ・結合先の既存ブロックのスナップ後セル
#   ・入ってくるソースブロックの最終セル(source_cells)
# を全て算出し、(a)互いに重複しない かつ (b)他塊の占有セルと衝突しない ことを確認する。
# これにより「90度回転スナップで傾いた塊の先端が既存ブロックの同一セルへ飛び込む」重なりを防ぐ。
# Tetrominoが現在保持している有効ブロック数（消去無効でないCollisionShape2D）を数える。
func _count_blocks(tet: Node) -> int:
	if not is_instance_valid(tet):
		return 0
	var n: int = 0
	for c in tet.get_children():
		if c is CollisionShape2D and not c.disabled:
			n += 1
	return n


func _merged_placement_ok(target_tet: Node, base_block: Node, base_cell: Vector2i, source_cells: Array, occupied_cells: Dictionary) -> bool:
	if not is_instance_valid(target_tet) or not is_instance_valid(base_block):
		return false
	var rot: float = round(target_tet.rotation / (PI / 2.0)) * (PI / 2.0)
	var used: Dictionary = {}

	# 結合先の既存ブロックの「スナップ後」フレームセル（base_block を基準に回転後オフセットで算出）
	for tb in target_tet.get_children():
		if not (tb is CollisionShape2D) or tb.disabled:
			continue
		var off: Vector2 = (tb.position - base_block.position).rotated(rot)
		var cell := base_cell + Vector2i(int(round(off.x / CELL_SIZE)), int(round(off.y / CELL_SIZE)))
		if used.has(cell):
			return false  # 結合先内で自己重複
		if occupied_cells.has(cell) and occupied_cells[cell] != target_tet:
			return false  # 他塊と衝突
		used[cell] = true

	# 入ってくるソースブロックの最終セル
	for sc in source_cells:
		if used.has(sc):
			return false  # ソースと結合先（または互い）が同一セル
		if occupied_cells.has(sc) and occupied_cells[sc] != target_tet:
			return false  # 他塊と衝突
		used[sc] = true

	return true


# 【救済仕様の判定】合体後の姿勢（結合先を90度スナップ、_merged_placement_ok と同じ計算）で、
# ソースブロックを含む同色連結が clear_threshold 以上になるかを調べ、成立する全セルを返す
# （不成立なら空配列）。グリッド隣接＝実距離ちょうど32pxなので match_connect_distance(36px)
# に必ず収まり、「ここに置けば必ず消える」を保証できる。
# 判定は合体後の塊の内部のみで行い、隣の別塊をあてにしない（物理的な隙間や揺れで
# 実際には発火しない「空約束」を避けるため、確実に消える配置だけを特例許可する）。
func _merged_clear_cells(target_tet: Node, base_block: Node, base_cell: Vector2i, source_blocks: Array, source_cells: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not is_instance_valid(target_tet) or not is_instance_valid(base_block):
		return out
	var threshold: int = settings.get("clear_threshold") if settings != null and settings.get("clear_threshold") != null else 4

	# 合体後の「セル → 色ID」地図を作る。同一セルへ複数ブロックが畳まれた場合は上書きで1個と
	# 数える（マッチ判定のスタック統合と同じ、見た目個数ベースの数え方）。
	var cell_color: Dictionary = {}
	var rot: float = round(target_tet.rotation / (PI / 2.0)) * (PI / 2.0)
	for tb in target_tet.get_children():
		if not (tb is CollisionShape2D) or tb.disabled or not tb.has_meta("color_id"):
			continue
		var off: Vector2 = (tb.position - base_block.position).rotated(rot)
		var cell := base_cell + Vector2i(int(round(off.x / CELL_SIZE)), int(round(off.y / CELL_SIZE)))
		cell_color[cell] = tb.get_meta("color_id")
	var pair_count: int = min(source_blocks.size(), source_cells.size())
	for i in range(pair_count):
		var sb = source_blocks[i]
		if is_instance_valid(sb) and sb.has_meta("color_id"):
			cell_color[source_cells[i]] = sb.get_meta("color_id")

	# 各ソースセルを起点に同色フラッドフィルし、閾値以上の連結があれば採用する。
	# 起点をソース側に限定することで「この結合が原因で消える」場合だけを特例の対象にする。
	var dirs := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	var counted: Dictionary = {}  # 採用済みセル（複数起点からの重複追加防止）
	for i in range(pair_count):
		var start: Vector2i = source_cells[i]
		if counted.has(start) or not cell_color.has(start):
			continue
		var color = cell_color[start]
		var component: Array[Vector2i] = []
		var visited: Dictionary = {}
		var stack: Array[Vector2i] = [start]
		while not stack.is_empty():
			var c: Vector2i = stack.pop_back()
			if visited.has(c):
				continue
			visited[c] = true
			component.append(c)
			for d in dirs:
				var n: Vector2i = c + d
				if not visited.has(n) and cell_color.has(n) and cell_color[n] == color:
					stack.append(n)
		if component.size() >= threshold:
			for c in component:
				if not counted.has(c):
					counted[c] = true
					out.append(c)
	return out


func _execute_docking(source_tet: Tetromino, target_tet: Tetromino, source_blocks: Array, target_cells: Array, target_data: Dictionary, frame_origin: Vector2, match_block: Node = null) -> bool:
	# 1. source_tet の物理演算と入力を無効化（アニメーション中の干渉を防止）
	source_tet.freeze = true
	source_tet.process_mode = Node.PROCESS_MODE_DISABLED
	
	var base_block = target_data.block
	var base_cell = target_data.cell

	# 補間時間は設定から参照（0なら瞬間移動）。配置ブロック・グリッド吸着で共通利用する。
	var anim_duration: float = 0.15
	if settings != null and settings.get("docking_anim_duration") != null:
		anim_duration = maxf(0.0, settings.docking_anim_duration)

	# 磁力ライン演出のリードイン（線が走ってから引っ張られ始めるまでの溜め）。アニメ無し設定なら0。
	var lead_in: float = 0.09 if anim_duration > 0.01 else 0.0
	# 磁力ライン：判定のきっかけになった「同色で隣接したペア」だけを1本で繋ぐ。
	# 表示位置は“ドッキング後”の最終グリッド位置にする（移動でズレないよう、下のスナップ計算と
	# 同じ式で端点を解析的に求める）。きっかけのソース側ブロックの添字を控えておく。
	var dock_segments: Array = []
	var match_idx: int = source_blocks.find(match_block)
	if match_idx < 0:
		match_idx = 0  # フォールバック：先頭ブロックで代用
	var link_from := Vector2.ZERO
	var link_from_valid := false

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
		tween.tween_property(target_tet, "global_position", target_pos_final, anim_duration).set_delay(lead_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(target_tet, "rotation", target_rot_final, anim_duration).set_delay(lead_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	for i in range(source_blocks.size()):
		var block = source_blocks[i]
		var target_cell = target_cells[i]

		# 検証時と同じ「絶対フレームセル」へ正確に配置する。
		# 結合先が90度回転スナップされても最終グローバル座標が検証済みセルに一致するよう、
		# 絶対セルのワールド座標を、結合先の最終姿勢のローカル座標へ逆変換する。
		var exact_local_pos: Vector2
		var block_final_global: Vector2  # ドッキング後（スナップ後）のこのブロックの最終global座標
		if target_pose_valid and is_instance_valid(pf_node):
			var cell_global: Vector2 = pf_node.to_global(Vector2(target_cell.x * CELL_SIZE, target_cell.y * CELL_SIZE))
			exact_local_pos = (cell_global - target_pos_final).rotated(-target_rot_final)
			block_final_global = cell_global
		else:
			# フォールバック（姿勢算出不可時）：従来どおり結合先ローカルでの差分配置
			var cell_diff = target_cell - base_cell
			exact_local_pos = base_block.position + Vector2(cell_diff.x * CELL_SIZE, cell_diff.y * CELL_SIZE)
			block_final_global = base_block.global_position + Vector2(cell_diff.x * CELL_SIZE, cell_diff.y * CELL_SIZE)

		# 磁力ラインの始点：きっかけのブロックの“ドッキング後”位置を採用（移動後に隣り合う場所）
		if i == match_idx:
			link_from = block_final_global
			link_from_valid = true

		# 移籍による位置ズレを防ぐため、現在の見た目の絶対座標・角度を保存
		var current_global_pos = block.global_position
		var current_global_rot = block.global_rotation

		# ターゲットに移籍
		block.get_parent().remove_child(block)
		target_tet.add_child(block)

		# 一旦元のグローバル座標・角度を復元（見た目を維持）
		block.global_position = current_global_pos
		block.global_rotation = current_global_rot

		# 目標のローカル座標・角度(0.0)へアニメーション（lead_in 分遅らせ、磁力ラインが走ってから引っ張る）
		tween.tween_property(block, "position", exact_local_pos, anim_duration).set_delay(lead_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(block, "rotation", 0.0, anim_duration).set_delay(lead_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# 磁力ラインの終点：結合先ブロックの“ドッキング後”位置（base_cell のグリッド中心）。
	# 始点(link_from)・終点とも最終位置なので、ブロックが移動し終わって本当に隣り合う場所に線が残る。
	if link_from_valid:
		var link_to: Vector2 = base_block.global_position
		if target_pose_valid and is_instance_valid(pf_node):
			link_to = pf_node.to_global(Vector2(base_cell.x * CELL_SIZE, base_cell.y * CELL_SIZE))
		dock_segments.append({"from": link_from, "to": link_to})

	# 磁力ライン演出を再生（線が走る → 引っ張られる → ドッキング後の接合位置でジューシーに消滅）。
	if is_instance_valid(effect_manager) and effect_manager.has_method("play_magnetic_dock"):
		effect_manager.play_magnetic_dock(dock_segments, lead_in, anim_duration)

	# クラッシュ対策：アニメーション中にオブジェクトが破棄される可能性を考慮し、事前にエフェクト再生用の座標をキャッシュしておく
	var snap_effect_pos = source_blocks[0].global_position if not source_blocks.is_empty() else Vector2.ZERO

	# 円形の衝撃波は「ドッキングの線の中央点（接合点）」に出す。
	# 線分の始点(link_from)・終点(link_to)の中点＝MagneticLink が線を吸い込んで消す接合位置と一致する。
	# 線が無い（リンク不成立）ケースはパチッと同じ位置にフォールバック。
	var shockwave_pos: Vector2 = snap_effect_pos
	if not dock_segments.is_empty():
		var seg: Dictionary = dock_segments[0]
		shockwave_pos = (seg["from"] as Vector2).lerp(seg["to"] as Vector2, 0.5)

	# 「パチッ」エフェクトの発火タイミングを、ブロックが着地する瞬間(lead_in + anim_duration)を
	# 基準にオフセットで前後させる。0なら着地と同時、マイナスで着地前、プラスで着地後。
	# アニメ完了コールバックから切り離し、独立した専用Tweenでスケジュールする（位置はキャッシュ済みで安全）。
	var snap_effect_offset: float = 0.0
	if settings != null and settings.get("snap_effect_offset") != null:
		snap_effect_offset = settings.snap_effect_offset
	var snap_at: float = maxf(0.0, lead_in + anim_duration + snap_effect_offset)
	var snap_tween = create_tween().bind_node(target_tet)
	snap_tween.tween_interval(snap_at)
	snap_tween.tween_callback(func():
		if snap_effect_pos == Vector2.ZERO or not is_instance_valid(effect_manager):
			return
		# パチッ（粒子）と円形の衝撃波（リング）を同じ瞬間に一緒に弾けさせる。
		# 衝撃波はドッキング線の中央点（接合点）に出す。
		if effect_manager.has_method("play_snap_particles"):
			effect_manager.play_snap_particles(snap_effect_pos)
		if effect_manager.has_method("play_dock_shockwave"):
			effect_manager.play_dock_shockwave(shockwave_pos)
	)

	# アニメーション完了後の処理を遅延実行
	tween.chain().tween_callback(func():
		if is_instance_valid(target_tet) and target_tet.has_method("_rebuild_internal_arrays"):
			target_tet._rebuild_internal_arrays()

		# ドッキング成立をSE用に通知
		block_docked.emit()

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
# 【救済仕様】上限超過の特例ドッキングで消える予定のセル。暖色の発光で「ここに置けば消える」を予告する。
var _clear_preview_rects: Array[Rect2] = []
var _clear_preview_fill_color: Color = Color(1.0, 0.92, 0.4, 0.4)
var _clear_preview_line_color: Color = Color(1.0, 0.85, 0.25, 0.95)
# デバッグ吸着円を最前面に描くための専用オーバーレイ（枠・ブロックより手前に出す）。_ready で生成。
var _debug_overlay: Node2D = null

func update_docking_preview(source_tet: Tetromino) -> void:
	# ドラッグ中のリアルタイムプレビュー。実際の結合(request_docking)と同じ緩め距離で判定する。
	_preview_rects.clear()
	_clear_preview_rects.clear()
	var eval = _evaluate_docking(source_tet, true)
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
			# 【救済仕様】上限超過の特例ドッキングなら、消える予定の同色連結セルを発光予告する
			if eval.over_limit_clear:
				for cell in eval.clear_cells:
					var exact_global_pos = frame_origin + Vector2(cell.x * CELL_SIZE, cell.y * CELL_SIZE)
					var local_draw_pos = to_local(exact_global_pos)
					_clear_preview_rects.append(Rect2(local_draw_pos - Vector2(half_size, half_size), Vector2(CELL_SIZE, CELL_SIZE)))

	queue_redraw()

func clear_docking_preview() -> void:
	_preview_rects.clear()
	_clear_preview_rects.clear()
	_debug_info.clear()
	queue_redraw()

func _draw() -> void:
	# プレビュー矩形の描画
	for rect in _preview_rects:
		draw_rect(rect, _preview_fill_color, true)
		draw_rect(rect, _preview_line_color, false, 2.0)
	# 「置けば消える」予告セル（特例ドッキング時のみ）。通常プレビューの上から暖色で重ねる
	for rect in _clear_preview_rects:
		draw_rect(rect, _clear_preview_fill_color, true)
		draw_rect(rect, _clear_preview_line_color, false, 3.0)


# デバッグ吸着円・拒否理由を最前面オーバーレイ(_debug_overlay)へ描画する（draw シグナルから呼ばれる）。
# 描画コマンドは「描画中のCanvasItem」に対して発行する必要があるため、self ではなく
# _debug_overlay の draw_* / to_local を用いる（オーバーレイは Board と同一変換なので座標は一致）。
func _on_debug_overlay_draw() -> void:
	if settings == null or not is_instance_valid(_debug_overlay):
		return

	# 調査用：マッチ判定の可視化（所属マス目・充電率・畳み込み・連結数）
	if _is_match_debug_on():
		_draw_match_debug()

	if not settings.show_debug_docking:
		return

	# 赤い円＝通常時（自動結合）の判定距離、橙の円＝プレイヤーがつかんでいる時の判定距離。
	var auto_threshold: float = settings.docking_distance_threshold
	var drag_threshold: float = settings.drag_docking_distance_threshold
	var physics_frame = get_node_or_null("BoardPhysicsFrame")
	if physics_frame:
		for child in get_children():
			if child is Tetromino and child.get("_is_locked"):
				for block in child.get_children():
					if block is CollisionShape2D and not block.disabled:
						var local_pos = _debug_overlay.to_local(block.global_position)
						# 吸着エリアを示す円を描画（赤＝通常 / 橙＝ドラッグ中）
						_debug_overlay.draw_arc(local_pos, auto_threshold, 0, TAU, 32, Color(1, 0, 0, 0.5), 1.0)
						_debug_overlay.draw_arc(local_pos, drag_threshold, 0, TAU, 32, Color(1, 0.6, 0, 0.5), 1.0)

	# 拒否された理由をテキスト表示
	if not _debug_info.is_empty() and not _debug_info.get("can_dock", true):
		var font = ThemeDB.fallback_font
		var points = _debug_info.get("debug_points", [])
		for pt in points:
			var local_pos = _debug_overlay.to_local(pt.pos)
			_debug_overlay.draw_string(font, local_pos + Vector2(0, -20), pt.reason, HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.RED)


# 調査用オーバーレイ：実距離ベースのマッチ判定を可視化する。
# ・黄色の線＝「隣接」とみなされた同色スタック間の連結エッジ（どこまでが一塊と認識されているか）
# ・各ブロックの小円＝状態（黄=マッチ中 / 赤=消去待ち凍結 / 青=非マッチ）＋充電率%
# ・OVLxN＝N個が重なり統合され「1個」として数えられている場所
# ・数字＝連結成分のサイズ（緑=消去閾値以上 / 橙=閾値未満）
func _draw_match_debug() -> void:
	if _debug_match_info.is_empty():
		return
	var font: Font = ThemeDB.fallback_font
	var hold: float = settings.line_clear_hold_time

	# 1. 連結エッジ（実距離で「隣接」と判定された同色ペア）
	for edge in _debug_match_info.get("edges", []):
		var pa: Vector2 = _debug_overlay.to_local(edge["a"])
		var pb: Vector2 = _debug_overlay.to_local(edge["b"])
		_debug_overlay.draw_line(pa, pb, Color(1.0, 0.9, 0.2, 0.7), 2.0)

	# 2. 各ブロックの状態と充電率（Pプレフィックスは消去待ち＝判定除外で凍結中の意味）
	for info in _debug_match_info.get("blocks", []):
		var local_pos: Vector2 = _debug_overlay.to_local(info["pos"])
		var col := Color(0.3, 0.7, 1.0, 0.8)
		if bool(info.get("pending", false)):
			col = Color(1.0, 0.2, 0.2, 1.0)
		elif bool(info.get("matched", false)):
			col = Color(1.0, 0.9, 0.2, 1.0)
		_debug_overlay.draw_arc(local_pos, 5.0, 0, TAU, 16, col, 2.0)
		var pct: int = int(round(clampf(float(info["charge"]) / hold, 0.0, 1.0) * 100.0))
		if pct > 0 or bool(info.get("pending", false)):
			var label: String = ("P" if bool(info.get("pending", false)) else "") + str(pct)
			_debug_overlay.draw_string(font, local_pos + Vector2(-10, -8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.95))

	# 3. 重なり統合（複数ブロックが「1個」として数えられている場所）
	for fold in _debug_match_info.get("folds", []):
		var fpos: Vector2 = _debug_overlay.to_local(fold["pos"])
		_debug_overlay.draw_string(font, fpos + Vector2(-20, 18), "OVLx%d" % [int(fold["count"])], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.3, 0.3, 1.0))

	# 4. 連結成分のサイズ（緑=消去閾値以上 / 橙=閾値未満）
	for comp in _debug_match_info.get("components", []):
		var comp_center: Vector2 = _debug_overlay.to_local(comp["center"])
		var size_n: int = int(comp["size"])
		var size_col := Color(0.4, 1.0, 0.4, 1.0) if size_n >= settings.clear_threshold else Color(1.0, 0.7, 0.2, 1.0)
		_debug_overlay.draw_string(font, comp_center + Vector2(-6, -26), str(size_n), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, size_col)


# 盤面上の非操作ブロック同士を監視し、条件を満たせば自動結合を発火させる（ステップ2）
func _scan_for_auto_docking() -> void:
	for child in get_children():
		if child is Tetromino and child.get("_is_locked"):
			# 自分自身がドラッグ中、アニメーション中、または連鎖ロック中ならスキップ
			if child.get("_is_dragging_by_player") or child.get("_is_docking_animating") or child.get("_is_chain_locked"):
				continue
				
			# 既存の優秀な吸着判定ロジックを流用して周囲を評価（自動結合なので厳しめの距離）
			var eval = _evaluate_docking(child, false)
			# 調査用：至近距離の同色ペアが結合できなかったケースを記録（デッドゾーン検証）
			if not eval.can_dock:
				_log_dock_deadzone(child, eval)
			if eval.can_dock and is_instance_valid(eval.target_tet):
				var target_tet = eval.target_tet
				
				# 相手側もドラッグ中、アニメーション中、または連鎖ロック中ならスキップして競合を防ぐ
				if target_tet.get("_is_dragging_by_player") or target_tet.get("_is_docking_animating") or target_tet.get("_is_chain_locked"):
					continue
					
				# 【仕様確保】ロック済み（鉄枠）の塊が関わる自動結合は行わない。
				# 未ロック同士なら合計が上限を超えてもよい（超えた瞬間にロック化する）。
				# _evaluate_docking 内の判定と同一基準（二重防御）。
				if not child.is_dock_locked() and not target_tet.is_dock_locked():
					# アニメーション中の多重処理（クラッシュ原因）を防ぐため、双方に即座に排他ロックをかける
					child.set("_is_docking_animating", true)
					target_tet.set("_is_docking_animating", true)
					
					# 結合処理を実行
					var physics_frame = get_node_or_null("BoardPhysicsFrame")
					var frame_origin = physics_frame.global_position if physics_frame else Vector2.ZERO
					_execute_docking(child, target_tet, eval.source_blocks, eval.target_cells, eval.target_data, frame_origin, eval.source_match_block)
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
	for child in get_children():
		if child is Tetromino and child.has_method("set_slow_motion"):
			child.set_slow_motion(is_slow)
	_is_slow_motion = is_slow


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
	# 枠（取っ手）を掴んで振り回している間は、速度による除外を無効化する。
	# 通常は「速度が高い＝まだ積まれていない」として判定対象から外すが、その仕様を逆手に取り、
	# 枠を揺すってブロックを飛ばし続ければデッドラインを越えていてもゲームオーバーを回避できてしまう
	# （＝意図しない“枠で耐える”体験）。枠ドラッグ中だけは速度に関わらずライン越えを危険とみなす。
	var ignore_velocity: bool = false
	if settings == null or settings.get("game_over_strict_on_frame_drag") != false:
		var frame := get_node_or_null("BoardPhysicsFrame")
		if frame != null and frame.has_method("is_being_dragged") and frame.is_being_dragged():
			ignore_velocity = true

	for child in get_children():
		if child is Tetromino and child.get("_is_locked"):
			# プレイヤーが操作中のブロックや、ドッキングアニメーション中のものは除外
			var is_dragging = child.get("_is_dragging_by_player") if "_is_dragging_by_player" in child else false
			var is_animating = child.get("_is_docking_animating") if "_is_docking_animating" in child else false
			if is_dragging or is_animating:
				continue

			# 「積まれている」とみなせる速度のブロックを判定対象とする。
			# 物理ベースで常時微振動するため完全静止(=ほぼ0)を条件にすると、揺れた瞬間に
			# 判定対象から外れて危険タイマーがチラついてしまう。しきい値はGameSettingsで調整可能にし、
			# 微振動を許容できる程度に緩く設定する（角速度はその比率で連動させる）。
			var v_threshold: float = 120.0
			if settings != null and settings.get("game_over_velocity_threshold") != null:
				v_threshold = settings.get("game_over_velocity_threshold")
			var v_len = child.linear_velocity.length()
			var a_len = abs(child.angular_velocity)
			var is_settled: bool = v_len < v_threshold and a_len < (v_threshold * 0.1)
			# 通常は静止（積まれている）ブロックのみ、枠ドラッグ中は速度に関わらず判定対象にする。
			if ignore_velocity or is_settled:
				for block in child.get_children():
					if block is CollisionShape2D and not block.disabled:
						# Godotでは画面上部に行くほどY座標が小さくなる
						if block.global_position.y < y_threshold:
							return true
	return false
