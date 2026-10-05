# pen_bridge -- xr-grid's SketchTool -> the pipeline's pen events (and so
# curvenet.elf's pen_begin / pen_point / pen_end), in the Body's local frame.
#
# pen = "xr": each SketchTool's `active` edge is watched here, the way
# SketchTool._process watches it for SimpleSketch: rising -> begin, held ->
# point (the tool's origin in Body space; pressure = tool.pressure / 0.01,
# hand.gd's max_size), falling -> end. SketchTool keeps drawing its own
# ribbon into Body/strokes. strokes.gd is not used: its just_pressed is
# is_zero_approx(pressed) inside `if not is_zero_approx(pressed)`, always
# false, so it never starts a stroke. The authoring ends on the menu button
# of either controller, Enter on a keyboard, or Main.dress_on_author_done().
# Boundary mode (the edge of an opening: a skirt's waist and hem) toggles on
# a thumbstick click on either controller (A/B/X/Y are xr-grid's own debug
# save/load in hand.gd) or the B key; a stroke takes the mode
# it began in (curvenet captures it at pen_begin).
#
# pen = "scripted": the pipeline's strokes (xr/pen_source_scripted.gd, handed
# over by its strokes_ready signal) are replayed one stroke per frame through
# the same pen_event calls, and drawn into Body/strokes as Line3D strokes so
# the flat and VR screenshots show them. No controller is read.
extends Node

const MAX_SIZE := 0.01 # hand.gd: sketch_tool.pressure = trigger * max_size

@export var tools: Array[NodePath] = []
@export var body_path: NodePath
@export var statue_path: NodePath

var pipeline = null
var body: Node3D = null
var statue = null
var _frame_of := {}
var _prev := {}
var _stroke_of := {}
var _next_stroke := 0
var _replay: Array = []
var _sketch = null
var strokes_sent := 0
var _cur: Dictionary = {}
var _cur_i := 0
var _pace_owed := 0.0
var _cur_k := 0
var boundary_mode := false
var _by_prev := false

func attach(p) -> void:
	pipeline = p
	pipeline.pen_external = true
	pipeline.strokes_ready.connect(_on_strokes)
	body = get_node_or_null(body_path)
	statue = get_node_or_null(statue_path) if not statue_path.is_empty() else null
	var strokes_node = body.get_node_or_null("strokes") if body != null else null
	if strokes_node != null:
		_sketch = load("res://xr/line3d_sketch.gd").new(strokes_node)

func _on_strokes(strokes: Array) -> void:
	if pipeline == null or pipeline.opts.get("pen", "scripted") != "scripted":
		return
	_replay = strokes.duplicate()
	_next_stroke = 0

func _process(_dt: float) -> void:
	if pipeline == null or pipeline.state != "AUTHOR":
		return
	if pipeline.opts.get("pen", "scripted") == "scripted":
		_replay_one()
	else:
		_forward_tools()

func _replay_one() -> void:
	var pace: float = float(pipeline.opts.get("pace", 0))
	if pace > 0.0:
		_replay_paced(pace)
		return
	if _replay.is_empty():
		return
	var st: Dictionary = _replay.pop_front()
	var pts: PackedVector3Array = st.points
	var k := _next_stroke
	_next_stroke += 1
	pipeline.pen_event("begin", k, pts[0], 0.5, bool(st.get("boundary", false)))
	for i in range(1, pts.size()):
		pipeline.pen_event("point", k, pts[i], 0.5)
	pipeline.pen_event("end", k)
	strokes_sent += 1
	if _sketch != null:
		_sketch.stroke_begin()
		for p in pts:
			_sketch.stroke_add(p, 0.008, Color(0.1, 0.2, 0.8))
		_sketch.stroke_end()
	if _replay.is_empty():
		pipeline.pen_finish()

# opts.pace > 0: pace points a frame, the ribbon growing with them, so a recording shows the drawing.
# A fraction below 1 spreads the points over several frames.
func _replay_paced(pace: float) -> void:
	if _cur.is_empty():
		if _replay.is_empty():
			return
		_cur = _replay.pop_front()
		_cur_k = _next_stroke
		_next_stroke += 1
		var p0: Vector3 = _cur.points[0]
		pipeline.pen_event("begin", _cur_k, p0, 0.5, bool(_cur.get("boundary", false)))
		if _sketch != null:
			_sketch.stroke_begin()
			_sketch.stroke_add(p0, 0.008, Color(0.1, 0.2, 0.8))
		_cur_i = 1
	var pts: PackedVector3Array = _cur.points
	_pace_owed += pace
	var take := int(_pace_owed)
	_pace_owed -= take
	var stop := mini(_cur_i + take, pts.size())
	for i in range(_cur_i, stop):
		pipeline.pen_event("point", _cur_k, pts[i], 0.5)
		if _sketch != null:
			_sketch.stroke_add(pts[i], 0.008, Color(0.1, 0.2, 0.8))
	_cur_i = stop
	if _cur_i >= pts.size():
		pipeline.pen_event("end", _cur_k)
		strokes_sent += 1
		if _sketch != null:
			_sketch.stroke_end()
		_cur = {}
		if _replay.is_empty():
			pipeline.pen_finish()

func _forward_tools() -> void:
	if body == null:
		return
	for path in tools:
		var t = get_node_or_null(path)
		if t == null:
			continue
		var active: bool = t.active
		var was: bool = _prev.get(path, false)
		var g: Vector3 = t.global_transform.origin
		if active and not was:
			_frame_of[path] = statue.body if statue != null and statue.reaches(g) else body
		var p: Vector3 = _frame_of.get(path, body).to_local(g)
		var pressure := clampf(float(t.pressure) / MAX_SIZE, 0.0, 1.0)
		if active and not was:
			_stroke_of[path] = _next_stroke
			_next_stroke += 1
			pipeline.pen_event("begin", _stroke_of[path], p, pressure, boundary_mode)
		elif active and was:
			pipeline.pen_event("point", _stroke_of[path], p, pressure)
		elif was and not active:
			pipeline.pen_event("end", _stroke_of[path])
			strokes_sent += 1
		_prev[path] = active
	if Input.is_action_just_pressed("ui_accept"):
		finish()
	var by := Input.is_physical_key_pressed(KEY_B)
	for path in tools:
		var t = get_node_or_null(path)
		var hand = t.get_parent() if t != null else null
		if hand is XRController3D and hand.is_button_pressed("primary_click"):
			by = true
	if by and not _by_prev:
		boundary_mode = not boundary_mode
		print("pen: boundary mode %s" % ("on" if boundary_mode else "off"))
	_by_prev = by
	for path in tools:
		var t = get_node_or_null(path)
		var hand = t.get_parent() if t != null else null
		if hand is XRController3D and hand.is_button_pressed("menu_button"):
			finish()

func finish() -> void:
	if pipeline != null and pipeline.state == "AUTHOR" and not pipeline.pen_finished:
		# Close any stroke still held.
		for path in _prev:
			if _prev[path]:
				pipeline.pen_event("end", _stroke_of[path])
				_prev[path] = false
		pipeline.pen_finish()
