import { useEffect, useRef } from 'react'

type Node = { x: number; y: number; vx: number; vy: number; r: number }
type Packet = { a: number; b: number; t: number; speed: number }
type Ring = { ox: number; oy: number; t: number; speed: number }

// Unit cube — 8 vertices, 12 edges — for the big rotating wireframe.
const CUBE_V: [number, number, number][] = [
  [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
  [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1],
]
const CUBE_E: [number, number][] = [
  [0, 1], [1, 2], [2, 3], [3, 0],
  [4, 5], [5, 6], [6, 7], [7, 4],
  [0, 4], [1, 5], [2, 6], [3, 7],
]

/**
 * Living BLE-mesh backdrop:
 *  - a giant slowly-rotating wireframe cube (the brand mark, writ large)
 *  - broadcast rings rippling out like BLE advertising
 *  - drifting nodes, proximity links, and encrypted packets hopping edges
 * All on one throttled rAF loop over the deep-green canvas.
 */
export default function MeshBackground({ className = '' }: { className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches

    let width = 0
    let height = 0
    let dpr = Math.min(window.devicePixelRatio || 1, 2)
    let nodes: Node[] = []
    let packets: Packet[] = []
    let rings: Ring[] = []
    let raf = 0
    let running = true

    // cube rotation angles (start on a pleasing three-quarter view)
    const rot = { x: 0.62, y: 0.82, z: 0 }

    const rand = (a: number, b: number) => a + Math.random() * (b - a)

    function build() {
      const rect = canvas!.getBoundingClientRect()
      width = rect.width
      height = rect.height
      canvas!.width = Math.floor(width * dpr)
      canvas!.height = Math.floor(height * dpr)
      ctx!.setTransform(dpr, 0, 0, dpr, 0, 0)

      const density = Math.round((width * height) / 26000)
      const count = Math.max(22, Math.min(64, density))
      nodes = Array.from({ length: count }, () => ({
        x: rand(0, width),
        y: rand(0, height),
        vx: rand(-0.12, 0.12),
        vy: rand(-0.12, 0.12),
        r: rand(1.1, 2.4),
      }))
      packets = []
      rings = []
    }

    const LINK = 150 // px

    function spawnPacket() {
      const a = Math.floor(Math.random() * nodes.length)
      let best = -1
      let bestD = LINK
      for (let b = 0; b < nodes.length; b++) {
        if (b === a) continue
        const d = Math.hypot(nodes[a].x - nodes[b].x, nodes[a].y - nodes[b].y)
        if (d < bestD && Math.random() > 0.5) {
          bestD = d
          best = b
        }
      }
      if (best >= 0) packets.push({ a, b: best, t: 0, speed: rand(0.006, 0.014) })
    }

    // ---- big rotating cube -------------------------------------------------
    function drawCube() {
      const scale = Math.min(width, height) * 0.46
      const cx = width * 0.5
      const cy = height * 0.44
      const fov = 3.2

      const cxr = Math.cos(rot.x), sxr = Math.sin(rot.x)
      const cyr = Math.cos(rot.y), syr = Math.sin(rot.y)
      const czr = Math.cos(rot.z), szr = Math.sin(rot.z)

      // project the 8 vertices once
      const proj = CUBE_V.map(([x0, y0, z0]) => {
        // rotate X
        let y = y0 * cxr - z0 * sxr
        let z = y0 * sxr + z0 * cxr
        let x = x0
        // rotate Y
        let nx = x * cyr + z * syr
        z = -x * syr + z * cyr
        x = nx
        // rotate Z
        nx = x * czr - y * szr
        y = x * szr + y * czr
        x = nx
        const factor = fov / (fov + z)
        return { sx: cx + x * scale * factor, sy: cy + y * scale * factor, z, factor }
      })

      // edges, brighter when nearer the camera
      ctx!.lineWidth = 1.3
      for (const [a, b] of CUBE_E) {
        const pa = proj[a]
        const pb = proj[b]
        const depth = (pa.z + pb.z) / 2 // ~[-1.7, 1.7], smaller = nearer
        const near = Math.max(0, Math.min(1, (1.9 - depth) / 3.8))
        const alpha = 0.09 + near * 0.19
        ctx!.strokeStyle = `rgba(46,219,143,${alpha.toFixed(3)})`
        ctx!.beginPath()
        ctx!.moveTo(pa.sx, pa.sy)
        ctx!.lineTo(pb.sx, pb.sy)
        ctx!.stroke()
      }

      // glowing vertices
      for (const p of proj) {
        const rr = 3.2 * p.factor
        const g = ctx!.createRadialGradient(p.sx, p.sy, 0, p.sx, p.sy, rr * 3)
        g.addColorStop(0, 'rgba(163,230,53,0.55)')
        g.addColorStop(1, 'rgba(163,230,53,0)')
        ctx!.fillStyle = g
        ctx!.beginPath()
        ctx!.arc(p.sx, p.sy, rr * 3, 0, Math.PI * 2)
        ctx!.fill()
      }
    }

    // ---- broadcast rings ---------------------------------------------------
    let ringToggle = 0
    function spawnRing() {
      const anchors = [
        { x: width * 0.28, y: height * 0.6 },
        { x: width * 0.74, y: height * 0.32 },
      ]
      const a = anchors[ringToggle % anchors.length]
      ringToggle++
      rings.push({ ox: a.x, oy: a.y, t: 0, speed: rand(0.0028, 0.0042) })
    }

    function drawRings() {
      const maxR = Math.hypot(width, height) * 0.6
      rings = rings.filter((r) => r.t <= 1)
      for (const r of rings) {
        r.t += r.speed
        const radius = r.t * maxR
        const alpha = (1 - r.t) * 0.16
        ctx!.strokeStyle = `rgba(46,219,143,${alpha.toFixed(3)})`
        ctx!.lineWidth = 1.4
        ctx!.beginPath()
        ctx!.arc(r.ox, r.oy, radius, 0, Math.PI * 2)
        ctx!.stroke()
      }
    }

    let lastSpawn = 0
    let lastRing = 0
    let lastFrame = -1000

    function frame(now: number) {
      if (!running) return
      // ~30fps throttle — plenty for a drifting mesh, half the GPU cost
      if (now - lastFrame < 33) {
        raf = requestAnimationFrame(frame)
        return
      }
      lastFrame = now
      ctx!.clearRect(0, 0, width, height)

      // (aurora glow lives in a cheap CSS layer behind the canvas — see Hero)

      // broadcast rings (behind everything)
      if (!reduce && now - lastRing > 2100) {
        spawnRing()
        lastRing = now
      }
      drawRings()

      // giant rotating cube
      drawCube()
      if (!reduce) {
        rot.x += 0.0016
        rot.y += 0.0022
        rot.z += 0.0010
      }

      // move nodes
      for (const n of nodes) {
        n.x += n.vx
        n.y += n.vy
        if (n.x < -20) n.x = width + 20
        if (n.x > width + 20) n.x = -20
        if (n.y < -20) n.y = height + 20
        if (n.y > height + 20) n.y = -20
      }

      // links
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const dx = nodes[i].x - nodes[j].x
          const dy = nodes[i].y - nodes[j].y
          const d = Math.hypot(dx, dy)
          if (d < LINK) {
            const a = (1 - d / LINK) * 0.34
            ctx!.strokeStyle = `rgba(127,217,166,${a})`
            ctx!.lineWidth = 1
            ctx!.beginPath()
            ctx!.moveTo(nodes[i].x, nodes[i].y)
            ctx!.lineTo(nodes[j].x, nodes[j].y)
            ctx!.stroke()
          }
        }
      }

      // nodes
      for (const n of nodes) {
        ctx!.beginPath()
        ctx!.arc(n.x, n.y, n.r, 0, Math.PI * 2)
        ctx!.fillStyle = 'rgba(200,255,210,0.7)'
        ctx!.fill()
      }

      // packets
      if (!reduce && now - lastSpawn > 520 && packets.length < 10) {
        spawnPacket()
        lastSpawn = now
      }
      packets = packets.filter((p) => p.t <= 1)
      for (const p of packets) {
        p.t += p.speed
        const na = nodes[p.a]
        const nb = nodes[p.b]
        if (!na || !nb) {
          p.t = 2
          continue
        }
        const x = na.x + (nb.x - na.x) * p.t
        const y = na.y + (nb.y - na.y) * p.t
        const glow = ctx!.createRadialGradient(x, y, 0, x, y, 7)
        glow.addColorStop(0, 'rgba(46,219,143,0.95)')
        glow.addColorStop(1, 'rgba(46,219,143,0)')
        ctx!.fillStyle = glow
        ctx!.beginPath()
        ctx!.arc(x, y, 7, 0, Math.PI * 2)
        ctx!.fill()
        ctx!.beginPath()
        ctx!.arc(x, y, 2, 0, Math.PI * 2)
        ctx!.fillStyle = '#eafff2'
        ctx!.fill()
      }

      raf = requestAnimationFrame(frame)
    }

    function onResize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2)
      build()
    }

    function onVisibility() {
      running = !document.hidden
      if (running) raf = requestAnimationFrame(frame)
      else cancelAnimationFrame(raf)
    }

    build()
    if (reduce) {
      frame(0) // one static frame (cube + mesh, no ring/packet motion)
      running = false
      cancelAnimationFrame(raf)
    } else {
      raf = requestAnimationFrame(frame)
    }
    window.addEventListener('resize', onResize)
    document.addEventListener('visibilitychange', onVisibility)

    return () => {
      running = false
      cancelAnimationFrame(raf)
      window.removeEventListener('resize', onResize)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [])

  return <canvas ref={canvasRef} className={className} />
}
