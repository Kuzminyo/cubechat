import { Kicker } from './ui'
import { useI18n } from '../i18n'
import MeshGrid from './MeshGrid'

export default function HowItWorks() {
  const { t } = useI18n()
  return (
    <section id="how" className="relative mx-auto max-w-6xl px-6 py-24 md:py-36">
      <div className="reveal flex flex-col items-center text-center">
        <Kicker>{t.how.kicker}</Kicker>
        <h2 className="font-section text-white text-4xl md:text-6xl leading-[1.02] tracking-tight mt-5 max-w-3xl whitespace-pre-line">
          {t.how.title}
        </h2>
      </div>

      <div className="reveal mt-14 md:mt-20 liquid-glass rounded-3xl p-4 md:p-6">
        <MeshGrid you={t.how.you} dest={t.how.dest} />
      </div>
      <div className="mt-5 text-center font-mono text-[11px] uppercase tracking-[0.25em] text-white/40">
        {t.how.caption}
      </div>

      <div className="mt-12 md:mt-16 grid gap-6 md:grid-cols-3">
        {t.how.steps.map((s, i) => (
          <div key={i} className="reveal group liquid-glass rounded-2xl p-7 transition-transform duration-500 hover:-translate-y-1">
            <div className="font-mono text-sm text-[#2edb8f]/80">{String(i + 1).padStart(2, '0')}</div>
            <h3 className="mt-4 text-xl font-semibold text-white">{s.title}</h3>
            <p className="mt-3 text-sm leading-relaxed text-white/55">{s.body}</p>
          </div>
        ))}
      </div>
    </section>
  )
}
