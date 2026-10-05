"""cassie_split -- train / validation / test splits of CASSIE's sketches, as a .usda.

  python tools/cassie_split.py <datasource-cassie>/data/raw_data <out.usda> [--rev=SHA]
  python tools/cassie_split.py --self-test

Splits the sketches of raw_data/, the app's own export and the one datasource-cassie folder
not blocklisted; a split names sketches, so it holds for every folder's copy of a sketch.
Split by group, never by file: a participant's six sketches (NN-a-b) are one group, and so
are a named object's variants (architecture, architecture-2), so no person's or subject's
strokes sit on both sides. A file byte-identical to an earlier one (large_hat is hat) is dropped. Groups are shuffled with a fixed seed
and cut 60/20/20. The sketches this work already opened (SEEN) stay in train: a set
that has been looked at cannot be held out after the fact. Test is withheld: it is
listed with each file's BLAKE3 so a later change to it is detectable, and
tools/curves_usd.py and tools/cassie_raw_usd.py refuse a test sketch without --unblind.
"""
import argparse
import os
import random
import re
import sys

from blake3 import blake3
from pxr import Sdf, Usd, UsdGeom, Vt

SEED = 20260925
SEEN = {"dress", "hat", "flower", "vintage_car"}
CUT = (0.6, 0.2)
EXT = ".json"


def group_of(name):
    m = re.match(r"^(\d{2})-\d-\d$", name)
    if m:
        return "participant-" + m.group(1)
    base = re.sub(r"-\d+$", "", name)
    return base


def split(files):
    groups = {}
    for f in sorted(files):
        groups.setdefault(group_of(f[:-len(EXT)]), []).append(f[:-len(EXT)])
    seen = sorted(g for g in groups if g in SEEN)
    rest = sorted(g for g in groups if g not in SEEN)
    random.Random(SEED).shuffle(rest)
    n_train = round(len(groups) * CUT[0]) - len(seen)
    n_val = round(len(groups) * CUT[1])
    parts = {"train": seen + rest[:n_train], "validation": rest[n_train:n_train + n_val],
             "test": rest[n_train + n_val:]}
    return {k: sorted(f for g in v for f in groups[g]) for k, v in parts.items()}, groups


def unique(raw_dir, files):
    """The files in sorted order without byte-identical copies, and each copy -> the file it repeats."""
    first, kept, dropped = {}, [], {}
    for f in sorted(files):
        h = blake3(open(os.path.join(raw_dir, f), "rb").read()).hexdigest()
        if h in first:
            dropped[f] = first[h]
        else:
            first[h] = f
            kept.append(f)
    return kept, dropped


def self_test():
    import tempfile
    d = tempfile.mkdtemp()
    for name, body in (("hat.json", b"a"), ("large_hat.json", b"a"), ("shoe.json", b"b")):
        open(os.path.join(d, name), "wb").write(body)
    checks = [("an identical copy is dropped", unique(d, os.listdir(d)) == (["hat.json", "shoe.json"], {"large_hat.json": "hat.json"})),
              ("different files are kept", unique(d, ["hat.json", "shoe.json"])[1] == {})]
    for name, ok in checks:
        print("%s %s" % ("PASS" if ok else "FAIL", name))
    return 0 if all(ok for _, ok in checks) else 1


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_dir")
    ap.add_argument("out")
    ap.add_argument("--rev", default="")
    o = ap.parse_args(argv)
    files, dropped = unique(o.raw_dir, [f for f in os.listdir(o.raw_dir) if f.endswith(EXT)])
    for f, orig in sorted(dropped.items()):
        print("dropped %s: byte-identical to %s" % (f, orig))
    parts, groups = split(files)
    stage = Usd.Stage.CreateInMemory()
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = stage.DefinePrim("/Splits", "Scope")
    stage.SetDefaultPrim(root)
    stage.GetRootLayer().customLayerData = {
        "dataset": "V-Sekai/datasource-cassie data/raw_data", "dataset_rev": o.rev, "seed": SEED,
        "rule": "group split (participant, or named subject), seeded shuffle, 60/20/20; seen sketches stay in train",
        "seen": Vt.StringArray(sorted(SEEN)), "withheld": "test",
        "duplicates_dropped": Vt.StringArray(["%s=%s" % (f[:-len(EXT)], g[:-len(EXT)]) for f, g in sorted(dropped.items())])}
    for k, fs in parts.items():
        p = stage.DefinePrim("/Splits/" + k, "Scope")
        p.CreateAttribute("files", Sdf.ValueTypeNames.StringArray, custom=True).Set(Vt.StringArray(fs))
        sums = [blake3(open(os.path.join(o.raw_dir, f + EXT), "rb").read()).hexdigest()[:12] for f in fs]
        p.CreateAttribute("blake3", Sdf.ValueTypeNames.StringArray, custom=True).Set(Vt.StringArray(sums))
        p.CreateAttribute("groups", Sdf.ValueTypeNames.Int, custom=True).Set(
            len({group_of(f) for f in fs}))
    open(o.out, "w").write(stage.GetRootLayer().ExportToString())
    print("ok %d files in %d groups: %s -> %s" % (len(files), len(groups),
          ", ".join("%s %d" % (k, len(v)) for k, v in parts.items()), o.out))
    return 0


def test_split_of(splits_path, name):
    """The split a sketch belongs to, by name with or without its extension ("" when unlisted)."""
    name = os.path.splitext(os.path.basename(name))[0]
    stage = Usd.Stage.Open(splits_path)
    for k in ("train", "validation", "test"):
        p = stage.GetPrimAtPath("/Splits/" + k)
        if p and name in list(p.GetAttribute("files").Get() or []):
            return k
    return ""


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
