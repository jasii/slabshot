class_name Weapons
## Weapon data table. Intervals/charge in ticks (60/s), speeds in m/s.
## All weapons fire slow, visible projectiles (bullet-hell style).
## Everyone always has the Pulse; one special weapon can be carried,
## picked up from map spots, with limited ammo.

enum { PULSE, RAIL, RICOCHET, SCATTER }
const NONE := -1

const DATA := {
	PULSE: {
		"name": "Pulse",
		"interval": 10,  # 6 shots/s
		"damage": 20,  # 5 body hits / 4 crits to kill
		"speed": 18.0,
		"radius": 0.12,
		"range": 150.0,
		"ammo": 0,
		"color": Color(0.1, 0.6, 1.0),
	},
	RAIL: {
		"name": "Rail",
		"interval": 60,  # cooldown after a shot
		"charge": 36,  # hold fire 0.6s; fires when full
		"damage": 100,  # one-shot kill (Split halves each need their own hit)
		"speed": 55.0,
		"radius": 0.08,
		"range": 200.0,
		"pierce": true,
		"ammo": 6,
		"color": Color(0.85, 0.2, 1.0),
	},
	RICOCHET: {
		"name": "Ricochet",
		"interval": 30,  # 2 shots/s
		"damage": 35,
		"speed": 16.0,
		"radius": 0.16,
		"range": 120.0,
		"bounces": 2,
		"ammo": 10,
		"color": Color(1.0, 0.85, 0.1),
	},
	SCATTER: {
		"name": "Scatter",
		"interval": 60,
		"damage": 12,
		"speed": 15.0,
		"radius": 0.1,
		"range": 30.0,
		"pellets": 7,
		"spread": 0.12,
		"ammo": 8,
		"color": Color(1.0, 0.35, 0.2),
	},
}

const OVERCHARGE_INTERVAL := 7  # ~8.6 shots/s
const OVERCHARGE_SPEED := 1.3


static func get_data(id: int) -> Dictionary:
	return DATA[id]


static func interval(id: int, overcharged: bool) -> int:
	if id == PULSE and overcharged:
		return OVERCHARGE_INTERVAL
	return DATA[id].interval


static func speed(id: int, overcharged: bool) -> float:
	var s: float = DATA[id].speed
	return s * OVERCHARGE_SPEED if id == PULSE and overcharged else s


static func pierces(id: int, overcharged: bool) -> bool:
	return DATA[id].get("pierce", false) or (id == PULSE and overcharged)


## Projectile directions for one trigger pull. Scatter uses a deterministic
## pattern (center + ring) rotated by tick, so clients rebuild it exactly.
static func pellet_dirs(id: int, dir: Vector3, tick: int) -> Array[Vector3]:
	if id != SCATTER:
		return [dir]
	var w: Dictionary = DATA[SCATTER]
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	var right := dir.cross(up).normalized()
	var up2 := right.cross(dir).normalized()
	var out: Array[Vector3] = [dir]
	var n: int = w.pellets - 1
	var spread: float = w.spread
	var rot := fmod(tick * 2.39996, TAU)
	for i in n:
		var a := rot + TAU * i / n
		out.append((dir + (right * cos(a) + up2 * sin(a)) * spread).normalized())
	return out
