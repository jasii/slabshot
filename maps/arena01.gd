class_name Arena01
## 48x48 symmetric room. Center powerup pad ringed by 4 columns, 8 mid
## pillars, low corner cover, two raised ledges (east/west) with stairs.

const HALF := 24.0
const WALL_H := 7.0


static func build() -> MapData:
	var m := MapData.new()
	m.name = "Arena01"

	# Floor + ceiling-less walls
	m.add_box(Vector3(0, -0.5, 0), Vector3(HALF * 2 + 2, 1, HALF * 2 + 2), 0.55)
	m.add_box(Vector3(0, WALL_H * 0.5, -HALF - 0.5), Vector3(HALF * 2 + 2, WALL_H, 1), 0.72)
	m.add_box(Vector3(0, WALL_H * 0.5, HALF + 0.5), Vector3(HALF * 2 + 2, WALL_H, 1), 0.72)
	m.add_box(Vector3(-HALF - 0.5, WALL_H * 0.5, 0), Vector3(1, WALL_H, HALF * 2), 0.66)
	m.add_box(Vector3(HALF + 0.5, WALL_H * 0.5, 0), Vector3(1, WALL_H, HALF * 2), 0.66)

	# Center: 4 thin columns around the pad
	m.add_mirrored4(3.0, 3.0, 1.0, 1.0, WALL_H, 0.85)
	m.add_block(0, 0, 3.0, 3.0, 0.25, 0.9)  # powerup pad

	# Mid pillars (8)
	m.add_mirrored4(9.0, 4.0, 2.0, 2.0, WALL_H, 0.8)
	m.add_mirrored4(4.0, 11.0, 2.0, 2.0, WALL_H, 0.8)

	# Long low walls north/south lanes
	m.add_block(0, 16.0, 8.0, 0.8, 1.3, 0.75)
	m.add_block(0, -16.0, 8.0, 0.8, 1.3, 0.75)

	# Corner cover: L of low blocks
	m.add_mirrored4(17.0, 18.0, 3.0, 1.0, 1.2, 0.75)
	m.add_mirrored4(18.5, 15.5, 1.0, 4.0, 1.2, 0.75)

	# Raised ledges east/west with 3-step stairs facing center
	for sx in [1.0, -1.0]:
		m.add_box(Vector3(sx * 21.0, 1.0, 0), Vector3(6.0, 2.0, 16.0), 0.62)
		m.add_box(Vector3(sx * 17.5, 0.75, 0), Vector3(1.0, 1.5, 4.0), 0.6)
		m.add_box(Vector3(sx * 16.5, 0.5, 0), Vector3(1.0, 1.0, 4.0), 0.6)
		m.add_box(Vector3(sx * 15.5, 0.25, 0), Vector3(1.0, 0.5, 4.0), 0.6)
		# ledge cover
		m.add_box(Vector3(sx * 19.5, 2.6, 5.0), Vector3(0.6, 1.2, 3.0), 0.8)
		m.add_box(Vector3(sx * 19.5, 2.6, -5.0), Vector3(0.6, 1.2, 3.0), 0.8)

	# Spawns: 16, symmetric
	for sx in [1.0, -1.0]:
		for sz in [1.0, -1.0]:
			m.add_spawn(Vector3(sx * 22.5, 0, sz * 22.5))
			m.add_spawn(Vector3(sx * 12.0, 0, sz * 20.0))
			m.add_spawn(Vector3(sx * 21.0, 2.0, sz * 6.5))
			m.add_spawn(Vector3(sx * 7.0, 0, sz * 7.0))

	# Powerups: center pad (contested) + behind each low lane wall
	m.powerup_spots.append(Vector3(0, 0.25, 0))
	m.powerup_spots.append(Vector3(0, 0, 18.5))
	m.powerup_spots.append(Vector3(0, 0, -18.5))
	# Weapons: rails on one corner diagonal, scatters on the other, ricochet
	# on each team ledge. Point-symmetric so neither side is favoured.
	m.weapon_spots.append([Vector3(20.0, 0, 20.0), Weapons.RAIL])
	m.weapon_spots.append([Vector3(-20.0, 0, -20.0), Weapons.RAIL])
	m.weapon_spots.append([Vector3(-20.0, 0, 20.0), Weapons.SCATTER])
	m.weapon_spots.append([Vector3(20.0, 0, -20.0), Weapons.SCATTER])
	m.weapon_spots.append([Vector3(22.0, 2.0, 0), Weapons.RICOCHET])
	m.weapon_spots.append([Vector3(-22.0, 2.0, 0), Weapons.RICOCHET])
	return m
