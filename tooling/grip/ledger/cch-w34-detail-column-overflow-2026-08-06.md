# cch-w34 — deployments.detail varchar(255) under a 2 KB validator: RE-DERIVATION RECIPE

Wave 34 verifier, 2026-08-06. Every line below was RUN against `origin/main`
(`edaee78edee8d5a620b7c02ef19c56c64724ba28`), not read.

## 0. The main checkout is NOT origin/main — this trap ate the first run

```
git -C /Volumes/SATECHI/github/barkpark log --oneline -1 HEAD      # a31faa52d
git -C /Volumes/SATECHI/github/barkpark rev-list --count HEAD..origin/main   # 466
```

`cloud/test/barkpark_cloud/registry_test.exs` in the working checkout is 1045
lines and does NOT contain the pinning test; `origin/main`'s is 1318 lines and
does. A `mix test` run in `/Volumes/SATECHI/github/barkpark/cloud` reports
`80 tests, 0 failures` and proves NOTHING about this defect. Run it in a
detached worktree at `origin/main`:

```
git worktree add --detach <SCRATCH>/wt-main origin/main
cp -R /Volumes/SATECHI/github/barkpark/cloud/deps <SCRATCH>/wt-main/cloud/deps
cp -R /Volumes/SATECHI/github/barkpark/cloud/_build <SCRATCH>/wt-main/cloud/_build
cd <SCRATCH>/wt-main/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/registry_test.exs
# → 90 tests, 0 failures
```

## 1. The suite PINS the defect (the guard certifies the lie)

```
cd <SCRATCH>/wt-main/cloud && CC=clang MIX_ENV=test \
  mix test test/barkpark_cloud/registry_test.exs:1041 --trace
# * test set_deployment_detail/2 (dwb-19) cch-w33-s3: a caption ABOVE the column
#   limit currently RAISES (see cch-deployment-detail-column-overflow) (38.1ms)
# 1 test, 0 failures (89 excluded)
```

## 2. The pin CAN LOSE (mutation, not a read)

Edit `registry_test.exs:1044` `String.duplicate("y", 5_000)` → `("y", 200)`,
re-run `…:1041`:

```
# Expected exception Postgrex.Error but nothing was raised
# 1 test, 1 failure (89 excluded)
```

Revert with `git checkout -- test/barkpark_cloud/registry_test.exs`.
This also fixes the threshold: 200 chars does not raise, 255 round-trips
(test at :1020), so the raise begins at exactly 256.

## 3. The route-level 500 (undocumented; @doc promises never-affects-outcome)

Drop a scratch test in `<SCRATCH>/wt-main/cloud/test/barkpark_cloud/web/`
that POSTs through the real router with the test worker token
`worker-token-test-fixed`, wrapping `Router.call/2` in try/rescue and reading
the sent response out of the process inbox (`Plug.ErrorHandler` re-raises after
sending):

```
ROUTE-300CHAR: {:raised, Plug.Conn.WrapperError,
 "** (Postgrex.Error) ERROR 22001 (string_data_right_truncation) value too long
  for type character varying(255)"}
[error] crash_envelope request_id=… status=500 method=POST
        path=/v1/builder/deployments/…/detail kind=:error
SENT-RESP-300CHAR: {500, "{\"error\":\"server_error\",\"request_id\":\"…\"}"}
ROUTE-200CHAR:     {200, "{\"ok\":true}"}
```

## 4. REACHABLE with real product data — not a synthetic 5 KB string

`internal/builder/builder.go:129` — `con.caption("Starting your build (%s)…",
refOrNone(d.GitRef))` — adds 23 characters to `git_ref`. `git_ref` is itself
`varchar(255)` with NO `validate_length` in
`cloud/lib/barkpark_cloud/registry/deployment.ex:247-301`, so every ref of
233..255 chars inserts fine and then makes its own caption overflow:

```
STEP1: {240, :git_ref_persisted}
CAPTION-LEN: 263
SENT-RESP: {500, "{\"error\":\"server_error\",\"request_id\":\"…\"}"}
DETAIL-AFTER: nil
```

## 5. Blast radius, stated honestly

`internal/builder/console.go:134` swallows the non-2xx (`caption` logs to stderr
and returns), so the BUILD does not fail — but `c.fails++` primes the shared
narration latch (`maxConsoleFails = 3`, console.go:45) and the caption is lost
with no trace on screen. Only `builder.go:129` interpolates; the other four
captions (`:153 :295 :352 :364`) are fixed short copy, so a single long ref
cannot on its own reach the 3-consecutive latch (a subsequent successful console
report resets `c.fails = 0`).

## 6. The task does NOT exist

```
bp task get cch-deployment-detail-column-overflow -o json
# {"error":{"code":"not_found",…,"message":"not found: task not found"},"ok":false}
```

The slug is referenced only in source prose (`registry.ex:6081`,
`registry_test.exs:1029,1041`). Nothing in
`.claude/workflows/bp-cloud-console-hardening-charter.md` rules on it — D151's
"tablet detail-route overflow" is the CSS band, a different defect.
