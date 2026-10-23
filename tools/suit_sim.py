"""Degrade the suit renders as a cheap 60/120 fps camera would, and score them (sim-to-real).

Reads build/suit-sim/renders/<avatar>-<yaw>-<plain|ours>.png and -truth.png (tools/suit_sim.sh)
and writes, per render and camera, the degraded frame beside its truth render plus one row of
frames.tsv: the dataset. Cameras:
  ideal          the render as is
  fast           1/1000 s shutter: matte fabric (range 40..200), 0.6 px defocus, noise 6, JPEG 60
  normal         1/120 s: the same plus a hand at 1.5 m/s smeared across the shutter
Scores, per frame, the visible suit squares (truth render) identified two ways:
  markers  the square holds a marker the detector read, with the id the board prints there
  levels   the square lies in a level window (60 mm cells, 4 by 4) that decodes to its own place
The levels are read off each 60 mm cell's contrast, (white - black) / (white + black) of its
squares, which shading scales away; four contrast classes give the two level bits. The cell grid
comes from the truth render, which a real reader must find itself (from markers or corners).
Control: the plain sheet carries no levels, so its level windows must not decode.
    python tools/suit_sim.py [build/suit-sim]
"""
import csv
import zlib
import glob
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import suit_multiscale as ms  # noqa: E402
import suit_texture as st  # noqa: E402

COLS, ROWS, P = st.COLS, st.ROWS, 45
M_PER_PX = 6.0 / 1920  # 90 degree lens, 3 m out
CAMERAS = {"ideal": None, "fast": 1 / 1000, "normal": 1 / 120}


def degrade(img, shutter, seed):
    if shutter is None:
        return img
    rng = np.random.default_rng(seed)
    f = 40 + img.astype(np.float32) * (160 / 255)
    n = int(round(1.5 * shutter / M_PER_PX))
    if n > 1:
        f = cv2.filter2D(f, -1, np.ones((1, n), np.float32) / n, borderType=cv2.BORDER_REPLICATE)
    f = cv2.GaussianBlur(f, (0, 0), 0.6) + rng.normal(0, 6, f.shape)
    f = f.round().clip(0, 255).astype(np.uint8)
    return cv2.imdecode(cv2.imencode(".jpg", f, [cv2.IMWRITE_JPEG_QUALITY, 60])[1], cv2.IMREAD_GRAYSCALE)


def truth_grid(truth):
    b, g, r = (truth[:, :, k].astype(int) for k in range(3))
    body = b > 128
    col = np.clip(np.rint((r - 2) / 5.0), 0, COLS - 1).astype(int)
    row = np.clip(np.rint((g - 1.5) / 3.0), 0, ROWS - 1).astype(int)
    return np.where(body, row * COLS + col, -1)


def white_squares(plain):
    return np.array([[plain[y * P + 3, x * P + 3] > 127 for x in range(COLS)] for y in range(ROWS)])


def square_values(img, key, white, min_px=6):
    """Per visible square: its white level (90th percentile) or black level (median)."""
    vals = np.full((ROWS, COLS), np.nan)
    flat, k = img.ravel().astype(float), key.ravel()
    order = np.argsort(k)
    k, flat = k[order], flat[order]
    starts = np.searchsorted(k, np.arange(-1, ROWS * COLS + 1))
    for sq in range(ROWS * COLS):
        a, b = starts[sq + 1], starts[sq + 2]
        if b - a < min_px:
            continue
        y, x = divmod(sq, COLS)
        px = flat[a:b]
        vals[y, x] = np.percentile(px, 90) if white[y, x] else np.median(px)
    return vals


def kmeans1d(x, k=4, it=50):
    c = np.quantile(x, (np.arange(k) + 0.5) / k)
    for _ in range(it):
        lab = np.argmin(np.abs(x[:, None] - c[None]), 1)
        c = np.array([x[lab == j].mean() if (lab == j).any() else c[j] for j in range(k)])
    order = np.argsort(c)
    return np.argsort(order)[np.argmin(np.abs(x[:, None] - c[None]), 1)]


def levels_identified(vals, white, maps):
    (w1, h1, t1), (w2, h2, t2) = maps
    pad = lambda a, c, w, h: np.pad(a, ((0, h * c - ROWS), (0, w * c - COLS)), constant_values=np.nan)
    v, wh = pad(vals, 2, w1, h1), np.pad(white, ((0, h1 * 2 - ROWS), (0, w1 * 2 - COLS)))
    cw = np.full((h1, w1), np.nan)
    for y in range(h1):
        for x in range(w1):
            blk, m = v[2 * y:2 * y + 2, 2 * x:2 * x + 2], wh[2 * y:2 * y + 2, 2 * x:2 * x + 2]
            W, B = blk[m], blk[~m]
            W, B = W[~np.isnan(W)], B[~np.isnan(B)]
            if len(W) and len(B):
                cw[y, x] = (W.mean() - B.mean()) / (W.mean() + B.mean() + 1e-6)
    known = ~np.isnan(cw)
    if known.sum() < 8:
        return np.zeros((ROWS, COLS), bool), 0, 0
    cls = np.full((h1, w1), -1)
    cls[known] = kmeans1d(cw[known])
    # Contrast rises with the dim: (b1, b2) = (0,0) < (1,0) < (0,1) < (1,1).
    b1 = np.where(cls >= 0, np.array([0, 1, 0, 1])[cls.clip(0)], -1)
    b2c = np.where(cls >= 0, np.array([0, 0, 1, 1])[cls.clip(0)], -1)
    ok = np.zeros((h1, w1), bool)
    right = placed = 0
    for y in range(h1 - 3):
        for x in range(w1 - 3):
            win = b1[y:y + 4, x:x + 4]
            if (win < 0).any():
                continue
            at = t1.get(win.astype(np.uint8).tobytes())
            placed += at is not None
            if at == (x, y):
                right += 1
                ok[y:y + 4, x:x + 4] = True
    ok_sq = ok.repeat(2, 0).repeat(2, 1)[:ROWS, :COLS]
    return ok_sq, right, placed


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "build/suit-sim"
    os.makedirs(f"{root}/frames", exist_ok=True)
    plain = cv2.imread("xr/suit/charuco-suit.png", cv2.IMREAD_GRAYSCALE)
    white = white_squares(plain)
    printed = st._printed("xr/suit/charuco-suit.png")
    maps = []
    for cell, seed in ((2, 1), (4, 2)):
        w, h = -(-COLS // cell), -(-ROWS // cell)
        maps.append((w, h, ms.perfect_map(w, h, 4, seed)[1]))
    det = cv2.aruco.ArucoDetector(st.board().getDictionary(), cv2.aruco.DetectorParameters())
    rows, ctrl_right, ctrl_windows = [], 0, 0
    print("view                 camera | squares visible | by markers | by levels | level windows right/placed")
    for path in sorted(glob.glob(f"{root}/renders/*-*-*.png")):
        name = os.path.basename(path)[:-4]
        if name.endswith("-truth"):
            continue
        truth = cv2.imread(f"{root}/renders/{name}-truth.png", cv2.IMREAD_COLOR)
        key = truth_grid(truth)
        vis = np.zeros(ROWS * COLS, bool)
        sqs, cnt = np.unique(key[key >= 0], return_counts=True)
        vis[sqs[cnt >= 6]] = True
        vis = vis.reshape(ROWS, COLS)
        render = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        for cam, shutter in CAMERAS.items():
            img = degrade(render, shutter, zlib.crc32((name + cam).encode()))
            cv2.imwrite(f"{root}/frames/{name}-{cam}.png", img)
            by_m = np.zeros((ROWS, COLS), bool)
            corners, ids, _ = det.detectMarkers(img)
            for c, i in zip(corners, [] if ids is None else np.asarray(ids).ravel()):
                x, y = np.rint(np.asarray(c).reshape(4, 2).mean(0)).astype(int)
                k = key[max(y - 2, 0):y + 3, max(x - 2, 0):x + 3]
                k = k[k >= 0]
                if len(k):
                    sq = int(np.median(k))
                    if printed.get((sq % COLS, sq // COLS)) == int(i):
                        by_m[sq // COLS, sq % COLS] = True
            ok_sq, right, placed = levels_identified(square_values(img, key, white), white, maps)
            by_l = ok_sq & vis
            if name.endswith("-plain"):
                ctrl_right, ctrl_windows = ctrl_right + right, ctrl_windows + placed
            print(f"{name:20s} {cam:6s} | {vis.sum():15d} | {by_m.sum():10d} | {by_l.sum():9d} | {right}/{placed}")
            rows.append([f"frames/{name}-{cam}.png", f"renders/{name}-truth.png", name.rsplit("-", 1)[1], cam,
                         int(vis.sum()), int(by_m.sum()), int(by_l.sum()), right, placed])
    with open(f"{root}/frames.tsv", "w", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["frame", "truth", "sheet", "camera", "squares_visible", "by_markers", "by_levels",
                    "level_windows_right", "level_windows_placed"])
        w.writerows(rows)
    print(f"control, plain sheet: {ctrl_right} level windows decoded to their place")
    print(f"dataset: {len(rows)} frames in {root}/frames, with frames.tsv")
    ok = ctrl_right == 0 and len(rows) > 0
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
