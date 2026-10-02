# Loads xr_main flat, waits for the station, then walks, snap-turns and teleports the station player.
# --control=no_cooldown drops the snap-turn cooldown, so the second turn lands and the probe must FAIL.
#   godot --headless --path . --xr-mode off -s tools/probe_player.gd -- [--control=no_cooldown]
extends SceneTree

const PLAYER := "res://xr/station_player.gd"

var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://xr_main.tscn").instantiate()
	if "--control=no_cooldown" in OS.get_cmdline_user_args():
		var s := GDScript.new()
		s.source_code = FileAccess.get_file_as_string(PLAYER).replace("const SNAP_COOLDOWN := 0.25", "const SNAP_COOLDOWN := 0.0")
		s.reload()
		var node: Node = _main.get_node("World/StationPlayer")
		var kept := {}
		for prop in node.get_property_list():
			if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE:
				kept[prop.name] = node.get(prop.name)
		node.set_script(s)
		for k in kept:
			node.set(k, kept[k])
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
	var checks := {
		"walk": walked > 11.0 and walked < 13.0,
		"snap cooldown": absf(absf(turned) - 30.0) < 0.01,
		"teleport": landed,
		"radial": picks == [0, 1, 2, -1] and chose == "World grab" and grab_on and home < 1e-3,
	}
	var failed: Array = checks.keys().filter(func(k): return not checks[k])
	print("RESULT: %s" % ("PASS" if failed.is_empty() else "FAIL (%s)" % ", ".join(failed)))
	quit(0 if failed.is_empty() else 1)
	return true
