class_name Hitbox
## Builds the slab hitboxes for a player from (pos, body yaw, entity flags).
## Everything that traces shots goes through here, on server, in lag-comp
## rewind and in client-side prediction, so powerup shapes are consistent.

const HALF := Vector3(SimConst.SLAB_WIDTH * 0.5, SimConst.PLAYER_HEIGHT * 0.5, SimConst.SLAB_DEPTH * 0.5)
## Sphere around the player's center that contains every slab variant
## (Split widens the footprint). Used for trace early-out.
const BOUND_RADIUS := 1.6
const SPLIT_HALF_X := HALF.x * 0.5
const SPLIT_OFFSET := SPLIT_HALF_X + 0.3  # 0.6m gap between halves
const FOLD_HALF := Vector3(HALF.x * 0.5, HALF.y * 0.5, HALF.z)


class Slab:
	var center: Vector3
	var yaw: float
	var half: Vector3
	var index: int

	func _init(c: Vector3, y: float, h: Vector3, i: int) -> void:
		center = c
		yaw = y
		half = h
		index = i


static func slabs_for(pos: Vector3, yaw: float, flags: int) -> Array[Slab]:
	var out: Array[Slab] = []
	match Powerups.of(flags):
		Powerups.SPLIT:
			var h := Vector3(SPLIT_HALF_X, HALF.y, HALF.z)
			var right := SimMath.right_flat(yaw)
			var c := pos + Vector3(0, HALF.y, 0)
			if flags & Powerups.F_HALF_A:
				out.append(Slab.new(c - right * SPLIT_OFFSET, yaw, h, 0))
			if flags & Powerups.F_HALF_B:
				out.append(Slab.new(c + right * SPLIT_OFFSET, yaw, h, 1))
		Powerups.FOLD:
			out.append(Slab.new(pos + Vector3(0, FOLD_HALF.y, 0), yaw, FOLD_HALF, 0))
		_:
			out.append(Slab.new(pos + Vector3(0, HALF.y, 0), yaw, HALF, 0))
	return out


static func is_crit(local_y: float, half: Vector3) -> bool:
	return local_y > half.y * (1.0 - 2.0 * SimConst.CRIT_FRACTION)
