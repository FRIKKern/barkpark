# http-edge-truth W1 — pins-run-proof re-derivation recipes (2026-08-08)

Verifier assignment `[pins-run-proof]`. Recipes only — no derived values are
authoritative here; re-run to get today's truth. All test files were confirmed
byte-identical to `origin/main` before running (local checkout is 671 commits
behind, but these four paths carry zero drift).

## R1 — the three load-bearing suites are green, and what the default run SKIPS

```
cd api && git diff --stat origin/main -- \
  test/barkpark_web/integration/media_delivery_test.exs \
  test/barkpark_web/controllers/scoped_paper_controller_test.exs \
  test/barkpark_web/plugs/paper_reader_csp_test.exs      # must print nothing

CC=clang MIX_ENV=test mix test test/barkpark_web/integration/media_delivery_test.exs
CC=clang MIX_ENV=test mix test test/barkpark_web/integration/media_delivery_test.exs --include requires_vips
CC=clang MIX_ENV=test mix test test/barkpark_web/controllers/scoped_paper_controller_test.exs
CC=clang MIX_ENV=test mix test test/barkpark_web/plugs/paper_reader_csp_test.exs
```

Read the ExUnit header line `Excluding tags: [...]` — `:requires_vips` present
means the rendition pin at `media_delivery_test.exs:136` did NOT execute. The
delta between the first two runs (test count and the exclusion count in
`N tests, 0 failures (M excluded)`) is the whole vips question. Confirm the
toolchain independently with `which vips`.

## R2 — the two slice-2 co-change pins, by line

```
cd api && grep -n 'cache-control\|@tag :requires_vips' \
  test/barkpark_web/integration/media_delivery_test.exs
```

## R3 — slice-1 gate/etag blast radius in scoped_paper_controller_test

```
cd api && grep -n 'assert_revision_headers\|released_revision_id\|canonical_digest\|pin_released_revision' \
  test/barkpark_web/controllers/scoped_paper_controller_test.exs
git show origin/main:api/lib/barkpark_web/plugs/paper_revision_headers.ex
```

The helper `assert_revision_headers/2` is the single pin for BOTH the
`x-barkpark-paper-revision` value and the exact ETag string shape; the
`Paper revision response authority` describe pins the negative (missing +
draft ⇒ no headers). Judge any gate widening against the helper, not the
call sites.

## R4 — slice-3 before-state, in test env AND on live prod (the mutation-proof baseline)

Throwaway probe (write, run, `trash` it, then `git status --short -- api/`
must be empty):

```
# api/test/scratch_static_headers_probe_test.exs
defmodule Barkpark.ScratchStaticHeadersProbeTest do
  use BarkparkWeb.ConnCase
  test "static before-state" do
    for p <- ["/fonts/Inter-var.woff2", "/assets/bp-graph.js"] do
      c = build_conn() |> get(p)
      IO.inspect(%{path: p, status: c.status,
        cache_control: get_resp_header(c, "cache-control"),
        etag: get_resp_header(c, "etag"), vary: get_resp_header(c, "vary")}, label: "PROBE")
    end
  end
end
```

Live counterpart — note that `api.barkpark.cloud` is the CLOUD control plane
(a different app with its own statics doctrine), NOT the Studio/API host:

```
for h in http://89.167.28.206 https://guerrilla.barkpark.cloud https://api.barkpark.cloud; do
  for p in /assets/bp-graph.js /fonts/Inter-var.woff2 /robots.txt; do
    echo "== $h$p"; curl -sSI --max-time 20 "$h$p" | grep -iE '^HTTP|cache-control|etag|vary'
  done
done
```

## R5 — is the static ETag content-derived? (decides whether an etag can prove anything)

```
grep -n 'etag_for_path' -A 10 api/deps/plug/lib/plug/static.ex
```

## R6 — is a font actually content-stable under one filename?

The cloud doctrine's fonts-immutable arm rests on this premise. Test it per
file, per app, by counting DISTINCT blobs the path ever held:

```
for f in $(git ls-tree -r --name-only origin/main | grep '^api/priv/static/fonts/'); do
  n=$(for c in $(git log --format=%H --all -- "$f"); do git rev-parse "${c}:${f}" 2>/dev/null; done | sort -u | wc -l)
  echo "$n $f"
done
# repeat with '^cloud/priv/static/fonts/'
```

ZSH TRAP: `git rev-parse $c:api/...` (unbraced) applies the zsh `:a` history
modifier and silently returns a bogus absolute path. Always brace: `"${c}:${f}"`.

## R7 — where the ported doctrine comes from, verbatim

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '355,400p'
```
