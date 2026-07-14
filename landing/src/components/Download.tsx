import type { ReactNode } from 'react'
import CubeLogo from './CubeLogo'
import { Kicker } from './ui'
import { useI18n } from '../i18n'

// Per-platform downloadable files live in landing/public/downloads/.
// Swap the APK / iOS artifact for freshly-built ones when you cut a release.
const ANDROID = { href: '/downloads/cubechat-0.1.0.apk', file: 'cubechat-0.1.0.apk' }
const IOS = { href: '/downloads/cubechat-ios-sideload.txt', file: 'cubechat-ios-sideload.txt' }
const SOURCE = { href: '/downloads/cubechat-0.1.0-source.zip', file: 'cubechat-0.1.0-source.zip' }

function StoreButton({
  href,
  download,
  glyph,
  top,
  bottom,
  primary = false,
}: {
  href: string
  download: string
  glyph: ReactNode
  top: string
  bottom: string
  primary?: boolean
}) {
  return (
    <a
      href={href}
      download={download}
      className={`group flex items-center gap-3.5 rounded-2xl px-6 py-3.5 transition-all duration-300 hover:-translate-y-0.5 ${
        primary
          ? 'bg-white text-[#06140d] button-glow'
          : 'liquid-glass text-white'
      }`}
    >
      <span className={primary ? 'text-[#06140d]' : 'text-[#7fd9a6]'}>{glyph}</span>
      <span className="text-left leading-tight">
        <span className={`block text-[10px] uppercase tracking-widest ${primary ? 'text-[#06140d]/55' : 'text-white/45'}`}>
          {top}
        </span>
        <span className="block text-[15px] font-semibold">{bottom}</span>
      </span>
    </a>
  )
}

export default function Download() {
  const { t } = useI18n()
  return (
    <section id="download" className="relative mx-auto max-w-6xl px-6 py-24 md:py-32">
      <div className="reveal relative overflow-hidden rounded-[2rem] liquid-glass px-8 py-16 text-center md:px-16 md:py-24">
        {/* inner glow */}
        <div className="pointer-events-none absolute left-1/2 top-0 h-64 w-[40rem] -translate-x-1/2 rounded-full bg-[#2edb8f]/15 blur-[90px]" />

        <div className="relative flex flex-col items-center">
          <CubeLogo size={64} className="animate-float-slow" />
          <div className="mt-8">
            <Kicker>{t.download.kicker}</Kicker>
          </div>
          <h2 className="font-section text-white text-4xl md:text-6xl leading-[1.02] tracking-tight mt-5 max-w-2xl whitespace-pre-line">
            {t.download.title}
          </h2>
          <p className="mt-5 max-w-lg text-white/55 text-sm md:text-base leading-relaxed">
            {t.download.subtitle}
          </p>

          <div className="mt-10 flex flex-col sm:flex-row items-center gap-3.5">
            <StoreButton
              href={ANDROID.href}
              download={ANDROID.file}
              primary
              top={t.download.androidTop}
              bottom={t.download.android}
              glyph={
                <svg width="22" height="22" viewBox="0 0 24 24" fill="currentColor"><path d="M17.6 9.5 20 5.4a.5.5 0 0 0-.87-.5l-2.44 4.2A13.3 13.3 0 0 0 12 8.3c-1.65 0-3.2.32-4.69.9L4.87 4.9a.5.5 0 0 0-.87.5L6.4 9.5A11 11 0 0 0 1 18h22a11 11 0 0 0-5.4-8.5ZM7 15.2a1.1 1.1 0 1 1 0-2.2 1.1 1.1 0 0 1 0 2.2Zm10 0a1.1 1.1 0 1 1 0-2.2 1.1 1.1 0 0 1 0 2.2Z" /></svg>
              }
            />
            <StoreButton
              href={IOS.href}
              download={IOS.file}
              top={t.download.iosTop}
              bottom={t.download.ios}
              glyph={
                <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M16.4 12.9c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.15-2.8.85-3.5.85-.7 0-1.85-.83-3-.8-1.55.02-3 .9-3.8 2.3-1.6 2.8-.4 7 1.15 9.3.76 1.13 1.66 2.4 2.85 2.35 1.15-.05 1.58-.74 2.97-.74 1.38 0 1.77.74 2.98.72 1.23-.02 2-1.14 2.76-2.28.87-1.3 1.23-2.57 1.25-2.64-.03-.01-2.4-.92-2.42-3.64ZM14.13 6.1c.63-.77 1.06-1.83.94-2.9-.91.04-2.02.61-2.67 1.37-.58.68-1.09 1.76-.95 2.8 1.02.08 2.05-.51 2.68-1.27Z" /></svg>
              }
            />
            <StoreButton
              href={SOURCE.href}
              download={SOURCE.file}
              top={t.download.sourceTop}
              bottom={t.download.source}
              glyph={
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="m8 8-4 4 4 4M16 8l4 4-4 4M13 5l-2 14" /></svg>
              }
            />
          </div>

          <div className="mt-8 inline-flex items-center gap-2 rounded-full border border-white/5 bg-white/[0.02] px-4 py-2 font-mono text-[11px] text-white/45">
            <span className="h-1.5 w-1.5 rounded-full bg-[#f5c26b]" />
            {t.download.note}
          </div>
        </div>
      </div>
    </section>
  )
}
