// epic-cycle-resume.test.mjs — what a resume of .claude/workflows/bp-epic-cycle.workflow.js
// actually replays, measured by COUNTING DISPATCHES, never by started/result rows.
//
//   node --test scripts/epic-cycle-resume.test.mjs
//
// THE MODEL OF THE WORKFLOW TOOL (task-d1cecb3cb94aa97a). The tool's docs say
// only "the longest unchanged prefix of agent() calls returns cached results".
// The precise rule below was read out of the Claude Code 2.1.281 binary
// (functions io/fr/so and the agent() hook) and is CHECKED against a real
// recorded run in the last arm, which re-derives 36 of that run's 37 journal
// keys byte for byte:
//
//   key_n  = "v2:" + sha256(key_{n-1} "\0" prompt "\0" canon(opts)),  key_0 = ""
//            canon keeps schema/model/effort/isolation/agentType/
//            disallowedTools/bashCommandClamp, keys sorted; label/phase are OUT
//   replay : not latched AND the journal has a `result` row for key_n
//   miss   : latch LIVE for the rest of the run, UNLESS the key was `started`,
//            never `failed`, and has no result (in flight at the kill: respawn)
//   null   : a dispatch that returns null appends `failed`, never `result`
//
// Every arm runs the REAL workflow file end to end with a stub agent(), so the
// prompts, the call order, neverLose and the carry path are the shipped ones.
// "dispatches" = live agent() spawns = agent-<id>.jsonl files a real run would
// write. A journal's started/result rows cannot tell a replay from a restart
// (result rows are written only on completion); this file never counts them.

import test from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { extractCarry, compactCarry, parseJournal } from './epic-cycle-carry.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const WORKFLOW = path.join(ROOT, '.claude/workflows/bp-epic-cycle.workflow.js')

// ── the harness model ───────────────────────────────────────────────────────
const OPT_KEYS = ['schema', 'model', 'effort', 'isolation', 'agentType', 'disallowedTools', 'bashCommandClamp']
const canonical = (v) => {
  if (typeof v === 'function') return undefined
  if (Array.isArray(v)) return v.map(canonical)
  if (v && typeof v === 'object') {
    const o = {}
    for (const k of Object.keys(v).sort()) if (k !== '__proto__') o[k] = canonical(v[k])
    return o
  }
  return v
}
const canonOpts = (opts) => {
  if (!opts) return '{}'
  const r = {}
  for (const k of OPT_KEYS) if (opts[k] !== undefined && typeof opts[k] !== 'function') r[k] = opts[k]
  return JSON.stringify(canonical(r))
}
export const chainKey = (prev, prompt, opts) =>
  'v2:' + crypto.createHash('sha256').update(prev).update('\0').update(prompt).update('\0').update(canonOpts(opts)).digest('hex')

function loadJournal(rows) {
  const results = new Map(), started = new Map(), failed = new Set()
  for (const r of rows) {
    if (r.type === 'result') results.set(r.key, r)
    else if (r.type === 'started') started.set(r.key, (started.get(r.key) || 0) + 1)
    else if (r.type === 'failed') failed.add(r.key)
  }
  return { results, started, failed }
}

const PHASE_OF = (label) =>
  label === 'strategist' ? 'Strategize' : label === 'digest' ? 'Digest' : label === 'architect' ? 'Decide'
    : label === 'review' ? 'Review' : label.startsWith('survey:') ? 'Survey' : label.startsWith('verify:') ? 'Verify'
      : label.startsWith('build:') ? 'Build' : 'other'

// Run the workflow once. `journal` = rows of a prior run to resume from (or []),
// `behave(label, model)` = what a live dispatch returns (null = the agent died),
// `killAt(label)` = true to kill the run the moment that dispatch starts.
async function runWave({ args, journal = [], behave, killAt = () => false, script }) {
  const src = (script || fs.readFileSync(WORKFLOW, 'utf8')).replace(/^export\s+/gm, '')
  const J = loadJournal(journal)
  let prev = ''
  let latched = false
  const calls = [], out = [], logs = []
  let killed = false, onKill
  const killedP = new Promise((r) => { onKill = r })
  let ids = 0

  const agent = async (prompt, opts = {}) => {
    const label = opts.label || '?'
    const key = chainKey(prev, String(prompt), opts)
    prev = key
    const call = { label, phase: PHASE_OF(label), model: opts.model, key, replayed: false }
    calls.push(call)
    const hit = latched ? undefined : J.results.get(key)
    if (hit !== undefined) { call.replayed = true; return hit.result }
    if (!(!latched && J.started.get(key) > 0 && !J.failed.has(key))) latched = true
    const agentId = 'a' + String(++ids).padStart(16, '0')
    call.agentId = agentId
    out.push({ type: 'started', key, agentId })
    if (killAt(label)) { killed = true; onKill(); return new Promise(() => {}) }
    const res = behave(label, opts.model)
    if (res === null) out.push({ type: 'failed', key, agentId })
    else out.push({ type: 'result', key, agentId, result: JSON.parse(JSON.stringify(res)) })
    return res
  }
  // parallel(): the real one invokes every thunk synchronously, in order, then
  // allSettled — so first-attempt keys are call-order deterministic.
  const parallel = async (thunks) =>
    (await Promise.allSettled(thunks.map((t) => { try { return Promise.resolve(t()) } catch (e) { return Promise.reject(e) } })))
      .map((s) => (s.status === 'fulfilled' ? s.value : null))
  const pipeline = async (items, ...stages) =>
    parallel(items.map((it, i) => async () => { let v = it; for (const s of stages) v = await s(v, it, i); return v }))
  const AF = Object.getPrototypeOf(async function () {}).constructor
  const fn = new AF('args', 'agent', 'parallel', 'pipeline', 'phase', 'log', 'budget', 'workflow', src)
  const budget = { total: null, spent: () => 0, remaining: () => Infinity }
  let result, error
  await Promise.race([
    fn(args, agent, parallel, pipeline, () => {}, (m) => logs.push(m), budget, async () => null).then((r) => { result = r }, (e) => { error = e }),
    killedP,
  ])
  const live = calls.filter((c) => !c.replayed)
  const byPhase = (list) => list.reduce((m, c) => ({ ...m, [c.phase]: (m[c.phase] || 0) + 1 }), {})
  return { calls, live, dispatchesByPhase: byPhase(live), replayedByPhase: byPhase(calls.filter((c) => c.replayed)), journal: [...journal, ...out], result, error, killed, logs }
}

// ── a synthetic wave: shape-valid reports, deterministic per label ─────────
const SURVEY_KEYS = ['s1', 's2', 's3', 's4', 's5', 's6']
const VERIFY_KEYS = ['v1', 'v2', 'v3']
const SLICES = ['alpha', 'beta', 'gamma']
const journey = { mission: 'm', key_moments: [], outcome: 'o', meaning: 'x' }
const stamps = { started_at: '2026-09-25T00:00:00Z', ended_at: '2026-09-25T00:01:00Z' }
function report(label) {
  if (label === 'strategist') return { direction: 'DIRECTION-1', direction_debate: 'debate', paper_id: 'wave-paper', paper_created: true, candidates: [], survey: SURVEY_KEYS.map((key) => ({ key, question: `q ${key}`, why: 'w' })), journey, ...stamps }
  if (label.startsWith('survey:')) { const key = label.slice(7); return { key, findings: `found ${key}`, coverage: [{ path: 'a', checked_for: 'b', result: 'found', note: '' }], facts: [{ claim: 'c', evidence: 'e', rerun: 'true' }, { claim: 'c2', evidence: 'e2' }], risks: [], open_questions: [], journey } }
  if (label === 'digest') return { synthesis: 'SYNTHESIS-1', verification: VERIFY_KEYS.map((key) => ({ key, question: `q ${key}`, why: 'w', model: 'opus', verify_commands: 'true', needs_worktree: false })), paper_updated: true, heartbeat_stamped: true, journey, ...stamps }
  if (label.startsWith('verify:')) { const key = label.slice(7); return { key, findings: `verified ${key}`, coverage: [], facts: [{ claim: 'c', evidence: 'e', rerun: 'true' }], proofs: ['$ true', 'exit 0'], risks: [], journey } }
  if (label === 'architect') return { charter_written: true, charter_pr: '#1', wave_referent_task: 'task-ref', paper_updated: true, epic_task_id: 'task-epic', tasks_verified: true, backlog_filed: 'none', heartbeat_stamped: true, decisions_summary: 'DECIDED-1', doc_facts_routed: 'none', candidates_resolved: [], wave: SLICES.map((s) => ({ title: s, task_id: `task-${s}`, surface: 'x', files: [`${s}.js`], instructions: 'i', gate: 'true', size: 'S', builder_model: 'opus', round: 1 })), journey, ...stamps }
  if (label.startsWith('build:')) { const s = label.slice(6); return { ok: true, task_id: `task-${s}`, task_claimed: true, branch: `loop-epic/${s}`, summary: 'built', gate_command: 'true', gate_passed: true, review: 'r', files_changed: [`${s}.js`], ledger_stamps: 'ok', journey } }
  if (label === 'review') return { reviewed: [], ledger_fixes: 'none', wave_log_appended: true, grade: 'A', commentary: 'c', paper_closed: true, heartbeat_stamped: true, next_wave: 'n', overall_verdict: 'v', retro: [], telemetry_appended: true, stranded_worktrees: 'CLEAN exit 0', journey, ...stamps }
  throw new Error('no synthetic report for ' + label)
}
const ARGS = { wish: 'resume harness wish', charter_exists: false, lead_notes: '' }
const healthy = (label) => report(label)
// The incident shape: every Fable dispatch dies, so every joint succeeds only
// on its Opus fallback after three Fable failures.
const fableDown = (label, model) => (model === 'fable' ? null : report(label))
const killInBuild = (label) => label.startsWith('build:')
const PREFIX = ['Strategize', 'Survey', 'Digest', 'Verify', 'Decide']
const prefixDispatches = (run) => PREFIX.reduce((n, p) => n + (run.dispatchesByPhase[p] || 0), 0)

// ── arms ───────────────────────────────────────────────────────────────────
test('control: a wave with no null dispatch, killed in Build, replays its whole prefix on resume', async () => {
  const original = await runWave({ args: ARGS, behave: healthy, killAt: killInBuild })
  assert.equal(original.killed, true)
  assert.deepEqual(original.dispatchesByPhase, { Strategize: 1, Survey: 6, Digest: 1, Verify: 3, Decide: 1, Build: 3 })

  const resumed = await runWave({ args: ARGS, journal: original.journal, behave: healthy })
  assert.equal(resumed.error, undefined, String(resumed.error))
  assert.equal(prefixDispatches(resumed), 0, 'no agent in Strategize..Decide may dispatch on resume')
  assert.deepEqual(resumed.replayedByPhase, { Strategize: 1, Survey: 6, Digest: 1, Verify: 3, Decide: 1 })
  // the three builders were in flight at the kill: they respawn WITHOUT
  // latching, and Review (never started) runs live once.
  assert.deepEqual(resumed.dispatchesByPhase, { Build: 3, Review: 1 })
  assert.equal(resumed.result.direction, 'DIRECTION-1')
  assert.equal(resumed.result.surveys, 6)
  assert.equal(resumed.result.verifications, 3)
})

test('MECHANISM: joints that won on the Opus fallback make a plain resume re-buy the whole wave', async () => {
  const original = await runWave({ args: ARGS, behave: fableDown, killAt: killInBuild })
  assert.equal(original.killed, true)
  // 3 Fable nulls + 1 Opus win per joint
  assert.deepEqual(original.dispatchesByPhase, { Strategize: 4, Survey: 6, Digest: 4, Verify: 3, Decide: 4, Build: 3 })
  const failedKeys = new Set(original.journal.filter((r) => r.type === 'failed').map((r) => r.key))
  assert.equal(failedKeys.size, 9)

  const resumed = await runWave({ args: ARGS, journal: original.journal, behave: fableDown })
  // The keys do NOT diverge: the resumed run's first call carries exactly the
  // original's first key. That key is a FAILED row with no result, so the run
  // latches live right there and never looks at the journal again.
  assert.equal(resumed.calls[0].key, original.calls[0].key)
  assert.ok(failedKeys.has(resumed.calls[0].key))
  assert.equal(resumed.calls.filter((c) => c.replayed).length, 0, 'nothing replays')
  // …even though the Opus winner's result IS in the journal under the same key
  // the resumed run computes for its 4th call:
  assert.equal(resumed.calls[3].key, original.calls[3].key)
  assert.equal(original.journal.some((r) => r.type === 'result' && r.key === resumed.calls[3].key), true)
  assert.deepEqual(resumed.dispatchesByPhase, { Strategize: 4, Survey: 6, Digest: 4, Verify: 3, Decide: 4, Build: 3, Review: 4 })
  assert.equal(prefixDispatches(resumed), 21, 'the full prefix is re-bought')
})

test('the fix the row proposed (dispatch straight to the recorded winner) is inert: a chained key it never saw', async () => {
  const original = await runWave({ args: ARGS, behave: fableDown, killAt: killInBuild })
  // no_fable:true makes every joint dispatch Opus FIRST — exactly "replay
  // directly to the attempt that succeeded".
  const resumed = await runWave({ args: { ...ARGS, no_fable: true }, journal: original.journal, behave: fableDown })
  const known = new Set(original.journal.map((r) => r.key))
  assert.equal(known.has(resumed.calls[0].key), false, 'the Opus-first key chains from "" — the journal holds the Opus win under a key chained through three failures')
  assert.equal(resumed.calls.filter((c) => c.replayed).length, 0)
  assert.equal(prefixDispatches(resumed), 1 + 6 + 1 + 3 + 1)
})

test('FIX: args.carry from the incident journal skips every carried phase — zero prefix dispatches', async () => {
  const original = await runWave({ args: ARGS, behave: fableDown, killAt: killInBuild })
  for (const [name, carry] of [['compacted', compactCarry(extractCarry(original.journal).carry)], ['full', extractCarry(original.journal).carry]]) {
    assert.deepEqual(Object.keys(carry), ['strategist', 'surveys', 'aim', 'verifications', 'architect', 'built'], name)
    assert.equal(carry.surveys.length, 6, name)
    assert.equal(carry.verifications.length, 3, name)
    assert.equal(carry.built.length, 0, `${name}: the builders were killed, none carried`)
    const resumed = await runWave({ args: { ...ARGS, carry }, behave: fableDown })
    assert.equal(resumed.error, undefined, `${name}: ${resumed.error}`)
    assert.equal(prefixDispatches(resumed), 0, `${name}: nothing in Strategize..Decide dispatches`)
    assert.deepEqual(resumed.dispatchesByPhase, { Build: 3, Review: 4 }, name)
    // result shapes match the wave that was paid for
    assert.equal(resumed.result.direction, 'DIRECTION-1', name)
    assert.equal(resumed.result.synthesis, 'SYNTHESIS-1', name)
    assert.equal(resumed.result.decisions, 'DECIDED-1', name)
    assert.equal(resumed.result.surveys, 6, name)
    assert.equal(resumed.result.verifications, 3, name)
    assert.equal(resumed.result.proofs, 6, `${name}: proof COUNT survives compaction`)
    assert.equal(resumed.result.telemetry.interrupts.facts_demoted_no_rerun, 6, `${name}: demoted-fact count survives compaction`)
    assert.equal(resumed.result.built, 3, name)
  }
})

test('fresh-run behaviour is unchanged: with no carry, neverLose still recovers every joint', async () => {
  const run = await runWave({ args: ARGS, behave: fableDown })
  assert.equal(run.error, undefined, String(run.error))
  assert.deepEqual(run.dispatchesByPhase, { Strategize: 4, Survey: 6, Digest: 4, Verify: 3, Decide: 4, Build: 3, Review: 4 })
  assert.equal(run.result.built, 3)
  assert.ok(run.logs.some((l) => /RECOVER strategist: recovered on attempt 4 \(opus\)/.test(l)))
  assert.equal(run.logs.some((l) => l.startsWith('CARRY')), false)
})

test('a partial fleet carry finishes the fleet live instead of shrinking it', async () => {
  const original = await runWave({ args: ARGS, behave: healthy, killAt: (l) => l === 'digest' })
  const { carry } = extractCarry(original.journal)
  assert.deepEqual(Object.keys(carry), ['strategist', 'surveys'])
  carry.surveys = carry.surveys.filter((s) => s.key !== 's4') // s4 was lost
  const run = await runWave({ args: { ...ARGS, carry }, behave: healthy })
  assert.equal(run.dispatchesByPhase.Strategize, undefined)
  assert.equal(run.dispatchesByPhase.Survey, 1)
  assert.equal(run.live.find((c) => c.phase === 'Survey').label, 'survey:s4')
  assert.equal(run.result.surveys, 6)
})

test('a carry that is not a prefix is refused before anything dispatches', async () => {
  const original = await runWave({ args: ARGS, behave: healthy })
  const { carry } = extractCarry(original.journal)
  const run = await runWave({ args: { ...ARGS, carry: { aim: carry.aim } }, behave: healthy })
  assert.match(String(run.error), /args\.carry\.aim was given without args\.carry\.strategist/)
  assert.equal(run.calls.length, 0)
  const bad = await runWave({ args: { ...ARGS, carry: { strategist: carry.strategist, survey: [] } }, behave: healthy })
  assert.match(String(bad.error), /unknown field\(s\) survey/)
})

test('the extractor resolves a journal that holds several resumed attempts to ONE coherent chain', async () => {
  const run1 = await runWave({ args: ARGS, behave: fableDown, killAt: killInBuild })
  const run2 = await runWave({ args: ARGS, journal: run1.journal, behave: fableDown, killAt: killInBuild })
  const rows = run2.journal
  const strategistRows = rows.filter((r) => r.type === 'result' && r.result.survey)
  assert.equal(strategistRows.length, 2, 'the accumulation the task row reported: one strategist result per run')
  const lastStrategistRow = rows.lastIndexOf(strategistRows[1])
  const { carry, summary } = extractCarry(rows)
  assert.equal(carry.strategist, strategistRows[1].result)
  assert.ok(summary.join('\n').includes(`strategist: journal row ${lastStrategistRow + 1}`))
  assert.equal(carry.surveys.length, 6)
  // every carried survey comes from AFTER the chosen strategist
  for (const s of carry.surveys) assert.ok(rows.findIndex((r) => r.type === 'result' && r.result === s) > lastStrategistRow)
})

// ── real-shape arm: the model against a REAL recorded run ─────────────────
// Needs a recorded bp-epic-cycle run on this machine (the run record holds the
// script + args; the journal holds the keys). Absent on CI runners, so it
// skips there and says why; the synthetic arms above are the CI gate.
const REAL_RUN = process.env.EPIC_CYCLE_REAL_RUN || 'wf_f72fba43-a5e'
function findRealRun(runId) {
  const root = path.join(os.homedir(), '.claude', 'projects')
  if (!fs.existsSync(root)) return null
  for (const proj of fs.readdirSync(root)) {
    const pdir = path.join(root, proj)
    let sessions
    try { sessions = fs.readdirSync(pdir) } catch { continue }
    for (const sess of sessions) {
      const rec = path.join(pdir, sess, 'workflows', `${runId}.json`)
      const jrn = path.join(pdir, sess, 'subagents', 'workflows', runId, 'journal.jsonl')
      if (fs.existsSync(rec) && fs.existsSync(jrn)) return { rec, jrn }
    }
  }
  return null
}
const real = findRealRun(REAL_RUN)

test('REAL RUN: the key model re-derives a recorded run\'s journal keys', { skip: real ? false : `no recorded run ${REAL_RUN} on this machine` }, async () => {
  const rec = JSON.parse(fs.readFileSync(real.rec, 'utf8'))
  const rows = parseJournal(fs.readFileSync(real.jrn, 'utf8'))
  const resultKeys = rows.filter((r) => r.type === 'result').length
  const run = await runWave({ args: rec.args, journal: rows, behave: () => { throw new Error('a real-run replay must not dispatch') }, script: rec.script })
  const replayed = run.calls.filter((c) => c.replayed)
  // Every call but the LAST replays. The last is Review, whose prompt embeds
  // budget.spent() telemetry — the one non-deterministic prompt input, and it
  // sits on the final call, so it can never cost a replay.
  assert.equal(replayed.length, resultKeys - 1)
  assert.deepEqual(run.live.map((c) => c.label), ['review'])
})

test('REAL RUN: a carry built from the recorded journal takes the CURRENT workflow to Build with zero prefix dispatches', { skip: real ? false : `no recorded run ${REAL_RUN} on this machine` }, async () => {
  const rec = JSON.parse(fs.readFileSync(real.rec, 'utf8'))
  const rows = parseJournal(fs.readFileSync(real.jrn, 'utf8'))
  const { carry } = extractCarry(rows, { through: 'architect' })
  const compact = compactCarry(carry)
  const run = await runWave({ args: { ...rec.args, carry: compact }, behave: (label) => report(label.startsWith('build:') ? 'build:alpha' : label), killAt: killInBuild })
  assert.equal(prefixDispatches(run), 0)
  assert.equal(run.killed, true, 'reached Build')
  assert.ok(JSON.stringify(compact).length < 0.2 * JSON.stringify(extractCarry(rows).carry).length, 'compaction cut the carry below 20% of the full reports')
})
