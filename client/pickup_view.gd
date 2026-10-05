class_name PickupView
extends Node3D
## Floating spinning cube over a flat pad. Weapons: weapon color cube.
## Powerups: tilted cube in the powerup's color, slightly larger.

var kind := 0
var type := 0
var _cube: MeshInstance3D
var _mat: StandardMaterial3D
var _pad_mat: StandardMaterial3D
var _t := randf() * TAU


func setup(p_kind: int, p_type: int) -> void:
	kind = p_kind
	var pad := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.7
	pm.bottom_radius = 0.7
	pm.height = 0.04
	pm.radial_segments = 24
	pad.mesh = pm
	_pad_mat = StandardMaterial3D.new()
	_pad_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pad.material_override = _pad_mat
	pad.position.y = 0.02
	add_child(pad)

	_cube = MeshInstance3D.new()
	var cm := BoxMesh.new()
	var s := 0.42 if kind == Pickups.Kind.POWERUP else 0.32
	cm.size = Vector3(s, s, s) if kind == Pickups.Kind.POWERUP else Vector3(0.7, s * 0.6, s * 0.6)
	_cube.mesh = cm
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cube.material_override = _mat
	_cube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cube)
	set_type(p_type)


func set_type(p_type: int) -> void:
	type = p_type
	var c: Color
	if kind == Pickups.Kind.POWERUP:
		c = Powerups.DATA[type].color if Powerups.DATA.has(type) else Color.WHITE
	else:
		c = Weapons.get_data(type).color
	_mat.albedo_color = c
	_pad_mat.albedo_color = c.lerp(Color(0.6, 0.6, 0.62), 0.6)


func set_available(on: bool) -> void:
	_cube.visible = on


func _process(delta: float) -> void:
	_t += delta
	_cube.position.y = 1.0 + sin(_t * 2.0) * 0.12
	if kind == Pickups.Kind.POWERUP:
		_cube.rotation = Vector3(0.6, _t * 1.5, 0.6)
	else:
		_cube.rotation = Vector3(0, _t * 1.2, 0)
