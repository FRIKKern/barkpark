# Re-derivation recipe — installation-global plugin-credential authority hole (connectors W35, settings-global-cred-authority)

Verifier: connectors wave-35 [settings-global-cred-authority]. NOT committed by me — Decide commits.

## The claim
SettingsLive's credential handlers (`reveal` :149, `reveal_field` :187, `save`→save_generic/save_typed :217, `delete` :227) operate on the installation-GLOBAL `plugin_settings` row (keyed by `plugin_name` only, NO workspace column) and carry NEITHER `guard_bound_ws/3` NOR `guard_ws_admin/3`. The panel now mounts under `LiveAuth.:scoped_admin` (per-workspace admin of the URL workspace — NOT global-permission). So an admin of workspace B ONLY can mount `/w/B/p/…/studio/settings` and reveal / overwrite / delete plugin credentials shared by every tenant. W34/#5972 added the per-write re-gate to theme/plugin/placement but explicitly scoped credentials OUT ("credentials are installation-global … out of this guard's scope by design", settings_live.ex ~:349).

## Re-derive the ungated handlers
    git show origin/main:api/lib/barkpark_web/live/studio/settings_live.ex | sed -n '149,252p'
    # reveal/reveal_field/save/delete → Settings.reveal|put|delete direct, no guard_* wrapper
    # contrast: set_workspace_theme :255 / toggle_plugin :271 / set_plugin_placement :296 all wrap guard_bound_ws → guard_ws_admin

## Re-derive the store is installation-global (no tenant column)
    git show origin/main:api/priv/repo/migrations/20260426100002_create_plugin_settings.exs
    # add :plugin_name, primary_key; add :settings; add :updated_at; add :updated_by — NO workspace_id
    git show origin/main:api/lib/barkpark/plugins/settings_record.ex
    # @primary_key {:plugin_name,:string}; schema "plugin_settings" — no workspace field

## Re-derive the mount gate is scoped_admin (per-workspace, not global)
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1305,1332p'   # live_session :scoped_admin_studio → {LiveAuth,:scoped_admin}; live "/settings", SettingsLive
    git show origin/main:api/lib/barkpark_web/live_auth.ex | sed -n '82,90p;255,262p'  # :scoped_admin → workspace_admin?(principal, URL ws)

## Re-derive the test state (ungated behavior pinned; escalation UNtested)
    cd api && MIX_ENV=test mix test test/barkpark_web/live/studio/settings_live_test.exs 2>&1 | tail -3   # 42 tests, 0 failures
    git show origin/main:api/test/barkpark_web/live/studio/settings_live_test.exs | sed -n '167,235p'
    # "reveal fetches unmasked" / "delete removes row" run under @admin_token (GLOBAL admin + Default admin member) — assert happy path, NEVER a workspace-B-only admin refusal on credential handlers

## Re-derive the unpaid E2 on #5972 itself
    gh pr view 5972 --json title,mergedAt,reviews    # mergedAt 2026-07-23T10:36:28Z, reviews: []
    bp task get connectors-settingslive-theme-plugin-per-write-belt -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['content']['lifecycle_status']);print(d['content']['acceptance_criteria'][3]['met'],d['content']['acceptance_criteria'][3]['evidence'])"
    # lifecycle_status: open ; C3 met=False, evidence="" — E2 second review never recorded; task never closed

## Remedy judgment (for Decide)
Credentials are GENUINELY installation-global (one Bokbasen/Indx account per deployment; PluginSettingsController + Indx/Bokbasen/EdgeProjector wrappers all read `Settings.get(plugin_name)` with no workspace). So:
- (b) tenant-scope SettingsRecord = WRONG model (fragments a one-per-install credential; cascades into /v1/plugins/settings CRUD + every wrapper). Reject.
- (c) single-tenant-per-install doc = contradicts multi-tenant epic. Reject.
- (a) installation-admin re-gate = CORRECT + cheap. Wrap reveal/reveal_field/save/delete with guard_installation_admin (token arm Auth.has_permission?(tok,"admin"); user arm Tenancy.Auth.authorize(user, default_ws, :admin)), fail-closed, negated-cond-first, ZERO Settings.* on refusal. Restores the invariant the flat `:admin`-gated /studio/settings had before W26's scoped move silently weakened the credential subset. Existing @admin_token tests stay green (it IS an installation admin). New E2 test: admin-of-B-ONLY token → reveal/save/delete refused, plugin_settings row unchanged (STATE oracle, not the flash substring — W34 vacuous-oracle lesson: "owner or admin" phrase also lives in help text). Mutation-prove: neuter re-gate → state changes → red → restore → green. Its own independent second reviewer (HIGH-FLIP: credential handling + tenant authority).
