class_name LocalInput
extends Node
## Mouse look + keyboard sampling. Look angles update every mouse event (so
## the camera is never tick-limited); movement/buttons are sampled per tick.

var yaw := 0.0
var pitch := 0.0
var alt := false  # special weapon selected
var captured := false

const PITCH_LIMIT := 1.55


func _ready() -> void:
	capture()


func capture() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	captured = true


func release() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	captured = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and captured:
		var rel: Vector2 = event.screen_relative
		yaw -= rel.x * Settings.mouse_sensitivity
		pitch = clampf(pitch - rel.y * Settings.mouse_sensitivity, -PITCH_LIMIT, PITCH_LIMIT)
	elif event is InputEventMouseButton and event.pressed and not captured:
		capture()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		release()
	elif captured and event.is_action_pressed("weapon_toggle"):
		alt = not alt
	elif captured and event.is_action_pressed("weapon_1"):
		alt = false
	elif captured and event.is_action_pressed("weapon_2"):
		alt = true


func sample(tick: int) -> InputCmd:
	var cmd := InputCmd.new()
	cmd.tick = tick
	cmd.set_angles(yaw, pitch)
	if alt:
		cmd.buttons |= InputCmd.BTN_ALT
	if not captured:
		return cmd
	var mx := Input.get_axis("move_left", "move_right")
	var mz := Input.get_axis("move_back", "move_forward")
	cmd.move_x = int(round(mx * 127.0))
	cmd.move_z = int(round(mz * 127.0))
	if Input.is_action_pressed("fire"):
		cmd.buttons |= InputCmd.BTN_FIRE
	if Input.is_action_pressed("jump"):
		cmd.buttons |= InputCmd.BTN_JUMP
	if Input.is_action_pressed("blade"):
		cmd.buttons |= InputCmd.BTN_BLADE
	return cmd
