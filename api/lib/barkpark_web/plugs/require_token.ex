defmodule BarkparkWeb.Plugs.RequireToken do
  @moduledoc "Plug that verifies Bearer token and assigns token to conn."

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Auth.verify_token(raw_token) do
      assign(conn, :api_token, token)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end

defmodule BarkparkWeb.Plugs.RequireAdmin do
  @moduledoc "Plug that requires admin permission on the token."

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with %{api_token: token} <- conn.assigns,
         true <- Auth.has_permission?(token, "admin") do
      conn
    else
      _ ->
        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{error: "forbidden: admin required"})
        |> halt()
    end
  end
end
