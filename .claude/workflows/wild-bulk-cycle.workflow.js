export const meta = {
  name: 'wild-bulk-cycle',
  description: 'Wild bulk development cycle: 1 Fable plans 3 codebase domains → 3 Opus leads fan out 10-20 Opus surveyors each → 1 Fable digests → 3 Opus task-cutters file 10-60 bp tasks → Opus preflight per task → 1 Fable HARMONIZES the whole roster (blast-radius + collision control) → 1 Opus builder per task → 3 Opus domain reviewers → polish Opus passes ONLY where needed → 1 Fable grades the whole cycle.',
  whenToUse:
    'A bulk sweep-and-fix across the codebase — wider and wilder than bp-epic-cycle (10-60 tasks, Opus builders), so it spends MORE on mid-planning: every task is preflighted against reality and one Fable harmonizes the full roster before any builder flies. INVOKE: Workflow({scriptPath: ".claude/workflows/wild-bulk-cycle.workflow.js", args: {wish: "<the user\'s request, verbatim — REQUIRED>", epic_task_id: "<task-… slug if the parent exists>", charter_path: "<optional charter to respect>", lead_notes: "<optional>"}}). Launch via scriptPath, not name (the name registry is a session-start snapshot).',
  // EXACTLY the phase() titles the body announces, in call order. A title declared
  // here but never announced leaves a phantom progress group open for the whole run,
  // so the fan-out stages that ride inside these six (Recon/Survey, Build,
  // Review/Polish) are described in their host phase's detail instead of claiming a
  // group of their own.
  phases: [
    { title: 'Plan', detail: '1 Fable (high): partition the codebase into exactly 3 blast-radius-aware domains, open the cycle Paper, ensure the epic parent task — then 3 Opus recon leads design 10-20 probes each and 30-60 Opus surveyors sweep them read-only', model: 'fable' },
    { title: 'Digest', detail: '1 Fable (high): synthesize ALL survey reports, dedup cross-domain, cut 3 finding bundles, fold into the Paper', model: 'fable' },
    { title: 'Cut', detail: '3 Opus task-cutters: 4-20 published rubric-quality bp tasks each — 10-60 total', model: 'opus' },
    { title: 'Preflight', detail: '1 Opus (low effort) per task: verify the brief against reality — files exist, evidence still true, gate runnable', model: 'opus' },
    { title: 'Harmonize', detail: '1 Fable (high): the blast-radius gate — holds ALL tasks + script-computed overlap matrix + preflight reports; merges/patches/defers until the roster is disjoint and coherent — then 1 worktree-isolated Opus builder per rostered task, 3 Opus domain reviewers, and 0-60 Opus polishers where a reviewer names a gap', model: 'fable' },
    { title: 'Verdict', detail: '1 Fable (high): whole-cycle review — ledger audit, merge-ready list, Cody grade, close the Paper', model: 'fable' },
  ],
}

// args = { wish, epic_task_id?, charter_path?, lead_notes?, builder_model?, survey_model?, lead_model?, cutter_model?, reviewer_model? }
// Model doctrine (lead mandate): Fable holds ONLY the four critical-thinking
// joints — Plan, Digest, Harmonize, Verdict — at high effort. Opus takes
// the well-scoped design/judge seats (recon leads, task-cutters, domain
// reviewers). Opus is the fleet too (survey, preflight, build, polish) — never Sonnet or Haiku (operator model policy 2026-08-31).
// Same defensive parse as bp-epic-cycle: args can arrive as a JSON STRING.
const A = (() => {
  if (typeof args === 'string') { try { return JSON.parse(args) } catch (e) { throw new Error('wild-bulk-cycle args is a non-JSON string') } }
  return args || {}
})()
if (!A.wish) throw new Error('wild-bulk-cycle requires an explicit args.wish')
const WISH = A.wish
const EPIC_TASK_ID = A.epic_task_id || null
const CHARTER_PATH = A.charter_path || null
const BUILD_MODEL = A.builder_model || 'opus'
const SURVEY_MODEL = A.survey_model || 'opus'
const LEAD_MODEL = A.lead_model || 'opus'
const CUTTER_MODEL = A.cutter_model || 'opus'
const REVIEWER_MODEL = A.reviewer_model || 'opus'
// FABLE OUTAGE SWITCH (mirrors bp-epic-cycle). When Fable is unreachable (spend
// limit, retention tier, refusal class), every fable-selecting site must dispatch
// Opus INSTEAD — not merely fall back to it after burning attempts. Identity by
// default, so passing nothing changes nothing. The four joints below are the only
// fable sites; the fleet models are already args-overridable.
const NO_FABLE = A.no_fable === true
const M = (m) => (NO_FABLE && m === 'fable' ? 'opus' : m)
// TWO SETTINGS ONLY, cycle-wide: fable@high for the thinking joints, opus at
// their own depth for everything else. Nothing above 'high', and no 'max', anywhere
// — a joint that wants more depth gets a better brief, not a bigger effort knob.
// Fan-out FLOORS. Every maxItems below is an upper bound; nothing but a floor stops
// a thinking phase from returning one item, or zero. The ratified anti-goal — a
// cycle must never spend FEWER agents to look decisive — was prose, and prose does
// not run.
//
// These are THROWS even though all four sites ALSO declare minItems. That is not
// because minItems is unenforced — it IS enforced — but because it does not do the
// job a floor needs. Settled by reading the host (2.1.215), not by running a wave:
// the host compiles the workflow-supplied schema with Ajv and runs it inside the
// StructuredOutput tool call, so a short array IS caught. But (1) it is caught in
// the SUBAGENT's turn and handed back as a retryable tool error — pressure on one
// agent, never a decision the orchestrator gets to make; (2) minItems is not in the
// host's strict-schema keyword allowlist, so carrying it disqualifies the schema
// from strict structured-output mode entirely; and (3) when the retries run out the
// workflow reports "subagent completed without calling StructuredOutput", naming
// the wrong cause. A floor that reports the wrong reason is worse than none.
//
// PLACEMENT IS LOAD-BEARING. The host runs pipeline()/parallel() stages under
// Promise.allSettled: a throw INSIDE a stage is swallowed into a logged `null`, not
// a cycle abort. So the per-domain probe floor below is deliberately paired — it
// throws in-stage to stop THAT domain from spending its scouts, and a second
// top-level check turns the resulting dropped domain into a real abort before the
// next phase spends anything.
//
// HONESTY, per charter D28: these throws have never fired in a real run, and
// neither have bp-epic-cycle's. They were proven under a node:vm harness that
// reproduces the host evaluator, over n = 0, 1, floor-1, floor, floor+1. A harness
// is not a wave; nothing here has been observed firing in the loop.
// Count a fan-out array. A non-array truthy value (a model returning a bare
// string where an array was declared) has a `.length` too — "abc".length is 3,
// which SATISFIES a floor of 3 and then faults on the .map() two lines later
// with an error naming neither the floor nor the cause. A floor whose whole job
// is to fail informatively must not be the thing that fails obscurely.
const fanout = (v) => (Array.isArray(v) ? v.length : -1)
const DOMAIN_FLOOR = 3
const PROBE_FLOOR = 10
const BUNDLE_FLOOR = 3
const CUT_TASK_FLOOR = 4
const LEAD_NOTES = A.lead_notes ? `\n\nLEAD NOTES THIS CYCLE:\n${A.lead_notes}` : ''
const CHARTER_LINE = CHARTER_PATH ? `An epic charter exists at ${CHARTER_PATH} — read it; its decisions bind this cycle.` : ''

const USER_WISH_BLOCK = `THE USER'S WISH (this is the focus — everything serves it, judged holistically, not as a checklist):
"""
${WISH}
"""`

const GATES_BLOCK = `Local gates available (every task must name at least one that proves it):
- Cloud SPA: node --check cloud/priv/static/app.js AND node cloud/priv/static/__app.test.mjs (node:vm harness over __bpTestHook — extend it for new pure helpers)
- Go CLI: go build ./... && go vet ./internal/cli/... && go test ./internal/cli/...
- Elixir control plane: targeted unit tests only (mix test <file>), no DB/boot, never prod compile
  (CC=clang is HOST-CONDITIONAL, not part of the gate: prefix it only where \`cc\` is shadowed by a
   wrapper — check with \`type cc\`; on a clean host the bare command is the gate you quote.)
- JS SDK: pnpm --filter <pkg> build/typecheck/test (+ js/.changeset/ entry for any public API change)`

const TASKS_BLOCK = `THE BP TASK CONTRACT (the ledger is the spine — every phase reads and writes it):
- Tasks are type:task documents in Barkpark, driven via the bp CLI. Try \`bp task create\` first; if this binary lacks the verb, the fallback is:
    bp doc create task --yes --set _id=<slug> --set title="..." --set kind=task --set lifecycle_status=open --set 'priority:=1' --set parent_id=<epic-task-slug> --set description="..." --set 'tags:=[{"tag":"docs","strength":80,"rationale":"..."},{"tag":"search","strength":40,"rationale":"..."}]' --set 'acceptance_criteria:=[{"criterion":"...","met":false,"evidence":""}]'
    bp doc publish task <slug> --yes        # tasks MUST be published — gates and boards read the published ledger only. tags are weighted [{tag,strength 1–100,rationale}] with DISTINCT strengths (max = main tag); each tag MUST be a registered tag doc (bp doc ls tag) or publish 422s unknown_tag
- Fields are FLAT top-level in content. priority 0=highest..4. parent_id is a slug. Typed values use key:=json.
- Acceptance criteria to the authoring rubric: concrete, evidence-bearing, one per real proof obligation — {criterion, met, evidence}.
- Claim BEFORE working: \`bp task claim <task-id> <worker>\` — the claim epoch is at doc.claim.epoch in the JSON response.
- Stamp each criterion the MOMENT it is proven (mid-claim, never batched): \`bp task stamp <task-id> <worker> <epoch> --criterion N --criterion-text "<the criterion's exact stored wording>" --met --evidence "…"\` — \`--met\` REQUIRES non-empty \`--evidence\` AND \`--criterion-text\` (the row's wording, copied verbatim from acceptance_criteria[N].criterion). \`--criterion N\` is 0-BASED — the FIRST criterion is 0; an unguarded met-flip is REJECTED (409 criterion_text_required / 409 criteria_mismatch). \`--miss --note "…"\` records an honest attempt WITHOUT flipping the lock and needs no text.
- Builders do NOT close merge-gated criteria ("PR merged") — the LEAD closes those on merge. A builder whose work is done but unmerged leaves lifecycle in_progress with evidence stamped.
- Never TodoWrite, never markdown TODO lists. Work without a published, claimable bp task does not exist.`

const PAPER_BLOCK = `THE CYCLE PAPER (the cycle's living story — one Barkpark Paper, opened at Plan, closed at Verdict):
- style=article is MANDATORY. bp doc create ignores stdin — write/extend the body via the HTTP /v1/data/mutate path (patch merges into content), then bp doc publish; \`bp capabilities -o json\` shows the verbs.
- ONLY the single-Fable phases (Plan, Digest, Harmonize, Verdict) write the Paper; multi-agent phases and every fan-out worker NEVER write it (concurrent patches clobber each other) — they write their OWN bp tasks, and the next single-Fable phase folds their reports in.
- Link both ways: the Paper's id lives on the epic task (flat wave_paper field) and on every cycle task; the Paper names the task ids it drives.
- WALL DIALECT (what the publish wall ENFORCES — the cycle Paper carries tag epic-cycle-wave-paper and is gated by api/lib/barkpark/content/papers/epic_quality.ex on origin/main):
  - NEVER author an empty paragraph block anywhere — hard failure :empty_paragraph_spacer, checked over the NESTED block tree.
  - Opening, within the first 8 meaningful blocks: exactly one h1 in the whole document, one \`ingress\` block, and one orientation block of byline|stats|toc|list|steps. No heading-level jumps.
  - Ceilings: 80 top-level blocks, 16 top-level headings, 5000 primary words (closed expandables excluded). Tables carry \`head\`.
  - A refused publish answers 422 code=invalid_epic_paper_quality with details.failures naming every failed gate — fix and re-publish (the bp CLI renders details).
  - The spacer-doctrine ruling is owned by open task cchi-w67-bl-the-epic-paper-floor-forbids-the-spacing-doctrine (cch-instruments-epic): teach the ENFORCED dialect and cite that task; do NOT edit the wall.`

const LIVENESS_BLOCK = `LEDGER LIVENESS (the board must read like a LIVE system, never an afterthought):
- Stamp state changes the MOMENT they happen — claim when you start, evidence the second a criterion is proven, a note the second you deviate or stall. Never batch honesty to the end of your run.
- Your CLAIMED task carries a claim-scoped now-line — pulse it so every board moves while you work: \`bp task pulse <task-id> <worker> --now "…" [--criterion N]\` (no epoch arg). Pulse right after you claim and at each phase boundary.
- Patches to tasks go through /v1/data/mutate semantics: fields FLAT, patch merges into content, re-publish after mutating (boards read the published ledger only).`

const COVERAGE_ITEMS = {
  type: 'object', additionalProperties: false,
  required: ['path', 'checked_for', 'result', 'note'],
  properties: {
    path: { type: 'string', description: 'file (or bp paper/task id) you actually opened or grepped' },
    checked_for: { type: 'string', description: 'what you were looking for in it' },
    result: { type: 'string', enum: ['found', 'not_found', 'partial'], description: 'found = it was there; not_found = you looked and it is NOT there (that is a finding!); partial = some of it / ran out of time' },
    note: { type: 'string', description: 'the one-line takeaway; empty string if nothing beyond result' },
  },
}

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['direction', 'paper_id', 'paper_created', 'epic_task_id', 'domains'],
  properties: {
    direction: { type: 'string', description: 'the cycle\'s strategic direction: what a successful bulk cycle leaves behind, what kind of defects/debt/polish it hunts, what it must NOT touch' },
    paper_id: { type: 'string', description: 'slug of the PUBLISHED cycle Paper you created (style=article)' },
    paper_created: { type: 'boolean', description: 'true only after you created AND published the Paper and read it back from the server' },
    epic_task_id: { type: 'string', description: 'slug of the PUBLISHED epic parent task for this cycle (verified pre-existing, or created by you)' },
    domains: {
      type: 'array', minItems: 3, maxItems: 3,
      description: 'EXACTLY 3 domains partitioning the codebase for this cycle — disjoint scopes, no file owned twice',
      items: {
        type: 'object', additionalProperties: false,
        required: ['name', 'slug', 'scope_paths', 'mission', 'hazards'],
        properties: {
          name: { type: 'string' },
          slug: { type: 'string', description: 'short kebab-case label, used in branch names and worker ids' },
          scope_paths: { type: 'array', items: { type: 'string' }, description: 'repo-relative path prefixes this domain OWNS this cycle — disjoint from the other two' },
          mission: { type: 'string', description: 'what the domain lead should hunt for here, complete enough to brief a cold agent' },
          hazards: { type: 'string', description: 'what in this domain is fragile/forbidden (hot concurrent-dev areas, prod-coupled code, known traps) — the blast-radius map every downstream phase inherits' },
        },
      },
    },
  },
}

const RECON_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['domain', 'survey'],
  properties: {
    domain: { type: 'string' },
    survey: {
      type: 'array', minItems: 10, maxItems: 20,
      description: '10-20 survey probes; each becomes one Opus surveyor. Cast a WIDE net over YOUR domain only',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'question', 'why'],
        properties: {
          key: { type: 'string', description: 'short kebab-case label, unique within the domain' },
          question: { type: 'string', description: 'a concrete, answerable question about the domain — name suspected files, defect classes to hunt, seams to map' },
          why: { type: 'string', description: 'how the answer changes what gets fixed' },
        },
      },
    },
  },
}

// Kept in lockstep with FACT_ITEMS / FACTS_DESCRIPTION in bp-epic-cycle.workflow.js
// — the two cycles share this schema shape, so a change to one belongs in both.
// `rerun` carries the command that re-derives the fact, ON the fact itself.
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

const FACTS_DESCRIPTION = 'load-bearing facts you actually verified, never assumed. Evidence takes several forms, and the strongest are cheap: `git show origin/main:<path>` reads what is really on main (not your worktree, which may be ahead, behind, or dirty), and a curl against a running host reads what is really deployed — both are fast enough to be the default, not a luxury (measured here: `git show` 34-54ms; a localhost curl 96-172ms warm, ~925ms cold). A worktree file:line is a perfectly good form too, but it is a claim about YOUR checkout and nothing more — do not quote it as a claim about main or about prod. Whichever form you used, put the command that re-derives it in that fact\'s rerun field.'

const SURVEY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'coverage', 'facts', 'fix_candidates', 'open_questions'],
  properties: {
    key: { type: 'string' },
    findings: { type: 'string', description: 'the answer, honestly — including "the premise is wrong" when it is' },
    coverage: { type: 'array', description: 'EVERY file/paper/task you checked. Not-found is evidence too; unlisted = unchecked', items: COVERAGE_ITEMS },
    facts: {
      type: 'array', description: FACTS_DESCRIPTION,
      items: FACT_ITEMS,
    },
    fix_candidates: {
      type: 'array', description: 'concrete fixable defects/debt/polish you found — the raw ore the task-cutters mine',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'files', 'evidence', 'suggested_fix', 'severity'],
        properties: {
          title: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          evidence: { type: 'string', description: 'file:line + what is wrong, verified by reading' },
          suggested_fix: { type: 'string' },
          severity: { type: 'string', enum: ['bug', 'debt', 'polish'], description: 'bug = wrong behavior; debt = correct but rotting; polish = quality below the Kinsta/Vercel bar' },
        },
      },
    },
    open_questions: { type: 'array', items: { type: 'string' } },
  },
}

// STRUCTURAL SELF-CHECK — mirrors the one in bp-epic-cycle.workflow.js, and for
// the same reason: `node --check` proves this file PARSES, not that its schemas
// are intact. A misplaced brace once moved a key out of a schema's properties
// while every gate stayed green. This throws at module scope, before any agent
// is spent, so the failure is legible and free.
for (const key of SURVEY_SCHEMA.required || []) {
  if (!Object.prototype.hasOwnProperty.call(SURVEY_SCHEMA.properties || {}, key)) {
    throw new Error(`SURVEY_SCHEMA declares required key '${key}' but does not define it in properties — a brace or edit moved it out of the schema. Fix the schema; do not proceed.`)
  }
}
if (!SURVEY_SCHEMA.properties?.facts?.items?.properties?.rerun) {
  throw new Error('SURVEY_SCHEMA.facts[].rerun is missing — the fact-level provenance carrier was dropped, and the two cycles have drifted.')
}
if ((SURVEY_SCHEMA.properties.facts.items.required || []).includes('rerun')) {
  throw new Error('SURVEY_SCHEMA.facts[].rerun must stay OPTIONAL (charter D3: a missing command DEMOTES to L6, it never rejects).')
}

// THE FACT-PROVENANCE GATE — ported from bp-epic-cycle.workflow.js, semantics
// unchanged. The schema check above only proves the CARRIER exists; it says
// nothing about whether a returned fact filled it. Without this, a fact with no
// rerun command — an unverified belief at the level of agent memory — is
// serialised into the Digest prompt indistinguishable from a measured one, and
// the Fable downstream of that prompt cuts up to 60 tasks on it.
//
// DEMOTE, NEVER REJECT (charter D3): a missing command lowers the fact's
// authority level, it does not throw the fact away — the cheapest fix is for
// the reader to add a one-line command, and a rejected fact never gets read.
//
// The reports are mutated IN PLACE, at the single barrier where the survey
// resolves. That is deliberate: gating each JSON.stringify site separately is
// the copies-that-must-agree defect in miniature, and the next serialisation
// someone adds would silently be the ungated one.
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

// Renders the gate's COUNT into the prompt of the phase that receives the facts,
// so the reader sees how much of its own input was demoted rather than having to
// notice the per-fact markers. Zero renders as an explicit all-clear, never as
// nothing: a gate that is silent when clean is indistinguishable from a gate
// that was deleted, and one that shouts when clean gets tuned out.
function gripBlock(grip) {
  if (!grip.total) return '\nFACT PROVENANCE GATE: no facts were returned at all — that is itself a signal about this sweep, not a clean bill of health.'
  if (!grip.demoted) return `\nFACT PROVENANCE GATE: 0/${grip.total} fact(s) demoted — every fact below carries a rerun command that re-derives it.`
  return `\n⚠ FACT PROVENANCE GATE: ${grip.demoted}/${grip.total} fact(s) are marked \`provenance: "DEMOTED-NO-RERUN"\`. Those facts carry NO command that re-derives them: treat each as an unverified belief at the level of agent memory, never as a settled measurement, and do not cut a task on one without first giving it a rerun command. The other ${grip.total - grip.demoted} are re-derivable as claimed.`
}

const DIGEST_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['synthesis', 'paper_updated', 'bundles', 'dropped'],
  properties: {
    synthesis: { type: 'string', description: 'what the sweep established across all 3 domains, the defect themes, where reports contradict, what got deduped' },
    paper_updated: { type: 'boolean', description: 'true only after you appended the survey digest (incl. coverage map + not-founds) AND the 3 bundles to the cycle Paper and re-published it' },
    bundles: {
      type: 'array', minItems: 3, maxItems: 3,
      description: 'EXACTLY 3 finding bundles, one per domain — deduped, triaged, ready for a task-cutter',
      items: {
        type: 'object', additionalProperties: false,
        required: ['domain_slug', 'guidance', 'findings'],
        properties: {
          domain_slug: { type: 'string' },
          guidance: { type: 'string', description: 'triage guidance for this domain\'s task-cutter: what to prioritize, what to merge into one task, what quality bar applies, which shared seams other domains also touch (harmonization forewarning)' },
          findings: {
            type: 'array',
            description: 'the vetted fix-worthy findings for this domain — enough for 4-20 tasks',
            items: {
              type: 'object', additionalProperties: false,
              required: ['title', 'files', 'evidence', 'suggested_fix', 'severity'],
              properties: {
                title: { type: 'string' },
                files: { type: 'array', items: { type: 'string' } },
                evidence: { type: 'string' },
                suggested_fix: { type: 'string' },
                severity: { type: 'string', enum: ['bug', 'debt', 'polish'] },
              },
            },
          },
        },
      },
    },
    dropped: { type: 'string', description: 'what you deliberately dropped or deferred and why — silent truncation is forbidden' },
  },
}

const CUT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['domain', 'tasks', 'tasks_verified', 'backlog_filed'],
  properties: {
    domain: { type: 'string' },
    tasks: {
      type: 'array', minItems: 4, maxItems: 20,
      description: '4-20 PUBLISHED bp tasks you filed for this domain — one per builder (pending harmonization)',
      items: {
        type: 'object', additionalProperties: false,
        required: ['task_id', 'title', 'surface', 'files', 'instructions', 'gate', 'size'],
        properties: {
          task_id: { type: 'string', description: 'slug of the PUBLISHED bp task — you created it and read it back' },
          title: { type: 'string' },
          surface: { type: 'string' },
          files: { type: 'array', items: { type: 'string' }, description: 'exact repo-relative paths the fix touches — the harmonizer collision-checks these across the whole cycle' },
          instructions: { type: 'string', description: 'complete enough for a cold Opus builder: the defect, the evidence, the fix, the constraints' },
          gate: { type: 'string', description: 'exact shell command(s) that prove it — DRY-RUN the gate yourself before filing' },
          size: { type: 'string', enum: ['small', 'medium'], description: 'wild-bulk tasks are small or medium; anything large goes to the backlog for an epic cycle' },
        },
      },
    },
    tasks_verified: { type: 'boolean', description: 'true only after you re-read every task from the server and confirmed each is published, parented, rubric-quality' },
    backlog_filed: { type: 'string', description: 'too-big-for-this-cycle work you filed as published backlog tasks (ids), or "none"' },
  },
}

const PREFLIGHT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['task_id', 'ok', 'problems', 'notes'],
  properties: {
    task_id: { type: 'string' },
    ok: { type: 'boolean', description: 'true only if the brief survives contact with reality unchanged' },
    problems: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['kind', 'detail'],
        properties: {
          kind: { type: 'string', enum: ['missing_file', 'stale_evidence', 'bad_gate', 'overlap_risk', 'underspecified', 'hazard', 'other'] },
          detail: { type: 'string', description: 'concrete: which path/line/command, what you observed instead' },
        },
      },
    },
    notes: { type: 'string', description: 'anything the harmonizer should know that is not a problem (e.g. an easier fix exists)' },
  },
}

const HARMONIZE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['harmony_report', 'ledger_patches', 'paper_updated', 'heartbeat_stamped', 'roster'],
  properties: {
    harmony_report: { type: 'string', description: 'what collided, what got merged/dropped/deferred and why, which conventions you unified across domains' },
    ledger_patches: { type: 'string', description: 'every bp task mutation you made (patched instructions, merged tasks closed as duplicate, deferred tasks re-prioritized), or "none"' },
    paper_updated: { type: 'boolean', description: 'true only after you appended the harmonized roster + harmony report to the cycle Paper and re-published it' },
    heartbeat_stamped: { type: 'boolean', description: 'true only after wave_status on the epic task says the cycle is building' },
    roster: {
      type: 'array',
      description: 'the FINAL disposition of every cut task — this roster, not the cutters\' output, is what builds',
      items: {
        type: 'object', additionalProperties: false,
        required: ['task_id', 'domain_slug', 'action', 'title', 'surface', 'files', 'instructions', 'gate', 'harmony_note'],
        properties: {
          task_id: { type: 'string' },
          domain_slug: { type: 'string' },
          action: { type: 'string', enum: ['build', 'merged', 'dropped', 'deferred'], description: 'build = a builder flies; merged = folded into another rostered task (name it in harmony_note); dropped = not worth it (task closed with honest note); deferred = real but not this cycle (task stays open, re-prioritized)' },
          title: { type: 'string' },
          surface: { type: 'string' },
          files: { type: 'array', items: { type: 'string' }, description: 'FINAL file set — across ALL action=build rows these must be pairwise disjoint' },
          instructions: { type: 'string', description: 'the FINAL brief (post-patch) the builder gets — must match the bp task text after your patches' },
          gate: { type: 'string' },
          harmony_note: { type: 'string', description: 'cross-task context the builder needs: shared conventions to follow, the sibling task that owns a shared helper, hazards adjacent to its files; empty string if none' },
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
    ledger_stamps: { type: 'string', description: 'the task mutations you made DURING the build — claim, each stamp, each pulse — proof the ledger stayed live' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['domain', 'verdicts', 'summary'],
  properties: {
    domain: { type: 'string' },
    verdicts: {
      type: 'array',
      description: 'one verdict per build in your domain — green AND red',
      items: {
        type: 'object', additionalProperties: false,
        required: ['task_id', 'branch', 'verdict', 'issues', 'polish_brief'],
        properties: {
          task_id: { type: 'string' },
          branch: { type: 'string', description: 'the builder\'s branch, or "" if it never committed' },
          verdict: { type: 'string', enum: ['ship', 'polish', 'reject'], description: 'ship = good as-is, DO NOT touch (no need to fix what is good); polish = worth one Opus pass; reject = wrong approach or not worth rescuing — task reopens' },
          issues: { type: 'string', description: 'what you found (diff-level, concrete), or "none"' },
          polish_brief: { type: 'string', description: 'ONLY for verdict=polish: the exact, bounded fix list for the polisher — no open-ended "improve things"; empty string otherwise' },
        },
      },
    },
    summary: { type: 'string', description: 'domain-level verdict: coherence across the fixes, themes, anything the final reviewer must know' },
  },
}

const POLISH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ok', 'task_id', 'branch', 'summary', 'gate_passed', 'ledger_stamps'],
  properties: {
    ok: { type: 'boolean' },
    task_id: { type: 'string' },
    branch: { type: 'string', description: 'the final -p branch, or the original branch if you changed nothing' },
    summary: { type: 'string', description: 'exactly what you fixed from the brief, and anything in the brief you could not do' },
    gate_passed: { type: 'boolean', description: 'the task\'s gate re-run green on your final state' },
    ledger_stamps: { type: 'string', description: 'bp mutations you made (stamps/pulses/notes), or why you could not (lapsed claim etc.)' },
  },
}

const FINAL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ledger_fixes', 'grade', 'commentary', 'paper_closed', 'heartbeat_stamped', 'merge_ready', 'not_merge_ready', 'next_cycle'],
  properties: {
    ledger_fixes: { type: 'string', description: 'bp task mutations you made to make the ledger match reality (incl. reopening rejected tasks), or "none"' },
    grade: { type: 'string', description: 'letter grade A+..F for the cycle AS IT WILL MERGE, judged against the WISH' },
    commentary: { type: 'string', description: 'the Cody mandate: honest commentary that EARNS the grade — what is genuinely strong, what falls short and why, never a bare number' },
    paper_closed: { type: 'string', description: 'the cycle Paper id after you appended the final debrief and re-published it, or "failed: <why>"' },
    heartbeat_stamped: { type: 'boolean', description: 'true only after wave_status on the epic task says the cycle is complete and names the Paper' },
    merge_ready: {
      type: 'array',
      description: 'branches the lead should integrate, in order',
      items: {
        type: 'object', additionalProperties: false,
        required: ['task_id', 'branch', 'verdict'],
        properties: {
          task_id: { type: 'string' },
          branch: { type: 'string', description: 'the FINAL branch (-p if polished, else original)' },
          verdict: { type: 'string', description: 'one line: what it is + anything the lead must know before merging' },
        },
      },
    },
    not_merge_ready: { type: 'array', items: { type: 'string' }, description: 'task ids that stalled/were rejected/deferred, each with a one-line why' },
    next_cycle: { type: 'string', description: 'what the next cycle (bulk or epic) should take and why' },
  },
}

const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)

// ── Phase 1: Plan — one Fable partitions the codebase into 3 blast-radius-aware domains ──
phase('Plan')
const planner = await agent(
  `You are the PLANNER of a Barkpark WILD BULK CYCLE — one Fable mind opening a high-throughput sweep-and-fix across the codebase. Downstream of you: 3 Opus domain leads, 30-60 Opus surveyors, 3 Opus task-cutters, a harmonization gate, up to 60 Opus builders. This cycle is WIDE — the blast radius of a bad partition is 60 colliding branches — so partition for isolation first, ambition second.

${USER_WISH_BLOCK}
${CHARTER_LINE}

Your job:
1. direction — what this cycle hunts (bug classes, debt, polish below the Kinsta/Vercel bar) and what it must NOT touch. Bulk cycles fix and finish; they do not redesign. Name the global conventions builders must share (error shapes, naming, test style) so 60 small fixes read as one hand's work.
2. domains — partition the codebase into EXACTLY 3 disjoint domains sized to the wish (e.g. api/ vs internal/+cli vs cloud/+js/+web — but YOU choose from what the wish implies). Scope paths must not overlap: two builders in one file is a merge conflict factory. Skim just enough (\`bp search\` for prior papers/tasks, a fast look at the tree) to partition honestly. The hazards field is the blast-radius map every downstream phase inherits — name hot concurrent-dev areas, prod-coupled code, contract seams shared with the OTHER two domains, known traps. Be specific; "be careful" protects nothing.
3. OPEN THE CYCLE PAPER: create + publish the cycle Paper (slug like wild-bulk-<topic>-<YYYY-MM-DD>, style=article): the wish, your direction, the 3 domains with scopes, missions, hazards. Read it back before setting paper_created=true.
4. EPIC PARENT TASK: ${EPIC_TASK_ID ? `verify ${EPIC_TASK_ID} exists and is published; stamp its flat wave_status ("wild-bulk: surveying — <one-line direction>") + wave_paper (the Paper's id) and re-publish.` : 'ensure ONE published epic parent task exists for this cycle (create it if missing — slug it from the topic); stamp wave_status + wave_paper on it.'} Report its slug in epic_task_id.
${PAPER_BLOCK}
${TASKS_BLOCK}${LEAD_NOTES}`,
  { label: 'planner', phase: 'Plan', schema: PLAN_SCHEMA, model: M('fable'), effort: 'high' }
)
if (!planner) throw new Error('Plan phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
// Floor 1/4 — the partition. Fires before Recon spends a single domain lead.
if (fanout(planner.domains) < DOMAIN_FLOOR) {
  throw new Error(`Domain fan-out floor: the planner returned ${fanout(planner.domains)} domain(s), below the floor of ${DOMAIN_FLOOR}. The whole cycle is partitioned here — recon, survey, digest, cut and review all fan out per domain — so a short partition silently narrows every later phase at once, and the cycle still reports itself complete. Re-run Plan with a real ${DOMAIN_FLOOR}-way disjoint partition rather than proceeding.`)
}
const CYCLE_PAPER = planner.paper_id
const EPIC_TASK = planner.epic_task_id
log(`Planner cut 3 domains: ${planner.domains.map((d) => d.slug).join(', ')}; paper ${CYCLE_PAPER}; epic task ${EPIC_TASK}`)

// ── Phases 2+3: Recon + Survey — per-domain pipeline: Opus lead designs probes, Opus scouts sweep ──
// Pipelined: domain B's lead thinks while domain A's surveyors already fly.
const surveyed = (await pipeline(
  planner.domains,
  (d) =>
    agent(
      `You are a DOMAIN LEAD in a Barkpark wild bulk cycle — one of 3, each owning a disjoint slice of the codebase. You design the survey; Opus scouts execute it.

${USER_WISH_BLOCK}

CYCLE DIRECTION:
${planner.direction}

YOUR DOMAIN [${d.slug}]: ${d.name}
SCOPE (yours alone — stay inside it): ${(d.scope_paths || []).join(', ')}
MISSION: ${d.mission}
HAZARDS (the blast-radius map — your probes must cover these seams, not just avoid them): ${d.hazards}
${CHARTER_LINE}

Design 10-20 survey probes for Opus surveyors. Each probe is one scout: a concrete, answerable question that hunts fixable defects — bug classes, dead code, error paths, contract drift between surfaces, quality below the Kinsta/Vercel bar. Dedicate at least two probes to the domain's SEAMS — the places your files meet the other two domains and prod — because that is where a bulk cycle does accidental damage. Read just enough of your domain (skim structure, \`bp search\` prior art) to aim the probes well; the scouts do the reading. Spread the probes so together they COVER the domain — name the corners each one owns.`,
      { label: `recon:${d.slug}`, phase: 'Recon', schema: RECON_SCHEMA, model: LEAD_MODEL }
    ),
  async (recon, d) => {
    if (!recon) return null
    const probes = Array.isArray(recon.survey) ? recon.survey.slice(0, 20) : []
    // Floor 2/4 — the real agent fan-out: one Opus scout per probe. Fires before
    // this domain's surveyors are spent. NOTE: pipeline() runs stages under
    // Promise.allSettled, so this throw is swallowed into a dropped domain rather
    // than aborting the cycle — the top-level surviving-domain check after the
    // pipeline is what actually stops the run. Both halves are required.
    if (probes.length < PROBE_FLOOR) {
      throw new Error(`Survey fan-out floor [${d.slug}]: the domain lead designed ${probes.length} probe(s), below the floor of ${PROBE_FLOOR}. Each probe is one Opus scout, and width is the cheapest part of a cycle — a thin probe set is how a domain's defects stay invisible and get rebuilt later at full price. Re-run Recon for this domain with a real ${PROBE_FLOOR}-20 probe sweep rather than proceeding.`)
    }
    log(`[${d.slug}] lead designed ${probes.length} probes; surveying`)
    const reports = (await parallel(
      probes.map((q) => () =>
        agent(
          `You are a SURVEYOR in a Barkpark wild bulk cycle — one of ~${probes.length} Opus scouts sweeping the "${d.name}" domain. READ-ONLY: no edits, no commits, no bp mutations. Budget: ~5 minutes — breadth over depth; park what you can't settle in open_questions.

${USER_WISH_BLOCK}

CYCLE DIRECTION: ${planner.direction}
DOMAIN SCOPE (stay inside it): ${(d.scope_paths || []).join(', ')}
DOMAIN HAZARDS (context, not targets): ${d.hazards}

YOUR PROBE [${q.key}]: ${q.question}
WHY IT MATTERS: ${q.why}

Search Barkpark FIRST (\`bp search query "<terms>"\` — the \`query\` sub-verb is REQUIRED; dropping it exits 2 with \`unknown command "search"\`, and that failure reads exactly like a real absence of prior art, so check the exit code — papers and tasks carry prior art the tree doesn't), then grep/read the repo. Every load-bearing fact needs evidence you actually derived, and its \`rerun\` command. "The premise is wrong" is a valid answer.

YOUR MAIN CARGO is fix_candidates[]: concrete, bounded, fixable defects — each with files, file:line evidence, a suggested fix, and severity (bug / debt / polish). A candidate an Opus builder could fix in one sitting is gold; a vague "this area smells" is noise. Note in the evidence when a candidate's files sit on a seam shared with another domain or prod — the harmonizer needs that.

COVERAGE ACCOUNTING: list EVERY file/paper/task you checked in coverage[] — path, what you checked it for, found / not_found / partial. NOT-FOUND IS A FINDING. Unlisted = unchecked.`,
          { label: `survey:${d.slug}:${q.key}`, phase: 'Survey', schema: SURVEY_SCHEMA, model: SURVEY_MODEL }
        )
      )
    )).filter(Boolean)
    log(`[${d.slug}] ${reports.length}/${probes.length} surveyors reported; ${reports.reduce((n, r) => n + (r.fix_candidates || []).length, 0)} fix candidates`)
    return { domain: d, reports }
  }
)).filter(Boolean)

// The enforcing half of floor 2/4. A domain whose lead died, or whose probe floor
// threw in-stage, comes back as a swallowed `null` and is filtered away above —
// leaving the cycle to digest 2 domains while still calling itself a 3-domain
// sweep. Fires before Digest spends a Fable.
if (surveyed.length < DOMAIN_FLOOR) {
  throw new Error(`Domain survival floor: only ${surveyed.length} of ${DOMAIN_FLOOR} domains survived Recon+Survey. A domain drops out here when its lead died or its probe floor fired, and pipeline() swallows both into a silent null — so the cycle would digest a partial sweep and report it as whole. Check the pipeline[] failure lines above for the real cause, then resume the run rather than proceeding on ${surveyed.length}/${DOMAIN_FLOOR} of the codebase.`)
}
const totalCandidates = surveyed.reduce((n, s) => n + s.reports.reduce((m, r) => m + (r.fix_candidates || []).length, 0), 0)
// ONE interception, in place, at the barrier where the survey resolves — BEFORE
// the first JSON.stringify in this file, so every downstream serialisation of a
// survey report (Digest today, whatever a later wave adds) reads gated facts.
const surveyGrip = gateFactProvenance(surveyed.flatMap((s) => s.reports || []))
const SURVEY_GRIP = gripBlock(surveyGrip)
log(`Survey complete: ${surveyed.length}/3 domains, ${totalCandidates} raw fix candidates; provenance gate: ${surveyGrip.demoted}/${surveyGrip.total} fact(s) DEMOTED (no rerun command)`)

// ── Phase 4: Digest — one Fable holds ALL reports (barrier: cross-domain dedup) ──
phase('Digest')
const digest = await agent(
  `You are the DIGEST strategist of a Barkpark wild bulk cycle — one Fable holding every survey report from all 3 domains. Your output feeds 3 Opus task-cutters directly; the harmonizer catches collisions later, but every rumor you let through here costs a filed task, a preflight, and a patch downstream. Filter hard now.

${USER_WISH_BLOCK}

CYCLE DIRECTION:
${planner.direction}

DOMAINS:
${JSON.stringify(planner.domains.map((d) => ({ slug: d.slug, name: d.name, scope_paths: d.scope_paths, hazards: d.hazards })), null, 2)}

SURVEY REPORTS BY DOMAIN (trust file:line evidence over prose; treat unanchored claims as rumors):
${JSON.stringify(surveyed.map((s) => ({ domain: s.domain.slug, reports: s.reports })), null, 2)}
${SURVEY_GRIP}

Your job:
1. SYNTHESIZE: defect themes across domains, contradictions between scouts, what the sweep established and what stayed dark.
2. CUT 3 BUNDLES (one per domain): dedup ACROSS domains (two scouts finding the same rot at a shared seam = ONE finding, assigned to the domain that owns the file), kill rumors (no file:line evidence = out), merge trivial neighbors into one finding, and drop what does not serve the wish — record every drop in \`dropped\` with why (silent truncation is forbidden). Each bundle should carry enough vetted findings for 4-20 tasks. Give each cutter triage guidance: priorities, what to merge, the quality bar, and — explicitly — which of its findings sit on seams other domains also touch, so the cutters pre-shrink the harmonizer's job.
3. UPDATE THE CYCLE PAPER (${CYCLE_PAPER}) — append, then re-publish, BEFORE the cutters fly: the synthesis, a coverage map distilled from the scouts' coverage[] (found AND not-found, plus corners no scout reached), and the 3 bundles in summary form. Set paper_updated=true only after you re-published and read it back.
4. HEARTBEAT: stamp the epic task ${EPIC_TASK}'s flat wave_status ("wild-bulk: cutting tasks — <one-line synthesis>") and re-publish.
${PAPER_BLOCK}${LEAD_NOTES}`,
  { label: 'digest', phase: 'Digest', schema: DIGEST_SCHEMA, model: M('fable'), effort: 'high' }
)
if (!digest) throw new Error('Digest phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
// Floor 3/4 — one bundle per domain, one Opus task-cutter per bundle. Fires before
// Cut spends a cutter, and before the reduce below would fault on a missing array.
if (fanout(digest.bundles) < BUNDLE_FLOOR) {
  throw new Error(`Bundle fan-out floor: the digest returned ${fanout(digest.bundles)} bundle(s), below the floor of ${BUNDLE_FLOOR}. One bundle becomes one Opus task-cutter, so a dropped bundle is a domain that got surveyed and then silently cut nothing — the most expensive way to lose work in this cycle. Re-run Digest with one bundle per surveyed domain rather than proceeding.`)
}
log(`Digest cut 3 bundles (${digest.bundles.reduce((n, b) => n + b.findings.length, 0)} vetted findings); dropped: ${digest.dropped.slice(0, 120)}`)

const domainBySlug = {}
for (const d of planner.domains) domainBySlug[d.slug] = d
const domainOf = (s) => domainBySlug[s] || { slug: s, name: s, scope_paths: [], hazards: '', mission: '' }

// ── Phase 5: Cut — 3 Opus task-cutters file 10-60 bp tasks (barrier: harmonizer needs ALL) ──
phase('Cut')
const cuts = (await parallel(
  digest.bundles.map((bundle) => () => {
    const d = domainOf(bundle.domain_slug)
    return agent(
      `You are a TASK-CUTTER in a Barkpark wild bulk cycle — one of 3, turning a vetted finding bundle into published, claimable bp tasks. Every task you file becomes one Opus builder in an isolated worktree. After you, each task is PREFLIGHTED against reality and a Fable HARMONIZER cross-checks the whole 10-60-task roster — so file honestly and precisely; a sloppy brief costs a preflight failure and a patch.

${USER_WISH_BLOCK}

CYCLE DIRECTION: ${planner.direction}
DIGEST SYNTHESIS: ${digest.synthesis}
YOUR DOMAIN [${d.slug}]: scope ${(d.scope_paths || []).join(', ')} — hazards: ${d.hazards}
EPIC PARENT TASK: ${EPIC_TASK} — parent every task under it (parent_id=${EPIC_TASK}).
CYCLE PAPER: ${CYCLE_PAPER} — put its id on every task (flat wave_paper field). NEVER write the Paper itself.

YOUR BUNDLE (vetted findings + triage guidance):
${JSON.stringify(bundle, null, 2)}

Your job:
1. CUT 4-20 TASKS from the findings — one task per coherent fix. Merge findings that one builder should fix together (same file, same theme); a builder gets ONE sitting, so keep tasks small/medium. Anything large goes to the backlog (published, honest, priority set) — record ids in backlog_filed.
2. DISJOINT FILES: within your domain, no two tasks touch the same file — builders run in parallel worktrees and the lead merges their branches; overlaps become conflicts. Merge or drop rather than overlap. The files[] you report per task must be exact and complete: the harmonizer collision-checks them mechanically across all 3 domains, and a file you omit escapes the check.
3. FILE EACH TASK to the rubric: outcome-shaped title, description a cold builder could start from (the defect, the file:line evidence, the fix, the constraints, the domain hazards that apply), concrete evidence-bearing acceptance criteria (include a merge-gated "PR merged" criterion the lead closes), sane priority (bug=1, debt=2, polish=3), and an exact gate command — DRY-RUN each gate yourself before filing it.
4. PERFECT THE TASKS: re-read every task back from the server; verify published, parented under ${EPIC_TASK}, linked to the Paper, rubric-quality. Fix defects via bp. Set tasks_verified=true only after this read-back pass is clean.
${TASKS_BLOCK}
${GATES_BLOCK}${LEAD_NOTES}`,
      { label: `cut:${bundle.domain_slug}`, phase: 'Cut', schema: CUT_SCHEMA, model: CUTTER_MODEL }
    )
  })
)).filter(Boolean)

// Floor 4/4 — the build fan-out: one task becomes one builder. Checked per domain
// BEFORE the flatMap, so the error names which cutter came up short rather than
// reporting a healthy-looking total that hides one empty domain. Fires before
// Preflight spends an Opus (low effort) per task.
if (cuts.length < BUNDLE_FLOOR) {
  throw new Error(`Cutter survival floor: only ${cuts.length} of ${BUNDLE_FLOOR} task-cutters returned. parallel() swallows a died cutter into a null that is filtered away here, so the cycle would build one domain's fixes and report a full sweep. Check the parallel[] failure lines above, then resume the run rather than proceeding.`)
}
for (const c of cuts) {
  const cutCount = fanout(c.tasks)
  if (cutCount < CUT_TASK_FLOOR) {
    throw new Error(`Cut fan-out floor [${c.domain}]: this cutter filed ${cutCount} task(s), below the floor of ${CUT_TASK_FLOOR}. Every task is one builder, so a thin cut is a domain that was surveyed at full price and then fixed at none — and the cycle's own report would still read as a completed sweep of that domain. Re-run Cut for this domain against its bundle (${CUT_TASK_FLOOR}-20 tasks) rather than proceeding.`)
  }
}
const allCutTasks = cuts.flatMap((c) => (c.tasks || []).slice(0, 20).map((t) => ({ ...t, domain_slug: c.domain })))
log(`Cut: ${allCutTasks.length} tasks filed across ${cuts.length}/3 domains`)
if (allCutTasks.length === 0) {
  return { cycle_paper: CYCLE_PAPER, epic_task_id: EPIC_TASK, surveyors: surveyed.reduce((n, s) => n + s.reports.length, 0), fix_candidates: totalCandidates, tasks_filed: 0, note: 'no tasks cut — nothing to build', synthesis: digest.synthesis }
}

// ── Phase 6: Preflight — one Opus (low effort) per task verifies the brief against reality ──
phase('Preflight')
const preflights = (await parallel(
  allCutTasks.map((t) => () =>
    agent(
      `You are a PREFLIGHT scout in a Barkpark wild bulk cycle — one Opus scout (low effort) checking ONE task brief against reality BEFORE a builder is spent on it. READ-ONLY on the repo; no bp mutations. Budget: ~3 minutes. You are the cycle's cheapest defense against wasted builders — be literal and skeptical.

TASK [${t.task_id}] (domain ${t.domain_slug}): ${t.title}
FILES IT CLAIMS TO TOUCH: ${(t.files || []).join(', ')}
INSTRUCTIONS: ${t.instructions}
GATE: ${t.gate}

Check, concretely:
1. missing_file — does every path in FILES exist (or is it explicitly a new file the instructions say to create)?
2. stale_evidence — open the file:line evidence cited in the instructions; is the defect actually there, as described, TODAY? (Other sessions land constantly — evidence goes stale.)
3. bad_gate — is the gate command runnable from the repo root? Run it if it looks < ~60s (node --check, a single go vet package, one mix test file); for long suites verify the referenced paths/targets exist. A gate that cannot run forces the builder to interpret instead of prove.
4. underspecified — could a cold builder start from this brief without guessing an important choice?
5. hazard / overlap_risk — do the FILES sit in a known-hot area or on a seam the instructions do not mention?

Report ok=true ONLY if the brief survives unchanged. Every problem gets a concrete detail (which path, which line, what you observed instead). Put improvements that are not problems in notes.`,
      { label: `preflight:${slug(t.task_id)}`, phase: 'Preflight', schema: PREFLIGHT_SCHEMA, model: SURVEY_MODEL, effort: 'low' }
    )
  )
)).filter(Boolean)
const preflightProblems = preflights.filter((p) => !p.ok)
log(`Preflight: ${preflights.length}/${allCutTasks.length} checked, ${preflightProblems.length} briefs with problems`)

// Deterministic file-overlap matrix — never trust a model to notice a collision a script can compute.
const norm = (p) => p.replace(/^\.\//, '').replace(/\/+$/, '')
const fileClaims = allCutTasks.flatMap((t) => (t.files || []).map((f) => ({ path: norm(f), task_id: t.task_id, domain: t.domain_slug })))
const overlaps = []
for (let i = 0; i < fileClaims.length; i++) {
  for (let j = i + 1; j < fileClaims.length; j++) {
    const a = fileClaims[i], b = fileClaims[j]
    if (a.task_id === b.task_id) continue
    if (a.path === b.path || a.path.startsWith(b.path + '/') || b.path.startsWith(a.path + '/')) {
      overlaps.push({ tasks: [a.task_id, b.task_id], domains: [a.domain, b.domain], paths: [a.path, b.path] })
    }
  }
}
log(`Overlap matrix: ${overlaps.length} file collisions across the roster`)

// ── Phase 7: Harmonize — one Fable makes the whole roster coherent (THE blast-radius gate) ──
phase('Harmonize')
const harmonizer = await agent(
  `You are the HARMONIZER of a Barkpark wild bulk cycle — one Fable holding the ENTIRE roster before up to 60 Opus builders fly in parallel worktrees. This is the cycle's blast-radius gate: after you, nobody cross-checks anything until review. Three Opus cutters filed these tasks independently; your job is to make 10-60 independent briefs behave like one plan.

${USER_WISH_BLOCK}

CYCLE DIRECTION (including the global conventions builders must share):
${planner.direction}

DOMAINS + HAZARDS:
${JSON.stringify(planner.domains.map((d) => ({ slug: d.slug, scope_paths: d.scope_paths, hazards: d.hazards })), null, 2)}

THE CUT TASKS (all 3 domains):
${JSON.stringify(allCutTasks, null, 2)}

SCRIPT-COMPUTED FILE COLLISIONS (mechanical prefix/exact matching on the tasks' files[] — resolve EVERY row):
${JSON.stringify(overlaps, null, 2)}

PREFLIGHT REPORTS (one Opus scout checked each brief against reality — problems are observations, not opinions):
${JSON.stringify(preflights, null, 2)}

Your job — every cut task gets exactly one roster row with a final action:
1. COLLISIONS: resolve every row of the collision matrix — merge the tasks (one builder does both; close the other as duplicate with a note), re-scope files so they are disjoint, or defer one. Across all action=build rows, files[] must be PAIRWISE DISJOINT — that invariant, not good intentions, is what lets 60 worktrees merge cleanly.
2. PREFLIGHT FAILURES: a brief with stale_evidence or missing_file gets re-verified and PATCHED (fix the bp task text) or dropped — never handed to a builder as-is. bad_gate briefs get a working gate (dry-run it). underspecified briefs get the missing decision made — by you, now; do not push ambiguity onto a builder.
3. HARMONY: where two tasks would each invent the same helper/convention, designate ONE owner and point the other at it in harmony_note; where fixes on a shared seam could disagree (error shapes, naming, copy tone), decide the convention once and stamp it into both briefs. Where a task's files sit against a hazard (hot concurrent-dev area, prod-coupled code), either bound the brief so it cannot stray or defer it — a bulk cycle never bets the prod path on a bulk builder.
4. LEDGER: apply every change to the bp tasks themselves (patch instructions/files/gate, re-publish; close merged duplicates honestly; re-prioritize deferred tasks). The roster instructions you emit must MATCH the task text on the server — the builder is told the task is the contract of record.
5. UPDATE THE CYCLE PAPER (${CYCLE_PAPER}) — append the harmonized roster (per task: action + one line why) + your harmony report, re-publish, BEFORE the builders fly. Set paper_updated=true only after you read it back.
6. HEARTBEAT: stamp the epic task ${EPIC_TASK}'s wave_status ("wild-bulk: building <n> tasks — <one-line>") and re-publish.
${TASKS_BLOCK}
${PAPER_BLOCK}${LEAD_NOTES}`,
  { label: 'harmonizer', phase: 'Harmonize', schema: HARMONIZE_SCHEMA, model: M('fable'), effort: 'high' }
)
if (!harmonizer) throw new Error('Harmonize phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
const roster = (harmonizer.roster || []).filter((r) => r.action === 'build')
log(`Harmonizer: ${roster.length} build / ${(harmonizer.roster || []).filter((r) => r.action === 'merged').length} merged / ${(harmonizer.roster || []).filter((r) => r.action === 'dropped').length} dropped / ${(harmonizer.roster || []).filter((r) => r.action === 'deferred').length} deferred`)
if (roster.length === 0) {
  return { cycle_paper: CYCLE_PAPER, epic_task_id: EPIC_TASK, tasks_filed: allCutTasks.length, roster: 0, note: 'harmonizer rostered nothing to build', harmony_report: harmonizer.harmony_report }
}

// ── Phases 8-10: Build → Review → Polish — per-domain pipeline off the harmonized roster ──
const rosterByDomain = planner.domains
  .map((d) => ({ domain: d, items: roster.filter((r) => r.domain_slug === d.slug) }))
  .filter((g) => g.items.length > 0)
// Roster rows whose domain_slug matches no planned domain would silently never build — reassign loudly.
const orphaned = roster.filter((r) => !planner.domains.some((d) => d.slug === r.domain_slug))
if (orphaned.length > 0) {
  log(`WARNING: ${orphaned.length} roster rows have unknown domain_slug (${orphaned.map((r) => r.task_id).join(', ')}) — building them under the first domain`)
  rosterByDomain[0] = rosterByDomain[0] || { domain: planner.domains[0], items: [] }
  rosterByDomain[0].items.push(...orphaned)
}

const domainRuns = (await pipeline(
  rosterByDomain,
  // Stage 1 — BUILD: one Opus per rostered task, worktree-isolated
  async (g) => {
    const d = g.domain
    log(`[${d.slug}] building ${g.items.length} tasks`)
    const builds = (await parallel(
      g.items.map((t, i) => () =>
        agent(
          `You are a BUILDER in a Barkpark wild bulk cycle — one Opus builder fixing ONE task inside your OWN isolated git worktree (safe to edit/commit; you will not collide with other builders — the roster was harmonized so no two builders share a file). An Opus reviewer checks your work after — build honestly, not defensively.

${USER_WISH_BLOCK}
${CHARTER_LINE}
CYCLE CONVENTIONS (all builders share these — your fix must read as the same hand): ${planner.direction}
DOMAIN HAZARDS: ${d.hazards}

TASK: ${t.title}
BP TASK: ${t.task_id}
SURFACE: ${t.surface}
FILES (stay inside them — straying breaks the cycle's disjointness invariant): ${(t.files || []).join(', ')}
INSTRUCTIONS: ${t.instructions}
${t.harmony_note ? `HARMONY NOTE (cross-task context — follow it): ${t.harmony_note}` : ''}
GATE (must pass before you commit): ${t.gate}

Steps — task first, code second, ledger LIVE throughout:
1. CLAIM before touching code: \`bp task claim ${t.task_id} bulk-${d.slug}-${i}\` — read the brief it carries; the task, not this prompt, is the contract of record. If the claim fails, STOP and report ok:false task_claimed:false with the error.
2. Fix it properly — bounded scope, match surrounding code style, no drive-by refactors outside your FILES. Quality bar: Kinsta/Vercel.
3. STAMP AS YOU GO (see contract below) and PULSE at claim + each boundary (building → gating → committing). Record every stamp/pulse in ledger_stamps.
4. JS SDK public API change ⇒ add a js/.changeset/ entry.
5. Run the gate. Fix until it passes; if it truly cannot, STOP without committing and report ok:false with why (leave the task claimed + in_progress with a stamped note).
6. Honest self-review: what could break, blind spots.
7. Only if the gate passes: branch 'wild-bulk/${d.slug}/${slug(t.title)}-${i}', one clear conventional commit. Do NOT push. Do NOT touch main.
8. Merge-gated criteria stay open; lifecycle stays in_progress — the LEAD closes on merge. Your branch is named in the evidence.
${TASKS_BLOCK}
${LIVENESS_BLOCK}
Constraints: curl localhost only; never mix compile against prod; don't touch other worktrees' WIP.`,
          { label: `build:${d.slug}:${slug(t.title)}`, phase: 'Build', schema: BUILD_SCHEMA, model: BUILD_MODEL, isolation: 'worktree' }
        )
      )
    )).filter(Boolean)
    const green = builds.filter((b) => b.ok && b.gate_passed && b.branch)
    log(`[${d.slug}] build: ${green.length}/${builds.length} green`)
    return { domain: d, items: g.items, builds }
  },
  // Stage 2 — REVIEW (Opus judge) + POLISH (Opus only where needed)
  async (st) => {
    if (!st) return null
    const d = st.domain
    const review = await agent(
      `You are a DOMAIN REVIEWER in a Barkpark wild bulk cycle — one of 3 Opus judges, reviewing every build in the "${d.slug}" domain. You do NOT fix anything yourself: you judge, and for each build that needs work you write a bounded polish brief that one Opus pass executes. Economy is the mandate: NO NEED TO FIX WHAT IS GOOD — a clean build gets verdict=ship and zero further spend.

${USER_WISH_BLOCK}
${CHARTER_LINE}
CYCLE CONVENTIONS (every fix must read as the same hand): ${planner.direction}

YOU ARE IN THE SHARED MAIN CHECKOUT — read-only. NEVER checkout/switch branches here (hard rule; other sessions share it). Inspect each build via \`git diff $(git merge-base origin/main <branch>)..<branch>\` and \`git show\` only.

THE ROSTERED TASKS (what each build was supposed to be — harmony_note carries cross-task obligations to check):
${JSON.stringify(st.items.map((t) => ({ task_id: t.task_id, title: t.title, instructions: t.instructions, gate: t.gate, files: t.files, harmony_note: t.harmony_note })), null, 2)}

THE BUILDS (green and red):
${JSON.stringify(st.builds.map((b) => ({ task_id: b.task_id, ok: b.ok, branch: b.branch, gate_passed: b.gate_passed, summary: b.summary, builder_review: b.review, files: b.files_changed })), null, 2)}

For EACH build, chase the builder's own doubts first, then review the diff adversarially: correctness (edge cases, escaping, stale state, error paths), scope discipline (did files_changed stay inside the task's FILES? a stray file breaks the cycle's disjointness invariant — automatic polish or reject), harmony obligations honored (the harmony_note conventions), the Kinsta/Vercel bar, coherence with the sibling fixes in your domain. Distrust vacuous green — check the gate actually pins the claimed behavior. Then verdict:
- ship: good as-is. Say so and move on — do not manufacture criticism.
- polish: worth ONE bounded Opus pass. polish_brief = the exact fix list (concrete, diff-level); never "improve it".
- reject: wrong approach, or a red build not worth rescuing this cycle — say why; the final reviewer reopens the task.
A red build (no branch / gate failed) whose task is still worth one fresh attempt gets verdict=polish with a brief that says "build from scratch"; otherwise reject.`,
      { label: `review:${d.slug}`, phase: 'Review', schema: REVIEW_SCHEMA, model: REVIEWER_MODEL }
    )
    if (!review) return { ...st, review: null, polishes: [] }
    const taskById = {}
    for (const t of st.items) taskById[t.task_id] = t
    const needsPolish = (review.verdicts || []).filter((v) => v.verdict === 'polish')
    log(`[${d.slug}] review: ${(review.verdicts || []).filter((v) => v.verdict === 'ship').length} ship, ${needsPolish.length} polish, ${(review.verdicts || []).filter((v) => v.verdict === 'reject').length} reject`)
    const polishes = needsPolish.length === 0 ? [] : (await parallel(
      needsPolish.map((v, i) => () => {
        const t = taskById[v.task_id] || {}
        return agent(
          `You are a POLISHER in a Barkpark wild bulk cycle — one Opus polisher executing ONE bounded fix list from a reviewer, inside your OWN isolated git worktree. Do EXACTLY what the brief says — no more (the reviewer already decided what is worth fixing), no less.

${USER_WISH_BLOCK}
DOMAIN HAZARDS: ${d.hazards}
${t.harmony_note ? `HARMONY NOTE (still binding): ${t.harmony_note}` : ''}

BP TASK: ${v.task_id}
ORIGINAL TASK BRIEF: ${t.instructions || '(see the bp task)'}
FILES (still binding — stay inside them): ${(t.files || []).join(', ')}
GATE (must pass on your final state): ${t.gate || '(the gate named on the bp task)'}
BUILDER'S BRANCH: ${v.branch || '(none — the build never committed; start fresh from origin/main)'}
REVIEWER'S ISSUES: ${v.issues}
YOUR FIX LIST (the whole job, nothing else): ${v.polish_brief}

Steps:
1. ${v.branch ? `In your worktree: \`git checkout -b ${v.branch}-p ${v.branch}\` — work on the -p branch; the original stays untouched.` : `In your worktree: \`git checkout -b wild-bulk/${d.slug}/${slug(t.title || v.task_id)}-p\` from origin/main and build the task fresh per the brief.`}
2. LEDGER: try \`bp task claim ${v.task_id} bulk-polish-${d.slug}-${i}\` (the builder's lease has likely lapsed). If the claim conflicts, skip ledger writes and note it in ledger_stamps — the final reviewer reconciles. If it succeeds, pulse + stamp what you prove, per the contract below.
3. Execute the fix list. Match surrounding style. Touch nothing outside it.
4. Re-run the gate; it must pass on your final state. If it cannot, report ok:false with why and commit nothing.
5. Commit on your -p branch (one conventional commit). Do NOT push. Do NOT touch main.
${TASKS_BLOCK}
${LIVENESS_BLOCK}`,
          { label: `polish:${d.slug}:${slug(v.task_id)}`, phase: 'Polish', schema: POLISH_SCHEMA, model: BUILD_MODEL, isolation: 'worktree' }
        )
      })
    )).filter(Boolean)
    return { ...st, review, polishes }
  }
)).filter(Boolean)

// ── Phase 11: Verdict — one Fable reviews the whole cycle (barrier: needs everything) ──
phase('Verdict')
const allBuilds = domainRuns.flatMap((r) => r.builds || [])
const allVerdicts = domainRuns.flatMap((r) => (r.review && r.review.verdicts) || [])
const allPolishes = domainRuns.flatMap((r) => r.polishes || [])
const final = await agent(
  `You are the FINAL REVIEWER of a Barkpark wild bulk cycle — one Fable closing the loop on the whole run: ${allCutTasks.length} tasks cut, ${roster.length} rostered after harmonization, ${allBuilds.length} builds across ${domainRuns.length} domains, ${allVerdicts.length} domain-reviewer verdicts, ${allPolishes.length} polish passes. You audit, grade, and hand the lead a merge list. You fix the LEDGER where it lies, but you do not write code.

${USER_WISH_BLOCK}
${CHARTER_LINE}
EPIC PARENT TASK: ${EPIC_TASK}. CYCLE PAPER: ${CYCLE_PAPER}.

YOU ARE IN THE SHARED MAIN CHECKOUT — read-only for the repo. NEVER checkout/switch branches; inspect via \`git diff\`/\`git show\` only.

HARMONIZER'S REPORT (the roster contract every build was bound to):
${JSON.stringify({ harmony_report: harmonizer.harmony_report, non_build: (harmonizer.roster || []).filter((r) => r.action !== 'build').map((r) => ({ task_id: r.task_id, action: r.action })) }, null, 2)}

DOMAIN RUNS (roster → builds → review → polish, per domain):
${JSON.stringify(domainRuns.map((r) => ({
    domain: r.domain.slug,
    rostered: (r.items || []).map((t) => ({ task_id: t.task_id, files: t.files, harmony_note: t.harmony_note })),
    builds: (r.builds || []).map((b) => ({ task_id: b.task_id, ok: b.ok, branch: b.branch, gate_passed: b.gate_passed, summary: b.summary, files_changed: b.files_changed, ledger_stamps: b.ledger_stamps })),
    reviewer_summary: r.review ? r.review.summary : null,
    verdicts: (r.review && r.review.verdicts) || [],
    polishes: (r.polishes || []).map((p) => ({ task_id: p.task_id, ok: p.ok, branch: p.branch, gate_passed: p.gate_passed, summary: p.summary })),
  })), null, 2)}

Your job:
1. MERGE LIST: for every task, resolve the FINAL branch — the -p branch where a polish landed green, else the builder's branch where the verdict was ship. Verify the disjointness invariant HELD: across all merge_ready branches, files_changed must not overlap (a stray file that slipped past a reviewer goes to not_merge_ready, named). Spot-check the highest-risk diffs yourself (git diff vs merge-base). merge_ready[] in integration order; everything else goes to not_merge_ready with a one-line why.
2. LEDGER AUDIT: for every cycle task — claimed by its builder? evidence stamped AS THEY WORKED (their ledger_stamps claim vs the task's actual state)? lifecycle truthful (in_progress with open merge-gated criteria, never done)? Rejected tasks reopened with an honest note? Merged/dropped/deferred roster actions reflected on the server as the harmonizer claimed? Polish outcomes reflected? Fix every lie/omission directly via bp; record in ledger_fixes.
3. GRADE (Cody mandate): letter grade A+..F for the cycle as it will merge, judged against the WISH — correctness, completeness, bloat, harmony (do 60 fixes read as one hand?), economy (did reviewers ship-without-touching what was good?). Commentary must EARN the grade; never a bare number, and do not manufacture criticism.
4. CLOSE THE CYCLE PAPER (${CYCLE_PAPER}): append the final DEBRIEF — per domain what shipped/stalled, the harmonizer's saves (collisions resolved before they cost anything), the polish economy (how many builds needed none), the grade + commentary, the ledger audit outcome, next_cycle. Read the Paper top to bottom first and fix anything a later phase invalidated with a dated correction note. Re-publish; report the id in paper_closed.
5. HEARTBEAT: stamp the epic task's wave_status ("wild-bulk: complete — grade <g>, ${allBuilds.length} builds, paper ${CYCLE_PAPER}") and re-publish.
6. next_cycle: what the next cycle (bulk or epic) should take and why.
${TASKS_BLOCK}
${PAPER_BLOCK}${LEAD_NOTES}`,
  { label: 'final-review', phase: 'Verdict', schema: FINAL_SCHEMA, model: M('fable'), effort: 'high' }
)

return {
  direction: planner.direction,
  cycle_paper: CYCLE_PAPER,
  epic_task_id: EPIC_TASK,
  domains: planner.domains.map((d) => d.slug),
  surveyors: surveyed.reduce((n, s) => n + s.reports.length, 0),
  fix_candidates: totalCandidates,
  synthesis: digest.synthesis,
  tasks_filed: allCutTasks.length,
  preflight_problems: preflightProblems.length,
  file_collisions_detected: overlaps.length,
  harmony_report: harmonizer.harmony_report,
  rostered: roster.length,
  builds: allBuilds.length,
  builds_green: allBuilds.filter((b) => b.ok && b.gate_passed && b.branch).length,
  verdicts: { ship: allVerdicts.filter((v) => v.verdict === 'ship').length, polish: allVerdicts.filter((v) => v.verdict === 'polish').length, reject: allVerdicts.filter((v) => v.verdict === 'reject').length },
  polishes_green: allPolishes.filter((p) => p.ok && p.gate_passed).length,
  merge_ready: final ? final.merge_ready : [],
  not_merge_ready: final ? final.not_merge_ready : allBuilds.map((b) => `${b.task_id}: final review died — audit manually`),
  ledger_fixes: final ? final.ledger_fixes : null,
  grade: final ? final.grade : null,
  commentary: final ? final.commentary : null,
  paper_closed: final ? final.paper_closed : null,
  next_cycle: final ? final.next_cycle : null,
}
