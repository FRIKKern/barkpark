# clk / onconflict-sql-buckets — class-C population is definitively ONE (outside the fence)

Wave: clock-semantics-wave-2026-08-19 · lane: onconflict-sql-buckets · verifier phase
All reads via `git show origin/main:<path>` / `git grep origin/main` — never the working tree.

## Verdict

The class-C (bucket / window key) population outside the fence is **ONE**:
`api/lib/barkpark_web/plugs/paper_revision_headers.ex:177`. Confirmed by closing both
leaks the two bucket-key surveyors admitted.

Two NEW sites belong in the ledger that neither lane's grep could reach — neither is
class C, and saying so out loud is the deliverable:

* `api/lib/barkpark/pulse.ex:194` + `api/lib/barkpark_web/controllers/pulse_controller.ex:127`
  — an **anonymous** `daily_cap` (5000/UTC-day) bound whose reset instant is a wall-clock
  UTC midnight (`DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])`).
  Highest-reachability wall-clock-derived quota bound in the repo. Invisible to `div(`,
  invisible to `on_conflict`. **Class A** (cutoff vs. stored `inserted_at`), residual named:
  a FORWARD step across midnight resets the whole anonymous budget early (fail-open);
  BACKWARD counts up to two days (fail-closed). No caller can influence the clock; no
  bucket KEY, so no straddle and no cross-key delete — the #12628 mechanism is absent.
  A monotonic rewrite is IMPOSSIBLE: the compared column is wall clock.
* `cloud/lib/barkpark_cloud/accounts/two_factor.ex:83` — `div(time, 30)` where
  `time = now + offset * 30` and `now \\ System.os_time(:second)`. This is the SECOND
  instance of the div-through-a-variable leak (TOTP was the first), proving the leak is
  real. Class C mechanics, **correct by construction** (`Accounts` rejects step `<= ` the
  persisted one with a `<` ordering predicate — #12628's shape, applied prophylactically).

## Re-derivation recipes

### (a) on_conflict / counter-update conflict targets — ALL identity, zero time-derived

    # 38 files carry the token; 42 conflict_target lines
    git grep -ln 'on_conflict' origin/main -- api/lib cloud/lib | wc -l
    git grep -nE 'conflict_target' origin/main -- api/lib cloud/lib

    # the counter-update population is exactly 6 real sites — NOTE: `git grep -E '\binc:'`
    # returns ZERO (the \b escape does not bind in this engine). Use -F:
    git grep -n -F 'inc:' origin/main -- api/lib cloud/lib

Counter sites and their keys — every one an IDENTITY:
pulse.ex:183 `:channel` · pulse.ex:269 `:name` · studio_chat.ex:611 `s.id` ·
studio_chat.ex:2131 `s.id` · studio_chat.ex:2430 `s.id == ^session_id` (no budget /
spend_cap / max_cost is enforced against this accrual) · sync/dead_letter.ex:54
`[:source,:dataset,:event_id]` · webhooks.ex:487 `w.id == ^endpoint_id`.

15 files use `on_conflict` with NO `conflict_target` (`:nothing` / `{:replace, …}` on the
PK) — no key is named at all, so none can be time-keyed. List them with:

    ct=$(git grep -ln 'conflict_target' origin/main -- api/lib cloud/lib | sed 's|^origin/main:||')
    for f in $(git grep -ln 'on_conflict' origin/main -- api/lib cloud/lib | sed 's|^origin/main:||'); do
      echo "$ct" | grep -qx "$f" || echo "NO-TARGET: $f"; done

### (b) raw SQL / fragment quantisation — a definitive ZERO

    for t in date_trunc to_char "age(" "NOW()" CURRENT_TIMESTAMP INTERVAL "interval '"; do
      echo -n "$t -> "; git grep -c -F "$t" origin/main -- api/lib cloud/lib \
        | awk -F: '{s+=$NF} END{print s+0}'; done
    git grep -nE '"[^"]*\bnow\(\)' origin/main -- api/lib cloud/lib   # 0 hits

`date_trunc` 0 · `NOW()` 0 · `CURRENT_TIMESTAMP` 0 · `INTERVAL` 0 · `interval '` 0.
BEWARE two substring traps that inflate a naive count: `to_char` → 73 is all
`String.to_charlist`; `age(` → 374 is all `Exception.message(` / `_message(`; `now()` →
383 is all `DateTime.utc_now()`. Word-bound or fixed-string, then eyeball.
The single SQL `now()` in the repo (`api/lib/barkpark/access/grant.ex:33`) is PROSE inside
a `@moduledoc`; the executable predicate is Elixir-side `active_where/2`
(`api/lib/barkpark/access.ex:459-465`, `g.expires_at > ^now` with `now` bound in from
`DateTime.utc_now()` at :112/:142/:159) — class A.
Every `Repo.query!` body is `pg_advisory_xact_lock` / `SET LOCAL pg_trgm…` /
`pg_total_relation_size` / `set_config` / `SELECT 1` / catalog-literal `DELETE`s —
zero time expressions. `fragment(` hits carrying a time term are
`fragment("EXCLUDED.updated_at")` (sync cursors) and deploy_ledger's keyset
`fragment("(?,?) < (?,?)")` (a transmitted instant + PK — class A).

### (c) idempotency.ex — class A, NOT #12628's shape

    git show origin/main:api/lib/barkpark/idempotency.ex | sed -n '95,150p;215,240p'

`conflict_target: :key_hash` is `sha256(raw_key|token_id|method|path)` — an identity, no
quantisation anywhere in the module. The claim window is `stale?/2`:
`DateTime.diff(now, ts, :second) >= pending_ttl_seconds()` — a clock compared against the
row's own stored `inserted_at`. `sweep(now \\ DateTime.utc_now())` deletes
`inserted_at < cutoff` — **strictly-older only, and per-row, never per-bucket**, which is
already #12628's post-fix shape by construction. BACKWARD step: pending rows look fresher
→ `:in_progress` → 409 → fail-CLOSED. FORWARD step > `pending_ttl` (60s): a live
reservation looks crashed and is reclaimed → double execution — but that is the module's
documented TTL tradeoff, not a clock-semantics defect, and the wish forbids changing TTLs.
`reclaim/4`'s WHERE re-checks state+age atomically so only one reclaimer wins.

### Non-div quantisers, second pass (confirming the earlier lane's zero)

    git grep -nE 'DateTime\.to_date|Date\.utc_today|beginning_of_|end_of_|Timex\.' \
      origin/main -- api/lib cloud/lib
    git grep -nE '(rem|trunc|floor_div|ceil)\([^)]*(system_time|os_time|utc_now|unix)' \
      origin/main -- api/lib cloud/lib   # 0 hits

31 hits. `pulse.ex:194` is the ONLY bound-bearing one (above). The rest: sheets formula
engine (TODAY/DATEDIF/serial), search analytics periods (crystallizer / intelligence /
synonyms — reporting rollups, `crystallize_period` upserts idempotently), `tasks/query.ex`
`bucket_key/2` day|month|week (a DISPLAY grouping label over stored timestamps, no bound),
`content/writer.ex:448` `$today` template dynamic, `media.ex:62` `date_dir` (a storage
PATH segment; uniqueness comes from `unique_filename/1`, not the date),
`mix barkpark.rotate_public_read` label.

### Fence check

`git show --stat 8598c4efe7` names both fenced cloud limiters:
`cloud/lib/barkpark_cloud/device_auth/rate_limiter.ex` and
`cloud/lib/barkpark_cloud/accounts/two_factor_rate_limiter.ex`. Their
`window = div(now_ms, @window_ms)` sites (`:89` and `:53`) are class C and already fixed —
cite, do not re-pave. `api/lib/barkpark/rate_limiter.ex` (#12579, `e45f1377bb`) likewise.
