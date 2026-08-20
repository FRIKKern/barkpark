<!-- doc-tier: cold | canonical-for: none | budget: 800tok -->
# Re-derivation recipe — tripwire-p1-exact (cloud provider-raw-body-leak wave)

Pin: origin/main @ 7114fac139fea305a2070cef08826612151b6456 (2026-08-18).

## Claim A — P1 keyword-colon predicate is exact + FP-free

    git grep -nE '(reason|detail|message|error):[[:space:]]*inspect\(' origin/main -- cloud/lib

Expect EXACTLY 3 hits, all cloud/lib/barkpark_cloud/web/router.ex: 12236, 13898, 13981 (the three transport deploy/upload sites).

    git grep -nE '(reason|detail|message|error):[[:space:]]*inspect\(' origin/main -- cloud/lib | grep -i logger      # expect EMPTY (0 Logger FPs)
    git grep -nE '(reason|detail|message|error):[[:space:]]*inspect\(' origin/main -- cloud/lib | grep -v router.ex   # expect EMPTY (0 outside router.ex)

Verdict: P1 is clean — safe to ship as a zero-count regression tripwire (D-d).

## Claim B — #{inspect} interpolation variant is DIRTY (4 Logger FPs), so D-d must ship P1-only

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -nE '#\{inspect\(' | grep -vi logger

Expect 5 survivors: 8830, 9987, 11436, 13448 (all multi-line Logger.log/error/warning continuations — "Logger" is on the PRIOR physical line so the single-line grep -vi logger cannot drop them) + 12121 (the ONE real crown client leak: json(conn, 502, %{error: "cloudflare_bind_failed", detail: "...#{inspect(reason)}..."})).

Verdict: the interpolation grep cannot be made false-positive-free by a line-local logger filter → NOT usable as a tripwire. D-d ships the P1 keyword-colon grep only. NOTE: P1 does NOT cover the crown (12121 uses interpolation in detail:); the crown needs its own per-site mutation test, not the class tripwire.
