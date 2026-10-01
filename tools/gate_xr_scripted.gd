# The scripted pen in xr_main.tscn, in XR or flat: the pen bridge replays the
# pipeline's scripted skirt into curvenet.elf and the run stops after MESH.
#
#   godot --path . --xr-mode on --script tools/gate_xr_scripted.gd -- --expect=xr [--hold=60]
#   godot --path . --xr-mode off --script tools/gate_xr_scripted.gd -- --expect=flat
#   godot --path . --xr-mode on --script tools/gate_xr_scripted.gd -- --pen=xr --wallclock=1800
#   godot --path . --xr-mode off --write-movie s.cfhd --fixed-fps 30 --script tools/gate_xr_scripted.gd -- --expect=flat --clip=40 --hide=shorts/pen-skirt.hide
#
# PASS: the view is what --expect says (XR needs an OpenXR session), and the
# pen made 6 strokes that close 2 cycles with 2 openings into a closed skirt shell.
# --pen=xr is a person drawing with the controllers; any stroke count passes
# if they close 2 cycles with 2 openings into one shell.
# --clip ends a Movie Maker run at exactly SECONDS x fps frames; --hide draws a short's
# Hook/Intrigue/Delivery/Exit captions and checks each beat's pixels in the frame.
# Controls: --control=drop_seam must FAIL (MESH), --expect=xr with the runtime
# hidden must FAIL (flat), and --control=no_captions must FAIL (captions).
extends SceneTree

const SCENE := "res://xr_main.tscn"
const BEATS := ["hook", "intrigue", "delivery", "exit"]
const MARK := "https://github.com/v-sekai-fire"
const PANEL := Color(0.05, 0.05, 0.05)

var _args := {}
var _out: FileAccess
var _t0 := 0
var _wall_s := 300.0
var _hold_s := 0.0
var _main: Node = null
var _phase := "boot"
var _frames := 0
var _hold_t0 := 0
var _hold_game := 0.0
var _dts: Array = []
var _verdict := ""
var _xr = null
var _fps := 0.0
var _clip_s := 0.0
var _clip_frames := 0
var _delay_s := 0.0
var _caps: Array = []
var _beat := -1
var _cap_panel: PanelContainer = null
var _cap_label: Label = null
var _cap_checks: Array = []
var _cap_h := 0
var _dt_sum := 0.0

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
	_clip_s = float(_arg("clip", "0"))
	_delay_s = float(_arg("delay", "0"))
	if (_clip_s > 0.0 or _arg("hide") != "") and not _movie():
		_finish("FAIL (--clip and --hide need Movie Maker)")
		return
	if _movie():
		_fps = float(_arg("fps", "30"))
		_clip_frames = int(roundf(_clip_s * _fps))
		if absf(_clip_frames - _clip_s * _fps) > 1e-6:
			_finish("FAIL (--clip=%s is no whole number of frames at %d fps)" % [_arg("clip"), int(_fps)])
			return
		if _clip_frames > 0:
			_say("clip: %d frames at %d fps" % [_clip_frames, int(_fps)])
	if _arg("hide") != "":
		if _arg("expect", "xr") == "xr":
			_finish("FAIL (--hide draws captions in flat mode only)")
			return
		var why := _load_hide(_arg("hide"))
		if why != "":
			_finish("FAIL (hide script: %s)" % why)
			return
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
	if not _caps.is_empty():
		_caption_layer()
	_phase = "wait"

func _process(dt: float) -> bool:
	_frames += 1
	if _phase == "done":
		return false
	# A script cannot read --fixed-fps; the engine's steps jitter but sum to frames/fps.
	if _movie() and _frames <= 60:
		_dt_sum += dt
		if _frames == 60 and roundf(60.0 / _dt_sum) != _fps:
			_finish("FAIL (the movie runs at %.0f fps, not --fps=%s)" % [roundf(60.0 / _dt_sum), _arg("fps", "30")])
			return false
	if (Time.get_ticks_msec() - _t0) / 1000.0 > _wall_s:
		_finish("FAIL (wall clock %.0f s in %s: %s)" % [_wall_s, _phase, _main.dress_on_status() if _main != null else "-"])
		return false
	if not _caps.is_empty():
		_captions()
	if _clip_frames > 0 and _frames >= _clip_frames:
		if _phase != "hold":
			_finish("FAIL (the %s s clip ended in %s, before the pen reached DONE: %s)" % [_arg("clip"), _phase, _main.dress_on_status()])
		else:
			_frame_times()
			_finish(_with_captions(_verdict))
		return false
	match _phase:
		"wait":
			if _frames < 5 or _movie_t() < _delay_s:
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
				o["pace"] = float(_arg("pace"))
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
				if _clip_frames > 0:
					_say("DONE at frame %d; the clip runs to frame %d" % [_frames, _clip_frames])
				else:
					_say("holding %.0f s of %s time" % [_hold_s, "movie" if _movie() else "wall-clock"])
				if _arg("face") != "":
					_face_body(float(_arg("face")))
		"hold":
			_dts.append(dt)
			_hold_game += dt
			if _dts.size() == 30:
				_save_png()
			if _clip_frames == 0 and _held() and _dts.size() >= 30:
				_frame_times()
				_finish(_verdict)
	return false


func _movie_t() -> float:
	return (_frames - 1) / _fps if _fps > 0.0 else 0.0




func _load_hide(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot read %s" % path
	for raw: String in f.get_as_text().split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var p := line.split(" ", false, 2)
		if p.size() < 3 or not p[0].is_valid_float():
			return "not <seconds> <beat> <text>: %s" % line
		_caps.append({"at": float(p[0]), "beat": p[1], "text": p[2]})
	var names: Array = _caps.map(func(c: Dictionary) -> String: return c.beat)
	if names != BEATS:
		return "beats %s, HIDE is %s" % [str(names), str(BEATS)]
	if _caps[0].at != 0.0 or _caps[1].at > 3.0:
		return "the hook must hold the first 3 s from 0, not %.2f to %.2f" % [_caps[0].at, _caps[1].at]
	for i in range(1, _caps.size()):
		if _caps[i].at <= _caps[i - 1].at:
			return "%s starts at %.2f, not after %s" % [_caps[i].beat, _caps[i].at, _caps[i - 1].beat]
	if _clip_s > 0.0 and _caps[-1].at >= _clip_s:
		return "the exit starts at %.2f, past the %.2f s clip" % [_caps[-1].at, _clip_s]
	if not String(_caps[-1].text).contains(MARK):
		return "the exit does not show %s" % MARK
	return ""


func _caption_layer() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	_cap_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_content_margin_all(24)
	_cap_panel.add_theme_stylebox_override("panel", sb)
	_cap_panel.anchor_right = 1.0
	_cap_panel.anchor_top = 0.76
	_cap_panel.anchor_bottom = 1.0
	_cap_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_cap_label = Label.new()
	_cap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cap_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cap_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cap_label.add_theme_color_override("font_color", Color.WHITE)
	_cap_panel.add_child(_cap_label)
	_cap_panel.visible = _arg("control") != "no_captions"
	layer.add_child(_cap_panel)
	root.add_child(layer)


# Each beat's text changes at its start; at its midpoint the frame just drawn is read back
# and the caption band is counted pixel by pixel: panel colour and white text, or a FAIL.
func _captions() -> void:
	var h := int(root.get_visible_rect().size.y)
	var t := _movie_t()
	var b := -1
	for i in _caps.size():
		if t + 1e-6 >= _caps[i].at:
			b = i
	if b != _beat or h != _cap_h:
		_cap_h = h
		_cap_label.text = _caption_text(_caps[b].text)
		_fit_caption()
	if b != _beat:
		_beat = b
		_say("caption %s at %.2f s: %s" % [_caps[b].beat, t, _caps[b].text])
	var end: float = _caps[b + 1].at if b + 1 < _caps.size() else (_clip_s if _clip_s > 0.0 else _caps[b].at + 2.0)
	var mid: float = (_caps[b].at + end) / 2.0
	if _cap_checks.size() == b and t >= mid:
		_cap_checks.append(_caption_pixels(_caps[b].beat))


# A URL starts its own line, and the font shrinks until the longest word fits the band, so
# autowrap never breaks a URL at its slashes or hyphens.
func _caption_text(s: String) -> String:
	var out := ""
	for word in s.split(" ", false):
		if out != "":
			out += "\n" if word.contains("://") else " "
		out += word
	return out


func _fit_caption() -> void:
	var font := _cap_label.get_theme_font("font")
	var avail := root.get_visible_rect().size.x - 60.0
	var size := maxi(_cap_h / 24, 12)
	for word in _cap_label.text.replace("\n", " ").split(" ", false):
		var w := font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		if w > avail:
			size = int(size * avail / w)
	_cap_label.add_theme_font_size_override("font_size", maxi(size, 12))

func _caption_pixels(beat: String) -> Dictionary:
	var img := root.get_viewport().get_texture().get_image()
	var r := _cap_panel.get_global_rect()
	var s := Vector2(img.get_width(), img.get_height()) / root.get_visible_rect().size
	var x0 := int(r.position.x * s.x) + 6
	var y0 := int(r.position.y * s.y) + 6
	var x1 := int(r.end.x * s.x) - 6
	var y1 := int(r.end.y * s.y) - 6
	var panel := 0
	var text := 0
	var p8 := PANEL.r8
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			if absi(c.r8 - p8) <= 3 and absi(c.g8 - p8) <= 3 and absi(c.b8 - p8) <= 3:
				panel += 1
			elif c.r8 >= 200 and c.g8 >= 200 and c.b8 >= 200:
				text += 1
	var n := maxi((x1 - x0) * (y1 - y0), 1)
	var ok := float(panel) / n >= 0.5 and float(text) / n >= 0.005
	var check := {"beat": beat, "frame": _frames - 1, "ok": ok, "panel": float(panel) / n, "text": float(text) / n, "pixels": n}
	_say("caption %s %s at frame %d: panel %.3f, text %.4f of %d pixels in (%d,%d)-(%d,%d) of a %dx%d frame" % [
			beat, "ok" if ok else "FAIL", _frames - 1, check.panel, check.text, n, x0, y0, x1, y1, img.get_width(), img.get_height()])
	var out := _arg("out", OS.get_user_data_dir().path_join("xr_scripted.txt"))
	img.save_png(out.get_basename() + "-%d-%s.png" % [_cap_checks.size(), beat])
	return check


func _with_captions(verdict: String) -> String:
	if _caps.is_empty():
		return verdict
	var bad: Array = []
	for i in _caps.size():
		if i >= _cap_checks.size():
			bad.append("%s unchecked" % _caps[i].beat)
		elif not _cap_checks[i].ok:
			bad.append(_caps[i].beat)
	if bad.is_empty():
		return verdict
	return "FAIL (captions: %s)" % ", ".join(bad) if verdict == "PASS" else "%s; captions: %s" % [verdict, ", ".join(bad)]


# Under Movie Maker every frame advances a fixed 1/fps of game time however long it takes to
# render, so the hold counts game time there and --hold sets the clip's length.
func _movie() -> bool:
	return Engine.get_write_movie_path() != ""


func _held() -> bool:
	if _movie():
		return _hold_game + 1e-6 >= _hold_s
	return (Time.get_ticks_msec() - _hold_t0) / 1000.0 >= _hold_s

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
	var body: Node3D = w.get_node_or_null("XROrigin3D/Canvas/Body") if w != null else null
	var g: MeshInstance3D = w.get_node_or_null("XROrigin3D/Canvas/Body/Garment") if w != null else null
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
	if n == 0:
		_say("frame ms: no frames in the hold")
		return
	_say("frame ms over %d frames: mean %.2f p50 %.2f p95 %.2f max %.2f; fps %.1f" % [n, sum / n, ms[n / 2],
			ms[mini(n - 1, int(n * 0.95))], ms[n - 1], Engine.get_frames_per_second()])

func _finish(verdict: String) -> void:
	_say("RESULT: " + verdict)
	_phase = "done"
	if _out != null:
		_out.close()
		_out = null
	quit(0 if verdict == "PASS" else 1)
