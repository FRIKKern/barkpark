defmodule BarkparkWeb.SsoRoutingController do
  @moduledoc """
  Pre-login SSO routing (era-w3-jit-domain): a user enters their email; if its
  domain is a VERIFIED org domain, we return that org's SSO start URL so the
  login page can redirect them to their IdP. Unverified domains never route.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Sso.Domains
  alias BarkparkWeb.ErrorResponse

  def route(conn, %{"email" => email}) when is_binary(email) do
    case Domains.route_for_email(email) do
      nil ->
        json(conn, %{"sso" => false})

      org ->
        json(conn, %{
          "sso" => true,
          "organization" => org.slug,
          "start_url" => "/v1/auth/oidc/#{org.slug}/start"
        })
    end
  end

  def route(conn, _),
    do: ErrorResponse.emit_custom(conn, 400, "malformed", "email is required")
end
