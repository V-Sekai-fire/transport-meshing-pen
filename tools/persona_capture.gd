# Runs xr_main and, every half second, logs the visitor's station pose, world grab and frame rate, and saves
# what the head camera sees through a mirror SubViewport (the XR viewport's own texture is the headset's).
#   godot --path . --xr-mode on -s tools/persona_capture.gd -- --out=<dir>
extends SceneTree

var _main: Node
var _out := ""
var _cam := Camera3D.new()
var _view := SubViewport.new()
var _next := 2.0
var _t := 0.0
var _n := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	_main = load("res://xr_main.tscn").instantiate()
	get_root().add_child(_main)
	_view.size = Vector2i(960, 540)
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.add_child(_cam)
	get_root().add_child(_view)
	_view.world_3d = get_root().world_3d


func _process(dt: float) -> bool:
	_t += dt
	var xr: Node3D = _main.get_node("World/XROrigin3D/XRCamera3D")
	_cam.global_transform = xr.global_transform
	_cam.fov = 90.0
	if _t < _next:
		return false
	_next += 0.5
	var p = _main.get_node("World/StationPlayer")
	var grab: bool = _main.get_node("World/XROrigin3D/Canvas").enabled
	var radial: bool = _main.get_node("World/Radial").visible
	var pose := "no walker"
	if p.walker != null:
		pose = "x %.2f z %.2f feet %.3f yaw %.1f" % [p.walker.pos.x, p.walker.pos.z, p.walker.pos.y, rad_to_deg(p.walker.yaw)]
	var l: XRController3D = _main.get_node("World/XROrigin3D/hand_left")
	var r: XRController3D = _main.get_node("World/XROrigin3D/hand_right")
	pose += " | L %s %s Y %s R %s %s | move %s" % [l.get_is_active(), l.get_vector2("primary"), l.is_button_pressed("by_button"),
			r.get_is_active(), r.get_vector2("primary"),
			Input.get_vector("move_left", "move_right", "move_backwards", "move_forwards")]
	var name := "%s/frame-%03d.png" % [_out, _n]
	if _out != "":
		_view.get_texture().get_image().save_png(name)
	print("persona %s %s grab %s radial %s fps %d %s" % [Time.get_time_string_from_system(), pose, grab, radial,
			Engine.get_frames_per_second(), name.get_file()])
	_n += 1
	return false
