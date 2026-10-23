# suit_body -- a body drawn in the ChArUco suit (weftspun RFD 2332), cut into panels the
# way a suit is sewn, so its surface reads: where a garment sits, where it clips, how the
# body turns. Nothing is projected and nothing is mirrored.
#
# tools/suit_udim.py gives the body UVs (fixtures/<avatar>/avatar_suit.obj): xatlas charts
# at the suit's real scale (30 mm squares) in UDIM tiles 1001, 1002, each chart turned to
# read the right way round from outside, then unpacked as V-Sekai/fbx-udim-unpack does: one
# material per tile (usemtl suit_<tile>), UVs in 0..1, texture xr/suit/charuco-suit_<tile>.png.
# Here each tile becomes one surface of the ArrayMesh with its own material.
extends RefCounted

const TILE_TEXTURE := "res://xr/suit/charuco-suit_%s.png"

# The suit mesh for res://fixtures/<avatar>/avatar.obj, or null when it has none (the
# caller then draws the body plain). Its positions are the fixture's own.
static func mesh(avatar_obj: String, tint: Color = Color.WHITE) -> ArrayMesh:
	var path := avatar_obj.get_basename() + "_suit.obj"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("suit_body: no %s (run tools/suit_udim.py); the body is drawn plain" % path)
		return null
	var v := PackedVector3Array()
	var vt := PackedVector2Array()
	var tiles := {} # tile -> PackedInt32Array of [vertex, uv] pairs, three per face
	var cur := ""
	while not f.eof_reached():
		var p := f.get_line().split(" ", false)
		if p.is_empty():
			continue
		match p[0]:
			"v":
				v.append(Vector3(p[1].to_float(), p[2].to_float(), p[3].to_float()))
			"vt":
				vt.append(Vector2(p[1].to_float(), p[2].to_float()))
			"usemtl":
				cur = p[1].trim_prefix("suit_")
				if not tiles.has(cur):
					tiles[cur] = PackedInt32Array()
			"f":
				for k in [1, 3, 2]: # wire winding (CCW outward) -> Godot's
					var ids := p[k].split("/")
					tiles[cur].append_array([ids[0].to_int() - 1, ids[1].to_int() - 1])
	var m := ArrayMesh.new()
	for t in tiles:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var pairs: PackedInt32Array = tiles[t]
		for i in range(0, pairs.size(), 2):
			var uv := vt[pairs[i + 1]]
			st.set_uv(Vector2(uv.x, 1.0 - uv.y)) # the file's v points up, Godot's down
			st.add_vertex(v[pairs[i]])
		st.index()
		st.generate_normals()
		st.commit(m)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.albedo_texture = load(TILE_TEXTURE % t)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		mat.roughness = 1.0
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.surface_set_material(m.get_surface_count() - 1, mat)
		m.surface_set_name(m.get_surface_count() - 1, "suit_" + t)
	return m
