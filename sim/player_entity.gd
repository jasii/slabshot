class_name PlayerEntity
extends RefCounted
## Everything the server tracks per player beyond movement.

var id := 0
var name := ""
var team := 0  # 0 = FFA, 1/2 = teams
var color := Color.WHITE
var state := PlayerState.new()
var hp := float(SimConst.MAX_HP)
var hp2 := 0.0  # Split: second half's HP
var half_a := true
var half_b := false
var alive := true
var next_fire_tick := 0
var last_damage_tick := -100000
var respawn_tick := 0
var kills := 0
var deaths := 0

# weapons
var special := Weapons.NONE
var ammo := 0
var want_alt := false
var rail_charge := 0

# powerups
var powerup := Powerups.NONE
var powerup_start := 0
var powerup_end := 0

# decoys (server-only entities that look like their owner)
var is_decoy := false
var owner_id := -1
var decoy_mirror := false
var decoy_yaw0 := 0.0


func active_weapon() -> int:
	return special if want_alt and special != Weapons.NONE else Weapons.PULSE


func body_yaw(tick: int) -> float:
	if powerup == Powerups.SPIN:
		return state.body_yaw() + float(tick - powerup_start) * TAU / Powerups.SPIN_PERIOD_TICKS
	return state.body_yaw()


func flags() -> int:
	return Powerups.pack_flags(alive, powerup, half_a, half_b)
