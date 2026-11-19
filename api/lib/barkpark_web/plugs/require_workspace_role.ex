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

  ## The role decides authority, the permission caps the action

  (task-2617573f7e9fea79.) For any method other than GET or HEAD the token's
  own permissions must also permit `:write` (`TenancyAuth.permits?/2`). A
  token holding only `read`, raised to an admin seat, used to write schemas,
  secrets and webhooks here while every flat write and every mutate refused
  it. docs/auth.md keeps permission and membership as separate axes. Reads
  stay role-only. Only API tokens reach this plug (`RequireToken` runs first,
  and the session arm of `RequireTokenOrMemberSession` skips it), so a login
  session is never judged on a token permission it does not carry.
  """

  import Plug.Conn
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @safe_methods ~w(GET HEAD)

  def init(opts), do: opts

  def call(conn, _opts) do
    with %{current_workspace: %{id: ws_id}, api_token: token} <- conn.assigns,
         {:role, true} <- {:role, TenancyAuth.workspace_admin?(token, ws_id)},
         {:permission, true} <- {:permission, permits_method?(conn.method, token)} do
      conn
    else
      {:permission, false} -> refuse(conn, :forbidden_token_write)
      _ -> refuse(conn, :forbidden_workspace_role)
    end
  end

  defp permits_method?(method, _token) when method in @safe_methods, do: true
  defp permits_method?(_method, token), do: TenancyAuth.permits?(token, :write)

  defp refuse(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope({:error, reason}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
