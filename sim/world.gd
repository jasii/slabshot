class_name World
extends RefCounted
## Authoritative game state: map collision + players (+ decoys). No rendering
## here, so the same class runs inside a headless dedicated server. Clients
## only use it for map collision during prediction.

signal player_killed(victim_id: int, killer_id: int)
signal player_spawned(id: int)
signal decoy_removed(id: int)

const DECOY_BASE := 64  # decoy entity ids: 64 + owner*2 + k

var boxes: Array[AABB] = []
var grid := CollisionGrid.new()
var spawns: Array[Vector4] = []  # xyz = pos, w = yaw
var players := {}  # id -> PlayerEntity (includes decoys)
var tick := 0
var team_mode := false
var friendly_fire := false


func load_map(map: MapData) -> void:
	boxes = map.boxes
	grid.build(boxes)
	spawns = map.spawns


func add_player(id: int, pname: String) -> PlayerEntity:
	var p := PlayerEntity.new()
	p.id = id
	p.name = pname
	players[id] = p
	respawn(p)
	return p


func remove_player(id: int) -> void:
	var p: PlayerEntity = players.get(id)
	if p:
		_clear_powerup(p)
	players.erase(id)


func humans() -> Array:
	return players.values().filter(func(p: PlayerEntity) -> bool: return not p.is_decoy)


func respawn(p: PlayerEntity) -> void:
	var sp := pick_spawn(p)
	_clear_powerup(p)
	p.state = PlayerState.new()
	p.state.pos = Vector3(sp.x, sp.y, sp.z)
	p.state.yaw = sp.w
	p.hp = SimConst.MAX_HP
	p.alive = true
	p.half_a = true
	p.half_b = false
	p.special = Weapons.NONE
	p.ammo = 0
	p.rail_charge = 0
	p.last_damage_tick = -100000
	player_spawned.emit(p.id)


## Farthest spawn from nearest living enemy.
func pick_spawn(p: PlayerEntity) -> Vector4:
	var best := spawns[randi() % spawns.size()]
	var best_d := -1.0
	for sp in spawns:
		var nearest := INF
		for other: PlayerEntity in players.values():
			if other == p or not other.alive or other.is_decoy:
				continue
			if team_mode and other.team == p.team:
				continue
			nearest = minf(nearest, other.state.pos.distance_squared_to(Vector3(sp.x, sp.y, sp.z)))
		nearest += randf() * 4.0  # break ties so empty servers don't always use spawn 0
		if nearest > best_d:
			best_d = nearest
			best = sp
	return best


func step_player(p: PlayerEntity, cmd: InputCmd) -> void:
	if not p.alive:
		return
	PlayerSim.step(p.state, cmd, grid)
	if p.powerup == Powerups.DECOY:
		_step_decoys(p, cmd)


## Health regen, respawns, powerup expiry. Call once per tick after inputs.
func step_world() -> void:
	tick += 1
	for p: PlayerEntity in players.values():
		if p.is_decoy:
			continue
		if not p.alive:
			if tick >= p.respawn_tick:
				respawn(p)
			continue
		if p.powerup != Powerups.NONE and tick >= p.powerup_end:
			_clear_powerup(p)
		if tick - p.last_damage_tick > SimConst.REGEN_DELAY_TICKS:
			if p.half_a and p.hp < SimConst.MAX_HP:
				p.hp = minf(p.hp + SimConst.REGEN_PER_TICK, SimConst.MAX_HP)
			if p.half_b and p.hp2 < SimConst.MAX_HP:
				p.hp2 = minf(p.hp2 + SimConst.REGEN_PER_TICK, SimConst.MAX_HP)


## Living entities as hit targets: Array of [id, pos, body_yaw, flags].
func current_poses() -> Array:
	var out := []
	for p: PlayerEntity in players.values():
		if p.alive:
			out.append([p.id, p.state.pos, p.body_yaw(tick), p.flags()])
	return out


func can_damage(attacker_id: int, victim: PlayerEntity) -> bool:
	if not victim.alive or attacker_id == victim.id:
		return false
	var a: PlayerEntity = players.get(attacker_id)
	if a == null:
		return true
	if victim.is_decoy and victim.owner_id == attacker_id:
		return false
	if team_mode and not friendly_fire and a.team == victim.team:
		return false
	return true


## Returns true if the hit destroyed the entity (player killed or decoy popped).
func apply_damage(victim: PlayerEntity, attacker_id: int, amount: float, slab_index: int) -> bool:
	if not can_damage(attacker_id, victim):
		return false
	victim.last_damage_tick = tick
	if victim.is_decoy:
		_remove_decoy(victim.id)
		return true
	if victim.powerup == Powerups.SPLIT:
		if slab_index == 1:
			victim.hp2 -= amount
			if victim.hp2 <= 0.0:
				victim.hp2 = 0.0
				victim.half_b = false
		else:
			victim.hp -= amount
			if victim.hp <= 0.0:
				victim.hp = 0.0
				victim.half_a = false
		if victim.half_a or victim.half_b:
			return false
	else:
		victim.hp -= amount
		if victim.hp > 0.0:
			return false
	_die(victim, attacker_id)
	return true


func _die(victim: PlayerEntity, attacker_id: int) -> void:
	victim.hp = 0.0
	victim.alive = false
	victim.deaths += 1
	victim.respawn_tick = tick + SimConst.RESPAWN_TICKS
	_clear_powerup(victim)
	victim.special = Weapons.NONE
	var a: PlayerEntity = players.get(attacker_id)
	if a and a != victim and not (team_mode and a.team == victim.team):
		a.kills += 1
	player_killed.emit(victim.id, attacker_id)


# ---------------------------------------------------------------- pickups

func give_weapon(p: PlayerEntity, weapon: int) -> void:
	p.special = weapon
	p.ammo = Weapons.get_data(weapon).ammo
	p.rail_charge = 0


func use_ammo(p: PlayerEntity) -> void:
	if p.special == Weapons.NONE:
		return
	p.ammo -= 1
	if p.ammo <= 0:
		p.special = Weapons.NONE
		p.ammo = 0


func give_powerup(p: PlayerEntity, type: int) -> void:
	_clear_powerup(p)
	p.powerup = type
	p.powerup_start = tick
	p.powerup_end = tick + Powerups.duration_ticks(type)
	match type:
		Powerups.SPLIT:
			p.hp = SimConst.MAX_HP
			p.hp2 = SimConst.MAX_HP
			p.half_a = true
			p.half_b = true
		Powerups.FOLD:
			p.state.speed_mult = Powerups.FOLD_SPEED
		Powerups.DECOY:
			_spawn_decoys(p)


func _clear_powerup(p: PlayerEntity) -> void:
	match p.powerup:
		Powerups.SPLIT:
			if not p.half_a:
				p.hp = p.hp2
			p.half_a = true
			p.half_b = false
			p.hp2 = 0.0
		Powerups.FOLD:
			p.state.speed_mult = 1.0
		Powerups.DECOY:
			for k in 2:
				_remove_decoy(DECOY_BASE + p.id * 2 + k)
	p.powerup = Powerups.NONE


func _spawn_decoys(src: PlayerEntity) -> void:
	var right := SimMath.right_flat(src.state.yaw)
	for k in 2:
		var d := PlayerEntity.new()
		d.id = DECOY_BASE + src.id * 2 + k
		d.name = src.name
		d.team = src.team
		d.color = src.color
		d.is_decoy = true
		d.owner_id = src.id
		d.decoy_mirror = k == 0
		d.decoy_yaw0 = src.state.yaw
		d.hp = 1.0
		d.state = src.state.copy()
		d.state.pos += right * (2.5 if k == 0 else -2.5)
		players[d.id] = d


func _remove_decoy(id: int) -> void:
	if players.has(id):
		players.erase(id)
		decoy_removed.emit(id)


## Decoys copy the owner's input; decoy 0 mirrors it left/right around the
## facing the owner had when picking up the powerup.
func _step_decoys(src: PlayerEntity, cmd: InputCmd) -> void:
	for k in 2:
		var d: PlayerEntity = players.get(DECOY_BASE + src.id * 2 + k)
		if d == null:
			continue
		var dc := cmd.copy()
		dc.buttons &= InputCmd.BTN_JUMP
		if d.decoy_mirror:
			dc.move_x = -cmd.move_x
			dc.set_angles(2.0 * d.decoy_yaw0 - cmd.yaw(), cmd.pitch())
		PlayerSim.step(d.state, dc, grid)
