extends Control

@export var start_button_path: NodePath
@export var high_score_label_path: NodePath

func _ready() -> void:
	var btn = get_node_or_null(start_button_path) as Button
	if is_instance_valid(btn):
		btn.pressed.connect(_on_start_pressed)
		
	var lbl = get_node_or_null(high_score_label_path) as Label
	if is_instance_valid(lbl):
		lbl.text = "High Score: " + str(SaveManager.high_score)

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://Main.tscn")
