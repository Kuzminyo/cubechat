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
