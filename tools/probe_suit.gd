# Renders the FoxGirl body with the suit material from the front quarter and saves a PNG,
# for tools/suit_texture.py --read to count the markers a camera sees.
#
#   godot --path . --resolution 320x180 --xr-mode off --script tools/probe_suit.gd -- \
#     --out=<png> [--avatar=foxgirl] [--plain] [--yaw=20] [--dist=3.2] [--truth=<png>]
#     [--sheet=res://xr/suit/<png>] [--w=1600 --h=1200] [--fov=35] [--cam_y=<m>]
# --cam_y puts the camera at that height looking at the hips, as a mount on a lighthouse stand.
#
# --truth also renders the same view with each pixel's suit square in place of the suit: red
# (col * 5 + 2) / 255, green (row * 3 + 1.5) / 255 of the 49 by 65 sheet, blue 255 on the body
# and 0 off it. tools/suit_texture.py --read <png> --truth <png> checks each marker read is the
# one the UV map puts there.
# --plain draws the body in the old flat skin colour: the control, which shows no marker.
extends SceneTree

const ObjIO := preload("res://util/obj_io.gd")
const XrWorld := preload("res://xr/xr_world.gd")
const SuitBody := preload("res://util/suit_body.gd")

var _args := {}
var _frames := 0
var _vp: SubViewport
var _mi: MeshInstance3D
var _env: WorldEnvironment
var _truth_frames := -1

# The square under each pixel, unlit. The viewport turns linear output into sRGB, so the code is
# written as the linear value that comes out as the wanted byte.
const TRUTH := """shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;
vec3 lin(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
void fragment() {
	vec2 s = floor(fract(UV) * vec2(49.0, 65.0));
	ALBEDO = lin(vec3((s.x * 5.0 + 2.0) / 255.0, (s.y * 3.0 + 1.5) / 255.0, 1.0));
}
"""

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
	_vp.size = Vector2i(int(_args.get("w", "1600")), int(_args.get("h", "1200")))
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var mi := MeshInstance3D.new()
	_mi = mi
	var plain := _args.has("plain")
	var suit: ArrayMesh = null if plain else SuitBody.mesh(obj, Color.WHITE, _args.get("sheet", SuitBody.SHEET))
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
	_env = env
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	_vp.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = float(_args.get("fov", "35"))
	var yaw := deg_to_rad(float(_args.get("yaw", "20")))
	var at := Vector3(0, 1.0, 0)
	_vp.add_child(cam)
	var dist := float(_args.get("dist", "3.2"))
	var eye := at + Vector3(sin(yaw), 0.1, cos(yaw)) * dist
	if _args.has("cam_y"):
		eye = Vector3(sin(yaw) * dist, float(_args.cam_y), cos(yaw) * dist)
	cam.look_at_from_position(eye, at, Vector3.UP)
	cam.current = true

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 8:
		return false
	if _truth_frames >= 0:
		_truth_frames += 1
		if _truth_frames < 8:
			return false
		var terr := _vp.get_texture().get_image().save_png(_args.truth)
		print("probe_suit: truth %s -> %s" % [error_string(terr), _args.truth])
		print("RESULT: " + ("PASS" if terr == OK else "FAIL"))
		quit(0 if terr == OK else 1)
		return true
	var out: String = _args.get("out", "user://suit.png")
	var err := _vp.get_texture().get_image().save_png(out)
	if err == OK and _args.has("truth") and not _args.has("plain"):
		var sm := ShaderMaterial.new()
		sm.shader = Shader.new()
		sm.shader.code = TRUTH
		_mi.material_override = sm
		_env.environment.background_color = Color.BLACK
		_env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_truth_frames = 0
		print("probe_suit: suit %s -> %s" % [error_string(err), out])
		return false
	print("probe_suit: %s %s -> %s" % ["plain" if _args.has("plain") else "suit", error_string(err), out])
	print("RESULT: " + ("PASS" if err == OK else "FAIL"))
	quit(0 if err == OK else 1)
	return true
