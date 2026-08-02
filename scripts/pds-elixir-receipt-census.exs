#!/usr/bin/env elixir
# pds-elixir-receipt-census.exs — the FIRST census of the Elixir success surface.
#
# THE LAW (PDS wave 22): no Barkpark verb may report success on an exit code alone.
# THE OWNING DOC:        docs/decisions/success-claim-census.md (canonical-for: success-claim-census)
#
# WHAT THIS IS. A build-free AST census of every `ok: true` / `"ok" => true` success
# claim under api/lib. It runs under plain `elixir` with NO mix project and NO compile
# (`Code.string_to_quoted/2` only), so it never boots the app — deliberately, because
# `mix phx.server` OOMs on this host. `scripts/pds-*` is in NEITHER Elixir path set
# (scripts/elixir-path-escape-check.sh), so this file costs no Elixir gate minute.
#
# WHAT THIS IS NOT. It is NOT a gate. It ships no floor over the population, because
# the ruling stands (PDS-D454): Elixir stays honest-and-unguarded until the write-routed
# sites are bucketed. What it DOES fail on is its own integrity — a truncated corpus, a
# lens that loses occurrences, a partition that does not add up, or a delegate chain it
# can no longer follow. Those exit non-zero. A number that merely drifted prints DRIFT.
#
# THE LENS, STATED (PDS-D448a). This census is AST-based and depends on NO regex engine
# and, specifically, on NO word-boundary support: on this host Apple git 2.39.5's POSIX
# ERE has no `\b`, so `git grep -E '\bok: true'` returns 0 matches and exits 1 SILENTLY
# while `git grep -P`, BSD `grep -rE` and `rg` all return 97 on the identical corpus.
# Every textual count below is plain substring matching (`:binary.matches/2`).
#
# MEASURING ENGINE (printed again at runtime from the live VM):
#   Elixir 1.19.5 · Erlang/OTP 28 (erts 16.3.1) · darwin arm64 · git 2.39.5 (Apple)
#
# USAGE — ARGV IS STRICT. An argument this list does not name exits 2 without measuring
# anything, because a census that silently swallows a flag reports a number for a lens
# nobody asked for (PDS-D493: `--selftest` used to run the ordinary census and exit 0).
#   elixir scripts/pds-elixir-receipt-census.exs            # full corpus census
#   elixir scripts/pds-elixir-receipt-census.exs --sites    # + every emitted site, one per line
#   elixir scripts/pds-elixir-receipt-census.exs --files-from FILE   # corpus-refusal rehearsal
#   elixir scripts/pds-elixir-receipt-census.exs --keys     # STDOUT: the register key, TSV, one line per emitted site
#   elixir scripts/pds-elixir-receipt-census.exs --selftest # mutate this file over a synthetic corpus; prove the arms can go RED
#
# EXIT: 0 all integrity checks pass · 1 an integrity check failed · 2 corpus refused OR
#       an unknown argument. NEVER PIPE THIS SCRIPT WHEN READING ITS EXIT CODE — `cmd |
#       tail` reports tail's status, which is how the exit-2 refusal was once logged RC 0.

defmodule PDS.Census do
  # ---------------------------------------------------------------- constants

  # Recorded by PDS-D448 (wave 33 survey). Printed as DRIFT lines, never enforced —
  # a number-shaped pin is the defect this epic keeps filing, not the guard.
  @recorded %{
    textual: 103,
    ast: 95,
    phantom: 8,
    consumer: 4,
    emitted: 91,
    write: 64,
    read: 17,
    unrouted: 10
  }

  # Route-bearing sentinels. A carriers-only corpus (the files that literally hold an
  # `ok: true`) parses fine and reports write=0 with no error — PDS-D449a. These files
  # carry no `ok: true` themselves, so their absence PROVES the corpus is truncated.
  #
  # THE CARRIER COUNT IS DERIVED, NEVER TYPED (PDS wave 35). This comment said "the 27
  # files"; the measured value is 26 files carrying an AST-literal pair and 28 carrying a
  # textual occurrence — false under BOTH readings, and a hardcoded population inside the
  # instrument that measures the population is the exact defect this epic keeps filing.
  # report_lens/5 now prints both, live.
  @sentinels [
    "api/lib/barkpark/tasks.ex",
    "api/lib/barkpark/tasks/close.ex",
    "api/lib/barkpark/repo.ex"
  ]
  @corpus_floor 600

  # `transaction` IS NOT A WRITE VERB (PDS wave 34). Repo.transaction/1 OPENS a
  # transaction; it moves no row. The universal Barkpark shape is
  #   Repo.transaction(fn -> Repo.query!("SELECT pg_advisory_xact_lock(...)")
  #                          Repo.get(Document, id)   # the PRE-write load
  # so the opener scored WRITE at line N while the lock scored READ at N+1 and the
  # pre-write load at N+3 — and post_read?/2 is pure line arithmetic. That single
  # token manufactured 17 of 17 POST-READs on wave 33's shipped lens. Every verb
  # left in this list moves a row.
  @write_verbs ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update!)a
  @read_verbs ~w(all one one! get get! get_by get_by! aggregate exists? preload
                 stream reload reload!)a
  @repo_mods [:Repo, :Multi]

  # DEPTH 6 IS THE CLOSURE OF THE ROUTE RELATION, NOT A TASTE. Sweeping the budget,
  # write/read/unrouted reads 23/11/57 · 29/23/39 · 39/15/37 · 43/23/25 · 53/15/23 ·
  # 54/14/23 for depths 1..6 and then 54/14/23 IDENTICALLY at 7,8,9,10,12,15,20,30 —
  # the bfs seen-set makes the reachable set a finite closure and the route set is
  # monotone in the budget. The SHAPE relation does NOT close until 12 (POST-READ 6
  # here, 15/21/23/23/24 at 7/8/9/10/12), and every unit past 6 buys POST-READ
  # inflation via cross-row certifiers, so above 6 this knob is a COMPLIANCE DIAL,
  # not a lens. Printed at runtime by report_depth_sweep/2 so it cannot be read as
  # taste. (The brief's 42/14/35 was the A+B+C lens WITHOUT the clause-collapse fix.)
  @max_depth 6
  @sweep [1, 2, 3, 4, 5, 6]

  # DEPTHS PAST THE CENSUS DEPTH, MEASURED RATHER THAN ASSERTED. The claim "the route
  # closes at 6 but the shape relation does not" is only worth printing if the run can
  # still see it fail, so the sweep keeps going past @max_depth and the prose reads its
  # sentences off these rows. 12 is where wave 34 found the shape relation flat.
  @beyond [7, 8, 9, 10, 12]

  @shapes ~w(POST-READ CAS-CONFIRMED-ECHO PURE-ECHO CATCH-ALL-TO-SUCCESS WRONG-ROW
             DISCARDED-POST-READ)

  # ------------------------------------------------------- routed population (L4)
  #
  # THE POPULATION A COMPLETENESS ARM IS ABOUT (PDS wave 38). REGISTER-COMPLETE proves
  # "every emitted site carries a row, both directions" over a population THE LENS
  # DEFINES BY A STRING — the sites that literally spell `ok: true`. SCIM's three write
  # routes emit success with NO `ok` KEY AT ALL (`send_resp(conn, 204, "")` at
  # scim_users_controller.ex, behind `pipeline :scim` → RequireScimToken, a real
  # non-admin IdP write path), so they are STRUCTURALLY outside that claim and a green
  # REGISTER-COMPLETE says exactly nothing about them. A green gate over a population the
  # lens defines is a vacuous green wearing the LENS instead of the CORPUS.
  #
  # SO THE OUTSIDE POPULATION IS DERIVED FROM THE ROUTER — the one structure that already
  # enumerates every reachable write — and EVERY MEMBER CARRIES A DISPOSITION.
  #
  # VOCABULARY: ROUTED-WRITE / DISPOSED (PDS-D552). The census already owns
  # write-routed / read-routed / unrouted in the DRIFT rows, and those mean REPO-VERB
  # REACHABILITY over emitted sites. Two different populations behind one word inside one
  # instrument makes both unreadable, and the drift arms compare on those names.
  #
  # THE KEY IS THE QUAD {method, path, module, action}, AND IT IS MUTATION-PROVEN
  # (PDS-D539). Planting a synthetic write route onto an ALREADY-DISPOSED pair moves a
  # {module, action} key from N to N — the arrival is STRUCTURALLY INVISIBLE, and a new
  # route to an existing controller action is the single most likely real-world change.
  # The quad moves N to N+1 and the arm fires. The selftest fixture carries TWO routes to
  # ONE pair for exactly this reason, so the key is asked to discriminate on every run.
  #
  # BUILD-FREE, LIKE EVERYTHING ELSE HERE (PDS-D540). Derived from the AST of router.ex
  # unioned with the plugin route specs — never from a compiled Phoenix route table. This
  # script boots no app (7-14 s against ~7 min on a cold _build), and Phoenix 1.8.9's
  # route map carries no `pipe_through` key anyway. Two shapes force the AST regardless:
  # several route calls in router.ex are MULTILINE, so a single-line grep undercounts them
  # silently, and `Barkpark.Plugins.OnixEdit.register_routes/1` DELEGATES to
  # `OnixEdit.Routes.all/0`, so a literal-tuple grep over plugins/*.ex returns ZERO routes
  # for onixedit. Both are resolved below.
  @router_path "api/lib/barkpark_web/router.ex"
  @plugin_dir "api/lib/barkpark/plugins/"
  @routed_write_methods ~w(post put patch delete)a
  @routed_live_method :live

  # ROUTE-GENERATING MACROS. `plugin_routes/1` this lens RESOLVES (it reads the plugin
  # specs and mounts them); everything else it can only NAME. A macro whose expansion
  # lives in a dependency is a blind shape by construction for a script that never
  # compiles, and a lens that does not print its own blind shapes is propaganda.
  @routed_macros [:plugin_routes, :live_dashboard, :forward, :resources]
  @routed_resolved_macro :plugin_routes

  # DISPOSITION CLASSES — written prose, dated, one per class rather than one per row.
  # A class is what a human decided about a SHAPE; the rows below pin WHICH members that
  # decision covers, and the quad is what makes an arrival visible.
  @routed_exclusion_classes %{
    liveview_handle_event:
      "2026-08-02 (PDS wave 38): a LiveView route names {Module, :action-or-nil} and its writes live in handle_event/3, so there is no {Controller, action} pair for the receipt register to key on. EXCLUDED because this lens structurally cannot judge it — printed with its count so the exclusion is a fact and not a silence.",
    status_only_receipt:
      "2026-08-02 (PDS wave 38): the routed action reaches no `ok: true` / `\"ok\" => true` receipt this lens can see and carries no roster anchor — it claims success by STATUS alone (`send_resp(conn, 2xx, \"\")`, a bare `json/2`, a redirect). THIS IS THE POPULATION HOLE wave 38 named: SCIM's three IdP write routes land here. The register's completeness claim never covered these; now they are COUNTED instead of absent.",
    action_not_in_corpus:
      "2026-08-02 (PDS wave 38): the routed {module, action} resolves to no def under api/lib — the module is generated, vendored, or lives outside the corpus glob, so no span exists to read a receipt out of.",
    selftest_fixture:
      "2026-08-02 (PDS wave 38): a synthetic member that exists ONLY in the --selftest corpus (module Barkpark.Filler.M1, written by write_corpus!/2 and absent from the real tree). Carried on purpose: without a committed row the row->member direction of ROUTED-POPULATION-COMPLETE has nothing to go red on, and the TWO rows share one {module, action} pair so the quad key is asked to discriminate on every selftest run."
  }

  # THE DISPOSITION TABLE. `{method, path, module, action, class}` — committed data, the
  # same shape as @register and @roster, generated from the live derivation and then read
  # back. Rows whose module this corpus does not carry are OUT OF SCOPE, never a red: a
  # disposition naming a module nobody can open judges nothing either way.
  @routed_excluded [
    {:post, "/v1/selftest-fixture-close", "Barkpark.Filler.M1", :noop, :selftest_fixture},
    {:post, "/v1/selftest-departure-anchor", "Barkpark.Filler.M1", :noop, :selftest_fixture},
    {:delete, "/api/documents/:type/:id", "BarkparkWeb.LegacyController", :delete, :status_only_receipt},
    {:delete, "/api/workspaces/:workspace_slug", "BarkparkWeb.WorkspaceController", :delete, :status_only_receipt},
    {:delete, "/media/:id", "BarkparkWeb.MediaController", :delete, :status_only_receipt},
    {:delete, "/v1/access/:id", "BarkparkWeb.AccessController", :revoke, :status_only_receipt},
    {:delete, "/v1/auth/app-tokens", "BarkparkWeb.AppTokenController", :delete, :status_only_receipt},
    {:delete, "/v1/auth/app-tokens/current", "BarkparkWeb.AppTokenController", :delete_current, :status_only_receipt},
    {:delete, "/v1/fleet/support-tokens/:token_id", "BarkparkWeb.FleetSupportTokenController", :delete, :status_only_receipt},
    {:delete, "/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :delete, :status_only_receipt},
    {:delete, "/v1/media/:dataset/collections/:id/members/:asset_id", "BarkparkWeb.V1.MediaCollectionsController", :remove_member, :status_only_receipt},
    {:delete, "/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :revoke_share, :status_only_receipt},
    {:delete, "/v1/plugins/tickets/keys/:id", "BarkparkWeb.TicketKeysController", :delete, :status_only_receipt},
    {:delete, "/v1/schemas/:dataset/:name", "BarkparkWeb.SchemaController", :delete, :status_only_receipt},
    {:delete, "/v1/shares", "BarkparkWeb.ShareController", :delete, :status_only_receipt},
    {:delete, "/v1/shares/links/:id", "BarkparkWeb.ShareLinkController", :revoke, :status_only_receipt},
    {:delete, "/v1/shares/tokens/:token_id", "BarkparkWeb.ShareController", :revoke_token, :status_only_receipt},
    {:delete, "/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/members/:asset_id", "BarkparkWeb.V1.MediaCollectionsController", :remove_member, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :revoke_share, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id", "BarkparkWeb.TicketKeysController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/schemas/:dataset/:name", "BarkparkWeb.SchemaController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/v1/chat-hosts/:id", "BarkparkWeb.ChatHostController", :revoke, :status_only_receipt},
    {:live, "/admin/fleet", "Barkpark.Plugins.Tasks.Web.FleetLive", :index, :liveview_handle_event},
    {:live, "/admin/github", "Barkpark.Plugins.Github.Web.OpsLive", :index, :liveview_handle_event},
    {:live, "/admin/onixedit/bokbasen", "Barkpark.Plugins.OnixEdit.Web.BokbasenLive", :index, :liveview_handle_event},
    {:live, "/admin/onixedit/staleness", "Barkpark.Plugins.OnixEdit.Web.StalenessLive", :index, :liveview_handle_event},
    {:live, "/admin/projects", "Barkpark.Plugins.Tasks.Web.BoardLive", :index, :liveview_handle_event},
    {:live, "/admin/pulse", "Barkpark.Plugins.Pulse.Web.DashboardLive", :index, :liveview_handle_event},
    {:live, "/d/:dataset/papers/:slug", "BarkparkWeb.BulldocsLive", :index, :liveview_handle_event},
    {:live, "/finder", "BarkparkWeb.FinderLive", :index, :liveview_handle_event},
    {:live, "/papers/:slug", "BarkparkWeb.BulldocsLive", :index, :liveview_handle_event},
    {:live, "/quiz/host/:pin", "BarkparkWeb.QuizHostLive", :index, :liveview_handle_event},
    {:live, "/quiz/play/:pin", "BarkparkWeb.QuizPlayLive", :index, :liveview_handle_event},
    {:live, "/sheets/:slug", "BarkparkWeb.SheetsReaderLive", :index, :liveview_handle_event},
    {:live, "/studio/chat", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/studio/chat/:session_id", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/studio/onixedit/ping", "Barkpark.Plugins.OnixEdit.PingLive", :index, :liveview_handle_event},
    {:live, "/studio/org-admin", "BarkparkWeb.Studio.OrgAdminLive", nil, :liveview_handle_event},
    {:live, "/studio/styleguide", "BarkparkWeb.Studio.StyleguideLive", nil, :liveview_handle_event},
    {:live, "/studio/styleguide/swatch", "BarkparkWeb.Studio.SwatchLive", nil, :liveview_handle_event},
    {:live, "/studio/tickets", "Barkpark.Plugins.Tickets.InboxLive", :index, :liveview_handle_event},
    {:live, "/studio/tmux", "BarkparkWeb.Studio.TmuxLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/fleet", "Barkpark.Plugins.Tasks.Web.FleetLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/github", "Barkpark.Plugins.Github.Web.OpsLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/onixedit/bokbasen", "Barkpark.Plugins.OnixEdit.Web.BokbasenLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/onixedit/staleness", "Barkpark.Plugins.OnixEdit.Web.StalenessLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/projects", "Barkpark.Plugins.Tasks.Web.BoardLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/pulse", "Barkpark.Plugins.Pulse.Web.DashboardLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio", "BarkparkWeb.Studio.StudioLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/*path", "BarkparkWeb.Studio.StudioLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/_plugins", "BarkparkWeb.Admin.PluginsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/_plugins/:plugin/settings", "BarkparkWeb.Admin.PluginSettingsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/api-tester", "BarkparkWeb.Studio.ApiTesterLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/media", "BarkparkWeb.Studio.MediaLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/papers/:slug", "BarkparkWeb.BulldocsLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/chat", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/chat-hosts", "BarkparkWeb.Studio.ChatHostsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/chat/:session_id", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/connectors", "BarkparkWeb.Studio.ConnectorsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/onixedit/ping", "Barkpark.Plugins.OnixEdit.PingLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/settings", "BarkparkWeb.Studio.SettingsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/tickets", "Barkpark.Plugins.Tickets.InboxLive", :index, :liveview_handle_event},
    {:patch, "/scim/v2/Groups/:id", "BarkparkWeb.ScimGroupsController", :update, :status_only_receipt},
    {:patch, "/scim/v2/Users/:id", "BarkparkWeb.ScimUsersController", :update, :status_only_receipt},
    {:patch, "/v1/chat/sessions/:id", "BarkparkWeb.ChatController", :update, :status_only_receipt},
    {:patch, "/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :update, :status_only_receipt},
    {:patch, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :update, :status_only_receipt},
    {:post, "/api/documents/:type", "BarkparkWeb.LegacyController", :create, :status_only_receipt},
    {:post, "/api/playground", "BarkparkWeb.PlaygroundController", :provision, :status_only_receipt},
    {:post, "/api/workspaces", "BarkparkWeb.WorkspaceController", :create, :status_only_receipt},
    {:post, "/api/workspaces/:workspace_slug/import", "BarkparkWeb.WorkspaceController", :import, :status_only_receipt},
    {:post, "/api/workspaces/:workspace_slug/projects", "BarkparkWeb.WorkspaceController", :create_project, :status_only_receipt},
    {:post, "/auth/reset/:token", "BarkparkWeb.SessionController", :reset_submit, :status_only_receipt},
    {:post, "/login", "BarkparkWeb.SessionController", :create, :status_only_receipt},
    {:post, "/login/account", "BarkparkWeb.SessionController", :account, :status_only_receipt},
    {:post, "/login/magic", "BarkparkWeb.SessionController", :magic_request, :status_only_receipt},
    {:post, "/login/mfa", "BarkparkWeb.SessionController", :mfa, :status_only_receipt},
    {:post, "/login/reset", "BarkparkWeb.SessionController", :reset_request, :status_only_receipt},
    {:post, "/media/upload", "BarkparkWeb.MediaController", :upload, :status_only_receipt},
    {:post, "/scim/v2/Groups", "BarkparkWeb.ScimGroupsController", :create, :status_only_receipt},
    {:post, "/scim/v2/Users", "BarkparkWeb.ScimUsersController", :create, :status_only_receipt},
    {:post, "/v1/access", "BarkparkWeb.AccessController", :mint, :status_only_receipt},
    {:post, "/v1/access/claim", "BarkparkWeb.AccessController", :claim, :status_only_receipt},
    {:post, "/v1/admin/rollback", "BarkparkWeb.SelfUpdateController", :rollback, :status_only_receipt},
    {:post, "/v1/admin/site-deploy", "BarkparkWeb.SiteDeployController", :trigger, :status_only_receipt},
    {:post, "/v1/auth/app-tokens", "BarkparkWeb.AppTokenController", :create, :status_only_receipt},
    {:post, "/v1/auth/login", "BarkparkWeb.AuthController", :login, :status_only_receipt},
    {:post, "/v1/auth/login-tickets", "BarkparkWeb.LoginTicketController", :create, :status_only_receipt},
    {:post, "/v1/auth/magic-login", "BarkparkWeb.AuthController", :magic_login, :status_only_receipt},
    {:post, "/v1/auth/mfa/enroll", "BarkparkWeb.AuthController", :mfa_enroll, :status_only_receipt},
    {:post, "/v1/auth/register", "BarkparkWeb.AuthController", :register, :status_only_receipt},
    {:post, "/v1/auth/saml/:org_slug/slo", "BarkparkWeb.SamlController", :slo, :status_only_receipt},
    {:post, "/v1/auth/sso/route", "BarkparkWeb.SsoRoutingController", :route, :status_only_receipt},
    {:post, "/v1/auth/tokens", "BarkparkWeb.AuthController", :create_token, :status_only_receipt},
    {:post, "/v1/auth/webauthn/login", "BarkparkWeb.WebauthnController", :login, :status_only_receipt},
    {:post, "/v1/auth/webauthn/login/challenge", "BarkparkWeb.WebauthnController", :login_challenge, :status_only_receipt},
    {:post, "/v1/auth/webauthn/register/challenge", "BarkparkWeb.WebauthnController", :register_challenge, :status_only_receipt},
    {:post, "/v1/auth/webauthn/step-up/challenge", "BarkparkWeb.WebauthnController", :step_up_challenge, :status_only_receipt},
    {:post, "/v1/chat-host/enroll", "BarkparkWeb.ChatHostController", :enroll, :status_only_receipt},
    {:post, "/v1/chat-host/heartbeat", "BarkparkWeb.ChatHostController", :heartbeat, :status_only_receipt},
    {:post, "/v1/chat-host/rotate", "BarkparkWeb.ChatHostController", :rotate, :status_only_receipt},
    {:post, "/v1/chat/sessions", "BarkparkWeb.ChatController", :create, :status_only_receipt},
    {:post, "/v1/chat/sessions/:id/archive", "BarkparkWeb.ChatController", :archive, :status_only_receipt},
    {:post, "/v1/chat/sessions/:id/state", "BarkparkWeb.ChatHostController", :report_state, :status_only_receipt},
    {:post, "/v1/chat/sessions/:id/unarchive", "BarkparkWeb.ChatController", :unarchive, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/assignments", "BarkparkWeb.CycleFleetController", :create_assignment, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/assignments/:assignment_id/results", "BarkparkWeb.CycleFleetController", :create_result, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/open", "BarkparkWeb.CycleFleetController", :open, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/seal", "BarkparkWeb.CycleFleetController", :seal, :status_only_receipt},
    {:post, "/v1/data/mutate/:dataset", "BarkparkWeb.MutateController", :mutate, :status_only_receipt},
    {:post, "/v1/data/revision/:dataset/:id/restore", "BarkparkWeb.HistoryController", :restore, :status_only_receipt},
    {:post, "/v1/data/search/:dataset/synonyms", "BarkparkWeb.SearchController", :create_search_synonym, :status_only_receipt},
    {:post, "/v1/data/search/:dataset/synonyms/promote", "BarkparkWeb.SearchController", :promote_search_synonym, :status_only_receipt},
    {:post, "/v1/fleet/support-tokens", "BarkparkWeb.FleetSupportTokenController", :create, :status_only_receipt},
    {:post, "/v1/media/:dataset/:id/checkout", "BarkparkWeb.V1.MediaController", :checkout, :status_only_receipt},
    {:post, "/v1/media/:dataset/:id/undo-checkout", "BarkparkWeb.V1.MediaController", :undo_checkout, :status_only_receipt},
    {:post, "/v1/media/:dataset/collections/:id/members", "BarkparkWeb.V1.MediaCollectionsController", :add_member, :status_only_receipt},
    {:post, "/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :share, :status_only_receipt},
    {:post, "/v1/media/:dataset/processing/:id/callback", "BarkparkWeb.V1.MediaProcessingController", :callback, :status_only_receipt},
    {:post, "/v1/media/:dataset/search/synonyms", "BarkparkWeb.V1.MediaController", :create_search_synonym, :status_only_receipt},
    {:post, "/v1/media/:dataset/search/synonyms/promote", "BarkparkWeb.V1.MediaController", :promote_search_synonym, :status_only_receipt},
    {:post, "/v1/media/:dataset/upload", "BarkparkWeb.V1.MediaController", :upload, :status_only_receipt},
    {:post, "/v1/plugins/sheets/:slug/ops", "?", :apply_ops, :action_not_in_corpus},
    {:post, "/v1/plugins/sheets/import", "?", :create, :action_not_in_corpus},
    {:post, "/v1/plugins/tickets/keys", "BarkparkWeb.TicketKeysController", :create, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys/:id/pause", "BarkparkWeb.TicketKeysController", :pause, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys/:id/rotate", "BarkparkWeb.TicketKeysController", :rotate, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys/:id/unpause", "BarkparkWeb.TicketKeysController", :unpause, :status_only_receipt},
    {:post, "/v1/schemas/:dataset", "BarkparkWeb.SchemaController", :upsert, :status_only_receipt},
    {:post, "/v1/shares", "BarkparkWeb.ShareController", :create, :status_only_receipt},
    {:post, "/v1/shares/links", "BarkparkWeb.ShareLinkController", :mint, :status_only_receipt},
    {:post, "/v1/shares/tokens", "BarkparkWeb.ShareController", :mint_token, :status_only_receipt},
    {:post, "/v1/status/incidents", "BarkparkWeb.StatusController", :create_incident, :status_only_receipt},
    {:post, "/v1/status/incidents/:id/resolve", "BarkparkWeb.StatusController", :resolve_incident, :status_only_receipt},
    {:post, "/v1/tickets/:id/attachments", "BarkparkWeb.TicketsAttachmentsController", :create, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset", "BarkparkWeb.WebhookController", :create, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/deliveries/:event_id/replay", "BarkparkWeb.WebhookController", :replay, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/reenable", "BarkparkWeb.WebhookController", :reenable, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/rotate", "BarkparkWeb.WebhookController", :rotate, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/test-send", "BarkparkWeb.WebhookController", :test_send, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/chat/tokens", "BarkparkWeb.ChatTokenController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/assignments", "BarkparkWeb.CycleFleetController", :create_assignment, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/assignments/:assignment_id/results", "BarkparkWeb.CycleFleetController", :create_result, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/open", "BarkparkWeb.CycleFleetController", :open, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/promote", "BarkparkWeb.CycleFleetController", :promote, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/quarantine", "BarkparkWeb.CycleFleetController", :quarantine, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/activate", "BarkparkWeb.CycleFleetController", :activate_release_gate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/papers/:role/stage", "BarkparkWeb.CycleFleetController", :stage_release_paper, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/open", "BarkparkWeb.CycleFleetController", :admit_open_release_gate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/rollback", "BarkparkWeb.CycleFleetController", :rollback, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/seal", "BarkparkWeb.CycleFleetController", :seal, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset", "BarkparkWeb.MutateController", :mutate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/revision/:dataset/:id/restore", "BarkparkWeb.HistoryController", :restore, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/search/:dataset/synonyms", "BarkparkWeb.SearchController", :create_search_synonym, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id/checkout", "BarkparkWeb.V1.MediaController", :checkout, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id/undo-checkout", "BarkparkWeb.V1.MediaController", :undo_checkout, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/members", "BarkparkWeb.V1.MediaCollectionsController", :add_member, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :share, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/search/synonyms", "BarkparkWeb.V1.MediaController", :create_search_synonym, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/upload", "BarkparkWeb.V1.MediaController", :upload, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys", "BarkparkWeb.TicketKeysController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id/pause", "BarkparkWeb.TicketKeysController", :pause, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id/rotate", "BarkparkWeb.TicketKeysController", :rotate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id/unpause", "BarkparkWeb.TicketKeysController", :unpause, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/schemas/:dataset", "BarkparkWeb.SchemaController", :upsert, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/tokens", "BarkparkWeb.TokenController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset", "BarkparkWeb.WebhookController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/deliveries/:event_id/replay", "BarkparkWeb.WebhookController", :replay, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/reenable", "BarkparkWeb.WebhookController", :reenable, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/rotate", "BarkparkWeb.WebhookController", :rotate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/test-send", "BarkparkWeb.WebhookController", :test_send, :status_only_receipt},
    {:post, "/w/:workspace_slug/v1/chat-hosts/enrollments", "BarkparkWeb.ChatHostController", :create_enrollment, :status_only_receipt},
    {:put, "/api/workspaces/:workspace_slug/media/blob/*path", "BarkparkWeb.MediaController", :put_blob, :status_only_receipt},
    {:put, "/scim/v2/Groups/:id", "BarkparkWeb.ScimGroupsController", :replace, :status_only_receipt},
    {:put, "/scim/v2/Users/:id", "BarkparkWeb.ScimUsersController", :replace, :status_only_receipt},
    {:put, "/v1/data/search/:dataset/settings", "BarkparkWeb.SearchController", :update_search_settings, :status_only_receipt},
    {:put, "/v1/media/:dataset/search/settings", "BarkparkWeb.V1.MediaController", :update_search_settings, :status_only_receipt},
    {:put, "/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :update, :status_only_receipt},
    {:put, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :update, :status_only_receipt}
  ]

  # ------------------------------------------------------------- declared register
  #
  # COMMITTED DATA, NOT A SUPPRESSION SWITCH (PDS wave 35). A site lands here only with a
  # BASIS the reader can open — a line span in the source that says, in prose, that the
  # receipt deliberately does not track an outcome. The field value is `declared`, the
  # spelling already shipping in `internal/cli/hetzner_respost.go:197`
  # (`hzKeyConfirmation: "declared"` beside `hzKeyConfirmBasis`), because a confirmation
  # level that exists in one surface must not be re-invented with a new name in another.
  #
  # WHAT THE REGISTER IS FOR. Exactly one row suppresses anything today
  # (github_webhook_controller.ex:87, the one site the CATCH-ALL-TO-SUCCESS arm fires on
  # whose body NAMES its outcome). The other four are DOCUMENTATION: they record that a
  # human read the code and found the receipt honest, so the next lens that starts firing
  # on them meets a written basis instead of an argument.
  #
  # `route_claim` IS ORTHOGONAL TO `class`, DELIBERATELY. route_tag/1 and evidence/3 read
  # `site.write?` / `site.depth` and NEVER the shape, so no value in the shape vocabulary
  # can retract a false route bracket. A site whose route bracket is wrong says so here.
  @declared [
    %{
      key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_reset/2", "37852989", "17468236"},
      basis_spans: [{393, 393}],
      basis_token: "never reveal whether the email is registered",
      class: "NO-OP-ACK",
      confirmation: "declared",
      basis: "inline comment :393 — \"Always 200 — never reveal whether the email is registered.\"",
      why:
        "anti-enumeration. Route WRITE d1 — and the receipt asserts nothing ABOUT that write, " <>
          "which is precisely why it is honest. (It is NOT a \"no write\" site: request_reset " <>
          "does write a reset token when the address resolves.)"
    },
    %{
      key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_magic_link/2", "15394828", "17468236"},
      basis_spans: [{402, 407}],
      basis_token: "anti-enumeration",
      class: "NO-OP-ACK",
      confirmation: "declared",
      basis:
        "@doc :402-407, the anti-enumeration sentence at :403-406 (the token `anti-enumeration` on :405)",
      why:
        "anti-enumeration, request_magic_link/2. THE SPAN IS THE FIX: charter PDS-D465 cites " <>
          ":406-410, which is the sentence's tail fragment, the closing triple-quote and the def " <>
          "line — no anti-enumeration text in it; PDS-D453b cites :410-417, which is pure code. " <>
          "Both are phantom bases. This row SUPPRESSES NOTHING — the site's ok:true sits at :417, " <>
          "after the case closes at :415, so no clause contains it and no shipping configuration " <>
          "of the arm can fire on it. It is registered as documentation of a control the lens " <>
          "wrongly accused for two waves."
    },
    %{
      key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "17468236"},
      basis_spans: [{74, 78}],
      basis_token: "always answers 2xx unless intake genuinely",
      class: "NO-OP-ACK",
      confirmation: "declared",
      basis: "@doc :74-78 — \"always answers 2xx unless intake genuinely fails\"",
      why:
        "the `\"ping\"` clause head is a literal match, not a failure-discarding head, so the arm " <>
          "never fires here. A ping ack claims nothing beyond having been reached."
    },
    %{
      key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "105570378"},
      basis_spans: [{74, 78}, {87, 87}],
      basis_token: "ignored:",
      class: "CATCH-ALL-TO-SUCCESS",
      confirmation: "declared",
      basis: "the response body itself — `ignored: \"event\"` on :87, plus @doc :74-78",
      why:
        "THE ONE ROW THAT ACTUALLY SUPPRESSES. The arm fires here (head `_other`, body renders " <>
          "ok: true, site contained), and it is right to: this IS a catch-all routed to success. " <>
          "It is declared because the body NAMES the outcome — the caller is told the event was " <>
          "ignored, so the receipt does not pass an unhandled event off as handled work."
    },
    %{
      key: {"api/lib/barkpark_web/controllers/bulldocs_form_controller.ex",
            "BarkparkWeb.BulldocsFormController.submit/2", "123699679", "17468236"},
      basis_spans: [{22, 24}, {53, 53}],
      basis_token: "the trap stays invisible",
      class: "HONEYPOT",
      confirmation: "declared",
      route_claim: "ROUTE-MISCREDIT",
      basis:
        "@moduledoc :22-24 (\"bots that fill it get a vacuous 201 (no write) so the trap stays " <>
          "invisible\") and the ONE-LINE inline comment at :53 — not the :52-54 arm span",
      why:
        "declared TWICE, and the only site in the corpus whose honesty depends on the receipt " <>
          "being indistinguishable from the happy one. The `{:honeypot}` head is a literal match, " <>
          "so the arm does not fire. ROUTE-MISCREDIT: the census brackets this `[WRITE d5]` " <>
          "because submit/2 routes to a write on its SUCCESS path — crediting a write to the one " <>
          "arm that provably makes none. The bracket is disputed here because it cannot be " <>
          "retracted from the shape vocabulary: route_tag/1 and evidence/3 read write?/depth only."
    }
  ]

  # ------------------------------------------------------------- judgment register
  #
  # THE JUDGMENT LEDGER (PDS wave 37, task pds-w34-hand-bucket-register). One row per
  # EMITTED success claim, keyed on {path, module.name/arity, head_hash, expr_fp} — CLASS
  # AND LINE BOTH EXCLUDED. It is NOT a bucketing exercise and it asserts NO distribution:
  # REGISTER-COMPLETE checks completeness and integrity, never how the verdicts fall, so
  # no reclassification can red the build.
  #
  # DERIVED AT 501fb9670, off this script's OWN `--keys` emission (91 rows / 91 distinct).
  # Every key here was READ from that TSV, never transcribed by hand.
  #
  # THE KEY LADDER, MEASURED AT THAT SHA — so nobody "simplifies" the key to three fields:
  #     {path, mfa} = 75 distinct · +head_hash = 76 · +expr_fp = 91 · expr_fp ALONE = 67
  # `expr_fp` IS THE LOAD-BEARING FIELD. One fingerprint (17468236, the bare success map
  # with no discriminating key) covers 12 rows across 7 files; inside
  # github_webhook_controller.ex, path+expr_fp alone collapses 14 rows to 12. `head_hash`
  # buys exactly ONE row (75 -> 76) and is CARRIED FOR STABILITY, NOT UNIQUENESS: it
  # survives an edit inside a clause body that re-fingerprints the expression, so a row
  # demoted by basis-stale can still be found. gh:86 and gh:87 share {path, mfa,
  # head_hash} and are separated by expr_fp ALONE.
  #
  # WHAT head_hash CANNOT DISCRIMINATE (scope stated, or a reader believes it is near
  # unique on its own — it is not, and it does not need to be): across all 17,620 defs it
  # collides in exactly 3 buckets WITHIN a {path, module.name/arity} group, and 0 times
  # within the 75 site-owning groups. Only ONE of the three is a benign bodiless
  # declaration head; the other TWO are DISTINCT functions inside two `defimpl Inspect,
  # for: ...` blocks (plugins/github/errors.ex :94/:138, plugins/indx/errors.ex :118/:137)
  # that this walker cannot tell apart. Corpus-wide — ignoring path and mfa — it is 912
  # groups over 2,543 defs under this normaliser (the wave brief recorded 913/2,544 under
  # another spelling; that figure does not survive a spelling change and is not quotable
  # across one).
  #
  # CHURN, MEASURED across the three merges that landed into this sha: 5 orphaned / 5
  # arrived / 86 common, and it was a PURE RE-KEY — the {path, mfa} multiset was
  # byte-identical and only expr_fp moved. Expect ~5.5% of rows to re-key per code slice
  # touching two controllers. `--keys` is C-locale sorted by {path, line}; a consumer that
  # pipes it through `sort` without LC_ALL=C reorders it.
  #
  # THE SENTINEL PREDICATE, NAMED: sentinel-ok@repo-write,def+defp,tail-disjoint /
  # total-meta-drop/phash2-term/v1 / 501fb9670. The 21 function-tail / 11 clause-local
  # figures reproduce ONLY under that four-knob predicate (def+defp clauses with a
  # do-block, a Repo-WRITE verb list, tail = last expression of a __block__, clause-local
  # DISJOINT from function-tail). Dropping the write predicate gives 257/247; public def
  # only gives 15/4; any Repo.* gives 23/18; non-disjoint gives 13.
  #
  # CAS IS A STRICT SUBSET OF POST-READ AT THIS LENS AND THIS SHA — the difference
  # CAS-minus-POST-READ is EMPTY, and POST-READ-minus-CAS is the single site
  # oidc_controller.ex:82. All 14 CAS sites reach POST-READ via ARM 1 (`select:`), zero
  # via ARM 2, and the same function supplies both halves (Internal.fenced_content_write/4
  # x13, BlockOps.fenced_paper_update/4 x1). RECORDED WITH ITS LENS AND SHA, NEVER AS A
  # STANDING INVARIANT: a CAS spelling with no `select:` is describable
  # (pds-bl-cas-int-tuple-spelling-blind) and would break it.
  #
  # -- THE THREE VERDICTS. There are exactly three, and nothing else is admitted.
  #   PROVEN    a committed differential asserts `receipt == stored row`
  #   REFUTED   measured divergent
  #   UNJUDGED  named, WITH THE REASON — thirty honest UNJUDGED beat seventy-four
  #             confident guesses, which is what dissolves the shadowed-bucket problem
  #             instead of trading one shadowed bucket for another.
  #
  # -- THE OPENING BALANCE, STATED SO IT CANNOT BE ROUNDED UP (PDS-D526/D527).
  #   8 rows  PROVEN / end-to-end            mutation-attested; the row carries the line
  #   7 rows  PROVEN / end-to-end-unmutated  ALREADY CONJUNCTIVE in the committed suite,
  #                                          BUT ITS FALSIFIER WAS NEVER EXERCISED — the
  #                                          conjunction was READ, not made to fail
  #   1 tag   PROVEN inside an UNJUDGED row  github_webhook_controller.ex:194's
  #                                          `:already_stamped` tag only (see below)
  # PDS-D526 opened this at 18 (9 + 9). IT CLOSED AT 16, AND THE TWO MISSING ROWS WERE
  # TAKEN BY THIS WAVE'S OWN FALSIFIER, NOT BY AN ARGUMENT: BASIS-FALSIFIERS refused
  # bulldocs_ingest_controller.ex:630 and :715, whose cited tests drive the route and never
  # read the paper back. Both now read UNJUDGED / unjudged_other with the refusal written
  # in the row. THAT IS THE LEDGER WORKING — a wave that could only ever ratify its own
  # brief would be paperwork. Below the line, and NOT part of it: the rows carrying
  # `side_effect_existence_only`, which PDS-D499 maps to UNJUDGED — the cited Repo read
  # asserts an audit row EXISTS, never that the printed field equals the stored one.
  # THE COUNT IS NOT TRANSCRIBED HERE. It is derived at print time from @register (the
  # BASIS DISTRIBUTION block, and the "Below the line" sentence the integrity report
  # prints from `by_basis`) — a hand-typed integer in this comment went stale inside this
  # very wave, because bulldocs_ingest_controller.ex:164 was demoted to `unjudged_other`
  # on the advisory line AFTER the tally was written. The two that remain of the wave's
  # own "weaker still" rows are tasks_controller.ex:1352 and auth_controller.ex:329
  # (which proves session death through a SECOND ENDPOINT); :164's demotion is printed in
  # full in the UNJUDGED-OTHER block.
  #
  # -- THE BASIS VOCABULARY IS CLOSED, AND EACH VALUE CARRIES ITS OWN CHECK. An essay in
  # a reason field is unfalsifiable paperwork; a vocabulary token is a claim a machine can
  # refuse. PROSE IS PERMITTED ON EXACTLY ONE VALUE — `unjudged_other`, where it is
  # REQUIRED, counted, printed, and never reds. @basis_vocab below is the authority.
  # THIS WAVE ADDS FOUR VALUES to PDS-D499's eleven, each mechanically falsifiable:
  #   end_to_end_unmutated   — the distinct token for a conjunction read but not exercised
  #   declared_basis         — the five @declared rows; DECLARED-BASIS-INTACT is its check
  #   partial_tag_coverage   — one emitted site, several rendered receipts (below)
  #   unexamined             — no differential has been READ for this row. It is not a
  #                            euphemism for "probably fine": it is the honest floor, and
  #                            it is what 33 of these 91 rows say.
  #
  # -- MULTI-TAG SITES (PDS-D527). github_webhook_controller.ex:194's clause head is
  # `{:ok, tag, doc_id} when tag in [...]` — ONE emitted site, THREE rendered receipts,
  # and only `:already_stamped` is proven end-to-end. Such a row carries a `tags:`
  # sub-list and THE ROW'S OWN VERDICT IS THE WEAKEST OF THEM. IT IS NOT SPLIT INTO THREE
  # ROWS: three rows would name one emitted site three times and RED REGISTER-COMPLETE's
  # row->site direction, the arm this wave is judged on.
  #
  # -- WHAT THE KEY MIGRATION KILLED, AND WHAT IT DELIBERATELY DID NOT. With one blank
  # line inserted above github_webhook_controller.ex:87 (`perl -i -pe 'print "\n" if
  # $. == 80'` — NOT `sed -i '' '398i\'`, which is a macOS no-op and proves nothing), the
  # {path,line}-keyed spelling prints `1 undeclared of 1 fired` — A FALSE ACCUSATION
  # against a committed basis, at exit 0 — while this one still prints `0 undeclared of 1
  # fired` with only the printed anchor tracking to :88. REGISTER-COMPLETE and
  # DECLARED-ROWS-RESOLVE both stay green through it, because neither joins on a line.
  # DECLARED-BASIS-INTACT correctly REDS, and that is not a residual line dependency worth
  # engineering away: a basis span NAMES PROSE IN A FILE, so it is line-anchored by
  # nature, and the FAIL line carries the row and its recorded span so the fix is one edit.
  #
  # -- NO SCRIPT EVER WRITES A VERDICT. Arms check; they never assign. The one apparent
  # exception is `basis_stale`, and it is not one: a row whose recorded head_hash/expr_fp
  # no longer match is REPORTED as demoted at print time, and the committed row is left
  # exactly as its author wrote it, so the demotion is visible as a diff-free fact rather
  # than an edit nobody reviewed.
  #
  # -- WHAT THE MODULE-LINKAGE CHECK WOULD HAVE COST (PDS-D525). "The cited test
  # references the site's MODULE" reads like the obvious falsifier and it is a FALSE one:
  # `pds_group_c_receipt_differential_test.exs` contains the string `Controller` ZERO
  # times, because conn-driven tests name a URL, not a module — the predicate refuses ALL
  # of this wave's committed PROVEN differentials. Route linkage replaces it and is
  # ADVISORY, never redding, because it is UNCHECKABLE for the 14 github_webhook rows
  # (`GithubWebhookController` appears zero times in router.ex; the routes are
  # macro-generated) and reading the literal alone manufactured three FALSE contradictions
  # against genuine PROVEN rows whose route lives in an enclosing `scope`.
  #
  # -- HOME. In-file, beside @declared, at COMPACT row density (~4.4 lines/row). The
  # 19-lines-per-row @declared shape would have added ~1,730 lines and doubled this
  # script. PROSE LIVES IN THE WAVE PAPER, not here — except `unjudged_other`, where it is
  # required. `.sobelow-skips` is FORBIDDEN as a home: PDS-D141 forbids PDS PRs from
  # editing it, it is this repo's own worked example of a line-keyed register rotting
  # silently, and a judgment register whose rows silence the instrument inverts this
  # epic's law.

  # THE VOCABULARY IS THE AUTHORITY, AND IT IS DATA. {verdict class, falsifier, tier} —
  # `:reds` values are checked by the L2 basis falsifiers and go RED; `:advisory` values
  # print a counted CONTRADICTION line at exit 0, because their falsifier is either
  # undecidable as written or measured to manufacture false accusations.
  @basis_vocab %{
    end_to_end:
      {"PROVEN", "the cited test drives the site's route AND reads the stored row back", :reds},
    end_to_end_unmutated:
      {"PROVEN", "the cited test drives the site's route AND reads the stored row back (mutation NEVER exercised)", :reds},
    two_hop_composed:
      {"UNJUDGED", "a single test spanning BOTH hops exists", :advisory},
    stub_mapping_only:
      {"UNJUDGED", "the cited test has no injection seam, or DOES read Repo", :reds},
    context_differential_only:
      {"UNJUDGED", "the cited test builds a conn", :reds},
    side_effect_existence_only:
      {"UNJUDGED", "the Repo read compares a printed field, not existence", :advisory},
    shape_assertion_only:
      {"UNJUDGED", "the assertion can fail on a wrong payload (implementable ONLY as a denylist of weak predicates — is_list/is_map/is_binary/bare truthiness — so it is advisory, and this name promises more than its code delivers)", :advisory},
    payload_is_the_postcondition:
      {"UNJUDGED", "any emitted value traces to params[...] or a fn head", :advisory},
    request_param_echo:
      {"UNJUDGED", "no emitted value traces to a request parameter", :advisory},
    no_observer:
      {"UNJUDGED", "any test references the site's module OR its route path", :reds},
    basis_stale:
      {"UNJUDGED", "the current head_hash+expr_fp equal the recorded pair", :reds},
    partial_tag_coverage:
      {"UNJUDGED", "every tag in the sub-list carries the same verdict as the row", :advisory},
    declared_basis:
      {"UNJUDGED", "the @declared row's basis span no longer carries its token (DECLARED-BASIS-INTACT)", :advisory},
    unexamined:
      {"UNJUDGED", "a committed test cites this site's route AND reads Repo back", :advisory},
    not_a_receipt:
      {"UNJUDGED", "the site renders a body or a status that makes a claim about work done", :advisory},
    unjudged_other:
      {"UNJUDGED", "PROSE REQUIRED; counted and PRINTED in the integrity block; NEVER reds", :advisory}
  }

  # ---------------------------------------------------------- population roster
  #
  # THE BLIND-SPOT BLOCK USED TO BE THREE SUBSTRING TOTALS (PDS-D524). A total names
  # nobody; this names EIGHT sites outside the `ok: true` lens that report success without
  # a read, each with a verdict from the SAME vocabulary the register uses. It is DISJOINT
  # from the 91 BY SITE, and the distinction matters: zero register keys live in
  # scim_groups / scim_users / session_controller / chat_controller / chat_host_controller,
  # and the ONE shared FILE is pulse_controller.ex, where the register holds create/2 (:58)
  # and this roster names preflight/2 (:93) — a different function. Re-derived here rather
  # than asserted: `cut -f1 keys.tsv | sort -u | grep -E 'scim|session|chat|pulse'` returns
  # pulse_controller.ex and nothing else.
  #
  # EVERY ROW IS ANCHORED ON A LITERAL, NEVER A LINE NUMBER, and the arm asserts
  # EXISTENCE, NEVER A COUNT. Measured over 80 api/lib commits across 9 days the three
  # substring totals moved 7 times (~once per 11 commits, twice on ONE day) and the movers
  # were a papers fence, a credential-scope security fix and a chat-wire feature — a count
  # arm would have redded on unrelated work every week. The roster literals had ZERO drift
  # across all 80.
  #
  # THE TEN "CLASS D" DELETE/REVOKE ECHO SITES ARE NOT ROSTERED (PDS-D523). Every one
  # bottoms out in Repo.delete(_, stale_error_field: :id), Repo.update/1 on one fetched
  # row, or Repo.rollback — they are FALSE ACCUSATIONS, and a roster that carries them
  # would be the over-claiming this census exists to find, pointed the other way.
  #
  # TWO ROWS ARE STALE-ON-MERGE, AND SAYING SO IS THE POINT (wave 37 review, 2026-08-02).
  # scim_groups_controller.ex and session_controller.ex are verdicted REFUTED **at
  # 501fb9670**. `pds-w37-unread-callee-receipts` repairs BOTH, and both roster literals
  # SURVIVE that repair as substrings — measured, not assumed: the census run over the
  # three wave-37 branches merged together prints ROSTER-ANCHORS-EXIST PASS with these
  # verdicts unchanged. So the ANCHOR arm cannot catch the staleness; nothing here can.
  # Whoever merges that slice OWNS re-deriving these two rows in the same wave — the note
  # below is the obligation, and a REFUTED that outlives its defect is exactly the
  # over-claim this roster exists to name, pointed at the roster itself.
  @roster [
    %{path: "api/lib/barkpark_web/controllers/scim_groups_controller.ex",
      literal: "Scim.delete_group(org, group)",
      verdict: "REFUTED", basis: :unjudged_other,
      note: "the callee's return is DISCARDED ENTIRELY before a 204, and Scim.delete_group/2 returns {:ok, n} including {:ok, 0}. STALE-ON-MERGE: pds-w37-unread-callee-receipts widens the callee to {:error, :not_found} and matches it at the caller; when that branch lands, RE-DERIVE this row — the literal survives, so no arm will red for you."},
    %{path: "api/lib/barkpark_web/controllers/scim_users_controller.ex",
      literal: "Scim.deprovision_user(org, user, hard: true)",
      verdict: "PROVEN", basis: :end_to_end_unmutated,
      note: "the match is `{:ok, _} =` over a raising Repo.delete! inside a transaction, so a failed deprovision cannot reach the 204."},
    %{path: "api/lib/barkpark_web/controllers/session_controller.ex",
      literal: "Barkpark.Accounts.revoke_user_session_token(token)",
      verdict: "REFUTED", basis: :unjudged_other,
      note: "revoke_user_session_token/1 hardcodes :ok over a Repo.update_all, so the flash and the redirect below it are true no matter how many rows moved. STALE-ON-MERGE: pds-w37-unread-callee-receipts widens it to {:ok, revoked} and forks the flash on the count; when that branch lands, RE-DERIVE this row — the literal survives, so no arm will red for you."},
    %{path: "api/lib/barkpark_web/controllers/chat_controller.ex",
      literal: "StudioChat.update_approval_status(id, request_id, status)",
      verdict: "UNJUDGED", basis: :unjudged_other,
      note: "both arms of update_approval_status fold to :ok, and answer_approval's result is discarded with `_ =`."},
    %{path: "api/lib/barkpark_web/controllers/chat_controller.ex",
      literal: "persist_user_turn(id, content)",
      verdict: "UNJUDGED", basis: :declared_basis,
      note: "a fail-soft persist, declared in the clause comment above it — the send is already on its way, so a persist miss must not turn a live send into an error."},
    %{path: "api/lib/barkpark_web/controllers/chat_controller.ex",
      literal: "json(%{request_id: request_id})",
      verdict: "UNJUDGED", basis: :declared_basis,
      note: "the request_id: nil no-op, declared in the @doc."},
    %{path: "api/lib/barkpark_web/controllers/chat_host_controller.ex",
      literal: "{:ok, :accepted} -> conn |> put_status(:accepted) |> json(",
      verdict: "UNJUDGED", basis: :stub_mapping_only,
      note: "re-renders the callee's :accepted tag faithfully; the tag's truth against any stored row is a separate question this row does not answer."},
    %{path: "api/lib/barkpark_web/controllers/pulse_controller.ex",
      literal: "def preflight(conn, _params), do: send_resp(conn, 204,",
      verdict: "UNJUDGED", basis: :not_a_receipt,
      note: "a CORS preflight 204 claims nothing about work done. CARRIED ON PURPOSE, so the roster's own completeness is checkable: a roster of only the guilty is indistinguishable from a roster nobody finished."}
  ]

  @register [
    # barkpark/plugins/sheets/web/import_controller.ex:64
    %{key: {"api/lib/barkpark/plugins/sheets/web/import_controller.ex",
            "Barkpark.Plugins.Sheets.Web.ImportController.create/2", "51320322", "13286890"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark/plugins/sheets/web/ops_controller.ex:71
    %{key: {"api/lib/barkpark/plugins/sheets/web/ops_controller.ex",
            "Barkpark.Plugins.Sheets.Web.OpsController.apply_ops/2", "36006285", "87176703"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:177
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.erase/2", "14672314", "70062513"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:329
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.revoke_session/2", "14482306", "17656195"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:369"},
    # barkpark_web/controllers/auth_controller.ex:351
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.logout/2", "893943", "17468236"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:351
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.logout/2", "893943", "101485070"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:379
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.verify_email/2", "13273957", "17468236"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:399
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_reset/2", "37852989", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/auth_controller.ex:417
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_magic_link/2", "15394828", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/auth_controller.ex:463
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.reset/2", "117976982", "93237454"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/controllers/pds_w36_revoke_all_receipt_test.exs:64",
      attestation:
        "mutation: hardcode sessionsRevoked — `mix test api/test/barkpark_web/controllers/pds_w36_revoke_all_receipt_test.exs:64` reds on Repo.aggregate",
    },
    # barkpark_web/controllers/auth_controller.ex:528
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.mfa_verify/2", "16615157", "38279071"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:463"},
    # barkpark_web/controllers/auth_controller.ex:567
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.mfa_disable/2", "103479204", "17468236"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:463"},
    # barkpark_web/controllers/auth_controller.ex:600
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.mfa_step_up/2", "85508749", "111398976"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:463"},
    # barkpark_web/controllers/bulldocs_form_controller.ex:50
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_form_controller.ex",
            "BarkparkWeb.BulldocsFormController.submit/2", "123699679", "127244318"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_form_controller.ex:54
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_form_controller.ex",
            "BarkparkWeb.BulldocsFormController.submit/2", "123699679", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:164
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.ingest_blocks/4", "1989150", "124223564"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED ON THE ADVISORY LINE. side_effect_existence_only claims a Repo read that asserts EXISTENCE; the cited positive control (bulldocs_ingest_controller_test.exs:319) reads nothing back at all, so it cannot even assert that."},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:244
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.ingest_html/4", "19560303", "124223564"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/bulldocs_ingest_controller_test.exs:97"},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:321
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.ingest_session/2", "11366553", "107043790"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:431
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.apply_session_op/2", "38576492", "88664755"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:502
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.append_session_event/2", "51520286", "61088078"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:551
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.touch_session_conversation/2", "104647366", "61088078"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:630
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.apply_op/2", "133005745", "10224315"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED BY THIS WAVE'S OWN FALSIFIER, not by argument. The brief ruled it end_to_end_unmutated; the arm refused the citation (bulldocs_ingest_controller_test.exs:595 drives the batch route but never reads the paper back), so the receipt-vs-stored-row question is unjudged."},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:715
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.apply_op/2", "85655901", "15024779"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED BY THIS WAVE'S OWN FALSIFIER, not by argument. Same shape as its batch sibling: bulldocs_ingest_controller_test.exs:397 drives the single-op route and asserts the returned fragment, and nothing reads the stored paper back."},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:814
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.propose/2", "78347098", "122622379"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_intents_controller.ex:50
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_intents_controller.ex",
            "BarkparkWeb.BulldocsIntentsController.mark_processed/2", "120960553", "126280052"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_adopt_controller.ex:66
    %{key: {"api/lib/barkpark_web/controllers/github_adopt_controller.ex",
            "BarkparkWeb.GithubAdoptController.adopt/2", "109355155", "85172196"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_adopt_controller.ex:69
    %{key: {"api/lib/barkpark_web/controllers/github_adopt_controller.ex",
            "BarkparkWeb.GithubAdoptController.adopt/2", "109355155", "81072"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_status_controller.ex:65
    %{key: {"api/lib/barkpark_web/controllers/github_status_controller.ex",
            "BarkparkWeb.GithubStatusController.status/2", "63059312", "64996178"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_webhook_controller.ex:86
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/github_webhook_controller.ex:87
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "105570378"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/github_webhook_controller.ex:111
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_inbound/2", "26011363", "124460091"},
      verdict: "UNJUDGED", basis: :two_hop_composed, evidence: "api/test/barkpark/plugins/github/inbound_events_test.exs:201"},
    # barkpark_web/controllers/github_webhook_controller.ex:115
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_inbound/2", "26011363", "96836141"},
      verdict: "UNJUDGED", basis: :two_hop_composed, evidence: "api/test/barkpark/plugins/github/inbound_events_test.exs:201"},
    # barkpark_web/controllers/github_webhook_controller.ex:120
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_inbound/2", "26011363", "39153928"},
      verdict: "UNJUDGED", basis: :two_hop_composed, evidence: "api/test/barkpark/plugins/github/inbound_events_test.exs:235"},
    # barkpark_web/controllers/github_webhook_controller.ex:145
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "38180227"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:165"},
    # barkpark_web/controllers/github_webhook_controller.ex:150
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "96836141"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:112"},
    # barkpark_web/controllers/github_webhook_controller.ex:154
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "39153928"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:122"},
    # barkpark_web/controllers/github_webhook_controller.ex:161
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "109773520"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/github_webhook_controller.ex:189
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "46526763"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:209",
      attestation:
        "mutation: render stamped: without the merge write — `mix test api/test/barkpark_web/controllers/github_webhook_integration_test.exs:209` reds on Repo.get!",
    },
    # barkpark_web/controllers/github_webhook_controller.ex:194
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "107251666"},
      verdict: "UNJUDGED", basis: :partial_tag_coverage, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:244",
      tags: [
        %{tag: :already_stamped, verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:244"},
        %{tag: :no_marker, verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
        %{tag: :no_guardable_marker, verdict: "UNJUDGED", basis: :no_observer, evidence: ""},
      ],
    },
    # barkpark_web/controllers/github_webhook_controller.ex:200
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "28623217"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/github_webhook_controller.ex:205
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "62383269"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/github_webhook_controller.ex:209
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "1432007"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/oidc_controller.ex:82
    %{key: {"api/lib/barkpark_web/controllers/oidc_controller.ex",
            "BarkparkWeb.OidcController.callback/2", "55913437", "73996638"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/plugin_settings_controller.ex:53
    %{key: {"api/lib/barkpark_web/controllers/plugin_settings_controller.ex",
            "BarkparkWeb.PluginSettingsController.update/2", "52263610", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:251",
      attestation:
        "mutation: drop one key from the stored settings map — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:251` reds",
    },
    # barkpark_web/controllers/plugin_settings_controller.ex:65
    %{key: {"api/lib/barkpark_web/controllers/plugin_settings_controller.ex",
            "BarkparkWeb.PluginSettingsController.delete/2", "52373358", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:272",
      attestation:
        "mutation: 200 without deleting the row — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:272` reds",
    },
    # barkpark_web/controllers/pulse_controller.ex:58
    %{key: {"api/lib/barkpark_web/controllers/pulse_controller.ex",
            "BarkparkWeb.PulseController.create/2", "89312836", "32961015"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/query_controller.ex:199
    %{key: {"api/lib/barkpark_web/controllers/query_controller.ex",
            "BarkparkWeb.QueryController.counts/2", "9322375", "98818316"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/saml_controller.ex:66
    %{key: {"api/lib/barkpark_web/controllers/saml_controller.ex",
            "BarkparkWeb.SamlController.acs/2", "32993266", "73996638"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/saml_controller_test.exs:117"},
    # barkpark_web/controllers/search_controller.ex:190
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.reindex/2", "43259676", "54848977"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/search_controller.ex:316
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.delete_search_synonym/2", "57054890", "120063507"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:67",
      attestation:
        "mutation: flip `Synonyms.delete/4` to return {:ok, 0} without deleting — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:67` reds on the Repo read",
    },
    # barkpark_web/controllers/search_controller.ex:337
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.search_interaction/2", "79721084", "115364326"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/integration/v1_data_search_suggestions_test.exs:84"},
    # barkpark_web/controllers/search_controller.ex:340
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.search_interaction/2", "79721084", "95315838"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/search_controller.ex:363
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.correction/2", "57827587", "73264487"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/secret_controller.ex:67
    %{key: {"api/lib/barkpark_web/controllers/secret_controller.ex",
            "BarkparkWeb.SecretController.update/2", "4060754", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:195",
      attestation:
        "mutation: store the PREVIOUS ciphertext — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:195` reds on the decode-back",
    },
    # barkpark_web/controllers/secret_controller.ex:80
    %{key: {"api/lib/barkpark_web/controllers/secret_controller.ex",
            "BarkparkWeb.SecretController.delete/2", "115609568", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:145",
      attestation:
        "mutation: skip the audit insert — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:145` reds on the audit row",
    },
    # barkpark_web/controllers/self_update_controller.ex:24
    %{key: {"api/lib/barkpark_web/controllers/self_update_controller.ex",
            "BarkparkWeb.SelfUpdateController.trigger/2", "84801527", "68291924"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/site_deploy_controller.ex:81
    %{key: {"api/lib/barkpark_web/controllers/site_deploy_controller.ex",
            "BarkparkWeb.SiteDeployController.start/2", "126876520", "52242951"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/social_controller.ex:66
    %{key: {"api/lib/barkpark_web/controllers/social_controller.ex",
            "BarkparkWeb.SocialController.callback/2", "9871709", "73996638"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/tasks_controller.ex:83
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.task_list_response/3", "83021484", "1576835"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "wave 36 measured this receipt divergent and pds-w36-help-seal-fix repaired it; no committed differential naming task_list_response/3 resolves in the tree at this sha, so the REPAIR is unjudged here rather than credited. UPGRADE-ON-MERGE (wave 37 review, 2026-08-02): that slice lands api/test/barkpark_web/controllers/pds_w36_help_seal_probe_test.exs, whose PROBE A and PROBE D were re-verified RED by this reviewer against a faithful revert of the seal hoist. It cites the ROUTE, never the function name, so this note's wording stays literally true after the merge and no arm will red — re-derive the row to end_to_end by hand when the branch lands.",
    },
    # barkpark_web/controllers/tasks_controller.ex:170
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.prime/2", "40556915", "123654328"},
      verdict: "UNJUDGED", basis: :request_param_echo},
    # barkpark_web/controllers/tasks_controller.ex:224
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.events/2", "114887844", "12538138"},
      verdict: "UNJUDGED", basis: :request_param_echo},
    # barkpark_web/controllers/tasks_controller.ex:316
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.claim/2", "130674472", "21159066"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:2435"},
    # barkpark_web/controllers/tasks_controller.ex:371
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.show/2", "107047617", "14030995"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:435
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.claim_by_id/2", "59151065", "67476"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:105"},
    # barkpark_web/controllers/tasks_controller.ex:558
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.release/2", "64399052", "86587931"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:741"},
    # barkpark_web/controllers/tasks_controller.ex:587
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.close_response/3", "102889179", "17778956"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:149"},
    # barkpark_web/controllers/tasks_controller.ex:652
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.stage/2", "86501420", "84462998"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:3147"},
    # barkpark_web/controllers/tasks_controller.ex:788
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.stamp/2", "53080965", "119279425"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:126"},
    # barkpark_web/controllers/tasks_controller.ex:861
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.pulse/2", "62712851", "71420310"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:169"},
    # barkpark_web/controllers/tasks_controller.ex:922
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.edges/2", "29434876", "113319186"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:952
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_show/2", "68876245", "14314567"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:984
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_tasks/2", "6484558", "37641606"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1008
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_orphans/2", "87006539", "21591304"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1015
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_dangling/2", "113055363", "33214619"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1142
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_corpus/2", "84484341", "94052887"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1289
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.add_edge/2", "32780970", "67314930"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:165"},
    # barkpark_web/controllers/tasks_controller.ex:1327
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.relabel/2", "7475620", "84462998"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:209"},
    # barkpark_web/controllers/tasks_controller.ex:1352
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.papers/2", "102968637", "84462998"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:1724"},
    # barkpark_web/controllers/tasks_controller.ex:1379
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.sessions/2", "36243778", "84462998"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:234"},
    # barkpark_web/controllers/tasks_controller.ex:1422
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.move/2", "90153949", "84462998"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:194"},
    # barkpark_web/controllers/tasks_controller.ex:1655
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.fleet_beat/2", "8622444", "8757049"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:266"},
    # barkpark_web/controllers/tasks_controller.ex:1696
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.fleet_roster/2", "116314994", "118018566"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tickets_controller.ex:93
    %{key: {"api/lib/barkpark_web/controllers/tickets_controller.ex",
            "BarkparkWeb.TicketsController.index_own/2", "13011616", "113191402"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/tickets_controller.ex:169
    %{key: {"api/lib/barkpark_web/controllers/tickets_controller.ex",
            "BarkparkWeb.TicketsController.inbox/2", "102026838", "113191402"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/tickets_controller.ex:263
    %{key: {"api/lib/barkpark_web/controllers/tickets_controller.ex",
            "BarkparkWeb.TicketsController.render_ticket/3", "77961612", "114383917"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/v1/media_controller.ex:188
    %{key: {"api/lib/barkpark_web/controllers/v1/media_controller.ex",
            "BarkparkWeb.V1.MediaController.delete_search_synonym/2", "57054890", "20252134"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:82",
      attestation:
        "mutation: return the media surface's receipt without the delete — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:82` reds",
    },
    # barkpark_web/controllers/v1/media_controller.ex:228
    %{key: {"api/lib/barkpark_web/controllers/v1/media_controller.ex",
            "BarkparkWeb.V1.MediaController.search_interaction/2", "79721084", "115364326"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/v1/media_controller.ex:231
    %{key: {"api/lib/barkpark_web/controllers/v1/media_controller.ex",
            "BarkparkWeb.V1.MediaController.search_interaction/2", "79721084", "95315838"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/webauthn_controller.ex:64
    %{key: {"api/lib/barkpark_web/controllers/webauthn_controller.ex",
            "BarkparkWeb.WebauthnController.register/2", "48289311", "78521592"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/webauthn_controller.ex:170
    %{key: {"api/lib/barkpark_web/controllers/webauthn_controller.ex",
            "BarkparkWeb.WebauthnController.step_up/2", "118230159", "123849466"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/webauthn_controller.ex:212
    %{key: {"api/lib/barkpark_web/controllers/webauthn_controller.ex",
            "BarkparkWeb.WebauthnController.delete/2", "99456611", "17468236"},
      verdict: "UNJUDGED", basis: :unexamined}
  ]


  # ---------------------------------------------------------------- entrypoint

  def main(argv) do
    case parse_args(argv) do
      {:error, msgs} -> refuse_args(msgs)
      %{selftest?: true} -> selftest()
      %{keys?: true} = opts -> keys_run(opts)
      opts -> census(opts)
    end
  end

  # ARGV-STRICT. Every accepted spelling is named here and everything else is an error —
  # not a warning, not a shrug. `--files-from` is the one flag that takes a value, so its
  # value is consumed here and never re-read as a flag.
  defp parse_args(argv),
    do: parse_args(argv, %{sites?: false, keys?: false, selftest?: false, files_from: nil}, [])

  defp parse_args([], opts, []), do: opts
  defp parse_args([], _opts, bad), do: {:error, Enum.reverse(bad)}
  defp parse_args(["--sites" | rest], o, bad), do: parse_args(rest, %{o | sites?: true}, bad)
  defp parse_args(["--keys" | rest], o, bad), do: parse_args(rest, %{o | keys?: true}, bad)
  defp parse_args(["--selftest" | rest], o, bad), do: parse_args(rest, %{o | selftest?: true}, bad)

  defp parse_args(["--files-from", path | rest], o, bad),
    do: parse_args(rest, %{o | files_from: path}, bad)

  defp parse_args(["--files-from"], _o, bad),
    do: {:error, Enum.reverse(["--files-from needs a FILE path and was given none" | bad])}

  defp parse_args([other | rest], o, bad),
    do: parse_args(rest, o, ["unknown argument #{inspect(other)}" | bad])

  defp refuse_args(msgs) do
    p("")
    p("REFUSED: UNKNOWN ARGUMENT")
    Enum.each(msgs, &p("  " <> &1))
    p("")
    p("  accepted: --sites · --files-from FILE · --keys · --selftest")
    p("  A swallowed flag is a census measuring a lens nobody asked for. Exit 2.")
    System.halt(2)
  end

  defp census(opts) do
    t0 = System.monotonic_time(:millisecond)
    show_sites? = opts.sites?
    files = corpus(opts)

    banner()
    guard_corpus!(files)

    parsed = Enum.map(files, &parse_file/1)
    index = build_index(parsed)

    sites = Enum.flat_map(parsed, & &1.sites)
    textual = Enum.sum(Enum.map(parsed, & &1.textual_count))
    {ast_sites, phantoms} = split_phantoms(parsed, sites)
    {consumers, emitted} = Enum.split_with(ast_sites, & &1.pattern?)

    routed = Enum.map(emitted, &route(&1, index))
    classified = Enum.map(routed, &classify(&1, index))

    report_lens(textual, ast_sites, phantoms, consumers, emitted)
    report_carriers(parsed, ast_sites)
    report_split(classified)
    report_depth_sweep(emitted, index)
    report_shapes(classified)
    report_declared_register(classified)
    report_judgment_register(classified)
    falsifiers = if register_scope(classified) == :real, do: report_basis_falsifiers(classified), else: :skipped
    if show_sites?, do: report_each_site(classified)
    routed = report_routed_population(routed_derivation(parsed), classified, parsed, index)
    report_lens_can_miss(routed)
    report_blind_spots(parsed)
    delegate = report_delegate_probe(index)

    ms = System.monotonic_time(:millisecond) - t0

    integrity(files, textual, ast_sites, phantoms, consumers, emitted, classified, delegate, ms,
      parsed, falsifiers, routed)
  end

  # THE GLOB IS RELATIVE TO CWD, DELIBERATELY. `--selftest` censuses a synthetic tree by
  # running this same file with `cd:` set to a tmp dir — the sentinels at the top of this
  # module are relative literals for the same reason. (The `--files-from` seam does NOT
  # work for fixtures: guard_corpus!/1 runs before parse_file/1 and ORs the corpus floor
  # with the sentinel check on one cond arm, so no fixture list is both small enough to
  # mutate and large enough to pass.)
  defp corpus(%{files_from: nil}), do: Path.wildcard("api/lib/**/*.ex") |> Enum.sort()

  defp corpus(%{files_from: path}),
    do: path |> File.read!() |> String.split("\n", trim: true)

  defp banner do
    {otp, erts} = {System.otp_release(), :erlang.system_info(:version)}

    p("PDS ELIXIR RECEIPT CENSUS — the api/lib success surface, first look")
    p(String.duplicate("=", 78))
    p("engine      Elixir #{System.version()} · Erlang/OTP #{otp} (erts #{erts}) · #{:erlang.system_info(:system_architecture)}")
    p("lens        AST (Code.string_to_quoted/2, literal_encoder) — no regex, NO \\b dependency")
    p("            PDS-D448a: git grep -E '\\bok: true' returns 0 and exits 1 SILENTLY on this host.")
    p("            Every textual count here is :binary.matches/2 substring matching.")
    p("law         no Barkpark verb may report success on an exit code alone (PDS wave 22)")
    p("gate        NONE. This prints a population; it does not police one (PDS-D454).")
    p("")
  end

  # ---------------------------------------------------------------- corpus guard

  # `announce?` is false for --keys ONLY, whose stdout is machine-read TSV and must carry
  # nothing else. The REFUSAL is never quiet: a truncated corpus still exits 2 and says so.
  defp guard_corpus!(files, announce? \\ true) do
    set = MapSet.new(files)
    missing = Enum.reject(@sentinels, &MapSet.member?(set, &1))

    cond do
      files == [] ->
        refuse(["corpus is EMPTY — nothing to census"])

      missing != [] or length(files) < @corpus_floor ->
        refuse(
          [
            "#{length(files)} file(s); the api/lib corpus is #{@corpus_floor}+ and MUST carry every route-bearing module"
          ] ++
            Enum.map(missing, &"MISSING route-bearing sentinel: #{&1}") ++
            [
              "A corpus holding only the files that CARRY `ok: true` parses cleanly and reports",
              "write=0 for every site, with no error and no warning (PDS-D449a). That green is a lie:",
              "the write verbs live in the callees, which such a corpus does not contain."
            ]
        )

      announce? ->
        p("corpus      #{length(files)} .ex files under api/lib · sentinels present: #{Enum.join(@sentinels, ", ")}")
        p("")

      true ->
        :ok
    end
  end

  defp refuse(lines) do
    p("")
    p("REFUSED: TRUNCATED CORPUS")
    Enum.each(lines, &p("  " <> &1))
    p("")
    p("The census does not report zeros it cannot stand behind. Exit 2.")
    System.halt(2)
  end

  # ---------------------------------------------------------------- parsing

  defp parse_file(path) do
    src = File.read!(path)
    lines = String.split(src, "\n")

    textual =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        List.duplicate({n, :atom}, count(line, "ok: true")) ++
          List.duplicate({n, :string}, count(line, "\"ok\" => true"))
      end)

    opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      emit_warnings: false,
      unescape: false
    ]

    ast =
      case Code.string_to_quoted(src, opts) do
        {:ok, ast} -> ast
        {:error, _} -> :parse_error
      end

    {defs, sites, imports} =
      case ast do
        :parse_error -> {[], [], []}
        ast -> {collect_defs(ast, path), collect_sites(ast, path), collect_imports(ast)}
      end

    %{
      path: path,
      src: src,
      textual: textual,
      textual_count: length(textual),
      parse_error?: ast == :parse_error,
      imports: imports,
      defs: attribute(defs, sites) |> elem(0),
      sites: attribute(defs, sites) |> elem(1)
    }
  end

  defp count(hay, needle), do: length(:binary.matches(hay, needle))

  # -- site collection (pairs, with pattern context) --------------------------

  # THE CONTAINER IS RETAINED (PDS-D498). Wave 35's walker recorded {path, line, pattern?,
  # key} and threw the enclosing node away, so `expr_fp` — the half of the register key
  # that survives a line shift — was not computable at all. `expr` is the innermost
  # enclosing AST node that is NOT the pair itself: for `json(conn, %{ok: true, id: id})`
  # it is the `%{}` node, which is what distinguishes two receipts in one function.
  defp collect_sites(ast, path) do
    {_, acc} = pairs(ast, false, [], nil)

    acc
    |> Enum.map(fn {line, pat?, kind, expr} ->
      %{path: path, line: line, pattern?: pat?, key: kind, def: nil, expr: expr}
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp pairs(node, pat?, acc, box) do
    case node do
      {:=, _, [lhs, rhs]} ->
        acc = pairs(lhs, true, acc, node) |> elem(1)
        pairs(rhs, pat?, acc, node)

      {:<-, _, [lhs, rhs]} ->
        acc = pairs(lhs, true, acc, node) |> elem(1)
        pairs(rhs, pat?, acc, node)

      {:->, _, [heads, body]} ->
        acc = pairs(heads, true, acc, node) |> elem(1)
        pairs(body, false, acc, node)

      {op, _, [head, body]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        acc = pairs(head, true, acc, node) |> elem(1)
        pairs(body, false, acc, node)

      {op, _, [head]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        pairs(head, true, acc, node)

      {left, right} ->
        acc =
          case pair_site(left, right) do
            nil -> acc
            {line, kind} -> [{line, pat?, kind, box} | acc]
          end

        acc = pairs(left, pat?, acc, box) |> elem(1)
        pairs(right, pat?, acc, box)

      list when is_list(list) ->
        {node, Enum.reduce(list, acc, fn el, a -> pairs(el, pat?, a, box) |> elem(1) end)}

      {f, _, args} ->
        acc = pairs(f, pat?, acc, node) |> elem(1)
        {node, if(is_list(args), do: pairs(args, pat?, acc, node) |> elem(1), else: acc)}

      _ ->
        {node, acc}
    end
    |> case do
      {_, _} = ok -> ok
      acc when is_list(acc) -> {node, acc}
    end
  end

  defp pair_site(left, right) do
    with {:lit, key, meta} <- lit(left),
         {:lit, true, _} <- lit(right) do
      # A bare 2-tuple `{:ok, true}` and a keyword pair `ok: true` quote IDENTICALLY.
      # Only the key's metadata separates them: `format: :keyword` for `ok:`, `assoc:`
      # for `"ok" =>`. Without this, ~100 ordinary `{:ok, true}` tuples enter the census.
      case {key, meta[:format], meta[:assoc]} do
        {:ok, :keyword, _} -> {meta[:line], :atom}
        {"ok", _, [_ | _]} -> {meta[:line], :string}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp lit({:__block__, meta, [v]}) when is_atom(v) or is_binary(v) or is_number(v),
    do: {:lit, v, meta}

  defp lit(_), do: :no

  # -- def collection ---------------------------------------------------------

  defp collect_defs(ast, path), do: defs(ast, [], path, [])

  defp defs(node, mod, path, acc) do
    case node do
      {:defmodule, _, [{:__aliases__, _, segs}, body]} ->
        defs(body, mod ++ segs, path, acc)

      {op, meta, [head | rest]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        {name, req, arity, hmeta} = head_sig(head)
        body = List.first(rest)

        rec = %{
          module: mod,
          name: name,
          arity: arity,
          req: req,
          path: path,
          line: meta[:line] || hmeta[:line] || 0,
          last: max_line(node, meta[:line] || 0),
          delegate: nil,
          body: body,
          head: head
        }

        [rec | acc]

      {:defdelegate, meta, [head, opts]} ->
        {name, req, arity, _} = head_sig(head)
        target = kw(opts, :to)
        as = kw(opts, :as)

        rec = %{
          module: mod,
          name: name,
          arity: arity,
          req: req,
          path: path,
          line: meta[:line] || 0,
          last: meta[:line] || 0,
          delegate: {target, as || name},
          body: nil,
          head: head
        }

        [rec | acc]

      list when is_list(list) ->
        Enum.reduce(list, acc, &defs(&1, mod, path, &2))

      {a, b} ->
        acc |> then(&defs(a, mod, path, &1)) |> then(&defs(b, mod, path, &1))

      {_f, _, args} when is_list(args) ->
        Enum.reduce(args, acc, &defs(&1, mod, path, &2))

      _ ->
        acc
    end
  end

  # -- import collection ------------------------------------------------------
  #
  # WHY THIS EXISTS (PDS wave 34). raw_calls/1 emits an IMPORTED call as {:local, f},
  # and callees/2 resolves {:local, f} only inside the CALLING module — so an imported
  # helper is not merely mis-attributed, it is STRUCTURALLY INVISIBLE to the call
  # graph. The corpus's one honest `select:`-inside-the-update writer,
  # Barkpark.Tasks.Internal.fenced_content_write/4 (internal.ex:50, `select: d` at
  # :54), is reached ONLY by `import Barkpark.Tasks.Internal, only: [...]`, so wave
  # 33's lens could never name it. Each entry is {calling_module_segs, fun_name,
  # imported_module_segs}.
  defp collect_imports(ast), do: imports(ast, [], [])

  defp imports(node, mod, acc) do
    case node do
      {:defmodule, _, [{:__aliases__, _, segs}, body]} ->
        imports(body, mod ++ segs, acc)

      {:import, _, [{:__aliases__, _, target} | opts]} ->
        Enum.reduce(import_only_names(opts), acc, &[{mod, &1, target} | &2])

      list when is_list(list) ->
        Enum.reduce(list, acc, &imports(&1, mod, &2))

      {a, b} ->
        acc |> then(&imports(a, mod, &1)) |> then(&imports(b, mod, &1))

      {_f, _, args} when is_list(args) ->
        Enum.reduce(args, acc, &imports(&1, mod, &2))

      _ ->
        acc
    end
  end

  # Only `only: [f: a]` is honoured. A bare `import Mod` or an `except:` list would
  # make the graph guess at which names came from where; this census does not guess.
  defp import_only_names(opts) do
    {_, only} =
      Macro.prewalk(opts, nil, fn
        {k, v} = n, acc ->
          case lit(k) do
            {:lit, :only, _} -> {n, acc || v}
            _ -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    case only do
      nil -> []
      node -> fun_arity_names(node)
    end
  end

  defp fun_arity_names(node) do
    {_, names} =
      Macro.prewalk(node, [], fn
        {k, v} = n, acc ->
          case {lit(k), lit(v)} do
            {{:lit, f, _}, {:lit, a, _}} when is_atom(f) and is_integer(a) -> {n, [f | acc]}
            _ -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(names)
  end

  # THE ARITY KEY IS A RANGE, NOT A SCALAR (PDS-D491). `def f(a, b \\ nil)` is callable
  # at 1 AND at 2, so a head declares `required..total`, not one number. The scalar
  # spelling was measured and is a REGRESSION — it drops every edge into a defaulted
  # head and routes 50/13/28 where the range spelling routes what this file prints.
  defp head_sig({:when, _, [h | _]}), do: head_sig(h)

  defp head_sig({name, meta, args}) when is_atom(name) and is_list(args),
    do: {name, required_arity(args), length(args), meta}

  defp head_sig({name, meta, _}) when is_atom(name), do: {name, 0, 0, meta}
  defp head_sig(_), do: {:__unknown__, 0, 0, []}

  defp required_arity(args) do
    Enum.count(args, fn
      {:\\, _, [_, _]} -> false
      _ -> true
    end)
  end

  defp kw(opts, key) do
    opts = if is_list(opts), do: opts, else: []

    Enum.find_value(opts, fn {k, v} ->
      case lit(k) do
        {:lit, ^key, _} -> alias_or_atom(v)
        _ -> nil
      end
    end)
  end

  defp alias_or_atom({:__aliases__, _, segs}), do: segs

  defp alias_or_atom(other) do
    case lit(other) do
      {:lit, v, _} when is_atom(v) -> v
      _ -> nil
    end
  end

  defp max_line(node, seed) do
    {_, m} =
      Macro.prewalk(node, seed, fn
        {_, meta, _} = n, acc when is_list(meta) ->
          l = Keyword.get(meta, :line, 0)
          e = get_in(meta, [:end, :line]) || get_in(meta, [:closing, :line]) || 0
          {n, Enum.max([acc, l, e])}

        n, acc ->
          {n, acc}
      end)

    m
  end

  # attribute each site to the innermost def containing its line
  defp attribute(defs, sites) do
    sites =
      Enum.map(sites, fn s ->
        owner =
          defs
          |> Enum.filter(&(&1.line <= s.line and s.line <= &1.last))
          |> Enum.sort_by(&(&1.last - &1.line))
          |> List.first()

        # KEEP THE OWNING CLAUSE, not just its {module, name, arity} key. Wave 33's
        # lens found the innermost containing def here and then threw the clause
        # away, and resolve_exact/2 re-resolved the key to the FIRST def of that
        # arity — 15 of 91 sites came back owned by a clause that does not contain
        # their line. The line pins the clause.
        %{s | def: owner && {owner.module, owner.name, owner.arity, owner.line}}
      end)

    {defs, sites}
  end

  # ---------------------------------------------------------------- index

  defp build_index(parsed) do
    all =
      parsed
      |> Enum.flat_map(& &1.defs)
      |> propagate_defaults()
      |> Enum.map(&Map.put(&1, :calls, raw_calls(&1)))

    by_key = Enum.group_by(all, fn d -> {d.module, d.name} end)
    by_module = Enum.group_by(all, & &1.module)

    # reverse edge, by called NAME — a receipt assembled in a helper is still a claim
    # about the caller's write (tasks_controller close/2 -> close_response/3).
    callers_by_name =
      all
      |> Enum.flat_map(fn d ->
        d.calls
        |> Enum.map(fn
          {:local, f, _a} -> {f, d}
          {:remote, _segs, f, _a} -> {f, d}
        end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # {calling_module, imported_fun} -> [imported_module_segs]
    imports =
      parsed
      |> Enum.flat_map(& &1.imports)
      |> Enum.group_by(fn {mod, f, _t} -> {mod, f} end, fn {_m, _f, t} -> t end)

    %{
      defs: all,
      by_key: by_key,
      by_module: by_module,
      modules: Map.keys(by_module),
      callers_by_name: callers_by_name,
      imports: imports
    }
  end

  # A BODILESS HEADER DECLARES DEFAULTS ITS SIBLING CLAUSE DOES NOT. `def f(a, b \\ nil)`
  # with no body, followed by `def f(a, b) do ... end`, is ONE function callable at 1..2 —
  # but only the header carries the `\\`, so per-clause `required` reads 1 and 2. The
  # minimum over every clause sharing {module, name, total_arity} is the function's real
  # required arity; without this propagation the body-carrying clause refuses the 1-arg
  # call and the edge is silently lost.
  defp propagate_defaults(defs) do
    mins =
      defs
      |> Enum.group_by(&{&1.module, &1.name, &1.arity}, & &1.req)
      |> Map.new(fn {k, reqs} -> {k, Enum.min(reqs)} end)

    Enum.map(defs, &%{&1 | req: Map.get(mins, {&1.module, &1.name, &1.arity}, &1.req)})
  end

  # THE KEY IS {module, fun, required..total}. `arity == nil` means "any" — the only
  # callers that pass nil are the ones with no call site to read an arity off.
  defp accepts?(_d, nil), do: true
  defp accepts?(d, arity), do: arity >= d.req and arity <= d.arity

  defp at_arity(cands, arity), do: Enum.filter(cands, &accepts?(&1, arity))

  defp resolve(index, mod_segs, name, arity) do
    (Map.get(index.by_key, {mod_segs, name}) ||
       (index.modules
        |> Enum.filter(&suffix?(&1, mod_segs))
        |> Enum.flat_map(&Map.get(index.by_key, {&1, name}, []))))
    |> at_arity(arity)
  end

  defp suffix?(full, segs) do
    n = length(segs)
    length(full) >= n and Enum.take(full, -n) == segs
  end

  # ---------------------------------------------------------------- routing

  defp route(site, index, max \\ @max_depth) do
    start = site.def && resolve_exact(index, site.def)

    {verbs, depth, chain} =
      case start do
        nil -> {%{}, nil, []}
        d -> bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], max)
      end

    # UP ONE, THEN DOWN. A receipt assembled in a private helper claims the CALLER's
    # write (tasks_controller.ex:587 lives in close_response/3, which touches no Repo
    # verb — the write is Tasks.close/3 in close/2, one frame up). One hop up only:
    # expanding callers transitively would reach the whole tree and mean nothing.
    {via, via_verbs} =
      if start && not Map.has_key?(verbs, :write) do
        start
        |> callers(index)
        |> Enum.reduce_while({nil, %{}}, fn c, acc ->
          {v, _, _} = bfs([{c, 1, [label(c)]}], index, MapSet.new(), %{}, nil, [], max)
          if Map.has_key?(v, :write), do: {:halt, {label(c), v}}, else: {:cont, acc}
        end)
      else
        {nil, %{}}
      end

    verbs =
      Map.merge(via_verbs, verbs, fn
        :visited, a, b -> a ++ b
        _k, a, b -> a ++ b
      end)

    Map.merge(site, %{
      verbs: verbs,
      write?: Map.has_key?(verbs, :write),
      read?: Map.has_key?(verbs, :read),
      depth: depth,
      via_caller: via,
      chain: chain,
      owner: start
    })
  end

  # callers of a def, matched on the called NAME and (for remote calls) an alias whose
  # tail matches the owning module — the same suffix rule the downward resolver uses.
  defp callers(d, index) do
    index.callers_by_name
    |> Map.get(d.name, [])
    |> Enum.filter(fn c ->
      Enum.any?(c.calls, fn
        {:local, f, a} -> f == d.name and c.module == d.module and accepts?(d, a)
        {:remote, segs, f, a} -> f == d.name and suffix?(d.module, segs) and accepts?(d, a)
      end)
    end)
    |> Enum.reject(&(&1.module == d.module and &1.name == d.name))
    |> Enum.take(12)
  end

  # ARITY FIRST, THEN THE LINE PIN. The key is {module, fun, required..total}; within the
  # clauses that accept this arity the LINE picks the exact clause, because a
  # {module, name, arity} triple names a FUNCTION and a receipt lives in ONE CLAUSE of it
  # (wave 33 threw the line away here and mis-owned 15 of 91 sites — see CLAUSE-COLLAPSE).
  defp resolve_exact(index, {mod, name, arity, line}) do
    cands = Map.get(index.by_key, {mod, name}) || []
    at = at_arity(cands, arity)

    Enum.find(at, &(&1.line == line)) ||
      List.first(at) ||
      Enum.find(cands, &(&1.line == line)) ||
      List.first(cands)
  end

  defp bfs([], _index, _seen, verbs, depth, chain, _max), do: {verbs, depth, chain}

  defp bfs([{d, depth, path} | rest], index, seen, verbs, found_at, chain, max) do
    key = {d.module, d.name, d.arity}

    if MapSet.member?(seen, key) do
      bfs(rest, index, seen, verbs, found_at, chain, max)
    else
      seen = MapSet.put(seen, key)
      hits = verb_hits(d)
      # every function the route actually entered — the evidence the shape test reads
      verbs = Map.update(verbs, :visited, [d], &[d | &1])

      verbs =
        Enum.reduce(hits, verbs, fn {kind, verb, line}, acc ->
          Map.update(acc, kind, [{verb, line, d.path, depth}], &[{verb, line, d.path, depth} | &1])
        end)

      {found_at, chain} =
        if found_at == nil and Map.has_key?(verbs, :write),
          do: {depth, path},
          else: {found_at, chain}

      # A defdelegate is a RENAME, not a call: it holds no logic that could make the
      # claim true or false, so following one costs no depth. Charging it a hop is how
      # a 24-entry facade like Barkpark.Tasks eats the whole budget and reports false.
      step = if d.delegate, do: 0, else: 1

      next =
        if depth + step > max do
          []
        else
          d
          |> callees(index)
          |> Enum.map(&{&1, depth + step, path ++ [label(&1)]})
        end

      bfs(rest ++ next, index, seen, verbs, found_at, chain, max)
    end
  end

  defp label(d), do: "#{Enum.join(d.module, ".")}.#{d.name}/#{d.arity}"

  defp verb_hits(%{delegate: {_, _}}), do: []

  defp verb_hits(%{body: nil}), do: []

  defp verb_hits(%{body: body}) do
    {_, hits} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, meta, args} = n, acc when is_list(args) ->
          last = List.last(segs)

          cond do
            last in @repo_mods and f in @write_verbs ->
              {n, [{:write, :"#{last}.#{f}", meta[:line]} | acc]}

            last in @repo_mods and f in @read_verbs ->
              {n, [{:read, :"#{last}.#{f}", meta[:line]} | acc]}

            # Repo.query/query! IS NOT A READ HERE (PDS wave 34). Every Repo.query
            # site of consequence in this corpus is `SELECT pg_advisory_xact_lock(..)`
            # — a lock acquisition, not a read of the row a receipt is about. Scored
            # as a read it was worth 6 false POST-READs on its own. An advisory-lock
            # allowlist measures identically and is more code; the clause is gone.

            true ->
              {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    hits
  end

  # callees: defdelegate target, or every local/remote call resolvable in the corpus
  defp callees(%{delegate: {target, as}} = d, index) when is_list(target),
    do: resolve(index, target, as, d.arity)

  defp callees(%{delegate: {_, _}}, _index), do: []

  defp callees(%{body: nil}, _index), do: []

  defp callees(%{module: mod} = d, index) do
    (d[:calls] || raw_calls(d))
    |> Enum.flat_map(fn
      # A {:local, f, a} with no def of that name AND ARITY in the calling module is
      # either undefined or IMPORTED — and an imported call is a real edge, so follow it.
      {:local, f, a} ->
        case at_arity(Map.get(index.by_key, {mod, f}, []), a) do
          [] -> imported_defs(index, mod, f, a)
          defs -> defs
        end

      {:remote, segs, f, a} ->
        resolve(index, segs, f, a)
    end)
    |> Enum.uniq_by(&{&1.module, &1.name, &1.arity})
  end

  defp imported_defs(index, mod, f, arity) do
    index.imports
    |> Map.get({mod, f}, [])
    |> Enum.flat_map(&resolve(index, &1, f, arity))
  end

  defp raw_calls(%{body: nil}), do: []

  defp raw_calls(%{body: body}) do
    {_, calls} =
      body
      |> expand_pipes()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc
        when is_atom(f) and is_list(args) ->
          {n, [{:remote, segs, f, length(args)} | acc]}

        {f, _, args} = n, acc when is_atom(f) and is_list(args) ->
          if Macro.special_form?(f, length(args)) or Macro.operator?(f, length(args)) do
            {n, acc}
          else
            {n, [{:local, f, length(args)} | acc]}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(calls)
  end

  # PIPE EXPANSION IS PART OF THE ARITY KEY (PDS-D491). `conn |> json(body)` quotes as
  # json/1 and calls json/2; reading the arity straight off the node would refuse the
  # real callee at exactly the places this corpus pipes most (controllers, contexts).
  # prewalk re-enters the rewritten node, so `a |> b() |> c()` unwinds fully.
  defp expand_pipes(body) do
    Macro.prewalk(body, fn
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) ->
        {dot, meta, [lhs | args]}

      {:|>, _, [lhs, {f, meta, args}]} when is_atom(f) and is_list(args) ->
        {f, meta, [lhs | args]}

      n ->
        n
    end)
  end

  # ---------------------------------------------------------------- classify

  defp classify(site, index) do
    owner = site.owner
    shape = shape_of(site, owner, index)
    Map.put(site, :shape, shape)
  end

  defp shape_of(_site, nil, _index), do: {"UNCLASSIFIED", "no enclosing function resolved"}

  defp shape_of(site, owner, _index) do
    # The shape lives in the ROUTE, not only in the emitting function: the write and the
    # post-read that would back it are usually three frames down from the receipt.
    visited = Map.get(site.verbs, :visited, [owner])
    hits = verb_hits(owner)
    local_writes = for {:write, v, l} <- hits, do: {v, l}
    local_reads = for {:read, v, l} <- hits, do: {v, l}

    # Only the functions that ACTUALLY WRITE (plus the one that prints the receipt) can
    # supply a post-read. Accepting evidence from any function the route touched would
    # let an unrelated read three modules away certify the claim — over-claiming
    # compliance is the disease this census exists to find.
    candidates = Enum.filter(visited, &writes?/1) ++ [owner]

    selecting = Enum.find(candidates, &has_select_in_update?(&1.body))
    reading_after = Enum.find(candidates, &post_read_in?/1)
    cas = Enum.find(candidates, &cas_confirmed?/1)

    cond do
      site.write? and selecting ->
        {"POST-READ",
         "ARM 1 ADMISSIBLE (not proven): #{label(selecting)} writes with `select:` INSIDE the update query — the row is measured after the change (`returning:` is silently ignored by update_all, auth.ex:139-141, and is NOT this). This does NOT prove the selected row reaches the printed value"}

      site.write? and reading_after ->
        {"POST-READ",
         "ARM 2 ADMISSIBLE (weaker, line-order only): #{label(reading_after)} reads back after its own write — necessary, NOT sufficient"}

      site.write? and cas ->
        {"CAS-CONFIRMED-ECHO",
         "#{label(cas)} matches its update_all result against a literal row count — the claim dies if 0 rows moved"}

      span = catch_all_span(site, owner) ->
        {"CATCH-ALL-TO-SUCCESS",
         "the receipt is emitted INSIDE a failure-discarding clause at :#{elem(span, 0)}-#{elem(span, 1)} (head `#{elem(span, 2)}`) whose body renders `ok: true` — every outcome the earlier clauses did not name, including every failure, is answered with success"}

      true ->
        {"UNCLASSIFIED", evidence(site, local_writes, local_reads)}
    end
  end

  defp writes?(d), do: Enum.any?(verb_hits(d), fn {k, _, _} -> k == :write end)

  defp post_read_in?(d) do
    hits = verb_hits(d)
    post_read?(for({:write, v, l} <- hits, do: {v, l}), for({:read, v, l} <- hits, do: {v, l}))
  end

  defp evidence(site, writes, reads) do
    parts =
      [
        if(site.write?, do: "write-routed at depth #{site.depth}", else: nil),
        if(site.read? and not site.write?, do: "read-routed only", else: nil),
        if(!site.write? and !site.read?, do: "no Repo verb within depth #{@max_depth}", else: nil),
        if(writes != [], do: "local writes: #{Enum.map_join(writes, ",", &elem(&1, 0))}", else: nil),
        if(reads != [], do: "local reads: #{Enum.map_join(reads, ",", &elem(&1, 0))}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "; ")
  end

  defp post_read?([], _), do: false
  defp post_read?(_, []), do: false

  defp post_read?(writes, reads) do
    w = writes |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    r = reads |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    w != [] and r != [] and Enum.max(r) > Enum.min(w)
  end

  # `returning:` is a BLIND lens — Ecto silently ignores it on update_all (auth.ex:139-141).
  # The honest idiom is `select:` INSIDE the update query.
  #
  # KNOWN RESIDUAL UNSOUNDNESS, NAMED AND NOT FIXED HERE (PDS wave 34). This prewalks the
  # WHOLE function body for ANY `from(..., select: ...)`; it does not require the `select:`
  # to be on the query that is UPDATED. move.ex:230 is a plain READ query carrying a
  # `select:` inside a non-writing function, so it costs nothing today — but the predicate
  # is unsound by construction, which is exactly why every POST-READ it admits is printed
  # as ADMISSIBLE and never as proven. Filed as its own row.
  defp has_select_in_update?(nil), do: false

  defp has_select_in_update?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:from, _, args} = n, acc when is_list(args) ->
          {n, acc or kw_present?(args, :select)}

        n, acc ->
          {n, acc}
      end)

    found
  end

  defp kw_present?(args, key) do
    Enum.any?(List.flatten(args), fn
      {k, _} ->
        case lit(k) do
          {:lit, ^key, _} -> true
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp cas_confirmed?(%{body: nil}), do: false

  defp cas_confirmed?(%{body: body} = d) do
    updates? = Enum.any?(verb_hits(d), fn {k, v, _} -> k == :write and v == :"Repo.update_all" end)
    updates? and int_tuple_match?(body)
  end

  defp int_tuple_match?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:{}, _, [a, _]} = n, acc -> {n, acc or int_lit?(a)}
        {a, _} = n, acc -> {n, acc or int_lit?(a)}
        n, acc -> {n, acc}
      end)

    found
  end

  defp int_lit?(node) do
    case lit(node) do
      {:lit, v, _} when is_integer(v) -> true
      _ -> false
    end
  end

  # ------------------------------------------------------- CATCH-ALL-TO-SUCCESS
  #
  # THIS ARM REPLACED A FALL-THROUGH (PDS wave 35). Its predecessor, UNREACHABLE-ERROR,
  # tested `not error_arm?(owner.body)` — no write guard, no positive evidence, and it sat
  # directly above the UNCLASSIFIED default, so it absorbed every site the earlier arms had
  # not claimed and read 26. Hand measurement says 3. Among the 23 it invented was
  # auth_controller.ex:417, the charter's OWN declared-honest anti-enumeration control: a
  # lens that accuses its own control is not measuring, it is asserting.
  #
  # THE TEST IS NOW POSITIVE, and it is a CONJUNCTION OF THREE, none of which may be
  # dropped on the grounds that it is individually inert:
  #
  #   1. A FAILURE-DISCARDING CLAUSE HEAD — one head argument, a variable whose name starts
  #      with `_`. WIDE on purpose: bare `_` AND `_other`, `_err`, `_reason`. A literal or
  #      structural head (`{:ok, id}`, `{:honeypot}`, `"ping"`) NAMES what it matched and is
  #      therefore not discarding.
  #   2. THE CLAUSE BODY RENDERS AN `ok: true` LITERAL PAIR.
  #   3. CONTAINMENT — the receipt's own line falls inside that clause's span.
  #
  # WHY NO `site.write?` GUARD (PDS-D476a, measured, not argued). Under a NARROW head (bare
  # `_` only) a write guard is inert, 2 -> 2. Under the SHIPPED wide head it collapses the
  # arm 3 -> 2 and deletes exactly github_webhook_controller.ex:87, whose route is unrouted —
  # the one site widening the head buys. Wide-head-plus-write-guard IS narrow-head, the
  # UNCLASSIFIED denominator silently moves 74 -> 75, and the declared register's CATCH-ALL
  # row stops corresponding to anything the arm suppresses, with no diff that looks like a
  # bucket change. A shape test that reads the route is not a shape test.
  #
  # WHY renders_ok_true?/1 SURVIVES BEING A TAUTOLOGY (PDS-D476b). Given containment it can
  # never be false: collect_sites/2 only emits a site ON an `ok: true` pair line, so a
  # contained site IS the pair. It stays because the two are inert only GIVEN EACH OTHER —
  # drop both and the arm fires on 11 and re-accuses auth_controller.ex:417. Deleting a
  # conjunct because it is currently redundant is how a fall-through grows back.
  defp catch_all_span(_site, %{body: nil}), do: nil

  defp catch_all_span(site, %{body: body}) do
    body
    |> discarding_success_clauses()
    |> Enum.find(fn {lo, hi, _head} -> lo <= site.line and site.line <= hi end)
  end

  defp discarding_success_clauses(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:->, meta, [heads, clause_body]} = n, acc ->
          with {:discarding, name} <- discarding_head(heads),
               true <- renders_ok_true?(clause_body) do
            lo = meta[:line] || 0
            {n, [{lo, max_line(clause_body, lo), name} | acc]}
          else
            _ -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.sort(acc)
  end

  # ONE head argument, and it is a variable named `_...`. A guarded head (`_x when ...`)
  # narrows what it matches, so it is not a catch-all and is not unwrapped here.
  defp discarding_head([{name, _meta, ctx}]) when is_atom(name) and is_atom(ctx) do
    str = Atom.to_string(name)
    if String.starts_with?(str, "_"), do: {:discarding, str}, else: :no
  end

  defp discarding_head(_), do: :no

  defp renders_ok_true?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {left, right} = n, acc -> {n, acc or pair_site(left, right) != nil}
        n, acc -> {n, acc}
      end)

    found
  end

  # ------------------------------------------------------- declared register lookup
  #
  # KEYED ON THE FOUR-FIELD SITE KEY, NEVER {path, line} (PDS-D521). The line-keyed
  # spelling SILENTLY RESURRECTED A FINDING: one blank line inserted seven lines above
  # github_webhook_controller.ex:87 took `0 undeclared of 1 fired` -> `1 undeclared of 1
  # fired` — a false accusation against a committed basis — and flipped this register's
  # own status line to a FALSE sentence, at exit 0 in both runs. The line is now printed
  # (tracked live off the resolved site) and never matched on.
  defp declared_for(%{path: _} = site) do
    key = site_key(site)
    Enum.find(@declared, &(&1.key == key))
  end

  defp declared_for(_), do: nil

  # ---------------------------------------------------------------- register key
  #
  # WHAT --keys IS FOR. The hand-bucket register names sites; a register keyed on
  # `path:line` orphans every row the moment somebody inserts a line above one. The key
  # printed here is {path, module.name/arity, head_hash, expr_fp} — NO LINE NUMBER — so a
  # clause inserted above a registered site produces neither an orphan nor an arrival.
  #
  # THE NORMALISER IS THE TOTAL METADATA DROP (PDS-D498): `{f, _meta, a} -> {f, [], a}` on
  # every node, then `:erlang.phash2` OF THE TERM. It is NOT PDS-D477's partial drop of 11
  # known metadata keys followed by a phash2 of an `inspect` STRING. The two are
  # partition-identical inside every one of this corpus's {path, mfa} groups, so nothing is
  # lost — but the total drop is immune to an Elixir minor emitting a NEW metadata key,
  # which under a partial drop silently re-keys every row. THE TWO SPELLINGS PRODUCE
  # DIFFERENT INTEGERS FOR THE SAME SITE (capabilities.ex visible?/2 is 83655895 under the
  # partial drop and 52289869 under this one) — never transcribe a hash across normalisers.
  #
  # EDITING drop_meta/1, head_hash/1 OR expr_fp/1 IS A RE-KEY MIGRATION, not a refactor:
  # every register row keyed under the old spelling orphans at once. Bump @key_normaliser
  # in the same commit so the register can see which spelling produced its integers.
  #
  # WHAT head_hash CANNOT DISCRIMINATE — DERIVED UNDER THIS NORMALISER, not transcribed.
  # Across all 17,620 defs it collides in exactly 3 buckets (6 defs) WITHIN a
  # {path, module.name/arity} group, and 0 times within the 75 site-owning groups. Only
  # ONE of the three is the benign bodiless header (plugins/capabilities.ex visible?/2
  # :144/:155, where :144 is the header and :155 the last clause); the other TWO are two
  # DISTINCT functions inside two `defimpl Inspect, for: ...` blocks
  # (plugins/github/errors.ex :94/:138, plugins/indx/errors.ex :118/:137) that this walker
  # cannot tell apart, because it reads the head and defimpl reuses it verbatim.
  #
  # CORPUS-WIDE — ignoring path and mfa — it is 912 groups over 2,543 defs (`def all()` is
  # byte-identical in 7 modules; the widest groups are init/1 at 53 defs and call/2 at 39).
  # THE PATH AND THE MFA ARE CARRYING THAT LOAD, which is why the key is a 4-tuple and not
  # a hash. NOTE: the wave brief recorded 913 over 2,544 for this figure — re-derived here
  # it is 912 over 2,543. The corpus-wide partition is NOT covered by the two normalisers'
  # within-group partition identity, so that number does not survive a spelling change and
  # is not quotable across one. capabilities.ex visible?/2 hashes 52289869 here.
  @key_normaliser "total-meta-drop/phash2-term/v1"

  defp drop_meta(ast) do
    Macro.prewalk(ast, fn
      {f, meta, a} when is_list(meta) -> {f, [], a}
      n -> n
    end)
  end

  defp fp(nil), do: "-"
  defp fp(node), do: node |> drop_meta() |> :erlang.phash2() |> to_string()

  defp head_hash(%{owner: %{head: head}}), do: fp(head)
  defp head_hash(_), do: "-"

  defp expr_fp(%{expr: expr}), do: fp(expr)
  # THE `_` FALLBACK MATCHES head_hash/1 AND key_mfa/1 (PDS-D521). Without it, site_key/1
  # raises FunctionClauseError on any map that is not a collected site — which is exactly
  # what a register lookup does when a caller hands it a def record by mistake.
  defp expr_fp(_), do: "-"

  defp key_mfa(%{owner: owner}) when not is_nil(owner), do: label(owner)
  defp key_mfa(_), do: "?"

  # THE ONE SPELLING OF THE KEY. Every register — @declared and @register — joins on this
  # and on nothing else. Line and CLASS are both excluded: a class in the key means every
  # honest lens correction re-keys and orphans rows, which is the ratchet eating itself.
  defp site_key(s), do: {s.path, key_mfa(s), head_hash(s), expr_fp(s)}

  # STDOUT IS TSV AND NOTHING ELSE — one line per emitted site, so a consumer can read it
  # with `cut` and a `wc -l` against it means what it says. The one-line summary goes to
  # STDERR for the same reason.
  defp keys_run(opts) do
    files = corpus(opts)
    guard_corpus!(files, false)

    parsed = Enum.map(files, &parse_file/1)
    index = build_index(parsed)
    sites = Enum.flat_map(parsed, & &1.sites)
    {ast_sites, _phantoms} = split_phantoms(parsed, sites)
    {_consumers, emitted} = Enum.split_with(ast_sites, & &1.pattern?)
    routed = Enum.map(emitted, &route(&1, index))

    routed
    |> Enum.sort_by(&{&1.path, &1.line})
    |> Enum.each(fn s ->
      {path, mfa, hh, fp} = site_key(s)
      IO.puts(Enum.join([path, mfa, hh, fp], "\t"))
    end)

    IO.puts(
      :stderr,
      "keys #{length(routed)} · emitted #{length(emitted)} · normaliser #{@key_normaliser}"
    )

    System.halt(0)
  end

  # ---------------------------------------------------------------- reporting

  defp split_phantoms(parsed, sites) do
    ast_sites = sites

    ast_by_file =
      ast_sites
      |> Enum.group_by(& &1.path)
      |> Map.new(fn {p, l} -> {p, Enum.frequencies(Enum.map(l, & &1.line))} end)

    phantoms =
      Enum.flat_map(parsed, fn f ->
        seen = Map.get(ast_by_file, f.path, %{})

        f.textual
        |> Enum.frequencies()
        |> Enum.flat_map(fn {{line, _kind}, n} ->
          have = Map.get(seen, line, 0)
          extra = n - have

          if extra > 0 do
            List.duplicate(%{path: f.path, line: line, why: phantom_why(f, line)}, extra)
          else
            []
          end
        end)
      end)

    {ast_sites, phantoms}
  end

  # a textual `ok: true` the AST does not carry as an `:ok`/`"ok"` pair is either a
  # DIFFERENT KEY (`db_ok: true`) or prose inside a @doc/comment/string.
  defp phantom_why(f, line) do
    text = f.src |> String.split("\n") |> Enum.at(line - 1, "")

    cond do
      String.contains?(text, "_ok: true") ->
        key =
          text
          |> String.split("ok: true")
          |> List.first()
          |> String.split(~r/[^A-Za-z0-9_]/)
          |> List.last()

        "WRONG KEY — `#{key}ok: true` is not `ok: true`"

      String.contains?(text, "#") ->
        "prose in a comment"

      true ->
        "prose in a @doc/@moduledoc/string (no AST pair on this line)"
    end
  end

  defp report_lens(textual, ast_sites, phantoms, consumers, emitted) do
    p("THE POPULATION (derived here, not inherited)")
    p(String.duplicate("-", 78))
    row("textual occurrences", textual, nil, :textual)
    row("  AST-literal pairs", length(ast_sites), nil, :ast)
    row("  phantoms", length(phantoms), nil, :phantom)

    Enum.each(Enum.sort_by(phantoms, &{&1.path, &1.line}), fn ph ->
      p("      #{short(ph.path)}:#{ph.line} — #{ph.why}")
    end)

    row("  consumers (pattern position, NOT emitters)", length(consumers), nil, :consumer)

    Enum.each(Enum.sort_by(consumers, &{&1.path, &1.line}), fn c ->
      p("      #{short(c.path)}:#{c.line} — matches a REMOTE response, does not make a claim")
    end)

    row("EMITTED success claims", length(emitted), nil, :emitted)
    p("")
  end

  # CARRIER FILES, DERIVED — the number the @sentinels comment used to hardcode as 27.
  # BOTH readings are printed because they differ and neither is the obvious one: a file
  # can carry a textual occurrence that is pure prose (the phantom set) and so hold no AST
  # pair at all. A single integer here would be a lens with its lens filed off.
  defp report_carriers(parsed, ast_sites) do
    textual_files = Enum.count(parsed, &(&1.textual_count > 0))
    ast_files = ast_sites |> Enum.map(& &1.path) |> Enum.uniq() |> length()

    p("  carrier files          #{ast_files} hold an AST-literal pair · #{textual_files} hold a textual occurrence")
    p("  A CARRIERS-ONLY CORPUS IS THE TRAP (PDS-D449a): those #{ast_files} files parse cleanly and")
    p("  report write=0 for every site, with no error and no warning. The write verbs live in")
    p("  the #{length(parsed) - textual_files} files that carry no receipt at all.")
    p("")
  end

  defp report_split(classified) do
    w = Enum.count(classified, & &1.write?)
    r = Enum.count(classified, &(not &1.write? and &1.read?))
    u = Enum.count(classified, &(not &1.write? and not &1.read?))

    p("WHAT EACH CLAIM IS ABOUT (route-following through defdelegate, depth #{@max_depth})")
    p(String.duplicate("-", 78))
    row("write-routed  (claims a state change)", w, nil, :write)
    row("read-routed   (claims a read)", r, nil, :read)
    row("unrouted      (no Repo verb reached)", u, nil, :unrouted)
    p("")
    p("  #{w} IS A FLOOR, NEVER A CEILING. The #{u} unrouted sites are unrouted because this")
    p("  lens gave up at depth #{@max_depth} or could not resolve an alias — not because they")
    p("  touch no state. PDS-D448 judged them almost certainly writes. Read the write count")
    p("  as \"at least #{w} success claims are about a state change\".")
    p("")
    report_clause_collapse(classified)
  end

  # ATTRIBUTION INTEGRITY, PRINTED. Every site must be owned by a def clause whose line
  # range CONTAINS it. Wave 33's lens read 15 of 91 here — it found the innermost clause
  # and then re-resolved the {module, name, arity} key to the FIRST clause of that arity
  # (bulldocs_ingest_controller.ex:630, inside the batch clause of apply_op/2 at :604,
  # came back owned by the single-op clause at :693). A site owned by a clause that does
  # not contain it makes every downstream evidence claim about the wrong code.
  # THE FAIL-OPEN IS CLOSED (PDS wave 36). This function used to filter `& &1.owner` FIRST
  # and only then reject the sites whose owner does not contain them — so a site the
  # resolver could not own AT ALL (owner == nil) was neither collapsed nor counted, and the
  # number printed here read 0 while attribution had failed outright. An unowned site is
  # the WORST attribution failure available, not the absence of one; it is counted here.
  defp report_clause_collapse(classified) do
    {owned, unowned} = Enum.split_with(classified, & &1.owner)
    mis_owned = Enum.reject(owned, &(&1.owner.line <= &1.line and &1.line <= &1.owner.last))
    n = length(mis_owned) + length(unowned)

    p("  CLAUSE-COLLAPSE  #{n} of #{length(classified)} sites NOT attributed to a def clause that")
    p("  contains their line — #{length(mis_owned)} owned by a clause that does not contain them, #{length(unowned)} owned")
    p("  by no clause at all (0 is correct; wave 33's shipped lens read 15).")

    Enum.each(Enum.sort_by(mis_owned, &{&1.path, &1.line}), fn s ->
      p("      #{short(s.path)}:#{s.line} — owned by #{label(s.owner)} at :#{s.owner.line}-#{s.owner.last}")
    end)

    Enum.each(Enum.sort_by(unowned, &{&1.path, &1.line}), fn s ->
      p("      #{short(s.path)}:#{s.line} — NO OWNING CLAUSE RESOLVED; every evidence line about this site is about nothing")
    end)

    p("")
    n
  end

  # WHY THE FLOOR IS A FLOOR, shown rather than asserted. The write count is a function
  # of the depth budget, not a property of the code: a controller that calls a context
  # that calls a query builder that calls Repo is 4 hops, and depth 3 cannot see it.
  defp report_depth_sweep(emitted, index) do
    p("THE FLOOR MOVES WITH THE LENS (depth sensitivity — the drift vs PDS-D448 explained)")
    p(String.duplicate("-", 78))

    rows = Enum.map(@sweep ++ @beyond, &sweep_row(emitted, index, &1))
    {inside, beyond} = Enum.split_with(rows, &(&1.depth <= @max_depth))

    Enum.each(inside, fn r ->
      mark = if r.depth == @max_depth, do: "  <- the census depth", else: ""

      p("  depth #{r.depth}   write #{pad(r.write)}   read #{pad(r.read)}   unrouted #{pad(r.unrouted)}   POST-READ #{pad(r.post_read)}#{mark}")
    end)

    Enum.each(beyond, fn r ->
      p("  depth #{String.pad_trailing(to_string(r.depth), 2)}  write #{pad(r.write)}   read #{pad(r.read)}   unrouted #{pad(r.unrouted)}   POST-READ #{pad(r.post_read)}   (past the census depth)")
    end)

    p("")
    p("  WHY #{@max_depth} AND NOT MORE. EVERY NUMBER IN THIS PARAGRAPH IS READ OFF THE TABLE ABOVE")
    p("  (PDS wave 35 — this paragraph used to hardcode a write sweep that its own table")
    p("  refuted at depths 2 and 3, and a POST-READ figure less than half the one printed")
    p("  above it. A lens whose commentary disagrees with its own measurement is the defect")
    p("  this epic keeps filing; the false numbers are not reprinted here, only replaced.)")
    p("")
    at_max = Enum.find(rows, &(&1.depth == @max_depth))
    p("  THE ROUTE RELATION CLOSES AT #{@max_depth}. Write-routed climbs #{Enum.map_join(inside, "/", &to_string(&1.write))} across depths")
    p("  #{List.first(@sweep)}..#{@max_depth}, and then write #{at_max.write} / read #{at_max.read} / unrouted #{at_max.unrouted} is #{closure_word(rows, at_max)} at depths")
    p("  #{Enum.map_join(@beyond, ", ", &to_string/1)} — the bfs seen-set makes the reachable set a finite closure, and the")
    p("  route set is MONOTONE in the budget by construction (a larger budget explores a")
    p("  superset), so nothing is lost by stopping at the closure.")
    p("  THE SHAPE RELATION DOES NOT CLOSE THERE. POST-READ reads #{at_max.post_read} at depth #{@max_depth} and")
    p("  #{Enum.map_join(beyond, "/", &to_string(&1.post_read))} at depths #{Enum.map_join(@beyond, "/", &to_string/1)} — #{launder_phrase(rows, at_max)}. Those extra")
    p("  certifications are CROSS-ROW: at depth 7, six of them come from")
    p("  Barkpark.Webhooks.record_endpoint_failure/2 — a real `select:` on a WEBHOOK FAILURE")
    p("  COUNTER vouching for a session-revoke receipt (auth_controller.ex:329) and for")
    p("  WebAuthn registration. A read of an unrelated row is not a post-read.")
    p("  ABOVE #{@max_depth} THIS KNOB IS A COMPLIANCE DIAL, NOT A LENS. #{@max_depth} is where the route stops")
    p("  growing and the evidence has not yet started lying.")
    p("")
    p("  PDS-D448 recorded write=#{@recorded.write} read=#{@recorded.read} unrouted=#{@recorded.unrouted}. That is NOT this lens at")
    p("  depth #{@max_depth}; it is what a deeper (or hand-followed) route sees. Both are honest and")
    p("  neither is a ceiling — which is the point. A success-claim census reports the")
    p("  budget it measured with, or its integer means nothing.")
    p("")
  end

  defp sweep_row(emitted, index, d) do
    routed = Enum.map(emitted, &route(&1, index, d))
    shaped = Enum.map(routed, &classify(&1, index))

    %{
      depth: d,
      write: Enum.count(routed, & &1.write?),
      read: Enum.count(routed, &(not &1.write? and &1.read?)),
      unrouted: Enum.count(routed, &(not &1.write? and not &1.read?)),
      post_read: Enum.count(shaped, fn s -> elem(s.shape, 0) == "POST-READ" end)
    }
  end

  defp pad(n), do: String.pad_leading(to_string(n), 3)

  defp closure_word(rows, at_max) do
    beyond = Enum.filter(rows, &(&1.depth > @max_depth))

    if Enum.all?(beyond, &(&1.write == at_max.write and &1.read == at_max.read)),
      do: "IDENTICAL",
      else: "NOT identical (the closure claim no longer holds — read the table)"
  end

  defp launder_phrase(rows, at_max) do
    next = Enum.find(rows, &(&1.depth == List.first(@beyond)))

    case next && next.post_read - at_max.post_read do
      nil -> "the extra depth is not measured here"
      n when n > 0 -> "#{n} SITES LAUNDER IN AT DEPTH #{next.depth} ALONE"
      0 -> "depth #{next.depth} launders nothing in"
      n -> "depth #{next.depth} LOSES #{abs(n)} — read the table, not this sentence"
    end
  end

  defp report_shapes(classified) do
    counts = Enum.frequencies(Enum.map(classified, fn s -> elem(s.shape, 0) end))

    p("SHAPE (PDS-D453 taxonomy — six shapes, or UNCLASSIFIED; never a guess)")
    p(String.duplicate("-", 78))
    p("  READ THE POST-READ COUNT AS A CEILING, not a clean bill of health. Its evidence is")
    p("  line order — a Repo READ below a Repo WRITE inside the writing function — which is")
    p("  NECESSARY and NOT SUFFICIENT: this lens cannot prove the read is OF THE ROW that")
    p("  was written. `select:` inside the update query is the one spelling it CAN prove.")
    p("  Wave 34 confirms each one by hand; a POST-READ here is a candidate, not a verdict.")
    p("")
    p("  EVERY POST-READ BELOW IS ADMISSIBLE, NONE IS PROVEN HONEST. Even ARM 1")
    p("  (has_select_in_update?/1) only proves the update query CARRIES a `select:`; it does")
    p("  NOT prove the caller SPENDS the selected row on the value it prints. That exact")
    p("  failure mode is live in this corpus — BlockOps.fenced_paper_update/4 selects the")
    p("  saved row and its caller prints a PRE-WRITE rev. Nothing here excludes it.")
    p("")

    Enum.each(@shapes, fn sh ->
      n = Map.get(counts, sh, 0)
      note = if n == 0, do: shape_zero_note(sh), else: ""
      p(String.pad_trailing("  " <> sh, 30) <> String.pad_leading(to_string(n), 4) <> "  " <> note)
    end)

    n = Map.get(counts, "UNCLASSIFIED", 0)
    p(String.pad_trailing("  UNCLASSIFIED", 30) <> String.pad_leading(to_string(n), 4) <>
        "  the lens holds evidence but no verdict — wave 34 buckets these by hand")
    p("")
    post_read_roll(classified)
    catch_all_findings(classified)
  end

  # THE FINDINGS BLOCK. A shape count is not a finding — a NAMED site with no written basis
  # is. Every CATCH-ALL-TO-SUCCESS site that is not in the declared register is printed
  # here; a declared one is listed below it as SUPPRESSED, with its basis, so the reader can
  # see what was withheld and go read the same lines the register cites.
  defp catch_all_findings(classified) do
    all =
      classified
      |> Enum.filter(fn s -> elem(s.shape, 0) == "CATCH-ALL-TO-SUCCESS" end)
      |> Enum.sort_by(&{&1.path, &1.line})

    {declared, findings} = Enum.split_with(all, &declared_for/1)

    p("  CATCH-ALL-TO-SUCCESS FINDINGS  #{length(findings)} undeclared of #{length(all)} fired")

    if findings == [] do
      p("      none — every catch-all-to-success site carries a written basis")
    else
      Enum.each(findings, fn s ->
        p("      FINDING  #{short(s.path)}:#{s.line}  fn #{label(s.owner)}")
        p("               #{elem(s.shape, 1)}")
        p("               NO DECLARED BASIS. The caller cannot tell this receipt from the one")
        p("               the named clause above it emits, and nothing in the body says so.")
      end)
    end

    Enum.each(declared, fn s ->
      d = declared_for(s)
      p("      SUPPRESSED  #{short(s.path)}:#{s.line}  [#{d.class}, #{d.confirmation}]")
      p("                  basis: #{d.basis}")
    end)

    p("")
  end

  # THE REGISTER, PRINTED IN FULL — including the rows that suppress nothing. A register
  # that only shows up when it fires is indistinguishable from a mute list; this one is
  # readable on every run, so a row whose site the lens no longer reaches is visible as
  # documentation rather than quietly doing nothing.
  defp report_declared_register(classified) do
    fired =
      classified
      |> Enum.filter(fn s -> elem(s.shape, 0) != "UNCLASSIFIED" end)
      |> MapSet.new(&{&1.path, &1.line})

    p("DECLARED REGISTER (committed data — `declared`, the confirmation level already")
    p("shipping in internal/cli/hetzner_respost.go:197, never a new spelling)")
    p(String.duplicate("-", 78))

    by_key = Map.new(classified, &{site_key(&1), &1})

    Enum.each(@declared, fn d ->
      site = Map.get(by_key, d.key)

      # THE STATUS LINE SAYS WHAT IS ACTUALLY WITHHELD. A declared row never suppresses
      # the SHAPE — the arm still fires and the site still prints CATCH-ALL-TO-SUCCESS in
      # the roll. What it withholds is the FINDING. Writing "suppresses a fired shape"
      # would be this epic's own offence: a printed sentence that overstates what the
      # machine did.
      status =
        cond do
          site == nil ->
            "ORPHAN — this row's four-field key matches NO emitted site in this corpus (DECLARED-ROWS-RESOLVE says so above)"

          MapSet.member?(fired, {site.path, site.line}) ->
            "WITHHOLDS A FINDING — an arm fires here; the shape still prints, the finding does not"

          true ->
            "documents only — no arm fires here"
        end

      anchor = if site, do: ":#{site.line}", else: " (unresolved)"
      p("  #{short(declared_path(d))}#{anchor}  #{d.class} / #{d.confirmation}#{route_claim_tag(d)}")
      wrap("basis:  " <> d.basis, "      ", "        ")
      wrap("status: " <> status, "      ", "        ")
      wrap(d.why, "      ")
      p("")
    end)
  end

  defp route_claim_tag(%{route_claim: claim}), do: "  ·  route_claim #{claim}"
  defp route_claim_tag(_), do: ""

  defp declared_path(%{key: {path, _, _, _}}), do: path

  defp wrap(text, indent, hang \\ "") do
    width = 74 - String.length(indent)

    text
    |> String.split(" ")
    |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
      cand = if cur == "", do: word, else: cur <> " " <> word

      cond do
        # A single word longer than the column cannot be broken — emit it long rather
        # than pushing an EMPTY line, which is what the naive form did.
        cur == "" -> {lines, cand}
        String.length(cand) > width -> {[cur | lines], word}
        true -> {lines, cand}
      end
    end)
    |> then(fn {lines, cur} -> Enum.reverse([cur | lines]) end)
    |> Enum.with_index()
    |> Enum.each(fn {line, i} -> p(indent <> if(i == 0, do: "", else: hang) <> line) end)
  end

  # ------------------------------------------------------- judgment register report
  #
  # THE DISTRIBUTION IS PRINTED AND NEVER ASSERTED. Nothing below can red the build; the
  # arms that can live in integrity/10, and they check COMPLETENESS and INTEGRITY only.
  # THE THREE RESOLUTION STATES, AND WHY `:stale` IS NOT AN ORPHAN. Churn is measured at
  # ~5.5% of rows per code slice touching two controllers, and it is a PURE RE-KEY — the
  # {path, mfa} multiset holds and only expr_fp moves. A row whose four-field key no
  # longer matches but whose {path, mfa} still names exactly ONE unclaimed emitted site is
  # DEMOTED to UNJUDGED / basis-stale and REPORTED; it does not red the build, because a
  # ratchet that reds on every honest edit gets switched off. A row with no {path, mfa}
  # match, or an ambiguous one inside a multi-site group, is an ORPHAN and REDS: the
  # register would otherwise silently re-point a bought judgment at a different receipt.
  #
  # THE COMMITTED ROW IS NEVER EDITED BY THIS. The demotion is a print-time report, so a
  # reader sees the stale basis and the author's original judgment side by side.
  defp resolve_register(classified) do
    live = Map.new(classified, &{site_key(&1), &1})
    exact = MapSet.new(for r <- @register, Map.has_key?(live, r.key), do: r.key)
    by_mfa = Enum.group_by(classified, &{&1.path, key_mfa(&1)})

    {rows, _taken} =
      Enum.map_reduce(@register, MapSet.new(), fn r, taken ->
        case Map.get(live, r.key) do
          nil ->
            {path, mfa, _, _} = r.key

            cands =
              by_mfa
              |> Map.get({path, mfa}, [])
              |> Enum.reject(
                &(MapSet.member?(exact, site_key(&1)) or MapSet.member?(taken, site_key(&1)))
              )

            case cands do
              [s] -> {{r, :stale, s}, MapSet.put(taken, site_key(s))}
              _ -> {{r, :orphan, nil}, taken}
            end

          s ->
            {{r, :live, s}, taken}
        end
      end)

    rows
  end

  defp report_judgment_register(classified) do
    resolved = resolve_register(classified)

    rows =
      Enum.map(resolved, fn {r, status, site} ->
        r |> Map.put(:resolved, site) |> Map.put(:status, status)
      end)

    scope = register_scope(classified)

    p("JUDGMENT REGISTER (committed data — one row per emitted site, keyed on")
    p("{path, module.name/arity, head_hash, expr_fp}; CLASS and LINE both EXCLUDED)")
    p(String.duplicate("-", 78))

    if scope == :scoped_out do
      p("  SCOPED OUT — this corpus holds none of the #{length(@register)} registered paths, so the")
      p("  register is neither checked nor reported here. This is NOT a pass: the synthetic")
      p("  selftest fixture resolves zero rows by construction.")
      p("")
    else
      # A DEMOTED ROW COUNTS AS UNJUDGED / basis_stale IN THE DISTRIBUTION, not as the
      # verdict its author committed — otherwise the register would keep reporting a
      # PROVEN it can no longer stand behind.
      effective =
        Enum.map(rows, fn r ->
          if r.status == :stale, do: %{r | verdict: "UNJUDGED", basis: :basis_stale}, else: r
        end)

      by_verdict = Enum.frequencies(Enum.map(effective, & &1.verdict))
      by_basis = Enum.frequencies(Enum.map(effective, & &1.basis))
      other = Map.get(by_basis, :unjudged_other, 0)
      stale = Enum.filter(rows, &(&1.status == :stale))

      p("  rows #{length(@register)} · resolved to a live site #{Enum.count(rows, & &1.resolved)} · derived at 501fb9670")
      p("  VERDICTS   #{Enum.map_join(["PROVEN", "REFUTED", "UNJUDGED"], " · ", &"#{&1} #{Map.get(by_verdict, &1, 0)}")}")
      p("  PROVEN IS NOT ONE TIER: #{Map.get(by_basis, :end_to_end, 0)} end_to_end (mutation-attested) + #{Map.get(by_basis, :end_to_end_unmutated, 0)} end_to_end_unmutated")
      p("  (the conjunction was READ, its falsifier NEVER exercised). Below the line and NOT")
      p("  part of it: #{Map.get(by_basis, :side_effect_existence_only, 0)} side_effect_existence_only, which PDS-D499 maps to UNJUDGED.")
      p("  unjudged_other (PROSE REQUIRED, counted, NEVER reds): #{other}")
      p("")
      p("  BASIS DISTRIBUTION (printed, never asserted — a reclassification cannot red this)")

      by_basis
      |> Enum.sort_by(fn {b, n} -> {-n, b} end)
      |> Enum.each(fn {b, n} ->
        {cls, _falsifier, tier} = Map.get(@basis_vocab, b, {"?", "?", :advisory})
        p("      #{String.pad_trailing(to_string(b), 30)} #{String.pad_leading(to_string(n), 3)}  #{cls} · #{tier}")
      end)

      p("")
      report_register_stale(stale)
      report_register_tags(rows)
      report_register_prose(rows)
    end
  end

  defp report_register_stale([]), do: :ok

  defp report_register_stale(stale) do
    p("  BASIS-STALE DEMOTIONS (#{length(stale)}) — reported, NOT written back, and NOT a red build")

    Enum.each(stale, fn r ->
      {path, mfa, hh, fp} = r.key
      now = site_key(r.resolved)

      p("      #{short(path)}:#{r.resolved.line}  #{mfa}")
      p("        recorded #{hh}/#{fp} · current #{elem(now, 2)}/#{elem(now, 3)}")
      p("        #{r.verdict} / #{r.basis}  ->  UNJUDGED / basis_stale (the basis it was judged on has moved)")
    end)

    p("")
  end

  defp report_register_tags(rows) do
    tagged = Enum.filter(rows, &Map.has_key?(&1, :tags))

    Enum.each(tagged, fn r ->
      anchor = if r.resolved, do: ":#{r.resolved.line}", else: " (unresolved)"
      proven = Enum.count(r.tags, &(&1.verdict == "PROVEN"))

      p("  MULTI-TAG  #{short(elem(r.key, 0))}#{anchor}  ONE emitted site, #{length(r.tags)} rendered receipts")
      p("             row verdict #{r.verdict} / #{r.basis} — the WEAKEST of its tags (#{proven} of #{length(r.tags)} proven)")

      Enum.each(r.tags, fn t ->
        p("               #{String.pad_trailing(inspect(t.tag), 24)} #{String.pad_trailing(t.verdict, 9)} #{t.basis}")
      end)

      p("")
    end)
  end

  defp report_register_prose(rows) do
    prose = Enum.filter(rows, &(&1.basis == :unjudged_other))

    Enum.each(prose, fn r ->
      anchor = if r.resolved, do: ":#{r.resolved.line}", else: " (unresolved)"
      p("  UNJUDGED-OTHER  #{short(elem(r.key, 0))}#{anchor}")
      wrap(r.note, "      ", "  ")
      p("")
    end)
  end

  # THE SCOPE PREDICATE. The selftest's synthetic fixture holds none of these paths, so an
  # unconditional arm would red the selftest on its own commit. A corpus holding SOME of
  # them is the real corpus with a file missing — that is an orphan, and it reds.
  defp register_scope(classified) do
    live = MapSet.new(classified, & &1.path)
    if Enum.any?(@register, &MapSet.member?(live, elem(&1.key, 0))), do: :real, else: :scoped_out
  end

  # The POST-READ survivors, named with the arm that admitted them. A count alone lets a
  # later wave quote "N post-reads" as compliance; the roll makes the arm — and therefore
  # the strength of the evidence — impossible to quote without.
  defp post_read_roll(classified) do
    survivors =
      classified
      |> Enum.filter(fn s -> elem(s.shape, 0) == "POST-READ" end)
      |> Enum.sort_by(&{&1.path, &1.line})

    if survivors != [] do
      p("  POST-READ SURVIVORS, BY ARM (admissible, never proven)")

      Enum.each(survivors, fn s ->
        arm = if String.starts_with?(elem(s.shape, 1), "ARM 1"), do: "ARM 1 select:", else: "ARM 2 line-order"
        p("      #{short(s.path)}:#{s.line}  [#{arm}]  fn #{label(s.owner)}")
      end)

      p("")
    end
  end

  defp shape_zero_note("WRONG-ROW"),
    do: "0 DETECTED — this lens cannot see it; it needs the row identity, not the verb"

  defp shape_zero_note("DISCARDED-POST-READ"),
    do: "0 DETECTED — needs dataflow from the read to the printed value"

  defp shape_zero_note("PURE-ECHO"),
    do: "0 DETECTED — not separable from UNCLASSIFIED without dataflow; not guessed"

  defp shape_zero_note(_), do: ""

  defp report_each_site(classified) do
    p("EVERY EMITTED SITE")
    p(String.duplicate("-", 78))

    classified
    |> Enum.sort_by(&{&1.path, &1.line})
    |> Enum.each(fn s ->
      {shape, why} = s.shape

      declared = if declared_for(s), do: " DECLARED", else: ""

      p("#{short(s.path)}:#{s.line}  [#{route_tag(s)}] #{shape}#{declared}")
      p("    fn #{s.owner && label(s.owner) || "?"} — #{why}")
    end)

    p("")
  end

  # THE ROUTE BRACKET IS DISPUTABLE, AND ONLY HERE (PDS wave 35). This function reads
  # `write?`/`depth` and NEVER the shape, so no class value can retract a route it got
  # wrong — bulldocs_form_controller.ex:54, the honeypot arm that by design writes nothing,
  # printed a bare `[WRITE d5]` because its ENCLOSING function routes to a write on the
  # success path. A declared row carrying `route_claim` marks the bracket disputed at the
  # one place that prints it.
  defp route_tag(s) do
    base =
      cond do
        s.write? and s.via_caller -> "WRITE via caller #{s.via_caller}"
        s.write? -> "WRITE d#{s.depth}"
        s.read? -> "READ"
        true -> "UNROUTED"
      end

    case declared_for(s) do
      %{route_claim: claim} -> "#{base} DISPUTED — #{claim}"
      _ -> base
    end
  end

  # ----------------------------------------------------- routed population (L4a-d)

  # THE WHOLE DERIVATION, IN ONE PASS OVER THE SOURCES THE CENSUS ALREADY READ. Returns
  # :no_router when this corpus carries no router.ex — the ROUTER-PRESENCE predicate the
  # two new arms hang on, so a synthetic or truncated corpus contributes NO arm rather
  # than a PASS nobody earned.
  defp routed_derivation(parsed) do
    with %{src: src} <- Enum.find(parsed, &(&1.path == @router_path)),
         {:ok, ast} <- Code.string_to_quoted(src) do
      literal = router_literal_routes(ast)
      mounts = router_mount_sites(ast)
      specs = plugin_route_specs(parsed)

      mounted =
        for {prefix, bucket} <- mounts,
            s <- specs,
            auth_in_scope?(s.auth, bucket),
            do: {s.method, prefix <> s.path, s.module, s.action}

      # `scope "/" do post("/login", ...) end` composes to "//login". Phoenix normalises
      # that away, so the key must too — otherwise the disposition table reads as a set of
      # URLs nobody can find in the router and a reviewer cannot check a single row.
      routes =
        (literal ++ mounted)
        |> Enum.map(fn {m, path, mod, a} -> {m, normalize_route_path(path), mod, a} end)
        |> Enum.uniq()

      %{
        routes: routes,
        population: Enum.filter(routes, &routed_member?/1),
        mounts: mounts,
        specs: specs,
        macro_sites: router_macro_sites(ast),
        textual_macro: count(src, "#{@routed_resolved_macro}(")
      }
    else
      _ -> :no_router
    end
  end

  # ROUTED-WRITE. A member is a route that can MOVE STATE: the four write methods, plus
  # every LiveView mount — a LiveView's handle_event/3 writes are routed from here too,
  # and dropping them silently is the exact move this slice exists to refuse. They are
  # disposed EXCLUDED, with a count, rather than never counted.
  defp routed_member?({m, _p, _mod, _a}),
    do: m in @routed_write_methods or m == @routed_live_method

  # -- the router AST ---------------------------------------------------------
  #
  # SCOPE STATE IS {path prefix, alias segments} AND BOTH NEST. `scope "/v1", BarkparkWeb
  # do get("/x", FooController, :y) end` is GET /v1/x -> BarkparkWeb.FooController.y, and
  # reading the literal alone (as an earlier route-linkage probe did) manufactures false
  # findings on every scoped controller in the file.
  defp router_literal_routes(ast), do: Enum.reverse(router_walk(ast, {"", []}, []))

  @route_verbs ~w(get post put patch delete options head live)a

  defp router_walk({:scope, _, args}, {prefix, aliases}, acc) do
    {p, al, body} = scope_parts(args)
    router_walk(body, {prefix <> p, aliases ++ al}, acc)
  end

  defp router_walk({verb, _, args}, {prefix, aliases} = ctx, acc) when verb in @route_verbs do
    case args do
      [path, mod, action | _] when is_binary(path) ->
        [{verb, prefix <> path, alias_string(aliases, mod), action_atom(action)} | acc]

      # `live "/x", FooLive` — Phoenix's 2-arity form, action nil. Dropping it undercounts
      # the LiveView class by a third.
      [path, mod] when is_binary(path) and verb == @routed_live_method ->
        [{verb, prefix <> path, alias_string(aliases, mod), nil} | acc]

      _ ->
        router_descend(args, ctx, acc)
    end
  end

  defp router_walk({_, _, args}, ctx, acc) when is_list(args), do: router_descend(args, ctx, acc)
  defp router_walk({a, b}, ctx, acc), do: router_walk(b, ctx, router_walk(a, ctx, acc))
  defp router_walk(l, ctx, acc) when is_list(l), do: router_descend(l, ctx, acc)
  defp router_walk(_, _, acc), do: acc

  defp router_descend(nodes, ctx, acc), do: Enum.reduce(nodes, acc, &router_walk(&1, ctx, &2))

  # THE MOUNT SITES, WITH THE SCOPE THEY SIT IN. `plugin_routes(scope: :api)` inside
  # `scope "/v1/plugins"` mounts every plugin spec tagged `auth: :api` under that prefix.
  defp router_mount_sites(ast), do: Enum.reverse(mount_walk(ast, "", []))

  defp mount_walk({:scope, _, args}, prefix, acc) do
    {p, _al, body} = scope_parts(args)
    mount_walk(body, prefix <> p, acc)
  end

  defp mount_walk({@routed_resolved_macro, _, [opts]}, prefix, acc) when is_list(opts),
    # kw_lit/2, NOT the census's kw/2: kw/2 reads the literal_encoder-wrapped form that
    # parse_file/1 produces, and this walk parses router.ex PLAIN. Reading a bare `:scope`
    # key through kw/2 returns nil, every mount silently defaults to :admin, and the
    # mounted population loses ~84 routes without a single error.
    do: [{prefix, kw_lit(opts, :scope) || :admin} | acc]

  defp mount_walk({_, _, args}, prefix, acc) when is_list(args),
    do: Enum.reduce(args, acc, &mount_walk(&1, prefix, &2))

  defp mount_walk({a, b}, prefix, acc), do: mount_walk(b, prefix, mount_walk(a, prefix, acc))
  defp mount_walk(l, prefix, acc) when is_list(l), do: Enum.reduce(l, acc, &mount_walk(&1, prefix, &2))
  defp mount_walk(_, _, acc), do: acc

  # DELIBERATELY A SECOND WALK, NOT A FILTER OVER mount_walk/3. LENS-CAN-MISS asserts that
  # the blind-shape DETECTOR is alive; if killing it also killed the mount resolution, the
  # mutation would red ROUTED-POPULATION-COMPLETE as collateral and the selftest could not
  # tell which arm caught it. Separate functions, surgical mutation.
  defp router_macro_sites(ast), do: Enum.reverse(macro_walk(ast, []))

  defp macro_walk({name, meta, args}, acc) when name in @routed_macros and is_list(args),
    do: [{name, length(args), meta[:line] || 0} | Enum.reduce(args, acc, &macro_walk/2)]

  defp macro_walk({_, _, args}, acc) when is_list(args), do: Enum.reduce(args, acc, &macro_walk/2)
  defp macro_walk({a, b}, acc), do: macro_walk(b, macro_walk(a, acc))
  defp macro_walk(l, acc) when is_list(l), do: Enum.reduce(l, acc, &macro_walk/2)
  defp macro_walk(_, acc), do: acc

  defp scope_parts(args) do
    {body, rest} =
      case List.last(args) do
        [{{:__block__, _, [:do]}, b}] -> {b, Enum.drop(args, -1)}
        [{:do, b}] -> {b, Enum.drop(args, -1)}
        _ -> {nil, args}
      end

    {Enum.find_value(rest, "", &string_lit/1),
     Enum.find_value(rest, [], fn
       {:__aliases__, _, segs} -> segs
       _ -> nil
     end), body}
  end

  defp normalize_route_path(path) do
    case path |> String.split("/", trim: true) |> Enum.join("/") do
      "" -> "/"
      p -> "/" <> p
    end
  end

  defp string_lit({:__block__, _, [s]}) when is_binary(s), do: s
  defp string_lit(s) when is_binary(s), do: s
  defp string_lit(_), do: nil

  defp alias_string(prefix, {:__aliases__, _, segs}), do: Enum.join(prefix ++ segs, ".")
  defp alias_string(_, a) when is_atom(a), do: to_string(a)
  defp alias_string(_, _), do: "?"

  defp action_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp action_atom(a) when is_atom(a), do: a
  defp action_atom(_), do: :__dynamic__

  # -- the plugin specs -------------------------------------------------------
  #
  # THE DELEGATION IS RESOLVED, NOT GREPPED (PDS-D540). `OnixEdit.register_routes/1` is
  # `do: Routes.all()`. A literal-tuple grep over plugins/*.ex returns FOUR ROUTES SHORT
  # and says nothing about it; here the callback body that holds no literal tuple is
  # followed to the def it names, by SUFFIX match on the alias segments (the same trick
  # resolve/4 uses), and that def's tuples are collected instead.
  defp plugin_route_specs(parsed) do
    plugin_files = Enum.filter(parsed, &String.starts_with?(&1.path, @plugin_dir))
    bodies = Map.new(plugin_files, &{&1.path, plugin_defs(&1)})
    all_defs = bodies |> Map.values() |> Enum.concat()

    all_defs
    |> Enum.filter(fn {_mod, name, _arity, _body} -> name == :register_routes end)
    |> Enum.flat_map(fn {_mod, _n, _a, body} ->
      case route_specs(body) do
        [] -> follow_route_delegation(body, all_defs)
        specs -> specs
      end
    end)
    |> Enum.uniq()
  end

  defp plugin_defs(%{path: path, src: src}) do
    case Code.string_to_quoted(src) do
      {:ok, ast} -> plugin_def_walk(ast, [], path, [])
      _ -> []
    end
  end

  defp plugin_def_walk({:defmodule, _, [{:__aliases__, _, segs}, body]}, mod, path, acc),
    do: plugin_def_walk(body, mod ++ segs, path, acc)

  defp plugin_def_walk({op, _, [head, body]}, mod, path, acc) when op in [:def, :defp] do
    {name, _req, arity, _} = head_sig(head)
    [{mod, name, arity, body} | plugin_def_walk(body, mod, path, acc)]
  end

  defp plugin_def_walk({_, _, args}, mod, path, acc) when is_list(args),
    do: Enum.reduce(args, acc, &plugin_def_walk(&1, mod, path, &2))

  defp plugin_def_walk({a, b}, mod, path, acc),
    do: plugin_def_walk(b, mod, path, plugin_def_walk(a, mod, path, acc))

  defp plugin_def_walk(l, mod, path, acc) when is_list(l),
    do: Enum.reduce(l, acc, &plugin_def_walk(&1, mod, path, &2))

  defp plugin_def_walk(_, _, _, acc), do: acc

  defp follow_route_delegation(body, all_defs) do
    body
    |> remote_calls()
    |> Enum.flat_map(fn {segs, fun, arity} ->
      all_defs
      |> Enum.filter(fn {mod, name, ar, _b} -> name == fun and ar == arity and suffix?(mod, segs) end)
      |> Enum.flat_map(fn {_m, _n, _a, b} -> route_specs(b) end)
    end)
  end

  defp remote_calls(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc when is_atom(f) and is_list(args) ->
          {n, [{segs, f, length(args)} | acc]}

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(acc)
  end

  # A ROUTE SPEC IS A 4- OR 5-TUPLE {method, path, Module, action[, opts]}. The 4-tuple
  # form carries no opts and therefore the DEFAULT `auth: :admin` — read straight off
  # BarkparkWeb.Router.Plugins.route_in_scope?/2, which is the code that actually mounts
  # them, so this derivation and the compiler agree by construction rather than by hope.
  defp route_specs(node), do: node |> specs_walk([]) |> Enum.reverse()

  defp specs_walk({:{}, _, [m, path, mod, action]}, acc) do
    case {action_atom(m), string_lit(path)} do
      {m, p} when is_atom(m) and is_binary(p) and m != :__dynamic__ ->
        [%{method: m, path: p, module: alias_string([], mod), action: action_atom(action), auth: :admin} | acc]

      _ ->
        acc
    end
  end

  defp specs_walk({:{}, _, [m, path, mod, action, opts]}, acc) do
    case {action_atom(m), string_lit(path)} do
      {m, p} when is_atom(m) and is_binary(p) and m != :__dynamic__ ->
        [%{method: m, path: p, module: alias_string([], mod), action: action_atom(action),
           auth: kw_lit(opts, :auth) || :admin} | acc]

      _ ->
        acc
    end
  end

  defp specs_walk({_, _, args}, acc) when is_list(args), do: Enum.reduce(args, acc, &specs_walk/2)
  defp specs_walk({a, b}, acc), do: specs_walk(b, specs_walk(a, acc))
  defp specs_walk(l, acc) when is_list(l), do: Enum.reduce(l, acc, &specs_walk/2)
  defp specs_walk(_, acc), do: acc

  defp kw_lit(opts, key) when is_list(opts) do
    Enum.find_value(opts, fn
      {k, v} -> if action_atom(k) == key, do: action_atom(v)
      _ -> nil
    end)
  end

  defp kw_lit(_, _), do: nil

  # `:public` is the CALLSITE name and `:none` the SPEC-SIDE spelling of the same bucket
  # (BarkparkWeb.Router.Plugins.auth_matches_scope?/2). Missing it drops every public
  # plugin route silently.
  defp auth_in_scope?(:none, :public), do: true
  defp auth_in_scope?(auth, scope), do: auth == scope

  # -- disposition ------------------------------------------------------------
  #
  # PRECEDENCE, EXACTLY ONCE: JUDGED > ROSTERED > EXCLUDED > UNDISPOSED. JUDGED and
  # ROSTERED are DERIVED every run (a receipt that moves keeps its judgement); EXCLUDED is
  # committed data pinned to the QUAD, which is what makes an arriving route visible.
  #
  # THE JUDGED RELATION IS ONE HOP, AND SAYING SO IS THE POINT. A receipt in the action's
  # own span counts, and so does one in a def the action CALLS LOCALLY (close/2 renders
  # through close_response/3). A receipt two helpers deep reads as EXCLUDED here — that is
  # a stated limit of this relation, not a hidden one.
  defp dispose_routed(population, classified, parsed, index) do
    receipts = receipt_functions(classified)
    rostered = roster_functions(parsed)
    module_files = module_file_index(parsed)
    committed = Map.new(@routed_excluded, fn {m, p, mod, a, c} -> {{m, p, mod, a}, c} end)

    disposed =
      Enum.map(population, fn {_m, _p, mod, action} = key ->
        cond do
          reaches?(index, mod, action, receipts) -> {key, :judged, nil}
          reaches?(index, mod, action, rostered) -> {key, :rostered, nil}
          Map.has_key?(committed, key) -> {key, :excluded, Map.fetch!(committed, key)}
          true -> {key, :undisposed, nil}
        end
      end)

    live = MapSet.new(population)

    orphans =
      for {m, p, mod, a, c} <- @routed_excluded,
          not MapSet.member?(live, {m, p, mod, a}),
          Map.has_key?(module_files, mod),
          do: {{m, p, mod, a}, c}

    dupes =
      @routed_excluded
      |> Enum.frequencies_by(fn {m, p, mod, a, _c} -> {m, p, mod, a} end)
      |> Enum.filter(fn {_k, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    %{
      rows: disposed,
      judged: Enum.count(disposed, &(elem(&1, 1) == :judged)),
      rostered: Enum.count(disposed, &(elem(&1, 1) == :rostered)),
      excluded: Enum.count(disposed, &(elem(&1, 1) == :excluded)),
      undisposed: for({k, :undisposed, _} <- disposed, do: k),
      orphans: orphans,
      dupes: dupes,
      classes: Enum.frequencies(for {_k, :excluded, c} <- disposed, do: c)
    }
  end

  # {module string, function name} of every def that OWNS a register-covered emitted site.
  defp receipt_functions(classified) do
    for {_row, status, site} <- resolve_register(classified),
        status in [:live, :stale],
        %{def: {mod, name, _ar, _ln}} <- [site],
        into: MapSet.new(),
        do: {Enum.join(mod, "."), name}
  end

  # The roster names LITERALS, not functions. Resolve each literal to the def that
  # contains it, so a routed action can be disposed ROSTERED by the same anchor the
  # ROSTER-ANCHORS-EXIST arm already keeps honest.
  defp roster_functions(parsed) do
    by_path = Map.new(parsed, &{&1.path, &1})

    for r <- @roster,
        f = Map.get(by_path, r.path),
        f != nil,
        {:ok, line} <- [roster_anchor(%{r.path => f.src}, r)],
        d <- f.defs,
        d.line <= line and line <= d.last,
        into: MapSet.new(),
        do: {Enum.join(d.module, "."), d.name}
  end

  defp module_file_index(parsed) do
    for f <- parsed, d <- f.defs, into: %{}, do: {Enum.join(d.module, "."), f.path}
  end

  # Direct hit, or ONE local hop out of the action's own body.
  defp reaches?(index, module, action, targets) do
    MapSet.member?(targets, {module, action}) or
      index
      |> action_defs(module, action)
      |> Enum.any?(fn d ->
        Enum.any?(d.calls, fn
          {:local, f, _ar} -> MapSet.member?(targets, {module, f})
          _ -> false
        end)
      end)
  end

  defp action_defs(index, module, action) do
    segs = module |> String.split(".") |> Enum.map(&String.to_atom/1)
    Map.get(index.by_key, {segs, action}, [])
  end

  # -- report -----------------------------------------------------------------

  defp report_routed_population(:no_router, _classified, _parsed, _index) do
    p("ROUTED-WRITE POPULATION — SKIPPED (this corpus carries no #{@router_path})")
    p(String.duplicate("-", 78))
    p("  NOT A PASS. Without the router there is no population to dispose, so the two")
    p("  arms below contribute nothing rather than a green nobody earned.")
    p("")
    :no_router
  end

  defp report_routed_population(d, classified, parsed, index) do
    disp = dispose_routed(d.population, classified, parsed, index)
    lives = Enum.filter(d.population, fn {m, _, _, _} -> m == @routed_live_method end)
    live_mods = lives |> Enum.map(fn {_, _, mod, _} -> mod end) |> Enum.uniq() |> length()
    pairs = d.population |> Enum.map(fn {_, _, mod, a} -> {mod, a} end) |> Enum.uniq() |> length()

    p("ROUTED-WRITE POPULATION — the denominator REGISTER-COMPLETE does not have")
    p(String.duplicate("-", 78))
    p("  key         {method, path, module, action}  (the QUAD; a {module, action} key")
    p("              collapses this population #{length(d.population)} -> #{pairs} and cannot see an arriving")
    p("              route to an action it already disposed)")
    p("  derived     #{length(d.routes)} routed entries from #{@router_path} AST + #{length(d.specs)} plugin spec(s)")
    p("              mounted at #{length(d.mounts)} #{@routed_resolved_macro}/1 callsite(s)")
    p("  ROUTED-WRITE #{length(d.population)} member(s) — methods #{Enum.map_join(@routed_write_methods, "/", &to_string/1)} plus every LiveView mount")

    p("")
    p("  DISPOSITION — every member exactly once")
    p("    JUDGED    #{pad(disp.judged)}  reaches a receipt this lens emitted AND the register judged")
    p("    ROSTERED  #{pad(disp.rostered)}  reaches a hand-named roster site outside the lens")
    p("    EXCLUDED  #{pad(disp.excluded)}  committed disposition row, by class:")

    Enum.each(Enum.sort(disp.classes), fn {class, n} ->
      p("      #{String.pad_trailing(to_string(class), 22)} #{pad(n)}")
      wrap(Map.get(@routed_exclusion_classes, class, "(no prose — see @routed_exclusion_classes)"), "               ")
    end)

    p("    UNDISPOSED #{pad(length(disp.undisposed))}  <- ROUTED-POPULATION-COMPLETE reds on this")
    p("    sum       #{pad(disp.judged + disp.rostered + disp.excluded + length(disp.undisposed))}  == population #{length(d.population)}")

    p("")
    p("  EXCLUDED CLASS, PRINTED RATHER THAN ASSUMED: LiveView")
    p("    #{length(lives)} route entr(y/ies) over #{live_mods} distinct module(s). Every one is a MOUNT, not a")
    p("    {Controller, action} pair — the writes live in handle_event/3, which carries no")
    p("    routed action name at all. An arm silent about what it structurally cannot key")
    p("    inherits the exact vacuity it replaces, so the count is printed on every run.")
    p("")

    Map.put(d, :disposition, disp)
  end

  # WHAT THE ROUTE LENS ITSELF CANNOT SEE. The blind shapes are NAMED with their line, and
  # the resolved-macro count is DERIVED from the AST — a plain `grep -c` over router.ex
  # counts comment prose as callsites, which is the transcription error this epic exists
  # to kill, printed side by side so the difference is on the record.
  defp report_lens_can_miss(:no_router), do: :ok

  defp report_lens_can_miss(d) do
    {resolved, blind} = Enum.split_with(d.macro_sites, &(elem(&1, 0) == @routed_resolved_macro))

    p("WHAT THE ROUTE LENS CANNOT EXPAND (blind shapes, named and counted)")
    p(String.duplicate("-", 78))
    p("  #{length(resolved)}  #{@routed_resolved_macro}/1 callsite(s) — RESOLVED here (a plain substring count over")
    p("     router.ex says #{d.textual_macro}; the difference is comment prose, which the AST does not count)")

    if blind == [] do
      p("  0  route-generating macro callsite(s) this lens cannot expand")
    else
      p("  #{length(blind)}  route-generating macro callsite(s) this lens CANNOT expand — the routes they")
      p("     emit are absent from the population above, and that absence is stated here:")

      Enum.each(blind, fn {name, arity, line} ->
        p("       #{name}/#{arity} at #{short(@router_path)}:#{line} — expanded by a dependency this")
        p("         build-free lens never compiles, so its routes are UNCOUNTED, not judged")
      end)
    end

    p("")
  end

  # -- the two arms -----------------------------------------------------------
  #
  # THEY LIVE IN THE UNCONDITIONAL CHECKS LIST, NEVER INSIDE register_checks/2 (PDS-D541).
  # register_scope/1 returns :scoped_out unless a live corpus path matches one of
  # @register's controller paths, and router.ex is not one of them — an arm added there is
  # UNMUTATABLE: a probe hardcoded false in that branch still printed SELFTEST OK. Each arm
  # carries its OWN router-presence predicate instead.
  defp routed_checks(:no_router), do: []

  defp routed_checks(d) do
    disp = d.disposition
    {resolved, blind} = Enum.split_with(d.macro_sites, &(elem(&1, 0) == @routed_resolved_macro))
    ok? = disp.undisposed == [] and disp.orphans == [] and disp.dupes == []
    pairs = d.population |> Enum.map(fn {_, _, mod, a} -> {mod, a} end) |> Enum.uniq() |> length()

    complete_why =
      if ok? do
        "#{length(d.population)} ROUTED-WRITE member(s) <-> #{disp.judged} judged + #{disp.rostered} rostered + #{disp.excluded} excluded, both directions, no duplicate key"
      else
        Enum.join(
          [
            "#{length(disp.undisposed)} ROUTED-WRITE member(s) carry NO disposition",
            "#{length(disp.orphans)} disposition row(s) name NO live routed member",
            "#{length(disp.dupes)} disposition key(s) carry more than one row",
            "the quad key sees #{length(d.population)} member(s) where a {module, action} key sees #{pairs} — an arrival onto an already-disposed pair is INVISIBLE under the pair key"
          ] ++
            Enum.map(Enum.take(disp.undisposed, 4), fn {m, p, mod, a} ->
              "UNDISPOSED ARRIVAL #{m} #{p} -> #{mod}.#{a}"
            end) ++
            Enum.map(Enum.take(disp.orphans, 4), fn {{m, p, mod, a}, c} ->
              "ORPHANED DISPOSITION #{m} #{p} -> #{mod}.#{a} [#{c}]"
            end) ++
            Enum.map(Enum.take(disp.dupes, 4), fn {m, p, mod, a} ->
              "DUPLICATE DISPOSITION #{m} #{p} -> #{mod}.#{a}"
            end),
          " · "
        )
      end

    lens_why =
      if resolved == [] do
        "the blind-shape detector found ZERO #{@routed_resolved_macro}/1 callsite(s) in a router.ex that a plain substring count reads #{d.textual_macro} time(s) — the lens can no longer name what it cannot expand, so every population figure above is over an unknown denominator"
      else
        "#{length(resolved)} #{@routed_resolved_macro}/1 callsite(s) resolved (substring count #{d.textual_macro}; the rest is comment prose) · #{length(blind)} unexpandable macro callsite(s) NAMED: " <>
          if blind == [],
            do: "none",
            else: Enum.map_join(blind, ", ", fn {n, a, l} -> "#{n}/#{a}:#{l}" end)
      end

    [
      {"ROUTED-POPULATION-COMPLETE", ok?, complete_why},
      {"LENS-CAN-MISS", resolved != [], lens_why}
    ]
  end

  # ---------------------------------------------------------------- blind spots

  defp report_blind_spots(parsed) do
    json = sum_occ(parsed, "json(conn,")
    send_resp = sum_occ(parsed, "send_resp(conn, 2")

    put2xx =
      Enum.sum(
        for f <- parsed do
          Enum.sum(
            for pat <- ["put_status(:ok", "put_status(:created", "put_status(:accepted",
                        "put_status(:no_content", "put_status(20"],
                do: count(f.src, pat)
          )
        end
      )

    p("WHAT THIS LENS CANNOT SEE (a census that hides its blind spots is propaganda)")
    p(String.duplicate("-", 78))
    p("  #{json}  json(conn, ...) responses — a 200 with no `ok` key claims success by STATUS alone")
    p("  #{put2xx}  put_status(2xx) sites — same claim, wearing a status code")
    p("  #{send_resp}  send_resp(conn, 2xx) sites — same again, with no body to inspect")
    p("  ALSO INVISIBLE: `mix ecto.migrations` reporting `up` (PDS-D311) — it reads a")
    p("  bookkeeping row, never the object the migration claims to have produced.")
    p("  Re-derive these three without this script (plain substrings, no \\b needed):")
    p("    git grep -c 'json(conn,' -- 'api/lib/**/*.ex' | awk -F: '{s+=$2} END{print s}'")
    p("    git grep -c 'send_resp(conn, 2' -- 'api/lib/**/*.ex' | awk -F: '{s+=$2} END{print s}'")
    p("")
    report_roster(parsed)
  end

  # THE ROSTER, PRINTED WITH ITS ANCHORS RESOLVED LIVE. The line beside each row is
  # DERIVED from the literal on every run, never transcribed — that is the whole point of
  # anchoring on a literal.
  defp report_roster(parsed) do
    src = Map.new(parsed, &{&1.path, &1.src})

    p("  THE POPULATION ROSTER — #{length(@roster)} NAMED sites outside this lens that report success")
    p("  without a read. A total names nobody; these are named, each with a verdict from")
    p("  the SAME vocabulary the register uses, and each anchored on a LITERAL.")

    Enum.each(@roster, fn r ->
      case roster_anchor(src, r) do
        {:ok, line} ->
          p("      #{String.pad_trailing(r.verdict, 9)} #{short(r.path)}:#{line}  [#{r.basis}]")
          wrap(r.note, "               ")

        :missing ->
          p("      #{String.pad_trailing(r.verdict, 9)} #{short(r.path)}  ANCHOR MISSING — see ROSTER-ANCHORS-EXIST")
      end
    end)

    p("")
  end

  # EXISTENCE, NEVER A COUNT. The three totals above moved 7 times in 9 days on unrelated
  # work; an arm over them would have been switched off inside a fortnight. A literal that
  # has left its file is a real, actionable fact — the roster row now describes nothing.
  defp roster_anchor(src, r) do
    lines = src |> Map.get(r.path, "") |> String.split("\n")

    case Enum.find_index(lines, &String.contains?(&1, r.literal)) do
      nil -> :missing
      i -> {:ok, i + 1}
    end
  end

  defp roster_check(parsed) do
    src = Map.new(parsed, &{&1.path, &1.src})
    missing = Enum.filter(@roster, &(roster_anchor(src, &1) == :missing))

    why =
      if missing == [] do
        "all #{length(@roster)} roster literal(s) still occur in their named file (EXISTENCE, never a count)"
      else
        "#{length(missing)} roster literal(s) have LEFT their file — the row now describes nothing: " <>
          Enum.map_join(missing, " · ", &"#{short(&1.path)} #{inspect(&1.literal)}")
      end

    {"ROSTER-ANCHORS-EXIST", missing == [], why}
  end

  defp sum_occ(parsed, needle), do: Enum.sum(Enum.map(parsed, &count(&1.src, needle)))

  # ---------------------------------------------------------------- delegate probe

  # PDS-D449a trap 2: Barkpark.Tasks is a 24-entry defdelegate facade, and `defdelegate`
  # is not `def` — a naive write detector reports 24 of 25 sites false. This probe is the
  # ONLY thing in the script that can go red on a code change: it asserts the facade still
  # resolves through to a real write verb.
  defp report_delegate_probe(index) do
    facade = Map.get(index.by_module, [:Barkpark, :Tasks], [])
    delegates = Enum.filter(facade, & &1.delegate)
    close = Enum.find(delegates, &(&1.name == :close))

    {verbs, depth, chain} =
      case close do
        nil -> {%{}, nil, []}
        d -> bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], @max_depth)
      end

    write? = Map.has_key?(verbs, :write)

    p("DELEGATE PROBE — Barkpark.Tasks (the facade that makes naive detectors lie)")
    p(String.duplicate("-", 78))
    p("  defdelegate entries on Barkpark.Tasks: #{length(delegates)}")
    p("    (`git grep -c defdelegate api/lib/barkpark/tasks.ex` says 24 — three of those are")
    p("     the word `defdelegated` in comments. The AST counts declarations, not prose.)")

    if close do
      hops =
        case chain do
          [_ | rest] when rest != [] -> Enum.join(rest, " -> ")
          _ -> "(no write reached — the chain ends without one)"
        end

      p("  Barkpark.Tasks.close/#{close.arity} -> delegate -> #{hops}")

      verbs
      |> Map.get(:write, [])
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.each(fn {v, l, path, d} -> p("    write verb #{v} at #{short(path)}:#{l} (depth #{d})") end)
    end

    p("  reaches a write verb: #{write?}")
    p("")

    %{delegates: length(delegates), close_write?: write?, close_depth: depth}
  end

  # ---------------------------------------------------------------- selftest
  #
  # A SELFTEST THAT HAS NEVER BEEN OBSERVED RED IS NOT A SELFTEST. This one mutates THIS
  # FILE, one anchored edit at a time, and requires the mutant to go red on the arm the
  # mutation kills. Every case that carries a mutation also requires its anchor to occur
  # EXACTLY ONCE — an anchor a refactor moved would otherwise leave a case that runs the
  # unmutated script and passes vacuously.
  #
  # THE SEAM IS CWD INJECTION. corpus/1 globs `api/lib/**/*.ex` relative to the working
  # directory and @sentinels are relative literals, so a synthetic tree in a tmp dir is
  # censused verbatim by running this same file with `cd:` set to it. The `--files-from`
  # seam does NOT work for fixtures: guard_corpus!/1 runs before parse_file/1 and ORs the
  # corpus floor with the sentinel check on ONE cond arm, so no fixture list is both small
  # enough to mutate and large enough to pass.
  #
  # PDS-D511, RESTATED HONESTLY (PDS wave 37). It is often quoted as "the selftest was
  # disarmed". It was not: it disarmed EMITTERS-PARTITION, ONE ARM OF NINE, and the other
  # eight kept going red on their own mutants throughout. The wave-37 finding is a
  # different and larger one — KEYS-ONE-LINE-PER-SITE was never armed AT ALL, because the
  # relation it asserted is true by construction (see judge_selftest_case/5 below).
  #
  # IT ASSERTS NO BUCKET COUNT — not one. Exit codes, arm names, refusal prose, and one
  # RELATION (keys lines == emitted, both read off the same invocation). A selftest that
  # pinned POST-READ or the unclassified denominator would red the build on every honest
  # lens correction, which is the defect this epic keeps filing, not the guard. PDS-D467b:
  # CORPUS-INTACT is structurally unreachable in normal operation — guard_corpus!/1 exits 2
  # on exactly the condition that arm tests — so it is proven by BYPASSING the guard.
  @self_source Path.expand(__ENV__.file)
  @pair_atom "ok:" <> " true"
  @selftest_filler 620

  @selftest_cases [
    %{
      name: "BASELINE-GREEN",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: ["CENSUS OK"],
      proves: "the synthetic corpus censuses clean, so every red below is the mutation"
    },
    %{
      name: "ARGV-STRICT",
      corpus: :full,
      argv: ["--nonsense-flag"],
      mut: nil,
      exit: 2,
      expect: ["REFUSED: UNKNOWN ARGUMENT", "unknown argument"],
      proves: "an unnamed flag refuses instead of running an unrequested lens (PDS-D493)"
    },
    %{
      name: "CORPUS-REFUSAL",
      corpus: :tiny,
      argv: [],
      mut: nil,
      exit: 2,
      expect: ["REFUSED: TRUNCATED CORPUS"],
      proves: "a corpus under the floor exits 2 rather than reporting zeros it cannot stand behind"
    },
    %{
      name: "CORPUS-INTACT (guard bypassed)",
      corpus: :tiny,
      argv: [],
      # EVERY ANCHOR IS SPELLED IN TWO FRAGMENTS JOINED AT COMPILE TIME. Written whole, the
      # anchor would occur twice in this file — here and at the line it targets — and the
      # exactly-once check in apply_mutation/2 would reject its own case list.
      mut: {"stand behind. Exit 2.\")\n    System." <> "halt(2)", "stand behind. Exit 2.\")\n    :bypassed_by_selftest"},
      exit: 1,
      expect: ["FAIL  CORPUS-INTACT", "is BELOW the"],
      proves: "the arm itself can go red once the guard that shadows it is removed"
    },
    %{
      name: "LENS-LOSES-NOTHING",
      corpus: :full,
      argv: [],
      mut: {"if extra" <> " > 0 do", "if false do"},
      exit: 1,
      expect: ["FAIL  LENS-LOSES-NOTHING", "the lens LOSES"],
      proves: "a textual occurrence the lens can neither parse nor explain reds the run"
    },
    %{
      name: "EMITTERS-PARTITION",
      corpus: :full,
      argv: [],
      mut:
        {"{consumers, emitted} = Enum.split_with(ast_sites" <> ", & &1.pattern?)",
         "{consumers, emitted} = Enum.split_with(tl(ast_sites), & &1.pattern?)"},
      exit: 1,
      expect: ["FAIL  EMITTERS-PARTITION", "is NOT the AST population"],
      proves: "an emitted site dropped between the AST and the split reds the run"
    },
    %{
      name: "CLASSIFICATION-TOTAL",
      corpus: :full,
      argv: [],
      mut:
        {"classified = Enum.map(routed" <> ", &classify(&1, index))",
         "classified = tl(Enum.map(routed, &classify(&1, index)))"},
      exit: 1,
      expect: ["FAIL  CLASSIFICATION-TOTAL", "fell out of the taxonomy entirely"],
      proves: "a site that leaves the taxonomy reds the run instead of shrinking a denominator"
    },
    %{
      name: "DELEGATE-REACHES-WRITE",
      corpus: :full,
      argv: [],
      mut: {"do: resolve(index, target, as" <> ", d.arity)", "do: []"},
      exit: 1,
      expect: ["FAIL  DELEGATE-REACHES-WRITE", "reaches NO write verb"],
      proves: "a route that can no longer follow a defdelegate reds the run (PDS-D449a trap 2)"
    },
    %{
      name: "KEYS-ONE-LINE-PER-SITE",
      corpus: :full,
      argv: ["--keys"],
      mut: nil,
      exit: 0,
      expect: {:keys, :holds},
      proves: "--keys prints one DISTINCT TSV line per emitted site, and the count survives an independent re-derivation"
    },
    # THE THREE MUTANTS THAT PROVE THE FLOOR IS NOT VACUOUS (PDS-D519). Each kills the
    # keys emission a DIFFERENT way, and each names the sub-check that must catch it —
    # a mutant caught by the WRONG sub-check is a FAIL here, not a pass.
    %{
      name: "KEYS-FLOOR-NOT-VACUOUS",
      corpus: :full,
      argv: ["--keys"],
      mut:
        {"{_consumers, emitted} = Enum.split_with(ast_sites" <> ", & &1.pattern?)",
         "{_consumers, emitted} = {ast_sites, []}"},
      exit: 0,
      expect: {:keys, {:reds, "VACUOUS"}},
      proves: "an emission zeroed inside keys_run/1 reds, instead of certifying 0 == 0 == 0"
    },
    %{
      name: "KEYS-PARTIAL-DROP",
      corpus: :full,
      argv: ["--keys"],
      mut:
        {"{_consumers, emitted} = Enum.split_with(ast_sites" <> ", & &1.pattern?)",
         "{_consumers, emitted} = (fn {c, e} -> {c, Enum.drop(e, 1)} end).(Enum.split_with(ast_sites, & &1.pattern?))"},
      exit: 0,
      expect: {:keys, {:reds, "independently derived emitted"}},
      proves: "a ONE-ROW drop reds — measured to slip past a `tsv > 0` floor, which agrees with itself at the reduced number"
    },
    %{
      name: "KEY-DISCRIMINATES",
      corpus: :full,
      argv: ["--keys"],
      mut:
        {"IO.puts(Enum.join([path, mfa, hh" <> ", fp], \"\\t\"))",
         "IO.puts(Enum.join([path, mfa, hh], \"\\t\"))"},
      exit: 0,
      expect: {:keys, {:reds, "does not DISCRIMINATE"}},
      proves: "dropping expr_fp from the key collapses two sites in one clause to one row — the register would silently lose a site"
    },
    # THE ROUTED-POPULATION ARMS (PDS wave 38). Both directions, plus the blind-shape
    # detector.
    #
    # WHY THE ARRIVAL IS PLANTED IN THE DERIVATION AND NOT IN THE FIXTURE ROUTER. The two
    # corpora are written ONCE by selftest/0 with the UNMUTATED write_corpus!/2 and then
    # censused by the mutant; a mutation to the fixture heredoc changes a function the
    # mutant never calls and the case passes vacuously at exit 0 (measured — it is how the
    # first draft of these two cases went green while asserting nothing). The route is
    # therefore planted into the derived population itself, one synthetic quad onto
    # Barkpark.Filler.M1.noop — a pair the fixture's TWO committed rows already dispose,
    # so the arrival is exactly the shape a {module, action} key cannot see.
    %{
      name: "ROUTED-ARRIVAL-REDS",
      corpus: :full,
      argv: [],
      mut:
        {"(literal ++ mounted)" <> "\n        |> Enum.map",
         "(literal ++ mounted ++ [{:post, \"/v1/selftest-planted\", \"Barkpark.Filler.M1\", :noop}])\n        |> Enum.map"},
      exit: 1,
      expect: ["FAIL  ROUTED-POPULATION-COMPLETE", "UNDISPOSED ARRIVAL", "/v1/selftest-planted"],
      proves: "a write route ARRIVING onto an ALREADY-DISPOSED {module, action} pair reds by name — the quad key sees it where a {module, action} key cannot, because the pair count does not move at all"
    },
    %{
      name: "ROUTED-DEPARTURE-REDS",
      corpus: :full,
      argv: [],
      mut:
        {"{:post, \"/v1/selftest-departure-anchor\", \"Barkpark.Filler.M1\", :noop, :selftest_fixture}" <> ",",
         "{:post, \"/v1/selftest-departure-anchor\", \"Barkpark.Filler.M1\", :noop, :selftest_fixture},\n    {:post, \"/v1/selftest-never-routed\", \"Barkpark.Filler.M1\", :noop, :selftest_fixture},"},
      exit: 1,
      expect: ["FAIL  ROUTED-POPULATION-COMPLETE", "ORPHANED DISPOSITION", "/v1/selftest-never-routed"],
      proves: "a committed disposition that names NO live routed member reds too — one direction alone is half an arm, and a row judging nothing is the shape a stale table takes"
    },
    %{
      name: "LENS-CAN-MISS-ARMED",
      corpus: :full,
      argv: [],
      mut: {"macro_sites: router_macro_sites(ast)" <> ",", "macro_sites: [],"},
      exit: 1,
      expect: ["FAIL  LENS-CAN-MISS", "blind-shape detector found ZERO"],
      proves: "killing the blind-shape detector reds LENS-CAN-MISS BY NAME, not a neighbour — the population figures would otherwise sit over an unknown denominator"
    },
    %{
      name: "LENS-CAN-MISS-NAMES-BLIND",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: ["PASS  LENS-CAN-MISS", "live_dashboard/2", "CANNOT expand"],
      proves: "a route-generating macro the lens cannot expand is NAMED with its line, so the routes it emits are stated absent rather than silently missing"
    }
  ]

  defp selftest do
    p("PDS CENSUS SELFTEST — can this instrument be made to go RED?")
    p(String.duplicate("=", 78))
    p("  Mutates this file over a synthetic corpus (CWD injection) and requires each")
    p("  mutant to red on the arm it kills. Asserts exit codes, arm names and refusal")
    p("  prose — NEVER a bucket count, so an honest lens correction can never red it.")
    p("")

    src = File.read!(@self_source)
    # THE OS PID IS LOAD-BEARING (PDS-D542). System.unique_integer/1 is VM-LOCAL: eight
    # concurrent VMs joined onto one shared TMPDIR produced the IDENTICAL root FIVE times,
    # and File.rm_rf!(root) below then deletes a concurrent run's corpus mid-flight. The
    # dangerous shape is not the crash — at a small stagger it prints SELFTEST FAILED
    # naming FAIL KEY-DISCRIMINATES, a vacuous RED wearing a real arm's name, which reads
    # as a substantive regression in key-discrimination logic. mkdir_p! would repair only
    # the crash and leave that shape alive; the OS pid makes the root globally unique.
    root =
      Path.join(
        System.tmp_dir!(),
        "pds-census-selftest-#{System.pid()}-#{System.unique_integer([:positive])}"
      )
    dirs = %{full: Path.join(root, "full"), tiny: Path.join(root, "tiny")}

    write_corpus!(dirs.full, @selftest_filler)
    write_corpus!(dirs.tiny, 0)

    results = Enum.map(@selftest_cases, &run_selftest_case(&1, src, dirs, root))
    File.rm_rf!(root)

    Enum.each(results, fn r ->
      p("  #{if r.ok?, do: "PASS", else: "FAIL"}  #{String.pad_trailing(r.name, 32)} #{r.why}")
      unless r.ok?, do: p("        proves: #{r.proves}")
    end)

    p("")
    failed = Enum.reject(results, & &1.ok?)

    if failed == [] do
      p("SELFTEST OK — #{length(results)} cases, #{Enum.count(@selftest_cases, & &1.mut)} of them mutants that went red as required.")
      System.halt(0)
    else
      p("SELFTEST FAILED — #{length(failed)} case(s) did not behave as required. Read the FAIL lines.")
      System.halt(1)
    end
  end

  defp run_selftest_case(c, src, dirs, root) do
    base = %{name: c.name, proves: c.proves}

    with {:ok, mutated} <- apply_mutation(src, c.mut) do
      script = Path.join(root, "case-#{:erlang.phash2(c.name)}.exs")
      File.write!(script, mutated)
      dir = Map.fetch!(dirs, c.corpus)

      # NEVER PIPED: System.cmd hands back the child's own status, which is the whole
      # point — `cmd | tail` reports tail's status and once logged an exit-2 refusal as 0.
      {out, code} = System.cmd("elixir", [script | c.argv], cd: dir, stderr_to_stdout: true)

      judge_selftest_case(base, c, out, code, {script, dir})
    else
      {:error, why} -> Map.merge(base, %{ok?: false, why: why})
    end
  end

  # ------------------------------------------------------------- the keys floor
  #
  # WHY THIS IS FOUR CHECKS AND NOT ONE RELATION (PDS-D519). The shipped arm asserted
  # `length(routed) == length(emitted)`, which keys_run/1 makes TRUE BY CONSTRUCTION —
  # it maps over `emitted`. Forcing the emission to [] made `--keys` print zero lines
  # over the real 804-file corpus while `--selftest` still printed SELFTEST OK at RC 0.
  # A `tsv > 0` floor alone does not repair it either: a one-row drop passes, because
  # keys, emitted and tsv all agree at the reduced number. The four checks below are
  # ordered so the FAIL sentence names WHICH ONE fired, and the last one is the only
  # genuinely independent path — a SECOND invocation of the same binary over the same
  # corpus, deriving `emitted` through the census's own reporting instead of keys_run/1.
  defp judge_selftest_case(base, %{expect: {:keys, mode}} = c, out, code, ctx) do
    case {mode, keys_floor_verdict(out, code, c.exit, ctx)} do
      {:holds, :ok} ->
        Map.merge(base, %{
          ok?: true,
          why: "exit 0 · TSV == keys == emitted == the census's OWN derived emitted · every key distinct · floor non-vacuous"
        })

      {:holds, {:red, why}} ->
        Map.merge(base, %{ok?: false, why: why})

      {{:reds, frag}, {:red, why}} ->
        if String.contains?(why, frag) do
          Map.merge(base, %{ok?: true, why: "went RED as required — #{why}"})
        else
          Map.merge(base, %{
            ok?: false,
            why: "went red on the WRONG sub-check (#{why}) — expected one naming #{inspect(frag)}"
          })
        end

      {{:reds, frag}, :ok} ->
        Map.merge(base, %{
          ok?: false,
          why: "THE MUTANT PASSED THE KEYS FLOOR — nothing here would catch it; expected a red naming #{inspect(frag)}"
        })
    end
  end

  defp judge_selftest_case(base, c, out, code, _ctx) do
    missing = Enum.reject(c.expect, &String.contains?(out, &1))

    cond do
      code != c.exit ->
        Map.merge(base, %{ok?: false, why: "exit #{code}, expected #{c.exit}"})

      missing != [] ->
        Map.merge(base, %{
          ok?: false,
          why: "exit #{code} as required but never printed #{inspect(missing)}"
        })

      true ->
        Map.merge(base, %{ok?: true, why: "exit #{c.exit} · printed #{inspect(hd(c.expect))}"})
    end
  end

  defp keys_floor_verdict(out, code, want_exit, {script, dir}) do
    lines = String.split(out, "\n", trim: true)
    tsv = Enum.filter(lines, &String.contains?(&1, "\t"))
    n = length(tsv)
    distinct = length(Enum.uniq(tsv))

    summary =
      Enum.find_value(lines, fn l ->
        case Regex.run(~r/^keys (\d+) · emitted (\d+)/, l) do
          [_, k, e] -> {String.to_integer(k), String.to_integer(e)}
          _ -> nil
        end
      end)

    cond do
      code != want_exit ->
        {:red, "exit #{code}, expected #{want_exit}"}

      summary == nil ->
        {:red, "--keys printed no summary line to stderr"}

      n == 0 ->
        {:red,
         "ZERO-FLOOR: --keys printed 0 TSV line(s). The one-line-per-site relation is VACUOUS at zero — 0 == 0 == 0 certifies nothing, and the register reads its rows off this emission"}

      elem(summary, 0) != n or elem(summary, 1) != n ->
        {:red,
         "ONE-LINE-PER-SITE: TSV lines #{n} != keys #{elem(summary, 0)} / emitted #{elem(summary, 1)}"}

      distinct != n ->
        {:red,
         "KEY-DISCRIMINATES: the key does not DISCRIMINATE: #{n} site(s) collapsed to #{distinct} distinct key(s)"}

      true ->
        independent_rederivation(n, script, dir)
    end
  end

  # THE SECOND PATH. Runs the SAME (possibly mutated) script with `argv []` in the SAME
  # fixture and reads `emitted` off the ordinary census report — a figure keys_run/1 does
  # not produce and cannot influence. FAILS CLOSED: an unparsable figure is a red, never
  # a shrug, because "the re-derivation could not read a number" and "the numbers agree"
  # must never print the same verdict.
  defp independent_rederivation(n, script, dir) do
    {out, _code} = System.cmd("elixir", [script], cd: dir, stderr_to_stdout: true)

    case Regex.run(~r/EMITTED success claims\s+(\d+)/, out) do
      [_, e] ->
        e = String.to_integer(e)

        if e == n do
          :ok
        else
          {:red,
           "INDEPENDENT-REDERIVATION: --keys printed #{n} TSV line(s) but the census run over the SAME corpus independently derived emitted #{e}"}
        end

      _ ->
        {:red,
         "INDEPENDENT-REDERIVATION: the census run over the same corpus printed no parsable `EMITTED success claims` figure — failing CLOSED rather than passing on an unread number"}
    end
  end

  # AN ANCHOR THAT DOES NOT OCCUR EXACTLY ONCE IS A DEAD CASE, NOT A PASS. A refactor that
  # moves the mutated line must break the selftest loudly rather than leave it running the
  # unmutated script and reporting green.
  defp apply_mutation(src, nil), do: {:ok, src}

  defp apply_mutation(src, {from, to}) do
    case length(:binary.matches(src, from)) do
      1 -> {:ok, String.replace(src, from, to)}
      0 -> {:error, "MUTATION ANCHOR GONE — #{inspect(String.slice(from, 0, 48))} no longer occurs"}
      n -> {:error, "MUTATION ANCHOR AMBIGUOUS — #{inspect(String.slice(from, 0, 48))} occurs #{n} times"}
    end
  end

  # THE SYNTHETIC CORPUS. Small on purpose: it carries one emitter, one consumer, one
  # phantom, one defdelegate facade that reaches a write verb, and enough filler to clear
  # the corpus floor. The receipt text is assembled from fragments so that no literal
  # success pair appears in THIS file's own source.
  defp write_corpus!(dir, filler) do
    w = fn rel, body ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    w.("api/lib/barkpark/tasks.ex", """
    defmodule Barkpark.Tasks do
      @moduledoc "the defdelegate facade that makes naive write detectors lie"
      defdelegate close(id, worker, epoch), to: Barkpark.Tasks.Close
      defdelegate reopen(id), to: Barkpark.Tasks.Close
    end
    """)

    w.("api/lib/barkpark/tasks/close.ex", """
    defmodule Barkpark.Tasks.Close do
      # a phantom: the words #{@pair_atom} in prose, which the AST does not carry as a pair
      def close(id, worker, epoch) do
        {n, _} = Repo.update_all(id, set: [worker: worker, epoch: epoch])
        receipt(id, n)
      end

      def reopen(id), do: Repo.update(id)

      # TWO EMITTED SITES IN ONE CLAUSE (PDS-D519). Identical {path, module.name/arity,
      # head_hash} — one clause, one head — and DIFFERENT expr_fp, because the two `%{}`
      # nodes differ. Without this the fixture holds one emitted site, every key is
      # trivially distinct, and KEY-DISCRIMINATES cannot fail on a fixture that never
      # asks the key to discriminate anything.
      def receipt(id, n) do
        if n > 0 do
          %{#{@pair_atom}, id: id, moved: n}
        else
          %{#{@pair_atom}, id: id}
        end
      end

      def consume(resp) do
        %{#{@pair_atom}} = resp
        :ok
      end
    end
    """)

    # THE FIXTURE ROUTER (PDS wave 38). Two write routes onto ONE {module, action} pair,
    # so the quad key is asked to DISCRIMINATE on every selftest run; a route-generating
    # macro this lens resolves (plugin_routes) and one it cannot (live_dashboard), so
    # LENS-CAN-MISS has both a resolved site and a blind site to name. Both routes point
    # at Barkpark.Filler.M1, a module that exists ONLY here — in the real tree the two
    # committed :selftest_fixture disposition rows name a module the corpus does not
    # carry and are OUT OF SCOPE, never a red.
    w.("api/lib/barkpark_web/router.ex", """
    defmodule BarkparkWeb.Router do
      live_dashboard("/dashboard", metrics: BarkparkWeb.Telemetry)

      scope "/v1" do
        plugin_routes(scope: :admin)
        post("/selftest-fixture-close", Barkpark.Filler.M1, :noop)
        post("/selftest-departure-anchor", Barkpark.Filler.M1, :noop)
      end
    end
    """)

    w.("api/lib/barkpark/repo.ex", """
    defmodule Barkpark.Repo do
      def update_all(q, opts), do: {0, [q | opts]}
      def update(q), do: {:ok, q}
    end
    """)

    Enum.each(1..filler//1, fn i ->
      w.("api/lib/barkpark/filler/m#{i}.ex", """
      defmodule Barkpark.Filler.M#{i} do
        def noop(x), do: x
      end
      """)
    end)
  end

  # ---------------------------------------------------------------- integrity

  defp integrity(files, textual, ast_sites, phantoms, consumers, emitted, classified, delegate, ms, parsed, falsifiers, routed) do
    classified_n = Enum.count(classified, fn s -> elem(s.shape, 0) != "UNCLASSIFIED" end)
    unclassified_n = Enum.count(classified, fn s -> elem(s.shape, 0) == "UNCLASSIFIED" end)

    # EVERY ARM RENDERS ITS OWN FAIL SENTENCE. One `why` for both branches is how a RED
    # line prints a true-reading sentence — the shipped form printed `FAIL CORPUS-INTACT 3
    # files >= 600`, which is a lie wearing the word FAIL. DELEGATE-REACHES-WRITE already
    # carried the false-branch shape; it is now the rule, not the exception. The relation
    # in the PASS prose is the one the arm asserts; the FAIL prose says what happened.
    checks = [
      {"CORPUS-INTACT", length(files) >= @corpus_floor,
       if length(files) >= @corpus_floor do
         "#{length(files)} files >= #{@corpus_floor}"
       else
         "#{length(files)} files is BELOW the #{@corpus_floor} floor — the corpus is truncated and every zero below it is unearned (normally unreachable: guard_corpus!/1 exits 2 on this same condition first)"
       end},
      {"LENS-LOSES-NOTHING", textual == length(ast_sites) + length(phantoms),
       if textual == length(ast_sites) + length(phantoms) do
         "textual #{textual} == ast #{length(ast_sites)} + phantom #{length(phantoms)}"
       else
         "textual #{textual} != ast #{length(ast_sites)} + phantom #{length(phantoms)} — the lens LOSES #{textual - length(ast_sites) - length(phantoms)} occurrence(s) it can neither parse nor explain"
       end},
      {"EMITTERS-PARTITION", length(ast_sites) == length(consumers) + length(emitted),
       if length(ast_sites) == length(consumers) + length(emitted) do
         "ast #{length(ast_sites)} == consumer #{length(consumers)} + emitted #{length(emitted)}"
       else
         "ast #{length(ast_sites)} != consumer #{length(consumers)} + emitted #{length(emitted)} — the emitter/consumer split drops #{length(ast_sites) - length(consumers) - length(emitted)} site(s); the emitted population is NOT the AST population"
       end},
      {"CLASSIFICATION-TOTAL", classified_n + unclassified_n == length(emitted),
       if classified_n + unclassified_n == length(emitted) do
         "classified #{classified_n} + unclassified #{unclassified_n} == emitted #{length(emitted)}"
       else
         "classified #{classified_n} + unclassified #{unclassified_n} != emitted #{length(emitted)} — #{length(emitted) - classified_n - unclassified_n} emitted site(s) fell out of the taxonomy entirely; every shape count below is over the wrong denominator"
       end},
      {"DELEGATE-REACHES-WRITE", delegate.close_write?,
       # On FAIL close_depth is nil, and "at depth " with nothing after it reads
       # like a truncated line rather than a finding — say what actually happened.
       if delegate.close_write? do
         "Barkpark.Tasks.close (defdelegate, #{delegate.delegates} on the facade) reaches a write verb at depth #{delegate.close_depth}"
       else
         "Barkpark.Tasks.close (defdelegate, #{delegate.delegates} on the facade) reaches NO write verb within the route budget — the facade probe is blind"
       end}
    ] ++ routed_checks(routed) ++ register_checks(classified, parsed) ++ falsifier_check(falsifiers)

    p("INTEGRITY (these can go RED — the population numbers cannot; they are not a gate)")
    p(String.duplicate("-", 78))

    Enum.each(checks, fn {name, ok?, why} ->
      p("  #{if ok?, do: "PASS", else: "FAIL"}  #{String.pad_trailing(name, 24)} #{why}")
    end)

    p("")
    p("DRIFT vs PDS-D448 (advisory — printed, never enforced)")
    p(String.duplicate("-", 78))
    drift("textual", textual, :textual)
    drift("ast-literal", length(ast_sites), :ast)
    drift("phantom", length(phantoms), :phantom)
    drift("consumer", length(consumers), :consumer)
    drift("emitted", length(emitted), :emitted)
    drift("write-routed", Enum.count(classified, & &1.write?), :write)
    drift("read-routed", Enum.count(classified, &(not &1.write? and &1.read?)), :read)
    drift("unrouted", Enum.count(classified, &(not &1.write? and not &1.read?)), :unrouted)
    p("")
    p("wall clock  #{ms} ms  (build-free: no mix project, no compile, no app boot)")

    if Enum.all?(checks, &elem(&1, 1)) do
      p("CENSUS OK")
      System.halt(0)
    else
      p("CENSUS FAILED — an integrity check went red. Read the FAIL line above.")
      System.halt(1)
    end
  end

  # ----------------------------------------------------------- basis falsifiers
  #
  # THE VOCABULARY IS ONLY WORTH ANYTHING IF A SCRIPT CAN REFUSE A TOKEN (PDS-D525). Each
  # value in @basis_vocab names a falsifier; this reads the committed test tree and fires
  # the ones it can DECIDE. It is TIERED AS MEASURED, not as hoped:
  #
  #   REDS (5)      end_to_end (and end_to_end_unmutated, the same predicate minus the
  #                 mutation) · stub_mapping_only, THE "DOES read Repo" HALF ONLY ·
  #                 context_differential_only · basis_stale (a direct --keys join, built
  #                 FIRST because this wave's own slices re-key rows) · no_observer, the
  #                 MODULE-SUBSTRING half only, which needs no test-tree index.
  #   ADVISORY      everything else, printed as a counted CONTRADICTION line at exit 0 —
  #                 the DRIFT pattern this census already uses.
  #
  # A CITED PATH THAT DOES NOT EXIST REDS. It is never silently skipped: a citation to a
  # file nobody can open is the paperwork this ledger exists to refuse.
  #
  # THE PREDICATE THE WISH ASKED FOR IS A FALSE FALSIFIER AND IS NOT BUILT. "The cited
  # test references the site's MODULE" refuses ALL of this wave's committed PROVEN
  # differentials, because pds_group_c_receipt_differential_test.exs contains the string
  # `Controller` ZERO times — conn-driven tests name a URL, not a module — and it GREENS a
  # cross-wired citation. Route linkage replaces it and is ADVISORY, never redding:
  # PluginSettings/Secret route literals are all-dynamic (the URL lives in the enclosing
  # `scope`, and reading the literal alone manufactured 3 FALSE contradictions on genuine
  # PROVEN rows) and `GithubWebhookController` appears ZERO times in router.ex because the
  # routes are macro-generated, so linkage is UNCHECKABLE for all 14 webhook rows.
  #
  # `shape_assertion_only`'s falsifier is UNDECIDABLE as written and is implementable only
  # as a denylist of weak predicates (is_list/is_map/is_binary/bare truthiness). It is
  # advisory, and @basis_vocab says so in the falsifier text rather than shipping an arm
  # whose name promises more than its code delivers.
  #
  # HELPER RESOLUTION IS MANDATORY, AND THE HELPER-NAME REGEX IS [\w!?]+ (both cost the
  # prototype an iteration). The decisive `Repo.` / `build_conn` token routinely lives in
  # a helper — `stored/1`, `deliver/3`, `stub_intake/1`, `assert_receipt_is_stored!/2` —
  # never in the cited block; and `\w+` truncates `assert_receipt_is_stored!` at the `!`
  # and FALSELY REFUSES four genuine rows.
  # THE PROBE IS THE SUBSTRING `Repo.`, AND ITS LIMIT IS MEASURED. A test that reads
  # Postgres through a CONTEXT MODULE carries no such token — inbound_events_test.exs's
  # `link_state/2` goes through `Content.get_document/4` and `detached_conflicts/1` through
  # `Conflicts.list/1`. That is exactly why `two_hop_composed` is ADVISORY: on this probe
  # its falsifier is not decidable, so it prints a counted CONTRADICTION and never a red.
  # The redding values are the ones the probe CAN decide, and nothing else was promoted to
  # redding on the grounds that it would usually be right.
  @test_root "api/test"
  @conn_tokens ["build_conn", "json_response", "conn |>", "|> post(", "|> get(",
                "|> put(", "|> delete(", "%{conn:", "conn: conn", "authed("]
  @repo_token "Repo."

  defp basis_falsifiers(classified) do
    if File.dir?(@test_root) do
      cache = %{}

      {findings, _cache} =
        classified
        |> resolve_register()
        |> Enum.reduce({[], cache}, fn {r, status, _site}, {acc, c} ->
          case status do
            :live -> {f, c} = check_row_basis(r, c)
              {acc ++ f, c}

            _ ->
              {acc, c}
          end
        end)

      {:ran, findings}
    else
      :no_test_tree
    end
  end

  defp check_row_basis(r, cache) do
    ev = Map.get(r, :evidence, "")
    tier_of_basis = elem(Map.get(@basis_vocab, r.basis, {"?", "?", :advisory}), 2)

    cond do
      r.basis == :no_observer ->
        {no_observer_findings(r), cache}

      r.basis in [:end_to_end, :end_to_end_unmutated, :stub_mapping_only,
                  :context_differential_only, :side_effect_existence_only, :two_hop_composed] ->
        cited_findings(r, ev, tier_of_basis, cache)

      true ->
        {[], cache}
    end
  end

  defp cited_findings(r, "", tier, cache),
    do: {[finding(r, tier, "carries no citation, and its falsifier needs one")], cache}

  defp cited_findings(r, ev, tier, cache) do
    case String.split(ev, ":") do
      [path, line] ->
        if File.exists?(path) do
          {text, cache} = cited_text(path, String.to_integer(line), cache)
          {judge_citation(r, ev, tier, text), cache}
        else
          # ALWAYS A RED, whatever the basis's tier: an unopenable citation is not a weak
          # judgment, it is no judgment at all.
          {[finding(r, :reds, "cites #{ev}, and that PATH DOES NOT EXIST")], cache}
        end

      _ ->
        {[finding(r, :reds, "cites #{inspect(ev)}, which is not a `path:line`")], cache}
    end
  end

  defp judge_citation(r, ev, tier, text) do
    conn? = Enum.any?(@conn_tokens, &String.contains?(text, &1))
    repo? = String.contains?(text, @repo_token)

    case r.basis do
      b when b in [:end_to_end, :end_to_end_unmutated] ->
        cond do
          not conn? -> [finding(r, tier, "#{ev} drives no route (no conn token in the cited block or its helpers)")]
          not repo? -> [finding(r, tier, "#{ev} never reads the stored row back (no `Repo.` in the cited block or its helpers)")]
          true -> []
        end

      :stub_mapping_only ->
        # ONLY THE REPO HALF REDS. The seam half ("has no injection seam") is advisory:
        # a seam can be a put_env, a Mox, a passed fun or a config key, and a denylist of
        # spellings would refuse honest rows.
        if repo?,
          do: [finding(r, tier, "#{ev} DOES read Repo — `stub_mapping_only` understates what the suite proves")],
          else: []

      :context_differential_only ->
        if conn?,
          do: [finding(r, tier, "#{ev} BUILDS A CONN — the controller->wire hop is covered, so this is not context-differential-only")],
          else: []

      :side_effect_existence_only ->
        if not repo?,
          do: [finding(r, :advisory, "#{ev} reads no Repo at all, so it cannot even assert existence")],
          else: []

      :two_hop_composed ->
        if not repo?,
          do: [finding(r, :advisory, "#{ev} reads no Repo — the second hop is not visible in the cited block")],
          else: []

      _ ->
        []
    end
  end

  # THE MODULE HALF ONLY. `no_observer` claims NOTHING in the test tree names this site;
  # one substring hit refutes it, and that needs no index and no route.
  defp no_observer_findings(r) do
    mod = r.key |> elem(1) |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    hit =
      Path.wildcard(@test_root <> "/**/*.exs")
      |> Enum.find(&String.contains?(File.read!(&1), mod))

    if hit,
      do: [finding(r, :reds, "`no_observer` is refuted — #{mod} is named in #{hit}")],
      else: []
  end

  defp finding(r, tier, why), do: %{key: r.key, basis: r.basis, tier: tier, why: why}

  # THE CITED BLOCK PLUS ITS HELPERS, ONE LEVEL DEEP. The block runs from the cited line to
  # the `end` at its own indentation (capped, because a runaway scan would swallow the file
  # and green everything).
  defp cited_text(path, line, cache) do
    lines = Map.get_lazy(cache, path, fn -> path |> File.read!() |> String.split("\n") end)
    cache = Map.put(cache, path, lines)
    block = block_at(lines, line)

    helpers =
      ~r/([\w!?]+)\(/
      |> Regex.scan(block)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()
      |> Enum.flat_map(&helper_body(lines, &1))
      |> Enum.join("\n")

    {block <> "\n" <> helpers, cache}
  end

  defp block_at(lines, line) do
    start = max(line - 1, 0)
    head = Enum.at(lines, start, "")
    indent = String.length(head) - String.length(String.trim_leading(head))

    lines
    |> Enum.drop(start)
    |> Enum.take(200)
    |> Enum.reduce_while([], fn l, acc ->
      closed? =
        acc != [] and String.trim(l) == "end" and
          String.length(l) - String.length(String.trim_leading(l)) == indent

      if closed?, do: {:halt, [l | acc]}, else: {:cont, [l | acc]}
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # `[\w!?]+`, NEVER `\w+`: `\w+` truncates assert_receipt_is_stored! at the bang and the
  # def is then never found, which falsely refuses four genuine rows.
  defp helper_body(lines, name) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {l, _n} -> Regex.match?(~r/^\s*defp?\s+#{Regex.escape(name)}\(/, l) end)
    |> Enum.map(fn {_l, n} -> block_at(lines, n) end)
  end

  defp report_basis_falsifiers(classified) do
    p("BASIS FALSIFIERS (PDS-D525 — a vocabulary token is only a claim if a script can")
    p("refuse it; tiered AS MEASURED, so an undecidable falsifier is advisory, not a lie)")
    p(String.duplicate("-", 78))

    case basis_falsifiers(classified) do
      :no_test_tree ->
        p("  SKIPPED — this corpus carries no #{@test_root}/ tree, so no citation can be opened.")
        p("  THIS IS NOT A PASS. The census is normally run over `git archive HEAD api/lib")
        p("  scripts`, which excludes the tests on purpose; run it from a full checkout to")
        p("  arm these arms. Within a present test tree, a citation that cannot be opened REDS.")
        p("")
        :skipped

      {:ran, findings} ->
        {red, advisory} = Enum.split_with(findings, &(&1.tier == :reds))
        p("  checked #{Enum.count(@register)} row(s) against #{length(Enum.filter(@basis_vocab, fn {_k, {_c, _f, t}} -> t == :reds end))} redding value(s) · #{length(red)} refusal(s) · #{length(advisory)} advisory contradiction(s)")

        Enum.each(red, fn f ->
          p("      REFUSED  #{short(elem(f.key, 0))} #{elem(f.key, 1)}  [#{f.basis}]")
          wrap(f.why, "               ")
        end)

        Enum.each(advisory, fn f ->
          p("      CONTRADICTION  #{short(elem(f.key, 0))} #{elem(f.key, 1)}  [#{f.basis}] #{f.why}")
        end)

        if findings == [], do: p("      none — every decidable falsifier holds")
        p("")
        {:ran, red}
    end
  end

  # ---------------------------------------------------------- register integrity
  #
  # THREE ARMS, ALL SCOPED TO THE REAL CORPUS. They assert COMPLETENESS and INTEGRITY and
  # never a verdict distribution — a reclassification cannot red this build, which is the
  # whole reason the ratchet is safe to leave armed.
  # A SKIPPED SCOPE CONTRIBUTES NO ARM AT ALL, rather than a PASS nobody earned.
  defp falsifier_check(:skipped), do: []

  defp falsifier_check({:ran, red}) do
    why =
      if red == [] do
        "every decidable falsifier holds across the register's cited basis tokens"
      else
        "#{length(red)} basis token(s) REFUSED by their own falsifier: " <>
          Enum.map_join(Enum.take(red, 4), " · ", &"#{short(elem(&1.key, 0))} [#{&1.basis}] #{&1.why}")
      end

    [{"BASIS-FALSIFIERS", red == [], why}]
  end

  defp register_checks(classified, parsed) do
    case register_scope(classified) do
      :scoped_out -> []
      :real ->
        [
          register_complete(classified),
          declared_rows_resolve(classified),
          declared_basis_intact(parsed),
          roster_check(parsed)
        ]
    end
  end

  # BOTH DIRECTIONS, AND THE FAIL SENTENCE NAMES THE OFFENDER. site->row catches an
  # emitted claim nobody has judged; row->site catches a row judging nothing (the shape a
  # split multi-tag row would take). One direction alone is half a register.
  defp register_complete(classified) do
    resolved = resolve_register(classified)
    site_keys = Enum.map(classified, &site_key/1)
    row_keys = Enum.map(@register, & &1.key)
    row_freq = Enum.frequencies(row_keys)

    covered = MapSet.new(for {_r, st, s} <- resolved, st in [:live, :stale], do: site_key(s))
    demoted = Enum.count(resolved, fn {_r, st, _s} -> st == :stale end)

    unjudged = Enum.reject(site_keys, &MapSet.member?(covered, &1))
    orphaned = for {r, :orphan, _s} <- resolved, do: r.key
    dupes = for {k, n} <- row_freq, n > 1, do: k

    ok? = unjudged == [] and orphaned == [] and dupes == []

    why =
      if ok? do
        "#{length(row_keys)} row(s) <-> #{length(site_keys)} emitted site(s), both directions, no duplicate key" <>
          if(demoted > 0, do: " (#{demoted} demoted to basis_stale — reported, never a red)", else: "")
      else
        Enum.join(
          [
            "#{length(unjudged)} emitted site(s) carry NO register row",
            "#{length(orphaned)} register row(s) name NO emitted site",
            "#{length(dupes)} key(s) carry more than one row"
          ] ++
            Enum.map(Enum.take(unjudged, 4), &"UNJUDGED SITE #{short(elem(&1, 0))} #{elem(&1, 1)} #{elem(&1, 2)}/#{elem(&1, 3)}") ++
            Enum.map(Enum.take(orphaned, 4), &"ORPHANED ROW #{short(elem(&1, 0))} #{elem(&1, 1)} #{elem(&1, 2)}/#{elem(&1, 3)}") ++
            Enum.map(Enum.take(dupes, 4), &"DUPLICATE ROW #{short(elem(&1, 0))} #{elem(&1, 1)}"),
          " · "
        )
      end

    {"REGISTER-COMPLETE", ok?, why}
  end

  # NOT "the row's line still carries a success pair" (PDS-D521): the pair occurs on 11
  # lines of auth_controller.ex, so a line shift can land a row on a DIFFERENT site and
  # pass silently, and the FAIL line becomes an eleven-candidate re-derivation instead of
  # a one-edit fix. The row must match an EMITTED AST SITE.
  defp declared_rows_resolve(classified) do
    live = MapSet.new(classified, &site_key/1)
    orphans = Enum.reject(@declared, &MapSet.member?(live, &1.key))

    why =
      if orphans == [] do
        "all #{length(@declared)} declared row(s) resolve to an emitted site"
      else
        "#{length(orphans)} declared row(s) resolve to NO emitted site — a declared basis is suppressing nothing and nobody would know: " <>
          Enum.map_join(orphans, " · ", fn d ->
            {path, mfa, hh, fp} = d.key
            "ORPHAN #{short(path)} #{mfa} #{hh}/#{fp} [#{d.class}]"
          end)
      end

    {"DECLARED-ROWS-RESOLVE", orphans == [], why}
  end

  # THE BASIS ITSELF MUST STILL BE THERE. Each declared row records the SPAN(S) its prose
  # lives in and one TOKEN that must occur inside one of them. Comparison is DOWNCASED on
  # both sides: bulldocs_form's basis is written "so the trap stays invisible" at :24 and
  # "# The trap stays invisible:" at :53, and a case-sensitive test silently loses one.
  # THE FAIL LINE NAMES THE ROW AND ITS RECORDED SPAN, so the fix is one edit and not a
  # re-derivation of where the sentence went.
  defp declared_basis_intact(parsed) do
    src = Map.new(parsed, &{&1.path, String.split(&1.src, "\n")})

    drifted =
      Enum.reject(@declared, fn d ->
        lines = Map.get(src, declared_path(d), [])
        token = String.downcase(d.basis_token)

        Enum.any?(d.basis_spans, fn {lo, hi} ->
          lines
          |> Enum.slice((lo - 1)..(hi - 1)//1)
          |> Enum.any?(&String.contains?(String.downcase(&1), token))
        end)
      end)

    why =
      if drifted == [] do
        "all #{length(@declared)} basis token(s) still occur inside their recorded span(s)"
      else
        "#{length(drifted)} declared basis has DRIFTED off its recorded span: " <>
          Enum.map_join(drifted, " · ", fn d ->
            spans = Enum.map_join(d.basis_spans, ",", fn {lo, hi} -> ":#{lo}-#{hi}" end)
            "#{short(declared_path(d))} #{elem(d.key, 1)} [#{d.class}] recorded span #{spans} no longer carries #{inspect(d.basis_token)}"
          end)
      end

    {"DECLARED-BASIS-INTACT", drifted == [], why}
  end

  defp drift(label, got, key) do
    want = @recorded[key]
    tag = if got == want, do: "==", else: "DRIFT"
    p("  #{String.pad_trailing(label, 14)} recorded #{String.pad_leading(to_string(want), 4)}  derived #{String.pad_leading(to_string(got), 4)}  #{tag}")
  end

  defp row(label, got, _raw, key) do
    want = @recorded[key]
    tag = if got == want, do: "", else: "  (PDS-D448 recorded #{want})"
    p(String.pad_trailing("  " <> label, 48) <> String.pad_leading(to_string(got), 4) <> tag)
  end

  defp short(path), do: String.replace_prefix(path, "api/lib/", "")

  defp p(s), do: IO.puts(s)
end

PDS.Census.main(System.argv())
