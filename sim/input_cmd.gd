class_name InputCmd
extends RefCounted
## One tick of player input. Yaw/pitch are stored already quantized so the
## client predicts with exactly the angles the server will receive.

const BTN_FIRE := 1
const BTN_JUMP := 2
const BTN_ALT := 4  # special weapon selected
const BTN_BLADE := 8  # hold: turn slab edge-on, move slow

var tick := 0
var move_x := 0  # -127..127, strafe right positive
var move_z := 0  # -127..127, forward positive
var yaw_q := 0  # u16
var pitch_q := 0  # i16
var buttons := 0


func yaw() -> float:
	return yaw_q * TAU / 65536.0


func pitch() -> float:
	return pitch_q * (PI * 0.5) / 32767.0


func set_angles(yaw_rad: float, pitch_rad: float) -> void:
	yaw_q = int(round(fposmod(yaw_rad, TAU) / TAU * 65536.0)) & 0xFFFF
	pitch_q = clampi(int(round(pitch_rad / (PI * 0.5) * 32767.0)), -32767, 32767)


func has(btn: int) -> bool:
	return buttons & btn != 0


func copy() -> InputCmd:
	var c := InputCmd.new()
	c.tick = tick
	c.move_x = move_x
	c.move_z = move_z
	c.yaw_q = yaw_q
	c.pitch_q = pitch_q
	c.buttons = buttons
	return c
