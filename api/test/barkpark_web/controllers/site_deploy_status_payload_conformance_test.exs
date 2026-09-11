defmodule BarkparkWeb.SiteDeployStatusPayloadConformanceTest do
  @moduledoc """
  THE PRODUCER-SIDE HALF OF THE BOX STATUS/RECORD PAYLOAD LOCK.

  `BarkparkWeb.SiteDeployController` emits two payloads the control plane in
  the OTHER app consumes: `render_status/1` (the poll body
  `BarkparkCloud.Sites.Deploy.normalize_report/1` reads) and
  `render_build_record/1` (the durable record `BarkparkCloud.Sites.BuildLog`
  renders). Until this file existed, each side pinned its OWN hand-written
  snapshot — a closed `Map.keys(done) |> Enum.sort() == ~w(...)` here, a
  hand-authored body in `cloud/test/support/sites_fake_box_relay.ex`, and a
  hand-typed `@record_keys` allowlist in `cloud/lib/.../sites/build_log.ex`.
  Nothing compared them, so a producer key rename was GREEN on both suites and
  wrong in production.

  It was not hypothetical. When this lock was built, `render_build_record/1`
  had emitted `route_status` and `route_detail` since #17640 and the control
  plane's allowlist did not list them, so the box's route verdict was being
  silently dropped on the way to the operator — with every suite green.

  The one copy now lives in `test/support/fixtures/box_status_payload.json`,
  and cloud/ READS it (`BarkparkCloud.BoxStatusPayloadFixture`). This file is
  what makes that JSON trustworthy: it drives the REAL controller to real 200s
  on both doors and DERIVES the key sets from the responses — never retyped.
  Reword the producer without updating the JSON and THIS test fails, in api/,
  on the api diff that did the rewording.

  The other half — that the cloud consumer still reads what the JSON says it
  reads — lives in
  `cloud/test/barkpark_cloud/sites/box_status_payload_conformance_test.exs`.
  """
  # async: false — mutates the singleton DeployRunner + application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.{DeployRunner, Provisioner}

  @fixture_path Path.expand("../../support/fixtures/box_status_payload.json", __DIR__)
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  @producer "api/lib/barkpark_web/controllers/site_deploy_controller.ex"
  @fixture_rel "api/test/support/fixtures/box_status_payload.json"

  @admin_token "barkpark-test-status-payload-admin"

  setup do
    base = Path.join(System.tmp_dir!(), "bp-status-payload-#{System.unique_integer([:positive])}")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"stub"}))

    prior = Application.get_env(:barkpark, Provisioner)

    Application.put_env(:barkpark, Provisioner,
      sites_dir: Path.join(base, "sites"),
      template_dir: template
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

    {:ok, _} =
      Auth.create_token(@admin_token, "status-payload-admin", "test", ["read", "write", "admin"])

    :ok
  end

  # ── the fixture is a well-formed declaration, before anything reads it ────
  #
  # NON-VACUITY FIRST. Every assertion below compares a derived set against a
  # list out of the JSON. A JSON whose lists went empty, or whose two halves
  # overlapped, would make those comparisons meaningless in the direction that
  # passes — so the declaration is checked for shape before it is trusted.

  describe "the declaration itself" do
    test "the status key lists are non-empty, disjoint, and sorted" do
      consumed = fx(["status", "consumed"])
      producer_only = fx(["status", "producer_only"])

      assert length(consumed) >= 5,
             "#{@fixture_rel}: status.consumed has #{length(consumed)} entries — an empty or near-empty list makes every comparison below vacuous"

      assert producer_only != [], "#{@fixture_rel}: status.producer_only is empty"

      assert consumed -- producer_only == consumed,
             "#{@fixture_rel}: a key is in BOTH status.consumed and status.producer_only — the classification must partition"

      assert consumed == Enum.sort(consumed), "#{@fixture_rel}: status.consumed is not sorted"

      assert producer_only == Enum.sort(producer_only),
             "#{@fixture_rel}: status.producer_only is not sorted"
    end

    test "`conditional` and `consumer_only` sit on the right side of the partition" do
      all = status_keys()

      for key <- fx(["status", "conditional"]) do
        assert key in all,
               "#{@fixture_rel}: status.conditional names #{inspect(key)}, which is not a producer key at all"
      end

      for key <- fx(["status", "consumer_only"]) do
        refute key in all,
               "#{@fixture_rel}: status.consumer_only names #{inspect(key)}, but the producer DOES emit it — it belongs in consumed or producer_only"
      end
    end

    test "the record key list is non-empty and sorted" do
      keys = fx(["record", "emitted"])

      assert length(keys) >= 10,
             "#{@fixture_rel}: record.emitted has #{length(keys)} entries — too few to be render_build_record/1's key set"

      assert keys == Enum.sort(keys), "#{@fixture_rel}: record.emitted is not sorted"
    end
  end

  # ── the lock: the REAL emitter, driven, key set DERIVED ───────────────────

  describe "render_status/1" do
    test "the emitted status key set IS the shared JSON's, derived from a real 200", %{conn: conn} do
      put_runner_cfg(enabled: true, command: stub("echo hi; exit 0"))

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", %{
               "slug" => "status-payload-conf",
               "build_id" => "b1",
               "mode" => "deploy"
             })
             |> json_response(202)

      done = await_done("status-payload-conf")

      # `echo hi` narrates no HEALTH stage, so the one `conditional` key is
      # ABSENT here. That absence is the contract (0 is the SUCCESS code, so a
      # defaulted health code would certify a gate that never ran) and it is
      # what `conditional` declares — asserted, not assumed.
      conditional = fx(["status", "conditional"])

      for key <- conditional do
        refute Map.has_key?(done, key),
               "#{@producer} emitted #{inspect(key)} on a run that measured nothing — #{@fixture_rel} declares it CONDITIONAL, i.e. omitted rather than defaulted"
      end

      assert Enum.sort(Map.keys(done)) == Enum.sort(status_keys() -- conditional),
             drift_message("render_status/1", Map.keys(done), status_keys() -- conditional)
    end
  end

  describe "render_build_record/1" do
    test "the emitted record key set IS the shared JSON's, derived from a real 200", %{conn: conn} do
      run_state =
        Path.join(System.tmp_dir!(), "bp-rec-conf-#{System.unique_integer([:positive])}")

      File.mkdir_p!(run_state)
      on_exit(fn -> File.rm_rf(run_state) end)
      put_runner_cfg(enabled: true, run_state_dir: run_state, command: stub("exit 0"))

      log = Path.join(run_state, "recconf-b1.log")
      File.write!(log, "npm ERR! 401 Unauthorized\n")

      File.write!(
        Path.join(run_state, "recconf-b1.terminal.json"),
        Jason.encode!(%{
          "slug" => "recconf",
          "build_id" => "b1",
          "run_tag" => "b1",
          "log_file" => log,
          "log_bytes" => 26,
          "exit_code" => 1,
          "failure_reason" => "BUILD failed: npm ERR! 401 Unauthorized",
          "stages" => [%{"name" => "BUILD", "status" => "failed"}],
          "unit_name" => "bp-site-build-recconf.service",
          "started_at" => "2026-09-01T10:00:00Z",
          "finished_at" => "2026-09-01T10:01:00Z"
        })
      )

      body =
        conn
        |> admin_conn()
        |> get("/v1/admin/site-deploy?slug=recconf&build_id=b1&record=1")
        |> json_response(200)

      # The record door renders a CLOSED map — every key always present, unlike
      # the status door's one conditional. A `log_state` proves we reached the
      # record renderer and not some earlier bail-out that would make an empty
      # key set look like agreement.
      assert body["log_state"] == "available",
             "the record door did not render a real record (log_state=#{inspect(body["log_state"])}) — the key-set comparison below would be measuring the wrong map"

      assert Enum.sort(Map.keys(body)) == fx(["record", "emitted"]),
             drift_message("render_build_record/1", Map.keys(body), fx(["record", "emitted"]))
    end
  end

  describe "render_stage/1" do
    test "the emitted stage key set IS the shared JSON's", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        command: stub("echo 'BPSTAGE name=PLAN status=ok build_id=b1'; exit 0")
      )

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", %{
               "slug" => "stage-payload-conf",
               "build_id" => "b1",
               "mode" => "deploy"
             })
             |> json_response(202)

      done = await_done("stage-payload-conf")

      stages = done["stages"]

      assert is_list(stages) and stages != [],
             "the run narrated no stages — there is nothing here to compare, and a vacuous pass is exactly what this lock exists to stop"

      [stage | _] = stages

      assert Enum.sort(Map.keys(stage)) == fx(["status", "stage", "emitted"]),
             drift_message("render_stage/1", Map.keys(stage), fx(["status", "stage", "emitted"]))
    end
  end

  describe "the conditional key, in the direction that PROVES it is emitted" do
    # The status arm above asserts `health_exit_code` is ABSENT from a run that
    # measured nothing. On its own that is satisfiable by a producer that never
    # emits the key at all — in which case `conditional` would be a lie and the
    # key set the JSON declares would be wrong by one. This is the other half:
    # a run that DOES report HEALTH, where the key must be present.
    test "a run that reports HEALTH emits the conditional key", %{conn: conn} do
      put_runner_cfg(
        enabled: true,
        command: stub("echo 'BPSTAGE name=HEALTH status=ok build_id=b1'; exit 0")
      )

      assert conn
             |> admin_conn()
             |> post("/v1/admin/site-deploy", %{
               "slug" => "health-payload-conf",
               "build_id" => "b1",
               "mode" => "deploy"
             })
             |> json_response(202)

      done = await_done("health-payload-conf")

      for key <- fx(["status", "conditional"]) do
        assert Map.has_key?(done, key),
               "#{@producer} did not emit #{inspect(key)} on a run that DID measure it — #{@fixture_rel} declares it a producer key, so it is either no longer emitted at all (drop it from the JSON) or no longer conditional"
      end

      assert Enum.sort(Map.keys(done)) == status_keys(),
             drift_message("render_status/1 (health measured)", Map.keys(done), status_keys())
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp fx(path), do: get_in(@fixture, path) || flunk("#{@fixture_rel}: missing #{inspect(path)}")

  defp status_keys, do: Enum.sort(fx(["status", "consumed"]) ++ fx(["status", "producer_only"]))

  defp drift_message(fun, got, want) do
    got = Enum.sort(got)
    want = Enum.sort(want)

    """
    THE BOX PAYLOAD MIRROR HAS DRIFTED.

    #{@producer} — #{fun} — now emits:
        #{inspect(got)}

    …but #{@fixture_rel} says:
        #{inspect(want)}

      only in the emitter: #{inspect(got -- want)}
      only in the JSON   : #{inspect(want -- got)}

    That JSON is THE ONE COPY. cloud/ reads it through
    BarkparkCloud.BoxStatusPayloadFixture: the fake box relay builds its bodies
    from it, and the control plane's own consumers
    (BarkparkCloud.Sites.Deploy.normalize_report/1,
    BarkparkCloud.Sites.BuildLog's @record_keys) are asserted against it. A key
    you add here and not there is a key the control plane silently drops; a key
    you remove here and not there is one it renders and never receives.

    If the change is intended, update #{@fixture_rel} in the SAME commit — ONE
    line in the right list, kept sorted. Do not retype the list anywhere else:
    the cloud-side guard
    (cloud/test/barkpark_cloud/sites/box_status_payload_conformance_test.exs)
    fails if you do.
    """
  end

  defp admin_conn(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

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

  defp await_done(slug, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    body =
      Phoenix.ConnTest.build_conn()
      |> admin_conn()
      |> get("/v1/admin/site-deploy", %{"slug" => slug})
      |> json_response(200)

    cond do
      body["state"] == "done" -> body
      System.monotonic_time(:millisecond) >= deadline -> body
      true -> Process.sleep(25) && await_done(slug, deadline)
    end
  end
end
