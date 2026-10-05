# pipeline -- the loop as one state machine, advanced from _process (rule 4):
#
#   IDLE -> INFER -> RIG -> AUTHOR -> MESH -> DONE | FAILED(reason)
#
# INFER   body mesh (infer.elf; today the opts.avatar fixture, FoxGirl or Maro)
# RIG     15-joint skeleton (infer.elf's rig; today that fixture's own, via skeleton15)
# AUTHOR  pen events -> curvenet pen_begin/point/end, then curvenet_build
#         (recorded strokes: the graph port's cycles, cut from the fitted strokes, -> boundary_patches)
# MESH    mesh_build on curvenet's worker thread -> garment shell + its rims
#
# A stage whose ELF is missing (or too old to have its API) FAILs the run as
# "<stage> missing (...)" unless opts.allow_fixture names it; then its fixture
# stands in and the run is labelled FIXTURE for it. At most one vmcall is in
# flight per sandbox: the long calls go to that stage's worker Thread and the
# machine does nothing else on that stage until poll() says done.
# Every state records its host-timed duration, its stage's vmcall time and
# the stage sandbox's heap when it ends.
extends Node

const PenSource := preload("res://xr/pen_source_scripted.gd")
const MeshTopo := preload("res://util/mesh_topo.gd")
const MeshWire := preload("res://util/mesh_wire.gd")
const StrokesUsd := preload("res://util/strokes_usd.gd")

signal state_changed(state: String, record: Dictionary)
signal body_ready(v: PackedFloat32Array, f: PackedInt32Array)
signal skeleton_ready(joints: PackedFloat32Array, bones: PackedInt32Array)
signal strokes_ready(strokes: Array)
signal garment_ready(v: PackedFloat32Array, f: PackedInt32Array, label: String)
signal progress(text: String) # a line within a state (the heartbeat)

const TERMINAL := ["IDLE", "DONE", "FAILED"]
const PEN_EVENTS_PER_FRAME := 64

var infer = null
var curvenet = null
var mujoco = null
const PORT_TIMEOUT_MS := 60000 # triangulating the port's cycles; past this the run fails
const PORT_WELD_M := 0.003
const PORT_SLICES_PER_WORKER := 3
var _pool: Array = []
var _pool_full := false
const POOL_MEM_MB := 256
var usd = null # stages/usd_stage.gd: strokes_from and saving strokes

var opts := {}
var state := "IDLE"
var reason := ""
var records: Array = []
var fixtures := PackedStringArray()
var data := {}
var pen_queue: Array = []
var pen_external := false # a pen bridge (xr/pen_bridge.gd) feeds pen_queue
var pen_finished := false

var _enter_ms := 0
var _frames := 0
var _run_t0 := 0
var _first := true
var _stroke_ids := {}
var _authored_of := {} # pen stroke index -> data.authored index (the strokes as drawn, for saving)
var _note := ""

const DEFAULTS := {
	"allow_fixture": [],       # stage keys, or one comma-separated String
	"force_fixture": [],       # stages run as their fixture even when present (to reach what follows them)
	"pen": "scripted",        # scripted | xr
	"avatar": "foxgirl",      # the infer/rig fixture body under fixtures/: foxgirl | maro
	"pen_instant": false,     # feed every pen event in order in one frame, not paced per frame
	"crossings": "mujoco",    # "recorded": CASSIE's graph port replays the layer's session; else curvenet's own solve
	"body_snap": true,        # false: curvenet's snap_radius 0, for a sketch not authored on this body
	"drop_seam": false,       # control: the back seam is not drawn, or seam_back is dropped from strokes_from
	                          # -> FAILED(MESH)
	"closed_rings": false,
	"no_boundary": false,     # control: the rings are ordinary strokes, so their caps are patched too
	"mesh_edge": 0.03,        # curvenet mesh_build target_edge_length (m); 0 = no remesh
	"mesh_workers": 1,        # recorded strokes: curvenet sandboxes meshing patches at once; 0 = min(cores - 1, 8)
	"weld_eps": 1e-5,
	"stop_after": "",         # "MESH" for --gate=pen
	"strokes_from": "",       # a .usda of saved strokes (util/strokes_usd.gd, via usd.elf): replaces the
	                          # scripted source; its customLayerData rides along as data.strokes_from.meta
}

func setup(stages: Dictionary) -> void:
	infer = stages.get("infer")
	curvenet = stages.get("curvenet")
	mujoco = stages.get("mujoco")
	usd = stages.get("usd")

# --- control ---------------------------------------------------------------------------

func start(o: Dictionary = {}) -> String:
	if not (state in TERMINAL):
		return "BUSY pipeline in %s" % state
	if curvenet != null and curvenet.busy():
		return "BUSY %s: %s" % [curvenet.stage_name, curvenet.busy_text()]
	opts = DEFAULTS.duplicate(true)
	for k in o:
		opts[k] = o[k]
	if typeof(opts.allow_fixture) == TYPE_STRING:
		opts.allow_fixture = str(opts.allow_fixture).split(",", false)
	opts.allow_fixture = PackedStringArray(opts.allow_fixture)
	if typeof(opts.force_fixture) == TYPE_STRING:
		opts.force_fixture = str(opts.force_fixture).split(",", false)
	opts.force_fixture = PackedStringArray(opts.force_fixture)
	records = []
	fixtures = PackedStringArray()
	data = {}
	pen_queue = []
	pen_finished = false
	reason = ""
	_stroke_ids = {}
	_run_t0 = Time.get_ticks_msec()
	if infer != null:
		infer.avatar = str(opts.avatar)
	for s in [infer, curvenet]:
		if s != null:
			s.take_vm_us()
	_goto("INFER")
	return "STARTED allow_fixture=%s force_fixture=%s pen=%s avatar=%s" % [",".join(opts.allow_fixture),
			",".join(opts.force_fixture), opts.pen, opts.avatar]

# Pen events from a bridge (body-local). kind: begin | point | end.
# boundary (begin only): the stroke is the edge of an opening (curvenet's
# boundary pen mode; a cycle made only of such strokes gets no patch).
func pen_event(kind: String, stroke: int, pos: Vector3 = Vector3.ZERO, pressure: float = 0.5,
		boundary: bool = false) -> void:
	pen_queue.append({"kind": kind, "stroke": stroke, "pos": pos, "pressure": pressure, "boundary": boundary})

func pen_finish() -> void:
	pen_finished = true

func status() -> String:
	var s := "%s" % state
	if state == "FAILED":
		s += "(%s)" % reason
	if not fixtures.is_empty():
		s += " FIXTURE:" + ",".join(fixtures)
	s += " t=%.1fs" % ((Time.get_ticks_msec() - _run_t0) / 1000.0 if _run_t0 > 0 else 0.0)
	return s

func summary() -> Dictionary:
	var d := {"state": state, "reason": reason, "fixtures": fixtures, "records": records,
			"wall_s": (Time.get_ticks_msec() - _run_t0) / 1000.0}
	for k in ["counts", "rings", "min_clearance", "mesh"]:
		if data.has(k):
			d[k] = data[k]
	return d

# --- the machine -------------------------------------------------------------------------

func _process(_dt: float) -> void:
	if state in TERMINAL:
		return
	_frames += 1
	_heartbeat()
	var first := _first
	_first = false
	match state:
		"INFER": _infer()
		"RIG": _rig()
		"AUTHOR": _author(first)
		"MESH": _mesh(first)

# A heartbeat while one guest call runs long (nothing else is written
# meanwhile). Every HEARTBEAT_S seconds of a state, one progress line: the
# state, its age, the stage's in-flight call and its age, and the guest heap (a
# host-side reading, no vmcall). The cost is one clock compare per frame and one
# line per HEARTBEAT_S; the gate writes it to the results file.
const HEARTBEAT_S := 30.0
var _beat_ms := 0

func _heartbeat() -> void:
	var now := Time.get_ticks_msec()
	if now - _enter_ms < HEARTBEAT_S * 1000.0 or now - _beat_ms < HEARTBEAT_S * 1000.0:
		return
	_beat_ms = now
	var st = _stage_for(state)
	var call := ""
	if st != null and st.has_method("busy") and st.busy():
		var p: Dictionary = st.poll()
		call = "%s %.0f s" % [str(p.get("call", "")), float(p.get("host_ms", 0)) / 1000.0]
	progress.emit("HEARTBEAT %s t=%.0f s%s heap %s" % [state, (now - _enter_ms) / 1000.0,
			(" | " + call) if call != "" else "", _fmt_heap(st.heap() if st != null else -1)])

func _fmt_heap(b: int) -> String:
	return "-" if b < 0 else "%.1f MiB" % (b / 1048576.0)

func _stage_for(s: String):
	match s:
		"INFER", "RIG": return infer
		"AUTHOR", "MESH": return curvenet
	return null

func _close_record() -> void:
	if state in TERMINAL:
		return
	var st = _stage_for(state)
	var rec := {
		"state": state,
		"ms": Time.get_ticks_msec() - _enter_ms,
		"frames": _frames,
		"vm_ms": (st.take_vm_us() / 1000.0) if st != null else 0.0,
		"heap": st.heap() if st != null else -1,
		"fixture": _note.begins_with("FIXTURE"),
		"note": _note,
	}
	records.append(rec)
	state_changed.emit(state, rec)

func _goto(next: String, note: String = "") -> void:
	if note != "":
		_note = note
	_close_record()
	if opts.get("stop_after", "") != "" and state == opts.stop_after and next != "FAILED":
		next = "DONE"
	state = next
	_enter_ms = Time.get_ticks_msec()
	_frames = 0
	_first = true
	_note = ""
	if next in ["DONE", "FAILED"]:
		state_changed.emit(next, {"state": next, "reason": reason})

func _fail(why: String) -> void:
	reason = "%s: %s" % [state, why]
	_note = "FAILED " + why
	_goto("FAILED")

func _allowed(key: String) -> bool:
	return opts.allow_fixture.has(key)

# "real" when the stage can run, "fixture" when it cannot and the run allows
# its fixture, "" after failing the run.
func _mode(key: String, stage, missing: String) -> String:
	if opts.force_fixture.has(key):
		if not fixtures.has(key):
			fixtures.append(key)
		return "fixture"
	if missing == "":
		return "real"
	if _allowed(key):
		if not fixtures.has(key):
			fixtures.append(key)
		return "fixture"
	_fail("%s missing (%s)" % [key, missing])
	return ""

func _missing(stage) -> String:
	if stage == null:
		return "no stage node"
	return "" if stage.available() else stage.reason

# --- INFER / RIG ---------------------------------------------------------------------------

func _infer() -> void:
	var m := _mode("infer", infer, _missing(infer) if _missing(infer) != "" else "infer.elf has no pipeline path yet")
	if m == "":
		return
	var b: Dictionary = infer.body_fixture()
	if b.has("error"):
		_fail(b.error)
		return
	data.body_v = b.vertices
	data.body_f = b.triangles
	body_ready.emit(b.vertices, b.triangles)
	_goto("RIG", "%s: %d v, %d f" % [b.source, b.vertices.size() / 3, b.triangles.size() / 3])

func _rig() -> void:
	var m := _mode("rig", infer, _missing(infer) if _missing(infer) != "" else "infer.elf has no rig path yet")
	if m == "":
		return
	var r: Dictionary = infer.rig_fixture()
	if r.has("error") and r.error != "":
		_fail(r.error)
		return
	data.joints = r.joints
	data.bones = r.bones
	skeleton_ready.emit(r.joints, r.bones)
	_goto("AUTHOR", "%s: 15 joints, map %s" % [r.source, str(Array(r.map))])

# --- AUTHOR / MESH -------------------------------------------------------------------------

# Each stroke in drawing order is pushed out of the body as it is drawn. A junction it
# shares with a stroke already drawn stays where that stroke put it; one it is first to
# reach is set by its own push. Junctions sit on the strokes as vertices (cassie_raw_usd).
func _fit_in_drawing_order(strokes: Array, meta: Dictionary) -> Dictionary:
	var err: String = mujoco.load_body("res://fixtures/%s/avatar.obj" % opts.avatar)
	if err != "":
		return {"error": err}
	var axis_z := float(meta.get("body_axis_z", 0.0))
	var clearance := float(meta.get("body_clearance", 0.004))
	var recorded = JSON.parse_string(str(meta.get("junctions", "[]")))
	var is_junction := {}
	for g in recorded:
		for q in g:
			is_junction[_jkey(Vector3(float(q[0]), float(q[1]), float(q[2])))] = true
	var placed := {}
	var out := []
	var moved := 0
	var pinned := 0
	for s in strokes:
		var r: Dictionary = mujoco.push(s.points, 0.0, axis_z, clearance)
		if r.has("error"):
			return r
		moved += int(r.moved)
		var pts: PackedVector3Array = r.points
		for i in pts.size():
			var key := _jkey(s.points[i])
			if not is_junction.has(key):
				continue
			if placed.has(key):
				pts[i] = placed[key]
				pinned += 1
			else:
				placed[key] = pts[i]
		var moved_s: Dictionary = s.duplicate()
		moved_s.points = pts
		out.append(moved_s)
	var junctions := []
	for g in recorded:
		var pts := PackedVector3Array()
		for q in g:
			var v := Vector3(float(q[0]), float(q[1]), float(q[2]))
			pts.append(placed.get(_jkey(v), v))
		junctions.append(pts)
	return {"strokes": out, "junctions": junctions, "moved": moved, "pinned": pinned}


# Recorded strokes: CASSIE's graph port replays the layer's session; each live cycle's
# boundary is cut from the fitted stroke polylines and triangulated on curvenet's worker.
func _port_start() -> void:
	var meta: Dictionary = data.get("strokes_from", {}).get("meta", {})
	if not meta.has("session"):
		_fail("crossings recorded: %s carries no session" % opts.strokes_from)
		return
	var st: String = curvenet.start("session_replay", [str(meta.session)])
	if not st.begins_with("STARTED"):
		_fail("session_replay: " + st)
		return
	data.port = {"phase": "session"}

# The session replay is back: cut the boundaries and hand them to the mesh pool.
func _port_cut(r: String, session_ms: int) -> void:
	var t1 := Time.get_ticks_msec()
	var lines := r.strip_edges().split("\n")
	if lines.is_empty() or not lines[0].begins_with("ok "):
		_fail("session_replay: " + r.left(200))
		return
	var by_name := {}
	for s in data.get("layer_strokes", []):
		by_name[str(s.name)] = s.points
	var edge := float(opts.mesh_edge) if float(opts.mesh_edge) > 0.0 else 0.02
	var bounds := []
	var missing := []
	for i in range(1, lines.size()):
		var parts := lines[i].split(" |", true, 1)
		var pts := PackedVector3Array()
		for tok in (parts[1] if parts.size() > 1 else "").strip_edges().split(" ", false):
			var f := tok.split(":")
			var poly = _port_stroke(by_name, int(f[0]))
			if poly == null:
				missing.append(int(f[0]))
				pts.clear()
				break
			_append_span(pts, poly, float(f[1]) * (poly.size() - 1), float(f[2]) * (poly.size() - 1), edge)
		if pts.size() > 1 and pts[0].distance_to(pts[-1]) < 1e-6:
			pts.remove_at(pts.size() - 1)
		if pts.size() < 3:
			continue
		bounds.append(pts)
	data.pen_ends = by_name.keys()
	var t2 := Time.get_ticks_msec()
	var pool := _mesh_pool()
	var slices := []
	var per := maxi(1, ceili(float(bounds.size()) / float(pool.size() * PORT_SLICES_PER_WORKER)))
	for a in range(0, bounds.size(), per):
		slices.append({"bounds": bounds.slice(a, a + per), "worker": -1, "made": -1})
	data.port = {"session": lines[0], "cycles": lines.size() - 1, "boundaries": bounds.size(), "missing_strokes": missing,
			"replay": r, "session_ms": session_ms, "boundary_ms": t2 - t1, "pool_ms": Time.get_ticks_msec() - t2,
			"workers": pool.size(), "slices": slices, "next": 0, "running": {}, "t0": Time.get_ticks_msec(), "edge": edge,
			"slowest_ms": 0}
	for w in pool:
		if w != curvenet:
			w.call_now("cn_reset")

# Hands the next slice to every idle worker; once every slice is back, gathers the
# patches, in slice order, into the main curvenet sandbox for MESH.
func _port_poll() -> void:
	var port: Dictionary = data.port
	if port.get("phase", "") == "session":
		var sp: Dictionary = curvenet.poll()
		if not sp.done:
			return
		_port_cut(str(sp.result), int(sp.host_ms))
		return
	var pool := _mesh_pool()
	for wi in pool.size():
		var w = pool[wi]
		if w.busy():
			var pr: Dictionary = w.poll()
			if int(pr.host_ms) > PORT_TIMEOUT_MS:
				_fail("boundary_patches: worker %d still meshing after %d s" % [wi, PORT_TIMEOUT_MS / 1000])
			continue
		if port.running.has(wi):
			var r := str(w.poll().result)
			var sl: Dictionary = port.slices[port.running[wi]]
			port.running.erase(wi)
			port.slowest_ms = maxi(int(port.slowest_ms), int(w.poll().host_ms))
			if not r.begins_with("ok"):
				_fail("boundary_patches: " + r)
				return
			sl.made = _kv(r, "patches")
		if port.next < port.slices.size():
			var sl: Dictionary = port.slices[port.next]
			var flat := PackedFloat32Array()
			var counts := PackedInt32Array()
			for pts in sl.bounds:
				for q in pts:
					flat.append_array([q.x, q.y, q.z])
				counts.append(pts.size())
			sl.worker = wi
			port.running[wi] = port.next
			port.next += 1
			var st: String = w.start("boundary_patches", [flat, counts, port.edge, float(opts.mesh_edge)])
			if not st.begins_with("STARTED"):
				_fail("boundary_patches: " + st)
				return
	if port.next < port.slices.size() or not port.running.is_empty():
		return
	port.mesh_ms = Time.get_ticks_msec() - int(port.t0)
	var t_gather := Time.get_ticks_msec()
	var v := PackedFloat32Array()
	var f := PackedInt32Array()
	var c := PackedInt32Array()
	var parts := {}
	for wi in pool.size():
		var wv: PackedFloat32Array = pool[wi].call_now("parts_vertices")
		var wf: PackedInt32Array = pool[wi].call_now("parts_triangles")
		var wc: PackedInt32Array = pool[wi].call_now("parts_counts")
		parts[wi] = {"v": wv, "f": wf, "c": wc, "av": 0, "af": 0, "ac": 0}
	for sl in port.slices:
		var src: Dictionary = parts[sl.worker]
		for k in sl.made:
			var nv: int = src.c[src.ac] * 3
			var nf: int = src.c[src.ac + 1]
			v.append_array(src.v.slice(src.av, src.av + nv))
			f.append_array(src.f.slice(src.af, src.af + nf))
			c.append_array([src.c[src.ac], nf])
			src.av += nv
			src.af += nf
			src.ac += 2
	var sr: String = curvenet.call_now("set_parts", [v, f, c])
	port.gather_ms = Time.get_ticks_msec() - t_gather
	var patches := c.size() / 2
	print("[dress-on] port: %s; %d cycles, %d boundaries, missing strokes %s; session %d ms, boundaries %d ms, pool %d ms, triangulate+remesh %d ms on %d workers in %d slices (slowest %d ms), gather %d ms: %s" % [
			port.session, port.cycles, port.boundaries, str(port.missing_strokes), port.session_ms, port.boundary_ms,
			port.pool_ms, port.mesh_ms, port.workers, port.slices.size(), port.slowest_ms, port.gather_ms, sr])
	if not sr.begins_with("ok"):
		_fail("set_parts: " + sr)
		return
	port.erase("slices")
	data.counts = {"strokes": data.pen_ends.size(), "cycles": int(port.cycles), "openings": 0, "patches": patches,
			"pen_ends": data.pen_ends}
	_goto("MESH", "strokes %d port cycles %d patches %d" % [data.pen_ends.size(), port.cycles, patches])

# The curvenet sandboxes that mesh patches: the main stage, then extra stage nodes of
# their own, each its own sub-thread group, made once.
func _mesh_pool() -> Array:
	var k := int(opts.mesh_workers) if int(opts.mesh_workers) > 0 else clampi(OS.get_processor_count() - 1, 1, 8)
	while _pool.size() < k - 1 and not _pool_full:
		var w: Node = load("res://stages/curvenet_stage.gd").new()
		w.name = "curvenet_pool_%d" % _pool.size()
		w.mem_mb = POOL_MEM_MB
		add_child(w)
		if not w.available():
			_pool_full = true
			w.queue_free()
			break
		_pool.append(w)
	var out := [curvenet]
	for i in mini(k - 1, _pool.size()):
		if _pool[i].available():
			out.append(_pool[i])
	return out

# A port stroke id's fitted polyline: stroke_<id>, or the mirror of stroke id - 1.
static func _port_stroke(by_name: Dictionary, sid: int):
	var n := "stroke_%03d" % sid
	if by_name.has(n):
		return by_name[n]
	n = "stroke_%03d_mirror" % (sid - 1)
	return by_name[n] if by_name.has(n) else null

# The span from fractional index a to b, resampled to about one point per edge length.
# It is sampled low to high and then reversed if need be, so the two cycles sharing a
# span get the same points and their patches weld.
static func _append_span(pts: PackedVector3Array, poly: PackedVector3Array, a: float, b: float, edge: float) -> void:
	var lo := minf(a, b)
	var hi := maxf(a, b)
	var path := PackedVector3Array([_at(poly, lo)])
	for k in range(int(floor(lo)) + 1, int(ceil(hi))):
		path.append(poly[k])
	path.append(_at(poly, hi))
	var cum := [0.0]
	for i in range(1, path.size()):
		cum.append(cum[-1] + path[i - 1].distance_to(path[i]))
	var total: float = cum[-1]
	var n := maxi(1, int(round(total / edge)))
	var out := PackedVector3Array()
	var k := 0
	for m in n + 1:
		var d := total * m / n
		while k < path.size() - 2 and cum[k + 1] < d:
			k += 1
		var seg: float = cum[k + 1] - cum[k] if path.size() > 1 else 0.0
		out.append(path[k].lerp(path[mini(k + 1, path.size() - 1)], (d - cum[k]) / seg if seg > 0.0 else 0.0))
	if b < a:
		out.reverse()
	for q in out:
		if pts.is_empty() or pts[-1].distance_to(q) > 1e-6:
			pts.append(q)

static func _at(poly: PackedVector3Array, x: float) -> Vector3:
	var i := clampi(int(floor(x)), 0, poly.size() - 1)
	return poly[i].lerp(poly[mini(i + 1, poly.size() - 1)], x - floor(x))

func _jkey(v: Vector3) -> String:
	return "%.6f,%.6f,%.6f" % [v.x, v.y, v.z]



# The proximity for MuJoCo crossings (capsule radius is half of it), matching
# the curvenet graph's snap/merge scale.
func _crossing_proximity() -> float:
	return float(opts.get("snap_radius", 0.02))

func _author(first: bool) -> void:
	if first:
		var m := _mode("curvenet", curvenet, _missing(curvenet))
		if m == "":
			return
		if m == "fixture":
			var g: Dictionary = infer.garment_fixture()
			if g.has("error"):
				_fail(g.error)
				return
			var fl: Array = MeshTopo.boundary_loops(g.triangles)
			data.garment = {"vertices": g.vertices, "triangles": g.triangles, "source_joints": g.source_joints,
					"loops": fl, "rims": fl}
			data.counts = {"fixture": true}
			_goto("MESH", g.source)
			return
		var events := []
		if str(opts.strokes_from) != "":
			var saved: Dictionary = StrokesUsd.from_file(usd, opts.strokes_from) if usd != null else {"error": "no usd stage"}
			if saved.has("error"):
				_fail("strokes_from %s: %s" % [opts.strokes_from, saved.error])
				return
			var strokes: Array = saved.strokes
			if opts.drop_seam:
				strokes = strokes.filter(func(s: Dictionary) -> bool: return str(s.name) != "seam_back")
				if strokes.size() != saved.strokes.size() - 1:
					_fail("drop_seam: %s has no stroke seam_back" % opts.strokes_from)
					return
			# A sketch not drawn on this body is fitted with the collision guest: only
			# points inside the body move, out through its surface.
			if str(saved.meta.get("body_fit", "")) == "mujoco" and mujoco != null:
				var fit: Dictionary = _fit_in_drawing_order(strokes, saved.meta)
				if fit.has("error"):
					_fail("body_fit: " + str(fit.error))
					return
				strokes = fit.strokes
				data.recorded_junctions = fit.junctions
				data.body_fit_moved = fit.moved
				print("[dress-on] body_fit: %d stroke points moved out of the body, %d junctions pinned to earlier strokes" % [fit.moved, fit.pinned])
			data.strokes_from = {"path": opts.strokes_from, "strokes": strokes.size(), "meta": saved.meta}
			data.layer_strokes = strokes
			events = StrokesUsd.events(strokes)
			strokes_ready.emit(strokes)
		else:
			var src := PenSource.make(data.body_v, data.joints, {"drop_seam": opts.drop_seam,
					"closed_rings": opts.closed_rings, "no_boundary": opts.no_boundary})
			if src.error != "":
				_fail("pen source: " + src.error)
				return
			data.rings = {"waist": _ring_text(src.waist), "hem": _ring_text(src.hem)}
			data.min_clearance = "%.4f m after growing both rings by %.4f m (the rings alone: %.4f m)" % [
					src.min_clearance, src.grow, src.clearance_before_grow]
			data.expected = src.expected
			events = src.events
			strokes_ready.emit(src.strokes)
		var r0: String = curvenet.reset()
		var r1: String = curvenet.set_body(data.body_v, data.body_f)
		if r0.begins_with("FAIL") or r1.begins_with("FAIL"):
			_fail("curvenet setup: %s | %s" % [r0, r1])
			return
		if not bool(opts.body_snap):
			curvenet.set_param("snap_radius", 0.0)
		data.pen_ends = []
		data.authored = []
		_authored_of = {}
		if str(opts.crossings) == "recorded":
			_port_start()
			return
		if opts.pen == "scripted" and not pen_external:
			pen_queue = events.duplicate()
			pen_finished = true
		elif opts.pen == "scripted":
			pass # the bridge replays the same source, with its visuals
		return
	if data.has("port"):
		_port_poll()
		return
	var n := 0
	while not pen_queue.is_empty() and (opts.pen_instant or n < PEN_EVENTS_PER_FRAME):
		var e: Dictionary = pen_queue.pop_front()
		n += 1
		match e.kind:
			"begin":
				var bm: String = curvenet.set_param("boundary", 1.0 if e.get("boundary", false) else 0.0)
				if bm.begins_with("FAIL"):
					_fail("set_param boundary: " + bm)
					return
				var id: int = curvenet.pen_begin_at(e.pos, e.pressure)
				if id < 0:
					_fail("pen_begin refused stroke %d at %s" % [e.stroke, str(e.pos)])
					return
				_stroke_ids[e.stroke] = id
				_authored_of[e.stroke] = data.authored.size()
				data.authored.append({"name": "stroke_%03d" % data.authored.size(), "boundary": bool(e.get("boundary", false)),
						"points": PackedVector3Array([e.pos])})
			"point":
				curvenet.pen_point_at(_stroke_ids.get(e.stroke, -1), e.pos, e.pressure)
				if _authored_of.has(e.stroke):
					data.authored[_authored_of[e.stroke]].points.append(e.pos)
			"end":
				var sid: int = _stroke_ids.get(e.stroke, -1)
				# Parallel-commit finalize (RFD 2274): the MuJoCo guest finds
				# crossings from every authored stroke polyline and the graph splits
				# at them; add_stroke_with_splits keeps only those on the ending
				# stroke, so passing the whole set is safe. No guest, or none found,
				# falls back to curvenet's own solve (the parallel-commit rollback).
				var cx := PackedVector3Array()
				if str(opts.crossings) == "mujoco" and mujoco != null and mujoco.available():
					var polys := []
					for a in data.authored:
						polys.append(a.points)
					cx = mujoco.crossings(polys, _crossing_proximity())
				var r: String
				if cx.is_empty():
					r = curvenet.pen_end_raw(sid)
				else:
					var flat := PackedFloat32Array()
					for p in cx:
						flat.append(p.x)
						flat.append(p.y)
						flat.append(p.z)
					r = curvenet.pen_end_with_crossings(sid, flat)
				data.pen_ends.append(r)
				if r.begins_with("FAIL"):
					_fail("pen_end stroke %d: %s" % [e.stroke, r])
					return
		if e.kind == "end" and not opts.pen_instant:
			break # at most one stroke ends per frame
	if not pen_queue.is_empty() or not pen_finished:
		return
	var last: String = data.pen_ends[-1] if not data.pen_ends.is_empty() else ""
	var cb: String = curvenet.build_curvenet()
	var kw = curvenet.knots()
	var knots: Array = MeshWire.knots(kw) if typeof(kw) == TYPE_PACKED_FLOAT32_ARRAY else []
	var degrees := []
	var kpos := []
	for k in knots:
		degrees.append(k.degree)
		kpos.append("(%.3f, %.3f, %.3f)" % [k.position.x, k.position.y, k.position.z])
	var patches: int = curvenet.patches()
	data.counts = {
		"strokes": data.pen_ends.size(),
		"cycles": _kv(last, "cycles"),
		"openings": _kv(last, "openings"),
		"edges": _kv(last, "edges"),
		"nodes": _kv(last, "nodes"),
		"patches": patches,
		"curves": _kv(cb, "curves"),
		"knots": _kv(cb, "knots"),
		"knot_degrees": degrees,
		"knot_positions": kpos,
		"pen_ends": data.pen_ends,
		"last_pen_end": last,
		"curvenet_build": cb,
	}
	_goto("MESH", "strokes %d cycles %d openings %d patches %d curves %d knots %d degrees %s" % [data.pen_ends.size(),
			data.counts.cycles, data.counts.openings, patches, data.counts.curves, data.counts.knots, str(degrees)])

func _mesh(first: bool) -> void:
	if data.has("garment"): # the curvenet fixture
		_mesh_done(data.garment, "FIXTURE garment")
		return
	if first:
		# Port cycles meet where the fitted strokes cross, which a sample can miss by a few mm.
		var weld: float = maxf(float(opts.weld_eps), PORT_WELD_M) if data.has("port") else float(opts.weld_eps)
		# Port patches were remeshed one by one in the pool, their seams held.
		var r: String = curvenet.start_mesh_build(0.0 if data.has("port") else opts.mesh_edge, weld)
		if not r.begins_with("STARTED"):
			_fail("mesh_build: " + r)
		return
	var p: Dictionary = curvenet.poll()
	if not p.done:
		return
	var r := str(p.result)
	data.mesh = {"mesh_build": r, "host_ms": p.host_ms}
	print("[dress-on] mesh_build: %d ms: %s" % [int(p.host_ms), r])
	if not r.begins_with("ok"):
		_fail("mesh_build: " + r)
		return
	var a: Dictionary = curvenet.mesh_arrays()
	if a.has("error"):
		_fail(a.error)
		return
	_mesh_done({"vertices": a.vertices, "triangles": a.triangles, "loops": a.loops, "rims": a.rims,
			"source_joints": data.joints}, r)

func _mesh_done(g: Dictionary, note: String) -> void:
	var nv: int = g.vertices.size() / 3
	var nf: int = g.triangles.size() / 3
	var comps := MeshTopo.components(nv, g.triangles)
	# Counted here from the triangles, not taken from the guest's answer.
	var loops: Array = MeshTopo.boundary_loops(g.triangles)
	var rims: Array = g.get("rims", [])
	data.garment = g
	data.mesh = data.get("mesh", {})
	data.mesh.merge({"vertices": nv, "triangles": nf, "loops": loops.size(), "rims": rims.size(), "components": comps,
			"finite": MeshTopo.all_finite(g.vertices)})
	garment_ready.emit(g.vertices, g.triangles, "mesh")
	if data.has("port"):
		var hc := HashingContext.new()
		hc.start(HashingContext.HASH_SHA256)
		hc.update(PackedFloat32Array(g.vertices).to_byte_array())
		hc.update(PackedInt32Array(g.triangles).to_byte_array())
		data.mesh.sha256 = hc.finish().hex_encode().left(16)
		print("[dress-on] mesh: %d v %d f sha256 %s" % [nv, nf, data.mesh.sha256])
		_goto("DONE", "%s | %d v %d f, %d components, %d boundary loops, %d rims" % [note, nv, nf, comps, loops.size(), rims.size()])
		return
	# A skirt is one closed shell, double-sided in its geometry: one component, no boundary
	# loop, and two rims where the drawn tube was open (waist, hem).
	if nf == 0 or comps != 1 or loops.size() != 0 or rims.size() != 2 or not data.mesh.finite:
		_fail("not a closed skirt shell: %d triangles, %d components, %d boundary loops, %d rims (want >0, 1, 0, 2)%s" % [
				nf, comps, loops.size(), rims.size(), "" if data.mesh.finite else ", non-finite vertices"])
		return
	_goto("DONE", "%s | %d v %d f, closed, %d rims" % [note, nv, nf, rims.size()])

# --- helpers ---------------------------------------------------------------------------------

static func _kv(text: String, key: String) -> int:
	var at := text.find(key + "=")
	if at < 0:
		return -1
	var s := text.substr(at + key.length() + 1)
	var end := 0
	while end < s.length() and (s[end] == "-" or (s[end] >= "0" and s[end] <= "9")):
		end += 1
	return int(s.substr(0, end)) if end > 0 else -1

static func _ring_text(r: Dictionary) -> String:
	return "centre %s radius %.4f m (body %.4f m + 0.01, %d vertices)" % [str(r.center), r.radius, r.body_radius, r.vertices]
