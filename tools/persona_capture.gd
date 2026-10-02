# Runs xr_main and, every half second, logs the visitor's station pose, world grab and frame rate, and saves
# what the head camera sees through a mirror SubViewport (the XR viewport's own texture is the headset's).
# With --persona and --beat-file it places the visitor where the persona arrives, saves a frame as each
# beat walk_oxrsys.py reports ends, checks the forecourt stairs tread by tread, and quits with a verdict.
# --no-station frees the station first, for the frame-rate baseline; --self-test runs the stairs judge's controls.
#   godot --path . --xr-mode on -s tools/persona_capture.gd -- --out=<dir> [--persona=<json>]
#       [--beat-file=<path>] [--no-station]
extends SceneTree

const STAIRS := {"x0": 0.6, "x1": 6.2, "z0": -23.3, "z1": -20.4}
const TREAD := 1.25 / 7.0

var _main: Node
var _out := ""
var _beat_file := ""
var _arrive = null
var _bare := false
var _cam := Camera3D.new()
var _view := SubViewport.new()
var _next := 2.0
var _t := 0.0
var _n := 0
var _beat := ""
var _arrived := false
var _passes: Array = []
var _on_stairs := false
var _fps: Array = []


func _initialize() -> void:
	if "--self-test" in OS.get_cmdline_user_args():
		_self_test()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--beat-file="):
			_beat_file = a.substr(12)
		elif a.begins_with("--persona="):
			for b in JSON.parse_string(FileAccess.get_file_as_string(a.substr(10))):
				if b.has("arrive"):
					_arrive = b.arrive
		elif a == "--no-station":
			_bare = true
	_main = load("res://xr_main.tscn").instantiate()
	if _bare:
		_main.get_node("World/StationPlayer").free()
		_main.get_node("World/Station").free()
	get_root().add_child(_main)
	_view.size = Vector2i(960, 540)
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.add_child(_cam)
	get_root().add_child(_view)
	_view.world_3d = get_root().world_3d


func _process(dt: float) -> bool:
	if _main == null:
		return false
	_t += dt
	var xr: Node3D = _main.get_node("World/XROrigin3D/XRCamera3D")
	_cam.global_transform = xr.global_transform
	_cam.fov = 90.0
	var radial: Node3D = _main.get_node("World/Radial")
	if radial.visible:
		_cam.look_at(radial.global_position, Vector3.UP)
	var p = _main.get_node_or_null("World/StationPlayer")
	var walker = p.walker if p else null
	if walker and _arrive != null and not _arrived:
		walker.set_pose(_arrive[0], _arrive[1], _arrive[2])
		_arrived = true
	if walker:
		_track_stairs(walker.pos)
	var beat := _read_beat()
	if beat != _beat:
		if _beat != "":
			_log("beat %s ended:" % _beat.replace("\t", " "), "beat-%s.png" % _beat.get_slice("\t", 0))
		_beat = beat
		if _beat.ends_with("\tdone"):
			return _verdict()
	if _t < _next:
		return false
	_next += 0.5
	_fps.append(Engine.get_frames_per_second())
	_log("", "frame-%03d.png" % _n)
	_n += 1
	return false


func _read_beat() -> String:
	if _beat_file == "" or not FileAccess.file_exists(_beat_file):
		return _beat
	var s := FileAccess.get_file_as_string(_beat_file).strip_edges()
	return s if s != "" else _beat


func _log(lead: String, file: String) -> void:
	var p = _main.get_node_or_null("World/StationPlayer")
	var grab: bool = _main.get_node("World/XROrigin3D/Canvas").enabled
	var radial: bool = _main.get_node("World/Radial").visible
	var pose := "no walker"
	if p and p.walker != null:
		pose = "x %.2f z %.2f feet %.3f yaw %.1f" % [p.walker.pos.x, p.walker.pos.z, p.walker.pos.y, rad_to_deg(p.walker.yaw)]
	var l: XRController3D = _main.get_node("World/XROrigin3D/hand_left")
	var r: XRController3D = _main.get_node("World/XROrigin3D/hand_right")
	pose += " | L %s %s Y %s R %s %s | move %s" % [l.get_is_active(), l.get_vector2("primary"), l.is_button_pressed("by_button"),
			r.get_is_active(), r.get_vector2("primary"),
			Input.get_vector("move_left", "move_right", "move_backwards", "move_forwards")]
	if _out != "":
		_view.get_texture().get_image().save_png("%s/%s" % [_out, file])
	var ms := int(fmod(Time.get_unix_time_from_system(), 1.0) * 1000.0)
	print("persona %s.%03d %s%s grab %s radial %s fps %d %s" % [Time.get_time_string_from_system(), ms,
			lead + " " if lead != "" else "", pose, grab, radial, Engine.get_frames_per_second(), file])


## Each crossing of the stairs' footprint as the feet heights it passed through, one per change.
func _track_stairs(pos: Vector3) -> void:
	var on: bool = pos.x > STAIRS.x0 and pos.x < STAIRS.x1 and pos.z > STAIRS.z0 and pos.z < STAIRS.z1
	if on and not _on_stairs:
		_passes.append([])
	if on and (_passes[-1].is_empty() or absf(_passes[-1][-1] - pos.y) > 1e-4):
		_passes[-1].append(pos.y)
	_on_stairs = on


func _verdict() -> bool:
	_fps.sort()
	var fps_mid: int = _fps[_fps.size() / 2] if not _fps.is_empty() else 0
	print("persona fps: median %d over %d half-second samples%s" % [fps_mid, _fps.size(), " (no station)" if _bare else ""])
	if _bare:
		print("persona RESULT: BASELINE (no station, so no stairs to check)")
		quit(0)
		return true
	var ok := _judge(_passes)
	quit(0 if ok else 1)
	return true


## PASS when there is a pass down falling every frame and a pass up through all six treads and the forecourt.
func _judge(passes: Array) -> bool:
	var down := 0
	var up := 0
	var crossings := 0
	for ys in passes:
		if ys.size() < 2:
			continue
		crossings += 1
		var rising: bool = ys[-1] > ys[0]
		var mono := true
		var treads := {}
		for i in range(1, ys.size()):
			mono = mono and (ys[i] > ys[i - 1] if rising else ys[i] < ys[i - 1])
		for y in ys:
			var k := roundi(y / TREAD)
			if absf(y - k * TREAD) < 0.005:
				treads[k] = true
		var ok: bool = mono and (not rising or range(1, 8).all(func(k): return treads.has(k)))
		up += 1 if rising and ok else 0
		down += 1 if not rising and ok else 0
		print("persona stairs %s: %s %s, %d tread levels hit: %s" % ["up" if rising else "down",
				"monotonic" if mono else "NOT monotonic", "PASS" if ok else "FAIL", treads.size(),
				" ".join(ys.map(func(y): return "%.3f" % y))])
	var ok := up >= 1 and down >= 1 and up + down == crossings
	print("persona RESULT: %s (%d passes down, %d up, each tread %.3f m, about one and a half soda cans tall)" % [
			"PASS" if ok else "FAIL", down, up, TREAD])
	return ok


func _self_test() -> void:
	var climb := [0.0]
	for k in range(1, 8):
		climb.append(k * TREAD)
	var skip := climb.duplicate()
	skip.remove_at(3)
	var dip := climb.duplicate()
	dip.insert(4, 2.5 * TREAD)
	var fall := [1.25, 1.2, 1.0, 0.6, 0.0]
	var cases := [["a fall and a full climb pass", [fall, climb], true], ["control: a climb skipping a tread fails", [fall, skip], false],
			["control: a climb that dips fails", [fall, dip], false], ["control: no climb fails", [fall], false],
			["control: a fall that rises fails", [[1.25, 1.0, 1.1, 0.0], climb], false]]
	var failed := 0
	for c in cases:
		var ok: bool = _judge(c[1]) == c[2]
		print("%s %s" % ["PASS" if ok else "FAIL", c[0]])
		failed += 0 if ok else 1
	print("RESULT: %s" % ("PASS" if failed == 0 else "FAIL"))
	quit(1 if failed else 0)
