import { useId } from 'react'

/**
 * The cubechat brand mark — an isometric 3D cube.
 * A faithful SVG port of `CubeLogoPainter` (lib/core/widgets/cube_logo.dart):
 * three lit faces in the brand lime/green ramp, white edge speculars, and an
 * emerald halo.
 */
export default function CubeLogo({
  size = 28,
  glow = true,
  className = '',
}: {
  size?: number
  glow?: boolean
  className?: string
}) {
  const id = useId().replace(/:/g, '')

  // Normalised isometric vertices (viewBox 0 0 100 100, center 50,50, scale 38)
  const cos30 = 0.86602540378
  const s = 38
  const c = 50
  const P = (nx: number, ny: number) => `${(c + nx * s).toFixed(2)},${(c + ny * s).toFixed(2)}`

  const topApex = P(0, -1)
  const rightBack = P(cos30, -0.5)
  const leftBack = P(-cos30, -0.5)
  const centerFront = P(0, 0)
  const rightBottom = P(cos30, 0.5)
  const leftBottom = P(-cos30, 0.5)
  const bottomApex = P(0, 1)

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 100 100"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <defs>
        <linearGradient id={`top-${id}`} x1="50" y1="12" x2="50" y2="50" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#CFFC56" />
          <stop offset="1" stopColor="#A3E635" />
        </linearGradient>
        <linearGradient id={`right-${id}`} x1="83" y1="31" x2="50" y2="88" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#7BC93C" />
          <stop offset="1" stopColor="#4C9B23" />
        </linearGradient>
        <linearGradient id={`left-${id}`} x1="17" y1="31" x2="50" y2="88" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#5BAE2C" />
          <stop offset="1" stopColor="#2D7211" />
        </linearGradient>
        {glow && (
          <radialGradient id={`halo-${id}`} cx="50%" cy="50%" r="50%">
            <stop offset="0" stopColor="#2EDB8F" stopOpacity="0.35" />
            <stop offset="1" stopColor="#2EDB8F" stopOpacity="0" />
          </radialGradient>
        )}
      </defs>

      {glow && <circle cx="50" cy="50" r="48" fill={`url(#halo-${id})`} />}

      {/* Faces */}
      <polygon points={`${topApex} ${rightBack} ${centerFront} ${leftBack}`} fill={`url(#top-${id})`} />
      <polygon points={`${rightBack} ${rightBottom} ${bottomApex} ${centerFront}`} fill={`url(#right-${id})`} />
      <polygon points={`${leftBack} ${centerFront} ${bottomApex} ${leftBottom}`} fill={`url(#left-${id})`} />

      {/* Inner seams */}
      <polyline points={`${rightBack} ${centerFront} ${leftBack}`} stroke="#1B4D0A" strokeOpacity="0.35" strokeWidth="0.6" fill="none" />

      {/* Edge speculars */}
      <line x1={topApex.split(',')[0]} y1={topApex.split(',')[1]} x2={rightBack.split(',')[0]} y2={rightBack.split(',')[1]} stroke="#fff" strokeOpacity="0.55" strokeWidth="1" strokeLinecap="round" />
      <line x1={topApex.split(',')[0]} y1={topApex.split(',')[1]} x2={leftBack.split(',')[0]} y2={leftBack.split(',')[1]} stroke="#fff" strokeOpacity="0.32" strokeWidth="1" strokeLinecap="round" />
      <line x1={centerFront.split(',')[0]} y1={centerFront.split(',')[1]} x2={bottomApex.split(',')[0]} y2={bottomApex.split(',')[1]} stroke="#fff" strokeOpacity="0.16" strokeWidth="0.7" strokeLinecap="round" />
    </svg>
  )
}
