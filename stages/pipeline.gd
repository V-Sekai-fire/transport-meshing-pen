# pipeline -- the loop as one state machine, advanced from _process (rule 4):
#
#   IDLE -> INFER -> RIG -> AUTHOR -> MESH -> DONE | FAILED(reason)
#
# INFER   body mesh (infer.elf; today the opts.avatar fixture, FoxGirl or Maro)
# RIG     15-joint skeleton (infer.elf's rig; today that fixture's own, via skeleton15)
# AUTHOR  pen events -> curvenet pen_begin/point/end, then curvenet_build
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
const SOLVE_TIMEOUT_MS := 60000 # one stroke's commit; past this the run fails
var _end_pending := -1
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
	"crossings": "mujoco",    # "curvenet": curvenet finds each stroke's crossings; "recorded": the layer's junctions
	"body_snap": true,        # false: curvenet's snap_radius 0, for a sketch not authored on this body
	"drop_seam": false,       # control: the back seam is not drawn, or seam_back is dropped from strokes_from
	                          # -> FAILED(MESH)
	"closed_rings": false,
	"no_boundary": false,     # control: the rings are ordinary strokes, so their caps are patched too
	"mesh_edge": 0.03,        # curvenet mesh_build target_edge_length (m); 0 = no remesh
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
	_end_pending = -1
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

# The junctions the strokes layer recorded for stroke k, flat xyz in the Body frame.
func _recorded_junctions(k: int) -> PackedFloat32Array:
	var flat := PackedFloat32Array()
	var all = JSON.parse_string(str(data.get("strokes_from", {}).get("meta", {}).get("junctions", "[]")))
	if typeof(all) != TYPE_ARRAY or k >= all.size():
		return flat
	for p in all[k]:
		flat.append_array([float(p[0]), float(p[1]), float(p[2])])
	return flat


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
			data.strokes_from = {"path": opts.strokes_from, "strokes": strokes.size(), "meta": saved.meta}
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
		if str(opts.crossings) == "recorded":
			curvenet.set_param("defer_meshing", 1.0)
		data.pen_ends = []
		data.authored = []
		_authored_of = {}
		if opts.pen == "scripted" and not pen_external:
			pen_queue = events.duplicate()
			pen_finished = true
		elif opts.pen == "scripted":
			pass # the bridge replays the same source, with its visuals
		return
	if _end_pending >= 0:
		var pr: Dictionary = curvenet.poll()
		if not pr.done:
			if int(pr.host_ms) > SOLVE_TIMEOUT_MS:
				_fail("pen_end stroke %d: still solving after %d s" % [_end_pending, SOLVE_TIMEOUT_MS / 1000])
			return
		var done_r := str(pr.result)
		data.pen_ends.append(done_r)
		if done_r.begins_with("FAIL"):
			_fail("pen_end stroke %d: %s" % [_end_pending, done_r])
			return
		_end_pending = -1
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
				if str(opts.crossings) == "recorded":
					# On the stage's worker thread: the frame goes on, and the queue waits
					# for this stroke before the next one, so topology stays in order.
					curvenet.start("pen_end_recorded", [sid, _recorded_junctions(e.stroke), e.stroke])
					_end_pending = e.stroke
					return
				elif cx.is_empty():
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
		var r: String = curvenet.start_mesh_build(opts.mesh_edge, opts.weld_eps)
		if not r.begins_with("STARTED"):
			_fail("mesh_build: " + r)
		return
	var p: Dictionary = curvenet.poll()
	if not p.done:
		return
	var r := str(p.result)
	data.mesh = {"mesh_build": r, "host_ms": p.host_ms}
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
