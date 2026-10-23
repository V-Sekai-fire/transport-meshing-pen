# garment_checks -- what MESH measures of a drawn garment beyond its shell (RFD 3010).
#
#   panels   every cycle the strokes close has a patch, and every patch has triangles
#   cover    every drawn stroke point lies on the garment (within reach metres of a
#            triangle), so a panel the strokes enclose and the mesh lacks shows by name
#   inside   no garment vertex lies inside the body, by generalized winding number
#            (the avatar mesh is not watertight, so ray parity would not do)
#
# Each returns {ok, why, ...}; why names the patch, the stroke or the vertex.
extends RefCounted

static func panels(cycles: int, patch_points: Array, v: PackedFloat32Array, f: PackedInt32Array) -> Dictionary:
	var per := shell_triangles_per_patch(patch_points, v, f)
	var empty := []
	for i in per.size():
		if per[i] <= 0:
			empty.append(i)
	var counts := str(Array(per))
	if cycles < 1:
		return {"ok": false, "why": "no cycle closed (cycles %d)" % cycles}
	if per.size() != cycles:
		return {"ok": false, "why": "%d cycles but %d patches, shell triangles per patch %s" % [cycles, per.size(), counts]}
	if not empty.is_empty():
		return {"ok": false, "why": "patch %s has no triangles in the shell; shell triangles per patch %s" % [
				", ".join(empty.map(func(i): return str(i))), counts]}
	return {"ok": true, "why": "%d cycles, %d patches, shell triangles per patch %s" % [cycles, per.size(), counts]}

# Each shell triangle counted for the patch whose vertex is nearest its centroid
# (the remesh drops curvenet's per-triangle patch ids).
static func shell_triangles_per_patch(patch_points: Array, v: PackedFloat32Array, f: PackedInt32Array) -> PackedInt32Array:
	var per := PackedInt32Array()
	per.resize(patch_points.size())
	if patch_points.is_empty():
		return per
	for t in range(0, f.size(), 3):
		per[nearest_patch(patch_points, (_v(v, f[t]) + _v(v, f[t + 1]) + _v(v, f[t + 2])) / 3.0)] += 1
	return per

static func nearest_patch(patch_points: Array, p: Vector3) -> int:
	var best := INF
	var at := 0
	for k in patch_points.size():
		var pv: PackedFloat32Array = patch_points[k]
		for i in pv.size() / 3:
			var d := p.distance_squared_to(_v(pv, i))
			if d < best:
				best = d
				at = k
	return at

# Control: the shell without the triangles nearest patch k (a panel the strokes
# close and the mesh lacks).
static func drop_patch(patch_points: Array, k: int, f: PackedInt32Array, v: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for t in range(0, f.size(), 3):
		if nearest_patch(patch_points, (_v(v, f[t]) + _v(v, f[t + 1]) + _v(v, f[t + 2])) / 3.0) != k:
			out.append_array([f[t], f[t + 1], f[t + 2]])
	return out

# strokes: [{name, points: PackedVector3Array}], in the garment's frame.
static func cover(strokes: Array, v: PackedFloat32Array, f: PackedInt32Array, reach: float) -> Dictionary:
	var tris := _tris(v, f)
	var worst := 0.0
	var worst_at := ""
	var off := []
	var points := 0
	for s in strokes:
		var miss := 0
		var pts: PackedVector3Array = s.points
		for p in pts:
			points += 1
			var d := _distance(p, tris)
			if d > worst:
				worst = d
				worst_at = "%s %s" % [s.name, str(p)]
			if d > reach:
				miss += 1
		if miss > 0:
			off.append("%s %d of %d points" % [s.name, miss, pts.size()])
	var why := "%d stroke points, farthest %.4f m (%s), reach %.4f m" % [points, worst, worst_at, reach]
	if points == 0:
		return {"ok": false, "why": "no stroke points to check", "worst": worst}
	if not off.is_empty():
		return {"ok": false, "why": "strokes off the mesh: %s; %s" % ["; ".join(off), why], "worst": worst}
	return {"ok": true, "why": why, "worst": worst}

static func inside(v: PackedFloat32Array, body_v: PackedFloat32Array, body_f: PackedInt32Array) -> Dictionary:
	var a := PackedVector3Array()
	var b := PackedVector3Array()
	var c := PackedVector3Array()
	for i in range(0, body_f.size(), 3):
		a.append(_v(body_v, body_f[i]))
		b.append(_v(body_v, body_f[i + 1]))
		c.append(_v(body_v, body_f[i + 2]))
	var bad := []
	var top := 0.0
	for i in v.size() / 3:
		var w := winding(_v(v, i), a, b, c)
		top = maxf(top, w)
		if w > 0.5:
			bad.append(i)
	var why := "%d garment vertices against %d body triangles, largest winding number %.3f" % [v.size() / 3, a.size(), top]
	if a.is_empty():
		return {"ok": false, "why": "no body triangles"}
	if v.size() < 3:
		return {"ok": false, "why": "no garment vertices to check"}
	if not bad.is_empty():
		return {"ok": false, "why": "%d vertices inside the body, first %s at %s; %s" % [bad.size(), str(bad[0]),
				str(_v(v, bad[0])), why], "inside": bad.size()}
	return {"ok": true, "why": why, "inside": 0}

# Solid angle of every triangle seen from p (Van Oosterom and Strackee), over 4 pi.
static func winding(p: Vector3, a: PackedVector3Array, b: PackedVector3Array, c: PackedVector3Array) -> float:
	var w := 0.0
	for i in a.size():
		var x := a[i] - p
		var y := b[i] - p
		var z := c[i] - p
		var lx := x.length()
		var ly := y.length()
		var lz := z.length()
		w += atan2(x.dot(y.cross(z)), lx * ly * lz + x.dot(y) * lz + y.dot(z) * lx + z.dot(x) * ly)
	return w / (2.0 * PI)

static func _v(v: PackedFloat32Array, i: int) -> Vector3:
	return Vector3(v[3 * i], v[3 * i + 1], v[3 * i + 2])

static func _tris(v: PackedFloat32Array, f: PackedInt32Array) -> PackedVector3Array:
	var t := PackedVector3Array()
	for k in f:
		t.append(_v(v, k))
	return t

static func _distance(p: Vector3, tris: PackedVector3Array) -> float:
	var best := INF
	for i in range(0, tris.size(), 3):
		best = minf(best, p.distance_to(_closest(p, tris[i], tris[i + 1], tris[i + 2])))
	return best

# Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
static func _closest(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var den := 1.0 / (va + vb + vc)
	return a + ab * (vb * den) + ac * (vc * den)
