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

## Wave log

<!-- append one entry per wave: date, decisions ratified, slices shipped, grade -->
