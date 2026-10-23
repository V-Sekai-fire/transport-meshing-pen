# RFD 3010 gate 3, offline: a held stroke reaches curvenet with no point that steps
# back against the step before it. Each raw dev.4 layer's strokes are fed, point by
# point, through the pipeline's pen_event as a tracked pen would send them; the points
# it queues for curvenet must step back nowhere and equal the -noreversal layer.
#
#   godot --path . --resolution 320x180 --xr-mode off --script tools/gate_clean_strokes.gd \
#     [-- --control=no_clean]
#
# --control=no_clean turns the cleaning off, so the queued points keep their
# back-and-forth and the gate must FAIL.
extends SceneTree

const Pipeline := preload("res://stages/pipeline.gd")
const LAYERS := ["hand-skirt-1", "hand-skirt-2"]
const DIR := "res://tools/strokes/dev4/"

func _initialize() -> void:
	var control := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--control="):
			control = a.get_slice("=", 1)
	if control not in ["", "no_clean"]:
		_end("FAIL (unknown control %s)" % control)
		return
	var checks := 0
	var bad := []
	for name in LAYERS:
		var raw := _strokes(DIR + name + ".usda")
		var want := _strokes(DIR + name + "-noreversal.usda")
		if raw.is_empty() or raw.size() != want.size():
			bad.append("%s: %d raw strokes, %d clean" % [name, raw.size(), want.size()])
			continue
		var p: Node = Pipeline.new()
		p.opts = {"pen": "xr", "clean_strokes": control != "no_clean"}
		p.data = {}
		for k in raw.size():
			var pts: PackedVector3Array = raw[k]
			p.pen_event("begin", k, pts[0])
			for i in range(1, pts.size()):
				p.pen_event("point", k, pts[i])
			p.pen_event("end", k, pts[-1])
		var sent := {}
		for e in p.pen_queue:
			if e.kind == "begin":
				sent[e.stroke] = PackedVector3Array([e.pos])
			elif e.kind == "point":
				sent[e.stroke].append(e.pos)
		for k in raw.size():
			checks += 1
			var got: PackedVector3Array = sent.get(k, PackedVector3Array())
			var back := Pipeline.reversals(got)
			var same := _same(got, want[k])
			print("%s stroke %d: %d points in, %d sent, %d step back; %s the -noreversal layer (%d points)" % [
					name, k, raw[k].size(), got.size(), back, "equals" if same else "differs from", want[k].size()])
			if back > 0 or not same:
				bad.append("%s stroke %d" % [name, k])
		p.free()
	print("CHECKS %d of %d ran" % [checks, 12])
	if checks != 12:
		bad.append("%d of 12 strokes checked" % checks)
	_end("PASS" if bad.is_empty() else "FAIL (%s)" % ", ".join(bad))

func _end(verdict: String) -> void:
	print("RESULT: " + verdict)
	quit(0 if verdict == "PASS" else 1)

static func _same(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i].distance_to(b[i]) > 1e-6:
			return false
	return true

# The points of every BasisCurves prim, in file order (a test-only reader of the
# layers util/strokes_usd.gd writes; the pipeline reads them through usd.elf).
static func _strokes(path: String) -> Array:
	var text := FileAccess.get_file_as_string(path)
	var out := []
	var re := RegEx.create_from_string("point3f\\[\\] points = \\[([^\\]]*)\\]")
	var num := RegEx.create_from_string("\\(([^()]*)\\)")
	for m in re.search_all(text):
		var pts := PackedVector3Array()
		for t in num.search_all(m.get_string(1)):
			var c := t.get_string(1).split(",")
			pts.append(Vector3(float(c[0]), float(c[1]), float(c[2])))
		out.append(pts)
	return out
