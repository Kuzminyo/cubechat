import { useEffect, useRef } from 'react'

type GNode = { x: number; y: number; heat: number }
type Ambient = { a: number; b: number; t: number; speed: number }

/**
 * The "how it works" centrepiece: a big field of mesh dots with a fixed
 * source (You) and destination (Aisha). A packet routes multi-hop across the
 * grid; on every send a few random relays "drop out of range", so the shortest
 * path is recomputed and visibly changes — the mesh healing itself, live.
 */
export default function MeshGrid({ you, dest }: { you: string; dest: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const labels = useRef({ you, dest })
  labels.current = { you, dest }

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const rand = (a: number, b: number) => a + Math.random() * (b - a)
    const ek = (a: number, b: number) => (a < b ? `${a}-${b}` : `${b}-${a}`)

    let width = 0
    let height = 0
    let dpr = Math.min(window.devicePixelRatio || 1, 2)

    let nodes: GNode[] = []
    let adj: number[][] = []
    let edges: [number, number][] = []
    let src = 0
    let dst = 0
    let route: number[] = []
    let down = new Set<number>()
    const edgeHeat: Record<string, number> = {}
    let packet = { seg: 0, t: 0, speed: 0.02 }
    let arriving = false
    let holdUntil = 0
    let ambients: Ambient[] = []

    let raf = 0
    let running = true
    let lastFrame = -1000
    let lastAmbient = 0

    function bfs(source: number, target: number, blocked: Set<number>): number[] | null {
      const N = nodes.length
      const prev = new Array<number>(N).fill(-1)
      const seen = new Array<boolean>(N).fill(false)
      const q = [source]
      seen[source] = true
      while (q.length) {
        const u = q.shift()!
        if (u === target) break
        for (const v of adj[u]) {
          if (seen[v] || blocked.has(v)) continue
          seen[v] = true
          prev[v] = u
          q.push(v)
        }
      }
      if (!seen[target]) return null
      const path: number[] = []
      let c = target
      while (c !== -1) {
        path.push(c)
        c = prev[c]
      }
      return path.reverse()
    }

    function newRoute() {
      const N = nodes.length
      const blocked = new Set<number>()
      const drop = Math.floor(N * 0.12)
      for (let k = 0; k < drop; k++) {
        const idx = Math.floor(Math.random() * N)
        if (idx !== src && idx !== dst) blocked.add(idx)
      }
      let path = bfs(src, dst, blocked)
      if (!path) {
        blocked.clear()
        path = bfs(src, dst, blocked)
      }
      down = blocked
      route = path || [src, dst]
      packet = { seg: 0, t: 0, speed: rand(0.016, 0.024) }
      arriving = false
      holdUntil = 0
    }

    function build() {
      const rect = canvas!.getBoundingClientRect()
      width = rect.width
      height = rect.height
      canvas!.width = Math.floor(width * dpr)
      canvas!.height = Math.floor(height * dpr)
      ctx!.setTransform(dpr, 0, 0, dpr, 0, 0)

      const cols = Math.max(6, Math.min(14, Math.round(width / 86)))
      const rows = Math.max(4, Math.min(9, Math.round(height / 74)))
      const cellW = width / cols
      const cellH = height / rows
      const jit = Math.min(cellW, cellH) * 0.26

      nodes = []
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          nodes.push({
            x: (c + 0.5) * cellW + rand(-jit, jit),
            y: (r + 0.5) * cellH + rand(-jit, jit),
            heat: 0,
          })
        }
      }

      // adjacency by proximity (incl. diagonals)
      const thresh = Math.hypot(cellW, cellH) * 1.28
      adj = nodes.map(() => [])
      edges = []
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const d = Math.hypot(nodes[i].x - nodes[j].x, nodes[i].y - nodes[j].y)
          if (d < thresh) {
            adj[i].push(j)
            adj[j].push(i)
            edges.push([i, j])
          }
        }
      }

      // source bottom-left, destination top-right
      const nearest = (tx: number, ty: number) => {
        let best = 0
        let bd = Infinity
        nodes.forEach((n, i) => {
          const d = Math.hypot(n.x - tx, n.y - ty)
          if (d < bd) {
            bd = d
            best = i
          }
        })
        return best
      }
      src = nearest(width * 0.08, height * 0.84)
      dst = nearest(width * 0.92, height * 0.16)

      for (const k of Object.keys(edgeHeat)) delete edgeHeat[k]
      ambients = []
      newRoute()
    }

    function pos(i: number) {
      return nodes[i]
    }

    function draw(now: number) {
      ctx!.clearRect(0, 0, width, height)

      // ---- base links ----
      ctx!.lineWidth = 1
      for (const [i, j] of edges) {
        if (down.has(i) || down.has(j)) continue
        ctx!.strokeStyle = 'rgba(127,217,166,0.06)'
        ctx!.beginPath()
        ctx!.moveTo(nodes[i].x, nodes[i].y)
        ctx!.lineTo(nodes[j].x, nodes[j].y)
        ctx!.stroke()
      }

      // ---- planned route (dim) ----
      if (route.length > 1) {
        ctx!.strokeStyle = 'rgba(46,219,143,0.16)'
        ctx!.lineWidth = 1.4
        ctx!.beginPath()
        ctx!.moveTo(nodes[route[0]].x, nodes[route[0]].y)
        for (let i = 1; i < route.length; i++) ctx!.lineTo(nodes[route[i]].x, nodes[route[i]].y)
        ctx!.stroke()
      }

      // ---- heated (travelled) edges ----
      for (const key of Object.keys(edgeHeat)) {
        const h = edgeHeat[key]
        if (h < 0.02) {
          delete edgeHeat[key]
          continue
        }
        const [a, b] = key.split('-').map(Number)
        ctx!.strokeStyle = `rgba(46,219,143,${(0.25 + h * 0.6).toFixed(3)})`
        ctx!.lineWidth = 1.4 + h * 1.4
        ctx!.beginPath()
        ctx!.moveTo(nodes[a].x, nodes[a].y)
        ctx!.lineTo(nodes[b].x, nodes[b].y)
        ctx!.stroke()
        if (!reduce) edgeHeat[key] = h * 0.94
      }

      // ---- nodes ----
      for (let i = 0; i < nodes.length; i++) {
        if (i === src || i === dst) continue
        const n = nodes[i]
        const isDown = down.has(i)
        const heat = n.heat
        const r = 1.7 + heat * 2.4
        if (isDown) {
          ctx!.fillStyle = 'rgba(130,130,140,0.14)'
        } else if (heat > 0.02) {
          ctx!.fillStyle = `rgba(${(200 + heat * 55) | 0},255,${(210 + heat * 45) | 0},${(0.35 + heat * 0.6).toFixed(3)})`
        } else {
          ctx!.fillStyle = 'rgba(127,217,166,0.28)'
        }
        ctx!.beginPath()
        ctx!.arc(n.x, n.y, r, 0, Math.PI * 2)
        ctx!.fill()
        if (!reduce) n.heat = heat * 0.93
      }

      // ---- ambient background traffic ----
      if (!reduce && now - lastAmbient > 620 && ambients.length < 6 && edges.length) {
        const [a, b] = edges[(Math.random() * edges.length) | 0]
        if (!down.has(a) && !down.has(b)) ambients.push({ a, b, t: 0, speed: rand(0.02, 0.05) })
        lastAmbient = now
      }
      ambients = ambients.filter((p) => p.t <= 1)
      for (const p of ambients) {
        if (!reduce) p.t += p.speed
        const x = nodes[p.a].x + (nodes[p.b].x - nodes[p.a].x) * p.t
        const y = nodes[p.a].y + (nodes[p.b].y - nodes[p.a].y) * p.t
        ctx!.fillStyle = 'rgba(127,217,166,0.5)'
        ctx!.beginPath()
        ctx!.arc(x, y, 1.6, 0, Math.PI * 2)
        ctx!.fill()
      }

      // ---- endpoints (You / Aisha) ----
      drawEndpoint(pos(src), '#2edb8f', labels.current.you, now, -1)
      drawEndpoint(pos(dst), '#a3e635', labels.current.dest, now, 1)

      // ---- main packet ----
      if (route.length > 1 && !arriving) {
        const a = nodes[route[packet.seg]]
        const b = nodes[route[Math.min(packet.seg + 1, route.length - 1)]]
        const x = a.x + (b.x - a.x) * packet.t
        const y = a.y + (b.y - a.y) * packet.t
        // trailing comet
        const tx = a.x + (b.x - a.x) * Math.max(0, packet.t - 0.5)
        const ty = a.y + (b.y - a.y) * Math.max(0, packet.t - 0.5)
        const trail = ctx!.createLinearGradient(tx, ty, x, y)
        trail.addColorStop(0, 'rgba(46,219,143,0)')
        trail.addColorStop(1, 'rgba(46,219,143,0.7)')
        ctx!.strokeStyle = trail
        ctx!.lineWidth = 2.4
        ctx!.beginPath()
        ctx!.moveTo(tx, ty)
        ctx!.lineTo(x, y)
        ctx!.stroke()
        // glow + core
        const g = ctx!.createRadialGradient(x, y, 0, x, y, 10)
        g.addColorStop(0, 'rgba(234,255,242,0.95)')
        g.addColorStop(0.4, 'rgba(46,219,143,0.8)')
        g.addColorStop(1, 'rgba(46,219,143,0)')
        ctx!.fillStyle = g
        ctx!.beginPath()
        ctx!.arc(x, y, 10, 0, Math.PI * 2)
        ctx!.fill()
        ctx!.fillStyle = '#eafff2'
        ctx!.beginPath()
        ctx!.arc(x, y, 2.4, 0, Math.PI * 2)
        ctx!.fill()
      }

      // ---- advance packet ----
      if (!reduce) {
        if (arriving) {
          if (now > holdUntil) newRoute()
        } else if (route.length > 1) {
          const key = ek(route[packet.seg], route[Math.min(packet.seg + 1, route.length - 1)])
          edgeHeat[key] = Math.max(edgeHeat[key] || 0, 0.55)
          nodes[route[packet.seg]].heat = Math.max(nodes[route[packet.seg]].heat, 0.7)
          packet.t += packet.speed
          if (packet.t >= 1) {
            const reached = route[packet.seg + 1]
            if (reached !== undefined) nodes[reached].heat = 1
            edgeHeat[key] = 1
            packet.seg++
            packet.t = 0
            if (packet.seg >= route.length - 1) {
              arriving = true
              holdUntil = now + 950
              nodes[dst].heat = 1
            }
          }
        }
      }
    }

    function drawEndpoint(n: GNode, color: string, label: string, now: number, dir: number) {
      // pulse ring
      if (!reduce) {
        const phase = (now / 1600) % 1
        ctx!.strokeStyle = `rgba(46,219,143,${(0.35 * (1 - phase)).toFixed(3)})`
        ctx!.lineWidth = 1.4
        ctx!.beginPath()
        ctx!.arc(n.x, n.y, 9 + phase * 20, 0, Math.PI * 2)
        ctx!.stroke()
      }
      // halo
      const halo = ctx!.createRadialGradient(n.x, n.y, 0, n.x, n.y, 22)
      halo.addColorStop(0, color === '#2edb8f' ? 'rgba(46,219,143,0.4)' : 'rgba(163,230,53,0.4)')
      halo.addColorStop(1, 'rgba(0,0,0,0)')
      ctx!.fillStyle = halo
      ctx!.beginPath()
      ctx!.arc(n.x, n.y, 22, 0, Math.PI * 2)
      ctx!.fill()
      // core
      ctx!.fillStyle = color
      ctx!.beginPath()
      ctx!.arc(n.x, n.y, 7, 0, Math.PI * 2)
      ctx!.fill()
      ctx!.strokeStyle = 'rgba(255,255,255,0.55)'
      ctx!.lineWidth = 1.5
      ctx!.stroke()
      // label
      ctx!.font = '600 13px "JetBrains Mono", ui-monospace, monospace'
      ctx!.textAlign = 'center'
      ctx!.fillStyle = 'rgba(255,255,255,0.72)'
      ctx!.fillText(label, n.x, n.y + (dir < 0 ? 30 : -20))
    }

    function frame(now: number) {
      if (!running) return
      if (now - lastFrame < 33) {
        raf = requestAnimationFrame(frame)
        return
      }
      lastFrame = now
      draw(now)
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
      draw(0)
      running = false
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

  return <canvas ref={canvasRef} className="h-[340px] w-full sm:h-[420px] md:h-[460px]" />
}
