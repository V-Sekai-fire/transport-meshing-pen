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

func _ready() -> void:
	print("[dress-on] companion pens: _ready")
	_origin = get_node_or_null("../XROrigin3D")
	if _origin == null:
		return
	# Bring OpenVR up for tracking only (never rendering — that submit asserts under
	# Proton). xr_world renders via OpenXR or flat; this reads the vpen devices.
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
	if OS.has_environment("DRESS_POSE_DEBUG"):
		for _k in 8:
			await get_tree().create_timer(0.4).timeout
			var s := ""
			for tn in _companions:
				var c: Node3D = _companions[tn]
				s += " %s=%.2v" % [tn, c.global_position]
			print("[dress-on] companion pos:%s" % s)

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
	# A coloured tip so the companion is visible even when it is not moving.
	var tip := MeshInstance3D.new()
	tip.name = "Tip"
	var sphere := SphereMesh.new()
	sphere.radius = 0.02
	sphere.height = 0.04
	tip.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COMPANION_COLOR
	tip.material_override = mat
	ctrl.add_child(tip)
	_origin.add_child(ctrl)
	_companions[tracker_name] = ctrl
	print("[dress-on] companion pen: %s (%s)" % [str(tracker_name), _serial(tracker_name)])

func _on_removed(tracker_name, _type) -> void:
	if _companions.has(tracker_name):
		_companions[tracker_name].queue_free()
		_companions.erase(tracker_name)
