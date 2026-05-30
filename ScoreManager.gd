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
	
	if rule == 0: # Tetris
		earned_score = _calculate_tetris_score(data)
	elif rule == 1: # Puyo (将来の拡張用)
		earned_score = _calculate_puyo_score(data)
		
	if earned_score <= 0:
		return
		
	current_score += earned_score
	_spawn_popup(earned_score, popup_position)
	_animate_score()


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

func _spawn_popup(earned: int, pos: Vector2) -> void:
	if popup_scene == null:
		return
	var popup: Node = popup_scene.instantiate()
	if popup is Control:
		popup.position = pos
		if popup.has_method("set_score_text"):
			popup.call("set_score_text", "+" + str(earned))
		elif popup is Label:
			popup.text = "+" + str(earned)
	elif popup is Node2D:
		popup.position = pos
		for child in popup.get_children():
			if child is Label:
				child.text = "+" + str(earned)
	add_child(popup)
	
	var tween := create_tween()
	tween.tween_property(popup, "position:y", pos.y - 50.0, 1.0).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.parallel().tween_property(popup, "modulate:a", 0.0, 1.0).set_ease(Tween.EASE_IN)
	# 確実な破棄処理（安全性向上）
	tween.tween_callback(func():
		if is_instance_valid(popup):
			popup.queue_free()
	)

func _animate_score() -> void:
	if _label == null:
		return
	var tween := create_tween()
	tween.tween_method(_set_displayed_score, displayed_score, current_score, 0.5).set_ease(Tween.EASE_OUT)

func _set_displayed_score(val: int) -> void:
	displayed_score = val
	_update_label()

func _update_label() -> void:
	if _label != null:
		_label.text = str(displayed_score)
