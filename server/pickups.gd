class_name Pickups
extends RefCounted
## Weapon and powerup spots. Server-only logic; availability changes are
## broadcast as reliable events.

enum Kind { WEAPON, POWERUP }

const RADIUS := 1.3
const WEAPON_RESPAWN := 20 * 60
const POWERUP_RESPAWN := 30 * 60
const POWERUP_FIRST := 10 * 60  # powerups first appear 10s into a match

class Spot:
	var pos: Vector3
	var kind: int
	var type: int
	var available := true
	var respawn_tick := 0

var spots: Array[Spot] = []


func build(map: MapData) -> void:
	spots.clear()
	for ws: Array in map.weapon_spots:
		var s := Spot.new()
		s.pos = ws[0]
		s.kind = Kind.WEAPON
		s.type = ws[1]
		spots.append(s)
	for pp in map.powerup_spots:
		var s := Spot.new()
		s.pos = pp
		s.kind = Kind.POWERUP
		s.type = _random_powerup()
		spots.append(s)


func reset(now: int) -> void:
	for s in spots:
		if s.kind == Kind.POWERUP:
			s.available = false
			s.respawn_tick = now + POWERUP_FIRST
		else:
			s.available = true


static func _random_powerup() -> int:
	return randi_range(1, Powerups.COUNT)


## Returns indices of spots whose state changed this tick.
func step(world: World) -> Array[int]:
	var changed: Array[int] = []
	for i in spots.size():
		var s := spots[i]
		if not s.available:
			if world.tick >= s.respawn_tick:
				s.available = true
				if s.kind == Kind.POWERUP:
					s.type = _random_powerup()
				changed.append(i)
			continue
		for p: PlayerEntity in world.players.values():
			if not p.alive or p.is_decoy:
				continue
			var d := p.state.pos - s.pos
			if Vector2(d.x, d.z).length_squared() > RADIUS * RADIUS or absf(d.y) > 1.5:
				continue
			if s.kind == Kind.WEAPON:
				world.give_weapon(p, s.type)
				s.respawn_tick = world.tick + WEAPON_RESPAWN
			else:
				world.give_powerup(p, s.type)
				s.respawn_tick = world.tick + POWERUP_RESPAWN
			s.available = false
			changed.append(i)
			break
	return changed
