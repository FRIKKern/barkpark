defmodule Barkpark.Sso.Oidc do
  @moduledoc """
  OpenID Connect relying-party (era-w3-oidc-rp). Barkpark is the RP; an
  organization's IdP is the OP. Authorization-code flow with PKCE:

    1. `authorize_url/2` builds the redirect to the OP (state + nonce + PKCE
       `code_challenge`); the caller stores `state`/`nonce`/`code_verifier`.
    2. `handle_callback/3` exchanges the code at the token endpoint, verifies the
       returned `id_token` (JWS RS256, signed by a key from the OP's JWKS),
       validates `iss`/`aud`/`exp`/`nonce`, and find-or-creates the User.

  With `strict_validation` on (the connection's field, or
  `BARKPARK_OIDC_STRICT_VALIDATION` for the instance), the id_token must carry
  `exp`, `nbf`/`iat` may not lie in the future beyond 60s of clock skew, and
  the user is matched on the IdP subject (Entra `oid`, else `sub`) before the
  email. A set `tenant_id` must equal the token's `tid`. Empty endpoints come
  from the issuer's discovery document. Discovery and JWKS are cached in ETS;
  a token the cached keys cannot verify refetches the JWKS once, so a key
  rollover at the IdP needs no operator action.

  The outbound calls go through `Barkpark.Sso.Oidc.HTTP` so tests stand in a
  mock IdP. Live-IdP verification (Okta/Entra quirks) is the remaining manual
  step; the protocol logic here is fully covered by tests against a mock OP.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Accounts.User
  alias Barkpark.Sso.{OidcConnection, SocialIdentity}
  alias Barkpark.Sso.Oidc.HTTP
  alias Barkpark.Tenancy.Organization

  @cache :barkpark_oidc_cache
  @cache_ttl_s 3600
  @clock_skew_s 60

  @doc "Create a per-org OIDC connection."
  @spec create_connection(map()) :: {:ok, OidcConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_connection(attrs) do
    %OidcConnection{} |> OidcConnection.changeset(attrs) |> save(&Repo.insert/1)
  end

  @doc "Update a connection; group mappings are re-checked like on create."
  @spec update_connection(OidcConnection.t(), map()) ::
          {:ok, OidcConnection.t()} | {:error, term()}
  def update_connection(%OidcConnection{} = c, attrs) do
    c |> OidcConnection.changeset(attrs) |> save(&Repo.update/1)
  end

  @doc "Delete a connection. Sign-ins through it stop at once."
  @spec delete_connection(OidcConnection.t()) :: {:ok, OidcConnection.t()} | {:error, term()}
  def delete_connection(%OidcConnection{} = c), do: Repo.delete(c)

  @doc """
  Read the issuer's discovery document and return the endpoint attributes a
  connection needs. The document must name the same issuer it was fetched from.
  """
  @spec discover(String.t()) :: {:ok, map()} | {:error, term()}
  def discover(issuer) when is_binary(issuer) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case HTTP.get_json(url) do
      {:ok,
       %{
         "issuer" => ^issuer,
         "authorization_endpoint" => authorize,
         "token_endpoint" => token,
         "jwks_uri" => jwks
       }}
      when is_binary(authorize) and is_binary(token) and is_binary(jwks) ->
        {:ok,
         %{
           issuer: issuer,
           authorization_endpoint: authorize,
           token_endpoint: token,
           jwks_uri: jwks
         }}

      {:ok, _doc} ->
        {:error, :invalid_discovery_document}

      {:error, _} ->
        {:error, :discovery_unavailable}
    end
  end

  defp save(changeset, write) do
    # Mapping TARGETS must be known roles (built-in, or a custom Role defined
    # globally / for one of the org's workspaces) — mirrors SCIM's group
    # validation. Guarded here because the authoritative role sync writes via
    # update_all, which would otherwise bypass the membership changeset and
    # persist an unknown role string.
    with %{valid?: true} <- changeset,
         :ok <- validate_mapping_roles(changeset),
         :ok <- validate_owner_mapping(changeset) do
      write.(changeset)
    else
      %Ecto.Changeset{} = cs -> {:error, cs}
      {:error, _} = err -> err
    end
  end

  defp validate_mapping_roles(changeset) do
    mappings = Ecto.Changeset.get_field(changeset, :group_role_mappings) || %{}
    org_id = Ecto.Changeset.get_field(changeset, :organization_id)

    unknown =
      mappings
      |> Map.values()
      |> Enum.uniq()
      |> Enum.reject(&known_role?(org_id, &1))

    case unknown do
      [] -> :ok
      names -> {:error, {:unknown_role, names}}
    end
  end

  # Each sign-in sets the role from the user's groups and can lower it. With
  # BARKPARK_OIDC_KEEP_OWNER on and owners in the org, a changed mapping must
  # still map a group to owner, or the owners' next sign-ins would leave the
  # org with no owner.
  defp validate_owner_mapping(changeset) do
    case Barkpark.Sso.keep_owner?() &&
           Ecto.Changeset.get_change(changeset, :group_role_mappings) do
      mappings when is_map(mappings) and map_size(mappings) > 0 ->
        org_id = Ecto.Changeset.get_field(changeset, :organization_id)

        if "owner" in Map.values(mappings) or not Barkpark.Sso.org_has_owner?(org_id),
          do: :ok,
          else: {:error, :no_owner_mapping}

      _ ->
        :ok
    end
  end

  defp known_role?(org_id, role_name) when is_binary(role_name) do
    ws_ids =
      Repo.all(
        from w in Barkpark.Tenancy.Workspace,
          where: w.organization_id == ^org_id,
          select: w.id
      )

    role_name in Barkpark.Tenancy.Membership.roles() or
      Repo.exists?(
        from r in Barkpark.Tenancy.Role,
          where: r.name == ^role_name and (is_nil(r.workspace_id) or r.workspace_id in ^ws_ids)
      )
  end

  defp known_role?(_org_id, _), do: false

  @doc "The active OIDC connection for an org slug, or nil."
  @spec connection_for_org_slug(String.t()) :: OidcConnection.t() | nil
  def connection_for_org_slug(slug) when is_binary(slug) do
    Repo.one(
      from c in OidcConnection,
        join: o in Organization,
        on: o.id == c.organization_id,
        where: o.slug == ^slug and c.active == true
    )
  end

  @doc "Fresh PKCE + anti-forgery material: `%{state, nonce, code_verifier, code_challenge}`."
  @spec new_auth_params() :: %{
          state: String.t(),
          nonce: String.t(),
          code_verifier: String.t(),
          code_challenge: String.t()
        }
  def new_auth_params do
    verifier = url64(:crypto.strong_rand_bytes(32))
    challenge = url64(:crypto.hash(:sha256, verifier))

    %{
      state: url64(:crypto.strong_rand_bytes(16)),
      nonce: url64(:crypto.strong_rand_bytes(16)),
      code_verifier: verifier,
      code_challenge: challenge
    }
  end

  @doc "Build the OP authorization redirect URL for `connection` + `params`."
  @spec authorize_url(OidcConnection.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def authorize_url(%OidcConnection{} = c, %{
        state: state,
        nonce: nonce,
        code_challenge: challenge,
        redirect_uri: redirect_uri
      }) do
    with {:ok, endpoint} <- endpoint(c, :authorization_endpoint) do
      query =
        %{
          "response_type" => "code",
          "client_id" => c.client_id,
          "redirect_uri" => redirect_uri,
          "scope" => c.scopes || "openid email",
          "state" => state,
          "nonce" => nonce,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        }
        |> Map.merge(mfa_request(c))
        |> URI.encode_query()

      {:ok, endpoint <> "?" <> query}
    end
  end

  # An Entra connection (tenant_id set) that trusts the IdP's MFA asks for it
  # with the OIDC `claims` request parameter: `amr` essential with value `mfa`.
  # Measured 2026-10-27 on a tenant with security defaults and no Entra ID P1:
  # Entra asked a registered user for the authenticator code on every sign-in
  # with this parameter and on none without it.
  @mfa_claims_request Jason.encode!(%{
                        "id_token" => %{"amr" => %{"essential" => true, "values" => ["mfa"]}}
                      })

  defp mfa_request(%OidcConnection{trust_idp_mfa: true, tenant_id: tid})
       when is_binary(tid) and tid != "",
       do: %{"claims" => @mfa_claims_request}

  defp mfa_request(_c), do: %{}

  @doc """
  Complete the callback: exchange `code`, verify the id_token, find-or-create the
  user. `opts` carries `:redirect_uri`, `:code_verifier`, and `:nonce` (from the
  start step). Returns `{:ok, user, claims}` or `{:error, reason}`.
  """
  @spec handle_callback(OidcConnection.t(), String.t(), keyword()) ::
          {:ok, User.t(), map()} | {:error, term()}
  def handle_callback(%OidcConnection{} = c, code, opts) when is_binary(code) do
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    verifier = Keyword.fetch!(opts, :code_verifier)
    expected_nonce = Keyword.get(opts, :nonce)

    with {:ok, %{"id_token" => id_token}} <- exchange_code(c, code, redirect_uri, verifier),
         {:ok, claims} <- verify_id_token(c, id_token),
         :ok <- validate_claims(c, claims, expected_nonce),
         {:ok, user} <- find_or_create_user(c, claims) do
      # JIT: first SSO login gains a membership in the connection's org
      # (era-w3-jit). When the id_token's groups resolve through the
      # admin-configured group→role mappings (era-w7), that role wins — for
      # new AND existing memberships (authoritative, mirroring SCIM group
      # sync). An absent/unmapped groups claim leaves existing roles alone.
      case Barkpark.Sso.resolve_group_role(c, claims) do
        nil ->
          Barkpark.Sso.jit_provision(c.organization_id, user)

        role ->
          Barkpark.Sso.jit_provision(c.organization_id, user, role)
          Barkpark.Sso.set_org_member_role(c.organization_id, user.id, role)
      end

      {:ok, user, claims}
    else
      {:ok, %{}} -> {:error, :no_id_token}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  Did the IdP assert MFA for this sign-in, on a connection that trusts it?
  True when `trust_idp_mfa` is on and the id_token's `amr` contains `"mfa"`,
  or its `acr` equals the connection's `mfa_acr`.
  """
  @spec idp_mfa?(OidcConnection.t(), map()) :: boolean()
  def idp_mfa?(%OidcConnection{trust_idp_mfa: true} = c, claims) do
    amr = claims["amr"]

    result =
      (is_list(amr) and "mfa" in amr) or
        (c.mfa_acr not in [nil, ""] and claims["acr"] == c.mfa_acr)

    # Method names and context ids only; nothing here identifies the user.
    Logger.debug(fn ->
      "[OIDC] MFA claims: amr=#{inspect(amr)} acr=#{inspect(claims["acr"])} " <>
        "acrs=#{inspect(claims["acrs"])} counted=#{result}"
    end)

    result
  end

  def idp_mfa?(_c, _claims), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  defp exchange_code(c, code, redirect_uri, verifier) do
    params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => c.client_id,
      "code_verifier" => verifier
    }

    with {:ok, url} <- endpoint(c, :token_endpoint) do
      case c.token_endpoint_auth_method do
        # RFC 6749 §2.3.1: form-encode both parts before joining them.
        "client_secret_basic" ->
          basic =
            Base.encode64(
              URI.encode_www_form(c.client_id) <> ":" <> URI.encode_www_form(c.client_secret)
            )

          HTTP.post_form(url, params, [{"authorization", "Basic " <> basic}])

        _ ->
          HTTP.post_form(url, Map.put(params, "client_secret", c.client_secret), [])
      end
    end
  end

  # Verify the id_token JWS against a key from the OP's JWKS (RS256 only — never
  # trust the token's own alg header, which defeats alg:none / HS256-confusion).
  # The cached key set is tried first; a miss (unknown kid after a rollover)
  # refetches the JWKS once.
  defp verify_id_token(c, id_token) do
    with {:ok, uri} <- endpoint(c, :jwks_uri),
         {:error, _} <- verify_with(cached(uri), id_token),
         {:ok, %{"keys" => keys} = jwks} <- HTTP.get_json(uri) do
      cache_put(uri, jwks)
      verify_with(keys, id_token)
    else
      {:ok, %{} = claims} -> {:ok, claims}
      _ -> {:error, :invalid_id_token}
    end
  end

  defp verify_with(%{"keys" => keys}, id_token), do: verify_with(keys, id_token)

  defp verify_with(keys, id_token) when is_list(keys) do
    with %{} = jwk_map <- select_jwk(keys, token_kid(id_token)),
         jwk = JOSE.JWK.from_map(jwk_map),
         {true, payload, _} <- JOSE.JWS.verify_strict(jwk, ["RS256"], id_token),
         {:ok, %{} = claims} <- Jason.decode(payload) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  defp verify_with(_, _), do: {:error, :invalid_id_token}

  # A stored endpoint wins; an empty one is read from the issuer's discovery
  # document, so a connection created before discovery keeps its endpoints.
  defp endpoint(c, field) do
    case Map.fetch!(c, field) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> discovered(c.issuer, Atom.to_string(field))
    end
  end

  defp discovered(issuer, key) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    doc =
      case cached(url) do
        %{} = doc ->
          doc

        nil ->
          case HTTP.get_json(url) do
            {:ok, %{} = doc} -> cache_put(url, doc)
            _ -> nil
          end
      end

    case doc do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> {:error, :discovery_failed}
    end
  end

  @doc """
  Create the discovery and JWKS cache, owned by the caller.
  `Barkpark.Application.start/2` calls this at boot. Idempotent.
  """
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.whereis(@cache) == :undefined do
      try do
        _ = :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp cached(url) do
    now = System.system_time(:second)

    case :ets.whereis(@cache) != :undefined and :ets.lookup(@cache, url) do
      [{^url, value, fetched_at}] when now - fetched_at < @cache_ttl_s -> value
      _ -> nil
    end
  end

  defp cache_put(url, value) do
    init_cache()
    :ets.insert(@cache, {url, value, System.system_time(:second)})
    value
  end

  defp token_kid(jwt) do
    with [header_b64 | _] <- String.split(jwt, "."),
         {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, %{"kid" => kid}} <- Jason.decode(header_json) do
      kid
    else
      _ -> nil
    end
  end

  # Match the kid; if the token carries no kid and there is exactly one key, use it.
  defp select_jwk(keys, nil) when length(keys) == 1, do: hd(keys)
  defp select_jwk(keys, kid), do: Enum.find(keys, &(&1["kid"] == kid))

  defp validate_claims(c, claims, expected_nonce) do
    now = System.system_time(:second)

    cond do
      claims["iss"] != c.issuer -> {:error, :issuer_mismatch}
      not aud_ok?(claims["aud"], c.client_id) -> {:error, :audience_mismatch}
      is_integer(claims["exp"]) and claims["exp"] < now -> {:error, :expired}
      expected_nonce && claims["nonce"] != expected_nonce -> {:error, :nonce_mismatch}
      c.tenant_id not in [nil, ""] and claims["tid"] != c.tenant_id -> {:error, :tenant_mismatch}
      not (email?(claims) or strict_subject(c, claims) != nil) -> {:error, :no_email}
      strict?(c) -> validate_strict(claims, now)
      true -> :ok
    end
  end

  # Strict mode: `exp` is required, and `nbf`/`iat` may not lie in the future
  # beyond a small clock skew. Off by default so existing connections are
  # unchanged.
  defp validate_strict(claims, now) do
    cond do
      not is_integer(claims["exp"]) -> {:error, :missing_exp}
      future?(claims["nbf"], now) -> {:error, :not_yet_valid}
      future?(claims["iat"], now) -> {:error, :issued_in_future}
      true -> :ok
    end
  end

  defp future?(t, now) when is_integer(t), do: t - @clock_skew_s > now
  defp future?(nil, _now), do: false
  defp future?(_, _now), do: true

  defp strict?(c),
    do:
      c.strict_validation == true or
        Application.get_env(:barkpark, :oidc_strict_validation, false)

  defp email?(claims), do: login_email(claims) != nil

  # The address a sign-in is matched on: the email claim. With
  # BARKPARK_OIDC_EMAIL_FROM_UPN on, a token without one falls back to
  # preferred_username, then upn, when it is an address. Matching on the
  # address ignores case (`Accounts.get_user_by_email/1`).
  defp login_email(%{"email" => email}) when is_binary(email) and email != "", do: email

  defp login_email(claims) do
    if Application.get_env(:barkpark, :oidc_email_from_upn, false) == true do
      Enum.find([claims["preferred_username"], claims["upn"]], &(is_binary(&1) and &1 =~ "@"))
    end
  end

  # The IdP's stable id for the user under strict mode: Entra's `oid` (the same
  # across apps in a tenant), else the standard `sub`. Nil when strict is off.
  defp strict_subject(c, claims) do
    if strict?(c) do
      Enum.find([claims["oid"], claims["sub"]], &(is_binary(&1) and &1 != ""))
    end
  end

  defp aud_ok?(aud, client_id) when is_binary(aud), do: aud == client_id
  defp aud_ok?(aud, client_id) when is_list(aud), do: client_id in aud
  defp aud_ok?(_, _), do: false

  # Under strict mode a subject linked at an earlier sign-in re-signs the same
  # account whatever email the IdP now asserts; the first sign-in links it.
  defp find_or_create_user(c, claims) do
    subject = strict_subject(c, claims)

    linked =
      subject && Repo.get_by(SocialIdentity, provider: provider(c), external_id: subject)

    case linked do
      %SocialIdentity{user_id: uid} ->
        {:ok, Accounts.get_user(uid)}

      _ ->
        with {:ok, user} <- find_or_create_by_email(c.organization_id, login_email(claims)) do
          if subject, do: link_subject(c, user, subject)
          {:ok, user}
        end
    end
  end

  # One provider namespace per connection: a subject is only unique per IdP.
  defp provider(c), do: "oidc:" <> c.id

  defp link_subject(c, user, subject) do
    %SocialIdentity{}
    |> SocialIdentity.changeset(%{user_id: user.id, provider: provider(c), external_id: subject})
    |> Repo.insert(on_conflict: :nothing)
  end

  defp find_or_create_by_email(_org_id, email) when not is_binary(email) or email == "",
    do: {:error, :no_email}

  # Find-or-create the authenticated User (unusable local password — they sign
  # in via the IdP). Confirmed on creation (the IdP vouched for the identity).
  # An EXISTING account is adopted only when the connection's org can vouch
  # for it (`Sso.org_may_adopt?/3`: a seat in the org, or a verified org
  # domain). The IdP is tenant-controlled and may assert any email, so without
  # this an org could sign in as another org's user (task-6f7cd94ab61cc688).
  defp find_or_create_by_email(org_id, email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        # Seat, or verified domain with an unconfirmed account reclaimed
        # first (task-0abbf88fd420360d); otherwise refused.
        Barkpark.Sso.org_adopt(org_id, user, email)

      _ ->
        random = Base.encode16(:crypto.strong_rand_bytes(32))

        case Accounts.register_user(%{email: email, password: random}) do
          {:ok, user} -> {:ok, Accounts.confirm_provisioned_user(user)}
          err -> err
        end
    end
  end

  defp url64(bytes), do: Base.url_encode64(bytes, padding: false)
end
