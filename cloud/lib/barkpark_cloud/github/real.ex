defmodule BarkparkCloud.GitHub.Real do
  @moduledoc """
  The real `BarkparkCloud.GitHub.Client` — it builds the ACTUAL GitHub App API
  request shapes (App-JWT → installation-token exchange → REST) and sends them
  over the injected verified-TLS transport. Selected in prod ONLY once a human
  wires the App id + private key (gh-2 is HUMAN-LAST: no real credential exists
  in the repo, so this module is exercised purely through its pure builders in
  the suite — no byte ever reaches `api.github.com`).

  ## App-JWT — RS256 via OTP's `:public_key`, no new dependency

  A GitHub App authenticates by signing a short-lived JWT with its RSA private
  key (RS256). The control plane has NO JWT/JOSE library in the tree — and needs
  none: `build_app_jwt/3` assembles the compact JWS by hand and signs the
  `header.claims` input with `:public_key.sign(input, :sha256, rsa_key)`, which
  is exactly PKCS#1-v1.5 RSA-SHA256 = RS256. The claims are GitHub's documented
  set — `iat` backdated 60s (clock-skew slack), `exp` at most 10 minutes out,
  `iss` = the App id. `build_app_jwt/3` is PURE (given app_id, PEM, and `now`),
  so a test asserts the header/claims and verifies the signature against the
  public half of a throwaway key — no network, no committed secret.

  ## Installation tokens

  The App-JWT is only good for App-level endpoints; every repo action needs a
  short-lived INSTALLATION token minted via
  `POST /app/installations/:id/access_tokens` (Bearer the App-JWT). Each mutating
  callback exchanges a fresh installation token internally, so the context never
  handles one.

  ## Injectable HTTP client — €0 in tests, no new dep

  Same seam as `Billing.StripeGateway`: `request/1` resolves a 1-arity client fn
  from config (`config :barkpark_cloud, BarkparkCloud.GitHub, http_client: &m.f/1`)
  and calls it with the `%{method, url, headers, body}` map. In prod that is
  `Billing.HttpClient` (Erlang `:httpc`, verified TLS). In dev/test there is no
  client, so any callback that would hit the wire returns
  `{:error, :http_client_not_configured}` — it can NEVER silently call GitHub.
  The pure request builders are the assertion seam.
  """
  @behaviour BarkparkCloud.GitHub.Client

  @api_base "https://api.github.com"
  @api_version "2022-11-28"
  @user_agent "barkpark-cloud"

  # GitHub caps an App-JWT at 10 minutes; iat is backdated 60s for clock skew.
  @jwt_iat_backdate 60
  @jwt_ttl 540

  @impl true
  def get_installation(installation_id) do
    with {:ok, jwt} <- app_jwt(),
         {:ok, decoded} <- request(get_installation_request(installation_id, jwt)) do
      case decoded do
        %{"account" => %{"login" => login}} when is_binary(login) ->
          {:ok, %{account_login: login}}

        _ ->
          {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def exchange_installation_token(installation_id) do
    with {:ok, jwt} <- app_jwt(),
         {:ok, decoded} <- request(access_token_request(installation_id, jwt)) do
      case decoded do
        %{"token" => token} when is_binary(token) -> {:ok, token}
        _ -> {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def create_repo(installation_id, name, private?)
      when is_binary(name) and is_boolean(private?) do
    with {:ok, %{account_login: owner}} <- get_installation(installation_id),
         {:ok, token} <- exchange_installation_token(installation_id),
         {:ok, decoded} <- request(create_repo_request(token, owner, name, private?)) do
      {:ok, decoded}
    end
  end

  @impl true
  def push_files(installation_id, repo_full_name, files, message)
      when is_binary(repo_full_name) and is_list(files) and is_binary(message) do
    with {:ok, token} <- exchange_installation_token(installation_id) do
      Enum.reduce_while(files, {:ok, %{pushed: 0}}, fn file, {:ok, %{pushed: n}} ->
        path = file[:path] || file["path"]
        content = file[:content] || file["content"]
        req = content_request(token, repo_full_name, path, content, message, [])

        case request(req) do
          {:ok, _} -> {:cont, {:ok, %{pushed: n + 1}}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  @impl true
  def register_webhook(installation_id, repo_full_name, url, secret)
      when is_binary(repo_full_name) and is_binary(url) and is_binary(secret) do
    with {:ok, token} <- exchange_installation_token(installation_id),
         {:ok, decoded} <- request(webhook_request(token, repo_full_name, url, secret)) do
      {:ok, decoded}
    end
  end

  @impl true
  def list_repos(installation_id) do
    with {:ok, token} <- exchange_installation_token(installation_id),
         {:ok, decoded} <- request(list_repos_request(token)) do
      case decoded do
        %{"repositories" => repos} when is_list(repos) -> {:ok, repos}
        repos when is_list(repos) -> {:ok, repos}
        _ -> {:error, :unexpected_response}
      end
    end
  end

  ## Pure request builders — the assertion seam (NO network) ─────────────────

  @doc """
  Build the compact GitHub App JWT (RS256) for `app_id`, signed by `private_key`
  (a PEM string), stamped from `now` (unix seconds). PURE. Returns the
  `header.claims.signature` string. Raises only on an unparseable PEM.
  """
  @spec build_app_jwt(String.t() | integer(), String.t(), integer()) :: String.t()
  def build_app_jwt(app_id, private_key, now)
      when is_binary(private_key) and is_integer(now) do
    header = %{"alg" => "RS256", "typ" => "JWT"}

    claims = %{
      "iat" => now - @jwt_iat_backdate,
      "exp" => now + @jwt_ttl,
      "iss" => to_string(app_id)
    }

    signing_input = b64url(Jason.encode!(header)) <> "." <> b64url(Jason.encode!(claims))
    signature = :public_key.sign(signing_input, :sha256, rsa_key(private_key))
    signing_input <> "." <> b64url(signature)
  end

  @doc "Pure request map for `GET /app/installations/:id` (App-JWT auth)."
  def get_installation_request(installation_id, jwt) do
    build_request(:get, "/app/installations/#{installation_id}", jwt_auth(jwt), "")
  end

  @doc "Pure request map for `POST /app/installations/:id/access_tokens` (App-JWT auth)."
  def access_token_request(installation_id, jwt) do
    build_request(:post, "/app/installations/#{installation_id}/access_tokens", jwt_auth(jwt), "")
  end

  @doc """
  Pure request map for creating a repo under `owner`. Uses `POST /orgs/:owner/repos`
  with `auto_init` so the default branch exists for the subsequent push. (A
  user-account installation would use `POST /user/repos`; disambiguating org-vs-
  user is a HUMAN refinement, out of scope for the never-invoked v1 shape.)
  """
  def create_repo_request(token, owner, name, private?) do
    body = Jason.encode!(%{"name" => name, "private" => private?, "auto_init" => true})
    build_request(:post, "/orgs/#{owner}/repos", token_auth(token), body)
  end

  @doc """
  Pure request map for a single create-or-update-contents call
  (`PUT /repos/:full_name/contents/:path`). `content` is the raw text; GitHub's
  contents API takes it Base64-encoded. `opts` may carry `:branch` and (for an
  update) the existing blob `:sha`.
  """
  def content_request(token, repo_full_name, path, content, message, opts) do
    body =
      %{"message" => message, "content" => Base.encode64(content)}
      |> maybe_put("branch", opts[:branch])
      |> maybe_put("sha", opts[:sha])
      |> Jason.encode!()

    build_request(:put, "/repos/#{repo_full_name}/contents/#{path}", token_auth(token), body)
  end

  @doc """
  Pure request map for registering a push webhook (`POST /repos/:full_name/hooks`).
  The `secret` rides in `config.secret` — GitHub uses it to HMAC-sign deliveries;
  it is sent to GitHub but never echoed back.
  """
  def webhook_request(token, repo_full_name, url, secret) do
    body =
      Jason.encode!(%{
        "name" => "web",
        "active" => true,
        "events" => ["push"],
        "config" => %{
          "url" => url,
          "content_type" => "json",
          "secret" => secret,
          "insecure_ssl" => "0"
        }
      })

    build_request(:post, "/repos/#{repo_full_name}/hooks", token_auth(token), body)
  end

  @doc "Pure request map for `GET /installation/repositories` (installation-token auth)."
  def list_repos_request(token) do
    build_request(:get, "/installation/repositories", token_auth(token), "")
  end

  @doc """
  Assemble a request map: method, `#{@api_base}<path>`, the base GitHub headers
  merged with `auth`, and `body`. PURE — the shape tests assert.
  """
  @spec build_request(atom(), String.t(), [{String.t(), String.t()}], String.t()) :: map()
  def build_request(method, path, auth, body) do
    %{
      method: method,
      url: @api_base <> path,
      headers:
        auth ++
          [
            {"Accept", "application/vnd.github+json"},
            {"X-GitHub-Api-Version", @api_version},
            {"User-Agent", @user_agent},
            {"Content-Type", "application/json"}
          ],
      body: body
    }
  end

  ## Internals ───────────────────────────────────────────────────────────────

  # Build the App-JWT from config. Fails closed (no raise) when the App id or
  # private key is unset, so an accidental invocation of Real without credentials
  # returns an error instead of crashing the request.
  defp app_jwt do
    cfg = config()

    with app_id when not is_nil(app_id) <- cfg[:app_id],
         pem when is_binary(pem) and pem != "" <- cfg[:private_key] do
      {:ok, build_app_jwt(app_id, pem, System.system_time(:second))}
    else
      _ -> {:error, :not_configured}
    end
  end

  # Decode a PEM private key to the record `:public_key.sign/3` accepts. Takes the
  # first PEM entry (PKCS#1 `RSA PRIVATE KEY` or PKCS#8 `PRIVATE KEY`).
  defp rsa_key(pem) do
    pem
    |> :public_key.pem_decode()
    |> hd()
    |> :public_key.pem_entry_decode()
  end

  defp jwt_auth(jwt), do: [{"Authorization", "Bearer " <> jwt}]
  defp token_auth(token), do: [{"Authorization", "token " <> token}]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # base64url without padding — the JWS wire encoding.
  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  # Resolve the injected HTTP client and perform the request. NEVER reaches the
  # wire in tests (no client configured → fail closed). On a 2xx, decode the JSON
  # body; otherwise surface the status + body.
  defp request(req) do
    case http_client() do
      fun when is_function(fun, 1) ->
        with {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(req),
             {:ok, decoded} <- Jason.decode(body) do
          {:ok, decoded}
        else
          {:ok, %{status: status, body: body}} -> {:error, {:github_http_error, status, body}}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_github_response, other}}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  defp http_client, do: config()[:http_client]
  defp config, do: Application.get_env(:barkpark_cloud, BarkparkCloud.GitHub, [])
end
