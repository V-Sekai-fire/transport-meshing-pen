# Clean-room functional spec: muscle and skin layers from surface markers

Source read: Alvarado, Kim, Nolte, Runte, Botsch, Habermann and Theobalt, "SOMA: From Surface
Observations to Muscle Anatomy", ECCV 2026, arXiv 2606.09246 (main paper and supplement, HTML,
read 2026-10-23). Nothing from the authors' repository was read for this spec. The implementer
works from this file only and must not open that repository.

Section numbers below (§) are the paper's; "S§" is the supplement's.

## 1. What it does

From a skeletal pose, predict how one person's muscle layer and skin surface deform beyond plain
linear blend skinning (LBS): muscle bulging, joint-volume loss, skin sliding. It is trained per
subject on tracked suit-marker positions. At run time it needs only the pose (§7).

It is subject-specific. It does not model force or co-contraction at a fixed joint angle (§6).
There is no in-vivo muscle ground truth; muscle shape is constrained by priors, not measured
(§5.1).

## 2. Inputs per subject (§3.2, §3.3, S§1.5)

- Skin bind mesh S_bind: the subject's scan in rest T-pose, wearing the suit. Paper: 23,752
  vertices, 47,500 faces.
- Muscle bind mesh M_bind and bone bind mesh B_bind: inner layers with the SAME topology as
  S_bind (vertex i on each layer corresponds). The paper gets them from a separate volumetric
  fitting method (Komaritzan, Wenninger and Botsch 2021, "Inside Humans"); that method is a
  dependency, not part of this spec.
- Individual muscle meshes M_bind^m, each in rest shape (paper total: 320,256 vertices).
- LBS weights for the skin mesh, shared by all three layers; a skeleton of J joints.
- Canonical marker cloud P_bind: one 3D point per marker corner on S_bind, with each corner's
  triangle and barycentric coordinates on S_bind, and LBS weights interpolated the same way.
- Marker-to-muscle map: from each marker point, cast a ray along the negative surface normal;
  the first individual muscle it hits owns that marker (§3.3).

Building P_bind (§3.2, S§1.4): unwrap the textured scan to a 2D atlas, detect markers in the
atlas, map each detected corner back to its 3D triangle by barycentric coordinates. Markers
split by atlas seams are not detected; the paper fills them by hand with a tool that accepts a
marker's four corners on different UV islands. Marker identity: dictionary id m, instance
index i in {0, 1} for ids used twice, corner c in {0..3} (S§1.1).

## 3. Training data per frame (§3.4, §3.5, S§2)

1. Detect marker corners in every camera; triangulate corners seen by two or more cameras by
   minimising multi-view reprojection error (eq. 1).
2. Clean the 3D tracks:
   - Fill gaps of at most 2 frames by linear interpolation, in 2D per camera and in 3D.
   - Temporal median filter, odd window w (w not given).
   - Outlier rejection per marker: compare its centroid displacement since the previous frame
     with the median displacement of its K nearest marker centroids; drop it if the difference
     exceeds tau_out (K and tau_out not given).
3. Pose theta_t: per-joint 6D rotation, from the capture system (paper: Captury markerless
   mocap, separate from the suit).
4. Residual per tracked corner k: pose its canonical point with LBS (eq. 3), subtract that from
   the observed point, and rotate the difference back into the rest frame by the inverse of the
   weight-blended joint rotation sum_j w_kj R_j (eq. 4). Record a visibility mask per corner.

Paper data: 5 subjects, about 45 min each at 25 Hz, 120 cameras, about 266K triangulated
frames; mean corner coverage 82%, 65% (push-ups) to 95% (tricep extension) (S§1.5, S§5).

## 4. Model (§4.1, S§3.1)

- Pose feature r*: for each non-root joint, its relative rotation matrix minus identity,
  flattened (9 x (J - 1)). Paper: 23 non-root joints, 207 inputs.
- Two networks of the same shape, each mapping r* to a displacement per vertex (3N outputs):
  - Psi_M gives D_musc, the muscle layer's canonical displacement.
  - Psi_S gives D_res, the skin's residual on top of the muscle.
- Network: encoder of two fully connected layers (512, 1024), a 1024 bottleneck, a decoder that
  mirrors the encoder, encoder features concatenated into the matching decoder layer, GELU,
  1D batch norm, dropout 0.1, final linear projection to 3N.
- Layers:
  - muscle: M_pred = M_bind + D_musc
  - skin: S_pred(canonical) = S_bind + D_musc + D_res, then posed by LBS with the shared
    weights.
  - bone layer B_bind is not displaced; it bounds the muscle volume.
- Individual muscles (S§7): bind every vertex u of each individual muscle to its closest triangle
  on M_bind (barycentric b_u); at run time u' = u + sum b_j D_musc(vertex j).

## 5. Loss (§4.2, §4.3, S§3.1, S§4)

E_total = lambda_data E_data + E_smooth + E_bi + E_stretch + E_tang + E_vol; each regulariser
is summed over the muscle layer (acting on D_musc) and the skin layer (acting on D_res).

| Term | Definition | Weight muscle | Weight skin |
| --- | --- | --- | --- |
| E_data | mean over visible corners of squared distance between predicted canonical residual (barycentric blend of D_musc + D_res at the corner's triangle) and measured residual | 50 (one weight) | |
| E_smooth | squared norm of sqrt(M^-1) L D: uniform Laplacian L, diagonal Voronoi-area mass M | 100 | 200 |
| E_bi | biharmonic: squared M^-1-norm of L M^-1 L D | 100 | 200 |
| E_stretch | sum over edges of w_uv (current length - rest length)^2, w_uv = one third of the two incident triangle areas, normalised to sum 1 | 1000 | 1000 |
| E_tang | sum over vertices of vertex area x squared tangential part of the displacement (component orthogonal to the rest normal) | 1.0 | 0.1 |
| E_vol | mean over valid prisms of (V - V0)^2 / (abs(V0) + eps) | 1000 | 1000 |

E_vol prisms: one prism per triangle between two layers with shared topology. Skin layer: the
prism between skin and muscle (subcutaneous), evaluated in canonical space. Muscle layer: the
prism between muscle and bone (deep tissue), evaluated in POSED space, so the network learns
bulges that undo LBS volume loss. Use SIGNED volume, so layer inversion gives a negative volume
and a large penalty. Degenerate prisms are skipped; eps and the validity rule are not given.

Signed prism volume, exact (S§4): with the bottom triangle x1, x2, x3 and the top x4, x5, x6,
and J(alpha, beta, xi) the 3x3 matrix of columns
  d/dalpha = xi (x1 - x3) + (1 - xi)(x4 - x6)
  d/dbeta  = xi (x2 - x3) + (1 - xi)(x5 - x6)
  d/dxi    = alpha (x1 - x4) + beta (x2 - x5) + (1 - alpha - beta)(x3 - x6)
V = (det J(w1) + det J(w2)) / 4, with w1, w2 = (1/3, 1/3, (1 -/+ sqrt(1/3)) / 2).

Training: Adam, learning rate 1e-4 constant, 20 epochs, batch 128 frames, gradient clipping at
norm 1.0, end to end.

## 6. Evaluation (§5, S§3.2)

On held-out motion sequences:
- MPME, MedPME, P90: mean, median and 90th-percentile Euclidean marker error (mm), predicted
  posed skin at the marker against the tracked marker.
- DRE at tau 15, 20, 25 mm: the same error, only over markers whose plain-LBS error exceeds tau.
- Intersection ratio: share of inner-layer vertices outside the outer layer (skin to muscle,
  muscle to bone).
- Volume change: mean abs(V - V0) / V0 in percent, per layer pair.
- Baselines: plain LBS of the bind meshes (must be beaten on MedPME, P90, DRE; it has a
  falsely low intersection because layers collapse together).

Paper's numbers, full model: MPME 13.43, MedPME 11.51, P90 19.20, DRE>25 64.52 mm (LBS 134.28);
volume change 1.37% subcutaneous, 10.35% deep. Linear blendshapes and an MLP fit the markers
almost as well (MPME 16.52, 14.03); the U-Net matters most for volume (§5.4).

## 7. Not given in the paper (the implementer chooses, and records the choice)

- Median window w, K and tau_out of the outlier filter.
- eps and the degenerate-prism rule in E_vol; whether layer meshes need a minimum thickness.
- Initialisation, normalisation of inputs and outputs, train/validation split.
- How the network's 3N output is laid out against the mesh (vertex order).

## 8. Mapping onto this workspace (not from the paper)

- Body: ANNY with the SOMA-X rig on the makehuman topology (19,158 vertices) in place of a scan.
  Pose input becomes 76 non-root joints x 9 = 684 features.
- Missing: muscle and bone bind layers with ANNY's topology, and individual muscle meshes. The
  paper's source for these is a separate method ("Inside Humans"); reading that paper is a
  second clean-room source.
- Sim: renders of the suit on ANNY posed by Kimodo give marker tracks with exact truth. The skin
  must deform beyond LBS for there to be a residual to learn; SOMA-X's pose correctives are the
  candidate source.
- Frontier success check: the §6 metrics on held-out sim problems, with plain LBS as the
  baseline that a level must beat.
- Coverage: the paper's 120 cameras give 82% corner coverage at 25 Hz; lighthouse rigs with 2 to
  4 cameras at 60/120 fps will see far fewer corners per frame.
- RFD 2332's open "2310 against 1593 markers" question: the supplement states 2310 markers,
  4x4 dictionary, ids repeated once and told apart by an instance index (S§1.1).
