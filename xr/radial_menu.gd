# Hold B or Y to open three wedges at that hand, tilt its stick to pick one, release to choose it.
extends Node3D

const ITEMS := ["World grab", "Recentre", "Exit"]
const TILT := 0.5

@export var player_path: NodePath
@export var canvas_path: NodePath
@export var hand_paths: Array[NodePath] = []

var selected := -1
var _hand: XRController3D
var _wedges: Array[CSGPolygon3D] = []
var _labels: Array[Label3D] = []


func _ready() -> void:
	for i in ITEMS.size():
		var w := CSGPolygon3D.new()
		var poly := PackedVector2Array()
		var a0 := PI / 2.0 - TAU * i / ITEMS.size() - PI / ITEMS.size() + 0.05
		var a1 := a0 + TAU / ITEMS.size() - 0.1
		for k in 9:
			var a := lerpf(a0, a1, k / 8.0)
			poly.append(Vector2(cos(a), sin(a)) * 0.12)
		for k in 9:
			var a := lerpf(a1, a0, k / 8.0)
			poly.append(Vector2(cos(a), sin(a)) * 0.04)
		w.polygon = poly
		w.depth = 0.005
		w.material = StandardMaterial3D.new()
		add_child(w)
		_wedges.append(w)
		var l := Label3D.new()
		var mid := (a0 + a1) / 2.0
		l.position = Vector3(cos(mid), sin(mid), 0.01) * Vector3(0.08, 0.08, 1.0)
		l.pixel_size = 0.0004
		add_child(l)
		_labels.append(l)
	visible = false


## Wedge under a stick tilt, or -1 inside the dead centre.
func pick(tilt: Vector2) -> int:
	if tilt.length() < TILT:
		return -1
	var from_top := fposmod(atan2(tilt.x, tilt.y) + PI / ITEMS.size(), TAU)
	return int(from_top / (TAU / ITEMS.size())) % ITEMS.size()


func open(hand: XRController3D) -> void:
	_hand = hand
	selected = -1
	visible = true
	_paint()


func tilt(stick: Vector2) -> void:
	var s := pick(stick)
	if s != selected:
		selected = s
		if s >= 0 and _hand and _hand.get_is_active():
			_hand.trigger_haptic_pulse("haptic", 0.0, 0.3, 0.03, 0.0)
		_paint()


func release() -> String:
	visible = false
	_hand = null
	if selected < 0:
		return ""
	var item: String = ITEMS[selected]
	selected = -1
	match item:
		"World grab":
			var canvas = get_node_or_null(canvas_path)
			if canvas:
				canvas.enabled = not canvas.enabled
		"Recentre":
			var player = get_node_or_null(player_path)
			if player:
				player.recentre()
		"Exit":
			get_tree().quit()
	return item


func _paint() -> void:
	var canvas = get_node_or_null(canvas_path)
	for i in ITEMS.size():
		var on: bool = i == 0 and canvas != null and canvas.enabled
		_labels[i].text = "%s %s" % [ITEMS[i], "on" if on else "off"] if i == 0 else ITEMS[i]
		(_wedges[i].material as StandardMaterial3D).albedo_color = Color(1.0, 0.8, 0.2) if i == selected else Color(0.2, 0.2, 0.25)


func _process(_dt: float) -> void:
	var oxr := XRServer.find_interface("OpenXR")
	if oxr == null or not oxr.is_initialized():
		return
	for path in hand_paths:
		var hand: XRController3D = get_node_or_null(path)
		if hand == null or not hand.get_is_active():
			continue
		var held: bool = hand.is_button_pressed("by_button")
		if held and _hand == null:
			open(hand)
		if hand == _hand:
			if held:
				global_transform = hand.global_transform
				tilt(hand.get_vector2("primary"))
			else:
				release()
