# How many suit panel triangles read mirrored: the UV turn of each triangle against its winding.
#   godot --path . --script tools/probe_suit_winding.gd -- [--avatar=foxgirl]
extends SceneTree

func _initialize() -> void:
	var avatar := "foxgirl"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--avatar="):
			avatar = a.substr(9)
	var m: Dictionary = load("res://util/obj_io.gd").read("res://fixtures/%s/avatar.obj" % avatar)
	var r: Dictionary = load("res://util/suit_body.gd").build(m.v, m.f)
	if r.has("error"):
		print("RESULT: FAIL (%s)" % r.error)
		quit(1)
		return
	var a: Array = r.mesh.surface_get_arrays(0)
	var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var pos := 0
	var neg := 0
	var flat := 0
	for i in range(0, idx.size(), 3):
		var p := uv[idx[i]]
		var q := uv[idx[i + 1]]
		var s := uv[idx[i + 2]]
		var area := (q - p).cross(s - p)
		if absf(area) < 1e-12:
			flat += 1
		elif area > 0.0:
			pos += 1
		else:
			neg += 1
	print("%s: %d triangles, UV turn positive %d, negative %d, no area %d" % [avatar, idx.size() / 3, pos, neg, flat])
	print("RESULT: " + ("PASS" if pos == 0 or neg == 0 else "FAIL (mixed)"))
	quit(0 if pos == 0 or neg == 0 else 1)
