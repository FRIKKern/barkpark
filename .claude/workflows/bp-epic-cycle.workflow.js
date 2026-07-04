export const meta = {
  name: 'bp-epic-cycle',
  description: 'Epic-team loop: 5 Fable strategists (bold, first-cycle only) → 1 Fable architect decides + owns the charter → up to 5 Fable builders in worktrees → 1 Fable perfecter per slice → 1 Fable direction agent. The USER WISH is the focus; risk is welcome while strategizing, rigor while perfecting.',
  phases: [
    { title: 'Strategize', detail: '5 Fable strategists, holistic + bold (skipped once the charter exists)', model: 'fable' },
    { title: 'Decide', detail: '1 Fable architect: makes the important choices, writes/updates the epic charter, cuts this wave of slices', model: 'fable' },
    { title: 'Build', detail: 'up to 5 Fable builders, worktree-isolated, gate + honest self-review + commit', model: 'fable' },
    { title: 'Perfect', detail: '1 Fable perfecter per green slice: review at the Kinsta/Vercel bar, polish in place, re-gate', model: 'fable' },
    { title: 'Direction', detail: 'honest wave assessment + charter wave-log update', model: 'fable' },
  ],
}

// args = { wish, charter_exists, charter_path?, strategist_model?, lead_notes? }
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
const STRAT_MODEL = A.strategist_model || 'opus'
const JUDGE_MODEL = A.judge_model || 'fable'  // fall back to opus on Fable exhaustion: judge_model:'opus'
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
  required: ['charter_written', 'decisions_summary', 'wave'],
  properties: {
    charter_written: { type: 'boolean', description: `true only after you actually wrote/updated ${CHARTER_PATH}` },
    decisions_summary: { type: 'string' },
    wave: {
      type: 'array',
      description: 'this wave of build slices, ≤5, integration-ordered',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'surface', 'files', 'instructions', 'gate', 'size'],
        properties: {
          title: { type: 'string' }, surface: { type: 'string' },
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
  required: ['ok', 'branch', 'summary', 'gate_command', 'gate_passed', 'review', 'files_changed'],
  properties: {
    ok: { type: 'boolean' },
    branch: { type: 'string' },
    summary: { type: 'string' },
    gate_command: { type: 'string' },
    gate_passed: { type: 'boolean' },
    review: { type: 'string', description: 'honest self-review: what could break, blind spots' },
    files_changed: { type: 'array', items: { type: 'string' } },
  },
}

const PERFECT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['final_branch', 'polished', 'changes', 'gate_passed', 'verdict'],
  properties: {
    final_branch: { type: 'string', description: 'branch the lead should integrate (the -p branch if you changed anything, else the original)' },
    polished: { type: 'boolean' },
    changes: { type: 'string' },
    gate_passed: { type: 'boolean' },
    verdict: { type: 'string', description: 'honest quality verdict vs the Kinsta/Vercel bar + anything the lead must know' },
  },
}

const STRATEGIST_ANGLES = [
  { key: 'operator-journey', angle: 'the operator journey — every task an operator does in a week, where they get stuck, dead ends, missing feedback loops' },
  { key: 'information-architecture', angle: 'information architecture — what should be visible where; overview vs drill-down; density, hierarchy, live state; what Kinsta/Vercel get right structurally' },
  { key: 'drive-surface', angle: 'the DRIVE surface — every Hetzner capability bp already has (compute/net/dns/storage/backups on hcloud-go/v2) and how the GUI exposes each safely (confirmation, progress, failure states)' },
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

Ground yourself in the real repo first: the Cloud control-plane SPA lives in cloud/priv/static/ (app.js ~3.3k lines, app.css, index.html; node:vm harness __app.test.mjs), the CLI cloud+hetzner tree in internal/cli/, the control-plane Elixir routes/events beside them. Read what exists — then design what SHOULD exist. Read .claude/workflows/bp-loop-ledger.md for settled ground.

Return: a concrete vision (what the finished experience looks/feels like), the KEY CHOICES you'd make (with honest risk ratings — medium/high risk is acceptable when the payoff is structural), and 4-8 build slices sized small/medium/large that realize your vision. Slices may be ambitious; each still needs a local gate.
${GATES_BLOCK}${LEAD_NOTES}`,
        { label: `strategy:${s.key}`, phase: 'Strategize', schema: STRATEGY_SCHEMA, model: STRAT_MODEL }
      )
    )
  )).filter(Boolean)
  log(`${strategies.length}/5 strategists reported`)
}

phase('Decide')
const architect = await agent(
  CHARTER_EXISTS
    ? `You are the ARCHITECT of a running Barkpark epic. The epic charter exists at ${CHARTER_PATH} — read it fully, then read the repo state it references (and .claude/workflows/bp-loop-ledger.md) to see what has actually landed since it was written.

${USER_WISH_BLOCK}

Your job this wave:
1. Reconcile the charter with reality (mark landed slices done; fold in anything the team shipped outside the loop).
2. Cut THIS WAVE: up to 5 build slices from the charter's plan — the highest-value next steps toward the wish. Now that the epic is underway, weight PERFECTING what exists (quality, coherence, the Kinsta/Vercel bar) alongside net-new capability; prefer finishing journeys over starting new ones.
3. UPDATE the charter file (Write/Edit) — wave plan, done-list, any decision changes — and set charter_written=true only after you actually wrote it.
Each slice needs instructions complete enough to build without more context, exact gate command(s), and must name the charter decisions it must respect.
${GATES_BLOCK}${LEAD_NOTES}`
    : `You are the ARCHITECT founding a Barkpark epic. 5 strategists just reported from different vantages:

${JSON.stringify(strategies, null, 2)}

${USER_WISH_BLOCK}

Your job — this is where the IMPORTANT CHOICES get made, and early risk is acceptable when it buys structural payoff:
1. Synthesize the strategies into ONE coherent epic: the vision, the key decisions (decide them — don't list options), the full slice roadmap in integration order. Verify load-bearing claims against the actual tree before deciding (grep, don't trust).
2. WRITE the epic charter to ${CHARTER_PATH} (use your Write tool): ## Vision, ## Decisions (each with a one-line why), ## Roadmap (all slices, ordered, sized), ## Wave log (empty). This file is the epic's memory — every future wave reads it. Set charter_written=true only after you actually wrote it.
3. Cut WAVE 1: up to 5 slices, buildable in parallel by isolated builders (minimize file overlap between slices; if two slices must touch the same region of app.js, merge or sequence them). Bold slices are fine; each needs instructions complete enough to build without more context and exact local gate command(s).
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'architect', phase: 'Decide', schema: PLAN_SCHEMA, model: JUDGE_MODEL }
)

const wave = (architect.wave || []).slice(0, 5)
log(`Architect cut ${wave.length} slices; charter_written=${architect.charter_written}`)
if (wave.length === 0) {
  return { strategies: strategies.length, wave: 0, built: 0, note: 'architect cut no slices', decisions: architect.decisions_summary }
}

const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)

const results = await pipeline(
  wave,
  // BUILD
  (item, orig, i) =>
    agent(
      `You are BUILDING one slice of a Barkpark epic inside your OWN isolated git worktree (safe to edit/commit; you will not collide with other builders).

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first — your slice must respect its decisions.

SLICE: ${item.title}
SURFACE: ${item.surface}
FILES: ${(item.files || []).join(', ')}
SIZE: ${item.size}
INSTRUCTIONS: ${item.instructions}
GATE (must pass before you commit): ${item.gate}

Steps:
1. Build it properly — this may be a real feature slice, not just a patch. Match surrounding code style. Quality bar: Kinsta/Vercel — honest states (loading/empty/error), safe actions, immediate feedback.
2. JS SDK public API change ⇒ add a js/.changeset/ entry (correctness gate, never skip).
3. Run the gate. Fix until it passes; if it truly cannot, STOP without committing and report ok:false with why.
4. Honest self-review: what could break, what you didn't cover, blind spots.
5. Only if the gate passes: branch 'loop-epic/${slug(item.title)}-${i}', one clear conventional commit. Do NOT push. Do NOT touch main.
Constraints: curl localhost only; never mix compile against prod; don't touch other worktrees' WIP.`,
      { label: `build:${slug(item.title)}`, phase: 'Build', schema: BUILD_SCHEMA, model: 'opus', isolation: 'worktree' }
    ),
  // PERFECT
  (built, item, i) => {
    if (!built || !(built.ok && built.gate_passed && built.branch)) return built
    return agent(
      `You are the PERFECTER for one just-built slice of a Barkpark epic. You are in your OWN git worktree. This is the phase where we spend time getting it RIGHT.

${USER_WISH_BLOCK}

SLICE: ${item.title}
BUILDER'S BRANCH: ${built.branch}
BUILDER'S SUMMARY: ${built.summary}
BUILDER'S OWN REVIEW (their doubts — chase these first): ${built.review}
GATE: ${built.gate_command || item.gate}

Steps:
1. \`git checkout -b ${built.branch}-p ${built.branch}\` in your worktree, study the full diff vs its merge-base with origin/main.
2. Review adversarially for correctness (edge cases, escaping, stale-state, error paths) AND against the Kinsta/Vercel quality bar (honest loading/empty/error states, legibility, feedback, consistency with the charter's design decisions — read ${CHARTER_PATH}).
3. POLISH IN PLACE: fix what you find, tighten what's rough. If it's already right, change nothing.
4. Re-run the gate (must pass on your final state). Commit polish as follow-up commit(s) on the -p branch.
5. Report final_branch = the -p branch if you changed anything, else the original branch; and an honest verdict incl. anything the lead must know before merging.`,
      { label: `perfect:${slug(item.title)}`, phase: 'Perfect', schema: PERFECT_SCHEMA, model: JUDGE_MODEL, isolation: 'worktree' }
    ).then((p) => ({ ...built, perfect: p }))
  }
)

const done = results.filter(Boolean)
const green = done.filter((r) => r.ok && r.gate_passed && r.branch && (!r.perfect || r.perfect.gate_passed))

phase('Direction')
const direction = await agent(
  `You are the DIRECTION agent for a Barkpark epic loop — honest assessor, not implementer.

${USER_WISH_BLOCK}

Read ${CHARTER_PATH} and .claude/workflows/bp-loop-ledger.md, then assess THIS wave:

ARCHITECT DECISIONS: ${architect.decisions_summary}
WAVE (${wave.length}): ${wave.map((w) => `${w.title} [${w.size}]`).join(' | ')}
GREEN (${green.length}): ${green.map((r) => `${r.title || r.branch}: ${r.summary}`).join(' || ') || '(none)'}
NOT GREEN: ${done.filter((r) => !green.includes(r)).map((r) => r.summary).join(' || ') || '(none)'}
PERFECTER VERDICTS: ${green.map((r) => r.perfect ? r.perfect.verdict : '(no perfect pass)').join(' || ')}

1. Assess honestly: did this wave move the WISH forward, or drift into micro-repair? Is the charter still the right plan?
2. APPEND a '### Wave <date>' entry to the charter's ## Wave log (use Edit): what landed, what stalled, what the next wave should take.
3. Return concise markdown: ### ASSESSMENT, ### NEXT WAVE (what the architect should cut next and why), ### RISKS.`,
  { label: 'direction', phase: 'Direction', model: JUDGE_MODEL }
)

return {
  strategies: strategies.length,
  decisions: architect.decisions_summary,
  charter_written: architect.charter_written,
  wave: wave.length,
  built: green.length,
  green_branches: green.map((r) => ({
    branch: r.perfect && r.perfect.final_branch ? r.perfect.final_branch : r.branch,
    summary: r.summary,
    files: r.files_changed,
    builder_review: r.review,
    perfecter_verdict: r.perfect ? r.perfect.verdict : null,
  })),
  not_green: done.filter((r) => !green.includes(r)).map((r) => ({ summary: r.summary, review: r.review })),
  direction,
}
