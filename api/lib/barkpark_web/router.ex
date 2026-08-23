defmodule BarkparkWeb.Router do
  use BarkparkWeb, :router

  # Compile-time macro that folds plugin-contributed routes into the host
  # router. See `BarkparkWeb.Router.Plugins` and Goal barkpark-G2.
  import BarkparkWeb.Router.Plugins

  # Tailored, script-blocking CSP (task-0fc9d55c). The static map on
  # put_secure_browser_headers is what Sobelow's syntactic Config.CSP check
  # credits (a downstream plug is invisible to it); BrowserCsp then replaces the
  # header with the real per-request value — a `script-src` with a per-request
  # nonce (for the inline <script> blocks), 'unsafe-hashes' for the enumerated
  # Studio inline handlers, cdn.jsdelivr.net (mermaid) and no 'unsafe-inline'.
  # style-src is left untightened. Full rationale: BarkparkWeb.CSP @moduledoc.
  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "script-src 'self' https://cdn.jsdelivr.net; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    })

    plug(BarkparkWeb.Plugs.BrowserCsp)
  end

  pipeline :api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    # Baseline JSON security headers (nosniff + referrer-policy). The browser
    # pipelines get these via put_secure_browser_headers; the API surface did
    # not until now. No CSP/HSTS/frame headers here — see the plug's @moduledoc.
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalToken)
    # Back-compat tenancy shim: flat routes (no /w/:ws/p/:project slugs in the
    # path) infer the seeded Default Workspace/Project so downstream code always
    # has a scope. No-op once a resolver has already set the assigns.
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
    # Stamp the resolved tenant scope onto Logger.metadata so every log line is
    # tenant-attributable (incident blast-radius). Cheap, no DB — see the plug.
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
  end

  # Flat CycleFleet commands must identify the same workspace as their token.
  # Unlike the legacy :api alias, token derivation happens before the Default
  # fallback so a local `bp cycle` invocation cannot silently operate on a
  # different cloud/default workspace.
  pipeline :cycle_api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.DeriveWorkspaceFromToken)
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
    # Structural backstop for the public-read tier on the flat CycleFleet read
    # (arpss-cycle-api-publicread-followup). The LIVE guard stays the controller
    # seal `CycleFleetController.authorize_cycle/3` (cycle_fleet_controller.ex:412),
    # which 403s a public-read token via `Plugs.PublicRead.public_read_token?/1`
    # — ONE tier definition, shared. This mount closes the STRUCTURAL gap the
    # seal cannot: a FUTURE flat read route added under `:cycle_api` would
    # silently reopen the class, because the plug denies deny-by-default while a
    # new controller action would have to re-derive the seal by hand. Mounted at
    # the TAIL so `:api_token` (RequireToken) and `:current_workspace`
    # (DeriveWorkspaceFromToken/AssignDefaultScope) are assigned before it runs.
    # The `/v1/cycles/:epic/:wave` path is not in the plug allowlist, so a
    # public-read token is denied with the plug canonical message; a read/write/
    # admin token no-ops through it (`public_read_token?/1` is false).
    plug(BarkparkWeb.Plugs.PublicRead)
  end

  # Grant-fold overlay for the FLAT `/v1/data` READ routes (airdrop-grants
  # ag-enforcement — flat-routes arm). Layered AFTER `:api` on the flat read
  # scope ONLY — NEVER on write/admin/auth/plugin routes. `ResolveTokenOwner`
  # resolves an OWNED api_token to its owner `:current_user` (non-halting, only
  # sets :current_user); `AssignGrantScope` then folds that user's grants and,
  # for a non-member grantee, flags `:grant_scoped_read` so `ScopeHelpers`
  # threads Layer-2 row narrowing. Members + unowned/service tokens are
  # byte-identical (the plug no-ops). Kept off writes because
  # `CallerContext.from_conn/1` prefers an assigned `:caller_context` over the
  # `:api_token` — setting it on a write could downgrade the caller.
  pipeline :api_grant_read do
    plug(BarkparkWeb.Plugs.ResolveTokenOwner)
    plug(BarkparkWeb.Plugs.AssignGrantScope)
    # Deny-by-default clamp for a `public-read`-only token (site-spawner D6):
    # published perspective + public-visibility schemas + GET query/doc only.
    # Runs AFTER OptionalToken (:api) assigned :api_token AND after
    # AssignDefaultScope (:api) set :current_workspace/:current_project, so the
    # schema-visibility check is scope-accurate. No-op for read/write/admin/anon.
    plug(BarkparkWeb.Plugs.PublicRead)
  end

  # SCIM 2.0 directory-sync — org-scoped bearer, no tenancy shim (era-w4).
  pipeline :scim do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.RequireScimToken)
  end

  # SSO browser redirect flows (OIDC, social login) — need a session to carry
  # state/nonce/PKCE-verifier across the round-trip (era-w3-oidc-rp, era-w2-social).
  #
  # Sobelow triage (task-f76e9b7b):
  #   * Config.Headers — FIXED. SamlController.slo renders a real HTML page (the
  #     esaml HTTP-POST LogoutResponse auto-submit form, saml_controller.ex:118)
  #     that was served with NO secure headers. put_secure_browser_headers now
  #     adds X-Frame-Options/nosniff/referrer-policy on every response this
  #     pipeline emits (redirects included) — clickjacking + MIME-sniff + Referer
  #     leakage of the SLO/callback tokens closed.
  #   * Config.CSRF — N/A (justified, stays baselined). These are FEDERATED flows:
  #     OIDC/social use the `state` param + PKCE verifier as the CSRF defense, and
  #     the SAML ACS/SLO endpoints are cross-site POST-backs from the IdP that
  #     structurally cannot carry a Phoenix CSRF token. protect_from_forgery would
  #     BREAK SSO. The session holds only transient state/nonce, never a trust
  #     anchor — the IdP assertion (XML-dsig, pinned cert) is what authenticates.
  #   * Config.CSP — FIXED (task-0fc9d55c). The static map below is credited by
  #     Sobelow's syntactic check; SamlController.slo replaces it per-request
  #     with a `script-src 'self' 'nonce-…'` matching the esaml auto-submit
  #     `<script nonce=…>` (esaml 4.6.0 emits a DOMContentLoaded handler, NOT an
  #     inline onload — the old "needs a form rewrite" note was stale; the
  #     nonce is threaded via encode_http_post/4). Redirect/JSON responses on
  #     this pipeline carry no inline script, so the strict static map fits them.
  pipeline :sso_browser do
    plug(:accepts, ["html", "json"])
    plug(:fetch_session)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "script-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    })
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
  #
  # Credential resolution is `:scoped_api_optional_credential` (below), NOT the
  # plain OptionalToken this pipeline used to run — that is the gyldendal #15
  # fix. Read its comment for the CSRF decision; the short version is that a
  # browser session is admitted as a credential here, and on a state-changing
  # method only behind the same `x-requested-with` check the media write
  # pipelines already use.
  pipeline :scoped_api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    # Parity with :api — baseline JSON security headers on the tenancy-aware
    # mirror serving the same /w/:ws/p/:project/v1/data/{query,doc}/* reads.
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(:scoped_api_optional_credential)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
  end

  # Soft credential resolution for :scoped_api — bearer ALWAYS, browser session
  # only where it cannot drive a forged state change (gyldendal field report
  # #15).
  #
  # THE BUG IT CLOSES. :scoped_api was the last media-adjacent pipeline with no
  # `:fetch_session` and no `OptionalSessionToken`, so `ResolveWorkspace`'s
  # `%User{}` arm was structurally unreachable on it: a signed-in Studio
  # operator whose browser carries only the `user_session` cookie (no account
  # login writes `session["api_token"]`, so the asset explorer renders
  # `data-token=""`) resolved as ANONYMOUS and the membership gate 403'd every
  # scoped media read. Proven live before the fix: anonymous flat
  # `/v1/media/production` → 200, but `/w/default/p/default/v1/media/production`
  # → 403 for the same operator. Media WRITES already authenticated a browser
  # session (`:scoped_media_mutate` opens with fetch_session +
  # OptionalSessionToken "so the membership gate below sees a session-only
  # browser member too"); media READS did not.
  #
  # THE CSRF DECISION, stated here because :scoped_api — unlike
  # :shared_media_api — also carries non-GET routes (search interaction, cycle
  # opens, scoped secrets, media synonyms, and the [:scoped_api, :media_mutate]
  # collections/checkout stack). We took BOTH halves of the constraint rather
  # than picking one:
  #
  #   * GET/HEAD — the cookie is admitted unconditionally. These are
  #     side-effect-free reads, which is precisely the justification
  #     :shared_media_api and :session_token_root already carry; a read is not a
  #     CSRF target, and `protect_from_forgery` is the wrong tool here (API and
  #     Web-Component clients present no Phoenix CSRF token).
  #   * every other method — the cookie is admitted ONLY when the request
  #     carries `x-requested-with`, the identical check
  #     `RequireBearerOrSessionToken` applies to its own cookie branch: a
  #     cross-site form/img cannot set that header, and a cross-origin fetch
  #     that sets it trips a CORS preflight the allowlist blocks. Without the
  #     header the conn falls back to bearer-only resolution, so a forged
  #     cross-site write sees exactly the anonymous request it saw before this
  #     change.
  #
  # Bearer callers are untouched on every method (OptionalSessionToken prefers
  # the Authorization header), and an anonymous conn still passes through
  # unauthenticated to be denied by ResolveWorkspace — the fail-closed default
  # is byte-identical.
  #
  # FREE BONUS: the [:scoped_api, :media_mutate] block (collections
  # share/members, checkout) ran ResolveWorkspace BEFORE :media_mutate's
  # `fetch_session`, so it 403'd a session-only browser member before its own
  # cookie-aware gate could speak. Those routes are POST/DELETE and the Studio
  # sends `x-requested-with`, so the header arm below now resolves the member's
  # session token in time for the membership gate — and :media_mutate's
  # RequireBearerOrSessionToken still runs afterwards as the hard gate.
  #
  # Sobelow Config.CSRF: the session is fetched on this pipeline, but every
  # cookie-authorized request that can change state is header-checked above and
  # then re-gated by the route's own write pipeline. Same posture as
  # :shared_media_api / :media_mutate, both baselined.
  #
  # TWO DIVERGENCES from the OptionalToken arm, both checked rather than
  # assumed. (1) `OptionalSessionToken` also honours `:dev_browser_token`, so on
  # the cookie arm a dev machine's scoped GETs authenticate as the seeded dev
  # token — config/dev.exs ONLY (grep: it is set nowhere in test.exs, runtime.exs
  # or prod.exs), and it is the same convenience :scoped_media_mutate already
  # grants. (2) `OptionalToken` refuses a scope-bound SHARE token presented off
  # its surface and `OptionalSessionToken` has no such arm — a no-op here, not a
  # hole: `RequireToken.share_token_off_surface?/2` is true only when
  # `conn.path_params["workspace_slug"]` is absent, and EVERY :scoped_api route
  # is mounted under /w/:workspace_slug, so the predicate is false on this
  # pipeline by construction.
  defp scoped_api_optional_credential(%Plug.Conn{} = conn, _opts) do
    if cookie_credential_admissible?(conn) do
      conn
      |> Plug.Conn.fetch_session()
      |> BarkparkWeb.Plugs.OptionalSessionToken.call([])
    else
      BarkparkWeb.Plugs.OptionalToken.call(
        conn,
        BarkparkWeb.Plugs.OptionalToken.init([])
      )
    end
  end

  defp cookie_credential_admissible?(%Plug.Conn{method: method} = conn) do
    method in ["GET", "HEAD"] or csrf_header?(conn)
  end

  defp csrf_header?(conn) do
    case Plug.Conn.get_req_header(conn, "x-requested-with") do
      [val | _] when is_binary(val) and val != "" -> true
      _ -> false
    end
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
    # Parity with :api — this pipeline serves anonymous shared-scope reads, the
    # surface where nosniff/referrer-policy matter most.
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :docs)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.ResolveProject)
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
    # Deny-by-default clamp for a `public-read`-only token (site-spawner D6) on
    # the SCOPED read the site-spawner BUILD token fetches over. Mounted at the
    # TAIL: OptionalToken assigned :api_token and ResolveWorkspace/ResolveProject
    # set the scope, so the schema-visibility check is workspace-accurate.
    # Membership (ResolveWorkspace) is necessary but not sufficient — it does not
    # pin published-vs-draft; this plug is the missing clamp. No-op otherwise.
    plug(BarkparkWeb.Plugs.PublicRead)
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
  # Sobelow Config.CSRF (justified, stays baselined — task-f76e9b7b): the session
  # is fetched ONLY so OptionalSessionToken can resolve a member's token from the
  # cookie for READ authorization (bare <img> tags cannot send a Bearer header).
  # RequireShareScope is method-aware — a :media share grants GET/HEAD only — so
  # no cookie-authorized state change is reachable here. Reads are not a CSRF
  # target; protect_from_forgery would break same-origin <img> media loads.
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
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
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
    # Stamp scope BEFORE the auth gates so a 403'd cross-tenant WRITE is still
    # tenant-attributable in the logs (the blast-radius question includes denied
    # attempts).
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
    plug(BarkparkWeb.Plugs.RequireToken)
    # Per-workspace quota gate (perfect-plan-build W1, D11) — AFTER
    # ResolveWorkspace (current_workspace is set) and BEFORE the write gate. Doc
    # writes are metered by the [:barkpark, :content, :mutate] span, so no
    # `meter: :media` here (that would double-count against the span).
    plug(BarkparkWeb.Plugs.RequireWithinQuota)
    plug(BarkparkWeb.Plugs.RequireWritePermission)
    plug(BarkparkWeb.Plugs.Idempotency)
  end

  # Media writes (upload/update/delete) — mirrors [:scoped_api, :media_mutate]
  # (keeps the session-cookie branch + AssignDefaultScope for the browser
  # Studio) with the edit-token grant spliced in before ResolveWorkspace.
  # Sobelow Config.CSRF (justified, stays baselined — task-f76e9b7b): this IS a
  # write pipeline, but the cookie/session branch is CSRF-defended by
  # RequireBearerOrSessionToken (below), which requires an `x-requested-with`
  # header a cross-site form/img cannot set and a cross-origin fetch cannot add
  # without a CORS preflight the allowlist blocks. Bearer callers return before
  # that check (token-auth, not a CSRF target). protect_from_forgery is the wrong
  # tool: API/Web-Component clients present no Phoenix CSRF token.
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
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
    # Per-workspace quota gate (perfect-plan-build W1, D11) — the media write
    # path bypasses Content (Media.upload/3 = raw Repo.insert), so this router
    # seam is the ONLY point that gates it. `meter: :media` emits the one
    # [:barkpark, :media, :mutate] telemetry event per allowed write (the media
    # path has no span of its own — charter D12).
    plug(BarkparkWeb.Plugs.RequireWithinQuota, meter: :media)
    # Write-gate: a read-only token/session member is denied 403 before the
    # controller. A P5 edit-share token short-circuits via :share_writer (set by
    # RequireShareEditToken above), so scoped uploads still work. Mirrors
    # :scoped_mutate's RequireWritePermission.
    plug(BarkparkWeb.Plugs.RequireWritePermission)
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
  # Tailored, script-blocking CSP (task-0fc9d55c) — shares root.html.heex with
  # :browser, so the same BrowserCsp nonce+hash policy applies. Static map =
  # Sobelow credit; BrowserCsp = real per-request header. See BarkparkWeb.CSP.
  pipeline :scoped_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "script-src 'self' https://cdn.jsdelivr.net; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    })

    plug(BarkparkWeb.Plugs.BrowserCsp)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    # Anonymous resolves the DEFAULT workspace only while the public-demo
    # flag is on (:studio_demo — dev/test true, PROD OFF unless
    # BARKPARK_PUBLIC_DEMO_STUDIO); flag-off anonymous → redirect to /login.
    # Every other anonymous scope still fails closed, token paths unchanged.
    plug(BarkparkWeb.Plugs.ResolveWorkspace, allow_anonymous_default: :studio_demo)
    plug(BarkparkWeb.Plugs.ResolveProject)
  end

  # Optional token resolution for browser routes that only REDIRECT (the
  # flat-Studio 302s, P3): composes after :browser, supplies the
  # session/dev token the scope-resolution rule keys off. No gating —
  # anonymous passes through and resolves to the Default workspace.
  pipeline :soft_token do
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
  end

  # Layer-2 script-blocking CSP for the PUBLIC paper reader (defense-in-depth
  # follow-up to the store-time body_html sanitizer). Layered ON TOP of a
  # browser pipeline for the paper reader scopes ONLY. The plug SELF-GATES to
  # `.../papers/:slug` paths, so on the SHARED `:public_root` bucket (scope "/"
  # below — papers AND /sheets AND /quiz) it emits the policy for papers alone
  # and is a pure no-op for the sibling readers. See PaperReaderCsp @moduledoc.
  pipeline :paper_reader_csp do
    plug(BarkparkWeb.Plugs.PaperReaderCsp)
  end

  # Reader conditional (http-edge-truth D9/D10/D11): weak time-bucketed ETag +
  # honored 304 for the FLAT paper reader spellings. Layered AFTER
  # :paper_reader_csp so the 304 branch can delete the freshly-nonced CSP that
  # plug just minted (a 304 delivering a new nonce would permanently break the
  # cached reader's inline scripts). Self-gates to `.../papers/:slug` paths, so
  # on the shared `:public_root` bucket it is a pure no-op for the sheets/quiz
  # sibling readers. See BarkparkWeb.Plugs.PaperRevisionHeaders @moduledoc.
  pipeline :paper_revision_headers do
    plug(BarkparkWeb.Plugs.PaperRevisionHeaders)
  end

  # Papers are shareable, not searchable, out of the box — see the plug's
  # @moduledoc. Rides BEFORE :paper_revision_headers so the 304 carries it.
  pipeline :reader_noindex do
    plug(BarkparkWeb.Plugs.ReaderNoindex)
  end

  # :scoped_browser + the :docs share gate (P4) — the scoped STUDIO pipeline.
  # An anonymous request for a `:docs`-shared scope is pre-resolved by
  # RequireShareScope (read-only; LiveScope attaches the server-side write
  # gate at mount); otherwise byte-identical to :scoped_browser — members via
  # membership, anonymous via the Default allowance, everything else closed.
  # Tailored, script-blocking CSP (task-0fc9d55c) — doc-shared Studio, shares
  # root.html.heex, so the same BrowserCsp nonce+hash policy applies. Static map
  # = Sobelow credit; BrowserCsp = real per-request header. See BarkparkWeb.CSP.
  pipeline :shared_studio_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "script-src 'self' https://cdn.jsdelivr.net; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    })

    plug(BarkparkWeb.Plugs.BrowserCsp)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :docs)
    plug(BarkparkWeb.Plugs.ResolveWorkspace, allow_anonymous_default: :studio_demo)
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
  #
  # Anonymous-Default allowance (bug-scoped-paper-route-500): the flat
  # /papers/:slug reader serves the seeded Default workspace's PUBLISHED papers
  # to anonymous callers (`get_public_paper/2` pins that tenant), so the scoped
  # spelling of the SAME content — /w/default/p/default/papers/:slug — 403ing
  # anonymously was a UX bug, not a boundary. `allow_anonymous_default: true`
  # (the same opt-in :shared_studio_browser carries, P3 of Scoped-by-URL) lets
  # an ANONYMOUS conn resolve the Default workspace ONLY; every non-Default
  # workspace still fails closed (membership or an explicit :papers share), and
  # token-present requests keep the membership gate unchanged. No draft
  # exposure: the reader resolves by slug (a `drafts.` row never matches) and
  # renders wikilinks/valuerefs as the anonymous principal over published rows
  # (D2/D5) on BOTH surfaces.
  # Sobelow Config.CSP (task-0fc9d55c): this pipeline ONLY serves the scoped
  # paper reader (/w/:ws/p/:project/papers/:slug), whose scope layers
  # [:shared_paper_browser, :paper_reader_csp]; PaperReaderCsp (#2389) REPLACES
  # the header per-response with the tailored reader policy + its own nonce. A
  # pipeline map here is a cosmetic double-set — so a static map on
  # put_secure_browser_headers (the Sobelow-credit form) is all that is needed,
  # matching the reader's already-strict script-src. CSRF + secure headers stay.
  pipeline :shared_paper_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BarkparkWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "script-src 'self' https://cdn.jsdelivr.net; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    })

    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.RequireShareScope, surface: :papers)
    plug(BarkparkWeb.Plugs.ResolveWorkspace, allow_anonymous_default: true)
    plug(BarkparkWeb.Plugs.ResolveProject)
    plug(BarkparkWeb.Plugs.ReaderNoindex)
    plug(BarkparkWeb.Plugs.PaperRevisionHeaders)
  end

  pipeline :api_unlimited do
    plug(:accepts, ["json"])
    # Parity with :api — baseline JSON security headers.
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
  end

  pipeline :api_preview do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    # Parity with :api — baseline JSON security headers on the flat preview reads.
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
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
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
  end

  pipeline :require_token do
    plug(BarkparkWeb.Plugs.RequireToken)
    # Deny-by-default clamp for a `public-read` token (site-spawner D6/D106).
    # RequireToken has just proven a token exists; PublicRead then allows ONLY
    # `GET /v1/data/query|doc` — which no route on this pipeline is — so the
    # public tier is denied the whole bearer-gated surface it was never meant to
    # reach (export/analytics/history/revision returned 200 and `listen` held an
    # open SSE stream before this line). No-op for read/write/admin/ops tokens by
    # the plug's own construction, so every other principal is byte-identical.
    plug(BarkparkWeb.Plugs.PublicRead)
  end

  # The low-trust TICKET-KEY tier (Barkpark Tickets, charter Decision 1 + 7).
  # Mirrors the :api pipeline's `accepts`, then gates on RequireTicketKey — the
  # ONLY plug that resolves a `kind == "ticket"` key. Deliberately thin: a ticket
  # key carries no tenancy/permission tier (OptionalToken/AssignDefaultScope are
  # irrelevant), and the submitter surface is server-derived from the resolved
  # key's own workspace binding.
  pipeline :ticket_key do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.RequireTicketKey)
    # Per-key abuse rails on the WRITE surface (charter Decision 9). Mounted
    # AFTER RequireTicketKey so the bucket key can read the resolved
    # `conn.assigns.ticket_key.id`; reads (the polling loop) pass through.
    plug(BarkparkWeb.Plugs.TicketRateLimit)
  end

  # Session-cookie soft-auth for the OPERATOR's ROOT-mounted GET plugin routes
  # (Barkpark Tickets, charter Decision 12). The `:api` pipeline shape — same
  # AcceptBarkparkVendor / accepts json / ApiSecurityHeaders /
  # ErrorEnvelopeNegotiation / RateLimit / AssignDefaultScope — but with
  # `:fetch_session` FIRST and `OptionalSessionToken` in place of
  # `OptionalToken`. ApiSecurityHeaders stays: the routes that ride this bucket
  # used to ride `:token_root` (which pipes through `:api`), so every response —
  # including the 401/404 error envelopes — keeps the same nosniff +
  # referrer-policy baseline it always had.
  #
  # WHY IT EXISTS: the Studio inbox timeline renders attachment-download links as
  # plain `<a href>` navigations. A browser Studio session carries only the
  # signed session cookie, never a Bearer header, so the Bearer-only `:token_root`
  # pipeline (`RequireToken`) 401'd every operator click. OptionalSessionToken
  # resolves the member's token from EITHER the Bearer header (wins when present —
  # API clients unchanged) OR `session["api_token"]`, so the logged-in operator's
  # cookie authenticates the download; an anonymous conn passes through untouched.
  #
  # NO HALTING PLUG by design: OptionalSessionToken never halts, and the
  # controller's own `require_operator/1` is the fail-closed gate — an anonymous
  # conn 401s there, exactly the same soft-auth + downstream-gate shape as
  # `:shared_media_api`. We deliberately do NOT use RequireBearerOrSessionToken:
  # its session branch demands the `x-requested-with` header (CSRF defense), which
  # a plain `href` / `target=_blank` navigation cannot send — that would re-break
  # the very click this pipeline fixes.
  #
  # GET-ONLY BUCKET. The cookie branch is navigation auth with no CSRF header, so
  # a WRITE must NEVER ride this pipeline — only idempotent, side-effect-free GETs.
  #
  # Sobelow Config.CSRF (justified, stays baselined — task-f76e9b7b): the GET-only
  # invariant IS the CSRF defense — a side-effect-free read is not a CSRF target,
  # and protect_from_forgery would break the plain-<a href> attachment-download
  # navigations this bucket exists to serve (they cannot carry a CSRF token).
  pipeline :session_token_root do
    plug(:fetch_session)
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.OptionalSessionToken)
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
  end

  # Base pipeline for the core user-auth API (/v1/auth/*). Like :api but without
  # the api-token/tenancy plugs (auth is pre-tenant) and WITH :fetch_session so
  # login can set the signed `user_session` cookie. RateLimit keys on IP here
  # (anonymous), which is the brute-force defense for login.
  #
  # Sobelow Config.CSRF (justified, stays baselined — task-f76e9b7b): this is a
  # JSON API (accepts ["json"] + AcceptBarkparkVendor), so a cross-site HTML form
  # cannot forge an application/json request against it. The session-gated
  # routes mounted downstream (:require_user / :access_principal) run
  # RequireUserSession / OptionalUserSession, which STILL enforce the
  # `x-requested-with` CSRF check on the cookie branch for mutating methods — so
  # login setting the cookie here introduces no CSRF-writable surface.
  pipeline :user_auth do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(:fetch_session)
  end

  # Second, TIGHTER meter for anonymous account creation, stacked ON TOP of
  # `:user_auth` (which already bills the shared 60/min anon-write bucket). Its
  # own per-IP per-hour bucket — default 5/h, BARKPARK_AUTH_RATE_REGISTER — so a
  # register flood neither starves the other anonymous writes from that IP nor
  # turns the API-shaped 60/min ceiling into a 3600-mail/hour amplifier against a
  # third party. Only `POST /v1/auth/register` rides this.
  pipeline :auth_register_throttle do
    plug(BarkparkWeb.Plugs.AuthWriteRateLimit, class: :register)
  end

  # Core user-login session gate (distinct from API-token auth): login bearer
  # or `user_session` cookie → :current_user, then the require_mfa org gate.
  pipeline :require_user do
    plug(BarkparkWeb.Plugs.RequireUserSession)
    plug(BarkparkWeb.Plugs.RequireOrgMfaEnrolment)
  end

  # ag-bp-user-identity-auth: SOFT user-principal gate for the grantee surface
  # (`/v1/access/claim`, `/v1/access/mine`). Unlike `:require_user` (a login
  # session ONLY), this resolves `:current_user` from EITHER a login session OR
  # an OWNED api_token, so a terminal `bp access claim`/`mine` (holding an owned
  # token) works alongside the browser/JS session path:
  #
  #   * `OptionalToken` — a Bearer api_token → `:api_token` (bearer-only; no
  #     cookie side effects), soft.
  #   * `OptionalUserSession` — a login session (Bearer session-token OR
  #     `user_session` cookie, with the cookie branch's CSRF check preserved) →
  #     `:current_user`, soft. This keeps the pre-existing session-bearer claim
  #     path byte-identical.
  #   * `ResolveTokenOwner` — an OWNED `:api_token` → its owner user, ONLY when a
  #     session did not already resolve one (login session wins). Non-halting.
  #   * `RequirePrincipalUser` — 401 if `:current_user` is STILL nil (anonymous,
  #     bad token, or an UN-OWNED token → fail closed).
  #   * `RequireOrgMfaEnrolment` — restores the org-MFA-enrolment overlay the OLD
  #     `:require_user` pipeline applied here. A SESSION-user grantee unenrolled
  #     in a `require_mfa` org is 403'd (`mfa_enrolment_required`) exactly as
  #     before — login is not enrolment-gated, this per-route overlay is. It
  #     reads `:current_user` (fails closed on nil) and exempts only `/v1/auth/*`
  #     compliance paths, so claim/mine stay fully gated. The TOKEN path is safe
  #     WITHOUT re-checking here: an owned token can only be MINTED via
  #     `POST /v1/auth/tokens` under `[:user_auth, :require_user]`, so org-MFA
  #     enrolment is enforced at ISSUANCE — an unenrolled user cannot obtain the
  #     token to begin with (see AuthController.create_token/2).
  #
  # Requires `:fetch_session` upstream (`:user_auth` provides it). NEVER mounted
  # on the grantor routes — those stay a pure api_token principal.
  pipeline :access_principal do
    plug(BarkparkWeb.Plugs.OptionalToken)
    plug(BarkparkWeb.Plugs.OptionalUserSession)
    plug(BarkparkWeb.Plugs.ResolveTokenOwner)
    plug(BarkparkWeb.Plugs.RequirePrincipalUser)
    plug(BarkparkWeb.Plugs.RequireOrgMfaEnrolment)
  end

  # Browser Studio uploads send `credentials: same-origin` with the session
  # cookie; API clients still use Bearer. Requires `:fetch_session` upstream.
  # Sobelow Config.CSRF (justified, stays baselined — task-f76e9b7b): identical
  # rationale to :scoped_media_mutate — the session branch is CSRF-defended by
  # RequireBearerOrSessionToken's `x-requested-with` check; bearer callers are
  # token-auth. protect_from_forgery cannot apply (no Phoenix CSRF token on API /
  # Web-Component uploads).
  pipeline :media_mutate do
    plug(:fetch_session)
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.RequireBearerOrSessionToken)
    # Close the flat :media_mutate quota hole (bpb-flat-media-quota-hole, D14/D30).
    # This pipeline has no ResolveWorkspace, so it would fall to AssignDefaultScope
    # and meter EVERY flat media write against the singleton Default Workspace.
    # Derive :current_workspace from the just-assigned api_token BEFORE
    # AssignDefaultScope so the write meters to its OWN workspace. AssignDefaultScope
    # does NOT simply no-op here: it skips the workspace assign (already set) but
    # still evaluates its PROJECT branch, and a token carries no project binding.
    # That branch is conditional on the resolved workspace BEING the Default one
    # for exactly this reason — see AssignDefaultScope's moduledoc. A
    # nil-workspace_id token falls through untouched and keeps today's
    # Default-Workspace behavior.
    plug(BarkparkWeb.Plugs.DeriveWorkspaceFromToken)
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
    # Per-workspace quota gate — mirrors :scoped_media_mutate. The media write
    # path bypasses Content (Media.upload/3 = raw Repo.insert), so this router
    # seam is the only point that gates it; `meter: :media` emits the one
    # [:barkpark, :media, :mutate] telemetry event per allowed write (charter D12).
    plug(BarkparkWeb.Plugs.RequireWithinQuota, meter: :media)
    # Write-gate: media upload/update/delete are mutations — a read-only token
    # (or read-only session member) must be denied 403 before the controller.
    # RequireBearerOrSessionToken always assigns :api_token on success, so the
    # permits?(:write) check has a principal. Mirrors the doc :mutate gate.
    plug(BarkparkWeb.Plugs.RequireWritePermission)
  end

  # Ingest endpoints: JSON in, shared-secret bearer auth (NOT the api_tokens
  # table). Used by the Bulldocs paper-ingest API and any plugin that ships an
  # `auth: :ingest` route via the plugin highway.
  pipeline :ingest do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.RequireIngestToken)
  end

  # Anonymous, CORS-open JSON for the `:public_api` plugin bucket (Pulse /
  # Shared Storm). NO auth plug by design — safety is the plugin's caps
  # (schema validation + rate limits), not identity. PublicCors is the ONLY
  # place the API surface emits CORS headers; the core `/v1/data/*` surface
  # stays browser-unreachable cross-origin on purpose.
  pipeline :public_api do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.PublicCors)
  end

  # Inbound GitHub webhook (github-bridge Wave 3). A server-to-server GitHub App
  # callback — NOT a browser origin, so NO token, NO session, NO CORS. The ONLY
  # auth is the HMAC signature: GithubWebhookSignature verifies X-Hub-Signature-256
  # over the RAW request body (teed into conn.assigns[:raw_body] at the endpoint by
  # CacheBodyReader) and fails closed on anything it cannot positively verify. The
  # body is already parsed at the endpoint, so this pipeline only asserts JSON +
  # verifies the signature.
  pipeline :github_webhook do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.GithubWebhookSignature)
  end

  pipeline :require_admin do
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.RequireAdmin)
  end

  # THE admin gate for every FLAT (`/v1/...`, no `/w/:ws/p/:project` in the
  # path) admin route that must attribute per-workspace. It is the flat twin of
  # `:scoped_admin`, and it REPLACES `:api` — never layers on it.
  #
  # ORDER IS THE ENTIRE FIX (charter D45/D49; task-2b396416a680ff0b). A naive
  # `[:api, :require_admin]` cannot attribute per-workspace: `:api` runs
  # `AssignDefaultScope`, which stamps `current_workspace = <seeded Default>`
  # BEFORE the admin gate, and `ScopeHelpers.scope_opts/1` reads exactly that
  # assign — so every caller, from every workspace, converges on Default.
  # `DeriveWorkspaceFromToken` is NO-OP-IF-SET, so appending it after `:api` is
  # a pure no-op: Default has already won. Only this ordering works —
  # token-resolve → DeriveWorkspaceFromToken → AssignDefaultScope → admin
  # (the same shape as `:media_mutate`). `BarkparkWeb.FlatAdminTenancyTest`
  # reads this block and goes RED if the two are ever swapped.
  #
  # It re-includes every `:api` security plug (AcceptBarkparkVendor, accepts
  # json, ApiSecurityHeaders, ErrorEnvelopeNegotiation, RateLimit,
  # TenantLogMetadata) so the surface is byte-identical to `[:api,
  # :require_admin]` apart from the derivation order. The only set delta is
  # `OptionalToken` → `DeriveWorkspaceFromToken`: `RequireToken` (which
  # `:require_admin` ran anyway, one plug later) is a strict superset of
  # `OptionalToken` — same `Auth.verify_token`, same
  # `share_token_off_surface?/2` refusal — so the old pair resolved the token
  # twice and an admin route can never serve an anonymous caller regardless.
  #
  # `DeriveWorkspaceFromToken` is controller-agnostic (it reads only
  # `:api_token` + `:current_workspace`), which is why ONE pipeline attributes
  # search settings, schemas, structure and webhooks alike — do NOT clone it
  # per controller. Adding a flat admin surface? Mount it HERE.
  pipeline :flat_admin_api do
    plug(BarkparkWeb.Plugs.AcceptBarkparkVendor)
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.DeriveWorkspaceFromToken)
    plug(BarkparkWeb.Plugs.AssignDefaultScope)
    plug(BarkparkWeb.Plugs.TenantLogMetadata)
    plug(BarkparkWeb.Plugs.RequireAdmin)
  end

  # Chat tenancy gate (Connectors charter D18/D19a). RequireToken sets
  # `:api_token`; RequireChatAccess resolves `:chat_scope` (`:global` for a
  # global-admin token — D21 authority preserved — or `{:workspace, ws}` for a
  # workspace-bound `chat` token) and 403s a token that is neither. The
  # controller confines a workspace scope to sessions its tenant owns.
  pipeline :require_chat_access do
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.RequireChatAccess)
  end

  pipeline :require_chat_host_admin do
    plug(BarkparkWeb.Plugs.RequireToken)
    plug(BarkparkWeb.Plugs.ResolveWorkspace)
    plug(BarkparkWeb.Plugs.RequireWorkspaceRole)
  end

  pipeline :registered_chat_host do
    plug(:accepts, ["json"])
    plug(BarkparkWeb.Plugs.ApiSecurityHeaders)
    plug(BarkparkWeb.Plugs.RateLimit)
    plug(BarkparkWeb.Plugs.RequireChatHost)
  end

  # Scoped admin gate (barkpark-23yi / barkpark-fsko P0 fix). For the
  # /w/:ws/p/:project admin routes: require a token AND a membership ROLE of
  # owner/admin in the resolved `current_workspace`. RequireToken sets
  # :api_token; ResolveWorkspace (in :scoped_api) sets :current_workspace and
  # already gates :read membership; RequireWorkspaceRole reads the per-grant
  # role — so a `member` of B with global admin perms is 403'd on admin ops.
  #
  # THE FLAT ADMIN ROUTES DO NOT USE THIS PIPELINE, AND NO LONGER USE BARE
  # `:require_admin` EITHER. They ride `:flat_admin_api` (defined ~40 lines
  # above), which derives the workspace from the TOKEN before AssignDefaultScope
  # can stamp Default. `:scoped_admin` is for the PATH-scoped
  # /w/:ws/p/:project admin routes, where a resolver has already put the real
  # workspace in `:current_workspace`. Adding a FLAT admin surface? Mount it on
  # `:flat_admin_api`, not here and not on `[:api, :require_admin]`.
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

  # scaffy:zone router-pipelines (ensure-router-zones) -- stable head anchor
  # for NEW pipeline definitions: add your `pipeline :name do ... end` block
  # DIRECTLY BELOW this comment. Pipeline definitions are POSITION-FREE --
  # each compiles to a named private plug referenced by name from
  # `pipe_through`, so a block landing here can never change route matching
  # (proof in-tree: :media_processing_callback is defined mid-scopes far
  # below and works). Ordering INSIDE a pipeline (plug order) is that
  # pipeline's own documented contract -- read its comments. Sweeps: move
  # this comment only whole, on its own lines. MARK:zone-router-pipelines

  # Bare /studio and / redirect to the session-resolved SCOPED Studio
  # (P3 cutover — see PageController.redirect_to_studio for the
  # resolution rule). The :soft_token pipeline supplies the optional
  # session/dev token the resolution keys off.
  scope "/", BarkparkWeb do
    pipe_through([:browser, :soft_token])
    get("/", PageController, :redirect_to_studio)
    get("/studio", PageController, :redirect_to_studio)

    # Airdrop-grant claim (account-bound): the grantee opens the out-of-band
    # link, and — once signed in (soft_token → :current_user) — the grant binds
    # to their account and lands them in the scoped Studio. Anonymous → /login
    # (return_to resumes the claim); every other failure is one no-oracle
    # response. See BarkparkWeb.GrantController.
    get("/grant/:token", GrantController, :claim)
  end

  # ── Session login (paste API token) ─────────────────────────────────
  scope "/", BarkparkWeb do
    pipe_through(:browser)

    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    # Account sign-in (studio-user-login): email+password against the core
    # auth system, with the TOTP/recovery second step. Mints `user_session`.
    post("/login/account", SessionController, :account)
    post("/login/mfa", SessionController, :mfa)
    post("/logout", SessionController, :delete)

    # Browser password-reset (login-brand-ux): "Forgot password?" page + the
    # landing page for the emailed /auth/reset/<token> link (which the JSON
    # request-reset flow was already sending — it 404'd in a browser before
    # these routes). Anti-enumeration mirrors POST /v1/auth/request-reset.
    get("/login/reset", SessionController, :reset_request_form)
    post("/login/reset", SessionController, :reset_request)
    get("/auth/reset/:token", SessionController, :reset_form)
    post("/auth/reset/:token", SessionController, :reset_submit)

    # Magic-link (passwordless) browser sign-in: request page + the landing for
    # the emailed /auth/magic/<token> link (which 404'd in a browser before —
    # only the JSON POST /magic-login existed). Consume routes through the same
    # second-factor step as password login (no 2FA bypass).
    get("/login/magic", SessionController, :magic_request_form)
    post("/login/magic", SessionController, :magic_request)
    get("/auth/magic/:token", SessionController, :magic)

    # dwb-7 one-click Studio entry: consume a single-use login ticket, set the
    # session api_token (no paste), redirect to /studio. Minted by
    # POST /v1/auth/login-tickets (LoginTicketController). See SessionController.ticket/2.
    get("/login/ticket/:ticket", SessionController, :ticket)
  end

  # ── dwb-7: login-ticket mint (api_token bearer) ─────────────────────────
  # POST /v1/auth/login-tickets — the caller proves possession of an api_token
  # (typically the control plane's stored per-instance admin token) and gets a
  # single-use, 60s ticket bound to it. The browser then opens
  # /login/ticket/:ticket (above) for one-click Studio entry.
  scope "/v1/auth", BarkparkWeb do
    pipe_through([:api, :require_token])

    post("/login-tickets", LoginTicketController, :create)

    # ── Mobile app-token exchange, instance half (mobile charter D4) ──────
    # POST /v1/auth/app-tokens — admin-bearer-gated in the controller (the
    # mint_login_ticket idiom): the Cloud control plane proves possession of
    # the stored per-instance admin token server-side and gets back a
    # member-shaped, workspace-bound [read,write,chat] token for the calling
    # cloud user (JIT-provisioned member, charter D5). The admin credential
    # never reaches the member; the plaintext minted token is the payload.
    post("/app-tokens", AppTokenController, :create)

    # ── App-token revoke, instance half (wave 2, mob-w2-app-token-revoke) ──
    # DELETE /app-tokens — admin-bearer-gated body revoke ({"token": raw}, or
    # {"email": e} → every live "app:<e>"-labelled token). DELETE …/current —
    # the bearer revokes ITSELF (possession is the authorization; admin
    # bearers refused so the stored custody credential can't self-destruct).
    # Both only SET revoked_at: Auth.verify_token/1 already filters revoked
    # rows in its WHERE clause, so a revoked token fails closed on its next
    # use with zero read-path changes.
    delete("/app-tokens/current", AppTokenController, :delete_current)

    # jf-backlog-apptoken-revoke-upstream — enumerate + revoke BY ID. The mint's
    # optional `label` REPLACES the `app:<email>` default, so
    # `revoke_app_tokens_for_email/1`'s exact-label match could not reach a
    # custom-labelled token: with no list and no by-id route it was unrevocable
    # unless the operator still held the raw string.
    #
    # ORDER IS LOAD-BEARING: `/app-tokens/current` MUST stay above
    # `/app-tokens/:id` or the literal segment is swallowed by the param and
    # self-revoke starts trying to revoke a row with id "current".
    get("/app-tokens", AppTokenController, :index)
    delete("/app-tokens/:id", AppTokenController, :delete_by_id)
    delete("/app-tokens", AppTokenController, :delete)
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
      on_mount: [
        {BarkparkWeb.LiveAuth, :admin},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.StudioChrome, :default}
      ],
      layout: {BarkparkWeb.Layouts, :studio} do
      # `/studio/settings` moved to the workspace-scoped canonical
      # `/w/:ws/p/:proj/studio/settings` (sdl-w1-admin-canonical, charter D4):
      # SettingsLive edits ONE workspace, so the flat route silently pinned the
      # seeded Default workspace. The flat spelling now 302s — see the
      # `AdminStudioRedirectController` scope below. org-admin stays flat
      # (org-level, genuinely scope-free).
      live("/org-admin", OrgAdminLive)
      # Living token style guide (unified-aesthetic W1.4) — admin-gated; renders
      # the emitted design tokens (var(--…) from root.html.heex GENERATED block).
      live("/styleguide", StyleguideLive)
      # Dev-only tmux console — admin-gated here; TmuxLive.mount also hard-gates
      # on TmuxConsole.enabled? (dev-only PTY dep + config flag). Hidden in
      # prod/test where the flag is off and the backend isn't compiled.
      live("/tmux", TmuxLive)
      # Provider-neutral agent chat — admin-gated here; ChatLive.mount also
      # requires at least one enabled Claude Code or Codex runtime (refused on
      # public-demo hosts). Both routes share this live_session + module, so a
      # session switch is a `push_patch` with NO remount (charter D14):
      # `/chat` is the new-chat empty state; `/chat/:session_id` replays a
      # remembered session's history. `handle_params/3` is the single source of
      # truth.
      live("/chat", ChatLive)
      live("/chat/:session_id", ChatLive)
    end

    # Styleguide theme-showroom swatch cell (ts-w5d) — admin-gated, rendered
    # through the BARE `:swatch` layout (no Studio chrome) because StyleguideLive
    # loads it in an IFRAME, one per known theme × [light, dark]. Its own
    # live_session so the layout override is scoped to this route; the
    # studio-chrome / status / reader skins are html[data-bp-theme]-anchored, so
    # the cell must own its <html> (SwatchLive stamps data-bp-theme + data-theme).
    live_session :admin_swatch,
      on_mount: [
        {BarkparkWeb.LiveAuth, :admin},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.StudioChrome, :default}
      ],
      layout: {BarkparkWeb.Layouts, :swatch} do
      live("/styleguide/swatch", SwatchLive)
    end
  end

  # ── Scoped-in-substance admin flat → scoped 302 (sdl-w1-admin-canonical) ─
  # `/studio/settings` is scoped-in-substance (SettingsLive edits ONE
  # workspace) so its canonical home is `/w/:ws/p/:proj/studio/settings`.
  # This flat spelling 302s there via the session-resolved workspace/project.
  # Declared BEFORE the `/studio/:dataset` catch-all far below so
  # `/studio/settings` never parses as dataset="settings". :soft_token
  # supplies the optional session token the resolution keys off.
  scope "/studio", BarkparkWeb do
    pipe_through([:browser, :soft_token])

    get("/settings", AdminStudioRedirectController, :settings)

    # Same substance argument (connectors D49): a connector install belongs to
    # ONE workspace, so the canonical home is
    # `/w/:ws/p/:proj/studio/connectors` and the flat spelling only 302s there.
    get("/connectors", AdminStudioRedirectController, :connectors)
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
      on_mount: [
        {BarkparkWeb.LiveAuth, :admin},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.StudioChrome, :default}
      ],
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
      on_mount: [
        {BarkparkWeb.LiveAuth, :fetch_api_token},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.StudioChrome, :default}
      ],
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
      on_mount: [
        {BarkparkWeb.LiveAuth, :ops},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.StudioChrome, :default}
      ],
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

  # ── Plugin-contributed routes — anonymous public JSON (`auth: :public_api`) ─
  # The CORS-open, no-auth sibling of the buckets above (Pulse / Shared Storm).
  # `:public_api` pipeline = JSON + security headers + PublicCors (handles the
  # OPTIONS preflight); NO token plug — the mounted plugin owns its own abuse
  # caps (per-IP buckets, per-channel ceilings, strict payload validation).
  # No `BarkparkWeb` scope alias — plugin route specs fully-qualify their
  # controllers (same rationale as `:token_root`/`:ingest`). Dormant until a
  # plugin contributes an `auth: :public_api` route.
  scope "/v1/plugins" do
    pipe_through(:public_api)

    plugin_routes(scope: :public_api)
  end

  # ── Plugin-contributed routes — GitHub webhook (`auth: :github_webhook`) ──
  # The signature-gated, server-to-server sibling of `:public_api` (github-bridge
  # Wave 3). Same `/v1/plugins/<slug>/…` mount, but on the `:github_webhook`
  # pipeline (JSON + GithubWebhookSignature) instead of PublicCors — the inbound
  # GitHub App callback authenticates by HMAC over the raw body, never a token or
  # a browser origin. No `BarkparkWeb` scope alias: plugin route specs
  # fully-qualify their controllers (same rationale as `:ingest`/`:public_api`).
  # Dormant until the `github` plugin's `register_routes/1` contributes the
  # `POST /github/webhook` route (Wave 3 Slice 3) — expands to nothing today.
  scope "/v1/plugins" do
    pipe_through(:github_webhook)

    plugin_routes(scope: :github_webhook)
  end

  # scaffy:zone plugin-buckets (ensure-router-zones) -- stable head anchor
  # for NEW plugin auth-bucket wrappers (`scope ... plugin_routes(scope:
  # :x)`; the matching `pipeline` goes in the router-pipelines zone above):
  # add the wrapper DIRECTLY BELOW this comment. Ordering contract this
  # position guards: /v1/plugins-mounted wrappers are order-free among
  # themselves (plugin paths are slug-disjoint), and a ROOT-mounted
  # (`scope "/v1"`) wrapper landing here sits BEFORE the :token_root /
  # :session_token_root / :ticket_key run below, so :ticket_key's submitter
  # dynamic `/tickets/:id` stays the LAST root-mounted match and operator
  # statics keep winning (the static-before-dynamic pin in those blocks'
  # comments). NEVER declare a bucket after :ticket_key. Per-route plugin
  # adds do NOT belong here -- they auto-fold via register_routes/1. Sweeps:
  # move this comment only whole, on its own lines. MARK:zone-plugin-buckets

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

  # ── Plugin-contributed routes — session-cookie GET tier (`auth: :session_token_root`) ─
  # Cookie-aware sibling of the `:token_root` bucket above (Barkpark Tickets,
  # charter Decision 12). Same host `/v1` top-level mount, but on the
  # `:session_token_root` pipeline (OptionalSessionToken, no `RequireToken`
  # halt) so a browser Studio operator whose only credential is the session
  # cookie can follow a plain attachment-download `<a href>` — the Bearer-only
  # `:token_root` route 401'd that click. GET-only by contract (see the pipeline
  # comment): the cookie branch is navigation auth with no CSRF header, so a
  # WRITE must never ride this bucket. Anonymous conns pass through and the
  # controller's own `require_operator/1` 401s them (fail-closed downstream
  # gate, the `:shared_media_api` precedent).
  #
  # Mounted BEFORE the `:ticket_key` block below so the operator static
  # `/tickets/inbox/*` routes match ahead of the submitter dynamic
  # `/tickets/:id` — the same static-before-dynamic pin the charter fixes for
  # `:token_root`. No `BarkparkWeb` scope alias — plugin route specs
  # fully-qualify their controllers (same rationale as `:token_root`).
  scope "/v1" do
    pipe_through(:session_token_root)

    plugin_routes(scope: :session_token_root)
  end

  # ── Plugin-contributed routes — ticket-key tier (`auth: :ticket_key`) ─────
  # The low-trust TICKET-KEY submitter surface (Barkpark Tickets, charter
  # Decision 7). Root-mounted at host `/v1` on the `:ticket_key` pipeline
  # (RequireTicketKey), so a spec `{:post, "/tickets", …, auth: :ticket_key}`
  # lands at `/v1/tickets`. Mounted AFTER the `:token_root` block above so the
  # operator statics (`/tickets/inbox`, declared `:token_root` by the tickets
  # plugin) match BEFORE the submitter dynamic `/tickets/:id` here — the
  # static-before-dynamic disambiguation the charter pins.
  # No `BarkparkWeb` scope alias — plugin route specs fully-qualify their
  # controllers (same rationale as `:token_root`/`:ingest`). Dormant until the
  # tickets plugin (a sibling slice) contributes a `:ticket_key` route — the
  # `:token_root` bucket was likewise dormant when first added.
  scope "/v1" do
    pipe_through(:ticket_key)

    plugin_routes(scope: :ticket_key)
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
    pipe_through([:browser, :paper_reader_csp, :reader_noindex, :paper_revision_headers])

    plugin_routes(scope: :public_root)
  end

  # ── Public finder (LiveView) — the flagship search, Phoenix-native ──────
  # search-template W3: the same premium experience the Next/Astro starters
  # ship, as pure LiveView — per-keystroke search round-trips into the same
  # engine the search channel serves, the corpus graph inlines server-derived
  # topology into the shared Canvas2D renderer. Same public pipeline + reader
  # layout as the flat /papers reader it links into.
  scope "/", BarkparkWeb do
    pipe_through([:browser, :paper_reader_csp])

    live_session :finder, root_layout: {BarkparkWeb.Layouts, :bulldocs} do
      live("/finder", FinderLive, :index)
    end
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
        {BarkparkWeb.LiveAuth, :scoped_admin},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.PluginScopeSession, :scope},
        {BarkparkWeb.StudioChrome, :default}
      ],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :admin)
    end
  end

  # ── Scoped Workspace Settings — admin-gated, dataset-less (sdl-w1-admin-canonical) ─
  # SettingsLive edits ONE workspace, so the canonical address carries the
  # workspace/project (same dataset-less grammar as the scoped plugin admin
  # scope above). LiveScope resolves + authorizes the workspace from the URL
  # (membership-gated) so the panel binds to the URL workspace — never the
  # seeded Default that StudioChrome's flat fallback pins. Declared BEFORE the
  # `/w/:ws/p/:proj/studio/:dataset` back-compat wildcard below, or that
  # `:dataset` segment would swallow `/settings` (dataset="settings").
  scope "/w/:workspace_slug/p/:project_slug/studio", BarkparkWeb.Studio do
    pipe_through(:browser)

    live_session :scoped_admin_studio,
      on_mount: [
        {BarkparkWeb.LiveAuth, :scoped_admin},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.LiveScope, :resolve},
        {BarkparkWeb.StudioChrome, :default}
      ],
      layout: {BarkparkWeb.Layouts, :studio} do
      live("/settings", SettingsLive)
      live("/chat-hosts", ChatHostsLive)
      live("/chat", ChatLive)
      live("/chat/:session_id", ChatLive)

      # Connectors catalog + the connect loop (connectors D49). It MUST be in
      # THIS session, not the flat `/studio/*` one: the flat live_session carries
      # no `LiveScope` hook, so it has no `current_workspace` — and every install
      # would then pin to the seeded Default workspace (the exact bug that moved
      # `/studio/settings` to the scoped spelling). LiveScope's membership gate
      # binds the panel to the URL workspace; the LV re-gates each write on
      # `workspace_admin?/2` (the mount gate is a GLOBAL-permission gate, which is
      # strictly weaker than the per-workspace mint gate it delegates to).
      live("/connectors", ConnectorsLive)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/studio" do
    pipe_through(:scoped_browser)

    live_session :scoped_plugin_public,
      on_mount: [
        {BarkparkWeb.LiveAuth, :fetch_api_token},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.PluginScopeSession, :scope},
        {BarkparkWeb.StudioChrome, :default}
      ],
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
        {BarkparkWeb.LiveAuth, :require_org_mfa},
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

  # ── Scoped mirror of the token-gated plugin bucket (`auth: :token`) ────────
  # github-bridge Wave 8 / D15. The tenancy-aware sibling of the flat
  # `scope "/v1/plugins" … plugin_routes(scope: :token)` mount above: the SAME
  # token-gated plugin controller routes (github.adopt / github.status), but
  # under the `/w/:ws/p/:proj` path-based tenant prefix so a scoped `bp github
  # adopt` / `bp github status` participates in the hard tenant boundary.
  #
  # Pipeline `[:scoped_api, :require_token]` mirrors the flat `[:api,
  # :require_token]`, swapping `:api` (AssignDefaultScope) for `:scoped_api`
  # (OptionalToken → ResolveWorkspace → ResolveProject). ResolveWorkspace's
  # membership gate enforces tenant isolation — a caller who is not a member of
  # the URL workspace is 403'd BEFORE any controller runs — so no raw
  # workspace/project param can bypass membership. `:require_token` (NOT
  # `:scoped_admin`) keeps the OPERATOR tier: a valid bearer, never the admin
  # role — identical trust to the flat `:token` bucket. The controllers then
  # read the resolved `current_workspace`/`current_project` assigns via
  # `ScopeHelpers.scope_opts/1`. Same no-alias rationale as the flat bucket —
  # plugin route specs fully-qualify their controllers.
  scope "/w/:workspace_slug/p/:project_slug/v1/plugins" do
    pipe_through([:scoped_api, :require_token])

    plugin_routes(scope: :token)
  end

  # ── Scoped plugins-admin LV — dataset-scoped, admin-gated (sdl-w1-admin-canonical) ─
  # PluginsLive / PluginSettingsLive move under the canonical `/w/:ws/p/:proj/
  # d/:dataset/studio/_plugins[...]` grammar. Auth stays the flat semantics
  # (global `:admin` permission via LiveAuth) — the surface is the global
  # plugin registry scoped by dataset, not a per-workspace substance — but the
  # URL now carries the scope so `scope_prefix` (assigned by StudioChrome from
  # the params) makes the admin chrome links workspace-truthful. The leading
  # underscore keeps the namespace clear of schema-named paths.
  #
  # ORDERING: MUST be declared BEFORE the `:scoped_studio` `/*path` catch-all
  # below, or StudioLive's wildcard swallows `/_plugins`.
  scope "/w/:workspace_slug/p/:project_slug/d/:dataset/studio", BarkparkWeb.Admin do
    pipe_through(:browser)

    live_session :scoped_admin_studio_dataset,
      on_mount: [
        {BarkparkWeb.LiveAuth, :admin},
        {BarkparkWeb.LiveAuth, :require_org_mfa},
        {BarkparkWeb.StudioChrome, :default}
      ],
      layout: {BarkparkWeb.Layouts, :studio} do
      live("/_plugins", PluginsLive)
      live("/_plugins/:plugin/settings", PluginSettingsLive)
    end
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
        {BarkparkWeb.LiveAuth, :require_org_mfa},
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

  # ── Flat plugins-admin → scoped 302 (sdl-w1-admin-canonical) ──────────
  # The live `/studio/:dataset/_plugins[...]` mount moved to the canonical
  # `/w/:ws/p/:proj/d/:dataset/studio/_plugins[...]` scope above; the flat
  # spelling now 302s there (session-resolved workspace/project, dataset +
  # `/:plugin/settings` tail preserved). MUST come before the `/studio/:dataset`
  # catch-all below, which would otherwise 302 `_plugins` to StudioLive.
  scope "/studio/:dataset", BarkparkWeb do
    pipe_through([:browser, :soft_token])

    get("/_plugins", AdminStudioRedirectController, :plugins)
    get("/_plugins/:plugin/settings", AdminStudioRedirectController, :plugins)
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

    # The published OpenAPI 3.1 descriptor of the /v1 surface. Public, no token
    # (SDK generators / procurement fetch it before any caller has a token) and
    # not rate-limit-charged — same posture as /v1/meta and Coolify's
    # checked-in openapi.yaml. Generated from the capabilities manifest by
    # Barkpark.Api.OpenApi, so it can never drift from the routes.
    get("/openapi.json", OpenApiController, :index)
  end

  # ── Anonymous account creation — its OWN, tighter bucket ────────────────
  # POST /v1/auth/register is an UNAUTHENTICATED write that mails a third party
  # (a fresh address gets a confirmation mail; an existing one re-mails the
  # account holder). It rides `:user_auth` exactly as the other public auth
  # routes do — so it keeps the shared 60/min anon-write meter — and then bills a
  # SECOND, per-IP, per-hour bucket of its own (default 5/h,
  # BARKPARK_AUTH_RATE_REGISTER). Two independent buckets mean a register flood
  # can neither starve the other anonymous writes from that IP nor use the
  # API-shaped 60/min ceiling as a 3600-mail/hour amplifier. Throttle only —
  # invite codes / allowlists / closing signup are the owner's policy call.
  # See BarkparkWeb.Plugs.AuthWriteRateLimit.
  scope "/v1/auth", BarkparkWeb do
    pipe_through([:user_auth, :auth_register_throttle])

    post("/register", AuthController, :register)
  end

  # ── Core user auth (login/sessions/MFA/email flows) — public entry ───────
  scope "/v1/auth", BarkparkWeb do
    pipe_through(:user_auth)

    post("/login", AuthController, :login)
    post("/verify-email", AuthController, :verify_email)
    post("/request-reset", AuthController, :request_reset)
    post("/reset", AuthController, :reset)
    post("/request-magic-link", AuthController, :request_magic_link)
    post("/magic-login", AuthController, :magic_login)
    # Pre-login SSO routing: email → its org's SSO start URL (verified domains).
    post("/sso/route", SsoRoutingController, :route)

    # Passkey (WebAuthn) sign-in — usernameless login factor.
    post("/webauthn/login/challenge", WebauthnController, :login_challenge)
    post("/webauthn/login", WebauthnController, :login)
  end

  # ── SCIM 2.0 directory sync (per-organization bearer) ───────────────────
  scope "/scim/v2", BarkparkWeb do
    pipe_through(:scim)

    # Discovery (RFC 7644 §4) — an IdP probes these before it provisions.
    get("/ServiceProviderConfig", ScimDiscoveryController, :service_provider_config)
    get("/ResourceTypes", ScimDiscoveryController, :resource_types)
    get("/Schemas", ScimDiscoveryController, :schemas)

    post("/Users", ScimUsersController, :create)
    get("/Users", ScimUsersController, :index)
    get("/Users/:id", ScimUsersController, :show)
    patch("/Users/:id", ScimUsersController, :update)
    put("/Users/:id", ScimUsersController, :replace)
    delete("/Users/:id", ScimUsersController, :delete)

    post("/Groups", ScimGroupsController, :create)
    get("/Groups", ScimGroupsController, :index)
    get("/Groups/:id", ScimGroupsController, :show)
    put("/Groups/:id", ScimGroupsController, :replace)
    patch("/Groups/:id", ScimGroupsController, :update)
    delete("/Groups/:id", ScimGroupsController, :delete)
  end

  # ── Enterprise SSO — OIDC relying party (per-organization) ──────────────
  scope "/v1/auth/oidc", BarkparkWeb do
    pipe_through(:sso_browser)

    get("/:org_slug/start", OidcController, :start)
    get("/:org_slug/callback", OidcController, :callback)
  end

  # ── Social login — Google / GitHub / Microsoft (app-level) ──────────────
  scope "/v1/auth/social", BarkparkWeb do
    pipe_through(:sso_browser)

    get("/:provider/start", SocialController, :start)
    get("/:provider/callback", SocialController, :callback)
  end

  # ── Enterprise SSO — SAML 2.0 Service Provider (per-organization) ────────
  scope "/v1/auth/saml", BarkparkWeb do
    pipe_through(:sso_browser)

    get("/:org_slug/start", SamlController, :start)
    post("/:org_slug/acs", SamlController, :acs)
    # IdP-initiated Single Logout (POST binding, signed LogoutRequest).
    post("/:org_slug/slo", SamlController, :slo)
  end

  # ── Core user auth — session-gated ──────────────────────────────────────
  scope "/v1/auth", BarkparkWeb do
    pipe_through([:user_auth, :require_user])

    get("/me", AuthController, :me)
    delete("/logout", AuthController, :logout)
    # Session-gated self-mint of a Personal Access Token that carries the
    # caller's USER identity. owner_user_id is HARD-BOUND to current_user.id
    # server-side (any body-supplied owner/user_id is ignored) — a user can
    # ONLY mint a token owned by themselves (no-escalation). Raw token returned
    # ONCE. Powers the terminal `bp access claim`/`mine` grantee verbs.
    post("/tokens", AuthController, :create_token)
    get("/export", AuthController, :export)
    post("/erase", AuthController, :erase)
    # Self-service password change, gated on the current password — same
    # re-auth shape as /erase. See AuthController.change_password/2.
    patch("/password", AuthController, :change_password)
    post("/mfa/enroll", AuthController, :mfa_enroll)
    post("/mfa/verify", AuthController, :mfa_verify)
    # Present a current factor to make this session step-up-fresh (clears a
    # `mfa_required` 401 before retrying a guarded action).
    post("/mfa/step-up", AuthController, :mfa_step_up)
    post("/mfa/disable", AuthController, :mfa_disable)
    # Session management: the "your devices" list + revoke-one (era-w7).
    get("/sessions", AuthController, :sessions)
    delete("/sessions/:id", AuthController, :revoke_session)

    # Passkeys (WebAuthn): enrol, step-up factor, and management.
    post("/webauthn/register/challenge", WebauthnController, :register_challenge)
    post("/webauthn/register", WebauthnController, :register)
    post("/webauthn/step-up/challenge", WebauthnController, :step_up_challenge)
    post("/webauthn/step-up", WebauthnController, :step_up)
    get("/webauthn/credentials", WebauthnController, :index)
    delete("/webauthn/credentials/:id", WebauthnController, :delete)
  end

  # ── Public status page + machine-readable status ────────────────────────
  scope "/", BarkparkWeb do
    pipe_through(:browser)
    get("/status", StatusController, :index)
  end

  scope "/", BarkparkWeb do
    pipe_through(:api)
    get("/status.json", StatusController, :show_json)
  end

  # Incident management — admin only.
  scope "/v1/status", BarkparkWeb do
    pipe_through([:api, :require_admin])
    post("/incidents", StatusController, :create_incident)
    post("/incidents/:id/resolve", StatusController, :resolve_incident)
  end

  # ── Capabilities manifest (CLI/MCP/SDK contract) — optional token ───────
  # The `:api` pipeline runs `OptionalToken`, so the controller resolves the
  # caller's tier (none when anonymous) and projects the manifest through the
  # existence-hiding allow-list keyed on it.
  scope "/v1", BarkparkWeb do
    pipe_through(:api)

    get("/capabilities", CapabilitiesController, :index)
  end

  # ── Instance machine meter: rolling req/s + p95 + 5xx window (cloud-console
  # W5; 5xx added dr-w5-s2) ──
  # Authed with the SAME Bearer-token seam the agent health gate probes
  # (`RequireToken`); never unauthenticated. Contract owned by
  # `BarkparkWeb.RequestStats` and pinned by `RequestStatsControllerTest`:
  # {"req_per_s": float, "p95_ms": int|null, "err_5xx_per_s": float|null,
  #  "window_s": int}.
  # Both nullable keys are `null` — never 0 — on an empty window: the agent maps
  # a null (or an absent key, from an instance that predates it) to its -1
  # unmeasured sentinel, and the control plane renders that unmetered.
  scope "/v1", BarkparkWeb do
    pipe_through(:cycle_api)

    get("/cycles/:epic_id/:wave_id", CycleFleetController, :show)
  end

  scope "/v1", BarkparkWeb do
    pipe_through([:api, :require_token])

    get("/instance/request-stats", RequestStatsController, :show)

    # Can this box deploy sites? Answered WITHOUT spending a deploy (dr-w15-s1).
    # Same Bearer seam, same never-unauthenticated rule as request-stats.
    # {"configured": bool, "runner_alive": bool, "door": {…}, "serving": {…}}
    # — was six keys until dr-w26-s7 deleted `build_slots` and
    # `runner_queue_len`, neither of which ever had a reader. Contract owned by
    # `BarkparkWeb.InstanceSiteDeployController` (read its moduledoc for why
    # each field's producer is the one that cannot lie) and pinned by
    # `InstanceSiteDeployControllerTest`. No field makes a GenServer.call, so a
    # WEDGED runner still gets an answer — true of the code, but NO LONGER
    # PINNED BY A TEST: the wedge control observed the wedge only through
    # `runner_queue_len` and went with it (dr-w26-s7).
    get("/instance/site-deploy", InstanceSiteDeployController, :show)

    # Prometheus scrape of the telemetry aggregates (p95 Ecto query, per-route
    # latency, VM memory/run-queue). Same Bearer seam — NOT the public `/metrics`
    # convention, because request-rate/latency/memory is instance-operational
    # data. Served by TelemetryMetricsPrometheus.Core (BarkparkWeb.Telemetry).
    get("/instance/metrics", MetricsController, :scrape)
  end

  scope "/v1", BarkparkWeb do
    pipe_through([:cycle_api, :require_write])

    post("/cycles/:epic_id/:wave_id/open", CycleFleetController, :open)
    post("/cycles/:epic_id/:wave_id/seal", CycleFleetController, :seal)
    post("/cycles/:epic_id/:wave_id/assignments", CycleFleetController, :create_assignment)

    post(
      "/cycles/:epic_id/:wave_id/assignments/:assignment_id/results",
      CycleFleetController,
      :create_result
    )
  end

  # ── Federated discovery ─────────────────────────────────────────────────
  scope "/v1", BarkparkWeb do
    pipe_through(:api)

    get("/search/:dataset", FederatedSearchController, :search)
  end

  # ── Public API — read-only, respects schema visibility ──────────────────
  # `:api_grant_read` layers the flat-path grant fold on top of `:api` — an
  # owned-token grantee sees EXACTLY their grant's scope; everyone else is
  # byte-identical. Reads only (blast-radius containment) — the write/admin
  # blocks below stay on bare `:api`.
  scope "/v1/data", BarkparkWeb do
    pipe_through([:api, :api_grant_read])

    get("/search/:dataset/suggestions", SearchController, :search_suggestions)
    post("/search/:dataset/interaction", SearchController, :search_interaction)
    post("/search/:dataset/correction", SearchController, :correction)
    get("/search/:dataset", SearchController, :search)
    get("/query/:dataset/:type", QueryController, :index)
    get("/doc/:dataset/:type/:doc_id", QueryController, :show)
    get("/backlinks/:dataset/:id", QueryController, :backlinks)
    # Related documents — shared weighted tags fused with inbound references
    # (authoring-excellence D68–D71 / manifest `doc.related`). Token/preview
    # only (existence-hiding, like backlinks); tenancy fail-closed via
    # scope_opts in the controller.
    get("/related/:dataset/:id", QueryController, :related)
    # Tag-registry reads (authoring-excellence ae-w10 / manifest `tag.browse` +
    # `tag.docs`): per-tag per-type published counts, and a tag's documents
    # ranked by that tag's strength (tags_meta lateral, DESC NULLS LAST).
    # Token/preview only (existence-hiding, like backlinks); tenancy
    # fail-closed via scope_opts in the controller.
    get("/tags/:dataset", QueryController, :tag_browse)
    get("/tags/:dataset/:tag", QueryController, :tag_docs)
    # Bundled per-type published-document counts — ONE GROUP BY d.type aggregate
    # (AXI charter decision 19 / manifest `data.counts`). Token/preview only
    # (existence-hiding, like backlinks); tenancy fail-closed in the controller.
    get("/counts/:dataset", QueryController, :counts)
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
    get("/backlinks/:dataset/:id", QueryController, :backlinks)
    get("/related/:dataset/:id", QueryController, :related)
    get("/tags/:dataset", QueryController, :tag_browse)
    get("/tags/:dataset/:tag", QueryController, :tag_docs)
  end

  # ── Private API — full CRUD, requires token ─────────────────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through([:api, :require_token])

    get("/listen/:dataset", ListenController, :listen)
    # Trigger an Indx blue/green rebuild for the scope. Oban-unique per scope,
    # so concurrent triggers collapse into one rebuild.
    #
    # NOT reachable by a `public-read` token, and this comment used to say
    # otherwise — it named "the public-read token the web demo holds" as an
    # intended caller. Mounting `Plugs.PublicRead` on `:require_token`
    # (2026-07-30) falsified that: the clamp allows only GET query/doc/graph, so
    # every other method AND path on this pipeline is denied to the public tier.
    # The claim then stood uncorrected for three weeks, which is the whole
    # hazard — a reader who trusts it "repairs" the 403 by adding a route-level
    # allowance and punches a POST-shaped hole through a clamp governing 44
    # routes. Unclamped, this route is not merely a disclosure: a
    # browser-shipped credential ENQUEUES an index rebuild across every type
    # (proven at 200 `{"ok":true,...,"jobId":...}` by deleting the clamp line).
    # Any non-public tier (`read`, `write`, `admin`) still calls it.
    #
    # Pinned by public_read_enforcement_test.exs, "reindex: POST is 403 forbidden
    # for a public-read token (the non-GET arm)" — the decision you would be
    # reversing.
    post("/search/:dataset/reindex", SearchController, :reindex)
    get("/export/:dataset", ExportController, :export)

    get("/analytics/:dataset", AnalyticsController, :index)

    get("/history/:dataset/:type/:doc_id", HistoryController, :index)
    get("/revision/:dataset/:id", HistoryController, :show)
  end

  # ── Claude chat transport (charter bp-chat-tui D21-D24; Connectors D18/D19a).
  # `[:api, :require_chat_access]`: RequireToken + RequireChatAccess resolve
  # `conn.assigns.chat_scope` BEFORE any UUID/store/runtime work — `:global` for
  # a global-admin token (instance-wide authority UNCHANGED, D21) or
  # `{:workspace, ws}` for a workspace-bound `chat` Connector, else 403. `:api`
  # supplies AcceptBarkparkVendor, which rewrites a `text/event-stream` Accept so
  # the SSE `:events` route negotiates JSON (D6) instead of 406-ing. The
  # controller confines a workspace scope to sessions its tenant owns; a
  # wrong-tenant read joins the not-found oracle. A strict Recorder/ClaudeChat
  # adapter: no adopt_sink, no launcher controls, no shed-and-close.
  scope "/v1/chat", BarkparkWeb do
    pipe_through([:api, :require_chat_access])

    # The herd fleet stream (charter D45h): snapshot-then-live STATE frames for the
    # whole in-scope herd on ONE connection. STATIC `/events` declared BEFORE the
    # dynamic `/sessions/:id/events` — sibling paths, never shadowed, but kept in
    # obvious order.
    get("/events", ChatController, :fleet_events)

    # The workspace fleet rollup (herd charter D64h): agent_state counts + one
    # precedence state, DB-scoped by chat_scope. STATIC, declared with /events
    # before the dynamic /sessions/:id routes.
    get("/rollup", ChatController, :rollup)

    get("/sessions", ChatController, :index)
    post("/sessions", ChatController, :create)
    get("/sessions/:id", ChatController, :show)
    patch("/sessions/:id", ChatController, :update)
    post("/sessions/:id/messages", ChatController, :create_message)
    post("/sessions/:id/interrupt", ChatController, :interrupt)
    post("/sessions/:id/approval", ChatController, :approval)

    # Archive shelf flips (charter D28): POST verbs (NOT a PATCH key — archived
    # is lifecycle, not a continuity field), same tenant oracle as every other
    # id route. They ride THIS :require_chat_access scope, never the
    # :registered_chat_host scope below.
    post("/sessions/:id/archive", ChatController, :archive)
    post("/sessions/:id/unarchive", ChatController, :unarchive)

    get("/sessions/:id/events", ChatController, :events)
  end

  scope "/w/:workspace_slug/v1/chat-hosts", BarkparkWeb do
    pipe_through([:api, :require_chat_host_admin])

    get("/", ChatHostController, :index)
    post("/enrollments", ChatHostController, :create_enrollment)
    delete("/:id", ChatHostController, :revoke)
  end

  scope "/v1/chat-host", BarkparkWeb do
    pipe_through(:api)
    post("/enroll", ChatHostController, :enroll)
  end

  scope "/v1/chat-host", BarkparkWeb do
    pipe_through(:registered_chat_host)
    post("/heartbeat", ChatHostController, :heartbeat)
    post("/rotate", ChatHostController, :rotate)
    get("/commands", ChatHostController, :commands)
    post("/events", ChatHostController, :event)
  end

  # Authoritative external state report (herd-s6, charter D78h/D79h): the
  # registered host holding a session's live execution-lease fence writes the
  # herd four-state directly. Host-credential auth (NOT a bearer token) — a
  # plain API token has no host identity for the fence's host_id leg, so the
  # route rides the :registered_chat_host pipeline like the /v1/chat-host
  # dispatch surface above, even though the path lives under /v1/chat.
  scope "/v1/chat", BarkparkWeb do
    pipe_through(:registered_chat_host)
    post("/sessions/:id/state", ChatHostController, :report_state)
  end

  # ── Revision restore — a WRITE (Revisions.restore_revision →
  # Content.upsert_document), so it carries the same :require_write gate as
  # /mutate. Split out of the token-only read scope above so a read/public-read
  # token can no longer overwrite a document via restore, while the history +
  # revision GET reads stay reachable by any member token.
  scope "/v1/data", BarkparkWeb do
    pipe_through([:api, :require_token, :require_write])

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
    # Expectation reverse view (lvw-t8): tasks that cite the doc, with their
    # acceptance-criteria state. Three segments — never shadowed by `/graph/:id`.
    get("/graph/:id/tasks", TasksController, :graph_tasks)
  end

  # Airdrop-grant grantee surface (JSON) — CLAIM + MINE. The authenticated
  # grantee binds a grant addressed to their email (claim) or lists the grants
  # bound to them (mine). Gated by `[:user_auth, :access_principal]`: a
  # `:current_user` from EITHER a login session OR an OWNED api_token (so a
  # terminal `bp access claim` / `bp access mine` works). Claim is the JSON twin
  # of the browser GrantController; both funnel through the SHARED
  # Access.ClaimFlow no-oracle decision (email match still enforced there).
  #
  # DECLARED BEFORE the grantor `/access/:id` block: the STATIC `GET
  # /access/mine` must win over the DYNAMIC `GET /access/:id` (else `mine` binds
  # `:id = "mine"` → show/2 → 404), the same static/dynamic ordering idiom as
  # `/graph` above.
  scope "/v1/access", BarkparkWeb do
    pipe_through([:user_auth, :access_principal])

    post("/claim", AccessController, :claim)
    get("/mine", AccessController, :mine)
  end

  # ── Airdrop grants — the `access` noun (grantor-driven surface) ─────────────
  # CORE (survives the `config :barkpark, :plugins, []` kill switch) — mounted
  # under `[:api, :require_token]` (bearer-gated, NOT admin). The no-escalation
  # gate lives INSIDE Access.mint/2 (a token can only confer capabilities it
  # holds in the body's workspace); list/show/revoke authorize per-grant. The
  # grantee CLAIM/MINE are NOT here — they need a USER identity (session or
  # owned token), so they sit in the `/v1/access` grantee block ABOVE.
  scope "/v1", BarkparkWeb do
    pipe_through([:api, :require_token])

    post("/access", AccessController, :mint)
    get("/access", AccessController, :index)
    get("/access/:id", AccessController, :show)
    delete("/access/:id", AccessController, :revoke)
  end

  # search-surface-config settings — per-workspace attributed (charter D45/D49).
  # These two routes run the bespoke admin pipeline that derives the caller's
  # OWN workspace before the admin gate, so a shared dataset slug no longer means
  # a shared config row. The sibling insights/synonyms routes below run the SAME
  # bespoke pipeline (charter D85/D86 — repoint) so their reads and writes land
  # on the caller's own workspace instead of collapsing to Default.
  scope "/v1/data", BarkparkWeb do
    pipe_through(:flat_admin_api)

    get("/search/:dataset/settings", SearchController, :search_settings)
    put("/search/:dataset/settings", SearchController, :update_search_settings)
  end

  # insights + synonyms — per-workspace attributed (charter D85/D86). Repointed
  # off `[:api, :require_admin]` (which ran AssignDefaultScope with NO
  # DeriveWorkspaceFromToken → collapsed every caller to Default) onto the
  # bespoke `:flat_admin_api` pipeline: DeriveWorkspaceFromToken (fail-
  # SOFT) runs before AssignDefaultScope, so a workspace-bound admin token
  # resolves ITS workspace while a nil-workspace token still falls through to
  # Default/global (READs stay global-legacy by D59 — never over-blocked).
  scope "/v1/data", BarkparkWeb do
    pipe_through(:flat_admin_api)

    get("/search/:dataset/insights", SearchController, :search_insights)
    get("/search/:dataset/synonyms", SearchController, :search_synonyms)
    get("/search/:dataset/synonyms/preview", SearchController, :preview_search_synonym)
    post("/search/:dataset/synonyms", SearchController, :create_search_synonym)
    post("/search/:dataset/synonyms/promote", SearchController, :promote_search_synonym)
    delete("/search/:dataset/synonyms/:id", SearchController, :delete_search_synonym)
  end

  # ── Desk structure — the canonical Studio tree, served for the TUI ──────
  # `:flat_admin_api`, not `[:api, :require_admin]`: the desk tree is built from
  # `Structure.build(dataset, scope_opts(conn))`, so on the naive pipeline every
  # caller was served the SEEDED DEFAULT workspace's tree (D45/D49).
  scope "/v1/structure", BarkparkWeb do
    pipe_through(:flat_admin_api)

    get("/:dataset", StructureController, :show)
  end

  # ── Schema management — requires admin token ────────────────────────────
  # `:flat_admin_api`, not `[:api, :require_admin]`: `upsert`/`delete` stamp and
  # filter on `scope_opts(conn)`, so on the naive pipeline a non-Default
  # workspace's admin read AND MUTATED the Default workspace's content model
  # (D45/D49). The scoped `/w/:ws/p/:project` twin below is unaffected.
  scope "/v1/schemas", BarkparkWeb do
    pipe_through(:flat_admin_api)

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
    get("/:name/audit", SecretController, :audit)
    get("/:name", SecretController, :show)
    put("/:name", SecretController, :update)
    delete("/:name", SecretController, :delete)
  end

  # ── Fleet support tokens — admin-only mint + revoke (PDF-D57/D60) ───────
  # The main mints a WRITE-capable, per-support ledger token (label
  # fleet-support-<name>) so a remote support machine works the ledger as a
  # distinct, attributable actor; DELETE revokes it at teardown. Admin gate =
  # WHO may mint, not the minted token's scope. Secret returned ONCE.
  #
  # :flat_admin_api, NOT [:api, :require_admin] (gyldendal field report, the
  # last Class A remnant #12826 did not reach). `:api` runs AssignDefaultScope,
  # which stamps `current_workspace = <seeded Default>` before the admin gate —
  # and `create/2` binds the MINTED CREDENTIAL to that assign. So a tenant admin
  # whose only membership is workspace X minted a live write token bound to
  # Default, plus a `member` row in Default (Auth.create_token/5 writes the
  # membership alongside the token), and that token then read Default's
  # documents: a durable credential manufactured inside a workspace the caller
  # was never a member of. :flat_admin_api derives the workspace from the
  # CALLER'S TOKEN before the Default fallback, so the mint lands in the
  # minter's own workspace. Same admin gate, same 401/403 surface.
  scope "/v1/fleet/support-tokens", BarkparkWeb do
    pipe_through(:flat_admin_api)

    post("/", FleetSupportTokenController, :create)
    delete("/:token_id", FleetSupportTokenController, :delete)
  end

  # ── Instance self-update — admin-only apply trigger + status ───────────
  # POST starts the configured update command (503 unless the box opted in
  # via BARKPARK_SELF_UPDATE_APPLY=1, 409 while a run is in flight); GET
  # returns the runner state + captured log tail. POST /rollback flips the
  # box back to the idle blue/green slot's recorded sha (same apply gate +
  # single-flight; sync preflight → async Port). See Barkpark.SelfUpdate.Runner.
  scope "/v1/admin", BarkparkWeb do
    pipe_through([:api, :require_admin])

    post("/self-update", SelfUpdateController, :trigger)
    get("/self-update", SelfUpdateController, :status)
    post("/rollback", SelfUpdateController, :rollback)

    # Site deploy — the control plane's remote-exec seam for a content-bound
    # STATIC site (charter D22). Same admin door as self-update (that is the
    # point: the CP already holds a per-instance admin token), but its OWN
    # runner: per-SLUG single-flight and a per-REQUEST build_id, which
    # SelfUpdate.Runner (global slot, compile-time command) cannot carry.
    # POST body: {slug, build_id, content_rev, mode, env}; GET takes ?slug=.
    # 503 unless BARKPARK_SITE_DEPLOY_APPLY=1. See Barkpark.Sites.DeployRunner.
    post("/site-deploy", SiteDeployController, :trigger)
    get("/site-deploy", SiteDeployController, :status)
  end

  # ── Webhooks — requires admin token ────────────────────────────────────
  # `:flat_admin_api`, not `[:api, :require_admin]`: the sharpest row of the
  # D45/D49 remainder. `create_webhook` stamps `workspace_id` from
  # `scope_opts(conn)`, so on the naive pipeline any workspace's admin token
  # registered a hook in the SEEDED DEFAULT workspace and received Default's
  # content-change stream; `show`/`rotate` reach Default's webhook secrets.
  scope "/v1/webhooks", BarkparkWeb do
    pipe_through(:flat_admin_api)

    get("/:dataset", WebhookController, :index)
    get("/:dataset/:id", WebhookController, :show)
    get("/:dataset/:id/deliveries", WebhookController, :deliveries)
    post("/:dataset", WebhookController, :create)
    post("/:dataset/:id/deliveries/:event_id/replay", WebhookController, :replay)
    post("/:dataset/:id/rotate", WebhookController, :rotate)
    post("/:dataset/:id/reenable", WebhookController, :reenable)
    post("/:dataset/:id/test-send", WebhookController, :test_send)
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

  # ── Personal-Development-Server blob push (pds W1 G2) ────────────────────
  # Admin-gated raw-blob write for CROSS-INSTANCE media re-pointing: a workspace
  # bundle import on a TARGET instance copies the source's DB rows, then pushes
  # each source blob HERE by its server-generated relative path so `serve/2`
  # (which derives the disk path from the row's `path`) finds the bytes. The
  # `*path` is validated to the server-blob shape by `Media.put_blob/3` (reject
  # traversal / absolute / malformed → 422) and the body is written verbatim.
  # DELIBERATELY a bare route — an infra primitive, NOT a public SDK verb, so it
  # is absent from the capabilities manifest. `:workspace_slug` is BINDING: the
  # `:require_admin` gate below is workspace-BLIND, so the action itself resolves
  # the slug, binds the caller with `TenancyAuth.member?/2`, and refuses any blob
  # key another workspace owns. Blobs still share one media root — the tenant
  # wall is ownership of the key, not a prefix on it (see `Media.put_blob/3`).
  scope "/api/workspaces/:workspace_slug/media", BarkparkWeb do
    pipe_through([:api, :require_admin])

    put("/blob/*path", MediaController, :put_blob)
  end

  # ── v1 Media — unified blob + mediaAsset metadata ───────────────────────
  # media search-surface-config settings — per-workspace attributed (charter
  # D45/D49), same bespoke admin pipeline as the documents settings routes.
  scope "/v1/media", BarkparkWeb do
    pipe_through(:flat_admin_api)

    get("/:dataset/search/settings", V1.MediaController, :search_settings)
    put("/:dataset/search/settings", V1.MediaController, :update_search_settings)
  end

  # media insights + synonyms — per-workspace attributed (charter D85/D86),
  # repointed onto the same bespoke `:flat_admin_api` pipeline as the
  # documents block above so a workspace-bound admin token resolves ITS workspace
  # instead of collapsing to Default; a nil-workspace token still falls through.
  scope "/v1/media", BarkparkWeb do
    pipe_through(:flat_admin_api)

    get("/:dataset/search/insights", V1.MediaController, :search_insights)
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
    pipe_through([:shared_paper_browser, :paper_reader_csp])

    get("/d/:dataset/papers/:slug/source", BulldocsSourceController, :show)
    get("/papers/:slug/source", BulldocsSourceController, :show)
    get("/papers/:slug/email", BulldocsEmailController, :show)

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
    get("/v1/preview/backlinks/:dataset/:id", QueryController, :backlinks)
    get("/v1/preview/related/:dataset/:id", QueryController, :related)
    get("/v1/preview/tags/:dataset", QueryController, :tag_browse)
    get("/v1/preview/tags/:dataset/:tag", QueryController, :tag_docs)
  end

  scope "/w/:workspace_slug/p/:project_slug/v1", BarkparkWeb do
    pipe_through([:scoped_api, :require_token])

    get("/cycles/:epic_id/:wave_id", CycleFleetController, :show)

    get(
      "/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/papers/:role/source",
      CycleFleetController,
      :release_paper_source
    )

    get(
      "/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/papers/:role/render",
      CycleFleetController,
      :release_paper_render
    )
  end

  scope "/w/:workspace_slug/p/:project_slug/v1", BarkparkWeb do
    pipe_through([:scoped_api, :require_token, :require_write])

    post("/cycles/:epic_id/:wave_id/open", CycleFleetController, :open)

    post(
      "/cycles/:epic_id/:wave_id/release-gates/open",
      CycleFleetController,
      :admit_open_release_gate
    )

    post(
      "/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/papers/:role/stage",
      CycleFleetController,
      :stage_release_paper
    )

    post(
      "/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/activate",
      CycleFleetController,
      :activate_release_gate
    )

    post("/cycles/:epic_id/:wave_id/seal", CycleFleetController, :seal)
    post("/cycles/:epic_id/:wave_id/quarantine", CycleFleetController, :quarantine)
    post("/cycles/:epic_id/:wave_id/promote", CycleFleetController, :promote)
    post("/cycles/:epic_id/:wave_id/rollback", CycleFleetController, :rollback)
    post("/cycles/:epic_id/:wave_id/assignments", CycleFleetController, :create_assignment)

    post(
      "/cycles/:epic_id/:wave_id/assignments/:assignment_id/results",
      CycleFleetController,
      :create_result
    )
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
    get("/v1/data/backlinks/:dataset/:id", QueryController, :backlinks)
    get("/v1/data/related/:dataset/:id", QueryController, :related)
    get("/v1/data/tags/:dataset", QueryController, :tag_browse)
    get("/v1/data/tags/:dataset/:tag", QueryController, :tag_docs)
    # Scoped mirror of the flat bundled-counts read (AXI decision 19) — a scoped
    # caller resolves its real workspace/project, so counts stay tenant-true.
    get("/v1/data/counts/:dataset", QueryController, :counts)
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
  end

  # Scoped revision restore — a WRITE, so it carries :require_write on top of the
  # scoped-read pipeline, mirroring the flat restore split above. Kept out of the
  # token-only scoped-read scope so a read/public-read token cannot overwrite a
  # document via restore; the scoped history + revision GET reads stay open to
  # any member token.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :require_token, :require_write])

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

  # Scoped MEMBER administration (admin) — the workspace roster: who holds a
  # seat, seat a human, change a role, remove a seat, plus the token inventory
  # for this workspace. Same :scoped_admin gate as schema management and the
  # token mint, so authority is the membership ROLE in the resolved workspace
  # (`owner`/`admin`), never a token's global permissions.
  #
  # Every primitive underneath (Membership, create_membership/4,
  # workspace_admin?/2) predates this block; what was missing was any endpoint
  # at all, which is why an instance owner could not seat their own account in
  # a workspace their token had created. The two safety rails live in
  # `Barkpark.Tenancy.Members`: last-owner protection and an explicitly stated
  # principal kind.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/members", MemberController, :index)
    post("/v1/members", MemberController, :create)
    patch("/v1/members/:principal_ref", MemberController, :update)
    delete("/v1/members/:principal_ref", MemberController, :delete)

    # Token inventory + revocation. `GET` answers "which credentials reach this
    # workspace"; `DELETE` kills one, gated on that token actually holding a
    # seat HERE (cross-tenant rail — an admin of A must not reach B's token).
    get("/v1/tokens", MemberController, :tokens)
    delete("/v1/tokens/:id", MemberController, :revoke_token)
  end

  # Scoped CHAT token mint (admin) — mints a workspace-bound token whose
  # permission set is HARDCODED to ["chat"] (Connectors D36). Deliberately a
  # separate controller from TokenController above (whose allowlist is read-only
  # by contract): a connector install needs a per-tenant chat credential, and an
  # `admin` entry would resolve to `:global` chat scope and stamp NULL-owner
  # sessions. Same :scoped_admin gate (owner/admin role in the resolved
  # workspace), so this can never be a privilege-mint.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    post("/v1/chat/tokens", ChatTokenController, :create)
  end

  # Scoped webhooks (admin).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/webhooks/:dataset", WebhookController, :index)
    get("/v1/webhooks/:dataset/:id", WebhookController, :show)
    get("/v1/webhooks/:dataset/:id/deliveries", WebhookController, :deliveries)
    post("/v1/webhooks/:dataset", WebhookController, :create)
    post("/v1/webhooks/:dataset/:id/deliveries/:event_id/replay", WebhookController, :replay)
    post("/v1/webhooks/:dataset/:id/rotate", WebhookController, :rotate)
    post("/v1/webhooks/:dataset/:id/reenable", WebhookController, :reenable)
    post("/v1/webhooks/:dataset/:id/test-send", WebhookController, :test_send)
    put("/v1/webhooks/:dataset/:id", WebhookController, :update)
    delete("/v1/webhooks/:dataset/:id", WebhookController, :delete)
  end

  # Scoped run-secrets (admin) — the per-workspace tier of the encrypted
  # store (connectors D197/D199). Same SecretController as the flat
  # /v1/secrets route; the controller keys the tier off the ROUTE
  # (path_params carries :workspace_slug here) and threads the resolved
  # workspace id — a workspace admin manages ONLY their workspace's scoped
  # secrets, never the global tier.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through([:scoped_api, :scoped_admin])

    get("/v1/secrets", SecretController, :index)
    get("/v1/secrets/:name/audit", SecretController, :audit)
    get("/v1/secrets/:name", SecretController, :show)
    put("/v1/secrets/:name", SecretController, :update)
    delete("/v1/secrets/:name", SecretController, :delete)
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

  # scaffy:zone scoped-mirrors (ensure-router-zones) -- stable tail anchor
  # for NEW workspace-scoped mirror scopes: add your
  # `scope "/w/:workspace_slug/p/:project_slug" ...` block DIRECTLY BELOW
  # this comment. Ordering contract this position guards: every mirror above
  # owns a disjoint `/v1/<noun>` suffix, so a new mirror is order-neutral
  # here PROVIDED (a) its suffix starts `/v1/` with a NOVEL noun -- a route
  # under a noun an existing block already serves belongs INSIDE that owning
  # block, statics before dynamic `:param` segments (the /graph and
  # /access/mine idiom), because an earlier dynamic like `/v1/media/:dataset`
  # swallows a later literal -- and (b) it is NEVER a `/studio`-suffixed
  # scope: the `/w/:ws/p/:proj/studio/:dataset` back-compat wildcard far
  # above swallows those, so studio scopes are declared BEFORE that wildcard,
  # beside the scoped plugin scopes. Sweeps: move this comment only whole,
  # on its own lines. MARK:zone-scoped-mirrors

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

    get(
      "/workspaces/:workspace_slug/projects/:project_slug/datasets",
      WorkspaceController,
      :datasets
    )

    # Create surface: any authenticated token may create a workspace (becomes
    # its owner-member, + Default project + production dataset); project
    # creation is member-gated (non-member → 404, no existence leak).
    post("/workspaces", WorkspaceController, :create)
    post("/workspaces/:workspace_slug/projects", WorkspaceController, :create_project)
  end

  # ── Workspace DELETE — admin-gated destructive teardown ─────────────────
  # Separate scope (NOT the membership-scoped switcher above) because delete is
  # the destructive primitive eject / backup / abuse-isolation build on: it
  # requires the GLOBAL `admin` permission. The `:require_admin` pipeline
  # (RequireToken + RequireAdmin) 401s an absent token and 403s a non-admin
  # BEFORE the action runs; the action delegates to `Tenancy.delete_workspace/1`,
  # which cascades across every workspace_id-scoped table inside one
  # rollback-on-failure transaction (zero orphans).
  #
  # THE PIPELINE IS ONLY HALF THE GATE (task-a5636ad31304b23a). `:require_admin`
  # proves a global permission and never reads a workspace, so it cannot say
  # WHICH workspace the caller may destroy — on its own it let any admin token
  # delete any tenant's workspace by slug. `WorkspaceController.delete/2` binds
  # the verb to the URL's workspace with `TenancyAuth.workspace_admin?/2`.
  # Do NOT read "admin-gated" here as "tenancy-gated": that inference is exactly
  # what shipped the hole.
  scope "/api", BarkparkWeb do
    pipe_through([:api, :require_admin])

    delete("/workspaces/:workspace_slug", WorkspaceController, :delete)
  end

  # ── Playground front door — provision a disposable workspace + scoped token ─
  # perfect-plan-build W2c (charter D25/D27). One call mints a real, ephemeral
  # `tier: "playground"` workspace (expires_at = now + 48h, document quota 100)
  # plus a workspace-scoped NON-admin visitor token — the top-of-funnel "try it
  # now" experience. Same admin gate as DELETE above this wave; the public,
  # rate-limited anon exposure is W3 backlog (`bpb-playground-rate-limit`).
  #
  # DELIBERATELY a bare router+controller route with NO capabilities manifest
  # command: `docs/openapi.json` is manifest-derived, so a bare route is
  # invisible to the OpenAPI drift gate (mirrors DELETE above, also absent from
  # the spec) — zero drift trip, zero local-OOM spec regen (charter D22).
  scope "/api", BarkparkWeb do
    pipe_through([:api, :require_admin])

    post("/playground", PlaygroundController, :provision)
  end

  # ── Workspace bundle transfer — admin-gated export / import ──────────────
  # The HTTP surface over the shipped `Barkpark.Tenancy.WorkspaceBundle` keystone
  # engine (bp-export-v1): a complete, self-describing, round-trippable dump of
  # every workspace-scoped table. Same admin gate as delete above — the bundle
  # is the raw byte carrier that backup / eject / migration build on, so it
  # requires the GLOBAL `admin` permission.
  #
  # AND, like delete, the pipeline is only half the gate (task-f416f96ef0860f47):
  # `export/2` binds to the URL's workspace with `TenancyAuth.workspace_admin?/2`,
  # because `:require_admin` alone streamed any tenant's complete bundle to any
  # admin-permissioned token.
  #
  # `import` is DELIBERATELY not bound the same way, and that asymmetry is the
  # reason this binding lives in the two ACTIONS rather than in a plug on this
  # shared scope. `import/2` ignores its `workspace_slug` (it is underscored);
  # the target comes from the uploaded bundle's manifest, and the normal restore
  # case is a workspace that does NOT exist yet. A `ResolveWorkspace`-style plug
  # on this pipeline would 404 exactly those legitimate restores before the
  # action ran. Its own collision paths fail closed instead — clean mode's bare
  # `COPY FROM STDIN` is a PK violation on a duplicate id, `unique_index(
  # :workspaces, [:slug])` refuses a slug squat, and both roll back; merge mode
  # sits behind the fail-closed `:allow_bundle_import` opt-in and
  # `adopt_or_refuse_root_slug!/1`.
  #
  # DELIBERATELY a bare router+controller route with NO capabilities manifest
  # command: `docs/openapi.json` is manifest-derived, so a bare route is invisible
  # to the OpenAPI drift gate (mirrors the DELETE route above, also absent from
  # the spec) — zero drift trip, zero local-OOM spec regen.
  #
  # export is SYNC but CONSTANT-MEMORY (pds-w11-spill-engine):
  # `WorkspaceBundle.export_to_file/2` streams the bundle to a per-request temp
  # tar and the action `send_file/3`s it under an `application/x-tar`
  # attachment — the whole-tar-in-RAM materialization is gone from the HTTP
  # path (`export/2`'s `{:ok, binary()}` contract survives for the fidelity
  # suite only). import SPILLS the raw tar body to disk in bounded chunks
  # (`with_spilled_body/2` -> `import_bundle_file/2`) — a RESTORE into a clean
  # scope: E3/allowlist members are idempotent (INSERT ON CONFLICT DO NOTHING)
  # but the copy-strategy members (root/E1/E2) assume an empty target.
  scope "/api", BarkparkWeb do
    pipe_through([:api, :require_admin])

    get("/workspaces/:workspace_slug/export", WorkspaceController, :export)
    post("/workspaces/:workspace_slug/import", WorkspaceController, :import)
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
  end

  # Legacy document WRITES (create/delete) — these call Content.upsert_document /
  # delete_document directly with no in-controller permission check, so the
  # :require_write gate is the write authorization (mirrors /v1/data/mutate). Kept
  # in a separate scope from the legacy GET reads so a read/public-read token can
  # no longer create or delete a document via the deprecated /api/documents surface.
  scope "/api", BarkparkWeb do
    pipe_through([:api, :require_token, :require_write, BarkparkWeb.Plugs.LegacyDeprecation])

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

  # Test-only route that deliberately raises, so the RenderErrors integration
  # tests can prove ErrorJSON/ErrorHTML render a well-formed response end-to-end.
  # The app defends every real path (route misses and parse errors are handled
  # gracefully), so nothing user-facing raises — this is the only way to reach
  # the crash path. Compiled out unless :error_test_routes is set (config/test.exs).
  #
  # This pipeline used to carry a permanent Sobelow Config.Headers waiver on the
  # grounds that it is compiled out of dev and prod. That reasoning was sound but
  # the waiver was not free: a baselined finding is a line-anchored fingerprint
  # that has to be re-anchored on every drift, and a permanently-red security
  # gate cannot report a regression. Setting the headers costs three lines, so
  # the waiver is deleted instead. The two-arg map form is the house pattern
  # (see :browser, :shared_paper_browser) and is what Sobelow's syntactic
  # Config.CSP check credits — the one-arg form would merely trade this finding
  # for an uncredited Config.CSP one. Honest price: because the pipeline is
  # compile_env-gated to MIX_ENV=test, this prevents no production failure.
  if Application.compile_env(:barkpark, :error_test_routes, false) do
    pipeline :error_test do
      plug(:accepts, ["json", "html"])

      plug(:put_secure_browser_headers, %{
        "content-security-policy" => "default-src 'none'"
      })
    end

    scope "/__error_test__", BarkparkWeb do
      pipe_through(:error_test)
      get("/boom", ErrorTestController, :boom)
    end
  end
end
