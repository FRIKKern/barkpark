export const meta = {
  name: 'deep-investigation',
  description: 'Epic-preparation research harness: 1 Fable frames 5 investigation lanes → 5 Fable investigators → their data-needs pool into a ~25-Opus storm → routed back → each lane crunches everything and publishes an incredible preparation Paper → 1 Fable capstone links them. Papers only — no code, no builds.',
  whenToUse:
    'INVOKE: Workflow({scriptPath: ".claude/workflows/deep-investigation.workflow.js", args: {wish: "<the user\'s request, verbatim — REQUIRED>", interview: "<Q&A digest from step 0>", lead_notes: "<optional steering>", epic_task_id: "<optional task-… slug>", storm_size: 25}}) — always by scriptPath, never by name (the name registry is a session-start snapshot). Use it to prepare a POTENTIAL epic before any charter or build wave exists. STEP 0 — THE INTERVIEW, in the MAIN session BEFORE launching: the run is headless and can never reach the user, so ask 1-4 HIGH-VALUE questions via AskUserQuestion — the ones whose answers most change the framing (product intent, audience, platform constraints, scope ambition, taste) — and pass the digest as args.interview; skip only when the wish is already unambiguous on those axes. The point is that the run starts INFORMATION-RICH: Frame should inherit everything the session already holds — interview answers, known ground truth, prior epics, steering (args.lead_notes) — so it spends its judgment on lane design, not on rediscovering what the user could have just said. The crown paper is the deliverable, and it feeds bp-epic-cycle as strategize-phase raw material.',
  phases: [
    { title: 'Frame', detail: '1 Fable, unhurried: reads until reading stops changing its mind, weighs rival framings, cuts exactly 5 investigation lanes with rich missions', model: 'fable' },
    { title: 'Investigate', detail: '5 Fable investigators, read-only, one per lane: deep dig — bp search first, then the repo; each files 3-8 data_needs it wants the storm to fetch', model: 'fable' },
    { title: 'Dispatch', detail: '1 Fable: pools all data_needs, dedups/merges, designs the storm — 15-25 sharp Opus probes, each tagged with the lane(s) it serves', model: 'fable' },
    { title: 'Storm', detail: '15-25 Opus probes, read-only, ~5 min each: fetch exactly what the lanes asked for, with coverage accounting and rerun-carrying facts', model: 'opus' },
    { title: 'Crunch', detail: '5 Fable crunchers, one per lane, carrying the lane brief + its investigation + its storm findings: synthesize everything, then CREATE + PUBLISH the lane\'s preparation Paper', model: 'fable' },
    { title: 'Capstone', detail: '1 Fable, unhurried: reads all 5 published Papers end-to-end and writes THE CROWN PAPER — one large premium report that weaves the best of every lane into a single fantastic document; the 5 lane Papers become its supporting stack; optionally seeds a considering-state epic candidate task', model: 'fable' },
  ],
}

// args = { wish (REQUIRED), interview?, lead_notes?, epic_task_id?, storm_size?, frame_model?, lane_model?, storm_model? }
// Same defensive parse as bp-epic-cycle: args can arrive as a JSON STRING
// (workflow-args-string-trap), and a run without an explicit wish is a run
// investigating nothing in particular — refuse, never guess.
const A = (() => {
  if (typeof args === 'string') { try { return JSON.parse(args) } catch (e) { throw new Error('deep-investigation args is a non-JSON string') } }
  return args || {}
})()
if (!A.wish) throw new Error('deep-investigation requires an explicit args.wish')
const WISH = A.wish
const EPIC_TASK_ID = A.epic_task_id || null
const LEAD_NOTES = A.lead_notes ? `\n\nLEAD NOTES THIS RUN:\n${A.lead_notes}` : ''

// The shape IS the contract: 5 lanes, 5 investigators, 5 papers — exactly.
// Fewer lanes is a framing that didn't work hard enough; more dilutes each
// Fable's depth. The storm flexes 15-25 (target 25) because needs vary.
const LANE_COUNT = 5
const STORM_TARGET = Math.min(25, Math.max(15, Number(A.storm_size) || 25))
const STORM_FLOOR = 12
const NEEDS_FLOOR = 8 // pooled across all 5 lanes — below this the investigation didn't really reach for data

// Phase↔model doctrine (inherited from bp-epic-cycle, lead mandate rev 2):
// every THINKING role is Fable — here that is 12 of the 13 non-storm agents
// (frame, 5 investigators, dispatch, 5 crunchers, capstone). The storm is
// Opus — width fetching what the Fables asked for. Never Sonnet or Haiku (operator model policy 2026-08-31).
const FRAME_MODEL = A.frame_model || 'fable'
const LANE_MODEL = A.lane_model || 'fable'
const STORM_MODEL = A.storm_model || 'opus'

const USER_WISH_BLOCK = `THE USER'S WISH (this is the focus — everything serves it, judged holistically, not as a checklist):
"""
${WISH}
"""${A.interview ? `

THE INTERVIEW (the user answered these high-value questions before this run launched — their answers are user truth, senior to any inference below):
"""
${A.interview}
"""` : ''}`

const READ_ONLY_BLOCK = `READ-ONLY ON THE REPO, ALWAYS: this run prepares an epic, it does not build one. No edits, no commits, no branches, no worktrees, never touch main. The ONLY writes this run makes are Barkpark writes (Papers, and the optional capstone candidate task).`

const BP_SEARCH_BLOCK = `Search Barkpark FIRST: \`bp search query "<terms>"\` — the \`query\` sub-verb is REQUIRED; dropping it exits 2 with \`unknown command "search"\`, and that failure reads exactly like a real absence of prior art, so check the exit code. Papers and tasks carry prior art the tree doesn't.`

const PD_CRAFT_BLOCK = `PORTABLEDOC CRAFT (Papers are PortableDoc documents — use the palette, not just prose):
- The corpus defaults to two prose block types for 78% of all content (measured: /papers/portabledoc-potential-study). This run's Papers must NOT — they should read AND look premium.
- BEFORE authoring, derive the live palette from the system itself: \`bp search query "portabledoc showcase"\` and read the 91-block showcase paper, plus /papers/portabledoc-potential-study — together they show every block family that exists and which ones render beautifully in the reader (some families lack reader CSS; prefer proven ones — the showcase is the proof).
- Compose on the ladder Element · Widget · Section · Layout · Document (composition doctrine): real section structure, not one long scroll of paragraphs.
- Reach for the expressive families where they genuinely serve the material: callouts for decisions/risks/laws, tables and comparison tables for rival options, stat/metric widgets for measured numbers, mermaid diagrams for architecture and flows (labels DOUBLE-QUOTED — the TUI renderer requires it), code blocks for contracts and commands, and query/TaskResolver blocks where a LIVE view of the ledger beats a frozen list. Decoration for its own sake is bloat; an unbroken wall of prose is a failure the other way.
- Gotchas that 422/render-break: inline leaves use "value" not "text"; title + featured-image are ENFORCED body blocks (content-first doctrine); style=article always.
- After publishing, READ THE PAPER BACK and check the block structure actually landed as intended — never assume a write rendered.`

const PAPER_CONTRACT_BLOCK = `THE PAPER CONTRACT (every Paper this run creates follows it — no exceptions):
- style=article is MANDATORY (without it the render falls back to the ugly email look).
- \`bp doc create\` ignores stdin — create the doc with --set fields, then write/extend the body via the HTTP /v1/data/mutate path (patch merges into content), then \`bp doc publish\`. \`bp capabilities -o json\` shows the verbs this binary actually has.
- The publish wall requires a real description AND weighted tags: [{tag, strength 1-100, rationale}] with DISTINCT strengths (max strength = the main tag). Each tag MUST be a registered tag doc (\`bp doc ls tag\`) or publish 422s unknown_tag.
- Read the Paper BACK from the server after publishing before reporting paper_created=true — a stranded draft is not a Paper.
- Link Papers to each other by slug in the body (the capstone names all 5 lane Papers; each lane Paper names the capstone slug it will appear in).
- THE PUBLISH WALL (the ENFORCED dialect — teach it, do not fight it): any Paper carrying tag \`epic-cycle-wave-paper\` sits behind the publish wall (\`api/lib/barkpark/content/papers/epic_quality.ex\` on origin/main — the gate is exactly tag-scoped); this run's lane and crown Papers author to the same dialect whether or not they carry the tag. NEVER author an empty paragraph block anywhere — hard failure \`:empty_paragraph_spacer\`, checked over the NESTED block tree. Opening, within the first 8 meaningful blocks: exactly one h1 in the whole document, one \`ingress\` block, and one orientation block of byline|stats|toc|list|steps. No heading-level jumps. Ceilings: 80 top-level blocks, 16 top-level headings, 5000 primary words (closed expandables excluded). Tables carry \`head\`. A refused publish answers 422 code=invalid_epic_paper_quality with details.failures naming every failed gate — fix and re-publish (the bp CLI renders details). The spacer-doctrine ruling is owned by open task \`cchi-w67-bl-the-epic-paper-floor-forbids-the-spacing-doctrine\` (cch-instruments-epic): teach the ENFORCED dialect and cite that task; do not edit the wall.`

// ── Shared schema fragments (inherited from bp-epic-cycle, proven shape) ─────
const COVERAGE_ITEMS = {
  type: 'object', additionalProperties: false,
  required: ['path', 'checked_for', 'result', 'note'],
  properties: {
    path: { type: 'string', description: 'file (or bp paper/task id, or URL) you actually opened or grepped' },
    checked_for: { type: 'string', description: 'what you were looking for in it' },
    result: { type: 'string', enum: ['found', 'not_found', 'partial'], description: 'found = it was there; not_found = you looked and it is NOT there (that is a finding!); partial = some of it / ran out of time' },
    note: { type: 'string', description: 'the one-line takeaway (what you found, or what its absence means); empty string if nothing beyond result' },
  },
}

const FACT_ITEMS = {
  type: 'object', additionalProperties: false,
  required: ['claim', 'evidence'],
  properties: {
    claim: { type: 'string' },
    evidence: { type: 'string' },
    rerun: {
      type: 'string',
      description: 'OPTIONAL. The ONE literal shell command that re-derives this fact from scratch — e.g. `git show origin/main:path/to/file | sed -n 40,60p`, `bp capabilities -o json | jq …`, `grep -rn "needle" dir/`. This command, not your prose, decides the authority level the fact may be quoted at downstream. Leave it EMPTY rather than guessing: an empty rerun is an honest belief, a wrong one is a level-skip.',
    },
  },
}

const FACTS_DESCRIPTION = 'load-bearing facts you actually verified, never assumed. `git show origin/main:<path>` reads what is really on main (not your possibly-dirty checkout); a curl against a running host reads what is really deployed; both are cheap enough to be the default. A checkout file:line is a fine form too, but it is a claim about YOUR checkout only. Whichever form you used, put the command that re-derives it in that fact\'s rerun field.'

const FRAME_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['framing', 'framing_debate', 'paper_slug_prefix', 'lanes'],
  properties: {
    framing: { type: 'string', description: 'how you chose to cut the problem: the grand view, what the finished investigation must let the user decide, and why THESE five lanes cover it' },
    framing_debate: { type: 'string', description: 'the rival lane-cuts you seriously developed and argued against each other, why the winner won, and the sharpest attack on it — a framing that never faced a rival is usually the first idea, not the best one' },
    paper_slug_prefix: { type: 'string', description: 'short kebab-case prefix all Papers in this run share (e.g. "barkpark-tasks-mobile") so the family is greppable in bp search' },
    lanes: {
      type: 'array', minItems: 5, maxItems: 5,
      description: 'EXACTLY 5 investigation lanes — each becomes one Fable investigator now and one Fable cruncher+Paper later. Together they must cover the wish holistically; individually each must be deep enough to deserve a Fable.',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'title', 'mission', 'questions', 'why', 'suspected_sources'],
        properties: {
          key: { type: 'string', description: 'short kebab-case label — becomes the Paper slug suffix' },
          title: { type: 'string', description: 'the lane as a Paper title a human wants to read' },
          mission: { type: 'string', description: 'a rich brief: what this lane must understand, what its Paper must let the user decide, what "done" looks like' },
          questions: { type: 'array', items: { type: 'string' }, description: 'the concrete questions the investigator starts from (it may grow more)' },
          why: { type: 'string', description: 'how this lane serves the wish and what breaks if it is skipped' },
          suspected_sources: { type: 'array', items: { type: 'string' }, description: 'files, dirs, bp papers/tasks, docs cards, endpoints the investigator should hit first' },
        },
      },
    },
  },
}

const INVESTIGATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'emerging_shape', 'coverage', 'facts', 'data_needs', 'open_questions'],
  properties: {
    key: { type: 'string' },
    findings: { type: 'string', description: 'what you established about your lane, honestly — including "the premise is wrong" when it is' },
    emerging_shape: { type: 'string', description: 'the draft thesis of your future Paper: what you currently believe should be created, and the strongest evidence for and against it — the cruncher (your future self) starts from this' },
    coverage: { type: 'array', description: 'EVERY file/paper/task you checked — path, what you checked it for, found/not_found/partial. Not-found is evidence too; unlisted = unchecked', items: COVERAGE_ITEMS },
    facts: { type: 'array', description: FACTS_DESCRIPTION, items: FACT_ITEMS },
    data_needs: {
      type: 'array', minItems: 2, maxItems: 8,
      description: '3-8 things you WANT FETCHED but should not burn your own depth on — mapping sweeps, inventories, cross-surface greps, external references. These become Opus storm probes; write each so an agent with none of your context can nail it.',
      items: {
        type: 'object', additionalProperties: false,
        required: ['need', 'why', 'sources_hint'],
        properties: {
          need: { type: 'string', description: 'a concrete, self-contained fetch task — name the exact question and what a complete answer contains' },
          why: { type: 'string', description: 'what in your Paper this unblocks' },
          sources_hint: { type: 'string', description: 'where to look — dirs, files, bp queries, endpoints; empty string if genuinely unknown' },
        },
      },
    },
    open_questions: { type: 'array', items: { type: 'string' }, description: 'what you could NOT settle and the storm cannot fetch either — judgment calls for the Paper to weigh openly' },
  },
}

const DISPATCH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['synthesis', 'probes'],
  properties: {
    synthesis: { type: 'string', description: 'cross-lane read: where lanes overlap, contradict, or leave gaps; which needs you merged/dropped and why; what the storm must come back with for the crunch to succeed' },
    probes: {
      type: 'array', minItems: 12, maxItems: 25,
      description: 'the storm: 15-25 sharp Opus probes (target 25). Merge duplicate needs across lanes into one probe tagged with every lane it serves; split needs too big for ~5 minutes; add gap-filling probes the lanes missed.',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'lanes', 'question', 'why', 'sources_hint'],
        properties: {
          key: { type: 'string', description: 'short kebab-case label' },
          lanes: { type: 'array', items: { type: 'string' }, description: 'lane key(s) this probe serves — its findings route back to exactly these crunchers ("all" is valid for cross-cutting probes)' },
          question: { type: 'string', description: 'concrete and self-contained — an Opus with no other context must be able to nail it' },
          why: { type: 'string' },
          sources_hint: { type: 'string', description: 'where to look first; empty string if unknown' },
        },
      },
    },
  },
}

const PROBE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'findings', 'coverage', 'facts', 'open_questions'],
  properties: {
    key: { type: 'string' },
    findings: { type: 'string', description: 'the answer, honestly — including "the premise is wrong" when it is' },
    coverage: { type: 'array', description: 'EVERY file/paper/task you checked — path, what you checked it for, found/not_found/partial. Not-found is evidence too; unlisted = unchecked', items: COVERAGE_ITEMS },
    facts: { type: 'array', description: FACTS_DESCRIPTION, items: FACT_ITEMS },
    open_questions: { type: 'array', items: { type: 'string' }, description: 'what you could not settle in the timebox' },
  },
}

const CRUNCH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['key', 'paper_id', 'paper_created', 'thesis', 'files_likely_touched', 'risks', 'open_questions'],
  properties: {
    key: { type: 'string' },
    paper_id: { type: 'string', description: 'slug of the PUBLISHED lane Paper (style=article) — read back from the server' },
    paper_created: { type: 'boolean', description: 'true only after you created AND published the Paper and read it back from the server' },
    thesis: { type: 'string', description: 'the Paper\'s core proposal in a paragraph — what should be created and why this shape wins' },
    files_likely_touched: { type: 'array', items: { type: 'string' }, description: 'repo-relative paths (or path prefixes ending /) a future build wave would likely change — mirrors the Paper\'s files section' },
    risks: { type: 'array', items: { type: 'string' } },
    open_questions: { type: 'array', items: { type: 'string' }, description: 'the judgment calls the Paper leaves explicitly to the user/epic strategist' },
  },
}

const CAPSTONE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['capstone_paper_id', 'paper_created', 'executive_summary', 'recommendation', 'papers', 'candidate_task_id', 'craft_report'],
  properties: {
    capstone_paper_id: { type: 'string', description: 'slug of the PUBLISHED crown Paper — the large premium synthesis report' },
    craft_report: { type: 'string', description: 'which PortableDoc block families the crown Paper uses and why each earns its place (diagrams, comparison tables, callouts, stat widgets, live query blocks, …) — proof the appealing-mandate was met, confirmed by reading the published Paper back as a reader' },
    paper_created: { type: 'boolean', description: 'true only after published AND read back' },
    executive_summary: { type: 'string', description: 'the grand view in a page: what was learned, where the lanes agree/disagree, what should happen next — a compression of the crown Paper, never a substitute for it' },
    recommendation: { type: 'string', description: 'the honest go/no-go/go-differently call on the potential epic, with the reasoning that earns it' },
    papers: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'paper_id', 'one_liner'],
        properties: { key: { type: 'string' }, paper_id: { type: 'string' }, one_liner: { type: 'string' } },
      },
    },
    candidate_task_id: { type: 'string', description: 'slug of the considering-state epic candidate task you filed (task-funnel doctrine), or "skipped: <why>" — a 4xx you cannot resolve in two attempts is a valid why; never fight the write contract' },
  },
}

// ── Structural self-check — every declared required key must exist (a green
// `node --check` once hid a brace that moved keys out of a schema; a schema
// whose `required` names an undefined key is a contract the host can never
// satisfy). Throws at module scope, before a single agent is spent.
for (const [name, schema] of [
  ['FRAME_SCHEMA', FRAME_SCHEMA], ['INVESTIGATE_SCHEMA', INVESTIGATE_SCHEMA], ['DISPATCH_SCHEMA', DISPATCH_SCHEMA],
  ['PROBE_SCHEMA', PROBE_SCHEMA], ['CRUNCH_SCHEMA', CRUNCH_SCHEMA], ['CAPSTONE_SCHEMA', CAPSTONE_SCHEMA],
]) {
  for (const key of schema.required || []) {
    if (!Object.prototype.hasOwnProperty.call(schema.properties || {}, key)) {
      throw new Error(`${name} declares required key '${key}' but does not define it in properties — a brace or edit moved it out of the schema. Fix the schema; do not proceed.`)
    }
  }
}
for (const [name, schema] of [['INVESTIGATE_SCHEMA', INVESTIGATE_SCHEMA], ['PROBE_SCHEMA', PROBE_SCHEMA]]) {
  const props = schema.properties?.facts?.items?.properties || {}
  if (!props.rerun) throw new Error(`${name}.facts[].rerun is missing — the fact-level provenance carrier was dropped.`)
  if ((schema.properties.facts.items.required || []).includes('rerun')) {
    throw new Error(`${name}.facts[].rerun must stay OPTIONAL (a missing command DEMOTES the fact, it never rejects it).`)
  }
}

// ── Provenance gate (inherited verbatim from bp-epic-cycle): demote, never
// drop. A fact without a rerun command is an honest belief, not a measurement;
// the demotion rides ON the fact so every downstream Fable SEES it.
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
      fact.provenance = 'DEMOTED-NO-RERUN'
      fact.provenance_note = 'no rerun command on this fact — it cannot be re-derived; treat it as an unverified belief and never quote it above the level of agent memory. Add a one-line rerun command and it levels up in ten seconds.'
    }
  }
  return { total, demoted }
}

// ── Phase 1: Frame — one Fable mind cuts the problem into exactly 5 lanes ────
phase('Frame')
const frame = await agent(
  `You are the FRAMER of a Barkpark deep investigation — one Fable mind whose lane-cut sets the CEILING for the whole run. This run BUILDS NOTHING: its deliverable is five deep, evidence-grounded preparation Papers plus a capstone, good enough that a future epic strategist can start from them instead of from zero. Your job is to figure out what five Fable investigators should each go deep on.

${USER_WISH_BLOCK}

${READ_ONLY_BLOCK}

WORK THE PROBLEM PROPERLY, in whatever order serves you:
- GROUND: read until further reading stops changing your mind. ${BP_SEARCH_BLOCK} Then read the real surfaces the wish touches — CLAUDE.md routes, docs cards, the actual code seams. A lane-cut made on an unread codebase is a guess.
- DELIBERATE: develop at least two genuinely different ways to cut this into 5 lanes and argue them against each other — by surface? by user journey? by product-shape candidate? by risk? Then COMMIT to one cut. Record the debate.
- COVER HOLISTICALLY: together the 5 lanes must cover everything the wish needs decided; individually each must be deep enough to deserve a Fable and to become a Paper someone actually wants to read. Product-shape questions (rival visions, what to build) and ground-truth questions (how the system works today, what constrains us) BOTH need a home.

Your output:
1. framing — the grand view and why these five lanes cover it.
2. framing_debate — the rival cuts, why the winner won, the sharpest attack on it.
3. paper_slug_prefix — short kebab-case prefix for the whole Paper family.
4. lanes — EXACTLY 5, each with key, title, a rich mission (what its Paper must let the user decide), starter questions, why, and suspected_sources (be generous — you have read the repo, the investigators start from your pointers).
${LEAD_NOTES}`,
  { label: 'frame', phase: 'Frame', schema: FRAME_SCHEMA, model: FRAME_MODEL }
)
const lanes = (frame.lanes || []).slice(0, LANE_COUNT)
if (lanes.length < LANE_COUNT) {
  throw new Error(`Lane floor: the framer returned ${lanes.length} lane(s); the contract is exactly ${LANE_COUNT}. A narrower cut under-covers the wish — re-run Frame rather than proceeding.`)
}
log(`Framer cut 5 lanes [${lanes.map((l) => l.key).join(', ')}], paper family "${frame.paper_slug_prefix}"`)

// ── Phase 2: Investigate — 5 Fable minds, one per lane, deep and read-only ───
phase('Investigate')
const investigations = (await parallel(
  lanes.map((lane) => () =>
    agent(
      `You are a LANE INVESTIGATOR on a Barkpark deep investigation — one of 5 Fable minds, each owning one lane. Go DEEP: your later self (the cruncher) will write this lane's Paper from what you establish now plus what an Opus storm fetches for you. Nothing is built this run.

${USER_WISH_BLOCK}

${READ_ONLY_BLOCK}

THE FRAMING (from the framer — your lane exists inside this grand view):
${frame.framing}

YOUR LANE [${lane.key}] — ${lane.title}
MISSION: ${lane.mission}
WHY IT MATTERS: ${lane.why}
STARTER QUESTIONS:
${(lane.questions || []).map((q) => `- ${q}`).join('\n')}
SUSPECTED SOURCES: ${(lane.suspected_sources || []).join(', ') || '(none — you scout)'}

${BP_SEARCH_BLOCK} Then read the repo for real — file:line anchors, not vibes. "The premise is wrong" is a valid and valuable finding. Every load-bearing fact needs evidence you actually derived, and its \`rerun\` command.

SPEND YOUR DEPTH WISELY — you have an Opus storm at your service. Anything that is WIDE rather than DEEP (inventories, cross-surface greps, endpoint censuses, prior-art sweeps, external references) goes into data_needs (3-8 of them, each written so an agent with NONE of your context can nail it — name the question, the shape of a complete answer, and where to look). Keep your own time for the judgment-heavy digging only a Fable can do.

COVERAGE ACCOUNTING: list EVERY file/paper/task you checked in coverage[] — path, what for, found/not_found/partial. NOT-FOUND IS A FINDING. Unlisted = unchecked.

End with emerging_shape: the draft thesis of your future Paper — what you currently believe should be created, with the strongest evidence for AND against. Your cruncher starts from it.`,
      { label: `investigate:${lane.key}`, phase: 'Investigate', schema: INVESTIGATE_SCHEMA, model: LANE_MODEL }
    )
  )
)).filter(Boolean)
if (investigations.length < LANE_COUNT) {
  log(`WARNING: only ${investigations.length}/${LANE_COUNT} investigators reported — their lanes proceed with what returned; the capstone must name the gap`)
}
const investGrip = gateFactProvenance(investigations)
const totalNeeds = investigations.reduce((n, r) => n + (r.data_needs || []).length, 0)
if (totalNeeds < NEEDS_FLOOR) {
  throw new Error(`Data-needs floor: the 5 investigators pooled only ${totalNeeds} data_needs (floor ${NEEDS_FLOOR}). An investigation that asks the storm for almost nothing either didn't dig or is hoarding width the storm should fetch. Re-run Investigate rather than starving the storm.`)
}
log(`${investigations.length}/${LANE_COUNT} investigators reported; ${totalNeeds} pooled data_needs; provenance gate: ${investGrip.demoted}/${investGrip.total} fact(s) DEMOTED (no rerun)`)

// ── Phase 3: Dispatch — one Fable pools the needs and designs the storm ──────
// Barrier justified: dedup/merge across ALL lanes' needs before spending 25 storm probes.
phase('Dispatch')
const dispatch = await agent(
  `You are the STORM DISPATCHER of a Barkpark deep investigation — one Fable mind holding all 5 lanes' investigation reports. The 5 investigators each filed data_needs: things they want FETCHED before they write their Papers. You design the storm that fetches it all.

${USER_WISH_BLOCK}

THE FRAMING:
${frame.framing}

INVESTIGATION REPORTS (5 lanes — findings, emerging Paper theses, and their data_needs):
${JSON.stringify(investigations, null, 2)}

Your job:
1. SYNTHESIZE across lanes: where do they overlap, contradict each other, or jointly leave a gap no lane owns? Contradictions between lanes are the most valuable thing you can surface — the crunchers must not write 5 papers that silently disagree.
2. DESIGN THE STORM: ${STORM_FLOOR}-${STORM_TARGET} Opus probes (target ${STORM_TARGET}).
   - MERGE duplicate/overlapping needs across lanes into one probe tagged with every lane key it serves (lanes: ["a","b"], or ["all"] for cross-cutting).
   - SPLIT needs too big for a ~5-minute read-only probe.
   - ADD probes for the cross-lane gaps and contradictions YOU found — the lanes cannot see each other; you can.
   - Every probe must be self-contained: a probe agent with zero other context must be able to nail it. Name the question, the shape of a complete answer, and sources_hint.
   - Honor every lane's needs — a lane whose needs you silently drop writes a starved Paper. If you drop or fold a need, say so in the synthesis.`,
  { label: 'dispatch', phase: 'Dispatch', schema: DISPATCH_SCHEMA, model: FRAME_MODEL }
)
if (!dispatch) throw new Error('Dispatch phase returned no result (agent died — check auth/spend); resume the run rather than restarting')
const probes = (dispatch.probes || []).slice(0, STORM_TARGET)
if (probes.length < STORM_FLOOR) {
  throw new Error(`Storm floor: the dispatcher returned ${probes.length} probe(s), below the floor of ${STORM_FLOOR}. The storm is the run's entire width — a thin storm starves five Papers at once. Re-run Dispatch with a real storm (${STORM_FLOOR}-${STORM_TARGET} probes).`)
}
log(`Dispatcher designed ${probes.length} storm probes`)

// ── Phase 4: Storm — the Opus probes fetch what the lanes asked for ─────────
phase('Storm')
const stormReports = (await parallel(
  probes.map((p) => () =>
    agent(
      `You are a STORM PROBE on a Barkpark deep investigation — one of ${probes.length} Opus probes in a wide fetch sweep serving 5 Fable paper-writers. READ-ONLY: no edits, no commits, no bp mutations. Budget: ~5 minutes — a fast honest answer with real file:line anchors beats a deep dive.

${USER_WISH_BLOCK}

YOUR PROBE [${p.key}] (serves lane(s): ${(p.lanes || []).join(', ')}): ${p.question}
WHY IT MATTERS: ${p.why}
WHERE TO LOOK FIRST: ${p.sources_hint || '(unknown — scout, and say where you looked)'}

${BP_SEARCH_BLOCK} Then grep/read the repo. Answer honestly — "the premise is wrong" and "it does not exist" are valid, valuable answers. Every load-bearing fact needs evidence you actually derived plus its \`rerun\` command.

COVERAGE ACCOUNTING: list EVERY file/paper/task you checked in coverage[] — path, what for, found/not_found/partial. NOT-FOUND IS A FINDING. Unlisted = unchecked. Park what you can't settle in open_questions.`,
      { label: `storm:${p.key}`, phase: 'Storm', schema: PROBE_SCHEMA, model: STORM_MODEL }
    ).then((r) => (r ? { ...r, lanes: p.lanes || [], question: p.question } : null))
  )
)).filter(Boolean)
const stormGrip = gateFactProvenance(stormReports)
log(`${stormReports.length}/${probes.length} storm probes reported; provenance gate: ${stormGrip.demoted}/${stormGrip.total} fact(s) DEMOTED (no rerun)`)

// Route storm findings back per lane. A probe tagged "all" (or with no tags —
// defensive: an untagged report must not vanish) reaches every cruncher.
const stormForLane = (key) => stormReports.filter((r) => {
  const ls = r.lanes || []
  return ls.length === 0 || ls.includes('all') || ls.includes(key)
})

// ── Phase 5: Crunch — 5 Fable minds write the Papers ─────────────────────────
// Barrier justified upstream (storm must complete to be routed); the 5
// crunchers themselves run concurrently — they write DIFFERENT Papers and
// never share a document, so no clobbering (the paper-per-worker law).
phase('Crunch')
const investByKey = {}
for (const r of investigations) investByKey[r.key] = r
const crunches = (await parallel(
  lanes.map((lane) => () => {
    const inv = investByKey[lane.key] || null
    const stormSlice = stormForLane(lane.key)
    return agent(
      `You are a LANE CRUNCHER on a Barkpark deep investigation — the same Fable judgment that investigated lane [${lane.key}], now holding everything: your investigation, the cross-lane synthesis, and the storm findings fetched for you. Your deliverable is this lane's PREPARATION PAPER — published in Barkpark, detailed enough that a future epic wave can start from it instead of from zero. Nothing is built this run.

${USER_WISH_BLOCK}

${READ_ONLY_BLOCK}

YOUR LANE [${lane.key}] — ${lane.title}
MISSION (the Paper must fulfil it): ${lane.mission}

YOUR OWN INVESTIGATION (phase 2 — start from its emerging_shape, but you may overturn it if the storm evidence demands):
${JSON.stringify(inv, null, 2)}

CROSS-LANE SYNTHESIS (from the dispatcher — where the 5 lanes overlap, contradict, or leave gaps; your Paper must not silently disagree with a sibling lane on a shared fact):
${dispatch.synthesis}

STORM FINDINGS ROUTED TO YOUR LANE (${stormSlice.length} probe reports — trust file:line evidence over prose; any fact carrying provenance DEMOTED-NO-RERUN is an unverified belief, never a settled measurement):
${JSON.stringify(stormSlice, null, 2)}

WRITE AND PUBLISH THE PAPER (slug: ${frame.paper_slug_prefix}-${lane.key}, style=article). It must contain, in whatever structure serves the material best:
- WHAT WE WILL CREATE — the proposed shape: the experience, the architecture, the key choices with the reasoning that earns them. Where genuinely rival options survive the evidence, present the rivals honestly with your recommendation — decided where the evidence decides, open where it doesn't.
- WHAT WE LEARNED — the evidence-backed findings, including the surprises and the premises that turned out wrong.
- HOW THE SYSTEM WORKS TODAY — the mechanics that constrain the design, with file:line anchors a builder can jump to.
- FILES LIKELY TO CHANGE — a concrete list: path, why it changes, blast-radius note. This mirrors files_likely_touched in your report.
- RISKS & UNKNOWNS — honest, including the judgment calls you explicitly leave to the user.
- COVERAGE APPENDIX — what was checked and found, and JUST AS PROMINENTLY what was checked and NOT found (absences are decisions-in-waiting), distilled from your and the storm's coverage[].
Name the capstone slug (${frame.paper_slug_prefix}-capstone) in the body — the capstone will name yours back.
${PD_CRAFT_BLOCK}
${PAPER_CONTRACT_BLOCK}

Verify anything load-bearing that smells off before printing it — you may grep/read the repo freely; you may NOT edit it. Set paper_created=true only after publish + server read-back.`,
      { label: `crunch:${lane.key}`, phase: 'Crunch', schema: CRUNCH_SCHEMA, model: LANE_MODEL }
    )
  })
)).filter(Boolean)
log(`${crunches.length}/${LANE_COUNT} lane Papers reported: ${crunches.map((c) => `${c.key}=${c.paper_id}(created=${c.paper_created})`).join(', ')}`)

// ── Phase 6: Capstone — one Fable reads all 5 Papers and ties the grand view ─
phase('Capstone')
const capstone = await agent(
  `You are the CAPSTONE of a Barkpark deep investigation — one Fable mind, the last, holding the whole run, taking whatever time this needs. Five lane Papers now exist. Your deliverable is THE CROWN PAPER: one large, premium, incredibly valuable report that COMBINES the papers — it takes the best material, the sharpest evidence, and the strongest proposals from every lane and weaves them into a single fantastic document that stands on its own. The five lane Papers become its supporting stack: a reader gets the whole story from the crown Paper alone, and descends into a lane Paper only when they want that lane's full depth. This is the goal of the entire run — everything before you existed to make this one document possible. Read the lane Papers ALL end-to-end from the server (bp — never trust the summaries below over the published text) before writing a word.

${USER_WISH_BLOCK}

${READ_ONLY_BLOCK}

THE FRAMING (how the run was cut): ${frame.framing}
LANE PAPERS (read each fully from bp):
${JSON.stringify(crunches.map((c) => ({ key: c.key, paper_id: c.paper_id, paper_created: c.paper_created, thesis: c.thesis })), null, 2)}
${crunches.length < LANE_COUNT ? `MISSING LANES (investigator or cruncher died): ${lanes.filter((l) => !crunches.some((c) => c.key === l.key)).map((l) => l.key).join(', ')} — the capstone must name this gap honestly, never paper over it.` : ''}

Your job:
1. READ all lane Papers end-to-end. Where two Papers disagree on a shared fact or jointly leave a seam uncovered, resolve it (re-derive from the repo if needed) or record the disagreement openly.
2. WRITE AND PUBLISH THE CROWN PAPER (slug: ${frame.paper_slug_prefix}-capstone, style=article) — a LARGE, standalone, premium report, not an index. It synthesizes, it does not merely link:
   - THE GRAND VIEW — the whole product story in one coherent narrative: the wish, what the investigation established, the vision that emerged.
   - THE BEST OF EVERY LANE, woven in — the strongest proposals, the decisive evidence, the killer findings, rewritten into ONE voice and ONE argument; credit each lane Paper by slug where its material appears so the reader can descend for depth.
   - THE PROPOSED SHAPE — what should be created: experience, architecture, the key choices with the reasoning that earns them; rival options presented honestly where the evidence leaves them alive.
   - GROUND TRUTH — how the system works today (the constraining mechanics, with file:line anchors), consolidated from all lanes into one map.
   - THE CONSOLIDATED FILES-LIKELY-TO-CHANGE PICTURE — merged across lanes, deduplicated, with blast-radius notes.
   - CONTRADICTIONS & RESOLUTIONS — where lanes disagreed and how you resolved it (or why it stays open).
   - RISKS, UNKNOWNS, AND THE RECOMMENDATION — go / no-go / go-differently on the potential epic, what the first wave should take if it goes, and the judgment calls left explicitly to the user.
   Quality bar: premium — this Paper is the run's true deliverable: a perfect, well-researched answer to the user's wish that EXPANDS on every useful detail rather than compressing it away. It should read like the best strategy document the user owns on this topic. Structure, prose, and evidence density all matter; padding does not.
   MAKE IT APPEALING — PortableDoc at its highest level: this Paper must also be the best-LOOKING document in the family. Architecture and the onboarding cascade want mermaid diagrams; the rival product shapes want a real comparison table; decisions and risks want callouts; measured numbers want stat widgets; the paper map wants structure a reader can navigate. Use the full proven palette (see PORTABLEDOC CRAFT below) and report what you used and why in craft_report. A crown paper that renders as a wall of paragraphs has failed half its mandate.
3. FIX any lane Paper that is a stranded draft (published=false in the reports above): publish it if the content is real; report what you did.
4. SEED THE FUNNEL (task-funnel doctrine: considering precedes open): file ONE epic-candidate bp task in a considering/research state — title from the wish, description pointing at the capstone + 5 Papers, parent ${EPIC_TASK_ID || '(none — top-level)'}. Try \`bp task create\` first, fall back to \`bp doc create task …\` + publish; \`bp capabilities -o json\` shows the verbs. If the write contract fights you (4xx twice), report candidate_task_id as "skipped: <why>" — the Papers are the deliverable, the task is a courtesy.
5. FINAL READER PASS: open the published crown Paper from the server one last time and read it AS THE USER WILL — top to bottom. Fix anything that reads or renders below premium (broken blocks, orphaned sections, a table that should be a diagram) and re-publish before reporting.
${PD_CRAFT_BLOCK}
${PAPER_CONTRACT_BLOCK}
${LEAD_NOTES}`,
  { label: 'capstone', phase: 'Capstone', schema: CAPSTONE_SCHEMA, model: FRAME_MODEL }
)
if (!capstone) throw new Error('Capstone phase returned no result (agent died — check auth/spend); resume the run rather than restarting')

return {
  framing: frame.framing,
  framing_debate: frame.framing_debate,
  paper_family: frame.paper_slug_prefix,
  lanes: lanes.map((l) => l.key),
  investigations: investigations.length,
  storm_probes: stormReports.length,
  facts_demoted: investGrip.demoted + stormGrip.demoted,
  papers: crunches.map((c) => ({ key: c.key, paper_id: c.paper_id, created: c.paper_created, thesis: c.thesis, files_likely_touched: c.files_likely_touched, risks: c.risks, open_questions: c.open_questions })),
  capstone_paper: capstone.capstone_paper_id,
  executive_summary: capstone.executive_summary,
  recommendation: capstone.recommendation,
  candidate_task_id: capstone.candidate_task_id,
}
