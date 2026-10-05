class_name BulletFx
extends MultiMeshInstance3D
## Client-side bullets. Paths come from Projectiles.build_path (same as the
## server). Each bullet is one MultiMesh instance moved by the shader; the
## CPU updates an instance only on spawn, bounce (segment change) or death.
## Times are ticks on the client's predicted timeline.

const CAPACITY := 4096
## Bullets are drawn bigger than their hitbox (bullet-hell convention:
## grazes that look close are misses, never the other way round).
const VISUAL_SCALE := 1.5
const HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3(0, -1000, 0))

class Live:
	var key := 0
	var inst := 0
	var path: Array
	var seg := 0
	var owner := -1
	var attacker := -1  # who it can't hurt (owner, or Mirror holder after reflect)
	var weapon := 0
	var radius := 0.1
	var color := Color.WHITE
	var hidden := false

var base_tick := 0.0  # shader time origin (keeps float32 precision)
var live := {}  # key -> Live
var _free: Array[int] = []
var _mat: ShaderMaterial


func _init() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 10
	mesh.rings = 6
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://client/bullet.gdshader")
	mesh.material = _mat
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = CAPACITY
	for i in CAPACITY:
		multimesh.set_instance_transform(i, HIDDEN)
		_free.append(CAPACITY - 1 - i)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-200, -50, -200), Vector3(400, 150, 400))


func add(key: int, path: Array, owner: int, attacker: int, weapon: int, color: Color) -> void:
	if live.has(key):
		remove(key)
	if _free.is_empty():
		return
	var b := Live.new()
	b.key = key
	b.inst = _free.pop_back()
	b.path = path
	b.owner = owner
	b.attacker = attacker
	b.weapon = weapon
	b.radius = Weapons.get_data(weapon).radius
	b.color = color
	live[key] = b
	_apply_seg(b)


func set_path(key: int, path: Array, attacker: int) -> void:
	var b: Live = live.get(key)
	if b == null:
		return
	b.path = path
	b.seg = 0
	b.attacker = attacker
	_apply_seg(b)


func rekey(old: int, new: int) -> void:
	var b: Live = live.get(old)
	if b == null:
		return
	live.erase(old)
	if live.has(new):
		remove(new)
	b.key = new
	live[new] = b


func remove(key: int) -> void:
	var b: Live = live.get(key)
	if b == null:
		return
	multimesh.set_instance_transform(b.inst, HIDDEN)
	_free.append(b.inst)
	live.erase(key)


func hide_bullet(key: int) -> void:
	var b: Live = live.get(key)
	if b and not b.hidden:
		b.hidden = true
		multimesh.set_instance_transform(b.inst, HIDDEN)


## Advance segments / expire. Call once per client tick.
func update(now: float) -> void:
	var dead := []
	for b: Live in live.values():
		while b.seg < b.path.size() and now >= b.path[b.seg][Projectiles.S_T1]:
			b.seg += 1
			if b.seg < b.path.size():
				_apply_seg(b)
		if b.seg >= b.path.size():
			dead.append(b.key)
	for k in dead:
		remove(k)


func set_now(now: float) -> void:
	_mat.set_shader_parameter("now_ticks", now - base_tick)


func pos_of(b: Live, now: float) -> Vector3:
	var s: Array = b.path[mini(b.seg, b.path.size() - 1)]
	return Projectiles.seg_pos(s, now)


func _apply_seg(b: Live) -> void:
	if b.hidden or b.seg >= b.path.size():
		return
	var s: Array = b.path[b.seg]
	var vel: Vector3 = s[Projectiles.S_VEL]
	multimesh.set_instance_transform(b.inst, Transform3D(Basis.IDENTITY, s[Projectiles.S_ORIGIN]))
	multimesh.set_instance_custom_data(b.inst, Color(vel.x, vel.y, vel.z, float(s[Projectiles.S_T0]) - base_tick))
	multimesh.set_instance_color(b.inst, Color(b.color, b.radius * VISUAL_SCALE))
