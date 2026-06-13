extends Control

@export var endless_button_path: NodePath
@export var timeattack_button_path: NodePath
@export var high_score_label_path: NodePath
## サウンドのON/OFFを切り替えるボタンへのパスです（OPTIONウィンドウ内）。
@export var mute_button_path: NodePath
## OPTIONウィンドウを開くボタンへのパスです。
@export var option_button_path: NodePath
## OPTIONウィンドウ（サウンド・解像度をまとめたパネル）本体へのパスです。
@export var option_panel_path: NodePath
## 解像度を選択するドロップダウン（OptionButton）へのパスです。
@export var resolution_dropdown_path: NodePath
## OPTIONウィンドウを閉じるボタンへのパスです。
@export var option_close_button_path: NodePath
## 操作チュートリアル（ビジュアル説明）を開くHELPボタンへのパスです。
@export var help_button_path: NodePath
## チュートリアル本体（TutorialUI）へのパスです。
@export var tutorial_path: NodePath

var _mute_btn: Button
var _option_panel: Control
var _resolution_dropdown: OptionButton
var _tutorial: TutorialUI


func _ready() -> void:
	var endless_btn = get_node_or_null(endless_button_path) as Button
	if is_instance_valid(endless_btn):
		endless_btn.pressed.connect(_on_endless_pressed)

	var timeattack_btn = get_node_or_null(timeattack_button_path) as Button
	if is_instance_valid(timeattack_btn):
		timeattack_btn.pressed.connect(_on_timeattack_pressed)

	# モード別ハイスコアを並記する（エンドレスとタイムアタックは別記録）。
	# 数字部分だけ黄色にするため、Label ではなく RichTextLabel + BBCode で表示する。
	# 黄色は実プレイ中のスコア表示（ScoreLabel）と同じビビッドな黄色に揃える。
	var lbl = get_node_or_null(high_score_label_path) as RichTextLabel
	if is_instance_valid(lbl):
		lbl.text = "[center]HIGH SCORE   ENDLESS: [color=#fefb00]%d[/color]   /   TIME ATTACK: [color=#fefb00]%d[/color][/center]" % [
			SaveManager.high_score_endless, SaveManager.high_score_time_attack
		]

	_mute_btn = get_node_or_null(mute_button_path) as Button
	if is_instance_valid(_mute_btn):
		_mute_btn.pressed.connect(_on_mute_pressed)
		_update_mute_label()

	# --- OPTIONウィンドウ（サウンド＋解像度）---
	_option_panel = get_node_or_null(option_panel_path) as Control

	var option_btn = get_node_or_null(option_button_path) as Button
	if is_instance_valid(option_btn):
		option_btn.pressed.connect(_on_option_pressed)

	var close_btn = get_node_or_null(option_close_button_path) as Button
	if is_instance_valid(close_btn):
		close_btn.pressed.connect(_on_option_close_pressed)

	_setup_resolution_dropdown()

	# --- 操作チュートリアル（HELP）---
	_tutorial = get_node_or_null(tutorial_path) as TutorialUI
	var help_btn = get_node_or_null(help_button_path) as Button
	if is_instance_valid(help_btn):
		help_btn.pressed.connect(_on_help_pressed)


# 解像度ドロップダウンへ SaveManager のプリセット一覧を流し込み、保存済みの選択を復元する。
# Web版はブラウザがキャンバスサイズを決めるため変更できず、誤解を防ぐために行ごと非表示にする。
func _setup_resolution_dropdown() -> void:
	_resolution_dropdown = get_node_or_null(resolution_dropdown_path) as OptionButton
	if not is_instance_valid(_resolution_dropdown):
		return
	if OS.has_feature("web"):
		var row := _resolution_dropdown.get_parent() as Control
		if is_instance_valid(row):
			row.visible = false
		return
	for preset: Vector2i in SaveManager.RESOLUTION_PRESETS:
		_resolution_dropdown.add_item("%d x %d" % [preset.x, preset.y])
	_resolution_dropdown.select(SaveManager.resolution_index)
	_resolution_dropdown.item_selected.connect(_on_resolution_selected)


func _on_endless_pressed() -> void:
	SaveManager.selected_mode = SaveManager.GameMode.ENDLESS
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_timeattack_pressed() -> void:
	SaveManager.selected_mode = SaveManager.GameMode.TIME_ATTACK
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_option_pressed() -> void:
	if is_instance_valid(_option_panel):
		_option_panel.visible = true


func _on_option_close_pressed() -> void:
	if is_instance_valid(_option_panel):
		_option_panel.visible = false


func _on_resolution_selected(index: int) -> void:
	SaveManager.set_resolution_index(index)


func _on_help_pressed() -> void:
	if is_instance_valid(_tutorial):
		_tutorial.open()


func _on_mute_pressed() -> void:
	SaveManager.toggle_mute()
	_update_mute_label()


func _update_mute_label() -> void:
	if is_instance_valid(_mute_btn):
		_mute_btn.text = "SOUND: OFF" if SaveManager.is_muted else "SOUND: ON"
