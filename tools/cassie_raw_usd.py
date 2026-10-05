"""cassie_raw_usd -- a CASSIE session's raw export (datasource-cassie raw_data/) -> the pen's .usda.

  python tools/cassie_raw_usd.py <raw_data/<sketch>.json> <out.usda> [--source-rev=SHA]
  python tools/cassie_raw_usd.py --self-test

raw_data is the sketching app's own export, the only datasource-cassie folder not blocklisted.
The layer is the sketch as the app ended it: every stroke still alive at the end, in the order
it was drawn, as the app's own beautified curve (ctrlPts), each followed by its mirror image when
the session mirrored. The app mirrors across x = MIRROR_X in canvas space and leaves a stroke
unmirrored when it lies on that plane: planar, its plane facing x, and snapped onto the plane by
a recorded constraint. Each stroke carries the junctions the app recorded for it (its applied
intersection constraints), which the replay joins the graph at. Points go to the Body frame as
curves_usd does (Z negated), then PLACEMENT seats them on the avatar body (the session stays in canvas space).

The expectation is the number of cycles the app's algorithm had at the end. The export logs every
patch it ever created and not the ones it dropped, so a found patch counts unless it was deleted,
lost a stroke to deletion, or was split: a later stroke has two or more patches in its batch
(the patches logged while it was committed, just before its ADD_STROKE) that contain it and
together hold all of the earlier patch's strokes. A mirror stroke's id is its original's
plus one, so deleting a stroke deletes its mirror, and a stroke splits with its mirror too.

The layer also carries the session subset the CASSIE graph port replays ("session", numbers in
the app's own spelling) and the alive patches as sorted stroke-id lists ("expected_cycles").
"""
import argparse
import decimal
import json
import os
import sys

import numpy as np

MIRROR_X = 0.125
ADD_STROKE, DELETE_STROKE, ADD_PATCH, DELETE_PATCH = 1, 2, 3, 4
SAMPLES_PER_SEGMENT = 64
# Body-frame similarity that seats the dress on fixtures/foxgirl/avatar.obj: q = (p - centre) * scale + to.
# Keypoints from STARFORGED-STD-3001 Appendix E, Table E.2-1 (50th %ile female), scaled to the
# avatar's 1.70 m stature: crotch at stature less sitting height (158.5 - 83.5 cm) = 0.804 m, and
# hip breadth 37.5 cm = 0.402 m. Waist height is not in Appendix E: 99/158.5 of stature (ISO 7250
# typical) = 1.062 m. The dress is 0.407 m wide at the hip line, a width scale of 0.989, so it is
# placed at its drawn size: a translation putting its waist (narrowest section, y 1.23) on the body
# waist and its mirror plane on the midline. The collision guest moves what then collides.
PLACEMENT = {"centre": [0.125, 1.23, -0.204], "scale": [1.0, 1.0, 1.0], "to": [0.0, 1.062, -0.007],
             "keypoints": {"crotch": 0.804, "waist": 1.062, "hip_breadth": 0.402, "stature": 1.70},
             "body": "fixtures/foxgirl/avatar.obj"}


def samples(stroke):
    return np.array([[p["x"], p["y"], p["z"]] for p in stroke["inputSamples"]], dtype=np.float64)


def curve(stroke):
    P = np.array([[p["x"], p["y"], p["z"]] for p in stroke["ctrlPts"]], dtype=np.float64)
    t = np.linspace(0.0, 1.0, SAMPLES_PER_SEGMENT)[:, None]
    if len(P) == 2:
        return P[0] + (P[1] - P[0]) * t
    if (len(P) - 1) % 3:
        raise ValueError("stroke %d: %d control points is not a cubic Bezier chain" % (stroke["id"], len(P)))
    pieces = []
    for i in range(0, len(P) - 1, 3):
        a, b, c, d = P[i:i + 4]
        seg = (1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t ** 2 * c + t ** 3 * d
        pieces.append(seg if i == 0 else seg[1:])
    return np.vstack(pieces)


def junctions(stroke):
    return np.array([[c["position"][k] for k in "xyz"] for c in stroke["appliedPositionConstraints"]
                     if c["isIntersection"]], dtype=np.float64).reshape(-1, 3)


def on_mirror_plane(stroke):
    P = samples(stroke)
    normal = np.linalg.svd(P - P.mean(0))[2][-1]
    snapped = any(abs(c["position"]["x"] - MIRROR_X) < 1e-6 for c in stroke["appliedPositionConstraints"])
    return bool(stroke.get("planar")) and abs(normal[0]) > 0.7 and snapped


def mirror(P):
    M = P.copy()
    M[:, 0] = 2.0 * MIRROR_X - M[:, 0]
    return M


def final_sketch(session):
    states = session["systemStates"]
    deleted = {s["elementID"] for s in states if s["interactionType"] == DELETE_STROKE}
    order = [s["elementID"] for s in states if s["interactionType"] == ADD_STROKE]
    by_id = {s["id"]: s for s in session["allSketchedStrokes"]}
    mirroring = any(s.get("mirroring") for s in states)
    strokes, names, joins = [], [], []
    for sid in order:
        if sid in deleted or sid not in by_id:
            continue
        P, J = curve(by_id[sid]), junctions(by_id[sid])
        strokes.append(P)
        joins.append(J)
        names.append("stroke_%03d" % sid)
        if mirroring and not on_mirror_plane(by_id[sid]):
            strokes.append(mirror(P))
            joins.append(mirror(J))
            names.append("stroke_%03d_mirror" % sid)
    return strokes, names, joins, len(order), len(deleted)


def alive_patches(session):
    """{found, deleted, deleted_stroke, split, alive}: the found patches the app still had at the end."""
    seq = [(s["interactionType"], s["elementID"]) for s in session["systemStates"]
           if s["interactionType"] in (ADD_STROKE, DELETE_STROKE, ADD_PATCH, DELETE_PATCH)]
    patches = {p["id"]: p for p in session["allCreatedPatches"]}
    # The app logs a stroke's patches while committing it, just before its ADD_STROKE.
    batch, owner, stroke_at, pending = {}, {}, {}, []
    for i, (kind, e) in enumerate(seq):
        if kind == ADD_PATCH:
            pending.append(e)
        elif kind == ADD_STROKE:
            stroke_at.setdefault(e, i)
            batch[e] = pending
            owner.update((q, e) for q in pending)
            pending = []
        elif kind == DELETE_STROKE:
            pending = []
    del_s = {e for kind, e in seq if kind == DELETE_STROKE}
    del_s |= {e + 1 for e in del_s}
    del_p = {e for kind, e in seq if kind == DELETE_PATCH}
    out = {"found": 0, "deleted": 0, "deleted_stroke": 0, "split": 0, "alive": 0, "alive_strokes": []}
    for p in patches.values():
        if not p["foundByAlgo"]:
            continue
        out["found"] += 1
        P = set(p["strokesID"])
        t = stroke_at[owner[p["id"]]] if p["id"] in owner else -1
        if p["id"] in del_p:
            out["deleted"] += 1
            continue
        if P & del_s:
            out["deleted_stroke"] += 1
            continue
        split = False
        for s, ids in batch.items():
            if stroke_at[s] <= t:
                continue
            qs = [set(patches[q]["strokesID"]) for q in ids if {s, s + 1} & set(patches[q]["strokesID"])]
            if len(qs) >= 2 and P <= set().union(*qs):
                split = True
                break
        if split:
            out["split"] += 1
            continue
        out["alive"] += 1
        out["alive_strokes"].append(sorted(set(p["strokesID"])))
    return out


def with_junction_vertices(strokes, joins, tol=1e-4):
    """Each stroke with every junction lying on it (within tol) inserted as a vertex, at the
    junction's own coordinates, so a later per-point move keeps the junction on both strokes."""
    every = np.vstack([j for j in joins if len(j)]) if any(len(j) for j in joins) else np.zeros((0, 3))
    out = []
    for P in strokes:
        a, b = P[:-1], P[1:]
        ab = b - a
        inserts = {}
        for q in every:
            t = np.clip(np.einsum('ij,ij->i', q - a, ab) / np.maximum(np.einsum('ij,ij->i', ab, ab), 1e-30), 0, 1)
            dist = np.linalg.norm(a + ab * t[:, None] - q, axis=1)
            k = int(np.argmin(dist))
            if dist[k] <= tol:
                inserts.setdefault(k, []).append((float(t[k]), q))
        rows = []
        for k in range(len(P)):
            rows.append(P[k])
            for _, q in sorted(inserts.get(k, []), key=lambda e: e[0]):
                rows.append(q)
        out.append(np.array(rows, dtype=P.dtype))
    return out


def place(points):
    """PLACEMENT on Body-frame points; strokes and junctions take the same move, so junctions stay on their strokes."""
    c = np.asarray(PLACEMENT["centre"], np.float64)
    t = np.asarray(PLACEMENT["to"], np.float64)
    return ((np.asarray(points, np.float64) - c) * np.asarray(PLACEMENT["scale"], np.float64) + t).astype(np.float32)


def raw_json(v):
    """JSON with each number in its source spelling (parsed as Decimal), so the guest reads the app's floats."""
    if isinstance(v, dict):
        return "{" + ",".join(json.dumps(k) + ":" + raw_json(x) for k, x in v.items()) + "}"
    if isinstance(v, list):
        return "[" + ",".join(raw_json(x) for x in v) + "]"
    if isinstance(v, decimal.Decimal):
        return str(v)
    return json.dumps(v)


def session_subset(data):
    """What the graph port's session replay reads, in canvas space; it mirrors on its own."""
    raw = json.loads(data, parse_float=decimal.Decimal)
    states = [{k: st[k] for k in ("interactionType", "elementID", "mirroring", "canvasScale", "time")}
              for st in raw["systemStates"]]
    added = {st["elementID"] for st in states if st["interactionType"] == ADD_STROKE}
    keep = ("position", "isIntersection", "isAtExistingNode", "isAtNewEndpoint")
    strokes = [{"id": s["id"], "ctrlPts": s["ctrlPts"], "closedLoop": s["closedLoop"], "planar": s["planar"],
                "appliedPositionConstraints": [{k: c[k] for k in keep} for c in s["appliedPositionConstraints"]],
                "rejectedPositionConstraints": [{k: c[k] for k in keep} for c in s["rejectedPositionConstraints"]]}
               for s in raw["allSketchedStrokes"] if s["id"] in added]
    patches = [{k: p[k] for k in ("id", "foundByAlgo", "strokesID")} for p in raw["allCreatedPatches"]]
    return raw_json({"systemStates": states, "allSketchedStrokes": strokes, "allCreatedPatches": patches})


def self_test():
    def log(states, patches):
        return {"systemStates": [{"interactionType": k, "elementID": e} for k, e in states],
                "allCreatedPatches": [{"id": i, "foundByAlgo": True, "strokesID": s} for i, s in patches]}
    S, D, P = ADD_STROKE, DELETE_STROKE, ADD_PATCH
    checks = [
        ("unsplit patch is kept", log([(S, 1), (S, 2), (S, 3), (P, 10), (S, 4)], [(10, [1, 2, 3, 4])]), 1),
        ("split patch is dropped", log([(S, 1), (S, 2), (S, 3), (P, 10), (S, 4), (P, 11), (P, 12), (S, 5)],
                                       [(10, [1, 2, 3, 4]), (11, [1, 2, 5, 3]), (12, [3, 4, 5, 1])]), 2),
        ("siblings of one stroke do not split each other",
         log([(S, 1), (S, 2), (S, 3), (P, 10), (P, 11), (S, 4)], [(10, [1, 2, 4]), (11, [2, 3, 4])]), 2),
        ("a neighbour sharing two strokes does not split",
         log([(S, 1), (S, 2), (S, 3), (P, 10), (S, 4), (S, 5), (P, 11), (S, 6)],
             [(10, [1, 2, 3, 4]), (11, [2, 3, 5, 6])]), 2),
        ("a stroke and its mirror split a patch three ways",
         log([(S, 1), (S, 2), (S, 3), (S, 4), (P, 10), (S, 5), (P, 11), (P, 12), (P, 13), (S, 6)],
             [(10, [1, 2, 3, 4, 5]), (11, [1, 2, 6, 7]), (12, [3, 6]), (13, [4, 5, 7])]), 3),
        ("a deleted stroke drops its patches", log([(S, 1), (S, 2), (P, 10), (S, 3), (D, 2)], [(10, [1, 2, 3])]), 0),
    ]
    bad = 0
    for name, session, want in checks:
        got = alive_patches(session)["alive"]
        ok = got == want
        bad += not ok
        print("%s %s: alive %d, want %d" % ("PASS" if ok else "FAIL", name, got, want))
    return bad


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--source-rev", default="")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--unblind", action="store_true", help="convert a withheld test-split sketch anyway")
    a = ap.parse_args(argv)
    if a.self_test:
        sys.exit(1 if self_test() else 0)
    from blake3 import blake3
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import curves_usd as cu
    from cassie_split import test_split_of
    if not os.path.exists(cu.SPLITS):
        sys.exit("no %s: the split decides whether %s is withheld" % (cu.SPLITS, a.raw))
    if test_split_of(cu.SPLITS, a.raw) == "test" and not a.unblind:
        sys.exit("%s is in the withheld test split (%s); pass --unblind to convert it" % (a.raw, cu.SPLITS))
    data = open(a.raw, "rb").read()
    session = json.loads(data)
    strokes, names, joins, drawn, deleted = final_sketch(session)
    counts = alive_patches(session)
    strokes = with_junction_vertices(strokes, joins)
    body = cu.to_body([s.astype(np.float32) for s in strokes])
    body_joins = cu.to_body([j.astype(np.float32) for j in joins])
    body = [place(b) for b in body]
    body_joins = [place(j) for j in body_joins]
    meta = {
        "converter": "transport-meshing-pen tools/cassie_raw_usd.py",
        "source": os.path.basename(a.raw),
        "source_folder": "raw_data",
        "source_blake3": blake3(data).hexdigest()[:12],
        "source_rev": a.source_rev,
        "flip": "z",
        "mirror_x": MIRROR_X,
        "strokes_drawn": drawn,
        "strokes_deleted": deleted,
        "expected": json.dumps({"strokes": len(strokes), "cycles": counts["alive"], "openings": 0}),
        "expected_source": ("found patches the app still had at the end: %(found)d found, less %(deleted)d deleted, "
                            "%(deleted_stroke)d with a deleted stroke, %(split)d split by a later stroke" % counts),
        "crossings": "recorded",
        "body_snap": False,
        "placement": json.dumps(PLACEMENT),
        "body_fit": "mujoco",
        "body_axis_z": -0.003,
        "body_clearance": 0.004,
        "session": session_subset(data),
        "expected_cycles": json.dumps(sorted(counts["alive_strokes"])),
        "junctions": json.dumps([[[round(float(v), 7) for v in p] for p in j] for j in body_joins]),
    }
    text = cu.write_usda(body, names, (), meta)
    open(a.out, "w", encoding="utf-8").write(text)
    print("ok %d strokes (%d drawn, %d deleted, mirrored to the final sketch), %d junctions; %s -> %s"
          % (len(strokes), drawn, deleted, sum(len(j) for j in joins), meta["expected_source"], a.out))


if __name__ == "__main__":
    main(sys.argv[1:])
