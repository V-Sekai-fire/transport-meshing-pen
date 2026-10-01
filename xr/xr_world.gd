# xr_world -- the visible half of xr_main.tscn: picks XR or flat, shows the
# pipeline's body, strokes and garment under Body, and hands
# the pen bridge to the pipeline. Main (the scene root, main.gd) calls
# attach(main) once its stages exist (children are ready before parents).
#
# XR: with --xr-mode on and a runtime (XR_RUNTIME_JSON per process, never the
# system default: AGENTS.md rule 9) the OpenXR interface comes up initialised;
# then the viewport renders to it from XRCamera3D. Otherwise FlatCamera looks
# at the body; that is the flat run Gate 8 screenshots.
extends Node3D

const MeshWire := preload("res://util/mesh_wire.gd")

var xr_on := false
var xr_runtime := ""
var main = null

@onready var body: Node3D = $Body

func _ready() -> void:
	var xr := _pick_xr()
	if xr == null and "--render=openvr" in OS.get_cmdline_user_args():
		xr = await _pick_openvr()
	xr_on = xr != null
	if xr_on:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		$XROrigin3D/XRCamera3D.current = true
		xr_runtime = str(xr.get_name())
	else:
		$FlatCamera.current = true
	print("[dress-on] xr_main: %s" % ("XR on (%s)" % xr_runtime if xr_on else "flat"))

# OpenXR renders the headset. OpenVR rendering is a hard wall under Proton: its
# frame submit aborts in Proton's vrclient (vrcompositor_manual.c:2321, "!status")
# on the multiview array submit, and --xr-mode on crashes at startup. So the person
# wears and draws through OpenXR; OpenVR is the tracking/controller stack (flat/
# companion path). Fixing OpenVR render needs non-array per-eye submits in
# godot_openvr plus Proton cooperation, not a mode toggle here.
# Native Windows SteamVR has no such wall, so `-- --render=openvr` renders through
# OpenVR, the one interface that also tracks the companions (tools/run-windows.sh).
func _pick_xr() -> XRInterface:
	var oxr := XRServer.find_interface("OpenXR")
	if oxr != null and oxr.is_initialized():
		return oxr
	return null

# godot_openvr adds its interface on a deferred call, so wait for it.
func _pick_openvr() -> XRInterface:
	var ovr: XRInterface = null
	for i in 60:
		ovr = XRServer.find_interface("OpenVR")
		if ovr != null:
			break
		await get_tree().process_frame
	if ovr == null or not (ovr.is_initialized() or ovr.initialize()):
		push_error("[dress-on] --render=openvr: OpenVR interface unavailable")
		return null
	XRServer.primary_interface = ovr
	return ovr

func attach(m) -> void:
	main = m
	var p = m.pipeline
	p.body_ready.connect(_on_body)
	p.garment_ready.connect(_on_garment)
	p.skeleton_ready.connect(_on_skeleton)
	var bridge = get_node_or_null("PenBridge")
	if bridge != null:
		bridge.attach(p)

func _mat(c: Color, alpha: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c, alpha)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

# mesh_wire's ArrayMesh with smooth normals, so the screenshot shows shape.
func _shaded(v: PackedFloat32Array, f: PackedInt32Array) -> ArrayMesh:
	var m := MeshWire.to_array_mesh(v, f)
	if m.get_surface_count() == 0:
		return m
	var st := SurfaceTool.new()
	st.create_from(m, 0)
	st.generate_normals()
	return st.commit()

func _on_body(v: PackedFloat32Array, f: PackedInt32Array) -> void:
	var mi: MeshInstance3D = body.get_node("BodyMesh")
	mi.mesh = _shaded(v, f)
	mi.material_override = _mat(Color(0.85, 0.75, 0.68))

func _on_skeleton(joints: PackedFloat32Array, _bones: PackedInt32Array) -> void:
	var holder: Node3D = body.get_node("Joints")
	for c in holder.get_children():
		c.queue_free()
	for i in joints.size() / 3:
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.012
		sm.height = 0.024
		s.mesh = sm
		s.material_override = _mat(Color(0.9, 0.2, 0.2))
		s.position = Vector3(joints[3 * i], joints[3 * i + 1], joints[3 * i + 2])
		holder.add_child(s)

func _on_garment(v: PackedFloat32Array, f: PackedInt32Array, _label: String) -> void:
	var mi: MeshInstance3D = body.get_node("Garment")
	mi.mesh = _shaded(v, f)
	mi.material_override = _mat(Color(0.3, 0.5, 0.9))
