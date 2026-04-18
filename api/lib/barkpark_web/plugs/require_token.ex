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
        env = Barkpark.Content.Errors.to_envelope({:error, :unauthorized}, conn)

        conn
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
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
        env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

        conn
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()
    end
  end
end
