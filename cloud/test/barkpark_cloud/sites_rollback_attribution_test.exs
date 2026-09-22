defmodule BarkparkCloud.SitesRollbackAttributionTest do
  @moduledoc """
  site-spawner rollback-latency (task-b017df2fda0fe600, criterion 0) — the box's
  own execution, BRACKETED by the control plane, and the relay split handed up to
  the request-scoped accumulator.

  The row asks for the ~1.4-3.4 s of server-side time to be split three ways: the
  CP route, the CP->box relay, and the box itself. `BoxRelay.HTTP`'s existing
  `accept_ms / poll_wire_ms / sleep_ms` line covers the relay and nothing else —
  the box's work was folded into an unnamed residue TOGETHER with this loop's own
  poll quantisation, so a 3 s rollback could not be blamed on the box or acquitted
  of it.

  These tests drive `BoxRelay.HTTP` through the one transport seam
  (`:studio_link_http_client`) with a box whose completion time the test CONTROLS,
  and then assert the bracket actually contains it. The relay runs in the calling
  process, so the scripted box keeps its state in this test's own process
  dictionary and the accumulator's report comes back in the same process.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Sites.BoxRelay
  alias BarkparkCloud.Sites.RollbackAttribution

  @slug "lp-rollback-attribution"

  defmodule Sink do
    @moduledoc "Forwards the attribution report to the test process, as a map."
    def report(r) do
      send(Process.get(:attribution_owner), {:attribution, r})
      :ok
    end
  end

  defmodule ScriptedBox do
    @moduledoc """
    A box that is BUSY for a programmed number of status reads and then done. The
    POST accepts (202, the real door's answer); each GET sleeps
    `:box_poll_delay_ms` on the wire, then answers `running` until
    `:box_busy_polls` reads have gone by and `done` after that.
    """
    def request(%{method: :post}), do: {:ok, %{status: 202, body: ~s({"status":"started"})}}

    def request(%{method: :get}) do
      n = Process.get(:box_polls, 0) + 1
      Process.put(:box_polls, n)
      Process.sleep(Process.get(:box_poll_delay_ms, 0))

      body =
        if n > Process.get(:box_busy_polls, 0) do
          ~s({"state":"done","exit_code":0,"log":["TARGET_BUILD=b-old"]})
        else
          ~s({"state":"running"})
        end

      {:ok, %{status: 200, body: body}}
    end
  end

  setup do
    prev_client = Application.get_env(:barkpark_cloud, :studio_link_http_client)
    Application.put_env(:barkpark_cloud, :studio_link_http_client, ScriptedBox)

    on_exit(fn ->
      case prev_client do
        nil -> Application.delete_env(:barkpark_cloud, :studio_link_http_client)
        c -> Application.put_env(:barkpark_cloud, :studio_link_http_client, c)
      end
    end)

    Process.put(:attribution_owner, self())
    RollbackAttribution.redirect_reports_to(Sink)
    Process.put(:box_polls, 0)
    Process.put(:box_poll_delay_ms, 0)

    :ok
  end

  describe "the BOX's execution is bracketed, not left in a residue" do
    test "a box busy for two polls reports a bracket that contains its real run time" do
      # The box stays `running` for two status reads and answers `done` on the
      # third. With a 50ms poll interval that is roughly 100ms of box work — and
      # the point is not the exact number, it is that the plane can now NAME a
      # lower and an upper bound for it at all.
      Process.put(:box_busy_polls, 2)

      report = run_rollback()

      assert report.relay_polls == 3

      assert report.box_min_ms > 0,
             "the box answered `running` on two reads, so it demonstrably ran for a " <>
               "positive time — box_min_ms=#{report.box_min_ms} says the plane did not " <>
               "notice (report: #{inspect(report)})"

      assert is_integer(report.box_max_ms),
             "the box finished and the plane saw it finish, so an upper bound EXISTS — " <>
               "a nil box_max_ms means the bracket never closed (#{inspect(report)})"

      assert report.box_max_ms >= report.box_min_ms,
             "the bracket is inverted: box_min_ms=#{report.box_min_ms} > " <>
               "box_max_ms=#{report.box_max_ms}"

      # The bracket must be a bound on the BOX, not on the whole call: it cannot
      # exceed the wall clock the relay spent.
      assert report.box_max_ms <= report.relay_ms,
             "box_max_ms=#{report.box_max_ms} exceeds the whole relay span " <>
               "relay_ms=#{report.relay_ms} — that is not a bound on the box"
    end

    # THE CONTROL. A box already finished before the first status read did NOT run
    # for a measurable time after the accept, and the bracket must say so rather
    # than inheriting the busy case's numbers. This arm is what proves the bracket
    # tracks the box instead of just tracking the clock.
    test "a box already done on the first read reports a ZERO lower bound" do
      Process.put(:box_busy_polls, 0)

      report = run_rollback()

      assert report.relay_polls == 1

      assert report.box_min_ms == 0,
             "no poll ever saw the box `running`, so there is no evidence it ran at all " <>
               "after the accept — box_min_ms=#{report.box_min_ms} is invented " <>
               "(#{inspect(report)})"

      assert report.wait_quantisation_ms == 0,
             "the first read found the box done, so this loop never slept — " <>
               "wait_quantisation_ms=#{report.wait_quantisation_ms}"
    end
  end

  describe "the relay split reaches the request-scoped accumulator" do
    test "every seam of the server-side second is named in one report" do
      Process.put(:box_busy_polls, 1)

      report = run_rollback()

      for key <- [
            :total_ms,
            :route_pre_ms,
            :route_post_ms,
            :deploy_own_ms,
            :wait_quantisation_ms,
            :relay_ms,
            :relay_accept_ms,
            :relay_poll_wire_ms,
            :relay_polls,
            :box_min_ms,
            :unattributed_ms
          ] do
        assert is_integer(Map.fetch!(report, key)),
               "#{key} is not a measured integer in #{inspect(report)}"
      end

      assert report.outcome == "rolled_back"

      # The relay's own legs must add up INSIDE its span — if they overran it the
      # split would be measuring overlapping clocks.
      assert report.relay_accept_ms + report.relay_poll_wire_ms + report.wait_quantisation_ms <=
               report.relay_ms,
             "the relay's legs exceed the relay span: #{inspect(report)}"
    end

    # THE SECOND CONTROL. The accumulator is request-scoped; a relay call made
    # OUTSIDE a route (a worker, a script, this very test without `open/1`) must
    # not report anything at all. A module that reported unconditionally would
    # look green above for the wrong reason.
    test "a relay call with no stopwatch open reports NOTHING" do
      Process.put(:box_busy_polls, 0)

      assert {:ok, 200, %{"status" => "rolled_back"}} =
               BoxRelay.HTTP.rollback(bp(), %{slug: @slug})

      refute_receive {:attribution, _}, 100
    end
  end

  # Drive one full rollback with the stopwatch open, exactly as the route does.
  defp run_rollback do
    RollbackAttribution.open(@slug)
    RollbackAttribution.deploy_begins()

    assert {:ok, 200, %{"status" => "rolled_back", "build_id" => "b-old"}} =
             BoxRelay.HTTP.rollback(bp(), %{slug: @slug})

    RollbackAttribution.deploy_ends()
    RollbackAttribution.close("rolled_back")

    assert_receive {:attribution, report}, 500
    report
  end

  defp bp do
    %Barkpark{
      url: "https://box.example",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    }
  end
end
