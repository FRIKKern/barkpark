# Re-derivation recipes — wave 15 verifier V9 (unreachable-reader-proof)

Epic: deploy-reliability. Baseline: `origin/main` = `8e770a08efdb36173b013ebc4f59faa1b238b6fa`
(2026-08-07 15:58:59 +0200). All Elixir runs were done in a **detached scratchpad worktree** at that
SHA (`git worktree add --detach <scratch> origin/main`), with `cloud/deps` and `cloud/_build` copied
in from the main checkout (`cloud/mix.lock` is byte-identical between the two, so the copy is sound).
The main checkout was never switched and never edited.

## R1 — zero production callers (grep form)

    git grep -n 'DeployLedger.delivery\|DeployLedger.refusal_phase' origin/main -- cloud/lib   # rc=1, no output
    git grep -no 'DeployLedger\.[a-z_]*' origin/main -- cloud/lib | sed 's/.*://' | sort | uniq -c | sort -rn

The second command is the stronger form: it enumerates every `DeployLedger.*` call site in production
code. On this SHA the entire list is `classify` (5), `census` (3), `list_page` (2), `parse_window` (1),
`min_sample` (1). `delivery` and `refusal_phase` do not appear.

## R2 — the tests are green anyway

    cd <worktree>/cloud && CC=clang mix test test/barkpark_cloud/deploy_ledger_test.exs
    # => 60 tests, 0 failures

## R3 — mutation proof (the decisive one; grep can be argued with, this cannot)

Rename the public entry point and compile **production code only**. If the app still compiles, nothing
in production called it.

    cp lib/barkpark_cloud/deploy_ledger.ex /tmp/dl.bak
    perl -pi -e 's/refusal_phase\(/refusal_phase_MUTATED(/g' lib/barkpark_cloud/deploy_ledger.ex
    MIX_ENV=dev CC=clang mix compile --force        # => "Compiling 129 files (.ex) / Generated barkpark_cloud app"
    CC=clang mix test test/barkpark_cloud/deploy_ledger_test.exs   # => 60 tests, 1 failure
    cp /tmp/dl.bak lib/barkpark_cloud/deploy_ledger.ex

Same recipe for `delivery/3` (note the `@spec` line must be renamed with a distinct pattern or the
naive global substitution double-applies and yields `@spec@spec`):

    perl -pi -e 's/\bdef delivery\(%DateTime\{\} = from/def delivery_MUTATED(%DateTime{} = from/g; s/\@spec delivery\(/\@spec delivery_MUTATED(/g' lib/barkpark_cloud/deploy_ledger.ex
    MIX_ENV=dev CC=clang mix compile --force        # => Generated barkpark_cloud app

Restore with `cp /tmp/dl.bak …` and confirm `git status --porcelain -- cloud/lib` is empty.

## R4 — prod structural facts (cloud-db-1)

`docker exec -i` runs psql **inside** the container, so `-f /tmp/x.sql` cannot see a host file that was
`scp`'d to the host. Pipe on stdin instead:

    scp -i ~/.ssh/barkpark_indx /tmp/v9.sql root@178.105.92.191:/tmp/v9.sql
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod < /tmp/v9.sql'

Queries used:

    \d deployments
    SELECT date_trunc('hour',inserted_at) h,
           count(*) att,
           count(*) FILTER (WHERE status='failed') failed,
           count(*) FILTER (WHERE status IN ('live','failed')) settled
    FROM deployments
    WHERE inserted_at >= '2026-08-06 08:00' AND inserted_at < '2026-08-06 20:00'
    GROUP BY 1 ORDER BY 1;

    SELECT count(*) FILTER (WHERE failure_reason ~ '^the instance refused the build poll') poll_rows,
           count(*) FILTER (WHERE failure_reason ~ '^the instance refused the deploy')     start_rows
    FROM deployments;

    EXPLAIN (ANALYZE, BUFFERS) SELECT date_trunc('hour',inserted_at), count(*) FROM deployments
    WHERE inserted_at >= '2026-08-06 08:00' AND inserted_at < '2026-08-06 20:00' GROUP BY 1;

Note the timestamps are `timestamp without time zone` stored in UTC — do **not** append `Z` inside a
`psql` literal in a heredoc unless you want the server to parse it as a timetz-ish input; bare
`'2026-08-06 08:00'` is what these numbers were taken with.

## R5 — the follow-up tasks already exist

    bp search query "emit-delivery-on-route"
    bp task get dr-w11-s4-followup-emit-delivery-on-route
    bp task get dr-w14-s3-followup-phase-in-deployment-json

Both are open and unclaimed. `bp search` without the `query` sub-verb exits 2 and an empty result is
indistinguishable from genuine absence.
