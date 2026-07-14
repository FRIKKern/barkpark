defmodule BarkparkWeb.SiteDeployControllerTest do
  @moduledoc """
  Contract tests for `/v1/admin/site-deploy` (site-spawner charter D22).

  The seam the control plane calls: it rides the EXISTING `/v1/admin` scope, so
  401 (no token) and 403 (non-admin) come for free from RequireToken +
  RequireAdmin — proving that here is proving there is no new auth surface.
  Then the status contract: 503 fail-closed, 400 on anything that would reach
  argv or the child's env unvalidated, 409 per-slug single-flight, 202 started,
  500 runner_start_failed — and a GET that walks the six stages.
  """
  # async: false — mutates the DeployRunner singleton + Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.DeployRunner

  @admin_token "barkpark-test-site-deploy-admin"
  @junior_token "barkpark-test-site-deploy-junior"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "site-deploy-admin", "test", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "site-deploy-junior", "test", ["read", "write"])

    :ok
  end

  defp admin_conn(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)
  defp junior_conn(conn), do: put_req_header(conn, "authorization", "Bearer " <> @junior_token)

  defp put_runner_cfg(overrides) do
    prior = Application.get_env(:barkpark, DeployRunner)
    Application.put_env(:barkpark, DeployRunner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)
    end)
  end

  defp stub(script), do: {"bash", ["-c", script]}

  defp body(slug, extra \\ %{}) do
    Map.merge(%{"slug" => slug, "build_id" => "b1", "mode" => "deploy"}, extra)
  end

  # Poll GET until the run reports done (cap ~15s); returns the last body.
  defp await_done(slug, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    body =
      build_conn()
      |> admin_conn()
      |> get("/v1/admin/site-deploy", %{"slug" => slug})
      |> json_response(200)

    cond do
      body["state"] == "done" -> body
      System.monotonic_time(:millisecond) >= deadline -> body
      true -> Process.sleep(25) && await_done(slug, deadline)
    end
  end

  # ── auth (inherited from the existing admin scope — zero new auth) ──────

  describe "auth" do
    test "401 without a token", %{conn: conn} do
      assert conn |> post("/v1/admin/site-deploy", body("s")) |> json_response(401)
      assert conn |> get("/v1/admin/site-deploy", %{"slug" => "s"}) |> json_response(401)
    end

    test "403 for a non-admin token", %{conn: conn} do
      assert conn
             |> junior_conn()
             |> post("/v1/admin/site-deploy", body("s"))
             |> json_response(403)

      assert conn
             |> junior_conn()
             |> get("/v1/admin/site-deploy", %{"slug" => "s"})
             |> json_response(403)
    end
  end

  # ── fail-closed ─────────────────────────────────────────────────────────

  describe "POST — fail-closed" do
    test "503 feature_not_configured when the apply flag is off (the default)", %{conn: conn} do
      refute DeployRunner.enabled?()

      assert %{"error" => %{"code" => "feature_not_configured", "message" => message}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("s"))
               |> json_response(503)

      assert message =~ "BARKPARK_SITE_DEPLOY_APPLY=1"
    end

    test "503 wins over a malformed body — a box that cannot deploy says so first", %{conn: conn} do
      assert %{"error" => %{"code" => "feature_not_configured"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{"slug" => "../etc"})
               |> json_response(503)
    end
  end

  # ── validation (nothing reaches argv or the child env unvalidated) ──────

  describe "POST — validation" do
    setup do
      put_runner_cfg(enabled: true, command: stub("exit 0"))
      :ok
    end

    test "400 invalid_slug", %{conn: conn} do
      for bad <- ["../../etc/passwd", "Site", "a b", "-x"] do
        assert %{"error" => %{"code" => "invalid_slug"}} =
                 conn
                 |> admin_conn()
                 |> post("/v1/admin/site-deploy", %{"slug" => bad, "build_id" => "b1"})
                 |> json_response(400)
      end
    end

    test "400 invalid_build_id (missing, or path-shaped)", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_build_id"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{"slug" => "ok"})
               |> json_response(400)

      assert %{"error" => %{"code" => "invalid_build_id"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{"slug" => "ok", "build_id" => "../../x"})
               |> json_response(400)
    end

    test "400 invalid_mode", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_mode"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("ok", %{"mode" => "rm-rf"}))
               |> json_response(400)
    end

    test "400 invalid_env — an unknown var is refused, never silently dropped", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_env"}} =
               conn
               |> admin_conn()
               |> post(
                 "/v1/admin/site-deploy",
                 body("ok", %{"env" => %{"LD_PRELOAD" => "/tmp/evil.so"}})
               )
               |> json_response(400)
    end

    test "400 invalid_slug on GET without a slug", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_slug"}} =
               conn |> admin_conn() |> get("/v1/admin/site-deploy") |> json_response(400)
    end
  end

  # ── the happy path: six stages, then live ──────────────────────────────

  describe "POST — 202 + the six visible stages" do
    test "a deploy walks PLAN→BUILD→STAGE→HEALTH→SWITCH→RETIRE and GET reports them", %{
      conn: conn
    } do
      put_runner_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=started build_id=b1'
          echo 'npm install output…'
          echo 'BPSTAGE name=BUILD status=ok build_id=b1'
          echo 'BPSTAGE name=STAGE status=ok build_id=b1'
          echo 'BPSTAGE name=HEALTH status=ok build_id=b1'
          echo 'BPSTAGE name=SWITCH status=ok build_id=b1'
          echo 'BPSTAGE name=RETIRE status=ok build_id=b1'
          exit 0
          """)
      )

      assert %{"ok" => true, "status" => %{"state" => state, "slug" => "my-blog"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("my-blog"))
               |> json_response(202)

      assert state in ["running", "done"]

      done = await_done("my-blog")

      assert done["state"] == "done"
      assert done["exit_code"] == 0
      assert done["failure_reason"] == nil
      assert done["mode"] == "deploy"
      assert done["build_id"] == "b1"

      assert Enum.map(done["stages"], & &1["name"]) ==
               ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)

      assert Enum.all?(done["stages"], &(&1["status"] == "ok"))
      assert Enum.all?(done["stages"], &is_binary(&1["at"]))
      assert Enum.any?(done["log"], &String.contains?(&1, "npm install output"))
    end

    test "a HEALTH failure is honest — real reason, non-zero exit, never a switch", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=ok build_id=b1'
          echo 'BPSTAGE name=STAGE status=ok build_id=b1'
          echo 'HEALTH: index.html is missing the bp-build-id marker'
          echo 'BPSTAGE name=HEALTH status=failed build_id=b1 detail="bp-build-id marker is missing but this deploy ships b1"'
          echo 'HEALTH gate FAILED for build b1 — live release untouched, no switch (fail closed)'
          exit 14
          """)
      )

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", body("sick-site"))
             |> json_response(202)

      done = await_done("sick-site")

      assert done["state"] == "done"
      assert done["exit_code"] == 14
      assert done["failure_reason"] =~ "HEALTH gate failed"
      assert done["failure_reason"] =~ "bp-build-id marker"
      # A broken build never reaches a visitor: no SWITCH stage was reported.
      refute Enum.any?(done["stages"], &(&1["name"] == "SWITCH"))
      assert %{"name" => "HEALTH", "status" => "failed"} = List.last(done["stages"])

      # …and the WHY travels on the wire. The control plane renders this key as the
      # failed stage's message and `bp cloud site` prints it; if it is absent the
      # user gets a canned "the build failed" and the marker miss is invisible.
      assert List.last(done["stages"])["detail"] =~ "bp-build-id marker is missing"
    end

    test "mode=rollback runs the rollback command", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        command: stub("echo DEPLOY; exit 0"),
        rollback_command: stub("echo 'BPSTAGE name=SWITCH status=ok build_id=prev'; exit 0")
      )

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", %{"slug" => "rb-site", "mode" => "rollback"})
             |> json_response(202)

      done = await_done("rb-site")

      assert done["state"] == "done"
      assert done["mode"] == "rollback"
      assert done["exit_code"] == 0
      assert [%{"name" => "SWITCH", "status" => "ok"}] = done["stages"]
    end
  end

  # ── single-flight ───────────────────────────────────────────────────────

  describe "POST — 409 single-flight is PER SLUG" do
    test "the same slug twice is 409; a different slug is 202", %{conn: conn} do
      put_runner_cfg(enabled: true, command: stub("sleep 0.6; exit 0"))

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", body("busy"))
             |> json_response(202)

      assert %{"error" => %{"code" => "already_running", "message" => message}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("busy", %{"build_id" => "b2"}))
               |> json_response(409)

      assert message =~ "busy"

      # A second SITE is unaffected — this is the whole reason for a per-slug slot.
      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", body("not-busy"))
             |> json_response(202)

      await_done("busy")
      await_done("not-busy")
    end
  end

  # ── start failure ───────────────────────────────────────────────────────

  describe "POST — 500 runner_start_failed" do
    test "the feature is ON but the command cannot spawn", %{conn: conn} do
      put_runner_cfg(enabled: true, command: {"bp-no-such-executable-9f2a", []})

      assert %{"error" => %{"code" => "runner_start_failed"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("cant-start"))
               |> json_response(500)
    end
  end

  # ── status ──────────────────────────────────────────────────────────────

  describe "GET" do
    test "a slug that has never deployed is an honest idle, not a 404", %{conn: conn} do
      assert %{
               "state" => "idle",
               "slug" => "brand-new",
               "stages" => [],
               "log" => [],
               "exit_code" => nil,
               "failure_reason" => nil,
               "started_at" => nil,
               "finished_at" => nil
             } =
               conn
               |> admin_conn()
               |> get("/v1/admin/site-deploy", %{"slug" => "brand-new"})
               |> json_response(200)
    end

    test "the response never leaks the configured command", %{conn: conn} do
      put_runner_cfg(enabled: true, command: stub("echo hi; exit 0"))

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", body("no-leak"))
             |> json_response(202)

      done = await_done("no-leak")

      refute Map.has_key?(done, "command")
      assert Map.keys(done) |> Enum.sort() == ~w(
               build_id content_rev exit_code failure_reason finished_at log mode
               slug stages started_at state
             )
    end
  end
end
