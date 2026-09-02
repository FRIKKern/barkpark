export const meta = {
  name: 'bp-epic-cycle',
  description: 'One epic wave: strategize → survey → digest → verify → decide → build → review, with the bp task ledger + wave Paper as the live spine.',
  whenToUse:
    'Run one wave of a Barkpark epic. INVOKE: Workflow({scriptPath: ".claude/workflows/bp-epic-cycle.workflow.js", args: {wish: "<the user\'s request, verbatim — REQUIRED, the run refuses to start without it (charter D68)>", charter_path: "<.claude/workflows/<epic>-charter.md — REQUIRED for any epic with a charter; default is the cloud charter>", charter_exists: true|false, epic_task_id: "<task-… slug, when the epic task exists>"}}). Launch from the repo root or pass an absolute scriptPath (it resolves against the session cwd); never launch by name (the name registry is a session-start snapshot). TWO SETTINGS ONLY — fable@high for thinking-focused work and for visual design/interface; opus@medium for everything else. Effort derives from the model; no xhigh, no max, anywhere. Shape: 1 Fable strategizes + OPENS the wave Paper → 5-20 Opus surveyors sweep (coverage-accounted) → 1 Fable digests + designs the verify fleet → mostly-Opus verifiers PROVE claims with run output → 1 Fable decides + files/perfects bp tasks → Opus builders (Fable on hard or visually-designed slices) claim their task, build in worktrees, stamp evidence, gate, commit → 1 Fable reviews everything, fixes in place, grades, closes the Paper as the debrief.',
  phases: [
    { title: 'Strategize', detail: '1 Fable @ high — thinking-focused, the highest-leverage judgment in the wave: reads until reading stops changing its mind, weighs rival directions and commits to one, stress-tests it, sets 5-20 broad survey questions, OPENS the wave strategy Paper, searches prior wave Papers first (answered questions become drift-checks)', model: 'fable' },
    { title: 'Survey', detail: '5-20 Opus surveyors @ medium, read-only, ~5 min each: wide sweep — bp search first, then the repo; report COVERAGE (every file checked, what for, found/not-found)', model: 'opus' },
    { title: 'Digest', detail: '1 Fable @ high: synthesize, fold the survey digest into the Paper, design the LAST explore round — per assignment pick the verifier MODEL and what must be PROVEN by running tests; Paper states the verify plan BEFORE the fleet flies; folds a journey card per surveyor into the Paper', model: 'fable' },
    { title: 'Verify', detail: 'Fable-designed fleet, mostly Opus @ medium with Fable @ high only on judgment-heavy digs: targeted deep answers with coverage accounting; claims that need proof get tests/gates actually RUN, output quoted', model: 'opus' },
    { title: 'Decide', detail: '1 Fable @ high: finalize choices, update Paper + charter, cut the wave (≤8 slices, builder model per slice — that one choice sets both model and depth), file + publish + PERFECT a bp task per slice (each linked to the Paper), seed the backlog', model: 'fable' },
    { title: 'Build', detail: 'Opus @ medium by default; Fable @ high for hard OR visually-designed slices. Worktree-isolated: CLAIM the bp task first, stamp evidence as each criterion is proven, gate, honest self-review, commit. Round-1 slices only — round ≥2 slices are deferred to the lead (sequenced-rounds law)' },
    { title: 'Review', detail: '1 Fable, whatever time it needs: review every green slice + the ledger, FIX issues in place, re-gate, Cody-grade verdict, append wave log, CLOSE the wave Paper as the debrief, hand off; persists wave telemetry (tokens/clock/interrupts) + a per-phase efficiency retro in the Paper debrief', model: 'fable' },
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
// Fan-out FLOORS. The caps below (survey 20, verify 15, wave 8) are upper bounds
// only; nothing stopped a thinking phase from returning one assignment, or zero.
// The ratified anti-goal — a wave must never spend FEWER agents to look decisive
// — was prose, and prose does not run. These are THROWS, deliberately, not schema
// minItems: wild-bulk-cycle declares minItems, but whether the host validator
// enforces it is unproven and cannot be proven without running a wave. A throw
// has no such doubt. A survey fan-out below 5 is a bug in the plan, not a plan.
const SURVEY_FLOOR = 5
const VERIFY_FLOOR = 3
// Phase↔model doctrine (lead mandate 2026-07-25, rev 4).
//
// THERE ARE EXACTLY TWO SETTINGS IN THIS WORKFLOW:
//
//     fable @ high     ← thinking-focused work, and visual design / interface
//     opus  @ medium   ← everything else, which is most of it
//
// EFFORT IS NOT AN INDEPENDENT DIAL — it is a function of the model (see
// EFFORT_FOR below), so the two can never drift apart. Choosing depth and
// choosing a model are the same decision, made once.
//
// NO XHIGH, NO MAX, ANYWHERE. When work is hard enough to want more depth, the
// answer is a better MODEL at high, not the same model strained upward. Both
// top tiers are documented as prone to overthinking with diminishing returns,
// and overthinking has a specific shape here that is worse than slow: an
// overthinking wave-cut does not produce a BETTER cut, it produces a BIGGER
// one — more slices, more scope — and that lands on eight builders. A builder
// strained upward likewise elaborates past the brief, which is precisely the
// scope creep the build prompt spends a paragraph suppressing. Rev 3 ran
// builders at xhigh on the documented coding recommendation; rev 4 rejects it
// and routes the hard slices to Fable instead. Depth by model, never by strain.
//
// WHAT COUNTS AS FABLE WORK — two categories, nothing else:
//   1. THINKING-FOCUSED: the four single-agent joints (strategize, digest,
//      decide, review), where everything downstream rides on one judgment, and
//      any fan-out assignment that is genuinely judgment-heavy rather than
//      merely large.
//   2. VISUAL DESIGN AND INTERFACE: palette, layout, typography, CSS,
//      LiveView/SPA chrome — anything judged against the Kinsta/Vercel bar.
//      This is independent of size: a small fully-specified CSS slice is Fable.
//
// Everything else is Opus 5 at medium — surveying, mapping, well-specified
// building, breadth verification. Medium is deliberate and not a floor to sink
// below: 'low' explicitly consolidates tool calls, and fewer greps is exactly
// how a surveyor manufactures a FALSE not_found ("no existing rate limiter in
// api/" when there is one). Nothing downstream re-checks an absence — it goes
// straight into Decide and the wave rebuilds prior art.
//
// Sonnet is GONE (rev 3, kept): its tokenizer emits ~30% more tokens for the
// same text and it defaults to high effort, so its per-token price edge over
// Opus largely evaporates in practice. Never Haiku anywhere. Model overrides
// exist only for Fable exhaustion.
//
// CONSEQUENCE, stated plainly: builder_model now sets BOTH model and depth, so
// mis-classifying a hard slice as routine costs twice. The architect's two-axis
// rule at PLAN_SCHEMA.builder_model is doing more work than it used to.
const STRAT_MODEL = A.strategist_model || 'fable'
const SURVEY_MODEL = A.survey_model || 'opus'
const REVIEW_MODEL = A.review_model || 'fable'
// Decide's own knob, defaulting to STRAT_MODEL so behaviour is unchanged unless
// asked. It exists so a run that dies at Decide on Fable exhaustion can be
// RESUMED onto Opus without touching STRAT_MODEL — moving that constant would
// change the strategist's and digest's cache keys too, re-buying an entire
// survey round to fix a joint that runs once.
const ARCH_MODEL = A.architect_model || STRAT_MODEL
// FABLE OUTAGE SWITCH. When Fable is unreachable (spend limit, retention tier,
// refusal class), every fable-selecting site must dispatch Opus INSTEAD — not
// merely fall back to it. The distinction is load-bearing at the builder
// fan-out, which is deliberately NOT wrapped in neverLose: a fable-assigned
// slice dispatches once, returns null, and the slice is LOST with no retry. The
// joints only waste three attempts; the builders lose work outright.
// Identity by default, so passing nothing changes nothing.
const NO_FABLE = A.no_fable === true
const M = (m) => (NO_FABLE && m === 'fable' ? 'opus' : m)
// The single source of depth in this workflow. Every agent() call derives its
// effort from its model through this, so no call site can quietly acquire a
// different depth than its tier implies — and adding an xhigh anywhere means
// deliberately bypassing this function, which is exactly the friction intended.
const EFFORT_FOR = (model) => (model === 'fable' ? 'high' : 'medium')
// The joints are Fable, but NOT USING FABLE IS NEVER A REASON TO STOP. Every
// joint falls back to Opus 5 after repeated dispatch failures and the wave keeps
// going on it. Fable carries the tighter constraints of the two — it runs
// classifiers aimed at bio/most-cyber content it is explicitly not intended for,
// and it is unavailable to orgs below 30-day data retention — so the direction
// of this fallback is deliberate: Opus 5 is the documented refusal-fallback
// target, not a consolation prize. A wave finished by Opus 5 at every joint is
// a fine wave.
const JOINT_FALLBACK = 'opus'
const CHARTER_EXISTS = !!A.charter_exists
const LEAD_NOTES = A.lead_notes ? `\n\nLEAD NOTES THIS WAVE:\n${A.lead_notes}` : ''
const SPENT = { t0: budget.spent() }

const USER_WISH_BLOCK = `THE USER'S WISH (this is the focus — everything serves it, judged holistically, not as a checklist):
"""
${WISH}
"""`

const GATES_BLOCK = `Local gates available (a slice must name at least one that proves it):
- Cloud SPA: node --check cloud/priv/static/app.js AND node cloud/priv/static/__app.test.mjs (node:vm harness over __bpTestHook — extend it for new pure helpers)
- Go CLI: go build ./... && go vet ./internal/cli/... && go test ./internal/cli/...
- Elixir control plane: targeted unit tests only (mix test <file>), no DB/boot, never prod compile
- JS SDK: pnpm --filter <pkg> build/typecheck/test (+ js/.changeset/ entry for any public API change)
- CC=clang is HOST-CONDITIONAL, not part of the gate: prefix it only on hosts where \`cc\` is shadowed by a wrapper (some dev Macs alias cc to a Claude launcher, which breaks cgo); on a clean host the plain commands above are the gate.`

const TASKS_BLOCK = `THE BP TASK CONTRACT (the ledger is the spine — every phase reads and writes it):
- Tasks are type:task documents in Barkpark, driven via the bp CLI. Try \`bp task create\` first; if this binary lacks the verb, the fallback is:
    bp doc create task --yes --set _id=<slug> --set title="..." --set kind=task --set lifecycle_status=open --set 'priority:=1' --set parent_id=<epic-task-slug> --set description="..." --set 'tags:=[{"tag":"docs","strength":80,"rationale":"..."},{"tag":"search","strength":40,"rationale":"..."}]' --set 'acceptance_criteria:=[{"criterion":"...","met":false,"evidence":""}]'
    bp doc publish task <slug> --yes        # tasks MUST be published — gates and boards read the published ledger only. tags are weighted [{tag,strength 1–100,rationale}] with DISTINCT strengths (max = main tag); each tag MUST be a registered tag doc (bp doc ls tag) or publish 422s unknown_tag
- Fields are FLAT top-level in content. priority 0=highest..4. parent_id is a slug. Typed values use key:=json.
- Acceptance criteria to the authoring rubric: concrete, evidence-bearing, one per real proof obligation — {criterion, met, evidence}.
- A CRITERION NAMES THE CLAIM, NEVER THE CONTAINER. Word it "the claim <X> is recorded in a durable venue the merge carries, and the evidence NAMES WHICH" — and accept ANY such venue: the commit message body, a test \`@moduledoc\` or a header comment on a shipped file, the instrument's own printed output, a comment at the site it describes, the task's own stamped ledger evidence, or the PR body. Never write "the PR body says <X>". The mechanical reason: builders are told not to push and do not open pull requests, so at stamp time NO PR body exists and none can — and the later \`gh pr create\` always passes \`--body\`, never \`--fill\`, and \`--body\` overwrites autofill entirely, so a commit message NEVER becomes the PR body on this harness. A venue-presuming criterion is therefore unmeetable the moment the builder finishes. Equally: NEVER demand PROSE for what the merged artifact already proves — if a file list, a diff, or a test name settles it, ask for THAT instead of a sentence restating it. EXEMPT from this rule: the lead-owned merge-gated row described below ("PR merged"), which the lead closes on merge and may name the PR.
- DECIDE phases: author \`files:\` labels on each wave slice — the exact paths it will touch (one repo-relative path per label; trailing \`/\` = directory prefix; no globs). This feeds the dispatch frontier's file-truth collision check so slices with disjoint file sets dispatch in parallel. Grammar + semantics: docs/contracts/dispatch-areas.md.
- Claim BEFORE working: \`bp task claim <task-id> <worker>\` — the claim epoch is at doc.claim.epoch in the JSON response.
- Stamp each criterion the MOMENT it is proven (mid-claim, never batched): \`bp task stamp <task-id> <worker> <epoch> --criterion N --criterion-text "<the criterion's exact stored wording>" --met --evidence "…"\` — \`--met\` REQUIRES non-empty \`--evidence\` (a met flip without proof is rejected) AND \`--criterion-text\` (the row's wording, copied verbatim from acceptance_criteria[N].criterion). \`--criterion N\` is 0-BASED — the FIRST criterion is 0 — and the index alone is UNVERIFIABLE: an unguarded met-flip is REJECTED (409 criterion_text_required) rather than silently flipping a NEIGHBOURING criterion, and a text that does not match the row at N is REJECTED too (409 criteria_mismatch). \`--miss --note "…"\` records an honest attempt WITHOUT flipping the lock and needs no text. Close stays the SEAL, validating the full set: \`bp task close <task-id> <worker> <epoch> done "reason" --set 'criteria:=[{"index":N,"met":true,"evidence":"...","criterion":"<that row's exact wording>"}]'\` (the \`criterion\` key is REQUIRED on every met:true entry, same guard).
  Builders do NOT close merge-gated criteria ("PR merged") — the LEAD closes those on merge. A builder whose work is done but unmerged leaves lifecycle in_progress with evidence stamped.
- Never TodoWrite, never markdown TODO lists. If a slice has no published, claimable bp task, that slice does not exist.`

const PAPER_BLOCK = `THE WAVE PAPER (the wave's living story — one Barkpark Paper, opened at Strategize, closed at Review):
- style=article is MANDATORY (without it the render falls back to the ugly email look). bp doc create ignores stdin — write/extend the body via the HTTP /v1/data/mutate path (patch merges into content), then bp doc publish; \`bp capabilities -o json\` shows the verbs.
- THE BODY IS A TOP-LEVEL \`blocks\` ARRAY — nothing else renders. Set/extend \`blocks\` at the ROOT of the document's content: NEVER \`body.content\`, NEVER a root \`content\` node array. \`body: {blocks, html}\` is what the SERVER synthesises on publish — authoring INTO \`body\` yourself publishes 200 and renders EMPTY.
- THE INLINE TEXT LEAF IS KEYED \`value\`, NEVER \`text\`. The renderer reads \`Map.get(n, "value", "")\` and has NO \`"text"\` fallback (api/lib/barkpark/portable_doc/render/inline.ex), so a \`text\`-keyed leaf renders as the EMPTY STRING — and a paragraph left empty is DROPPED, so the prose disappears with no error anywhere. A real paragraph block therefore reads:
    {"type":"paragraph","content":[{"type":"text","value":"Six verifiers re-ran the console gates; two claims did not survive."}]}
  MIXED dialects are the nastiest shape on the board: the Paper still looks fine while a subset of its prose is silently gone.
- READ-BACK OBLIGATION — a guard that can LOSE. After EVERY publish or patch of the Paper, re-read it FROM THE SERVER and prove BOTH:
    (a) DERIVE the public host first — \`bp capabilities -o json\` and read \`.server.base_url\` from the JSON — then \`curl -s -o /dev/null -w '%{http_code}' <base_url>/papers/<slug>\` prints 200. Never hardcode a host: this engine runs against whatever server the local bp config points at, and a host baked into this file is wrong on every other machine. Trust FIELDS, never exit codes — \`bp whoami\` exits 0 even when the server is unreachable, so only the value read from the JSON counts as a derivation; AND
    (b) the SERVER-DERIVED body contains the Paper's own prose — pick a distinctive sentinel sentence you just wrote, fetch the paper (the doc TYPE is \`paper\`, not \`bulldoc\`: \`bp doc get paper <slug> -o json\` — \`bulldoc\` answers not_found and reads like a missing Paper — or curl the /papers/<slug> URL) and confirm the sentinel appears at least once AND the rendered body's stripped text length is > 0.
  A 200 with ZERO prose characters is precisely the defect this obligation exists to catch, so status alone proves NOTHING and a paragraph count proves nothing either. If either check fails the Paper is unreadable memory: fix the body, re-publish, re-read. Ending the phase over a failed read-back is a PHASE FAILURE, not a note — do not report the phase complete.
- Fable phases OWN the Paper; fan-out workers NEVER write it (20 concurrent patches clobber each other) — workers write their OWN bp task, and the next Fable folds their reports into the Paper.
- The Paper always states what is IN FLIGHT: Digest appends the survey digest + verify plan BEFORE the verifiers fly; Decide appends decisions + the wave plan BEFORE the builders fly; Review closes the story as the debrief. Someone opening the Paper mid-wave must see exactly where the wave stands.
- Link both ways: the Paper's id lives on the epic task (flat wave_paper field) and on every slice task; the Paper names the task ids it drives.
- THE WALL DIALECT (enforced at publish, not a style preference): the wave Paper carries tag \`epic-cycle-wave-paper\`, and that exact tag puts it behind the epic paper publish wall (api/lib/barkpark/content/papers/epic_quality.ex on origin/main). The enforced set: NEVER author an empty paragraph spacer ANYWHERE — hard failure :empty_paragraph_spacer, checked over the NESTED block tree, not just top level (this REPLACES the retired spacing doctrine for this cohort; the ruling is owned by open task cchi-w67-bl-the-epic-paper-floor-forbids-the-spacing-doctrine — teach the wall, never author spacers). Opening, within the first 8 meaningful blocks: an h1 (exactly one h1 in the WHOLE document), one \`ingress\` block, and one orientation block of byline|stats|toc|list|steps. No heading-level jumps (h2 followed by h4 fails). Ceilings: 80 top-level blocks, 16 top-level headings, 5000 primary words — closed expandables are EXCLUDED from the word count, so long evidence goes behind a collapsed expandable. Every table with rows carries a non-empty \`head\`. A refused publish answers 422 code=invalid_epic_paper_quality and details.failures names EVERY failed gate — fix each named failure and re-publish (the bp CLI renders details); a publish that keeps failing is a Paper defect, never a reason to drop the tag.
- BEAUTIFUL BY CONTRACT (epic-memory D2): compose with real components, never walls of paragraphs — eyebrow/byline/ingress open the Paper; stat-grid for headline numbers; journey CARDS per agent (cards block: mission → what they figured out → what it means); decisions as callout blocks; proofs as code blocks quoting REAL output; load-bearing facts as a table WITH their rerun commands; diagram (mermaid) where flow beats prose; divider between phase sections. Block-shape crib: .claude/skills/bp-epic-debrief/helpers/blocks.md.
- CURATE, DON'T DUMP: keep turning points, surprises, refuted premises, real output; drop boilerplate. The Paper is the ONLY durable carrier of the wave's story (no dossiers, no per-agent papers — D3): what you leave out is gone.`

const LIVENESS_BLOCK = `LEDGER LIVENESS (the board must read like a LIVE system, never an afterthought):
- Stamp state changes the MOMENT they happen — claim when you start, evidence the second a criterion is proven, a note the second you deviate or stall. Never batch honesty to the end of your run.
- The epic parent task carries a flat \`wave_status\` field — the heartbeat. Fable phases update it on entry and exit (e.g. "wave: digesting survey", "wave: building 6 slices", "wave: complete — debrief <paper-id>") via bp patch + publish (bp doc patch if this binary has it, else HTTP /v1/data/mutate — \`bp capabilities -o json\` shows what exists). Skip silently only if the epic task does not exist yet.
- Your CLAIMED task carries a claim-scoped now-line — pulse it so every board moves while you work: \`bp task pulse <task-id> <worker> --now "…" [--criterion N]\` (no epoch arg — one atomic write that refreshes the now-line AND renews your lease; it survives fences). Pulse right after you claim and at each phase boundary. This is DISTINCT from the epic-level \`wave_status\` heartbeat above: pulse = per-claim ("what THIS worker is doing right now"), wave_status = per-epic ("what phase the whole wave is in"). Never conflate them — pulse is a task write, wave_status is an epic-task patch.
- Work discovered but NOT taken this wave gets filed NOW as a published child task (honest description, sane priority) — the visible backlog is part of the system being alive.
- Patches to tasks go through /v1/data/mutate semantics: fields FLAT, patch merges into content, re-publish after mutating (boards read the published ledger only).`

const JOURNEY_BLOCK = `YOUR JOURNEY (required — the epic's human story is assembled from these, and the debrief agent reads it days later):
Return journey{}: mission (one line), 2-5 key_moments — each a turning point or surprise WITH the evidence that caused it; a step log is not a journey — outcome, and meaning (the so-what for this wave). Write it for a human reader who was not there. Padded moments are worse than fewer moments.`

const PREMISE_SMOKE_BLOCK = `PREMISE SMOKE (E1, graduated into this cycle 2026-07-23 — a cheap pre-build check that caught the phantom-citation class for ~2% of a full survey's cost; DISTINCT from your own facts[].rerun discipline). Your facts[].rerun attaches a re-derivation command to facts YOU emit; this governs the INHERITED premises you are about to RELY ON but did not author — a charter D-number the direction/charter CITES, a candidate a prior phase NAMED reachable, a code site the wish points a builder at. A rerun string passes by being non-empty; a premise passes only when you RUN the check. Three obligations, each a cheap L1/L2 git-show (34-54ms — cheaper than being wrong):
- CITATION EXISTS AND COVERS: git-show every cited charter D-number / prior decision on origin/main (\`git show origin/main:<path>\`) and read that it actually AUTHORIZES what it is cited for. Existence is not enough — the arm-D phantom-D32 miss was a REAL entry cited as authority it does not cover. A citation you did not git-show is unverified; one whose text you did not read for coverage is a phantom wearing a number.
- CANDIDATE IS REACHABLE: confirm every candidate capability is reachable through a REAL non-admin write path, and name the caller/route that proves it. A path only an admin can reach is not the reachability the slice claims (the codelists-refutation lesson).
- CODE SITE STILL EXISTS: confirm every named file:symbol you build on still exists on ORIGIN/MAIN (\`git show origin/main:<path>\`), never a worktree that may be ahead/behind/dirty.
A premise that fails smoke is a FINDING, not a foundation — drop it, or fix the citation, before it reaches a builder.`

const FLIP_RISK_BLOCK = `FLIP-RISK DUAL-REVIEW (E2, graduated into this cycle 2026-07-23 — a 2nd independent reviewer's DISAGREEMENT localized a real escape the single-review census missed; scoped to earn its cost ONLY at high-flip-risk points, never every slice):
- DECIDE names it: for each slice whose KEY judgment is flip-prone — reachability, security, tenancy (NOT routine slices) — say so both IN that slice's task brief and in the wave-plan prose, as a "HIGH-FLIP-RISK: <which judgment>" line. That line is the trigger the reviewer reads.
- REVIEW acts on it: for any slice flagged high-flip-risk, the single wave-reviewer performs a DISTINCT independent re-derivation of that judgment (not a re-read of the builder's reasoning), AND explicitly flags — in the slice verdict and in next_wave — that a genuinely INDEPENDENT second reviewer is warranted before merge.
HONEST LIMIT: this workflow spawns exactly ONE reviewer, so the actual dispatch of that second reviewer is a MANUAL LEAD STEP — the lead already reviews the full diff and merges by hand. Review's job here is to NAME when independence is owed, not to auto-spawn it.`

// The journey is the wave's human story at agent grain — the debrief agent's
// raw material (epic-memory design D1). REQUIRED of every agent: the debrief
// runs DAYS later, when this run's session files are gone; a journey that is
// not in a report (and thence a Paper) does not exist.
const JOURNEY_FIELD = {
  type: 'object', additionalProperties: false,
  required: ['mission', 'key_moments', 'outcome', 'meaning'],
  properties: {
    mission: { type: 'string', description: 'your assignment as you understood it, one line' },
    key_moments: {
      type: 'array',
      description: '2-5 turning points or surprises, written for a human reader following the epic later — never a step log ("read A, then B" is a log; "expected X in warmpool.go, found the opposite — that killed direction A" is a moment). Fewer honest moments beat padded ones.',
      items: {
        type: 'object', additionalProperties: false,
        required: ['moment', 'evidence'],
        properties: {
          moment: { type: 'string', description: 'what turned or surprised you, and what it changed' },
          evidence: { type: 'string', description: 'the file:line, command output, paper/task id, or observation that caused it' },
        },
      },
    },
    outcome: { type: 'string', description: 'where you landed, one or two lines' },
    meaning: { type: 'string', description: 'the so-what for THIS wave: how your outcome should change what happens next' },
  },
}

// Wall-clock telemetry (design D6). The script cannot call Date.now() (banned
// for resume-safety), so the Fable phases carry the clock: fleets are
// bracketed by Fable checkpoints, so phase boundaries are these stamps.
const FABLE_STAMPS = {
  started_at: { type: 'string', description: 'output of `date -u +%FT%TZ`, run as your FIRST command (wall-clock telemetry, epic-memory D6)' },
  ended_at: { type: 'string', description: 'output of `date -u +%FT%TZ`, run as your LAST command before returning' },
}

const STRATEGY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['direction', 'direction_debate', 'paper_id', 'paper_created', 'survey', 'journey', 'started_at', 'ended_at'],
  properties: {
    direction: { type: 'string', description: 'bold strategic direction for THIS wave: what the finished experience looks/feels like, the choices you are leaning toward, what matters most right now' },
    direction_debate: { type: 'string', description: 'the rival directions you seriously developed and argued against each other, why the winner won, and the sharpest attack on the winner you found (with how the wave absorbs it) — a direction that never faced a rival is usually the first idea, not the best one' },
    paper_id: { type: 'string', description: 'slug of the PUBLISHED wave strategy Paper you created (style=article)' },
    paper_created: { type: 'boolean', description: 'true only after you created AND published the Paper and read it back from the server' },
    journey: JOURNEY_FIELD,
    ...FABLE_STAMPS,
    survey: {
      type: 'array',
      description: '5-20 broad survey assignments; each becomes one Opus surveyor at medium effort. Cast a WIDE net — width now buys precise depth later',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'question', 'why'],
        properties: {
          key: { type: 'string', description: 'short kebab-case label' },
          question: { type: 'string', description: 'a concrete, answerable question about the repo/product/ledger — name suspected files, claims to check, seams to map' },
          why: { type: 'string', description: 'how the answer changes the plan' },
          mode: { type: 'string', enum: ['research', 'drift-check'], description: "drift-check = a prior wave Paper already answered this; the surveyor re-runs its stored rerun commands and reports drift instead of re-deriving (epic-memory D4). Default: research." },
          prior_paper: { type: 'string', description: 'REQUIRED when mode=drift-check: the paper id that answered it' },
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

// One fact carries its own derivation. `rerun` is the join key that proofs[]
// never had: proofs[] is a PARALLEL array of {claim, command, output_excerpt},
// and a proof.claim matches a fact.claim exactly 0.3% of the time — so a reader
// can see a fact, see a command, and not know which produced which. Putting the
// command ON the fact removes the guess. proofs[] stays as it is.
const FACT_ITEMS = {
  type: 'object', additionalProperties: false,
  required: ['claim', 'evidence'],
  properties: {
    claim: { type: 'string' },
    evidence: { type: 'string' },
    rerun: {
      type: 'string',
      description: 'OPTIONAL. The ONE literal shell command that re-derives this fact from scratch — e.g. `git show origin/main:path/to/file | sed -n 40,60p`, `curl -s localhost:4000/api/schemas`, `grep -rn "needle" dir/`. This command, not your prose, decides the authority level the fact may be quoted at downstream. Leave it EMPTY rather than guessing: an empty rerun is an honest belief, a wrong one is a level-skip — exactly the failure this field exists to prevent.',
    },
  },
}

// Evidence has LEVELS, and the higher ones are cheap — say which one you used.
const FACTS_DESCRIPTION = 'load-bearing facts you actually verified, never assumed. Evidence takes several forms, and the strongest are cheap: `git show origin/main:<path>` reads what is really on main (not your worktree, which may be ahead, behind, or dirty), and a curl against a running host reads what is really deployed — both are fast enough to be the default, not a luxury (measured here: `git show` 34-54ms; a localhost curl 96-172ms warm, ~925ms cold). A worktree file:line is a perfectly good form too, but it is a claim about YOUR checkout and nothing more — do not quote it as a claim about main or about prod. Whichever form you used, put the command that re-derives it in that fact\'s rerun field.'

const SURVEY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'coverage', 'facts', 'risks', 'open_questions', 'journey'],
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
      description: FACTS_DESCRIPTION,
      items: FACT_ITEMS,
    },
    risks: { type: 'array', items: { type: 'string' } },
    open_questions: { type: 'array', items: { type: 'string' }, description: 'what you could NOT settle in the timebox — candidates for the verify round' },
    journey: JOURNEY_FIELD,
  },
}

const AIM_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['synthesis', 'verification', 'paper_updated', 'heartbeat_stamped', 'journey', 'started_at', 'ended_at'],
  properties: {
    synthesis: { type: 'string', description: 'what the survey established, where reports contradict each other or the direction, and what remains unknown that the Decide phase cannot live without' },
    paper_updated: { type: 'boolean', description: 'true only after you appended the survey digest (incl. coverage map + not-founds) AND the verify plan to the wave Paper and re-published it' },
    journey: JOURNEY_FIELD,
    ...FABLE_STAMPS,
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
          model: { type: 'string', enum: ['opus', 'fable'], description: "'opus' (at medium) is the default and fits most verification — mapping, breadth follow-ups, running a gate and quoting its output. 'fable' (at high) ONLY for genuinely judgment-heavy digs: subtle correctness, cross-surface reasoning, a call where being wrong is expensive and the answer is a judgment rather than a lookup. Depth comes from the model, never from straining one upward — there is no xhigh tier in this workflow. Most fleets should be mostly opus" },
          verify_commands: { type: 'string', description: 'shell command(s) the verifier must RUN to prove/refute the claim (tests, gates, curl against localhost) — empty string when reading suffices' },
          needs_worktree: { type: 'boolean', description: 'true only if verification requires a throwaway probe edit or an isolated build dir. An assignment that will write ledger rows under tooling/grip/ledger/ must NOT set it — Decide commits from the shared checkout and never sees a throwaway worktree, so those rows would be stranded' },
        },
      },
    },
    heartbeat_stamped: { type: 'boolean', description: 'true only after you stamped wave_status on the epic task (or it does not exist yet)' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'coverage', 'facts', 'proofs', 'risks', 'journey'],
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
      description: FACTS_DESCRIPTION,
      items: FACT_ITEMS,
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
    journey: JOURNEY_FIELD,
  },
}

// STRUCTURAL SELF-CHECK — runs on every wave, before a single agent is spent.
//
// `node --check` proves only that this file PARSES. It was green on a state
// where a misplaced brace closed SURVEY_SCHEMA.properties early and silently
// moved fix_candidates outside the schema: a valid program, a wrong contract,
// and no gate anywhere could see it. The probes that caught it were throwaway,
// so the same brace could return tomorrow against a green gate.
//
// This is the cheap permanent version. It is a THROW at module scope for the
// same reason the fan-out floors are (D15): it is certain, it needs no runner,
// and it fires before the wave costs anything. A schema whose `required` names
// a key it does not define is a contract the host can never satisfy.
for (const [name, schema] of [['SURVEY_SCHEMA', SURVEY_SCHEMA], ['VERIFY_SCHEMA', VERIFY_SCHEMA], ['STRATEGY_SCHEMA', STRATEGY_SCHEMA]]) {
  for (const key of schema.required || []) {
    if (!Object.prototype.hasOwnProperty.call(schema.properties || {}, key)) {
      throw new Error(`${name} declares required key '${key}' but does not define it in properties — a brace or edit moved it out of the schema. Fix the schema; do not proceed.`)
    }
  }
}
// `rerun` is the whole point of the provenance seam: if an edit drops it, the
// carrier is gone and every downstream grip check silently has nothing to read.
for (const [name, schema] of [['SURVEY_SCHEMA', SURVEY_SCHEMA], ['VERIFY_SCHEMA', VERIFY_SCHEMA]]) {
  const props = schema.properties?.facts?.items?.properties || {}
  if (!props.rerun) throw new Error(`${name}.facts[].rerun is missing — the fact-level provenance carrier was dropped.`)
  if ((schema.properties.facts.items.required || []).includes('rerun')) {
    throw new Error(`${name}.facts[].rerun must stay OPTIONAL (charter D3: a missing command DEMOTES to L6, it never rejects).`)
  }
}

// ── The in-loop provenance gate (charter D20) ────────────────────────────────
// SCOPE, SAID HONESTLY: this gates THE WAVE'S FACT FLOW — the facts[] arrays the
// survey and verify fleets hand back to THIS workflow — and NOT every write in
// the repo. An agent that writes durably mid-turn stored its fact long before
// any report reaches this line; nothing here can reach back and touch that.
//
// DELIBERATELY DUMBER THAN THE GRAMMAR. The real level ladder lives in
// tooling/grip/ (level.mjs derives, record.mjs adjudicates) and can never run
// here: a workflow file is compiled as a CLASSIC SCRIPT inside a vm context with
// codeGeneration disabled, so import, require, eval and new Function are all
// closed doors by host design (charter D19 — settled, do not re-probe). So this
// half asks the ONE question a program can answer with no vocabulary at all: is
// `rerun` present and non-empty? If this check ever needs to AGREE with
// record.mjs on a judgment call, that is a design error, not a missing import.
//
// DEMOTE, NEVER DROP. A dropped fact is a silent loss — the same defect class as
// a silent promotion. Length in === length out, always. The demotion and its
// reason ride ON the fact so the next Fable SEES both.
// ── A DEAD AGENT MUST NEVER KILL A WAVE (lead mandate 2026-07-25) ──
//
// `agent()` resolves to null when a subagent is skipped or dies on a terminal
// API error after the harness's own retries. A refusal is one way that happens:
// both Opus and Fable run safety classifiers that can decline a request
// outright, and benign work adjacent to security or life-sciences trips them
// occasionally. We CANNOT see why a given agent came back null — the harness
// surfaces absence, not cause — so this does not try to diagnose. It just
// refuses to accept the first no.
//
// WHAT THIS IS NOT: the Messages-API `fallbacks` parameter (server-side refusal
// routing, `server-side-fallback-2026-07-01`) is not reachable from a workflow
// script — we do not construct those requests. This is the agent-level analogue
// and the only lever we actually have: re-dispatch, then re-dispatch on another
// model, then carry the gap forward as data.
//
// THE LADDER, and an honest caveat about its last rung:
//   1. same model again — most deaths are transient (overload, 429, a dropped
//      connection), and a fresh dispatch is cheap next to losing the wave.
//   2. same model again — a second transient in a row is uncommon but not rare
//      at 20-way fan-out.
//   3. the other model — this is a HEDGE, not a cure. If the death was
//      capability- or schema-shaped, a different model genuinely helps. If it
//      was a refusal, it may not: Fable's classifiers are at least as tight as
//      Opus 5's (it is explicitly not intended for bio/most-cyber work), so
//      escalating Opus→Fable on a refusal can fail the same way. We take the
//      swing anyway because we cannot tell the cases apart and the attempt is
//      cheaper than the gap.
//   4. proceed WITHOUT it. Never throw.
//
// Rung 4 is the whole point, and it is not "proceed silently" — that was the
// original defect. The gap becomes a FACT that rides into Digest, Decide, and
// the wave Paper, so the wave cuts a plan knowing exactly which questions went
// unanswered instead of quietly believing it has coverage it never got.
const RECOVERY_ATTEMPTS = ['same', 'same', 'other']
async function neverLose(dispatch, { label, model, other }) {
  let result = await dispatch(model)
  if (result) return result
  for (let i = 0; i < RECOVERY_ATTEMPTS.length; i++) {
    const useModel = RECOVERY_ATTEMPTS[i] === 'other' ? other : model
    log(`RECOVER ${label}: no report after attempt ${i + 1} — re-dispatching on ${useModel}`)
    result = await dispatch(useModel)
    if (result) {
      if (useModel !== model) result.recovered_on = useModel
      log(`RECOVER ${label}: recovered on attempt ${i + 2} (${useModel})`)
      return result
    }
  }
  log(`LOST ${label}: no report after ${RECOVERY_ATTEMPTS.length + 1} dispatches — the wave CONTINUES and carries this assignment forward as unanswered`)
  return null
}

// Renders the lost assignments as a block every downstream thinking phase must
// read. An empty deficit renders as an explicit all-clear rather than nothing,
// so a Fable reading this can tell "no gaps" apart from "nobody told me".
function deficitBlock(kind, lost) {
  if (!lost || lost.length === 0) return `\nCOVERAGE DEFICIT (${kind}): none — every dispatched agent reported.`
  return `\n⚠ COVERAGE DEFICIT (${kind}): ${lost.length} assignment(s) were dispatched and NEVER REPORTED, after four attempts each including a cross-model retry. These questions are UNANSWERED — not "answered thinly", not "found nothing". Treat each as an open unknown you are deciding around, say so explicitly in the Paper, and if one is load-bearing for the wish, either re-ask it in a round you control or narrow the wave so it does not depend on the answer:
${lost.map((q) => `  - [${q.key}] ${q.question}\n    WHY IT MATTERED: ${q.why}`).join('\n')}`
}

function gateFactProvenance(reports) {
  let total = 0
  let demoted = 0
  for (const report of reports || []) {
    const facts = (report && report.facts) || []
    for (const fact of facts) {
      if (!fact || typeof fact !== 'object') continue
      total++
      const rerun = typeof fact.rerun === 'string' ? fact.rerun.trim() : ''
      if (rerun) continue
      demoted++
      // Annotated on the RESOLVED object, never in the schema: FACT_ITEMS is
      // additionalProperties:false, and that constraint governs what the MODEL
      // may return — it says nothing about what we may add after the fact.
      fact.provenance = 'DEMOTED-NO-RERUN'
      fact.provenance_note = 'no rerun command on this fact — it cannot be re-derived, so treat it as an unverified belief and never quote it above the level of agent memory (charter D3: demote, never reject; add a one-line rerun command and it levels up in ten seconds).'
    }
  }
  return { total, demoted }
}

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['charter_written', 'charter_pr', 'wave_referent_task', 'paper_updated', 'epic_task_id', 'tasks_verified', 'backlog_filed', 'heartbeat_stamped', 'decisions_summary', 'doc_facts_routed', 'wave', 'journey', 'started_at', 'ended_at'],
  properties: {
    charter_written: { type: 'boolean', description: `true only after the docs-only PR carrying ${CHARTER_PATH} is OPEN and reporting its checks — a charter that never reached a PR is not published, and a direct push to main is REJECTED (GH006)` },
    charter_pr: { type: 'string', description: 'the docs-only charter PR — its number or URL (e.g. "#6123"); if no PR could be opened, the one-line reason instead, and charter_written stays false' },
    wave_referent_task: { type: 'string', description: 'the PER-WAVE referent task (`<epic-slug>-wave-<N>-log`, parented under the epic) that you filed, CLAIMED, and pulsed BEFORE opening the charter PR, and whose id is on that PR\'s `Task:` line. The gate freezes its verdict at PR-open time (`claim.expired_at >= pull_request.created_at`), so a referent claimed after the fact is worth nothing. Never the epic Goal — that misrepresents a multi-wave Goal\'s lifecycle. If no PR was opened, the one-line reason instead' },
    paper_updated: { type: 'boolean', description: 'true only after you appended verification results + decisions + the wave plan (with task ids) to the wave Paper and re-published it' },
    epic_task_id: { type: 'string', description: 'slug of the PUBLISHED epic parent task (created this wave or pre-existing)' },
    tasks_verified: { type: 'boolean', description: 'true only after you re-read every wave task from the server and confirmed each is published, parented, and rubric-quality' },
    backlog_filed: { type: 'string', description: 'discovered-but-deferred work you filed as published child tasks (ids), or "none"' },
    heartbeat_stamped: { type: 'boolean', description: 'true only after wave_status on the epic task says the wave is building' },
    decisions_summary: { type: 'string' },
    doc_facts_routed: { type: 'string', description: 'durable repo-facts routed into their owning docs/ card this wave (path + one-line what, per fact), or "none — <why>". Facts that deserved docs but missed the byte budget were filed as backlog tasks instead — name them.' },
    journey: JOURNEY_FIELD,
    ...FABLE_STAMPS,
    wave: {
      type: 'array',
      description: 'this wave of build slices, ≤8, integration-ordered',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'task_id', 'surface', 'files', 'instructions', 'gate', 'size', 'builder_model', 'round'],
        properties: {
          title: { type: 'string' },
          task_id: { type: 'string', description: 'slug of the PUBLISHED bp task for this slice — you created or verified it' },
          surface: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          instructions: { type: 'string', description: 'complete enough to build without more context; name the key choices it must respect' },
          gate: { type: 'string', description: 'exact shell command(s) that prove it' },
          size: { type: 'string', enum: ['small', 'medium', 'large'] },
          builder_model: { type: 'string', enum: ['opus', 'fable'], description: 'THIS SETS BOTH MODEL AND DEPTH (opus runs at medium, fable at high) — there is no separate effort knob and no xhigh, so mis-classifying a hard slice as routine costs twice. TWO INDEPENDENT AXES, either one alone is sufficient for fable. (1) DIFFICULTY: opus@medium is the default and fits most well-specified building; reserve fable for slices that are genuinely hard rather than merely large — subtle design judgment, cross-surface coupling, high blast radius. (2) SURFACE: a VISUALLY DESIGNED slice goes to fable regardless of size — palette, layout, typography, CSS, LiveView/SPA chrome, anything judged against the Kinsta/Vercel bar. A small fully-specified CSS slice is easy on axis 1 and would fall to opus; that is the wrong call. System/architecture design is NOT this axis — that judgment already happened in Strategize/Decide' },
          round: { type: 'integer', minimum: 1, description: 'dispatch round. 1 = dependency-free, builds THIS run. ≥2 = depends on a lower-round slice being MERGED first — the run does NOT build it; it is returned as a deferral the lead dispatches after merging its deps (sequenced-rounds law: a slice never dispatches beside its unmerged dependency)' },
          after: { type: 'array', items: { type: 'string' }, description: 'for round ≥2: the same-wave task_ids that must MERGE before this slice dispatches (put the same fact in the task brief as an "AFTER <task_id> merges" line)' },
        },
      },
    },
  },
}

const BUILD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ok', 'task_id', 'task_claimed', 'branch', 'summary', 'gate_command', 'gate_passed', 'review', 'files_changed', 'ledger_stamps', 'journey'],
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
    ledger_stamps: { type: 'string', description: 'the task mutations you made DURING the build — the claim, each `bp task stamp` (per-criterion --met evidence + honest --miss notes), each `bp task pulse` now-line at claim/phase boundaries, and deviation notes — proof the ledger stayed live and the now-line moved' },
    journey: JOURNEY_FIELD,
  },
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['reviewed', 'ledger_fixes', 'wave_log_appended', 'grade', 'commentary', 'paper_closed', 'heartbeat_stamped', 'next_wave', 'overall_verdict', 'retro', 'telemetry_appended', 'journey', 'started_at', 'ended_at'],
  properties: {
    journey: JOURNEY_FIELD,
    ...FABLE_STAMPS,
    reviewed: {
      type: 'array',
      description: 'one entry per built slice you reviewed',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'task_id', 'final_branch', 'fixes', 'gate_passed', 'verdict', 'pushed'],
        properties: {
          title: { type: 'string' },
          task_id: { type: 'string' },
          final_branch: { type: 'string', description: 'branch the lead should integrate (the -r branch if you fixed anything, else the original)' },
          fixes: { type: 'string', description: 'what you fixed in place, or "none"' },
          gate_passed: { type: 'boolean', description: 'the slice gate re-run green on the final branch' },
          verdict: { type: 'string', description: 'honest quality verdict vs the Kinsta/Vercel bar + anything the lead must know before merging' },
          pushed: { type: 'boolean', description: 'final_branch was pushed to origin (step 11). FALSE means this slice exists only on a local branch in a shared checkout other cycles reset — i.e. the wave did not deliver it. If false, the verbatim push/PR error belongs in verdict.' },
          pr: { type: 'string', description: 'PR URL or number opened for final_branch, or "" if pushed is false' },
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
    retro: {
      type: 'array',
      description: 'PROCESS RETRO (epic-memory D7): one honest efficiency verdict PER PHASE (strategize, survey, digest, verify, decide, build, review), each tied to a telemetry row or a journey moment — wasted surveys, duplicate verifies, builders burned on BLOCKED. "no waste seen" is a valid verdict; manufactured criticism is not.',
      items: {
        type: 'object', additionalProperties: false,
        required: ['phase', 'verdict', 'suggestion'],
        properties: {
          phase: { type: 'string' },
          verdict: { type: 'string', description: 'what actually happened, tied to evidence' },
          suggestion: { type: 'string', description: 'one concrete efficiency change, or "keep as is"' },
        },
      },
    },
    telemetry_appended: { type: 'boolean', description: 'true only after the wave telemetry (stat-grid headline + per-phase table, at measured grain) AND the retro landed in the Paper debrief and it re-published' },
  },
}

// Epic-memory tripwire (design D1): every report carries journey{} — the
// debrief agent's raw material. An edit that drops one starves the debrief
// SILENTLY, days later, when nothing else can notice. Identity check, not
// truthiness: a forked copy of the field drifts exactly like a dropped one.
for (const [name, schema] of [
  ['STRATEGY_SCHEMA', STRATEGY_SCHEMA], ['SURVEY_SCHEMA', SURVEY_SCHEMA],
  ['AIM_SCHEMA', AIM_SCHEMA], ['VERIFY_SCHEMA', VERIFY_SCHEMA],
  ['PLAN_SCHEMA', PLAN_SCHEMA], ['BUILD_SCHEMA', BUILD_SCHEMA],
  ['REVIEW_SCHEMA', REVIEW_SCHEMA],
]) {
  if (schema.properties.journey !== JOURNEY_FIELD) {
    throw new Error(`${name}.journey is missing or forked — the epic-memory carrier (design D1) was dropped. Wire journey: JOURNEY_FIELD.`)
  }
  if (!(schema.required || []).includes('journey')) {
    throw new Error(`${name} does not REQUIRE journey — an optional journey decays to absent under load (design D1).`)
  }
}

// Same class of tripwire for the clock: telemetry.clock reads these stamps.
for (const [name, schema] of [
  ['STRATEGY_SCHEMA', STRATEGY_SCHEMA], ['AIM_SCHEMA', AIM_SCHEMA],
  ['PLAN_SCHEMA', PLAN_SCHEMA], ['REVIEW_SCHEMA', REVIEW_SCHEMA],
]) {
  for (const key of ['started_at', 'ended_at']) {
    if (!schema.properties[key] || !(schema.required || []).includes(key)) {
      throw new Error(`${name}.${key} is missing or optional — the wall-clock telemetry carrier (design D6) was dropped; clock arrays would silently go null.`)
    }
  }
}

// ── Phase 1: Strategize — one Fable mind, unhurried; the direction sets the wave's ceiling ──
phase('Strategize')
const strategist = await neverLose((m) => agent(
  `You are the STRATEGIST of a Barkpark epic wave — one Fable mind whose direction sets the CEILING for everything downstream. Take whatever time this needs: surveyors, verifiers, and builders can execute a great direction well, but nothing after you can rescue a mediocre one. Two exploration rounds of rigor follow, so you never need to PROVE claims — but read as much as sharpens your judgment. Bold is still the mandate; unhurried bold, not hedged.

${USER_WISH_BLOCK}

${CHARTER_EXISTS
    ? `The epic charter exists at ${CHARTER_PATH} — read it FULLY, plus the epic's bp task tree${EPIC_TASK_ID ? ` (bp task get ${EPIC_TASK_ID} carries children)` : ''} and the prior wave Papers/debriefs it names. Reconcile the charter with what actually landed, then set the direction for THIS wave: what matters most now, what should be finished vs started, where the quality bar (Kinsta/Vercel) is not yet met. THEN SEARCH BEFORE ASKING (epic-memory D4): \`bp search query "<epic terms>"\` for prior wave Papers and debriefs on this topic. Any survey question a prior Paper already answered becomes a drift-check assignment (mode='drift-check', prior_paper=<id>) — verification is cheap, re-research is not.`
    : `This is the FOUNDING wave — no charter yet. Ground yourself honestly: \`bp search query "<terms>"\` for prior papers/tasks on this topic (the \`query\` sub-verb is REQUIRED; without it the command exits 2 and looks like "no prior art"), then read the surfaces the wish actually touches — verification is the fleets' job, but the DIRECTION is yours alone, and a direction set on an unread codebase is a guess. If prior papers already answer a question you were going to ask, file it as mode='drift-check' with prior_paper set.`}

WORK THE PROBLEM PROPERLY, in whatever order serves you:
- GROUND: read until further reading stops changing your mind — the charter/ledger/prior papers above, the real code of the surfaces involved, adjacent systems that constrain the design. Depth is your call; a clock is not.
- DELIBERATE: develop at least two genuinely different candidate directions for this wave and argue them against each other — what the finished experience looks/feels like under each, what each risks, what each forecloses for later waves. Then COMMIT to one. A direction that never faced a serious rival is usually the first idea, not the best one.
- STRESS-TEST: attack the winner before shipping it. What would make it wrong? Which assumption, if false, kills it? Each such assumption becomes a survey question below — ammunition for the fleets, not a reason to hedge the direction.

Your output:
1. direction — the bold strategic direction for this wave: what the finished experience looks/feels like, the key choices you lean toward (tentatively; Decide finalizes after two explore rounds), what to prioritize.
2. direction_debate — the rivals you weighed, why the winner won, the sharpest attack on it and how the wave absorbs it.
3. survey — 5-20 BROAD assignments for the Opus surveyor fleet. Cast a wide net: suspected files, prior art (in the repo AND in bp papers/tasks), claims to check, seams to map, adjacent systems that might constrain the design, and every load-bearing assumption your stress-test surfaced. Width is cheap here — ask everything you'd want a scout report on. The Digest phase distills; you do not need to be precise yet.
4. OPEN THE WAVE PAPER: create + publish the wave strategy Paper (slug like <epic>-wave-<YYYY-MM-DD>, style=article): the wish, your direction, the direction debate (candidates weighed, why the winner won), the survey plan (every question + why). This Paper is the wave's living story — every later phase appends to it; someone opening it mid-wave sees exactly where the wave stands. Read it back before setting paper_created=true.
5. HEARTBEAT: ${EPIC_TASK_ID ? `stamp the epic task ${EPIC_TASK_ID}: flat wave_status ("wave: surveying — <one-line direction>") + flat wave_paper (the Paper's id), then re-publish.` : 'if a published epic parent task already exists for this epic, stamp its wave_status + wave_paper; if none exists yet, skip (Decide creates it).'}
CLOCK STAMPS (telemetry, epic-memory D6): run \`date -u +%FT%TZ\` as your first command → started_at; run it again as your very last → ended_at.
${JOURNEY_BLOCK}
${PREMISE_SMOKE_BLOCK}
${PAPER_BLOCK}
${LEAD_NOTES}`,
  { label: 'strategist', phase: 'Strategize', schema: STRATEGY_SCHEMA, model: m, effort: EFFORT_FOR(m) }
), { label: 'strategist', model: M(STRAT_MODEL), other: M(JOINT_FALLBACK) })
if (!strategist) throw new Error(`Strategize returned nothing after four dispatches spanning ${STRAT_MODEL} and ${JOINT_FALLBACK}. There is no partial wave to salvage — nothing has been surveyed, decided, or written. Resume the run rather than restarting.`)
const surveyAssignments = (strategist.survey || []).slice(0, 20)
if (surveyAssignments.length < SURVEY_FLOOR) {
  throw new Error(`Survey fan-out floor: the strategist returned ${surveyAssignments.length} survey assignment(s), below the floor of ${SURVEY_FLOOR}. Width is the cheapest part of a wave and a narrow survey is how a wave misses prior art it then rebuilds. Re-run Strategize with a wider net (5-20 assignments) rather than proceeding.`)
}
const WAVE_PAPER = strategist.paper_id
SPENT.strategize = budget.spent()
log(`Strategist set direction; wave paper ${WAVE_PAPER} (created=${strategist.paper_created}); ${surveyAssignments.length} survey assignments`)

// ── Phase 2: Survey — wide Opus sweep at medium effort, ~5 minutes each ──
phase('Survey')
const surveyResults = surveyAssignments.length === 0 ? [] : (await parallel(
  surveyAssignments.map((q) => () =>
    neverLose((m) => agent(
      `You are a SURVEYOR on a Barkpark epic wave — one of up to 20 scouts in a fast, wide sweep. READ-ONLY: no edits, no commits, no bp mutations. Budget: ~5 minutes — breadth over depth. A fast honest answer with real file:line anchors beats a deep dive; park what you can't settle in open_questions (a targeted verify round runs after you).

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (context for what your answer feeds):
${strategist.direction}

YOUR ASSIGNMENT [${q.key}]: ${q.question}
WHY IT MATTERS: ${q.why}
${q.mode === 'drift-check' ? `
DRIFT-CHECK MODE (epic-memory D4): prior wave Paper ${q.prior_paper || 'MISSING — the strategist omitted prior_paper; treat this as research mode and say so in findings'} already answered this. Read it, re-run its facts' rerun commands, and report each fact CONFIRMED or DRIFTED in your facts[] (with a fresh rerun command). Spend remaining time ONLY on the delta — what changed, what was never asked. Do not re-derive settled ground.` : ''}

Search Barkpark FIRST (\`bp search query "<terms>"\` — the \`query\` sub-verb is REQUIRED; dropping it exits 2 with \`unknown command "search"\`, and that failure reads exactly like a real absence of prior art, so check the exit code — papers and tasks carry prior art the tree doesn't), then grep/read the repo${CHARTER_EXISTS ? `; the charter at ${CHARTER_PATH} is a fair source` : ''}. Answer honestly — "the premise is wrong" is a valid and valuable answer. Every load-bearing fact needs evidence you actually derived, and its \`rerun\` command.

COVERAGE ACCOUNTING (your report is only trustworthy if its edges are visible): list EVERY file/paper/task you checked in coverage[] — the path, what you checked it for, and found / not_found / partial. NOT-FOUND IS A FINDING ("no existing rate limiter in api/" changes the plan as much as finding one). Anything you did not list is treated as unchecked — do not imply coverage you don't have. The wave Paper (${WAVE_PAPER}) will carry your coverage map; you do NOT write the Paper yourself.
${JOURNEY_BLOCK}`,
      { label: `survey:${q.key}`, phase: 'Survey', schema: SURVEY_SCHEMA, model: m, effort: EFFORT_FOR(m) }
    ), { label: `survey:${q.key}`, model: M(SURVEY_MODEL), other: M('fable') })
  )
)).filter(Boolean)
// ONE interception, in place, right at the resolve — `surveys` is serialised
// TWICE downstream (in full into Digest, projected into Decide), and gating each
// serialisation site separately would be the copies-that-must-agree defect in
// miniature. Mutating here means every downstream reader sees the gated array.
const surveys = surveyResults.filter(Boolean)
// Index-aligned: parallel() preserves order, so a null at position i is exactly
// assignment i going unanswered. This is the ONLY place that mapping exists —
// downstream phases see the rendered deficit, never the raw nulls.
const surveyLost = surveyAssignments.filter((q, i) => !surveyResults[i])
const SURVEY_DEFICIT = deficitBlock('survey', surveyLost)
const surveyGrip = gateFactProvenance(surveys)
log(`${surveys.length}/${surveyAssignments.length} surveyors reported${surveyLost.length ? ` — ${surveyLost.length} LOST after full recovery (${surveyLost.map((q) => q.key).join(', ')}); the wave continues and carries them as unanswered` : ''}; ${surveys.filter((s) => s.recovered_on).length} recovered cross-model; provenance gate: ${surveyGrip.demoted}/${surveyGrip.total} fact(s) DEMOTED (no rerun command)`)
SPENT.survey = budget.spent()

// ── Phase 3: Digest — one Fable mind, ~10 minutes, designs the verify fleet ──
phase('Digest')
const aim = await neverLose((m) => agent(
  `You are the DIGEST strategist of a Barkpark epic wave — the same Fable judgment that set the direction, now holding ${surveys.length} survey reports. Budget: ~10 minutes. Your output designs the LAST exploration round before the plan is cut — after it, there is no more looking.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (yours, from Strategize):
${strategist.direction}

DIRECTION DEBATE (the rivals you weighed and the sharpest attack on the winner — survey evidence that lands on an attack line matters MORE than evidence that merely decorates the direction):
${strategist.direction_debate}

SURVEY REPORTS (wide but shallow — trust file:line evidence over prose; treat unanchored claims as rumors):
${JSON.stringify(surveys, null, 2)}
${SURVEY_DEFICIT}

Your job:
1. SYNTHESIZE: what is now established, where reports contradict each other or the direction, which open_questions actually matter for the wish, and what the Decide phase cannot live without knowing.
2. DESIGN THE VERIFY FLEET (1-15 assignments) — you choose, per assignment:
   - model: 'opus' (runs at medium) for mapping, breadth follow-ups, and running a gate to quote its output — that is most verification. 'fable' (runs at high) ONLY where the answer is a judgment rather than a lookup: subtle correctness, cross-surface reasoning, a call where being wrong is expensive. Depth comes from the model, never from straining one upward — there is no xhigh in this workflow. Expect most of your fleet to be opus; a fleet that is mostly fable is a fleet that has not triaged.
   - verify_commands: where a survey claim (or your own assumption) is load-bearing, the verifier must PROVE it by RUNNING something — the surface's tests/gates, a targeted mix/go test, curl against localhost. Reading is not proof for claims like "the gate passes", "this endpoint returns X", "these tests pin that behavior" (distrust vacuous green — a pass only counts if the RIGHT thing produced it). Empty string when reading genuinely suffices.
   - needs_worktree: true only for probe edits or isolated build dirs. An assignment that will write ledger rows under tooling/grip/ledger/ must NOT set it — Decide commits from the shared checkout and never sees a throwaway worktree, so those rows would be stranded.
   Do not re-ask what the survey settled with evidence. This round closes unknowns; it does not browse.
3. UPDATE THE WAVE PAPER (${WAVE_PAPER}) — append, then re-publish, BEFORE your fleet flies:
   - Survey digest: the synthesis, plus a coverage map distilled from the surveyors' coverage[] — what was checked and found, and JUST AS PROMINENTLY what was checked and NOT found (absences are decisions-in-waiting). Name which corners of the repo no surveyor reached.
   - JOURNEY ROSTER (epic-memory D2): one card per surveyor (cards block) — mission → what they figured out → what it means — distilled from each report's journey{}; keep the turning points and surprises, drop boilerplate. A reader must be able to follow every scout's arc without the raw reports.
   - Verify plan: every assignment (question, model, what will be RUN as proof) — so the Paper states what is in flight while the verifiers work.
   Set paper_updated=true only after you re-published and read it back.
4. HEARTBEAT: ${EPIC_TASK_ID ? `stamp the epic task ${EPIC_TASK_ID}'s flat wave_status field ("wave: verifying — <one-line synthesis>") and re-publish.` : 'if a published epic parent task for this epic already exists, stamp its wave_status; if none exists yet, set heartbeat_stamped=true and move on (Decide creates it).'}
CLOCK STAMPS (telemetry, epic-memory D6): run \`date -u +%FT%TZ\` as your first command → started_at; run it again as your very last → ended_at.
${JOURNEY_BLOCK}
${PREMISE_SMOKE_BLOCK}
${PAPER_BLOCK}
${LIVENESS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'digest', phase: 'Digest', schema: AIM_SCHEMA, model: m, effort: EFFORT_FOR(m) }
), { label: 'digest', model: M(STRAT_MODEL), other: M(JOINT_FALLBACK) })
if (!aim) throw new Error(`Digest returned nothing after four dispatches spanning ${STRAT_MODEL} and ${JOINT_FALLBACK} — not a model problem at that point (check auth/spend). The survey reports are intact; resume the run rather than restarting so they are not re-bought.`)
const verifyAssignments = (aim.verification || []).slice(0, 15)
if (verifyAssignments.length < VERIFY_FLOOR) {
  throw new Error(`Verify fan-out floor: the digest returned ${verifyAssignments.length} verify assignment(s), below the floor of ${VERIFY_FLOOR}. Verify is the LAST round before the plan is cut — nobody checks after it. A wave that surveyed wide and then verified nothing is deciding on unproven claims. Re-run Digest with a real verify fleet (1-15 assignments, floor ${VERIFY_FLOOR}) rather than proceeding.`)
}
log(`Digest done; verify fleet: ${verifyAssignments.length} (${verifyAssignments.filter((v) => v.model === 'fable').length} fable@high, rest opus@medium; ${verifyAssignments.filter((v) => v.verify_commands).length} with live proofs)`)
SPENT.digest = budget.spent()

// THE CARVE-OUT, MADE RUNNABLE. The verify prompt below granted a write and
// named no verb, so a verifier had to rediscover the write path from scratch
// and most abandoned the write. This is the whole path — the schema it must
// materialise, the rehearsal, the verb, the one-new-file fence, and what a
// refusal does. Kept literal: verifier-write-join.test.mjs EXTRACTS these two
// commands from this string and runs them, so wording that drifts away from
// ledger.mjs reds. No level-ladder vocabulary here (D20).
const LEDGER_WRITE_HOWTO = `
WRITING A LEDGER ROW (the carve-out above, made runnable — nothing materialises the input for you):
- Your facts file is a JSON array of \`{claim, evidence, rerun}\` — exactly those three keys, and never a \`value\`/\`result\` key (the store indexes how to re-derive, never the answer). Only \`rerun\` reaches the store; subject and quantity are minted out of that command, not out of your prose, so write \`rerun\` as if it were the only thing you were saying.
- Rehearse: \`node tooling/grip/ledger.mjs prescreen <facts.json>\` — stores nothing, prints ADMIT/REFUSE plus the screen's own reason per row, exits 1 exactly when the write would refuse.
- Write: \`node tooling/grip/ledger.mjs write <facts.json>\` — omit the optional trailing [dir] and the run file lands in tooling/grip/ledger/ from any cwd.
- SCOPE FENCE: run it ONCE. It creates exactly one new \`<run_id>-<digest>.json\` and opens no existing file. Never hand-edit a *.json there — the fold reads a forgery back as authoritative — and touch nothing else under tooling/grip/.
- FAILURE IS ALL-OR-NOTHING: one refused row stores NOTHING, prints \`REJECTED — nothing was written\` with a reason class per row (REFUSED-COMMAND, VALUE-STORED, UNKNOWN-FIELD, …) and exits 1; nothing mintable also exits 1; an unreadable or non-array facts file exits 2. Success exits 0 and prints \`wrote <path>\`; the identical write re-run is idempotent — \`already recorded\`, same file, still exit 0. Never retry a refusal unchanged: fix or drop those rows and re-run prescreen.`

// ── Phase 4: Verify — the Fable-designed fleet closes the unknowns ──
//
// THE STRANDED-FILE CASE IS RULED, NOT LEFT SILENT (charter D27/D35). Verify
// WRITES ledger rows under tooling/grip/ledger/ and Decide COMMITS them, one
// phase apart. Between those two phases the rows are uncommitted, so there is
// a real window: if Decide dies, throws, or cuts zero slices, whatever the
// verifiers wrote stays uncommitted and is eventually LOST.
//
// THAT LOSS IS ACCEPTED. No sweep is built, here or anywhere:
//   - A sweep would have to stage files in a checkout OTHER LIVE SESSIONS
//     SHARE, on a path where nothing succeeded — riskier than the loss it
//     prevents. Committing another session's in-flight work is unrecoverable
//     in a way a missing recipe is not.
//   - A row is a RE-DERIVATION RECIPE, never a value (D26). Losing one costs
//     exactly one re-run of a command that, by construction, still exists and
//     still works. Cheapness-to-re-derive is the whole point of the store; a
//     store whose contents are cheap to rebuild does not deserve a dangerous
//     rescue path.
// The second stranding path — a needs_worktree verifier writing into its own
// throwaway worktree, a distinct path Decide cannot reach no matter how its
// commit is worded — is closed differently, by DENYING the carve-out on that
// branch of the prompt below rather than by trying to recover from it.
phase('Verify')
const verifyResults = verifyAssignments.length === 0 ? [] : (await parallel(
  verifyAssignments.map((q) => () =>
    neverLose((m) => agent(
      `You are a VERIFIER on a Barkpark epic wave — the LAST explorer before the plan is cut; nobody checks after you. No commits, no bp mutations, never touch main${q.needs_worktree ? ' (you are in your OWN throwaway worktree — probe edits are fine, but commit nothing; and the ledger carve-out below is DENIED to you: a row written here would be stranded, because your worktree is a distinct filesystem path that Decide — which commits from the shared checkout — never sees)' : ', and exactly ONE repo-write carve-out: you may WRITE re-derivation recipe rows under tooling/grip/ledger/ (one new file per write, never opening an existing one), and nothing else, anywhere. You never commit them — Decide commits them one phase later, this same run. No other repo edits'}.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION:
${strategist.direction}

DIGEST SYNTHESIS (what is established and what you exist to close):
${aim.synthesis}

YOUR ASSIGNMENT [${q.key}]: ${q.question}
WHY IT MATTERS: ${q.why}
${q.verify_commands ? `MUST RUN (proof, not reading): ${q.verify_commands}
Run it (plus whatever else proves/refutes the claim), and QUOTE the decisive output lines in proofs[] — never paraphrase a pass. A failing command is a finding, not a failure of yours.` : 'Reading suffices for this assignment, but if you find a load-bearing claim that only a run can settle, run it and record the proof.'}

Investigate sharply — grep/read${CHARTER_EXISTS ? `, the charter at ${CHARTER_PATH},` : ''} \`bp search query "<terms>"\` for prior art (the \`query\` sub-verb is REQUIRED — without it the command exits 2 and the empty result is indistinguishable from genuine absence). "The premise is wrong" remains a valid answer. Every fact needs evidence you actually derived plus its \`rerun\` command; every proof needs real output.
${q.needs_worktree ? '' : LEDGER_WRITE_HOWTO}

COVERAGE ACCOUNTING: list EVERY file/paper/task you checked in coverage[] — path, what you checked it for, found / not_found / partial. Not-found is a finding. Unlisted = unchecked. The wave Paper (${WAVE_PAPER}) will carry your coverage; you do NOT write the Paper yourself.
${JOURNEY_BLOCK}`,
      { label: `verify:${q.key}`, phase: 'Verify', schema: VERIFY_SCHEMA, model: m, effort: EFFORT_FOR(m), ...(q.needs_worktree ? { isolation: 'worktree' } : {}) }
    // Recovery hops the OTHER way for a fable-assigned verifier, so a lost
    // judgment-heavy dig retries on opus rather than giving up on the question.
    ), { label: `verify:${q.key}`, model: M(q.model === 'fable' ? 'fable' : 'opus'), other: M(q.model === 'fable' ? 'opus' : 'fable') })
  )
)).filter(Boolean)
// Same single interception for the verify round, at its own resolve.
const verifications = verifyResults.filter(Boolean)
// Same index-alignment as Survey. A lost verifier costs more than a lost
// surveyor — nobody checks after Verify — which is an argument for making the
// gap LOUDER to Decide, not for throwing and losing the verifications that did
// come back with real proof output attached.
const verifyLost = verifyAssignments.filter((q, i) => !verifyResults[i])
const VERIFY_DEFICIT = deficitBlock('verify — NOTHING RUNS AFTER THIS ROUND, so these stay open for the whole wave', verifyLost)
const verifyGrip = gateFactProvenance(verifications)
log(`${verifications.length}/${verifyAssignments.length} verifiers reported${verifyLost.length ? ` — ${verifyLost.length} LOST after full recovery (${verifyLost.map((q) => q.key).join(', ')}); these unknowns stay OPEN and Decide is told so` : ''}; ${verifications.filter((v) => v.recovered_on).length} recovered cross-model; ${verifications.reduce((n, v) => n + (v.proofs || []).length, 0)} live proofs; provenance gate: ${verifyGrip.demoted}/${verifyGrip.total} fact(s) DEMOTED (no rerun command)`)
SPENT.verify = budget.spent()

// ── Phase 5: Decide — one Fable mind finalizes charter + wave + tasks ──
phase('Decide')
const EPIC_TASK_LINE = EPIC_TASK_ID
  ? `The epic parent task is ${EPIC_TASK_ID} — verify it exists and is published; file this wave's slice tasks as its children (parent_id=${EPIC_TASK_ID}).`
  : `Ensure ONE published epic parent task exists for this epic (create it if missing — slug it from the charter name); file this wave's slice tasks as its children via parent_id.`
const architect = await neverLose((m) => agent(
  `You are the STRATEGIST-ARCHITECT of a Barkpark epic — the same Fable judgment that set direction and digested exploration, now DECIDING with two rounds of ground truth in hand. Take whatever time this needs; the IMPORTANT CHOICES get made here.

${USER_WISH_BLOCK}

STRATEGIC DIRECTION (from Strategize):
${strategist.direction}

DIRECTION DEBATE (from Strategize — the rivals weighed and the sharpest attack on the winner; if exploration proved an attack line RIGHT, switching to a rival direction is a legitimate decision, not a failure):
${strategist.direction_debate}

DIGEST SYNTHESIS (from Digest):
${aim.synthesis}

VERIFICATION REPORTS (the deep round — proofs[] carry actually-run output; trust proofs > facts > prose; spot-check anything load-bearing that smells off):
${JSON.stringify(verifications, null, 2)}

SURVEY REPORTS (the wide round, already distilled by the synthesis — consult for detail, not direction):
${JSON.stringify(surveys.map((s) => ({ key: s.key, findings: s.findings, facts: s.facts })), null, 2)}
${SURVEY_DEFICIT}
${VERIFY_DEFICIT}
If either deficit above is non-empty, the wave did NOT get the coverage it planned for. That is a fact about this wave, not an excuse: record it in the Paper's decision section by name, and let it shape the cut — a slice whose correctness rests on an unanswered question is either re-scoped, moved to a later round with the question re-asked, or filed to the backlog with the gap stated. Do not cut a confident slice on top of a hole and let the Paper imply it was verified.

Any survey fact carrying provenance DEMOTED-NO-RERUN has no command that re-derives it: treat it as an unverified belief at the level of agent memory, never as a settled measurement, and do not build a slice on one without first giving it a rerun command.

Your job:
1. DECIDE: finalize the key choices (decide them — don't list options). Where verification contradicted the direction, follow the evidence.
2. ${CHARTER_EXISTS
      ? `UPDATE the charter at ${CHARTER_PATH} (Read then Edit): reconcile with what landed, fold in decision changes, set the wave plan.`
      : `WRITE the epic charter to ${CHARTER_PATH} (Write tool): ## Vision, ## Decisions (each with a one-line why), ## Roadmap (all slices, ordered, sized), ## Wave log (empty). This file is the epic's memory — every future wave reads it.`} Then PUBLISH IT AS A DOCS-ONLY PULL REQUEST — never a direct push to main. \`main\` is protected: a direct push is rejected server-side with \`remote: error: GH006: Protected branch update failed for refs/heads/main.\`, exit 1, EVEN FOR A REPO ADMIN, and the contents API returns 409 with the same sentence, so there is no API detour (honest-gates charter D39, measured on live GitHub). The primary checkout also stays on \`main\` — never \`git switch\`/\`checkout -b\` there, ~40 sessions share it and a branch jump strands their uncommitted work — so the branch lives in ITS OWN WORKTREE:
   \`\`\`
   git fetch origin main
   BR=epic-charter/<epic-slug>-<UTC stamp: run \`date -u +%Y%m%dT%H%M%SZ\`>       # unique — a duplicate concurrent wave must not collide
   git worktree add ../bp-charter-wt-<same stamp> -b "$BR" origin/main
   \`\`\`
   Copy the charter you just wrote into that worktree BY EXPLICIT PATH (one \`cp\` of one named file), then INSIDE the worktree: \`git add <that one explicit path>\` — never \`git add -A\`, never a directory, never a glob you did not first expand and read — one docs-only conventional commit, then \`git push -u origin "$BR"\`, NEVER \`--force\` and NEVER a blind push (if the push is rejected, \`git pull --rebase origin main\` inside the worktree and push again; the branch is yours alone, so this should not happen).
   FILE AND CLAIM THE WAVE REFERENT **BEFORE** YOU OPEN THE PR — this is a step, not a formality, and doing it after \`gh pr create\` is already too late. The pr-task-gate's predicate is \`claim.expired_at >= pull_request.created_at\` (honest-gates charter D58): the verdict is FROZEN at PR-open time, so a task whose lease had ALREADY lapsed when the PR was created fails permanently. Measured live 2026-07-28 against the real ledger: a charter PR naming the epic parent at 21:30Z FAILS with \`had ALREADY lapsed 19979s before this PR was opened\`, while the SAME task with the PR opened at 15:00Z PASSES. Nothing rescues the losing side — not a re-run, not a re-claim, not close/reopen — because none of them move \`created_at\`; only a NEW PR opened under a live claim (or the \`hotfix!\` label) escapes. So, first:
   \`\`\`
   # a PER-WAVE referent, parented under the epic — published, then claimed
   bp task create --id <epic-slug>-wave-<N>-log --parent ${EPIC_TASK_ID || '<the epic parent task id>'} --title "Wave <N> paperwork: charter PR + wave log" ...   # or the bp doc create task + bp doc publish fallback
   bp task claim <epic-slug>-wave-<N>-log <this run's worker id>        # doc.claim.epoch comes back here
   \`\`\`
   THE REFERENT IS PER-WAVE, AND THE REJECTED ALTERNATIVE IS RECORDED HERE SO NO LATER PHASE RE-DERIVES IT: claiming the long-lived epic parent Goal (${EPIC_TASK_ID || '<the epic parent task id>'}) would also satisfy the gate, and it is WRONG — it misrepresents that Goal's lifecycle for the whole wave, parking a multi-wave Goal in \`in_progress\` under one Decide agent's name for hours, and it makes the Goal's claim state a hostage of PR timing. A \`<epic-slug>-wave-<N>-log\` child is exactly as long-lived as this wave's paperwork, which is what the gate should be vouching for.
   THEN PULSE IT UNTIL THE PR IS OPEN: \`bp task pulse <referent> <worker> --now "…"\` at least every 30 MINUTES from the claim until \`gh pr create\` returns, and once more immediately after with the PR number. The lease is 2700s — \`api/lib/barkpark/tasks/ttl_sweeper.ex:158 @default_ttl_seconds 2700\`, i.e. 45 minutes — so 30 leaves margin for a slow push or a rebase. PULSE IS A KEEP-ALIVE AND NEVER A RESURRECT: \`api/lib/barkpark/tasks/pulse.ex:130-136\` \`check_live/1\` refuses anything not \`in_progress\` with \`:not_holder\`, so once the lease is reaped you cannot pulse your way back — you must re-claim, and if the PR is already open by then, that PR is dead and you open a new one.
   THEN OPEN THE PR: \`gh pr create --base main --head "$BR"\`, and its body MUST carry the line \`Task: <the wave referent id you just claimed>\` ON ITS OWN LINE — that is exactly what the pr-task-gate reads, and it reads it on EVERY pull request: \`.github/workflows/pr-task-gate.yml:43\` says verbatim "No paths filter: any change needs a task, so every PR is checked." THERE IS NO DOCS-ONLY SKIP FOR THIS GATE — a \`.md\`-only diff does NOT clear it (the paths-filtered skip you may be remembering belongs to the Elixir gate's dispatcher, a different workflow), so a charter PR carrying a lapsed or missing referent is unmergeable, permanently.
   REPORT, DO NOT PUSH: set charter_written=true, charter_pr=<the PR number or URL>, and wave_referent_task=<the referent id you claimed and pulsed> once the PR is OPEN and reporting its checks. The success condition of this phase is THE PR EXISTING AND REPORTING, not a push succeeding — do not block the wave waiting on the merge; the lead merges it. And because the charter therefore may NOT be on origin/main while the builders fly, name the PR in decisions_summary and make sure this wave's decisions are in the wave Paper IN FULL (step 7) — the Paper is what a builder can read today.
   THE SAME PR CARRIES THIS RUN'S LEDGER ROWS: the verify fleet may have written re-derivation recipe rows under tooling/grip/ledger/ and it is forbidden to commit them — that is YOUR step. Run \`git status --porcelain tooling/grip/ledger/\` in the PRIMARY checkout; for each untracked *.json it names, copy that file into the charter worktree BY EXPLICIT PATH and \`git add\` it there — never \`git add -A\`, never a directory, never a glob you did not first expand and read, because other sessions share this checkout. Same commit as the charter, or a second docs-only commit on the same branch — either is fine, both ride the one PR, and nothing here ever touches main directly. If it names nothing, skip the step silently; touch nothing else under tooling/grip/.
2b. ROUTE DURABLE REPO-FACTS INTO DOCS (epic-memory D5) — do this WHILE THE CHARTER WORKTREE STILL EXISTS, i.e. before the \`git worktree remove\` that closes step 2b (if it is already gone, \`git worktree add\` a fresh one on \`$BR\`): from this wave's verified facts, the FEW that are durable repo-truths (not wave-local findings) go into their OWNING docs/ card per the CLAUDE.md routing table — corrections and gap-fills only, never additive research dumps; byte budgets and the 7-card cap are sovereign. Gate before committing: bash scripts/check-doc-budgets.sh && bash scripts/docs-anchors-check.sh. The edit RIDES THE CHARTER PR — never a direct push to main: make the edit in the primary checkout, then copy the card into the charter worktree BY EXPLICIT PATH and \`git add\` it there, on the same branch and in the same PR as the charter (same commit or a second docs-only one, either is fine). A fact that deserves docs but misses budget becomes a published backlog task instead. Record everything in doc_facts_routed. Then \`git worktree remove\` the worktree (the primary checkout keeps its working copy of the charter, uncommitted, so THIS run can still read it — leave it alone, do not commit it to main).
3. FILE THE TASKS: ${EPIC_TASK_LINE} Every slice gets a published bp task with rubric-quality acceptance criteria (include a merge-gated criterion the lead closes) and the wave Paper's id on it (flat wave_paper field) so task → story is one hop. A slice without a published task does not exist — wave[].task_id is required.
4. SEED THE BACKLOG: everything exploration surfaced that is real but NOT this wave gets filed now as a published child task (honest description, sane priority) — record the ids in backlog_filed. The ledger must show the future, not just the present.
5. PERFECT THE TASKS (you are also the task reviewer — there is no one behind you): after filing, re-read every wave task back from the server and verify it is published (not a stranded draft), parented under the epic task, linked to the wave Paper, and reads to the rubric — outcome-shaped title, description a cold builder could start from, concrete evidence-bearing criteria, sane priority. Fix every defect via bp (patch, publish, re-parent, dedup stranded drafts). Set tasks_verified=true only after this read-back pass is clean.
6. CUT THE WAVE: up to 8 slices, buildable in parallel by isolated builders (minimize file overlap; if two slices must touch the same region of a file, merge or sequence them). ROUNDS ARE LAW (three waves proved briefs alone don't stop the dispatcher): stamp every slice with \`round\`. round 1 = dependency-free, builds this run. A slice that needs another slice's code ON MAIN (imports its package, calls its seam, seeds its schema) is round ≥2 with \`after: [<dep task_ids>]\` — it will NOT build this run; the lead dispatches it after merging its deps (this exact manual-rounds recipe went 7-for-7 across two epics). Never mark a slice round 1 "optimistically" — a round-1 slice whose dep is unmerged burns a builder to produce a BLOCKED report. Write the same dependency as an "AFTER <task_id> merges" line at the TOP of the deferred task's brief so a manually-dispatched builder sees it first. Per slice pick builder_model, which sets BOTH the model and its depth ('opus' builds at medium, 'fable' at high — there is no separate effort knob and nothing above high, so this one choice is the whole decision and mis-classifying a hard slice as routine costs twice). TWO INDEPENDENT AXES, either one alone is enough to warrant fable. DIFFICULTY: 'opus' is the default and fits most well-specified building; reserve 'fable' for slices that are genuinely hard rather than merely large — subtle design judgment, cross-surface coupling, high blast radius. SURFACE: a VISUALLY DESIGNED slice gets 'fable' regardless of size — palette, layout, typography, CSS, LiveView/SPA chrome, anything judged against the Kinsta/Vercel bar; a small fully-specified CSS slice is easy on the difficulty axis and would wrongly fall to opus. (System/architecture design is not this axis — you already did that judgment here.) ${CHARTER_EXISTS ? 'Weight FINISHING what exists (quality, coherence, the Kinsta/Vercel bar) alongside net-new capability; prefer finishing journeys over starting new ones.' : 'Bold slices are fine.'} Each needs instructions complete enough to build without more context and exact local gate command(s) — DRY-RUN each gate command yourself before filing it (a gate that cannot run, or references paths/globs that don't exist, forces the builder to interpret instead of prove).
7. UPDATE THE WAVE PAPER (${WAVE_PAPER}) — append, then re-publish, BEFORE the builders fly:
   - Verification results: per assignment what was proven/refuted (quote the decisive proof lines), plus the verifiers' coverage — including not-founds — render proofs as code blocks quoting the decisive output lines, and the verifiers' journeys as cards.
   - FACTS TABLE (epic-memory D4): the load-bearing facts with their rerun commands (table block) — the next wave's strategist turns these into drift-checks instead of re-research.
   - Decisions: each with its one-line why (mirror the charter, don't fork it — the charter is the epic's memory, the Paper is this wave's story).
   - Wave plan: every slice with its task id, surface, builder model, gate — so the Paper states what is in flight while the builders work.
   Set paper_updated=true only after you re-published and read it back.
8. HEARTBEAT: stamp the epic task's wave_status ("wave: building <n> slices — <one-line plan>") + wave_paper=${WAVE_PAPER} and re-publish. Set heartbeat_stamped=true only after you did.
CLOCK STAMPS (telemetry, epic-memory D6): run \`date -u +%FT%TZ\` as your first command → started_at; run it again as your very last → ended_at.
${JOURNEY_BLOCK}
${TASKS_BLOCK}
${PREMISE_SMOKE_BLOCK}
${FLIP_RISK_BLOCK}
${PAPER_BLOCK}
${LIVENESS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
  { label: 'architect', phase: 'Decide', schema: PLAN_SCHEMA, model: m, effort: EFFORT_FOR(m) }
), { label: 'architect', model: M(ARCH_MODEL), other: M(JOINT_FALLBACK) })

if (!architect) throw new Error(`Decide returned nothing after four dispatches spanning ${ARCH_MODEL} and ${JOINT_FALLBACK} — not a model problem at that point (check auth/spend). Survey AND verify are intact and were expensive; resume the run rather than restarting so neither round is re-bought.`)
const wave = (architect.wave || []).slice(0, 8)
log(`Architect cut ${wave.length} slices (${wave.filter((w) => w.builder_model === 'fable').length} fable); charter_written=${architect.charter_written} (PR ${architect.charter_pr || 'NONE — the charter is not published'}, referent ${architect.wave_referent_task || 'NONE — that PR cannot pass the task gate'}); tasks_verified=${architect.tasks_verified}; epic task=${architect.epic_task_id}; backlog=${architect.backlog_filed}`)
SPENT.decide = budget.spent()
if (wave.length === 0) {
  return {
    surveys: surveys.length, verifications: verifications.length, wave_paper: WAVE_PAPER, wave: 0, built: 0, note: 'architect cut no slices', decisions: architect.decisions_summary,
    telemetry: {
      grain: 'partial — wave cut zero slices; build/review never ran',
      tokens_by_phase: {
        strategize: SPENT.strategize - SPENT.t0,
        survey: SPENT.survey - SPENT.strategize,
        digest: SPENT.digest - SPENT.survey,
        verify: SPENT.verify - SPENT.digest,
        decide: SPENT.decide - SPENT.verify,
      },
      interrupts: {
        surveyors_lost: surveyAssignments.length - surveys.length,
        verifiers_lost: verifyAssignments.length - verifications.length,
        facts_demoted_no_rerun: surveyGrip.demoted + verifyGrip.demoted,
      },
    },
  }
}

const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)

// ── Sequenced-rounds law (charter D43/D53, proven 7-for-7 as manual rounds):
// only round-1 (dependency-free) slices build in this run. round ≥2 slices are
// DEFERRED — returned to the lead, who merges round 1 and dispatches them as
// sequential rounds. Dispatching a slice beside its unmerged dependency burns
// a builder to produce a BLOCKED report (it happened three waves running).
const buildNow = wave.filter((w) => (w.round || 1) === 1)
const deferred = wave.filter((w) => (w.round || 1) > 1)
if (deferred.length > 0) {
  log(`Sequenced rounds: building ${buildNow.length} round-1 slice(s) now; DEFERRING ${deferred.length} (${deferred.map((w) => `${w.task_id} r${w.round} after ${(w.after || []).join('+') || '?'}`).join('; ')}) — the lead dispatches them after round 1 merges`)
}

// ── Phase 6: Build — Fable/Opus builders per slice complexity, task-first ──
phase('Build')
const built = (await parallel(
  buildNow.map((item, i) => () =>
    ((m) => agent(
      `You are BUILDING one slice of a Barkpark epic inside your OWN isolated git worktree (safe to edit/commit; you will not collide with other builders).

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first — your slice must respect its decisions. ${architect.charter_pr ? `HEADS UP, and this is not a formality: THIS wave's charter is still an OPEN PULL REQUEST (${architect.charter_pr}), because \`main\` is protected and Decide no longer pushes to it. Your worktree branched from origin/main, so the ${CHARTER_PATH} on your disk is the PREVIOUS wave's — it will read as plausible and be silently out of date. Get this wave's decisions from the wave Paper (${WAVE_PAPER}), which is current, and from your bp task brief; if you need the charter diff itself, \`gh pr diff ${String(architect.charter_pr).replace(/[^0-9]/g, '') || architect.charter_pr}\`.` : ''} The wave Paper (${WAVE_PAPER}) carries this wave's story — decisions, verification proofs, the other slices; read it for context, NEVER write it (your bp task is your voice).

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
3. STAMP AS YOU GO: the moment a criterion is actually proven (gate output, test name, behavior observed), invoke \`bp task stamp ${item.task_id} epic-builder-${slug(item.title)} <epoch> --criterion N --criterion-text "<that criterion's exact wording, verbatim>" --met --evidence "…"\` (epoch from your claim response, doc.claim.epoch; N is 0-BASED — the FIRST criterion is 0 — and \`--criterion-text\` is REQUIRED for \`--met\`: without it the stamp is REJECTED 409 criterion_text_required, because an index alone can silently flip a NEIGHBOURING criterion) — do not batch to the end; a criterion you attempted but could not meet gets \`--miss --note "…"\` (honest, no flip). And PULSE the now-line so the board moves during your run: \`bp task pulse ${item.task_id} epic-builder-${slug(item.title)} --now "…" [--criterion N]\` right after you claim and at each phase boundary (building → gating → committing). If you deviate from the brief or hit a wall, stamp a note the moment it happens. Record every stamp AND pulse in ledger_stamps.
4. JS SDK public API change ⇒ add a js/.changeset/ entry (correctness gate, never skip).
5. Run the gate. Fix until it passes; if it truly cannot, STOP without committing and report ok:false with why (leave the task claimed + in_progress with a stamped note explaining the stall).
6. Honest self-review: what could break, what you didn't cover, blind spots.
7. Only if the gate passes: branch 'loop-epic/${slug(item.title)}-${i}', one clear conventional commit. Do NOT push. Do NOT touch main.
8. Final ledger state: every criterion you proved carries concrete evidence (gate output, test names, branch); merge-gated criteria stay open and lifecycle stays in_progress — the LEAD closes on merge. Your branch is named in the evidence.
${JOURNEY_BLOCK}
${TASKS_BLOCK}
${LIVENESS_BLOCK}
SCOPE DISCIPLINE — your slice is the deliverable, at the scope it was cut. Other builders are working other slices of this same wave RIGHT NOW, and the wave's whole parallel design rests on your slice staying inside its FILES list; widening it is how two builders collide and one of them loses work. Deliver what the brief asks: make routine judgment calls yourself, but do not quietly widen, narrow, or transform the slice. Don't refactor around your change, don't add abstractions or error handling for cases that can't happen, don't tidy neighbouring code — a bug fix does not need surrounding cleanup. If you conclude the brief is wrong or a better approach exists, say so in a sentence in your self-review and BUILD IT AS BRIEFED anyway; rescoping is the lead's call, not yours. Finish the WHOLE slice, not the easy part — report ok:true only when every criterion is actually met, and if something genuinely can't be done, do the rest and say plainly what is missing and why.
DELEGATION — do the work yourself. A slice this size does not need subagents: each one re-establishes context, re-explores, and reports back, and you then re-read its report, which costs more than the work. Verification in particular belongs in YOUR loop — never spawn an agent to check your own work or re-run your gate. If you genuinely need one for an independent wide investigation, one is the ceiling.
Constraints: curl localhost only; never mix compile against prod; don't touch other worktrees' WIP.
Catalog-first (measured law, /papers/scaffy-benchmark): before hand-editing a repeated shape (block types, workers, error shapes, CLI verbs/nouns, migrations, plugins, routes/buckets, schema types, SDK methods, docs cards, canonical markers, imports, console helpers), check \`ls scaffy/commands/\` — if a command covers the chore, run \`bp scaffy run scaffy/commands/<name>.scaffy --var …\` instead of editing by hand (validate-first, receipts make it reversible; told agents produce engine-identical bytes, untold agents drift and lose reversibility).`,
      { label: `build:${slug(item.title)}`, phase: 'Build', schema: BUILD_SCHEMA, model: m, effort: EFFORT_FOR(m), isolation: 'worktree' }
    // Builders are the ONE fan-out not wrapped in neverLose: a retry would
    // re-dispatch against an already-claimed bp task, and the brief tells a
    // builder to STOP on a failed claim — so a rescue could turn a lost slice
    // into a stuck one. The IIFE exists only to bind the slice's model so
    // EFFORT_FOR can derive depth from it, exactly as every other call site.
    ))(M(item.builder_model === 'fable' ? 'fable' : 'opus'))
  )
)).filter(Boolean)

const greenBuilt = built.filter((r) => r.ok && r.gate_passed && r.branch)
log(`Build: ${greenBuilt.length}/${built.length} slices green`)
SPENT.build = budget.spent()

// Wave telemetry (design D6, honesty rule D9): measured grain ONLY. Tokens
// are per-phase deltas of budget.spent() — the runtime exposes nothing finer;
// per-agent splits DO NOT EXIST and must never be presented. Wall-clock comes
// from the Fable stamps (fleets are bracketed by Fable checkpoints). Interrupts
// are the countable frictions: lost agents (skips/API deaths), failed gates.
const telemetry = {
  grain: 'tokens = per-phase output-token deltas from budget.spent(); clock = Fable date -u stamps; per-agent token splits are NOT measured — never invent them',
  tokens_by_phase: {
    strategize: SPENT.strategize - SPENT.t0,
    survey: SPENT.survey - SPENT.strategize,
    digest: SPENT.digest - SPENT.survey,
    verify: SPENT.verify - SPENT.digest,
    decide: SPENT.decide - SPENT.verify,
    build: SPENT.build - SPENT.decide,
    review: 'in flight — lands in the run return, not the Paper (Review cannot know its own cost)',
  },
  clock: {
    strategize: [strategist.started_at, strategist.ended_at],
    survey_bracket: [strategist.ended_at, aim.started_at],
    digest: [aim.started_at, aim.ended_at],
    verify_bracket: [aim.ended_at, architect.started_at],
    decide: [architect.started_at, architect.ended_at],
    build_bracket: [architect.ended_at, 'review start — see Review stamps'],
  },
  fleet: {
    surveyors: `${surveys.length}/${surveyAssignments.length} reported`,
    verifiers: `${verifications.length}/${verifyAssignments.length} reported (${verifications.reduce((n, v) => n + (v.proofs || []).length, 0)} live proofs)`,
    builders: `${built.length}/${buildNow.length} reported, ${greenBuilt.length} green`,
    deferred_by_rounds_law: deferred.length,
  },
  interrupts: {
    surveyors_lost: surveyAssignments.length - surveys.length,
    verifiers_lost: verifyAssignments.length - verifications.length,
    builders_lost: buildNow.length - built.length,
    slices_not_green: built.length - greenBuilt.length,
    facts_demoted_no_rerun: surveyGrip.demoted + verifyGrip.demoted,
  },
}

// ── Phase 7: Review — one Fable mind reviews, fixes, grades, debriefs, hands off ──
phase('Review')
let review = null
if (built.length > 0) {
  review = await neverLose((m) => agent(
    `You are the REVIEWER for a just-built Barkpark epic wave — one Fable agent, the LAST hands before merge, taking whatever time this needs. You review EVERYTHING (code of every green slice + the task ledger), FIX issues yourself instead of reporting them, grade the wave honestly, write the Paper debrief, and hand off. You are in your OWN git worktree.

${USER_WISH_BLOCK}

Read the epic charter at ${CHARTER_PATH} first. Epic parent task: ${architect.epic_task_id}.${architect.charter_pr ? ` NOTE: this wave's charter is an OPEN PR (${architect.charter_pr}) — \`main\` is protected and Decide publishes by PR, so the copy on your disk is the PREVIOUS wave's. Read this wave's decisions from the wave Paper (${WAVE_PAPER}) and from \`gh pr diff\` on that PR. Your step-8 wave-log entry therefore belongs on the CHARTER PR's branch, not on a copy of main: check the PR out into your own worktree, append there, and push — appending to the stale local file silently drops this wave's charter changes.` : ''}

BUILT SLICES (review every green one):
${JSON.stringify(greenBuilt.map((b) => ({ task_id: b.task_id, branch: b.branch, gate: b.gate_command, summary: b.summary, builder_review: b.review, files: b.files_changed })), null, 2)}

NOT-GREEN SLICES (audit their ledger state only — the task must honestly reflect the stall):
${JSON.stringify(built.filter((b) => !greenBuilt.includes(b)).map((b) => ({ task_id: b.task_id, ok: b.ok, summary: b.summary })), null, 2)}

WAVE INSTRUCTIONS (what each slice was supposed to be):
${JSON.stringify(wave.map((w) => ({ title: w.title, task_id: w.task_id, round: w.round || 1, instructions: w.instructions, gate: w.gate })), null, 2)}

DEFERRED SLICES (round ≥2 — NOT built this run BY DESIGN, the sequenced-rounds law; do not grade their absence as a failure): ${deferred.length === 0 ? 'none' : deferred.map((w) => `${w.task_id} (round ${w.round}, after ${(w.after || []).join('+')})`).join('; ')}. Your next_wave handoff MUST spell out the dispatch order: merge round 1, then each deferred slice as its deps merge.

WAVE TELEMETRY (measured in-script — persist it in the Paper debrief as a stat-grid headline + a per-phase table; the debrief agent runs DAYS later when this run's files are gone; honesty rule D9 — measured grain only, never per-agent token splits):
${JSON.stringify(telemetry, null, 2)}

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
9. CLOSE THE WAVE PAPER (${WAVE_PAPER}): append the final DEBRIEF section and re-publish — what shipped (per slice: task, final branch, verdict), what stalled and why, the grade + commentary, the ledger audit outcome, what the next wave should take. Read the Paper top to bottom first: it now tells the whole wave's story (direction → survey coverage → verification proofs → decisions → outcome) — fix any section a later phase invalidated (a decision reversed, a proof superseded) with a dated correction note rather than silent rewriting. Report the Paper id in paper_closed. The debrief section MUST carry builder journey cards (from every builder's journey{}, including not-green slices — a stall is a story), your own journey, and the telemetry + retro sections (see WAVE TELEMETRY above). Include the RETRO: one verdict per phase in retro[], mirrored into the Paper's debrief section. If a session is open, log the seal: \`bp session log <session-slug> --kind epic-wave-complete --ref ${WAVE_PAPER}\` — a failed log never blocks the wave.
10. HEARTBEAT + HANDOFF: stamp the epic task's wave_status ("wave: complete — grade <g>, paper ${WAVE_PAPER}") and re-publish; set heartbeat_stamped accordingly.
   CLOSE THE WAVE REFERENT — it is the one task in this wave whose work IS finished when you finish, and nothing else will ever close it. Decide filed \`<epic-slug>-wave-<N>-log\`, claimed it so the charter PR could pass the task gate, and left it \`in_progress\`; you are the phase that appends the wave log and seals the Paper, i.e. the phase that completes exactly that paperwork. Left alone it is reaped by the TTL sweeper 45 minutes later and reads on the board as a STALLED claim rather than as finished work — a lie about a live system, filed by the machinery built to stop lying. The claim is Decide's and \`close\` is a CAS on the CURRENT claim, so: \`bp task claim <referent> <your worker id>\` (this returns a fresh \`doc.claim.epoch\`), then \`bp task close <referent> <your worker id> <that epoch> done "wave <N> paperwork complete: charter PR <#>, wave log appended, Paper ${WAVE_PAPER} sealed"\`. This is the ONE task Review closes outright — every SLICE task stays \`in_progress\` with its merge-gated criteria open for the lead. If the charter PR is still unmerged that is fine and changes nothing: the referent vouches for the paperwork being DONE, not for it being merged. Put the direction handoff in next_wave; per slice report final_branch (the -r branch if you changed anything), gate_passed on your final state, and an honest verdict incl. anything the lead must know before merging (the lead closes merge-gated criteria on merge — name them).
11. **PUSH EVERY FINAL BRANCH AND OPEN ITS PR. THE WAVE IS NOT DONE UNTIL YOU DO.** This is step 11 because SIX consecutive waves ended with built, reviewed, gate-passing work sitting on local-only branches in a SHARED multi-session checkout that other cycles reset — roughly 20 slices that existed only because a human went looking for them. A branch you do not push is work this wave did not do. For each green slice, from your worktree:
   RE-CLAIM (OR PULSE) THE SLICE TASK IMMEDIATELY BEFORE ITS PR IS OPENED — one command per slice, in the same breath as the push, and NEVER in a batch at the start of step 11. You are opening these PRs HOURS after the builders stopped pulsing, and the pr-task-gate freezes its verdict at PR-open time (\`claim.expired_at >= pull_request.created_at\`, honest-gates charter D58): a slice claim that lapsed in the gap between "builder done" and "Review opens the PR" reds that PR PERMANENTLY — no re-run, no later claim, no close/reopen moves \`created_at\`, so the only escape is a brand-new PR. The lease is 2700s (\`api/lib/barkpark/tasks/ttl_sweeper.ex:158 @default_ttl_seconds 2700\`), and builders finish well outside that window. So per slice: \`bp task pulse <task_id> <your worker id> --now "opening the slice PR"\` if the task is still \`in_progress\` and held — pulse is a KEEP-ALIVE, never a resurrect (\`api/lib/barkpark/tasks/pulse.ex:130-136\` \`check_live/1\` refuses anything not \`in_progress\` with \`:not_holder\`) — otherwise \`bp task claim <task_id> <your worker id>\` first and pulse after. Then push and open the PR, and only then move to the next slice.
   \`git push -u origin <final_branch>\` then \`gh pr create --head <final_branch> --title "<conventional-commit title>" --body "<what it does + the gate you re-ran + Task: <task_id>>"\`.
   The body MUST carry a single canonical \`Task: <task_id>\` line (not \`Tasks: a + b\`) or the PR↔task gate fails — and it is checked on EVERY PR regardless of what the diff touches (\`.github/workflows/pr-task-gate.yml:43\`: "No paths filter: any change needs a task, so every PR is checked"). Do NOT merge — the lead merges. Report per slice \`pushed: true\` and \`pr\`; if a push or PR genuinely fails, report \`pushed: false\` with the verbatim error, and say so in overall_verdict — never silently. A wave that grades A with unpushed branches has not earned it, and you must say that in the commentary.
CLOCK STAMPS (telemetry, epic-memory D6): run \`date -u +%FT%TZ\` as your first command → started_at; run it again as your very last → ended_at.
${JOURNEY_BLOCK}
${TASKS_BLOCK}
${PAPER_BLOCK}
${LIVENESS_BLOCK}
${FLIP_RISK_BLOCK}`,
    { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA, model: m, effort: EFFORT_FOR(m), isolation: 'worktree' }
  ), { label: 'review', model: M(REVIEW_MODEL), other: M(JOINT_FALLBACK) })
  // No throw here, and that is deliberate: by this point green branches EXIST on
  // disk. A lost Review costs the grade, the debrief, and the PR push — real
  // losses the lead must pick up (the downstream `review ? … : null` reads
  // already handle it) — but throwing would abandon built, gated work in a
  // shared checkout, which is the one failure this wave log has recorded most.
  if (!review) log('LOST review: the wave built work that is NOT reviewed, NOT graded, and NOT pushed — the lead must review the branches and open the PRs by hand')
}
SPENT.review = budget.spent()

const reviewedByTask = {}
for (const r of (review && review.reviewed) || []) reviewedByTask[r.task_id] = r
const green = greenBuilt.map((b) => ({ ...b, reviewed: reviewedByTask[b.task_id] || null }))
  .filter((b) => !b.reviewed || b.reviewed.gate_passed)

return {
  direction: strategist.direction,
  direction_debate: strategist.direction_debate,
  wave_paper: WAVE_PAPER,
  surveys: surveys.length,
  synthesis: aim.synthesis,
  verifications: verifications.length,
  proofs: verifications.reduce((n, v) => n + (v.proofs || []).length, 0),
  decisions: architect.decisions_summary,
  charter_written: architect.charter_written,
  charter_pr: architect.charter_pr,
  epic_task_id: architect.epic_task_id,
  tasks_verified: architect.tasks_verified,
  backlog_filed: architect.backlog_filed,
  wave: wave.length,
  built: green.length,
  deferred_slices: deferred.map((w) => ({
    task_id: w.task_id,
    round: w.round,
    after: w.after || [],
    builder_model: w.builder_model,
    gate: w.gate,
    note: 'NOT built this run (sequenced-rounds law) — dispatch after its `after` deps merge; the task brief carries the full instructions',
  })),
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
  telemetry: { ...telemetry, tokens_by_phase: { ...telemetry.tokens_by_phase, review: SPENT.review - SPENT.build } },
  retro: review ? review.retro : null,
  telemetry_appended: review ? review.telemetry_appended : false,
}
