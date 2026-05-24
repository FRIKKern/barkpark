defmodule BarkparkWeb.Plugs.RequireBearerOrSessionToken do
  @moduledoc """
  Requires a valid API token from either:

    * `Authorization: Bearer …` — API clients and Web Components that
      receive `data-token` from LiveView, or
    * `session["api_token"]` — browser Studio after `POST /login`.

  Requires `:fetch_session` upstream. Used by `/media/upload` and
  `/media/:id` DELETE so same-origin browser uploads work with the
  session cookie alone.
  """

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> assign_from_bearer()
    |> case do
      {:ok, conn} ->
        conn

      {:error, conn} ->
        conn
        |> assign_from_session()
        |> case do
          {:ok, conn} -> conn
          {:error, conn} -> unauthorized(conn)
        end
    end
  end

  defp assign_from_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] ->
        verify_and_assign(conn, raw)

      _ ->
        {:error, conn}
    end
  end

  defp assign_from_session(conn) do
    case get_session(conn, "api_token") do
      raw when is_binary(raw) and raw != "" ->
        verify_and_assign(conn, raw)

      _ ->
        {:error, conn}
    end
  end

  defp verify_and_assign(conn, raw) do
    case Auth.verify_token(String.trim(raw)) do
      {:ok, token} -> {:ok, assign(conn, :api_token, token)}
      _ -> {:error, conn}
    end
  end

  defp unauthorized(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :unauthorized}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
