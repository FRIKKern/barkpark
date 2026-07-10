defmodule BarkparkWeb.Plugs.OptionalUserSession do
  @moduledoc """
  Soft sibling of `RequireUserSession`: resolve a USER login session into
  `:current_user` WITHOUT 401ing on absence, so a downstream owned-token
  resolver (`ResolveTokenOwner`) can supply the principal instead.

  Mirrors `RequireUserSession`'s credential handling EXACTLY, minus the
  no-session 401:

    * `Authorization: Bearer <session-token>` — API/JS clients (CSRF-exempt,
      bearers carry no cookies);
    * the signed `user_session` cookie — first-party browser. On a MUTATING
      method the cookie branch STILL enforces CSRF (`x-requested-with`) and
      halts 403 without it — the SAME defense `RequireUserSession` applies, so
      swapping this plug in on `/v1/access/claim` introduces no CSRF regression.

  Bearer wins; the cookie branch runs ONLY when no bearer is present (so an
  api_token bearer never trips the cookie CSRF check). A request with neither
  credential passes through untouched — never halted. Requires `:fetch_session`
  upstream.
  """
  import Plug.Conn

  alias Barkpark.Accounts
  alias Barkpark.Content.CallerContext

  @safe_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer(conn) do
      {:ok, raw} ->
        assign_if_valid(conn, raw, :bearer)

      :none ->
        case get_session(conn, "user_session") do
          raw when is_binary(raw) and raw != "" -> assign_if_valid(conn, raw, :cookie)
          _ -> conn
        end
    end
  end

  defp assign_if_valid(conn, raw, source) do
    case Accounts.verify_user_session(String.trim(raw)) do
      {%Accounts.User{} = user, session} ->
        conn
        |> maybe_require_csrf(source)
        |> assign_user(user, session)

      # Not a login session (e.g. an api_token bearer). Leave the conn untouched
      # so OptionalToken's :api_token + ResolveTokenOwner can carry the identity.
      nil ->
        conn
    end
  end

  defp assign_user(%Plug.Conn{halted: true} = conn, _user, _session), do: conn

  defp assign_user(conn, user, session) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_user_session, session)
    |> assign(:caller_context, CallerContext.from_user(user.id))
  end

  defp maybe_require_csrf(conn, :bearer), do: conn

  defp maybe_require_csrf(conn, :cookie) do
    if conn.method in @safe_methods or requested_with?(conn) do
      conn
    else
      # One shared emitter → the 403 carries request_id (+ hint); mirrors
      # RequireUserSession's csrf_required exactly.
      BarkparkWeb.ErrorResponse.emit_custom(
        conn,
        403,
        "csrf_required",
        "missing x-requested-with header"
      )
    end
  end

  defp requested_with?(conn) do
    case get_req_header(conn, "x-requested-with") do
      [v | _] when is_binary(v) and v != "" -> true
      _ -> false
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> {:ok, raw}
      _ -> :none
    end
  end
end
