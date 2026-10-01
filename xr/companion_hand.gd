# companion_hand -- drives a companion pen's SketchTool from a vpen device that
# the OpenVR interface surfaces. When the device's trigger is mapped (an OpenVR
# action manifest, which the feeder brings) the tool follows it; until then the
# tool draws while the device is tracked, so the companion's motion is visible.
# The person's own hands use hand.gd, not this. RFD 2287.
extends XRController3D

@onready var sketch_tool: Node3D = $SketchTool

func _process(_dt: float) -> void:
	# No OpenVR action manifest yet, so there is no "trigger" input to read, and
	# reading one null-derefs the double build. Draw while the device has a valid
	# pose, which also skips the frames before the first pose (no origin streak);
	# the feeder's action manifest gates on the trigger later.
	sketch_tool.active = get_has_tracking_data()
	sketch_tool.pressure = 0.012
