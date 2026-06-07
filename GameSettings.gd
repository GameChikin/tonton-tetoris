extends Resource
class_name GameSettings

@export_group("Board & Game Rules")
## 盤面の横幅（マス数）です。数値を変更すると、壁や背景が自動でリサイズされます。
@export var board_width_cells: int = 10
## 盤面の高さ（マス数）です。
@export var board_height_cells: int = 20
## 現在のゲームルールです。0がテトリス風（横一列で消去）、1がぷよぷよ風（隣接数で消去）として扱われます。
@export_enum("Tetris", "Puyo") var current_rule: int = 0
## 下入力でブロックを叩き落とす（トントン落下）際の、落下の速さです。
@export var tonton_drop_speed: float = 0.02
## トントン落下が発動した際に、一度に落下させる距離（ピクセル）です。
@export var tonton_drop_distance: int = 20
## ブロックが消滅するために必要な条件です（テトリスなら横一列に必要なマス数、ぷよぷよなら隣接必要なブロック数）。
@export var clear_threshold: int = 8
## ブロックの抽選に使用する色の種類数です（2〜12）。多いほど同色が揃いにくく難しく、少ないほど易しくなります。
@export_range(2, 12) var block_color_count: int = 7
## ブロックが揃ってから、実際に消滅（爆発）するまでの待機時間（秒）です。連鎖の演出に使われます。
@export var line_clear_hold_time: float = 1.5
## 盤面の物理的な横幅（ピクセル）です。当たり判定やUIの基準サイズとして使用されます。
@export var board_width_px: float = 320.0
## ブロック消滅時や激しい衝突時に発生する、衝撃波エフェクトの判定半径です。
@export var shockwave_radius: float = 96.0
## 衝撃波エフェクトを描画する際の、半透明度（0.0〜1.0）です。
@export var shockwave_fill_alpha: float = 0.3
## 連鎖が発生した際、次の連鎖判定が行われるまでの間隔（秒）です。
@export var chain_interval_time: float = 0.3

@export_group("Spawn Settings")
## ゲーム開始時のブロック生成間隔（秒）です。
@export var base_spawn_interval: float = 3.0
## 難易度が上がり、生成が早くなるまでの経過時間（秒）です。
@export var spawn_speedup_interval: float = 15.0
## 1回の難易度上昇で短縮される時間（秒）です。
@export var spawn_speedup_amount: float = 0.2
## 自然生成間隔の限界値（これ以上は速くならない下限値）です。
@export var min_spawn_interval: float = 1.0
## スペースキー（早送り）を押している間の生成間隔（秒）です。
@export var fast_forward_spawn_interval: float = 0.15

@export_group("Tetromino Physics & Snap")
## ブロックの移動速度がこの値を下回ると、「静止した」とみなされやすくなります。
@export var sleep_threshold_velocity: float = 15.0
## 速度がしきい値を下回ってから、実際に物理演算がスリープ（盤面にロック）されるまでの猶予時間（秒）です。
@export var sleep_delay_time: float = 0.2
## ブロックが空中で正しい角度（90度単位）に自動補正されようとする力の強さです。
@export var snap_rotation_strength: float = 12.0
## 角度の自動補正が有効になる、ズレの限界角度（度）です。これ以上傾いていると補正されません。
@export var snap_rotation_limit: float = 25.0
## ブロックがマスの中心（X座標）に自動で引き寄せられる力の強さです。
@export var snap_x_strength: float = 8.0
## X座標の引き寄せが有効になる、マス中心からのズレの限界距離（ピクセル）です。
@export var snap_x_limit: float = 12.0
## 一度の判定で、同時に自動結合（ドッキング）できるブロックの最大数です。
@export var max_auto_dock_blocks: int = 4
## ドッキング時に、結合先をグリッドへ吸着させ、ブロックを所定位置へ移動させる補間アニメーションの時間（秒）です。
## 0にすると瞬間移動（アニメなし）になります。
@export var docking_anim_duration: float = 0.15

@export_group("AI Settings")
## AIによる自動操作（デモプレイや敵など）を有効にするかどうかの設定です。
@export var ai_enabled: bool = true
## AIが次の行動（移動や回転）を起こすまでの思考時間・待機時間（秒）です。短いほど強くなります。
@export var ai_action_delay: float = 0.5
## AIがブロックを落下させる際などの、基準点（中心）からの横ズレの許容幅です。
@export var drop_center_offset: float = 160.0

@export_group("Game Over Settings")
## ゲームオーバー判定となるデッドラインの高さ（Boardの中心からの相対距離）です。マイナス値で上方向を指定します。
@export var game_over_y_threshold: float = -300.0
## ブロックがデッドラインを越えてから、実際にゲームオーバーになるまでの猶予時間（秒）です。
@export var game_over_grace_period: float = 2.0

@export_group("Time Attack")
## タイムアタックモードの制限時間（秒）です。0になった瞬間にゲームオーバーになります。
@export var time_attack_duration: float = 120.0

@export_group("Board Handle (Drag Grip)")
## 盤面を掴んで動かす「持ち手（ジョッキの取っ手）」の大きさ（半径ピクセル）です。大きいほど掴みやすくなります。
@export var handle_radius: float = 60.0
## 持ち手（取っ手）の太さ（ピクセル）です。
@export var handle_thickness: float = 16.0
## 持ち手を盤面の下端からどれだけ上に配置するかの距離（ピクセル）です。0なら最下部に寄ります。
@export var handle_bottom_margin: float = 40.0
## 持ち手（取っ手）の表示色です。
@export var handle_color: Color = Color(0.85, 0.65, 0.3, 1.0)
## 枠（壁）をドラッグで動かす際の最大追従速度（px/秒）です。
## 0 = 即時追従（クランプ無効＝マウスに最も鋭敏に反応。推奨）。
## すり抜け防止は sync_to_physics と封じ込め安全網が担うため、通常は 0 でよい。
## 正の値を入れた時だけ、その速度で追従を平滑化（鈍く）します。
@export var max_frame_drag_speed: float = 0.0
## 枠をドラッグで動かせる範囲のマージン（ピクセル）です。
## 枠＋取っ手が画面端からこの距離より内側に収まるよう、可動範囲をクランプします。
@export var frame_drag_screen_margin: float = 24.0
## 枠をドラッグしたとき、中のブロックが付いて来る「結合力（粘性ドラッグ）の強さ」です。
## チャーハンの鍋を振ると米が遅れて付いてくるような、慣性のある追従を生みます。
## 速度を上書きせず力を加えるだけなので、重力など本来の物理はそのまま生きます。
## 小さいほど“もっさり遅れて”、大きいほどキビキビ追従します（単位: 1/秒）。
## 0 = 追従なし（純粋な物理のみ）。目安: 2.0≒0.5秒で追いつく / 4.0≒0.25秒。
@export_range(0.0, 20.0, 0.5) var frame_drag_follow_strength: float = 2.0

@export_group("Debug")
## デバッグ用：盤面テンプレートを選択するボタン（画面左上のパネル）を表示するかどうかです。
## リリース時（itch公開など）はオフにしてプレイヤーから隠してください。
@export var show_debug_presets: bool = true


func print_all_settings() -> void:
	print("=== GameSettings Current Values ===")
	print("[Board & Game Rules]")
	print("board_width_cells: ", board_width_cells)
	print("board_height_cells: ", board_height_cells)
	print("current_rule: ", "Tetris" if current_rule == 0 else "Puyo")
	print("tonton_drop_speed: ", tonton_drop_speed)
	print("tonton_drop_distance: ", tonton_drop_distance)
	print("clear_threshold: ", clear_threshold)
	print("block_color_count: ", block_color_count)
	print("line_clear_hold_time: ", line_clear_hold_time)
	print("board_width_px: ", board_width_px)
	print("max_frame_drag_speed: ", max_frame_drag_speed)
	
	print("[Tetromino Physics & Snap]")
	print("sleep_threshold_velocity: ", sleep_threshold_velocity)
	print("sleep_delay_time: ", sleep_delay_time)
	print("snap_rotation_strength: ", snap_rotation_strength)
	print("snap_rotation_limit: ", snap_rotation_limit)
	print("snap_x_strength: ", snap_x_strength)
	print("snap_x_limit: ", snap_x_limit)
	print("max_auto_dock_blocks: ", max_auto_dock_blocks)
	
	print("[AI Settings]")
	print("ai_enabled: ", ai_enabled)
	print("ai_action_delay: ", ai_action_delay)
	print("drop_center_offset: ", drop_center_offset)
	print("[Debug]")
	print("show_debug_presets: ", show_debug_presets)
	print("===================================")
