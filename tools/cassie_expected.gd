# A saved sketch's expected cycles from CASSIE's own sketch graph (cassie_graph.elf, godot-cassie's
# CassieSketchGraph::find_cycles), so the loop's expectation comes from CASSIE, not from curvenet.
#   godot --headless --path . --xr-mode off --script tools/cassie_expected.gd -- --strokes=tools/strokes/dress.usda [--merge=0.01]
# Prints one line: strokes, strokes the graph took, nodes, edges, cycles. --merge is CASSIE's merge
# epsilon (mergeConstraintsThreshold, 0.01 x canvasScale); 0 keeps the graph's own default.
extends SceneTree

const StrokesUsd := preload("res://util/strokes_usd.gd")
const UsdStage := preload("res://stages/usd_stage.gd")
const CassieGraph := preload("res://stages/cassie_graph_stage.gd")


func _arg(name: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var usd = UsdStage.new()
	root.add_child(usd)
	var graph = CassieGraph.new()
	root.add_child(graph)
	var path := _arg("strokes", "res://tools/strokes/dress.usda")
	var saved: Dictionary = StrokesUsd.from_file(usd, path)
	if saved.has("error"):
		print("FAIL %s: %s" % [path, saved.error])
		quit(1)
		return
	if not graph.ensure():
		print("FAIL cassie_graph.elf: %s" % graph.reason)
		quit(1)
		return
	var r: Dictionary = graph.cycles(saved.strokes, float(_arg("merge", "0")))
	if r.has("error"):
		print("FAIL cg_cycles: %s" % r.error)
		quit(1)
		return
	print("CASSIE %s: strokes %d, added %d, nodes %d, edges %d, cycles %d (merge %s)" % [path.get_file(), saved.strokes.size(),
			int(r.get("strokes_added", -1)), int(r.get("nodes", -1)), int(r.get("edges", -1)), int(r.get("cycles", -1)), _arg("merge", "0")])
	quit(0)
