// Throwaway timing probe, never merged: reads one set of parts, three at once, on one runner, with a CPU sampler.
// BARKUI_PROBE_OWN=1 gives each part its own browser. node check/time-probe.mjs button,checkbox,dialog,menu,radio
import { runCheck } from './check.mjs'
import { startCpuProbe } from './cpu-probe.mjs'
import { materialize } from './jobs.mjs'

const dir = materialize()
const names = process.argv[2].split(',')
const arm = process.env.BARKUI_PROBE_PAGE === '1' ? 'P (a page per part and its follower)' : 'S (the group page)'
console.log(`probe: arm ${arm}: ${names.join(', ')}`)
const stop = startCpuProbe(arm.slice(0, 1))
const began = performance.now()
const { ok } = await runCheck({ dir, names })
stop()
console.log(`probe: arm ${arm} ${ok ? 'passed' : 'failed'} in ${((performance.now() - began) / 1000).toFixed(1)} s`)
process.exit(0)
