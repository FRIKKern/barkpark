# bp-studio-nav-shell — Studio Navigation Shell charter

Epic task: `bp-studio-nav-shell` (published; wave slices are its children).

## Vision

Wherever you are in Studio, the shell looks and behaves identically and always tells you
where you are. Nav is a pure function of stable inputs — (workspace scope, admin?, enabled
plugins, current path) — never a function of which page you happen to be on or which mount
remembered to set which assign. One nav model, one shell hook, one documented set of
visibility rules, and a route-sweep parity test that makes any future regression fail CI.

Ground truth (exploration, 2026-07-09): the entry LIST is already computed identically per
render (`default_top_menu_entries/3` + plugin resolver merge, stable `{order,label}` sort),
and admin gating is already uniform via `StudioChrome.shares_admin?`. The reproducible
disease is ACTIVE-STATE: `current_path` drives all highlighting, `StudioChrome` only
`assign_new`s it to nil with no `:handle_params` hook, and only 4 of ~13 Studio LVs hand-set
it — so ApiTester, Styleguide, Settings, OrgAdmin, Plugins, plugin-admin LVs render with ZERO
active tab. Secondary diseases: a dead "single source of truth" fork
(`BarkparkWeb.Studio.Nav.tabs/1`, zero live callers, wrong path shape, guarded by a phantom
test), a nil-workspace hole that SKIPS plugin-enablement filtering (all plugin tabs leak),
and the `:plugin_public` live_session mounting chrome with no LiveAuth (admin tabs vanish
for admins there).

## Scope boundary

- We own: layout components, shell hook, nav model, visibility + active-state logic.
- We do NOT touch link targets, URL shapes, or router route structure (sibling epic
  bp-studio-deep-link-charter owns that). Adding a non-gating on_mount to an existing
  live_session is allowed (chrome behavior); moving/renaming routes is not.
- OUT of scope by design: public readers (/papers, /sheets), the swatch iframe cell
  (`swatch.html.heex` is deliberately chrome-less), and the Tickets inbox controller route
  (non-LiveView; filed as a note for a future wave / sibling).
- Plugin enablement semantics are OWNED by bp-studio-structure-polish (two-layer
  enablement, `Barkpark.Plugins.Enablement.effective/1`, placement tiers). We consume,
  never re-decide. Their wave 2 also edits `components/studio_components/nav.ex` — lead
  serializes merges on that file.

## Decisions

1. **Canonicalize the LIVE nav source; delete the dead fork.** `default_top_menu_entries/3`
   in `components/studio_components/nav.ex` (+ the `studio_tabs/1` resolver merge) IS the
   nav model — promote its entry point to public, stamp `@canonical
   capability:studio-nav-model aka:nav-tabs,top-menu,studio-tabs doc:docs/cards/studio.md`,
   fix the false "derived from Studio.Nav.tabs/1" docstring, and DELETE
   `barkpark_web/studio/nav.ex` + `test/barkpark_web/studio/nav_test.exs` (which pins a
   path shape the live code never produces). Why: exploration proved `Studio.Nav.tabs/1`
   has zero live callers and lacks all gating/active-state machinery — promoting it (the
   original lean) would regress; the richer function is the truth.
2. **StudioChrome IS the shared shell hook — finish it, don't rebuild it.** It is already
   attached to every Studio live_session and already computes scope_prefix, dataset,
   workspace, `shares_admin?`. Add ONE thing: `attach_hook(:handle_params)` that derives
   `current_path` from the URI on every mount/patch (generalizing
   `studio_live/handlers/lifecycle.ex:21-30`), normalized (no trailing slash, no query).
   Delete every per-LV `current_path` hand-set (StudioLive lifecycle, MediaLive, ChatLive,
   TmuxLive) so the hook is the ONE producer. Why: active-state becomes derived-everywhere
   instead of hand-set-in-4-places, killing the whole "no tab lit on ApiTester/Styleguide/
   Settings" class at once.
3. **`nav_section` survives, demoted.** It no longer drives active-state (already true) but
   still feeds the api-tester topbar action group (`studio.html.heex:54`) and the
   DatasetSwitcher section suffix. Keep those two consumers; do not add new ones; dead
   `nav_section` sets elsewhere may be removed opportunistically. Why: deleting it outright
   breaks two live chrome elements for zero user value this wave.
4. **Deterministic visibility, both axes, fail-to-defaults.** Admin axis: every
   studio-layout live_session must compute admin? — add non-gating
   `{LiveAuth, :fetch_api_token}` to `:plugin_public` / `:scoped_plugin_public` on_mount
   lists so admin chrome no longer vanishes for admins there. Plugin axis: nil
   `workspace_id` must NOT skip enablement filtering — resolve via
   `Enablement.effective(nil)` → declaration defaults (structure-polish Decision 4's own
   rule), never "show everything". Flat admin routes deterministically attribute the
   Default workspace (existing `default_scope_fallback`) — documented rule, not a bug.
   Why: an entry becomes present-everywhere or absent-everywhere for a given
   user+workspace-scope, with no auth-mode or seeding accidents.
5. **Prove it with a route-sweep parity test — the wave's spine.** Reflection over
   `BarkparkWeb.Router.__routes__()` (filter `Phoenix.LiveView.Plug` +
   `layout == {Layouts, :studio}`; 26 routes today) is the completeness guard: any new
   studio-layout route must be in the curated mount table or the test fails. A curated
   fixture-driven table mounts each route (real seeded slugs — never "x"-substitution),
   parses nav DOM with LazyHTML (Floki is NOT a dep), and asserts per user: (a) identical
   entry id/label set + order across routes (NOT identical hrefs — scope_prefix legally
   varies them), (b) exactly one active entry, (c) active entry matches the route.
   Documented skip-list ONLY for env-gated tmux/chat (their tabs and mounts share the same
   predicates). Red-before-green: the red run against pre-fix main is recorded as task
   evidence; the test PR merges AFTER the fixes (guard+fix co-merge reds the fail-before
   gate — keep them decoupled). Why: distrust vacuous green; this test is the permanent
   regression fence.
6. **`active_when` binary contract: boundary match, not bare prefix.** A binary
   `active_when` matches iff `current_path == prefix` or starts with `prefix <> "/"` (also
   tolerate `?`). Preserves chat's `/studio/chat/:session_id` deep-link highlighting while
   killing the `/studio/media` vs `/studio/media-library` over-match. Why: sound semantics
   for the one contract plugins will program against.
7. **Visibility rules documented once**, in `docs/cards/studio.md` (the routed Studio
   card): the nav model location + canonical marker, the two gating axes and their inputs,
   the current_path/active-state contract, `nav_section`'s demoted role, and the named
   exceptions (swatch, public readers, tickets inbox). Why: one owner per fact-topic; the
   next agent must not rediscover this by archaeology.

## Roadmap

Wave 1 (this wave — S2/S3/S4 parallel in worktrees, S1 merges last, S5 anytime after S3/S4 decided):
- S2 `snav-w1-current-path-hook` — StudioChrome :handle_params hook owns current_path; delete per-LV hand-sets. (medium)
- S3 `snav-w1-nav-model-dedup` — delete dead Studio.Nav fork + phantom test; canonical marker; docstring fix; active_when boundary match. (medium)
- S4 `snav-w1-gating-determinism` — nil-workspace enablement fail-to-defaults; LiveAuth fetch_api_token on plugin_public sessions. (medium)
- S1 `snav-w1-parity-sweep` — route-sweep nav parity test (reflection guard + curated mount table + LazyHTML assertions); red evidence vs pre-fix main; merges after S2-S4. (large)
- S5 `snav-w1-docs-visibility-rules` — docs/cards/studio.md nav-shell section + sibling-epic note for tickets inbox. (small)

Wave 2 candidates — TRIAGED 2026-09-10 (`spd-b5-navshell-wave2-triage`), against
origin/main `151022500`. This list is CLOSED: every row below has a verdict and
an owner or an obsolescence proof, so it must not be mined for new work again.
The nav-shell epic `bp-studio-nav-shell` is lifecycle **done**, so the two
still-real rows are parented under `studio-space-priority-desk` (the open Studio
mission that can actually complete them), not under a sealed epic.

- **Tickets inbox** — DONE, `task-d6489fba128b61b8`. Chosen path: the existing
  plugin-owned `InboxLive` under the `plugin_admin` / `scoped_plugin_admin`
  StudioChrome sessions; no controller-layout fork. Flat + scoped Tickets routes
  are `:plugin` mount rows in `nav_parity_sweep_test.exs`.
- **DatasetSwitcher `current_section` + api-tester action group derived from
  current_path → retire nav_section fully** — STILL REAL, filed as
  `task-0e9a71366667ef23`. `nav_section` no longer drives active-state
  (`nav.ex:374-376`) but still drives two chrome decisions:
  `layouts/studio.html.heex:54` feeds it to `DatasetSwitcher`, whose only use is
  the pure path-suffix map at `studio/dataset_switcher.ex:42-45`, and
  `layouts/studio.html.heex:77` gates the api-tester token/run-all group on
  `assigns[:nav_section] == :api_tester`. Six LiveViews still hand-assign it.
- **Latent flat↔scoped workspace-attribution UX (surface as disabled-state
  instead of vanish)** — STILL REAL, filed as `task-e34595f816cd4bd2`.
  `plugins/registry/resolver_chain.ex:140-148` still `Enum.filter`s disabled
  plugins out of every surfacing callback, and `normalize_top_menu_entry/1`
  (`resolver_chain.ex:358-366`) keeps no `:disabled` field, so `nav.ex:419-441`
  has nothing to render a disabled state from.
- **Extend parity sweep to plugin routes behind the `:plugin_routes` tag with
  enable-fixtures** — OBSOLETE: it shipped inside wave 1 itself, not wave 2.
  `snav-w1-parity-sweep` (#1909, 2026-07-09) added the
  `describe "nav parity on plugin routes (enabled per workspace)"` block with
  `@describetag :plugin_routes` and a `set_workspace_plugin_settings/2`
  enable-fixture setup — `test/barkpark_web/studio/nav_parity_sweep_test.exs:347-366`
  — plus the `:plugin` disposition rows and the global exclude in
  `test/test_helper.exs:55`. Nothing left to do.

## Wave log

(empty — reviewer appends per wave)
