class_name CollisionGrid
extends RefCounted
## XZ broadphase for player movement. Each cell holds every box that could
## touch a player whose feet are anywhere in that cell (cell expanded by
## MARGIN), in original map order. Because skipped boxes are ones the
## narrowphase would ignore anyway, results are bit-identical to testing all
## boxes - prediction and server stay in lockstep.

const CELL := 4.0
const MARGIN := 1.5  # >= radius + max per-tick travel

var _origin := Vector2.ZERO
var _w := 0
var _h := 0
var _cells: Array = []  # Array[Array[AABB]]
var _all: Array[AABB] = []


func build(boxes: Array[AABB]) -> void:
	_all = boxes
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for b in boxes:
		lo = lo.min(Vector2(b.position.x, b.position.z))
		hi = hi.max(Vector2(b.end.x, b.end.z))
	_origin = lo
	_w = ceili((hi.x - lo.x) / CELL)
	_h = ceili((hi.y - lo.y) / CELL)
	_cells.resize(_w * _h)
	for cz in _h:
		for cx in _w:
			var c_lo := _origin + Vector2(cx, cz) * CELL - Vector2(MARGIN, MARGIN)
			var c_hi := c_lo + Vector2(CELL + MARGIN * 2.0, CELL + MARGIN * 2.0)
			var list: Array[AABB] = []
			for b in boxes:
				if b.end.x >= c_lo.x and b.position.x <= c_hi.x and b.end.z >= c_lo.y and b.position.z <= c_hi.y:
					list.append(b)
			_cells[cz * _w + cx] = list


func near(pos: Vector3) -> Array[AABB]:
	var cx := floori((pos.x - _origin.x) / CELL)
	var cz := floori((pos.z - _origin.y) / CELL)
	if cx < 0 or cz < 0 or cx >= _w or cz >= _h:
		return _all
	return _cells[cz * _w + cx]
