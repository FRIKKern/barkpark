<!-- doc-tier: agent | canonical-for: studio-ui | budget: 500tok -->
# Studio (LiveView)

One LiveView — `StudioLive` — manages the multi-pane Studio at `/w/:ws/p/:proj/d/:dataset/studio` (flat `/studio/*` and legacy `/w/:ws/p/:proj/studio/:dataset` both 302 there; `BarkparkWeb.LiveScope` resolves + re-authorizes scope from URL params on every patch). Delegates to ~25 files under studio_live/; handlers in studio_live/handlers/<domain>.ex, shared helpers in studio_live/shared.ex, components in studio_live/components.ex.

Layout gotchas:
- `pane_builder.ex` lives at `lib/barkpark_web/studio/` — NOT `live/studio/`. Same dir: `presence_state.ex`, `nav.ex`, `dataset_switcher.ex`, `workspace_switcher.ex`.
- Panes update via PubSub; who-is-editing presence via `PresenceState`.
- Router mounts: StudioLive rides `live_session :scoped_studio` at `/w/:ws/p/:proj/d/:dataset/studio`; `live_session :admin_studio` mounts SettingsLive at `/studio/settings`; plugin LiveViews mount via `plugin_routes/1` in their own live_sessions. live_session names MUST be unique router-wide.
- `bp-*` Web Components (overflow menu etc.) → docs/studio/web-components.md.
- Styling is the inline `<style>` in root.html.heex using `--bg`/`--fg`/`--border` vars. No CSS files — for plugins too (see docs/cards/plugins.md).
- User-facing flows (ONIX-import SSH procedure, tab-not-in-URL decision) → docs/studio/user-guide.md.

## Sheet grid

`type:"sheet"` docs open as the grid editor (`editor_view: :sheet` → `SheetGrid` LiveComponent), not the field form. Edits are session ops (`Sheets.Session.apply_ops/3`); StudioLive forwards `{:sheets_op, …}` via `send_update/3` — own + remote edits ride one path, never applied locally by the component. Presence cursors/selections paint on an overlay layer (never inside the cell comprehension). Cmd/Ctrl+Z / +Shift+Z send per-user undo/redo ops. Render bound: used range, hard cap 500 rows.

## Code anchors
- api/lib/barkpark_web/live/studio/studio_live.ex — section-index header comment; `# ──` banners
- api/lib/barkpark_web/live/studio/sheet_grid.ex — defmodule BarkparkWeb.Studio.SheetGrid
- api/lib/barkpark_web/studio/pane_builder.ex — def build
- api/lib/barkpark_web/studio/presence_state.ex — def list
- api/lib/barkpark_web/router.ex — live_session :scoped_studio (StudioLive) / live_session :admin_studio (SettingsLive)
