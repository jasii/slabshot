extends Node
## Transport layer. Wraps ENet via SceneMultiplayer.send_bytes (no RPCs, no
## synchronizers) plus an in-process loopback so a listen-server host's own
## client uses the exact same byte protocol with zero latency.
## Optional NetSim injects latency/jitter/loss on the client side.

signal client_packet(peer_id: int, data: PackedByteArray)  # server receives
signal server_packet(data: PackedByteArray)  # client receives
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connected
signal connect_failed
signal disconnected

const LOCAL_PEER := 1

var is_server := false
var is_client := false
var local_client := false  # listen-server host plays in-process
var net_sim := NetSim.new()

var bytes_in := 0
var bytes_out := 0
var rate_in := 0.0  # bytes/s, client side
var rate_out := 0.0
var _rate_t := 0.0

var _to_server: Array[PackedByteArray] = []
var _to_client: Array[PackedByteArray] = []


func _ready() -> void:
	process_priority = -100  # deliver packets before game nodes tick
	multiplayer.peer_packet.connect(_on_peer_packet)
	multiplayer.peer_connected.connect(func(id: int) -> void: if is_server: peer_joined.emit(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: if is_server: peer_left.emit(id))
	multiplayer.connected_to_server.connect(func() -> void: connected.emit())
	multiplayer.connection_failed.connect(func() -> void: connect_failed.emit())
	multiplayer.server_disconnected.connect(func() -> void: disconnected.emit())


func host(port: int, max_players: int, with_local_client: bool) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_players)
	if err != OK:
		return err
	# No ENet compression: snapshots are small and already quantized/delta'd;
	# range coder cost ~3x more server CPU than it saved in bytes (63-bot test).
	multiplayer.multiplayer_peer = peer
	multiplayer.server_relay = false
	is_server = true
	local_client = with_local_client
	is_client = with_local_client
	return OK


func join(address: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_client = true
	return OK


func shutdown() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	is_client = false
	local_client = false
	_to_server.clear()
	_to_client.clear()


func send_to_server(data: PackedByteArray, reliable: bool) -> void:
	bytes_out += data.size()
	if local_client:
		_to_server.append(data)
	elif net_sim.enabled:
		net_sim.queue_out(data, reliable)
	else:
		_raw_send(1, data, reliable)


func send_to_peer(peer_id: int, data: PackedByteArray, reliable: bool) -> void:
	if local_client and peer_id == LOCAL_PEER:
		bytes_in += data.size()
		_to_client.append(data)
	else:
		_raw_send(peer_id, data, reliable)


func kick(peer_id: int) -> void:
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer and peer_id != LOCAL_PEER:
		peer.disconnect_peer(peer_id)


func _raw_send(peer_id: int, data: PackedByteArray, reliable: bool) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	var mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	multiplayer.send_bytes(data, peer_id, mode, 0)


func _on_peer_packet(id: int, data: PackedByteArray) -> void:
	if is_server:
		client_packet.emit(id, data)
	else:
		bytes_in += data.size()
		if net_sim.enabled:
			net_sim.queue_in(data)
		else:
			server_packet.emit(data)


func _process(delta: float) -> void:
	# Loopback delivery (listen host)
	if not _to_server.is_empty():
		var q := _to_server
		_to_server = []
		for d in q:
			client_packet.emit(LOCAL_PEER, d)
	if not _to_client.is_empty():
		var q := _to_client
		_to_client = []
		for d in q:
			server_packet.emit(d)
	# Simulated network
	if net_sim.enabled and is_client and not local_client:
		for d in net_sim.due_out():
			_raw_send(1, d[0], d[1])
		for d in net_sim.due_in():
			server_packet.emit(d)
	_rate_t += delta
	if _rate_t >= 1.0:
		rate_in = bytes_in / _rate_t
		rate_out = bytes_out / _rate_t
		bytes_in = 0
		bytes_out = 0
		_rate_t = 0.0
