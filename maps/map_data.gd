class_name MapData
extends RefCounted
## Map = list of boxes + spawn points + pickup spots. Drives both collision
## and rendering, so there is exactly one source of truth for geometry.

var name := ""
var boxes: Array[AABB] = []
var shades: PackedFloat32Array = []  # per-box grey level for rendering
var spawns: Array[Vector4] = []  # xyz pos, w yaw
var weapon_spots: Array = []  # [pos: Vector3, weapon: int]
var powerup_spots: Array[Vector3] = []


func add_box(center: Vector3, size: Vector3, shade: float) -> void:
	boxes.append(AABB(center - size * 0.5, size))
	shades.append(shade)


## Box resting on y=0 (or at given base height).
func add_block(x: float, z: float, w: float, d: float, h: float, shade: float, base := 0.0) -> void:
	add_box(Vector3(x, base + h * 0.5, z), Vector3(w, h, d), shade)


## Adds a block in all 4 mirrored quadrants (x,z), (-x,z), (x,-z), (-x,-z).
func add_mirrored4(x: float, z: float, w: float, d: float, h: float, shade: float) -> void:
	for sx in [1.0, -1.0]:
		for sz in [1.0, -1.0]:
			add_block(x * sx, z * sz, w, d, h, shade)


## Spawn facing the arena center.
func add_spawn(pos: Vector3) -> void:
	var yaw := atan2(pos.x, pos.z)  # forward = (-sin, -cos) points to origin
	spawns.append(Vector4(pos.x, pos.y, pos.z, yaw))
