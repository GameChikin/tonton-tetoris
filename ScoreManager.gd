extends Node
class_name ScoreManager

@export var score_label_path: NodePath
@export var popup_scene: PackedScene
@export var base_score_per_line: int = 100
@export var line_multipliers: Array[float] = [0.0, 1.0, 1.5, 2.0, 3.0] # 0, 1, 2, 3, 4ライン用

var current_score: int = 0
var displayed_score: int = 0
var _label: Label

func _ready() -> void:
	_label = get_node_or_null(score_label_path) as Label
	_update_label()

func add_score(rule: int, data: Dictionary, popup_position: Vector2) -> void:
	var earned_score: int = 0
	var chain: int = 1
	if data.has("chain"):
		chain = data["chain"]
	
	if rule == 0: # Tetris
		earned_score = _calculate_tetris_score(data)
	elif rule == 1: # Puyo (将来の拡張用)
		earned_score = _calculate_puyo_score(data)
		
	if earned_score <= 0:
		return
		
	current_score += earned_score
	_spawn_popup(popup_position, earned_score, chain)
	_animate_score(earned_score, chain)


func _calculate_tetris_score(data: Dictionary) -> int:
	var lines_cleared: int = data.get("lines", 0)
	var chain: int = data.get("chain", 1)
	if lines_cleared <= 0:
		return 0
		
	var multiplier: float = 1.0
	if lines_cleared < line_multipliers.size():
		multiplier = line_multipliers[lines_cleared]
	else:
		multiplier = line_multipliers[line_multipliers.size() - 1]
		
	return int(base_score_per_line * lines_cleared * multiplier * chain)


func _calculate_puyo_score(data: Dictionary) -> int:
	var puyo_count: int = data.get("puyo_count", 0)
	var chain: int = data.get("chain", 1)
	if puyo_count <= 0:
		return 0
	
	# ぷよ基本スコア: 消去数 * 10 に連鎖倍率を適用
	return puyo_count * 10 * chain

func _spawn_popup(pos: Vector2, score_val: int, chain: int = 1) -> void:
	if popup_scene == null:
		return
		
	var popup = popup_scene.instantiate()
	get_tree().current_scene.add_child(popup)
	popup.global_position = pos
	
	# ラベルのテキスト設定（ノード構造に合わせて適宜調整）
	if popup is Label:
		popup.text = str(score_val)
	elif popup.has_node("Label"):
		popup.get_node("Label").text = str(score_val)

	var chain_clamped = clampi(chain, 1, 5)
	
	# 連鎖数に応じたカラー変化（1:白, 2:黄, 3:オレンジ, 4:赤, 5:紫/発光）
	var colors = [Color.WHITE, Color.YELLOW, Color.ORANGE, Color.RED, Color(0.8, 0.2, 1.0)]
	popup.modulate = colors[chain_clamped - 1]

	# 中央を基準にスケールするための自動設定
	if popup is Control:
		popup.pivot_offset = popup.size / 2.0
		popup.scale = Vector2.ZERO

	var base_scale = 1.0 + (chain_clamped * 0.2)
	var float_height = -50.0 - (chain_clamped * 10.0)
	var fade_delay = 0.4 + (chain_clamped * 0.1)

	var tween = create_tween().set_parallel(true)
	
	# 上昇アニメーション
	tween.tween_property(popup, "position", popup.position + Vector2(0, float_height), 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	
	# 拍動スケールアニメーション
	var scale_tween = create_tween()
	scale_tween.tween_property(popup, "scale", Vector2(base_scale * 1.5, base_scale * 1.5), 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	scale_tween.tween_property(popup, "scale", Vector2(base_scale, base_scale), 0.2).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)

	# フェードアウト（待機時間あり）
	tween.tween_property(popup, "modulate:a", 0.0, 0.3).set_delay(fade_delay)
	
	# アニメーション完了後に安全に破棄
	tween.chain().tween_callback(popup.queue_free)

func _animate_score(added_score: int, chain: int = 1) -> void:
	if _label == null:
		return
	
	# 既存のカウントアップアニメーション
	var tween := create_tween()
	tween.tween_method(_set_displayed_score, displayed_score, current_score, 0.5).set_ease(Tween.EASE_OUT)
	
	if not is_instance_valid(_label):
		return
	
	var chain_clamped = clampi(chain, 1, 5)
	
	# 拡大の基準点を中央に設定
	_label.pivot_offset = _label.size / 2.0
	
	# 既存のアニメーションが実行中であれば破棄（Tweenの競合による描画バグを防止）
	if _label.has_meta("score_pulse_tween"):
		var old_tween = _label.get_meta("score_pulse_tween") as Tween
		if is_instance_valid(old_tween) and old_tween.is_running():
			old_tween.kill()

	var scale_intensity = 1.1 + (chain_clamped * 0.1)
	var pulse_duration = 0.1 + (chain_clamped * 0.02)

	var pulse_tween = create_tween()
	_label.set_meta("score_pulse_tween", pulse_tween)

	# ドクン！（拡大→通常へ収縮）
	pulse_tween.tween_property(_label, "scale", Vector2(scale_intensity, scale_intensity), pulse_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	pulse_tween.tween_property(_label, "scale", Vector2.ONE, pulse_duration * 1.5).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)

func _set_displayed_score(val: int) -> void:
	displayed_score = val
	_update_label()

func _update_label() -> void:
	if _label != null:
		_label.text = str(displayed_score)
