# The locomotion gate: the walker on the station's colliders in the MuJoCo guest, headless, at a fixed step.
# PASS when it walks, climbs the forecourt stairs, is refused at a ledge and by the handrail, snap-turns,
# teleports onto ground but not into a solid, and repeats bit for bit. Each control must FAIL:
#   --control=step_high   step height 1.2 m, so the refused ledge is climbed
#   --control=no_resolve  walls are not resolved, so the handrail is walked through
#   --control=solid_land  teleport ignores solids, so a target inside the handrail lands
#   --control=ulp         the repeat run's input moves by one ulp, so the bits differ
#   godot --headless --path . --script tools/gate_locomotion.gd -- [--control=...]
extends SceneTree

const Ctx = preload("res://addons/sakuragaoka_station/core/ctx.gd")
const MODULES := ["environment", "station", "plaza", "sakura"]
const DT := 1.0 / 60.0

var _control := ""
var _failed := 0
var _ctx
var _stage_script: GDScript
var _walker_script: GDScript


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--control="):
			_control = a.substr(10)
	_run.call_deferred()


func _check(name: String, ok: bool, detail: String) -> void:
	print("%s %s: %s" % ["PASS" if ok else "FAIL", name, detail])
	_failed += 0 if ok else 1


func _script(path: String, from: String, to: String) -> GDScript:
	var s := GDScript.new()
	s.source_code = FileAccess.get_file_as_string(path)
	if from != "":
		s.source_code = s.source_code.replace(from, to)
	s.resource_path = ""
	s.reload()
	return s


func _stage():
	var st = _stage_script.new()
	root.add_child(st)
	if st.load_station(_ctx.physics, _ctx.L, 0.3, 1.7) < 0:
		return null
	return st


func _walker(st, x: float, z: float, yaw_deg: float):
	var w = _walker_script.new(st, _ctx.L.WORLD.play)
	w.set_pose(x, z, yaw_deg)
	return w


func _walk(w, seconds: float, move: Vector2) -> void:
	for i in int(round(seconds / DT)):
		w.update(DT, move)


func _run() -> void:
	_ctx = Ctx.new(1)
	for n in MODULES:
		load("res://addons/sakuragaoka_station/world/%s.gd" % n).new().build(_ctx)
	var stage_path := "res://stages/station_physics_stage.gd"
	var walker_path := "res://xr/station_walker.gd"
	_stage_script = load(stage_path)
	_walker_script = load(walker_path)
	if _control == "step_high":
		_walker_script = _script(walker_path, "const STEP_HEIGHT := 0.45", "const STEP_HEIGHT := 1.2")
		_stage_script = _script(stage_path, "const STEP_HEIGHT := 0.45", "const STEP_HEIGHT := 1.2")
	elif _control == "no_resolve":
		_stage_script = _script(stage_path, "func resolve(p: Vector2, feet_y: float) -> Vector2:\n",
				"func resolve(p: Vector2, feet_y: float) -> Vector2:\n\treturn p\n")
	elif _control == "solid_land":
		_stage_script = _script(stage_path, "func resolve(p: Vector2, feet_y: float) -> Vector2:\n",
				"func resolve(p: Vector2, feet_y: float) -> Vector2:\n\treturn p\n")
	var st = _stage()
	if st == null:
		print("RESULT: FAIL (the guest did not load the station)")
		quit(1)
		return

	var h = _ctx.L.HERO
	var w = _walker(st, h.x, h.z, h.yaw)
	var start: Vector3 = w.pos
	_walk(w, 3.0, Vector2(0, 0.9))
	var walked: float = Vector2(w.pos.x - start.x, w.pos.z - start.z).length()
	_check("walk", walked > 8.0 and walked < 10.0, "%.3f m in 3 s at walking speed" % walked)

	# Forecourt stairs (station/building.gd:355): six treads up to the 1.25 m forecourt, west of the handrail.
	w = _walker(st, 1.5, -20.3, 0.0)
	var y0: float = w.pos.y
	_walk(w, 2.0, Vector2(0, 0.9))
	_check("step up", absf(w.pos.y - 1.25) < 0.02 and w.pos.z < -23.0,
			"feet %.3f -> %.3f m at z %.2f (forecourt 1.25 m, each tread about a hand's width up)" % [y0, w.pos.y, w.pos.z])

	# The forecourt's west edge stands 1.25 m above the ground beside it, far over the 0.45 m step.
	w = _walker(st, -5.2, -24.0, -90.0)
	var ledge_y: float = w.pos.y
	_walk(w, 2.0, Vector2(0, 0.9))
	_check("ledge refused", w.pos.y < ledge_y + 0.45 and w.pos.x < -4.0 + 0.05,
			"feet %.3f -> %.3f m, x %.3f (the ledge is at -4.0)" % [ledge_y, w.pos.y, w.pos.x])

	# The handrail down the middle of the stairs is a solid box at x 3.4.
	w = _walker(st, 2.4, -21.8, -90.0)
	_walk(w, 2.0, Vector2(0, 0.9))
	_check("wall stops", w.pos.x < 3.4 - 0.3 + 0.01, "x %.3f after walking into the handrail at 3.4" % w.pos.x)

	w = _walker(st, h.x, h.z, h.yaw)
	var before: Vector3 = w.pos
	var yaw0: float = w.yaw
	w.snap_turn(PI / 6.0)
	_check("snap turn", is_equal_approx(yaw0 - w.yaw, PI / 6.0) and w.pos == before,
			"yaw moved %.4f rad, position unchanged" % (yaw0 - w.yaw))

	var gx: float = h.x
	var gz: float = h.z - 4.0
	var landed: bool = w.teleport(Vector3(gx, st.ground_height(gx, gz, 1e9), gz))
	_check("teleport lands", landed and Vector2(w.pos.x - gx, w.pos.z - gz).length() < 1e-3,
			"onto the plaza 4 m ahead: %s" % landed)
	var into: bool = w.teleport(Vector3(3.4, 0.6, -21.8))
	_check("teleport refused", not into, "into the handrail: %s" % into)

	var a := _trace(PackedFloat64Array([0.0, 0.9]))
	var b_in := PackedFloat64Array([0.0, 0.9])
	if _control == "ulp":
		b_in[1] = 0.9000000000000001
	var b := _trace(b_in)
	_check("repeats bit for bit", a == b, "%d bytes of poses, %s" % [a.size(), "identical" if a == b else "different"])

	print("RESULT: %s (%d FAIL)" % ["PASS" if _failed == 0 else "FAIL", _failed])
	quit(1 if _failed > 0 else 0)


## A fresh stage and walker, 2 s from the hero point; every pose's bytes.
func _trace(input: PackedFloat64Array) -> PackedByteArray:
	var st = _stage()
	var h = _ctx.L.HERO
	var w = _walker(st, h.x, h.z, h.yaw)
	var out := PackedByteArray()
	for i in 120:
		w.update(DT, Vector2(input[0], input[1]))
		out.append_array(var_to_bytes([w.pos.x, w.pos.y, w.pos.z, w.yaw]))
	st.queue_free()
	return out
