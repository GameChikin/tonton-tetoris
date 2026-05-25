extends AnimatableBody2D

@export_group("Drag Settings")
@export var grab_area_size: Vector2 = Vector2(320.0, 640.0)
@export var grab_area_offset: Vector2 = Vector2(160.0, 320.0)

var _is_dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO


func _ready() -> void:
	input_pickable = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var local_mouse_pos = get_local_mouse_position()
			var grab_rect = Rect2(grab_area_offset - grab_area_size / 2.0, grab_area_size)
			
			if grab_rect.has_point(local_mouse_pos):
				_is_dragging = true
				_drag_offset = get_global_mouse_position() - global_position
				get_viewport().set_input_as_handled()
		else:
			_is_dragging = false


func _physics_process(_delta: float) -> void:
	if _is_dragging:
		# velocityによる移動を廃止し、座標を直接指定して絶対的な追従を実現する
		var target_pos = get_global_mouse_position() - _drag_offset
		global_position = target_pos
