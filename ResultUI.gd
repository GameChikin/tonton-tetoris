extends CanvasLayer
## ゲームオーバー時に表示するリザルトウィンドウ。
## 黒い半透明のウィンドウにスコア／ハイスコアとボタン群をまとめて表示する。
## 数値の反映は Main.game_over() から show_result() を呼んで行う（直接 Label を触らせない）。

# 各ラベルへの参照。シーン内の子ノードなので @onready + 生存チェックで安全に取得する。
@onready var _title_label: Label = get_node_or_null("Window/Margin/VBox/TitleLabel")
@onready var _score_label: Label = get_node_or_null("Window/Margin/VBox/ScoreLabel")
# ハイスコアは数字だけ黄色にするため RichTextLabel（BBCode）で表示する。
@onready var _high_score_label: RichTextLabel = get_node_or_null("Window/Margin/VBox/HighScoreLabel")


## リザルト内容を反映してウィンドウを表示する。
## max_chain は現状ウィンドウには出していないが、将来の拡張に備えて引数で受け取っておく。
## is_time_up: タイムアタックの制限時間切れなら true（見出しを「TIME UP」にする）。
func show_result(score: int, _max_chain: int, high_score: int, is_time_up: bool = false) -> void:
	if is_instance_valid(_title_label):
		_title_label.text = "TIME UP" if is_time_up else "GAME OVER"
	if is_instance_valid(_score_label):
		_score_label.text = "SCORE  %d" % score
	if is_instance_valid(_high_score_label):
		# 数字部分だけ黄色（タイトルのハイスコア表示と同じビビッドな黄色）にする。
		_high_score_label.text = "[center]HI-SCORE  [color=#fefb00]%d[/color][/center]" % high_score
	visible = true
