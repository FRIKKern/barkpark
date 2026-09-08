# Phantom-warrant enforcement ledger — 2026-08-19

<!-- NO doc-tier LINE, DELIBERATELY. The three tiers are agent / human / cold,
     and `cold` means RETIRED — a doc nobody should load, whose commands need a
     dated HISTORICAL RECORD banner. This ledger is neither: it is live, and it
     ships a script you are MEANT to run. Stamping it `cold` (as the first draft
     did) trips docs-anchors-check §for-cold-docs-with-commands, and the fix is
     not to add a HISTORICAL RECORD banner asserting something false in order to
     quiet a guard. 1,009 of the 1,178 rows in this directory carry no tier line
     either — ledger rows are not part of the routed three-tier doc system. -->



**What a guarantee sentence in this repo is actually worth.** Four bounded strata, a stated
denominator for each, and a four-cell verdict per claim.

Re-derived and published **2026-09-08** against `287dd278d653ab02e8c9b6b895c8b0f85ae2baf4`.
Every counted figure below is re-derived by
`tooling/grip/ledger/phantom-warrant-enforcement-ledger-2026-08-19.rerun.sh`, which **exits 1 when
one drifts**.

<!-- FIGURES
# THE ONLY HOME OF THESE NUMBERS. The .rerun.sh re-derives each and compares;
# it deliberately carries no copy of its own, because a script that holds the
# numbers it checks agrees with itself forever while the ledger rots beside it.
required_contexts             = 4
exclusion_rows                = 119
workflow_files                = 64
canonical_grep_occurrences    = 202
canonical_declarations        = 97
claude_md_numbered_claims     = 19
docs_anchors_real_invocations = 1
-->

## Read this first: three of the commissioning figures were stale, and that is the finding

This ledger was commissioned with denominators measured at verify time. **Re-deriving them was the
first act of writing it, and three had drifted badly:**

| figure | commissioned | re-derived `287dd278d` | |
|---|---:|---:|---|
| required contexts | 4 | **4** | holds — and the same four names |
| CLAUDE.md numbered claims | 19 | **19** | holds (8 Golden Rules + 11 Past Mistakes) |
| `docs-anchors-check.sh` real invocations | 1 | **1** | holds |
| **exclusion rows** | 25 | **119** | **drifted 4.8×** |
| **workflow files** | 50 | **64** | **drifted** |
| **`@canonical` declarations** | 51 | **97** | **drifted 1.9×** |
| **`@canonical` grep occurrences** | 128 | **202** | **drifted** |

**The drift is not an error to correct back.** These are denominators over a live repo: workflows get
added, markers get stamped, exclusion rows accumulate. What the drift proves is the premise —
**a transcribed figure is stale in its own commit**, and the only durable form of a count is a
producer. That is why the `.rerun.sh` exists and why it reads its expected values *out of this file*
rather than carrying them.

**A measurement error of my own, recorded because it nearly became a filed finding.** The first pass
reported `docs-anchors-check.sh` as drifted 1 → 8. It has not drifted. The grep counted **mentions**
against a claim about **invocations**: of the 8 lines, 2 are `paths:` filter entries, 4 are comment
prose, and 2 are invocations — one of which is `--selftest`. **One real invocation, exactly as
commissioned.** A mention-shaped predicate cannot answer an invocation-shaped question, and the
`.rerun.sh` encodes the narrow predicate so the same mistake cannot be made twice.

## The four cells

Three cells are not enough. The one that carries the weight is the second.

| cell | means |
|---|---|
| **ENFORCED** | A named test/guard/type/constraint reds when the claim is violated — **and the guard can actually fail.** |
| **ENFORCED-ADVISORY** | A guard that **structurally cannot stop a merge**: paths-filtered (absent context), `continue-on-error` (laundered red), or an S4/S7 exclusion row. **This is the default cell, not a nicety.** |
| **UNENFORCED-BUT-TRUE** | Holds today by construction. Nothing stops it drifting. |
| **FALSE** | Does not hold on `origin/main`. |

## The ranking rule, stated so it can be argued with

**Rank by what a reader would DO with the false belief.** Authorization, tenancy, atomicity and merge
authority outrank formatting and naming, because acting on those produces a security or process hole;
acting on a naming claim produces a tidier grep.

Applied: the `.test.sh` unknown-flag swallow is ranked **LOW**, and the reason is exposure, not
severity-in-principle — the only flag-passing CI invocation of any `.test.sh` is
`required-checks.test.sh --hermetic`, and that harness is strict (`rc=2` on an unknown flag). **Zero
live exposure.**

## Stratum A — merge authority

**Denominator, re-derived:** **64** workflow files, **4** required contexts, **119** exclusion rows.

The four required contexts are `Cloud gate`, `Console gate`, `Elixir gate`, and
`PR references an active task`.

| claim | cell | evidence |
|---|---|---|
| `blocking_authority_check` (`scripts/required-checks-verify.sh:659`) gates merges | **ENFORCED-ADVISORY** | Exactly ONE real-tree workflow invocation: `required-checks-drift.yml:153`, job *Required-check spec drift (advisory)*, `continue-on-error: true`. `console-harness.yml:522/1007/1089` and `elixir.yml:259` are **comment prose**; `shell-harnesses.yml:285` runs only `--selftest`. |
| `docs/ops/merge-gates.md:828/830/839` | **FALSE** | See `pws-s2`. |
| `scripts/elixir-path-escape-check.sh` — *"OK: every repo-root read … is dispatched on."* | **FALSE** | See `pws-s8`. |

### The inverse class, which the commissioning framing misses

**The naming layer is wrong in BOTH directions.** 54 job/step names claim an authority they do not
have — and **`PR references an active task` is a required context whose name claims no authority at
all.** It reads like a status line and is one of only four things that can stop a merge.

A census that only hunts for over-claiming names will never find this one, because it is not looking
for the shape.

### One honesty note, and deliberately zero rows

`required-checks.json` `_readme[4]` **already** declares:

> *"EXCLUSIONS ARE WHAT THE SAMPLE SAW, never a complete census. A workflow that never triggered on
> either sampled head renders no name at all, so it cannot appear below."*

This is the **ENFORCED-BY-DISCLOSURE** precedent. **Do not file exclusion rows against it and do not
add a `_readme` note** — the gap is disclosed at the site, in the artifact's own words. The durable
producer is already filed as `cchi-w57-blocking-shaped-name-census-guard`.

## Stratum B — the canonical index

**Denominator, re-derived:** **97** real `@canonical` declarations across section 8's five extensions
(`.ex`, `.exs`, `.go`, `.ts`, `.tsx`), against **202** raw grep occurrences. **The gap is prose
citations** in charters, cards and scaffy corpora; counting those would pad this stratum by 105 rows.
Two numbers, on purpose.

| claim | cell | evidence |
|---|---|---|
| `docs-anchors-check.sh` (the section-8 enforcer) gates merges | **ENFORCED-ADVISORY** | One real invocation, `doc-gates.yml`, job **`Doc budgets + anchors`** — which is an exclusion row reading *"S4 PATHS-FILTERED: doc-gates.yml only runs on matching paths, so on other PRs this name is ABSENT — a required absent context never reports"*. **Stratum B's own enforcer has no merge authority**, and that single job is the sole home of ~20 guards. |
| Section 8's three arms fire | **ENFORCED** | Slug uniqueness, public entry point within 6 lines, resolving `doc:` backlink — each mutation-proven `rc=1`; an empty-result abort is a **FALSE RED** (`rc=1`), never a laundered green. |
| Markers satisfy a no-fork property | **FALSE** | Section 8 does not check it. Five fail: `console-authority-predicate` (5 in-file forks; `router.ex:1536` already admits *"six hand-written copies … none of which can be wrong-proofed"*), `api-client-new` and `zero-check` (registered against a Go **test-fixture string literal** at `internal/scaffy/insertbefore_test.go:239/:245`, so section 8 would RED the true owner at `internal/apiclient/client.go:169`), `error-response-emit` (sheets `export_controller.ex:179-190` still hand-rolls the envelope with no `request_id`), `secret-redaction` (`epic_fleet/benchmark.ex:973/:980` bypass). |
| The `aka:` promise | **UNENFORCED-BUT-TRUE** | All aka words appear in their own file — but only 3 markers are **selective** (`New` matches 3,510 files, `met` 3,431, `role` 1,390), and **section 8 checks nothing about `aka:` at all.** |

## Stratum C — the chokepoints

**Denominator, as commissioned:** 125 files. **1,052** doc/comment lines matched the broad guarantee
vocabulary; **359** survived an assertion-shape filter; **693 were DROPPED AS DESCRIPTIVE.**

**Two thirds of vocabulary hits are not claims, and saying so out loud is what keeps this stratum
honest.** A census that skipped that line would report 1,052 "guarantees" and be theatre.

| claim | cell | evidence |
|---|---|---|
| `envelope.ex` — *"`:internal` not reachable from any request path"* | **FALSE** | See `pws-s4`. Note **line 235 is a third, TRUE claim** — the file is not uniformly wrong, and saying so is the difference between a ledger and a verdict. |
| `envelope.ex` — *"`:internal` is never externally supplied"* | **UNENFORCED-BUT-TRUE** | Same file, other half. |
| `audit.ex:41-42` / `broadcast.ex:181-183` savepoint guarantee | **FALSE** | Atomicity. See `pws-s6`. |
| cloud `authz.ex` — *"`authorize/3` is the single entry point"* | **FALSE** | Authorization. **ZERO callers in `cloud/lib`** (`pws-s7`); its totality clause is latently non-total but unreachable. |
| `Access.claim/2` concurrency half | **UNENFORCED-BUT-TRUE** | `pws-s5`. |
| `Access` WHERE-clause half | **ENFORCED** | `access_test.exs:315`. |
| `ReplayRing` — *"Exactly-once"* | **ENFORCED** | Guard lives under another filename: `api/test/barkpark/sheets/session_idempotency_test.exs:102`. |
| `cycle_fleet` release-gate idempotency | **ENFORCED** | By `unique_index` in migration `20260719020000` — **not** by its `FOR UPDATE`, which is a no-op on a zero-row SELECT. |
| cloud header-degradation guard | **ENFORCED** | `router_team_switcher_test.exs:72`. |

## Stratum D — the doctrine surface

**Denominator, re-derived: 19** numbered claims in `CLAUDE.md` — **8** Golden Rules + **11** Past
Mistakes. **Not 20.**

23 guarantee lines across the 10 routed cards: tenancy 13, cli 3, studio 3, schema-v2 2,
webhook-realtime 1, plugins 1. **`js-sdk`, `tui`, `search-media` and `onix-bokbasen` assert ZERO** —
an absence worth stating, because a card that claims nothing cannot be wrong.

| claim | cell |
|---|---|
| GR5 — `force_ssl` without HTTPS causes redirect loops | **UNENFORCED-BUT-TRUE** |

## What this ledger does not do

It does **not** manufacture rows. A claim that is enforced *is* enforced — cited, and moved past. The
guarantee vocabulary matches ~15,109 lines in `api/lib` + `cloud/lib` + `internal` alone, so an
exhaustive census is unfalsifiable theatre; four bounded, machine-derivable strata with stated
denominators is the honest shape.

## Re-deriving this ledger

```bash
bash tooling/grip/ledger/phantom-warrant-enforcement-ledger-2026-08-19.rerun.sh
bash tooling/grip/ledger/phantom-warrant-enforcement-ledger-2026-08-19.rerun.sh --selftest
```

The gate reds on drift, reds on a **missing** FIGURES line (an absence must never read as a pass),
and reds if zero checks run. `--selftest` proves the comparator discriminates without touching this
file.

**On a red: the world usually moved, the ledger did not lie.** Re-derive, update the FIGURES block,
and re-read the surrounding prose — **a count appears twice, once as data and once as an argument,
and only the first is mechanically checked.**
