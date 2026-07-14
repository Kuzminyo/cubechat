import { useEffect } from 'react'
import Navbar from './components/Navbar'
import Hero from './components/Hero'
import StatMarquee from './components/StatMarquee'
import HowItWorks from './components/HowItWorks'
import Features from './components/Features'
import Security from './components/Security'
import Philosophy from './components/Philosophy'
import Download from './components/Download'
import Footer from './components/Footer'
import { useI18n } from './i18n'

export default function App() {
  const { lang } = useI18n()

  // Re-run whenever language changes so newly-rendered elements get observed
  useEffect(() => {
    const els = Array.from(document.querySelectorAll<HTMLElement>('.reveal'))
    if (!('IntersectionObserver' in window)) {
      els.forEach((el) => el.classList.add('is-visible'))
      return
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add('is-visible')
            io.unobserve(e.target)
          }
        })
      },
      { threshold: 0, rootMargin: '0px 0px 0px 0px' },
    )
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [lang])

  return (
    <div className="grain relative min-h-screen bg-[#06140d] text-white antialiased">
      <Navbar />
      <main>
        <Hero />
        <StatMarquee />
        <HowItWorks />
        <Features />
        <Security />
        <Philosophy />
        <Download />
      </main>
      <Footer />
    </div>
  )
}
