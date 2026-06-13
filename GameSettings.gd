extends Resource
class_name GameSettings

@export_group("Board & Game Rules")
## 盤面の横幅（マス数）です。数値を変更すると、壁や背景が自動でリサイズされます。
@export var board_width_cells: int = 10
## 盤面の高さ（マス数）です。
@export var board_height_cells: int = 20
## 現在のゲームルールです。0がテトリス風（横一列で消去）、1がぷよぷよ風（隣接数で消去）として扱われます。
@export_enum("Tetris", "Puyo") var current_rule: int = 0
## ブロックが消滅するために必要な条件です（テトリスなら横一列に必要なマス数、ぷよぷよなら隣接必要なブロック数）。
@export var clear_threshold: int = 8
## ブロックの抽選に使用する色の種類数です（2〜12）。多いほど同色が揃いにくく難しく、少ないほど易しくなります。
@export_range(2, 12) var block_color_count: int = 7
## ブロックが揃ってから、実際に消滅（爆発）するまでの待機時間（秒）です。連鎖の演出に使われます。
@export var line_clear_hold_time: float = 1.5
## 盤面の物理的な横幅（ピクセル）です。当たり判定やUIの基準サイズとして使用されます。
## ※実行時に board_width_cells × セルサイズ で自動的に上書きされるため、インスペクタでの手動編集は反映されません（ランタイム用キャッシュ）。
@export var board_width_px: float = 320.0
## ブロック消滅時や激しい衝突時に発生する、衝撃波エフェクトの判定半径です。
@export var shockwave_radius: float = 96.0
## 衝撃波エフェクトを描画する際の、半透明度（0.0〜1.0）です。
@export var shockwave_fill_alpha: float = 0.3
## ドッキング成立時に「パチッ」と同時に弾ける、円形の衝撃波（リング）の最大半径です。
## 消去時の衝撃波(shockwave_radius)とは独立。0にするとリングを出しません。
@export var dock_shockwave_radius: float = 64.0
## 連鎖が発生した際、次の連鎖判定が行われるまでの間隔（秒）です。
@export var chain_interval_time: float = 0.3
## ぷよ消去の「隣接」とみなすブロック中心間の実距離（ピクセル）です。マス目への丸めではなく
## 実際の距離で連結を判定するため、ブロックが傾いて積まれていても見た目どおりに数えられます。
## ぴったり隣接静止＝32px、斜め接触＝約45px なので、その間（36〜40）に設定してください。
@export var match_connect_distance: float = 36.0
## この距離（ピクセル）以内に重なり合った同色ブロックを「1個」として数える統合距離です。
## 物理的なめり込みやテレポートで重なったブロックが、連結数を水増しして
## 「見た目4個未満なのに消える」のを防ぎます（旧・セル畳み込みの距離版）。
@export var match_overlap_merge_distance: float = 16.0

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
## プレイヤーのブロックが出現する位置の、枠（盤面）中心を基準とした横オフセット（ピクセル）です。
## 0で枠の基準点と同じX、プラスで右、マイナスで左にずれます。盤面中心に出したいときの目安は160前後。
## 枠をドラッグで動かすと出現位置もそれに追従します（AIのdrop_center_offsetと同じ枠基準）。
@export var spawn_center_offset_x: float = 160.0
## プレイヤーのブロックが出現する位置の、枠（盤面）基準点からの縦オフセット（ピクセル）です。
## 0で枠の基準点と同じY、プラスで下、マイナスで上にずれます。盤面上部から落としたいときに調整してください。
## X同様、枠をドラッグで動かすと出現位置も追従します。
@export var spawn_center_offset_y: float = 0.0

@export_group("Tetromino Physics & Snap")
## ブロックが空中で正しい角度（90度単位）に自動補正されようとする力の強さです。
@export var snap_rotation_strength: float = 12.0
## 角度の自動補正が有効になる、ズレの限界角度（度）です。これ以上傾いていると補正されません。
@export var snap_rotation_limit: float = 25.0
## ブロックがマスの中心（X座標）に自動で引き寄せられる力の強さです。
@export var snap_x_strength: float = 8.0
## X座標の引き寄せが有効になる、マス中心からのズレの限界距離（ピクセル）です。
@export var snap_x_limit: float = 12.0

@export_group("Docking Settings")
## 吸着（ドッキング）判定の距離しきい値（ピクセル）。【通常時＝盤面上の自動結合】に使われます。
## 小さくするほど、放置したブロック同士が勝手にくっつきにくくなります。
@export var docking_distance_threshold: float = 38.0
## 吸着（ドッキング）判定の距離しきい値（ピクセル）。【プレイヤーがつかんで動かしている時】に使われます。
## 通常時より大きくするほど、少し離れていても気持ちよく吸い付いて結合します。
@export var drag_docking_distance_threshold: float = 60.0
## 同色ブロックとしか結合（ドッキング）できないようにするかどうかです。
@export var require_same_color: bool = true
## 塊がロック（鉄枠）になるブロック数です。この数以上の塊は、手動ドラッグの
## 「置けば即消える」特例を除き、それ以上結合できなくなります。
## 未ロックの塊同士は合計がこの数を超えても結合でき、超えた瞬間にロック化します
## （塊の最大サイズはおよそ この数-1+ピースサイズ に収まります）。
@export var max_auto_dock_blocks: int = 4
## ドッキング時に、結合先をグリッドへ吸着させ、ブロックを所定位置へ移動させる補間アニメーションの時間（秒）です。
## 0にすると瞬間移動（アニメなし）になります。
@export var docking_anim_duration: float = 0.15
## 「パチッ」とはじけるエフェクトを、ブロックが所定位置に着地した瞬間を基準に何秒ずらすかです。
## 0=着地と同時。マイナス=着地直前に弾けて先取り感（アンティシペーション）。プラス=着地後に一拍おいてタメ感。
## アニメ時間(docking_anim_duration)を変えても自動で着地と同期するので、ここは微調整だけで済みます。
@export var snap_effect_offset: float = 0.0
## デバッグ用：吸着判定エリア（赤い円）と、結合できなかった理由を画面に描画するかどうかです。
@export var show_debug_docking: bool = false

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
## ラインより下に戻った時、危険タイマー（赤い警告）が回復する速さの倍率です。
## 1.0なら越えていた時間と同じ速さで戻り、大きいほど早く回復します。0にすると一切回復しません。
@export var game_over_recovery_rate: float = 1.5
## デッドライン判定の対象とするブロックの最大速度(px/s)です。これ以下の速度なら「積まれている」とみなし判定対象にします。
## 物理ベースで常に微振動するため、ある程度大きい値にしないと揺れた瞬間に判定対象から外れてしまいます。
@export var game_over_velocity_threshold: float = 120.0
## 連鎖終了後、デッドライン判定の再開を遅らせる「沈静化（settle）猶予」の秒数です。
## 連鎖直後はブロックが崩落・バウンドの最中で、速度が低く＆ライン上にある一瞬を誤って拾いがちです。
## この時間だけ判定を凍結し、物理が落ち着いてから判定を再開することで意図しないゲームオーバーを防ぎます。
@export var game_over_chain_settle_time: float = 0.6
## 枠（取っ手）を掴んでドラッグしている間は、速度による除外を無効化してデッドライン越えを厳格に判定するかどうかです。
## ON にすると「枠を振り回してブロックを飛ばし続け、速度除外で耐える」抜け道をふさぎます。
## OFF にすると従来通り、ドラッグ中でも高速なブロックは判定対象から外れます（耐えやすくなります）。
@export var game_over_strict_on_frame_drag: bool = true

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

@export_group("Block Visuals")
## ブロック同士の境界線（塊の内部の区切り線）の太さ（ピクセル）です。0にすると区切り線を描きません。
@export var block_inner_line_width: float = 2.0
## ブロック同士の境界線の色です。半透明の黒にすると、どの色のブロックでも自然になじみます。
@export var block_inner_line_color: Color = Color(0.0, 0.0, 0.0, 0.45)
## 塊（結合済みブロックのまとまり）の外周線の太さ（ピクセル）です。太いほど漫画的なくっきりした輪郭になります。
@export var block_outline_width: float = 4.0
## 塊の外周線の色です。消去待ちの白発光と見分けがつくよう、黒系を推奨します。
@export var block_outline_color: Color = Color(0.05, 0.05, 0.08, 0.95)
## 各ブロック上部のツヤ（白いハイライト）の濃さ（0.0〜1.0）です。0でツヤなし、大きいほどキャンディのような光沢になります。
@export_range(0.0, 1.0, 0.05) var block_gloss_strength: float = 0.35
## 各ブロック下部の影の濃さ（0.0〜1.0）です。0で影なし。ツヤと合わせてゼリーのような立体感を出します。
@export_range(0.0, 1.0, 0.05) var block_shade_strength: float = 0.18

@export_group("Tutorial")
## チュートリアル（HELPで開く操作説明）のループアニメ全体の再生速度です。
## 1.0が標準。大きいほどデモが速く動き、小さいほどゆっくり丁寧に見えます。
@export_range(0.2, 3.0, 0.1) var tutorial_anim_speed: float = 1.0

@export_group("Debug")
## デバッグ用：盤面テンプレートを選択するボタン（画面左上のパネル）を表示するかどうかです。
## リリース時（itch公開など）はオフにしてプレイヤーから隠してください。
@export var show_debug_presets: bool = true
## デバッグ用：ゲームオーバー判定を無効化（無敵化）するかどうかです。
## ON にすると、デッドライン超過でもタイムアタックの時間切れでもゲームオーバーになりません。
## 演出や連鎖・結合の挙動をじっくり観察するための調査用スイッチです。リリース時は必ずオフに戻してください。
@export var debug_invincible: bool = false
## デバッグ用（原因調査）：ぷよマッチ判定の詳細を画面に可視化し、調査ログをコンソールへ出力するかどうかです。
## 各ブロックの「所属マス目（黄=マッチ中／赤=消去待ち凍結／青=非マッチ）」「充電率%」「FOLD=同一マス畳み込み」
## 「連結数」を描画し、発火しないマッチ・結合デッドゾーン・連鎖キュー滞留をコンソールへ出力します。
## 調査が終わったら必ずオフに戻してください。
@export var show_debug_matching: bool = false


func print_all_settings() -> void:
	print("=== GameSettings Current Values ===")
	print("[Board & Game Rules]")
	print("board_width_cells: ", board_width_cells)
	print("board_height_cells: ", board_height_cells)
	print("current_rule: ", "Tetris" if current_rule == 0 else "Puyo")
	print("clear_threshold: ", clear_threshold)
	print("block_color_count: ", block_color_count)
	print("line_clear_hold_time: ", line_clear_hold_time)
	print("board_width_px: ", board_width_px)
	print("max_frame_drag_speed: ", max_frame_drag_speed)
	print("[Spawn Settings]")
	print("spawn_center_offset_x: ", spawn_center_offset_x)
	print("spawn_center_offset_y: ", spawn_center_offset_y)
	print("[Tetromino Physics & Snap]")
	print("snap_rotation_strength: ", snap_rotation_strength)
	print("snap_rotation_limit: ", snap_rotation_limit)
	print("snap_x_strength: ", snap_x_strength)
	print("snap_x_limit: ", snap_x_limit)
	print("[Docking Settings]")
	print("docking_distance_threshold: ", docking_distance_threshold)
	print("drag_docking_distance_threshold: ", drag_docking_distance_threshold)
	print("require_same_color: ", require_same_color)
	print("max_auto_dock_blocks: ", max_auto_dock_blocks)
	print("docking_anim_duration: ", docking_anim_duration)
	print("snap_effect_offset: ", snap_effect_offset)
	print("dock_shockwave_radius: ", dock_shockwave_radius)
	print("show_debug_docking: ", show_debug_docking)
	
	print("[AI Settings]")
	print("ai_enabled: ", ai_enabled)
	print("ai_action_delay: ", ai_action_delay)
	print("drop_center_offset: ", drop_center_offset)
	print("[Game Over Settings]")
	print("game_over_y_threshold: ", game_over_y_threshold)
	print("game_over_grace_period: ", game_over_grace_period)
	print("game_over_recovery_rate: ", game_over_recovery_rate)
	print("game_over_velocity_threshold: ", game_over_velocity_threshold)
	print("game_over_chain_settle_time: ", game_over_chain_settle_time)
	print("game_over_strict_on_frame_drag: ", game_over_strict_on_frame_drag)
	print("[Debug]")
	print("show_debug_presets: ", show_debug_presets)
	print("===================================")
