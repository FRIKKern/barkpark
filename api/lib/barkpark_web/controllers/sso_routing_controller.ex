defmodule BarkparkWeb.SsoRoutingController do
  @moduledoc """
  Pre-login SSO routing (era-w3-jit-domain, task-9963609c3ef5276f): a user
  enters their email; if its domain is a VERIFIED org domain and that org has an
  active OIDC or SAML connection, we return that org's start URL so the login
  page can redirect them to their IdP. Unverified domains never route, and
  neither does an org with no active connection, whose start URL would 404.

  `protocol` is `"oidc"` or `"saml"`. `sso_only` is true when the org allows
  SSO and not password sign-in, so the login page hides the password field.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Sso.LoginOptions
  alias BarkparkWeb.ErrorResponse

  def route(conn, %{"email" => email}) when is_binary(email) do
    case LoginOptions.route_for_email(email) do
      nil ->
        json(conn, %{"sso" => false})

      route ->
        json(conn, %{
          "sso" => true,
          "organization" => route.org_slug,
          "protocol" => Atom.to_string(route.protocol),
          "start_url" => route.start_path,
          "sso_only" => route.sso_only
        })
    end
  end

  def route(conn, _),
    do: ErrorResponse.emit_custom(conn, 400, "malformed", "email is required")
end
