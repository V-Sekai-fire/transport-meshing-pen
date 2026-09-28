# mujoco_stage -- mujoco.elf: stroke crossings from the engine's capsule
# collision (RFD 2274). Optional: when its ELF is absent or fails to load, the
# pipeline falls back to curvenet's own solve, which is the parallel-commit
# rollback (RFD 2119) -- the stroke still commits, on the predicted points.
extends "res://stages/stage_base.gd"

const REQUIRED := ["mj_crossings"]

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
