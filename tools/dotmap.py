"""Prototype: our own suit pattern, a two-level dot map (no ChArUco).

Calm on purpose: a regular field of small grey dots on off-white, like dot paper. Each dot sits
off its grid point in one of four directions (up, right, down, left), so it carries 2 bits, as
in Anoto's pen paper. Every 4 by 4 window of dots is unique on the sheet, also against the
other windows turned or mirrored, so any surviving patch names its own place and orientation,
and a mirrored view decodes nowhere.
  fine:   dark dots every 10 mm, 3 mm across, 2 mm offset; a 40 mm patch gives the place
  coarse: pale grey discs every 40 mm, 18 mm across, 8 mm offset, under the fine dots; a 160 mm
          patch, read from far off
The two levels are apart in tone and size: the fine reader keeps only detail (the image minus
its blur), the coarse reader only the blur, so neither sees the other. Sheet 1.47 by 1.95 m at
1500 px a metre.

Flat-sheet test only: no body, no seams, no perspective; distance by area downsampling, and
the reader is told the grid (a body needs a fitted local lattice).
    python tools/dotmap.py [--out build/dotmap]
"""
import argparse
import os
import sys

import cv2
import numpy as np

PX_M = 1500
W_PX, H_PX = 2205, 2925
PAPER, INK, PALE = 235, 80, 185
FINE = dict(pitch=0.010, r=0.0015, off=0.0020)
COARSE = dict(pitch=0.040, r=0.0090, off=0.0080)
K = 4
DIRS = np.array([[0, -1], [1, 0], [0, 1], [-1, 0]])  # up, right, down, left (image axes)
GAP = 4


def _forms(win):
    """The window's 8 views (4 turns, mirrored or not), each as bytes; win holds 0-3 or GAP."""
    out = []
    w = win
    for mirror in (False, True):
        if mirror:
            w = win[:, ::-1].copy()
            m = (w == 1) | (w == 3)
            w[m] = 4 - w[m]  # right <-> left
        v = w
        for _ in range(4):
            out.append(v.tobytes())
            v = np.rot90(v, -1).copy()  # a quarter turn clockwise
            m = v != GAP
            v[m] = (v[m] + 1) % 4
    return out


def make_map(nx, ny, gaps, seed):
    rng = np.random.default_rng(seed)
    s = rng.integers(0, 4, (ny, nx)).astype(np.uint8)
    s[gaps] = GAP
    for _ in range(100000):
        owner, clash = {}, None
        for y in range(ny - K + 1):
            for x in range(nx - K + 1):
                for j, f in enumerate(_forms(s[y:y + K, x:x + K])):
                    if f in owner and owner[f] != (x, y):
                        clash = (x, y)
                        break
                    owner.setdefault(f, (x, y))
                if clash:
                    break
            if clash:
                break
        if clash is None:
            table = {s[y:y + K, x:x + K].tobytes(): (x, y) for y in range(ny - K + 1) for x in range(nx - K + 1)}
            return s, table
        x, y = clash
        free = [(yy, xx) for yy in range(y, y + K) for xx in range(x, x + K) if s[yy, xx] != GAP]
        yy, xx = free[rng.integers(len(free))]
        s[yy, xx] = (s[yy, xx] + 1 + rng.integers(3)) % 4
    raise SystemExit("no unique map found")


def draw(sheet, sym, lvl, step, tone):
    pitch = lvl["pitch"] * PX_M
    for (y, x), v in np.ndenumerate(sym):
        if v == GAP:
            continue
        cx = (x + 0.5) * step * FINE["pitch"] * PX_M + DIRS[v][0] * lvl["off"] * PX_M
        cy = (y + 0.5) * step * FINE["pitch"] * PX_M + DIRS[v][1] * lvl["off"] * PX_M
        cv2.circle(sheet, (int(cx * 16), int(cy * 16)), int(lvl["r"] * PX_M * 16), tone, -1, cv2.LINE_AA, 4)


def read(img, scale, lvl, step, shape, coarse):
    """Symbols the reader sees for one level of a flat, axis-aligned sheet (-1 where none)."""
    ny, nx = shape
    fine_px = FINE["pitch"] * PX_M * scale
    f = img.astype(np.float32)
    if coarse:
        # A closing (max then min) wider than a fine dot erases the fine dots and keeps the
        # discs; the paper level is the wide blur of what is left.
        k = max(1, int(round(2 * FINE["r"] * PX_M * scale * 1.6)) | 1)
        c = cv2.morphologyEx(f, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
        x = cv2.GaussianBlur(c, (0, 0), max(3.0 * COARSE["pitch"] * PX_M * scale, 2.0), borderType=cv2.BORDER_REPLICATE) - c
    else:
        # Detail only: a fine dot against its own surroundings, disc or paper.
        x = cv2.GaussianBlur(f, (0, 0), max(fine_px, 1.0)) - f
    x = np.clip(x, 0, None)
    if x.max() <= 0:
        return np.full(shape, -1, int)
    x8 = (255 * x / x.max()).astype(np.uint8)
    _, bw = cv2.threshold(x8, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    n, _, stats, cent = cv2.connectedComponentsWithStats(bw)
    out = np.full(shape, -1, int)
    best = np.zeros(shape)
    cell = fine_px * step
    want = np.pi * (lvl["r"] * PX_M * scale) ** 2
    for i in range(1, n):
        a = stats[i, cv2.CC_STAT_AREA]
        if a < 0.25 * want or a > 4.0 * want + 4:
            continue
        p = cent[i] / cell - 0.5
        g = np.rint(p).astype(int)
        if not (0 <= g[0] < nx and 0 <= g[1] < ny) or a <= best[g[1], g[0]]:
            continue
        d = (p - g) * cell
        if np.linalg.norm(d) < lvl["off"] * PX_M * scale / 2:
            continue
        best[g[1], g[0]] = a
        out[g[1], g[0]] = int(np.argmax(DIRS @ d))
    return out


def score(seen, sym, table):
    ny, nx = sym.shape
    right = claimed = tot = 0
    for y in range(ny - K + 1):
        for x in range(nx - K + 1):
            w = seen[y:y + K, x:x + K].copy()
            gaps = sym[y:y + K, x:x + K] == GAP
            w[gaps] = GAP
            if (w < 0).any():
                continue
            tot += 1
            at = table.get(w.astype(np.uint8).tobytes())
            claimed += at is not None
            right += at == (x, y)
    return right, claimed, (ny - K + 1) * (nx - K + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/dotmap")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    fx, fy = round(W_PX / (FINE["pitch"] * PX_M)), round(H_PX / (FINE["pitch"] * PX_M))
    cx, cy = -(-fx // 4), -(-fy // 4)
    fine, ftab = make_map(fx, fy, np.zeros((fy, fx), bool), 1)
    coarse, ctab = make_map(cx, cy, np.zeros((cy, cx), bool), 2)
    sheet = np.full((H_PX, W_PX), PAPER, np.uint8)
    draw(sheet, coarse, COARSE, 4, PALE)
    draw(sheet, fine, FINE, 1, INK)
    cv2.imwrite(f"{a.out}/dotmap-suit.png", sheet)
    print(f"fine {fx}x{fy} dots, coarse {cx}x{cy}; every {K}x{K} window unique under turns and mirroring")
    print("px per 10 mm | fine windows right/placed/all | coarse windows right/placed/all | mirrored: placed")
    ok = True
    for px10 in (15, 7.5, 5, 3.75, 2.5, 1.5, 1.0, 0.75, 0.5):
        s = px10 / 15.0
        small = cv2.resize(sheet, (round(W_PX * s), round(H_PX * s)), interpolation=cv2.INTER_AREA)
        rf, pf, nf = score(read(small, s, FINE, 1, fine.shape, False), fine, ftab)
        rc, pc, nc = score(read(small, s, COARSE, 4, coarse.shape, True), coarse, ctab)
        flip = small[:, ::-1]
        _, mf, _ = score(read(flip, s, FINE, 1, fine.shape, False), fine, ftab)
        _, mc, _ = score(read(flip, s, COARSE, 4, coarse.shape, True), coarse, ctab)
        print(f"{px10:12} | {rf:5d}/{pf:5d}/{nf} | {rc:4d}/{pc:4d}/{nc} | {mf + mc}")
        ok &= pf == rf and pc == rc and mf + mc == 0
        if px10 == 15:
            ok &= rf == nf and rc == nc
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
