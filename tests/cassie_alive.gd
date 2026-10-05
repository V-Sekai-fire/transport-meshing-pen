extends SceneTree
## Cases for util/cassie_alive.gd, synthetic and on datasource-cassie's dress.json.
##   godot --path . --script tests/cassie_alive.gd   (CASSIE_RAW_DATA overrides the raw_data dir)

const S := CassieAlive.ADD_STROKE
const D := CassieAlive.DELETE_STROKE
const P := CassieAlive.ADD_PATCH

var failed := PackedStringArray()


func _initialize() -> void:
	# Stroke 6 and its mirror 7 cut patch 10 three ways; no two of 11, 12, 13 hold all of 10.
	var three_way := _log([[S, 1], [S, 2], [S, 3], [S, 4], [P, 10], [S, 5], [P, 11], [P, 12], [P, 13], [S, 6]],
			[[10, [1, 2, 3, 4, 5]], [11, [1, 2, 6, 7]], [12, [3, 6]], [13, [4, 5, 7]]])
	_check("three-way split is dropped", _alive(three_way), [[1, 2, 6, 7], [3, 6], [4, 5, 7]])
	_check("pair split is dropped", _alive(_log([[S, 1], [S, 2], [S, 3], [P, 10], [S, 4], [P, 11], [P, 12], [S, 5]],
			[[10, [1, 2, 3, 4]], [11, [1, 2, 5, 3]], [12, [3, 4, 5, 1]]])), [[1, 2, 3, 5], [1, 3, 4, 5]])
	_check("siblings of one stroke do not split each other", _alive(_log([[S, 1], [S, 2], [S, 3], [P, 10], [P, 11], [S, 4]],
			[[10, [1, 2, 4]], [11, [2, 3, 4]]])), [[1, 2, 4], [2, 3, 4]])
	# The app found one half of a cut and the user patched the other by hand: the log cannot show
	# the old patch went, so it stays counted (dress stroke 74, the open case on #6).
	_check("one-sided cut keeps the old patch", _alive(_log([[S, 1], [S, 2], [S, 3], [S, 4], [P, 10], [S, 5], [P, 11], [S, 6], [P, 12], [S, 7]],
			[[10, [1, 2, 3, 4]], [11, [1, 3, 4, 6]], [12, [2, 3, 4, 6]]], [12])), [[1, 2, 3, 4], [1, 3, 4, 6]])
	_check("user patches are not counted", _alive(_log([[S, 1], [S, 2], [S, 3], [P, 10], [S, 4]], [[10, [1, 2, 3, 4]]], [10])), [])
	_check("a deleted stroke drops its patches", _alive(_log([[S, 1], [S, 2], [P, 10], [S, 3], [D, 2]], [[10, [1, 2, 3]]])), [])
	_dress()
	print("RESULT: ", "PASS" if failed.is_empty() else "FAIL " + ", ".join(failed))
	quit(0 if failed.is_empty() else 1)


func _dress() -> void:
	var dir := OS.get_environment("CASSIE_RAW_DATA")
	if dir == "":
		dir = ProjectSettings.globalize_path("res://").path_join("../../6-datasource/cassie/data/raw_data")
	var text := FileAccess.get_file_as_string(dir.path_join("dress.json"))
	if text == "":
		print("FAIL dress: no %s (set CASSIE_RAW_DATA)" % dir.path_join("dress.json"))
		failed.append("dress")
		return
	var d: Dictionary = JSON.parse_string(text)
	var a := CassieAlive.alive_patches(d)
	_check("dress counts", [a["found"], a["deleted"], a["deleted_stroke"], a["split"], a["alive"]], [225, 9, 42, 72, 102])
	var alive_sets: Array = a["alive_strokes"]
	_check("dress stroke 144 splits patch 111 three ways",
			alive_sets.has([48, 49, 64, 65, 110, 111, 112, 113, 124, 125, 130, 131, 132, 133, 142, 143]), false)
	_check("dress stroke 188 splits patch 112 three ways",
			alive_sets.has([64, 65, 130, 131, 132, 133, 142, 143, 144, 145]), false)
	var patches := {}
	for p in d["allCreatedPatches"]:
		patches[int(p["id"])] = p
	var batch := []
	var pending := []
	for s in d["systemStates"]:
		if int(s["interactionType"]) == P:
			pending.append(int(s["elementID"]))
		elif int(s["interactionType"]) == S:
			if int(s["elementID"]) == 74:
				for q in pending:
					batch.append(_sorted(patches[q]["strokesID"]))
				batch.sort()
			pending = []
	_check("dress stroke 74 finds one side only", batch, [[8, 34, 66, 74], [8, 35, 67, 75], [33, 35, 67, 75]])
	var hand := []
	for p in patches.values():
		if not p["foundByAlgo"]:
			hand.append(_sorted(p["strokesID"]))
	_check("dress: the user patched stroke 74's other side by hand", hand.has([32, 34, 66, 86]), true)


func _log(states: Array, patches: Array, user: Array = []) -> Dictionary:
	var st := []
	for k in states:
		st.append({"interactionType": k[0], "elementID": k[1]})
	var ps := []
	for p in patches:
		ps.append({"id": p[0], "foundByAlgo": not user.has(p[0]), "strokesID": p[1]})
	return {"systemStates": st, "allCreatedPatches": ps}


func _alive(session: Dictionary) -> Array:
	var out: Array = CassieAlive.alive_patches(session)["alive_strokes"]
	out.sort()
	return out


func _sorted(ids: Array) -> Array:
	var out := []
	for x in ids:
		if not out.has(int(x)):
			out.append(int(x))
	out.sort()
	return out


func _check(name: String, got, want) -> void:
	var ok: bool = got == want
	print("%s %s: got %s, want %s" % ["PASS" if ok else "FAIL", name, str(got), str(want)])
	if not ok:
		failed.append(name)
