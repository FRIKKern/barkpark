# `content.surface` backfill — the 40 open rows that carried no value

Written 2026-09-22T16:40Z–16:49Z against the LIVE ledger (`guerrilla.barkpark.cloud`).
Task `task-6d86c8dbf030e652`. Input: charter **D905** and
`tooling/grip/ledger/cch-surface-enum-vocabulary-and-48-value-map-2026-09-22.md` (PR #19870).

**38 rows written, 2 left ABSENT on purpose.** Every value was chosen by reading the row;
every write was read back from the store and the stored value is quoted below.

## 0 — THE INPUT MAP DOES NOT COVER THIS POPULATION, and says so itself

The ordering brief calls the 48-value map "explicitly the input to YOUR row". It is the
input to the VOCABULARY, not to the values: that table maps the 45 PROSE `surface` strings
already stored on 45 rows onto the enum. This row's population is the rows that carry NO
`surface` at all, and #19870's own §4(b) states the boundary in one sentence:

> §3 maps the 45 prose values and the 3 in-vocabulary ones — it does not value the rows
> that carry NO `surface` at all, which is where that 98.6% lives.

The two populations intersect in ZERO rows. What #19870 supplies, and what this backfill
used, is its ordered classification RULE and its three §3c rulings — not a per-row lookup.
No row below could have been read off that table, and none was.

## 1 — POPULATION, re-derived at execution time (criterion 0)

    for P in cloud-console-hardening-epic cch-instruments-epic; do
      bp task ls --parent "$P" --all -o json > ls-$P.json          # --all, not limit=100
    done
    jq -s '[.[].docs[]]|unique_by(.doc_id)' ls-*.json > ALL.json   # 1279 lifetime children
    jq '[.[]|select(.lifecycle_status=="open" and .content.surface==null)]|length' ALL.json

| | 2026-09-22T12:3xZ (brief) | 2026-09-22T16:37Z (this run) |
|---|---|---|
| lifetime children of the two epics | 1279 | **1279** |
| `lifecycle_status == "open"` | 48 | **44** |
| of those, carrying `content.surface` | 5 | **4** |
| of those, LACKING it — the population | **43** | **40** |

The 1279 and the 43-of-48 both RECONCILE EXACTLY, and the reconciliation is the evidence
that the re-derivation measured the same thing the brief did:

* Zero children were CREATED under either epic after 12:00Z, so the population only shrank.
* Four rows left the open set between 12:3xZ and 16:37Z. THREE were in the 43:

| Row | Left at | Why it dropped |
|---|---|---|
| `task-011476f035a21196` | 2026-09-22T12:45:23Z | closed `done` |
| `cch-bl-scroll-driven-cue-firefox-fallback` | 2026-09-22T16:00:49Z | closed `done` |
| `cch-w44-bl-console-gate-nothing-ran-notice-can-be-truncated-away` | 2026-09-22T16:35:46Z | closed `done` |

  43 − 3 = **40**. The fourth, `cchi-w27-bl-d307-create-time-door-guard` (cancelled
  12:42:37Z), was one of the FIVE that already had a value — it is #31 on #19870's map —
  so it reduces the 48 and the 5 but not the 43.

* A FIFTH row sits at `lifecycle_status: considering`, not `open`:
  `cloud-console-operator-audit-log` (CCH, last touched 2026-07-23). 44 open + 1 considering
  = 45, which is the "45 open" #19870 read at 16:06Z (its "10 CCH" = 9 open + this one).
  The brief's 48 counted `open` only, so this row is OUT OF SCOPE here and was NOT written.
  Naming it because "open" silently means two different things across the three documents.

## 2 — THE RULE APPLIED (criterion 1)

D905's vocabulary, and #19870 §3's ordered rule: (a) whose artifact is it — the product a
customer operates (`console`), this campaign's measuring apparatus (`instrument`), or the
task roster and its filing law (`ledger`); (b) tie-break — take the OUTCOME's owner, except
that a row whose entire deliverable is coverage or measurement, changing nothing outside the
campaign, is `instrument`.

**No value was taken from a doc_id.** The population is 30 slug ids and 10 `task-<hash>` ids;
the hash ids split 9 `instrument` / 1 ABSENT and the slugs carry all 9 `console` and all 6
`ledger`, so the id shape predicted nothing and was not consulted. The sentence that chose
each value is quoted in §3, and in every case it is a sentence about the ARTIFACT THE ROW
CHANGES, never about the subject matter it discusses — that distinction is what separates
rows 17 and 30 (deliverable is a test file → `instrument`) from rows 28 and 31 (deliverable
is product behaviour a customer meets → `console`).

One more guard on the direction, used wherever (a) and (b) disagreed: D905 records the enum
as a ONE-WAY guarantee. `instrument`/`ledger` PROMISE that no person outside this campaign
meets the artifact; `console` promises only that the artifact IS the product. So where a row
could be read either way, the safe error is `console` — a false `console` costs a D307
refusal that should have fired, while a false `instrument` states something untrue.

## 3 — THE 40 ROWS: value, the sentence that chose it, and the value READ BACK

`READ BACK` is a fresh `bp task get <id> -o json | jq -r .doc.content.surface` issued after
each write, quoted from the store — never from the write receipt (criterion 3). All reads are
`.doc.content.surface`; `.doc.surface` returns empty on every row and would have read as
ABSENT everywhere.

### 3a — `console` (9 rows)

| # | Row | The sentence in the row that chose it | READ BACK |
|---|---|---|---|
| 5 | `cch-hg-compose-network-recreation` | criterion 2: "A fresh sign-in writes a user_tokens row carrying the REAL client IP … the L1 proof the peer-ip pin actually works in production" — the deliverable is production behaviour a customer's sign-in meets | `console` |
| 6 | `cch-rtl-script-neutral-borrowing` | "real on the two hosts where user text and system text share one inline run: activityRow fleet-name and memberRowHtml set-row-name" — the SPA renders it | `console` |
| 9 | `cch-w20-bl-console-touch-target-comfort-44px` | "738 of 810 rendered control instances are under 44x44, on ALL FIVE routes" — the controls a person taps | `console` |
| 10 | `cch-w34-bl-lower-recipient-index` | "The fix is an index on (team_id, lower(recipient), inserted_at) … It NEEDS A MIGRATION on an auto-deploying surface" — the product's own delivery read | `console` |
| 15 | `cch-w70-bl-worker-url-backfill-gated-on-prod-dup-scan` | "this row owns the stored rows … A backfill UPDATE barkparks SET url = <normalised>" — the deliverable is the product's production data | `console` |
| 16 | `cch-w71-bl-bootstrap-vercel-mint-403-raw-dump` | criterion 0: "Both token-mint 403 consumers render the forbidden required/scope role sentence instead of a raw status snippet" — copy in `internal/bootstrap` and `internal/cli`, D905's "a CLI cell" | `console` |
| 26 | `cchi-w62-reveal-admin-token-doc-claims-a-single-caller` | criterion 0: "registry.ex reveal_admin_token/1 @doc no longer claims /credentials is the only caller" — the artifact edited is control-plane product source; see §5(a) | `console` |
| 28 | `gr-backlog-qr-live-scan-proof` | "a user must be able to enrol 2FA from the rendered modal", and criterion 2 may change the product's named fallback path — a person outside this campaign meets it | `console` |
| 31 | `gr-blk-cp-deploy-rollback-stale-env` | "a rollback via docker start would serve a container where [PLATFORM_ADMIN_EMAILS] is still unset — silently disabling operator access" — the consequence lands on live traffic | `console` |

### 3b — `ledger` (6 rows)

| # | Row | The sentence in the row that chose it | READ BACK |
|---|---|---|---|
| 2 | `cch-bl-live-count-criteria-must-be-deltas-not-absolute-floors` | its own tag rationale: "the defect is in how task acceptance criteria are authored"; the fix is "author live-count criteria as DELTAS" | `ledger` |
| 7 | `cch-w12-bl-mirror-syncs-unpublished-drafts` | "`bp task create` produced documents at status: draft … an open issue with no ledger row behind it" — the roster's create door | `ledger` |
| 8 | `cch-w16-bl-publish-door-has-no-published-row-cas` | "publishing a draft that is stale on a proof-bearing criterion is now REFUSED with a 422 naming the exact criterion index" — the filing law over criteria | `ledger` |
| 19 | `cchi-w26-bl-stranded-draft-is-a-silent-plus-one` | "Publishing that first draft would raise orphans 112 -> 113 with NO new filing and NO new work" — orphan count, D905's own example | `ledger` |
| 20 | `cchi-w40-bl-newlaunch-plan-limit-row-is-two-thirds-paid` | "ROSTER HYGIENE, filed so a future false-open sweep does not close a live criterion by mistake" | **NOT WRITTEN — see §4** |
| 22 | `cchi-w46-bl-lapsed-claim-arrears-close-path` | "The DECIDE phase re-claims shipped rows to perfect their briefs, then lapses — OVERWRITING the builder's claim" — claim + stamp | `ledger` |

### 3c — `instrument` (24 rows)

| # | Row | The sentence in the row that chose it | READ BACK |
|---|---|---|---|
| 1 | `cch-bl-citation-drift-cross-language` | "Extend coverage to cloud/lib/**/*.ex citations, which likely requires hosting in scripts/docs-anchors-check.sh … and to doc-gates.yml's path filters" | `instrument` |
| 3 | `cch-bl-nul-native-path-matcher` | "a --null flag on the four *-path-escape-check.sh scripts" — the diff producer inside four CI gates | `instrument` |
| 4 | `cch-bl-preview-selector-residue` | "cch-w10 widened the smoke shim's ELEMENT-level selector grammar" — the preview harness's own shim | `instrument` |
| 11 | `cch-w37-bl-binding-census-drift-arm` | "The binding census gains a DRIFT arm, once an oracle exists that can see inline-cond refusals" | `instrument` |
| 12 | `cch-w37-bl-register-spec-gate-human-gate` | "Register the spec gate as the fifth required context" — D905 lists required-check under `instrument` | `instrument` |
| 13 | `cch-w42-bl-elixir-gate-reporter-and-attribution-loss` | "Decide whether elixir.yml earns the same job-level reporter" — a CI gate's reporting | `instrument` |
| 14 | `cch-w57-fu-exclusion-acks-are-typed-by-hand-every-regeneration` | "a human regenerating the spec must now paste seven flags" — the required-checks generator | `instrument` |
| 17 | `cch-w73-bl-newcreaterepo-success-fields-unasserted` | "TEST-ONLY, a source-text assertion … do NOT drive it, and do NOT change app.js" — the artifact changed is `__app.test.mjs` | `instrument` |
| 18 | `cchi-bl-protection-claim-paraphrase-escape` | "widen or replace section 18's protection-claim census" in `scripts/required-checks.test.sh` | `instrument` |
| 21 | `cchi-w40-bl-refusal-copy-census-verdict-drift-arm` | "cch-w40-s2's census gates ADD and REMOVE over a keyed set. Its per-row verdicts … are printed but NOT gated" | `instrument` |
| 23 | `cchi-w47-bl-inline-cond-overlay-pairs-route-to-line-by-source-order` | "The census would print six true numbers under six wrong labels" — the overlay's own output | `instrument` |
| 24 | `cchi-w57-blocking-shaped-name-census-guard` | "This row converts the concession into something that can lose" — a census guard over the required-checks spec | `instrument` |
| 25 | `cchi-w61-main-gate-watch-runstatus-is-per-tip-not-per-context` | "Residual accepted by wave 61 and stated in scripts/main-gate-watch.sh's header" | `instrument` |
| 27 | `cchi-w68-bl-merge-gate-autostamp-has-no-product-reader` | "The instrument-class remedy: add the key to the reader-less instrument census @register … The SURFACE-class remedy … is a separate later-wave slice — do not fold it in here." The row scopes ITSELF to the instrument half | `instrument` |
| 29 | `gr-backlog-scenario-drive-field` | its own tag rationale: "Lives entirely in cloud/priv/static/__preview__ — the Cloud console preview harness" | `instrument` |
| 30 | `gr-backlog-tfa-confirm-throttle` | criterion 1: "No limiter is added to authenticated enrollment" — the product is deliberately NOT changed; criteria 0 and 2 ship only tests | `instrument` |
| 32 | `task-0217190472c7aad7` | "seal-predicate.mjs asserts repo freshness against origin/main at START" — the epic's own seal instrument | `instrument` |
| 33 | `task-13f830a9c36314e0` | "correct the W19-S2 entry in place" in `cssom-heads.baseline` — the parity instrument's sidecar | `instrument` |
| 34 | `task-3c620a8d3b603128` | "seal-predicate's clause-(a) `forwarded` bucket is structurally unreachable" — the defect is IN the instrument | `instrument` |
| 35 | `task-3e2226c69000587d` | "The single red under Node 22 IS the self-check … not a console defect" — the predicate's own runtime handling | `instrument` |
| 36 | `task-60c35a2da304c080` | "In cloud/priv/static/__preview__/member-authority-sweep.mjs the HOOKS row … is mis-typed and invisible" | `instrument` |
| 37 | `task-b579afe77276b4f8` | "cloud/priv/static/__preview__/smoke.mjs asserts … that negative assertion is over a class that no longer exists … VACUOUSLY green" | `instrument` |
| 38 | `task-b881189fa7f7395d` | "The checker exists and is proven in both directions, but NOTHING RUNS IT" — `scripts/file-line-citation-check.mjs` plus the charter | `instrument` |
| 40 | `task-fe3eb44ff42410c5` | "this is a COVERAGE GAP in the guard, not a shipped defect … NO user-visible dishonest refusal is hidden" | `instrument` |

## 4 — THE TWO ROWS LEFT ABSENT, and why each is correct rather than short

Criterion 1 requires a row whose value cannot be determined from its own content to be left
ABSENT and listed. Two rows are unfilled, for two DIFFERENT reasons, and only one of them is
the criterion's reason.

**(a) `task-e4289e4c30bb6eff` — UNDECIDABLE from the row. No value written.**
"ensure-console-hook-zones.scaffy: mirror the zone-anchor guard prose into op 3, add the
ASSERT CMD postcondition, and re-seed barkpark--console-hook-zones--js". Rule (a) and the
row's own criteria point in opposite directions and the row never says which it means:

* `console` — criterion 1 is `go run ./scaffy/seed --check reads MATCH for
  barkpark--console-hook-zones--js after the re-seed`. The re-seed writes the SERVED scaffy
  catalog, which is a Barkpark product surface that people outside this campaign consume.
  Writing `instrument` here would assert D905's one-way guarantee ("no person outside this
  campaign meets this") over a served catalog entry, and that assertion would be false.
* `instrument` — the template's entire CONTENT is this campaign's console-harness test-zone
  scaffolding, and criterion 0 adds `ASSERT CMD "node scripts/console-tdz-order-check.mjs
  cloud/priv/static/__app.test.mjs"`. Nothing a customer does reaches that command, and a
  scaffy template is literally a generator, which D905 lists under `instrument`.

Both readings are supported by the row's own text and nothing in it discriminates. A guess
here would be the exact failure the criterion names — a wrong value that LOOKS decided.
**This one wants a lead ruling, not more reading.**

**(b) `cchi-w40-bl-newlaunch-plan-limit-row-is-two-thirds-paid` — DECIDED `ledger`, REFUSED
by the write door.** The value is not in doubt ("ROSTER HYGIENE, filed so a future false-open
sweep does not close a live criterion by mistake"). The server refused the patch, twice,
`validation_failed`, request_id `GNeygyrG-e_fP9EAAMHh`:

> a draft twin `drafts.cchi-w40-bl-newlaunch-plan-limit-row-is-two-thirds-paid` already
> exists for the published task … Patching through it would return 200 for a write nothing
> reads, and landing this patch on the published row would silently destroy the twin.
> Resolve the fork first — `discardDraft` … or `publish` … then resend this patch.

The twin is real, read WITHOUT touching it: `_createdAt` and `_updatedAt` both
`2026-08-09T13:21:11.011338Z`, `_rev 44ff58596d795994959d2ca98542b271`, never edited since
the day it was forked. Resolving the fork means discarding or publishing another lane's
unpublished draft — a lifecycle act this row explicitly forbids ("You write ONE field"), and
`discardDraft` is destructive. **So the refusal stands and the row is left ABSENT.**

THE IRONY IS THE FINDING: this is precisely the hazard described by
`cchi-w26-bl-stranded-draft-is-a-silent-plus-one` (row 19, written `ledger` in this same
pass) — "any future parent_id census … over-counts by the number of stale drafts". Here the
stranded draft did not merely inflate a count; it BLOCKED a write. That row's general-hazard
paragraph can now name a second consequence, with this request_id as its specimen.

Note also what the refusal proves about the other 38: the door rejects a patch whenever a
draft twin exists, so 38 clean `rc=0` writes are 38 rows with no stranded twin. The door
was the control, not an assumption.

## 5 — WHAT ELSE MOVED, measured not asserted (criterion 2)

**The met-set diff is EMPTY.** Before every write, `bp task get` was captured for all 40 rows
and flattened to `<doc_id, index, met, text[0:60]>` — 124 criteria, 6 met. The same flattening
after the writes is BYTE-IDENTICAL: `diff` produces no output, 124 criteria, 6 met. No
criterion was stamped, un-stamped, added, removed or reworded, and `doc.criteria_progress`
did not move on any row. `content.claim`, `lifecycle_status`, `priority`, `assignee`,
`content.criteria` and `content.disposition` are unchanged on all 40.

**The comparator was controlled**: mutating one field of one after-copy (`priority="CONTROL"`)
makes the same comparison report a difference, so an empty diff is a measurement, not a
blind reader.

**The two ABSENT rows are byte-identical before to after**, whole `content` object. That is
the second control: the changes below occur only where a write landed.

TWO SERVER-SIDE SIDE EFFECTS FOLLOW A PATCH. Neither is something this row authored, both are
named here rather than left for someone to discover:

1. **`content.github.synced_fingerprint` / `synced_rev` changed on 36 of the 38 written rows**
   — the GitHub mirror's bookkeeping, re-derived because the document revved. On the other 2
   (`task-b579afe77276b4f8`, `task-b881189fa7f7395d`) the whole `github` object is unchanged;
   both DO carry the field, so the difference is that the mirror did not re-sync them in this
   window, not that they lack it. No `issue`, `repo`, `state` or `parent_marker` value changed
   anywhere.
2. **`content.brief` was RE-DERIVED on 3 rows** — `cch-bl-preview-selector-residue`,
   `cchi-w57-blocking-shaped-name-census-guard`, `task-13f830a9c36314e0`. On all three the
   stored brief was STALE and the patch refreshed it from the row's current `description`:

   | Row | brief BEFORE | brief AFTER |
   |---|---|---|
   | `cch-bl-preview-selector-residue` | "Complete the work described by “…” and record verifiable evidence." (a placeholder) | the description, verbatim |
   | `task-13f830a9c36314e0` | `"short"` | the description |
   | `cchi-w57-blocking-shaped-name-census-guard` | the body WITHOUT its "TWO LIVE SPECIMENS" appendix | the body WITH it |

   Verified LOSSLESS in the only direction that matters: diffing each refreshed brief against
   its own `description` leaves ONLY stripped markdown backticks (the brief is the plain-text
   rendering). Nothing was truncated and no earlier text was dropped — all three moved
   stale → current. Flagged anyway, because a lane reading `content.brief` on those three rows
   will see text it did not write.

## 6 — NOT DONE, named

* **No criterion was stamped, and no row was claimed, pulsed, closed or cancelled.** Not on
  the 38 written rows, not on `task-6d86c8dbf030e652` itself.
* **The D307 guard was NOT armed** and no refusal was promoted. D307 criterion 2 requires
  this backfill to land first; `cch-w28-s4-followup-promote-absent-surface-to-hard` still
  holds the promotion.
* **`cloud-console-operator-audit-log` was not written** — `lifecycle_status: considering`,
  outside the brief's "open" population (§1).
* **The 45 prose `surface` values were not normalised.** They are #19870's population, not
  this row's, and the enum's write door grandfathers an unchanged value on update.
* **The stranded draft twin in §4(b) was not discarded or published**, and the
  `cch-instruments-epic` write-door gap (`task-29b971932b045394`) was not closed.
* **No live create was issued** to probe the 422 off-vocabulary refusal; every value written
  is in-vocabulary and the door accepted all 38, which is the only evidence claimed.
