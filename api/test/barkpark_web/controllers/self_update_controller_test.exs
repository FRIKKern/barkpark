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
    body = scoped_conn() |> admin_conn() |> get("/v1/admin/self-update") |> json_response(200)

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

    # THE NON-DESTRUCTIVE ARMING PROBE (dr-bl-w7). `state` is the RUN's state and
    # reads "idle" identically on an armed box and an unarmed one — so before
    # this key the control plane could learn a box was unarmed ONLY by POSTing,
    # and that POST's 503 is what `AutoupdateRolloutWorker` (:178) answers with
    # `Registry.pause_autoupdate/1` — a pause no code path anywhere clears (the
    # only writer of `autoupdate_paused: false` is the admin-and-audited
    # PATCH /v1/barkparks/:id/autoupdate). The only probe was the destructive one.
    #
    # `apply_enabled` reports `Runner.enabled?/0`, i.e. the RUNNING BEAM's
    # boot-frozen `Application.get_env` value — NOT what the env file says. A box
    # whose env file gained BARKPARK_SELF_UPDATE_APPLY=1 but was never restarted
    # still reports false here, which is the whole point: it is the state the
    # 503 is decided from.
    test "GET reports apply_enabled=false, and that PREDICTS the POST 503", %{conn: conn} do
      body = conn |> admin_conn() |> get("/v1/admin/self-update") |> json_response(200)

      assert body["apply_enabled"] == false,
             "GET must report apply_enabled=false on an unarmed box — it is the control " <>
               "plane's only NON-DESTRUCTIVE arming probe. Without it the rollout worker " <>
               "can discover 'unarmed' only by triggering, and that trigger's 503 pauses " <>
               "the box permanently (worker :178 → Registry.pause_autoupdate/1, cleared " <>
               "only by a human PATCH). Got: #{inspect(body["apply_enabled"])}"

      # Same box, same tick: the prediction must match the destructive outcome.
      resp = conn |> admin_conn() |> post("/v1/admin/self-update")

      assert resp.status == 503,
             "apply_enabled=false must mean the POST 503s — a probe that disagrees with " <>
               "the trigger is worse than no probe."

      assert Jason.decode!(resp.resp_body)["error"]["code"] == "feature_not_configured"
    end
  end

  describe "enabled runner" do
    # The other polarity of the probe: an ARMED box says so without being
    # triggered. Both polarities are required — a key hardcoded to either value
    # would pass one test and fail the other.
    test "GET reports apply_enabled=true on an armed box, with no trigger", %{conn: conn} do
      put_runner_cfg(enabled: true, command: {"bash", ["-c", "true"]})

      body = conn |> admin_conn() |> get("/v1/admin/self-update") |> json_response(200)

      assert body["apply_enabled"] == true,
             "an armed box must be readable as armed WITHOUT a trigger. Got: " <>
               inspect(body["apply_enabled"])

      # The probe is read-only: it must not have started anything.
      assert body["state"] in ["idle", "done"]
    end

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

    test "GET status carries the run mode", %{conn: conn} do
      put_runner_cfg(enabled: true, command: {"bash", ["-c", "echo hi"]})
      assert conn |> admin_conn() |> post("/v1/admin/self-update") |> Map.get(:status) == 202
      done = await_done()
      assert done["mode"] == "self_update"
    end
  end

  # A preflight stub that exits `code` and (on 0) echoes a target sha. Tests
  # NEVER shell out to the real deploy script — only these bash stubs.
  @sha "0123456789abcdef0123456789abcdef01234567"

  defp preflight_ok,
    do: {"bash", ["-c", "echo TARGET_SLOT=green; echo TARGET_SHA=#{@sha}; exit 0"]}

  defp preflight_exit(code), do: {"bash", ["-c", "exit #{code}"]}

  describe "rollback — auth gating" do
    test "POST /v1/admin/rollback returns 401 without a token", %{conn: conn} do
      assert post(conn, "/v1/admin/rollback").status == 401
    end

    test "POST /v1/admin/rollback returns 403 for a non-admin token", %{conn: conn} do
      assert conn |> junior_conn() |> post("/v1/admin/rollback") |> Map.get(:status) == 403
    end
  end

  describe "rollback — disabled (fail-closed default)" do
    test "POST returns 503 feature_not_configured", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 503
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "feature_not_configured"
    end
  end

  describe "rollback — typed preflight refusals" do
    test "no previous slot (preflight exit 21) → 409 no_previous_slot", %{conn: conn} do
      put_runner_cfg(enabled: true, rollback_preflight_command: preflight_exit(21))
      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "no_previous_slot"
    end

    test "unsupported box (preflight exit 22) → 409 not_supported", %{conn: conn} do
      put_runner_cfg(enabled: true, rollback_preflight_command: preflight_exit(22))
      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_supported"
    end

    test "script lock held (preflight exit 23) → 409 already_running", %{conn: conn} do
      put_runner_cfg(enabled: true, rollback_preflight_command: preflight_exit(23))
      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "already_running"
    end

    test "exit 0 with no TARGET_SHA fails CLOSED → 500, never a flip to garbage", %{conn: conn} do
      # Preflight succeeds but prints no sha — we must refuse, not spawn.
      put_runner_cfg(
        enabled: true,
        rollback_preflight_command: {"bash", ["-c", "echo no-sha-here; exit 0"]},
        rollback_command: {"bash", ["-c", "echo SHOULD-NOT-RUN"]}
      )

      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 500
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "rollback_preflight_failed"
      # The mutating run never started.
      assert Runner.status().state in [:idle, :done]
      refute Runner.running?()
    end
  end

  describe "rollback — happy path" do
    test "POST 202 returns the preflight target_sha and spawns the async run", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        rollback_preflight_command: preflight_ok(),
        rollback_command: {"bash", ["-c", "echo rolled-back-line"]}
      )

      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 202
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == "started"
      assert body["target_sha"] == @sha

      done = await_done()
      assert done["state"] == "done"
      assert done["exit_code"] == 0
      assert done["mode"] == "rollback"
      assert "rolled-back-line" in done["log"]
      # The command itself is never exposed — only its output lines.
      refute Map.has_key?(done, "command")
    end
  end

  describe "rollback — shared single-flight with self-update" do
    test "rollback while a self-update run is in flight returns 409", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        command: {"bash", ["-c", "sleep 2"]},
        rollback_preflight_command: preflight_ok(),
        rollback_command: {"bash", ["-c", "echo should-not-run"]}
      )

      # Start a self-update, then a rollback collides on the shared run slot.
      assert conn |> admin_conn() |> post("/v1/admin/self-update") |> Map.get(:status) == 202

      resp = conn |> admin_conn() |> post("/v1/admin/rollback")
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "already_running"
    end
  end
end
