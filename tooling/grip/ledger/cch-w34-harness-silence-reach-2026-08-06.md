# cch-w34 — harness-silence-reach: re-derivation recipes

Verifier: harness-silence-reach (Cloud Console hardening, wave 34).
Every recipe below runs against **origin/main**, not the working tree.

## 0. WHY THE TREE MATTERS (this bit me first)

The local checkout was **1967 lines behind** origin/main on `cloud/priv/static/app.js`.
Probes run in the worktree silently answered from code without `deployConsoleCutHtml`
at all, producing a wrong (and comforting) "s3 discloses nothing on either arm".

    git rev-parse HEAD origin/main
    git diff --stat origin/main -- cloud/priv/static/app.js

Materialize origin/main before probing anything:

    S=<scratch>
    mkdir -p $S/om && git archive origin/main cloud internal deploy | tar -x -C $S/om

`deploy/` and `internal/` are REQUIRED: 15 of `__app.test.mjs`'s censuses read
`cloud/lib/**`, and cch-w25-s3 reads `deploy/lib/site-deploy-common.sh`. A partial
archive reds them for reasons that have nothing to do with the code.

## 1. Both harnesses, green on origin/main

    cd $S/om/cloud/priv/static/__preview__ && node smoke.mjs | tail -3   # all 102 scenarios rendered
    cd $S/om/cloud/priv/static           && node __app.test.mjs | tail -5 # pass 847 / fail 0 (whole tree)

NOTE: `node smoke.mjs | tail -15; echo $?` reports **tail's** status, not the
runner's (recurrence of the pipe-eats-rc trap). Use:

    node smoke.mjs >/dev/null 2>&1; echo REAL_EXIT=$?

## 2. Patch that makes SSE silence reachable from smoke.mjs (6 lines)

In a copy of `smoke.mjs`:
  * `EventSourceStub` → retain the returned object in a module-local `esInstances[]`
  * `bootScenario` return → add `esInstances`
  * (for read-failure work) in `fetchStub`, honour `globalThis.__FAILPATHS` by
    overriding the routed result with `{status:500}`
  * export `{ bootScenario, flush }` and disable `main()`

Then: `esInstances[0].onerror()` runs the SHIPPED handler
(app.js:14246) end-to-end; `#liveness-chip` moves `live` → `reconnecting`.

## 3. Silence WITHOUT any harness patch

`hooks.renderLivenessChip({evtDead:true, evtErrored:false, lastEventMs, nowMs})`
paints `data-state="dead"`. The override seam is already exported (app.js:14082)
and already used by `__app.test.mjs:5069-5096`. smoke.mjs uses it **zero** times.

## 4. The instance-sites collapse (loadInstanceSites, app.js:7803)

    globalThis.__FAILPATHS = ["/v1/sites"];   // before bootScenario
    bootScenario("shell-instance"); await flush();
    registry.get("instance-sites").innerHTML

200 and 500 produce the BYTE-IDENTICAL "No sites yet" empty state.
Control: `bootScenario("sites")` → `#sites-body` renders
"Couldn't load sites" on 500 and rows on 200 (loadSites, app.js:10176 has the
`!r.ok` arm its twin lacks). No `__bpTestHook` export is needed for either — both
are reached through the real render path.

## 5. The narration-latch gate is a `status` KEY, not a wording

    hooks.deployConsoleHtml({id:"d",status:"failed",console:[
      {line:"BUILD running", at:"...", status:"running", stage:"build"}]}, false)
      → count reads "1 line · narration ended mid-build"

    same call with console:[{line:"BUILD running", at:"..."}]   (no status key)
      → count reads "1 line"                                    (no disclosure)

Producers, both on origin/main:
  * OFF-BOX  `registry.ex:6044` `append_deployment_console/2` → `%{"line","at"}`
    (+ optional `truncated_from`). No `status`, no `stage`.
  * ON-BOX   `sites/deploy.ex:970` `console_entry/1` → `line/at/stage/status/detail`.

A terminal deployment with an EMPTY console renders `""` — no console element at
all (`deployConsoleHtml`'s `if (!lines.length && !active) return ""`).

## 6. The browser harness (mock.js) — what is and is not reachable

    git show origin/main:cloud/priv/static/__preview__/mock.js | sed -n '240,288p'

  * `streams[]` is closure-private; `window.__preview` exposes only
    `{scenario, accent, push}` and `push` fires **onmessage only**. `onerror` is
    unreachable — but exposing it is a ~3-line addition, not a redesign.
  * `appHooks` (mock.js:154) captures `__bpTestHook` but is never put on `window`;
    only `openAccountModal` is driven from it. So `renderLivenessChip`'s override
    is unreachable in-browser too, for the same 1-line reason.
  * `window.fetch` (mock.js:125) always RESOLVES — no hang, no reject, no abort.
    So is smoke's `fetchStub`. Neither harness can express a never-settling read.
  * HTTP-status failure IS already expressible in BOTH, because it lives in the
    SHARED `scenarios.mjs` (403/500/502 arms at :2626, :3182, :4295, :4499, :4570;
    scenario `operator-unreadable` 403s every route).
