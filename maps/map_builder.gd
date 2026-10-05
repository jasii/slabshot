class_name MapBuilder
## Turns MapData boxes into flat-shaded meshes. All boxes of the same shade
## share one material; everything goes in one parent node.


static func build(map: MapData) -> Node3D:
	var root := Node3D.new()
	root.name = "Map_" + map.name
	var mats := {}
	for i in map.boxes.size():
		var box := map.boxes[i]
		var shade := map.shades[i]
		if not mats.has(shade):
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(shade, shade, shade * 1.02)
			mat.roughness = 1.0
			mat.metallic_specular = 0.0
			mats[shade] = mat
		var mesh := BoxMesh.new()
		mesh.size = box.size
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mats[shade]
		mi.position = box.get_center()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	return root


static func make_environment() -> Node3D:
	var root := Node3D.new()
	root.name = "Lighting"

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.82, 0.83, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = Color(0.82, 0.83, 0.85)
	env.fog_density = 0.006
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 1.2
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	# Two shadowless lights give each face a distinct flat shade.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.75
	sun.shadow_enabled = false
	root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -145, 0)
	fill.light_energy = 0.25
	fill.shadow_enabled = false
	root.add_child(fill)
	return root
