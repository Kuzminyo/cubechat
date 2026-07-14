import MeshBackground from './MeshBackground'
import { PrimaryButton, GhostButton } from './ui'
import { useI18n } from '../i18n'

export default function Hero() {
  const { t } = useI18n()
  return (
    <section id="top" className="relative h-screen w-full overflow-hidden">
      {/* Aurora glow — cheap CSS layer, drifts slowly (GPU-composited) */}
      <div className="pointer-events-none absolute inset-0 animate-float-slow" style={{
        background:
          'radial-gradient(45% 40% at 30% 34%, rgba(46,219,143,0.18), transparent 62%),' +
          'radial-gradient(42% 38% at 74% 66%, rgba(163,230,53,0.11), transparent 62%),' +
          'radial-gradient(34% 30% at 60% 14%, rgba(52,211,153,0.10), transparent 60%)',
      }} />

      {/* Living mesh backdrop */}
      <MeshBackground className="absolute inset-0 h-full w-full" />

      {/* Soft scrim right behind the headline so it stays legible over the cube */}
      <div className="pointer-events-none absolute inset-0" style={{
        background: 'radial-gradient(46% 42% at 50% 42%, rgba(6,20,13,0.62), transparent 72%)',
      }} />

      {/* Vignette + top fade so the navbar reads */}
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(120%_90%_at_50%_-10%,transparent_35%,rgba(3,10,7,0.55)_100%)]" />
      <div className="pointer-events-none absolute inset-x-0 top-0 h-40 bg-gradient-to-b from-[#06140d]/80 to-transparent" />
      <div className="pointer-events-none absolute inset-x-0 bottom-0 h-48 bg-gradient-to-t from-[#06140d] to-transparent" />

      {/* Center content */}
      <div className="absolute inset-0 flex flex-col items-center justify-center px-6 pt-16">
        <div
          className="mb-7 flex items-center gap-2.5 liquid-glass rounded-full px-4 py-1.5"
          style={{ animation: 'float-slow 7s ease-in-out infinite' }}
        >
          <span className="h-1.5 w-1.5 rounded-full bg-[#2edb8f] shadow-[0_0_10px_2px_rgba(46,219,143,0.8)]" />
          <span className="font-mono text-[11px] tracking-[0.22em] uppercase text-white/70">
            {t.hero.badge}
          </span>
        </div>

        <h1 className="font-instrument text-white text-[34px] md:text-6xl lg:text-[80px] leading-[0.95] tracking-tight text-center text-glow-white max-w-[15ch] whitespace-pre-line">
          {t.hero.title.a}
          <span className="text-[#7fffb0] text-glow-emerald">{t.hero.title.em}</span>
          {t.hero.title.b}
        </h1>

        <p className="text-white/65 text-sm md:text-lg text-center mt-6 md:mt-8 max-w-xl leading-relaxed">
          {t.hero.subtitle}
        </p>

        <div className="mt-8 md:mt-10 flex flex-col sm:flex-row items-center gap-3.5">
          <PrimaryButton href="#download">
            {t.hero.ctaPrimary}
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" className="translate-y-px">
              <path d="M5 12h14M13 6l6 6-6 6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </PrimaryButton>
          <GhostButton href="#how">{t.hero.ctaSecondary}</GhostButton>
        </div>

        <div className="mt-9 flex flex-wrap items-center justify-center gap-x-3 gap-y-2 font-mono text-[11px] tracking-widest uppercase text-white/40">
          {t.hero.chips.map((c, i) => (
            <span key={c} className="flex items-center gap-3">
              {i > 0 && <span className="text-[#2edb8f]/60">/</span>}
              {c}
            </span>
          ))}
        </div>
      </div>

      {/* Live mesh indicator (desktop) */}
      <div className="hidden md:flex absolute bottom-8 left-8 items-center gap-3">
        <span className="relative flex h-10 w-10 items-center justify-center rounded-full border border-white/15">
          <span className="absolute h-10 w-10 rounded-full border border-[#2edb8f]/40" style={{ animation: 'pulse-ring 2.6s ease-out infinite' }} />
          <span className="h-2 w-2 rounded-full bg-[#2edb8f] shadow-[0_0_10px_2px_rgba(46,219,143,0.8)]" />
        </span>
        <div className="leading-tight">
          <div className="font-mono text-[11px] text-white/70">{t.hero.meshLive}</div>
          <div className="font-mono text-[11px] text-white/40">{t.hero.relaying}</div>
        </div>
      </div>

      {/* Scroll cue */}
      <div className="hidden md:flex absolute bottom-9 right-10 flex-col items-center gap-2 text-white/40">
        <span className="font-mono text-[10px] tracking-[0.3em] uppercase [writing-mode:vertical-rl]">{t.hero.scroll}</span>
        <span className="h-10 w-px bg-gradient-to-b from-white/40 to-transparent" />
      </div>
    </section>
  )
}
