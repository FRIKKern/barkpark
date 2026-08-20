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
- **D33 — D87's shape is honoured by changing the SOURCE, never the KEY; and #12628's "tolerate the duplicate" shape is CONTRAINDICATED here.** Why: D87 requires prebuilt's `{:duplicate,…}` be "structurally unreachable" and requires a nonce key distinct from `force`'s — the swap keeps both. Tolerating the duplicate cannot work because `recover_conflict/3` reaches that tuple by TWO lookups (a repeat build_id AND the deploy-truth-W1 active-production coalesce), cannot tell them apart, and `router_sites_test.exs:2678` asserts the coalesce as INTENDED. Any diff that merges `:prebuilt_nonce` and `:force_nonce` into one key is the D86 violation.
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
