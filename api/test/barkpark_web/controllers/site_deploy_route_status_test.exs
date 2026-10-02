defmodule BarkparkWeb.SiteDeployRouteStatusTest do
  @moduledoc """
  deploy-reliability W21 (charter D608): THE ARM DECISION CROSSES THE WIRE.

  `GET /v1/admin/site-deploy` is what the control plane polls, so it is the
  producer of the ROUTE measurement — and until `route_status`/`route_detail`
  joined `render_status/1` the decision was durable on the box and invisible
  everywhere else. Wave 21's count of cloud `deployments` rows carrying a ROUTE
  outcome was 0 of 19,327 console-bearing rows, and it could not have been
  anything else: the key did not exist on this door.

  ## The vacuous-green trap, and how these tests step around it

  Dev, CI and macOS fall back to the in-process Port runner
  (`deploy_runner.ex`'s `render_run/1`), which hardcodes `route_status: nil`
  with the reason in a comment — ROUTE lands in the in-memory log there, never
  in a fold. A test that ran a shell script echoing a ROUTE line and asserted on
  the wire key would therefore be asserting against a path PRODUCTION DOES NOT
  USE (prod launches transient systemd units and rebuilds status from the
  durable files), and would stay green over a controller that dropped the key.

  So none of these tests drive the Port path. They seed a DURABLE TERMINAL
  RECORD — the same JSON `write_terminal_record/2` leaves behind after a
  systemd run finalizes, and the same one `render_terminal_record/1` reads back
  — and poll the two doors that read it:

    * `GET …?slug=…`           → `status/1`'s record fallback → `render_status/1`
    * `GET …?slug=…&record=1`  → `build_record/2` → `render_build_record/1`

  Both doors must agree about a build, which is why both are asserted here.

  ## ROUTE is a REPORT, never a verdict

  It stays outside the box's `@stage_names` (the SERVED precedent), so it never
  enters `stages` and can never reach `stage_exit_code/1`. A run whose route
  arm FAILED still carries its own exit code and its own stage list; the last
  test pins that, because the moment a failed arm re-decides a run that already
  emitted SWITCH ok, this channel has become the thing charter D608 refused.
  """
  # async: false — mutates the DeployRunner singleton's Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.DeployRunner

  @admin_token "barkpark-test-route-status-admin"

  setup do
    dir = Path.join(System.tmp_dir!(), "bp-route-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prior = Application.get_env(:barkpark, DeployRunner)

    Application.put_env(
      :barkpark,
      DeployRunner,
      # `runner_mode: :systemd` IS THE POINT, not scaffolding. In `:port` mode
      # `load_latest_terminal_record/1` returns nil by construction, so the
      # status door would answer `idle` and every assertion below would be about
      # a code path production does not run. Measured, not assumed: the first run
      # of this file was written without it and printed `left: nil` on the ARMED
      # arm.
      Keyword.merge(prior || [], enabled: true, runner_mode: :systemd, run_state_dir: dir)
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)

      File.rm_rf(dir)
    end)

    {:ok, _} =
      Auth.create_token(@admin_token, "route-status-admin", "test", ["read", "write", "admin"])

    {:ok, dir: dir}
  end

  defp admin_conn(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  # The record a finalized SYSTEMD run leaves on disk. Deliberately hand-built
  # from the same key names `write_terminal_record/2` writes, so a rename on that
  # side surfaces here as a nil rather than as a silent pass.
  defp seed_record(dir, slug, fields) do
    record =
      Map.merge(
        %{
          "slug" => slug,
          "build_id" => "b1",
          "run_tag" => "b1",
          "content_rev" => "rev-1",
          "mode" => "deploy",
          "runtime_target" => "static",
          "unit_name" => "bp-site-build-#{slug}-b1-1.service",
          "journal_command" => "journalctl -u bp-site-build-#{slug}-b1-1.service",
          "exit_code" => 0,
          "failure_reason" => nil,
          "stages" => [],
          "served_port" => nil,
          "served_slot" => nil,
          "route_status" => nil,
          "route_detail" => nil,
          "log_file" => Path.join(dir, "#{slug}-b1.log"),
          "log_bytes" => nil,
          "log_state" => "missing",
          "evicted_at" => nil,
          "started_at" => "2026-09-11T10:00:00Z",
          "finished_at" => "2026-09-11T10:01:00Z"
        },
        fields
      )

    File.write!(Path.join(dir, "#{slug}-b1.terminal.json"), Jason.encode!(record))
    :ok
  end

  defp status_door(conn, slug) do
    conn
    |> admin_conn()
    |> get("/v1/admin/site-deploy", %{"slug" => slug})
    |> json_response(200)
  end

  defp record_door(conn, slug) do
    conn
    |> admin_conn()
    |> get("/v1/admin/site-deploy", %{"slug" => slug, "record" => "1"})
    |> json_response(200)
  end

  describe "route_status / route_detail — the arm decision on the wire" do
    test "an ARMED route reaches both doors", %{conn: conn, dir: dir} do
      seed_record(dir, "rt-armed", %{
        "stages" => [%{"name" => "SWITCH", "status" => "ok", "build_id" => "b1"}],
        "route_status" => "ok",
        "route_detail" => "armed: wrote the BARKPARK_SITE_ROUTE:rt-armed handle"
      })

      status = status_door(conn, "rt-armed")

      assert status["route_status"] == "ok"
      assert status["route_detail"] == "armed: wrote the BARKPARK_SITE_ROUTE:rt-armed handle"

      # The terminal door must not disagree with the live one about a build.
      record = record_door(conn, "rt-armed")

      assert record["route_status"] == "ok"
      assert record["route_detail"] == "armed: wrote the BARKPARK_SITE_ROUTE:rt-armed handle"
    end

    test "a REFUSED arm reaches both doors and re-decides nothing", %{conn: conn, dir: dir} do
      seed_record(dir, "rt-refused", %{
        "exit_code" => 0,
        "stages" => [%{"name" => "SWITCH", "status" => "ok", "build_id" => "b1"}],
        "route_status" => "failed",
        "route_detail" => "caddy validate rejected the block"
      })

      status = status_door(conn, "rt-refused")

      assert status["route_status"] == "failed"
      assert status["route_detail"] == "caddy validate rejected the block"

      # THE POINT OF THE SIBLING CHANNEL (charter D608). A failed ROUTE is a
      # MEASUREMENT, not a verdict: it entered no stage, so it cannot reach
      # `stage_exit_code/1`, and this run — which emitted SWITCH ok — still
      # reports 0. Admitting ROUTE into `@stage_names` would have made this
      # exit -1 and invented a failure_reason, pre-deciding a fatality question
      # nobody has ruled on.
      assert status["exit_code"] == 0
      assert status["failure_reason"] == nil
      assert Enum.map(status["stages"], & &1["name"]) == ["SWITCH"]

      assert record_door(conn, "rt-refused")["route_status"] == "failed"
    end

    test "a run that never armed reports null on both doors — present, not absent", %{
      conn: conn,
      dir: dir
    } do
      seed_record(dir, "rt-silent", %{
        "stages" => [%{"name" => "BUILD", "status" => "failed", "build_id" => "b1"}],
        "exit_code" => 12
      })

      status = status_door(conn, "rt-silent")

      # PRESENT AND NULL, not omitted. `health_exit_code` is omitted when
      # unmeasured because the value that would be invented is 0 and 0 is the
      # SUCCESS code; the value that would be invented here is a STRING, and
      # `null` already reads as "nobody measured this". Every box older than the
      # ROUTE engines lands in exactly this shape, so a caller must be able to
      # tell it apart from a key this door forgot.
      assert Map.has_key?(status, "route_status")
      assert Map.has_key?(status, "route_detail")
      assert status["route_status"] == nil
      assert status["route_detail"] == nil

      record = record_door(conn, "rt-silent")

      assert Map.has_key?(record, "route_status")
      assert record["route_status"] == nil
      assert record["route_detail"] == nil
    end

    test "a slug that never deployed still carries both keys, null", %{conn: conn} do
      # The `absent_record/2` shape. A door that only set these keys on the
      # happy path would 500 or omit here, and the control plane's decoder would
      # see a different payload shape for "never deployed" than for "deployed
      # and never armed" — two sentences that must look the same on the wire.
      record = record_door(conn, "rt-nonexistent")

      assert Map.has_key?(record, "route_status")
      assert record["route_status"] == nil
      assert record["route_detail"] == nil
    end
  end

  describe "the record door answers about a record a REAL run wrote" do
    test "a record carrying `mode` and `runtime_target` renders instead of 500-ing", %{
      conn: conn,
      dir: dir
    } do
      # FOUND BY THIS WAVE, NOT BY THE SUITE. `write_terminal_record/2` persists
      # `"mode" => to_string(manifest.mode)` and the same for
      # `runtime_target`; `render_terminal_record/1` passes those STRINGS
      # through; `render_build_record/1` then fed them to `atom_or_nil/1`, which
      # had only a `nil` clause and an `is_atom` clause. Every record a real run
      # ever wrote therefore raised FunctionClauseError on this door — a 500 for
      # "tell me about this build".
      #
      # It stayed invisible because the one existing fixture for this door
      # (`site_deploy_controller_test.exs`, the "recorded failure exposes the
      # CAUSE" row) omits both keys, so `atom_or_nil/1` only ever saw nil there.
      # MUTATION-PROVED: delete the `is_binary` clause and this test reds with
      # `no function clause matching in atom_or_nil/1 … "deploy"`.
      seed_record(dir, "rt-realshape", %{
        "mode" => "deploy",
        "runtime_target" => "static",
        "route_status" => "ok",
        "route_detail" => "already armed"
      })

      record = record_door(conn, "rt-realshape")

      assert record["mode"] == "deploy"
      assert record["runtime_target"] == "static"
      assert record["route_status"] == "ok"
      assert record["route_detail"] == "already armed"
    end
  end
end
