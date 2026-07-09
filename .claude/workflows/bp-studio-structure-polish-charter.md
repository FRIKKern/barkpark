# Studio + Structure Polish — Epic Charter

Epic task: `studio-structure-polish` (published, priority 1). Every slice is a published bp child task.

## Vision

A fresh Barkpark workspace opens to a calm, honest desk. The MAIN tier holds what matters first — Papers, Sheets, Tasks (plus core content/taxonomy/settings) — top-level, themed, alive. Below it one collapsed **Plugins** node holds plugin-owned trees (Onix, Tickets, Lightning Storm, GitHub, Frt) — present only for plugins enabled in THIS workspace; most of those are OFF by default. Media lives in the top menu, not the tree, unless promoted by setting. At the bottom a **…Rest** folder with honest counts catches every doc type that found no home — the tree never lies about the database, it only organizes it. Admins flip installed plugins on/off per workspace, or promote one into MAIN, from /studio/settings. The SAME server tree (`GET /v1/structure/:dataset`) drives Studio and the Go TUI desk. Theme hits everywhere: off-theme Studio chrome is fixed through derive(theme) tokens, ratcheted by design/exemptions.json.

## Decisions

1. **Tiers are nested `:list` nodes; MAIN stays top-level (no wrapper).** Both consumers already recurse `:list` (pane_builder walk_path; Go fromDeskNode) so old TUI binaries render Plugins/…Rest with zero client change — a new node `type` would be DROPPED by the Go switch (structure.go:215 default→nil). Keeping MAIN flat at top level preserves existing deep-links/URLs. Tier assignment happens only where the tree is built (structure.ex) — never in a client.
2. **Two-layer enablement: boot whitelist = installed; `workspaces.settings["plugins"]` = surfaced.** The `:barkpark, :plugins` boot config keeps meaning installed/loaded (schemas/routes/workers are boot-scoped and stay registered — the fresh-install boot test's 8-schema assertion is untouched). A per-workspace jsonb map under `workspaces.settings["plugins"]` (exact `workspace_theme/1` accessor precedent; NOT the encrypted plugin_name-keyed `Plugins.Settings` secrets store, which is global and wrong-scoped) decides what a workspace surfaces.
3. **Defaults live in the plugin declaration.** Two new optional `Barkpark.Plugin` callbacks with `__using__` defaults: `default_enabled?/0` (default `true`) and `structure_placement/0` (default `:plugins`; values `:main | :plugins | :top_menu`). Declarations: bulldocs/sheets/tasks → `:main` + enabled; media → `:top_menu` + enabled (hidden in tree by default — its top-menu tab already exists as a host built-in, nav.ex:386); onixedit/tickets/pulse/frt/github → `:plugins` + `default_enabled?: false`. Studio hardcodes nothing.
4. **One resolution module, one interface contract** (parallel slices build against it verbatim):
   ```elixir
   # api/lib/barkpark/plugins/enablement.ex
   Barkpark.Plugins.Enablement.effective(workspace_id | nil) ::
     %{optional(plugin_name :: String.t()) => %{enabled: boolean(), placement: :main | :plugins | :top_menu}}
   # merges declaration defaults with workspaces.settings["plugins"] overrides
   #   (%{"<plugin>" => %{"enabled" => bool, "placement" => "main"|"plugins"|"top_menu"}});
   # nil workspace_id or any lookup failure → declaration defaults; unknown plugin → enabled:true, placement: :plugins
   # Tenancy.workspace_plugin_settings(workspace) / Tenancy.set_workspace_plugin_settings(workspace_id, map)
   #   mirror workspace_theme/set_workspace_theme (tenancy.ex:188/210), merging into settings jsonb.
   # Registry.collect_desk_items_attributed(baseline:, ctx:) ::
   #   %{host: [Node.t()], plugins: [{plugin_name, [Node.t()]}]}   # existing collect_desk_items stays
   ```
5. **Filtering scope: the three surfacing collectors only** — desk_items, top_menu_entries, doc_actions skip plugins whose effective enablement is false (filter in resolver_chain where ctx carries a workspace; nav.ex + doc_actions.ex get workspace_id threaded into ctx). Explicitly NOT filtered: before/after_save lifecycle hooks (hooks.ex mirror — data-integrity gates always run for installed plugins), content_renderer (public reader pages keep rendering), routes, Oban workers, and `/v1/capabilities`/CLI (generated globally — accepted, documented degradation). Enablement resolution never runs inside the Registry GenServer registration path (no workspace in ctx → unfiltered, no Repo read → no deadlock).
6. **…Rest is computed from a tree-mirroring type census, not the stock analytics scope.** New `Analytics.type_census(dataset, opts)` — same `group_by(:type)` counts as `document_stats` (selects only type + counts; leaks no content) but scoped to MIRROR `Structure.build`'s schema scope: include nil-workspace globals, do NOT narrow by project (the stock `document_stats` scope would misreport). Rest = census types minus the type_names claimed by placed nodes (recursive walk, deduped). Counts = total docs (drafts included — honest). Rest renders only when non-empty. Orphaned types (schema force-deleted) appear here — today they are silently invisible; that is the truth-bug this fixes.
7. **Host-group asymmetry is resolved by a placement map in structure.ex.** content/papers/sheets/taxonomy/settings groups → MAIN. `build_books_group` follows onixedit's effective enablement+placement (deduped with onix's own desk items). `build_media_group` follows the media plugin's placement (`:top_menu` = out of the tree; workspace override to `"main"` restores it). Plugin desk items place per attributed plugin. Promotion = the placement override, uniform for every plugin.
8. **Theme sweep goes through the Part E ratchet.** Real Studio-chrome offenders are layouts/root.html.heex (219 literals) and layouts/bulldocs.html.heex (137) — the LiveView modules are already tokenized. Every tokenization lowers the design/exemptions.json baseline in the same diff; genuinely-exempt literals (mail-skin traffic lights, TUI-preview surface) stay and are justified in the ledger note. Paper-editor CSS (177+167+107 literals) is NOT in the ledger — onboarding it is a later slice, not silent scope creep.
9. **Styleguide matrix autofit is a same-origin `contentDocument.scrollHeight` fit, NOT postMessage.** The bulldocs.html.heex:1024-1037 `fit()` prior art (load handler + 400/1500ms re-fits + resize listener, `Math.max(320, …)`) copies directly because the swatch iframe is same-origin/admin-gated. Do not add a postMessage sender to SwatchLive.
10. **Settings UI joins SettingsLive, reframed.** /studio/settings becomes "Workspace Settings": theme section (existing), new Plugins section (per-workspace enable/disable + placement promote, default badges), credential editing demoted to a sub-section. No new route or pane.

## Roadmap

Wave 1 (this wave — integration order as listed; S1/S3 build against the Decision-4 contract in parallel and rebase on S2 before merge):

1. **ssp-w1-plugin-enablement** (large, p0) — declaration callbacks + Enablement module + Tenancy accessors + collector filtering + ctx threading + per-plugin declarations. Merges FIRST.
2. **ssp-w1-tiered-tree-rest** (large, p0) — tiered desk tree (MAIN top-level / Plugins node / …Rest with counts) + type_census + host-group placement + promotion honoring + TUI compat proof. Depends on S2's module.
3. **ssp-w1-settings-plugins-ui** (medium, p1) — Workspace Settings reframe + plugin toggle/promote UI. Depends on S2's accessors.
4. **ssp-w1-theme-root-sweep** (medium, p1) — root.html.heex tokenization, ledger ratchet down. Independent.
5. **ssp-w1-styleguide-autofit** (small, p2) — styleguide 340px iframe autofit + bulldocs.html.heex tokenization ratchet. Independent (exemptions.json touches a different entry than #4; rebase if needed).

Wave 2+ (filed when wave 1 lands):
- Paper-editor CSS ledger onboarding + tokenization (add exemptions entries FIRST, then ratchet).
- Deep-link courtesy redirects for plugin items that moved under the Plugins node (?desk paths).
- Oban job-time enablement guard for per-workspace-off plugins (pulse/github workers), if wanted.
- Boot-test extension: per-workspace-disable axis asserted alongside the global kill switch.
- Studio "bad design mistakes" polish round 2 (visual sweep once tiering settles the sidebar).
- docs/cards/studio.md + plugins card refresh for the new tiering + enablement contract.

## Wave log

### Wave 2 (2026-07-09) — reviewer log

**Landed (review-fixed, gates green, UNMERGED — lead integrates slice 1 first, then slice 2):**

- **ssp-w2-owned-types-settings** → `loop-epic/harvested-plugin-schema-ownership-kills--0-r`. `owned_schema_types/0` (optional callback, try/rescue→[] `__using__` default; Frt overrides via compile-time `schema_names/0`) feeds ONE harvested `plugin => [types]` map per desk build — both structure.ex hardcodes deleted (`plugin_owned_types/1` media/onixedit list, the `[book, mediaAsset, mediaCollection]` + `frt_schema_names` Settings rejects). Settings catch-all now rejects by OWNERSHIP, not enablement: the ticket Settings-masquerade is dead (falls to …Rest with honest count), sheet no longer double-lists, host singletons (siteSettings/navigation/colors) stay. structure.ex names zero plugin modules. Reviewer fix (one commit): the two new Settings-leak refutes were wrapped in `if settings do` — silently vacuous if the Settings group ever vanished; now assert the node exists. Gate 22/22 green; format clean.
- **ssp-w2-studio-honest-desk** → `loop-epic/studio-desk-finally-reflects-enablement--1-r` (no code fixes needed — clean build). panes[0] now renders the GATED tree, so the flagship Studio sidebar finally tells the enablement truth (disabled plugins absent, top-menu Media out of MAIN). Resolution walks gated-first via new `resolve/4`: a stale pre-tiering deep link (`/studio/:ds/book/:id`) is normalized through `find_type_node` and reveals via the drilled Plugins/…Rest column, URL unchanged; a type absent from the gated display entirely falls back to the ungated `gating: :none` tree — the #1851 never-unreachable guarantee holds. Reserved `graph`/`open` heads bypass both. Gate 30/30; cross-slice merged sweep (both branches together): studio + live/studio + structure + plugins = 2806 tests, 0 failures.

**Stalled (correctly):**

- **ssp-w2-visual-addendum** refused to shoot — prerequisites unmerged, guerrilla still serves the wave-1 desk (no display gating, ticket leak live); pixels would lie. No mutations, no vizcheck workspace, claim held at epoch 1. Stall status stamped into the task description. Re-run AFTER both merges + confirmed guerrilla redeploy.

**Ledger notes:** slice-2's builder believed criteria stamping was broken — actual failure mode: `bp doc patch` writes to a DRAFT; the published ledger (which gates/boards read) only changes after `bp doc publish`. Reviewer stamped criteria 0–5 with evidence and published (lifecycle in_progress, claim intact); criterion 5 is met-with-caveat (full suite 8919 tests, 1 pre-existing pulse_metrics sandbox flake, passes in isolation). Both wave tasks' work digests changed under claim → the eventual `task close` may 409 `doc_changed_since_claim`; re-read then close (documented fence). Wave-1 tasks untouched (all `done`).

**Charter gap:** wave-2 briefs cite "charter Decisions 11/12/13/14" but this file stops at Decision 10 — the Decide phase never wrote them here. For the record: 11 = harvested `owned_schema_types/0` ownership map; 12 = Settings catch-all rejects by ownership, not enablement; 13 = the wave-1 tree does not display-gate enablement (fixed this wave in PaneBuilder); 14 = live-guerrilla visual evidence Paper. Future Decide phases must append decisions to this file.

**Next wave:** (1) merge slice 1 then slice 2 (api/** — wait for the Elixir Test gate; PR bodies carry `Task: <id>` lines); lead closes each task's merge-gated criterion on merge. (2) IMMEDIATELY re-run ssp-w2-visual-addendum against redeployed guerrilla — it is the epic's only remaining owed proof and now unblocked. (3) Then pick from the wave-2+ queue: deep-link courtesy redirects for demoted types, paper-editor CSS ledger onboarding, docs/cards/studio.md + plugins card refresh.

## Wave 1 log (2026-07-09, lead-landed)

Five slices merged S1→S5: #1846 per-workspace enablement (Plugin callbacks default_enabled?/structure_placement; onixedit/tickets/pulse/frt/github OFF by default; workspaces.settings["plugins"] via the theme seam; only the 3 surfacing collectors filter), #1847 tiered desk (MAIN flat top-level in charter order, Plugins node per enabled plugin, …Rest from the tree-mirroring census — orphaned/public ad-hoc types now SURFACE; TUI-safe existing-node-types-only), #1851 Workspace Settings UI (toggles + placement promotion, honest states, forged-id guards), #1861 theme sweep (root.html.heex 219→165 via 3 HSL ink triplets; selection tints follow the workspace theme), #1862 styleguide iframe auto-fit (SgFit hook, same-origin scrollHeight, mail-frame prior art; bulldocs ledger 137→102).

LEAD FINDINGS while landing: (1) REAL regression caught+fixed on S3 — PaneBuilder resolved nav paths against the GATED tree, which would have broken top-menu Media panes and disabled plugins' deep links; fix = Structure.build(gating: :none) for RESOLUTION (display stays tiered; :top_menu placements fold into MAIN for findability). (2) Three more old-world tests beyond the review's five: pulse desk-link (rewritten both-directions), resolver_outputs Bokbasen/desk (rewritten to enablement contract; the Plugins tier assertion moved to structure_test where the tenancy dance is native), scoped-mount :first-of-type click (tiering reorders the pane; click the first select node by id).

Wave 2 queue (from the review): Settings catch-all leak (disabled plugin's PRIVATE schema surfaces as a Settings singleton instead of …Rest), generalize top_menu_claimed_types (structure.ex hardcodes media/onixedit type lists), deep-link redirects for demoted types, paper-editor CSS ledger onboarding, live-guerrilla screenshot addendum (owed — no browser pixels captured in wave 1).
