# Front paw correction

User evidence: the shy sticker displayed two flat green capsules with pads,
appearing detached on the chest.

Cause: smooth_arm returned separate upper and lower strokes. The upper stroke
was hidden behind the body and only the distal stroke remained visible. The
elbow solution also bent inward when the target moved above the shoulder.
The same pad-facing crop was incorrectly used for every hand orientation.

Correction: replace the disconnected segments with one continuous curved
foreleg starting at the actual shoulder. Blend the attachment into body fur.
Use an illustrated cream/olive furry-side paw for face touches and holding.
Keep pad-facing paws for the existing rigid waving/open-palm gestures.
The fixed core, face, body, tail and timing are unchanged by this correction.

Affected: 26 cat animations listed in paw-fix-affected.json.
Evidence: paw-fix-shy.jpg and paw-fix-contact.jpg; complete motion QA in qa/.
Source graphic: cat-paw-fur-source.png; built-in ImageGen using the original
cat-shy reference, followed by a solid-background cleanup.
