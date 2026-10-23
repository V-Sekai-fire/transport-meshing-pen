# Renders the FoxGirl body with the suit material from the front quarter and saves a PNG,
# for tools/suit_texture.py --read to count the markers a camera sees.
#
#   godot --path . --resolution 320x180 --xr-mode off --script tools/probe_suit.gd -- \
#     --out=<png> [--avatar=foxgirl] [--plain] [--yaw=20]
#
# --plain draws the body in the old flat skin colour: the control, which shows no marker.
extends SceneTree

const ObjIO := preload("res://util/obj_io.gd")
const XrWorld := preload("res://xr/xr_world.gd")
const SuitBody := preload("res://util/suit_body.gd")

var _args := {}
var _frames := 0
var _vp: SubViewport

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var obj := "res://fixtures/%s/avatar.obj" % _args.get("avatar", "foxgirl")
	var m: Dictionary = ObjIO.read(obj)
	if m.has("error"):
		print("RESULT: FAIL (%s)" % m.error)
		quit(1)
		return
	# Its own viewport, so the frame is 1600 by 1200 whatever the window and stretch settings.
	_vp = SubViewport.new()
	_vp.size = Vector2i(1600, 1200)
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var mi := MeshInstance3D.new()
	var plain := _args.has("plain")
	var suit: ArrayMesh = null if plain else SuitBody.mesh(obj)
	mi.mesh = suit if suit != null else XrWorld._shaded(m.v, m.f)
	if suit == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.85, 0.75, 0.68)
		mi.material_override = mat
	_vp.add_child(mi)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.7, 0.7, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	_vp.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 35.0
	var yaw := deg_to_rad(float(_args.get("yaw", "20")))
	var at := Vector3(0, 1.0, 0)
	_vp.add_child(cam)
	cam.look_at_from_position(at + Vector3(sin(yaw), 0.1, cos(yaw)) * float(_args.get("dist", "3.2")), at, Vector3.UP)
	cam.current = true

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 8:
		return false
	var out: String = _args.get("out", "user://suit.png")
	var err := _vp.get_texture().get_image().save_png(out)
	print("probe_suit: %s %s -> %s" % ["plain" if _args.has("plain") else "suit", error_string(err), out])
	print("RESULT: " + ("PASS" if err == OK else "FAIL"))
	quit(0 if err == OK else 1)
	return true
