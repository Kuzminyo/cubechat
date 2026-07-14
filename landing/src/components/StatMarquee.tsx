import { useI18n } from '../i18n'

function Row({ items }: { items: readonly string[] }) {
  return (
    <div className="flex shrink-0 items-center gap-10 pr-10">
      {items.map((t, i) => (
        <div key={i} className="flex items-center gap-3">
          <span className="h-1.5 w-1.5 rotate-45 bg-[#2edb8f]/70" />
          <span className="font-mono text-xs md:text-sm tracking-wide text-white/55 whitespace-nowrap">
            {t}
          </span>
        </div>
      ))}
    </div>
  )
}

export default function StatMarquee() {
  const { t } = useI18n()
  return (
    <div className="relative border-y border-white/5 bg-white/[0.015] py-5 overflow-hidden">
      <div className="pointer-events-none absolute inset-y-0 left-0 z-10 w-24 bg-gradient-to-r from-[#06140d] to-transparent" />
      <div className="pointer-events-none absolute inset-y-0 right-0 z-10 w-24 bg-gradient-to-l from-[#06140d] to-transparent" />
      <div className="flex w-max animate-marquee">
        <Row items={t.marquee} />
        <Row items={t.marquee} />
      </div>
    </div>
  )
}
