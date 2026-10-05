extends SceneTree
## Headless sim tests:
##   godot --headless --path . --script res://tests/run_tests.gd

var _fails := 0
var _passes := 0


func _init() -> void:
	_test_slab_face_vs_edge()
	_test_crit()
	_test_movement()
	_test_determinism()
	_test_grid_equivalence()
	_test_input_quantization()
	_test_combat()
	_test_powerups()
	_test_blade()
	print("\n%d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
		push_error("FAIL: " + label)
		print("FAIL: " + label)


func _test_slab_face_vs_edge() -> void:
	var center := Vector3(0, 0.95, -10)
	var half := Hitbox.HALF
	var origin := Vector3(0.3, 1.0, 0)  # 0.3m off center
	var dir := Vector3(0, 0, -1)
	# Target facing +Z (yaw = PI looks toward +Z): full face toward shooter.
	var face := SimMath.ray_slab(origin, dir, center, PI, half, 100.0)
	check(face.x > 9.9 and face.x < 10.1, "face-on hit at 0.3 offset")
	# Edge-on (yaw = PI/2): 0.3 offset must miss, only 0.04 sliver remains.
	var edge := SimMath.ray_slab(origin, dir, center, PI * 0.5, half, 100.0)
	check(edge.x < 0.0, "edge-on miss at 0.3 offset")
	var edge_center := SimMath.ray_slab(Vector3(0.02, 1.0, 0), dir, center, PI * 0.5, half, 100.0)
	check(edge_center.x > 0.0, "edge-on hit dead center")
	# 45 degrees: projected width ~ 0.9*cos45 = 0.64 -> 0.3 offset hits
	var diag := SimMath.ray_slab(origin, dir, center, PI * 0.75, half, 100.0)
	check(diag.x > 0.0, "45deg hit at 0.3 offset")


func _test_crit() -> void:
	var half := Hitbox.HALF
	check(Hitbox.is_crit(0.9, half), "top is crit")
	check(not Hitbox.is_crit(0.0, half), "middle not crit")


func _make_world() -> World:
	var w := World.new()
	w.load_map(Arena01.build())
	return w


func _run(s: PlayerState, grid: CollisionGrid, ticks: int, mz: int, mx := 0, yaw := 0.0) -> void:
	for i in ticks:
		var c := InputCmd.new()
		c.move_z = mz
		c.move_x = mx
		c.set_angles(yaw, 0)
		PlayerSim.step(s, c, grid)


func _test_movement() -> void:
	var w := _make_world()
	var s := PlayerState.new()
	s.pos = Vector3(0, 3, 20)
	_run(s, w.grid, 120, 0)
	check(s.on_ground and absf(s.pos.y) < 0.001, "falls and lands on floor (y=%f)" % s.pos.y)

	# Walk -Z (yaw 0) from z=20 into low wall at z=16 (1.3 high, not steppable)
	s.pos = Vector3(0, 0, 20)
	_run(s, w.grid, 120, 127)
	check(s.pos.z > 16.4 - 0.01 and s.pos.z < 17.0, "low wall blocks (z=%f)" % s.pos.z)

	# Walk up east stairs: start x=12 facing +X (yaw = -PI/2)
	s = PlayerState.new()
	s.pos = Vector3(12, 0, 0)
	_run(s, w.grid, 10, 0)
	_run(s, w.grid, 120, 127, 0, -PI * 0.5)
	check(s.pos.y > 1.99 and s.pos.x > 18.0, "climbs stairs to ledge (x=%f y=%f)" % [s.pos.x, s.pos.y])

	# Pillar collision: run into pillar at (9,4) from (9,0) heading +Z (yaw = PI)
	s = PlayerState.new()
	s.pos = Vector3(9, 0, 0)
	_run(s, w.grid, 120, 127, 0, PI)
	check(s.pos.z < 3.0 - SimConst.PLAYER_RADIUS + 0.01, "pillar blocks (z=%f)" % s.pos.z)


func _test_determinism() -> void:
	var w := _make_world()
	var cmds: Array[InputCmd] = []
	for i in 600:
		var c := InputCmd.new()
		c.move_z = int(sin(i * 0.05) * 127)
		c.move_x = int(cos(i * 0.031) * 127)
		c.set_angles(i * 0.013, sin(i * 0.02))
		if i % 40 == 0:
			c.buttons |= InputCmd.BTN_JUMP
		cmds.append(c)
	var a := PlayerState.new()
	a.pos = Vector3(-5, 0, 5)
	var b := a.copy()
	for c in cmds:
		PlayerSim.step(a, c, w.grid)
	# Replay from a mid-point copy, like reconciliation does
	var mid := PlayerState.new()
	mid.pos = b.pos
	for i in 300:
		PlayerSim.step(b, cmds[i], w.grid)
	mid = b.copy()
	for i in range(300, 600):
		PlayerSim.step(mid, cmds[i], w.grid)
	check(a.pos == mid.pos and a.vel == mid.vel, "replay from snapshot is bit-identical")


func _test_input_quantization() -> void:
	var c := InputCmd.new()
	c.set_angles(-0.5, 1.2)
	check(absf(angle_difference(c.yaw(), -0.5)) < 0.0002, "yaw quantization")
	check(absf(c.pitch() - 1.2) < 0.0002, "pitch quantization")


## Broadphase must not change results: random walk with grid vs all boxes.
func _test_grid_equivalence() -> void:
	var w := _make_world()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var ok := true
	for run in 20:
		var a := PlayerState.new()
		a.pos = Vector3(rng.randf_range(-22, 22), 3.0, rng.randf_range(-22, 22))
		var b := a.copy()
		for i in 600:
			var c := InputCmd.new()
			c.move_x = rng.randi_range(-127, 127)
			c.move_z = rng.randi_range(-127, 127)
			c.set_angles(rng.randf() * TAU, 0)
			if rng.randf() < 0.03:
				c.buttons |= InputCmd.BTN_JUMP
			PlayerSim.step(a, c, w.grid)
			# brute force path: same step but all boxes
			b.yaw = c.yaw()
			b.pitch = c.pitch()
			var g2 := CollisionGrid.new()
			g2._all = w.boxes
			g2._w = 0
			PlayerSim.step(b, c, g2)
			if a.pos != b.pos or a.vel != b.vel:
				ok = false
				break
		if not ok:
			break
	check(ok, "grid broadphase matches brute force")

## Arena with a shooter at (0,0,14) facing -Z down the open north lane.
func _range(targets: Array) -> Array:
	var w := _make_world()
	var bs := Projectiles.new()
	var shooter := w.add_player(0, "shooter")
	shooter.state.pos = Vector3(0, 0, 14)
	shooter.state.yaw = 0.0
	var id := 1
	for t: Array in targets:  # [pos, yaw, powerup]
		var p := w.add_player(id, "t%d" % id)
		p.state.pos = t[0]
		p.state.yaw = t[1]
		if t.size() > 2 and t[2] != Powerups.NONE:
			w.give_powerup(p, t[2])
		id += 1
	return [w, bs, shooter]


func _shoot(w: World, bs: Projectiles, shooter: PlayerEntity, weapon: int, offset_x := 0.0, ticks := 120, overcharged := false) -> void:
	shooter.state.pos.x = offset_x
	var cmd := InputCmd.new()
	cmd.set_angles(shooter.state.yaw, 0.0)
	bs.fire(w, shooter, weapon, overcharged, cmd, w.tick)
	for i in ticks:
		w.tick += 1
		bs.step(w, w.tick)


func _test_combat() -> void:
	# Face-on target takes the hit (bullet arrives later, not instantly).
	var r := _range([[Vector3(0, 0, 10), PI]])
	var w: World = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE, 0.0, 5)
	check(w.players[1].hp == 100.0, "bullet still in flight after 5 ticks")
	for i in 60:
		w.tick += 1
		r[1].step(w, w.tick)
	check(w.players[1].hp < 100.0, "pulse bullet hits face-on target")

	# Edge-on target: 0.3m off-center misses, dead-center hits.
	r = _range([[Vector3(0, 0, 10), PI * 0.5]])
	w = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE, 0.3)
	check(w.players[1].hp == 100.0, "edge-on dodge: 0.3m offset misses")
	_shoot(w, r[1], r[2], Weapons.PULSE, 0.0)
	check(w.players[1].hp < 100.0, "edge-on: center shot still hits")

	# Rail pierces two slabs; pulse stops at the first.
	r = _range([[Vector3(0, 0, 11), PI], [Vector3(0, 0, 9), PI]])
	w = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE)
	check(w.players[1].hp < 100.0 and w.players[2].hp == 100.0, "pulse stops at first slab")
	r = _range([[Vector3(0, 0, 11), PI], [Vector3(0, 0, 9), PI]])
	w = r[0]
	_shoot(w, r[1], r[2], Weapons.RAIL)
	check(not w.players[1].alive and not w.players[2].alive, "rail pierces and one-shots both")

	# Ricochet path: two bounces = three segments.
	var path := Projectiles.build_path(w.boxes, Vector3(0, 4.5, -20), Vector3(1, 0, 0.3).normalized(), 16.0, 0.0, 2, 120.0)
	check(path.size() == 3, "ricochet path bounces twice (%d segments)" % path.size())
	var again := Projectiles.build_path(w.boxes, Vector3(0, 4.5, -20), Vector3(1, 0, 0.3).normalized(), 16.0, 0.0, 2, 120.0)
	check(str(path) == str(again), "paths are deterministic")

	# Scatter: 7 pellets in cone.
	var dirs := Weapons.pellet_dirs(Weapons.SCATTER, Vector3(0, 0, -1), 123)
	var ok := dirs.size() == 7
	for d in dirs:
		ok = ok and d.angle_to(Vector3(0, 0, -1)) < 0.13
	check(ok, "scatter: 7 pellets in cone")

	# Mirror: front reflects back into the shooter; back is vulnerable.
	r = _range([[Vector3(0, 0, 10), PI, Powerups.MIRROR]])
	w = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE)
	check(w.players[1].hp == 100.0 and w.players[0].hp < 100.0, "mirror front reflects into shooter")
	r = _range([[Vector3(0, 0, 10), 0.0, Powerups.MIRROR]])
	w = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE)
	check(w.players[1].hp < 100.0, "mirror back takes damage")

	# Teammates: bullets pass through.
	r = _range([[Vector3(0, 0, 10), PI]])
	w = r[0]
	w.team_mode = true
	w.players[0].team = 1
	w.players[1].team = 1
	_shoot(w, r[1], r[2], Weapons.PULSE)
	check(w.players[1].hp == 100.0, "team mode: bullets pass through teammates")


func _test_powerups() -> void:
	# Split: center gap lets a bullet through; offset shot hits a half.
	var r := _range([[Vector3(0, 0, 10), PI, Powerups.SPLIT]])
	var w: World = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE, 0.0)
	check(w.players[1].hp == 100.0 and w.players[1].hp2 == 100.0, "split: center gap misses")
	_shoot(w, r[1], r[2], Weapons.PULSE, 0.55)
	check(w.players[1].hp < 100.0 or w.players[1].hp2 < 100.0, "split: offset shot hits a half")

	# Fold: eye-height bullet passes over a folded slab.
	r = _range([[Vector3(0, 0, 10), PI, Powerups.FOLD]])
	w = r[0]
	_shoot(w, r[1], r[2], Weapons.PULSE)
	check(w.players[1].hp == 100.0, "fold: eye-height shot passes over")

	# Split damage model: both halves must die.
	w = _make_world()
	var p := w.add_player(0, "a")
	w.add_player(1, "b")
	w.give_powerup(p, Powerups.SPLIT)
	w.apply_damage(p, 1, 150.0, 0)
	check(p.alive and not p.half_a and p.half_b, "split: one half down, still alive")
	w.apply_damage(p, 1, 150.0, 1)
	check(not p.alive, "split: both halves down kills")

	# Decoys spawn and die in one hit, no kill credit.
	var q := w.add_player(2, "c")
	w.give_powerup(q, Powerups.DECOY)
	var decoy: PlayerEntity = w.players.get(World.DECOY_BASE + 2 * 2)
	check(decoy != null and decoy.is_decoy, "decoy spawned")
	var kills_before: int = w.players[1].kills
	check(w.apply_damage(decoy, 1, 14.0, 0) and not w.players.has(decoy.id), "decoy pops in one hit")
	check(w.players[1].kills == kills_before, "decoy gives no kill credit")

	# Spin: body yaw advances half a turn per half period.
	var s := w.add_player(3, "d")
	w.give_powerup(s, Powerups.SPIN)
	var y0 := s.body_yaw(w.tick)
	check(absf(absf(angle_difference(y0, s.body_yaw(w.tick + Powerups.SPIN_PERIOD_TICKS / 2))) - PI) < 0.01, "spin half turn per half period")

	# Team mode: no friendly fire.
	w.team_mode = true
	w.players[0].team = 1
	w.players[1].team = 1
	w.respawn(w.players[0])
	check(not w.can_damage(1, w.players[0]), "team mode blocks friendly fire")

func _test_blade() -> void:
	var w := _make_world()
	var s := PlayerState.new()
	s.pos = Vector3(-12, 0, 10)  # open lane
	var c := InputCmd.new()
	c.move_z = 127
	c.buttons = InputCmd.BTN_BLADE
	for i in 120:
		PlayerSim.step(s, c, w.grid)
	var blade_speed := Vector2(s.vel.x, s.vel.z).length()
	check(s.blade_t == SimConst.BLADE_TICKS, "blade: fully turned after holding")
	check(absf(blade_speed - SimConst.MAX_SPEED * SimConst.BLADE_SPEED) < 0.05, "blade: slow movement (%.2f m/s)" % blade_speed)
	check(absf(angle_difference(s.yaw, s.body_yaw()) - PI * 0.5) < 1e-4, "blade: slab turned 90 deg, aim unchanged")
	c.buttons = 0
	for i in SimConst.BLADE_TICKS:
		PlayerSim.step(s, c, w.grid)
	check(s.blade_t == 0, "blade: turns back after release")

	# Bladed target facing the shooter is edge-on: 0.3m offset misses.
	var r := _range([[Vector3(0, 0, 10), PI]])
	w = r[0]
	w.players[1].state.blade_t = SimConst.BLADE_TICKS
	_shoot(w, r[1], r[2], Weapons.PULSE, 0.3)
	check(w.players[1].hp == 100.0, "blade: bladed target dodges 0.3m offset shot")