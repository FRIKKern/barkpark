export const meta = {
  name: 'bp-epic-cycle',
  description: 'Task-obsessed 7-phase epic loop with a LIVING wave Paper: 1 Fable strategizes fast and OPENS the wave strategy Paper → 5-20 Sonnets survey wide (coverage-accounted: file, checked-for, found/not-found) → 1 Fable digests, folds the survey into the Paper, designs a targeted verify fleet → Sonnet/Opus verifiers PROVE claims (running tests where needed) → 1 Fable decides, updates Paper + charter AND files+perfects bp tasks → Fable/Opus builders (model per slice complexity) claim their bp task, build in worktrees, gate + commit → 1 Fable reviews everything (code + ledger), fixes issues in place, closes the Paper as the debrief, hands off. The USER WISH is the focus; the bp task ledger + wave Paper are the LIVE spine — every phase writes them the moment state changes. INVOKE: Workflow({name: "bp-epic-cycle", args: {wish: "<the user\'s request, verbatim>", charter_path: "<.claude/workflows/<epic>-charter.md — REQUIRED for any epic with a charter, the default is the cloud charter>", charter_exists: true|false, epic_task_id: "<task-… slug, when the epic task exists>"}}) — args.wish is REQUIRED and the run refuses to start without it (charter D68: a bare Workflow({name}) self-aborts).',
  phases: [
    { title: 'Strategize', detail: '1 Fable, ~5 min: bold direction + 5-20 broad survey questions, OPENS the wave strategy Paper — think hard, read little', model: 'fable' },
    { title: 'Survey', detail: '5-20 Sonnet surveyors, read-only, ~5 min each: wide cheap sweep — bp search first, then the repo; report COVERAGE (every file checked, what for, found/not-found)', model: 'sonnet' },
    { title: 'Digest', detail: '1 Fable, ~10 min: synthesize, fold the survey digest into the Paper, design the LAST explore round — per assignment pick Sonnet or Opus and what must be PROVEN by running tests; Paper states the verify plan BEFORE the fleet flies', model: 'fable' },
    { title: 'Verify', detail: 'Fable-chosen fleet of Sonnet/Opus verifiers: targeted deep answers with coverage accounting; claims that need proof get tests/gates actually RUN, output quoted' },
    { title: 'Decide', detail: '1 Fable, whatever time it needs: finalize choices, update Paper + charter, cut the wave (≤8 slices, builder model per slice), file + publish + PERFECT a bp task per slice (each linked to the Paper), seed the backlog', model: 'fable' },
    { title: 'Build', detail: 'Fable or Opus builders per slice complexity, worktree-isolated: CLAIM the bp task first, stamp evidence as each criterion is proven, gate, honest self-review, commit' },
    { title: 'Review', detail: '1 Fable, whatever time it needs: review every green slice + the ledger, FIX issues in place, re-gate, Cody-grade verdict, append wave log, CLOSE the wave Paper as the debrief, hand off', model: 'fable' },
  ],
}

// args = { wish, charter_exists, charter_path?, epic_task_id?, strategist_model?, survey_model?, review_model?, lead_notes? }
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
// Phase↔model doctrine (lead mandate 2026-07-10, rev 2): every THINKING phase
// is ONE Fable agent (strategize, digest, decide, review). The broad survey is
// Sonnet — cheap width. The verify fleet and the build fleet are MIXED: the
// digest/decide Fable picks Sonnet vs Opus per verification and Opus vs Fable
// per slice. Never Haiku anywhere. Overrides exist only for Fable exhaustion.
const STRAT_MODEL = A.strategist_model || 'fable'
const SURVEY_MODEL = A.survey_model || 'sonnet'
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

const PAPER_BLOCK = `THE WAVE PAPER (the wave's living story — one Barkpark Paper, opened at Strategize, closed at Review):
- style=article is MANDATORY (without it the render falls back to the ugly email look). bp doc create ignores stdin — write/extend the body via the HTTP /v1/data/mutate path (patch merges into content), then bp doc publish; \`bp capabilities -o json\` shows the verbs.
- Fable phases OWN the Paper; fan-out workers NEVER write it (20 concurrent patches clobber each other) — workers write their OWN bp task, and the next Fable folds their reports into the Paper.
- The Paper always states what is IN FLIGHT: Digest appends the survey digest + verify plan BEFORE the verifiers fly; Decide appends decisions + the wave plan BEFORE the builders fly; Review closes the story as the debrief. Someone opening the Paper mid-wave must see exactly where the wave stands.
- Link both ways: the Paper's id lives on the epic task (flat wave_paper field) and on every slice task; the Paper names the task ids it drives.`

const LIVENESS_BLOCK = `LEDGER LIVENESS (the board must read like a LIVE system, never an afterthought):
- Stamp state changes the MOMENT they happen — claim when you start, evidence the second a criterion is proven, a note the second you deviate or stall. Never batch honesty to the end of your run.
- The epic parent task carries a flat \`wave_status\` field — the heartbeat. Fable phases update it on entry and exit (e.g. "wave: digesting survey", "wave: building 6 slices", "wave: complete — debrief <paper-id>") via bp patch + publish (bp doc patch if this binary has it, else HTTP /v1/data/mutate — \`bp capabilities -o json\` shows what exists). Skip silently only if the epic task does not exist yet.
- Work discovered but NOT taken this wave gets filed NOW as a published child task (honest description, sane priority) — the visible backlog is part of the system being alive.
- Patches to tasks go through /v1/data/mutate semantics: fields FLAT, patch merges into content, re-publish after mutating (boards read the published ledger only).`

const STRATEGY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['direction', 'paper_id', 'paper_created', 'survey'],
  properties: {
    direction: { type: 'string', description: 'bold strategic direction for THIS wave: what the finished experience looks/feels like, the choices you are leaning toward, what matters most right now' },
    paper_id: { type: 'string', description: 'slug of the PUBLISHED wave strategy Paper you created (style=article)' },
    paper_created: { type: 'boolean', description: 'true only after you created AND published the Paper and read it back from the server' },
    survey: {
      type: 'array',
      description: '5-20 broad survey assignments; each becomes one Sonnet surveyor. Cast a WIDE net — cheap width now buys precise depth later',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'question', 'why'],
        properties: {
          key: { type: 'string', description: 'short kebab-case label' },
          question: { type: 'string', description: 'a concrete, answerable question about the repo/product/ledger — name suspected files, claims to check, seams to map' },
          why: { type: 'string', description: 'how the answer changes the plan' },
        },
      },
    },
  },
}

const COVERAGE_ITEMS = {
  type: 'object', additionalProperties: false,
  required: ['path', 'checked_for', 'result', 'note'],
  properties: {
    path: { type: 'string', description: 'file (or bp paper/task id) you actually opened or grepped' },
    checked_for: { type: 'string', description: 'what you were looking for in it' },
    result: { type: 'string', enum: ['found', 'not_found', 'partial'], description: 'found = it was there; not_found = you looked and it is NOT there (that is a finding!); partial = some of it / ran out of time' },
    note: { type: 'string', description: 'the one-line takeaway (what you found, or what its absence means); empty string if nothing beyond result' },
  },
}

const SURVEY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'coverage', 'facts', 'risks', 'open_questions'],
  properties: {
    key: { type: 'string' },
    findings: { type: 'string', description: 'the answer, honestly — including "the premise is wrong" when it is' },
    coverage: {
      type: 'array',
      description: 'EVERY file/paper/task you checked — path, what you checked it for, found/not_found/partial. Not-found is evidence too; unlisted = unchecked',
      items: COVERAGE_ITEMS,
    },
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
    open_questions: { type: 'array', items: { type: 'string' }, description: 'what you could NOT settle in the timebox — candidates for the verify round' },
  },
}

const AIM_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['synthesis', 'verification', 'paper_updated', 'heartbeat_stamped'],
  properties: {
    synthesis: { type: 'string', description: 'what the survey established, where reports contradict each other or the direction, and what remains unknown that the Decide phase cannot live without' },
    paper_updated: { type: 'boolean', description: 'true only after you appended the survey digest (incl. coverage map + not-founds) AND the verify plan to the wave Paper and re-published it' },
    verification: {
      type: 'array',
      description: 'the LAST explore round: 1-15 targeted assignments. YOU pick the fleet — model per assignment, and which claims must be PROVEN by actually running tests/gates rather than read',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'question', 'why', 'model', 'verify_commands', 'needs_worktree'],
        properties: {
          key: { type: 'string' },
          question: { type: 'string', description: 'sharp and targeted — this round closes unknowns, it does not browse' },
          why: { type: 'string' },
          model: { type: 'string', enum: ['sonnet', 'opus'], description: 'sonnet for mapping/breadth follow-ups; opus for subtle correctness, cross-surface reasoning, or judgment-heavy verification' },
          verify_commands: { type: 'string', description: 'shell command(s) the verifier must RUN to prove/refute the claim (tests, gates, curl against localhost) — empty string when reading suffices' },
          needs_worktree: { type: 'boolean', description: 'true only if verification requires a throwaway probe edit or an isolated build dir' },
        },
      },
    },
    heartbeat_stamped: { type: 'boolean', description: 'true only after you stamped wave_status on the epic task (or it does not exist yet)' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'coverage', 'facts', 'proofs', 'risks'],
  properties: {
    key: { type: 'string' },
    findings: { type: 'string', description: 'the answer, honestly — including "the premise is wrong" when it is' },
    coverage: {
      type: 'array',
      description: 'EVERY file/paper/task you checked — path, what you checked it for, found/not_found/partial. Not-found is evidence too; unlisted = unchecked',
      items: COVERAGE_ITEMS,
    },
    facts: {
      type: 'array',
      description: 'load-bearing facts, each with file:line evidence — verified by reading, not assumed',
      items: {
        type: 'object', additionalProperties: false,
        required: ['claim', 'evidence'],
        properties: { claim: { type: 'string' }, evidence: { type: 'string' } },
      },
    },
    proofs: {
      type: 'array',
      description: 'one entry per claim you PROVED or REFUTED by running something — quote real output, never paraphrase a pass',
      items: {
        type: 'object', additionalProperties: false,
        required: ['claim', 'command', 'output_excerpt', 'passed'],
        properties: {
          claim: { type: 'string' },
          command: { type: 'string' },
          output_excerpt: { type: 'string', description: 'the actual decisive lines of output' },
          passed: { type: 'boolean' },
        },
      },
    },
    risks: { type: 'array', items: { type: 'string' } },
  },
}

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['charter_written', 'paper_updated', 'epic_task_id', 'tasks_verified', 'backlog_filed', 'heartbeat_stamped', 'decisions_summary', 'wave'],
  properties: {
    charter_written: { type: 'boolean', description: `true only after you actually wrote/updated ${CHARTER_PATH}` },
    paper_updated: { type: 'boolean', description: 'true only after you appended verification results + decisions + the wave plan (with task ids) to the wave Paper and re-published it' },
    epic_task_id: { type: 'string', description: 'slug of the PUBLISHED epic parent task (created this wave or pre-existing)' },
    tasks_verified: { type: 'boolean', description: 'true only after you re-read every wave task from the server and confirmed each is published, parented, and rubric-quality' },
    backlog_filed: { type: 'string', description: 'discovered-but-deferred work you filed as published child tasks (ids), or "none"' },
    heartbeat_stamped: { type: 'boolean', description: 'true only after wave_status on the epic task says the wave is building' },
    decisions_summary: { type: 'string' },
    wave: {
      type: 'array',
      description: 'this wave of build slices, ≤8, integration-ordered',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'task_id', 'surface', 'files', 'instructions', 'gate', 'size', 'builder_model'],
        properties: {
          title: { type: 'string' },
          task_id: { type: 'string', description: 'slug of the PUBLISHED bp task for this slice — you created or verified it' },
          surface: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          instructions: { type: 'string', description: 'complete enough to build without more context; name the key choices it must respect' },
          gate: { type: 'string', description: 'exact shell command(s) that prove it' },
          size: { type: 'string', enum: ['small', 'medium', 'large'] },
          builder_model: { type: 'string', enum: ['opus', 'fable'], description: 'opus for well-specified slices; fable for the genuinely hard ones — subtle design, cross-surface coupling, high blast radius' },
        },
      },
    },
  },
}

const BUILD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ok', 'task_id', 'task_claimed', 'branch', 'summary', 'gate_command', 'gate_passed', 'review', 'files_changed', 'ledger_stamps'],
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
    ledger_stamps: { type: 'string', description: 'the task mutations you made DURING the build (claim, per-criterion evidence, deviation notes) — proof the ledger stayed live' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['reviewed', 'ledger_fixes', 'wave_log_appended', 'grade', 'commentary', 'paper_closed', 'heartbeat_stamped', 'next_wave', 'overall_verdict'],
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
    grade: { type: 'string', description: 'letter grade A+..F for the wave AS IT WILL MERGE (final branches), judged against the WISH' },
    commentary: { type: 'string', description: 'the Cody mandate: honest agent-judged commentary that EARNS the grade — what is genuinely strong, what falls short and why, never a bare number. Correctness, completeness vs the wish, bloat, aesthetics; tree-tidiness has no value.' },
    paper_closed: { type: 'string', description: 'the wave Paper id after you appended the final debrief section and re-published it, or "failed: <why>"' },
    heartbeat_stamped: { type: 'boolean', description: 'true only after wave_status on the epic task says the wave is complete and names the wave Paper' },
    next_wave: { type: 'string', description: 'what the next wave should take and why — the direction handoff' },
    overall_verdict: { type: 'string', description: 'did this wave move the WISH forward; cross-slice coherence; risks' },
  },
}

// ── Phase 1: Strategize — one Fable mind, ~5 minutes, direction + wide net ──
phase('Strategize')
const strategist = await agent(
  `You are the STRATEGIST of a Barkpark epic wave — one Fable mind setting bold direction FAST. Budget: ~5 minutes of thinking, minimal reading. Risk is welcome here; two whole exploration rounds of rigor come after you.

${USER_WISH_BLOCK}

${CHARTER_EXISTS
    ? `The epic charter exists at ${CHARTER_PATH} — read it, plus the epic's bp task tree${EPIC_TASK_ID ? ` (bp task get ${EPIC_TASK_ID} carries children)` : ''}. Reconcile with what actually landed, then set the direction for THIS wave: what matters most now, what should be finished vs started, where the quality bar (Kinsta/Vercel) is not yet met.`
    : `This is the FOUNDING wave — no charter yet. Skim just enough to strategize honestly (a \`bp search\` for prior papers/tasks on this topic, a fast look at the obvious surface dirs) — verification is the fleets' job, not yours.`}

Your job:
1. direction — the bold strategic direction for this wave: what the finished experience looks/feels like, the key choices you lean toward (tentatively; Decide finalizes after two explore rounds), what to prioritize.
2. survey — 5-20 BROAD assignments for cheap Sonnet surveyors. Cast a wide net: suspected files, prior art (in the repo AND in bp papers/tasks), claims to check, seams to map, adjacent systems that might constrain the design. Width is cheap here — ask everything you'd want a scout report on. The Digest phase distills; you do not need to be precise yet.
3. OPEN THE WAVE PAPER: create + publish the wave strategy Paper (slug like <epic>-wave-<YYYY-MM-DD>, style=article): the wish, your direction, the survey plan (every question + why). This Paper is the wave's living story — every later phase appends to it; someone opening it mid-wave sees exactly where the wave stands. Read it back before setting paper_created=true.
4. HEARTBEAT: ${EPIC_TASK_ID ? `stamp the epic task ${EPIC_TASK_ID}: flat wave_status ("wave: surveying — <one-line direction>") + flat wave_paper (the Paper's id), then re-publish.` : 'if a published epic parent task already exists for this epic, stamp its wave_status + wave_paper; if none exists yet, skip (Decide creates it).'}
${PAPER_BLOCK}
${LEAD_NOTES}`,
  { label: 'strategist', phase: 'Strategize', schema: STRATEGY_SCHEMA, model: STRAT_MODEL }
)
const surveyAssignments = (strategist.survey || []).slice(0, 20)
const WAVE_PAPER = strategist.paper_id
log(`Strategist set direction; wave paper ${WAVE_PAPER} (created=${strategist.paper_created}); ${surveyAssignments.length} survey assignments`)

// ── Phase 2: Survey — wide cheap Sonnet sweep, ~5 minutes each ──
phase('Survey')
const surveys = surveyAssignments.length === 0 ? [] : (await parallel(
  surveyAssignments.map((q) => () =>
    agent(
      `You are a SURVEYOR on a Barkpark epic wave — one of up to 20 scouts in a fast, wide sweep. READ-ONLY: no edits, no commits, no bp mutations. Budget: ~5 minutes — breadth over depth. A fast honest answer with real file:line anchors beats a deep dive; park what you can't settle in open_questions (a targeted verify round runs after you).

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (context for what your answer feeds):
${strategist.direction}

YOUR ASSIGNMENT [${q.key}]: ${q.question}
WHY IT MATTERS: ${q.why}

Search Barkpark FIRST (\`bp search "<terms>"\` — papers and tasks carry prior art the tree doesn't), then grep/read the repo${CHARTER_EXISTS ? `; the charter at ${CHARTER_PATH} is a fair source` : ''}. Answer honestly — "the premise is wrong" is a valid and valuable answer. Every load-bearing fact needs file:line evidence you actually read.

COVERAGE ACCOUNTING (your report is only trustworthy if its edges are visible): list EVERY file/paper/task you checked in coverage[] — the path, what you checked it for, and found / not_found / partial. NOT-FOUND IS A FINDING ("no existing rate limiter in api/" changes the plan as much as finding one). Anything you did not list is treated as unchecked — do not imply coverage you don't have. The wave Paper (${WAVE_PAPER}) will carry your coverage map; you do NOT write the Paper yourself.`,
      { label: `survey:${q.key}`, phase: 'Survey', schema: SURVEY_SCHEMA, model: SURVEY_MODEL }
    )
  )
)).filter(Boolean)
log(`${surveys.length}/${surveyAssignments.length} surveyors reported`)

// ── Phase 3: Digest — one Fable mind, ~10 minutes, designs the verify fleet ──
phase('Digest')
const aim = await agent(
  `You are the DIGEST strategist of a Barkpark epic wave — the same Fable judgment that set the direction, now holding ${surveys.length} survey reports. Budget: ~10 minutes. Your output designs the LAST exploration round before the plan is cut — after it, there is no more looking.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (yours, from Strategize):
${strategist.direction}

SURVEY REPORTS (wide but shallow — trust file:line evidence over prose; treat unanchored claims as rumors):
${JSON.stringify(surveys, null, 2)}

Your job:
1. SYNTHESIZE: what is now established, where reports contradict each other or the direction, which open_questions actually matter for the wish, and what the Decide phase cannot live without knowing.
2. DESIGN THE VERIFY FLEET (1-15 assignments) — you choose, per assignment:
   - model: 'sonnet' for mapping/breadth follow-ups; 'opus' for subtle correctness, cross-surface reasoning, judgment-heavy digs. Spend Opus where being wrong is expensive.
   - verify_commands: where a survey claim (or your own assumption) is load-bearing, the verifier must PROVE it by RUNNING something — the surface's tests/gates, a targeted mix/go test, curl against localhost. Reading is not proof for claims like "the gate passes", "this endpoint returns X", "these tests pin that behavior" (distrust vacuous green — a pass only counts if the RIGHT thing produced it). Empty string when reading genuinely suffices.
   - needs_worktree: true only for probe edits or isolated build dirs.
   Do not re-ask what the survey settled with evidence. This round closes unknowns; it does not browse.
3. UPDATE THE WAVE PAPER (${WAVE_PAPER}) — append, then re-publish, BEFORE your fleet flies:
   - Survey digest: the synthesis, plus a coverage map distilled from the surveyors' coverage[] — what was checked and found, and JUST AS PROMINENTLY what was checked and NOT found (absences are decisions-in-waiting). Name which corners of the repo no surveyor reached.
   - Verify plan: every assignment (question, model, what will be RUN as proof) — so the Paper states what is in flight while the verifiers work.
   Set paper_updated=true only after you re-published and read it back.
4. HEARTBEAT: ${EPIC_TASK_ID ? `stamp the epic task ${EPIC_TASK_ID}'s flat wave_status field ("wave: verifying — <one-line synthesis>") and re-publish.` : 'if a published epic parent task for this epic already exists, stamp its wave_status; if none exists yet, set heartbeat_stamped=true and move on (Decide creates it).'}
${PAPER_BLOCK}
${LIVENESS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'digest', phase: 'Digest', schema: AIM_SCHEMA, model: STRAT_MODEL }
)
if (!aim) throw new Error('Digest phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
const verifyAssignments = (aim.verification || []).slice(0, 15)
log(`Digest done; verify fleet: ${verifyAssignments.length} (${verifyAssignments.filter((v) => v.model === 'opus').length} opus, ${verifyAssignments.filter((v) => v.verify_commands).length} with live proofs)`)

// ── Phase 4: Verify — the Fable-designed fleet closes the unknowns ──
phase('Verify')
const verifications = verifyAssignments.length === 0 ? [] : (await parallel(
  verifyAssignments.map((q) => () =>
    agent(
      `You are a VERIFIER on a Barkpark epic wave — the LAST explorer before the plan is cut; nobody checks after you. No commits, no bp mutations, never touch main${q.needs_worktree ? ' (you are in your OWN throwaway worktree — probe edits are fine, but commit nothing)' : ' , no repo edits'}.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION:
${strategist.direction}

DIGEST SYNTHESIS (what is established and what you exist to close):
${aim.synthesis}

YOUR ASSIGNMENT [${q.key}]: ${q.question}
WHY IT MATTERS: ${q.why}
${q.verify_commands ? `MUST RUN (proof, not reading): ${q.verify_commands}
Run it (plus whatever else proves/refutes the claim), and QUOTE the decisive output lines in proofs[] — never paraphrase a pass. A failing command is a finding, not a failure of yours.` : 'Reading suffices for this assignment, but if you find a load-bearing claim that only a run can settle, run it and record the proof.'}

Investigate sharply — grep/read${CHARTER_EXISTS ? `, the charter at ${CHARTER_PATH},` : ''} bp search for prior art. "The premise is wrong" remains a valid answer. Every fact needs file:line evidence; every proof needs real output.

COVERAGE ACCOUNTING: list EVERY file/paper/task you checked in coverage[] — path, what you checked it for, found / not_found / partial. Not-found is a finding. Unlisted = unchecked. The wave Paper (${WAVE_PAPER}) will carry your coverage; you do NOT write the Paper yourself.`,
      { label: `verify:${q.key}`, phase: 'Verify', schema: VERIFY_SCHEMA, model: q.model === 'opus' ? 'opus' : 'sonnet', ...(q.needs_worktree ? { isolation: 'worktree' } : {}) }
    )
  )
)).filter(Boolean)
log(`${verifications.length}/${verifyAssignments.length} verifiers reported; ${verifications.reduce((n, v) => n + (v.proofs || []).length, 0)} live proofs`)

// ── Phase 5: Decide — one Fable mind finalizes charter + wave + tasks ──
phase('Decide')
const EPIC_TASK_LINE = EPIC_TASK_ID
  ? `The epic parent task is ${EPIC_TASK_ID} — verify it exists and is published; file this wave's slice tasks as its children (parent_id=${EPIC_TASK_ID}).`
  : `Ensure ONE published epic parent task exists for this epic (create it if missing — slug it from the charter name); file this wave's slice tasks as its children via parent_id.`
const architect = await agent(
  `You are the STRATEGIST-ARCHITECT of a Barkpark epic — the same Fable judgment that set direction and digested exploration, now DECIDING with two rounds of ground truth in hand. Take whatever time this needs; the IMPORTANT CHOICES get made here.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (from Strategize):
${strategist.direction}

DIGEST SYNTHESIS (from Digest):
${aim.synthesis}

VERIFICATION REPORTS (the deep round — proofs[] carry actually-run output; trust proofs > facts > prose; spot-check anything load-bearing that smells off):
${JSON.stringify(verifications, null, 2)}

SURVEY REPORTS (the wide round, already distilled by the synthesis — consult for detail, not direction):
${JSON.stringify(surveys.map((s) => ({ key: s.key, findings: s.findings, relevant_files: s.relevant_files })), null, 2)}

Your job:
1. DECIDE: finalize the key choices (decide them — don't list options). Where verification contradicted the direction, follow the evidence.
2. ${CHARTER_EXISTS
      ? `UPDATE the charter at ${CHARTER_PATH} (Read then Edit): reconcile with what landed, fold in decision changes, set the wave plan.`
      : `WRITE the epic charter to ${CHARTER_PATH} (Write tool): ## Vision, ## Decisions (each with a one-line why), ## Roadmap (all slices, ordered, sized), ## Wave log (empty). This file is the epic's memory — every future wave reads it.`} Then COMMIT it (one docs-only conventional commit, this file by explicit path only — never git add -A, other sessions share this checkout): builder worktrees branch from committed state, so an uncommitted charter is INVISIBLE to every builder (learned the hard way — a wave shipped wave-log entries citing decisions that existed only in a working copy). Set charter_written=true only after you wrote AND committed it.
3. FILE THE TASKS: ${EPIC_TASK_LINE} Every slice gets a published bp task with rubric-quality acceptance criteria (include a merge-gated criterion the lead closes) and the wave Paper's id on it (flat wave_paper field) so task → story is one hop. A slice without a published task does not exist — wave[].task_id is required.
4. SEED THE BACKLOG: everything exploration surfaced that is real but NOT this wave gets filed now as a published child task (honest description, sane priority) — record the ids in backlog_filed. The ledger must show the future, not just the present.
5. PERFECT THE TASKS (you are also the task reviewer — there is no one behind you): after filing, re-read every wave task back from the server and verify it is published (not a stranded draft), parented under the epic task, linked to the wave Paper, and reads to the rubric — outcome-shaped title, description a cold builder could start from, concrete evidence-bearing criteria, sane priority. Fix every defect via bp (patch, publish, re-parent, dedup stranded drafts). Set tasks_verified=true only after this read-back pass is clean.
6. CUT THE WAVE: up to 8 slices, buildable in parallel by isolated builders (minimize file overlap; if two slices must touch the same region of a file, merge or sequence them). Per slice pick builder_model: 'opus' for well-specified work; 'fable' for the genuinely hard slices — subtle design judgment, cross-surface coupling, high blast radius. ${CHARTER_EXISTS ? 'Weight FINISHING what exists (quality, coherence, the Kinsta/Vercel bar) alongside net-new capability; prefer finishing journeys over starting new ones.' : 'Bold slices are fine.'} Each needs instructions complete enough to build without more context and exact local gate command(s) — DRY-RUN each gate command yourself before filing it (a gate that cannot run, or references paths/globs that don't exist, forces the builder to interpret instead of prove).
7. UPDATE THE WAVE PAPER (${WAVE_PAPER}) — append, then re-publish, BEFORE the builders fly:
   - Verification results: per assignment what was proven/refuted (quote the decisive proof lines), plus the verifiers' coverage — including not-founds.
   - Decisions: each with its one-line why (mirror the charter, don't fork it — the charter is the epic's memory, the Paper is this wave's story).
   - Wave plan: every slice with its task id, surface, builder model, gate — so the Paper states what is in flight while the builders work.
   Set paper_updated=true only after you re-published and read it back.
8. HEARTBEAT: stamp the epic task's wave_status ("wave: building <n> slices — <one-line plan>") + wave_paper=${WAVE_PAPER} and re-publish. Set heartbeat_stamped=true only after you did.
${TASKS_BLOCK}
${PAPER_BLOCK}
${LIVENESS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'architect', phase: 'Decide', schema: PLAN_SCHEMA, model: STRAT_MODEL }
)

if (!architect) throw new Error('Decide phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
const wave = (architect.wave || []).slice(0, 8)
log(`Architect cut ${wave.length} slices (${wave.filter((w) => w.builder_model === 'fable').length} fable); charter_written=${architect.charter_written}; tasks_verified=${architect.tasks_verified}; epic task=${architect.epic_task_id}; backlog=${architect.backlog_filed}`)
if (wave.length === 0) {
  return { surveys: surveys.length, verifications: verifications.length, wave_paper: WAVE_PAPER, wave: 0, built: 0, note: 'architect cut no slices', decisions: architect.decisions_summary }
}

const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)

// ── Phase 6: Build — Fable/Opus builders per slice complexity, task-first ──
phase('Build')
const built = (await parallel(
  wave.map((item, i) => () =>
    agent(
      `You are BUILDING one slice of a Barkpark epic inside your OWN isolated git worktree (safe to edit/commit; you will not collide with other builders).

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first — your slice must respect its decisions. The wave Paper (${WAVE_PAPER}) carries this wave's story — decisions, verification proofs, the other slices; read it for context, NEVER write it (your bp task is your voice).

SLICE: ${item.title}
BP TASK: ${item.task_id}
SURFACE: ${item.surface}
FILES: ${(item.files || []).join(', ')}
SIZE: ${item.size}
INSTRUCTIONS: ${item.instructions}
GATE (must pass before you commit): ${item.gate}

Steps — task first, code second, and the ledger stays LIVE throughout:
1. CLAIM your task before touching code: bp task claim ${item.task_id} epic-builder-${slug(item.title)} — read the brief it carries; the task, not this prompt, is the contract of record. If the claim fails, STOP and report ok:false task_claimed:false with the error.
2. Build it properly — this may be a real feature slice, not just a patch. Match surrounding code style. Quality bar: Kinsta/Vercel — honest states (loading/empty/error), safe actions, immediate feedback.
3. STAMP AS YOU GO: the moment a criterion is actually proven (gate output, test name, behavior observed), stamp its evidence into the task — do not batch to the end. If you deviate from the brief or hit a wall, stamp a note the moment it happens. Record everything you stamped in ledger_stamps.
4. JS SDK public API change ⇒ add a js/.changeset/ entry (correctness gate, never skip).
5. Run the gate. Fix until it passes; if it truly cannot, STOP without committing and report ok:false with why (leave the task claimed + in_progress with a stamped note explaining the stall).
6. Honest self-review: what could break, what you didn't cover, blind spots.
7. Only if the gate passes: branch 'loop-epic/${slug(item.title)}-${i}', one clear conventional commit. Do NOT push. Do NOT touch main.
8. Final ledger state: every criterion you proved carries concrete evidence (gate output, test names, branch); merge-gated criteria stay open and lifecycle stays in_progress — the LEAD closes on merge. Your branch is named in the evidence.
${TASKS_BLOCK}
${LIVENESS_BLOCK}
Constraints: curl localhost only; never mix compile against prod; don't touch other worktrees' WIP.`,
      { label: `build:${slug(item.title)}`, phase: 'Build', schema: BUILD_SCHEMA, model: item.builder_model === 'fable' ? 'fable' : 'opus', isolation: 'worktree' }
    )
  )
)).filter(Boolean)

const greenBuilt = built.filter((r) => r.ok && r.gate_passed && r.branch)
log(`Build: ${greenBuilt.length}/${built.length} slices green`)

// ── Phase 7: Review — one Fable mind reviews, fixes, grades, debriefs, hands off ──
phase('Review')
let review = null
if (built.length > 0) {
  review = await agent(
    `You are the REVIEWER for a just-built Barkpark epic wave — one Fable agent, the LAST hands before merge, taking whatever time this needs. You review EVERYTHING (code of every green slice + the task ledger), FIX issues yourself instead of reporting them, grade the wave honestly, write the Paper debrief, and hand off. You are in your OWN git worktree.

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
2. Review adversarially for correctness (edge cases, escaping, stale-state, error paths) AND against the Kinsta/Vercel quality bar (honest loading/empty/error states, legibility, feedback, consistency with the charter's design decisions). Distrust vacuous green — spot-check that the load-bearing tests actually pin the behavior claimed.
3. FIX issues in place — bugs, missing states, sloppy copy, style drift, unformatted code (run the surface's formatter: mix format / gofmt). If it's already right, change nothing. Do NOT redesign the slice; structural concerns go in the verdict for the lead.
4. Re-run the slice's gate (must pass on your final state). Commit fixes as follow-up commit(s) on the -r branch.
5. Cross-slice pass: do the slices cohere (shared vocabulary, no duplicated helpers, no conflicting UI states)? Fix small incoherences on the owning slice's -r branch; flag big ones in overall_verdict.

Then, once, for the wave:
6. LEDGER AUDIT: for every slice task, verify the builder claimed it, stamped honest evidence AS THEY WORKED (their ledger_stamps claim vs the task's actual state), and left lifecycle truthful (in_progress, not done — merge-gated criteria stay open for the lead). Not-green slices' tasks must say so. Verify tasks NOT in this wave weren't touched. Fix ledger lies/omissions directly via bp and record them in ledger_fixes.
7. GRADE (Cody mandate): a letter grade A+..F for the wave as it will merge, judged against the WISH — correctness, completeness, bloat, aesthetics; tree-tidiness has no value. The commentary must EARN the grade: name what is genuinely strong AND what falls short. Never a bare number. Do not manufacture criticism to look rigorous.
8. WAVE LOG: APPEND a '### Wave <today>' entry to the charter's ## Wave log (Edit tool): what landed, what stalled, what the next wave should take. Set wave_log_appended=true only after you actually wrote it.
9. CLOSE THE WAVE PAPER (${WAVE_PAPER}): append the final DEBRIEF section and re-publish — what shipped (per slice: task, final branch, verdict), what stalled and why, the grade + commentary, the ledger audit outcome, what the next wave should take. Read the Paper top to bottom first: it now tells the whole wave's story (direction → survey coverage → verification proofs → decisions → outcome) — fix any section a later phase invalidated (a decision reversed, a proof superseded) with a dated correction note rather than silent rewriting. Report the Paper id in paper_closed.
10. HEARTBEAT + HANDOFF: stamp the epic task's wave_status ("wave: complete — grade <g>, paper ${WAVE_PAPER}") and re-publish; set heartbeat_stamped accordingly. Put the direction handoff in next_wave; per slice report final_branch (the -r branch if you changed anything), gate_passed on your final state, and an honest verdict incl. anything the lead must know before merging (the lead closes merge-gated criteria on merge — name them).
${TASKS_BLOCK}
${PAPER_BLOCK}
${LIVENESS_BLOCK}`,
    { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA, model: REVIEW_MODEL, isolation: 'worktree' }
  )
}

const reviewedByTask = {}
for (const r of (review && review.reviewed) || []) reviewedByTask[r.task_id] = r
const green = greenBuilt.map((b) => ({ ...b, reviewed: reviewedByTask[b.task_id] || null }))
  .filter((b) => !b.reviewed || b.reviewed.gate_passed)

return {
  direction: strategist.direction,
  wave_paper: WAVE_PAPER,
  surveys: surveys.length,
  synthesis: aim.synthesis,
  verifications: verifications.length,
  proofs: verifications.reduce((n, v) => n + (v.proofs || []).length, 0),
  decisions: architect.decisions_summary,
  charter_written: architect.charter_written,
  epic_task_id: architect.epic_task_id,
  tasks_verified: architect.tasks_verified,
  backlog_filed: architect.backlog_filed,
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
  grade: review ? review.grade : null,
  commentary: review ? review.commentary : null,
  paper_closed: review ? review.paper_closed : null,
  next_wave: review ? review.next_wave : null,
  overall_verdict: review ? review.overall_verdict : null,
}
