# suit_body -- a body drawn in the ChArUco suit (weftspun RFD 2332), cut into panels the
# way a suit is sewn, so its surface reads: where a garment sits, where it clips, how the
# body turns. Nothing is projected.
#
# The panels come from the engine's own xatlas (modules/xatlas_unwrap, through
# ArrayMesh.lightmap_unwrap) at the suit's print scale, PX_PER_M texels a metre. xatlas runs
# with fixWinding there, so every panel's UVs turn the same way as its faces. The unwrap writes
# UV2 in 0..1 of an atlas lightmap_size_hint texels wide; UV1 takes the same layout in sheet
# units, so the 2205 by 2925 px sheet (45 px a 30 mm square, tools/suit_texture.py) lands at its
# real size and repeats past its edge, as UDIM tiles do.
extends RefCounted

const SHEET := "res://xr/suit/charuco-suit.png"
const PX_PER_M := 1500.0

# The suit-panelled mesh of v/f (an OBJ's arrays, as util/obj_io.gd reads them):
# {"mesh": ArrayMesh, "atlas": Vector2i, "ms": unwrap time} or {"error": why}.
static func build(v: PackedFloat32Array, f: PackedInt32Array, tint: Color = Color.WHITE, sheet_path: String = SHEET) -> Dictionary:
	var sheet = load(sheet_path)
	if sheet == null:
		return {"error": "%s did not load (tools/suit_texture.py or tools/suit_multiscale.py writes it)" % sheet_path}
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in v.size() / 3:
		st.add_vertex(Vector3(v[3 * i], v[3 * i + 1], v[3 * i + 2]))
	for i in range(0, f.size(), 3):
		# OBJ faces wind anticlockwise outward; Godot's front faces wind clockwise.
		st.add_index(f[i])
		st.add_index(f[i + 2])
		st.add_index(f[i + 1])
	st.generate_normals()
	var m := st.commit()
	var t0 := Time.get_ticks_msec()
	var err := m.lightmap_unwrap(Transform3D.IDENTITY, 1.0 / PX_PER_M)
	if err != OK:
		return {"error": "lightmap_unwrap: %s (the engine needs modules/xatlas_unwrap)" % error_string(err)}
	var ms := Time.get_ticks_msec() - t0
	var atlas := Vector2(m.lightmap_size_hint)
	var scale := atlas / Vector2(sheet.get_width(), sheet.get_height())
	var a := m.surface_get_arrays(0)
	var uv2: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
	var uv := PackedVector2Array()
	uv.resize(uv2.size())
	for i in uv2.size():
		uv[i] = uv2[i] * scale
	a[Mesh.ARRAY_TEX_UV] = uv
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.albedo_texture = sheet
	mat.texture_repeat = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	out.surface_set_material(0, mat)
	return {"mesh": out, "atlas": Vector2i(atlas), "ms": ms}

# build() for an OBJ path, or null with a warning (the caller then draws the body plain).
static func mesh(avatar_obj: String, tint: Color = Color.WHITE, sheet_path: String = SHEET) -> ArrayMesh:
	var m: Dictionary = load("res://util/obj_io.gd").read(avatar_obj)
	if m.has("error"):
		push_warning("suit_body: " + m.error)
		return null
	var r := build(m.v, m.f, tint, sheet_path)
	if r.has("error"):
		push_warning("suit_body: %s; the body is drawn plain" % r.error)
		return null
	print("[dress-on] suit_body: %s unwrapped in %d ms, atlas %dx%d texels" % [avatar_obj, r.ms, r.atlas.x, r.atlas.y])
	return r.mesh
