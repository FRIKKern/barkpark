defmodule BarkparkCloud.SitesBoxRelayRollbackDeadlineTest do
  @moduledoc """
  site-spawner rollback-latency (task-b017df2fda0fe600, criterion 0) — the
  control plane's HALF of the rollback wait: is its budget a wall clock, and can
  it say where the time went?

  A live rollback on guerrilla measured 1.4-3.4s server-side against an engine
  symlink flip the charter measured at 25ms, with a 2x spread between two runs
  minutes apart. Nothing in `BoxRelay.HTTP` could attribute that, and its wait
  loop recurred on `left_ms - @rollback_poll_ms` — subtracting only its own
  SLEEP and never the CP->box round trip it had just spent. `@rollback_budget_ms
  10_000` was therefore a budget of 200 ITERATIONS, not of 10 seconds, and the
  box's own status read is allowed to take up to 20s
  (`Barkpark.Sites.DeployRunner.@status_call_timeout_ms`).

  Both tests drive `BoxRelay.HTTP` through the ONE transport seam
  (`:studio_link_http_client`). The relay runs the request IN THE CALLING
  PROCESS, so the fake keeps its script and its poll tally in this test's own
  process dictionary — no Agent, no cross-process ambiguity.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Sites.BoxRelay
  alias BarkparkCloud.Registry.Vault

  @slug "lp-rollback-deadline"

  defmodule ScriptedBox do
    @moduledoc """
    The box, faked at `:studio_link_http_client`. The POST accepts (202, the real
    door's answer); every GET sleeps `:box_poll_delay_ms` and then answers the
    programmed `:box_state`. Each GET is tallied so a test can count the polls the
    loop actually spent, not just the wall clock it took.
    """
    def request(%{method: :post}), do: {:ok, %{status: 202, body: ~s({"status":"started"})}}

    def request(%{method: :get}) do
      Process.put(:box_polls, Process.get(:box_polls, 0) + 1)
      Process.sleep(Process.get(:box_poll_delay_ms, 0))
      {:ok, %{status: 200, body: Process.get(:box_body)}}
    end
  end

  setup do
    prev_client = Application.get_env(:barkpark_cloud, :studio_link_http_client)
    prev_budget = Application.get_env(:barkpark_cloud, :site_rollback_budget_ms)
    Application.put_env(:barkpark_cloud, :studio_link_http_client, ScriptedBox)

    on_exit(fn ->
      restore(:studio_link_http_client, prev_client)
      restore(:site_rollback_budget_ms, prev_budget)
    end)

    :ok
  end

  describe "the wait is bounded by a WALL CLOCK, not by an iteration count" do
    test "a box that never reports done is cut off at the budget, not at budget/poll_interval polls" do
      # 300ms of budget against a box whose every status read costs 120ms on the
      # wire. Counting ITERATIONS, 300ms of budget buys 300/50 = 6 of them, and
      # each also pays its own 120ms round trip: ~1020ms of wall clock inside a
      # "300ms" budget — the 3.4x overrun that scales straight to the shipped
      # 10_000ms budget and a slow box. Counting the CLOCK, the wire time is
      # charged too, so the wait ends at ~300ms after 2-3 polls.
      Application.put_env(:barkpark_cloud, :site_rollback_budget_ms, 300)
      Process.put(:box_poll_delay_ms, 120)
      Process.put(:box_body, ~s({"state":"running"}))
      Process.put(:box_polls, 0)

      started = System.monotonic_time(:millisecond)
      reply = BoxRelay.HTTP.rollback(bp(), %{slug: @slug})
      elapsed = System.monotonic_time(:millisecond) - started

      # The honest 504 still lands — the fix bounds the wait, it does not invent
      # a verdict about a flip nobody confirmed.
      assert {:ok, 504, %{"error" => error}} = reply
      assert error =~ "did not confirm the rollback in time"

      polls = Process.get(:box_polls)

      assert elapsed < 600,
             "the rollback wait took #{elapsed}ms against a 300ms budget — the deadline " <>
               "is counting poll iterations, not the clock (#{polls} polls)"

      assert polls <= 4,
             "the wait spent #{polls} polls inside a 300ms budget at 120ms/poll — an " <>
               "iteration count, not a wall clock"
    end
  end

  describe "the wait ATTRIBUTES its own time" do
    test "a completed rollback logs the accept / poll-wire / sleep split" do
      Process.put(:box_poll_delay_ms, 0)
      Process.put(:box_body, ~s({"state":"done","exit_code":0,"log":["TARGET_BUILD=b-old"]}))
      Process.put(:box_polls, 0)

      # config/test.exs pins the primary Logger level to :warning, which would
      # filter the attribution line before any capture handler could see it — an
      # empty capture would then read as "the line is missing" rather than "the
      # level filtered it". Lift it for this test only.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, 200, %{"status" => "rolled_back", "build_id" => "b-old"}} =
                   BoxRelay.HTTP.rollback(bp(), %{slug: @slug})
        end)

      assert log =~ "site rollback attribution slug=#{@slug}"
      # Every component of the ~1.4-3.4s question is named, so ONE live rollback
      # says how much sat in the relay and how much in this loop's quantisation.
      assert log =~ "total_ms="
      assert log =~ "accept_ms="
      assert log =~ "poll_wire_ms="
      # A box already done before the first read costs exactly one poll and zero
      # sleep — the residue is then all relay, which is the whole point of the
      # split.
      assert log =~ "polls=1"
      assert log =~ "sleep_ms=0"
    end
  end

  defp bp do
    %Barkpark{
      url: "https://box.example",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    }
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark_cloud, key)
  defp restore(key, value), do: Application.put_env(:barkpark_cloud, key, value)
end
