defmodule BarkparkCloud.OAuthStub do
  @moduledoc """
  A canned OAuth IdP transport for HERMETIC, €0 tests — the OAuth twin of the
  Billing StubGateway. `request/1` has the SAME `%{method, url, headers, body}` →
  `{:ok, %{status, body}}` shape `BarkparkCloud.Billing.HttpClient.request/1` has,
  so wiring it as `OAuth`'s `http_client` makes the whole token-exchange +
  userinfo path run with ZERO network calls.

  Default responses model a verified GitHub + Google user. A test can override
  any leg via `put_response/2` (stored in the PROCESS DICTIONARY, so it is
  per-test and safe under `async: true` — Plug.Test runs the router in the test
  process). For example, to model GitHub withholding a verified primary email:

      OAuthStub.put_response(:github_emails,
        [%{"email" => "x@example.com", "primary" => true, "verified" => false}])
  """

  @doc "Override one canned response for the current test process."
  def put_response(key, value), do: Process.put({__MODULE__, key}, value)

  @doc false
  def request(%{url: url}) do
    cond do
      # GitHub token exchange. Overridable via put_response(:github_token, …) so a
      # test can model a token-exchange failure (e.g. an empty body with no
      # access_token → OAuth.fetch_identity returns {:error, :token_exchange_failed}).
      String.contains?(url, "github.com/login/oauth/access_token") ->
        json(
          response(:github_token, %{
            "access_token" => "gh_test_access_token",
            "token_type" => "bearer"
          })
        )

      # GitHub verified-emails — MUST be checked before the bare /user match
      # below (the emails URL contains "/user" too).
      String.contains?(url, "api.github.com/user/emails") ->
        json(response(:github_emails, default_github_emails()))

      # GitHub profile (the stable numeric id).
      String.contains?(url, "api.github.com/user") ->
        json(response(:github_user, %{"id" => 4_242, "login" => "octocat"}))

      # Google token exchange.
      String.contains?(url, "oauth2.googleapis.com/token") ->
        json(%{"access_token" => "g_test_access_token", "token_type" => "Bearer"})

      # Google OIDC userinfo (the stable `sub`).
      String.contains?(url, "openidconnect.googleapis.com/v1/userinfo") ->
        json(
          response(:google_userinfo, %{
            "sub" => "google-sub-default",
            "email" => "googler@example.com",
            "email_verified" => true
          })
        )

      true ->
        {:ok, %{status: 404, body: "{}"}}
    end
  end

  defp response(key, default), do: Process.get({__MODULE__, key}, default)

  defp default_github_emails do
    [
      %{"email" => "secondary@example.com", "primary" => false, "verified" => true},
      %{"email" => "octocat@example.com", "primary" => true, "verified" => true}
    ]
  end

  defp json(body), do: {:ok, %{status: 200, body: Jason.encode!(body)}}
end
