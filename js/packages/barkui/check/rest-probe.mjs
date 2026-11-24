// Local throwaway: where a world call's time goes, for the button alone on the page of every part.
import { runCheck } from './check.mjs'
const names = process.argv.slice(2)
const t = performance.now()
const { ok } = await runCheck(names.length ? { names } : {})
console.log(`rest-probe: ${names.join(',') || 'all'} ${ok} in ${((performance.now() - t) / 1000).toFixed(1)} s`)
