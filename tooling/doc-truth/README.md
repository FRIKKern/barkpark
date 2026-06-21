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
that gate). Current state: **19/19 rows resolved, 0 duplicate owners, budget
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
- **Candidate set:** the 335 elixir files present as nodes in `symbols.json` — the
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
**34 under-documented, top gap is the tenancy seam (membership/project/workspace/
dataset, reach ~292, named by zero docs).**

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
to `remake-failures.log` (gitignored, like paperflow's `simplify-failures.log`);
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
  **not reject** (claims + links + anchors all survive — **41 → 41 facts, lost:
  0**) AND verdict is **human** (verbatim-exempt → must require sign-off).
- **NEGATIVE-1 (must pass)** — same candidate but drops the `systemctl restart`
  fact from both GR and PM. Asserts `reject` with `cmd:systemctl restart` in
  `lostClaims`.
- **NEGATIVE-2 (must pass)** — a candidate that drops the
  `docs/ops/studio-nav-bug-2026-04-19.md` outbound link. Asserts `reject` with it
  in `lostLinks`.

Current state: **POSITIVE human (41→41, lost 0) · NEGATIVE-1 reject · NEGATIVE-2
reject · no file written.**

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
