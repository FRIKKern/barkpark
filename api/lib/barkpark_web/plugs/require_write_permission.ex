defmodule BarkparkWeb.Plugs.RequireWritePermission do
  @moduledoc """
  Write-gate for the mutation path. Halts the conn with HTTP 403 unless the
  caller's token carries a write-capable permission ("write" or "admin"),
  BEFORE the request reaches the controller and `Content.apply_mutations`.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.RequireToken` so
  `conn.assigns[:api_token]` is set. Permission satisfaction is delegated to
  `Barkpark.Tenancy.Auth.permits?/2` (the `:write` action ← "write"/"admin").

  This is the enforcement-first slice of the tenancy retrofit. Workspace-scoped
  authorization (`Barkpark.Tenancy.Auth.authorize/3`) is wired at the route
  level by the sibling ROUTER task once `/w/:workspace` resolution lands.
  """

  import Plug.Conn
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    # P5: a scoped-share edit token already proved its right to write THIS scope
    # in RequireShareEditToken (opaque perm + live :edit-share + byte-exact
    # scope). It deliberately holds no global :write perm, so let `share_writer`
    # short-circuit the permits?/2 check. Set ONLY by RequireShareEditToken.
    if conn.assigns[:share_writer] == true do
      conn
    else
      with %{api_token: token} <- conn.assigns,
           true <- TenancyAuth.permits?(token, :write) do
        conn
      else
        _ ->
          forbidden(conn)
      end
    end
  end

  defp forbidden(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
