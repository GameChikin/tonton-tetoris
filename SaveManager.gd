extends Node

const SAVE_FILE_PATH = "user://save_data.save"

## ゲームモード。タイトル画面で選択し、Mainシーンで参照する。
enum GameMode { ENDLESS, TIME_ATTACK }
## タイトルで選ばれたモード（シーン遷移をまたいで保持する）
var selected_mode: int = GameMode.ENDLESS

## モード別ハイスコア。エンドレス（無制限）とタイムアタック（90秒）はスコアの土俵が
## 違うため、同じ記録を取り合わないようモードごとに分けて保持・保存する。
var high_score_endless: int = 0
var high_score_time_attack: int = 0
var max_chain_all_time: int = 0
## サウンドのミュート状態。タイトル／ゲーム内メニューのボタンで切り替え、
## 保存して次回起動時も維持する（ブラウザ公開時のプレイヤー配慮）。
var is_muted: bool = false


func _ready() -> void:
	load_data()


func load_data() -> void:
	if FileAccess.file_exists(SAVE_FILE_PATH):
		var file: FileAccess = FileAccess.open(SAVE_FILE_PATH, FileAccess.READ)
		var data: Variant = file.get_var()
		if data is Dictionary:
			# 旧形式（"high_score" 単一キー）のセーブはエンドレスの記録として引き継ぐ
			high_score_endless = data.get("high_score_endless", data.get("high_score", 0))
			high_score_time_attack = data.get("high_score_time_attack", 0)
			max_chain_all_time = data.get("max_chain", 0)
			is_muted = data.get("is_muted", false)
	# 起動直後から保存済みのミュート状態を音声バスへ反映する
	apply_mute()


func save_data() -> void:
	var file: FileAccess = FileAccess.open(SAVE_FILE_PATH, FileAccess.WRITE)
	var data: Dictionary = {
		"high_score_endless": high_score_endless,
		"high_score_time_attack": high_score_time_attack,
		"max_chain": max_chain_all_time,
		"is_muted": is_muted,
	}
	file.store_var(data)


## 現在選択中のモードのハイスコアを返す
func get_high_score() -> int:
	if selected_mode == GameMode.TIME_ATTACK:
		return high_score_time_attack
	return high_score_endless


func update_score(current_score: int, current_max_chain: int) -> void:
	var updated: bool = false
	if current_score > get_high_score():
		if selected_mode == GameMode.TIME_ATTACK:
			high_score_time_attack = current_score
		else:
			high_score_endless = current_score
		updated = true
	if current_max_chain > max_chain_all_time:
		max_chain_all_time = current_max_chain
		updated = true

	if updated:
		save_data()


## ミュート状態を反転して適用・保存する。切り替え後の状態を返す。
func toggle_mute() -> bool:
	is_muted = not is_muted
	apply_mute()
	save_data()
	return is_muted


## 記憶しているミュート状態をMasterバスへ反映する（BGM・SEすべてに効く）
func apply_mute() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), is_muted)
