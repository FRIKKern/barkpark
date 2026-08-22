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
          {:ok, conn} ->
            require_csrf_header(conn)

          {:error, conn} ->
            case account_session?(conn) do
              true -> require_csrf_header(conn)
              false -> unauthorized(conn)
            end
        end
    end
  end

  # ── the ACCOUNT arm (gfr-w1-account-session-bearer-gap) ───────────────────
  #
  # An account (`user_session`) principal holds NO api_token: no account/SSO
  # login writes `session["api_token"]`, so a legitimate workspace member was
  # refused here even though `ResolveWorkspace` already admits them. Nobody
  # gained access from the gap — a member was BLOCKED by it.
  #
  # It mints nothing. `LiveAuth` still renders `data-token=""` for an account
  # session and that is the CORRECT end state: handing a web component a raw
  # bearer would put a live credential in every SSO user's HTML, at all four
  # `data-token={@api_token_raw}` sites. The components use the cookie branch
  # instead (see the `x-requested-with` fallback in the media JS).
  #
  # SCOPED PIPELINES ONLY, and that is structural rather than a scope cut. On
  # `:scoped_media_mutate` the workspace is already resolved FROM THE URL by
  # `ResolveWorkspace`, which runs before this plug. The FLAT `:media_mutate`
  # pipeline derives its workspace from the token via `DeriveWorkspaceFromToken`
  # — a token carries ONE workspace_id, a user carries N memberships, and a flat
  # path carries no workspace at all, so there is no non-guessing answer there.
  # Guessing (say, the first membership) is the shape that produced the
  # stamps-to-Default defect D15/D16 paid off. A flat account-session media
  # write therefore still refuses, deliberately: it needs an explicit workspace
  # on the request, which is new surface, not a missing arm here.
  #
  # This assigns NO `:api_token`. Downstream plugs that need a principal read
  # `:current_user` — see `RequireWritePermission`, which authorises an account
  # principal on its MEMBERSHIP ROLE via `Tenancy.Auth.authorize/3`.
  # SCOPED-ONLY, by two independent facts. Stated separately because only one of
  # them is doing the work today, and conflating them would overstate this guard.
  #
  #   1. WHAT ACTUALLY PROTECTS FLAT TODAY: `OptionalSessionToken` is NOT on the
  #      `:media_mutate` pipeline, so `:current_user` is never assigned there and
  #      this arm cannot fire on a flat request at all. Measured: deleting the
  #      `:current_workspace` clause below leaves the flat refusal green.
  #
  #   2. WHAT THE `:current_workspace` CLAUSE ADDS: defense-in-depth for the day
  #      someone adds `OptionalSessionToken` to the flat pipeline — which would
  #      look like a harmless improvement. On `:scoped_media_mutate`,
  #      `ResolveWorkspace` runs BEFORE this plug, so the URL-derived workspace
  #      is present. On flat, `DeriveWorkspaceFromToken` and `AssignDefaultScope`
  #      both run AFTER, so it is nil and the arm declines even if a
  #      `:current_user` appeared.
  #
  # Without (2), a flat account write would be stamped to and metered against the
  # singleton Default workspace — the stamps-to-Default defect D15/D16 paid off.
  # It carries NO failing test precisely because (1) makes it redundant today; it
  # is a tripwire for a future pipeline edit, not a proven-live control.
  defp account_session?(conn) do
    match?(%Barkpark.Accounts.User{}, conn.assigns[:current_user]) and
      match?(%{id: id} when is_binary(id), conn.assigns[:current_workspace])
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
    BarkparkWeb.ErrorResponse.emit(conn, reason)
  end
end
