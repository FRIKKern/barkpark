# PDS w37 — re-derive the PROVEN opening balance (2026-08-01, sha 501fb9670)

Every number below is derived by running these, never transcribed. Run from a
clean worktree at `origin/main`; `api/_build` may be copied from the main
checkout but `mix deps.get` MUST be re-run (mix.lock moved in #8949-#8952).

## 0. worktree + env

    git -C <repo> worktree add --detach /tmp/vfy37 origin/main
    cp -R <repo>/api/deps /tmp/vfy37/api/deps
    mkdir -p /tmp/vfy37/api/_build && cp -R <repo>/api/_build/test /tmp/vfy37/api/_build/test
    cd /tmp/vfy37/api && CC=/usr/bin/clang MIX_ENV=test mix deps.get && CC=/usr/bin/clang MIX_ENV=test mix compile

## 1. the lens (91 rows, four fields, no LINE)

    cd /tmp/vfy37 && elixir scripts/pds-elixir-receipt-census.exs --keys > /tmp/k.tsv
    wc -l /tmp/k.tsv                      # 91
    cut -f2 /tmp/k.tsv | sed 's/\.[a-z_!?]*\/[0-9]*$//' | sort -u | wc -l   # 23 modules

## 2. the candidate set (route driver co-located with a storage read)

    cd /tmp/vfy37/api/test
    for f in $(grep -rlE '(\|> *(post|put|patch|delete|get)\()|((post|put|patch|delete)\(conn)' --include='*.exs' .); do
      grep -qE 'Repo\.(get|get_by|all|one|aggregate|exists\?|reload|preload)' "$f" && echo "$f"; done | sort
    # 41 files. NOTE: five of the files the brief named as starters
    # (grant_controller_test, app_token_controller_test, scoped_secret_controller_test,
    #  scim_users_controller_test, webhook_deliveries_test) drive controllers with
    # ZERO `ok: true` — verify with:
    grep -c 'ok: true' /tmp/vfy37/api/lib/barkpark_web/controllers/{grant,app_token,scim_users,webhook}_controller.ex

## 3. the per-test conjunction screen (drive + storage read + `ok` asserted, SAME test)

    python3 tooling/grip/ledger/scripts/w37-conj.py   # not committed; recipe below

Split each `*_test.exs` on lines matching `^\s*test\s+["~]`; a block counts only if
it matches ALL THREE of:
  drive `(\|>\s*(post|put|patch|delete)\()|((post|put|patch|delete)\(conn)`
  read  `Repo\.(get|get_by|all|one|aggregate|exists\?|reload)|Content\.get_document|Content\.get_paper`
  claim `"ok"\s*(=>|==)\s*true|\["ok"\]\s*==\s*true`
Helpers defined AFTER the last `test` block leak into it — hand-check every hit
(this produced one false positive: tasks_controller_test.exs:1688).

## 4. run the proofs

    cd /tmp/vfy37/api
    CC=/usr/bin/clang mix test test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs   # 11 tests, 0 failures
    CC=/usr/bin/clang mix test test/barkpark_web/controllers/github_webhook_integration_test.exs      # 4 tests, 0 failures
    CC=/usr/bin/clang mix test test/barkpark_web/controllers/pds_w36_revoke_all_receipt_test.exs      # 5 tests, 0 failures
    CC=/usr/bin/clang mix test test/barkpark/content/task_birth_fence_test.exs \
        test/barkpark_web/integration/v1_data_search_suggestions_test.exs \
        test/barkpark_web/controllers/saml_controller_test.exs                                        # 27 tests, 0 failures
    CC=/usr/bin/clang mix test test/barkpark_web/controllers/tasks_controller_test.exs:741 \
        test/barkpark_web/controllers/tasks_controller_test.exs:3147 \
        test/barkpark_web/controllers/tasks_controller_test.exs:2435 \
        test/barkpark_web/controllers/tasks_controller_test.exs:1724                                  # 4 tests, 0 failures
    CC=/usr/bin/clang mix test test/barkpark_web/controllers/bulldocs_ingest_controller_test.exs \
        test/barkpark_web/controllers/auth_controller_test.exs                                        # 72 tests, 0 failures
    CC=/usr/bin/clang mix format --check-formatted; echo $?                                           # 0

## 5. join a named site to its key row

`--keys` carries NO line number. Join on `{path, Module.fun/arity}` and, when a
function holds several `ok: true` arms, disambiguate by expr_fp. Beware:
expr_fp 84462998 is shared by FIVE TasksController rows (stage/relabel/papers/
sessions/move all emit the identical `json(conn, %{ok: true, doc: ...})`), and
expr_fp 17468236 (bare `%{ok: true}`) is shared across seven controllers.

    grep -n 'ok: true' api/lib/barkpark_web/controllers/<f>.ex   # lines, in source order
    grep '<f>' /tmp/k.tsv                                         # key rows, same order per function
