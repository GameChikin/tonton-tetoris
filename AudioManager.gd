extends Node
class_name AudioManager

## BGMと各種SE（効果音）の再生を一手に担うノード。
## Main.tscn 内に配置し、シーン破棄（タイトル遷移・リトライ）と同時にBGMも止まる。
## サウンド設定は GameSettings ではなく専用の SoundSettings リソースから読み込む。

var sound_settings: SoundSettings = preload("res://sound_settings.tres")

var _bgm_player: AudioStreamPlayer
var _dock_player: AudioStreamPlayer
var _break_player: AudioStreamPlayer


func _ready() -> void:
	# 連鎖スロー演出中やメニュー等によるポーズ（時間停止）中でもSEを鳴らせるよう常時処理にする
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_players()


# 3つの AudioStreamPlayer を動的生成し、SoundSettings からストリームと音量を流し込む。
# こうすることでシーン側（Main.tscn）のノード配線は不要になり、調整は sound_settings.tres に閉じる。
func _setup_players() -> void:
	_bgm_player = _create_player("BGMPlayer")
	_dock_player = _create_player("DockPlayer")
	_break_player = _create_player("BreakPlayer")

	if sound_settings == null:
		push_warning("[AudioManager] sound_settings.tres が読み込めませんでした。")
		return

	if sound_settings.bgm_stream != null:
		_bgm_player.stream = sound_settings.bgm_stream
		_bgm_player.volume_db = sound_settings.bgm_volume_db
	if sound_settings.dock_stream != null:
		_dock_player.stream = sound_settings.dock_stream
		_dock_player.volume_db = sound_settings.dock_volume_db
	if sound_settings.break_stream != null:
		_break_player.stream = sound_settings.break_stream
		_break_player.volume_db = sound_settings.break_volume_db


func _create_player(player_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	# プレイヤー自身もポーズを無視して再生を継続させる
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(player)
	return player


# === 公開API ===

## ゲーム本編の開始時に呼ぶ。BGMをループ再生する。
func play_bgm() -> void:
	if not is_instance_valid(_bgm_player) or _bgm_player.stream == null:
		return
	# 二重再生を避ける
	if _bgm_player.playing:
		return
	# ストリーム側のループ設定に依存せず確実にループさせるための保険
	if not _bgm_player.finished.is_connected(_on_bgm_finished):
		_bgm_player.finished.connect(_on_bgm_finished)
	_bgm_player.play()


func _on_bgm_finished() -> void:
	# ループ素材なら finished は飛ばないため、これは非ループ素材時のループ用フォールバック
	if is_instance_valid(_bgm_player) and _bgm_player.stream != null:
		_bgm_player.play()


## ドッキング（吸着結合）成功時に呼ぶ。
func play_dock_se() -> void:
	if not is_instance_valid(_dock_player) or _dock_player.stream == null:
		return
	_dock_player.play()


## ブロック破壊時に呼ぶ。連鎖数に応じてピッチを上げる（SoundSettings.break_pitch_max_chain で頭打ち）。
func play_break_se(chain_count: int) -> void:
	if not is_instance_valid(_break_player) or _break_player.stream == null:
		return
	var pitch: float = 1.0
	if sound_settings != null:
		# 1連鎖目を基準(1.0)とし、連鎖数に応じて段階的に上げる。上限を超えた分は頭打ち。
		var capped: int = mini(maxi(chain_count, 1), sound_settings.break_pitch_max_chain)
		pitch = 1.0 + sound_settings.break_pitch_step * float(capped - 1)
	_break_player.pitch_scale = maxf(0.01, pitch)
	_break_player.play()
