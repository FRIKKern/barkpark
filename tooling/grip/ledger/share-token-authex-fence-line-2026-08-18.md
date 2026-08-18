<!-- doc-tier: cold | canonical-for: share-token-authex-fence-line-rederivation | budget: 800tok -->

# Share-token actions 7-9 — auth.ex fence line (V3 re-derivation)

Re-derive whether share_controller mint/list/revoke_token can be confined to
the actor's workspace ENTIRELY controller-side with NO auth.ex signature change.

## Commands

    # auth.ex primitives (all PUBLIC, unscoped by workspace):
    git show origin/main:api/lib/barkpark/auth.ex | grep -n \
      'def revoke_token\|def list_share_tokens\|def create_share_token'
    # -> revoke_token/1 @200 (%ApiToken{}) + @227 (binary id, bare Repo.get)
    #    create_share_token/5 @616, list_share_tokens/1 @678

    # revoke_token/1 binary head is a BARE Repo.get (no ws filter):
    git show origin/main:api/lib/barkpark/auth.ex | sed -n '227,244p'
    # -> Repo.get(ApiToken, uuid) ; no workspace_id

    # SHARED primitive — non-share callers that MUST stay unscoped:
    git grep -n 'revoke_token(' origin/main -- api/lib | grep -v 'def revoke_token'
    # studio_chat/runtime.ex:654, runtime/codex/session.ex:612,
    # fleet_support_token_controller.ex:75, claude_chat.ex:1601,
    # app_token_controller.ex:140/175, connectors_live.ex:365/375/399/562
    # -> all revoke their OWN session/connector/app tokens; scoping breaks them.

    # controller actions 7-9:
    git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | sed -n '95,160p'

    # actor workspace is available: RequireToken sets conn.assigns[:api_token],
    # ApiToken carries workspace_id (bound) / nil (global-admin):
    git grep -n '%ApiToken{workspace_id' origin/main -- api/lib/barkpark_web/plugs

## Verdict

All three confinable CONTROLLER-SIDE, NO auth.ex change (fence holds):
- mint_token: resolve scope's ws_slug -> Tenancy.get_workspace_by_slug(ws).id,
  compare to conn.assigns.api_token.workspace_id BEFORE create_share_token; reject mismatch.
- list_tokens: post-filter list_share_tokens/1 rows by .workspace_id.
- revoke_token: list_share_tokens() |> Enum.find(&(&1.id==token_id)) to READ
  the target's workspace_id (existing fn, in-fence), compare, then revoke_token(token_id).
- All three: nil actor workspace_id => global/host/platform admin => NO filter (see-all).
- auth.ex.revoke_token/1 stays untouched -> its 6+ non-share callers unaffected.
