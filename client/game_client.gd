class_name GameClient
extends Node3D
## Networked client.
##  - Local player: predicted every tick with the shared PlayerSim, reconciled
##    against the server's authoritative state (replay unacked inputs).
##  - Remote players: interpolated between snapshots, rendered interp_delay
##    ticks in the past.
##  - Clock: we run ahead of the server so inputs arrive just before they are
##    needed. Server reports "slack" (how early our inputs arrive); we nudge
##    our tick rate to hold it at TARGET_SLACK.
##  - Bullets: deterministic paths (Projectiles.build_path) drawn on OUR
##    predicted timeline, so incoming fire is shown exactly where the server
##    will test it against us. Own shots are predicted and later matched to
##    the server's bullet ids. Damage and hit markers come from the server.

signal left_game(reason: String)

const TARGET_SLACK := 2.0
const SNAP_KEEP := 64
const PING_INTERVAL := 0.5
const SMOOTH_SNAP_DIST := 2.0  # corrections bigger than this snap instantly
const SMOOTH_RATE := 12.0  # visual error decay per second

var headless := false  # bot client: no rendering
var player_name := "slab"
var input_source: Object  # LocalInput or BotInput: sample(tick), yaw, pitch, alt

# session
var joined := false
var my_slot := -1
var snap_div := 2
var server_name := ""
var infos := {}  # slot -> {name, color, team}
var scores := {}  # slot -> [kills, deaths]
var match_info := {"mode": 0, "state": 0, "end_tick": 0, "limit": 25, "t1": 0, "t2": 0,
	"winner": -1, "winner_name": ""}

# prediction
var world := World.new()  # used for map collision + trace only
var map: MapData
var tick := 0
var _acc := 0.0
var _time_scale := 1.0
var _slack_hold_until := 0
var pred := PlayerState.new()
var _cmds := {}  # tick -> InputCmd
var _states := {}  # tick -> PlayerState (after applying that tick's cmd)
var _local_alive := false
var _next_fire_tick := 0
var _rail_charge := 0
var _visual_offset := Vector3.ZERO
var _prev_render_pos := Vector3.ZERO

# private state from server ("you" block)
var my_special := Weapons.NONE
var my_ammo := 0
var my_powerup := Powerups.NONE
var my_powerup_end := 0

# snapshots / interpolation
var _snaps := {}  # tick -> Dictionary(id -> PackedInt32Array)
var _snap_order: Array[int] = []
var _newest_snap := 0
var _interp_tick := 0.0
var _interp_scale := 1.0
var _last_snap_ms := 0.0
var _jitter_ticks := 0.0

# stats
var rtt_ms := 0.0
var slack := 0.0
var corrections := 0
var last_correction := 0.0
var snaps_received := 0
var snaps_missed := 0
var _ping_t := 0.0
var _stat_t := 0.0

# render
var camera: Camera3D
var hud: Hud
var bullets: BulletFx
var _pred_bullets := {}  # tick*8+pellet -> temp key (negative)
var _tombstones := {}  # bullet id -> msec when it died (ignore late repeats)
var views := {}  # id -> PlayerView
var pickup_views: Array[PickupView] = []


func _ready() -> void:
	map = Arena01.build()
	world.load_map(map)
	Net.server_packet.connect(_on_packet)
	Net.disconnected.connect(func() -> void: left_game.emit("disconnected"))
	Net.connect_failed.connect(func() -> void: left_game.emit("connection failed"))
	if Net.local_client:
		_send_hello.call_deferred()
	else:
		Net.connected.connect(_send_hello)
	if headless:
		return
	add_child(MapBuilder.make_environment())
	add_child(MapBuilder.build(map))
	bullets = BulletFx.new()
	add_child(bullets)
	camera = Camera3D.new()
	camera.fov = Settings.fov
	camera.near = 0.05
	camera.far = 300.0
	add_child(camera)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	hud.client = self
	layer.add_child(hud)


func _send_hello() -> void:
	var b := Proto.buf(Proto.C_HELLO)
	b.put_u16(Proto.VERSION)
	b.put_utf8_string(player_name)
	Net.send_to_server(b.data_array, true)


# ---------------------------------------------------------------- packets

func _on_packet(data: PackedByteArray) -> void:
	if data.is_empty():
		return
	var b := Proto.reader(data)
	match b.get_u8():
		Proto.S_WELCOME:
			_on_welcome(b)
		Proto.S_SNAPSHOT:
			if joined:
				_on_snapshot(b)
		Proto.S_EVENT:
			_on_event(b)
		Proto.S_BULLETS:
			if joined:
				_decode_bullets(b, b.get_u32())
		Proto.S_PONG:
			var sent := b.get_u32()
			var sample := float(Time.get_ticks_msec() - sent)
			rtt_ms = sample if rtt_ms == 0.0 else lerpf(rtt_ms, sample, 0.2)
		Proto.S_REJECT:
			left_game.emit("rejected: " + b.get_utf8_string())


func _on_welcome(b: StreamPeerBuffer) -> void:
	my_slot = b.get_u8()
	var server_tick := b.get_u32()
	snap_div = b.get_u8()
	server_name = b.get_utf8_string()
	var n := b.get_u8()
	for i in n:
		_read_info(b)
	var np := b.get_u8()
	for i in np:
		var pos := Proto.get_qpos(b)
		var kind := b.get_u8()
		var type := b.get_u8()
		var avail := b.get_u8() == 1
		if not headless:
			var pv := PickupView.new()
			pv.position = pos
			add_child(pv)
			pv.setup(kind, type)
			pv.set_available(avail)
			pickup_views.append(pv)
	# Start ahead of the server; slack feedback converges from here.
	tick = server_tick + 6
	_interp_tick = server_tick - snap_div * 2
	if bullets:
		bullets.base_tick = tick
	joined = true
	print("[client] joined '%s' as slot %d" % [server_name, my_slot])


func _read_info(b: StreamPeerBuffer) -> void:
	var slot := b.get_u8()
	var pname := b.get_utf8_string()
	var col := Proto.get_color(b)
	var team := b.get_u8()
	infos[slot] = {"name": pname, "color": col, "team": team}
	if not scores.has(slot):
		scores[slot] = [0, 0]
	if headless:
		return
	if views.has(slot):
		views[slot].set_color(col)
	# recolor this player's decoys too
	for k in 2:
		var did := World.DECOY_BASE + slot * 2 + k
		if views.has(did):
			views[did].set_color(col)


func _on_event(b: StreamPeerBuffer) -> void:
	match b.get_u8():
		Proto.EV_PLAYER_INFO:
			_read_info(b)
		Proto.EV_PLAYER_LEFT:
			var slot := b.get_u8()
			infos.erase(slot)
			scores.erase(slot)
			_drop_view(slot)
		Proto.EV_KILL:
			var victim := b.get_u8()
			var killer := b.get_u8()
			var weapon := b.get_u8()
			if hud:
				hud.kill_feed(killer, victim, weapon)
		Proto.EV_HIT_CONFIRM:
			var f := b.get_u8()
			if hud:
				hud.hit_marker(f & 2 != 0, f & 4 != 0)
		Proto.EV_SPAWN:
			input_source.yaw = Proto.dqyaw(b.get_u16())
			input_source.pitch = 0.0
		Proto.EV_MATCH:
			match_info.mode = b.get_u8()
			match_info.state = b.get_u8()
			match_info.end_tick = b.get_u32()
			match_info.limit = b.get_u16()
			match_info.t1 = b.get_u16()
			match_info.t2 = b.get_u16()
			var w := b.get_u8()
			match_info.winner = w if w != 255 else -1
			match_info.winner_name = b.get_utf8_string()
		Proto.EV_SCORE:
			var slot := b.get_u8()
			var k := b.get_u16()
			var d := b.get_u16()
			scores[slot] = [k, d]
		Proto.EV_PICKUP:
			var i := b.get_u8()
			var avail := b.get_u8() == 1
			var type := b.get_u8()
			if i < pickup_views.size():
				pickup_views[i].set_type(type)
				pickup_views[i].set_available(avail)
		Proto.EV_DECOY_GONE:
			_drop_view(b.get_u8())


func _drop_view(id: int) -> void:
	if views.has(id):
		views[id].queue_free()
		views.erase(id)


func player_name_of(slot: int) -> String:
	return infos[slot].name if infos.has(slot) else "?"


func _on_snapshot(b: StreamPeerBuffer) -> void:
	var T := b.get_u32()
	var base_tick := b.get_u32()
	var srv_slack := b.get_8()
	var s := PlayerState.new()
	s.pos = Proto.get_vec3f(b)
	s.vel = Proto.get_vec3f(b)
	var yflags := b.get_u8()
	s.on_ground = yflags & 1 != 0
	var alive := yflags & 2 != 0
	s.blade_t = b.get_u8()
	var next_fire := b.get_u32()
	var special := b.get_8()
	var ammo := b.get_u8()
	var powerup := b.get_u8()
	var powerup_end := b.get_u32()
	s.speed_mult = Powerups.FOLD_SPEED if powerup == Powerups.FOLD else 1.0

	if T <= _newest_snap:
		return  # out of order / duplicate
	var ents: Dictionary
	if base_tick == 0:
		ents = {}
	elif _snaps.has(base_tick):
		ents = (_snaps[base_tick] as Dictionary).duplicate()
	else:
		return  # base gone; server will fall back to full once our ack moves on
	_decode_body(b, ents, T)

	if _newest_snap > 0:
		var gap := (T - _newest_snap) / snap_div - 1
		if gap > 0:
			snaps_missed += gap
	snaps_received += 1
	_snaps[T] = ents
	_snap_order.append(T)
	while _snap_order.size() > SNAP_KEEP:
		_snaps.erase(_snap_order.pop_front())
	_newest_snap = T

	if special != Weapons.NONE and special != my_special:
		input_source.alt = true  # auto-switch to a newly picked-up weapon
	my_special = special
	my_ammo = ammo
	my_powerup = powerup
	my_powerup_end = powerup_end
	pred.speed_mult = s.speed_mult

	_update_clocks(T, srv_slack)
	_reconcile(T, s, alive, next_fire)


func _decode_body(b: StreamPeerBuffer, ents: Dictionary, T: int) -> void:
	var n := b.get_u8()
	for i in n:
		var id := b.get_u8()
		var mask := b.get_u8()
		var e: PackedInt32Array
		if ents.has(id):
			e = (ents[id] as PackedInt32Array).duplicate()
		else:
			e = PackedInt32Array()
			e.resize(Proto.E_SIZE)
		if mask & Proto.M_POS:
			e[Proto.E_PX] = b.get_u16()
			e[Proto.E_PY] = b.get_u16()
			e[Proto.E_PZ] = b.get_u16()
		if mask & Proto.M_YAW:
			e[Proto.E_YAW] = b.get_u16()
		if mask & Proto.M_HP:
			e[Proto.E_HP] = b.get_u8()
			e[Proto.E_HP2] = b.get_u8()
		if mask & Proto.M_FLAGS:
			e[Proto.E_FLAGS] = b.get_u8()
		ents[id] = e
	var removed := b.get_u8()
	for i in removed:
		ents.erase(b.get_u8())
	_decode_bullets(b, T)


func _decode_bullets(b: StreamPeerBuffer, base_tick: int) -> void:
	if headless:
		return
	for i in b.get_u16():
		_on_bullet_spawn(Proto.get_spawn(b, base_tick))
	for i in b.get_u16():
		_on_bullet_redirect(Proto.get_redirect(b))
	for i in b.get_u16():
		_on_bullet_hit(Proto.get_despawn(b))


func _update_clocks(T: int, srv_slack_q: int) -> void:
	var now := Time.get_ticks_msec()
	# Input clock: hold server-side slack near target. Server value is an EMA,
	# so after a hard jump ignore it until fresh samples have flushed through.
	if srv_slack_q != -128 and now >= _slack_hold_until:
		slack = srv_slack_q / 4.0
		var err := slack - TARGET_SLACK - _jitter_ticks
		if absf(err) > 8.0:
			tick -= roundi(err)
			_time_scale = 1.0
			_slack_hold_until = now + int(rtt_ms) + 500
		else:
			_time_scale = 1.0 - clampf(err * 0.02, -0.08, 0.08)

	# Snapshot arrival jitter (EMA of deviation from expected spacing).
	if _last_snap_ms > 0.0:
		var expected := snap_div * 1000.0 / SimConst.TICK_RATE
		var dev := absf((now - _last_snap_ms) - expected) / (1000.0 / SimConst.TICK_RATE)
		_jitter_ticks = lerpf(_jitter_ticks, dev, 0.05)
	_last_snap_ms = now

	# Interp clock: render interp_delay() behind newest snapshot.
	var target := T - interp_delay()
	var d := target - _interp_tick
	if absf(d) > 12.0:
		_interp_tick = target
		_interp_scale = 1.0
	else:
		_interp_scale = 1.0 + clampf(d * 0.04, -0.1, 0.1)


func interp_delay() -> float:
	return snap_div * 2.0 + _jitter_ticks * 1.5


func _reconcile(T: int, server: PlayerState, alive: bool, next_fire: int) -> void:
	_local_alive = alive
	if T >= tick:
		pred = server
		return
	if next_fire > _next_fire_tick:
		_next_fire_tick = next_fire
	var predicted: PlayerState = _states.get(T)
	if predicted != null and predicted.pos.distance_squared_to(server.pos) < 1e-6 \
			and predicted.vel.distance_squared_to(server.vel) < 1e-4:
		return  # prediction was correct
	# Mismatch: rewind to server state and replay our unacknowledged inputs.
	var before := pred.pos
	var s := server
	_states[T] = s.copy()
	for t in range(T + 1, tick + 1):
		var cmd: InputCmd = _cmds.get(t)
		if cmd != null and alive:
			PlayerSim.step(s, cmd, world.grid)
		_states[t] = s.copy()
	pred = s
	var err := before - pred.pos
	last_correction = err.length()
	corrections += 1
	if last_correction < SMOOTH_SNAP_DIST:
		_visual_offset += err
	else:
		_visual_offset = Vector3.ZERO


# ---------------------------------------------------------------- ticking

func _process(delta: float) -> void:
	if not joined:
		return
	_ping_t += delta
	if _ping_t >= PING_INTERVAL:
		_ping_t = 0.0
		var p := Proto.buf(Proto.C_PING)
		p.put_u32(Time.get_ticks_msec())
		Net.send_to_server(p.data_array, false)

	_interp_tick += delta * SimConst.TICK_RATE * _interp_scale
	_acc += delta * _time_scale
	var steps := 0
	while _acc >= SimConst.DT and steps < 8:
		_acc -= SimConst.DT
		steps += 1
		_tick()
	if steps == 8:
		_acc = 0.0

	_visual_offset = _visual_offset.lerp(Vector3.ZERO, 1.0 - exp(-SMOOTH_RATE * delta))
	if not headless:
		_render()
	else:
		_stat_t += delta
		if _stat_t >= 5.0:
			_stat_t = 0.0
			print("[bot %s] tick %d rtt %d slack %.1f jitter %.2f snaps %d lost %d corr %d (last %.3f) in %.1f KB/s" % [
				player_name, tick, rtt_ms, slack, _jitter_ticks, snaps_received, snaps_missed,
				corrections, last_correction, Net.rate_in / 1024.0])


func active_weapon() -> int:
	return my_special if input_source.alt and my_special != Weapons.NONE else Weapons.PULSE


func rail_charge_frac() -> float:
	return float(_rail_charge) / Weapons.get_data(Weapons.RAIL).charge


func _tick() -> void:
	tick += 1
	var cmd: InputCmd = input_source.sample(tick)
	_cmds[tick] = cmd
	_prev_render_pos = pred.pos
	if _local_alive:
		PlayerSim.step(pred, cmd, world.grid)
		_predict_weapon(cmd)
	_states[tick] = pred.copy()
	_cmds.erase(tick - 128)
	_states.erase(tick - 128)
	_send_inputs()
	if bullets:
		bullets.update(tick)
		_hide_bullets_hitting_me()
		for k in 8:
			_pred_bullets.erase((tick - 180) * 8 + k)


func _send_inputs() -> void:
	var b := Proto.buf(Proto.C_INPUT)
	b.put_u32(_newest_snap)
	var n := mini(Proto.INPUT_REDUNDANCY, tick)
	var list: Array[InputCmd] = []
	for t in range(tick - n + 1, tick + 1):
		if _cmds.has(t):
			list.append(_cmds[t])
	b.put_u8(list.size())
	for c in list:
		Proto.put_cmd(b, c)
	Net.send_to_server(b.data_array, false)


## Mirrors the server's fire logic so our bullets appear instantly.
func _predict_weapon(cmd: InputCmd) -> void:
	var firing: bool = cmd.has(InputCmd.BTN_FIRE) and pred.blade_t == 0 \
		and match_info.state == MatchRules.State.PLAYING
	var weapon := active_weapon()
	if weapon == Weapons.RAIL:
		if not firing:
			_rail_charge = 0
		elif tick >= _next_fire_tick:
			_rail_charge += 1
			if _rail_charge >= Weapons.get_data(Weapons.RAIL).charge:
				_rail_charge = 0
				_predict_fire(weapon)
	else:
		_rail_charge = 0
		if firing and tick >= _next_fire_tick:
			_predict_fire(weapon)


func _predict_fire(weapon: int) -> void:
	var overcharged := my_powerup == Powerups.OVERCHARGE
	_next_fire_tick = tick + Weapons.interval(weapon, overcharged)
	if headless:
		return
	# Same inputs the server will use: eye at this tick + quantized aim.
	var cmd: InputCmd = _cmds[tick]
	var dir := SimMath.dir_from_angles(cmd.yaw(), cmd.pitch())
	var paths := _bullet_paths(weapon, overcharged, pred.eye(), dir, tick)
	for i in paths.size():
		var key := -1 - ((tick * 8 + i) % 1000000)
		_pred_bullets[tick * 8 + i] = key
		bullets.add(key, paths[i], my_slot, my_slot, weapon, _my_color())


func _bullet_paths(weapon: int, overcharged: bool, eye: Vector3, dir: Vector3, t: int) -> Array:
	var w := Weapons.get_data(weapon)
	var out := []
	for d in Weapons.pellet_dirs(weapon, dir, t):
		out.append(Projectiles.build_path(world.boxes, Projectiles.spawn_origin(eye, d), d,
			Weapons.speed(weapon, overcharged), t, w.get("bounces", 0), w.range))
	return out


func _my_color() -> Color:
	return infos[my_slot].color if infos.has(my_slot) else Color.WHITE


func _color_of(slot: int) -> Color:
	return infos[slot].color if infos.has(slot) else Color.WHITE


func _dead_recently(id: int) -> bool:
	return _tombstones.has(id) and Time.get_ticks_msec() - _tombstones[id] < 3000


func _on_bullet_spawn(e: Array) -> void:
	var first: int = e[0]
	var owner: int = e[1]
	var weapon: int = e[2]
	if not Weapons.DATA.has(weapon):
		return
	var t: int = e[4]
	if bullets.live.has(first) or _dead_recently(first):
		return  # redundant copy of an event we already applied
	var dir := SimMath.dir_from_angles(e[6] * TAU / 65536.0, e[7] * (PI * 0.5) / 32767.0)
	var paths := _bullet_paths(weapon, e[3], e[5], dir, t)
	for i in paths.size():
		var id := (first + i) & 0xFFFF
		if _dead_recently(id):
			continue
		var pk: Variant = _pred_bullets.get(t * 8 + i) if owner == my_slot else null
		if pk != null and bullets.live.has(pk):
			bullets.rekey(pk, id)  # our predicted bullet: adopt the server id
			bullets.set_path(id, paths[i], owner)
		else:
			bullets.add(id, paths[i], owner, owner, weapon, _color_of(owner))
		_pred_bullets.erase(t * 8 + i)


func _on_bullet_redirect(e: Array) -> void:
	var id: int = e[0]
	if _dead_recently(id):
		return
	var w := Weapons.get_data(e[2])
	var path := Projectiles.build_path(world.boxes, e[5], e[6], Weapons.speed(e[2], e[3]),
		e[4], e[7], w.range)
	if bullets.live.has(id):
		bullets.set_path(id, path, e[8])
	else:
		bullets.add(id, path, e[1], e[8], e[2], _color_of(e[1]))


func _on_bullet_hit(e: Array) -> void:
	var id: int = e[0]
	var flags: int = e[1]
	var victim: int = e[2]
	if views.has(victim):
		views[victim].flash_hit()
	if flags & Proto.HIT_PIERCED == 0:
		bullets.remove(id)
		_tombstones[id] = Time.get_ticks_msec()
	if _tombstones.size() > 4096:
		var now := Time.get_ticks_msec()
		for k in _tombstones.keys():
			if now - _tombstones[k] > 3000:
				_tombstones.erase(k)


## Hide enemy bullets that reach our predicted slab now instead of a round
## trip later (the server's hit event will remove them for real).
func _hide_bullets_hitting_me() -> void:
	if not _local_alive:
		return
	var rec := my_record()
	var flags: int = rec[Proto.E_FLAGS] if rec.size() > 0 else Powerups.F_ALIVE
	var my_team: int = infos[my_slot].team if infos.has(my_slot) else 0
	var center := pred.pos + Vector3(0, Hitbox.HALF.y, 0)
	var slabs := Hitbox.slabs_for(pred.pos, pred.body_yaw(), flags)
	for b: BulletFx.Live in bullets.live.values():
		if b.hidden or b.attacker == my_slot:
			continue
		if my_team != 0 and infos.has(b.attacker) and infos[b.attacker].team == my_team:
			continue
		var p1 := bullets.pos_of(b, tick)
		if p1.distance_squared_to(center) > 4.0:
			continue
		var p0 := bullets.pos_of(b, tick - 1)
		var d := p1 - p0
		var length := d.length()
		if length < 1e-6:
			continue
		var r := Vector3(b.radius, b.radius, b.radius)
		for slab in slabs:
			if SimMath.ray_slab(p0, d / length, slab.center, slab.yaw, slab.half + r, length).x >= 0.0:
				bullets.hide_bullet(b.key)
				break

# ---------------------------------------------------------------- interpolation

## Remote entities' interpolated poses at fractional server tick t:
## [id, pos, body_yaw, flags, record]. Excludes ourselves.
func remote_poses(t: float) -> Array:
	var out := []
	if _snap_order.is_empty():
		return out
	var a_tick := _snap_order[0]
	var b_tick := a_tick
	for st in _snap_order:
		if st <= t:
			a_tick = st
			b_tick = st
		else:
			b_tick = st
			break
	var a: Dictionary = _snaps[a_tick]
	var bb: Dictionary = _snaps[b_tick]
	var frac := 0.0 if b_tick == a_tick else clampf((t - a_tick) / float(b_tick - a_tick), 0.0, 1.0)
	for id in bb:
		if id == my_slot:
			continue
		var eb: PackedInt32Array = bb[id]
		if not Powerups.alive(eb[Proto.E_FLAGS]):
			continue
		var ea: PackedInt32Array = a.get(id, eb)
		if not Powerups.alive(ea[Proto.E_FLAGS]):
			ea = eb  # just respawned: don't lerp across the map
		var pos := Proto.record_pos(ea).lerp(Proto.record_pos(eb), frac)
		var yaw := lerp_angle(Proto.dqyaw(ea[Proto.E_YAW]), Proto.dqyaw(eb[Proto.E_YAW]), frac)
		out.append([id, pos, yaw, eb[Proto.E_FLAGS], eb])
	return out


func my_record() -> PackedInt32Array:
	if _snaps.has(_newest_snap):
		return (_snaps[_newest_snap] as Dictionary).get(my_slot, PackedInt32Array())
	return PackedInt32Array()


func is_alive() -> bool:
	return _local_alive


func ticks_left() -> int:
	return match_info.end_tick - _newest_snap


func _view_for(id: int) -> PlayerView:
	var v: PlayerView = views.get(id)
	if v:
		return v
	var oid := id if id < World.DECOY_BASE else (id - World.DECOY_BASE) / 2
	if not infos.has(oid):
		return null
	v = PlayerView.new()
	add_child(v)
	v.setup(infos[oid].color)
	views[id] = v
	return v


func _render() -> void:
	var frac := _acc / SimConst.DT
	var pos := _prev_render_pos.lerp(pred.pos, frac) + _visual_offset
	camera.position = pos + Vector3(0, SimConst.EYE_HEIGHT, 0)
	camera.rotation = Vector3(input_source.pitch, input_source.yaw, 0)
	camera.fov = Settings.fov
	bullets.set_now(tick + frac)

	var radar := my_powerup == Powerups.RADAR
	var my_team: int = infos[my_slot].team if infos.has(my_slot) else 0
	for v: PlayerView in views.values():
		v.visible = false
	for pose: Array in remote_poses(_interp_tick):
		var v := _view_for(pose[0])
		if v == null:
			continue
		v.visible = true
		v.set_pose(pose[1], pose[2])
		v.apply_flags(pose[3])
		var oid: int = pose[0] if pose[0] < World.DECOY_BASE else (pose[0] - World.DECOY_BASE) / 2
		var enemy: bool = my_team == 0 or not infos.has(oid) or infos[oid].team != my_team
		v.set_xray(radar and enemy)

	hud.extra_info = "%s  slot %d  players %d\nrtt %d ms  slack %.1f  jitter %.1f t  interp %.1f t\nin %.1f KB/s  out %.1f KB/s  snaps lost %d/%d\ncorrections %d (last %.3f m)" % [
		server_name, my_slot, infos.size(), rtt_ms, slack, _jitter_ticks, interp_delay(),
		Net.rate_in / 1024.0, Net.rate_out / 1024.0, snaps_missed, snaps_received + snaps_missed,
		corrections, last_correction]
