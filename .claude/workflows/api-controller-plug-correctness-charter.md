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

**D18 — Prior verdicts are NARROWED, never overturned.** D89
("both cloud limiters already increment atomically") examined the INCREMENT only and
never looked at the preceding sweep. The crown is DISJOINT from D89. *Why: attacking
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

### Wave 4 — clock semantics (D23–D57)

- **D23 — The census counting rule is DECISION-SITES-ONLY: 505 censused, 383 dropped, 120 survivors, 4 fenced.** Why: it is the only rule a reader can re-derive from a single grep, and it keeps the class-A ledger to 83 DateTime rows instead of 120 near-duplicate mint/verify pairs.
- **D24 — `session_controller.ex:346` is CLASS A, not class B; the strategic direction was wrong and three independent reviewers said so.** Why: `at` is written at `:189` on a DIFFERENT earlier request and round-trips through the signed session cookie, so the gate compares a clock against a TRANSMITTED instant — verbatim the class-A definition. Filing it class B would invite a monotonic re-source of a cross-request instant, which is precisely the damage this epic exists to prevent.
- **D25 — SIDEDNESS IS ORTHOGONAL TO A/B/C/D, and the family splits on SHAPE, not class.** RECENCY predicates ("did X happen recently?", anchored on a stamp of a PAST event where a future anchor is nonsense) can carry a floor and fail closed cheaply. DEADLINE predicates ("has the deadline passed?", where a future value is the entire point) cannot — a floor there has no second anchor and its fail-closed direction is a simultaneous mass logout for zero security gain. Why: this distinction is what makes the fix safe; without it "make the family consistent" would harden seven correctly-class-A TTLs into a logout storm.
- **D26 — FIX the two RECENCY predicates with a FLOOR, not with `abs()`.** `session_controller.ex:346` and `user_session.ex:174` `mfa_fresh?/3` both accept an anchor later than `now`; a ConnCase probe on UNFIXED origin/main drove `studio_mfa_at = now + 100_000` and got `status=302 location=["/studio"] user_session_minted=true`. Why a floor and not `abs()`: all three two-sided `abs()` gates in the repo guard a REMOTE-SUPPLIED timestamp from an inbound signature header, where two-sidedness is mandatory because a remote can sign an arbitrary future `t`. `at` is server-written and signed. Adopting the remote-tolerance idiom on a server-stored gate would break the rule the other 18 one-sided gates follow; a floor rejects a nonsensical anchor without claiming the input is untrusted. Why fix both and not one: hardening the controller alone leaves `mfa_fresh?` incoherent, and `plugs/require_recent_mfa.ex:35` is the only enforcement reader of `mfa_verified_at`, so hardening `mfa_fresh?` covers every enforcement path at once.
- **D27 — The MFA finding is a HARDENING, not a bug, and the Paper says so in those words.** Why: no attacker-supplied value is involved; the exposure requires a genuine backward OS clock step on the api node, and the pending marker only attests "the password was correct" — `mfa_factor_ok?/2` still demands a live TOTP or a burned recovery code. The honest severity is defence-in-depth erosion, not auth bypass, and overstating it would forfeit the epic's credibility on every other refusal.
- **D28 — The argument-by-asymmetry the direction leaned on does NOT survive, and the charter records that rather than quietly dropping it.** Why: the three `abs()` gates differ from the MFA gate by INPUT TRUST, not by one site being sloppy. The fix stands on its own run-proven consequence; it must never be argued from "the repo norm is two-sided."
- **D29 — Yesterday's sibling paper `api-auth-accounts-correctness-wave-2026-08-18` cites this family "SAFE", and the Paper must scope that verdict explicitly or it reads as a contradiction.** Why: that verdict is on the BOUNDARY-INCLUSIVITY axis (`!= :lt` vs `== :lt`) and its 12-site DateTime family does not include `session_controller.ex:346` (integer arithmetic, not `DateTime.compare`). Under a backward step `mfa_fresh?` is fail-OPEN, so the prior row is not a refutation — but a reviewer who finds it first will reject this finding as already-cleared.
- **D30 — api's equality-CAS TOTP replay floor is REFUTED and CITED SAFE. No fix ships.** Why: acceptance requires `floor(now/30) > floor(since/30)` because NimbleTOTP's `:since` reuse gate (`nimble_totp.ex:251-252`) is STRICT at step granularity and runs BEFORE the write, which arithmetically implies `now > since`. An exhaustive 121x121 sweep found the accepted-with-`time <= since` set EMPTY, and an end-to-end probe with the floor forced 600s into the future returned `:error` with the stored floor byte-identical. A rewound clock fails CLOSED. The missing ordering predicate in `cas_last_totp/2` is REDUNDANT, not absent-and-dangerous, and shipping `u.last_totp_at < ^now` would mean claiming a defect that does not exist.
- **D31 — But D30's invariant is enforced by a DEPENDENCY's internals, so the coupling gets recorded at the site and a tripwire is filed.** Why: a `nimble_totp` bump, or anyone adding a `time:` opt or dropping `since:` from `totp_opts/1`, silently converts the redundant CAS into the real defect. The durable artifact is one line of recorded coupling, not a code change.
- **D32 — Class D earned ONE fix, and it goes the opposite way from every reflex: `cloud/.../sites/deploy.ex:337` swaps `System.unique_integer([:positive, :monotonic])` for `System.system_time()`.** Why: three in-repo moduledocs (`sheets/session.ex:481`, `fleet_hub.ex:35`, `sheet_grid.ex:1730`) explicitly REJECT that primitive for this exact fence because it restarts with the BEAM, and `deploy.ex:337` is the single site in the repo that violates its own stated rule. Probed L1: three fresh VMs each returned `1`, and `[:positive, :monotonic]` is a SEPARATE sequence from bare `[:positive]`, so the Nth prebuilt mint since boot deterministically gets nonce N — the overlap is guaranteed, not improbable.
- **D33 — site-spawner charter D87's shape is honoured by changing the SOURCE, never the KEY; and #12628's "tolerate the duplicate" shape is CONTRAINDICATED here.** Why: site-spawner charter D87 requires prebuilt's `{:duplicate,…}` be "structurally unreachable" and requires a nonce key distinct from `force`'s — the swap keeps both. Tolerating the duplicate cannot work because `recover_conflict/3` reaches that tuple by TWO lookups (a repeat build_id AND the deploy-truth-W1 active-production coalesce), cannot tell them apart, and `router_sites_test.exs:2678` asserts the coalesce as INTENDED. Any diff that merges `:prebuilt_nonce` and `:force_nonce` into one key is the site-spawner charter D86 violation.
- **D34 — The prebuilt fix needs a ONE-LINE SEAM or its test is vacuous, and the charter budgets for it.** Why: the nonce is invisible through `build_id/5` (a hash) and no restart can be staged in `mix test`, so every assertion available on today's surface passes on unfixed code — `refute n1 == n2` is same-VM and already true. The deciding assertion is a VALUE-DOMAIN one (`> 1_000_000_000_000`), which fails on `1` and passes on ~1.787e18. One named function is not a new time-abstraction module.
- **D35 — `github/client.ex:340` gets an upper clamp on BOTH arms of `retry_after_seconds`, via one `min/2` on the return value.** Why: the trace to the end proved there is NO downstream cap — Oban's `snooze_job` does `inc: [max_attempts: 1]` so a snooze never consumes an attempt, `Period.is_seconds` accepts any non-negative integer, and the Pruner deletes only `completed`/`cancelled`/`discarded` so a parked `scheduled` row leaks forever. Three of four sibling backoff parsers clamp; the one that does not is the only one that reads a clock.
- **D36 — That site is CLASS A with a time-as-INPUT defect, NOT class B, and the label is load-bearing.** Why: `x-ratelimit-reset` is an absolute epoch instant transmitted by the peer, so subtracting local wall clock from it is the ONLY correct computation and monotonic is meaningless against GitHub's epoch. If the Paper files it class B, a later sweep "fixing" it by re-sourcing to monotonic breaks the computation outright.
- **D37 — Severity for D35 is AVAILABILITY / row-leak, ranked below every auth finding, and the Paper says so.** Why: the `unique` clause is `period: 60` against `inserted_at`, so a parked job stops blocking re-enqueues after 60s and level-triggered reconcile converges — mirroring is not dead. What leaks is one never-pruned `scheduled` row per parked attempt. No caller can influence the timing: the API base is app-env only.
- **D38 — The forward-step residual at that site is NAMED, not silently bundled.** Why: local clock ahead of `reset` floors to 0, `{:snooze, max(s || 0, 1)}` turns that into 1s, and because snooze bumps `max_attempts` the loop never exhausts — a perpetual 1s-interval hammer. An upper clamp does not fix it. Scoping it out keeps the fix minimal and semantics-preserving; hiding it would be dishonest.
- **D39 — `paper_revision_headers.ex:177` is the ONLY class-C site outside the fence and it is CITED, not fixed. The class-C column reads "1 censused, 1 cited, 0 fixed."** Why: the bucket keys NO shared mutable state (private `weak_etag/1`, single caller, value interpolated into a response header and discarded), so #12628's stale-writer-deletes-a-newer-bucket shape has no analogue and a boundary straddle costs one extra full 200. A client cannot forge an older bucket — `If-None-Match` candidates are weak-compared against the tag the server just computed. Breaching the bound needs a BACKWARD step of at least one full bucket width (604 800 s).
- **D40 — Re-keying that bucket to monotonic is REFUSED for the same reason class D exists.** Why: monotonic resets on restart, exactly when body turnover must be guaranteed, and a correct monotonic-anchored 7-day bucket would need a persisted watermark — a new mechanism the wish forbids. This is the site where a reflexive sweep would manufacture a fix, so the refusal is the deliverable.
- **D41 — The class-C population is ONE, and the sweep behind that number is exhaustive on four axes.** Why: `on_conflict`/counter conflict targets (38 files, 42 targets, all identity keys), raw SQL (`date_trunc` 0, `NOW()` 0, `INTERVAL` 0), non-`div` quantisers (`rem`/`trunc`/`floor_div`/`beginning_of_*` — zero bound-bearing), and `div`-through-a-variable (which the canonical `div(System…` grep cannot see, and which is how the second quantiser hid).
- **D42 — TWO GREP TRAPS are recorded in the method section, because they moved the denominators twice.** Why: `git grep -cE '\binc:'` returns ZERO in this grep engine while `-F 'inc:'` returns 9 — a surveyor using the canonical form would have concluded there are no counter updates at all. And `to_char` (73 hits, all `String.to_charlist`), `age(` (374, all `Exception.message(`) and `now()` (383, all `DateTime.utc_now()`) are pure substring inflation. A zero-by-naive-grep is not a zero.
- **D43 — The time-as-input thread, framed as the highest-upside question on the board, is REFUTED, and the negative is stronger than the lane that framed it.** Why: zero request params, zero inbound headers, and zero `apply`/`spawn`-MFA/GenServer-message/Oban-arg paths carry a time value into a bound. The injectable-clock surface is 30 functions, not the briefed 19 (23 `\\` defaults plus 7 `Keyword.get(opts, :now)`-style), and every one is arity-short or literal-opts at every production call site.
- **D44 — Two zero-caller sites keep their negative ONLY as a residual recorded AT THE SITE.** Why: `PreviewToken.sign/2`'s `Map.put_new(:exp, …)` lets a caller-supplied `:exp` win outright, and `dispatcher.ex:411 verify_signature/5` is dead code. A negative resting on "nothing calls it" expires the moment something does.
- **D45 — The `abs()` two-sidedness is CODED but NOT PROVEN, and this wave ships a TEST-ONLY slice to fix that.** Why: striking `abs(` from `inbound_signature.ex:111` left the ENTIRE 3722-test cloud suite green while a live, unauthenticated webhook verifier lost half its replay window. Every negative freshness arm in all three twins drives the PAST side only. This slice must be labelled TESTABILITY and carry ZERO lib lines; presenting it as a security finding would overstate.
- **D46 — The VM premise HOLDS and was measured on both live Linux surfaces, not inferred.** Why: guerrilla reports `mode=multi_time_warp corr=true otp=27` and the live cloud control-plane release node reports the same via `rpc` — the serving process, not a fresh VM. No `vm.args`, no `+C`, no `ERL_FLAGS` anywhere. Backward steps are structurally PERMITTED. Steady state is SLEW (offsets +238us / +45us) and no clock jump appears in 60 days of journal on either host, so the honest register is: permitted, step-capable, **NOT OBSERVED**.
- **D47 — DO NOT "harden the VM" with `+C no_time_warp`, ever.** Why: freezing the offset makes every class-A absolute instant drift permanently from real wall time after any host correction — worse than the sites it would protect — and it does nothing for `System.os_time`, which bypasses the VM time layer entirely (`os_system_time_source` = `clock_gettime`/`CLOCK_REALTIME`).
- **D48 — The straddle reframing is retained as the survey lens even though it yielded zero findings.** Why: a straddle needs S1 quantisation ∧ S2 shared mutable state ∧ S3 cross-key reach. Dropping any one makes a site straddle-immune and collapses the clock question from a race to a magnitude argument. Every quantiser outside the fence either keeps its bucket inside one request or guards its cross-key write with a strict ordering test, so a refutation of clock steps would damage the ranking but not empty the wave.
- **D49 — `pulse.ex:193 count_today/1` is added to the ledger as the most reachable clock-derived bound in the repo, CITED SAFE with its residual named in both directions.** Why: it was uncensused — invisible to `div(`, to `on_conflict`, and to the non-`div` sweep unless you follow `count_today` to its SECOND caller at `pulse_controller.ex:127`, whose own moduledoc says "Auth posture: NONE, by design." A FORWARD step across UTC midnight resets the full anonymous 5000 budget early (fail-open); a BACKWARD step counts two days (fail-closed). It is a range COUNT over persisted `inserted_at`, not a bucket key, so #12628's mechanism is absent — and the compared column is wall clock, so a monotonic rewrite is IMPOSSIBLE, not merely wrong. One verifier called this display-only; that was an error, corrected here by tracing both callers.
- **D50 — `cloud/.../accounts/two_factor.ex:83` is cited as the in-repo class-C MODEL IDIOM.** Why: it is a genuine `div(time, 30)` quantiser whose persisted step is guarded by `two_factor_last_step < ^step` in the WHERE — #12628's shape applied prophylactically, before that defect was found. One repo, two replay floors, one correct twin.
- **D51 — Every CITED-SAFE verdict is recorded AT THE SITE, in the shape PR #12630 already shipped.** Why: a prior green stamp is not evidence, and the next auditor must find the reasoning instead of re-deriving it. The shape: header naming verdict/wave/date, provenance, a STRUCTURAL ground stated before any argument about consequences, a consumer census closed by a negative grep, the residual named in the safe direction, and an explicit "WHAT THIS VERDICT DOES NOT REST ON."
- **D52 — A criterion NAMES THE CLAIM, never the container, and no slice may cite a D-number from the UNTRACKED `api-controller-plug-correctness-charter.md`.** Why: that charter exists in the working checkout but is on NO branch of origin/main (two competing open PRs, #12614 and #12471, both carry it), so every D-number its 41 children cite is unverifiable by git-show. Cite #12628 as `8598c4efe7` and #12579 as `e45f1377bb`, and cite code by `git show origin/main:<path>`.
- **D53 — FENCE, and it is WIDER than the wish stated: five open-PR-owned files the exclusion list is blind to.** `api/lib/barkpark_web/request_stats.ex` (#12630), `api/lib/barkpark_web/controllers/tasks_controller.ex` (#12629 AND #12526 — two owners, hard-excluded), `api/lib/barkpark/sharing/links.ex` and `api/lib/barkpark_web/controllers/share_link_controller.ex` (#12404), `api/lib/barkpark/content/writer.ex` (#8465). Why: the previous sweep ran at `--limit 60` and there are 68 open PRs. Every slice file in this wave was re-checked at `--limit 200` and NONE collides.
- **D54 — The `api/lib/barkpark/tenancy/` fence is over-broad by 13 of 14 files, and that is recorded rather than silently narrowed.** Why: #12616 owns exactly `tenancy/auth.ex`; no open PR touches any other tenancy file. The two caller-supplied-time sites there are `workspace_bundle/janitor.ex:214` and `workspace_bundle/archive.ex:121` — one directory deeper than the wish's paths, which do not exist. `janitor.ex:273` compares a clock against a FILESYSTEM MTIME, a stored instant, so it is class A, not the class B its framing implies. Fence-deferred with corrected paths, not omitted.
- **D55 — BASELINE FROM A CLEAN WORKTREE AT origin/main, never the primary checkout.** Why: the primary checkout is 19 commits behind and the gap contains `rate_limiter.ex` and BOTH cloud limiters — baselining there would measure a tree WITHOUT the motivating precedent. Measured green at `1f981ec42d`: api 181/0, MFA family 27/0, github 67/0, cloud 106/0.
- **D56 — `CC=/usr/bin/clang` is required on any host where `cc` is shadowed (it is on this one — `alias cc='c claude …'`), and `cloud` needs an EXPLICIT `mix ecto.create && mix ecto.migrate`.** Why: `argon2_elixir` (api) and `bcrypt_elixir` (cloud) are C NIFs and die with `error: unknown option '-g'` under the wrapper; api's `mix.exs` has a `test` alias that migrates for you and **cloud's does not**, so a cloud builder reds on setup rather than substance.
- **D57 — STATE THE COUNT EVEN AT ZERO, and do not dress it up.** Why: "505 censused, 383 dropped, 120 class-A cited safe, 1 class-C cited, 0 class-B, 3 fixed" converts an unexamined assumption about the whole codebase into a checkable ledger. That is the A-grade result whether or not a fix falls out, and the two REFUTED candidates (the TOTP CAS, the time-as-input thread) are worth as much as the three that shipped.

### Wave 1 — web-glue robustness (D58–D69)

- **D58. The verdict is the deliverable; a cited zero outranks a manufactured fix.** Fourteen
  of sixteen survey lanes came back a swept zero with a NAMED guard (`Repo.uuid_or_nil` on
  every binary_id lookup, `min/max` clamps on every limit/offset, 22-of-22 emitting plugs
  pairing response with `halt`). Churn on an already-safe pattern is what the wish forbids.
- **D59. The surviving 500 surface is the DEEPER frame, not the action head.** Phoenix 1.8.9
  converts an action-head clause mismatch into a clean 400 via `Phoenix.ActionClauseError`
  (`pipeline.ex:144-152` → `exceptions.ex:69-72`, `status(_) → 400`). That refutes most of
  the wish's premise (1). What still 500s is a `FunctionClauseError`/`CaseClauseError` raised
  in a private helper or a context callee, where the top stack frame is not the action.
  Every wave-1 build slice is that exact shape.
- **D60. The unifying defect is one sentence: an unvalidated param TYPE, not a missing param.**
  Plug decodes `?x[]=v` to a list and `?x[k]=v` to a map. Five of six slices are the same
  bug — a list-valued param sails past a key-presence match and raises three frames down.
  Naming the class once is why six independent findings cost one review, not six.
- **D61. Fix at the boundary that OWNS the type, and let the framework do the rest.** For an
  action-head-reachable param, adding `when is_binary(x)` to the CONTROLLER HEAD makes the
  top frame the action, so Phoenix returns 400 for free. For a helper-internal shape, guard
  the element (`is_map/1`) or make the private helper TOTAL with a catch-all clause.
- **D62. A FILTER fails loud, a SCOPE SELECTOR fails soft.** `?kind[]=x` on task edges must
  400 — a silently-ignored filter is the dishonesty `query_controller`'s `invalid_filter_op`
  guard exists to refuse. `?dataset[]=x` falls back to the documented `"production"` default,
  matching that module's own `|| "production"` convention. Uniformity here would be wrong.
- **D63. Error CONSTRUCTORS must be total.** `cycle_fleet`'s `receipt_error/2` had clauses for
  two of the four keys it is called with, so any malformed body raised INSIDE the error
  builder before the `else` could render its 422. A partial helper on the error path is
  invisible to anyone scanning `else` blocks — this class gets a `_key` catch-all, never a
  dynamic-atom collapse (`:"#{key}_required"` is an unbounded-atom hazard).
- **D64. Concurrency races are FILED, never built here.** The RateLimiter ETS read-modify-write
  and the Quota count-then-compare TOCTOU are real and fail-open, but both fix loci sit
  OUTSIDE the fence (`lib/barkpark/rate_limiter.ex`, `lib/barkpark/tenancy/quota.ex`) and
  neither is deterministically provable by a single-process conn test.
- **D65. A finding with no possible mutation proof still ships — labelled.** `Plug.Adapters.Test.Conn.chunk/2`
  returns `{:ok, …}` on every clause, so no conn test can red `listen_controller.ex:62`. The
  fix lands on the guard census as its evidence, and the task says so in writing.
  *(Corrected 2026-08-18 at review: the census is 11 sites / 10 guarded, not 12 / 11. The
  three `workspace_controller.ex` hits are a local `write_chunk/3` disk helper and `plugs/`
  has zero `chunk/2` sites. Substance unchanged — all but one were already guarded.)*
  Claiming a red-without-fix proof there would be exactly the stamped-evidence-overstates trap.
- **D66. Two files are FILE-only for the whole epic while their PRs are open.**
  `share_controller.ex` (#12405) and `share_link_controller.ex` (#12404) are actively
  diverging. Correctness findings there are filed, never built, until those merge.
- **D67. Every builder brief carries the host bootstrap.** A fresh worktree needs
  `mix deps.get` then `CC=/usr/bin/clang MIX_ENV=test mix compile` once — `cc` on this host is
  aliased to a Claude wrapper and breaks the argon2 NIF. The wave's own verify round lost
  cycles to this. `mix test` auto-runs `ecto.create`/`ecto.migrate`, so the "run migrations
  first" folklore is wrong for the test path and is struck from the briefs.
- **D68. Instrument traps are findings, not footnotes.** Three of this wave's greps returned
  confident fake zeros: `\s` is undefined in POSIX ERE so `git grep -E` silently matches
  nothing; zsh does not word-split an unquoted scalar pathspec so git receives one argument
  and exits 1; a `Repo.get`-only census is blind to `where([x], x.id == ^param)`. RULE for
  every future wave: mutation-check a class grep against a KNOWN POSITIVE before quoting its
  zero.
- **D69. Coverage is accounted, and the remainder is filed by name.** Wave 1's censuses closed
  the Papers/meta block (18 modules), the auth/deploy long tail (17), and the hot core (5).
  What remains unopened is filed as a backlog task, not implied verified.

### Wave 2 — rate-limit & quota atomicity (D70–D93)

**D70 — Close the token bucket with an `:ets.select_replace/2` compare-and-swap. NOT a serializing GenServer, NOT a milli-token integer redesign.** *Why:* the filed task's premise ("a float bucket cannot be atomic via `update_counter`, so a real fix is a GenServer or an integer redesign") is REFUTED by run output from six independent probes — a literal-tuple match head compare-and-swaps a float-valued row on the limiter's exact table options, and a GenServer would turn every authenticated request into a single-process bottleneck.

**D71 — The blocker on `:ets.update_counter` is NOT the integer restriction; it is that every UpdateOp operand is a caller-supplied constant.** *Why:* a bucket whose refill derives from the row's own `last_ms` can never be one atomic call, so milli-tokens fixes the wrong half — it is a redesign (tick-driven refill or GCRA) owing an equivalence proof, not a fallback, and it would break the existing prune tests that insert raw float 3-tuples.

**D72 — The arithmetic stays byte-identical; only the commit changes.** *Why:* burst capacity and refill rate are then preserved by construction rather than by argument, and `api/test/barkpark/rate_limiter_test.exs` passes BYTE-UNCHANGED — the strongest preservation evidence available, and one this wave will not trade away.

**D73 — The match head MUST carry the literal key and the replacement body MUST be `{:const, tuple}`.** *Why:* a `:"$1"`-key-plus-guard head is a FULL TABLE SCAN — measured 0.43us vs 30,252us per call on a 200k-row table, a 70,000x silent throughput regression that is atomic, correct, and passes every behavioural assertion. A bare tuple body raises `ArgumentError` for every tuple key the six non-string callers use.

**D74 — Ship a STRUCTURAL guard on the match-spec shape, not a timing guard.** *Why:* no non-timing behavioural probe can distinguish the keyed head from the scanning head — a scanning head with a correct guard replaces the same row and returns the same `1`. The spec builder is extracted as `@doc false __cas_spec__/2` and a test asserts the head's key element is the literal key term. One deterministic line; the alternative is a 3,500x timing bound that is advisory at best.

**D75 — The retry bound is 128, and exhaustion returns `:rate_limited` (fail CLOSED).** *Why:* the bound is a LIVENESS knob, not a correctness one — no bound over-admits, so a low bound can only spuriously DENY. Measured: bound 8 denied 36% of legitimate traffic; bound 20 denied 3.5%; bound 100 denied 0 of 6000 in one verifier's harness while a second verifier's suite was flaky-red at 64 and green 20/20 at 128. Take the higher measured-green value; p50 is 0 retries either way.

**D76 — The twin harness ships TWO twins: a seam-widened one that ASSERTS, and a verbatim one that REPORTS.** *Why:* this is the wave's crux and the direction was wrong about it. The byte-verbatim origin/main body **never over-admits at one scheduler** — 0 of 220 rounds across five configurations — and is flaky at two (79/100, and one sampled run at 9/20). CI is `runs-on: ubuntu-latest` with no `+S` pin and no `--max-cases`, so its scheduler count is unknown and uncontrolled. A verbatim twin asserting per-round is permanently red on a 1-vCPU runner; a suite asserting only that the FIXED limiter admits exactly capacity is vacuous there, because the unfixed body passes that too. One `:erlang.yield()` at the read→write seam makes over-admission **deterministic and total at every scheduler count** (20/20 rounds at +S 1, 2 and 4, with all N callers admitted). The widened twin therefore carries the per-round assertion; the verbatim twin carries no assertion and PRINTS its per-round distribution alongside `schedulers_online` as reported evidence.

**D77 — The yield is labelled as scheduling-widened, never as "the origin/main body".** *Why:* the yield widens the seam, it does not create the race — the verbatim twin's +S 2/3/4 numbers prove the race exists without it, and describing the widened twin as verbatim would be exactly the dishonesty this codebase's doctrine names. A reviewer should reject that framing.

**D78 — No runtime scheduler skip.** *Why:* the previously-proposed `schedulers_online < 2` skip was implemented as a runtime `if` that PRINTS and returns, so a 1-scheduler runner reports PASSED for a test that proved nothing — a vacuous green wearing a skip's clothes. D76 removes the need for it entirely.

**D79 — Widen `@stale_after_ms` from 300_000 to 3_600_000, in its OWN slice, after the CAS lands.** *Why:* a new in-fence finding, mutation-proven. The prune's justifying comment ("The plug's capacity/refill is a CONSTANT 60s full-refill") was TRUE when written on 2026-07-02 and was invalidated ONE DAY LATER by `Plugs.TicketRateLimit`, then again by `Plugs.AuthWriteRateLimit` — both refill at `limit/3600`. A DEPLETED hourly bucket idle 300s is pruned as "stale" and its next request creates a FULL one: ~12x the hourly allowance on the unauthenticated register path, plus 4x on the public bulldocs form. Compounding it, the `:rate_limited` branch writes NOTHING, so a hammering client's `last_ms` freezes at its last SUCCESSFUL admit and it ages toward prune-eligibility while being denied.

**D80 — D79 is the ONE place the byte-unchanged constraint is deliberately relaxed, and the carve-out is explicit.** *Why:* two seed constants in `rate_limiter_test.exs` (`now - 600_000`) encode the OLD cutoff and necessarily stop being stale at a 1h cutoff. They move to `now - 4_000_000` with the reason recorded at the site. Separating this from the CAS slice is what keeps the CAS slice's byte-unchanged proof intact.

**D81 — D79's severity is stated with its refutation attached.** *Why:* on guerrilla the prune essentially never fires — blue/green cutovers restart the content slot ~29 times per 24h, wiping the whole ETS table long before it reaches `@max_entries`. The finding is real for a long-uptime self-hosted install, which is the deployment this limiter is written for. Claiming it is "a bigger hole than the race" without that qualifier would overstate.

**D82 — File the quota finding; do not narrow it.** *Why:* D-vision's category fact, confirmed independently by three surveyors and re-derived here against `router.ex:273/312/667` and `require_within_quota.ex`.

**D83 — The quota deliverable is a DEMONSTRATION test, explicitly asserting the CURRENT BROKEN behaviour.** *Why:* Arm C promised "a reproducible demonstration that the over-admission is real rather than argued", and it is buildable: cap 10, 9 seeded documents, 8 concurrent callers — `admitted=8, final_count=17` in 100% of rounds across four harness shapes and 11 runs, against a sequential CONTROL that admits exactly 1. The staged leg (all callers check, then all write) is deterministic and needs no scheduler luck at all. It must NEVER be described as a regression guard: its moduledoc states in its first sentence that a fix MUST flip these assertions.

**D84 — The SHARED Ecto sandbox is sufficient for the quota demo and insufficient for a quota FIX proof.** *Why:* the TOCTOU spans two statements, so one serialized connection still interleaves count/count/insert/insert — refuting the claim that shared mode makes the demo impossible. But a DB-level fix (advisory lock, serializable, FOR UPDATE) can never be proven under shared mode, because both "processes" are one session. That asymmetry is independent structural support for D82.

**D85 — The costed menu ranks the counter-column trigger first and REFUTES the conditional INSERT by name.** *Why:* two psql sessions at cap 3 / count 2 running `insert … where (select count(*)) < (select quota)` under READ COMMITTED BOTH returned `INSERT 0 1` and both committed — final count 4. That is the tightest possible form of the shape and it closes nothing. Ranking: (1) statement-level trigger with transition tables + `documents_count` column + `NOT VALID` CHECK — measured to hold exactly at cap under READ COMMITTED with no retry, at 1.14x cascade-delete cost vs 4.9x for FOR EACH ROW; (2) per-workspace advisory lock — in-tree prior art exists, but creates a three-lock protocol (quota→task→audit) with a shared bigint keyspace; (3) SERIALIZABLE — correct, but its SIRead predicate lock escalates to relation level at production size and falsely aborted two transactions working DISJOINT workspaces, and there is zero 40001 retry infrastructure anywhere in `api/lib`; (4) conditional INSERT — NOT A FIX.

**D86 — Correct the filed quota task's stated filing reason.** *Why:* it says "the race is not deterministically provable by a single-process conn test". That is now obsolete — the batch overshoot IS deterministically provable single-process, and the two-session psql reproduction is sub-second. It is filed because the FIX LOCUS is out of fence and carries behaviour change, not because the defect is unprovable. Leaving the old reason standing invites a future wave to conclude the finding is soft.

**D87 — Correct the filed quota task's overshoot bound.** *Why:* it says the workspace exceeds its quota "by up to the concurrency factor". The overshoot is bounded by the CALLER-CHOSEN BATCH SIZE, not by concurrency: `Content.Mutations.apply_mutations/3` takes an unbounded list in one transaction with no cap anywhere in `api/lib`. Measured through the real scoped route: cap 3, usage parked at 2, ONE request of 25 creates → usage 27. At cap 1, one request of 200 → usage 200. A single serial client overshoots arbitrarily, and this SURVIVES any fix to the race.

**D88 — The media/documents contradiction resolves as PLUGIN-CONDITIONAL, and both surveyors were half right.** *Why:* `Media.upload/3` really does insert only a `media_files` row — but it then calls `Plugins.Registry.run_after_media_upload/1`, which reaches `Plugins.Media.after_media_upload/1` → `Assets.ensure_for_upload/1` → `Content.create_document`, stamping the blob's `workspace_id`. Run-proven both ways: plugins discovered → documents delta 1; media plugin excluded → documents delta 0. `BARKPARK_PLUGINS` unset is the documented production default and means discover-all, so the media quota gate is REAL on a stock install and decorative only under an explicit operator whitelist.

**D89 — Sibling honesty is corrected DOWNWARD: 3 of the direction's 4 named siblings are not in this class.** *Why:* both cloud limiters increment atomically via `:ets.update_counter/4` and compare the RETURNED value — they are the anti-pattern's opposite, and filing them would be two fabricated findings; `RequestStats` is an insert-only telemetry ring under a globally unique key, not a bound at all. A census of every ETS writer in `api/lib` + `cloud/lib` found `rate_limiter.ex` to be the only lookup-then-insert BOUND in the tree.

**D90 — The real siblings are filed by name.** *Why:* the graph-corpus TTL sweep is a genuine fail-open — DEMONSTRATED with a running probe showing 3 then 5 concurrent derivations admitted against a cap of 2 with every owner ALIVE, and mutation-proven — and its ACQUIRE path is provably safe because it inserts before reading size, which is exactly the ordering `rate_limiter.ex` gets backwards. Plus `cloud/.../registry.ex` `register_barkpark/2` (a third count-then-compare quota TOCTOU), the blue/green deploy-cadence limiter reset, and the total absence of telemetry on `:ets.info(@table, :size)`.

**D91 — Overturn the felix "already-good" verdict BY NAME, and cite the same paper IN SUPPORT of D70.** *Why:* `felix-findings-otp-supervision` graded this exact limiter `already-good` and read same-key contention purely as throughput — a standing "verified, no change" stamp on the defective function. The SAME paper carries a `rejected-w-reason` verdict against sharding it and asserts "rate limiting in ETS, not a GenServer", so D70's refusal of the GenServer is the codebase's own prior position.

**D92 — All three slices build at `opus`, including the hard one.** *Why:* the wish caps Fable until Aug 21. Slice S1 would otherwise be a Fable slice on the difficulty axis (lock-free CAS, a match-spec trap no behavioural test can see, a scheduler-dependent proof design, and a blast radius covering every authenticated request path). The cap is honoured, and the compensation is explicit: S1 is flagged HIGH-FLIP-RISK and owed an independent second reviewer before merge.

**D93 — Probe instrumentation must not ship.** *Why:* the verify round's patches carried `Process.put(:rate_limiter_retries)` meters and `:max_retries` / `:yield_after` options purely to measure. A `Process.put` on the zero-retry path invalidates the quoted +0.33us hot-path cost, and the options are new configuration surface on the hottest path in the system.

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

### Wave 4 — clock semantics

Wave 4 (this wave) — 5 slices, all round 1, no inter-slice dependencies, disjoint file sets.

| # | Slice | Task | Surface | Size | Model |
|---|---|---|---|---|---|
| 1 | MFA recency floor — the one proven fail-open (HIGH-FLIP-RISK) | `clk-w4-mfa-recency-floor` | api auth | medium | fable |
| 2 | Prebuilt nonce: class-D restart reset | `clk-w4-prebuilt-nonce-wall-clock` | cloud sites | small | opus |
| 3 | GitHub backoff: clamp an unbounded park | `clk-w4-github-backoff-clamp` | api plugins | medium | opus |
| 4 | Signature freshness: prove the two-sidedness (TEST-ONLY) | `clk-w4-signature-future-arm` | api + cloud tests | small | opus |
| 5 | Record the CITED-SAFE verdicts at their sites | `clk-w4-cited-safe-at-sites` | api + cloud docs | medium | opus |

Deferred to a later wave or the backlog, with the reason:

- The forward-step 1s-retry residual at `github/client.ex` — a distinct defect an upper clamp does not fix (D38).
- The `nimble_totp` coupling tripwire behind D30/D31 — needs a test that cannot pass vacuously.
- `webhooks.ex:574`'s `fence = DateTime.utc_now()` equality-CAS token — a real class-D shape whose reachability is unproven; must not be "fixed" on a shape argument alone.
- `cloud/.../health.ex:120-132` `serving_since` — the one true inverse-error site (a boot-local monotonic quantity published as a durable instant); already owned by charter D404/D417 and `ServingMemory`.
- The five DEADLINE predicates, the `PreviewToken.sign/2` `put_new(:exp)` shape, and `dispatcher.ex:411` dead code — cited in wave 4, no fix owed.
- Narrowing the `tenancy/` fence to `tenancy/auth.ex` so `janitor.ex:214` enters the ledger (D54) — ledger completeness, zero collision cost, no fix.

### Wave 1 — web-glue robustness

### Wave 1 — the six proven 500s (this wave, all round 1)

| # | Slice | Surface | Size | Model |
|---|---|---|---|---|
| 1 | `receipt_error/2` totality — malformed release-gate body 500 → 422 | `cycle_fleet_controller.ex` | small | opus |
| 2 | SCIM scalar member/op element → 500 on 5 request shapes | `scim_groups_controller.ex`, `scim_users_controller.ex` | small | opus |
| 3 | Task `edges` `kind[]` CaseClauseError + `request_dataset/1` list dataset | `tasks_controller.ex` | medium | opus |
| 4 | SSO list-param 500 on OIDC/SAML/social callbacks (HIGH-FLIP) | `oidc_controller.ex`, `saml_controller.ex`, `social_controller.ex` | medium | fable |
| 5 | Bulldocs `?dataset[]=` → `Ecto.Query.CastError` 500 → 404 | `bulldocs_email_controller.ex`, `bulldocs_source_controller.ex` | small | opus |
| 6 | `listen_controller.ex:62` unguarded `chunk/2` hard bind | `listen_controller.ex` | small | opus |

### Wave 2 and beyond — candidate shape (not yet cut)

- Close the controller census remainder: the modules no wave-1 lane opened, swept for the
  same four classes with the D68-corrected instrument.
- The partial-private-helper census: `receipt_error/2` is unlikely to be the only error
  constructor called with more argument values than it has clauses. Grep the class, not the file.
- Conn-level coverage for routes that have none — `webhook_controller` replay/test-send and
  `tickets_attachments` both ship with zero controller tests, which is why their seams went
  unexamined for so long.
- The out-of-fence robustness items filed in wave 1 (rate-limit race, quota TOCTOU,
  `Accounts.get_user/1` uuid parity) if a later epic takes the contexts.

### Wave 2 — rate-limit & quota atomicity

| # | Slice | Round | Size | Model | Surface |
|---|---|---|---|---|---|
| S1 | `acpc-w2-ratelimiter-cas-atomic-debit` — CAS the token-bucket debit + the twin harness | 1 | large | opus | `api/lib/barkpark/rate_limiter.ex`, `api/test/barkpark/rate_limiter_concurrency_test.exs` |
| S2 | `acpc-w2-ratelimiter-prune-hourly-reset` — widen the staleness cutoff to the slowest window | 2 (after S1) | small | opus | `api/lib/barkpark/rate_limiter.ex`, `api/test/barkpark/rate_limiter_test.exs`, `api/test/barkpark/rate_limiter_prune_test.exs` |
| S3 | `acpc-w2-quota-toctou-demonstration` — demonstrate the quota over-admission, file the fix sharpened | 1 | medium | opus | `api/test/barkpark/tenancy/quota_toctou_demonstration_test.exs` |

S1 and S2 both edit `rate_limiter.ex`; S2 additionally moves two seed constants in the very file S1 must leave byte-unchanged. They are sequenced, not parallelised. S3 is file-disjoint from both and builds beside S1 in round 1.

Deferred by construction (filed, not built — every fix locus is outside this fence): the quota DB invariant, the batch-size cap on `apply_mutations/3`, the graph-corpus TTL sweep, the cloud registry TOCTOU, the deploy-cadence limiter reset, and limiter-table size telemetry.

## Wave log

### Wave 2026-08-19 — sibling ETS-bound atomicity (wave 3)

**Premise refuted, and that is the headline.** The wave was briefed to mirror
#12579's `:ets.select_replace/2` CAS onto four sibling read-modify-write
admission bounds. **Zero of the four had #12579's shape.** The cloud limiters
already commit through `:ets.update_counter/4` (an atomic RMW with a default
seed); the `/v1/graph` cap is ticket-then-count (the row is inserted *before*
`:ets.info(:size)` is read, so the latest admitter counts itself and refuses);
`RequestStats` writes a single `:ets.insert` on a VM-unique key with no
preceding lookup. No CAS was ported anywhere, no retry loop was added anywhere,
and therefore no retry distribution or exhaustion rate is quoted anywhere — the
absence is the finding, not a gap in it.

**Two of the four were still genuinely fail-open, by a different mechanism.**
Both are sweep-predicate defects, not lost updates:

| Bound | Disposition | Mechanism | Reachability |
|---|---|---|---|
| `Accounts.TwoFactorRateLimiter` + `DeviceAuth.RateLimiter` | **FIXED** (#12628) | the stale-window sweep guard `{:"/=", :"$1", window}` deleted every row for the key that was not the caller's own — *including a newer one*, refunding an exhausted budget | **unauthenticated** on `register:` / `start:` / `poll:` / `oauth_exchange:`; pre-session on the 2FA challenge — the crown |
| `TasksController` `/v1/graph` slot cap | **FIXED** (#12629) | the TTL sweep's `deadline <= now or` arm reaped rows of **live** holders whose derivation outran the 60s TTL; every acquire sweeps first, so an arriving request performed that reap on the live holders' behalf and was admitted over the cap — self-amplifying | authenticated bearer (`:require_token`); severity is blast radius, not reach |
| `BarkparkWeb.RequestStats` | **CITED SAFE** (#12630) | not an admission bound at all: unique-keyed single insert, and the only in-tree reader is a branchless `json(conn, RequestStats.stats())`; the off-box chain terminates in a `quota=nil` meter that tints and never enforces | n/a |

Fix size: **one match-spec token per cloud limiter** and **one deleted `or`
arm** on the graph cap. Every limit, burst capacity, window and `retry_after`
derivation is byte-unchanged; all thirteen pre-existing test files ran
byte-unchanged and green.

**RED-FIRST was real and was re-derived independently by the reviewer, not
inherited.** Reverting the cloud lib bodies to `origin/main` gives 3 tests / 3
failures (`right: :ok` where a rate-limited tuple is asserted, on both
limiters); restoring *only* the graph cap's `deadline <= now or` arm gives 5
tests / 1 failure on the headline assertion, while the legacy twin and
dead-owner controls stay green in both states — which is what makes the
headline the discriminating test rather than a test that merely agrees with the
fix.

**Class residue is zero for the named class.** `git grep -nF ':"/="' -- api/lib
cloud/lib` returns nothing after these merges, and every remaining `:ets.lookup`
in `api/lib` + `cloud/lib` is a cache or a record read, not a bound.

**Ledger:** three slice tasks, all claimed, all stamped criterion-by-criterion
with real evidence as the work happened, all left `in_progress` with only the
merge-gated row open. **No ledger fixes were needed** — the first wave in a
while where the reviewer found nothing to correct.

**Grade: A−.** What the next wave should take, in order: merge #12628 → #12629 →
#12630 (disjoint files, any order works, but the unauthenticated crown first);
then the four residue rows this wave filed rather than built —
`acpc-bl-poll-key-unbounded-ets-growth` (attacker-chosen key space, the *fifth*
failure mode and the one this wave deliberately did not touch),
`acpc-bl-graph-slot-wedged-live-holder` (the fail-closed capacity loss #12629
knowingly trades for), the untested `ReplayRing` single-writer invariant, and
the two per-IP buckets on session-authenticated routes. Full story:
Paper `sibling-ets-atomicity-wave-2026-08-19`.

### Epic charter — Clock semantics: classify every security-relevant time read, fix only the ones whose semantics are wrong

Epic task: `api-controller-plug-correctness-audit`
Wave Paper: `clock-semantics-wave-2026-08-19`
Wave referent: `acpc-wave-4-log`
Audited against origin/main `1f981ec42d837a46de228283d4c6d8762ba38988`.

#### Wave 4 vision

#12628 (`8598c4efe7`) fixed the Cloud rate limiters and found their window derived from `System.system_time(:millisecond)` — explicitly non-monotonic — and used as a BUCKET KEY, so a caller holding a stale window could delete a newer bucket and reset the budget. The bucket-key misuse, not the atomicity, is what made an otherwise-atomic limiter fail open. That raises a question about the whole codebase: where else does a security or bounding decision depend on wall-clock time in a way a clock step or a stale read can subvert?

**The answer is: almost nowhere, and proving that is the deliverable.** Most wall-clock reads in this codebase are CORRECT and must not be touched. An ABSOLUTE STORED INSTANT — `expires_at`, a signed-URL `exp`, `locked_until`, a TTL cutoff compared against a persisted timestamp — MUST be wall clock: it has to survive a restart and be comparable across nodes, and `System.monotonic_time` is process-local and meaningless for it. A sweep that mechanically pushed these toward monotonic would be a serious regression, and this epic exists partly to make that regression un-shippable by writing the CITED-SAFE argument at the site.

So the primary artifact is a CLASSIFIED LEDGER — every security-relevant time read as one row carrying file:line, semantic class, why wall clock is right or wrong THERE, the consequence of a clock step in BOTH directions, and whether an unauthenticated or non-admin caller can influence the timing. Fixes fall out of the classification; they are never the starting point.

**THE CENSUS, with its counting rule stated so the coverage claim is checkable.** 505 raw clock reads across `api/lib` + `cloud/lib` on origin/main; 383 dropped as prose, display-only, or already-monotonic; **120 security-relevant survivors** under a DECISION-SITES-ONLY rule (83 `DateTime.utc_now` + 37 `system_time`/`os_time` family); 4 fence-excluded. The rule is load-bearing and is why the number moved twice: a survivor is a site where the clock read is ITSELF compared against a stored or transmitted instant. Counting the paired WRITE of every stamp a bound later reads gives 157 instead — defensible, but it doubles the ledger with mint/verify pairs and is not re-derivable from one grep. State the rule in the same sentence as the number or the number means nothing.

**THE FOUR CLASSES.** (A) ABSOLUTE INSTANT — stored, transmitted, or compared against a stored value; wall clock CORRECT; CITED SAFE; the overwhelming majority. (B) ELAPSED DURATION — two reads in one process; monotonic correct; fix only when the consequence is security- or bound-relevant. (C) BUCKET / WINDOW KEY — a wall-clock read quantised into a key a bound is enforced against; the #12628 class. (D) FENCE / IDENTITY TOKEN — a value used as an incarnation epoch, nonce, or build id, where the required property is "never repeats, never goes backwards across a restart"; NEITHER pure source is correct, because monotonic RESETS on restart, which is exactly when these must change. Class D is CITE-ONLY BY DEFAULT — its job is to be the refusal bucket that says out loud why "just use monotonic" is wrong. It earned one fix this wave, and that fix goes the OTHER way: replacing a monotonic-flavoured primitive with a wall clock.

**THE RESULT.** 0 class-B defects. 1 class-C site outside the fence, CITED not fixed. 3 fixes total, none of them where the strategic direction expected: a proven one-sided freshness gate on an anonymous auth leg (class A with a sidedness defect — sidedness is ORTHOGONAL to A/B/C/D and the taxonomy has no bucket for it), a class-D nonce that restarts from 1, and an unclamped backoff. Two of the four candidate defects the direction led with were REFUTED by verification, and recording those refutations is worth as much as the fixes.

### Wave 2026-08-19 — clock semantics (epic `api-controller-plug-correctness-audit`, wave 4)

**Grade: A.** Paper: `clock-semantics-wave-2026-08-19`. Charter PR: #12655. Referent: `acpc-wave-4-log`.

**What the wave actually is.** A classified ledger, not a fix pile: 505 raw clock reads censused across `api/lib` + `cloud/lib`, 383 dropped as prose/display/already-monotonic, **120 security-relevant survivors** under the decision-sites-only rule (D23), 4 fence-excluded. Result: **0 class-B defects, 1 class-C site outside the fence (cited, not fixed), 3 fixes** — none of them where the strategic direction expected. The two candidate defects the direction led with (the TOTP equality-CAS, the time-as-input thread) were REFUTED by verification, and both refutations shipped as durable at-site notes. That is the deliverable the wish asked for: an unexamined assumption about the whole codebase converted into a checkable ledger.

**Landed — five slices, all round 1, disjoint file sets, five PRs open.**

| Slice | Task | Final branch | PR | Class |
|---|---|---|---|---|
| MFA step-up recency floor | `clk-w4-mfa-recency-floor` | `loop-epic/mfa-step-up-give-the-two-recency-predica-0` | #12688 | A, sidedness |
| Prebuilt build_id nonce | `clk-w4-prebuilt-nonce-wall-clock` | `…-1-r` | #12689 | D |
| GitHub backoff clamp | `clk-w4-github-backoff-clamp` | `loop-epic/github-client-clamp-retry-after-seconds--2` | #12690 | A, time-as-input |
| Signature future arms (test-only) | `clk-w4-signature-future-arm` | `…-3-r` | #12691 | testability |
| Five CITED-SAFE notes | `clk-w4-cited-safe-at-sites` | `…-4-r` | #12694 | comments-only |

**Proofs re-derived by review, not re-read.** MFA: both predicates mutated back to their unfixed form in the reviewer's own worktree → **54 tests, 2 failures**, the controller arm failing `left: "/studio"` (unfixed code MINTS a session) and `mfa_fresh?/3 rejects a mfa_verified_at in the FUTURE`, with all four controls green in that same red run. Webhooks: `abs(` struck from `inbound_signature.ex:111` → both cloud arms fail with `left: 202`, and they are the ONLY two failures in those files. Slice 5's comments-only claim verified mechanically (added lines that are not `#` comments: **zero**; removed lines: **zero**), and its six load-bearing citations re-derived against this tree — `phoenix_live_view` 1.1.28 / `@max_session_age 1_209_600` (which the builder had taken on faith from the brief and never opened), `@bucket_seconds 604_800`, NimbleTOTP's strict `reused?/3` at `nimble_totp.ex:250-252`, cloud's `two_factor_last_step < ^step` at `accounts.ex:2186`, the `[-1, 0, 1]` earliest-first scan, and the `fleet_hub` / `sheets/session.ex` microsecond-epoch siblings. All checked out.

**What review fixed in place.** (1) `mix format` on the prebuilt nonce value-domain test — it was not format-clean and would have reded a formatting gate. (2) Mirrored the future-side freshness arm onto `push_relay_receiver_test.exs`, the SECOND anonymously-reachable HMAC-only leg in cloud (`router.ex:8052`), which had the identical past-only gap; re-proven non-vacuous by the same mutation. (3) Widened both future offsets from `+400` to `+3600` — `+400` left only 100s of margin against the 300s tolerance. (The builder flagged this as a spurious-GREEN risk; it is actually spurious-RED, since the assertion is `401` and a narrowed gap yields `202`. The margin is free either way.) (4) Rewrapped a broken sentence in the `paper_revision_headers` verdict. Slices 1 and 3 needed nothing.

**Ledger.** All five slice tasks published, parented, claimed, stamped mid-claim with evidence quoting real diff hunks and real run output, lifecycle honestly `in_progress`, and in every case exactly ONE criterion left open — the lead-owned `PR merged` row. No fabricated met flags, no batched honesty, no task outside this wave touched. **Zero ledger fixes were required**, which has not been true of a wave in this epic before. Both named residuals were filed as open backlog children before review began (`clk-bl-github-backoff-forward-step-1s-loop`, `clk-bl-js-webhook-future-arm-missing`).

**Before merging, the lead must know.** (1) **#12688 is HIGH-FLIP-RISK and an INDEPENDENT second reviewer is still owed.** The wave reviewer re-derived the class-A judgment from source — `studio_mfa_at` is written at `session_controller.ex:189` on an earlier request and round-trips through the signed cookie; `require_recent_mfa.ex:35` is the only ENFORCEMENT reader of `mfa_verified_at` — but that reviewer is the same harness that built it. Misclassifying an absolute instant as a duration is the one way this wave could do damage. (2) #12688 adds a real new residual the brief did not name: on a fleet with inter-node clock skew, a node whose clock trails the stamping node now re-prompts for a factor. Fail-CLOSED, sub-second under normal NTP, but new. (3) #12690 is not a no-op — a legitimate GitHub `Retry-After` above 300s is now truncated, costing one extra 403 per over-long window; and its forward-step twin (a perpetual 1s hammer that a ceiling does not fix) is the arguably-more-damaging half, filed separately. The two should not sit far apart. (4) **Merge order:** #12694's `fleet_hub` note says a sibling slice "addresses" the prebuilt nonce — merging it before #12689 leaves a sentence describing a fix that has not landed. (5) The lead closes the `PR merged` criterion on each slice task on merge (indices 10, 8, 10, 7, 9 respectively).

**Next wave, in dispatch order.** Merge round 1 in the order above → then the two filed residuals, `clk-bl-github-backoff-forward-step-1s-loop` (the forward-step hot loop, the half this wave scoped out) and `clk-bl-js-webhook-future-arm-missing` (the JS webhook twin, outside this wave's fence) → then the ledger-completeness items the charter deferred with reasons: narrowing the `tenancy/` fence to `tenancy/auth.ex` so `workspace_bundle/janitor.ex:214` enters the ledger (D54), the `nimble_totp` coupling tripwire behind D30/D31, and `webhooks.ex:574`'s `fence = DateTime.utc_now()` equality-CAS token whose reachability is unproven and which must NOT be "fixed" on a shape argument alone. `cloud/.../health.ex:120-132` `serving_since` stays owned by charter D404/D417.

### HTTP controller + plug correctness epic — charter

Epic task: `api-controller-plug-correctness-audit` · wave Paper: `web-glue-robustness-wave-2026-08-18`
Pinned tree for wave 1: `origin/main` @ `cd75286b72d08e439adccf7a338e5c8e8e607641`

#### Wave 1 — web-glue robustness vision

The HTTP glue layer — 80 controllers and 49 plugs under `api/lib/barkpark_web/controllers`
and `api/lib/barkpark_web/plugs` — is where edge-case bugs hide: a param that arrives as a
list instead of a string, a status code that says 200 when the row was never found, a plug
that answers without halting, an error branch nobody wrote. This epic is an
improvement-only, evidence-first correctness ledger over that layer. Every candidate is
either a REAL defect carrying its concrete failing request (method + path + params → wrong
status or 500) and a conn test that reds without the fix, or a SAFE pattern cited by the
specific guard that makes it safe. The honest per-class count — stated even where it is
zero — is the deliverable, not a fix quota. This is a robustness lens, never a second pass
over the merged content-plane security campaign.

<!-- one row per wave: wave, date, slices merged, grade, paper -->

### Wave 2026-08-18 — wave 1, the six proven 500s

Grade **A-**. Paper `web-glue-robustness-wave-2026-08-18`. Charter PR #12471.

**All six slices landed and were pushed with PRs — including the one the harness reported
not-green.** Every fix is the same class D60 named: an unvalidated param TYPE, not a missing
param.

| Slice | Task | Final branch | PR | Verdict |
|---|---|---|---|---|
| `receipt_error/2` totality | `acpc-w1-cycle-fleet-receipt-error-totality` | `…cycle-fleet-make-receipt-error-2-total-s-0-r` | #12524 | clean; additive only, #11697 seal byte-identical |
| SCIM element shape | `acpc-w1-scim-scalar-member-guard` | `…scim-guard-the-element-shape-so-a-scalar-1-r` | #12525 | clean; 5 crash shapes + the false-refute pin |
| tasks `kind` / `dataset` | `acpc-w1-tasks-edges-kind-and-dataset` | `…tasks-controller-400-on-a-list-valued-ed-2-r` | #12526 | clean; D62 asymmetry built and commented at both sites |
| SSO list-param (HIGH-FLIP) | `acpc-w1-sso-list-param-guard` | `…sso-callbacks-guard-the-action-heads-so--3-r` | #12528 | clean; reachability re-derived by review, second reviewer still owed |
| bulldocs `?dataset[]=` | `acpc-w1-bulldocs-dataset-cast-guard` | `…bulldocs-guard-the-query-string-dataset--4-r` | #12529 | one review commit (test-discoverability pointer) |
| listen `chunk/2` bind | `acpc-w1-listen-chunk-hard-bind` | `…listen-controller-guard-the-welcome-fram-5-r` | #12531 | reported not-green, **is green** on a quiet host |

**Nothing stalled.** The one "stall" was an instrument artefact: every builder reported a
noisy wide gate (4-8 failures, a different failing set each run, always carrying
`Postgrex.Error FATAL 53300 too_many_connections` or `40P01 deadlock_detected`) because ~30
concurrent worktrees share one local test Postgres. Review re-ran all six wide gates on a
quiet host and every one is a literal zero: 1716 / 1720 / 1719 / 1722 / 1717 / 1714 tests,
0 failures. Two consequences worth carrying forward:

1. **The listen slice was misclassified.** Its gate failed only under that load. Its work
   was complete, committed, and correct; it is delivered as #12531. A wave that trusts its
   harness's green/not-green flag without re-running on a quiet host loses real work.
2. `acpc-preexisting-workspace-import-token-reds` (filed for 5 "pre-existing reds on clean
   origin/main") is refuted — those files are green here. Close it rather than chase it.

**A recurring incident, now three-for-three.** Three of six builders mis-popped a foreign
slice out of the repo-GLOBAL stash stack; the stash list already carried six historical
`MISPOP-RECOVERY` entries from prior waves. `git stash push` / `git stash pop` is shared
across every worktree in a checkout. RULE for every future wave, and it belongs in the
builder brief next to D67: a baseline probe uses `git diff > file` + `git checkout -- <paths>`,
or `git checkout origin/main -- <paths>` and restore from the branch — **never** bare
`stash push`/`stash pop`. Review used `git checkout origin/main -- <path>` for all six
mutation proofs and had no incident.

**Re-derived by review, not re-read** (each independently confirmed against `origin/main`):
the `:sso_browser` pipeline really is three plugs with no auth plug; `endpoint.ex` really
has `signing_salt` and no `encryption_salt`, so the OIDC arm is a same-session replay and
not an anonymous crash; the `chunk/2` census is 11 sites / 10 guarded (D65 corrected above);
and every one of the six mutation proofs reds exactly as claimed, including the source
controller's guard reverted **alone** (stack at `bulldocs_source_controller.ex:41`).

**One reachability precision the lead should carry into merge:** the SAML crash is
unauthenticated, but `Base.decode64/2` sits behind `%SamlConnection{} <- c || :no_conn`, so
it additionally requires an org slug with SAML *configured*. Anonymous, not arbitrary. The
bulldocs finding went the other way — the brief said AUTHENTICATED and it is in fact
anonymously reachable via the flat `:public_root` routes.

**Next wave should take** the charter's own wave-2 candidates, in this order: (a) the
partial-private-error-constructor census — D63's class, grepped repo-wide rather than
file-by-file, since `receipt_error/2` is unlikely to be the only error builder called with
more argument values than it has clauses; (b) the controller census remainder with the
D68-corrected instrument; (c) conn-level coverage for `webhook_controller` replay/test-send
and `tickets_attachments`, which ship with zero controller tests — that absence is *why*
their seams went unexamined. `share_controller` / `share_link_controller` stay FILE-only
under D66 until #12404 and #12405 merge.

### Epic charter — Rate-limit & quota atomicity: closing a fail-open race, refusing to half-fix its twin

Epic task: `api-controller-plug-correctness-audit`
Wave Paper: `rate-limit-quota-atomicity-wave-2026-08-19`
Wave referent: `acpc-wave-2-log`
Audited against origin/main `122fd0df81b8e76d179a96cea8fadfbb09dacc3b`.

#### Wave 2 — rate-limit & quota atomicity vision

Two fail-open concurrency defects were confirmed and filed by the just-completed HTTP controller/plug audit, both out of that wave's fence. Both let a caller exceed a limit under exactly the concurrency the limit exists to bound. This wave closes ONE of them properly, refuses to half-fix the other, and overturns an inherited premise and a prior "verified, no change" stamp while doing it.

**The limiter race (CLOSED this wave).** `api/lib/barkpark/rate_limiter.ex` `check/2` commits a token-bucket debit as two separate ETS operations — `:ets.lookup(@table, key)` then an unconditional `:ets.insert(@table, {key, refilled - 1.0, now_ms})`. Per-object atomicity buys nothing across two calls. At bucket `{k, 1.0, t}`: A lookups and reads `1.0`; B lookups before A inserts and reads the SAME `1.0`; A computes `refilled = 1.0`, passes `>= 1.0`, inserts `{k, 0.0, now}`, returns `:ok`; B computes `1.0` from its stale read, passes, inserts `{k, 0.0, now}`, returns `:ok`. Two admissions, one debit — generalising to N-1 extra admissions per contended window. Measured in ExUnit against the real module: at capacity 50 with 200 barrier-released callers, **all 200 were admitted, in 20 of 20 rounds**. The limit is not merely over-drawn; under contention it is effectively absent. Reachability is proven NON-ADMIN and in fact fully UNAUTHENTICATED: `BarkparkWeb.Plugs.AuthWriteRateLimit` is mounted at `router.ex:592` on the `POST /v1/auth/register` path whose `:user_auth` pipeline carries no token, session or admin plug. Over-admission there is over-mailing a third party, which is precisely the ceiling that plug exists to enforce.

**The quota race (FILED SHARPENED, not fixed).** `api/lib/barkpark/tenancy/quota.ex` `within_quota?/1` is `usage(id) < quota`, where `usage/1` is a live `Repo.aggregate(:count)`. `BarkparkWeb.Plugs.RequireWithinQuota` halts BEFORE the controller runs; the quota-relevant writes then open their OWN transactions in different modules. The check and the write are in different transactions, in different modules, at different points in the request lifecycle. That is a category fact, not a difficulty: **no change confined to `quota.ex` can be atomic against a write that is not in scope of the check.** Every correct fix — a trigger-maintained counter column with a CHECK constraint, a conditional INSERT, a serializable transaction, a per-workspace advisory lock — lands in a migration, in `content/`, or in `media/`, i.e. outside this fence by construction. A narrowed window inside `quota.ex` would be fail-open AND believed fixed, which is worse than the defect.

The wave's shape is therefore asymmetric on purpose. It spends its full rigor on the finding that can actually be closed, and pays the other in the only currency it can honestly accept: a re-derived interleaving, a reproducible demonstration that runs in the suite in under a second, and a costed design menu with one option explicitly refuted.

### Wave 2026-08-19 — wave 2 (grade A-)

**Landed (2 round-1 slices; both gates re-run green on the reviewer's `-r` branches, both rebased onto `bf499f54b6` and pushed):**

- **S1 — the token bucket is atomic** (`acpc-w2-ratelimiter-cas-atomic-debit`, final branch `loop-epic/ratelimiter-commit-the-token-bucket-debi-0-r`, **PR #12579**). `check/2` delegates to `debit/4` with `@max_commit_attempts 128`; the existing branch commits via `:ets.select_replace/2` pinning the exact tuple read, the cold branch via `:ets.insert_new/2`, and exhaustion returns `:rate_limited` — fail CLOSED. D70's refutation of the inherited "update_counter is integer-only, so it needs a GenServer" premise held all the way to the merge. A **second race the filed finding never named** was closed with it: the cold branch let N callers each insert a FULL bucket (29–32 admitted at capacity 5). Semantics preserved by construction — `elapsed_s`, `refilled` and `refilled >= 1.0` are all context lines in the diff, and `rate_limiter_test.exs` is byte-unchanged and green.
- **S3 — the quota is demonstrated, not patched** (`acpc-w2-quota-toctou-demonstration`, final branch `loop-epic/quota-demonstrate-the-count-then-compare-1-r`, **PR #12580**). `git diff origin/main -- api/lib/barkpark/tenancy/quota.ex` prints nothing, as D82 required. Four legs, the staged and batch ones deterministic; leg 4 refutes the filed task's own "up to the concurrency factor" bound (D87) and survives any fix to the race. `acpc-bl-quota-toctou` patched and re-published with all five corrections and the ranked costed menu.

**D76 was the wave's best call, and the reviewer's own measurement is what proves it.** At `ELIXIR_ERL_OPTIONS="+S 1" --max-cases 1` the byte-verbatim twin over-admitted in **0 of 20 rounds** while the seam-widened twin asserted green in all 20. A verbatim per-round assertion would have been permanently red on a 1-vCPU CI runner; a fixed-limiter-only assertion would have been vacuous there. The two-twin split is the only shape that is both honest and CI-safe.

**The guard is able to fail, re-proven independently.** The reviewer restored origin/main's `check/2` into the tree and re-ran: **6 of the 9** concurrency tests red, including `round 1: admitted 200 of 200 at capacity 50` and `round 1: cold-key race admitted 32`.

**Reviewer fixes (both on the `-r` branches — integrate `-r`, never the originals):**
- S1: the barrier's `assert_receive` liveness bound moved 5s → `@barrier_timeout_ms 60_000`. `race/2` hands the scheduler 200 busy-spinning processes and then drains 2N messages, so on a 1-vCPU runner a receive timeout was the likeliest red — and it would have read as "the limiter over-admitted".
- S3: leg 2 asserted the exact `admitted == 8`, the file's only scheduling-dependent number, in a file that asserts BROKEN behaviour. It now asserts `admitted > 1` (non-vacuous because leg 3 pins the sequential answer at exactly 1) plus a conservation check. Measured 26 consecutive clean runs at `+S 1` before weakening — the change is about what a failure would *mean*, not about one being observed.

**Stalled / deferred:** `acpc-w2-ratelimiter-prune-hourly-reset` (S2) was **not built, by design** — it is round 2 and edits the same file S1 must leave byte-unchanged (D79/D80). It dispatches once S1 merges, rebased onto it.

**Ledger:** one real omission, fixed. S1's criterion 3 (the seam-widened twin's per-round assertion) was built, gated and green but left unstamped, while the builder's now-line claimed 11/12 against a ledger holding 10/12. The reviewer stamped it with first-hand re-run evidence and attributed the stamp. S3's ledger was clean (9/10, only the merge-gated row open). No task outside this wave was touched.

**Grade A-.** Both fail-open races in fence closed or honestly refused; the concurrency proof genuinely reds on the unfixed body; the refusal is a category argument, not a shrug. Short of A because S1's stamped "arithmetic unchanged" grep is exact while the same claim in its commit prose is looser than the diff supports, and because the retry budget's fail-closed behaviour at pathological widths beyond 200 contenders is reasoned rather than measured.

**Next wave:** merge #12579 first (it is S2's dependency), then #12580, then dispatch S2 rebased onto S1. **#12579 is owed an INDEPENDENT second reviewer before merge** — HIGH-FLIP on both the atomicity and preserved-semantics arguments, on a path every authenticated request crosses. The lead closes the merge-gated criteria: S1 criterion 11, S3 criterion 9.
