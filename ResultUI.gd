extends CanvasLayer
## ゲームオーバー時に表示するリザルトウィンドウ。
## 黒い半透明のウィンドウにスコア／ハイスコアとボタン群をまとめて表示する。
## 数値の反映は Main.game_over() から show_result() を呼んで行う（直接 Label を触らせない）。

# 各ラベルへの参照。シーン内の子ノードなので @onready + 生存チェックで安全に取得する。
@onready var _score_label: Label = get_node_or_null("Window/Margin/VBox/ScoreLabel")
@onready var _high_score_label: Label = get_node_or_null("Window/Margin/VBox/HighScoreLabel")


## リザルト内容を反映してウィンドウを表示する。
## max_chain は現状ウィンドウには出していないが、将来の拡張に備えて引数で受け取っておく。
func show_result(score: int, _max_chain: int, high_score: int) -> void:
	if is_instance_valid(_score_label):
		_score_label.text = "SCORE  %d" % score
	if is_instance_valid(_high_score_label):
		_high_score_label.text = "HI-SCORE  %d" % high_score
	visible = true
