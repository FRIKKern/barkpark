# bp-studio-deep-link — Studio linking & path consistency

Epic task: `bp-studio-deep-link` (published; wave slices are its children).

## Vision

Every Studio destination has ONE canonical URL, ONE builder emits it, and URL-equals-state is an
enforced invariant. Paste any Studio URL into a fresh browser and you get exactly the pixels and
scope of clicking there. No navigation ever silently swaps your workspace/project/dataset. Every
scope-trail target and back-navigation path is the canonical path it claims to be — and CI catches
the next hand-built href the same way doc anchors are caught.

The Scoped-by-URL initiative (P0–P4, design Paper `/papers/studio-url-architecture`) already shipped
the hard core for the content/desk surface: StudioLive has exactly one live mount
(`/w/:ws/p/:proj/d/:ds/studio[/*path]`), LiveScope re-authorizes from URL params on mount and every
patch, and flat forms 302 through StudioRedirectController. This epic is the consolidation +
enforcement endgame: kill the residual teleports, unify the emitters, canonicalize the flat admin
family, and pin the fixed state with a gate.

## Scope boundary (sibling: bp-studio-nav-shell)

We own: routes, URL builders/helpers (`Paths`), link TARGET strings, breadcrumb/back TRUTH (targets
and data), `handle_params`/LiveScope scope resolution, the redirect funnels. The sibling owns
sidebar/menu chrome RENDERING and visibility. The seam runs THROUGH files: in
`components/studio_components/nav.ex` the target builders (`default_top_menu_entries` + `*_entry`
helpers) are ours; the `studio_tabs` render loop and topbar/shell/footer markup are theirs. Chrome
rendering changes needed by our fixes get filed as notes to the sibling, not built here.

## Decisions

1. **Paths is THE builder.** Every Studio URL string is produced inside
   `BarkparkWeb.Studio.StudioLive.Paths` — socket-free, `scope_prefix` passed in. Add
   `Paths.studio_path(scope_prefix, segments, dataset, opts)` (prefix-aware) and
   `Paths.scoped_root(ws_slug, proj_slug, dataset)`; `Shared.studio_path/4` stays as the
   socket-aware wrapper that reads `scope_prefix` off assigns and delegates. *Why:* the grammar is
   hand-built in ≥10 places today (studio_chrome, nav tabs, redirect controller, media_live,
   components); one owner ends the drift class.
2. **Plugin links go canonical at the SOURCE; `scoped_plugin_href` shim retired.** PaneBuilder gets
   `scope_prefix` threaded in and emits canonical `:plugin_link` hrefs via Paths;
   `components.ex:647` stops rewriting; the shim is deleted and the
   `scoped_studio_mount_test` "plugin-link hrefs" describe is updated to assert source-canonical.
   *Why:* the render-time rewrite was a point-fix to dodge the teleporting 302 funnel; fixing the
   source removes the funnel entry entirely.
3. **Teleport killed: referring scope beats session.** `StudioRedirectController` resolution order
   when the URL under-determines workspace: (a) scope in the URL (already handled by
   `legacy_scoped`), (b) `/w/:ws/p/:proj` parsed from the `Referer` header, membership-validated,
   (c) session/first-membership fallback only when both are absent. `resolve_dataset` resolves
   within the chosen workspace. *Why:* `resolve_workspace` today picks the first slug-ordered
   membership unconditionally — the daily-pain teleport for multi-workspace users.
4. **Admin family split by SUBSTANCE, not URL shape.**
   - Scoped-in-substance → move under the canonical with 302 back-compat:
     `settings` → `/w/:ws/p/:proj/studio/settings` (workspace-level, dataset-less scoped grammar,
     same family as scoped plugin admin routes); `_plugins` →
     `/w/:ws/p/:proj/d/:ds/studio/_plugins[/:plugin/settings]` (declared BEFORE the
     `:scoped_studio` `/*path` catch-all). *Why:* SettingsLive edits ONE workspace's settings but
     the flat route pins the seeded Default workspace — a substantive-scope teleport (users in
     workspace B silently edit Default's settings).
   - Genuinely scope-free → stay flat: `org-admin` (org-level), `styleguide`, `tmux`, `chat`
     (session-based, D14 handle_params pattern). They carry a truthful return path (D5).
5. **`return_to` contract for flat destinations.** Scoped surfaces linking to a flat destination
   attach `?return_to=<current canonical path>`; the flat LV threads it through its own patches;
   any back/exit/disabled-fallback redirect prefers a VALIDATED `return_to` (must parse as a
   local `/w/…` canonical Studio path — never an absolute URL, no open redirect) over the
   `/studio` session funnel. *Why:* flat surfaces have `scope_prefix=""` and literally cannot
   build a truthful return today; `redirect(to: "/studio")` rides the teleport.
6. **URL-state doctrine (D14 generalized): whatever survives a reload derives from path+query.**
   Declared EPHEMERAL (documented, intentionally socket-only): `nav_group`, `diff_visible`,
   `editor_mode` (:classic/:beta), `paper_edit_mode`, `content_preview_visible`, api-tester
   endpoint selection, all modals except shares (`?shares=open` stays URL-backed). To ENCODE in a
   later wave: the secondary/split pane (biggest parity hole — a shared link can never reproduce a
   split view). *Why:* explicit contract beats silent loss; encoding secondary needs its own
   design (param grammar + rebuild path) and doesn't block the teleport/emitter work.
7. **Enforcement gate ships in the same wave as the fixes.** Three layers: (a) Paths unit
   round-trip test (build→parse→state), (b) route-grammar test asserting every destination's
   canonical + 302 back-compat + deep-link-reproduces-clicking, (c) `scripts/studio-link-lint.sh`
   — grep-tree-and-fail (docs-anchors-check §8 idiom) over `api/lib/barkpark_web` for hand-built
   Studio URL literals outside Paths, with an explicit whitelist for the deliberate flat family.
   *Why:* without the gate the next hand-built href reintroduces the drift; the whitelist makes
   "deliberately flat" a reviewed decision instead of an accident.
8. **Dead code dies.** `BarkparkWeb.Studio.Nav` (duplicate tab builder, referenced only by its own
   test + a stale doc comment) is deleted with its test; the stale Paths moduledoc (claims the
   choke point "stays in StudioLive" — it's `Shared.studio_path/4`) is corrected.
9. **Deferred, deliberately:** plugin dual mounts (flat `/studio/<plugin>` live routes 302→scoped),
   papers' four spellings → one canonical, media dual-path (standalone MediaLive vs in-Studio
   `:media_explorer`), secondary-pane URL encoding, possible scoped chat mount. All wave 2+ — wave
   1 is the daily-pain bug class + the gate that pins it.

## Roadmap

Wave 1 (this wave — integration order):
1. `sdl-w1-builder` (large) — Paths promoted to THE builder; all Class B emitters rerouted;
   plugin_link canonical at source; shim + dead Nav module deleted.
2. `sdl-w1-teleport` (medium) — Referer-aware scope resolution in the redirect funnels; session
   demoted to last resort.
3. `sdl-w1-admin-canonical` (medium) — settings + `_plugins` move under the canonical with 302
   back-compat.
4. `sdl-w1-return-path` (medium) — `return_to` contract for chat/tmux/styleguide/org-admin.
5. `sdl-w1-gate` (medium) — Paths round-trip test + route-grammar test + studio-link-lint CI gate
   (lands last, pins the post-fix state).

Wave 2 (candidates, re-cut after wave 1 review):
- Flat plugin live mounts become 302s → scoped is the only live mount (onixedit/tickets/tasks/
  github/pulse).
- Papers: one canonical reader grammar (four spellings today).
- Secondary/split pane encoded in URL.
- Media dual-path: declare distinct-destinations or collapse.
- Chat scoped-mount decision (today: flat + return_to).
- `/*path` catch-all vs explicit `/media`/`/api-tester` collision: declare reserved segments.

Wave 3: residuals from review; docs (`docs/cards/studio.md`, api-v1.md §1a) updated to the final
grammar if drifted.

## Wave log

### Wave 2026-07-09 — wave 1 built + reviewed (all five slices green)

**Landed (reviewer-fixed branches, integration order):**

1. `sdl-w1-builder` — `loop-epic/paths-is-the-studio-url-builder-all-emit-0` (clean, no review
   fixes). Paths is THE builder: `studio_path/4`, `scoped_root/3`, `flat_root/1`, `paper_path/2`;
   plugin_link hrefs canonical at SOURCE (scope_prefix threaded Shared→PaneBuilder→list_items/2);
   `scoped_plugin_href` shim + dead `Studio.Nav` deleted. Gate 41/0.
2. `sdl-w1-teleport` — `loop-epic/teleport-killed-flat-scoped-redirects-pr-1` (clean, no review
   fixes). New `BarkparkWeb.Studio.ScopeResolver` (`@canonical capability:studio-scope-resolution`):
   the Referer's membership-verified `/w/:ws/p/:proj` beats first-membership; preference only,
   never auth. All three funnels (StudioRedirect/Page/LegacyRedirect) share `scoped_studio_target`.
   Gate 16/0.
3. `sdl-w1-admin-canonical` — **merge the -r branch**
   `loop-epic/scoped-in-substance-admin-surfaces-move--2-r`: reviewer merged the teleport branch in
   and swapped the inlined first-membership seam in `AdminStudioRedirectController` for the real
   `ScopeResolver` delegation (flat admin 302s are now Referer-aware too). settings →
   `/w/:ws/p/:proj/studio/settings` (LiveScope-bound — substance test proves B writes to B, never
   Default); `_plugins` → `/w/:ws/p/:proj/d/:ds/studio/_plugins[...]`; flat spellings 302.
   123/0 on the merged state.
4. `sdl-w1-return-path` — **merge the -r branch**
   `loop-epic/flat-scope-free-destinations-carry-a-tru-3-r`: reviewer hardened `ReturnTo` against
   dot-segment traversal (`..`/`.` and their `%2e` spellings — a crafted return_to could otherwise
   normalize to an arbitrary same-origin path) and integrated sdl-w1-builder (nav.ex auto-merge
   verified, stale arity docs fixed). Contract: scoped tabs stamp return_to; chat/tmux thread +
   sanitize it; disabled fallbacks prefer it over the `/studio` funnel. 20/0 + combined 61/0.
5. `sdl-w1-gate` — **merge the -r branch** `loop-epic/url-equals-state-pinned-paths-round-trip-4-r`
   (contains merges of all four fix slices; lands LAST). The builder built on plain main; the
   reviewer resolved ALL its integration debt: paths_test now covers the promoted builders and the
   `plugin_link_href` rename (**the original branch's paths_test crashes once sdl-w1-builder merges
   — do NOT merge the original**); the grammar test asserts the scoped admin canonicals +
   Referer-resolved admin 302s; lint whitelist PENDING entries pruned to zero; the two `_plugins`
   LV path helpers (fresh hand-builders from the admin slice) rerouted through Paths; new SEAM
   whitelist entry for AdminStudioRedirectController. Lint PASS + selftest bites. Full studio blast
   radius on the integrated tree: **1313 tests, 0 failures**.

**Merge order for the lead:** builder → teleport → admin-canonical(-r) → return-path(-r) →
gate(-r). All .ex-touching — wait for the CI Elixir Test gate. The -r branches already contain
their upstream siblings (merge commits), so later merges stay conflict-free. The lead closes each
task's merge-gated "PR merged" criterion on merge.

**Stalled:** nothing — all five slices green.

**Next wave (wave-2 re-cut, charter candidates + review findings):**
- Flat plugin live mounts (onixedit/tickets/tasks/github/pulse) become 302s → scoped is the only
  live mount — now trivially expressible through ScopeResolver + Paths.
- Papers: one canonical reader grammar (four spellings today; `paper_path/2` is ready as owner).
- Media dual-path (standalone MediaLive vs `:media_explorer`) — declare distinct or collapse.
- Secondary/split pane URL encoding — biggest URL==state parity hole; needs param-grammar design.
- Review findings to fold in: (a) User-principal sessions (no api_token) still resolve to Default
  in ScopeResolver — the Referer preference keys off ApiToken only; extend when the
  enterprise-auth session surface lands. (b) `same_origin?` compares host only (not scheme/port)
  — fine as defence-in-depth, tighten if hosts ever diverge only by port. (c) chat/tmux return_to
  is threaded but no chrome back-affordance renders it yet — sibling notes task-fb0ab1946adf6238
  + task-21541772c8cd62e6 under bp-studio-nav-shell.
