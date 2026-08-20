# Re-derivation recipe — AutoDeployWorker builds SITES, and the GitHub-push copy inverted (wave 56, v4)

Pin: `origin/main` = b97663730a7a98c39f05a607110bdad5981c81e4 (2026-08-08).

## 1. AutoDeployWorker never touches a Barkpark instance, and is not on the GitHub path

    git grep -n "AutoDeployWorker.enqueue" origin/main -- cloud/lib
    #   cloud/lib/barkpark_cloud/sites/deploy.ex:1457     (deferral re-fire)
    #   cloud/lib/barkpark_cloud/web/router.ex:7717       (content-publish webhook)
    git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | sed -n 179,192p
    #   Registry.get_site/1 + Registry.get_barkpark/1 -> Sites.Deploy   (SITE build)
    git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | grep -c github   # => 0

## 2. The predicate flipped: repo-backed pushes DO build

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n 13268p
    #   defp github_build_available?(site), do: is_binary(site.github_repo)
    git log --oneline -1 -L 13268,13268:cloud/lib/barkpark_cloud/web/router.ex origin/main
    #   404e3a6ba feat(cloud): git-ref clone lane — repo-present predicate flip (#8400)

Repo and webhook secret are set and cleared TOGETHER
(`set_site_github/4` requires `is_binary(repo)`; `clear_site_github/1` nils both),
so any delivery that clears the route's secret gate has a repo => the born-failed
branch is unreachable on the live push path.

    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n 5464,5480p
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n 5526,5537p

## 3. The two console sentences

    git grep -n "Automatic GitHub builds are coming\|will build and deploy automatically" origin/main -- cloud/
    #   failure_copy.ex:540, app.js:12000, __app.test.mjs:3732, __preview__/scenarios.mjs:1511  -> STALE
    #   app.js:13163                                                                            -> TRUE

## 4. Stale in-tree claims riding on the pre-flip world

    git grep -n "hardcoded \`false\`\|record_unbuildable_push" origin/main -- cloud/lib
    #   deploy_ledger.ex:64-65 — names a function that does not exist and a predicate
    #   value that is no longer the code (the real writer is Registry.create_failed_deployment/3)

## 5. The MUST-RUN proof (and why it must not be run in the main checkout)

    git worktree add <scratch>/w56v4 origin/main --detach
    cd <scratch>/w56v4/cloud && CC=clang MIX_ENV=test mix deps.get && CC=clang mix compile
    CC=clang mix test test/barkpark_cloud/sites 2>&1 | tail -40
    #   73 tests, 0 failures

Same command in the primary checkout (705 commits behind origin/main) gives
`45 tests, 10 failures`, all one cause: `Ecto.ConstraintError ...
deployments_active_site_env_index`. That index exists only in the shared test DB
(migrated to origin/main) — the constraint name appears NOWHERE in the stale
worktree. Phantom red. Always run cloud tests from an origin/main worktree.
