class_name MainMenu
extends Control
## Main menu: Play (server browser + direct connect), Host, Settings.

signal host_requested(opts: Dictionary)
signal join_requested(address: String, port: int)

var message := ""

var _name: LineEdit
var _addr: LineEdit
var _list: ItemList
var _status: Label
var _browser: ServerBrowser
var _rows: Array = []  # browser entries in list order

var _host_mode: OptionButton
var _host_rotate: CheckBox
var _host_dummies: SpinBox
var _host_dummy_pu: CheckBox
var _host_port: SpinBox
var _host_max: SpinBox
var _host_upnp: CheckBox
var _host_master: CheckBox

var _sens: SpinBox
var _fov: SpinBox
var _fps: SpinBox
var _vsync: CheckBox
var _master: LineEdit
var _lat: SpinBox
var _jit: SpinBox
var _loss: SpinBox


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.86, 0.87, 0.89)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_CENTER)
	root.offset_left = -320
	root.offset_right = 320
	root.offset_top = -330
	root.offset_bottom = 330
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := Label.new()
	title.text = "SLABSHOT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.12, 0.12, 0.14))
	root.add_child(title)

	if message != "":
		var m := Label.new()
		m.text = message
		m.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		m.add_theme_color_override("font_color", Color(0.75, 0.15, 0.1))
		root.add_child(m)

	_name = _line(root, "Name", Settings.player_name)
	(_name.get_parent().get_child(0) as Label).add_theme_color_override("font_color", Color(0.12, 0.12, 0.14))
	_name.text_changed.connect(func(t: String) -> void: Settings.player_name = t.strip_edges())

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)
	_build_play(tabs)
	_build_host(tabs)
	_build_settings(tabs)

	var quit := Button.new()
	quit.text = "Quit"
	quit.pressed.connect(func() -> void:
		_save()
		get_tree().quit())
	root.add_child(quit)

	_browser = ServerBrowser.new(self)
	_browser.updated.connect(_refresh_list)
	_browser.refresh(Settings.master_url)


func _process(_delta: float) -> void:
	if _browser:
		_browser.poll()


func _exit_tree() -> void:
	if _browser:
		_browser.close()


# ---------------------------------------------------------------- tabs

func _build_play(tabs: TabContainer) -> void:
	var v := _tab(tabs, "Play")
	_status = Label.new()
	v.add_child(_status)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size.y = 220
	_list.item_activated.connect(func(i: int) -> void: _join_entry(i))
	v.add_child(_list)
	var row := HBoxContainer.new()
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(func() -> void: _browser.refresh(Settings.master_url))
	row.add_child(refresh)
	var join_sel := Button.new()
	join_sel.text = "Join selected"
	join_sel.pressed.connect(func() -> void:
		var sel := _list.get_selected_items()
		if sel.size() > 0:
			_join_entry(sel[0]))
	row.add_child(join_sel)
	v.add_child(row)

	v.add_child(HSeparator.new())
	_addr = _line(v, "Address", Settings.last_address)
	var join := Button.new()
	join.text = "Join address"
	join.pressed.connect(func() -> void:
		var a := _addr.text.strip_edges()
		var port := Proto.DEFAULT_PORT
		if ":" in a:
			port = int(a.get_slice(":", 1))
			a = a.get_slice(":", 0)
		Settings.last_address = _addr.text.strip_edges()
		_go_join(a, port))
	v.add_child(join)


func _build_host(tabs: TabContainer) -> void:
	var v := _tab(tabs, "Host")
	_host_mode = OptionButton.new()
	_host_mode.add_item("Free For All", MatchRules.Mode.FFA)
	_host_mode.add_item("Team Slayer", MatchRules.Mode.TDM)
	_row(v, "Mode", _host_mode)
	_host_rotate = _check(v, "Alternate modes each match", false)
	_host_dummies = _spin(v, "Practice dummies", 4, 0, 32)
	_host_dummy_pu = _check(v, "Dummies use powerups", true)
	_host_max = _spin(v, "Max players", 16, 2, Proto.MAX_PLAYERS)
	_host_port = _spin(v, "Port", Proto.DEFAULT_PORT, 1024, 65534)
	_host_upnp = _check(v, "Open port with UPnP (router)", true)
	_host_master = _check(v, "List on master server", false)
	var host := Button.new()
	host.text = "Host game"
	host.pressed.connect(func() -> void:
		_save()
		var opts := {
			"mode": "tdm" if _host_mode.get_selected_id() == MatchRules.Mode.TDM else "ffa",
			"dummies": str(int(_host_dummies.value)),
			"max": str(int(_host_max.value)),
			"port": str(int(_host_port.value)),
			"player": Settings.player_name,
		}
		if _host_dummy_pu.button_pressed:
			opts["dummy-powerups"] = ""
		if _host_rotate.button_pressed:
			opts["rotate"] = ""
		if _host_upnp.button_pressed:
			opts["upnp"] = ""
		if _host_master.button_pressed and Settings.master_url != "":
			opts["master"] = Settings.master_url
		host_requested.emit(opts))
	v.add_child(host)


func _build_settings(tabs: TabContainer) -> void:
	var v := _tab(tabs, "Settings")
	_sens = _spin(v, "Sensitivity (x1000)", Settings.mouse_sensitivity * 1000.0, 0.2, 10.0, 0.05)
	_fov = _spin(v, "FOV", Settings.fov, 70, 130)
	_fps = _spin(v, "FPS cap (0 = off)", Settings.fps_cap, 0, 1000)
	_vsync = _check(v, "VSync", Settings.vsync)
	_master = _line(v, "Master server URL", Settings.master_url)
	v.add_child(HSeparator.new())
	var ns := Label.new()
	ns.text = "Network simulation (testing, joined games only)"
	v.add_child(ns)
	_lat = _spin(v, "Added RTT ms", 0, 0, 500)
	_jit = _spin(v, "Jitter ms", 0, 0, 200)
	_loss = _spin(v, "Loss %", 0, 0, 50)
	var apply := Button.new()
	apply.text = "Apply"
	apply.pressed.connect(_save)
	v.add_child(apply)


func _save() -> void:
	Settings.player_name = _name.text.strip_edges() if _name.text.strip_edges() != "" else "slab"
	Settings.mouse_sensitivity = _sens.value / 1000.0
	Settings.fov = _fov.value
	Settings.fps_cap = int(_fps.value)
	Settings.vsync = _vsync.button_pressed
	Settings.master_url = _master.text.strip_edges()
	Settings.apply_video()
	Settings.save_settings()
	Net.net_sim.configure(_lat.value, _jit.value, _loss.value)


# ---------------------------------------------------------------- browser

func _refresh_list() -> void:
	_status.text = "%d servers" % _browser.entries.size() if _browser.entries.size() > 0 else _browser.status
	_list.clear()
	_rows = _browser.entries.duplicate()
	_rows.sort_custom(func(a: ServerBrowser.Entry, b: ServerBrowser.Entry) -> bool:
		var pa := a.ping_ms if a.ping_ms >= 0 else 9999
		var pb := b.ping_ms if b.ping_ms >= 0 else 9999
		return pa < pb)
	for e: ServerBrowser.Entry in _rows:
		var ping := "%d ms" % e.ping_ms if e.ping_ms >= 0 else "?"
		var tag := " [LAN]" if e.lan else ""
		var bad := "  (version %d)" % e.version if e.version != Proto.VERSION and e.version != 0 else ""
		_list.add_item("%s%s   %s   %d/%d   %s%s" % [e.name, tag, e.mode, e.players, e.max_players, ping, bad])


func _join_entry(i: int) -> void:
	if i < 0 or i >= _rows.size():
		return
	var e: ServerBrowser.Entry = _rows[i]
	_go_join(e.ip, e.port)


func _go_join(addr: String, port: int) -> void:
	_save()
	join_requested.emit(addr, port)


# ---------------------------------------------------------------- widgets

func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var m := MarginContainer.new()
	m.name = title
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 12)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	m.add_child(v)
	tabs.add_child(m)
	return v


func _row(parent: Control, label: String, ctl: Control) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 210
	row.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctl)
	parent.add_child(row)


func _line(parent: Control, label: String, value: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = value
	_row(parent, label, e)
	return e


func _spin(parent: Control, label: String, value: float, lo: float, hi: float, step := 1.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	_row(parent, label, s)
	return s


func _check(parent: Control, label: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = label
	c.button_pressed = on
	parent.add_child(c)
	return c
