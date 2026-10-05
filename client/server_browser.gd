class_name ServerBrowser
extends RefCounted
## Fetches the master list over HTTP, discovers LAN servers by UDP broadcast,
## and pings each server's query port for live players + RTT.

signal updated

class Entry:
	var host := ""
	var ip := ""
	var port := Proto.DEFAULT_PORT
	var name := ""
	var mode := ""
	var players := 0
	var max_players := 0
	var version := 0
	var ping_ms := -1
	var lan := false
	var nonce := 0
	var sent_ms := 0

var entries: Array[Entry] = []
var status := ""
var _udp := PacketPeerUDP.new()
var _http: HTTPRequest
var _owner: Node


func _init(owner: Node) -> void:
	_owner = owner
	_http = HTTPRequest.new()
	_http.timeout = 5.0
	owner.add_child(_http)
	_http.request_completed.connect(_on_list)
	_udp.set_broadcast_enabled(true)
	_udp.bind(0)


func refresh(master_url: String) -> void:
	entries.clear()
	status = "searching LAN..."
	_broadcast_lan()
	_owner.get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if entries.is_empty() and status == "searching LAN...":
			status = "no servers found (set a master server URL in Settings)"
			updated.emit())
	if master_url != "":
		status = "fetching server list..."
		if _http.request(master_url.trim_suffix("/") + "/servers") != OK:
			status = "bad master URL"
	updated.emit()


func _broadcast_lan() -> void:
	_udp.set_dest_address("255.255.255.255", Proto.DEFAULT_PORT + Proto.QUERY_PORT_OFFSET)
	_udp.put_packet(QueryResponder.make_request(0))


func _on_list(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		status = "master unreachable (%d/%d)" % [result, code]
		updated.emit()
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY or not data.has("servers"):
		status = "bad master response"
		updated.emit()
		return
	for s: Dictionary in data.servers:
		var e := Entry.new()
		e.host = str(s.get("host", ""))
		e.port = int(s.get("port", Proto.DEFAULT_PORT))
		e.name = str(s.get("name", "?"))
		e.mode = str(s.get("mode", ""))
		e.players = int(s.get("players", 0))
		e.max_players = int(s.get("max", 0))
		e.version = int(s.get("version", 0))
		e.ip = e.host if e.host.is_valid_ip_address() else IP.resolve_hostname(e.host, IP.TYPE_IPV4)
		if e.ip == "":
			continue
		_ping(e)
		entries.append(e)
	status = "%d servers" % entries.size()
	updated.emit()


func _ping(e: Entry) -> void:
	e.nonce = randi() & 0x7FFFFFFF | 1
	e.sent_ms = Time.get_ticks_msec()
	_udp.set_dest_address(e.ip, e.port + Proto.QUERY_PORT_OFFSET)
	_udp.put_packet(QueryResponder.make_request(e.nonce))


## Call every frame while the browser is open.
func poll() -> void:
	var changed := false
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var src_port := _udp.get_packet_port()
		var r := QueryResponder.parse_reply(pkt)
		if r.is_empty():
			continue
		var game_port := src_port - Proto.QUERY_PORT_OFFSET
		var e: Entry = null
		for x in entries:
			if x.nonce == r.nonce and r.nonce != 0:
				e = x
				break
			if r.nonce == 0 and x.ip == ip and x.port == game_port:
				e = x
				break
		if e == null:
			if r.nonce != 0:
				continue
			e = Entry.new()  # LAN broadcast reply
			e.ip = ip
			e.host = ip
			e.port = game_port
			e.lan = true
			e.sent_ms = 0
			entries.append(e)
		if e.sent_ms > 0:
			e.ping_ms = Time.get_ticks_msec() - e.sent_ms
		e.name = r.name
		e.players = r.players
		e.max_players = r.max
		e.version = r.version
		e.mode = MatchRules.mode_name(r.mode)
		changed = true
	if changed:
		updated.emit()


func close() -> void:
	_udp.close()
	if is_instance_valid(_http):
		_http.queue_free()
