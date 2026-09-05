defmodule BarkparkWeb.SiteDeployControllerTest do
  @moduledoc """
  Contract tests for `/v1/admin/site-deploy` (site-spawner charter D22).

  The seam the control plane calls: it rides the EXISTING `/v1/admin` scope, so
  401 (no token) and 403 (non-admin) come for free from RequireToken +
  RequireAdmin — proving that here is proving there is no new auth surface.
  Then the status contract: 503 fail-closed, 400 on anything that would reach
  argv or the child's env unvalidated, 409 per-slug single-flight, 409
  `box_at_capacity` when the box's one fleet build slot is taken, 202 started,
  500 runner_start_failed — and a GET that walks the six stages.
  """
  # async: false — mutates the DeployRunner singleton + Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.{DeployRunner, Provisioner}

  @admin_token "barkpark-test-site-deploy-admin"
  @junior_token "barkpark-test-site-deploy-junior"

  setup do
    base =
      Path.join(System.tmp_dir!(), "bp-site-controller-#{System.unique_integer([:positive])}")

    sites = Path.join(base, "sites")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"controller-stub"}))

    prior_provisioner = Application.get_env(:barkpark, Provisioner)

    Application.put_env(:barkpark, Provisioner,
      sites_dir: sites,
      template_dir: template
    )

    on_exit(fn ->
      if prior_provisioner,
        do: Application.put_env(:barkpark, Provisioner, prior_provisioner),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

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

  # Take over the Runner's registered name with a door that CANNOT answer a
  # trigger — deterministically, on any machine, at any load.
  #
  # `DeployRunner.trigger/1` resolves the Runner by name and gives up on the
  # call budget (`safe_call/3`). The interceptor sits on that name and:
  #   * `{:trigger, _}` — forwards it to the real Runner off the loop, so the
  #     deploy really is provisioned and spawned, and then DROPS the reply:
  #     the caller is never answered, so its budget always expires;
  #   * everything else — proxied verbatim, reply included, so status polling
  #     still reads the real Runner's real state.
  # Restored on exit. `async: false` (see the case header) is what makes
  # borrowing a singleton's name safe here.
  defp intercept_with_unanswering_door do
    real = Process.whereis(DeployRunner)
    assert is_pid(real), "the DeployRunner singleton must be alive to be intercepted"

    door = spawn(fn -> unanswering_door_loop(real) end)
    Process.unregister(DeployRunner)
    Process.register(door, DeployRunner)

    on_exit(fn ->
      if Process.whereis(DeployRunner) == door, do: Process.unregister(DeployRunner)
      Process.exit(door, :kill)

      if Process.alive?(real) and is_nil(Process.whereis(DeployRunner)),
        do: Process.register(real, DeployRunner)
    end)

    door
  end

  defp unanswering_door_loop(real) do
    receive do
      {:"$gen_call", _from, {:trigger, _req} = msg} ->
        # Real work, no reply: the trigger lands on the box, the caller waits
        # forever. Spawned so status calls stay answerable meanwhile.
        spawn(fn ->
          try do
            GenServer.call(real, msg, 15_000)
          catch
            :exit, _ -> :ok
          end
        end)

      {:"$gen_call", from, msg} ->
        GenServer.reply(from, GenServer.call(real, msg, 15_000))

      other ->
        send(real, other)
    end

    unanswering_door_loop(real)
  end

  defp body(slug, extra \\ %{}) do
    Map.merge(%{"slug" => slug, "build_id" => "b1", "mode" => "deploy"}, extra)
  end

  # Poll GET until the run reports done (cap ~15s); returns the last body.
  defp await_done(slug, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    body =
      scoped_conn()
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

      # D593: it names the CONSENT BOUNDARY, never a flag to flip. A spawned box
      # reaches this arm by construction (nothing in the provisioning path may
      # consent for its owner), so the sentence it answers with is the whole
      # product of that path — and "set BARKPARK_SITE_DEPLOY_APPLY=1" was an
      # instruction to an operator who may not want to follow it.
      assert message =~ "has not consented"
      assert message =~ "third-party site build code"
      # The flag name is the instruction, so its ABSENCE is the assertion.
      refute message =~ "BARKPARK_SITE_DEPLOY_APPLY"
      # …and the operator who DOES want to consent is sent to the thing that
      # checks whether this box can honour it, not to an env var.
      assert message =~ "--site-deploy-preflight"
    end

    test "503 wins over a malformed body — a box that cannot deploy says so first", %{conn: conn} do
      assert %{"error" => %{"code" => "feature_not_configured"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{"slug" => "../etc"})
               |> json_response(503)
    end
  end

  # ── the Runner that did not answer (dr-w8-s2) ───────────────────────────

  # THE CONFLATION, measured on the fleet: a 503 `feature_not_configured` at
  # 5039ms on a box whose BEAM had carried BARKPARK_SITE_DEPLOY_APPLY=1 for 75
  # minutes — and the build it names as never-configured RAN TO COMPLETION. The
  # door's `GenServer.call/2` used the unstated 5_000ms default and converted the
  # resulting exit into `{:error, :disabled}`, the same value the flag-off guard
  # produces, rendered by the same renderer. 207 rows in 24h, wrong about the
  # cause AND the outcome.
  #
  # HOW THE UNANSWERED TRIGGER IS PRODUCED (dr-w13-s4). This used to shrink the
  # answer budget to 1ms against the REAL Runner and bet that provision + spawn
  # would outrun it — a RACE, which lost at random inside a required gate (main
  # was red on it at b00d793c, byte-identical to a green run). A guard that
  # loses at random is worse than one that cannot lose: it teaches the fleet to
  # re-run reds. So the timeout is now produced BY CONSTRUCTION, not by speed:
  # `intercept_with_unanswering_door/0` puts an interceptor on the Runner's
  # registered name that forwards the trigger to the real Runner (the deploy
  # genuinely starts, and finishes — the second half of this test) but NEVER
  # replies to the caller's `$gen_call`. No amount of machine speed can make
  # that call answer, so the 503 below can only fail for the right reason.
  describe "POST — the Runner did not answer" do
    setup do
      put_runner_cfg(
        enabled: true,
        # Any budget expires against a door that never answers; small only so
        # the test is quick. Nothing here races the Runner's real work.
        trigger_call_timeout_ms: 25,
        command: stub("echo 'BPSTAGE name=PLAN status=ok build_id=b1'\nexit 0")
      )
    end

    test "an unanswered trigger is its OWN 503 — it never blames a flag that is set", %{
      conn: conn
    } do
      # The half that makes the old message a lie: the flag IS on.
      assert DeployRunner.enabled?()

      # And the door is guaranteed silent — not merely likely to be slow.
      intercept_with_unanswering_door()

      res =
        conn
        |> admin_conn()
        |> post("/v1/admin/site-deploy", body("slow-blog"))

      assert %{"error" => %{"code" => "deploy_runner_unavailable", "message" => message}} =
               json_response(res, 503)

      # The accusation is gone: this refusal says nothing about configuration.
      refute message =~ "BARKPARK_SITE_DEPLOY_APPLY"
      refute message =~ "not enabled"
      assert message =~ "did not answer"
      # And it is retryable, in the header a client actually honours.
      assert [retry_after] = get_resp_header(res, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n > 0

      # THE SECOND HALF, and the reason the old row was wrong twice: the deploy
      # the door refused to admit to was ALREADY RUNNING, and it finishes.
      done = await_done("slow-blog")
      assert done["state"] == "done"
      assert done["exit_code"] == 0
    end

    test "the flag-off refusal is untouched — the two paths are now distinguishable", %{
      conn: conn
    } do
      # Same shrunken budget, flag off: the guard answers before the call, so
      # this must still be the CONSENT message, byte for byte (D593 re-worded
      # it away from "set BARKPARK_SITE_DEPLOY_APPLY=1"; the code word and the
      # status are unchanged, which is what the ledger classifies on).
      put_runner_cfg(enabled: false)
      refute DeployRunner.enabled?()

      assert %{"error" => %{"code" => "feature_not_configured", "message" => message}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("off-blog"))
               |> json_response(503)

      assert message ==
               "this instance has not consented to run third-party site build code " <>
                 "— a site deploy executes the site's own npm dependency tree " <>
                 "(postinstall scripts included) on this box, so opting in is the " <>
                 "box owner's decision, not a retry; the per-box prerequisites are " <>
                 "checked by `deploy/instance-deploy.sh --site-deploy-preflight`"
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

    test "400 invalid_deploy_mode", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_deploy_mode"}} =
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

  # ── prebuilt artifacts (charter D86/D87) ────────────────────────────────

  # A one-file `dist/` as a .tar.gz plus the digest of those exact bytes.
  defp prebuilt_artifact do
    tar = Path.join(System.tmp_dir!(), "bp-ctl-pb-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(tar) end)

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"index.html", "<h1>pb</h1>"}], [:compressed])

    raw = File.read!(tar)
    {Base.encode64(raw), :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)}
  end

  describe "POST — a prebuilt artifact" do
    test "the 202 echoes prebuilt:true AND the verified digest", %{conn: conn} do
      run_state = Path.join(System.tmp_dir!(), "bp-ctl-run-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(run_state) end)
      {b64, sha} = prebuilt_artifact()

      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      body =
        conn
        |> admin_conn()
        |> post(
          "/v1/admin/site-deploy",
          body("pb-site", %{"artifact_b64" => b64, "artifact_sha256" => sha})
        )
        |> json_response(202)

      assert body["ok"] == true
      assert body["prebuilt"] == true
      assert body["artifact_sha256"] == sha
      assert body["status"]["slug"] == "pb-site"

      # The box builds ONE site at a time, so a fire-and-forget run would refuse
      # the NEXT test's deploy with `box_at_capacity`. Leave the slot free.
      await_done("pb-site")
    end

    test "a BOX BUILD omits both keys — an absent field, never a bare prebuilt:false", %{
      conn: conn
    } do
      put_runner_cfg(enabled: true, command: stub("exit 0"))

      body =
        conn
        |> admin_conn()
        |> post("/v1/admin/site-deploy", body("box-built"))
        |> json_response(202)

      assert body["ok"] == true
      refute Map.has_key?(body, "prebuilt")
      refute Map.has_key?(body, "artifact_sha256")

      await_done("box-built")
    end

    test "400 invalid_artifact_digest — artifact_b64 alone is REFUSED, never silently dropped",
         %{conn: conn} do
      {b64, _sha} = prebuilt_artifact()
      put_runner_cfg(enabled: true, command: stub("exit 0"))

      assert %{"error" => %{"code" => "invalid_artifact_digest", "message" => message}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("half-pair", %{"artifact_b64" => b64}))
               |> json_response(400)

      assert message =~ "artifact_sha256 is required"
    end

    test "400 with the extractor's OWN typed code when the box refuses the bytes", %{conn: conn} do
      run_state = Path.join(System.tmp_dir!(), "bp-ctl-run-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(run_state) end)
      {b64, _sha} = prebuilt_artifact()

      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      assert %{"error" => %{"code" => "E_DIGEST_MISMATCH", "message" => message}} =
               conn
               |> admin_conn()
               |> post(
                 "/v1/admin/site-deploy",
                 body("bad-digest", %{
                   "artifact_b64" => b64,
                   "artifact_sha256" => String.duplicate("0", 64)
                 })
               )
               |> json_response(400)

      assert message =~ "sha256"
      # The refusal did not start a run — the slug is still idle.
      assert %{"state" => "idle"} =
               conn
               |> admin_conn()
               |> get("/v1/admin/site-deploy", %{"slug" => "bad-digest"})
               |> json_response(200)
    end
  end

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

      # A SECOND SITE draws a DIFFERENT typed 409: its own single-flight slot is
      # free (it is still `idle`), but the box builds one site at a time, so the
      # deploy is refused AT THE DOOR rather than queueing inside its own unit
      # for 900s where an operator reads the queue as a hang. `code` is exactly
      # "box_at_capacity" and the message is NON-EMPTY: the control plane
      # renders a refusal as "<code> — <message>" and classifies on the head of
      # that split, so an empty message lands the deferral unclassified.
      assert %{"error" => %{"code" => "box_at_capacity", "message" => busy_message}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", body("not-busy"))
               |> json_response(409)

      assert String.trim(busy_message) != ""
      assert busy_message =~ "1 of 1"

      assert %{"state" => "idle"} =
               conn
               |> admin_conn()
               |> get("/v1/admin/site-deploy", %{"slug" => "not-busy"})
               |> json_response(200)

      await_done("busy")

      # The slot frees itself with the build — no operator action, no lock to
      # clear — and the refused site deploys on a plain retry.
      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", body("not-busy"))
             |> json_response(202)

      await_done("not-busy")
    end

    test "a ROLLBACK is never refused by the box door — it takes no build slot", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        command: stub("sleep 0.6; exit 0"),
        rollback_command: stub("exit 0")
      )

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", body("gate-busy"))
             |> json_response(202)

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", %{"slug" => "gate-rb", "mode" => "rollback"})
             |> json_response(202)

      await_done("gate-rb")
      await_done("gate-busy")
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

      # site-spawner (node slot truth): +served_port +served_slot, the slot the
      # box measured Caddy to be serving. `health_exit_code` is deliberately NOT
      # here and this pin is the proof: `echo hi` reports no HEALTH stage, and an
      # unmeasured health code is OMITTED rather than defaulted to 0 (0 is the
      # SUCCESS code, so a default would certify a gate that never ran).
      assert Map.keys(done) |> Enum.sort() == ~w(
               build_id content_rev exit_code failure_reason finished_at log mode
               served_port served_slot slug stages started_at state
             )
    end

    test "a non-empty build_id that does not match the served run is 404", %{conn: conn} do
      # A slug that never deployed serves an idle run whose build_id is nil, so
      # any non-empty polled build_id is a mismatch — the control plane keeps
      # waiting rather than adopting the idle (or a newer) run.
      assert %{"error" => %{"code" => "build_id_mismatch", "message" => message}} =
               conn
               |> admin_conn()
               |> get("/v1/admin/site-deploy", %{"slug" => "brand-new", "build_id" => "b1"})
               |> json_response(404)

      assert message =~ "brand-new"
      assert message =~ "b1"
    end

    test "an empty build_id falls back to slug-only match (rollback await-flip)", %{conn: conn} do
      assert %{"state" => "idle", "slug" => "brand-new"} =
               conn
               |> admin_conn()
               |> get("/v1/admin/site-deploy", %{"slug" => "brand-new", "build_id" => ""})
               |> json_response(200)
    end
  end

  # ── build_id match key — the pure decision (charter D34) ─────────────────

  describe "resolve_status_match/2 (pure)" do
    alias BarkparkWeb.SiteDeployController

    test "a matching build_id serves" do
      assert :serve = SiteDeployController.resolve_status_match(%{build_id: "b1"}, "b1")
    end

    test "a mismatched build_id is not_found" do
      assert :not_found = SiteDeployController.resolve_status_match(%{build_id: "b1"}, "b2")
    end

    test "an empty build_id serves (slug-only, backward compatible)" do
      assert :serve = SiteDeployController.resolve_status_match(%{build_id: "b1"}, "")
    end

    test "an absent build_id serves (legacy caller)" do
      assert :serve = SiteDeployController.resolve_status_match(%{build_id: "b1"}, nil)
    end

    test "a non-empty build_id against an idle run (nil build_id) is not_found" do
      assert :not_found = SiteDeployController.resolve_status_match(%{build_id: nil}, "b1")
    end
  end

  # ── the call budgets are PINNED, not merely configured (dr-w15-s1) ───────
  #
  # Every existing reference to `trigger_call_timeout_ms` OVERRIDES it (25ms,
  # above) — so nothing observed the DEFAULT, and a regression from 30_000 back
  # to the 5_000 that produced 265 wrong `feature_not_configured` rows would
  # have shipped GREEN. These two tests are the guard that can lose: mutate the
  # module attribute and they RED.
  describe "call budgets — the defaults, observed without overriding them" do
    test "the trigger budget default is 30_000ms, longer than the ctl round-trip it waits on" do
      # The pin is meaningless if config is supplying the number: assert we are
      # reading the ATTRIBUTE, then assert the attribute.
      refute Keyword.has_key?(DeployRunner.config(), :trigger_call_timeout_ms),
             "this test observes the DEFAULT — an override in config would make it vacuous"

      assert DeployRunner.trigger_call_timeout_ms() == 30_000

      # The invariant underneath the number: the caller's budget must outlast a
      # control-plane systemctl round-trip (@default_ctl_cmd_timeout_ms, 15s),
      # which the trigger's critical section is ALLOWED to make. The old 5_000
      # violated this, and that is what made the door lie.
      assert DeployRunner.trigger_call_timeout_ms() > 15_000
    end

    test "the status budget default is 20_000ms, and is the one `trigger/1` does NOT share" do
      refute Keyword.has_key?(DeployRunner.config(), :status_call_timeout_ms),
             "this test observes the DEFAULT — an override in config would make it vacuous"

      assert DeployRunner.status_call_timeout_ms() == 20_000
      # Same invariant as the trigger: longer than the ctl round-trip
      # `{:status, slug}` may make. `status/1` used to take safe_call's unstated
      # 5_000 default.
      assert DeployRunner.status_call_timeout_ms() > 15_000
    end
  end

  # ── status/1 no longer answers a silent :idle for a wedged Runner ────────
  #
  # A 5_000ms budget with an `idle_status/1` fallback meant a Runner wedged for
  # >5s reported `state: :idle` — byte-identical to "this slug has never run",
  # on the very read a control plane polls to decide a deploy finished. The
  # wedge here is produced BY CONSTRUCTION (a process parked on a message nobody
  # sends), so this can only fail for the right reason.
  describe "status/1 — an unread status is not an empty one" do
    test "a genuine idle and an unreachable Runner are DIFFERENT answers" do
      genuine = DeployRunner.status("never-ran-anywhere")
      assert genuine.state == :idle
      assert genuine.log_state == :never_recorded
      assert is_nil(genuine.failure_reason)

      # Shrink the budget so the wedge is observed in milliseconds; the door is
      # silent by construction, so no budget could have been long enough.
      put_runner_cfg(status_call_timeout_ms: 100)
      intercept_with_silent_door()

      degraded = DeployRunner.status("never-ran-anywhere")

      assert degraded.state == :unknown
      refute degraded.state == genuine.state
      assert degraded.log_state == :unknown
      assert degraded.failure_reason =~ "did not answer"
      assert degraded.failure_reason =~ "NOT idle"
      # Same keys as every other status map — callers match the shape.
      assert Map.keys(degraded) |> Enum.sort() == Map.keys(genuine) |> Enum.sort()
      # And `running?/1` still answers false, never crashes, on that map.
      refute DeployRunner.running?("never-ran-anywhere")
    end
  end

  # A door that answers NOTHING — the same name takeover as
  # `intercept_with_unanswering_door/0`, but it does not proxy status either, so
  # `{:status, slug}` expires too.
  defp intercept_with_silent_door do
    real = Process.whereis(DeployRunner)
    assert is_pid(real), "the DeployRunner singleton must be alive to be intercepted"

    door = spawn(fn -> receive do: (:never -> :ok) end)
    Process.unregister(DeployRunner)
    Process.register(door, DeployRunner)

    on_exit(fn ->
      if Process.whereis(DeployRunner) == door, do: Process.unregister(DeployRunner)
      Process.exit(door, :kill)

      if Process.alive?(real) and is_nil(Process.whereis(DeployRunner)),
        do: Process.register(real, DeployRunner)
    end)

    door
  end

  describe "GET ?record=1 — the DURABLE per-build record" do
    # WHY THIS ENDPOINT EXISTS: render_status/1 answers about the run the Runner
    # holds IN MEMORY. Once a build finishes and the slug goes idle, the only
    # thing that still knows what happened is the terminal record on disk — and
    # before this, reading it cost an SSH session.

    test "a slug that never deployed answers never_recorded, NOT an empty success",
         %{conn: conn} do
      run_state = Path.join(System.tmp_dir!(), "bp-rec-#{System.unique_integer([:positive])}")
      File.mkdir_p!(run_state)
      on_exit(fn -> File.rm_rf(run_state) end)
      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      body =
        conn
        |> admin_conn()
        |> get("/v1/admin/site-deploy?slug=never-built&record=1")
        |> json_response(200)

      assert body["log_state"] == "never_recorded"
      assert body["record"] == "none"
      assert body["exit_code"] == nil

      # THE DISTINCTION THIS ROW EXISTS FOR: a slug that never deployed and a
      # build whose log was pruned must not answer identically. `never_recorded`
      # is a different word from `evicted`, and both are different from
      # `missing` (gone from disk, never tombstoned).
      refute body["log_state"] in ["evicted", "missing", "available"]
    end

    test "a recorded failure exposes the CAUSE — stages, exit code, journal command — and NEVER raw log bytes",
         %{conn: conn} do
      run_state = Path.join(System.tmp_dir!(), "bp-rec-#{System.unique_integer([:positive])}")
      File.mkdir_p!(run_state)
      on_exit(fn -> File.rm_rf(run_state) end)
      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      secret = "BARKPARK_TOKEN=bppat_thismustnevercrosstheboundary"
      log = Path.join(run_state, "boom-b1.log")
      File.write!(log, "npm ERR! 401 Unauthorized\n" <> secret <> "\n")

      File.write!(
        Path.join(run_state, "boom-b1.terminal.json"),
        Jason.encode!(%{
          "slug" => "boom",
          "build_id" => "b1",
          "run_tag" => "b1",
          "log_file" => log,
          "log_bytes" => 64,
          "exit_code" => 1,
          "failure_reason" => "BUILD failed: npm ERR! 401 Unauthorized",
          "stages" => [
            %{"name" => "PLAN", "status" => "ok"},
            %{"name" => "BUILD", "status" => "failed"}
          ],
          "unit_name" => "bp-site-build-boom.service",
          "started_at" => "2026-08-22T10:00:00Z",
          "finished_at" => "2026-08-22T10:01:00Z"
        })
      )

      body =
        conn
        |> admin_conn()
        |> get("/v1/admin/site-deploy?slug=boom&build_id=b1&record=1")
        |> json_response(200)

      # MORE than the one-line failure_reason — the whole point of the row.
      assert body["exit_code"] == 1
      assert body["failure_reason"] =~ "401 Unauthorized"
      assert length(body["stages"]) == 2
      assert body["unit_name"] == "bp-site-build-boom.service"
      assert body["journal_command"]
      assert body["log_state"] == "available"
      assert body["log_bytes"] == 64

      # THE SECURITY BOUNDARY, asserted POSITIVELY against the exact bytes on
      # disk rather than by hoping no field carries them. The build env file
      # carries BARKPARK_TOKEN in plaintext and the shared scrubber's measured
      # leak rate against this token shape is 95.1%, which is why the bytes are
      # refused rather than scrubbed.
      encoded = Jason.encode!(body)
      refute encoded =~ "bppat_"
      refute encoded =~ "BARKPARK_TOKEN"
      refute Map.has_key?(body, "log")

      # NOT "no log-derived text" — `failure_reason` is BUILT from the log's
      # trailing meaningful lines and carrying the cause is the entire point of
      # the row. The boundary is the raw BYTES, which is where the plaintext
      # token lives. An earlier version of this test refuted "npm ERR!" and was
      # wrong in the direction that matters: it would have passed against a
      # surface that had stopped saying anything useful.
      assert body["failure_reason"] =~ "npm ERR!"
    end

    test "the reason and stage caps are ENFORCED HERE, not inherited from upstream",
         %{conn: conn} do
      run_state = Path.join(System.tmp_dir!(), "bp-rec-#{System.unique_integer([:positive])}")
      File.mkdir_p!(run_state)
      on_exit(fn -> File.rm_rf(run_state) end)
      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      # An order of magnitude over each cap. Upstream bounds these already; this
      # asserts the DOOR does too, so a future upstream change cannot widen what
      # this endpoint serves without reddening here.
      File.write!(
        Path.join(run_state, "huge-b1.terminal.json"),
        Jason.encode!(%{
          "slug" => "huge",
          "build_id" => "b1",
          "run_tag" => "b1",
          "log_file" => Path.join(run_state, "huge-b1.log"),
          "exit_code" => 1,
          "failure_reason" => String.duplicate("x", 40_000),
          "stages" => Enum.map(1..320, &%{"name" => "S#{&1}", "status" => "ok"})
        })
      )

      body =
        conn
        |> admin_conn()
        |> get("/v1/admin/site-deploy?slug=huge&build_id=b1&record=1")
        |> json_response(200)

      assert byte_size(body["failure_reason"]) < 5_000
      assert body["failure_reason"] =~ "truncated at 4000 bytes"
      assert length(body["stages"]) == 32
    end

    test "WITHOUT the flag the existing status contract is byte-identical — BoxRelay is untouched",
         %{conn: conn} do
      run_state = Path.join(System.tmp_dir!(), "bp-rec-#{System.unique_integer([:positive])}")
      File.mkdir_p!(run_state)
      on_exit(fn -> File.rm_rf(run_state) end)
      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      plain =
        conn |> admin_conn() |> get("/v1/admin/site-deploy?slug=idle-one") |> json_response(200)

      assert plain["state"] == "idle"
      refute Map.has_key?(plain, "log_state")

      # A typo in the flag must NOT switch response shapes — it degrades to the
      # live status. `record=0` and `record=please` are not opt-ins.
      for bad <- ["0", "false", "please", ""] do
        other =
          conn
          |> admin_conn()
          |> get("/v1/admin/site-deploy?slug=idle-one&record=#{bad}")
          |> json_response(200)

        assert other["state"] == "idle",
               "record=#{inspect(bad)} switched response shapes; only 1/true/yes/on may opt in"

        refute Map.has_key?(other, "log_state")
      end

      # And the 404 contract BoxRelay depends on (charter D34) still fires.
      conn
      |> admin_conn()
      |> get("/v1/admin/site-deploy?slug=idle-one&build_id=not-the-live-one")
      |> json_response(404)
    end
  end
end
