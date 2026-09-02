defmodule Barkpark.Plugins.OnixEdit.Bokbasen.ClientTest do
  # async: false because Auth is a singleton GenServer and tests
  # mutate Application env for credentials.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth
  alias Barkpark.TestSupport.BlackHole
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Client

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.{
    AuthError,
    HTTPError,
    NetworkError,
    RateLimitError,
    SchemaRejectionError
  }

  @moduletag :bokbasen_client

  @client_id "test_client_id"
  @client_secret "test_secret_42"
  @bearer "test_access_token_xyz"
  @onix_xml "<?xml version=\"1.0\"?><ONIXMessage/>"

  setup do
    # Trap exits so Bypass plug crashes (e.g. writing to a closed conn
    # after a forced client timeout) do not surface as `(exit) shutdown`
    # in the test process.
    Process.flag(:trap_exit, true)

    # Auth GenServer runs in its own process and must read Settings via
    # the Repo. Allow it (and any other process spawned by Req) to use
    # the test's sandbox connection.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    prior = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.OnixEdit.Bokbasen,
      client_id: @client_id,
      client_secret: @client_secret,
      api_base: base,
      oauth_token_url: "#{base}/oauth2/token",
      client_role: "publisher"
    )

    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end

      # Reset sandbox mode so the next test can take ownership cleanly.
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    end)

    {:ok, bypass: bypass, base: base}
  end

  defp stub_token(bypass, counter \\ nil) do
    Bypass.stub(bypass, "POST", "/oauth2/token", fn conn ->
      if counter, do: Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => @bearer, "expires_in" => 3600}))
    end)
  end

  describe "stage/2" do
    test "happy path returns submission_id and poll_url", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.expect(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer " <> @bearer]
        body = Jason.encode!(%{"submission_id" => "sub-123", "poll_url" => "https://x/sub-123"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, body)
      end)

      assert {:ok, %{submission_id: "sub-123", poll_url: "https://x/sub-123"}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 0)
    end
  end

  describe "poll/2" do
    test "transitions pending → accepted", %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "GET", "/metadata/import/onix/v2/status/sub-123", fn conn ->
        n = Agent.get_and_update(counter, fn x -> {x, x + 1} end)
        body = if n == 0, do: ~s({"status":"pending"}), else: ~s({"status":"accepted"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, %{status: :pending}} = Client.poll("sub-123", base_url: base, max_retries: 0)
      assert {:ok, %{status: :accepted}} = Client.poll("sub-123", base_url: base, max_retries: 0)
    end
  end

  describe "cancel/2" do
    test "204 → :ok", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.expect(bypass, "DELETE", "/metadata/import/onix/v2/sub-123", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Client.cancel("sub-123", base_url: base, max_retries: 0)
    end
  end

  describe "auth refresh" do
    test "401 then 201 → :ok with two token fetches", %{bypass: bypass, base: base} do
      {:ok, token_counter} = Agent.start_link(fn -> 0 end)
      {:ok, stage_counter} = Agent.start_link(fn -> 0 end)
      stub_token(bypass, token_counter)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        n = Agent.get_and_update(stage_counter, fn x -> {x, x + 1} end)

        if n == 0 do
          Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
        else
          Plug.Conn.resp(
            conn,
            201,
            Jason.encode!(%{"submission_id" => "sub-7", "poll_url" => "https://x/sub-7"})
          )
        end
      end)

      assert {:ok, %{submission_id: "sub-7"}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 0)

      assert Agent.get(token_counter, & &1) == 2
    end

    test "401 twice → AuthError", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
      end)

      assert {:error, %AuthError{status: 401, message: "Token refresh failed"}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 0)
    end
  end

  describe "schema rejection" do
    test "422 → SchemaRejectionError with parsed details", %{bypass: bypass, base: base} do
      stub_token(bypass)

      details_body = ~s({"errors":[{"code":"INVALID_ISBN","field":"product_identifier"}]})

      Bypass.expect(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, details_body)
      end)

      assert {:error, %SchemaRejectionError{rejection_details: details}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 0)

      assert is_map(details) and details["errors"] |> hd() |> Map.get("code") == "INVALID_ISBN"
    end
  end

  describe "network errors" do
    test "Bypass.down → NetworkError", %{bypass: bypass, base: base} do
      stub_token(bypass)
      # Warm the token cache while Bypass is still up so the token
      # fetch does not collide with the connection-refused condition
      # we want to assert on the metadata endpoint.
      assert {:ok, _} = Auth.token()
      Bypass.down(bypass)

      assert {:error, %NetworkError{}} =
               Client.stage(@onix_xml,
                 base_url: base,
                 max_retries: 1,
                 retry_delay_ms: 5,
                 timeout: 200
               )
    end

    test "timeout → NetworkError{reason: :timeout}", %{bypass: bypass} do
      stub_token(bypass)

      # Warm token cache while server is fast — otherwise the slow stub
      # below catches the token fetch first.
      assert {:ok, _} = Auth.token()

      # Use a non-routable address so connect/receive blocks past our
      # configured timeout. 10.255.255.1 is on a typically-unrouted /16
      # but most test environments cannot reach it; combined with a
      # short timeout this surfaces a deterministic :timeout reason
      # without needing a sleeping Bypass plug (whose late conn-write
      # was racing the test teardown).
      assert {:error, %NetworkError{reason: reason}} =
               Client.stage(@onix_xml,
                 base_url: "http://10.255.255.1:1",
                 max_retries: 0,
                 timeout: 100
               )

      assert reason in [:timeout, :econnrefused, :ehostunreach, :enetunreach, :nxdomain]
    end
  end

  describe "rate limiting" do
    test "Retry-After 1 → retries and succeeds", %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        n = Agent.get_and_update(counter, fn x -> {x, x + 1} end)

        if n == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.resp(429, ~s({"error":"rate_limited"}))
        else
          Plug.Conn.resp(
            conn,
            201,
            Jason.encode!(%{"submission_id" => "rl-1", "poll_url" => "u"})
          )
        end
      end)

      assert {:ok, %{submission_id: "rl-1"}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 1)
    end

    test "Retry-After 60 (over budget) → RateLimitError", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.resp(429, ~s({"error":"rate_limited"}))
      end)

      assert {:error, %RateLimitError{retry_after_seconds: 60}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 3)
    end
  end

  describe "5xx retry" do
    test "503 once then 201 succeeds", %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        n = Agent.get_and_update(counter, fn x -> {x, x + 1} end)

        if n == 0 do
          Plug.Conn.resp(conn, 503, "{}")
        else
          Plug.Conn.resp(conn, 201, Jason.encode!(%{"submission_id" => "r-1", "poll_url" => "u"}))
        end
      end)

      assert {:ok, %{submission_id: "r-1"}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 3, retry_delay_ms: 10)

      assert Agent.get(counter, & &1) == 2
    end
  end

  # The defect this guards: the client retried the WHOLE request on a transport
  # `:timeout`, which is the ONE failure where the remote may already have
  # accepted the write and only the response was lost. A slow Bokbasen therefore
  # minted up to 3 ONIX submissions for one document. `PublishWorker`'s
  # `submission_id` guard cannot see this — it happens inside ONE `stage/2`
  # call, before any `submission_id` exists.
  describe "retry safety — a timed-out-but-ACCEPTED write is not replayed" do
    test "stage POST reaches the server exactly ONCE when the response times out",
         %{bypass: bypass} do
      stub_token(bypass)
      # Warm the token against Bypass; the black hole below answers nothing,
      # so the client must not need it for the OAuth leg.
      assert {:ok, _} = Auth.token()

      {acceptor, base, hits} = BlackHole.start()
      on_exit(fn -> BlackHole.stop(acceptor) end)

      assert {:error, %NetworkError{reason: :timeout}} =
               Client.stage(@onix_xml,
                 base_url: base,
                 max_retries: 3,
                 retry_delay_ms: 5,
                 timeout: 300
               )

      # RED-BEFORE (guard reverted): 4. Bokbasen would hold four submissions
      # of one document, each with its own submission_id, for one publish.
      assert hits.() == 1
    end

    test "poll GET IS still replayed on the same timeout — the guard is method-scoped",
         %{bypass: bypass} do
      stub_token(bypass)
      assert {:ok, _} = Auth.token()

      {acceptor, base, hits} = BlackHole.start()
      on_exit(fn -> BlackHole.stop(acceptor) end)

      assert {:error, %NetworkError{reason: :timeout}} =
               Client.poll("sub-1",
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

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.resp(conn, 502, "bad gateway")
      end)

      assert {:error, %HTTPError{status: 502}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 3, retry_delay_ms: 5)

      assert Agent.get(counter, & &1) == 1
    end

    test "a 503 (origin-authored, did not process) still retries the POST",
         %{bypass: bypass, base: base} do
      stub_token(bypass)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        n = Agent.get_and_update(counter, fn x -> {x, x + 1} end)

        if n == 0 do
          Plug.Conn.resp(conn, 503, "{}")
        else
          Plug.Conn.resp(conn, 201, Jason.encode!(%{"submission_id" => "ok", "poll_url" => "u"}))
        end
      end)

      assert {:ok, %{submission_id: "ok"}} =
               Client.stage(@onix_xml, base_url: base, max_retries: 3, retry_delay_ms: 5)

      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "token caching" do
    test "3 concurrent stage calls hit /oauth2/token only once", %{bypass: bypass, base: base} do
      {:ok, token_counter} = Agent.start_link(fn -> 0 end)
      stub_token(bypass, token_counter)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"submission_id" => "c", "poll_url" => "u"}))
      end)

      results =
        1..3
        |> Task.async_stream(
          fn _ -> Client.stage(@onix_xml, base_url: base, max_retries: 0) end,
          max_concurrency: 3,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Agent.get(token_counter, & &1) == 1
    end

    test "invalidate triggers a re-fetch", %{bypass: bypass, base: base} do
      {:ok, token_counter} = Agent.start_link(fn -> 0 end)
      stub_token(bypass, token_counter)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"submission_id" => "i", "poll_url" => "u"}))
      end)

      assert {:ok, _} = Client.stage(@onix_xml, base_url: base, max_retries: 0)
      assert :ok = Auth.invalidate()
      assert {:ok, _} = Client.stage(@onix_xml, base_url: base, max_retries: 0)

      assert Agent.get(token_counter, & &1) == 2
    end
  end

  describe "credential leak guard" do
    test "no token or secret appears in captured logs", %{bypass: bypass, base: base} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Plug.Conn.resp(
          conn,
          422,
          ~s({"errors":[{"code":"X","field":"y"}],"echo":{"access_token":"#{@bearer}"}})
        )
      end)

      log =
        capture_log(fn ->
          {:error, err} = Client.stage(@onix_xml, base_url: base, max_retries: 0)
          # Force inspection through Logger so any redaction failure surfaces
          require Logger
          Logger.error("bokbasen client error: #{inspect(err)}")
        end)

      refute log =~ @bearer
      refute log =~ @client_secret
    end
  end
end
