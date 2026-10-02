# The dress-on statue beside the plaza monument: a body on a plinth that the XR pen draws on.
# The body is Maro (character-marocchino), and the pipeline fits on Maro when run with avatar "maro".
extends Node3D

const ObjIO := preload("res://util/obj_io.gd")
const XrWorld := preload("res://xr/xr_world.gd")
const BODY := "res://fixtures/maro/avatar.obj"
const PLINTH := Vector3(0.7, 0.2, 0.7)
const BESIDE := -1.7
const REACH := 1.2
const STONE := Color(0.78, 0.76, 0.72)

@export var station_path: NodePath = ^".."

var body: Node3D
var monument := {}
var placed := false
var garment: MeshInstance3D

func _ready() -> void:
	visible = false
	var plinth := MeshInstance3D.new()
	plinth.name = "Plinth"
	var bm := BoxMesh.new()
	bm.size = PLINTH
	plinth.mesh = bm
	plinth.position.y = PLINTH.y * 0.5
	plinth.material_override = _mat(STONE)
	add_child(plinth)
	body = Node3D.new()
	body.name = "Body"
	body.position.y = PLINTH.y
	add_child(body)
	var bmi := MeshInstance3D.new()
	bmi.name = "BodyMesh"
	body.add_child(bmi)
	garment = MeshInstance3D.new()
	garment.name = "Garment"
	body.add_child(garment)
	var st = get_node_or_null(station_path)
	if st != null and st.has_signal("built"):
		st.built.connect(func(_s): place(st.ctx.physics))

# The monument's collider in plaza/furniture.gd: addBox(x, z, 1.8, 0.7, rotY, 0, 1.05).
static func find_monument(physics) -> Dictionary:
	var hits := []
	for it in physics.items:
		if it[0] == "box" and is_equal_approx(it[3], 0.9) and is_equal_approx(it[4], 0.35) \
				and is_zero_approx(it[7]) and is_equal_approx(it[8], 1.05):
			hits.append(it)
	if hits.size() != 1:
		return {"error": "%d monument colliders" % hits.size()}
	var m: Array = hits[0]
	return {"centre": Vector3(m[1], 0.0, m[2]), "rot_y": float(m[5]), "half": Vector2(m[3], m[4])}

func place(physics, beside: float = BESIDE) -> bool:
	monument = find_monument(physics)
	if monument.has("error"):
		push_warning("statue: " + monument.error)
		return false
	var b := Basis(Vector3.UP, monument.rot_y)
	transform = Transform3D(b, monument.centre + b * Vector3(beside, 0, 0))
	var m := ObjIO.read(BODY)
	if m.has("error"):
		push_warning("statue: " + m.error)
		return false
	_show_body(m.v, m.f)
	visible = true
	placed = true
	return true

func attach(p) -> void:
	p.body_ready.connect(_show_body)
	p.garment_ready.connect(_show_garment)

# A stroke begun this close to the statue's hips is drawn on the statue.
func reaches(global_p: Vector3) -> bool:
	var hips := body.global_transform * Vector3(0, 0.9, 0)
	return placed and is_visible_in_tree() and hips.distance_to(global_p) < REACH * body.global_transform.basis.get_scale().x

func _show_body(v: PackedFloat32Array, f: PackedInt32Array) -> void:
	var mi: MeshInstance3D = body.get_node("BodyMesh")
	mi.mesh = XrWorld._shaded(v, f)
	mi.material_override = _mat(STONE)

func _show_garment(v: PackedFloat32Array, f: PackedInt32Array, _label: String) -> void:
	garment.mesh = XrWorld._shaded(v, f)
	garment.material_override = _mat(Color(0.3, 0.5, 0.9))

static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
