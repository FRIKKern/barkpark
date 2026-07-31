# Re-derivation recipe — PDS wave 27, the claimable-and-ledger-closed contradiction (2026-07-31)

Worker: `epic-builder-repair-the-13-closure-rows-that-are-simu`. Task:
`pds-w27-round-contradiction-13`. Every write read back from the server, one row at a time.

**The defect.** Rows carrying `content.disposition = closed` while `lifecycle_status = open`.
Per **PDS-D372** this is not an orthogonal axis, it is PDS-D298's CLOSED recipe with its second
half never run: the verdict was recorded, the lifecycle act was not, so the row stayed inside
`validation.ex`'s claimable allowlist and `bp task ready` kept handing finished work to workers.

**Outcome.** 14 rows repaired (the 13 named in the brief, plus one a sibling slice minted mid-run).
Claimable-and-closed is now **zero on two independent instruments**.

## 0. Both citations, re-derived from origin/main (never quoted from a brief)

    git fetch origin main
    git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '4310,4320p'
    git show origin/main:api/lib/barkpark/tasks/validation.ex   | sed -n '19,32p'

The charter's `sed -n '4318,4327p'` window lands *mid-bullet* — widen to `4310,4320` or the
CLOSED binding is cut in half. It reads:

> - **CLOSED** → `bp task close <id> <worker> <epoch> done "<reason>"` → `content.close_reason`,
>   which must name the fixing commit / charter line / live probe that makes the row moot.

`validation.ex:19-31`: *"OPEN MEANS READY" is held by construction — only open|blocked is claimable*,
with `@claimable_statuses ~w(open blocked)`. That pair is the whole argument: `closed` on a row
whose `lifecycle_status` is still `open` is a verdict the queue cannot see.

## 1. Criterion 0 — the live probe, on disposable rows, BEFORE any real write

Four arms, two scratch rows. `bp task create` **fails with `internal_error` if you pin `--set _id=…`** —
let it mint the id, then patch tags and publish (the publish wall needs a description + weighted tags).

    bp task create "SCRATCH probe row …" --yes -o json \
      --description "…" --set 'priority:=4' \
      --set 'acceptance_criteria:=[{"criterion":"Deliberately unmet …","met":false,"evidence":""}]'
    bp doc patch   task <id> --yes --set 'tags:=[{"tag":"pds","strength":90,"rationale":"…"}, …]'
    bp doc publish task <id> --yes

| # | row | request | result |
|---|---|---|---|
| A | `task-f892ea5f8fa27947` (claim null, 0/1) | bare close | **REFUSED** `criteria_unmet:0` |
| B | same | `--set criteria_override=…` | OK — `close_override.criteria` recorded |
| C | `task-9cf983cd42836f3a` (claimed by `some-other-worker-not-me`) | `criteria_override` only | **REFUSED** `not_holder:some-other-worker-not-me` |
| D | same | both overrides | OK — `close_override.{criteria,holder}` + `claim.closed_by` |

Wire form is `--set holder_override="…"` / `--set criteria_override="…"`
(`tasks_controller.ex:492-493`). Both gates are live, independent, and record.

**Finding that changes the budget.** The brief budgeted *~2 recorded overrides per row*. On an
**unclaimed** row the holder gate does not fire at all — `close.ex:395 check_close_holder` returns
`{:ok, nil}` through `close_holder`'s unclaimed arm, and `compose_override_record` then writes **no**
holder record. Sending `holder_override` there is inert paperwork asserting a displacement that never
happened, so it was deliberately not sent. Eleven rows took **one** override; three took two.

## 2. The pinned manifest — re-derive, never inherit

    for o in 0 1000 2000 3000 4000; do
      bp doc query task --fields doc_id,parent_id,disposition,lifecycle_status \
        --limit 1000 --offset $o -o json > pg$o.json; done
    bp task ready --all -o json > rdy.json

Closure = transitive `parent_id` closure from root `task-2ac1f95237c4a8e5`, root excluded.

| quantity | value |
|---|---|
| store rows | 3984, pages `[1000,1000,1000,984]`, 0 duplicates |
| manifest sha256 | `8c509efe3d6fc20d224345d41a1569a654f7396282cae93dbf0acedb2bab5e82` |
| PDS closure | 350 |
| `ready --all` | 1312 |
| claimable **and** closed, store-wide | **13** |
| …inside the PDS closure | **13** |
| …outside the closure | **0** |

The set matched the brief's 13 exactly — no named row had ceased to be a contradiction, no unnamed
row was one.

**Three populations, not conflated.** Store-wide claimable rows with `disposition == parked` = **3**
(`pds-bl-dedup-unavailable-error-code`, `pds-bl-pds-harness-no-ci`, `task-32ce52edfd7af367`), which
is where the brief's store-wide figure of 16 comes from: 13 closed + 3 parked.
`task-32ce52edfd7af367` is **parked, not closed**, and `in_closure = False` — a neighbour epic's row.
**It was not written.**

## 3. Every cited sha verified — and the brief's count corrected

Extracting every sha-like token from all 13 stored reasons yields **13 distinct tokens, not 8**, and
**zero rows cite no sha** (so the brief's "two by-content verifications for the rows that cite no
sha" population is empty — both rows it meant cite shas *and* argue by content).

    for s in 0b4c677fd 448749cf1 63581a76d 645260961 6f4ca7904 7d0846b0d 7f8a0dd7f \
             92553f9a6 a190984df c222a8739 c305a1a6e c4899b4ec f899ef2e9; do
      git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done

**13/13 ANCESTOR.** The brief's 8-sha list omits `c4899b4ec` and `c305a1a6e` — the two shas
`pds-bl-w16-arm-never-records-its-own-floor` cites, its reason saying outright *"it took TWO shas
rather than one — which is why a single-commit search missed it"* — and `c222a8739`. `0b4c677fd` and
`7f8a0dd7f` are **not** fixing shas: they are observed values quoted inside
`pds-bl-deploy-success-without-advance`'s reason. They were verified anyway rather than filtered by
assumption. No row's claimed fix failed to verify, so no row was left alone on that ground.

## 4. The repair

Per row: `close_reason` = the row's **pre-existing adjudication text, verbatim and unmodified**
(it already opens `CLOSED …` and already names the fixing commit, satisfying D298). The new D372
paperwork lives only in `close_override.criteria.reason`, which states plainly that the criteria are
unmet and are **not** being asserted as met. No criterion was flipped on any row.

    bp task close <row> <worker> <epoch> done "<the row's stored adjudication reason>" \
      --yes --set criteria_override="PDS-D372 repair. This row's acceptance criteria are UNMET AS
      STORED and are NOT being asserted as met: … adjudicated CLOSED BY CONTENT under PDS-D299
      against origin/main (<shas>) … what never ran was PDS-D298's second half, the lifecycle act …
      This close performs only that lifecycle act; it changes no verdict and flips no criterion."

`<epoch>` is the row's `claim.epoch` when a stale claim exists, else `0`.

| row | epoch | criteria after | overrides |
|---|---|---|---|
| pds-bl-autostamp-elixir-guard | 0 | 0/4 | criteria |
| pds-bl-blob-sidecar-byte-verify | 0 | 0/4 | criteria |
| pds-bl-blob-storage-readback | 5 | 6/7 | criteria + **holder** |
| pds-bl-close-holder-and-criteria-gate | 0 | 0/5 | criteria |
| pds-bl-counts-perspective-honesty | 0 | 0/3 | criteria |
| pds-bl-deploy-success-without-advance | 0 | 0/4 | criteria |
| pds-bl-import-receipt-counts | 0 | 0/3 | criteria |
| pds-bl-park-note-evaporates | 7 | 5/6 | criteria + **holder** |
| pds-bl-scratch-pointer-concurrency | 0 | 1/6 | criteria |
| pds-bl-scratch-pointer-explicit-default | 0 | 0/3 | criteria |
| pds-bl-w16-arm-never-records-its-own-floor | 0 | 0/5 | criteria |
| pds-w22-deploy-readback | 6 | 6/8 | criteria + **holder** |
| task-5c4f2673778d5ff0 | 0 | 0/3 | criteria |
| pds-bl-cond-b-nonnumeric-floor-fail-direction | 0 | 0/2 | criteria |

All 14 read back `lifecycle=done`, `disposition=closed`, criteria unchanged.

**The brief was wrong that all 13 had `claim == null`.** Three carry **expired** claims with
`worker: null` (`pds-bl-blob-storage-readback` ep5, `pds-bl-park-note-evaporates` ep7,
`pds-w22-deploy-readback` ep6). On those the holder gate genuinely fired with
`not_holder:<prior worker>` and a second recorded override was required. The prior holder is
preserved on `claim.worker`; this actor is recorded as `claim.closed_by`.

**The 14th row.** `pds-bl-cond-b-nonnumeric-floor-fail-direction` was adjudicated
`disposition=closed` by a sibling slice at `02:26:32Z`, *while this slice was running* — a new
contradiction of exactly this class. Its reason cites no sha (refuted by experiment); its source
citation was verified by content before repair:
`git show origin/main:scripts/pds-pull-proof.sh | sed -n '1300,1312p'` shows the
`if [ -z "$mem_mb" ] / elif [ "$mem_mb" -ge "$FULL_MIN_MEM_MB" ] / else …; ok=0` block exactly as
quoted. The population is a **floor, not a ceiling**, and the board is not quiesced — so the repair
loop re-derives and re-runs until a pass finds nothing, rather than trusting one snapshot.

## 5. Two reader lies caught in flight — both relevant to the epic's law

**(a) A read-back with no `lifecycle_status` was being read as state.** A first repair pass printed
`SKIP pds-bl-scratch-pointer-concurrency — lifecycle is already None` and moved on. The row was
untouched and still `open`. A degraded read had been mistaken for a completed row: an untouched row
reported as done, behind a green summary. Fix: a missing `lifecycle_status` is a **degraded read**,
retried, never returned as truth.

**(b) `bp task ready --all` silently under-reports.** A convergence pass reported
`claimable-and-closed = 0` while `pds-bl-cond-b-nonnumeric-floor-fail-direction` was demonstrably
`open` + `closed` **and present in both corpora**. An identical run on the same unchanged data
returned `1`. Sampling `ready --all` six times returned a stable 1304/1305 with the row present, so
the omission is intermittent, not a filter. **Consequence: the slice gate's zero cannot stand
alone** — it is exactly "reaching exit 0 by not looking", which PDS-D348 refuses.

## 6. The zero, asserted on two instruments

    # A) the slice gate, verbatim
    bp task ready --all -o json > rdy.json ; paged bp doc query task … ; join on disposition==closed
    # B) ready-INDEPENDENT: validation.ex's own definition, straight from the paged corpus
    lifecycle_status in ('open','blocked') AND disposition == 'closed'

| instrument | result |
|---|---|
| A) ready-join | **0** |
| B) status-derived (`@claimable_statuses ~w(open blocked)`) | **0** |
| B) within the 355-row PDS closure | **0** |

Paged corpus at assertion time: 3989 rows, pages `{0:1000, 1000:1000, 2000:1000, 3000:989, 4000:0}`,
3989 unique, **0 duplicates**, first empty page reached — so coverage is complete, not assumed.

**Ability to fail, proven by mutation rather than asserted.** Injecting one synthetic
`disposition=closed` onto a genuinely claimable row in the corpus copy (no server write) makes the
same join report it. The instrument also produced three distinct non-zero answers on real data
during this run — 13 before any write, 1 after the sibling-minted row appeared, 0 after — so its
zero is a measurement, not a silence.

**Known blind spot, reported not fixed (outside this slice's files).** 28 rows in `ready --all` are
absent from the paged corpus and **all 28 are `drafts.*`** — drafts in the ready pool. None carries
`disposition=closed`, so none is a hidden survivor today, but the gate's `if i in d` join would drop
such a row silently if one ever existed.

## 7. Scratch rows left on the ledger

`task-f892ea5f8fa27947` and `task-9cf983cd42836f3a` are the criterion-0 probe rows. Both are
`lifecycle=done`, so neither is claimable and neither can reach a worker. Titles begin `SCRATCH probe
row`. They are recorded here rather than deleted so the probe transcript stays reproducible.
