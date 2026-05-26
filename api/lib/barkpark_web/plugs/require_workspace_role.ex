defmodule BarkparkWeb.Plugs.RequireWorkspaceRole do
  @moduledoc """
  Scoped admin gate. Halts the conn with 403 unless the caller's MEMBERSHIP
  ROLE in `conn.assigns.current_workspace` is `owner` or `admin`.

  This is the core of the per-membership authz model (barkpark-23yi / the
  barkpark-fsko P0 fix): admin authority on a workspace is conferred by the
  GRANT recorded in `workspace_memberships.role`, NOT by the token's GLOBAL
  `permissions[]`. A `member` of workspace B — even one holding global
  `["read","write","admin"]` — can NO LONGER perform scoped admin ops (schema
  upsert, webhook/synonym CRUD) on B.

  Pipeline: runs in the `:scoped_admin` pipeline AFTER `ResolveWorkspace`
  (which sets `conn.assigns[:current_workspace]` and already membership-gates
  at `:read`) and `RequireToken` (which sets `conn.assigns[:api_token]`). When
  either assign is missing it fails closed → 403.

  The flat (Default-scoped) admin routes keep `:require_admin` (global-perm
  gate) — see the router. The seeded dev token is `owner`/`admin` of Default,
  so both halves keep working for it.
  """

  import Plug.Conn
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    with %{current_workspace: %{id: ws_id}, api_token: token} <- conn.assigns,
         true <- TenancyAuth.workspace_admin?(token, ws_id) do
      conn
    else
      _ ->
        env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

        conn
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()
    end
  end
end
