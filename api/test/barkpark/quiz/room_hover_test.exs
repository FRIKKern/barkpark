defmodule Barkpark.Quiz.RoomHoverTest do
  @moduledoc """
  P2 hq-p2-hover tests: per-choice hover-intent counts ("37 hovering B"),
  broadcast on change over the events topic, with validation + cleanup.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "TH" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "hover sets per-choice counts and broadcasts them", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")

    Quiz.hover(pin, "p1", "a")
    assert_receive {:quiz, ^pin, {:hover_counts, %{"a" => 1, "b" => 0}}}, 500
    Quiz.hover(pin, "p2", "a")
    assert_receive {:quiz, ^pin, {:hover_counts, %{"a" => 2}}}, 500

    assert Quiz.state(pin).hover_counts["a"] == 2
  end

  test "hovering a different choice moves the count", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.hover(pin, "p1", "a")
    Quiz.hover(pin, "p1", "b")
    # let the casts settle
    counts = Quiz.state(pin).hover_counts
    assert counts["a"] == 0
    assert counts["b"] == 1
  end

  test "nil clears a player's hover", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.hover(pin, "p1", "a")
    Quiz.hover(pin, "p1", nil)
    assert Quiz.state(pin).hover_counts["a"] == 0
  end

  test "invalid choice and non-joined player are ignored", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.hover(pin, "p1", "zzz")
    Quiz.hover(pin, "ghost", "a")
    counts = Quiz.state(pin).hover_counts
    assert counts == %{"a" => 0, "b" => 0, "c" => 0, "d" => 0}
  end

  test "leaving clears the player's hover", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.hover(pin, "p1", "a")
    Quiz.leave(pin, "p1")
    assert Quiz.state(pin).hover_counts["a"] == 0
  end

  test "an unchanged hover does NOT re-broadcast (no O(N) amplification)", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")

    Quiz.hover(pin, "p1", "a")
    assert_receive {:quiz, ^pin, {:hover_counts, %{"a" => 1}}}, 500
    # Same choice again → state already reflects it → must NOT broadcast again.
    Quiz.hover(pin, "p1", "a")
    refute_receive {:quiz, ^pin, {:hover_counts, _}}, 150
  end
end
