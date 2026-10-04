"""cassie_raw_usd -- a CASSIE session's raw export (datasource-cassie raw_data/) -> the pen's .usda.

  python tools/cassie_raw_usd.py <raw_data/<sketch>.json> <out.usda> [--source-rev=SHA]

raw_data is the sketching app's own export, the only datasource-cassie folder not blocklisted.
The layer is the sketch as the app ended it: every stroke still alive at the end, in the order
it was drawn, from its controller inputSamples, each followed by its mirror image when the
session mirrored. The app mirrors across x = MIRROR_X in canvas space and leaves a stroke
unmirrored when it lies on that plane: planar, its plane facing x, and snapped onto the plane by
a recorded constraint. Points go to the Body frame as curves_usd does (Z negated). The layer's
expectation is the session's own result: the surface patches still alive at the end that the
app's cycle detection found.
"""
import argparse
import json
import os
import sys

import numpy as np
from blake3 import blake3

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import curves_usd as cu  # noqa: E402

MIRROR_X = 0.125
ADD_STROKE, DELETE_STROKE, ADD_PATCH, DELETE_PATCH = 1, 2, 3, 4


def samples(stroke):
    return np.array([[p["x"], p["y"], p["z"]] for p in stroke["inputSamples"]], dtype=np.float64)


def on_mirror_plane(stroke):
    P = samples(stroke)
    normal = np.linalg.svd(P - P.mean(0))[2][-1]
    snapped = any(abs(c["position"]["x"] - MIRROR_X) < 1e-6 for c in stroke["appliedPositionConstraints"])
    return bool(stroke.get("planar")) and abs(normal[0]) > 0.7 and snapped


def final_sketch(session):
    states = session["systemStates"]
    deleted = {s["elementID"] for s in states if s["interactionType"] == DELETE_STROKE}
    order = [s["elementID"] for s in states if s["interactionType"] == ADD_STROKE]
    by_id = {s["id"]: s for s in session["allSketchedStrokes"]}
    mirroring = any(s.get("mirroring") for s in states)
    strokes, names = [], []
    for sid in order:
        if sid in deleted or sid not in by_id:
            continue
        P = samples(by_id[sid])
        strokes.append(P)
        names.append("stroke_%03d" % sid)
        if mirroring and not on_mirror_plane(by_id[sid]):
            M = P.copy()
            M[:, 0] = 2.0 * MIRROR_X - M[:, 0]
            strokes.append(M)
            names.append("stroke_%03d_mirror" % sid)
    gone = {s["elementID"] for s in states if s["interactionType"] == DELETE_PATCH}
    alive = [p for p in session["allCreatedPatches"] if p["id"] not in gone and not (set(p["strokesID"]) & deleted)]
    return strokes, names, alive, len(order), len(deleted)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out")
    ap.add_argument("--source-rev", default="")
    a = ap.parse_args(argv)
    data = open(a.raw, "rb").read()
    strokes, names, alive, drawn, deleted = final_sketch(json.loads(data))
    found = sum(1 for p in alive if p["foundByAlgo"])
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
        "patches_alive": len(alive),
        "expected": json.dumps({"strokes": len(strokes), "cycles": found, "openings": 0}),
        "expected_source": "the session's patches alive at the end found by CASSIE's own cycle detection (foundByAlgo)",
        "stop_after": "AUTHOR",
    }
    text = cu.write_usda(cu.to_body([s.astype(np.float32) for s in strokes]), names, (), meta)
    open(a.out, "w", encoding="utf-8").write(text)
    print("ok %d strokes (%d drawn, %d deleted, mirrored to the final sketch), %d patches alive, %d found by CASSIE -> %s"
          % (len(strokes), drawn, deleted, len(alive), found, a.out))


if __name__ == "__main__":
    main(sys.argv[1:])
