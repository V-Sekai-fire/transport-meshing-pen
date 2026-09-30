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
	_xr = XRServer.find_interface("OpenVR")
	_origin = get_node_or_null("../XROrigin3D")
	if _xr == null or _origin == null:
		return
	XRServer.tracker_added.connect(_on_added)
	XRServer.tracker_removed.connect(_on_removed)
	# Devices already present before we connected.
	for tracker_name in XRServer.get_trackers(XRServer.TRACKER_CONTROLLER):
		_on_added(tracker_name, XRServer.TRACKER_CONTROLLER)

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
	_origin.add_child(ctrl)
	_companions[tracker_name] = ctrl
	print("[dress-on] companion pen: %s (%s)" % [str(tracker_name), _serial(tracker_name)])

func _on_removed(tracker_name, _type) -> void:
	if _companions.has(tracker_name):
		_companions[tracker_name].queue_free()
		_companions.erase(tracker_name)
