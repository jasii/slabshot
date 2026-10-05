class_name Proto
## Wire protocol: opcodes, quantization, buffer helpers. All little-endian,
## byte-aligned (StreamPeerBuffer) - simple and fast enough in GDScript.

const VERSION := 6
const DEFAULT_PORT := 27500
const QUERY_PORT_OFFSET := 1  # UDP server-browser query port = game port + 1
const MAX_PLAYERS := 64

# client -> server
const C_HELLO := 1
const C_INPUT := 2
const C_PING := 3
# server -> client
const S_WELCOME := 64
const S_SNAPSHOT := 65
const S_PONG := 66
const S_EVENT := 67
const S_REJECT := 68
const S_BULLETS := 69  # overflow bullet events that didn't fit in the snapshot

# reliable events
const EV_PLAYER_INFO := 1
const EV_PLAYER_LEFT := 2
const EV_KILL := 3
const EV_HIT_CONFIRM := 4
const EV_SPAWN := 5  # to the spawning player: face spawn yaw
const EV_MATCH := 6
const EV_SCORE := 7
const EV_PICKUP := 8
const EV_DECOY_GONE := 9

# entity record field indices (PackedInt32Array)
const E_PX := 0
const E_PY := 1
const E_PZ := 2
const E_YAW := 3  # body yaw (includes Spin)
const E_HP := 4
const E_FLAGS := 5  # Powerups flag layout
const E_HP2 := 6  # Split second half
const E_SIZE := 7

# entity delta mask bits
const M_POS := 1
const M_YAW := 2
const M_HP := 4
const M_FLAGS := 8
const M_ALL := 15

# bullet hit flags (despawn events)
const HIT := 1
const HIT_CRIT := 2
const HIT_PIERCED := 4  # bullet keeps flying

# bullet events are repeated in this many consecutive snapshots so a lost
# packet never makes a bullet invisible; clients dedupe by bullet id.
const EVENT_REDUNDANCY := 2
const MTU_SAFE := 1200  # keep unreliable packets under ENet's 1392 MTU

const INPUT_REDUNDANCY := 3

const POS_SCALE := 64.0
const POS_OFFSET := 512.0


static func qpos(v: float) -> int:
	return clampi(int(round((v + POS_OFFSET) * POS_SCALE)), 0, 65535)


static func dqpos(q: int) -> float:
	return q / POS_SCALE - POS_OFFSET


static func qyaw(yaw: float) -> int:
	return int(round(fposmod(yaw, TAU) / TAU * 65536.0)) & 0xFFFF


static func dqyaw(q: int) -> float:
	return q * TAU / 65536.0


static func buf(op: int) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(op)
	return b


static func reader(data: PackedByteArray) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = data
	return b


static func put_vec3f(b: StreamPeerBuffer, v: Vector3) -> void:
	b.put_float(v.x)
	b.put_float(v.y)
	b.put_float(v.z)


static func get_vec3f(b: StreamPeerBuffer) -> Vector3:
	var x := b.get_float()
	var y := b.get_float()
	var z := b.get_float()
	return Vector3(x, y, z)


static func put_qpos(b: StreamPeerBuffer, v: Vector3) -> void:
	b.put_u16(qpos(v.x))
	b.put_u16(qpos(v.y))
	b.put_u16(qpos(v.z))


static func get_qpos(b: StreamPeerBuffer) -> Vector3:
	var x := dqpos(b.get_u16())
	var y := dqpos(b.get_u16())
	var z := dqpos(b.get_u16())
	return Vector3(x, y, z)


static func put_color(b: StreamPeerBuffer, c: Color) -> void:
	b.put_u8(int(c.r * 255))
	b.put_u8(int(c.g * 255))
	b.put_u8(int(c.b * 255))


static func get_color(b: StreamPeerBuffer) -> Color:
	var r := b.get_u8()
	var g := b.get_u8()
	var bl := b.get_u8()
	return Color8(r, g, bl)


static func put_cmd(b: StreamPeerBuffer, c: InputCmd) -> void:
	b.put_u32(c.tick)
	b.put_8(c.move_x)
	b.put_8(c.move_z)
	b.put_u16(c.yaw_q)
	b.put_16(c.pitch_q)
	b.put_u8(c.buttons)


static func get_cmd(b: StreamPeerBuffer) -> InputCmd:
	var c := InputCmd.new()
	c.tick = b.get_u32()
	c.move_x = clampi(b.get_8(), -127, 127)
	c.move_z = clampi(b.get_8(), -127, 127)
	c.yaw_q = b.get_u16()
	c.pitch_q = clampi(b.get_16(), -32767, 32767)
	c.buttons = b.get_u8()
	return c


# ---------------------------------------------------------------- bullet events

## Spawn record, 14 bytes. Tick is sent relative to the section's base tick
## (events are at most a few ticks old); eye is quantized to 1/64 m.
static func put_spawn(b: StreamPeerBuffer, e: Array, base_tick: int) -> void:
	# [first_id, owner, weapon, overcharged, tick, eye, yaw_q, pitch_q]
	b.put_u16(e[0])
	b.put_u8(e[1])
	b.put_u8((e[2] & 15) | (16 if e[3] else 0))
	b.put_u8(clampi(base_tick - int(e[4]), 0, 255))
	put_qpos(b, e[5])
	b.put_u16(e[6])
	b.put_16(e[7])


static func get_spawn(b: StreamPeerBuffer, base_tick: int) -> Array:
	var id := b.get_u16()
	var owner := b.get_u8()
	var wf := b.get_u8()
	var tick := base_tick - b.get_u8()
	var eye := get_qpos(b)
	var yq := b.get_u16()
	var pq := b.get_16()
	return [id, owner, wf & 15, wf & 16 != 0, tick, eye, yq, pq]


static func put_redirect(b: StreamPeerBuffer, e: Array) -> void:
	# [id, owner, weapon, overcharged, t, origin, dir, bounces, attacker]
	b.put_u16(e[0])
	b.put_u8(e[1])
	b.put_u8(e[2])
	b.put_u8(1 if e[3] else 0)
	b.put_double(e[4])
	put_vec3f(b, e[5])
	put_vec3f(b, e[6])
	b.put_u8(e[7])
	b.put_u8(e[8])


static func get_redirect(b: StreamPeerBuffer) -> Array:
	var id := b.get_u16()
	var owner := b.get_u8()
	var weapon := b.get_u8()
	var oc := b.get_u8() == 1
	var t := b.get_double()
	var origin := get_vec3f(b)
	var dir := get_vec3f(b)
	var bounces := b.get_u8()
	var attacker := b.get_u8()
	return [id, owner, weapon, oc, t, origin, dir, bounces, attacker]


static func put_despawn(b: StreamPeerBuffer, e: Array) -> void:
	b.put_u16(e[0])
	b.put_u8(e[1])
	b.put_u8(e[2])


static func get_despawn(b: StreamPeerBuffer) -> Array:
	var id := b.get_u16()
	var flags := b.get_u8()
	var victim := b.get_u8()
	return [id, flags, victim]


## Entity record from authoritative entity. Decoy powerup is hidden so the
## real player can't be told apart from their decoys.
static func entity_record(p: PlayerEntity, tick: int) -> PackedInt32Array:
	var e := PackedInt32Array()
	e.resize(E_SIZE)
	e[E_PX] = qpos(p.state.pos.x)
	e[E_PY] = qpos(p.state.pos.y)
	e[E_PZ] = qpos(p.state.pos.z)
	e[E_YAW] = qyaw(p.body_yaw(tick))
	var hp_scale := 100.0 if p.is_decoy else 1.0  # decoys show full HP
	e[E_HP] = clampi(ceili(p.hp * hp_scale), 0, 255)
	var pu := Powerups.NONE if p.powerup == Powerups.DECOY else p.powerup
	e[E_FLAGS] = Powerups.pack_flags(p.alive, pu, p.half_a, p.half_b)
	e[E_HP2] = clampi(ceili(p.hp2), 0, 255)
	return e


static func record_pos(e: PackedInt32Array) -> Vector3:
	return Vector3(dqpos(e[E_PX]), dqpos(e[E_PY]), dqpos(e[E_PZ]))
