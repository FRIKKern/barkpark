<!-- doc-tier: cold | canonical-for: none | budget: 2000tok -->
# V4 premise-smoke re-derivation — sharing object-authz wave (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Every premise the direction/charter/wish cites, re-derived on origin/main. Citation
line numbers had drifted; every named SYMBOL still exists. Re-run commands:

```
# Confirmed door: bare unscoped Repo.get in revoke
git show origin/main:api/lib/barkpark/sharing/links.ex | sed -n '91,110p'   # def revoke/1 @91, Repo.get(ShareLink,uuid) @99

# Both callers of Links.revoke
git show origin/main:api/lib/barkpark_web/controllers/share_link_controller.ex | sed -n '219,222p'  # DELETE action @219 -> Links.revoke(id) @220
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex | grep -n 'Links.revoke'  # item_share_revoke @67 -> Links.revoke(id) @69 (path drifted from cited studio/item_share.ex)

# Router shares scope (cited 2051-2072 STALE -> real 2099-2130)
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2099,2130p'    # delete("/links/:id",ShareLinkController,:revoke) @2119
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '706,709p'      # pipeline :require_admin (cited 682-684 STALE) = RequireToken+RequireAdmin, NO workspace binding

# Grounding discovery: list/mint resolve workspace from CLIENT scope, not token
git show origin/main:api/lib/barkpark_web/controllers/share_link_controller.ex | sed -n '206,216p'  # list: Tenancy.get_workspace_by_slug(params scope) -> list_for(workspace.id) ; link_json url:@304 emits raw l.token
git show origin/main:api/lib/barkpark_web/controllers/share_link_controller.ex | sed -n '168,192p'  # mint: same client-scope resolution -> Links.create

# Fix-primitive idiom (surface_configs two-head, cited 274-289 EXACT)
git show origin/main:api/lib/barkpark/search/surface_configs.ex | sed -n '274,289p'  # nil-scope clause vs workspace_id clause; nil arm = get_row(...,nil) NOT get_by(workspace_id:nil)

# Fence seam: share_controller token actions resolve OUT of fence into auth.ex; revoke_token/1 is SHARED
grep -rn 'Auth.revoke_token\|revoke_token(' api/lib --include='*.ex'  # callers: studio_chat/runtime@654, codex/session@612, claude_chat@1601, connectors_live@365 -> signature must NOT change

# Charter FULL scan (333 lines / 87590 bytes, not 2KB preview) for ruling-bound sharing clause
git show origin/main:.claude/workflows/bp-security-remainder-charter.md | grep -in 'ruling\|shar\|fence\|barkpark_web/live'
#  -> only share finding = line 30 foreign-scope-share-token-flat-read, already BUILT+MERGED #11765 (share-EDIT-token flat-read, DIFFERENT mechanism from Links object-authz)
#  -> ZERO clause designates Links.revoke/list/mint ruling-bound: ZERO-ruling-bound-sharing certification HOLDS after full scan
#  -> charter is SILENT on this wave: neither authorizes controller-token-read NOR blesses a barkpark_web/live one-line exception (wave-local judgment, not charter-backed)

# Task + open-PR fence state
bp task get arpss-item-share-revoke-unscoped-revoke -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d.get('assignee'),d.get('claim'))"  # -> open None None
gh pr list --state open --limit 150 --json number,files --jq '.[]|select([.files[].path|test("barkpark/sharing|share_link_controller|share_controller|handlers/item_share|barkpark/auth\\.ex")]|any)|.number'  # -> (empty) ZERO open PRs in fence
```
