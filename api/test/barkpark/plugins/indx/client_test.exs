defmodule Barkpark.Plugins.Indx.ClientTest do
  # async: false because Auth is a singleton GenServer and tests mutate
  # Application env for credentials. Mirrors the Bokbasen client test.
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Indx.{Auth, Client}
  alias Barkpark.Plugins.Indx.Errors.{AuthError, IndexError, NetworkError, SearchError}

  @moduletag :indx_client

  @email "admin@indx.co"
  @password "Admin123!@#"
  @jwt "test-indx-jwt-token"
  @ds "bp_production_v1"

  setup do
    Process.flag(:trap_exit, true)

    # Auth runs in its own process and reads Settings via the Repo.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    prior = Application.get_env(:barkpark, Barkpark.Plugins.Indx)

    Application.put_env(:barkpark, Barkpark.Plugins.Indx,
      api_base: base,
      user_email: @email,
      user_password: @password
    )

    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.Indx, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Indx)
      end

      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    end)

    {:ok, bypass: bypass, base: base}
  end

  defp stub_login(bypass, counter \\ nil) do
    Bypass.stub(bypass, "POST", "/api/Login", fn conn ->
      if counter, do: Agent.update(counter, &(&1 + 1))

      Plug.Conn.resp(conn, 200, Jason.encode!(%{"token" => @jwt}))
    end)
  end

  test "create_or_open hits PUT /api/CreateOrOpen/{ds} with bearer", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "PUT", "/api/CreateOrOpen/#{@ds}", fn conn ->
      assert ["Bearer " <> @jwt] = Plug.Conn.get_req_header(conn, "authorization")
      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert :ok = Client.create_or_open(@ds, base_url: base)
  end

  test "set_searchable_fields sends camelCase ValueTuple array", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "PUT", "/api/SetSearchableFields/#{@ds}", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [%{"item1" => "title", "item2" => 0}, %{"item1" => "_id", "item2" => 2}] =
               Jason.decode!(body)

      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert :ok =
             Client.set_searchable_fields(@ds, [{"title", 0}, {"_id", 2}], base_url: base)
  end

  test "load_string sends body as text/plain (not application/json)", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "PUT", "/api/LoadString/#{@ds}", fn conn ->
      assert ["text/plain"] = Plug.Conn.get_req_header(conn, "content-type")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [%{"id" => 1, "_id" => "p1"}] = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert :ok = Client.load_string(@ds, [%{"id" => 1, "_id" => "p1"}], base_url: base)
  end

  test "index_dataset hits GET /api/IndexDataSet/{ds}", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "GET", "/api/IndexDataSet/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert :ok = Client.index_dataset(@ds, base_url: base)
  end

  test "get_status decodes the status body", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "GET", "/api/GetStatus/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"status" => "ready"}))
    end)

    assert {:ok, %{"status" => "ready"}} = Client.get_status(@ds, base_url: base)
  end

  test "get_number_of_json_records parses the integer count", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "GET", "/api/GetNumberOfJsonRecordsInDb/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 200, "42")
    end)

    assert {:ok, 42} = Client.get_number_of_json_records(@ds, base_url: base)
  end

  test "search posts CloudQuery and returns records", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "POST", "/api/Search/#{@ds}", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["text"] == "elixir phoenix"
      assert decoded["maxNumberOfRecordsToReturn"] == 30

      records = %{"records" => [%{"documentKey" => 7, "score" => 200}]}
      Plug.Conn.resp(conn, 200, Jason.encode!(records))
    end)

    assert {:ok, [%{"documentKey" => 7, "score" => 200}]} =
             Client.search(@ds, "elixir phoenix", base_url: base)
  end

  test "get_json posts the key array and returns docs", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "POST", "/api/GetJson/#{@ds}", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [7, 9] = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, Jason.encode!([%{"_id" => "p1", "_type" => "post"}]))
    end)

    assert {:ok, [%{"_id" => "p1", "_type" => "post"}]} =
             Client.get_json(@ds, [7, 9], base_url: base)
  end

  test "delete_dataset hits DELETE /api/DeleteDataSet/{ds}", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "DELETE", "/api/DeleteDataSet/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert :ok = Client.delete_dataset(@ds, base_url: base)
  end

  test "401 invalidates the token and retries once with a fresh login", %{
    bypass: bypass,
    base: base
  } do
    {:ok, login_counter} = Agent.start_link(fn -> 0 end)
    {:ok, call_counter} = Agent.start_link(fn -> 0 end)
    stub_login(bypass, login_counter)

    Bypass.expect(bypass, "GET", "/api/IndexDataSet/#{@ds}", fn conn ->
      n = Agent.get_and_update(call_counter, fn c -> {c, c + 1} end)
      # First call → 401 (forces invalidate + re-login + retry); second → 200.
      if n == 0 do
        Plug.Conn.resp(conn, 401, "unauthorized")
      else
        Plug.Conn.resp(conn, 200, "{}")
      end
    end)

    assert :ok = Client.index_dataset(@ds, base_url: base)
    # One login for the first attempt, a second after invalidate.
    assert Agent.get(login_counter, & &1) == 2
    assert Agent.get(call_counter, & &1) == 2
  end

  test "a persistent 401 surfaces as AuthError after one retry", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect(bypass, "GET", "/api/IndexDataSet/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 401, "nope")
    end)

    assert {:error, %AuthError{status: 401}} = Client.index_dataset(@ds, base_url: base)
  end

  test "a 500 maps to IndexError on the index path", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect(bypass, "GET", "/api/IndexDataSet/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, %IndexError{status: 500}} = Client.index_dataset(@ds, base_url: base)
  end

  test "a 500 maps to SearchError on the query path", %{bypass: bypass, base: base} do
    stub_login(bypass)

    Bypass.expect(bypass, "POST", "/api/Search/#{@ds}", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, %SearchError{status: 500}} = Client.search(@ds, "x", base_url: base)
  end

  test "a transport failure on the op (login ok) maps to NetworkError", %{base: base} do
    # Two bypasses: a live one for Login, a downed one for the op, so the
    # transport failure lands on the request path (not on login). The client
    # takes a single base_url, so we drive login via Application env (which
    # Auth reads) and point the op at the dead port via base_url.
    login_bypass = Bypass.open()
    login_base = "http://localhost:#{login_bypass.port}"
    stub_login(login_bypass)

    Application.put_env(:barkpark, Barkpark.Plugins.Indx,
      api_base: login_base,
      user_email: @email,
      user_password: @password
    )

    Auth.invalidate()
    # Warm the token cache against the live login bypass...
    assert {:ok, _jwt} = Auth.token()

    # ...then hit a dead op endpoint. Login is cached, so do_request goes
    # straight to the (refused) op URL → NetworkError.
    dead = Bypass.open()
    dead_base = "http://localhost:#{dead.port}"
    Bypass.down(dead)

    assert {:error, %NetworkError{}} = Client.create_or_open(@ds, base_url: dead_base)

    # base unused here but kept for setup parity.
    _ = base
  end
end
