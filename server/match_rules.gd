class_name MatchRules
extends RefCounted
## Game mode + match flow. FFA: first to N kills. Team Slayer: two teams,
## first team to N. Match ends on score or time, shows results, restarts.

enum Mode { FFA, TDM }
enum State { PLAYING, ENDED }

const END_SCREEN_TICKS := 10 * 60
const TEAM_COLORS := [Color.WHITE, Color(1.0, 0.5, 0.1), Color(0.1, 0.75, 1.0)]

var mode := Mode.FFA
var state := State.PLAYING
var score_limit := 25
var time_limit_ticks := 10 * 60 * 60
var end_tick := 0  # PLAYING: match ends at; ENDED: next match starts at
var team_scores := [0, 0, 0]
var winner := -1  # slot (FFA) or team (TDM)
var winner_name := ""


static func mode_name(m: int) -> String:
	return "Team Slayer" if m == Mode.TDM else "Free For All"


static func parse_mode(s: String) -> int:
	return Mode.TDM if s.to_lower() in ["tdm", "team", "slayer", "team_slayer"] else Mode.FFA


func configure(m: int) -> void:
	mode = m
	score_limit = 50 if m == Mode.TDM else 25
	time_limit_ticks = (12 if m == Mode.TDM else 10) * 60 * 60


func start(now: int) -> void:
	state = State.PLAYING
	end_tick = now + time_limit_ticks
	team_scores = [0, 0, 0]
	winner = -1
	winner_name = ""


func is_team() -> bool:
	return mode == Mode.TDM


## Pick the smaller team for a joining player.
func assign_team(world: World) -> int:
	if not is_team():
		return 0
	var counts := [0, 0, 0]
	for p: PlayerEntity in world.humans():
		counts[p.team] += 1
	return 1 if counts[1] <= counts[2] else 2


func color_for(p: PlayerEntity) -> Color:
	if is_team():
		return TEAM_COLORS[p.team]
	return Color.from_hsv(fmod(p.id * 0.618034, 1.0), 0.85, 0.95)


## Returns true if the match just ended.
func on_kill(world: World, victim: PlayerEntity, killer: PlayerEntity) -> bool:
	if state != State.PLAYING or killer == null or killer == victim:
		return false
	if is_team():
		if killer.team == victim.team:
			return false
		team_scores[killer.team] += 1
		if team_scores[killer.team] >= score_limit:
			_end(world)
			return true
	elif killer.kills >= score_limit:
		_end(world)
		return true
	return false


## Returns 1 if match ended this tick, 2 if a new match should start.
func step(world: World) -> int:
	if state == State.PLAYING and world.tick >= end_tick:
		_end(world)
		return 1
	if state == State.ENDED and world.tick >= end_tick:
		return 2
	return 0


func _end(world: World) -> void:
	state = State.ENDED
	end_tick = world.tick + END_SCREEN_TICKS
	if is_team():
		winner = 1 if team_scores[1] > team_scores[2] else (2 if team_scores[2] > team_scores[1] else 0)
		winner_name = ["Draw", "Orange", "Cyan"][winner]
	else:
		var best: PlayerEntity = null
		for p: PlayerEntity in world.humans():
			if best == null or p.kills > best.kills or (p.kills == best.kills and p.deaths < best.deaths):
				best = p
		winner = best.id if best else -1
		winner_name = best.name if best else "nobody"
	print("[server] match over: %s (%s)" % [result_text(), mode_name(mode)])


func result_text() -> String:
	return winner_text(winner_name)


static func winner_text(wname: String) -> String:
	return "Draw!" if wname == "Draw" else "%s wins!" % wname
