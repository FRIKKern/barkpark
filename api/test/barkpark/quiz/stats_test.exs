defmodule Barkpark.Quiz.StatsTest do
  @moduledoc "P6 hq-p6-observability: live room/player metrics + telemetry."
  use ExUnit.Case, async: false

  # Plugins-off: the quiz plugin starts Barkpark.Quiz.RoomRegistry and the room supervisors
  @moduletag :requires_plugins

  alias Barkpark.Quiz
  alias Barkpark.Quiz.Stats

  @registry Barkpark.Quiz.RoomRegistry

  # The pins of every room the registry holds now.
  defp live_pins,
    do: @registry |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}]) |> MapSet.new()

  test "live_room_count grows with started rooms; room_stats reflects players" do
    n = System.unique_integer([:positive])
    pin1 = "TST#{n}a"
    pin2 = "TST#{n}b"

    on_exit(fn ->
      Quiz.stop_room(pin1)
      Quiz.stop_room(pin2)
    end)

    # The count is global, and a room an earlier test stopped can still be leaving
    # the registry (it drops a stopped room's entry after the stop returns), so a
    # bare before/after count can come up short. The row counts what it started:
    # each room live around the first count that is gone by the second is taken off;
    # a room started elsewhere only adds.
    others = live_pins()
    before = Stats.live_room_count()
    others = MapSet.union(others, live_pins())
    # Joins never start rooms (Decision N) — ensure (host) first, then join.
    {:ok, _} = Quiz.ensure_room(pin1)
    {:ok, _} = Quiz.ensure_room(pin2)
    Quiz.join(pin1, "p1", "Alice")
    Quiz.join(pin1, "p2", "Bob")
    Quiz.join(pin2, "p3", "Carol")

    now = Stats.live_room_count()
    ended = Enum.count(others, &(Registry.lookup(@registry, &1) == []))

    assert now >= before + 2 - ended,
           "live rooms #{now}, before #{before}, ended #{ended}: the row's two rooms are not counted"

    st = Stats.room_stats(pin1)
    assert st.players == 2
    assert st.phase == :question
    assert is_integer(st.cursors)
  end

  test "rooms emit a quiz tick telemetry event" do
    pin = "TST#{System.unique_integer([:positive])}"
    on_exit(fn -> Quiz.stop_room(pin) end)
    ref = :telemetry_test.attach_event_handlers(self(), [[:barkpark, :quiz, :tick]])
    {:ok, _} = Quiz.ensure_room(pin)
    Quiz.join(pin, "p1", "Alice")
    assert_receive {[:barkpark, :quiz, :tick], ^ref, %{cursors: _}, %{pin: ^pin}}, 500
  end
end
