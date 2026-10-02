# A world-grab clip: the visitor stands on the plaza, two scripted hand pinches turn the whole world
# about them and a last one shrinks it to a model, filmed from a fixed viewer camera.
#   godot --path . --xr-mode off --write-movie grab.avi --fixed-fps 30 --resolution 1920x1080 \
#       --script tools/world_grab_movie.gd
extends SceneTree

const HAND_Y := 1.2
const HAND_Z := -0.4
const TURNS := 6
const TURN := 30.0

var _scene: Node
var _station: Node3D
var _canvas: Node3D
var _left := XRPositionalTracker.new()
var _right := XRPositionalTracker.new()
var _cam := Camera3D.new()
var _plan: Array = []
var _f := -1
var _origin := Transform3D()
var _canvas_rest := Transform3D()
var _station_rest := Transform3D()
var _t0 := Time.get_ticks_msec()


func _initialize() -> void:
	for t in [[_left, &"left_hand", XRPositionalTracker.TRACKER_HAND_LEFT], [_right, &"right_hand",
			XRPositionalTracker.TRACKER_HAND_RIGHT]]:
		t[0].type = XRServer.TRACKER_CONTROLLER
		t[0].name = t[1]
		t[0].hand = t[2]
		XRServer.add_tracker(t[0])
	_hands(0.4, 0.0, 0.0)
	_scene = load("res://xr_main.tscn").instantiate()
	_station = _scene.get_node("World/Station")
	get_root().add_child(_scene)
	for i in TURNS:
		_plan.append([30, 0.4, 0.0, 0.4, 0.0, 0.0])
		_plan.append([20, 0.4, 0.0, 0.4, 0.0, 1.0])
		_plan.append([45, 0.4, 0.0, 0.4, TURN, 1.0])
		_plan.append([10, 0.4, TURN, 0.4, TURN, 0.0])
		_plan.append([15, 0.4, TURN, 0.4, 0.0, 0.0])
	_plan.append([30, 0.4, 0.0, 0.4, 0.0, 0.0])
	_plan.append([20, 0.4, 0.0, 0.4, 0.0, 1.0])
	_plan.append([75, 0.4, 0.0, 0.1, 45.0, 1.0])
	_plan.append([10, 0.1, 45.0, 0.1, 45.0, 0.0])
	_plan.append([90, 0.4, 0.0, 0.4, 0.0, 0.0])


func _process(_dt: float) -> bool:
	if Time.get_ticks_msec() - _t0 > 600000:
		print("RESULT: FAIL (no clip in 600 s)")
		quit(1)
		return true
	if _f < 0:
		var p = _scene.get_node("World/StationPlayer")
		if p.walker == null:
			return false
		var origin: Node3D = _scene.get_node("World/XROrigin3D")
		origin.global_transform = _station.global_transform * p.walker.origin()
		p.process_mode = Node.PROCESS_MODE_DISABLED
		_origin = origin.global_transform
		_canvas = _scene.get_node("World/XROrigin3D/Canvas")
		_canvas.enabled = true
		_canvas_rest = _canvas.transform
		_station_rest = _station.global_transform
		_cam.fov = 70.0
		_cam.far = 2500.0
		get_root().add_child(_cam)
		_cam.global_transform = _origin * Transform3D(Basis.from_euler(Vector3(deg_to_rad(-10.0), 0.0, 0.0)), Vector3(0.0, 1.6, 0.0))
		_cam.make_current()
		_f = 0
		print("world_grab_movie: station built, filming from the plaza")
		return false
	var k := _f
	for seg in _plan:
		if k < int(seg[0]):
			var a: float = float(k) / seg[0]
			_hands(lerpf(seg[1], seg[3], a), lerpf(seg[2], seg[4], a), seg[5])
			break
		k -= int(seg[0])
	if _f >= _frames():
		var d: Transform3D = _canvas.transform * _canvas_rest.affine_inverse()
		print("RESULT: PASS (%d frames, world scale %.3f, yaw %.1f deg)" % [_f, d.basis.get_scale().x,
				rad_to_deg(d.basis.orthonormalized().get_euler().y)])
		quit(0)
		return true
	var d: Transform3D = _canvas.transform * _canvas_rest.affine_inverse()
	_station.global_transform = _origin * d * _origin.affine_inverse() * _station_rest
	_f += 1
	return false


func _frames() -> int:
	var n := 0
	for seg in _plan:
		n += int(seg[0])
	return n


func _hands(half: float, turn_deg: float, grip: float) -> void:
	var mid := Vector3(0.0, HAND_Y, HAND_Z)
	var off := Vector3(half, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(turn_deg))
	for t in [[_left, mid - off], [_right, mid + off]]:
		t[0].set_pose(&"default", Transform3D(Basis(), t[1]), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		t[0].set_input(&"grip", grip)
