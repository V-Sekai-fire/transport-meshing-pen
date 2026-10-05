extends SceneTree
## CASSIE's log as the test: each committed stroke must add exactly the cycles the app logged in
## its batch, and each tap exactly the patches it logged. curvenet.elf replays; this reads the log.
##   godot --path . --script tests/cassie_events.gd [-- --split=train|validation] [-- --control]
## CASSIE_RAW_DATA overrides the raw_data dir. The test split is refused.

const ADD_STROKE := 1
const DELETE_STROKE := 2
const ADD_PATCH := 3
const SPLITS := "res://gates/S-strokes/cassie-splits.usda"

var failed := PackedStringArray()


func _initialize() -> void:
	var split := "train"
	var control := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--split="):
			split = a.trim_prefix("--split=")
		elif a == "--control":
			control = true
	if split == "test":
		print("FAIL the test split is withheld")
		quit(1)
		return
	var dir := OS.get_environment("CASSIE_RAW_DATA")
	if dir == "":
		dir = ProjectSettings.globalize_path("res://").path_join("../../6-datasource/cassie/data/raw_data")
	var names := _split_names(split)
	if names.is_empty():
		print("FAIL no %s sketches in %s" % [split, SPLITS])
		quit(1)
		return
	var stage = load("res://stages/curvenet_stage.gd").new()
	stage._ready()
	var total := 0
	var passed := 0
	for name in names:
		var text := FileAccess.get_file_as_string(dir.path_join(name + ".json"))
		if text == "":
			print("FAIL %s: no %s" % [name, dir.path_join(name + ".json")])
			failed.append(name)
			continue
		var logged := logged_events(JSON.parse_string(text))
		if control:
			for state in logged:
				if not logged[state].is_empty():
					logged[state].append([-1])
					break
		var added := _parse(stage.session_events(text))
		if added.has("error"):
			print("FAIL %s: %s" % [name, added["error"]])
			failed.append(name)
			continue
		var ok := 0
		for state in logged:
			var want: Array = logged[state]
			var got: Array = added.get(state, [])
			if want == got:
				ok += 1
			else:
				print("FAIL %s state %d: logged %s, replay added %s" % [name, state, want, got])
		for state in added:
			if not logged.has(state):
				print("FAIL %s state %d: the replay reports an event the log has none for" % [name, state])
		total += logged.size()
		passed += ok
		print("%s %s: %d of %d events" % ["PASS" if ok == logged.size() else "FAIL", name, ok, logged.size()])
		if ok != logged.size():
			failed.append(name)
	stage.free()
	print("RESULT: %s %d of %d events match the log over %d %s sketches" % [
			"PASS" if failed.is_empty() else "FAIL", passed, total, names.size(), split])
	quit(0 if failed.is_empty() else 1)


## What the app logged per event, keyed by system state index: a committed stroke's batch of
## algorithm patches, or a tap's patches (consecutive user patches with one timestamp).
static func logged_events(session: Dictionary) -> Dictionary:
	var patches := {}
	for p in session["allCreatedPatches"]:
		patches[int(p["id"])] = p
	var states: Array = session["systemStates"]
	var out := {}
	var pending := []
	var i := 0
	while i < states.size():
		var st: Dictionary = states[i]
		var kind := int(st["interactionType"])
		var next := i + 1
		if kind == ADD_PATCH and patches[int(st["elementID"])]["foundByAlgo"]:
			pending.append(_ids(patches[int(st["elementID"])]["strokesID"]))
		elif kind == ADD_PATCH:
			var group := [_ids(patches[int(st["elementID"])]["strokesID"])]
			while next < states.size() and int(states[next]["interactionType"]) == ADD_PATCH \
					and not patches[int(states[next]["elementID"])]["foundByAlgo"] and states[next]["time"] == st["time"]:
				group.append(_ids(patches[int(states[next]["elementID"])]["strokesID"]))
				next += 1
			group.sort()
			out[i] = group
		elif kind == ADD_STROKE or kind == DELETE_STROKE:
			if kind == ADD_STROKE:
				pending.sort()
				out[i] = pending
			pending = []
		i = next
	return out


func _parse(text: String) -> Dictionary:
	var out := {}
	if text.begins_with("error") or text.begins_with("FAIL"):
		return {"error": text.strip_edges()}
	for line in text.split("\n", false):
		var parts := line.split("\t")
		var cycles := []
		if parts.size() > 1 and parts[1] != "":
			for c in parts[1].split(";"):
				cycles.append(Array(c.split(",")).map(func(x): return int(x)))
		cycles.sort()
		out[int(parts[0])] = cycles
	return out


static func _ids(ids: Array) -> Array:
	var out := []
	for x in ids:
		if not out.has(int(x)):
			out.append(int(x))
	out.sort()
	return out


func _split_names(split: String) -> PackedStringArray:
	var text := FileAccess.get_file_as_string(SPLITS)
	var at := text.find('def Scope "%s"' % split)
	if at < 0:
		return PackedStringArray()
	var files := text.find("files = [", at) + "files = [".length()
	var end := text.find("]", files)
	var out := PackedStringArray()
	for item in text.substr(files, end - files).split(","):
		var n := item.strip_edges().trim_prefix('"').trim_suffix('"')
		if n != "":
			out.append(n)
	return out
