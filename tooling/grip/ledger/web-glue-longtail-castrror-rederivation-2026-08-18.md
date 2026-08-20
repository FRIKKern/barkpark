# Long-tail binary_id CastError corner — re-derivation recipe (2026-08-18)

Wave: web-glue-robustness-wave-2026-08-18 · assignment `longtail-context-castrror`
Pinned tree: `origin/main` = `6015bedabd301db9893bd300c90600ce307ae567`
(NOTE: the digest pinned `228090798`; origin/main moved before this phase. Re-pin before quoting.)

VERDICT: **SWEPT ZERO** across all five assigned controllers. No unguarded
binary_id lookup is reachable from secret / instance_site_deploy / self_update /
share_link / tickets_attachments.

## The assigned grep is uninformative — do not quote its empty output

    cd api && git grep -nE 'Repo\.get(_by)?[!(]' origin/main \
      -- 'lib/barkpark/secret*' 'lib/barkpark/instance*' \
         'lib/barkpark/self_update*' 'lib/barkpark/plugins/tickets/*'

Returns ZERO lines, but three of the four pathspecs match no file on the tree:
the modules are `lib/barkpark/secrets.ex`, `lib/barkpark/sharing/links.ex`,
`lib/barkpark/self_update.ex`; there is no `lib/barkpark/instance*` at all.
An empty result here is a typo, not a clean bill.

## Use these two instead

Roster first (prove the pathspecs match something):

    git ls-tree -r --name-only origin/main -- api/lib/barkpark \
      | grep -Ei 'secret|instance|self_update|tickets|share'

Then the WIDENED cast surface — `Repo.get` alone is structurally blind, because
`where([x], x.id == ^param)` on a `:binary_id` column raises
`Ecto.Query.CastError` (500) identically:

    cd api && git grep -nE '\.id == \^|Repo\.get' origin/main \
      -- 'lib/barkpark/secrets*' 'lib/barkpark/sharing/*' \
         'lib/barkpark/plugins/tickets*' 'lib/barkpark/self_update*' \
         'lib/barkpark/instance*' 'lib/barkpark/release/secrets.ex'

Exactly two live cast sites, both guarded:
  * `lib/barkpark/sharing/links.ex:94` `Repo.uuid_or_nil/1` → `:99 Repo.get(ShareLink, uuid)`
  * `lib/barkpark/plugins/tickets/keys.ex:220` `Repo.uuid_or_nil/1` → `:228 where t.id == ^uuid`

## Per-controller trace (context function → guard line)

| Controller | id-bearing action | Context fn | Guard |
|---|---|---|---|
| share_link | `revoke DELETE /v1/shares/links/:id` | `Sharing.Links.revoke/1` | `links.ex:94` uuid_or_nil |
| tickets_attachments | `show/show_operator :asset_id` | `Attachments.linked_asset/4` → `Media.get_file/2` | `media.ex:392` uuid_or_nil |
| tickets_attachments | `create/show :id` (ticket) | `Content.get_document/4` | no cast: `query.ex:729` filters `d.doc_id` (STRING col) |
| secret | `show/update/delete/audit :name` | `Secrets.reveal/put/delete`, `scope_audit/2` | `secret_controller.ex:191` uuid_or_nil on the SCOPE; `:name` is a string col (`secrets.ex:272` "NEVER Repo.get/2 by name") |
| instance_site_deploy | `show` | — | takes `_params`; no id read |
| self_update | `trigger/rollback/status` | — | all take `_params`; no id read |

## Executed proofs (re-run verbatim from `api/`)

    MIX_ENV=test mix test test/barkpark/repo_uuid_guard_test.exs          # 4 tests, 0 failures
    MIX_ENV=test mix test test/barkpark/secrets_castgap_contract_test.exs # 5 tests, 0 failures
    MIX_ENV=test mix test test/barkpark_web/controllers/share_link_test.exs # 12 tests, 0 failures
    MIX_ENV=test mix test test/barkpark/media_test.exs:228               # 1 test, 0 failures

`share_link_test.exs:288-289` is the conn-level certification already on main:
`DELETE /v1/shares/links/not-a-uuid` → 404 `not_found` (not a 500).

## Adjacent, NOT this class — do not re-pave

`bp search query "binary_id CastError uuid guard controller"` surfaces task
`arpss-share-link-object-authz-close`: `Links.revoke/1` is a bare *unscoped*
`Repo.get` — a ws-A admin can revoke a ws-B link (200 `revoked:true`). That is a
cross-tenant AUTHZ hole already filed by the read-path security wave; it is not a
CastError finding and is outside this wave's correctness lens.
