# dr-w2 — probe-token count + revoke hazard: re-derivation recipes (2026-08-06)

Verifier assignment `probe-token-count-and-revoke-hazard`, deploy-truth wave 2.
Code read at `origin/main`. Live host = `guerrilla.barkpark.cloud` / `157.180.90.121`.

## 0. psql access (the assignment's MUST-RUN body was wrong)

`psql -U barkpark` fails with `FATAL: Peer authentication failed for user "barkpark"`.
Use the postgres peer instead:

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  "sudo -u postgres psql -d barkpark_prod -c \"<SQL>\""
```

## 1. The count is SEVEN, all live, all id-addressable

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select id, label, permissions, dataset, workspace_id, revoked_at, inserted_at from api_tokens where label like 'probe-%' order by inserted_at;\""
```

7 rows. 5 `{public-read}`, 2 `{read}`. All `revoked_at` NULL, all one workspace
`03e3d6d9-d123-4557-9c06-ae4382a20626`. Strategize's "three" and charter D20's "five"
are both undercounts. The filed task `dr-bl-token-revoke-route-missing` names all seven
labels but omits ids for `probe-publicread-2026-08-05` and `probe-publicread-b-2026-08-05`;
the DB supplies them (`274f53a8-124b-4588-87b1-64fe8c785ec4`, `6c3792d2-96c2-40b9-9eae-94b46594b61c`),
so "two cannot be revoked by id" is REFUTED.

## 2. The EIGHTH token nobody counted

`task-1a9b89e4be002159` discloses `lead-verify-403fix`, whose raw secret was printed into a
session transcript. It is outside the `probe-%` filter and carries MORE privilege than any probe:

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select id,label,permissions,revoked_at from api_tokens where id='ac8ff595-deff-4c51-b251-0d05e8414184';\""
# ac8ff595-… | lead-verify-403fix | {public-read,read} | (null)
```

## 3. Liveness proved at verify_token/1's own predicate (raw secrets are unrecoverable)

`TokenController.create/2` mints `:crypto.strong_rand_bytes(32) |> Base.url_encode64` — NO
prefix — returned once, never persisted. No ledger file records one:

```sh
grep -rEo "[A-Za-z0-9_-]{43}" tooling/grip/ledger/readmit-probe-observed-403-matrix-2026-08-05.md \
  tooling/grip/ledger/graph-visibility-ceiling-2026-08-05.md | wc -l   # -> 0
```

So an authenticated read *as a probe token* is impossible from recorded state. Liveness is
instead proved by evaluating `verify_token/1`'s exact WHERE (auth.ex:44-49) in the DB:

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select label, kind, expires_at, revoked_at, (kind='api' and revoked_at is null and (expires_at is null or expires_at > now())) as passes_verify_token_where from api_tokens where label like 'probe-%' order by inserted_at;\""
# 7/7 -> t
```

CONSEQUENCE FOR SLICE SIZING: criterion 3 of `dr-bl-token-revoke-route-missing` ("revocation is
verified by a request that now fails") is UNSATISFIABLE for all 8 tokens — nobody holds the raw
bearer. The verifiable form is a DB read-back of `revoked_at`, plus a *fresh* mint→revoke→401 test.

## 4. A REVOKE ROUTE ALREADY EXISTS AND IS LIVE

`DELETE /v1/shares/tokens/:token_id` (router.ex:2027, `pipe_through([:api, :require_admin])`)
calls `Auth.revoke_token/1`, whose binary-id arm does an UNSCOPED `Repo.get(ApiToken, uuid)` with
NO `kind` and NO `share_scope` predicate (auth.ex:~226). It will therefore revoke a
`kind="api"` public-read token by id today, over HTTP, no DB and no migration:

```sh
ADMIN=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))["token"])')
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE https://guerrilla.barkpark.cloud/v1/shares/tokens/00000000-0000-0000-0000-000000000000            # 401
curl -s -X DELETE -H "authorization: Bearer $ADMIN" https://guerrilla.barkpark.cloud/v1/shares/tokens/00000000-0000-0000-0000-000000000000            # 404 "token not found" == Repo.get ran
curl -s -H "authorization: Bearer $ADMIN" https://guerrilla.barkpark.cloud/v1/shares/tokens                                                            # 200 {"tokens":[]}
```

The 200-with-empty-list against 56 live tokens is the asymmetry: `list_share_tokens/1`
(auth.ex:678-686) filters `share_scope IS NOT NULL`; `revoke_token/1` filters nothing. LIST is
family-scoped, REVOKE is not. Charter D20's "there is no revoke route, so revocation is a DB
action" is FALSE as stated — the route is misfiled, not missing.

## 5. The mint route's live shape (scoped only)

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'content-type: application/json' -d '{}' https://guerrilla.barkpark.cloud/v1/tokens                       # 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'content-type: application/json' -d '{}' https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens   # 403
curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens                                                        # 404 (no GET/list)
```

`token.create`'s manifest entry (capabilities.ex:1495-1515) carries
`scoped_prefix: "/w/:workspace_slug/p/:project_slug"`, resolved client-side
(`internal/manifest/manifest.go:82,104`; `internal/cli/run.go:97`), so the manifest shape is
correct here — connectors D200's "bake the slugs into path_template" is the fallback, not a
required change, unless a new verb ships without a `scoped_prefix`.

## 6. Cross-tenant enumeration hazard is CONCRETE, not theoretical

`Auth.list_tokens/1` (auth.ex:454-458) filters on `dataset` ONLY. Two workspaces on this box both
use dataset `production`:

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select workspace_id, dataset, count(*) from api_tokens group by 1,2 order by 1,2;\""
# 03e3d6d9-… | production | 148
# e0d57bfb-… | production |   2
```

Wiring `list_tokens/1` behind `:scoped_admin` verbatim returns all 150 rows to either
workspace's admin. Current HTTP callers: NONE (only `seeds/clean.ex:126` and a warmpool
remote-eval string, `internal/cli/cloud/warmpool.go:558`).

## 7. No migration needed; the tests are green

`verify_token/1` already filters `is_nil(t.revoked_at)` in its WHERE (auth.ex:47).

```sh
cd api && CC=clang mix test test/barkpark/auth_test.exs   # 23 tests, 0 failures
```

## 8. Prior art to COPY, not invent

`ShareController` ships the whole lifecycle for the share family — `mint_token` / `list_tokens`
(family-filtered) / `revoke_token` — at `api/lib/barkpark_web/controllers/share_controller.ex:126-159`,
including the pds-w39 RECEIPT LAW shape (`revoked: not is_nil(revoked.revoked_at)` descends from the
returned row). The api-token slice is that controller with a `kind == "api"` + workspace predicate added.
