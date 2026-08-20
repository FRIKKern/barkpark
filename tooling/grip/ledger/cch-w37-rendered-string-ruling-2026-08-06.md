# cch-w37 — the rendered-string ruling for slice 1 (friendly() precedence)

Verifier lane `[rendered-string-ruling]`, wave 37. Tree: `origin/main` = `bf97452bb38488d04cfbb596c2528a3f34ad5baf`.
Every row below re-derives from scratch. Nothing here is quoted from a worktree.

## 0. Extract main (the ONLY correct extraction — `cloud`-only breaks 4 tests on cross-tree fixtures)

    T=$(mktemp -d); git archive origin/main | tar -x -C $T; echo $T

## 1. Main's console gate is GREEN (Decide question #1)

    cd $T && node --test cloud/priv/static/__app.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)'
    # -> # tests 914 / # pass 914 / # fail 0

The alarm ("4 fails", "68/75 fails") is an EXTRACTION ARTIFACT, not a red on main:

    git archive origin/main cloud | tar -x -C $T2   # cloud-only
    cd $T2 && node --test cloud/priv/static/__app.test.mjs 2>&1 | grep -c '^not ok'   # -> 4
    # every one: ENOENT on internal/taskboard/testdata/… (outside cloud/)
    cd $T && node --test cloud/priv/static/__preview__/seal-predicate.test.mjs 2>&1 | grep -E '^# (pass|fail)'
    # -> pass 61 / fail 14; failure #62 is ENOENT on `.git` — the tool reads git history.
    # CI runs it with a PATH shim inside a real checkout (.github/workflows/console-harness.yml:305-313).
    gh api "repos/{owner}/{repo}/commits/bf97452bb38488d04cfbb596c2528a3f34ad5baf/check-runs?per_page=100" \
      --jq '.check_runs[]|"\(.conclusion)\t\(.name)"' | sort | grep -i console
    # -> success Console client unit harness / success Console gate / success Console path-escape ratchet

## 2. The rendered-string harness (the ruling itself)

Loads the SHIPPED app.js in a node:vm sandbox (same technique as `__app.test.mjs:29-82`),
grabs `hooks.friendly` / `hooks.faultCopy`, and prints CURRENT vs PROPOSED for real payloads.

    node /path/to/render_ruling.mjs  $T/cloud/priv/static/app.js   # 32 reachable emitter payloads
    node /path/to/render_ruling2.mjs $T/cloud/priv/static/app.js   # curated/default/leak reservoirs

Scripts are in the wave scratchpad; they are ~90 lines each and reproduce from the sandbox
literal at `__app.test.mjs:29-82` plus this PROPOSED body:

    const GENERIC = new Set(["invalid", "validation_failed"]);
    if (data && GENERIC.has(data.error) && data.details && typeof data.details === "object") { …details wins… }

### Decisive outputs

    TOTAL CASES: 32
    DISTINCT CURRENT STRINGS: 1        <-- every emitter renders "That didn't work — check your input."
    curated total 36: composes 18, GRAMMAR-BREAKS 18
    the REAL shape {error:'invalid'}: CURRENT="That didn't work — check your input." PROPOSED="name is required" identical:false
    shipped test payload {error:'x'}:  CURRENT="name is required" PROPOSED="name is required" identical:TRUE

## 3. Census commands

    R=$T/cloud/lib/barkpark_cloud/web/router.ex
    grep -c 'error: "invalid", details:' $R                 # 47
    grep -n 'validation_failed.*details:' $R                # 8567 (one)
    grep -n 'already_invited' $R                            # 4793 (HTTP 409 — EXCLUDED)
    grep -rhoE 'message: "[^"]+"' $T/cloud/lib | sort | uniq -c | sort -rn   # 22 distinct curated messages
    grep -rc validate_inclusion $T/cloud/lib | grep -v ':0' | awk -F: '{s+=$2} END {print s}'  # 52
    grep -rA2 validate_inclusion $T/cloud/lib | grep -c 'message:'                              # 4

### Route attribution, including the corner nobody reached (emitters >= 8249)

    awk '/^  (post|put|patch|delete|get) "/ {r=$0; sub(/^  /,"",r)} /error: "invalid", details:/ {print NR"\t"r}' $R
    # correct only below 7879; after that the emitters live in defp helpers:
    awk '/^  defp? [a-z_]+/ {f=$0; sub(/^  /,"",f); sub(/ do$/,"",f)} /error: "invalid", details:/ && NR>8000 {print NR"\t"f}' $R
    # -> 8249 go_live, 8447 do_resurrect, 8882/8896/8909/8920 handle_onboarding_action,
    #    9198/9202/9205 connect_provider_request, 11088 deploy_static_site, 11194 promote_deployment,
    #    11830 deprovision_live_barkpark, 12128 connect_site_github, 12333/12396 handle_*_push,
    #    12624 start_prebuilt_deploy

## 4. POST /v1/sites is OUTSIDE the fence (raw token render)

    sed -n '8395,8414p' $T/cloud/priv/static/app.js
    # :8410  var msg = (r.data && (r.data.error || r.data.message)) || ("create failed (" + r.status + ")");
    # no friendly() — the person reads the bare token "invalid".

## 5. Escaping is NOT a concern

    grep -n 'function setText' $T/cloud/priv/static/app.js     # :35 el.textContent = t
    grep -n 'innerHTML.*friendly(' $T/cloud/priv/static/app.js # :12262, wrapped in esc()
