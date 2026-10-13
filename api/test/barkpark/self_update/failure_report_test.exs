defmodule Barkpark.SelfUpdate.FailureReportTest do
  @moduledoc """
  A failed self-update reports its failing phase and a short, redacted log
  tail on `GET /v1/admin/self-update` (`failure`), so Barkpark Cloud can show
  WHY an update failed without SSH. Before this the reason lived only in the
  box's `.deploy-status.json` and run log (red on main: no `failure` key).

  Simulated runs use stub commands that write deploy-rebuild's flight record
  the way `write_status` does — never the real deploy script.
  """
  # async: false — mutates the singleton Runner + Application env.
  use ExUnit.Case, async: false

  alias Barkpark.SelfUpdate.{FailureReport, Runner}

  describe "FailureReport (pure)" do
    test "a successful or unfinished run has no failure" do
      assert FailureReport.build(0, ["ok"]) == nil
      assert FailureReport.build(nil, ["running"]) == nil
    end

    test "the phase comes from the matching flight record, else the exit code" do
      assert %{phase: "migrate", source: "deploy_status"} =
               FailureReport.build(1, [], %{"phase" => "migrate", "outcome" => "failed"})

      assert %{phase: "build", source: "exit_code"} = FailureReport.build(1, [])
      assert %{phase: "migrate", source: "exit_code"} = FailureReport.build(13, [])
      assert %{phase: "restart"} = FailureReport.build(15, [])
      assert %{phase: "merge"} = FailureReport.build(2, [])
      assert %{phase: "deadline"} = FailureReport.build(-2, [])
      assert %{phase: "interrupted"} = FailureReport.build(-3, [])
      assert %{phase: "fetch"} = FailureReport.build(128, ["fatal: unable to access"])

      assert %{phase: "unknown"} =
               FailureReport.build(9, ["[self-update] merge done — rebuilding..."])
    end

    test "an applied or running flight record does not name the failing phase" do
      assert %{phase: "build", source: "exit_code"} =
               FailureReport.build(1, [], %{"phase" => "restart", "outcome" => "applied"})
    end

    test "the tail keeps the last 40 lines" do
      log = for i <- 1..100, do: "line #{i}"
      tail = FailureReport.build(1, log).tail
      assert length(tail) == 40
      assert hd(tail) == "line 61"
      assert List.last(tail) == "line 100"
    end

    test "env values and secrets are redacted; plain prose and the target sha are kept" do
      [env, export, quoted, secret, url, sha, prose] =
        FailureReport.tail([
          "BARKPARK_ADMIN_TOKEN=abc123 PHX_HOST=api.example.com mix compile",
          "export DATABASE_URL=postgres://u:p@db/x",
          ~s(SECRET_KEY_BASE="a b c" next),
          "using ghp_abcdefghijklmnopqrstuvwxyz0123 to fetch",
          "fetching https://example.com/repo",
          "TARGET_SHA=0123456789abcdef",
          "** (Mix) Could not compile dependency :exqlite, phase=build"
        ])

      assert env == "BARKPARK_ADMIN_TOKEN=[redacted] PHX_HOST=[redacted] mix compile"
      assert export == "export DATABASE_URL=[redacted]"
      assert quoted == "SECRET_KEY_BASE=[redacted] next"
      refute secret =~ "ghp_abcdefghijklmnopqrstuvwxyz0123"
      assert url == "fetching https://example.com/repo"
      assert sha == "TARGET_SHA=0123456789abcdef"
      assert prose == "** (Mix) Could not compile dependency :exqlite, phase=build"
    end

    test "a long line is capped" do
      [line] = FailureReport.tail([String.duplicate("x", 2_000)])
      assert byte_size(line) < 500
      assert String.ends_with?(line, "[cut]")
    end
  end

  describe "Runner + GET /v1/admin/self-update" do
    setup do
      await_not_running()

      dir =
        Path.join(System.tmp_dir!(), "bp-self-update-fail-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      status_file = Path.join(dir, "deploy-status.json")
      put_cfg(run_state_dir: dir, deploy_status_file: status_file, orphan_poll_ms: 50)
      on_exit(fn -> File.rm_rf(dir) end)
      on_exit(fn -> await_not_running() end)
      {:ok, status_file: status_file}
    end

    # deploy-rebuild's `write_status <phase> failed`, under the child's own pid.
    defp failing_run(status_file, phase, code, lines) do
      echoes = Enum.map_join(lines, "\n", &"echo #{inspect(&1)}")

      """
      #{echoes}
      printf '{"engine":"deploy-rebuild","phase":"#{phase}","outcome":"failed","sha":"abc1234","ts":"%s","pid":%d}\\n' \\
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" > #{status_file}
      exit #{code}
      """
    end

    test "a build failure reports phase=build with the redacted tail", %{status_file: sf} do
      script =
        failing_run(sf, "build", 1, [
          "[deploy-rebuild] building aside in api/_build_next",
          "BARKPARK_TOKEN=supersecret mix compile",
          "** (CompileError) lib/x.ex:1: undefined function foo/0"
        ])

      put_cfg(enabled: true, command: {"bash", ["-c", script]})
      assert Runner.trigger() == {:ok, :started}
      status = await_done()

      assert status.exit_code == 1

      assert %{phase: "build", source: "deploy_status", exit_code: 1, tail: tail} =
               status.failure

      assert "** (CompileError) lib/x.ex:1: undefined function foo/0" in tail
      assert "BARKPARK_TOKEN=[redacted] mix compile" in tail
      refute Enum.any?(tail, &(&1 =~ "supersecret"))

      body = admin_status_json()
      assert body["failure"]["phase"] == "build"
      assert body["failure"]["exit_code"] == 1
      assert "** (CompileError) lib/x.ex:1: undefined function foo/0" in body["failure"]["tail"]
    end

    test "a migrate failure reports phase=migrate", %{status_file: sf} do
      script =
        failing_run(sf, "migrate", 13, [
          "[deploy-rebuild] migrating",
          "** (Postgrex.Error) ERROR 42P07 (duplicate_table) relation \"x\" already exists"
        ])

      put_cfg(enabled: true, command: {"bash", ["-c", script]})
      assert Runner.trigger() == {:ok, :started}
      status = await_done()

      assert %{phase: "migrate", source: "deploy_status", exit_code: 13, tail: tail} =
               status.failure

      assert Enum.any?(tail, &(&1 =~ "duplicate_table"))
      assert admin_status_json()["failure"]["phase"] == "migrate"
    end

    test "a successful run reports no failure" do
      put_cfg(enabled: true, command: {"bash", ["-c", "echo fine; exit 0"]})
      assert Runner.trigger() == {:ok, :started}
      assert %{exit_code: 0, failure: nil} = await_done()
      assert admin_status_json()["failure"] == nil
    end
  end

  defp admin_status_json do
    conn =
      Phoenix.ConnTest.build_conn()
      |> BarkparkWeb.SelfUpdateController.status(%{})

    Jason.decode!(conn.resp_body)
  end

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, Runner)
    Application.put_env(:barkpark, Runner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Runner, prior),
        else: Application.delete_env(:barkpark, Runner)
    end)
  end

  defp await_not_running(attempts \\ 60) do
    case Runner.status() do
      %{state: :running} when attempts > 0 ->
        Process.sleep(50)
        await_not_running(attempts - 1)

      _ ->
        :ok
    end
  end

  defp await_done(attempts \\ 60) do
    case Runner.status() do
      %{state: :done} = s -> s
      _ when attempts > 0 -> Process.sleep(50) && await_done(attempts - 1)
      s -> s
    end
  end
end
