# clock-semantics: class-C etag bucket verdict — re-derivation recipe

Site: `api/lib/barkpark_web/plugs/paper_revision_headers.ex:177`
`bucket = div(System.os_time(:second), @bucket_seconds)` (@bucket_seconds 604_800, line 86)
Baseline: origin/main @ 1f981ec42d837a46de228283d4c6d8762ba38988

## Verdict: class C, CITED, NOT FIXED. Class-C column = "1 censused, 1 cited, 0 fixed".

## Premise (a) — 14-day LiveView bound, from the LOCKED version not a stray deps tree
    git show origin/main:api/mix.lock | grep -o '"phoenix_live_view": {[^}]*}'
      -> "phoenix_live_view", "1.1.28", ...
    grep -n 'version' api/deps/phoenix_live_view/mix.exs | head -3
      -> 4:  @version "1.1.28"            # deps tree IS the locked version
    grep -n 'max_session_age' api/deps/phoenix_live_view/lib/phoenix_live_view/static.ex
      -> 18:  @max_session_age 1_209_600  # = 14 days
      -> 32:  Phoenix.Token.verify(..., max_age: @max_session_age)   # attribute, no option
    grep -rn 'max_age' api/deps/phoenix_live_view/lib/
      -> only static.ex:32 (session) and utils.ex:537 (@max_flash_age). No config path.
    git grep -nE 'live_view|max_age|session_age' origin/main -- api/config/
      -> config.exs:44 `live_view: [signing_salt: "MXGKAyTI"]` ; config.exs:316 Oban Pruner. NO max_age override.
  => 14 days is a compile-time constant of the locked dep; 7-day bucket < 14-day bound; slack = 7 days.

## Premise (b) — the "already pinned" claim is a RUN, not a reading
    git status --porcelain / git diff origin/main --stat on the plug + its test -> EMPTY (files == origin/main)
    cd api && MIX_ENV=test mix test test/barkpark_web/plugs/paper_revision_headers_test.exs
      -> 16 tests, 0 failures (0.5s)
    Deciding test: "time bucket (D9) / an adjacent bucket window flips the 304 back to 200"
    (test file lines 140-151): a candidate carrying `current_bucket() - 1` gets 200, not 304.
    A client cannot forge an old bucket: If-None-Match candidates are weak-compared against
    the tag the server JUST computed (if_none_match?/2, lines 181-192).

## Why no #12628 analogue (the refusal)
    git grep -n 'weak_etag\|@bucket_seconds' origin/main -- api/
      -> bucket appears ONLY in defp weak_etag/1 (176-179), single caller respond/2 (157).
    No shared mutable state is keyed by the bucket; the value is interpolated into a response
    header and discarded. #12628's "stale writer deletes a newer bucket" has no analogue.
    Boundary straddle costs one extra full 200. cache-control is `private, max-age=0,
    must-revalidate` (respond/2) and `git grep -riE cache origin/main -- deploy/` finds no
    proxy/CDN cache, so only private browser caches hold a body at all.

## Clock step, both directions
  FORWARD: bucket advances early -> tag changes early -> extra 200s. Bound still holds (tightens).
  BACKWARD: re-issues an already-handed-out bucket. To validate a body older than 14 days the
    clock must return into that body's original 7-day window, i.e. a backward step of at least
    ONE BUCKET WIDTH (604_800s = 7 days). Consequence is a LIVENESS bound (revived HTML with an
    expired LV token dead-loops the client), not authorization.
  CALLER INFLUENCE: none. No request param or header feeds the bucket; only host clock does.
  Inherited premise (from wave digest, not re-derived here): System.os_time bypasses BEAM
  time-warp, so the exposure does not depend on the VM's time-warp mode.

## Why re-keying to monotonic would be WRONG here (same reason as class D)
    fleet_hub.ex:105 argues it in-repo: monotonic RESETS on restart, which is exactly when the
    fence must change. A monotonic-anchored 7-day bucket would need a PERSISTED watermark to
    survive restart — a new mechanism the wish forbids ("do not introduce a new time
    abstraction module"). Residual: named, unfixed, deliberately.
