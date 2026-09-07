# Matcha & Emoji — motion revision 06
72 revised action animations (36 cats + 36 emoji). This revision responds to the
request to follow the FIRST eight animations: distinct drawn action poses and
facial changes, rather than small idle deformation of one still.

The first 24 use their original four-pose sheets. For the remaining 48, ImageGen
created extra poses using the existing sticker art as reference. Their visual
design is retained as the reference; small drawing variations across poses remain.
Approved static PNGs and 2K still exports are copied unchanged from collection 05.

Each 6-second loop has expression holds and eased single-source optical-flow
inbetweens at 25 fps. The source switches between drawn poses; these are animated
concept studies, not hand-cleaned production animation or Telegram TGS files.
WebP is 512 x 512, GIF is 240 x 240 on ivory. Transparent VP9 WebM is 2048 x 2048.
The 2K files are upscaled exports from smaller drawings, not native 2K detail.

Open index.html for the collection. compare.html shows previous/revised motion
while served alongside the earlier collections. No Flutter integration.
The built-in ImageGen tool produced pose sheets; build-motion.py records the
source mapping, framing, background keying and motion timing. All source sheets
and 288 individual poses are retained in the workspace.
