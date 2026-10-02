# The dress-on statue beside the plaza monument, drawn on with the XR pen, headless.
#   godot --headless --xr-mode off --path . --script tools/gate_statue.gd [-- --control=on_monument|canvas_frame]
# PASS: the statue stands within 2.5 m of the monument's collider and clears every station collider,
# and the scripted skirt, drawn by a pen tool held at the statue (pen_bridge, pen = "xr"), lands in
# the statue's body frame and becomes a closed garment shown on it.
# Controls, each must FAIL: on_monument stands the statue inside the monument; canvas_frame turns
# off the bridge's statue routing, so the same pen strokes land in the canvas body's frame.
extends SceneTree

const SCENE := "res://xr_main.tscn"
const ObjIO := preload("res://util/obj_io.gd")
const NEAR_MONUMENT := 2.5
const MIN_CLEARANCE := 0.05
const ON_BODY := 0.3
const WALL_S := 280.0

class PenTool extends Node3D:
	var active := false
	var pressure := 0.005

var _main: Node
var _statue: Node3D
var _bridge: Node
var _tool: PenTool
var _control := ""
var _phase := "boot"
var _strokes: Array = []
var _steps: Array = []
var _fails := 0
var _t0 := 0

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--control="):
			_control = a.substr(10)
	if _control not in ["", "on_monument", "canvas_frame"]:
		_finish("FAIL (unknown control %s)" % _control)
		return
	_main = load(SCENE).instantiate()
	root.add_child(_main)
	_statue = _main.get_node("World/Station/Statue")
	_bridge = _main.get_node("World/PenBridge")
	_tool = PenTool.new()
	_tool.name = "StatuePen"
	_main.get_node("World").add_child(_tool)
	_bridge.tools.append(_bridge.get_path_to(_tool))
	print("gate_statue: Godot %s, control %s" % [Engine.get_version_info().string, _control if _control != "" else "none"])

func _check(ok: bool, what: String, detail: String) -> void:
	print("%s %s: %s" % ["PASS" if ok else "FAIL", what, detail])
	if not ok:
		_fails += 1

func _process(_dt: float) -> bool:
	if _phase == "done":
		return false
	if (Time.get_ticks_msec() - _t0) / 1000.0 > WALL_S:
		_finish("FAIL (wall clock %.0f s in %s: %s)" % [WALL_S, _phase, _main.dress_on_status()])
		return false
	var station: Node3D = _main.get_node("World/Station")
	match _phase:
		"boot":
			if station.stats.is_empty():
				return false
			if _control == "on_monument":
				_statue.place(station.ctx.physics, 0.0)
			if not _statue.placed:
				_finish("FAIL (the statue was not placed: %s)" % str(_statue.monument))
				return false
			_measure_placement(station.ctx.physics)
			_main.pipeline.strokes_ready.connect(func(s: Array): _strokes = s)
			if _control == "canvas_frame":
				_bridge.statue = null
			var r: String = _main.dress_on_run_opts({"pen": "xr", "allow_fixture": "infer,rig", "stop_after": "MESH"})
			print("run: " + r)
			_phase = "author"
		"author":
			if _strokes.is_empty() or _main.pipeline.state != "AUTHOR":
				return false
			_plan_strokes()
			_phase = "draw"
		"draw":
			if not _steps.is_empty():
				var s: Array = _steps.pop_front()
				_tool.global_position = _statue.body.to_global(s[0])
				_tool.active = s[1]
				if s[2] != null:
					_bridge.boundary_mode = s[2]
			else:
				_bridge.finish()
				_phase = "mesh"
		"mesh":
			var st: String = _main.pipeline.state
			if st == "DONE" or st == "FAILED":
				_evaluate()
	return false

func _measure_placement(physics) -> void:
	var body_v: PackedFloat32Array = ObjIO.read(_statue.PLACEHOLDER_BODY).get("v", PackedFloat32Array())
	var radius := Vector2(_statue.PLINTH.x, _statue.PLINTH.z).length() * 0.5
	for i in body_v.size() / 3:
		radius = maxf(radius, Vector2(body_v[3 * i], body_v[3 * i + 2]).length())
	var c: Vector3 = _statue.position
	var m: Dictionary = _statue.monument
	var to_m := Vector2(c.x - m.centre.x, c.z - m.centre.z).length()
	_check(to_m <= NEAR_MONUMENT, "beside the monument", "statue at (%.2f, %.2f), %.2f m from the monument at (%.2f, %.2f)" % [
			c.x, c.z, to_m, m.centre.x, m.centre.z])
	var nearest := INF
	var what := ""
	var counted := 0
	var skipped := 0
	for it in physics.items:
		var box := _as_box(it)
		if box.is_empty():
			skipped += 1
			continue
		if box.y1 < 0.1 or box.y0 > 1.9:
			skipped += 1
			continue
		counted += 1
		var d: float = box.dist.call(c) - radius
		if d < nearest:
			nearest = d
			what = "%s at (%.2f, %.2f)" % [it[0], it[1], it[2]]
	_check(nearest >= MIN_CLEARANCE, "clears the station", "%.3f m to the nearest collider, %s, footprint radius %.3f m; %d colliders in the body's height band, %d outside it" % [
			nearest, what, radius, counted, skipped])

# A collider row as {y0, y1, dist(point) -> horizontal distance}; {} for an unknown kind.
static func _as_box(it: Array) -> Dictionary:
	var kind: String = it[0]
	var cx: float = it[1]
	var cz: float = it[2]
	if kind == "cyl":
		var r: float = it[6]
		return {"y0": it[7], "y1": it[8], "dist": func(p: Vector3) -> float: return maxf(Vector2(p.x - cx, p.z - cz).length() - r, 0.0)}
	var top: float
	match kind:
		"box":
			top = it[8]
		"walk":
			top = it[9]
		"ramp":
			top = maxf(it[10], it[11])
		_:
			return {}
	var hw: float = it[3]
	var hd: float = it[4]
	var inv := Basis(Vector3.UP, -float(it[5]))
	return {"y0": it[7], "y1": top, "dist": func(p: Vector3) -> float:
		var l := inv * Vector3(p.x - cx, 0, p.z - cz)
		return Vector2(maxf(absf(l.x) - hw, 0.0), maxf(absf(l.z) - hd, 0.0)).length()}

func _plan_strokes() -> void:
	for s in _strokes:
		var pts: PackedVector3Array = s.points
		_steps.append([pts[0], true, bool(s.get("boundary", false))])
		for i in range(1, pts.size()):
			_steps.append([pts[i], true, null])
		_steps.append([pts[pts.size() - 1], false, null])
	print("pen: %d strokes, %d frames held at the statue" % [_strokes.size(), _steps.size()])

func _evaluate() -> void:
	var p = _main.pipeline
	var c: Dictionary = p.data.get("counts", {})
	var strokes := int(c.get("strokes", -1))
	var cycles := int(c.get("cycles", -1))
	var openings := int(c.get("openings", -1))
	var aabb := AABB()
	var bv: PackedFloat32Array = p.data.get("body_v", PackedFloat32Array())
	for i in bv.size() / 3:
		var v := Vector3(bv[3 * i], bv[3 * i + 1], bv[3 * i + 2])
		aabb = AABB(v, Vector3.ZERO) if i == 0 else aabb.expand(v)
	var off := 0.0
	var n := 0
	for a in p.data.get("authored", []):
		for q in a.points:
			off = maxf(off, _outside(aabb, q))
			n += 1
	_check(n > 0 and off <= ON_BODY, "strokes on the statue", "%d points, farthest %.3f m outside the body's box (bound %.2f m)" % [
			n, off, ON_BODY])
	_check(p.state == "DONE" and strokes == _strokes.size() and cycles == 2 and openings == 2, "garment from the pen",
			"strokes %d of %d, cycles %d, openings %d, %s" % [strokes, _strokes.size(), cycles, openings, p.status()])
	var g: MeshInstance3D = _statue.garment
	var tris: int = g.mesh.get_faces().size() / 3 if g.mesh != null and g.mesh.get_surface_count() > 0 else 0
	_check(tris > 0, "worn by the statue", "%d garment triangles on Statue/Body/Garment" % tris)
	_finish("PASS" if _fails == 0 else "FAIL (%d checks)" % _fails)

static func _outside(b: AABB, q: Vector3) -> float:
	var lo := b.position
	var hi := b.end
	return Vector3(maxf(maxf(lo.x - q.x, q.x - hi.x), 0.0), maxf(maxf(lo.y - q.y, q.y - hi.y), 0.0),
			maxf(maxf(lo.z - q.z, q.z - hi.z), 0.0)).length()

func _finish(verdict: String) -> void:
	print("RESULT: " + verdict)
	_phase = "done"
	quit(0 if verdict == "PASS" else 1)
