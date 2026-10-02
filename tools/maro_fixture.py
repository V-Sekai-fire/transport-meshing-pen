# Maro (character-marocchino) as a pen fixture: body only, no wardrobe meshes.
# python tools/maro_fixture.py <Marocchino.usda> fixtures/maro fixtures/foxgirl/skeleton.obj
# Z-up metres -> Godot (x, z, -y); faces +z, left is +x; feet already on y=0.
import sys
from pxr import Usd, UsdGeom
src, out = sys.argv[1], sys.argv[2]
s = Usd.Stage.Open(src)
BODY = ["/Marocchino/Armature/Maro_Ms_Body_VRC/Noir_Ms_Stockings_HP_002", "/Marocchino/Armature/Body/Maro"]
g = lambda p: (p[0], p[2], -p[1])
V, F = [], []
for path in BODY:
    prim = s.GetPrimAtPath(path); m = UsdGeom.Mesh(prim)
    L = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(0)
    lh = m.GetOrientationAttr().Get() == "leftHanded"
    base = len(V)
    V += [g(L.Transform(p)) for p in m.GetPointsAttr().Get()]
    idx = m.GetFaceVertexIndicesAttr().Get(); k = 0
    for n in m.GetFaceVertexCountsAttr().Get():
        poly = [base + i for i in idx[k:k + n]]; k += n
        for j in range(1, n - 1):
            t = (poly[0], poly[j], poly[j + 1])
            F.append(t[::-1] if lh else t)
ymin = min(v[1] for v in V)
V = [(x, y - ymin, z) for x, y, z in V]
with open(out + "/avatar.obj", "w") as f:
    f.write("# Maro (character-marocchino usd/Marocchino.usda), body + head meshes only, no wardrobe\n")
    f.write("# USD Z-up (x,y,z) -> Godot (x,z,-y), y -= %.6g (feet on y=0)\n" % ymin)
    for v in V: f.write("v %.7g %.7g %.7g\n" % v)
    for t in F: f.write("f %d %d %d\n" % tuple(i + 1 for i in t))
from pxr import UsdSkel
sk = UsdSkel.Skeleton(s.GetPrimAtPath("/Marocchino/Armature/Armature"))
names = [n.split("/")[-1] for n in sk.GetJointsAttr().Get()]
bind = sk.GetBindTransformsAttr().Get()
L = UsdGeom.Xformable(sk.GetPrim()).ComputeLocalToWorldTransform(0)
SLOTS = ["Hips", "Chest", "Head", "Upper_arm_L", "Lower_arm_L", "LeftHand", "Upper_arm_R", "RightHand", "Lower_arm_R",
         "Upper_leg_L", "Lower_leg_L", "Foot_L", "Upper_leg_R", "Lower_leg_R", "Foot_R"]
fox = [l for l in open(sys.argv[3]) if l.startswith("l ")]
with open(out + "/skeleton.obj", "w") as f:
    f.write("# Maro bind pose, skeleton15 slot order (util/skeleton15.gd); bones copied from fixtures/foxgirl\n")
    for n in SLOTS:
        x, y, z = g(L.Transform(bind[names.index(n)].ExtractTranslation()))
        f.write("v %.7g %.7g %.7g\n" % (x, y - ymin, z))
    f.writelines(fox)
print(len(V), "verts", len(F), "tris")
