defmodule BarkparkCloud.OAuth.Github do
  @moduledoc """
  The GitHub `BarkparkCloud.OAuth.Provider`. Authorization-code flow against
  `github.com` / `api.github.com`.

  Stable subject id: GitHub's numeric `id` (NOT the login, which a user can
  rename). That `id` is the `provider_uid` the safe `(provider, provider_uid)`
  link is keyed on.

  Email: `GET /user` omits a private email, so the verified primary is read from
  the second call `GET /user/emails` (`emails_request/1`). Only a `verified:
  true` primary is accepted as the identity email; otherwise the identity email
  is `nil` and the link stands on the uid alone.
  """
  @behaviour BarkparkCloud.OAuth.Provider

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"
  @user_url "https://api.github.com/user"
  @emails_url "https://api.github.com/user/emails"

  # read:user for the profile (the numeric id), user:email for the verified
  # primary via /user/emails. No repo/admin scope — sign-in only.
  @scope "read:user user:email"

  @impl true
  def authorize_url(config, state, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "redirect_uri" => redirect_uri,
        "scope" => @scope,
        "state" => state,
        "allow_signup" => "true"
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
        "redirect_uri" => redirect_uri
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
      url: @user_url,
      headers: bearer_headers(access_token),
      body: ""
    }
  end

  @impl true
  def emails_request(access_token) do
    %{
      method: :get,
      url: @emails_url,
      headers: bearer_headers(access_token),
      body: ""
    }
  end

  @impl true
  def parse_identity(%{"id" => id} = body) when not is_nil(id) do
    {:ok, %{uid: to_string(id), email: verified_primary_email(body["emails"])}}
  end

  def parse_identity(_), do: :error

  # GitHub's Accept header is its API-version selector; a User-Agent is REQUIRED
  # by api.github.com or it 403s. The token is sent as a Bearer.
  defp bearer_headers(access_token) do
    [
      {"Authorization", "Bearer " <> access_token},
      {"Accept", "application/vnd.github+json"},
      {"User-Agent", "barkpark-cloud"}
    ]
  end

  # Find the verified primary from GET /user/emails. Accept ONLY a primary that
  # is verified:true — an unverified or non-primary address is never trusted as
  # the linkable email (it would let an attacker pre-claim a victim's email).
  # Returns nil when no verified primary is present.
  defp verified_primary_email(emails) when is_list(emails) do
    Enum.find_value(emails, fn
      %{"email" => email, "primary" => true, "verified" => true} -> email
      _ -> nil
    end)
  end

  defp verified_primary_email(_), do: nil
end
