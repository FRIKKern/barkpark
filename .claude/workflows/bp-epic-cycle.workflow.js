export const meta = {
  name: 'bp-epic-cycle',
  description: 'Task-obsessed epic-team loop: 1 Fable strategist sets direction + exploration questions → Opus explorers ground it in the repo → 1 Fable strategist decides, owns the charter AND files+perfects bp tasks for every slice → Opus builders claim their bp task, build in worktrees, gate + commit → 1 Fable reviewer reviews everything (code + task ledger), fixes obvious issues, and writes the wave log. The USER WISH is the focus; the bp task ledger is the spine — every phase reads and writes it.',
  phases: [
    { title: 'Strategize', detail: '1 Fable strategist: bold direction for this wave + the exploration questions that must be answered before deciding', model: 'fable' },
    { title: 'Explore', detail: 'up to 5 Opus explorers, read-only: answer the strategist\'s questions against the real repo — verify claims, map files, name seams and gates', model: 'opus' },
    { title: 'Decide', detail: '1 Fable strategist-architect: synthesizes strategy + exploration, writes/updates the epic charter, cuts this wave of slices, files + publishes + PERFECTS a bp task per slice', model: 'fable' },
    { title: 'Build', detail: 'up to 5 Opus builders, worktree-isolated: CLAIM the bp task first, build, gate, honest self-review, commit, stamp evidence into the task', model: 'opus' },
    { title: 'Review', detail: '1 Fable reviewer: reviews EVERY green slice (code) + the task ledger, fixes obvious issues in place, re-gates, appends the charter wave log', model: 'fable' },
  ],
}

// args = { wish, charter_exists, charter_path?, epic_task_id?, strategist_model?, explore_model?, review_model?, lead_notes? }
// GUARD (restored 2026-07-04 after a SECOND worktree revert wiped it — this bug
// built 2 waves against the wrong (cloud) charter): args can arrive as a JSON
// STRING; charter_path was hardcoded to cloud so every charter_exists wave read
// the cloud charter regardless of the intended epic. Parse defensively, refuse
// to run without an explicit wish, and HONOR charter_path.
const A = (() => {
  if (typeof args === 'string') { try { return JSON.parse(args) } catch (e) { throw new Error('epic-cycle args is a non-JSON string') } }
  return args || {}
})()
if (!A.wish) throw new Error('epic-cycle requires an explicit args.wish')
const WISH = A.wish
const CHARTER_PATH = A.charter_path || '.claude/workflows/bp-cloud-epic-charter.md'
const EPIC_TASK_ID = A.epic_task_id || null
// Phase↔model doctrine (lead mandate 2026-07-09): every THINKING phase is ONE
// Fable agent (strategize, decide, review); every FAN-OUT WORK phase is Opus
// (explore, build). Overrides exist only as a fallback for Fable exhaustion.
const STRAT_MODEL = A.strategist_model || 'fable'
const EXPLORE_MODEL = A.explore_model || 'opus'
const REVIEW_MODEL = A.review_model || 'fable'
const CHARTER_EXISTS = !!A.charter_exists
const LEAD_NOTES = A.lead_notes ? `\n\nLEAD NOTES THIS WAVE:\n${A.lead_notes}` : ''

const USER_WISH_BLOCK = `THE USER'S WISH (this is the focus — everything serves it, judged holistically, not as a checklist):
"""
${WISH}
"""`

const GATES_BLOCK = `Local gates available (a slice must name at least one that proves it):
- Cloud SPA: node --check cloud/priv/static/app.js AND node cloud/priv/static/__app.test.mjs (node:vm harness over __bpTestHook — extend it for new pure helpers)
- Go CLI: CC=clang go build ./... && go vet ./internal/cli/... && go test ./internal/cli/...
- Elixir control plane: targeted unit tests only (CC=clang mix test <file>), no DB/boot, never prod compile
- JS SDK: pnpm --filter <pkg> build/typecheck/test (+ js/.changeset/ entry for any public API change)`

const TASKS_BLOCK = `THE BP TASK CONTRACT (the ledger is the spine — every phase reads and writes it):
- Tasks are type:task documents in Barkpark, driven via the bp CLI. Try \`bp task create\` first; if this binary lacks the verb, the fallback is:
    bp doc create task --yes --set _id=<slug> --set title="..." --set kind=task --set lifecycle_status=open --set 'priority:=1' --set parent_id=<epic-task-slug> --set description="..." --set 'acceptance_criteria:=[{"criterion":"...","met":false,"evidence":""}]'
    bp doc publish task <slug> --yes        # tasks MUST be published — gates and boards read the published ledger only
- Fields are FLAT top-level in content. priority 0=highest..4. parent_id is a slug. Typed values use key:=json.
- Acceptance criteria to the authoring rubric: concrete, evidence-bearing, one per real proof obligation — {criterion, met, evidence}.
- Claim BEFORE working: \`bp task claim <task-id> <worker>\` — the claim epoch is at doc.claim.epoch in the JSON response.
- Stamp progress INTO the task as you work (close-time criteria flip): \`bp task close <task-id> <worker> <epoch> done "reason" --set 'criteria:=[{"index":N,"met":true,"evidence":"..."}]'\`.
  Builders do NOT close merge-gated criteria ("PR merged") — the LEAD closes those on merge. A builder whose work is done but unmerged leaves lifecycle in_progress with evidence stamped.
- Never TodoWrite, never markdown TODO lists. If a slice has no published, claimable bp task, that slice does not exist.`

const STRATEGY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['direction', 'exploration'],
  properties: {
    direction: { type: 'string', description: 'bold strategic direction for THIS wave: what the finished experience looks/feels like, the choices you are leaning toward, what matters most right now' },
    exploration: {
      type: 'array',
      description: '1-5 exploration assignments whose answers the Decide phase needs; each becomes one Opus explorer',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'question', 'why'],
        properties: {
          key: { type: 'string', description: 'short kebab-case label' },
          question: { type: 'string', description: 'a concrete, answerable question about the repo/product — name suspected files, claims to verify, seams to map' },
          why: { type: 'string', description: 'how the answer changes the plan' },
        },
      },
    },
  },
}

const EXPLORE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'facts', 'risks', 'relevant_files'],
  properties: {
    key: { type: 'string' },
    findings: { type: 'string', description: 'the answer to the question, honestly — including "the premise is wrong" when it is' },
    facts: {
      type: 'array',
      description: 'load-bearing facts, each with file:line evidence — verified by reading, not assumed',
      items: {
        type: 'object', additionalProperties: false,
        required: ['claim', 'evidence'],
        properties: { claim: { type: 'string' }, evidence: { type: 'string' } },
      },
    },
    risks: { type: 'array', items: { type: 'string' } },
    relevant_files: { type: 'array', items: { type: 'string' } },
  },
}

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['charter_written', 'epic_task_id', 'tasks_verified', 'decisions_summary', 'wave'],
  properties: {
    charter_written: { type: 'boolean', description: `true only after you actually wrote/updated ${CHARTER_PATH}` },
    epic_task_id: { type: 'string', description: 'slug of the PUBLISHED epic parent task (created this wave or pre-existing)' },
    tasks_verified: { type: 'boolean', description: 'true only after you re-read every wave task from the server and confirmed each is published, parented, and rubric-quality' },
    decisions_summary: { type: 'string' },
    wave: {
      type: 'array',
      description: 'this wave of build slices, ≤5, integration-ordered',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'task_id', 'surface', 'files', 'instructions', 'gate', 'size'],
        properties: {
          title: { type: 'string' },
          task_id: { type: 'string', description: 'slug of the PUBLISHED bp task for this slice — you created or verified it' },
          surface: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          instructions: { type: 'string', description: 'complete enough to build without more context; name the key choices it must respect' },
          gate: { type: 'string', description: 'exact shell command(s) that prove it' },
          size: { type: 'string', enum: ['small', 'medium', 'large'] },
        },
      },
    },
  },
}

const BUILD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ok', 'task_id', 'task_claimed', 'branch', 'summary', 'gate_command', 'gate_passed', 'review', 'files_changed'],
  properties: {
    ok: { type: 'boolean' },
    task_id: { type: 'string' },
    task_claimed: { type: 'boolean', description: 'true only if you actually claimed the bp task before building' },
    branch: { type: 'string' },
    summary: { type: 'string' },
    gate_command: { type: 'string' },
    gate_passed: { type: 'boolean' },
    review: { type: 'string', description: 'honest self-review: what could break, blind spots' },
    files_changed: { type: 'array', items: { type: 'string' } },
  },
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['reviewed', 'ledger_fixes', 'wave_log_appended', 'next_wave', 'overall_verdict'],
  properties: {
    reviewed: {
      type: 'array',
      description: 'one entry per built slice you reviewed',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'task_id', 'final_branch', 'fixes', 'gate_passed', 'verdict'],
        properties: {
          title: { type: 'string' },
          task_id: { type: 'string' },
          final_branch: { type: 'string', description: 'branch the lead should integrate (the -r branch if you fixed anything, else the original)' },
          fixes: { type: 'string', description: 'what you fixed in place, or "none"' },
          gate_passed: { type: 'boolean', description: 'the slice gate re-run green on the final branch' },
          verdict: { type: 'string', description: 'honest quality verdict vs the Kinsta/Vercel bar + anything the lead must know before merging' },
        },
      },
    },
    ledger_fixes: { type: 'string', description: 'bp task mutations you made to make the ledger match reality, or "none"' },
    wave_log_appended: { type: 'boolean', description: `true only after you actually appended the wave entry to ${CHARTER_PATH}` },
    next_wave: { type: 'string', description: 'what the next wave should take and why — the direction handoff' },
    overall_verdict: { type: 'string', description: 'did this wave move the WISH forward; cross-slice coherence; risks' },
  },
}

// ── Phase 1: Strategize — one Fable agent sets direction + exploration ──
phase('Strategize')
const strategist = await agent(
  `You are the STRATEGIST of a Barkpark epic wave — one Fable mind setting bold direction. Risk is welcome here; rigor comes later.

${USER_WISH_BLOCK}

${CHARTER_EXISTS
    ? `The epic charter exists at ${CHARTER_PATH} — read it fully, plus .claude/workflows/bp-loop-ledger.md, and the epic's bp task tree${EPIC_TASK_ID ? ` (bp task get ${EPIC_TASK_ID} carries children)` : ''}. Reconcile with what actually landed, then set the direction for THIS wave: what matters most now, what should be finished vs started, where the quality bar (Kinsta/Vercel) is not yet met.`
    : `This is the FOUNDING wave — no charter yet. Skim the repo's real surfaces (cloud/priv/static/, internal/cli/, the control-plane Elixir beside them; .claude/workflows/bp-loop-ledger.md for settled ground) just enough to strategize honestly — deep verification is the explorers' job, not yours.`}

Return:
1. direction — the bold strategic direction for this wave: what the finished experience looks/feels like, the key choices you lean toward (decide tentatively; the Decide phase finalizes after exploration), what to prioritize.
2. exploration — 1-5 concrete assignments for Opus explorers: the questions whose answers you NEED before the plan can be cut. Name suspected files, claims to verify, seams to map, prior art to find. Do not ask what you already know; do not skip what you merely assume.
${LEAD_NOTES}`,
  { label: 'strategist', phase: 'Strategize', schema: STRATEGY_SCHEMA, model: STRAT_MODEL }
)
const assignments = (strategist.exploration || []).slice(0, 5)
log(`Strategist set direction; ${assignments.length} exploration assignments`)

// ── Phase 2: Explore — Opus fan-out grounds the strategy in the repo ──
phase('Explore')
const explorations = assignments.length === 0 ? [] : (await parallel(
  assignments.map((q) => () =>
    agent(
      `You are an EXPLORER grounding a Barkpark epic wave in reality. READ-ONLY: no edits, no commits, no bp mutations. Your job is truth the strategist can plan on — verified by reading actual code, never assumed.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (context for what your answer feeds):
${strategist.direction}

YOUR ASSIGNMENT [${q.key}]: ${q.question}
WHY IT MATTERS: ${q.why}

Investigate the repo (grep/read; ${CHARTER_EXISTS ? `the charter at ${CHARTER_PATH} and ` : ''}.claude/workflows/bp-loop-ledger.md are fair sources). Answer honestly — "the premise is wrong" is a valid and valuable answer. Every load-bearing fact needs file:line evidence you actually read.`,
      { label: `explore:${q.key}`, phase: 'Explore', schema: EXPLORE_SCHEMA, model: EXPLORE_MODEL }
    )
  )
)).filter(Boolean)
log(`${explorations.length}/${assignments.length} explorers reported`)

// ── Phase 3: Decide — one Fable agent finalizes charter + wave + tasks ──
phase('Decide')
const EPIC_TASK_LINE = EPIC_TASK_ID
  ? `The epic parent task is ${EPIC_TASK_ID} — verify it exists and is published; file this wave's slice tasks as its children (parent_id=${EPIC_TASK_ID}).`
  : `Ensure ONE published epic parent task exists for this epic (create it if missing — slug it from the charter name); file this wave's slice tasks as its children via parent_id.`
const architect = await agent(
  `You are the STRATEGIST-ARCHITECT of a Barkpark epic — the same Fable judgment that set the direction now decides, with the explorers' ground truth in hand. This is where the IMPORTANT CHOICES get made.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (from the Strategize phase):
${strategist.direction}

EXPLORATION REPORTS (ground truth — trust their file:line evidence over your priors; spot-check anything load-bearing that smells off):
${JSON.stringify(explorations, null, 2)}

Your job:
1. DECIDE: finalize the key choices (decide them — don't list options). Where exploration contradicted the direction, follow the evidence.
2. ${CHARTER_EXISTS
      ? `UPDATE the charter at ${CHARTER_PATH} (Read then Edit): reconcile with what landed, fold in decision changes, set the wave plan.`
      : `WRITE the epic charter to ${CHARTER_PATH} (Write tool): ## Vision, ## Decisions (each with a one-line why), ## Roadmap (all slices, ordered, sized), ## Wave log (empty). This file is the epic's memory — every future wave reads it.`} Set charter_written=true only after you actually wrote it.
3. FILE THE TASKS: ${EPIC_TASK_LINE} Every slice gets a published bp task with rubric-quality acceptance criteria (include a merge-gated criterion the lead closes). A slice without a published task does not exist — wave[].task_id is required.
4. PERFECT THE TASKS (you are also the task reviewer — there is no one behind you): after filing, re-read every wave task back from the server and verify it is published (not a stranded draft), parented under the epic task, and reads to the rubric — outcome-shaped title, description a cold builder could start from, concrete evidence-bearing criteria, sane priority. Fix every defect via bp (patch, publish, re-parent, dedup stranded drafts). Set tasks_verified=true only after this read-back pass is clean.
5. Cut THE WAVE: up to 5 slices, buildable in parallel by isolated builders (minimize file overlap; if two slices must touch the same region of a file, merge or sequence them). ${CHARTER_EXISTS ? 'Weight FINISHING what exists (quality, coherence, the Kinsta/Vercel bar) alongside net-new capability; prefer finishing journeys over starting new ones.' : 'Bold slices are fine.'} Each needs instructions complete enough to build without more context and exact local gate command(s).
${TASKS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'architect', phase: 'Decide', schema: PLAN_SCHEMA, model: STRAT_MODEL }
)

if (!architect) throw new Error('Decide phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
const wave = (architect.wave || []).slice(0, 5)
log(`Architect cut ${wave.length} slices; charter_written=${architect.charter_written}; tasks_verified=${architect.tasks_verified}; epic task=${architect.epic_task_id}`)
if (wave.length === 0) {
  return { exploration: explorations.length, wave: 0, built: 0, note: 'architect cut no slices', decisions: architect.decisions_summary }
}

const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)

// ── Phase 4: Build — Opus builders, task-first ──
phase('Build')
const built = (await parallel(
  wave.map((item, i) => () =>
    agent(
      `You are BUILDING one slice of a Barkpark epic inside your OWN isolated git worktree (safe to edit/commit; you will not collide with other builders).

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first — your slice must respect its decisions.

SLICE: ${item.title}
BP TASK: ${item.task_id}
SURFACE: ${item.surface}
FILES: ${(item.files || []).join(', ')}
SIZE: ${item.size}
INSTRUCTIONS: ${item.instructions}
GATE (must pass before you commit): ${item.gate}

Steps — task first, code second:
1. CLAIM your task before touching code: bp task claim ${item.task_id} epic-builder-${slug(item.title)} — read the brief it carries; the task, not this prompt, is the contract of record. If the claim fails, STOP and report ok:false task_claimed:false with the error.
2. Build it properly — this may be a real feature slice, not just a patch. Match surrounding code style. Quality bar: Kinsta/Vercel — honest states (loading/empty/error), safe actions, immediate feedback.
3. JS SDK public API change ⇒ add a js/.changeset/ entry (correctness gate, never skip).
4. Run the gate. Fix until it passes; if it truly cannot, STOP without committing and report ok:false with why (leave the task claimed + in_progress with a note).
5. Honest self-review: what could break, what you didn't cover, blind spots.
6. Only if the gate passes: branch 'loop-epic/${slug(item.title)}-${i}', one clear conventional commit. Do NOT push. Do NOT touch main.
7. Stamp the evidence into your task: flip every criterion you actually proved (--set criteria:=[...] with concrete evidence: gate output, test names, branch). Do NOT close merge-gated criteria and do NOT set lifecycle done — the lead closes on merge. Leave the task in_progress with your branch named in the evidence.
${TASKS_BLOCK}
Constraints: curl localhost only; never mix compile against prod; don't touch other worktrees' WIP.`,
      { label: `build:${slug(item.title)}`, phase: 'Build', schema: BUILD_SCHEMA, model: EXPLORE_MODEL, isolation: 'worktree' }
    )
  )
)).filter(Boolean)

const greenBuilt = built.filter((r) => r.ok && r.gate_passed && r.branch)
log(`Build: ${greenBuilt.length}/${built.length} slices green`)

// ── Phase 5: Review — one Fable agent reviews everything, fixes, writes the wave log ──
phase('Review')
let review = null
if (greenBuilt.length > 0 || built.length > 0) {
  review = await agent(
    `You are the REVIEWER for a just-built Barkpark epic wave — one Fable agent reviewing EVERYTHING: the code of every green slice AND the task ledger. You are in your OWN git worktree. There is no perfection pass behind you: review at the Kinsta/Vercel bar and FIX the obvious issues yourself instead of reporting them.

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first. Epic parent task: ${architect.epic_task_id}.

BUILT SLICES (review every green one):
${JSON.stringify(greenBuilt.map((b) => ({ task_id: b.task_id, branch: b.branch, gate: b.gate_command, summary: b.summary, builder_review: b.review, files: b.files_changed })), null, 2)}

NOT-GREEN SLICES (audit their ledger state only — the task must honestly reflect the stall):
${JSON.stringify(built.filter((b) => !greenBuilt.includes(b)).map((b) => ({ task_id: b.task_id, ok: b.ok, summary: b.summary })), null, 2)}

WAVE INSTRUCTIONS (what each slice was supposed to be):
${JSON.stringify(wave.map((w) => ({ title: w.title, task_id: w.task_id, instructions: w.instructions, gate: w.gate })), null, 2)}

For EACH green slice, in integration order:
1. \`git checkout -b <branch>-r <branch>\` in your worktree; study the full diff vs its merge-base with origin/main. Chase the builder's own doubts first.
2. Review adversarially for correctness (edge cases, escaping, stale-state, error paths) AND against the Kinsta/Vercel quality bar (honest loading/empty/error states, legibility, feedback, consistency with the charter's design decisions).
3. FIX obvious issues in place — bugs, missing states, sloppy copy, style drift, unformatted code (run the surface's formatter: mix format / gofmt). If it's already right, change nothing. Do NOT redesign the slice; structural concerns go in the verdict for the lead.
4. Re-run the slice's gate (must pass on your final state). Commit fixes as follow-up commit(s) on the -r branch.
5. Cross-slice pass: do the slices cohere (shared vocabulary, no duplicated helpers, no conflicting UI states)? Fix small incoherences on the owning slice's -r branch; flag big ones in overall_verdict.

Then, once, for the wave:
6. LEDGER AUDIT: for every slice task, verify the builder claimed it, stamped honest evidence, and left lifecycle truthful (in_progress, not done — merge-gated criteria stay open for the lead). Not-green slices' tasks must say so. Verify tasks NOT in this wave weren't touched. Fix ledger lies/omissions directly via bp and record them in ledger_fixes.
7. WAVE LOG: APPEND a '### Wave <today>' entry to the charter's ## Wave log (Edit tool): what landed, what stalled, what the next wave should take. Set wave_log_appended=true only after you actually wrote it. Put the direction handoff in next_wave.
8. Report per slice: final_branch = the -r branch if you changed anything, else the original; gate_passed on your final state; an honest verdict incl. anything the lead must know before merging (the lead closes merge-gated criteria on merge — name them).
${TASKS_BLOCK}`,
    { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA, model: REVIEW_MODEL, isolation: 'worktree' }
  )
}

const reviewedByTask = {}
for (const r of (review && review.reviewed) || []) reviewedByTask[r.task_id] = r
const green = greenBuilt.map((b) => ({ ...b, reviewed: reviewedByTask[b.task_id] || null }))
  .filter((b) => !b.reviewed || b.reviewed.gate_passed)

return {
  direction: strategist.direction,
  exploration: explorations.length,
  decisions: architect.decisions_summary,
  charter_written: architect.charter_written,
  epic_task_id: architect.epic_task_id,
  tasks_verified: architect.tasks_verified,
  wave: wave.length,
  built: green.length,
  green_branches: green.map((r) => ({
    task_id: r.task_id,
    branch: r.reviewed && r.reviewed.final_branch ? r.reviewed.final_branch : r.branch,
    summary: r.summary,
    files: r.files_changed,
    builder_review: r.review,
    reviewer_fixes: r.reviewed ? r.reviewed.fixes : null,
    reviewer_verdict: r.reviewed ? r.reviewed.verdict : null,
  })),
  not_green: built.filter((r) => !greenBuilt.includes(r)).map((r) => ({ task_id: r.task_id, summary: r.summary, review: r.review })),
  ledger_fixes: review ? review.ledger_fixes : null,
  wave_log_appended: review ? review.wave_log_appended : false,
  next_wave: review ? review.next_wave : null,
  overall_verdict: review ? review.overall_verdict : null,
}
