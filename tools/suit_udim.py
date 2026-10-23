"""Cut the ChArUco suit into panels on a body, UDIM style, then unpack the tiles.

The body has no UVs, so this gives it some, the way a suit is made: xatlas cuts the
surface into charts and lays them flat at the suit's real scale (1500 px a metre, so a
30 mm square is 45 px) in 2205 px tiles, 1.47 m on a side. Charts that do not fit spill
into the next tile, as UDIM tiles 1001, 1002 and on do. A chart that comes out flat
mirrored (its UV turn against its faces' outward winding) is flipped back, so every
marker on the body reads the right way round from outside; none is projected.

Then, as V-Sekai/fbx-udim-unpack does, each tile becomes its own material, suit_<tile>,
with its faces' UVs back in 0..1, so the engine needs no UDIM shader. Tile 1001 takes the
top 49 rows of the suit sheet (xr/suit/charuco-suit.png) and 1002 the bottom 49; further
tiles alternate.

    python tools/suit_udim.py fixtures/foxgirl/avatar.obj
      -> fixtures/foxgirl/avatar_suit.obj, xr/suit/charuco-suit_1001.png, _1002.png

It prints the tiles, the charts, and how many charts were flipped; it exits 1 if any
triangle still has its UVs turned against its winding.
"""
import os
import sys

import cv2
import numpy as np
import xatlas

TILE_PX = 2205  # 49 squares of 45 px
PX_PER_M = 1500.0
SHEET = "xr/suit/charuco-suit.png"


def read_obj(path):
    v, f = [], []
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "v":
            v.append([float(x) for x in p[1:4]])
        elif p[0] == "f":
            ids = [int(x.split("/")[0]) - 1 for x in p[1:]]
            for k in range(1, len(ids) - 1):
                f.append([ids[0], ids[k], ids[k + 1]])
    return np.array(v, np.float32), np.array(f, np.uint32)


def uv_turn(uv, tri):
    """Signed area of each UV triangle with v pointing up (positive: same turn as the faces)."""
    a, b, c = uv[tri[:, 0]], uv[tri[:, 1]], uv[tri[:, 2]]
    return (b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (c[:, 0] - a[:, 0]) * (b[:, 1] - a[:, 1])


def main():
    src = sys.argv[1]
    v, f = read_obj(src)
    atlas = xatlas.Atlas()
    atlas.add_mesh(v, f)
    po = xatlas.PackOptions()
    po.resolution = TILE_PX
    po.texels_per_unit = PX_PER_M
    po.padding = 4
    po.bilinear = True
    atlas.generate(pack_options=po)
    vmap, tri, uv = atlas[0]
    uv = np.array(uv, np.float64)
    tile, chart = (np.asarray(x).astype(np.int64) for x in atlas.get_mesh_vertex_assignment(0))
    tri = np.asarray(tri)
    # xatlas leaves faces smaller than a texel out of every chart (tile and chart 0xffffffff);
    # at 0.67 mm a texel they draw as nothing, so they are dropped. A face left out that covers
    # a texel or more would be a hole: fail.
    tri_tile = tile[tri[:, 0]]
    loose = tri_tile == 0xFFFFFFFF
    p3 = v[vmap]
    area3 = np.linalg.norm(np.cross(p3[tri[:, 1]] - p3[tri[:, 0]], p3[tri[:, 2]] - p3[tri[:, 0]]), axis=1) / 2
    holes = int((loose & (area3 > 1.0 / PX_PER_M ** 2)).sum())
    tri = tri[~loose]
    # xatlas gives v down the image; turn it up for the winding test.
    up = np.column_stack([uv[:, 0], 1.0 - uv[:, 1]])
    area = uv_turn(up, tri)
    tri_chart = chart[tri[:, 0]]
    flipped = 0
    for c in np.unique(tri_chart):
        sel = tri_chart == c
        if area[sel].sum() < 0:
            verts = np.unique(tri[sel])
            lo, hi = up[verts, 0].min(), up[verts, 0].max()
            up[verts, 0] = lo + hi - up[verts, 0]
            flipped += 1
    area = uv_turn(up, tri)
    against = int((area < 0).sum())
    tiles = sorted(set(int(t) for t in tile[tri[:, 0]]))
    base = os.path.splitext(src)[0]
    out = base + "_suit.obj"
    with open(out, "w") as o:
        o.write(f"# {os.path.basename(src)} cut into suit panels by tools/suit_udim.py; "
                f"tiles {', '.join(str(1001 + t) for t in tiles)} unpacked to one material each\n")
        for i in vmap:
            o.write("v %.7g %.7g %.7g\n" % tuple(v[i]))
        for u, w in up:
            o.write("vt %.7g %.7g\n" % (u, w))
        for t in tiles:
            o.write(f"usemtl suit_{1001 + t}\n")
            for a, b, c in tri[tile[tri[:, 0]] == t]:
                o.write(f"f {a + 1}/{a + 1} {b + 1}/{b + 1} {c + 1}/{c + 1}\n")
    sheet = cv2.imread(SHEET, cv2.IMREAD_GRAYSCALE)
    if sheet is None:
        print(f"FAIL cannot read {SHEET} (run tools/suit_texture.py first)")
        return 1
    crops = [sheet[:TILE_PX, :TILE_PX], sheet[-TILE_PX:, :TILE_PX]]
    for t in tiles:
        path = SHEET.replace(".png", f"_{1001 + t}.png")
        cv2.imwrite(path, crops[t % 2])
    print(f"{out}: {len(vmap)} vertices, {len(tri)} triangles, {atlas.chart_count} charts in "
          f"{len(tiles)} tiles ({', '.join(str(1001 + t) for t in tiles)}), {atlas.utilization:.2f} of each tile used; "
          f"{flipped} charts flipped back, {against} triangles turned against their winding; "
          f"{int(loose.sum())} faces under a texel dropped, {holes} larger faces left out")
    ok = against == 0 and holes == 0
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
