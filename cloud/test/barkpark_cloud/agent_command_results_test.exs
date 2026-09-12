defmodule BarkparkCloud.AgentCommandResultsTest do
  @moduledoc """
  `POST /v1/agent/results` must COUNT what the on-box agent reports, not ack a
  200 over it (dr-w19-bl).

  ## The can-lose proof this file is built around

  A guard that cannot fail is not a guard. The route answers `200 {ok: true}`
  whether or not anything was counted, so a test that only asserts the status
  would stay green with the reporting ripped out — that is precisely the bug
  being fixed, re-created inside the guard.

  So the END-TO-END arm below asserts the OBSERVABLE, never the status: one
  `Logger.warning` per failed/timed-out/rejected result and one telemetry event
  carrying the buckets. Delete the `AgentCommandResults.record/2` call from
  `Web.Router`'s `post "/v1/agent/results"` and the three
  `"reports … through the live route"` tests go red — no warning is logged and
  the telemetry message never arrives — while the 200 keeps being a 200. That
  mutation was run: RED with the call removed, GREEN with it restored (tails in
  the PR body).

  ## Why the three shapes are pinned separately

  They are produced by DIFFERENT code in `internal/agent`, so one fixture
  cannot stand for all three:

    * rejected  — `runCommand/2` in `commands.go`, `Approved: false` plus a
      `rejected: %q is not an approved command` reason.
    * timed out — `runBounded` in `report.go`, which turns a blown
      `execRunnerTimeout` into `"timed out after 5m0s: make -C …"`.
    * failed    — the runner's own `exec.ExitError`, i.e. `"exit status 1"`.

  The literal wire strings in the fixtures below are copied from those two
  files on purpose: they are the contract, and if Go reworded them this suite
  is where the drift should surface.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, AgentCommandResults, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"

  ## Fixtures — the exact shapes internal/agent puts on the wire.

  # commands.go, runCommand/2: the allowlist miss. Approved is a real boolean
  # field, so this classification never depends on prose.
  defp rejected_result do
    %{
      "id" => "r-1",
      "name" => "rm-rf",
      "approved" => false,
      "output" => "",
      "error" =>
        "rejected: \"rm-rf\" is not an approved command (allowed: [backup doctor logs rebuild restart update])"
    }
  end

  # report.go, runBounded: `fmt.Errorf("%w after %s: %s %s", errProbeTimedOut, …)`.
  defp timed_out_result do
    %{
      "id" => "t-1",
      "name" => "update",
      "approved" => true,
      "output" => "",
      "error" => "timed out after 5m0s: make -C /opt/barkpark deploy"
    }
  end

  # The runner's own non-zero exit — an exec.ExitError, not a deadline.
  defp failed_result do
    %{
      "id" => "f-1",
      "name" => "rebuild",
      "approved" => true,
      "output" => "make: *** [rebuild] Error 1",
      "error" => "exit status 1"
    }
  end

  defp ok_result do
    %{"id" => "o-1", "name" => "restart", "approved" => true, "output" => "ok", "error" => ""}
  end

  defp agent_conn(bp) do
    {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")
    agent_token
  end

  defp barkpark_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "acr-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-acr-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-acr-#{n}"})
    bp
  end

  defp post_results(bp, body) do
    conn(:post, "/v1/agent/results", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{agent_conn(bp)}")
    |> Router.call(@opts)
  end

  # Attach to the module's own event for the duration of one test and forward
  # every measurement to the test process.
  defp attach_telemetry do
    ref = make_ref()
    parent = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      AgentCommandResults.telemetry_event(),
      fn _event, measurements, metadata, _ ->
        send(parent, {:telemetry, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  ## ── classify/1: the contract with internal/agent ──

  describe "classify/1" do
    test "an allowlist rejection is :rejected — off the boolean, not the prose" do
      assert {:rejected, detail} = AgentCommandResults.classify(rejected_result())
      assert detail.name == "rm-rf"
      assert detail.error =~ "not an approved command"
    end

    test "a blown deadline is :timed_out, told apart from a plain non-zero exit" do
      assert {:timed_out, detail} = AgentCommandResults.classify(timed_out_result())
      assert detail.error == "timed out after 5m0s: make -C /opt/barkpark deploy"
    end

    test "a non-zero exit is :failed" do
      assert {:failed, detail} = AgentCommandResults.classify(failed_result())
      assert detail.error == "exit status 1"
    end

    test "an approved command with no error is :ok" do
      assert {:ok, _} = AgentCommandResults.classify(ok_result())
      assert {:ok, _} = AgentCommandResults.classify(%{"id" => "x", "approved" => true})
    end

    test "a non-map entry is :malformed, and names the SHAPE without echoing the payload" do
      assert {:malformed, detail} = AgentCommandResults.classify("s3kr3t-payload")
      assert {:malformed, _} = AgentCommandResults.classify(nil)

      # D95 (router_transport_redaction_test.exs): an unparseable body is the
      # body most likely to carry something nobody vetted. The count is the
      # signal; the content is not repeated back.
      refute detail.error =~ "s3kr3t-payload"
      assert detail.error == "unreadable result entry (string)"
    end

    test "the three failure shapes land in THREE distinct buckets" do
      outcomes =
        for entry <- [rejected_result(), timed_out_result(), failed_result(), ok_result()] do
          {outcome, _} = AgentCommandResults.classify(entry)
          outcome
        end

      assert outcomes == [:rejected, :timed_out, :failed, :ok],
             "each shape must be countable on its own; got #{inspect(outcomes)}"
    end
  end

  ## ── record/2: counting, including Plug's array wrapper ──

  describe "record/2" do
    test "counts a Plug-wrapped JSON array (the shape the route actually receives)" do
      body = %{"_json" => [rejected_result(), timed_out_result(), failed_result(), ok_result()]}

      counts = capture_log_result(fn -> AgentCommandResults.record(%{id: "bp-1"}, body) end)

      assert counts == %{ok: 1, failed: 1, timed_out: 1, rejected: 1, malformed: 0}
    end

    test "an empty parsed body is zero results, not one malformed one" do
      counts = capture_log_result(fn -> AgentCommandResults.record(%{id: "bp-1"}, %{}) end)
      assert counts == %{ok: 0, failed: 0, timed_out: 0, rejected: 0, malformed: 0}
    end

    test "a bare list works too — the classification never depends on parser trivia" do
      counts =
        capture_log_result(fn -> AgentCommandResults.record(%{id: "bp-1"}, [failed_result()]) end)

      assert counts.failed == 1
    end
  end

  ## ── the live route: the arms the mutation reds ──

  describe "POST /v1/agent/results" do
    test "reports a rejection through the live route" do
      bp = barkpark_fixture()
      ref = attach_telemetry()

      log =
        capture_log(fn ->
          conn = post_results(bp, [rejected_result()])
          assert conn.status == 200
        end)

      assert log =~ "agent command rejected:",
             "the allowlist rejection reached the control plane and was not logged"

      assert log =~ "not an approved command"

      assert_received {:telemetry, ^ref, measurements, %{barkpark_id: id}}
      assert id == bp.id
      assert measurements.rejected == 1
    end

    test "reports a timeout through the live route" do
      bp = barkpark_fixture()
      ref = attach_telemetry()

      log =
        capture_log(fn ->
          conn = post_results(bp, [timed_out_result()])
          assert conn.status == 200
        end)

      assert log =~ "agent command timed_out:",
             "the blown 5-minute deadline reached the control plane and was not logged"

      assert_received {:telemetry, ^ref, measurements, _}
      assert measurements.timed_out == 1
    end

    test "reports a non-zero exit through the live route" do
      bp = barkpark_fixture()
      ref = attach_telemetry()

      log =
        capture_log(fn ->
          conn = post_results(bp, [failed_result()])
          assert conn.status == 200
        end)

      assert log =~ "agent command failed:",
             "the non-zero exit reached the control plane and was not logged"

      assert_received {:telemetry, ^ref, measurements, _}
      assert measurements.failed == 1
    end

    test "an all-ok post still emits the counters — silence must mean 'nothing broke', not 'nothing ran'" do
      bp = barkpark_fixture()
      ref = attach_telemetry()

      log = capture_log(fn -> assert post_results(bp, [ok_result()]).status == 200 end)

      refute log =~ "agent command failed:"

      # The per-post SUMMARY is a Logger.info and `config/test.exs` pins the
      # primary logger at :warning, so it is filtered before capture_log can see
      # it — asserting on it here would be asserting on the config, not on the
      # code. The telemetry event below is the all-ok arm's real observable, and
      # it is the one a metrics backend reads anyway.

      assert_received {:telemetry, ^ref, measurements, _}
      assert measurements == %{ok: 1, failed: 0, timed_out: 0, rejected: 0, malformed: 0}
    end

    test "an unauthenticated post is still 401 — the counter never runs before auth" do
      ref = attach_telemetry()

      conn =
        conn(:post, "/v1/agent/results", Jason.encode!([failed_result()]))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 401
      refute_received {:telemetry, ^ref, _, _}
    end
  end

  # capture_log/1 returns the LOG, so a function whose return value we also want
  # needs the value carried out of the closure.
  defp capture_log_result(fun) do
    parent = self()
    ref = make_ref()
    _ = capture_log(fn -> send(parent, {ref, fun.()}) end)

    receive do
      {^ref, value} -> value
    after
      0 -> flunk("the captured function did not return")
    end
  end
end
