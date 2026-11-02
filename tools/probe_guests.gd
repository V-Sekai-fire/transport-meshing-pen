# Guest call gate: lasso.elf and mujoco.elf load and answer one real call each,
# and each answer is checked by a predicate whose control must fail.
#   godot --headless --path . --xr-mode off --script tools/probe_guests.gd
#
# lasso.elf (interactor-lasso): a pointer at the origin looks down -z at a near
# and a far target inside its cone, with a nearer target off to the side outside
# it. The snap must pick the near target in the cone. Control: the same scene
# with the pointer turned toward the side target; "the near cone target is
# picked" must then be false, so the pick follows the cone, not the target order.
#
# mujoco.elf (interactor-mujoco-sandbox-demo): the station model with no
# colliders is the player capsule alone (radius 0.3 m, y 0 to 1.7 m). A stroke
# point inside it goes through mj_push_out, and mjc_ray decides "outside the
# body": a ray from the point toward the capsule's axis meets a surface facing
# it. The pushed point must be outside. Control: the same predicate on the point
# as it was, left inside the body, must fail.
#
# The ELFs are the ones tools/build.exs just built (lasso.elf is not tracked).
extends SceneTree

const SandboxUtil := preload("res://stages/sandbox_util.gd")

var _failed := PackedStringArray()


func _initialize() -> void:
	_lasso()
	_mujoco()
	print("RESULT: ", "PASS" if _failed.is_empty() else "FAIL " + ", ".join(_failed))
	quit(0 if _failed.is_empty() else 1)


func _expect(name: String, ok: bool, detail: String) -> void:
	print("%s: %s (%s)" % [name, "ok" if ok else "FAIL", detail])
	if not ok:
		_failed.append(name)


# The control is a check that must not hold; it holding fails the gate.
func _control(name: String, holds: bool, detail: String) -> void:
	print("%s: %s (%s)" % [name, "FAIL, held" if holds else "ok, failed as it must", detail])
	if holds:
		_failed.append(name)


# --- lasso.elf -------------------------------------------------------------------

const NEAR_IN_CONE := 1
const SIDE_OUT_OF_CONE := 2


# A pointer at the origin whose -z column is along dir: basis columns x, y, z, then the origin.
func _pointer(dir: Vector3) -> PackedFloat64Array:
	var b := Basis.looking_at(dir, Vector3.UP)
	return PackedFloat64Array([b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, 0.0, 0.0, 0.0])


# The first target lasso_snap picks, or -2 when the call did not answer.
func _snap(sb, source: PackedFloat64Array, targets: PackedFloat32Array) -> int:
	var r = sb.vmcall("lasso_snap", source, targets, -1, 0.0, 0.0, false)
	if (typeof(r) != TYPE_PACKED_FLOAT32_ARRAY and typeof(r) != TYPE_PACKED_FLOAT64_ARRAY) or r.size() != 4:
		print("lasso_snap: answered ", str(r).left(120))
		return -2
	print("lasso_snap: first %d second %d scores %.3f %.3f" % [int(r[0]), int(r[1]), r[2], r[3]])
	return int(r[0])


func _lasso() -> void:
	var holder := Node.new()
	var made := SandboxUtil.make_sandbox(holder, "res://lasso.elf", 0, 4096, 0, {}, PackedStringArray(["lasso_snap"]))
	var sb = made.sandbox
	_expect("lasso.elf load", sb != null, made.reason if sb == null else "%d functions" % sb.get_functions().size())
	if sb == null:
		holder.free()
		return
	# Per target: x, y, z, size, snapping power, visible, snap locked.
	var targets := PackedFloat32Array([
		0.0, 0.0, -6.0, 0.25, 1.0, 1.0, 0.0, # 0: far, in the cone
		0.0, 0.0, -2.0, 0.25, 1.0, 1.0, 0.0, # 1: near, in the cone
		1.5, 0.0, -1.0, 0.25, 1.0, 1.0, 0.0, # 2: nearest (1.8 m), 56 degrees off the axis
	])
	var picked := _snap(sb, _pointer(Vector3.FORWARD), targets)
	_expect("lasso picks the near cone target", picked == NEAR_IN_CONE, "picked %d, want %d" % [picked, NEAR_IN_CONE])
	_expect("lasso skips the target outside the cone", picked != SIDE_OUT_OF_CONE and picked >= 0, "picked %d" % picked)
	var turned := _snap(sb, _pointer(Vector3(1.5, 0.0, -1.0)), targets)
	_expect("lasso control answered", turned >= 0, "picked %d" % turned)
	_control("lasso control: near cone target picked with the pointer turned away", turned == NEAR_IN_CONE,
			"picked %d" % turned)
	holder.free()


# --- mujoco.elf ------------------------------------------------------------------

const CAPSULE_RADIUS := 0.3
const THICKNESS := 0.02


# Outside the body: a horizontal ray from p toward the capsule's axis (x = z = 0) first meets a
# surface whose normal faces back along the ray. From inside, the first hit is the exit, facing away.
func _outside(stage, p: Vector3) -> Dictionary:
	var toward := Vector3(-p.x, 0.0, -p.z).normalized()
	var r = stage.call_now("mjc_ray", [PackedFloat64Array([p.x, p.y, p.z]),
			PackedFloat64Array([toward.x, toward.y, toward.z]), 4.0, -1])
	if typeof(r) != TYPE_PACKED_FLOAT64_ARRAY or r.size() != 9:
		return {"answered": false, "outside": false, "detail": "mjc_ray answered %s" % str(r).left(120)}
	var facing: float = r[5] * toward.x + r[6] * toward.y + r[7] * toward.z
	return {"answered": true, "outside": r[0] > 0.5 and facing < 0.0,
			"detail": "hit %d dist %.3f normal.dir %.3f" % [int(r[0]), r[1], facing]}


func _mujoco() -> void:
	var stage = load("res://stages/mujoco_stage.gd").new()
	var ok: bool = stage.available()
	_expect("mujoco.elf load", ok, stage.reason if not ok else "%d functions" % stage.sandbox.get_functions().size())
	if not ok:
		stage.free()
		return
	for fn in ["mjc_load_primitives", "mjc_ray"]:
		if not stage.sandbox.has_function(fn):
			_expect("mujoco.elf has %s" % fn, false, "an ELF from before the station cut")
			stage.free()
			return
	# No colliders and no terrain: the model is the player capsule alone.
	var geoms = stage.call_now("mjc_load_primitives", [PackedFloat64Array(), PackedFloat64Array(), 0, 0,
			PackedFloat64Array()])
	_expect("mujoco loads the capsule body", typeof(geoms) == TYPE_INT and geoms == 1, "geoms %s" % str(geoms))
	var inside := Vector3(0.1, 0.85, 0.05)
	var pushed: Dictionary = stage.push(PackedVector3Array([inside]), 0.0, 0.0, THICKNESS)
	if pushed.has("error"):
		_expect("mujoco push_out answered", false, pushed.error)
		stage.free()
		return
	var p: Vector3 = pushed.points[0]
	var radial := Vector2(p.x, p.z).length()
	_expect("mujoco pushes the point out", pushed.moved >= 1 and radial >= CAPSULE_RADIUS,
			"moved %d, %s at radius %.4f" % [pushed.moved, str(p), radial])
	var out := _outside(stage, p)
	_expect("mujoco: pushed point is outside the body", out.outside, out.detail)
	var left := _outside(stage, inside)
	_expect("mujoco control answered", left.answered, left.detail)
	_control("mujoco control: point left inside reads outside", left.outside, left.detail)
	stage.free()
