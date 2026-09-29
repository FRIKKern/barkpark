# `content.surface` — the vocabulary, the D307 six-row test, and the full 48-value map

Measured 2026-09-22T16:06Z against the LIVE ledger (`guerrilla.barkpark.cloud`) and
against `origin/main` `fe6f4b11b` in a throwaway worktree. Task `task-65292b745313f83f`.
Every table below is a read, not a recollection. This file is the BACKFILL's input:
a value left off it is a row the backfill cannot place.

## 0 — What was already true before this row, and what was not

The enum this row was asked to DESIGN already exists and already refuses: charter
**D331** (wave 28) minted `console | instrument | ledger` and armed it at
`Barkpark.Content.Writer.ensure_task_surface_declared/5`; **D339** (wave 29) measured it
live and named a patch-then-publish bypass, since CLOSED by deleting the `nil = prev_doc`
clause head (`writer.ex:1535`, comment block `:1476-1531`). So criterion 3 of this row was
paid two waves before the row was written.

THREE THINGS WERE NOT DONE, and they are what this file adds:

1. The members' meanings exist only as a SOURCE COMMENT (`writer.ex:1480-1485`) and inside
   a refusal string (`:1611-1613`). A comment is not a charter decision, and the comment
   answers "what does the word mean" without answering D307's actual question — which
   direction the classification is a GUARANTEE in.
2. **The candidate was never tested against D307's own six.** D331 measured classifier
   accuracy over 15 rows; nobody ran the six that killed D307. §2 runs it.
3. **The 48 values were never mapped.** D331/D339 recorded the backfill as "not
   mechanically producible" — TRUE of an automatic classifier and IRRELEVANT to a read.
   §3 maps all 48 by reading the rows.

## 1 — Re-derivation: the population, the 48, the 15 colliding tokens

    B=https://guerrilla.barkpark.cloud/v1/tasks
    for P in cloud-console-hardening-epic cch-instruments-epic; do
      OFF=0; while :; do
        curl -s "$B?filter[parent_id]=$P&limit=100&offset=$OFF" -H "Authorization: Bearer $BP_TOKEN" \
          > "page-$P-$OFF.json"
        N=$(jq -r '.docs|length' "page-$P-$OFF.json"); [ "$N" -lt 100 ] && break; OFF=$((OFF+100))
      done
    done
    jq -s '[.[].docs[]]|unique_by(.id)' page-*.json > ALL.json
    jq -r '[.[]|.content.surface//empty]|unique|length' ALL.json      # -> 48
    jq -r '[.[]|.content.surface//empty]|length' ALL.json             # -> 123 uses

A PAGED read, not a first page: `cloud-console-hardening-epic` alone returns 950 children
over ten pages. A single `limit=100` call reads 100 of 1279 and would have produced a
smaller, confident, wrong 48.

**1279 lifetime children of the two epics. 123 carry `surface`. 48 distinct values:
3 in-vocabulary (`console` ×47, `instrument` ×23, `ledger` ×8 = 78 uses) and 45 prose
strings used exactly ONCE each.** The prose half is what the brief counted; the
in-vocabulary half is the post-D331 filings and is where this file's mapping ends up.

Two corrections to the ordering brief, both in the brief's favour and neither changing
its conclusion:

* **"a bare FILE PATH in the field" is path-LED, not bare.** The value is
  `cloud/priv/static/__preview__/overflow-guard.mjs — the whole-file run`
  (`cch-w24-bl-guard-full-run-nav-flake`), and its sibling
  `cloud/priv/static/__preview__ — every browser oracle in the harness`
  (`cch-w24-bl-hash-only-nav-is-same-document`) has the same shape. The point stands
  exactly: a leading-token rule reads `cloud/priv/static/__preview__/overflow-guard.mjs`
  as its token, and no token rule reaches those two.
* **The live open population has moved since 2026-09-22T12:3xZ.** The brief's `5 of 48
  open children (0 of 11 / 5 of 37)` reads `4 of 45 (0 of 10 CCH, 4 of 35 CCHI)` at
  16:06Z the same day. Same direction, same argument.

## 2 — THE TEST: the enum against D307's own six (criterion 1)

D324 names four of the six BY DESCRIPTION and names neither of the two residue rows by id.
Matching the four descriptions against the live roster:

| D324's description | Row | Created | Class under the enum |
|---|---|---|---|
| a customer's inbox | `cch-w26-bl-deployment-failed-email-still-unhumanized` | 2026-08-02T17:23:55Z | `console` |
| a silent clip on a deploy row | `cch-w26-bl-deploy-row-siblings-unwrapped` | 17:31:56Z | `console` |
| a 408px drag on the /new hero | `task-ee662108818d603c` | 17:29:40Z | `console` |
| a raw provision aggregate reaching a person | `cchi-w26-bl-two-unhumanized-failure-tails` | 17:09:14Z | `console` |

**THE FOUR LAND IN ONE CLASS.** They share no technical vocabulary whatsoever — an Elixir
mail body (`event_email.ex`), an `app.css` wrap property, an SPA geometry measurement, and
an SSE/JSON render path. Three different languages, four different files, one class. That
is the whole result: the enum separates them correctly **because it is keyed on WHOSE
ARTIFACT IT IS, not on what the artifact is made of.** The 48 prose strings are keyed on
artifact family, which is precisely why they cannot.

The two residue rows: D324 does not name them, so this test does not depend on guessing
which pair it meant. Every other `-bl-` create in the same 17:07–17:32Z window classifies
away from `console`, so ANY pair D324 meant gives the same verdict:

| Candidate residue row in the window | Class |
|---|---|
| `cchi-w26-bl-deploy-rail-fail-value-has-no-leg-that-can-lose` | `instrument` |
| `cchi-w26-bl-font-pinned-evidence-narrates-instead-of-reporting` | `instrument` |
| `cch-w26-bl-desktop-band-above-1280-unswept` | `instrument` |
| `cchi-w26-bl-8500-decision-packet-and-the-relabel-trap` | `ledger` |
| `cchi-w26-bl-eight-live-rows-can-never-be-stamped` | `ledger` |
| `cchi-w26-bl-stranded-draft-is-a-silent-plus-one` | `ledger` |

**VERDICT: PASS, 6/6, and robust to the ambiguity in D324's own record.** The enum puts
the four person-facing rows in `console` and every residue candidate in `instrument` or
`ledger`. D307's refusal target — "ABSENT, or names an instrument path" — reads on this
vocabulary as "`surface` is absent, or `surface` is not `console`", and on the six that
predicate refuses exactly the two (or three, or six) residue rows and none of the four.

**WHAT THE TEST DOES NOT SHOW, said here rather than left to be discovered.** `console` is
a one-way guarantee. `instrument`/`ledger` mean *no person outside this campaign meets
this*, and that direction is sound. `console` does NOT mean *a person meets this*: it means
*the artifact is the product*. `cch-w26-bl-choice-picker-css-unproduced` — dead `.choice-*`
rules in `app.css` with no producer — is `console` and no person will ever meet it. For
D307 the asymmetry is harmless and load-bearing in the right direction, because D307
refuses RESIDUE: a false `console` costs a refusal that should have fired, never a
legitimate filing refused. A future guard that reasons the other way (*this row is
`console`, therefore a person meets it*) is reasoning past what the enum promises.

## 3 — THE MAP: all 48 values (criterion 2)

Rule applied, in order: (a) whose artifact is it — the product a customer operates
(`console`), this campaign's own measuring apparatus (`instrument`), or the task roster and
its filing law (`ledger`); (b) tie-break for a value naming BOTH a product surface and a
harness leg — take the OUTCOME's owner, except that a row whose entire deliverable is
coverage or measurement of a person-facing screen, changing nothing a person sees, is
`instrument`.

### 3a — the 3 in-vocabulary values (78 rows, no backfill needed)

| Value | Rows | Maps to |
|---|---|---|
| `console` | 47 | `console` (identity) |
| `instrument` | 23 | `instrument` (identity) |
| `ledger` | 8 | `ledger` (identity) |

### 3b — the 45 prose values, one row each

| # | Existing free-text value | Row | → |
|---|---|---|---|
| 1 | `Barkpark ledger — epic roster hygiene (no application code)` | `cch-w24-s6-law0-repayment-counts-its-own-filings` | `ledger` |
| 2 | `Barkpark ledger — the create-time filing law at the document writer's birth seat` | `cch-w28-s4-d307-door-guard-armed-at-the-birth-seat` | `ledger` |
| 3 | `Cloud console SPA — /new provisioning theater (all four theater screens)` | `cch-w24-bl-theater-grid-no-min-content-escape` | `console` |
| 4 | `Cloud console SPA — /new provisioning theater failure screen` | `cch-w24-s4-first-run-failure-screen-stops-shredding` | `console` |
| 5 | `Cloud console SPA — app.css, seven surfaces outside /new` | `cch-w24-bl-word-break-alias-remaining-seven` | `console` |
| 6 | `Cloud console SPA — instance detail head + provisioning timeline; overflow-guard cruel leg` | `cch-w24-s2-instance-detail-stops-dragging-the-page` | `console` (tie-break b: the screen stops dragging; the leg is how it is proved) |
| 7 | `Cloud console SPA — launch wizard catalog panel + provider connect success path` | `cch-w24-s3-launch-catalog-stops-lying-after-a-connect` | `console` |
| 8 | `Cloud console SPA — provider credential dialog + providers page connect card` | `cch-w24-s1-credential-dialog-button-is-alive` | `console` |
| 9 | `Console harness — __css_check E11 file set; three stale citations` | `cch-w24-s8-e11-can-see-the-stylesheet` | `instrument` |
| 10 | `Console harness — __css_check.mjs module shape` | `cch-bl-css-check-gate-body-not-importable` | `instrument` |
| 11 | `Console harness — overflow-guard W15 fleet leg + smoke.mjs fixture readers` | `cch-w24-s5-the-fence-goes-around-a-reader` | `instrument` |
| 12 | `Console harness — overflow-guard.mjs nav() + every element-walking leg` | `cch-w24-followup-no-leg-drives-a-hash-nav` | `instrument` |
| 13 | `Console harness — sites/env cruel fixtures + the existing breakpoint-sweep cells` | `cch-w24-s7-three-screens-cruel-by-fixture` | `instrument` |
| 14 | `cloud SPA drift gate residue` | `gr-backlog-css-check-missing-classes` | `instrument` — see §3c(i) |
| 15 | `cloud SPA preview harness` | `gr-backlog-reset-route-smoke` | `instrument` — see §3c(i) |
| 16 | `cloud SPA status grammar` | `gr-backlog-d24-statusmeta-sweep` | `console` — see §3c(i) |
| 17 | `cloud console SPA — instance workspace Sites card (app.css track + overflow-guard leg)` | `cch-w26-s1-instance-track-min-content-and-a-leg-that-can-lose` | `console` (tie-break b) |
| 18 | `cloud console SPA — launch wizard / provider credential sheet exits (app.js + pure-helper tests + a guard leg)` | `cch-w26-s4-every-credential-sheet-exit-resumes-or-clears` | `console` (tie-break b) |
| 19 | `cloud console SPA — site detail deploy list failure panel (app.css wrap + cruel fixture + per-cell clip leg)` | `cch-w26-s2-deploy-fail-is-the-twin-the-hoist-silenced` | `console` (tie-break b) |
| 20 | `cloud console SPA — the /new launch theater (theater-ready + new-launch), geometry coverage only` | `cch-w26-s6-theater-ready-and-new-launch-get-geometry` | `instrument` — "geometry coverage only": the deliverable is a cruel drive over a person-facing screen, and nothing a person sees changes. The clearest case for tie-break (b), and the one that shows the rule is not a formality |
| 21 | `cloud console SPA — the /new ready hero (theater-ready + new-launch), the screen every successful signup lands on` | `task-ee662108818d603c` | `console` |
| 22 | `cloud console SPA — the instance detail failure timeline, where the Retry control lives after a failed provision` | `cch-w25-bl-flick-to-bottom-overshoots-retry` | `console` |
| 23 | `cloud console SPA — the notification settings matrix, and the control plane events behind it` | `cch-w27-bl-deployment-failed-toggle-fires-nothing` | `console` |
| 24 | `cloud console SPA — the provisioning master progress bar on instance detail (.prov-overall), on a run that has already failed` | `task-a5a9c63ee5b22fc3` | `console` |
| 25 | `cloud console SPA — the site detail preview deploy rows (.deploys previews card), where a branch name a person chose is rendered beside its preview URL` | `cch-w26-bl-deploy-row-siblings-unwrapped` | `console` |
| 26 | `cloud console SPA — the site row inside an instance workspace` | `cch-w28-s8-never-deployed-site-row-says-so` | `console` |
| 27 | `cloud console instruments — __css_check.mjs ALLOW_PREFIXES / KNOWN_GAPS + the coherence role-set test` | `cch-w26-s5-css-check-bp-lc-closed-alternation-paid` | `instrument` |
| 28 | `cloud console instruments — overflow-guard.mjs's merge-resolution safety, the file three concurrent slices append to every wave` | `cchi-w27-bl-okline-arity-swallows-a-leg` | `instrument` |
| 29 | `cloud console instruments — the W26-deploy-fail-clip leg's attribution logic` | `cchi-w27-bl-deploy-fail-clip-misattributes-a-sibling` | `instrument` |
| 30 | `cloud console instruments — the cruelty ledger and its three consumers` | `cchi-w27-bl-w22s7-residue-derived-caps-and-refusals` | `instrument` — the "cruelty ledger" is a HARNESS artifact, not the task roster. The word `ledger` inside a prose surface is the vocabulary's one true homonym and §3c(ii) rules on it |
| 31 | `cloud console instruments — the ledger's own filing law, at the create door every task write passes through` | `cchi-w27-bl-d307-create-time-door-guard` | `ledger` — **this value is self-refuting and is the single best argument for the enum.** D307 itself is a defect in the TASK ROSTER, filed under a prose surface that calls it an instrument. Exactly the fold D331 refused when it kept `ledger` separate |
| 32 | `cloud console instruments — the notification scrub test's fixture reachability` | `cchi-w27-bl-scrub-test-green-by-construction` | `instrument` |
| 33 | `cloud console instruments — the seal predicate, the instrument this epic reads its own temperature from` | `gr-bl-seal-predicate-provenance-gap` | `instrument` |
| 34 | `cloud control plane + console SPA — the domain-status ladder a person reads while waiting for a domain` | `cch-w28-s7-domain-status-stops-guessing-at-an-unreachable-resolver` | `console` |
| 35 | `cloud control plane — FailureCopy classification, the sentence a person reads when a deploy fails` | `cch-w27-bl-connection-refused-classified-as-timeout` | `console` |
| 36 | `cloud control plane — FailureCopy classification, the sentence a person reads when a provision or deploy fails` | `cch-w28-s5-refused-connection-is-not-a-timeout` | `console` |
| 37 | `cloud control plane — notification dispatch` | `cch-w28-s6-followup-oban-mail-queue-uncaps-reaper-alerts` | `console` |
| 38 | `cloud control plane — notification dispatch for deployment failures, and the alert email a person reads` | `cch-w28-s6-deployment-failed-alerts-actually-dispatch` | `console` |
| 39 | `cloud control plane — notifications/event_email.ex provision_failed body (Elixir)` | `cch-w26-s3-the-humanized-cause-reaches-the-inbox` | `console` |
| 40 | `cloud control plane — the deploy failure render path: the JSON boundary, the .deploy-rail-fail caption a person watches, and the SSE site.deploy.stage channel` | `task-c04dde30f94b14c9` | `console` |
| 41 | `cloud/priv/static/__preview__ — every browser oracle in the harness` | `cch-w24-bl-hash-only-nav-is-same-document` | `instrument` — see §3c(iii) |
| 42 | `cloud/priv/static/__preview__/overflow-guard.mjs — the whole-file run` | `cch-w24-bl-guard-full-run-nav-flake` | `instrument` — see §3c(iii), THE PATH-LED VALUE |
| 43 | `console instruments` | `cch-w28-followup-seal-suite-depth1-coupling` | `instrument` — a near-miss of the enum, and the reason exact-case closed membership is the rule rather than a prefix |
| 44 | `console instruments — the CI wiring's committed prose about its own behaviour` | `cch-w28-s3-console-harness-hermeticity-prose` | `instrument` |
| 45 | `console instruments — the seal predicate's own test file, on PR #9356's branch` | `cch-w28-s1-empty-roster-control-asserts-clause-a` | `instrument` |

**45 of 45 mapped. Zero unmappable.** The value D331 called not-mechanically-producible was
not producible BY A CLASSIFIER — 7/15 against a 11/15 constant baseline. It is producible by
READING 45 rows once, which is what this table is. The two claims are compatible and this
file is not a refutation of D331; it is the read D331 declined to spend.

### 3c — the three rulings the map needed

**(i) The three terse `gr-backlog-*` / `gr-bl-*` values are a DIFFERENT EPIC'S vocabulary
that got re-parented in.** `cloud SPA drift gate residue`, `cloud SPA preview harness` and
`cloud SPA status grammar` were created 2026-07-18, three days before this epic opened, in
the `tooling/grip` backlog's own surface language (D339 counted 42 rows in that vocabulary
living outside this epic). They are mappable — a drift gate and a preview harness are
instruments, a status grammar is copy a person reads — but they are **the reason the enum
must be SCOPED to a parent rather than global**: `surface` is a word several vocabularies
own, and a global enum would have retroactively made 100 rows off-vocabulary in vocabularies
that were never wrong. `writer.ex:1470-1474` already says this; the three rows are its
measured instance.

**(ii) `ledger` is a homonym and the enum means only one of the two.** In `cloud console
instruments — the cruelty ledger and its three consumers` the word names a harness artifact.
The enum's `ledger` means THE TASK ROSTER AND ITS FILING LAW — the rows whose subject is a
`bp` task, a claim, a stamp, a criterion or the create door — and nothing else. Any row
naming the *cruelty* ledger, the *evidence* ledger or a `tooling/grip/ledger/*.md` record is
classified by what the row is ABOUT, which for all of those is `instrument`.

**(iii) A PATH IS NOT A SURFACE, and the two path-led values are the proof.** A path answers
WHERE the bytes live; the enum answers WHOSE THEY ARE. The ruling is that a path-led value
is mapped by reading the row and never by parsing the path, and that a path may not be a
`surface` value going forward — the write door already enforces this, since
`cloud/priv/static/__preview__/overflow-guard.mjs — the whole-file run` is not one of the
three terms and a create carrying it returns 422 `birth_surface_term_error`. The two rows
predate the guard (2026-08-02T12:59 and 13:01; the guard merged 2026-08-03T15:08Z per D339),
which is the only reason they exist.

## 4 — Enforcement, as it actually stands (criterion 3)

Read at `api/lib/barkpark/content/writer.ex` on `origin/main` `fe6f4b11b`:

| Tier | Behaviour | Where |
|---|---|---|
| OFF-VOCABULARY `surface` | **HARD 422** `validation_failed` / `birth_surface_term_error`, exact case, closed set | `:1577`, wired `:507` and `:1075` |
| ABSENT `surface` | **WARN and PASS** — one greppable line, `grep -c "filing law: undeclared surface"` | `:1547-1558` |
| Unchanged `surface` on an update | allowed, grandfathering the 45 prose rows for every other field | `:1573`, `previous_surface/1` `:1588` |
| Parent not `cloud-console-hardening-epic` | `:ok`, guard does not fire | `:1544`, `cch_epic_child?/1` `:1597` |

So a filer **can no longer invent a value** under `cloud-console-hardening-epic`. Three
things are still true and none of them is written down anywhere a reader will meet:

**(a) THE GUARD COVERS ONE OF THE TWO EPICS.** `@cch_epic_parent` (`:1532`) is a single
literal and `cch-instruments-epic` appears nowhere under `api/lib/`. That epic holds **35 of
the 45 live open rows** and **25 of the 123 surface-bearing rows**, and every one of them
passed an unguarded door. MEASURED, and the measurement is reassuring rather than alarming:
all 10 prose values under `cch-instruments-epic` were created on or before
2026-08-03T10:32Z, hours BEFORE the guard merged at 15:08Z, and the 15 in-vocabulary
values filed there since (2026-08-03T13:49 → 2026-08-22T20:58) chose the enum with no door
to make them. **Zero measured escapes through the open door — the convention held on its
own.** The gap is a latent one, and naming it is worth more than closing it on a guess:
closing it is a one-literal change to a list, and it belongs in the sibling row with a
mutation proof, not here.

**(b) THE ABSENT TIER IS STILL ADVISORY, AND THAT IS NOW A CHOICE WITH A PRICE.** D331 and
D339 deferred it on the backfill's producibility; §3 removes that reason for these 48
values. What remains is the population D339 measured: under presence+enum, **70 of 71 open
rows (98.6%) would be refused**. §3 maps the 45 prose values and the 3 in-vocabulary ones —
it does not value the rows that carry NO `surface` at all, which is where that 98.6% lives.
**The promotion is gated on the BACKFILL WRITING those rows, not on this map.** Row
`cch-w28-s4-followup-promote-absent-surface-to-hard` (OPEN, under `cch-instruments-epic`)
is where that lands.

**(c) NOTHING READS `content.surface`.** D339's finding still holds on `fe6f4b11b`: the only
occurrences repo-wide are the guard and its own log string, there is no `surface` field in
`tasks/schema.ex`, and zero hits in `app.js`. The enum is a write-side discipline with no
consumer. D307 would be its first.

## 5 — Not run, named

* **No live create was issued** to re-prove the 422 against guerrilla. D339 settled that
  with three real creates and the source is a literal list read directly; a fourth probe
  would have written to the shared ledger for no new information. The enforcement table in
  §4 is a SOURCE read, not a live probe, and is labelled as such.
* **No mutation proof** of the `cch-instruments-epic` gap — finding (a) is a grep of a
  single literal, which is the source, but the refusal's absence was not driven.
* **No row was claimed, pulsed, stamped, closed or patched**, and no `surface` value was
  written. The backfill is a separate row by the ordering's own sequencing.
