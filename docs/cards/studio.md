<!-- doc-tier: agent | canonical-for: studio-ui | budget: 500tok -->
# Studio (LiveView)

`StudioLive` runs panes at `/w/:ws/p/:proj/d/:dataset/studio` (flat `/studio/*` + legacy 302; `LiveScope` re-auths scope each patch).

## Tiered desk — one tree, gated display
- **Tree** (`Structure.build`, also drives the Go TUI): MAIN top-level → collapsed **Plugins** node (subtree per ENABLED plugin) → **…Rest** census folder, honest counts. Media → top-menu unless promoted.
- **Placement + …Rest/Settings reject share ONE harvested `plugin_name → [owned types]` map** (`owned_schema_types/0`) — no hardcoded types.
- **PaneBuilder renders the GATED tree** (`panes[0]`); a stale deep link is REVEALED via its Plugins/…Rest ancestors, else falls back to ungated.

## Space-priority — role × priority × bucket
- Panes carry `data-role` (`content` on all SIX `.editor-panel` roots, else nav) + `data-priority`; `html[data-width-bucket]` (wide/standard/narrow/phone at 1280/1024/640) stamped pre-paint by the head script.
- `PaneBuilder.display_state/4` resolves `:full | :strip | :hidden` from those three. DERIVED — never on `Structure.Node` nor the `/v1/structure` wire.
- Content pane WINS every squeeze: paper floor `calc(55ch + 80px)` behind `@container content (min-width: 720px)`, classic `48ch`; pinned by `measure_parity_test`.

## Nav shell + layout
- **Model**: ONE source — `@canonical capability:studio-nav-model` in `nav.ex`: baseline tabs + `Registry.collect_top_menu_entries`, order-then-label.
- **Gating = two axes**. admin: `StudioChrome.shares_admin?`; plugin: `Enablement.effective(workspace_id)` — `nil` ws → declaration DEFAULTS, never show-all. `current_path` (`:handle_params`) marks ONE active entry.
- Chrome at `lib/barkpark_web/studio/`; panes via PubSub; CSS inline in root.html.heex; `sheet` opens `SheetGrid` (500-row cap).
- **Workspace Settings is SCOPED**: `SettingsLive` at `/w/:ws/p/:proj/studio/settings`; writes fail-closed, URL-bound workspace is truth.

## Code anchors
- api/lib/barkpark_web/components/studio_components/nav.ex — def studio_tabs
- api/lib/barkpark_web/studio_chrome.ex — def on_mount (shares_admin?, current_path)
- api/lib/barkpark/structure.ex — def build (tiered tree)
- api/lib/barkpark/plugins/enablement.ex — def effective
- api/lib/barkpark_web/studio/pane_builder.ex — def build; def display_state
