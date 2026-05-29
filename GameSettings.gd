extends Resource
class_name GameSettings

@export_group("Board & Game Rules")
@export_enum("Tetris", "Puyo") var current_rule: int = 0 # 0: Tetris, 1: Puyo
@export var tonton_drop_speed: float = 0.02
@export var tonton_drop_distance: int = 20
@export var clear_threshold: int = 8
@export var line_clear_hold_time: float = 1.5
@export var board_width_px: float = 320.0

@export_group("Tetromino Physics & Snap")
@export var sleep_threshold_velocity: float = 15.0
@export var sleep_delay_time: float = 0.2
@export var snap_rotation_strength: float = 12.0
@export var snap_rotation_limit: float = 25.0
@export var snap_x_strength: float = 8.0
@export var snap_x_limit: float = 12.0

@export_group("AI Settings")
@export var ai_enabled: bool = true
@export var ai_action_delay: float = 0.5
@export var drop_center_offset: float = 160.0


func print_all_settings() -> void:
	print("=== GameSettings Current Values ===")
	print("[Board & Game Rules]")
	print("current_rule: ", "Tetris" if current_rule == 0 else "Puyo")
	print("tonton_drop_speed: ", tonton_drop_speed)
	print("tonton_drop_distance: ", tonton_drop_distance)
	print("clear_threshold: ", clear_threshold)
	print("line_clear_hold_time: ", line_clear_hold_time)
	print("board_width_px: ", board_width_px)
	
	print("[Tetromino Physics & Snap]")
	print("sleep_threshold_velocity: ", sleep_threshold_velocity)
	print("sleep_delay_time: ", sleep_delay_time)
	print("snap_rotation_strength: ", snap_rotation_strength)
	print("snap_rotation_limit: ", snap_rotation_limit)
	print("snap_x_strength: ", snap_x_strength)
	print("snap_x_limit: ", snap_x_limit)
	
	print("[AI Settings]")
	print("ai_enabled: ", ai_enabled)
	print("ai_action_delay: ", ai_action_delay)
	print("drop_center_offset: ", drop_center_offset)
	print("===================================")
