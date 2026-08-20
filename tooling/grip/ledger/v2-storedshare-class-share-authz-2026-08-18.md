<!-- doc-tier: cold | canonical-for: v2-storedshare-classification-share-authz-wave | budget: 900tok -->

# V2 — StoredShare classification (share-authz wave, api-read-path-security-sweep)

Ruling: `share_controller` index/create/delete are a GLOBAL HOST-ADMIN REGISTRY
(ruling-bound FILE), NOT a per-workspace resource (not build-in-fence). Contrast
with `Links.revoke` (build-in-fence) rests on ONE schema fact: StoredShare has no
owner FK; ShareLink does.

## Re-derivation recipes (run from repo root)

Schema — StoredShare has NO workspace_id FK, only slug strings:
    git show origin/main:api/lib/barkpark/sharing/stored_share.ex | grep -n 'field\|schema'
    git show origin/main:api/priv/repo/migrations/20260609000000_create_shares.exs | grep -n 'add :\|table('
  → columns: id(binary_id PK), workspace_slug:text, project_slug:text, dataset:text,
    surfaces:{array,text}, access:text, timestamps. workspace_slug is the EXPOSURE
    TARGET (scope subject), not an owner reference. No belongs_to.

Contrast — ShareLink DOES carry an owner workspace_id FK (why revoke is in-fence):
    git show origin/main:api/lib/barkpark/sharing/share_link.ex | grep -n 'belongs_to\|workspace_id'
  → `belongs_to :workspace, Barkpark.Tenancy.Workspace` + :workspace_id in @fields.

Registry is env-twinned (part of the listed set has NO DB row to scope):
    git show origin/main:api/lib/barkpark/sharing/sharing.ex | grep -n 'shares_env\|list_stored\|BARKPARK_SHARES\|refresh'
  → live :shares = shares_env() ++ list_stored(). index() emits BOTH (source "env"/"stored").

Controller takes caller-supplied scope, no actor filter; mounted require_admin only:
    git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | grep -n 'def index\|def create\|def delete\|add_share\|remove_share\|list_stored\|require_admin'

remove_share side-effect crosses into Auth (shared primitive, out of fence):
    git show origin/main:api/lib/barkpark/auth.ex | grep -n 'def revoke_share_tokens'
  → remove_share/3 calls Barkpark.Auth.revoke_share_tokens(ws,proj,dataset).

## Why FILE, not BUILD-in-fence
1. No owner column → the revoke primitive (Repo.get_by id+workspace_id) has NO analog.
   The only workspace ref is workspace_slug = exposure TARGET, not owner.
2. Env twin: index() lists BARKPARK_SHARES env shares that have no DB row at all —
   nothing to scope; they are pure operator declaration.
3. Correct confinement is a host-admin-only POLICY ruling (require_admin →
   require-host-admin, router/pipeline-shaped) — the exact bespoke-pipeline shape
   the wave deliberately avoids for the in-fence controller-token pattern.
