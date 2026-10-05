class_name Powerups
## Powerup data + entity flag packing. Effects that change hit geometry live
## in Hitbox, so lag-comp rewind covers them automatically.

enum { NONE, SPLIT, FOLD, DECOY, MIRROR, GHOST, SPIN, OVERCHARGE, RADAR }

const DATA := {
	SPLIT: {"name": "Split", "secs": 20.0, "color": Color(0.2, 1.0, 0.45),
		"desc": "Two hitboxes. Both must die."},
	FOLD: {"name": "Fold", "secs": 18.0, "color": Color(1.0, 0.6, 0.1),
		"desc": "Quarter-size slab, faster."},
	DECOY: {"name": "Decoy", "secs": 15.0, "color": Color(0.7, 0.7, 0.75),
		"desc": "Two copies of you. One hit kills them."},
	MIRROR: {"name": "Mirror Face", "secs": 15.0, "color": Color(0.85, 0.95, 1.0),
		"desc": "Your face reflects bullets. Back is exposed."},
	GHOST: {"name": "Ghost", "secs": 18.0, "color": Color(0.6, 0.6, 1.0),
		"desc": "Invisible when still."},
	SPIN: {"name": "Spin", "secs": 15.0, "color": Color(1.0, 0.3, 0.8),
		"desc": "Your slab spins. Hard to hit square."},
	OVERCHARGE: {"name": "Overcharge", "secs": 15.0, "color": Color(0.2, 0.9, 1.0),
		"desc": "Pulse pierces and fires faster."},
	RADAR: {"name": "Radar", "secs": 20.0, "color": Color(0.9, 1.0, 0.3),
		"desc": "See enemies through walls."},
}

const COUNT := 8
const FOLD_SPEED := 1.12
const SPIN_PERIOD_TICKS := 30  # 0.5s per revolution

# Entity flag layout (u8): bit0 alive, bits1-4 powerup, bit5 split half A
# alive, bit6 split half B alive.
const F_ALIVE := 1
const F_HALF_A := 32
const F_HALF_B := 64


static func duration_ticks(id: int) -> int:
	return int(DATA[id].secs * SimConst.TICK_RATE)


static func pack_flags(alive: bool, powerup: int, half_a: bool, half_b: bool) -> int:
	return (F_ALIVE if alive else 0) | ((powerup & 15) << 1) \
		| (F_HALF_A if half_a else 0) | (F_HALF_B if half_b else 0)


static func of(flags: int) -> int:
	return (flags >> 1) & 15


static func alive(flags: int) -> bool:
	return flags & F_ALIVE != 0
