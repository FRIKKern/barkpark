<!-- doc-tier: cold | canonical-for: pds-w25-board-repin-recipe | budget: 20000tok -->

# PDS wave 25 — board re-pin at a named instant, and the pinned shard manifest

> HISTORICAL RECORD (2026-07-30) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

RE-DERIVATION RECIPE. Nothing below is quotable without re-running it; the board moves.

```
cd <repo> && git show origin/main:scripts/pds-ledger-census.sh > /tmp/census.sh
bash /tmp/census.sh --json                 # aggregate census (exit 0)
bash /tmp/census.sh --assert-round-done    # the done-condition (exit 1 today)
python3 tooling/grip/ledger/pds-w25-rowdump.py /tmp/rN.json   # row-level, same discipline
```

## Instants

| run | started (UTC) | finished | corpus | closure | live |
|---|---|---|---|---|---|
| A | 2026-07-30T17:36:37.442369Z | 2026-07-30T17:36:58.676181Z | 3810 | 291 | 164 |
| B | 2026-07-30T17:47:56.643487Z | 2026-07-30T17:48:31.622129Z | 3813 | 291 | 164 |

## Drift A -> B (0 field change(s) over 0 rows)

**ZERO rows moved.** Not one of the 291 closure rows changed `lifecycle_status`, `disposition`, `disposition_reason` (md5), `disposition_owner`, `reopen_trigger`, `_rev` or `_updatedAt` across the ~12-minute gap. The aggregate census diff agrees: every count is byte-identical between the two runs; the ONLY deltas are `corpus_size` 3810 -> 3813 (three `type:task` rows born OUTSIDE this closure) and the instant itself.

So the board is NOT moving right now. The newest `_updatedAt` anywhere in the closure is `2026-07-30T16:55:00.811419Z` — **40 minutes before** instant A.

### The drift the survey saw, now NAMED

Strategize measured 167 live at 16:52:04-16:52:23Z; Survey measured 164 at ~17:19Z. That is **-3**, and the three rows are identifiable by `_updatedAt` + `claim.closed_at`:

| row | closed_at | closed_by | now |
|---|---|---|---|
| `pds-w24-hollowness-unwritable` | 2026-07-30T16:53:17.401863Z | `lead-merge` | done |
| `pds-bl-export-controller-matcherror-on-disconnect` | 2026-07-30T16:53:32.477157Z | `lead-merge` | done |
| `pds-bl-bounded-import-unpack` | 2026-07-30T16:54:40.544480Z | `lead-merge` | done |

WHO: `lead-merge`, the wave-24 seal pass closing its own rows — not the 87 open claims and not a concurrent wave. The digest's other figure ("165, my independent re-derivation") was a SECOND METHOD at the same instant, not a second instant; the honest reading is 167 -> 164 by three `lead-merge` closes, then flat.

## Class partition (pinned at instant B)

| class | rows | shard-eligible |
|---|---|---|
| bare | 34 | yes |
| open-normalise | 103 | yes |
| parked | 27 | yes |
| terminal-with-disposition | 15 | separate slice |
| terminal-silent | 112 | separate slice |

DISJOINTNESS ASSERTIONS (all must hold before any builder flies):

- pairwise overlap between bare / open-normalise / parked: **0**
- union of the three live classes == the live set: **True** (164 == 164)
- `sort | uniq -d` over the manifest's doc_ids: **empty** (asserted below by construction)

## The gap the provisional slicing leaves — it is 27, not 13

S3-S5 as briefed reads `104 open-normalise + 34 bare + 14 terminal = 152`. Measured: **103 + 34 + 15 = 152**, and the live set is **164**. The unassigned rows are not a scattered 13 — they are the ENTIRE `parked` class, all 27 of them, which no provisional slice names. 19 of those 27 are the boilerplate S2 recovers; the other **8 are the row-specific template parks the wish says NOT to touch** — but "do not touch" is not the same as "do not assign": every one of them carries `reopen_trigger = ""`, so all 8 are RED against any coverage clause that reads the field. They need an owner even if their reason text is left verbatim.

The 8: `pds-bl-w13-export-duration-unmeasured`, `pds-bl-w13-spill-dir-full-export-unobserved`, `pds-w11-paired-control-measure`, `pds-w12-measure`, `pds-w20-crown-collect-and-seal`, `pds-w20-crown-fire`, `task-328621eadb772c81`, `task-8db002bc83e78718`.

## Shard-selector hazards

1. **A `pds-` slug prefix selector silently drops 7 live rows** — not one. In the closure: `task-015fb9866bc2cc59` (open-normalise), `task-5c4f2673778d5ff0` (open-normalise), `task-fff1116564723b60` (open-normalise), `task-a0e37c21f73f8e26` (bare), `task-328621eadb772c81` (parked), `task-8db002bc83e78718` (parked), `task-e7bd4b127aaee4fc` (parked, AND one of the 19 boilerplate rows S2 recovers). Select by the manifest, never by slug shape.
2. **`pds-w12-crown-climb-preconditions` is `blocked`, not `open` — and it is UNWRITABLE in place.** `stage.ex:134` `@stageable ~w(considering researching open)` gates the TARGET, so `blocked -> blocked` is refused (`blocked` is not in the set) even though `Transitions.legal?/2` allows same->same. `{"blocked","open"}` IS in `@legal_pairs` (`transitions.ex:60`), so the only door writes the disposition *and* silently unblocks the row. Same shape as the 15 terminal rows: `{"done","open"}` / `{"cancelled","open"}` are legal, `done -> done` is not stageable. **16 of the 179 manifest rows have no in-place door.**

## THE MANIFEST

| doc_id | class | lifecycle | disposition | _rev | reason_md5 | owner |
|---|---|---|---|---|---|---|
| `pds-b-proof-instrument-control-auto` | open-normalise | open | open | `e7fa30c0d23dee6087f991c3b5d1c35e` | 127e972c | pds-harness-maintainer |
| `pds-backlog-bp-dev-pull-verb` | open-normalise | open | OPEN | `e347593ae9af249edcc8afdd978964d2` | e510a302 | pds-backlog-bp-dev-pull-verb |
| `pds-backlog-ci-scratch-target` | open-normalise | open | OPEN | `424eaa12f3f36ecaf98ccf45a53e60ba` | 186715ac | pds-backlog-ci-scratch-target |
| `pds-backlog-delete-reconciliation` | open-normalise | open | OPEN | `55f812648f2479477fec0e98e6596a95` | e1e5ccca | pds-backlog-delete-reconciliation |
| `pds-backlog-export-edge-idle-timeout` | open-normalise | open | OPEN | `279cf502239cdb9779e16af2e364ceaf` | 276e02a6 | pds-backlog-export-edge-idle-timeout |
| `pds-backlog-flat-verb-workspace-honesty` | open-normalise | open | OPEN | `0d325fd295990f4f1b881d7fceb6f782` | b9055d06 | pds-backlog-flat-verb-workspace-honesty |
| `pds-backlog-g8-identity-reconciliation` | open-normalise | open | OPEN | `e065fad6a03418535dec7eeed6f44f53` | 2a76351e | pds-backlog-g8-identity-reconciliation |
| `pds-backlog-import-savepoint-honesty` | open-normalise | open | OPEN | `60883ce41a3b9cfcc1a16b86ccebf2bf` | a08ce3d7 | pds-bl-clean-import-ungated-500 |
| `pds-barkpark-reload-wedged-server-deadend` | bare | open | — | `da20a58fc39242898b412bf7e9e3f4ae` | — | — |
| `pds-barkpark-stop-4000-fallback` | terminal-with-disposition | done | OPEN | `147c0bc843e1d2cd86fab582b0892f93` | 1dcce457 | pds-barkpark-stop-4000-fallback |
| `pds-bl-admin-token-mint-path` | open-normalise | open | OPEN | `c4f196991845a6c2c94cc46782fbcdcf` | 0a58a1a3 | pds-bl-owner-walk-reaches-the-mint |
| `pds-bl-artdir-no-cleanup` | open-normalise | open | open | `a312efc9c650d2770399fb42146256c8` | 12e6bf39 | pds-harness-maintainer |
| `pds-bl-artifact-dir-retention` | open-normalise | open | OPEN | `ba9378082b87bb6feb3eedb0588808dc` | 62fe0d75 | pds-bl-artifact-dir-retention |
| `pds-bl-autostamp-elixir-guard` | open-normalise | open | OPEN | `d51495582ef98431071e5adb577dd222` | 2474c267 | pds-w22-close-holder-criteria-honesty |
| `pds-bl-bandit-request-line-ceiling` | open-normalise | open | OPEN | `4bbe8803ec51f3512dc0278bcf97816d` | 2c4fb46f | pds-bl-bandit-request-line-ceiling |
| `pds-bl-blob-sidecar-byte-verify` | open-normalise | open | OPEN | `1d73e6edcec044733df1fae715903ecf` | bcd8a757 | pds-w22-receipt-and-sidecar-honesty |
| `pds-bl-blob-storage-readback` | open-normalise | open | OPEN | `e572c0e0702d8ca58187db3cb76e1357` | 39142771 | pds-w22-receipt-and-sidecar-honesty |
| `pds-bl-bootstrap-cross-tenant-theft` | open-normalise | open | OPEN | `f115f1bca53fa8c7375496fc6d5b92c5` | b6656a50 | pds-bl-bootstrap-cross-tenant-theft |
| `pds-bl-bounded-import-unpack` | terminal-with-disposition | done | OPEN | `34feb582e9bf8bbcf846edc7bbc12eaf` | 24447518 | wave-24 |
| `pds-bl-bp-search-false-negative` | parked | considering | parked | `24b5e2f32e75598a0c1925045d58ae98` | 4f556ba7 | pds-charter-steward |
| `pds-bl-charter-anchors-stale-vs-frozen-blob` | bare | open | — | `0f13a4e442f16251a53b1bc67b161ba6` | — | — |
| `pds-bl-charter-line-refs-stale` | open-normalise | open | open | `12aadc1e2f881bfe53935445e88298df` | a8f528ce | pds-charter-steward |
| `pds-bl-charter-slot-durability` | open-normalise | open | open | `01a978799eb057ae725bb0845526b633` | c3c32ac9 | pds-charter-steward |
| `pds-bl-clean-import-ungated-500` | open-normalise | open | OPEN | `05d0a2e9078559d0b59727782c0be794` | 5d7c7bb1 | pds-bl-clean-import-ungated-500 |
| `pds-bl-clear-pull-provenance` | open-normalise | open | OPEN | `03bbe165c6a895742f7cdc00e0fab7f1` | 427d4b93 | pds-bl-clear-pull-provenance |
| `pds-bl-cli-budget-window` | bare | open | — | `62668f738d4997b651983c6ce8dbe3ce` | — | — |
| `pds-bl-close-audit-gaps` | open-normalise | open | OPEN | `f0b85e4ca2738d7232f547aa7dfcde03` | c960a063 | pds-w22-close-holder-criteria-honesty |
| `pds-bl-close-holder-and-criteria-gate` | open-normalise | open | OPEN | `0912c42a7b537d2360fcfaa81a2e9ba1` | 0ae8ed7e | pds-w22-close-holder-criteria-honesty |
| `pds-bl-collect-stillrunning-hides-force` | open-normalise | open | open | `89642b321bdfb85b5627117da8551774` | e82c3e26 | pds-harness-maintainer |
| `pds-bl-cond-d-job-blind-false-abort` | bare | open | — | `74f13fcf0523db67b0cb2ebf1d23b1fa` | — | — |
| `pds-bl-counts-perspective-honesty` | open-normalise | open | OPEN | `fda82c51c2b4ed0b1a19b20275dd9aba` | e9825c98 | pds-bl-counts-perspective-honesty |
| `pds-bl-crown-launch-armed-without-liveness` | bare | open | — | `1052bce034eaf092cb309e0aa513a05e` | — | — |
| `pds-bl-d220a-keyed-on-a-proxy` | open-normalise | open | open | `1f24f93cb68d6dcb1b359aeb0f2df294` | 923af5e5 | pds-harness-maintainer |
| `pds-bl-dedup-unavailable-error-code` | bare | open | — | `ac65b581ea26cceaa57086ace22aaa63` | — | — |
| `pds-bl-deploy-readback-json-envelope` | bare | open | — | `fea0cdbc7c5ac841b02f85237eaf84c4` | — | — |
| `pds-bl-deploy-success-without-advance` | open-normalise | open | OPEN | `adba57a3b281ff5a0df5e94c5a3bf89e` | 1cea64e6 | pds-w22-deploy-readback |
| `pds-bl-deployed-sha-override-unimplemented` | open-normalise | open | OPEN | `278a940908361e038790ccb019dd0dd1` | f708c49b | wave-25 |
| `pds-bl-doc-patch-propagation-lag` | open-normalise | open | OPEN | `a1ada7f4a92be417795843196af859f9` | 8c2cae86 | pds-bl-doc-patch-propagation-lag |
| `pds-bl-documents-chunk-near-peer` | parked | considering | parked | `df29e6b76eeb901aa62fafb138f887b1` | 4f556ba7 | pds-charter-steward |
| `pds-bl-e3-bare-slug-dynamic-derivation` | bare | open | — | `62df84e78494beed8145d4c8fd4ae32f` | — | — |
| `pds-bl-export-controller-matcherror-on-disconnect` | terminal-with-disposition | done | OPEN | `97cdb895a1a0bebb740761a33e0115cc` | 2e0dfbf4 | wave-24 |
| `pds-bl-export-latency-instrument` | parked | considering | parked | `122e6d7b2bf56145b5066d531608bc33` | 4f556ba7 | pds-charter-steward |
| `pds-bl-export-pool-starvation` | open-normalise | open | OPEN | `c7319e506187d595552a2ffd8fdc73d3` | be9a0bd0 | pds-bl-export-pool-starvation |
| `pds-bl-export-single-flight-guard` | open-normalise | open | OPEN | `f26492585ac1e4339d1bfe7845ec8e8e` | d8a11511 | pds-bl-export-pool-starvation |
| `pds-bl-export-teardown-lockstep-untested` | open-normalise | open | OPEN | `f114cd3e44fd363a35132f5d5dcfc05a` | ab21d7bd | pds-bl-export-teardown-lockstep-untested |
| `pds-bl-export-wire-bytes-and-vary-after-send-file` | bare | open | — | `46c158094c45c157f673a5f0f3116fff` | — | — |
| `pds-bl-failed-build-wipes-rollback-root` | bare | open | — | `1347261449fbc4c8fffca81b81afd735` | — | — |
| `pds-bl-floor-env-silent-revert` | bare | open | — | `1ca3739ab3c12ef514480e4c8e75e481` | — | — |
| `pds-bl-format-drift-hygiene` | open-normalise | open | OPEN | `4b90721c56225bb73da92224cc463b25` | 2ac90974 | pds-bl-format-drift-hygiene |
| `pds-bl-full-export-store-host-scoping` | parked | considering | parked | `6ea5c3af6f229e8eddfb7081294945db` | 4f556ba7 | pds-charter-steward |
| `pds-bl-gate-b-anticorrelated` | open-normalise | open | open | `a0052bafb935842fca2c62916237ca46` | b01f5811 | lead-pds |
| `pds-bl-go-literal-selftest-false-red-macos` | bare | open | — | `395920a7223db54c728ae59b726a3fee` | — | — |
| `pds-bl-guerrilla-ssr-leftovers` | open-normalise | open | OPEN | `39498d17a824ea10089d2012233a370b` | 860a5b9d | pds-bl-guerrilla-ssr-leftovers |
| `pds-bl-guerrilla-stale-build-prod-trap` | parked | considering | parked | `70b70a7ffe8aebeb2c9ae30d57df50de` | 4f556ba7 | pds-charter-steward |
| `pds-bl-harness-not-relocatable` | open-normalise | open | open | `746106660b883b2e5d63da9b36e87d8c` | 38ad8fee | pds-harness-maintainer |
| `pds-bl-hook-observed-rev-defeats-fence` | open-normalise | open | OPEN | `ad463c23a213b0a05bbf7fb8282e7192` | f40b6e47 | pds-w22-close-holder-criteria-honesty |
| `pds-bl-import-409-http-test` | open-normalise | open | OPEN | `2552f4df93055928cdbdcf11006b369f` | 2093919f | pds-backlog-ci-scratch-target |
| `pds-bl-import-ddl-deadlock-flake` | bare | open | — | `a3f9fcc5b890b8595abaf7b258b02e15` | — | — |
| `pds-bl-import-receipt-counts` | open-normalise | open | OPEN | `c7ac38c12adba8f096de87b770e6fe60` | f2b51e30 | pds-w22-receipt-and-sidecar-honesty |
| `pds-bl-large-task-write-500` | open-normalise | open | OPEN | `a1a6494e7fdbbab6a8919e68f269996c` | 10cc31c3 | pds-bl-large-task-write-500 |
| `pds-bl-launcher-assert-scratch-env` | bare | open | — | `095f58e8ab67b92d9576b3ffaa9cfa14` | — | — |
| `pds-bl-launcher-statedir-fresh-transcript` | open-normalise | open | open | `f451256238a25af6485624f75440f81a` | 32a6c325 | pds-harness-maintainer |
| `pds-bl-legb-visibility-control-n3` | open-normalise | open | open | `591f2cf8dc37081ba262b8a434b8486f` | 9845923a | pds-harness-maintainer |
| `pds-bl-legb-visibility-false-red` | parked | considering | parked | `102a33cc3b6e3d4c56412f3fee63850f` | 4f556ba7 | pds-charter-steward |
| `pds-bl-lifecycle-check-precondition` | open-normalise | open | open | `947d473a04362e7e723752c33a992e41` | 7765ef3e | pds-harness-maintainer |
| `pds-bl-manifest-writes-fails-open` | open-normalise | open | OPEN | `25372032fed779406da94ad9aaec5ece` | eeb3155a | wave-25 |
| `pds-bl-merge-gate-key-unimplemented` | open-normalise | open | OPEN | `7e0acc26441b1ef2ad0cd9fe07147deb` | 9e3b5b47 | pds-w22-close-holder-criteria-honesty |
| `pds-bl-metric-orphan-schema-row` | open-normalise | open | open | `c122cc3dcdbbfea760159a6495f0deb3` | 0e919005 | pds-schema-owner |
| `pds-bl-migration-amended-in-place-divergence` | bare | open | — | `bbf6e8f580562b981aeb38e70232f52a` | — | — |
| `pds-bl-nonint-comparison-fallthrough` | open-normalise | open | open | `0fcb6d51cb9d58d9aa34ab2c8a5efcb9` | 891be2de | pds-harness-maintainer |
| `pds-bl-owner-walk-reaches-the-mint` | open-normalise | open | OPEN | `0b20ab1b11b1e0b553e6356d959beb81` | 0d382b63 | pds-bl-owner-walk-reaches-the-mint |
| `pds-bl-park-note-evaporates` | open-normalise | open | open | `f1868d2526cb97639f56ea950ad76396` | 227e615c | bp-task-ledger-maintainer |
| `pds-bl-pds-harness-no-ci` | bare | open | — | `d09e725fbe3cd91deb831a14ca949463` | — | — |
| `pds-bl-peak-budget-enforcement` | open-normalise | open | open | `d7c09a7bf60fb54293b4e2dc1c63f083` | 6f95ba1a | pds-harness-maintainer |
| `pds-bl-peak-lock-sequencing` | open-normalise | open | open | `e533247d67b67def71c6c2a0c9e39af0` | afda6098 | pds-harness-maintainer |
| `pds-bl-personal-local-doc-staleness` | open-normalise | open | OPEN | `12126c47cf007a52f562db30d15cb65a` | 6929ecde | task-5c4f2673778d5ff0 |
| `pds-bl-pid-live-identity-blind` | open-normalise | open | open | `71636a173d5cbc38077f5200d0a9249c` | e0caa4eb | pds-harness-maintainer |
| `pds-bl-pin-webhook-deliveries-inner-join` | open-normalise | open | OPEN | `742e2c9d99cad3fde5b8db69156739f2` | f888e113 | pds-bl-pin-webhook-deliveries-inner-join |
| `pds-bl-place-directory-install-echoes-transport` | bare | open | — | `ba4a84eae5cb875577056f9c8e61dcc4` | — | — |
| `pds-bl-plugin-cli-command-writes-fails-open` | open-normalise | open | OPEN | `f25266e72173d785d4abe057b6717495` | c10b989a | wave-25 |
| `pds-bl-plugin-doc-state-classification` | open-normalise | open | OPEN | `b40dee9c5e2c14223460737d42df1104` | 9feb0e3a | pds-bl-plugin-doc-state-classification |
| `pds-bl-private-orphan-roster-probe` | open-normalise | open | open | `681f32a581751bf6dce3fbaf307c2b83` | 696f43ac | pds-schema-owner |
| `pds-bl-provision-schemas-pulled-warning` | open-normalise | open | OPEN | `8de8208f3dc3cb3a7bd3ef45000de30d` | e749df2c | pds-bl-clear-pull-provenance |
| `pds-bl-publish-wall-tag-count-hint` | parked | considering | parked | `3c667f29ac2163af3d14c24d07dbc31f` | 4f556ba7 | pds-charter-steward |
| `pds-bl-recover-lost-park-notes` | bare | open | — | `cf72eb4d44d1e1f31d9778833fd7d2ac` | — | — |
| `pds-bl-repull-into-populated-target-500` | open-normalise | open | open | `c2ebeaffe67d8ef397823f7205e70d72` | 5090798f | pds-scratch-target-maintainer |
| `pds-bl-rss-ambient-caveat` | open-normalise | open | open | `d5a25389e63288ea722f33ceb0fd3d4a` | 130543a3 | pds-harness-maintainer |
| `pds-bl-rung6-percolumn-invisible-on-green` | open-normalise | open | open | `3ac90d2c7a5c6af28136cc8ea6abe0a3` | 0b174757 | pds-harness-maintainer |
| `pds-bl-sampler-window-default-retired-engine` | open-normalise | open | open | `ab4734f6335669407eeb240e9534660b` | 6678d586 | pds-harness-maintainer |
| `pds-bl-scratch-pointer-concurrency` | open-normalise | open | open | `935563171289c0e52fe6c0c46cf585e5` | a785678a | pds-scratch-target-maintainer |
| `pds-bl-scratch-pointer-explicit-default` | open-normalise | open | open | `be093351900ee828461b258f35be53bf` | 337f85c0 | pds-scratch-target-maintainer |
| `pds-bl-scratch-teardown-strands-the-survivor` | bare | open | — | `e4202291db67c35e7101d71d94105514` | — | — |
| `pds-bl-scripts-md-budgets-unenforced` | open-normalise | considering | OPEN | `00ba324e5894c0e06e9d786e9bc351ae` | 1b9ba224 | wave-25 |
| `pds-bl-secret-scan-invisible-tables` | open-normalise | open | open | `114802f5cbcd7316c311f5cbaaaad5d4` | a6f1e606 | pds-harness-maintainer |
| `pds-bl-site-create-ambient-dataset` | open-normalise | open | OPEN | `09c84dae681ceec63b4da2d2f4df9c72` | 2bf53c5f | pds-backlog-flat-verb-workspace-honesty |
| `pds-bl-sobelow-baseline-line-shift-reconcile` | open-normalise | open | OPEN | `10b4adc0d40dc738e1d0355aa09e187e` | 022a5576 | pds-bl-sobelow-baseline-line-shift-reconcile |
| `pds-bl-sobelow-baseline-line-shift-tenancy` | open-normalise | open | OPEN | `6bf33ea7ffb02534ffb403a9ac2533c1` | 531959c7 | pds-bl-sobelow-baseline-line-shift-reconcile |
| `pds-bl-source-box-too-small-for-full-export` | parked | considering | parked | `2a497c5fc9a6aeccc5a445a9110a5f32` | 4f556ba7 | pds-charter-steward |
| `pds-bl-spill-dir-path-drift` | open-normalise | open | OPEN | `c8224cb0f2e8bcaf9113f6a928be3a8f` | 9d48b1f3 | pds-w11-janitor-engine-handshake |
| `pds-bl-stamp-silent-noop` | open-normalise | open | open | `849a06df90c4efd8c24069f5c8f800e8` | 8dfada52 | bp-task-ledger-maintainer |
| `pds-bl-stamp-trailing-newline-deadend` | open-normalise | open | open | `80986853f860262562a56cea32c4c1d9` | 87550316 | pds-harness-maintainer |
| `pds-bl-stamp-writeback-reverts-a-stamped-criterion` | bare | open | — | `f77c6b25435bdeee2d50f1bb4483393e` | — | — |
| `pds-bl-start-server-trusts-the-pidfile` | terminal-with-disposition | done | OPEN | `7e1f4431db7118eed7403bcd563bd7b1` | c81caadb | wave-24 |
| `pds-bl-step1-grain-no-control` | open-normalise | open | open | `fc7a51fa32a9e4254fdd7c0a0552a6b5` | 27e7689a | pds-harness-maintainer |
| `pds-bl-step3-control-leg-grammar-guard` | open-normalise | open | open | `1a2874a884b166637ce93647b29e63e4` | 3773d938 | pds-harness-maintainer |
| `pds-bl-step5-faildemo-passline-selfdescription` | parked | considering | parked | `dd5dcc3821a70afbf4521af2c88d9f71` | 4f556ba7 | pds-charter-steward |
| `pds-bl-step6-control-inert-at-sha-parity` | bare | open | — | `42e6cba49d21cd85650087a91c00ad22` | — | — |
| `pds-bl-step6-tag-exclusion-stale-comment` | open-normalise | open | open | `da393ad5f62a014a30e0680a1bf40d08` | f1571e80 | pds-harness-maintainer |
| `pds-bl-step8-cross-invocation-gap` | bare | open | — | `1aa914e094861027814f0a113b0688aa` | — | — |
| `pds-bl-streaming-workspace-export` | open-normalise | open | OPEN | `dbc1696123371a8c20155ba30b7580f5` | 6e35d897 | pds-bl-bounded-import-unpack |
| `pds-bl-surface-durable-reason` | terminal-with-disposition | done | OPEN | `f2e51b95700fdb578b8a8e14790c9409` | 650ab9b9 | wave-24 |
| `pds-bl-tag-schema-frozen-in-stamped-slot` | parked | considering | parked | `be353851afd1b51dac250bc70b93d3bd` | 4f556ba7 | pds-charter-steward |
| `pds-bl-tagregistry-guard-no-rung` | bare | open | — | `995c824d130042950703280932815234` | — | — |
| `pds-bl-task-create-dedup-scan-lies` | terminal-with-disposition | done | OPEN | `6c10c6d26d810d760e2c8d32eaf877e0` | 26bab6e5 | wave-24 |
| `pds-bl-task-events-carry-no-worker` | open-normalise | open | OPEN | `f9290c6a8dc7b07e25ca11a2f5bd82e5` | d8134219 | pds-w22-close-holder-criteria-honesty |
| `pds-bl-tickets-local-otp28-divergence` | open-normalise | open | OPEN | `2442f52a813e7f0d0a17226a2cabee4e` | 3951d47a | pds-bl-tickets-local-otp28-divergence |
| `pds-bl-tickets-ten-undiagnosed-local-failures` | bare | open | — | `d228821d622654715307eede82876ad2` | — | — |
| `pds-bl-token-deny-control-ammo` | open-normalise | open | OPEN | `71d90dd0ec63e87072e98def23e80cd0` | 3776ce42 | pds-bl-token-deny-control-ammo |
| `pds-bl-up-seed-remint-crash-after-revoke` | bare | open | — | `83d470951de16c75a94d2bd20a1d1eb3` | — | — |
| `pds-bl-w13-cond-d-no-reservation` | open-normalise | open | open | `807f508a2cdff66f0dcccd6c8c8d2fff` | ad89ccfc | pds-harness-maintainer |
| `pds-bl-w13-export-duration-unmeasured` | parked | considering | parked | `8a84125ad3fa2c7d422daa6b52383858` | 56e09551 | lead-pds |
| `pds-bl-w13-spill-dir-full-export-unobserved` | parked | considering | parked | `22b3cdbb68ebeeb0527501a6710d4f55` | 6f6abf68 | lead-pds |
| `pds-bl-w13-stale-worktree-prune` | parked | considering | parked | `9a2c50d1dbfde0631dd877a56f6ec584` | 4f556ba7 | pds-charter-steward |
| `pds-bl-w13-window-episode-n1` | parked | considering | parked | `ef5d8a0bfaf624cb93c2bfd572318544` | 4f556ba7 | pds-charter-steward |
| `pds-bl-w14-round2-standdown-risk` | open-normalise | considering | open | `229d440a0287d9d2275187f067dbec52` | c3695d92 | lead-pds |
| `pds-bl-w14-standdown-token-ruling` | open-normalise | open | open | `ba77d8f0cde741f6d2964ed36872d2fc` | 2dd00947 | lead-pds |
| `pds-bl-w16-arm-never-records-its-own-floor` | open-normalise | open | open | `0fb903f8c4a4b0cc07349cd3d3c0446d` | 936ce5ec | pds-harness-maintainer |
| `pds-bl-w16-failed-refetch-destroys-parked-bundle` | open-normalise | open | open | `8fabfc0c60257659edac951e6ce0251c` | 1c1eb89d | pds-harness-maintainer |
| `pds-bl-w16-full-meta-permissive-default` | open-normalise | open | OPEN | `b3dc97a4adddedafce91390f5ecedcf6` | 5f7d8ae6 | wave-25 |
| `pds-bl-w16-launcher-one-shot-burns-the-window` | open-normalise | open | open | `a297e28f8e83c8a3d49758750093009b` | c7e0697c | pds-harness-maintainer |
| `pds-bl-w16-prewarm-warms-the-wrong-build-tree` | open-normalise | open | open | `d8f14c421329d34f24d25fbe2082a5ff` | 9af7451f | pds-harness-maintainer |
| `pds-bl-w16-sampler-loses-its-own-evidence` | open-normalise | open | open | `7fb2f3b858fb0b7ce7e49abb75527553` | 529f0437 | pds-harness-maintainer |
| `pds-bl-wave-paper-slug-collision` | bare | open | — | `2668b85f66faa39fe6865f58397af6d0` | — | — |
| `pds-bl-whole-workspace-shared-slug-stamp` | open-normalise | open | OPEN | `1eabf902146992d9b188e93673cf13ba` | 23170a67 | pds-bl-whole-workspace-shared-slug-stamp |
| `pds-crown-stamp-readback-evidence-diff` | open-normalise | open | open | `5023b781b614fb13b9a5292975a61f47` | 5ae74628 | pds-harness-maintainer |
| `pds-sheets-linearity-deterministic-guard` | parked | considering | parked | `623cf8efb7364833a464203655128ff0` | 4f556ba7 | pds-charter-steward |
| `pds-w10-climb-in-the-post-deploy-window` | parked | considering | parked | `24cc0f0777db4eb0d66a6deed8de2766` | 4f556ba7 | pds-charter-steward |
| `pds-w10-correlation-truncation-correction` | open-normalise | considering | open | `88410827ca618dffb10a4f48cfeda93a` | 7df73cb9 | pds-charter-steward |
| `pds-w10-fence-provenance-unknown` | parked | considering | parked | `d587e15f165bf58f65d5e3ee63f99bdc` | 4f556ba7 | pds-charter-steward |
| `pds-w10-instrumented-climb` | bare | open | — | `16bdc67e927456fd32d0164f88f12119` | — | — |
| `pds-w11-d193-leg-tension` | open-normalise | open | open | `a8e438a8402e6c957247622cf9f8a8cb` | e4de78da | pds-harness-maintainer |
| `pds-w11-janitor-engine-handshake` | open-normalise | open | OPEN | `fb7ef1049497d9c6705b1c083b33b9e4` | 13aca0e6 | pds-w11-janitor-engine-handshake |
| `pds-w11-paired-control-measure` | parked | considering | parked | `391ff9032aec7ead6c796a36ec11cb63` | f803bc91 | lead-pds |
| `pds-w11-router-export-comment-drift` | open-normalise | open | OPEN | `769d7675d1840751520214c900e6d1b3` | 48778daa | pds-bl-charter-anchors-stale-vs-frozen-blob |
| `pds-w11-storage-honest-envelope` | open-normalise | open | OPEN | `cdcb3b506258e01d61a3444a56c6406a` | 8ee79972 | pds-w11-storage-honest-envelope |
| `pds-w12-crown-climb-preconditions` | bare | blocked | — | `d009fa94ac6758ae3e22c8262af1f8a5` | — | — |
| `pds-w12-measure` | parked | considering | parked | `82ebbff63c34813cff2a4ffde53d3c0e` | 293a527d | lead-pds |
| `pds-w12-stamp-trailing-newline-gap` | parked | considering | parked | `8d18b61675fee2b794d6af528768096f` | 4f556ba7 | pds-charter-steward |
| `pds-w13-uphint-cold-prod-aware` | open-normalise | open | open | `ae6e253b980813a00deb2e7948d63cee` | 4020b43e | pds-scratch-target-maintainer |
| `pds-w16-prewarm-cc-dev-leg` | parked | considering | parked | `3ed0d3e655d7e53da38032343ab2bbe8` | 4f556ba7 | pds-charter-steward |
| `pds-w2-scratch-harness-ci` | bare | open | — | `8a1ecbfe0b0145a25c1ef2e23a45a5f8` | — | — |
| `pds-w20-crown-collect-and-seal` | parked | considering | parked | `d81cf65469d754cda87aeada624bdaf3` | 981244b7 | lead-pds |
| `pds-w20-crown-fire` | parked | considering | parked | `b68b619043105cbd6d36f6f86f3382a7` | b007540e | lead-pds |
| `pds-w22-close-holder-criteria-honesty` | terminal-with-disposition | done | in-flight | `5dd6ac032155687c6e3205c8e72f0c07` | 015170ba | lead-pds |
| `pds-w22-deploy-readback` | open-normalise | open | OPEN | `ff63510a96ad7fa6cf0e8124f2b993a5` | b720b8b7 | pds-w22-deploy-readback |
| `pds-w22-deploy-stamp-and-harness` | terminal-with-disposition | done | in-flight | `03a3a6b9b894f6a148f34dd9a8cb48bf` | 75787e39 | lead-pds |
| `pds-w22-manifest-and-counts-honesty` | terminal-with-disposition | done | in-flight | `c4507d5767a0b4bf1b3c43fd75d1d80a` | d4358d25 | lead-pds |
| `pds-w22-receipt-and-sidecar-honesty` | terminal-with-disposition | done | in-flight | `09a06035baf068e2a6b27589f32ed24b` | 5b83c0bd | lead-pds |
| `pds-w22-status-commit-read-path` | terminal-with-disposition | done | in-flight | `da1597010377539835b549fcbf63e2cf` | a37211e3 | lead-pds |
| `pds-w22-triage-harness-and-crown-family` | terminal-with-disposition | done | in-flight | `b3a3b8cdc55a20d03f2d50f56b021de5` | 2969e9e8 | lead-pds |
| `pds-w22-triage-remaining-rows` | terminal-with-disposition | done | in-flight | `48a3e85f80a156e735d42b1ef69d2617` | 1adf4435 | lead-pds |
| `pds-w23-cold-owner-verb-honesty` | bare | open | — | `4e245ece74080650314093cac73e916b` | — | — |
| `pds-w23-harness-liveness-and-registry` | bare | open | — | `73d2a2827595e3e486da02c5f35798bd` | — | — |
| `pds-w23-success-claim-registry` | bare | open | — | `465b2e112bd0e2e02bb3aed2bb4df4db` | — | — |
| `pds-w23-triage-round` | open-normalise | open | OPEN | `ce136eaffb8b9c35eb3cc7f1b8556989` | 6b41570f | wave-24 |
| `pds-w24-census-instrument` | terminal-with-disposition | done | OPEN | `126f663423d5341dc2760b7672b6f2be` | 8805fa56 | wave-24 |
| `pds-w24-hollowness-unwritable` | terminal-with-disposition | done | OPEN | `8688e7a81096285629540381c91b1c6a` | fde854ae | wave-24 |
| `pds-w3-shares-fidelity` | open-normalise | open | OPEN | `02474255201acf52165074df4d216022` | f5ac6134 | pds-w3-shares-fidelity |
| `pds-w5-citation-grep-honesty` | open-normalise | open | open | `db3b43ca83b36d9ed3b035799baafac4` | 7792255d | pds-harness-maintainer |
| `pds-w6-scratch-env-quoting-trap` | bare | open | — | `81133ebf941f01d0942f3385d74617ee` | — | — |
| `pds-w8-schema-column-count-gap` | parked | considering | parked | `aacf54b0d0b81c0d8c968b74e6e81d38` | 4f556ba7 | pds-charter-steward |
| `pds-w9-stale-2231-in-papers` | open-normalise | considering | open | `777a290e3268900d47ed9ec642c95e29` | 473fa07f | pds-papers-sweep-owner |
| `task-015fb9866bc2cc59` | open-normalise | open | OPEN | `31de0a1686b94f061b591ac66f066b70` | 662c228d | pds-bl-plugin-doc-state-classification |
| `task-328621eadb772c81` | parked | considering | parked | `757b87e45d419b8523700e46edece6c8` | 5b4c1259 | lead-pds |
| `task-5c4f2673778d5ff0` | open-normalise | open | OPEN | `dc5cf8058d9c2fae248a9a3f99bdf0c8` | 4fce32ac | task-5c4f2673778d5ff0 |
| `task-8db002bc83e78718` | parked | considering | parked | `4cc913fa4f227d975368d3c38f57a082` | 0c427305 | lead-pds |
| `task-a0e37c21f73f8e26` | bare | open | — | `d55e32d9d84145028cb52a5bcb93702c` | — | — |
| `task-e7bd4b127aaee4fc` | parked | considering | parked | `bcd076af8359b0f11a5d59703c68f0b7` | 4f556ba7 | pds-charter-steward |
| `task-fff1116564723b60` | open-normalise | open | OPEN | `409a3e8e5ed66cc637e246d75472b9cb` | 2d5ccf47 | pds-bl-pin-webhook-deliveries-inner-join |

(the 112 `terminal-silent` rows — terminal lifecycle AND no disposition — are outside the round entirely and are omitted.)

