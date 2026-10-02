# xr-grid's world grab in the pen: both grips pinch the canvas (the station and the body) and it
# follows the hands; one grip moves nothing. Headless, the two hand trackers faked through
# XRServer, the station left unbuilt.
#   godot --headless --fixed-fps 60 --path . --script tools/gate_world_grab.gd
# PASS: both hands moved 0.30 m along x carry the canvas 0.30 m (within 5 mm), on a hand's first
# grab and on a later one, and hands pulled from 0.4 m to 0.8 m apart scale it 2x (within 2%);
# with no grip the canvas holds its scene offset. Controls: the same move with one grip leaves
# the canvas where it was (within 1 mm); --control=cold_debounce zeroes the grip debounce
# timers, as upstream xr-grid starts them, and must FAIL on the first grab.
extends SceneTree

const SCENE := "res://xr_main.tscn"
const LEFT := Vector3(-0.2, 1.2, -0.4)
const RIGHT := Vector3(0.2, 1.2, -0.4)

var _main: Node
var _canvas: Node3D
var _left := XRPositionalTracker.new()
var _right := XRPositionalTracker.new()
var _plan: Array = []
var _step := 0
var _frame := 0
var _mark := Transform3D()
var _rest := Transform3D()
var _results := {}


func _initialize() -> void:
	for t in [[_left, &"left_hand", XRPositionalTracker.TRACKER_HAND_LEFT], [_right, &"right_hand",
			XRPositionalTracker.TRACKER_HAND_RIGHT]]:
		t[0].type = XRServer.TRACKER_CONTROLLER
		t[0].name = t[1]
		t[0].hand = t[2]
		XRServer.add_tracker(t[0])
	_main = load(SCENE).instantiate()
	_main.get_node("World/Station").free()
	get_root().add_child(_main)
	_canvas = _main.get_node("World/XROrigin3D/Canvas")
	_canvas.enabled = true
	_rest = _canvas.transform
	var away := Vector3(0.3, 0, 0)
	# [frames, left grip, right grip, left from, left to, right from, right to, what to measure]
	_plan = [
		[30, 0, 0, LEFT, LEFT, RIGHT, RIGHT, "settle"],
		[40, 1, 0, LEFT, LEFT, RIGHT, RIGHT, ""],
		[60, 1, 0, LEFT, LEFT + away, RIGHT, RIGHT + away, ""],
		[60, 1, 0, LEFT + away, LEFT + away, RIGHT + away, RIGHT + away, "one_grip"],
		[30, 0, 0, LEFT, LEFT, RIGHT, RIGHT, "mark"],
		[40, 1, 1, LEFT, LEFT, RIGHT, RIGHT, ""],
		[60, 1, 1, LEFT, LEFT + away, RIGHT, RIGHT + away, ""],
		[60, 1, 1, LEFT + away, LEFT + away, RIGHT + away, RIGHT + away, "first_grab"],
		[30, 0, 0, LEFT, LEFT, RIGHT, RIGHT, "mark"],
		[40, 1, 1, LEFT, LEFT, RIGHT, RIGHT, ""],
		[60, 1, 1, LEFT, LEFT + away, RIGHT, RIGHT + away, ""],
		[60, 1, 1, LEFT + away, LEFT + away, RIGHT + away, RIGHT + away, "move"],
		[30, 0, 0, LEFT, LEFT, RIGHT, RIGHT, "mark"],
		[40, 1, 1, LEFT, LEFT, RIGHT, RIGHT, ""],
		[60, 1, 1, LEFT, LEFT * Vector3(2, 1, 1), RIGHT, RIGHT * Vector3(2, 1, 1), ""],
		[60, 1, 1, LEFT * Vector3(2, 1, 1), LEFT * Vector3(2, 1, 1), RIGHT * Vector3(2, 1, 1), RIGHT * Vector3(2, 1, 1), "scale"],
	]
	_mark = _canvas.transform


func _process(_dt: float) -> bool:
	# After the canvas's _ready, which warms the timers.
	if _step == 0 and _frame == 0 and "--control=cold_debounce" in OS.get_cmdline_user_args():
		_canvas.hand_left_grab_debounce_timer = 0.0
		_canvas.hand_right_grab_debounce_timer = 0.0
	if _step >= _plan.size():
		_finish()
		return true
	var p: Array = _plan[_step]
	var k := float(_frame + 1) / float(p[0])
	_pose(_left, p[3].lerp(p[4], k), p[1])
	_pose(_right, p[5].lerp(p[6], k), p[2])
	_frame += 1
	if _frame >= p[0]:
		_measure(p[7])
		_frame = 0
		_step += 1
	return false


func _pose(t: XRPositionalTracker, at: Vector3, grip: float) -> void:
	t.set_pose(&"default", Transform3D(Basis(), at), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	t.set_input(&"grip", grip)


func _measure(what: String) -> void:
	var now := _canvas.transform
	match what:
		"settle":
			_results.settle = now.origin.distance_to(_rest.origin)
			_mark = now
		"mark":
			_mark = now
		"one_grip":
			_results.one_grip = now.origin.distance_to(_mark.origin)
		"first_grab":
			_results.first_grab = now.origin.x - _mark.origin.x
		"move":
			_results.move = now.origin.x - _mark.origin.x
		"scale":
			_results.scale = now.basis.get_scale().x / _mark.basis.get_scale().x


func _finish() -> void:
	var r := _results
	print("world grab: no grip, canvas %.4f m from its scene offset; one grip, moved %.4f m; first two-hand grab, %.4f m; "
			% [r.get("settle", -1.0), r.get("one_grip", -1.0), r.get("first_grab", -1.0)]
			+ "two-hand grab, %.4f m for 0.30; hands 2x apart, scale %.4f" % [r.get("move", -1.0), r.get("scale", -1.0)])
	var ok: bool = r.get("settle", 1.0) < 0.001 and r.get("one_grip", 1.0) < 0.001 \
			and absf(r.get("first_grab", 0.0) - 0.3) < 0.005 and absf(r.get("move", 0.0) - 0.3) < 0.005 \
			and absf(r.get("scale", 0.0) - 2.0) < 0.04
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
