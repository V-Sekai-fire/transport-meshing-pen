extends SceneTree
## Shapes with one right answer: closed polyhedra drawn as straight strokes, each stroke joined to
## earlier ones where CASSIE would have recorded an intersection. In any drawing order and stroke
## direction, curvenet.elf's replay must end with exactly the polyhedron's faces.
##   godot --path . --script tests/cassie_shapes.gd [-- --control]

const W := preload("res://addons/witness/witness.gd")

## name: [vertices, edges as vertex pairs, faces as vertex loops]
const SHAPES := {
	"tetrahedron": [[[0, 0, 0], [1, 0, 0], [0.5, 0, 0.866], [0.5, 0.816, 0.289]],
		[[0, 1], [1, 2], [2, 0], [0, 3], [1, 3], [2, 3]],
		[[0, 1, 2], [0, 1, 3], [1, 2, 3], [2, 0, 3]]],
	"square pyramid": [[[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1], [0.5, 0.8, 0.5]],
		[[0, 1], [1, 2], [2, 3], [3, 0], [0, 4], [1, 4], [2, 4], [3, 4]],
		[[0, 1, 2, 3], [0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]],
	"triangular prism": [[[0, 0, 0], [1, 0, 0], [0.5, 0, 0.866], [0, 1, 0], [1, 1, 0], [0.5, 1, 0.866]],
		[[0, 1], [1, 2], [2, 0], [3, 4], [4, 5], [5, 3], [0, 3], [1, 4], [2, 5]],
		[[0, 1, 2], [3, 4, 5], [0, 1, 4, 3], [1, 2, 5, 4], [2, 0, 3, 5]]],
	"cube": [[[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1], [0, 1, 0], [1, 1, 0], [1, 1, 1], [0, 1, 1]],
		[[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]],
		[[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]],
	# Non-convex: an L-shaped floor plan extruded.
	"L prism": [[[0, 0, 0], [2, 0, 0], [2, 0, 1], [1, 0, 1], [1, 0, 2], [0, 0, 2],
			[0, 1, 0], [2, 1, 0], [2, 1, 1], [1, 1, 1], [1, 1, 2], [0, 1, 2]],
		[[0, 1], [1, 2], [2, 3], [3, 4], [4, 5], [5, 0], [6, 7], [7, 8], [8, 9], [9, 10], [10, 11], [11, 6],
			[0, 6], [1, 7], [2, 8], [3, 9], [4, 10], [5, 11]],
		[[0, 1, 2, 3, 4, 5], [6, 7, 8, 9, 10, 11], [0, 1, 7, 6], [1, 2, 8, 7], [2, 3, 9, 8], [3, 4, 10, 9],
			[4, 5, 11, 10], [5, 0, 6, 11]]],
	# The cube's top face split in four by a plus: two strokes from edge midpoints, crossing at its centre.
	"cube with a plus": [[[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1], [0, 1, 0], [1, 1, 0], [1, 1, 1], [0, 1, 1],
			[0.5, 1, 0], [0.5, 1, 1], [0, 1, 0.5], [1, 1, 0.5], [0.5, 1, 0.5]],
		[[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7], [8, 9], [10, 11]],
		[[0, 1, 2, 3], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7],
			[4, 8, 12, 10], [8, 5, 11, 12], [12, 11, 6, 9], [10, 12, 9, 7]]],
}
const SIZE := 0.2
const CENTRE := Vector3(-0.1, 1.1, 0.4)

var stage
var control := false
var failed := PackedStringArray()


func _initialize() -> void:
	control = "--control" in OS.get_cmdline_user_args()
	stage = load("res://stages/curvenet_stage.gd").new()
	stage._ready()
	for name in SHAPES:
		var shape: Array = SHAPES[name]
		var edges: Array = shape[1]
		var identity := []
		for i in edges.size():
			identity.append([i, false])
		_check("%s, edges in listed order" % name, _mismatch(shape, identity))
		var orders := func(rng: RandomNumberGenerator, _lvl) -> Array:
			var idx := range(edges.size())
			for i in range(idx.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t = idx[i]
				idx[i] = idx[j]
				idx[j] = t
			return idx.map(func(e): return [e, rng.randi_range(0, 1) == 1])
		var ladder := [W.Level.new(0, 1, 32, 40)]
		var t: W.Trial = W.resolve_with_ladder("%s faces in any order" % name, ladder, orders,
				func(order): return _mismatch(shape, order) == "", Callable(), func(order): return "%s: %s" % [order, _mismatch(shape, order)])
		_check(t.message, "" if t.outcome == W.Outcome.PROVABLY_NONE else t.message)
	stage.free()
	print("RESULT: ", "PASS" if failed.is_empty() else "FAIL " + ", ".join(failed))
	quit(0 if failed.is_empty() else 1)


func _check(name: String, problem: String) -> void:
	print("%s %s%s" % ["PASS" if problem == "" else "FAIL", name, "" if problem == "" else ": " + problem])
	if problem != "":
		failed.append(name.get_slice(",", 0).get_slice(" faces", 0))


## "" when the replay of the shape drawn in this order ends with exactly its faces.
func _mismatch(shape: Array, order: Array) -> String:
	var session := _session(shape, order)
	var want := _faces(shape, order)
	if control:
		want.append([-1])
	var text: String = stage.session_replay(JSON.stringify(session))
	if not text.begins_with("ok"):
		return text.strip_edges()
	var got := []
	for line in text.split("\n", false).slice(1):
		got.append(Array(line.get_slice("|", 0).strip_edges().split(" ")).map(func(x): return int(x)))
	got.sort()
	return "" if got == want else "faces %s, replay %s" % [want, got]


func _point(shape: Array, v: int) -> Dictionary:
	var p: Array = shape[0][v]
	var q := CENTRE + Vector3(p[0], p[1], p[2]) * SIZE
	return {"x": q.x, "y": q.y, "z": q.z}


func _session(shape: Array, order: Array) -> Dictionary:
	var edges: Array = shape[1]
	var states := []
	var strokes := []
	var drawn := []
	var nodes := {}
	for k in order.size():
		var e: Array = edges[order[k][0]]
		var ends := [e[1], e[0]] if order[k][1] else [e[0], e[1]]
		var constraints := []
		for v in shape[0].size():
			var on_earlier := drawn.filter(func(d): return _on(shape, v, d))
			if not _on(shape, v, ends) or on_earlier.is_empty():
				continue
			var at_node: bool = nodes.has(v) or on_earlier.any(func(d): return v in d)
			constraints.append({"position": _point(shape, v), "isIntersection": true, "isAtExistingNode": at_node,
					"isAtNewEndpoint": v in ends, "alignTangents": false})
			nodes[v] = true
		for v in ends:
			nodes[v] = true
		drawn.append(ends)
		strokes.append({"id": k, "ctrlPts": [_point(shape, ends[0]), _point(shape, ends[1])], "closedLoop": false,
				"planar": true, "appliedPositionConstraints": constraints, "rejectedPositionConstraints": []})
		states.append({"interactionType": 1, "elementID": k, "mirroring": false, "canvasScale": 1.0, "time": float(k)})
	return {"sketchSystem": 2, "sketchModel": 0, "interactionMode": 2, "systemStates": states,
			"allSketchedStrokes": strokes, "allCreatedPatches": []}


## Whether vertex v lies on the straight stroke between vertices ab[0] and ab[1].
func _on(shape: Array, v: int, ab: Array) -> bool:
	var p := _vec(shape, v)
	var a := _vec(shape, ab[0])
	var b := _vec(shape, ab[1])
	var t := (p - a).dot(b - a) / (b - a).length_squared()
	return t >= -1e-9 and t <= 1.0 + 1e-9 and (a + (b - a) * t).distance_to(p) < 1e-9


func _vec(shape: Array, v: int) -> Vector3:
	var p: Array = shape[0][v]
	return Vector3(p[0], p[1], p[2])


## The faces as sorted stroke-id lists, a stroke's id being its place in the drawing order; each side
## of a face belongs to the stroke that holds both its corners.
func _faces(shape: Array, order: Array) -> Array:
	var edges: Array = shape[1]
	var out := []
	for loop in shape[2]:
		var ids := []
		for i in loop.size():
			var a: int = loop[i]
			var b: int = loop[(i + 1) % loop.size()]
			for k in order.size():
				var e: Array = edges[order[k][0]]
				if _on(shape, a, e) and _on(shape, b, e) and not ids.has(k):
					ids.append(k)
		ids.sort()
		out.append(ids)
	out.sort()
	return out
