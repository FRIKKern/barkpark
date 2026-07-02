defmodule BarkparkWeb.SelfUpdateControllerTest do
  @moduledoc """
  Contract tests for `/v1/admin/self-update` (Barkpark.SelfUpdate.Runner).

  Covers: 401 no token, 403 non-admin, 503 when apply is not enabled
  (fail-closed default), the 202 happy path with captured log output, and
  the 409 single-flight guard while a run is in flight.
  """
  # async: false — mutates the Runner singleton GenServer + Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.SelfUpdate.Runner

  @admin_token "barkpark-test-self-update-admin"
  @junior_token "barkpark-test-self-update-junior"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "self-update-admin", "test", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "self-update-junior", "test", ["read", "write"])

    # The Runner is a singleton whose run state outlives each test — make sure
    # no previous run is still in flight before AND after every test.
    await_not_running()
    on_exit(fn -> await_not_running() end)
    :ok
  end

  defp admin_conn(conn),
    do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  defp junior_conn(conn),
    do: put_req_header(conn, "authorization", "Bearer " <> @junior_token)

  # Per-test Runner config override, restored on exit (canonical put_env shape).
  defp put_runner_cfg(overrides) do
    prior = Application.get_env(:barkpark, Runner)
    Application.put_env(:barkpark, Runner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Runner, prior),
        else: Application.delete_env(:barkpark, Runner)
    end)
  end

  # Poll GET until the runner reports "done" (cap ~2s); returns the last body.
  defp await_done(deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    body = build_conn() |> admin_conn() |> get("/v1/admin/self-update") |> json_response(200)

    cond do
      body["state"] == "done" ->
        body

      System.monotonic_time(:millisecond) >= deadline ->
        body

      true ->
        Process.sleep(50)
        await_done(deadline)
    end
  end

  # Direct (non-HTTP) drain used by setup/on_exit — no conn, no sandbox needed.
  defp await_not_running(attempts \\ 60) do
    case Runner.status() do
      %{state: :running} when attempts > 0 ->
        Process.sleep(50)
        await_not_running(attempts - 1)

      _status ->
        :ok
    end
  end

  describe "auth gating" do
    test "GET returns 401 without a token", %{conn: conn} do
      assert get(conn, "/v1/admin/self-update").status == 401
    end

    test "POST returns 403 for non-admin token", %{conn: conn} do
      assert conn |> junior_conn() |> post("/v1/admin/self-update") |> Map.get(:status) == 403
    end

    test "GET returns 403 for non-admin token", %{conn: conn} do
      assert conn |> junior_conn() |> get("/v1/admin/self-update") |> Map.get(:status) == 403
    end
  end

  describe "disabled (fail-closed default)" do
    test "POST returns 503 feature_not_configured", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/admin/self-update")
      assert resp.status == 503
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "feature_not_configured"
    end

    test "GET still reports status when apply is disabled", %{conn: conn} do
      body = conn |> admin_conn() |> get("/v1/admin/self-update") |> json_response(200)
      assert body["state"] in ["idle", "done"]
    end
  end

  describe "enabled runner" do
    test "POST 202 runs the command and GET captures its log", %{conn: conn} do
      put_runner_cfg(enabled: true, command: {"bash", ["-c", "echo line-one; echo line-two"]})

      resp = conn |> admin_conn() |> post("/v1/admin/self-update")
      assert resp.status == 202
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["status"]["state"] in ["running", "done"]

      done = await_done()
      assert done["state"] == "done"
      assert done["exit_code"] == 0
      assert "line-one" in done["log"]
      assert "line-two" in done["log"]
      assert done["started_at"] != nil
      assert done["finished_at"] != nil
      # The configured command is never exposed — only its output lines.
      refute Map.has_key?(done, "command")
    end

    test "second POST while a run is in flight returns 409", %{conn: conn} do
      put_runner_cfg(enabled: true, command: {"bash", ["-c", "sleep 2"]})

      assert conn |> admin_conn() |> post("/v1/admin/self-update") |> Map.get(:status) == 202

      resp = conn |> admin_conn() |> post("/v1/admin/self-update")
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "already_running"
    end
  end
end
