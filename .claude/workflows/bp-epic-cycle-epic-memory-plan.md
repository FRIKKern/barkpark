<!-- doc-tier: agent | canonical-for: epic-memory-plan | budget: 12000tok -->
# Epic Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every epic-cycle agent returns a human-readable journey; each wave Paper becomes the beautiful, telemetry-carrying durable record; a standalone `bp-epic-debrief` skill composes a premium epic debrief days later.

**Architecture:** All wave-time changes land in ONE file — `.claude/workflows/bp-epic-cycle.workflow.js` (schemas, prompts, in-script telemetry). The debrief is a new project skill at `.claude/skills/bp-epic-debrief/` (SKILL.md + a block-shape crib). Spec: `.claude/workflows/bp-epic-cycle-epic-memory-design.md` (D1–D9).

**Tech Stack:** Plain JS workflow script (classic script in a vm — no imports, no Date.now/Math.random), JSON-Schema agent contracts, bp CLI + `/v1/data/mutate`, Barkpark PortableDoc blocks.

## Global Constraints

- The workflow script runs as a CLASSIC SCRIPT in a vm: no `import`/`require`/`eval`; `Date.now()`, `Math.random()`, argless `new Date()` THROW (resume-safety). Timestamps come from agents running `date -u`.
- `export const meta` must stay a PURE LITERAL (no spreads/variables/interpolation). Schema objects in the body MAY use spreads.
- All agent schemas are `additionalProperties: false` — every new field must be added to BOTH `properties` and (when mandatory) `required`.
- Fan-out workers NEVER write the shared wave Paper (clobber law) — journeys travel via structured output; Fable phases fold them in.
- `facts[].rerun` stays OPTIONAL (charter D3: demote, never reject). Do not touch the provenance gate semantics (length in == length out).
- Telemetry honesty (design D9): record only what was measured, at measured grain. `budget.spent()` deltas are per-phase; per-agent token splits DO NOT EXIST — never present them.
- Main checkout stays on `main`. EVERYTHING goes through a worktree branch + PR — docs-only commits (design/plan/charter) included. `main` is protected: a direct push is rejected with `remote: error: GH006: Protected branch update failed for refs/heads/main.`, exit 1, even for a repo admin, and the contents API returns 409 with the same sentence (honest-gates charter D39, measured on live GitHub). The old "docs-only may land directly on main" rule is DEAD — it would hang every epic-cycle at Decide the day protection landed. The rules that survive onto the PR branch unchanged: explicit paths only, never `git add -A`, never a directory or an unexpanded glob, never `--force`, never a blind push. A docs-only PR carrying `Task: <task id>` self-satisfies the required contexts and clears the docs-only skip in ~30s.
- Syntax gate for every workflow.js edit: `bash scripts/workflow-module-smoke.sh .claude/workflows/bp-epic-cycle.workflow.js` → exit 0, prints `MODULE-SCOPE-OK <file>`. Do NOT use `node --check` (VACUOUS: exits 0 on this file with `const x = (((;` appended, because a top-level `export` plus a top-level `return` defeats Node's format sniffing) and do NOT use `node --input-type=module --check <` (FALSE RED: exits 1 on unmodified main, `Illegal return statement` at line 751, because these files legitimately top-level `return` — they run as a classic script in a vm). The smoke script strips `export` and parses the rest as an async function body, which legalises both the top-level `return` and the top-level `await`; it is mutation-proven (charter D66).

---

### Task 1: Publish the spec + plan (docs-only, on main)

**Files:**
- Commit: `.claude/workflows/bp-epic-cycle-epic-memory-design.md` (exists, untracked)
- Commit: `.claude/workflows/bp-epic-cycle-epic-memory-plan.md` (this file)

**Interfaces:**
- Produces: both docs on origin/main so every later worktree/builder can read them.

- [ ] **Step 1: Commit by explicit path onto a worktree branch, and open a docs-only PR**

Per the constraint above: `main` is protected, so a direct push is rejected with GH006 even for an admin, and the primary checkout never leaves `main`.

```bash
git -C <primary checkout> fetch origin main
git -C <primary checkout> worktree add ../bp-epic-memory-docs-wt -b docs/epic-memory-design-plan origin/main
# copy the two files in by explicit path, then inside the worktree:
git add .claude/workflows/bp-epic-cycle-epic-memory-design.md .claude/workflows/bp-epic-cycle-epic-memory-plan.md
git commit -m "docs(epic-memory): design + implementation plan for journeys, wave telemetry, premium debrief"
git push -u origin docs/epic-memory-design-plan
gh pr create --base main --head docs/epic-memory-design-plan   # body MUST carry a `Task: <task id>` line
```

Expected: the PR is open and reporting; a `.md`-only diff clears the docs-only skip in ~30s. Never `--force`, never `git add -A`, never a blind push.

---

### Task 2: Worktree branch for the code changes

- [ ] **Step 1: Create the worktree** (agents: EnterWorktree; manual fallback below)

```bash
git worktree add /Users/frikkjarl/Documents/GitHub/barkpark/.claude/worktrees/epic-memory -b feat/epic-memory-journeys-debrief origin/main
cd /Users/frikkjarl/Documents/GitHub/barkpark/.claude/worktrees/epic-memory
```

Expected: new worktree on branch `feat/epic-memory-journeys-debrief`. ALL Tasks 3–10 edit files inside this worktree.

---

### Task 3: `JOURNEY_FIELD` — schema + tripwire

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js` (worktree copy)

**Interfaces:**
- Produces: `const JOURNEY_FIELD` (shared schema object); `journey` required on STRATEGY/SURVEY/AIM/VERIFY/PLAN/BUILD/REVIEW schemas; module-scope tripwire. Tasks 4–8 rely on the exact name `JOURNEY_FIELD` and property key `journey`.

- [ ] **Step 1: Insert `JOURNEY_FIELD` after the `FACTS_DESCRIPTION` const** (anchor: the line starting `const FACTS_DESCRIPTION =`; insert after its closing line, before `const SURVEY_SCHEMA = {`):

```js
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
```

- [ ] **Step 2: Wire `journey` into all seven schemas.** For each schema, extend `required` and add the property `journey: JOURNEY_FIELD` (exact edits):

| Schema | `required` gains | property added |
|---|---|---|
| `STRATEGY_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |
| `SURVEY_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |
| `AIM_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |
| `VERIFY_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |
| `PLAN_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |
| `BUILD_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |
| `REVIEW_SCHEMA` | `'journey'` | `journey: JOURNEY_FIELD,` |

Example (SURVEY_SCHEMA):

```js
required: ['key', 'findings', 'coverage', 'facts', 'risks', 'open_questions', 'journey'],
```

and inside `properties`, after `open_questions`:

```js
    journey: JOURNEY_FIELD,
```

- [ ] **Step 3: Add the tripwire AFTER `REVIEW_SCHEMA`'s closing `}`** (mirrors the existing structural self-check philosophy — a THROW at module scope, fires before any agent is spent):

```js
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
```

- [ ] **Step 4: Verify**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c 'journey: JOURNEY_FIELD' .claude/workflows/bp-epic-cycle.workflow.js
```

Expected: `PARSE-OK`; count `7`.

- [ ] **Step 5: Commit**

```bash
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): required journey{} on every agent schema + module-scope tripwire (epic-memory D1)"
```

---

### Task 4: `JOURNEY_BLOCK` prompt contract for all agents

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js`

**Interfaces:**
- Consumes: `journey` field from Task 3.
- Produces: `const JOURNEY_BLOCK` interpolated into all seven agent prompts.

- [ ] **Step 1: Add `JOURNEY_BLOCK` after the `PAPER_BLOCK` const:**

```js
const JOURNEY_BLOCK = `YOUR JOURNEY (required — the epic's human story is assembled from these, and the debrief agent reads it days later):
Return journey{}: mission (one line), 2-5 key_moments — each a turning point or surprise WITH the evidence that caused it; a step log is not a journey — outcome, and meaning (the so-what for this wave). Write it for a human reader who was not there. Padded moments are worse than fewer moments.`
```

- [ ] **Step 2: Interpolate into every agent prompt.** Add the line `${JOURNEY_BLOCK}` immediately before the existing trailing block-stack of each prompt:

- strategist prompt: before `${PREMISE_SMOKE_BLOCK}`
- surveyor prompt: append as a new final line (after the COVERAGE ACCOUNTING paragraph)
- digest prompt: before `${PREMISE_SMOKE_BLOCK}`
- verifier prompt: append as a new final line (after COVERAGE ACCOUNTING)
- architect prompt: before `${TASKS_BLOCK}`
- builder prompt: before `${TASKS_BLOCK}`
- review prompt: before `${TASKS_BLOCK}`

- [ ] **Step 3: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c '\${JOURNEY_BLOCK}' .claude/workflows/bp-epic-cycle.workflow.js
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): JOURNEY_BLOCK prompt contract for all seven agents"
```

Expected: `PARSE-OK`; count `7`.

---

### Task 5: Search-first strategist + drift-check survey mode (D4)

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js`

**Interfaces:**
- Produces: optional `mode` + `prior_paper` on `STRATEGY_SCHEMA.survey[]` items; drift-check branch in the surveyor prompt.

- [ ] **Step 1: Extend `STRATEGY_SCHEMA.survey.items.properties`** (keep `required: ['key','question','why']` unchanged — the new fields are optional):

```js
          mode: { type: 'string', enum: ['research', 'drift-check'], description: "drift-check = a prior wave Paper already answered this; the surveyor re-runs its stored rerun commands and reports drift instead of re-deriving (epic-memory D4). Default: research." },
          prior_paper: { type: 'string', description: 'REQUIRED when mode=drift-check: the paper id that answered it' },
```

- [ ] **Step 2: Make search-first universal.** In the strategist prompt, REPLACE the `CHARTER_EXISTS` ternary's true-branch sentence ending `…where the quality bar (Kinsta/Vercel) is not yet met.` by appending to it:

```
 THEN SEARCH BEFORE ASKING (epic-memory D4): \`bp search query "<epic terms>"\` for prior wave Papers and debriefs on this topic. Any survey question a prior Paper already answered becomes a drift-check assignment (mode='drift-check', prior_paper=<id>) — verification is cheap, re-research is not.
```

The false branch (founding wave) already mandates `bp search query` — append to its end:

```
 If prior papers already answer a question you were going to ask, file it as mode='drift-check' with prior_paper set.
```

- [ ] **Step 3: Drift-check branch in the surveyor prompt.** After the line `WHY IT MATTERS: ${q.why}` add:

```js
${q.mode === 'drift-check' ? `
DRIFT-CHECK MODE (epic-memory D4): prior wave Paper ${q.prior_paper} already answered this. Read it, re-run its facts' rerun commands, and report each fact CONFIRMED or DRIFTED in your facts[] (with a fresh rerun command). Spend remaining time ONLY on the delta — what changed, what was never asked. Do not re-derive settled ground.` : ''}
```

- [ ] **Step 4: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c "drift-check" .claude/workflows/bp-epic-cycle.workflow.js
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): universal search-first + drift-check survey mode (epic-memory D4)"
```

Expected: `PARSE-OK`; grep count ≥ 5.

---

### Task 6: Fable clock stamps (D6, wall-clock leg)

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js`

**Interfaces:**
- Produces: `FABLE_STAMPS` spread; `started_at`/`ended_at` required on STRATEGY/AIM/PLAN/REVIEW schemas; consumed by Task 8's telemetry object.

- [ ] **Step 1: Add after `JOURNEY_FIELD`:**

```js
// Wall-clock telemetry (design D6). The script cannot call Date.now() (banned
// for resume-safety), so the Fable phases carry the clock: fleets are
// bracketed by Fable checkpoints, so phase boundaries are these stamps.
const FABLE_STAMPS = {
  started_at: { type: 'string', description: 'output of `date -u +%FT%TZ`, run as your FIRST command (wall-clock telemetry, epic-memory D6)' },
  ended_at: { type: 'string', description: 'output of `date -u +%FT%TZ`, run as your LAST command before returning' },
}
```

- [ ] **Step 2: Wire into the four Fable schemas** — `STRATEGY_SCHEMA`, `AIM_SCHEMA`, `PLAN_SCHEMA`, `REVIEW_SCHEMA` each gain in `required`: `'started_at', 'ended_at'` and in `properties`: `...FABLE_STAMPS,`

- [ ] **Step 3: Prompt line.** Add to each of the four Fable prompts (strategist, digest, architect, review), directly above the `${JOURNEY_BLOCK}` line added in Task 4:

```
CLOCK STAMPS (telemetry, epic-memory D6): run `date -u +%FT%TZ` as your first command → started_at; run it again as your very last → ended_at.
```

- [ ] **Step 4: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c '\.\.\.FABLE_STAMPS' .claude/workflows/bp-epic-cycle.workflow.js   # expect 4
grep -c 'CLOCK STAMPS' .claude/workflows/bp-epic-cycle.workflow.js          # expect 4
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): Fable clock stamps started_at/ended_at (epic-memory D6)"
```

---

### Task 7: Beauty contract + journey rosters in the Paper (D2)

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js`

- [ ] **Step 1: Extend `PAPER_BLOCK`.** Append two bullets before the final `- Link both ways:` bullet:

```
- BEAUTIFUL BY CONTRACT (epic-memory D2): compose with real components, never walls of paragraphs — eyebrow/byline/ingress open the Paper; stat-grid for headline numbers; journey CARDS per agent (cards block: mission → what they figured out → what it means); decisions as callout blocks; proofs as code blocks quoting REAL output; load-bearing facts as a table WITH their rerun commands; diagram (mermaid) where flow beats prose; divider between phase sections. Block-shape crib: .claude/skills/bp-epic-debrief/helpers/blocks.md.
- CURATE, DON'T DUMP: keep turning points, surprises, refuted premises, real output; drop boilerplate. The Paper is the ONLY durable carrier of the wave's story (no dossiers, no per-agent papers — D3): what you leave out is gone.
```

- [ ] **Step 2: Digest journey roster.** In the digest prompt's step 3 (`UPDATE THE WAVE PAPER`), after the `- Survey digest:` bullet add:

```
   - JOURNEY ROSTER (epic-memory D2): one card per surveyor (cards block) — mission → what they figured out → what it means — distilled from each report's journey{}; keep the turning points and surprises, drop boilerplate. A reader must be able to follow every scout's arc without the raw reports.
```

- [ ] **Step 3: Decide proof + facts rendering.** In the architect prompt's step 7, extend the `- Verification results:` bullet with `— render proofs as code blocks quoting the decisive output lines, and the verifiers' journeys as cards`, and add a bullet:

```
   - FACTS TABLE (epic-memory D4): the load-bearing facts with their rerun commands (table block) — the next wave's strategist turns these into drift-checks instead of re-research.
```

- [ ] **Step 4: Review journey fold.** In the review prompt's step 9 (`CLOSE THE WAVE PAPER`), after `Report the Paper id in paper_closed.` append:

```
The debrief section MUST carry builder journey cards (from every builder's journey{}, including not-green slices — a stall is a story), your own journey, and the telemetry + retro sections (see WAVE TELEMETRY below).
```

- [ ] **Step 5: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c 'JOURNEY ROSTER\|BEAUTIFUL BY CONTRACT\|FACTS TABLE' .claude/workflows/bp-epic-cycle.workflow.js   # expect 3
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): Paper beauty contract + journey rosters + facts table (epic-memory D2/D4)"
```

---

### Task 8: In-script telemetry + Review retro (D6/D7)

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js`

**Interfaces:**
- Consumes: `FABLE_STAMPS` values (Task 6), fleet arrays already in scope.
- Produces: `SPENT` samples, `telemetry` object interpolated into the Review prompt and returned; `REVIEW_SCHEMA.retro` + `telemetry_appended`.

- [ ] **Step 1: Sample `budget.spent()` at every phase boundary.** Insert these single lines (exact anchors):

| After (anchor line) | Insert |
|---|---|
| `const LEAD_NOTES = …` (end of arg parsing) | `const SPENT = { t0: budget.spent() }` |
| `const WAVE_PAPER = strategist.paper_id` | `SPENT.strategize = budget.spent()` |
| the `log(...surveyors reported...)` line | `SPENT.survey = budget.spent()` |
| the `log('Digest done...')` line | `SPENT.digest = budget.spent()` |
| the `log(...verifiers reported...)` line | `SPENT.verify = budget.spent()` |
| the `log('Architect cut...')` line | `SPENT.decide = budget.spent()` |
| the `log('Build: ...slices green')` line | `SPENT.build = budget.spent()` |

- [ ] **Step 2: Assemble `telemetry` before the Review phase** (insert directly above `phase('Review')`):

```js
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
    gates_failed: built.length - greenBuilt.length,
    facts_demoted_no_rerun: surveyGrip.demoted + verifyGrip.demoted,
  },
}
```

- [ ] **Step 3: Extend `REVIEW_SCHEMA`.** `required` gains `'retro', 'telemetry_appended'`; `properties` gains:

```js
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
```

- [ ] **Step 4: Feed telemetry to Review.** In the review prompt, after the `DEFERRED SLICES` paragraph, insert:

```
WAVE TELEMETRY (measured in-script — persist it in the Paper debrief as a stat-grid headline + a per-phase table; the debrief agent runs DAYS later when this run's files are gone; honesty rule D9 — measured grain only, never per-agent token splits):
${JSON.stringify(telemetry, null, 2)}
```

And in the wave-level numbered steps add after step 9's text (extended in Task 7): `Include the RETRO: one verdict per phase in retro[], mirrored into the Paper's debrief section.`

- [ ] **Step 5: Return value.** Add after the review agent resolves: `SPENT.review = budget.spent()`. In the final `return {`, add:

```js
  telemetry: { ...telemetry, tokens_by_phase: { ...telemetry.tokens_by_phase, review: SPENT.review - SPENT.build } },
  retro: review ? review.retro : null,
  telemetry_appended: review ? review.telemetry_appended : false,
```

- [ ] **Step 6: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c 'budget.spent()' .claude/workflows/bp-epic-cycle.workflow.js   # expect 8 (t0 + 6 phase samples + review)
grep -c 'WAVE TELEMETRY' .claude/workflows/bp-epic-cycle.workflow.js   # expect 1
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): per-phase token/clock/interrupt telemetry + Review retro (epic-memory D6/D7)"
```

---

### Task 9: Decide doc-fact routing (D5)

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js`

- [ ] **Step 1: `PLAN_SCHEMA`.** `required` gains `'doc_facts_routed'`; `properties` gains:

```js
    doc_facts_routed: { type: 'string', description: 'durable repo-facts routed into their owning docs/ card this wave (path + one-line what, per fact), or "none — <why>". Facts that deserved docs but missed the byte budget were filed as backlog tasks instead — name them.' },
```

- [ ] **Step 2: Architect prompt step.** After step 2's ledger-rows paragraph (`…touch nothing else under tooling/grip/.`), insert:

```
2b. ROUTE DURABLE REPO-FACTS INTO DOCS (epic-memory D5): from this wave's verified facts, the FEW that are durable repo-truths (not wave-local findings) go into their OWNING docs/ card per the CLAUDE.md routing table — corrections and gap-fills only, never additive research dumps; byte budgets and the 7-card cap are sovereign. Gate before committing: bash scripts/check-doc-budgets.sh && bash scripts/docs-anchors-check.sh. Commit rides the charter commit (explicit paths). A fact that deserves docs but misses budget becomes a published backlog task instead. Record everything in doc_facts_routed.
```

- [ ] **Step 3: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c 'doc_facts_routed' .claude/workflows/bp-epic-cycle.workflow.js   # expect 3 (required + property + prompt)
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "feat(epic-cycle): Decide routes durable repo-facts into owning docs card (epic-memory D5)"
```

---

### Task 10: `meta.phases` detail refresh

**Files:**
- Modify: `.claude/workflows/bp-epic-cycle.workflow.js` (meta block — pure literal, no interpolation)

- [ ] **Step 1:** Update three `detail` strings in `meta.phases` (literal text edits):
- Strategize: append `, searches prior wave Papers first (answered questions become drift-checks)` before the closing quote.
- Digest: append `; folds a journey card per surveyor into the Paper`.
- Review: append `; persists wave telemetry (tokens/clock/interrupts) + a per-phase efficiency retro in the Paper debrief`.

- [ ] **Step 2: Verify + commit**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
git add .claude/workflows/bp-epic-cycle.workflow.js
git commit -m "docs(epic-cycle): meta.phases reflects journeys, drift-checks, telemetry retro"
```

---

### Task 11: `bp-epic-debrief` skill

**Files:**
- Create: `.claude/skills/bp-epic-debrief/SKILL.md`
- Create: `.claude/skills/bp-epic-debrief/helpers/blocks.md`

**Interfaces:**
- Consumes: wave Papers (journey cards, telemetry, retro sections), epic charter, bp ledger, git history.
- Produces: one published premium debrief Paper; optional process-improvement backlog tasks.

- [ ] **Step 1: Write `SKILL.md`:**

```markdown
---
name: bp-epic-debrief
description: Compose a full Barkpark epic into ONE premium, human-first debrief Paper — narrative arc, per-wave journey highlights, cross-wave telemetry trends, and a process retro with teeth. Invoke when the user says "debrief epic <id>", "epic debrief", "write the epic story", or names an epic task to debrief. Runs days or weeks after the waves; reads only durable stores (Papers, ledger, charter, git). Part of the epic-memory design (.claude/workflows/bp-epic-cycle-epic-memory-design.md).
---

# Epic Debrief — an author with taste, not a report generator

You are composing the story of a whole epic for a human who wants fast, premium insight. One Fable-grade author pass; reviewer discipline folded in (re-read the rendered Paper before publishing, fix what reads badly).

## Inputs

`<epic-task-id>` (required — ask if missing). Everything else is derived:

1. `bp task show <epic-task-id>` — children (slices, backlog), `wave_status`, `wave_paper` pointers.
2. The epic charter named by the task or its Papers (`.claude/workflows/<epic>-charter.md`): Vision, Decisions, Roadmap, Wave log.
3. Every wave Paper: follow `wave_paper` fields + `bp search query "<epic> wave"` — these carry journey cards, decisions, proofs, facts tables, telemetry + retro sections.
4. `git log --oneline` + merged PRs touching the epic's surfaces (task ids in PR bodies: `Task: <id>`).

DURABLE STORES ONLY — session files from wave runs are gone; never claim data that is not in a Paper, the ledger, the charter, or git (design D1). If a wave predates telemetry, SAY SO in the Paper — never backfill numbers (honesty rule D9).

## Compose (block crib: helpers/blocks.md — exact JSON shapes)

One Paper, slug `<epic>-debrief-<YYYY-MM-DD>`, style=article MANDATORY, published via one atomic `/v1/data/mutate` batch (create + publish), registered tags only (`bp tag browse`).

Structure the story, component per job:
- eyebrow · heading · byline · ingress — the epic in one breath.
- stat-grid — headline numbers: waves, slices shipped/deferred, PRs merged, total tokens, wall-clock span, interrupts.
- steps or pipeline — the epic's arc wave by wave: ambition → obstacles → turning points → what stands.
- Per wave: heading + a journey-highlight cards block (the 2-4 BEST moments across that wave's agents — surprises and refuted premises beat routine wins) + callouts for the decisions that shaped what followed.
- table — shipped vs deferred vs stalled, with task ids and PR links.
- chart — cross-wave trends from the telemetry sections (tokens per phase per wave; did Decide get cheaper as the charter matured?). Only measured data; state grain.
- THE RETRO WITH TEETH: table of per-phase verdicts across waves, then cards with your top-3 process changes — each argued from telemetry rows or journey moments. Offer to file each as a published bp backlog task under the epic (ask first).
- pullquote for the epic's one-line lesson; expandable for source anchors (papers, tasks, PRs read).

## Seal

1. Read the published Paper back top-to-bottom; fix anything that reads as a dump.
2. Stamp the epic task: flat `epic_debrief=<paper-id>` via patch + re-publish.
3. Reply with the Paper URL and a 3-line summary.
```

- [ ] **Step 2: Write `helpers/blocks.md`** — the block-shape crib, verified 2026-07-24 against production papers on guerrilla + `api/lib/barkpark/portable_doc/render/`. Content: one JSON example per block type, copied verbatim from this session's extraction:

```markdown
# PortableDoc block shapes (verified 2026-07-24 against live papers)

Every block: unique string `id`. Rich text spans: `{"type":"text","value":"…"}` (+ optional `"marks":[{"type":"bold"}]`).

- eyebrow `{"type":"eyebrow","text":"EPIC · DEBRIEF"}`
- heading `{"type":"heading","level":1,"text":"…"}` (levels 1-3)
- byline `{"type":"byline","items":["…","…"]}`
- ingress `{"type":"ingress","text":"…"}` — the standfirst under the title
- paragraph `{"type":"paragraph","content":[<spans>]}`
- callout `{"type":"callout","content":[<spans>]}`
- pullquote `{"type":"pullquote","text":"…"}`
- divider `{"type":"divider"}`
- list `{"type":"list","items":[[<spans>],[<spans>]]}` — items = array of span-arrays
- table `{"type":"table","head":["…"],"rows":[["…","…"]]}` — plain strings in cells
- stat-grid `{"type":"stat-grid","items":[{"label":"…","value":"…"}]}` (compact); stats = same shape, larger
- gauge-list `{"type":"gauge-list","title":"…","max":75,"mode":"share","rows":[{"label":"…","value":60,"note":"…"}]}`
- cards `{"type":"cards","items":[{"title":"…","text":"…","tone":"ok"}]}` — tone optional
- steps `{"type":"steps","steps":[{"title":"…","blocks":[<blocks>]}]}`
- pipeline `{"type":"pipeline","nodes":[{"title":"…","detail":"…","kind":"source|emit|gate","source":true?}]}`
- tabs `{"type":"tabs","tabs":[{"label":"…","blocks":[<blocks>]}]}`
- expandable `{"type":"expandable","summary":"…","children":[<blocks>]}`
- diagram `{"type":"diagram","source":"flowchart TD\n  A --> B","caption":"…"}` — mermaid
- toc `{"type":"toc","items":[{"anchor":"…","level":1,"text":"…"}]}`
- code `{"type":"code",…}` / terminal — quote REAL output only

Publish: POST `<server>/w/default/p/default/v1/data/mutate/production` with
`{"mutations":[{"createOrReplace":{"_type":"paper","_id":"<slug>","title":"…","style":"article","description":"…","main_tag":"<registered>","tags":[{"tag":"…","strength":95,"rationale":"…"}],"blocks":[…]}},{"publish":{"id":"<slug>","type":"paper"}}]}`
— style=article is MANDATORY; tags must exist in `bp tag browse` (else 422 unknown_tag); strengths DISTINCT, max = main_tag. Verify: `bp doc get paper <slug>` shows `_draft:false`; GET `/papers/<slug>` returns 200.
```

- [ ] **Step 3: Verify + commit**

```bash
test -f .claude/skills/bp-epic-debrief/SKILL.md && test -f .claude/skills/bp-epic-debrief/helpers/blocks.md && echo FILES-OK
git add .claude/skills/bp-epic-debrief/
git commit -m "feat(skills): bp-epic-debrief — premium epic debrief author (epic-memory D8)"
```

---

### Task 12: Ship — full review, push, PR

- [ ] **Step 1: Whole-file sanity on the final state**

```bash
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js && echo PARSE-OK
grep -c 'journey: JOURNEY_FIELD' .claude/workflows/bp-epic-cycle.workflow.js   # 7
grep -c '\.\.\.FABLE_STAMPS' .claude/workflows/bp-epic-cycle.workflow.js       # 4
grep -c 'budget.spent()' .claude/workflows/bp-epic-cycle.workflow.js           # 8
```

- [ ] **Step 2: Re-read the full diff** (`git diff origin/main`) against the spec's D1–D9 — every decision must map to a hunk; every hunk to a decision.

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feat/epic-memory-journeys-debrief
gh pr create --head feat/epic-memory-journeys-debrief \
  --title "feat(epic-cycle): epic memory — journeys, wave telemetry, drift-checks, premium debrief skill" \
  --body "Implements .claude/workflows/bp-epic-cycle-epic-memory-design.md (D1-D9): required journey{} on all seven agent schemas + tripwire; Paper beauty contract with journey rosters; universal search-first + drift-check survey mode; per-phase token/clock/interrupt telemetry persisted by Review with a per-phase retro; Decide doc-fact routing; new bp-epic-debrief skill. Gates: node --input-type=module --check + grep contract counts (in plan).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 4: After merge (lead):** remove the worktree (`git worktree remove .claude/worktrees/epic-memory`), `make update` in the main checkout, and dry-run one wave of a small epic to watch the new contract live — the first real wave Paper with journey cards + telemetry is the acceptance test.
