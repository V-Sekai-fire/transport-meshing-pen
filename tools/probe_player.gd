# Loads xr_main flat, waits for the station, then walks, snap-turns and teleports the station player.
#   godot --headless --path . --xr-mode off -s tools/probe_player.gd
extends SceneTree

var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://xr_main.tscn").instantiate()
	get_root().add_child(_main)


func _process(_dt: float) -> bool:
	_frames += 1
	var p = _main.get_node("World/StationPlayer")
	if p.walker == null:
		if _frames > 600:
			print("RESULT: FAIL (station never built)")
			quit(1)
		return false
	var cam: Node3D = _main.get_node("World/FlatCamera")
	p.step(1.0 / 60.0, Vector2.ZERO, 0, false)
	var a: Vector3 = cam.global_position
	var t0 := Time.get_ticks_usec()
	for i in 120:
		p.step(1.0 / 60.0, Vector2(0, 1), 0, false)
	var walked := (cam.global_position - a).length()
	var yaw0: float = p.walker.yaw
	p.step(1.0 / 60.0, Vector2.ZERO, 1, false)
	p.step(1.0 / 60.0, Vector2.ZERO, 1, false)
	var turned: float = rad_to_deg(p.walker.yaw - yaw0)
	var target: Vector3 = p.walker.pos + Vector3(0, 0, -3).rotated(Vector3.UP, p.walker.yaw)
	var landed: bool = p.walker.teleport(Vector3(target.x, p.stage.ground_height(target.x, target.z, 1e9), target.z))
	print("player: walked %.3f m in 2 s at full stick (run), snap %.1f deg (second inside cooldown), teleport %s, %.2f ms/frame" % [
			walked, turned, landed, (Time.get_ticks_usec() - t0) / 1000.0 / 122.0])
	var r = _main.get_node("World/Radial")
	var canvas = _main.get_node("World/XROrigin3D/Canvas")
	var picks := [r.pick(Vector2(0, 1)), r.pick(Vector2(0.9, -0.5)), r.pick(Vector2(-0.9, -0.5)), r.pick(Vector2(0.1, 0.1))]
	r.open(null)
	r.tilt(Vector2(0, 1))
	var chose: String = r.release()
	var grab_on: bool = canvas.enabled
	r.open(null)
	r.tilt(Vector2(0.9, -0.5))
	r.release()
	var home := Vector2(p.walker.pos.x - 1.6, p.walker.pos.z - 34.0).length()
	print("radial: picks %s, chose %s, world grab %s, recentre %.3f m from the hero spot" % [picks, chose, grab_on, home])
	var ok := picks == [0, 1, 2, -1] and chose == "World grab" and grab_on and home < 1e-3 and walked > 11.0 and walked < 13.0 and absf(absf(turned) - 30.0) < 0.01 and landed
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
	return true
