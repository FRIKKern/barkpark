defmodule BarkparkWeb.SiteDeployServedSlotTest do
  @moduledoc """
  site-spawner (node slot truth): what the BOX REPORT says about the slot Caddy
  is serving, and about whether the health gate ran.

  `GET /v1/admin/site-deploy` is what the control plane polls, so it is the
  producer of both facts. Three laws, each with the arm that would break it:

  ## `health_exit_code` is OMITTED when it was never measured

  Not `null`, not `0` — ABSENT. The same discipline the 202's `prebuilt_echo/1`
  already states on this door: an absent field is an honest "nobody measured
  this", where a present one invites the caller to read it as a considered
  answer. It matters more here than anywhere else, because the value that would
  be invented is ZERO and zero is SUCCESS: a `health_exit_code: 0` on a build
  that died in BUILD says the health gate passed, which is precisely the
  zero-value success this contract forbids.

  The three arms are the whole point — a test that only asserted "0 when it
  passed" would pass just as happily against a serializer that hardcoded 0.

  ## `served_port` / `served_slot` come from the engine's SERVED marker

  Which the engine writes AFTER its Caddy flip has committed, from a re-READ of
  the Caddyfile — so what crosses this wire is what Caddy is proxying, not the
  slot the run intended. A build that never reached SWITCH reports neither.

  ## SERVED can never flip a verdict

  It is deliberately outside `@stage_names` (the ROUTE precedent, charter D327),
  so `parse_stage_line/2` skips it: it never enters `stages`, and therefore can
  never reach `stage_exit_code/1`. The last test drives a run whose ONLY marker
  is SERVED and asserts the stage list stays empty while the values still land.
  """
  # async: false — mutates the DeployRunner singleton + Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.{DeployRunner, Provisioner}

  @admin_token "barkpark-test-served-slot-admin"

  setup do
    base = Path.join(System.tmp_dir!(), "bp-served-slot-#{System.unique_integer([:positive])}")
    sites = Path.join(base, "sites")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"served-slot-stub"}))

    prior_provisioner = Application.get_env(:barkpark, Provisioner)
    Application.put_env(:barkpark, Provisioner, sites_dir: sites, template_dir: template)

    on_exit(fn ->
      if prior_provisioner,
        do: Application.put_env(:barkpark, Provisioner, prior_provisioner),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

    {:ok, _} =
      Auth.create_token(@admin_token, "served-slot-admin", "test", ["read", "write", "admin"])

    :ok
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

  defp body(slug), do: %{"slug" => slug, "build_id" => "b1", "mode" => "deploy"}

  defp await_done(slug, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    payload =
      scoped_conn()
      |> admin_conn()
      |> get("/v1/admin/site-deploy", %{"slug" => slug})
      |> json_response(200)

    cond do
      payload["state"] == "done" -> payload
      System.monotonic_time(:millisecond) >= deadline -> payload
      true -> Process.sleep(25) && await_done(slug, deadline)
    end
  end

  defp run(slug, script, conn) do
    put_runner_cfg(enabled: true, command: stub(script))

    assert conn |> admin_conn() |> post("/v1/admin/site-deploy", body(slug)) |> json_response(202)

    await_done(slug)
  end

  describe "health_exit_code — three answers, and the absent one is a real answer" do
    test "HEALTH never ran: the key is ABSENT, not 0 and not null", %{conn: conn} do
      done =
        run(
          "hs-nohealth",
          """
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=failed build_id=b1 detail="npm ci exited 1"'
          exit 12
          """,
          conn
        )

      assert done["state"] == "done"
      assert done["exit_code"] == 12

      refute Map.has_key?(done, "health_exit_code"),
             "a build that died in BUILD never reached HEALTH — the key must be ABSENT. " <>
               "A 0 here would render an un-run health gate as a pass (0 IS SUCCESS), and " <>
               "even an explicit null invites a reader to treat it as a measurement. " <>
               "got: #{inspect(Map.take(done, ["health_exit_code"]))}"
    end

    test "HEALTH ran and passed: the key is PRESENT and 0", %{conn: conn} do
      done =
        run(
          "hs-pass",
          """
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=ok build_id=b1'
          echo 'BPSTAGE name=STAGE status=ok build_id=b1'
          echo 'BPSTAGE name=HEALTH status=ok build_id=b1 detail="200 in 0.4s"'
          echo 'BPSTAGE name=SWITCH status=ok build_id=b1'
          echo 'BPSTAGE name=RETIRE status=ok build_id=b1'
          exit 0
          """,
          conn
        )

      assert Map.has_key?(done, "health_exit_code")
      assert done["health_exit_code"] == 0
    end

    test "HEALTH ran and failed: the key is PRESENT and 14", %{conn: conn} do
      done =
        run(
          "hs-fail",
          """
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=ok build_id=b1'
          echo 'BPSTAGE name=STAGE status=ok build_id=b1'
          echo 'BPSTAGE name=HEALTH status=failed build_id=b1 detail="bp-doc-id marker is empty"'
          exit 14
          """,
          conn
        )

      assert done["health_exit_code"] == 14,
             "14 is the cross-engine HEALTH-failed convention, and it is what lets a " <>
               "reader tell 'the gate caught it' from 'it fell over and nobody gated anything'"

      refute Enum.any?(done["stages"], &(&1["name"] == "SWITCH"))
    end

    test "HEALTH started but never reported a verdict: still ABSENT", %{conn: conn} do
      done =
        run(
          "hs-inflight",
          """
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=ok build_id=b1'
          echo 'BPSTAGE name=STAGE status=ok build_id=b1'
          echo 'BPSTAGE name=HEALTH status=started build_id=b1'
          exit 1
          """,
          conn
        )

      refute Map.has_key?(done, "health_exit_code"),
             "`started` is not a verdict — a code here would be invented"
    end
  end

  describe "served_port / served_slot — the slot Caddy is actually serving" do
    test "the SERVED marker's values reach the wire", %{conn: conn} do
      done =
        run(
          "sv-live",
          """
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=ok build_id=b1'
          echo 'BPSTAGE name=STAGE status=ok build_id=b1'
          echo 'BPSTAGE name=HEALTH status=ok build_id=b1'
          echo 'BPSTAGE name=SWITCH status=ok build_id=b1'
          echo 'BPSTAGE name=SERVED status=ok build_id=b1 detail="port=7043 slot=b"'
          echo 'BPSTAGE name=RETIRE status=ok build_id=b1'
          exit 0
          """,
          conn
        )

      assert done["served_port"] == 7043
      assert done["served_slot"] == "b"
    end

    test "a run that never reached SWITCH reports neither", %{conn: conn} do
      done =
        run(
          "sv-noswitch",
          """
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=failed build_id=b1 detail="npm ci exited 1"'
          exit 12
          """,
          conn
        )

      assert done["served_port"] == nil
      assert done["served_slot"] == nil
    end

    test "`none` is read as NOT KNOWN, never as a slot", %{conn: conn} do
      # The engine emits `none` when its marker-anchored Caddy read matched
      # neither of this site's ports (the D345 prefix-sibling shape). That is a
      # measurement — "we looked, and Caddy names no upstream for us" — and it
      # must not be laundered into a slot name.
      done =
        run(
          "sv-none",
          """
          echo 'BPSTAGE name=SWITCH status=ok build_id=b1'
          echo 'BPSTAGE name=SERVED status=ok build_id=b1 detail="port=none slot=none"'
          exit 0
          """,
          conn
        )

      assert done["served_port"] == nil
      assert done["served_slot"] == nil
    end

    test "SERVED is a REPORT, never a verdict — it enters no stage and no exit code", %{
      conn: conn
    } do
      done =
        run(
          "sv-report-only",
          """
          echo 'BPSTAGE name=SERVED status=ok build_id=b1 detail="port=7042 slot=a"'
          exit 0
          """,
          conn
        )

      assert done["served_port"] == 7042
      assert done["served_slot"] == "a"

      assert done["stages"] == [],
             "SERVED must stay OUTSIDE @stage_names (the ROUTE precedent, charter D327): " <>
               "a name in that whitelist is folded into `stages`, and a failed folded " <>
               "stage reaches stage_exit_code/1 — turning a report into a verdict. " <>
               "got: #{inspect(done["stages"])}"
    end
  end
end
