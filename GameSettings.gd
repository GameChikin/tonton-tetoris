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
## 盤面や他のブロックに対して、磁石のように吸着する処理の判定半径です。
@export var magnetic_snap_radius: float = 48.0
## 磁石のような吸着処理が始まってから、完了するまでの時間（秒）です。
@export var magnetic_snap_duration: float = 0.2
## 一度の判定で、同時に自動結合（ドッキング）できるブロックの最大数です。
@export var max_auto_dock_blocks: int = 4

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


func print_all_settings() -> void:
	print("=== GameSettings Current Values ===")
	print("[Board & Game Rules]")
	print("board_width_cells: ", board_width_cells)
	print("board_height_cells: ", board_height_cells)
	print("current_rule: ", "Tetris" if current_rule == 0 else "Puyo")
	print("tonton_drop_speed: ", tonton_drop_speed)
	print("tonton_drop_distance: ", tonton_drop_distance)
	print("clear_threshold: ", clear_threshold)
	print("line_clear_hold_time: ", line_clear_hold_time)
	print("board_width_px: ", board_width_px)
	
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
	print("===================================")
