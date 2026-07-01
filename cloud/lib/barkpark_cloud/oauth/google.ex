defmodule BarkparkCloud.OAuth.Google do
  @moduledoc """
  The Google `BarkparkCloud.OAuth.Provider`. OAuth2 / OpenID Connect
  authorization-code flow against Google's endpoints.

  Stable subject id: the OIDC `sub` claim from the userinfo endpoint (Google's
  documented stable, unique-per-user id — NOT the email, which a user can
  change). That `sub` is the `provider_uid` the safe link is keyed on.

  Email: Google's userinfo returns `email` + `email_verified` inline, so no
  second call is needed (`emails_request/1` is NOT implemented). The email is
  only accepted as the identity email when `email_verified` is truthy.
  """
  @behaviour BarkparkCloud.OAuth.Provider

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @userinfo_url "https://openidconnect.googleapis.com/v1/userinfo"

  @scope "openid email profile"

  @impl true
  def authorize_url(config, state, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => @scope,
        "state" => state
      })

    @authorize_url <> "?" <> query
  end

  @impl true
  def token_request(config, code, redirect_uri) do
    body =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "client_secret" => config[:client_secret],
        "code" => code,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code"
      })

    %{
      method: :post,
      url: @token_url,
      headers: [
        {"Accept", "application/json"},
        {"Content-Type", "application/x-www-form-urlencoded"}
      ],
      body: body
    }
  end

  @impl true
  def userinfo_request(access_token) do
    %{
      method: :get,
      url: @userinfo_url,
      headers: [
        {"Authorization", "Bearer " <> access_token},
        {"Accept", "application/json"}
      ],
      body: ""
    }
  end

  @impl true
  def parse_identity(%{"sub" => sub} = body) when not is_nil(sub) do
    {:ok, %{uid: to_string(sub), email: verified_email(body)}}
  end

  def parse_identity(_), do: :error

  # Accept the email ONLY when Google asserts it verified. Google sends
  # email_verified as either a JSON boolean true or the string "true" depending
  # on the path — accept both. An unverified email is dropped to nil.
  defp verified_email(%{"email" => email, "email_verified" => verified})
       when is_binary(email) and verified in [true, "true"],
       do: email

  defp verified_email(_), do: nil
end
