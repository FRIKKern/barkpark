# CI Gate-Script Integrity Audit — epic charter

Epic task: `ci-gate-script-integrity-audit` · Wave 1 Paper: `/papers/ci-gate-script-integrity-wave-2026-08-18` ("The Third Ring")

## Vision

Barkpark's guard estate has already proven its famous instruments can fail. `required-checks.test.sh` is 3,437 lines of disarm-and-watch; `pr-task-gate.test.sh` is 123 assertions that red on a one-token case widening; the three path-escape ratchets each carry a `--selftest` that observes its own guard being neutered. What the repo has never proven is that the **quiet** guards can fail — the workflow-wired scripts with neither a `.test.sh` nor a `--selftest`, the ones nothing has ever watched turning red.

This epic audits that third ring, mutation-first. For each guard: derive its CLAIMED catch-set from its header prose, the doctrine it enforces and the scar that created it — never from reading its own regex, which is circular — then PLANT that violation in a temp copy, RUN the guard, and record what happened. A red is a SAFE verdict newly earned and cited with the planted input. A green is the finding the epic exists to catch.

And the deliverable is a **tripwire, not a verdict list**. A verdict is a snapshot of a moving tree; the same evidence spent as a wired `--selftest` re-earns itself on every CI run and costs the same to produce. Where a hermetic selftest is genuinely infeasible, the epic files an honest unproven verdict with the reason rather than shipping a harness that only proves the script parses.

Zero findings is a publishable result. Manufacturing a finding is the one failure mode worse than finding none.

## Decisions

**D1 — The blocking ring is CLEAN; do not spend slices there.** Live branch protection requires exactly four contexts (Elixir gate, PR references an active task, Cloud gate, Console gate; `enforce_admins=true`). Verification drove `pr-task-gate.sh` through 10 planted fixtures on an independent stub ledger — every claimed violation reds with the correct message, both controls pass, and the lapsed-lease predicate is genuinely time-ordered. All three required aggregators' `decide()` bodies were replayed 22 times under `env -i` and are fail-closed on failure / cancelled / empty / unrecognised / skipped-with-a-live-gate. All four blocking workflows are workflow-level unfiltered, so the paths-filtered vacuity cannot reach them. *Why: the most merge-authoritative surface in the repo is the best-defended one; auditing it re-buys evidence the repo already owns.*

**D2 — doc-gates is ADVISORY, and the epic hardens it anyway, saying so out loud.** `Doc budgets + anchors` is held out of the required set by an explicit S4 PATHS-FILTERED exclusion — a paths-filtered workflow is ABSENT on non-matching PRs, and a required absent context never reports. So ~21 guards labelled "(blocking)" inside that job, `tenant-scope-check.sh` included, cannot stop a merge. *Why: an honest guard that cannot block is still worth more than a vacuous one that could; but every slice states the limit rather than letting the wave's own Paper imply merge authority it does not have.*

**D3 — Promotion of doc-gates to a required context is FILED, never built.** S4 is a test on one literal YAML key (`on: pull_request: paths:`), proven by four variants of the real generator: remove the key and the same job name is KEPT and emitted into branch protection; a push-level filter is invisible to it; `paths-ignore` is caught by the same rule. So promotion is mechanically possible. But registering the name is an ADMIN WRITE to live branch protection (`required-checks-apply.sh` refuses without `--confirm`, the floor refuses growth without `--acknowledge-growth`), and doc-gates' `cancel-in-progress` on PR refs would ship a self-inflicted merge stall. *Why: a branch-protection write is categorically outside a scripts/ fence and deserves a human gate — and promotion must FOLLOW the tripwire work, never precede it.*

**D4 — Three of the direction's load-bearing premises were REFUTED; the plan followed the evidence.** `required-checks-generate.sh` is NOT unharnessed — `required-checks.test.sh` drives it 28 times hermetically with seven guard-disarm mutations, so the briefed priority-2 slice is dead. `required-checks.test.sh --hermetic` PASSES today (177/0) and has zero failures in 60 main runs at both run and job level, so the bedrock is genuinely green. "122 scripts" is `scripts/*.sh` top-level only; the real recursive inventory is 167, and `scripts/connectors/` holds six dark guards the census missed. *Why: a wave that builds on a refuted premise ships confident work on a hole.*

**D5 — Fix the one LIVE RED inside the fence first.** `crown-reconcile.test.sh` fails on a PROSE COMMENT in `shell-harnesses.yml` — a textbook over-broad-pattern FALSE RED, violating the "MENTION IS NOT EXECUTION" doctrine written twenty lines above the comment it matches. Because the harness is the FIRST step of the product job, the crown-vs-production reconciler has been dark since 2026-08-17 08:30Z while the failure notifier fires every ~6h naming the wrong defect. *Why: the epic's own rule is that the fix direction is always toward MORE able-to-fail — so tighten the predicate, never delete the documentation the FAIL text tempts you into deleting.*

**D6 — ARG DISPATCH IS A PREREQUISITE, not a nicety.** Twenty workflow-wired guards exit 0 on an unknown flag with output byte-identical to a bare run; eleven of them already have a CI-wired `--selftest`, so the hazard is live today, one typo away. `status-manifest-check.sh` is the proof shape: `MODE="${1:-check}"` makes `--selftest` the default check mode. A `--selftest` wired onto a swallowing guard runs the ordinary check twice and reports green forever. *Why: wiring a tripwire without dispatch FABRICATES the proof — the exact vacuity the epic came to delete.*

**D7 — The exit-code / pipeline class is CLEAN; do not spend slices there.** Zero real `cmd | tail && echo ok`, zero always-true `[ "$x" ]`, zero `read` without `-r`, zero materially unquoted `[ ]` tests. Every `|| true` inspected is the correct `grep -c` counting idiom (`grep -c` exits 1 on zero matches while printing 0; removing it makes the script die earlier, not later). The real mechanical hazard is the opposite shape — a script that ACCEPTS an argument it does not understand. *Why: the wish ranked this class high; the measurement says otherwise, and honest ranking beats inherited ranking.*

**D8 — One slice owns `.github/workflows/doc-gates.yml`, and it is round 2.** Five round-1 slices deliberately do not touch that file, so their PRs cannot conflict in it; `cgsi-s8-wire-tripwires` wires every new `--selftest` selftest-FIRST in one step after those five merge. It also fixes a real ordering defect: a `--selftest` placed in a step AFTER the bare run is skipped exactly when the gate reds, so the repo learns a guard can fail only on runs where it did not. *Why: sequenced rounds beat five concurrent PRs colliding in one YAML, and one place performs the fabrication pre-check once, correctly.*

**D9 — Every builder runs Opus at medium, by explicit instruction.** Four slices (arg-dispatch's cross-surface blast radius, studio-link-lint's circular-selftest judgment, docs-anchors' interacting sections, tenant-scope's security predicate) would otherwise warrant Fable. Fable is capped until Aug 21. *Why: the cap is honoured and the cost is paid in brief length — each of those four carries its planted inputs, its false-red controls and its named flip-risk inline, so the builder proves rather than interprets.*

**D10 — Three slices carry a HIGH-FLIP-RISK line.** `cgsi-s2-arg-dispatch` (does a correct unknown-arg arm newly RED a CI step?), `cgsi-s6-budget-span-pin` (does the golden pin CLOSE the laundering channel or merely RELOCATE it?), `cgsi-s7-tenant-scope-marker` (the tenancy/security predicate — too strict invalidates a live justification, too loose and the spoof survives). *Why: the review phase must independently RE-DERIVE those judgments, and name where a genuinely independent second reviewer is owed before merge.*

**D11 — Absence of mutation is absence of verdict.** The epic names its unreached corners rather than implying coverage: `stale-verdict-watch` (12/12 consecutive main failures, log unread), `webhook-fanout-watch.sh` (the only wired guard with no `set` line and no harness), the six `scripts/connectors/` proofs, `audit-paper-readers.sh` (no baseline at all — it outran every surveyor's timeout). All filed. *Why: a harness's documented exclusions are its blind spot, and an audit that hides its own is the thing it came to delete.*

### Wave 2 — gate wiring + spec generator (D12–D23)


**D12 — The inverse blocking-authority clause derives its subject set as the COMPLEMENT (`.checks` + transitive `needs:`-closure), never as an `.exclusions` join.** *Why:* measured at structural evidence the join reds 3 and the complement reds 4 — the extra is `connectors.yml`'s `shim-confinement`, whose job-adjacent comment asserts "BLOCKING — no continue-on-error" and which has NO ledger row, so a join can never reach it; and all 13 S3 rows sit inside the needs-closure (13/13), so the complement excludes transitively-blocking names by construction with no hand list to rot.

**D13 — The clause uses STRUCTURAL evidence only — job `name:` token, own step names, the contiguous comment block immediately above the job key — never a substring search for the context name.** *Why:* mirroring the existing forward clause's name-anchored 200-char window MISSES all three known specimens (doc-gates' claim sits 316 lines above its own job name) and collides on generic job keys, reddening `changes`, `build` and `control-plane` on ordinary prose.

**D14 — File-header prose is reported UNRESOLVED against a committed baseline, never red.** *Why:* of its 11 hits at least five fire on prose that DENIES blocking authority ("but NEVER blocks the merge", "can never be a merge gate") — reddening a correction is the fastest way to get a guard disabled.

**D15 — The clause and the doc-gates honest step-renaming CO-MERGE in one PR.** *Why:* proven by mutation, not by reading — planting one disclaimer into the real `.github/workflows/` took `required-checks.test.sh --hermetic` from `177 passed, 0 failed` to `173 passed, 4 failed`; the hermetic suite scans the REAL tree, and 23 live `name:` values carry `(blocking)`.

**D16 — `go-format.yml` and `security.yml` get an ANNOTATION (`# spec-authority: advisory-ok — <reason>`), not a rename.** *Why:* their `(blocking)` token is inside the JOB name, which IS the rendered context name and IS a committed exclusion row — renaming would silently invalidate the ledger.

**D17 — "Disarm the clause, watch its own `--selftest` red" is VACUOUS and is forbidden as a proof method.** *Why:* `required-checks-verify.sh:709` `probe()` re-execs the COMMITTED path, never `$0`; a copy with `PROSE_DISCLAIMERS` set to `ZZZNEVERMATCHZZZ` still printed `SELFTEST OK`. The working template is the §6(d) idiom — mutant copy inside `scripts/`, invoked DIRECTLY with `--spec/--readback/--runs/--sha/--workflows`, armed rc=1 / disarmed rc=0 on the identical fixture.

**D18 — The generator's parser is widened at the JOB level only; step-level `continue-on-error` REFUSES LOUDLY instead of silently classifying.** *Why:* the naive fix ("any indentation, any non-false value") would mark `js-tests.yml`'s `test` job advisory — it mixes 3 advisory steps with genuinely blocking ones — and EXCLUDING a real gate loses protection rather than adding it.

**D19 — The `^on:` byte anchor is fixed at ALL THREE sites in one PR.** *Why:* it also lives in `scripts/absent-context-census.test.sh` (443, 465) and `scripts/check-deployyml-filters.sh` (128); a one-file fix would leave two parsers disagreeing about the same workflow — the mirrored-truth defect again.

**D20 — All new suite clauses land in `scripts/required-checks.test.sh` in ONE round-2 slice, decoupled from the fixes they guard.** *Why:* a guard co-merged with its fix cannot red on the fail-before state (Standing Law 0), and one owner for that 3,437-line file removes the wave's worst collision.

**D21 — `cchi-w57-blocking-shaped-name-census-guard` stays FILED, not claimed.** *Why:* `.github/required-checks.json` itself routes the count to that task; Standing Law 0 sends free-standing gates to `cch-instruments-epic`; and this wave's own fixes move the census, so a guard merged beside them is born green. It inherits this wave's defended definition instead — 51 under a subtraction ledger of eight buckets, against 59 under the published w56 recipe, against 3 under a literal reading.

**D22 — The registration trigger is EXECUTED up to, and stops at, the human gate.** *Why:* both halves fire today — `Required-check spec gate` is `completed/success` on main HEAD, and a fresh `--require-new-context` sweep reports `evaluated 21, skipped 39, casualties: 0` with all eight non-green heads already CONFLICTING. The active token carries repo admin and the PUT would succeed; `cch-w37` makes it an explicit owner sign-off and `cch-w36` was cancelled precisely for inviting a builder to mutate live protection.

**D23 — The honesty chain is PUBLISHED, not footnoted.** *Why:* the crown lands in a file whose CI homes are `Required-check spec gate` (S7 EXCLUDED) and `Required-check spec drift (advisory)` (S2, continue-on-error), so its red does not yet stop a merge. A tripwire that names its own authority ceiling is strictly better than one that lets a reader assume it has teeth.

## Roadmap

Wave 1 slices (all filed as published children of `ci-gate-script-integrity-audit`, all Opus per D9):

| # | task | round | size | surface |
|---|---|---|---|---|
| 1 | `cgsi-s1-crown-false-red` | 1 | small | `crown-reconcile.test.sh` predicate + `crown-reconcile.yml` paths — the live red |
| 2 | `cgsi-s2-arg-dispatch` | 1 | medium | unknown-arg refusal across ten CI-wired guards (D6) |
| 3 | `cgsi-s3-studio-link-lint` | 1 | medium | the confirmed second-order vacuous selftest + whitelist anchoring |
| 4 | `cgsi-s4-web-literal-floor` | 1 | medium | corpus floor + comment-position `lit-allow` + first selftest |
| 5 | `cgsi-s5-docs-anchors-hash-arm` | 1 | large | comment-only symbol, three silent aborts, unquoted ERE, first selftest |
| 6 | `cgsi-s6-budget-span-pin` | 1 | medium | golden-pinned + capped onramp span exclusion |
| 7 | `cgsi-s7-tenant-scope-marker` | 1 | medium | comment-position `# global-read:` + missing-root refusal |
| 8 | `cgsi-s8-wire-tripwires` | 2 | small | the wave's single `doc-gates.yml` edit, after 3–7 merge (D8) |

Backlog, filed and published under the same parent — the epic's future, in priority order:
`cgsi-bl-doc-gates-requirable` (human gate, D3) · `cgsi-bl-s7-generator-spec-drift` (regeneration erases a hand-corrected exclusion) · `cgsi-bl-baseline-laundering-estate` (seven silencer files, no CODEOWNERS, no growth ratchet) · `cgsi-bl-out-of-fence-guard-findings` (four defects outside the fence, each with its planted violation) · `cgsi-bl-unreached-corners` (D11) · `cgsi-bl-preview-parity-and-mirror` · `cgsi-bl-canonical-marker-blind-outside-five` · `cgsi-bl-pr-task-gate-selftest-unclassified` · `cgsi-bl-literal-family-siblings` · `cgsi-bl-shell-harnesses-overclaims-registration-sample`.

Later waves, in the order the evidence suggests: (a) the round-2 wiring plus the doc-gates promotion decision; (b) the baseline-laundering growth ratchet, which is one guard that closes seven holes; (c) the unreached corners, mutation-audited rather than assumed; (d) a coverage re-derivation over the full 167-file recursive inventory, since the original census measured only the top level.

### Wave 2 — gate wiring + spec generator

Round 1 (dependency-free, builds this wave):

| Slice | Task | Surface | Size | Model |
|---|---|---|---|---|
| Inverse blocking-authority clause + honest doc-gates step names (CROWN) | `cgsiw-s1-inverse-blocking-clause` | `scripts/required-checks-verify.sh`, `doc-gates.yml`, `go-format.yml`, `security.yml`, `connectors.yml` | large | fable |
| Generator parser: quoted `"on":`, non-literal continue-on-error, `.yaml` glob, both-lists refusal | `cgsiw-s2-generator-parser-forms` | `scripts/required-checks-generate.sh`, `absent-context-census.test.sh`, `check-deployyml-filters.sh` | large | fable |
| Wire two orphan selftests + a push↔pull_request paths-parity tripwire | `cgsiw-s3-wire-orphans-and-paths-parity` | `.github/workflows/shell-harnesses.yml`, `scripts/doc-gates-paths-parity-check.sh` (new) | medium | opus |

Round 2 (dispatched by the lead after its dependencies MERGE):

| Slice | Task | After | Surface | Size | Model |
|---|---|---|---|---|---|
| Mutation clauses for every fix this wave ships | `cgsiw-s4-suite-mutation-clauses` | s1, s2 | `scripts/required-checks.test.sh` | large | fable |
| The three proven doc-gates paths-filter gaps | `cgsiw-s5-doc-gates-paths-gaps` | s1 | `.github/workflows/doc-gates.yml` | medium | opus |

Filed, not built this wave: the doc-gates requirable-aggregator packet (human-gated), the branch-protection PUT (`cch-w37`, human gate), the blocking-shaped census guard (`cchi-w57`), the `Dispatch (compose-smoke paths)` exclusion row (spec file, out of fence), and the out-of-fence guard findings — `deploy/cp-deploy_test.sh` (green on a live re-pin to `localhost:4100`), `tooling/task-obsession/reland_check.py` (62 assertions bind none of its fetch-verdict branch), `api/scripts/sobelow-fresh-finding-guard.sh` (`--selftest` never invoked), `js/scripts/check-no-node-imports.sh` (five surviving plants).

## Fence

`scripts/` + fixture dirs + the minimum `.github/workflows` edit required to wire a selftest, ONLY. Disjoint from the `api/lib/barkpark_web` controller+plug wave and the `api/lib/barkpark/sharing` share-token wave. No `api/`, `cloud/`, `js/`, `web/` or `internal/` edits — gate-critical guards DO live outside the fence (`api/scripts/sobelow-*.sh`, `js/scripts/check-no-node-imports.sh`, `api/test/scripts/build-plugin-node-matrix.sh`) and findings there are FILED with the planted violation, never fixed here.

Every mutation goes to a temp copy under the scratchpad or a fixture dir. No `git checkout`, no `git stash`, no branch switch — the primary checkout stays on `main` and other sessions hold uncommitted work in it. Each slice re-checks `git status --porcelain` for paths it did not intend to change. Never weaken a guard to make it pass: a pre-existing violation a strengthened guard newly sees is a FINDING to file, never a licence to widen the pattern.

## Wave log

### Wave 2026-08-19 — wave 1 (grade A−)

**Landed: 7 of 7 round-1 slices, every one gate-green on the reviewer's final branch.** The wave's method held: no verdict in it was earned by reading a regex. Reviewer re-ran every gate and independently re-derived the high-flip judgment.

- **S1 crown-reconcile false red** (`cgsi-s1-crown-false-red`, `…-f-0`, unchanged by review). The double-run assertion grepped `crown-reconcile` over `shell-harnesses.yml` and fired on the PROSE COMMENT at line 84 — testing MENTION where its message claimed EXECUTION. It had skipped the reconcile step on every push and every ~6h schedule for ~36h. Predicate tightened to non-comment occurrences and, crucially, the assertion now plants a real wiring in a temp copy on EVERY run and fails if the predicate no longer catches it. Reviewer disarmed `wiring_hits()` to `echo 0`: 228/1, rc=1 — the built-in mutation case is genuinely able to fail. 229/0 on the real tree.
- **S2 unknown-arg refusal on ten CI-wired guards** (`cgsi-s2-arg-dispatch`, `…-f-1`, unchanged). All ten now exit 2 and name the argument; nine keep `--selftest`=0; `check-bp-graph-drift` bare stays rc=1 on a PRE-EXISTING `web/public/bp-graph.js` mirror drift the reviewer confirmed untouched vs origin/main. Reviewer re-derived the invocation census independently: every live call in `.github/workflows`, `Makefile` and `scripts/` is bare, `--selftest`, or `--write`. No CI step newly reds.
- **S3 studio-link-lint** (`cgsi-s3-studio-link-lint`, **`…-2-r`**). Selftest no longer reimplements the scan — eight cases drive the real gate against a fixture tree, asserting exit code AND output. Whitelist anchored to a path segment (a suffix-spoofed `evil_studio_chrome.ex` no longer inherits `studio_chrome.ex`'s exemption); an absent scan root reds. **Reviewer fix:** `$0` was resolved AFTER the `cd`, so `cd scripts && bash studio-link-lint.sh --selftest` ran every case at rc=127 — a FALSE RED on a legitimate invocation.
- **S4 web-literal floor + comment-position waiver** (`cgsi-s4-web-literal-floor`, `…-3`, unchanged). Zero-file corpus now reds (`MIN_WEB_FILES=30`, live 56); the `lit-allow` waiver is read from a comments-only projection of the length-preserving lexer, so a JSX attribute `data-x="lit-allow"` and a CSS class `.lit-allow` no longer waive a live `#ff0000` (both were green before). Reviewer re-proved both by mutation: reverting the allow read to `raw_lines` reds the JSX-spoof arm; `MIN_WEB_FILES=0` reds the relocated-copy arm.
- **S5 docs-anchors** (`cgsi-s5-docs-anchors-hash-arm`, `…-4`, unchanged). The `^#` alternative let a symbol surviving only in a `#` comment satisfy a code anchor; it is now scoped to `.md` anchor paths. Three grep assignments aborted the whole run on an empty result under `set -euo pipefail`, making §1's friendly failure unreachable and silently skipping §3c–§8. `$sym` is now a literal, not an ERE. **Reviewer's strongest evidence:** the real-tree output is BYTE-IDENTICAL to the origin/main script run in place — zero new findings, zero regressions — and disarming either fix reds the matching selftest case.
- **S6 doc-budgets onramp span pin** (`cgsi-s6-budget-span-pin`, **`…-5-r`**). The budget-exempt span validated marker count and order but nothing about content, so 34KB of in-span filler printed the identical counted size and passed. Span is now pinned byte-identically to `scripts/onramp-span.golden` and capped at 4000B, so re-pinning blesses content but never unbounded size. **Reviewer fixes (two):** the slice shipped `DOC_BUDGETS_SPAN_ONLY=1`, an env var that skipped ~45 fixed caps AND the 7-card count while printing PASS at exit 0 — the exact class this wave hunts, introduced by the wave itself. It is now the argument `--span-only`, and `DOC_BUDGETS_ONRAMP_SPAN_CAP` is CLAMPED so it may only tighten. Both pinned by new selftest arms (11 total). Plus the same `$0`-after-`cd` false red as S3.
- **S7 tenant-scope waiver** (`cgsi-s7-tenant-scope-marker`, **`…-6-r`**, HIGH-FLIP). The `# global-read:` waiver was a raw substring, so a string literal, a sigil, a bare marker, or the marker buried mid-prose each laundered a live unjustified fail-open read to green. It is now a code-position comment that must OPEN with the marker and carry a real reason. A missing or empty scan root reds. **Reviewer fix:** `"$0"` was invoked as a bare command word, so from `scripts/` all 14 re-invocations died rc=127.

**The high-flip judgment, independently re-derived (not a re-read of the builder's reasoning).** The reviewer extracted the shipped `justified()` predicate and ran it directly against every real `# global-read:` line in `api/lib`: **15/15 accepted, 0 rejected** — no false red on a reviewed waiver. Then nine adversarial shapes the builder did not test were planted against the real gate: marker and read both inside a heredoc, a string held open past an escaped quote, a marker after `#{}` interpolation, an uppercase non-interpolating `~S` sigil, a punctuation-only reason, and a comment that does not OPEN with the marker — **all nine red**, plus three legitimate shapes green. The predicate holds in both directions. A genuinely independent second reviewer on S7 remains warranted before merge (manual lead step).

**Cross-slice finding the reviewer fixed in three places.** Three slices taught their gate to re-invoke itself and three got the self-reference wrong — resolving `$0` after a `cd`, or executing it as a bare command word. Every one produced a rc=127 false red on `cd scripts && bash <gate>.sh --selftest`. All five hardened selftests now resolve their own absolute path from `BASH_SOURCE` before changing directory, and all five pass from the repo root and from `scripts/`.

**Stalled: nothing.** `cgsi-s8-wire-tripwires` was NOT built by design — it is the wave's single `doc-gates.yml` edit, deliberately deferred to round 2 so five concurrent PRs cannot collide in one YAML.

**What the next wave should take.** (1) Merge round 1, then dispatch `cgsi-s8-wire-tripwires` — until it lands, every selftest this wave built runs only when a human types it, and `doc-gates.yml`'s existing step ordering skips the selftest step exactly when the gate reds. (2) `cgsi-bl-doc-gates-requirable` is the highest-leverage backlog row: this wave hardened a security guard that still cannot block a merge. (3) `cgsi-bl-literal-family-siblings` — `templates-literal-check` and `go-literal-check` carry S4's two defects unfixed, and S4's fix is now a proven template. (4) `cgsi-bl-baseline-laundering-estate` — every silencer file in the estate is regenerable in one command and nothing in CI compares a baseline to its previous revision, which is the residual S6 relocated rather than closed.

### Epic charter — CI gate integrity, wave 2: the layer BENEATH the guards

Epic task: `ci-gate-script-integrity-audit`
Wave Paper: `ci-gate-wiring-spec-generator-wave-2026-08-19`
Wave referent: `ci-gate-script-integrity-audit-wave-2-log`
Audited against origin/main `bf499f54b63135b8ae078305b83f2b5b2c078877`.
(The strategy phase pinned `122fd0df81`; the tree moved during the wave and every number below was re-derived at `bf499f54b6`.)

#### Wave 2 vision

Wave 1 of this epic hardened guard SCRIPTS — ten unknown-arg refusals, a studio-link-lint selftest, docs-anchors, doc-budgets. Its own ranking put two things FIRST by blast radius and then covered neither: `.github/workflows/doc-gates.yml` (the WIRING that decides whether a guard runs at all) and `scripts/required-checks-generate.sh` (the GENERATOR that decides what may block a merge). A guard can be perfectly written and still vacuous as a gate if the wiring never invokes it on the PR that breaks it — and a generator that silently emits a wrong spec is worse, because every downstream verifier then agrees, correctly, against the wrong answer.

Wave 2 audits that layer. Two of the wish's premises and two of the strategy's did not survive first contact, and each refutation improved the wave rather than shrinking it:

- **doc-gates cannot block a merge at all.** Main's required set is exactly four contexts — Cloud gate, Console gate, Elixir gate, PR references an active task. `Doc budgets + anchors` is filed S4 PATHS-FILTERED among 25 exclusion rows, and 21 of its steps are named "(blocking)". Every wiring gap inside doc-gates is therefore a POST-MERGE DETECTION gap, not a merge hole. That re-pricing holds and it re-ranks the whole wave.
- **The spec generator is NOT unharnessed.** `scripts/required-checks.test.sh` is 3,437 lines / 31 sections / ~28 generator drives / 7 disarm mutations, wired twice in `required-checks-drift.yml`. Bolting a second `--selftest` onto `generate.sh` beside it would manufacture the mirrored-truth defect this repo has already paid for four times. The work is to find what the existing suite does NOT mutate and extend THAT file.
- **`required-checks-verify.sh` already carries an 18-probe mutation `--selftest`.** The crown appends probes, it does not build a harness.
- **The advisory-posture census numbers were all wrong** — wish 24, strategy 18, truth 15 YAML keys in 11 workflows; console-harness scored third-highest on a substring scan while all five of its hits BAN the construct. Zero of the 15 are silently-demoted blocking guards. The defect is in the CLASSIFIER, not the postures.

The crown is a class this repo's own doctrine names and nothing enforces. `required-checks-verify.sh`'s advisory-prose clause reds when a workflow calls a REQUIRED context advisory. The INVERSE — a workflow asserting blocking authority the spec DENIES — is enforced by nothing: the file contains ZERO references to `.exclusions` across all 872 lines. `docs/ops/merge-gates.md` already carries a bullet headed "A NAME THAT SAYS (blocking) AND HAS NO MERGE AUTHORITY AT ALL". The disease is named; the mechanism does not exist.

Fence: `.github/workflows/**` + `scripts/**` + fixture dirs ONLY. Findings in gate-critical scripts outside it (`api/scripts/sobelow-*.sh`, `js/scripts/check-no-node-imports.sh`, `deploy/cp-deploy_test.sh`, `tooling/task-obsession/reland_check.py`) are FILED with the planted violation, never fixed here. `.github/required-checks.json` is a SPEC file and the branch-protection PUT is a human gate (`cch-w37-bl-register-spec-gate-human-gate`) — this wave does not take it, even though the active token would let it.

### Wave 2026-08-19 — gate wiring + spec generator (`ci-gate-script-integrity-audit`)

Round 1 built three slices; all three green on the reviewer's re-run and pushed with PRs open. Grade **A-**.

| Slice | Task | Final branch | Verdict |
|---|---|---|---|
| Inverse blocking-authority clause + honest doc-gates step names (crown) | `cgsiw-s1-inverse-blocking-clause` | `loop-epic/inverse-blocking-authority-clause-honest-0-r` | `blocking_authority_check()` ships with a complement-derived subject set (93 of 112 jobs denied), three structural evidence classes, a reason-bearing escape hatch checked in both directions, and probes 19–23. Fail-before arm re-run by the reviewer against origin/main's four workflows reds exactly the predicted 4. |
| Four legal YAML spellings make the spec generator emit a wrong spec at exit 0 | `cgsiw-s2-generator-parser-forms` | `loop-epic/four-legal-yaml-spellings-make-the-spec--1-r` | Quoted `"on":` trigger key, continue-on-error by VALUE, the both-lists refusal's missing mirror (`--expect-demoted`), and the `*.yaml` glob — fixed at all four byte-anchor sites plus the two sibling scripts. `.github/required-checks.json` untouched. |
| Wire two orphan selftests + the push↔pull_request paths-parity tripwire | `cgsiw-s3-wire-orphans-and-paths-parity` | `loop-epic/wire-two-orphan-selftests-and-build-the--2-r` | `cloud-static-gz-guard.sh` and `pds-live-hetzner-placement-group.sh --selftest-offline` were written, green, mutation-proven and invoked by NO workflow; both are now wired selftest-first. New 419-line `doc-gates-paths-parity-check.sh` fails closed on `[] == []` and carries a self-retiring pin for the live 70-vs-69 drift. |

Reviewer fixes, one commit per slice: both prose clauses in `required-checks-verify.sh` now scan `*.yaml` as well as `*.yml` (s1); a quoted or absent `continue-on-error` is read as the FALSE it is, so a blocking job is never dropped from the required set and a quoted-`false` step cannot manufacture a laundering red (s2); the parity lane installs PyYAML using this workflow file's own idiom instead of hard-failing on an image fact (s3).

Cross-slice integration proof the reviewer ran and no builder could: s1's clause over a merged s1+s3 workflow tree reads 96 of 115 jobs denied with zero violations, and s2's generator builds its index over that same tree without tripping the catch-all or laundering refusals.

THE HEADLINE, restated because it re-ranks everything in this fence: **doc-gates cannot block a merge at all.** Main's required set is exactly `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task`. Every wiring gap inside doc-gates is post-merge DETECTION, never a merge hole — and the crown slice exists because 21 of its step names said `(blocking)` anyway.

Stalled: nothing. Deferred BY DESIGN to round 2, dispatched as their dependencies merge — `cgsiw-s4-suite-mutation-clauses` (after s1 AND s2) mechanizes every disarm this wave proved by hand; `cgsiw-s5-doc-gates-paths-gaps` (after s1) closes the three proven paths-filter gaps and must delete the pin line in `scripts/doc-gates-paths-parity-check.sh` in the same PR or s3's guard reds STALE PIN.

Next wave: merge round 1 in the order s1 → s2 → s3 (disjoint files, so any order works, but s5's brief is written against a merged s1), dispatch s4 and s5, then take the axis this wave deliberately did not: the `continue-on-error` postures themselves, and the gate-critical scripts outside this fence (`api/scripts/sobelow-fresh-finding-guard.sh`, `js/scripts/check-no-node-imports.sh`), both already filed with planted violations.
