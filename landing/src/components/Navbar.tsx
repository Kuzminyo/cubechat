import { useEffect, useState } from 'react'
import CubeLogo from './CubeLogo'
import { useI18n, type Lang } from '../i18n'

const EASE = 'cubic-bezier(0.22,1,0.36,1)'

function LangToggle({ className = '' }: { className?: string }) {
  const { lang, setLang } = useI18n()
  const opt = (l: Lang, label: string) => (
    <button
      key={l}
      onClick={() => setLang(l)}
      className={`rounded-full px-2.5 py-1 font-mono text-[11px] tracking-wide transition-colors duration-300 ${
        lang === l ? 'bg-white text-[#06140d]' : 'text-white/55 hover:text-white'
      }`}
      aria-pressed={lang === l}
    >
      {label}
    </button>
  )
  return (
    <div className={`flex items-center rounded-full border border-white/10 p-0.5 ${className}`}>
      {opt('uk', 'UA')}
      {opt('en', 'EN')}
    </div>
  )
}

export default function Navbar() {
  const { t } = useI18n()
  const [open, setOpen] = useState(false)
  const [scrolled, setScrolled] = useState(false)

  const LINKS = [
    { label: t.nav.features, href: '#features' },
    { label: t.nav.how, href: '#how' },
    { label: t.nav.security, href: '#security' },
    { label: t.nav.source, href: 'https://github.com/permissionlesstech/bitchat' },
  ]

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  useEffect(() => {
    document.body.style.overflow = open ? 'hidden' : ''
    return () => {
      document.body.style.overflow = ''
    }
  }, [open])

  return (
    <>
      <nav
        className={`fixed top-0 left-0 right-0 z-50 flex items-center justify-between px-6 md:px-12 transition-all duration-500 ${
          scrolled ? 'py-3.5 bg-[#06140d]/55 backdrop-blur-xl border-b border-white/5' : 'py-5'
        }`}
      >
        {/* Brand */}
        <a href="#top" className="flex items-center gap-2.5 group shrink-0">
          <CubeLogo size={30} className="transition-transform duration-500 group-hover:rotate-[8deg]" />
          <span className="text-white text-xl md:text-[22px] font-semibold tracking-tight lowercase">
            cubechat
          </span>
        </a>

        {/* Center links — absolutely centered, never competes with sides */}
        <div className="hidden md:flex absolute left-1/2 -translate-x-1/2 items-center gap-6">
          {LINKS.map((l) => (
            <a
              key={l.href}
              href={l.href}
              className="relative text-white/70 hover:text-white text-sm tracking-wide transition-colors duration-300 after:absolute after:-bottom-1.5 after:left-0 after:h-px after:w-0 after:bg-[#2edb8f] after:transition-all after:duration-300 hover:after:w-full whitespace-nowrap"
            >
              {l.label}
            </a>
          ))}
        </div>

        {/* Right */}
        <div className="flex items-center gap-4 shrink-0">
          <div className="hidden md:flex items-center gap-4">
            <LangToggle />
            <a
              href="#download"
              className="inline-flex items-center bg-white text-[#06140d] px-6 py-2.5 rounded-full font-semibold text-sm tracking-wide hover:bg-white/90 hover:-translate-y-0.5 transition-all duration-300 button-glow"
            >
              {t.nav.cta}
            </a>
          </div>

          {/* Hamburger (mobile) */}
          <button
            aria-label={open ? t.nav.menuClose : t.nav.menuOpen}
            onClick={() => setOpen((v) => !v)}
            className="md:hidden relative z-50 flex h-10 w-10 flex-col items-center justify-center gap-[7px]"
          >
            <span
              className="block h-[2px] w-6 rounded-full bg-white transition-all"
              style={{ transitionTimingFunction: EASE, transitionDuration: '400ms', transform: open ? 'translateY(9px) rotate(45deg)' : 'none' }}
            />
            <span
              className="block h-[2px] w-6 rounded-full bg-white transition-all"
              style={{ transitionTimingFunction: EASE, transitionDuration: '400ms', opacity: open ? 0 : 1, transform: open ? 'scaleX(0)' : 'none' }}
            />
            <span
              className="block h-[2px] w-6 rounded-full bg-white transition-all"
              style={{ transitionTimingFunction: EASE, transitionDuration: '400ms', transform: open ? 'translateY(-9px) rotate(-45deg)' : 'none' }}
            />
          </button>
        </div>
      </nav>

      {/* Mobile overlay */}
      <div
        className={`fixed inset-0 z-40 bg-black/60 transition-opacity duration-500 md:hidden ${
          open ? 'opacity-100' : 'pointer-events-none opacity-0'
        }`}
        onClick={() => setOpen(false)}
      />

      {/* Mobile slide-in panel */}
      <aside
        className="fixed top-0 right-0 z-40 h-full w-[85%] max-w-[340px] bg-[#06140d]/95 backdrop-blur-xl border-l border-white/10 md:hidden flex flex-col px-8 pt-28 pb-10"
        style={{
          transform: open ? 'translateX(0)' : 'translateX(100%)',
          transition: `transform 560ms ${EASE}`,
        }}
      >
        <div className="flex flex-col gap-2">
          {LINKS.map((l, i) => (
            <a
              key={l.href}
              href={l.href}
              onClick={() => setOpen(false)}
              className="py-3 text-2xl font-section text-white/90 border-b border-white/5"
              style={{
                opacity: open ? 1 : 0,
                transform: open ? 'translateX(0)' : 'translateX(24px)',
                transition: `opacity 500ms ${EASE} ${150 + i * 75}ms, transform 500ms ${EASE} ${150 + i * 75}ms`,
              }}
            >
              {l.label}
            </a>
          ))}
        </div>

        <div className="mt-8" style={{ opacity: open ? 1 : 0, transition: `opacity 500ms ${EASE} 400ms` }}>
          <LangToggle className="w-max" />
        </div>

        <a
          href="#download"
          onClick={() => setOpen(false)}
          className="mt-auto inline-flex items-center justify-center bg-white text-[#06140d] px-8 py-4 rounded-full font-semibold tracking-wide button-glow"
          style={{
            opacity: open ? 1 : 0,
            transform: open ? 'translateY(0)' : 'translateY(16px)',
            transition: `opacity 500ms ${EASE} 450ms, transform 500ms ${EASE} 450ms`,
          }}
        >
          {t.nav.cta}
        </a>
      </aside>
    </>
  )
}
