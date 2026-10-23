"""The body's ChArUco suit texture (weftspun RFD 2332).

The image is drawn from the SOMA suit detector's own board (edualvarado/SOMA,
01-Suit-Processing/caliboards/suit/suit.py: CharucoBoard((49, 65), 0.03, 0.022,
DICT_4X4_1000), legacy pattern), so the markers on the body are the ones that
detector reads. The body has no UVs, so the pen projects the image triplanar at
its real size, 1.47 by 1.95 m (30 mm squares).

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
        _, ids, _ = aruco.ArucoDetector(b.getDictionary(), aruco.DetectorParameters()).detectMarkers(img)
        n = 0 if ids is None else len(ids)
        print(f"{a.read}: {n} suit markers read")
        return 0
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
