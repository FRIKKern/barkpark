defmodule Barkpark.Sso.Oidc do
  @moduledoc """
  OpenID Connect relying-party (era-w3-oidc-rp). Barkpark is the RP; an
  organization's IdP is the OP. Authorization-code flow with PKCE:

    1. `authorize_url/2` builds the redirect to the OP (state + nonce + PKCE
       `code_challenge`); the caller stores `state`/`nonce`/`code_verifier`.
    2. `handle_callback/3` exchanges the code at the token endpoint, verifies the
       returned `id_token` (JWS RS256, signed by a key from the OP's JWKS),
       validates `iss`/`aud`/`exp`/`nonce`, and find-or-creates the User.

  The two outbound calls go through `Barkpark.Sso.Oidc.HTTP` so tests stand in a
  mock IdP. Live-IdP verification (Okta/Entra quirks) is the remaining manual
  step; the protocol logic here is fully covered by tests against a mock OP.
  """
  import Ecto.Query, warn: false

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Accounts.User
  alias Barkpark.Sso.OidcConnection
  alias Barkpark.Sso.Oidc.HTTP
  alias Barkpark.Tenancy.Organization

  @doc "Create a per-org OIDC connection."
  @spec create_connection(map()) :: {:ok, OidcConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_connection(attrs) do
    changeset = OidcConnection.changeset(%OidcConnection{}, attrs)

    # Mapping TARGETS must be known roles (built-in, or a custom Role defined
    # globally / for one of the org's workspaces) — mirrors SCIM's group
    # validation. Guarded here because the authoritative role sync writes via
    # update_all, which would otherwise bypass the membership changeset and
    # persist an unknown role string.
    with %{valid?: true} <- changeset,
         :ok <- validate_mapping_roles(changeset) do
      Repo.insert(changeset)
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
  @spec authorize_url(OidcConnection.t(), map()) :: String.t()
  def authorize_url(%OidcConnection{} = c, %{
        state: state,
        nonce: nonce,
        code_challenge: challenge,
        redirect_uri: redirect_uri
      }) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => c.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => "openid email",
        "state" => state,
        "nonce" => nonce,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    c.authorization_endpoint <> "?" <> query
  end

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
         {:ok, user} <- find_or_create_user(claims["email"]) do
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

  # ── internals ──────────────────────────────────────────────────────────────

  defp exchange_code(c, code, redirect_uri, verifier) do
    HTTP.post_form(c.token_endpoint, %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => c.client_id,
      "client_secret" => c.client_secret,
      "code_verifier" => verifier
    })
  end

  # Verify the id_token JWS against a key from the OP's JWKS (RS256 only — never
  # trust the token's own alg header, which defeats alg:none / HS256-confusion).
  defp verify_id_token(c, id_token) do
    with {:ok, %{"keys" => keys}} <- HTTP.get_json(c.jwks_uri),
         kid <- token_kid(id_token),
         %{} = jwk_map <- select_jwk(keys, kid),
         jwk = JOSE.JWK.from_map(jwk_map),
         {true, payload, _} <- JOSE.JWS.verify_strict(jwk, ["RS256"], id_token),
         {:ok, claims} <- Jason.decode(payload) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token}
    end
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
      not (is_binary(claims["email"]) and claims["email"] != "") -> {:error, :no_email}
      true -> :ok
    end
  end

  defp aud_ok?(aud, client_id) when is_binary(aud), do: aud == client_id
  defp aud_ok?(aud, client_id) when is_list(aud), do: client_id in aud
  defp aud_ok?(_, _), do: false

  # Find-or-create the authenticated User (unusable local password — they sign
  # in via the IdP). Confirmed on creation (the IdP vouched for the identity).
  defp find_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        {:ok, user}

      _ ->
        random = Base.encode16(:crypto.strong_rand_bytes(32))

        case Accounts.register_user(%{email: email, password: random}) do
          {:ok, user} -> {:ok, Repo.update!(User.confirm_changeset(user))}
          err -> err
        end
    end
  end

  defp url64(bytes), do: Base.url_encode64(bytes, padding: false)
end
