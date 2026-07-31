<!-- doc-tier: cold -->

# PDS wave 27 — the 30 bare live rows, adjudicated and re-derivable

Recipe for `pds-w27-round-bare-30`. Every verdict below was re-derived **by content**
against `origin/main` at `6e53d27824206c5cbda4eb8916795921064165e9`, not inherited from the
slice brief. The point of this file is that the five stale-row rewrites and the two
duplicate pairs are auditable without re-reading the task.

## 0. The pinned manifest

`clause 1 only checks md5-distinctness`, so a false reason passes the census. The census
cannot catch that; only a per-row content re-check can. And the population itself must be
PINNED before any write — PDS-D352: the stage takes a blocking `pg_advisory_xact_lock` and
re-reads `observed_rev` INSIDE it while the controller accepts no `observed_rev`/`If-Match`,
so two concurrent writers both get 200 and the second silently overwrites.

| field | value |
|---|---|
| census | `origin/main:scripts/pds-ledger-census.sh --json --anchor-from-paper pds-wave-27-2026-07-31` |
| started | `2026-07-31T02:10:17.266002Z` |
| finished | `2026-07-31T02:10:39.194434Z` (21.93s) |
| round anchor | `2026-07-31T00:21:23.535114Z` |
| anchor source | `paper/pds-wave-27-2026-07-31 _createdAt 2026-07-31T00:21:23.535114Z` |
| source | `https://guerrilla.barkpark.cloud` |
| live / adjudicated / bare | 204 / 156 / 30 |
| deferred residue (post-anchor, PDS-D364) | 18 |

The manifest itself is committed beside this file as
`pds-w27-round-bare-30-manifest.json` — all 30 ids, the 18 residue ids and the instant.
Every stage write iterated that file, one row at a time; nothing re-derived the population live.

## 1. The verdicts

29 `open`, 1 `closed`. A disposition is **not** a lifecycle move: the one `closed` row keeps
`lifecycle_status=open`, and `pds-w12-crown-climb-preconditions` was adjudicated in place at
`lifecycle_status=blocked` — which proves live that `blocked -> blocked` is a legal
adjudication door (`transitions.ex:42`, `legal?/2:89-96`, `stage.ex:375`).

| # | row | disp | lifecycle | note | reason md5 | B |
|---:|---|---|---|---|---|---:|
| 1 | `pds-bl-armed-draft-twin-tagregistry` | **open** | open | CLEAN open — defect still true verbatim | `1ef96d20b39f3390d6e4b612bdbc6d56` | 864 |
| 2 | `pds-bl-census-count-true-total-assertion` | **open** | open | CLEAN open — defect still true verbatim | `2f17d84d2d15a4a8ae8715bb1773a648` | 772 |
| 3 | `pds-bl-census-read-path-500-under-load` | **open** | open | RUNTIME — probed live, did NOT reproduce | `93baf153c1ce588348f9fb5cf2311273` | 870 |
| 4 | `pds-bl-close-409-hint-promises-absent-fields` | **open** | open | STALE (MIS-STATED) — rewritten; surviving owner of the shared CLI-decoder fix | `6c5dead6c5f6a8469bd8f033aba43dc5` | 1241 |
| 5 | `pds-bl-cond-b-nonnumeric-floor-fail-direction` | **closed** | open | REFUTED BY EXPERIMENT — the only `closed` | `906b0e50dc0ef33ca6a1d6350cb4109a` | 1064 |
| 6 | `pds-bl-criteria-fence-http-level-pin` | **open** | open | CLEAN open — defect still true verbatim | `039305d2a53245d66cec50e1d2886dfd` | 875 |
| 7 | `pds-bl-disposition-owner-role-registry` | **open** | open | CLEAN open — MEASURED WORSE THAN FILED (22 slugs, not 16) | `6370c03c45ad3dce830bde0bcc5698ba` | 1212 |
| 8 | `pds-bl-export-close-delimited-silent-truncation` | **open** | open | CLEAN open — defect still true verbatim | `6fe5cd01ca79eea80ad7bc67dbc061ed` | 939 |
| 9 | `pds-bl-github-linkput-auto-publish-erasure` | **open** | open | STALE (headline FIXED) — rewritten to the residue | `901b2b8a489292ef976f8aed8d25b23b` | 1413 |
| 10 | `pds-bl-hetzner-create-image-post-condition` | **open** | open | DUPLICATE — pointer only | `5314c5a56cc14374896b11d140a6e1f2` | 1143 |
| 11 | `pds-bl-hzresdone-registry-row-vacuous` | **open** | open | SURVIVING OWNER of the hzResDone pair; count corrected 51 -> 50 | `e35b35e9cc19c71ef2333a152cd40674` | 1130 |
| 12 | `pds-bl-publish-refusal-drops-teaching-text` | **open** | open | STALE (MIS-LOCATED) — rewritten; one CLI fix with the row above | `feaf3d731bc5bc3e4c92c3a8274546ef` | 1183 |
| 13 | `pds-bl-remaining-os-create-sinks` | **open** | open | CLEAN open; line pointer fixed :699 -> :747 | `85f45084eefb7b7e8bed0bdcd670e3fd` | 1008 |
| 14 | `pds-bl-sync-source-bypasses-publish-door` | **open** | open | CLEAN open; line pointer fixed :277-279 -> :310 | `764e15f1fd2b1a07b13abc2227e51ddf` | 1002 |
| 15 | `pds-bl-tagregistry-standing-position-not-in-transcripts` | **open** | open | CLEAN open — defect still true verbatim | `80700af8c4ecb2e5be3c50a9b4ff6926` | 988 |
| 16 | `pds-bl-task-create-500-no-brief` | **open** | open | RUNTIME — unprobed, probe named | `ac14e92e1d4a79ab7367cc4be79d5be6` | 1215 |
| 17 | `pds-bl-task-stamp-silent-nonland` | **open** | open | STALE (priority-1 framing) — rewritten, narrowed | `d8f3187eceff085294097c75cdebc0b2` | 1170 |
| 18 | `pds-w12-crown-climb-preconditions` | **open** | blocked | RUNTIME — unprobed, probe named; adjudicated IN PLACE at lifecycle=blocked | `318dc2abb1ddfc6c4f4ebf4de02d93d9` | 1250 |
| 19 | `pds-w25-backlog-api-v1-relocation` | **open** | open | CLEAN open — defect still true verbatim | `eb8a8edc8a9655774752c5353115af4d` | 876 |
| 20 | `pds-w25-backlog-hzresdone-receipt` | **open** | open | DUPLICATE — pointer only; its 50 was the right number | `f01c0e6f61c728d9d2d8d66b292719b8` | 1036 |
| 21 | `pds-w25-backlog-merge-gate-split` | **open** | open | PARTIAL — topology + 554-row count NOT re-derived | `4f38411a2e6ec599beddd80bbb873d3a` | 899 |
| 22 | `pds-w25-backlog-studio-criteria-text-edit` | **open** | open | RUNTIME — unprobed, probe named; path pointer fixed | `72d8f44917602e7609490f5b94982164` | 1049 |
| 23 | `pds-w25-independent-review-stage-widening` | **open** | open | LEAD-GATED | `33b27a2381670b35c65ece2f3f8989c0` | 957 |
| 24 | `pds-w25-round-bare` | **open** | open | LEAD-GATED; records the stale 'non-stageable' premise | `cdb3d110b52158b7978ce601e9ab68e7` | 1069 |
| 25 | `pds-w25-round-open` | **open** | open | LEAD-GATED | `e2414ee4a859d1577fa8bef559742163` | 979 |
| 26 | `pds-w25-round-parked` | **open** | open | LEAD-GATED | `6f8ed3f0ee4089451b39a42adde3c586` | 913 |
| 27 | `pds-w26-close-pulse-readback` | **open** | open | CLEAN open — defect still true verbatim | `26ab0bc245be0c08bc2a513bdf2cab0b` | 921 |
| 28 | `pds-w26-close-refusal-taxonomy-remainder` | **open** | open | CLEAN open — defect still true verbatim | `a6f86361a8234efa543d806afe249ee9` | 1001 |
| 29 | `pds-w26-create-image-image-postcondition` | **open** | open | SURVIVING OWNER of the create-image pair | `456aab3159370fbadaebede9a08c231d` | 1044 |
| 30 | `pds-w26-mcp-stamp-bypasses-readback` | **open** | open | CLEAN open — defect still true verbatim | `80f8ad608e00d54d63c17fb8191b553f` | 1066 |

All 30 read back from the server byte-identical to what was sent (`bp task get <id> -o json`,
comparing stored `content.disposition` + `content.disposition_reason`) — 30/30 matched, 30
distinct md5s, 30 non-empty. A blank note would have been an INVISIBLE adjudication:
`detail_render.go:662-666` returns early on an empty reason and a shipped test pins that the
TUI then renders nothing at all, not even a label.

## 2. The by-content command behind each verdict

**`pds-bl-armed-draft-twin-tagregistry`** — `bp doc ls task --perspective drafts --limit 1000 --offset {0,1000,2000,3000,4000}` filtered to `drafts.*pds*` -> exactly 1 row (drafts.pds-bl-tagregistry-guard-no-rung); `bp doc get task pds-bl-tagregistry-guard-no-rung` -> rev 43e6314f314d830fa39f10defbc93ccb, criteria [T,T,F,T], evidence 609/373/0/131 B = 1113 B

**`pds-bl-census-count-true-total-assertion`** — `grep -c 'count=true' scripts/pds-ledger-census.sh` -> 0; this wave's own run: pages [1000,1000,1000,980], corpus_size 3980

**`pds-bl-census-read-path-500-under-load`** — LIVE PROBE: full paginated `GET /v1/data/query/production/task?limit=1000` sweep 2026-07-31T02:10:17.266002Z-02:10:39.194434Z under concurrent wave load -> 4 pages, 3980 docs, 21.93s, exit 0, stderr 0 B, ZERO 500s (did NOT reproduce)

**`pds-bl-close-409-hint-promises-absent-fields`** — `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '515,536p'` -> 409 emits current_rev + changed_fields at TOP LEVEL (:519-533); `grep -n 'details' internal/cli/errors.go` -> NOTHING; canon struct :153-160, {ok:false,reason} branch :205-215

**`pds-bl-cond-b-nonnumeric-floor-fail-direction`** — `git show origin/main:scripts/pds-pull-proof.sh | sed -n '1300,1312p'` to pin :1304-1310, then the block RE-RUN standalone under `set -euo pipefail` with FULL_MIN_MEM_MB=abc, mem_mb=2048 -> `[: abc: integer expression expected` / cond_b=FAILED / ok=0

**`pds-bl-criteria-fence-http-level-pin`** — `git grep -c criteria origin/main -- api/test/barkpark_web/controllers/mutate_controller_test.exs` -> no matches; `git grep -ln 'gate_task_publish' origin/main -- api/test` -> only api/test/barkpark/content/lifecycle_test.exs

**`pds-bl-disposition-owner-role-registry`** — Full drafts-perspective walk (4300 distinct type:task rows) counting non-empty disposition_owner -> 22 DISTINCT slugs (filed: 16); `git ls-tree -r --name-only origin/main | grep -iE 'disposition.*owner|owner.*registry'` -> nothing

**`pds-bl-export-close-delimited-silent-truncation`** — `git grep -n 'os.Create\|io.Copy\|ContentLength\|Content-Length' origin/main -- internal/cli/export_cmd.go` -> os.Create(partialPath) :180 and io.Copy :395 only; NO completeness signal anywhere

**`pds-bl-github-linkput-auto-publish-erasure`** — `git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '285,315p'` -> github publishers thread source: :github and FALL THROUGH to gate_task_publish; only :sync exempt (:310). `git grep -n 'collapse' origin/main -- api/test/barkpark/plugins/github/link_test.exs` -> :177-209 PINS the Logger.warning (link.ex:198) — CORRECTS the round brief's 'no test pins either half'

**`pds-bl-hetzner-create-image-post-condition`** — `git grep -n 'func runHetznerServerCreateImage' origin/main -- internal/cli/hetzner_cmd.go` -> :1517 (stored pointer 1290-1329 DRIFTED); `sed -n '1540,1568p'` -> DECLARED EXEMPTION comment + result.Image.ID echo at :1553-1561

**`pds-bl-hzresdone-registry-row-vacuous`** — `git grep -n 'hzResDone(' origin/main -- internal/cli | grep -v _test.go | grep -vc 'func hzResDone'` -> 50 (NOT PDS-D367's 51; the extra was the definition at hetzner_net_cmd.go:56)

**`pds-bl-publish-refusal-drops-teaching-text`** — `git show origin/main:api/lib/barkpark/content/errors.ex | sed -n '528,548p'` -> `details: details` at :535 (server DOES ship it); `grep -n 'details' internal/cli/errors.go` -> NOTHING; `grep -n stale_claim_error` -> lifecycle.ex:438 (stored :324-338 DRIFTED)

**`pds-bl-remaining-os-create-sinks`** — `git grep -n 'os.Create(' origin/main -- internal/ | grep -v _test.go` -> cloud_workspace_cmd.go:747 (stored :699 DRIFTED by 48), :211 now a COMMENT, context_render.go:177, export_cmd.go:180, hetzner_instance_transfer_cmd.go:229, hetzner_storage_cmd.go:453 — the three criterion-0 pointers still resolve EXACTLY

**`pds-bl-sync-source-bypasses-publish-door`** — `grep -n 'source, :api) == :sync' api/lib/barkpark/content/lifecycle.ex` -> :310 (stored :277-279 DRIFTED by ~32); ensure_task_publish_transition_legal/5 at :309

**`pds-bl-tagregistry-standing-position-not-in-transcripts`** — `git grep -c 'suite-only\|PDS-D187' origin/main -- scripts/pds-pull-proof.sh` -> NOTHING; the 4 TagRegistry hits in scripts/pds-pull-proof.crown-transcript-w8.txt (:110,:776,:778) are SKIP-count lines, never the standing position

**`pds-bl-task-create-500-no-brief`** — RUNTIME, NOT PROBED. Content NARROWS only: `git show origin/main:api/lib/barkpark/plugins/tasks.ex | sed -n '126,146p'` -> portable_brief_gate/1 :128 returns {:halt, ...}; errors.ex:422-423 maps it to a 409 with the sentence verbatim => the PUBLISH leg is honest, the 500 is on CREATE

**`pds-bl-task-stamp-silent-nonland`** — `git show origin/main:internal/cli/tasks_stamp_cmd.go | sed -n '160,195p'` -> taskboard.FetchCriterion :166, 'stamp sent but NOT confirmed' :167-171, renderStampVerdict :185 -> exitConflict :202

**`pds-w12-crown-climb-preconditions`** — RUNTIME, NOT PROBED. Stageability PROVEN LIVE instead: staged blocked->blocked, reads back disposition=open with lifecycle_status=blocked intact

**`pds-w25-backlog-api-v1-relocation`** — `git ls-tree -r --name-only origin/main | grep -c 'docs/api/error-codes.md'` -> 0 (relocation target absent)

**`pds-w25-backlog-hzresdone-receipt`** — Same count as its pair: 50 measured. THIS row's stored 50 was RIGHT; the surviving owner's 51 was wrong

**`pds-w25-backlog-merge-gate-split`** — `git grep -c 'merge_gate' origin/main -- api/lib/barkpark/tasks/schema.ex` -> NOTHING (criterion 1 unpaid). PARTIAL: the four-writer topology and the 554-row count were NOT re-derived and must not be inherited

**`pds-w25-backlog-studio-criteria-text-edit`** — RUNTIME, NOT PROBED. Pointer fixed: `git ls-tree -r --name-only origin/main | grep -i 'studio/plugins/adapter'` -> api/lib/barkpark_web/live/studio/plugins/adapter.ex (stored 'studio/plugins/adapter.ex' does not resolve)

**`pds-w25-independent-review-stage-widening`** — LEAD-GATED. Outstanding act quoted from its own criterion 3: '[MERGE-GATED] The lead confirms the second review happened before pds-w25-stage-terminal-widening merged'

**`pds-w25-round-bare`** — LEAD-GATED (criterion 7). Stale-premise citations re-derived: transitions.ex:42 @statuses includes blocked; legal?/2 :89-96 from==to -> `from in @statuses`; stage.ex:375 `(to in @stageable or from == to)` with from read from the LOCKED row at :367

**`pds-w25-round-open`** — LEAD-GATED (criterion 7), 7/8 met. Live caveat measured: pds-barkpark-stop-4000-fallback still carries disposition_owner == its own _id

**`pds-w25-round-parked`** — LEAD-GATED (criterion 7), 7/8 met. Census corroboration: live_parked 29, reopen_triggers_structured 29, live_park_no_trigger []

**`pds-w26-close-pulse-readback`** — `git grep -n 'taskboard.FetchCriterion' origin/main -- internal/cli` -> EXACTLY ONE site (tasks_stamp_cmd.go:166); cli.go:608-618 shows stamp is intercepted before runCommand, close/pulse are not

**`pds-w26-close-refusal-taxonomy-remainder`** — `grep -n '"criteria_unmet"\|"invalid_lifecycle"\|"sentinel_worker_id"' internal/cli/errors.go` -> NOTHING; codeExit (:60-96) stops at criterion_text_required/note_required/illegal_transition; the names appear only in the comment at :100-102

**`pds-w26-create-image-image-postcondition`** — Same lines as its pair (hetzner_cmd.go:1517, :1553-1561). SURVIVING OWNER on criteria richness (confirmation-unavailable escape + disagreeing-fake behavioural test + exemption deletion)

**`pds-w26-mcp-stamp-bypasses-readback`** — `git show origin/main:internal/cli/mcp_tasks.go | sed -n '660,680p'` -> execManifestCommand at :670; `git show origin/main:internal/cli/run.go | sed -n '172,186p'` -> execManifestCommand is the HEADLESS primitive ('no rendering'); the read-back lives in runTaskStamp, reached from cli.go:616 BEFORE runCommand — the branch MCP skips

## 3. The five materially-stale rows, rewritten

These five had stored text that was owner-facing FALSE. Templating them forward would have
passed clause 1 while lying. Full new reasons are in section 5.

1. **`pds-bl-cond-b-nonnumeric-floor-fail-direction` — REFUTED, and it is the only `closed`.**
   Re-run, not inherited. The `:1304-1310` block reproduced standalone under `set -euo pipefail`
   with `FULL_MIN_MEM_MB=abc` and `mem_mb=2048` (a healthy reading — the input most likely to
   manufacture a false pass) prints `[: abc: integer expression expected`, lands
   `cond_b=FAILED`, `ok=0`. IT FAILS CLOSED: `set -e` does not fire on a test in condition
   position, and the `elif`'s status-2 routes to the STRICT `else`. The row's entire premise
   — a silent gate bypass — does not exist.
2. **`pds-bl-github-linkput-auto-publish-erasure` — headline FIXED, residue kept.** The GitHub
   automatic publishers thread `source: :github`, not `:sync`, so they fall through to
   `gate_task_publish`; only `:sync` is exempt (`lifecycle.ex:310`). *This slice CORRECTS the
   round brief*: the brief says "no test pins either half", but `link_test.exs:177-209` DOES
   pin the `Logger.warning` and the surviving draft twin. The true residue is narrower — the
   warning names the refusal reason but never WHAT WOULD HAVE BEEN OVERWRITTEN, and no test
   drives the criteria-fence route (only `unknown_tag`).
3. **`pds-bl-task-stamp-silent-nonland` — priority-1 framing stale.** `tasks_stamp_cmd.go:166`
   re-reads via `taskboard.FetchCriterion`; `renderStampVerdict` (:185) returns `exitConflict`
   (:202) on disagreement. Criterion 1 is satisfied FOR THE CLI PATH; 0, 2 and 3 stay open;
   the MCP hole is `pds-w26-mcp-stamp-bypasses-readback`, not this row.
4. **`pds-bl-close-409-hint-promises-absent-fields` — MIS-STATED.** The server 409 carries
   `current_rev` + `changed_fields` at the TOP LEVEL (`tasks_controller.ex:519-533`). The
   defect is CLIENT-SIDE. **Criterion 0 as written would make the SERVER worse.**
5. **`pds-bl-publish-refusal-drops-teaching-text` — MIS-LOCATED.** `errors.ex:535` already
   emits `details: details`; the same `canon` struct drops it.

**Rows 4 and 5 are ONE CLI FIX.** `internal/cli/errors.go`'s `classifyError` decodes
`code/message/request_id/hint` only (`:153-160`) and its `{"ok":false,"reason":…}` branch
decodes `Reason` + `bodyMessage` only (`:205-215`) — `grep -n details internal/cli/errors.go`
returns nothing. **Surviving owner: `pds-bl-close-409-hint-promises-absent-fields`.** Row 5 is
retained solely for its criterion 2 (the propagation must also reach the PDS-D362
criteria-fence refusal), which row 4 does not cover.

## 4. The two duplicate pairs

| pair | surviving owner | why | pointer row |
|---|---|---|---|
| create-image | `pds-w26-create-image-image-postcondition` | its criteria alone specify the confirmation-unavailable escape matching `hzFlagVerbDone` and a behavioural test with a fake whose `GET /images/<id>` disagrees | `pds-bl-hetzner-create-image-post-condition` |
| hzResDone | `pds-bl-hzresdone-registry-row-vacuous` | it alone carries the mutation proof of the vacuous registry row plus a derived population check and the `backup restore` exemption | `pds-w25-backlog-hzresdone-receipt` |

**The hzResDone population is 50, not 51.**

```
$ git grep -n 'hzResDone(' origin/main -- internal/cli | grep -v _test.go | grep -vc 'func hzResDone'
50
$ git grep -n 'hzResDone(' origin/main -- internal/cli | wc -l
52
$ git grep -n 'func hzResDone' origin/main -- internal/cli
origin/main:internal/cli/hetzner_net_cmd.go:56:func hzResDone(out *writer, action, kind string, ...
```

Charter PDS-D367 and the surviving row both recorded **51** — they counted the DEFINITION line
at `hetzner_net_cmd.go:56`. The surviving row's own class breakdown already summed to 50
(13 destroy + 12 create + 23 request-echo + 1 measured-but-uncompared + 1 no-cheap-post-read),
so its 51 contradicted its own arithmetic. `pds-w25-backlog-hzresdone-receipt` had it right and
still loses the pair on criteria richness; the correct 50 is transplanted into the survivor's
reason so nothing true is lost by the merge.

## 5. The 30 stored reasons, verbatim

Transcribed from the SERVER read-back, not from the send buffer.

### `pds-bl-armed-draft-twin-tagregistry` — open (lifecycle open, md5 `1ef96d20b39f3390d6e4b612bdbc6d56`)

> OPEN - re-derived INDEPENDENTLY 2026-07-31 (wave 27), and every stored figure holds. A paginated drafts-perspective walk over type:task (4300 distinct rows, 5 pages of 1000) returns EXACTLY ONE drafts.pds* row: drafts.pds-bl-tagregistry-guard-no-rung. Its published twin re-reads unchanged at rev 43e6314f314d830fa39f10defbc93ccb with criteria [met,met,unmet,met] and evidence 609/373/131 B = 1113 B held hostage. Nothing in the filing is stale. All four criteria remain unpaid: no durable JSON capture of the pair exists under tooling/grip/ledger/, the claim-divergent refusal has not been reproduced on a scratch row shaped like the target, the twin is neither discarded nor deliberately kept, and the rail-vs-census disagreement (which lens is authoritative, and why 205 is the wrong pds-* count) is unrecorded. Wave 27 ADJUDICATES this row; it does not pay it.

### `pds-bl-census-count-true-total-assertion` — open (lifecycle open, md5 `2f17d84d2d15a4a8ae8715bb1773a648`)

> OPEN - still true verbatim, re-derived 2026-07-31 against origin/main 6e53d278. `grep -c 'count=true' scripts/pds-ledger-census.sh` = 0: the corpus walk still never asks the server for a total, so `collected == total` cannot be asserted and a SHORT page is indistinguishable from a TRUNCATED one. The wave-27 run of this very census demonstrates the shape it cannot defend: pages [1000,1000,1000,980], corpus_size 3980, terminated on the short page alone. All three criteria unpaid - fetch_page sends no count=true, no selftest fixture proves a mismatch fires, and the script header still does not state whether the published-only perspective is a deliberate scope or a known blindness (it is a real blindness: the drafts walk above finds a pds row the census cannot see).

### `pds-bl-census-read-path-500-under-load` — open (lifecycle open, md5 `93baf153c1ce588348f9fb5cf2311273`)

> OPEN, and PROBED LIVE rather than ruled from a desk - the probe DID NOT REPRODUCE. Between 2026-07-31T02:10:17.266002Z and 02:10:39.194434Z, with sibling wave-27 builders writing to the same board concurrently, a full paginated GET /v1/data/query/production/task?limit=1000 sweep ran 4 pages [1000,1000,1000,980] = 3980 docs in 21.93s with ZERO 500s (census exit 0, empty stderr). A NON-REPRODUCTION CLOSES NOTHING: criterion 0 asks for the 500 reproduced with its server-side cause named FROM LOGS, and criteria 1-2 are structural and untouched - no walk in the tree distinguishes a FAILED page from a SHORT page, and this very run terminated on `len(docs) < 1000`, exactly the terminator the filing indicts. The defect stays armed. SETTLING PROBE: drive the same sweep under deliberate concurrent mutate load and read guerrilla's server log for the failing request_id.

### `pds-bl-close-409-hint-promises-absent-fields` — open (lifecycle open, md5 `6c5dead6c5f6a8469bd8f033aba43dc5`)

> OPEN, but the stored defect is MIS-STATED and is RESTATED here. Re-derived 2026-07-31: `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '515,536p'` shows the 409 body DOES carry current_rev AND changed_fields - at the TOP LEVEL beside ok:false and reason:"doc_changed_since_claim" (:519-533), not under `details`. The server is already honest and errors.go:430's hint ('the 409 body names current_rev + changed_fields') is TRUE OF THE WIRE. The defect is CLIENT-SIDE: classifyError's canon struct (internal/cli/errors.go:153-160) declares only Code/Message/RequestID/Hint, and its {"ok":false,"reason":...} branch (:205-215) reads Reason plus bodyMessage and nothing else - `grep -n details internal/cli/errors.go` returns NOTHING. The CLI discards both fields and re-renders a canonical envelope without them, which is what the wave-26 verifier saw and mis-attributed to the server. CRITERION 0 AS WRITTEN WOULD MAKE THE SERVER WORSE: moving current_rev under details.* would relocate fields the CLI still would not read. ONE CLI FIX WITH pds-bl-publish-refusal-drops-teaching-text - the same canon struct drops that row's details.* teaching sentence. SURVIVING OWNER of the shared decoder work: THIS ROW.

### `pds-bl-cond-b-nonnumeric-floor-fail-direction` — closed (lifecycle open, md5 `906b0e50dc0ef33ca6a1d6350cb4109a`)

> CLOSED - REFUTED BY EXPERIMENT, re-run in wave 27 rather than inherited. Source re-pinned first: `git show origin/main:scripts/pds-pull-proof.sh | sed -n '1300,1312p'` shows :1304-1310 as `if [ -z "$mem_mb" ] ... elif [ "$mem_mb" -ge "$FULL_MIN_MEM_MB" ] ... else cond_b=FAILED...; ok=0`, shebang #!/usr/bin/env bash (:1). That exact block was reproduced standalone under `set -euo pipefail` with FULL_MIN_MEM_MB=abc and mem_mb=2048 - a HEALTHY numeric reading, i.e. the input most likely to manufacture a false PASS. Output verbatim: `[: abc: integer expression expected` / `cond_b=FAILED (2048 MB available, floor abc MB) - taking it now risks OOMing the LIVE content API` / `ok=0`, script exit 0. IT FAILS CLOSED: set -e does not fire on a test in CONDITION position, and the elif's status-2 routes to the STRICT else, not past the gate. Criterion 0 is settled by experiment; criterion 1 is moot, being conditioned on 'if it fails OPEN', which it does not. There is no silent gate bypass, and leaving this open would be the wave-25 defect pointed the other way.

### `pds-bl-criteria-fence-http-level-pin` — open (lifecycle open, md5 `039305d2a53245d66cec50e1d2886dfd`)

> OPEN - still true verbatim, re-derived 2026-07-31 against origin/main. `git grep -c criteria origin/main -- api/test/barkpark_web/controllers/mutate_controller_test.exs` returns NOTHING (zero matches in a file that exists), while `git grep -ln 'gate_task_publish' origin/main -- api/test` returns exactly one file: api/test/barkpark/content/lifecycle_test.exs. The PDS-D362 criteria fence is therefore proven at the Content layer ALONE - nothing pins that a criteria-clearing publish over POST /v1/data/mutate returns the same 422 validation_failed, and nothing reads the task back OVER HTTP to assert the met:true flag and its evidence survived. Both criteria unpaid. Relation, so the two are not confused: pds-bl-sync-source-bypasses-publish-door is a path the fence does NOT cover; this row is the fence's one covered path not being pinned where callers actually reach it.

### `pds-bl-disposition-owner-role-registry` — open (lifecycle open, md5 `6370c03c45ad3dce830bde0bcc5698ba`)

> OPEN, and MEASURED WORSE THAN FILED. Re-derived 2026-07-31 by walking every type:task row (4300 distinct, drafts perspective, 5 pages) and counting non-empty disposition_owner: 22 DISTINCT SLUGS live today, not the 16 the row records. Tally: pds-harness-maintainer 35, lead-pds 33, 'truth-grip-epic lead (wave-10 steward)' 26, lead-truthgrip 24, pds-charter-steward 24, pds-export-path-owner 10, pds-schema-owner 7, wave-24 7, pds-import-path-owner 6, pds-repo-hygiene-owner 5, and 12 more at <=4 each. THREE violation classes are visible at once: (a) 'truth-grip-epic lead (wave-10 steward)' carries SPACES and parentheses, breaking the ratified lowercase-kebab shape on 26 rows; (b) the wave-N shape criterion 2 demands a ruling on is live on 8 rows (wave-24 x7, wave-25 x1); (c) THREE rows name a task id as owner and one of them, pds-barkpark-stop-4000-fallback, is owned BY ITSELF (disposition OPEN, lifecycle done) - self-ownership is not extinct, it survives among the terminal rows pds-w27-round-terminal-15 is paying this wave. No registry exists anywhere in the tree (`git ls-tree -r --name-only origin/main | grep -iE 'disposition.*owner|owner.*registry'` = nothing), so all three criteria are unpaid.

### `pds-bl-export-close-delimited-silent-truncation` — open (lifecycle open, md5 `6fe5cd01ca79eea80ad7bc67dbc061ed`)

> OPEN - still true, re-derived 2026-07-31 against origin/main, and NARROWED. `git grep -n 'ContentLength\|Content-Length\|completeness' -- internal/cli/export_cmd.go` returns NOTHING: the file carries no completeness signal of any kind, so `err == nil` out of io.Copy (:395) on a close-delimited body is still read as a COMPLETE stream and the sidecar attests the SHORT file. What HAS landed is the atomicity half - the sink at :180 is `os.Create(partialPath)`, not the destination, from pds-w26-export-atomic-out (:29 and :286 keep the old truncating shape only as explanatory comments). Do NOT re-brief this row as the truncate-the-destination bug; it is now specifically about COMPLETENESS. All three criteria unpaid: no explicit completeness signal is required, no committed test covers the three framings (close-delimited truncated, short content-length, unterminated chunked), and --verify still PASSES on a silently truncated export.

### `pds-bl-github-linkput-auto-publish-erasure` — open (lifecycle open, md5 `901b2b8a489292ef976f8aed8d25b23b`)

> OPEN ON A NARROWED RESIDUE - the HEADLINE DEFECT IS FIXED and the source says so verbatim. `git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '285,315p'`: the GitHub automatic publishers thread `source: :github`, NOT `:sync` (link.ex:193 via mirror_job.ex:560 / inbound_events.ex:172, and adopt.ex:178), so they FALL THROUGH to gate_task_publish at :309-327 and the PDS-D362 criteria fence applies to them; only `:sync` is exempt (:310). An automatic Link.put collapse therefore CANNOT erase a met:true flag - criterion 0's premise is answered. CRITERION 1 IS HALF PAID, and this corrects the round brief's 'no test pins either half': link.ex:192-204's collapse_draft_twin now Logger.warning's 'github link: draft-twin collapse publish for <pid> rejected: <inspect reason>' and returns %{published: false, error: ...} instead of swallowing it, AND api/test/barkpark/plugins/github/link_test.exs:177-209 PINS that log plus the surviving draft twin. THE HONEST RESIDUE, which is what keeps this row open: the warning names only the REFUSAL REASON, never WHAT WOULD HAVE BEEN OVERWRITTEN (the task id and the fields at risk), which is the audit-trail half criterion 1 asks for; and the shipped test drives the unknown_tag rejection route ONLY - no test drives the CRITERIA-FENCE route, so criterion 2's 'both arms covered, and which can reach a pds-* row' is unpaid. Do NOT close over that residue.

### `pds-bl-hetzner-create-image-post-condition` — open (lifecycle open, md5 `5314c5a56cc14374896b11d140a6e1f2`)

> OPEN - the defect is still true, but THIS ROW IS A DUPLICATE and is NOT the surviving owner. Re-derived 2026-07-31: runHetznerServerCreateImage is at internal/cli/hetzner_cmd.go:1517 - the stored pointer '1290-1329' has DRIFTED by ~227 lines and is corrected here - and at :1553-1561 the verb still puts result.Image.ID straight off the CreateImage ACTION response into extra, under a DECLARED EXEMPTION comment naming hzServerPostConditionExemptions["create-image"]. No GET /images/<id> exists in the verb. EXACT DUPLICATE OF pds-w26-create-image-image-postcondition: same verb, same lines, same fix, three criteria that are the same three obligations reworded. SURVIVING OWNER: pds-w26-create-image-image-postcondition, because its criteria ALSO specify the confirmation-unavailable escape matching hzFlagVerbDone and a behavioural test with a fake whose GET /images/<id> disagrees - obligations this row's criteria do not carry. Retained as a POINTER only: adjudicating both halves as independent findings manufactures clause-1 md5 variation without adding information, so this reason states the duplication instead of restating the defect.

### `pds-bl-hzresdone-registry-row-vacuous` — open (lifecycle open, md5 `e35b35e9cc19c71ef2333a152cd40674`)

> OPEN, SURVIVING OWNER of the hzResDone pair, and ITS POPULATION FIGURE IS CORRECTED HERE BY MEASUREMENT. `git grep -n 'hzResDone(' origin/main -- internal/cli | grep -v _test.go | grep -vc 'func hzResDone'` = 50, NOT the 51 this row and charter PDS-D367 both record. The extra one was the DEFINITION line internal/cli/hetzner_net_cmd.go:56 (52 raw matches total; minus the definition, minus one test-file match = 50). The row's own class breakdown already summed to 50 - 13 destroy + 12 create + 23 request-echo + 1 measured-but-uncompared + 1 no-cheap-post-read - so the stored 51 contradicted its own arithmetic. OVERLAPS pds-w25-backlog-hzresdone-receipt, which recorded 50 and was RIGHT; that row is the duplicate and THIS row survives anyway, because it alone carries the mutation proof (deleting the payload spread AND the sorted table-view lines AND the orphaned sort import still left success_claim_registry_test.go:232-239 PASSING - only the Go compiler noticed) plus criteria 2-3, a derived population check in the shape of hzActionVerbsFromSource and a declared exemption for `backup restore`. All four criteria unpaid.

### `pds-bl-publish-refusal-drops-teaching-text` — open (lifecycle open, md5 `feaf3d731bc5bc3e4c92c3a8274546ef`)

> OPEN and TRUE, but MIS-LOCATED - the loss is in the CLI, not in the server, and two stored pointers have drifted. Re-derived 2026-07-31: `git show origin/main:api/lib/barkpark/content/errors.ex | sed -n '528,548p'` shows the validation_failed clause already emitting `details: details` (:535) carrying the per-field composed sentence, so THE SERVER ALREADY SHIPS THE TEACHING TEXT. `grep -n 'details' internal/cli/errors.go` returns NOTHING: classifyError's canon struct (:153-160) declares only Code/Message/RequestID/Hint under `error`, so the details map decodes into nothing and the operator gets errors.go's generic code-keyed hint instead. POINTER FIX: stale_claim_error/1 is now lifecycle.ex:438, not the stored :324-338. THIS ROW AND pds-bl-close-409-hint-promises-absent-fields ARE ONE CLI FIX - the same canon struct drops this row's details.<field> sentence and that row's top-level current_rev/changed_fields. SURVIVING OWNER of the shared decoder work: pds-bl-close-409-hint-promises-absent-fields. This row is retained for criterion 2 alone, which that row does not cover: the same propagation must reach PDS-D362's criteria-fence refusal, not only the stale-claim one.

### `pds-bl-remaining-os-create-sinks` — open (lifecycle open, md5 `85f45084eefb7b7e8bed0bdcd670e3fd`)

> OPEN - still true, with ONE stored pointer corrected by re-derivation. `git grep -n 'os.Create(' origin/main -- internal/ | grep -v _test.go` returns exactly six live sinks plus two comments: cloud_workspace_cmd.go:747 (the blob leg - the row cites :699, DRIFTED by 48 lines; it is the ALREADY-HONEST one, do not re-brief it), context_render.go:177, export_cmd.go:180, hetzner_instance_transfer_cmd.go:229, hetzner_storage_cmd.go:453, and cloud_workspace_cmd.go:211 which is now a COMMENT recording the fixed sink rather than a sink. The three pointers criterion 0 names (:453, :229, context_render.go:177) all still resolve EXACTLY - only the blob-leg reference in the description had drifted, so the criteria themselves need no repair. All four criteria unpaid: no temp+rename on the three sinks, no streaming atomicWriteStream sibling to onramp_write.go's atomicWriteFile, no declared-size comparison on the S3 get, and the transfer verb's failure-path os.Remove can still delete a file it did not create.

### `pds-bl-sync-source-bypasses-publish-door` — open (lifecycle open, md5 `764e15f1fd2b1a07b13abc2227e51ddf`)

> OPEN - still true, and its stored line pointer is CORRECTED here. The row cites api/lib/barkpark/content/lifecycle.ex:277-279 for the exemption; re-derived 2026-07-31, ensure_task_publish_transition_legal/5 is at :309 and the `if Keyword.get(opts, :source, :api) == :sync do :ok` short-circuit is at :310 - the pointer has DRIFTED by ~32 lines. The defect is unchanged: the :sync branch returns :ok BEFORE the transition check and BEFORE gate_task_publish, so a sync-sourced publish bypasses the lifecycle gate, the stale-claim gate and the PDS-D362 criteria fence in one step. Wave 26's own in-tree comment at :294-297 now names this row as the NOT-COVERED case, which makes the hole DOCUMENTED but not smaller - and documentation is not a fence. All three criteria unpaid: no removal of the exemption, no sync-side reconciliation recorded as a charter decision, no api/test proving a sync publish cannot blank a met:true flag or a non-empty evidence string, and neither Pusher nor Applier is covered.

### `pds-bl-tagregistry-standing-position-not-in-transcripts` — open (lifecycle open, md5 `80700af8c4ecb2e5be3c50a9b4ff6926`)

> OPEN - still true, re-derived 2026-07-31 against origin/main. The ruling itself is plain: scripts/pds-tagregistry-rung-ruling.md states 'NO RUNG. Suite-only coverage is the standing position for the TagRegistry pull-provenance guard' under PDS-D187. But that position appears NOWHERE a climb reader would meet it: `git grep -c 'suite-only\|PDS-D187' origin/main -- scripts/pds-pull-proof.sh` returns NOTHING, and the only four TagRegistry mentions in scripts/pds-pull-proof.crown-transcript-w8.txt (:110, :776, :778) are about the core `tag` row being SKIPPED as outside the sentinel scope and about that count being reported-NOT-asserted - never about the guard being suite-only BY DECISION. So a green rung 6 still reads as covering the guard, which is exactly the misread the row was filed against. Both criteria unpaid: neither the transcript nor a template/honesty banner outside the frozen harness carries the statement, and PDS-D187 has not been amended to drop the clause instead.

### `pds-bl-task-create-500-no-brief` — open (lifecycle open, md5 `ac14e92e1d4a79ab7367cc4be79d5be6`)

> OPEN and UNVERIFIED BY CONTENT SINCE FILING (2026-07-30) - no live probe was run in wave 27, and NO invented content-shaped reason is offered in its place. What content CAN settle NARROWS the row: the brief-less PUBLISH leg is HONEST, not a 500. `git show origin/main:api/lib/barkpark/plugins/tasks.ex | sed -n '126,146p'` shows portable_brief_gate/1 (:128) returning {:halt, 'task brief is required before publish - set content.brief to PortableDoc {version: 1, blocks: [...]} so bp task tui can render it'}, and errors.ex:422-423 maps {:error, {:halted, reason}} to a 409 carrying that plugin sentence VERBATIM as the message. So the observed HTTP 500 internal_error (request_id GMciBMqA0IA09lsAAM9R) is on the CREATE leg SPECIFICALLY, not the publish gate. THE EXACT PROBE THAT WOULD SETTLE IT: POST /v1/data/mutate against guerrilla with a create of a type:task document carrying title+kind but NO content.brief and no publish, then the BYTE-IDENTICAL payload WITH a brief, quoting both statuses and both request_ids. Criterion 1's CLI half is separately checkable and is NOT satisfied: internal/cli/errors.go has no branch that surfaces a 500 body's request_id, so the collapse to 'unknown error' still stands.

### `pds-bl-task-stamp-silent-nonland` — open (lifecycle open, md5 `d8f3187eceff085294097c75cdebc0b2`)

> OPEN ON A NARROWER RESIDUE - the priority-1 framing is STALE and is narrowed here. Re-derived 2026-07-31: `git show origin/main:internal/cli/tasks_stamp_cmd.go | sed -n '160,195p'` shows the stamp now RE-READS after the write - taskboard.FetchCriterion(client, req.docID, req.index) at :166, a failed read-back reported as 'stamp sent but NOT confirmed' with exitGeneric at :167-171, and renderStampVerdict (:185) returning exitConflict (:202) whenever the stored row disagrees with the request. CRITERION 1 IS SATISFIED FOR THE CLI PATH: the silent drop this row observed would today exit NON-ZERO with a printed contradiction. It is NOT satisfied globally - an MCP-issued stamp skips that wrapper entirely (cli.go:616 intercepts only the CLI dispatch), which is its own row, pds-w26-mcp-stamp-bypasses-readback, not this one. CRITERIA 0, 2 AND 3 REMAIN FULLY OPEN: the size boundary has never been bisected (no byte figure exists for the smallest non-persisting payload), no regression stamps an over-boundary evidence string, and the read-back-and-count doctrine has been neither vindicated nor amended in the charter. In substance this is no longer a priority-1 row.

### `pds-w12-crown-climb-preconditions` — open (lifecycle blocked, md5 `318dc2abb1ddfc6c4f4ebf4de02d93d9`)

> OPEN, ADJUDICATED IN PLACE AT lifecycle=blocked - and that in-place adjudication is itself the finding. blocked -> blocked is a LEGAL stage: transitions.ex:42 lists blocked in @statuses, legal?/2 (:89-96) returns `from in @statuses` on the from == to branch, and stage.ex:375 admits `(to in @stageable or from == to)` with the from-state read from the LOCKED row (:367), never from caller input. pds-w25-round-bare's criterion 4, which enshrines this row as 'blocked, NON-STAGEABLE', is therefore STALE. THE DEFECT ITSELF IS RUNTIME AND UNVERIFIED SINCE FILING: no wave has run the climb, so nothing at a desk can rule on whether the three preconditions hold. Criterion 0 waits on pds-w11-floor-rederivation producing a deployed-spill measurement; criterion 1 needs a clean origin/main worktree, deployed-sha ancestry, host-local spent/ceiling arithmetic, a fresh-bundle decision and a frozen-harness hash captured TOGETHER; criterion 2 needs ONE unsplit run under a single run id. THE EXACT PROBE THAT WOULD SETTLE IT: run scripts/pds-pull-proof.sh end to end against the deployed spill engine and commit the transcript. Adjudicated open, not closed: the work is real and unstarted. lifecycle stays blocked - the disposition is not a lifecycle move.

### `pds-w25-backlog-api-v1-relocation` — open (lifecycle open, md5 `eb8a8edc8a9655774752c5353115af4d`)

> OPEN - still true, re-derived 2026-07-31. `git ls-tree -r --name-only origin/main | grep -c 'docs/api/error-codes.md'` = 0: THE RELOCATION TARGET DOES NOT EXIST. So docs/api-v1.md line 171 has not moved, check-doc-budgets.sh has no reduced figure to report, and errors_doc_coverage_test.exs has not been amended to read section 9 UNION a second doc. None of the four anti-laundering mutation proofs (cap overflow reds, stripped G1 header reds, colliding canonical-for reds, dangling pointer reds) can have been run against a file that is absent. ONE SCOPE HAZARD for whoever takes it: criterion 3 bundles pds-bl-dedup-unavailable-error-code into the same PR, and that row is PARKED - so this row's scope is coupled to a park and the coupling must be re-ruled before work starts, not discovered mid-PR. Criteria 0-4 unpaid; criterion 5 is [MERGE-GATED] and belongs to the lead.

### `pds-w25-backlog-hzresdone-receipt` — open (lifecycle open, md5 `f01c0e6f61c728d9d2d8d66b292719b8`)

> OPEN - the defect is real, but this row OVERLAPS pds-bl-hzresdone-registry-row-vacuous and is NOT the surviving owner. ITS NUMBER WAS THE RIGHT ONE: re-measured 2026-07-31, `git grep -n 'hzResDone(' origin/main -- internal/cli | grep -v _test.go | grep -vc 'func hzResDone'` = 50, matching THIS row's 50 and refuting the 51 carried by pds-bl-hzresdone-registry-row-vacuous and by charter PDS-D367 (both counted the definition at hetzner_net_cmd.go:56). SURVIVING OWNER: pds-bl-hzresdone-registry-row-vacuous - chosen DESPITE its bad number, because it alone carries the mutation proof of the vacuous registry row and two obligations this row lacks (a derived population check in the shape of hzActionVerbsFromSource, and a declared exemption for `backup restore`). The correct 50 has been transplanted into that row's reason, so nothing true is lost by the merge. Retained here as a POINTER; its criteria are not separately actionable and its 13 nil-extra subset should be read as the same 13-site destroy class the surviving row names.

### `pds-w25-backlog-merge-gate-split` — open (lifecycle open, md5 `4f38411a2e6ec599beddd80bbb873d3a`)

> OPEN, and PARTIALLY RE-DERIVED - said plainly so this adjudication is not read as a full content check. WHAT WAS RE-DERIVED 2026-07-31: `git grep -c 'merge_gate' origin/main -- api/lib/barkpark/tasks/schema.ex` returns NOTHING, so criterion 1 is unpaid - merge_gate is still not a declared criterion subfield and no written decision replaces the declaration. WHAT WAS NOT RE-DERIVED, and must not be inherited from here or from the filing: the FOUR-WRITER TOPOLOGY claim (which of the write sites could carry the normaliser, and which is the fourth) was taken on the filing's word and NOT traced through close.ex / stage.ex / the mutate path in this slice; and criterion 2's '554 text-only gated rows' was NOT re-counted from the published corpus. Both figures are load-bearing for scoping the work, so whoever takes this row re-derives them FIRST. Criteria 0-4 unpaid; criterion 5 is [MERGE-GATED].

### `pds-w25-backlog-studio-criteria-text-edit` — open (lifecycle open, md5 `72d8f44917602e7609490f5b94982164`)

> OPEN, RUNTIME, and UNVERIFIED SINCE FILING - plus one stored pointer corrected. THE POINTER: the row cites 'studio/plugins/adapter.ex', which does not resolve; the real path is api/lib/barkpark_web/live/studio/plugins/adapter.ex, with api/test/barkpark_web/live/studio/plugins/adapter_test.exs beside it - confirmed 2026-07-31 by `git ls-tree -r --name-only origin/main | grep -i 'studio/plugins/adapter'`. THE DEFECT CANNOT BE SETTLED BY CONTENT: whether a Classic-form criterion-text edit reports Saved and persists nothing is a LiveView RUNTIME behaviour, and no probe was run in wave 27. THE EXACT PROBE THAT WOULD SETTLE IT: mount /studio authenticated, edit one criterion's text through the Classic form, save, then re-read the PUBLISHED document over GET /v1/data/doc/production/task/<id> and diff acceptance_criteria - and in the SAME pass save a criterion carrying merge_gate:true and assert the unknown key survives byte-identical (criterion 2). No content-shaped reason is invented here in place of that probe; the row is thin on purpose.

### `pds-w25-independent-review-stage-widening` — open (lifecycle open, md5 `33b27a2381670b35c65ece2f3f8989c0`)

> OPEN - LEAD-GATED, adjudicated open rather than closed because the outstanding act is not a builder's to perform. THE SPECIFIC OUTSTANDING ACT: criterion 3, '[MERGE-GATED] The lead confirms the second review happened before pds-w25-stage-terminal-widening merged (LEAD closes this criterion)'. Criteria 0-2 are also unpaid and CANNOT be paid by this wave's builders by construction: each requires a reviewer DISTINCT from the slice's builder and from the wave reviewer to independently re-derive the from == to reachability judgment across controller and CLI, confirm do_stage's write set excludes content.claim (so in_progress->in_progress and blocked->blocked mint or alter no claim or lease), and confirm the three stage_test.exs refusal fixtures still constrain what they were written to constrain. Clause 4(a) requires a DISPOSITION - neither a lifecycle move nor a met:true flip - so open plus this reason satisfies it honestly and overstates nothing.

### `pds-w25-round-bare` — open (lifecycle open, md5 `cdb3d110b52158b7978ce601e9ab68e7`)

> OPEN - LEAD-GATED. THE SPECIFIC OUTSTANDING ACT: criterion 7, '[MERGE-GATED] The lead re-derives this shard from the pinned manifest and independently confirms at least 3 of the 8 free closes by content'. Criteria 0 and 6 are also unpaid and are being paid FORWARD, not here: the bare class has since re-formed at 30 rows and pds-w27-round-bare-30 is the descendant slice adjudicating them against a fresh manifest pinned at census instant 2026-07-31T02:10:17.266002Z, while /tmp/w25-count.py died with its host. FOR THE RECORD, ITS CRITERION 4 IS NOW STALE: it enshrines pds-w12-crown-climb-preconditions as a 'blocked, NON-STAGEABLE row'. Re-derived 2026-07-31, blocked -> blocked IS a legal adjudication door - transitions.ex:42 lists blocked in @statuses, legal?/2 (:89-96) returns `from in @statuses` on the from == to branch, and stage.ex:375 admits `(to in @stageable or from == to)` with the from-state read from the LOCKED row (:367), never from caller input. pds-w12 IS stageable in place, and wave 27 adjudicated it in place at lifecycle=blocked to prove it.

### `pds-w25-round-open` — open (lifecycle open, md5 `e2414ee4a859d1577fa8bef559742163`)

> OPEN - LEAD-GATED, and the merge-gated criterion is the ONLY unpaid one. THE SPECIFIC OUTSTANDING ACT: criterion 7, '[MERGE-GATED] The lead re-derives this shard from the pinned manifest and confirms the 103 rows plus every free close by content (LEAD closes this criterion; this slice has no PR)'. Criteria 0-6 all carry met:true with stamped evidence, so the row stands at 7/8 with no builder work left in it; adjudicating open with this reason is the honest act and is sufficient for clause 4(a), which requires a disposition and neither a lifecycle move nor a met flip. ONE LIVE CAVEAT for whoever re-derives it, measured 2026-07-31: criterion 1's 'zero rows have disposition_owner == their own _id' held for the open-normalise CLASS, but self-ownership is NOT extinct board-wide - pds-barkpark-stop-4000-fallback still carries disposition_owner == its own _id today (disposition OPEN, lifecycle done), among the 8 terminal rows pds-w27-round-terminal-15 is paying this wave.

### `pds-w25-round-parked` — open (lifecycle open, md5 `6f8ed3f0ee4089451b39a42adde3c586`)

> OPEN - LEAD-GATED, and the merge-gated criterion is the ONLY unpaid one. THE SPECIFIC OUTSTANDING ACT: criterion 7, '[MERGE-GATED] The lead re-derives this shard from the pinned manifest and confirms the 27 rows and the 8 unchanged hashes (LEAD closes this criterion; this slice has no PR)'. Criteria 0-6 carry met:true with evidence; the row stands at 7/8 with no builder work left. CORROBORATION THE LEAD CAN USE, from this wave's census at 2026-07-31T02:10:17.266002Z: live_parked = 29, reopen_triggers_structured = 29, and live_park_no_trigger = [] - EVERY live park carries a structured trigger, so clause 4(c) holds and criterion 3's 'all 27 live parked rows' has SURVIVED the two parks added since rather than decaying, which is the PDS-D353 decay this row was written against. Adjudicated open, not closed: the disposition is what clause 4(a) requires, and the lead's re-derivation is what closes the row.

### `pds-w26-close-pulse-readback` — open (lifecycle open, md5 `26ab0bc245be0c08bc2a513bdf2cab0b`)

> OPEN - still true verbatim, re-derived 2026-07-31 against origin/main. `git grep -n 'taskboard.FetchCriterion' origin/main -- internal/cli` returns EXACTLY ONE call site: tasks_stamp_cmd.go:166. There is no second read for close and none for pulse, so both still report success ON AN EXIT CODE ALONE - the precise thing this epic's law has forbidden since wave 22. cli.go:608-618 shows the shape of the fix that DOES exist and the shape these two lack: `bp task stamp` is intercepted before runCommand and wrapped by runTaskStamp, which owns the read-back; close and pulse have no such interception and fall straight through to the manifest dispatch. Criteria 0-2 unpaid - no close read-back rendering the receipt from the STORED lifecycle_status + criteria, no pulse confirmation that the stored now-line is the one it wrote, and no ledger rows for either in success_claim_registry_test.go. Criterion 3 is [MERGE-GATED].

### `pds-w26-close-refusal-taxonomy-remainder` — open (lifecycle open, md5 `a6f86361a8234efa543d806afe249ee9`)

> OPEN - still true verbatim, re-derived 2026-07-31 against origin/main. The comment at internal/cli/errors.go:100-102 NAMES criteria_unmet:<indices>, invalid_lifecycle:<s> and sentinel_worker_id:<w> as compound reasons the tasks controller mints, and reasonKey/lookupExit (:107-130) would route them by family name IF the family were in the table - but `grep -n '"criteria_unmet"\|"invalid_lifecycle"\|"sentinel_worker_id"' internal/cli/errors.go` returns NOTHING. None of the three is in codeExit (:60-96), which stops at criteria_mismatch, criteria_index_out_of_range, criterion_text_required, note_required and illegal_transition. So all three still fall to the unknown-reason bucket at exit 2 - THE SAME CODE AS A MALFORMED COMMAND LINE - while their PDS-D371 siblings were split 5/6 by retryability. Criteria 0-3 unpaid (no table entries, no measurement through the real dispatch against a fake server, no docs/cli/error-exit-table.md rows, no inverted pinning test); criterion 4 is [MERGE-GATED].

### `pds-w26-create-image-image-postcondition` — open (lifecycle open, md5 `456aab3159370fbadaebede9a08c231d`)

> OPEN and SURVIVING OWNER of the create-image pair. Re-derived 2026-07-31: runHetznerServerCreateImage (internal/cli/hetzner_cmd.go:1517) still ends at :1553-1561 with a DECLARED EXEMPTION comment - 'see hzServerPostConditionExemptions["create-image"] ... its honest post-condition is a GET /images/<id>, a different resource, and it is filed rather than faked here' - and puts result.Image.ID, taken from the CreateImage ACTION response, into extra before hzDone. No image re-read exists anywhere in the verb, so a snapshot that never materialised still prints the same tick. DUPLICATE: pds-bl-hetzner-create-image-post-condition is the same defect at the same lines with the same fix; it is retained as a POINTER and THIS row survives, because its criteria alone specify the confirmation-unavailable escape matching hzFlagVerbDone and a behavioural test with a fake whose GET /images/<id> DISAGREES. All three criteria unpaid, including the exemption deletion that TestHetznerActionVerbsAllDeclareAPostCondition will demand in the same change.

### `pds-w26-mcp-stamp-bypasses-readback` — open (lifecycle open, md5 `80f8ad608e00d54d63c17fb8191b553f`)

> OPEN - still true, and re-derived CAREFULLY because the MCP path LOOKS like it inherits the CLI fix. mcp_tasks.go:670 dispatches the stamp through execManifestCommand(g, ctx, m, stampCmd, tail), and run.go:172-186 documents execManifestCommand as the HEADLESS primitive: it builds the request and sends it with 'no dry-run, no prod write-guard, no --all pagination loop, and no rendering'. The read-back does NOT live in the manifest command - it lives in the CLI-ONLY wrapper runTaskStamp, reached from cli.go:616 (`if noun == "task" && verb == "stamp"`) BEFORE runCommand, which is precisely the branch the MCP handler skips. So an MCP-issued stamp against a store that answers 200 and writes NOTHING still reports success, and every agent that stamps over MCP is outside the wave-26 law. Criteria 0-2 unpaid; criterion 3 is [MERGE-GATED]. NOTE FOR THE BUILDER: criterion 1's 'one function renders both verdicts' means LIFTING renderStampVerdict + taskboard.FetchCriterion out of tasks_stamp_cmd.go into a shared seam, not adding a second read inside mcp_tasks.go.

## 6. Drifted pointers repaired in the reasons

| row | stored pointer | actual on origin/main |
|---|---|---|
| `pds-bl-sync-source-bypasses-publish-door` | `lifecycle.ex:277-279` | `:310` (fn at `:309`) |
| `pds-bl-remaining-os-create-sinks` | `cloud_workspace_cmd.go:699` | `:747` |
| `pds-w25-backlog-studio-criteria-text-edit` | `studio/plugins/adapter.ex` | `api/lib/barkpark_web/live/studio/plugins/adapter.ex` |
| `pds-bl-hetzner-create-image-post-condition` | `hetzner_cmd.go:1290-1329` | `:1517` (exemption at `:1553-1561`) |
| `pds-bl-publish-refusal-drops-teaching-text` | `lifecycle.ex:324-338` | `stale_claim_error/1` at `:438` |

The three pointers `pds-bl-remaining-os-create-sinks` criterion 0 names
(`hetzner_storage_cmd.go:453`, `hetzner_instance_transfer_cmd.go:229`, `context_render.go:177`)
all still resolve exactly — only the description's blob-leg reference had drifted, so the
criteria themselves needed no repair.

## 7. The gate

```
CENSUS_RC=0
bare 0 residue 20 distinct 213 nonempty 213
live 193 live_adjudicated 173 live_parked 29
live_adjudicated_no_reason []
live_park_no_trigger []
instant {'started': '2026-07-31T02:31:20.800257Z', 'finished': '2026-07-31T02:31:35.904963Z', 'seconds': 15.1}
GATE PASS
```

* clause **4(a)** — `live_bare == []`. Paid.
* clause **4(b)** — `live_adjudicated_no_reason == []`. Every adjudicated row carries a reason.
* clause **4(c)** — `live_park_no_trigger == []`. Every park still names what would reopen it.
* clause **1** — `reason_hashes_distinct == reasons_non_empty == 213`, up from 183. Adding 30
  reasons raised BOTH counts by exactly 30, which is the collision proof: had any of the 30
  new md5s matched an existing board hash, `distinct` would have lagged `non_empty`.

### The one conjunct that is NOT satisfiable, said plainly

Criterion 7 also demands `live_bare_residue == []`. It reads **20**, and it cannot read 0.
The residue is the set of bare rows born AFTER the round anchor — PDS-D364's one-round
deferral working exactly as designed. Nineteen of the twenty are this wave's own slices and
the findings its verifiers filed; adjudicating them here would both widen this slice and
collide with builders writing them right now (PDS-D352). The criterion's parenthetical
("or the then-current live total with zero bare") is the achievable target and it is met;
the `residue == []` conjunct is an authoring error that contradicts the same task's own
description. It was NOT met, so criterion 7 was not flipped — moving the bar to get a green
is the defect this epic exists to close.

## 8. Found while working, filed not swallowed

* **`pds-w27-bl-stamp-guard-substring-false-positive`** — `stampMergeGateBlocked`
  (`tasks_stamp_cmd.go:317-331`) is `strings.Contains(u, "MERGE-GATED")` over the whole
  `--criterion-text`, so a criterion that merely QUOTES the marker is unstampable and the only
  documented escape (`--merge-gated`) requires the builder to falsely assert lead identity.
  This slice's own criterion 6 hit it; the refusal was recorded rather than overridden.
* **guerrilla 500s under concurrent wave load**, observed during the writes: `/v1/tasks` stage
  (`GMc-0IwL9wjdWMsABzIy`) and `/v1/capabilities` (`GMc-0aRUiVvKiXwABuKh`). Each affected write
  was retried until the READ-BACK matched — never until the exit code was 0. Not folded into
  `pds-bl-census-read-path-500-under-load`, which is the `/v1/data/query` READ path.
* **self-ownership is not extinct** — `pds-barkpark-stop-4000-fallback` carries
  `disposition_owner == its own _id` today. Recorded in `pds-w25-round-open`'s and
  `pds-bl-disposition-owner-role-registry`'s reasons rather than filed as a new row, since the
  latter already owns the registry work.

