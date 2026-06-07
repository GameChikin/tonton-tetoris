extends Control

@export var endless_button_path: NodePath
@export var timeattack_button_path: NodePath
@export var high_score_label_path: NodePath

func _ready() -> void:
	var endless_btn = get_node_or_null(endless_button_path) as Button
	if is_instance_valid(endless_btn):
		endless_btn.pressed.connect(_on_endless_pressed)

	var timeattack_btn = get_node_or_null(timeattack_button_path) as Button
	if is_instance_valid(timeattack_btn):
		timeattack_btn.pressed.connect(_on_timeattack_pressed)

	var lbl = get_node_or_null(high_score_label_path) as Label
	if is_instance_valid(lbl):
		lbl.text = "High Score: " + str(SaveManager.high_score)

func _on_endless_pressed() -> void:
	SaveManager.selected_mode = SaveManager.GameMode.ENDLESS
	get_tree().change_scene_to_file("res://Main.tscn")

func _on_timeattack_pressed() -> void:
	SaveManager.selected_mode = SaveManager.GameMode.TIME_ATTACK
	get_tree().change_scene_to_file("res://Main.tscn")
