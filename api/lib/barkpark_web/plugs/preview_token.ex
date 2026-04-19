defmodule BarkparkWeb.Plugs.PreviewToken do
  @moduledoc """
  Verifies a short-lived preview JWT from `Authorization: Preview <jwt>`
  or `?preview_token=<jwt>`. Forces perspective to drafts on success.
  """

  import Plug.Conn

  alias Barkpark.Content.Errors
  alias Barkpark.PreviewToken

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = Application.get_env(:barkpark, :preview, [])[:secret]

    with raw when is_binary(raw) <- extract_token(conn),
         true <- is_binary(secret) and byte_size(secret) > 0,
         {:ok, claims} <- PreviewToken.verify(raw, secret),
         {:ok, _} <- PreviewToken.record_jti(claims) do
      conn
      |> assign(:preview_claims, claims)
      |> assign(:forced_perspective, "drafts")
    else
      {:error, :already_used} -> deny(conn, :replay)
      _ -> deny(conn, :unauthorized)
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Preview " <> jwt] ->
        jwt

      _ ->
        conn = fetch_query_params(conn)
        conn.query_params["preview_token"]
    end
  end

  defp deny(conn, reason) do
    env = Errors.to_envelope({:error, reason}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
