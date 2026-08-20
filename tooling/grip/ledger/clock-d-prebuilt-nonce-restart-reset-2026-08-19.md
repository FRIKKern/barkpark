# Class D — prebuilt build_id nonce resets on BEAM restart (cloud/lib/.../sites/deploy.ex:336-337)

Verifier: clock-semantics wave 2026-08-19, slice `prebuilt-nonce-class-d`.
All code read via `git show origin/main:<path>` — never the working tree.

## The claim, and how to re-derive each half

1. `[:positive, :monotonic]` restarts from 1 in a fresh VM, and it is a SEPARATE
   sequence from bare `[:positive]`:

       elixir -e 'IO.inspect({System.unique_integer([:positive]), System.unique_integer([:positive,:monotonic]), System.unique_integer([:positive,:monotonic])})'
       # run twice → {1314, 1, 2} then {1315, 1, 2}

   Wall clock for contrast (never repeats across boots):

       elixir -e 'IO.inspect(System.system_time())'   # 1787127092958896542 / 1787127093238357833

2. deploy.ex:337 is the ONLY `[:positive, :monotonic]` caller in cloud/lib, so
   that sequence is consumed exclusively by prebuilt mints — the Nth prebuilt
   deploy since boot gets nonce N, exactly reproducible after a restart:

       git grep -n 'unique_integer' origin/main -- cloud/lib

3. `code_rev` is the BOX's git_commit (deploy.ex:412-414), not the cloud release,
   so restarting the control plane does not perturb the other build_id inputs:

       git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '405,415p'

4. Consequence chain is D87 verbatim: duplicate build_id → `recover_conflict`
   → `{:duplicate, existing}` → router.ex answers `json(conn, 200, ...)` with the
   OLD row, and `record_audit` lives ONLY in the `{:ok, _}` arm → zero trace:

       git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '12264,12345p'

5. Repo already states the rule in three places; :337 is the one violation:

       git grep -n 'restarts with the BEAM\|restarts at low values' origin/main -- api/lib

## Reachability (refuted widening)

ONE mint path only: `router.ex:12264` → `Sites.Deploy.enqueue(site, bp, force,
"manual", nil, source)` on `POST /v1/sites/:id/deploy {"source":"prebuilt"}`,
authenticated + `site.prebuilt_enabled`. `auto_deploy_worker.ex:225-227` writes
`source: "prebuilt"` via `Registry.create_deployment/2` DIRECTLY (a refusal row,
no build_id at all) and never reaches `maybe_prebuilt_nonce/2`:

    git grep -n 'Deploy.enqueue' origin/main -- cloud/lib

## Baseline

    cd cloud && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
    mix test test/barkpark_cloud/sites_deploy_test.exs
    # 88 tests, 0 failures   (seed 711969, 1.9s)

## Test-pin survey

No test pins a prebuilt build_id VALUE. The literal build_ids in cloud/test
(`"deadbeefdeadbeef"`, `"abc123abc123abc1"`, `"pb1"`, `"b-prev"`) are all inserted
directly via `Registry.create_deployment/2`, never derived from `build_id/5`:

    git grep -n 'build_id' origin/main -- cloud/test | grep -E '"[0-9a-z-]{2,}"'

Two tests assert the PROPERTY (not the bytes) and both keep passing after an
entropy swap — and both are VACUOUS w.r.t. this defect (same-VM, so the counter
never resets): `sites_deploy_test.exs:2289` "a prebuilt mint is non-idempotent"
and `router_sites_test.exs:2665` "TWO prebuilt mints … DIFFERENT build_ids".
`router_sites_test.exs:2678` asserts the deploy-truth-W1 coalesce (`{:duplicate,_}`
→ HTTP 200, same deployment id) is INTENDED behaviour.
