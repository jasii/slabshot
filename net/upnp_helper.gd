class_name UpnpHelper
extends Node
## Best-effort UPnP port forward for listen-server hosts behind a home
## router. Discovery blocks for ~2s, so it runs on a thread.

signal finished(ok: bool, external_ip: String)

var port := Proto.DEFAULT_PORT
var _upnp: UPNP
var _thread: Thread
var _mapped := false


func start(p_port: int) -> void:
	port = p_port
	_thread = Thread.new()
	_thread.start(_work)


func _work() -> void:
	var u := UPNP.new()
	var err := u.discover(2000, 2, "InternetGatewayDevice")
	if err != UPNP.UPNP_RESULT_SUCCESS or u.get_gateway() == null or not u.get_gateway().is_valid_gateway():
		_done.call_deferred(false, "", null)
		return
	var ok := u.add_port_mapping(port, port, "Slabshot", "UDP", 0) == UPNP.UPNP_RESULT_SUCCESS
	u.add_port_mapping(port + Proto.QUERY_PORT_OFFSET, port + Proto.QUERY_PORT_OFFSET, "Slabshot query", "UDP", 0)
	_done.call_deferred(ok, u.query_external_address(), u)


func _done(ok: bool, ip: String, u: UPNP) -> void:
	_thread.wait_to_finish()
	_upnp = u
	_mapped = ok
	print("[upnp] %s %s" % ["mapped UDP %d, public address" % port if ok else "no UPnP gateway / mapping failed", ip])
	finished.emit(ok, ip)


func _exit_tree() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	if _mapped and _upnp:
		_upnp.delete_port_mapping(port, "UDP")
		_upnp.delete_port_mapping(port + Proto.QUERY_PORT_OFFSET, "UDP")
