defmodule BarkparkWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts the conn with 403 unless the caller's token has the `admin` permission
  AND, since OWNER RULING 2026-10-03 #2, its holder still has admin authority
  in the workspace the request acts on (the D22 seat rule on flat admin routes):

    * a WORKSPACE-BOUND token (`workspace_id` set): `Tenancy.Auth.authorize/3`
      `:admin` on that workspace — its own seat's role must confer admin, and
      for a user-owned token its owner's seat must too. Demoting or removing
      the seat refuses the token at once; nothing has to be revoked.
    * a WORKSPACE-LESS USER-OWNED token (`owner_user_id` set): the owner's
      admin authority in the workspace the request acts on
      (`conn.assigns.current_workspace`, else Default). A read seat on Default
      no longer reaches Default's admin routes (task-6132833921b7dc36 RQ3).
    * a WORKSPACE-LESS MACHINE token (no owner): unchanged — the instance
      credential (Cloud's, seeds, operators). Its reach on instance-global
      routes is narrowed by `RequirePlatformOperator`, not here.

  A refusal is the same 403 `forbidden` envelope with an additive
  `required: "admin_seat"`, so a caller can tell "your token lacks admin" from
  "your seat no longer allows it".

  Pipeline: must run AFTER `BarkparkWeb.Plugs.RequireToken` so
  `conn.assigns[:api_token]` is set.
  """

  import Plug.Conn

  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    with %{api_token: token} <- conn.assigns,
         true <- Auth.has_permission?(token, "admin") do
      if admin_seat?(conn, token), do: conn, else: deny(conn, %{required: "admin_seat"})
    else
      _ -> deny(conn, %{})
    end
  end

  @doc false
  @spec admin_seat?(Plug.Conn.t(), term()) :: boolean()
  def admin_seat?(_conn, %ApiToken{workspace_id: ws_id} = token) when is_binary(ws_id),
    do: TenancyAuth.authorize(token, ws_id, :admin) == :ok

  def admin_seat?(conn, %ApiToken{owner_user_id: uid}) when is_binary(uid) do
    case acting_workspace_id(conn) do
      ws_id when is_binary(ws_id) -> TenancyAuth.authorize(%User{id: uid}, ws_id, :admin) == :ok
      _ -> false
    end
  end

  def admin_seat?(_conn, %ApiToken{}), do: true
  def admin_seat?(_conn, _token), do: false

  defp acting_workspace_id(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} when is_binary(id) ->
        id

      _ ->
        case Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end
    end
  end

  defp deny(conn, extra) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: env |> Map.delete(:status) |> Map.merge(extra)})
    |> halt()
  end
end
