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

func add_score_for_lines(lines_cleared: int, popup_position: Vector2) -> void:
	if lines_cleared <= 0:
		return
		
	var multiplier: float = 1.0
	if lines_cleared < line_multipliers.size():
		multiplier = line_multipliers[lines_cleared]
	else:
		multiplier = line_multipliers[line_multipliers.size() - 1]
		
	var earned_score: int = int(base_score_per_line * lines_cleared * multiplier)
	current_score += earned_score
	
	_spawn_popup(earned_score, popup_position)
	_animate_score()

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
	tween.tween_callback(popup.queue_free)

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
