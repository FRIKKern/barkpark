defmodule BarkparkCloud.EventsTest do
  @moduledoc """
  The team-scoped pub/sub (over OTP `:pg`) that backs the live dashboard's SSE
  stream. No DB — these exercise subscribe/broadcast/isolation/auto-unsubscribe
  directly. `async: false` because `:pg` membership is process-global state
  (distinct team ids keep tests independent, but membership polling shouldn't
  race other suites touching the same scope).
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Events

  # The :pg scope Events broadcasts over (mirrors the module's @scope). Used only
  # to assert membership directly in the auto-unsubscribe test.
  @scope :barkpark_cloud_events

  defp team_id, do: "team-#{System.unique_integer([:positive])}"

  test "subscribe/1 joins the team's pg group" do
    tid = team_id()
    :ok = Events.subscribe(tid)
    assert self() in :pg.get_members(@scope, {:team, tid})
  end

  test "broadcast/3 delivers {:bpcloud_event, %{type, payload}} to a subscriber" do
    tid = team_id()
    :ok = Events.subscribe(tid)

    :ok = Events.broadcast(tid, "fleet", %{"id" => "abc"})

    assert_receive {:bpcloud_event, %{type: "fleet", payload: %{"id" => "abc"}}}
  end

  test "broadcast defaults the payload to an empty map" do
    tid = team_id()
    :ok = Events.subscribe(tid)

    :ok = Events.broadcast(tid, "subscription")

    assert_receive {:bpcloud_event, %{type: "subscription", payload: %{}}}
  end

  test "cross-team isolation: a subscriber of team A never receives team B's events" do
    a = team_id()
    b = team_id()
    :ok = Events.subscribe(a)

    :ok = Events.broadcast(b, "fleet")

    # Team A's process must NOT get team B's broadcast.
    refute_receive {:bpcloud_event, _}, 100
  end

  test "broadcast with a nil or blank team id is a no-op (never crashes)" do
    assert Events.broadcast(nil, "fleet") == :ok
    assert Events.broadcast("", "fleet") == :ok
    refute_receive {:bpcloud_event, _}, 50
  end

  test "a dead subscriber is auto-removed from the group (process death unsubscribes)" do
    tid = team_id()
    parent = self()

    pid =
      spawn(fn ->
        :ok = Events.subscribe(tid)
        send(parent, :subscribed)
        # Park until killed.
        receive do
          :never -> :ok
        end
      end)

    assert_receive :subscribed

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # :pg removal is async — poll briefly until the dead pid is gone.
    assert eventually(fn -> pid not in :pg.get_members(@scope, {:team, tid}) end)
  end

  # Retry `fun` (a 0-arity predicate) until it returns true or the budget runs
  # out — used to wait on :pg's asynchronous membership cleanup without a flaky
  # fixed sleep.
  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
