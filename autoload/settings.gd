extends Node
## Player-facing settings (persisted to user://settings.cfg) + input map.
## Input actions are registered in code so project.godot stays readable.

const PATH := "user://settings.cfg"
const DEFAULT_MASTER := ""

var player_name := ""
var mouse_sensitivity := 0.0022  # radians per pixel
var fov := 100.0
var fps_cap := 0  # 0 = unlimited
var vsync := false
var master_url := DEFAULT_MASTER
var last_address := str(ProjectSettings.get_setting("slabshot/default_server", "127.0.0.1"))


func _ready() -> void:
	_register_inputs()
	load_settings()
	apply_video()


func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		player_name = "slab%d" % (randi() % 100)
		return
	player_name = cf.get_value("player", "name", "slab")
	mouse_sensitivity = cf.get_value("input", "sensitivity", mouse_sensitivity)
	fov = cf.get_value("video", "fov", fov)
	fps_cap = cf.get_value("video", "fps_cap", fps_cap)
	vsync = cf.get_value("video", "vsync", vsync)
	master_url = cf.get_value("net", "master_url", master_url)
	last_address = cf.get_value("net", "last_address", last_address)
	if last_address == "127.0.0.1":
		last_address = str(ProjectSettings.get_setting("slabshot/default_server", last_address))


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.set_value("input", "sensitivity", mouse_sensitivity)
	cf.set_value("video", "fov", fov)
	cf.set_value("video", "fps_cap", fps_cap)
	cf.set_value("video", "vsync", vsync)
	cf.set_value("net", "master_url", master_url)
	cf.set_value("net", "last_address", last_address)
	cf.save(PATH)


func apply_video() -> void:
	Engine.max_fps = fps_cap
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)


func _register_inputs() -> void:
	_key("move_forward", KEY_W)
	_key("move_back", KEY_S)
	_key("move_left", KEY_A)
	_key("move_right", KEY_D)
	_key("jump", KEY_SPACE)
	_key("toggle_netgraph", KEY_F3)
	_key("scoreboard", KEY_TAB)
	_key("blade", KEY_SHIFT)
	_key("weapon_toggle", KEY_Q)
	_key("weapon_1", KEY_1)
	_key("weapon_2", KEY_2)
	_mouse("fire", MOUSE_BUTTON_LEFT)
	_mouse("weapon_toggle", MOUSE_BUTTON_WHEEL_UP)
	_mouse("weapon_toggle", MOUSE_BUTTON_WHEEL_DOWN)


func _key(action: StringName, key: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)


func _mouse(action: StringName, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)
