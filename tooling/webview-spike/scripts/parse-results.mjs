#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// parse-results.mjs — turn the raw measurement output in ./results/ into the
// numeric D11 verdict table (PASS/FAIL per axis + overall). SPIKE ARTIFACT.
//
// Inputs (written by scripts/run-*.sh):
//   results/cold-load-inline.log      lines: cold-load variant=inline rn_ms=N dom_ms=M
//   results/cold-load-file.log        same, variant=file
//   results/scroll-inline.framestats  dumpsys gfxinfo <pkg> framestats dump
//   results/memory-warm0.meminfo      dumpsys meminfo <pkg> (1 active WebView)
//   results/memory-warm3.meminfo      dumpsys meminfo <pkg> (1 active + 3 warm)
//   results/device.txt                key=value device identification
//
// Output: verdict table on stdout + results/RESULTS.md.
//
// D11 thresholds (fixed at Decide — any single FAIL => overall FAIL => the
// native prose fast-path promotes into v1 and wave 2's renderer budget
// re-plans, crown cr-059):
//   cold-load  P50 <= 800 ms, P95 <= 1500 ms (10 runs; graded on the inline
//              variant — the shippable primary; file/baseUrl is axis 4)
//   scroll     >= 50 fps avg, <= 17% janky (16.6 ms budget), 0 frames > 100 ms
//   memory     <= 350 MB total PSS with 3-4 warm WebViews; <= 60 MB marginal each
//   file vs inline  cold-load P50 <= 1.3x inline OR <= +200 ms

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// BPSPIKE_RESULTS_DIR override lets the fixture self-test (scripts/test-parse.sh)
// exercise the parser without touching a real results/ run.
const RESULTS =
  process.env.BPSPIKE_RESULTS_DIR || join(dirname(fileURLToPath(import.meta.url)), '..', 'results')

const read = (name) => (existsSync(join(RESULTS, name)) ? readFileSync(join(RESULTS, name), 'utf8') : null)
const fmt = (v, unit = '') => (v === null || Number.isNaN(v) ? 'n/a' : `${typeof v === 'number' && !Number.isInteger(v) ? v.toFixed(1) : v}${unit}`)

// nearest-rank percentile
function pct(sorted, q) {
  if (!sorted.length) return null
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1))]
}

function coldLoad(name) {
  const raw = read(name)
  if (!raw) return null
  const vals = [...raw.matchAll(/rn_ms=(\d+)/g)].map((m) => Number(m[1])).sort((a, b) => a - b)
  if (!vals.length) return null
  return { n: vals.length, p50: pct(vals, 0.5), p95: pct(vals, 0.95), vals }
}

// dumpsys gfxinfo framestats: ---PROFILEDATA--- CSV sections; frame duration =
// (FRAME_COMPLETED - INTENDED_VSYNC) / 1e6 ms; Flags != 0 rows are excluded
// (first-draw / surface-changed frames, per the Android docs).
// run-scroll.sh dumps + resets after EVERY swipe (framestats retains only
// ~120 frames), so one file carries many sections — ALL are aggregated here,
// which is what makes the strict 0-frames>100ms axis cover the whole pass.
function scroll(name) {
  const raw = read(name)
  if (!raw) return null
  const durations = []
  let sectionCount = 0
  const sections = raw.split('---PROFILEDATA---')
  for (let i = 1; i < sections.length; i += 2) {
    const lines = sections[i].trim().split('\n')
    const header = lines[0].split(',').map((s) => s.trim())
    const fFlags = header.indexOf('Flags')
    const fIntended = header.indexOf('IntendedVsync')
    const fCompleted = header.indexOf('FrameCompleted')
    if (fFlags < 0 || fIntended < 0 || fCompleted < 0) continue
    sectionCount++
    for (const line of lines.slice(1)) {
      const cols = line.split(',')
      if (cols.length <= fCompleted) continue
      const flags = Number(cols[fFlags])
      const dur = (Number(cols[fCompleted]) - Number(cols[fIntended])) / 1e6
      if (flags === 0 && Number.isFinite(dur) && dur > 0) durations.push(dur)
    }
  }
  if (!durations.length) return null
  const mean = durations.reduce((a, b) => a + b, 0) / durations.length
  return {
    frames: durations.length,
    sections: sectionCount,
    avgFps: 1000 / mean,
    jankyPct: (100 * durations.filter((d) => d > 16.6).length) / durations.length,
    over100: durations.filter((d) => d > 100).length,
  }
}

// dumpsys meminfo: prefer the App Summary "TOTAL PSS:" line; fall back to the
// legacy "TOTAL <kb>" table row. Values are KB.
function pssMb(name) {
  const raw = read(name)
  if (!raw) return null
  let m = raw.match(/TOTAL\s+PSS:\s*([\d,]+)/)
  if (!m) m = raw.match(/^\s*TOTAL\s+(\d+)/m)
  if (!m) return null
  return Number(m[1].replace(/,/g, '')) / 1024
}

const device = Object.fromEntries(
  (read('device.txt') || '')
    .split('\n')
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)

const inline = coldLoad('cold-load-inline.log')
const file = coldLoad('cold-load-file.log')
const sc = scroll('scroll-inline.framestats')
const warm0 = pssMb('memory-warm0.meminfo')
const warm3 = pssMb('memory-warm3.meminfo')
const marginal = warm0 !== null && warm3 !== null ? (warm3 - warm0) / 3 : null
const ratio = inline && file ? file.p50 / inline.p50 : null
const delta = inline && file ? file.p50 - inline.p50 : null

// ---- grade -----------------------------------------------------------------
const rows = []
function grade(axis, metric, value, threshold, pass) {
  rows.push({ axis, metric, value, threshold, verdict: value === null || value === undefined || Number.isNaN(value) ? 'MISSING' : pass ? 'PASS' : 'FAIL' })
}

grade('1 cold-load', `P50 (inline, n=${inline?.n ?? 0})`, inline?.p50 ?? null, '<= 800 ms', inline && inline.p50 <= 800)
grade('1 cold-load', 'P95 (inline)', inline?.p95 ?? null, '<= 1500 ms', inline && inline.p95 <= 1500)
grade('2 scroll', `avg fps (${sc?.frames ?? 0} frames / ${sc?.sections ?? 0} sections)`, sc ? Number(sc.avgFps.toFixed(1)) : null, '>= 50 fps', sc && sc.avgFps >= 50)
grade('2 scroll', 'janky % (>16.6 ms)', sc ? Number(sc.jankyPct.toFixed(1)) : null, '<= 17 %', sc && sc.jankyPct <= 17)
grade('2 scroll', 'frames > 100 ms', sc?.over100 ?? null, '= 0', sc && sc.over100 === 0)
grade('3 memory', 'total PSS, 4 WebViews (MB)', warm3 !== null ? Number(warm3.toFixed(1)) : null, '<= 350 MB', warm3 !== null && warm3 <= 350)
grade('3 memory', 'marginal per warm WebView (MB)', marginal !== null ? Number(marginal.toFixed(1)) : null, '<= 60 MB', marginal !== null && marginal <= 60)
grade(
  '4 file vs inline',
  `file P50 / inline P50 (file P50 ${fmt(file?.p50, ' ms')})`,
  ratio !== null ? Number(ratio.toFixed(2)) : null,
  '<= 1.3x OR <= +200 ms',
  ratio !== null && (ratio <= 1.3 || delta <= 200),
)

const missing = rows.filter((r) => r.verdict === 'MISSING')
const failed = rows.filter((r) => r.verdict === 'FAIL')
const overall = missing.length ? 'INCOMPLETE' : failed.length ? 'FAIL' : 'PASS'
const isEmulator = device.emulator === '1'
// Debug APKs skew every axis: the run is advisory regardless of where it ran
// (review F4). run-all.sh writes build= from dumpsys package DEBUGGABLE.
const isDebug = device.build === 'debug'
const advisoryReasons = [
  ...(isEmulator ? ['emulator'] : []),
  ...(isDebug ? ['debug APK'] : []),
]
const advisory = advisoryReasons.length > 0
const advisoryTag = advisory ? ` [${advisoryReasons.join(' + ').toUpperCase()} — ADVISORY ONLY]` : ''

// ---- render ----------------------------------------------------------------
const pad = (s, n) => String(s).padEnd(n)
let table = `${pad('axis', 18)}${pad('metric', 42)}${pad('value', 12)}${pad('threshold', 24)}verdict\n`
for (const r of rows) table += `${pad(r.axis, 18)}${pad(r.metric, 42)}${pad(fmt(r.value), 12)}${pad(r.threshold, 24)}${r.verdict}\n`

console.log(`\nD11 verdict — device: ${device.model || 'unknown'} (Android ${device.android || '?'})${advisoryTag}\n`)
console.log(table)
console.log(`OVERALL: ${overall}${advisory ? ` (ADVISORY — ${advisoryReasons.join(' + ')}; the binding verdict requires real mid-tier hardware on a RELEASE build)` : ''}`)
if (overall === 'FAIL') console.log('Consequence (charter D11): native prose fast-path promotes into v1; wave-2 renderer budget re-plans (crown cr-059).')

const md = `# WebView spike — D11 results

- **Date:** ${new Date().toISOString().slice(0, 10)}
- **Device:** ${device.model || 'UNKNOWN'} (${device.device || '?'}, Android ${device.android || '?'}, SDK ${device.sdk || '?'})
- **System WebView:** ${device.webview || 'unknown'}
- **react-native-webview:** 13.16.1 · Expo SDK 57 · RN 0.86 · new architecture
- **Run kind:** ${advisory ? `ADVISORY ONLY (${advisoryReasons.join(' + ')}) — NOT the binding verdict` : 'real hardware, release build (binding-verdict eligible)'}
- **Build:** ${device.build || 'unknown'} (auto-detected via dumpsys package DEBUGGABLE; release required for the binding verdict)

| Axis | Metric | Value | Threshold | Verdict |
|---|---|---|---|---|
${rows.map((r) => `| ${r.axis} | ${r.metric} | ${fmt(r.value)} | ${r.threshold} | ${r.verdict} |`).join('\n')}

## Overall: **${overall}**

${overall === 'FAIL' ? '> Any single FAIL promotes the native prose fast-path into v1 and re-plans wave 2’s renderer budget (charter D11, crown cr-059).\n' : ''}
Cold-load detail: inline ${inline ? inline.vals.join(', ') : 'n/a'} ms · file ${file ? file.vals.join(', ') : 'n/a'} ms (rn_ms = WebView mount → FMP, double-rAF after DOMContentLoaded).
Notes: 3 mermaid mounts stay inert (mermaid not bundled). avg fps = 1000 / mean frame duration over Flags==0 frames; janky = frames over the 16.6 ms budget.
Scroll coverage: framestats dumped + reset after EVERY swipe (gfxinfo retains only ~120 frames) — ${sc ? `${sc.sections} sections aggregated, ${sc.frames} frames graded` : 'n/a'} across the whole pass, not just its tail.
`
writeFileSync(join(RESULTS, 'RESULTS.md'), md)
console.log(`\nwrote ${join(RESULTS, 'RESULTS.md')}`)
if (overall !== 'PASS') process.exitCode = overall === 'FAIL' ? 2 : 3
