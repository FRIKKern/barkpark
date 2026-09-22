# The per-op cost of `Caps.derive/1` at the paper write chokepoint

`pds-w42-bl-caps-derive-per-op-cost-unmeasured`, measured 2026-09-16.
The harness is `pds_w42_caps_derive_op_latency_test.exs` beside this file.

## The call count — 2 derives per op, on BOTH routes, and not the same 2

Counted by an `:erlang.trace` on the **live view process** across a real paper
block op that actually wrote to the store (the assertion reads the store back,
so a no-op could not be priced as an op). Not by `grep -c`: every call site on
this path is reached through a `defdelegate`, a `handle_info` hop or an
`attach_hook`, and a source count sees none of them.

| route | derives | from `write_denied?/1` | from the socket gate |
|---|---|---|---|
| component (`handle_info` → `paper_pane_op/2`) | 2 | **2** | 0 |
| `paper-op` event | 2 | **1** | 1 |

So the derives **this row's fix added** are 2 on the component route and 1 on
the event route. The component route has no socket gate at all — an
`attach_hook(_, :handle_event, _)` cannot see a `handle_info`, which is the
bypass `pds_w42_paper_op_principal_gate_test.exs` was filed to close — and it
enters the write seam twice per composite-field commit (`inner-change`, then
`inner-flush`).

Two corrections to the record, both by run:

* The row's premise says `write_denied?/1` adds **a** derive per op. On the
  component route — the one the row names — it adds **two**.
* `pds_w43_caps_derive_cost_test.exs` says the grant `Repo.all` is issued
  "UNCONDITIONALLY on every `derive/1`". Read as "not memoized" that is true.
  Read literally it is not: `active_grants/1` matches on
  `assigns.current_user` and returns `[]` without a query for any socket
  without one, so an **API-token** Studio socket never pays the grant load.

## The price of one derive

**Load-invariant units, ASSERTED in the harness:**

| principal shape | repo queries | reductions |
|---|---|---|
| API-token socket | 2 (`%ApiToken{}` reload + membership) | ~3.3k–4.0k |
| user socket | 2 (membership + grant `Repo.all`) | ~3.6k |

**OS-metered price — LOCAL, meter NAMED.** `/usr/bin/time -l` around
`LC_ALL=C bash -c`, so the BEAM and every port child are inside the meter. An
A/B: the same file run with `CAPS_DERIVE_BENCH_N` low and high, differenced
**inside one load stamp** (PDS-D656 — no figure here is a ratio across two
stamps taken at different loads).

```
bash caps-meter.sh <worktree> 200 5000 3      # n = 19,200 derives per A/B pair
# arm: LC_ALL=C bash -c "MIX_TEST_PARTITION=… CAPS_DERIVE_BENCH_N=<n> \
#                        mix test test/barkpark_web/live/studio/pds_w42_caps_derive_op_latency_test.exs"
```

n = 19,200 derives differenced, 3 trials. **RE-RUN ON A QUIET HOST
2026-09-22T11:47Z** (lead-api-r21o), `load1` 5.10–5.33 on **10 cpus** —
under-subscribed, where the 2026-09-16 run was 2x over:

| trial | load1 | CPU user+sys / derive | wall / derive |
|---|---|---|---|
| 1 | 5.10 | 98 µs | 0.096 ms |
| 2 | 5.33 | 107 µs | 0.130 ms |
| 3 | 5.15 | 96 µs | 0.112 ms |

**Band 96–107 µs CPU per derive; QUOTE THE HIGH END: 107 µs.**
Per op (2 derives): **≤ 0.215 ms CPU** — ~0.043% of the 500 ms debounce window.

The 2026-09-16 band was 204–223 µs (quote 223) at `load1` 20.5–23.6. The quiet
host reads **2.08x cheaper**, which is the direction contention predicts: CPU
accounting inflates under oversubscription. The DECISION below is unchanged and
is now argued from a smaller number, not a larger one.

**HOW n = 19,200 IS DERIVED, because the figure cannot be checked without it:**
`price!/2` runs `Enum.each(1..@ops, …)` **twice** (once inside `queries_during/1`,
once between two `Process.info(:reductions)` reads) and is called at **two** sites
(`"API-TOKEN socket"`, `"USER socket"`). So one arm costs `4 × @ops` derives and
the A/B difference is `4 × (5000 − 200) = 19,200`. Reproducing the documented n
from the source is the control that the per-derive arithmetic is right; a reader
who assumes `Δ = 4800` gets a band 4x too high.

**THE 2026-09-16 HARNESS RUN WAS SILENTLY MEASURING NOTHING ON THIS BOX, and the
first re-run reproduced that.** `caps-meter.sh` redirects its arm to
`>/dev/null 2>&1`, so when `mix test` dies before running a single test the meter
still prints a clean, plausible timing row. On this machine `cc` is a shell alias
to Claude Code, so `argon2_elixir`'s NIF build fails with `error: unknown option
'-g'` and the run aborts in under a second — six rows, zero tests, no A/B
difference at all (n=200 and n=5000 both ~0.5 s). The tell was the script's own
header: *"A meter that reads zero is broken, not fast."* Run it as
`CC=/usr/bin/cc bash caps-meter.sh …`, and before trusting any row, run one arm
WITHOUT the redirect and read `N tests, 0 failures`.

Three things this price does NOT cover, said here rather than left implied:

* **Postgres' own server-side CPU.** The server is not a child of the metered
  shell. The client-side round-trip cost is inside the meter; the backend's
  work is not.
* **A quiet host — SATISFIED as of the 2026-09-22 re-run** (`load1` 5.10–5.33
  on 10 cpus, under-subscribed). The 2026-09-16 run was ~21 on 10, 2x over, and
  its **wall** column was that load rather than the code's cost. The wall column
  above is from an under-subscribed box and is still the weaker number: the CPU
  column is far less load-sensitive and the reductions row is load-invariant,
  which is why the harness ratchets reductions and asserts no millisecond at all.
  Nothing here is asserted in the suite; this file is the record, the ratchet is
  the guard.
* **A grantee.** These principals hold no grants; `Access.admits_desk?/3`
  re-validates the grantor per action and issues its own queries.

## THE DECISION — no cache. Freshness stands.

**Do not add a short-TTL per-socket memo.** The measured marginal cost does not
buy enough to pay for what it would cost:

1. **It is small against the window it lands in.** The editor debounces at
   `phx-debounce="500"`. ≤ 0.45 ms of CPU per op is ~0.09% of that window.
   There is no keystroke-path CPU problem to solve.
2. **The thing it would buy back is the thing the gate exists for.** The 2
   queries per derive ARE the membership/token reload and the grant load. A TTL
   memo of length *T* means a membership revoked, a role downgraded, a token
   revoked or a grant expired keeps writing for up to *T*. That is the exact
   stale-assign hole `Caps`' moduledoc calls out and that
   `caps_principal_freshness_test.exs` closes.
3. **The honest cheaper win costs no fidelity and is not a cache.** The
   component route calls `write_denied?/1` **twice** per field commit
   (`inner-change`, then `inner-flush`) — a genuine duplicate within one user
   action, not a freshness feature. Collapsing that is a ~50% cut to this
   row's added cost with no expiry-truth trade at all. Filed separately rather
   than smuggled into a measurement row.

The ratchet that keeps this decision honest is in the harness: the query counts
are asserted, and the failure message says which direction is dangerous — a
**drop** to 1 means the grant load was memoized away and the trade was made
without a decision.
