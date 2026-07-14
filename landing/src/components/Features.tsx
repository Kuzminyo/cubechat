import type { ReactNode } from 'react'
import { Kicker } from './ui'
import { useI18n } from '../i18n'

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      {children}
    </svg>
  )
}

// Icons are indexed to match the order of t.features.items
const ICONS: ReactNode[] = [
  <Icon><rect x="4" y="10.5" width="16" height="10" rx="2" /><path d="M8 10.5V7a4 4 0 0 1 8 0v3.5" /><circle cx="12" cy="15.5" r="1.3" /></Icon>,
  <Icon><path d="M12 3v18M5 8l7-5 7 5M5 16l7 5 7-5" /></Icon>,
  <Icon><circle cx="12" cy="8" r="4" /><path d="M4 20c0-4 4-6 8-6s8 2 8 6" /></Icon>,
  <Icon><path d="M4 12a8 8 0 0 1 16 0" /><path d="M12 8v4l3 2" /><path d="M2 12h2M20 12h2" /></Icon>,
  <Icon><path d="M12 3l7 3v5c0 5-3 8-7 10-4-2-7-5-7-10V6z" /><path d="m9 12 2 2 4-4" /></Icon>,
  <Icon><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14" /><path d="M10 11v5M14 11v5" /></Icon>,
  <Icon><path d="M4 9h16M4 15h16M10 4 8 20M16 4l-2 16" /></Icon>,
  <Icon><rect x="3" y="5" width="18" height="14" rx="2" /><path d="m3 15 5-4 4 3 3-2 6 4" /><circle cx="8.5" cy="9.5" r="1.5" /></Icon>,
]

export default function Features() {
  const { t } = useI18n()
  return (
    <section id="features" className="relative mx-auto max-w-6xl px-6 py-24 md:py-32">
      <div className="reveal flex flex-col items-center text-center">
        <Kicker>{t.features.kicker}</Kicker>
        <h2 className="font-section text-white text-4xl md:text-6xl leading-[1.02] tracking-tight mt-5 max-w-3xl whitespace-pre-line">
          {t.features.title}
        </h2>
      </div>

      <div className="mt-14 md:mt-20 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {t.features.items.map((f, i) => (
          <div
            key={f.title}
            className="reveal group relative liquid-glass rounded-2xl p-6 transition-all duration-500 hover:-translate-y-1.5"
          >
            <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-[#2edb8f]/10 text-[#7fd9a6] ring-1 ring-inset ring-[#2edb8f]/20 transition-colors duration-500 group-hover:text-[#c9ffd8]">
              {ICONS[i]}
            </div>
            <h3 className="mt-5 text-lg font-semibold text-white">{f.title}</h3>
            <p className="mt-2.5 text-[13.5px] leading-relaxed text-white/55">{f.body}</p>
            {f.tag && (
              <div className="mt-4 inline-block rounded-md bg-white/5 px-2 py-1 font-mono text-[10.5px] tracking-wide text-[#7fd9a6]/80">
                {f.tag}
              </div>
            )}
          </div>
        ))}
      </div>
    </section>
  )
}
