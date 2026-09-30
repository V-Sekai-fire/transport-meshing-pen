# companion_hand -- drives a companion pen's SketchTool from a vpen device that
# the OpenVR interface surfaces. When the device's trigger is mapped (an OpenVR
# action manifest, which the feeder brings) the tool follows it; until then the
# tool draws while the device is tracked, so the companion's motion is visible.
# The person's own hands use hand.gd, not this. RFD 2287.
extends XRController3D

@onready var sketch_tool: Node3D = $SketchTool

func _process(_dt: float) -> void:
	var pressed := get_float("trigger")
	if pressed > 0.05:
		sketch_tool.active = true
		sketch_tool.pressure = pressed * 0.01 # hand.gd's max_size
	else:
		sketch_tool.active = get_has_tracking_data()
		sketch_tool.pressure = 0.005
