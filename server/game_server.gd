class_name GameServer
extends Node
## Authoritative server. Fixed 60Hz tick in _physics_process:
##   1. apply each client's input for this tick (or repeat last if missing)
##   2. spawn projectiles; step all projectiles against current positions
##   3. pickups, regen/respawn, powerup expiry, match rules
##   5. every snap_div ticks: send per-client delta snapshots
## Runs identically in a headless dedicated server and in a listen host.

const SNAP_HISTORY := 64
const MAX_FUTURE_TICKS := 60
const SECTION_MAX := 600  # bullet-event bytes per packet section
const EMPTY_EVENTS := [0, 0, 0, 0, 0, 0]

class Conn:
	var peer_id := 0
	var slot := -1
	var cmds := {}  # tick -> InputCmd
	var last_cmd := InputCmd.new()
	var ack_tick := 0  # newest snapshot tick client has decoded
	var slack := 0.0  # how many ticks early inputs arrive (EMA)
	var has_slack := false

var world := World.new()
var bullets := Projectiles.new()
var rules := MatchRules.new()
var pickups := Pickups.new()
var snap_div := 2  # 30Hz snapshots
var max_players := Proto.MAX_PLAYERS
var server_name := "Slabshot server"
var dummy_count := 0
var dummy_powerups := false  # practice: dummies cycle through powerups
var mode := MatchRules.Mode.FFA
var rotate_modes := false
var score_limit := 0  # 0 = mode default
var time_limit_min := 0.0  # 0 = mode default
var port := Proto.DEFAULT_PORT
var master_url := ""
var master_key := ""
var public_host := ""

var conns := {}  # peer_id -> Conn
var _slot_used := {}  # slot -> peer_id (or -1 for dummies)
var _snap_ticks := PackedInt32Array()
var _snap_ents: Array[Dictionary] = []  # id -> PackedInt32Array
var _event_rounds: Array = []  # newest first: [spawns, redirects, despawns]
var _dummies := {}  # slot -> phase
var _map: MapData
var _query: QueryResponder
var _master: MasterClient

# perf stats
var tick_ms := 0.0
var prof_sim := 0.0
var prof_snap := 0.0  # per snapshot round
var prof_fire := 0.0  # accumulated per stats window
var snap_bytes := 0


func _ready() -> void:
	_map = Arena01.build()
	world.load_map(_map)
	world.player_killed.connect(_on_killed)
	world.player_spawned.connect(_on_spawned)
	world.decoy_removed.connect(_on_decoy_removed)
	_snap_ticks.resize(SNAP_HISTORY)
	_snap_ticks.fill(-1)
	_snap_ents.resize(SNAP_HISTORY)
	Net.client_packet.connect(_on_packet)
	Net.peer_left.connect(_on_peer_left)
	_configure(mode)
	pickups.build(_map)
	_start_match()
	for i in dummy_count:
		_add_dummy(i)

	_query = QueryResponder.new()
	_query.server = self
	add_child(_query)
	_query.listen(port + Proto.QUERY_PORT_OFFSET)
	if master_url != "":
		_master = MasterClient.new()
		_master.server = self
		_master.url = master_url
		_master.key = master_key
		_master.public_host = public_host
		add_child(_master)


func human_count() -> int:
	return conns.size()


func _alloc_slot() -> int:
	for s in Proto.MAX_PLAYERS:
		if not _slot_used.has(s):
			return s
	return -1


func _add_dummy(i: int) -> void:
	var slot := _alloc_slot()
	if slot < 0:
		return
	_slot_used[slot] = -1
	var p := world.add_player(slot, "dummy%d" % i)
	p.team = rules.assign_team(world)
	p.color = rules.color_for(p)
	_dummies[slot] = i * 0.77


# ---------------------------------------------------------------- packets

func _on_packet(peer_id: int, data: PackedByteArray) -> void:
	if data.is_empty():
		return
	var b := Proto.reader(data)
	var op := b.get_u8()
	match op:
		Proto.C_HELLO:
			_on_hello(peer_id, b)
		Proto.C_INPUT:
			if conns.has(peer_id):
				_on_input(conns[peer_id], b)
		Proto.C_PING:
			var out := Proto.buf(Proto.S_PONG)
			out.put_u32(b.get_u32())
			Net.send_to_peer(peer_id, out.data_array, false)


func _on_hello(peer_id: int, b: StreamPeerBuffer) -> void:
	if conns.has(peer_id):
		return
	var version := b.get_u16()
	var pname := b.get_utf8_string().strip_edges().left(20)
	if pname.is_empty():
		pname = "slab"
	var slot := _alloc_slot()
	if version != Proto.VERSION or slot < 0 or conns.size() >= max_players:
		var rej := Proto.buf(Proto.S_REJECT)
		rej.put_utf8_string("version mismatch" if version != Proto.VERSION else "server full")
		Net.send_to_peer(peer_id, rej.data_array, true)
		Net.kick.call_deferred(peer_id)
		return

	var c := Conn.new()
	c.peer_id = peer_id
	c.slot = slot
	conns[peer_id] = c
	_slot_used[slot] = peer_id
	var team := rules.assign_team(world)
	var p := world.add_player(slot, pname)
	p.team = team
	p.color = rules.color_for(p)
	if team != 0:
		world.respawn(p)  # re-pick spawn now that team is known

	var w := Proto.buf(Proto.S_WELCOME)
	w.put_u8(slot)
	w.put_u32(world.tick)
	w.put_u8(snap_div)
	w.put_utf8_string(server_name)
	var hs := world.humans()
	w.put_u8(hs.size())
	for other: PlayerEntity in hs:
		_put_info(w, other)
	w.put_u8(pickups.spots.size())
	for s in pickups.spots:
		Proto.put_qpos(w, s.pos)
		w.put_u8(s.kind)
		w.put_u8(s.type)
		w.put_u8(1 if s.available else 0)
	Net.send_to_peer(peer_id, w.data_array, true)
	Net.send_to_peer(peer_id, _match_event(), true)
	for other: PlayerEntity in hs:
		Net.send_to_peer(peer_id, _score_event(other), true)

	var ev := Proto.buf(Proto.S_EVENT)
	ev.put_u8(Proto.EV_PLAYER_INFO)
	_put_info(ev, p)
	_broadcast(ev.data_array, true, peer_id)
	print("[server] %s joined (peer %d, slot %d, team %d)" % [pname, peer_id, slot, team])


func _put_info(b: StreamPeerBuffer, p: PlayerEntity) -> void:
	b.put_u8(p.id)
	b.put_utf8_string(p.name)
	Proto.put_color(b, p.color)
	b.put_u8(p.team)


func _on_input(c: Conn, b: StreamPeerBuffer) -> void:
	var ack := b.get_u32()
	if ack > c.ack_tick and ack <= world.tick:
		c.ack_tick = ack
	var n := mini(b.get_u8(), 8)
	var newest := -1
	for i in n:
		var cmd := Proto.get_cmd(b)
		newest = maxi(newest, cmd.tick)
		if cmd.tick <= world.tick or cmd.tick > world.tick + MAX_FUTURE_TICKS:
			continue  # late (already simulated) or bogus
		c.cmds[cmd.tick] = cmd
	if newest >= 0:
		# Slack sample: how far ahead of the sim this packet's newest input is.
		# Includes late/far-future packets so the client clock can correct.
		var sample := float(newest - world.tick)
		c.slack = sample if not c.has_slack else lerpf(c.slack, sample, 0.2)
		c.has_slack = true


func _on_peer_left(peer_id: int) -> void:
	var c: Conn = conns.get(peer_id)
	if c == null:
		return
	conns.erase(peer_id)
	_slot_used.erase(c.slot)
	var p: PlayerEntity = world.players.get(c.slot)
	print("[server] %s left" % (p.name if p else "?"))
	world.remove_player(c.slot)
	var ev := Proto.buf(Proto.S_EVENT)
	ev.put_u8(Proto.EV_PLAYER_LEFT)
	ev.put_u8(c.slot)
	_broadcast(ev.data_array, true)


func _broadcast(data: PackedByteArray, reliable: bool, except_peer := 0) -> void:
	for pid in conns:
		if pid != except_peer:
			Net.send_to_peer(pid, data, reliable)


func _conn_for_slot(slot: int) -> Conn:
	var pid: int = _slot_used.get(slot, -1)
	return conns.get(pid)


# ---------------------------------------------------------------- tick

func _physics_process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var T := world.tick + 1

	for c: Conn in conns.values():
		var p: PlayerEntity = world.players[c.slot]
		var cmd: InputCmd = c.cmds.get(T)
		if cmd == null:
			cmd = c.last_cmd.copy()  # lost/late: repeat last input
			cmd.tick = T
		else:
			c.cmds.erase(T)
			c.last_cmd = cmd
		_simulate(p, cmd, T)

	_step_dummies(T)
	world.step_world()  # world.tick == T after this
	_step_bullets(T)
	for i in pickups.step(world):
		_broadcast(_pickup_event(i), true)
	match rules.step(world):
		1:
			_broadcast(_match_event(), true)
		2:
			_next_match()
	var t1 := Time.get_ticks_usec()
	if T % snap_div == 0:
		_send_snapshots()
	var t3 := Time.get_ticks_usec()
	tick_ms = lerpf(tick_ms, (t3 - t0) / 1000.0, 0.05)
	prof_sim = lerpf(prof_sim, (t1 - t0) / 1000.0, 0.05)
	if T % snap_div == 0:
		prof_snap = lerpf(prof_snap, (t3 - t1) / 1000.0, 0.1)


func _simulate(p: PlayerEntity, cmd: InputCmd, T: int) -> void:
	if not p.alive:
		return
	p.want_alt = cmd.has(InputCmd.BTN_ALT)
	world.step_player(p, cmd)
	var weapon := p.active_weapon()
	# no firing while bladed (or still turning back out of it)
	var firing := cmd.has(InputCmd.BTN_FIRE) and p.state.blade_t == 0 \
		and rules.state == MatchRules.State.PLAYING
	if weapon == Weapons.RAIL:
		# Hold to charge; fires automatically when full; release cancels.
		if not firing:
			p.rail_charge = 0
		elif T >= p.next_fire_tick:
			p.rail_charge += 1
			if p.rail_charge >= Weapons.get_data(Weapons.RAIL).charge:
				p.rail_charge = 0
				_fire(p, weapon, cmd, T)
	else:
		p.rail_charge = 0
		if firing and T >= p.next_fire_tick:
			_fire(p, weapon, cmd, T)


func _fire(p: PlayerEntity, weapon: int, cmd: InputCmd, T: int) -> void:
	var overcharged := p.powerup == Powerups.OVERCHARGE
	p.next_fire_tick = T + Weapons.interval(weapon, overcharged)
	if weapon != Weapons.PULSE:
		world.use_ammo(p)
	bullets.fire(world, p, weapon, overcharged, cmd, T)


## Advance bullets, then tell shooters what they hit.
func _step_bullets(T: int) -> void:
	var tf := Time.get_ticks_usec()
	bullets.step(world, T)
	var confirms := {}  # attacker -> flags
	for h: Array in bullets.hits:
		var f: int = confirms.get(h[0], 0) | 1 | (2 if h[2] else 0) | (4 if h[3] else 0)
		confirms[h[0]] = f
	bullets.hits.clear()
	for attacker in confirms:
		var c := _conn_for_slot(attacker)
		if c:
			var ev := Proto.buf(Proto.S_EVENT)
			ev.put_u8(Proto.EV_HIT_CONFIRM)
			ev.put_u8(confirms[attacker])
			Net.send_to_peer(c.peer_id, ev.data_array, true)
	prof_fire += (Time.get_ticks_usec() - tf) / 1000.0

func _on_spawned(slot: int) -> void:
	var c := _conn_for_slot(slot)
	if c == null:
		return
	var ev := Proto.buf(Proto.S_EVENT)
	ev.put_u8(Proto.EV_SPAWN)
	ev.put_u16(Proto.qyaw(world.players[slot].state.yaw))
	Net.send_to_peer(c.peer_id, ev.data_array, true)


func _on_killed(victim_id: int, killer_id: int) -> void:
	var victim: PlayerEntity = world.players.get(victim_id)
	var killer: PlayerEntity = world.players.get(killer_id)
	var ev := Proto.buf(Proto.S_EVENT)
	ev.put_u8(Proto.EV_KILL)
	ev.put_u8(victim_id)
	ev.put_u8(killer_id if killer else 255)
	ev.put_u8(killer.active_weapon() if killer else 0)
	_broadcast(ev.data_array, true)
	if victim:
		_broadcast(_score_event(victim), true)
	if killer and killer != victim:
		_broadcast(_score_event(killer), true)
	if victim and rules.on_kill(world, victim, killer):
		_broadcast(_match_event(), true)
	elif rules.is_team():
		_broadcast(_match_event(), true)  # team score changed


func _on_decoy_removed(id: int) -> void:
	var ev := Proto.buf(Proto.S_EVENT)
	ev.put_u8(Proto.EV_DECOY_GONE)
	ev.put_u8(id)
	_broadcast(ev.data_array, true)


func _step_dummies(T: int) -> void:
	var t := T * SimConst.DT
	for slot in _dummies:
		var d: PlayerEntity = world.players[slot]
		if not d.alive:
			continue
		var ph: float = _dummies[slot]
		var dc := InputCmd.new()
		dc.tick = T
		dc.set_angles(ph + t * (0.4 + fmod(ph, 1.5)), 0.0)
		dc.move_x = int(sin(t * 0.7 + ph) * 127.0) if int(ph * 10) % 2 == 0 else 0
		world.step_player(d, dc)
		if dummy_powerups and d.powerup == Powerups.NONE and (T + slot * 41) % 240 == 0:
			world.give_powerup(d, 1 + (T / 240 + slot) % Powerups.COUNT)


# ---------------------------------------------------------------- match flow

func _configure(m: int) -> void:
	rules.configure(m)
	if score_limit > 0:
		rules.score_limit = score_limit
	if time_limit_min > 0.0:
		rules.time_limit_ticks = int(time_limit_min * 60.0 * SimConst.TICK_RATE)
	world.team_mode = rules.is_team()


func _start_match() -> void:
	rules.start(world.tick)
	pickups.reset(world.tick)
	print("[server] match start: %s" % MatchRules.mode_name(rules.mode))


func _next_match() -> void:
	if rotate_modes:
		var m := MatchRules.Mode.TDM if rules.mode == MatchRules.Mode.FFA else MatchRules.Mode.FFA
		_configure(m)
		var counts := [0, 0, 0]
		for p: PlayerEntity in world.humans():
			p.team = 0
		for p: PlayerEntity in world.humans():
			if rules.is_team():
				p.team = 1 if counts[1] <= counts[2] else 2
				counts[p.team] += 1
			p.color = rules.color_for(p)
			var ev := Proto.buf(Proto.S_EVENT)
			ev.put_u8(Proto.EV_PLAYER_INFO)
			_put_info(ev, p)
			_broadcast(ev.data_array, true)
	_start_match()
	for p: PlayerEntity in world.humans():
		p.kills = 0
		p.deaths = 0
		world.respawn(p)
		_broadcast(_score_event(p), true)
	for i in pickups.spots.size():
		_broadcast(_pickup_event(i), true)
	_broadcast(_match_event(), true)


func _match_event() -> PackedByteArray:
	var b := Proto.buf(Proto.S_EVENT)
	b.put_u8(Proto.EV_MATCH)
	b.put_u8(rules.mode)
	b.put_u8(rules.state)
	b.put_u32(rules.end_tick)
	b.put_u16(rules.score_limit)
	b.put_u16(rules.team_scores[1])
	b.put_u16(rules.team_scores[2])
	b.put_u8(rules.winner if rules.winner >= 0 else 255)
	b.put_utf8_string(rules.winner_name)
	return b.data_array


func _score_event(p: PlayerEntity) -> PackedByteArray:
	var b := Proto.buf(Proto.S_EVENT)
	b.put_u8(Proto.EV_SCORE)
	b.put_u8(p.id)
	b.put_u16(p.kills)
	b.put_u16(p.deaths)
	return b.data_array


func _pickup_event(i: int) -> PackedByteArray:
	var s := pickups.spots[i]
	var b := Proto.buf(Proto.S_EVENT)
	b.put_u8(Proto.EV_PICKUP)
	b.put_u8(i)
	b.put_u8(1 if s.available else 0)
	b.put_u8(s.type)
	return b.data_array


# ---------------------------------------------------------------- snapshots

func _send_snapshots() -> void:
	var T := world.tick
	var ents := {}
	for p: PlayerEntity in world.players.values():
		ents[p.id] = Proto.entity_record(p, T)
	var si := T % SNAP_HISTORY
	_snap_ticks[si] = T
	_snap_ents[si] = ents

	var sections := _bullet_events(T)  # same for every client
	var body_cache := {}  # base tick -> PackedByteArray (shared by clients with same base)
	snap_bytes = 0
	for c: Conn in conns.values():
		var base_tick := c.ack_tick
		var bi := base_tick % SNAP_HISTORY
		if base_tick <= 0 or T - base_tick >= SNAP_HISTORY or _snap_ticks[bi] != base_tick:
			base_tick = 0
		var body: PackedByteArray = body_cache.get(base_tick, PackedByteArray())
		if body.is_empty():
			body = _encode_body(ents, _snap_ents[bi] if base_tick > 0 else {})
			body_cache[base_tick] = body

		var p: PlayerEntity = world.players[c.slot]
		var h := Proto.buf(Proto.S_SNAPSHOT)
		h.put_u32(T)
		h.put_u32(base_tick)
		# input slack in 1/4 ticks; -128 = no sample yet
		h.put_8(clampi(roundi(c.slack * 4.0), -127, 127) if c.has_slack else -128)
		# "you" block: exact state for reconciliation + private weapon/powerup info
		Proto.put_vec3f(h, p.state.pos)
		Proto.put_vec3f(h, p.state.vel)
		h.put_u8((1 if p.state.on_ground else 0) | (2 if p.alive else 0))
		h.put_u8(p.state.blade_t)
		h.put_u32(p.next_fire_tick)
		h.put_8(p.special)
		h.put_u8(p.ammo)
		h.put_u8(p.powerup)
		h.put_u32(p.powerup_end)
		var pkt := h.data_array
		pkt.append_array(body)
		# first event section rides in the snapshot if it fits; the rest (or all,
		# if the body is big) go in separate S_BULLETS packets.
		var rest := 0
		if pkt.size() + sections[0].size() <= Proto.MTU_SAFE:
			pkt.append_array(sections[0])
			rest = 1
		else:
			pkt.append_array(PackedByteArray(EMPTY_EVENTS))
		snap_bytes += pkt.size()
		Net.send_to_peer(c.peer_id, pkt, false)
		for i in range(rest, sections.size()):
			if sections[i].size() <= 6:
				continue
			var bp := Proto.buf(Proto.S_BULLETS)
			bp.put_u32(T)
			bp.put_data(sections[i])
			snap_bytes += bp.get_size()
			Net.send_to_peer(c.peer_id, bp.data_array, false)


func _encode_body(ents: Dictionary, base: Dictionary) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	var changed := []
	for id in ents:
		var e: PackedInt32Array = ents[id]
		var mask := Proto.M_ALL
		if base.has(id):
			var o: PackedInt32Array = base[id]
			mask = 0
			if e[Proto.E_PX] != o[Proto.E_PX] or e[Proto.E_PY] != o[Proto.E_PY] or e[Proto.E_PZ] != o[Proto.E_PZ]:
				mask |= Proto.M_POS
			if e[Proto.E_YAW] != o[Proto.E_YAW]:
				mask |= Proto.M_YAW
			if e[Proto.E_HP] != o[Proto.E_HP] or e[Proto.E_HP2] != o[Proto.E_HP2]:
				mask |= Proto.M_HP
			if e[Proto.E_FLAGS] != o[Proto.E_FLAGS]:
				mask |= Proto.M_FLAGS
		if mask != 0:
			changed.append([id, mask, e])
	b.put_u8(changed.size())
	for item in changed:
		var e: PackedInt32Array = item[2]
		var mask: int = item[1]
		b.put_u8(item[0])
		b.put_u8(mask)
		if mask & Proto.M_POS:
			b.put_u16(e[Proto.E_PX])
			b.put_u16(e[Proto.E_PY])
			b.put_u16(e[Proto.E_PZ])
		if mask & Proto.M_YAW:
			b.put_u16(e[Proto.E_YAW])
		if mask & Proto.M_HP:
			b.put_u8(e[Proto.E_HP])
			b.put_u8(e[Proto.E_HP2])
		if mask & Proto.M_FLAGS:
			b.put_u8(e[Proto.E_FLAGS])
	var removed := []
	for id in base:
		if not ents.has(id):
			removed.append(id)
	b.put_u8(removed.size())
	for id in removed:
		b.put_u8(id)
	return b.data_array


## Bullet events for this snapshot: this round's spawns/redirects/hits plus
## the previous EVENT_REDUNDANCY-1 rounds, so every event rides in several
## snapshots. Returns sections (each fits a packet with room for a body):
## [u16 n, spawns..][u16 n, redirects..][u16 n, despawns..]
func _bullet_events(T: int) -> Array[PackedByteArray]:
	_event_rounds.push_front([bullets.spawns, bullets.redirects, bullets.despawns])
	bullets.spawns = []
	bullets.redirects = []
	bullets.despawns = []
	if _event_rounds.size() > Proto.EVENT_REDUNDANCY:
		_event_rounds.pop_back()

	# encode every entry once, oldest round first
	var entries := [[], [], []]
	for i in range(_event_rounds.size() - 1, -1, -1):
		var r: Array = _event_rounds[i]
		for e: Array in r[0]:
			var eb := _new_buf()
			Proto.put_spawn(eb, e, T)
			entries[0].append(eb.data_array)
		for e: Array in r[1]:
			var eb := _new_buf()
			Proto.put_redirect(eb, e)
			entries[1].append(eb.data_array)
		for e: Array in r[2]:
			var eb := _new_buf()
			Proto.put_despawn(eb, e)
			entries[2].append(eb.data_array)

	# pack greedily into sections of at most SECTION_MAX bytes
	var sections: Array[PackedByteArray] = []
	var idx := [0, 0, 0]
	while true:
		var out := _new_buf()
		var budget := SECTION_MAX - 6
		for kind in 3:
			var list: Array = entries[kind]
			var start: int = idx[kind]
			var n := 0
			var body := PackedByteArray()
			while start + n < list.size() and body.size() + (list[start + n] as PackedByteArray).size() <= budget:
				body.append_array(list[start + n])
				n += 1
			budget -= body.size()
			out.put_u16(n)
			out.put_data(body)
			idx[kind] = start + n
		sections.append(out.data_array)
		if idx[0] >= entries[0].size() and idx[1] >= entries[1].size() and idx[2] >= entries[2].size():
			break
	return sections

func _new_buf() -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	return b