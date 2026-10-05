# mujoco_stage -- mujoco.elf: stroke crossings from the engine's capsule
# collision (RFD 2274). Optional: when its ELF is absent or fails to load, the
# pipeline falls back to curvenet's own solve, which is the parallel-commit
# rollback (RFD 2119) -- the stroke still commits, on the predicted points.
extends "res://stages/stage_base.gd"

const REQUIRED := ["mj_crossings", "mjc_load_xml", "mj_push_out"]
const MESH_PIECE_TRIS := 1500

func _init() -> void:
	stage_name = "mujoco"
	open_sandbox("res://mujoco.elf", 1024, 4096, 1 << 24, {}, PackedStringArray(REQUIRED))

# strokes: an Array of PackedVector3Array polylines. Returns the crossing points
# among them (coalesced world midpoints) as a PackedVector3Array. Empty when the
# stage is not loaded, so the caller falls back to the solve.
func crossings(strokes: Array, proximity: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not available():
		return out
	var points := PackedFloat32Array()
	var counts := PackedInt32Array()
	for s in strokes:
		var poly: PackedVector3Array = s
		counts.append(poly.size())
		for v in poly:
			points.append(v.x)
			points.append(v.y)
			points.append(v.z)
	var raw = call_now("mj_crossings", [points, counts, proximity])
	if typeof(raw) != TYPE_PACKED_FLOAT64_ARRAY and typeof(raw) != TYPE_PACKED_FLOAT32_ARRAY:
		return out
	var f := PackedFloat64Array(raw)
	var n := int(f.size() / 3)
	for i in n:
		out.append(Vector3(f[i * 3], f[i * 3 + 1], f[i * 3 + 2]))
	return out

# Loads the triangle mesh at obj_path as the one model, for push(). "" or the error.
func load_body(obj_path: String) -> String:
	if not available():
		return "no mujoco sandbox (%s)" % reason
	var verts: Array[String] = []
	var tris: Array[PackedInt32Array] = []
	for line in FileAccess.get_file_as_string(obj_path).split("\n"):
		var f := line.strip_edges().split(" ", false)
		if f.size() >= 4 and f[0] == "v":
			verts.append("%s %s %s" % [f[1], f[2], f[3]])
		elif f.size() >= 4 and f[0] == "f":
			for k in range(2, f.size() - 1):
				tris.append(PackedInt32Array([int(f[1].split("/")[0]) - 1, int(f[k].split("/")[0]) - 1, int(f[k + 1].split("/")[0]) - 1]))
	if verts.is_empty() or tris.is_empty():
		return "no triangles in %s" % obj_path
	# MuJoCo refuses a mesh attribute past 64 KB, so the body loads as pieces.
	var assets := ""
	var geoms := ""
	var piece := 0
	for start in range(0, tris.size(), MESH_PIECE_TRIS):
		var local := {}
		var pv := PackedStringArray()
		var pf := PackedStringArray()
		for t in tris.slice(start, start + MESH_PIECE_TRIS):
			var ids := PackedStringArray()
			for vi in t:
				if not local.has(vi):
					local[vi] = local.size()
					pv.append(verts[vi])
				ids.append(str(local[vi]))
			pf.append(" ".join(ids))
		assets += "<mesh name='body%d' inertia='shell' vertex='%s' face='%s'/>" % [piece, " ".join(pv), " ".join(pf)]
		geoms += "<geom type='mesh' mesh='body%d'/>" % piece
		piece += 1
	var xml := "<mujoco><option gravity='0 0 0'/><asset>%s</asset><worldbody>%s</worldbody></mujoco>" % [assets, geoms]
	if not bool(call_now("mjc_load_xml", [xml.to_utf8_buffer()])):
		return "mjc_load_xml refused %s" % obj_path
	return ""

# Moves the points inside the loaded body out through its surface along a horizontal
# ray from the vertical axis (axis_x, axis_z), plus thickness; a point inside a nested
# fold exits one surface and may still be inside, so it repeats. {points, moved} or {error}.
func push(points: PackedVector3Array, axis_x: float, axis_z: float, thickness: float) -> Dictionary:
	var pts := PackedFloat64Array()
	for v in points:
		pts.append_array([v.x, v.y, v.z])
	var total := 0
	for _pass in 4:
		var r = call_now("mj_push_out", [pts, axis_x, axis_z, thickness])
		if typeof(r) != TYPE_PACKED_FLOAT64_ARRAY or r.size() != pts.size() + 1:
			return {"error": "mj_push_out: %s" % str(r).left(120)}
		var moved_now := int(r[r.size() - 1])
		total += moved_now
		pts = r.slice(0, pts.size())
		if moved_now == 0:
			break
	var out := PackedVector3Array()
	for k in range(0, pts.size(), 3):
		out.append(Vector3(pts[k], pts[k + 1], pts[k + 2]))
	return {"points": out, "moved": total}
