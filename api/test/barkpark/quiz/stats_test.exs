defmodule Barkpark.Quiz.StatsTest do
  @moduledoc "P6 hq-p6-observability: live room/player metrics + telemetry."
  use ExUnit.Case, async: false

  alias Barkpark.Quiz
  alias Barkpark.Quiz.Stats

  test "live_room_count grows with started rooms; room_stats reflects players" do
    n = System.unique_integer([:positive])
    pin1 = "TST#{n}a"
    pin2 = "TST#{n}b"

    on_exit(fn ->
      Quiz.stop_room(pin1)
      Quiz.stop_room(pin2)
    end)

    before = Stats.live_room_count()
    Quiz.join(pin1, "p1", "Alice")
    Quiz.join(pin1, "p2", "Bob")
    Quiz.join(pin2, "p3", "Carol")

    assert Stats.live_room_count() >= before + 2

    st = Stats.room_stats(pin1)
    assert st.players == 2
    assert st.phase == :question
    assert is_integer(st.cursors)
  end

  test "rooms emit a quiz tick telemetry event" do
    pin = "TST#{System.unique_integer([:positive])}"
    on_exit(fn -> Quiz.stop_room(pin) end)
    ref = :telemetry_test.attach_event_handlers(self(), [[:barkpark, :quiz, :tick]])
    Quiz.join(pin, "p1", "Alice")
    assert_receive {[:barkpark, :quiz, :tick], ^ref, %{cursors: _}, %{pin: ^pin}}, 500
  end
end
