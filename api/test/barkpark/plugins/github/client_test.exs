defmodule Barkpark.Plugins.Github.ClientTest do
  # async: false because Auth is a singleton GenServer and the tests
  # mutate Application env for credentials.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Github.Auth
  alias Barkpark.Plugins.Github.Client
  alias Barkpark.TestSupport.BlackHole

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

    # The plugin's `register_workers/1` now boot-starts the singleton `Auth`
    # (folded into the boot supervision tree via the plugin disk-walk, like
    # `Bokbasen.Auth`). Reusing that live singleton — rather than
    # `start_supervised!(Auth)`, which would clash on the registered name — and
    # invalidating its token cache so this test's Bypass-backed credentials take
    # effect is the established bokbasen `client_test` pattern.
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

  describe "get_issue/2" do
    test "GETs the issue and returns its current state", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.expect(bypass, "GET", "/repos/#{@repo}/issues/42", fn conn ->
        # A GET carries no request body — the verb must not send JSON.
        assert {:ok, "", _conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "number" => 42,
            "title" => "Current title",
            "state" => "open",
            "labels" => [%{"name" => "bug"}]
          })
        )
      end)

      assert {:ok, issue} =
               Client.get_issue(@repo, 42, base_url: base, max_retries: 0)

      assert issue["number"] == 42
      assert issue["title"] == "Current title"
      assert issue["state"] == "open"
    end

    test "404 → NotFound (issue deleted/transferred)", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/999", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:error, %NotFound{status: 404}} =
               Client.get_issue(@repo, 999, base_url: base, max_retries: 0)
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

  describe "graphql/3" do
    test "POSTs query+variables to /graphql and returns the data payload",
         %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/graphql", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => "PVTI_x"}}}
          })
        )
      end)

      assert {:ok, %{"addProjectV2ItemById" => %{"item" => %{"id" => "PVTI_x"}}}} =
               Client.graphql(
                 "mutation($id:ID!){ addProjectV2ItemById(input:{contentId:$id}){ item { id } } }",
                 %{"id" => "I_abc"},
                 base_url: base,
                 max_retries: 0
               )

      body = Agent.get(body_ref, & &1)
      assert body["query"] =~ "addProjectV2ItemById"
      assert body["variables"] == %{"id" => "I_abc"}
    end

    test "defaults variables to an empty map", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/graphql", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"viewer" => %{"login" => "octocat"}}}))
      end)

      assert {:ok, %{"viewer" => %{"login" => "octocat"}}} =
               Client.graphql("query { viewer { login } }", %{}, base_url: base, max_retries: 0)

      assert Agent.get(body_ref, & &1)["variables"] == %{}
    end

    test "a 200 carrying a non-empty errors array → NetworkError{reason: {:graphql, _}}",
         %{bypass: bypass, base: base} do
      stub_token(bypass)

      errors = [%{"message" => "Field 'bogus' doesn't exist", "type" => "INVALID"}]

      Bypass.stub(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        # GraphQL returns 200 OK even for a query-level error — the wrinkle.
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => nil, "errors" => errors}))
      end)

      assert {:error, %NetworkError{reason: {:graphql, ^errors}, endpoint: endpoint}} =
               Client.graphql("query { bogus }", %{}, base_url: base, max_retries: 0)

      assert endpoint =~ "/graphql"
    end

    test "a 403 with rate headers → RateLimitError (classified as a REST verb)",
         %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, ~s({"message":"secondary rate limit"}))
      end)

      assert {:error, %RateLimitError{}} =
               Client.graphql("query { viewer { login } }", %{}, base_url: base, max_retries: 0)
    end
  end

  describe "add_sub_issue/4" do
    test "POSTs the sub_issue_id to the /sub_issues path", %{bypass: bypass, base: base} do
      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/repos/#{@repo}/issues/7/sub_issues", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{"number" => 7, "sub_issues_summary" => %{"total" => 1}})
        )
      end)

      # parent = number 7, child = its DATABASE id (not its number).
      assert {:ok, %{"number" => 7}} =
               Client.add_sub_issue(@repo, 7, 55_667_788, base_url: base, max_retries: 0)

      assert Agent.get(body_ref, & &1) == %{"sub_issue_id" => 55_667_788}
    end

    test "a 422 (already a sub-issue) surfaces as NetworkError{reason: {:http, 422}}",
         %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues/7/sub_issues", fn conn ->
        Plug.Conn.resp(conn, 422, ~s({"message":"Sub-issue already added"}))
      end)

      # NOT special-cased here — the Relations caller maps 422 → :ok.
      assert {:error, %NetworkError{reason: {:http, 422}}} =
               Client.add_sub_issue(@repo, 7, 55_667_788, base_url: base, max_retries: 0)
    end

    test "a 403 with rate headers → RateLimitError", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues/7/sub_issues", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "17")
        |> Plug.Conn.resp(403, ~s({"message":"secondary rate limit"}))
      end)

      assert {:error, %RateLimitError{retry_after: 17}} =
               Client.add_sub_issue(@repo, 7, 55_667_788, base_url: base, max_retries: 0)
    end
  end

  # Same defect, same shape as the bokbasen twin — both clients now route the
  # decision through `Barkpark.Net.RetrySafety`. A timed-out create_issue POST
  # minted up to 3 GitHub issues for ONE task; `MirrorJob`'s Oban-level dedup
  # cannot see it, because it happens inside one `create_issue/3` call.
  describe "retry safety — a timed-out-but-ACCEPTED write is not replayed" do
    test "create_issue POST reaches the server exactly ONCE when the response times out",
         %{bypass: bypass} do
      stub_token(bypass)
      # Warm the installation token against Bypass; the black hole answers
      # nothing, so the client must not need it for the token leg.
      assert {:ok, _} = Auth.token()

      {acceptor, base, hits} = BlackHole.start()
      on_exit(fn -> BlackHole.stop(acceptor) end)

      assert {:error, %NetworkError{reason: :timeout}} =
               Client.create_issue(@repo, %{title: "dup me"},
                 base_url: base,
                 max_retries: 3,
                 retry_delay_ms: 5,
                 timeout: 300
               )

      # RED-BEFORE (guard reverted): 4 — four GitHub issues for ONE task.
      assert hits.() == 1
    end

    test "get_issue GET IS still replayed on the same timeout — the guard is method-scoped",
         %{bypass: bypass} do
      stub_token(bypass)
      assert {:ok, _} = Auth.token()

      {acceptor, base, hits} = BlackHole.start()
      on_exit(fn -> BlackHole.stop(acceptor) end)

      assert {:error, %NetworkError{reason: :timeout}} =
               Client.get_issue(@repo, 42,
                 base_url: base,
                 max_retries: 2,
                 retry_delay_ms: 5,
                 timeout: 300
               )

      # Non-vacuity: the black hole really does drive the retry loop, so the
      # `== 1` above is the guard refusing — not the stub failing to retry.
      assert hits.() == 3
    end

    test "a 502 (gateway may already have forwarded the POST) is not replayed either",
         %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.resp(conn, 502, "bad gateway")
      end)

      assert {:error, %NetworkError{reason: {:http, 502}}} =
               Client.create_issue(@repo, %{title: "x"},
                 base_url: base,
                 max_retries: 3,
                 retry_delay_ms: 5
               )

      assert Agent.get(counter, & &1) == 1
    end

    test "a 503 (origin-authored, did not process) still retries the POST",
         %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        n = Agent.get_and_update(counter, fn x -> {x, x + 1} end)

        if n == 0 do
          Plug.Conn.resp(conn, 503, "{}")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(201, Jason.encode!(%{"number" => 7}))
        end
      end)

      assert {:ok, %{"number" => 7}} =
               Client.create_issue(@repo, %{title: "x"},
                 base_url: base,
                 max_retries: 3,
                 retry_delay_ms: 5
               )

      assert Agent.get(counter, & &1) == 2
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

  describe "installation-token TTL (real GitHub shape)" do
    test "derives the cache TTL from expires_at (GitHub omits expires_in)",
         %{bypass: bypass, base: base} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # Real GitHub returns `expires_at` (ISO8601), NOT `expires_in`. A future
      # expires_at must yield a positive TTL so the token caches across calls.
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      Bypass.stub(bypass, "POST", @token_path, fn conn ->
        Agent.update(counter, &(&1 + 1))

        Plug.Conn.resp(
          conn,
          201,
          Jason.encode!(%{"token" => @inst_token, "expires_at" => future})
        )
      end)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 1}))
      end)

      assert {:ok, _} = Client.create_issue(@repo, %{title: "a"}, base_url: base, max_retries: 0)
      assert {:ok, _} = Client.create_issue(@repo, %{title: "b"}, base_url: base, max_retries: 0)

      # Cached: the expires_at-derived TTL kept the token, so exactly one fetch.
      assert Agent.get(counter, & &1) == 1
    end

    test "a past expires_at does not cache a dead token forever",
         %{bypass: bypass, base: base} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      # A past expires_at means a broken/skewed timestamp; the token must not be
      # trusted as ~1 h. (It falls back to the default life, but the point is it
      # must never produce a negative expiry that poisons the cache.)
      past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.to_iso8601()

      Bypass.stub(bypass, "POST", @token_path, fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"token" => @inst_token, "expires_at" => past}))
      end)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 1}))
      end)

      assert {:ok, _} = Client.create_issue(@repo, %{title: "a"}, base_url: base, max_retries: 0)
      # Token was still returned (usable this once); no crash on the negative span.
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "base URL config resolution" do
    test "falls back to :api_base when :github_api_base is absent",
         %{bypass: bypass, base: base} do
      # Configure ONLY api_base (the key Auth reads) — Client must reuse it so a
      # single config key can't silently split token-exchange from REST calls.
      Application.put_env(
        :barkpark,
        Barkpark.Plugins.Github,
        app_id: @app_id,
        installation_id: @installation_id,
        private_key: Application.get_env(:barkpark, Barkpark.Plugins.Github)[:private_key],
        api_base: base
      )

      Auth.invalidate()
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 1}))
      end)

      # No :base_url opt and no :github_api_base — resolution must land on api_base.
      assert {:ok, %{"number" => 1}} =
               Client.create_issue(@repo, %{title: "x"}, max_retries: 0)
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
          {:error, err} =
            Client.create_issue(@repo, %{title: "x"}, base_url: base, max_retries: 0)

          require Logger
          Logger.error("github client error: #{inspect(err)}")
        end)

      refute log =~ @inst_token
    end
  end

  # CLASS A (clock-semantics wave, clk-w4-github-backoff-clamp): X-RateLimit-Reset
  # is a peer-transmitted ABSOLUTE epoch, so subtracting local wall clock is the
  # only correct computation — monotonic would be meaningless against GitHub's
  # epoch. The defect is time-as-INPUT: an unbounded peer value (or a backward
  # clock step) fed an Oban {:snooze, n}, which never consumes an attempt, so the
  # job parked effectively forever and leaked a scheduled row the Pruner never
  # reclaims. Severity is availability / row accumulation, NOT authorization, and
  # no caller can influence the timing (base_url resolves from app env only) —
  # rank it below any auth finding. `now` is passed explicitly here, so these are
  # deterministic: no sleeps, no barriers.
  describe "retry_after_seconds/2 clamp" do
    test "x-ratelimit-reset inside the window returns the true remaining seconds" do
      reset = 1_800_000_000
      assert Client.retry_after_seconds([{"x-ratelimit-reset", "#{reset}"}], reset - 10) == 10
    end

    test "an absurdly distant x-ratelimit-reset clamps to the ceiling" do
      # RED-BEFORE: unclamped this returns 10_000_000 (≈ 116 days of park).
      reset = 1_800_000_000

      assert Client.retry_after_seconds([{"x-ratelimit-reset", "#{reset}"}], reset - 10_000_000) ==
               300
    end

    test "a forward clock step past the reset floors to 0" do
      reset = 1_800_000_000
      assert Client.retry_after_seconds([{"x-ratelimit-reset", "#{reset}"}], reset + 5_000) == 0
    end

    test "a hostile bare retry-after is clamped on that arm too" do
      assert Client.retry_after_seconds([{"retry-after", "999999"}], 1_800_000_000) == 300
    end

    test "a sane bare retry-after is passed through unchanged" do
      assert Client.retry_after_seconds([{"retry-after", "42"}], 1_800_000_000) == 42
    end

    test "no rate-limit headers → 0" do
      assert Client.retry_after_seconds([{"content-type", "application/json"}], 1_800_000_000) ==
               0
    end
  end
end
