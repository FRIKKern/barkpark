# Re-derivation — the build-log BYTES READ door's secret boundary, on the MERGED bytes of #17752

Written 2026-09-11 by `deploy-r11-w12`, the INDEPENDENT reviewer for
`task-3a18bd1e2085aa93` criterion 4. I did not write #17752. Everything below was RUN in a
worktree cut from `origin/main` at `13c5cf13b`; the merge commit under review is
`4a315265b64cef0da0d9f16e77ef3d9a11fe12dc`. Test partition `r11bytesrev`, `CC=/usr/bin/clang`.
The probes in §1b are MINE — none is a fixture vector from the PR, which is the point: a corpus
written by the builder measures the builder's imagination.

This is the READ-side twin of `recorder-write-scrub-secret-boundary-review-2026-09-11.md`
(#17624's write-scrub, D182 shape). That review asked "are the bytes safe by the time they are
durable". This one asks "can bytes reach the wire that were never made safe".

**VERDICT: HOLDS WITH CAVEATS.** Every `log_scrub` gate the PR claims exists, exists and is
load-bearing (three mutations, three reds). The tail cap is real and the whole file demonstrably
never enters memory (a mutation that reads the whole file and emits byte-identical output is
caught). The caveat is that the control plane's own stated doctrine — *"an invariant held
somewhere else is exactly what a byte door must not rely on"* — is implemented on **one of the
five** branches that can put a `tail` on the wire. The other four relay whatever the box sends.
Not reachable with the box merged in the same commit; latent against any other box.

## 0. the tree

    git worktree add …/deploy-r11-bytes-door-review -b deploy/r11-bytes-door-review origin/main
    git rev-parse HEAD                     # 13c5cf13bd1ef3258f94471b675bba6337e31d89
    cd cloud && MIX_ENV=test MIX_TEST_PARTITION=r11bytesrev mix ecto.create && … ecto.migrate
    cd api   && MIX_ENV=test MIX_TEST_PARTITION=r11bytesrev mix ecto.create && … ecto.migrate

## 1. EVERY PATH BY WHICH BYTES REACH THE WIRE

There are exactly two emitters. Nothing else on the new route writes a `tail`.

### 1a. the BOX (api) — gated, on every path

`tail` enters a box response at ONE line: `site_deploy_controller.ex:693`
(`tail: Map.get(record, :tail)`, inside `render_build_log_bytes/2` at `:679`). The map that
reaches it is whatever `DeployRunner.build_log_tail/2` handed back (`deploy_runner.ex:611`):

| branch | carries `:tail`? | gate |
|---|---|---|
| `{:ok, served}` | yes | `serve_tail/1` — the **first clause**, `deploy_runner.ex:632`, is `%{log_scrub: nil} -> {:error, :unscrubbed, record}`. The read at `:653` is *below* it, so unfolded bytes are never opened, let alone rendered. |
| `{:error, :unscrubbed, record}` | no — `record` is `build_record/2` output, which has no `:tail` key; `Map.get` → `nil` | n/a |
| `:evicted` / `:missing` / `:never_recorded` / `:unreadable` | no, same reason | n/a |

And the healing window is closed on the way past, not merely documented:
`build_log_tail/2` reads through `build_record/2` → `heal_unscrubbed_log/1`
(`deploy_runner.ex:530`), so an unstamped record whose log is still on disk is **folded and
re-stamped before `serve_tail/1` ever sees it**. I checked that heal does not defeat the memory
claim: `BuildLogScrub.scrub_file/1` folds through `File.stream!()` line by line
(`build_log_scrub.ex:198`) into a temp file and `rename(2)`s — no whole-file binary, on either
path.

### 1b. the CONTROL PLANE (cloud) — gated on ONE branch of five

`tail` enters a cloud response only through `record/1` (`build_log_bytes.ex:298`, `"tail"` is in
`@bytes_keys` at `:81`). `record/1` is called from five sites:

| # | call site | inspects `log_scrub`? | measured |
|---|---|---|---|
| C1 | `decide_bytes` `{"available", nil, _tail}` — `:252`, then `Map.put(:tail, nil)` at `:257` | **YES** | mutation M3 + M1 below |
| C2 | `decide_bytes` `{"available", _scrub, tail}` 200 — `:259` | n/a (C1 already took the nil case) | — |
| C3 | `decide_bytes` `{"evicted", _scrub, _tail}` — `:276` | no | **P3 — LEAKS** |
| C4 | `decide_bytes` `{state, …} when state in ["missing","never_recorded"]` — `:282` | no | by reading (same shape as C3) |
| C5 | `wire/3` relayed box-`422` — `:153`, and relayed box-`410` — `:159` | no | **P1, P2 — LEAK** |

The three probes (a scratch copy of the PR's own router test module, programming the fake box —
run, then deleted, not committed):

    P1  box answers 422 build_log_unscrubbed WITH a populated tail
        -> 422, body["tail"] = "BARKPARK_TOKEN=bppat_relayed422leak\n"   RELAYED
    P2  box answers 410 evicted WITH a populated tail, log_scrub nil
        -> 410, resp_body contains "bppat_"                              RELAYED
    P3  box answers 200, log_state "evicted", log_scrub nil, tail populated
        -> 410, resp_body contains "bppat_"                              RELAYED
    P4  CONTROL — an operator who is a member of NO team owning the site reads it
        -> 200. The operator gate is global by design; P4 is not a defect, it is
           the proof that P1–P3 ran against a live door and not a 403.

C1 is the branch the PR's prose describes and the branch its test drives. C3/C4/C5 inherit.
This is exactly the inheritance the moduledoc (`build_log_bytes.ex:53-56`) says a byte door must
not do. It is **not reachable today**: the box merged in the same commit puts `tail: nil` on
every refusal (§1a), so no shipped producer emits these shapes. It is a latent gap against a box
running older or newer code — which is the *same* box the PR invokes to justify the tail cap
(`build_log_bytes.ex:86-88`).

## 2. THE AUTH BOUNDARY

The route is `router.ex:9034`, and the gate is `Auth.require_platform_operator(conn, [])` at
`:9035`, evaluated **before** anything else — `auth.ex:424-432`: `require_user`, then
`current_user.email in Notifications.platform_admin_emails()`, else 403. Not team role, not
ability, not a PAT scope: a global allowlist, empty on prod (`gr-ops-platform-admin-emails`), so
the route is 403-dark there. Both arms are tested and both assert the box was never asked
(`router_build_log_bytes_test.exs:379, :399`).

**Does the #17693 team-scoping fix hold for the sub-route?** It is not inherited and does not
need to be, but the mechanism is different and that difference is worth recording. The record
route (`router.ex:9006`) resolves the site through `with_team_site(conn, {:ability, "read"}, …)`,
so `site.id` is *produced by* the team filter and a foreign site is a 404. The bytes route hands
`conn.path_params["id"]` **raw** to `BuildLogBytes.for_deployment/2`, which does an unscoped
`Registry.get_site(site_id)` (`build_log_bytes.ex:110`). Cross-*site* scoping still holds — the
`with` clause at `:111` requires `deployment.site_id == site.id`, so a deployment of another site
is `404 not_found` (tested, `router_build_log_bytes_test.exs:169`) — but there is no team filter
anywhere on this path. A team-scoped principal cannot reach the route at all today, so the
answer to the criterion's question is: **no team-scoped principal can reach another team's
deployment id, because no team-scoped principal can reach the route.** The caveat is that the
day anyone widens this gate the way #17693 widened its sibling, swapping the plug is not enough —
`for_deployment/2` would also have to move to `Registry.get_team_site/2`. Nothing in the code
says so; this ledger does.

## 3. THE TAIL CAP

Two caps, both real, and they are independent rather than one trusting the other.

**Box (`api`).** `@default_max_build_log_tail_bytes 262_144` (`deploy_runner.ex:583`), overridable
by config so a test can drive past it. `read_tail_bytes/2` (`:653`) is `File.open` →
`:file.position(fd, :eof)` for the size → `:file.position(fd, {:eof, -cap})` (`:661`) → one
`IO.binread(fd, cap)` (`:685`). Peak is the cap, whatever the file size. This is **measured, not
read**: the PR's own test samples `:erlang.memory(:binary)` *while the read is in flight*, and my
mutation M6 — insert `File.read!(path)` alongside the seek so the output bytes are **identical**
and only the memory profile changes — reds it:

    binary memory peaked 3995216 bytes above baseline while reading a 4 MB log
    with a 4 KB cap — the file looks to have been read in whole

A residue-based test would have passed that mutation (the test's own moduledoc says an earlier
version did). This one does not. That is the strongest single assertion in the PR.

**Control plane (`cloud`).** `@max_tail_bytes 262_144` (`:89`), applied in `cap_tail/1` (`:312`)
on the way out of `record/1`, so it covers every branch in §1b's table uniformly (verified in
P1: the relayed 422's `tail_bytes` was re-measured at 36, not echoed).

**Can log content forge the truncation marker?** Partly, and it does not matter, because the
marker is not the machine-readable fact:

* `truncated` is **computed**, never content-derived: `capped != tail` (`:323`), a comparison
  against the cap on this end. No byte sequence can make a short tail compare unequal to its own
  capped copy. `tail_bytes` is `byte_size(capped)` (`:322`) — measured off what ships.
* the marker *string* is forgeable in the weak direction only. A build log that literally prints
  `…[truncated by the control plane at 262144 bytes]` produces a response whose `tail` reads as
  truncated while `truncated: false` and `tail_bytes == byte_size(tail)` contradict it. That is a
  log pretending to be *shorter* than it is — it cannot manufacture extra bytes, cannot suppress
  the cap, and cannot move the boundary. Same on the box: `truncation_notice/2` (`:703`) is
  prepended only inside the `total > cap` branch.
* the one field this end takes on trust is the box's own `truncated` flag — `Map.get(rendered,
  :truncated, false) or capped != tail` (`:323`). A box can claim truncation that did not happen.
  A lie toward "there is more", never toward "this is everything". Noted, not filed.

## 4. THE RUNS

All green, in my worktree, one invocation at a time.

    cloud  mix test test/barkpark_cloud/web/router_build_log_bytes_test.exs \
                    test/barkpark_cloud/sites/build_log_bytes_producer_lock_test.exs \
                    test/barkpark_cloud/terminal_write_census_test.exs \
                    test/barkpark_cloud/web/router_head_fence_census_test.exs
           24 tests, 0 failures

    cloud  mix test test/barkpark_cloud/web/router_build_log_bytes_test.exs
           12 tests, 0 failures

    api    mix test test/barkpark_web/controllers/site_deploy_build_log_bytes_test.exs
           12 tests, 0 failures

Those are the four test files #17752 added or changed, plus `cloud/test/support/
sites_fake_box_relay.ex` (a support module, no tests of its own — the producer lock test is what
holds it to the api's real emitter).

## 5. THE MUTATIONS — what the suite catches, and what it does not

Every one applied to the merged bytes, run, then restored from a byte copy; `git status
--porcelain lib/` empty after each.

| # | mutation | result |
|---|---|---|
| M1 | `build_log_bytes.ex:257` — drop `\|> Map.put(:tail, nil)` from C1 | **12 tests, 1 failure** — *"a 200 claiming available bytes with a NULL log_scrub is refused on this end too"*, and it fails on `refute conn.resp_body =~ "bppat_"`, i.e. on the RAW response, not a decoded field |
| M2 | `build_log_bytes.ex:89` — cap `262_144` → `268_435_456` | **12 tests, 1 failure** — *"an oversized tail from the box is truncated with a visible marker"* |
| M3 | `build_log_bytes.ex:252` — make the `{"available", nil, _tail}` clause unmatchable | **12 tests, 1 failure** — same test as M1, from the other direction |
| M4 | `deploy_runner.ex:632` — make `serve_tail`'s `log_scrub: nil` clause unmatchable | **12 tests, 2 failures** — the named refusal test AND *"evicted / never recorded / unscrubbed are three DIFFERENT statuses"* |
| M5 | `deploy_runner.ex:661` — seek `{:eof, -cap}` → `:bof` (serve the HEAD) | **12 tests, 2 failures** — both size-policy tests |
| M6 | `deploy_runner.ex:661` — add `File.read!(path)` beside the seek: **identical output bytes**, whole file in memory | **12 tests, 1 failure** — the PEAK test, with the real number (3,995,216 bytes over baseline) |

**THE GAP THE SUITE DOES NOT CATCH.** There is no mutation for C3/C4/C5 because there is nothing
to mutate — the code was never written. The suite's own relayed-422 test
(`router_build_log_bytes_test.exs:194`) programs the box with `tail: nil`, so it asserts the
status is relayed and never asks what happens when the tail is not. P1/P2/P3 are the arms that
test does not have. An honest reading: the PR proves the *refusal is relayed*; it does not prove
*bytes are withheld on the relayed refusal*, and the two are only the same fact as long as the
box behaves.

## 6. CAVEATS — follow-up candidates (listed, NOT filed)

* **V1 (MEDIUM, latent).** Apply the C1 doctrine to the other four: nil the `tail` in `wire/3`'s
  relayed 422 and 410 (`build_log_bytes.ex:153, :159`), and make `decide_bytes`' `evicted` /
  `missing` / `never_recorded` arms (`:276, :282`) drop a `tail` the box should not have sent —
  or, simplest and strictly stronger, refuse a `tail` anywhere `log_scrub` is nil, once, in
  `record/1`. Three probes (P1–P3) reproduce today against a programmed box.
* **V2 (LOW, documentation-shaped).** `for_deployment/2` resolves the site with an unscoped
  `Registry.get_site/1` while its sibling route resolves through `with_team_site`. Correct under
  a platform-operator gate, wrong the moment that gate is widened. Either move to
  `Registry.get_team_site/2` now or put the dependency in the function's own doc.
* **V3 (LOW).** `log_path` ships to the caller on every shape (`@bytes_keys`, `:82`) — an
  absolute on-box path. Inherited verbatim from the record route, so not new here; recorded
  because a byte door is where path disclosure stops being cosmetic.
* **V4 (TRIVIAL).** The box's `truncated` flag is OR'd in unverified (`:323`). Only permits a
  false "there is more".
* **V5 (carried from the write-side review, unchanged).** R1 there — a credential split by an
  ANSI run survives the fold — is a *write*-boundary residual, and this read door serves exactly
  what the fold left behind. A 200 from this route means "these bytes were folded", never "these
  bytes are clean". Nothing in #17752 claims otherwise; recorded so the two ledgers read as one
  boundary.

## the sentence for criterion 4

> An independent reviewer (`deploy-r11-w12`, not the author) re-derived the secret boundary of
> the BYTES read door on the merged bytes of 4a315265b6, in a worktree off origin/main 13c5cf13b:
> both emitters enumerated to the single line each writes a `tail` on, the box-side gate proved
> load-bearing by mutation (`serve_tail`'s `log_scrub: nil` clause, 12/0 → 12/2), the cap proved
> by a mutation that emits byte-identical output and only changes the memory profile (the PEAK
> test reds at 3,995,216 bytes over baseline), and the auth gate read off `require_platform_operator`
> — VERDICT HOLDS WITH CAVEATS, the caveat being that the control plane's stated "an invariant
> held somewhere else is what a byte door must not rely on" is implemented on ONE of the FIVE
> branches that can put a `tail` on the wire; three probes (P1–P3) relay a programmed box's
> `bppat_` token through the other four. Unreachable with the box merged in the same commit,
> latent against any other, filed here as V1.
