# doc-truth — the standing doc-truth verifier

Turns the one-time 22-agent doc audit into a **repeatable tool**. The one-time
audit was ~84% accurate and false-flagged `.github/workflows/js-tests.yml` — a
path that actually exists. This verifier's defining feature is the **re-verify
gate** that audit lacked: no candidate finding is emitted until its check has
been re-run independently and survived.

The verifier is a **lead generator, not an authority.** Every finding carries a
confidence tag and the evidence that produced it. Low-confidence leads never
auto-apply — they land in a human-review queue.

## What it does

```
node tooling/doc-truth/verify-docs.mjs [--json] [--emit-refs] [<doc>...]
```

1. **Extract** — parse a markdown doc into typed claims from backtick spans and
   fenced code blocks.
2. **Verify** — check each claim against ground truth (the on-disk tree + the
   currency manifest, the symbol graph, the router).
3. **Re-verify gate** — before emitting any candidate `false`/`stale`, re-run
   its check independently. If it now passes, suppress and mark `confirmed`.
4. **Route** — high-confidence survivors → findings; low-confidence leads →
   `humanQueue`.

Default corpus is the 92-doc audit corpus
(`fixtures/audit-2026-06-21-corpus.json`); pass paths/dirs to scope.

## Claim taxonomy

| Type | What it matches | Ground truth | Failure status |
|---|---|---|---|
| `path` | repo file paths (`api/…`, `tooling/…`, or `*.ext`) | `manifest.json` files + `fs.existsSync` | `false` (high if anchored to a top dir; low if unanchored/relative) |
| `symbol` | Elixir refs: `Barkpark.Foo.bar`, `func/2`, `defmodule X` | `symbol-graph/symbols.json` | `false` (always **low** — prose extraction is fuzzy) |
| `route` | `/v1/…`, `GET /papers/:slug` | grep `router.ex` + plugin sources | `unverifiable` only — routes are dynamic, **never** flagged false |
| `lineref` | `mix.exs:55`, `content.ex ~:2153/:2172`, `router.ex line ~672` | read the file, scan ±3 of the cited line for an anchor token | `stale` (high) when the line number drifted; the dominant stale category |
| `command` | `mix …`, `bp …`, `make …`, `npm …`, `curl …` | `which` on PATH; `make` target in `Makefile` | `unverifiable` — subcommand semantics aren't checked, so we don't over-claim |

Globs/wildcards (`js/**`, `priv/plugins/*/plugin.json`) and brace patterns are
**not** treated as literal paths.

## The re-verify gate (the never-worse guarantee)

- **path flagged absent** → re-check the literal path at repo root AND in the
  manifest, independently. If it exists, the finding is **suppressed** and
  marked `confirmed`. This is the `js-tests.yml` case: the doc references
  `.github/workflows/js-tests.yml`, the file exists, the one-time audit wrongly
  "fixed" it — the gate re-verifies and emits nothing.
- **lineref flagged stale** → re-resolve the file and re-scan a **wider** window
  (±5 vs ±3) so an off-by-a-few near-miss doesn't become a false stale.
- **symbol false** is low-confidence by construction — it never becomes a hard
  finding; the human queue owns it.

A `node_modules/…` path is never flagged false: `node_modules` is excluded from
the manifest, so the verifier can't prove absence — flagging it would risk the
exact false positive the gate exists to prevent.

## Run it

```bash
# verify the full audit corpus (human report)
node tooling/doc-truth/verify-docs.mjs

# one doc / a directory, machine-readable
node tooling/doc-truth/verify-docs.mjs docs/ops/ --json

# via the unified query front door
node tooling/map/query.mjs verify --docs
node tooling/map/query.mjs verify --docs js/CLAUDE.md --json

# optional sidecar: doc -> [referenced repo files], for drift-gating from the
# manifest WITHOUT touching manifest.json's schema
node tooling/doc-truth/verify-docs.mjs --emit-refs   # writes doc-refs.json
```

`query verify` (no `--docs`) is unchanged — it remains the map-currency gate.

## The acceptance test

```bash
node tooling/doc-truth/acceptance.mjs
```

Two metrics:

- **Recall** — of the audit's 87 real findings (`falseAll` + `staleAll`), how
  many the verifier reproduces, matched on `(doc basename, category)`. Reported
  honestly — **not** hard-failed. The audit was 22 LLM agents reading prose; the
  verifier only reproduces the *mechanical* subset (missing paths → `false`,
  drifted linerefs → `stale`). Many prose-level findings (counts, plugin lists,
  "mark resolved") are intentionally out of reach, and several audit findings
  have since been *fixed* in the live docs — a correct verifier must NOT
  reproduce those.
- **The gate (MUST PASS)** — asserts the verifier emits no `false`/`stale`
  finding for `.github/workflows/js-tests.yml`. Prints `GATE: PASS|FAIL` and
  exits non-zero on failure.

## Code-comment citations (citation-truth epic)

The markdown verifier read only `.md`. A 53-agent citation-truth sweep found that
**27 of 29** confusion/citation defects lived in `@moduledoc` / `///` / `//`
**doc-comment prose** it never parsed — drifted linerefs, dead-dependency
citations, retired-tech assertions. The verifier now reads that prose too, reusing
the **same** extract → classify → verify → re-verify pipeline.

```bash
# scan every tracked .ex/.exs/.go/.ts comment/doc prose
node tooling/doc-truth/verify-docs.mjs --code [--json]
```

- **`extractCommentSpans(text, lang)`** pulls `@moduledoc`/`@doc` heredocs and
  `#` runs (Elixir), `//` `///` `/** */` (Go/TS) into synthetic spans of the
  **same shape** `extractSpans` yields, so `claimsFromSpan` / `verifyClaim` /
  `reverify` run unchanged. The corpus walk dispatches on extension.
- **Bare-range linerefs** — a `file.ext … NNN-NNN` span classifies as a lineref
  *without* a `:`/backtick cue, but only for a **resolvable** basename and never a
  date. This is what catches the flagship
  `capabilities.ex:1527 → router.ex … 716-724` (the real `/v1/auth` lines drifted).
- **Same-package basename resolution** — a code file citing a bare `types.ts`
  resolves to the `types.ts` next to it before any global hit (several exist),
  catching `listen.ts:10 → types.ts:117-126` (real `ListenEvent` is line 818).
- **Precision** — comment prose is noisy, so the HIGH lane is scoped: lineref +
  explicit **backticked** path stay high; symbol/route drop to the low-confidence
  queue. Bare prose that merely *reads* like a path (an `internal/system` tier, a
  `deploy/restart` cycle) is never a claim.

### retired-terms — context-aware dead-tech denylist

```bash
node tooling/doc-truth/retired-terms.mjs [--json]
```

The semantic complement: verify-docs catches drifted *citations*, retired-terms
catches drifted *claims* — prose asserting a gutted technology is current
(`cytoscape` after the graph pane went Canvas2D). **Not a blind grep** — a term is
allowed when it sits within ~170 chars of a negation/historical word
(`gutted`, `removed`, `retired`, `NOT`, `historically`, `legacy`, `mirror`,
`compatible` …), carries an inline `doc-truth-allow` pragma, or lives under an
allowlisted path (`test/`, `CHANGELOG`, git-history docs, this tool's fixtures).
So `Canvas2D, NOT Cytoscape` and `Cytoscape is fully gutted` **pass**, while a
planted `# uses Cytoscape to render` (a live-use verb bound directly to the term)
**flags**. Exit is **never-worse** against the frozen corpus.

### The code-comment acceptance test

```bash
node tooling/doc-truth/acceptance-code-comments.mjs
```

Hard gates (`fixtures/citation-corpus-2026-07.json`): **(a) fail-before** — every
FIXED defect (2 linerefs + 1 path + 7 dead-terms) is caught by the guard. The
linerefs/paths verify against committed frozen WINDOWS of their pre-fix source
(`fixtures/frozen/`, ±context), so the proof survives the live tree being
corrected; the dead-terms verify against their frozen `cite` text. **(a″)
pass-after** — the same defects are GONE from the live tree (closes the loop).
**(a′) live never-worse** — retired-terms over the real tree is clean now that
the purge slices landed (a re-introduction fails here). **(b)** the clean control
(`fixtures/control-clean.ex`) plus `graph_view.ex` / `root.html.heex` (canonical
historical mentions) emit **zero** false positives; **(c)** a planted
live-Cytoscape assertion and a planted stale lineref are both caught; **(d)** the
markdown `acceptance.mjs` (js-tests.yml gate) still passes. The `liveLeads` in the
corpus are drift the guard newly surfaces but no slice fixed — advisory, tracked
as follow-up, and reflected in the Cody Citation-truth grade. Wired into
`doc-gates.yml`, fail-closed, triggering on `.ex/.go/.ts/.md` changes.

## P2 — the waterfall (each fact once)

P1 asks *"is each claim TRUE?"*. **P2 asks the orthogonal question: "is the same
fact RESTATED in more than one place?"** — and, when it is, **proposes (never
applies)** collapsing the duplicates to one canonical home plus typed pointers.

```bash
node tooling/doc-truth/waterfall.mjs [--json]
node tooling/doc-truth/waterfall.mjs --topic <factKey-substr> [--json]
# via the front door:
node tooling/map/query.mjs waterfall
node tooling/map/query.mjs waterfall --topic systemctl --json
```

### Hash on verifiable claims, NOT prose

Two sections restate the same fact when they share a significant set of
**verifiable-claim anchors** — the paths / commands / symbols P1 already
extracts — even if the prose differs entirely. The waterfall **reuses P1's
extractor** (`extractClaims` / `sectionsOf`, now exported from `verify-docs.mjs`
— one set of regexes, no duplication) and content-hashes each claim into a
normalized `factKey`:

| Claim | factKey |
|---|---|
| path | `path:<repo-rel, 2-seg prefix>` (so `_build/prod` ≡ `_build/prod/lib/barkpark`) |
| command | `cmd:<tool + salient arg>` (`cmd:systemctl restart`) |
| symbol | `sym:<module>#<func>` |
| route | `route:<path>` |
| lineref | `lref:<basename>` |

It adds one small class P1's five types skip — **invariant anchors** (`force_ssl`,
`<head>`/`<script>`, `_build/prod`, env vars, `phx-*`) — mined only from backtick
spans, never free prose. A **prose-scan** then augments each section's factKey
set with any corpus-vocabulary anchor whose literal string appears in the
section body, so a fact stated in a backtick in one section (`` `systemctl
restart` ``) matches the same fact stated in prose in another ("Forgot systemctl
restart"). The prose-scan only ever re-finds strings that are verifiable claims
*somewhere* — it never does fuzzy text similarity.

### Canonical-fact DAG

`factKey → { canonical: {doc, section, line, tier}, pointers: [...] }`. Canonical
pick: highest **doc-tier** (`agent` > `human` > `cold`, read from the
`<!-- doc-tier: … -->` marker on line 1), tie-broken by first occurrence. This
DAG is what `--topic` queries — the substrate a routing table builds on.

### Restatement detector + conservative thresholds

Every section **pair** (cross-doc AND within a doc) is compared on factKey-set
overlap. A pair clusters when it shares **≥ 3 distinctive anchors** (Jaccard ≥
0.10). Generic top-dir prefixes (`path:api`, `path:priv`) are **excluded from the
evidence count** — two unrelated sections both touching `api/` is not
restatement. Tuned so the acceptance target (Golden Rules ↔ Past Mistakes, 6
distinctive shared anchors) is caught with headroom while co-mentions stay out.

### Propose-only + lose-no-fact

The detector **never edits a doc.** It emits collapse proposals as data: promote
the higher-tier section to canonical, replace the other's overlapping facts with
a typed pointer (`> See [Golden Rules](#golden-rules) — canonical for: …`).
**Verbatim-exempt** sections (CLAUDE.md Golden Rules / Past Mistakes) are still
proposed, tagged `requiresOwnerSignoff: true`. Every proposal enforces the
**lose-no-fact** guarantee: it enumerates every factKey present in either section
and asserts each survives in `canonical ∪ retained-non-shared ∪ pointer`. A
proposal that would drop a fact is invalid — dropped, with the reason logged.

### The P2 acceptance test

```bash
node tooling/doc-truth/acceptance-p2.mjs
```

- **Detection (must pass)** — runs the detector over the root `CLAUDE.md` and
  asserts the Golden Rules ↔ Past Mistakes restatement cluster is found with ≥ 4
  distinctive shared anchors; prints the shared factKeys. Non-zero if absent.
- **Lose-no-fact (must pass)** — asserts the proposed collapse preserves 100% of
  verifiable claims (`before ⊆ after`); prints the count and any lost facts
  (must be 0), corpus-wide.

## P3 — highways (`highways.mjs` + `acceptance-p3.mjs`)

P1 asks *"is each claim true?"*, P2 asks *"is each fact stated once?"*, P3 asks
*"does the map still work?"* — does every entry in the root `CLAUDE.md` routing
table reach exactly one canonical owner doc in a short hop, and do the byte
budgets / 7-card cap still hold.

`highways.mjs` parses the `| Group | Task pattern | Load |` table, builds a
`canonical-for → owner` index from every doc's line-1 marker, and resolves each
Load target to its canonical owner in **≤2 hops**. A hop is one canonical-record
redirection: hop 0 is a direct non-pointer owner; a pointer doc (`canonical-for`
ending `-redirect`/`-pointer`, or a body `Canonical record:`/`Canonical
guidance …:` line) is followed up to twice. Pointer-of-a-pointer, a missing
link, or a final doc with no `canonical-for` is a routing failure. It also flags
duplicate owners (one topic on 2+ docs), orphan topics (referenced, no owner),
and shells out to `scripts/check-doc-budgets.sh` to surface over-budget docs and
the card count.

```
node tooling/doc-truth/highways.mjs            # readable report
node tooling/doc-truth/highways.mjs --json     # {routes, orphans, duplicateOwners, budget}
node tooling/map/query.mjs highways --json     # via the front door
node tooling/doc-truth/acceptance-p3.mjs       # gates: RESOLUTION + UNIQUENESS (budget informational)
```

The acceptance gate passes when every routing row resolves to one owner in ≤2
hops and no `canonical-for` topic has more than one owner. Budget violations are
reported but do not fail the gate (the repo's own `check-doc-budgets.sh` owns
that gate). Current state: **20/20 rows resolved, 0 duplicate owners, budget
clean (7/7 cards)**.

## P4 — priority (`priority.mjs` + `acceptance-p4.mjs`)

`priority.mjs` joins doc **coverage** against code **reach / importance / churn**
and emits a ranked work queue: high-reach code that's under-documented, and
trivia that's over-documented.

- **Coverage** inverts `doc-refs.json` (`file → [covering docs]`). Verdicts count
  **exact, file-level** references only — a card naming a *directory* is not
  documentation of a specific file.
- **Reach** is the authoritative blast-radius signal from `tooling/map/what-breaks.mjs
  --json` (`closureSize + 2×surfaceReach`); `file-signals.json` is a secondary
  importance signal. Files outside the symbol graph report `reach: null`
  (unknown, never guessed).
- **Churn** joins `cochange-report.json` (`cochangePartners`) and
  `file-signals.json` (`churn`).
- **Candidate set:** the 394 elixir files present as nodes in `symbols.json` — the
  set with a file-exact reverse closure.

```
node tooling/doc-truth/priority.mjs           # ranked report
node tooling/doc-truth/priority.mjs --json     # { queue, overDocumented, buildSpec }
node tooling/map/query.mjs priority --json     # via the front door
node tooling/doc-truth/acceptance-p4.mjs       # asserts top flag is real top-decile reach + build-spec named
```

Verdicts: `under-documented` (reach ≥ p90 AND zero exact coverage),
`over-documented` (≥1 exact doc but zero dependents and reach ≤ p10), else
`proportioned`. The queue actions are `write-new` (no doc names it) or
`extend-canonical <doc>` (a doc already covers it loosely). `buildSpec` names the
canonical "how to build here" doc (`docs/setup/SETUP.md`) and flags the missing
dedicated build-spec (`gap: true` — cqv6 specced, never built). Current state:
**36 under-documented, top gap is `api/lib/barkpark/repo.ex` (reach 329, coverage 0).**

## P5 — remake (the never-worse remake gate)

P1 asks *"is each claim true?"*, P2 *"is each fact stated once?"*, P3 *"does the
map still work?"*, P4 *"is doc effort proportioned to reach?"*. **P5 is the
capstone that USES all four:** it gates a proposed doc **restructure** (merge /
split / promote / rewrite) and lets it land ONLY if it loses no verifiable fact
and no outbound link. Destructive remakes go to **human review, never silent
auto-apply**.

`remake.mjs` exports `gateRemake({ beforePath, beforeText, afterText, meta })` →
`{ verdict, reason, lostClaims, lostLinks, lostAnchors, classification }`.

### The gate (Figure 4 of the plan)

```
proposed remake (beforeText → afterText)
  → CLAIM DIFF:  extractClaims(before) ⊆ extractClaims(after)?   (P1's extractor,
       keyed by P2's factKey)   any factKey missing → REJECT (failure log)
  → LINK CHECK:  every outbound link/URL/doc-path in before still in after?
       any link broken → REJECT
  → STRUCTURE:   every H2/H3 that P3's routing/pointers target still present
       (or redirected via meta)?   a dropped routing anchor → REJECT
  → SIZE/TYPE:   merges docs / alters a canonical H2 / touches a verbatim-exempt
       or requiresOwnerSignoff region?
         yes → HUMAN (queue for review; never auto-apply)
         no (prose/reorder only, all three checks green) → AUTO
```

### The three survival checks

1. **Claim survival** — `extractClaims` (P1) on before & after, each claim hashed
   to its normalized `factKey` (P2's `factKeyForClaim`) so a fact stated two ways
   still matches. `lostClaims` = before-factKeys absent from after. Non-empty →
   `reject`.
2. **Link survival** — outbound links mined from before: markdown `[text](url)`,
   bare `http(s)://…`, and backtick doc-paths (`docs/…`, `api/…`). Mined
   **fence-aware** (line-by-line, skipping ` ``` ` delimiters) so an odd fence
   backtick never drifts the whole-doc pairing. `lostLinks` = before-links absent
   from after. Non-empty → `reject`.
3. **Structure survival** — the set of H2/H3 heading slugs P3 treats as
   routing/pointer targets (the routing table's `§/#` anchors that point INTO
   this doc, plus same-doc `#anchor` links) must survive, or be intentionally
   redirected via `meta.redirects: { oldSlug: newSlug }`. A dropped routing
   anchor with no redirect → `reject`.

### Propose-only / human-review stance

The gate **EVALUATES** a remake — it **never writes a doc**. Applying an accepted
remake is a separate, explicitly-invoked step that is out of scope for P5
(propose + gate only, exactly like P2). A remake that merges docs, alters the
canonical H2 structure, or touches a verbatim-exempt / `requiresOwnerSignoff`
region routes to **`human`** — the never-auto guarantee. Rejects append one line
to `remake-failures.log` (gitignored);
they never pollute git or a rail.

```bash
node tooling/doc-truth/remake.mjs           # human-review queue + recent rejects
node tooling/doc-truth/remake.mjs --json     # { humanQueue, recentRejects, failureLog }
node tooling/map/query.mjs remake --json     # via the front door
node tooling/doc-truth/acceptance-p5.mjs     # gates: POSITIVE + NEGATIVE-1 + NEGATIVE-2
```

### The P5 acceptance test

The acceptance target is the barkpark root `CLAUDE.md` Golden Rules ↔ Past
Mistakes overlap. Those sections are **verbatim-exempt** — so the gate must route
that remake to **human** review and **never write the file**.

- **POSITIVE (must pass)** — builds the real GR↔PM collapse candidate via P2's
  proposal (keep GR canonical; replace PM's *overlapping* facts with a typed
  pointer to GR while keeping every non-overlapping PM fact). Asserts verdict is
  **not reject** (claims + links + anchors all survive — **36 → 36 facts, lost:
  0**) AND verdict is **human** (verbatim-exempt → must require sign-off).
- **NEGATIVE-1 (must pass)** — same candidate but drops the `systemctl restart`
  fact from both GR and PM. Asserts `reject` with `cmd:systemctl restart` in
  `lostClaims`.
- **NEGATIVE-2 (must pass)** — a candidate that drops the
  `docs/ops/studio-nav-bug-2026-04-19.md` outbound link. Asserts `reject` with it
  in `lostLinks`.

Current state: **POSITIVE human (36→36, lost 0) · NEGATIVE-1 reject · NEGATIVE-2
reject · no file written.**

## P6 — metric-currency (`metric-currency.mjs`)

P1–P5 verify *static* claims. **P6 guards the class of claim that re-rots on its
own: hand-coded LIVE metrics in prose.** The truth-audit's #1 honest limit — docs
that pin the Cody grade / per-critic scores drift every commit (the audit fixed
83→81 once; nothing kept it synced). `metric-currency.mjs` compares the README
`## Codebase grade` table against the live `tooling/quality/quality-report.json`
and reports any stale number — overall, per-critic scores, and the `N-critic`
count claim (normalizing `Dead-code` ≡ `Dead code`). Default is REPORT-ONLY
(exits non-zero so the standing loop / CI surfaces drift; **SKIPs** at exit 0 when
the gitignored report is absent). `--fix` **regenerates** the grade-section numbers
(scores, overall `/100`, grade letter, count) FROM the live report — the audit's
durable fix made executable: regenerate the metric, don't hand-maintain it.

```bash
node tooling/doc-truth/metric-currency.mjs          # ✓ FRESH | ✗ DRIFT list
node tooling/doc-truth/metric-currency.mjs --json
node tooling/doc-truth/metric-currency.mjs --fix    # re-sync README from the live report
```

Wired into the `codebase-intel.yml` drift-guard job (it already regenerates
`quality-report.json`). Run `--fix` after a recompute and the grade can never
silently rot.

## P7 — printed `bp` commands (`verify-bp-commands.mjs` + `bp-cli-sources.mjs`)

**This gate proves a printed command PARSES. It never claims the command
SUCCEEDS** — no server is contacted, no token is resolved, nothing is run. A
command that parses can still 401, 404, or do the wrong thing to the right
dataset.

It replaces the verifier's one vacuous green: `verifyCommand` used to return
`confirmed` for ANY `bp …` on `which bp` alone, so every wrong `bp` command in
the tree read as verified. Resolution now runs against a **union of the CLI's
own sources**, because no single one knows the whole surface:

| | source | file | what only it knows |
|---|---|---|---|
| A | manifest rows | `docs/cli/fixtures/full-manifest.json` | the server-declared noun/verb tree (`doc`, `task`, `workspace`, …). Drop it and manifest-driven commands go falsely RED |
| B | `completionNouns` | `internal/cli/builtins.go` | the built-in top-level nouns. B knows `cloud` is a noun — and nothing more |
| C | `parseHzArgs` allowlists | `internal/cli/*.go` | a leaf's declared value/bool flags |
| D | router switch tables | `internal/cli/*.go` (`case "x":` + `if verb == "x"`) | the DEPTH. **Not optional**: `bp cloud barkpark ls` cannot be RED from A+B+C, because B has `cloud` and nothing left can adjudicate the token after it |
| E | `"--flag"` literals | `internal/cli/*.go`, file-scoped | hand-rolled parsers that declare no allowlist. Without E, `bp login --device` and every `bp vercel quick-setup` flag is UNPROVEN |

**Laws.** A token that resolves in NO source is UNRESOLVED and the gate FAILS —
it never skips what it cannot adjudicate. A source that cannot be LOADED fails
the run outright. Absence may be DECLARED, never assumed: `--offline` drops [A],
is accepted only when every target is under `templates/**` (a shipped template
has no manifest fixture in its tree), and PRINTS `SOURCE A DECLARED ABSENT`.
**UNPROVEN is not a pass** — a flag set no source enumerates is reported by name
and by count, and is a different verdict from UNRESOLVED.

Two extractor fixes it depends on, both in `verify-docs.mjs`: fenced lines are
joined across a trailing `\` (a shell continuation is one command, not two
fragments — unjoined, the one correct multi-line command in the tree reds for
the flags on its second line), and required-flag checks run on **fenced lines
only, by bracket DEPTH** (a flag printed inside `[…]` is shown optional, so it
is neither required by a synopsis nor supplied by a doc line; an inline prose
fragment naming one flag is an illustration, not an invocation).

```bash
node tooling/doc-truth/verify-bp-commands.mjs --selftest        # 36 cases, every law proved BY MUTATION
node tooling/doc-truth/verify-bp-commands.mjs templates/**/*.md # exit 1 on any UNRESOLVED, 2 on a dead source
node tooling/doc-truth/verify-bp-commands.mjs --brief <doc>...  # source letters only, no citations
node tooling/doc-truth/verify-bp-commands.mjs --json <doc>...
```

The selftest is mutation-shaped on purpose: each law's negative half (drop D,
drop A, drop E, drop the continuation join, drop the depth rule) must FAIL, or
its positive half proves nothing.

### The mutations run over FIXTURES, not the live READMEs

`fixtures/bp-commands/` holds a corpus the selftest OWNS: `clean.md` (must
GREEN) plus one file per defect class — `unknown-flag.md`, `unknown-subnoun.md`,
`unresolvable-head.md` (each must RED, by name, with a reason).

Anchoring a mutation to `templates/**` looks equivalent and is not. Those files
are edited by other rows — #6941 repaired the `--barkpark` defects the gate was
built to catch — so a mutation pointed at them stops proving anything the moment
someone repairs a README, **and keeps reporting green while it proves nothing**.
Fixtures test the LOGIC; the live `templates/**` case at the end tests the
WIRING, which fixtures cannot. Both are needed, and the live one now refuses to
pass when its corpus filters to empty or yields zero commands.

`clean.md` also pins all four markup shapes a command appears in — fenced,
`$ `-prompted, backslash-continued, and inline in prose — and a selftest case
asserts each shape is present, so the corpus cannot quietly stop exercising one.

### Every green cites the line that made it green

A source letter (`[D]`) is a claim the reader cannot check. Each GREEN row
therefore names the **specific authority** that adjudicated each token:

```
  ✓ L42 `bp cloud site create --name my-search …` [D+C+E]
        ↳ D cloud    → internal/cli/cli.go:391            case "cloud":
        ↳ D site     → internal/cli/hetzner_cmd.go:118    case "site", "sites":
        ↳ D create   → internal/cli/cloud_site_cmd.go:88  case "create":
        ↳ C+E --name → internal/cli/cloud_site_cmd.go:159 parseHzArgs allowlist
```

Source **[A] cites a row, not a line** (`full-manifest.json#cloud.site.create`)
— that manifest ships as a single line of JSON, so a `:<line>` would be a
fiction, and printing one would be exactly the kind of plausible-looking
falsehood this gate exists to catch.

A citation is only worth more than nothing if it is TRUE, so the selftest
re-opens every file the run cited and demands the token actually be declared on
that line — and then **shifts every citation by one line and demands the
read-back FAIL**. Without that mutation, a citation check that never opened the
file would pass just as happily.

## Meta-lesson

The verifier is a **lead generator, not an authority.** It earns trust through
three disciplines, not by claiming to be right:

1. **Confidence-tag every claim** — `high` (mechanical ground truth) vs `low`
   (fuzzy prose extraction).
2. **Re-verify before emitting** — the never-worse guarantee. A finding that
   doesn't survive an independent re-check is suppressed, not shipped.
3. **Human queue for the rest** — low-confidence leads are surfaced for a human,
   never auto-applied.

Mechanical recall beats inflated recall: a `false` that is actually `confirmed`
on re-check costs more than a missed prose nuance.
