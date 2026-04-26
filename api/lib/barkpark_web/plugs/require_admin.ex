defmodule BarkparkWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts the conn with 403 unless the caller's token has the `admin` permission.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.RequireToken` so
  `conn.assigns[:api_token]` is set.
  """

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with %{api_token: token} <- conn.assigns,
         true <- Auth.has_permission?(token, "admin") do
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
