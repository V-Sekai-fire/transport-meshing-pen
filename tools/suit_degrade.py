"""The suit through an ordinary 60/120 fps camera on a lighthouse mount, degraded on purpose.

Flat-sheet test of the plain SOMA ChArUco sheet against ours (the same board with the two
position levels of tools/suit_multiscale.py on top). Each view is the sheet shrunk to the pixels
a 30 mm square gets from a corner-mounted camera, then degraded as a cheap camera degrades it:
  - matte fabric: the range squeezed to 40..200 of 255
  - motion: a hand at 1.5 m/s smeared across the shutter time (1/1000 s or 1/120 s)
  - lens: a 0.6 px defocus blur
  - sensor: Gaussian noise, sigma 6 of 255
  - video: JPEG at quality 60, standing in for a streaming codec
Reports, per view: markers read (full sheet), chessboard corners (the top 11 rows, a board in
its own right, since the full sheet repeats ids past 999), and the share of our level-1 and
level-2 windows that decode to their own place. Control: the plain sheet, degraded the same
way, must decode no level windows.
    python tools/suit_degrade.py   (run tools/suit_multiscale.py first; it writes our sheet)
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import suit_multiscale as ms  # noqa: E402
import suit_texture as st  # noqa: E402

COLS, ROWS, P = st.COLS, st.ROWS, 45
HAND = 1.5  # m/s
SHEET = "build/multiscale/charuco-suit-multiscale.png"


def degrade(img, s, shutter, seed):
    rng = np.random.default_rng(seed)
    f = cv2.resize(img, (round(img.shape[1] * s / P), round(img.shape[0] * s / P)), interpolation=cv2.INTER_AREA).astype(np.float32)
    if shutter is None:
        return f.round().clip(0, 255).astype(np.uint8)
    f = 40 + f * (160 / 255)
    smear = HAND * shutter * s / 0.03
    if smear > 1:
        n = int(np.ceil(smear))
        k = np.ones((1, n), np.float32) / n
        f = cv2.filter2D(f, -1, k, borderType=cv2.BORDER_REPLICATE)
    f = cv2.GaussianBlur(f, (0, 0), 0.6)
    f += rng.normal(0, 6, f.shape)
    f = f.round().clip(0, 255).astype(np.uint8)
    return cv2.imdecode(cv2.imencode(".jpg", f, [cv2.IMWRITE_JPEG_QUALITY, 60])[1], cv2.IMREAD_GRAYSCALE)


def levels():
    out = []
    for cell, k, seed in ((2, 4, 1), (4, 4, 2)):
        w, h = -(-COLS // cell), -(-ROWS // cell)
        m, table = ms.perfect_map(w, h, k, seed)
        out.append((cell, k, w, h, table))
    return out


def decode_levels(small, lv):
    sq = cv2.resize(small.astype(float), (COLS, ROWS), interpolation=cv2.INTER_AREA)

    def cells(c, w, h):
        pad = np.full((h * c, w * c), np.nan)
        pad[:ROWS, :COLS] = sq
        return np.nanmean(pad.reshape(h, c, w, c), axis=(1, 3))

    (_, k1, w1, h1, t1), (_, k2, w2, h2, t2) = lv
    c2 = cells(4, w2, h2)
    o2, n2 = ms.decode(c2, k2, t2)
    v = np.sort(c2.ravel())
    thr = (v[: len(v) // 4].mean() + v[-len(v) // 4:].mean()) / 2
    dark2 = (c2 < thr).repeat(2, 0).repeat(2, 1)[:h1, :w1]
    c1 = cells(2, w1, h1)
    for d in (True, False):
        sel = np.sort(c1[dark2 == d])
        c1[dark2 == d] -= (sel[: len(sel) // 4].mean() + sel[-len(sel) // 4:].mean()) / 2
    o1, n1 = ms.decode(c1, k1, t1)
    return o1 / n1, o2 / n2


def main():
    ours = cv2.imread(SHEET, cv2.IMREAD_GRAYSCALE)
    if ours is None:
        print(f"FAIL no {SHEET} (run tools/suit_multiscale.py)")
        return 1
    plain = st.board().generateImage((COLS * P, ROWS * P), marginSize=0, borderBits=1)
    d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_1000)
    R = 11
    small_board = cv2.aruco.CharucoBoard((COLS, R), 0.03, 0.022, d, np.arange((COLS * R) // 2, dtype=np.int32))
    small_board.setLegacyPattern(True)
    cdet = cv2.aruco.CharucoDetector(small_board)
    mdet = cv2.aruco.ArucoDetector(st.board().getDictionary(), cv2.aruco.DetectorParameters())
    corners_all = (COLS - 1) * (R - 1)
    lv = levels()
    print("px/square  camera            | markers plain, ours (of 1592) | corners plain, ours (of 480) | ours level 1, level 2 | control level 1, 2")
    ctrl_max = 0.0
    for s in (14, 10, 7, 6):
        for name, shutter in (("ideal", None), ("1/1000 s, cheap", 1 / 1000), ("1/120 s, cheap", 1 / 120)):
            row = []
            for img in (plain, ours):
                ids = mdet.detectMarkers(degrade(img, s, shutter, 1))[1]
                row.append(0 if ids is None else len(ids))
            for img in (plain, ours):
                crop = cv2.copyMakeBorder(img[: R * P], P, P, P, P, cv2.BORDER_CONSTANT, value=255)
                ci = cdet.detectBoard(degrade(crop, s, shutter, 2))[1]
                row.append(0 if ci is None else len(ci))
            l1, l2 = decode_levels(degrade(ours, s, shutter, 3), lv)
            c1, c2 = decode_levels(degrade(plain, s, shutter, 3), lv)
            ctrl_max = max(ctrl_max, c1, c2)
            print(f"{s:9d}  {name:16s}  | {row[0]:5d}, {row[1]:5d} | {row[2]:4d}, {row[3]:4d} | {l1:6.0%}, {l2:6.0%} | {c1:4.0%}, {c2:4.0%}")
    ok = ctrl_max < 0.05
    print("RESULT: " + ("PASS" if ok else f"FAIL (the plain sheet decoded {ctrl_max:.0%} of level windows)"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
