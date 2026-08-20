# Re-derivation recipe — clock-semantics: dynamic-dispatch hole in the time-as-input refutation

Verifier lane `dynamic-dispatch-hole`, wave `clock-semantics-wave-2026-08-19`.
All commands read `origin/main` (never a working tree). Run from repo root.

VERDICT: the hole is CLOSED. Zero dynamic paths carry a caller-influenced time
value into a bound. The static refutation stands, and its denominator was WRONG
LOW (23 defaulted-time functions on origin/main, not 19).

## 1. apply/2 and apply/3 — 12 sites, none reaches a time-defaulted function
    git grep -nE 'apply\((__MODULE__|[A-Z][A-Za-z.]+), *:' origin/main -- api/lib cloud/lib
    git grep -nE 'apply\([a-z_]+, *[a-z_]+, *\[|apply\([a-z_]+, *\[|:erlang\.apply' origin/main -- api/lib cloud/lib
8 module-literal + 4 `resolver_chain.ex` (274/439/441/444) dispatching plugin
resolver callbacks with `[prev, ctx]` / `[]` / `["production"]`. No time arg.

## 2. Task/spawn MFA form — zero sites (grep exits 1)
    git grep -nE '(spawn|spawn_link|Task\.async|Task\.start|Task\.start_link|Task\.Supervisor\.(async|start_child))\(' origin/main -- api/lib cloud/lib | grep -E ', *:[a-z_]+, *\['

## 3. Oban args — 48 arg-key reads in 8 worker files; exactly ONE time-ish key
    git grep -nE 'def perform\(%Oban\.Job\{args:' origin/main -- api/lib cloud/lib
    git grep -nE 'Map\.get\(args|Map\.fetch!?\(args|args\["' origin/main -- api/lib cloud/lib
    git grep -niE '(Map\.get\(args|args\[)[^)]*"(now|now_ms|date|ts|time|timestamp|issued_at|as_of|exp|iat|since|until|at)"' origin/main -- api/lib cloud/lib
Sole hit: `api/lib/barkpark/search/workers/crystallize.ex:10` `Map.get(args,"date")`.
(`prune.ex:9` reads `"retention_days"` — a retention BOUND, not a time value.)

## 4. Crystallize reachability — cron only, zero HTTP/LiveView enqueue
    git grep -n 'Crystallize' origin/main -- api/lib
    git grep -n 'SearchAnalyticsCrystallize\|Workers.Crystallize\|Workers.Prune' origin/main
Only producer is `api/config/config.exs:319` `{"30 3 * * *", …Crystallize}` (cron
args `%{}` → `date` nil → `Date.utc_today()`). No `Crystallize.new(` exists
anywhere in the repo. Same for Prune (`config.exs:327`).

## 5. The real defaulted-time census — 23, not 19
    git grep -nE '\\\\ *(System\.(system_time|os_time|monotonic_time)|DateTime\.utc_now|NaiveDateTime\.utc_now|Date\.utc_today|:os\.system_time)' origin/main -- api/lib cloud/lib
Plus a SECOND family the `\\`-default regex misses entirely — opts-injected
clocks read with `Keyword.get(opts, :now|:issued_at_ms)`:
`media/blobstore/s3/presign.ex:48`, `connectors/connect_ticket.ex:130`,
`tasks/board.ex:158/:392/:801`, `tasks/fleet.ex:129`, and `preview_token.ex:25`
(`Map.put_new(:exp, …)` — a caller `:exp` WINS OUTRIGHT).

## 6. Every non-arity-short call site, resolved
    bash: for each fn name, git grep -nE "\.<fn>\(|[^a-z_.]<fn>\("  origin/main -- api/lib cloud/lib
Only TWO live sites pass a time VARIABLE, both locally minted:
  chat_hosts/context.ex:400 `set_agent_state(…, now)` ← `now = DateTime.utc_now()` at :394
  studio_chat/recorder.ex:828 `touch_agent_state_at(…, ts)` ← `ts = DateTime.utc_now()` at :827
Board/Fleet (lane-marked PARTIAL) → CLOSED: all 8 call sites pass literal
keyword lists (`dataset:`, `group_by:`, `filters:`); no `:now`, no opts splat.

## 7. Presign (:now, SigV4) — unreachable because the adapter REBUILDS opts
    git grep -n 'Presign\.' origin/main -- api/lib
    git show origin/main:api/lib/barkpark/media/blobstore/s3.ex | sed -n '245,258p'
All 6 call sites construct a fresh keyword list (`expires_in:`, `extra_query:`).
Request-derived values (`:response_content_disposition`) are read from the
caller's opts and re-emitted as `extra_query` — `opts` is never forwarded whole.

## 8. Named residuals (shapes, not defects)
- `preview_token.ex:25` `Map.put_new(:exp, now + ttl)` — a caller-supplied `:exp`
  would be signed with the real key. ZERO production callers:
      git grep -rn 'PreviewToken.sign' origin/main   # → 24 hits, ALL in api/test
- `webhooks/dispatcher.ex:411 verify_signature/5` and `webhooks/webhook.ex:122
  effective_secrets/2` — zero production callers (dispatcher's own moduledoc at
  :400 says so: "grep confirms only tests call it").
- Job-args→MODULE dispatch (`String.to_existing_atom("Elixir." <> mod)`) at
  findability_posttest.ex:258-262, projector_worker.ex:423/:434,
  indexer_worker.ex:604/:616 — the enqueuers build fixed key sets, so the
  "search"/"content"/"projector"/"indexer" keys are test-only, and the dispatched
  functions (`search_documents/3`, `get_document/4`) take no time argument.
- `chat_hosts` accept_event/2 (HTTP host report) orders by a monotone `cursor`,
  never a clock — cite as the in-repo model for out-of-order safety.
