extends Control
## A small rotating arc used as the "connecting" indicator on the lobby
## screen. Draws itself (no texture assets needed) and can be switched into
## a success/error/idle resting state instead of just spinning forever.

enum State { SPINNING, SUCCESS, ERROR, IDLE }

@export var spin_color: Color = Color("c3f53e")   # lime accent, mid-spin
@export var success_color: Color = Color("4ade80")
@export var error_color: Color = Color("ff6b6b")
@export var track_color: Color = Color(1.0, 1.0, 1.0, 0.10)
@export var line_width: float = 5.0
@export var spin_speed: float = 3.4                # radians/sec
@export var arc_length: float = TAU * 0.27         # how much of the ring is lit while spinning

var _state: int = State.SPINNING
var _angle: float = 0.0
var _ring_color: Color

func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(56, 56)
	set_state(_state)


func _process(delta: float) -> void:
	if _state != State.SPINNING:
		return
	_angle = wrapf(_angle + spin_speed * delta, 0.0, TAU)
	queue_redraw()


## Switch to a resting state. State.SPINNING resumes normal spinning.
func set_state(new_state: int) -> void:
	_state = new_state
	match new_state:
		State.SUCCESS:
			_ring_color = success_color
		State.ERROR:
			_ring_color = error_color
		State.IDLE:
			_ring_color = track_color
		State.SPINNING:
			_ring_color = spin_color
	queue_redraw()


func _draw() -> void:
	var r: float = (min(size.x, size.y) - line_width) * 0.5
	var center: Vector2 = size * 0.5
	draw_arc(center, r, 0.0, TAU, 48, track_color, line_width, true)
	if _state == State.SPINNING:
		draw_arc(center, r, _angle, _angle + arc_length, 32, _ring_color, line_width, true)
	elif _state != State.IDLE:
		draw_arc(center, r, 0.0, TAU, 48, _ring_color, line_width, true)
