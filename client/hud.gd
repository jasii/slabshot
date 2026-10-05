class_name Hud
extends Control
## Crosshair, hit marker, HP, weapon, powerup, match banner, kill feed,
## scoreboard (Tab), end-of-match screen, net graph (F3).

const INK := Color(0.1, 0.1, 0.12)
const FEED_SECS := 5.0

var client: GameClient
var show_info := true
var extra_info := ""

var _hit_t := 0.0
var _hit_crit := false
var _hit_kill := false
var _feed: Array[String] = []
var _feed_t: Array[float] = []
var _info: Label
var _hp: Label
var _weapon: Label
var _powerup: Label
var _banner: Label
var _feed_label: Label
var _center: Label
var _board: PanelContainer
var _board_text: Label
var _board_t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info = _label(14, Control.PRESET_TOP_LEFT, Vector2(12, 8), Vector2(600, 120))
	_hp = _label(34, Control.PRESET_BOTTOM_LEFT, Vector2(24, -70), Vector2(400, 50))
	_weapon = _label(22, Control.PRESET_BOTTOM_RIGHT, Vector2(-424, -80), Vector2(400, 60))
	_weapon.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_powerup = _label(20, Control.PRESET_CENTER_BOTTOM, Vector2(-250, -90), Vector2(500, 60))
	_powerup.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner = _label(20, Control.PRESET_CENTER_TOP, Vector2(-300, 10), Vector2(600, 60))
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feed_label = _label(16, Control.PRESET_TOP_RIGHT, Vector2(-470, 10), Vector2(450, 200))
	_feed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_center = _label(30, Control.PRESET_CENTER, Vector2(-350, 50), Vector2(700, 120))
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_board = PanelContainer.new()
	_place(_board, Control.PRESET_CENTER, Vector2(-330, -260), Vector2(660, 0))
	_board.grow_vertical = Control.GROW_DIRECTION_END
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.95, 0.95, 0.96, 0.9)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_board.add_theme_stylebox_override("panel", sb)
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_text = Label.new()
	_board_text.add_theme_font_override("font", _mono())
	_board_text.add_theme_font_size_override("font_size", 16)
	_board_text.add_theme_color_override("font_color", INK)
	_board.add_child(_board_text)
	_board.visible = false
	add_child(_board)


## Anchor-relative placement (works before the parent has a size).
func _place(c: Control, preset: int, pos: Vector2, sz: Vector2) -> void:
	c.set_anchors_preset(preset)
	c.offset_left = pos.x
	c.offset_top = pos.y
	c.offset_right = pos.x + sz.x
	c.offset_bottom = pos.y + sz.y


func _mono() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Consolas", "DejaVu Sans Mono", "monospace"])
	return f


func _label(font_size: int, preset: int, pos: Vector2, sz: Vector2) -> Label:
	var l := Label.new()
	_place(l, preset, pos, sz)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", INK)
	l.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.85))
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func hit_marker(crit: bool, kill: bool) -> void:
	_hit_t = 0.22 if kill else 0.12
	_hit_crit = crit
	_hit_kill = kill


func kill_feed(killer: int, victim: int, weapon: int) -> void:
	var wname: String = Weapons.get_data(weapon).name if Weapons.DATA.has(weapon) else ""
	var text := "%s  [%s]  %s" % [client.player_name_of(killer), wname, client.player_name_of(victim)] \
		if killer != 255 else "%s died" % client.player_name_of(victim)
	_feed.push_front(text)
	_feed_t.push_front(FEED_SECS)
	if _feed.size() > 6:
		_feed.pop_back()
		_feed_t.pop_back()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_netgraph"):
		show_info = not show_info
	_hit_t = maxf(_hit_t - delta, 0.0)
	for i in range(_feed_t.size() - 1, -1, -1):
		_feed_t[i] -= delta
		if _feed_t[i] <= 0.0:
			_feed.remove_at(i)
			_feed_t.remove_at(i)
	_feed_label.text = "\n".join(_feed)
	_info.visible = show_info
	if show_info:
		_info.text = "%d fps\n%s" % [Engine.get_frames_per_second(), extra_info]
	if client and client.joined:
		_update_player()
		_update_match()
		_board.visible = Input.is_action_pressed("scoreboard") \
			or client.match_info.state == MatchRules.State.ENDED
		_board_t -= delta
		if _board.visible and _board_t <= 0.0:
			_board_t = 0.25
			_board_text.text = _scoreboard_text()
	queue_redraw()


func _update_player() -> void:
	var rec := client.my_record()
	var alive := client.is_alive()
	if not alive or rec.is_empty():
		_hp.text = ""
	elif Powerups.of(rec[Proto.E_FLAGS]) == Powerups.SPLIT:
		var f: int = rec[Proto.E_FLAGS]
		var a := str(rec[Proto.E_HP]) if f & Powerups.F_HALF_A else "x"
		var b := str(rec[Proto.E_HP2]) if f & Powerups.F_HALF_B else "x"
		_hp.text = "%s | %s" % [a, b]
	else:
		_hp.text = str(rec[Proto.E_HP])

	var w := client.active_weapon()
	var wd := Weapons.get_data(w)
	var txt: String = wd.name
	if w != Weapons.PULSE:
		txt += "  %d" % client.my_ammo
	if client.my_special != Weapons.NONE:
		var other: String = Weapons.get_data(client.my_special).name if w == Weapons.PULSE else Weapons.get_data(Weapons.PULSE).name
		txt += "\n[Q] %s" % other
	_weapon.text = txt
	_weapon.add_theme_color_override("font_color", wd.color.darkened(0.35))

	if client.my_powerup != Powerups.NONE:
		var pd: Dictionary = Powerups.DATA[client.my_powerup]
		var secs := maxf(0.0, (client.my_powerup_end - client._newest_snap) / 60.0)
		_powerup.text = "%s  %.0fs\n%s" % [pd.name, secs, pd.desc]
		_powerup.add_theme_color_override("font_color", (pd.color as Color).darkened(0.4))
	else:
		_powerup.text = ""

	if client.match_info.state == MatchRules.State.ENDED:
		var mi := client.match_info
		_center.text = "%s\nnext match in %d" % [MatchRules.winner_text(mi.winner_name), maxi(0, ceili(client.ticks_left() / 60.0))]
	elif not alive:
		_center.text = "respawning..."
	else:
		_center.text = ""


func _update_match() -> void:
	var mi := client.match_info
	var secs := maxi(0, ceili(client.ticks_left() / 60.0)) if mi.state == MatchRules.State.PLAYING else 0
	var clock := "%d:%02d" % [secs / 60, secs % 60]
	if mi.mode == MatchRules.Mode.TDM:
		_banner.text = "TEAM SLAYER  %s\nOrange %d  -  %d Cyan   (to %d)" % [clock, mi.t1, mi.t2, mi.limit]
	else:
		var mine: Array = client.scores.get(client.my_slot, [0, 0])
		var lead := 0
		for s: Array in client.scores.values():
			lead = maxi(lead, s[0])
		_banner.text = "FREE FOR ALL  %s\nyou %d   lead %d   (to %d)" % [clock, mine[0], lead, mi.limit]


func _scoreboard_text() -> String:
	var mi := client.match_info
	var rows := []
	for slot in client.infos:
		var s: Array = client.scores.get(slot, [0, 0])
		rows.append([slot, client.infos[slot].name, client.infos[slot].team, s[0], s[1]])
	rows.sort_custom(func(a: Array, b: Array) -> bool:
		return a[3] > b[3] if a[3] != b[3] else a[4] < b[4])
	var lines := ["%s   %s" % [client.server_name, MatchRules.mode_name(mi.mode)], ""]
	var groups := [[1, "ORANGE  %d" % mi.t1], [2, "CYAN  %d" % mi.t2]] \
		if mi.mode == MatchRules.Mode.TDM else [[-1, ""]]
	for g: Array in groups:
		if g[1] != "":
			lines.append(g[1])
		lines.append("  %-22s %6s %6s" % ["name", "kills", "deaths"])
		for r: Array in rows:
			if g[0] != -1 and r[2] != g[0]:
				continue
			var me := ">" if r[0] == client.my_slot else " "
			lines.append("%s %-22s %6d %6d" % [me, String(r[1]).left(22), r[3], r[4]])
		lines.append("")
	return "\n".join(lines)


func _draw() -> void:
	var c := size * 0.5
	var col := Color(0.05, 0.05, 0.05)
	draw_circle(c, 2.0, col)
	for d: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(c + d * 6.0, c + d * 12.0, col, 2.0)
	if client and client.pred.blade_t > 0:
		# blade stance indicator: crosshair gains vertical bars
		var a := client.pred.blade()
		for sx: float in [-1.0, 1.0]:
			draw_line(c + Vector2(sx * 18.0, -10.0), c + Vector2(sx * 18.0, 10.0), Color(col, a), 2.0)
	if client and client.active_weapon() == Weapons.RAIL:
		var f := client.rail_charge_frac()
		draw_arc(c, 20.0, -PI * 0.5, -PI * 0.5 + TAU * f, 48, Weapons.get_data(Weapons.RAIL).color, 3.0)
	if _hit_t > 0.0:
		var hc := Color(1, 0.15, 0.1) if _hit_kill else (Color(1, 0.75, 0) if _hit_crit else Color(0, 0, 0))
		var s := 14.0 if _hit_kill else 10.0
		for d: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			draw_line(c + d * 5.0, c + d * s, hc, 2.5)
