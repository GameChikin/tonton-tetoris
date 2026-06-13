extends Resource
class_name SoundSettings

## BGM・SE（効果音）に関する設定を集約する専用リソース。
## ゲームバランス用の GameSettings とは分離し、サウンドはすべてここで管理する。
## 音源ファイル（AudioStream）はインスペクタ上で各項目に割り当てる。

@export_group("BGM")
## ゲーム本編（モード選択後にブロックを操作している状態）の開始時に再生するBGMです。
## ループ素材を割り当ててください（ループ設定が無くても自動で繰り返します）。
@export var bgm_stream: AudioStream
## BGMの音量（デシベル）です。0が原音、マイナス値で小さくなります。
@export var bgm_volume_db: float = -6.0

@export_group("SE - Docking")
## ブロックがドッキング（吸着結合）に成功した瞬間に鳴らす効果音です。
@export var dock_stream: AudioStream
## ドッキングSEの音量（デシベル）です。
@export var dock_volume_db: float = 0.0

@export_group("SE - Block Break")
## ブロックが破壊（消去）された瞬間に鳴らす効果音です。
@export var break_stream: AudioStream
## ブロック破壊SEの基準音量（デシベル）です。
@export var break_volume_db: float = 0.0
## 連鎖が1段増えるごとに上昇させるピッチ量です。例: 0.15なら2連鎖目で1.15倍の高さになります。
@export var break_pitch_step: float = 0.15
## ピッチ上昇が頭打ちになる連鎖数です。これ以上連鎖してもピッチは上がりません（目安: 5）。
@export_range(1, 20, 1) var break_pitch_max_chain: int = 5

@export_group("Debug")
## デバッグ用：BGMの再生を有効にするかどうかです。OFFにするとBGMだけを止められます。
## SE（効果音）には影響しません。リリース時はONに戻してください。
@export var bgm_enabled: bool = true
## デバッグ用：SE（効果音＝ドッキング音・ブロック破壊音）の再生を有効にするかどうかです。
## OFFにするとSEだけを止められます。BGMには影響しません。リリース時はONに戻してください。
@export var se_enabled: bool = true
