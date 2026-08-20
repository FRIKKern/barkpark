# V3 re-derivation — auth.ex token-action fence line (share-authz wave)

Re-derive the BUILD-vs-FILE verdict for share_controller actions 7-9
(list_tokens / mint_token / revoke_token) from origin/main.

## The three resolvers in auth.ex (OUT of fence, signatures must not change)

    git show origin/main:api/lib/barkpark/auth.ex | sed -n '227,240p'   # revoke_token/1 (binary): bare Repo.get(ApiToken, uuid) — NO ws filter
    git show origin/main:api/lib/barkpark/auth.ex | sed -n '616,652p'   # create_share_token: authz = validate_edit_share (scope :edit-shared?), NOT caller ws
    git show origin/main:api/lib/barkpark/auth.ex | sed -n '678,692p'   # list_share_tokens(scope): WHERE not is_nil(share_scope) + optional client scope; NO ws filter

## The controller callers (IN fence — share_controller.ex)

    git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | sed -n '100,160p'  # mint_token / list_tokens / revoke_token
    git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | sed -n '183,197p'  # token_json — strips raw + token_hash (list = metadata read, NOT raw-cred leak)

## The token assign + admin gate (IN fence to READ)

    git show origin/main:api/lib/barkpark_web/plugs/require_admin.ex | sed -n '14,18p'   # gates ONLY has_permission?(token,"admin"); zero ws binding
    git show origin/main:api/lib/barkpark_web/plugs/derive_workspace_from_token.ex | sed -n '50,52p'  # api_token assign is %ApiToken{workspace_id: ws_id}

## Shared revoke_token/1 callers that MUST stay unscoped (why the primitive can't change)

    grep -rn 'revoke_token(' api/lib api/lib/barkpark_web | grep -v 'def revoke_token'
    # non-share: studio_chat/runtime.ex:654, runtime/codex/session.ex:612, studio/claude_chat.ex:1601,
    # connectors_live.ex:365/375/399/562, app_token_controller.ex:140/175, fleet_support_token_controller.ex:75

## VERDICT
All three BUILDABLE controller-side, NO auth.ex signature change:
- list  (7): post-filter Auth.list_share_tokens(scope) by caller_ws == t.workspace_id; nil ws → all.
- mint  (8): resolve Tenancy.get_workspace_by_slug(ws_slug).id, reject if != caller_ws; nil ws → allow.
- revoke(9): gate token_id on membership in the caller-scoped list_share_tokens set BEFORE Auth.revoke_token(token_id); nil ws → allow. Reuses existing (unchanged) list_share_tokens read — no Repo.get in controller, no auth.ex change. Bonus fail-closed: list_share_tokens only yields share-scoped rows, so a non-share PAT id can't be revoked here.
- Global/host/platform admin (nil workspace_id) arm preserved on all three.
