export const meta = {
  name: 'bp-epic-cycle',
  description: 'Task-obsessed epic-team loop, every non-build phase on Fable: 5 Fable strategists (bold, first-cycle only) → 1 Fable architect decides, owns the charter AND files bp tasks for every slice → 1 Fable reviewer perfects the task setup → builders (opus) claim their bp task, build in worktrees, gate + commit → 1 Fable reviewer reviews everything (code + task ledger) and fixes obvious issues → 1 Fable direction agent. The USER WISH is the focus; the bp task ledger is the spine — every phase reads and writes it.',
  phases: [
    { title: 'Strategize', detail: '5 Fable strategists, holistic + bold (skipped once the charter exists)', model: 'fable' },
    { title: 'Decide', detail: '1 Fable architect: makes the important choices, writes/updates the epic charter, cuts this wave of slices, files + publishes a bp task per slice', model: 'fable' },
    { title: 'Task Review', detail: '1 Fable reviewer: audits the epic/wave task setup against the authoring rubric, FIXES defects directly via bp, go/no-go per slice', model: 'fable' },
    { title: 'Build', detail: 'up to 5 builders, worktree-isolated: CLAIM the bp task first, build, gate, honest self-review, commit, stamp evidence into the task' },
    { title: 'Review', detail: '1 Fable reviewer: reviews EVERY green slice (code) + the task ledger, fixes obvious issues in place, re-gates', model: 'fable' },
    { title: 'Direction', detail: 'honest wave assessment + charter wave-log update + task-ledger reconciliation report', model: 'fable' },
  ],
}

// args = { wish, charter_exists, charter_path?, epic_task_id?, strategist_model?, judge_model?, review_model?, lead_notes? }
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
// Every non-build phase runs on Fable by design (lead mandate 2026-07-09);
// builders stay opus. Overrides exist only as a fallback for Fable exhaustion.
const STRAT_MODEL = A.strategist_model || 'fable'
const JUDGE_MODEL = A.judge_model || 'fable'   // architect + direction
const REVIEW_MODEL = A.review_model || 'fable' // task review + wave review
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
  required: ['vision', 'key_choices', 'slices'],
  properties: {
    vision: { type: 'string', description: 'what the finished experience looks and feels like, concretely' },
    key_choices: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['choice', 'recommendation', 'why', 'risk'],
        properties: {
          choice: { type: 'string' }, recommendation: { type: 'string' },
          why: { type: 'string' }, risk: { type: 'string', enum: ['low', 'medium', 'high'] },
        },
      },
    },
    slices: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'what', 'files', 'gate', 'size'],
        properties: {
          title: { type: 'string' }, what: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          gate: { type: 'string' }, size: { type: 'string', enum: ['small', 'medium', 'large'] },
        },
      },
    },
  },
}

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['charter_written', 'epic_task_id', 'decisions_summary', 'wave'],
  properties: {
    charter_written: { type: 'boolean', description: `true only after you actually wrote/updated ${CHARTER_PATH}` },
    epic_task_id: { type: 'string', description: 'slug of the PUBLISHED epic parent task (created this wave or pre-existing)' },
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

const TASK_REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['tasks_perfect', 'fixes_applied', 'slices'],
  properties: {
    tasks_perfect: { type: 'boolean', description: 'true only if, AFTER your fixes, every wave task is published, well-formed, claimable, and correctly parented' },
    fixes_applied: { type: 'string', description: 'every bp mutation you made, or "none"' },
    slices: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'task_id', 'go', 'why'],
        properties: {
          title: { type: 'string' }, task_id: { type: 'string' },
          go: { type: 'boolean', description: 'false blocks this slice from building this wave' },
          why: { type: 'string' },
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
  required: ['reviewed', 'ledger_fixes', 'overall_verdict'],
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
    overall_verdict: { type: 'string' },
  },
}

const STRATEGIST_ANGLES = [
  { key: 'operator-journey', angle: 'the operator journey — every task an operator does in a week, where they get stuck, dead ends, missing feedback loops' },
  { key: 'information-architecture', angle: 'information architecture — what should be visible where; overview vs drill-down; density, hierarchy, live state; what Kinsta/Vercel get right structurally' },
  { key: 'drive-surface', angle: 'the DRIVE surface — every provider capability bp already has (compute/net/dns/storage/backups) and how each surface exposes it safely (confirmation, progress, failure states)' },
  { key: 'design-system', angle: 'visual design system — tokens, components, states (loading/empty/error/hover/focus), theming, what "Barkpark\'s own design language, lifted" concretely means' },
  { key: 'platform-parity', angle: 'platform parity — feature-by-feature honest comparison against Kinsta and Vercel dashboards; what is table stakes we lack, what we can uniquely do better' },
]

let strategies = []
if (!CHARTER_EXISTS) {
  phase('Strategize')
  log('First wave: 5 Fable strategists thinking boldly about the epic')
  strategies = (await parallel(
    STRATEGIST_ANGLES.map((s) => () =>
      agent(
        `You are a principal product engineer strategizing a Barkpark epic. Think BOLDLY — this is the phase where risk is welcome and the important choices get made; implementation rigor comes later.

${USER_WISH_BLOCK}

Your vantage: ${s.angle}.

Ground yourself in the real repo first: the Cloud control-plane SPA lives in cloud/priv/static/ (app.js, app.css, index.html; node:vm harness __app.test.mjs), the CLI cloud tree in internal/cli/, the control-plane Elixir routes/events beside them. Read what exists — then design what SHOULD exist. Read .claude/workflows/bp-loop-ledger.md for settled ground.

Return: a concrete vision (what the finished experience looks/feels like), the KEY CHOICES you'd make (with honest risk ratings — medium/high risk is acceptable when the payoff is structural), and 4-8 build slices sized small/medium/large that realize your vision. Slices may be ambitious; each still needs a local gate.
${GATES_BLOCK}${LEAD_NOTES}`,
        { label: `strategy:${s.key}`, phase: 'Strategize', schema: STRATEGY_SCHEMA, model: STRAT_MODEL }
      )
    )
  )).filter(Boolean)
  log(`${strategies.length}/5 strategists reported`)
}

phase('Decide')
const EPIC_TASK_LINE = EPIC_TASK_ID
  ? `The epic parent task is ${EPIC_TASK_ID} — verify it exists and is published; file this wave's slice tasks as its children (parent_id=${EPIC_TASK_ID}).`
  : `Ensure ONE published epic parent task exists for this epic (create it if missing — slug it from the charter name); file this wave's slice tasks as its children via parent_id.`
const architect = await agent(
  CHARTER_EXISTS
    ? `You are the ARCHITECT of a running Barkpark epic. The epic charter exists at ${CHARTER_PATH} — read it fully, then read the repo state it references (and .claude/workflows/bp-loop-ledger.md) to see what has actually landed since it was written. Read the epic's bp task tree too (bp task get <epic-task-id> carries children) — the ledger is the spine; reconcile it with reality before planning.

${USER_WISH_BLOCK}

Your job this wave:
1. Reconcile the charter AND the task ledger with reality (mark landed slices done in the charter; fold in anything the team shipped outside the loop).
2. Cut THIS WAVE: up to 5 build slices from the charter's plan — the highest-value next steps toward the wish. Weight FINISHING what exists (quality, coherence, the Kinsta/Vercel bar) alongside net-new capability; prefer finishing journeys over starting new ones.
3. FILE THE TASKS: ${EPIC_TASK_LINE} Every slice gets a published bp task with rubric-quality acceptance criteria (include a merge-gated criterion the lead closes). A slice without a published task does not exist — wave[].task_id is required.
4. UPDATE the charter file (Write/Edit) — wave plan, done-list, any decision changes — and set charter_written=true only after you actually wrote it.
Each slice needs instructions complete enough to build without more context, exact gate command(s), and must name the charter decisions it must respect.
${TASKS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`
    : `You are the ARCHITECT founding a Barkpark epic. 5 strategists just reported from different vantages:

${JSON.stringify(strategies, null, 2)}

${USER_WISH_BLOCK}

Your job — this is where the IMPORTANT CHOICES get made, and early risk is acceptable when it buys structural payoff:
1. Synthesize the strategies into ONE coherent epic: the vision, the key decisions (decide them — don't list options), the full slice roadmap in integration order. Verify load-bearing claims against the actual tree before deciding (grep, don't trust).
2. WRITE the epic charter to ${CHARTER_PATH} (use your Write tool): ## Vision, ## Decisions (each with a one-line why), ## Roadmap (all slices, ordered, sized), ## Wave log (empty). This file is the epic's memory — every future wave reads it. Set charter_written=true only after you actually wrote it.
3. FILE THE TASKS: ${EPIC_TASK_LINE} Every wave-1 slice gets a published bp task with rubric-quality acceptance criteria (include a merge-gated criterion the lead closes). A slice without a published task does not exist — wave[].task_id is required.
4. Cut WAVE 1: up to 5 slices, buildable in parallel by isolated builders (minimize file overlap between slices; if two slices must touch the same region of a file, merge or sequence them). Bold slices are fine; each needs instructions complete enough to build without more context and exact local gate command(s).
${TASKS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'architect', phase: 'Decide', schema: PLAN_SCHEMA, model: JUDGE_MODEL }
)

const wave = (architect.wave || []).slice(0, 5)
log(`Architect cut ${wave.length} slices; charter_written=${architect.charter_written}; epic task=${architect.epic_task_id}`)
if (wave.length === 0) {
  return { strategies: strategies.length, wave: 0, built: 0, note: 'architect cut no slices', decisions: architect.decisions_summary }
}

phase('Task Review')
const taskReview = await agent(
  `You are the TASK REVIEWER for a Barkpark epic wave — the ledger-obsessed gate between planning and building. The bp task ledger is the spine of this loop: if it is wrong, everything downstream is wrong.

${USER_WISH_BLOCK}

Epic parent task: ${architect.epic_task_id}
Charter: ${CHARTER_PATH} (read it)
THE WAVE AS PLANNED:
${JSON.stringify(wave.map((w) => ({ title: w.title, task_id: w.task_id, surface: w.surface, gate: w.gate, size: w.size })), null, 2)}

Your job — review everything, then FIX whatever is obviously wrong yourself (you have the bp CLI; mutate directly, don't file reports about fixable defects):
1. For the epic task and EVERY wave task: verify it exists, is PUBLISHED (not a stranded draft), is parented under the epic task, and reads to the authoring rubric — outcome-shaped title, description a cold builder could start from, concrete evidence-bearing acceptance criteria including one merge-gated criterion, sane priority.
2. Verify the ledger matches the charter: no slice missing a task, no orphaned/duplicate tasks for this wave (dedup drafts if the create flow stranded any), lifecycle states honest (nothing pre-claimed, nothing marked done that isn't).
3. FIX every defect you find via bp (patch fields, publish drafts, re-parent, rewrite weak criteria). Record every mutation in fixes_applied.
4. Per slice: go=true only if its task is now perfect AND the slice itself is buildable as instructed (gate is a real command, files don't collide with another slice). go=false blocks the slice this wave — say exactly why.
${TASKS_BLOCK}`,
  { label: 'task-review', phase: 'Task Review', schema: TASK_REVIEW_SCHEMA, model: REVIEW_MODEL }
)
const goByTitle = {}
for (const s of (taskReview.slices || [])) goByTitle[s.title] = s.go
const buildable = wave.filter((w) => goByTitle[w.title] !== false)
log(`Task review: tasks_perfect=${taskReview.tasks_perfect}; ${buildable.length}/${wave.length} slices go`)
if (buildable.length === 0) {
  return { strategies: strategies.length, decisions: architect.decisions_summary, wave: wave.length, built: 0, note: 'task reviewer blocked every slice', task_review: taskReview }
}

const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)

phase('Build')
const built = (await parallel(
  buildable.map((item, i) => () =>
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
      { label: `build:${slug(item.title)}`, phase: 'Build', schema: BUILD_SCHEMA, model: 'opus', isolation: 'worktree' }
    )
  )
)).filter(Boolean)

const greenBuilt = built.filter((r) => r.ok && r.gate_passed && r.branch)
log(`Build: ${greenBuilt.length}/${built.length} slices green`)

phase('Review')
let review = null
if (greenBuilt.length > 0) {
  const byTitleWave = {}
  for (const w of buildable) byTitleWave[w.title] = w
  review = await agent(
    `You are the REVIEWER for a just-built Barkpark epic wave — one Fable agent reviewing EVERYTHING: the code of every green slice AND the task ledger. You are in your OWN git worktree. This replaces a per-slice perfection pass: review at the Kinsta/Vercel bar, and FIX the obvious issues yourself instead of reporting them.

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first. Epic parent task: ${architect.epic_task_id}.

BUILT SLICES (review every one):
${JSON.stringify(greenBuilt.map((b) => ({ title: (built.find((x) => x === b) || {}).title, task_id: b.task_id, branch: b.branch, gate: b.gate_command, summary: b.summary, builder_review: b.review, files: b.files_changed })), null, 2)}

WAVE INSTRUCTIONS (what each slice was supposed to be):
${JSON.stringify(buildable.map((w) => ({ title: w.title, task_id: w.task_id, instructions: w.instructions, gate: w.gate })), null, 2)}

For EACH slice, in integration order:
1. \`git checkout -b <branch>-r <branch>\` in your worktree; study the full diff vs its merge-base with origin/main. Chase the builder's own doubts first.
2. Review adversarially for correctness (edge cases, escaping, stale-state, error paths) AND against the Kinsta/Vercel quality bar (honest loading/empty/error states, legibility, feedback, consistency with the charter's design decisions).
3. FIX obvious issues in place — bugs, missing states, sloppy copy, style drift. If it's already right, change nothing. Do NOT redesign the slice; structural concerns go in the verdict for the lead.
4. Re-run the slice's gate (must pass on your final state). Commit fixes as follow-up commit(s) on the -r branch.
5. Cross-slice pass: do the slices cohere (shared vocabulary, no duplicated helpers, no conflicting UI states)? Fix small incoherences on the owning slice's -r branch; flag big ones in overall_verdict.
6. LEDGER AUDIT: for every slice task, verify the builder claimed it, stamped honest evidence, and left lifecycle truthful (in_progress, not done — merge-gated criteria stay open for the lead). Verify tasks NOT built this wave weren't touched. Fix ledger lies/omissions directly via bp and record them in ledger_fixes.
7. Report per slice: final_branch = the -r branch if you changed anything, else the original; gate_passed on your final state; an honest verdict incl. anything the lead must know before merging.
${TASKS_BLOCK}`,
    { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA, model: REVIEW_MODEL, isolation: 'worktree' }
  )
}

const reviewedByBranch = {}
for (const r of (review && review.reviewed) || []) reviewedByBranch[r.task_id] = r
const green = greenBuilt.map((b) => {
  const r = reviewedByBranch[b.task_id]
  return { ...b, reviewed: r || null }
}).filter((b) => !b.reviewed || b.reviewed.gate_passed)

phase('Direction')
const direction = await agent(
  `You are the DIRECTION agent for a Barkpark epic loop — honest assessor, not implementer.

${USER_WISH_BLOCK}

Read ${CHARTER_PATH} and .claude/workflows/bp-loop-ledger.md, and the epic task tree (bp task get ${architect.epic_task_id}), then assess THIS wave:

ARCHITECT DECISIONS: ${architect.decisions_summary}
TASK REVIEW: tasks_perfect=${taskReview.tasks_perfect}; fixes: ${taskReview.fixes_applied}
WAVE (${wave.length} cut, ${buildable.length} go): ${wave.map((w) => `${w.title} [${w.size}]`).join(' | ')}
GREEN (${green.length}): ${green.map((r) => `${r.task_id}: ${r.summary}`).join(' || ') || '(none)'}
NOT GREEN: ${built.filter((r) => !greenBuilt.includes(r)).map((r) => `${r.task_id}: ${r.summary}`).join(' || ') || '(none)'}
REVIEWER: ${review ? `${review.overall_verdict} | ledger fixes: ${review.ledger_fixes}` : '(no green slices to review)'}

1. Assess honestly: did this wave move the WISH forward, or drift into micro-repair? Is the charter still the right plan? Is the task ledger an honest mirror of reality?
2. APPEND a '### Wave <date>' entry to the charter's ## Wave log (use Edit): what landed, what stalled, what the next wave should take.
3. Return concise markdown: ### ASSESSMENT, ### NEXT WAVE (what the architect should cut next and why), ### RISKS, ### LEDGER (task ids the lead must close on merge, with which criteria).`,
  { label: 'direction', phase: 'Direction', model: JUDGE_MODEL }
)

return {
  strategies: strategies.length,
  decisions: architect.decisions_summary,
  charter_written: architect.charter_written,
  epic_task_id: architect.epic_task_id,
  task_review: { tasks_perfect: taskReview.tasks_perfect, fixes: taskReview.fixes_applied },
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
  direction,
}
