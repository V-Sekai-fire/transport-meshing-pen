# Topological face matching for a replayed CASSIE session. A face is its boundary, a set of edges
# "stroke:from:to"; adding faces mod 2 cancels the edges they share. No distance is involved.
extends RefCounted

# A face's boundary as a set of edges "stroke:from:to" with the endpoints ordered; a pair of faces
# that share an edge cancels it when their sets are added mod 2.
static func edge_set(spans: String) -> Dictionary:
	var out := {}
	for tok in spans.strip_edges().split(" ", false):
		var f := tok.split(":")
		if f.size() != 3:
			continue
		var a := float(f[1])
		var b := float(f[2])
		out["%s:%s:%s" % [f[0], f[1], f[2]] if a <= b else "%s:%s:%s" % [f[0], f[2], f[1]]] = true
	return out

static func strokes_of(edges: Dictionary) -> String:
	var ids := {}
	for e in edges:
		ids[int(str(e).get_slice(":", 0))] = true
	var l := ids.keys()
	l.sort()
	return " ".join(l.map(func(v): return str(v)))

# The port faces whose edge sets add mod 2 to a boundary running over exactly the strokes of `key`;
# [] when none do. Choosing faces is a vector x over GF(2). Every edge on a stroke outside the key must
# cancel, which is one linear equation per such edge (an even number of chosen faces carry it). The
# solutions are the null space of that system, found by Gaussian elimination. Their boundaries form a
# space too; the cover is the smallest solution whose boundary touches exactly the key's strokes.
# No limits: the work grows with the null space's dimension, nothing is cut off.
static func cover(key: String, all_faces: Array) -> Array:
	var faces := all_faces.filter(func(f): return f.key != key)  # a face is not its own cover
	var in_key := {}
	for t in key.split(" "):
		in_key[int(t)] = true
	var rows := {}  # outside-key edge -> {face index: true}
	for i in faces.size():
		for e in faces[i].edges:
			if not in_key.has(int(str(e).get_slice(":", 0))):
				if not rows.has(e):
					rows[e] = {}
				rows[e][i] = true
	var pivots := {}  # column -> reduced row (a set of columns, containing the pivot)
	for e in rows:
		var row: Dictionary = rows[e].duplicate()
		var reduced := true
		while reduced:
			reduced = false
			for c in row.keys():
				if pivots.has(c):
					for d in pivots[c]:
						if row.has(d):
							row.erase(d)
						else:
							row[d] = true
					reduced = true
					break
		if row.is_empty():
			continue
		var lead: int = row.keys().min()
		for c in pivots.keys():
			if pivots[c].has(lead):
				for d in row:
					if pivots[c].has(d):
						pivots[c].erase(d)
					else:
						pivots[c][d] = true
		pivots[lead] = row
	var basis := []  # null space vectors, each a set of face indices
	for f in faces.size():
		if pivots.has(f):
			continue
		var x := {f: true}
		for c in pivots:
			if pivots[c].has(f):
				x[c] = true
		basis.append(x)
	var best := []
	var d := basis.size()
	for mask in range(1, 1 << d):
		var x := {}
		for k in d:
			if mask & (1 << k):
				for i in basis[k]:
					if x.has(i):
						x.erase(i)
					else:
						x[i] = true
		if x.is_empty() or (not best.is_empty() and x.size() >= best.size()):
			continue
		var sum := {}
		for i in x:
			for e in faces[i].edges:
				if sum.has(e):
					sum.erase(e)
				else:
					sum[e] = true
		if not sum.is_empty() and strokes_of(sum) == key:
			best = x.keys()
	var names := []
	for i in best:
		names.append(faces[i].key)
	names.sort()
	return names

# expected: stroke-id keys ("8 32 34 66"). port_lines: the replay's face lines, "ids | stroke:from:to ...".
# An expected face the port lacks is covered when port faces add mod 2 to its boundary; a port face
# that is not expected must take part in some cover, or it is unexplained.
static func compare(expected: Array, port_lines: Array) -> Dictionary:
	var faces := []
	var port := {}
	for line in port_lines:
		var parts := str(line).split(" |")
		var key := parts[0].strip_edges()
		port[key] = true
		faces.append({"key": key, "edges": edge_set(parts[1] if parts.size() > 1 else "")})
	var want := {}
	for k in expected:
		want[str(k)] = true
	var covered := {}
	var uncovered := []
	var used := {}
	for k in want:
		if port.has(k):
			continue
		var c := cover(k, faces)
		if c.is_empty():
			uncovered.append(k)
		else:
			covered[k] = c
			for f in c:
				used[f] = true
	var unexplained := []
	for k in port:
		if not want.has(k) and not used.has(k):
			unexplained.append(k)
	return {"covered": covered, "uncovered": uncovered, "unexplained": unexplained}
