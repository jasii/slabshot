class_name Projectiles
extends RefCounted
## Slow projectiles. A bullet flies in straight lines and bounces off the
## static map, so its whole flight path is computed once at spawn by
## build_path(). Server and clients run the same function on the same
## inputs (eye position, quantized aim, tick), so the server only has to
## announce spawns, mirror reflections and hits - never per-tick positions.
##
## Hits are resolved on the server in the present (no rewind): bullets are
## checked against where players actually are. Clients draw bullets on
## their own predicted timeline, so the bullet you see coming at you is
## exactly where the server tests it against you ("favor the dodger").
##
## Time unit everywhere is ticks (float).

const ORIGIN_FORWARD := 0.4  # spawn slightly in front of the eye
const EPS := 0.01
const CELL := 4.0

# path segment layout: [t0: float, origin: Vector3, vel_per_tick: Vector3, t1: float]
const S_T0 := 0
const S_ORIGIN := 1
const S_VEL := 2
const S_T1 := 3


class Bullet:
	var id := 0
	var owner := -1
	var attacker := -1  # owner, or the Mirror holder after a reflection
	var weapon := 0
	var overcharged := false
	var damage := 0.0
	var radius := 0.1
	var pierce := false
	var bounces := 0  # bounces allowed for the current path
	var path: Array = []
	var seg := 0
	var hit_ids := {}
	var dead := false


## Flight path from origin: straight segments, reflecting off boxes until
## out of bounces or range.
static func build_path(boxes: Array[AABB], origin: Vector3, dir: Vector3, speed: float,
		t0: float, bounces: int, max_range: float) -> Array:
	var segs := []
	var per_tick := speed / SimConst.TICK_RATE
	var o := origin
	var d := dir
	var t := t0
	var remaining := max_range
	for i in bounces + 1:
		var hit := SimMath.ray_world(o, d, boxes, remaining)
		var length := hit.x if hit.x >= 0.0 else remaining
		var t_end := t + length / per_tick
		segs.append([t, o, d * per_tick, t_end])
		if hit.x < 0.0 or i == bounces:
			break
		remaining -= length
		var end := o + d * length
		var n := SimMath.aabb_normal_at(end, boxes[int(hit.y)])
		d = SimMath.reflect(d, n)
		o = end + n * EPS
		t = t_end
	return segs


static func end_time(path: Array) -> float:
	return path[path.size() - 1][S_T1]


static func seg_pos(s: Array, t: float) -> Vector3:
	return (s[S_ORIGIN] as Vector3) + (s[S_VEL] as Vector3) * (t - (s[S_T0] as float))


static func spawn_origin(eye: Vector3, dir: Vector3) -> Vector3:
	return eye + dir * ORIGIN_FORWARD


# ---------------------------------------------------------------- server side

var bullets := {}  # id -> Bullet
var _next_id := 0

# events since last drain (server encodes them into snapshots)
var spawns := []  # [first_id, owner, weapon, overcharged, tick, eye, yaw_q, pitch_q]
var redirects := []  # [id, owner, weapon, overcharged, t, origin, dir, bounces, attacker]
var despawns := []  # [id, flags (Proto.HIT_*), victim]
var hits := []  # [attacker, victim, crit, killed] for hit confirms


func fire(world: World, p: PlayerEntity, weapon: int, overcharged: bool, cmd: InputCmd, tick: int) -> void:
	var w := Weapons.get_data(weapon)
	var eye := p.state.eye()
	var dir := SimMath.dir_from_angles(cmd.yaw(), cmd.pitch())
	var first := _next_id
	for d in Weapons.pellet_dirs(weapon, dir, tick):
		var b := Bullet.new()
		b.id = _next_id
		_next_id = (_next_id + 1) & 0xFFFF
		b.owner = p.id
		b.attacker = p.id
		b.weapon = weapon
		b.overcharged = overcharged
		b.damage = w.damage
		b.radius = w.radius
		b.pierce = Weapons.pierces(weapon, overcharged)
		b.bounces = w.get("bounces", 0)
		b.path = build_path(world.boxes, spawn_origin(eye, d), d, Weapons.speed(weapon, overcharged),
			tick, b.bounces, w.range)
		bullets[b.id] = b
	spawns.append([first, p.id, weapon, overcharged, tick, eye, cmd.yaw_q, cmd.pitch_q])


## Advance all bullets over (T-1, T] against players' positions at T.
func step(world: World, T: int) -> void:
	var grid := _player_grid(world)
	var t_a := float(T - 1)
	var t_b := float(T)
	for b: Bullet in bullets.values():
		_sweep(world, b, t_a, t_b, grid)
		if b.dead or t_b >= end_time(b.path):
			bullets.erase(b.id)


func clear() -> void:
	bullets.clear()


func _sweep(world: World, b: Bullet, t_a: float, t_b: float, grid: Dictionary) -> void:
	var t := t_a
	while not b.dead and b.seg < b.path.size():
		var s: Array = b.path[b.seg]
		var s0 := maxf(t, s[S_T0])
		var s1 := minf(t_b, s[S_T1])
		if s1 > s0:
			var p0 := seg_pos(s, s0)
			var p1 := seg_pos(s, s1)
			var redirected_at := _test_segment(world, b, p0, p1, s0, s1, grid)
			if redirected_at >= 0.0:
				t = redirected_at  # new path starts here; keep sweeping it
				continue
		if t_b < s[S_T1]:
			return
		b.seg += 1
		t = s[S_T1]


## Returns the redirect time if the bullet hit a Mirror (path replaced), else -1.
func _test_segment(world: World, b: Bullet, p0: Vector3, p1: Vector3, s0: float, s1: float,
		grid: Dictionary) -> float:
	var cands := _candidates(grid, p0, p1, b.radius)
	if cands.is_empty():
		return -1.0
	var delta := p1 - p0
	var length := delta.length()
	if length < 1e-6:
		return -1.0
	var dir := delta / length
	var inflate := Vector3(b.radius, b.radius, b.radius)
	var reach := Hitbox.BOUND_RADIUS + b.radius
	var found := []
	for pose: Array in cands:
		# cheap reject: segment's closest approach to the player's center
		var to: Vector3 = (pose[1] as Vector3) + Vector3(0, Hitbox.HALF.y, 0) - p0
		var along := clampf(to.dot(dir), 0.0, length)
		if (to - dir * along).length_squared() > reach * reach:
			continue
		var id: int = pose[0]
		if id == b.attacker and b.attacker == b.owner:
			continue  # can't hit yourself (until reflected back)
		if b.hit_ids.has(id * 4) and b.hit_ids.has(id * 4 + 1):
			continue
		var victim: PlayerEntity = world.players.get(id)
		if victim == null or not world.can_damage(b.attacker, victim):
			continue  # teammates, own decoys: pass through
		var flags: int = pose[3]
		var mirror := Powerups.of(flags) == Powerups.MIRROR
		for slab in Hitbox.slabs_for(pose[1], pose[2], flags):
			if b.hit_ids.has(id * 4 + slab.index):
				continue  # piercing bullet already went through this slab
			var h := SimMath.ray_slab(p0, dir, slab.center, slab.yaw, slab.half + inflate, length)
			if h.x < 0.0:
				continue
			var front := mirror and h.z <= -slab.half.z - b.radius + 1e-3
			found.append([h.x, id, slab.index, Hitbox.is_crit(h.y, slab.half), front, pose])
	if found.is_empty():
		return -1.0
	found.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	for h: Array in found:
		var dist: float = h[0]
		var hit_t := s0 + (s1 - s0) * (dist / length)
		var hit_pos := p0 + dir * dist
		if h[4]:
			_reflect(world, b, h[1], h[5], hit_pos, dir, hit_t)
			return hit_t
		var victim: PlayerEntity = world.players.get(h[1])
		var dmg: float = b.damage * (SimConst.CRIT_MULT if h[3] else 1.0)
		var killed := world.apply_damage(victim, b.attacker, dmg, h[2])
		hits.append([b.attacker, h[1], h[3], killed])
		b.hit_ids[h[1] * 4 + h[2]] = true
		var f := 1 | (2 if h[3] else 0)
		if not b.pierce:
			b.dead = true
			despawns.append([b.id, f, h[1]])
			return -1.0
		despawns.append([b.id, f | 4, h[1]])  # pierced: flash victim, bullet lives on
	return -1.0


func _reflect(world: World, b: Bullet, mirror_id: int, pose: Array, at: Vector3, dir: Vector3, t: float) -> void:
	var n := SimMath.forward_flat(pose[2])
	var new_dir := SimMath.reflect(dir, n)
	var w := Weapons.get_data(b.weapon)
	b.attacker = mirror_id
	b.hit_ids.clear()
	b.bounces = maxi(0, b.bounces - b.seg)
	var origin := at + new_dir * EPS
	b.path = build_path(world.boxes, origin, new_dir, Weapons.speed(b.weapon, b.overcharged), t, b.bounces, w.range)
	b.seg = 0
	redirects.append([b.id, b.owner, b.weapon, b.overcharged, t, origin, new_dir, b.bounces, mirror_id])


## Players by 4m XZ cell, rebuilt each tick.
func _player_grid(world: World) -> Dictionary:
	var g := {}
	for pose: Array in world.current_poses():
		var p: Vector3 = pose[1]
		var key := _cell_key(floori(p.x / CELL), floori(p.z / CELL))
		if g.has(key):
			g[key].append(pose)
		else:
			g[key] = [pose]
	return g


static func _cell_key(cx: int, cz: int) -> int:
	return (cx + 512) * 1024 + (cz + 512)


func _candidates(grid: Dictionary, p0: Vector3, p1: Vector3, radius: float) -> Array:
	var pad := Hitbox.BOUND_RADIUS + radius
	var x0 := floori((minf(p0.x, p1.x) - pad) / CELL)
	var x1 := floori((maxf(p0.x, p1.x) + pad) / CELL)
	var z0 := floori((minf(p0.z, p1.z) - pad) / CELL)
	var z1 := floori((maxf(p0.z, p1.z) + pad) / CELL)
	if x0 == x1 and z0 == z1:
		return grid.get(_cell_key(x0, z0), [])
	var out := []
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var c: Array = grid.get(_cell_key(cx, cz), [])
			out.append_array(c)
	return out
