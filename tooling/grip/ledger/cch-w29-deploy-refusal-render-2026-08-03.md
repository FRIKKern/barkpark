# cch-w29 verifier: the auto-deploy refusal row's two dropped explanation channels

Re-derivation recipes. All measured at `origin/main` = `92f91f043` in a detached
worktree (`git worktree add --detach <dir> origin/main`); the primary checkout is
`[ahead 48, behind 402]` and its `app.js` / `failure_copy.ex` / `deploy.ex` /
`auto_deploy_worker.ex` all differ — running there measures stale bytes.

## R1 — the refusal row's producer (one site, no fixture, no event)

    git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | grep -n '@refusal_detail'
    # -> :162, status cancelled + failure_reason = detail = @refusal_detail, trigger content-auto
    git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | grep -nE 'Events|Alerts|emit|Notif|dispatch|broadcast'
    # -> rc 1, no matches: the refusal emits NO event anywhere

## R2 — humanize passes the refusal through VERBATIM (no quota arm)

    cd <worktree>/cloud && mix deps.get && CC=clang mix compile
    CC=clang mix run --no-start -e 'BarkparkCloud.FailureCopy.humanize(<@refusal_detail bytes>) |> IO.puts()'
    # typed_refusal? => false ; humanize/1 == input (true) ; stage_caption("cancelled", s) == s (true)

## R3 — both console channels drop it (driven through the __bpTestHook)

    # vm-sandbox app.js exactly as __app.test.mjs does, grab hooks.deployRow /
    # hooks.deployDetailHtml, pass the refusal row.
    # -> deployRow html = bare "Cancelled" pill, no deploy-fail, no deploy-detail
    # -> deployDetailHtml(row,"cancelled") = ""
    # -> CONTROL: same row with status "failed" renders the full refusal.

## R4 — the twin at app.js:10333 (previewRow) is UNREACHABLE from the node harness

    # delete previewRow's fail gate only:
    perl -0pi -e 's/(.*?)\Qvar fail = st === "failed" ? deployFailHtml(d.failure_reason) : "";\E/$1var fail = "";/s' cloud/priv/static/app.js
    node --test cloud/priv/static/__app.test.mjs   # -> 797/797 PASS (green by construction)
    # delete deployRow's gate at :11203 instead (greedy .*):
    perl -0pi -e 's/(.*)\Qvar fail = ...\E/$1var fail = "";/s' cloud/priv/static/app.js
    node --test cloud/priv/static/__app.test.mjs   # -> 796 pass / 1 fail (reachable)

Cause: `previewRow` is NOT in the `__bpTestHook` export block, and
`__app.test.mjs:11707` reads `hooks.previewRow ? hooks.previewRow(d) : null`
then wraps all four assertions in `if (html !== null)`.

## R5 — the existing cancelled control PINS the defect

    git show origin/main:cloud/priv/static/__app.test.mjs | sed -n '11286,11291p'
    # assert.doesNotMatch(html, /deploy-fail/);  // fixture has no failure_reason at all
