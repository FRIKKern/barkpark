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
       ADOPTING an existing email account additionally requires the provider to
       have ASSERTED that it verified the address (`email_verified`, or github's
       primary+verified entry in GET /user/emails); without that signal a NEW
       account may still be created, but an existing one is refused with
       `:email_unverified`.

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
      id_key: "sub",
      # Google's OIDC userinfo carries the claim; we require it to be true.
      verified_key: "email_verified"
    },
    "github" => %{
      authorize: "https://github.com/login/oauth/authorize",
      token: "https://github.com/login/oauth/access_token",
      userinfo: "https://api.github.com/user",
      scope: "user:email",
      email_key: "email",
      id_key: "id",
      # GET /user carries NO verification flag — its `email` is the public
      # profile address. The already-requested `user:email` scope reaches
      # GET /user/emails, whose entries carry `verified` + `primary`.
      verified_key: nil,
      emails: "https://api.github.com/user/emails"
    },
    "microsoft" => %{
      authorize: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      userinfo: "https://graph.microsoft.com/oidc/userinfo",
      scope: "openid email",
      email_key: "email",
      id_key: "sub",
      # Microsoft Graph's OIDC userinfo exposes NO verification claim, and
      # Microsoft documents `email` as unverified / user-settable on personal
      # accounts. There is no signal to trust, so this provider may never
      # adopt an existing Barkpark account.
      verified_key: nil
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
      find_or_link(name, external_id, email, verified_email?(cfg, info, email, token))
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

  defp extract(_cfg, info) when not is_map(info), do: {:error, :no_email}

  defp extract(cfg, info) do
    email = info[cfg.email_key]
    external_id = info[cfg.id_key]

    if is_binary(email) and email != "" and not is_nil(external_id),
      do: {:ok, email, to_string(external_id)},
      else: {:error, :no_email}
  end

  # Did the PROVIDER assert that it verified this address? Only that signal may
  # unlock adoption of an EXISTING Barkpark account (find_or_link/4).
  #
  #   * a `verified_key` in userinfo (google: "email_verified")
  #   * an `emails` endpoint whose entry for this address is primary+verified
  #     (github: GET /user/emails, reachable on the `user:email` scope we
  #     already request)
  #   * neither (microsoft) — the provider tells us nothing, so the answer is
  #     false and this provider can never adopt an existing account.
  defp verified_email?(cfg, info, email, token) do
    cond do
      is_binary(cfg[:verified_key]) -> truthy?(info[cfg[:verified_key]])
      is_binary(cfg[:emails]) -> emails_endpoint_verified?(cfg[:emails], email, token)
      true -> false
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp emails_endpoint_verified?(url, email, token) do
    want = String.downcase(email)

    case HTTP.get_bearer(url, token) do
      {:ok, entries} when is_list(entries) ->
        Enum.any?(entries, fn
          %{"email" => e, "verified" => v, "primary" => pr} when is_binary(e) ->
            String.downcase(e) == want and truthy?(v) and truthy?(pr)

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  # An existing (provider, external_id) re-logs the same account — the link
  # itself is the credential, so no email check applies. Otherwise the email
  # find-or-creates the User and the social identity is linked; ADOPTING an
  # existing email account requires `verified?`, because an attacker who
  # controls a provider account bearing someone else's UNVERIFIED address
  # would otherwise be handed that person's Barkpark session.
  defp find_or_link(provider, external_id, email, verified?) do
    case Repo.get_by(SocialIdentity, provider: provider, external_id: external_id) do
      %SocialIdentity{user_id: uid} ->
        {:ok, Accounts.get_user(uid)}

      nil ->
        case find_or_create_user(email, verified?) do
          {:ok, user} ->
            %SocialIdentity{}
            |> SocialIdentity.changeset(%{
              user_id: user.id,
              provider: provider,
              external_id: external_id
            })
            |> Repo.insert(on_conflict: :nothing)

            {:ok, user}

          {:error, _} = err ->
            err
        end
    end
  end

  defp find_or_create_user(email, verified?) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        if verified?, do: {:ok, user}, else: {:error, :email_unverified}

      _ ->
        random = Base.encode16(:crypto.strong_rand_bytes(32))
        {:ok, user} = Accounts.register_user(%{email: email, password: random})
        {:ok, Repo.update!(User.confirm_changeset(user))}
    end
  end
end
