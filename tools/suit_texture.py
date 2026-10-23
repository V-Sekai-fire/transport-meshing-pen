"""The body's ChArUco suit texture (weftspun RFD 2332).

The image is drawn from the SOMA suit detector's own board (edualvarado/SOMA,
01-Suit-Processing/caliboards/suit/suit.py: CharucoBoard((49, 65), 0.03, 0.022,
DICT_4X4_1000), legacy pattern), so the markers on the body are the ones that
detector reads: a sheet 1.47 by 1.95 m (30 mm squares). util/suit_body.gd cuts it
into panels on the body with the engine's xatlas.

    python tools/suit_texture.py [--px 45] [--out xr/suit/charuco-suit.png]
    python tools/suit_texture.py --read <render.png> [--truth <truth.png>]
        (markers a camera reads off a render; with the truth render, whether each is the right one)

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


def _printed(sheet):
    """{(col, row): id} of the sheet as printed, read off the sheet image itself."""
    img = cv2.imread(sheet, cv2.IMREAD_GRAYSCALE)
    if img is None:
        return None
    px = img.shape[1] / COLS
    corners, ids, _ = aruco.ArucoDetector(board().getDictionary(), aruco.DetectorParameters()).detectMarkers(img)
    out = {}
    for c, i in zip(corners, np.asarray(ids).ravel()):
        x, y = np.asarray(c).reshape(4, 2).mean(0) / px
        out[(int(x), int(y))] = int(i)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--px", type=int, default=45, help="pixels per 30 mm square")
    ap.add_argument("--out", default="xr/suit/charuco-suit.png")
    ap.add_argument("--read", default="", help="count the suit markers read off this image and exit")
    ap.add_argument("--truth", default="", help="with --read: probe_suit.gd's truth render of the same view")
    a = ap.parse_args()
    b = board()
    if a.read:
        img = cv2.imread(a.read, cv2.IMREAD_GRAYSCALE)
        if img is None:
            print(f"FAIL cannot read {a.read}")
            return 1
        corners, ids, _ = aruco.ArucoDetector(b.getDictionary(), aruco.DetectorParameters()).detectMarkers(img)
        n = 0 if ids is None else len(ids)
        if not a.truth:
            print(f"{a.read}: {n} suit markers read")
            return 1 if n == 0 else 0
        # Each marker is judged on its own, as SOMA's tracker uses it: the truth render names the
        # suit square under every pixel, and a marker passes when its id is the one the board
        # prints in the square under its centre. A mirrored panel or a flipped image decodes other
        # ids there; a seam between panels does not matter.
        truth = cv2.imread(a.truth, cv2.IMREAD_COLOR)
        if truth is None or truth.shape[:2] != img.shape:
            print(f"FAIL truth {a.truth} missing or not the render's size")
            return 1
        tb, tg, tr = (truth[:, :, k].astype(int) for k in range(3))
        body = tb > 128
        col = np.clip(np.rint((tr - 2) / 5.0), 0, COLS - 1).astype(int)
        row = np.clip(np.rint((tg - 1.5) / 3.0), 0, ROWS - 1).astype(int)
        printed = _printed(a.out)
        if printed is None:
            print(f"FAIL cannot read the sheet {a.out}")
            return 1
        ok = 0
        for c, i in zip(corners, [] if ids is None else np.asarray(ids).ravel()):
            x, y = np.rint(np.asarray(c).reshape(4, 2).mean(0)).astype(int)
            ys, xs = slice(max(y - 2, 0), y + 3), slice(max(x - 2, 0), x + 3)
            m = body[ys, xs]
            if not m.any():
                continue
            sq = (int(np.median(col[ys, xs][m])), int(np.median(row[ys, xs][m])))
            if printed.get(sq) == int(i):
                ok += 1
        # Markers in view: printed squares that cover at least a 10 by 10 px patch of the render.
        key = np.where(body, row * COLS + col, -1)
        vals, counts = np.unique(key[key >= 0], return_counts=True)
        seen = sum(1 for v, k in zip(vals, counts) if k >= 100 and (int(v) % COLS, int(v) // COLS) in printed)
        print(f"{a.read}: {seen} markers in view, {n} read, {ok} are the marker the UV map puts there, {n - ok} are not")
        return 1 if n == 0 or (n - ok) * 10 > n else 0
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
