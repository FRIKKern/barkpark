#!/usr/bin/env node
// epic-cycle-carry.mjs — build args.carry for .claude/workflows/bp-epic-cycle.workflow.js
// from a run's journal, so a relaunch does not re-buy phases it already paid for.
//
// WHY A PLAIN RESUME IS NOT ENOUGH. The Workflow tool replays the longest
// unchanged prefix of agent() calls, and each call's key hashes the previous
// call's key. A dispatch that returned null (a Fable death that neverLose
// retried, a lost surveyor) leaves a `failed` row and no `result` row, and a
// resumed run latches LIVE at the first such call. Every call after it
// dispatches again, including ones whose results sit in the journal. The full
// mechanism is in the RESUME block of the workflow; the proof is
// scripts/epic-cycle-resume.test.mjs.
//
// WHAT THIS DOES. Reads journal.jsonl, picks each phase's result by its SHAPE
// (the schema's required fields) rather than by key, so it does not depend on
// the harness's undocumented key rule, and prints the carry object as JSON on
// stdout. A journal holding several attempts at the same wave (resumed runs
// append to it) resolves to ONE coherent chain:
//
//   strategist    the LAST strategist result
//   aim           the last digest result AFTER that strategist
//   surveys       per assignment key, the last survey result between the two
//   architect     the last decide result after that digest
//   verifications per assignment key, the last verify result between the two
//   built         per slice task_id, the last build result after that decide
//
// A phase with no result ends the carry there. Review is never carried; it is
// the last call and a resume that wants it has nothing left to replay.
//
// USAGE
//   node scripts/epic-cycle-carry.mjs <runId | path/to/journal.jsonl> [--through <phase>] [--full]
//     <phase> is one of strategist, surveys, aim, verifications, architect, built
//     --full  skip compaction (see COMPACTION below) and carry every report whole
//   A bare runId is looked up as ~/.claude/projects/*/*/subagents/workflows/<runId>/journal.jsonl.
//   Then relaunch the SAME args plus {"carry": <stdout>} as a FRESH run (no
//   resumeFromRunId: the keys cannot match anyway once the prefix is carried).
//
// EXIT CODES  0 carry printed · 1 no strategist result (nothing to carry) · 2 bad usage / unreadable journal

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const CARRY_ORDER = ['strategist', 'surveys', 'aim', 'verifications', 'architect', 'built']

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
const has = (r, keys) => isObj(r) && keys.every((k) => k in r)

// Shape predicates, keyed on each schema's required fields in the workflow —
// only fields every schema REVISION has carried: a 2026-08 journal predates
// strategist.candidates, and a predicate naming it read that real run as
// "no strategist result".
export const SHAPES = {
  strategist: (r) => has(r, ['direction', 'direction_debate', 'survey']),
  survey: (r) => has(r, ['key', 'findings', 'coverage', 'open_questions']) && !('proofs' in r),
  aim: (r) => has(r, ['synthesis', 'verification']),
  verify: (r) => has(r, ['key', 'findings', 'coverage', 'proofs']),
  architect: (r) => has(r, ['wave', 'charter_written', 'decisions_summary']),
  build: (r) => has(r, ['task_id', 'task_claimed', 'gate_passed', 'branch']),
}

export function parseJournal(text) {
  const rows = []
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    try { rows.push(JSON.parse(line)) } catch { /* the harness also skips unparseable lines */ }
  }
  return rows
}

// COMPACTION. The lead passes the carry INLINE as Workflow args, so every byte
// is a token the lead must emit; a full carry of a real 15-survey wave measured
// 833013 bytes (~208k tokens), more than one response can carry. A carried
// report only has to hold what the FIRST LIVE PHASE and everything after it
// read, and the workflow reads a lot less of an old report than it wrote:
//   surveys        digest live -> whole reports (Digest stringifies them all)
//                  decide live -> key, task_id, findings, facts (Decide's projection)
//                  later       -> key + facts[] reduced to rerun PRESENCE (only the demoted-fact count reads them)
//   verifications  decide live -> whole reports
//                  later       -> key + facts[] reduced to rerun presence + proofs as a same-length
//                                 placeholder list (only counts read them)
//   every report   journey dropped once its reader (Digest for surveys, Review
//                  never reads a carried journey) has already run
// Measured on that same run carried through Build: see the test.
export function compactCarry(carry) {
  const c = { ...carry }
  const live = CARRY_ORDER.find((k) => c[k] == null) || 'review'
  const after = (k) => CARRY_ORDER.indexOf(live) > CARRY_ORDER.indexOf(k) || live === 'review'
  // Only the PRESENCE of a rerun is read downstream (gateFactProvenance counts
  // demoted facts), so a carried fact keeps presence, not the command text.
  const factsOnly = (facts) => (facts || []).map((f) => ({ rerun: f && typeof f.rerun === 'string' && f.rerun.trim() ? 'carried' : '' }))
  const drop = (r, ...keys) => { const o = { ...r }; for (const k of keys) delete o[k]; return o }
  if (c.surveys && after('aim')) {
    c.surveys = after('architect')
      ? c.surveys.map((r) => ({ key: r.key, facts: factsOnly(r.facts) }))
      : c.surveys.map((r) => ({ key: r.key, task_id: r.task_id, findings: r.findings, facts: r.facts }))
  }
  if (c.verifications && after('architect')) {
    c.verifications = c.verifications.map((r) => ({ key: r.key, facts: factsOnly(r.facts), proofs: (r.proofs || []).map(() => 'carried: proof text is in the source journal') }))
  }
  if (c.strategist && after('surveys')) c.strategist = drop(c.strategist, 'journey')
  if (c.aim && after('verifications')) c.aim = drop(c.aim, 'journey')
  if (c.architect) c.architect = drop(c.architect, 'journey')
  if (c.built) c.built = c.built.map((r) => drop(r, 'journey', 'ledger_stamps'))
  return c
}

// rows: parsed journal rows in file order. Returns { carry, summary }.
export function extractCarry(rows, { through = 'built' } = {}) {
  const stop = CARRY_ORDER.indexOf(through)
  if (stop < 0) throw new Error(`--through must be one of ${CARRY_ORDER.join(', ')}`)
  const results = rows.map((r, i) => ({ i, row: r })).filter(({ row }) => row && row.type === 'result' && isObj(row.result)).map(({ i, row }) => ({ i, result: row.result }))
  const lastOf = (pred, after, before = Infinity) => {
    let hit = null
    for (const x of results) if (x.i > after && x.i < before && pred(x.result)) hit = x
    return hit
  }
  const perKey = (pred, field, wanted, after, before) => {
    const byKey = new Map()
    for (const x of results) if (x.i > after && x.i < before && pred(x.result) && wanted.has(x.result[field])) byKey.set(x.result[field], x.result)
    return [...wanted].filter((k) => byKey.has(k)).map((k) => byKey.get(k))
  }

  const carry = {}
  const summary = []
  const s = lastOf(SHAPES.strategist, -1)
  if (!s) return { carry: null, summary: ['no strategist result in the journal — nothing to carry'] }
  carry.strategist = s.result
  summary.push(`strategist: journal row ${s.i + 1}`)
  if (stop < 1) return { carry, summary }

  const a = lastOf(SHAPES.aim, s.i)
  const surveyKeys = new Set((s.result.survey || []).map((q) => q.key))
  carry.surveys = perKey(SHAPES.survey, 'key', surveyKeys, s.i, a ? a.i : Infinity)
  summary.push(`surveys: ${carry.surveys.length}/${surveyKeys.size} assignments carried${carry.surveys.length < surveyKeys.size ? ' (the rest dispatch live)' : ''}`)
  if (stop < 2 || !a) { if (!a && stop >= 2) summary.push('aim: no digest result after that strategist — carry ends at surveys'); return { carry, summary } }

  carry.aim = a.result
  summary.push(`aim: journal row ${a.i + 1}`)
  if (stop < 3) return { carry, summary }

  const p = lastOf(SHAPES.architect, a.i)
  const verifyKeys = new Set((a.result.verification || []).map((q) => q.key))
  carry.verifications = perKey(SHAPES.verify, 'key', verifyKeys, a.i, p ? p.i : Infinity)
  summary.push(`verifications: ${carry.verifications.length}/${verifyKeys.size} assignments carried${carry.verifications.length < verifyKeys.size ? ' (the rest dispatch live)' : ''}`)
  if (stop < 4 || !p) { if (!p && stop >= 4) summary.push('architect: no decide result after that digest — carry ends at verifications'); return { carry, summary } }

  carry.architect = p.result
  summary.push(`architect: journal row ${p.i + 1}`)
  if (stop < 5) return { carry, summary }

  const taskIds = new Set((p.result.wave || []).map((w) => w.task_id))
  carry.built = perKey(SHAPES.build, 'task_id', taskIds, p.i, Infinity)
  summary.push(`built: ${carry.built.length}/${taskIds.size} slices carried${carry.built.length < taskIds.size ? ' (the rest dispatch live)' : ''}`)
  return { carry, summary }
}

export function resolveJournal(arg) {
  if (fs.existsSync(arg) && fs.statSync(arg).isFile()) return arg
  if (fs.existsSync(arg) && fs.statSync(arg).isDirectory()) return path.join(arg, 'journal.jsonl')
  if (!/^wf_[A-Za-z0-9_-]+$/.test(arg)) return null
  const root = path.join(os.homedir(), '.claude', 'projects')
  if (!fs.existsSync(root)) return null
  for (const proj of fs.readdirSync(root)) {
    const pdir = path.join(root, proj)
    if (!fs.statSync(pdir).isDirectory()) continue
    for (const sess of fs.readdirSync(pdir)) {
      const j = path.join(pdir, sess, 'subagents', 'workflows', arg, 'journal.jsonl')
      if (fs.existsSync(j)) return j
    }
  }
  return null
}

function main(argv) {
  const args = argv.slice(2)
  let through = 'built'
  const full = args.includes('--full')
  if (full) args.splice(args.indexOf('--full'), 1)
  const t = args.indexOf('--through')
  if (t >= 0) { through = args[t + 1]; args.splice(t, 2) }
  if (args.length !== 1) {
    process.stderr.write('usage: node scripts/epic-cycle-carry.mjs <runId | journal.jsonl> [--through <phase>] [--full]\n')
    return 2
  }
  const j = resolveJournal(args[0])
  if (!j || !fs.existsSync(j)) {
    process.stderr.write(`epic-cycle-carry: no journal found for ${args[0]}\n`)
    return 2
  }
  let out
  try {
    out = extractCarry(parseJournal(fs.readFileSync(j, 'utf8')), { through })
  } catch (e) {
    process.stderr.write(`epic-cycle-carry: ${e.message}\n`)
    return 2
  }
  process.stderr.write(`epic-cycle-carry: ${j}\n  ${out.summary.join('\n  ')}\n`)
  if (!out.carry) return 1
  const body = JSON.stringify(full ? out.carry : compactCarry(out.carry))
  process.stderr.write(`  carry is ${body.length} bytes (~${Math.ceil(body.length / 4)} tokens to pass as args.carry)\n`)
  process.stdout.write(body + '\n')
  return 0
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv)
}
