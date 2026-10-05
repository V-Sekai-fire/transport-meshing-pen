extends SceneTree
## Random loops from a mesh: a cube split n x n per side, a torus or an open tube, vertices nudged,
## every edge drawn as part of the mesh's rings, each ring cut at random into strokes drawn in random order and
## direction. A stroke meeting a corner an earlier stroke holds records an intersection there. The
## mesh's quads are the one right answer, so curvenet.elf's replay must end with exactly them.
##   godot --path . --script tests/cassie_mesh_loops.gd [-- --mesh=cube|torus|tube --straight --flat --control]

const W := preload("res://addons/witness/witness.gd")
const SIZE := 0.2
const CENTRE := Vector3(-0.1, 1.1, 0.4)

var stage
var control := false
var straight := false
var flat := false
var only := ""


func _initialize() -> void:
	control = "--control" in OS.get_cmdline_user_args()
	straight = "--straight" in OS.get_cmdline_user_args()
	flat = "--flat" in OS.get_cmdline_user_args()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mesh="):
			only = a.trim_prefix("--mesh=")
	stage = load("res://stages/curvenet_stage.gd").new()
	stage._ready()
	# Rung n is the grid size and the nudge grows with it, from none to a fifth of a cell.
	var ladder := [W.Level.new(0, 1, 1, 40), W.Level.new(1, 2, 2, 40), W.Level.new(2, 3, 3, 30)]
	var t: W.Trial = W.resolve_with_ladder("mesh loops replay to the mesh's quads", ladder, _drawing,
			func(d): return _mismatch(d) == "", Callable(), func(d): return "%s n=%d nudge=%.3f strokes=%d: %s" % [
				d["mesh"], d["n"], d["nudge"], d["strokes"].size(), _mismatch(d)])
	var ok := t.outcome == W.Outcome.PROVABLY_NONE
	_rates(ladder)
	print("%s %s" % ["PASS" if ok else "FAIL", t.message])
	stage.free()
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


## One random drawing: {mesh, n, nudge, points (key -> Vector3), strokes (lists of keys), faces}.
func _drawing(rng: RandomNumberGenerator, lvl: W.Level) -> Dictionary:
	var n: int = lvl.fin_bound
	var nudge := 0.0 if flat else 0.2 * float(lvl.idx) / 2.0 * rng.randf()
	var kind: String = only if only != "" else ["cube", "torus", "tube"][rng.randi_range(0, 2)]
	var mesh: Dictionary = {"cube": _cube, "torus": _torus, "tube": _tube}[kind].call(n + (7 if kind != "cube" else 0))
	var points: Dictionary = mesh["points"]
	for key in points:
		points[key] += Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * nudge / float(n)
	var used := {}
	var arcs := []
	for ring in mesh["rings"]:
		var run := [ring[0]]
		for r in range(1, ring.size()):
			var e := _edge(ring[r - 1], ring[r])
			if used.has(e):
				if run.size() > 1:
					arcs.append(run)
				run = [ring[r]]
				continue
			used[e] = true
			var turns: bool = run.size() > 1 and not _straight(points, run[run.size() - 2], ring[r - 1], ring[r])
			if run.size() > 1 and (rng.randi_range(0, 2) == 0 or (straight and turns)):
				arcs.append(run)
				run = [ring[r - 1]]
			run.append(ring[r])
		if run.size() > 1:
			arcs.append(run)
	for i in range(arcs.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = arcs[i]
		arcs[i] = arcs[j]
		arcs[j] = t
	for a in arcs.size():
		if rng.randi_range(0, 1) == 1:
			arcs[a].reverse()
	return {"mesh": kind, "n": n, "nudge": nudge, "points": points, "strokes": arcs, "faces": mesh["faces"]}


func _straight(points: Dictionary, a, b, c) -> bool:
	return (points[b] - points[a]).normalized().dot((points[c] - points[b]).normalized()) > 0.999


## A cube split n x n per side, in a unit box: its rings wrap it around each axis.
func _cube(n: int) -> Dictionary:
	var points := {}
	for i in n + 1:
		for j in n + 1:
			for k in n + 1:
				var key := Vector3i(i, j, k)
				if i in [0, n] or j in [0, n] or k in [0, n]:
					points[key] = Vector3(key) / float(n)
	var rings := []
	for axis in 3:
		for level in n + 1:
			rings.append(_ring(axis, level, n))
	return {"points": points, "rings": rings, "faces": _quads(n)}


## A torus of n x n quads, major radius 0.35 and minor 0.15 in the unit box: its rings are the
## meridians and the parallels, and none of them bounds a face.
func _torus(n: int) -> Dictionary:
	var points := {}
	for u in n:
		for v in n:
			var a := TAU * u / n
			var b := TAU * v / n
			points[Vector2i(u, v)] = Vector3(0.5, 0.5, 0.5) + Vector3(cos(a), 0, sin(a)) * (0.35 + 0.15 * cos(b)) + Vector3(0, 0.15 * sin(b), 0)
	var rings := []
	for u in n:
		rings.append(range(n + 1).map(func(v): return Vector2i(u, v % n)))
	for v in n:
		rings.append(range(n + 1).map(func(u): return Vector2i(u % n, v)))
	var faces := []
	for u in n:
		for v in n:
			faces.append([Vector2i(u, v), Vector2i((u + 1) % n, v), Vector2i((u + 1) % n, (v + 1) % n), Vector2i(u, (v + 1) % n)])
	return {"points": points, "rings": rings, "faces": faces}


## An open tube of n around by n - 1 along: its rings are the circles and the straight lines along it.
## The two rims are closed loops with nothing inside them, so they bound no face of the mesh.
func _tube(n: int) -> Dictionary:
	var points := {}
	var rows := n - 1
	for u in n:
		for v in rows + 1:
			var a := TAU * u / n
			points[Vector2i(u, v)] = Vector3(0.5 + 0.3 * cos(a), float(v) / rows, 0.5 + 0.3 * sin(a))
	var rings := []
	for v in rows + 1:
		rings.append(range(n + 1).map(func(u): return Vector2i(u % n, v)))
	for u in n:
		rings.append(range(rows + 1).map(func(v): return Vector2i(u, v)))
	var faces := []
	for u in n:
		for v in rows:
			faces.append([Vector2i(u, v), Vector2i((u + 1) % n, v), Vector2i((u + 1) % n, v + 1), Vector2i(u, v + 1)])
	return {"points": points, "rings": rings, "faces": faces}


## The closed ring of grid keys on the cube's surface in the plane axis = level.
func _ring(axis: int, level: int, n: int) -> Array:
	var perimeter := []
	for s in n:
		perimeter.append(Vector2i(s, 0))
	for s in n:
		perimeter.append(Vector2i(n, s))
	for s in n:
		perimeter.append(Vector2i(n - s, n))
	for s in n:
		perimeter.append(Vector2i(0, n - s))
	perimeter.append(Vector2i(0, 0))
	var out := []
	for p in perimeter:
		var c := [0, 0, 0]
		c[axis] = level
		c[(axis + 1) % 3] = p.x
		c[(axis + 2) % 3] = p.y
		out.append(Vector3i(c[0], c[1], c[2]))
	return out


func _quads(n: int) -> Array:
	var out := []
	for axis in 3:
		for side in [0, n]:
			for u in n:
				for v in n:
					var corners := []
					for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]:
						var c := [0, 0, 0]
						c[axis] = side
						c[(axis + 1) % 3] = u + d.x
						c[(axis + 2) % 3] = v + d.y
						corners.append(Vector3i(c[0], c[1], c[2]))
					out.append(corners)
	return out


func _edge(a, b) -> Array:
	return [a, b] if str(a) < str(b) else [b, a]


## "" when the replay ends with exactly the mesh's quads, as sorted stroke-id lists.
func _mismatch(d: Dictionary) -> String:
	var stroke_of := {}
	for k in d["strokes"].size():
		var arc: Array = d["strokes"][k]
		for i in range(1, arc.size()):
			stroke_of[_edge(arc[i - 1], arc[i])] = k
	var want := []
	for q in d["faces"]:
		var ids := []
		for i in 4:
			var s: int = stroke_of[_edge(q[i], q[(i + 1) % 4])]
			if not ids.has(s):
				ids.append(s)
		ids.sort()
		want.append(ids)
	want.sort()
	if control:
		want.append([-1])
	var session_text := JSON.stringify(_session(d))
	var text: String = stage.session_replay(session_text)
	if not text.begins_with("ok"):
		return text.strip_edges()
	var got := []
	for line in text.split("\n", false).slice(1):
		got.append(Array(line.get_slice("|", 0).strip_edges().split(" ")).map(func(x): return int(x)))
	got.sort()
	if got == want:
		return ""
	if OS.get_environment("CASSIE_DUMP") != "":
		FileAccess.open(OS.get_environment("CASSIE_DUMP"), FileAccess.WRITE).store_string(session_text)
	var missing := want.filter(func(f): return not got.has(f))
	var extra := got.filter(func(f): return not want.has(f))
	return "%d quads, replay %d: missing %s, extra %s" % [want.size(), got.size(), missing, extra]


func _session(d: Dictionary) -> Dictionary:
	var states := []
	var strokes := []
	var held := {}
	for k in d["strokes"].size():
		var arc: Array = d["strokes"][k]
		var ctrl := []
		for i in arc.size():
			var p := _world(d, arc[i])
			if i > 0:
				var q := _world(d, arc[i - 1])
				ctrl.append(_json(q.lerp(p, 1.0 / 3.0)))
				ctrl.append(_json(q.lerp(p, 2.0 / 3.0)))
			ctrl.append(_json(p))
		var closed: bool = arc.size() > 2 and arc[0] == arc.back()
		var constraints := []
		for i in arc.size() - (1 if closed else 0):
			if held.has(arc[i]):
				constraints.append({"position": _json(_world(d, arc[i])), "isIntersection": true, "isAtExistingNode": true,
						"isAtNewEndpoint": i == 0 or i == arc.size() - 1, "alignTangents": false})
		for key in arc:
			held[key] = true
		strokes.append({"id": k, "ctrlPts": ctrl, "closedLoop": closed, "planar": false,
				"appliedPositionConstraints": constraints, "rejectedPositionConstraints": []})
		states.append({"interactionType": 1, "elementID": k, "mirroring": false, "canvasScale": 1.0, "time": float(k)})
	return {"sketchSystem": 2, "sketchModel": 0, "interactionMode": 2, "systemStates": states,
			"allSketchedStrokes": strokes, "allCreatedPatches": []}


func _world(d: Dictionary, key) -> Vector3:
	return CENTRE + (d["points"][key] - Vector3(0.5, 0.5, 0.5)) * SIZE


func _json(p: Vector3) -> Dictionary:
	return {"x": p.x, "y": p.y, "z": p.z}


## Quads recovered over 20 drawings per mesh and rung, so a change shows as a number and not only a first failure.
func _rates(ladder: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261005
	var kinds := [only] if only != "" else ["cube", "torus", "tube"]
	for kind in kinds:
		only = kind
		for lvl in ladder:
			var quads := 0
			var hit := 0
			var extra := 0
			var exact := 0
			for i in 20:
				var d := _drawing(rng, lvl)
				var r := _score(d)
				quads += r[0]
				hit += r[1]
				extra += r[2]
				exact += 1 if r[1] == r[0] and r[2] == 0 else 0
			print("RATE %s rung %d: %d of %d quads (%.1f%%), %d extra cycles, %d of 20 drawings exact" % [
					kind, lvl.idx, hit, quads, 100.0 * hit / quads, extra, exact])


func _score(d: Dictionary) -> Array:
	var stroke_of := {}
	for k in d["strokes"].size():
		var arc: Array = d["strokes"][k]
		for i in range(1, arc.size()):
			stroke_of[_edge(arc[i - 1], arc[i])] = k
	var want := []
	for q in d["faces"]:
		var ids := []
		for i in 4:
			var s: int = stroke_of[_edge(q[i], q[(i + 1) % 4])]
			if not ids.has(s):
				ids.append(s)
		ids.sort()
		want.append(ids)
	var text: String = stage.session_replay(JSON.stringify(_session(d)))
	var got := []
	for line in text.split("\n", false).slice(1):
		got.append(Array(line.get_slice("|", 0).strip_edges().split(" ")).map(func(x): return int(x)))
	var hit := want.filter(func(f): return got.has(f)).size()
	return [want.size(), hit, got.filter(func(f): return not want.has(f)).size()]

