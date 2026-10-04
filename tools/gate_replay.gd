# The Skateboard's simulator implementation: the pen driven through OpenXR by
# OXRSys, with tools/replay_oxrsys.py in place of the simulator's hand.
#
#   XR_RUNTIME_JSON=<oxrsys build>/runtime/oxrsys-runtime.json \
#     godot --path . --rendering-driver metal --xr-mode on --script tools/gate_replay.gd -- \
#       --plan=<plan.json> --out=<results.txt> [--wallclock=600]
#   python3 tools/replay_oxrsys.py <plan.json>      (started alongside)
#
#   godot --headless --path . --xr-mode off --script tools/gate_replay.gd -- \
#       --strokes=tools/strokes/skirt.usda [--control=drop_seam]
#
# --strokes replays saved strokes with no XR and checks them against the
# layer's expected counts; --control=drop_seam drops seam_back and must FAIL
# at MESH. A layer carrying a CASSIE "session" (dress) passes only when
# curvenet's graph port replays it to every one of its "expected_cycles".
#
# The pipeline runs with pen = "xr" and stops after MESH, so every stroke comes
# from xr-grid's SketchTool on the right controller: OXRSys tracking packet ->
# OpenXR pose and trigger -> hand.gd -> SketchTool.active -> xr/pen_bridge.gd
# -> curvenet.elf. Boundary mode toggles on the thumbstick click, and the
# menu button ends the authoring, as a person would.
#
# The strokes are the pipeline's own scripted skirt (xr/pen_source_scripted.gd,
# via strokes_ready), in the Body frame. The replay client first holds the
# right controller at CALIB (tracking space); this script reads where that
# lands in the XROrigin frame, and writes the plan: every point mapped Body ->
# XROrigin, minus that offset, so the runtime's reference-space origin cancels.
#
# PASS: the pen made as many strokes as the plan has, and curvenet closed the
# full skirt's 2 cycles with 2 openings (Gate 8's pen criteria).
extends SceneTree

const StrokesUsd := preload("res://util/strokes_usd.gd")

const SCENE := "res://xr_main.tscn"
const CALIB := Vector3(0.0, 1.2, -0.3)
const FULL_SKIRT_CYCLES := 2

var _args := {}
var _out: FileAccess
var _t0 := 0
var _wall_s := 600.0
var _main: Node = null
var _phase := "boot"
var _frames := 0
var _strokes: Array = []
var _plan_path := ""
var _calib_frames := 0
var _strokes_file := ""
var _frame_cam: Camera3D = null
var _session := {}

func _say(s: String) -> void:
	print(s)
	if _out != null:
		_out.store_line(s)
		_out.flush()

func _arg(k: String, d: String = "") -> String:
	return _args.get(k, d)

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_wall_s = float(_arg("wallclock", "600"))
	_plan_path = _arg("plan", OS.get_user_data_dir().path_join("replay_plan.json"))
	var out := _arg("out", OS.get_user_data_dir().path_join("replay_results.txt"))
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	_out = FileAccess.open(out, FileAccess.WRITE)
	DirAccess.remove_absolute(_plan_path)
	_say("gate_replay: Godot %s, XR_RUNTIME_JSON %s" % [Engine.get_version_info().string,
			OS.get_environment("XR_RUNTIME_JSON").get_file()])
	var ps: PackedScene = load(SCENE)
	if ps == null:
		_finish("FAIL (cannot load %s)" % SCENE)
		return
	_main = ps.instantiate()
	root.add_child(_main)
	_strokes_file = _arg("strokes")
	_phase = "replay_wait" if _strokes_file != "" else "wait"

func _process(_dt: float) -> bool:
	_frames += 1
	_follow_body()
	if _phase == "done":
		return false
	if (Time.get_ticks_msec() - _t0) / 1000.0 > _wall_s:
		_finish("FAIL (wall clock %.0f s in %s: %s)" % [_wall_s, _phase,
				_main.dress_on_status() if _main != null and _main.get("pipeline") != null else "-"])
		return false
	match _phase:
		"replay_wait":
			# Saved-stroke replay: no XR, no OXRSys hand. The pipeline reads the
			# strokes straight from the .usda (strokes_from) and feeds curvenet,
			# so the run is deterministic and needs no simulator.
			if _frames < 5:
				return false
			_main.pipeline.state_changed.connect(func(st: String, _rec: Dictionary): _say("STATE " + st))
			# Every stroke in its saved order, all in one frame: sequenced, not paced.
			# --paced feeds them frame by frame, for a recording.
			var o := {"strokes_from": _strokes_file, "allow_fixture": "infer,rig", "stop_after": _stop_after(),
					"pen_instant": _arg("paced") == ""}
			# The layer's own replay settings, then any given on the command line.
			var meta: Dictionary = StrokesUsd.from_file(_main.usd, _strokes_file).get("meta", {})
			for k in ["crossings", "body_snap"]:
				if meta.has(k):
					o[k] = str(meta[k]) if k == "crossings" else str(meta[k]).to_lower() not in ["0", "false"]
				if _arg(k) != "":
					o[k] = _arg(k) if k == "crossings" else _arg(k) == "true"
			# The session replay is the graph port alone, so it runs before the strokes.
			_session = _session_check(_main.pipeline, meta)
			_say("replay settings: crossings %s body_snap %s" % [o.get("crossings", "mujoco"), o.get("body_snap", true)])
			match _arg("control"):
				"":
					pass
				"drop_seam":
					o["drop_seam"] = true
				_:
					_finish("FAIL (unknown control %s)" % _arg("control"))
					return false
			var rr: String = _main.dress_on_run_opts(o)
			_say("replay %s control=%s: %s" % [_strokes_file.get_file(), _arg("control", "none"), rr])
			if not rr.begins_with("STARTED"):
				_finish("FAIL (replay did not start: %s)" % rr)
				return false
			_phase = "replay_run"
		"replay_run":
			var stt: String = _main.pipeline.state
			if stt == "DONE" or stt == "FAILED":
				_evaluate_file()
		"wait":
			if _frames < 5:
				return false
			if _arg("control") != "":
				_finish("FAIL (--control needs --strokes)")
				return false
			var w = _main.get_node_or_null("World")
			if w == null or not w.xr_on:
				_finish("FAIL (no XR session: is XR_RUNTIME_JSON set and --xr-mode on?)")
				return false
			_say("view: XR %s" % str(w.xr_runtime))
			_main.pipeline.strokes_ready.connect(func(s: Array): _strokes = s)
			_main.pipeline.state_changed.connect(func(st: String, _rec: Dictionary): _say("STATE " + st))
			var r: String = _main.dress_on_run_opts({"pen": "xr", "allow_fixture": "infer,rig", "stop_after": "MESH"})
			_say("run: " + r)
			if not r.begins_with("STARTED"):
				_finish("FAIL (run did not start)")
				return false
			_phase = "strokes"
		"strokes":
			if not _strokes.is_empty():
				_phase = "calib"
		"calib":
			# The client holds the right controller at CALIB; wait until the
			# pose is tracked and has stayed put for a few frames.
			var hand: XRController3D = _main.get_node("World/XROrigin3D/hand_right")
			if hand.get_has_tracking_data() and hand.position.length() > 0.0:
				_calib_frames += 1
			if _calib_frames >= 30:
				_write_plan(hand.position - CALIB)
				_phase = "author"
		"author":
			var st: String = _main.pipeline.state
			if st == "DONE" or st == "FAILED":
				_evaluate()
	return false

func _write_plan(offset: Vector3) -> void:
	var origin: Node3D = _main.get_node("World/XROrigin3D")
	var body: Node3D = _main.get_node("World/XROrigin3D/Canvas/Body")
	var to_origin := origin.global_transform.affine_inverse() * body.global_transform
	var plan := {"calib": [CALIB.x, CALIB.y, CALIB.z], "strokes": []}
	for s in _strokes:
		var pts := []
		for p in s.points:
			var q: Vector3 = to_origin * p - offset
			pts.append([q.x, q.y, q.z])
		plan.strokes.append({"name": s.name, "boundary": bool(s.boundary), "points": pts})
	var f := FileAccess.open(_plan_path + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(plan))
	f.close()
	DirAccess.rename_absolute(_plan_path + ".tmp", _plan_path)
	_say("plan: %d strokes, offset %s (the runtime's origin in XROrigin space), %s" % [_strokes.size(), str(offset), _plan_path])

func _evaluate() -> void:
	var p = _main.pipeline
	var c: Dictionary = p.data.get("counts", {})
	var strokes := int(c.get("strokes", -1))
	var cycles := int(c.get("cycles", -1))
	var openings := int(c.get("openings", -1))
	_say("pen: strokes %d (plan %d) cycles %d openings %d, state %s, bridge strokes_sent %d; %s" % [strokes, _strokes.size(),
			cycles, openings, p.state, int(_main.get_node("World/PenBridge").strokes_sent) if _main.has_node("World/PenBridge") else -1,
			_mesh_line(p)])
	var ok: bool = p.state == "DONE" and strokes == _strokes.size() and cycles == FULL_SKIRT_CYCLES and openings == 2
	_finish("PASS" if ok else "FAIL (%s)" % p.status())

func _evaluate_file() -> void:
	var p = _main.pipeline
	var c: Dictionary = p.data.get("counts", {})
	var strokes := int(c.get("strokes", -1))
	var cycles := int(c.get("cycles", -1))
	var openings := int(c.get("openings", -1))
	var sf: Dictionary = p.data.get("strokes_from", {})
	var planned := int(sf.get("strokes", -1))
	var exp := _expected(sf.get("meta", {}))
	_say("replay: strokes %d (planned %d) cycles %d openings %d, expected %s, state %s; %s" % [strokes, planned, cycles,
			openings, JSON.stringify(exp) if not exp.is_empty() else "none", p.status(), _mesh_line(p)])
	var ends: Array = p.data.get("pen_ends", [])
	var first_bad := -1
	var best := ""
	for i in ends.size():
		if not str(ends[i]).begins_with("ok="):
			if first_bad < 0:
				first_bad = i
		else:
			best = str(ends[i])
	_say("pen_ends: %d, first not ok at %d (%s); last ok: %s" % [ends.size(), first_bad,
			str(ends[first_bad]).left(160) if first_bad >= 0 else "-", best.left(200)])
	var session := _session
	if p.state != "DONE":
		_finish("FAIL (%s)" % p.status())
		return
	if not session.is_empty():
		_finish("PASS" if session.ok else "FAIL (%s)" % session.why)
		return
	if exp.is_empty():
		_finish("FAIL (%s has no readable expected in its customLayerData)" % _strokes_file.get_file())
		return
	var ok: bool = strokes == planned and cycles == int(exp.cycles) and openings == int(exp.openings)
	_finish("PASS" if ok else "FAIL (counts differ from expected)")

# A layer with a "session" replays it through curvenet's CASSIE graph port and
# matches the port's cycles, as sorted stroke-id lists, against "expected_cycles".
# {} when the layer has no session.
func _session_check(p, meta: Dictionary) -> Dictionary:
	if not meta.has("session"):
		return {}
	var expected = JSON.parse_string(str(meta.get("expected_cycles", "")))
	if typeof(expected) != TYPE_ARRAY:
		_say("session: no readable expected_cycles")
		return {"ok": false, "why": "session without expected_cycles"}
	if p.curvenet == null:
		return {"ok": false, "why": "no curvenet stage for the session replay"}
	while p.curvenet.busy():
		OS.delay_msec(20)
	p.curvenet.poll()
	var t0 := Time.get_ticks_usec()
	var r: String = p.curvenet.session_replay(str(meta.session))
	var ms := (Time.get_ticks_usec() - t0) / 1000
	var lines := r.strip_edges().split("\n")
	if lines.is_empty() or not lines[0].begins_with("ok "):
		_say("session: replay failed in %d ms: %s" % [ms, r.left(200)])
		return {"ok": false, "why": "session replay failed"}
	var port := {}
	for i in range(1, lines.size()):
		port[lines[i].strip_edges()] = true
	var want := {}
	for c in expected:
		want[" ".join(Array(c).map(func(v): return str(int(v))))] = true
	var exact := 0
	for k in want:
		if port.has(k):
			exact += 1
	var expected_only := want.size() - exact
	var port_only := port.size() - exact
	_say("session: %s (%d ms)" % [lines[0], ms])
	_say("session: cycles %d, exact matches %d of %d, expected-only %d, port-only %d" % [port.size(), exact,
			want.size(), expected_only, port_only])
	for k in want:
		if not port.has(k):
			_say("session: expected-only " + k)
	for k in port:
		if not want.has(k):
			_say("session: port-only " + k)
	var ok: bool = exact == want.size() and want.size() == expected.size()
	return {"ok": ok, "why": "session cycles: %d of %d expected matched" % [exact, want.size()]}

# What MESH measured of the garment shell.
static func _mesh_line(p) -> String:
	var m: Dictionary = p.data.get("mesh", {})
	return "mesh %s v %s f, %s boundary loops, %s rims, %s components" % [str(m.get("vertices", -1)),
			str(m.get("triangles", -1)), str(m.get("loops", -1)), str(m.get("rims", -1)), str(m.get("components", -1))]

# Where the layer's replay stops: its own stop_after (a dress stops after AUTHOR, since MESH checks a
# skirt's shell), MESH otherwise. Read through usd.elf, like every other value of the layer.
func _stop_after() -> String:
	var saved: Dictionary = StrokesUsd.from_file(_main.usd, _strokes_file)
	return str(saved.get("meta", {}).get("stop_after", "MESH"))

# The layer's expected counts. usd.elf hands every customLayerData value back
# as text, so it is JSON; {} when missing, unreadable, or without both counts.
static func _expected(meta: Dictionary) -> Dictionary:
	var e = meta.get("expected", null)
	if typeof(e) == TYPE_STRING:
		e = JSON.parse_string(e)
	if typeof(e) != TYPE_DICTIONARY or not (e.has("cycles") and e.has("openings")):
		return {}
	return e

# --frame: a camera on the drawn body from the front quarter, for a recording.
func _follow_body() -> void:
	if _arg("frame") == "" or _main == null:
		return
	var body := _main.get_node_or_null("World/XROrigin3D/Canvas/Body") as Node3D
	if body == null:
		return
	if _frame_cam == null:
		_frame_cam = Camera3D.new()
		_frame_cam.fov = 40.0
		_main.get_node("World").add_child(_frame_cam)
		_frame_cam.current = true
	var at := body.global_position + Vector3(0, float(_arg("frame_up", "1.0")), 0)
	var dist := float(_arg("frame_dist", "2.6"))
	_frame_cam.global_position = at + Vector3(0.45, 0.15, 1.0).normalized() * dist
	_frame_cam.look_at(at, Vector3.UP)


func _finish(verdict: String) -> void:
	if _main != null and _main.get("pipeline") != null:
		var pl = _main.pipeline
		var pe: Array = pl.data.get("pen_ends", [])
		_say("progress: %d strokes committed; last: %s" % [pe.size(), str(pe[-1]).left(200) if not pe.is_empty() else "-"])
		if _arg("probe_cycles") != "" and pl.curvenet != null:
			while pl.curvenet.busy():
				OS.delay_msec(20)
			pl.curvenet.poll()
			var t0 := Time.get_ticks_usec()
			var c = pl.curvenet.call_now("find_cycles_count")
			_say("probe: one find_cycles walk finds %s cycles in %d ms" % [str(c), (Time.get_ticks_usec() - t0) / 1000])
			var srcs = pl.curvenet.call_now("cycle_sources")
			_say("cycle_sources: " + ",".join(Array(srcs).map(func(v): return str(v))))
	_say("RESULT: " + verdict)
	_phase = "done"
	if _out != null:
		_out.close()
		_out = null
	var hold := float(_arg("hold", "0"))
	if hold > 0.0:
		await create_timer(hold).timeout
	quit(0 if verdict == "PASS" else 1)
