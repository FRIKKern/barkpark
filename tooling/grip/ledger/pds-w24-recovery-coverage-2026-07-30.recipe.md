<!-- doc-tier: cold | canonical-for: pds-w24-recovery-coverage-rederivation | budget: 6000tok -->

# PDS wave 24 — recovery-coverage re-derivation recipe (2026-07-30)

Measured instant: 2026-07-30, server `guerrilla.barkpark.cloud`. Every number below is
re-derivable with the commands in this file. Nothing here was read from a Paper.

## 0. The one gotcha that invalidates a census

`bp task get` / `bp doc revision` return a **valid JSON envelope with `"ok": false`**
when rate limited, and exit **7**; under high parallelism they can also exit **1** with
empty output. A fetch loop guarded on `[ -s "$file" ]` (non-empty) therefore accepts a
rate-limit error as data. 45 of 111 rows were silently lost to this on the first pass.

    # PROVE it: 60 concurrent gets at -P 12
    seq 1 60 | xargs -P 12 -I{} sh -c 'bp task get pds-w23-triage-round -o json >/dev/null 2>&1; echo $?' | sort | uniq -c
    # observed: 40x exit=0, 18x exit=1 (empty), 2x exit=7 (ok:false body)

**Rule: validate every payload by CONTENT (`'doc' in d` / `'revisions' in d`), never by
size or exit code alone. Keep parallelism at -P 3..4.**

## 1. Build the live closure

    bp task get task-2ac1f95237c4a8e5 -o json   # PDS epic
    # BFS over children; the level-1 child objects carry NO child_count,
    # so each child must be fetched individually to discover grandchildren.

Result: **179 unique descendants** (178 level-1 + 1 grandchild under
`pds-w2-scratch-harness-ci`). open 101 · considering 10 · done 58 · cancelled 10.
**111 LIVE rows** (open + considering).

## 2. Current adjudication state of the 111 live rows

    bp task get <id> -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content'];e=c.get('engagement') or {};print(len(e.get('note') or ''), len(c.get('disposition_reason') or ''), repr(c.get('disposition')))"

| measure | value |
|---|---|
| non-blank `content.engagement.note` | **0 / 111** |
| non-blank `content.disposition_reason` | **79 / 111** |
| `disposition` = `OPEN` / `open` / `parked` / absent | 47 / 24 / 8 / 32 |
| distinct `disposition_reason` md5 (of the 79) | **72** |
| the 8 `parked` rows' reason md5 | `4f556ba7385447684ff923235cece0f0`, 644 B, **8/8 identical** |
| live rows carrying a NON-boilerplate REACTIVATE trigger | **0** |

## 3. The revision archive IS the recovery store — no psql, no new endpoint

    bp doc history task <id> -o json           # -> revisions[].id, .timestamp, .action
    bp doc revision <rev-id> -o json           # -> revision.content, verbatim

2490 revisions across the 111 live PDS rows; 813 across the 40 truth-grip `considering`
rows. All 3303 fetched, 0 unreadable.

**Positive control (proves a silent redaction is not being read as "no note"):**

    bp doc revision 8f7ca193-bded-440e-93b2-ce3ba79f4f98 -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['revision']['content'];print(len(c['engagement']['note']))"
    # -> 822

## 4. Coverage

| population | rows | rows with a recoverable `engagement.note` in the revision archive |
|---|---|---|
| PDS live closure | 111 | **10** |
| truth-grip `considering` (the "45 tgw* parks") | 40 | **40** — 40 distinct notes, 40/40 contain REACTIVATE, 197–550 B |

**The 158 figure does NOT survive the revision route.** It was measured on
`mutation_events`, a different store. Via the revision archive the recoverable set is
**50 rows** (10 PDS + 40 tgw). `mutation_events` was NOT probed here; do not quote 158
through this route.

## 5. What the 8 parked PDS rows actually show

All 8 carried a row-specific note (481–1058 B) at 2026-07-27 **21:15–21:23Z**. The 644 B
boilerplate landed at **22:24–22:27Z** — **8 of 8 written AFTER** the good text. The
boilerplate asserts *"the original adjudication text is NOT recoverable"*. It is
recoverable, verbatim, from the revision archive. The ledger states a falsehood about
its own data loss.

The boilerplate also contains the literal string `REACTIVATE:`, so a gate counting
"rows carrying a reopen trigger" scores 8/111 and **all 8 are false positives**.

## 6. The tgw10 diagnosis is refuted

`tgw10-bl-park-reasons-not-durable` states: *"The mechanism is NOT broken — it was not
used"* (0 of 46 considering rows carry a note). True of CURRENT state; **false as a
diagnosis**. All 40 considering rows carry a note in the revision archive, written
2026-07-27 15:08–15:37Z by holder `epic-builder-tail-disposition-prune-drive-clause-b-s-`.
The notes were written and then evaporated (engagement lease TTL, 900 s).

## 7. THE RECOVERY RULE

1. **Source**: latest revision, by `revisions[].timestamp`, whose
   `content.engagement.note` is non-blank. Dedupe by content md5 first — create/publish
   pairs duplicate every revision.
2. **LATEST-WINS, not earliest-adjudication.** Proven by the only 2 drifting rows of 40:
   - `tgw2-bl-throw-liveness-observation`: earliest 405 B, latest 550 B superset
     ("PARK REASON RESTORED BY REVIEW"). Latest strictly better.
   - `tgw5-mint-numeric-flags`: **earliest is the literal 10-byte string `TEST-PROBE`**;
     latest is the real 286 B reason. Earliest-wins restores test garbage.
   PDS side: all 10 rows have exactly 1 distinct note text — the question is moot there.
3. **Reject sentinels**: skip notes matching `TEST-PROBE` or < 40 B with no REACTIVATE.
4. **Write guard — promote-only-when-blank is NOT sufficient here.**
   `api/lib/barkpark/tasks/ttl_sweeper.ex:595-611` `promote_legacy_note/2` writes only
   when `blank_reason?(content["disposition_reason"])`. Applied to this board it recovers
   **ZERO of 10** PDS rows, because the boilerplate already occupies the field.
   The repair needs a second, narrower clause: **overwrite only when the current reason's
   md5 == `4f556ba7385447684ff923235cece0f0`** (the known generic boilerplate). Never
   overwrite any other non-blank reason — that preserves the sweeper's intent while
   undoing the one write that destroyed information.
5. **Provenance is mandatory**: cite the revision id + its ISO timestamp in the restored
   text, e.g. `RESTORED 2026-07-30 from revision 8f7ca193-… (2026-07-27T21:16:16.901017Z)`.
6. **Read-back**: `bp doc patch` writes the DRAFT row; publish after every patch, then
   re-read and COUNT the field. A count taken off the published route without publishing
   under-reports the last ~40 s of writes.

## 8. Per-row recovery targets (PDS live closure)

| row | archive note B | rev id | current reason |
|---|---|---|---|
| pds-bl-tag-schema-frozen-in-stamped-slot | 1058 | ca8efc94-da2a-42fd-a0e0-866da55d1b74 | 644 boilerplate |
| pds-bl-bp-search-false-negative | 822 | 8f7ca193-bded-440e-93b2-ce3ba79f4f98 | 644 boilerplate |
| pds-w9-stale-2231-in-papers | 805 | 0b5b4516-9bce-4069-8b83-c89f805225a7 | 497 B (older, `open`) |
| pds-w8-schema-column-count-gap | 779 | d6d194f9-5386-45b3-bb39-dab62970cb8c | 644 boilerplate |
| pds-bl-legb-visibility-false-red | 746 | 18dd5f4e-6b02-4dc5-8fad-0c0c691e3bd0 | 644 boilerplate |
| pds-sheets-linearity-deterministic-guard | 730 | 6967d8c2-d7c5-47ea-be52-35931a9fb729 | 644 boilerplate |
| pds-bl-scripts-md-budgets-unenforced | 727 | bb6f68ea-a5ba-4996-bb60-2a62207f59db | 410 B (older, `open`) |
| pds-w10-climb-in-the-post-deploy-window | 583 | d5808484-090a-4295-8ab6-ea89ffac8ced | 644 boilerplate |
| pds-bl-source-box-too-small-for-full-export | 481 | 6544e0e1-fdb2-4b27-9db4-aa6fb32dd8c8 | 644 boilerplate |
| pds-bl-step5-faildemo-passline-selfdescription | 130 | 091551f5-b78a-4943-94f8-d910d756ccf0 | 644 boilerplate; note has NO trigger |

The last row is the only one whose recovered note lacks a REACTIVATE clause — recovery
restores the reason but a trigger must still be authored.

## 9. The 32 unadjudicated rows are genuinely greenfield

Of the 32 live rows with no `disposition`: **0** have an archive note, **0** have a
current `disposition_reason`. Recovery cannot help them; they need adjudication.
