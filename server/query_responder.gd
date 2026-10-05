class_name QueryResponder
extends Node
## Answers server-browser pings on UDP (game port + 1) with live info.
## Requests must be padded to REQUEST_SIZE so replies are never larger than
## requests (no reflection/amplification value).

const REQUEST_SIZE := 64
const MAGIC_REQ := 0x31514C53  # "SLQ1"
const MAGIC_RESP := 0x31524C53  # "SLR1"

var server: GameServer
var _udp := PacketPeerUDP.new()


func listen(port: int) -> void:
	var err := _udp.bind(port)
	if err != OK:
		push_warning("query port %d unavailable: %s" % [port, error_string(err)])


func _process(_delta: float) -> void:
	if not _udp.is_bound():
		return
	var budget := 64
	while _udp.get_available_packet_count() > 0 and budget > 0:
		budget -= 1
		var pkt := _udp.get_packet()
		if pkt.size() < REQUEST_SIZE:
			continue
		var b := Proto.reader(pkt)
		if b.get_u32() != MAGIC_REQ:
			continue
		var nonce := b.get_u32()
		var out := StreamPeerBuffer.new()
		out.big_endian = false
		out.put_u32(MAGIC_RESP)
		out.put_u32(nonce)
		out.put_u16(Proto.VERSION)
		out.put_u8(server.human_count())
		out.put_u8(server.max_players)
		out.put_u8(server.rules.mode)
		out.put_utf8_string(server.server_name.left(32))
		var data := out.data_array
		if data.size() > REQUEST_SIZE:
			data.resize(REQUEST_SIZE)
		_udp.set_dest_address(_udp.get_packet_ip(), _udp.get_packet_port())
		_udp.put_packet(data)


func _exit_tree() -> void:
	_udp.close()


## Client side: build a padded request.
static func make_request(nonce: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u32(MAGIC_REQ)
	b.put_u32(nonce)
	var data := b.data_array
	data.resize(REQUEST_SIZE)
	return data


## Client side: parse a reply, or {} if invalid.
static func parse_reply(data: PackedByteArray) -> Dictionary:
	if data.size() < 15:
		return {}
	var b := Proto.reader(data)
	if b.get_u32() != MAGIC_RESP:
		return {}
	var nonce := b.get_u32()
	var version := b.get_u16()
	var players := b.get_u8()
	var max_p := b.get_u8()
	var mode := b.get_u8()
	var sname := b.get_utf8_string() if b.get_available_bytes() >= 4 else ""
	return {"nonce": nonce, "version": version, "players": players, "max": max_p,
		"mode": mode, "name": sname}
