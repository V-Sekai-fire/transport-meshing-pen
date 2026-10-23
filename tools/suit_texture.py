"""The body's ChArUco suit texture (weftspun RFD 2332).

The image is drawn from the SOMA suit detector's own board (edualvarado/SOMA,
01-Suit-Processing/caliboards/suit/suit.py: CharucoBoard((49, 65), 0.03, 0.022,
DICT_4X4_1000), legacy pattern), so the markers on the body are the ones that
detector reads: a sheet 1.47 by 1.95 m (30 mm squares). util/suit_body.gd cuts it
into panels on the body with the engine's xatlas.

    python tools/suit_texture.py [--px 45] [--out xr/suit/charuco-suit.png]
    python tools/suit_texture.py --read <render.png>   (markers a camera reads off a render)

Then it detects the markers in the image it wrote and exits 1 unless every
marker the board holds is read back with its own id.
"""
import argparse
import sys

import cv2
import numpy as np
import cv2.aruco as aruco

COLS, ROWS = 49, 65
SQUARE_M, MARKER_M = 0.030, 0.022


def board():
    d = aruco.getPredefinedDictionary(aruco.DICT_4X4_1000)
    # The board holds more markers than the dictionary has, and OpenCV refuses ids past
    # 999; the suit's ids wrap at 1000 (RFD 2332), so they are given wrapped.
    n = (COLS * ROWS) // 2
    b = aruco.CharucoBoard((COLS, ROWS), SQUARE_M, MARKER_M, d, np.arange(n, dtype=np.int32) % 1000)
    b.setLegacyPattern(True)
    return b


def _wrapped(d):
    w, h = COLS * SQUARE_M, ROWS * SQUARE_M
    return np.hypot(min(abs(d[0]) % w, w - abs(d[0]) % w), min(abs(d[1]) % h, h - abs(d[1]) % h))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--px", type=int, default=45, help="pixels per 30 mm square")
    ap.add_argument("--out", default="xr/suit/charuco-suit.png")
    ap.add_argument("--read", default="", help="count the suit markers read off this image and exit")
    a = ap.parse_args()
    b = board()
    if a.read:
        img = cv2.imread(a.read, cv2.IMREAD_GRAYSCALE)
        if img is None:
            print(f"FAIL cannot read {a.read}")
            return 1
        corners, ids, _ = aruco.ArucoDetector(b.getDictionary(), aruco.DetectorParameters()).detectMarkers(img)
        n = 0 if ids is None else len(ids)
        # A mirrored view decodes markers as other ids, so the markers around one on screen are
        # not its neighbours on the board. A marker passes when some marker within six of its own
        # widths on screen (its longest side, so a squashed oblique marker still reaches) lies
        # within 4.5 squares of it on the board. Board distance wraps around the image, which
        # repeats on the body; ids past 999 wrap, so an id can have two places.
        where = {}
        for i, q in zip(np.asarray(b.getIds()).ravel(), b.getObjPoints()):
            where.setdefault(int(i), []).append(np.asarray(q).reshape(4, 3).mean(0)[:2])
        flat = [] if ids is None else [int(i) for i in np.asarray(ids).ravel()]
        quads = [np.asarray(c).reshape(4, 2) for c in corners]
        centres = [q.mean(0) for q in quads]
        ok = 0
        for k in range(n):
            reach = 6.0 * max(np.linalg.norm(quads[k][i] - quads[k][(i + 1) % 4]) for i in range(4))
            for j in range(n):
                if j == k or np.linalg.norm(centres[k] - centres[j]) > reach:
                    continue
                if min(_wrapped(pa - pb) for pa in where.get(flat[k], []) for pb in where.get(flat[j], [])) <= 4.5 * SQUARE_M:
                    ok += 1
                    break
        bad = n - ok
        print(f"{a.read}: {n} suit markers read, {ok} sit beside their board neighbours, {bad} do not")
        return 1 if n == 0 or bad * 4 > n else 0
    img = b.generateImage((COLS * a.px, ROWS * a.px), marginSize=0, borderBits=1)
    if not cv2.imwrite(a.out, img):
        print(f"FAIL cannot write {a.out}")
        return 1
    want = [int(i) for i in np.asarray(b.getIds()).ravel()]
    padded = cv2.copyMakeBorder(img, a.px, a.px, a.px, a.px, cv2.BORDER_CONSTANT, value=255)
    _, ids, _ = aruco.ArucoDetector(b.getDictionary(), aruco.DetectorParameters()).detectMarkers(padded)
    got = [int(i) for i in ids.ravel()] if ids is not None else []
    expect = sorted(want)
    ok = sorted(got) == expect
    print(f"{a.out}: {img.shape[1]}x{img.shape[0]} px, {len(want)} markers on the board, "
          f"{len(got)} read back, {'all' if ok else 'NOT all'} with their own id")
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
