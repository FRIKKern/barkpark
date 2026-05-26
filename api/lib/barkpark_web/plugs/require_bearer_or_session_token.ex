defmodule BarkparkWeb.Plugs.RequireBearerOrSessionToken do
  @moduledoc """
  Requires a valid API token from either:

    * `Authorization: Bearer …` — API clients and Web Components that
      receive `data-token` from LiveView, or
    * `session["api_token"]` — browser Studio after `POST /login`.

  Requires `:fetch_session` upstream. Used by `/media/upload` and
  `/media/:id` DELETE so same-origin browser uploads work with the
  session cookie alone.

  ## CSRF on the cookie branch (Task barkpark-yjcg)

  The cookie/session branch is a CSRF surface: a logged-in user's session
  cookie alone would otherwise authorize destructive POST/DELETE driven by
  a cross-site `<form>` or `<img>`. SameSite=Lax + the DatasetCors allowlist
  mitigate it, but defense-in-depth was missing. So the session branch now
  additionally requires an `x-requested-with` header. That header cannot be
  set by a simple cross-site form/image submit, and a cross-origin `fetch`
  that sets it triggers a CORS preflight the allowlist blocks — so only
  same-origin first-party JS can satisfy it.

  The Studio uploaders (`bp-asset-explorer`, `bp-media-picker`) authenticate
  with `Authorization: Bearer <data-token>` — the raw token LiveAuth derives
  from `session["api_token"]` — so they take the bearer branch and never hit
  this check. Bearer (API/external) callers are unaffected: APIs don't use
  cookies and aren't a CSRF target.
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
          {:ok, conn} -> require_csrf_header(conn)
          {:error, conn} -> unauthorized(conn)
        end
    end
  end

  # CSRF guard for the cookie branch only. Bearer callers return above and
  # never reach here. A same-origin custom header proves the request came
  # from first-party JS rather than a forged cross-site form/img submit.
  defp require_csrf_header(conn) do
    case get_req_header(conn, "x-requested-with") do
      [val | _] when is_binary(val) and val != "" -> conn
      _ -> csrf_required(conn)
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
    halt_with(conn, {:error, :unauthorized})
  end

  defp csrf_required(conn) do
    halt_with(conn, {:error, :csrf_required})
  end

  defp halt_with(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope(reason, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
