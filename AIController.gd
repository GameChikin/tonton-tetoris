extends Node
class_name AIController

var settings: GameSettings = preload("res://game_settings.tres")

var _main_node: Node = null
var _is_acting: bool = false

func setup(main_node: Node) -> void:
	_main_node = main_node

func _process(_delta: float) -> void:
	if not settings.ai_enabled or _is_acting or not is_instance_valid(_main_node):
		return

	var active_tet = _main_node.get("active_tetromino")
	if is_instance_valid(active_tet) and not active_tet.get("_is_locked"):
		_is_acting = true
		_execute_random_drop(active_tet)

func _execute_random_drop(tetromino: RigidBody2D) -> void:
	await get_tree().create_timer(settings.ai_action_delay).timeout

	if is_instance_valid(tetromino) and not tetromino.get("_is_locked"):
		var target_x = settings.drop_center_offset
		
		# 動いている枠の現在位置を取得し、その中心を落下地点とする
		if is_instance_valid(_main_node):
			var board = _main_node.get("board")
			if is_instance_valid(board):
				var frame = board.get_node_or_null("BoardPhysicsFrame")
				if is_instance_valid(frame):
					target_x = frame.global_position.x + settings.drop_center_offset

		if tetromino.has_method("execute_ai_drop"):
			tetromino.execute_ai_drop(target_x)

	_is_acting = false
