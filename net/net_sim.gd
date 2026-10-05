class_name NetSim
extends RefCounted
## Client-side bad-network simulator. Latency is split half each way, so
## latency_ms is added RTT. Reliable packets are never dropped and never
## reordered (ENet guarantees that for real traffic too).

var enabled := false
var latency_ms := 0.0
var jitter_ms := 0.0
var loss := 0.0  # 0..1, unreliable only

var _out: Array = []  # [release_ms, data, reliable]
var _in: Array = []  # [release_ms, data]
var _last_reliable_out := 0.0


func configure(lat: float, jit: float, loss_pct: float) -> void:
	latency_ms = lat
	jitter_ms = jit
	loss = loss_pct / 100.0
	enabled = lat > 0.0 or jit > 0.0 or loss_pct > 0.0


func _delay() -> float:
	return Time.get_ticks_msec() + latency_ms * 0.5 + randf() * jitter_ms


func queue_out(data: PackedByteArray, reliable: bool) -> void:
	if not reliable and randf() < loss:
		return
	var t := _delay()
	if reliable:
		t = maxf(t, _last_reliable_out)
		_last_reliable_out = t
	_out.append([t, data, reliable])


func queue_in(data: PackedByteArray) -> void:
	# Can't tell reliability on receive; only drop snapshots (op 65).
	if data.size() > 0 and (data[0] == Proto.S_SNAPSHOT or data[0] == Proto.S_BULLETS) and randf() < loss:
		return
	var t := _delay()
	if data.size() > 0 and (data[0] == Proto.S_EVENT or data[0] == Proto.S_WELCOME):
		# keep reliable ordering
		for item in _in:
			t = maxf(t, item[0])
	_in.append([t, data])


func due_out() -> Array:
	var now := Time.get_ticks_msec()
	var out := []
	var keep := []
	for item in _out:
		if item[0] <= now:
			out.append([item[1], item[2]])
		else:
			keep.append(item)
	_out = keep
	return out


func due_in() -> Array[PackedByteArray]:
	var now := Time.get_ticks_msec()
	var out: Array[PackedByteArray] = []
	var keep := []
	for item in _in:
		if item[0] <= now:
			out.append(item[1])
		else:
			keep.append(item)
	_in = keep
	return out
