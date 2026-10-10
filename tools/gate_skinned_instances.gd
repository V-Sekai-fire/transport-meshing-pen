# Gate for realize.gd's skinned instances: every copy bone of every realized instanced set must sit
# at the built copy's world position (o.matrix_world * instance_matrix[i]), and no MultiMesh is
# left. The planted control doubles every instance offset, as MToon did on a MultiMesh, and must fail.
# Copies with an atlas cell (the original's aCell) must keep every UV inside their own cell; the
# planted control reads each copy against the next copy's cell and must fail.
#   godot --path . --resolution 320x180 --xr-mode off --script tools/gate_skinned_instances.gd
extends SceneTree

const TOL := 1e-4
var st


func _initialize() -> void:
	st = load("res://addons/sakuragaoka_station/station.tscn").instantiate()
	st.built.connect(_on_built)
	root.add_child(st)
	create_timer(900.0).timeout.connect(func(): print("RESULT: watchdog"); quit(2))


func _worst(skels: Array, plant: bool) -> Array:
	var worst := 0.0
	var bones := 0
	for sk: Skeleton3D in skels:
		var o = sk.get_meta("station_source")
		for i in o.count:
			var want: Vector3 = o.matrix_world * o.instance_matrix[i].origin
			var pose := sk.get_bone_global_pose(i + 1)
			if plant:
				pose.origin *= 2.0
			var got: Vector3 = sk.global_transform * pose.origin
			worst = maxf(worst, got.distance_to(want))
			bones += 1
	return [worst, bones]


## [copies checked, copies with a UV outside the cell] over every skeleton whose source has aCell.
func _cells(skels: Array, plant: bool) -> Array:
	var checked := 0
	var bad := 0
	for sk: Skeleton3D in skels:
		var o = sk.get_meta("station_source")
		var m = o.materials()[0]
		if not o.user_data.has("aCell") or m == null or not m.user_data.has("uCell"):
			continue
		var mi: MeshInstance3D = sk.get_child(0)
		var a := mi.mesh.surface_get_arrays(0)
		if a[Mesh.ARRAY_TEX_UV] == null:
			continue
		var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
		var n: int = uv.size() / o.count
		var cs: Vector2 = m.user_data["uCell"]
		for c in o.count:
			var k: int = (c + 1) % o.count if plant else c
			var off := Vector2(o.user_data["aCell"][k].x, o.user_data["aCell"][k].y)
			var rect := Rect2(off - Vector2(1e-4, 1e-4), cs + Vector2(2e-4, 2e-4))
			for i in n:
				if not rect.has_point(uv[c * n + i]):
					bad += 1
					break
			checked += 1
	return [checked, bad]


func _on_built(stats: Dictionary) -> void:
	var skels: Array = st.get_children().filter(func(n): return n is Skeleton3D and n.has_meta("station_source"))
	var mms: int = st.get_children().filter(func(n): return n is MultiMeshInstance3D).size()
	var ok := true
	var ran := 0
	var shape_ok: bool = skels.size() == stats.instanced and skels.size() > 0 and mms == 0
	print("%s  instanced sets: %d skeletons realized, %d MultiMeshes left (stats.instanced %d)" % [
		"PASS" if shape_ok else "FAIL", skels.size(), mms, stats.instanced])
	ok = ok and shape_ok
	ran += 1
	var a := _worst(skels, false)
	print("%s  every bone at its built copy: worst %.9f m over %d bones" % ["PASS" if a[0] <= TOL and a[1] > 0 else "FAIL", a[0], a[1]])
	ok = ok and a[0] <= TOL and a[1] > 0
	ran += 1
	var b := _worst(skels, true)
	print("%s  planted: doubled offsets are caught (worst %.2f m)" % ["PASS" if b[0] > TOL else "FAIL", b[0]])
	ok = ok and b[0] > TOL
	ran += 1
	var cc := _cells(skels, false)
	print("%s  every atlas copy inside its cell: %d of %d copies outside" % ["PASS" if cc[0] > 0 and cc[1] == 0 else "FAIL", cc[1], cc[0]])
	ok = ok and cc[0] > 0 and cc[1] == 0
	ran += 1
	var cp := _cells(skels, true)
	print("%s  planted: copies read against the next cell are caught (%d of %d)" % ["PASS" if cp[1] > 0 else "FAIL", cp[1], cp[0]])
	ok = ok and cp[1] > 0
	ran += 1
	var have: bool = ProjectSettings.has_setting("shader_globals/ramp_sun_dir") and ProjectSettings.has_setting("shader_globals/ramp_sun_color")
	print("%s  the sakura toon ramp's shader globals are declared" % ["PASS" if have else "FAIL"])
	ok = ok and have
	ran += 1
	var planted: bool = ProjectSettings.has_setting("shader_globals/ramp_sun_dir_planted")
	print("%s  planted: an undeclared global is reported missing" % ["PASS" if not planted else "FAIL"])
	ok = ok and not planted
	ran += 1
	ok = ok and ran == 7
	print("stats: %s" % JSON.stringify(stats))
	print("RESULT: %s (%d of 7 checks ran)" % ["PASS" if ok else "FAIL", ran])
	quit(0 if ok else 1)
