# Source-of-Truth Grip — epic charter

<!-- doc-tier: agent | canonical-for: source-of-truth-grip-epic | budget: 14000tok -->

## Vision

Every wrong value this session produced was a LEVEL-SKIP: reading at one authority level and
claiming at a higher one. `tooling/grip/` is the substrate that makes that structurally
impossible — one small, fast, LLM-free adjudicator standing between any produced fact and any
durable store, answering in the doctrine's own vocabulary with a nonzero exit and a named reason.

The load-bearing inversion: **authority level is DERIVED by a program from the shape of the
command that re-derives the fact, and can never be raised by what the author claims.** A
self-reported level is an L6 claim about an L1 fact — the laundering the doctrine exists to
prevent, wearing the doctrine's own uniform.

The ratified authority hierarchy (`/papers/survey-once-build-forever`):

| Level | What it is |
|---|---|
| L1 | running system — served bytes, live DB, box HEAD, a real click |
| L2 | `origin/main` |
| L3 | local checkout — a CLAIM about L2; has run 200+ commits stale and lied silently |
| L4 | generated artifacts — openapi.json, token layer, goldens |
| L5 | charters / docs / cards — a CLAIM about L2 |
| L6 | agent memory / the wish — a CLAIM about L5, drifts most |

The four rules the substrate enforces: **R1** a fact records the level it was read at and may
never be quoted above it. **R2** a fact records its DEPENDENCIES, not just its subject. **R3** no
fact is stored without a demonstration the method COULD have answered differently — rejection at
WRITE time, not review time. **R4** conflicting facts are BOTH stored and flagged, never resolved
by write order.

**The anti-goal, ratified and binding:** the ledger is NOT a substitute for verification, it is an
INDEX OF HOW TO VERIFY FAST. Facts are leads to re-check cheaply, never settled truth. Survey must
NOT spend fewer agents — same surveyor count, better questions. Spending less is how the
adversarial layer quietly dies.

**Order is load-bearing:** provenance schema FIRST, controls as a write-time gate SECOND,
verify-writes-back THIRD, survey-reads-leads LAST. If wave 1 ships only the gate and stores
NOTHING, it has succeeded. A corpus that earns trust from its first row beats a corpus with trust
bolted on afterward, which is worth nothing.

## Decisions

- **D1 — The grammar levels the COMMAND, never the prose.** A new structured `rerun` field holds
  one literal shell command; the `evidence` narrative is L6 by construction and can never raise a
  level. *Why: a prose-scanning extractor scored L1 and L2 precision at 0.67 against 60
  hand-labelled real strings and promoted the text "OPEN — requires a run against the deployed
  build" to L1 — the disease wearing the doctrine's uniform.*

- **D2 — Level is DERIVED from the command's head and shape, and the derived level is a CEILING.**
  L1 = `ssh <user>@<host>` or `curl <scheme>://<non-loopback-host>`; L2 = `git show <ref>:<path>`
  or `gh api`; L3 = local read, scoped grep, local test run, `node <script>`; L4 = a read of a
  known generated-artifact path; L6 = no command. *Why: the author's claim becomes a hypothesis
  the gate tests, which is the only arrangement where compliance is not required for correctness.*

- **D3 — No rerun command means DEMOTED to L6, never REJECTED.** *Why: the briefed grammar
  defaulted 67.7% of real honest evidence to L6 against a true rate near 13.7%; a gate that
  punishes honest work gets routed around within a wave, so the honest path must be the cheap one
  and the fix must take ten seconds.*

- **D4 — The gate RE-EXECUTES the literal command and requires the claimed observable to
  reproduce. Its verdict wording is "re-derived just now", never "verified read".** *Why: a
  syntactically perfect curl the author never ran passed both the grammar and re-execution — the
  gate certifies RE-DERIVABILITY, never authorship, and any wording implying otherwise is itself
  the level-skip.*

- **D5 — Reachability keys on the (http_code, exit_code) PAIR, and a probe that cannot run yields
  a third verdict UNAVAILABLE — never a pass, never a rejection.** *Why: 404+exit0 (wrong route)
  and 000+exit28 (host down) collapse into "non-200", letting a network outage forge a pass-shaped
  absence claim; and ssh is a laptop property — guerrilla answers, `89.167.28.206` denies with the
  same key, and CI has neither.*

- **D6 — An empty or failed read is NULL-READ, a distinct verdict, and may never become an
  admissible negative claim.** *Why: the "0-byte fixture" reading had no 0-byte artifact anywhere
  on disk across 993 worktrees or on origin/main — a read returned empty and an agent stored it as
  a fact.*

- **D7 — Only DISCRETE predicates are admissible.** A fact whose re-derivation yields a
  distribution must declare a predicate or be inadmissible. *Why: one L1 command returned a stable
  code=200 while t_total drifted 0.116 / 0.135 / 0.118 across three runs — R4 would fire forever
  on noise.*

- **D8 — Synchronous admission requires a FACT-SCOPED command AND a warm toolchain; corpus-wide
  and cold-Elixir commands are ASYNC-DEFERRED at their derived level.** *Why: `git show` is
  94-337ms and scoped grep 149ms, but a first targeted `mix test` in a fresh worktree costs 81.74s
  because Elixir compiles all 800 files — build warmth is a third input the "scope decides, not
  tool" rule missed.*

- **D9 — A path-less line reference is REJECTED.** *Why: `notifications.ex:389-397` sent a
  verifier to `api/lib` and returned empty; the real file was
  `cloud/lib/barkpark_cloud/notifications.ex`.*

- **D10 — NOTHING is stored durably this wave. `tooling/research-coverage` is NOT joined, and is
  BLOCKED as a wave-2 target until its ledger is reproducible.** *Why: the same command at the
  same commit reports 50.1% in the main checkout and 0% in a clean worktree because
  `research-ledger.json` is gitignored; `record()` strips unknown fields (proven by mutation) and
  two writers staggered inside an ~11s window silently lose one's entire contribution (proven).*

- **D11 — `tooling/doc-truth` is reused for METHODOLOGY and its path/lineref verifier only, with
  NO authority.** *Why: it self-declares "a LEAD GENERATOR, not an authority" at
  `verify-docs.mjs:14`, its `verifyCommand` "confirmed" four guaranteed-to-fail commands because
  curl/git/mix resolve on PATH, and its only root is `git rev-parse --show-toplevel` — it tops out
  at L3 and has no level concept.*

- **D12 — The adversarial fixture is SIX ratified specimens, each LABELLED with the rule that
  catches it; unratified specimens are labelled UNCAUGHT.** *Why: the ratified table has six rows,
  not seven, and 420px-vs-340px is a unit/identity confusion at one level that R1 structurally
  cannot catch — labelling the gap honestly is the anti-vacuity discipline.*

- **D13 — The evidence corpus is snapshotted INTO `tooling/grip/fixtures/` with its harvest
  command stored beside it.** *Why: 29,959 real evidence strings live only under `~/.claude`,
  outside the repo, unbacked-up and prunable — an unfrozen quarry evaporates.*

- **D14 — The schema change is a `rerun` field ON `facts[]`, not a second array; SURVEY_SCHEMA
  gets it too.** *Why: `proofs[]` already carries command+output 7,623 times but its `claim` joins
  a `fact.claim` only 0.3% of the time — two parallel arrays with no key — and SURVEY_SCHEMA has
  no command carrier at all, so survey is where the gate is blind.*

- **D15 — The never-fewer-agents floor is a JS `throw`, not schema `minItems`.** *Why: the throw
  path is certain and precedented at `bp-epic-cycle.workflow.js:27`; whether the host validator
  honors `minItems` is unproven and cannot be proven without running a wave.*

- **D16 — `bp search "<terms>"` is corrected to `bp search query "<terms>"` at both root
  sources.** *Why: the bare form exits 2 with a usage error, and at least five prior waves
  independently rediscovered it and silently lost prior-art coverage that reads exactly like a
  real absence.*

- **D17 — The gate ships as an importable ESM module plus a CLI; the workflow seam is a later
  round whose FIRST obligation is probing whether workflow files may `import`.** *Why: all three
  workflow files have zero fs/exec/require, so in-JS adjudication is the only enforcement
  available today — but no workflow uses `import`, so that capability is unproven, and `main` has
  no branch protection or rulesets, which makes a CI-only grip job advisory theatre.*

- **D18 — Every gate carries an inline `--selftest` and a THIRD outcome class for a control that
  did not fire.** *Why: seven scripts in this repo already prove guards by plant-and-rescan
  mutation, and `pds-secret-scan.sh`'s exit-3 "CONTROL DID NOT BEHAVE AS A CONTROL" is exactly the
  DEMOTED idea in miniature — a non-firing control must never be absorbed into a normal pass.*

- **D19 — A workflow file may NEVER `import`, `require`, `eval`, or read the clock. This is
  permanent host design, not a gap, and NO capability task is filed against it.** *Why: the host
  evaluator, extracted verbatim from the compiled binary and reproduced locally, parses with acorn
  in module mode then compiles the body with `vm.Script` — a classic script, never a module — so
  static `import` dies at compile with "Cannot use import statement outside a module"; dynamic
  `import()` hits a hand-written `importModuleDynamically:()=>{throw sNe("import() is not available
  in workflow scripts.")}`; `require` is undefined; and `createContext(…,{codeGeneration:{strings:
  false,wasm:false}})` closes the smuggle-the-grammar-as-a-string workaround (`eval` and `new
  Function` both raise EvalError). A separate AST walk hard-refuses `Date.now`/`Math.random`/`new
  Date()` with "breaks resume". D17's probe is CLOSED: the answer is NO, in every direction.*

- **D20 — The in-workflow half is GRAMMAR-FREE by construction, and deliberately dumber than
  `record.mjs`.** It may check only that a fact's `rerun` is present and non-empty, and demote +
  annotate in place. *Why: D19 forecloses sharing the grammar by import, so the only way to avoid a
  sixth hand-copy — this epic's own defect class — is to put no grammar in the workflow at all. If
  the in-workflow half ever needs to AGREE with `record.mjs` on a judgment call, that is the design
  error, not a missing import.*

- **D21 — Aiming the verify fleet by authority deficit is CUT, not deferred.** *Why: measured over
  the frozen 1,902-entry corpus through the real `deriveLevel`, the deficit has CV 0.355, two
  random facts TIE 48.9% of the time, entropy is 1.118 of a possible 2.322 bits, and L1+L2 together
  are 1.8% — the signal is near-constant. And `FACT_ITEMS` has no `load_bearing` property at all, so
  (load-bearing × authority deficit) has ZERO of its two structured inputs. Shipping it would
  launder a near-constant into a ranking that looks measured and is not — the exact laundering this
  epic exists to abolish, reintroduced one layer up.*

- **D22 — The wave is launched by `scriptPath`, never by name, and the checkout is synced FIRST.**
  *Why: the host does NOT snapshot workflow file content — a file swapped ~50s after a session
  started delivered the NEW sentinel to the dispatched subagent — but the workflow NAME registry IS
  a session-start snapshot. This wave was launched by name from a checkout 20 commits behind, so it
  ran the pre-#4915 file and measured 0 `rerun` keys across 6,891 facts machine-wide. That 0% is an
  offer never made, not a behaviour. The discrimination experiment has still never run.*

- **D23 — "676 evidence strings, 24% quote a command" is RETIRED and may not be quoted again.**
  Re-derived on the frozen fixture (n=1,902): command-quoting **14.6%**, file:line **59.3%**,
  multi-sentence >200ch **22.4%**, bare `path:line` **3.4%**, `origin/main` **8.4%**. *Why: 676 came
  from a `bp task ls` pull capped by that CLI's own paging bug and produced four different values
  for one count. The enforcement-ambition cap SURVIVES and strengthens — 14.6% is lower than 24%.
  Also: `has_command_field` is a DEAD field, false on 1902/1902 because `FACT_ITEMS` has no
  `command` key; it is not a 0% command rate and must never be cited as one.*

- **D24 — The adjudicator COMPOSES `record.mjs`'s `admitFact`; it re-derives no rejection class. The
  verdict vocabulary is TEN names, not seven.** `FAILED`, `REACHABLE-WRONG-ROUTE` and
  `HOST-UNREACHABLE` pass through as first-class verdicts. *Why: `admitFact` already emits
  LEVEL-SKIP, PATHLESS-REF, INADMISSIBLE-CONTINUOUS, MISSING-SUBJECT, MISSING-CLAIM, BAD-DEPS,
  UNKNOWN-LEVEL and demote-to-L6 — a superset of what the adjudicator brief asked a builder to
  produce from `level.mjs` raw, and rejections ACCUMULATE rather than abort. And folding FAILED into
  REJECTED collapses "your fact is FALSE" into "your fact is MALFORMED" — the exact distinction
  `rerun.mjs` says its enum exists to prevent.*

- **D25 — R4 CONFLICT ships as a directly unit-tested API and is NOT claimed live.** *Why: no live
  schema carries `subject` or `quantity` at all (0 occurrences in SURVEY_SCHEMA/VERIFY_SCHEMA/
  FACT_ITEMS), so nothing upstream can populate an R4 key this wave. Measured collision rates on the
  real corpus are vacuous at every honest grain — 0.05% on exact claim, 2.4% on full `path:line`
  (and all 37 colliding groups are CORROBORATION between compatible facts, not rival values) —
  while coarsening to basename jumps to 61% by conflating exactly what unbuilt R2 must separate. The
  only R4 specimen in the fixture is self-declared synthetic. A CONFLICT state that structurally
  cannot fire, shipped as live, reads green forever.*

- **D26 — D10 is AMENDED. Durable storage IS permitted from this wave, as ONE immutable file per
  run, folded at read time.** `tooling/grip/ledger/<run>-<key>.json`; the row is `(subject,
  quantity, rerun, derived_level, deps[], observed_at)` with **no value field**, and `observed_at`
  means "when this recipe last ran", never "when this was true". `observed_at` is supplied by the
  writer — the workflow has no clock (D19). *Why: the anti-goal becomes a property of the schema
  rather than a discipline, because a ledger containing no truth cannot be mistaken for settled
  truth. One-file-per-run makes D10's lost-write class impossible rather than managed: add/add
  merges clean across concurrent worktrees (proven), and `tooling/grip/ledger/` is NOT gitignored
  (unlike `tooling/research-coverage/research-ledger.json`, which is — D10's trap, confirmed live).
  `tooling/research-coverage` stays OUT of scope and its own reproducibility block stands.*

- **D27 — Verify WRITES the ledger rows; Decide COMMITS them.** *Why: the JS orchestrator genuinely
  cannot persist (zero fs/exec/require in all three workflow files, D17), but the verify PHASE can —
  its "no repo edits" line is a prompt sentence inside this wave's own surface fence, not a missing
  capability. The Decide agent already writes AND commits a file by explicit path in the shared main
  checkout, in-loop, with no worktree isolation — an in-loop committed write is precedented, not
  speculative. So "verify-writes-back" is honest and needs no renaming: written and committed one
  phase apart, in the same wave, never one build-cycle stale. The carve-out is narrow: write ONLY to
  `tooling/grip/ledger/`, never commit, never touch anything else.*

- **D28 — The fan-out floor throws have NEVER fired in a real run, and the charter says so.**
  *Why: swept 659 workflow journals and every `wf_*.json` run record on this machine — zero
  incidents, and every bp-epic-cycle run (including four dispatched AFTER the floor commit merged)
  carries a byte-identical 54,073-char pre-floor script snapshot. Both throws were proven under a
  builder-authored simulation, never in the loop. "The throw is the only enforcement that genuinely
  fires" is an intent, not an observation, until a wave observes one.*

  **AMENDED 2026-09-02 — the ruling above is SUPERSEDED: both floors have fired.** *Re-derived on
  this date. The VERIFY floor has fired in **13** distinct real `bp-epic-cycle` runs, each one
  `"status": "failed"` with the fully-RENDERED throw — a digit where the source carries an
  interpolation — in the run record's own top-level `error`. The first is `wf_5fb8ba2e-ab7.json`,
  2026-07-21, after 14/14 surveyors reported: the digest returned 1 assignment against a floor of 3.
  Twelve more fired on 2026-08-18, two of them on THIS epic's own waves — `wf_27e7dcd5-7a5.json`
  (0 assignments) and `wf_f5b9da24-ba7.json` (1). The SURVEY floor has ALSO fired: 5 distinct runs
  on 2026-07-22 (workflow task-ids `wlcsw6x2d`, `w1smo8lzj`, `w2p2ldakl`, `wkimfhhf3`, `wy6ts9gf1`),
  each a failed-workflow notification reading "the strategist returned 1 survey assignment(s), below
  the floor of 5". Those five left NO `wf_*.json` behind — a run that dies at the Survey floor never
  persists a run record — so the original sweep, which read run records, was structurally blind to
  precisely the floor it then declared unfired. That is worth more than the correction: absence from
  the run-record corpus is not absence of the firing, and a sweep must be shown able to FIND the
  thing before its silence counts as evidence. The record also did not decay — it lives under
  `~/.claude/projects/<project-slug>/<session-id>/workflows/`, which outlives the repo worktree a run
  was launched from, so a check that looked only inside the worktree read the wrong shelf.*

  *Re-derive it, do not trust it — read-only, from any checkout:*
  `grep -rlE 'Verify fan-out floor: the digest returned [0-9]+ verify assignment' ~/.claude/projects --include='wf_*.json'`
  *and* `grep -rlE 'Survey fan-out floor: the strategist returned [0-9]+ survey' ~/.claude/projects`.
  *Expected shape: the first prints one file path per firing and nothing else — 13 paths on
  2026-09-02, one under an `e2-review-w17` session and twelve under a `fix-stamp-miss-doc` session;
  fewer means records were pruned, more means the floor fired again. The second prints session
  `.jsonl` transcripts and never a `wf_*.json`, and one of them is the builder-authored simulation
  (it prints its own `n=0: THREW ->` roll-call), not a wave. The DIGIT is the discriminator — a hit
  reading `returned ${` is a snapshot of the throw's source, not an execution of it. Confirm each
  VERIFY hit in its record's top-level `error` beside `"status": "failed"`, each SURVEY hit inside a
  `<task-notification>` block whose status is failed, and de-duplicate by `runId` and `<task-id>`:
  a transcript reports one firing twice, once queued and once delivered. Permission warnings on
  unrelated project directories are stderr noise, not misses.*

- **D29 — The census may NEVER gate on `classifySafety`. It gets its own fail-closed screen, and
  the screen is an ALLOWLIST first.** Three layers, in order: (a) a HOST BOUND refusing any command
  naming `ssh`/`scp`/`rsync`, `157.180.90.121`, `178.105.92.191`, `guerrilla`, `barkpark.cloud` or
  `root@`; (b) an allowlist of command heads and sub-verbs that fails CLOSED on an unknown head;
  (c) the `WRITE_SHAPES` gaps patched as SECOND-layer defence, never as the gate. Measured reach:
  the allowlist admits **194 of 651 = 29.8%** of the frozen corpus, and that is the census's honest
  reach — a decay statistic over it may never be reported as covering "651 commands". Two judgement
  calls are ruled here rather than left to a builder: `git fetch` is REFUSED (it mutates `.git`
  refs in a checkout three live cycles share) and all 12 `npx` commands are REFUSED (npx installs
  and executes an arbitrary package). *Why: `classifySafety` marks 26 of 31 synthetic
  outage-capable commands SAFE — including `reboot`, `mix ecto.drop`, `kill -9`, `pkill`,
  `cp <anything> <repo path>` and `curl -o /opt/barkpark/deploy/site-deploy.sh` — and `runRerun`
  gates on it and then calls `spawnSync("/bin/sh", ["-c", cmd])`, so every false-safe is an
  execution. A patch was written, measured and made able to fail (22/22 danger refused, 0/7
  over-refusals, 0/12 cry-wolf, 0/18 existing `mustAllow` broken) — and it took FOUR correction
  rounds against the corpus, oscillating between false-safe and false-refusal each time, with the
  full corpus in hand and a harness running. `rerun.mjs:75` and `:121-131` already say it: "a
  denylist of mutating APIs cannot be complete… the verdict it supports is 'no write shape
  detected', never 'this command cannot write'." A second verifier, screening the corpus from the
  opposite direction to run the decay census, independently had to write the same second denylist
  and rejected 5 systemctl and 5 deploy-script commands `classifySafety` green-lit. Two
  investigations, opposite directions, same hole.*

- **D30 — The "cheap high-value" `L3_HEADS` head-token fix is CUT AS WORDED and REPLACED.** Adding
  `bp`, `gh` and `cd` to `L3_HEADS` was the Digest's cheapest recommendation; verification refuted
  it three independent ways and it may not ship in that form. What ships instead, in one slice:
  (a) the curl/wget/URL-sniff L1 check is UN-GATED from head-only matching so it fires anywhere in
  a compound; (b) a wrapper-strip path handles `cd X && …`, `for … do …` and env-assignment
  prefixes so the head token is found PAST the wrapper — adding no head to `L3_HEADS`; (c) `bp` and
  non-`api` `gh` route to **L2**, the level `gh api` already holds, because they are remote-API
  reads; (d) a PARSEABILITY FLOOR: a `rerun` string that is not a syntactically valid command
  cannot derive above L6. *Why: (1) `bp` reads `https://guerrilla.barkpark.cloud` and `gh` reads
  `api.github.com` — both live remote reads — so filing them at L3 "local checkout" is a two-level
  SKIP, this charter's own line 50 disease wearing the doctrine's uniform, and it would mislabel
  volatile remote state as checkout-stable, corrupting the decay axis. (2) `deriveLevel`'s L1
  curl/wget check is head-gated while `SSH_READ` is not, so adding `cd` makes
  `cd /opt/barkpark && curl https://guerrilla.barkpark.cloud/health` derive **L3** — it was L6,
  safe-by-demotion — a proven authority inflation on a command that provably reaches production,
  with ZERO tests covering any compound `&&` shape. (3) 13.3% of the frozen corpus's `rerun`
  strings are PROSE, not commands (`python3 confusion matrix (15 per PREDICTED class…)`,
  `grep/read <path> around lines 200-219`), and `deriveLevel` grades 33 of those 58 at L2/L3
  because it inspects a head token and never asks whether the string parses — so the head-token fix
  shipped ALONE would move prose INTO L3 and make the grammar's central promise weaker, not
  stronger. The parseability floor errs by DEMOTION, which D3 already establishes as the safe
  direction.*

- **D31 — `observed_at` gets a caller-supplied `now` bound, and the CLI sources `now` from the
  SHELL, never from agent-supplied JSON.** `admitRecipe(input, { now })` compares ISO strings and
  rejects a future `observed_at`; omitting `now` admits, so no existing caller breaks. The WRITE
  verb bakes `date -u +%Y-%m-%dT%H:%M:%SZ` into itself. `observed_at` MUST be Z-only at the write
  seam, with a named rejection for an offset form. *Why: a forged row — two commands never run,
  dated 2031 and 2087 — was ADMITTED, written to disk and folded back as authoritative, one at
  **L1** and one at **L2**, and the L2 one does not even execute (`fatal: path
  'tooling/grip/ledger/recipes.json' does not exist in 'origin/main'`). Every rejection class that
  fires is a SHAPE class; zero honesty classes exist. Typing an ssh-shaped string mints L1 for
  free. Of the three doors offered — prompt discipline, a `Date.now` bound, or nothing — the
  `Date.now` bound reds TWO tests, and the second red is the finding: a fixture hardcoded
  `2026-07-21T09:00:00Z` sits 8 hours in the future, so a clock in the module converts a
  deterministic suite into a wall-clock-dependent one, invisibly. The caller-supplied bound passes
  37/37, keeps the module clock-free, and rejects the forgery. Z-only is required because lexical
  ISO comparison is correct only for same-offset instants, and normalising offsets needs
  `Date.parse`, which re-trips the clock-free grep the fourth door exists to avoid.*

- **D32 — `subject` is MINTED from the `rerun` command's first normalised repo path token, with a
  `cmd:<head-token>` fallback; `quantity` is minted from the command's verb phrase. Neither is ever
  free-typed or derived from claim prose.** *Why: over this wave's own 104 real survey facts, a
  claim-derived subject produces **104 distinct keys out of 104** — a provably injective key, a
  `detectConflicts` that can never fire and a leads index in which nothing is ever a lead. Path-token
  minting gives 67% coverage, 22 distinct subjects, and **8 subjects shared by 2+ facts covering 56
  of 104** — a working index (`bp-epic-cycle.workflow.js` ×23, `ledger.mjs` ×14). `findRefs`/
  `classifyRef` are the WRONG tool and were measured as such: `REF_CANDIDATE` requires a literal
  `:digits` suffix and scores 0 of 104 on both claims and reruns. The fallback is what keeps the
  verb from ever reporting 100% REJECTED.*

- **D33 — The ledger fold's flag is RENAMED to `RIVAL-METHOD`. The adjudicator's `CONFLICT` stays
  library-only (D25 stands), and `tgw2-ledger-adjudicator-vocab`'s premise is FALSE.** *Why: a 2×2
  probe ran all four cells. `foldLedger` fires on ≥2 distinct rerun COMMAND STRINGS and has no
  value field to compare, so it fired CONFLICT on `wc -l /abs/path` vs `wc -l rel/path` — both
  verified to output `544`. `detectConflicts` fires on ≥2 distinct claim VALUES and never reads
  rerun, so it correctly returned 0 conflicts on that same pair and 2 on a genuine `544` vs `999`
  disagreement, which `foldLedger` is structurally incapable of seeing. The shapes are not
  identical by construction — they detect OPPOSITE things — so re-pointing the ledger's constant at
  `VERDICTS.CONFLICT` would import a name for a different concept, making one canonical string
  definitionally shared by two incompatible meanings. Under D32's path-grain key, `RIVAL-METHOD`
  will fire on those 8 corroboration groups on day one: that is the PRODUCT — "multiple checks
  exist, re-run and compare" — not a defect, and it must be documented as expected before the read
  path ships, or the first honest multi-recipe entry discredits the flag permanently.*

- **D34 — The surface fence is PATHS, never a directory.** `tooling/grip/**`,
  `.claude/workflows/bp-truth-grip-charter.md`, `.claude/workflows/bp-epic-cycle.workflow.js`.
  Nothing else, and specifically no other charter under `.claude/workflows/`. *Why: that directory
  holds 80+ files including three actively-running epics' charters, and the hazard is live, not
  theoretical — open PR #5106 and an unpushed local commit both append to
  `bp-cloud-gui-remake-charter.md` at the same anchor line 1331, so whoever pushes second eats a
  conflict. A fence stated as a bare directory reads as permission to edit those.*

- **D35 — The Verify carve-out and Decide's commit ship in ONE slice, the carve-out is granted ONLY
  in the shared-checkout branch, and the stranded-file case is ruled: THE LOSS IS ACCEPTED.**
  A verify assignment that sets `needs_worktree` may not write ledger rows, and Digest's prompt
  says so. If Decide crashes or cuts zero slices, uncommitted rows are lost; no sweep is built, and
  a code comment states that this is a decision. *Why: amending "no repo edits" without extending
  Decide's explicit-path commit strands rows in a checkout other sessions share — Decide's prompt
  today commits exactly one file, the charter, "by explicit path only — never `git add -A`", and
  names no other path. There are TWO stranding paths, not the one the plan assumed: a
  `needs_worktree` verifier writes into its own throwaway worktree, which Decide never sees no
  matter how its commit is amended — so the carve-out must be scoped to the branch that shares
  Decide's checkout, or the ruling looks complete while staying silently lossy. No sweep is built
  because a sweep in a contended checkout is more dangerous than the loss, and a recipe is cheap to
  re-derive by construction — that is the entire point of the store. Silence here would have been
  the defect; this is the ruling.*

- **D36 — The wave's headline is THREE numbers, and the Digest's four are RETIRED.** Published:
  **100% PRESENT / 93.1% EXECUTABLE / 86.3% ANSWERING**, over **104** facts. Fill rate may never be
  published alone — it is the weakest of the three. *Why: the Digest reported 95 facts, 14.7%
  nominal L6, 13-of-14 bp-or-gh, and "exactly one genuine L6 ≈1.1%". Re-extracted programmatically
  from the 18 raw surveyor transcripts, every one of those four is wrong: **104** facts (the digest
  lost 9), nominal L6 **19/104 = 18.3%**, bp-or-gh **14/19 = 73.7%**, and TRUE L6 **0/104 = 0.0%**
  — there is not one unclassifiable command in the corpus. The cause is the finding: the digest
  levelled a hand-normalised PARAPHRASE of its own corpus. 27 of its 95 strings appear nowhere in
  the survey output, real paths were replaced with a literal `x` placeholder, and `cd <path> &&`
  prefixes were STRIPPED — which is exactly the wrapper `headToken` cannot see past, so the
  normalisation silently converted L6 rows into L3 rows. The digest measured its own typing. The
  predeclared prediction of ~85% L6 is REFUTED, and it was predeclared in a form that could not be
  retrofitted, which is the discipline working. The honest name stays long: "fill rate under the
  wave-2-shipped, already-rerun-tutored prompt" — four live instruction sites push on rerun and
  this wave added zero, so it is a clean read of the shipped prompt but NOT evidence about organic
  agent behaviour.*

- **D37 — D21's entropy statistic is RETIRED and may not be quoted again; D21's DECISION stands.**
  The figures struck: entropy 1.118 of 2.322 bits, `L1+L2 = 1.8%`, buckets `{L1:8, L2:27, L3:1047,
  L6:820}` summing to 1902. *Why: it is not re-derivable from anything committed. The extraction
  script that produced it is absent from `tooling/grip/` and from that path's entire history, and
  it cannot be reproduced by the shipped grammar because `deriveLevel` reads a `rerun` field alone
  while the 1,902-entry `evidence` array has no command field at all — applying the real
  `deriveLevel` to what those rows actually carry returns L6 for 1902 of 1902. That is an L6 claim
  by this epic's own grammar, sitting inside the epic's own trial-cutting rationale, and it gets
  the same treatment D23 gave the retired 676/24% figure. The QUALITATIVE finding survives — L1+L2
  near-zero, L3/L6 dominant — confirmed independently by two methods. The wave-2 corpus census
  (L1 33 / L2 31 / L3 336 / L6 252 over the 652 `proofs`) is a DIFFERENT corpus and remains valid;
  any census verb must name which corpus it read.*

- **D38 — The census verb must classify SILENCE-AS-ANSWER explicitly, and the answer-DRIFT rate is
  UNMEASURED and may not be quoted.** *Why: 7 of 104 facts have empty output as their CORRECT
  answer — 4 `rc=0`-with-no-stdout byte-identity proofs and 3 `grep`-`rc=1` absence proofs — so a
  naive `rc==0 && stdout` predicate scores all 7 as decayed and INVERTS three of them, on a clean
  corpus. The decay axis was insurance and it paid: over 406 screened commands, **59.4% still
  answer, 22.4% have genuinely decayed** (a FLOOR — the 245 excluded commands are systematically
  more decay-prone), and **13.3% were never executable commands at all**. The single most valuable
  specimen is an absence claim that has gone false: `git ls-tree -r origin/main | grep -i
  "internal/scaffy"` recorded "(empty output — no matches)" and today returns 58 files — a
  value-storing index would have got that wrong where a recipe-storing index gets it right, which
  is the strongest empirical argument for D26 anyone has produced. The drift rate is a different
  matter: the 154 mismatches measured are truncation-bound, not drift, because only the first 200
  chars of stdout were captured. It is a BOUND, not a rate, and it is filed as backlog rather than
  quoted.*

- **D39 — The write seam gets a safety gate BY INJECTION.** `admitRecipe` takes an optional `screen`
  predicate and rejects a command the census screen would refuse to run, under a named class. The
  ledger imports nothing from the screen module; the CLI wires them together. *Why: `admitRecipe`
  never calls any safety check, so `systemctl stop bp-crux-parent` and `rm -rf
  /opt/barkpark/releases` are both ADMITTED as recipes today — and a recipe is precisely a thing
  this epic exists to make agents re-run cheaply and often. The danger is not only that the census
  re-executes historical commands; it is that the store will happily persist an outage-capable one
  for someone else to re-run later. Injection rather than import keeps the two slices' files
  disjoint so they build in the same round.*

- **D40 — Merge is proven by CONTENT on `origin/main`, never by commit ancestry, and the ten
  done-but-open slices are closed on that basis.** *Why: all 7 distinct branch-tip SHAs cited by
  those tasks return `is-ancestor exit=1` against `origin/main` — squash-merge erased ancestry for
  every one — while each slice's characteristic exports are present verbatim on main. An
  ancestry check would have produced 10 false negatives; a content check produced 10 true
  positives. The urgency is not hygiene: all 10 currently surface in `bp task ready --all` with
  claims expired since 2026-07-20T13-16Z, so `bp task next` would hand a builder already-shipped
  work today. Note also that the verification recipe circulated for this check was itself broken —
  it read a `tasks`/`documents` key where the API returns `docs`, and omitted `--all` against a
  905-row pool, so run verbatim it printed an empty list and read as good news. A vacuous green.*

- **D41 — The wave-3 landing (four branches plus the D29–D40 charter commit) is a PRECONDITION,
  not progress, and it is landed by one PR before any wave-4 builder flies.** *Why: proven by dry
  run against three successive tips. All four branches merge clean in the order screen → level →
  ledger → verify-seam, and `a96aacce6` cherry-picks clean (rc=0, 208 insertions, one file) despite
  sitting on a local `main` diverged by three other epics — because it is the tip of that divergence
  and touches exactly one file. But the sharpest finding is the negative one: on the fully merged
  tree, `git ls-tree HEAD --name-only tooling/grip/ledger/` STILL returns only `README.md` and
  `node ledger.mjs --help` still prints `usage: node ledger.mjs [fold [dir] | --selftest]`. Round 0
  buys a correct record and zero rows. Budgeting it as progress toward "the ledger stops being
  empty" would under-plan the wave. It is landed as a PR from an isolated worktree — never as a
  commit to the shared checkout's local `main`, which is how D29–D40 went missing in the first
  place.*

- **D42 — Between the four artifacts and a charter commit, the charter commit is the one that
  cannot be deferred, because a decision nobody can read is a decision that does not exist.**
  *Why: observed directly mid-flight. After the four merges but BEFORE the cherry-pick, the charter
  held exactly 28 decision rows while the wave-log added by branch 4 cited D29, D31, D33, D35 and
  D39 — five references to decisions with no text anywhere on the branch. That is precisely the
  state a round 0 that only pushed branches would have left on main, and it is wave 1's
  charter-never-reached-main defect repeating one wave later. Every wave-3 and wave-4 brief was
  written against D29–D40; a fresh worktree saw D1–D28.*

- **D43 — `grip leads` ships REDUCED, on measured grounds: the substring filter is the feature, and
  the staleness band, the ranking, and the RIVAL-METHOD flag are all cut.** *Why: the predeclared
  hit rate came in at ~19% of 18 survey assignments (~13% over 27 incl. verify) — in-band at the
  top edge, so not the null result that would have cut the verb entirely. But three cuts are each
  carried by a number. (a) RIVAL-METHOD carries ZERO BITS: at the `(subject, quantity)` grain D33
  specifies, 282 of 297 pairs (94.9%) are singletons where it cannot fire, and it fires on 15 of 15
  where it can, with 0 corroboration cases — at subject grain, 41 of 41. It is either impossible or
  certain, never informative. D33's rename DECISION stands; what is cut is rendering it as a flag,
  replaced by the row count itself ("3 methods on this key — run all three and compare"), which
  delivers D33's product with no false authority. (b) The staleness BAND is a constant column on
  day one, because every row at ship is minted this wave; and no row in the 652-proof corpus carries
  any timestamp field, so it cannot even be backfilled. (c) "Ranked" has no rank signal at n≈100
  with all-fresh rows — a ranked list with no ranking is the laundering this epic exists to abolish.
  What survives is the rerun-substring filter, which narrows the busiest real bucket 2–8x
  (`internal/cli/` 31 rows → 8 on "vet", 14 on "test", 4 on "build") and is the measured answer to
  the granularity attack.*

- **D44 — The leads substring filter is CASE-INSENSITIVE, and the null state names the structural
  misses out loud.** *Why: a case-sensitive filter produces a FALSE honest-empty — measured:
  substring "completion" returns 0 rows over a bucket that contains
  `go test -run TestCompletionNounsCoverAllDispatchedBuiltins ./internal/cli/`. Against this epic's
  own bar ("honest empty is an answer"), an empty that lies is worse than no filter at all. The null
  state must say "no recipes for this subject — the ledger indexes repo PATHS; it cannot index bp
  task ids, and it cannot answer judgment questions", which converts two of the three measured
  structural miss classes from silent failures into diagnoses.*

- **D45 — `cmd:<head>` fallback subjects are excluded from the leads index.** *Why: the fallback
  exists so the WRITE verb never reports 100% REJECTED (D32) — that is a write-path concern and
  does not obligate the read path to index them. Measured, they are dumps, not subjects: `cmd:bp`
  is the single largest bucket in this wave's own corpus at 16 rows, and repo-wide `cmd:bp` is 55,
  `cmd:git` 42, `cmd:curl` 27. The first user query against a dumping ground discredits the
  feature.*

- **D46 — The honest scope of leads is intra-epic, and the charter says so rather than claiming
  repo-wide lookup.** *Why: within one wave's fence the mint clusters (51 distinct keys for 119
  facts; 16 subjects shared by 2+ covering 84 of 119) because a single wave is a monoculture.
  Repo-wide over the frozen 652-proof corpus it degenerates: 337 distinct subjects, 268 of them
  singletons. Leads beats grep only in a bucket-size band of roughly 3–20. The claim that survives
  measurement is "leads help THIS EPIC stop re-deriving its own housekeeping facts", not "leads
  help surveyors generally".*

- **D47 — The census OWNS the screen composition. `rerun.mjs`'s gate is NOT swapped, and
  `runRerun` is not on the census path at all.** *Why: this was the wave's genuinely undecided
  design, and two builders guessing differently IS the wave-3 cross-slice break repeating.
  Three findings settle it. (a) The ordering defect the direction alleged does not exist:
  `shell()` is DEFINED at rerun.mjs:335 and CALLED at :360, :450 and :492, all after the gate at
  :420 — a builder sent to fix the ordering would find nothing and might weaken the gate hunting
  for it. (b) There are THREE call sites, not two, so a slice that swaps the gate at :420 and stops
  leaves :360 reachable. (c) `probeHttp` at :360 is a fixed read-only curl, not a bypass. Census
  therefore calls `screenCommand` itself and executes only what passes, which keeps screen.mjs
  importing nothing from rerun.mjs (D29), keeps the files disjoint, and keeps the blast radius off
  the only gate currently running on main.*

- **D48 — `screen.mjs` admits an arbitrary file-overwrite primitive, and this wave closes it.**
  *Why: `screenCommand("sort input.txt -o api/lib/barkpark/application.ex")` returns `ok: true`,
  and the overwrite is real, not theoretical — `sort -o` turned a victim file's contents from
  "original content" into "PWNED" in a live probe. `uniq in out` and `tree -o` are the same shape.
  `sort`, `uniq` and `tree` are registered as bare `plainRule()` with no flag inspection and no
  WRITE_SHAPES backstop. This matters beyond its size: D29's own named danger is
  `cp /tmp/evil.js api/lib/barkpark/application.ex`, which screen.mjs closes BY NAME while leaving
  a byte-identical outcome open through `sort -o`. That is denylist thinking surviving inside the
  module whose entire thesis is that denylists cannot be complete, and it is invisible to the
  shipped suite precisely because DANGER_SET was written from the same head-list that has the gap.
  Honest bound: LATENT, not live — 0 of 240 admitted corpus rows use these shapes. But harvest.mjs
  regenerates the corpus from arbitrary other agents' transcripts, so today's fixture bounds
  nothing about tomorrow's input. The fix is a flag guard plus a WRITE_SHAPES backstop plus
  DANGER_SET entries so the suite can fail on them.*

- **D49 — The cross-slice wiring test asserts SUBSTRING CONTAINMENT of the screen's live output
  inside the ledger's live output, importing both real modules — never a shape assertion.** *Why:
  this is the wave's most decisive proof. A shape assertion would duplicate `screen.test.mjs`,
  which already goes 16–19 tests red on a naive mutation. The gap is the CONSISTENT refactor: a
  complete, self-consistent rename of `reason` → `why` (in `refuse()`, in the admit return, in
  `screenAll`'s own consumer at screen.mjs:806, and throughout `test/screen.test.mjs`) leaves
  `screen.test.mjs` 34/0, `ledger.test.mjs` 60/0 and `level.test.mjs` 71/0 — EVERY shipped suite
  100% green — while the ledger silently falls back to "the injected screen refused it". Wave 3's
  headline defect, reproduced on the merged tip, invisible to the entire shipped suite. Only a
  containment assertion catches it, and only a test importing both modules can express one. Note
  the trap: `test/ledger.test.mjs:826` is already TITLED "the injected-screen contract MEETS
  screen.mjs's real return shape" while line 836 states it uses a STAND-IN rather than importing
  screen.mjs — a builder may find that title and believe the work is done.*

- **D50 — Silence is classified by TOOL FAMILY first and exit code second; there is no flat
  predicate, and `git show`'s rc128 is discriminated by STDERR PATTERN.** *Why: a flat
  `rc==0 && stdout non-empty` misclassifies a byte-identity `git diff` (rc0+empty is the ANSWER)
  and a grep absence (rc1+empty is the ANSWER). The obvious repair — "rc1 means absence" — inverts
  polarity on `diff`, whose rc1 carried 7,357 bytes of real differences in the probe. And rc128
  cannot key decay: path-gone ("does not exist in"), ref-gone ("invalid object name") and wrong-cwd
  ("not a git repository") all exit 128, so a census run in a worktree that has not fetched
  `origin` would report the ENTIRE ledger as decayed — an outage forging a decay wave. REF-GONE
  and WRONG-CWD are environment faults and INADMISSIBLE, never decay. Scope: 246 of 652 corpus
  commands (37.7%) sit in an exit-code-ambiguous family, and 12 non-grep silent-PASS specimens —
  including a clean `go vet`, the canonical green — are discarded as NULL-READ today.*

- **D51 — Two live defects in `rerun.mjs` are fixed independently of whether the census ships.**
  *Why: (a) `diff a b` where b does not exist exits 2, reads nothing, and is ADMITTED as evidence
  that something is absent — a tool error laundered into an absence claim. `readIsNull`
  special-cases grep's exit 2 and nothing else, so grep is protected and every other tool is not.
  This is a false ADMISSION, strictly worse than the discards, because it manufactures a false
  claim rather than dropping a true one. (b) `git merge-base --is-ancestor` is refused
  UNSAFE-RERUN because the write-verb regex lists `merge` and `\b` matches inside `merge-base` —
  so the epic's own D40 merge-proof check and every stranded-branch ancestry check cannot be rerun
  by its own instrument. One-token fix (`merge(?!-base)`), but it sits inside the safety allowlist
  and must be ruled explicitly and paired with a protective test, or a builder "fixing safety" near
  WRITE_SHAPES is exactly the weakening this charter warns against.*

- **D52 — Three statistics are RETIRED, and each is replaced by one that can be re-run.** *Why:
  D21's precedent, applied to this epic's own favourite numbers. (a) "26 of 31 outage probes
  green-lit" is unrecoverable and lives in SHIPPED SOURCE (screen.mjs:21, screen.test.mjs:351), not
  merely in briefs — replaced by the re-runnable pair: 22/22 named outage probes admitted by
  `classifySafety` vs 0/22 by `screenCommand`, and 572/651 vs 240/651 over the frozen corpus. Safe
  to retire: no test asserts the number, the test asserts 14 SHAPE regexes. (b) The mint rule's
  "70 of 104 = 67%" is carried as a fact with NO RERUN — structurally identical to D21's retired
  entropy statistic — replaced by 90 of 119 = 75.6%, re-derivable from this wave's own journal.
  (c) The "7 of 104" silence figure cannot be re-derived as stated, because 0 of 652 corpus proofs
  have an empty `output_excerpt`: agents NARRATE silence rather than record it. Replaced by 38 of
  652 (5.8%) under the strict narration pattern.*

- **D53 — Prediction 1 is REFUTED, and the metric is named rather than the favourable reading
  quoted.** *Why: path-token mint yield over this wave's own 122 facts is 75.6% of rerun-bearing
  facts (73.8% of all) — above wave 3's 67% prior by 7–12 points, but not the predeclared ≥90%.
  The loose reading ("mints a subject at all", counting the `cmd:` fallback) is 97.5% and would
  satisfy the prediction, but D32's own prose shows the fallback was designed as a FLOOR, not as
  coverage. Quoting 97.5% without naming the metric would repeat exactly the 26-of-31 failure this
  wave is retiring. The honest headline is ~76%. Injectivity is confirmed on fresh data: the
  path key gives 51 distinct keys for 119 facts (it CLUSTERS), while the claim-derived control
  gives 119 for 119 — perfectly injective, a dead index. D32's central argument holds.*

- **D54 — The write verb mints its own `run_id` from a sanitized UTC bound, and the
  foreign-row staging hole is stated as a CEILING rather than patched.** *Why: `run_id` appears
  NOWHERE in the workflow JS (zero occurrences of run_id/randomUUID/crypto/Date.now), and
  `ledger.mjs` deliberately owns no minting policy — its BAD-RUN-ID message says run_id "is
  supplied by the caller because this module has no clock and no random source to invent one".
  Critically, a raw `date -u` string CANNOT be the run_id: colons violate the RUN_ID regex, so
  "bake date -u into the write path" does not work literally and must be sanitized. Landing the
  wave-3 branch does NOT close the Decide-staging hole: two simultaneous untracked rows appear as
  identical bare `??` and Decide's shipped instructions stage both. Since the workflow cannot
  supply a shared per-wave prefix, run_id-prefix filtering cannot be made reliable, and the honest
  claim is that explicit-path staging bounds the blast radius without eliminating it.*

- **D55 — `harvest.mjs` is READ and named, not absorbed: the safety enumeration is TWO exec
  primitives, one fact-driven and gated, one fixed and read-only.** *Why: three waves of "606
  lines unread" ended. It holds exactly one exec — `execFileSync("bash", ["-c", LIST_COMMAND])` at
  :78, where LIST_COMMAND is a module-level `find … -print0` constant with zero interpolation — and
  it has ZERO import sites anywhere in `tooling/grip`. It is invoked only by a human running
  `--harvest` by hand. It is also disqualified as a write-verb fact source BY CONSTRUCTION: no row
  in its corpus carries a `rerun` field ("100% of these strings are prose"), which is what killed
  the backfill rival on the merits. Naming it beats absorbing it: the claim "only one execution
  path exists" was false, and a charter that says so stays trustworthy.*

- **D56 — the fleet-as-factory is DEFERRED, not attempted; wave 5's volume comes from
  RE-EXECUTION BACKFILL.** *Why: the join blocker is worse than "the prompt never names
  `ledger.mjs`". At Verify time the shared checkout the D35 carve-out points at was 26 commits
  behind `origin/main` and had NO write verb — `node tooling/grip/ledger.mjs write /tmp/f.json`
  printed the old `[fold | --selftest]` usage and exited 2. A verifier that got past that needed
  NINE independent discovery steps (that a tool exists at all; the verb and its arity; that it must
  MATERIALISE `facts.json` itself, since the harness never writes one; that raw `{claim, evidence,
  rerun}` facts are not rows and `mint` is a required intermediate; that the third positional `dir`
  exists; that `screenCommand` returns `.ok`, not `.safe`). Then all-or-nothing killed the batch
  anyway: 9 refusals over 22 real foreign survey facts — 7 of them `sed -n 'N,Mp'` — discarded ALL
  22 rows, exit 1, nothing written. Two of those three failure modes sit outside this epic's
  surface fence. A wave that bets its headline on that seam mints zero rows.*

- **D57 — directory density does NOT cluster subjects; QUESTION density does. P4 is REFUTED
  BACKWARDS.** *Why: P4 predicted foreign singletons below 65%; deliberate directory-dense aim
  measured 92.3% (39 foreign subjects, 36 singletons) — WORSE than D46's 79.5% under scatter. The
  bucket histogram is `{1:36, 2:1, 3-20:2}`, with only 28.3% of rows in the band D46 identified as
  the only one where leads beats grep. The mechanism is that the mint's subject is the FILE PATH:
  ten questions about ten files in one directory mint ten singletons. The only clusters produced
  were the two files asked about REPEATEDLY (n=11, n=4), and the survey's unengineered facts
  clustered BETTER than the engineered ones — 22 facts to 9 subjects — because surveyors kept
  re-interrogating the same two artifacts. Every future aim instruction reads "many questions per
  FILE", never "many files per directory".*

- **D58 — the census is the MINTING INSTRUMENT: a corpus command becomes a ledger row only by
  ANSWERING on re-execution today.** *Why: the corpus's `proofs[]` carry `run` as a workflow id
  (`wf_009b2433-388`), never a timestamp, so a backfill cannot honestly derive `observed_at`, and
  stamping `now` on a weeks-old command is exactly the freshness claim this epic exists to forbid.
  Re-execution fixes it BY CONSTRUCTION — `observed_at` is true because the command was just run.
  This also settles D55's backfill disqualification precisely rather than reversing it: D55 killed
  the EVIDENCE half (1,902 prose entries, no `rerun` field, "100% of these strings are prose"). The
  PROOFS half is 652 entries carrying `.command`, which IS a rerun. Backfill is re-admitted on the
  proofs half ONLY, gated on answering, and a command that no longer answers is not stored at all.*

- **D59 — `leads` SHIPS, and P5 is RE-WORDED BEFORE it is quoted: an honest-empty rate is
  meaningless without a stated query granularity.** *Why: two independent measurements disagreed
  because P5 never named the variable that decides it. Over 20 router-vocabulary queries on the
  62-row store: 65.0% honest-empty → SHIP (threshold >70%). Over coarse queries on a 279-row store:
  5–40% → SHIP. Over 20 INDEPENDENTLY-derived exact file paths: 75.0% → CUT. The 75% is a
  STORE-COVERAGE reading, not a verb reading — 19 of its 20 query paths exist in the checkout, not
  one has a stored recipe in 279 rows, and applying the cut literally returns the same 166 subjects
  for the agent to eyeball, making an under-covered store HARDER to read, not easier. Where the
  filter does work it is decisive: `mix test` → 35 subjects, `api/lib` → 26, `internal/cli` → 12 —
  exactly D46's 3–20 band. P5 as re-worded and re-committed: measured at SUBSYSTEM granularity, and
  both readings published whenever it is quoted.*

- **D60 — RIVAL-METHOD is a FALSE-POSITIVE GENERATOR today, so fixing the mint is a PRECONDITION of
  the ledger census, not backlog.** *Why: `quantityPhrase` mints the command FLAG, not the
  property. `grep -c "needs_worktree" X` and `grep -c "isolation" X` both mint `grep:-c`, collide
  on one key, and the fold emits "N independent recipes re-derive Q … run all N today and compare
  what they answer NOW" — for commands answering different questions. Reproduced independently
  twice, and once in a stronger form: `git show <path> | wc -l` and `git show <path> | grep -c
  'needs_worktree'` both mint `git:show`, so a line count was flagged as a rival of a match count.
  Over the 652-command corpus, 449 distinct keys hold 652 rows: 58 keys collide, absorbing 261 rows
  (40%), and 41 of those 58 sit on a `cmd:<head>` fallback subject absorbing 222 rows (34%), where
  four unrelated trees were presented as four ways to derive one property. D45 hides `cmd:` from
  leads but NOT from the fold, and `census --ledger` consumes `rival_methods` directly — so
  measuring decay on the store before fixing the mint measures a signal the mint invented.*

- **D61 — the safety enumeration is THREE exec primitives, and the two sharpest holes sit UPSTREAM
  of every head rule.** *Why: D55's "TWO" is corrected on three counts. The primitives are
  `harvest.mjs:78` (`execFileSync`, fixed module constant, zero import sites), `rerun.mjs:360` —
  which is `spawnSync("/bin/sh", ["-c", cmd])`, NOT `execFileSync`, so a tranche grepping
  `execFileSync` MISSES the only primitive that takes caller data — and `ledger.mjs:849`
  (`execFileSync("date", ["-u", …])`, fixed argv, feeding every write's `observed_at`). Two new RCE
  primitives are live-proven below the allowlist: (a) DOUBLE-QUOTED COMMAND SUBSTITUTION EXECUTES —
  `maskQuotedSpans` blanks double-quoted spans identically to single-quoted ones, but `sh` DOES
  expand `$()` inside double quotes, and `censusOne('grep -n "$(id > /tmp/MARK)" .')` returns
  `screened:true, executed:true` with the marker written carrying live `id` output, on the census's
  own supposedly fail-closed path; (b) THE ENVIRONMENT-ASSIGNMENT STRIP IS A GENERAL RCE PRIMITIVE
  — `screenSegment` strips `VAR=value` prefixes and never screens the variable, so
  `GIT_EXTERNAL_DIFF=./evil.sh git diff HEAD~1` is ADMITTED and live-executes the script, with
  `GIT_PAGER=`, `PAGER=` and `NODE_OPTIONS=--require=` the same shape. Both are reachable before any
  head rule runs, which is why no amount of tightening a head rule reaches them.*

- **D62 — the node refusal STANDS (option a), documented as a REACH BOUND, never as a security
  invariant.** *Why: measured yield of the narrow `node --test <in-repo-path>` form over 651 real
  proof commands is ONE. 0.15%. The JS test evidence agents actually type is `npx vitest run`,
  `pnpm --filter @barkpark/react test`, `npm run typecheck` — 13 commands option (b) recovers NONE
  of — and 2 of the repo's 3 real `npm test` scripts carry `--import` or `--test-reporter=spec` and
  fail the narrow form anyway. The narrow form is also DEFEATED below its own grammar by D61(b): 7
  of 29 escapes were admitted and `NODE_OPTIONS=--require=./evil.cjs node --test ok.test.mjs`
  live-executed attacker JavaScript. Option (b) as literally filed on `tgw4-screen-refuses-node`
  (`node <path-under-the-repo>`) is straightforward RCE needing no escape at all. The honesty
  clause is mandatory: the screen ALREADY admits `mix test` and `go test`, which execute arbitrary
  repo code — this repo's own ExUnit files call `System.cmd("python3", ["-c", …])` — so "we refuse
  arbitrary code execution" is not a principle the screen holds, it is a rule applied to node and
  not to Elixir or Go. The refusal is a bound this epic CHOOSES; the cost (grip's own `node --test`
  recipes can never be stored) is paid knowingly and written into the README.*

- **D63 — the screen's two FALSE REFUSALS are fixed in the SAME slice as the tightenings, because a
  screen that only ever tightens gets routed around.** *Why: (a) the host bound runs on the RAW
  string before `maskQuotedSpans`, so a purely local `grep -c "ssh" docs/ops/PROD_OPS.md` is
  refused as "names ssh (remote execution)" — a PATTERN read as a TARGET — and the densest planned
  foreign targets are ops docs whose most quotable lines all contain `ssh`. (b) `sed -n 'N,Mp'`,
  read-only line citation, is refused on the head as a stream editor, and it is the single largest
  refusal class in real foreign output: 7 of 9 refusals over the survey's own facts. The kicker is
  that the harness's own `rerun` schema description gives `git show origin/main:path | sed -n
  40,60p` as its FIRST worked example — the instrument instructs its producers to write exactly
  what it refuses. Shipping the tightenings alone would raise the refusal rate on honest work in
  the same wave that multiplies stored commands.*

- **D64 — all-or-nothing writes STAY, and a PRE-SCREEN verb ships beside them.** *Why:
  all-or-nothing is correct — a file holding only the rows that happened to pass IS the silent-strip
  defect at file granularity — but it is currently UNLEARNABLE. Nine refusals discarded all 22 rows
  with exit 1 and nothing written, and there is no cheap way to find out first, so a verifier learns
  the rule by losing a whole batch. `ledger.mjs prescreen <facts.json>` reports per-row verdicts and
  writes nothing. Pinned in the same breath because a verifier got it exactly backwards in the
  field: `screenCommand` returns `.ok`, NOT `.safe` — reading `.safe` yields `undefined`, scores
  0/40, and the reason string still reads "admitted", so a careful agent pre-screening its batch
  concludes the precise opposite of the truth.*

- **D65 — the level-mention promotion is a CORRECTNESS fix, NOT a volume precondition, and it is a
  RULING because the suite ENFORCES the bug.** *Why: `SSH_READ`/`GIT_SHOW_REMOTE`/`GH_API` are
  tested against the raw unmasked segment at `level.mjs:472`/`:483`, unlike curl/wget which was
  deliberately head-gated with its own regression test, so `grep -rn "ssh root@…"
  docs/ops/PROD_OPS.md` derives L1 and `checkCeiling` — which accepts any claim at or below the
  derived ceiling — then accepts ANY claimed level. The strings are real: PROD_OPS.md carries them
  at :17, :36, :82. But measured exposure is 0 of 652 corpus commands and 1 of 103 wave reruns (and
  that one is a probe OF this bug), and the L1 half is already unreachable through the screened
  write path because the screen refuses `ssh` — only the L2 inflation is storable. Decisively,
  `level.test.mjs` test 131 ("the ssh forms the corpus actually uses are never demoted") ENFORCES
  the current behaviour, so any fix reds the suite BY DESIGN. That is a decision to reverse with a
  no-false-demotion bar, not a patch to slip into a volume wave — a first attempt at the fix
  false-demoted a genuine origin read through `diff <(git show origin/main:…)`, and only the
  corpus-distribution test caught it.*

- **D66 — `foldLedger`'s read path admits every defect the write path refuses, and hardening is
  round 2 because the only actor who could exploit it is the fleet D56 defers.** *Why: 6/6
  run-proven — a row carrying `value`, a screen-refused `rm -rf` rerun, a year-2099 `observed_at`
  and a false L1 all fold clean with `unreadable: []` and exit 0. `usableRow` checks exactly three
  things (subject, quantity, rerun non-empty); it consults no screen, no clock and no derivation,
  while `admitRecipe` does all four. One nuance cuts the epic's way and is WHY leads may ship over
  an unhardened store: `foldLedger`'s projection rebuilds each recipe from six NAMED fields, so
  `value` and every other unknown key is DROPPED before reaching `entries[]` — `leads`, as a filter
  over `entries[]`, structurally CANNOT hand back a value even from a forged file. The wish's
  central guarantee holds at the read layer; it is the STORE that is unguarded, silently. Hardening
  routes rejections into the existing `unreadable[]`, which already drives the fold CLI's exit
  code — a CI-usable tripwire for free.*

- **D67 — `census.mjs` is INVISIBLE TO GREP, and that is this epic's own disease inside its own
  instrument.** *Why: a literal NUL byte at `census.mjs:148` (offset 8398), written into a mask
  expression as a raw `0x00` instead of the `\0` escape, makes `file(1)` classify the file as
  binary. The Claude Code `grep` wrapper (ugrep with `-I`) therefore returns ZERO LINES AND EXIT 1
  while `/usr/bin/grep -anc screenCommand census.mjs` returns 7 — an agent grepping for census
  internals gets a clean empty result indistinguishable from genuine absence. This is the most
  likely explanation for "census-adjacent corners no surveyor reached"; one verifier nearly filed
  two false absences from it and caught itself, concluding at first that census does NOT call
  `screenCommand`, the exact opposite of the truth. One-character fix, zero behaviour change.
  **METHOD RULING: any negative anywhere in this epic that rests on the grep wrapper over
  `census.mjs` is VOID and must be re-derived with `/usr/bin/grep -a`.***

- **D68 — the census is NOT hermetic, and the fix is a broadened `ENV_FAULT` plus a NAMED reach,
  not `--offline`.** *Why: 38 of 240 admitted rows reach live services (bp=21, gh=15, curl=2), and
  the real outage stderr of those binaries — "connect: connection refused", "no such host", "error
  connecting to <host>" — matches NONE of the three `ENV_FAULT` regexes, so `bp`/`gh` fall through
  `QUERY-LISTER` to `RAN-AND-FAILED`, which is in the DECAYED set. One hiccup flips up to 36 rows
  to false DECAYED against a published 14.6% — a single-cause spike, not 36 independent decay
  events. `--offline` costs reach unconditionally (240→202 executed, 36.9%→31.0%) to dodge a
  failure mode the regex fixes surgically, so it ships opt-in at most. One residual is NAMED rather
  than glossed: `curl -s` — 27 of the corpus's 34 curl commands — SUPPRESSES its own
  connection-refused text, leaving empty stderr with exit 7, so no stderr regex can reach it; curl
  exit codes 6 and 7 are therefore treated as environment faults directly, by code, not by text.*

- **D69 — P2 FALSIFIES, and BOTH readings are published rather than the flattering one.** *Why:
  predicted 68–85% strict path-token yield. Real fleet output measured 62.5% (65 of 104 survey
  facts) — below the floor. The frozen corpus measures 48.8% (318/652), reproduced independently
  three times to the digit. Deliberately-AIMED facts measure 85–100%, above the ceiling. Yield is a
  function of AIM, not of the miner, and the honest forecast for unprompted fleet output is the
  62.5% figure. Two mint defects surfaced while measuring, neither previously filed: `pathToken`
  rejects Go's `./internal/cli/...` because the `..` traversal guard fires on the ellipsis
  (go-family yield 24.2%, the worst of any family, and `internal/cli` is a named dense target); and
  it returns null for EVERY single-segment top-level directory — `api/`, `js/`, `web/`, `docs/`,
  `deploy/`, `scaffy/` — so the repo's own subsystem names, precisely the coarse terms an agent
  types, can never become leads subjects.*

- **D70 — P3 is RE-WORDED BEFORE it is measured, because the naive reading overstates outward reach
  2.6x.** *Why: over the wave's 104 survey facts, the naive all-non-grip share is 61.5% (64/104),
  but the corrected leads-VISIBLE non-grip share — excluding `cmd:<head>` per D45 — is 24.0%
  (25/104). `cmd:bp` alone is the single largest bucket at 20 rows, D45's dumping ground appearing
  live in this wave's own output. Quoting the naive figure would have claimed 2.6x the outward
  reach the store actually has. P3 counts leads-visible subjects only, permanently.*

- **D71 — the zombie roster closes by CONTENT, and `lifecycle_status: done` is CONFIRMED sufficient
  to leave the ready pool.** *Why: measured rather than assumed. The ten tasks named in
  `tgw3-bl-close-ten-merged-slices` all carry `lifecycle_status: done` with `claim.closed_at` from
  `tgw4-decide`, and NONE of the ten appears in a fresh 968-document `bp task ready --all` — so
  `done` does remove a task from the pool, and that backlog task's own description ("all ten
  currently surface in ready --all") is itself now a stale truth inside the epic that hunts them.
  `tgw1-adjudicator` and `tgw1-acceptance-suite` are self-documenting zombies whose own briefs open
  "SUPERSEDED … must NOT be built from" — closed by content. `tgw1-workflow-gate-wiring` is NOT
  pure bookkeeping and is NOT closed: it has 17 children of which 10 are still open, including
  `tgw2-acceptance-suite` at 0/7, so closing it would orphan real work behind a closed parent.*

- **D72 — wave 4's Paper UNDERCOUNTS its own filed debt by seven tasks.** *Why: seven `tgw4-*` /
  `tgw-*` tasks are real, published, direct children of `truth-grip-epic`, inserted between
  03:02:36Z and 03:52:26Z — after the wave-4 charter landed (03:30Z) and before the wave-4 review
  commit (04:44Z) — and NONE of the seven appears anywhere in the 346KB wave-4 Paper. The Paper is
  not lying: its blocks were frozen before its own Decide-phase filing sweep ran. The effect on a
  reader is identical to lying, which is the point. From now on the wave-log entry is written AFTER
  the filing sweep, and the Paper's wave plan names every task id it filed.*

- **D73 — BINDING is keyed on REF IDENTITY, never on path shape, and there are FIVE classes, not
  three.** *Why: the p1 task's count reproduces exactly (46 of 62 rows, 74.2%, re-derived four times
  independently) but its MECHANISM does not. Classifying all 62 rows by which ref the command
  actually reads gives 51 shared-ref (44 of them absolute), 1 per-worktree HEAD, 10 working-tree (2
  absolute). A screen that refuses absolute checkout paths would REFUSE 44 rows that answer
  identically from any tree and ADMIT the 9 whose answer is decided by cwd — an anti-signal on its
  own corpus, headlined as a 74% fix. Proven at L1, not argued: `git show origin/main:<path>`
  returns byte-identical output from the primary checkout, this worktree, and a fresh `/tmp`
  worktree (`internal/cli/tasks_next_cmd.go` → 314 lines in all three), because `refs/remotes/*`
  lives only in the shared `.git` and is absent from `.git/worktrees/<name>/`; `git worktree add
  --detach` still shares; `extensions.worktreeConfig` is UNSET so a per-worktree remote override is
  unreachable; there are no submodules. Meanwhile `git ls-tree HEAD --name-only tooling/grip/ledger/`
  returns 1 file in the primary and 4 in a fresh worktree, and `grep -c needs_worktree` on a
  relative path returns 5 vs 6 — the two rows a path-shape screen would wave through. The five
  classes, each with a real specimen in the corpus or the backfill source: **content-addressed**
  (SHA-pinned `git show <sha>:` — re-runs in any clone on any box, the MOST portable form and the
  one a 3-way split inverts into "tree-bound"), **shared-ref** (`origin/…`, `upstream/…`,
  `refs/remotes/…`), **per-worktree** (`HEAD`, bare `git log`, and the index-bound family
  `ls-files` / `status` / `diff`, whose index lives at `.git/worktrees/<name>/index`),
  **cwd-bound** (a bare `grep`/`wc` on a relative path), and **foreign-tree-pinned** (an absolute
  path into a named checkout — answers about THAT tree from anywhere, which is why the 2 rows
  pinning the EPHEMERAL `spill-janitor-wt` are worse than the 44 pinning the primary checkout, not
  better).*

- **D74 — the classifier is READ-TIME. It is NOT a stored field and NOT a screen on the write
  seam.** *Why: three mechanics, each measured, close all the other doors. (a) `RECIPE_FIELDS` is
  frozen to six keys and unknown keys are REJECTED, not stripped — `admitRecipe({…, binding_class})`
  returns `UNKNOWN-FIELD: "binding_class" is not a ledger row field`, so a stored class is a
  deliberate schema amendment, never a migration. (b) The store is structurally immutable: the only
  write uses `wx`/O_EXCL (raw overwrite fails `EEXIST … errno -17`), there is no update or delete
  verb, and `foldLedger` never supersedes — an appended correction for an existing key becomes a
  RIVAL-METHOD and renders the wrong row as a CO-EQUAL peer, proven live: `leads internal/cli` over
  a store carrying a stale row, its correction, and a deliberately tampered third printed all three
  under "(3 methods on this key — run all 3 and compare)" with no marking. Appending a fix makes the
  defect MORE prominent, not less. (c) A refusal on the write seam inherits D64: a batch of 4 rows
  with ONE refused wrote ZERO files (`ok:false`, `rejections: UNKNOWN-FIELD`, 0 files on disk;
  codified as test "ALL-OR-NOTHING: one refused row in a batch of two writes NOTHING"). That is the
  worst possible place for a discriminator which is itself under debate. Therefore p1 criterion 3
  ("migrate or grandfather the 46") is satisfied the only way it structurally can be: a read-time
  classifier over the existing rows — which IS the census.mjs pattern, and which grandfathers by
  LABELLING rather than by editing history. The p1 task's own SUGGESTED SHAPE text ("a screen/lint at
  mint time that refuses a rerun containing an absolute checkout path") is OVERRIDDEN, on evidence
  the lead did not have. The one place a rewrite is legitimate is mint-time, in memory, BEFORE
  `admitRecipe` — proven to round-trip untouched — and only where the classifier proves the answer
  invariant.*

- **D75 — "shared-ref" means shared among WORKTREES of one `.git`. It does NOT extend to a clone,
  and every CI checkout is a clone.** *Why: a clone's `refs/remotes/origin/*` mirrors the SOURCE's
  `refs/heads/*`, never the source's own `refs/remotes/*` — so a clone silently inherits the
  source's staleness. Measured: source `refs/heads/main` = `a96aacce6`, source
  `refs/remotes/origin/main` = `515f14fdd`, clone `refs/remotes/origin/main` = `a96aacce6`, 41
  commits apart, 69 files differing including every grip source. The same shared-ref recipe then
  answers `level.mjs` = 339 lines in the clone and 615 in the primary — both exit 0. `--depth 1`
  changes nothing (a real `file://` shallow clone landed on the identical stale SHA); a single-ref CI
  checkout has no `origin/main` at all and exits 128. So shared-ref is "re-run in any worktree of
  THIS clone", and the render must say that rather than "re-run anywhere".*

- **D76 — 79% of stored rows PIPE, so the failure the p1 task called loud is SILENT, and exit
  masking is a first-class classifier output.** *Why: 49 of 62 rows end in `| wc -l` or `| grep -c`,
  and a pipeline reports the LAST command's status. Proven: `git show origin/main:x 2>/dev/null | wc
  -l` prints `0` and exits `0` while git itself exited 128. A plausible numeric zero is
  indistinguishable from a real answer of zero. This corrects the direction that opened this wave in
  its favour: the 44 `cd <abs> && git show origin/main:<path>` rows are not merely portability debt
  with a loud failure elsewhere — outside this clone they fail quietly with a fabricated quantity.
  The classifier therefore reports `exit_masked` alongside the class, and a shared-ref row that pipes
  is not "safe", it is "safe HERE, silently wrong THERE".*

- **D77 — the mint-era split is ruled: the FOLD RE-DERIVES the quantity from the rerun. Nothing is
  rewritten, nothing is discarded, no rule is amended.** *Why: 57 of 62 stored rows (91.9%) carry a
  quantity the merged mint no longer produces — reproduced independently three times — and the
  consequence ships today: `census --ledger` prints "9 recipes for `git:show` of
  `.claude/workflows/bp-epic-cycle.workflow.js`" and "4 recipes … of `internal/cli/tasks_next_cmd.go`",
  word-for-word what `tgw5-mint-key-era-split` quotes, and `leads tasks_next_cmd` instructs an agent
  to run a LINE COUNT and a MATCH COUNT "and compare". Re-minting was executed end to end against an
  `origin/main` archive: **0 of 4 rival groups survive**, 48 keys → 62, and a structured
  field-by-field comparison plus a raw line diff prove ONLY `quantity` changes (114 changed lines =
  57 rows × 2, zero non-quantity content), with a byte-identical failing-test set before and after.
  So the data half is settled and lossless. The MECHANISM is not: that proof used a direct file
  rewrite, which `ledger/README.md`'s "written once, never modified" forbids and which no verb
  exposes. The resolution is the law this epic already lives by one layer up — **`leads` re-derives
  the LEVEL from the command at render time and never trusts storage** — extended to the key itself.
  `foldLedger` keys on `quantityPhrase(rerun)`, keeps the stored value only as `stored_quantity` +
  `quantity_restated` drift signal, and re-derives `derived_level` the same way (closing
  `tgw2-fold-reread-derived-level` in the same seam). The 62 files keep their bytes; the fabricated
  rivals stop rendering; `tgw5-corpus-backfill` gains a store keyed by one grammar. Options (a)
  discard, (b) bound the split as permanent, and (c) carry a mint-era field are all REFUSED: the
  first loses 62 rows of genuine foreign work, the second bakes a known fabrication into the
  product, and the third is a schema amendment bought to avoid a re-derivation this codebase already
  performs elsewhere for free.*

- **D78 — every grip verb declares WHICH TREE it is answering from, on STDERR.** *Why: this is the
  only item on the wave's list with a recorded incident. Running `leads ledger` from a worktree
  printed the pre-`leads` usage string because it executed the WORKTREE's stale `ledger.mjs`; the
  lead read a shipped feature as unshipped, while verifying this very wave. The adjudicator is
  un-adjudicated: grip applies "a local checkout is an L3 claim that can run 200 commits stale and
  lie silently" to every fact it judges and to nothing about itself. Placement is measured, not
  reasoned: an unconditional STDOUT banner breaks `leads --json` AND `fold` (both
  `JSON.parse(stdout)`, both failing `Unexpected token 'g', "[grip-prove"… is not valid JSON` — and
  `fold` emits BARE JSON with no flag gating it, so stdout corrupts the tool's only always-machine
  verb). The same banner on STDERR is green across all 460 tests: no harness merges the streams on a
  successful run and no test asserts stderr is empty. Embedding it in the JSON is also green but
  costs four separate edits (`write`/`prescreen` have no `--json` to embed into and `fold` has no
  wrapper object to add a key to) — four places to silently miss a verb, for the same guarantee.
  STDERR is the ruling; `leads --json` additionally carries it as a `provenance` object because a
  machine consumer cannot read a banner. It states the tree root, HEAD, whether HEAD differs from
  `origin/main`, and whether the working tree is dirty — the exact four facts whose absence cost the
  false negative — and it says "as of last fetch", because it performs none.*

- **D79 — P5 is SETTLED. `leads` SHIPS, and the honest finding is not the cut criterion but the
  PRECISION.** *Why: P5 ran for the first time in this epic's life, twice, under two independently
  derived term lists: 50.0% honest-empty at subsystem granularity (the grain D59 ratified) and
  65.0% at file-path granularity — the second reproducing D59's headline exactly. Both are below
  the >70% cut, so `leads` is not cut and the question is closed; no builder spends a slice
  re-running it, and no prompt anywhere gains a rerun exhortation. Published whichever way it fell,
  per D21's precedent. Two corrections ride along. (a) D59's three decisive readings do NOT
  reproduce on the shipping store: `mix test` → 0 rows (claimed 35), `api/lib` → 0 (claimed 26),
  `internal/cli` → 11/8 subjects (claimed 12). Two of three are zero. Those readings are RETIRED
  into the D23/D37/D52 class and may not be quoted again. (b) P5's own original wording is not on
  `origin/main` — the charter cites it by number five times and never states it — so every SHIP/CUT
  statement in this epic is against D59's paraphrase, and that is now written down rather than
  implied. The measurement that actually answers D46 is precision, and it is **29.2%**: 92 of 130
  returned rows are not about the queried subsystem, because `matchesQuery` hays `subject + "\0" +
  rerun`, i.e. the full command text. `leads origin/main` returns 51 of 62 rows with ZERO subject
  matches — a pure dump, D45's `cmd:<head>` dumping-ground failure reappearing through the half D45
  never covered. Against a repo-wide grep `leads` wins 10 of 10 non-empty terms; against the SCOPED
  grep an agent types once it knows the subsystem, 8 of 10 with one outright loss; correct for
  precision and it is 3 of 20. `leads` beats grep in a narrow, precise, in-band slice — exactly
  D46's stated intra-epic scope and no wider — and that is the claim the charter carries from now
  on.*

- **D80 — `leads` matches on the SUBJECT by default; the command text is opt-in.** *Why: the direct
  consequence of D79's 29.2%, and the fix is one predicate rather than a ranking. Two of the ten
  non-empty terms are pure noise and both were counted as wins: `leads js` returns 30 rows of which
  5 are under `js/` (`package.json` matches "js" via "json"; `.workflow.js` contributes 11 via its
  extension) and `leads test` returns 9 rows of which 0 are on-subsystem. Subject-default is not a
  recall cut, because the empty state stays honest and gains a number: when the subject index has
  nothing but the command text does, `leads` says so and names the flag rather than printing
  nothing. This closes `tgw5-leads-short-needle-false-positives` with a measurement instead of a
  heuristic, and it keeps D44's rule that the matching rule must be restatable in one sentence.*

- **D81 — the HOLD on `tgw5-corpus-backfill` STANDS, and for a stronger reason than volume.** *Why:
  the backfill's source corpus is the MIRROR of the store it would write into. The 652 committed
  proofs classify 87.1% working-tree / 11.7% shared-ref, against the store's 82% shared-ref / 18%
  tree-sensitive — so a classifier validated on the 62 rows is validated against the inverse of the
  distribution 4x volume would mint, and the naive grammar's 2.0% error rate on that corpus is
  else-branch absorption, not discrimination (a trivial always-working-tree classifier errs 12.7%,
  and 568 of 652 correct answers arrive via the else branch). Five of the seven resisting forms have
  ZERO instances in the current store — `git status`, `git diff`, bare `git log`, SHA-pinned reads,
  `stash`/`rev-parse HEAD` — so a grammar gated on the 62 rows cannot fail there and would ship
  green. Backfill dispatches after the classifier AND the fold re-derivation are on `origin/main`,
  and its own gate is the 652-proof corpus, never the 62-row store.*

- **D82 — the wave gate is `cd <worktree-root> && node --test tooling/grip/test/*.test.mjs`,
  expecting 460 tests / 459 pass / 0 fail / 1 skipped, and the `cd` is load-bearing.** *Why: the
  suite has never been run green from a proper tree in this epic's life — the two survey readings
  (369/382 and 414/424) are both STALE FILE SETS, and 424 = 460 − `leads.test.mjs`(30) −
  `wiring.test.mjs`(6) exactly. From a fresh worktree at `origin/main` it is 460/459/0/1, identical
  at `6a5baa247` and at `515f14fdd`, stable across three consecutive runs, with per-file totals
  summing to 460 (no order dependence, so a builder may gate on its own file alone). The single skip
  is `rerun.test.mjs:789`, gated `{ skip: process.env.GRIP_LIVE !== "1" }` — a green baseline is
  `# fail 0 # skipped 1`, NEVER `# skipped 0`, and a builder reporting 460/460 has changed
  something. Three facts every slice must carry. (a) The suite is CWD-DEPENDENT: run from outside a
  git repo it fails 3 tests in `rerun.test.mjs` with `128 !== 0` and `'UNAVAILABLE' !== 'FAILED'` —
  assertion-shaped errors that mimic a real regression. (b) The directory form `node --test
  tooling/grip/test/` fails spuriously with `ERR_TEST_FAILURE`; the glob is the invocation. (c) NO
  CI WORKFLOW RUNS THIS SUITE — `grep -rl grip .github/workflows/` returns nothing, and the four
  workflows containing `node --test` each run a different suite. The gate is manual and local, so a
  builder's QUOTED output is the only evidence there is; and because `screenCommand` refuses every
  `node` command per D62, no slice can store its gate proof as a grip recipe — it goes in the task's
  evidence field as quoted output.*

- **D83 — builders branch from `origin/main`. The primary checkout is not a base, and the wave-5
  log is landed retroactively rather than re-authored.** *Why: `/Volumes/SATECHI/github/barkpark` is
  41 behind / 4 ahead, its `tooling/grip` is 15 files and ~3968 lines behind, `leads.test.mjs` does
  not exist there, and it carries an 18-file STAGED grip diff that matches no commit: 17 of the 18
  files are byte-identical to the stranded branch `truth-grip/wave5-decide`, and the 18th
  (`census.mjs`, 757 lines against main's 1066) is abandoned `tgw4-census-run-is-not-hermetic` WIP
  still containing the literal NUL byte that D67 proves was already fixed. A builder gating there
  gates a hand-assembled tree. The charter itself reproduces the wave's own thesis three ways
  simultaneously — 1266 lines on `origin/main`, 1018 in one worktree, 617 in the primary — and two
  surveyors independently called their own copy "this worktree". A worktree created FRESH from
  `origin/main` gets the right charter and the right file set; nothing else does. Separately, the
  wave-5 review commit `170f01420` is proven stranded by CONTENT, not merely by ancestry: its diff
  parent blob is byte-identical to `origin/main`'s current charter blob, it lives only on
  `truth-grip/wave5-review` (mirrored on `review/union-final` and `review/union-probe`), and no PR
  was ever opened for it — while its 119 lines of graded narrative are the only record of how wave
  5 actually shipped. Its CODE is fully landed (`git diff origin/main..truth-grip/wave5-review --
  tooling/grip` excluding tests returns ZERO files), so this is docs-only stranding. It is appended
  verbatim below, marked as landed retroactively, rather than rewritten from memory.*

- **D84 — the 254-vs-240 divergence is a NON-FINDING; 240 is stale D63-superseded prose, not a
  live count.** *Why: both entry points (`screenCommand` over the corpus and the census reach)
  admit 254 of 651, and the admitted set-diff is empty — there is no disagreement to reconcile. The
  `240` comments still sitting in `census.mjs` (and `screen.mjs:43`) are the pre-D63 waves-2-4
  reach, superseded by tgw5-screen-hardening's 254/651. They are annotated as historical where a
  slice touches them and filed as `tgw8-bl-stale-240-comment` where not; no future surveyor may
  re-quote 240 as the live reach.*

- **D85 — the real volume is +167 answering recipes = 3.7x, NOT 4x, and the ±live-services band is
  named.** *Why: measured over the frozen 651-distinct corpus through the census-as-minting
  instrument (D58): 254 admitted → 195 executed → 167 answering/minted. The store goes 63 rows/45
  subjects → 230 rows/144 subjects (135 leads-indexed, `cmd:<head>` excluded per D45) = 3.71x. Of
  the 167, 32 are network-reaching {bp:20, gh:11, curl:1} — the live-services band — so a hermetic
  re-run floors at 135. The "4x" the Strategize estimate carried is retired; 3.7x is the re-run
  number, and the band is published beside it, never hidden. Cost consequence, stated: the committed
  230-row store means the grip suite now censuses 32 network-reaching commands on every run (~47s,
  network-touching); on hermetic CI they degrade to SPAWN-ERROR which the tests tolerate.*

- **D86 — `internal/cli` is 11 recipes today / 20 post-backfill — NOT 16, NOT 27.** *Why: a
  verified number replacing two wrong ones (the D23/D37/D52 retired-figure discipline). Strategize
  mis-stated 16; a later reconciliation mis-stated 27. Re-derived on the 62-row store it is 11, and
  on the integrated post-backfill store the Review trial measured exactly 20 — the W4 prediction
  pinned and confirmed.*

- **D87 — the subsystem rollup is ALL-ANCESTOR-PREFIX MATCH-COUNT, the band EXCLUDES `cmd:<head>`
  subjects, and the real move is 15 → 28 full / 15 → 25 leads-faithful, not the projected 36.**
  *Why: two rules wore one name. All-ancestor-prefix counts a recipe under `api/lib` for `api`, for
  `api/lib`, and for its exact subject (never a greedy single-bucket partition), reproducing 15 band
  keys → 28 at 4x; greedy partition yields 6 → 17 — a different product. All-ancestor is pinned. The
  band is computed over leads-indexed subjects only (`cmd:<head>` hidden per D45) so the reader's
  quoted number matches the tool's. Post-backfill the Review trial confirmed the band shifting: at
  229 rows `api/lib`(30) and `.claude/workflows`(21) cross into >20-buckets, so an over-band key
  renders its immediate-child breakdown rather than a flat dump.*

- **D88 — the RCE close is a CALLER-BOUNDARY WIRE (Design B), 0 test-flips, proven against a naive
  `rerun.mjs:676` swap that is 12 flips with 8 `screenCommand` defects.** *Why: `cli → adjudicate →
  runRerun` re-executed a fact's `rerun` by default, gating only on `classifySafety` — which admits
  22/22 named outage probes (systemctl stop, `mix ecto.drop`, reboot, a bare `cp` into api/lib/) and
  51/53 of DANGER_SET — before `spawnSync`. A `facts.json` whose rerun was `cp /etc/hosts
  /tmp/grip-marker`, adjudicated with NO flags, MATERIALISED the file. The fix swaps adjudicate's
  DEFAULT runner from bare `runRerun` to a new `screenedRerun`: `screenCommand` decides first,
  `runRerun` executes only what it admits, a refusal returns UNSAFE-RERUN → REJECTED before any
  spawn. `classifySafety`'s grammar is NOT rewritten and `runRerun`'s internal gate is NOT swapped
  (git diff on rerun.mjs/screen.mjs = 0 lines), so `rerun.test.mjs`'s 35 direct `runRerun` callers
  keep exact behaviour — zero flip cost. An injected runner still bypasses the screen BY DESIGN (the
  census owns its own screen, D47). Coverage bound stated, not expanded: the boundary inherits
  screen.mjs's `git -C` parse defect and merge-base refusal, so those safe reads are over-refused
  (fail CLOSED) until tgw4-screen-git-global-option-audit / tgw4-rerun-silence-fixes land. Proven by
  a marker probe that goes from materialised to refused (W7).*

- **D89 — fold-hardening criterion 6 (re-derive `derived_level`) already SHIPPED via #5442 —
  CONFIRM, don't rebuild — and the projection is a TWELVE-field allowlist, "six" is stale.** *Why:
  `foldLedger` already re-derives `derived_level` from the command at fold time (level_restated=0
  over the committed rows), so criterion 6 is confirmed by running the existing test, not
  re-implemented. What tgw5-fold-hardening adds is orthogonal and real: the fold COMPOSES
  `admitRecipe(row,{now,screen})` after the crash-safety gate and routes every rejection (VALUE-
  STORED, REFUSED-COMMAND, FUTURE-OBSERVED-AT, LEVEL-SKIP, UNKNOWN-FIELD) into the existing
  `unreadable[]` channel, which drives the fold CLI's nonzero exit — the READ path now rejects what
  the WRITE path rejects. The projection that drops `value` before `entries[]` is a NAMED ALLOWLIST
  of twelve fields (it grew from six when the fold began re-deriving its own key); the guarantee is
  the allowlist, never its cardinality.*

- **D90 — backfill criterion 7 (re-adjudicate P5) is STRUCK before dispatch — D79 SETTLED P5.**
  *Why: D79 closed P5 ("no builder spends a slice re-running it"). A criterion ordering a builder to
  re-litigate it would re-open a settled question; it is struck, D79/D90 cited, and the backfill
  moves on.*

- **D91 — `leads-subject-first` was a LIVE 25/30 defect (`leads js`), folded into S2 as SUBSYSTEM-
  BOUNDARY SEGMENT MATCHING.** *Why: post-#5441 subject-default matching still hayed `js` against
  `package.json` (via "json") and `.workflow.js` (via its extension) — 25 of 30 returned rows were
  not under `js/`. The fix: a needle matches a subject iff it EQUALS it or is a leading PATH-SEGMENT
  prefix (`js` matches `js/packages/x`, never `package.json`), case-insensitive, no needle
  tokenising. Measured at Review on the integrated store: precision is 100% across every subsystem
  query (against D79's retired 29.2% and post-#5441's 74.4%) — the W5 prediction (>80%) confirmed
  decisively. A real capability tradeoff, ratified: `leads grip` no longer finds `tooling/grip/…`
  because grip is a middle segment; the null state names it.*

- **D92 — `leads`/`fold` truncated stdout on a pipe (a `process.exit` race); the fix is
  `process.exitCode`, and every harness REDIRECTS to a file, never pipes.** *Why: `main().then((c)
  => process.exit(c))` raced Node's asynchronous pipe flush — a multi-kilobyte fold/leads JSON tore
  at ~512 bytes the instant a caller added `| cat` or `| jq`, and a piped `JSON.parse` threw on the
  truncated bytes while a redirect to a file got the whole thing (512 → 2834 bytes measured).
  Setting `process.exitCode` and letting the event loop drain flushes stdout on natural exit;
  ledger.mjs opens no lingering handle, so the exit stays immediate. The leads-vs-grep trial
  captures `leads --json` by REDIRECTING to a file descriptor for the same reason, and a test proves
  the redirected JSON parses.*

- **D93 — the epic is NOT SEALABLE in wave 9, and that is a pre-authorized, honest outcome.**
  *Why: closing the root does NOT remove its descendants from the claim queue. `ready_query/1`
  (`api/lib/barkpark/tasks/queue.ex:46-180`) — the ONE definition both `ready/1` and `Claim.claim/2`
  ride — has five gates (type/kind, `lifecycle_status in ~w(open blocked)`, `QueueGate`, the
  `blocks` anti-join, the `dependencies` anti-join) plus twin-collapse, and **none reads the
  parent's lifecycle_status**; every `parent_as(:doc)` in that file is Ecto's binding macro and the
  only `content.parent_id` read is the opt-in phase filter at :235. `close.ex` contains ZERO
  occurrences of `parent_id` and its one cascade (`cascade_unblock_dependents!/1`, :598) walks
  INBOUND `blocks` edges — closing a task can only ADD rows to the pool. Confirmed L1 on production
  twice: 134 of 139 open tasks whose parent is `done` sit in the live ready pool right now (the
  other 5 are excluded by an active claim, not by any parent), and a controlled scratch parent/child
  went 845 → 847 → **846** on closing the parent, with the child still ready AND successfully
  claimed. So a sealed root with 64 claimable descendants is not cosmetics — it is an active queue
  defect that `bp task next` serves forever with no signal the parent is sealed. D71 already refused
  this move one level down ("closing it would orphan real work behind a closed parent"); wave 9
  applies D71's own reasoning to the root. Precedent for the refusal: cloud-console D72, "NOT YET
  SEALABLE — and that is a pre-authorized, honest outcome."*

- **D94 — the seal predicate, adopted in shape from the mobile charter's D34.** The root closes
  only when ALL of: (a) every acceptance criterion is stamped with evidence carrying a literal
  rerun command, adjudicated by grip itself; (b) **ZERO rows in the `tgw*`/`truth-grip*` namespace
  carry a claimable lifecycle** (`open` or `blocked`) — verified by intersecting the namespace with
  a live `bp task ready --all`, **never** by a `child_count`-derived census; (c) the root closes
  LAST, and no wave-log entry, Paper, memory note or commit message may use the word SEALED for
  this epic before it does. *Why: the disposition surface is 64 rows, not 57 — seven ready `tgw*`
  rows (`tgw2-acceptance-suite`, `tgw2-l4-grip-corpus-selfref`, `tgw2-verify-writes-back`,
  `tgw-bl-epic-cycle-minitems-comment`, `tgw-bl-fanout-floor-harness`,
  `tgw-bl-interpreter-denylist-census`, `tgw-bl-wild-bulk-roster-floor`) hang under
  `tgw1-workflow-gate-wiring`, which is itself `done` at 8/8. A direct-child census under-counts by
  seven and re-creates D71's orphan one level down. Clause (b) keys on the READY POOL because that
  is the thing that actually harms a builder. `considering` is a legitimate third disposition:
  `@claimable_statuses` is `~w(open blocked)` (validation.ex:31), so a parked row leaves the pool
  without the false-done of closing it — proven live, authoring-excellence's two `considering`
  children are ABSENT from an 846-row ready pool while its four `open` children are present.
  `considering` is reachable ONLY via `bp task stage` — `close.ex:26` is `~w(done cancelled blocked)`.*

- **D95 — criterion 2 SPLITS: 2a is MET, 2b is NOT MET and keeps a named owner.** 2a — "every
  rejection class that has a control fires under mutation, and a control that does not behave as a
  control is its own third outcome class" — is met: `node tooling/grip/cli.mjs --selftest` fires
  15/15 and `node tooling/grip/ledger.mjs --selftest` fires 19/19, and the third outcome class was
  proven **by mutation** for the first time in this epic's life — breaking the LEVEL-SKIP control's
  clean twin (`git show origin/main:…record.mjs` → `cat …record.mjs`, L2 → L3) produced `CONTROL DID
  NOT BEHAVE AS A CONTROL (1)` at **exit 3**, with the other 14 controls still `ok`. 2b — the
  frozen-fixture, per-class fail-before + never-cry-wolf half — is NOT met and is owned by
  `tgw2-acceptance-suite` (P0, 0/7, open). *Why the split rather than "met with a stated bound": a
  bound is honest when it is a residual; it is dishonest when it eats the claim's quantifier. Here
  it eats three of the criterion's four load-bearing words at once. **every** fails — exactly three
  rejection classes have no control or test anywhere (`NO-QUANTITY` mint.mjs:482, `NOT-A-REF`
  level.mjs:579/583, `WRITE-FAILED` ledger.mjs:652); the digest's "five" is wrong. **against a
  frozen adversarial fixture** fails — the mutation controls are built from an inline synthetic
  `CLEAN` object at cli.mjs:43-49 and never read `fixtures/level-skip-specimens.json`; the frozen
  fixture is exercised only by `acceptance.mjs`, which demonstrates ONE class (LEVEL-SKIP) with
  specimen 4 ADMITTED-by-design (D12) and specimen 5 caught by the wrong rule. And **class** is
  undefined for the epic's biggest instrument — `screen.mjs` has NO class vocabulary at all
  (`"HEAD"` and `"PWNED"` are its only shouty strings; refusals are free-text `reason`, :135), its
  discipline being named SETS (`runNamedSets()` → `{falsePermissions:[], falseRefusals:[]}`), which
  is arguably STRONGER than per-class plants but structurally cannot satisfy a class-quantified
  criterion. An amendment that keeps 2a and drops 2b is softening, and it is the single most likely
  way this wave goes wrong.*

- **D96 — criterion 2's honest evidence ceiling is L3, and the "derive L2 or better" demand is a
  TRAP for criteria 2 and 4.** `level.mjs:184` keys L2 on remote refs only, and says so at :180-183:
  "`git show HEAD:…` or a local branch is a read of the local checkout's object store — L3."
  Measured through grip's own `deriveLevel`: `git ls-tree -r 1514f52cb …` → L3, `git show
  1514f52cb:…` → L3, `node tooling/grip/cli.mjs --selftest` → L3, `git show origin/main:…` → L2.
  Criterion 2's fact is LOCAL EXECUTION and has **no L2 route at all** — worse, `node` is a REFUSED
  head (`screen.mjs:1096`), so the selftest can be neither adjudicated nor stored: **grip cannot
  adjudicate its own execution, by design and permanently.** Criterion 4's fact is HISTORY, and
  grip's L2 means "what the remote holds NOW"; its only L2 route is the forge (`gh api
  …/commits/<sha>` → L2, and it works). *Why this is a decision and not a footnote: rewriting
  criterion 4's evidence as `git show origin/main:…` to buy L2 silently swaps the question from
  "what did wave 1 commit" to "what does main hold today" — buying an authority level by changing
  the question, which is this epic's disease wearing this epic's uniform, on this epic's own
  tombstone. State L3 honestly; never manufacture an L2 wrapper. Corollary (D65 is live and aims
  straight at this seal): a purely LOCAL grep whose search string mentions a remote form is
  PROMOTED — `grep -n "git show origin/main:…" <charter>` derives **L2** and `grep -rn "ssh
  root@89.167.28.206" docs/ops/PROD_OPS.md` derives **L1**. Since wave 9's criteria are about the
  charter and about grip's own commands, no criterion evidence may be a local grep of the charter.*

- **D97 — criterion 3 is REWORDED: clause (b) is UNSATISFIABLE, not unmet, and clause (c) is FALSE
  in `wild-bulk-cycle`.** `git show origin/main:.claude/workflows/wild-bulk-cycle.workflow.js |
  grep -c VERIFY_SCHEMA` returns **0** — that cycle has no verify phase at all (its ladder is Plan →
  Recon → Survey → Digest → Cut → Preflight → Harmonize → Build → Review → Polish → Verdict), so no
  amount of building makes "VERIFY_SCHEMA in BOTH workflow files" true. The reword's PROVENANCE, so
  it reads as correction and not retreat: criterion 3 derives from `tgw1-workflow-gate-wiring`
  (done, 8/8), whose own criterion reads "the survey and verify **fleets**" with evidence naming two
  call sites in ONE file, and D14 pairs SURVEY with VERIFY — survey *in addition to* verify, never
  two files. The root criterion is a root-level over-generalisation of a slice-level claim about two
  fleets. Clause (c) is separately FALSE and is a REAL HOLE, not a wording problem:
  `wild-bulk-cycle.workflow.js` has **zero** `gateFactProvenance` and serialises survey facts
  UNGATED into the Digest prompt at :545, so a fact with no rerun command reaches the Fable that
  cuts up to 60 tasks carrying no demotion marker. Wave 9 SHIPS that gate (slice S7); the reworded
  criterion is stamped by the lead on S7's merge. *Also settled: `bp-epic-cycle` is airtight and the
  wave-2 blind-projection defect is CLOSED — :699 now projects `facts: s.facts`, and every
  serialisation (:587 Digest, :696/:699 Decide) happens AFTER its gate at :570/:673. And the gate is
  LIVE, not merely present: 149 RENDERED gate lines across 75 run records, 18 of them non-zero, peak
  42/153 demoted.*

- **D98 — criterion 4 is MET IN SUBSTANCE with its stated verifier RETIRED as unsound. D13
  governs; D26 is a red herring twice over.** Wave 1's tree at `1514f52cb` is 9 files with **no
  `ledger/` directory** — that dir first appears in wave 2 at `9e1192c03` (#4982) — so D26, which
  permits durable storage "from this wave" (wave 2) and amends D10, cannot govern a wave-1-scoped
  criterion; citing it there would itself be a level-skip. What actually kills the verifier is
  **D13**, ratified in wave 1, in the same charter, three entries above D26: wave 1 committed
  `tooling/grip/fixtures/evidence-corpus.json` (16,009 lines, 1,902 evidence + 652 proofs) under a
  commit whose subject is literally *"freeze the evidence corpus … (tgw1)"*. So the clause "verified
  by the absence of any new persisted corpus" was **self-refuting the day wave 1 merged**. The
  anti-goal itself held: `git show 1514f52cb:tooling/grip/record.mjs | grep -n 'writeFileSync\|
  appendFileSync\|mkdirSync\|node:fs'` returns NOTHING (the `grep -c fs` = 2 is two false positives
  — `findRefs` at :33 and `for (const ref of` at :75), and D10's actual concern was gitignored
  irreproducibility, not bytes on disk — the corpus is COMMITTED, so it re-derives identically in a
  clean worktree, which is precisely the defect D10 named. *Why amend rather than leave it false: as
  literally worded the criterion is refuted at L2 by the epic's own wave-1 merge commit, so there is
  no third option where the sentence stands unchanged and reads true.*

- **D99 — `tooling/grip/ledger/` is an UNOWNED COMMONS, and that — not a grip regression — is why
  the suite is RED on main.** Measured on a clean `origin/main` worktree: **622 tests / 618 pass /
  3 fail / 1 skipped in 193s**, rc 1. All three failures share one root cause — three tests assert
  over *every `*.json` in a directory nobody owns*, while other epics commit into it. Nine tracked
  files named `grip-*.json` are not run records at all (no `recipes[]`): the PDS wave-20 (#5514), ae
  wave-10 (#5603), deep-investigation (#6131), connectors, s3-anchor, two premise-smoke, gui-spec
  and elixir-chat rows. `binding.test.mjs:444` dies `run.recipes is not iterable`;
  `ledger.test.mjs:1281` — the **D89 CONTROL itself** — folds `unreadable 371` against an asserted 0
  (`MALFORMED-ROW 202, LEVEL-SKIP 60, REFUSED-COMMAND 48, UNKNOWN-FIELD 45, MALFORMED-RUN 9,
  VALUE-STORED 7`) with `level_restated 1`; `mint.test.mjs:549` reports **277 of 601** rows moving
  subject/deps, 202 of them from a stored `subject: null`. THE FIX IS SHAPE, NOT QUARANTINE: a file
  without `recipes[]` is NOT a broken grip run, it is **not a grip run** — it earns its own named,
  counted `NOT-A-RUN` class, and the three globbing tests scope to grip-owned conformant runs the
  way `binding.test.mjs`'s pinned `CENSUS_RUN_FILES` already does (its comment at :40-47 explains
  exactly why pinning was chosen there). Deleting or quarantining other epics' files is FORBIDDEN —
  D26 sanctioned one-file-per-run and those waves used the store as designed; the defect is that
  grip's read path has no schema discriminator. *And this is the epic's own disease at the meta
  level: three tests were written to be growth-proof by globbing, over a directory the epic does not
  own, and the resulting red sat unnoticed on main.*

- **D100 — D82's baseline is RETIRED; the surviving invariant is `# fail 0 # skipped 1`, never a
  test count.** D82 states 460/459/0/1; measured today is 622/618/3/1 — stale by 162 tests, and the
  count moved that far inside one epic. The single skip is real and still correct
  (`rerun.test.mjs`, `live: prod distinguishes right-route from wrong-route # SKIP`, GRIP_LIVE-gated),
  so `# skipped 0` still means something changed. D82's CWD discipline and its no-CI claim both
  stand (`git grep -l grip origin/main -- .github/workflows/` exits 1 with no output, re-derived
  today). *Corollary — D82's "cd is load-bearing" is UNDERSTATED and for a different reason than it
  states: the >900s `trial-leads-vs-grep` observation is neither a hang nor buffering, it is
  `REPO_WIDE_EXCLUDES` (trial-leads-vs-grep.mjs:327-329) omitting `.claude/worktrees`, so
  `runGrep(term, ".")` at :343 walks 1,339 nested repo copies when run from the primary checkout —
  caught live at 38:30 elapsed. Isolated from a clean worktree that file takes **9 seconds**. The
  defect is in the exclude list, not in the worktree count, and it cannot fire on a CI runner, whose
  fresh checkout has no nested trees.*

- **D101 — D85 is RETIRED on BOTH digits and mechanism, and the manufacture is the epic's disease
  inside the epic's instrument.** Reach is **17** `{gh:10, bp:6, curl:1}`, not 32 `{bp:20, gh:11,
  curl:1}` — identical under full and hermetic PATH, so it is not a PATH artefact. And a hermetic
  run produces **ZERO** SPAWN-ERROR rows: `census.mjs:422` maps rc 127 → `PATH_GONE`, which
  `census.mjs:299` puts in the **DECAYED** set; D68's tolerance (census.test.mjs:619) is scoped to
  the OUTAGE case only — tool PRESENT, network down, exit 1 with dial/connect stderr. So the
  tolerated class D85 leans on never fires when a runner simply lacks the binaries. Side by side on
  the same corpus: full PATH `decayed 2 / 0.743%` → verdict "CONSISTENT"; hermetic `decayed 16 /
  5.926%` → verdict "CONSISTENT". **14 of 16 hermetic decayed rows are pure missing-binary** (11
  bp/gh, 3 `go`), i.e. 87.5% of the published decay numerator is manufactured by the runner's
  toolbox — and `census.mjs` has NO tool-availability probe and none of its five `caveats[]` can
  disclose it. Any gate that prints `decayPct` without a tool-availability header beside it is
  publishing "5.9% of stored recipes have rotted" when the true statement is "94% of that number is
  that this container has no `bp`". *Cost note that survives: the hermetic census is CHEAPER, not
  slower — 17.2s of summed command time vs 57.3s — and `census.test.mjs` finishes hermetically in
  62s, 66/66. It is not the file that hangs.*

- **D102 — the volume family is RETIRED, not restated, and `3.71x` is arithmetically impossible.**
  62 and 63, and 229 and 230, are two REAL store snapshots ~90 minutes apart on 2026-07-21 — both
  re-derive to the digit — so the charter's five-site 229/230 split is not an error of measurement.
  But `3.71x` is `230/62`: the numerator of one snapshot over the denominator of the other. The
  coherent pairs are `63 → 230 = 3.65x` and `62 → 229 = 3.69x`. Rule from here: volume-derived
  figures (rows, subjects, band counts, `internal/cli` reach, the leads-vs-grep splits) may be
  quoted ONLY past-tense with their snapshot and sha named, because `tooling/grip/ledger/` is a
  shared write target six other epics wrote into between 2026-07-21 and 2026-07-26 — restating them
  with today's numbers just resets the clock, which is the failure D23/D37/D52 already retired three
  times. `254 / 651 = 39.0%` SURVIVES as a live figure: it reads
  `fixtures/evidence-corpus.json`, which has exactly ONE commit in history and whose blob is
  byte-identical on main, and `census()` never touches the ledger — but it is code-dependent (194 →
  240 → 254 as `screen.mjs` changed), so it must be quoted with the sha of the screen that produced
  it. *Also live and unfixed: today's store reports TWO row counts — 332 via the library
  `foldLedger(dir)`, 327 via the CLI, which injects `cliBounds()`. Any row count the seal quotes
  must name its reading path or it is ambiguous by 5.*

- **D103 — the FENCE changes: DROP `bp-epic-cycle.workflow.js`, ADD `wild-bulk-cycle.workflow.js`.**
  PR #6086 (`feat/epic-memory-journeys-debrief`, OPEN since 2026-07-25) modifies
  `.claude/workflows/bp-epic-cycle.workflow.js` **+200/−17** and is the only open-PR collision in
  the fence as originally written; a third concurrent editor holds uncommitted changes to the same
  file in `.claude/worktrees/wf_d2874b15-076-4`. Nothing wave 9 needs touches that file.
  `wild-bulk-cycle.workflow.js` is the opposite: ZERO open PRs touch it, its last commit on main is
  this epic's own tgw2 slice (`be6dd195f`), and `tooling/grip/test/fanout-floors.test.mjs:36`
  already reads that exact path — so a builder editing it is already covered by the epic's own suite
  gate. *Second, unreported fence collision, recorded for the record: PR #5754
  (`docs/grad-ledger-w17`, OPEN) touches three `tooling/grip/ledger/*.json` — harmless AND closable,
  since all three blobs are already byte-identical on origin/main.*

- **D104 — grip CI ships, but as a SECOND round, after the suite is green.** The gate is authorised
  by the wish's own closing sentence ("a wave that stores nothing durably but tightens the gate has
  succeeded") and by D17 being about a merge GATE rather than a ROT DETECTOR — but shipping it while
  main is RED would join a standing noise floor and die on arrival. That floor is real and measured:
  the `Format (advisory)` check has been red on main since 2026-07-20 (filed as
  `format-gate-red-on-main-teaches-dismissal`, still open) and PRs #6295/#6296/#6297 each carried
  THREE failing checks and merged anyway. Advisory reality re-derived today:
  `branches/main/protection` → HTTP 404 "Branch not protected", `rulesets` → `[]`,
  `rules/branches/main` → `[]`. So the workflow must (a) be path-filtered to `tooling/grip/**` plus
  itself so no other epic's PR ever waits on it, (b) state IN ITS OWN OUTPUT that it is advisory and
  cannot block, and what a hermetic green does NOT certify (per D101), (c) satisfy the never-cancel-main
  ratchet — `doc-gates.yml` triggers on `.github/workflows/**` and runs
  `scripts/never-cancel-main-check.sh` as a BLOCKING step, which fails a workflow that both triggers
  on push-to-main and sets a bare `cancel-in-progress: true`; use `${{ github.ref !=
  'refs/heads/main' }}`. Escalation uses the mechanism that already exists and is live-proven —
  `scripts/file-ci-failure-issue.sh` with `CI_FAILURE_KEY: grip-suite` and `permissions: issues:
  write` — which is key-scoped, not workflow-name-scoped, so it cannot merge into the standing
  `CI failure: paper-readers` issue (#5658). *Stated honestly, because #5658 has sat 5 days with 0
  assignees and 3 bot pings: that tier does not deliver human ATTENTION. What it delivers is
  durable, greppable state a cold agent finds in one command — which, in a repo whose primary actors
  are agents running waves, is the whole value. Claim `tgw6-bl-grip-suite-has-no-ci`; do not file a
  new task, and do not have the workflow file a bp task (`BARKPARK_TASK_TOKEN` does not exist and
  the write would land as an invisible DRAFT).*

- **D105 — "re-home" has no destination, so residue stays as DEMOTED CHILDREN of this root.** Four
  sealed epics agree and cloud-console states it in one line — *"Open residue lives as CHILDREN, not
  the epic"* — with `<prefix>-bl-*` ids, priority demoted, brief made self-contained, parent
  UNCHANGED. This epic's ONE prior re-home attempt (`tgw3-bl-rehome-research-coverage-bugs`) is
  still open precisely because it could not name a destination, and no api/** epic can own the
  server-side `type:fact` work: felix-pristine is improvement-only with all 12 audit children done,
  and a new schema type is new capability, not an audit fix. For residue with no owner at all, the
  airdrop-leakseal precedent applies — file it **parent-less with a `proj:` label**. Wave 9
  therefore does NOT invent a destination epic and does NOT file a new epic root inside a seal wave.

- **D106 — stranded work is RECOVERED, never re-filed as a fresh task.** Five worktrees under
  `.claude/worktrees/` hold uncommitted grip edits absent from origin/main, and two are
  security-shaped and live-proven: `wf_6d5c9474-c05-24` adds write-flag guards to `screen.mjs`
  (+71/−2) closing `git <verb> --output=<file>` AND the separate-token `--output <file>` spelling —
  both live-proven to write a real file at exit 0 — plus the `go` profiling family
  (`-coverprofile`, `-cpuprofile`, `-memprofile`, `-blockprofile`, `-mutexprofile`, `-trace`,
  `-outputdir`, `-c`), which the old exact-token `hasFlag(argv, "-o", "-exec")` check could not see;
  and `wf_6d5c9474-c05-25` moves an untrusted `url` out of a `JSON.stringify`-interpolated `/bin/sh
  -c` string into argv form (+17/−3). `GIT_OUTPUT_RE` returns nothing on origin/main, so these are
  genuinely stranded, not merely behind. *Why this is a decision: sealing an epic whose thesis is a
  fail-closed caller boundary, while two proven write-bypasses in that very boundary sit uncommitted
  in a temp directory one `git worktree prune` from destruction, is the exact failure this epic
  exists to end. Recover through the gate — the fixes are unverified and must be mutation-proven,
  not assumed.*

- **D107 — WAVE 9 NEVER FLEW, TWICE; wave 10 is the closing wave and it ABSORBS wave 9's slice
  set rather than re-booking it.** Attempt 1 drove Strategize→Decide overnight, ratified D93–D106,
  filed six slices and pushed the charter at `ba9914129` (04:19+0200) — then died before one builder
  flew. Attempt 2 relaunched this morning from the same stale lead notes and reached the same
  finding. Five independent liveness signals agree the sibling wave is dead: exactly one epic-cycle
  journal advanced today and it is this run's; zero transcripts outside this tree mention
  `wave-9-round-1`; all six `tgw9-s*` slices are `open` with `claim: null` frozen at 02:24–02:25Z;
  no `tgw9` branch exists local, remote or in any of the 1,455 worktrees; no open PR; and the epic
  root's own `wave_paper` already reads wave 10. *Also corrected: there is NO `tgw9-s2` — the filed
  round-1 set is SIX slices (S1, S3, S4, S5, S6, S7), not seven, and both the wave-9 record and the
  wave-10 direction said seven.* The fence therefore INVERTS: those six slices are unclaimed and on
  the table, and wave 10 re-scopes them against measurement instead of dispatching them as written.

- **D108 — D94(b) and D94(c) are MUTUALLY UNSATISFIABLE as written; the amendment is ROOT-EXCLUSION
  plus a new clause (b′), never "evaluate at the instant of close".** `truth-grip-epic` is ITSELF a
  row in the live ready pool (measured today: pool 859, namespace 80, root present, `open`, 0/4,
  child_count 119). Clause (b) demands zero claimable namespace rows; clause (c) holds the root open
  until last. There is no instant at which both hold — and "evaluate (b) when the close is issued"
  is not an escape, because at that instant the root is still in the pool, and `close.ex` has
  exactly one `def close/3` with no `before_publish`/pre-close hook to attach to. AMENDED: **(b)**
  the namespace MINUS the root has zero claimable rows in a live pool — today 79; **(b′)** the root
  itself IS still claimable at check time, which converts (c) from prose into a machine-checked
  clause (a root already closed makes the predicate RED, refusing to rubber-stamp an out-of-order
  seal). *Why (b′) is not decoration: silent root-exclusion without it deletes (c)'s only
  enforcement — that is amendment-into-vacuity, and it is exactly the softening this epic exists to
  refuse. Prior art supports exclusion but not the method: `seal-predicate.mjs` excludes its root by
  construction because it queries `fetchRoster(EPIC)` — a direct-`parent_id` census, the very shape
  D94 forbids by name.*

- **D109 — D94(a) is AMENDED to POLARITY-DECLARED adjudication; "accept FAILED" would be a
  softening, and it costs 131,489 bytes.** A zero-match grep returns `VERDICT.FAILED`
  (`rerun.mjs:590`) and `STANDING = {ADMITTED, DEMOTED}`, so `stands()` is false — and criterion 4
  is literally worded "verified by the ABSENCE of any new persisted corpus" while criterion 3's
  clause (b) is absence-shaped too. Put through grip, criterion 4's own D98-ratified evidence comes
  back FAILED, `stands() = false`: an unamended D94(a) reds two of four criteria even when they are
  honestly evidenced. But the naive fix admits a lie: four shapes through `screenedRerun` measured
  side by side — honest no-match → FAILED, `admits.absence = TRUE`; dead host → HOST-UNREACHABLE,
  false; **`diff` rc1 carrying 131,489 bytes → FAILED, `absenceEligible = false`, "a DIFFERENCE,
  never an absence"**; `grep` tool error → NULL-READ, false. A bare `verdict === FAILED` amendment
  would accept a 131KB diff as proof that something is absent. AMENDED: every criterion's evidence
  DECLARES its polarity; a pass-shaped fact is adjudicated by `admitsPassClaim`, an absence-shaped
  fact by grip's already-shipped, already-tested `admitsAbsenceClaim` (`rerun.mjs:843`), which is
  strictly STRICTER than accepting FAILED. **Evidence with no declared polarity fails CLOSED.**
  *Builder blocker nobody had recorded: `adjudicate.mjs`'s `ruling()` (:253) returns
  `{verdict,label,reasons,rejections,fact,level,rerun,note,conflict}` — no `admits`. The polarity IS
  computed (`decorate()` sets `r.admits`) and then DISCARDED at the adjudicate boundary, so a seal
  check built on `adjudicate()` alone structurally cannot adjudicate an absence. `ruling()` must
  carry `admits` through, additively.*

- **D110 — the namespace LENS is the transitive `parent_id` closure minus the root, intersected with
  an OFFSET-WALKED ready pool. Both single lenses leak, and each leaks a row the other catches.**
  Measured: the closure is 137 = 1 root + 119 depth-1 + 17 depth-2 (all 17 under
  `tgw1-workflow-gate-wiring`, itself `done`); the `tgw*`/`truth-grip*` id-prefix lens sees 135. The
  two prefix-invisible children are hash-ids `task-a965c4fbfe3710f5` (OPEN) and
  `task-ae5358384170ec8b` (done) — so a prefix query silently drops a live row, and a
  `filter[parent_id]` roster silently drops EIGHT live rows including `tgw2-acceptance-suite`, the
  P0 owner of criterion 2b. Conversely `task-a965c4fbfe3710f5` is open but NOT in the ready pool
  (assignee-routed, TTL-reaped claim epoch 2), so a ready-only lens drops it too. **Pagination is
  cleared as a false-zero risk** — `--all` = 859 = the offset walk (500 + 359, offset 900 → 0) — but
  the walk is proven only at this size and the server caps a single page at 1000 SILENTLY (rc 0,
  envelope keys `['docs','ok']`, no `total`, no `has_more`), so a seal check must PERFORM the walk
  and assert it, never trust `--all`. Also asserted per counted row: `status == "published"` (14
  drafts sit in the live ready pool today, one of them `lifecycle: blocked`), and dedupe on `doc_id`
  (`ls --all` carries a duplicate id under two UUIDs).

- **D111 — Movement 2 is a PORT PLUS A SURGERY of an existing, mutation-proven seal predicate — and
  it must NOT inherit that file's open priority-1 defect.** `cloud/priv/static/__preview__/seal-predicate.mjs`
  (237 lines, 149 executable) runs live today, exit 1 "NO SEAL", with working `--ledger` fixture
  injection proven in BOTH directions (clean pool + passing guard → SEAL exit 0; dirty pool +
  failing guard → NO SEAL exit 1 with all three clauses named separately) and an explicit
  NOT-asserted scope block. Honest reuse: **36 of 149 executable lines port verbatim (24%)**; 111
  are epic payload and ~60 more have no analogue (recursive/namespace lens, D94(c) root-closes-last,
  grip adjudication replacing the guard spawn, the L3 disclosure). Budget it as a fresh ~150–170
  executable-line module inheriting a proven blueprint, NOT a copy-and-sed. **The defect it must not
  carry:** `hg-overflow-guard-refusal-exits-1` (open, priority 1) — `seal-predicate.mjs:176` reads
  only `r.status !== 0` and prints "the defect is still measurable at origin/main", so a port squat
  on the guard's port produced three FALSE "still measurable" lines and a NO SEAL indistinguishable
  from a real one. That is NULL-READ laundered into FAILED, the precise distinction `rerun.mjs:590`
  exists to make. **The port reads the adjudicator's VERDICT, never its exit code.** *And the
  warning the prior art carries in its own body: the epic that shipped it is STILL OPEN with four
  open children. A passing predicate did not close a root — clause (c) as an EXECUTED ACT is the
  whole difference.*

- **D112 — D99's "all three failures share one root cause" is REFUTED; there are THREE independent
  problems and the NOT-A-RUN discriminator fixes exactly ONE.** The store has THREE shapes, not two:
  of 73 committed `grip-*.json`, **9** lack `recipes[]`, **26** carry `recipes[]` but no `run_id`
  (foreign `{claim, rerun}` verifier-note rows — a shape D99 never names), and 38 are grip-owned.
  Per file: `binding.test.mjs:444` (63/62/1) IS the nine files and a `?? []` guard drives its
  assertion violations to 0 — fixed. `mint.test.mjs:549` (38/37/1) is a **literal no-op** for D99's
  fix: line 556 already reads `run.recipes ?? []`; its 277-of-601 splits **202 rows with NO
  `subject` key at all + 75 that genuinely re-derive differently**, and the count of rows storing
  `subject: null` is **ZERO** — D99's wording is imprecise and a builder chasing stored nulls finds
  none. `ledger.test.mjs:1281` (77/76/1) folds 371 unreadable of which **160 sit in grip-OWNED
  `run_id` files** (LEVEL-SKIP 60, REFUSED-COMMAND 48, UNKNOWN-FIELD 45, VALUE-STORED 7) plus a
  SECOND, independent failing assertion the test never reaches: `level_restated` is 1, also
  grip-owned. A `run_id` discriminator cuts perfectly (202 no-key rows all lack `run_id`; all 75
  drifting rows carry it; no file is mixed) but still leaves ledger and mint red. **And the pin is a
  trap:** `binding.test.mjs`'s three pinned `CENSUS_RUN_FILES` are none of the 16 drifting files, so
  pinning mint's REGRESSION FLOOR to them makes it green and VACUOUS with respect to all 75 real
  drifting rows. *A builder can satisfy S1's criteria 2–5 in full, believe the diagnosis held, and
  hand back a suite with two of three tests still red.*

- **D113 — D100's gate SHAPE is defeated by the trap grip's own README documents; the gate grows a
  third clause: an EXPECTED-FILE FLOOR.** Proven by mutation, not by reading:
  `node --test tooling/grip/test/rerun.test.mjs tooling/grip/test/DOES-NOT-EXIST.test.mjs` exits
  **0** with `# fail 0` and `# skipped 1` — the full D100 predicate — on a run where 15 of 16 real
  test files never executed and the missing path is mentioned **zero** times anywhere in the output.
  A lone missing file DOES red (`Could not find …`, exit 1) and an empty glob is a silent
  zero-test green, so the trap fires exactly in the CI shape. Worse, `# skipped 1` asserts an
  ENVIRONMENT fact: the single skip is `rerun.test.mjs:789`, `{ skip: process.env.GRIP_LIVE !== "1" }`,
  so a job that sets `GRIP_LIVE=1` — i.e. runs MORE coverage — produces `# skipped 0` and reds the
  gate. The canary is inverted. **Gate = `# fail 0` AND `# skipped 1` AND the test glob expanded to
  the expected file count (16 today), the found list printed on mismatch.** File count is a
  legitimate invariant where test count is not: files are added deliberately, tests drift with every
  edit. *Also: the DIRECTORY form is a hard `MODULE_NOT_FOUND`, never a discovery walk — the quoted
  glob is the only correct invocation.*

- **D114 — grip CI is IN the seal fence, not an out-of-fence remainder: it is the ONLY path that
  lifts criterion 2 out of UNSTORABLE.** D96 understated the problem. Criterion 2's fact is local
  execution, and every storable head is refused: `node …` → "not allowlisted: node executes
  arbitrary JavaScript", `make grip-selftest` → "make executes recipes from a Makefile",
  `npm test --prefix tooling/grip` → "npm sub-verb \"test\" is not on the read-only allowlist". Only
  `gh run list …` and `gh api …/actions/runs` screen ADMITTED at **L2**. So criterion 2 has no
  adjudicable evidence at ANY level until a grip workflow exists — and it still does not
  (`git grep -l grip origin/main -- .github/workflows/` exits 1, no output; 39 workflows, zero grip,
  re-derived today). **Two premise corrections for the builder:** `fetch-depth: 0` is PRUDENT, not
  necessary — the dependency is REF RESOLUTION, not history depth (a `--depth 1 --single-branch`
  clone runs `rerun.test.mjs` 59/58/0/1, identical to a full checkout; a PR-shaped checkout without
  `refs/remotes/origin/main` reds test 38 with `+ 'UNAVAILABLE' - 'FAILED'`, and one
  `git fetch --depth=1 origin +refs/heads/main:refs/remotes/origin/main` restores it). And this
  checkout under-counted the workflow directory by two because it was 12 commits stale — derive CI
  facts from `origin/main`, never from a working tree. D104's ordering stands: round 2, behind a
  green suite.

- **D115 — the class-coverage tripwire must be DUAL-SPELLING over ALL SIXTEEN modules; the filed
  command CRIES WOLF on four genuinely-controlled classes and undercounts by at least five.** D95's
  verbatim 7-file hyphen-only rerun reproduces its three absences exactly (`NO-QUANTITY`
  mint.mjs:482, `NOT-A-REF` level.mjs:579/583, `WRITE-FAILED` ledger.mjs:652) — but the method is
  defective. `census.mjs` stores `TOOL_ERROR: "TOOL-ERROR"` while `census.test.mjs` asserts through
  the UPPER_SNAKE enum KEY, so adding census to the same hyphen-only scan flags EIGHT, of which four
  (`ANOMALOUS-SILENCE` :245, `AMBIGUOUS-SILENCE` :254, `UNCLASSIFIED-128` :310, `SKIPPED-TEST-RUNNER`
  :366) are asserted as fired outcomes. A dual-spelling scan over all 16 modules yields 82
  identifiers and **SEVEN** uncontrolled: the three D95 named plus `TOOL-ERROR` (census.mjs:281),
  `TEST-RUNNER` (backfill.mjs:68), `DEFAULT-CWD-BOUND` and `FORGE-API-READ` (binding.mjs). The
  regex's structural blind spot must be DECLARED in the tripwire's own output: it requires a hyphen,
  so six of the ten verdict names are invisible to it by construction. **And "mentioned" is not
  "controlled" — proven by mutation:** renaming `FORGE-API-READ` to a same-class rule left the suite
  at 63/62/1 unchanged, and renaming the ELSE branch collapsed `DEFAULT-CWD-BOUND` 29 → 2 while
  IMPROVING the epic's flagship else-share number 4.8% → 0.6% with nothing noticing —
  `binding.test.mjs:454` is `assert.ok(registered.has(verdict.rule))`, a subset check that cannot
  fail for an unexercised rule, and `defaultShare < 0.2` is one-sided and gameable by renaming the
  default. *`NO-QUANTITY` looks STRUCTURALLY UNREACHABLE — `mintRecipe` returns `NO-SUBJECT`
  whenever `head === ""`, which is the only way `quantityPhrase` returns `""`; five probe shapes
  reached it with none. Disposition is prove-reachable-or-document, never "write a control for a
  dead branch" — and "likely unreachable" must not be stamped as "unreachable".*

- **D116 — criterion 2b's C5 reword names `screenCommand`, NEVER bare `runRerun`; the one-word
  difference is a tripwire versus a production incident.** `runRerun` does NOT gate on
  `screenCommand` — its step 1 is `classifySafety` (`rerun.mjs:678`), which admits **6 of 6** frozen
  specimens including specimen 1's `ssh root@157.180.90.121` and specimen 6's arbitrary-JS `node`,
  while `screenCommand` refuses three (specimen 1 "host bound: names ssh", specimen 4 "host bound:
  names barkpark.cloud", specimen 6 "node executes arbitrary JavaScript"). The codebase says so in
  its own words at `adjudicate.mjs:90-96`: left to itself `runRerun` is "a default-on RCE". So the
  proposed reword wears the vocabulary of safety while removing the refusal. **The reword that is a
  genuine TIGHTENING:** every frozen specimen's `rerun` goes through `screenCommand` and its
  `{ok, reason}` is frozen as an expectation — the three refusals ARE the assertion, not an
  omission. It executes nothing (`screen.mjs` has zero imports; `acceptance.mjs:70` declines
  execution on purpose, "several of them ssh to production"), and it converts the fixture into a
  screen-DRIFT tripwire nothing in the repo currently asserts. Actual execution is separately
  impossible: specimen 3's rerun returns **269** against the local charter glob and **106** against
  the truth-grip charter on `origin/main` — there is no output to freeze. *Ownership settled:
  `tgw1-acceptance-suite` is CANCELLED as a superseded zombie; `tgw2-acceptance-suite` owns epic
  criterion 2b. Neither row carries a `title` field at all — do not route on remembered titles in
  this namespace. And the three quantifiers are DISJOINT: `tgw2` C1 quantifies over the TEN VERDICT
  classes, epic 2b over REJECTION classes, and `screen.mjs` over named SETS which are already
  mutation-injected (`screen.test.mjs:438-446`) and out of 2b's class quantifier by construction,
  not by exemption. Also: `tgw2`'s own gate runs `acceptance.mjs`, which has no exit-3 path — C2's
  evidence lives in `cli.mjs --selftest`, so the gate must grow it or C2 is evidenced by a command
  the gate never runs. And C6 is UNCLOSABLE as worded: `has_command_field` appears 1,902× inside the
  FROZEN fixture, which by definition cannot be edited — it needs a scope clause distinguishing
  ASSERTION from CITATION.*

- **D117 — D105's quotation is a PHANTOM and its two real precedents say the OPPOSITE; demoted
  children are ratified here on THIS wave's authority, and cloud-console is no longer cited for it.**
  The string *"Open residue lives as CHILDREN, not the epic"* appears NOWHERE in the repository
  (exact grep zero; loose forms zero), and `bp-cloud-console-charter.md` carries ZERO decision rows
  in any format across its 182 lines. The two texts that DO address residue both mandate what D105
  forbids: hardening-charter D72 clause (c), "a NAMED successor forwards genuine live residue", and
  GUI-Remake GR61, "the survivors go to ONE named successor epic, filed NOW so it is never silent".
  **The conclusion survives anyway, and the reason is measured, not borrowed:** D93 proved a closed
  parent does not drain the pool, so a named successor root inherits the identical defect while
  adding a second root to seal — it moves the problem and buys nothing. Residue therefore stays as
  DEMOTED CHILDREN of this root, on D93's measurement. *And note what D105 got right by accident:
  the epic's own prior re-home attempt (`tgw3-bl-rehome-research-coverage-bugs`) is still open
  precisely because no destination could be named — it is the live proof, and it is itself a
  disposition candidate rather than a third attempt. Meta-finding worth one line, because it IS this
  epic's thesis in the wild: `bp-cloud-console-charter.md:6` warns that its own D48/D49/D51
  citations are dangling "do not propagate them" — and its next paragraph propagates them as
  binding, three lines apart.*

- **D118 — the FENCE is restated: EXCLUSIVE over grip CODE, SHARED APPEND-ONLY over the ledger.**
  grip code is COLD — `git log --since=2026-07-25 origin/main -- 'tooling/grip/*.mjs' tooling/grip/test
  tooling/grip/fixtures` returns NOTHING. But `tooling/grip/ledger/` is a commons in which
  truth-grip is the MINORITY writer: since 2026-07-25, six commits wrote to it and only ONE is ours
  (3 rows) against 38 foreign rows from the mobile and search-template charters. A fence reading
  `tooling/grip/**` is breached by innocent siblings roughly daily and would have fired five times
  in three days on waves that did nothing wrong — the standing noise floor D104 warns about.
  EXCLUSIVE: `tooling/grip/*.mjs`, `tooling/grip/test/**`, `tooling/grip/fixtures/**`,
  `tooling/grip/README.md`, this charter, `wild-bulk-cycle.workflow.js`. SHARED, APPEND-ONLY: new
  files under `tooling/grip/ledger/**` only — never edit, move, rename, delete or gitignore an
  existing row, and assert NO exclusivity. DROPPED, per D103 and now doubly justified:
  `bp-epic-cycle.workflow.js` carries TWO open PRs (#6086 and #6332) plus an uncommitted edit in
  this shared checkout. *Only ONE open PR touches the fence at all — #5754, whose three ledger blobs
  are byte-identical to `origin/main`, so it is closable by content and cannot conflict. PR #6305 is
  MERGED and is not a collision in any sense.*

- **D119 — D84 is REFUTED and D106's urgency is FICTION; both close by content, and the REAL
  security item was hiding behind them.** (a) `tgw8-bl-stale-240-comment`: the "240" at
  `screen.mjs:43` is not a stale admitted-count, it is a LABELLED historical baseline inside a delta
  accounting whose next sentence names the current figure ("moved it to 254") — and 254 is LIVE, not
  prose: `screen.test.mjs:648` asserts `r.admitted === WAVE5_REACH` and the file runs 58/58 printing
  `254/651 admitted`. Closing a hygiene task against an accurate, test-pinned comment is the ledger
  substituting for verification. WONTFIX. (b) `tgw9-s6-recover-screen-writeflags` and
  `tgw9-bl-recover-rerun-quote-blindness` are CLOSE-BY-CONTENT under D40/D71: the probeHttp argv fix
  landed at **8e3c9fbb7 (#5350)** and the quote-blindness fix at **0f3a881b5 (#4983)**, both in
  strictly superior form (main also closes the interpreter trap — `sh -c "rm -rf /tmp/y"` still
  refused — which the stranded diff does not). Proven by RUNNING the injection: at base `81c3afa3b`
  the marker file IS created at exit 7 (curl failed AND the write landed — a control that behaved as
  a control); on `origin/main` it is not. **`tgw9-s6` is additionally UNBUILDABLE as written** — its
  criterion 1 demands reproducing the bypass against origin/main, which is fixed, so a builder must
  fail criterion 1 to satisfy criteria 2–4. (c) The direction's own "GIT_OUTPUT_RE=0" was a
  LEVEL-SKIP: the identifier is absent, the capability is live at `screen.mjs:402` carrying BOTH
  spellings, proven by a 14-shape matrix (10 refused, 4 admitted, zero errors). (d) `git worktree
  prune --dry-run -v` emits **ZERO** lines — prune reaps only worktrees whose directory has
  vanished, and none has, so "one prune from destruction" describes nothing. The ban stays because
  it costs nothing; the urgency does not. **(e) THE ITEM THAT IS REAL AND WAS MISPRIORITISED:**
  `origin/main`'s `deriveLevel` promotes a purely local grep of a documentation file to **L1** — `grep
  -rn "ssh root@host" doc.md` → L1, "a running system was touched", in the module whose entire job
  is preventing level-skips. `level.mjs:526` calls `segmentLevel(segment.raw)` and never passes the
  quote mask. It is filed as `tgw5-bl-level-mention-promotion` at priority 2, and its own title says
  **the suite ENFORCES the bug** — so the fix must invert a green test and a builder gating on
  "suite stays green" will bounce off it. Promoted to priority 0 and taken this wave.

- **D120 — the CENSUS reconciles exactly and D94's 64 was never stale; the honest blocking set is
  79.** 135 `tgw*`/`truth-grip*` rows exist (80 open, 48 done, 7 cancelled); the 80 claimable =
  **16 `tgw9-*` rows wave 9's own Decide filed + 64**. Nothing decayed. Minus the root, clause (b)'s
  blocking set is **79**, and it is a LIVE, VOLATILE figure — it read 859/860/861 across four
  minutes of sampling — so every count the seal quotes must name its sample instant and be
  re-derived at execution, never cited. Parking is confirmed sound and reversible by mutation on a
  real backlog row: `stage … considering` took the pool 860 → 859 with the row absent and the
  namespace 80 → 79, `stage … open` restored it exactly, `engagement` cleared on the way out, and
  the row stayed fully visible to `bp task ls --all` throughout — invisible to the queue, visible to
  a census, which is precisely what a disposition needs. The TTL sweeper's lapse rules only ever
  move DOWNWARD (`researching → considering`; `considering` stays), so a parked row never leaks
  back. *Sequencing rule for the sweep: a row carrying a live claim CANNOT be parked —
  `in_progress → considering` is refused `illegal_transition`, rc 2 — so release first (`bp task
  release <id> <worker> <epoch>`, both positionals required). And close-by-content is authorised for
  LEAVES only: D71's own final sentence REFUSES it for a parent with open children, so every
  candidate needs a parent/child read before any close.*

- **D121 — FIVE STANDING DECISIONS ARE CORRECTED BY MEASUREMENT (wave 11, at origin/main
  `a9638ecef`; `tooling/grip` bytes unchanged at `5ccd9ad0a`). The originals stay on the record; this
  is the dated correction.**
  **D95** — its "exactly three rejection classes have no control or test anywhere" (`NO-QUANTITY`
  mint.mjs:482, `NOT-A-REF` level.mjs:579/583, `WRITE-FAILED` ledger.mjs:652) is FALSE at main: #6359
  landed `class-coverage.test.mjs` with a fail-before plant AND a never-cry-wolf half for all three.
  D95's OTHER two clauses — "against a frozen adversarial fixture" and the undefined "class" — are
  UNTOUCHED (`grep -n 'fixtures\|evidence-corpus' class-coverage.test.mjs` returns nothing; every
  control there is an inline literal). So #6359 closes ONE of 2b's three failing words. Its "0/7" for
  `tgw2-acceptance-suite` is now 0/9. D95's closing warning — that keeping 2a and dropping 2b is the
  single most likely way this goes wrong — STANDS, unamended.
  **D109** — its builder-blocker paragraph is OVERSTATED. The FACT is true (`ruling()` at
  adjudicate.mjs:253 returns nine keys, no top-level `admits`). The INFERENCE, "a seal check built on
  `adjudicate()` alone structurally cannot adjudicate an absence", is REFUTED at runtime: `ruling()`
  passes `rerun: result` BY REFERENCE and `decorate()` (rerun.mjs:860) stamps `admits{pass,absence}`,
  so an executed ADMITTED ruling yields `{"pass":true,"absence":false}`. The real hole is narrower —
  `screenedRerun`'s refusal branch (adjudicate.mjs:122-134) hand-builds an undecorated 6-key literal,
  so `ruling.rerun.admits.absence` TypeErrors on every REFUSED command. Also: the "polarity is
  DISCARDED" text every wave attributed to D111 is D109's.
  **D111** — the `r.status !== 0` launder is at seal-predicate.mjs:**171 AND :176**, byte-identical.
  D111 names only :176, and :171 is the `--guard-cmd` override branch that every prior mutation proof
  of that file actually drove — so the credential was earned through the unfixed line. D111's
  "`--ledger` fixture injection proven in BOTH directions" is NOT RE-DERIVABLE FROM MAIN: `git grep
  -ln defectCommits` returns exactly one tracked file, the module itself, and no tracked JSON carries
  a `landed` key. The fixture was a throwaway.
  **D113** — the invariant stands; the digit moved. `tooling/grip/test/` holds **17** files, not
  "16 today". The trap still fires verbatim: `node --test rerun.test.mjs DOES-NOT-EXIST.test.mjs`
  exits 0 with `# fail 0`, `# skipped 1` and zero mention of the missing path.
  **D119(e)** — its FINDING is live (level.mjs:526 is still `segmentLevel(segment.raw)`), but its
  BUILDER GUIDANCE is REFUTED. "Its own title says the suite ENFORCES the bug — so the fix must
  invert a green test" is sourced to a TASK TITLE and adopted as instruction. Measured before and
  after across all 17 files: NO green test inverts. level.test.mjs goes 71/71/0 → 75/75/0 and every
  other file is byte-identical. *That is the hearsay class this epic exists to refuse, committed by
  the charter itself — which is why it is recorded here rather than quietly dropped.*

- **D122 — D94's PREDICATE HAS THREE CLAUSES, AND THE FOURTH IS D108's. The SEALED ban does NOT
  reach program stdout.** Read verbatim: (a), (b), (c). There is **no clause (d)**. The four clauses
  the seal command prints are **(a), (b), (b′), (c)** — (b′) is D108's amendment. Output labelling
  anything "(d)" invents a predicate clause on the instrument that certifies this epic's honesty.
  Separately: D94(c)'s ban enumerates four artifact classes — "no wave-log entry, Paper, memory note
  or commit message may use the word SEALED" — and a program's stdout is none of them. **The rule
  still binds** (the seal command must not print SEALED before the predicate holds) but it is a WAVE
  RULE EXTENDING D94(c), never a quotation of it. *Over-citing a real decision for authority it does
  not carry is the same defect as citing a phantom one; it just survives a grep.*

- **D123 — RECONCILIATION IS NOT SURVEY IN A SMALLER HAT: it changed the scope of three of the four
  refired briefs and refuted four charter decisions, for the cost of one bounded delta pass.** The
  attack on this wave's direction was that measurement keeps displacing construction. The answer is
  arithmetic: the expensive item (the full suite) cost 182s and is now stamped; the delta produced
  the #6359 overlap ruling, the phantom-fourth-failure refutation, the six-class mint split, the
  `admits` ruling and the D119(e) refutation — every one of which would have cost a builder real time
  or produced a false stamp. **A brief stale in its ground rules produces a builder that gates against
  the wrong baseline.** The briefs were NOT re-cut, NOT re-surveyed and NOT re-filed; each carries a
  dated amendment block that overrides where it conflicts.

- **D124 — THE THREE GRIP REDS ARE TWO NESTED AND ONE INDEPENDENT, and `run_id` scoping is NECESSARY
  BUT NOT SUFFICIENT.** `tgw9-s1`'s own title says "three independent problems, not one"; measured,
  binding.test.mjs:444 does not assert — it CRASHES (`TypeError: run.recipes is not iterable` at
  ledgerRows :57) — and ledger.test.mjs:1281's first unreadables are `MALFORMED-RUN` on the SAME ten
  recipes-less files. `run_id` scoping fixes shape 1 outright and removes 218 of shape 2's 421.
  mint.test.mjs:549 IS independent (`run.recipes ?? []` → those files contribute 0 rows). **And
  excluding every foreign file takes the D89 control 421 → 203, not → 0**, across 18 of grip's own 40
  runs: D99's "unowned commons" framing understates, and the argued ruling on grip's OWN rows is the
  majority of that slice. Three unit rulings the briefs inherited wrong: rejections ACCUMULATE per
  row (ledger.mjs:772-782), so 203 is **entries across 95 rows**, not rows; the 208/99 mint split is
  an OWNERSHIP split, not rejected/drifted (mint rejects **zero** of 631); and the 99 drifting rows
  are **six classes**, of which the 27 `path→path` rows are a LATENT ROOT-RELATIVITY BUG IN MINT, not
  an improvement — a blanket "mint improved" ruling would ship a regression under a checkbox. Filed
  as `tgw11-bl-mint-path-root-relativity`. *The 18 files carrying drifting mint rows are EXACTLY the
  18 owned files carrying unreadable rejections — set equality. Two mechanically independent tests,
  one population of pre-hardening runs.*

- **D125 — A FAILURE COUNT IS MEANINGLESS WITHOUT THE TREE AND HOW IT WAS BUILT, and there are THREE
  phantom generators, not one.** The suite is `644/640/3/1` in a clean git worktree at origin/main,
  reproduced digit-identically by four independent measurements at three commits — **the lead's
  "four failures" is refuted for the third time; there is no fourth to file.** The generators:
  (i) a bare-directory invocation, `node --test tooling/grip/test/`, reports "1 test, 1 fail" in
  ~40ms on node v22 **inside a clean git worktree** — small, plausible, and the dangerous one; any
  CI job or shell-out must use the glob or explicit files. (ii) a tooling-only non-git copy gives
  `604/586/17/1`, and its cause is a MISSING REPO-ROOT FILE (`.claude/workflows/bp-epic-cycle.workflow.js`
  at inloop-gate.test.mjs:29), **not** the missing `.git`. (iii) a FULL tree with `.git` deleted gives
  `644/628/15/1` — so "non-git" names at least two different shapes. **Every generator only ever ADDS
  failures; all three contain the same three reds as a subset.** Duration is a HOST property, not a
  code property: 145-174s idle across four runs, and a 4.4× load increase bought 4%. The "53 minutes"
  is neither reproduced nor refutable here and its mechanism is UNEXPLAINED — do not quote it as
  settled, and give grip CI a 10-minute timeout, not 5.

- **D126 — THE SEAL PORTS A BLUEPRINT AND REWRITES BOTH THINGS IT IS JUDGED ON: the LENS and the
  ADJUDICATION.** D94(b) forbids the prior art's census shape by name (D108 says so in its own
  words), so this is not a constant swap. Measured lenses: transitive closure **147**, id-prefix
  **145**, `filter[parent_id]` **131**, union **147** — union equals closure TODAY, a measurement and
  not an invariant, so **compute the union**. The direct lens drops 16 rows, all children of
  `tgw1-workflow-gate-wiring`, one of them (`tgw2-verify-writes-back`) OPEN and in the live pool: 32
  claimable where the truth is 33. An unfenced prefix lens sweeps 4 PAPERS. `--limit` is **silently
  clamped at 1000** with no truncation flag and `count` is the page size, so a single-call lens sees
  98 of 146 rows **while reporting the correct claimable count** — green for the wrong reason, and
  the reason a builder must check the ROW count, not the claimable count. `/v1/tasks` **silently
  ignores `parent_id`** (a real, an absent and a nonexistent parent all return the identical 1000-row
  set); pin `GET /v1/data/query/production/task` by name. **(b′) MUST BE WRITTEN, NOT INHERITED**: the
  prior art excludes its root purely because a `parent_id` census structurally cannot return the
  parent — there is no check and nothing to fail — so a closure lens without an explicit
  `pool.has(ROOT)` assertion silently deletes clause (c)'s only enforcement, which is D108's named
  amendment-into-vacuity. Key (b′) on POOL MEMBERSHIP, never `claim == null`: the root carries an
  EXPIRED claim and is pooled anyway. **The launder is four shapes**: :171, :176, `status === null`
  (timeout/signal/ENOENT — D111 names none of it), and a non-JSON HTTP response throwing at :116 so
  exit 1 means both NO SEAL and infra failure. The fix is a four-way classifier used by both call
  sites, not a sed. **The fixture must be AUTHORED AND COMMITTED** or the credential evaporates on
  merge exactly as D111's did. And **the seal reads `admitsAbsenceClaim(ruling.rerun)`** — total
  functions, correct on all four undefined-admits paths, zero production change: promoting `admits`
  onto `ruling()` would silently satisfy 2 of open task `tgw4-absence-veto-stops-at-the-rerun-seam`'s
  3 criteria, so adjudicate.mjs is OUT of the seal's fence.

- **D127 — #6359 SUBTRACTS ONE WORD FROM 2b AND ZERO CRITERIA FROM `tgw2`, and the residual is
  smaller in one direction and larger in the other than anyone wrote down.** It meets 0 of tgw2's 9
  stored criteria. Two corrections in opposite directions. **Over-building**: SIX of the seven
  "missing never-cry-wolf halves over the ten verdict classes" ALREADY EXIST on main with both halves
  (DEMOTED adjudicate.test.mjs:128/:136 + :144; FAILED, HOST-UNREACHABLE, UNAVAILABLE, NULL-READ,
  ASYNC-DEFERRED all in rerun.test.mjs) — building seven is D95's softening arriving by OVER-build.
  The honest residual is a SELFTEST PROJECTION gap plus ONE real build: `REACHABLE-WRONG-ROUTE` has
  no executed plant, and the hermetic replacement is proven to work (a 404 variant of
  `withLocalServer`, rerun.test.mjs:737, returns `{"verdict":"REACHABLE-WRONG-ROUTE","code":404,
  "reachable":true,"absence":true}`). **Do NOT unskip rerun.test.mjs:788** — it curls prod, and
  flipping `# skipped 1` to 0 reds D113's own gate. **Under-gating**: the three D95 classes are named
  in EXACTLY ONE test file, `class-coverage.test.mjs`, which tgw2's stored gate did not run — a PR
  citing #6359 while its own gate never executes that file is a citation with no gate behind it. The
  gate now runs it. *And a new vacuous-green generator sits on the exact command D116 mandates that
  gate grow: `cli.mjs --selftest` writes 23 lines to a FILE and 7 through a PIPE, verdict line gone,
  exit 0. Capture to a file and assert the tail line. Filed as
  `tgw11-bl-cli-selftest-pipe-truncation`.*

- **D128 — `tgw6-bl-grip-suite-has-no-ci` IS DEFERRED ON D104/D114 ORDERING, NOT ON A WORKFLOWS
  COLLISION.** The wave's stated ground — that a concurrent branch-protection run owns
  `.github/workflows/**` — is a CONCURRENCY argument, and `.github/workflows/**` appears in NEITHER
  half of D118's fence, so it is not a fence argument at all. The charter's own ground is stronger and
  correctly sourced: D114 states grip CI is the ONLY path lifting epic criterion 2 out of UNSTORABLE,
  and "D104's ordering stands: round 2, behind a green suite." *This wave hands the next one that
  green suite, a re-derived cost, and a criterion with a route — which is the whole reason `tgw9-s1`
  is in it.*

- **D129 — A DROPPED SLICE MUST BE IMPOSSIBLE TO DISCOVER AT REVIEW; the wave asserts its own
  dispatch.** Wave 10 lost four of eight slices because the builder fan-out is the ONE fan-out not
  wrapped in `neverLose` — deliberately, since a retry could re-dispatch against a live claim — and
  `.filter(Boolean)` deletes a null dispatch before anything counts it: no LOST log, no deficit
  block, no result key, and `Build: 3/3 slices green` printed post-filter over post-filter. Per slice,
  assert a BRANCH exists (`loop-epic/<slug>-*` created after wave start). Three rulings that make the
  receipt work rather than misfire: (i) the branch slug comes from **Decide's slice title**, not the
  bp task title — on wave 10's own data a task-title glob would have reported branch-absent for 2 of
  the 3 slices that DID build, a 67% false re-dispatch rate; match by slug PREFIX or by set
  difference over the window, never by exact index (the index is `buildNow`-relative). (ii) **NEVER
  re-dispatch on claim-present**: the worker id is deterministic from the slice title, so a
  re-dispatch hits `renewal?` and BUMPS THE EPOCH, fencing off the live builder's stamps and close
  (`:fenced_off` at stamp.ex:217, close.ex:380) — that converts a lost slice into a stuck one,
  silently. (iii) `claim == null` does NOT prove no builder is running: the lease TTL is 2700s
  (ttl_sweeper.ex:143) and wave 10 recorded two leases lapsing back into the pool. Re-dispatch only
  on branch-absent AND claim-absent AND not-in-`not_green`. **Assert BRANCH at Build, PR at Review** —
  `gh pr list --head` returns `[]` for every builder branch, because the PR is opened on the
  reviewer's `-r` branch.

- **D130 — WAVE 12 IS RECONCILE-AND-VERIFY WITH EARNED BUILDS; the wish's stale-open premise is
  REFUTED against live L1.** The wish predicted the 136 children were dominated by DONE-pending-merge
  stale-open rows closeable by evidence. Measured against the live server (single 500-row page,
  `count == docs == unique == 136`): **53 done / 40 considering (parked) / 34 open / 9 cancelled** —
  NOT a stale-open batch. Exactly ONE row sits at N-1 (`tgw9-s3` at 11/12), and its residual is a
  lead close-window stamp (owned by `tgw11-bl-root-criteria-stamp-needs-close-window`), NOT shippable
  code: its lone unmet criterion (index 10) is a ledger-stamp act and is NOT merge-gated, so it FAILS
  the batch-close hard filter and must NOT be batch-closed. Movement 1's product is therefore an
  ACCURATE PARTITION plus a corrected premise, not a mass close-by-evidence. Two rows are genuinely
  evidence-closeable by the lead (state proves it, not merged content): `tgw9-bl-close-superseded-pr-5754`
  (PR #5754 is CLOSED, `mergedAt` null) and `tgw6-bl-primary-checkout-staged-grip-fork`
  (`git diff --cached` = 0 staged grip files). Neither is a build.

- **D131 — THE GRIP HOLDS; no recent merge silently defeated it, and every guard can still FAIL.**
  Since wave 11 (2026-07-28) only ONE grip production module changed on `origin/main`: `provenance.mjs`
  via foreign #11535 (dr-w34), which *tightens* the quotable-ancestry law (replaced a boolean
  `differs_from_origin` with a five-rung ancestry grade; `ahead_of_main`/`diverged` are now refused)
  and is mutation-fail-able (32/32, reds when the law is widened). `seal.mjs`, `screen.mjs`,
  `level.mjs`, `record.mjs` carry NO post-07-28 commit. All six named guards RED under a reverting
  mutation on current `origin/main` (level checkCeiling reds 3; screen screenSegment reds 24; record
  admitFact reds 5 via level.test; seal classifyRun reds +2; adjudicate.stands and provenance.isQuotable
  are THIN at 1 each). The seal is a runnable command that ships saying NO — but on live data it exits
  **2 INFRA-FAULT**, not 1, because a stale ready-pool GHOST row (`akbr-feedback-2026-08-epic` listed
  twice; the document store holds exactly ONE row) trips the global pool-integrity gate. That is a
  server-side ready-pool dedup bug OUTSIDE this epic's fence; deduped, the predicate reads
  `a=FAIL b=FAIL(blocking=35) b'=PASS c=PASS HOLDS=FALSE` — an honest NOT-YET, backlog remains.

- **D132 — CROWN BUILD: the screen value-taking-global collision is a LIVE census-gate write-bypass,
  and git is NOT the only vulnerable head.** `screenCommand` — the SOLE, non-injectable gate the live
  census executes through (`census.mjs:22` "the safety bound is screenCommand and NOTHING ELSE") —
  ADMITS a write whenever a value-consuming global's ARGUMENT is itself a read-verb name. Proven on
  `origin/main`, executed into the census EXECUTED list: `git -C log push origin main`,
  `go -C env run main.go` (arbitrary CODE EXECUTION), `npm --prefix ls install` (postinstall CODE
  EXECUTION). Root cause: `firstNonFlag` (screen.mjs:345) skips flag TOKENS but not the VALUES that
  value-consuming globals eat, so the value is misread as the sub-verb; `gitRule`/`goRule`/`npmRule`
  all inherit it (`gh` survives incidentally via its two-level noun+verb scan). Fix target =
  `screenCommand` (a per-head value-taking-globals normaliser feeding `firstNonFlag`) and it MUST
  close git AND go AND npm — a git-only fix is incomplete. This is a danger-axis level-skip on the
  grip's OWN executor: a command classified less dangerous than it is, and the executor acts on it.
  HIGH-FLIP-RISK (security/correctness on the guard itself): independent mutation-proven review owed,
  prove the guard can still FAIL, fail-closed. The gap is ORIGINAL to wave 3 (screen.mjs unchanged
  since #5349), not a regression. `classifySafety`'s separate space-separated-long-global leak is
  LATENT (census never calls it) and is NOT the target.

- **D133 — ON-THESIS BUILD: `tgw3` bp-local subcommand overpromotion is a live provenance-axis
  level-skip.** `deriveLevel` (level.mjs:506) routes every `bp` head to L2 unless `hasOnlyLoopbackTargets`,
  so the four PURE-LOCAL `bp scaffy` verbs (validate, fmt, run, discover) — documented in
  `scaffy_cmd.go` as "no network, no auth, no manifest — this file never touches the server", true
  authority L3 — grade L2, and `checkCeiling("L2", derived)` returns `{ok:true}`. A non-admin author
  citing `bp scaffy validate x.scaffy` as an L2 rerun stores a fact one authority level above its
  ground, reachable through the ordinary rerun field. #6506 added mention-immunity for ssh/gh-api/git-show
  only — NO scaffy carve-out. Fix = demote URL-free local `bp scaffy` local verbs to L3; remote verbs
  (`pull`, `ls --remote`, defined in a SEPARATE file) stay L2 — do NOT blanket-demote the `bp` head or
  you wrongly downgrade legitimate remote reads. HIGH-FLIP-RISK (reachability/correctness): the scope
  boundary (local-only, not remote) is the whole judgment.

- **D134 — READ-PATH BUILD: D66 is largely CLOSED, one injection-wiring gap survives.** `foldLedger`
  composes `admitRecipe` on the read path (ledger.mjs:879-902 "the read path re-admits what the write
  path admitted") — refuting a from-scratch D66 rebuild. Four of six forged-row defect classes reject
  with zero injection; all six reject when `{now, screen}` are injected as the CLI write path does.
  The residual: the actual read callers `census.mjs:990` (`loadLedgerRecipes`) and `backfill.mjs:247`
  call `foldLedger(dir)` with NO bounds, so a future-dated (FUTURE-OBSERVED-AT) or outage-capable
  (REFUSED-COMMAND) row still folds through the product read paths while the write path refuses both.
  Fix = inject `now` (from `date -u`) + `screenCommand` into those two fold callers; mutation-provable
  by reverting the injection and watching a future/outage row fold clean. Bounded, in-fence, on-thesis
  (the read path admitting what the write path refuses).

- **D135 — CONVERGENCE HARDENING: the grip suite's own two reds and the one untested rejection class.**
  (a) `inloop-gate.test.mjs` tests 255/256 are RED on `origin/main` — stale prose-anchors from #6688
  (NOT #11604): the heading reworded to "THE SAME PR CARRIES THIS RUN'S LEDGER ROWS" and the ban
  backticked, so the literal greps return -1/0 while the guarded discipline is fully intact at
  workflow line 757. The grip suite is NOT CI-gated, so this blocks no merge, but every builder
  running the full suite sees 2 reds on a clean tree. A re-pin (tolerate the current wording by
  pattern) is slice 0 so each builder's gate proof is unambiguous — test-file only, no guard
  semantics. (b) `BAD-DEPS` is the single `admitFact` rejection class with NO fail-before-plant test
  (proven by mutation: neutering the guard reds ZERO tests); a small direct `record.test.mjs` closes
  it. Neither is a level-skip; both are honest hardening of an already-working guard. DEFERRED to
  backlog, NOT built this wave: `tgw4-absence-veto-stops-at-the-rerun-seam` (a fail-CLOSED
  consistency gap on the refused-command read contract — real and in-fence, but not the on-thesis
  fail-open level-skip the wave prioritizes).

## Roadmap

Ordered. Round = dispatch round; a slice never dispatches beside an unmerged dependency.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw1-level-grammar` — the fact record + pure level-derivation over the `rerun` command | 1 | medium | tooling/grip |
| 2 | `tgw1-fixture-quarry` — harvest + freeze the evidence corpus and the six ratified specimens | 1 | medium | tooling/grip |
| 3 | `tgw1-rerun-executor` — re-execution, (code,exit) reachability, UNAVAILABLE, NULL-READ, scope/warmth classifier | 1 | medium | tooling/grip |
| 4 | `tgw1-workflow-provenance-seam` — `rerun` on both schemas, the `bp search query` fix, the fan-out floor | 1 | small | .claude/workflows |
| 5 | `tgw1-adjudicator` — the verdict engine composing grammar + executor, conflict keyed on (subject, quantity) | 2 | large | tooling/grip |
| 6 | `tgw1-acceptance-suite` — fail-before / pass-after / never-cry-wolf / catches-a-plant, every rejection class firing | 3 | large | tooling/grip |
| 7 | `tgw1-workflow-gate-wiring` — probe the import seam, run the gate over every returned fact | 3 | medium | .claude/workflows |

Wave 1 landed rows 1-4. Rows 5-7 are superseded by the wave-2 plan below: `tgw1-adjudicator` is
rebuilt as `tgw2-adjudicator` under D24 (compose, don't re-derive), `tgw1-acceptance-suite` becomes
`tgw2-acceptance-suite`, and `tgw1-workflow-gate-wiring` is promoted to the wave-2 PARENT with its
build work split into `tgw2-inloop-gate` (round 1) and `tgw2-verify-writes-back` (round 2).

### Wave 2 — verify-writes-back. Parent task `tgw1-workflow-gate-wiring`.

**The wave-2 blocker is LIFTED by D26, not ignored.** D10's research-coverage clause stands
untouched; the recipe ledger simply never joins that store.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw2-grip-quote-safety` — quote-aware `classifySafety` + CWD-hardened, tightened `rerun.test.mjs` | 1 | medium | tooling/grip |
| 2 | `tgw2-adjudicator` — the verdict engine COMPOSING `admitFact` (D24), ten verdicts, CONFLICT unit-only (D25) | 1 | large | tooling/grip |
| 3 | `tgw2-recipe-ledger` — one immutable file per run, no value field, folded at read time (D26) | 1 | medium | tooling/grip |
| 4 | `tgw2-inloop-gate` — the grammar-free in-workflow demotion+annotation at the one interception seam (D19/D20) | 1 | medium | .claude/workflows |
| 5 | `tgw2-l4-artifact-census` — `GENERATED_ARTIFACT_PATTERNS` derived by running the emitters, not guessed | 1 | medium | tooling/grip |
| 6 | `tgw2-wild-bulk-fanout-floor` — port the D15 throws to `wild-bulk-cycle`, and settle `minItems` empirically (D28) | 1 | small | .claude/workflows |
| 7 | `tgw2-acceptance-suite` — fail-before / pass-after / never-cry-wolf, every verdict class proven able to fail | 2 | large | tooling/grip |
| 8 | `tgw2-verify-writes-back` — the narrow verify-writes / Decide-commits carve-out (D27) | 2 | medium | .claude/workflows |

### Wave 3 — the CLI is the seam. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-3-2026-07-21`.

**The realisation that reframes the epic.** D19 permanently forbids the workflow JS from reading a
file, importing a module, running a command or reading a clock. Wave 2 correctly wired the only
thing the orchestrator CAN do — a grammar-free demote. But the orchestrator was never the right
consumer. Every phase of this loop dispatches an AGENT WITH A SHELL, and that premise was re-run at
Digest rather than assumed: D19's vm-sandbox scopes to the `.workflow.js` file, not to dispatched
agents; Verify's default dispatch carries no isolation key and runs in the shared checkout exactly
as Decide does; a probe write under `tooling/grip/ledger/` succeeded. Wave 1 shipped a substrate
nothing called; wave 2 made the one caller D19 permanently cripples call it; wave 3 hands it to the
caller that can actually do the work.

**Conceded openly:** everything the builders produce goes live NEXT wave, not this one. The
phase-agent choreography rehearsed inside this wave is a REHEARSAL and the debrief must label it as
one.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw3-census-screen` — the fail-closed allowlist screen, its own module, three layers (D29) | 1 | large | tooling/grip |
| 2 | `tgw3-level-compound-fix` — un-gate the remote checks, strip wrappers, bp/gh → L2, parseability floor (D30) | 1 | large | tooling/grip |
| 3 | `tgw3-ledger-honesty` — the injected `now` bound, Z-only, injected safety screen, `RIVAL-METHOD` (D31/D33/D39) | 1 | medium | tooling/grip |
| 4 | `tgw3-prompt-seam` — the Verify carve-out + Decide's ledger commit + the stranded-file ruling (D35) | 1 | medium | .claude/workflows |
| 5 | `tgw3-write-verb` — the WRITE CLI + the subject/quantity minting transformer (D32) | 2 | large | tooling/grip |
| 6 | `tgw3-census-verb` — the decay census, silence-as-answer, its honest 29.8% reach (D38) | 2 | large | tooling/grip |
| 7 | `tgw3-leads-verb` — the read path, one command, one screen, staleness called out, no answer ever shown | 3 | medium | tooling/grip |

Rounds 2 and 3 do NOT dispatch this run. `tgw3-write-verb` waits on 1 and 3 (it wires the screen
into the write seam and routes the renamed fold); `tgw3-census-verb` waits on 1; `tgw3-leads-verb`
waits on 5, because both edit `ledger.mjs`'s CLI routing.

Later waves, in the ratified order: **wave 4+** the server-side
`type:fact` backend, whose grammar must live in an Elixir `before_publish` hook because schema-v2's
cross-field `validations:` slot is parsed but inert.

### Wave 4 — the ledger stops being empty. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-4-2026-07-21`.

Round 0 landed before any builder flew: the four wave-3 branches plus the D29–D40 charter commit,
one PR, merged by CONTENT (D40/D41/D42).

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw3-write-verb` — the WRITE CLI + the minting transformer + the first real rows (D32/D53/D54) | 1 | large | tooling/grip |
| 2 | `tgw3-census-verb` — the decay census, family-dispatch silence, census owns the screen (D47/D50) | 1 | large | tooling/grip |
| 3 | `tgw4-screen-overwrite-guard` — close `sort -o`/`uniq`/`tree -o`, retire the 26-of-31 prose (D48/D52) | 1 | medium | tooling/grip |
| 4 | `tgw4-wiring-and-acceptance` — the containment wiring test + the acceptance suite (D49) | 1 | large | tooling/grip |
| 5 | `tgw4-rerun-silence-fixes` — the `diff` rc2 false-admission + the merge-base false-unsafe (D51) | 1 | medium | tooling/grip |
| 6 | `tgw3-leads-verb` — the REDUCED read path: substring filter, no band, no rank, no flag (D43–D46) | 2 | medium | tooling/grip |

The three verb slices keep their wave-3 task ids rather than being re-filed under `tgw4-*`: they
were correctly filed and correctly dependency-blocked on branches that were not on main, and round
0 is exactly what lifts that block. Minting duplicate ids for work that already has a good task is
the zombie-task disease this wave is treating.

Round 2 does NOT dispatch this run. `tgw3-leads-verb` waits on 1 (it needs rows to read) and on 2
(its staleness column renders the census's verdict, and both edit `ledger.mjs`'s CLI routing).

### Wave 5 — the ledger becomes readable. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-5-2026-07-21`.

The direction that opened this wave was "the fleet is the factory, aimed outward". Verification
refuted its mechanism (D57) and its seam (D56), and replaced both. The store still leaves home —
53 of the 62 committed rows are foreign — but it leaves home in a Decide commit of rows a verifier
minted by hand, and the volume that makes `leads` worth typing comes from RE-EXECUTION BACKFILL
(D58), not from dispatched verifiers.

**Committed with this charter:** the two carve-out run files a wave-5 verifier wrote through the
real CLI under D35, staged by explicit path. The store goes 9 rows → 62, 7 subjects → 48, 100%
self-portrait → 85% foreign, with zero `value` fields, zero L1 rows and zero unreadable rows.
That is D35's Decide step executed for the first time, one wave after it shipped.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw5-screen-hardening` — two upstream RCE primitives, four write-flag holes, two false refusals | 1 | large | tooling/grip |
| 2 | `tgw5-leads-verb` — `grip leads` + `grip prescreen`, reduced per D43–D46 | 1 | medium | tooling/grip |
| 3 | `tgw5-mint-fixes` — the go-glob, the single-segment hole, and the quantity that fabricates rivals | 1 | medium | tooling/grip |
| 4 | `tgw5-census-ledger` — `census --ledger`, the NUL byte, the hermeticity caveat | 1 | medium | tooling/grip |
| 5 | `tgw5-probehttp-argv` — close the fact-derived-URL injection with argv, not a better gate | 1 | small | tooling/grip |
| 6 | `tgw5-write-path-docs` — the nine discovery steps, answered where a writer looks | 1 | small | tooling/grip |
| 7 | `tgw5-corpus-backfill` — the census mints; only commands that answer TODAY become rows | 2 | medium | tooling/grip |
| 8 | `tgw5-fold-hardening` — the read path stops admitting what the write path refuses | 2 | medium | tooling/grip |

Round 2 does NOT dispatch this run. `tgw5-corpus-backfill` waits on 1, 3 and 4: it re-executes
historical commands, so it must not dispatch beside an unhardened screen (D61); it writes rows, so
minting them with the colliding quantity would bake fabricated rivals into the store permanently
(D60); and it mints THROUGH the census classifier (D58). `tgw5-fold-hardening` waits on 2 — both
edit `ledger.mjs`, and leads owns the CLI dispatch chain this wave.

**The one thing this wave is for.** After round 1, an agent types
`node tooling/grip/ledger.mjs leads <substring>` and gets back RECIPES — command, derived level,
dependency paths — for questions somebody already answered cheaply. Never a value, and not by
promise: `RECIPE_FIELDS` has no `value` field, and `foldLedger`'s projection drops unknown keys
before they reach `entries[]` (D66), so the verb CANNOT hand back a stale truth even from a forged
file. After round 2 it reads a store roughly four times larger, every row of which re-derived an
answer on the day it was written.

**What this wave will NOT have proven, stated in advance.** The dispatched-verifier write path
remains unexercised end to end (D56) — the prompt and harness edits that would close it are outside
this epic's surface fence and are filed as `tgw5-bl-join-prompt-closure` for the lead. The level
mention-promotion still derives a false L1 from a grep of an ops doc (D65). And P5's SHIP verdict
rests on a 5-point margin at 62 rows, with 5 of 7 non-empty queries returning a SINGLE row — a
one-row lead is not measurably better than a grep, so P5 is re-measured after round 2 at the larger
row count before it is called settled.

### Wave 6 — bind the answer to the tree. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-6-2026-07-21`.

The direction that opened this wave was "bind the answer to the tree — close the defect CLASS, not
the instance". Verification kept the direction and re-grounded three of its four premises. The
count in the p1 task reproduces exactly and its mechanism does not (D73); the fix cannot be a
migration or a write-seam screen because the store is structurally immutable and the write is
all-or-nothing (D74); the failure the task called loud is silent, because 79% of the rows pipe
(D76); and the mint-era ruling the lead escalated is settled by re-deriving the key rather than by
touching a byte (D77).

**One shape, four instances, one seam.** Nothing in grip binds an artifact to the tree or era it
was produced against, so a consumer cannot tell whether it is looking at the right one. Rows do not
record their binding; the CLI does not record which tree it is; the fold does not record which era
keyed it; and the rot detector scores a tree-sensitive row HEALTHY while it answers differently in
two trees — demonstrated, at last, rather than argued: `censusOne("git ls-tree HEAD --name-only
tooling/grip/ledger/")` returns `ANSWERED · answering=true · decayed=false` from BOTH the primary
checkout and a fresh worktree, with 1 line in one and 4 in the other. The census's only
tree-awareness classifier, `WRONG_CWD`, keys on stderr `/not a git repository/i` and therefore
CANNOT fire inside any worktree of any clone — it is a null guard against exactly this class.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw6-binding-classifier` — the five binding classes, keyed on ref identity, with `exit_masked` | 1 | large | tooling/grip |
| 2 | `tgw6-self-provenance` — every grip verb declares its own tree, on stderr; `cli.mjs` gets its entry guard | 1 | medium | tooling/grip |
| 3 | `tgw6-fold-rederives-key` — the fold keys on `quantityPhrase(rerun)`; stored quantity and level become drift signals | 1 | medium | tooling/grip |
| 4 | `tgw6-leads-subject-first` — `leads` matches the SUBJECT by default; the command text is opt-in and counted | 1 | medium | tooling/grip |
| 5 | `tgw6-leads-declares-binding` — every returned recipe states its binding class; `--json` carries provenance | 2 | medium | tooling/grip |
| 6 | `tgw6-mint-binds-to-caller` — mint strips a `cd <root> &&` prefix ONLY where the classifier proves the answer invariant | 2 | medium | tooling/grip |
| 7 | `tgw6-census-binding-report` — `census --ledger` reports the binding-class distribution and stops scoring tree-sensitive rows as healthy | 2 | medium | tooling/grip |

Round 2 does NOT dispatch this run. Slices 5, 6 and 7 all import `binding.mjs`, which slice 1
creates; 5 additionally edits `leads.mjs` (slice 4) and `ledger.mjs` (slice 3); 7 additionally
edits `census.mjs` (slice 2). Every round-2 brief opens with its `AFTER <task_id> merges` line, per
the sequenced-rounds law that has now gone 7-for-7 across two epics.

**The one thing this wave is for.** After round 1, an agent in any worktree types `node
tooling/grip/ledger.mjs leads internal/cli` and the first thing it learns is WHICH TREE the answer
is about and whether that tree differs from `origin/main` — so the lead's false negative becomes
structurally impossible rather than merely unlikely — and the store it reads stops printing a line
count beside a match count as rival methods of one property. After round 2, every returned recipe
declares whether it re-runs in any clone, in any worktree of this clone, only in YOUR tree, only in
YOUR cwd, or only against one named checkout with a recorded reason.

**What this wave will NOT have proven, stated in advance.** The classifier is gated on the 62-row
store, where it cannot fail (D81) — five of the seven resisting forms have zero instances there, so
its acceptance test is the 652-proof corpus, and its grammar is un-stress-tested until
`tgw5-corpus-backfill` runs. The suite has no CI (D82), so every green here is a local green that
nothing on the merge path re-derives. `census --ledger` still measures STILL-ANSWERING, never
STILL-CORRECT; slice 7 narrows that to "still answering, and here is which tree it answered about",
which is strictly less than correctness. And `git blame` appears zero times in either corpus, so
its per-worktree classification is reasoned from git semantics rather than measured — the one row
in D73's table without corpus evidence.

### Wave 9 — the instrument adjudicates its own close. Parent task `truth-grip-epic`. Paper `truth-grip-seal-wave-9-2026-07-27`.

The thin wave the wave-8 debrief named — with two of its four premises REFUTED before a builder
flew. The four wave-6 "zombies" are all `done` with stamped merge evidence, and
`tgw8-bl-stale-240-comment` closes BY CONTENT (screen.mjs:38 already prints "254 (39.0%) here as of
wave 5" four lines above the 240 at :43, inside a paragraph titled "THE SCREEN'S REACH MOVES, AND
THAT IS NOT A REGRESSION"). Most of the wish's checklist was already true, which is exactly why this
wave has room for the three things that were not.

**The wave does NOT seal (D93).** It makes the seal REACHABLE and settles, permanently, the two
questions a future seal would otherwise have to re-litigate: what each criterion honestly says
(D95–D98), and what the predicate for closing the root is (D94).

| Slice | Task | Round | What |
|---|---|---|---|
| S1 | `tgw9-s1-ledger-commons-honest` | 1 | the store's read path recognises a run by SHAPE; the three globbing tests stop asserting over a directory nobody owns; suite goes green (D99) |
| S2 | `tgw6-bl-grip-suite-has-no-ci` | **2, after S1** | the advisory, path-filtered, hermetic rot detector + its own honesty block (D104) |
| S3 | `tgw9-s3-criteria-adjudicated` | 1 | criteria 0/1/3 amended to the D95–D98 wording and stamped on adjudicated evidence; criterion 2 is S7's merge-gated criterion |
| S4 | `tgw9-s4-tail-disposition` | 1 | the 64-row namespace disposed row by row against D94(b) — close-by-content, park-with-a-ruling, or leave open |
| S5 | `tgw9-s5-prune-stale-branches` | 1 | the six superseded remotes pruned behind a guard that re-derives safety AT PRUNE TIME |
| S6 | `tgw9-s6-recover-screen-writeflags` | 1 | the two stranded, live-proven write-bypass fixes recovered through the gate (D106) |
| S7 | `tgw9-s7-wildbulk-provenance-gate` | 1 | `wild-bulk-cycle` gets the provenance gate it never had — criterion 3's real hole (D97) |

What wave 10 inherits, stated in advance: the root still open, `tgw2-acceptance-suite` (P0, 0/7)
still owning criterion 2b, and the seal reduced to one mechanical check — D94(b)'s ready-pool
intersection returning empty.

## Wave log

<!-- one entry per wave: date, slices shipped, grade, what the next wave inherits -->

### Wave 2026-07-20 — round 1, the substrate. Grade A−.

Paper: `source-of-truth-grip-wave-2026-07-20`. Four round-1 slices built and
reviewed; rounds 2-3 deferred by design (sequenced-rounds law), not stalled.

**Landed** (final branches carry a reviewer `-r` commit):

| Slice | Branch | What |
|---|---|---|
| `tgw1-level-grammar` | `…derive-the-authority-level-from-the-reru-0-r` | `level.mjs` + `record.mjs`: level derived from the `rerun` command alone, claim as ceiling, LEVEL-SKIP / PATHLESS-REF / INADMISSIBLE-CONTINUOUS. 34 tests. |
| `tgw1-fixture-quarry` | `…freeze-the-evidence-corpus-and-the-six-r-1-r` | Frozen evidence corpus (1,902 evidence / 652 proofs, deterministic sample) + the six ratified specimens and two labelled negative controls. 19 checks, 19 controls proven able to fail. |
| `tgw1-rerun-executor` | `…re-execute-a-rerun-command-and-report-a--2-r` | `rerun.mjs`: actually executes, `(code, exit)` reachability, UNAVAILABLE / NULL-READ / ASYNC-DEFERRED / UNSAFE-RERUN. 30 tests. |
| `tgw1-workflow-provenance-seam` | `…give-both-workflow-schemas-a-rerun-field-3-r` | `rerun` on `facts[]` in both cycles, the `bp search query` fix (D16), JS fan-out floors (D15), plus a module-scope schema self-check. |

**Charter landed with this wave.** The charter was authored at `448eee5f9` and
never reached `origin/main`; three of four builders reported they could not read
D1-D18 and worked from their task briefs. It rides the `tgw1-level-grammar-r`
branch. Merge that branch and the dangling pointer closes.

**Defects the review found and fixed** — all three were the epic's own failure
mode committed inside the tooling built to prevent it:

1. **False promotion to L1.** `curl http://[::1]:4000/…` derived L1. The URL host
   extractor stopped at the first colon and captured a bare `[`, which failed
   the loopback test. `LOOPBACK_HOST` already listed `::1` — the intent was
   there, nothing exercised it. A ceiling set too high is a level-skip.
2. **The probe's authority laundered onto the command's.** The executor's HTTP
   branch ruled on the bounded reachability probe and DISCARDED the literal
   command's exit, so `curl <live 200 host> | grep -c ABSENT_NEEDLE` returned
   verdict OK with `admits.pass: true`. The probe now governs reachability only;
   the literal exit governs the verdict. Mutation-proven (29 pass → 28/1 fail).
3. **A frozen `rerun` that could never run.** Specimen 3 carried an unfilled
   `<charter>` placeholder — a template posing as a command — and its `>` tripped
   the write-redirect guard, so the executor refused it UNSAFE-RERUN before
   execution. Found by running the fixture's commands through the other two
   slices; that cross-slice check is worth repeating every wave.

Also closed: vacuous `rerun: "n/a — …"` prose on unratified specimens (now
`null` + `no_rerun_reason`, so absence is typed as absence); the synthetic
no-lag side now declares itself synthetic; the one unproven control (the 4 MB
size bound) is now plantable; the workflow schema contract is a module-scope
throw instead of a throwaway probe, mutation-proven twice.

**What the next wave inherits.** Merge round 1, then dispatch by dependency:
`tgw1-adjudicator` (round 2) once grammar + executor are in; then
`tgw1-acceptance-suite` and `tgw1-workflow-gate-wiring` (round 3) once the
adjudicator merges. The adjudicator is where the wave's honest gaps become
visible and must be closed rather than inherited: the six `caught_by` labels are
HYPOTHESES the acceptance suite has to test, `GENERATED_ARTIFACT_PATTERNS` is
still a guess (`tgw-bl-l4-artifact-inventory`), `KNOWN_WRITERS` has one
hand-seeded entry (`tgw1-writer-census`), and specimen 4 remains honestly
UNCAUGHT — R1 structurally cannot catch it, so R2 dependency recording is the
real next capability (`tgw-bl-r2-dependency-enrichment-substrate`).

D10 still holds: nothing is stored durably, and `tooling/research-coverage`
stays blocked until its ledger is reproducible.

### Wave 2026-07-20 (2) — round 1, verify-writes-back. Grade A−.

Paper: `source-of-truth-grip-wave-2-2026-07-20`. Six round-1 slices built and
reviewed; the two round-2 slices deferred by design (sequenced-rounds law), not
stalled. Every slice ran `builder_model: opus` — the wave's hard model
constraint, verified on all six task documents.

**Landed** (final branches carry a reviewer `-r` commit):

| Slice | Branch | What |
|---|---|---|
| `tgw2-adjudicator` | `…ship-the-verdict-engine-by-composing-adm-0-r` | `adjudicate.mjs` + `cli.mjs`: the verdict engine as a COMPOSITION of `admitFact`, ten frozen names, CONFLICT unit-tested and stated NOT live. 32 tests. |
| `tgw2-inloop-gate` | `…run-a-grammar-free-demotion-gate-over-ev-1-r` | `gateFactProvenance` in `bp-epic-cycle.workflow.js` — one grammar-free interception per resolve, DEMOTE-never-drop. 17 tests under a host-shaped vm. |
| `tgw2-recipe-ledger` | `…store-re-derivation-recipes-never-values-2-r` | `ledger.mjs`: rows with NO value field, `wx` content-addressed immutable writes, conflict observed at fold time. 37 tests, 7 selftest controls. |
| `tgw2-grip-quote-safety` | `…make-classifysafety-quote-aware-so-hones-3-r` | Quote-aware `classifySafety` + interpreter carve-out; suite made invocation-agnostic; vacuous test 21 tightened. 38 tests. |
| `tgw2-l4-artifact-census` | `…derive-generated-artifact-patterns-by-ru-4-r` | `GENERATED_ARTIFACT_PATTERNS` derived from an actual emitter census; marker-splice boundary ruled in a comment. 45 tests. |
| `tgw2-wild-bulk-fanout-floor` | `…give-wild-bulk-cycle-the-same-never-fewe-5-r` | Four named fan-out floors + two survival guards in `wild-bulk-cycle`; minItems settled by reading the host. 10 tests (added in review). |

**The wave's thesis, delivered.** Wave 1 shipped a substrate nothing called.
Wave 2 makes the loop USE it: facts returned by the survey and verify fleets now
pass a demotion gate in-loop, and the durable store exists with a schema that
cannot hold an answer. All six branches merge clean with every gate green.

**Defects the review found and fixed** — the pattern from wave 1 held: the
epic's own failure modes kept appearing inside the tooling built to prevent them.

1. **The ten-name vocabulary leaked through Object.prototype.** `EXECUTION_MAP`
   is an object literal, so a bare index resolved inherited keys — an executor
   returning `toString` / `constructor` / `__proto__` produced a ruling whose
   verdict was a function or `{}`. The guard written to keep the vocabulary
   closed was the one place it failed open. Own-property lookup + non-string
   guard; mutation-proven.
2. **The demotion never reached Decide.** The gate annotated the resolved survey
   objects and Digest saw it, but the Decide projection was
   `{key, findings, relevant_files}` — no `facts[]` at all, and
   `relevant_files` is not even a SURVEY_SCHEMA property. So the phase that
   FILES THE NEXT WAVE'S SLICES was blind to which facts cannot be re-derived.
   The wiring read as done while half-connected.
3. **One rotten row took down the whole ledger fold.** `admitRecipe` gates the
   WRITE path; nothing re-admits the READ path. A non-string subject threw out
   of `recipeKey` and cost every well-formed row in every other file, while null
   rows and subject-less rows silently merged into one bogus empty-key entry.
   Reported at row grain now — never skipped, never fatal.
4. **The quote-safety fix opened four live bypasses.** `su -c`, `watch`,
   `elixir -e` and `iex -e` each rated `rm -rf /tmp/y` SAFE once quoted — all
   commands the executor would then have run. Closed on SHAPE, not a longer name
   denylist: an unknown head handed a quoted argument through
   `-c`/`-e`/`--eval`/`--command`/`--exec` is assumed to execute it, with a
   small allowlist of data-flag heads. That inverts the error direction for the
   unbounded set, which is the point — a wrong allowlist entry costs a false
   refusal, a wrong denylist costs a false permission.
5. **The fan-out floors had no test at all.** The slice's gate was `node
   --check` — a syntax check that cannot tell a floor of 3 from a floor of 0.
   That is the slice's own thesis failing one level up: the anti-goal was prose,
   prose does not run, so it became a throw, and the throw was checked by
   something that does not run it either. Harness committed
   (`tooling/grip/test/fanout-floors.test.mjs`), mutation-proven three ways.
   Also hardened: `"abc".length` is 3 and satisfied `DOMAIN_FLOOR`.

**The number wave 2 was missing, now measured.** The quote-safety builder said
the never-cry-wolf rate was unknown. Over the 651 distinct frozen-corpus
commands, refusal went **84 → 79: five false refusals recovered, zero newly
refused.** Strictly better, no new cry-wolf. The L4 census was likewise
re-verified independently: the corpus re-derives an identical L1 33 / L2 31 /
L3 336 / L6 252, so no historical command was silently re-levelled.

**Honest gaps carried forward, not papered over.** L4 is still 0 across the
frozen corpus — the corpus predates the emitters appearing in rerun commands, so
only `level.test.mjs` can regression-test L4 today. CONFLICT remains unwired and
unproven in the field in both the adjudicator and the ledger. The ledger is
empty: nothing writes a row from a real verify phase yet, which is exactly what
`tgw2-verify-writes-back` is for. And D28 still holds — no fan-out floor in
either workflow has ever fired in a real run; all of it is harness evidence.

**What the next wave inherits.** Merge round 1 (six branches, all green), then
dispatch by dependency: `tgw2-acceptance-suite` once `tgw2-adjudicator` is in,
and `tgw2-verify-writes-back` once BOTH `tgw2-recipe-ledger` and
`tgw2-inloop-gate` are in. `tgw2-verify-writes-back` is the one that makes the
wave title fully honest — until a verifier actually writes a row, the store is a
schema with no contents. Backlog worth taking after that:
`tgw2-fold-reread-derived-level` (the fold trusts a stored derivation, which is
a stored value by another name), `tgw2-l4-grip-corpus-selfref` (safe to apply
once this wave's L3 citations have merged), and `tgw-bl-wild-bulk-roster-floor`
(a fifth, still-unguarded fan-out).

### Wave 2026-07-21 — round 1, survey-reads-leads. Grade A−.

Paper: `source-of-truth-grip-wave-3-2026-07-21`. Four round-1 slices built and
reviewed; the three round-2/3 slices deferred by design (sequenced-rounds law),
not stalled. Every slice carries `builder_model: opus` — the wave's hard model
constraint, verified on all four task documents.

**Landed** (every final branch carries a reviewer `-r` commit):

| Slice | Branch | What |
|---|---|---|
| `tgw3-census-screen` | `…ship-a-fail-closed-allowlist-screen-so-t-0-r` | `screen.mjs`: the three-layer fail-closed screen (host bound → head/sub-verb allowlist → write shapes), importing nothing from `rerun.mjs` (D29). 34 tests, three named sets, measured reach 240/651 = 36.9%. |
| `tgw3-level-compound-fix` | `…close-the-compound-walk-level-skip-and-t-1-r` | `level.mjs` walks compound segments instead of sniffing a head, `bp`/non-`api` `gh` → L2, plus a parseability floor. L6 38.7% → 22.4% over the frozen 651. 71 tests. |
| `tgw3-ledger-honesty` | `…make-a-forged-ledger-row-rejectable-the--2-r` | `admitRecipe(input, {now, screen})`: the injected future bound, Z-only instants, the injected safety screen, `CONFLICT` → `RIVAL-METHOD` (D31/D33/D39). 60 tests, 16 selftest controls. |
| `tgw3-prompt-seam` | `…let-verify-write-ledger-rows-and-decide--3-r` | D27/D35 in `bp-epic-cycle.workflow.js`: Verify's narrow ledger carve-out, DENIED on the worktree branch, Decide staging rows by explicit path, the stranded-file loss ruled in a code comment. 28 source-reading tests. |

**The reach number is HIGHER than D29's and that is the honest read.** D29
records 194/651 = 29.8%; the shipped screen admits 240/651 = 36.9%, because it
screens `cd X && <read>` and pipelines SEGMENT BY SEGMENT rather than refusing
them whole. The builder reported what it measured instead of steering to the
estimate. The two figures have not been proven to measure the same thing — the
29.8% methodology was not reproduced — so **D29's 29.8% should be read as
superseded by 36.9% for the shipped module, and neither number may be quoted as
"coverage of 651 commands"** (the module's own `--census` says so in prose).

**Defects the review found and fixed.** The wave-1 and wave-2 pattern held for a
third time: the epic's own failure modes keep appearing inside the tooling built
to prevent them.

1. **D29's own named danger walked through both layers of the screen.** `curl -o
   /opt/barkpark/deploy/site-deploy.sh` is refused; `curl -so /opt/barkpark/
   deploy/site-deploy.sh` was **ADMITTED**. Short flags cluster, and both layer
   (b) and layer (c) compared `-o` as an exact token. Six more of the same class
   went with it: `curl -sO`, `gh repo clone`, `gh release download`,
   `bp --server=<remote>` (walking straight past the loopback bound),
   `journalctl --vacuum-size`, and `date -s` (a census able to move the system
   clock the ledger's own now-bound compares against). The screen's error
   direction was right; its *parser* was not.
   **The instrument lesson is the real one:** the DANGER SET carried only the
   unclustered spelling, so the measurement built to catch exactly this class
   could not see it. A named set measures the spellings it contains and nothing
   else. All seven now live in `DANGER_SET`, so the selftest carries them — and
   the fixes cost the census **zero** reach (240/651 before and after, pinned by
   a test), which is the check that separates a real fix from cry-wolf.
2. **`gh` was a denylist inside the allowlist module.** `ghRule` carried only
   `GH_WRITE_VERBS`, so any unlisted noun sailed through — the exact shape the
   module's own header argues cannot be complete. Now a noun allowlist with
   per-noun read sub-verbs, with the denylist kept behind it. Corpus reach
   preserved exactly: the 23 `gh` rows use only `api`, `pr`, `issue`, `run`.
3. **The two slices that must meet did not meet.** `ledger.mjs`'s injected
   screen contract read `verdict.message`; `screen.mjs` returns `{ok, reason}`.
   Built in the same round with disjoint file sets, both correct alone, and
   nothing in either suite ever put them in a room together — so every refusal
   printed the generic fallback and **discarded the screen's diagnosis**, in the
   precise place `REFUSED_HEADS` authors a per-head explanation so the log would
   not be a shrug. Verified by wiring the real `screenCommand` in. Both keys are
   accepted now, and a cross-slice test pins the seam.
4. **The prose floor floored a good command.** `find . \( -name a -o -name b \)`
   went L3 → L6: a backslash-escaped paren read as a prose aside because
   `-name` is not a plausible command head. **Zero occurrences in the 651-command
   corpus**, so the before/after distribution was bit-identical with the bug
   present and with it fixed — the same blindness that hid the builder's own
   `sort < in.txt > out.txt` cry-wolf. *A corpus distribution is a LOWER BOUND on
   cry-wolf, never a proof of its absence.* Both controls mutation-proven.
5. **An async screen read as an over-aggressive screen.** A Promise is neither
   `true` nor `{ok:true}`, so the tolerant contract failed it closed under
   `REFUSED-COMMAND` — right verdict, wrong diagnosis, and it would have sent
   whoever wires the CLI next round hunting the wrong bug. Now `SCREEN-NOT-SYNC`.
6. **The copies-that-must-agree question, closed.** The builder flagged that a
   second workflow file might still carry the pre-carve-out verifier prompt and
   did not check. It does not — `bp-epic-cycle.workflow.js` is the only carrier
   — and that is now a test rather than an observation someone made once.

**What the wave did NOT prove, and must not be read as proving.** No dispatched
verifier has yet written a ledger row and no Decide has yet committed one: the
seam is prompt text plus tests that the words are in the shipped file, which is
the ceiling of any prompt slice. **The ledger is still empty.** The loop reads as
closed one wave before it is.

**What the next wave inherits.** Merge round 1 (four branches, all green, all
merging clean together — verified by merging all four onto `origin/main` in one
tree: 272 tests pass, both selftests green, the workflow parses). Then dispatch
strictly by dependency: `tgw3-write-verb` and `tgw3-census-verb` once
`tgw3-census-screen` and `tgw3-ledger-honesty` are in, then `tgw3-leads-verb`
once `tgw3-write-verb` is in. `tgw3-write-verb` is the slice that converts this
wave's opt-in bounds into real seams — until it lands, `admitRecipe`'s `now`
bound is a mechanism nobody passes, and a forger who omits `now` is admitted
exactly as before.

Backlog worth taking after that: `tgw-bl-screen-wire-into-rerun` (nothing calls
the screen yet — a proven capability protecting nothing),
`tgw3-decide-stages-foreign-rows` (Decide cannot tell this run's rows from a
concurrent session's), `tgw3-bl-segment-relevance` (strongest-segment-wins
over-permits when the authoritative segment is not the fact's source — the
sharpest residual in the level grammar), and `tgw3-bl-ssh-bare-host-alias` (a
bare `ssh <alias>` derives L6; pre-existing, and widening `SSH_READ` is a
promotion rule change that needs a decision, not a review fix).

### Wave 2026-07-21 (2) — round 1, the substrate gets a caller. Grade A.

Paper: `source-of-truth-grip-wave-4-2026-07-21`. Five round-1 slices built and
reviewed; `tgw3-leads-verb` deferred by design (sequenced-rounds law), not
stalled. All five carry `builder_model: opus` — three of them only after this
review patched the field on, see the ledger note below.

**THE LEDGER IS NO LONGER EMPTY.** Three waves said "the loop reads as closed
one wave before it is". It is closed now. `node tooling/grip/ledger.mjs write
<facts.json>` is shell-reachable, and on the merged tree
`git ls-tree HEAD --name-only tooling/grip/ledger/` returns a real run file
beside `README.md`. Nine rows fold to seven keys and RIVAL-METHOD fires once —
the clustering D32 predicted, delivered on the first write. Re-derived in review,
not taken on report.

**Landed** (final branches carry a reviewer `-r` commit where one was needed):

| Slice | Branch | What |
|---|---|---|
| `tgw3-write-verb` | `…ship-the-write-verb-and-the-minting-tran-0-r` | `mint.mjs` + the `write` verb: a fact→recipe TRANSFORMER, subject from the rerun's path token, `now` and `observed_at` from ONE `date -u` reading, all-or-nothing writes. 25 new tests. |
| `tgw3-census-verb` | `…ship-the-decay-census-so-the-epic-measur-1-r` | `census.mjs`: family-first silence classification over the frozen corpus. 85.4% of 178 decisive recipes still answer, 14.6% decayed, reach 240/651 printed as the honest bound. 40 tests. |
| `tgw4-screen-overwrite-guard` | `…close-the-arbitrary-file-overwrite-primi-2-r` | The `sort -o` / `uniq <in> <out>` / `tree -o` / `npm pack` / `curl -so<path>` overwrite primitive closed, DANGER_SET 23→29, NEVER_CRY_WOLF 4→10, census reach unchanged at 240. 39 tests. |
| `tgw4-wiring-and-acceptance` | `…prove-the-screen-to-ledger-contract-with-3-r` | `test/wiring.test.mjs` (substring containment through both real modules) + `acceptance.mjs` (the six ratified specimens through the real adjudicator). 15 + 3 tests. |
| `tgw4-rerun-silence-fixes` | `…stop-rerun-mjs-laundering-a-tool-error-i-4` | Family-dispatched silence in `rerun.mjs`, the `merge(?!-base)` carve-out, and a THIRD defect the builder found itself: git's global options let `git -C <path> push` classify SAFE. 55 tests. |

**D49's proof reproduced by the reviewer, exactly as claimed.** The consistent
rename `reason`→`why` across `screen.mjs` and its own suite leaves screen 34/0,
ledger 60/0 and level 71/0 — every shipped suite 100% green — while
`wiring.test.mjs` goes 3/3 red. That is the wave's most decisive artifact and it
behaves as advertised.

**The defect only the merge could see.** Each slice was green alone; the union of
all five went RED. `screen.test.mjs` froze `classifySafety`'s corpus admission at
`572`, a number belonging to `rerun.mjs` — a module that suite does not own — and
`tgw4-rerun-silence-fixes` legitimately moved it to 583 (the `merge-base`
carve-out re-admits 11 rows). Two correct fixes jointly producing a red, the
co-scoped-merge class again. The sharper half is the irony: that test's own
comment reads "ratios are asserted, not counts" with three frozen counts below
it — the retired-statistic disease committed inside the cure. Fixed on the
screen slice: the screen's own 240 stays pinned (it is what that suite owns), and
`classifySafety`'s figure is asserted as a MARGIN and printed, never frozen.
**A wave whose slices are individually green has not been reviewed until they
have been merged into one tree and gated together.**

**Other defects the review found and fixed.** The pattern held for a fourth wave
— the epic's own failure modes keep appearing inside the tooling built to
prevent them:

1. **A bound that silently unbound itself.** `census.mjs --limit` with a missing
   or non-numeric value parsed to `NaN`, failed the `isFinite` test and ran the
   ENTIRE 651-command corpus. The operator asked for a bounded run and got an
   unbounded one with no signal. Named rejection, exit 2.
2. **An underpowered pass wearing a full census's authority.** `--limit 12`
   admits 3 decisive rows, measures 0.0% decay and printed "CONSISTENT — below
   the 22.4% floor". Zero-admissible already had a NULL STATE; too-few-to-say did
   not. A 30-row floor now returns UNDERPOWERED and reports the measurement as an
   observation, never as consistent or contrary. Control pair tested both ways.
3. **The acceptance suite's escape hatch cost nothing.** "Each entry must be paid
   off by a filed task" was a COMMENT, and nothing read it — an entry with an
   empty `filed_as`, or one whose label did not actually diverge, silenced a real
   finding just as well as an honest declaration. The shape is now checked at
   module scope and FATAL on import, like PROBE-DRIFT. It still cannot prove the
   task exists (that needs the network, and the module is hermetic); it proves
   the declaration was written as a payoff rather than as a shrug.
4. **The write verb died as an unhandled rejection.** `main` became async when
   `write` landed and nothing caught it. A store whose CLI dies quietly is
   indistinguishable from one that wrote nothing on purpose. Named crash, exit 2.
5. **A test that made the suite flaky one run in three** — introduced by fix 3,
   caught by running the union gate eight times rather than once. The mutated
   module copy was written INTO `tooling/grip`, where another test in the same
   process enumerates every file in that directory. Moved out of the tree with
   its sibling imports rewritten to absolute URLs. Eight clean runs.

**Ledger audit.** All five slices left `lifecycle: in_progress` with the
merge-gated criterion honestly open — builders did not close what the lead
closes. Two fixes were needed. (a) `builder_model` was ABSENT from all three
`tgw4-*` tasks, against the wave's own hard model constraint; Decide filed the
tgw4 slices on a thinner schema than the tgw3 ones (no `gate`, `round`, `size`,
`surface` either). The Paper's wave plan states "Every slice runs on opus", so
the intent was recorded at L5 while the spine the gates read carried nothing.
Patched and re-published. (b) `tgw3-census-verb` criterion 5 (a clean `go vet`
classifies as an ANSWER) was PROVEN and left unstamped — the task's own now-line
said "12/13". Re-derived in review and stamped with evidence. No task outside
this wave was touched.

**What this wave did NOT prove.** The census is not hermetic: `bp` and `gh` are
allowlisted read heads, so a run reaches live services and an outage would
inflate the decay rate as RAN-AND-FAILED. 14.6% describes this box on this day
more tightly than the render says. The mint's ~76% path-token yield is still
INHERITED from the charter, not re-derived — the write verb has not yet been fed
a real survey report, only nine hand-authored facts. And `absenceEligible` is
enforced at exactly one seam: `adjudicate.mjs` maps on the verdict alone, so the
veto survives on `ruling.rerun` but is never promoted.

**What the next wave inherits.** Merge round 1 (five branches, verified merging
clean together into one tree: 382 tests, 381 pass, 0 fail, 1 skipped by design;
both selftests green; `acceptance.mjs` exit 0). Then `tgw3-leads-verb`, and only
once BOTH `tgw3-write-verb` and `tgw3-census-verb` are on `origin/main` — it
needs rows to read, it renders the census's verdict, and it edits the same
`ledger.mjs` CLI routing the write verb just claimed. It ships REDUCED per D43:
the substring filter is the feature; the band, the rank and the RIVAL-METHOD flag
are all cut.

The sharpest work after that is DOGFOODING what now exists rather than adding to
it: run a real survey report through `ledger.mjs write` and re-derive the mint
yield from something nobody hand-authored. Backlog filed this review:
`tgw4-absence-veto-stops-at-the-rerun-seam` and
`tgw4-census-run-is-not-hermetic`.

> **Landed retroactively by wave 6 (D83).** The entry below was written, graded and
> reviewed on 2026-07-21 as commit `170f01420`, then stranded: it lives only on
> `truth-grip/wave5-review`, no PR was ever opened for it, and its diff parent blob is
> byte-identical to the charter blob it never reached. Its CODE landed; only the record of
> how did not. It is reproduced verbatim rather than rewritten from memory.

### Wave 2026-07-21 (3) — round 1, the ledger becomes readable. Grade A.

Paper: `source-of-truth-grip-wave-5-2026-07-21`. Six round-1 slices built and
reviewed; `tgw5-corpus-backfill` and `tgw5-fold-hardening` deferred by design
(sequenced-rounds law), not stalled. All six carry `builder_model: opus`, filed
that way by Decide rather than patched on in review — the wave-4 lesson held.

**ROSTER DRIFT, named per D72.** The roadmap table above lists slices 2 and 5 as
`tgw5-leads-verb` and `tgw5-probehttp-argv`. The real, claimed, stamped task ids
are **`tgw3-leads-verb`** and **`tgw4-bl-probehttp-shell-injection`** — both
correctly kept their original ids rather than being re-filed. The charter names
should be read as titles, not ids.

**THE VERB EXISTS AND IT READS WELL.** `node tooling/grip/ledger.mjs leads
<substring>` returns recipes over the 62-row store: `internal/cli` → 8 of 48
indexed subjects, 11 recipes, each with a level RE-DERIVED from the command at
render time. The no-value guarantee is structural, not promissory, and a forged
run file carrying `value: 544` is proven unable to put 544 on the screen.

**Landed** (final branches carry a reviewer `-r` commit where one was needed):

| Slice | Branch | What |
|---|---|---|
| `tgw5-screen-hardening` | `…close-two-upstream-rce-primitives-and-fo-0-r` | Two upstream RCE primitives closed — double-quoted `$()` (live-proven to execute through `censusOne` itself) and the env-assignment strip — plus four write-flag holes and two false refusals. `sed` LEFT `REFUSED_HEADS` and is judged on its SCRIPT by a real scanner. Reach 240→254/651, accounted for member-by-member. 58 tests. |
| `tgw3-leads-verb` | `…ship-grip-leads-substring-filtered-recip-1-r` | `leads.mjs` + the `prescreen` rehearsal verb. Shipped REDUCED exactly as D43–D46 rule: no band, no rank, no RIVAL-METHOD flag, each cut asserted on rendered output. 30 tests. |
| `tgw5-mint-fixes` | `…stop-the-mint-discarding-go-and-top-leve-2-r` | Go package globs, top-level directories, and the quantity re-keyed from the FLAG to the PROPERTY. Corpus path-token yield 48.8%→54.1%, collision groups 58→45. The RIVAL-METHOD control fires through `foldLedger`, so the signal was narrowed rather than erased. |
| `tgw5-census-ledger` | `…point-the-census-at-the-ledger-make-it-v-3-r` | `census --ledger`, the D67 NUL byte, the D68 hermeticity fix, and `validateArgv`. 58 tests. |
| `tgw4-bl-probehttp-shell-injection` | `…close-the-probehttp-fact-derived-url-inj-4` | `probeHttp` spawns curl with an argument vector. Re-derived live in review: the payload leaves no marker and curl exits 3. **No reviewer commit needed — correct as shipped.** |
| `tgw5-write-path-docs` | `…document-the-write-path-where-a-writer-a-5-r` | The nine discovery steps answered beside the write target; D62 and D67 written down honestly. |

**THE UNION WAS GREEN ON THE FIRST TRY.** Wave 4's headline lesson was that a
wave whose slices are individually green has not been reviewed until they are
merged into one tree and gated together. Done first this time, including the
`truth-grip/wave5-decide` charter commit and its 62 rows: seven branches merge
clean, **460 tests / 459 pass / 0 fail across three consecutive runs**, selftest
16/16, fold exit 0, `census --ledger` and `--limit 40` exit 0, acceptance exit 0.
No co-scoped-merge defect this wave.

**What the review found and fixed.** The epic's own failure modes kept appearing
inside the tooling built to prevent them, for a fifth wave:

1. **Three README claims that go FALSE the moment this wave merges.** The docs
   slice branched from a base where its siblings were unmerged, so it correctly
   stated that `prescreen` does not exist, that
   `NODE_OPTIONS=--require=… mix test` is admitted, and that `census.mjs`
   contains a NUL byte. All three are false on the merged tree. A doc is an L5
   claim about L2 and this one would have shipped stale on day zero. Rewritten
   against the merged tree with real output pasted, and the NUL section kept in
   PAST tense because the METHOD RULING outlives the fix — repairing the file
   does not retroactively make a negative measured through a blind wrapper have
   happened.
2. **`leads` rendered a partially-unreadable store as a smaller clean one.** The
   builder named this as the sharpest thing it would fix next and did not fix
   it. `foldLedger` reports unusable run files in `unreadable[]` and the fold
   CLI exits 1 on it, but `selectLeads` read only `entries[]` — so rows that
   were never READ rendered as rows that do not EXIST, and the empty state
   printed "This is an answer, not a blank" over a store half of which was never
   opened. That is D6's disease at the read layer. Surfaced above both render
   paths, named file by file, honesty claim withdrawn when it applies.
3. **A false refusal inside the fix for false refusals.** `envAssignmentReason`
   tested the raw span, so `CC="/usr/bin/clang"` was refused while its unquoted
   twin was admitted. Quotes are now stripped for the shape test only — the
   expansion test still reads the raw span, so `CC="$FOO"` stays refused.
4. **The census's unreadable branch was dead code nobody had run.** The builder
   said so. It is the branch that stops a partially-read store publishing itself
   as a clean smaller one — the highest-cost branch in the module — so it is now
   fired against a synthesised rotten store, with a clean-store control.
5. **The eight new mint subjects nobody eyeballed.** Enumerated: 42
   single-segment subjects, six of them new. Three are the repo's real top-level
   names; three (`lib`, `src`, `sizer`) are RELATIVE and conflate directories.
   No behaviour change — the conflation is the correct trade — but it is now a
   stated and tested property rather than something the first ambiguous lead
   teaches somebody.

**THE ONE THING THE LEAD MUST DECIDE BEFORE ROUND 2.** Re-derived on the merged
tree: **57 of the 62 committed rows carry a `quantity` the merged mint would no
longer produce.** The mint fix is on `origin/main`-to-be; the STORE still
carries the fabrication it was built to kill — `census --ledger` prints "9
recipes for `git:show` of `bp-epic-cycle.workflow.js`", and `leads internal/cli`
shows a line count beside a match count as rival methods of one property, which
is D60 verbatim. `tgw5-corpus-backfill` mints under the NEW grammar, so running
it over this store splits the index by ERA rather than by method and leaves the
old half fabricating rivals among itself forever. The tension is real in both
directions: `ledger/README.md` declares run files immutable, so rewriting keys
breaks a ratified rule and discarding them loses 62 rows of genuine foreign
work. Filed as **`tgw5-mint-key-era-split`** (priority 1, published) because it
is a charter decision, not a patch.

**Ledger audit.** The most honest ledger of the five waves. All six built slices
left `lifecycle: in_progress` with the merge-gated criterion open for the lead,
every other criterion stamped with real evidence as the work happened, and both
round-2 tasks untouched at `open`. Two fixes. (a) `tgw5-write-path-docs`
criterion 1 was an honest `--miss` ("documented together with the prescreen
escape") that the REVIEW made true; stamped with evidence naming the review
commit and the reason the builder's miss was correct at the time. (b)
`tgw5-prescreen-verb` — filed by the docs builder for a verb `tgw3-leads-verb`
was shipping in the same wave — closed by CONTENT per D71 before it reached the
ready pool. No task outside this wave was touched. Seven backlog tasks filed by
builders were verified present and published.

**What this wave did NOT prove.** The store is 62 rows, not the ~250 round 2
targets, so P5 remains un-re-adjudicated and `leads` is still a verb whose
value rests on a corpus that has not arrived — the leads builder measured 77.8%
honest-empty at subsystem granularity over the 9 rows it had and reported it
rather than flattering it. The `sed` script scanner is genuinely new attack
surface, hand-written, fail-closed on everything it does not model, and it is
the part of this wave a future reviewer should read adversarially rather than
trust the green. Unquoted parameter expansion (`grep -n $PATTERN .`) is still
admitted. And `census --ledger` measures STILL-ANSWERING, never STILL-CORRECT —
the render says so, but 100% answering over 47 rows will be misread as health.

**What the next wave inherits.** Merge round 1 as ONE unit — the six `-r`
branches plus `truth-grip/wave5-decide`, whose charter the branches assume and
whose 62 rows the gates read. Then rule on `tgw5-mint-key-era-split`, because it
is upstream of the store backfill writes into. Then `tgw5-corpus-backfill`
(after screen + mint + census are on `origin/main`, proven BY CONTENT per D40)
and `tgw5-fold-hardening` (after leads). Round 2 is where this epic's central
claim finally gets tested at a row count where an honest empty is informative.

### Wave 2026-07-21 — bind the answer to the tree. Round 1. Grade A−.

Paper: `source-of-truth-grip-wave-6-2026-07-21`. Four round-1 slices built and
reviewed; slices 5-7 deferred by design (sequenced-rounds law, now 8-for-8), not
stalled.

**Landed** (every final branch carries a reviewer `-r` commit — merge the `-r`
variant, never the original):

| Slice | Final branch | What |
|---|---|---|
| `tgw6-binding-classifier` | `…classify-what-every-stored-recipe-is-anc-0-r` | `binding.mjs` (+867 lines) + 63 tests: five classes keyed on REF IDENTITY per D73, 17 named rules with `is_default` flags, `exit_masked` + `exit_mask_rule`, `cd_prefix` recorded and never weighed. Gated on the 652-proof corpus per D81. |
| `tgw6-self-provenance` | `…make-every-grip-verb-say-which-tree-it-i-1-r` | `provenance.mjs` + 22 tests: four facts, four batched git calls, STDERR only (D78), TOTAL by construction, no fetch. Wired into `census.mjs` / `acceptance.mjs` / `cli.mjs`, and `cli.mjs` finally got the entry guard it never had. |
| `tgw6-fold-rederives-key` | `…stop-the-store-rendering-a-line-count-as-2-r` | `foldLedger` keys on `quantityPhrase(rerun)` and re-derives `derived_level`, closing `tgw2-fold-reread-derived-level` in the same seam. Stored values survive as drift signals; fallbacks are NAMED and counted. |
| `tgw6-leads-subject-first` | `…make-leads-answer-about-the-subject-you--3-r` | `matchesQuery` matches the SUBJECT by default, command text behind `--cmd` and COUNTED, `MATCH_RULE` printed verbatim on every render. |

**The measured outcomes, all re-derived on the integrated tree.** The store goes
48 subjects → 62 with **0 rival methods** (from 4), and not one byte on disk
changed — `git diff … -- tooling/grip/ledger/` is empty, which is the whole
point of D77's ruling. `census --ledger` stops printing "9 recipes for
`git:show`". `leads origin/main` goes 51 rows → 0 with the honest empty naming
the 51 and the flag. The 62-row binding census is
`{content-addressed 0, shared-ref 51, per-worktree 2, cwd-bound 7,
foreign-tree-pinned 2}` with **zero** else-branch verdicts, and on the 652-proof
corpus the grammar's else share is 4.8% against a naive 3-way rule's 89.0% — the
unflattering 61.3% "a trivial always-cwd-bound classifier would agree" is printed
beside it rather than omitted. All four branches merge clean into `origin/main`
and into each other: **565 tests / 564 pass / 0 fail / 1 skipped** on the
integrated tree, with `fold`, `census --ledger`, `leads` and `leads --json` all
green.

**Defects the review found and fixed** — three of the four are the epic's own
disease inside the tooling built to cure it:

1. **A FABRICATED honest warning, on 7.1% of the corpus.** `binding.mjs` split
   pipelines over the RAW statement while every other scan ran over the
   quote-masked copy, so a quoted grep alternation read as a pipe:
   `grep -nE "foo|bar" x` reported `exit_masked: true` / `MASK-PIPE-SILENT` on a
   command containing no pipe at all. Measured: **46 of 652 proofs**. Zero
   `binding_class` verdicts move, so every census number in the slice's evidence
   stands. A module whose product is honest warnings cannot ship a fabricated one.
2. **A confidently WRONG diagnosis in the provenance banner.** Node raises the
   identical `{ code: "ENOENT", path: "git" }` for a missing binary and a missing
   cwd, so `treeProvenance` told anyone whose worktree had been pruned that "git
   is not on PATH". Now disambiguated (`no-such-cwd` / "NO SUCH DIRECTORY"), with
   a test that also asserts a real non-repo still reports `NOT_A_REPO` so the new
   arm cannot swallow the old one.
3. **Silent absorption of the wave's own headline number.** The fold restates
   **57 of 62** stored keys and NOTHING rendered it — `census --ledger` printed
   "rival methods 0" with no hint that the clean number is a property of the READ
   rather than of the DATA. Two lines added to the preamble: the restatement
   counts, and separately the FALLBACK counts, which are the only signal the fold
   could still be keying on a stale value.
4. **A false statement in the honesty footer itself.** `NO_VALUE_FOOTER` — printed
   to the user on every `leads` render — claimed the fold rebuilds each recipe
   from "six NAMED fields". It is twelve after this wave. The guarantee was never
   the count; all three sites now say "a NAMED ALLOWLIST". The header's claim that
   `tgw2-fold-reread-derived-level` is an OPEN defect was fixed the same way.
   Closes `tgw6-leads-header-stale-after-fold-rederive`, filed by a builder who
   correctly judged it a merge-conflict risk mid-round — it stopped being one once
   the review made the shared hunk byte-identical on both branches.

Also pre-resolved: the wave's ONE genuine merge conflict. Two round-1 slices edit
the same line of `leads.mjs`, and resolving it the wrong way makes
`level_restated` read `false` forever — the drift annotation retiring in silence.
Both branches now carry that hunk byte-for-byte identically, so it merges without
anyone adjudicating it.

**Ledger audit.** Clean, and the best-stamped wave of the six. All four built
slices left `lifecycle: in_progress` with only the merge-gated criterion open,
every other criterion stamped with quoted run output as the work happened.
`tgw6-leads-subject-first` criterion 2 is a stamped honest **`--miss`** with the
full measurement (`leads js` 30 → 30, `cmd_only_recipes` 0) and a filed
follow-up, rather than a criterion quietly re-read to fit. Nine backlog tasks
filed by builders and Decide are present and published; no task outside this wave
was touched. Review writes: a `review_note` on each of the four naming the final
`-r` branch, `tgw6-leads-header-stale-after-fold-rederive` closed 3/3, and one
new task filed — see below.

**What this wave did NOT prove, and one charter line that needs reading
narrowly.** The wave-6 section above says "after round 1, an agent in any
worktree types `node tooling/grip/ledger.mjs leads internal/cli` and the first
thing it learns is WHICH TREE the answer is about". **That is a round-2
statement, not a round-1 one.** `ledger.mjs` is deliberately excluded from
`tgw6-self-provenance`'s fence, so after this round the banner reaches
`census`, `acceptance` and `cli` — and the `leads` verb the sentence names has
no banner until `tgw6-leads-declares-binding` lands. Same shape for the
classifier: after round 1 the binding of every row is COMPUTABLE and nothing
RENDERS it. Round 1 buys a correct instrument and no visible answer, exactly as
D41 warned about round 0 last time.

And the wish's second half — "then measure whether leads beats grep" — was not
measured, by any slice, because no slice covered it. D79's head-to-head (10 of 10
against a repo-wide grep, 8 of 10 against a scoped one, **3 of 20** corrected for
precision) was measured against the concatenated haystack `tgw6-leads-subject-first`
just removed, so quoting it after this merge is the D23/D37/D52 stale-figure class
for the fourth time. Filed as `tgw6-leads-vs-grep-remeasured` (p1) with the
predeclare-the-term-list discipline written into its criteria, because a term list
assembled after seeing results is shopping for a number.

**What the next wave inherits.** Merge round 1 as ONE unit, in dependency order:
`binding-classifier-r` (carries this charter entry), then `self-provenance-r`,
then `fold-rederives-key-r`, then `leads-subject-first-r`. All four are proven to
merge clean in that order and in any other. Then dispatch round 2 as its
dependencies land — `tgw6-mint-binds-to-caller` needs only the classifier;
`tgw6-census-binding-report` needs the classifier and provenance;
`tgw6-leads-declares-binding` needs all four, and it is the slice that finally
makes the wave's headline true for the verb an agent actually types. Then
`tgw6-leads-vs-grep-remeasured`, which cannot honestly run before round 2 ships,
and which is the only thing that will tell this epic whether its read path earns
the typing.

### Wave 2026-07-21 (4) — the finishing wave: volume, a readable leads, the verdict, the last RCE. Grade A−.

Paper: `source-of-truth-grip-wave-8-2026-07-21`. Seven round-1 slices, all
file-disjoint, every one `builder_model: opus` (the wave's hard constraint,
verified on all seven task documents). Wave 7 strategized, surveyed and verified
but died at Decide (spend limit) before cutting a slice; wave 8 is the fresh wave
that decided the slices wave-7's analysis supported, built them, and drove to
seal. Decisions D84–D92 land with this entry (D42: the charter commit cannot be
deferred).

**Landed** (final branches carry a reviewer `-r` commit only where the review
changed something):

| Slice | Task | Final branch | What |
|---|---|---|---|
| S1 volume | `tgw5-corpus-backfill` | `…fill-the-ledger-by-re-execution-mint-the-0` | `backfill.mjs`: the census as a MINTING INSTRUMENT (D58). 651 distinct → 254 admitted → 195 executed → 167 answering/minted, committed as one immutable run file. Store 63→230 rows (3.71x, D85). Execution gated on `screenCommand`, never `classifySafety`. |
| S2 readable | `tgw6-leads-subject-segment-noise` | `…leads-is-short-precise-and-declares-its--1` | `leads.mjs`: subsystem-boundary segment matching (D91, closes the live 25/30 `leads js` defect), dense one-line render, all-ancestor rollup (D87), per-row binding. Review-measured precision **100%**. |
| S3 hardening | `tgw5-fold-hardening` | `…harden-the-fold-read-path-fix-the-main-s-2` | `ledger.mjs`: the fold COMPOSES `admitRecipe` and routes rejections into `unreadable[]` (nonzero exit); `process.exitCode` fixes the stdout-flush truncation race (D92); the self-provenance banner on stderr (D78). |
| S4 census | `tgw6-census-binding-report` | `…census-reports-what-each-answer-was-abou-3` | `census.mjs`: every measured row carries its binding class; the render states which tree the census ran in; 254-hygiene (D84). Gates on `screenCommand` only (D47). |
| S5 mint | `tgw6-mint-binds-to-caller` | `…mint-future-recipes-bound-to-the-caller--4` | `mint.mjs`: strips a leading `cd <abs> &&` iff `classifyBinding` rates the remainder ref-decided; a provable NO-OP over the index (0 committed rows moved). Imports the rule from `binding.mjs`, never restates it. |
| S6 safety | `tgw-bl-screen-wire-into-rerun` | `…close-the-last-default-on-rce-caller-bou-5` | `adjudicate.mjs`: the caller-boundary screen wire (Design B, D88). The default runner is `screenedRerun`; a `cp /etc/hosts` fact no longer materialises the marker (W7). 0 test-flips. |
| S7 verdict | `tgw6-leads-vs-grep-remeasured` | `…the-committed-leads-vs-grep-trial-store--6-r` | New committed `trial-leads-vs-grep.mjs`: `--store <dir>` so the same instrument measures the 62- and 229-row stores; frozen W1–W7; redirect-not-pipe (D92). **Reviewer fix**: a self-test assertion pinned to the 62-row store (`api/lib === zero-coverage`) flipped to `large-bucket` once the backfill lands in the same dir — replaced with a volume-independent bucket-coherence check. |

**The wave's thesis, delivered.** All five in-fence outcomes shipped: volume
minted (3.7x), leads reads like a CLI at 100% precision, the RCE closed with a
spawn-detector proof, the committed verdict harness run at Review, reconciliation
debts cleared. The seven branches merge in dispatch order with **zero conflicts**
(the feared S2/S3 `leads.test.mjs` collision did not occur — S2 left the
forged-value test at baseline, only S3 rewrote it), and the integrated suite is
**621 pass / 0 fail / 1 pre-existing skip**.

**The one defect the review found and fixed** — and it is the epic's own lesson
one level up: a builder gating on its OWN isolated branch cannot see a
store-VOLUME interaction with a sibling slice. S7's self-test asserted a
62-row-store outcome; S1's backfill lands +167 rows into the SAME ledger dir, so
`api/lib` moved from zero-coverage to large-bucket and the assertion failed on
the integrated tree the wave actually ships — invisible to every isolated gate,
caught only because Review built the integration and ran the full suite. Fixed by
asserting the classifier's coherence (bucket_class is a pure function of
`leads_on_subject`) instead of a volume-pinned outcome.

**The verdict — does leads earn the typing?** Measured at Review on the merged
229-row store, published whichever way it fell (D21). **W5 precision: 100%**
(115/115 returned rows on-subject) against D79's retired 29.2% and post-#5441's
74.4% — the decisive, unambiguous win. **W4: `internal/cli` = 20 rows**, the
prediction pinned. **W6 head-to-head splits on the metric, and the metric choice
IS the verdict**: on *first-command* (time-to-first-answer) leads wins 0/8 — a
scoped grep gets there faster; on *full-scan* (lines to read the whole returned
set) leads wins 5/8 (62.5%) via its dense render. The honest reading: **leads is
a PRECISION INDEX, not a speed win** — everything it returns is about what you
asked, densely rendered, with the tree it re-runs in labelled — which is exactly
D46's ratified intra-epic scope and no wider. That is a valid seal per D46/D79
precedent: the read-path ambition is HONESTLY BOUNDED, not failed.

**What the next wave inherits.** Merge round 1 in dispatch order (S1 → S2 → S3 →
S4 → S5 → S6 → S7-r); the lead closes each slice's single merge-gated criterion
on merge (all seven sit `in_progress` with evidence stamped, one criterion open
each). This charter commit lands its own PR. There is no round 2 — the wave is
round-1-only by design. The in-fence thesis is COMPLETE; the SHORTEST PATH TO
SEAL is: land these branches, then a thin wave 9 seals the epic and re-homes the
out-of-fence remainders (server-side `type:fact` in an Elixir `before_publish`
hook, api/**; grip-suite CI, .github/**; the ~65 priority-2-4 in-fence hardening
long tail — screen sed-parser bounds, unquoted param expansion, pipefail masking,
plainRule flag audit). Two hygiene items filed as backlog: `tgw8-bl-stale-240-comment`
(D84) and the closed-by-content lifecycle flips for the wave-6 zombies
(`tgw6-binding-classifier`, `tgw6-self-provenance`, `tgw6-fold-rederives-key`,
`tgw2-fold-reread-derived-level`), which the charter's D89/D91 already record
durably. Standing cost: the committed 230-row store makes the grip suite census
32 network-reaching commands on every run (~47s, network-touching; hermetic CI
degrades them to tolerated SPAWN-ERRORs) — inherent to censusing the product, and
the suite still has no CI (D82), so every green stays a local green.

### Wave 2026-07-27 — the instrument adjudicates its own close. Round 1 of 2. Grade pending.

Paper: `truth-grip-seal-wave-9-2026-07-27`

**THE WAVE DID NOT SEAL, AND THAT IS THE FINDING.** Wave 9 was chartered as a thin seal wave. Two
rounds of ground truth turned it into something better: an adjudication. Sealing this epic by typing
`met: true` into four empty evidence fields would have been an L6 claim standing over an L2
measurement that says otherwise — the doctrine's own disease, wearing the doctrine's uniform, on the
doctrine's tombstone. Instead every criterion was adjudicated (D95–D98), the predicate for a real
close was written down (D94), and the refusal was recorded with its measurement (D93).

**Four inherited premises died on measurement, and every one of them would have produced a false
seal sentence.** (1) Criterion 4's killer is D13, not D26 — wave 1 committed no ledger at all, but
DID commit a 16,009-line evidence corpus under its own wave-1 decision, so the clause "verified by
the absence of any new persisted corpus" was self-refuting the day wave 1 merged. (2) Criterion 3's
clause (b) is UNSATISFIABLE, not unmet — `wild-bulk-cycle` has no VERIFY_SCHEMA because it has no
verify phase; the reword's provenance is `tgw1-workflow-gate-wiring`'s own fleet-scoped wording.
(3) D82's baseline was stale by 162 tests AND the suite is RED on main — three failures, one root
cause, none of it a grip regression. (4) D85's hermetic claim was wrong in digits (17 reaching, not
32) and in mechanism (rc 127 → PATH_GONE ∈ DECAYED, never the tolerated SPAWN-ERROR class), so a
hermetic census publishes 5.9% decay of which 87.5% is "this container has no `bp`" — the epic's
disease, manufactured by the epic's own instrument, inside the number a CI gate would have printed.

**The load-bearing new fact: closing a parent does NOT remove its children from the claim queue.**
Confirmed at L1 on production twice — 134 of 139 open tasks under a `done` parent sit in the live
ready pool, and a controlled scratch parent/child went 845 → 847 → 846 on closing the parent, with
the child still ready AND successfully claimed. D71 measured that `done` removes THAT ROW; it does
not extend downward. A sealed root with 64 claimable descendants is an active queue defect, not
cosmetics — so disposition precedes the flip, permanently (D94).

**What was NOT done, named rather than implied.** The gate did not ship this round: it is round 2
behind S1, because shipping an advisory check onto a main that is already RED joins a standing noise
floor whose own defect task has been open since 2026-07-20. Criterion 2b is not met and keeps a
named owner. The `~65 priority-2-4 long tail` was 57 direct / 64 in-namespace, flat, with no
priority 4 at all. And three verify assignments could not be answered without mutating production,
so they were answered by natural experiment instead and the bound is recorded.


### Wave 2026-07-27 (II) — wave 10, the closing wave: the seal becomes a COMMAND. In flight.

Paper: `truth-grip-wave-10-2026-07-27`

**The brief was stale and its central premise failed smoke: wave 9 already ran, twice, and never
flew a builder** (D107). So wave 10 does not re-book those six slices — it absorbs them, re-scopes
them against measurement, and takes the scope wave 9's own debrief assigns to wave 10 by name: the
root still open, `tgw2-acceptance-suite` still owning criterion 2b, and the seal reduced to one
mechanical check.

**THE THESIS.** Wave 9 applied the epic's central inversion — authority is DERIVED by a program from
the shape of the rerun command, never raised by the author's claim — to every fact the epic ever
stored, and then left THE SEAL ITSELF as prose. D94 writes the seal predicate in English, adjudicated
by whoever types `met: true` into four evidence fields. That is an L6 claim standing over an L2
measurement: the doctrine's disease, wearing the doctrine's uniform, on the doctrine's tombstone.
Wave 10 makes the seal DERIVABLE and the blocking set SMALLER. It does not produce the word SEALED,
which D94(c) forbids before the predicate holds — and D108 has now proven the predicate could never
have held, because the root is a member of the set it requires to be empty.

**Verification broke four of Decide's own premises and handed back a bigger, cheaper wave.** D99's
single root cause is three independent problems (D112). D100's gate shape passes vacuously and was
proven so by mutation (D113). The stranded-security emergency is fiction, and the real fail-open was
hiding one worktree over (D119). D105's supporting quotation does not exist and its precedents say
the opposite (D117). Two of the wish's four named items — the wave-6 zombie flips and the 240
comment — turn out to be already done or refuted, and one supposed out-of-fence remainder (grip CI)
turns out to be seal-critical (D114).

| # | Slice | Task | Round | Model | Surface |
|---|---|---|---|---|---|
| 1 | ledger commons honest — three independent reds, one shape discriminator | `tgw9-s1-ledger-commons-honest` | 1 | fable | tooling/grip ledger + 3 tests |
| 2 | criterion 2b — the frozen fixture screened, not executed | `tgw2-acceptance-suite` | 1 | fable | acceptance.mjs, cli.mjs |
| 3 | class-coverage tripwire — dual-spelling, all 16 modules | `tgw9-bl-uncontrolled-rejection-classes` | 1 | opus | new test file only |
| 4 | the seal becomes a command — `tooling/grip/seal.mjs` | `tgw9-s3-criteria-adjudicated` | 1 | fable | seal.mjs, adjudicate.mjs |
| 5 | level.mjs mention-promotion — a local doc grep derives L1 | `tgw5-bl-level-mention-promotion` | 1 | fable | level.mjs |
| 6 | wild-bulk provenance gate — criterion 3 clause (c) | `tgw9-s7-wildbulk-provenance-gate` | 1 | opus | wild-bulk-cycle.workflow.js |
| 7 | tail disposition + prune — drive clause (b) from 79 toward 0 | `tgw9-s4-tail-disposition` | 1 | opus | bp ledger + git remote |
| 8 | grip CI — the only L2 route for criterion 2 | `tgw6-bl-grip-suite-has-no-ci` | 2 (after 1) | opus | .github/workflows |

**HIGH-FLIP-RISK, flagged for independent re-derivation before merge:** slice 5 (does the quote-mask
fix demote any GENUINE remote read — the false-refusal direction, not the false-admission one);
slice 4 (the namespace lens — does the closure ∩ offset-walked-pool actually see every claimable
row, including the two hash-id children); slice 7 (every close-by-content adjudication, and D71's
leaves-only restriction on each candidate).

**What this wave will NOT do, named rather than implied.** It will not seal. It will not delete or
quarantine another epic's ledger rows. It will not run `git worktree prune`. It will not touch
`bp-epic-cycle.workflow.js`, the PortableDoc render path, or `js/react-native`. And the ~65
"priority-2-4 hardening long tail" was enumerated by nobody in two rounds of survey and remains
enumerated by nobody — slice 7 disposes the 79 by content, and whatever survives is named, not
implied.


### Wave 2026-07-27 (III) — wave 10 CLOSED. Three of eight slices landed. Grade B.

Paper: `truth-grip-wave-10-2026-07-27`. PRs #6359, #6360, #6361 — all pushed, none merged (the lead merges).

**WHAT LANDED — three slices, each of which does what it says.**

| slice | task | final branch | PR |
|---|---|---|---|
| class-coverage tripwire, dual-spelling over all 16 modules | `tgw9-bl-uncontrolled-rejection-classes` | `…class-coverage-tripwire-dual-spelling-ov-2-r` | #6359 |
| wild-bulk fact-provenance gate — criterion 3 clause (c) | `tgw9-s7-wildbulk-provenance-gate` | `…wild-bulk-cycle-gates-fact-provenance-be-5-r` | #6360 |
| tail disposition + prune — clause (b) 86 → 32 | `tgw9-s4-tail-disposition` | `…tail-disposition-prune-drive-clause-b-s--6-r` | #6361 |

**WHAT DID NOT BUILD, named rather than implied: FIVE of the eight slices returned nothing.**
`tgw9-s1-ledger-commons-honest`, `tgw2-acceptance-suite`, `tgw9-s3-criteria-adjudicated` (the seal
predicate — the wave's own thesis) and `tgw5-bl-level-mention-promotion` (the wave's one security
item) produced no branch at all; `tgw6-bl-grip-suite-has-no-ci` was round 2 behind S1 by design and
was correctly not attempted. **So the seal did not become a command, the L1-from-a-local-grep
promotion is still live on main, and the ledger commons is still red** — the full grip suite on the
combined wave branch is 644/640/3/1, and the three reds are exactly the ones S1 owns. Grip CI stays
correctly blocked behind them (D104).

**THE WAVE'S OWN FINDING, produced at review by re-derivation rather than by reading.** The tail
disposition claimed each of its 45 parks carried a row-specific reason plus a named reactivation
trigger in `content.engagement.note`. Re-derived over the live ledger: **0 of 46 `considering` rows
carry a note.** The mechanism is not broken — a control writes one and reads it back verbatim — it
was simply not used. The closes and the 26 disposition-patched open rows DO carry durable reasons;
only the parks lost theirs, so 44 of 45 adjudications exist nowhere. That is this epic's disease
inside this epic's own disposition row: a claim stored at the author's word and refuted the first
time a program went and looked. Corrected in the committed row (§R7), corrected on the task's
criterion evidence, one reason restored live, and the re-adjudication filed as
`tgw10-bl-park-reasons-not-durable`.

**A LIVE WRITE-PERMISSION HOLE, independently re-derived at review and NOT closed.** `screenCommand`
ADMITS `git -C log push origin main`, `git -C show commit -m x` and `git --git-dir log push`: the
global option's VALUE is read as the sub-verb, collides with the read-only allowlist, and the write
verb behind it is never examined. `rerun.mjs` refuses all three. Two gates, one command, opposite
rulings — `tgw4-screen-git-global-option-audit` stays OPEN and
`tgw10-bl-screencommand-bypass-census` names the shape. **This is the highest-value open row in the
namespace and the next wave should take it first.**

**THE RULE THIS WAVE ADDS: a close-by-content is only as wide as the module you ran.** Run every gate
that guards the capability, not the first one that agrees with you. The near-miss above would have
laundered a live hole into a `done` row.

**Clause (b) moved and the six stale refs are gone.** Blocking set 86 → 32 by content, one row at a
time, every close a verified leaf on two lenses; six superseded remote branches re-derived at prune
time with two-dot diffs and deleted, head SHAs recorded and confirmed still resolvable, so the
deletion is reversible. `git worktree prune` was not run. The count reads 35 at review because this
review filed one row and two builders' claim leases lapsed back into the ready pool — the pool is a
live shared commons and the row says so rather than freezing a number.

**WHAT THE NEXT WAVE TAKES.** Round 1 of the deferred set, in dependency order: `tgw9-s1` (the three
independent ledger-commons reds — everything downstream is blocked on it), then
`tgw6-bl-grip-suite-has-no-ci` the moment S1 is green, then `tgw5-bl-level-mention-promotion` and
`tgw9-s3`. Plus the two rows this review produced: the `screenCommand` global-option hole and the 44
lost park reasons. **The epic still does not seal, for the same reason it did not seal in wave 9 —
the predicate does not hold — and now also because the predicate is still prose.**

### Wave 2026-07-28 — wave 11, THE REFIRE: the four unbuilt briefs, rebuilt from a measured main. In flight.

Paper `truth-grip-wave-11-2026-07-28`. Parent `truth-grip-epic`. Measured at origin/main `a9638ecef`
(`tooling/grip` bytes unchanged at `5ccd9ad0a`; main moved FOUR times during the wave — every digit
below is stamped, and a builder re-derives at its own head).

**THIS WAVE DOES NOT RE-CUT ANYTHING.** Wave 10's briefs were good; they were lost to a dispatch
hole, not to a design fault. All four are claimed and built as written, each carrying a dated
AMENDMENT block that overrides where it conflicts. No re-survey, no re-file. FABLE IS UNAVAILABLE, so
every slice dispatches at opus@medium — `tgw9-s1` and `tgw9-s3` would otherwise have been fable on
the difficulty axis, and their briefs carry the extra pre-derivation that buys back.

| # | slice | task | round | size | model | surface |
|---|---|---|---|---|---|---|
| 1 | the grip commons folds honest — two nested reds, one independent | `tgw9-s1-ledger-commons-honest` | 1 | large | opus | tooling/grip ledger+mint+binding |
| 2 | a local grep of a doc stops deriving L1 | `tgw5-bl-level-mention-promotion` | 1 | medium | opus | tooling/grip/level.mjs |
| 3 | the seal becomes a COMMAND that says NO | `tgw9-s3-criteria-adjudicated` | 1 | large | opus | tooling/grip/seal.mjs (new) |
| 4 | criterion 2b keeps its frozen fixture | `tgw2-acceptance-suite` | 1 | large | opus | tooling/grip acceptance+cli |

All four are ROUND 1 and file-disjoint. `tgw9-s1` gates `tgw6-bl-grip-suite-has-no-ci` (out of scope,
D128); it does NOT gate its three siblings — the one behaviour the file fence hides, `deriveLevel`
feeding the fold's `level_restated`, was measured at **0 of 631 rows**, so no serialising is needed.

**HIGH-FLIP-RISK, and an independent second reviewer is owed before merge:** `tgw9-s3`'s NAMESPACE
LENS and its (b′) enforcement. A wrong lens or a vacuous (b′) produces a confident, clean-looking
FALSE SEAL — precisely what this epic exists to refuse, and the one failure mode a green gate cannot
catch. `tgw5` is the second flag: it is a security item, and under SR-1 no CI check can block a merge.

**THE SEAL IS NOT ATTEMPTED.** D94's predicate does not hold, and D94(c) plus this wave's own rule
(D122) forbid the word SEALED before it does. Success is four slices built, gated and merged, with
the seal DERIVABLE BY COMMAND and printing NOT YET.

**Filed to the backlog this wave, all published under the epic:**
`tgw11-bl-mint-path-root-relativity` (P1 — the 27 `path→path` drift rows are mint decaying, not mint
improving), `tgw11-bl-cli-selftest-pipe-truncation` (P1 — a grip entrypoint launders its own verdict
away at exit 0, on the exact command D116 mandates tgw2's gate grow),
`tgw11-bl-screen-classifysafety-global-option-launder` (P1, SR-1 — `classifySafety` admits SEVEN of
nine separated-value git globals, so on that shape class D88's defence-in-depth is ZERO layers, not
one; widens the open `tgw4-screen-git-global-option-audit`, does not duplicate it),
`tgw11-bl-unwrapped-recipe-rows-unread` (P2 — two recipe-shaped ledger files the fold has never read).

**Coverage was complete.** 17 survey reports and 11 verify reports, zero deficit in either round.
Nothing in this wave's cut rests on an unanswered question. The corners the survey named and verify
closed are recorded in D121-D129; the ones still open are the "53 minutes" mechanism (D125) and
whether `GRIP_LIVE=1` inverts D113's skip canary — neither is load-bearing for any slice here.

### Wave 2026-07-28 — wave 11 REVIEW: all four refire slices built, fixed and merged-ready. Grade A−.

Paper `truth-grip-wave-11-2026-07-28`. Parent `truth-grip-epic`. The refire worked: the four briefs
wave 10 wrote and lost to a dispatch hole were claimed and built as written, no re-cut, no re-survey.
**Four of four green.** Every branch is PUSHED and has a PR — the six-wave streak of stranded local
branches is broken.

| Slice | Final branch | PR | What |
|---|---|---|---|
| `tgw9-s1-ledger-commons-honest` | `…the-grip-commons-folds-honest-two-nested-0-r` | #6505 | Write-path ATTESTATION (`isAttestedRun`: the filename reproduces the digest of the file's own bytes), NOT-A-RUN split from MALFORMED-RUN, `foldLedger(scope)`, directional level restatements. Three standing reds green without softening. |
| `tgw5-bl-level-mention-promotion` | `…a-purely-local-grep-of-a-document-stops--1-r` | #6506 | The security item. A local grep quoting `ssh`/`gh api`/`git show origin/` no longer derives L1/L2. Reviewer fixed three false demotions the builder's own evidence missed. |
| `tgw9-s3-criteria-adjudicated` | `…the-seal-becomes-a-command-that-ships-sa-2-r` | #6507 | `tooling/grip/seal.mjs` — D94-as-amended, mechanical, four clauses named, live `rc=1`, SEALED nowhere. |
| `tgw2-acceptance-suite` | `…criterion-2b-keeps-its-frozen-fixture-th-3-r` | #6508 | Criterion 2b's buildable half after five waves of declining it: the frozen `screenCommand` table, the REACHABLE-WRONG-ROUTE plant, the automated exit-3 mutations. Needed no reviewer fix. |

**INTEGRATION PROVEN, NOT ASSUMED.** All four `-r` branches merged into one scratch branch off
`origin/main`: **686 tests / 685 pass / 0 fail / 1 skipped over 18 files**, against a `644/640/3/1`
baseline. D113's `# skipped 1` clause holds.

**THE FINDING THAT JUSTIFIED THE REVIEW: two file-disjoint slices were semantically coupled, and the
pair would have reddened main whichever merged second.** `seal.test.mjs` pinned
`deriveLevel(CHARTER_GREP_SPECIMEN) === "L2"`; `tgw5` closes exactly that promotion, so the same
command re-derives L3 once it lands. The file-truth collision check cannot see this class — the two
slices share no file. **The lesson is a rule: a slice that PINS a value another slice's brief says it
will CHANGE is collided even when their file sets are disjoint. Dispatch must collide on asserted
VALUES, not only on paths.** Fixed by asserting the property that holds in both worlds (the PATH rule
refuses a charter grep whatever the level grammar says) — which is what defence in depth means.

**Other defects the review found and fixed in place:**

1. **Three false demotions in the security slice** (`tgw5`). Reading the blessed tokens off the
   quote-mask for EVERY head demoted `ssh "root@host" uptime` L1→L6, `git show 'origin/main:…'`
   L2→L3 and `timeout 30 ssh "root@h"` L1→L6. Quoting a HOST or a REF is quoting an argument. The
   builder's criterion-3 evidence said "8/8 HOLD rows identical" — true of the rows it walked, false
   of the criterion it claimed, because the HOLD table never contained a quoted destination. Rule is
   now head-keyed: a segment headed by the command ITSELF reads its raw bytes.
2. **A near-vacuous assertion in the D89 control** (`tgw9-s1`). `level_restated_down === 0` reads
   like a live launder detector and is not one: the fold runs `admitRecipe` before the restatement
   counter, and a DOWN-shaped row IS the LEVEL-SKIP shape, so it is rejected and can never reach the
   counter. Now executed both halves against one synthetic run, with the D89 control saying out loud
   which assertion actually fires on a forged store.
3. **Clause (c) misreported a non-closed root** (`tgw9-s3`). It read "closes LAST" as CLAIMABLE, so
   an `in_progress` root printed "the root is already closed" — a false statement in the program
   whose whole job is refusing false statements. Now reads the two genuinely closed statuses.

**HIGH-FLIP-RISK, re-derived independently and CLEARED — with one thing still owed.** The reviewer
re-derived `tgw9-s3`'s namespace lens by a different method: 153 recursive **server-side**
`filter[parent_id]` queries rather than a client-side closure over a walked corpus. Closure 152 /
prefix 150 / union 152 / claimable 34 / root-in-pool true — identical, and it covers depth 2+, the
hole the builder named in his own depth-1 reconciliation. **Still owed to a human:** both derivations
fence to `_type == "task"`, so a `tgw*`-named row of another type carrying a `lifecycle_status` is
invisible to both. That is one shared assumption, and one reviewer cannot break it.

**Ledger fixes.** `tgw5`'s claim lease had lapsed, so the board read a built-and-unmerged slice as
`open` — re-claimed, `in_progress`, now-line rewritten. Criterion 3 carries a review-correction
`--miss` note recording that its stamped evidence overstated. The other three tasks were honest:
in_progress, merge-gated criteria left open for the lead, no task outside the wave touched.
`tgw6-bl-grip-suite-has-no-ci` is untouched at 0/11, as D128 requires.

**GUERRILLA'S DOC-CREATE IS DOWN, AND ONE ROW IS THEREFORE UNFILED.** `/v1/data/mutate` doc-CREATE
returned 500/timeout on every attempt during the review (request ids `GMZYbJhOxSPzcsMACkxR`,
`GMZYdmeCBah-FP4ACz6y`); reads, claims, pulses and stamps all worked. Same fault `tgw9-s1`'s builder
hit. The residual it would have filed — an UNQUOTED mention under a NON-reader head (`echo ssh
root@h` still derives L1; zero of 631 committed rows have the shape) — is PINNED BY ASSERTION in
`level.test.mjs` and cites no task id, because citing a task that does not exist is the dangling
pointer this epic refuses. **File it when the server recovers.**

**WHAT THE NEXT WAVE TAKES.** Merge round 1 in any order (integration is proven green in all four
together; there is no merge-order constraint left). Then, as their deps land:
`tgw6-bl-grip-suite-has-no-ci` the moment `tgw9-s1` is on main AND the Honest Gates branch-protection
run has settled — it is the last thing standing between this suite and a gate that can actually
fail. Then `tgw9-s3`'s criterion 10 (stamping the root's four criteria) inside a lead close-window,
and `tgw4-absence-veto-stops-at-the-rerun-seam`, which `seal.mjs` now cites by file:line rather than
works around. **The epic still does not seal — but for the first time the reason is DERIVABLE BY
COMMAND: `node tooling/grip/seal.mjs` exits 1 and prints `a=FAIL b=FAIL b'=PASS c=PASS blocking=34`.
The predicate stopped being prose.**

### Wave 2026-08-18 — wave 12, RECONCILE-AND-VERIFY + earned builds. Parent `truth-grip-epic`. Paper `truth-grip-wave-12-2026-08-18`. In flight.

Three weeks after the last ledger touch, the survey RECONCILED current truth first. The wish's
stale-open premise was refuted against live L1 (D130): 136 children partition 53 done / 40 considering
/ 34 open / 9 cancelled — no batch to close. The grip HOLDS (D131): only `provenance.mjs` moved
post-wave-11 (#11535, a tightening), and all six guards red under a reverting mutation on current
`origin/main`. Seal exits 2 INFRA-FAULT on a server-side ready-pool ghost row, not a grip defect;
deduped it reads `HOLDS=FALSE blocking=35`, an honest NOT-YET.

The verify floor CLEARED genuine, in-fence, mutation-proven holes above the bar, so this is
convergence AND earned builds, not a vacuous convergence:

| Slice | Round | Model | Surface | What |
|---|---|---|---|---|
| `tgw12-s0-inloop-anchor-repin` | 1 | opus | tooling/grip/test | re-pin inloop-gate 255/256 to the #6688 wording by pattern; restore full-suite green (D135a) |
| `tgw12-s1-screen-value-global-collision` | 1 | fable | tooling/grip | CROWN: `screenCommand` value-taking-globals normaliser — close git+go+npm on the LIVE census gate (D132). HIGH-FLIP-RISK: security guard |
| `tgw12-s2-bp-local-overpromotion` | 1 | opus | tooling/grip | `tgw3`: demote URL-free local `bp scaffy` verbs L2→L3; remote verbs untouched (D133). HIGH-FLIP-RISK: reachability scope |
| `tgw12-s3-foldledger-injection-gap` | 1 | opus | tooling/grip | inject `now`+`screenCommand` into census/backfill `foldLedger` callers so FUTURE-OBSERVED-AT / REFUSED-COMMAND fire on read (D134) |
| `tgw12-s4-record-baddeps-test` | 1 | opus | tooling/grip/test | direct fail-before-plant `record.test.mjs` for the untested BAD-DEPS admitFact rejection class (D135b) |

All five are round 1, file-disjoint (screen.mjs / level.mjs / {census,backfill}.mjs /
test/inloop-gate.test.mjs / new test/record.test.mjs), inside the `tooling/grip/` fence — clear of the
live Deploy-reliability (deploy/+scripts/) and Felix (api/) fences. Merge-gated live/prod proofs and
the `tgw9-s3`/root close-window stamps are left for the lead. The two evidence-closeable reconcile
rows (`tgw9-bl-close-superseded-pr-5754`, `tgw6-bl-primary-checkout-staged-grip-fork`) are the lead's
close-by-evidence, not build slices.

- **D136 — WAVE 13 IS INDEPENDENT VERIFY-AND-LAND: the four wave-12 builds were re-derived from
  source, not inherited, and #12180 (the crown) is APPROVED and MERGED.** Five verifiers flew — one
  per PR plus a merged-interaction proof — each running a NEW adversarial matrix rather than echoing
  wave-12's self-review. #12180's `dropValueGlobals` closes the value-taking-global collision
  FAIL-CLOSED: the full collision matrix on PR head refused every exploit shape (`git -C`/`-c`/
  `--git-dir`/`--git-dir=value`/double-global `log push`, `go -C env run main.go`,
  `npm --prefix ls install`) and admitted every safe recipe (`git -C /path log`,
  `git -c core.pager=cat log`, `git status`, `go test ./...`, `npm ls`), with post-verb writes still
  caught (`git branch -C/-m old new` REFUSED) and no new unsafe recipe introduced. Mutation-proven:
  neutering `dropValueGlobals` to identity re-admits all three exploits and reds `screen.test.mjs`
  (61→56); restore → 61/0. On current `origin/main` after the merge (870fcbb7bb):
  `adjudicate.test.mjs` 37/37 and `screen.test.mjs` 58/58 GREEN — V5's stale-base prediction of an
  adjudicate red was an artifact of a 5888-commit-behind branch base, NOT a real defect; GitHub's
  3-way merge landed clean. *Why: distrust a check most when it confirms — wave 12's own Review
  graded all five A and wrote "an independent second security review is still owed on #12180 before
  merge." That review IS wave 13, and it holds.*

- **D137 — #12180's NAMED RESIDUAL is the npm config value-global long-tail, PRE-EXISTING and
  NON-REGRESSING; APPROVE stands.** `NPM_VALUE_GLOBALS` enumerates 7 of ~150 npm config keys, so
  `npm --registry/--tag/--otp/--node-options ls install` still admit as masked writes — byte-identical
  `ok:true` on `origin/main` pre-fix and post-fix, so #12180 strictly improves and loosens nothing.
  The `NPM_VALUE_GLOBALS` comment scopes itself to "the config paths/names that also eat a value" and
  never claims npm-completeness, so the over-claim trap that would flip APPROVE→REQUEST-CHANGES is
  absent. Owner: `task-8b3de757996336f9` (pnpm/docker `verbRule` twin, OPEN), whose scope broadens to
  cover the npm long-tail. NOT built this wave. *Why: fail-closed means "no NEW hole opened"; a
  partial-but-honest closure of a class the PR never claimed to finish clears the bar.*

- **D138 — #12182 (foldLedger read-path inject) is APPROVED and merges AFTER #12180.** The injection
  is strictly ADDITIVE: `admitRecipe` checks VALUE-STORED input-free (fires with or without bounds)
  and gates FUTURE-OBSERVED-AT on `hasNow` / REFUSED-COMMAND on `hasScreen`, so passing
  `{now, screen}` can only ADD rejection classes, never disable one — no bypass, and a forged/
  level-skipped row still rejects. `shellNow` in census.mjs and backfill.mjs is byte-identical to the
  write-path `ledger.mjs:shellNow`. Mutation-proven: reverting BOTH injections to bare
  `foldLedger(dir)` reds exactly the two product-path tests while the CONTROL (un-bounded fold folds
  forgeries clean) stays green — 3/3 → pass 1/fail 2 → restore 3/3. Merge after #12180 so the census
  read path inherits the tightened `screenCommand` and the census denominator shifts once (EXPECTED,
  not a regression).

- **D139 — #12183 (BAD-DEPS fail-before test) is APPROVED.** A single new `record.test.mjs`; the
  guard already lives on `origin/main` (record.mjs:54), so the PR is purely additive coverage and
  cannot loosen the grip. Mutation-proven: neutering the guard to `if(false)` reds exactly the 3
  negative cases (string/numeric/object deps) and leaves the 3 positives green (array, empty-array,
  undefined→stored `[]`) — the nil-stays-green trap is guarded in both directions — and the full-suite
  fail-count delta is EXACTLY 3, all inside record.test.mjs, confirming BAD-DEPS was the one
  admitFact class with zero prior coverage.

- **D140 — #12181 (bp scaffy L2→L3 demotion) earns REQUEST-CHANGES on a fail-closed OVER-REFUSAL;
  the CORE fix is airtight.** Independently re-derived: the tgw3 level-skip is real (5 pure-local
  verbs derive L2 with `checkCeiling` ok:true on main), the fix closes it (→L3 LEVEL-SKIP), the
  local/remote boundary holds (pull / `ls --remote` / URL-bearing stay L2, loopback L3), `remove` is
  confirmed pure-local (the 5-verb superset over D133's 4 is correct), mutation reds tests 63/64/66 +
  corpus snapshot 74, and the frozen 651-command corpus moves exactly ONE correct row. BUT
  `isLocalScaffyInvocation` uses `tokens.indexOf("scaffy")` (level.mjs:343) — first occurrence
  ANYWHERE — so a remote read carrying `scaffy` as an argument before a local-verb word over-demotes:
  `bp task get scaffy validate x.scaffy` → L3 (should be L2). It fails CLOSED (stricter, zero corpus
  occurrences), but test 65 titles the demotion "SUBCOMMAND-scoped" while the implementation is
  indexOf-scoped — an unverified over-claim on the grip's own provenance grader. Per the wave's
  fail-closed rule (over-refusal OR over-claiming test → REQUEST-CHANGES), this blocks. REMEDY (one
  line, byte-disjoint): anchor `scaffy` to the subcommand position (require `bp` then adjacent
  `scaffy` before the LOCAL_SCAFFY_VERBS check) and add
  `assert.equal(deriveLevel("bp task get scaffy validate x.scaffy"), "L2")` to test 65. Filed as
  `tgw13-s1`; the tgw12-s2 builder amends PR #12181. *Why: uncertainty on the grip's own executor/
  grader is a block, and a test whose title asserts what its body does not verify is exactly the
  vacuity this epic refuses.*

- **D141 — CURRENT MAIN CARRIES 2 PRE-EXISTING GRIP REDS INDEPENDENT OF WAVE 13:
  `inloop-gate.test.mjs` tests 22/23 red on `origin/main` from renewed workflow-wording drift.**
  D135(a)'s #12179 re-pin held at merge time, but `bp-epic-cycle.workflow.js` reworded the Decide
  ledger-commit prose again, so the literal-string anchors miss once more while the guarded discipline
  is intact. #12180 (screen.mjs only) did not cause them; measured on 870fcbb7bb they were red before
  it. The grip suite is not CI-gated so no merge is blocked, but every builder running the full suite
  sees 2 reds on a clean tree. The durable fix is a WORDING-TOLERANT pattern (assert the discipline's
  shape, not one PR's phrasing) so it stops drifting each month, filed as `tgw13-s2`. MERGE ORDER:
  #12180 (DONE) → #12182 → #12183 (any order after #12182); #12181 HELD for its anchor remedy.

### Wave 2026-08-18 — wave 13, INDEPENDENT VERIFY-AND-LAND. Parent `truth-grip-epic`. Paper `truth-grip-wave-13-2026-08-18`.

No new construction: file edits under `tooling/grip/` were FORBIDDEN (they would conflict with the
four PRs under review). Five verifiers re-derived the four wave-12 builds from source on current
`origin/main` + `gh pr diff`, ran NEW adversarial matrices, mutation-proved each test in a throwaway
worktree, and posted APPROVE/REQUEST-CHANGES as `gh pr` comments.

| PR | Slice | Verdict | Merge |
|---|---|---|---|
| #12180 | tgw12-s1 screen value-global collision | APPROVE (+named npm residual) | MERGED 870fcbb7bb |
| #12182 | tgw12-s3 foldLedger read-path inject | APPROVE | after #12180 |
| #12183 | tgw12-s4 BAD-DEPS fail-before test | APPROVE | after #12182, any order |
| #12181 | tgw12-s2 bp scaffy L2→L3 demotion | REQUEST-CHANGES (indexOf over-refusal) | HELD for tgw13-s1 |

Two round-2 follow-up slices, dispatched by the lead after this wave (both `tooling/grip`, forbidden
this wave):

| # | Slice | Round | Model | Surface | What |
|---|---|---|---|---|---|
| 1 | `tgw13-s1-scaffy-subcommand-anchor` | 2 | opus | tooling/grip | anchor `scaffy` to the subcommand position + assert the L2 remote-read case; amends PR #12181 (D140). HIGH-FLIP-RISK: reachability scope |
| 2 | `tgw13-s2-inloop-gate-wording-tolerant` | 2 | opus | tooling/grip/test | re-pin inloop-gate 22/23 by WORDING-TOLERANT pattern so it stops drifting (D141) |

Backlog, named-not-built: `task-8b3de757996336f9` (pnpm/docker `verbRule` twin, broadened to the npm
config long-tail — D137); `tgw4-absence-veto-stops-at-the-rerun-seam` (fail-closed refused-command
read-contract gap). Both OPEN, pre-existing children.

- **D142 — THE DONE SET IS TRUE: FALSE-DONE COUNT = 0 over the full 62-row done universe; zero
  reopens warranted, none manufactured.** An independent GR112-style false-done audit re-derived the
  live denominator (Postgres, not `child_count` 147), pinned against `origin/main` and ran two
  100%-coverage mechanical sweeps plus a stratified judgment layer over every done row. **The true
  done universe is 62, not 54:** the flat `parent_id == truth-grip-epic` filter drops 16 grandchildren
  parented to `tgw1-workflow-gate-wiring` (itself done), of which **8 are done and are the
  highest-stakes wave-2 grip-engine rows** (`tgw2-adjudicator`, `-grip-quote-safety`,
  `-fold-reread-derived-level`, `-inloop-gate`, `-recipe-ledger`, `-l4-artifact-census`,
  `-decide-survey-projection`, `-wild-bulk-fanout-floor`). Both sweeps had originally run against the
  flat 54 and were re-run against the 8 to close the gap. `seal.mjs`'s own header (:50-52) already
  documents this 16-row drop — the denominator correction is baked into the code under audit. SWEEP A
  (SHA-ancestry via `git rev-list --count origin/main..<sha> | grep -qx 0`, never the `is-ancestor`
  form the grip's own `screenCommand` refuses as a write shape): every cited PR merge commit resolves
  to an ancestor of `origin/main`; non-ancestor branch-tip SHAs were squash-resolved before any verdict
  (superseded-landed, TRUE — no manufactured reopen). SWEEP B (close-provenance from `doc.claim`, not
  `bp task events` which carry no actor): provenance recovered for 61/62; the one null-claim row
  (`tgw5-prescreen-verb`, carrying the `Historical completion reconciled` seal string) is EXCUSED —
  its cited verb re-derives `ADMIT[0]/REFUSE[1]/exit 1/no-mutation` when RUN on `origin/main`. The seal
  string appears in 7 rows, all with full N/N criteria and real file:line evidence — benign, not the
  Felix fabrication shape. The content-close dependency graph is a clean DAG (no cycles). Reverse
  direction measured: 0 shipped-but-open and 0 shipped-but-cancelled mislabels. *Why: a grip/guard fix
  marked done but not landed would be the highest-stakes false-done — the correctness guard with a hole
  nobody knows about. The audit proves that did not happen anywhere in the done set.*

- **D143 — GUARD MUTATION IS THE TRUTH AUTHORITY, and the six highest-stakes guards are LIVE
  (red-when-reverted), not dead lines present on main.** The vacuity defense holds: because the grip
  suite is not CI-gated, guard-exists + test-reds-on-revert IS the L1 truth for a guard-fix row. Six
  targeted mutation-reverts, each restored to green: `screen.mjs` `git --output` refusal (5 reds) and
  the `go coverprofile` write-flag (5 reds); `rerun.mjs` `classifySafety` quote-blanking (2 reds);
  `seal.mjs` `adjudicateCriterion` polarity/verdict veto (2 reds); `level.mjs` `deriveLevel`
  compound-walk (2 reds) and the `GENERATED_ARTIFACT_PATTERNS` `_gen.go` L4 census entry (1 red). The
  cited capabilities are present on `origin/main` (line-drifted from the closes, grep-verified — the
  tree is ~187 commits past). *Why: Sweep A proves code LANDED, not that it DOES what the criterion
  claims; mutation closes that gap for the rows where it matters most.*

- **D144 — FINDING (NOT a false-done): the grip suite is 1-red on `origin/main` —
  `adjudicate.test.mjs:418` (the D88 caller-boundary test) pins a since-corrected over-refusal.** The
  test asserts `screenCommand("git -C tooling/grip show HEAD:README.md")` is REFUSED, but the tgw4
  value-global fix (`GIT_VALUE_GLOBALS`/`dropValueGlobals`, `screen.mjs:437/444`) since taught the
  parser that `-C <dir>` is a value-taking global, so that safe read is now correctly ADMITTED. The
  guard got STRICTER-correct (still refuses `git merge-base --is-ancestor` and every write verb); it
  merely stopped over-refusing one safe read, and the co-scoped test was never updated. This is a
  test-hygiene defect, not a guard hole, so NO row was reopened. It is invisible because the suite is
  not CI-gated, and it is a concrete PREREQUISITE for `tgw6-bl-grip-suite-has-no-ci` (D104/D128 forbid
  advisory CI on a red main). Distinct from the D141 `inloop-gate` 22/23 reds. Filed as backlog
  `tgw-bl-adjudicate-d88-stale-pin` (OPEN). *Why: the epic exists to make an undetected level-skip
  impossible; an undetected red on main is exactly the shape it should surface.*

### Wave 2026-08-18 — DONE-SET FALSE-DONE AUDIT (verify-heavy, READ-ONLY). Parent `truth-grip-epic`. Paper `truth-grip-done-set-audit-2026-08-18`. Referent `truth-grip-epic-doneset-audit-log`.

No construction: the fence is a read-only ledger audit (`bp` + `git` reads on `origin/main`) plus
reopen-stage writes and this charter note. NO code edits — the guard-mutation cohort was proven by
revert-in-a-throwaway-worktree, never on main. Six verifiers ran both 100% sweeps over the full 62-row
done universe, mutation-proved the six highest-stakes guards, recovered close provenance, and measured
both directions.

| Lane | Coverage | Verdict |
|---|---|---|
| Sweep A — SHA-ancestry | 62/62 done rows, all cited PRs resolved | 0 genuinely-absent; every landing an ancestor |
| Sweep B — close provenance | 61/62 from `doc.claim`; 1 null-claim excused by re-derivation | 0 fabrication-shape matches |
| Guard mutation | 6 highest-stakes guards reverted | all LIVE (red-when-reverted) |
| Content-close DAG | 6 mass-close rows, transitive targets | clean DAG, no cycles, all targets done/present |
| Reverse mirror | open + cancelled cohorts sampled | 0 shipped-but-open, 0 shipped-but-cancelled |

**Whole-ledger trust verdict: the truth-grip done set is TRUE. False-done count = 0.**

Reopens issued this wave: NONE (none warranted, none manufactured). Backlog, named-not-built:
`tgw-bl-adjudicate-d88-stale-pin` (D144, the stale D88 test — blocks tgw6 grip-CI); the pre-existing
`tgw6-bl-grip-suite-has-no-ci` (OPEN, D128 — its OPEN status is legitimate and now has a concrete
prerequisite named). No build slices: the audit warrants zero reopens and the fence is read-only.

### Wave 2026-08-18 — WAVE 15: TWO HONEST LOOSE ENDS (verify-heavy FIX wave). Parent `truth-grip-epic`. Paper `truth-grip-wave-15-2026-08-18`. Referent `truth-grip-epic-wave-15-log`.

The done-set audit (D142, 62/62 true) left two offline-buildable, mutation-provable loose ends. Wave 15
fixes BOTH in one worktree-isolated fence (`tooling/grip/`), two separate PRs, no publish-floor trip.
Both fixes were IMPLEMENTED-AND-CERTIFIED in throwaway worktrees during verify; builders re-land them on
fresh branches from clean origin/main. Re-smoked live on `origin/main` f3c4b6b04: D88 red, inloop-gate
28/28 green, level.test 76/76 green, corpus {L1:32,L2:93,L3:380,L6:146}, no scaffy demotion on main.

- **D145 — WAVE 15 IS A TWO-TARGET FIX WAVE, byte-disjoint, two PRs, worktree-isolated.** FIX 2 (D88
  test split) lands first — trivial, greens the whole grip suite. FIX 1 (scaffy anchor) rides its own PR
  behind the hand-run matrix. Files disjoint (`adjudicate.test.mjs` vs `level.mjs` + `level.test.mjs`),
  no ordering dependency. All work in a worktree cut from CLEAN origin/main — the primary carries another
  session's uncommitted cloud-build wave-2b work and is never touched. *Why: separation frees the
  green-main/CI-prep unblock from FIX 1's risk review at zero cost.*

- **D146 — #12181 SHIPS BY CLOSE+FRESH, superseding D140's amend routing; the ratified verdict + remedy
  are preserved byte-for-byte.** D140's "the tgw12-s2 builder amends PR #12181" is a tactical filing
  sentence (PR-routing), NOT a fact-authority invariant — the ratified content is the REQUEST-CHANGES
  verdict + the anchor-and-assert remedy, satisfied by ANY PR that lands them. #12181's base is 28
  commits stale and its branch belongs to the tgw12-s2 builder (Heggemsnes: no uninvited push). Close
  #12181, cut fresh from clean origin/main, re-land the demotion + corrected anchor + ported tests.
  `tgw13-s1` criterion 4 re-worded from "amend #12181" to "the fresh corrected PR" so the row stays
  closeable. *Why: overriding a tactical routing clause preserves the invariant D140 protects; a
  criterion pinned to a superseded mechanism is the false-done shape this epic refuses.*

- **D147 — THE REMEDY IS NOT ONE LINE: the anchor must skip bp's value-taking globals per the arity
  authority `internal/cli/globals.go` `valueFlags`.** D140 wrote "one line, byte-disjoint" — it lacked
  the fact that a naive skip-set reintroduces the OPPOSITE over-refusal (fails to demote a genuine local
  verb, reopening tgw3). Correct anchor: the first non-flag / non-value token after `bp` must
  `=== "scaffy"`, consuming each value-global's value (13 keys: `-s/--server`, `--token`,
  `-w/--workspace`, `-p/--project`, `-d/--dataset`, `-o/--output`, `--limit`, `--offset`, `--manifest`),
  treating `--json` as BOOLEAN and inline `=` as self-contained only for long `--flag=value` (not short
  `-o=json`). Verify proved 16/16 both directions and both traps avoided. *Why: the arity partition is
  load-bearing in BOTH directions — only the exact valueFlags/boolFlags split is correct.*

- **D148 — THE CORPUS IS BLIND to the over-refusal class; the hand-run bidirectional matrix is the SOLE
  merge instrument (grip has no CI).** The class has ZERO corpus occurrences, so naive-indexOf and the
  correct anchor give a bit-identical corpus distribution — the frozen snapshot cannot tell the fix from
  the bug. The builder ports the two incidental-scaffy rows as durable guard tests in `level.test.mjs`
  and co-edits the corpus pin from `{L1:32,L2:93,L3:380,L6:146}` to `{L1:32,L2:92,L3:381,L6:146}` (one
  row moves: `bp scaffy run classify-block-type.scaffy …`). HIGH-FLIP-RISK: the level-classification
  (reachability) judgment — a genuinely independent reviewer re-runs the full matrix before merge. *Why:
  with no CI, the synthesized matrix is the only thing standing between the merge and a silent level-skip.*

- **D149 — FIX 2 IS THE SOLE remaining suite-green prerequisite for tgw6 grip-CI; D141's inloop-gate red
  has CLEARED.** D141 recorded `inloop-gate` 22/23 red at wave-13; #12179's literal re-pin (merged
  04:28Z) took it to 28/28 GREEN on current main (re-run f3c4b6b04). `adjudicate.test.mjs` D88 (FIX 2)
  is now the ONLY grip-suite red. FIX 2 splits the D88 loop — admit the `git -C … show` read (tgw4
  correctly admits it), keep refusing `git merge-base` (broad `\bmerge\b` write regex, pinned as
  intended-for-now; the merge-base over-refusal + `git grep -ln` false-refusal are filed for a later wave
  as `pds-bl-grip-screen-refuses-honest-read-commands`, which truth-grip should ADOPT via `bp task stage`
  since the epic owns `screen.mjs`) — greening the whole suite (708/707/1-skip). `tgw9-s1` (tgw6's other
  dep) is done, so once FIX 2 merges tgw6 can proceed. `tgw13-s2` (wording-tolerant inloop-gate) remains
  worthwhile anti-drift but is NOT a live red and NOT blocking. *Why: an undetected red on main is
  exactly the shape this epic surfaces; naming the SINGLE blocker keeps the tgw6 unblock claim honest.*

Wave roster (both round 1, dependency-free, opus — Fable capped until Aug 21):

| PR | Slice | Task | Files | Gate |
|---|---|---|---|---|
| FIX 2 (first) | D88 adjudicate split | `tgw-bl-adjudicate-d88-stale-pin` | `tooling/grip/test/adjudicate.test.mjs` | `node --test tooling/grip/test/*.test.mjs` from repo root — expect 708/707/1-skip |
| FIX 1 | scaffy subcommand anchor (close+fresh #12181) | `tgw13-s1-scaffy-subcommand-anchor` | `tooling/grip/level.mjs`, `tooling/grip/test/level.test.mjs` | `node --test tooling/grip/test/level.test.mjs` + hand-run 16-row bidirectional matrix |

Merge-gated closes LEFT FOR THE LEAD (D40 content-on-main; re-claim lapsed epochs first): `tgw12-s0`
idx 3 (READY NOW — #12179 merged + inloop-gate 28/28 green); `tgw12-s2` idx 5 + `tgw13-s1` idx 4 (after
FIX 1's fresh PR merges + #12181 closed); `tgw-bl-adjudicate-d88-stale-pin` idx 2 (after FIX 2 merges).

### Wave 2026-08-18 — WAVE 15 REVIEW: both loose ends corrected, mutation-re-proven, grip suite green on the combined merge. Grade A.

Both slices landed exactly as briefed; the reviewer independently re-derived the HIGH-FLIP reachability
judgment and re-ran every mutation probe on this worktree rather than trusting the builder's numbers.

- **FIX 2 — `tgw-bl-adjudicate-d88-stale-pin`, final branch `loop-epic/fix-2-d88-adjudicate-boundary-test-split-0-r`.** Only `adjudicate.test.mjs` changed; `screen.mjs` byte-identical to origin/main. The single over-refusal loop is split into a READ half (`git -C tooling/grip show …` now `screenCommand().ok===true` and verdict `!== REJECTED`) and a WRITE half (`git merge-base --is-ancestor` still `.ok===false`, verdict `=== REJECTED`). Reviewer-run mutation: reverting `dropValueGlobals`→`rawArgv` in the git rule reds ONLY the READ half; dropping `merge` from the write-verb regex reds ONLY the WRITE half — each half pins a distinct real behavior, not a tautology. `node --test tooling/grip/test/adjudicate.test.mjs` → 37/37.

- **FIX 1 — `tgw13-s1-scaffy-subcommand-anchor`, final branch `loop-epic/fix-1-scaffy-subcommand-anchor-close-fre-1-r`.** Re-lands the whole tgw3 demotion on top of a clean origin/main (which carried NO scaffy carve-out), with `isLocalScaffyInvocation` anchored to the subcommand position: `bp` via `headToken`, walk the remainder skipping each value-taking global WITH its value (13-key mirror of `globals.go` `valueFlags`), treat `--json`/inline-long as self-contained, and require the first non-flag token `=== "scaffy"`. Reviewer re-ran the full deriveLevel+checkCeiling matrix and the arity traps: all five URL-free local verbs derive L3 and refuse an L2 claim; remote (`pull`, `ls --remote`, any `-s https://…`) stay L2; loopback stays L3; both incidental-scaffy remote reads (`bp task get scaffy validate x.scaffy`, `bp search query scaffy validate`) stay L2 with checkCeiling admitting the L2 claim — the over-refusal is GONE. Mutation: reverting the anchor to `rest.indexOf("scaffy")` reds exactly ONE test (79/80). `node --test tooling/grip/test/level.test.mjs` → 80/80. Corpus pin moved one row `{…L2:93,L3:380…}`→`{…L2:92,L3:381…}` as designed.

- **Combined merge (both -r branches, disjoint files):** `node --test tooling/grip/test/*.test.mjs` from repo root → 712 tests / 711 pass / 0 fail / 1 skip. The D88 red that FIX 1 alone leaves standing is closed by FIX 2 — together they deliver the wish's "grip suite green on main," the prerequisite tgw6 grip-CI (D149) was waiting on.

- **Ledger:** both slice tasks left honestly `in_progress` with non-merge-gated criteria stamped and evidence bearing; merge-gated rows (`tgw13-s1` idx 4, `tgw-bl-adjudicate-d88-stale-pin` idx 2) left open for the lead. No ledger lies found; no fixes needed. No tasks outside the wave were touched.

- **HIGH-FLIP handoff:** FIX 1's level-classification is a reachability/security judgment. The single wave-reviewer independently re-derived it and it holds — but a genuinely independent second reviewer re-running the matrix before merge is still warranted, per the flip-risk protocol.

- **Next wave:** merge FIX 2 first (greens the suite), then FIX 1's fresh PR (the lead closes #12181 and cuts it — the branch belongs to the tgw12-s2 builder). Then the lead closes the merge-gated criteria named above. With the suite green on main, tgw6 grip-CI (D128) is unblocked — its remaining dep `tgw9-s1` is done. The merge-base over-refusal and `git grep -ln` false-refusal remain filed as `pds-bl-grip-screen-refuses-honest-read-commands` for truth-grip to adopt.
