class_name BotInput
extends RefCounted
## Fake player input for load tests / filling servers. Wanders, strafes,
## turns toward the nearest remote player with some error, fires in bursts.

var client: GameClient
var yaw := 0.0
var pitch := 0.0
var alt := true  # always use a special weapon when holding one
var _rng := RandomNumberGenerator.new()
var _move := Vector2.ZERO
var _move_t := 0
var _fire_t := 0


func _init(c: GameClient) -> void:
	client = c
	_rng.randomize()
	yaw = _rng.randf() * TAU


func sample(tick: int) -> InputCmd:
	var cmd := InputCmd.new()
	cmd.tick = tick
	if tick >= _move_t:
		_move_t = tick + _rng.randi_range(20, 90)
		_move = Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-0.3, 1)).limit_length(1.0)
	var target := _nearest()
	if target != Vector3.INF:
		var to := target + Vector3(0, 1.2, 0) - client.pred.eye()
		var want_yaw := atan2(-to.x, -to.z) + _rng.randf_range(-0.08, 0.08)
		yaw = lerp_angle(yaw, want_yaw, 0.15)
		pitch = lerpf(pitch, atan2(to.y, Vector2(to.x, to.z).length()), 0.15)
		if tick >= _fire_t and _rng.randf() < 0.05:
			_fire_t = tick + _rng.randi_range(20, 60)
	else:
		yaw += 0.02
	cmd.set_angles(yaw, pitch)
	cmd.move_x = int(_move.x * 127)
	cmd.move_z = int(_move.y * 127)
	if alt:
		cmd.buttons |= InputCmd.BTN_ALT
	if tick < _fire_t:
		cmd.buttons |= InputCmd.BTN_FIRE
	if _rng.randf() < 0.01:
		cmd.buttons |= InputCmd.BTN_JUMP
	# blade up in bursts, roughly a quarter of the time
	if (tick / 45 + get_instance_id()) % 4 == 0:
		cmd.buttons |= InputCmd.BTN_BLADE
	return cmd


func _nearest() -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for pose: Array in client.remote_poses(client._interp_tick):
		var d := (pose[1] as Vector3).distance_squared_to(client.pred.pos)
		if d < best_d:
			best_d = d
			best = pose[1]
	return best
