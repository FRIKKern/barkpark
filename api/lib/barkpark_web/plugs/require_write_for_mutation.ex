defmodule BarkparkWeb.Plugs.RequireWriteForMutation do
  @moduledoc """
  Method-derived write gate for a bucket whose routes are declared elsewhere.

  `BarkparkWeb.Plugs.RequireWritePermission` gates a route the router names
  explicitly (`pipe_through([:api, :require_token, :require_write])`). That
  shape cannot gate the `:token_root` plugin bucket: its routes are contributed
  at compile time by `register_routes/1` in each plugin, so the router never
  writes them down and a new `{:post, …, auth: :token_root}` spec would arrive
  ungated by omission. This plug closes the bucket by METHOD instead of by
  route, so the default for anything mounted there is CLOSED.

  ## The failure mode it prevents (task-a87a3346b8ff736a)

  `POST /v1/tokens` mints `public-read` and `read` tokens only, and a
  workspace `member`'s personal access token caps at `read`
  (`Barkpark.Auth.@pat_allowed_member_permissions`). Yet the `:token_root`
  bucket rode `[:api, :require_token]` with nothing between the token check and
  the controller, so that weakest grantable credential could
  `POST /v1/tasks/:id/claim`, `/stamp`, `/close`, `/stage`, `/move`, `/pulse`,
  `POST /v1/tasks/claim`, `POST /v1/tickets/:id/answer|close` and
  `POST /v1/fleet/beat` — each confirmed live with an independent admin
  read-back. `acceptance_criteria[].met` is a one-way lock, so `stamp` in
  particular made that lock forgeable by a read-only token.

  The clamp for the tier BELOW this one already lived on the same pipeline:
  `Plugs.PublicRead` (mounted in `:require_token`) allows a `public-read` token
  exactly two GET routes and 403s everything else, which is why the defect
  stopped at the `read` tier. This plug is the `read`-tier half of the same
  clamp — deny the mutation, keep the read.

  ## Safe methods pass; everything else must satisfy `:write`

  `GET`, `HEAD` and `OPTIONS` are side-effect-free by HTTP contract and pass
  through untouched, so a `read` token keeps every `:token_root` READ it has
  today (`GET /v1/tasks`, `/tasks/ready`, `/tasks/:doc_id`, `/fleet/roster`, …).
  Every other method delegates verbatim to `RequireWritePermission` — one
  judgment, one 403 envelope, and the `share_writer` short-circuit and the
  account (`:current_user`) arm are inherited rather than re-derived. This
  module deliberately holds NO permission logic of its own; splitting the
  verdict in two is the drift that `RequireWritePermission.granted?/1` exists
  to prevent.

  ## It IS now mounted in the `:require_token` pipeline (task-a85afbbc0c4b1be3)

  The `:token_root` bucket was the first mount because one route blocked the
  pipeline-wide one: `DELETE /v1/auth/app-tokens/current` is the bearer revoking
  ITSELF, where possession is the authorization and an admin bearer is
  deliberately refused. Blanket-gating the pipeline would have stranded exactly
  the read-only tokens that most need self-revocation.

  Leaving the pipeline ungated cost five routes. The SAME census that produced
  the `:token_root` fix found ten mutating routes on plain
  `[:api, :require_token]` with no write gate at all, and five of them were
  reachable by a token minted `permissions: ["read"]`:

    * `POST /api/workspaces` — no permission check whatsoever; the caller
      becomes OWNER of the new workspace (confirmed live at 201).
    * `POST /api/workspaces/:workspace_slug/projects` — membership-gated, never
      permission-gated, so a read-only member creates projects.
    * `POST /v1/data/search/:dataset/reindex` — enqueues a full-corpus
      `IndexerWorker` rebuild. Unbounded work from the weakest credential.
    * `POST /v1/access` and `DELETE /v1/access/:id` — `Access.mint/2` is
      self-limiting (it refuses capabilities the principal does not hold) and
      `Access.revoke/2` is grantor-or-admin, so neither is an ESCALATION; both
      still let a read-only token write and retire grant rows.

  A per-route fix would have left the NEXT mutating route on this pipeline
  ungated by omission — which is precisely how this class was born. So the gate
  moved to the MOUNT and the one true exception became an EXPLICIT, reviewed
  list (`exempt_routes/0`) instead of an implicit hole. Default: CLOSED.

  ## The exempt list, and the two reasons a route earns a place on it

  It is the WHOLE of `/v1/auth`'s mutating surface and nothing else. Each entry
  is there for one of exactly two reasons.

  **SELF-SERVICE** — the mutation confers nothing the caller does not already
  hold, so possession of the bearer IS the authorization:

    * `DELETE /v1/auth/app-tokens/current` — the bearer revokes ITSELF
      (`AppTokenController.delete_current/2` refuses `admin` bearers outright).
      Gating it would leave a read-only token no way to retire itself.
    * `POST /v1/auth/login-tickets` — `Barkpark.Auth.mint_login_ticket/2` binds
      the ticket to the caller's OWN raw bearer, so consuming it yields a
      session carrying exactly the permissions the caller already presented.
      The one ESCALATING variant (`user_email`, which JIT-provisions an account)
      is gated on `admin` INSIDE `mint_login_ticket/2`, not by this plug.

  **ALREADY FENCED HARDER, AND THE FENCE HAS A SHAPE THIS GATE WOULD BREAK** —
  `POST /v1/auth/app-tokens`, `DELETE /v1/auth/app-tokens` and
  `DELETE /v1/auth/app-tokens/:id` each run
  `Auth.has_permission?(token, "admin")` in the controller. That is STRICTLY
  stronger than `permits?(token, :write)` (`~w(write admin)`), so this gate can
  add no security there — and it would subtract some. Those routes answer a
  non-admin bearer with the SAME generic 401 an INVALID bearer gets (the
  `mint_login_ticket` no-tier-oracle idiom, pinned by
  `app_token_revoke_test.exs`, `app_token_admin_revoke_test.exs`,
  `app_token_controller_test.exs` and `capabilities_manifest_test.exs`). A 403
  from this plug, arriving BEFORE the controller, would announce "your bearer is
  valid but under-permissioned" — precisely the tier oracle those routes were
  built to withhold. Deferring to the stronger, quieter gate is the correct
  reading of default-closed here, not an exception to it.
  """

  alias BarkparkWeb.Plugs.RequireWritePermission

  # RFC 9110 safe methods. TRACE is not routed by Phoenix; OPTIONS is listed so
  # a CORS preflight is never answered with a 403 from an auth gate.
  @safe_methods ~w(GET HEAD OPTIONS)

  @doc """
  The methods that pass through without a write check.

  Public so the router census test asserts against THIS list rather than
  re-typing it — a test that hard-codes the set cannot notice the set changing.
  """
  @spec safe_methods() :: [String.t()]
  def safe_methods, do: @safe_methods

  # The exemptions, as `{METHOD, path_info pattern}`. See the moduledoc for the
  # argument behind each one.
  #
  # Matched on `conn.path_info` — a SEGMENT LIST — not on `request_path`. A
  # string compare would let a `script_name` prefix, a trailing slash or a
  # percent-encoded separator make a GATED route read as exempt; a segment list
  # is what the router itself matched on, so there is nothing left to normalize.
  # `:_` matches exactly ONE segment and never zero or many, so the `:id` entry
  # cannot widen into a subtree.
  @exempt_routes [
    # SELF-SERVICE
    {"DELETE", ["v1", "auth", "app-tokens", "current"]},
    {"POST", ["v1", "auth", "login-tickets"]},
    # ALREADY FENCED HARDER (controller `admin` check + no-tier-oracle 401)
    {"POST", ["v1", "auth", "app-tokens"]},
    {"DELETE", ["v1", "auth", "app-tokens"]},
    {"DELETE", ["v1", "auth", "app-tokens", :_]}
  ]

  @doc """
  The `{method, path_info pattern}` pairs this gate lets through unchecked.

  Public for the same reason `safe_methods/0` is: the census test asserts
  against THIS list, so GROWING the hole is visible in a diff the test reads
  rather than in one it re-types. Adding an entry is a deliberate, reviewed act
  and must carry one of the two arguments in the moduledoc — self-service, or
  fenced harder in the controller by a check this gate would only weaken.
  """
  @spec exempt_routes() :: [{String.t(), [String.t() | :_]}]
  def exempt_routes, do: @exempt_routes

  @doc """
  Is `{method, path_info}` on the exempt list?

  Public so a caller can ask the question without re-implementing the `:_`
  segment match — two implementations of one predicate is the drift this module
  exists to avoid.
  """
  @spec exempt?(String.t(), [String.t()]) :: boolean()
  def exempt?(method, path_info) when is_binary(method) and is_list(path_info) do
    Enum.any?(@exempt_routes, fn {m, pattern} ->
      m == method and segments_match?(pattern, path_info)
    end)
  end

  defp segments_match?([], []), do: true
  defp segments_match?([:_ | pat], [_ | path]), do: segments_match?(pat, path)
  defp segments_match?([seg | pat], [seg | path]), do: segments_match?(pat, path)
  defp segments_match?(_, _), do: false

  def init(opts), do: RequireWritePermission.init(opts)

  def call(%Plug.Conn{method: method} = conn, _opts) when method in @safe_methods, do: conn

  def call(%Plug.Conn{method: method, path_info: path_info} = conn, opts) do
    if exempt?(method, path_info) do
      conn
    else
      RequireWritePermission.call(conn, opts)
    end
  end
end
