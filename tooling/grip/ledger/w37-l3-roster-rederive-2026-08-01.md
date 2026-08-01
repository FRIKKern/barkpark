# PDS w37 — L3 roster re-derivation recipes (sha 501fb9670)

Every L3 roster anchor and every Class D accusation, as a command that re-derives it.
Verdicts use the PDS-D499 basis vocabulary. Run from repo root.

## 1. Roster anchors — grep the LITERAL, never the line number

```sh
git grep -n -F 'send_resp(conn, 204, "")' origin/main -- api/lib
#   pulse_controller.ex:93          CORS preflight — protocol-bound, not a receipt
#   scim_groups_controller.ex:139   ROSTER ROW, verdict REFUTED
#   scim_users_controller.ex:105    ROSTER ROW, verdict PROVEN (raising-write)

git grep -n -F 'send_resp(conn, :no_content' origin/main -- api/lib
#   chat_controller.ex:334          ROSTER ROW, verdict UNJUDGED

git grep -n -F 'put_status(:accepted)' origin/main -- api/lib/barkpark_web/controllers/chat_controller.ex
#   :261 (persist fail-soft, declared) · :291 (request_id may be nil, declared)

git grep -n -F 'Signed out.' origin/main -- api/lib
#   session_controller.ex:418  — the flash. The LOSSY CALL is :410.
git show origin/main:api/lib/barkpark_web/controllers/session_controller.ex \
  | grep -n -E 'revoke_user_session_token|configure_session\(drop|put_flash\(:info, "Signed out|redirect\(to: "/studio"\)'
#   410 / 417 / 418 / 419  — PDS-D504's ":410" is the CALL and is correct.
```

## 2. Roster ∩ lens must be EMPTY (L3 is disjoint from L1)

```sh
elixir scripts/pds-elixir-receipt-census.exs --keys > /tmp/keys.txt
wc -l /tmp/keys.txt                                              # 91
grep -c -E 'scim_groups|scim_users|session_controller|chat_controller' /tmp/keys.txt   # 0
```

## 3. Class D — is `{:ok, _} <-` already a row-level proof?

Read the CALLEE, not the controller. The question is whether `{:ok, _}` is
reachable when nothing was written.

```sh
git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '649,706p'  # delete_document
git show origin/main:api/lib/barkpark/content/schema.ex    | sed -n '181,206p'  # delete_schema
git show origin/main:api/lib/barkpark/webhooks.ex          | sed -n '135,143p'  # delete_webhook
git show origin/main:api/lib/barkpark/media.ex             | sed -n '413,458p'  # delete_file
git show origin/main:api/lib/barkpark/auth.ex              | sed -n '200,241p'  # revoke_token
git show origin/main:api/lib/barkpark/sharing/links.ex     | sed -n '91,109p'   # Links.revoke
```

All six bottom out in `Repo.delete/2` (`stale_error_field: :id`) or `Repo.update/1`
on ONE fetched row — `{:ok, _}` is unreachable on a zero-row write. The ten
`%{deleted: id}` / `%{revoked: true}` echo sites are therefore **FALSE
ACCUSATIONS** and must not enter the L3 roster.

## 4. The two counter-examples — `Repo.delete_all` / hardcoded `:ok`

```sh
git show origin/main:api/lib/barkpark/scim.ex     | sed -n '467,476p'   # {:ok, n} even when n == 0
git show origin/main:api/lib/barkpark/accounts.ex | sed -n '326,334p'   # update_all, then `:ok`
```

Consequence for `pds-bl-status-only-residue-payment`: its criterion
"scim_groups_controller.ex:139 … matched at least as strictly as
scim_users_controller.ex:102" is **satisfiable by a no-op** — `{:ok, _} =`
always matches `{:ok, 0}`. The falsifiable form is `{:ok, n} when n > 0` (or a
404 on `n == 0`), plus a test that reds when a cross-org id is deleted.
