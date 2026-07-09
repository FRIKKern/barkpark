<!-- doc-tier: agent | canonical-for: studio-ui | budget: 500tok -->
# Studio (LiveView)

`StudioLive` runs the multi-pane Studio at `/w/:ws/p/:proj/d/:dataset/studio` (flat `/studio/*` + legacy 302; `LiveScope` re-auths scope each patch).

## Tiered desk — one server tree, gated display
- **Tree** (`Structure.build`, also drives the Go TUI): MAIN top-level (Papers/Sheets/Tasks + content/taxonomy/settings, no wrapper) → collapsed **Plugins** node (subtree per ENABLED plugin) → **…Rest** census folder with honest counts (orphaned/ad-hoc types surface). Media → top-menu unless promoted.
- **Placement + …Rest/Settings reject share ONE harvested `plugin_name → [owned types]` map** per build (`owned_schema_types/0`) — no hardcoded type lists.
- **PaneBuilder renders the GATED tree** (`panes[0]`); nav resolves gated-first — a stale deep link is REVEALED via its nested Plugins/…Rest ancestors, falling back to the ungated tree when the type is absent (Media, disabled plugin).

## Nav shell — one contract, every route
- **Model**: ONE source — `@canonical capability:studio-nav-model` in `nav.ex`: baseline tabs + `Registry.collect_top_menu_entries`, order-then-label. `Studio.Nav` is DELETED.
- **Gating = two axes**. admin: `StudioChrome.shares_admin?` (token OR account admin). plugin: `Enablement.effective(workspace_id)` — `nil` ws → declaration DEFAULTS (never show-all).
- **Active state**: `current_path` set ONLY by StudioChrome `:handle_params`; ONE active entry.

## Layout
- Chrome at `lib/barkpark_web/studio/`; panes via PubSub.
- **Workspace Settings is SCOPED**: `SettingsLive` at `/w/:ws/p/:proj/d/:ds/studio/settings` in `:scoped_admin_studio` (flat `/studio/settings` redirects there). Writes fail-closed — the URL-bound workspace is truth; a stamped-ws mismatch REFUSES with a flash, never silently retargets.
- Styling: inline `<style>` in root.html.heex; `sheet` docs open `SheetGrid` (cap 500 rows).

## Code anchors
- api/lib/barkpark_web/components/studio_components/nav.ex — def studio_tabs; @canonical capability:studio-nav-model
- api/lib/barkpark_web/studio_chrome.ex — def on_mount (shares_admin?, current_path)
- api/lib/barkpark/structure.ex — def build (tiered tree + owned map)
- api/lib/barkpark/plugins/enablement.ex — def effective
- api/lib/barkpark_web/studio/pane_builder.ex — def build (gated display + reveal)
