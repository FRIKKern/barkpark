// Throwaway timing probe, never merged: reads each named set of parts in turn, three at once, on one runner,
// and prints each set's time lines. node check/slow-probe.mjs dialog,switch,tabs dialog,menu,tabs
import { runCheck } from './check.mjs'
import { materialize } from './jobs.mjs'

const dir = materialize()
for (const set of process.argv.slice(2)) {
  const names = set.split(',')
  console.log(`probe: set ${names.join(', ')}`)
  const began = performance.now()
  const { ok } = await runCheck({ dir, names })
  console.log(`probe: set ${names.join(', ')} ${ok ? 'passed' : 'failed'} in ${((performance.now() - began) / 1000).toFixed(1)} s`)
}
