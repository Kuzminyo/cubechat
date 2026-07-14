import type { ReactNode } from 'react'

/** White pill CTA (Serene spec) — retuned with an emerald glow. */
export function PrimaryButton({
  children,
  href = '#download',
  className = '',
}: {
  children: ReactNode
  href?: string
  className?: string
}) {
  return (
    <a
      href={href}
      className={`inline-flex items-center justify-center gap-2 bg-white text-[#06140d] px-8 py-3.5 rounded-full font-semibold text-sm tracking-wide hover:bg-white/90 hover:-translate-y-0.5 transition-all duration-300 button-glow ${className}`}
    >
      {children}
    </a>
  )
}

/** Ghost / glass pill — secondary action. */
export function GhostButton({
  children,
  href = '#',
  className = '',
}: {
  children: ReactNode
  href?: string
  className?: string
}) {
  return (
    <a
      href={href}
      className={`inline-flex items-center justify-center gap-2 liquid-glass text-white/90 px-8 py-3.5 rounded-full font-medium text-sm tracking-wide hover:text-white transition-all duration-300 ${className}`}
    >
      {children}
    </a>
  )
}

/** Small mono kicker that labels each section. */
export function Kicker({ children }: { children: ReactNode }) {
  return (
    <div className="inline-flex items-center gap-2.5 font-mono text-[11px] uppercase tracking-[0.28em] text-[#7fd9a6]">
      <span className="h-1.5 w-1.5 rounded-full bg-[#2edb8f] shadow-[0_0_10px_2px_rgba(46,219,143,0.7)]" />
      {children}
    </div>
  )
}
