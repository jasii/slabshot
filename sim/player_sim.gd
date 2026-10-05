class_name PlayerSim
## Shared movement step. Runs on server (authoritative) and on client
## (prediction/replay). Must stay deterministic: only reads state + cmd + map.


static func step(s: PlayerState, cmd: InputCmd, grid: CollisionGrid) -> void:
	var dt := SimConst.DT
	s.yaw = cmd.yaw()
	s.pitch = cmd.pitch()

	var wish := SimMath.forward_flat(s.yaw) * (cmd.move_z / 127.0) \
		+ SimMath.right_flat(s.yaw) * (cmd.move_x / 127.0)
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	if cmd.has(InputCmd.BTN_BLADE):
		s.blade_t = mini(s.blade_t + 1, SimConst.BLADE_TICKS)
	else:
		s.blade_t = maxi(s.blade_t - 1, 0)
	var max_speed := SimConst.MAX_SPEED * s.speed_mult * lerpf(1.0, SimConst.BLADE_SPEED, s.blade())
	if s.on_ground:
		_friction(s, dt)
		_accelerate(s, wish, max_speed, SimConst.GROUND_ACCEL, dt)
		if cmd.has(InputCmd.BTN_JUMP):
			s.vel.y = SimConst.JUMP_VELOCITY
			s.on_ground = false
	else:
		_accelerate(s, wish, max_speed, SimConst.AIR_ACCEL, dt)

	s.vel.y = maxf(s.vel.y - SimConst.GRAVITY * dt, -SimConst.MAX_FALL)
	SimMath.move_player(s, grid.near(s.pos), dt)


static func _friction(s: PlayerState, dt: float) -> void:
	var speed := Vector2(s.vel.x, s.vel.z).length()
	if speed < 0.001:
		s.vel.x = 0.0
		s.vel.z = 0.0
		return
	var drop := maxf(speed, SimConst.STOP_SPEED) * SimConst.FRICTION * dt
	var scale := maxf(speed - drop, 0.0) / speed
	s.vel.x *= scale
	s.vel.z *= scale


static func _accelerate(s: PlayerState, wish: Vector3, max_speed: float, accel: float, dt: float) -> void:
	var wish_len := wish.length()
	if wish_len < 0.001:
		return
	var wish_dir := wish / wish_len
	var target := max_speed * wish_len
	var current := s.vel.x * wish_dir.x + s.vel.z * wish_dir.z
	var add := target - current
	if add <= 0.0:
		return
	var amount := minf(accel * target * dt, add)
	s.vel.x += wish_dir.x * amount
	s.vel.z += wish_dir.z * amount
