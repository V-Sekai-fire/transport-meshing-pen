# companion_pens -- spawns a companion SketchTool for every vpen device the
# OpenVR interface surfaces (a controller whose serial begins "vpen_"), so the
# system draws alongside the person. The person's own left_hand/right_hand are
# untouched; OpenVR is how the companions get past the OpenXR vive-tracker role
# cap. Placed under World in xr_main.tscn. RFD 2287.
extends Node

const CompanionHand := preload("res://xr/companion_hand.gd")
const SketchToolScript := preload("res://addons/procedural_3d_grid/core/simple_sketcher/sketch_tool.gd")
const COMPANION_COLOR := Color(0.95, 0.45, 0.05) # orange, distinct from the person's pens
const PROP_SERIAL := 1002 # vr::Prop_SerialNumber_String

var _xr = null
var _origin: Node3D = null
var _companions := {} # tracker_name -> XRController3D
var _model_queue := [] # [{mi, candidates, fallback}] loaded one at a time
var _loading := false

func _ready() -> void:
	print("[dress-on] companion pens: _ready")
	_origin = get_node_or_null("../XROrigin3D")
	if _origin == null:
		return
	# OpenVR and OpenXR do not coexist here: godot_openvr crashes in
	# _update_device_roles alongside an OpenXR session. So when OpenXR renders the
	# headset the companions stay off (the person draws with their own controllers);
	# they run in the flat/OpenVR path.
	var oxr := XRServer.find_interface("OpenXR")
	if oxr != null and oxr.is_initialized():
		print("[dress-on] companion pens: OpenXR active, companions off")
		return
	# Bring OpenVR up for tracking only (never rendering — that submit asserts under
	# Proton). xr_world renders flat; this reads the vpen devices.
	_xr = await _ensure_openvr()
	print("[dress-on] companion pens: OpenVR up=%s" % (_xr != null and _xr.is_initialized()))
	if _xr == null or not _xr.is_initialized():
		print("[dress-on] companion pens: OpenVR not up, none spawned")
		return
	XRServer.tracker_added.connect(_on_added)
	XRServer.tracker_removed.connect(_on_removed)
	# OpenVR devices present at init do not reliably fire tracker_added and settle a
	# few frames after initialize(), so poll get_trackers (dedup via _companions)
	# for a few seconds rather than scanning once.
	var t0 := Time.get_ticks_msec()
	var diag := true
	while Time.get_ticks_msec() - t0 < 6000:
		var controllers := XRServer.get_trackers(XRServer.TRACKER_CONTROLLER)
		if diag:
			diag = false
			var serials := []
			for tn in controllers:
				serials.append(_serial(tn))
			print("[dress-on] companion pens: first scan %d controllers, serials=%s" % [controllers.size(), str(serials)])
		for tracker_name in controllers:
			_on_added(tracker_name, XRServer.TRACKER_CONTROLLER)
		if _companions.size() > 0 and _companions.size() >= controllers.size():
			break
		await get_tree().process_frame
	print("[dress-on] companion pens: %d spawned" % _companions.size())
	# The person's own controllers get their real render models too, so both the
	# hands and the companions show as posed device meshes. Skip a hand whose
	# device is absent (no model), so nothing stray appears at the origin.
	for hand_name in ["hand_left", "hand_right"]:
		var hand: XRController3D = _origin.get_node_or_null(hand_name)
		if hand != null and String(hand.tracker) != "":
			_attach_render_model(hand, hand.tracker, Color(0.72, 0.74, 0.8), false)

# Find the OpenVR interface (godot_openvr adds it on a deferred call, so wait a few
# frames), else instantiate it, then initialize() for tracking. Not made primary
# and no viewport uses it, so Godot never submits a frame through it.
func _ensure_openvr() -> XRInterface:
	var ovr: XRInterface = XRServer.find_interface("OpenVR")
	var tries := 0
	while ovr == null and tries < 60:
		await get_tree().process_frame
		ovr = XRServer.find_interface("OpenVR")
		tries += 1
	if ovr == null and ClassDB.class_exists("XRInterfaceOpenVR"):
		ovr = ClassDB.instantiate("XRInterfaceOpenVR")
		if ovr != null:
			XRServer.add_interface(ovr)
	if ovr != null and not ovr.is_initialized():
		ovr.initialize()
	return ovr

const PROP_RENDER_MODEL := 1003 # vr::Prop_RenderModelName_String

# Attach the device's actual OpenVR render model (generic_tracker for a vpen, the
# real controller mesh for the person's hands) so orientation reads. Tinted, since
# the model comes untextured. Falls back to an oriented cone when a device reports
# no model (fallback off skips instead, so an absent controller shows nothing).
func _attach_render_model(ctrl: Node3D, tracker_name, tint: Color, fallback := true) -> void:
	var t = XRServer.get_tracker(tracker_name)
	var reported := ""
	if _xr != null and t != null:
		reported = str(_xr.get_tracked_device_property(t, PROP_RENDER_MODEL))
	var has_reported := reported != "" and reported != "<null>"
	# Nothing to show for an absent person controller (no reported model, no fallback).
	if _xr == null or (not has_reported and not fallback):
		return
	# Prefer the model the driver reports, then a generic model the driver always
	# provides, then an oriented cone.
	var candidates: Array[String] = []
	if has_reported:
		candidates.append(reported)
	candidates.append("generic_controller")
	candidates.append("generic_tracker")
	var mi := MeshInstance3D.new()
	mi.name = "Model"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mi.material_override = mat
	ctrl.add_child(mi)
	_model_queue.append({"mi": mi, "candidates": candidates, "fallback": fallback})
	if not _loading:
		_load_models()

# Load render models one at a time. godot_openvr's loader is not reentrant, so many
# concurrent load_render_model calls crash it; a serial queue is the state machine.
func _load_models() -> void:
	_loading = true
	while not _model_queue.is_empty():
		var item = _model_queue.pop_front()
		await _fill_render_model(item["mi"], item["candidates"], item["fallback"])
	_loading = false

# A render model loads async: godot_openvr queues it and its per-frame process
# fills the mesh one load_render_model call returns. For each candidate submit once,
# then poll that mesh's surface count each frame (a state check, not a re-request);
# take the first that fills, else the next, else an oriented cone.
func _fill_render_model(mi: MeshInstance3D, candidates: Array, fallback: bool) -> void:
	for model_name in candidates:
		if not is_instance_valid(mi):
			return
		var mesh = _xr.load_render_model(model_name)
		if mesh == null or not (mesh is Mesh):
			continue
		mi.mesh = mesh
		for _i in 200:
			if not is_instance_valid(mi):
				return
			if mesh.get_surface_count() > 0:
				return
			await get_tree().process_frame
	if fallback and is_instance_valid(mi) and (mi.mesh == null or mi.mesh.get_surface_count() == 0):
		mi.mesh = _cone_mesh()
		mi.rotation_degrees = Vector3(-90, 0, 0)

func _cone_mesh() -> Mesh:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.02
	cone.height = 0.10
	return cone

func _serial(tracker_name) -> String:
	var t = XRServer.get_tracker(tracker_name)
	if _xr != null and t != null and _xr.has_method("get_tracked_device_property"):
		return str(_xr.get_tracked_device_property(t, PROP_SERIAL))
	return ""

func _on_added(tracker_name, type) -> void:
	if type != XRServer.TRACKER_CONTROLLER or _companions.has(tracker_name):
		return
	if not _serial(tracker_name).begins_with("vpen_"):
		return
	var ctrl := XRController3D.new()
	ctrl.name = String(tracker_name)
	ctrl.tracker = tracker_name
	ctrl.set_script(CompanionHand)
	var tool := Node3D.new()
	tool.name = "SketchTool"
	tool.set_script(SketchToolScript)
	tool.set("CANVAS", NodePath("../../../Body"))
	tool.set("color", COMPANION_COLOR)
	ctrl.add_child(tool)
	_attach_render_model(ctrl, tracker_name, COMPANION_COLOR)
	_origin.add_child(ctrl)
	_companions[tracker_name] = ctrl
	print("[dress-on] companion pen: %s (%s)" % [str(tracker_name), _serial(tracker_name)])

func _on_removed(tracker_name, _type) -> void:
	if _companions.has(tracker_name):
		_companions[tracker_name].queue_free()
		_companions.erase(tracker_name)
