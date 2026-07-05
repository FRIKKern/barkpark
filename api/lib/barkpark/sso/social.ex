defmodule Barkpark.Sso.Social do
  @moduledoc """
  Social login (era-w2-social-oauth) for Google, GitHub, and Microsoft, unified
  under one OAuth2 + userinfo flow:

    1. `authorize_url/3` → redirect to the provider (state, scope).
    2. `handle_callback/3` → exchange the code for an access token, fetch the
       userinfo/user endpoint for the email + external id, then find-or-LINK the
       Barkpark User: an existing `(provider, external_id)` re-logs the same
       account; otherwise the email find-or-creates a User (never a duplicate of
       an existing email account) and links the social identity.

  App-level client credentials live in `social_providers` (`client_secret`
  encrypted). The endpoints are well-known per provider. Outbound calls go
  through `Barkpark.Sso.Social.HTTP` so tests run against a mock provider.
  """
  import Ecto.Query, warn: false

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Accounts.User
  alias Barkpark.Sso.Social.HTTP
  alias Barkpark.Sso.{SocialIdentity, SocialProvider}

  # Well-known endpoints + where the email / stable id live in userinfo.
  @endpoints %{
    "google" => %{
      authorize: "https://accounts.google.com/o/oauth2/v2/auth",
      token: "https://oauth2.googleapis.com/token",
      userinfo: "https://openidconnect.googleapis.com/v1/userinfo",
      scope: "openid email",
      email_key: "email",
      id_key: "sub"
    },
    "github" => %{
      authorize: "https://github.com/login/oauth/authorize",
      token: "https://github.com/login/oauth/access_token",
      userinfo: "https://api.github.com/user",
      scope: "user:email",
      email_key: "email",
      id_key: "id"
    },
    "microsoft" => %{
      authorize: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      userinfo: "https://graph.microsoft.com/oidc/userinfo",
      scope: "openid email",
      email_key: "email",
      id_key: "sub"
    }
  }

  @doc "Enable (upsert) a provider's app-level OAuth credentials."
  @spec enable_provider(String.t(), String.t(), String.t()) ::
          {:ok, SocialProvider.t()} | {:error, term()}
  def enable_provider(provider, client_id, client_secret) do
    attrs = %{
      provider: provider,
      client_id: client_id,
      client_secret: client_secret,
      enabled: true
    }

    case Repo.get_by(SocialProvider, provider: provider) do
      nil -> %SocialProvider{}
      existing -> existing
    end
    |> SocialProvider.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "The enabled provider record (with credentials), or nil."
  @spec provider(String.t()) :: SocialProvider.t() | nil
  def provider(name) when is_binary(name) do
    Repo.one(from p in SocialProvider, where: p.provider == ^name and p.enabled == true)
  end

  @doc "Build the provider authorization redirect URL."
  @spec authorize_url(SocialProvider.t(), String.t(), String.t()) :: String.t()
  def authorize_url(%SocialProvider{provider: name, client_id: client_id}, state, redirect_uri) do
    cfg = @endpoints[name]

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "scope" => cfg.scope,
        "state" => state
      })

    cfg.authorize <> "?" <> query
  end

  @doc """
  Complete the callback: exchange `code`, fetch userinfo, find-or-link the User.
  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec handle_callback(SocialProvider.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, term()}
  def handle_callback(%SocialProvider{provider: name} = p, code, redirect_uri)
      when is_binary(code) do
    cfg = @endpoints[name]

    with {:ok, %{"access_token" => token}} <- exchange(cfg, p, code, redirect_uri),
         {:ok, info} <- HTTP.get_bearer(cfg.userinfo, token),
         {:ok, email, external_id} <- extract(cfg, info) do
      {:ok, find_or_link(name, external_id, email)}
    else
      {:ok, %{}} -> {:error, :no_access_token}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp exchange(cfg, p, code, redirect_uri) do
    HTTP.post_form(cfg.token, %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => p.client_id,
      "client_secret" => p.client_secret
    })
  end

  defp extract(cfg, info) do
    email = info[cfg.email_key]
    external_id = info[cfg.id_key]

    if is_binary(email) and email != "" and not is_nil(external_id),
      do: {:ok, email, to_string(external_id)},
      else: {:error, :no_email}
  end

  # An existing (provider, external_id) re-logs the same account; otherwise the
  # email find-or-creates the User (no duplicate of an existing email account),
  # and the social identity is linked.
  defp find_or_link(provider, external_id, email) do
    case Repo.get_by(SocialIdentity, provider: provider, external_id: external_id) do
      %SocialIdentity{user_id: uid} ->
        Accounts.get_user(uid)

      nil ->
        user = find_or_create_user(email)

        %SocialIdentity{}
        |> SocialIdentity.changeset(%{
          user_id: user.id,
          provider: provider,
          external_id: external_id
        })
        |> Repo.insert(on_conflict: :nothing)

        user
    end
  end

  defp find_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        user

      _ ->
        random = Base.encode16(:crypto.strong_rand_bytes(32))
        {:ok, user} = Accounts.register_user(%{email: email, password: random})
        Repo.update!(User.confirm_changeset(user))
    end
  end
end
