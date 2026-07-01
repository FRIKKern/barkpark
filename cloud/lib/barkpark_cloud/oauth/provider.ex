defmodule BarkparkCloud.OAuth.Provider do
  @moduledoc """
  Strategy behaviour for ONE consumer OAuth2 IdP — the OAuth analog of
  `BarkparkCloud.Billing.Gateway`. The `BarkparkCloud.OAuth` context never names
  a provider directly; it resolves `provider -> {module, config}` from config and
  drives this behaviour, so adding/removing a provider is a config + module edit,
  not a context rewrite.

  ## Why a behaviour, not Assent/Ueberauth

  The control plane has a deliberate no-new-HTTP-dep ethos: `Billing.HttpClient`
  reaches `api.stripe.com` over OTP's bundled `:httpc` (verified TLS) rather than
  pull a client library, and all crypto is hand-rolled (`Registry.Vault`,
  `UserToken.hash_token/1`, the Stripe webhook HMAC). Two fixed consumer
  providers — build authorize URL, POST a token endpoint, GET userinfo — is
  ~120 LOC and fits the existing Gateway mold 1:1. A library (Assent) is the
  right call ONLY when per-team enterprise OIDC/SAML lands (PKCE, nonce, JWKS
  rotation, discovery docs); flagged there, not built here.

  ## The request-map contract

  The `*_request` callbacks return the SAME `%{method, url, headers, body}` map
  that `Billing.HttpClient.request/1` already consumes, so the identical
  injectable, TLS-verified transport drives OAuth too — one audited `:httpc`
  path, no second HTTP surface.

  ## Callbacks

    * `authorize_url/3` — the IdP's authorization-code URL to redirect the
      browser to (carries `client_id`, derived `redirect_uri`, `scope`, `state`).
    * `token_request/3` — the request map to exchange an authorization `code`
      for an access token (POST the token endpoint).
    * `userinfo_request/1` — the request map to read the authenticated user's
      profile (GET userinfo, Bearer).
    * `parse_identity/1` — pull the STABLE subject id (`uid`) and the verified
      `email` (or `nil`) out of a decoded userinfo body. NEVER returns an
      unverified email as the identity email.
  """

  @typedoc "Resolved per-provider config: `%{client_id, client_secret, redirect_uri, ...}`."
  @type config :: map()

  @typedoc "The `%{method, url, headers, body}` shape `Billing.HttpClient.request/1` consumes."
  @type request_map :: %{
          method: :get | :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @typedoc "A verified identity: the IdP's stable uid + an OPTIONAL verified email."
  @type identity :: %{uid: String.t(), email: String.t() | nil}

  @callback authorize_url(config(), state :: String.t(), redirect_uri :: String.t()) ::
              String.t()

  @callback token_request(config(), code :: String.t(), redirect_uri :: String.t()) ::
              request_map()

  @callback userinfo_request(access_token :: String.t()) :: request_map()

  @callback parse_identity(userinfo :: map()) :: {:ok, identity()} | :error

  @doc """
  OPTIONAL second-call request map for providers whose userinfo endpoint does
  not return a verified email inline. GitHub is the case: `GET /user` omits a
  private email, so the verified primary must be read from `GET /user/emails`.
  When a strategy exports this, the context fetches it and merges the decoded
  list under the `"emails"` key of the body it hands to `parse_identity/1`.
  Google (OIDC) returns a verified email inline and does NOT implement this.
  """
  @callback emails_request(access_token :: String.t()) :: request_map()

  @optional_callbacks emails_request: 1
end
