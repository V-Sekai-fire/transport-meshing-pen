class_name CassieAlive
## The found patches a CASSIE session still had at the end, from its raw_data export.
## A found patch counts unless it was deleted, lost a stroke (or its mirror, id + 1) to deletion,
## or was split: a later stroke's batch holds two or more patches touching that stroke or its
## mirror whose strokes together cover the earlier patch's.

const ADD_STROKE := 1
const DELETE_STROKE := 2
const ADD_PATCH := 3
const DELETE_PATCH := 4


static func alive_patches(session: Dictionary) -> Dictionary:
	var seq := []
	for s in session["systemStates"]:
		var kind := int(s["interactionType"])
		if kind in [ADD_STROKE, DELETE_STROKE, ADD_PATCH, DELETE_PATCH]:
			seq.append([kind, int(s["elementID"])])
	var patches := {}
	for p in session["allCreatedPatches"]:
		patches[int(p["id"])] = p
	var batch := {}
	var owner := {}
	var stroke_at := {}
	var pending := []
	for i in seq.size():
		var kind: int = seq[i][0]
		var e: int = seq[i][1]
		if kind == ADD_PATCH:
			pending.append(e)
		elif kind == ADD_STROKE:
			if not stroke_at.has(e):
				stroke_at[e] = i
			batch[e] = pending
			for q in pending:
				owner[q] = e
			pending = []
		elif kind == DELETE_STROKE:
			pending = []
	var del_s := {}
	var del_p := {}
	for k in seq:
		if k[0] == DELETE_STROKE:
			del_s[k[1]] = true
			del_s[k[1] + 1] = true
		elif k[0] == DELETE_PATCH:
			del_p[k[1]] = true
	var out := {"found": 0, "deleted": 0, "deleted_stroke": 0, "split": 0, "alive": 0, "alive_strokes": []}
	for id in patches:
		var p: Dictionary = patches[id]
		if not p["foundByAlgo"]:
			continue
		out["found"] += 1
		var strokes := _id_set(p["strokesID"])
		if del_p.has(id):
			out["deleted"] += 1
			continue
		if strokes.keys().any(func(s): return del_s.has(s)):
			out["deleted_stroke"] += 1
			continue
		var t: int = stroke_at[owner[id]] if owner.has(id) else -1
		if _split(strokes, t, batch, stroke_at, patches):
			out["split"] += 1
			continue
		out["alive"] += 1
		var sorted_ids: Array = strokes.keys()
		sorted_ids.sort()
		out["alive_strokes"].append(sorted_ids)
	return out


static func _split(strokes: Dictionary, t: int, batch: Dictionary, stroke_at: Dictionary, patches: Dictionary) -> bool:
	for s in batch:
		if stroke_at[s] <= t:
			continue
		var cover := {}
		var touching := 0
		for q in batch[s]:
			var qs := _id_set(patches[q]["strokesID"])
			if qs.has(s) or qs.has(s + 1):
				touching += 1
				cover.merge(qs)
		if touching >= 2 and strokes.keys().all(func(x): return cover.has(x)):
			return true
	return false


static func _id_set(ids: Array) -> Dictionary:
	var d := {}
	for x in ids:
		d[int(x)] = true
	return d
