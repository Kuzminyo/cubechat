import { Kicker } from './ui'
import { useI18n } from '../i18n'

export default function Security() {
  const { t } = useI18n()
  return (
    <section id="security" className="relative overflow-hidden py-24 md:py-36">
      {/* subtle top glow */}
      <div className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-[#2edb8f]/40 to-transparent" />
      <div className="pointer-events-none absolute left-1/2 top-0 h-72 w-[46rem] -translate-x-1/2 rounded-full bg-[#2edb8f]/10 blur-[100px]" />

      <div className="mx-auto max-w-6xl px-6">
        <div className="reveal flex flex-col items-center text-center">
          <Kicker>{t.security.kicker}</Kicker>
          <h2 className="font-section text-white text-4xl md:text-6xl leading-[1.02] tracking-tight mt-5 max-w-3xl">
            {t.security.title.a}
            <span className="text-[#7fffb0]">{t.security.title.em}</span>
            {t.security.title.b}
          </h2>
          <p className="mt-5 max-w-2xl text-white/55 text-sm md:text-base leading-relaxed">
            {t.security.intro}
          </p>
        </div>

        <div className="reveal mt-16 grid gap-10 lg:grid-cols-[0.9fr_1.1fr] lg:items-center">
          {/* Two-tier envelope */}
          <div className="liquid-glass rounded-3xl p-8 md:p-10">
            <div className="font-mono text-[11px] uppercase tracking-[0.25em] text-[#7fd9a6]">
              {t.security.envelopeTitle}
            </div>
            <div className="mt-6 rounded-2xl border border-[#2edb8f]/25 bg-[#2edb8f]/[0.05] p-5">
              <div className="font-mono text-xs text-[#7fd9a6]">{t.security.outer}</div>
              <div className="mt-1 text-xs text-white/45">{t.security.outerDesc}</div>
              <div className="mt-4 rounded-xl border border-white/15 bg-white/[0.04] p-5">
                <div className="font-mono text-xs text-white/80">SignedPayload · Ed25519</div>
                <div className="mt-1 text-xs text-white/45">{t.security.signedDesc}</div>
                <div className="mt-4 rounded-lg border border-white/20 bg-gradient-to-br from-white/95 to-white/80 p-4 text-[#06140d]">
                  <div className="font-mono text-[11px] uppercase tracking-wide text-[#06140d]/60">{t.security.yourMessage}</div>
                  <div className="mt-0.5 text-sm font-medium">{t.security.messageExample}</div>
                </div>
              </div>
            </div>
            <p className="mt-5 font-mono text-[11px] leading-relaxed text-white/40">
              {t.security.comment}
            </p>
          </div>

          {/* Primitive stack */}
          <div className="space-y-2.5">
            {t.security.layers.map((l) => (
              <div
                key={l.name}
                className="group flex flex-col gap-1 rounded-xl border border-white/5 bg-white/[0.02] px-5 py-4 transition-colors duration-300 hover:border-[#2edb8f]/25 hover:bg-[#2edb8f]/[0.04] sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="flex items-baseline gap-3">
                  <span className="text-white font-semibold">{l.name}</span>
                  <span className="text-white/45 text-[13px]">{l.purpose}</span>
                </div>
                <span className="font-mono text-[11px] text-[#7fd9a6]/75 whitespace-nowrap">{l.prim}</span>
              </div>
            ))}
          </div>
        </div>

        {/* Honest scope note */}
        <div className="reveal mt-10 flex items-start gap-3 rounded-xl border border-[#f5c26b]/20 bg-[#f5c26b]/[0.04] px-5 py-4">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" className="mt-0.5 shrink-0 text-[#f5c26b]">
            <path d="M12 3 2 20h20L12 3z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
            <path d="M12 10v4M12 17h.01" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
          </svg>
          <p className="text-[13px] leading-relaxed text-white/55">
            <span className="text-white/80 font-medium">{t.security.scopeTitle}</span>{' '}
            {t.security.scopeBody}
          </p>
        </div>
      </div>
    </section>
  )
}
