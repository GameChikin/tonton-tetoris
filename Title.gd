extends Control

@export var endless_button_path: NodePath
@export var timeattack_button_path: NodePath
@export var high_score_label_path: NodePath
## サウンドのON/OFFを切り替えるボタンへのパスです。
@export var mute_button_path: NodePath

var _mute_btn: Button


func _ready() -> void:
	var endless_btn = get_node_or_null(endless_button_path) as Button
	if is_instance_valid(endless_btn):
		endless_btn.pressed.connect(_on_endless_pressed)

	var timeattack_btn = get_node_or_null(timeattack_button_path) as Button
	if is_instance_valid(timeattack_btn):
		timeattack_btn.pressed.connect(_on_timeattack_pressed)

	# モード別ハイスコアを並記する（エンドレスとタイムアタックは別記録）
	var lbl = get_node_or_null(high_score_label_path) as Label
	if is_instance_valid(lbl):
		lbl.text = "HIGH SCORE   ENDLESS: %d   /   TIME ATTACK: %d" % [
			SaveManager.high_score_endless, SaveManager.high_score_time_attack
		]

	_mute_btn = get_node_or_null(mute_button_path) as Button
	if is_instance_valid(_mute_btn):
		_mute_btn.pressed.connect(_on_mute_pressed)
		_update_mute_label()


func _on_endless_pressed() -> void:
	SaveManager.selected_mode = SaveManager.GameMode.ENDLESS
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_timeattack_pressed() -> void:
	SaveManager.selected_mode = SaveManager.GameMode.TIME_ATTACK
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_mute_pressed() -> void:
	SaveManager.toggle_mute()
	_update_mute_label()


func _update_mute_label() -> void:
	if is_instance_valid(_mute_btn):
		_mute_btn.text = "SOUND: OFF" if SaveManager.is_muted else "SOUND: ON"
