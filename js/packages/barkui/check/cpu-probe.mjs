// Throwaway probe, never merged: CPU seconds per process kind under this node process, read from /proc (Linux).
import { readdirSync, readFileSync } from 'node:fs'
import { availableParallelism, loadavg } from 'node:os'
import { performance } from 'node:perf_hooks'

const TICK = 100
const read = (p) => {
  try {
    return readFileSync(p, 'utf8')
  } catch {
    return null
  }
}
function kindOf(pid, cmd) {
  if (pid === process.pid) return 'node'
  const t = cmd.match(/--type=([\w-]+)/)
  if (t) return t[1] === 'gpu-process' ? 'gpu' : t[1] === 'utility' ? `utility(${(cmd.match(/--utility-sub-type=([\w.]+)/) ?? [])[1] ?? '?'})` : t[1]
  return /chrom|headless/.test(cmd) ? 'browser' : `other(${cmd.split(' ')[0].split('/').pop()})`
}

export function startCpuProbe(label) {
  const seen = new Map()
  const threads = new Map()
  const t0 = performance.now()
  const elu0 = performance.eventLoopUtilization()
  const series = []
  let lastWin = { t: t0, tot: 0, by: new Map() }
  const sample = () => {
    const ppid = new Map()
    const stat = new Map()
    for (const d of readdirSync('/proc')) {
      if (!/^\d+$/.test(d)) continue
      const s = read(`/proc/${d}/stat`)
      if (!s) continue
      const f = s.slice(s.lastIndexOf(')') + 2).split(' ')
      ppid.set(+d, +f[1])
      stat.set(+d, (+f[11] + +f[12]) / TICK)
    }
    const mine = (pid) => {
      for (let p = pid, i = 0; p && i < 40; p = ppid.get(p), i++) if (p === process.pid) return true
      return false
    }
    for (const [pid, cpu] of stat) {
      if (!mine(pid)) continue
      let e = seen.get(pid)
      if (!e) {
        const cmd = (read(`/proc/${pid}/cmdline`) ?? '').replace(/\0/g, ' ')
        e = { kind: kindOf(pid, cmd), base: pid === process.pid ? cpu : 0, cpu, first: performance.now() }
        seen.set(pid, e)
      }
      e.cpu = cpu
      e.last = performance.now()
      if (pid === process.pid) continue
      let tids = []
      try {
        tids = readdirSync(`/proc/${pid}/task`)
      } catch {}
      for (const t of tids) {
        const ts = read(`/proc/${pid}/task/${t}/stat`)
        if (!ts) continue
        const comm = ts.slice(ts.indexOf('(') + 1, ts.lastIndexOf(')')).replace(/\d+$/, '')
        const g = ts.slice(ts.lastIndexOf(')') + 2).split(' ')
        threads.set(`${pid}/${t}`, { key: `${e.kind} ${comm}`, cpu: (+g[11] + +g[12]) / TICK })
      }
    }
  }
  const total = () => {
    const by = new Map()
    for (const e of seen.values()) by.set(e.kind, (by.get(e.kind) ?? 0) + (e.cpu - e.base))
    return by
  }
  const top = () => [...seen.entries()].map(([pid, e]) => ({ pid, ...e })).sort((a, b) => (b.cpu - b.base) - (a.cpu - a.base))
  const timer = setInterval(() => {
    sample()
    const now = performance.now()
    if (now - lastWin.t >= 30000) {
      const by = total()
      const tot = [...by.values()].reduce((a, b) => a + b, 0)
      const secs = (now - lastWin.t) / 1000
      const shares = [...by].map(([k, v]) => [k, (v - (lastWin.by.get(k) ?? 0)) / secs]).filter(([, v]) => v > 0.05).sort((a, b) => b[1] - a[1])
      series.push(`cpu-probe ${label} @${((now - t0) / 1000).toFixed(0)} s: ${((tot - lastWin.tot) / secs).toFixed(2)} cores; ${shares.map(([k, v]) => `${k} ${v.toFixed(2)}`).join(', ')}; load ${loadavg()[0].toFixed(1)}`)
      lastWin = { t: now, tot, by }
    }
  }, 500)
  timer.unref()
  sample()
  return () => {
    clearInterval(timer)
    sample()
    const wall = (performance.now() - t0) / 1000
    const by = total()
    const sum = [...by.values()].reduce((a, b) => a + b, 0)
    const counts = new Map()
    for (const e of seen.values()) counts.set(e.kind, (counts.get(e.kind) ?? 0) + 1)
    const elu = performance.eventLoopUtilization(elu0)
    const lines = [...series]
    lines.push(`cpu-probe ${label}: wall ${wall.toFixed(1)} s, ${availableParallelism()} cpus, all kinds ${sum.toFixed(1)} cpu s = ${(sum / wall).toFixed(2)} cores; node event loop ${(elu.utilization * 100).toFixed(0)}% busy`)
    for (const [k, v] of [...by].sort((a, b) => b[1] - a[1])) lines.push(`cpu-probe ${label}: ${k}: ${v.toFixed(1)} cpu s over ${counts.get(k)} process(es), ${(v / wall).toFixed(2)} cores`)
    const th = new Map()
    for (const t of threads.values()) th.set(t.key, (th.get(t.key) ?? 0) + t.cpu)
    for (const [k, v] of [...th].sort((a, b) => b[1] - a[1]).slice(0, 14)) lines.push(`cpu-probe ${label}: thread ${k}: ${v.toFixed(1)} cpu s, ${(v / wall).toFixed(2)} cores`)
    for (const e of top().slice(0, 6)) lines.push(`cpu-probe ${label}: busiest pid ${e.pid} ${e.kind}: ${(e.cpu - e.base).toFixed(1)} cpu s in ${((e.last - e.first) / 1000).toFixed(0)} s seen = ${((e.cpu - e.base) / Math.max(1, (e.last - e.first) / 1000)).toFixed(2)} of a core`)
    for (const l of lines) console.log(l)
  }
}
