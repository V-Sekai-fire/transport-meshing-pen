# station_physics_stage -- mujoco.elf holding the station's colliders: physics.js's groundHeight and
# resolve answered by the guest, so the walk is bit-deterministic and migrates with the VM.
extends "res://stages/stage_base.gd"

const REQUIRED := ["mjc_load_primitives", "mjc_ray_group", "mjc_player_band", "mjc_player_contacts",
		"mjc_set_qpos", "mjc_forward", "mjc_mocap_set"]
const STRIDE := 12
const WALKABLE := 1
const STEP_HEIGHT := 0.45
const RESOLVE_ITERATIONS := 3

var _height_at: Callable
var _player := -1
var _mocaps := 0


func _init() -> void:
	stage_name = "station_physics"
	open_sandbox("res://mujoco.elf", 1024, 4096, 1 << 24, {}, PackedStringArray(REQUIRED))


## physics: the station's ctx.physics; layout: ctx.L. The player is a 0.3 m band from the step height
## to the body height, so solids block exactly over physics.js's vertical span. Returns the geom count.
func load_station(physics, layout, radius: float, height: float) -> int:
	if not available():
		return -1
	_height_at = layout.height_at
	var prims := PackedFloat64Array(physics.prims)
	var boxes: Array = physics.dynamic_boxes()
	_mocaps = boxes.size()
	for b in boxes:
		prims.append_array(_box_record(b, 1.0))
	# MuJoCo refuses a zero half-extent, and walk tops are flat: give boxes a millimetre.
	for i in range(0, prims.size(), STRIDE):
		if prims[i] != 1.0:
			for k in 3:
				prims[i + 4 + k] = maxf(prims[i + 4 + k], 0.001)
	# The guest's MJCF reader refuses an elevation grid past a few thousand cells, so terrain stays
	# with layout.height_at, as physics.js's groundHeight has it; a tiny grid off the map satisfies the loader.
	var far := PackedFloat64Array([0.0, 0.01, 0.0, 0.01])
	call_now("mjc_player_band", [radius, STEP_HEIGHT, height])
	var n = call_now("mjc_load_primitives", [prims, far, 2, 2, PackedFloat64Array([1.0, 1.0, 10000.0, 10000.0])])
	if typeof(n) != TYPE_INT or n < 0:
		return -1
	var bodies = call_now("mjc_nbody", [])
	_player = int(bodies) - 1 if typeof(bodies) == TYPE_INT else -1
	return n


## physics.js's groundHeight: the highest walk top, ramp or terrain within a step of the feet.
func ground_height(x: float, z: float, feet_y: float) -> float:
	var top: float = minf(feet_y, 1000.0) + STEP_HEIGHT + 1e-7
	var hit = call_now("mjc_ray_group", [PackedFloat64Array([x, top, z]), PackedFloat64Array([0.0, -1.0, 0.0]),
			top + 200.0, _player, WALKABLE])
	if typeof(hit) == TYPE_PACKED_FLOAT64_ARRAY and hit.size() == 9 and hit[0] == 1.0:
		return hit[3]
	return _height_at.call(x, z)


## physics.js's resolve: push the circle out of every solid overlapping the band, in up to three passes.
func resolve(p: Vector2, feet_y: float) -> Vector2:
	for i in RESOLVE_ITERATIONS:
		call_now("mjc_set_qpos", [PackedFloat64Array([p.x, feet_y, p.y])])
		call_now("mjc_forward", [])
		var c = call_now("mjc_player_contacts", [])
		if typeof(c) != TYPE_PACKED_FLOAT64_ARRAY or c.size() == 0:
			break
		var deepest := {}
		for k in range(0, c.size(), 5):
			if c[k + 4] < -1e-12 and (not deepest.has(c[k]) or c[k + 4] < deepest[c[k]][2]):
				deepest[c[k]] = [c[k + 1], c[k + 3], c[k + 4]]
		if deepest.is_empty():
			break
		for g in deepest:
			var n := Vector2(deepest[g][0], deepest[g][1])
			if n.length() > 1e-6:
				p += n.normalized() * -deepest[g][2]
	return p


## Each moving collider (physics.js addDynamic) as {cx, cz, w, d, rotY, y0, y1}; the count is the load's.
func move_dynamic(boxes: Array) -> void:
	for i in mini(boxes.size(), _mocaps):
		var r := _box_record(boxes[i], 1.0)
		call_now("mjc_mocap_set", [i, PackedFloat64Array([r[1], r[2], r[3], r[7], r[8], r[9], r[10]])])


func _box_record(b: Dictionary, mocap: float) -> PackedFloat64Array:
	var y0: float = b.get("y0", -50.0)
	var y1: float = b.get("y1", 200.0)
	var q := Quaternion(Vector3.UP, b.get("rotY", 0.0))
	return PackedFloat64Array([0, b.cx, (y0 + y1) / 2.0, b.cz, b.w / 2.0, (y1 - y0) / 2.0, b.d / 2.0,
			q.w, q.x, q.y, q.z, mocap])
