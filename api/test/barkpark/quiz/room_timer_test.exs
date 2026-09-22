defmodule Barkpark.Quiz.RoomTimerTest do
  @moduledoc """
  P3 hq-p3-timer: server-authoritative countdown — auto-reveal on expiry,
  generation-tokened so a manual reveal cancels the armed timer, and
  seconds_remaining exposed in the snapshot.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  # 100x the 50ms countdown armed below. See the comment at its assert_receive.
  @reveal_ceiling_ms :timer.seconds(5)

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
    # The countdown is a real Process.send_after in the room GenServer, so the
    # :reveal broadcast arrives on wall-clock time and this ceiling is racing
    # BEAM scheduling, not the product. It flaked CI run 33465179465 with
    # ExUnit's own diagnosis — "Found message matching {:quiz, ^pin, {:phase,
    # :reveal, _}} after 500ms. This means the message was delivered too close
    # to the timeout value" — i.e. the message DID arrive, just late; that run
    # reddened #14519, a web-only PR whose diff touches zero api/ files.
    #
    # Measured on a loaded dev box, 300 arm→receive round trips of this exact
    # sequence: p50 51ms, p95 73ms, p99 152ms, max 591ms — 1 in 300 already
    # blows a 500ms ceiling with no concurrent suite at all, and CI runs this
    # inside 15,509 async tests. @reveal_ceiling_ms is therefore 100x the 50ms
    # armed duration (~8x the worst latency observed under load), not a nudge.
    # It costs nothing on the happy path: assert_receive returns the moment the
    # message lands, so the timeout is a ceiling, never a sleep. (Contrast the
    # refute_receive in the next test, which IS a real wall-clock wait on every
    # green run and must stay small.)
    assert_receive {:quiz, ^pin, {:phase, :reveal, _}}, @reveal_ceiling_ms
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
