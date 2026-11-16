defmodule BarkparkWeb.EcosystemPanelFrameController do
  @moduledoc """
  `GET /w/:ws/p/:proj/studio/ecosystem-panel/frame` — the stored ecosystem
  panel page, served raw for the Studio shell's iframe
  (task-d76b1c09fe303401). Mounted by `Barkpark.Plugins.EcosystemPanel` on the
  `:admin` bucket, so the scoped copy rides `:scoped_browser`.

  ## Who may read

  A plain controller gets no `on_mount`, so the check is here, on every
  request: `Tenancy.Auth.workspace_admin?/2` must be true for the RESOLVED URL
  workspace (`conn.assigns.current_workspace`), for either

    * the signed-in user (`conn.assigns.current_user`), or
    * the token held in the browser session (`api_token_session`, or the
      legacy raw `api_token`), re-read from the session here.

  That is the bar `LiveAuth :scoped_admin` sets for the shell, minus its
  dev-root arm (a global-permission grant). A Bearer api token and the dev
  `:dev_browser_token` fallback that `OptionalSessionToken` may assign are not
  consulted. Global `admin` permission without an owner or admin role in the
  URL workspace is not enough. A signed-in user whose organization requires
  MFA and who has no factor is refused, as `LiveAuth :require_org_mfa` refuses
  the shell.

  `:scoped_browser` lets an anonymous visitor resolve the default workspace
  while `:studio_demo` is on. That visitor holds no user and no session token,
  so the frame still refuses.

  ## Answers

    * 200 — the stored HTML, with the sandbox CSP below.
    * 302 to `/login` — signed out.
    * 403 — signed in, not an admin of the URL workspace.
    * 404 "No snapshot" — an admin, but the workspace has no row.
    * 404 — the flat `/studio/ecosystem-panel/frame` copy (no workspace in the
      path), for everyone.

  No refusal carries snapshot bytes. `?v=<sha>` is a cache-buster for the
  shell's iframe; it never selects a row.

  ## Headers on the 200

  The `sandbox` directive is in the header, so even the frame URL opened
  top-level runs with an opaque origin: no cookies, no storage, no
  same-origin requests, no forms, no network but the two font hosts. The
  pipeline's Studio CSP (`BrowserCsp`, nonce and all) is REPLACED, not
  appended to; nothing after the controller adds a policy.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.EcosystemPanel
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @csp Enum.join(
         [
           "sandbox allow-scripts",
           "default-src 'none'",
           "script-src 'unsafe-inline'",
           "style-src 'unsafe-inline' https://fonts.googleapis.com",
           "font-src https://fonts.gstatic.com",
           "img-src data:",
           "connect-src 'none'",
           "form-action 'none'",
           "base-uri 'none'",
           "frame-ancestors 'self'"
         ],
         "; "
       )

  @doc "The Content-Security-Policy every 200 from the frame carries."
  @spec csp() :: String.t()
  def csp, do: @csp

  def show(%Plug.Conn{path_params: %{"workspace_slug" => _}} = conn, _params) do
    case authorize(conn) do
      {:ok, workspace_id} -> serve(conn, EcosystemPanel.get(workspace_id))
      :signed_out -> to_login(conn)
      :forbidden -> plain(conn, 403, "Admin access required.")
    end
  end

  # No workspace in the path: the flat mount. Nothing is read.
  def show(conn, _params), do: plain(conn, 404, "Not found.")

  defp authorize(conn) do
    user = conn.assigns[:current_user]
    token = session_token(conn)

    case conn.assigns[:current_workspace] do
      _ when is_nil(user) and is_nil(token) ->
        :signed_out

      %{id: workspace_id} when is_binary(workspace_id) ->
        if not mfa_blocked?(conn, user) and
             (admin?(user, workspace_id) or admin?(token, workspace_id)),
           do: {:ok, workspace_id},
           else: :forbidden

      _ ->
        :forbidden
    end
  end

  defp session_token(conn) do
    case Auth.resolve_session_credential(
           get_session(conn, "api_token_session"),
           get_session(conn, "api_token")
         ) do
      {:ok, token, _raw} -> token
      :error -> nil
    end
  end

  defp admin?(nil, _workspace_id), do: false
  defp admin?(principal, workspace_id), do: TenancyAuth.workspace_admin?(principal, workspace_id)

  # The `LiveAuth :require_org_mfa` rule: a session born from the IdP's MFA
  # stands in for a factor; otherwise a governed user needs one enrolled.
  defp mfa_blocked?(_conn, nil), do: false

  defp mfa_blocked?(conn, %User{} = user) do
    case conn.assigns[:current_user_session] do
      %{idp_mfa: true} -> false
      _ -> BarkparkWeb.SessionIssuer.org_mfa_enrolment_blocked?(user)
    end
  end

  defp serve(conn, %{html: html}) when is_binary(html) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/html", "utf-8")
    |> send_resp(200, html)
  end

  defp serve(conn, nil), do: plain(conn, 404, "No snapshot yet.")

  defp to_login(conn) do
    path = conn.request_path
    redirect(conn, to: "/login?return_to=" <> URI.encode_www_form(path))
  end

  defp plain(conn, status, text) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(status, text)
  end
end
