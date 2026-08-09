# Design QA: Contact profile

## Final result

`passed`

## Visual truth and implementation

- Source visual truth: `D:\projects\cubechat\.codex\design-references\target-contact-profile.png`
- Previous product screen: `D:\projects\cubechat\.codex\design-references\current-verification.png`
- Implementation, default state: `D:\projects\cubechat\.codex\design-qa\implementation-profile-360x800-with-fonts.png`
- Implementation, actions menu open: `D:\projects\cubechat\.codex\design-qa\implementation-menu-open-360x800.png`
- Full comparison: `D:\projects\cubechat\.codex\design-qa\comparison-source-left-implementation-right.jpg`
- Menu comparison: `D:\projects\cubechat\.codex\design-qa\comparison-menu-source-left-implementation-right.jpg`

## Viewport and normalization

- Source dimensions: 1080 x 2340 physical pixels.
- Implementation dimensions: 360 x 800 logical pixels.
- QA viewport: 360 x 800 logical pixels.
- The source was proportionally normalized to 360 x 780 and centered in a 360 x 800 canvas before side-by-side comparison.
- State checked: contact profile loaded; actions menu closed and open.
- The in-app browser renderer was unavailable because its Windows sandbox helper failed. The implementation evidence was therefore rendered directly by Flutter at the exact target logical viewport.

## Comparison findings

- The main composition matches the reference: full-width visual hero, identity and status near the hero bottom, a horizontal quick-action row, dark contact details below, and an overlay actions menu.
- The actions menu now uses a right-aligned translucent panel with a dimmed backdrop, matching the reference interaction and placement.
- Primary controls are functional: open chat, mute/unmute, verify identity, copy contact ID, block/unblock, open and close the actions menu.
- Text and interactive content remain inside the 360 x 800 viewport with no overflow.
- The reference uses a peer photo. The current data model has no peer-photo field, so the implementation deliberately uses the existing Cubechat generated identity avatar and gradient instead of a fake image.
- The target screenshot contains product-specific actions that Cubechat does not currently support. Only existing, real Cubechat actions were included.

## Focused-region review

The menu occupies most of the normalized viewport and all labels remain readable in the full menu comparison, so a separate crop would not add useful inspection detail.

## Comparison history

1. Initial implementation used a bottom sheet for secondary actions. This was a visible P2 mismatch because the reference uses a right-side overlay panel.
2. The bottom sheet was replaced with an 82%-width right-aligned glass panel, a full-screen dim backdrop, and an explicit close action.
3. Revised evidence: `D:\projects\cubechat\.codex\design-qa\comparison-menu-source-left-implementation-right.jpg`.

## Functional verification

- Widget coverage: 360 x 800 layout, localized content, menu open/close, block/unblock state.
- Route coverage: contact names and public keys are encoded correctly.
- Static analysis: no errors in the new contact profile screen.
---

# Design QA: People map

## Final result

`passed`

## Visual truth and implementation

- Latest source reference: `C:\Users\kuzme\AppData\Local\Temp\codex-clipboard-9681190a-ce47-459d-b050-0c2b0a2edd74.png`
- Implementation capture: `D:\projects\cubechat\.codex\design-qa\people-map-360x800.png`
- Side-by-side comparison: `D:\projects\cubechat\.codex\design-qa\people-map-comparison.jpg`

## Viewport and normalization

- Implementation viewport: 360 x 800 logical pixels.
- The source was cover-normalized to 360 x 800 for the comparison.
- The in-app browser connection was unavailable because its Windows sandbox helper failed. Flutter rendered the implementation directly at the exact phone viewport instead.
- Network tiles are disabled in the deterministic widget capture. The production build keeps the real OpenStreetMap street layer and applies a local monochrome inversion plus a black overlay.
- Flutter's deterministic screenshot renderer displays text as geometry blocks. Semantic widget assertions separately verify the decoded Ukrainian labels, including the map title and privacy state.

## Comparison findings

- The map remains the full-screen dominant surface and supports the same real-world pan and zoom model as the source.
- The requested color direction is implemented as black and graphite, with roads and labels retained by the local tile color matrix rather than replaced by a fake background.
- Circular user avatars remain the strongest visual anchors. Theme-colored glows and restrained links preserve Cubechat's own glass language.
- Header and state cards remain inside safe areas and clear the persistent bottom navigation.
- The reference's blue utility buttons were not copied because the request targeted the map surface; Cubechat keeps its existing theme-aware controls and navigation.
- No overflow or uncaught layout exception occurred at 360 x 800.

## Functional verification

- The fifth bottom-bar item opens the map branch.
- All map labels now decode correctly in Ukrainian; the previous question-mark strings are gone.
- `Show me on map` is persisted under Privacy and defaults to off.
- When off, Cubechat does not request a GPS fix, hides the own pin, and blocks manual location sharing with a localized explanation.
- When on, the own marker appears. Tapping it opens the own mini-profile card, whose Profile action returns to the profile tab.
- Location checks run only while the map tab is visible, at a 90-second cadence; map animation pauses while hidden or idle.
- Automatic precise-location fanout to contacts is not enabled.
- Focused unit, widget, localization, navigation, and golden tests pass; static analysis reports no errors.
- Android release compilation succeeded.
