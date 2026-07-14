# CubeChat Landing QA

final result: **passed (DOM + behaviour); visual pass still owed by a human**

## Scope

The landing in `landing/` is a React + Vite + TypeScript + Tailwind app
(`npm run dev --prefix landing`). Sections: hero, stat marquee, how-it-works,
features, security, philosophy, download, footer. Default language is Ukrainian
with a live UA/EN toggle.

> **Note.** The previous revision of this file described a *different* landing —
> a static page with a generated hero raster and a TikTok-style vertical product
> reel. That page no longer exists; the React rewrite replaced it, and neither
> the reel nor the raster asset is in the codebase. The old "blocked on comparing
> the reel against the supplied video" follow-up is therefore moot and has been
> dropped.

## Automated checks

Driven against the dev server at `http://localhost:5199`.

- Desktop (1440×1024) horizontal overflow: **none**.
- Mobile (375×812) horizontal overflow: **none**, including with the mobile
  drawer open.
- Default `html lang`: `uk`. Hero: `Повідомлення, яким не потрібен сигнал.`
- EN toggle flips `html lang` to `en` and the hero to
  `Messages that need no signal.`; UA toggle restores it.
- Sections present and anchored: `top`, `how`, `features`, `security`,
  philosophy, `download`.
- Mobile drawer: burger toggles state, locks body scroll, and holds the five
  expected links.
- Tailwind stylesheet loads (360 rules); no runtime console errors.
- Test-count claim in the copy corrected from 186 to **246** to match
  `flutter test`.

## Known limitation of this QA run

The preview browser used here **cannot capture screenshots** (every capture times
out) and **does not advance CSS transitions** — a transformed element stays
pinned at its start value even after its inline style updates. That makes every
motion-dependent assertion unverifiable from here, and it is what made the
previous run's visual QA fail too. It is an environment limitation, not a page
defect: forcing the same transform with `transition: none` moves the element
exactly where it should go.

So the following still needs a human with a real browser (`npm run dev --prefix
landing`, open `http://localhost:5199`):

- Eyeball the hero drift, aurora sweep, logo pulse, scroll reveals, hover lift,
  and CTA shimmer.
- Confirm the mobile drawer visibly slides in on a tap (state, scroll-lock and
  layout are all verified; only the animated slide is unproven).
