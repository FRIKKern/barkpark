<!-- doc-tier: agent | canonical-for: studio-ui | budget: 500tok -->
# Studio (LiveView)

One LiveView — `StudioLive` — manages the whole multi-pane Studio at `/w/:ws/p/:proj/studio/:dataset` (flat `/studio/*` 302s there; `BarkparkWeb.LiveScope` resolves + re-authorizes scope from URL params on every patch). The file is ~4,800 lines: do NOT read it whole. It opens with a section-index comment; grep the `# ──` banners for the handle_event/handle_info group you need.

Layout gotchas:
- `pane_builder.ex` lives at `lib/barkpark_web/studio/` — NOT `live/studio/`. Same dir holds `presence_state.ex`, `nav.ex`, `dataset_switcher.ex`, `workspace_switcher.ex`.
- Panes update in real time via PubSub; who-is-editing presence via `PresenceState`.
- Router mounts: core Studio rides `live_session :admin_studio`; plugin LiveViews are mounted by the `plugin_routes/1` macro in their own live_sessions (`:plugin_admin` / `:plugin_public` / `:plugin_ops` + scoped variants). live_session names MUST be unique router-wide.
- `bp-*` Web Components (overflow menu etc.): decision record (composed:false, phx-update=ignore, execCommand choice) → docs/studio/web-components.md.
- Styling is the inline `<style>` in root.html.heex using `--bg`/`--fg`/`--border` vars. No CSS files — for plugins too (see docs/cards/plugins.md).
- User-facing flows (ONIX-import SSH procedure, tab-not-in-URL decision) → docs/studio/user-guide.md.

## Code anchors
- api/lib/barkpark_web/live/studio/studio_live.ex — section-index header comment; `# ──` banners
- api/lib/barkpark_web/studio/pane_builder.ex — def build
- api/lib/barkpark_web/studio/presence_state.ex — def list
- api/lib/barkpark_web/router.ex — live_session :admin_studio
