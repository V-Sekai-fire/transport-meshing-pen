# xr-grid's world grab on film: two scripted hands pinch the world, pull it close, roll it through a
# full turn, shrink it to a 1/64 model, set it down and spin it. The grab moves the viewer by its inverse,
# so the world and its sun stay put and shadows keep their scale.
#   godot --path . --xr-mode off --write-movie grab.avi --fixed-fps 30 --script tools/world_grab_movie.gd
extends SceneTree

const MID := Vector3(0.0, 1.25, -0.45)

var _scene: Node
var _station: Node3D
var _canvas: Node3D
var _left := XRPositionalTracker.new()
var _right := XRPositionalTracker.new()
var _marks: Array = []
var _cam := Camera3D.new()
var _rig := Node3D.new()
var _cam_rest := Transform3D()
var _body: Node3D
var _body_rest := Transform3D()
var _plan: Array = []
var _f := -1
var _origin := Transform3D()
var _canvas_rest := Transform3D()
var _station_rest := Transform3D()
var _t0 := Time.get_ticks_msec()
var _pose := {"mid": MID, "half": 0.3, "roll": 0.0, "yaw": 0.0}


func _initialize() -> void:
	for t in [[_left, &"left_hand", XRPositionalTracker.TRACKER_HAND_LEFT], [_right, &"right_hand",
			XRPositionalTracker.TRACKER_HAND_RIGHT]]:
		t[0].type = XRServer.TRACKER_CONTROLLER
		t[0].name = t[1]
		t[0].hand = t[2]
		XRServer.add_tracker(t[0])
	_scene = load("res://xr_main.tscn").instantiate()
	_station = _scene.get_node("World/Station")
	get_root().add_child(_scene)
	_hold(30)
	_grab(45, {"mid": MID + Vector3(0.0, 0.0, 0.3)})
	for i in 3:
		_grab(50, {"roll": 60.0})
	for i in 3:
		_grab(50, {"roll": 60.0})
	for i in 3:
		_grab(60, {"half": 0.075})
	_grab(45, {"mid": MID + Vector3(0.0, -0.35, -0.1)})
	for i in 4:
		_grab(45, {"yaw": 90.0})
	_hold(60)
	_apply(_pose)


func _hold(n: int) -> void:
	_plan.append({"n": n, "from": _pose.duplicate(), "to": _pose.duplicate(), "grip": 0.0})


func _grab(n: int, change: Dictionary, half := 0.3) -> void:
	var start := {"mid": MID, "half": half, "roll": 0.0, "yaw": 0.0}
	var end := start.duplicate()
	end.merge(change, true)
	_plan.append({"n": 15, "from": _pose.duplicate(), "to": start, "grip": 0.0})
	_plan.append({"n": 25, "from": start, "to": start, "grip": 1.0})
	_plan.append({"n": n, "from": start, "to": end, "grip": 1.0})
	_plan.append({"n": 15, "from": end, "to": end, "grip": 0.0})
	_pose = end


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
		_body = _canvas.get_node("Body")
		_body_rest = _body.global_transform
		get_root().add_child(_rig)
		_rig.global_transform = _origin
		for c in [Color(0.3, 0.6, 1.0), Color(1.0, 0.45, 0.3)]:
			var m := MeshInstance3D.new()
			var s := SphereMesh.new()
			s.radius = 0.035
			s.height = 0.07
			var mat := StandardMaterial3D.new()
			mat.albedo_color = c
			mat.emission_enabled = true
			mat.emission = c
			s.material = mat
			m.mesh = s
			_rig.add_child(m)
			_marks.append(m)
		_cam.fov = 75.0
		_cam.near = 0.02
		_cam.far = 2500.0
		get_root().add_child(_cam)
		_cam.global_transform = _origin * Transform3D(Basis.from_euler(Vector3(deg_to_rad(-25.0), 0.0, 0.0)), Vector3(0.0, 1.6, 0.0))
		_cam_rest = _cam.global_transform
		_cam.make_current()
		_pose = {"mid": MID, "half": 0.3, "roll": 0.0, "yaw": 0.0}
		_f = 0
		print("world_grab_movie: station built, filming from the plaza")
		return false
	var k := _f
	for seg in _plan:
		if k < int(seg.n):
			var a: float = smoothstep(0.0, 1.0, float(k) / seg.n)
			_apply({"mid": seg.from.mid.lerp(seg.to.mid, a), "half": lerpf(seg.from.half, seg.to.half, a),
					"roll": lerpf(seg.from.roll, seg.to.roll, a), "yaw": lerpf(seg.from.yaw, seg.to.yaw, a)}, seg.grip)
			break
		k -= int(seg.n)
	var d: Transform3D = _canvas.transform * _canvas_rest.affine_inverse()
	var v: Transform3D = _origin * d.affine_inverse() * _origin.affine_inverse()
	_rig.global_transform = v * _origin
	var c: Transform3D = v * _cam_rest
	_cam.global_transform = Transform3D(c.basis.orthonormalized(), c.origin)
	_body.global_transform = _body_rest
	if _f >= _frames():
		print("RESULT: PASS (%d frames, world scale %.3f, basis %s, origin %s)" % [_f, d.basis.get_scale().x,
				str(d.basis.orthonormalized().get_euler(EULER_ORDER_YXZ) * 180.0 / PI), str(d.origin)])
		quit(0)
		return true
	_f += 1
	return false


func _frames() -> int:
	var n := 0
	for seg in _plan:
		n += int(seg.n)
	return n


func _apply(p: Dictionary, grip := 0.0) -> void:
	var b := Basis.from_euler(Vector3(0.0, deg_to_rad(p.yaw), deg_to_rad(p.roll)), EULER_ORDER_YXZ)
	var off: Vector3 = b * Vector3(p.half, 0.0, 0.0)
	var hands := [[_left, p.mid - off], [_right, p.mid + off]]
	for i in hands.size():
		hands[i][0].set_pose(&"default", Transform3D(Basis(), hands[i][1]), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		hands[i][0].set_input(&"grip", grip)
		if i < _marks.size():
			_marks[i].position = hands[i][1]
			_marks[i].scale = Vector3.ONE * (1.4 if grip > 0.0 else 1.0)
