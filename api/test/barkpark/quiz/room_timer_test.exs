defmodule Barkpark.Quiz.RoomTimerTest do
  @moduledoc """
  P3 hq-p3-timer: server-authoritative countdown — auto-reveal on expiry,
  generation-tokened so a manual reveal cancels the armed timer, and
  seconds_remaining exposed in the snapshot.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "TT" <> Integer.to_string(System.unique_integer([:positive]))
    # Joins never start rooms (Decision N) - the host (ensure) is the sole creator.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "the countdown auto-transitions :question → :reveal on expiry", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")

    Quiz.start_question(pin, 0.05)
    assert_receive {:quiz, ^pin, {:phase, :question, _}}
    assert_receive {:quiz, ^pin, {:phase, :reveal, _}}, 500
    assert Quiz.state(pin).phase == :reveal
  end

  test "a manual reveal cancels the armed timer (no double reveal)", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")

    Quiz.start_question(pin, 0.1)
    assert_receive {:quiz, ^pin, {:phase, :question, _}}
    Quiz.reveal(pin)
    assert_receive {:quiz, ^pin, {:phase, :reveal, _}}
    # the 100ms timer fires but is stale (gen bumped) → no second reveal
    refute_receive {:quiz, ^pin, {:phase, :reveal, _}}, 300
  end

  test "seconds_remaining counts down during the question", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.start_question(pin, 10)
    sr = Quiz.state(pin).seconds_remaining
    assert sr > 0 and sr <= 10
  end

  test "seconds_remaining is 0 with no active countdown", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    assert Quiz.state(pin).seconds_remaining == 0
  end
end
