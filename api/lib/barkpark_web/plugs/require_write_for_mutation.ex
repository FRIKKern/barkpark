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

  ## Why this is NOT mounted in the `:require_token` pipeline

  `:require_token` also carries routes where a mutating method on a read token
  is CORRECT — `DELETE /v1/auth/app-tokens/current` is the bearer revoking
  ITSELF, where possession is the authorization and an admin bearer is
  deliberately refused. Blanket-gating the pipeline would break self-revocation
  for exactly the read-only tokens that most need it. The gate therefore mounts
  at the `:token_root` bucket, and
  `test/barkpark_web/token_root_write_gate_test.exs` carries a census of every
  OTHER mutating route on `:require_token` so the remainder is an explicit,
  reviewed list instead of an unknown.
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

  def init(opts), do: RequireWritePermission.init(opts)

  def call(%Plug.Conn{method: method} = conn, _opts) when method in @safe_methods, do: conn

  def call(%Plug.Conn{} = conn, opts), do: RequireWritePermission.call(conn, opts)
end
