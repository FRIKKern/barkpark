# PDS wave 27 round certification — ROUND NOT DONE, RC=1 (certified 2026-08-22 @ 85fed3997b)

**VERDICT: ROUND NOT DONE. RC = 1.** A named red, produced by looking, not a
green obtained by moving the bar (PDS-D348).

The round is blocked by **three** clause failures over **22 named rows**. Every
one is enumerated below by `doc_id` with the specific reason it could not be
honestly adjudicated. **No row was closed, parked or re-worded to make a number
move.**

The headline finding: **the round is NOT blocked by wave-27 residue.** Wave 27's
own bare-filing discipline held — it contributes nothing to the clause-1
failure. The blocker is later-wave rows leaking into the closure-scoped clauses,
which is precisely the second-order trap this slice's brief predicted.

## 1. Provenance

| | |
|---|---|
| certified at | `origin/main` @ `85fed3997b99603f45199bba21a059a4f77f5ada` |
| tree materialized by | `git archive origin/main \| tar -x` (PDS-D397 — NOT the primary checkout, NOT `git clone --shared` + checkout; both reproduce a stale tree) |
| CWD hygiene | no `bisect.py` / `json.py` / `urllib.py` in CWD — the census execs `python3 -`, so CWD is `sys.path[0]` and a stray module both breaks every check and executes its own top-level code |
| round anchor | `2026-07-31T00:21:23.535114Z` (`paper/pds-wave-27-2026-07-31` `_createdAt`) |
| corpus / closure | 6979 rows / 711 closure rows, `perspective=published` |
| page order | `_createdAt:asc` (pinned once at `scripts/pds-ledger-census.sh:509`) |

## 2. Preconditions — verified, not assumed

All four dependency slices are merged to `origin/main`, and all four are
confirmed ancestors via `git merge-base --is-ancestor`:

```
7d3bda6d3b  docs(pds): re-derive the 15 terminal-round adjudications by content — clause 3 falls 15 -> 0 (#8407)    [pds-w27-round-terminal-15]
5a0d7e974d  docs(pds): re-derivation recipe for the 30 bare live rows (wave 27) (#8408)                             [pds-w27-round-bare-30]
a23867c384  fix(ledger): run D298's second half on 14 rows the queue still called claimable (#8409)                  [pds-w27-round-contradiction-13]
4b28b737d6  fix(pds): the census stops lying about itself — clause 6, pipeable --json, a stable page order (#8411)   [pds-w27-census-self-honesty]
```

**Three of those four commit subjects do not carry the task slug.** A
`git log --grep <slug>` finds nothing for `pds-w27-round-terminal-15` and would
report it unmerged. It is merged. Absence of a name is not absence of the work —
resolve by PR, not by grep.

The merged census sends the correct spelling. `PAGE_ORDER = "_createdAt:asc"` is
a single pinned constant at line 509, interpolated at line 656 as `&order=%s`, so
neither documented trap (`order=doc_id`, silently ignored at HTTP 200;
`order=doc_id:asc`, an all-NULL content key) is reachable by typo.

## 3. Quiesce — proven, not waited out

The gate is **closure-scoped exactly as clause 5 scopes itself**. This is not a
stylistic choice: `build_closure` seeds `frontier` from
`sorted(kids.get(root, []))` and never appends `root`, and clause 5 examines
`rows = [corpus[i] for i in closure]`. A corpus-wide gate is hostage to foreign
fleet traffic and never settles.

First attempt **FAILED, and is recorded because it failed**: two closure rows
moved 78 s apart — `pds-bl-merge-gated-criteria-carry-the-flag`
(15:01:38.143243Z → 15:19:32.005142Z) and `task-9e2c61a0979657ae`
(2026-08-05T22:36:40Z → 15:20:00.151705Z). Both were live rows held by other
active workers (`bare-rows-w27`, `dedup-crash`); the second took a fresh claim
*during* the read. This was neither the author's write tail nor the GitHub
MirrorJob.

Sampling continued at 45 s intervals until the traffic stopped. The certifying
pair:

```
READ A  2026-08-22T15:21:58Z  window 7.6s  corpus 6979  closure 711
READ B  2026-08-22T15:23:42Z  window 8.0s  corpus 6979  closure 711
        104 s apart
        appeared 0 · disappeared 0 · moved 0   QUIESCENT
```

**The differ was self-tested on four planted positives before its zeros were
believed** — a moved `_updatedAt`, a moved `_rev` alone, a disappeared row, an
appeared row. All four were detected. A zero from an instrument never shown able
to report a non-zero is indistinguishable from a blind spot.

**Independent corroboration from the run itself: `drifted == []`.** Clause 5
computed no drift over its own read window, so the snapshot the verdict rests on
is coherent — and the run exited 1, not 4.

## 4. The certifying run — executed once, exit code captured directly

```
CWD=<clean tree>
bash scripts/pds-ledger-census.sh --assert-round-done \
     --anchor-from-paper pds-wave-27-2026-07-31 --json > cen.json 2> cen.err; RC=$?

RUN_START=2026-08-22T15:24:41Z
RUN_END=2026-08-22T15:24:59Z
RC=1
stdout 14760 bytes (JSON)   stderr 14452 bytes (human)
```

**`$?` was read directly off the census. Never through a pipe.** The brief
measured `... | tail -20; echo RC=$?` printing `RC=0` over a failing census —
that is `tail`'s exit code, and it is how this epic's own certifying command
lies about the epic's own law.

`--json` was added to the single run because criterion 6 requires the JSON
payload **from the same run**, and under `--json` stdout carries only the
payload while every human line moves to stderr. One run therefore yields the
predicate block, the exit code, and the payload — running twice would have
violated "executed once".

**Criterion 6 — the payload is honest about the run:**

```
jq -e . cen.json          -> exit 0        (pipeable on the red path, not only the green one)
.round_done               -> false
agrees with RC=1          -> true
.round_done_failures      -> 3 entries
```

## 5. The surviving rows — 22, every one named

### 5a. Clause 1 — duplicate reasons: 8 rows, and NOT ONE of them is wave 27

`distinct reason hashes == non-empty reasons` reads `243 == 250 FAIL`. The
surplus of 7 is produced by **exactly one collision group of 8 rows** sharing a
single boilerplate string.

The census reports the counts but never names the rows (`report["duplicates"]`
is the *pagination* duplicate list, and it is empty). The group was therefore
re-derived with the census's own rule — `sha256(" ".join(text.split()))[:16]`,
over `[corpus[i] for i in closure]` — and **the derivation reproduces the
census's own figures exactly: closure 711, non-empty 250, distinct 243, surplus
7.** An extractor that could not hit those three numbers would be reading a
different population.

| doc_id | `_createdAt` | post-anchor |
|---|---|---|
| `pds-w48-react-reference-error-collapse` | 2026-08-05T18:36:11.112601Z | yes |
| `pds-w48-cli-count-and-birth-receipts` | 2026-08-05T18:37:09.176056Z | yes |
| `pds-w48-deploy-banner-descends-from-health` | 2026-08-05T18:37:24.411267Z | yes |
| `pds-w48-meter-rot-and-duplicate-rate-table` | 2026-08-05T18:38:19.513243Z | yes |
| `pds-bl-w48-web-gate-cannot-block-and-greens-vacuously` | 2026-08-05T18:39:52.856844Z | yes |
| `pds-bl-w48-web-sibling-launders` | 2026-08-05T18:40:01.386714Z | yes |
| `pds-bl-w48-deploy-make-and-rebuild-receipts` | 2026-08-05T18:40:15.640288Z | yes |
| `pds-bl-w48-task-create-open-hangs-and-500s` | 2026-08-05T18:40:22.799691Z | yes |

Shared hash `4797f7e5a2555a6e`. Shared reason, in full:

> wave 48 slice — filed open at Decide

**THIS IS THE SECOND-ORDER TRAP, FIRING EXACTLY AS THE BRIEF PREDICTED.** All
eight rows were born 2026-08-05, **five days after** the round anchor
(2026-07-31T00:21:23.535114Z). Clause 4(a) correctly defers them — every one
appears in the 239-row RESIDUE list as the next round's inbox. But **clauses 1,
3, 4(b) and 4(c) are CLOSURE-scoped, not anchor-scoped**: distinctness is a
property of everything ever written. So a later wave's boilerplate reds a round
that closed before those rows existed.

The brief's instruction was to verify wave 27's bare-filing discipline still
holds before blaming the round. **It holds.** The entire surplus of 7 is
accounted for by this one wave-48 group; no wave-27 row contributes to the
clause-1 failure at all.

**REMEDY — and it is not this slice's to apply:** wave 48 must give those eight
rows real reasons. "filed open at Decide" is a filing status, not a reason; it is
the boilerplate clause 1 exists to refuse. Re-wording them from *this* slice
would be exactly the bar-moving PDS-D348 forbids.

### 5b. Clause 6 — the claimable-and-closed contradiction: 1 row

```
live rows NOT dispositioned `closed`   424/425   FAIL   (CLAIMABLE and adjudicated shut)
```

| doc_id | `_createdAt` | `lifecycle_status` | `disposition` | claim |
|---|---|---|---|---|
| `pds-bl-w47-stamp-tripwire-false-positive` | 2026-08-04T13:11:54.773282Z | `open` | `closed` | FREE |

`bp task ready` hands out a row the ledger calls shut, and clause 4(a) counts it
as adjudicated. Also post-anchor (2026-08-04), also a later wave's row. Its
subject — `bp task stamp`'s MERGE-GATED tripwire firing on any criterion that
merely *mentions* merge-gating — is unrelated to wave 27.

**REMEDY:** the row is either open or it is closed. Whichever is true, one of the
two fields is lying, and only its owner can say which.

### 5c. Lapse shape A — reverted to `open` by the TTL sweeper: 13 rows

```
claims NOT lapsed-to-open (shape A)   412/425   FAIL   (re-open lie: 9 carry work evidence)
leases held INSIDE the TTL (shape B)  425/425   PASS   (TTL 2700s, NEVER keyed on expired_at)
open rows with NO stale claim (shape C) 425/425 PASS   (worker SET and closed_at SET)
```

All 13, with the 9 carrying work evidence marked — those were mid-flight when
the sweeper took them:

| doc_id | work evidence |
|---|---|
| `pds-bl-census-exact-pins-tax-growth` | yes |
| `pds-bl-charter-slot-durability` | — |
| `pds-bl-w48-deploy-make-and-rebuild-receipts` | yes |
| `pds-bl-w48-web-sibling-launders` | yes |
| `pds-w25-round-bare` | yes |
| `pds-w27-round-bare-30` | yes |
| `pds-w29-pay-lb` | — |
| `pds-w42-liveview-authorization-column` | yes |
| `pds-w43-liveview-residual-32-fold` | yes |
| `pds-w47-price-column-retake` | — |
| `pds-w49-npm-publish-preflight` | — |
| `pds-w49-published-artifact-door` | yes |
| `task-2c6e0fff8a8a63c9` | yes |

**`pds-w27-round-bare-30` is on this list, and it is one of this round's own four
dependency slices.** Its code is merged (`5a0d7e974d`, PR #8408) while its task
row reads `open` at 8/10 criteria. That is the shape-A lie in one row: the work
landed, the sweeper reverted the claim, and the ledger now shows unstarted work
against a merged PR. It is *also* the reason a reader checking dependencies by
row status rather than by merge would wrongly conclude this round was not ready
to certify.

**REMEDY, quoted from the census:** "re-claim and close on the evidence already
there". Nine of the thirteen already carry it.

## 6. What this run does NOT say

**Criterion 5 did not fire and its statement is deliberately NOT made here.**
That criterion is conditioned on `RC == 0`; RC is 1. Writing the "exit 0
certifies the round and never the epic" paragraph under a red would be asserting
a certificate that was never issued. Criteria 4 and 5 are mutually exclusive
branches — exactly one can ever be met on a given run, and on this run it is 4.

One fact from that criterion was verified anyway, because it is true regardless
of the exit code and cheap to check: **the epic row `task-2ac1f95237c4a8e5` is
absent from the closure, measured** (`root_in_closure=False` over 711 rows).
`build_closure` seeds its frontier with `kids[root]` and never appends `root`, so
the epic row is outside the predicate's population. No run of this command, green
or red, adjudicates it.

## 7. The full predicate block, verbatim

Reproduced exactly as the run emitted it, including the 239-row residue list.

```
ROUND-DONE PREDICATE
  distinct reason hashes == non-empty reasons   243 == 250   FAIL
  non-empty reasons > 0                          250        PASS
  off-vocabulary dispositions == 0               0        PASS
  round anchor                                  2026-07-31T00:21:23.535114Z   (paper/pds-wave-27-2026-07-31 _createdAt 2026-07-31T00:21:23.535114Z)
  live rows carrying a disposition               186/425    PASS
  ^ deferred to the next round (RESIDUE)        239        next-round inbox
      residue: pds-bl-advisory-enrolment-table-unguarded
      residue: pds-bl-anchor-retirement-after-both-fences
      residue: pds-bl-callee-clause-collapse-68-groups
      residue: pds-bl-cas-int-tuple-spelling-blind
      residue: pds-bl-census-ast-scan-blind-to-func-values
      residue: pds-bl-census-exact-pins-tax-growth
      residue: pds-bl-census-files-from-truncation
      residue: pds-bl-census-kind-vanished-double-reports
      residue: pds-bl-census-runs-in-no-ci-gate
      residue: pds-bl-charter-d399-duplicate-identifier
      residue: pds-bl-charter-says-opaque-callers
      residue: pds-bl-chat-approve-unreachable-204-arm
      residue: pds-bl-deprovision-blast-radius-crosses-orgs
      residue: pds-bl-elixir-claims-reach-no-repo-verb
      residue: pds-bl-fixtures-only-pr-runs-no-go-job
      residue: pds-bl-flash-redirect-success-class
      residue: pds-bl-go-basis-wording-embellishment-hole
      residue: pds-bl-go-tests-not-required
      residue: pds-bl-grip-adoption-governance
      residue: pds-bl-grip-screen-refuses-honest-read-commands
      residue: pds-bl-has-select-in-update-unsound
      residue: pds-bl-hermetic-vacuous-green
      residue: pds-bl-isprod-guard-never-fires-on-guerrilla
      residue: pds-bl-lb-byname-pin-generalize
      residue: pds-bl-live-runners-duplicated
      residue: pds-bl-mcp-exec-bypasses-write-fence
      residue: pds-bl-mutate-patch-still-forks-published-tasks
      residue: pds-bl-null-expiry-claims-repo-wide
      residue: pds-bl-ok-true-arrival-tripwire
      residue: pds-bl-response-carries-the-read-arm
      residue: pds-bl-route-depth-split-two-numbers
      residue: pds-bl-sentinel-ok-returner-population
      residue: pds-bl-shard-count-gate-reads-a-prefix
      residue: pds-bl-single-caller-attribution-unfalsifiable
      residue: pds-bl-stale-open-rows-with-merged-prs
      residue: pds-bl-task-create-draft-at-rc0
      residue: pds-bl-task-criteria-publish-label-spine-opacity
      residue: pds-bl-taskboard-fetchpaper-unfenced
      residue: pds-bl-upsert-insert-branch-ungated-birth
      residue: pds-bl-w2-w5-product-ground-map
      residue: pds-bl-w30-ledger-reconciliation
      residue: pds-bl-w36-census-blind-flash
      residue: pds-bl-w36-defimpl-key-blind
      residue: pds-bl-w36-groupc-remainder
      residue: pds-bl-w36-no-guardable-marker
      residue: pds-bl-w36-record6-conflation
      residue: pds-bl-w36-scim-lens-blind
      residue: pds-bl-w37-mutate-the-unmutated-nine
      residue: pds-bl-w37-persist-fun-seam-defeats-the-falsifier
      residue: pds-bl-w37-sobelow-clearing-breakdown-blindspot
      residue: pds-bl-w37-tier2-basis-falsifiers
      residue: pds-bl-w37-webhook-currency-remainder
      residue: pds-bl-w38-census-citations-drift-blind
      residue: pds-bl-w38-census-gate-fence-handoff
      residue: pds-bl-w38-outside-emission-population
      residue: pds-bl-w39-liveview-handle-event-population
      residue: pds-bl-w39-opaque-exclusion-row-unfalsifiable
      residue: pds-bl-w39-record-parity-61-reds-owner-report
      residue: pds-bl-w39-record-parity-leaf-count-conflates
      residue: pds-bl-w39-status-only-receipt-is-a-misnomer
      residue: pds-bl-w41-caps-comprehensiveness-blind
      residue: pds-bl-w41-charter-43-27-unreproducible
      residue: pds-bl-w41-clause-precedence-mask
      residue: pds-bl-w41-error-branch-verdicts
      residue: pds-bl-w41-exclusion-class-atom-ungated
      residue: pds-bl-w41-livescope-component-bypass-unrun
      residue: pds-bl-w41-partition-arm-class-blind
      residue: pds-bl-w41-scim-deprovision-fence-unpinned
      residue: pds-bl-w47-census-doc-headroom-spent
      residue: pds-bl-w47-duplicate-d-allocation-pointer
      residue: pds-bl-w47-hetzner-offline-door-rescoped
      residue: pds-bl-w47-measure-all-content-key-price-stale
      residue: pds-bl-w47-receipt-census-never-issues-a-request
      residue: pds-bl-w47-stale-claim-third-shape-rescoped
      residue: pds-bl-w48-deploy-make-and-rebuild-receipts
      residue: pds-bl-w48-find-suggestions-empty-is-not-a-measurement
      residue: pds-bl-w48-search-seed-empty-index-is-not-a-measurement
      residue: pds-bl-w48-task-create-open-hangs-and-500s
      residue: pds-bl-w48-web-gate-cannot-block-and-greens-vacuously
      residue: pds-bl-w48-web-sibling-launders
      residue: pds-bl-w49-budget-literal-moved-by-its-own-pr
      residue: pds-bl-w49-changeset-version-cannot-run
      residue: pds-bl-w49-cli-release-cadence-gate
      residue: pds-bl-w49-core-auth-collapses-403-as-unauthenticated
      residue: pds-bl-w49-js-claudemd-asserts-a-gate-that-cannot-block
      residue: pds-bl-w49-meter-shares-verb-and-two-fail-opens
      residue: pds-bl-w49-paper-publish-gate-arms-on-a-key-name
      residue: pds-bl-w49-post-flip-curl-only-logged
      residue: pds-bl-w49-prebuilt-checksum-gate-is-structurally-unreached
      residue: pds-bl-w49-preview-dist-tag
      residue: pds-bl-w49-sdk-readme-advertises-a-package-that-does-not-exist
      residue: pds-bl-w7a-lifecycle-check-enum-drift
      residue: pds-bl-write-redirect-downgrade
      residue: pds-bl-wrongpath-arm-blind-to-wrong-id-2
      residue: pds-d-number-allocation-arbiter
      residue: pds-document-block-op-withheld-id
      residue: pds-scoped-search-intel-receipts-unpinned
      residue: pds-w28-bl-backup-restore-ignores-its-own-manifest
      residue: pds-w28-bl-birth-warn-to-hard
      residue: pds-w28-bl-grip-exec-path-admitted
      residue: pds-w28-bl-grip-silent-predicate-null-read
      residue: pds-w28-bl-rerun-backfill-19-prose-reasons
      residue: pds-w28-bl-round-bare-30-criterion-7-unsatisfiable
      residue: pds-w28-bl-two-rerun-screens-drift
      residue: pds-w28-census-check-count-citations-stale
      residue: pds-w28-named-codes-invisible-in-human-shapes
      residue: pds-w29-bl-disposition-schema-invisible
      residue: pds-w29-bl-drafts-in-ready-handoff
      residue: pds-w29-bl-grip-count-uncompared
      residue: pds-w29-bl-grip-git-grep-absence-fail-open
      residue: pds-w29-bl-grip-go-fault-as-refutation
      residue: pds-w29-bl-grip-stored-rerun-never-read
      residue: pds-w29-bl-twin-policy-split
      residue: pds-w29-bl-w27-size-ceiling-contradicted
      residue: pds-w29-builtin-verbs-bypass-write-fence
      residue: pds-w29-pay-lb
      residue: pds-w30-anonymous-read-preflight-audit
      residue: pds-w30-hcloud-context-rung-dead-on-macos
      residue: pds-w31-hzread-swallows-stderr
      residue: pds-w33-async-shared-sandbox-flake
      residue: pds-w33-bl-bucket-the-64-write-receipts
      residue: pds-w33-bl-catchall-success-clauses
      residue: pds-w33-bl-census-blind-to-generic-instantiation
      residue: pds-w33-bl-census-primitives-fail-silently
      residue: pds-w33-bl-dedup-gate-backlog-scan-crashes
      residue: pds-w33-bl-detail-lines-uncapped
      residue: pds-w33-bl-discarded-postread-paper-rev
      residue: pds-w33-bl-elixir-census-arm-two-hop-binding
      residue: pds-w33-bl-firewall-create-unreachable-guard
      residue: pds-w33-bl-live-mutation-refusal-postread
      residue: pds-w33-bl-mutate-error-typed-map
      residue: pds-w33-bl-notreadable-hint-names-no-real-verb
      residue: pds-w33-bl-publish-wall-codes-exit-1
      residue: pds-w33-bl-wave-log-routing-and-zero-readers
      residue: pds-w33-bl-whole-file-paid-grep
      residue: pds-w33-bl-wrong-row-mutate-forks-published-tasks
      residue: pds-w34-hand-bucket-register
      residue: pds-w35-elixir-census-gate
      residue: pds-w36-reset-receipt-count-downstream
      residue: pds-w37-api-logout-unread-revoke
      residue: pds-w37-roster-stale-on-merge
      residue: pds-w37-selftest-zero-row-floor
      residue: pds-w37-two-hop-repo-probe
      residue: pds-w38-record-parity-ci-lane
      residue: pds-w38-scim-groups-list-members
      residue: pds-w39-charter-ledger-corrections-owed
      residue: pds-w39-lens-closes-two-false-exclusions
      residue: pds-w39-literal-receipt-residue
      residue: pds-w39-release-scan-walk-predicate
      residue: pds-w39-roster-fresh-callee-blindspot
      residue: pds-w39-routed-disposition-regen
      residue: pds-w39-shadow-disposition-arm
      residue: pds-w39-status-only-receipts
      residue: pds-w39-vocab-text-overclaim
      residue: pds-w40-bl-blind-shape-block-refuted
      residue: pds-w40-bl-body-bound-provenance
      residue: pds-w40-bl-census-ci-lane-policy-cut
      residue: pds-w40-bl-exclusion-freshness-arm
      residue: pds-w40-bl-item-share-silent-noop
      residue: pds-w40-bl-ledger-n1-free-closes
      residue: pds-w40-bl-shares-env-row-no-affordance
      residue: pds-w40-judgment-coverage-ladder
      residue: pds-w42-bl-caps-derive-per-op-cost-unmeasured
      residue: pds-w42-bl-census-prose-outlives-its-code
      residue: pds-w42-bl-chatlive-routed-clauses-ungated
      residue: pds-w42-bl-grant-graded-component-arm-unbuilt
      residue: pds-w42-bl-handle-info-write-seam-audit
      residue: pds-w42-bl-liveview-derivation-anchor
      residue: pds-w42-bl-paper-canvas-path-unmeasured
      residue: pds-w42-bl-presence-writes-outside-readonly-wall
      residue: pds-w42-bl-tree-codelist-readonly-guard-inert
      residue: pds-w42-caps-prop-is-a-mount-snapshot
      residue: pds-w42-liveview-authorization-column
      residue: pds-w42-liveview-residual-32-plugin-session
      residue: pds-w42-minted-decides-exact
      residue: pds-w42-sheetgrid-read-mode-hook
      residue: pds-w43-bl-blind-spot-sentence-is-a-mechanism
      residue: pds-w43-bl-charter-ledger-sweep-content-red
      residue: pds-w43-bl-github-bridge-synced-rev-lies
      residue: pds-w43-bl-grant-grade-doc-escalation-unproven
      residue: pds-w43-bl-heuristic-column-bounds
      residue: pds-w43-bl-lapse-lens-drafts-undercount-unmeasured
      residue: pds-w43-bl-ledger-census-exunit-door
      residue: pds-w43-bl-ledger-census-readback-arm
      residue: pds-w43-bl-sheetgrid-hook-harness-ungated
      residue: pds-w43-bl-sheetgrid-reader-half
      residue: pds-w43-bl-stale-claim-third-shape
      residue: pds-w43-bl-stamp-readback-blind-to-draft
      residue: pds-w43-judgment-coverage-ladder
      residue: pds-w43-liveview-residual-32-fold
      residue: pds-w44-bl-citation-precedes-merge-check
      residue: pds-w44-bl-ledger-census-door-repriced
      residue: pds-w44-bl-ops-controller-apply-ops-ungated
      residue: pds-w44-bl-sheetgrid-write-landing-unproven
      residue: pds-w44-bl-stranded-work-is-invisible-to-git-grep
      residue: pds-w44-bl-vacuous-reader-toggle-oracle
      residue: pds-w44-d605-doc-label-drift
      residue: pds-w44-hetzner-offline-door
      residue: pds-w45-argspan-sigil-and-silent-bound
      residue: pds-w45-bl-foreign-runner-first-door
      residue: pds-w45-bl-grant-door-untested-arms
      residue: pds-w45-bl-ledger-census-lazy-urllib
      residue: pds-w45-bl-scratch-target-class-refuted
      residue: pds-w45-price-provenance
      residue: pds-w46-bl-census-own-price-measures-the-wrong-arm
      residue: pds-w46-bl-go-tests-testdata-carveout
      residue: pds-w46-load-stamp-provenance-doubt
      residue: pds-w46-retired-evidence-whitespace-passes
      residue: pds-w46-selftest-floor-multiplier-undelivered
      residue: pds-w46-sweep-idiom-exclusion-lens-repair
      residue: pds-w47-price-column-retake
      residue: pds-w47-price-freshness-silence
      residue: pds-w48-createifnotexists-probe
      residue: pds-w48-retake-price-classed-rows
      residue: pds-w49-instrument-run-map
      residue: pds-w49-meter-ci-decision
      residue: pds-w49-meter-per-model-recompute
      residue: pds-w49-npm-publish-preflight
      residue: pds-w49-published-artifact-door
      residue: pds-w49-scratch-target-class-vs-its-own-price
      residue: pds-w49-self-erasing-lens
      residue: task-114768618bf29ae0
      residue: task-2abbac8d7975050c
      residue: task-2c6e0fff8a8a63c9
      residue: task-441f5a5669e0ab6b
      residue: task-496b413263c754c5
      residue: task-50ea16eb76c8f5c9
      residue: task-545e4a6e4e78925c
      residue: task-5a3b22be679c826a
      residue: task-6a07d368aa2eee73
      residue: task-6ac7f97249b746f6
      residue: task-869b52af6f4e4153
      residue: task-9e2c61a0979657ae
      residue: task-aa1194c2c4aac214
      residue: task-ac55ff2388510d67
      residue: task-e4f1d8e178509fc9
      residue: task-f7e4d6ff8dbbcf80
      residue: task-fbdf8011a1721236
      residue: task-pds-support-online-roster-fact-on-success
  live adjudicated rows carrying a reason        186/186    PASS
  live parked rows carrying a reopen_trigger     28/28    PASS   (STRUCTURED field, not prose)
  live rows NOT dispositioned `closed`           424/425    FAIL   (CLAIMABLE and adjudicated shut)
  claims NOT lapsed-to-open (shape A)           412/425    FAIL   (re-open lie: 9 carry work evidence)
  leases held INSIDE the TTL (shape B)          425/425    PASS   (TTL 2700s, NEVER keyed on expired_at)
  open rows with NO stale claim (shape C)       425/425    PASS   (worker SET and closed_at SET)

VERDICT: ROUND NOT DONE
  - 7 duplicate reason(s): 250 non-empty reasons collapse to 243 hashes -- boilerplate is not a reason
  - 1 LIVE row(s) are CLAIMABLE and dispositioned `closed` -- `bp task ready` hands out a row the ledger calls shut, and clause 4(a) counts it as adjudicated: pds-bl-w47-stamp-tripwire-false-positive
  - 13 row(s) are SHAPE A -- reverted to `open` by the TTL sweeper with the claim's previous_worker and expired_at still on them (9 carry a now-line, so the work was mid-flight). REMEDY: re-claim and close on the evidence already there: pds-bl-census-exact-pins-tax-growth, pds-bl-charter-slot-durability, pds-bl-w48-deploy-make-and-rebuild-receipts, pds-bl-w48-web-sibling-launders, pds-w25-round-bare, pds-w27-round-bare-30, pds-w29-pay-lb, pds-w42-liveview-authorization-column, ...
```
