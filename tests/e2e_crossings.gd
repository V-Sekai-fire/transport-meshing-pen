extends SceneTree
## Vehicle D end-to-end: the pen loop's two guests together. curvenet.elf stages
## each crossing_split stroke, mujoco.elf finds the crossings from all authored
## polylines, and pen_end_with_crossings splits the graph at them. Asserts the
## curvenet topology (9 edges / 9 nodes) that crossing_split's own solve gives,
## proving the injected path reaches the same graph through the real guests.

const PROX := 0.02

func _mk(program: String, allocs: int):
	var sb = ClassDB.instantiate("Sandbox")
	if sb == null: return null
	sb.set("program", load(program))
	sb.set_memory_max(1024); sb.set_allocations_max(allocs)
	sb.set_unboxed_arguments(true)
	return sb

func _seg(a: Vector3, b: Vector3, n: int) -> Array:
	var p := []
	for i in range(n + 1): p.push_back(a.lerp(b, float(i) / float(n)))
	return p

func _mj_crossings(mj, polys: Array) -> PackedFloat32Array:
	var points := PackedFloat32Array(); var counts := PackedInt32Array()
	for poly in polys:
		counts.append((poly as Array).size())
		for v in poly:
			points.append(v.x); points.append(v.y); points.append(v.z)
	var raw = mj.vmcall("mj_crossings", points, counts, PROX)
	var flat := PackedFloat32Array()
	if typeof(raw) == TYPE_PACKED_FLOAT64_ARRAY or typeof(raw) == TYPE_PACKED_FLOAT32_ARRAY:
		var f := PackedFloat64Array(raw)
		for x in f: flat.append(x)
	return flat

func _kv(report: String, key: String) -> int:
	for tok in report.split(" "):
		if tok.begins_with(key + "="): return int(tok.get_slice("=", 1))
	return -1

func _init() -> void:
	var cn = _mk("res://curvenet.elf", 4000000)
	var mj = _mk("res://mujoco.elf", 1 << 21)
	if cn == null or mj == null: print("FAIL e2e: Sandbox class missing"); quit(1); return
	cn.vmcall("cn_reset")
	var strokes := [
		_seg(Vector3(-1.2, 0, 0), Vector3(1.2, 0, 0), 16),
		_seg(Vector3(1.1, -0.3, 0), Vector3(-0.2, 1.8, 0), 16),
		_seg(Vector3(0.2, 1.8, 0), Vector3(-1.1, -0.3, 0), 16)]
	var authored := []
	var last := ""
	for s in strokes:
		var id := int(cn.vmcall("pen_begin", (s[0] as Vector3).x, (s[0] as Vector3).y, (s[0] as Vector3).z, 0.5))
		if id < 0: print("FAIL e2e: pen_begin refused"); quit(1); return
		for i in range(1, s.size()):
			var p: Vector3 = s[i]
			cn.vmcall("pen_point", id, p.x, p.y, p.z, 0.5)
		authored.push_back(s)
		var flat := _mj_crossings(mj, authored)
		last = str(cn.vmcall("pen_end_with_crossings", id, flat))
	var edges := _kv(last, "edges"); var nodes := _kv(last, "nodes"); var cyc := _kv(last, "cycles")
	print("e2e report: ", last)
	if edges == 9 and nodes == 9 and cyc >= 1:
		print("DONE e2e_crossings: two guests -> %d edges, %d nodes, %d cycle(s), matching crossing_split" % [edges, nodes, cyc])
		quit(0)
	else:
		print("FAIL e2e_crossings: edges=%d nodes=%d cycles=%d (want 9/9/>=1)" % [edges, nodes, cyc]); quit(1)
