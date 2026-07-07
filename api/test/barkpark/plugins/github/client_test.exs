defmodule Barkpark.Plugins.Github.ClientTest do
  # async: false because Auth is a singleton GenServer and the tests
  # mutate Application env for credentials.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Github.Auth
  alias Barkpark.Plugins.Github.Client

  alias Barkpark.Plugins.Github.Errors.{
    AuthError,
    NetworkError,
    NotFound,
    RateLimitError
  }

  @moduletag :github_client

  @app_id "123456"
  @installation_id "987654"
  @repo "FRIKKern/barkpark"
  @inst_token "ghs_installation_token_abc123"
  @token_path "/app/installations/#{@installation_id}/access_tokens"

  setup do
    # Trap exits so Bypass plug crashes (e.g. writing to a closed conn
    # after a forced client timeout / Bypass.down) don't surface as
    # `(exit) shutdown` in the test process.
    Process.flag(:trap_exit, true)

    # Auth runs in its own process; keep it able to reach the sandbox
    # connection even though this slice never touches the DB (mirrors the
    # bokbasen client test setup verbatim + future-proofs Auth).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    # Generate a throwaway RSA keypair so the JWT is signed with a real key
    # (NO real GitHub App credentials exist).
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    prior = Application.get_env(:barkpark, Barkpark.Plugins.Github)

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Github,
      app_id: @app_id,
      installation_id: @installation_id,
      private_key: pem,
      # Auth uses api_base for the installation-token exchange; Client uses
      # github_api_base for the REST verbs. Both point at Bypass.
      api_base: base,
      github_api_base: base
    )

    # Start a fresh singleton Auth for this test; stopped automatically on exit.
    start_supervised!(Auth)
    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.Github, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Github)
      end

      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    end)

    {:ok, bypass: bypass, base: base, public_key: public_key}
  end

  # Stubs the installation-token endpoint. Records the app JWT it received
  # and counts how many times it was hit.
  defp stub_token(bypass, opts \\ []) do
    jwt_ref = Keyword.get(opts, :jwt_ref)
    counter = Keyword.get(opts, :counter)

    Bypass.stub(bypass, "POST", @token_path, fn conn ->
      if counter, do: Agent.update(counter, &(&1 + 1))

      if jwt_ref do
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> jwt] -> Agent.update(jwt_ref, fn _ -> jwt end)
          _ -> :ok
        end
      end

      Plug.Conn.resp(
        conn,
        201,
        Jason.encode!(%{"token" => @inst_token, "expires_in" => 3600})
      )
    end)
  end

  defp read_json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  describe "installation-token exchange" do
    test "mints an RS256 app JWT, exchanges it, and REST calls carry the installation token",
         %{bypass: bypass, base: base, public_key: public_key} do
      {:ok, jwt_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass, jwt_ref: jwt_ref)

      Bypass.expect(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @inst_token]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"number" => 1}))
      end)

      assert {:ok, %{"number" => 1}} =
               Client.create_issue(@repo, %{title: "hi"}, base_url: base, max_retries: 0)

      jwt = Agent.get(jwt_ref, & &1)
      assert is_binary(jwt)

      # Three segments, RS256 header, iss == app_id, valid signature.
      [h64, p64, s64] = String.split(jwt, ".")
      header = h64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      claims = p64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert header["alg"] == "RS256"
      assert header["typ"] == "JWT"
      assert claims["iss"] == @app_id
      assert claims["exp"] > claims["iat"]

      signature = Base.url_decode64!(s64, padding: false)
      assert :public_key.verify(h64 <> "." <> p64, :sha256, signature, public_key)
    end
  end

  describe "create_issue/2" do
    test "POSTs the issue body and returns the created issue", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"number" => 42, "state" => "open"}))
      end)

      assert {:ok, %{"number" => 42}} =
               Client.create_issue(
                 @repo,
                 %{"title" => "Mirror me", "body" => "Task: t-1", "labels" => ["bp"]},
                 base_url: base,
                 max_retries: 0
               )

      body = Agent.get(body_ref, & &1)
      assert body["title"] == "Mirror me"
      assert body["body"] == "Task: t-1"
      assert body["labels"] == ["bp"]
    end
  end

  describe "update_issue/3" do
    test "PATCHes the issue with the given fields", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "PATCH", "/repos/#{@repo}/issues/42", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"number" => 42, "title" => "New title"}))
      end)

      assert {:ok, %{"number" => 42}} =
               Client.update_issue(@repo, 42, %{"title" => "New title"},
                 base_url: base,
                 max_retries: 0
               )

      assert Agent.get(body_ref, & &1)["title"] == "New title"
    end
  end

  describe "close_issue/3" do
    test "PATCHes state=closed with a lifecycle state_reason", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "PATCH", "/repos/#{@repo}/issues/7", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"number" => 7, "state" => "closed"}))
      end)

      assert {:ok, %{"state" => "closed"}} =
               Client.close_issue(@repo, 7, :not_planned, base_url: base, max_retries: 0)

      body = Agent.get(body_ref, & &1)
      assert body["state"] == "closed"
      assert body["state_reason"] == "not_planned"
    end
  end

  describe "add_labels/3" do
    test "POSTs the labels array", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/repos/#{@repo}/issues/7/labels", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"name" => "src:github"}]))
      end)

      assert {:ok, _} =
               Client.add_labels(@repo, 7, ["src:github", "needs-human"],
                 base_url: base,
                 max_retries: 0
               )

      assert Agent.get(body_ref, & &1)["labels"] == ["src:github", "needs-human"]
    end
  end

  describe "create_comment/3" do
    test "POSTs the comment body", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/repos/#{@repo}/issues/7/comments", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"id" => 99}))
      end)

      assert {:ok, %{"id" => 99}} =
               Client.create_comment(@repo, 7, "tracked internally",
                 base_url: base,
                 max_retries: 0
               )

      assert Agent.get(body_ref, & &1)["body"] == "tracked internally"
    end
  end

  describe "token caching + refresh" do
    test "several REST calls share a single token fetch", %{bypass: bypass, base: base} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      stub_token(bypass, counter: counter)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 1}))
      end)

      assert {:ok, _} = Client.create_issue(@repo, %{title: "a"}, base_url: base, max_retries: 0)
      assert {:ok, _} = Client.create_issue(@repo, %{title: "b"}, base_url: base, max_retries: 0)

      assert Agent.get(counter, & &1) == 1
    end

    test "invalidate triggers a token re-fetch", %{bypass: bypass, base: base} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      stub_token(bypass, counter: counter)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 1}))
      end)

      assert {:ok, _} = Client.create_issue(@repo, %{title: "a"}, base_url: base, max_retries: 0)
      assert :ok = Auth.invalidate()
      assert {:ok, _} = Client.create_issue(@repo, %{title: "b"}, base_url: base, max_retries: 0)

      assert Agent.get(counter, & &1) == 2
    end

    test "a 401 refreshes the token once and retries", %{bypass: bypass, base: base} do
      {:ok, token_counter} = Agent.start_link(fn -> 0 end)
      {:ok, issue_counter} = Agent.start_link(fn -> 0 end)
      stub_token(bypass, counter: token_counter)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        n = Agent.get_and_update(issue_counter, fn x -> {x, x + 1} end)

        if n == 0 do
          Plug.Conn.resp(conn, 401, ~s({"message":"Bad credentials"}))
        else
          Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 5}))
        end
      end)

      assert {:ok, %{"number" => 5}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)

      assert Agent.get(token_counter, & &1) == 2
    end

    test "a persistent 401 → AuthError", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"message":"Bad credentials"}))
      end)

      assert {:error, %AuthError{status: 401, message: "token refresh failed"}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
    end
  end

  describe "error classification" do
    test "429 with Retry-After → RateLimitError{retry_after}", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "42")
        |> Plug.Conn.resp(429, ~s({"message":"rate limited"}))
      end)

      assert {:error, %RateLimitError{retry_after: 42}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
    end

    test "403 with X-RateLimit-Remaining: 0 → RateLimitError", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, ~s({"message":"secondary rate limit"}))
      end)

      assert {:error, %RateLimitError{}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
    end

    test "403 without rate headers → AuthError (forbidden)", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 403, ~s({"message":"forbidden"}))
      end)

      assert {:error, %AuthError{status: 403, message: "forbidden"}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
    end

    test "404 → NotFound", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/999", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:error, %NotFound{status: 404}} =
               Client.update_issue(@repo, 999, %{"title" => "x"}, base_url: base, max_retries: 0)
    end

    test "410 Gone (detached) → NotFound", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/12", fn conn ->
        Plug.Conn.resp(conn, 410, ~s({"message":"Gone"}))
      end)

      assert {:error, %NotFound{status: 410}} =
               Client.update_issue(@repo, 12, %{"title" => "x"}, base_url: base, max_retries: 0)
    end

    test "exhausted 5xx → NetworkError{reason: {:http, 503}}", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 503, "{}")
      end)

      assert {:error, %NetworkError{reason: {:http, 503}}} =
               Client.create_issue(@repo, %{title: "x"},
                 base_url: base,
                 max_retries: 1,
                 retry_delay_ms: 5
               )
    end

    test "5xx then success is retried transparently", %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        n = Agent.get_and_update(counter, fn x -> {x, x + 1} end)
        if n == 0, do: Plug.Conn.resp(conn, 503, "{}"), else: Plug.Conn.resp(conn, 201, "{}")
      end)

      assert {:ok, _} =
               Client.create_issue(@repo, %{title: "x"},
                 base_url: base,
                 max_retries: 3,
                 retry_delay_ms: 5
               )

      assert Agent.get(counter, & &1) == 2
    end

    test "Bypass.down → NetworkError", %{bypass: bypass, base: base} do
      stub_token(bypass)
      # Warm the token cache while Bypass is up, so the connection-refused
      # condition we assert lands on the REST call, not the token fetch.
      assert {:ok, _} = Auth.token()
      Bypass.down(bypass)

      assert {:error, %NetworkError{}} =
               Client.create_issue(@repo, %{title: "x"},
                 base_url: base,
                 max_retries: 1,
                 retry_delay_ms: 5,
                 timeout: 200
               )
    end
  end

  describe "auth misconfiguration" do
    test "missing private key → AuthError before any HTTP", %{base: base} do
      Application.put_env(
        :barkpark,
        Barkpark.Plugins.Github,
        app_id: @app_id,
        installation_id: @installation_id,
        private_key: nil,
        api_base: base,
        github_api_base: base
      )

      Auth.invalidate()

      assert {:error, %AuthError{status: 0, message: "GitHub App private key not configured"}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
    end

    test "unparseable private key → AuthError", %{base: base} do
      Application.put_env(
        :barkpark,
        Barkpark.Plugins.Github,
        app_id: @app_id,
        installation_id: @installation_id,
        private_key: "-----BEGIN RSA PRIVATE KEY-----\nnot-a-key\n-----END RSA PRIVATE KEY-----",
        api_base: base,
        github_api_base: base
      )

      Auth.invalidate()

      assert {:error, %AuthError{message: "GitHub App private key invalid"}} =
               Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
    end
  end

  describe "credential leak guard" do
    test "installation token never appears in captured logs", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 403, ~s({"message":"forbidden","token":"#{@inst_token}"}))
      end)

      log =
        capture_log(fn ->
          {:error, err} = Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)
          require Logger
          Logger.error("github client error: #{inspect(err)}")
        end)

      refute log =~ @inst_token
    end
  end
end
