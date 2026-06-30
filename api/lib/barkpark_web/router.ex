defmodule BarkparkWeb.Router do
  use BarkparkWeb, :router

  # Compile-time macro that folds plugin-contributed routes into the host
  # router. See `BarkparkWeb.Router.Plugins` and Goal barkpark-G2.
  import BarkparkWeb.Router.Plugins

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalToken)
    # Back-compat tenancy shim: flat routes (no /w/:ws/p/:project slugs in the
    # path) infer the seeded Default Workspace/Project so downstream code always
    # has a scope. No-op once a resolver has already set the assigns.
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
  end

  # Localhost fast-path pipeline (Barkpark Cloud P4 / Move B). Deliberately
  # thin — `accepts :json` + the loopback gate. No OptionalToken (no DB lookup
  # per request), no RateLimit (loopback is trusted), no tenancy back-compat
  # (the co-located caller passes workspace_id/project_id explicitly if needed).
  # Shaves the per-keystroke Phoenix floor from ~1–5 ms to the router minimum.
  pipeline :api_local do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.RequireLoopback)
  end

  # Tenancy-aware variant of :api for the path-scoped
  # /w/:workspace_slug/p/:project_slug routes. Same base plugs as :api
  # (sans AssignDefaultScope — the resolvers set the real scope), then
  # resolves + membership-gates the workspace and resolves the project.
  pipeline :scoped_api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalToken)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  # Public-share variant of :scoped_api for the scoped READ document routes
  # (GET /w/:ws/p/:project/v1/data/query/:dataset/:type and
  # GET .../v1/data/doc/:dataset/:type/:doc_id). Mirrors :scoped_api exactly,
  # but inserts RequireShareScope(surface: :docs) between OptionalToken and the
  # resolvers: when the scope is shared for the :docs surface (via
  # Barkpark.Sharing) the plug pre-resolves workspace+project and flags
  # :share_public, so ResolveWorkspace SKIPS its membership gate (anonymous read
  # of a shared scope). When the scope is NOT shared — the default everywhere —
  # RequireShareScope is a pure no-op and ResolveWorkspace gates membership
  # byte-identically to a normal scoped request. RequireShareScope is method- +
  # access-aware (a :read share serves only GET/HEAD), so these GET reads are
  # the ONLY thing a :docs:read share opens — the POST mutate route lives in its
  # own scope block on a different pipeline and is never reached from here.
  pipeline :shared_docs_api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :docs)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  # Tenancy-aware READ pipeline for the scoped media surface (P3) — the
  # :shared_docs_api shape but gated on the :media surface. A `:media`-shared
  # scope is reachable by an anonymous caller (RequireShareScope is method-aware
  # so only safe GET reads grant); otherwise it is byte-identical to a normal
  # scoped request and ResolveWorkspace gates membership. The MediaController is
  # already scope-aware (list_files / get_file / get_file_by_path all take the
  # resolved workspace scope), so a media share serves ONLY its own workspace's
  # files — a path that resolves to another workspace 404s. Per-asset
  # `bp_visibility` still applies on serve (private bytes stay denied).
  #
  # Session-aware (like :scoped_browser): these routes are loaded by bare
  # browser `<img>` tags from the scoped Studio media library, which carry
  # the session cookie but can never attach a Bearer header. Plain
  # OptionalToken left those conns anonymous, so ResolveWorkspace's
  # membership gate 403'd every thumbnail for a logged-in member.
  # OptionalSessionToken resolves the member's token from EITHER the Bearer
  # header (wins when present — API clients unchanged) OR
  # `session["api_token"]`; anonymous still passes through untouched, so the
  # :media share path and the fail-closed default are byte-identical.
  pipeline :shared_media_api do
    plug(:fetch_session)
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :media)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  # P5 scoped-share EDIT pipelines. These serve the SAME scoped write routes to
  # BOTH a member (via membership, exactly as today) AND a scope-bound edit-token
  # holder. The ONLY addition over the existing member pipelines is
  # RequireShareEditToken inserted right after token resolution and BEFORE
  # ResolveWorkspace: it grants `:share_public` + `:share_writer` solely for a
  # token whose opaque `share-edit-<surface>` permission + `share_scope` match a
  # live :edit-share at this exact scope. On any other request it no-ops, so the
  # member path + the anonymous-deny path are byte-identical to before. An
  # anonymous write is denied by ResolveWorkspace (no token → membership gate
  # 403) — writes ALWAYS require a presented token.

  # Docs writes (mutate) — mirrors [:scoped_api, :require_token, :require_write,
  # :idempotent] with the edit-token grant spliced in.
  pipeline :scoped_mutate do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalToken)
    plug(BarkparkWeb.Plugs.RequireShareEditToken, surface: :docs)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.RequireWritePermission)
    plug(BarkparkWeb.Plugs.Idempotency)
  end

  # Media writes (upload/update/delete) — mirrors [:scoped_api, :media_mutate]
  # (keeps the session-cookie branch + AssignDefaultScope for the browser
  # Studio) with the edit-token grant spliced in before ResolveWorkspace.
  pipeline :scoped_media_mutate do
    plug(:fetch_session)
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    # Cookie-aware soft-auth: bearer (API client / Web Component data-token) OR
    # session (browser Studio member), so the membership gate below sees a
    # session-only browser member too — and a bearer edit token reaches
    # RequireShareEditToken. Anon passes through to be denied by ResolveWorkspace.
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.RequireShareEditToken, surface: :media)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
    # Final gate: a credential MUST be present (halts anon), and the session
    # branch is CSRF-checked here (bearer callers return before the CSRF check).
    plug(BarkparkWeb.Plugs.RequireBearerOrSessionToken)
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
  end

  # Tenancy-aware variant of :browser for the path-scoped plugin LiveView
  # mounts at /w/:workspace_slug/p/:project_slug/{studio,admin}. The base
  # :browser plugs (session, flash, CSRF, secure headers, root layout), then
  # the two resolver plugs so the plugin LiveViews participate in the hard
  # tenant boundary — `current_workspace` / `current_project` land in the
  # conn assigns, threaded into the LV session for ScopeHelpers.scope_opts/1.
  # OptionalSessionToken runs first so ResolveWorkspace's membership gate
  # sees a token from EITHER a Bearer header OR the signed-in browser's
  # session cookie (`session["api_token"]`) — a real member with only the
  # cookie resolves their token and clears the gate instead of 403'ing
  # before mount. The LV's own on_mount admin/ops hook is the UI auth gate.
  pipeline :scoped_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    # Anonymous resolves the DEFAULT workspace only (P3 cutover — the flat
    # Studio's public-demo/dev posture carried onto the scoped surface);
    # every other anonymous scope still fails closed, token paths unchanged.
    plug(BarkparkWeb.Plugs.ResolveWorkspace, allow_anonymous_default: true)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  # Optional token resolution for browser routes that only REDIRECT (the
  # flat-Studio 302s, P3): composes after :browser, supplies the
  # session/dev token the scope-resolution rule keys off. No gating —
  # anonymous passes through and resolves to the Default workspace.
  pipeline :soft_token do
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
  end

  # :scoped_browser + the :docs share gate (P4) — the scoped STUDIO pipeline.
  # An anonymous request for a `:docs`-shared scope is pre-resolved by
  # RequireShareScope (read-only; LiveScope attaches the server-side write
  # gate at mount); otherwise byte-identical to :scoped_browser — members via
  # membership, anonymous via the Default allowance, everything else closed.
  pipeline :shared_studio_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :docs)
    plug(BarkparkWeb.Plugs.ResolveWorkspace, allow_anonymous_default: true)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  # Public-share variant of :scoped_browser for the gated scoped paper reader
  # at /w/:ws/p/:project/papers/:slug (P1b). RequireShareScope runs BEFORE the
  # resolvers: when the scope is shared for the :papers surface (via
  # Barkpark.Sharing) it pre-resolves the workspace+project and flags
  # :share_public, so ResolveWorkspace SKIPS its membership gate (anonymous
  # read of a shared scope). When the scope is NOT shared — the default
  # everywhere — RequireShareScope is a pure no-op and ResolveWorkspace gates
  # membership byte-identically to a normal scoped request. OptionalSessionToken
  # still runs so a signed-in member reaches their own non-shared paper via the
  # membership gate exactly as on :scoped_browser.
  pipeline :shared_paper_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :papers)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  pipeline :api_unlimited do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
  end

  pipeline :api_preview do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.PreviewToken)
    # Tenancy shim: the flat /v1/preview/* routes carry no /w/:ws/p/:project
    # slugs, so without this the preview-JWT draft reads ran UNSCOPED across
    # every workspace (B9/barkpark-6xd9). Mirror :api — infer the seeded
    # Default workspace/project. A path-scoped preview route (under
    # /w/:ws/p/:project) sets the real scope via the resolvers, and
    # AssignDefaultScope no-ops once an assign is already present.
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
  end

  pipeline :require_token do
    plug(BarkparkWeb.Plugs.RequireToken)
  end

  # Base pipeline for the core user-auth API (/v1/auth/*). Like :api but without
  # the api-token/tenancy plugs (auth is pre-tenant) and WITH :fetch_session so
  # login can set the signed `user_session` cookie. RateLimit keys on IP here
  # (anonymous), which is the brute-force defense for login.
  pipeline :user_auth do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(:fetch_session)
  end

  # Core user-login session gate (distinct from API-token auth). Accepts the
  # `POST /v1/auth/login` bearer or the signed `user_session` cookie; assigns
  # :current_user + a :user CallerContext.
  pipeline :require_user do
    plug(BarkparkWeb.Plugs.RequireUserSession)
  end

  # Browser Studio uploads send `credentials: same-origin` with the session
  # cookie; API clients still use Bearer. Requires `:fetch_session` upstream.
  pipeline :media_mutate do
    plug(:fetch_session)
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.RequireBearerOrSessionToken)
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
  end

  # Ingest endpoints: JSON in, shared-secret bearer auth (NOT the api_tokens
  # table). Used by the Bulldocs paper-ingest API and any plugin that ships an
  # `auth: :ingest` route via the plugin highway.
  pipeline :ingest do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.RequireIngestToken)
  end

  pipeline :require_admin do
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.RequireAdmin)
  end

  # Scoped admin gate (barkpark-23yi / barkpark-fsko P0 fix). For the
  # /w/:ws/p/:project admin routes: require a token AND a membership ROLE of
  # owner/admin in the resolved `current_workspace`. RequireToken sets
  # :api_token; ResolveWorkspace (in :scoped_api) sets :current_workspace and
  # already gates :read membership; RequireWorkspaceRole reads the per-grant
  # role — so a `member` of B with global admin perms is 403'd on admin ops.
  # The FLAT admin routes keep :require_admin (global-perm gate) — the Default
  # workspace + the dev token's owner/admin Default membership keep them green.
  pipeline :scoped_admin do
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.RequireWorkspaceRole)
  end

  pipeline :idempotent do
    plug(BarkparkWeb.Plugs.Idempotency)
  end

  # Write-gate: rejects tokens lacking "write"/"admin" with 403 before the
  # mutation reaches the controller. Must run after :require_token.
  pipeline :require_write do
    plug(BarkparkWeb.Plugs.RequireWritePermission)
  end

  # Bare /studio and / redirect to the session-resolved SCOPED Studio
  # (P3 cutover — see PageController.redirect_to_studio for the
  # resolution rule). The :soft_token pipeline supplies the optional
  # session/dev token the resolution keys off.
  scope "/", BarkparkWeb do
    pipe_through([:browser, :soft_token])
    get("/", PageController, :redirect_to_studio)
    get("/studio", PageController, :redirect_to_studio)
  end

  # ── Session login (paste API token) ─────────────────────────────────
  scope "/", BarkparkWeb do
    pipe_through(:browser)

    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    post("/logout", SessionController, :delete)
  end

  # ── Bulldocs paper reader (LiveView) ────────────────────────────────────
  # The public reader at `/papers/:slug` is now contributed by the Bulldocs
  # plugin via the `:public_root` route bucket — see
  # `Barkpark.Plugins.Bulldocs.register_routes/1` and the
  # `scope "/" … plugin_routes(scope: :public_root)` block below. It mounts
  # `BarkparkWeb.BulldocsLive` in its own live_session with the full-document
  # `:bulldocs` root layout: byte-identical URL + layout to the former hardcoded
  # `scope "/papers"`, just sourced from the plugin. (The route template still
  # matches the `/papers/{slug}` reader URL.)

  # ── Bulldocs paper ingest (JSON POST) — back-compat alias ───────────────
  # The CANONICAL ingest API is now the Bulldocs plugin's `/v1/plugins/bulldocs/*`
  # (the `:ingest` route bucket — see `Barkpark.Plugins.Bulldocs.register_routes/1`).
  # These flat `/v1/paperflow/*` routes are kept as a back-compat alias for legacy
  # external producers that have not yet repointed — same controllers, same
  # `:ingest` (RequireIngestToken) pipeline. The path name is historical; it is an
  # EXTERNAL contract, so do NOT drop it unilaterally (see docs/decisions/deferred.md).
  scope "/v1/paperflow", BarkparkWeb do
    pipe_through(:ingest)

    post("/papers", BulldocsIngestController, :ingest)
    # Wave 4 block-ingest: POST a single DocPatchOp for a slug. Same bearer
    # auth; applies via Content.apply_paper_block_op, broadcasts a delta frame.
    post("/papers/:slug/ops", BulldocsIngestController, :apply_op)
    # Loop-closer: the external reader loop drains pending action:*/simplify-*
    # intents here, then marks each done.
    get("/intents", BulldocsIntentsController, :index)
    post("/intents/:id/processed", BulldocsIntentsController, :mark_processed)
  end

  # ── Studio admin (LiveView) — admin-gated via on_mount ──────────────────
  scope "/studio", BarkparkWeb.Studio do
    pipe_through(:browser)

    live_session :admin_studio,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}, {BarkparkWeb.StudioChrome, :default}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live("/settings", SettingsLive)
    end
  end

  # ── Back-compat redirects: legacy host-namespaced admin URLs ──────────
  # When a plugin admin LV migrates from host namespace into a plugin's
  # own namespace via `plugin_routes(scope: :ops)`, its URL prefix
  # changes from `/admin/<lv>` to `/admin/<plugin>/<lv>`. The redirect
  # controller below preserves old deep links via 301. New legacy paths
  # only get an entry when the URL prefix genuinely changes — when the
  # original URL already includes the plugin slug, no redirect is needed.
  scope "/admin", BarkparkWeb do
    pipe_through(:browser)

    get("/bokbasen", LegacyRedirectController, :bokbasen)
  end

  # ── Back-compat redirects (must come BEFORE the StudioLive catch-all) ───
  # The dedicated OnixEdit BookEditor / BookView LiveViews were removed in
  # Goal barkpark-zdy. `book` documents now open in native StudioLive at
  # `/studio/:dataset/book/:doc_id`. These two redirects keep old deep links
  # working — including the `?tab=…` query string the old editor used.
  scope "/studio/:dataset", BarkparkWeb do
    pipe_through([:browser, :soft_token])

    get("/onixedit/book/:doc_id", LegacyRedirectController, :onixedit_book)
    get("/onixedit/book/:doc_id/view", LegacyRedirectController, :onixedit_book)
  end

  # ── Plugin-contributed routes — admin-gated (Goal barkpark-G2 s3) ─────
  # `plugin_routes(scope: :admin)` expands at compile time to one
  # Phoenix.Router AST node per `{:live, …}` / `{:get, …}` / etc. tuple
  # returned by each plugin's `register_routes/1` callback whose `:auth`
  # opt resolves to `:admin` (the default when omitted). Plugin paths
  # include the slug — the plugin returns `"/onixedit/ping"` and the
  # `scope "/studio"` here contributes the `/studio` prefix → final
  # `/studio/onixedit/ping`. MUST come before the `/studio/:dataset`
  # catch-all scope below.
  #
  # NOTE: this scope intentionally omits the second `BarkparkWeb` alias
  # arg that other scopes carry. Plugin modules are fully qualified by
  # the route specs returned from each plugin's `register_routes/1`
  # callback — passing a host alias here would cause Phoenix's `scope`
  # macro to prepend `BarkparkWeb.` to those names, breaking module
  # resolution.
  scope "/studio" do
    pipe_through(:browser)

    live_session :plugin_admin,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}, {BarkparkWeb.StudioChrome, :default}],
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :admin)
    end
  end

  # ── Plugin-contributed routes — public (`auth: :public`) ──────────────
  # For plugin-supplied routes that opt out of the admin gate via
  # `auth: :public` (or the legacy `auth: :none`) in the route spec opts
  # (e.g. OAuth callbacks). No `on_mount` admin hook; plugins handle
  # their own auth inside the LV. Same no-alias rationale as the
  # `:plugin_admin` scope above.
  scope "/studio" do
    pipe_through(:browser)

    live_session :plugin_public,
      on_mount: [{BarkparkWeb.StudioChrome, :default}],
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :public)
    end
  end

  # ── Plugin-contributed routes — ops-gated (`auth: :ops`) ──────────────
  # Goal barkpark-G3 s3. Mirrors the host's `:admin_ops` scope at
  # `/admin` — same `:browser` pipeline, same `BarkparkWeb.LiveAuth.:ops`
  # on_mount hook. Plugins that contribute an ops route write paths
  # relative to `/admin/<plugin-slug>/` (e.g.
  # `"/onixedit/staleness"` → `/admin/onixedit/staleness`).
  # No-op until a plugin contributes a spec with `auth: :ops` (G3 s4
  # migrates Bokbasen + onixedit staleness; until then this expands to
  # an empty live_session, which Phoenix accepts cleanly).
  # Same no-alias rationale as the `:plugin_admin` scope above —
  # plugin LV modules are fully qualified.
  scope "/admin" do
    pipe_through(:browser)

    live_session :plugin_ops,
      on_mount: [{BarkparkWeb.LiveAuth, :ops}, {BarkparkWeb.StudioChrome, :default}],
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :ops)
    end
  end

  # ── Plugin-contributed routes — API (`auth: :api`) ────────────────────
  # Goal barkpark-G3 s3. Mirrors the host's `/v1/plugins/onixedit`
  # scope — `[:api, :require_admin]` pipeline, controller routes only
  # (no live_session). Plugins that contribute an API route write paths
  # relative to `/v1/plugins/<plugin-slug>/` (e.g.
  # `"/onixedit/export/:dataset/:id"` → `/v1/plugins/onixedit/export/...`).
  # No-op until a plugin contributes a spec with `auth: :api` (G3 s5
  # migrates the OnixEdit export controller).
  # Same no-alias rationale as the `:plugin_admin` scope — plugin
  # controller modules are fully qualified.
  scope "/v1/plugins" do
    pipe_through([:api, :require_admin])

    plugin_routes(scope: :api)
  end

  # ── Plugin-contributed routes — token-gated (`auth: :token`) ──────────
  # Mirror of the `:api` bucket above, but gated by `[:api, :require_token]`
  # instead of `[:api, :require_admin]` — i.e. AUTHENTICATED (valid api_tokens
  # bearer) but NOT requiring the admin role. For plugin CONTROLLER routes that
  # any token holder may call, mounted under `/v1/plugins/<slug>/…`. No
  # live_session. Expands to nothing until a plugin contributes an `auth: :token`
  # route (dormant, like `:ingest`/`:public_root` were when first added).
  scope "/v1/plugins" do
    pipe_through([:api, :require_token])

    plugin_routes(scope: :token)
  end

  # ── Plugin-contributed routes — token-gated, ROOT-mounted (`auth: :token_root`) ─
  # Root-mounted sibling of the `:token` bucket above: same `[:api, :require_token]`
  # pipeline (authenticated bearer, NOT admin), but mounted at the host `/v1`
  # TOP-LEVEL scope instead of under `/v1/plugins`. A spec
  # `{:get, "/tasks/ready", Mod, :ready, auth: :token_root}` therefore lands at
  # `/v1/tasks/ready` — analogous to how `:public_root` (`scope "/"`) is the
  # root-mounted sibling of `:public` (`/studio`). Controller routes only, no
  # live_session. Coexists with the existing core `/v1` scopes (Phoenix allows
  # multiple `scope "/v1"` blocks). Expands to nothing until a plugin contributes
  # an `auth: :token_root` route (dormant, like `:token`/`:ingest`/`:public_root`
  # were when first added).
  # NOTE: no `BarkparkWeb` scope alias here. Plugin route specs declare their
  # controller fully-qualified (`BarkparkWeb.TasksController`); a scope alias
  # would double-prefix it to `BarkparkWeb.BarkparkWeb.TasksController`. Same
  # no-alias rationale as the `:ingest` (`/v1/plugins`) and `:public_root` (`/`)
  # plugin wrappers.
  scope "/v1" do
    pipe_through([:api, :require_token])

    plugin_routes(scope: :token_root)
  end

  # ── Plugin-contributed routes — public root-layout (`auth: :public_root`) ──
  # For plugin LiveViews that own a FULL-document root layout and mount at the
  # top level WITHOUT the studio chrome — e.g. the Bulldocs paper reader at
  # `/papers/:slug`. The plugin declares `root_layout:` in the route spec opts;
  # the `plugin_routes/1` macro wraps each such route in its OWN live_session
  # applying that layout (a per-route root layout the `:public` bucket can't
  # express, since that one is pinned to `/studio` + the studio layout). No
  # on_mount gate — these are public read surfaces and the plugin scopes its
  # own data. Same no-alias rationale as the other plugin scopes — plugin LV
  # modules are fully qualified. Expands to nothing until a plugin contributes
  # a `:public_root` route.
  scope "/" do
    pipe_through(:browser)

    plugin_routes(scope: :public_root)
  end

  # ── Plugin-contributed routes — ingest-token (`auth: :ingest`) ────────
  # For plugin CONTROLLER routes authenticated by the shared-secret ingest
  # token (`RequireIngestToken`) rather than an `api_tokens` bearer — e.g. the
  # Bulldocs paper-ingest API. Mounts under `/v1/plugins/<slug>/…` via the
  # `:ingest` pipeline (json + RequireIngestToken). Controller routes only, no
  # live_session. Expands to nothing until a plugin contributes an `:ingest`
  # route.
  scope "/v1/plugins" do
    pipe_through(:ingest)

    plugin_routes(scope: :ingest)
  end

  # ── Plugin-contributed routes — workspace/project-scoped mirrors ──────
  # Task barkpark-4tuu (Goal barkpark-G… W1). The four flat plugin mounts
  # above keep working as the Default-scoped back-compat alias (mirroring
  # how the rest of W1 left the flat `/v1/data`, `/media`, etc. in place);
  # these mirrors mount the SAME plugin routes under the path-based tenant
  # prefix `/w/:workspace_slug/p/:project_slug/{studio,admin,v1/plugins}` so
  # plugin routes participate in the hard tenant boundary.
  #
  # Pipelines:
  #   * browser scopes (admin/public/ops) use :scoped_browser — base
  #     :browser plugs + ResolveWorkspace/ResolveProject so the workspace +
  #     project land in conn assigns (ScopeHelpers.scope_opts/1 then reads
  #     them in the plugin LVs). The LV's own on_mount admin/ops hook stays
  #     the UI auth gate; ResolveWorkspace's membership gate enforces tenant
  #     isolation (tokenless scoped browser access → 403; the flat /studio,
  #     /admin paths remain the cookie-only back-compat surface).
  #   * the :api scope uses :scoped_api + :require_admin — identical to the
  #     flat /v1/plugins mount but with the resolvers replacing
  #     AssignDefaultScope, so the export controller is workspace-scoped.
  #
  # live_session names MUST be unique across the router, hence the
  # `scoped_plugin_*` prefix. Same no-alias rationale as the flat plugin
  # scopes — plugin modules are fully qualified by their route specs.
  scope "/w/:workspace_slug/p/:project_slug/studio" do
    pipe_through(:scoped_browser)

    live_session :scoped_plugin_admin,
      on_mount: [
        {BarkparkWeb.LiveAuth, :admin},
        {BarkparkWeb.PluginScopeSession, :scope},
        {BarkparkWeb.StudioChrome, :default}
      ],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :admin)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/studio" do
    pipe_through(:scoped_browser)

    live_session :scoped_plugin_public,
      on_mount: [{BarkparkWeb.PluginScopeSession, :scope}, {BarkparkWeb.StudioChrome, :default}],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :public)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/admin" do
    pipe_through(:scoped_browser)

    live_session :scoped_plugin_ops,
      on_mount: [
        {BarkparkWeb.LiveAuth, :ops},
        {BarkparkWeb.PluginScopeSession, :scope},
        {BarkparkWeb.StudioChrome, :default}
      ],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :ops)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/v1/plugins" do
    pipe_through([:scoped_api, :scoped_admin])

    plugin_routes(scope: :api)
  end

  # ── Scoped Studio (P1 of Scoped-by-URL — tsk-url-p1) ─────────────────────
  # THE canonical Studio address: workspace + project + dataset are URL
  # segments, not socket state — every scope level gets a marker
  # (`/w/<ws>/p/<proj>/d/<dataset>/studio`). The :scoped_browser conn
  # resolvers gate the DEAD render only (plugs never run for live
  # navigation), so the LiveScope on_mount resolves + authorizes from URL
  # params AND re-authorizes on every scope-changing live patch — see
  # BarkparkWeb.LiveScope.
  #
  # ORDERING: the `/d/:dataset/studio` prefix cannot swallow the scoped
  # plugin `/studio/<plugin-path>` scopes above (the old
  # `/studio/:dataset` form could — a plugin path like
  # /w/x/p/y/studio/onixedit/ping parsed as dataset="onixedit"). The
  # swallow-guard now lives on the BACK-COMPAT scope below, which keeps
  # the old wildcard shape and therefore MUST stay registered after the
  # scoped plugin `/studio` scopes.
  scope "/w/:workspace_slug/p/:project_slug/d/:dataset/studio", BarkparkWeb.Studio do
    pipe_through(:shared_studio_browser)

    live_session :scoped_studio,
      on_mount: [
        {BarkparkWeb.LiveAuth, :fetch_api_token},
        {BarkparkWeb.LiveScope, :resolve},
        {BarkparkWeb.StudioChrome, :default}
      ],
      layout: {BarkparkWeb.Layouts, :studio} do
      live("/", StudioLive)
      live("/media", MediaLive)
      live("/api-tester", ApiTesterLive)

      live("/*path", StudioLive)
    end
  end

  # ── Old scoped Studio form → /d/ canonical 302 ───────────────────────────
  # Back-compat for the pre-/d/ canonical `/w/:ws/p/:proj/studio/:dataset`.
  # Pure URL rewrite (every segment is already in the URL — no session
  # resolution); the canonical route above authorizes. 302, never 301.
  #
  # ORDERING (route-swallow guard): this scope's `:dataset` wildcard MUST
  # register AFTER the scoped plugin `/studio` scopes above — otherwise a
  # plugin path like /w/x/p/y/studio/onixedit/ping would parse here as
  # dataset="onixedit" and 302 away from the plugin. Same reasoning the
  # canonical scope carried before the /d/ move.
  scope "/w/:workspace_slug/p/:project_slug/studio/:dataset", BarkparkWeb do
    pipe_through(:browser)

    get("/", StudioRedirectController, :legacy_scoped)
    get("/*path", StudioRedirectController, :legacy_scoped)
  end

  # ── Studio admin LV — dataset-scoped, admin-gated ─────────────────────
  # Task barkpark-otv: plugin admin LV at `/studio/:dataset/_plugins`.
  # MUST come before the studio_public scope below — the catch-all
  # `live "/*path", StudioLive` inside `:studio_public` would otherwise
  # swallow the `_plugins` path. The leading underscore is a convention
  # signalling "admin / system route" (mirrors `_/` patterns in many
  # CMSes) and keeps the namespace clear of any future schema-named
  # path collisions.
  scope "/studio/:dataset", BarkparkWeb.Admin do
    pipe_through(:browser)

    live_session :admin_studio_dataset,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}, {BarkparkWeb.StudioChrome, :default}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live("/_plugins", PluginsLive)
      live("/_plugins/:plugin/settings", PluginSettingsLive)
    end
  end

  # ── Flat Studio → scoped 302 (P3 cutover, Scoped-by-URL) ─────────────────
  # The :studio_public live_session is GONE: /w/:ws/p/:proj/d/:dataset/studio
  # (the :scoped_studio session above) is the only Studio mount. Every flat
  # form 302s to the session-resolved scoped canonical, path + query
  # preserved — old bookmarks resolve AT LEAST as well as they did when the
  # workspace was silently picked in-socket, except the choice is now
  # visible and correctable in the address bar. 302 (never 301): the
  # resolution is session-dependent and must not be browser-cached.
  scope "/studio/:dataset", BarkparkWeb do
    pipe_through([:browser, :soft_token])

    get("/", StudioRedirectController, :studio)
    get("/*path", StudioRedirectController, :studio)
  end

  # ── Meta (SDK handshake) — no auth, no rate limit ───────────────────────
  scope "/v1", BarkparkWeb do
    pipe_through(:api_unlimited)

    get("/meta", MetaController, :index)
  end

  # ── Core user auth (login/sessions/MFA/email flows) — public entry ───────
  scope "/v1/auth", BarkparkWeb do
    pipe_through(:user_auth)

    post("/register", AuthController, :register)
    post("/login", AuthController, :login)
    post("/verify-email", AuthController, :verify_email)
    post("/request-reset", AuthController, :request_reset)
    post("/reset", AuthController, :reset)
  end

  # ── Core user auth — session-gated ──────────────────────────────────────
  scope "/v1/auth", BarkparkWeb do
    pipe_through([:user_auth, :require_user])

    get("/me", AuthController, :me)
    delete("/logout", AuthController, :logout)
    post("/mfa/enroll", AuthController, :mfa_enroll)
    post("/mfa/verify", AuthController, :mfa_verify)
    post("/mfa/disable", AuthController, :mfa_disable)
  end

  # ── Capabilities manifest (CLI/MCP/SDK contract) — optional token ───────
  # The `:api` pipeline runs `OptionalToken`, so the controller resolves the
  # caller's tier (none when anonymous) and projects the manifest through the
  # existence-hiding allow-list keyed on it.
  scope "/v1", BarkparkWeb do
    pipe_through(:api)

    get("/capabilities", CapabilitiesController, :index)
  end

  # ── Federated discovery ─────────────────────────────────────────────────
  scope "/v1", BarkparkWeb do
    pipe_through(:api)

    get("/search/:dataset", FederatedSearchController, :search)
  end

  # ── Public API — read-only, respects schema visibility ──────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through(:api)

    get("/search/:dataset/suggestions", SearchController, :search_suggestions)
    post("/search/:dataset/interaction", SearchController, :search_interaction)
    post("/search/:dataset/correction", SearchController, :correction)
    get("/search/:dataset", SearchController, :search)
    get("/query/:dataset/:type", QueryController, :index)
    get("/doc/:dataset/:type/:doc_id", QueryController, :show)
  end

  # ── Localhost fast-path search (Barkpark Cloud P4 / Move B) ──────────────
  # The co-located Next.js site on the same box queries search over loopback;
  # the standard /v1/data/search pipeline pays for OptionalToken, RateLimit,
  # tenancy back-compat, and request logging on every keystroke. This lane
  # gates on RequireLoopback only — a non-loopback caller gets a silent 403.
  # The body skips auth-derived scope and accepts workspace_id/project_id in
  # query params, since the co-located caller already knows them.
  scope "/v1/data", BarkparkWeb do
    pipe_through(:api_local)

    get("/local/search/:dataset", SearchController, :search_local)
  end

  # ── Preview — same reads, forces perspective=drafts via preview JWT ─────
  scope "/v1/preview", BarkparkWeb do
    pipe_through(:api_preview)

    get("/query/:dataset/:type", QueryController, :index)
    get("/doc/:dataset/:type/:doc_id", QueryController, :show)
  end

  # ── Private API — full CRUD, requires token ─────────────────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through([:api, :require_token])

    get("/listen/:dataset", ListenController, :listen)
    # Trigger an Indx blue/green rebuild for the scope (token-gated; any member
    # token, e.g. the public-read token the web demo holds). Oban-unique per
    # scope, so concurrent triggers collapse into one rebuild.
    post("/search/:dataset/reindex", SearchController, :reindex)
    get("/export/:dataset", ExportController, :export)

    get("/analytics/:dataset", AnalyticsController, :index)

    get("/history/:dataset/:type/:doc_id", HistoryController, :index)
    get("/revision/:dataset/:id", HistoryController, :show)
    post("/revision/:dataset/:id/restore", HistoryController, :restore)
  end

  # ── Mutations — token + idempotency dedup ──────────────────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through([:api, :require_token, :require_write, :idempotent])

    post("/mutate/:dataset", MutateController, :mutate)
  end

  # ── Tasks API surface ───────────────────────────────────────────────────
  # The task endpoints live in `Barkpark.Plugins.Tasks`' `register_routes/1`
  # (auth: :token_root) and mount via the dormant
  # `scope "/v1" … plugin_routes(scope: :token_root)` wrapper above (C4-3b).
  # The flat `scope "/v1/tasks"` block was deleted — the plugin OWNS its routes.

  # ── Content graph reads — CORE, not the Tasks plugin (fresh-install) ────
  # Goal ges/graph-edge-seam. The content graph roots on ANY content doc (gap
  # #4 — not task-specific), so its read surface is mounted from CORE here,
  # NOT inside the disable-able Tasks plugin. Under the documented kill switch
  # `config :barkpark, :plugins, []` the plugin's `register_routes/1` /
  # `cli_commands/0` collapse to `[]`; mounting these in core keeps
  # `/v1/graph/*` (and the matching `graph.*` core verbs) alive so the feature
  # still works end-to-end with all plugins off (the '/v1/graph serves a
  # non-empty graph' invariant). Same `[:api, :require_token]` pipeline the
  # plugin's `:token_root` bucket used (authenticated bearer, NOT admin).
  #
  # Static routes (orphans/dangling) MUST mount BEFORE the dynamic `/graph/:id`
  # or Phoenix matches the literals as `:id` (the documented static/dynamic
  # disambiguation idiom, same as `/tasks/prime`). The `TasksController` keeps
  # the `graph_orphans` / `graph_dangling` / `graph_show` actions — only the
  # route DECLARATION moved from the plugin into core.
  scope "/v1", BarkparkWeb do
    pipe_through([:api, :require_token])

    # Whole-dataset graph (all nodes + all edges) — backs the Web finder's
    # interactive landing graph. MUST precede the dynamic `/graph/:id`.
    get("/graph", TasksController, :graph_corpus)
    get("/graph/orphans", TasksController, :graph_orphans)
    get("/graph/dangling", TasksController, :graph_dangling)
    get("/graph/:id", TasksController, :graph_show)
  end

  scope "/v1/data", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/search/:dataset/insights", SearchController, :search_insights)
    get("/search/:dataset/settings", SearchController, :search_settings)
    put("/search/:dataset/settings", SearchController, :update_search_settings)
    get("/search/:dataset/synonyms", SearchController, :search_synonyms)
    get("/search/:dataset/synonyms/preview", SearchController, :preview_search_synonym)
    post("/search/:dataset/synonyms", SearchController, :create_search_synonym)
    post("/search/:dataset/synonyms/promote", SearchController, :promote_search_synonym)
    delete("/search/:dataset/synonyms/:id", SearchController, :delete_search_synonym)
  end

  # ── Desk structure — the canonical Studio tree, served for the TUI ──────
  scope "/v1/structure", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/:dataset", StructureController, :show)
  end

  # ── Schema management — requires admin token ────────────────────────────
  scope "/v1/schemas", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/:dataset", SchemaController, :index)
    get("/:dataset/:name", SchemaController, :show)
    post("/:dataset", SchemaController, :upsert)
    delete("/:dataset/:name", SchemaController, :delete)
  end

  # ── Plugin roster — admin-only installed-plugin index ──────────────────
  # The real route behind the capabilities manifest's `plugin.ls` core command.
  # Bare `/v1/plugins` (no trailing segment) so it never collides with the
  # `/v1/plugins/<slug>/…` plugin-contributed `:api` / `:ingest` route buckets
  # nor the `/v1/plugins/settings/:plugin_name` CRUD scope below.
  scope "/v1/plugins", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/", PluginsController, :index)
  end

  # ── Plugin settings — admin-only encrypted-JSON CRUD ───────────────────
  scope "/v1/plugins/settings", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/:plugin_name", PluginSettingsController, :show)
    put("/:plugin_name", PluginSettingsController, :update)
    delete("/:plugin_name", PluginSettingsController, :delete)
  end

  # ── Cloud run-secrets — admin-only encrypted store ─────────────────────
  # GET /:name REVEALS the unmasked value (audited); the list stays masked.
  scope "/v1/secrets", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/", SecretController, :index)
    get("/:name", SecretController, :show)
    put("/:name", SecretController, :update)
    delete("/:name", SecretController, :delete)
  end

  # ── Webhooks — requires admin token ────────────────────────────────────
  scope "/v1/webhooks", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/:dataset", WebhookController, :index)
    get("/:dataset/:id", WebhookController, :show)
    post("/:dataset", WebhookController, :create)
    put("/:dataset/:id", WebhookController, :update)
    delete("/:dataset/:id", WebhookController, :delete)
  end

  # ── Scoped sharing — admin-only registry CRUD (P4b) ────────────────────
  # The HTTP surface behind `bp share ls/add/rm` + the Studio Shares panel.
  # DECLARING a share is admin-only; the surfaces a share then opens (the
  # anonymous reader/query/media routes) are gated separately by
  # RequireShareScope. Writes go through Barkpark.Sharing, which validates +
  # refreshes the live list (no restart).
  scope "/v1/shares", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/", ShareController, :index)
    post("/", ShareController, :create)
    delete("/", ShareController, :delete)

    # P5 edit-token management (admin-only minting, owner decision 2026-06-09).
    # mint_token shows the raw token ONCE; list_tokens never returns it; revoke
    # stamps revoked_at. The registry kill-switch (remove/downgrade the share)
    # also disables tokens live + batch-revokes via Sharing.remove_share/3.
    get("/tokens", ShareController, :list_tokens)
    post("/tokens", ShareController, :mint_token)
    delete("/tokens/:token_id", ShareController, :revoke_token)

    # P7 ITEM (per-document) share links — Google-Docs-style direct links to ONE
    # paper/doc/media. Admin-only mint (raw token shown once) / list-per-item /
    # revoke; the public reader is GET /s/:token below.
    get("/links", ShareLinkController, :list)
    post("/links", ShareLinkController, :mint)
    delete("/links/:id", ShareLinkController, :revoke)
  end

  # P7 ITEM share-link PUBLIC reader — resolves the opaque token to its bound
  # item, scoped to the LINK's own workspace (independent of section shares), and
  # serves it: a paper renders its reader page, another doc returns published
  # data, media serves the file. Browser pipeline for the paper HTML render.
  scope "/", BarkparkWeb do
    pipe_through(:browser)

    get("/s/:token", ShareLinkController, :show)
  end

  pipeline :media_processing_callback do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RequireMediaProcessingCallbackToken)
  end

  # ── Media — upload requires token, serving is public ────────────────────
  scope "/media", BarkparkWeb do
    pipe_through(:api)

    get("/renditions/:id/:preset", MediaController, :serve_rendition)
    get("/", MediaController, :index)
    get("/:id/meta", MediaController, :show)
    get("/files/*path", MediaController, :serve)
  end

  scope "/media", BarkparkWeb do
    pipe_through(:media_mutate)

    post("/upload", MediaController, :upload)
    delete("/:id", MediaController, :delete)
  end

  # ── v1 Media — unified blob + mediaAsset metadata ───────────────────────
  scope "/v1/media", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/:dataset/search/insights", V1.MediaController, :search_insights)
    get("/:dataset/search/settings", V1.MediaController, :search_settings)
    put("/:dataset/search/settings", V1.MediaController, :update_search_settings)
    get("/:dataset/search/synonyms", V1.MediaController, :search_synonyms)
    get("/:dataset/search/synonyms/preview", V1.MediaController, :preview_search_synonym)
    post("/:dataset/search/synonyms", V1.MediaController, :create_search_synonym)
    post("/:dataset/search/synonyms/promote", V1.MediaController, :promote_search_synonym)
    delete("/:dataset/search/synonyms/:id", V1.MediaController, :delete_search_synonym)
  end

  scope "/v1/media", BarkparkWeb do
    pipe_through(:api)

    get("/:dataset/search/suggestions", V1.MediaController, :search_suggestions)
    post("/:dataset/search/interaction", V1.MediaController, :search_interaction)
    get("/:dataset/search", V1.MediaController, :search)
    get("/:dataset/share/:token", V1.MediaCollectionsController, :share_view)
    get("/:dataset/collections", V1.MediaCollectionsController, :index)
    get("/:dataset/collections/:id/assets", V1.MediaCollectionsController, :assets)
    get("/:dataset/collections/:id", V1.MediaCollectionsController, :show)
    get("/:dataset/:id/relations", V1.MediaController, :relations)
    get("/:dataset", V1.MediaController, :index)
    get("/:dataset/:id", V1.MediaController, :show)
  end

  scope "/v1/media", BarkparkWeb do
    pipe_through(:media_processing_callback)

    post("/:dataset/processing/:id/callback", V1.MediaProcessingController, :callback)
  end

  scope "/v1/media", BarkparkWeb do
    pipe_through(:media_mutate)

    post("/:dataset/collections/:id/share", V1.MediaCollectionsController, :share)
    delete("/:dataset/collections/:id/share", V1.MediaCollectionsController, :revoke_share)
    post("/:dataset/collections/:id/members", V1.MediaCollectionsController, :add_member)

    delete(
      "/:dataset/collections/:id/members/:asset_id",
      V1.MediaCollectionsController,
      :remove_member
    )

    post("/:dataset/upload", V1.MediaController, :upload)
    post("/:dataset/:id/checkout", V1.MediaController, :checkout)
    post("/:dataset/:id/undo-checkout", V1.MediaController, :undo_checkout)
    patch("/:dataset/:id", V1.MediaController, :update)
    delete("/:dataset/:id", V1.MediaController, :delete)
  end

  # ── Gated scoped paper reader (P1b) ─────────────────────────────────────
  # Read-only HTML paper at /w/:ws/p/:project/papers/:slug, scoped to the
  # resolved workspace/project. Anonymous access ONLY when that scope is shared
  # for the :papers surface (Barkpark.Sharing); otherwise the :shared_paper_browser
  # pipeline's membership gate (ResolveWorkspace) denies exactly as a normal
  # scoped request. Placed BEFORE the broad scoped-data block — the `/papers/:slug`
  # path doesn't collide with any of the `/v1/…` scoped routes, but keeping the
  # dedicated-pipeline route ahead of the catch-alls keeps intent obvious.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through(:shared_paper_browser)

    # LIVE scoped reader (P4): the same BulldocsLive as the flat /papers/:slug
    # surface — per-block real-time streaming included (the paper PubSub topic
    # is already ws-keyed) — mounted behind the share/membership gates above.
    # PluginScopeSession bridges the dead-render-resolved scope into the LV
    # session; safe here because the reader never live-navigates across
    # scopes. The dead-render ScopedPaperController is retired from routing
    # (its HTML view lives on under /s/:token).
    live_session :scoped_paper_reader,
      on_mount: [{BarkparkWeb.PluginScopeSession, :scope}],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      root_layout: {BarkparkWeb.Layouts, :bulldocs} do
      live("/papers/:slug", BulldocsLive, :index)
    end
  end

  # ── Scoped tenancy routes ───────────────────────────────────────────────
  # Path-based tenancy: /w/:workspace_slug/p/:project_slug/… mirrors the flat
  # content data routes above. The `:scoped_api` pipeline resolves + membership-
  # gates the workspace (403 cross-dataset read-leak fix) and resolves the
  # project before routing. The `:dataset` segment stays the leaf — dataset is
  # still a string in Wave 1; WHERE-clause scoping by workspace_id is a sibling
  # CONTEXT task. The flat routes below remain the back-compat alias.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through(:scoped_api)

    # Public reads (mirror of /v1/data public scope)
    get("/v1/data/search/:dataset/suggestions", SearchController, :search_suggestions)
    post("/v1/data/search/:dataset/interaction", SearchController, :search_interaction)
    post("/v1/data/search/:dataset/correction", SearchController, :correction)
    get("/v1/data/search/:dataset", SearchController, :search)
    get("/v1/search/:dataset", FederatedSearchController, :search)

    # Preview reads
    get("/v1/preview/query/:dataset/:type", QueryController, :index)
    get("/v1/preview/doc/:dataset/:type/:doc_id", QueryController, :show)
  end

  # Scoped READ document routes — share-aware via the :docs surface (P2). These
  # GET reads sit on the :shared_docs_api pipeline so a `:docs`-shared scope is
  # anonymous-readable; the method-aware RequireShareScope keeps a `:read` share
  # from ever opening the separate POST mutate block. Without a matching :docs
  # share (the default) this is byte-identical to :scoped_api.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through(:shared_docs_api)

    get("/v1/data/query/:dataset/:type", QueryController, :index)
    get("/v1/data/doc/:dataset/:type/:doc_id", QueryController, :show)
  end

  # Scoped media surface (P3) — READ-only. A `:media`-shared scope is public
  # here; otherwise gated. Only the SCOPE-SAFE actions are exposed: index /
  # show / serve / renditions all resolve files via the resolved workspace
  # scope, so a share can never reach another workspace's media. The rendition
  # route joined in P4 once `serve_rendition` became scope-bounded (the P0 fix
  # ended its unscoped get_file/1 cross-scope leak — non-Default renditions
  # are served HERE, never on the Default-pinned flat route). upload/delete
  # (writes) stay excluded. Without a matching :media share this is
  # byte-identical to a normal scoped request.
  scope "/w/:workspace_slug/p/:project_slug/media", BarkparkWeb do
    pipe_through(:shared_media_api)

    get("/", MediaController, :index)
    get("/:id/meta", MediaController, :show)
    get("/files/*path", MediaController, :serve)
    get("/renditions/:id/:preset", MediaController, :serve_rendition)
  end

  # Token-required scoped reads (listen/export/analytics/history/revision).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :require_token])

    get("/v1/data/listen/:dataset", ListenController, :listen)
    get("/v1/data/export/:dataset", ExportController, :export)
    get("/v1/data/analytics/:dataset", AnalyticsController, :index)
    get("/v1/data/history/:dataset/:type/:doc_id", HistoryController, :index)
    get("/v1/data/revision/:dataset/:id", HistoryController, :show)
    post("/v1/data/revision/:dataset/:id/restore", HistoryController, :restore)
  end

  # Scoped mutations — the :scoped_mutate pipeline carries the member write-gate
  # AND the P5 edit-token grant (a scope-bound edit token writes here too).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through(:scoped_mutate)

    post("/v1/data/mutate/:dataset", MutateController, :mutate)
  end

  # Scoped admin reads (search insights/synonyms).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/data/search/:dataset/insights", SearchController, :search_insights)
    get("/v1/data/search/:dataset/synonyms", SearchController, :search_synonyms)
    post("/v1/data/search/:dataset/synonyms", SearchController, :create_search_synonym)
    delete("/v1/data/search/:dataset/synonyms/:id", SearchController, :delete_search_synonym)
  end

  # Scoped schema management (admin).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/structure/:dataset", StructureController, :show)
    get("/v1/schemas/:dataset", SchemaController, :index)
    get("/v1/schemas/:dataset/:name", SchemaController, :show)
    post("/v1/schemas/:dataset", SchemaController, :upsert)
    delete("/v1/schemas/:dataset/:name", SchemaController, :delete)
  end

  # Scoped token mint (admin) — mints a READ-ONLY, workspace-bound token. Same
  # :scoped_admin gate as schema management (owner/admin role in the resolved
  # workspace). The controller hard-restricts the mintable permission set to a
  # read-only allowlist (public-read/read) so this can never be a privilege-mint.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    post("/v1/tokens", TokenController, :create)
  end

  # Scoped webhooks (admin).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/webhooks/:dataset", WebhookController, :index)
    get("/v1/webhooks/:dataset/:id", WebhookController, :show)
    post("/v1/webhooks/:dataset", WebhookController, :create)
    put("/v1/webhooks/:dataset/:id", WebhookController, :update)
    delete("/v1/webhooks/:dataset/:id", WebhookController, :delete)
  end

  # Scoped v1 media — admin search ops.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/media/:dataset/search/insights", V1.MediaController, :search_insights)
    get("/v1/media/:dataset/search/synonyms", V1.MediaController, :search_synonyms)
    post("/v1/media/:dataset/search/synonyms", V1.MediaController, :create_search_synonym)
    delete("/v1/media/:dataset/search/synonyms/:id", V1.MediaController, :delete_search_synonym)
  end

  # Scoped v1 media — public reads.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through(:scoped_api)

    get("/v1/media/:dataset/search/suggestions", V1.MediaController, :search_suggestions)
    post("/v1/media/:dataset/search/interaction", V1.MediaController, :search_interaction)
    get("/v1/media/:dataset/search", V1.MediaController, :search)
    get("/v1/media/:dataset/share/:token", V1.MediaCollectionsController, :share_view)
    get("/v1/media/:dataset/collections", V1.MediaCollectionsController, :index)
    get("/v1/media/:dataset/collections/:id/assets", V1.MediaCollectionsController, :assets)
    get("/v1/media/:dataset/collections/:id", V1.MediaCollectionsController, :show)
    get("/v1/media/:dataset/:id/relations", V1.MediaController, :relations)
    get("/v1/media/:dataset", V1.MediaController, :index)
    get("/v1/media/:dataset/:id", V1.MediaController, :show)
  end

  # Scoped v1 media — collection + lock writes (member-only, bearer-or-session).
  # Collections management + checkout stay membership-gated; they are NOT part of
  # the shareable :media surface (P5 shares asset upload/update/delete only).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :media_mutate])

    post("/v1/media/:dataset/collections/:id/share", V1.MediaCollectionsController, :share)

    delete(
      "/v1/media/:dataset/collections/:id/share",
      V1.MediaCollectionsController,
      :revoke_share
    )

    post("/v1/media/:dataset/collections/:id/members", V1.MediaCollectionsController, :add_member)

    delete(
      "/v1/media/:dataset/collections/:id/members/:asset_id",
      V1.MediaCollectionsController,
      :remove_member
    )

    post("/v1/media/:dataset/:id/checkout", V1.MediaController, :checkout)
    post("/v1/media/:dataset/:id/undo-checkout", V1.MediaController, :undo_checkout)
  end

  # Scoped v1 media — asset upload/update/delete. The :scoped_media_mutate
  # pipeline serves a member (membership) AND a :media-edit-token holder (P5).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through(:scoped_media_mutate)

    post("/v1/media/:dataset/upload", V1.MediaController, :upload)
    patch("/v1/media/:dataset/:id", V1.MediaController, :update)
    delete("/v1/media/:dataset/:id", V1.MediaController, :delete)
  end

  # ── Workspace / project switcher — membership-scoped LIST ───────────────
  # The web switcher's read surface: which workspaces (and their projects) the
  # bearer token's principal can reach. Membership-scoped in the context layer
  # (`Tenancy.list_workspaces_for/1` INNER-JOINs `workspace_memberships`), so a
  # non-member workspace never appears; the :projects action returns 404 for a
  # non-member to avoid leaking existence. Token-gated only — NOT the path
  # tenancy macro / scoped plugin mounts (those live under /w/:ws/p/:project).
  scope "/api", BarkparkWeb do
    pipe_through([:api, :require_token])

    get("/workspaces", WorkspaceController, :index)
    get("/workspaces/:workspace_slug/projects", WorkspaceController, :projects)

    # Create surface: any authenticated token may create a workspace (becomes
    # its owner-member, + Default project + production dataset); project
    # creation is member-gated (non-member → 404, no existence leak).
    post("/workspaces", WorkspaceController, :create)
    post("/workspaces/:workspace_slug/projects", WorkspaceController, :create_project)
  end

  # ── Legacy compat ──────────────────────────────────────────────────────
  # Deprecated back-compat for the Go TUI's original endpoints — the TUI
  # migrated OFF these (Goal barkpark-qprk, B14). Now token-gated (`:require_token`)
  # and Default-scoped: the `:api` pipeline's `AssignDefaultScope` seeds the
  # Default workspace/project, and `LegacyController` threads `scope_opts(conn)`
  # into the Content reads/writes — closing the unauthenticated + unscoped
  # tenancy hole while mirroring the flat `/v1/data` Default-scope contract.
  scope "/api", BarkparkWeb do
    pipe_through([:api, :require_token, BarkparkWeb.Plugs.LegacyDeprecation])

    get("/documents/:type", LegacyController, :index)
    get("/documents/:type/:id", LegacyController, :show)
    post("/documents/:type", LegacyController, :create)
    delete("/documents/:type/:id", LegacyController, :delete)
  end

  # Legacy public schema discovery — intentionally NOT token-gated. w15-E
  # over-gated this when it closed the B14 unauth hole on /api/documents/*;
  # /api/schemas is public read, already Default-scoped via AssignDefaultScope
  # in the :api pipeline. Kept :LegacyDeprecation so the deprecation headers
  # still ride along.
  scope "/api", BarkparkWeb do
    pipe_through([:api, BarkparkWeb.Plugs.LegacyDeprecation])

    get("/schemas", LegacyController, :schemas)
  end

  if Application.compile_env(:barkpark, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through([:fetch_session, :protect_from_forgery])
      live_dashboard("/dashboard", metrics: BarkparkWeb.Telemetry)
    end
  end
end
