// node check/run.mjs: the showroom check over parts/. Exits non-zero when a part
// folder is incomplete, a press step fails, a light stays off, the page logs an
// error or asks the network, or anything runs past its time limit.
import { runCheck } from './check.mjs'

const { ok } = await runCheck()
process.exit(ok ? 0 : 1)
