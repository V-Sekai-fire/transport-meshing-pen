# Clean-room functional spec: skin, muscle and bone layers for one body

Source read: Komaritzan, Wenninger and Botsch, "Inside Humans: Creating a Simple Layered
Anatomical Model from Human Surface Scans", Frontiers in Virtual Reality 2:694244 (2021),
doi 10.3389/frvir.2021.694244, CC BY 4.0, read 2026-10-23. No code from the authors was read.
This builds the inputs that docs/soma-muscle-cleanroom-spec.md section 2 needs: muscle and
bone bind meshes with the skin's topology, and individual muscle meshes.

## 1. The layered model (§3.2)

Three closed surfaces with ONE shared triangulation (vertex i on each corresponds):
- skin surface S;
- muscle surface M, enveloping all muscles and bones;
- skeleton surface B, enveloping the bones.
Triangle pairs give prisms: S-to-M is the fat layer, M-to-B the muscle layer. A prism splits into
three tetrahedra if a solver needs them. Head, hands and toes are excluded: there all three
layers equal the skin.

## 2. Building the template once from an anatomy atlas (§3.2.1, §3.2.2)

Inputs: an atlas with a skin surface, individual bones and individual muscles, all in one rest
pose; the body's own skin mesh fitted to the atlas skin.

Skeleton surface B:
1. Make a bone wrap W: a smooth, watertight genus-0 surface around all bones that does not dip
   into the rib cage, pelvis holes or between paired bones (shrink-wrap, remesh and smooth a
   sphere; any modelling tool).
2. Start B = S and minimise E = E_fit + w_reg E_reg.
   - E_reg (bending): sum over vertices of area x squared length of (Laplacian of the current
     vertex minus the rest Laplacian rotated by its best-fit rotation). Cotangent Laplacian,
     Voronoi areas.
   - E_fit: sum over vertices of w x squared distance to ONE target on W per vertex. Target types
     and weights: closest point 0.1, fixed correspondence 1, collision target 100. A collision
     target overrides a fixed one, which overrides a closest point.
   - Fixed correspondences, chosen once: for skin vertices within 3 cm of W, sample points in a
     geodesic neighbourhood on W and keep the one with the lowest misalignment score (how far the
     skin-to-target segment is from the pair's averaged normal); add in order of increasing
     distance, at least 5 cm apart.
   - Each iteration: if a closest-point target's misalignment exceeds 0.01 (about 8 degrees),
     move it to the best-scoring sample in its one-ring.
   - Collisions with W (exact continuous collision detection): back-track the vertex path to
     the last non-colliding state and use it as the target.
   - Schedule: w_reg starts high; on convergence, reset rest Laplacians to the current ones and
     multiply w_reg by 0.1, until a floor. Smooth fine skin detail (nipples, navel) before taking
     the first rest Laplacians.

Muscle surface M:
1. For every vertex, cast the segment from its skin vertex to its skeleton vertex; the first
   hit with the atlas muscles is its fixed target (weight 1). No hit (e.g. the knee): target the
   skeleton vertex with a lower weight.
2. Minimise the same energy; at the end project each vertex onto its skin-to-skeleton segment.
3. Keep M at least 1 mm outside B so every prism has volume.
4. Record a muscle-thickness map per vertex: the total length of that segment lying inside
   atlas muscles (the abdomen's muscle layer is mostly organs, so thickness differs from
   layer depth).

## 3. Fitting the template to another body (§3.4)

Given a new skin surface in the same topology and T-pose:
1. Scale (§3.4.1): global uniform scale by the height ratio, damped so 20% taller gives 10%
   thicker bones; then per-limb scaling along each bone (upper/lower arm, upper/lower leg, foot,
   torso) from skeleton-graph segment lengths. Lengths change, bone diameters do not.
2. Skeleton (§3.4.2): copy the new skin positions as hard constraints; solve for B minimising
   - bending E_reg on B with a high weight (near rigid, small smooth change allowed);
   - an anisotropic strain limit per skin-to-skeleton prism: deformation gradient F, polar
     decomposition F = R S, rotate into a frame whose z axis is the skin triangle normal, allow
     scaling in z within factor 5 (clamp 0.2 to 5) and penalise the rest;
   - collisions: a skeleton vertex outside the skin gets a target 2 mm under the nearest skin
     triangle, weight starting at 1 and +1 each time it stays unresolved.
   Iterate to convergence, check collisions, repeat until none (paper: under 20 rounds).
3. Muscle (§3.4.3):
   - average M: keep the template muscle shape (bending term) while each vertex stays on its
     skeleton-to-skin segment (squared distance to the segment). In the abdomen, raise the lower
     bound of the segment parameter so a belly bulge lifts the abdominal muscles.
   - minimum and maximum M: per muscle group (upper legs with buttocks, lower legs, upper arms,
     lower arms, chest, abdomen, shoulders, back) move vertices along their segment in
     proportion to the thickness map, until the thick part of the group would touch the skin
     (maximum) or the skeleton (minimum), with a per-group growth cap. Use these as targets with
     the bending term, not as direct positions.
   - final M: the blend of minimum and maximum, found by bisection, whose fat and muscle masses
     best match the target masses. Masses: layer volume x density, corrected for visceral fat
     (cavity volume change), 2 mm of skin, and muscle not in the layer (k x height^2).
4. Detail transfer (§3.4.4): triharmonic radial basis warp, phi(r) = r^3 plus a linear
   polynomial, interpolating the template-to-body displacement at farthest-point samples:
   5,000 skeleton-surface vertices for bones, 7,000 skeleton- and muscle-surface vertices for
   muscles. Solve the dense system once (LU), then warp every atlas vertex.

Solver (appendix): local/global projective solver for all three energies. Muscle fit: start
w_reg high, halve on convergence, stop when every vertex is within 0.2 mm of its segment, then
project.

## 4. Fat and muscle mass (§3.3)

The paper regresses fat and muscle mass linearly from body-shape PCA, trained on BeyondBMI
(Maalin et al. 2020). Mapping below replaces this.

## 5. Mapping onto this workspace (not from the paper)

- Atlas: the paper uses Zygote, which is commercial. Open replacement: BodyParts3D (Database
  Center for Life Science, CC BY, adult male; doi 10.18908/lsdba.nbdc00837-000), or Z-Anatomy
  built on it (CC BY-SA 4.0, share-alike binds derivatives). No female atlas found yet.
- Body: ANNY makehuman topology (19,158 vertices) as the shared triangulation; fit ANNY's rest
  skin to the atlas skin once.
- Mass targets: ANNY's own phenotype controls for muscle and weight can set the fat/muscle
  split directly, so the BeyondBMI regressor is not needed for sim bodies.
- Then every ANNY body in the sim gets its three layers by section 3, and the SOMA spec's
  muscle model trains on them.
