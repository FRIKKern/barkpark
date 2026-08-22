# Independent review — the door-vs-unit race (dr-w3-s5 criterion 11, clause B)

- **Reviewer agent:** `dr-w3-s5-door-vs-unit-review`. Did NOT build the slice — no
  authorship in PR #9827, no prior context on it beyond the task row and the
  three sweeps that held it.
- **Date:** 2026-08-22
- **origin/main SHA read:** `97cd39f3225d94e77290ae2772a86b8f61f93714`
- **Payer merge under review:** `ef77af2748ceda54fdd6e078f71a6e6044b55439`
  ("feat(sites): the box refuses at the DOOR with a typed box_at_capacity 409 (#9827)")
- **Arrangement discharged:** the ratified form in
  `dr-w2-v-security-review-arrangement-2026-08-06.md` — a named non-author agent
  re-derives from merged/origin bytes and records the derivation; the LEAD closes.
- **VERDICT: REFUTES.** Clause A (the merge) is proven and untouched. The claim
  clause B exists to test — that the door-vs-unit race is closed — does **not**
  hold on origin/main. The race is real, it is reproduced below on unmodified
  bytes, and it lives on the **production** path.

## Ancestry and drift

    $ git merge-base --is-ancestor ef77af2748ceda54fdd6e078f71a6e6044b55439 origin/main
    $ echo $?
    0

**The tree HAS drifted since 2026-08-06.** `deploy_runner.ex` gained an ETS
census layer (`@census_table`, `publish_census/1`, `note_refusal/0`,
`door_census/0`, `refresh_door_census/1`) feeding `GET /v1/instance/site-deploy`
under deploy-reliability D8.

**The drift did not move the decision.** The ETS table is write-only from the
door's point of view: `box_at_capacity?/2` reads `building_slugs(state)` and
`foreign_build_in_flight?/1`, never `census_get/1`. `publish_census/1` calls the
same `building_slugs/1` and reports it. The census is a *reporting* surface laid
beside the decision, not on it. Everything below is therefore a review of the
same door #9827 shipped.

## The claim under test

#9827's body, line 35, records a derivation and declares it insufficient:

> "The wave reviewer re-derived it independently (the census is inside one
> `handle_call`, so serialization is structural; every `File.read`/`File.stat`
> error arm returns `false`; `takes_build_slot?` is `true` only for
> `mode: :deploy`) and agrees — but this is a manual lead step by charter."

Each leg re-derived from origin/main below.

### Leg 1 — "the census is inside one `handle_call`, so serialization is structural"

**TRUE as stated, and INSUFFICIENT for the question it is offered to answer.**

The serialization is genuine. `start_run/2` is called from exactly ONE site,
`deploy_runner.ex:551`, inside `handle_call({:trigger, …})`; `trigger/1`
(`:384`) is the only public entry and it is a `GenServer.call` via `safe_call/3`;
repo-wide there is a single caller, `site_deploy_controller.ex:87`. So
`drop_stale → running_slug? → box_at_capacity? → start_run` cannot interleave
with another trigger. Trigger-vs-trigger is closed by construction.

**Trigger-vs-trigger is not the race the criterion names.** The criterion names
door-vs-**unit**. `box_at_capacity?/2` never asks "did I already launch
something?" — it asks `building_slugs/1` (`:993-1002`), which on the systemd
path re-derives liveness by shelling out per unit:

    unit_slugs =
      for {slug, %{mode: :deploy} = manifest} <- state.units,
          is_active(manifest.unit_name) in @active_states,
          do: slug

`@active_states` is `~w(active activating reloading)` (`:283`). The manifest IS
in `state.units` — `launch_unit/2` (`:1319`) puts it there synchronously — but
presence is not what is counted. Liveness is re-measured externally, every time.

`systemd_run/3`'s own comment (`:1350`): "`systemd-run` REGISTERS the transient
unit and returns immediately — the build runs detached." The module also already
knows there is a beat before the unit reads active. `@spawn_grace_ms 3_000`
(`:220`) exists for exactly it:

> "After a launch, systemd may report the unit `inactive` for a beat before it
> transitions to `active`."

and `observe_unit/2` (`:1396`) applies a grace for it. **`building_slugs/1`
applies none.** During that beat a unit this BEAM itself launched counts as
zero, and the detached engine has not yet reached `build_gate_acquire` either,
so the /proc/locks second opinion is also empty. Both signals read free while a
build is in flight, and the door admits.

So the primary signal is "in-BEAM" only in the sense that its *call site* is
inside the critical section. Its *data* is an external probe with a fail-open
default — and criterion 2's "race-free by construction" is true of the Port path,
not of this one.

### Leg 2 — "every `File.read`/`File.stat` error arm returns `false`"

**TRUE.** Four arms on the door's path, enumerated, all fail open:

| Site | Arm | Result |
|---|---|---|
| `lock_triple/1` `:905` | `{:error, :enoent}` | `:error` |
| `lock_triple/1` `:920` | `{:error, reason}` | log + `:error` |
| `foreign_build_in_flight?/1` `:1041` | `{:error, :enoent}` | `false` |
| `foreign_build_in_flight?/1` `:1046` | `{:error, reason}` | log + `false` |

`:error` from `lock_triple/1` is mapped to `false` at its only call site
(`:1024`). No arm returns anything else, and none raises. Leg 2 stands.

### Leg 3 — "`takes_build_slot?` is `true` only for `mode: :deploy`"

**TRUE today, with a residual.** `deploy_runner.ex:987-988`:

    defp takes_build_slot?(%DeployRequest{mode: :deploy}), do: true
    defp takes_build_slot?(%DeployRequest{}), do: false

`mode` is a CLOSED enum validated at the boundary — `DeployRequest.validate_mode/1`
admits only `"deploy"`/`"rollback"`/`"teardown"` and 400s everything else — so
today the catch-all can only ever match `:rollback` or `:teardown`, which is
correct (neither takes the build gate).

**The residual:** the catch-all is a *default-false*. A fourth mode added to the
enum later — one that does build — silently takes no slot and is never refused,
with no compiler warning and no test red. The safer shape is to enumerate the
non-building modes and let a new one fail loudly. Not a defect today; a
fail-open by default that a future enum widening turns into one.

## The direct question: can a unit start between the door's check and the door's decision?

**Within one `handle_call`, no — and that is the wrong framing.** The check IS
the decision; no trigger interleaves. The real gap is on the other side: a unit
the door **already admitted** stays invisible to the **next** door decision for
as long as it takes `systemctl is-active` to report it, and for as long as it
takes the detached engine to reach `build_gate_acquire`. In that window the box
admits a second concurrent build.

### Why the shipped suite cannot see it

- `config/test.exs:223` pins `runner_mode: :port`. The door's own concurrency
  test ("two triggers RACING from separate processes", `deploy_runner_test.exs:252`)
  inherits it and passes `put_cfg(enabled: true, command: …)` with no
  `runner_mode` override.
- On the Port path `open_port_and_record/2` (`:1898`) writes `state: :running`
  into `state.runs` **synchronously**, so `building_slugs/1` sees it with no
  external probe. The race genuinely cannot occur there. That test is correct
  about the path it drives.
- Production takes the other path: `config/config.exs` sets `runner_mode: :auto`,
  which resolves to `:systemd` whenever `systemd-run` is on the box.
  `config/test.exs`'s own comment says so — it pins `:port` precisely because
  `:auto` "would flip to the systemd transient-unit path on any host where
  `systemd-run` happens to resolve."
- Every existing systemd-path test uses `fake_systemd_run/1`, whose own comment
  states it "Runs SYNCHRONOUSLY … the 'unit' simply completes before the call
  returns." No existing test ever holds a live unit across a second trigger.

This is the "present but deliberately unable to fail" shape: the green
concurrency test exercises the one path on which the race does not exist.

## Cases DRIVEN — new file, systemd path, faithful launcher

`api/test/barkpark/sites/deploy_runner_door_vs_unit_review_test.exs`. Drives
`runner_mode: :systemd` with `detaching_systemd_run/0` — a launcher faithful to
the real one: it registers, backgrounds the engine, and returns 0 immediately.
`proc_locks_path` points at an empty file, faithful to the window under test
(the detached engine has not reached `build_gate_acquire`).

    $ cd api && CC=/usr/bin/cc MIX_ENV=test mix test \
        test/barkpark/sites/deploy_runner_door_vs_unit_review_test.exs --seed 0
    3 tests, 0 failures

- **CONTROL** — with `is_active` reporting the launched unit `active`, the second
  deploy IS refused `{:error, :box_at_capacity}`. Without this the race test
  below would be indistinguishable from plumbing that never reaches the door.
- **RACE** — with `is_active` reporting `inactive` (the beat `@spawn_grace_ms`
  names verbatim), `dvu-alpha` is admitted and tracked (`status.state == :running`),
  and `dvu-beta` is **also admitted** — `{:ok, :started}`, not `box_at_capacity`.
- **COST** — the un-refused second deploy carries a prebuilt artifact and
  `dvu-cost-beta.prebuilt` exists on disk afterwards. The box paid
  `ingest_prebuilt`'s extraction for a deploy the door was supposed to decline —
  the exact D86/D87 cost criterion 1 pins on the refused path.

## MUTATION PROOF — the green is not vacuous

The assertions are load-bearing on `building_slugs/1` and nothing else. Applied
the candidate fix on origin/main bytes — one clause, using the module's OWN
existing helper:

    -          is_active(manifest.unit_name) in @active_states,
    +          is_active(manifest.unit_name) in @active_states or within_spawn_grace?(manifest),

Both race tests flip, and they flip **at the second trigger** — the criterion's
contract restored:

    $ MIX_ENV=test mix test …deploy_runner_door_vs_unit_review_test.exs:88
    1) RACE: a unit this BEAM just launched is INVISIBLE to the door …
       code:  assert DeployRunner.trigger(req("dvu-beta")) == {:ok, :started}
       left:  {:error, :box_at_capacity}
       right: {:ok, :started}
       stacktrace: …_test.exs:114

    $ MIX_ENV=test mix test …deploy_runner_door_vs_unit_review_test.exs:117
    1) COST: the un-refused second deploy PAYS ingest_prebuilt …
       code:  assert DeployRunner.trigger(req("dvu-cost-beta", …)) == {:ok, :started}
       left:  {:error, :box_at_capacity}
       right: {:ok, :started}
       stacktrace: …_test.exs:133

(Run one test per BEAM: the Runner is a singleton and units tracked by an
earlier test in the same run are still inside the grace, which reds the *first*
trigger instead and reads as a muddier failure.)

**The fix is NOT free — measured, not assumed.** The same one-clause mutation
reds 16 of the existing 84 `deploy_runner_test.exs` tests, because a blanket
3s grace on every tracked unit refuses legitimate back-to-back deploys. Whoever
lands a real fix must scope the grace (e.g. only while the manifest has produced
no output yet — `no_output_yet?/1` already exists and `observe_unit/2` already
pairs the two) and re-run the suite. Recording this so the next agent does not
ship the one-liner and discover the blast radius in CI.

**Restored.** `deploy_runner.ex` is byte-identical to origin/main:

    $ git diff --stat origin/main -- api/lib/barkpark/sites/deploy_runner.ex
    (empty)
    $ git status --porcelain
    ?? api/test/barkpark/sites/deploy_runner_door_vs_unit_review_test.exs

**Baseline re-verified on pristine bytes** — criterion 10's own command plus this
file, all green together:

    $ cd api && CC=/usr/bin/cc MIX_ENV=test mix test \
        test/barkpark/sites/deploy_runner_test.exs \
        test/barkpark_web/contract/error_code_coverage_test.exs \
        test/barkpark/sites/deploy_runner_door_vs_unit_review_test.exs
    89 tests, 0 failures

## Severity — stated honestly, neither inflated nor waved off

This is **not** a corruption or data-loss hazard. The engine's in-engine
`build_gate_acquire` with its `flock -w 900` is retained unchanged (criterion 5)
and still serializes the actual build. What the second admitted deploy gets is a
unit that blocks in `flock -w 900`.

That is precisely the outcome the door was built to prevent. `trigger/1`'s own
`@doc` says so: a second deploy is refused "because the engine would otherwise
queue that build inside its unit for up to 900s and read as a hang." So the
defect is bounded and real: on the production path, in the launch window, the
box does the thing the door exists to stop, and pays `ingest_prebuilt`'s
extraction to do it.

Two further honest notes on the same signal:

- `is_active/1` degrades to `"unknown"` on a `bounded_cmd` timeout or a missing
  `systemctl` — not in `@active_states`, so **not counted**. On a box whose
  systemd is slow or wedged (the D113 scenario the census exists to report) the
  door reads zero in flight and admits everything. Fail-open, consistent with
  the module's stated "every uncertain case ADMITS," but it means the primary
  signal has no floor.
- The counting choice is deliberate, not an oversight: counting `state.units`
  membership alone would pin a unit that finished outside the Runner's view as
  in-flight forever, which the `@default_census_interval_ms` comment names. The
  door trades race-freedom for staleness-freedom. That is a defensible design
  call — it is just not the one #9827's body claims to have made.

## What this review does NOT cover

- The four producers a census cannot see (criterion 8: hand-run `site-deploy.sh`,
  the shared lock across two engine command families, rollback/teardown, and the
  node engine releasing the slot before HEALTH boots) — already named in the PR
  body and not re-derived here.
- Criteria 0-10. Clause A of criterion 11 (the merge and its four required
  contexts) is proven and is not disturbed by this finding.
- Whether the residual on `takes_build_slot?/1`'s default-false catch-all is
  worth changing today. It is a shape note, not a live defect.

## Recommendation to the lead

Criterion 11's clause B is now **discharged as a review** — it was performed, and
it reached a verdict. The verdict is REFUTES, so closing criterion 11 as `met`
on the strength of "an independent review happened" would invert what the review
found. Two honest dispositions, lead's call:

1. Close criterion 11 recording the review as DONE with verdict REFUTES, and
   file the door-vs-unit gap as its own follow-up row (it is a distinct defect
   with a distinct fix and a measured 16-test blast radius); or
2. Leave criterion 11 open and let the follow-up row close it.

I have deliberately **not** stamped criterion 11. The three sweeps
(`dr-w8-stamp-audit-…:49`, `dr-w13-closable-…:75`, `dr-w19-s6-…:158`) held this
row for the lead; the missing step was the derivation, not the stamp.
