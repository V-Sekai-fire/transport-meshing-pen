extends SceneTree
## Topological face matching against the recorded dress, through the rebuilt curvenet.elf's replay.
##   godot --headless --path <meshing-pen with the rebuilt curvenet.elf> --script tools/test_session_topology.gd
const Topology := preload("res://tools/session_topology.gd")
var failed := 0

func _check(name: String, ok: bool) -> void:
	print(("PASS  " if ok else "FAIL  "), name)
	if not ok:
		failed += 1

func _initialize() -> void:
	var stage = load("res://stages/curvenet_stage.gd").new()
	stage._ready()
	var text: String = stage.session_replay(FileAccess.get_file_as_string(OS.get_environment("DRESS_JSON")))
	var lines := text.strip_edges().split("\n")
	var faces := []
	for i in range(1, lines.size()):
		var parts := lines[i].split(" |")
		faces.append({"key": parts[0].strip_edges(), "edges": Topology.edge_set(parts[1])})
	print("port faces: ", faces.size())
	# the rectangle the log never records as removed
	var c: Array = Topology.cover("8 32 34 66", faces)
	print("cover of 8 32 34 66: ", c)
	_check("the rectangle is covered by port faces", not c.is_empty())
	# control: without the strip on the 32 side the rectangle is not covered
	var fewer := faces.filter(func(f): return not (c.size() > 0 and f.key == c[c.size() - 1]))
	_check("control: dropping one covering face leaves it uncovered", Topology.cover("8 32 34 66", fewer).is_empty())
	# control: a stroke set no faces bound is not covered
	_check("control: an invented face is not covered", Topology.cover("8 32 34 99", faces).is_empty())
	# control: a face already in the port is not its own cover
	_check("control: a present face is not covered by itself", not Topology.cover("8 34 66 74", faces).has("8 34 66 74"))
	# the log's expected faces for the dress (alive patches after the last event), as the layer lists them
	var want: Array = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("EXPECTED_JSON")))
	var keys := want.map(func(c): return " ".join(c.map(func(v): return str(int(v)))))
	var cmp: Dictionary = Topology.compare(keys, Array(lines.slice(1)))
	print("covered ", cmp.covered.keys(), " uncovered ", cmp.uncovered, " unexplained ", cmp.unexplained)
	_check("the dress passes: every expected face matched or covered, none unexplained", cmp.uncovered.is_empty() and cmp.unexplained.is_empty())
	# control: an extra expected face that nothing covers fails
	var bad := keys.duplicate()
	bad.append("2 4 6 99")
	_check("control: an expected face nothing bounds is uncovered", not Topology.compare(bad, Array(lines.slice(1))).uncovered.is_empty())
	# control: a port face that no expected face explains fails
	var fewer_keys := keys.filter(func(k): return k != keys[0])
	_check("control: a port face left unexplained is reported", not Topology.compare(fewer_keys, Array(lines.slice(1))).unexplained.is_empty())
	print("RESULT: ", "PASS" if failed == 0 else "FAIL (%d)" % failed)
	quit(1 if failed else 0)
