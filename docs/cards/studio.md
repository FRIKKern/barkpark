<!-- doc-tier: agent | canonical-for: studio-ui | budget: 500tok -->
# Studio (LiveView)

One LiveView — `StudioLive` — manages the whole multi-pane Studio at `/w/:ws/p/:proj/d/:dataset/studio` (flat `/studio/*` and the old scoped `/w/:ws/p/:proj/studio/:dataset` form both 302 there; `BarkparkWeb.LiveScope` resolves + re-authorizes scope from URL params on every patch). The file is ~4,800 lines: do NOT read it whole. It opens with a section-index comment; grep the `# ──` banners for the handle_event/handle_info group you need.

Layout gotchas:
- `pane_builder.ex` lives at `lib/barkpark_web/studio/` — NOT `live/studio/`. Same dir holds `presence_state.ex`, `nav.ex`, `dataset_switcher.ex`, `workspace_switcher.ex`.
- Panes update in real time via PubSub; who-is-editing presence via `PresenceState`.
- Router mounts: core Studio rides `live_session :admin_studio`; plugin LiveViews are mounted by the `plugin_routes/1` macro in their own live_sessions (`:plugin_admin` / `:plugin_public` / `:plugin_ops` + scoped variants). live_session names MUST be unique router-wide.
- `bp-*` Web Components (overflow menu etc.): decision record → docs/studio/web-components.md.
- Styling is the inline `<style>` in root.html.heex using `--bg`/`--fg`/`--border` vars. No CSS files — for plugins too (see docs/cards/plugins.md).
- User-facing flows (ONIX-import SSH procedure, tab-not-in-URL decision) → docs/studio/user-guide.md.

## Sheet grid

`type:"sheet"` docs open as the grid editor (`editor_view: :sheet` → `SheetGrid` LiveComponent), not the field form. Edits are session ops (`Sheets.Session.apply_ops/3`); the component never applies ops locally — StudioLive forwards `{:sheets_op, …}` deltas via `send_update/3`, so own + remote edits ride ONE path. Presence cursors/selections paint on an overlay layer SIBLING to the table (perf: never in the cell comprehension). Cmd/Ctrl+Z / +Shift+Z send per-user undo/redo ops. Render bound: used range, hard cap 500 rows.

## Code anchors
- api/lib/barkpark_web/live/studio/studio_live.ex — section-index header comment; `# ──` banners
- api/lib/barkpark_web/live/studio/sheet_grid.ex — defmodule BarkparkWeb.Studio.SheetGrid
- api/lib/barkpark_web/studio/pane_builder.ex — def build
- api/lib/barkpark_web/studio/presence_state.ex — def list
- api/lib/barkpark_web/router.ex — live_session :admin_studio
