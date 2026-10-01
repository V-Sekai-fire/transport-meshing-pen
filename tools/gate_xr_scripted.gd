# The scripted pen in xr_main.tscn, in XR or flat: the pen bridge replays the
# pipeline's scripted skirt into curvenet.elf and the run stops after MESH.
#
#   godot --path . --xr-mode on --script tools/gate_xr_scripted.gd -- --expect=xr [--hold=60]
#   godot --path . --xr-mode off --script tools/gate_xr_scripted.gd -- --expect=flat
#   godot --path . --xr-mode on --script tools/gate_xr_scripted.gd -- --pen=xr --wallclock=1800
#
# PASS: the view is what --expect says (XR needs an OpenXR session), and the
# pen made 6 strokes that close 2 cycles with 2 openings into a closed skirt shell.
# --pen=xr is a person drawing with the controllers; any stroke count passes
# if they close 2 cycles with 2 openings into one shell.
# Controls: --control=drop_seam must FAIL (MESH), and --expect=xr with the
# runtime hidden must FAIL (flat).
extends SceneTree

const SCENE := "res://xr_main.tscn"

var _args := {}
var _out: FileAccess
var _t0 := 0
var _wall_s := 300.0
var _hold_s := 0.0
var _main: Node = null
var _phase := "boot"
var _frames := 0
var _hold_t0 := 0
var _dts: Array = []
var _verdict := ""
var _xr = null

func _say(s: String) -> void:
	var line := "[%7.2f] %s" % [(Time.get_ticks_msec() - _t0) / 1000.0, s]
	print(line)
	if _out != null:
		_out.store_line(line)
		_out.flush()

func _arg(k: String, d: String = "") -> String:
	return _args.get(k, d)

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_wall_s = float(_arg("wallclock", "300"))
	_hold_s = float(_arg("hold", "0"))
	var out := _arg("out", OS.get_user_data_dir().path_join("xr_scripted.txt"))
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	_out = FileAccess.open(out, FileAccess.WRITE)
	_say("gate_xr_scripted: Godot %s, %s %s, expect=%s control=%s, XR_RUNTIME_JSON=%s" % [
			Engine.get_version_info().string, OS.get_name(), Engine.get_architecture_name(),
			_arg("expect", "xr"), _arg("control", "none"), OS.get_environment("XR_RUNTIME_JSON")])
	_xr = XRServer.find_interface("OpenXR")
	if _xr != null:
		for sig in ["session_begun", "session_visible", "session_focussed", "session_stopping", "session_loss_pending"]:
			if _xr.has_signal(sig):
				_xr.connect(sig, func(): _say("openxr: " + sig))
	var ps: PackedScene = load(SCENE)
	if ps == null:
		_finish("FAIL (cannot load %s)" % SCENE)
		return
	_main = ps.instantiate()
	root.add_child(_main)
	_phase = "wait"

func _process(dt: float) -> bool:
	_frames += 1
	if _phase == "done":
		return false
	if (Time.get_ticks_msec() - _t0) / 1000.0 > _wall_s:
		_finish("FAIL (wall clock %.0f s in %s: %s)" % [_wall_s, _phase, _main.dress_on_status() if _main != null else "-"])
		return false
	match _phase:
		"wait":
			if _frames < 5:
				return false
			var w = _main.get_node_or_null("World")
			var xr_on: bool = w != null and w.xr_on
			_say("view: %s" % ("XR %s" % str(w.xr_runtime) if xr_on else "flat"))
			var want_xr := _arg("expect", "xr") == "xr"
			if xr_on != want_xr:
				_finish("FAIL (view is %s, expected %s)" % ["XR" if xr_on else "flat", _arg("expect", "xr")])
				return false
			_main.pipeline.state_changed.connect(func(st: String, rec: Dictionary): _say("STATE %s %s" % [st, str(rec.get("note", rec.get("reason", "")))]))
			var o := {"pen": _arg("pen", "scripted"), "allow_fixture": "infer,rig", "stop_after": "MESH"}
			if _arg("pace") != "":
				o["pace"] = int(_arg("pace"))
			if _arg("control") == "drop_seam":
				o["drop_seam"] = true
			var r: String = _main.dress_on_run_opts(o)
			_say("run: " + r)
			if not r.begins_with("STARTED"):
				_finish("FAIL (run did not start)")
				return false
			_phase = "run"
		"run":
			var st: String = _main.pipeline.state
			if st == "DONE" or st == "FAILED":
				_verdict = _evaluate()
				_phase = "hold"
				_hold_t0 = Time.get_ticks_msec()
				_say("holding %.0f s" % _hold_s)
				if _arg("face") != "":
					_face_body(float(_arg("face")))
		"hold":
			_dts.append(dt)
			if _dts.size() == 30:
				_save_png()
			if (Time.get_ticks_msec() - _hold_t0) / 1000.0 >= _hold_s and _dts.size() >= 30:
				_frame_times()
				_finish(_verdict)
	return false

func _evaluate() -> String:
	var p = _main.pipeline
	var c: Dictionary = p.data.get("counts", {})
	var m: Dictionary = p.data.get("mesh", {})
	var bridge = _main.get_node_or_null("World/PenBridge")
	_say("pen: state %s, strokes %d, cycles %d, openings %d, patches %d, bridge strokes_sent %d, mesh %s v %s f %s loops %s rims, %s" % [
			p.status(), int(c.get("strokes", -1)), int(c.get("cycles", -1)), int(c.get("openings", -1)),
			int(c.get("patches", -1)), int(bridge.strokes_sent) if bridge != null else -1,
			str(m.get("vertices", -1)), str(m.get("triangles", -1)), str(m.get("loops", -1)), str(m.get("rims", -1)),
			str(m.get("mesh_build", ""))])
	_log_sandboxes(_main)
	var strokes_ok: bool = int(c.get("strokes", -1)) == 6 or (_arg("pen", "scripted") == "xr" and int(c.get("strokes", -1)) > 0)
	var ok: bool = p.state == "DONE" and strokes_ok and int(c.get("cycles", -1)) == 2 \
			and int(c.get("openings", -1)) == 2 and int(m.get("loops", -1)) == 0 and int(m.get("rims", -1)) == 2 \
			and int(m.get("components", -1)) == 1
	return "PASS" if ok else "FAIL (%s)" % p.status()

func _log_sandboxes(n: Node) -> void:
	if n.is_class("Sandbox"):
		var prog = n.get("program")
		var bt := str(n.is_binary_translated()) if n.has_method("is_binary_translated") else "no method"
		_say("sandbox %s: %s is_binary_translated=%s" % [n.get_path(), prog.resource_path if prog != null else "-", bt])
	for c in n.get_children():
		_log_sandboxes(c)

# XR only: turn the body to face the headset and put the garment's centre
# --face metres along its view, so a headset still shows the garment.
func _face_body(d: float) -> void:
	var w = _main.get_node_or_null("World")
	var cam: Node3D = w.get_node_or_null("XROrigin3D/XRCamera3D") if w != null else null
	var body: Node3D = w.get_node_or_null("Body") if w != null else null
	var g: MeshInstance3D = w.get_node_or_null("Body/Garment") if w != null else null
	if cam == null or body == null or g == null or g.mesh == null:
		_say("face: FAIL (no camera, body or garment mesh)")
		return
	var ct := cam.global_transform
	var fwd := -ct.basis.z
	var flat := Vector3(fwd.x, 0.0, fwd.z)
	flat = flat.normalized() if flat.length() > 0.1 else Vector3(0, 0, -1)
	body.global_basis = Basis(Vector3.UP, atan2(-flat.x, -flat.z))
	var gc := g.global_transform * g.get_aabb().get_center()
	body.global_position += ct.origin + fwd * d - gc
	_say("face: head at %s looking %s; garment centre now %.2f m along the view" % [str(ct.origin), str(fwd), d])

func _save_png() -> void:
	var png := _arg("png")
	if png == "":
		return
	var img := root.get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		_say("png: viewport image unavailable")
		return
	DirAccess.make_dir_recursive_absolute(png.get_base_dir())
	_say("png: %s %dx%d %s" % [png, img.get_width(), img.get_height(), error_string(img.save_png(png))])

func _frame_times() -> void:
	var ms: Array = []
	for d in _dts:
		ms.append(float(d) * 1000.0)
	ms.sort()
	var sum := 0.0
	for v in ms:
		sum += v
	var n := ms.size()
	_say("frame ms over %d frames: mean %.2f p50 %.2f p95 %.2f max %.2f; fps %.1f" % [n, sum / n, ms[n / 2],
			ms[mini(n - 1, int(n * 0.95))], ms[n - 1], Engine.get_frames_per_second()])

func _finish(verdict: String) -> void:
	_say("RESULT: " + verdict)
	_phase = "done"
	if _out != null:
		_out.close()
		_out = null
	quit(0 if verdict == "PASS" else 1)
