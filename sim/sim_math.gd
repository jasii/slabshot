class_name SimMath
## Ray tests and collision. Pure functions, no engine physics, so server,
## client prediction and lag-comp rewind all produce identical results.


static func dir_from_angles(yaw: float, pitch: float) -> Vector3:
	var cp := cos(pitch)
	return Vector3(-sin(yaw) * cp, sin(pitch), -cos(yaw) * cp)


static func forward_flat(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0, -cos(yaw))


static func right_flat(yaw: float) -> Vector3:
	return Vector3(cos(yaw), 0, -sin(yaw))


## Ray vs axis-aligned box. Returns entry distance, or -1 on miss.
## Unrolled per axis: GDScript loop + Vector3 indexing is several times slower.
static func ray_aabb(origin: Vector3, dir: Vector3, box: AABB, max_t: float) -> float:
	var t_min := 0.0
	var t_max := max_t
	var lo := box.position
	var hi := box.end
	var t1: float
	var t2: float
	if absf(dir.x) < 1e-9:
		if origin.x < lo.x or origin.x > hi.x:
			return -1.0
	else:
		t1 = (lo.x - origin.x) / dir.x
		t2 = (hi.x - origin.x) / dir.x
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
		if t_min > t_max:
			return -1.0
	if absf(dir.y) < 1e-9:
		if origin.y < lo.y or origin.y > hi.y:
			return -1.0
	else:
		t1 = (lo.y - origin.y) / dir.y
		t2 = (hi.y - origin.y) / dir.y
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
		if t_min > t_max:
			return -1.0
	if absf(dir.z) < 1e-9:
		if origin.z < lo.z or origin.z > hi.z:
			return -1.0
	else:
		t1 = (lo.z - origin.z) / dir.z
		t2 = (hi.z - origin.z) / dir.z
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
		if t_min > t_max:
			return -1.0
	return t_min


## Outward face normal of a box at a point on its surface (for ricochet).
static func aabb_normal_at(point: Vector3, box: AABB) -> Vector3:
	var best := INF
	var n := Vector3.UP
	var lo := box.position
	var hi := box.end
	for axis in 3:
		var dlo := absf(point[axis] - lo[axis])
		var dhi := absf(point[axis] - hi[axis])
		if dlo < best:
			best = dlo
			n = Vector3.ZERO
			n[axis] = -1.0
		if dhi < best:
			best = dhi
			n = Vector3.ZERO
			n[axis] = 1.0
	return n


## Ray vs slab (box rotated by yaw around Y). Returns Vector3(t, local_y,
## local_z) of the entry point; local_y is height from slab center, local_z
## < 0 means the front face (slabs face local -Z). t < 0 on miss.
static func ray_slab(origin: Vector3, dir: Vector3, center: Vector3, yaw: float,
		half: Vector3, max_t: float) -> Vector3:
	var inv_rot := Basis(Vector3.UP, -yaw)
	var lo := inv_rot * (origin - center)
	var ld := inv_rot * dir
	var t := ray_aabb(lo, ld, AABB(-half, half * 2.0), max_t)
	if t < 0.0:
		return Vector3(-1.0, 0.0, 0.0)
	return Vector3(t, lo.y + ld.y * t, lo.z + ld.z * t)


static func reflect(dir: Vector3, n: Vector3) -> Vector3:
	return dir - n * (2.0 * dir.dot(n))


## Nearest world hit along ray. Returns Vector2(t, box_index) or (-1, -1).
static func ray_world(origin: Vector3, dir: Vector3, boxes: Array[AABB], max_t: float) -> Vector2:
	var best_t := max_t
	var best_i := -1
	for i in boxes.size():
		var t := ray_aabb(origin, dir, boxes[i], best_t)
		if t >= 0.0 and t < best_t:
			best_t = t
			best_i = i
	if best_i < 0:
		return Vector2(-1.0, -1.0)
	return Vector2(best_t, best_i)


## Move cylinder (feet at s.pos) through static boxes. Horizontal first with
## step-up, then vertical with landing/ceiling.
static func move_player(s: PlayerState, boxes: Array[AABB], dt: float) -> void:
	var r := SimConst.PLAYER_RADIUS
	var h := SimConst.PLAYER_HEIGHT

	s.pos.x += s.vel.x * dt
	s.pos.z += s.vel.z * dt
	for box in boxes:
		var top := box.end.y
		if s.pos.y >= top - 0.001 or s.pos.y + h <= box.position.y:
			continue
		var cx := clampf(s.pos.x, box.position.x, box.end.x)
		var cz := clampf(s.pos.z, box.position.z, box.end.z)
		var dx := s.pos.x - cx
		var dz := s.pos.z - cz
		var d2 := dx * dx + dz * dz
		if d2 >= r * r:
			continue
		if s.on_ground and top - s.pos.y <= SimConst.STEP_HEIGHT:
			s.pos.y = top
			continue
		var n := Vector2.ZERO
		var pen := 0.0
		if d2 > 1e-10:
			var d := sqrt(d2)
			n = Vector2(dx / d, dz / d)
			pen = r - d
		else:
			var left := s.pos.x - box.position.x
			var right := box.end.x - s.pos.x
			var back := s.pos.z - box.position.z
			var front := box.end.z - s.pos.z
			var m := minf(minf(left, right), minf(back, front))
			if m == left:
				n = Vector2(-1, 0)
				pen = left + r
			elif m == right:
				n = Vector2(1, 0)
				pen = right + r
			elif m == back:
				n = Vector2(0, -1)
				pen = back + r
			else:
				n = Vector2(0, 1)
				pen = front + r
		s.pos.x += n.x * pen
		s.pos.z += n.y * pen
		var vn := s.vel.x * n.x + s.vel.z * n.y
		if vn < 0.0:
			s.vel.x -= vn * n.x
			s.vel.z -= vn * n.y

	var prev_y := s.pos.y
	s.pos.y += s.vel.y * dt
	s.on_ground = false
	for box in boxes:
		var cx := clampf(s.pos.x, box.position.x, box.end.x)
		var cz := clampf(s.pos.z, box.position.z, box.end.z)
		var dx := s.pos.x - cx
		var dz := s.pos.z - cz
		if dx * dx + dz * dz >= r * r:
			continue
		if s.vel.y <= 0.0 and prev_y >= box.end.y - 0.001 and s.pos.y < box.end.y:
			s.pos.y = box.end.y
			s.vel.y = 0.0
			s.on_ground = true
		elif s.vel.y > 0.0 and prev_y + h <= box.position.y + 0.001 and s.pos.y + h > box.position.y:
			s.pos.y = box.position.y - h
			s.vel.y = 0.0
