# AI_RULES.md — tontonTetoris コーディング規約

このドキュメントは、AI（および開発者）が本プロジェクトのコードを**安全かつ一貫して**追記・修正するためのエンジニアリングルールを定義する。ゲームバランスやパラメータ等の「データ設定」は対象外（それらはすべて `game_settings.tres` 側で管理する。後述）。

---

## 0. 大前提：このゲームは「物理ベースの落ちものパズル」である

最重要の認識。本プロジェクトは**グリッド配列で盤面状態を管理する一般的なテトリスではない**。

- ブロックの塊（`Tetromino`）は `RigidBody2D` であり、Jolt 物理エンジンによる**実際の重力・衝突で落下・堆積する**。
- 盤面状態は「2次元配列」ではなく、**シーンツリー上に実在するノードの `global_position`** が唯一の真実（source of truth）。
- ライン消去やぷよ連結の判定は、配列を見るのではなく**毎物理フレーム、実ブロックのワールド座標を `CELL_SIZE`(32px) でマス目に丸めて**集計して行う（`Board._evaluate_tetris_lines` / `_evaluate_puyo_matches`）。

> ⚠️ `Board.gd` には `_initialize_grid()`, `is_cell_empty()`, `lock_blocks()`, `apply_tetris_gravity()` 等、**中身が `pass` / 空配列 / `return true` の旧グリッド方式の名残メソッドが多数残っている**。これらはレガシーであり、**呼び出しても何も起きない**。新規ロジックをここに足さないこと。盤面判定は必ず座標ベースで書く。

---

## 1. アーキテクチャ全体像

### ノード構成（`Main.tscn`）
```
Main (Node2D, Main.gd)              ← ゲーム進行・スポーン・ゲームオーバー判定の統括
├── Camera2D
├── Board (Node2D, Board.gd)        ← 判定の中枢。ドッキング/消去/連鎖を集中管理
│   └── BoardPhysicsFrame (AnimatableBody2D, BoardPhysicsFrame.gd)  ← 壁・床（動かせる物理枠）
├── DebugLayer (CanvasLayer, BoardPresetManager.gd) ← 盤面プリセット投入デバッグUI
├── EffectManager (Node, EffectManager.gd)   ← 全演出（シェイク/フラッシュ/衝撃波/パーティクル）
├── FlashLayer / FlashRect
├── ScoreUI / ScoreManager (ScoreManager.gd)  ← スコア計算・ポップアップ
├── AIController (Node, AIController.gd)       ← デモ/自動操作
├── ResultUI (CanvasLayer)                     ← ゲームオーバー画面
├── DeadlineLine / WarningRect                 ← デッドライン可視化
└── （実行時に Tetromino が動的に add_child される）

SaveManager  ← Autoload（プロジェクト唯一のシングルトン）
```

### 責務分離の原則
- **`Main.gd`**：生成タイミング、難易度（スポーン間隔）、デッドライン超過によるゲームオーバー判定のみ。盤面ロジックには踏み込まない。
- **`Board.gd`**：ドッキング（吸着結合）判定・実行、ライン/連結の消去判定、連鎖キューの管理。**盤面に関する判断はすべてここに集約する（中央集権型）**。
- **`Tetromino.gd`**：自分自身の物理挙動、ドラッグ操作、スナップ補正、分断時の自己分裂。**他のテトリミノを直接操作しない**（結合は必ず `Board` 経由）。
- **`EffectManager.gd`**：見た目の演出専門。ゲームロジックを判断しない。
- **`ScoreManager` / `SaveManager`**：スコアの算出と永続化のみ。

### 通信は「シグナル」で疎結合にする
ノード間の連携は直接呼び出しよりシグナルを優先する。既存のシグナル：
- `Board.resolve_started` / `resolve_finished` … 連鎖の開始/完了。`Main` が `resolve_finished` を受けて次ブロックを生成。
- `EffectManager.slow_motion_requested(is_slow)` … 演出中の盤面スロー化要求。`Board.set_board_slow_motion` が受信。
- `EffectManager.shake_finished` / `Tetromino.locked_to_board`。

新しい連携を足すときも、まずシグナルで表現できないか検討すること。

---

## 2. 設定値（データ）の扱い ── ハードコード禁止

- 調整可能な数値・フラグは**すべて `game_settings.tres`（`GameSettings` リソース）に集約**する。各スクリプトは先頭で次のように読む：
  ```gdscript
  var settings: GameSettings = preload("res://game_settings.tres")
  ```
- 値の読み出しは、**キー欠損に強い `settings.get("key")` を優先**し、`null` フォールバックを添える既存パターンに倣う：
  ```gdscript
  var interval = settings.get("chain_interval_time") if settings.get("chain_interval_time") != null else 0.3
  ```
- 新しい調整項目を追加するときは、`GameSettings.gd` に `@export` 変数として**日本語の `##` ドキュメントコメント付きで**定義する（インスペクタに説明が出る）。マジックナンバーをスクリプトに直書きしない。
- ⚠️ `Block.gd` のように独自定数（`SLEEP_THRESHOLD_VELOCITY` 等）を持つ箇所が一部残るが、**新規追加分は GameSettings に寄せる**のが正しい方向性。

---

## 3. 物理／シーンツリー操作の安全規約（最重要・クラッシュ防止）

物理コールバック中のツリー変更は Godot/Jolt をクラッシュさせる。以下を厳守する。

1. **`_physics_process` 中にノードを追加・削除・付け替えしない。** 必ず遅延実行する：
   - 削除：`block.queue_free()`
   - プロパティ即時反映を避ける：`block.set_deferred("disabled", true)`
   - ツリー構造変更：`call_deferred("_detach_and_recreate_blocks", blocks)`（既存例）。
2. **ノードに触る前に必ず生存確認する。** 物理オブジェクトは非同期に消える：
   ```gdscript
   if is_instance_valid(node) and not node.is_queued_for_deletion():
       ...
   ```
   特に `await` をまたいだ後は、再度 `is_instance_valid()` でチェックし直す（既存コードはこれを徹底している）。
3. **`await` の前に必要な座標等をローカル変数へキャッシュする。** アニメーション完了前に対象が消える前提で書く（`Board._execute_docking` の `snap_effect_pos` キャッシュが手本）。
4. **Tween は対象ノードにバインドする。** `create_tween().bind_node(target_tet)` とし、対象が消えたら Tween も自動キャンセルさせる。
5. **メソッド/プロパティの存在も確認してから呼ぶ。** 動的に種類が変わるノードを跨ぐため `has_method()` / `has_signal()` / `"prop" in node` を多用する：
   ```gdscript
   if board.has_method("request_docking"):
       board.request_docking(self)
   ```

---

## 4. ポーズ（時間停止）と演出の規約

連鎖演出中はゲーム全体をスロー/停止させる「泥沼状態」を使う。これに伴う固有ルール：

- **停止中も動かしたいノードは `process_mode = Node.PROCESS_MODE_ALWAYS`** を `_ready()` で設定する（`Board`, `EffectManager` が該当）。入力を拾うため。
- **ドラッグ中のテトリミノは局所的に覚醒させる**：`process_mode = Node.PROCESS_MODE_ALWAYS` にし、離したら `PROCESS_MODE_INHERIT` に戻す（`Tetromino.start_drag` / `release_drag`）。
- **ポーズ中に進めたい Tween は明示設定が必要**：
  ```gdscript
  tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
  ```
- スロー化は物理を直接いじらず、`set_slow_motion()` で `gravity_scale=0 / linear_damp=30 / angular_damp=30` を与える方式。**復帰用に `_default_*` を `_ready()` で記憶しておく**パターンを崩さない。
- 演出の入り口/出口で必ず `slow_motion_requested.emit(true/false)` をペアで発火し、**フェイルセーフとして連鎖完了時に必ず `set_board_slow_motion(false)`** を呼ぶ（途中でブロックが消えても解除漏れしないように）。

---

## 5. テトリミノ（塊）の整合性ルール

`Tetromino` はブロックの結合・分離・消去で構成が動的に変化する。内部状態の破綻を防ぐ規約：

- **`blocks` / `local_cells` 配列は実ノード構成と乖離しうる。** ブロックの移籍・消去後は必ず `_rebuild_internal_arrays()` を呼んで実ノードから再構築する（自己修復）。
- **ブロックが分断されたら自動分裂させる。** `child_exiting_tree` → `call_deferred("_check_and_split_if_needed")` → Flood Fill で島を検出し、最大の島を残して他を `_detach_group()` で独立 `Tetromino` 化する。この連鎖を壊さないこと。
- **空になった `Tetromino` は自身を `queue_free()` する**（`_rebuild_internal_arrays` 末尾）。空箱を残さない。
- **動的生成した分離ブロックは `disable_auto_spawn = true` を立ててから `add_child`**。これを忘れるとランダム4ブロックが勝手に生える。
- 各ブロックは `set_meta("color_id", key)` で色アイデンティティを持つ。連結・吸着の同色判定はこのメタに依存するので、ブロック生成時は必ず付与する。

---

## 6. ドッキング（吸着結合）に触る場合

- 判定本体は `Board._evaluate_docking()`。実行は `_execute_docking()`。**判定と実行は必ず分離**したまま保つ。
- 入口は3経路あるが**すべて `Board` 経由**で `_execute_docking` に合流する：
  1. プレイヤーが手を離した瞬間（`Tetromino.release_drag` → `request_docking`）
  2. ドラッグ中のリアルタイム自動吸着（`Tetromino._physics_process` → `request_docking`）
  3. 非操作ブロック同士の低頻度自動スキャン（`Board._scan_for_auto_docking`、0.2秒間隔）
- 多重結合によるクラッシュを防ぐため、結合に入る前に**双方へ `_is_docking_animating = true` の排他ロック**をかけ、アニメ完了コールバックで解除する。この不変条件を破らない。
- 回転で形状が歪むのを防ぐため、マス目算出時は**回転角を90度単位にスナップ**してから計算する（`round(rotation / (PI/2)) * (PI/2)`）。

---

## 7. コーディングスタイル規約

- **言語**：GDScript（静的型付けを徹底）。`var x: int = 0`、`func f(a: float) -> bool:`、`Array[Node]` のように**型注釈を必ず付ける**。
- **コメントは日本語**。意図・なぜそうするか（特に物理クラッシュ回避やフェイルセーフの理由）を残す既存スタイルに合わせる。
- **命名規約**：
  - クラス／ファイル：PascalCase（`Board.gd`, `EffectManager`）。`class_name` を付与する。
  - 関数・変数：snake_case。
  - private 想定（外部から呼ばない）関数・変数：先頭 `_`（`_evaluate_docking`, `_is_chain_active`）。
  - 定数：UPPER_SNAKE_CASE（`CELL_SIZE`, `TETROMINO_DATA`）。
  - シグナル：過去形・状態名（`resolve_finished`, `locked_to_board`）。
- **ノード参照は `get_node_or_null()` + 生存チェック**を基本とし、`@onready` / `@export var ..._path: NodePath` でパスを外部化する（ハード参照を避ける）。
- **デバッグ出力は `print("[Debug XXX] ...")` 形式**のタグ付き。`push_warning()` / `push_error()` を異常系で使う。
- 1行が極端に長くなる三項演算子・インラインラムダは既存コードに多用されているが、**新規追加時は可読性を優先**し、複雑なら多行に展開してよい。

---

## 8. シーン遷移・永続化

- シーン遷移は `get_tree().change_scene_to_file("res://XXX.tscn")`（タイトル）/ `reload_current_scene()`（リトライ）。
- ハイスコア等の永続化は **Autoload の `SaveManager` のみ**を経由する。`update_score()` を呼ぶだけでよく、ファイルI/Oを他所に書かない。保存先は `user://save_data.save`（`FileAccess.store_var`）。

---

## 9. 既知のレガシー／地雷（触れる前に確認）

- `ai_controller.gd`（小文字）は**空の雛形**。実体は `AIController.gd`（大文字）。新規ロジックは大文字側へ。
- `Board.gd` 内の `is_line_full`/`resolve_lines`/`apply_*_gravity`/`_collect_tonton_drop_targets` 等は**旧設計の空スタブ**。実装が必要に見えても、現行は座標ベースで別途処理済み。安易に肉付けしない。
- `Tetromino` の `_try_move`/`_try_rotate`/`_can_place`/`_hard_drop` 等のグリッド移動系は、`board.is_cell_empty()` が常に `true` を返すため**現行フローでは実質機能していない**（物理落下に置き換わっている）。
- 「トントン」関連（`apply_tonton_drop`, `tonton` 入力アクション）は仕様変更で一部が宙に浮いている。空間入力ポーリング（`Main._process` のスペースキー早送り）が現行。

---

## 10. 変更時のチェックリスト

新しいコードを書く／既存を直す前に：

- [ ] 盤面判定を**配列ではなく実ノードのワールド座標**で書いているか
- [ ] 物理フレーム中のツリー変更を `call_deferred` / `set_deferred` / `queue_free` にしたか
- [ ] ノードアクセスの前後（特に `await` 跨ぎ）で `is_instance_valid()` を入れたか
- [ ] 新規パラメータを `GameSettings.gd` に `@export` + `##` で足したか（直書きしていないか）
- [ ] ノード間連携をシグナルで疎結合にできないか検討したか
- [ ] 結合/分離後に `_rebuild_internal_arrays()` を呼んで配列を整合させたか
- [ ] スロー演出に絡む場合、解除のフェイルセーフ（`set_board_slow_motion(false)`）が漏れていないか
- [ ] 型注釈・日本語コメント・命名規約を既存コードに揃えたか
