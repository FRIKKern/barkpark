defmodule BarkparkWeb.Contract.RouterManifestDriftTest do
  @moduledoc """
  Router ↔ capabilities-manifest drift guard.

  ## The named failure mode

  `bp` is manifest-driven: the Go binary builds its entire verb table from
  `GET /v1/capabilities`, and `GET /v1/openapi.json` is generated from the same
  manifest. So a `/v1` route the manifest omits is a capability that EXISTS on
  the server and is UNREACHABLE from the tool — with no error on either side and
  nothing to grep. The server answers it; `bp` reports no such command; neither
  is wrong, and the omission is invisible from both ends. That is how SSE listen,
  the whole sheets surface, `GET /v1/graph`, and two media collection reads
  shipped with no CLI verb and no OpenAPI operation.

  The inverse is the same disease pointed the other way: a manifest command whose
  `path_template` no mounted route serves is a verb `bp` offers and the server
  404s. Plugin routes expand into the router at COMPILE time
  (`BarkparkWeb.Router.Plugins.plugin_routes/1`) while the manifest is assembled
  at RUNTIME, so a stale router BEAM produces exactly that shape.

  ## What this guard compares

  `BarkparkWeb.Router.__routes__/0` is the complete census — plugin routes are
  inlined into the router at compile time, so nothing is hidden behind a
  `forward/2` or a registry read. Every mounted controller route in a walked
  namespace (`@walked_prefixes`) must either carry a manifest command with the
  same method and path shape, or be named in `@not_a_cli_surface` with the
  reason it is not one, or be a filed row in `@filed_gaps`.

  Both sides are first collapsed onto the FLAT `/v1/…` shape by stripping a
  leading `/w/:workspace_slug/p/:project_slug`, because the two surfaces spell
  the same capability differently: most commands name the flat path and carry
  the mirror as `scoped_prefix`, while the `cycle.*` commands name the scoped
  path directly ("flat /v1/cycles routes remain a projectless compatibility API
  and are never selected by bp" — `Capabilities.core_commands/0`). Comparing
  raw paths would report every `cycle.*` verb as dangling and every flat
  `/v1/cycles` route as unlisted, when the capability is reachable from `bp` by
  its scoped spelling.

  ## The three maps, and why only one of them is a backlog

  A route with no command lands in exactly one of three places, and the
  distinction is the whole design:

    * `@not_a_cli_surface` — it can NEVER be a `bp` verb. A browser redirect leg,
      a platform-authenticator ceremony, a CORS preflight, a daemon's own
      callback. Each entry states why.
    * `@served_by_a_builtin` — it is already reachable, just not through the
      manifest. `bp listen`, `bp export` and friends are dispatched directly by
      `internal/cli/cli.go` because a long-lived stream is not the single JSON
      body the generic command path decodes. Each entry cites the Go line that
      BUILDS the URL; a comment mentioning a path is not evidence.
    * `@filed_gaps` — it genuinely should have a verb and does not. Each entry
      names the task tracking it.

  The first two are CLASSIFICATIONS and cannot rot: `"every classified route is
  still mounted"` fails the moment an entry stops naming a live route, so a
  stale row cannot sit there absolving a future route that reuses its
  method+path.

  `@filed_gaps` is the only backlog, and it is a ratchet DOWN rather than a
  baseline. `"@filed_gaps only ever shrinks"` fails when a row gains a command,
  so declaring one means deleting its row in the same change; it also fails when
  a row's route disappears. And because a route in NONE of the three maps fails
  outright, a newly mounted route with no verb reds immediately — the drift this
  guard exists to stop is caught from day one even while the historical backlog
  is still being paid down.

  What must never happen: moving a route into `@not_a_cli_surface` or
  `@served_by_a_builtin` because writing its declaration looked like work. Those
  two answer "this is not a gap"; only evidence, not inconvenience, puts a route
  in them.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Capabilities

  # ── Anti-vacuity floors ───────────────────────────────────────────────────
  #
  # A comparison over an empty set passes for free: zero routes walked, zero
  # commands compared, green. Both sides are DERIVED, and both can collapse
  # without any test noticing — so neither is allowed to be small.
  #
  # The command floor is not a round number. `Capabilities.manifest/2` folds the
  # plugin registry through `safe_registry/2`, which fails SOFT to a default, so
  # a manifest built while the registry is down still LOOKS like a manifest —
  # just a core-only one. Measured on this tree: 167 commands with the registry
  # up, 121 with it down (e.g. under `mix run --no-start`). 140 sits between the
  # two, so the degraded manifest reds instead of quietly halving what the drift
  # test compares. The route floor has 43 of headroom under the observed 283.
  @min_walked_routes 240
  @min_commands 140

  # The census row carrying every remaining omission (see @filed_gaps).
  @census_task "task-b1801ed5c86d2e2e"

  # Mounted `/v1` routes that are structurally not `bp` verbs. Each entry must
  # state WHY — "no verb yet" is not a reason, it is the defect this guard
  # exists to find, and such a route belongs in @filed_gaps instead.
  @not_a_cli_surface %{
    # ── CORS preflight ─────────────────────────────────────────────────────
    # An OPTIONS probe a browser sends before the real request. There is no
    # operator intent behind it and nothing to render.
    {"OPTIONS", "/v1/plugins/bulldocs/papers/:*/form-responses"} => "CORS preflight",
    {"OPTIONS", "/v1/plugins/pulse/:*/events"} => "CORS preflight",
    {"OPTIONS", "/v1/plugins/pulse/:*/recent"} => "CORS preflight",
    {"OPTIONS", "/v1/plugins/pulse/:*/stats"} => "CORS preflight",

    # ── Browser-redirect legs of an SSO/OAuth ceremony ──────────────────────
    # `start` 302s the USER AGENT to the identity provider and `callback`/`acs`
    # is the IdP's redirect back with a browser-bound state cookie. A CLI cannot
    # be the user agent in the middle, so neither leg is invocable as a verb.
    {"GET", "/v1/auth/oidc/:*/start"} => "OIDC redirect leg — browser only",
    {"GET", "/v1/auth/oidc/:*/callback"} => "OIDC IdP redirect target — browser only",
    {"GET", "/v1/auth/saml/:*/start"} => "SAML redirect leg — browser only",
    {"POST", "/v1/auth/saml/:*/acs"} => "SAML assertion consumer — the IdP POSTs here",
    {"POST", "/v1/auth/saml/:*/slo"} => "SAML single logout — the IdP POSTs here",
    {"GET", "/v1/auth/social/:*/start"} => "social OAuth redirect leg — browser only",
    {"GET", "/v1/auth/social/:*/callback"} => "social OAuth redirect target — browser only",
    {"POST", "/v1/auth/sso/route"} =>
      "tells a LOGIN PAGE which SSO provider to redirect to; the answer is a browser redirect",

    # ── WebAuthn ceremonies ────────────────────────────────────────────────
    # Each is one half of a challenge/response with a platform authenticator
    # (Touch ID, a security key). The signing step happens in the browser's
    # WebAuthn API; `bp` has no authenticator to sign with, so even the
    # credential list is browser account UI rather than an operator verb.
    {"POST", "/v1/auth/webauthn/login/challenge"} => "WebAuthn ceremony — needs an authenticator",
    {"POST", "/v1/auth/webauthn/login"} => "WebAuthn ceremony — needs an authenticator",
    {"POST", "/v1/auth/webauthn/register/challenge"} =>
      "WebAuthn ceremony — needs an authenticator",
    {"POST", "/v1/auth/webauthn/register"} => "WebAuthn ceremony — needs an authenticator",
    {"POST", "/v1/auth/webauthn/step-up/challenge"} =>
      "WebAuthn ceremony — needs an authenticator",
    {"POST", "/v1/auth/webauthn/step-up"} => "WebAuthn ceremony — needs an authenticator",
    {"GET", "/v1/auth/webauthn/credentials"} => "WebAuthn credential list — browser account UI",
    {"DELETE", "/v1/auth/webauthn/credentials/:*"} =>
      "WebAuthn credential delete — browser account UI",

    # ── Inbound calls: something else dials these, never an operator ────────
    {"POST", "/v1/plugins/github/webhook"} => "GitHub POSTs this; signature-verified receiver",
    {"POST", "/v1/media/:*/processing/:*/callback"} =>
      "the media processing worker calls this back; not an operator verb",
    {"POST", "/v1/plugins/bulldocs/papers/:*/form-responses"} =>
      "a reader submits a rendered paper's form from the browser",

    # ── Scrape + self-describing endpoints ─────────────────────────────────
    # `bp` fetches the manifest and spec directly as part of BEING a client;
    # advertising them inside the manifest they produce is circular.
    {"GET", "/v1/instance/metrics"} =>
      "Prometheus scrape target — text/plain exposition, not a JSON verb",
    {"GET", "/v1/capabilities"} => "the manifest itself — `bp` fetches it to learn its verbs",
    {"GET", "/v1/openapi.json"} => "the spec generated FROM the manifest",
    {"GET", "/v1/meta"} => "server identity probe `bp` reads directly during connect",

    # ── The chat-host daemon's own protocol ────────────────────────────────
    # An enrolled host process speaks these with its enrollment secret to poll
    # for work and report liveness. An operator never types them.
    {"GET", "/v1/chat-host/commands"} => "enrolled chat-host daemon polls for work",
    {"POST", "/v1/chat-host/enroll"} => "chat-host daemon enrollment handshake",
    {"POST", "/v1/chat-host/events"} => "chat-host daemon pushes runtime events",
    {"POST", "/v1/chat-host/heartbeat"} => "chat-host daemon liveness ping",
    {"POST", "/v1/chat-host/rotate"} => "chat-host daemon rotates its own secret",
    {"POST", "/v1/chat/sessions/:*/state"} => "chat-host daemon reports session state",

    # ── Tickets SUBMITTER surface — a RATIFIED omission, not a gap ──────────
    # Charter Decision 10 + 11 ("manifest honesty"), reasoned in full at
    # `Barkpark.Plugins.Tickets.CLI`'s moduledoc: these routes 401 every
    # operator bearer via `RequireTicketKey`, and the only credential they DO
    # accept — a `bptk_…` key — is unknown to `Auth.verify_token/1`, so
    # `Capabilities.tier_for_token/1` projects `none` for its holder. A verb no
    # `bp` credential can run has no place in the manifest; the submitter's
    # surface is the mint handoff card's raw curl (api-v1.md §8a).
    {"POST", "/v1/tickets"} => "tickets submitter surface — ratified omission (charter D10/D11)",
    {"GET", "/v1/tickets"} => "tickets submitter surface — ratified omission (charter D10/D11)",
    {"GET", "/v1/tickets/:*"} =>
      "tickets submitter surface — ratified omission (charter D10/D11)",
    {"POST", "/v1/tickets/:*/messages"} =>
      "tickets submitter surface — ratified omission (charter D10/D11)",
    {"POST", "/v1/tickets/:*/attachments"} =>
      "tickets submitter surface — ratified omission (charter D10/D11)",
    {"GET", "/v1/tickets/:*/attachments/:*"} =>
      "tickets submitter surface — ratified omission (charter D10/D11)",
    {"GET", "/v1/tickets/inbox/:*/attachments/:*"} =>
      "operator attachment DOWNLOAD — a cookie-authed binary response, not a JSON verb"
  }

  # Routes a `bp` BUILT-IN already dials. These are reachable from the CLI
  # today — they are neither a gap nor a non-CLI surface, and filing them as
  # missing work would send someone to build a verb that already exists in
  # another spelling.
  #
  # The category is not theoretical. `data.listen` was declared here first, and
  # the round trip against a live instance showed `bp data listen` returning ZERO
  # bytes while the `bp listen` built-in streamed the welcome frame and a live
  # mutation event: SSE is a long-lived stream, not the single JSON body the
  # generic manifest path decodes, which is exactly why `internal/cli/cli.go`
  # dispatches it as a built-in. The declaration was withdrawn.
  #
  # Every entry names the Go FUNCTION that builds the URL — a comment MENTIONING
  # a path is not evidence, and three candidates were rejected on that test.
  # Symbols, not line numbers: a line pin rots on any insertion above it, and
  # one of these already had — a pin written at `mediaUploadFileArg` addressed a
  # different function twenty-one commits later, before the doc-anchors gate
  # caught it
  # (`/v1/chat/events`, `/v1/admin/self-update`, `/v1/admin/rollback` matched
  # only prose and stayed in @filed_gaps).
  @served_by_a_builtin %{
    {"GET", "/v1/data/listen/:*"} => "bp listen — apiclient Client.Listen",
    {"GET", "/v1/data/export/:*"} => "bp export — apiclient Client.Export",
    {"GET", "/v1/structure/:*"} => "the desk tree — apiclient Client.LoadStructure",
    {"POST", "/v1/tasks/:*/labels"} => "bp task relabel — apiclient Client.TaskRelabel",
    {"GET", "/v1/instance/request-stats"} => "the agent report — internal/agent gatherReport",
    {"POST", "/v1/plugins/bulldocs/papers/:*/sync"} =>
      "bp paper sync — apiclient Client.PaperSync",
    {"POST", "/v1/plugins/bulldocs/papers/validate"} =>
      "bp paper --check — internal/cli runPaperPushCheck",
    {"POST", "/v1/fleet/support-tokens"} =>
      "bp cloud support add — internal/cli supportAddRun.stepBind",
    {"DELETE", "/v1/fleet/support-tokens/:*"} =>
      "bp cloud support remove — internal/cli supportRemoveRun.stepToken",
    {"PUT", "/api/workspaces/:*/media/blob/:*"} =>
      "bp cloud workspace blob push — internal/cli putOneBlob"
  }

  # Routes that SHOULD carry a `bp` verb and do not. This is the census from
  # task-b1801ed5c86d2e2e, carried in the tree rather than in a wiki: every
  # entry is filed, named here, and counted on every run.
  #
  # It is a RATCHET DOWN, not a baseline. `"@filed_gaps only ever shrinks"`
  # fails when an entry stops being an omission, so declaring a command means
  # deleting its row in the same change. And because a route in NEITHER map
  # fails outright, a newly mounted route with no verb reds immediately — the
  # thing this guard exists to prevent is guarded from day one even while the
  # historical backlog is still being paid down.
  @filed_gaps %{
    # BarkparkWeb.AppTokenController (5)
    {"GET", "/v1/auth/app-tokens"} => @census_task,
    {"POST", "/v1/auth/app-tokens"} => @census_task,
    {"DELETE", "/v1/auth/app-tokens"} => @census_task,
    {"DELETE", "/v1/auth/app-tokens/:*"} => @census_task,
    {"DELETE", "/v1/auth/app-tokens/current"} => @census_task,

    # BarkparkWeb.AuthController (9)
    {"POST", "/v1/auth/erase"} => @census_task,
    {"GET", "/v1/auth/export"} => @census_task,
    {"POST", "/v1/auth/magic-login"} => @census_task,
    {"POST", "/v1/auth/mfa/step-up"} => @census_task,
    {"PATCH", "/v1/auth/password"} => @census_task,
    {"POST", "/v1/auth/request-magic-link"} => @census_task,
    {"GET", "/v1/auth/sessions"} => @census_task,
    {"DELETE", "/v1/auth/sessions/:*"} => @census_task,
    {"POST", "/v1/auth/tokens"} => @census_task,

    # BarkparkWeb.BulldocsIngestController (5)
    {"POST", "/v1/paperflow/papers"} => @census_task,
    {"POST", "/v1/paperflow/papers/:*/ops"} => @census_task,
    {"POST", "/v1/plugins/bulldocs/sessions/:*/ops"} => @census_task,

    # BarkparkWeb.BulldocsIntentsController (2)
    {"GET", "/v1/paperflow/intents"} => @census_task,
    {"POST", "/v1/paperflow/intents/:*/processed"} => @census_task,

    # BarkparkWeb.ChatController (3)
    {"GET", "/v1/chat/events"} => @census_task,
    {"GET", "/v1/chat/rollup"} => @census_task,
    {"GET", "/v1/chat/sessions/:*/events"} => @census_task,

    # BarkparkWeb.ChatTokenController (1)
    {"POST", "/v1/chat/tokens"} => @census_task,

    # BarkparkWeb.CycleFleetController (2)
    {"GET", "/v1/cycles/:*/:*/release-gates/:*/papers/:*/render"} => @census_task,
    {"GET", "/v1/cycles/:*/:*/release-gates/:*/papers/:*/source"} => @census_task,

    # BarkparkWeb.ExportController (1)

    # BarkparkWeb.FederatedSearchController (1)
    {"GET", "/v1/search/:*"} => @census_task,

    # BarkparkWeb.FleetSupportTokenController (2)

    # BarkparkWeb.InstanceSiteDeployController (1)
    {"GET", "/v1/instance/site-deploy"} => @census_task,

    # BarkparkWeb.LoginTicketController (1)
    {"POST", "/v1/auth/login-tickets"} => @census_task,

    # BarkparkWeb.MediaController (1)

    # BarkparkWeb.PluginSettingsController (2)
    {"GET", "/v1/plugins/settings/:*"} => @census_task,
    {"DELETE", "/v1/plugins/settings/:*"} => @census_task,

    # BarkparkWeb.PulseController (3)
    {"POST", "/v1/plugins/pulse/:*/events"} => @census_task,
    {"GET", "/v1/plugins/pulse/:*/recent"} => @census_task,
    {"GET", "/v1/plugins/pulse/:*/stats"} => @census_task,

    # BarkparkWeb.QueryController (6)
    {"GET", "/v1/preview/backlinks/:*/:*"} => @census_task,
    {"GET", "/v1/preview/doc/:*/:*/:*"} => @census_task,
    {"GET", "/v1/preview/query/:*/:*"} => @census_task,
    {"GET", "/v1/preview/related/:*/:*"} => @census_task,
    {"GET", "/v1/preview/tags/:*"} => @census_task,
    {"GET", "/v1/preview/tags/:*/:*"} => @census_task,

    # BarkparkWeb.RequestStatsController (1)

    # BarkparkWeb.SearchController (1) — the other 12 were paid down by
    # task-b1801ed5c86d2e2e (#14125, merged): search-settings/insights/
    # synonyms/interaction/correction/reindex/suggestions all gained manifest
    # commands. Only the /v1/data/local/search/:* alias remains a gap.
    {"GET", "/v1/data/local/search/:*"} => @census_task,

    # BarkparkWeb.SecretController (1)
    {"GET", "/v1/secrets/:*/audit"} => @census_task,

    # BarkparkWeb.SelfUpdateController (3)
    {"POST", "/v1/admin/rollback"} => @census_task,
    {"GET", "/v1/admin/self-update"} => @census_task,
    {"POST", "/v1/admin/self-update"} => @census_task,

    # BarkparkWeb.ShareController (3)
    {"GET", "/v1/shares/tokens"} => @census_task,
    {"POST", "/v1/shares/tokens"} => @census_task,
    {"DELETE", "/v1/shares/tokens/:*"} => @census_task,

    # BarkparkWeb.ShareLinkController (3)
    {"GET", "/v1/shares/links"} => @census_task,
    {"POST", "/v1/shares/links"} => @census_task,
    {"DELETE", "/v1/shares/links/:*"} => @census_task,

    # BarkparkWeb.SiteDeployController (2)
    {"GET", "/v1/admin/site-deploy"} => @census_task,
    {"POST", "/v1/admin/site-deploy"} => @census_task,

    # BarkparkWeb.StatusController (2)
    {"POST", "/v1/status/incidents"} => @census_task,
    {"POST", "/v1/status/incidents/:*/resolve"} => @census_task,

    # BarkparkWeb.StructureController (1)

    # BarkparkWeb.TasksController (4)
    {"GET", "/v1/tasks/:*/edges"} => @census_task,
    {"POST", "/v1/tasks/:*/papers"} => @census_task,
    {"POST", "/v1/tasks/edges"} => @census_task,

    # BarkparkWeb.V1.MediaController (0) — all 9 were paid down by
    # task-b1801ed5c86d2e2e (#14125, merged).

    # BarkparkWeb.WorkspaceController (3)
    {"DELETE", "/api/workspaces/:*"} => @census_task,
    {"GET", "/api/workspaces/:*/export"} => @census_task,
    {"POST", "/api/workspaces/:*/import"} => @census_task
  }

  # ── Shared derivations ────────────────────────────────────────────────────

  defp normalize_path(path) do
    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> _ -> ":*"
      "*" <> _ -> ":*"
      segment -> segment
    end)
    |> Enum.join("/")
  end

  # Collapse the workspace-scoped mirror onto the flat spelling of the same
  # capability. Applied to BOTH sides so a route and the command that serves it
  # meet regardless of which spelling each chose.
  # Matched AFTER normalize_path/1 has already collapsed `:workspace_slug` and
  # `:project_slug` to `:*`, so one literal covers both spellings.
  @scope_prefix "/w/:*/p/:*"

  defp strip_scope(@scope_prefix <> rest), do: rest
  defp strip_scope(path), do: path

  defp canonical_path(path), do: path |> normalize_path() |> strip_scope()

  # The namespaces the manifest speaks for. `/v1` is the current API; the
  # tenancy verbs (`workspace.ls`, `workspace.create`, `workspace.project-ls`,
  # `workspace.project-create`, `workspace.dataset-ls`) still name routes under
  # `/api/workspaces`, so walking `/v1` alone reported all five as dangling
  # verbs pointing at nothing when in fact their routes are mounted.
  #
  # The rest of `/api/*` — documents, schemas, query, playground — is the
  # deprecated surface (`sunset: Wed, 31 Dec 2026 23:59:59 GMT`) and stays out:
  # a `bp` verb for a route that 404s after the sunset is worse than no verb.
  @walked_prefixes ["/v1", "/api/workspaces"]

  defp walked_prefix?(path) do
    Enum.any?(@walked_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  # Every mounted controller route in a namespace the manifest speaks for.
  # LiveViews are excluded by `plug`, not by path, so a LiveView that moves
  # under a walked prefix stays excluded and a controller that moves under a
  # LiveView-ish path does not.
  defp walked_routes do
    BarkparkWeb.Router.__routes__()
    |> Enum.filter(fn route ->
      walked_prefix?(canonical_path(route.path)) and
        route.plug != Phoenix.LiveView.Plug and route.verb != :*
    end)
    # The flat route and its scoped mirror collapse onto one key; keep one
    # representative so the failure message names each capability once.
    |> Enum.uniq_by(&route_key/1)
  end

  defp route_key(route) do
    {route.verb |> Atom.to_string() |> String.upcase(), canonical_path(route.path)}
  end

  # The UN-projected superset: existence-hiding must not shrink what the guard
  # walks, or an `admin`-tier omission would hide behind the projection.
  defp manifest_commands do
    Capabilities.manifest("admin", project: false)["commands"]
  end

  defp command_key(command) do
    {String.upcase(command["http"]["method"]), canonical_path(command["http"]["path_template"])}
  end

  # ── The guard ─────────────────────────────────────────────────────────────

  describe "router ↔ capabilities manifest" do
    test "the comparison is not vacuous" do
      routes = walked_routes()
      commands = manifest_commands()

      assert length(routes) >= @min_walked_routes,
             """
             Only #{length(routes)} mounted controller routes were walked \
             (floor: #{@min_walked_routes}). A drift comparison over a collapsed \
             route set passes for free — it compares nothing. Either the router \
             BEAM is stale/partial, or __routes__/0 changed shape.
             """

      assert length(commands) >= @min_commands,
             """
             Only #{length(commands)} manifest commands were compared \
             (floor: #{@min_commands}). `Capabilities.manifest/2` folds the \
             registry through `safe_registry/2`, which fails SOFT to a default \
             — a registry that did not boot yields a near-empty manifest and \
             every drift assertion below would then pass vacuously.
             """
    end

    test "every walked route is a manifest command, a declared non-CLI surface, or a filed gap" do
      command_keys = MapSet.new(manifest_commands(), &command_key/1)

      unlisted =
        walked_routes()
        |> Enum.reject(fn route ->
          key = route_key(route)

          MapSet.member?(command_keys, key) or Map.has_key?(@not_a_cli_surface, key) or
            Map.has_key?(@served_by_a_builtin, key) or Map.has_key?(@filed_gaps, key)
        end)
        |> Enum.sort_by(& &1.path)

      assert unlisted == [],
             """
             #{length(unlisted)} mounted route(s) have NO capabilities-manifest command \
             and are in none of @not_a_cli_surface, @served_by_a_builtin, @filed_gaps.

             Each one is a live server capability with no `bp` verb and no
             OpenAPI operation — reachable by curl, invisible to every generated
             client. Declare it (core: `Capabilities.core_commands/0`; plugin:
             that plugin's `cli_commands/0`), or, if it structurally cannot be a
             CLI verb, add it to @not_a_cli_surface WITH the reason.

             Adding it to @filed_gaps requires filing the row FIRST and citing
             its id — that map is a tracked backlog, not somewhere to put a
             route you did not want to think about.

             #{format_routes(unlisted)}
             """
    end

    test "@filed_gaps only ever shrinks" do
      command_keys = MapSet.new(manifest_commands(), &command_key/1)
      route_keys = MapSet.new(walked_routes(), &route_key/1)

      now_declared =
        @filed_gaps
        |> Enum.filter(fn {key, _task} -> MapSet.member?(command_keys, key) end)
        |> Enum.sort()

      unmounted =
        @filed_gaps
        |> Enum.reject(fn {key, _task} -> MapSet.member?(route_keys, key) end)
        |> Enum.sort()

      assert now_declared == [],
             """
             #{length(now_declared)} @filed_gaps entr(y/ies) now HAVE a manifest command.

             Good — that is the backlog being paid down. Delete these rows from
             @filed_gaps in the same change that declared them, so the map keeps
             stating what is still missing rather than what once was.

             #{Enum.map_join(now_declared, "\n", fn {{m, p}, task} -> "  #{m} #{p}  (#{task})" end)}
             """

      assert unmounted == [],
             """
             #{length(unmounted)} @filed_gaps entr(y/ies) name a route that is no longer mounted.

             A gap for a route that no longer exists is not a gap. Delete the
             row and close its slice on the census task.

             #{Enum.map_join(unmounted, "\n", fn {{m, p}, task} -> "  #{m} #{p}  (#{task})" end)}
             """
    end

    test "no manifest command points at a route the router does not mount" do
      route_keys = MapSet.new(walked_routes(), &route_key/1)

      dangling =
        manifest_commands()
        |> Enum.reject(&MapSet.member?(route_keys, command_key(&1)))
        |> Enum.sort_by(& &1["id"])

      assert dangling == [],
             """
             #{length(dangling)} manifest command(s) advertise a path the router does not mount.

             `bp` renders the verb and the server 404s it. Plugin routes expand
             into the router at COMPILE time while the manifest is built at
             RUNTIME, so a stale router BEAM produces exactly this — force a
             router recompile before treating it as a declaration bug.

             #{format_commands(dangling)}
             """
    end

    test "every classified route (non-CLI surface or built-in) is still mounted" do
      route_keys = MapSet.new(walked_routes(), &route_key/1)

      stale =
        Map.merge(@not_a_cli_surface, @served_by_a_builtin)
        |> Enum.reject(fn {key, _reason} -> MapSet.member?(route_keys, key) end)
        |> Enum.sort()

      assert stale == [],
             """
             #{length(stale)} classification entr(y/ies) name a route that is no longer mounted.

             @not_a_cli_surface and @served_by_a_builtin classify LIVE routes;
             neither is a ratchet baseline. A stale entry is dead weight that
             would silently absolve a future route reusing the same method+path.

             #{Enum.map_join(stale, "\n", fn {{m, p}, reason} -> "  #{m} #{p}  — #{reason}" end)}
             """
    end
  end

  defp format_routes(routes) do
    Enum.map_join(routes, "\n", fn route ->
      "  #{String.pad_trailing(route.verb |> Atom.to_string() |> String.upcase(), 7)}" <>
        " #{String.pad_trailing(route.path, 56)} #{inspect(route.plug)}.#{route.plug_opts}"
    end)
  end

  defp format_commands(commands) do
    Enum.map_join(commands, "\n", fn command ->
      "  #{String.pad_trailing(command["id"], 32)}" <>
        " #{String.pad_trailing(command["http"]["method"], 7)}" <>
        " #{String.pad_trailing(command["http"]["path_template"], 56)}" <>
        " source=#{command["source"]}"
    end)
  end
end
