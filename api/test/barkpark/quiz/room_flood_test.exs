defmodule Barkpark.Quiz.RoomFloodTest do
  @moduledoc """
  Owner ruling #59 (2026-10-03, task-eec10eeab544e619 Q3): quiz rooms get a
  per-room join limit and host kick and lock controls.

  One client could join a room as up to 2,000 fake players and skew the
  results. The room now meters NEW players with a token bucket, the host can
  lock the room, and the host can remove a player for good.

  Synchronous: the limiter reads `config :barkpark, Barkpark.Quiz.Room` when a
  room starts, and this module sets real values for its own duration
  (config/test.exs opens the limiter for the rest of the suite).
  """
  use ExUnit.Case, async: false

  @moduletag :requires_plugins

  alias Barkpark.Quiz

  setup do
    previous = Application.get_env(:barkpark, Barkpark.Quiz.Room)
    Application.put_env(:barkpark, Barkpark.Quiz.Room, join_burst: 3, join_rate_per_sec: 0.001)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Quiz.Room, previous) end)

    pin = "FL" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "a burst of new players is cut at the room's join limit", %{pin: pin} do
    results = for i <- 1..20, do: Quiz.join(pin, "bot-#{i}", "Bot #{i}")

    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, :join_rate_limited})) == 17
    assert Quiz.state(pin).player_count == 3

    # A known player re-joining (a reconnect) costs nothing and is never refused.
    assert {:ok, _} = Quiz.join(pin, "bot-1", "Bot 1")
  end

  test "the bucket refills over time" do
    Application.put_env(:barkpark, Barkpark.Quiz.Room, join_burst: 1, join_rate_per_sec: 50)
    pin = "FR" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)

    assert {:ok, _} = Quiz.join(pin, "a", "A")
    assert {:error, :join_rate_limited} = Quiz.join(pin, "b", "B")
    Process.sleep(60)
    assert {:ok, _} = Quiz.join(pin, "b", "B")
  end

  test "a locked room refuses new players but keeps the ones inside", %{pin: pin} do
    assert {:ok, _} = Quiz.join(pin, "p1", "Alice")
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    assert :ok = Quiz.lock(pin, true)
    assert_receive {:quiz, ^pin, {:locked, true}}
    assert Quiz.state(pin).locked

    assert {:error, :room_locked} = Quiz.join(pin, "p2", "Bob")
    assert {:ok, _} = Quiz.join(pin, "p1", "Alice")
    assert {:ok, _} = Quiz.submit_answer(pin, "p1", "a")

    assert :ok = Quiz.lock(pin, false)
    assert {:ok, _} = Quiz.join(pin, "p2", "Bob")
  end

  test "a kicked player is removed and cannot rejoin under that id", %{pin: pin} do
    {:ok, _} = Quiz.join(pin, "p1", "Alice")
    {:ok, _} = Quiz.join(pin, "p2", "Bob")
    {:ok, _} = Quiz.submit_answer(pin, "p2", "a")
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    assert :ok = Quiz.kick(pin, "p2")

    assert_receive {:quiz, ^pin, {:player_left, "p2", _slot, 1}}
    assert_receive {:quiz, ^pin, {:player_kicked, "p2"}}
    assert Quiz.state(pin).player_count == 1

    assert Map.get(Quiz.tally(pin), "a", 0) == 0,
           "the kicked player's answer must leave the tally"

    assert {:error, :kicked} = Quiz.join(pin, "p2", "Bob")
    assert {:ok, _} = Quiz.join(pin, "p3", "Carol")
  end
end
