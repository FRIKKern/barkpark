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
