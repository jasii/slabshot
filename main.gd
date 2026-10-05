extends Node
## Bootstrap. Command-line (after `--`), each also readable from an env var
## (shown in brackets) so the Docker image is configured by environment:
##   --server                     dedicated, headless
##   --port=27500        [SLAB_PORT]
##   --max=64            [SLAB_MAX]
##   --name=..           [SLAB_NAME]
##   --mode=ffa|tdm      [SLAB_MODE]
##   --rotate            [SLAB_ROTATE=1]   alternate FFA/TDM each match
##   --score=N           [SLAB_SCORE]      score limit (default FFA 25, TDM 50)
##   --time=MIN          [SLAB_TIME]       time limit minutes (default FFA 10, TDM 12)
##   --dummies=N         [SLAB_DUMMIES]
##   --dummy-powerups              practice: dummies cycle through powerups
##   --master=URL        [SLAB_MASTER]     register with master server list
##   --master-key=KEY    [SLAB_MASTER_KEY]
##   --public-host=HOST  [SLAB_PUBLIC_HOST] advertise this host instead of source IP
##   --host                       listen server + play
##   --upnp                       (with --host) try UPnP port forward
##   --join=ADDR[:PORT]           client
##   --bot                        headless bot client (with --join)
##   --netsim=LAT_MS,JITTER_MS,LOSS_PCT
##   --player=NAME
##   --shot=PATH                  debug: screenshot after 3s and quit
## No args: main menu.

const ENV := {
	"port": "SLAB_PORT", "max": "SLAB_MAX", "name": "SLAB_NAME", "mode": "SLAB_MODE",
	"rotate": "SLAB_ROTATE", "dummies": "SLAB_DUMMIES", "master": "SLAB_MASTER",
	"master-key": "SLAB_MASTER_KEY", "public-host": "SLAB_PUBLIC_HOST",
	"score": "SLAB_SCORE", "time": "SLAB_TIME",
}

var server: GameServer
var client: GameClient
var menu: MainMenu
var upnp: UpnpHelper
var args := {}


func _ready() -> void:
	for k in ENV:
		var v := OS.get_environment(ENV[k])
		if v != "" and v != "0":
			args[k] = v
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if OS.has_feature("dedicated_server") or (DisplayServer.get_name() == "headless" and not args.has("bot") and not args.has("join")):
		args["server"] = ""

	if args.has("netsim"):
		var p: PackedStringArray = String(args.netsim).split(",")
		Net.net_sim.configure(p[0].to_float(), p[1].to_float() if p.size() > 1 else 0.0,
			p[2].to_float() if p.size() > 2 else 0.0)

	var port := int(args.get("port", Proto.DEFAULT_PORT))
	if args.has("server"):
		start_server(port, false)
	elif args.has("host"):
		start_server(port, true)
	elif args.has("join"):
		var addr: String = args.join
		if ":" in addr:
			port = int(addr.get_slice(":", 1))
			addr = addr.get_slice(":", 0)
		start_client(addr, port, args.has("bot"))
	else:
		if args.has("master"):
			Settings.master_url = args.master
		show_menu()

	if args.has("shot"):
		_debug_screenshot(args.shot)


func show_menu(message := "") -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu = MainMenu.new()
	menu.message = message
	menu.host_requested.connect(func(opts: Dictionary) -> void:
		for k in opts:
			args[k] = opts[k]
		_close_menu()
		start_server(int(opts.port), true))
	menu.join_requested.connect(func(addr: String, port: int) -> void:
		args["player"] = Settings.player_name
		_close_menu()
		start_client(addr, port, false))
	add_child(menu)


func _close_menu() -> void:
	if menu:
		menu.queue_free()
		menu = null


func start_server(port: int, listen: bool) -> void:
	var max_players := clampi(int(args.get("max", Proto.MAX_PLAYERS)), 1, Proto.MAX_PLAYERS)
	var err := Net.host(port, max_players, listen)
	if err != OK:
		var msg := "Could not host on UDP %d (%s)" % [port, error_string(err)]
		push_error(msg)
		if listen:
			show_menu(msg)
		else:
			get_tree().quit(1)
		return
	server = GameServer.new()
	server.port = port
	server.server_name = args.get("name", "%s's game" % Settings.player_name if listen else "Slabshot server")
	server.dummy_count = int(args.get("dummies", 0))
	server.dummy_powerups = args.has("dummy-powerups")
	server.max_players = max_players
	server.mode = MatchRules.parse_mode(args.get("mode", "ffa"))
	server.rotate_modes = args.has("rotate")
	server.score_limit = int(args.get("score", 0))
	server.time_limit_min = float(args.get("time", 0))
	server.master_url = args.get("master", "")
	server.master_key = args.get("master-key", "")
	server.public_host = args.get("public-host", "")
	add_child(server)
	print("[server] '%s' listening on UDP %d (%s, %s)" % [server.server_name, port,
		"listen" if listen else "dedicated", MatchRules.mode_name(server.mode)])
	if listen:
		if args.has("upnp"):
			upnp = UpnpHelper.new()
			add_child(upnp)
			upnp.start(port)
		_spawn_client(false)
	else:
		Engine.max_fps = 120  # don't spin a core in headless idle loop
		_server_stats_loop()


func start_client(addr: String, port: int, bot: bool) -> void:
	var err := Net.join(addr, port)
	if err != OK:
		push_error("Could not connect to %s:%d" % [addr, port])
		if bot:
			get_tree().quit(1)
		else:
			show_menu("Could not connect to %s:%d" % [addr, port])
		return
	_spawn_client(bot)


func _spawn_client(bot: bool) -> void:
	client = GameClient.new()
	client.headless = bot
	client.player_name = args.get("player", "bot%d" % (randi() % 1000) if bot else Settings.player_name)
	if bot:
		client.input_source = BotInput.new(client)
	else:
		var li := LocalInput.new()
		client.add_child(li)
		client.input_source = li
	client.left_game.connect(_on_left_game)
	add_child(client)


func _on_left_game(reason: String) -> void:
	print("[client] left game: ", reason)
	if client and client.headless:
		get_tree().quit()
		return
	if client:
		client.queue_free()
		client = null
	if server:
		server.queue_free()
		server = null
	if upnp:
		upnp.queue_free()
		upnp = null
	Net.shutdown()
	show_menu("" if reason == "quit" else reason)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_F10 and client:
		_on_left_game("quit")


func _server_stats_loop() -> void:
	while true:
		await get_tree().create_timer(10.0).timeout
		if server:
			print("[server] tick %d  players %d  tick %.2f ms (sim %.2f snap/round %.2f bullets %.2f/tick, %d live)  snapshot out %d B/round" % [
				server.world.tick, server.conns.size(), server.tick_ms, server.prof_sim,
				server.prof_snap, server.prof_fire / 600.0, server.bullets.bullets.size(), server.snap_bytes])
			server.prof_fire = 0.0


func _debug_screenshot(path: String) -> void:
	await get_tree().create_timer(float(args.get("shot-delay", 3.0))).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
