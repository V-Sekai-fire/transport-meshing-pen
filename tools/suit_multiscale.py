"""Prototype: the SOMA ChArUco suit with coarser position levels laid over it (RFD 2332).

The bit level stays as it is: the same board, the same 22 mm DICT_4X4_1000 markers, so SOMA's
detector still reads the sheet. On top, each cell of a perfect map (every k by k window of bits
appears once on the sheet) shifts its squares' brightness: bit 1 dims the white, bit 0 lifts the
black, so a marker keeps 255 - DIM of contrast either way. Cells are even blocks of squares, so
each holds as many black squares as white and the chessboard averages out:
  level 1: 2 by 2 squares (60 mm) a bit, 4 by 4 windows (240 mm patch names its place)
  level 2: 4 by 4 squares (120 mm) a bit, 4 by 4 windows (480 mm patch)
OpenCV's adaptive threshold subtracts the local mean, so the slow brightness shift does not move
a marker's bits; seen from far off the markers blur to grey and only the levels remain.

This is a flat-sheet test: no body, no seams, no perspective. Distance is simulated by area
downsampling. It reports, per scale, the markers read and the share of map windows that decode
to their own place.
    python tools/suit_multiscale.py [--out build/multiscale]
"""
import argparse
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import suit_texture as st  # noqa: E402

COLS, ROWS = st.COLS, st.ROWS
PX = 45
DIM1, DIM2 = 25, 50  # how far each level's bit moves the brightness (of 255)


def perfect_map(w, h, k, seed):
    """w by h bits, every k by k window distinct (random search with repair)."""
    rng = np.random.default_rng(seed)
    m = rng.integers(0, 2, (h, w), dtype=np.uint8)
    for _ in range(200000):
        seen, dup = {}, None
        for y in range(h - k + 1):
            for x in range(w - k + 1):
                key = m[y:y + k, x:x + k].tobytes()
                if key in seen:
                    dup = (x, y)
                    break
                seen[key] = (x, y)
            if dup:
                break
        if dup is None:
            return m, seen
        x, y = dup
        m[y + rng.integers(k), x + rng.integers(k)] ^= 1
    raise SystemExit("no perfect map found")


def decode(cells, k, table):
    """Share of k by k windows of a sensed cell grid that decode to their own place. The flat
    sheet is lit evenly, so one threshold (the midpoint of the two brightness clusters) serves."""
    h, w = cells.shape
    v = np.sort(cells.ravel())
    thr = (v[: len(v) // 4].mean() + v[-len(v) // 4:].mean()) / 2
    ok = tot = 0
    for y in range(h - k + 1):
        for x in range(w - k + 1):
            bits = (cells[y:y + k, x:x + k] < thr).astype(np.uint8)
            tot += 1
            ok += table.get(bits.tobytes()) == (x, y)
    return ok, tot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/multiscale")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    b = st.board()
    base = b.generateImage((COLS * PX, ROWS * PX), marginSize=0, borderBits=1)
    levels = []
    for cell, k, seed in ((2, 4, 1), (4, 4, 2)):
        w, h = -(-COLS // cell), -(-ROWS // cell)
        m, table = perfect_map(w, h, k, seed)
        levels.append((cell, k, w, h, m, table))
    up = lambda m, c: m.repeat(c, 0).repeat(c, 1)[:ROWS, :COLS]
    b1 = up(levels[0][4], 2).astype(float)
    b2 = up(levels[1][4], 4).astype(float)
    # Level 2 moves the brightness twice as far as level 1, so a far view sees it first.
    dim = DIM1 * b1 + DIM2 * b2
    lift = DIM1 * (1 - b1) + DIM2 * (1 - b2)
    big = lambda a: cv2.resize(a, (COLS * PX, ROWS * PX), interpolation=cv2.INTER_NEAREST)
    white = base > 127
    sheet = np.where(white, 255 - big(dim), big(lift)).round().astype(np.uint8)
    cv2.imwrite(f"{a.out}/charuco-suit-multiscale.png", sheet)
    det = cv2.aruco.ArucoDetector(b.getDictionary(), cv2.aruco.DetectorParameters())
    print("levels: " + "; ".join(f"{c * 30} mm cells, {w}x{h} bits, {k}x{k} windows unique" for c, k, w, h, _, _ in levels))
    print("px per square | markers read (plain, multiscale) | level 1 windows | level 2 windows")
    worst = 0
    for s in (45, 15, 9, 6, 4, 3, 2, 1, 0.5):
        size = (int(COLS * s), int(ROWS * s))
        res = []
        for img in (base, sheet):
            ids = det.detectMarkers(cv2.resize(img, size, interpolation=cv2.INTER_AREA))[1]
            res.append(0 if ids is None else len(ids))
        small = cv2.resize(sheet, size, interpolation=cv2.INTER_AREA).astype(float)
        # The reader's view of each 30 mm square (the view is on the sheet's grid), then the
        # mean of each level's cell; the coarse level is read first and taken out of the fine one.
        sq = cv2.resize(small, (COLS, ROWS), interpolation=cv2.INTER_AREA)
        def cells(c, w, h):
            pad = np.full((h * c, w * c), np.nan)
            pad[:ROWS, :COLS] = sq
            return np.nanmean(pad.reshape(h, c, w, c), axis=(1, 3))
        c1w, c1h, c2w, c2h = levels[0][2], levels[0][3], levels[1][2], levels[1][3]
        c2 = cells(4, c2w, c2h)
        o2, u = decode(c2, 4, levels[1][5])
        dark2 = (c2 < np.median(c2)).repeat(2, 0).repeat(2, 1)[:c1h, :c1w]
        c1 = cells(2, c1w, c1h)
        for v in (True, False):
            sel = c1[dark2 == v]
            c1[dark2 == v] -= (np.sort(sel)[: len(sel) // 4].mean() + np.sort(sel)[-len(sel) // 4:].mean()) / 2
        o1, t_ = decode(c1, 4, levels[0][5])
        dec = [f"{o1:4d}/{t_}", f"{o2:4d}/{u}"]
        print(f"{s:13} | {res[0]:4d}, {res[1]:4d} | {dec[0]} | {dec[1]}")
        if s == 45:
            worst = res[0] - res[1]
    # Control: the plain sheet has no levels, so its windows must not decode to their places.
    sq = cv2.resize(base.astype(float), (COLS, ROWS), interpolation=cv2.INTER_AREA)
    pad = np.full((levels[1][3] * 4, levels[1][2] * 4), np.nan)
    pad[:ROWS, :COLS] = sq
    c2 = np.nanmean(pad.reshape(levels[1][3], 4, levels[1][2], 4), axis=(1, 3))
    ctrl, ctot = decode(c2, 4, levels[1][5])
    print(f"control, plain sheet: level 2 windows {ctrl}/{ctot}")
    ok = worst == 0 and ctrl * 10 < ctot
    print("RESULT: " + ("PASS" if ok else f"FAIL (markers lost at full size {worst}, control decoded {ctrl})"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
