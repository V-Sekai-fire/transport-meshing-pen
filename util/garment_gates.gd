# garment_gates -- dev.4's two mesh checks (RFD66606-3010 gates 1 and 2).
# Gate 1: every cycle the strokes enclose has a patch, and every patch has triangles.
# Gate 2: no garment vertex lies inside the body mesh, by generalized winding number.
# Triangles are index triples (util/mesh_wire.gd's format), vertices flat xyz.

# Gate 1. tris_per_patch[i] is patch i's triangle count. "" when it passes.
static func every_panel(cycles: int, tris_per_patch: PackedInt32Array) -> String:
	if cycles <= 0:
		return "every panel: no cycle enclosed (cycles %d)" % cycles
	if tris_per_patch.size() != cycles:
		return "every panel: %d cycles but %d patches" % [cycles, tris_per_patch.size()]
	var empty := PackedStringArray()
	for i in tris_per_patch.size():
		if tris_per_patch[i] <= 0:
			empty.append(str(i))
	if not empty.is_empty():
		return "every panel: patch %s has no triangles" % ", ".join(empty)
	return ""

# Gate 2. Indices of garment vertices whose winding number against the body is above 0.5.
static func inside(gv: PackedFloat32Array, bv: PackedFloat32Array, bf: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var box := _aabb(bv)
	for i in gv.size() / 3:
		var p := Vector3(gv[3 * i], gv[3 * i + 1], gv[3 * i + 2])
		if box.has_point(p) and absf(winding(p, bv, bf)) > 0.5:
			out.append(i)
	return out

static func nothing_inside(gv: PackedFloat32Array, bv: PackedFloat32Array, bf: PackedInt32Array) -> String:
	if bf.is_empty():
		return "nothing inside: no body mesh to test against"
	var hits := inside(gv, bv, bf)
	if hits.is_empty():
		return ""
	return "nothing inside: %d of %d garment vertices inside the body (first %s)" % [hits.size(), gv.size() / 3,
			str(Array(hits.slice(0, 5)))]

# Generalized winding number of p against a closed triangle mesh (van Oosterom and Strackee):
# 1 inside, 0 outside, near 0.5 on the surface.
static func winding(p: Vector3, bv: PackedFloat32Array, bf: PackedInt32Array) -> float:
	var total := 0.0
	for t in bf.size() / 3:
		var a := Vector3(bv[3 * bf[3 * t]], bv[3 * bf[3 * t] + 1], bv[3 * bf[3 * t] + 2]) - p
		var b := Vector3(bv[3 * bf[3 * t + 1]], bv[3 * bf[3 * t + 1] + 1], bv[3 * bf[3 * t + 1] + 2]) - p
		var c := Vector3(bv[3 * bf[3 * t + 2]], bv[3 * bf[3 * t + 2] + 1], bv[3 * bf[3 * t + 2] + 2]) - p
		var la := a.length()
		var lb := b.length()
		var lc := c.length()
		var num := a.dot(b.cross(c))
		var den := la * lb * lc + a.dot(b) * lc + b.dot(c) * la + c.dot(a) * lb
		total += 2.0 * atan2(num, den)
	return total / (4.0 * PI)

# A point inside the body for the plant_inside control: the body centroid, or [] when it is not inside.
static func inside_point(bv: PackedFloat32Array, bf: PackedInt32Array) -> PackedFloat32Array:
	if bv.is_empty() or bf.is_empty():
		return PackedFloat32Array()
	var c := Vector3.ZERO
	for i in bv.size() / 3:
		c += Vector3(bv[3 * i], bv[3 * i + 1], bv[3 * i + 2])
	c /= float(bv.size() / 3)
	if absf(winding(c, bv, bf)) <= 0.5:
		return PackedFloat32Array()
	return PackedFloat32Array([c.x, c.y, c.z])

static func _aabb(bv: PackedFloat32Array) -> AABB:
	var box := AABB(Vector3(bv[0], bv[1], bv[2]), Vector3.ZERO)
	for i in bv.size() / 3:
		box = box.expand(Vector3(bv[3 * i], bv[3 * i + 1], bv[3 * i + 2]))
	return box
