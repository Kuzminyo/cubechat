import CubeLogo from './CubeLogo'
import { useI18n } from '../i18n'

export default function Footer() {
  const { t } = useI18n()
  return (
    <footer className="relative border-t border-white/5 px-6 pt-16 pb-10">
      <div className="mx-auto max-w-6xl">
        <div className="grid gap-12 md:grid-cols-[1.4fr_1fr_1fr_1fr]">
          {/* brand */}
          <div>
            <div className="flex items-center gap-2.5">
              <CubeLogo size={30} />
              <span className="text-white text-xl font-semibold tracking-tight lowercase">cubechat</span>
            </div>
            <p className="mt-4 max-w-xs text-sm leading-relaxed text-white/45">
              {t.footer.tagline}
            </p>
            <div className="mt-6 inline-flex items-center gap-2 rounded-md bg-white/[0.03] px-3 py-2 font-mono text-[11px] text-[#7fd9a6]/80">
              <span className="text-white/35">$</span> /join #cubechat
            </div>
          </div>

          {/* link columns */}
          {t.footer.cols.map((c) => (
            <div key={c.head}>
              <div className="font-mono text-[11px] uppercase tracking-[0.2em] text-white/35">{c.head}</div>
              <ul className="mt-4 space-y-2.5">
                {c.links.map((l) => (
                  <li key={l.label}>
                    <a href={l.href} className="text-sm text-white/60 hover:text-white transition-colors duration-300">
                      {l.label}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="mt-14 flex flex-col items-start justify-between gap-4 border-t border-white/5 pt-6 sm:flex-row sm:items-center">
          <div className="font-mono text-[11px] text-white/35">
            © {new Date().getFullYear()} cubechat · {t.footer.rights}
          </div>
          <div className="flex items-center gap-2 font-mono text-[11px] text-white/35">
            <span className="h-1.5 w-1.5 rounded-full bg-[#2edb8f] shadow-[0_0_8px_2px_rgba(46,219,143,0.6)]" />
            {t.footer.e2e}
          </div>
        </div>
      </div>
    </footer>
  )
}
