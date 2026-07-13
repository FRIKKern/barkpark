# Felix Pristine — Phoenix Mastery Audit (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **azure-hetzner-hosting live-smoke wave** — is preserved
> verbatim as its own canonical memory at `.claude/workflows/bp-azure-hetzner-hosting-charter.md`
> (16-slice roadmap, Decisions 1–48, wave logs through 2026-07-12; debrief commit b3148e9a).
> Do NOT read this file for azure-hetzner history. This slot is now the memory of the
> **Felix Pristine** epic.
>
> Epic anchor: bp task **`task-96a908af98698118`** ("Felix pristine initiative", published,
> 12 domain-audit children all lifecycle=done). Wave Paper: **`felix-pristine-wave-2026-07-13`**
> (guerrilla, style=article). Corpus + founding charter live as Papers on guerrilla:
> `/papers/felix-pristine-charter` and the per-domain `/papers/felix-findings-<domain>`.

## Vision

Phoenix mastery of the `api/` tree under an **improvement-only doctrine**: every change must
name a concrete failure mode and its measured cost or scar-class risk. The 12 domain audits
(OTP, Plug/Router, Context/Plugins, Ecto/Changesets, Transactions, Query/Index, LiveView
lifecycle, LiveView collections, Realtime/PubSub, Security/Tenancy, Test doctrine, Telemetry)
already ran and are all closed with per-concept verdict tables. This epic now converts the
ripe, already-named findings into **merged fixes with green Elixir gates**
(`CC=/usr/bin/clang mix test`), and adversarially re-audits whether the audits left qualifying
issues un-filed. `already-good` is the expected, honest verdict for most seams — no breadth
theater, no cosmetic diffs, no refactor that cannot state its failure mode in one sentence.

## The doctrine bar (binding on every slice and every filed issue)

A change qualifies ONLY if it: (1) prevents a NAMED failure mode — concrete inputs → wrong
outcome; (2) removes MEASURED cost — latency/memory/bytes/query-count with the number
attached; (3) closes a SCAR-CLASS risk — swept as a class, not a spot-fix; or (4) makes a
NAMED future change provably cheaper. Tree-tidiness, style churn, and idiom rewrites with none
of the above are rejected — including the auditor's own.

## Decisions

- **D1 — This is the SHIP + COVERAGE-VERIFY wave, not a founding audit.** The 12 domain audits
  are done; spawning fresh domain scouts would be breadth theater. Why: verification confirmed
  all 12 children are lifecycle=done with real merged fixes; only the ripe open findings + a
  targeted coverage re-audit remain.
- **D2 — Ship Magick timeout/-limit first (task-38d34db1ead325b5).** Why: it is the ONE
  genuinely-ripe THRUST-A fix left unfixed in the tree — `magick.ex:30` `System.cmd` has no
  timeout, no ImageMagick `-limit`, no OTP bound; a crafted/huge image pins CPU+RAM. Sharpest
  scar-class (resource-exhaustion DoS on a render path). Reach is Windows-only (backend selects
  Magick only on `{:win32,_}`; Linux/ARM prod rides Vix/libvips) — correctly calibrated LOW-reach,
  still worth the deadline+`-limit` seam. Corpus: Part XI ch 82 (Interop — Ports vs NIFs vs
  System.cmd), which the 12-domain set never assigned (see D9).
- **D3 — Do NOT rebuild ready_query (task-2c74954d53781113); verify-and-close it.** Why: commit
  45c34d3d "perf: hash ready queue dependencies" (2026-07-12, one day before this wave) already
  eliminated the named failure mode — the per-candidate correlated `NOT EXISTS` that wrapped the
  indexed `doc_id` in `regexp_replace` is gone, replaced by a materialized `done_tasks` CTE +
  hash-join, and it shipped its own green EXPLAIN test (`queue_test.exs:385`, verified GREEN,
  19 tests 0 failures). Spawning a builder on the task-as-written would rebuild landed work. The
  task is patched to verify-and-close; the LEAD seals it in review with the commit + test as
  evidence.
- **D4 — Ship the async:false→true flip, part 2 ONLY (task-5a5e2c939a33a621).** Why: the keystone
  (per-test rate-limiter bucket scope, commit bdf5db1d) already landed and removed the
  unconditional `ConnCase` `:ets.delete_all_objects` — so the flip is unblocked, but the ~2-3x
  wall-clock payoff was never collected (async:false ROSE to 445/787). Scope is TIGHT and
  correctness-gated: flip only files proven free of global mutable state; the ETS rate-limiter's
  own tests and the Application-env mutators (`media_test`, `studio_chat_test`,
  `github/plugin_test`) STAY serial. Measured cost = suite wall-clock, measured before/after as
  the acceptance evidence (none exists yet).
- **D5 — Ship the bokbasen_live unbounded+unguarded mount fix (NEW slice).** Why: coverage-verify
  found a genuine, un-filed instance of the exact scar-class the closed d07 LiveView audit fixed
  everywhere else. `plugins/onixedit/web/bokbasen_live.ex` `mount/3` calls `load_submissions()`
  UNCONDITIONALLY (not gated by `connected?/1`) → runs on both the discarded disconnected render
  AND the live mount (2× per open), and `load_submissions/0` does
  `Document |> where(type=="book" and dataset=="production") |> Repo.all()` with NO limit →
  unbounded per-socket assign that grows with ONIX volume. d07's F2 fix named board/inbox/settings/
  org_admin/staleness but MISSED bokbasen. Named failure + measured cost both present.
- **D6 — Ship the sobelow inline-annotation consistency fix + close task-f0bdb914d63a2e84.** Why:
  the 12 delta findings are genuine false positives already triaged in PR #2641 and the gate is
  green, but `studio_chat.ex`'s 4 attachment-path functions (and `root.html.heex` XSS.Raw) are
  suppressed ONLY by the line-anchored `.sobelow-skips` fingerprint, not by durable inline
  `# sobelow_skip` — the exact fragility the team already learned from (commit 158e2dd4): a later
  line-shift silently re-adds an unjustified skip with no in-code traceability. Named failure mode
  (silent suppression drift), small mechanical fix.
- **D7 — Phantom-media atomicity is BACKLOG, not a ship slice.** Why: `tenancy.ex` `delete_workspace`
  runs irreversible `Media.delete_file/2` side-effects (File.rm + CDN purge) inside an outer
  `Repo.transaction` that can still abort on a later document delete — resurrecting media_file rows
  pointing at purged blobs. BUT the moduledoc (tenancy.ex:907-913) already documents this exact
  trade-off with a stated retry mitigation, so it is a reasoned choice, not an un-named failure
  path; the "proper" fix (defer side-effects to an after-commit step, changing delete_file's
  contract) is a design change needing Fable-class judgment — and Fable is exhausted this wave.
  Filed as backlog with the named failure + repro-gap noted.
- **D8 — LiveView built-in telemetry consumer gap is BACKLOG.** Why: real — Phoenix emits
  `[:phoenix,:live_view,:mount|:handle_event,...]` but the new Prometheus reporter consumes none of
  it, so LiveView mount/handle_event duration stays prod-invisible. But its doctrine hook is (4)
  observability, the weakest class, and the wave already carries 4 self-justifying fixes. Filed as
  backlog.
- **D9 — Part XI corpus gap is BACKLOG (future audit wave).** Why: the 12 domains never assigned
  Part XI (ch 77–82: Absinthe/GraphQL, Mailers, File storage, i18n, Assets, Interop). That gap is
  why D2's Magick fix sits outside the domain tree as an orphan. Recorded as an open question for a
  future founding wave, not an urgent re-audit.
- **D10 — Ledger-hygiene re-stamp is BACKLOG.** Why: ~20 already-merged Felix fix tasks are
  lifecycle=done with `acceptance_criteria met:false`/empty evidence — real work, unstamped
  criteria, most likely forced by the `bp task close --set criteria` rubric-shape bug
  (task-6e819f39fe3aa9e6). Not a code risk; a bookkeeping/audit-trail risk (a future agent
  grep-checking "is X fixed" via bp alone wrongly concludes it is still open). Filed as backlog.
- **D11 — All builders opus; Fable exhausted this wave.** Why: hard lead constraint. Every ship
  slice is well-specified enough for opus; the one genuinely hard item (phantom-media after-commit
  redesign) was pushed to backlog rather than cut into under-specified opus slices.
- **D12 — Gate every slice in an isolated worktree with `CC=/usr/bin/clang`.** Why: the main
  checkout stays on main; local `cc` is a Claude wrapper, not the compiler. `mix test` is not
  blocked by the dev-boot OOM/registry blockers (test.exs disables the codelist seeder; registry
  self-call fixed a81e9761) — the borrow-warm-_build recipe (copy `_build/test`, symlink `deps`)
  is the fast path.

## Roadmap (this wave — all slices ordered by ship priority, sized)

1. **[P0, small] Magick timeout + `-limit` + Vix twin-check** — `task-38d34db1ead325b5` — opus.
   `magick.ex`: bound `System.cmd` with a deadline (Task.async+Task.shutdown or Port) that returns
   `{:error, :magick_timeout}`, add ImageMagick `-limit memory/map/time` args; fail-before test
   proving a past-deadline stub yields bounded `{:error,_}`; confirm/park the Vix sibling.
2. **[P1, medium] bokbasen_live connected?-guard + bounded query** — NEW — opus. Gate
   `load_submissions()` behind `connected?(socket)` (empty assign on disconnected render), cap the
   query with a LIMIT (or paginate); fail-before test proving disconnected mount does no DB
   projection and the assign is bounded.
3. **[P1, large] async:false→true tight flip + measured wall-clock** — `task-5a5e2c939a33a621` —
   opus. Flip only files with none of {Application.put_env, :persistent_term, Registry.,
   Process.register, raw :ets new/insert/delete_all}; keep rate-limiter + Application-env mutators
   serial; measure suite wall-clock before/after as evidence.
4. **[P2, small] sobelow inline-annotation consistency + close** — `task-f0bdb914d63a2e84` — opus.
   Copy the PR #2641 inline `# sobelow_skip` pattern onto `studio_chat.ex`'s 4 attachment functions
   (+ optionally `root.html.heex`); prove `mix sobelow --skip --exit Low` green.

Verify-and-close (no build): `task-2c74954d53781113` (ready_query) — fixed by 45c34d3d; lead seals.

Backlog seeded this wave (future): phantom-media atomicity (D7), LiveView telemetry consumer (D8),
Part XI corpus gap (D9), ledger-hygiene re-stamp (D10).

## Wave 5 Decisions (2026-07-13) — SHIP THE FILED BACKLOG

Wave Paper for this wave: **`felix-pristine-wave-5-2026-07-13`** (guerrilla, style=article).
Wave 4 shipped and MERGED on origin/main: Magick bound (#2868/4ce8c471), bokbasen mount-gate
(#2869/0641b1d3), sobelow durable inline skip (#2870/821fcada). D6's `task-f0bdb914d63a2e84`
is CLOSED (criteria 4/4 met) — roadmap item 4 above is done.

- **D13 — Wave 5 is SHIP-THE-BACKLOG, not re-audit.** Build the 5 filed backlog tasks + 1
  optional as opus slices, each its own worktree/PR with a fail-before protective test and a green
  `CC=/usr/bin/clang mix test`. The 12 domains stay closed; no fresh scouts.
- **D14 — async flip (`task-5a5e2c939a33a621`): the monolithic 230-file flip is EMPIRICALLY
  UNSAFE — re-scope to graduated tranches.** Why: V5 flipped the prior stalled worker's 230-file
  "SAFE" list and got NON-DETERMINISTIC breakage — two runs at the SAME seed gave 38 then 27
  DIFFERENT failures vs 0 failures / 154.5s serial baseline. Root cause is a NEW hazard class no
  grep heuristic caught: `on_exit` callbacks calling Repo helpers directly (sandbox-ownership
  violation via `ExUnit.OnExitHandler`) in `v1_media_search_suggestions_test.exs` /
  `v1_media_collections_test.exs`, plus `codelist_issue_version_test.exs` (self-documented racy).
  Even minus those 3, 227 files still gave 31 failures. DECISION: re-derive the candidate set off
  origin/main, flip in graduated tranches, run each twice with different seeds, keep ONLY what is
  green across both. A smaller proven-safe subset committed is an HONEST outcome. Re-parented from
  the d11 audit to the epic for wave coherence.
- **D15 — vix ceiling (`task-vix-bomb-explicit-ceiling`): SHIP (was a D2 "confirm/park" note).**
  Why: V6 proved it viable against the real NIF — libvips does NOT reject an inflated header;
  `Image.open` reports declared w/h LAZILY before any decode (50000² PNG opens ~1ms/0.2MB warm),
  and `Image.thumbnail` is ALSO lazy so the guard cannot lean on it failing. Fix = explicit
  pre-decode guard between `Image.open` (vix.ex:19) and `Image.thumbnail` (:20), reject when
  `width*height*bands` exceeds a config ceiling mirroring Magick's 256MiB, return
  `{:error, :vix_dimensions_exceeded}` (flows untouched through `Renditions.generate/6`). Fixture =
  checked-in ~68-byte PNG bomb. MECHANISM DIFFERS from the Magick twin (in-process header guard vs
  CLI `-limit`; libvips has no per-call limit) — call that out in the PR.
- **D16 — LiveView telemetry (`task-felix-liveview-telemetry-consumer`): SHIP (was D8 backlog).**
  Why: V7 proved the contract. Exactly 4 event families
  (`live_view mount|handle_params|handle_event` + `live_component handle_event`); `tag_values` is a
  1-arity metadata→map fn read via `Map.take` against declared `:tags` (a missing key SILENTLY
  DROPS the sample). ASYMMETRY: the 3 live_view metrics extract `socket.view` from the raw
  `%Socket{}`; the live_component metric tags off `metadata.component` (top-level) — do NOT reuse
  one generic fn. Template = `write_hotpath_telemetry_test.exs`; harness = `board_live_test.exs`.
- **D17 — Part XI (`task-felix-part-xi-corpus-gap`): SHIP as a bounded verdict-table Paper (was D9
  future-audit backlog).** Why: survey established the verdicts by grep — GraphQL not-applicable
  (no Absinthe), Mailers already-good (Swoosh env-gated), i18n decorative/not-applicable (0 real
  gettext call sites), Assets applies-differently (3 JS bundlers), File-storage applies
  (phantom-media parked), Interop live (produced Magick+vix). Deliverable is a per-concept verdict
  table published as a Paper — a distillation, NOT new digging; file gap tasks only if a real gap
  lands (expected: none).
- **D18 — Ledger re-stamp (`task-felix-ledger-restamp`): SHIP (was D10 backlog). Scope is the
  authoritative 24-target table (V1), NOT "~20".** Restamp via `/v1/data/mutate` patch+publish in
  one batch (V3-proven: patch writes `drafts.<id>`, the publish op promotes it; GET full array,
  flip only provable entries, PATCH whole array back, `ifRevisionID` from the doc endpoint).
  NEVER FABRICATE: `task-d328fb91ff55b743` (OTP) IS genuinely fixed by `fc9665e4/#2403` — RESTAMP
  not reopen (V1/V2 REFUTED the digest's "no landing commit" landmine); `task-a9adc82f820db065`
  shares #2390 with `task-9e21c3f285b3d7d0` — partial-stamp, its N=2000 wall-time criterion stays
  met:false with a duplicate-of note; `task-f0bdb914d63a2e84` is NOT a 25th target (already 4/4 met
  — V1 REFUTED the "wave-4 residue" claim). `task-6e819f39fe3aa9e6` does NOT block (done tasks have
  no live claim; mutate is self-serve).
- **D19 — Bokbasen pagination (`task-5dbbbe2efc44e48e`): SHIP in-wave as the 6th opus slice.**
  Why: the #2869 heap bound (`@page_limit=200`) made rows beyond the cap unreachable — a UX gap, no
  urgency risk, clean single-file. Design PINNED: offset-based pagination (`@page` +
  `next_page/prev_page` → `load_submissions/1` offset variant, page size = @page_limit) with a
  PubSub re-subscribe guard on page change; preserve the connected? gate + per-page heap bound.
- **D20 — Phantom-media atomicity (`task-felix-phantom-media-atomicity`) STAYS backlog.** Why: the
  after-commit-side-effects redesign is Fable-class judgment and Fable is exhausted — do NOT cut it
  into under-specified opus slices. Already filed/parked.
- **D21 — New backlog seeded this wave:** `task-felix-roothtml-durable-sobelow-skip` (root.html.heex
  XSS.Raw still fingerprint-only, drifted twice — durable inline skip owed) and
  `task-felix-interop-resource-bound-sweep` (the remaining System.cmd/Port sites — self_update,
  xmllint, studio_chat titles/probe — same scar-class as Magick/vix, out of this wave's scope).
- **D22 — Stale contradiction items retired.** The digest's two fabrication landmines (OTP
  "no landing commit"; `task-f0bdb914d63a2e84` "ledger-open 25th target") were BOTH refuted by
  V1/V2 — do NOT pass them to the restamp builder as open risks. D11 (all builders opus) and D12
  (gate in isolated worktree, `CC=/usr/bin/clang`, borrow-warm-`_build`) hold unchanged.

### Wave 5 roadmap (6 opus slices, integration-ordered)

1. **[P2] vix pixel/memory ceiling** — `task-vix-bomb-explicit-ceiling` — opus. Files: `vix.ex` +
   `vix_test.exs`. Gate: `CC=/usr/bin/clang mix test test/barkpark/media/image_backend/vix_test.exs`.
2. **[P2] LiveView telemetry consumer** — `task-felix-liveview-telemetry-consumer` — opus. Files:
   `telemetry.ex` + new `liveview_telemetry_test.exs`. Gate: `CC=/usr/bin/clang mix test <new test>`.
3. **[P2] BokbasenLive pagination** — `task-5dbbbe2efc44e48e` — opus. Files: `bokbasen_live.ex` +
   `bokbasen_live_test.exs`. Gate: `CC=/usr/bin/clang mix test .../bokbasen_live_test.exs`.
4. **[P3] Part XI verdict table** — `task-felix-part-xi-corpus-gap` — opus. Deliverable: a Barkpark
   Paper (no repo files). Gate: verdict-table Paper published + linked; any gap filed as a child.
5. **[P1] Ledger re-stamp (24 targets)** — `task-felix-ledger-restamp` — opus. No repo files
   (ledger writes). Gate: `bp task get` on a sample shows criteria_progress reflecting the restamp.
6. **[P1] async flip — validated subset + wall-clock** — `task-5a5e2c939a33a621` — opus. Files:
   `api/test/` (broad; excludes every keep-serial + sibling-edited file). Merges LAST (rebases on
   top; re-derives its subset against the then-current origin/main). Gate: two seed-varied green
   `CC=/usr/bin/clang mix test` runs + before/after wall-clock.

## Wave 6 Decisions (2026-07-13) — FINISH + HONEST-LEDGER (land the two unlanded wave-5 slices)

Wave Paper: **`felix-pristine-wave-6-2026-07-13`** (guerrilla, style=article). Wave 5 shipped and
MERGED 4 of 6 slices (vix ceiling #2897→merged path, LV telemetry, bokbasen pagination, Part XI
Paper #2900). Two slices were BUILT+reviewer-A- but never LANDED/CLOSED — they are local-only
branches with no PR. Wave 6 FINISHES exactly those two; it does NOT rebuild. Twelve wave-6 scouts +
three deep verifiers (full-24 SHA sweep, post-rebase seed-varied gate, close-mechanics) converged.

- **D23 — Wave 6 is FINISH + VERIFY-BEFORE-CLOSE, scoped TIGHT to the two unlanded slices.** Why:
  survey+verify cross-confirmed both wave-5 slices are BUILT and correct; "unlanded" means
  not-merged/not-closed, not not-built. Restamp = verify-and-close; async = rebase-and-land. Every
  other open Felix child is mapped-not-built (backlog). No fresh scouts; the 12 domains stay closed.
- **D24 — Ledger restamp (`task-felix-ledger-restamp`): VERIFY-AND-CLOSE via claim→close, NEVER raw
  mutate.** Why: the restamp mutations are already LIVE (all 24 published copies carry the asserted
  met-vectors; verify RAN a full-24 sweep — every cited SHA an ancestor of origin/main, criterion-vs-
  diff fidelity on 16 of 24, zero fabrication). The task is 5/5 met but lifecycle=open with an
  EXPIRED claim (epoch 6). Close mechanics (verify-proven): there is NO bare `set lifecycle_status`
  verb — `task.close` is claim/epoch-CAS-gated by design, so re-claim (fresh epoch) → `bp task close`.
  A raw `/v1/data/mutate` on lifecycle_status would bypass the exact CAS/work-digest fence this
  honest-ledger wave exists to protect. The builder re-runs the full-24 ancestry sweep against
  CURRENT origin/main as the close evidence — audit-grade, not inherited trust.
- **D25 — d328 OTP landmine: RESTAMP, not reopen (confirmed a THIRD time, live).** Why: fc9665e4/#2403
  genuinely tiers the top-level supervision tree (4 new supervisors + `supervision_isolation_test.exs`
  152L + `application_child_specs_test.exs` 87L); verify confirmed [T,T,T] on the ancestor commit and
  read the diff. The digest's "no landing commit" fabrication-landmine is REFUTED. Do NOT reopen. Rule
  of the wave: had it been genuinely unfixed, the correct move is REOPEN — never a fabricated commit
  (surfacing a false-done is a WIN).
- **D26 — #2390 pair is NOT a double-count; `task-a9adc82f820db065` STAYS [T,F,T].** Why: task-9e21c3f2
  (issue #2299) and task-a9adc82f (issue #2297) are distinct findings sharing one commit. a9adc82f's
  criterion[1] (reopen wall-time / `:erlang.external_size` byte at N=2000) is genuinely unmet — #2390
  measures only `:reductions` — so it stays honestly met:false with a duplicate-of note. The unmet
  measurement is filed as backlog, not force-stamped.
- **D27 — Async flip (`task-5a5e2c939a33a621`): LAND the 55-file set as-is; do NOT re-litigate or
  expand.** Why: 55 is the empirical honest ceiling — the analytic 230 was EMPIRICALLY UNSAFE (non-
  deterministic breakage across 4 grep-invisible hazard classes; see D14). origin/main has since
  advanced past the verify base and touched 10 of the 55 files, but ALL 55 flip-target
  `use …DataCase, async: false` lines survive on origin/main (confirmed) — so the flip RE-APPLIES
  deterministically off origin/main. Builder re-derives the 55-file flip (avoids cherry-pick context
  conflicts) rather than growing the set; expanding repeats the failure mode. Merge-gated criterion
  closed by the lead.
- **D28 — Async payoff recorded HONESTLY as net-neutral on current base, NOT −36%.** Why: verify RAN
  both seeds (0-fail) AND a same-seed baseline on current origin/main — flip 220.7s vs baseline 221.4s
  is FLAT (the −36% was true on the old base 47b8c0ce; today the serial sync tail dominates and
  absorbs the rebalance). The merge is justified by correctness (2 seeds, 0-fail), not a payoff
  number — distrust-vacuous-green cuts both ways. The builder re-stamps criterion[2] with the honest
  net-neutral evidence after the post-rebase gate.
- **D29 — 40P01 migration-DDL deadlock is a KNOWN pre-existing flake, not a wave-6 regression.** Why:
  `task-felix-migration-ddl-audit-deadlock` tracks it (workspace-delete-cascade DDL ACCESS-EXCLUSIVE
  lock vs a leaked fire-and-forget audit-dispatch Task). The 55-flip touches no DDL file but raises
  ambient concurrency on the audit path, so a 40P01 hit during the seed-varied gate is already-known,
  self-healing on isolated rerun — NOT a red flag. The wave Paper and PR note this explicitly to
  prevent a false alarm.
- **D30 — `task-f0bdb914d63a2e84` (the wish's "25th landmine") is already CLOSED this wave.** Why:
  lifecycle=done, closed_by=lead-opus 2026-07-13, all 4 criteria met citing #2870/821fcada (verified
  MERGED, mergeCommit an ancestor of origin/main). Genuinely fixed, honestly marked done — no restamp,
  no reopen, no action.
- **D31 — Both slices branch from ORIGIN/main (local checkout diverged +107/−54); isolated worktrees;
  `CC=/usr/bin/clang`; opus-only builders (Fable exhausted).** Restamp branch f6beac23 is a zero-diff
  audit anchor — no PR, no repo files. Async is a code PR the lead merges. D11/D12 hold unchanged.

### Wave 6 roadmap (2 opus slices, parallel — disjoint files)

1. **[P1] Ledger restamp — verify-and-close** — `task-felix-ledger-restamp` — opus. No repo files
   (ledger-only). Re-run the full-24 SHA-ancestry sweep against current origin/main, confirm every
   published copy's met-vector unchanged (a9adc82f stays [T,F,T]), then claim→close (fresh epoch;
   NEVER raw mutate). Gate: ancestry sweep prints all-ANCESTOR + `bp task get task-felix-ledger-restamp`
   shows lifecycle=done post-close.
2. **[P1] async flip — land the 55-file subset** — `task-5a5e2c939a33a621` — opus. Files: the 55
   `api/test/**_test.exs` files of commit 0b9dcf8c (re-derived off origin/main). Rebase/re-apply,
   two seed-varied `CC=/usr/bin/clang mix test` green (0-fail; a 40P01 hit is the known flake per D29),
   push + open PR; builder stamps [1][2][3] with honest net-neutral payoff (D28); LEAD closes [4]
   (merge gate). Gate: two `CC=/usr/bin/clang mix test --seed N` runs, 0 failures each.

Backlog (mapped-not-built this wave): 3 open Group-A felix PRs #2897/#2898/#2899 (tasks
`task-vix-bomb-explicit-ceiling` in_progress, LV-telemetry + bokbasen DONE — merge cleanup);
`task-felix-roothtml-durable-sobelow-skip`, `task-felix-interop-resource-bound-sweep`,
`task-felix-phantom-media-atomicity`, `task-felix-migration-ddl-audit-deadlock` (all open);
NEW `task-felix-a9adc82f-reopen-wall-time-measure` (the unmet #2390 N=2000 measurement).

## Wave 7 Decisions (2026-07-13) — FINISH THE FOUR OPEN BACKLOG CHILDREN

Wave Paper: **`felix-pristine-wave-7-2026-07-13`** (guerrilla, style=article). Wave 6 LANDED
and closed: async flip #2917 (54-file, net-neutral, merge-gate closed), ledger restamp SEALED,
and the Group-A PRs #2897/#2898/#2899/#2900 are ALL MERGED now. Wave 7 converts the four remaining
open named-failure children into merged, gate-green fixes — nothing net-new, no re-audit. Two
explore rounds (11 surveys + a parse-only verify pass) resolved every crux; the surveys OVERTURNED
two premises baked into the wish and the tentative direction — recorded below as the load-bearing
corrections. Builders branch from ORIGIN/main (local checkout diverged; origin/main has advanced
past every survey SHA — the live raw() call is at root.html.heex:2901, `.sobelow-skips` grew to
193 lines / 4 root + 42 router — so every count/line MUST be derived live off origin/main, never
copied from the survey).

- **D32 — Wave 7 = FINISH THE BACKLOG, one opus PR per child.** Four slices, each 1:1 with an
  already-filed open child under `task-96a908af98698118`, each its own worktree/PR with a
  fail-before protective test and a green `CC=/usr/bin/clang mix test`. No fresh scouts; the 12
  domains stay closed; do NOT re-handle wave-6 landed work.
- **D33 — sobelow durable skip (`task-felix-roothtml-durable-sobelow-skip`): SCOPE TO
  root.html.heex ONLY; mechanism is HOIST-then-inline, NOT annotate-in-place; router.ex is
  DROPPED from this slice.** Why (survey triple-confirmed, empirically + from vendored source):
  inline `# sobelow_skip` attaches ONLY to `def`/`defp` function-body findings via `combine_skips`.
  (a) router.ex Config.* (CSRF/CSP/Headers on pipelines) run through `Config.fetch` — never touch
  `combine_skips` → inline is INERT; that ground was already triaged by #2643/#2641 (rationale
  comments + 2 real source fixes). (b) HEEx `raw()` (XSS.Raw) ALSO bypasses `combine_skips`
  (`XSS.get_template_vulns` hardcodes skip_mods=nil) → an inline comment IN the heex is ALSO inert
  (empirically verified: it only shifted the drift target one line). The ONLY durable fix for
  root.html.heex: HOIST the single live `raw(Barkpark.PortableDoc.Render.Stylesheet.css())` into a
  small `.ex` helper `def` carrying `# sobelow_skip ["XSS.Raw"]`, called from the template — then
  the file has ZERO raw() → ZERO XSS.Raw findings → remove ALL its `.sobelow-skips` entries; it
  never reds on line-shift again. ALSO prune the dead router.ex fossil entries (survey found ~63%
  have no live counterpart — `--mark-skip-all` is append-only) as a low-risk baseline cleanup, but
  this does NOT stop router.ex line-drift for LIVE findings (that durable fix is per-plug scoped
  CSP → D37 backlog). Slice 1 SOLELY owns `.sobelow-skips`.
- **D34 — interop sweep (`task-felix-interop-resource-bound-sweep`): ONE opus PR, THREE adopt
  fixes + one already-good verdict, mirroring titles.ex's documented Task.yield+brutal_kill
  pattern per-site (no shared-abstraction extraction — keeps blast radius low, Fable exhausted).**
  Per-site verdicts (survey `interop-site-inventory`): probe.ex:197 `defp run/2` (claude
  version/auth System.cmd) = ADOPT (strongest — spawned per Studio-chat mount via
  `kick_readiness_probe`, NO dedup → one orphaned OS child per page load if the probe stalls);
  self_update/runner.ex:114 preflight System.cmd + :249 Port.open = ADOPT (admin-gated but
  unbounded — a stalled preflight hangs the admin request forever, a stalled main run wedges
  `running?=true` until a BEAM restart); onixedit/export/validator.ex:72 xmllint System.cmd =
  ADOPT (content-editor-controlled XML even though the route is admin-gated — pathological ONIX
  hangs the export/Bokbasen worker); titles.ex:366 = ALREADY-GOOD (Task.yield+brutal_kill +
  `@cli_timeout_ms 15_000` already present — record verdict, NO churn); build_info.ex
  (compile-time only) + claude_chat.ex:853 (monitored Port, closed in terminate/2) = OUT OF SCOPE.
  Each adopt gets a named error atom + config-overridable timeout + fail-before stub-binary test
  (assert bounded error atom AND wall-clock cut via `:timer.tc`). Moving a System.cmd off its line
  breaks its CI.System baseline entry → each moved call carries an inline `# sobelow_skip
  ["CI.System"]` (CI.System IS function-body-scoped → inline WORKS, per the magick.ex precedent);
  slice 2 does NOT edit `.sobelow-skips` (inline suppresses at the new location; the residual
  fossils are harmless and mopped up by D38).
- **D35 — migration-DDL deadlock (`task-felix-migration-ddl-audit-deadlock`): fix via direction
  (a) — a wired sync-in-test toggle scoped to the AUDIT dispatch path ONLY.** Why: root cause is
  pinned (survey `audit-dispatch-path`) — `Audit.emit` → `safe_bridge` → `dispatch_audit_async`
  → `fan_out`'s `Task.Supervisor.start_child` spawns an UNAWAITED task; DataCase's `$callers`-drain
  only covers the ORIGINATING test and ExUnit gives no ordering guarantee it finishes before a
  concurrent DDL test's `shared: true` window, so a leaked audit SELECT deadlocks the raw
  ALTER-TABLE (40P01). Fix: add `config :barkpark, :audit_dispatch_async` (default true), set
  `false` in config/test.exs, and have `dispatch_audit_async/1` run the fan-out SYNCHRONOUSLY
  in-caller (owner-scoped, joins the sandbox, dies with the test) when the flag is false — scoped
  to the AUDIT path ONLY (do NOT touch the shared `fan_out/2` general webhook dispatch — that would
  break async-webhook tests and widen blast radius). The dead `search_analytics_async` config
  (present but read NOWHERE) is the intent-precedent, so this is net-new plumbing wired for real,
  not a knob-flip. Direction (b) (serialized DDL group) rejected: needs new mix.exs/CI wiring and
  does NOT fix the sibling `:flaky` Migrator-Task race (→ D38). Protective test (deterministic,
  fast): with the flag OFF, after `Audit.emit` NO leaked task remains on `Barkpark.TaskSupervisor`
  and the delivery ran inline; fail-before = the async path leaks a non-owner-scoped task.
  Acceptance also carries the flake-gone confirmation: N≥10 full-suite runs, 0 40P01 (the natural
  flake is rare — <1-in-2 — so a manufactured concurrent repro is allowed for the fail-before proof).
- **D36 — phantom-media atomicity (`task-felix-phantom-media-atomicity`): SUPERSEDES D20's
  Fable-class parking — it is now MECHANICAL and opus-safe, ONE PR (repro-first within it), and
  the deferred set WIDENS to all FOUR non-DB irreversible effects.** Why: the after-commit
  primitive ALREADY EXISTS and is battle-tested — `Barkpark.Content.Broadcast`'s
  `Repo.in_transaction?()`-gated process-dict queue (flush on commit, clear on rollback), consumed
  by `Content.Mutations`. Media.delete_file/2 has only 4 callers, only 1 (tenancy) needs a change.
  Repro-first: the existing atomicity test (tenancy_delete_workspace_test.exs, halt via
  `MediaDeleteSpyPlugin`) already asserts the media_file ROW survives rollback but discards the
  captured `on_disk` path — add `refute File.exists?(on_disk)` → RED today (row alive + blob gone
  = phantom). Fix: when `Repo.in_transaction?()`, delete_file DEFERS the four non-DB effects —
  Cdn.invalidate, Events.dispatch, File.rm, Renditions.delete_for_file — into a process-dict queue
  (mirror Broadcast's triad), flushed by tenancy.ex's delete_workspace transaction wrapper on
  `{:ok,_}` / cleared on rollback; keep `run_after_media_delete` (a DB write) in-transaction. The
  original criterion "File.rm + Cdn.invalidate" is provably INCOMPLETE (survey
  `media-delete-file-contract`): Events.dispatch fires an irreversible webhook telling the world
  the file is gone; Renditions is the same irreversible-disk class — WIDEN to all four. The other
  3 callers are outside a transaction (`Repo.in_transaction?()` false) → fire immediately as
  today, unchanged. Document the `after_media_delete` hook as "DB-writes only; no file/HTTP I/O"
  so a future plugin can't reopen the hole. Highest blast radius this wave — opus, exhaustive
  instructions.
- **D37 — All builders opus; Fable exhausted (unchanged from D11/D31). Guardrails hold:** branch
  from ORIGIN/main, main checkout stays on main, isolated worktrees, `CC=/usr/bin/clang`,
  borrow-warm-`_build` (copy `_build/test`, symlink `deps`). Slices are file-disjoint (slice 1:
  root.html.heex + `.sobelow-skips` + a new/edited layouts helper; slice 2: probe.ex, runner.ex,
  validator.ex + tests; slice 3: dispatcher.ex, config/{config,test}.exs + an audit test; slice 4:
  media.ex, tenancy.ex + two media/tenancy tests + optional deferral module) → all four dispatch
  in parallel.
- **D38 — New backlog seeded this wave (published children of the epic):**
  `task-0fc9d55c4725ab92` (router.ex per-plug scoped CSP — the genuinely-durable fix for the
  Config.* line-drift toil that inline can't touch; PUBLISHED this wave, was a stranded draft);
  `task-felix-sobelow-baseline-reconcile` (a reconcile-not-append `.sobelow-skips` regen step so
  the baseline stops only-growing and residual CI.System fossils from slice 2 get swept);
  `task-felix-migrator-task-sandbox-race` (the sibling `:flaky` Migrator-Task sandbox-escape bug
  in codelist_issue_version / restore_search_null_dataset_dedup — a DIFFERENT root cause from D35's
  audit dispatch, uncovered by slice 3); `task-felix-suite-order-flakes` (two pre-existing
  order-dependent gate flakes surfaced by the test-gate recipe — ContentProbeTest atom_count race
  + PulsePublicSurfaceTest rate-limit-window). accounts_test TOCTOU (`task-5f4c0d03c05cd10e`) is
  already filed — not refiled.

### Wave 7 roadmap (4 opus slices, parallel — disjoint files)

1. **[P0, medium] sobelow durable skip — root.html.heex hoist + baseline prune** —
   `task-felix-roothtml-durable-sobelow-skip` — opus. Files: `api/lib/barkpark_web/layouts/`
   (root.html.heex + a helper `def`), `api/.sobelow-skips`. Gate: `cd api && CC=/usr/bin/clang mix
   sobelow --skip --exit Low` exits 0, and a fresh `mix sobelow` scan shows root.html.heex yields
   ZERO findings + every remaining baseline entry maps to a live finding.
2. **[P1, large] interop resource-bound sweep — probe + self_update + xmllint** —
   `task-felix-interop-resource-bound-sweep` — opus. Files: `api/lib/barkpark/studio_chat/probe.ex`,
   `api/lib/barkpark/self_update/runner.ex`, `api/lib/barkpark/plugins/onixedit/export/validator.ex`
   + their `_test.exs`. Gate: `cd api && CC=/usr/bin/clang mix test` on the three new/updated test
   files.
3. **[P1, medium] migration-DDL deadlock — sync-in-test audit dispatch** —
   `task-felix-migration-ddl-audit-deadlock` — opus. Files: `api/lib/barkpark/webhooks/dispatcher.ex`,
   `api/config/config.exs`, `api/config/test.exs` + an audit-dispatch test. Gate: the protective
   test green (no leaked task under the sync toggle) + N≥10 full-suite `CC=/usr/bin/clang mix test`
   with 0 40P01 (merge-gated).
4. **[P2, large] phantom-media atomicity — repro-first + after-commit deferral** —
   `task-felix-phantom-media-atomicity` — opus. Files: `api/lib/barkpark/media.ex`,
   `api/lib/barkpark/tenancy.ex`, `api/test/barkpark/tenancy_delete_workspace_test.exs`,
   `api/test/barkpark/media_test.exs` (+ optional deferral module). Gate: `cd api &&
   CC=/usr/bin/clang mix test test/barkpark/tenancy_delete_workspace_test.exs test/barkpark/media_test.exs`.

## Wave log

- **Wave 7 — 2026-07-13 — REVIEWED (A, per `felix-pristine-wave-7-2026-07-13`).** All four opus
  slices built; gates re-run GREEN on the reviewer's final state (borrow-warm `_build/test` + deps
  symlink, `CC=/usr/bin/clang`, `+S 2:2`). (1) **sobelow durable skip**
  (`loop-epic/sobelow-durable-skip-root-html-heex-hois-0`) — the single `raw(...Stylesheet.css())`
  hoisted out of root.html.heex into `BarkparkWeb.Layouts.paper_stylesheet/0` with an inline
  `# sobelow_skip ["XSS.Raw"]`; `.sobelow-skips` pruned 193→84 (no root.html.heex/layouts.ex entry
  remains). REVIEWER-PROVEN: `mix sobelow --skip` → 0 surviving findings AND layouts.ex:48 is
  suppressed only under `--skip` (so the inline skip demonstrably attaches through @doc/@spec) —
  baseline genuinely pruned, not blanket-ignored. (2) **interop resource-bound sweep**
  (`loop-epic/interop-resource-bound-sweep-probe-ex-se-1`) — probe.ex / self_update runner.ex /
  xmllint validator.ex bounded (async_nolink+Task.yield+brutal_kill / size-cap-before-write / Port
  watchdog); 31 tests + sobelow green, `.sobelow-skips` untouched. Reviewer-verified: both probe
  callers degrade the new `{:error,:probe_timeout}` correctly, the watchdog guard matches the real
  `run: :running` state and stale deadlines fall through to the catch-all. (3) **phantom-media
  atomicity** (`loop-epic/phantom-media-atomicity-repro-first-defe-3`) — four irreversible non-DB
  effects deferred to after-commit via a process-dict queue mirroring `Content.Broadcast`; 41 tests
  green. Reviewer-verified: `delete_workspace_media` is the ONLY in-transaction `delete_file` caller
  (queue always flushed on commit / cleared on rollback), the three others fire immediately as before;
  the builder's `assert File.exists?` (vs the brief's `refute`) is CORRECT — the phantom is
  row-alive+blob-gone. (4) **migration-DDL deadlock**
  (`loop-epic/migration-ddl-deadlock-sync-in-test-audi-2`) — audit-path-only sync toggle,
  `fan_out/2` untouched, default TRUE preserves prod/dev; protective test 5/5 green (reviewer-run).
  **LEDGER FIX:** all three built slices carried a uniform off-by-one stamp bug (builders passed
  1-based `--criterion N` into the 0-based tool) — the MERGE criterion was falsely met=true and the
  first real criterion falsely unmet, evidence shifted by one. Reviewer re-patched all three
  (roothtml→TTTF, interop→TTTTTF, phantom→TTTF) so real work reads met-with-evidence and the MERGE
  gate stays open for the lead; migration-ddl was already honest (TTFF). NO code fixes were needed —
  all four slices correct as built; final branches are the originals (reviewer made zero code commits).
  **Merge-gated criteria the lead closes on merge:** all four final criteria (PR merged), PLUS
  migration-ddl criterion[2] — N≥10 full-suite `mix test`, 0 Postgrex 40P01 — the one substantive
  obligation still owed (reviewer ran only the single-file protective test, not the N≥10 sweep).
  **Next wave (8):** merge the four PRs (Elixir-gated), have the lead run + stamp migration-ddl's N≥10
  evidence before merging it, then clear the remaining D38 backlog (router-CSP durable skip, sobelow
  baseline-reconcile, sibling Migrator-Task sandbox race, two suite-order flakes, a9adc82f N=2000
  measurement) — Felix's named-failure backlog is otherwise emptied.

- **Wave 7 — 2026-07-13 — DECIDED (building).** Ratified D32–D38. Four opus slices under
  `task-96a908af98698118`, each 1:1 with an open backlog child, all linked to
  `felix-pristine-wave-7-2026-07-13`, all file-disjoint (parallel): (1) sobelow durable skip —
  root.html.heex HOIST-then-inline + baseline prune (survey OVERTURNED the wish: inline is inert
  for BOTH router.ex Config.* AND heex XSS.Raw; hoist the single raw() into an `.ex` helper is the
  only durable route; router.ex dropped); (2) interop sweep — probe.ex + self_update + xmllint
  bounded, titles.ex already-good (one PR, three fixes mirroring titles.ex's documented
  Task.yield+brutal_kill); (3) migration-DDL deadlock — direction (a) sync-in-test audit dispatch
  toggle scoped to the audit path; (4) phantom-media — SUPERSEDES D20's parking (the
  `Content.Broadcast` after-commit triad already exists → mechanical/opus-safe), repro-first +
  defer all FOUR non-DB irreversible effects (widened from File.rm+Cdn). Two explore rounds
  resolved every crux; load-bearing facts re-verified on origin/main pre-decision (Broadcast queue,
  probe/titles wrappers, audit fan_out spawn, media.ex effect order, tenancy transaction wrapper).
  Backlog seeded: router CSP (published from draft), sobelow baseline-reconcile, sibling
  Migrator-Task sandbox race, two suite-order flakes. Fable exhausted — all builders opus. Grade:
  pending build+review.
- **Wave 6 — 2026-07-13 — REVIEWED (A−).** Both slices FINISHED honestly.
  **(1) Ledger restamp (`task-felix-ledger-restamp`) — SEALED, lifecycle=done, 5/5 met.** Reviewer
  re-ran the full-24 SHA-ancestry sweep vs current origin/main: 22/22 ANCESTOR, zero fabrication.
  Sentinels re-read on the PUBLISHED copies (`/v1/data/doc`, `_draft=false`): a9adc82f820db065 holds
  [T,F,T] (N=2000 wall-time/byte honest-miss NEVER flipped, #2390 duplicate-of note); d328fb91 holds
  [T,T,T] on fc9665e4/#2403 (RESTAMPED not reopened — confirmed `fix(otp): tier the top-level
  supervision tree (#2403)`, a real ancestor genuinely fixing the blast-radius failure); 9e21c3f2
  [T,T,T] #2390 (distinct-shared, not a double-count). Branch fb6cdd1d = zero-diff audit anchor (no
  PR). Exemplary honest-ledger work. **(2) Async flip (`task-5a5e2c939a33a621`) — CORRECT, PR #2917
  open/mergeable, lifecycle=in_progress (merge-gate criterion[4] LEAD-owned).** Diff verified
  surgically pure: 57 `async:false→true` lines across 54 files, zero other changes; keep-serial set
  intact; media_search_scope (broad-grep false hit) confirmed hazard-free. Honestly scoped to 54 not
  55 (accounts_test excluded for a flip-attributable TOCTOU flake → backlog `task-5f4c0d03c05cd10e`).
  Payoff honestly recorded NET-NEUTRAL (async 43.6s vs sync 229.8s — the serial tail dominates;
  confirms D28, no fabricated −36%). CAVEAT (reviewer_note stamped on the task): reviewer full-suite
  re-gate under load-avg 14–19 + 3 concurrent BEAM suites surfaced non-deterministic `DBConnection`
  pool-timeout flakes at both seeds — PROVEN ENVIRONMENTAL, not flip-attributable: an UNFLIPPED file
  (`content_schema_workspace_scope_test.exs`, still async:false) failed with the identical signature,
  both failing files pass clean in isolation (32 tests/0-fail/0.3s), runtime inflated 2.2× (490s vs
  builder 220s). NOT reverted — the diff is correct. Merge MUST gate on CI Elixir Test green; the flip
  raises peak pool concurrency for a net-neutral payoff, so watch for pool-timeouts on constrained
  runners. Ledger fixed: wave_paper back-link added to both slice tasks. **Next wave:** lead merges
  #2917 on CI-green + closes criterion[4]; then Wave 7 = merge-cleanup of the 3 open Group-A felix PRs
  (#2897/#2898/#2899) and the open backlog children (roothtml skip, interop sweep, migration-ddl
  deadlock, phantom-media, a9adc82f N=2000 measurement).

- **Wave 6 — 2026-07-13 — DECIDED (building).** Ratified D23–D31. Two opus slices under
  `task-96a908af98698118`, both linked to `felix-pristine-wave-6-2026-07-13`: ledger restamp
  (verify-and-close, claim→close not raw mutate) and async flip (land the 55-file subset off
  origin/main, honest net-neutral payoff). Full-24 SHA sweep + post-rebase seed-varied gate proved
  green pre-decision. Backlog: 3 open felix PRs, 4 open backlog children, + new a9adc82f measurement
  gap. Fable exhausted — all builders opus. Grade: pending build+review.
- **Wave 5 — 2026-07-13 — SHIPPED (A-, per `felix-pristine-wave-5-2026-07-13`).** Ratified D13–D22.
  Merged 4 of 6: vix ceiling, LV telemetry, bokbasen pagination, Part XI verdict-table Paper. Two
  slices built+A- but left unlanded (ledger restamp, async flip) → carried to Wave 6 to LAND.
  Backlog seeded: root.html.heex durable skip, interop resource-bound sweep. Phantom-media parked.
- **Wave 4 — 2026-07-13 — SHIPPED (grade recorded prior).** Magick bound #2868, bokbasen
  mount-gate #2869, sobelow durable inline skip #2870 — all merged to origin/main.
