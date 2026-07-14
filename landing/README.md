# cubechat — landing

Marketing site for **cubechat**, built as a separate React + Vite + TypeScript +
Tailwind app so it stays out of the Flutter tree (`../web/` belongs to Flutter).

Design language: *editorial cryptography* — deep-green glass, a living BLE-mesh
backdrop, heavy Manrope display type with an emerald glow, JetBrains Mono for
technical accents. Palette is pulled straight from the app
(`lib/core/theme/colors.dart`) and the cube mark is an SVG port of
`CubeLogoPainter`.

## Run

```bash
cd landing
npm install
npm run dev        # http://localhost:5173 (or the printed port)
npm run build      # type-check + production bundle → dist/
npm run preview    # serve the built bundle
```

## Structure

```
src/
├── App.tsx                 # section assembly + scroll-reveal observer
├── index.css               # tokens, liquid-glass, glows, grain, keyframes
└── components/
    ├── CubeLogo.tsx        # isometric brand cube (SVG port of the painter)
    ├── MeshBackground.tsx  # canvas: drifting nodes, links, hopping packets
    ├── Navbar.tsx          # liquid-glass nav + animated mobile menu
    ├── Hero.tsx            # full-screen hero
    ├── StatMarquee.tsx     # scrolling proof strip
    ├── HowItWorks.tsx      # multi-hop mesh route (animated SVG) + 3 steps
    ├── Features.tsx        # 8 feature cards
    ├── Security.tsx        # two-tier envelope + crypto primitive stack
    ├── Philosophy.tsx      # parallax quote section (rAF + lerp)
    ├── Download.tsx        # final CTA
    ├── Footer.tsx
    └── ui.tsx              # shared buttons + section kicker
```

## TODO before shipping

Wire the real links (currently `#` placeholders):

- `Download.tsx` — `ANDROID_HREF`, `IOS_HREF`, `SOURCE_HREF`
- `Navbar.tsx` / `Footer.tsx` — the "Source" link points at bitchat (the stated
  inspiration); swap for cubechat's own repo/releases when public.
