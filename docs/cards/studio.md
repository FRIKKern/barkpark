<!-- doc-tier: agent | canonical-for: studio-ui | budget: 500tok -->
# Studio (LiveView)

`StudioLive` runs the multi-pane Studio at `/w/:ws/p/:proj/d/:dataset/studio` (flat `/studio/*` + legacy 302 there; `LiveScope` re-auths scope from URL each patch).

## Nav shell — one contract, every route
- **Model**: ONE source — `@canonical capability:studio-nav-model` in `components/studio_components/nav.ex`: baseline tabs + `Registry.collect_top_menu_entries`, order-then-label. `Studio.Nav` is DELETED — never reintroduce.
- **Gating = two axes**. admin: `StudioChrome.shares_admin?` (token OR account admin), set by the shared `on_mount` per studio live_session. plugin: `Enablement.effective(workspace_id)` — `nil` ws → declaration DEFAULTS (never show-all); flat admin routes attribute the Default ws via `default_scope_fallback`.
- **Active state**: `current_path` set ONLY by the StudioChrome `:handle_params` hook (normalized, fresh) — LiveViews never hand-set it. ONE active entry per page; binary `active_when` = boundary-match (equal, or prefix + `/`).
- **nav_section demoted**: feeds only the api-tester topbar + DatasetSwitcher suffix — never visibility/active-state.
- **Exceptions**: swatch iframe cell (bare layout, no chrome); public readers `/papers`+`/sheets` (not Studio); Tickets inbox (controller route, outside the shell; wave-2).
- **Fence**: `test/barkpark_web/studio/nav_parity_sweep_test.exs` — new studio-layout routes join its mount table.

## Layout
- Chrome/switchers live at `lib/barkpark_web/studio/`, NOT `live/studio/`; panes update via PubSub.
- Router: StudioLive → `:scoped_studio`; SettingsLive → `:admin_studio` (`/studio/settings`); plugins → `plugin_routes/1`. live_session names MUST be router-wide unique.
- Styling: inline `<style>` in root.html.heex (`--bg`/`--fg`/`--border`), no CSS files. Web Components → docs/studio/web-components.md; flows → docs/studio/user-guide.md.
- `type:"sheet"` docs open the `SheetGrid` LiveComponent (session ops; cap 500 rows).

## Code anchors
- api/lib/barkpark_web/components/studio_components/nav.ex — def studio_tabs; @canonical capability:studio-nav-model
- api/lib/barkpark_web/studio_chrome.ex — def on_mount (shares_admin?, current_path hook)
- api/lib/barkpark/plugins/enablement.ex — def effective
- api/lib/barkpark/plugins/registry.ex — def collect_top_menu_entries
