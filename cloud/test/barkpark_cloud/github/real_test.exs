defmodule BarkparkCloud.GitHub.RealTest do
  @moduledoc """
  The Real GitHub client (gh-2) asserted WITHOUT the network: the App-JWT shape
  (RS256 header + iss/iat/exp claims, signature verified against a throwaway
  key), the pure REST request builders, and the compose paths (token exchange →
  action) driven against a transport fake. HUMAN-LAST: no real App key exists, so
  a throwaway RSA key is generated per test — nothing is committed and no byte
  reaches api.github.com.

  `async: false` — the tests toggle the global `BarkparkCloud.GitHub` app env.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.GitHub
  alias BarkparkCloud.GitHub.Real
  alias BarkparkCloud.GitHubFakeTransport

  setup do
    priv = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, priv)])
    %{priv: priv, pem: pem}
  end

  defp put_github_config(kw) do
    base = Application.get_env(:barkpark_cloud, GitHub, [])
    Application.put_env(:barkpark_cloud, GitHub, Keyword.merge(base, kw))
    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  describe "build_app_jwt/3 — RS256 App JWT" do
    test "header + claims are GitHub's documented shape", %{pem: pem} do
      now = 1_700_000_000
      jwt = Real.build_app_jwt("12345", pem, now)

      [h, c, _s] = String.split(jwt, ".")
      header = h |> Base.url_decode64!(padding: false) |> Jason.decode!()
      claims = c |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert header["alg"] == "RS256"
      assert header["typ"] == "JWT"
      assert claims["iss"] == "12345"
      # iat backdated 60s for clock skew; exp <= 10 minutes out.
      assert claims["iat"] == now - 60
      assert claims["exp"] == now + 540
      assert claims["exp"] - claims["iat"] <= 600
    end

    test "the signature verifies against the key's public half (real RS256)", %{
      priv: priv,
      pem: pem
    } do
      now = 1_700_000_000
      jwt = Real.build_app_jwt("777", pem, now)
      [h, c, s] = String.split(jwt, ".")

      signing_input = h <> "." <> c
      signature = Base.url_decode64!(s, padding: false)
      # Derive the RSA public key from the private record: {:RSAPublicKey, N, E}.
      pub = {:RSAPublicKey, elem(priv, 2), elem(priv, 3)}

      assert :public_key.verify(signing_input, :sha256, signature, pub)
      # A tampered input must NOT verify.
      refute :public_key.verify(signing_input <> "x", :sha256, signature, pub)
    end
  end

  describe "pure request builders" do
    test "access_token_request — App-JWT bearer, correct path + headers" do
      req = Real.access_token_request("42", "the.jwt.token")

      assert req.method == :post
      assert req.url == "https://api.github.com/app/installations/42/access_tokens"
      assert {"Authorization", "Bearer the.jwt.token"} in req.headers
      assert {"Accept", "application/vnd.github+json"} in req.headers
      assert {"X-GitHub-Api-Version", "2022-11-28"} in req.headers
    end

    test "get_installation_request" do
      req = Real.get_installation_request("42", "jwt")
      assert req.method == :get
      assert req.url == "https://api.github.com/app/installations/42"
    end

    test "create_repo_request — installation-token auth, body carries name/private/auto_init" do
      req = Real.create_repo_request("ghs_x", "acme", "blog", true)

      assert req.method == :post
      assert req.url == "https://api.github.com/orgs/acme/repos"
      assert {"Authorization", "token ghs_x"} in req.headers
      body = Jason.decode!(req.body)
      assert body == %{"name" => "blog", "private" => true, "auto_init" => true}
    end

    test "content_request — PUT contents with Base64 content" do
      req = Real.content_request("ghs_x", "acme/blog", "index.md", "# hi", "seed", branch: "main")

      assert req.method == :put
      assert req.url == "https://api.github.com/repos/acme/blog/contents/index.md"
      body = Jason.decode!(req.body)
      assert body["message"] == "seed"
      assert body["branch"] == "main"
      assert Base.decode64!(body["content"]) == "# hi"
    end

    test "webhook_request — push event, secret in config, json delivery" do
      req = Real.webhook_request("ghs_x", "acme/blog", "https://x/hook", "topsecret")

      assert req.method == :post
      assert req.url == "https://api.github.com/repos/acme/blog/hooks"
      body = Jason.decode!(req.body)
      assert body["name"] == "web"
      assert body["events"] == ["push"]
      assert body["config"]["url"] == "https://x/hook"
      assert body["config"]["secret"] == "topsecret"
      assert body["config"]["content_type"] == "json"
    end

    test "list_repos_request" do
      req = Real.list_repos_request("ghs_x")
      assert req.method == :get
      assert req.url == "https://api.github.com/installation/repositories"
    end
  end

  describe "compose paths against a transport fake" do
    test "exchange_installation_token parses the token + signs with the App-JWT", %{pem: pem} do
      put_github_config(
        app_id: "999",
        private_key: pem,
        http_client: &GitHubFakeTransport.request/1
      )

      GitHubFakeTransport.program([
        {:ok,
         %{status: 201, body: ~s({"token":"ghs_live_abc","expires_at":"2026-01-01T00:00:00Z"})}}
      ])

      assert {:ok, "ghs_live_abc"} = Real.exchange_installation_token("77")

      req = GitHubFakeTransport.last_request()
      assert req.url == "https://api.github.com/app/installations/77/access_tokens"

      assert Enum.any?(req.headers, fn {k, v} ->
               k == "Authorization" and String.starts_with?(v, "Bearer ")
             end)
    end

    test "get_installation parses account.login", %{pem: pem} do
      put_github_config(
        app_id: "999",
        private_key: pem,
        http_client: &GitHubFakeTransport.request/1
      )

      GitHubFakeTransport.program([{:ok, %{status: 200, body: ~s({"account":{"login":"acme"}})}}])

      assert {:ok, %{account_login: "acme"}} = Real.get_installation("77")
    end

    test "register_webhook exchanges a token then posts the hook WITH the secret", %{pem: pem} do
      put_github_config(
        app_id: "999",
        private_key: pem,
        http_client: &GitHubFakeTransport.request/1
      )

      GitHubFakeTransport.program([
        {:ok, %{status: 201, body: ~s({"token":"ghs_live"})}},
        {:ok, %{status: 201, body: ~s({"id":99})}}
      ])

      assert {:ok, %{"id" => 99}} =
               Real.register_webhook("77", "acme/blog", "https://x/hook", "topsecret")

      # The LAST request is the hook POST — it carried the installation token and
      # the signing secret in the payload.
      req = GitHubFakeTransport.last_request()
      assert req.url == "https://api.github.com/repos/acme/blog/hooks"
      assert {"Authorization", "token ghs_live"} in req.headers
      assert Jason.decode!(req.body)["config"]["secret"] == "topsecret"
    end

    test "a non-2xx surfaces as a github_http_error", %{pem: pem} do
      put_github_config(
        app_id: "999",
        private_key: pem,
        http_client: &GitHubFakeTransport.request/1
      )

      GitHubFakeTransport.program([{:ok, %{status: 404, body: ~s({"message":"Not Found"})}}])

      assert {:error, {:github_http_error, 404, _}} = Real.exchange_installation_token("77")
    end
  end

  describe "fail-closed without configuration" do
    test "no http_client → never reaches the wire", %{pem: pem} do
      put_github_config(app_id: "1", private_key: pem, http_client: nil)
      assert {:error, :http_client_not_configured} = Real.exchange_installation_token("5")
    end

    test "no app credentials → the App-JWT can't be built", %{} do
      put_github_config(
        app_id: nil,
        private_key: nil,
        http_client: &GitHubFakeTransport.request/1
      )

      assert {:error, :not_configured} = Real.get_installation("5")
      assert {:error, :not_configured} = Real.exchange_installation_token("5")
    end
  end
end
