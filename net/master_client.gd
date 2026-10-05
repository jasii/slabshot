class_name MasterClient
extends Node
## Registers this server with the master list (heartbeat every 10s) and,
## as a static helper, fetches the list for the server browser.

const HEARTBEAT_SECS := 10.0

var server: GameServer
var url := ""  # e.g. http://master.example.com:27580
var key := ""  # optional shared secret (MASTER_KEY on the master)
var public_host := ""  # optional hostname to advertise instead of source IP

var _http: HTTPRequest
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 5.0
	add_child(_http)
	_http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		_busy = false
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("master heartbeat failed (result %d, http %d)" % [result, code]))
	_loop()


func _loop() -> void:
	while is_inside_tree():
		_heartbeat()
		await get_tree().create_timer(HEARTBEAT_SECS).timeout


func _heartbeat() -> void:
	if _busy or url == "":
		return
	var body := {
		"name": server.server_name,
		"port": server.port,
		"mode": MatchRules.mode_name(server.rules.mode),
		"map": "Arena01",
		"players": server.human_count(),
		"max": server.max_players,
		"version": Proto.VERSION,
	}
	if public_host != "":
		body["host"] = public_host
	var headers := PackedStringArray(["Content-Type: application/json"])
	if key != "":
		headers.append("X-Master-Key: " + key)
	_busy = true
	if _http.request(url.trim_suffix("/") + "/heartbeat", headers, HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		_busy = false
