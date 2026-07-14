import { useEffect, useRef } from 'react'
import { useI18n } from '../i18n'

const clamp = (min: number, max: number, v: number) => Math.min(max, Math.max(min, v))
const lerp = (cur: number, target: number, f: number) => cur + (target - cur) * f

/**
 * Parallax philosophy section — the Serene section-2 analog. A drifting aurora
 * arc up top and two glow orbs that slide in from the sides, driven by a
 * requestAnimationFrame loop with lerp smoothing and translate3d transforms.
 */
export default function Philosophy() {
  const { t } = useI18n()
  const sectionRef = useRef<HTMLElement>(null)
  const auroraRef = useRef<HTMLDivElement>(null)
  const leftRef = useRef<HTMLDivElement>(null)
  const rightRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    if (reduce) {
      // resting state
      leftRef.current && (leftRef.current.style.opacity = '0.5')
      rightRef.current && (rightRef.current.style.opacity = '0.5')
      return
    }

    let raf = 0
    // smoothed current values
    const cur = { aurora: 120, lx: -260, rx: 260, cloudY: 0, lop: 0, rop: 0 }

    const tick = () => {
      const el = sectionRef.current
      if (el) {
        const rect = el.getBoundingClientRect()
        const wh = window.innerHeight
        const progress = clamp(0, 1, (wh - rect.top) / (wh + rect.height))

        const auroraTarget = 120 - progress * 280
        const inView = progress > 0.12 && progress < 0.92
        const lxTarget = inView ? 0 : -260
        const rxTarget = inView ? 0 : 260
        const cloudYTarget = progress * -50
        const opTarget = inView ? clamp(0, 1, 1 - Math.abs(lxTarget - 0) / 260) : 0

        cur.aurora = lerp(cur.aurora, auroraTarget, 0.06)
        cur.lx = lerp(cur.lx, lxTarget, 0.04)
        cur.rx = lerp(cur.rx, rxTarget, 0.04)
        cur.cloudY = lerp(cur.cloudY, cloudYTarget, 0.06)
        cur.lop = lerp(cur.lop, opTarget, 0.05)
        cur.rop = lerp(cur.rop, opTarget, 0.05)

        if (auroraRef.current)
          auroraRef.current.style.transform = `translate3d(0, ${cur.aurora.toFixed(1)}px, 0)`
        if (leftRef.current) {
          leftRef.current.style.transform = `translate3d(${cur.lx.toFixed(1)}px, ${cur.cloudY.toFixed(1)}px, 0)`
          leftRef.current.style.opacity = (cur.lop * 0.85).toFixed(3)
        }
        if (rightRef.current) {
          rightRef.current.style.transform = `translate3d(${cur.rx.toFixed(1)}px, ${cur.cloudY.toFixed(1)}px, 0)`
          rightRef.current.style.opacity = (cur.rop * 0.85).toFixed(3)
        }
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [])

  return (
    <section
      ref={sectionRef}
      className="relative flex min-h-screen items-center justify-center overflow-hidden"
      style={{
        background:
          'linear-gradient(180deg, #02100a 0%, #063a29 38%, #0b6b4d 72%, #17b981 100%)',
      }}
    >
      {/* drifting aurora arc (parallax like Serene's rainbow) */}
      <div
        ref={auroraRef}
        className="pointer-events-none absolute inset-x-0 top-0 z-10 h-[60%] will-change-transform"
        style={{
          background:
            'radial-gradient(120% 90% at 50% 0%, rgba(163,230,53,0.35) 0%, rgba(46,219,143,0.18) 30%, rgba(46,219,143,0) 60%)',
        }}
      />

      {/* left glow orb */}
      <div
        ref={leftRef}
        className="pointer-events-none absolute left-0 bottom-[8%] z-10 hidden h-[560px] w-[560px] -translate-x-1/3 rounded-full opacity-0 blur-[60px] will-change-transform sm:block"
        style={{ background: 'radial-gradient(circle, rgba(234,255,242,0.5) 0%, rgba(46,219,143,0.25) 40%, transparent 70%)' }}
      />
      {/* right glow orb */}
      <div
        ref={rightRef}
        className="pointer-events-none absolute right-0 bottom-[14%] z-10 hidden h-[620px] w-[620px] translate-x-1/3 rounded-full opacity-0 blur-[70px] will-change-transform sm:block"
        style={{ background: 'radial-gradient(circle, rgba(163,230,53,0.35) 0%, rgba(46,219,143,0.2) 45%, transparent 72%)' }}
      />

      {/* grain-free soft top/bottom edges */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 h-32 bg-gradient-to-b from-[#06140d] to-transparent" />

      {/* Quote */}
      <div className="relative z-20 mx-auto max-w-4xl px-6 text-center">
        <blockquote
          className="font-section text-white text-lg leading-[1.55] sm:text-xl md:text-2xl lg:text-[26px] md:leading-[1.55]"
          style={{ fontWeight: 500 }}
        >
          {t.philosophy.quote}
        </blockquote>
        <div className="mt-7 font-mono text-sm tracking-wide text-white/80 md:mt-9">
          {t.philosophy.attribution}
        </div>
      </div>

      {/* bottom fade into next section */}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 z-20 h-32 bg-gradient-to-t from-[#06140d] to-transparent" />
    </section>
  )
}
