# API controller + plug correctness — epic charter

Epic task: `api-controller-plug-correctness-audit`
Charter owner: this file. One charter per epic (repo convention, ~90 siblings in `.claude/workflows/`).

## Vision

Close whole CLASSES of controller/plug correctness defect, not one instance at a
time. A wave here is finished when every member of the class it named is either
fixed with a proof that could have failed, or **cited safe with the mechanism
written down** — so the next reader does not re-derive it. A refusal to
manufacture a finding is a first-class deliverable of this epic, not a shortfall.

The current class is **ETS-backed admission bounds**: in-memory tables that decide
whether a caller is admitted or refused. Four distinct failure modes have now been
named across the epic's waves, and PR #12579 fixed only the first:

| # | Failure mode | Where | Status |
|---|---|---|---|
| 1 | lost update (`:ets.lookup` → unconditional `:ets.insert`) | `api/lib/barkpark/rate_limiter.ex` | FIXED, #12579 (`e45f1377bb`) |
| 2 | bound-reset-by-sweep (`/=` guard deletes a NEWER window) | both cloud limiters | wave 3 |
| 3 | ticket-then-count | `/v1/graph` slot acquire | CITED SAFE (proof below) |
| 4 | TTL-reap-of-a-live-holder | `/v1/graph` slot sweep | wave 3 |

Naming modes 2, 3 and 4 is what closes the class. Mirroring #12579's match spec
onto every sibling would have shipped a regression — that is the epic's standing
warning about pattern-fidelity over code-fidelity.

## Decisions

**D1 — The wave's own premise is dead, and the charter records that rather than
quietly working around it.** None of the four named siblings contains #12579's
`:ets.lookup` → unconditional `:ets.insert`. *Why: fidelity to a premise the code
refutes is not fidelity.*

**D2 — Do NOT port `select_replace` CAS onto either cloud limiter.** Both commit
with `:ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0})` —
an atomic, isolated read-modify-write with default seed, which is the primitive
#12579's own commit message says it wished it could use. *Why: replacing a
correct lock-free atomic with an optimistic loop plus a retry-exhaustion arm adds
a false-refusal mode and closes nothing.* Proven by run: 50 barrier-released
procs × 200 rounds × 5 table-option sets (incl. `write_concurrency` and
`decentralized_counters`) recorded **zero** lost updates; an admission sim at
limit 10 / 200 callers admitted exactly 10 every round.

**D3 — The crown is the stale-window sweep that runs one line ABOVE the atomic
increment.** Both limiters run
`:ets.select_delete(@table, [{{{key, :"$1"}, :_}, [{:"/=", :"$1", window}], [true]}])`
before committing. The guard is `/=`, not `<`, so a caller carrying a window-W
view deletes window W+1's counter — including an EXHAUSTED one — and the next
W+1 caller is re-seeded at 1 and admitted. *Why: fail-open, on the unauthenticated
register/start/poll/oauth_exchange paths.*

**D4 — The fix is one match-spec token per module: `{:"/=", …}` → `{:<, …}`.**
No new mechanism, no GenServer, no shared abstraction, no change to any limit,
window, burst, refill or `retry_after` derivation. *Why: semantics are then
preserved BY CONSTRUCTION — the diff's own context lines are the proof — and the
narrowing makes each file agree with the comment sitting directly above it.*

**D5 — Severity is stated as BOUNDED, in the write-up and in the task.** Each
straddle event costs at most `+limit` extra admissions (30 on `register:`, 5 on
2FA) before the counter refills; it is a repeatable fail-open primitive, not an
erased budget. *Why: an overstated severity is the thing an independent reviewer
kills the fix over, and the mechanism is strong enough without inflation.*

**D6 — The NTP-step vector is NOT claimed as proven, and the reason is recorded
because two verifiers disagreed.** `cloud/Dockerfile:19` pins OTP 27, whose ERTS
default is `multi_time_warp` (measured: `time_warp_mode=multi_time_warp`), and no
`vm.args` / rel overlay / `ERL_FLAGS` exists under `cloud/` or `deploy/`. That
makes a backwards wall-clock step PLAUSIBLE, not observed — nobody stepped a host
clock. The mechanism the fix rests on needs no clock step at all: a sub-millisecond
preemption gap across a 60s boundary suffices, wider on the device-auth limiter
because `limit_for/1` runs a `String.split` before the sweep. *Why: the fix stands
on the narrow, proven vector; the wide, unproven one is quoted at its real strength.*

**D7 — NO window-source change. `retry_after` may not be re-clocked.** Sourcing
`window` from monotonic time while `now_ms` stays wall-clock collapses every 429
to the `max(1)` floor of `1`, and only ONE surface in the whole tree can see it:
the unit file's exact-integer pins. The router test's `1..60` bound accepts 1; the
SPA's `tfaRetryAfterSecs` accepts 1 as a legitimate hint and thereby SUPPRESSES the
60s fallback that exists to stop a re-fire into the same 429. *Why: a silent
regression guarded by three assertions in a file the wave promises not to touch is
not a fix, it is a trap.* Corollary: those pins at
`cloud/test/barkpark_cloud/two_factor_rate_limiter_test.exs:25,64-71` are a
load-bearing guard — never relax them to accommodate a change.

**D8 — No shared `AdmissionBound` module.** `api/` and `cloud/` are separate mix
projects with no shared dependency, and `DeviceAuth.RateLimiter` returns a bare
`{:error, :rate_limited}` with no `retry_after` at all while the 2FA limiter
returns `{:error, {:rate_limited, secs}}`. *Why: "one module" would be two
implementations wearing one name, and a new abstraction is exactly the new
mechanism this class forbids.*

**D9 — NO twin-harness module for the cloud limiters, and that is a positive
finding.** `check/2` takes `now_ms` as an ordinary argument with a default, so the
straddle is three sequential calls in ONE process — zero concurrency, zero sleeps,
zero measured distribution. The probe therefore drives the SHIPPING function on the
SHIPPING table. *Why: a twin proves a COPY misbehaves; this proves the original
does. Adding a twin here would weaken the evidence and add a second body to keep in
sync.* #12579 needed its barrier + yield-widened twin only because its defect was
contention-dependent; what transfers is the DISCIPLINE (red before green, assert the
deterministic thing, report the probabilistic one), not the machinery.

**D10 — Retry/exhaustion cost is N/A and the charter says so rather than inventing
a number.** The `<` narrowing introduces no retry loop and no exhaustion arm, so
there is no distribution to quote. *Why: that absence is itself the argument for
preferring it over a ported CAS.*

**D11 — `/v1/graph` slot ACQUIRE is CITED SAFE, with the proof, not a shrug.** The
row is inserted (`:ets.insert(@graph_corpus_slots, {ref, self(), deadline})`)
BEFORE `:ets.info(:size)` is read, and rows are keyed by `make_ref()` into a `:set`,
so the caller with the LATEST admission instant necessarily observed a table already
containing itself and every concurrent racer — size ≥ cap+1, so it refuses.
Saturation races resolve toward REFUSAL. *Why: the in-tree comment already claims
this and the claim is TRUE; over-admission enters only through a third-party delete.*

**D12 — The `/v1/graph` fail-open is the TTL arm, and the fix is dead-owners-only.**
`deadline <= now or not Process.alive?(pid)` frees the slot of a LIVE, still-deriving
holder; the next acquire sees an emptied table and admits, and it REFILLS without
limit (effective concurrency ≈ ceil(duration / 60s) × cap, self-amplifying).
Reap on `not Process.alive?(pid)` alone. *Why: every exit the in-tree comment cites
is already covered — ordinary exits and RAISES by the lexical `try/after` (proven:
`after` RUNS on a raise), kills by the alive? arm (proven: `after` does NOT run on
`Process.exit(pid, :kill)`, so the alive? arm is load-bearing and must survive).
The deadline arm reclaims nothing the alive? arm would not, and it alone creates
the over-admission.*

**D13 — The dead-only trade is FILED, not built.** Dead-only leaves an
alive-but-permanently-wedged holder holding its slot forever: capacity loss,
fail-CLOSED. Nothing in `api/config` bounds handler wall time — Ecto's 15s
per-query default bounds only the DB half, and the in-memory node/edge dedup pass
has no ceiling at all. The alternative (kill the owner, then delete the row) is a
new mechanism with real blast radius and is rejected for this wave. *Why: a
spurious 503 is this cap's own stated safe error; erasing the bound is not.*

**D14 — No new config accessor for `@graph_corpus_slot_ttl_ms`.** The slot table is
`[:named_table, :public, :set]` and rows are plain `{ref, pid, deadline}`, so a test
seeds a past-deadline live-owner row directly. *Why: under HIGH-FLIP the diff should
add zero public surface; the seam already exists.* The TTL stays the only one of the
four graph ceilings without an `Application.get_env` accessor, deliberately.

**D15 — `RequestStats` is SAFE-BY-PURPOSE, argued on CORRECTNESS grounds and never
by citing the Felix already-good stamp.** Its key is
`{System.monotonic_time(:millisecond), System.unique_integer([:monotonic])}` into an
`:ordered_set` with no preceding lookup — collision-free, no read-modify-write — and
its only reader `json/2`s the result without branching; the off-box chain
(Go agent → `Usage.telemetry_threshold_meter(…, nil, …)`) carries `quota: nil` and
tints without enforcing. *Why: Felix graded it on OTP/throughput grounds, which is
the exact reading a prior wave overturned for the api RateLimiter — a safe verdict
resting on a discredited kind of argument is worthless.*

**D16 — No fifth ETS admission bound exists; the census is closed by run.** 85
`:ets.` mentions across 14 files in `api/lib` + `cloud/lib`; `git grep -nF ':"/="'`
over both trees returns EXACTLY the two known lines. `ReplayRing.put/3` IS a genuine
lookup-then-insert RMW (32 writers × 200 rounds: 200/200 rounds lost entries) but is
serialized by the unique `SessionRegistry`, and the "registry restarts, sessions live
on unregistered" escape is refuted by mechanism — `Registry` LINKS every registrant
to its partition, so a partition crash kills its registrants. *Why: the class claim
"lost-update exists in exactly one place, already fixed" needs a census, not a hope.*

**D17 — This epic gets its OWN charter file, not `bp-cloud-epic-charter.md`.** That
file is another epic's memory, is uncommitted-modified in the shared primary checkout,
and is contended by 13 open PRs. *Why: one charter per epic is the repo convention
(~90 siblings), and appending here would both clobber a concurrent session's work and
guarantee the recurring 13-way conflict.*

**D18 — Prior verdicts are NARROWED, never overturned.** The earlier wave's D20
("both cloud limiters already increment atomically") examined the INCREMENT only and
never looked at the preceding sweep. The crown is DISJOINT from D20. *Why: attacking
a correct verdict by name would put a false retraction on the ledger.*

**D19 — Two findings are already OPEN ledger rows and this wave CLOSES them rather
than re-filing.** `acpc-bl-ets-bound-class-census-residues` (criterion 0 = the sweep
resets, criterion 1 = the lazy request-path `:ets.new`, criterion 2 = the corrected
census) and `acpc-bl-graph-corpus-ttl-sweep-frees-live-slots`. *Why: re-filing a
finding a prior wave already named is the duplication this epic has hit before.*
Criterion 2 of the residues row is worded perpetually ("any future sweep re-derives…")
and can never be definitively met — it is discharged by D16's census evidence, or the
row hangs open forever on a criterion no wave can satisfy.

**D20 — The must-run cloud test set is ELEVEN files, not the eight the brief named.**
`grep -rln "TwoFactorRateLimiter\|DeviceAuth.RateLimiter" test/ lib/` returns eleven;
the three omitted include `router_test.exs`, at 173 tests the biggest consumer of both
limiters. Full baseline **273 tests, 0 failures**, dry-run in this checkout.
*Why: an incomplete must-run list leaves the largest consumer unproven.*

**D21 — A fresh worktree cannot run the cloud suite as the brief wrote it.**
`mix ecto.create` errors with `Can't continue due to errors on dependencies` before
`mix deps.get`, and without `MIX_TEST_PARTITION` + `ecto.create`/`ecto.migrate` the
boot dies on Oban with a `DBConnection.ConnectionError` that reads like an app bug.
*Why: a builder who hits this cold misdiagnoses an environment gap as a real failure.*

**D22 — CI cost is accepted, not optimised around.** `CONSOLE_PATHS` contains
`cloud/lib/**` (deliberate, wave-30 S1, "the cost is real and accepted"), so ANY
cloud limiter edit drags three real-Chrome jobs behind the REQUIRED Console gate.
*Why: narrowing that path set would re-litigate a settled ruling; the correct
response is to expect Chrome flake and re-run, not to widen this wave's fence.*
Corollary: split the cloud slice from the api slices so the api half stays cheap.

## Roadmap

Wave 3 (this wave) — three slices, all round 1, all dependency-free and
file-disjoint.

| # | Slice | Size | Model | Surface | Task |
|---|---|---|---|---|---|
| S1 | Cloud limiters: narrow the stale-window sweep to strictly-older | small | fable | `cloud/lib` (2 files) + 1 new cloud test | `acpc-w3-cloud-sweep-guard-strictly-older` |
| S2 | `/v1/graph` slot cap: reap dead owners only, plus the lazy-`:ets.new` residue | small | fable | `api/lib/…/tasks_controller.ex` + 1 new api test | `acpc-w3-graph-ttl-reap-dead-only` |
| S3 | `RequestStats`: record the CITED SAFE argument at the site | small | opus | `api/lib/barkpark_web/request_stats.ex` | `acpc-w3-request-stats-cited-safe` |

Both S1 and S2 are HIGH-FLIP-RISK (auth-adjacent flood defence; an admission bound
under the load it exists to shed). An independent second reviewer must re-derive
the atomicity argument AND the preserved-semantics argument for each before merge.

Beyond this wave, filed as published children and NOT built here: the `poll:`
attacker-chosen-key unbounded ETS growth (the fifth failure mode — key-space, not
over-admission), the untested `ReplayRing` single-writer invariant, the per-IP
buckets on two session-authenticated routes, and D13's wedged-live-holder residue.

## Wave log

_(empty — the lead appends one line per merged wave)_
