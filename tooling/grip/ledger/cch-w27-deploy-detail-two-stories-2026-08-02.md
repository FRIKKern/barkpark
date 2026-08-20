# Re-derivation recipe — CCH w27: the deploy stage detail tells a different story than the deploy row

Tree: `origin/main` @ `c2affd4458f491694f38773843df43b4f66507e0` (2026-08-02).

**The primary checkout is STALE (`a31faa52d`) and its `failure_copy.ex` has no `scrub/1`.**
Running `mix test test/barkpark_cloud/failure_copy_test.exs` in it is green *and vacuous* for
this question. Drive `origin/main`'s module standalone instead.

## 1. failure_reason vs detail — same source string, two outputs

```sh
D=$(mktemp -d)
git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex > "$D/failure_copy_main.ex"
cat > "$D/drive.exs" <<'EOF'
alias BarkparkCloud.FailureCopy
for detail <- ["connection refused", "dial tcp 10.0.0.4:443: i/o timeout", "probe 500"] do
  IO.puts("rail  >>>#{detail}<<<")
  IO.puts("row   >>>#{FailureCopy.humanize("HEALTH failed — " <> detail)}<<<\n")
end
EOF
(cd "$D" && elixir -r failure_copy_main.ex drive.exs)
```

## 2. The rail paints the RAW string (driven through the shipped app.js)

```sh
git show origin/main:cloud/priv/static/app.js > "$D/app_main.js"
# reuse the node:vm sandbox from cloud/priv/static/__app.test.mjs lines 30-80,
# then:
#   hooks.deployDetailHtml(dep, "failed")               -> ""   (gated by deployIsActive)
#   hooks.deployFailHtml(dep.failure_reason)            -> human copy
#   hooks.deployRailHtml(hooks.deployRailRows(
#     hooks.deployRailLedgerFromConsole(dep.console)),
#     {failureDetail: <failed row>.caption})            -> RAW jargon in .deploy-rail-fail
# Rail stages are ["PLAN","BUILD","STAGE","HEALTH","SWITCH","RETIRE"] — a console
# entry with any other `stage` is silently dropped by deployRailLedgerFromConsole.
```

## 3. The SSE channel bypasses the display-boundary scrub entirely

```sh
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '864,874p'   # broadcast_stage: detail: stage.detail, raw
git show origin/main:cloud/lib/barkpark_cloud/events.ex        | sed -n '94,103p'   # broadcast/3 sends payload verbatim
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex    | sed -n '10209p'    # HTTP console entries ARE scrubbed
```

Same bytes, two channels: `GET` scrubs, SSE does not. `recordDeployStage` is not in
`__bpTestHook`, so no node guard can reach the SSE leg today.
