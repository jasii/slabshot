class_name PlayerState
extends RefCounted
## Predicted/authoritative movement state. pos = feet position.

var pos := Vector3.ZERO
var vel := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var on_ground := false
var speed_mult := 1.0  # Fold powerup
var blade_t := 0  # 0..BLADE_TICKS, how far turned into blade stance


func copy() -> PlayerState:
	var s := PlayerState.new()
	s.pos = pos
	s.vel = vel
	s.yaw = yaw
	s.pitch = pitch
	s.on_ground = on_ground
	s.speed_mult = speed_mult
	s.blade_t = blade_t
	return s


## 0 = facing aim, 1 = fully edge-on.
func blade() -> float:
	return float(blade_t) / SimConst.BLADE_TICKS


## Slab facing: look yaw turned 90 degrees as the blade stance engages.
func body_yaw() -> float:
	return yaw + blade() * PI * 0.5


func eye() -> Vector3:
	return pos + Vector3(0, SimConst.EYE_HEIGHT, 0)


func aim_dir() -> Vector3:
	return SimMath.dir_from_angles(yaw, pitch)
