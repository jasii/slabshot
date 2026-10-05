class_name PlayerView
extends Node3D
## Visual for one player or decoy: flat colored slab(s) with a lighter crit
## strip on top. Layout follows the replicated powerup flags so what you see
## is exactly the hitbox the server traces (Split halves, Fold size).

const GHOST_MIN_ALPHA := 0.05

var _halves: Array[Node3D] = []
var _mat: StandardMaterial3D
var _crit_mat: StandardMaterial3D
var _xray_mat: StandardMaterial3D
var _mirror: MeshInstance3D
var _color := Color.WHITE
var _flash := 0.0
var _flags := -1
var _xray := false
var _last_pos := Vector3.ZERO
var _speed := 0.0
var _last_shot := 0.0
var _alpha := 1.0


func setup(color: Color) -> void:
	_mat = _unshaded(color)
	_crit_mat = _unshaded(color.lightened(0.45))
	_xray_mat = _unshaded(color)
	_xray_mat.no_depth_test = true
	_xray_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_xray_mat.albedo_color = Color(color, 0.35)
	_xray_mat.render_priority = 1
	for i in 2:
		_halves.append(_make_half())
	var plate := BoxMesh.new()
	plate.size = Vector3(SimConst.SLAB_WIDTH, SimConst.PLAYER_HEIGHT, 0.01)
	_mirror = MeshInstance3D.new()
	_mirror.mesh = plate
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.92, 0.97, 1.0)
	mm.metallic = 1.0
	mm.roughness = 0.05
	mm.emission_enabled = true
	mm.emission = Color(0.5, 0.6, 0.7)
	_mirror.material_override = mm
	_mirror.position = Vector3(0, SimConst.PLAYER_HEIGHT * 0.5, -SimConst.SLAB_DEPTH * 0.5 - 0.01)
	_mirror.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mirror)
	set_color(color)
	apply_flags(Powerups.F_ALIVE)


func set_color(c: Color) -> void:
	_color = c
	_mat.albedo_color = c
	_crit_mat.albedo_color = c.lightened(0.45)
	_xray_mat.albedo_color = Color(c, 0.35)
	_apply_alpha()


func set_pose(pos: Vector3, yaw: float) -> void:
	position = pos
	rotation = Vector3(0, yaw, 0)


func set_xray(on: bool) -> void:
	if on == _xray:
		return
	_xray = on
	_mat.next_pass = _xray_mat if on else null
	_crit_mat.next_pass = _xray_mat if on else null


func flash_hit() -> void:
	_flash = 0.08
	_mat.albedo_color = Color.WHITE


func note_shot() -> void:
	_last_shot = Time.get_ticks_msec() / 1000.0


## Rebuild slab layout when powerup / split state changes.
func apply_flags(flags: int) -> void:
	if flags == _flags:
		return
	_flags = flags
	var pu := Powerups.of(flags)
	var a: Node3D = _halves[0]
	var b: Node3D = _halves[1]
	a.scale = Vector3.ONE
	a.position = Vector3.ZERO
	b.visible = false
	a.visible = true
	match pu:
		Powerups.SPLIT:
			a.scale = Vector3(0.5, 1, 1)
			b.scale = Vector3(0.5, 1, 1)
			a.position = Vector3(-Hitbox.SPLIT_OFFSET, 0, 0)
			b.position = Vector3(Hitbox.SPLIT_OFFSET, 0, 0)
			a.visible = flags & Powerups.F_HALF_A != 0
			b.visible = flags & Powerups.F_HALF_B != 0
		Powerups.FOLD:
			a.scale = Vector3(0.5, 0.5, 1)
	_mirror.visible = pu == Powerups.MIRROR
	_apply_alpha()


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash -= delta
		if _flash <= 0.0:
			_mat.albedo_color = Color(_color, _alpha)
	if delta > 0.0:
		var v := (position - _last_pos) / delta
		_speed = lerpf(_speed, Vector2(v.x, v.z).length(), 0.2)
	_last_pos = position
	if Powerups.of(_flags) == Powerups.GHOST:
		var since_shot := Time.get_ticks_msec() / 1000.0 - _last_shot
		var target := clampf(GHOST_MIN_ALPHA + _speed / SimConst.MAX_SPEED * 0.8
			+ maxf(0.0, 1.0 - since_shot * 2.0), GHOST_MIN_ALPHA, 1.0)
		_alpha = lerpf(_alpha, target, 0.25)
		_apply_alpha()
	elif _alpha != 1.0:
		_alpha = 1.0
		_apply_alpha()
	if Powerups.of(_flags) == Powerups.OVERCHARGE:
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.02)
		_crit_mat.albedo_color = _color.lerp(Color.WHITE, pulse)


func _apply_alpha() -> void:
	var t := BaseMaterial3D.TRANSPARENCY_ALPHA if _alpha < 0.999 else BaseMaterial3D.TRANSPARENCY_DISABLED
	_mat.transparency = t
	_crit_mat.transparency = t
	_mat.albedo_color = Color(_color, _alpha)
	_crit_mat.albedo_color = Color(_color.lightened(0.45), _alpha)


func _make_half() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var h := SimConst.PLAYER_HEIGHT
	var crit_h := h * SimConst.CRIT_FRACTION
	var body_h := h - crit_h
	var body := _box(Vector3(SimConst.SLAB_WIDTH, body_h, SimConst.SLAB_DEPTH), _mat)
	body.position.y = body_h * 0.5
	root.add_child(body)
	var crit := _box(Vector3(SimConst.SLAB_WIDTH, crit_h, SimConst.SLAB_DEPTH), _crit_mat)
	crit.position.y = body_h + crit_h * 0.5
	root.add_child(crit)
	return root


func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m


func _box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
