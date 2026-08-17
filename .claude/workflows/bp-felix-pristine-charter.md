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


## Wave 20 Decisions (2026-07-23) — REFUTE-AND-TRIPWIRE: FK-ABORT SCAR-CLASS, CLOUD/ (Arm: E, E6+E7 recipe, 3rd surface)

- **D119 — PREMISE REFUTED AT THE FINEST RUNNABLE GRAIN: genuine cloud/ FK-abort fix count = 0.**
  The wish's "~17 unguarded cloud FK files" is W18's pre-D106 naive-grep count (provenance fully
  traced: first appears in W18 survey, overturned in-paper by V-cloud, corrected by D106; NO
  post-D106 artifact re-asserts it). Live census on origin/main at CHANGESET granularity: all 19
  belongs_to-bearing cloud/ schemas (36 changeset fns, 25 belongs_to = 25 `references()` FK
  columns 1:1) pair every FK-casting changeset with `assoc_constraint`/`foreign_key_constraint`.
  The inert-name (declared-but-mismatched translator) class is structurally absent TODAY: zero
  custom `name:` in cloud/ migrations AND schemas — both Ecto sides derive the identical
  `<table>_<column>_fkey` (verified in vendored ecto + ecto_sql source). Zero
  cast_assoc/put_assoc/build_assoc repo-wide, zero `insert_all` in cloud/lib, sole `Repo.insert!`
  (oauth State) has no FK column. The one changeset-bypass FK write (`device_auth.ex` `approve/2`
  `update_all` setting user_id) is UNREACHABLE as a scar — NO code path in cloud/ deletes a User
  row, and the id is always the caller's own live-session id, re-proven per request by
  `Accounts.verify_user_session_token/1`'s fresh `Repo.get(User, ...)`. Background writers doubly
  sealed (constraints + Oban/Task.Supervisor isolation). D99's filter held: only "no `references()`
  FK" excluded (`Site.current_deployment_id` plain binary_id, sole such column).

- **D120 — BUILD = ONE TRIPWIRE, RUN-PROVEN AT VERIFY (`task-felix-w20-fk-census-tripwire`).**
  The manual re-census this class has run four consecutive waves (W16/W17/W18/W20) becomes the
  machine's job: `cloud/test/barkpark_cloud/fk_census_test.exs`, a reflection test enumerating all
  BarkparkCloud schemas — every belongs_to-casting changeset must declare a matching
  `:foreign_key` constraint whose NAME is live in pg_constraint (the inert-translator case code
  inspection cannot catch). NOT designed on paper — V1 (opus spike) ran all five failure modes
  against a real migrated cloud test DB: baseline 2208/0; enumeration non-vacuous (24 schemas /
  19 belongs_to-bearing / 25 assocs / 27 FK casts / 25 declared constraints, count-floor asserted
  because the FIRST run WAS vacuously green on 0 loaded modules — fixed via `Code.ensure_loaded?`);
  mutation RED on stripped `assoc_constraint(:barkpark)` (env_var.ex) with precise
  `:missing_constraint` message; inert-name RED on `name: :env_vars_barkpark_id_WRONG_fkey`;
  restore GREEN, lib/ byte-identical. DUAL-MATCH is load-bearing: `Constraint.field` is the ASSOC
  name for `assoc_constraint` (18 schemas) but the COLUMN name for `foreign_key_constraint`
  (usage/sample.ex) — resolve via `__schema__(:association, f).owner_key` OR direct column match.
  Full verbatim harness preserved in the wave Paper (spike worktree is volatile). Mutation
  red-proof is a MERGE CRITERION, not a flourish. Moduledoc must carry the local-DB-drift caveat
  (CI's fresh migrate is the authority; a drifted shared local DB can false-red).

- **D121 — chat_changeset/4 is SPECIAL-CASED, not just excluded.** The sole non-arity-2 changeset
  on a belongs_to schema (`EmailSettings.chat_changeset/4`) keeps its asserted-exact exclusion in
  the generic enumerator (any NEW arity!=2 changeset fails that test), but gains an explicit
  hand-written call using the real public vocab sources (`Notifications.chat_events/0` +
  `Notifications.chat_channel_types/0` — both zero-arg source-of-truth accessors, verified) with
  the same declared+live assertion on its `assoc_constraint(:team)`. No silent skip anywhere:
  `@plain_binary_id_fields` and `@changeset_bypass_writes` stay as documented, reason-bearing attrs.

- **D122 — SLICE 2 = METER TRUTH (rides `grb-append-e4-e6-scoreboard-rows`, research epic — no
  duplicate felix child).** Verify PROVED the E4/E6 raw transcripts SURVIVE (wf_61734411-a89,
  wf_626db4ff-ff1, identified by exact journal direction-text match) and ran a
  dedup-by-message-id + METER.md-formula tally end-to-end: E4 = $63.75 / 62.3M all-axis tokens
  (677 unique turns), E6 = $46.61 / 38.9M (477 turns) — **22–26x larger than the lead-cited
  2.40M/1.72M**, which now propagate unverified across 4 documents. Ruling: NEVER "reconcile
  toward" the old figures — REPLACE with labeled-COMPUTED figures (METER.md tier-3), name the gap
  and the token-definition explicitly (all-axis incl. cache reads = the $-cost axis; the old
  figures' definition is unknown). Slice lands the durable aggregator
  `tooling/scaffy-duels/tally_wf.py` (PoC verbatim in the wave Paper; scratchpad copy is
  ephemeral), corrects the E4/E6 rows with method quoted, and leaves the exact command Review
  uses for THIS wave's own row (wf_2c9b2e75-d63). Premise-failure-caught-pre-build stays the
  recipe's headline metric — this wave IS the third-surface data point.

- **D123 — LEDGER HOUSEKEEPING EXECUTED AT DECIDE.** `task-felix-w18-registry-staleability-hardening`
  closed done 4/4 (PR #5917 MERGED, mergeCommit 91df62c5f ancestor-verified on origin/main; lease
  had lapsed post-merge — re-claimed epoch 9, criterion 2 stamped with merge evidence, sealed).
  W16/W17 census tasks stay SEALED as-is (confirmed done 3/3, correct scope) — W20's
  changeset-granularity evidence lives on the NEW tripwire task, never a reopen of a
  correctly-closed task. Fence re-verified live at Decide: ZERO open PRs touch cloud/**
  (#5917 merged); builders re-run the exact `gh pr list` fence check at PR time (~40 agents).

- **D124 — WAVE SHAPE + BACKLOG.** 2 slices, both round 1, both opus, file-disjoint
  (cloud/test/** vs tooling/scaffy-duels/**). No HIGH-FLIP-RISK slice: the wave's flip-prone
  judgment (census refute) was dual-derived pre-build (4 surveyors + V1's runtime crosscheck);
  reviewer must still independently re-run the mutation red-proof (strip one real constraint →
  red → restore → green). Gates: slice 1 = cloud.yml recipe locally
  (`cd cloud && CC=/usr/bin/clang mix deps.get && MIX_ENV=test mix ecto.create/migrate && mix
  format --check-formatted && mix test`), slice 2 = tally reruns reproducing the computed figures.
  Backlog filed: `task-felix-w20-bl-devauth-approve-bypass-guard` (P3 — activates the moment any
  user-deletion path lands in cloud/), `task-felix-w20-bl-cloud-testdb-drift` (P4 — local shared
  barkpark_cloud_test drift: phantom migration 20260723000000 + orphan
  `barkparks.fleet_parent_id` FK; false-red risk for local runs, CI unaffected).

### Wave 20 roadmap (2 slices, round 1, parallel — disjoint files)

| # | Slice | Task | Model | Size |
|---|-------|------|-------|------|
| S1 | FK-census reflection tripwire in cloud.yml's own gate (mutation-proven) | `task-felix-w20-fk-census-tripwire` | opus | medium |
| S2 | Durable meter tally + labeled-computed E4/E6 scoreboard rows (gap named) | `grb-append-e4-e6-scoreboard-rows` | opus | small |

Backlog filed: `task-felix-w20-bl-devauth-approve-bypass-guard` (P3),
`task-felix-w20-bl-cloud-testdb-drift` (P4).


## Wave 21 Decisions (2026-07-23) — INTEROP RESOURCE-BOUND: REFUTE THE SEALED LIST, BOUND THE NEW GENERATION (Arm: E, E6+E7 recipe)

- **D125 — PREMISE REFUTED AT THE SEALED-TASK GRAIN; W21 FILES NEW TASKS, NEVER A REOPEN.**
  The wish's target `task-felix-interop-resource-bound-sweep` is SEALED done 6/6 via PR #2954
  (W7, merge 841fc2845): probe (= `studio_chat/probe.ex` — NOT `media/probe.ex` or
  `plugins/content_probe.ex`, both zero-interop decoys; full paths mandatory everywhere),
  self_update/runner.ex, onixedit validator.ex all ADOPTED; titles.ex already-good;
  build_info.ex/claude_chat.ex out-of-scope. All six W7 sites re-verified drift-free on
  origin/main. Per W20/D123 no-reopen precedent, W21's work lands on NEW child tasks. Census =
  13 rows: 7 BOUNDED (magick, studio_chat/probe, titles, validator, self_update, codex
  readiness, release_capture bounded_cmd), 2 OUT-OF-SCOPE (build_info compile-time; mix task
  gen_types.ex dev-only npx — newly ruled, same class), 1 SURVEYED-AND-EXCLUDED (ExPTY forkpty
  NIF tmux console — admin-gated interactive terminal, operator-triggered kill, different
  threat class than request/job spawn), 3 CANDIDATE UNBOUNDED (codex/session.ex buffer,
  deploy_runner ctl cmds, janitor ps). No `:os.cmd`/`System.shell`/bare `:erlang.open_port`
  anywhere in api/lib; no Porcelain/Rambo/MuonTrap/Exile deps.

- **D126 — S1 = CODEX SESSION BUFFER CAP (`task-felix-w21-codex-buffer-cap`), FIX SHAPE PINNED
  BY RUN-PROOF.** `studio_chat/runtime/codex/session.ex` handle_info({port,{:data,data}})
  does uncapped `state.buffer <> data`; fail-before REPRODUCED offline (8 MiB newline-free sh
  stub → state.buffer = 8,388,608 bytes, one unbounded binary). Crucial constraint: the
  `%{failure: reason}` guards live ONLY on the two handle_call clauses — on a newline-free
  stream `split_lines` yields no complete line, so `fail_pending` alone can NEVER stop the
  flood. The cap MUST act in the :data handler itself: byte_size check → close the port, stop
  accumulating, `fail_pending(:buffer_overflow)` (named atom). Config: sibling
  `:max_buffer_bytes` key in the EXISTING `:codex_app_server` app-env keyword (session.ex
  already reads `:binary` there — never a new `__MODULE__` key), module-attr default 8 MiB,
  validator.ex's `@default`/`config/0`/`Keyword.get` TECHNIQUE as template. Mutation test rides
  the proven `binary:`/`args:` seam (hermetic, no real codex binary); assert threshold-crossing
  + named failure + port closed — never exact byte counts (streaming-chunk flake). SEVERITY
  FRAMING RESOLVED BY HOST CHECK: codex is DARK on guerrilla today (no `codex` binary anywhere
  on the filesystem, zero codex env vars, 0/38 chat_sessions rows ever provider='codex') but
  genuinely wired (provider CHECK constraint allows it; admin-gated ChatLive routes live).
  Framing = "admin session, if a codex binary is later provisioned, wedges the shared BEAM for
  every tenant" — defense-in-depth on the W7 admin-gated precedent (self_update ADOPT), not
  live-exploitable-today. No new sobelow surface (no System.cmd moves in S1).

- **D127 — S2 = DEPLOYRUNNER CONTROL-PLANE CMD DEADLINES
  (`task-felix-w21-deployrunner-cmd-deadlines`), WEDGE RUN-PROVEN.** Three unbounded
  System.cmd in the singleton `Sites.DeployRunner`: systemd_run:526 (inside
  handle_call :trigger), is_active:1351 (handle_call :status), systemctl_stop:1368 (inside
  handle_info :unit_deadline — the watchdog's OWN kill can wedge the watchdog; safe_call
  cannot rescue a handle_info). Wedge proven: sleep-30 systemd_run stub → concurrent raw
  GenServer.call exits `{:timeout,...}` at 5001ms while safe_call's 5s fallback MASKS the
  symptom (returns plausible idle) — tests must target the raw call or wall-clock, never the
  public status/1. Fix = the proven `Task.Supervisor.async_nolink` + `Task.yield(t) ||
  Task.shutdown(:brutal_kill)` family (nolink, NOT linked Task.async), degrading per the
  module's documented never-crash contract; ONE config key `:ctl_cmd_timeout_ms` in the
  existing `Application.get_env(:barkpark, __MODULE__)` keyword, default 15_000. All three
  seams (`:systemd_run_command`/`:is_active_cmd`/`:systemctl_stop_cmd`) are live-read and
  test-proven — `:systemctl_stop_cmd` accepted a first-ever stub (unit_deadline → :done/-2 +
  argv dump). Sobelow: the three CI.System entries are LINE-ANCHORED in api/.sobelow-skips
  (lines for 526/1351/1368) — migrate to inline `# sobelow_skip ["CI.System"]` comments
  (magick precedent) and drop the stale fingerprints. FENCE INSIDE THE FILE: the Port-fallback
  ingest loop is ALREADY bounded ({:line,4096} + 500-line push_log cap) — do NOT widen S2 to
  it; do not regress reattach (#3857) or teardown (#4106) semantics; 46-test baseline green is
  proven and must stay. HIGH-FLIP-RISK: happy-path preservation — reviewer independently
  re-derives that trigger/status/deadline behavior is unchanged when commands return promptly.

- **D128 — JANITOR VERDICT: UNBOUNDED-BUT-CONTAINED, BACKLOG NOT BUILD.** janitor.ex's `ps`
  System.cmd is genuinely unbounded and the `rescue` does NOT cover hangs (a blocked port read
  never raises) — the direction's "already-good-with-rescue" phrasing would be dishonest. But
  it is a boot-only one-shot `Task.start_link` (restart: :temporary, non-blocking to boot);
  worst case = one leaked process + one boot's sweep silently skipped. The D127 fold-in
  condition (real consequence) is UNMET → honest census row + backlog task, no build slice.

- **D129 — WAVE SHAPE + BACKLOG.** 2 slices, both round 1, both opus, file-disjoint
  (studio_chat/runtime/codex/** vs sites/**). Gates dry-run green at Decide: codex_test.exs
  4/0, deploy_runner_test.exs 46/0 (warm _build, CC=clang). Backlog filed as published epic
  children: `task-felix-w21-bl-claudechat-buffer-parity` (P3 — same uncapped `buffer <> chunk`
  scar in barkpark_web claude_chat.ex:1160/1481, zero coverage, spawn_env carries no
  resource-bound env; out of W21 fence), `task-felix-w21-bl-boundedcmd-extraction-eval` (P4 —
  doctrine-clause-4 EVAL, not migration: drift dossier = 3 kill families, 5 config schemes, 5
  error vocabularies, 2/7 volume-bound, uniform grandchild-kill gap; D34 per-site precedent
  stands until argued), `task-felix-w21-bl-releasecapture-bound-tests` (P4 — bounded_cmd's
  124/125 branches exist but have zero test proof), `task-felix-w21-bl-readiness-sobelow-inline`
  (P4 — readiness.ex:42 is the ONE holdout still on a line-anchored .sobelow-skips fingerprint),
  `task-felix-w21-bl-janitor-ps-bound` (P4 — per D128).

### Wave 21 roadmap (2 slices, round 1, parallel — disjoint files)

| # | Slice | Task | Model | Size |
|---|-------|------|-------|------|
| S1 | Codex session buffer cap — config-overridable ceiling, port closed on breach, mutation-proven | `task-felix-w21-codex-buffer-cap` | opus | medium |
| S2 | DeployRunner ctl cmd deadlines — 3 System.cmd sites bounded, never-crash preserved, sobelow inlined | `task-felix-w21-deployrunner-cmd-deadlines` | opus | medium |

Backlog filed: `task-felix-w21-bl-claudechat-buffer-parity` (P3),
`task-felix-w21-bl-boundedcmd-extraction-eval` (P4),
`task-felix-w21-bl-releasecapture-bound-tests` (P4),
`task-felix-w21-bl-readiness-sobelow-inline` (P4),
`task-felix-w21-bl-janitor-ps-bound` (P4).


## Wave 22 Decisions (2026-07-23) — BARKPARK_WEB RESOURCE-BOUND SWEEP: TWO-SEAM STREAMING CAP (Arm: E, E6+E7 recipe)

- **D130 — S1 = CLAUDE_CHAT TRANSPORT BUFFER CAP, RIDES THE FILED OPEN TASK
  (`task-felix-w21-bl-claudechat-buffer-parity`, promoted P3→P1).** Zero drift: every coordinate
  the task cites re-verified line-fresh on origin/main at Decide (parse_chunk :1160-1161, :data
  handler :1480-1483, buffer init :1349, config/0 :1182, terminate :1502-1516); task
  open/unclaimed; no open PR touches the file. Fix exactly as pinned + D126: byte ceiling checked
  IN the :data handler (a newline-free stream never yields a complete line, so the cap must live
  where bytes arrive); sibling `:max_buffer_bytes` in the EXISTING atom-keyed `:claude_chat`
  app-env keyword read by config/0 (never a new `__MODULE__` key); module-attr default 8 MiB
  (codex-twin symmetry); guarded Port.close + named `:buffer_overflow`; hermetic chatty
  newline-free sh-stub mutation proof on the proven put_chat_config command seam (describe
  "session subprocess", ~:692). TEMPLATE = the MERGED validator.ex technique; PR #5949 (codex
  twin) is REFERENCE-ONLY — still OPEN and red (Test/Sobelow/Format) at Decide. SEVERITY
  RE-DERIVED LIVE (supersedes W21's defense-in-depth framing for THIS module): claude is LIVE on
  guerrilla — barkpark_prod chat_sessions = 38 rows ALL provider='claude', 10 active in the last
  7 days, no BARKPARK_CLAUDE_CHAT override. NOTE for future re-derivations: the db name
  `barkpark` on guerrilla is a near-empty decoy; prod is `barkpark_prod` per DATABASE_URL — a
  query against `barkpark` false-negatives as role/db errors.

- **D131 — S2 = SINK-SIDE STREAMING DISPLAY CAP (`task-felix-w22-chatlive-stream-display-cap`),
  SURVIVES VERIFY BUT REFRAMED; SEMANTICS DECIDED = TRUNCATE-WITH-MARKER AT A STABLE BOUNDARY,
  DISPLAY-ONLY.** advance_streaming (chat_live.ex:5748-5762) does uncapped `state.text <> delta`,
  shared by BOTH providers (codex Runtime.Event :1231-1237 + raw claude :1282-1297). RUN-PROVEN
  at verify: 1000×200B well-formed deltas → streaming.text = 200000B, stable_len=0 (linear
  growth, all tail); 5000 deltas WEDGED the LiveView (:sys.get_state 5s timeout — the compounding
  full-prefix re-render is an independent DoS signal). REFRAME (digest premise REFUTED): the
  accumulator is cosmetic-in-flight for BOTH providers — chat_live.ex:1245's `is_binary`
  turn_completed branch is DEAD (advance_streaming always returns a map; codex appends nothing
  from the socket), codex durable text = Recorder runtime_text (recorder.ex:1046, out of fence →
  D134 backlog), claude durable = the full assistant frame (:1380-1388, transitively
  per-line-bounded once S1 merges). So S2 bounds a live-display memory + re-render DoS on the
  LiveView process, NOT persistence integrity — it must be sold as exactly that. SEMANTICS:
  truncate/freeze at the LAST STABLE balanced-fence boundary with an honest marker; stop
  accumulating and stop re-rendering past the cap; NEVER a mid-fence byte slice (the file's own
  :2465-2471 doctrine + chat_tool_renderer's render-only-truncation law); turn-abort REJECTED
  (kills legitimate long answers; cannot undo the Recorder's already-accumulated durable text).
  Config: sibling `:max_streaming_display_bytes` in the same `:claude_chat` keyword, module-attr
  default 1 MiB. Completion paths untouched — the full text still lands. HIGH-FLIP-RISK: the
  display-only judgment; the reviewer independently re-derives the dead-branch + Recorder
  provenance; an independent second reviewer is warranted before merge.

- **D132 — GATE BASELINE: OVERTAKEN BY EVENTS AT DECIDE — NO SLICE, NO TASK.** The digest's
  main-red (4 Fleet-tab failures: 3× PluginTopMenuTest + 1× NavParitySweepTest, proven at
  d4cf409ba and corroborated on #5949's branch) was FIXED by #5936 (59cd65d58) which repaired
  both test files (honest two-tab shape + curated /admin/fleet routes) alongside its CSS fix.
  Its own elixir run was in_progress at Decide — the LEAD confirms main green before merging W22
  PRs. Residual note (no task): the gate has a hole — a CANCELLED run at a tip is never
  auto-retried, so a tip can sit unverified (0f2497d55's own run was cancelled).

- **D133 — HONEST CENSUS VERDICT ROWS (refutations, no slices).** Tree-wide sweep of the
  252-file api/lib/barkpark_web: exactly TWO unbounded-and-reachable streaming accumulators
  (S1, S2). (a) thinking_pulse.text <> text (chat_live.ex:1332-1340) = INERT: fed solely by
  delta["thinking"], which the real CLI wire NEVER populates (charter D41 of the studio-chat
  epic = a direct versioned live probe, v2.1.205, both models; zero thinking_delta frames in any
  provenance-stamped fixture across 2.1.206–2.1.212); the ONE place real thinking text appears
  on the wire (full buffered assistant frames) is silently DROPPED by the handler's catch-all —
  correct today; a future refactor that renders thinking snippets must not wire that text into
  an accumulator without a cap. Caveat: the D41 probe is version-pinned; no fresh CLI probe this
  wave. (b) Channels BOUNDED: every handle_in overwrites single scalars/small maps; inbound WS
  frames capped only by Bandit's implicit 8MB default (no app-level max_frame_size — note, not
  a defect). (c) cache_body_reader BOUNDED-BY-PARSER (total-budget :length mechanism re-traced)
  but OVERSIZED for the unauthenticated pre-signature webhook path → D134 backlog. (d) Port
  lifecycle ALREADY-GOOD re-proven (merged no-orphan test; guarded close; exec-wrapped spawn).
  (e) Zero System.cmd/:os.cmd/System.shell/:erlang.open_port anywhere in the tree; sole
  Port.open = claude_chat.ex:1317. (f) append_message/@messages row-count already capped at 500
  (prior tasks) — different class, no action.

- **D134 — WAVE SHAPE + BACKLOG.** 2 slices, both round 1, both opus, file-disjoint
  (claude_chat.ex + its test vs chat_live.ex + its test). Gates are single-file
  `CC=/usr/bin/clang mix test`; the full 6-file chat suite ran green THIS wave (444/0 in 337.5s
  under load-avg 143 — slow is host contention, not recipe failure). Backlog filed as published
  epic children: `task-felix-w22-bl-recorder-bounds` (P2 — recorder.ex:1046 runtime_text
  uncapped `<>` is the REAL codex durable accumulator, + source_markdown persisted into an
  unbounded :text column with no validate_length; the third seam, out of the barkpark_web
  fence), `task-felix-w22-bl-webhook-body-rightsize` (P3 — ~101MB unauthenticated pre-signature
  webhook buffering vs GitHub's 25MB max, no RateLimit on that pipeline; path-scoped cap + rate
  limit, never lower the global constant), `task-felix-w22-bl-codex-completion-deadbranch`
  (P3 — the dead is_binary branch means codex never appends a live completion row from the
  socket; latent, codex dark in prod).

- **D135 — THE BLIND GATE IS REAL, AND OLDER THAN ANYONE SAID.** Sobelow's JOB conclusion on
  main's newest security run (30342320311, headSha 49c495a44, 2026-07-28T08:25Z) is `failure`
  while the WORKFLOW conclusion reads `success` — `continue-on-error: true` at
  `.github/workflows/security.yml:55` is the mask, confirmed live on six sampled main runs. Last
  green JOB = run 29692484044, 2026-07-19T15:15:46Z (`d58dd6c3b`): **8d17h blind, ~185 main runs,
  zero green in between**. The introducing merge is `f899ef2e9` (#4383), whose OWN security run
  (29692488581) was CANCELLED — two merges 6s apart is exactly how the rebaseline obligation got
  skipped. Before 07-19 the repo rebaselined reflexively (`aefba0809`, `efc02d635`, `d5db09e57`,
  `238fb58e7`); the practice did not decay, it stopped dead behind a cancelled run. Findings grew
  **9 → 51** under that cover. NAMED FAILURE MODE: *a permanently-red regression gate cannot report
  a regression* — the repo's own existing name for this class is "reds for reasons nobody believes".
- **D136 — CLASS (c) IS REFUTED FOR 7 OF 12 SQL SITES, AND HALF-SURVIVES FOR 5.** The direction
  sized S2 on "12 raw-SQL findings in never-security-reviewed code, plausibly a hidden injection."
  Two independent verifiers killed the injection hypothesis and one arithmetic proof split the set:
  (a) `tenancy.ex`'s 3 (`delete_e3_doc_keyed`/`delete_e3_dataset_keyed`/`delete_allowlist_scoped`)
  carry a **uniform +213 offset** from their baselined anchors (1154/1167/1178 → 1367/1380/1391)
  over **byte-identical** surrounding source — pure drift, and `delete_allowlist_scoped/3` is dead
  code (`Catalog.allowlist/0` is `%{}`); (b) 5 of `workspace_bundle.ex`'s 10 carry a uniform +711
  (328/340/345/348/354 → 1039/1051/1056/1059/1065) — also drift; (c) the other 5 (`merge_upsert`
  ×4, `scalar!` ×1) have preimages 371–411 in a file that was **368 lines long** at the last
  reconcile, so they cannot be drift by construction — genuinely new, never-baselined SQL that
  landed ~1h after the last green job (`9b4b50784`, #4385, 2026-07-19T18:21). BUT the injection is
  dead regardless: `workspace_bundle.ex:1020` reads `copy_into(qi(table), col_list, dump)` and
  `:1016` qi-maps every column; `qi/1` at `:1144` is correct Postgres quote-doubling; `merge_upsert`
  qi's `cols`, `order_cols`, `arbiter` and both sides of the DO UPDATE SET; `scalar!` is a pure
  false positive (both call sites pass static SQL with a `$1` bind). Honest Gates **D30** already
  ruled these ten sites on 2026-07-27 and the qi/1 comment correction is ALREADY on origin/main
  (`:1128`, "REQUEST-DERIVED, not catalog-derived"). **S2 as scoped does not exist.** Reachability
  is admin-only besides: `POST /api/workspaces/:slug/import` sits behind `:require_admin`
  (`Auth.has_permission?(token,"admin")`), and no HTTP surface in `api/` mints that permission.
- **D137 — GAP A IS REAL, EXECUTION-PROVEN, AND FENCED AWAY FROM FELIX.** Verify found what nobody
  was hunting: `import_member/3` (`workspace_bundle.ex:1013`) dispatches `entry["name"]` /
  `entry["columns"]` from the UPLOADED manifest straight into COPY/INSERT with **no membership
  check** — `table_exists?/1` (`:350-353`) gates only the DDL passes. Proven by running two hostile
  bundles through the real engine against a real Postgres: a manifest naming `schema_migrations`
  returned `{:ok, %{tables: %{"schema_migrations" => 1}}}` with the row present, and one naming
  `users` wrote an attacker-chosen identity row with an attacker-chosen `hashed_password`, inside
  the transaction that has already DROPped member FKs and DISABLEd triggers. This violates `qi/1`'s
  own written invariant (`:1141-1143`), and `table_exists?` would be insufficient anyway —
  existence is not membership; `users` exists. A 19-line `Catalog`-derived member guard was
  prototyped and the full adjacent suite ran **237 tests / 0 failures** with it applied. Severity is
  tenant→instance escalation-from-admin (a workspace owner can self-mint a PAT carrying global
  `admin` via `@pat_allowed_admin_permissions`), and clean-mode import is NOT behind
  `:allow_bundle_import`. **RULING: Felix does not build it.** D82 fences this epic strictly OFF
  `tenancy/workspace_bundle` (PDS crown, charter :917), and PR #6551 (PDS, OPEN) is rewriting
  `workspace_bundle.ex`, `archive.ex`, `janitor.ex`, `workspace_controller.ex` and both test files
  right now. Filed as a P0 backlog row naming the PDS parent and the sequencing. Building it here
  would commit the silent-substitution sin this wave exists to correct.
- **D138 — "BLOCKING" IS STRUCTURALLY IMPOSSIBLE IN security.yml; S5 CLAIMS VISIBILITY ONLY.** Two
  independent walls, both measured. (1) SR-1 live: `branches/main/protection` → 404 "Branch not
  protected", `rulesets` → `[]`, and `.github/required-checks.json` carries `"enforced": false` — so
  even the two SELECTED contexts are not applied. (2) `scripts/required-checks-generate.sh` stage
  **S4** excludes every check defined in a `pull_request`-paths-filtered workflow, and the flag is
  computed at WORKFLOW level (`:231`), so it binds every job in the file. Proof it is not an artifact
  of the advisory flag: the sibling `mix-audit` job carries NO `continue-on-error`, is blocking by
  intent, and is nevertheless excluded with `S4 PATHS-FILTERED`. Dropping `continue-on-error` moves
  the sobelow job from the S2 bucket to the S4 bucket — same outcome, excluded. **Therefore: any
  claim that this wave "makes Sobelow blocking" is false in the present tense.** The honest claim is
  that the failure becomes VISIBLE in the PR check list and truthful to `needs.<job>.result`. A
  fourth option nobody named — delete security.yml's workflow-level `paths:` and adopt elixir.yml's
  documented job-level skip shim (`:23-33`), since a job skipped by a job-level `if:` publishes a
  `skipped` check that GitHub counts as passing — is recorded as the cheap escape path, untested.
- **D139 — D75 IS UNSATISFIABLE AS WRITTEN AND IS AMENDED BY NAME THIS WAVE.** D75's only extant
  text is `docs/ops/merge-gates.md:136-142` (introduced by `34b9b25d3`, #5474): the flip is gated on
  "the baseline file:line entries reaching **0**". The floor is not 0, it is **10** — 6
  `Config.CSRF` + 1 `Config.Headers` + 1 `Config.HTTPS` (`config/prod.exs:0`) + 2 `.heex` `XSS.Raw`,
  all structurally unannotatable and each for a mechanical reason read in Sobelow's source:
  `Sobelow.Config.*` never routes through `combine_skips` (it iterates router pipelines directly),
  and `Parse.get_meta_template_funs/1` calls `File.read!` instead of the skip-rewriting `read_file/1`
  so a template's source never sees the `# → @` substitution. 98 of 108 are annotatable. Also
  recorded: D75 has **no defining charter entry** — it is cited at charter :904 and :2165 and at
  merge-gates :137, but this charter's own D75 (:1163) is a different subject entirely
  ("Fresh-eyes last corner honestly clean"). The number is a dangling citation and the wave says so
  rather than propagating it. The amendment restates the precondition as "the baseline holds ONLY
  entries that provably cannot carry an inline annotation, enumerated by type and count", records
  the S4/SR-1 topology so the implicit "then it blocks" promise stops being made, and fixes the
  doc's stale count (it still says **137**; main holds **108**).
- **D140 — THE FINGERPRINT REGIME IS TOOLCHAIN-STABLE; THE INSTABILITY IS THE LINE NUMBER.**
  security.yml's stated rationale ("fingerprints are NOT stable across Elixir toolchains") is
  REFUTED by measurement on an identical tree: CI (1.18.1/OTP27) and local (1.19.5/OTP28 — a wider
  gap than the pinned pair) produced **byte-identical** 51-finding sets, and a local regeneration
  reproduced the CI artifact's 106 entries with **57/57 shared fingerprints identical, 0 differing**.
  `Finding.fingerprint/1` is `:erlang.phash2([type, vuln_source, filename, vuln_line_no])` — phash2
  is Erlang's portable hash and the AST comes from `Code.string_to_quoted`, not the compiler. The
  line number is IN the hash, which is the whole disease: a pure renumber invalidates every waiver
  in a file. Proven by mutation — inserting two lines moved three baselined findings and all three
  re-reported, while two INLINE-annotated functions in the same file stayed suppressed across the
  same shift. **Consequence: the matched-toolchain ceremony buys nothing, and the human gate cannot
  rest on toolchain provenance — only on review.** Inline annotation is AST-bound and survives.
- **D141 — ANNOTATION SEMANTICS, PROVEN BY A REAL `mix sobelow` (0.14.1, the pinned version), AND
  ONE OF THEM IS A TRAP.** (a) A one-line `defp f(p), do: File.read!(p)` DOES bind. (b) A
  multi-clause `def`/`defp` binds **ONE CLAUSE ONLY** — each flagged clause needs its own comment.
  (c) An annotation placed INSIDE a function body is not a silent no-op — it **TRANSFERS the waiver
  to the NEXT `def` in the file**, silently waiving a different, unreviewed function (mechanism:
  `parse.ex:55-67` textually rewrites `# sobelow_skip [...]` → `@sobelow_skip [...]`, then
  `combine_skips` pairs the attribute with the adjacent def in source order). (d) Sobelow's regex is
  `~r/#\s?sobelow_skip (\[...\])/` — **at most one space after `#`, EXACTLY one space before `[`**;
  `# sobelow_skip["X"]` and `#  sobelow_skip ["X"]` are both silently ignored. A blank line or an
  intervening `@doc` is harmless. Privacy is no bar: 26 of 39 existing directives already sit on a
  `defp`. **Therefore no annotation migration may be reviewed by eye alone — every migration PR must
  be gated by a before/after scan diff**, and `# sobelow_skip [` is the only accepted spelling.
- **D142 — THE OVERLAP GATE IS BLIND TO EXACTLY WHAT THIS WAVE MIGRATES; THE STALENESS RATCHET IS
  THE WAVE'S REAL NEW INSTRUMENT.** `api/scripts/sobelow-inline-overlap-check.sh` is blocking and
  its `--selftest` genuinely reds under three independent mutations (neutered range comparison,
  broken prefix derivation, removed fail-closed branch) — it is a real ratchet and needs no work.
  But it is BASELINE-DRIVEN and SPAN-BASED: it fires only when a baseline entry's line falls INSIDE
  an annotation's span. Fixture-proven PASS on both drift and file-move — which is 100% of what this
  wave migrates — and PASS for a file carrying annotations with zero baseline rows (the janitor's
  exact case). It also cannot force a fingerprint deletion under those conditions, refuting the
  direction's "the migration is forced to DELETE each fingerprint". Two further defects: its
  annotation regex is LOOSER than Sobelow's in the UNSAFE direction (isolated fixture: it
  manufactures an OVERLAP on a Sobelow-ignored annotation and orders deletion of a load-bearing
  entry; tightening is a proven no-op on main today), and `entries++` counts rows, not parsed rows.
  **The genuine gap: 52 of 108 committed entries (48%) no longer resolve** — measured two
  independent ways that agree entry-for-entry (text-anchor resolution vs CI's own same-toolchain
  rescan artifact, `52 deletions / 50 additions`, disagreeing only on one `Config.CSRF` the text
  method deliberately skips). Phantoms are INERT, not live guns — a fingerprint hashes
  `[type, source, file, line]`, so a drifted entry waives nothing unless an AST-identical call
  reappears at the identical line — but that is precisely the collision a refactor can produce, with
  no signal. A text-only staleness check was prototyped and mutation-proven in four directions (red
  on main at 50/100, green on a cleaned baseline, red again on a single seeded +1 shift, exit-2
  fail-closed on empty). It runs in ~1s with no BEAM, so it can sit in the existing blocking job.
- **D143 — GREEN IS NOT REACHABLE THIS WAVE, AND SAYING SO IS THE DECISION.** The direction framed
  this as all-or-nothing on a green job. Of the 51 reddening findings, **16 sit in files Felix may
  not touch**: `workspace_bundle.ex` (10) and `workspace_bundle/janitor.ex` (6) are inside D82's PDS
  fence AND inside open PR #6551's diff. One more (`router.ex` `Config.Headers`) is structurally
  unannotatable. That leaves **34 buildable**: deploy_runner 12, blobstore local+s3 15, tenancy.ex 3,
  and 4 singletons (validation, titles, bulldocs, renditions). Dropping `continue-on-error` while
  still red buys a red badge and nothing else, so the flip is NOT in this wave — it is a filed
  round-3 row gated on the fenced 16 landing. **The wave ships the 34, the instrument, and the honest
  doc; it does not claim green.** Refusing to fake the deliverable is the doctrine working.
- **D144 — CROSS-EPIC ADOPTION, NOT RE-FILING.** `hg-bl-sobelow-fingerprint-to-inline-migration`
  (Honest Gates backlog item 6, open, P2, GH #6403) already IS this migration and already owns S5's
  criterion verbatim ("continue-on-error is dropped from the Sobelow job only once the baseline is
  falsifiable and green on main"). Two more open rows say the same thing from two more epics:
  `hg-bl-sobelow-red-under-green` and `pds-bl-sobelow-baseline-line-shift-reconcile`/`-tenancy`.
  Felix ADOPTS the Honest Gates row by stamping it with this wave's Paper and parenting its wave-23
  children under the epic, and closes the duplicates BY CONTENT rather than filing a fourth copy.
  `hg-bl-sobelow-inline-annotation-reversion` is closed by content outright: its whole premise (the
  reconciler runs `--mark-skip-all` WITHOUT `--skip`) was fixed on main by `c69cc0b1e` (#6412), which
  also shrank the baseline 134→108 by pure deletion and landed the blocking overlap job.
- **D145 — SEVERITY LANGUAGE IS BOUND, BECAUSE TWO CANDIDATES ARE WEAKER THAN FILED.** (a) The
  janitor's `ps` probe is not merely "unbounded-but-contained" per D128 — it is **UNREACHABLE in
  production**: `Janitor.own/1` and `disown/1` have ZERO callers in `api/lib` (the only four are in
  the test file), nothing else writes a `.owner` sidecar, so `owner_alive?/1` always takes the
  `:enoent` branch and `System.cmd(ps, …)` is never invoked. The moduledoc's claim that "the export
  engine calls this beside each temp file it creates" is FALSE on main, and the whole liveness guard
  is inert — already filed as `pds-w11-janitor-engine-handshake` (P1, open). Any future janitor slice
  must say "bounded a probe that is unreachable on main", never "removed a live hang". (b)
  `readiness.ex:42` is ALREADY bounded (`Task.Supervisor.async_nolink` + `Task.yield ||
  Task.shutdown(:brutal_kill)`); only the annotation remains. **D129 IS CORRECTED**: readiness.ex is
  not "the ONE holdout" — it is one of 108 line-anchored entries, one of 98 annotatable ones, and
  even scoped to `CI.System` there are two (the sibling is `studio_chat/titles.ex:366`). D129 was a
  detector-scoped observation inside the W21 fence promoted to a repo-scoped absolute.
- **D146 — WAVE SHAPE + BACKLOG.** 4 round-1 slices, all opus (fable unavailable), file-disjoint by
  construction: the migration owns `api/.sobelow-skips` alone, so no other slice may touch it. One
  round-2 slice (blobstore, `after: felix-w23-s1-drift-migration`) sequenced ONLY because it shares
  the baseline file — its code is disjoint. HIGH-FLIP-RISK is stamped on S1 (per-site reachability
  verdicts) and S5 (blobstore path provenance). Gates are local, BEAM-free where possible, and every
  one was dry-run before filing. Backlog filed as published epic children: GAP A (P0, fenced to PDS,
  sequenced after #6551), the fenced 16 (P1), the continue-on-error flip (P2, round 3), the
  overlap gate's unbound-annotation blindness (P2), `Dataset.changeset/2` slug format validation
  (P3), and the corpus gap — the Phoenix Mastery Corpus mentions Sobelow exactly once, as the last
  word of ch 56's title, and ch 63 universalised vacuous-green for TESTS and nobody carried it to
  TOOLING (P3).

### Wave 23 roadmap (4 slices round 1 + 1 slice round 2 — `api/.sobelow-skips` is owned by S1 alone)

| # | Slice | Task | Model | Size | Round |
|---|-------|------|-------|------|-------|
| S1 | Drift migration — 19 findings to inline annotations, 19 fingerprints deleted, per-site verdicts, scan-diff proven. HIGH-FLIP-RISK | `felix-w23-s1-drift-migration` | opus | large | 1 |
| S2 | Baseline staleness ratchet — text-only resolution check in the blocking job + Sobelow-exact regex fix + fixtures | `felix-w23-s2-staleness-ratchet` | opus | medium | 1 |
| S3 | Amend D75 by name + merge-gates truth (floor 10 not 0, 108 not 137, S4/SR-1 topology) | `felix-w23-s3-amend-d75` | opus | small | 1 |
| S4 | Fresh-finding guard `--selftest` — make the mutation proof able to fail | `felix-w23-s4-fresh-guard-selftest` | opus | small | 1 |
| S5 | Blobstore migration — 15 findings, fresh reachability verdicts (new S3 code, not a pure move). HIGH-FLIP-RISK | `felix-w23-s5-blobstore-migration` | opus | medium | 2 |

Backlog filed: `felix-w23-bl-bundle-member-guard` (P0), `felix-w23-bl-fenced-sixteen` (P1),
`felix-w23-bl-continue-on-error-flip` (P2), `felix-w23-bl-overlap-unbound-annotation` (P2),
`felix-w23-bl-dataset-slug-format` (P3), `felix-w23-bl-corpus-gate-integrity` (P3).

### Wave 22 roadmap (2 slices, round 1, parallel — disjoint files)

| # | Slice | Task | Model | Size |
|---|-------|------|-------|------|
| S1 | claude_chat transport buffer cap — :data-handler byte ceiling, port closed + :buffer_overflow, mutation-proven | `task-felix-w21-bl-claudechat-buffer-parity` | opus | medium |
| S2 | chat_live streaming display cap — stable-boundary truncate-with-marker, display-only, HIGH-FLIP-RISK | `task-felix-w22-chatlive-stream-display-cap` | opus | medium |

Backlog filed: `task-felix-w22-bl-recorder-bounds` (P2), `task-felix-w22-bl-webhook-body-rightsize` (P3),
`task-felix-w22-bl-codex-completion-deadbranch` (P3).


## Wave 24 Decisions (2026-07-29) — THE GATE GOES GREEN, AND EVERY WAIVER IN IT IS EARNED

- **D147 — THE LEAD'S BRIEF IS WRONG AND THAT IS FINDING ONE: FIVE FILES, NOT FOUR.** The brief lists
  workspace_bundle 10 + local.ex 7 + janitor 6 + router 1 = 24 and OMITS `media/blobstore/s3.ex`, which
  carries 8. Re-derived FOUR times independently — digest, two verifiers, and Decide itself
  (`mix sobelow --skip --format json` → `total 32`, five files, 34.2s wall, primary checkout whose `api/`
  is byte-identical to origin/main `606fefd15`; host load NOT quiet, so treat the timing as an upper
  bound). The omitted file is the largest unfenced block in the wave. **The correction was already on the
  ledger, verbatim, since 2026-07-28**, inside the never-dispatched S5 task ("local.ex 7, s3.ex 8").
  Nobody read it back. Three more corrections ride with it: main is `606fefd15`, not `0903f8132`; the
  baseline is **89** rows, not 90 (line 1 is blank); the staleness residue is **31**, not 32.

- **D148 — MOVE 1 IS A 15-ANNOTATION SLICE, NOT A P0. PROVEN BY EXECUTION, NOT BY READING.** A probe
  driving `POST /api/workspaces/:slug/import` through the real `BarkparkWeb.Endpoint.call/2` returned
  **403 for public-read, read AND read+write**, while an **ADMIN token passed the gate and died at 422
  `invalid_bundle`** — the oracle that makes the 403s the admin gate rather than a missing route, a body
  parse, or a workspace-not-found. Two further legs: ZERO writers of `media_files` outside `api/lib`
  (repo-wide grep + a targeted `INSERT INTO`/`insert_all` scan over priv/plugins/tooling/cloud/js/web),
  and no HTTP surface mints `"admin"` (four mint controllers, each with a server-authoritative allowlist
  topping out at `write`). **BUT the waiver sentence must be TWO CLAUSES.** `import_member/3`
  (workspace_bundle.ex:1013) still COPYs manifest-named tables and columns verbatim, bypassing
  `MediaFile.changeset` entirely, so an admin bundle CAN plant `../../..` and six sinks hand that column
  straight to `File.rm`/`send_file` — two of them (`share_link_controller.ex:140`,
  `tickets_attachments_controller.ex:226`) appearing in NO prior enumeration. A waiver reading "never raw
  client input" FULL STOP is FALSE, and the first reader who greps `import_member` correctly rejects all
  fifteen. That sentence is load-bearing and must not be trimmed as verbosity.

- **D149 — `felix-w23-bl-bundle-member-guard` IS NOT A P0 — AND IT WAS NEVER P0 ON THE LEDGER.**
  The wish calls it "the epic's only P0" and both the survey and the verify round repeated that. **Read back live
  during Decide, it is `priority: 3`.** Nobody re-derived the number they were all arguing about; the reprice this
  wave set out to make was already true. The SUBSTANTIVE ruling stands and is what matters: After D148 the only
  input that reaches it is an admin bundle — an actor who already holds `File.rm` authority by other
  means. Under hook (1) it names no reachable failure. It ships as scar-class defence-in-depth (hook 3)
  or it does not ship. **A LATENT SEAM FOUND WHILE PROVING IT, and worth more than the P0 was:**
  `Auth.authorize_pat_permissions/2` (auth.ex:577) allows `~w(read write admin)` when the caller's role is
  `owner` or `admin`, and workspace creators ARE owners — the library would happily mint a globally-admin
  token for a customer-created workspace owner. The ONLY thing holding it closed is that the sole HTTP
  caller (`auth_controller.ex:238`) hardcodes `["read"]` / `role: "member"`, with no test pinning the
  hardcode. One parameter from a privilege escalation. Filed, hook (4).

- **D150 — MOVE 2 AS WRITTEN IS A NO-OP; THE FIX IS A CODE FIX, AND THE OBVIOUS FIX IS A TRAP.** The
  fingerprint hashes the LINE NUMBER (`finding.ex:53-63`) and `--skip` matches on the hash alone
  (`sobelow.ex:540` destructures `[_type, _filename_line_n, fingerprint]`). Commit `2a60d013f` (#6090)
  already did the no-op once by accident: `:2539 → :2550` keeping hash `18ED697`, which brute-forces back
  to line **2530** — a cosmetic bump that made a DEAD waiver look maintained. The honest fix is
  `plug(:put_secure_browser_headers, %{"content-security-policy" => "default-src 'none'"})`, measured
  **32 → 31, high_confidence 1 → 0, router findings []**. The NAIVE one-arg `plug(:put_secure_browser_headers)`
  measures **32 → 32**: Config.Headers is merely replaced by a HIGH-confidence `Config.CSP` at :2611 with
  ZERO Config.CSP baseline rows to absorb it (`Config.CSP.missing_csp_status/2` returns `{true, :high, plug}`
  unconditionally). The two-arg map form is the established house pattern (router.ex :22/:121/:327/:375/:424).
  The slice also deletes the contrary in-code ruling at router.ex:2604-2609, which cites `task-f76e9b7b` —
  a task that **does not resolve** (`not_found`), a dangling citation of exactly the class D75 already caught.
  Honest price, stated rather than oversold: `pipeline :error_test` is `compile_env`-gated to MIX_ENV=test,
  so this prevents no production failure — it clears the wave's OWN named failure by DELETING a permanent
  waiver instead of maintaining one, at a cost of three lines. Fallback if the fix is rejected (ship one,
  never both): `Config.Headers: Missing Secure Browser Headers,lib/barkpark_web/router.ex:2609,364A37C`,
  derived twice independently (Sobelow's own SARIF `primaryLocationLineHash`, and the phash2 formula, which
  also reproduced CI's `18ED697` locally — so the fingerprint regime is toolchain-stable and the CI reconcile
  round-trip is NOT the only source of a fingerprint).

- **D151 — A `.sobelow-skips` ROW DELETION IS OUTSIDE D82's FENCE.** D82's OFF-list names
  `tenancy/workspace_bundle` as a SOURCE path; `api/.sobelow-skips` is in neither the allow-list nor the
  deny-list, and two merged PRs (#6616, #6412) already edited it. The fence's stated reason does not bind
  either: PR #6551's nine-file list does **not** contain `api/.sobelow-skips` — zero conflict surface.

- **D152 — THE DELETABLE SET IS 32, NOT 24, AND DELETING IT FLIPS THE STALENESS RATCHET GREEN.** Derived by
  per-row EXECUTION, not classification: run A (no `--skip`) **167**, run B (baseline EMPTIED, annotations
  honoured) **90**, run C (tracked baseline) **32**. A row is LIVE iff its exact `(type,file,line)` appears
  in run B → **57 live + 32 dead = 89**. Deleting all 32: staleness **PASS exit 0**, the BLOCKING overlap
  check **PASS exit 0** (deletion cannot red it — verified, not reasoned from its header),
  `mix sobelow --skip` **unchanged at 32**. **Mutation-proven able to fail:** deleting one row classified
  LIVE (`plugins/manifest.ex:90`) took the count to **33**. Deleting only the 23 non-fenced rows leaves the
  ratchet **RED at 9**, so D151's ruling is on the flip's critical path. The 32 decompose as 17 superseded
  by a named inline annotation, 5 media.ex rows closed by content against `1e0b43e67` (#6283, the
  pluggable-blobstore extraction — media.ex retains no traversal-eligible `File` call at all), 7
  workspace_bundle.ex + 2 archive.ex, and `router.ex:2550`.

- **D153 — AMEND D82 BY NAME: A NARROW COMMENT-ONLY CARVE-OUT INTO `tenancy/workspace_bundle`. THIS
  SUPERSEDES D143.** The digest's "there is no precedent for a comment-only cross-fence change" is
  **REFUTED**: commit `c69cc0b1e` (PR #6412), merged 2026-07-28T00:48, changed `workspace_bundle.ex` by 20
  lines **every one of which is a comment**, its own message reading verbatim *"Comment only — no
  behaviour change."*, and it is already an ancestor of #6551's merge-base with **zero conflict**
  (`git merge-base --is-ancestor c69cc0b1e 340204e5d` → yes). The counter-precedent is real and is quoted
  alongside it, not hidden: #6616 explicitly refused the same crossing (*"Fence held: no
  `tenancy/workspace_bundle/**` (D82 + PR #6551)"*). **RULING:** zero-semantic `# sobelow_skip` comment
  lines in `api/lib/barkpark/tenancy/workspace_bundle**` are PERMITTED, conditioned on (i) the
  annotation-binding ratchet landing FIRST, (ii) zero behaviour change, (iii) a rebase onto origin/main
  immediately before push with the binding check re-run AFTER the rebase. D143 said green was not reachable
  because 16 findings sat in files Felix may not touch; that premise is now amended, so the arithmetic
  closes: **32 → 17 (s1) → 16 (s2) → 0 (s6)**. But note the honest sequencing consequence — s6 and s7 are
  ROUND 2 and do NOT build this run, so **this run ships 32 → 17 and the instrument, not green.**

- **D154 — OPTIONS (b) AND (c) ARE DEAD ON THE EVIDENCE.** (b) *sequence behind #6551 and publish the date*
  has **no owner to publish one**: #6551 is OPEN but **unreviewed** (0 reviews, 0 review requests), **27
  commits behind**, its **own Sobelow job FAILURE**, last commit 2026-07-28T15:12Z, an abandoned
  half-finished `docs/api-v1.md` fix in its worktree, and its owning task `pds-bl-bounded-import-unpack`
  carries an **EXPIRED claim** (`worker: null`). Landing it also **GROWS** the fenced set — +9 new `File.*`
  calls in `archive.ex`. (c) *hand the 16 to PDS* has **no live recipient**: no `pds-w24` exists, all four
  `pds-w23` rows carry expired claims and none mentions sobelow, and the only overlapping PDS rows are two
  stale wave-11 P3 leftovers whose briefs describe a world that no longer exists. A Felix-owned P1 row
  (`felix-w23-bl-fenced-sixteen`) already names the work.

- **D155 — `# sobelow_skip` BINDS ON A `defp`, PROVEN BY MUTATION, FOR BOTH DETECTOR FAMILIES.** Annotating
  `defp remove/1` took the scan 32 → 30; adding `defp owner_alive?/1` and `defp os_process_alive?/1` took it
  to 28 — so **CI.System honours a `defp` too**, which had never been tested. All six janitor findings are
  annotatable and the arithmetic does not change on privacy grounds. Mechanism: `parse.ex:96` collects
  `{:defp,_,_}` into `def_funs` identically to `def`.

- **D156 — THE MULTI-CLAUSE HAZARD IS LATENT, NOT LIVE — AND THE BINDING RATCHET IS THE WAVE'S DURABLE
  DELIVERABLE.** Raised as possibly D137-class and **REFUTED**: with `.sobelow-skips` emptied so only inline
  annotations suppress (90 findings), all six files holding a multi-clause-bound annotation contribute
  **ZERO** findings. But one annotation waives exactly ONE clause — proven by splitting `Local.delete/1`,
  which left clause 2 firing at local.ex:102 — and **10 of the 57** inline annotations sit on a multi-clause
  def. D141's transfer trap was then **reproduced live**: displacing one annotation by one function moved the
  total **17 → 18**, a bare +1 indistinguishable from "someone added a `File` call", while the waiver silently
  transferred to a DIFFERENT unreviewed function. **Count-parity cannot see it.** The text-only binding
  predicate (exact-regex + next-code-line-is-def + indent-equality) runs BEAM-free over all of `api/lib` in
  **1.578s** with **ZERO violations today**, so it flips blocking on arrival — unlike the staleness ratchet it
  has no residue to burn down. It lands as a `--binding` mode inside the existing overlap script (reusing its
  verbatim `parse.ex:61` regex rather than forking a second copy) so it rides the existing blocking job with
  **no workflow edit**.

- **D157 — THE ANNOTATION COUNT IS 59 BINDING (57 inline + 2 attribute), NOT 73 AND NOT 39.**
  `git grep -c sobelow_skip -- api/lib` = 73 includes **14 prose lines** of the form
  `# @sobelow_skip — <justification>` that bind nothing. Spelling conformance is CLEAN (57/57 match Sobelow's
  exact regex, so D141(d) has no live violations) and the seven indent-4 annotations sit inside NESTED
  `defmodule`s, not inside function bodies, so D141(c) has no live violations either. Quote 57+2 with the
  grep; never any of the three inherited numbers.

- **D158 — THE STALENESS RATCHET UNDERCOUNTS BY ONE, STRUCTURALLY, AND security.yml's FLIP CONDITION IS
  FALSE.** The ratchet SKIPS every `Config.*` row for want of a per-line anchor (8 skipped of 89), so it
  reports 31 when **32** rows are dead — `router.ex:2550` is the invisible 32nd, dead AND with its live
  successor at :2609 unwaived. And security.yml's flip-condition comment claims *"15 of the 31 are the
  blobstore rows"*; `grep -c blobstore api/.sobelow-skips` = **0**. The blobstore contributes ZERO baseline
  rows and ZERO staleness, so completing the blobstore migration moves the residue by **exactly zero** — the
  gate's own operating instructions send the next reader to do the wrong work first. Corrected in the same PR
  as the deletion. **This conflation is a house habit**: it appears in the workflow file, in the lead's brief,
  and in the Strategize assignment briefs alike.

- **D159 — THE WISH MISQUOTES THE BAR, AND THE CORPUS CANNOT RECEIVE DOCTRINE.** The charter's hook (3) is
  *"closes a SCAR-CLASS risk — swept as a class"*, **not** "closes a real gap against the Phoenix Mastery
  Corpus", and a **FOURTH** hook exists ("makes a NAMED future change provably cheaper") that the wish omits.
  A slice justified solely on a Corpus gap does not clear the bar as written. Separately, the Corpus is a
  complete **92-chapter / 13-part TITLE MAP with no chapter bodies**: "sobelow" appears **once**, as the last
  word of ch 56's title, and `suppress|baseline|credo|dialyzer|static analy|linter|CI gate|regression gate`
  return **ZERO** hits. So `felix-w23-bl-corpus-gate-integrity`'s criterion 2 ("covers waiver binding,
  baseline monotonicity and advisory-mode-as-debt") is **structurally unsatisfiable in the artifact it names**.
  And the doctrine is **already published three times** — `gates-tell-the-truth-wave-2026-07-20`,
  `honest-gates-wave-2026-07-27`, and **felix's OWN wave 8 (2026-07-13)**, which already carried append-only
  baseline decay (`sobelow.ex:512` `:append`), the inline-annotation migration, and a run-proven mutation
  self-test, sixteen days before wave 24 claimed a doctrine gap. → **CLOSED BY CONTENT.** Only its criterion 3
  (the `.github/workflows` ownership gap) survives, re-filed as an owner assignment under hook (4).

- **D160 — D145 HOLDS: SETTLE `task-felix-w21-bl-janitor-ps-bound` BY SUPERSESSION, NOT BUILD.** `own`/`disown`
  have **zero** production callers in `api/lib` (their own definitions plus four test references), so
  `owner_alive?/1` always takes the `:enoent` branch and `os_process_alive?/1`'s unbounded `System.cmd(ps, …)`
  is **unreachable in production**. Checked and NOT previously checked by anyone: **PR #6551 does not wire the
  sidecar** — its janitor hunk is +8/−2 and is entirely the new `bp-ws-import-` scratch prefix — so lifting the
  fence does not make the probe reachable. Bounding dead code fails the epic's own bar. Its correct successor is
  `pds-w11-janitor-engine-handshake`, whose criterion 2 is literally the wiring that would make the probe live;
  fold the bound in there rather than shipping it now.

- **D161 — SR-1 IS DEAD; THE CONCLUSION SURVIVES ON ITS OWN FOOTING.** Branch protection on main is **LIVE**
  (`enforce_admins: true`, required contexts `Elixir gate` + `PR references an active task`, `strict: false`,
  rulesets `[]`). The wish's premise ("no branch protection — SR-1") is FALSE, and anyone re-deriving "rulesets
  are empty" gets a TRUE reading and draws the WRONG conclusion. The CONCLUSION survives untouched:
  `security.yml` is workflow-level paths-filtered on `api/**`, and `required-checks-generate.sh` stage S4
  excludes **every** check defined in a paths-filtered workflow (the `pf` flag is computed once per FILE and
  stamped on every job row), so no Sobelow check can be required as the file stands. Sobelow's greenness is NOT
  on the branch-protection path; it matters because a blind security gate is a real hole. `docs/ops/merge-gates.md`
  §9 still asserts the dead premise (and a stale `of 108` denominator) and is corrected this wave.

- **D162 — WAVE 23 IS ITS OWN VICTIM: S1–S4 ALL MERGED AND ALL FOUR TASKS ARE STILL OPEN.** Verified
  criterion-by-criterion against the merged diffs — #6616/#6617/#6618/#6619 (and #6620, the wave log) all MERGED
  2026-07-28T11:40–11:41Z and all ancestors of origin/main; all three landed scripts PASS `--selftest` exit 0.
  S1's binding was re-derived per-finding: 20 of 21 bound, the one "MISS" (`renditions.ex:107`) legitimately
  still covered by a surviving baseline row, and deploy_runner's CI.System annotation **pre-existed** the commit —
  so S1 did not over-waive. Two honesty deltas ride with the closes: **S2's TITLE overstates** (the selftest step
  is blocking; the real staleness run carries `continue-on-error`), and **S3's criterion 2 has ROTTED** (its
  "no branch protection" claim is now false — see D161). Closed by content with the fixing commits, not rebuilt.

- **D163 — GUARDRAILS.** All builders **opus** (Fable UNAVAILABLE this wave — `no_fable: true` remaps every
  fable-selecting dispatch site, builders included). Branch from **origin/main** into isolated worktrees;
  `CC=/usr/bin/clang`; `.ex` PRs WAIT for the Elixir Test gate. **FILE OWNERSHIP IS EXCLUSIVE this wave:**
  `api/.sobelow-skips` belongs to **s3 alone** (s1 and s2 are forbidden to touch it, and neither needs to);
  `.github/workflows/security.yml` belongs to s3 (staleness flip) then s7 (sobelow-job flip) in that order, never
  in parallel. Keep out of `cloud/**` and `deploy/**` — a Site Spawner wave holds that fence concurrently. Prefer
  CI as arbiter for `api/**`; every number quoted must name the TREE it was taken in and the LOAD it was taken under.

### Wave 24 roadmap (5 slices round 1 + 2 slices round 2 — green is reachable but NOT this run)

| # | Slice | Task | Model | Round | Files |
|---|---|---|---|---|---|
| S1 | Blobstore 15 — two-clause proven waivers, 32→17. **HIGH-FLIP-RISK: admin-only reachability** | `felix-w24-s1-blobstore-fifteen` | opus | 1 | blobstore/local.ex, blobstore/s3.ex |
| S2 | Router Config.Headers — FIX not re-anchor, floor 10→9 | `felix-w24-s2-router-csp-fix` | opus | 1 | barkpark_web/router.ex |
| S3 | Prune 32 dead baseline rows + flip staleness BLOCKING + correct the gate's false comment | `felix-w24-s3-baseline-prune-and-flip` | opus | 1 | api/.sobelow-skips, security.yml |
| S4 | Annotation-binding ratchet (`--binding` inside the existing blocking job) | `felix-w24-s4-annotation-binding-ratchet` | opus | 1 | scripts/sobelow-inline-overlap-check.sh |
| S5 | merge-gates.md §9 — kill the dead SR-1 premise, keep the conclusion | `felix-w24-s5-merge-gates-dead-premise` | opus | 1 | docs/ops/merge-gates.md |
| S6 | Fenced 16 under the D153 carve-out, 17→1. **HIGH-FLIP-RISK: fence amendment + displacement over #6551** | `felix-w24-s6-fenced-sixteen` | opus | 2 (after S4) | workspace_bundle.ex, janitor.ex |
| S7 | Drop `continue-on-error` — or publish the exact remainder | `felix-w24-s7-continue-on-error-flip` | opus | 2 (after S1,S2,S3,S6) | security.yml |

All five round-1 slices are file-disjoint and dispatch in parallel. S6 waits on S4 because the binding ratchet
is what makes a displacement loud instead of silent, and S6 is precisely the case that springs the trap. S7
waits on the arithmetic reaching zero — and if it has not, S7 publishes the remainder rather than faking green.

## Wave 25 Decisions (2026-08-17) — THE LEDGER PAYS FOR THE LENS

- **D164 — THE HONEST-LEDGER VERDICT TABLE (per-row, dated, commit-evidenced; the LEAD executes the closes at
  Review — reconciliation is never builder-time).** 19 days and ~4,000 PRs rotted most open-row premises; every
  verdict below was re-derived against origin/main on 2026-08-17 with rerun recipes committed under
  `tooling/grip/ledger/felix-w25-*.md` (this PR).
  **PAID — close with the paying commit:** `felix-w23-s1-drift-migration` → #6616 (`27352d8c13`);
  `felix-w23-s5-blobstore-migration` + `felix-w24-s1-blobstore-fifteen` → #7553 (`5a0f4abfa4`);
  `felix-w23-bl-fenced-sixteen` + `felix-w24-s6-fenced-sixteen` → #9411 (`92f91f0433`, semantic crossing dated
  2026-08-03, AFTER the #6551 fence died); `felix-w23-s2-staleness-ratchet` + `felix-w23-bl-staleness-blocking-flip`
  + `felix-w24-s3-baseline-prune-and-flip` + `felix-w24-bl-staleness-script-header-stale` +
  `felix-w24-bl-staleness-line-anchor` → #7555 (`c66008ae2b`) + #11427 (`4ca033f502`);
  `felix-w23-bl-overlap-unbound-annotation` → #6412 (`c69cc0b1ee`) + #7556; `felix-w24-s4-annotation-binding-ratchet`
  + the four binding sub-rows (transfer-needs-detector-map, census-floor, config-hash-line-consistency,
  multiclause-annotation-review) → #7556 (`2f9f25dd93`, commit body names the task);
  `felix-w23-s4-fresh-guard-selftest` → `--selftest` shipped on main; `felix-w23-s3-amend-d75` +
  `felix-w24-s5-merge-gates-dead-premise` → #7557 (`f91bf276b9`); `felix-w24-s2-router-csp-fix` → #7554
  (`458ce20113`) — **CAVEAT: read the row's verbatim text before closing (Headers vs CSRF; 5 router.ex Config.CSRF
  rows remain baselined)**; `task-felix-w20-fk-census-tripwire` → #5920 (`851e06703c`; the deliverable rides the
  cloud `mix test` suite, NOT a yml step); D7 phantom-media → #2955 (`38c68c81fd`, both `-S` probes collapse to it).
  **NO-OP — close superseded, zero builders:** `felix-w23-bl-continue-on-error-flip` +
  `felix-w24-s7-continue-on-error-flip` — `security.yml:227` continue-on-error is STILL true, and flipping buys
  nothing: stage-S4 excludes paths-filtered workflows from required checks (D143 reaffirmed by re-derivation).
  **HUMAN-GATED — leave open:** `felix-w24-bl-close-6057-superseded` (PR #6057 OPEN, security waiver).
  **STILL-LIVE — DO NOT batch-close** (the survey's "Sobelow vein fully triaged" overstated by three):
  `task-felix-w21-bl-readiness-sobelow-inline` (readiness.ex:42 still line-anchored at `.sobelow-skips:28`, the
  sole holdout of the 7 bounded interop sites), `felix-w23-bl-sobelow-transfer-proof-harness`,
  `felix-w24-bl-blobstore-runtime-guard`, plus the non-Sobelow residue: w13 bounded-read-watch (watch; its board.ex
  half is paid when S1 below merges — never double-file), w14 sync-deadletter, w18/w19 lock proofs, w20 devauth
  watch, w21 janitor-ps / releasecapture-bound-tests / boundedcmd-eval, w22 codex-completion-deadbranch /
  chatlive-overflow-banner / webhook-body-rightsize (bounded-but-oversized: 100MB pre-HMAC + no RateLimit on
  `:github_webhook` — behavior-changing, needs its own wave), and the four gr-bl rows (D171).
  `felix-w24-bl-stranded-sobelow-worktree` was NOT verified this wave — check the branch before touching it.

- **D165 — D82 IS AMENDED BY NAME (the D153 precedent): the `tenancy/workspace_bundle` fence is LIFTED for
  exactly two wave-25 slices — S3 (`felix-w25-s3-bundle-member-guard`, workspace_bundle.ex + its test) and the
  catalog.ex escaper half of S2 — and for nothing else.** Both of the fence's grounds are dead: PR #6551 CLOSED
  unmerged 2026-07-30 (content landed via #8130 the same minute), and the PDS crown is hardware-blocked climb work
  (a 2235 MiB export that does not fit guerrilla — crown rows cancelled/considering, no PDS wave since w27 closed
  2026-07-31, zero live claims on the five bundle-adjacent PDS rows, zero of 31 open PRs touching any tenancy
  path). The fence was already crossed semantically by merged #9411 (scalar!→Repo.query!, non-PDS, 2026-08-03).
  The guard row's own criterion 4 pre-authorized "the D82 fence is amended by name" as the unlock; its #6551
  sequencing clause is unsatisfiable as written and satisfied in intent (the rewrite landed; files quiet since
  2026-08-03). Conditions carried into the amendment: (i) lift scoped to the two named slices only; (ii)
  hostile-manifest test RED-before (a manifest naming `users` + `schema_migrations` must be rejected 422 before
  any COPY); (iii) behavior-preservation for catalog-member imports — the allow-set is DERIVED from the same
  enumeration export uses (`Catalog.root_table()` + `live_e1/e2/e3` + `Map.keys(allowlist)`), never the pinned
  lists, and a MEMBER table absent on the target stays tolerated (today's `table_exists?` skip path) — and the
  37/0 `workspace_bundle_test.exs` baseline must be re-proven on CURRENT main, not quoted from the w23 prototype's
  237/0; (iv) AUTO-RE-FENCE: if a PDS wave >27 opens or a tenancy file appears in any open PR, the lift is void
  and the slice stops; (v) D148's two-clause waiver sentence stays true — the qi/1 honest-waiver comment is
  updated, not deleted, and never replaced by a false "never raw client input" full-stop claim.

- **D166 — THE ROSTER: re-verified backlog + fresh delta-audit, 6 slices, all round 1, all file-disjoint.**
  Spine regardless of anything: S1 board bound, S2 dataset slug, S4 OnixEdit canonical events, S5 mailer offload.
  S3 ships as **P3 scar-class defence-in-depth per D149 — it was NEVER P0 on the ledger** (the direction's "the
  epic's only P0" is corrected; admin-only reachability is execution-proven 403/403/403 + admin-422). S6 recorder
  ships re-scoped per D169. Fresh findings that did NOT make a slice go to backlog rows (D171), not silence.

- **D167 — ZERO BUILDERS IN THE SOBELOW INSTRUMENT VEIN, reaffirmed as a hard commitment.** Everything there is
  paid, human-gated, or a documented no-op (D164). The three still-live Sobelow-adjacent rows (readiness-inline,
  transfer-proof-harness, blobstore-runtime-guard) are CONTENT/runtime rows, stay open, and are not rostered.

- **D168 — THREE ROSTER PATHS WERE STALE; the real files are:** `api/lib/barkpark/tenancy/workspace_bundle/catalog.ex`
  (not `tenancy/catalog.ex`), `api/lib/barkpark/plugins/onixedit/web/staleness_live.ex` and
  `api/lib/barkpark/plugins/onixedit/bokbasen/status.ex` (not under `barkpark_web/plugins/`). Also corrected:
  `staleness_live.ex` EXISTS on main (three lanes refuted the direction's "no longer exists" — the w13 watch row
  names `load_books/0` as a DELIBERATE flat read, distinct from the fresh OnixEdit write-bypass finding in the
  same file), and `Dataset` lives in `tenancy/`, not `content/`.

- **D169 — RECORDER RE-SCOPED: the w22 row's "unbounded per session" is FALSE (runtime_text is turn-scoped —
  resets at :341/:1103/:1132) and #6537 did NOT pay it (D64's 262144 bound covers the DISPLAY tail in
  stream_segments.ex, not the durable persist path).** The true named failure mode: the per-TURN concat at
  recorder.ex:1113 and the `source_markdown` persist seam (message.ex changeset has no `validate_length`) carry no
  byte cap. S6 builds the narrowed shape; `task-felix-w22-bl-recorder-bounds` is closed superseded-by-S6 at merge.
  Severity is defence-in-depth (codex DARK in prod, 0/38 sessions) — P3.

- **D170 — ONE VERIFY LANE RETURNED A STUB, AND THE ROSTER SAYS SO.** The `mailer-stall-pin` report carried no
  real content (its one fact is DEMOTED-NO-RERUN). Decide re-derived the premise directly: `Mailer.deliver` is
  called synchronously at `accounts/user_notifier.ex:80` and `access/grant_notifier.ex:48`, no Task offload in
  either file, and the fail-soft comment says auth callers intentionally ignore the result — so a supervised
  async offload (`Task.Supervisor.async_nolink` on `Barkpark.TaskSupervisor`, keeping the Logger.error
  observability INSIDE the task) is behavior-preserving for every caller that ignores the result. S5's builder
  MUST re-verify each `deliver_*` caller's pattern-match before offloading (any caller that branches on
  `{:error, _}` keeps a synchronous or awaited path). Seam ruling for S4: the canonical bypass-writer seam is
  `Content.broadcast_document_mutation/3` (content.ex:522, its own docstring names this exact use) PLUS a
  self-written `mutation_events` row — **NEVER `Content.upsert_document`**, which forces the draft twin and
  coerces published→draft (writer.ex:459/:475), a behavior change.

- **D171 — ADJUDICATED, NOT ROSTERED.** `gr-bl-tasks-route-parent-filter-ignored`: STILL-LIVE server defect
  (index/2 reads only `params["parent"]`/`params["phase_id"]`; both `?parent_id=` and `?filter[parent_id]=`
  silently ignored → unfiltered 200), but `tasks_controller.ex` carries open PR #11694 with a live review agent —
  FENCED this wave, build after #11694 merges (honor-or-422, the row's own AC allows either).
  `gr-bl-task-move-noop-help-drift`: server no-op-no-emit is working-as-designed (PDS-D451 comment); the defect
  is the Go CLI's "always emits" help text — `internal/cli` is outside this epic's fence; row stays open, routed
  to a CLI wave. `gr-bl-close-time-audit-vacuous-green` + `gr-bl-task-write-cap-breaks-briefs`: still-live,
  observability/behavior-changing respectively — not improvement-only slices; stay open. New backlog filed this
  wave: `felix-w25-bl-scim-sso-provision-seam` (Accounts has no token-free confirm; sso.ex:93-95 / scim.ex:296-297
  reach past the context by structural necessity — fixing it is an API ADDITION, not a cleanup, so it needs its
  own decision) and `felix-w25-bl-github-plugin-read-doctrine` (P4 — github plugin reads Content docs via raw Repo
  in health.ex/relations.ex/outbox.ex against its own stated doctrine; reads skip no hooks, low severity).

- **D172 — GUARDRAILS.** Builders **opus** except S3 (**fable** — tenancy blast radius + behavior-preservation
  judgment; **HIGH-FLIP-RISK: the guard must red hostile manifests without redding one existing bundle test**).
  Branch from **origin/main** into isolated worktrees; `CC=/usr/bin/clang` only where `cc` is shadowed; `.ex` PRs
  WAIT for the Elixir Test gate. FENCES per-FILE: strictly OFF `portable_doc/` + `content/` (Paper Excellence +
  BPML, PRs #11770/#11814/#11816), the security-wave controllers/plugs (#11765/#11766/#11809, incl.
  `tasks_controller.ex` #11694), `cloud/`, and everything D82 still covers outside the D165 lift. Every guard
  change is MUTATION-PROVEN (disable the guard → the new test reds). Every number quoted names the tree and load
  it was taken under. File ownership is exclusive: `workspace_bundle.ex` belongs to S3 alone; `catalog.ex` to S2
  alone; no slice shares a file.

### Wave 25 roadmap (6 slices, round 1, parallel — disjoint files)

| # | Slice | Task | Model | Round | Files |
|---|---|---|---|---|---|
| S1 | Bound `Board.snapshot`'s corpus scan — "the bounded HTTP reader has an unbounded LiveView twin" (board.ex:210 vs query.ex 500/1000, refreshed per socket every 15s) | `felix-w25-s1-board-snapshot-bound` | opus | 1 | tasks/board.ex, tasks/query.ex, test/…/board_test.exs |
| S2 | Dataset slug format — the only tenancy slug schema without `validate_format`, reachable non-admin via `POST /v1/data/mutate/:dataset`; + document/assert `standard_conforming_strings` at the catalog escaper (D165 lift) | `felix-w25-s2-dataset-slug-format` | opus | 1 | tenancy/dataset.ex, tenancy/workspace_bundle/catalog.ex, test/…/dataset_test.exs |
| S3 | Catalog-membership guard on `import_member/3` — P3 defence-in-depth per D149. **HIGH-FLIP-RISK: behavior preservation** (D165 conditions ii–v binding) | `felix-w25-s3-bundle-member-guard` | fable | 1 | tenancy/workspace_bundle.ex, test/…/workspace_bundle_test.exs |
| S4 | OnixEdit canonical events — two raw `Repo.update` writes on Content Documents gain a `mutation_events` row + `broadcast_document_mutation/3` (never `upsert_document`, D170) | `felix-w25-s4-onixedit-canonical-events` | opus | 1 | plugins/onixedit/web/staleness_live.ex, plugins/onixedit/bokbasen/status.ex, test/…/plugins/onixedit/ |
| S5 | Mailer offload — synchronous SMTP in the auth/grant request path moves to `Task.Supervisor.async_nolink`, observability preserved (D170 caller re-verify binding) | `felix-w25-s5-mailer-async-deliver` | opus | 1 | accounts/user_notifier.ex, access/grant_notifier.ex, test/…/user_notifier_test.exs |
| S6 | Recorder per-turn cap — config-overridable byte cap on the runtime_text concat + `validate_length(:source_markdown)` at the message changeset seam (D169 re-scope) | `felix-w25-s6-recorder-turn-cap` | opus | 1 | studio_chat/recorder.ex, studio_chat/message.ex, test/…/recorder_test.exs |

All six are file-disjoint and dispatch in parallel. S2 and S3 both sit under the D165 lift and its auto-re-fence
condition — if a tenancy file appears in any open PR before dispatch, BOTH stop. The ledger batch-closes (D164)
belong to the LEAD at Review, batched, with each close naming its paying commit.

## Wave 26 Decisions (2026-08-17) — THE SEAL IS EXECUTED, NOT DECLARED

- **D173 — THE D164 CLOSES ARE EXECUTED AT DECIDE, NOT STAGED FOR THE LEAD.** Wave 25's "honest-ledger
  reconciliation" was ratified but never landed: every D164 PAID row was still `lifecycle=open` because each carried
  a LAPSED null-worker claim and `bp task close` CAS-requires the CURRENT claim. Root cause of the wave-25 miss:
  the closes either never ran or 409'd silently (the bp-writes-silently-don't-land class). Wave 26 executed all of
  them live via **re-claim → stamp (STORED verbatim criterion text) → close → read-back**, proven on the first row
  (`felix-w23-s1-drift-migration`, epoch 7→8, life open→done, read back). Twenty rows closed: 17 PAID `done` (each
  naming its paying commit from the D164 table), 1 no-op `cancelled` (`felix-w24-s7-continue-on-error-flip`, D143),
  plus two stranded strays — `task-felix-w22-bl-recorder-bounds` `cancelled` superseded by #11858 (D169) and
  `task-e98797b38ca3b51e` `cancelled` as a duplicate of the merged #5914 realtime seal. The merge-gated rows
  closed with `--merge-gated` (Decide holding lead authority for the ledger reconciliation); the multi-unmet rows
  closed with `criteria_override` citing the paying commit rather than fabricating criterion flips. The stranded W18
  lock proof (`task-felix-w18-authority-lock-mutation-proof`, merged #5916) was also closed `done`. **Two D164
  sub-rows are PHANTOM and were struck, not closed: `census-floor` and `transfer-needs-detector-map` were never
  filed as tasks** (only `config-hash-line-consistency` and `multiclause-annotation-review` of the "four binding
  sub-rows" exist).

- **D174 — #11853 IS A FIXTURE DEFECT, NOT A BEHAVIOR CHANGE — LAND IT WITH AN UNDERSCORE-SAFE REGEX (S1).** The
  open red straggler adds `validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)`, whose char class excludes underscore;
  all 16 reds are ONE mechanism (an underscore dataset slug on the CREATE path → `get_or_create_dataset` refuses →
  `write_scope.ex:146` swallows to `dataset_id=nil` → partial-index collision / nil-authoritative assertions).
  Two ground-truth proofs settle the fork: the **guerrilla prod census** (`barkpark_prod`: 21 datasets, 0 with
  underscore, 0 violators — no real slug is refused), and the **probe** (both loosen-A and rename-B green all 16;
  `dataset_test.exs` stays 37/0; underscore is not a SQL-injection vector, so loosening loses no security value).
  Verdict: ship `@slug_format ~r/^[a-z0-9][a-z0-9_-]*$/` — the improvement-only-correct guard. Keeping strict would
  gratuitously refuse the de-facto underscore-slug convention for zero security gain; that would be the behavior
  change. S1 supersedes #11853 on a fresh branch; the lead closes #11853 on merge. The `write_scope.ex` swallow-to-nil
  is a real, orthogonal isolation defect filed as backlog (`felix-w26-bl-write-scope-swallow-nil`), NOT this slice.

- **D175 — THE pg_catalog BROADENING IS RELKIND-PRESERVING `pg_table_is_visible` (S2), SEQUENCED AFTER S1.** The
  bundle-member guard (`assert_member_tables!/1`) is public-schema-only: `table_exists?/1` filters `nspname='public'`
  while `copy_into/2` resolves the unqualified COPY via `search_path` (pg_catalog implicit-first), so a one-member
  manifest naming `pg_authid` imports — proven end-to-end by review2-11855 (landed a LOGIN SUPERUSER row). The fix is
  a 3-line SQL swap on `workspace_bundle.ex:510`: `SELECT 1 FROM pg_class cl WHERE cl.relname=$1 AND cl.relkind='r'
  AND pg_catalog.pg_table_is_visible(cl.oid)` — **KEEPING `relkind='r'`** (the reviewer's bare one-liner dropped it
  and would match views/indexes). Verify proved red-before/green-after: the probe manifest raises `InvalidBundleError`
  after the swap, and `workspace_bundle_test.exs` 40/0 + three sibling suites 41/0 confirm zero legit-bundle change.
  Draft `task-966de76b9dd92783` was AMENDED from its allow-set wording to this measured shape and published. **HIGH-FLIP-RISK:
  tenancy privilege boundary.** SEQUENCING (D165(iv) auto-re-fence): #11853 holds tenancy files in an open PR, so S2
  is **round 2** — it dispatches only after S1 merges AND #11853 is closed. The fix file (`workspace_bundle.ex`) is
  itself collision-free (no open PR touches it); the fence is the dir-level tenancy-in-open-PR condition, cleared by S1.

- **D176 — THE FRESH LANE FOUND A REAL SECURITY SLICE, NOT A PROVE-CLEAN (S3).** The least-swept unfenced stable-core
  file (`net/safe_outbound.ex`, one commit ever) carries a genuine **DNS-rebinding TOCTOU**: `check_url/1` resolves
  and classifies the target IP then DISCARDS it, and `post/2` hands the raw URL to Req, whose Finch pool re-resolves
  at connect time — nothing pins the checked IP. The sole runtime caller is the fence-hot webhook dispatcher, so the
  fix is confined ENTIRELY to `net/safe_outbound.ex` (pin the validated IP into the connection, preserve hostname for
  SNI/Host/verification). This IS a behavior change (closing a hole) framed as a security slice with a rebinding
  mutation fixture — not cleanup, not churn. The rival "prove-clean the whole core" outcome was refuted here; the rest
  of the least-swept core (pulse, sync, media internals) is honestly already-good. **HIGH-FLIP-RISK: security.**

- **D177 — THE ROSTER: 7 slices, all round 1 except S2 (round 2 after S1).** S1 straggler-rescue (opus),
  S2 pg_catalog broadening (fable, r2), S3 SSRF rebind-pin (fable), S4 blobstore read-path guard (opus),
  S5 chatlive two-seam honesty (opus — the codex dead-branch + buffer_overflow banner FOLDED into one slice because
  both live in `chat_live.ex` handle_info; `task-felix-w22-bl-chatlive-overflow-banner` cancelled as folded),
  S6 authority-lock remaining sites (fable — the FK-masked false-green trap is subtle per-site judgment; harness
  de-risked by merged W18 #5916), S7 release_capture 124/125 branch coverage (opus, test-only, adopts the existing
  `task-felix-w21-bl-releasecapture-bound-tests`). All file-disjoint. Fresh backlog filed: write-scope swallow,
  codex protocol_error swallow, s3 blob receive_timeout.

- **D178 — GUARDRAILS.** Builder models: **fable** for S2 (search_path semantics at the privilege boundary),
  S3 (TOCTOU + rebinding harness), S6 (false-green trap); **opus** for S1/S4/S5/S7. Fences re-derived from the live
  open-PR set at origin/main: content/ + portable_doc/ (#11934/#11770/#8465), capabilities (#11766), settings_live
  (#11978), auth_controller + router (#9530), search_controller (#9600), `.sobelow-skips` (#6057), and everything D82
  still covers outside the D165 lift; `application.ex` is soft-fenced by the conflicting zombie #2907 and the OTP lane
  simply avoids it. **D167 HOLDS: zero builders in the Sobelow instrument vein** — `readiness-sobelow-inline` stays
  backlog (its `.sobelow-skips:42` fingerprint currently matches the code, so it is not even a live line-drift). Note:
  main itself carries pre-existing non-required reds (spec-gate, compose-smoke, Sobelow) inherited by every PR — the
  four required contexts (Elixir/Cloud/Console gate + active-task) are what gate a merge.

## Wave 27 Decisions (2026-08-17) — LAND THE FLEET, FAIL CLOSED

- **D179 — THE MERGE TRAIN EXECUTED AT DECIDE; WHAT WAS GREEN IS ON MAIN.** The wish's premise
  ("wave 26 landed its fixes") was corrected twice: first by premise smoke (all six build PRs open),
  then by verify (#11853 MERGED at 21:18Z as b10593ab94, byte-identical in code to #12037 — the
  second review proved zero behavior delta). Executed at Decide 2026-08-17T21:35Z: **#12025**
  (charter D173–D178), **#12040** (chatlive two-seam), **#12042** (release_capture bounds) merged
  with all four required contexts green; **#12037 CLOSED superseded-by-#11853** (CONFLICTING/DIRTY,
  content already an ancestor of main; S1 second-review verdict recorded on the close comment).
  #12038/#12039 each red on ONE unrelated single-test flake (InstanceSiteDeployControllerTest door
  census; Pulse.MetricsTest vitals) — failed jobs re-run at 21:41Z; the lead merges each on green
  and closes felix-w26-s3-ssrf-rebind-pin / felix-w24-bl-blobstore-runtime-guard by the D181 recipe.
  #12041 is the one REAL red (ChatRenderGoldenTest sidebar byte-lock, chat_render_golden_test.exs:200)
  — resolved by the felix-w27-s6 contingency below. The Sobelow reds on the train were PROVEN
  stale-baseline line-shift by diff-independence (identical 6 router.ex CSRF findings on disjoint
  diffs) and structurally cannot gate a merge (continue-on-error, excluded from every required
  aggregator) — reconcile filed as backlog `felix-w27-bl-sobelow-baseline-lineshift`, fenced by #6057.

- **D180 — LEDGER CLOSES EXECUTED WITH READ-BACK; SUPERSEDE-CLOSES USE criteria_override, NEVER
  MET-FLIPS.** Five rows closed live at Decide, each read back `done`:
  `task-felix-w22-bl-codex-completion-deadbranch` + `task-felix-w21-bl-releasecapture-bound-tests`
  on #12040/#12042 merge evidence; `felix-w26-s1-11853-rescue` recording the SUPERSEDE INVERSION
  (content landed via #11853, #12037 closed superseded — every substantive obligation met on main);
  `felix-w23-bl-dataset-slug-format` (all four criteria substantively delivered by merged #11853)
  and `felix-w23-bl-bundle-member-guard` (substance delivered by merged #11855; residuals NAMED in
  the override: crit3's controller-test pass-count never captured, crit4's PR-6551 gate obsolete —
  6551 closed unmerged). The server itself enforces the honesty rule: `bp task stamp` REFUSES a
  MERGE-GATED criterion (`merge_gated_criterion`), so the sanctioned lead seal is
  `bp task close … --set criteria_override="<why it is done anyway>"` — override on the record.

- **D181 — THE CLOSE RECIPE IS CLAIM-STATE-DEPENDENT (supersedes D164's re-claim wording as the
  universal recipe).** Proven live on scratch tasks AND on the real rows: a HELD claim closes by
  presenting the CURRENT holder's worker+epoch (or your own worker + current epoch with
  `--set holder_override="…"` — the not_holder refusal is an honesty gate whose documented normal
  case is a lead sealing a merge-gated task); a LAPSED claim (worker null) closes by re-claim →
  close. Wrong epoch answers `fenced_off` — the CAS is real; epochs moved twice within minutes
  tonight (TTL sweeper), so ALWAYS re-read `claim.epoch` immediately before closing. Recipe row:
  `tooling/grip/ledger/felix-w27-held-claim-close-recipe-2026-08-17.md` (rides this PR).

- **D182 — write_scope FAILS CLOSED, WITH THE FRAME CORRECTED AND THE writer.ex FENCE LIFTED BY
  NAME.** The defect is real and reachable non-admin TODAY (the #11853 slug gate makes the error
  branch fire on any format-invalid dataset segment of POST /v1/data/mutate/:dataset), but
  "isolation-weakening" overstated it: the honest harm is silent-accept-of-invalid-slug +
  split-brain visibility between strict dataset_id readers (search/sheets/media) and NULL-tolerant
  string readers — workspace/project scoping stays intact. The slice ships the verify-pinned
  contract: legit-nil boundary byte-identical (cond arm, read arms, wykb NEVER-WORSE);
  `{:error, :dataset_not_found}` retried once then `{:error, :conflict}` (409 — never a spurious
  422, never nil); changeset errors become `{:error, {:invalid_dataset, details}}` re-keyed under
  "dataset", riding Repo.rollback → 422 `validation_failed` with zero known_codes/OpenAPI change;
  all 5 put_scope_attrs call sites restructured. FENCE LIFT (named, this slice only): writer.ex is
  nominally held by #8465, whose required greens date to 2026-07-31 (merge-base 2,500 commits
  behind) — it must re-gate before any merge anyway, so two call-site hoists cost it at most a
  trivial rebase. The identical swallow in media.ex:641-644 is OUT of this slice's fence — filed as
  `felix-w27-bl-media-dataset-swallow-mirror` so the "refused resolution is loud" claim is not
  overstated. HIGH-FLIP-RISK: the legit-nil/defect-nil boundary — independent second review owed.

- **D183 — THE WEBHOOK CAP IS ANCHORED AND THE 413 DISCIPLINE IS LAW.** GitHub documents a hard
  25 MB webhook payload ceiling, so a 26 MB config-overridable cap at the existing CacheBodyReader
  chokepoint rejects zero legitimate deliveries — provably behavior-preserving. Verified from
  pinned deps: ONLY the 3-tuple `{:more, chunk, conn}` reaches the canonical 413 payload_too_large
  envelope; a well-typed 2-tuple `{:error, :too_large}` raises non-enveloped Plug.BadRequestError
  (400). The slice returns read_body's `{:more…}` verbatim under a reduced :length; the global
  100MB endpoint length is untouched. The RateLimit half of the w22 brief is DESCOPED on the
  record (webhook_secret_cached memoization already blunted per-probe cost). Recipe row:
  `felix-w27-plug-bodyreader-413-propagation-2026-08-17.md`.

- **D184 — TWO REFUTATIONS RECORDED, NOTHING BUILT ON THEM.** (i) signed_url's unclamped ttl:
  the sole caller (delivery/urls.ex:147) passes no opts — ttl is never request-derived; no named
  failure mode from request data; already-good. (ii) the Session-GenServer "sandbox escape": the
  Ecto SQL sandbox exists only in test env — a Recorder committing on a pooled connection is
  correct prod behavior; test-infra hygiene, not a Felix slice. Found instead and filed low:
  undo_checkout's `admin?` = write-or-admin behind require_write, so ANY writer force-releases any
  checkout — the docstring lies (`felix-w27-bl-checkout-docstring-honesty`; tightening to true
  admin would be a behavior change, out of improvement-only scope). Recipe row:
  `felix-w27-signed-url-callsites-2026-08-17.md`.

- **D185 — MAIN'S ONLY FELIX-CAUSED RED GETS ITS TWO-LINE FIX AS A SLICE.** The spec-gate census
  (section 18) reds on exactly two UNPINNED protection-claim rows in the TRACKED
  felix-w25-sobelow-row-verdicts ledger file. Verify re-derived both hashes independently
  (25db097ed62f / 451500fdf367) and proved by mutation that the two class-C pins flip the census
  red→green and the suite exit 1→0 with the planted-claim canary still firing.

- **D186 — THE ROSTER: 5 slices round 1 + 1 lead-dispatched contingency; fences swept live.**
  Round 1 (all file-disjoint, zero open-PR collisions on a live sweep): write_scope fail-closed
  (`felix-w26-bl-write-scope-swallow-nil`, **fable**, HIGH-FLIP-RISK), pg_catalog bundle-guard
  broadening (`task-966de76b9dd92783`, **fable**, HIGH-FLIP-RISK: tenancy privilege boundary — its
  #11853-terminal sequencing gate CLEARED by the merge, its "publish the draft" wish-step was
  already stale), webhook 25MB cap (`task-felix-w22-bl-webhook-body-rightsize`, opus), spec-gate
  pins (`felix-w27-s5-spec-gate-pins`, opus), codex protocol_error surfacing
  (`felix-w26-bl-codex-protocol-error-swallow`, opus — ROUND 1 because #12040 merged at Decide,
  freeing chat_live.ex; the slice targets the codex Runtime.Event path, distinct from #12040's
  claude-pipeline overflow clause). Round 2, lead-dispatched on the re-run verdict:
  `felix-w27-s6-12041-golden-contingency` (opus — flake-or-drift verdict first, GOLDEN_REGEN only
  if real, then merge #12041 and close felix-w19-bl-authority-lock-remaining-sites per D181).
  Wave Paper: `felix-pristine-wave-27-2026-08-17`.

### Wave 27 roadmap (5 slices round 1 + 1 contingency round 2)

1. **write_scope fail-closed** — `felix-w26-bl-write-scope-swallow-nil` (fable, large, round 1).
   Gate: mix test on the touched files + fail-before revert run. HIGH-FLIP-RISK second review owed.
2. **pg_catalog bundle-guard broadening** — `task-966de76b9dd92783` (fable, medium, round 1).
   Gate: workspace_bundle_test.exs + 3 sibling suites green; pg_authid red-before probe.
   HIGH-FLIP-RISK second review owed.
3. **webhook 25MB body cap** — `task-felix-w22-bl-webhook-body-rightsize` (opus, medium, round 1).
   Gate: 413 payload_too_large envelope test red-before/green-after.
4. **spec-gate census pins** — `felix-w27-s5-spec-gate-pins` (opus, small, round 1).
   Gate: bash scripts/required-checks.test.sh exit 1→0, section-18 ok lines quoted.
5. **codex protocol_error surfacing** — `felix-w26-bl-codex-protocol-error-swallow` (opus, small,
   round 1). Gate: chat_live_test.exs 0 failures + clause-removal fail-before.
6. **#12041 golden contingency** — `felix-w27-s6-12041-golden-contingency` (opus, small, round 2 —
   lead dispatches on the re-run verdict; AFTER workflow 32068069994's re-run reports).

## Wave log

### Wave 2026-08-17 — Wave 27 DECIDED (building). "Land the Fleet, Fail Closed."

Ratified D179–D186. Verify corrected the direction mid-flight: #11853 merged at 21:18Z carrying the
byte-identical slug package, so the planned "merge #12037 first" inverted into "close #12037
superseded" and both owed slug second-reviews went moot. Act I largely EXECUTED at Decide: #12025 +
#12040 + #12042 merged (all-4 green), #12037 closed superseded, #12038/#12039 single-flake reds
re-run, five ledger rows closed live with read-back (two on fresh merge evidence, one recording the
supersede inversion, two w23 dup-family rows by supersede via criteria_override with residuals
named). The close recipe is now claim-state-dependent (D181): held → present current worker+epoch or
holder_override; lapsed → re-claim → close; the epoch CAS is real (fenced_off measured twice). Two
refutations recorded honestly (signed_url ttl not request-derived; sandbox-escape is test-infra) —
no slice built on either. Five slices round 1 (write_scope fail-closed + pg_catalog broadening on
fable with HIGH-FLIP-RISK flags; webhook 25MB cap, spec-gate pins, codex protocol_error on opus) +
the #12041 golden contingency round 2. Backlog seeded: media dataset-swallow mirror, sobelow
baseline reconcile (fenced by #6057), checkout docstring honesty. Grade: pending build+review.

### Wave 2026-08-17 — Wave 26 BUILT + REVIEWED, grade A. "Six Green, One Caught."

All six round-1 slices built, gates re-run green on the reviewer's final state, pushed with PRs: S1
dataset-slug guard, underscore-safe, supersedes #11853 (#12037, 60/0); S3 SSRF DNS-rebinding TOCTOU pin
with the Mint `:hostname` contract independently re-derived from deps (#12038, 19/0 + webhooks 111/0);
blobstore read-seam traversal guard (#12039, 41/0, **reviewer fixed** the builder-flagged leading-dash
regression on the `-r` branch — `unique_filename/1` genuinely emits `-<hex>.ext` for empty-slug
basenames, so `@blob_segment`'s leading class is now `[A-Za-z0-9-]`; leading `.`/`_` stay refused);
chatlive two-seam honesty (#12040, 295/0 — 3 local failures proved ENVIRONMENTAL: a stale committed
chat_sessions row in the shared barkpark_test DB, clean partition green, row deleted); authority-lock
lock-wait proofs for the two remaining sites (#12041, 77/0, test-only); release_capture 124/125 bounds
(#12042, 3/0, test-only — pins branch EFFECT via wide wall-clock separation since the exit codes are
private; the 126 rescue branch stays uncovered). Ledger spotless: every slice `in_progress` with
evidence stamped mid-claim, merge-gated criteria left for the lead, S2 (task-966de76b9dd92783,
pg_catalog broadening) honestly open for round 2 AFTER S1 merges and #11853 closes (D165(iv)
auto-re-fence). HIGH-FLIP-RISK second reviews owed before merging S1 and S3 (named in both PR bodies).
Next wave: lead merges the six (S1 first), closes #11853, dispatches S2, then considers the
never-swept core (access/, telemetry/, connectors/ interior) and the Session-GenServer
sandbox-escape leak the chatlive gate exposed. Grade: A.

### Wave 2026-08-17 — Wave 26 DECIDED (building). "The Seal Is Executed, Not Declared."

Ratified D173–D178. Premise smoke refuted the wish's core claim — wave 25 was NOT fully landed: #11853 was OPEN
and red, and all 19 D164 PAID rows were still `open` (lapsed null-worker claims defeating the close CAS). Wave 26's
first product is EXECUTION: 20 ledger rows closed live at Decide (re-claim → stamp verbatim → close → read-back),
the pg_catalog draft amended to the proven `pg_table_is_visible` shape and published, two phantom D164 sub-rows
struck. The second product is the build: 7 slices — land the straggler with the census-proven underscore-safe regex
(S1), broaden the guard to refuse pg_catalog members (S2, round 2 after S1 clears the tenancy fence), pin the SSRF
rebinding TOCTOU in the least-swept core (S3), plus blobstore read-guard, chatlive two-seam, authority-lock
remaining sites, and release_capture branch coverage. Three direction/digest premises corrected by ground truth: no
prod slug violates the regex (loosen, don't force), the guard file is collision-free (only the dir-level fence
sequences it), and the fresh lane is a real security slice (not prove-clean). 6 slices dispatch round 1
(S2 round 2); S3/S6 fable, S2 fable, rest opus. Grade: pending build+review.



### Wave 2026-08-17 — Wave 25 BUILT + REVIEWED, grade A. "Six for Six, Pushed."

All six round-1 slices built, reviewed, gate-re-run on the reviewer's final state, and **pushed with PRs
open** — #11852 S1 board cap, #11853 S2 dataset slug, #11855 S3 bundle guard, #11856 S4 OnixEdit events
(-r: honest test comment + format), #11857 S5 mailer offload, #11858 S6 recorder cap (-r: format). Every
guard was independently mutation-re-proven at review, not just re-read: S1 limit-drop reds only the cap
test; S2 validate_format-drop reds exactly the 3 negative tests; S3 (HIGH-FLIP-RISK) guard-disabled imports
the crafted users+schema_migrations bundle to completion and only the hostile test reds — 38 baseline tests
untouched; S5 delivery-skip reds all 3 notifier tests; S6 cap-passthrough reds exactly the two persist-site
tests. S2's degrade-to-nil premise and S5's 7/7 discard-census were re-derived from source, not trusted.
Review fixes were minimal (two slices: one misleading test comment, mix format on three files) — the
builders' trees were honest. Ledger audit clean: all six rows in_progress with evidence stamped mid-claim
and only merge-gated criteria open. LEAD TO EXECUTE ON MERGE: the D164 batch-closes (each close naming its
paying commit — read the row's verbatim text on the w24-s2 CSRF caveat first), close
task-felix-w22-bl-recorder-bounds superseded when #11858 merges, dispatch a genuinely independent second
reviewer on #11855 before merging it (flip-risk protocol), and eyeball S4's new :onixedit source tag (its
events ARE webhook-dispatched — intended, but confirm OnixEdit writes may echo outward). Next wave: the
still-live D164 remainder (readiness-sobelow-inline as the sole bounded-interop holdout,
webhook-body-rightsize as its own behavior-changing wave, w14 sync-deadletter, the gr-bl rows when their
fences lift) plus the two fresh backlog rows (scim-sso-provision-seam, github-plugin-read-doctrine).

### Wave 2026-08-17 — Wave 25 DECIDED (building). "The Ledger Pays for the Lens."

Ratified D164–D172. Two products in one motion: an honest ledger (every open row re-verdicted against
origin/main, dated, commit-evidenced — 13+ rows PAID, 2 no-op, 1 human-gated, the rest still-live with fresh
re-derivations committed as `tooling/grip/ledger/felix-w25-*.md`) and a fresh stable-core delta-audit that
yielded four builder-grade findings (board bound, dataset slug, OnixEdit write-bypass, mailer stall) on top of
two re-verified backlog rows (bundle guard per D149's P3 reprice, recorder re-scoped per-turn). The big call:
**D82's workspace_bundle fence is amended by name (D165)** — both grounds dead (#6551 closed unmerged, PDS crown
hardware-blocked), zero live collisions, the row's own criterion pre-authorized the unlock. Three direction
premises failed smoke and the wave followed the evidence: staleness_live EXISTS on main, recorder is turn-scoped
(not per-session) and unpaid by #6537, the bundle guard was never P0. One verify lane (mailer-stall-pin)
returned a stub — disclosed in D170, premise re-derived at Decide rather than built on a hole. 6 slices round 1
(5 opus + S3 fable, HIGH-FLIP-RISK), 2 new backlog rows filed. Grade: pending build+review.

### Wave 2026-07-29 — Wave 24 BUILT + REVIEWED, grade A. "The Arithmetic Held."

All five round-1 slices built, reviewed, gate-re-run on the reviewer's final state, and **pushed with
PRs open** — #7553 S1, #7554 S2, #7555 S3, #7556 S4, #7557 S5. Round-2 `felix-w24-s6-fenced-sixteen`
and `felix-w24-s7-continue-on-error-flip` are unbuilt BY DESIGN (sequenced-rounds law).

**The headline number, proven by execution on the merged tree rather than by addition.** The reviewer
octopus-merged all five slices onto `origin/main` @ `606fefd15` — they merge clean, no conflicts — and
re-ran the whole battery with a standalone sobelow 0.14.1 escript (the version pinned in `api/mix.lock`;
this worktree has no deps and a local app compile OOMs):

| measure | before | after |
|---|---|---|
| `sobelow --skip` total | 32 | **16** |
| blobstore `Traversal.FileModule` | 15 | 0 |
| `router.ex Config.Headers` | 1 | 0 |
| `.sobelow-skips` rows | 89 | 57 |
| baseline-staleness ratchet | exit 1 (50 stale) | **exit 0, blocking** |
| annotation-binding ratchet | did not exist | **exit 0, blocking, 66 annotations** |
| unannotatable floor | 10 | 9 |

The residue of 16 is exactly `workspace_bundle.ex` 10 + `janitor.ex` 6 — precisely what S6 is scoped to
clear, after which S7's verify-then-flip has a real chance of reaching a green Sobelow job. **Wave 24 did
not reach green** and does not claim to; it cut the residue in half, made two ratchets blocking, and left
one slice of arithmetic between here and the epic's own bar.

**Both fail-before proofs were reproduced by the reviewer, not quoted.** Staleness against the 89-row
baseline exits 1 (`STALE lib/barkpark/media.ex:61`), so the blocking flip genuinely required the prune.
Deleting one row proven live (`DOS.StringToAtom, content/validation.ex:109`) raises `--skip` from 32 to 33,
so "unchanged at 32 after deleting 32 rows" is a proof and not a tautology.

**The flip-risk judgment was independently re-derived and CONFIRMED.** S1's blobstore waiver rests on an
admin-only reachability verdict. Re-derived from source rather than re-read: `MediaFile.changeset/2` has
exactly one call site; `unique_filename/1` executed against 7 adversarial names lets a separator survive in
zero; `media_files` **is** a copy-strategy bundle member at `catalog.ex:98`; `import_bundle/2`'s sole HTTP
route sits behind `pipe_through([:api, :require_admin])`; no HTTP mint issues `admin`. Every line-number
citation in the two PATH PROVENANCE blocks checks out. **A genuinely independent second reviewer is still
owed before merge** — this is a security waiver, and it asserts the traversal is admin-only, not impossible.

**Three refutations, in the wave-23 spirit.** (1) The wave-23 row `felix-w23-s5-blobstore-migration` asserts
`media_files` is "never bundle-imported" — FALSE, and a waiver built on it would have been wrong; that row
is superseded and its brief now carries a dated correction. (2) The gate's own step comment claimed "15 of
the 31 are the blobstore rows" — `grep -c blobstore api/.sobelow-skips` is **0**, so completing that
migration would have moved the residue by exactly zero. (3) `archive.ex:36 File.read!` was dead by content,
not by annotation — a 33rd finding the brief never named.

**Two deliberate deviations, both measured before deviating and both disclosed.** S4 rebuilt predicate 4:
the briefed literal rule ("every sibling clause needs its own annotation") was *built and run first*, found
8 rows, all 8 read in source, all 8 trivial `, do: :ok` fallbacks — shipping it would have ordered 8 new
blanket waivers onto code with nothing to waive AND left the gate red on arrival. The two-half replacement
is zero on `api/lib` and catches a displacement direction the literal rule misses entirely. S5 widened past
its `files:` list because the dead premise it was sent to kill appeared **three times in the same file**;
fixing §9 alone would have shipped a half-corrected doc a cold agent hits top-down.

**Reviewer fixes, all in place, none a redesign.** S3's `-r` branch: the workflow said the blocking job
carries "BOTH" ratchets when S4 makes it three, so a CI reader hitting `MISSPELL` under a step named *"No
baseline entry duplicates an inline waiver"* had nothing to explain it — both step names corrected (job
`name:` untouched, it is the check context); and `sobelow-baseline-staleness-check.sh`'s header still called
its own run "REPORTING-ONLY", which this slice made false. S5's `-r` branch: one sentence recording that S3
takes the baseline 89 → 57, so the dated reading is not stale the day it merges. S1, S2 and S4 needed
nothing.

**The ledger, honestly.** `guerrilla` was 500ing for much of the build window. S2 and S5 shipped code with
**zero** claims, pulses or stamps — the board read untouched while commits existed; the reviewer claimed
both after recovery and stamped every buildable criterion from re-verified evidence. S4's task did not exist
at all; the builder re-filed it from the dispatch brief and wrote its criteria himself, flagging that
everywhere — the reviewer confirmed post-recovery that no competing Decide row landed. S1 had lapsed back to
`lifecycle=open` with 5/6 stamped and was re-claimed so the board tells the truth. Two wave-23 rows carry
dated corrections: `felix-w23-s5-blobstore-migration` (superseded, refuted claim) and
`felix-w23-bl-staleness-blocking-flip` (paid by S3, but its criterion 2 *contradicts* the measurement —
adjudicate, do not rebuild). `felix-w24-bl-staleness-script-header-stale` was **paid inside PR #7555** and
stamped rather than deferred.

**What the next wave takes, in dispatch order.** Merge round 1 — S4 with or before S3 (the S3 comment
describes S4's ratchet), then S1, S2, S5 in any order. Then `felix-w24-s6-fenced-sixteen` (16 → 0), then
`felix-w24-s7-continue-on-error-flip`, which must **verify before it flips** and publish the remainder if
the exit code is not 0. Then the epic's only P0, `felix-w23-bl-bundle-member-guard` — S1's waiver is a
judgment, not a fix, and nothing today pins the two facts it rests on. Standing risk the fleet must not
learn to shrug at: the staleness flip makes a **line-anchored** check load-bearing, so an inserted comment
above a covered call site reds a blocking job for a non-security reason (`felix-w24-bl-staleness-line-anchor`,
MEASURE-first).

### Wave 2026-07-28 — Wave 23 BUILT + REVIEWED, grade A−. "The Blind Gate."

All four round-1 slices built green, reviewed, gate-re-run on the reviewer's final state, and
**pushed with PRs open** — #6616 S1, #6617 S2, #6618 S3, #6619 S4. Round-2 `felix-w23-s5-blobstore-migration`
is unbuilt BY DESIGN (sequenced-rounds law: it edits `api/.sobelow-skips`, which S1 owns).

**What landed.** S1 (`felix-w23-s1-drift-migration`, branch
`loop-epic/drift-migration-19-sobelow-fingerprints--0`, unchanged by review) migrated the 19 pure
line-drift fingerprints to inline annotations with per-site reachability verdicts; baseline 108 → 89,
shipped-baseline findings 51 → 32. S2 (`felix-w23-s2-staleness-ratchet`, branch
`loop-epic/blocking-baseline-staleness-ratchet-sobe-1-r`) added the orthogonal text-only staleness
ratchet with a DERIVED detector→token table, plus the `parse.ex:61`-exact regex fix that closes an
unsafe-direction bug in the overlap checker. S3 (`felix-w23-s3-amend-d75`, branch
`loop-epic/amend-d75-by-name-floor-is-10-not-0-108--2-r`) amended D75 by name — floor 10 not 0, 108
not 137, and the S4/SR-1 topology proven by the blocking `mix-audit` job being S4-excluded too. S4
(`felix-w23-s4-fresh-guard-selftest`, branch `loop-epic/fresh-finding-guard-selftest-make-the-mu-3`,
unchanged by review) converted the fresh-finding guard from an unattributable exit-status assertion
to a TRANSITION assertion with a mutation-proven `--selftest`.

**REVIEW'S BIGGEST FIND, and the reason this is A− not A.** S2's new step was BLOCKING and the builder
flagged "must merge after S1". Re-measured at review with S1's pruned baseline **and** S1's sources
applied *together*: **31 entries are still stale** — S1's added comment lines shift line numbers
inside the very files it edits, so its 19 deletions do not clear the check. Merging after S1 would
still have turned `sobelow-inline-overlap` — a job that is green and meaningful today — permanently
red on every PR in the repo, reintroducing the exact blind-gate disease the wave exists to cure. Fixed
in place (commit `9ac576278`): the real-baseline step is `continue-on-error: true` with its measured
numbers, a one-line flip condition, and a tracking task; the hermetic `--selftest` stays blocking.
Second review fix (`3f26f57e7`): merge-gates §9 still gave D140's REFUTED toolchain-instability claim
as the reason the sobelow job is advisory, three paragraphs above S3's own amendment — replaced with
the real reason and the real instability (the line number, which is inside the fingerprint hash).

**Independently re-derived at review** (the HIGH-FLIP-RISK protocol): S1's D141(c) transfer proof was
re-run from scratch with a real `mix sobelow` 0.14.1 against two empty-baseline twin trees — 109 → 90,
19 removed / 0 added, and 51 → 32 with the shipped baseline; every number reproduced exactly. The
reachability verdicts were re-derived from source (`validate_slug/1` is the only entry to the
DeployRunner state files; every `fetch/2` call site resolves to a literal; `@allowlist %{}` makes
`delete_allowlist_scoped/3` dead). S2's regex tightening was mutation-proved by reverting it, which
reds the new malformed-annotation fixture. A genuinely INDEPENDENT second reviewer is still owed on
S1's reachability verdicts before merge — that dispatch is a manual lead step.

**On the wish's standing sore.** Main's Sobelow cannot be made honest without a human gate this wave,
and now we know *why* in two independent senses: S3 proved that even a fully drained baseline cannot
make Sobelow block a merge (SR-1 + stage-S4 paths-filter exclusion), and S2's ratchet measured that
the baseline itself is 50/100 dead promises — 31 after S1. The sore is real, it is measured, and it is
now instrumented; it is not closed.

**Ledger.** Honest across all four slices — 4/5 criteria stamped with real evidence, merge-gated
criterion left open, lifecycle `in_progress`. One correction applied: S2's criterion-2 evidence
asserted a blocking step, which review changed; the evidence now carries the correction and the
re-measured 31. Two backlog rows filed at review: `felix-w23-bl-staleness-blocking-flip` (P1, the
flip) and `felix-w23-bl-sobelow-transfer-proof-harness` (P2, filed on behalf of S1's builder, whose
six attempts timed out on `/v1/data/mutate`).

**NEXT WAVE.** Merge in order S1 → S2 → S3 → S4 (S1 first: S2's ratchet reads the baseline S1
prunes), then dispatch `felix-w23-s5-blobstore-migration` — 15 findings, 10 of which are NEW code no
baseline ever reviewed, so it needs FRESH verdicts and is HIGH-FLIP-RISK. After S5 the staleness
residue drops to ~16, and `felix-w23-bl-staleness-blocking-flip` becomes the one row that turns the
new ratchet into a real gate.

- **Wave 23 — 2026-07-28 — DECIDED (building). "The Blind Gate."** Ratified D135–D146. The wave
  repairs the instrument rather than adding one more resource bound: Sobelow's JOB has been
  `failure` on main for **8d17h / ~185 runs** while the workflow rolled up `success`, so the gate
  whose job is finding the NEXT fifty could not report a regression, and 41 findings accumulated
  under that cover. Verification substantially rewrote the direction's causal story and the wave
  followed the evidence: the raw-SQL injection hypothesis is DEAD (`copy_into` quotes at the call
  site, `qi/1` is correct quote-doubling, Honest Gates D30 already ruled these sites and the comment
  fix is already on main), the phantom count is **52 of 108** not 4, and "blocking" is
  STRUCTURALLY impossible inside security.yml (SR-1 live + stage-S4 paths-filter exclusion, proven
  by the blocking `mix-audit` job being excluded too). Verification also found what nobody was
  hunting — GAP A, an execution-proven arbitrary-table write through `import_member/3` that lands an
  attacker-chosen row in `users` — and the wave REFUSED to build it, because D82 fences Felix off
  `tenancy/workspace_bundle` and PDS PR #6551 is open across the same files; it ships as a P0 backlog
  row instead. Hardest call: **green is not reachable this wave** (16 of 51 findings sit in fenced,
  collided files; 1 more is unannotatable), so the wave ships the 34 it may honestly touch, the new
  staleness ratchet, and an amendment to D75 by name — and does not claim green. 4 round-1 slices +
  1 round-2, all opus (fable unavailable), `api/.sobelow-skips` owned by S1 alone. Cross-epic:
  Honest Gates' `hg-bl-sobelow-fingerprint-to-inline-migration` is ADOPTED by name, not re-filed,
  and its sibling `-inline-annotation-reversion` is closed by content (fixed by `c69cc0b1e`/#6412).
  Grade: pending build+review.
- **Wave 22 — 2026-07-23 — BUILT + REVIEWED, grade A. Arm: E (E6+E7 winning recipe — barkpark_web
  resource-bound sweep).** Both round-1 slices built green, reviewed, and re-proven by the
  reviewer's OWN mutations (not just the builders'): S1 claude_chat transport buffer cap
  (`task-felix-w21-bl-claudechat-buffer-parity`, branch
  `loop-epic/claude-chat-transport-buffer-cap-data-ha-0-r`, 129/0 — reviewer re-neutered the cap,
  the named-overflow test went red, restored green) and S2 chat_live streaming display cap
  (`task-felix-w22-chatlive-stream-display-cap`, branch
  `loop-epic/chat-live-streaming-display-cap-stable-b-1-r`, 293/0 — reviewer mutated the byte
  check to `if false`, BOTH new tests red). The D131 HIGH-FLIP-RISK display-only judgment was
  independently re-derived from source by the reviewer (dead `is_binary` turn_completed branch at
  chat_live.ex:1244-1247 — streaming is always nil-or-map; codex durable = Recorder runtime_text,
  recorder.ex:1045-1046 accumulate + persist_runtime_text :1272-1276; claude durable = full-frame
  blocks append :1380-1388, never streaming.text) — but per protocol a genuinely SEPARATE second
  reviewer is still owed before merge. Both slice gates were also re-run green on the INTEGRATED
  tree (both slices' files together — true cross-slice proof). Review fixes: both builders left
  `mix format` violations that would red the CI Format gate (claude_chat.ex overflow send;
  chat_live_test.exs three overlong lines) — formatted on the `-r` branches, gates re-run green
  byte-identical. Ledger clean (honest stamps, merge-gated criteria open, lifecycle
  in_progress). New backlog filed at review: `task-felix-w22-bl-chatlive-overflow-banner` (P4 —
  S1's named :buffer_overflow sink message is swallowed by ChatLive's catch-all; user sees the
  generic DOWN teardown copy). NEXT WAVE: merge both `-r` branches (lead closes the merge-gated
  criteria), then the strongest open vein is `task-felix-w22-bl-recorder-bounds` (P2 — the REAL
  codex durable accumulator, recorder.ex:1046, out of the barkpark_web fence).

- **Wave 22 — 2026-07-23 — DECIDED (building). Arm: E (E6+E7 winning recipe — barkpark_web
  resource-bound sweep).** Ratified D130–D134. Headline: honest census of the 252-file
  barkpark_web tree = exactly TWO unbounded-and-reachable streaming accumulators, both now wave
  slices: the filed W21 claude_chat transport buffer (zero drift, promoted P3→P1 — claude proven
  LIVE in prod: 38/38 chat_sessions provider='claude', 10 active <7d, prod db = barkpark_prod
  not the decoy `barkpark`) and the grep-invisible chat_live advance_streaming sink (run-proven:
  200KB linear growth at 1000 deltas, LiveView WEDGED at 5000 — an independent re-render DoS).
  Digest's "codex persistence rides the sink accumulator" premise REFUTED at verify (dead
  is_binary branch at :1245; Recorder runtime_text is the real durable source, out of fence →
  backlog); S2 reframed display-only, semantics = stable-boundary truncate-with-marker
  (turn-abort rejected), HIGH-FLIP-RISK flagged for independent re-derivation. Gate-baseline
  drift OVERTAKEN at Decide: #5936 landed the Fleet-tab test repair on tip. thinking_pulse
  INERT (D41 probe provenance); channels/Bandit-8MB, Port lifecycle, zero-spawn all re-proven.
  3 backlog children filed. Grade: pending build+review.
- **Wave 21 — 2026-07-23 — BUILT + REVIEWED, grade A. Arm: E (E6+E7 winning recipe — interop
  resource-bound sweep).** Both round-1 slices landed on pushed PR branches, gates re-run green
  at review, mutations independently re-run (S1 cap disabled → the new test REDs with
  `{:error,:timeout}`; S2 yield forced to 60s → exactly the 3 deadline tests RED). S1 codex
  buffer cap (`task-felix-w21-codex-buffer-cap`) — final branch
  `loop-epic/fix-studio-chat-cap-codex-session-line-r-0-r`, one review fix (mix format on
  protocol.ex, would have red the CI format gate); adversarial pass held (post-breach calls hit
  the `%{failure:}` guards, no Port.command-after-close path). S2 DeployRunner ctl deadlines
  (`task-felix-w21-deployrunner-cmd-deadlines`) — final branch
  `loop-epic/fix-sites-bound-deployrunner-control-pla-1`, zero fixes; the HIGH-FLIP-RISK
  happy-path preservation was independently re-derived (all three arms byte-identical on prompt
  return) — the lead still owes the named independent second review at merge per E2. Ledger
  audit clean (zero fixes; 4/5 stamped each, merge criterion honestly open; 5 backlog children
  published). Known residue: S2's line-shift staled ~12 Traversal.FileModule fingerprints for
  deploy_runner.ex in `.sobelow-skips` (advisory gate; owned by
  `task-felix-sobelow-baseline-reconcile`, D41). NEXT: lead merges both PRs after the Elixir
  Test gate (+ closes criterion 4 on both tasks); W22's natural take is
  `task-felix-w21-bl-claudechat-buffer-parity` (P3, S1's overflow/2 is the template), P4 backlog
  as fill. Debrief: paper `felix-pristine-wave-21-2026-07-23`.

- **Wave 21 — 2026-07-23 — DECIDED (building). Arm: E (E6+E7 winning recipe — interop
  resource-bound sweep).** Ratified D125–D129. Headline: the wish's named target
  (`task-felix-interop-resource-bound-sweep`) is SEALED done 6/6 (#2954, W7) and all six W7
  sites verified drift-free — the stale-premise guard fired again; W21 bounds the POST-W7
  generation instead: 2 opus round-1 slices, both fail-before run-proven at Verify (codex
  buffer grew to a literal 8 MiB offline; a sleep-stub systemd_run wedged the DeployRunner
  singleton at 5001ms while safe_call masked it). Census completed to 13 rows (ExPTY
  SURVEYED-AND-EXCLUDED, gen_types.ex OUT-OF-SCOPE). Codex proven DARK on guerrilla (no
  binary, 0/38 sessions) → severity framed as defense-in-depth on the W7 admin-gated
  precedent. Janitor ruled UNBOUNDED-BUT-CONTAINED (rescue does not cover hangs — the
  "already-good-with-rescue" phrasing rejected as dishonest), backlog not build. 5 backlog
  children filed. Grade: pending build+review.
- **Wave 20 — 2026-07-23 — REVIEWED (A, per `felix-pristine-wave-20-2026-07-23`). Arm: E
  (E6+E7 winning recipe, 3rd surface — cloud/ FK-abort refute-and-tripwire).** Both round-1
  slices BUILT, reviewer-verified with ZERO fixes needed, PUSHED with PRs. S1
  `task-felix-w20-fk-census-tripwire` (PR #5920, `loop-epic/cloud-fk-abort-scar-class-closed-as-a-cl-0`):
  `cloud/test/barkpark_cloud/fk_census_test.exs` reflection tripwire — reviewer re-ran the full
  cloud gate green on final state (format + compile --warnings-as-errors + **2209/0**; diagnostic
  24 schemas / 19 belongs_to-bearing / 26 live pg FKs / 27 FK casts, all >=19 floors met,
  non-vacuous) AND independently re-ran the D124 mutation proof: strip `assoc_constraint(:barkpark)`
  → RED `:missing_constraint` for `:barkpark_id`; `name: :env_vars_barkpark_id_WRONG_fkey` → RED
  `:inert_name`; restore → GREEN 5/0 with `git diff cloud/lib` empty. cloud/** open-PR fence
  re-checked empty at PR time. S2 `grb-append-e4-e6-scoreboard-rows` (PR #5921,
  `loop-epic/durable-meter-tally-labeled-computed-e4--1`, research epic task-09f4775e7ccc2cca):
  `tooling/scaffy-duels/tally_wf.py` — reviewer re-ran both tallies reproducing the figures
  byte-exactly (E4 $63.7514 / 62,319,436 all-axis tok / 677 ids / 20 transcripts; E6 $46.6116 /
  38,866,530 / 477 / 24, `<synthetic>` honestly unrated); constants verified against METER.md
  (1.25x/2.00x/0.10x); abcde t4 rows 9+12 + callout `c-e4e6-meter` verified LIVE on guerrilla
  (~23–26x gap over the copied 2.40M/1.72M named, not nudged; per-phase split honestly
  not-attributable — per-model split given). Ledger honest: both tasks in_progress 3/4 with
  merge gates open for the LEAD; D124 backlog children published (devauth-approve P3,
  cloud-testdb-drift P4). W20's own meter row: run
  `python3 tooling/scaffy-duels/tally_wf.py …/subagents/workflows/wf_2c9b2e75-d63` post-wave.
  NEXT: lead merges #5920 (waits on cloud.yml — cloud/ has its own gate, api/ Elixir gate does
  not cover it) + #5921 (tooling-only), closes each merge criterion; sharpest open felix children
  stay the W18 realtime broadcast seal (`task-e98797b38ca3b51e`) + the two W20 backlog tripwires.

- **Wave 20 — 2026-07-23 — DECIDED (building). Arm: E (E6+E7 winning recipe, 3rd surface —
  cloud/ FK-abort sweep).** Ratified D119–D124. Headline: the wish's "~17 unguarded cloud FK
  files" premise DIED pre-build (changeset-granularity census: 19/19 schemas sealed, 0 genuine;
  inert-name class structurally absent; sole bypass unreachable — no user-deletion path exists).
  Wave = refute-and-tripwire: 1 run-proven reflection-test slice making the four-wave manual
  re-census the machine's job (all five failure modes exercised at Verify incl. vacuous-green and
  inert-name reds), + 1 meter-truth slice replacing the unverified 2.40M/1.72M scoreboard figures
  with computed $63.75/62.3M (E4) and $46.61/38.9M (E6) — a 22–26x gap, named not nudged.
  Housekeeping: w18-registry-staleability closed 4/4 on #5917 merge evidence. Grade: pending
  build+review.
- **Wave 19 — 2026-07-23 — REVIEWED (A, per `felix-pristine-wave-19-2026-07-23`). Arm: E (E7 —
  E6 + freshness-gated verify).** All 4 round-1 slices BUILT, reviewer-verified, PUSHED with PRs:
  realtime broadcast field-vis seal (#5914 on `loop-epic/seal-the-realtime-broadcast-card-project-0-r`
  — reviewer INDEPENDENTLY re-derived the 7-field gated set off to_card/4, exact match, and re-ran
  the unthread mutation RED→GREEN; one pre-existing format fix folded), D43 walk.ex StatusVocab
  delegate with the ⠿ still-frame (#5915 — reviewer re-mutated, 3 tests red; golden regen verified
  exactly 2 chip swaps; NOTE: delegation covers all 9 manifest statuses, a documented superset of
  D114's literal 5 — manifest-faithful, ruled correct), bind_assignment_task dataset-row 55P03
  real-drive test (#5916 — reviewer re-ran the FOR-SHARE-delete mutation: "nothing was raised" red,
  restore green 45/0; test file only), cloud registry hardening + folded tier drift (#5917 —
  reviewer re-ran BOTH mutations: put_new revert and tier revert each red exactly their guard;
  105/0). Every gate re-run green on final state. Ledger honest: all 4 tasks in_progress, evidence
  stamped, merge gates open for the LEAD. E7 quality axis: 0 premise failures escaped — both
  verify-SKIPPED slices (S1, S4) survived independent adversarial review with zero functional
  defects; review-repair load = 1 trivial format fix. Token axis awaits the lead's meter read
  (E6 1.72M baseline is lead-supplied provenance per D117). NEXT: lead merges #5914–#5917 (each
  WAITS for the Elixir Test gate; #5917 is cloud/), closes each merge criterion; sharpest open
  children: `felix-w19-bl-authority-lock-remaining-sites` (P3, the other 2 lock sites need their
  own isolable-row analysis), `felix-w19-bl-email-golden-regen-mixtask` (P4), and the research
  epic's `grb-append-e4-e6-scoreboard-rows` + the E7 meter read to finish the experiment row.

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
