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

## Wave 8 Decisions (2026-07-13) — CI-HARDENING FINISH (kill the flaky / only-growing test infra)

Wave Paper: **`felix-pristine-wave-8-2026-07-13`** (guerrilla, style=article). Wave 7 LANDED and
MERGED its shippable slices (sobelow durable skip #2956, interop sweep #2954, phantom-media #2955);
the migration-DDL audit-dispatch fix (`task-felix-migration-ddl-audit-deadlock`, D35) is STILL OPEN
and UNMERGED on origin/main — that matters for slice 3 below. Wave 8 finishes the three OPEN
D38-seeded CI-hardening children — nothing net-new, no re-audit. Four RUN verifiers (V1–V4, all
executed `mix test`/`sobelow` with pasted output) OVERTURNED two premises baked into the wish; the
corrections are the load-bearing content of this wave. Builders branch from ORIGIN/main (local
checkout diverged ~114/−109 with omx commits — never build from it).

- **D39 — Wave 8 = FINISH-THE-CI-HARDENING-BACKLOG, exactly 3 opus slices.** Each 1:1 with an open
  D38 child under `task-96a908af98698118`, each its own worktree/PR with a fail-before REPRODUCTION
  (a flake fix with no reproduction is vacuous-green and rejected). All builders opus (Fable
  exhausted). No fresh scouts; the 12 domains stay closed; do NOT re-handle wave-7 landed work.
- **D40 — Slice 1 (`task-felix-suite-order-flakes`) ships BOTH proven fixes; it is the ACTUAL
  merge-train reddener → priority raised to P3.** These two tests are UN-tagged and run in the
  default `mix test` gate, so a rebased PR's Test reds on THEM. (a) content_probe_test.exs:83
  (async:true) asserts `:erlang.system_info(:atom_count) == before`, a whole-VM invariant any
  concurrent atom-mint breaks (content_get itself is atom-safe). Fix (V3-proven red→green): drop the
  global-counter read, keep async:true, assert `assert_raise ArgumentError, fn ->
  String.to_existing_atom(key) end` after `content_get(...) == nil`. (b) pulse_public_surface_test.exs
  :118-127 drives the burst-cap on the FAST-refill test-storm channel (10 tok/sec) and asserts
  `== 3` of 4; ~100ms latency refills a 4th token. The wish's Process.sleep(120ms)+`<=@burst`-on-
  test-storm is a RED test (V3: 120ms over-refills → all 4×200, 429 gone → reds BOTH `==3` and
  `<=@burst`). CORRECT fix: RETARGET the burst onto the SLOW-refill abuse-rate channel
  (config/test.exs:116-120, 0.1 tok/sec) asserting `two_hundreds <= @burst` AND `429 in statuses`,
  mirroring the latency-immune pulse_abuse_drill_test.exs:55-62.
- **D41 — Slice 2 (`task-felix-sobelow-baseline-reconcile`): reconcile = clear-skip THEN
  mark-skip-all, but it MUST run on the CI toolchain, NOT a dev-box target — and the task's dead-count
  figures are STALE.** Root cause confirmed from dep source: `--mark-skip-all` opens `.sobelow-skips`
  in APPEND mode (sobelow.ex:512), fingerprints are line-anchored → only grows. Native reconcile
  (V2 ran it end-to-end): `mix sobelow --clear-skip` (File.rm) then `mix sobelow --mark-skip-all`
  (regenerate) = the live set. DECISIVE HAZARD — TOOLCHAIN DRIFT: a dev-box regen (1.19.5/OTP28)
  emits 108 findings while CI (1.18.1/OTP27) emits a different set; the committed 84-baseline even
  REDS on the dev toolchain (media.ex:408 live vs baselined :400). So the reconcile MUST run on the
  CI toolchain (or inside CI) and be captured as an upload-artifact for human review (OpenAPI-regen
  playbook shape) — it MUST NOT be a dev-box make target that commits a locally-regenerated baseline.
  The task's "193 lines / 63% dead" is STALE: origin/main is 84 lines, ~93% LIVE — only 6 dead
  fossils (3 CI.System line-shifted by #2954 + 3 Traversal). GUARD (V2-proven): a planted
  non-controller `String.to_atom` fixture still reds `mix sobelow --skip --exit Low` (exit 1). The
  gate is ADVISORY (continue-on-error) — this improves hygiene, NEVER blocks a merge; do NOT flip it
  to blocking (that is backlog `task-felix-sobelow-gate-blocking-eval`).
- **D42 — Slice 3 (`task-felix-migrator-task-sandbox-race`): the task PREMISE IS REFUTED —
  rewritten.** V1 (20 seeds) proved: (1) NO 40P01 reproduces (0/20; repo-wide grep for
  `40P01|deadlock_detected` is EMPTY — the "deadlock" label is comment-only), so the "N≥10 runs, 0
  40P01" bar is trivially already met. (2) What reproduces DETERMINISTICALLY (20/20) is Fixture E —
  the ONLY test calling `Ecto.Migrator` (codelist_issue_version_test.exs:207, up/down :222/:234) —
  failing with a `DBConnection.ConnectionError` connection-checkout timeout, stack rooted at
  `ecto_sql migrator.ex:354 ← Task.Supervised.invoke_mfa`. Root cause: the parent test holds the
  migration advisory lock (a transaction) on the single SHARED sandbox conn (data_case.ex:82,
  `shared: not async`); the Migrator's `Task.async |> Task.await` child queues behind it → ~970ms
  timeout. It is NOT an ownership/`Sandbox.allow` gap (shared mode already shares the conn; `Task.async`
  already propagates `$callers`) — so the task's prescribed fix CANNOT work. PROVEN fix:
  `migration_lock: false` on Fixture E's up/down calls → 0/20 failures (preserves the SQLSTATE-22023
  jsonb regression the fixture guards). The other 6 `:flaky` tests (codelist A–D + restore_search ×2)
  drive `apply_up/1` directly (no Task/Migrator) and NEVER fail → detag them.
- **D43 — Slice-3 CONFOUND + rewritten acceptance criteria.** V4: D35's audit-dispatch 40P01 fix is
  UNMERGED on origin/main (grep `audit_dispatch_async`=0; `task-felix-migration-ddl-audit-deadlock`
  lifecycle=open) and its `fan_out` still spawns an unawaited `Task.Supervisor.start_child`; its
  documented victim `extend_workspace_delete_cascade_test.exs` shares slice-3's migrations test dir,
  so a live 40P01 CAN fire during slice-3's gate and be mis-charged to the migrator — every observed
  40P01 MUST be stack-attributed and a hit rooted in `dispatch_audit_async/fan_out` is D35's, not
  slice-3's. These `:flaky` tests are excluded by default (test_helper.exs:53) and CI never runs
  `--include flaky`, so they are NOT the merge-train symptom (that is slice 1). Criteria rewritten:
  [0] Fixture E `migration_lock:false` with the captured deterministic ConnectionError as fail-before;
  [1] detag the 6 apply_up tests on N≥10 `--include flaky` evidence, stack-attributed, file a new
  backlog child if any still flakes for a distinct cause; [2] merge gate (lead). D35 must still merge
  separately to clear the live 40P01 source.
- **D44 — Guardrails (unchanged from D37): all opus, branch from ORIGIN/main, main checkout stays on
  main, isolated worktrees, `CC=/usr/bin/clang`, borrow-warm `_build`.** The 3 slices are
  file-disjoint → dispatch in parallel. Backlog seeded this wave (published children of the epic):
  `task-felix-pulse-ratelimit-scope-isolation` (Pulse bypasses the landed per-test rate-limit bucket
  scope — raw `{:pulse,ip,channel}` keys → cross-test bucket-bleed risk) and
  `task-felix-sobelow-gate-blocking-eval` (flip the advisory sobelow gate to blocking once the CI
  reconcile lands).

### Wave 8 roadmap (3 opus slices, parallel — disjoint files)

1. **[P3, small] suite-order flakes — content_probe + pulse deflake** — `task-felix-suite-order-flakes`
   — opus. Files: `api/test/barkpark/plugins/content_probe_test.exs`,
   `api/test/barkpark_web/pulse_public_surface_test.exs`. Gate: `cd api && CC=/usr/bin/clang mix test
   test/barkpark/plugins/content_probe_test.exs test/barkpark_web/pulse_public_surface_test.exs`.
2. **[P4, medium] sobelow reconcile-not-append — CI-toolchain regen + fresh-finding guard** —
   `task-felix-sobelow-baseline-reconcile` — opus. Files: `api/scripts/` (new reconcile + guard
   scripts), `.github/workflows/security.yml`. Does NOT commit a dev-regenerated `.sobelow-skips`.
   Local gate: `cd api && CC=/usr/bin/clang mix sobelow --skip --exit Low` reds (exit 1) with a
   planted fixture, greens (exit 0) without; the CI-toolchain reconcile runs as a security.yml job
   step uploading the artifact.
3. **[P4, small] migrator/DDL deflake — Fixture E migration_lock:false + detag 6 apply_up tests** —
   `task-felix-migrator-task-sandbox-race` — opus. Files:
   `api/test/barkpark/repo/migrations/codelist_issue_version_test.exs`,
   `api/test/barkpark/repo/migrations/restore_search_null_dataset_dedup_test.exs`. Gate: `cd api &&
   CC=/usr/bin/clang mix test test/barkpark/repo/migrations/codelist_issue_version_test.exs
   test/barkpark/repo/migrations/restore_search_null_dataset_dedup_test.exs --include flaky`.

## Wave 9 Decisions (2026-07-13) — FINISH-THE-BACKLOG + ONE FRESH AUDIT

Wave Paper: **`felix-pristine-wave-9-2026-07-13`** (guerrilla, style=article). Wave 8 LANDED and
MERGED its two slices — #3015 (suite-order deflake) and #3016 (migrator/DDL Fixture-E
`migration_lock:false`) — plus charter commit 17f5b3ca; both W8 tasks are lifecycle=done, do NOT
re-handle. Wave 9 closes the remaining CI-hardening carryover, kills the recurring ledger-close
off-by-one AT THE TOOL, and runs one fresh outbound-I/O audit pass. Six RUN verifiers (proofs with
pasted output) OVERTURNED two wish premises — the corrections are the load-bearing content below.
Builders branch from ORIGIN/main (local checkout diverged ~114 with unrelated omx commits — NEVER
build from it); origin/main tip at decide = `3cbbe26b`.

- **D45 — Wave 9 = FINISH + ONE-FRESH-AUDIT, 4 opus slices, all file-disjoint.** Three fronts +
  one opportunistic land: (1) land the sobelow reconcile carryover branch; (2) auto-stamp the
  merge-gate criterion at close so no future wave hand-patches the ledger; (3) one fresh outbound-I/O
  audit shipping the CDN sync-block fix + backlog; (3b) land the D35 audit-dispatch fix. All builders
  opus (Fable exhausted). No fresh scouts; the 12 domains stay closed.
- **D46 — Front 1 (sobelow, `task-felix-sobelow-baseline-reconcile`): LAND the existing branch
  `wave8-carryover/sobelow-reconcile-candidate` (b48fb6c1, off 607aea46 = ancestor of origin/main)
  WITH ONE PROVEN HARDENING — the digest's "clean land, no code" read is REFUTED by the on-pin CI
  proof.** On-pin CI (run 29274393147, OTP 27 / Elixir 1.18.1) proved the reconcile step (clear-skip
  THEN mark-skip-all → live 112-line baseline vs committed 84) and the fresh-finding guard both
  correct; version-guard did not trip; continue-on-error shielded the job. BUT the reconciled
  `.sobelow-skips` — a DOTFILE the script writes to `$ARTIFACT_DIR/.sobelow-skips` — is SILENTLY
  DROPPED from the human-review artifact by `upload-artifact@v4` (`include-hidden-files: false`
  logged verbatim); the artifact ships only `metadata.txt` + `sobelow-skips.diff`, so the human never
  gets the baseline to commit — defeating the slice's purpose. FIX = add `include-hidden-files: true`
  to the "Upload reconciled Sobelow baseline" step (security.yml:106-112) OR write the baseline to a
  non-dotfile name; the branch does NOT touch tracked `api/.sobelow-skips` (byte-safe) — keep it so.
  CLAIM-STATE CORRECTION (verify beats prose): the wish said this task is held by a LIVE
  cross-session claim; `bp task get` proves it RELEASED (worker=null, epoch 5, released_by
  worker-1-team424-author, lifecycle=open, in `bp task ready`). Builder claims by EXPLICIT ID
  (epoch 5→6), NEVER `bp task next`; does NOT rebuild the reconcile (the branch is the deliverable).
  Sobelow stays ADVISORY (continue-on-error) — never a merge-blocker.
- **D47 — Front 2 (ledger close auto-stamp, NEW `task-felix-close-merge-gate-autostamp`): fix Mode B
  ONLY, at a LEAD/merge-time seam, via an EXPLICIT criterion marker — never a text/index heuristic.**
  The recurring bug is TWO modes and the wish conflates them. Mode A: builders pass a 1-based
  `--criterion N` into the 0-based stamp tool → wrong criterion; in observed incidents the merge-gate
  went falsely met=TRUE (the OPPOSITE polarity from the wish's "left met=false") — Wave-7 log:568-572
  documents it independently. Mode B: the final LEAD-CLOSED criterion is intentionally left met=false
  at builder-close time (builders can't know a PR is merged) — this is the design toil the wish wants
  automated. Verify PROVED `bp task stamp` CANNOT touch a done task
  (`{:error, {:not_in_progress, "done"}}` → HTTP 409; the ledger is sealed by close) — so a
  post-merge external stamp is architecturally impossible; the ONLY working seam is close.ex's own
  `apply_close_update`. Verify ALSO proved the "last acceptance_criteria entry contains 'MERGE GATE'"
  convention is UNRELIABLE (only 14/34 Felix children carry it as the last-entry substring). DESIGN:
  add an explicit `"merge_gate": true` marker on the criterion entry (author-set at task creation);
  in `apply_close_update`, when `new_status` is terminal (done) AND a non-empty `landed` map is
  present (the LEAD's merge close, never a builder's pre-merge close — this is what prevents
  recreating Mode A) AND the marked criterion is still met=false and the caller's `criteria` payload
  did not already touch it, inject a synthetic `{index, met:true, evidence}` into the `criteria` list
  so it rides the SAME `merge_criteria` + rev-CAS write. Composed evidence = `worker_id` +
  `claim.epoch` + `landed.prs`/commit + `ts_iso`. Pure server-side, derived from data already flowing
  → ZERO OpenAPI drift, no bp CLI change (close-route survey confirmed `landed`/`criteria` already
  ride the generic passthrough and never surface in the OpenAPI requestBody). Mode-A hardening
  (expose the existing `internal.ex` criteria-text guard / add 0-based `--criterion` validation to
  REJECT a wrong-index stamp with `:criteria_mismatch`) is filed BACKLOG, not built this wave.
- **D48 — Front 3 (fresh audit — outbound-I/O boundary): the wish's SSO headline is REFUTED; ship
  the CDN sync-block fix instead (NEW `task-felix-cdn-sync-block-async`).** Verify REFUTED the
  "SSO unbounded-timeout availability scar": Req 0.5.17 / Finch 0.21.0 apply a bounded 15_000ms
  `receive_timeout` default (live probe errored at 15164ms, did NOT hang to 25s) — SSO omitting the
  option is a low-sev consistency nit (BACKLOG), not a hang. The crispest CONFIRMED finding is
  `Cdn.invalidate_http`: synchronous, single-attempt, inline in BOTH the media-upload pipeline
  (`media/processing.ex:38`) AND the external transcoder callback
  (`media_processing_controller.ex:25`, before `json(conn,…)`) — a slow/hung CDN purge stalls the
  upload/callback response for the full round-trip (a third-party-edge availability scar). Fail-before
  PROVEN (slow-CDN Bypass: `Cdn.publish` 916/1103ms vs 0-7ms noop control); async-safety DOUBLY
  confirmed (all 3 call sites discard the return value; the whole invalidate chain unconditionally
  returns `:ok`, carrying no signal any caller could branch on). FIX: async-ize the publish-path CDN
  purge (fire-and-forget or bounded background) on the TWO upload sites ONLY. The delete-path
  (`media.ex:398 Cdn.invalidate`) is owned by D36's after-commit deferral — do NOT double-handle it
  (avoid a collision on media.ex). Backlog seeded: SSO explicit-timeout consistency; dedicated
  auth/plugin Finch pool (auth+plugin outbound share Req's default pool with up-to-100-concurrent
  webhook/CDN delivery → cross-tenant/cross-subsystem contention the dedicated `Sync.Finch` pool was
  carved out to avoid).
- **D49 — Front 3b (D35 land, `task-felix-migration-ddl-audit-deadlock`): CHERRY-PICK 60966bdc onto
  origin/main (NOT merge the 40-behind branch).** Verify PROVED the pick is conflict-free (exit 0,
  4 files, config.exs 3-way auto-merged), green (5 tests 0 failures with the fix), and a real
  fail-before (flip `:audit_dispatch_async` true → `dispatch_audit_async` returns `{:ok, #PID}` async
  → 3 failures, the decisive `:ok` vs `{:ok,pid}` semantic). PR #2917 concern DISPELLED — the 40-commit
  gap touched NEITHER `dispatcher.ex` NOR `data_case.ex`; the audit test pins `async:false` so any
  DataCase default flip is moot. Task is RELEASED (worker=null, epoch 16, 2/4 met) — builder
  re-claims by EXPLICIT ID (epoch 16→17). Criterion 2 (N≥10 full-suite `--include flaky`, 0 40P01)
  may stay a `--miss` note if the full-suite grant is unavailable (the HOLD note on the task still
  stands); the merge gate (criterion 3) is lead-closed. Landing this clears the still-unmerged
  audit-dispatch 40P01 source that blocks any trustworthy `--include-flaky` sweep.
- **D50 — Guardrails (unchanged from D37/D44): all opus, branch from ORIGIN/main, main checkout
  stays on main, isolated worktrees, `CC=/usr/bin/clang`, borrow-warm `_build`.** The 4 slices are
  file-disjoint → dispatch in parallel (slice 1: `.github/workflows/security.yml` + the two
  `api/scripts/sobelow-*.sh` + `docs/ops/merge-gates.md`; slice 2: `tasks/close.ex` +
  `tasks/internal.ex` + `close_test.exs`; slice 3: `media/processing.ex` +
  `media_processing_controller.ex` + `media/delivery/cdn.ex` + a new cdn test; slice 4:
  `config/{config,test}.exs` + `webhooks/dispatcher.ex` + `audit_dispatch_test.exs`). The Decide
  phase COMMITS this charter before fan-out (builders see only committed state). Backlog seeded
  (published children of the epic): `task-felix-sso-explicit-timeout`,
  `task-felix-outbound-pool-isolation`, `task-felix-stamp-index-guard`.

### Wave 9 roadmap (4 opus slices, parallel — disjoint files)

1. **[P1, small] sobelow reconcile — LAND branch + artifact-payload hardening** —
   `task-felix-sobelow-baseline-reconcile` — opus. Land `wave8-carryover/sobelow-reconcile-candidate`
   (b48fb6c1) + add `include-hidden-files: true` (or non-dotfile name) so the reconciled baseline
   actually ships in the artifact. Files: `.github/workflows/security.yml`,
   `api/scripts/sobelow-baseline-reconcile.sh`, `api/scripts/sobelow-fresh-finding-guard.sh`,
   `docs/ops/merge-gates.md`. Gate: `cd api && CC=/usr/bin/clang mix sobelow --skip --exit Low`
   (advisory) + confirm the branch's `if:always()` steps + the upload step now names the baseline.
2. **[P1, medium] ledger close merge-gate auto-stamp (Mode B)** —
   `task-felix-close-merge-gate-autostamp` — opus. Files: `api/lib/barkpark/tasks/close.ex`,
   `api/lib/barkpark/tasks/internal.ex`, `api/test/barkpark/tasks/close_test.exs`. Gate:
   `cd api && CC=/usr/bin/clang mix test test/barkpark/tasks/close_test.exs`.
3. **[P1, medium] CDN publish-path async-ize (upload sites only)** —
   `task-felix-cdn-sync-block-async` — opus. Files: `api/lib/barkpark/media/processing.ex`,
   `api/lib/barkpark_web/controllers/v1/media_processing_controller.ex`,
   `api/lib/barkpark/media/delivery/cdn.ex`, `api/test/barkpark/media/cdn_sync_block_test.exs` (new).
   Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark/media/cdn_sync_block_test.exs`.
4. **[P2, small] D35 audit-dispatch land — cherry-pick 60966bdc** —
   `task-felix-migration-ddl-audit-deadlock` — opus. Files: `api/config/config.exs`,
   `api/config/test.exs`, `api/lib/barkpark/webhooks/dispatcher.ex`,
   `api/test/barkpark/webhooks/audit_dispatch_test.exs`. Gate:
   `cd api && CC=/usr/bin/clang mix test test/barkpark/webhooks/audit_dispatch_test.exs`.

Backlog seeded this wave (published children): `task-felix-sso-explicit-timeout` (SSO OIDC/Social
are the lone outbound modules leaving `receive_timeout` implicit — set an explicit ≤15s bound for
consistency/faster-failure on the login path); `task-felix-outbound-pool-isolation` (dedicated
auth/plugin Finch pool so logins/plugin calls don't queue behind a webhook/CDN delivery storm on the
shared default pool); `task-felix-stamp-index-guard` (kill Mode A at source — require/expose the
`internal.ex` criteria-text guard or add 0-based `--criterion` validation so a wrong-index stamp is
REJECTED with `:criteria_mismatch` instead of silently corrupting a neighbor criterion).

## Wave 10 Decisions (2026-07-13) — FINISH THE THREE W9 CHILDREN + ONE FRESH AUDIT (already-good)

Wave Paper: **`felix-pristine-wave-10-2026-07-13`** (guerrilla, style=article). Wave 9 LANDED and
MERGED all four opus slices — #3038 (sobelow reconcile), #3039 (close.ex Mode-B autostamp), #3040
(CDN publish-path async), #3041 (D35 audit-dispatch land) — plus charter b8afeaa3; origin/main tip
at decide = `2862108d`. The three D50-seeded children (`task-felix-sso-explicit-timeout`,
`task-felix-outbound-pool-isolation`, `task-felix-stamp-index-guard`) are OPEN + unclaimed. Twelve
surveys + SIX RUN verifiers (proofs with pasted output) OVERTURNED/REFINED three baked-in premises;
the corrections are the load-bearing content below. Builders branch from ORIGIN/main (the local
checkout is at parity NOW but is a SHARED main other sessions re-diverge — `git fetch && branch off
origin/main` at claim time). Fable exhausted — all builders opus.

- **D51 — Wave 10 = FINISH-THE-BACKLOG + ONE-FRESH-AUDIT, TWO opus build slices (not three) + an
  already-good audit verdict.** The three filed children collapse to two PRs because pool-isolation
  and sso-explicit-timeout are the SAME edit to the SAME SSO call sites (D52), and the fresh audit
  yields no crisp buildable finding (D55). No fresh scouts; the 12 domains stay closed; do NOT
  re-handle wave-9 landed work.
- **D52 — Slices A + B are MERGED into ONE keystone PR — `task-felix-outbound-pool-isolation`, which
  ALSO closes `task-felix-sso-explicit-timeout`.** Why (V2): both edit the identical 4 SSO call
  sites (`oidc/http.ex:20,29` + `social/http.ex:21,36`), and the pool routing has a HARD RUNTIME
  dependency on the pool existing — a separate sso-timeout PR branched off origin/main that passes
  `finch: Barkpark.Auth.Finch` would crash on the unstarted pool. Merging beats sequencing: the one
  PR defines the pool, routes all 5 modules to it, AND adds explicit `receive_timeout: 10_000` to
  the 2 SSO modules (Slice B's entire content). The LEAD closes BOTH children's merge gate on merge.
- **D53 — Slice A framing is DEFENSE-IN-DEPTH, not a login-starvation crash-fix — D48's flat
  "queue behind the storm on the shared default pool" framing is an OVERCLAIM (V2 refuted by
  probe).** Finch 0.21.0 partitions pools per `{scheme,host,port}` (probe: 3 hosts → 3 distinct pool
  PIDs; same host twice → same pool); a webhook/CDN storm to CUSTOMER/CDN hosts physically cannot
  consume the IdP host pool's 50 slots — different SHP keys share the Req.Finch INSTANCE, not the
  connection slots. Honest residual value: (a) an owned/tunable/observable connection budget for the
  auth/login path decoupled from Req.Finch's global default (mirrors Sync.Finch's own rationale);
  (b) bounds BEAM-global socket/FD/ephemeral-port/scheduler pressure under a real 100-concurrent
  storm (partial, real); (c) deterministically fixes the same-host edge (a self-hosted IdP behind
  the same reverse-proxy host as a webhook target WOULD share an SHP pool today). The PR MUST be
  framed as availability-hardening; "fixes active pool-exhaustion login starvation" is refuted.
- **D54 — Slice A boundary: exactly 5 modules IN, pool name `Barkpark.Auth.Finch` (free name),
  child-spec mirrors `Sync.Finch` (`application.ex:51`).** IN (add `finch: Barkpark.Auth.Finch`):
  `sso/oidc/http.ex`, `sso/social/http.ex`, `plugins/github/auth.ex`, `plugins/indx/auth.ex`,
  `plugins/onixedit/bokbasen/auth.ex` (note the bokbasen path nests under `onixedit/` — the digest's
  `plugins/*/auth.ex` glob MISSES it). OUT — correctly: `*/client.ex` (already ride a Req-auto
  md5-keyed dedicated pool via `connect_options` — adding `finch:` RAISES ArgumentError),
  `webhooks/dispatcher.ex` + `net/safe_outbound.ex` (the contention SOURCE, stays on default),
  `hibp`/`judge`/`titles`/`self_update`/`sync` (unrelated domain or already isolated). CRITICAL: Req
  RAISES if BOTH `:finch` and `:connect_options` are set — none of the 5 IN targets set
  `connect_options` today, and the SSO explicit timeout MUST be a top-level `receive_timeout:` (a
  plain Req option), NEVER `connect_options`, so the co-edit is collision-safe. Prove isolation by a
  child-spec/config assertion (mirror `application_child_specs_test.exs`) + assert each of the 5 call
  sites carries `finch: Barkpark.Auth.Finch`; no live-traffic test (no Finch test exists — greenfield).
- **D55 — Slice D (fresh audit — Oban worker retry-idempotency) is an ALREADY-GOOD verdict; NOTHING
  is built.** Why (V4 ratified, prior-art overrides the S10 rec): GenServer-blocking-in-handle_call,
  Ecto.Multi, PubSub/LiveView are ALL already swept + rejected in the domain papers. Oban is the
  only fresh ground and the honest verdict is 13–15/15 workers exemplary — every effectful worker
  carries `unique:` + `max_attempts`; the create-then-stamp crash window in `mirror_job`/
  `publish_worker` is a DOCUMENTED, accepted at-least-once residual. The one outlier
  (`pulse/sweep_worker` has no `unique:`) is PROVABLY idempotent (pure `Repo.delete_all(where
  inserted_at < cutoff)`, zero external effect) → any "assert `unique:` present" test is tidiness,
  not protection = vacuous green, REJECTED. The verdict is recorded in the wave Paper; the deferred
  findings are filed as backlog (D56). Forcing a build would violate improvement-only doctrine or
  ship vacuous green.
- **D56 — Slice C (`task-felix-stamp-index-guard`): the fix is SERVER-SIDE text-guard threading, NOT
  CLI range-validation (V3 CONFIRMED the in-range corruption reproduces on origin/main TODAY).** Why:
  `internal.ex` ALREADY rejects out-of-range indices (`:criteria_index_out_of_range`, tested at
  `stamp_test.exs:121`); the residual is an IN-RANGE wrong index (1-based-passed-into-0-based) that
  silently flips a NEIGHBOR criterion with no error — V3's probe stamped `criterion: 2` into a
  3-criterion task, flipped index 2, left index 1 untouched, returned `{:ok}` ("1 test, 0 failures").
  Pure CLI 0-based range-validation is VACUOUS here (the wrong index IS in range). FIX: thread an
  OPTIONAL criterion-TEXT through the stamp seam (`params.ex` → `tasks_controller.ex` →
  `Stamp.build_update` sets the `"criterion"` key) so `internal.ex`'s dormant `:criteria_mismatch`
  guard finally fires for stamp callers; and state the 0-based convention FORCEFULLY where builders
  learn it wrong (`onramp_cmd.go:335` has ZERO 0-based mention today; the manifest `plugins/tasks.ex`
  stamp verb; the MCP schema). Scope is opt-in-but-reachable, NOT mandatory-text (forcing text on
  every caller breaks #3039's index-only autostamp — wide blast radius). Fail-before = V3's in-range
  silent-corruption probe (non-vacuous; the existing suite only guards out-of-range). Collision with
  #3039 is MOOT (that PR touched only `close.ex`). No OpenAPI drift expected (stamp params ride the
  generic passthrough like close's `landed`/`criteria`) — capture the CI regen artifact if drift appears.
- **D57 — Backlog seeded this wave (published children of the epic):**
  `task-felix-auth-genserver-async-fetch` (the 3 plugin-auth GenServers block their OWN mailbox on
  synchronous outbound HTTP inside `handle_call` for up to 30s, serializing ALL of that plugin's
  callers behind one slow token fetch — a blast-radius availability scar DISTINCT from Slice A's
  cross-subsystem pool contention. The OTP-domain paper rejected the PATTERN's existence
  ("de-dup is intended"), but this targets the 30s WINDOW and preserves de-dup via a monitored-Task
  + waiters redesign — subtle OTP design best built when Fable is available; buildable fail-before =
  a slow token endpoint, assert a SECOND concurrent client op is blocked ~2s; P2/medium);
  `task-felix-sweep-worker-unique-guard` (defense-in-depth WATCH-ITEM only — no current failure
  mode, becomes real ONLY if `Pulse.sweep` ever gains an external effect; NO protective-test
  criterion — filing it as a bug would be vacuous green; P4);
  `task-felix-pusher-explicit-timeout` (`sync/pusher.ex`'s finch-isolated `Req.post` lacks an
  explicit `receive_timeout` — tiny consistency nit on an ALREADY-isolated pool, low-sev; P4).
- **D58 — Guardrails (unchanged from D50): all opus, branch from ORIGIN/main, main checkout stays
  on main, isolated worktrees, `CC=/usr/bin/clang`, borrow-warm `_build`.** V6-timed reality: a
  fresh worktree pays a ONE-TIME ~100s full recompile on first `mix test` (absolute-path manifest
  mismatch) — that is NOT gate breakage; the second run in the same worktree is incremental (~15s).
  The 2 build slices are file-disjoint (slice 1: `application.ex` + the 5 auth modules + new pool/
  timeout tests; slice 2: `tasks/stamp.ex` + `tasks/internal.ex` + `tasks_controller{.ex,/params.ex}`
  + `stamp_test.exs` + `plugins/tasks.ex` + `internal/cli/{onramp_cmd,mcp_tasks}.go`) → dispatch in
  parallel. Sobelow stays advisory.

### Wave 10 roadmap (2 opus slices, parallel — disjoint files)

1. **[P1, medium/large] Auth/login outbound Finch-pool isolation + SSO explicit timeout** —
   `task-felix-outbound-pool-isolation` (ALSO closes `task-felix-sso-explicit-timeout`) — opus.
   Files: `api/lib/barkpark/application.ex`, `api/lib/barkpark/sso/oidc/http.ex`,
   `api/lib/barkpark/sso/social/http.ex`, `api/lib/barkpark/plugins/github/auth.ex`,
   `api/lib/barkpark/plugins/indx/auth.ex`, `api/lib/barkpark/plugins/onixedit/bokbasen/auth.ex`,
   `api/test/barkpark/auth_finch_pool_test.exs` (new), `api/test/barkpark/sso/sso_http_timeout_test.exs`
   (new). Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark/auth_finch_pool_test.exs
   test/barkpark/sso/sso_http_timeout_test.exs test/barkpark/application_child_specs_test.exs`.
2. **[P2, medium] Stamp in-range wrong-index guard — server-side text-guard reachable + loud 0-based
   docs** — `task-felix-stamp-index-guard` — opus. Files: `api/lib/barkpark/tasks/stamp.ex`,
   `api/lib/barkpark/tasks/internal.ex`, `api/lib/barkpark_web/controllers/tasks_controller.ex`,
   `api/lib/barkpark_web/controllers/tasks_controller/params.ex`,
   `api/test/barkpark/tasks/stamp_test.exs`, `api/lib/barkpark/plugins/tasks.ex`,
   `internal/cli/onramp_cmd.go`, `internal/cli/mcp_tasks.go`. Gates: `cd api && CC=/usr/bin/clang mix
   test test/barkpark/tasks/stamp_test.exs` AND `CC=clang go build ./... && go vet ./internal/cli/...`.

Backlog seeded this wave (published children): `task-felix-auth-genserver-async-fetch`,
`task-felix-sweep-worker-unique-guard`, `task-felix-pusher-explicit-timeout` (see D57).

## Wave 11 Decisions (2026-07-16) — RELIABLY-GREEN ANCHOR

Wave Paper: **`felix-pristine-wave-2026-07-16`** (guerrilla, style=article). North star: main goes
RELIABLY green so every `.ex` PR merges on its own gate — no admin override. The wish framed three
lanes (fix the `deploy_runner_test.exs:581` flake; sweep sibling test-isolation weaknesses; ship any
Felix doctrine violation). A 6-assignment RUN-verify fleet collapsed all three to ONE ship slice.

- **D59 — This wave is the ANCHOR-ONLY wave: fix `deploy_runner_test.exs:581`; ONE ship slice.**
  Why: this is the flake that forces admin-merges on every `.ex` PR; verification settled its
  mechanism decisively, and the sibling-sweep + doctrine lanes both came back empty of any slice
  that clears the improvement-only bar. A one-slice wave that makes main reliably green IS the north
  star — no breadth theater.
- **D60 — Theory A (env-leak → `delete_env` + reset-singleton) is REFUTED and DROPPED.** Why:
  `config()` reads `Application.get_env(:barkpark, DeployRunner)` LIVE every call
  (`deploy_runner.ex:134`) and never enters GenServer state, so "reset the singleton" is dead weight;
  TWO independent CI runs at DIFFERENT seeds (584655 job 87451079266; 706849 job 87461107180) gave
  the IDENTICAL failure — proving seed/order independence, so there is no cross-file order dependence
  to inherit; and grep proves NO test leaks `node_rollback_command`/`:cd` for this key. The red is a
  CONSISTENT-Linux NON-HERMETIC failure: line-581's `put_cfg(enabled: true)` dispatches the SHIPPED
  default `{"bash", ["deploy/site-deploy-node.sh", "--rollback"]}` from `run_cd = Path.dirname(File.cwd!())`
  = repo root, where the real script EXISTS; on Linux (flock present) it logs
  `no live route for 'rt-default' (not_supported)` and NEVER echoes its own path, so
  `assert log contains "deploy/site-deploy-node.sh"` is structurally unsatisfiable. macOS passed by
  ACCIDENT (flock absent → bash's `flock: command not found` error is prefixed with the script path).
- **D61 — The fix is purely HERMETIC: run bash from a scriptless tmp cwd via `put_cfg(enabled: true,
  cd: scriptless_tmp)`, DEFAULT command untouched.** Why: it preserves the test's stated intent
  ("prove the SHIPPED default names the node script — argv, not env") while making bash
  deterministically print `bash: deploy/site-deploy-node.sh: No such file or directory` (path-prefixed)
  on EVERY host, and the real script never runs. Prototype PROVEN: single test 1→0 red-before under
  Linux-equiv fake-flock → green-after; full file 36/0 under Linux-equiv flock AND plain macOS;
  14-line diff, test file only. Also restores the file's own moduledoc contract (`:5-6` "Stub commands
  only, never the real deploy/site-deploy.sh"), which line-581 alone violates.
- **D62 — The sibling sweep (wish lane 2) collapses to ZERO ship slices.** Why: verification
  classified the read-then-merge trio — both siblings are BENIGN. `self_update/runner_test.exs`
  overrides the exact command key it asserts on in EVERY behavior test (no shipped-default is under
  test); `provisioner_test.exs` setup overrides all 3 Provisioner keys every test and Provisioner
  reads ONLY those 3 — zero default-reliance/injection surface. The genuine green-wash shape (partial
  cfg + assert-on-shipped-default) exists ONLY at `deploy_runner_test.exs:587` (the anchor). Improvement-only
  forbids hardening clean files.
- **D63 — The W3 doctrine candidate `task-felix-auth-genserver-async-fetch` is DROPPED for this
  wave (stays honest backlog).** Why: real OTP smell (sync HTTP in `handle_call(:token)` on
  github/indx/bokbasen Auth) but the named failure mode is overstated — every `token/0` caller needs
  the token, so async yields ~zero ops-latency win; the only real delta is control-message
  responsiveness during a slow fetch, which no caller depends on. W10 (#3063) JUST intentionally
  shaped these three files (dedicated `Barkpark.Auth.Finch` pool). No red-before proves the headline;
  under improvement-only this reads as churn. If ever taken, scope HONESTLY to ":invalidate stays
  responsive during a slow fetch" with a timing red-before — not "serializes all ops for 30s."
- **D64 — Ecto FK-abort, unsupervised-spawn, and sandbox-ownership candidates are PREMISE-NEGATIVE
  — DROPPED.** Why: no `Ecto.Multi` anywhere in `api/lib` (every `Repo.transaction` rolls back
  cleanly, `{:error, changeset}` propagates); every `Task`/`spawn`/`start_link` is supervised or a
  deliberately-linked/awaited task with a handled failure mode; the `$callers`-scoped sandbox drain
  (`DataCase.setup_sandbox/1`) is correct and centralized. No named failure mode survives — the
  DeployRunner flake is orthogonal (plain `ExUnit.Case`, no Repo).
- **D65 — Backlog seeded (real, off this wave).** Why: none has a provable CURRENT failure mode /
  red-before. `studio_chat_test.exs:588-596` + `chat_live_test.exs:2049-2054` nil-prior `on_exit`
  leak (DORMANT — `config/test.exs:169` baseline guarantees `prev` non-nil; defense-in-depth);
  `tenancy_delete_workspace_test.exs` `:media_cdn` unconditional `delete_env` (W7-fenced, functionally
  safe today — sole reader supplies matching defaults; post-fence-lift pattern alignment); suite
  determinism gap (no pinned seed, `MIX_TEST_PARTITION` dormant).
- **D66 — All-opus; anchor slice is opus.** Why: Fable exhausted; the fix is a 14-line diff with a
  proven red-before/green-after — no subtle design judgment remains to warrant Fable.
- **D67 — Disjoint from concurrent cloud-build W6/W7.** Why: verification confirmed ZERO file overlap
  — the anchor touches only `api/test/barkpark/sites/deploy_runner_test.exs`; nothing under
  `api/lib/barkpark/tenancy/**` or the W6 search read-path. The W7-fenced `tenancy_delete_workspace_test.exs`
  is proven NOT the leaker (zero `DeployRunner`/`node_command` refs) and stays off-limits regardless.

## Wave 13 Decisions (2026-07-21) — THE SEAL WAVE: delta-audit or prove-clean

Wave Paper: **`felix-pristine-wave-13-2026-07-21`** (guerrilla, style=article). The 12 founding
domains + Part XI + waves 4–12 are closed, and **Wave 12's CSP + SAML-SLO-nonce slice (PR #3545,
`4c4051308`) is MERGED and LIVE on origin/main** — the epic's `wave_status` was STALE. Main is GREEN
on the authoritative Test (Elixir 1.18.1 / OTP 27.0) gate. So the finish-set is tiny; the RISK is a
**seal by assertion**: **222 in-fence files under `api/lib/barkpark` changed on origin/main since the
2026-07-10 founding cutoff and were NEVER swept by felix** (epic_fleet/cycle_fleet — 17 brand-new
files, new content/tasks/search logic, new Oban workers, new plugin capability code). Wave 13 runs a
WIDE fresh audit over that delta under the named scar-classes, then dispatches only the HONEST yield.
13 survey scouts + a 6-assignment RUN-verify fleet (telemetry query counts, a live ArgumentError
stacktrace, `sobelow`/`mix test` output) proved the delta is largely already-swept-or-clean and yielded
**6 improvement-only code slices + 1 finish doc slice** — the count the survey honestly produced, NOT a
forced 8. The epic seals either way: the delta got a REAL look.

- **D77 — Wave 13 = the SEAL wave via delta-audit; the seal rests on a look, not an assertion.** Why:
  the RUN-verify pattern held (~2 baked premises overturned per wave) — the delta was real, not a fig
  leaf. The improvement-only doctrine forbids manufacturing vacuous-green churn to hit a quota, so the
  8-slice budget is a CEILING the survey FILLS with real findings; it filled to 6+1. Both rivals lose:
  a literal 8-slice fresh audit re-sweeps closed ground or builds the watch-items doctrine refused 5×;
  a 1–2-slice minimal finish seals by assertion over 222 un-audited files. The finish-set runs in
  parallel so the epic closes regardless of yield.
- **D78 — SIX round-1 code slices, all file-disjoint, all opus (Fable spend-capped), each
  mutation-proven fail-before.** (1) **pulse dashboard_live mount-gate** — the #2402 connected?-mount
  scar's unswept remainder (f27623fdf swept 5 LiveViews, MISSED pulse + github plugin LVs);
  load_rows/load_vitals/safe_storage run on the discarded dead render. NOT wave-12-deferred (the wave-12
  paper has 0 mentions). (2) **github ops_live mount-gate** — same scar, Health.snapshot's 5 probes
  unconditional. (3) **board_live field-visibility seal** — load_peek→fetch_peek_doc raw `Repo.one`
  hand-picks task-content fields, 0 Envelope calls, ungated mount; LATENT fail-open (no task field
  declares visibility TODAY) → fail-closed hardening routing each peek field through
  `Envelope.field_readable?` (mirror `tasks/query.ex` measure_field_readable?); fail-before CONSTRUCTS a
  private task-schema fixture. (4) **content/expand.ex N+1** — MEASURED (N=1→4, 6→19, 16→49;
  documents==N, schema==2N+1), MUTATION-proven (stub→0); batch via existing
  `Content.get_documents_by_ids/3` + memoize ref_schema like `load_schemas/3`; live on delta-touched
  `query_controller` ?expand=; refutes d06's 'no per-row loops'. (5) **indx/persistence.ex corrupt-skip**
  — `load_all/0` RAISES `ArgumentError` (`:maps.from_list([nil,…])`) on any corrupt `.term`, contradicting
  its own 'skipped (logged)' moduledoc; RUN-proven; aborts `Recovery.recover` for EVERY scope that boot.
  (6) **tasks/claim_fence.ex UUID guard** — `verify/2` interpolates raw `task_id` into a `:binary_id` PK
  after only `is_binary`, raising `Ecto.Query.CastError` in violation of its `{:ok}|{:error}` @spec; a
  reproducible UNIT red today (no live integration trigger — callers pass UUID-typed ids), a small
  defense-in-depth that makes the named contract-violation impossible.
- **D79 — Ruled NOT ripe (recorded, NOT built — no reproducible red-before; improvement-only refuses
  each).** `staleness_live.load_books` unbounded `Repo.all` (DOCUMENTED deliberate flat-posture console;
  bounding fails closed) and `tasks/board.ex.load_task_docs` unbounded (consumer already #2402-gated,
  defensive-only) → backlog `task-felix-w13-bounded-read-watch`. `cycle_fleet reconcile/1` per-row
  get_result (cold bounded admin path, redundant re-query, no 500) → `task-felix-w13-cyclefleet-reconcile-nplus1`.
  `bulldocs/event.ex` missing `foreign_key_constraint` (ids DB-resolved, no raw-input path reachable) →
  `task-felix-w13-bulldocs-event-fk-constraint`. Merged migration `20260719010000` (correlated-subquery
  content backfill + DDL in one txn — the 25-min-outage landmine class) is ALREADY MERGED → no in-fence
  fix; growth watch `task-felix-w13-cyclecorrection-migration-growth-watch`.
- **D80 — New ground proven CLEAN with evidence (the seal rests here, not on assertion).** epic_fleet/
  cycle_fleet (17 new files): every raw-input `:binary_id` query is `Ecto.UUID.cast`/`nullable_uuid`-guarded;
  hot paths batch via single LEFT JOIN; `plugins/capabilities.ex` + `tasks/schema.ex` are DB-free (0
  `Repo.`); zero Envelope surface. schema-v2 clean (`"source"` is the documented permissive v1-leaf
  catch-all; no new field type; no JSON schema in the delta adds private/readable_by). changeset/FK-abort
  discipline holds across all delta transaction sites (Repo.rollback everywhere a changeset writes).
  The error-emitter fork set (16 barkpark_web files still hand-rolling `%{error:{code,message}}`) is
  **out of fence** — console-hardening's lane; the stale query_controller/legacy_controller pair named in
  memory is already unified via FallbackController.
- **D81 — Finish-set (parallel with the build slices; closes the epic).** (a) CSP crit-4
  (`task-0fc9d55c4725ab92`, 3/4): the literal `mix sobelow --skip --exit Low green` is STRUCTURALLY
  UNSATISFIABLE — ~137 pre-existing unrelated Low findings (D41 baseline drift) keep exit=1 forever with
  0 Config.CSP. **Re-worded (this wave) to content-proof: PR #3545 merged-ancestor + 0 Config.CSP findings
  + Elixir Test green**; LEAD closes on that, not the exit code. (b) `task-felix-sobelow-gate-blocking-eval`:
  STAY-ADVISORY verdict (D75 flip precondition baseline→0 still at 137) — recorded via doc slice
  `task-felix-w13-sobelow-stay-advisory-verdict` (docs/ops/merge-gates.md). (c) The 5 vacuous-green
  watch-items (sweep-worker-unique, pusher-timeout, auth-genserver-async, runtime-env-integer,
  suite-seed) + 2 fenced (studio-chat-onexit, tenancy-media-cdn-onexit) hold their D57/D63/D65/D75
  verdicts unchanged on origin/main → REVIEW/lead retires them won't-build citing each verdict verbatim
  (tenancy-media fence inferentially lifted: no open tenancy PR, cloud-build children unclaimed — retire
  with note). (d) `gr-blk-studio-presence-perf-flake` was MIS-PARENTED under felix — **re-parented this
  wave to gui-remake (`task-47bc4168392dec17`)** via `bp task move`; it is a Studio presence-perf flake,
  not a felix finding.
- **D82 — Guardrails (unchanged from D76): all builders opus (Fable spend-capped — MODEL CONSTRAINT is
  hard), branch from ORIGIN/main (local checkout diverges), isolated worktrees, `CC=/usr/bin/clang`, `.ex`
  PRs WAIT for the Elixir Test gate.** FENCE this thread: `api/lib/barkpark` (CMS core) + `api/test` ONLY
  — strictly OFF `api/lib/barkpark_web/live/studio` (console-hardening), `tooling/grip/` (truth-grip),
  `scripts/pds-*` + `tenancy/workspace_bundle` (PDS crown), `cloud/`, and the standing chat-tui /
  structure fences. The 6 code slices are file-disjoint (pulse dashboard / github ops_live / tasks
  board_live / content expand / indx persistence / tasks claim_fence, each with its own test) + the doc
  slice (docs/ops/merge-gates.md) → all 7 dispatch in parallel, round 1.

### Wave 13 roadmap (7 slices, round 1, parallel — disjoint files)

1. **[P2] pulse dashboard mount-gate** — `task-felix-w13-pulse-dashboard-mount-gate` — opus. Files:
   `api/lib/barkpark/plugins/pulse/web/dashboard_live.ex` + its test. Gate:
   `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/pulse/dashboard_live_test.exs`.
2. **[P2] github ops_live mount-gate** — `task-felix-w13-github-opslive-mount-gate` — opus. Files:
   `api/lib/barkpark/plugins/github/web/ops_live.ex` + its test. Gate: `mix test .../github/web/ops_live_test.exs`.
3. **[P1] board_live field-visibility seal** — `task-felix-w13-boardlive-envelope-fieldvis-seal` — opus.
   Files: `api/lib/barkpark/plugins/tasks/web/board_live.ex` + its test. Gate: `mix test .../tasks/web/board_live_test.exs`.
4. **[P1] content/expand.ex N+1 batch** — `task-felix-w13-expand-nplus1-batch` — opus. Files:
   `api/lib/barkpark/content/expand.ex` + `api/test/barkpark/content/expand_test.exs`. Gate: `mix test .../content/expand_test.exs`.
5. **[P1] indx persistence corrupt-skip** — `task-felix-w13-indx-persistence-corrupt-skip` — opus. Files:
   `api/lib/barkpark/plugins/indx/persistence.ex` + its test. Gate: `mix test .../indx/persistence_test.exs`.
6. **[P3] claim_fence UUID guard** — `task-felix-w13-claimfence-uuid-guard` — opus. Files:
   `api/lib/barkpark/tasks/claim_fence.ex` + NEW `api/test/barkpark/tasks/claim_fence_test.exs`. Gate: `mix test .../tasks/claim_fence_test.exs`.
7. **[P2, doc] sobelow stay-advisory verdict** — `task-felix-w13-sobelow-stay-advisory-verdict` — opus.
   Files: `docs/ops/merge-gates.md`. Gate: `grep -i 'stay advisory' docs/ops/merge-gates.md` + `bash scripts/check-doc-budgets.sh`.

Backlog on the ledger after this wave (all published children of the epic): `task-felix-w13-bounded-read-watch`,
`task-felix-w13-cyclefleet-reconcile-nplus1`, `task-felix-w13-bulldocs-event-fk-constraint`,
`task-felix-w13-cyclecorrection-migration-growth-watch`. Finish-set handled outside build slices: CSP
crit-4 re-worded (lead closes), gr-blk re-parented out, 7 watch/fenced items to retire at review.

## Wave 14 Decisions (2026-07-22) — LEAST-SWEPT INPUT-BOUNDARY HUNT, HONEST COUNT

Wave Paper: **`felix-pristine-wave-14-2026-07-22`** (guerrilla, style=article). W13 was the SEAL wave;
the marquee crown proof is sealed and buildable work is THIN (a graph scan showed ZERO pre-filed
open+executable+unclaimed tasks). W14 is NOT a quota wave — it applies the epic's proven scar-classes
at the seams where UNTRUSTED / content-editor-controlled input first meets the LEAST-swept subsystems
(sheets, scim, media, sync, search-analytics, tickets, onixedit, quiz) and delivers an HONEST count.
15 survey scouts + a 7-assignment RUN-verify fleet (proofs with pasted `mix test` / `:zip` / `psql`
output) converged: **4 in-fence build slices**, 3 backlog, and **5 surfaces honestly CLEAN** (no
manufactured green). The pivotal premise — "can DataCase/ConnCase RUN against a live local Postgres?" —
was PROVEN YES (A3: ConnCase 26/26 + DataCase 4/4 green), so C2/C4/B2 are locally mutation-testable, not
proven-by-trace-only. Builders branch from ORIGIN/main (local checkout diverged with concurrent-cycle
charter commits — NEVER build from it). Note for builders: `mix.exs` lives at `api/` — run
`cd api && CC=/usr/bin/clang mix test test/...` (NOT `mix test api/test/...` from repo root → "Could not
find a Mix.Project").

- **D83 — W14 = LEAST-SWEPT INPUT-BOUNDARY HUNT, exactly 4 in-fence build slices — an HONEST count, not
  a quota.** Why: the improvement-only doctrine REFUSES vacuous green; every slice below names a concrete
  failure mode with a RUN-proven or concretely-runnable red-before. Width was cheap at survey (15 scouts,
  8 surfaces) and fed a sharp verify fleet; the narrow build is what survived RUN-proof. The 12 domains +
  Part XI + W13 delta stay closed; no fresh scouts.
- **D84 — C1 sheets xlsx zip-bomb (`task-felix-w14-xlsx-zipbomb-guard`): BUILD — the richest, fully
  OFFLINE, no-DB slice.** Why (A1 RUN-proof): `XlsxImport.parse_layout/1`'s `:zip.extract(binary,[:memory])`
  (xlsx_import.ex:365) full-inflates the ENTIRE archive into memory UPSTREAM of every cell/merge/grid cap —
  measured 400 MiB materialised from a 1.45 MiB archive; `to_content/1` returns `{:ok,_}` having inflated
  the bomb while cell_cap (50_000) never approaches. The import controller's 15 MB cap is on COMPRESSED
  on-disk size (its own moduledoc admits "xlsx decompression is unbounded") and does not bound inflate.
  Reachable on the `:ingest` (content-editor) tier, not admin. Fix = a pre-extract size ceiling using
  `:zip.list_dir/1` (exposes each member's UNCOMPRESSED size from the central directory WITHOUT inflating),
  the structural twin of the shipped vix `guard_dimensions/1` / `@default_max_decode_bytes 256*1024*1024`.
  PLACEMENT (A1 nuance, load-bearing): the guard must sit at the TOP of `to_content/1` BEFORE
  `open_package/1` — a guard only at parse_layout:365 misses a bomb in a member XlsxReader itself reads
  (huge `xl/sharedStrings.xml`/`styles.xml`), which open_package inflates first. opus (security + subtle
  placement covering BOTH inflate vectors).
- **D85 — C2 scim group-member UUID guard (`task-felix-w14-scim-member-uuid-guard`): BUILD, but severity
  REFRAMED 500→400 (do NOT title it "500").** Why (A2 RUN-proof): the SCIM group-member WRITE path is
  genuinely unguarded — POST/PATCH Groups bind a raw IdP-supplied member value into `set_member_role/3`'s
  `m.principal_id == ^user_id` (`:binary_id`) with NO `Repo.uuid_or_nil` guard, while the sibling
  `replace_group_members` (scim.ex:409) DOES guard — all three entrypoints RAISED `Ecto.Query.CastError` at
  scim.ex:480 against live Postgres. The #672 guard covers only the resource `:id` path, never the member
  write path — genuinely NEW, no prior art. SEVERITY: phoenix_ecto maps `Ecto.Query.CastError`→HTTP **400**
  app-wide (proven: `Plug.Exception.status(%Ecto.Query.CastError{})`=400; no `exclude_ecto_exceptions_from_plug`),
  so this is a SCIM-conformance/consistency defect (malformed member → generic 400 instead of the guarded
  path's clean no-op), NOT a 500 crash. Fix stays IN-FENCE: route member ids through `Repo.uuid_or_nil` in
  `add_group_member`/`remove_group_member`/`set_member_role` (scim.ex, mirror replace_group_members), folding
  non-UUID to a no-op. Mutation-proof asserts the raise→no-raise transition (ConnCase re-raises so the 400 is
  unobservable in-test), NOT a status change. META (wave-wide): the "binary_id CastError 500" scar-class
  title is inaccurate here — both `Ecto.CastError` and `Ecto.Query.CastError` are 400s in this app. fable.
- **D86 — C4 sheets session undo/redo distinct-user-key cap (`task-felix-w14-sheets-undo-key-cap`): BUILD,
  OFFLINE pure-fn (no DB).** Why (A5 RUN-proof via `mix run --no-start`): `Session.Ops.record_undo/3` caps
  depth-per-key at `@undo_depth 100` (ops.ex:703) but NEVER caps the NUMBER of distinct `user` keys — 500
  distinct client-supplied `"user"` strings grow `map_size(state.undo)` to exactly 500, unbounded. `"user"`
  is unauthenticated on the `:ingest` tier (identity rides the op; ops_controller moduledoc). The sibling
  `ReplayRing` (session/replay_ring.ex, `@cap 32`+TTL+evict-on-write) is the bounded-cache precedent undo/redo
  failed to follow. Fix = cap distinct-user-key count (mirror ReplayRing's bounded-cache) with LRU-style
  eviction of the least-recently-touched user's stacks in `push_stack`. Mutation-proof (plain `ExUnit.Case`,
  no DataCase): pushing N > cap distinct users leaves `map_size(state.undo) <= cap` and retains the most
  recent — red-before = grows to N. fable (bounded-cache pattern has a clear ReplayRing template).
- **D87 — B2 MediaFile changeset FK-constraint (`task-felix-w14-mediafile-fk-constraint`): PROMOTED from
  digest-backlog to a BUILD slice — the W13 FK-abort scar-class, sibling to
  `task-felix-w13-bulldocs-event-fk-constraint`.** Why: `MediaFile.changeset/2` (media_file.ex:27) casts
  `:workspace_id`/`:project_id`/`:dataset_id` — all real DB FKs — with ZERO `foreign_key_constraint`, so a
  bad FK ref raises a raw `Ecto.ConstraintError`/Postgrex crash (500) out of `Repo.insert` instead of a
  controlled `{:error, changeset}`. Named failure: a workspace/project deleted concurrently mid-upload (or
  the cross-instance blob-push route). The codebase already treats this class correctly elsewhere
  (`scim/token.ex`+`scim/group.ex` call `assoc_constraint`); MediaFile is the outlier. In-fence,
  collision-clear (A6: media_file.ex CLEAR — the only recent touch already merged/byte-identical),
  mutation-provable (red-before: insert with a fabricated `workspace_id` RAISES today; green-after: returns
  `{:error, cs}`). Digest deferred it on SEVERITY (server-resolved ids) — but severity is not the doctrine
  bar; named-failure + mutation-proof + scar-class-sweep are, and this clears all three. Ranked P3 to reflect
  the lower severity honestly; the builder RED-FIRSTs criterion 0, so if it is somehow already-guarded the
  slice reports clean rather than fabricating. fable (well-specified — mirror the scim assoc_constraint
  pattern; match the DB constraint names from the migrations).
- **D88 — C3 media `/media/:id/meta` field-vis leak is OUT OF FENCE → HIGH-PRI BACKLOG, build-ready, lead
  decides routing.** Why (A4 RUN-proof): `MediaController.show/2` (media_controller.ex:52) skips the
  `Access.allowed?` gate that `serve/2` (:64) and `serve_rendition/2` (:109) both call — an anonymous caller
  gets a private asset's filename/path/size (200) while the identical caller is refused the bytes (403). The
  W13 Board.snapshot field-vis class, genuinely new, no prior art. BUT the fix lives entirely in
  `api/lib/barkpark_web/controllers/media_controller.ex` — barkpark_web, OUT of the D82 fence
  (`api/lib/barkpark` + `api/test` ONLY), with NO in-fence core anchor (the Access module needs no change).
  Under charter law and the lead's restated fence, W14 does NOT unilaterally extend the fence for a single
  web-file mid-Decide; C3 is filed as `task-felix-w14-media-meta-fieldvis-leak` (P1, build-spec complete,
  run-proof attached) and the lead is notified to either extend the fence or route it to a web-layer wave.
  The defect is tracked and loud, not buried.
- **D89 — B1 search suggestions/correction unbounded Repo.all + B3 sync dead-letter: BACKLOG, with a
  CORRECTED rationale (the digest's collision-deferral reason is STALE).** Why: A6 REFUTED the digest's "keep
  B1 deferred because intelligence.ex is double-contended" — both prior contending branches already
  squash-merged (#3423/#3424); intelligence.ex is collision-clear NOW. B1 is genuine (suggestions/5's
  popular/nohits helpers + `count_distinct_correction_sessions` `Repo.all` with no SQL `limit:`, truncating
  only via `Enum.take` AFTER fetch, on ANONYMOUS routes with an attacker-controlled grouping key) — but it
  was NOT run-verified this wave AND is HARD to mutation-prove offline (the defect is memory-unbounded while
  OUTPUT is unchanged by the fix, so a fail-before needs query instrumentation, not an output assertion). New
  deferral reason: needs a verify pass to design a fail-before harness before it can be cut without vacuous
  green — filed `task-felix-w14-search-suggestions-unbounded` (P2). B3 (sync dead-letter transient/permanent
  misclassification) is self-documented in HANDOFF.md and the whole sync subsystem is dormant everywhere
  (BARKPARK_SYNC_ENABLED unset on every deploy target) — `task-felix-w14-sync-deadletter-classification`
  (P3), do NOT manufacture a reaper for dead infrastructure.
- **D90 — Five surfaces honestly CLEAN; two false leads confirmed; NO manufactured green.** Why: tickets
  external `/tickets/:id` (binary_id + field-vis + attachments all clean by design — doc_id is a `:string`
  column, both personas share one presenter, attachments stat-then-read bounded), scim resource-`:id`/auth
  (#672-guarded, org-scoped, whitelist renderers), sync (NOT Oban — supervised GenServers with write-then-
  advance), search/workers Oban (ratified idempotent D55/D75), onixedit ping_live + staleness_live (BOTH
  `connected?`/on_mount gated — VEIN 6 is a FALSE lead, refuting the brief's "last un-gated LiveViews"), and
  quiz (answer stripped via public_question, 15 tests, other-epic findings). tickets binary_id was also a
  false lead. These are honest zeros per the improvement-only mandate.
- **D91 — Guardrails: FENCE holds (`api/lib/barkpark` + `api/test` ONLY, D82); Fable-5 spend is BACK.**
  Model policy this wave (lead): `fable` is the DEFAULT builder; `opus` reserved for the one subtle-
  correctness/security slice → C1 (xlsx zip-bomb) is opus (security + BOTH-inflate-vector placement), C2/C4/B2
  are fable (well-specified — mirror an existing guard/pattern). Branch from ORIGIN/main; main checkout stays
  on main; isolated worktrees; `cd api && CC=/usr/bin/clang mix test <file>` (targeted, no DB boot, no prod
  compile); run `mix format` before push; `.ex/.exs` WAIT for the Elixir Test gate. The 4 slices are
  file-disjoint (C1: xlsx_import.ex; C2: scim.ex; C4: session/ops.ex; B2: media_file.ex) → all round 1,
  parallel. A6 caveat: RE-RUN the merge-base collision check immediately before dispatch (branches move).

### Wave 14 roadmap (4 slices, round 1, parallel — disjoint files)

1. **[P1, small] xlsx zip-bomb pre-extract size ceiling** — `task-felix-w14-xlsx-zipbomb-guard` — **opus**.
   Files: `api/lib/barkpark/plugins/sheets/xlsx_import.ex` + NEW
   `api/test/barkpark/plugins/sheets/xlsx_zipbomb_test.exs`. Gate:
   `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/sheets/xlsx_zipbomb_test.exs`.
2. **[P2, small] scim group-member UUID guard** — `task-felix-w14-scim-member-uuid-guard` — **fable**.
   Files: `api/lib/barkpark/scim.ex` + `api/test/barkpark_web/controllers/scim_groups_controller_test.exs`.
   Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark_web/controllers/scim_groups_controller_test.exs`.
3. **[P2, medium] sheets undo/redo distinct-user-key cap** — `task-felix-w14-sheets-undo-key-cap` — **fable**.
   Files: `api/lib/barkpark/plugins/sheets/session/ops.ex` + NEW
   `api/test/barkpark/plugins/sheets/session_undo_key_cap_test.exs`. Gate:
   `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/sheets/session_undo_key_cap_test.exs`.
4. **[P3, small] MediaFile changeset FK-constraint** — `task-felix-w14-mediafile-fk-constraint` — **fable**.
   Files: `api/lib/barkpark/media/storage/media_file.ex` + `api/test/barkpark/media/media_file_fk_test.exs`
   (new). Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark/media/media_file_fk_test.exs`.

Backlog on the ledger after this wave (published children of the epic): `task-felix-w14-media-meta-fieldvis-leak`
(P1, OUT-OF-FENCE build-ready, lead routing), `task-felix-w14-search-suggestions-unbounded` (P2, needs
fail-before harness design), `task-felix-w14-sync-deadletter-classification` (P3, dormant infra). Five
surfaces closed CLEAN with no slice (D90). Vein 6 (onixedit) + tickets binary_id retired as false leads.

## Wave 12 Decisions (2026-07-16) — EMPTY THE NAMED-FAILURE BACKLOG, HONESTLY

Wave Paper: **`felix-pristine-wave-12-2026-07-16`** (guerrilla, style=article). Wave 11 LANDED: the
deploy_runner anchor (`0b303bc59`, #3435) is MERGED on origin/main — main is green on that flake.
Epic `task-96a908af98698118` = 46 children. Wave 12 is a SHIP-THE-BACKLOG wave: convert the remaining
ripe named-failure children into merged, protective-test-backed fixes, and — with the same rigor —
RETIRE the ones that collapse under verification (a watch-item with no reproducible red-before is
vacuous green, not a slice). 13 survey scouts + a 6-assignment RUN-verify fleet (proofs with pasted
`sobelow`/`mix test` output) collapsed the tentative 3-slice set to **2 build slices** and OVERTURNED
the wish's central CSP mental model. Builders branch from ORIGIN/main (local checkout diverged with
unrelated authoring/omx charter commits — NEVER build from it).

- **D68 — Wave 12 = SHIP-THE-BACKLOG + RETIRE-THE-VACUOUS, exactly 2 build slices.** Why: the RUN-verify
  fleet (the epic's recurring "~2 premises overturned per wave" pattern held) collapsed the tentative
  {CSP, pulse, accounts-toctou} set — pulse trended verify-only (no reproducible red-before). No fresh
  audit: v6 read the last un-assigned corner (config/runtime.exs, 848 lines) and found it honestly
  clean. The 12 domains + Part XI stay closed.
- **D69 — CSP slice (`task-0fc9d55c4725ab92`): BUILD, but the direction's downstream-plug model is
  REFUTED — reshaped to inline-CSP-map-into-`put_secure_browser_headers`.** Why: v1 PROVED with live
  probes that Sobelow's `Config.CSP` check (`deps/sobelow/.../csp.ex:55-96`) is a purely syntactic
  per-pipeline AST check — it credits ONLY a CSP map passed inside the `:put_secure_browser_headers`
  plug call, NEVER a downstream plug (Way-A: adding a downstream `PaperReaderCsp` to a pipeline left its
  finding flagged; the already-CSP'd `shared_paper_browser` is flagged every run). So the direction's
  "mirror the PaperReaderCsp downstream plug" mental model is FALSE and the `.sobelow-skips` entries
  CANNOT be cleared by a downstream plug. Way-B: an inline map DID clear the finding — but `include_csp?`
  checks KEY PRESENCE only, never the value, so a permissive `'unsafe-inline'` or bare `default-src 'self'`
  map clears all 5 findings **vacuous-green** → REJECTED. The slice ships REAL per-surface `script-src`
  that blocks inline script (`refute policy =~ "'unsafe-inline'"` is the load-bearing test lock).
  Load-bearing justification = qualifier #2 (kills the 3×-paid rebaseline toil — `Finding.fingerprint`
  hashes the LINE NUMBER, so any router.ex line-shift re-fingerprints every Config.* finding; 5 git
  rebaseline-only commits efc02d635/d5db09e57/aefba0809/ada18782e/3d7e0ebe2) + qualifier #3
  (defense-in-depth on operator surfaces). The "named security failure" axis is WEAKER — no concrete
  un-backstopped XSS sink found; Studio/admin are operator-authenticated — so toil-removal is the spine.
- **D70 — CSP blast radius: ONE coherent slice (not split), nonce-thread root.html.heex.** Why: the 4
  root-layout browser pipelines (browser / scoped_browser / shared_studio_browser / shared_paper_browser)
  all share ONE `root.html.heex` via `put_root_layout {BarkparkWeb.Layouts, :root}` — a tightened
  `script-src` there is felt on ALL FOUR (public root, full Studio, doc-shared Studio, paper-shared
  reader). `root.html.heex` has 4 un-nonced inline `<script>` blocks (theme-boot, `BP_PAPER_EDITOR_NO_INJECT`,
  self-update poll, the liveSocket boot ~:5160) that a nonce-less `script-src` would DEAD-CLICK (broken
  liveSocket boot = studio-nav-bug class) — thread a per-request nonce onto each. Keep `cdn.jsdelivr.net`
  in `script-src` (mermaid); leave `style-src` UNtightened (inline `@font-face` + `style=` attrs; PaperReaderCsp
  omits style-src for this reason). `shared_paper_browser` uses an inline `# sobelow_skip ["Config.CSP"]`
  (PaperReaderCsp already overwrites its header downstream → a pipeline map there is a cosmetic double-set).
  Splitting into a second router.ex-touching slice was rejected — both would edit router.ex → self-collision.
- **D71 — SAML SLO is IN-SCOPE and cheap; the "esaml form rewrite" blocker is REFUTED (v4).** Why: esaml
  4.6.0 (`mix.lock:25`) emits a plain `<script>` block (`addEventListener('DOMContentLoaded',…)`, NOT an
  inline `onload=` attribute — the router.ex:104-106 comment is STALE; read the vendored source
  `esaml_binding.erl`, not the comment) and ALREADY supports a `script-src` nonce via `encode_http_post/4`.
  `saml.ex:189` calls the no-nonce arity-3 variant. Fix = switch `saml.ex:189` to `/4` with a per-request
  nonce + `saml_controller.ex` `slo/2` sets a matching `script-src 'nonce-…'` header on that response
  (the `:sso_browser` pipeline bypasses `root.html.heex`; SLO nonce plumbing is by-hand in the controller).
  No PR#3514 collision (v4: chat-tui W3 touches neither router.ex nor root.html.heex).
- **D72 — pulse (`task-felix-pulse-ratelimit-scope-isolation`): VERIFY-ONLY, CLOSED keep-serial.** Why:
  v2 RAN the pulse suite (34 tests, 0 failures). The `{:pulse,ip,channel}`/`{:pulse_read,ip,channel}` keys
  (pulse_controller.ex:113/134, the ONLY producers) do bypass the per-test `rate_limit_scope` (which lives
  only in the RateLimit plug, rate_limit.ex:88-91) — but it is DORMANT: all 3 pulse test files are
  `async:false` and engineer DISJOINT client IPs per test (documented at pulse_abuse_drill_test.exs:192-195).
  There is NO reproducible red-before without manufacturing churn (flip a pulse test to `async:true` +
  force a same-IP collision) → under charter line "a flake fix with no reproduction is vacuous-green and
  rejected" it fails all four qualifiers. Closed via the criterion's own documented-accepted (keep-serial)
  branch. The direction's ship-slice #2 was correctly collapsed by the survey.
- **D73 — accounts-toctou (`task-5f4c0d03c05cd10e`): BUILD (thin but honest).** Why: v3 PROVED the harden
  and RAN it green — raise `accounts_test.exs:250` `Task.await/1` to `Task.await(&1, :infinity)` (ExUnit's
  own 60s per-test timeout is the real backstop; no timeout override exists), then flip line 3 to
  `async: true`. Proof: 3 solo seeds (459749/973762/74610) 33 tests 0 failures each, AND the full
  `test/barkpark/` suite under real `max_cases=20` contention = 7410 tests 0 failures. Diff is exactly
  2 lines, TEST-ONLY — the prod CAS (`consume_recovery_code`, accounts.ex:703, atomic `array_remove` UPDATE
  gated by `hash=ANY(...)`) is UNTOUCHED. Value is completing the honest `async:true` label, NOT a speedup
  (D28 net-neutral; 1 of 80 already-async files). Do NOT write "55/55 full-dir async" — 30 async:false
  files remain in `test/barkpark`; this completes a prior scoped campaign's set only. DEDUP: the
  byte-identical draft twin `drafts.task-b50cd380be7f0dd5` was DISCARDED; the slice is filed against
  `task-5f4c0d03c05cd10e`.
- **D74 — Honest-ledger reconcile (NO build; done this wave).** Why: (a) 3 done children had a
  merged-but-unstamped MERGE-GATE criterion — restamped via `/v1/data/mutate` (`bp task stamp` rejects a
  done task, 409): `task-felix-phantom-media-atomicity` [3]→met (#2955/38c68c81f), `task-felix-roothtml-durable-sobelow-skip`
  [3]→met (#2956/1be597c4d), `task-felix-interop-resource-bound-sweep` [5]→met (#2954/841fc2845), each PR
  an ancestor of origin/main. (b) `task-a9adc82f820db065` crit[1]'s "HONEST MISS: never produced" evidence
  was factually STALE — the N=2000 wall-time+byte measurement ALREADY SHIPPED (commit 3d66c0ddc,
  `chat_transcript_window_test.exs:98-146`); v5 RAN it twice (full 4584-10354us/~1.91MB vs capped
  2156-3578us/478007B, ~4× byte / 2-3× wall-time). Corrected + stamped met:true. (c) `task-4bc654f703da9d4a`
  (the measurement task) closed verify-only done. This is ledger-only reconciliation — the chat-fenced
  test file was NOT edited.
- **D75 — Fresh-eyes last corner honestly clean (v6); backlog on the ledger.** Why: config/runtime.exs
  (848 lines) — zero `String.to_atom` on env (BARKPARK_UPSTREAM_CHANNEL is a match-based whitelist,
  :731), every required env raises a loud documented prod error, the 3 Oban workers added since D55
  (findability_posttest, playground_reaper, tag_distribution) sit at/above the D55 idempotency bar. The
  ONE sub-doctrine-bar inconsistency (~8 `String.to_integer(env)` sites raise a generic ArgumentError vs
  the graceful `Integer.parse`+`IO.warn`+default of BARKPARK_TASK_LEASE_TTL) is a LOUD boot crash on an
  operator-supplied malformed env — not attacker-reachable, no incident, no measured cost — filed as a
  watch-item (`task-felix-runtime-env-integer-graceful-parse`), NOT built (idiom uniformity the doctrine
  rejects). `task-felix-suite-seed-determinism` (no protective test possible — reproducibility already
  ships in ExUnit `--seed`) and `task-felix-sobelow-gate-blocking-eval` (flip precondition is baseline
  file:line entries → 0, sequenced AFTER the CSP slice) STAY honest backlog. Tier-3 watch-items
  (sweep-worker-unique, pusher-timeout, auth-genserver-async — the last DROPPED as churn by D63) confirmed
  vacuous-green, NO promotion.
- **D76 — Guardrails (unchanged from D58/D66): all builders opus (Fable exhausted), branch from
  ORIGIN/main, main checkout stays on main, isolated worktrees, `CC=/usr/bin/clang`, borrow-warm `_build`
  (copy `_build/test`, symlink `deps`).** HARD FENCES: strictly OFF chat_* / studio_chat / chat_live
  (chat-tui cycle), settings_live / structure (studio-structure-polish), content authoring-wall / paper-tags
  (verify-only sealed area), and the W7-fenced `tenancy_delete_workspace_test.exs` `:media_cdn`. `.ex` PRs
  WAIT for the Elixir Test gate (local flakes QueueTest `ready/1` + sandbox-ownership are NOT ours; gate
  locally). The 2 slices are file-disjoint (CSP: router.ex + root.html.heex + saml.ex + saml_controller.ex
  + a new CSP plug/helper + a new test; accounts: `accounts_test.exs` ONLY) → dispatch in parallel.

### Wave 12 roadmap (2 opus slices, parallel — disjoint files)

1. **[P1, large] Sobelow tailored per-surface CSP + SAML SLO nonce** — `task-0fc9d55c4725ab92` — opus.
   Files: `api/lib/barkpark_web/router.ex` (5 browser pipelines' `put_secure_browser_headers`),
   `api/lib/barkpark_web/layouts/root.html.heex` (nonce-thread 4 inline scripts),
   `api/lib/barkpark/sso/saml.ex` (:189 `/3`→`/4`), `api/lib/barkpark_web/controllers/saml_controller.ex`
   (SLO nonce header), a new CSP plug/helper + new plug/integration test, `api/.sobelow-skips` (remove the
   router.ex Config.CSP entries). Gate: `cd api && CC=/usr/bin/clang mix sobelow --skip --exit Low` exits 0
   with the router.ex Config.CSP baseline entries gone, AND the new CSP test green
   (`refute policy =~ "'unsafe-inline'"`, cdn.jsdelivr.net retained, per-surface nonce present, SLO
   auto-submits).
2. **[P3, small] accounts_test TOCTOU harden → async:true** — `task-5f4c0d03c05cd10e` — opus.
   Files: `api/test/barkpark/accounts_test.exs` ONLY (raise Task.await to :infinity, flip line 3
   async:true; prod accounts.ex UNTOUCHED). Gate: `cd api && CC=/usr/bin/clang mix test
   test/barkpark/accounts_test.exs` twice with different `--seed`, 0 failures each.

Backlog on the ledger after this wave: `task-felix-runtime-env-integer-graceful-parse` (NEW watch-item),
`task-felix-suite-seed-determinism` + `task-felix-sobelow-gate-blocking-eval` (verify-only, honest
backlog), `task-felix-sweep-worker-unique-guard` + `task-felix-pusher-explicit-timeout` +
`task-felix-auth-genserver-async-fetch` (Tier-3 vacuous-green watch-items). Closed this wave without a
build: pulse keep-serial, N=2000 measurement, + 4 ledger restamps.

## Wave 15 Decisions (2026-07-22) — ARM C: RECOVERY PATHS + UNBOUNDED AGGREGATES (Arm: C)

Wave Paper: **`felix-pristine-wave-15-2026-07-22`** (guerrilla, style=article). **Research-program
Arm C** (/papers/epic-cycle-research-program-abcde): NO survey fleet — the strategist read the code
alone and named the slate in one pass; ONE Sonnet premise-smoke (3/3 CONFIRMED, zero collisions —
exactly one open PR repo-wide, #2907, disjoint) + TWO opus RUN-verifiers (webhooks abort raise;
telemetry SQL-capture harness) were the only pre-build research. Wave 15 hunts the two live,
least-swept veins the wish named — webhooks recovery and search aggregates — plus one thin-but-honest
self_update budget fix, and REFUSES the rest with reasons (D97). 3 slices, all round-1, file-disjoint.

- **D92 — Arm C protocol held: the smoke + 2 run-verifiers sufficed; every slice is RUN-proven, the
  honest skips stand on the strategist's solo read.** Why: the smoke confirmed all three candidate
  sites verbatim on origin/main (catch-all last clause + unguarded reduce + unordered/unbounded
  stuck_candidates; four group_by+Repo.all no-LIMIT helpers + Repo.all+length count on anonymous
  routes; 4×10s HTTP budget vs 30s call timeout), and the verifiers supplied the two proofs Decide
  could not cut without: the actual raise/starvation run and the actual telemetry SQL capture. The
  "webhooks lane is HOT" attack COOLED (the #5556-era class fix was NOT in flight — its own moduledoc
  documents the open class in three comments). Skips recorded as absences in the wave Paper, not
  oversights — per the declared Arm-C risk posture.
- **D93 — Slice A (P1, opus): close the webhooks recovery poison-row batch-abort CLASS
  (`task-felix-w15-webhooks-recovery-poison-class`).** Why: third recurrence of a twice-bitten class —
  chat_blocked clause, then the #5556 audit clause each closed ONE row-kind and left the class open
  (the module's own moduledoc says so). RUN-PROVEN (V1): a NULL-event_id document-kind delivery makes
  PayloadRebuild's catch-all raise `ArgumentError "cannot perform Ecto.Repo.get/2 because the given
  value is nil"` (the `with/else nil` arm can NEVER catch it — Repo.get raises, not returns), and one
  such poison row aborts StuckDeliverySweeper.sweep/1's unguarded reduce so a later recoverable row
  starves FOREVER (probe: status+updated_at byte-identical, 0 HTTP calls) — every cron pass, forever.
  Fix (three prongs, closes the class not the row): (1) guard the catch-all on
  `is_integer(delivery.event_id)` + a terminal fallback clause returning `:gone` with a loud
  Logger.warning naming delivery id + source_kind; (2) per-row try/rescue inside the sweep reduce
  (count the row skipped, log, continue); (3) `stuck_candidates` ordered oldest-first
  (`order_by: [asc: :updated_at]`) + batch-bounded (limit, default 500). LOAD-BEARING verifier facts:
  message assertions use the `Ecto.Repo.get/2` wording (NOT the moduledoc's "Barkpark.Repo.get/2");
  NO existing test expects the raise (all NULL-event_id tests assert the {:ok}/:gone path — the guard
  flips nothing); retry_worker.ex was READ — one Oban job per delivery, no reduce, no cross-row
  starvation → fence is payload_rebuild.ex + stuck_delivery_sweeper.ex ONLY, RetryWorker is fixed
  transitively (today a poison retry job wastes 3 Oban attempts).
- **D94 — Slice B (P2, fable): PROMOTE `task-felix-w14-search-suggestions-unbounded` — the D89
  deferral is OVERTURNED because the fail-before harness it demanded is now RUN-PROVEN.** Why: V2
  built and RAN the telemetry SQL-capture harness under the mix-test Ecto sandbox: Barkpark.Repo has
  NO custom telemetry_prefix, so `[:barkpark, :repo, :query]` fires with verbatim SQL in
  `metadata.query` — the probe captured all four popular/nohits GROUP-BY aggregates (none carries a
  SQL LIMIT; truncation is caller-side `Enum.sort_by |> Enum.take` AFTER `Repo.all`) and the
  correction count's `SELECT DISTINCT session_key` (Repo.all+length, no SQL COUNT), on queries
  grouped by attacker-mintable `query_normalized` reachable via ANONYMOUS
  GET /suggestions + POST /correction (router pipe `[:api, :api_grant_read]`). Fix: SQL-side
  `order_by` (desc count/sum) + LIMIT on each of the four helpers with a GENEROUS per-source cap
  (default 500, `Application.get_env`-overridable inline — NO config.exs edit, collision
  minimization) so crystal+event merge semantics hold at normal cardinality (output limit is ≤8);
  correction count via a SQL COUNT DISTINCT (`select: count(e.session_key, :distinct)`). Harness
  rules: `async: false` (process-global :telemetry handler table); isolate the four aggregates by
  filtering captured SQL on `GROUP BY` + table name (recent_queries' non-grouped SELECT is
  legitimately LIMIT'd and must be excluded); assert output parity below the cap; state the
  cap-straddle truncation edge in the PR. Verifier probe files are UNCOMMITTED throwaways — the
  builder re-derives the harness from these facts.
- **D95 — Slice C (P4, opus, thin-but-honest — BUILD, per the D73 precedent, not D63 churn): fix the
  self_update :check_now budget arithmetic (`task-felix-w15-selfupdate-checknow-budget`).** Why: the
  module's own comment names the failure ("a merely-slow upstream masquerades as :unknown while the
  fresh result is thrown away") and the smoke proved it now REACHABLE in fork mode: checker.run_check
  grew to FOUR sequential 10s-budget requests (latest_release(repo) + fork_advice→latest_release
  (canonical) + digest + release_notes, all through the single `request/1` helper with
  `@receive_timeout 10_000`) while `call_timeout(:check_now)` stayed 30_000 — worst case 40s > 30s,
  and the stale comment still says "two 10s-budget requests". This is a NAMED reachable failure with
  a mutation-provable fix, not idiom churn. Fix: derive — expose the worst-case sequential HTTP
  budget from ONE source of truth (e.g. `Checker.worst_case_http_budget_ms/0` computed from the
  client's receive_timeout × the request count), set `call_timeout(:check_now)` = budget + margin,
  correct the comment. Protective test asserts the relationship (RED with the budget exposed while
  call_timeout stays 30_000; GREEN after) — no 40s sleep-stub theater.
- **D96 — Builder logistics: branch from ORIGIN/main, isolated worktrees, `CC=/usr/bin/clang`,
  targeted `mix test` only; worktrees have NO deps/_build — `mix deps.get` + first full compile is a
  required setup step (both verifiers paid it), NOT a defect.** `.ex` PRs wait the CI Elixir Test
  gate; re-check open PRs at dispatch (webhooks was hot yesterday — #5556 merged; today one open PR,
  disjoint). Slice A ordering note: the fail-before starvation assertion must not depend on unordered
  SELECT ordering — assert the raise + at-least-one-row-untouched pre-fix, exact %{swept: 1,
  skipped: 1} post-fix (the ordered candidates make it deterministic). Models: A/C opus
  (well-specified), B fable (SQL-shape change under merge-semantics + harness subtlety).
- **D97 — Honest skips, each with its reason (recorded, not oversights): sync/** (dormant infra, D89
  holds — `task-felix-w14-sync-deadletter-classification` stays backlog); **bulldocs ingest core**
  (fail-soft + capped at its reachable seams); **schema-v2 validation** (admin-gated Regex.compile,
  no incident); **dispatcher retry math** (verified ALREADY-GOOD: usec fence precision end-to-end,
  Retry-After clamped); **dispatch_async/5 legacy sleep path** (caller-less = tidiness);
  **self_update/runner** (W7-bounded). The wave is honest at 2 slices if C falls at review. No new
  backlog discovered — exploration surfaced nothing real beyond the slate and these refusals.

### Wave 15 roadmap (3 slices, round 1, parallel — disjoint files)

1. **[P1, medium] webhooks recovery poison-row class fix** —
   `task-felix-w15-webhooks-recovery-poison-class` — opus. Files:
   `api/lib/barkpark/webhooks/payload_rebuild.ex`, `api/lib/barkpark/webhooks/stuck_delivery_sweeper.ex`,
   `api/test/barkpark/webhooks/stuck_delivery_sweeper_test.exs`,
   `api/test/barkpark/webhooks/payload_rebuild_audit_test.exs`. Gate: `cd api && CC=/usr/bin/clang
   mix test test/barkpark/webhooks/stuck_delivery_sweeper_test.exs
   test/barkpark/webhooks/payload_rebuild_audit_test.exs test/barkpark/webhooks/chat_blocked_delivery_test.exs`.
2. **[P2, medium] search suggestions/correction SQL bounds (promoted W14 backlog)** —
   `task-felix-w14-search-suggestions-unbounded` — fable. Files:
   `api/lib/barkpark/search/intelligence.ex`,
   `api/test/barkpark/search/intelligence_suggestions_bounds_test.exs` (new). Gate: `cd api &&
   CC=/usr/bin/clang mix test test/barkpark/search/intelligence_suggestions_bounds_test.exs
   test/barkpark/search/intelligence_test.exs`.
3. **[P4, small] self_update :check_now budget arithmetic** —
   `task-felix-w15-selfupdate-checknow-budget` — opus. Files: `api/lib/barkpark/self_update.ex`,
   `api/lib/barkpark/self_update/checker.ex`, `api/test/barkpark/self_update/checker_test.exs`.
   Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark/self_update/checker_test.exs`.

## Wave 17 Decisions (2026-07-22) — ARM E (E2): FK-ABORT SCAR-CLASS CENSUS COMPLETE + ONE REACHABLE SIBLING (Arm: E, config E2)

Research-program **Arm E / config E2** (paper `/papers/epic-cycle-research-program-abcde`; wave story
`felix-pristine-wave-17-2026-07-22`). E2 = E1's proven lean profile (straight-to-build + ONE premise-smoke)
PLUS a **dual-reviewer-intersection** merge gate. HYPOTHESIS (test + report): *inter-reviewer AGREEMENT
predicts escape-rate better than any pre-build signal — where two independent reviewers disagree on a slice
is exactly where escapes hide.* KILL SIGNAL: if the two reviewers agree on every slice AND reviewer-2 finds
nothing reviewer-1 missed, reviewer-2 is pure cost and E2 dies. The WORK finishes the FK-abort scar-class
census E1 seeded (`task-felix-w16-fk-abort-class-census-remainder`). All verdicts derived LIVE off
origin/main (`b0f1dcc19`) — the local checkout is 25 behind and shows already-fixed sites as un-constrained.

- **D98 — CENSUS COMPLETE on the 5 declared corners: ALL REFUTE (0 slices FROM the assigned corners).**
  (1) **sync/** — no changeset path at all (`Repo.insert_all` raw-map upserts, nothing to attach
  `foreign_key_constraint` to) AND dormant (`BARKPARK_SYNC_ENABLED` unset on every deploy target, zero
  routes, no Oban queue). (2) **Oban worker changesets** — all delegate to the generic content path, or
  their own schema is already-constrained (ProjectorWorker→`Content.Edge` has both FK constraints), or do
  no FK-bearing insert (sweep/export/retry). (3) **remaining plugin schemas** — exactly 4 `use Ecto.Schema`
  under `plugins/`: `bulldocs/event` (W16-fixed), `github/conflict` (no real `references()` FK — `doc_id`
  is plain `:text`), `settings_audit`/`settings_record` (plain string cols). (4) **media-beyond-meta** —
  `MediaFile` (W14-fixed) is the sole media schema; `search_intel_*` tables have no FK columns. (5)
  **schema-v2 field internals** — composite/arrayOf/localizedText have NO backing Ecto schema; codelists
  `Value`/`Translation` MATCH the shape (real CASCADE FKs, no constraint) but FAIL reachability — sole
  writer `Codelists.register/3` is boot/seed/admin-only, zero router `codelist` entries (cite the **W16
  PAPER**, not "D95" — the charter has no Wave-16 D-block and D92–D97 collide with Wave 15; the phantom-
  citation trap). Celebrated: the class is census-complete for these five corners.

- **D99 — CORRECTED FILTER (overrides the handed brief; load-bearing).** "CASCADE/SET NULL is NOT this
  class" is FACTUALLY WRONG — both W16 fixes (Event, SchemaDefinition) are CASCADE (`delete_all`) FKs and
  were built anyway. A Postgres FK raises on INSERT against a missing/concurrently-deleted parent
  regardless of `on_delete` (which only governs parent-deletion, not child-insert). The ONLY legitimate
  exclusion is "no real `references()` FK at all" (e.g. `documents.owner_id` is plain `:binary_id`, no
  `references` — correctly excluded; `nilify_all` scope FKs are still this class).

- **D100 — Content.Revision = REFUTE (child-of-a-child; clean reachability refute, NOT refute-on-fixability).**
  `revision.ex` casts `document_id/workspace_id/project_id/dataset_id` (real `nilify_all` FKs), ZERO
  `foreign_key_constraint` — SHAPE matches. But every one of the 3 inserters fails
  reachability-with-a-bad-scope: `broadcast.save_revision` (non-bang, non-admin) copies scope from a live
  in-transaction Document whose own scope FKs guarantee + row-lock live parents → NOT stale-able;
  `compactor.apply_compaction` is BANG + Oban-cron system (double-refute); `cycle_fleet.insert_candidate_revision`
  loads its Document `FOR UPDATE` (scope pinned) + fleet/system path. Buildable intersection
  {non-admin ∧ stale-able ∧ non-bang} = EMPTY. Even after D101's Document fix, the online path aborts at
  Document's FK BEFORE reaching Revision — Revision stays refute.

- **D101 — BUILD (the ONE reachable slice): Document.changeset FK-constraint** (`task-felix-w17-document-fk-constraint`,
  opus, round 1). Verification surfaced the OUT-OF-CORNER sibling of the three merged fixes:
  `content/document.ex` casts `workspace_id/project_id/dataset_id` (real `nilify_all` FKs, migrations
  20260527110100 + 20260527131000, default-named `documents_<col>_fkey`) with ZERO `foreign_key_constraint`.
  Reached NON-ADMIN via `POST /v1/data/mutate/:dataset` (MutateController, `:require_write`) and
  `POST /api/documents/:type` (LegacyController, `:require_write`) → `Content.Writer.upsert_document`/`create_document`
  → `Document.changeset` → **NON-BANG `Repo.insert()`** (writer.ex:205/611). On a concurrently-deleted scope
  (TOCTOU; D87 reachability doctrine — a DB-resolved id gone stale, not raw input) it raises raw
  `Ecto.ConstraintError` (500) instead of `{:error, cs}`. This is the FOURTH sibling of the exact
  scope-FK family fixed for Event/SchemaDefinition/MediaFile — fixing it FINISHES the family and closes the
  online-path vulnerability that makes Revision unreachable. **SCOPE RULING:** out of the 5 declared corners
  but squarely the class and the census's own purpose ("FK-abort census-complete on origin/main"); leaving
  it unfixed is a census-with-a-hole. It is NOT Rival-B (a genuine reachable 500, not shape-only
  defense-in-depth). **FENCE:** touches ONLY `api/lib/barkpark/content/document.ex` (3 bare
  `foreign_key_constraint` calls appended to `changeset/2`) + NEW `api/test/barkpark/content/document_fk_test.exs`
  — `writer.ex`/lifecycle/related are read-only traced, UNTOUCHED; no open PR touches document.ex.

- **D102 — webhooks/delivery.ex = REFUTE on reachability; NO slice, NO backlog.** Shape matches (casts
  `endpoint_id/event_id`, real `delete_all` FKs, `unique_constraint` only, non-bang `claim_delivery`
  insert) BUT the insert runs in a DETACHED fire-and-forget Task (`Dispatcher.fan_out` →
  `Task.Supervisor.start_child` + `async_stream_nolink`): a stale-ref `ConstraintError` crashes a background
  delivery task and is logged — NEVER a user-facing 500, and the doctrine green is ALSO unreachable
  (`deliver/3`'s `{:error,cs}` is discarded by `Stream.run`). Pure internal-robustness with no reachable 500
  → improvement-only doctrine REJECTS (the codelists lesson). Recorded as a census refute, not sliced.

- **D103 — E2 is SCORABLE, not merely inconclusive.** The one build slice (Document.changeset) gives the
  dual-reviewer INTERSECTION a real escape-rate test; the two borderline REFUTE verdicts (Revision D100,
  delivery.ex D102) are the disagreement-prone reachability calls both reviewers ALSO evaluate — precisely
  the W13(D79 refuse)→W16(D87 override, build) flip locus. Reviewer-1 = the wave's rank-and-fix
  (mutation-re-prove: strip constraint → raw `ConstraintError` 500, restore → `{:error,cs}`). Reviewer-2 =
  LEAD-dispatched, independent, BLIND to reviewer-1, re-derives the reachability premise + re-runs the
  mutation from scratch. MERGE = intersection of both above-bar sets. Kill-check honored: if both agree
  everywhere AND reviewer-2 finds nothing new, reviewer-2 is pure cost — report honestly.

- **D104 — BACKLOG (out of felix's corners, a separate sweep): the ~85 remaining `belongs_to` schemas
  repo-wide** (auth/tenancy/sso/cloud/mutation_event) were NOT migration-crosschecked for the FK-abort
  class — a genuine coverage gap outside the 5 corners and the barkpark_web/core-auth fence. Filed as
  `task-felix-w17-belongs-to-crosscheck-backlog` (P3). Note: `mutation_event` insert is BANG (`save_event`)
  → refute-on-fixability if surveyed.

## Wave 18 Decisions (2026-07-23) — ARM E (E4): FABLE-ARCHITECTED + FABLE-GRADED, FINISH THE REAL BACKLOG (Arm: E, config E4)

Research-program **Arm E / config E4** (paper `/papers/epic-cycle-research-program-abcde`; wave story
`felix-pristine-wave-18-2026-07-23`). E4 = Fable on the two judgment phases (architecting + grading),
graduated LEAN base (survey floor 1, straight-to-build + E1 premise-smoke, single reviewer except at
flip-risk), Fable REPLACING stages rather than adding them. HYPOTHESIS: same premise-failure +
72h-escape rate as the Opus-architected felix arms (C/E1/E2) at LOWER total tokens. NOTE ON NUMBERING:
W17's D98–D104 were stranded on an unpushed local-main commit (`46fb0d67e`) — their text is RECOVERED
verbatim into this pushed charter above; W18 numbers from D105.

- **D105 — GHOST W18 SUPERSEDED (wording corrected by verify).** The paper
  `felix-pristine-wave-18-2026-07-22` EXISTS (published, 21 blocks, reached "14 Sonnet surveyors
  dispatched") — the earlier "does not exist" claim was wrong. But it is an ABANDONED ATTEMPT with
  ZERO task artifacts (no w18 children on the epic, no claims, no wave log) — nothing to unwind.
  THIS wave (paper `felix-pristine-wave-18-2026-07-23`) is the real W18. Its stamped plan (full
  belongs_to breadth sweep, 14 surveyors) is dead twice over: the ~85-site premise was ~3x stale, and
  breadth-sweep surveying is exactly the reading-breadth spend E4 bets against.

- **D106 — CENSUS METHOD CORRECTION (load-bearing; closes D104's backlog).** A literal grep for
  `foreign_key_constraint` is NOT the shape test: `assoc_constraint/2` IS a `:foreign_key` constraint
  (ecto `changeset.ex` → `add_constraint(changeset, :foreign_key, …)`) keyed by association name, so
  the grep missed it everywhere. Bang-ness is ALSO a red herring: `constraints_to_errors/3` raises
  `Ecto.ConstraintError` for any UNDECLARED constraint violation before the bang/non-bang split — what
  decides crash-vs-`{:error, cs}` is solely whether the translator is declared. Corrected census of
  the D104 surface (29 belongs_to-casting files: 11 api-side + 18 cloud — `cloud/` is a SEPARATE
  Elixir app, `mutation_event` is ONE file): 7/8 api shape-matches and 16/18 cloud shape-matches are
  ALREADY GUARDED via `assoc_constraint`; `mutation_event` refuted (bang insert via `change/2`);
  `workspace.ex` + `usage/sample.ex` already safe. TWO genuine instances remain:
  `auth/api_token.ex` (workspace_id + owner_user_id cast, zero translator, 8 non-bang HTTP-reachable
  sites, softest route POST /v1/auth/tokens `require_user`; trigger = deleted-default-workspace race,
  not injection — narrow but real 500) and cloud `device_auth/request.ex` (belongs_to :user, no
  translator; LATENT — sole live write path `approve/2` is `Repo.update_all`, which bypasses
  changesets, and always writes the caller's own authed id). Two verifiers derived the
  assoc_constraint fact INDEPENDENTLY (api via vendored Ecto source; cloud via per-file grep) — the
  dual-check at the census-refute flip-risk seam (W17 Revision lesson) happened at VERIFY, pre-build.
  Fence ruling: ONE builder, not two — the "17 unguarded cloud files" evaporated under the corrected
  method. Census task `task-felix-w17-belongs-to-crosscheck-backlog` CLOSED 3/3 with this evidence.

- **D107 — BUILD slice A: FK-abort family close** (`task-felix-w18-fkabort-family-close`, opus,
  round 1, small). Append `foreign_key_constraint(:workspace_id)` + `(:owner_user_id)` to
  `ApiToken.changeset/2` (matching the merged Document/Event/SchemaDefinition/MediaFile family) and
  `assoc_constraint(:user)` to cloud `DeviceAuth.Request.changeset/2` (cloud house style).
  Mutation-proven red-then-green both sides; extend the EXISTING test files. Gates dry-run at Decide:
  cloud `device_auth_test.exs` 33/0 (after `mix deps.get`), api harness proven by claim_fence 4/0.

- **D108 — S2 SETTLED: insert_all-with-FK census complete; BUILD slice B = two studio_chat fixes**
  (`task-b55360f458ff6a45` repurposed as the slice task — census half stamped by evidence, build half
  + appended merge-gate criterion remain). Census: sync/ five REFUTED (W17: no changeset + dormant);
  idempotency/preview_token/pulse OUT OF CLASS (no `references()` FK column); cycle_fleet ×2 +
  runtime_usage correct-by-construction (the authority join FOR SHARE/FOR UPDATE locks the exact
  referenced rows — a cascade delete takes the same row locks, so parent deletes serialize behind the
  txn); their missing regression test filed as `task-felix-w18-authority-lock-mutation-proof` (P3).
  The ONE open site: `runtime_telemetry.ex persist_once` — Receipt `insert_all` races
  `delete_session`; delete-commits-first → FK raise out of `Repo.transaction` → Recorder crash
  (`on_conflict: :nothing` does NOT suppress FK violations); fix = locked session pre-check +
  `Repo.rollback(:session_not_found)`, mirroring `project_observation`'s existing guard.
  SHARPER CO-FINDING promoted into the same slice: `StudioChat.delete_session/2` is a bare
  `Repo.delete` — deleting any session with runtime-attempt/usage-receipt children raises an
  unhandled RESTRICT `foreign_key_violation` and CRASHES the admin chat LiveView (user-facing, not
  self-healing); fix = changeset-based delete with the RESTRICT constraints declared + a flash in
  `chat_live.ex`. Prior-art note: the 2026-07-12 transactions audit (task-290094…) predates all four
  tables (2026-07-15 migrations) — it never ruled on them. Baseline dry-run: 102/0.

- **D109 — S3 SEAL RULING: gate inside `to_card/3`, count stays ungated, dual review mandated**
  (`task-felix-w13-boardsnapshot-fieldvis-seal`, opus, round 1, medium; anchors re-derived on
  origin/main — the task's ~L904/977/998 were stale). Single seal point = `Board.to_card/3`
  (board.ex L195-222); `family_walk/4` (L833/835), `gantt_data/1` (board_live L3197) and `focus_of/1`
  (L3373) inherit the redaction — render-site-only gating is FORBIDDEN (the two copies would
  diverge). Gate the TEXT-BEARING fields: description_excerpt, design_doc, criteria_list AND
  next_criterion (both read raw acceptance_criteria text — gating one leaves a leak) + peek-parity
  fields per merged #5470 (`Envelope.field_readable?` with `CallerContext.anonymous()`, fail-closed,
  schema resolved ONCE per snapshot). The derived criteria COUNT (`Criteria.progress/1`, %{met,total},
  never text) stays UNGATED per the peek's own count-vs-text law (board_live.ex:765). `board_test.exs`
  does NOT exist — new scaffolding required. Latent hardening, not a live leak (no schema declares a
  private field today); sole consumer = board_live.ex at /admin/projects auth: :ops ("web embed"
  consumer claim was stale). DUAL INDEPENDENT REVIEW at Review — the E2 graduate applied at the
  security flip-risk seam. Baselines run-proven green: board_live 93/0, theme-parity 4/0.

- **D110 — S4 EXECUTED AT DECIDE (Fable replaces a stage — the E4 move; zero builders spent).**
  (a) `task-felix-w13-claimfence-uuid-guard` CLOSED done 4/4: its RECONCILED-2026-07-22 note was
  itself the false-done risk — WRONG on both prongs (ee9b00464/#5473 IS an ancestor of origin/main;
  the `Ecto.UUID.cast` guard IS live at claim_fence.ex:26-40); test ran 4/0. The note had compared
  against the stranded local-main head, not origin/main. (b) `task-felix-sobelow-gate-blocking-eval`
  CLOSED done: sibling STAY-ADVISORY verdict (PR #5474) + exact-137 recount with verbatim category
  match + security.yml:55 agreement; criterion-0 honestly notes classification rests on the baseline
  mechanism, not a fresh CI-log review. (c) D81(c)'s SEVEN won't-build retirements — never executed
  on the ledger since W13 — EXECUTED via `bp task close … cancelled` (D5: ledger-honest cancel, never
  delete; `Stage` excludes cancelled by design; unclaimed close needs no epoch), each citing its
  D57/D63/D65/D75 verdict + the tenancy fence-lift re-confirmed (no open tenancy PR 2026-07-23).
  STAY OPEN with premises re-verified live: openapi-drift-chronic (drift check still inside mix-test
  job; two same-day repair commits 07-22), sync-deadletter-classification, migration-growth-watch.
  D79's pair untouched (separate ruling, correctly-seeded backlog).

- **D111 — E4 SCORING INPUTS SO FAR (Review completes the row).** Premise-failures caught PRE-BUILD,
  zero builder cost: (1) the wish's five named children — all merged W6–W7 (caught at Strategize);
  (2) rival R1's 14-surveyor ~85-site breadth sweep — premise ~3x stale; (3) the digest's own
  "25 unguarded files" reading — overturned at Verify by the assoc_constraint method fix, sparing
  ~2 census builders + up to 24 false-positive fix slices. Escaped-to-build premise failures: 0 so
  far. Review must report tokens/slice (METER.md), wall-clock, review_fixes, the provisional
  72h-escape note (pending on ALL scoreboard arms — comparison provisional by construction), rank
  order, Fable grade with honest commentary, and the explicit E4 verdict vs felix C/E1/E2 rows.

### Wave 18 roadmap (3 slices, round 1, parallel — disjoint files)

| # | Slice | Task | Model | Size |
|---|-------|------|-------|------|
| A | FK-abort family close (api_token + cloud device_auth/request) | `task-felix-w18-fkabort-family-close` | opus | small |
| B | studio_chat: telemetry-race guard + delete_session RESTRICT crash | `task-b55360f458ff6a45` | opus | medium |
| C | Board.snapshot field-visibility seal at to_card/3 (dual review) | `task-felix-w13-boardsnapshot-fieldvis-seal` | opus | medium |

Backlog filed: `task-felix-w18-authority-lock-mutation-proof` (P3),
`task-felix-w18-registry-staleability-hardening` (P4), `task-felix-w18-cloud-github-route-tier-drift` (P4).


## Wave 19 Decisions (2026-07-23) — ARM E (E7): FINISH THE RESIDUAL BACKLOG WITH VERIFY-DEPTH TRIAGE (Arm: E, config E7)

Research-program **Arm E / config E7** (paper `/papers/epic-cycle-research-program-abcde`; wave story
`felix-pristine-wave-19-2026-07-23`). E7 = E6 (Fable-arch × Fable-grade × freshness-gated lean
survey) PLUS freshness-gated VERIFY: a verify agent is assigned ONLY where the key judgment is
flip-prone/uncertain; premise-smoke-cleared fresh slices go straight to build with the builder's own
mutation proof + independent reviewer re-derivation. Kill signal: escapes rise OR tokens ≥ E6's
claimed 1.72M. This wave ran 3 verifiers vs E6's 6 — the verify chunk shrinks by design.

- **D112 — HOUSEKEEPING EXECUTED AT DECIDE (Fable replaces a stage; zero builders).** The three
  merged-W18 tasks CLOSED done 4/4 via claim→close (fresh epochs 8/8/7 — stale claim epochs 6/7/6
  are unusable), each merge-gate criterion stamped with the file-diff-verified pairing:
  `task-felix-w18-fkabort-family-close` ↔ PR #5777 (dd4d4cef, 4/4 exact file match),
  `task-b55360f458ff6a45` ↔ #5778 (feedcb98, dir entry expands to both test files),
  `task-felix-w13-boardsnapshot-fieldvis-seal` ↔ #5779 (b6171ae3, PR files ⊂ stored files —
  board_live.ex untouched BY DESIGN per D109's seal-point ruling; stored files field was
  over-broad, noted on the close). All three merge commits proven ancestors of origin/main via
  `git merge-base --is-ancestor`, never CI timing. TRAPS CONFIRMED AND DODGED: (a) autostamp cannot
  fire — none of the three merge criteria carry `"merge_gate": true` (systemic gap already filed as
  `pds-bl-merge-gated-criteria-carry-the-flag`); (b) stored `github.issue` (5766/5725/5463) is a red
  herring on ALL THREE — pairing is by changed-file diff, never by issue number; (c) the merge-gate
  criterion TEXT is a copy-paste template identical across tasks (w13's variant lacks "on the PR"),
  so text-match alone cannot catch a task/PR swap — the file-diff table is the guard. STAY-OPEN
  sweep re-verified: `task-openapi-drift-chronic` (0/3, tooling gap real, drift not currently
  firing), `task-felix-w14-sync-deadletter-classification` (dormant-infra watch),
  `task-felix-w13-cyclecorrection-migration-growth-watch` (watch on an applied migration) all STAY
  OPEN; the two `considering` tasks (bounded-read-watch, cyclefleet-reconcile-nplus1) unchanged.

- **D113 — S1: realtime broadcast field-vis seal** (`task-e98797b38ca3b51e`, opus, round 1, medium).
  Thread merged #5779's `to_card/4` Envelope decisions into `card_from_broadcast` (board.ex
  L455-494, currently PURE and ungated; sole caller board_live.ex L272). SPEC: (1) promote
  `field_visibility_gate/1` (board.ex L181-195) from `defp` to `def`; (2) `card_from_broadcast/3`
  — inject `readable?`, stay 100% DB-free; gate EXACTLY the 7 text/PII fields to_card/4 gates
  (priority, parent_id, labels, worker via `gated_worker/2`, next_criterion + criteria_list under
  key "acceptance_criteria", description_excerpt under "description", design_doc);
  (3) `lifecycle_status`/`github`/`github_synced`/`blocker_statuses` STAY UNGATED — parity law with
  BOTH sealed paths (#5470 peek + #5779 snapshot); gating them would be new undiscussed behavior;
  (4) board_live mount computes+assigns `readable?` on CONNECTED mount
  (`Board.field_visibility_gate(@dataset)`); on disconnected mount assign `fn _ -> false end` —
  no broadcast can arrive pre-connect, so behavior is identical, and FAIL-CLOSED is the seam's law
  (mirrors the L212 no-DB-on-static-render pattern without a permissive default); `:refresh` (15s)
  recomputes it so schema edits self-heal; schema resolved at most mount+refresh cadence, NEVER
  per broadcast. E7 LEDGER: verify SKIPPED — fresh ground, premise smoke-cleared at L1 twice
  (strategist + digest, both on origin/main), mutation proof builder-self-suppliable.
  HIGH-FLIP-RISK: security field-visibility seam — reviewer must INDEPENDENTLY re-derive the gated
  field set + re-run the mutation, and NAME that a second independent review is warranted pre-merge
  (D109 discipline moved to review, not deleted).

- **D114 — S2: D43 walk.ex glyph delegate + THE STILL-FRAME RULING: ⠿, not ⠋**
  (`ttw17-bl-d43-elixir-walkex`, opus, round 1, small; re-parented from task-tui-goal — the Elixir
  half executes under felix, the Go half stays task-tui). walk.ex `task_glyph/1` (L671-678, the
  hardcoded ○/◐/⊘/●/✕/▸ fork) delegates to `StatusVocab` for the 5 KNOWN statuses, `▸`
  unknown-guard preserved (mirror Go D100's guarded shape). RULING on the contested byte: the
  spinner role degrades to **⠿** per the SHIPPED Elixir precedent (fleet_email.ex:578-580, charter
  D5) — walk.ex's chip is the shared View+email STATIC context (walk.ex:617-618's own comment),
  the same context class fleet_email already solved, NOT the Go terminal board. Go main's
  `roleGlyph["progress"]="⠋"` (gridblocks.go) and #5838 (MERGED to origin/main a80ac7443 during
  this Decide — the Go half is now DONE) are a TERMINAL-surface convention; the cross-language
  delta is ruled DELIBERATE per-surface consistency, documented in the new coverage test. NO
  dependency on #5838 either way (different language/files/gates — round 1). Blast radius
  is exactly: walk_test.exs:310-324 parity table (◐→⠿, ⊘→!, ●→✓; open ○ / cancelled ✕ / someday ▸
  unchanged — the L298-308 garbage-tolerance test still proves the guard) + email_golden.html
  (2 hits of "◐ in_progress") regenerated IN THE SAME DIFF via the PROVEN recipe:
  `MIX_ENV=test mix run --no-start` over `ParityFixture.tree()` +
  `Render.render_html(_, render_opts(:email))` (byte-identical regen verified today, sha256
  6f93f860…; there is NO mix task for it). Coverage gate (AC[1]) = an ExUnit test in walk_test.exs
  deriving expected glyphs from StatusVocab (delegation makes drift structurally impossible;
  mutation-proof by hardcoding one wrong byte). E7 LEDGER: verify ASSIGNED narrow (run-proof only
  — golden-regen mechanism + walk_test green, both proven; the 2026-07-16 wave died mid-Digest
  before ever running these).

- **D115 — S3: authority-lock mutation-proof — HARNESS RULING (the wave's ONE pre-build verify;
  it earned its cost)** (`task-felix-w18-authority-lock-mutation-proof`, opus, round 1, medium).
  The mirror-query option is REJECTED — PROVEN VACUOUS (mirror stays green when `lock: "FOR SHARE"`
  is deleted from cycle_fleet.ex; the real-drive test goes red). SHIPPED SHAPE: drive the REAL
  `CycleFleet.bind_assignment_task/2` on connection B (`unboxed_run` + `Task.async` + rendezvous,
  precedent cycle_fleet_test.exs:1611-1715) while connection A holds `FOR UPDATE` on the
  **DATASET row** — the ONLY isolable target: locking the assignment row is FK-masked (bind's
  `insert_all` RI-locks it → false green) and locking the wave row is RI-reached too (raw insert
  with NO select still 55P03s → false green); dataset-row is present→55P03 / removed→{:ok}.
  Session-level `SET lock_timeout` (SET LOCAL outside the txn is a NO-OP — measured), assert
  `Postgrex.Error` pg_code 55P03, and RESET `lock_timeout = 0` in an after-block (session GUC
  persists on the pooled conn and poisons later tests). Test MUST live INSIDE cycle_fleet_test.exs
  (fixture helpers are defp). The red/green loop is LOCAL — `mix test` runs fine (OOM memory is
  phx.server boot only); the mutation red-proof edits cycle_fleet.ex ONLY transiently in the
  builder's isolated worktree, committed diff touches the TEST FILE ONLY. SCOPE NARROWED to
  `bind_assignment_task` (the proven site); the other two sites (runtime_attempt_authority:4536
  FOR UPDATE, runtime_usage authoritative_join:187 FOR SHARE) need their OWN isolable-row analysis
  → backlog `felix-w19-bl-authority-lock-remaining-sites`. Wish premise "stale line refs" REFUTED
  (1683/4536/164 all exact on origin/main).

- **D116 — S4: registry staleability + route-tier drift FOLDED into one cloud slice**
  (`task-felix-w18-registry-staleability-hardening`, opus, round 1, small;
  `task-felix-w18-cloud-github-route-tier-drift` closed as folded — same files, one PR, one
  builder). (a) `create_site` becomes AUTHORITATIVE: `Map.put` (never `put_new`) for
  :barkpark_id/:team_id, mirroring the sanctioned `put_team_id/2` pattern (registry.ex:5328;
  create_site is the file's ONLY put_new offender for tenant identity), + an override-attempt test
  proving a client-supplied barkpark_id/team_id cannot win. (b) `put_env_var` TOCTOU: DOCUMENT the
  narrow check-to-write window at the call site + a deterministic test that a write against a
  deleted barkpark returns `{:error, changeset}` via the `assoc_constraint(:barkpark)` net
  (env_var.ex:95 — the repo-wide convention); no lock/txn added (improvement-only: no live defect,
  the net fails closed). (c) router.ex moduledoc L109 row for POST /v1/github/installations states
  the team-admin tier (route calls `require_team_admin`, L3251) + extend the mirror test to assert
  the tier for this route (its `@row_re` captures only method+path — structurally blind to tier
  prose, so the assertion must be explicit). E7 LEDGER: verify SKIPPED — surveyor ran the harness
  live TODAY (98/0) and every claim carries a rerun command.

- **D117 — E7 EXPERIMENT LEDGER + PROVENANCE CORRECTIONS (Review completes the row).**
  Verify ASSIGNED (3): S3 harness shape (flip-prone — DELIVERED decisively, refuted the mirror
  option, found the dataset-row/false-green trap a builder would have shipped wrong), S2-narrow
  run-proof (golden regen + walk_test — DELIVERED, both green), housekeeping close-pairing
  (misclose writes false ledger evidence — DELIVERED the file-diff table + exact criterion text).
  Verify SKIPPED (2): S1 (fresh, smoke-cleared twice, builder-self-suppliable mutation proof,
  reviewer re-derives), S4 (surveyor ran the gates same-day). CORRECTIONS the row must carry:
  (1) E6's own paper says its verify round was **6**, not the wish's "7"; (2) the kill-signal
  baselines (E6 1.72M/33%, E4 2.4M/31%) exist NOWHERE in Barkpark outside our own wave paper —
  `bp search "1.72M"` returns only us; both E4/E6 debriefs explicitly defer the token tally to the
  research epic and no scoreboard rows were ever appended. Review MUST flag the baselines as
  lead-supplied provenance; backlog filed on the research epic
  (`grb-append-e4-e6-scoreboard-rows`) to append the missing rows from meter reads. Scoring:
  total tokens + per-phase split vs E6/E4, premise-failures caught-vs-escaped (a skipped-verify
  escape kills E7), review fixes, whether PREMISE_SMOKE/FLIP_RISK blocks fired (they did — the
  strategist's 6-premise smoke block is in the paper), and the explicit E7 verdict.

- **D118 — WAVE SHAPE.** 4 slices, ALL round 1 (file-disjoint, no inter-slice deps), ALL opus
  (E7 knob e). Fence: api/lib/barkpark/tasks/board.ex + plugins/tasks/web/board_live.ex +
  portable_doc/render/walk.ex + api/test/** named files + cloud registry/router files. Collision
  scan clean (only #2907 touches api/lib — application.ex/host_vitals, disjoint; #5838/#5840/#5828
  are Go/CLI/docs lanes). Builders: branch from origin/main, isolated worktrees, CC=/usr/bin/clang,
  .ex waits for the Elixir Test gate, improvement-only.

### Wave 19 roadmap (4 slices, round 1, parallel — disjoint files)

| # | Slice | Task | Model | Size |
|---|-------|------|-------|------|
| S1 | card_from_broadcast realtime field-vis seal (/3 + injected readable?) | `task-e98797b38ca3b51e` | opus | medium |
| S2 | D43 walk.ex glyph delegate → StatusVocab (⠿ still-frame, golden regen) | `ttw17-bl-d43-elixir-walkex` | opus | small |
| S3 | bind_assignment_task real-drive lock-wait test (dataset-row 55P03) | `task-felix-w18-authority-lock-mutation-proof` | opus | medium |
| S4 | cloud registry staleability + route-tier drift (folded) | `task-felix-w18-registry-staleability-hardening` | opus | small |

Backlog filed: `felix-w19-bl-authority-lock-remaining-sites` (P3),
`felix-w19-bl-email-golden-regen-mixtask` (P4), `grb-append-e4-e6-scoreboard-rows` (research epic).


## Wave log

- **Wave 19 — 2026-07-23 — DECIDED (building). Arm: E (E7 — E6 + freshness-gated verify).**
  Ratified D112–D118. Housekeeping executed at Decide: 3 merged-W18 tasks closed done 4/4 on
  file-diff-verified PR pairings (#5777/#5778/#5779; autostamp can't fire — no merge_gate flag;
  github.issue a red herring on all three). 4 opus round-1 slices building: realtime broadcast
  field-vis seal (verify SKIPPED, HIGH-FLIP-RISK flagged for review), D43 walk.ex delegate with
  the ⠿-not-⠋ still-frame ruling (Elixir D5 static-degrade precedent beats Go terminal
  convention; golden regen recipe proven byte-identical), bind_assignment_task real-drive
  lock-wait test (the wave's ONE pre-build verify — dataset-row FOR UPDATE is the only
  mutation-sensitive target; mirror-query proven vacuous; scope narrowed, other 2 sites →
  backlog), cloud registry staleability + folded tier-drift doc fix. E7 ledger: 3 verifies
  assigned vs E6's 6; corrections recorded (E6 ran 6 not 7 verifies; 1.72M/2.4M baselines are
  lead-supplied, no scoreboard rows exist — backlog filed to append them). Grade: pending
  build+review.

- **Wave 18 — 2026-07-23 — REVIEWED (A−, per `felix-pristine-wave-18-2026-07-23`). Arm: E (E4 —
  Fable-architected + Fable-graded).** All 3 round-1 slices BUILT, reviewer-verified, PUSHED with
  PRs: FK-abort family close (api_token FK translators + cloud device_auth assoc_constraint,
  #5777 on `loop-epic/fk-abort-family-close-apitoken-cloud-dev-0-r` — one reviewer format fix),
  studio_chat telemetry-race FOR-SHARE pre-check + delete_session RESTRICT→changeset + chat_live
  flash (#5778), Board.snapshot field-visibility seal at to_card/4 (#5779). Reviewer re-ran every
  gate green on final state (10/0+35/0, 104/0+178/0, 104/0) and confirmed parity with the #5470
  peek seal (lifecycle_status + github ungated in BOTH projections — no divergence). Ledger clean:
  all 3 tasks in_progress with merge gates honestly open for the LEAD; residuals honest —
  `card_from_broadcast/2` realtime re-leak filed as `task-e98797b38ca3b51e`, approve/2 changeset
  bypass documented not changed. DEVIATION: D109's dual INDEPENDENT review ran as one reviewer's
  two adversarial passes, not two agents. E4 score: 0 premise failures escaped to build,
  review-repair load = 1 trivial format fix; quality axis SUPPORTS E4, token axis pending the
  meter read. NEXT: lead merges #5777/#5778/#5779 (each WAITS for the Elixir Test gate; #5777 also
  carries cloud/), closes each task's merge criterion, then the realtime broadcast seal
  (task-e98797b38ca3b51e) is the sharpest open child; backlog: authority-lock mutation proof (P3),
  registry staleability (P4), github route-tier drift (P4).

- **Wave 18 — 2026-07-23 — DECIDED (building). Arm: E (E4 — Fable-architected + Fable-graded, lean
  base).** Ratified D105–D111; recovered the stranded W17 D98–D104 text (unpushed local-main commit
  46fb0d67e) into the pushed charter. Ghost 07-22 W18 paper ruled an abandoned attempt (published, 21
  blocks, ZERO task artifacts) — superseded by `felix-pristine-wave-18-2026-07-23`. Census method
  corrected (assoc_constraint IS the FK translator; bang-ness irrelevant) → D104's ~85-site backlog
  collapses to TWO genuine instances; census task closed 3/3. 3 opus round-1 slices building:
  FK-abort family close (api_token + cloud device_auth/request), studio_chat telemetry-race +
  delete_session RESTRICT crash, Board.snapshot to_card seal (dual review). S4 executed AT Decide:
  claimfence closed 4/4 (its RECONCILED note was wrong on both prongs), sobelow-gate-eval closed via
  sibling verdict + exact-137 recount, D81(c)'s 7 retirements finally executed (close→cancelled).
  Backlog: authority-lock mutation proof, registry staleability hardening, github route-tier drift.
  E4 so far: 3 premise-failure classes caught pre-build, 0 escaped. Grade: pending build+review.

- **Wave 17 — 2026-07-22 — REVIEWED (A, per `felix-pristine-wave-17-2026-07-22`). Arm: E (E2 —
  dual-reviewer intersection).** COMPLETE the FK-abort scar-class CENSUS E1 seeded
  (`task-felix-w16-fk-abort-class-census-remainder`, now CLOSED 2/2 done by reviewer-1 — the wave
  ran the census in Digest/Decide but never stamped the deliverable task; reviewer sealed it). E2 =
  E1's lean straight-to-build + one premise-smoke PLUS a dual-reviewer-intersection merge gate.
  **Census-of-the-5-corners COMPLETE (all REFUTE, derived live off origin/main):** sync/ (insert_all
  raw upserts — no changeset for a constraint to attach to — + dormant), Oban workers (0/10 own an
  FK-casting changeset insert; ProjectorWorker→Content.Edge already constrained), plugin schemas
  (only 4 Ecto schemas repo-wide under plugins/; none an unfixed real `references()` FK),
  media-beyond-meta (MediaFile W14-fixed is the sole media schema), schema-v2 internals (no backing
  schema; codelists boot/seed/admin-only). **2 contestable candidates REFUTE on reachability:**
  Content.Revision (compactor `Repo.insert!` BANG on system Oban cron; online save_revision copies
  scope from a live in-txn parent Document — now FK-guarded — that aborts first → buildable
  intersection empty), webhooks/delivery.ex (real CASCADE FKs but insert runs in a DETACHED
  `Dispatcher.fan_out` `Task.Supervisor.start_child` fire-and-forget → crash logged, never a
  user-facing 500). **1 genuine reachable instance FOUND + BUILT:** `task-felix-w17-document-fk-constraint`
  (PR #5732, `loop-epic/content-document-core-schema-fk-abort-v1-0`) — the FOURTH sibling of the
  Event/SchemaDefinition/MediaFile scope-FK family. Three bare `foreign_key_constraint` appended to
  `Document.changeset/2`; owner_id correctly excluded (plain binary_id, no references()). Reviewer-1
  (this review) re-ran the mutation independently: strip → 3 `documents_<col>_fkey` ConstraintError
  raises, restore → 4/0 green; **ZERO code fixes needed**. **Corrected filter recorded (D99):**
  CASCADE/SET NULL/nilify_all are ALL still this class (both W16 fixes are themselves CASCADE FKs) —
  only "no real references() FK" excludes. **E2 experiment reading:** reviewer-1 AGREES with all
  three decide-phase verdicts (Document=build, Revision=refute, delivery.ex=refute); the
  agreement/disagreement data + escape-rate test await the LEAD-dispatched, blind reviewer-2 —
  that intersection is the E2 scoring input, reported post-wave, not by this reviewer. Backlog
  seeded: `task-felix-w17-belongs-to-crosscheck-backlog` (P3 — ~85 belongs_to schemas outside the
  5 corners) + a future insert_all-with-FK-no-changeset census (a distinct related scar-class).
  Ledger honest (slice in_progress 3/4, merge-gated [3] open for lead; census task closed 2/2).
  Next: LEAD merges PR #5732 (Elixir Test gate) + closes slice criterion [3] on the dual-reviewer
  intersection; dispatches blind reviewer-2 to re-derive the Document reachability premise, re-run
  the mutation, and re-check the Revision/delivery.ex refutes (the E2 disagreement seam).

- **Wave 16 — 2026-07-22 — REVIEWED (A−, per `felix-pristine-wave-16-2026-07-22`). Arm: E (E1).**
  COMPLETE the FK-abort scar-class sweep W14 opened on MediaFile. E1 = arm-D straight-to-build cost
  profile PLUS one real ~5-minute premise-smoke scout (no survey fleet). **2 round-1 slices, opus,
  file-disjoint, both landed on their branches with PRs, both reviewer-verified with ZERO code fixes
  needed:**
  (1) **bulldocs Event.changeset FK-constraint** (`task-felix-w13-bulldocs-event-fk-constraint`,
  PR #5714, `loop-epic/bulldocs-event-fk-constraint-restore-blo-0`) — reworked from the W13 refusal
  (D93 overrides D79). `paper_events.workspace_id/project_id` are real CASCADE FKs cast with zero
  `foreign_key_constraint`; a concurrent scope-delete raised `Ecto.ConstraintError` out of
  `Events.create_event/1`'s bare `Repo.insert`, escaping `block_ops.ex maybe_append_paper_event/3`'s
  documented "logged, never raised" contract and 500ing paper ingest. Fix maps the abort to
  `{:error, cs}`. `dataset_id` correctly untouched (not cast). Gate 3/0; RED-first re-proven by
  mutation (reviewer).
  (2) **SchemaDefinition.changeset FK-constraint** (`task-felix-w16-schemadef-fk-constraint`,
  PR #5715, `loop-epic/schemadefinition-fk-constraint-concurren-1`) — casts all three scope FKs +
  two `unique_constraint`, zero `foreign_key_constraint`; `Content.upsert_schema/3`'s raw
  `Repo.insert()/update()` raised on concurrent scope-delete. Fix appends the three FK constraints
  after the untouched unique ones. Gate 4/0; RED-first re-proven by mutation (reviewer).
  **E1 experiment reading (no kill signal):** the single premise-smoke confirmed every premise both
  slices lean on at L1 on origin/main AND correctly REFUTED candidate 3 (codelists Value/Translation)
  as non-reachable BEFORE a builder was dispatched — a real pre-build premise-failure catch, echoing
  D79's earlier W13 refusal. No builder hit a premise surprise at build time; reviewer independently
  re-verified every premise TRUE against real code + mutation gates. Cost ~1 scout (well under half a
  survey fleet). **Verdict: CONSISTENT with the E1 hypothesis but UNDER-POWERED** — n=3 candidates
  (2 built + 1 smoke-killed), all premises accurate, so this wave cannot distinguish "smoke caught
  everything" from "nothing to catch." Honest count of 2 is a valid E1 result; the DATA is that the
  smoke killed the one non-reachable candidate cheaply and left zero build-time premise failures.
  Backlog seeded: `task-felix-w16-fk-abort-class-census-remainder` (P4 — census the FK-abort corners
  the smoke did not scan: sync/, oban workers, remaining plugins schemas). Ledgers honest (both
  in_progress, 2/3, merge-gated criterion open for lead). Next: lead merges both PRs (Elixir Test
  gate) and closes criterion [2] on each.

- **Wave 15 — 2026-07-22 — DECIDED (building). Arm: C.** Ratified D92–D97. Minimal-research wave on a
  well-chartered epic: strategist solo read → ONE premise smoke (3/3 CONFIRMED, collision-free) → 2
  RUN-verifiers → 3 round-1 file-disjoint slices under `task-96a908af98698118`, all linked to
  `felix-pristine-wave-15-2026-07-22`: (1) webhooks recovery poison-row batch-abort CLASS fix
  (`task-felix-w15-webhooks-recovery-poison-class`, opus — run-proven ArgumentError + starvation;
  guard + terminal fallback + per-row rescue + ordered/bounded candidates; retry_worker read, fixed
  transitively, fence complete); (2) search suggestions/correction SQL bounds
  (`task-felix-w14-search-suggestions-unbounded` PROMOTED — the D89 deferral overturned by a
  run-proven `[:barkpark,:repo,:query]` telemetry SQL-capture harness; fable); (3) self_update
  :check_now budget arithmetic (`task-felix-w15-selfupdate-checknow-budget`, opus — 4×10s > 30s,
  derived budget + protective relationship test; thin-but-honest per D73). Honest skips recorded
  (D97): sync/ dormant, bulldocs fail-soft, schema-v2 admin-gated, dispatcher retry math
  already-good, dispatch_async sleep path caller-less, runner W7-bounded. Wave honest at 2 if C
  falls. Reviewer-2 verdicts arrive post-wave (research-program scoring). Grade: pending
  build+review.

- **Wave 14 — 2026-07-22 — DECIDED (building).** Ratified D83–D91. LEAST-SWEPT INPUT-BOUNDARY HUNT,
  honest count. 15 surveys + a 7-assignment RUN-verify fleet (A1 xlsx-zipbomb offline `:zip` proof;
  A2 scim member CastError live-Postgres proof + phoenix_ecto→400 reframe; A3 DB-gate OPEN proof; A4
  media `/meta` field-vis 200-vs-403 proof; A5 undo key-growth `mix run --no-start` proof; A6 collision
  recheck CLEARS all 4 + refutes B1's stale deferral; A7 prior-art reconcile — 58 children, no dup)
  yielded **4 in-fence round-1 slices, file-disjoint, parallel**: xlsx zip-bomb pre-extract ceiling
  (`task-felix-w14-xlsx-zipbomb-guard`, opus), scim member UUID guard (`task-felix-w14-scim-member-uuid-guard`,
  fable), sheets undo distinct-user-key cap (`task-felix-w14-sheets-undo-key-cap`, fable), MediaFile
  changeset FK-constraint (`task-felix-w14-mediafile-fk-constraint`, fable). Severity reframe: the
  "binary_id CastError 500" title is inaccurate — CastError is 400 in this app (D85). C3 media `/meta`
  leak CONFIRMED LIVE but OUT OF FENCE (barkpark_web) → high-pri backlog, lead-routed (D88). B1 search
  unbounded + B3 sync dead-letter → backlog (D89). Five surfaces CLEAN, vein 6 (onixedit) + tickets
  binary_id = false leads (D90). Fable-5 spend BACK — opus reserved for the one security/subtle slice.
  Grade: pending build+review.

- **Wave 13 — 2026-07-21 — REVIEWED (A−, per `felix-pristine-wave-13-2026-07-21`).** The SEAL wave
  delta-audit. The epic seal rests on the already-merged CSP PR #3545 (ancestor of origin/main, 0
  Config.CSP findings); Wave 13 gave the 222 in-fence files that changed since the 2026-07-10 founding
  cutoff a real look and shipped what it found — **6 code + 1 doc slice, all opus, all round-1 parallel,
  all reviewed correct with ZERO code fixes needed.** Ratified D77–D82. Slices + final branches (all
  pushed, PRs #5468–#5474, lead merges):
  (1) **pulse dashboard mount-gate** (`task-felix-w13-pulse-dashboard-mount-gate`, PR #5468,
  `loop-epic/gate-pulse-dashboard-live-mount-behind-c-0`) — load_rows/load_vitals/safe_storage gated
  behind `connected?/1`, dead render paints a loading skeleton; the #2402 scar's unswept pulse remainder.
  (2) **github ops_live mount-gate** (`task-felix-w13-github-opslive-mount-gate`, PR #5469,
  `loop-epic/github-ops-live-stop-running-health-snap-1`) — Health.snapshot/0 (5+ RTT) gated behind
  `connected?/1`, DB-free blank_health + skeleton on the dead render; the #2402 scar's github remainder.
  (3) **board_live field-visibility seal** (`task-felix-w13-boardlive-envelope-fieldvis-seal`, PR #5470,
  `loop-epic/seal-the-board-live-task-peek-field-visi-2`) — the raw-Repo.one peek's hand-picked fields
  now gate through `Envelope.field_readable?` as an anonymous fail-closed caller (latent fail-OPEN
  hardening; no task field declares visibility today). Sibling list-card/gantt bypass filed as backlog
  `task-felix-w13-boardsnapshot-fieldvis-seal`.
  (4) **expand ?expand= N+1 batch** (`task-felix-w13-expand-nplus1-batch`, PR #5471,
  `loop-epic/kill-the-expand-n-1-in-content-expand-ex-3`) — per-ref resolve (2N+1) → one
  `get_documents_by_ids/3` per ref_type + memoized schema, query count constant in N; query-scope
  caller_context normalized to nil for non-CallerContext sentinels (fail-closed). CAVEAT: owner-scoped
  ref-type expansion under a sentinel/grant caller is fail-closed stricter and untested (over-redacts,
  never leaks) — lead note on the PR.
  (5) **indx persistence corrupt-skip** (`task-felix-w13-indx-persistence-corrupt-skip`, PR #5472,
  `loop-epic/make-indx-persistence-load-all-skip-corr-4`) — load_all/0 filter-generator drops the
  `:error` branch before `:maps.from_list`, so one corrupt .term file no longer crashes P4b recovery for
  every scope (honors the moduledoc contract).
  (6) **claim_fence UUID guard** (`task-felix-w13-claimfence-uuid-guard`, PR #5473,
  `loop-epic/guard-claimfence-verify-against-non-uuid-5`) — `Ecto.UUID.cast` before the :binary_id PK
  query; a non-UUID collapses to `{:error,:task_not_found}` instead of raising CastError (honors the
  `{:ok}|{:error}` @spec). Defense-in-depth (both live callers pass validated ids).
  (7) **sobelow STAY-ADVISORY verdict** (`task-felix-w13-sobelow-stay-advisory-verdict`, PR #5474,
  `loop-epic/record-the-sobelow-gate-flip-decision-st-6`) — docs-only; records that D75's blocking-flip
  precondition is unmet (137 baselined entries, 0 Config.CSP). Reviewer re-ran the gate GREEN
  (`grep 'stay advisory'` matches, `check-doc-budgets.sh` exits 0).
  **Ledger audit:** all 7 tasks honest — each non-merge criterion met with evidence, the MERGE-GATE
  criterion [3] correctly left met=false for the lead, all linked to the wave paper and parented to the
  epic. NO ledger lies; no fixes needed.
  **Gate re-run status (honest):** the reviewer worktree has no Elixir toolchain/`_build` and cross-worktree
  borrow-build is documented-broken; under the hard Fable spend constraint no 802-file recompile was run.
  The doc slice's gate was re-run green. The 6 Elixir gates rest on rigorous adversarial static review +
  the builders' recorded mutation-proofs + the **authoritative CI Elixir Test gate that runs on every PR**
  (charter D82). The load-bearing tests were spot-checked and genuinely pin the claimed behavior (the
  expand probe asserts flat query counts across N=1/6/16 with resolution correctness; the board_live seal
  asserts private peek sections drop).
  **Merge-gated criteria the lead closes on merge:** criterion [3] on all 7 slice tasks (PR merged +
  Elixir Test green — docs slice merges on its own doc gate).
  **OUTSTANDING from D81 (NOT executed this review — needs the lead):** the "7 watch/fenced items retire
  at review" retirement did not surface an authoritative task-id list to the reviewer; the CSP crit-4
  reword is lead-owned; `gr-blk-studio-presence-perf-flake` reparent-out belongs to the gui-remake epic
  (off this fence). Next wave / lead should execute these with the named D57/D63/D65/D75 evidence.
  **Next wave (14 / seal):** merge #5468–#5474 (Elixir-gated), close the 7 merge-gate criteria, execute
  the D81 retirements, then the epic is one honest step from a seal — the delta-audit found no un-fixed
  ripe named-failure beyond these 7 (new fleet/capabilities/schema ground proven clean, D80).

- **Wave 13 — 2026-07-21 — DECIDED (building).** Ratified D77–D82. The SEAL wave. Reconciled the stale
  `wave_status`: CSP #3545 is MERGED/LIVE on origin/main. A wide delta-audit (13 surveys + 6 RUN-verifiers)
  of the 222 never-felix-swept in-fence files yielded **7 round-1 slices, all opus, all file-disjoint,
  parallel**: pulse dashboard mount-gate (`task-felix-w13-pulse-dashboard-mount-gate`), github ops_live
  mount-gate (`task-felix-w13-github-opslive-mount-gate`), board_live field-visibility seal
  (`task-felix-w13-boardlive-envelope-fieldvis-seal`), content/expand.ex N+1 batch
  (`task-felix-w13-expand-nplus1-batch`), indx persistence corrupt-skip
  (`task-felix-w13-indx-persistence-corrupt-skip`), claim_fence UUID guard
  (`task-felix-w13-claimfence-uuid-guard`), sobelow stay-advisory doc verdict
  (`task-felix-w13-sobelow-stay-advisory-verdict`) — each with a mutation-proven fail-before, gate
  `CC=/usr/bin/clang mix test <file>`. New ground (epic_fleet/cycle_fleet/capabilities/tasks-schema)
  proven CLEAN with evidence (D80). Backlog seeded: bounded-read-watch, cyclefleet-reconcile-nplus1,
  bulldocs-event-fk-constraint, cyclecorrection-migration-growth-watch. Finish-set: CSP crit-4 re-worded
  to content-proof (lead closes); `gr-blk-studio-presence-perf-flake` re-parented OUT to gui-remake; 7
  vacuous-green/fenced watch-items to retire at review. Fable spend-capped — ALL builders opus. Grade:
  pending build+review.

- **Wave 12 — 2026-07-16 — DECIDED (building).** Ratified D68–D76. TWO opus build slices under
  `task-96a908af98698118`, both linked to `felix-pristine-wave-12-2026-07-16`, file-disjoint (parallel):
  (1) Sobelow tailored per-surface CSP + SAML SLO nonce (`task-0fc9d55c4725ab92`, P1) — the direction's
  downstream-plug model REFUTED by v1 (Sobelow credits only an inline CSP map on `put_secure_browser_headers`,
  and any CSP key vacuous-green), reshaped to inline-map + nonce-threaded root.html.heex + SLO
  `encode_http_post/4` nonce (v4: no esaml form rewrite; no PR#3514 collision); load-bearing justification is
  killing the 3×-paid router.ex rebaseline toil, not a demonstrated XSS. (2) accounts_test TOCTOU harden →
  async:true (`task-5f4c0d03c05cd10e`, P3) — v3 PROVED the 2-line test-only fix green (3 seeds + 7410-test
  suite), prod CAS untouched; draft twin `drafts.task-b50cd380be7f0dd5` DISCARDED. The pulse slice
  (`task-felix-pulse-ratelimit-scope-isolation`) was COLLAPSED to verify-only by v2 (dormant scope-bypass,
  no reproducible red-before → vacuous green) and CLOSED keep-serial. Honest-ledger reconcile (no build):
  restamped 3 merged-but-unstamped merge-gate criteria (#2955/#2956/#2954) + corrected `task-a9adc82f820db065`
  crit[1]'s stale "never produced" evidence (N=2000 measurement already shipped on main, 3d66c0ddc) +
  closed `task-4bc654f703da9d4a` verify-only. v6 read the last un-assigned corner (config/runtime.exs) —
  honestly clean; the sole sub-doctrine-bar `String.to_integer` nit filed as a watch-item
  (`task-felix-runtime-env-integer-graceful-parse`). Fable exhausted — both builders opus. Grade: pending
  build+review.

- **Wave 11 — 2026-07-16 — DECIDED (building).** Ratified D59–D67. ONE opus ship slice under
  `task-96a908af98698118`, linked to `felix-pristine-wave-2026-07-16`: the anchor — hermetic fix of
  `deploy_runner_test.exs:581` (`task-32ee49492917906d`, re-parented from unparented + brief rewritten
  off the refuted env-leak theory to the proven `cd: scriptless_tmp` fix). A 6-assignment RUN-verify
  fleet REFUTED the wish's env-leak framing: two CI seeds (584655/706849) gave identical output →
  order-independent; `config()` is read live (never in GenServer state) → reset-singleton is dead
  weight; the real script never echoes its path → the assertion is unsatisfiable on Linux (macOS
  passed by flock-absent accident). The sibling sweep and the auth-async doctrine candidate BOTH
  collapsed to zero ship slices (siblings benign; auth-async churn — W10 just shaped those files).
  Ecto-FK / unsupervised-spawn / sandbox-ownership all premise-negative. Backlog seeded:
  studio_chat/chat_live nil-prior `on_exit` leak, tenancy `:media_cdn` pattern alignment (W7-fenced),
  suite-determinism seed pin. Fable exhausted — builder opus. Gate proves red-before/green-after under
  Linux-equiv fake-flock. Grade: pending build+review.

- **Wave 10 — 2026-07-13 — DECIDED (building).** Ratified D51–D58. TWO opus build slices under
  `task-96a908af98698118`, both linked to `felix-pristine-wave-10-2026-07-13`, file-disjoint
  (parallel): (1) auth/login outbound Finch-pool isolation — MERGES `task-felix-outbound-pool-isolation`
  + `task-felix-sso-explicit-timeout` into one PR (same 4 SSO call sites + hard runtime pool
  dependency; V2), framed DEFENSE-IN-DEPTH not crash-fix (Finch partitions per {scheme,host,port} —
  D48's flat framing overclaimed; 5 modules IN, `Barkpark.Auth.Finch`, `:finch`+`:connect_options`
  co-set RAISES so SSO timeout uses top-level `receive_timeout`); (2) stamp in-range wrong-index
  guard — SERVER-SIDE text-guard threading (CLI range-validation is vacuous; V3 reproduced the
  in-range silent neighbour corruption on origin/main). Fresh audit (Oban idempotency) = ALREADY-GOOD
  verdict, NOTHING built (V4; sweep_worker's missing `unique:` is provably idempotent → a test would
  be vacuous green). Backlog seeded: auth-genserver async-fetch (30s mailbox stall, Fable-class OTP
  redesign), sweep-worker unique watch-item, pusher explicit-timeout. Six RUN verifiers overturned
  three wish premises (SSO crash-headline, pool-contention magnitude, CLI-validation sufficiency).
  Fable exhausted — all builders opus. Grade: pending build+review.
- **Wave 10 — 2026-07-14 — LANDED (steward close-out).** BOTH slices merged to origin/main:
  (1) auth Finch-pool isolation `#3063` (admin-merged past a pr-task-gate lease-lapse; closed
  `task-felix-outbound-pool-isolation` + `task-felix-sso-explicit-timeout`); (2) stamp in-range
  wrong-index guard `#3064` merged as `cf48aeeb7` — closed `task-felix-stamp-index-guard`
  (all 4 criteria met). #3064 needed steward finish-work after the builder: rebased onto current
  origin/main, regenerated the AGENTS.md onramp golden + 3 teach wrappers, trimmed the teach line to
  hold `docs/setup/CODEX.md` under its 10100B budget, and hand-applied the task-stamp OpenAPI summary
  drift (CI-printed; can't regen locally — OOM). Both slices' three overturned premises stand. Wave 10
  epic `task-96a908af98698118` slices fully landed.

- **Wave 9 — 2026-07-13 — MERGED.** All four opus slices merged to origin/main (#3038 sobelow
  reconcile, #3039 close.ex Mode-B autostamp, #3040 CDN publish-path async, #3041 D35 audit-dispatch
  land) + charter b8afeaa3; origin/main tip `2862108d` (verified via `gh pr list --state merged` +
  `git log origin/main`). The full close-out review entry was not written before Wave 10; the three
  D50-seeded named-failure children carried forward and are finished by Wave 10. Grade: pending the
  W9 review debrief.

- **Wave 9 — 2026-07-13 — DECIDED (building).** Ratified D45–D50. Four opus slices under
  `task-96a908af98698118`, all linked to `felix-pristine-wave-9-2026-07-13`, all file-disjoint
  (parallel): (1) sobelow reconcile — LAND branch b48fb6c1 + the proven artifact-payload hardening
  (`include-hidden-files:true` — the reconciled dotfile baseline was being dropped from the
  human-review artifact; on-pin CI run 29274393147 proved reconcile+guard otherwise correct); claim
  RELEASED not live (verify beat the wish) → claim by explicit ID epoch 5→6; (2) ledger close
  auto-stamp — Mode B only, at close.ex's `apply_close_update`, gated on a terminal status + a
  non-empty `landed` map + an explicit `"merge_gate":true` criterion marker (stamp on a done task is
  sealed — 409; the last-entry "MERGE GATE" convention is unreliable at 14/34); zero OpenAPI drift;
  (3) CDN sync-block — the wish's SSO headline REFUTED (Req/Finch bounded 15s default, live-probed at
  15164ms), crispest fix is async-izing the synchronous CDN purge on the two upload sites
  (fail-before 916/1103ms vs 0-7ms), delete-path left to D36; (4) D35 land — cherry-pick 60966bdc
  (conflict-free, green, fail-before proven), re-claim epoch 16→17. Six RUN verifiers overturned two
  wish premises (SSO-timeout, sobelow clean-land). Backlog seeded: `task-felix-sso-explicit-timeout`,
  `task-felix-outbound-pool-isolation`, `task-felix-stamp-index-guard`. Fable exhausted — all
  builders opus. Grade: pending build+review.

- **Wave 8 — 2026-07-13 — DECIDED (building).** Ratified D39–D44. Three opus slices under
  `task-96a908af98698118`, each 1:1 with an open D38 CI-hardening child, all linked to
  `felix-pristine-wave-8-2026-07-13`, all file-disjoint (parallel): (1) suite-order flakes — the
  ACTUAL merge-train reddener (P3): content_probe key-scoped `assert_raise` (drop the global
  atom_count read, keep async:true) + pulse burst-cap RETARGETED to the slow-refill abuse-rate
  channel (the wish's sleep-force-on-test-storm is a RED test, V3-proven); (2) sobelow
  reconcile-not-append — clear-skip THEN mark-skip-all run on the CI toolchain + upload-artifact (NOT
  a dev-box commit — toolchain drift, V2-proven; the 193/63%-dead figure is stale, origin/main is 84
  lines ~93% live) + a fresh-finding guard; (3) migrator/DDL deflake — PREMISE REFUTED (V1: no 40P01
  reproduces at all; Fixture E fails DETERMINISTICALLY with a lock-contention checkout timeout, not a
  sandbox-ownership race), fix = `migration_lock: false` on Fixture E + detag the 6 apply_up tests,
  every 40P01 stack-attributed (D35's audit-dispatch source is still UNMERGED — V4). Four RUN
  verifiers overturned two wish premises. Backlog seeded: `task-felix-pulse-ratelimit-scope-isolation`,
  `task-felix-sobelow-gate-blocking-eval`. Fable exhausted — all builders opus. Grade: pending
  build+review.

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
