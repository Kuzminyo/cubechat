# Motion quality diagnosis

User video: video_2026-09-07_12-39-49.mp4, 590x1280, ~5.19 seconds.
Visible actions: laughter, raised paws/morning, flower, trophy.

Confirmed cause: v6/build-motion.py interpolates independently drawn poses with
DIS optical flow and switches source drawing at t=0.5. Registration uses only
alpha bounding boxes, not stable anatomy. The drawings have different head,
eye, torso and accessory shapes. Optical flow stretches those differences
through intermediate frames, so contours and faces change identity.

Requirements retained: 72 reactions, current matcha/yellow visual direction,
actual action gestures and changing expressions, slow smooth timing, transparent
animation plus 2K export, all deliverables in the project.

Replacement under development: articulated cutout parts with fixed artwork,
rigid transforms for limbs/head/props, discrete clean expression layers, no optical
flow, no raster mesh deformation, no crossfading independent full drawings.
First validation group is the four actions in the user video; this does not reduce
the 72-item scope. Old v6 is retained for comparison and is not accepted as final.

Verification must inspect motion throughout cycles at small chat size and enlarged,
check silhouette stability, face/prop identity, attachments, transparency, seams
and readable actions. Dimensions and decoding checks alone cannot prove quality.
