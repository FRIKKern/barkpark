<!-- doc-tier: cold | canonical-for: pds-wave-27-terminal-round-rederivation | budget: 6000tok -->

# PDS wave 27 — the terminal round, re-derived by content

> HISTORICAL RECORD (2026-07-31) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Ledger-only slice `pds-w27-round-terminal-15`. The 15 rows that made up clause 3 of the
census (off-vocabulary dispositions) were re-adjudicated to the canonical `closed`, and every
reason was re-written from the tree rather than templated from the row's stored text. The
dispositions themselves live on the Barkpark ledger; this file is the recipe for re-deriving
every claim without re-reading the task.

Everything below was measured against `origin/main = 6e53d27824206c5cbda4eb8916795921064165e9`.

## The population was counted, not quoted

The census caps its `off_vocabulary_samples` at 3 ids per value, so the brief-supplied list is
not evidence. Re-running the census with that cap raised to 500 yields the true population:

```
sed 's/if len(off_vocab_samples\[value\]) < 3:/if len(off_vocab_samples[value]) < 500:/' \
  scripts/pds-ledger-census.sh > cfull.sh
bash cfull.sh --json --anchor-from-paper pds-wave-27-2026-07-31
```

It returns **8 `OPEN` + 7 `in-flight` = 15**. The brief listed **8** in-flight, including
`pds-w22-deploy-readback`. That row is NOT off-vocabulary: it reads `disposition: closed` at
`lifecycle_status: open`, which places it wholly inside the clause-6 contradiction set owned by
`pds-w27-round-contradiction-13`. It was not written by this slice, so the coordination hazard
the brief flagged never materialised. Counting instead of quoting is what surfaced that.

## The stage door was probed live before any round write

`#8218` had to be DEPLOYED, not merely merged. Rather than perturb a real row, the probe used a
purpose-built, parentless row — `pds-w27-terminal15-stage-door-probe` — which sits outside the
PDS closure (root `task-2ac1f95237c4a8e5`) and therefore cannot move any census number.

```
bp task stage pds-w27-terminal15-stage-door-probe done --disposition closed \
  --note "PROBE (wave 27, terminal round): ..." --worker <worker> --yes
```

`ok:true`. Read back with `bp task get`: `lifecycle_status` stayed `done`, `disposition` became
`closed`, and `claim` was byte-identical before and after (`closed_at 2026-07-31T02:15:56.418521Z`,
`epoch 1`). The door widens adjudication, not movement, exactly as `bp task stage --help` claims.

## The 15 rows

`md5` is of the new reason text as stored. `census hash` is the instrument's own hash
(sha256 of the whitespace-normalised reason, first 16 hex — `pds-ledger-census.sh:544`), which
is the space clause 1 actually measures collisions in.

| # | row | was | fixing commit / artifact | md5(new reason) | census hash |
|---|---|---|---|---|---|
| 1 | `pds-barkpark-stop-4000-fallback` | `OPEN` | absorbed by #8134 (74ff85b92) | `20282f2382eaa2839f0cbe59a933e8ef` | `97c54694be6342ee` |
| 2 | `pds-bl-bounded-import-unpack` | `OPEN` | #8130 (2563a6cd6) | `8d2c5aec2b9ef4d70080eb6c8cb0b307` | `ad410e14b8322daa` |
| 3 | `pds-bl-export-controller-matcherror-on-disconnect` | `OPEN` | #8135 (2c6968e98) | `05f11f3485c0bad5c9644c96b3eea72f` | `4f9cba34ef0bafde` |
| 4 | `pds-bl-start-server-trusts-the-pidfile` | `OPEN` | #8134 (74ff85b92) | `ed30051ddfcc58f67cc760beb7b84336` | `2c6eac92c66a642d` |
| 5 | `pds-bl-surface-durable-reason` | `OPEN` | #8133 (7b0af004d) | `385fd180cd1cf073e2cc708c2b50908e` | `0f75f9791133aa40` |
| 6 | `pds-bl-task-create-dedup-scan-lies` | `OPEN` | #8136 (a144d3c81) | `802a144773854f1a63d3d1a5a2d8ace9` | `367103eb2ec0e3c1` |
| 7 | `pds-w24-census-instrument` | `OPEN` | #8131 (a74433aa5) | `a58135bfc5c831914cb0769402e8cab9` | `e19458d5dfc04579` |
| 8 | `pds-w24-hollowness-unwritable` | `OPEN` | #8132 (18addd9de) | `2121d34f695dc134c931c45e6342d1e3` | `b63d1069bc3b4e0f` |
| 9 | `pds-w22-close-holder-criteria-honesty` | `in-flight` | #6420 (448749cf1, merged 2026-07-28T00:35:32Z) | `4878aedbdcb85c7a1721eeca86e4587d` | `0d734c1b63c19fb3` |
| 10 | `pds-w22-deploy-stamp-and-harness` | `in-flight` | #6421 (c80130fb3, merged 2026-07-28T00:35:39Z) | `c419112b8e709dacf8480f011ae4be43` | `c3b04339e83b25e4` |
| 11 | `pds-w22-manifest-and-counts-honesty` | `in-flight` | #6426 (92553f9a6, merged 2026-07-28T00:36:09Z) | `aa8449f1e87e92dcb10b7cd79c11b556` | `bb574a4b1cd548e4` |
| 12 | `pds-w22-receipt-and-sidecar-honesty` | `in-flight` | #6423 (63581a76d, merged 2026-07-28T00:35:54Z) | `5b047d070b6948138ba2d93a9c7dfcdf` | `e6163392af09cc72` |
| 13 | `pds-w22-status-commit-read-path` | `in-flight` | #6422 (c73f22a0b, merged 2026-07-28T00:35:47Z) | `dea44958d04d9ef4c841bbfcb16c342b` | `9ca5f9ebf51dccf1` |
| 14 | `pds-w22-triage-harness-and-crown-family` | `in-flight` | #6424 (e41b990b5, merged 2026-07-28T00:36:02Z) — ARTIFACT, not code | `d44bcf940784673578971fe08b2c4464` | `ebc01b3f7367ea6d` |
| 15 | `pds-w22-triage-remaining-rows` | `in-flight` | #6425 (311b375e9, merged 2026-07-27T22:45:14Z) — ARTIFACT, not code | `d36238ec0b0ac4f6da31b54eac6b153f` | `7dec1027d9833bf9` |

## By-content verification, per row

No row was closed on its old reason's say-so. Each command below was run and its output is the
proof. Zero rows failed to find their fix by content, so zero were reported-instead-of-closed.

1. **`pds-barkpark-stop-4000-fallback`** — absorbed by #8134 (74ff85b92)
   `git merge-base --is-ancestor 74ff85b92eefdf712f665fc5917573aed10d04fd origin/main` -> 0; `git show origin/main:bin/barkpark \| grep -n "Stale pidfile: discarding"` -> line 237

2. **`pds-bl-bounded-import-unpack`** — #8130 (2563a6cd6)
   `git merge-base --is-ancestor 2563a6cd6a5192cf9dad41a7194dc0d661541ed0 origin/main` -> 0; `git show origin/main:docs/api-v1.md \| wc -c` -> **13884**

3. **`pds-bl-export-controller-matcherror-on-disconnect`** — #8135 (2c6968e98)
   `git merge-base --is-ancestor 2c6968e984de4cb2412354c224a2b658f116791a origin/main` -> 0; `git ls-tree -r --name-only origin/main \| grep error_envelope_negotiation_test` -> present

4. **`pds-bl-start-server-trusts-the-pidfile`** — #8134 (74ff85b92)
   `git show origin/main:scripts/barkpark-boot-selftest.sh \| wc -c` -> 17353; same file line 46 pins `REFERENCE_REV="0bff57e4f500e9c9fc99424fa2635ca9988be725"`

5. **`pds-bl-surface-durable-reason`** — #8133 (7b0af004d)
   `git grep -n reopen_trigger origin/main -- internal/taskboard` -> detail_render.go:204 emitStrip("reopens when", ...); detail_render_test.go:773 TestDetailReopenTriggerStrip

6. **`pds-bl-task-create-dedup-scan-lies`** — #8136 (a144d3c81)
   `git grep -n dedup_unavailable origin/main -- api/lib` -> tasks/dedup.ex:118, plugins/github/intake.ex:225, content/errors.ex:445

7. **`pds-w24-census-instrument`** — #8131 (a74433aa5)
   `git show origin/main:scripts/pds-ledger-census.sh \| grep -n '^CANONICAL_OPEN'` -> 244:CANONICAL_OPEN = "open"; `... pds-ledger-census_test.sh \| wc -c` -> 41736

8. **`pds-w24-hollowness-unwritable`** — #8132 (18addd9de)
   `git grep -ln reopen_trigger origin/main -- api/lib` -> 4 files; `git show origin/main:api/test/barkpark/content/disposition_trigger_gate_test.exs \| wc -l` -> **376**

9. **`pds-w22-close-holder-criteria-honesty`** — #6420 (448749cf1, merged 2026-07-28T00:35:32Z)
   `git merge-base --is-ancestor 448749cf183dc841aff2af50712fdb87ab10dfc9 origin/main` -> 0; `git grep -n holder_override origin/main -- api/lib` -> close.ex:81, tasks_controller.ex:492

10. **`pds-w22-deploy-stamp-and-harness`** — #6421 (c80130fb3, merged 2026-07-28T00:35:39Z)
   `git merge-base --is-ancestor c80130fb31b9d95a0b12d47c0f5a2d28aef0e109 origin/main` -> 0; `git show --stat` -> deploy/instance-deploy.sh +22, instance-deploy_test.sh +152

11. **`pds-w22-manifest-and-counts-honesty`** — #6426 (92553f9a6, merged 2026-07-28T00:36:09Z)
   `git merge-base --is-ancestor 92553f9a61c20726434fe9e15279505455e21a39 origin/main` -> 0; `git ls-tree -r --name-only origin/main \| grep cli_commands_manifest_test` -> present

12. **`pds-w22-receipt-and-sidecar-honesty`** — #6423 (63581a76d, merged 2026-07-28T00:35:54Z)
   `git merge-base --is-ancestor 63581a76dee7669723ca27fbb7af7a96368fd5a4 origin/main` -> 0; `git show --stat` -> internal/cli/cloud_workspace_cmd.go +214, _test.go +337

13. **`pds-w22-status-commit-read-path`** — #6422 (c73f22a0b, merged 2026-07-28T00:35:47Z)
   `git merge-base --is-ancestor c73f22a0b308b7b429bafb6f9a419e57c731dc62 origin/main` -> 0; `git show --stat` -> api/lib/barkpark/status.ex +22, status_controller_test.exs +31

14. **`pds-w22-triage-harness-and-crown-family`** — #6424 (e41b990b5, merged 2026-07-28T00:36:02Z) — ARTIFACT, not code
   `git ls-tree -r --name-only origin/main \| grep pds-w22-harness-crown-triage` -> tooling/grip/ledger/pds-w22-harness-crown-triage-2026-07-27.md; `git show --stat` -> that file alone, +137

15. **`pds-w22-triage-remaining-rows`** — #6425 (311b375e9, merged 2026-07-27T22:45:14Z) — ARTIFACT, not code
   `git ls-tree -r --name-only origin/main \| grep pds-w22-remaining-rows-triage` -> tooling/grip/ledger/pds-w22-remaining-rows-triage-2026-07-27.md; `git show --stat` -> that file alone, +80

## Four stale figures the old reasons carried, and a fifth still in the code

| claim | stored as | true on origin/main | where |
|---|---|---|---|
| `docs/api-v1.md` size | 13992 B, "headroom 8 B" | **13884 B**, headroom 116 B | `git show origin/main:docs/api-v1.md \| wc -c` |
| `reopen_trigger` code writers | "exists in zero files" | **4 files** | `git grep -ln reopen_trigger origin/main -- api/lib` |
| `disposition` code writers | "ZERO code writers repo-wide" | **3** under `api/lib/barkpark/tasks` | `dedup.ex`, `stage.ex`, `ttl_sweeper.ex` |
| rows with a reopen trigger | "on zero rows" | **29 structured** (+13 prose-only) | census `reopen_triggers_structured` |

Two further corrections are to *this wave's brief*, not to the ledger, and matter because a
builder who trusted them would have written a fresh lie:

- The brief gave `13998` as the true byte count. That was true only at `#8130`'s merge commit
  `2563a6cd6`; commit `662697194` ("Keep API error guide within budget") later shrank the file.
  The figure has now been wrong three ways. **A byte count quoted from any commit but
  `origin/main` HEAD is a lie with a shelf life.**
- The brief located the 376-line gate at `api/test/barkpark/tasks/disposition_trigger_gate_test.exs`.
  `git show origin/main:` reports that path does not exist. The real path is
  `api/test/barkpark/content/disposition_trigger_gate_test.exs` (376 lines confirmed by `wc -l`).

The fifth instance is still live in code and is named in the `pds-bl-task-create-dedup-scan-lies`
reason: `api/lib/barkpark/content/errors.ex:439` still justifies deferring an honest 503 by
citing "3 bytes of headroom" in `docs/api-v1.md`. There are 116.

## Clause 1 was proven BEFORE the write, not after

Collapsing distinct reasons into shared boilerplate is this epic's known last-step trap (wave 22
put one 644 B string into 19 rows). So the 183 pre-existing board hashes were extracted first —
by patching the census to emit `sorted(hashes)` — and the 15 candidate reasons were checked
against that set, in the census's own hash space, before a single row was staged.

- 15 distinct md5s, 15 distinct census hashes.
- **Zero** collisions against the 183.
- PDS-D336 enforced mechanically: every reason must contain `RETIRES`, `EXPLICIT NEGATIVE` and
  `BLOCKER TO REOPEN`, and the first 80 characters after each of the latter two must be 15/15
  distinct. A template collapses those two counts before anything else.
- Reason lengths run 870–1048 B, so no row is a padded clone of another.

## Result

| census field | before | after |
|---|---|---|
| `off_vocabulary_total` | 15 | **0** |
| `off_vocabulary` | `{"OPEN": 8, "in-flight": 7}` | `{}` |
| `reason_hashes_distinct` == `reasons_non_empty` | 183 == 183 | 213 == 213 |

The certifying run was coherent end to end: `CENSUS_RC=0`, `drifted 0`, `duplicates 0`,
`closure_size 353`, anchor `2026-07-31T00:21:23.535114Z` derived from
`paper/pds-wave-27-2026-07-31`. `reasons_non_empty` rose past the 198 floor because sibling
wave-27 slices were writing concurrently; the load-bearing equality held at every observation
(183, 193, 197, 213).

## Honest note on exit codes, since that is the epic's whole subject

Several census invocations during this round exited NONZERO and none of them was a clause-3
failure:

- `RC=4 SNAPSHOT INCOHERENT` — rows updated inside the scan window, or served on two pages.
  Roughly six sibling builders were writing this same ledger.
- `RC=2 FAIL CLOSED` — HTTP 500 from a loaded server, including on the anchor Paper read, where
  the census refuses to fall back to `now()` "which would excuse every row this round filed".

Both are the instrument being correct. `off_vocabulary_total` read `0` in **every** invocation
that produced a payload at all; the figures quoted above are from the one run that was clean
end to end. The inverse trap is worth restating: `bash c.sh ... | tail -20; echo $?` prints the
exit code of `tail`, so a FAILING census reads as RC=0. Redirect to a file and capture `$?`.
