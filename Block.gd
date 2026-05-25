extends RigidBody2D

var _still_timer: float = 0.0
const SLEEP_THRESHOLD_VELOCITY: float = 4.0
const SLEEP_DELAY_TIME: float = 0.5


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if freeze:
		return

	if linear_velocity.length() < SLEEP_THRESHOLD_VELOCITY and abs(angular_velocity) < SLEEP_THRESHOLD_VELOCITY:
		_still_timer += delta
		if _still_timer >= SLEEP_DELAY_TIME:
			freeze = true
			_still_timer = 0.0
	else:
		_still_timer = 0.0


func _on_body_entered(_body: Node) -> void:
	if freeze:
		freeze = false
		_still_timer = 0.0
